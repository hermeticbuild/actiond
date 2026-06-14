const builtin = @import("builtin");
const std = @import("std");
const qemu_vm = @import("qemu_vm.zig");
const vm_host = @import("vm_host.zig");

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: vm_host.ServeVmOptions,
    comptime embedded_qemu: type,
) !void {
    if (comptime builtin.os.tag != .linux or (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64)) {
        return error.UnsupportedHost;
    }
    if (!std.mem.eql(u8, embedded_qemu.target_arch, @tagName(builtin.cpu.arch))) return error.UnsupportedHost;

    var prepared = try vm_host.prepareVmStorage(io, allocator, options);
    defer prepared.deinit(io, allocator);

    prepared.assets.kernel = options.kernel orelse qemu_vm.embedded_kernel_path;
    prepared.assets.initramfs = options.initramfs orelse qemu_vm.embedded_initramfs_path;
    prepared.assets.runtime_image = options.runtime_image orelse qemu_vm.embedded_runtime_image_path;
    if (options.kernel != null) {
        prepared.owned_boot_kernel_path = try vm_host.prepareBootKernel(io, allocator, prepared.root_dir, prepared.assets.kernel);
    }
    prepared.boot_kernel_path = prepared.owned_boot_kernel_path orelse prepared.assets.kernel;
    if (options.initramfs != null) {
        prepared.owned_boot_initramfs_path = try vm_host.prepareBootInitramfs(io, allocator, prepared.root_dir, prepared.assets.initramfs);
    }
    prepared.boot_initramfs_path = prepared.owned_boot_initramfs_path orelse prepared.assets.initramfs;

    const expects_firmware = std.mem.eql(u8, embedded_qemu.target_arch, "x86_64");
    if ((embedded_qemu.firmware != null) != expects_firmware) return error.InvalidQemuAssets;

    std.log.info("starting QEMU VM kernel={s} initramfs={s} runtimes={s} cas={s}", .{
        prepared.boot_kernel_path,
        prepared.boot_initramfs_path,
        prepared.assets.runtime_image,
        prepared.cas_image_path,
    });
    var machine = try qemu_vm.Machine.start(io, allocator, .{
        .qemu_system_name = embedded_qemu.qemu_system_name,
        .machine = embedded_qemu.machine,
        .target_arch = embedded_qemu.target_arch,
        .kernel_path = prepared.boot_kernel_path,
        .initramfs_path = prepared.boot_initramfs_path,
        .runtime_image_path = prepared.assets.runtime_image,
        .cas_image_path = prepared.cas_image_path,
        .firmware_path = if (embedded_qemu.firmware != null) qemu_vm.embedded_firmware_path else null,
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
