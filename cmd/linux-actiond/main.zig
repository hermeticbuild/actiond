const std = @import("std");
const Io = std.Io;
const actiond = @import("actiond");
const embedded_assets = @import("actiond_embedded_assets");
const embedded_qemu = @import("actiond_embedded_qemu");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 1 and std.mem.eql(u8, args[1], actiond.qemu_vm.fexec_argument)) {
        if (args.len < 3) return error.MissingQemuArguments;
        try actiond.qemu_vm.fexecEmbedded(
            io,
            arena,
            init.minimal.environ,
            embedded_qemu.qemu_system,
            args[2..],
        );
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "serve-vm")) {
        const options = try actiond.vm_host.parseServeVmArgs(args[2..]);
        return actiond.linux_vm_host.serve(io, std.heap.smp_allocator, options, embedded_assets, embedded_qemu);
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        \\linux-actiond zig={s} bazel={s}
        \\usage:
        \\  linux-actiond serve-vm [--kernel=/path/kernel] [--initramfs=/path/initramfs.cpio[.zst]] [--runtime-image=/path/runtimes.sqfs] [--cas-image=/path/cas.ext4] [--listen=127.0.0.1:8980] [--root=/tmp/actiond-vm] [--actiondfs-stats-path=/path/stats.txt]
        \\
    , .{ actiond.version.zig, actiond.version.bazel });
    try stdout.flush();
}
