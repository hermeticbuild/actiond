const reapi = @import("reapi.zig");

pub fn getCapabilities(_: reapi.GetCapabilitiesRequest) reapi.ServerCapabilities {
    return .{
        .cache_capabilities = .{
            .digest_functions = &.{.sha256},
            .action_cache_update_capabilities = .{ .update_enabled = true },
            .max_batch_total_size_bytes = 4 * 1024 * 1024,
            .symlink_absolute_path_strategy = .allowed,
        },
        .execution_capabilities = .{
            .digest_function = .sha256,
            .exec_enabled = true,
            .digest_functions = &.{.sha256},
        },
        .low_api_version = .{ .major = 2, .minor = 0, .patch = 0 },
        .high_api_version = .{ .major = 2, .minor = 3, .patch = 0 },
    };
}

test "getCapabilities advertises SHA-256 cache and execution" {
    const caps = getCapabilities(.{});
    try @import("std").testing.expect(caps.cache_capabilities.?.action_cache_update_capabilities.?.update_enabled);
    try @import("std").testing.expectEqual(reapi.DigestFunction.sha256, caps.cache_capabilities.?.digest_functions[0]);
    try @import("std").testing.expect(caps.execution_capabilities.?.exec_enabled);
}

test "getCapabilities advertises allowed absolute symlinks in REAPI field 5" {
    const testing = @import("std").testing;
    const cache_capabilities = getCapabilities(.{}).cache_capabilities.?;
    try testing.expectEqual(reapi.SymlinkAbsolutePathStrategy.allowed, cache_capabilities.symlink_absolute_path_strategy);

    const encoded = try reapi.encodeAlloc(testing.allocator, cache_capabilities);
    defer testing.allocator.free(encoded);
    try testing.expectEqualSlices(u8, &.{ 0x28, 0x02 }, encoded[encoded.len - 2 ..]);
}
