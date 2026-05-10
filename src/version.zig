pub const bazel = "9.1.0";
pub const zig = "0.16.0";

test "tool versions are pinned" {
    const std = @import("std");

    try std.testing.expectEqualStrings("9.1.0", bazel);
    try std.testing.expectEqualStrings("0.16.0", zig);
}
