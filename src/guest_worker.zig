const builtin = @import("builtin");
const std = @import("std");

pub const Error = error{
    UnsupportedHost,
};

pub fn run(io: std.Io) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll("linux-actiond guest worker ready\n");
    try stderr.flush();

    while (true) {
        _ = std.os.linux.pause();
    }
}

test "guest worker is Linux-only" {
    if (comptime builtin.os.tag != .linux) {
        try std.testing.expectError(error.UnsupportedHost, run(std.testing.io));
    }
}
