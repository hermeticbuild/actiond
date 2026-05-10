const std = @import("std");
const action_cache = @import("action_cache.zig");
const action_runner = @import("action_runner.zig");
const cas = @import("cas.zig");
const execroot = @import("execroot.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    MissingActionBlob,
    MissingCommandDigest,
    MissingCommandBlob,
    MissingDirectoryBlob,
    MissingDirectoryDigest,
    MissingFileDigest,
    MissingInputBlob,
    MissingInputRootDigest,
    OutputParentCreateFailed,
    InvalidDirectoryEntryName,
    UnsupportedOutputDirectoryEntry,
};

const max_output_file_bytes = 1024 * 1024 * 1024;

pub const ExecuteOptions = struct {};

pub fn executeAndCacheAction(
    io: std.Io,
    allocator: std.mem.Allocator,
    blob_store: cas.Store,
    result_store: action_cache.Store,
    work_root: std.Io.Dir,
    action_digest: cas.Digest,
) !action_runner.Outcome {
    var outcome = try executeActionWithOptions(io, allocator, blob_store, work_root, action_digest, .{});
    errdefer outcome.deinit(allocator);

    var result = try actionResultFromOutcomeOwned(allocator, outcome);
    defer result.deinit(allocator);
    try result_store.put(
        io,
        allocator,
        action_digest,
        result.result,
    );
    return outcome;
}

pub fn executeAction(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    action_digest: cas.Digest,
) !action_runner.Outcome {
    return executeActionWithOptions(io, allocator, store, work_root, action_digest, .{});
}

pub fn executeActionWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    action_digest: cas.Digest,
    options: ExecuteOptions,
) !action_runner.Outcome {
    const action_bytes = store.readAlloc(io, allocator, action_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingActionBlob,
        else => return err,
    };
    defer allocator.free(action_bytes);
    var action_reader = protobuf.Reader.init(action_bytes);
    var action = try reapi.Action.decodeOwned(allocator, &action_reader);
    defer action.deinit(allocator);

    const command_digest = try cas.Digest.fromReapi(action.command_digest orelse return error.MissingCommandDigest);
    const command_bytes = store.readAlloc(io, allocator, command_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCommandBlob,
        else => return err,
    };
    defer allocator.free(command_bytes);
    var command_reader = protobuf.Reader.init(command_bytes);
    var command = try reapi.Command.decodeOwned(allocator, &command_reader);
    defer command.deinit(allocator);

    const input_root_digest = try cas.Digest.fromReapi(action.input_root_digest orelse return error.MissingInputRootDigest);
    var inputs: std.ArrayListUnmanaged(execroot.Input) = .empty;
    defer inputs.deinit(allocator);
    defer freeInputs(allocator, inputs.items);
    var directory_inputs: std.ArrayListUnmanaged(execroot.DirectoryInput) = .empty;
    defer directory_inputs.deinit(allocator);
    defer freeDirectoryInputs(allocator, directory_inputs.items);
    try collectInputs(io, allocator, store, input_root_digest, "", &inputs, &directory_inputs);

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try work_root.realPath(io, &cwd_buffer);
    const work_root_path = cwd_buffer[0..cwd_len];

    const materializer = execroot.Materializer.init(store, work_root);
    var materialization = materializer.materializeInputs(io, allocator, inputs.items, .{
        .chroot_root_path = work_root_path,
        .directory_inputs = directory_inputs.items,
    }) catch |err| switch (err) {
        error.FileNotFound, error.MissingInputTree => return error.MissingInputBlob,
        else => return err,
    };
    defer materialization.deinit(allocator);
    prepareOutputParents(io, work_root, command) catch |err| switch (err) {
        error.FileNotFound => return error.OutputParentCreateFailed,
        else => return err,
    };

    const chroot_cwd = if (command.working_directory.len == 0)
        "/"
    else cwd: {
        try execroot.validatePath(command.working_directory);
        break :cwd try std.fmt.allocPrint(allocator, "/{s}", .{command.working_directory});
    };
    defer if (command.working_directory.len != 0) allocator.free(chroot_cwd);

    _ = options;
    var outcome = try action_runner.runCommandWithOptions(io, allocator, store, command, .{
        .chroot_dir = work_root_path,
        .chroot_cwd = chroot_cwd,
        .bind_mounts = materialization.bind_mounts,
        .cgroup_limits = action_runner.CgroupLimits.fromPlatform(action.platform),
    });
    errdefer outcome.deinit(allocator);
    try collectOutputFiles(io, allocator, store, work_root, command, &outcome);
    return outcome;
}

