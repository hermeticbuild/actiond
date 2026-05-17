const builtin = @import("builtin");
const std = @import("std");
const action_cache = @import("action_cache.zig");
const action_runner = @import("action_runner.zig");
const cas = @import("cas.zig");
const execroot = @import("execroot.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");
const tree_service = @import("tree_service.zig");

pub const Error = error{
    MissingActionBlob,
    MissingCommandDigest,
    MissingCommandBlob,
    MissingDirectoryBlob,
    MissingDirectoryDigest,
    MissingFileDigest,
    MissingInputBlob,
    MissingInputRootDigest,
    MissingRuntimeRoot,
    OutputParentCreateFailed,
    InvalidDirectoryEntryName,
    UnsupportedLibcRuntime,
    UnsupportedOutputDirectoryEntry,
    UnsupportedRuntimeArch,
};

const max_output_file_bytes = 1024 * 1024 * 1024;

pub const ExecuteOptions = struct {
    runtime_root_path: ?[]const u8 = null,
};

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

    const libc_runtime = try libcRuntimeFromPlatform(action.platform);
    const use_workspace_chroot = options.runtime_root_path != null;
    var exec_root_dir = work_root;
    var workspace_dir: ?std.Io.Dir = null;
    defer if (workspace_dir) |*dir| dir.close(io);

    var exec_root_path_owned: ?[]u8 = null;
    defer if (exec_root_path_owned) |path| allocator.free(path);
    const exec_root_path = if (use_workspace_chroot) path: {
        try work_root.createDirPath(io, "workspace");
        workspace_dir = try work_root.openDir(io, "workspace", .{});
        exec_root_dir = workspace_dir.?;
        const value = try std.fmt.allocPrint(allocator, "{s}/workspace", .{work_root_path});
        exec_root_path_owned = value;
        break :path value;
    } else work_root_path;

    const materializer = execroot.Materializer.init(store, exec_root_dir);
    var materialization = materializer.materializeInputs(io, allocator, inputs.items, .{
        .chroot_root_path = exec_root_path,
        .directory_inputs = directory_inputs.items,
    }) catch |err| switch (err) {
        error.FileNotFound, error.MissingInputTree => return error.MissingInputBlob,
        else => return err,
    };
    defer materialization.deinit(allocator);
    prepareOutputParents(io, exec_root_dir, command) catch |err| switch (err) {
        error.FileNotFound => return error.OutputParentCreateFailed,
        else => return err,
    };

    const chroot_cwd_prefix = if (use_workspace_chroot) "/workspace" else "";
    var chroot_cwd_owned: ?[]u8 = null;
    defer if (chroot_cwd_owned) |path| allocator.free(path);
    const chroot_cwd = if (command.working_directory.len == 0) cwd: {
        break :cwd if (use_workspace_chroot) "/workspace" else "/";
    } else cwd: {
        try execroot.validatePath(command.working_directory);
        const value = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ chroot_cwd_prefix, command.working_directory });
        chroot_cwd_owned = value;
        break :cwd value;
    };

    var bind_mounts: std.ArrayListUnmanaged(action_runner.BindMount) = .empty;
    const borrowed_bind_mount_count = materialization.bind_mounts.len;
    defer {
        for (bind_mounts.items[borrowed_bind_mount_count..]) |mount| {
            allocator.free(mount.source);
            allocator.free(mount.target);
        }
        bind_mounts.deinit(allocator);
    }
    try bind_mounts.appendSlice(allocator, materialization.bind_mounts);
    if (options.runtime_root_path) |runtime_root| {
        if (libc_runtime == null) {
            try appendCommonRuntimeMounts(io, allocator, work_root, work_root_path, runtime_root, &bind_mounts);
        }
    }
    if (libc_runtime) |libc| {
        const runtime_root = options.runtime_root_path orelse return error.MissingRuntimeRoot;
        try appendLibcRuntimeMounts(io, allocator, work_root, work_root_path, runtime_root, libc, &bind_mounts);
    }

    var outcome = try action_runner.runCommandWithOptions(io, allocator, store, command, .{
        .chroot_dir = work_root_path,
        .chroot_cwd = chroot_cwd,
        .bind_mounts = bind_mounts.items,
        .cgroup_limits = action_runner.CgroupLimits.fromPlatform(action.platform),
    });
    errdefer outcome.deinit(allocator);
    try collectOutputFiles(io, allocator, store, exec_root_dir, command, &outcome);
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

