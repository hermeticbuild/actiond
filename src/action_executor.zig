const std = @import("std");
const action_cache = @import("action_cache.zig");
const action_runner = @import("action_runner.zig");
const cas = @import("cas.zig");
const execroot = @import("execroot.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    MissingCommandDigest,
    MissingDirectoryDigest,
    MissingFileDigest,
    MissingInputRootDigest,
    InvalidDirectoryEntryName,
};

pub fn executeAndCacheAction(
    io: std.Io,
    allocator: std.mem.Allocator,
    blob_store: cas.Store,
    result_store: action_cache.Store,
    work_root: std.Io.Dir,
    action_digest: cas.Digest,
) !action_runner.Outcome {
    var outcome = try executeAction(io, allocator, blob_store, work_root, action_digest);
    errdefer outcome.deinit(allocator);

    var stdout_hash: [64]u8 = undefined;
    var stderr_hash: [64]u8 = undefined;
    try result_store.put(
        io,
        allocator,
        action_digest,
        actionResultFromOutcome(outcome, &stdout_hash, &stderr_hash),
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
    const action_bytes = try store.readAlloc(io, allocator, action_digest);
    defer allocator.free(action_bytes);
    var action_reader = protobuf.Reader.init(action_bytes);
    const action = try reapi.Action.decode(&action_reader);

    const command_digest = try cas.Digest.fromReapi(action.command_digest orelse return error.MissingCommandDigest);
    const command_bytes = try store.readAlloc(io, allocator, command_digest);
    defer allocator.free(command_bytes);
    var command_reader = protobuf.Reader.init(command_bytes);
    var command = try reapi.Command.decodeOwned(allocator, &command_reader);
    defer command.deinit(allocator);

    const input_root_digest = try cas.Digest.fromReapi(action.input_root_digest orelse return error.MissingInputRootDigest);
    var inputs: std.ArrayListUnmanaged(execroot.Input) = .empty;
    defer inputs.deinit(allocator);
    defer freeInputs(allocator, inputs.items);
    try collectInputs(io, allocator, store, input_root_digest, "", &inputs);

    const materializer = execroot.Materializer.init(store, work_root);
    try materializer.copyInputs(io, allocator, inputs.items);

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try work_root.realPath(io, &cwd_buffer);
    return try action_runner.runCommand(io, allocator, store, command, cwd_buffer[0..cwd_len]);
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

fn collectInputs(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    directory_digest: cas.Digest,
    prefix: []const u8,
    inputs: *std.ArrayListUnmanaged(execroot.Input),
) !void {
    const directory_bytes = try store.readAlloc(io, allocator, directory_digest);
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
        defer allocator.free(child_prefix);
        try collectInputs(io, allocator, store, digest, child_prefix, inputs);
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

test "executeAction materializes REAPI inputs and stores streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    const input_digest = try store.putBytes(std.testing.io, "hello");

    var input_hash: [64]u8 = undefined;
    const root_directory_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{
            .{
                .name = "input.txt",
                .digest = input_digest.toReapi(&input_hash),
            },
        },
    });

    const command_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Command{
        .arguments = &.{ "/bin/sh", "-c", "cat input.txt; printf '%s' err >&2" },
    });

    var command_hash: [64]u8 = undefined;
    var root_hash: [64]u8 = undefined;
    const action_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Action{
        .command_digest = command_digest.toReapi(&command_hash),
        .input_root_digest = root_directory_digest.toReapi(&root_hash),
    });

    var outcome = try executeAction(std.testing.io, std.testing.allocator, store, work_dir, action_digest);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", outcome.stdout);
    try std.testing.expectEqualStrings("err", outcome.stderr);
    try std.testing.expect(outcome.stdout_digest != null);
    try std.testing.expect(outcome.stderr_digest != null);

    switch (outcome.status) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedStatus,
    }
}

test "executeAction walks nested REAPI directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    const nested_file_digest = try store.putBytes(std.testing.io, "nested");

    var nested_file_hash: [64]u8 = undefined;
    const child_directory_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{
            .{
                .name = "value.txt",
                .digest = nested_file_digest.toReapi(&nested_file_hash),
            },
        },
    });

    var child_hash: [64]u8 = undefined;
    const root_directory_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{
            .{
                .name = "dir",
                .digest = child_directory_digest.toReapi(&child_hash),
            },
        },
    });

    const command_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Command{
        .arguments = &.{ "/bin/sh", "-c", "cat dir/value.txt" },
    });

    var command_hash: [64]u8 = undefined;
    var root_hash: [64]u8 = undefined;
    const action_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Action{
        .command_digest = command_digest.toReapi(&command_hash),
        .input_root_digest = root_directory_digest.toReapi(&root_hash),
    });

    var outcome = try executeAction(std.testing.io, std.testing.allocator, store, work_dir, action_digest);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("nested", outcome.stdout);
}

test "executeAndCacheAction stores ActionResult under action digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var ac_dir = try tmp.dir.createDirPathOpen(std.testing.io, "ac", .{});
    defer ac_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const blob_store = cas.Store.init(cas_dir);
    const result_store = action_cache.Store.init(ac_dir);

    const root_directory_digest = try putProto(std.testing.io, std.testing.allocator, blob_store, reapi.Directory{});
    const command_digest = try putProto(std.testing.io, std.testing.allocator, blob_store, reapi.Command{
        .arguments = &.{ "/bin/sh", "-c", "printf cached" },
    });

    var command_hash: [64]u8 = undefined;
    var root_hash: [64]u8 = undefined;
    const action_digest = try putProto(std.testing.io, std.testing.allocator, blob_store, reapi.Action{
        .command_digest = command_digest.toReapi(&command_hash),
        .input_root_digest = root_directory_digest.toReapi(&root_hash),
    });

    var outcome = try executeAndCacheAction(
        std.testing.io,
        std.testing.allocator,
        blob_store,
        result_store,
        work_dir,
        action_digest,
    );
    defer outcome.deinit(std.testing.allocator);

    var entry = try result_store.get(std.testing.io, std.testing.allocator, action_digest);
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 0), entry.result.exit_code);
    try std.testing.expect(entry.result.stdout_digest != null);
}