pub fn actionResultFromOutcome(
    outcome: action_runner.Outcome,
    stdout_hash: *[64]u8,
    stderr_hash: *[64]u8,
) reapi.ActionResult {
    return .{
        .exit_code = switch (outcome.status) {
            .exited => |code| code,
            .signaled => |signal| 128 + @as(i32, signal),
            .stopped, .unknown => 1,
        },
        .stdout_digest = if (outcome.stdout_digest) |digest| digest.toReapi(stdout_hash) else null,
        .stderr_digest = if (outcome.stderr_digest) |digest| digest.toReapi(stderr_hash) else null,
    };
}

pub const OwnedActionResult = struct {
    result: reapi.ActionResult,
    output_files: []reapi.OutputFile,
    output_directories: []reapi.OutputDirectory,
    hash_strings: []const []u8,

    pub fn deinit(self: *OwnedActionResult, allocator: std.mem.Allocator) void {
        for (self.hash_strings) |hash| allocator.free(hash);
        allocator.free(self.hash_strings);
        allocator.free(self.output_files);
        allocator.free(self.output_directories);
        self.* = undefined;
    }
};

pub fn actionResultFromOutcomeOwned(
    allocator: std.mem.Allocator,
    outcome: action_runner.Outcome,
) !OwnedActionResult {
    var hash_strings: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (hash_strings.items) |hash| allocator.free(hash);
        hash_strings.deinit(allocator);
    }

    var output_files = try allocator.alloc(reapi.OutputFile, outcome.output_files.len);
    errdefer allocator.free(output_files);
    var output_directories = try allocator.alloc(reapi.OutputDirectory, outcome.output_directories.len);
    errdefer allocator.free(output_directories);

    for (outcome.output_files, 0..) |output_file, i| {
        output_files[i] = .{
            .path = output_file.path,
            .digest = try appendDigest(allocator, &hash_strings, output_file.digest),
            .is_executable = output_file.is_executable,
        };
    }
    for (outcome.output_directories, 0..) |output_directory, i| {
        output_directories[i] = .{
            .path = output_directory.path,
            .root_directory_digest = try appendDigest(allocator, &hash_strings, output_directory.root_digest),
            .is_topologically_sorted = true,
        };
    }

    return .{
        .result = .{
            .output_files = output_files,
            .output_directories = output_directories,
            .exit_code = switch (outcome.status) {
                .exited => |code| code,
                .signaled => |signal| 128 + @as(i32, signal),
                .stopped, .unknown => 1,
            },
            .stdout_digest = if (outcome.stdout_digest) |digest| try appendDigest(allocator, &hash_strings, digest) else null,
            .stderr_digest = if (outcome.stderr_digest) |digest| try appendDigest(allocator, &hash_strings, digest) else null,
        },
        .output_files = output_files,
        .output_directories = output_directories,
        .hash_strings = try hash_strings.toOwnedSlice(allocator),
    };
}

fn appendDigest(
    allocator: std.mem.Allocator,
    hash_strings: *std.ArrayListUnmanaged([]u8),
    digest: cas.Digest,
) !reapi.Digest {
    var buffer: [64]u8 = undefined;
    const owned_hash = try allocator.dupe(u8, digest.formatHex(&buffer));
    errdefer allocator.free(owned_hash);
    try hash_strings.append(allocator, owned_hash);
    return .{
        .hash = owned_hash,
        .size_bytes = @intCast(digest.size_bytes),
    };
}

