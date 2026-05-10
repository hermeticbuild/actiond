const std = @import("std");
const action_cache = @import("action_cache.zig");
const cas = @import("cas.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    MissingActionDigest,
    MissingActionResult,
};

pub fn updateActionResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: action_cache.Store,
    request: reapi.UpdateActionResultRequest,
) !reapi.ActionResult {
    const action_digest = try cas.Digest.fromReapi(request.action_digest orelse return error.MissingActionDigest);
    const result = request.action_result orelse return error.MissingActionResult;
    try store.put(io, allocator, action_digest, result);
    return result;
}

pub fn getActionResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: action_cache.Store,
    request: reapi.GetActionResultRequest,
) !action_cache.Entry {
    const action_digest = try cas.Digest.fromReapi(request.action_digest orelse return error.MissingActionDigest);
    return try store.get(io, allocator, action_digest);
}

test "updateActionResult writes a result that getActionResult reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = action_cache.Store.init(tmp.dir);
    const action_digest = cas.Digest.fromBytes("action");
    const stdout_digest = cas.Digest.fromBytes("stdout");

    var action_hash: [64]u8 = undefined;
    var stdout_hash: [64]u8 = undefined;
    _ = try updateActionResult(std.testing.io, std.testing.allocator, store, .{
        .action_digest = action_digest.toReapi(&action_hash),
        .action_result = .{
            .exit_code = 9,
            .stdout_digest = stdout_digest.toReapi(&stdout_hash),
        },
    });

    var entry = try getActionResult(std.testing.io, std.testing.allocator, store, .{
        .action_digest = action_digest.toReapi(&action_hash),
    });
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 9), entry.result.exit_code);
    try std.testing.expect(entry.result.stdout_digest.?.eql(stdout_digest.toReapi(&stdout_hash)));
}