fn libcRuntimeFromPlatform(platform: ?reapi.Platform) !?[]const u8 {
    const value = platform orelse return null;
    for (value.properties) |property| {
        if (!std.mem.eql(u8, property.name, "libc")) continue;
        if (property.value.len == 0 or std.mem.eql(u8, property.value, "none")) return null;
        if (std.mem.eql(u8, property.value, "glibc2.31")) return "glibc2.31";
        if (std.mem.eql(u8, property.value, "glibc2.35")) return "glibc2.35";
        if (std.mem.eql(u8, property.value, "glibc2.39")) return "glibc2.39";
        return error.UnsupportedLibcRuntime;
    }
    return null;
}

fn runtimeArch() ![]const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => error.UnsupportedRuntimeArch,
    };
}

fn appendCommonRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    runtime_root_path: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    const runtime_root = try std.fmt.allocPrint(allocator, "{s}/common/root", .{runtime_root_path});
    defer allocator.free(runtime_root);
    _ = try appendRuntimeMountIfExists(io, allocator, chroot_dir, chroot_path, runtime_root, "etc", "etc", bind_mounts);
}

fn appendLibcRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    runtime_root_path: []const u8,
    libc: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    const arch = try runtimeArch();
    const runtime_root = try std.fmt.allocPrint(allocator, "{s}/libc/{s}/{s}/root", .{ runtime_root_path, libc, arch });
    defer allocator.free(runtime_root);

    try appendFirstExistingRuntimeMount(io, allocator, chroot_dir, chroot_path, runtime_root, &.{ "lib", "usr/lib" }, "lib", bind_mounts);
    try appendFirstExistingRuntimeMount(io, allocator, chroot_dir, chroot_path, runtime_root, &.{ "lib64", "usr/lib64" }, "lib64", bind_mounts);
    _ = try appendRuntimeMountIfExists(io, allocator, chroot_dir, chroot_path, runtime_root, "usr/lib", "usr/lib", bind_mounts);
    _ = try appendRuntimeMountIfExists(io, allocator, chroot_dir, chroot_path, runtime_root, "etc", "etc", bind_mounts);
}

fn appendFirstExistingRuntimeMount(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    runtime_root: []const u8,
    source_candidates: []const []const u8,
    target_rel: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    for (source_candidates) |source_rel| {
        if (try appendRuntimeMountIfExists(io, allocator, chroot_dir, chroot_path, runtime_root, source_rel, target_rel, bind_mounts)) return;
    }
}

fn appendRuntimeMountIfExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    runtime_root: []const u8,
    source_rel: []const u8,
    target_rel: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !bool {
    const source = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ runtime_root, source_rel }, 0);
    errdefer allocator.free(source);
    std.Io.Dir.cwd().access(io, source, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(source);
            return false;
        },
        else => |e| return e,
    };

    try chroot_dir.createDirPath(io, target_rel);
    const target = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ chroot_path, target_rel }, 0);
    errdefer allocator.free(target);
    try bind_mounts.append(allocator, .{
        .source = source,
        .target = target,
    });
    return true;
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
            .tree_digest = try appendDigest(allocator, &hash_strings, output_directory.tree_digest),
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
    const root_digest = try putDirectoryTree(io, allocator, store, dir);
    try materializeOutputTreeDirectory(io, store, work_root, path, root_digest);
    const tree_digest = try putTreeProto(io, allocator, store, root_digest);

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    try output_directories.append(allocator, .{
        .path = path_copy,
        .tree_digest = tree_digest,
    });
}