fn collectOutputFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    command: reapi.Command,
    outcome: *action_runner.Outcome,
) !void {
    var output_files: std.ArrayListUnmanaged(action_runner.Outcome.OutputFile) = .empty;
    var output_directories: std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory) = .empty;
    errdefer {
        for (output_files.items) |output_file| allocator.free(output_file.path);
        for (output_directories.items) |output_directory| allocator.free(output_directory.path);
        output_files.deinit(allocator);
        output_directories.deinit(allocator);
    }

    if (command.output_paths.len != 0) {
        for (command.output_paths) |path| {
            try collectOutputPath(io, allocator, store, work_root, path, &output_files, &output_directories);
        }
    } else {
        for (command.output_files) |path| {
            try collectOutputFile(io, allocator, store, work_root, path, &output_files);
        }
        for (command.output_directories) |path| {
            try collectOutputDirectory(io, allocator, store, work_root, path, &output_directories);
        }
    }

    outcome.output_files = try output_files.toOwnedSlice(allocator);
    outcome.output_directories = try output_directories.toOwnedSlice(allocator);
}

fn collectOutputPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    path: []const u8,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    try execroot.validatePath(path);
    const stat = work_root.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    switch (stat.kind) {
        .file => try collectOutputFileWithStat(io, allocator, store, work_root, path, stat, output_files),
        .directory => try collectOutputDirectoryWithStat(io, allocator, store, work_root, path, output_directories),
        else => return error.FailedPrecondition,
    }
}

fn collectOutputFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    path: []const u8,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
) !void {
    try execroot.validatePath(path);
    const stat = work_root.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file) return error.FailedPrecondition;
    try collectOutputFileWithStat(io, allocator, store, work_root, path, stat, output_files);
}

fn collectOutputFileWithStat(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    path: []const u8,
    stat: std.Io.Dir.Stat,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
) !void {
    if (stat.size > max_output_file_bytes) return error.FileTooBig;

    const digest = store.putFile(io, work_root, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    try output_files.append(allocator, .{
        .path = path_copy,
        .digest = digest,
        .is_executable = isExecutable(stat),
    });
}

fn collectOutputDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    path: []const u8,
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    try execroot.validatePath(path);
    const stat = work_root.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) return error.FailedPrecondition;
    try collectOutputDirectoryWithStat(io, allocator, store, work_root, path, output_directories);
}

fn collectOutputDirectoryWithStat(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    path: []const u8,
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    var dir = try work_root.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const digest = try putDirectoryTree(io, allocator, store, dir);

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    try output_directories.append(allocator, .{
        .path = path_copy,
        .root_digest = digest,
    });
}

fn prepareOutputParents(
    io: std.Io,
    work_root: std.Io.Dir,
    command: reapi.Command,
) !void {
    if (command.output_paths.len != 0) {
        for (command.output_paths) |path| try createOutputParent(io, work_root, path);
        return;
    }

    for (command.output_files) |path| try createOutputParent(io, work_root, path);
    for (command.output_directories) |path| try createOutputParent(io, work_root, path);
}

fn createOutputParent(io: std.Io, work_root: std.Io.Dir, path: []const u8) !void {
    if (path.len == 0) return;
    try execroot.validatePath(path);
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (last_slash == 0) return;
    try work_root.createDirPath(io, path[0..last_slash]);
}

fn isExecutable(stat: std.Io.Dir.Stat) bool {
    if (comptime !std.Io.File.Permissions.has_executable_bit) return false;
    return stat.permissions.toMode() & 0o111 != 0;
}

const DirectoryEntry = struct {
    name: []u8,
    kind: std.Io.File.Kind,
};

