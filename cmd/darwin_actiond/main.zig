const std = @import("std");
const Io = std.Io;
const actiond = @import("actiond");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("darwin-actiond zig={s} bazel={s}\n", .{
        actiond.version.zig,
        actiond.version.bazel,
    });
    try stdout.flush();
}