fn putTreeProto(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    root_digest: cas.Digest,
) !cas.Digest {
    var root_hash: [64]u8 = undefined;
    var tree = try tree_service.getTree(io, allocator, store, .{
        .root_digest = root_digest.toReapi(&root_hash),
    });
    defer tree.deinit(allocator);

    return try putProto(io, allocator, store, reapi.Tree{
        .root = tree.response.directories[0],
        .children = tree.response.directories[1..],
    });
}

fn materializeOutputTreeDirectory(
    io: std.Io,
    store: cas.Store,
    work_root: std.Io.Dir,
    output_path: []const u8,
    root_digest: cas.Digest,
) !void {
    var tree_path_buffer: [cas.tree_prefix_len + 64]u8 = undefined;
    const tree_path = cas.treeSubPath(root_digest, &tree_path_buffer);
    const stat = store.root.statFile(io, tree_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (stat) |value| {
        if (value.kind == .directory) return;
        return error.UnsupportedOutputDirectoryEntry;
    }

    try store.root.createDirPath(io, tree_path);
    var src = try work_root.openDir(io, output_path, .{ .iterate = true });
    defer src.close(io);
    var dest = try store.root.openDir(io, tree_path, .{ .iterate = true });
    defer dest.close(io);
    try copyDirectoryContents(io, src, dest);
}

fn copyDirectoryContents(
    io: std.Io,
    src: std.Io.Dir,
    dest: std.Io.Dir,
) !void {
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => try copyFile(io, src, dest, entry.name),
            .directory => {
                try dest.createDirPath(io, entry.name);
                var src_child = try src.openDir(io, entry.name, .{ .iterate = true });
                defer src_child.close(io);
                var dest_child = try dest.openDir(io, entry.name, .{ .iterate = true });
                defer dest_child.close(io);
                try copyDirectoryContents(io, src_child, dest_child);
            },
            else => return error.UnsupportedOutputDirectoryEntry,
        }
    }
}

fn copyFile(
    io: std.Io,
    src_dir: std.Io.Dir,
    dest_dir: std.Io.Dir,
    name: []const u8,
) !void {
    const stat = try src_dir.statFile(io, name, .{});
    var src = try src_dir.openFile(io, name, .{});
    defer src.close(io);
    var dest = try dest_dir.createFile(io, name, .{
        .truncate = true,
        .permissions = if (isExecutable(stat)) .executable_file else .default_file,
    });
    defer dest.close(io);

    var buffer: [128 * 1024]u8 = undefined;
    while (true) {
        const n = try readFd(src.handle, &buffer);
        if (n == 0) break;
        try writeFdAll(dest.handle, buffer[0..n]);
    }
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

fn readFd(fd: std.Io.File.Handle, buffer: []u8) !usize {
    while (true) {
        const rc = std.posix.system.read(fd, buffer.ptr, buffer.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

fn writeFdAll(fd: std.Io.File.Handle, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteFailed;
                offset += n;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

test "libc runtime platform property accepts pinned runtimes" {
    try std.testing.expectEqualStrings("glibc2.31", (try libcRuntimeFromPlatform(.{
        .properties = &.{.{ .name = "libc", .value = "glibc2.31" }},
    })).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try libcRuntimeFromPlatform(.{
        .properties = &.{.{ .name = "libc", .value = "none" }},
    }));
    try std.testing.expectError(error.UnsupportedLibcRuntime, libcRuntimeFromPlatform(.{
        .properties = &.{.{ .name = "libc", .value = "glibc2.17" }},
    }));
}

test "appendLibcRuntimeMounts maps runtime directories into chroot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const arch = try runtimeArch();
    const runtime_usr_lib = try std.fmt.allocPrint(std.testing.allocator, "runtimes/libc/glibc2.35/{s}/root/usr/lib", .{arch});
    defer std.testing.allocator.free(runtime_usr_lib);
    const runtime_etc = try std.fmt.allocPrint(std.testing.allocator, "runtimes/libc/glibc2.35/{s}/root/etc", .{arch});
    defer std.testing.allocator.free(runtime_etc);
    try tmp.dir.createDirPath(std.testing.io, runtime_usr_lib);
    try tmp.dir.createDirPath(std.testing.io, runtime_etc);
    try tmp.dir.createDirPath(std.testing.io, "chroot");

    var chroot_dir = try tmp.dir.openDir(std.testing.io, "chroot", .{});
    defer chroot_dir.close(std.testing.io);

    var base_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buffer);
    const base_path = base_buffer[0..base_len];
    const runtime_root_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/runtimes", .{base_path});
    defer std.testing.allocator.free(runtime_root_path);
    const chroot_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/chroot", .{base_path});
    defer std.testing.allocator.free(chroot_path);

    var bind_mounts: std.ArrayListUnmanaged(action_runner.BindMount) = .empty;
    defer {
        for (bind_mounts.items) |mount| {
            std.testing.allocator.free(mount.source);
            std.testing.allocator.free(mount.target);
        }
        bind_mounts.deinit(std.testing.allocator);
    }

    try appendLibcRuntimeMounts(
        std.testing.io,
        std.testing.allocator,
        chroot_dir,
        chroot_path,
        runtime_root_path,
        "glibc2.35",
        &bind_mounts,
    );

    try std.testing.expectEqual(@as(usize, 3), bind_mounts.items.len);
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[0].target, "/chroot/lib"));
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[1].target, "/chroot/usr/lib"));
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[2].target, "/chroot/etc"));
}