fn putDirectoryTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    dir: std.Io.Dir,
) !cas.Digest {
    var entries: std.ArrayListUnmanaged(DirectoryEntry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }

    std.mem.sort(DirectoryEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    var files: std.ArrayListUnmanaged(reapi.FileNode) = .empty;
    defer files.deinit(allocator);
    var directories: std.ArrayListUnmanaged(reapi.DirectoryNode) = .empty;
    defer directories.deinit(allocator);
    var hash_strings: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (hash_strings.items) |hash| allocator.free(hash);
        hash_strings.deinit(allocator);
    }

    for (entries.items) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = try dir.statFile(io, entry.name, .{});
                const digest = try store.putFile(io, dir, entry.name);
                try files.append(allocator, .{
                    .name = entry.name,
                    .digest = try appendDigest(allocator, &hash_strings, digest),
                    .is_executable = isExecutable(stat),
                });
            },
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                const digest = try putDirectoryTree(io, allocator, store, child);
                try directories.append(allocator, .{
                    .name = entry.name,
                    .digest = try appendDigest(allocator, &hash_strings, digest),
                });
            },
            else => return error.UnsupportedOutputDirectoryEntry,
        }
    }

    return try putProto(io, allocator, store, reapi.Directory{
        .files = files.items,
        .directories = directories.items,
    });
}

fn collectInputs(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    directory_digest: cas.Digest,
    prefix: []const u8,
    inputs: *std.ArrayListUnmanaged(execroot.Input),
    directory_inputs: *std.ArrayListUnmanaged(execroot.DirectoryInput),
) !void {
    const directory_bytes = store.readAlloc(io, allocator, directory_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingDirectoryBlob,
        else => return err,
    };
    defer allocator.free(directory_bytes);

    var reader = protobuf.Reader.init(directory_bytes);
    var directory = try reapi.Directory.decodeOwned(allocator, &reader);
    defer directory.deinit(allocator);

    for (directory.files) |file| {
        try validateEntryName(file.name);
        const digest = try cas.Digest.fromReapi(file.digest orelse return error.MissingFileDigest);
        const path = try joinPath(allocator, prefix, file.name);
        errdefer allocator.free(path);
        try inputs.append(allocator, .{
            .path = path,
            .digest = digest,
            .is_executable = file.is_executable,
        });
    }

    for (directory.directories) |child| {
        try validateEntryName(child.name);
        const digest = try cas.Digest.fromReapi(child.digest orelse return error.MissingDirectoryDigest);
        const child_prefix = try joinPath(allocator, prefix, child.name);
        errdefer allocator.free(child_prefix);
        if (try store.hasTree(io, digest)) {
            try directory_inputs.append(allocator, .{
                .path = child_prefix,
                .digest = digest,
            });
        } else {
            try collectInputs(io, allocator, store, digest, child_prefix, inputs, directory_inputs);
            allocator.free(child_prefix);
        }
    }
}

fn validateEntryName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidDirectoryEntryName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidDirectoryEntryName;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidDirectoryEntryName;
    if (std.mem.eql(u8, name, ".")) return error.InvalidDirectoryEntryName;
    if (std.mem.eql(u8, name, "..")) return error.InvalidDirectoryEntryName;
}

fn joinPath(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn freeInputs(allocator: std.mem.Allocator, inputs: []const execroot.Input) void {
    for (inputs) |input| allocator.free(input.path);
}

fn freeDirectoryInputs(allocator: std.mem.Allocator, inputs: []const execroot.DirectoryInput) void {
    for (inputs) |input| allocator.free(input.path);
}

fn putProto(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    value: anytype,
) !cas.Digest {
    const bytes = try reapi.encodeAlloc(allocator, value);
    defer allocator.free(bytes);
    return try store.putBytes(io, bytes);
}

test "collectInputs preserves materialized tree directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    try store.ensureLayout(std.testing.io);

    const file_digest = try store.putBytes(std.testing.io, "leaf");
    var file_hash: [64]u8 = undefined;
    const child_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{
            .{ .name = "leaf.txt", .digest = file_digest.toReapi(&file_hash) },
        },
    });
    var child_tree_path_buffer: [cas.tree_prefix_len + 64]u8 = undefined;
    const child_tree_path = cas.treeSubPath(child_digest, &child_tree_path_buffer);
    try cas_dir.createDirPath(std.testing.io, child_tree_path);

    var child_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{
            .{ .name = "tree", .digest = child_digest.toReapi(&child_hash) },
        },
    });

    var files: std.ArrayListUnmanaged(execroot.Input) = .empty;
    defer files.deinit(std.testing.allocator);
    defer freeInputs(std.testing.allocator, files.items);
    var dirs: std.ArrayListUnmanaged(execroot.DirectoryInput) = .empty;
    defer dirs.deinit(std.testing.allocator);
    defer freeDirectoryInputs(std.testing.allocator, dirs.items);

    try collectInputs(std.testing.io, std.testing.allocator, store, root_digest, "", &files, &dirs);

    try std.testing.expectEqual(@as(usize, 0), files.items.len);
    try std.testing.expectEqual(@as(usize, 1), dirs.items.len);
    try std.testing.expectEqualStrings("tree", dirs.items[0].path);
    try std.testing.expect(dirs.items[0].digest.eql(child_digest));
}

