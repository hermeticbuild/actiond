const std = @import("std");
const action_cache = @import("action_cache.zig");
const action_executor = @import("action_executor.zig");
const cas = @import("cas.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    MissingActionDigest,
};

var next_work_id = std.atomic.Value(u64).init(0);

pub const CompletedOperation = struct {
    operation: reapi.Operation,
    operation_name: []u8,
    response_value: []const u8,

    pub fn deinit(self: *CompletedOperation, allocator: std.mem.Allocator) void {
        allocator.free(self.operation_name);
        allocator.free(self.response_value);
        self.* = undefined;
    }
};

pub fn execute(
    io: std.Io,
    allocator: std.mem.Allocator,
    blob_store: cas.Store,
    result_store: ?action_cache.Store,
    work_root: std.Io.Dir,
    request: reapi.ExecuteRequest,
    options: action_executor.ExecuteOptions,
) !CompletedOperation {
    const action_digest = try cas.Digest.fromReapi(request.action_digest orelse return error.MissingActionDigest);

    if (!request.skip_cache_lookup) {
        if (result_store) |store| {
            var cached_entry: ?action_cache.Entry = store.get(io, allocator, action_digest) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (cached_entry) |*entry| {
                defer entry.deinit(allocator);
                return try completedOperation(allocator, action_digest, entry.result, true);
            }
        }
    }

    const do_not_cache = try readDoNotCache(io, allocator, blob_store, action_digest);
    const work_path = try executionWorkKey(allocator, action_digest);
    defer allocator.free(work_path);
    var work_dir = try work_root.createDirPathOpen(io, work_path, .{});
    defer work_root.deleteTree(io, work_path) catch |err| {
        std.log.warn("failed to remove action work directory {s}: {s}", .{ work_path, @errorName(err) });
    };
    defer work_dir.close(io);

    var outcome = try action_executor.executeActionWithOptions(io, allocator, blob_store, work_dir, action_digest, options);
    defer outcome.deinit(allocator);

    var result = try action_executor.actionResultFromOutcomeOwned(allocator, outcome);
    defer result.deinit(allocator);
    if (!do_not_cache) {
        if (result_store) |store| try store.put(io, allocator, action_digest, result.result);
    }

    return try completedOperation(allocator, action_digest, result.result, false);
}

fn readDoNotCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    action_digest: cas.Digest,
) !bool {
    const action_bytes = try store.readAlloc(io, allocator, action_digest);
    defer allocator.free(action_bytes);
    var reader = protobuf.Reader.init(action_bytes);
    return (try reapi.Action.decode(&reader)).do_not_cache;
}

fn completedOperation(
    allocator: std.mem.Allocator,
    action_digest: cas.Digest,
    result: reapi.ActionResult,
    cached_result: bool,
) !CompletedOperation {
    const operation_name = try operationKey(allocator, "operations", action_digest);
    errdefer allocator.free(operation_name);

    const execute_response = reapi.ExecuteResponse{
        .result = result,
        .cached_result = cached_result,
        .status = .{},
    };
    const packed_response = try execute_response.toAny(allocator);
    errdefer allocator.free(packed_response.value);

    return .{
        .operation = .{
            .name = operation_name,
            .done = true,
            .response = packed_response,
        },
        .operation_name = operation_name,
        .response_value = packed_response.value,
    };
}

fn operationKey(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    digest: cas.Digest,
) ![]u8 {
    var hash: [64]u8 = undefined;
    return try std.fmt.allocPrint(
        allocator,
        "{s}/{s}-{d}",
        .{ prefix, digest.formatHex(&hash), digest.size_bytes },
    );
}

fn executionWorkKey(
    allocator: std.mem.Allocator,
    digest: cas.Digest,
) ![]u8 {
    const id = next_work_id.fetchAdd(1, .monotonic);
    var hash: [64]u8 = undefined;
    return try std.fmt.allocPrint(
        allocator,
        "exec/{s}-{d}-{d}",
        .{ digest.formatHex(&hash), digest.size_bytes, id },
    );
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

test "execution work keys are unique for repeated action digests" {
    const digest = cas.Digest.fromBytes("same action");
    const first = try executionWorkKey(std.testing.allocator, digest);
    defer std.testing.allocator.free(first);
    const second = try executionWorkKey(std.testing.allocator, digest);
    defer std.testing.allocator.free(second);

    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.startsWith(u8, first, "exec/"));
    try std.testing.expect(std.mem.startsWith(u8, second, "exec/"));
}

test "execute returns completed operation and populates action cache" {
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
        .arguments = &.{ "/bin/sh", "-c", "printf execute" },
    });

    var command_hash: [64]u8 = undefined;
    var root_hash: [64]u8 = undefined;
    const action_digest = try putProto(std.testing.io, std.testing.allocator, blob_store, reapi.Action{
        .command_digest = command_digest.toReapi(&command_hash),
        .input_root_digest = root_directory_digest.toReapi(&root_hash),
    });

    var action_hash: [64]u8 = undefined;
    var operation = try execute(std.testing.io, std.testing.allocator, blob_store, result_store, work_dir, .{
        .action_digest = action_digest.toReapi(&action_hash),
    }, .{});
    defer operation.deinit(std.testing.allocator);

    try std.testing.expect(operation.operation.done);
    try std.testing.expect(operation.operation.response != null);
    try std.testing.expectEqualStrings(reapi.execute_response_type_url, operation.operation.response.?.type_url);

    var response_reader = protobuf.Reader.init(operation.operation.response.?.value);
    const response = try reapi.ExecuteResponse.decode(&response_reader);
    try std.testing.expect(!response.cached_result);
    try std.testing.expectEqual(@as(i32, 0), response.result.?.exit_code);

    var cached_operation = try execute(std.testing.io, std.testing.allocator, blob_store, result_store, work_dir, .{
        .action_digest = action_digest.toReapi(&action_hash),
    }, .{});
    defer cached_operation.deinit(std.testing.allocator);

    var cached_response_reader = protobuf.Reader.init(cached_operation.operation.response.?.value);
    const cached_response = try reapi.ExecuteResponse.decode(&cached_response_reader);
    try std.testing.expect(cached_response.cached_result);
    try std.testing.expectEqual(@as(i32, 0), cached_response.result.?.exit_code);
}
