const builtin = @import("builtin");
const std = @import("std");
const control_transport_fd = @import("control_transport_fd.zig");
const grpc_vsock_bridge = @import("grpc_vsock_bridge.zig");
const qemu_vm = @import("qemu_vm.zig");
const vm_host = @import("vm_host.zig");

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: vm_host.ServeVmOptions,
    comptime embedded_assets: type,
    comptime embedded_qemu: type,
) !void {
    if (comptime builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        return error.UnsupportedHost;
    }

    var root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.root, .{});
    defer root_dir.close(io);

    const owned_cas_image_path = if (options.cas_image == null)
        try std.fs.path.join(allocator, &.{ options.root, "cas.ext4" })
    else
        "";
    defer if (options.cas_image == null) allocator.free(owned_cas_image_path);
    const cas_image_path = options.cas_image orelse owned_cas_image_path;
    const format_cas_image = try vm_host.ensureCasImageFile(io, cas_image_path, options.cas_image_size_mib);

    var assets = try vm_host.resolveAssets(io, allocator, root_dir, options, embedded_assets);
    defer assets.deinit(allocator);

    const raw_kernel = try vm_host.prepareBootKernel(io, allocator, root_dir, assets.kernel);
    defer if (raw_kernel) |path| allocator.free(path);
    const boot_kernel_path = raw_kernel orelse assets.kernel;

    const raw_initramfs = try vm_host.prepareBootInitramfs(io, allocator, root_dir, assets.initramfs);
    defer if (raw_initramfs) |path| allocator.free(path);
    const boot_initramfs_path = raw_initramfs orelse assets.initramfs;

    const bios_256k_path = try vm_host.materializeEmbeddedFile(
        io,
        allocator,
        root_dir,
        "qemu/bios-256k.bin",
        embedded_qemu.bios_256k,
    );
    defer allocator.free(bios_256k_path);
    const linuxboot_dma_path = try vm_host.materializeEmbeddedFile(
        io,
        allocator,
        root_dir,
        "qemu/linuxboot_dma.bin",
        embedded_qemu.linuxboot_dma,
    );
    defer allocator.free(linuxboot_dma_path);
    const qemu_data_path = try vm_host.absoluteSubPath(io, allocator, root_dir, "qemu");
    defer allocator.free(qemu_data_path);

    std.log.info("starting QEMU VM kernel={s} initramfs={s} runtimes={s} cas={s}", .{
        boot_kernel_path,
        boot_initramfs_path,
        assets.runtime_image,
        cas_image_path,
    });
    var machine = try qemu_vm.Machine.start(io, allocator, .{
        .kernel_path = boot_kernel_path,
        .initramfs_path = boot_initramfs_path,
        .runtime_image_path = assets.runtime_image,
        .cas_image_path = cas_image_path,
        .qemu_data_path = qemu_data_path,
        .format_cas_image = format_cas_image,
        .memory_mib = options.memory_mib,
        .cpu_count = options.cpus,
        .start_timeout_ms = options.start_timeout_ms,
        .connect_timeout_ms = options.connect_timeout_ms,
    });
    defer machine.deinit();

    std.log.info("actiond QEMU VM started; proxying gRPC to linux-actiond-guest", .{});
    var fd_client = control_transport_fd.Client{ .opener = machine.opener() };
    defer fd_client.deinit(io);
    var background_tasks: std.Io.Group = .init;
    defer background_tasks.cancel(io);
    if (options.actiondfs_stats_path) |path| {
        const stats_path = try allocator.dupe(u8, path);
        errdefer allocator.free(stats_path);
        try background_tasks.concurrent(io, vm_host.actiondfsStatsTask, .{ io, allocator, &fd_client, stats_path });
    }
    return grpc_vsock_bridge.serve(io, options.listen, &machine);
}