test "collectOutputFiles uploads requested output files and directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    try work_dir.createDirPath(std.testing.io, "out");
    try work_dir.writeFile(std.testing.io, .{
        .sub_path = "out/file.txt",
        .data = "artifact",
        .flags = .{ .permissions = .executable_file },
    });
    try work_dir.createDirPath(std.testing.io, "tree/sub");
    try work_dir.writeFile(std.testing.io, .{
        .sub_path = "tree/sub/file.txt",
        .data = "leaf",
    });

    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.testing.allocator.alloc(u8, 0),
    };
    defer outcome.deinit(std.testing.allocator);

    try collectOutputFiles(std.testing.io, std.testing.allocator, store, work_dir, .{
        .output_paths = &.{ "out/file.txt", "tree" },
    }, &outcome);

    try std.testing.expectEqual(@as(usize, 1), outcome.output_files.len);
    try std.testing.expectEqualStrings("out/file.txt", outcome.output_files[0].path);
    try std.testing.expect(outcome.output_files[0].is_executable);
    const output = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.output_files[0].digest);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("artifact", output);

    try std.testing.expectEqual(@as(usize, 1), outcome.output_directories.len);
    try std.testing.expectEqualStrings("tree", outcome.output_directories[0].path);

    const directory_bytes = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.output_directories[0].root_digest);
    defer std.testing.allocator.free(directory_bytes);
    var directory_reader = protobuf.Reader.init(directory_bytes);
    var directory = try reapi.Directory.decodeOwned(std.testing.allocator, &directory_reader);
    defer directory.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), directory.directories.len);
    try std.testing.expectEqualStrings("sub", directory.directories[0].name);

    var result = try actionResultFromOutcomeOwned(std.testing.allocator, outcome);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.result.output_directories.len);
    try std.testing.expectEqualStrings("tree", result.result.output_directories[0].path);
    var root_hash: [64]u8 = undefined;
    try std.testing.expect(result.result.output_directories[0].root_directory_digest.?.eql(outcome.output_directories[0].root_digest.toReapi(&root_hash)));
}

test "prepareOutputParents creates parent directories for declared outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    try prepareOutputParents(std.testing.io, work_dir, .{
        .output_files = &.{"gen/out.txt"},
    });
    _ = try work_dir.statFile(std.testing.io, "gen", .{});
}

test "prepareOutputParents creates parent directories for declared output paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    try prepareOutputParents(std.testing.io, work_dir, .{
        .output_paths = &.{"bazel-out/bin/pkg/out.txt"},
    });
    _ = try work_dir.statFile(std.testing.io, "bazel-out/bin/pkg", .{});
}

test "prepareOutputParents accepts Bazel-style external output paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const output_path =
        "bazel-out/darwin_arm64-fastbuild/bin/external/rules_zig++zig+zig_0.16.0_aarch64-macos/zig_toolchain.version_validation";

    try prepareOutputParents(std.testing.io, work_dir, .{
        .output_paths = &.{output_path},
    });
    _ = try work_dir.statFile(std.testing.io, "bazel-out/darwin_arm64-fastbuild/bin/external/rules_zig++zig+zig_0.16.0_aarch64-macos", .{});
}
