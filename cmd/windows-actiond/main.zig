const std = @import("std");
const Io = std.Io;
const actiond = @import("actiond");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 1 and std.mem.eql(u8, args[1], "serve-vm")) {
        const options = try actiond.vm_host.parseServeVmArgs(args[2..]);
        return actiond.windows_vm_host.serve(io, std.heap.smp_allocator, options);
    }

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        \\windows-actiond zig={s} bazel={s}
        \\usage:
        \\  windows-actiond serve-vm --kernel=C:\\path\\kernel --initramfs=C:\\path\\initramfs.cpio[.zst] --runtime-image=C:\\path\\runtimes.sqfs [--cas-image=C:\\path\\cas.vhd] [--listen=127.0.0.1:8980] [--root=C:\\path\\root]
        \\
    , .{ actiond.version.zig, actiond.version.bazel });
    try stdout.flush();
}