test "appendCommonRuntimeMounts maps runtime etc into chroot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "runtimes/common/root/etc");
    try tmp.dir.createDirPath(std.testing.io, "chroot");

    var chroot_dir = try tmp.dir.openDir(std.testing.io, "chroot", .{});
    defer chroot_dir.close(std.testing.io);

    var base_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buffer);
    const base_path = base_buffer[0..base_len];
    const runtime_root_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/runtimes", .{base_path});
    defer std.testing.allocator.free(runtime_root_path);
    const chroot_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/chroot", .{base_path});
    defer std.testing.allocator.free(chroot_path);

    var bind_mounts: std.ArrayListUnmanaged(action_runner.BindMount) = .empty;
    defer {
        for (bind_mounts.items) |mount| {
            std.testing.allocator.free(mount.source);
            std.testing.allocator.free(mount.target);
        }
        bind_mounts.deinit(std.testing.allocator);
    }

    try appendCommonRuntimeMounts(
        std.testing.io,
        std.testing.allocator,
        chroot_dir,
        chroot_path,
        runtime_root_path,
        &bind_mounts,
    );

    try std.testing.expectEqual(@as(usize, 1), bind_mounts.items.len);
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[0].source, "/runtimes/common/root/etc"));
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[0].target, "/chroot/etc"));
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

    const tree_bytes = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.output_directories[0].tree_digest);
    defer std.testing.allocator.free(tree_bytes);
    var tree_reader = protobuf.Reader.init(tree_bytes);
    while (try tree_reader.next()) |tag| switch (tag.field_number) {
        1 => {
            var nested = try tree_reader.readMessage();
            var directory = try reapi.Directory.decodeOwned(std.testing.allocator, &nested);
            defer directory.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), directory.directories.len);
            try std.testing.expectEqualStrings("sub", directory.directories[0].name);
        },
        else => try tree_reader.skipField(tag.wire_type),
    };

    var tree_dir = try work_dir.openDir(std.testing.io, "tree", .{ .iterate = true });
    defer tree_dir.close(std.testing.io);
    const root_digest = try putDirectoryTree(std.testing.io, std.testing.allocator, store, tree_dir);
    var tree_path_buffer: [cas.tree_prefix_len + 64]u8 = undefined;
    const materialized_tree = cas.treeSubPath(root_digest, &tree_path_buffer);
    const materialized_stat = try cas_dir.statFile(std.testing.io, materialized_tree, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, materialized_stat.kind);

    var result = try actionResultFromOutcomeOwned(std.testing.allocator, outcome);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.result.output_directories.len);
    try std.testing.expectEqualStrings("tree", result.result.output_directories[0].path);
    var tree_hash: [64]u8 = undefined;
    try std.testing.expect(result.result.output_directories[0].tree_digest.?.eql(outcome.output_directories[0].tree_digest.toReapi(&tree_hash)));
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
