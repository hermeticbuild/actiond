const std = @import("std");
const cas = @import("cas.zig");
const control_transport_fd = @import("control_transport_fd.zig");
const darwin_vm = @import("darwin_vm.zig");
const grpc_http2_server = @import("grpc_http2_server.zig");
const guest_proxy = @import("guest_proxy.zig");

pub const Error = error{
    MissingServeArgumentValue,
    MissingVmInitramfs,
    MissingVmKernel,
    UnknownServeArgument,
};

pub const ServeVmOptions = struct {
    listen: []const u8 = "127.0.0.1:8980",
    root: []const u8 = "/tmp/actiond-vm",
    cas: ?[]const u8 = null,
    kernel: ?[]const u8 = null,
    initramfs: ?[]const u8 = null,
    runtime_image: ?[]const u8 = null,
    memory_mib: u64 = 512,
    cpus: u32 = 2,
    start_timeout_ms: u32 = 30_000,
    connect_timeout_ms: u32 = 60_000,
};

pub fn parseServeVmArgs(args: []const []const u8) !ServeVmOptions {
    var options: ServeVmOptions = .{};
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--listen")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.listen = args[i];
        } else if (std.mem.startsWith(u8, arg, "--listen=")) {
            options.listen = arg["--listen=".len..];
        } else if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.root = args[i];
        } else if (std.mem.startsWith(u8, arg, "--root=")) {
            options.root = arg["--root=".len..];
        } else if (std.mem.eql(u8, arg, "--cas")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.cas = args[i];
        } else if (std.mem.startsWith(u8, arg, "--cas=")) {
            options.cas = arg["--cas=".len..];
        } else if (std.mem.eql(u8, arg, "--kernel")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.kernel = args[i];
        } else if (std.mem.startsWith(u8, arg, "--kernel=")) {
            options.kernel = arg["--kernel=".len..];
        } else if (std.mem.eql(u8, arg, "--initramfs")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.initramfs = args[i];
        } else if (std.mem.startsWith(u8, arg, "--initramfs=")) {
            options.initramfs = arg["--initramfs=".len..];
        } else if (std.mem.eql(u8, arg, "--runtime-image")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.runtime_image = args[i];
        } else if (std.mem.startsWith(u8, arg, "--runtime-image=")) {
            options.runtime_image = arg["--runtime-image=".len..];
        } else if (std.mem.eql(u8, arg, "--memory-mib")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.memory_mib = try parseU64(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--memory-mib=")) {
            options.memory_mib = try parseU64(arg["--memory-mib=".len..]);
        } else if (std.mem.eql(u8, arg, "--cpus")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.cpus = try parseU32(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--cpus=")) {
            options.cpus = try parseU32(arg["--cpus=".len..]);
        } else if (std.mem.eql(u8, arg, "--start-timeout-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.start_timeout_ms = try parseU32(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--start-timeout-ms=")) {
            options.start_timeout_ms = try parseU32(arg["--start-timeout-ms=".len..]);
        } else if (std.mem.eql(u8, arg, "--connect-timeout-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.connect_timeout_ms = try parseU32(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--connect-timeout-ms=")) {
            options.connect_timeout_ms = try parseU32(arg["--connect-timeout-ms=".len..]);
        } else {
            return error.UnknownServeArgument;
        }
        i += 1;
    }
    if (options.kernel == null) return error.MissingVmKernel;
    if (options.initramfs == null) return error.MissingVmInitramfs;
    return options;
}

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: ServeVmOptions,
) !void {
    var root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.root, .{});
    defer root_dir.close(io);

    const owned_cas_path = if (options.cas == null)
        try std.fs.path.join(allocator, &.{ options.root, "cas" })
    else
        "";
    defer if (options.cas == null) allocator.free(owned_cas_path);
    const cas_path = options.cas orelse owned_cas_path;

    var cas_dir = try std.Io.Dir.cwd().createDirPathOpen(io, cas_path, .{});
    try cas.Store.init(cas_dir).ensureLayout(io);
    cas_dir.close(io);

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("starting actiond VM kernel={s} initramfs={s} runtimes={s} cas={s}\n", .{
        options.kernel.?,
        options.initramfs.?,
        options.runtime_image orelse "<none>",
        cas_path,
    });
    try stderr.flush();

    var vm = try darwin_vm.Machine.start(allocator, .{
        .kernel_path = options.kernel.?,
        .initramfs_path = options.initramfs.?,
        .runtime_image_path = options.runtime_image,
        .cas_path = cas_path,
        .memory_mib = options.memory_mib,
        .cpu_count = options.cpus,
        .start_timeout_ms = options.start_timeout_ms,
        .connect_timeout_ms = options.connect_timeout_ms,
    });
    defer vm.deinit();

    try stderr.print("actiond VM started; proxying gRPC to guest linux-actiond\n", .{});
    try stderr.flush();

    var fd_client = control_transport_fd.Client{ .opener = vm.opener() };
    defer fd_client.deinit(io);
    var proxy = guest_proxy.Proxy{ .transport = fd_client.transport() };
    return grpc_http2_server.serveDispatcher(io, allocator, .{
        .listen = options.listen,
    }, proxy.dispatcher());
}

fn parseU32(value: []const u8) !u32 {
    return std.fmt.parseInt(u32, value, 10);
}

fn parseU64(value: []const u8) !u64 {
    return std.fmt.parseInt(u64, value, 10);
}

test "parseServeVmArgs accepts VM flags" {
    const options = try parseServeVmArgs(&.{
        "--listen=127.0.0.1:9999",
        "--root",
        "/tmp/actiond-vm-test",
        "--kernel",
        "/tmp/Image",
        "--initramfs=/tmp/initramfs.cpio",
        "--runtime-image=/tmp/runtimes.sqfs",
        "--cas",
        "/tmp/actiond-cas",
        "--memory-mib=768",
        "--cpus",
        "3",
        "--start-timeout-ms=1234",
        "--connect-timeout-ms",
        "5678",
    });

    try std.testing.expectEqualStrings("127.0.0.1:9999", options.listen);
    try std.testing.expectEqualStrings("/tmp/actiond-vm-test", options.root);
    try std.testing.expectEqualStrings("/tmp/Image", options.kernel.?);
    try std.testing.expectEqualStrings("/tmp/initramfs.cpio", options.initramfs.?);
    try std.testing.expectEqualStrings("/tmp/runtimes.sqfs", options.runtime_image.?);
    try std.testing.expectEqualStrings("/tmp/actiond-cas", options.cas.?);
    try std.testing.expectEqual(@as(u64, 768), options.memory_mib);
    try std.testing.expectEqual(@as(u32, 3), options.cpus);
    try std.testing.expectEqual(@as(u32, 1234), options.start_timeout_ms);
    try std.testing.expectEqual(@as(u32, 5678), options.connect_timeout_ms);
}

test "parseServeVmArgs requires kernel and initramfs" {
    try std.testing.expectError(error.MissingVmKernel, parseServeVmArgs(&.{}));
    try std.testing.expectError(error.MissingVmInitramfs, parseServeVmArgs(&.{"--kernel=/tmp/Image"}));
    try std.testing.expectError(error.MissingServeArgumentValue, parseServeVmArgs(&.{ "--kernel", "/tmp/Image", "--initramfs" }));
    try std.testing.expectError(error.UnknownServeArgument, parseServeVmArgs(&.{ "--kernel=/tmp/Image", "--initramfs=/tmp/initramfs", "--bad" }));
}
