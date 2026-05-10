const builtin = @import("builtin");
const std = @import("std");
const vsock = @import("vsock.zig");

pub const Error = error{
    UnsupportedHost,
};

pub fn run(io: std.Io) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const listener = try vsock.listen(vsock.control_port);
    defer listener.close();

    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("linux-actiond guest worker listening on vsock:{d}\n", .{vsock.control_port});
    try stderr.flush();

    while (true) {
        const connection = try listener.accept();
        connection.close();
    }
}

test "guest worker is Linux-only" {
    if (comptime builtin.os.tag != .linux) {
        try std.testing.expectError(error.UnsupportedHost, run(std.testing.io));
    }
}
