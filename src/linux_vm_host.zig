const builtin = @import("builtin");
const std = @import("std");
const qemu_vm = @import("qemu_vm.zig");
const vm_host = @import("vm_host.zig");

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: vm_host.ServeVmOptions,
    comptime embedded_assets: type,
    comptime embedded_qemu: type,
) !void {
    if (comptime builtin.os.tag != .linux or (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64)) {
        return error.UnsupportedHost;
    }
    if (!std.mem.eql(u8, embedded_qemu.target_arch, @tagName(builtin.cpu.arch))) return error.UnsupportedHost;

    var prepared = try vm_host.prepareVm(io, allocator, options, embedded_assets);
    defer prepared.deinit(io, allocator);

    if ((embedded_qemu.bios_256k == null) != (embedded_qemu.linuxboot_dma == null)) return error.InvalidQemuAssets;
    try materializeQemuFile(io, allocator, prepared.root_dir, "qemu/bios-256k.bin", embedded_qemu.bios_256k);
    try materializeQemuFile(io, allocator, prepared.root_dir, "qemu/linuxboot_dma.bin", embedded_qemu.linuxboot_dma);
    const qemu_data_path: ?[]u8 = if (embedded_qemu.bios_256k != null)
        try vm_host.absoluteSubPath(io, allocator, prepared.root_dir, "qemu")
    else
        null;
    defer if (qemu_data_path) |path| allocator.free(path);

    std.log.info("starting QEMU VM kernel={s} initramfs={s} runtimes={s} cas={s}", .{
        prepared.boot_kernel_path,
        prepared.boot_initramfs_path,
        prepared.assets.runtime_image,
        prepared.cas_image_path,
    });
    var machine = try qemu_vm.Machine.start(io, allocator, .{
        .qemu_system_name = embedded_qemu.qemu_system_name,
        .accel = embedded_qemu.accel,
        .machine = embedded_qemu.machine,
        .target_arch = embedded_qemu.target_arch,
        .kernel_path = prepared.boot_kernel_path,
        .initramfs_path = prepared.boot_initramfs_path,
        .runtime_image_path = prepared.assets.runtime_image,
        .cas_image_path = prepared.cas_image_path,
        .qemu_data_path = qemu_data_path,
        .format_cas_image = prepared.format_cas_image,
        .memory_mib = options.memory_mib,
        .cpu_count = options.cpus,
        .start_timeout_ms = options.start_timeout_ms,
        .connect_timeout_ms = options.connect_timeout_ms,
    });
    defer machine.deinit();

    std.log.info("actiond QEMU VM started; proxying gRPC to linux-actiond-guest", .{});
    return vm_host.serveGrpcBridge(io, allocator, options, &machine);
}

fn materializeQemuFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    path: []const u8,
    bytes: ?[]const u8,
) !void {
    const contents = bytes orelse return;
    const absolute_path = try vm_host.materializeEmbeddedFile(io, allocator, root_dir, path, contents);
    allocator.free(absolute_path);
}
