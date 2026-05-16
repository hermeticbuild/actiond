const std = @import("std");
const Io = std.Io;
const actiond = @import("actiond");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 0 and std.mem.eql(u8, std.fs.path.basename(args[0]), "init")) {
        return actiond.guest_init.run(io);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--guest-init")) {
        return actiond.guest_init.run(io);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--guest-worker")) {
        return actiond.guest_worker.run(io);
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        "linux-actiond-guest zig={s} bazel={s}\nusage: linux-actiond-guest [--guest-init|--guest-worker]\n",
        .{
            actiond.version.zig,
            actiond.version.bazel,
        },
    );
    try stdout.flush();
}
