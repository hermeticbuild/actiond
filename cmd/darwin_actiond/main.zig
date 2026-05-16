const std = @import("std");
const Io = std.Io;
const actiond = @import("actiond");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) {
        const options = try actiond.host_server.parseServeArgs(args[2..]);
        return actiond.host_server.serve(io, std.heap.smp_allocator, options);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "serve-vm")) {
        const options = try actiond.darwin_vm_host.parseServeVmArgs(args[2..]);
        return actiond.darwin_vm_host.serve(io, std.heap.smp_allocator, options);
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\darwin-actiond zig={s} bazel={s}
        \\usage:
        \\  darwin-actiond serve [--listen=127.0.0.1:8980] [--root=/tmp/actiond]
        \\  darwin-actiond serve-vm --kernel=/path/Image --initramfs=/path/initramfs.cpio [--runtime-image=/path/runtimes.sqfs] [--listen=127.0.0.1:8980] [--root=/tmp/actiond-vm]
        \\
    , .{
        actiond.version.zig,
        actiond.version.bazel,
    });
    try stdout.flush();
}
