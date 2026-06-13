const builtin = @import("builtin");
const std = @import("std");
const firecracker_vm = @import("firecracker_vm.zig");
const vm_host = @import("vm_host.zig");

const pmem_alignment_bytes = 2 * 1024 * 1024;

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: vm_host.ServeVmOptions,
) !void {
    if (comptime builtin.os.tag != .linux or (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64)) {
        return error.UnsupportedHost;
    }
    var root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.root, .{});
    defer root_dir.close(io);

    const owned_cas_image_path = if (options.cas_image == null)
        try std.fs.path.join(allocator, &.{ options.root, "cas.ext4" })
    else
        null;
    defer if (owned_cas_image_path) |path| allocator.free(path);
    const cas_image_path = options.cas_image orelse owned_cas_image_path.?;
    if (options.cas_image_size_mib % 2 != 0) return error.InvalidCasImage;
    const format_cas_image = try vm_host.ensureCasImageFile(io, cas_image_path, options.cas_image_size_mib);
    const cas_image_stat = try std.Io.Dir.cwd().statFile(io, cas_image_path, .{});
    try validatePmemImageSize(cas_image_stat.size);
    const absolute_cas_image_path = try vm_host.absolutePath(io, allocator, cas_image_path);
    defer allocator.free(absolute_cas_image_path);

    const vsock_path = try std.fs.path.join(allocator, &.{ options.root, "firecracker.vsock" });
    defer allocator.free(vsock_path);
    std.Io.Dir.cwd().deleteFile(io, vsock_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const absolute_vsock_path = try vm_host.absolutePath(io, allocator, vsock_path);
    defer allocator.free(absolute_vsock_path);

    std.log.info("starting Firecracker VM cas={s} vsock={s}", .{ absolute_cas_image_path, absolute_vsock_path });
    var machine = try firecracker_vm.Machine.start(io, allocator, .{
        .kernel_path = options.kernel,
        .initramfs_path = options.initramfs,
        .runtime_image_path = options.runtime_image,
        .cas_image_path = absolute_cas_image_path,
        .vsock_path = absolute_vsock_path,
        .format_cas_image = format_cas_image,
        .memory_mib = options.memory_mib,
        .cpu_count = options.cpus,
        .start_timeout_ms = options.start_timeout_ms,
        .connect_timeout_ms = options.connect_timeout_ms,
    });
    defer machine.deinit();

    std.log.info("actiond Firecracker VM started; proxying gRPC to linux-actiond-guest", .{});
    return vm_host.serveGrpcBridge(io, allocator, options, &machine);
}

fn validatePmemImageSize(size: u64) !void {
    if (size == 0 or size % pmem_alignment_bytes != 0) return error.InvalidCasImage;
}

test "Firecracker pmem images require 2 MiB alignment" {
    try validatePmemImageSize(pmem_alignment_bytes);
    try validatePmemImageSize(8 * 1024 * 1024);
    try std.testing.expectError(error.InvalidCasImage, validatePmemImageSize(0));
    try std.testing.expectError(error.InvalidCasImage, validatePmemImageSize(3 * 1024 * 1024));
}
