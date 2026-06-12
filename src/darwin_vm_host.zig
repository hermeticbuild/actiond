const std = @import("std");
const control_protocol = @import("control_protocol.zig");
const control_transport_fd = @import("control_transport_fd.zig");
const darwin_vm = @import("darwin_vm.zig");
const grpc_vsock_bridge = @import("grpc_vsock_bridge.zig");
const vm_host = @import("vm_host.zig");

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: vm_host.ServeVmOptions,
    comptime embedded_assets: type,
) !void {
    var root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.root, .{});
    defer root_dir.close(io);

    const owned_cas_image_path = if (options.cas_image == null)
        try std.fs.path.join(allocator, &.{ options.root, "cas.ext4" })
    else
        "";
    defer if (options.cas_image == null) allocator.free(owned_cas_image_path);
    const cas_image_path = options.cas_image orelse owned_cas_image_path;
    const format_cas_image = try ensureCasImageFile(io, cas_image_path, options.cas_image_size_mib);

    var assets = try vm_host.resolveAssets(io, allocator, root_dir, options, embedded_assets);
    defer assets.deinit(allocator);

    const raw_kernel = try vm_host.prepareBootKernel(io, allocator, root_dir, assets.kernel);
    defer if (raw_kernel) |path| allocator.free(path);
    const boot_kernel_path = raw_kernel orelse assets.kernel;

    const raw_initramfs = try vm_host.prepareBootInitramfs(io, allocator, root_dir, assets.initramfs);
    defer if (raw_initramfs) |path| allocator.free(path);
    const boot_initramfs_path = raw_initramfs orelse assets.initramfs;

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("starting actiond VM kernel={s} initramfs={s} runtimes={s} cas_image={s} format_cas_image={}\n", .{
        boot_kernel_path,
        boot_initramfs_path,
        assets.runtime_image,
        cas_image_path,
        format_cas_image,
    });
    try stderr.flush();

    var vm = try darwin_vm.Machine.start(io, allocator, .{
        .kernel_path = boot_kernel_path,
        .initramfs_path = boot_initramfs_path,
        .runtime_image_path = assets.runtime_image,
        .cas_image_path = cas_image_path,
        .format_cas_image = format_cas_image,
        .memory_mib = options.memory_mib,
        .cpu_count = options.cpus,
        .start_timeout_ms = options.start_timeout_ms,
        .connect_timeout_ms = options.connect_timeout_ms,
    });
    defer vm.deinit();

    try stderr.print("actiond VM started; proxying gRPC to linux-actiond-guest\n", .{});
    try stderr.flush();

    var fd_client = control_transport_fd.Client{ .opener = vm.opener() };
    defer fd_client.deinit(io);
    var background_tasks: std.Io.Group = .init;
    defer background_tasks.cancel(io);
    if (options.actiondfs_stats_path) |path| {
        const stats_path = try allocator.dupe(u8, path);
        errdefer allocator.free(stats_path);
        try background_tasks.concurrent(io, actiondfsStatsTask, .{ io, allocator, &fd_client, stats_path });
    }
    return grpc_vsock_bridge.serve(io, options.listen, &vm);
}

fn actiondfsStatsTask(
    io: std.Io,
    allocator: std.mem.Allocator,
    client: *control_transport_fd.Client,
    path: []const u8,
) !void {
    defer allocator.free(path);
    while (true) {
        writeActiondfsStatsSnapshot(io, allocator, client, path) catch |err| {
            std.log.warn("actiondfs stats snapshot failed: {s}", .{@errorName(err)});
        };
        try io.sleep(.fromMilliseconds(1_000), .awake);
    }
}

fn writeActiondfsStatsSnapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    client: *control_transport_fd.Client,
    path: []const u8,
) !void {
    var response = try client.call(io, allocator, .{
        .kind = .unary,
        .method = control_protocol.actiondfs_stats_method,
        .body = "",
    });
    defer response.deinit(allocator);
    if (response.status != .ok) return error.GuestApplicationError;

    try createParentDirs(io, path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = response.body,
        .flags = .{ .read = true, .permissions = .default_file },
    });
}

fn createParentDirs(io: std.Io, path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    try std.Io.Dir.cwd().createDirPath(io, path[0..slash]);
}

fn ensureCasImageFile(io: std.Io, path: []const u8, size_mib: u64) !bool {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
        if (stat.kind != .file) return error.InvalidCasImage;
        return false;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try createParentDirs(io, path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    const size_bytes = try std.math.mul(u64, size_mib, 1024 * 1024);
    try file.setLength(io, size_bytes);
    return true;
}
