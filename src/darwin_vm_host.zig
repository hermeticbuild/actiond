const std = @import("std");
const darwin_vm = @import("darwin_vm.zig");
const vm_host = @import("vm_host.zig");

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: vm_host.ServeVmOptions,
    comptime embedded_assets: type,
) !void {
    var prepared = try vm_host.prepareVm(io, allocator, options, embedded_assets);
    defer prepared.deinit(io, allocator);

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("starting actiond VM kernel={s} initramfs={s} runtimes={s} cas_image={s} format_cas_image={}\n", .{
        prepared.boot_kernel_path,
        prepared.boot_initramfs_path,
        prepared.assets.runtime_image,
        prepared.cas_image_path,
        prepared.format_cas_image,
    });
    try stderr.flush();

    var vm = try darwin_vm.Machine.start(io, allocator, .{
        .kernel_path = prepared.boot_kernel_path,
        .initramfs_path = prepared.boot_initramfs_path,
        .runtime_image_path = prepared.assets.runtime_image,
        .cas_image_path = prepared.cas_image_path,
        .format_cas_image = prepared.format_cas_image,
        .memory_mib = options.memory_mib,
        .cpu_count = options.cpus,
        .start_timeout_ms = options.start_timeout_ms,
        .connect_timeout_ms = options.connect_timeout_ms,
    });
    defer vm.deinit();

    try stderr.print("actiond VM started; proxying gRPC to linux-actiond-guest\n", .{});
    try stderr.flush();

    return vm_host.serveGrpcBridge(io, allocator, options, &vm);
}
