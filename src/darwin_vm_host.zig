const std = @import("std");
const builtin = @import("builtin");
const zstd = if (builtin.os.tag == .macos) @import("c") else struct {};
const action_cache = @import("action_cache.zig");
const action_executor = @import("action_executor.zig");
const cas = @import("cas.zig");
const control_transport_fd = @import("control_transport_fd.zig");
const darwin_vm = @import("darwin_vm.zig");
const embedded_payload = @import("embedded_payload.zig");
const grpc_http2_server = @import("grpc_http2_server.zig");
const guest_proxy = @import("guest_proxy.zig");
const reapi_dispatch = @import("reapi_dispatch.zig");

pub const Error = error{
    MissingServeArgumentValue,
    MissingVmInitramfs,
    MissingVmKernel,
    UnknownServeArgument,
};

const max_compressed_initramfs_bytes = 128 * 1024 * 1024;
const max_raw_initramfs_bytes = 512 * 1024 * 1024;
const max_compressed_kernel_bytes = 128 * 1024 * 1024;
const max_raw_kernel_bytes = 512 * 1024 * 1024;
const max_runtime_image_bytes = 512 * 1024 * 1024;
const zstd_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

pub const ServeVmOptions = struct {
    listen: []const u8 = "127.0.0.1:8980",
    root: []const u8 = "/tmp/actiond-vm",
    cas: ?[]const u8 = null,
    kernel: ?[]const u8 = null,
    initramfs: ?[]const u8 = null,
    runtime_image: ?[]const u8 = null,
    actiondfs_fstype: []const u8 = action_executor.default_actiondfs_fstype,
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
        } else if (std.mem.eql(u8, arg, "--actiondfs-fstype")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            try action_executor.validateActiondfsFSType(args[i]);
            options.actiondfs_fstype = args[i];
        } else if (std.mem.startsWith(u8, arg, "--actiondfs-fstype=")) {
            const value = arg["--actiondfs-fstype=".len..];
            try action_executor.validateActiondfsFSType(value);
            options.actiondfs_fstype = value;
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
    defer cas_dir.close(io);
    try cas.Store.init(cas_dir).ensureLayout(io);

    var ac_dir = try root_dir.createDirPathOpen(io, "ac", .{});
    defer ac_dir.close(io);
    try action_cache.Store.init(ac_dir).ensureLayout(io);

    const embedded_kernel = if (options.kernel == null)
        try embedded_payload.extractFromSelf(io, allocator, root_dir, embedded_payload.kernel_name)
    else
        null;
    defer if (embedded_kernel) |path| allocator.free(path);
    const kernel_path = options.kernel orelse embedded_kernel orelse return error.MissingVmKernel;
    const raw_kernel = try prepareBootKernel(io, allocator, root_dir, kernel_path);
    defer if (raw_kernel) |path| allocator.free(path);
    const boot_kernel_path = raw_kernel orelse kernel_path;

    const embedded_initramfs = if (options.initramfs == null)
        try embedded_payload.extractFromSelf(io, allocator, root_dir, embedded_payload.initramfs_name)
    else
        null;
    defer if (embedded_initramfs) |path| allocator.free(path);
    const initramfs_path = options.initramfs orelse embedded_initramfs orelse return error.MissingVmInitramfs;
    const raw_initramfs = try prepareBootInitramfs(io, allocator, root_dir, initramfs_path);
    defer if (raw_initramfs) |path| allocator.free(path);
    const boot_initramfs_path = raw_initramfs orelse initramfs_path;

    const embedded_runtime_image = if (options.runtime_image == null)
        try embedded_payload.extractFromSelf(io, allocator, root_dir, embedded_payload.runtimes_name)
    else
        null;
    defer if (embedded_runtime_image) |path| allocator.free(path);
    const selected_runtime_image_path = options.runtime_image orelse embedded_runtime_image;
    const shared_runtime_image_path = if (selected_runtime_image_path) |path|
        try prepareRuntimeImageShare(io, allocator, root_dir, path)
    else
        null;
    defer if (shared_runtime_image_path) |path| allocator.free(path);
    const runtime_image_path = shared_runtime_image_path;

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("starting actiond VM kernel={s} initramfs={s} runtimes={s} cas={s} actiondfs_fstype={s}\n", .{
        boot_kernel_path,
        boot_initramfs_path,
        runtime_image_path orelse "<none>",
        cas_path,
        options.actiondfs_fstype,
    });
    try stderr.flush();

    var vm = try darwin_vm.Machine.start(io, allocator, .{
        .kernel_path = boot_kernel_path,
        .initramfs_path = boot_initramfs_path,
        .runtime_image_path = runtime_image_path,
        .cas_path = cas_path,
        .actiondfs_fstype = options.actiondfs_fstype,
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
    var local_server = reapi_dispatch.Server{
        .store = cas.Store.initReady(cas_dir),
        .action_cache_store = action_cache.Store.initReady(ac_dir),
    };
    var proxy = guest_proxy.Proxy{
        .transport = fd_client.transport(),
        .local_server = &local_server,
    };
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

fn prepareBootInitramfs(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    initramfs_path: []const u8,
) !?[]u8 {
    return try prepareZstdBootFile(
        io,
        allocator,
        root_dir,
        initramfs_path,
        "initramfs",
        "cpio",
        max_compressed_initramfs_bytes,
        max_raw_initramfs_bytes,
    );
}

fn prepareBootKernel(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    kernel_path: []const u8,
) !?[]u8 {
    return try prepareZstdBootFile(
        io,
        allocator,
        root_dir,
        kernel_path,
        "kernel",
        "Image",
        max_compressed_kernel_bytes,
        max_raw_kernel_bytes,
    );
}

fn prepareRuntimeImageShare(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    runtime_image_path: []const u8,
) ![]u8 {
    const image = try std.Io.Dir.cwd().readFileAlloc(
        io,
        runtime_image_path,
        allocator,
        .limited(max_runtime_image_bytes),
    );
    defer allocator.free(image);

    try root_dir.createDirPath(io, "runtime-image");
    var file = try root_dir.createFile(io, "runtime-image/runtimes.sqfs", .{ .truncate = true });
    defer file.close(io);

    var file_buffer: [128 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try file_writer.interface.writeAll(image);
    try file_writer.interface.flush();

    return try absoluteSubPath(io, allocator, root_dir, "runtime-image/runtimes.sqfs");
}

fn prepareZstdBootFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    path: []const u8,
    artifact_name: []const u8,
    raw_extension: []const u8,
    max_compressed_bytes: u64,
    max_raw_bytes: u64,
) !?[]u8 {
    const read_limit = if (max_raw_bytes > max_compressed_bytes) max_raw_bytes else max_compressed_bytes;
    const compressed = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(read_limit),
    );
    defer allocator.free(compressed);

    if (!isZstdFrame(compressed)) {
        if (std.mem.endsWith(u8, path, ".zst")) return error.InvalidCompressedBootArtifact;
        return null;
    }
    if (compressed.len > max_compressed_bytes) return error.FileTooBig;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(compressed, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const output_rel = try std.fmt.allocPrint(allocator, "boot/{s}-{s}.{s}", .{ artifact_name, digest_hex, raw_extension });
    defer allocator.free(output_rel);

    try root_dir.createDirPath(io, "boot");
    if (root_dir.statFile(io, output_rel, .{})) |stat| {
        if (stat.kind == .file) return try absoluteSubPath(io, allocator, root_dir, output_rel);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const raw = try decompressZstdAlloc(allocator, compressed, max_raw_bytes);
    defer allocator.free(raw);

    var file = try root_dir.createFile(io, output_rel, .{ .truncate = true });
    defer file.close(io);
    var file_buffer: [128 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try file_writer.interface.writeAll(raw);
    try file_writer.interface.flush();

    return try absoluteSubPath(io, allocator, root_dir, output_rel);
}

fn decompressZstdAlloc(allocator: std.mem.Allocator, compressed: []const u8, max_raw_bytes: u64) ![]u8 {
    const content_size = zstd.ZSTD_getFrameContentSize(compressed.ptr, compressed.len);
    if (content_size == zstdContentSizeError()) return error.InvalidCompressedBootArtifact;
    if (content_size == zstdContentSizeUnknown()) return error.UnknownCompressedBootArtifactSize;
    if (content_size > max_raw_bytes) return error.FileTooBig;

    const raw = try allocator.alloc(u8, @intCast(content_size));
    errdefer allocator.free(raw);
    const actual_size = zstd.ZSTD_decompress(raw.ptr, raw.len, compressed.ptr, compressed.len);
    if (zstd.ZSTD_isError(actual_size) != 0) return error.InvalidCompressedBootArtifact;
    if (actual_size != raw.len) return error.InvalidCompressedBootArtifact;
    return raw;
}

fn zstdContentSizeUnknown() c_ulonglong {
    return std.math.maxInt(c_ulonglong);
}

fn zstdContentSizeError() c_ulonglong {
    return std.math.maxInt(c_ulonglong) - 1;
}

fn isZstdFrame(bytes: []const u8) bool {
    return bytes.len >= zstd_magic.len and std.mem.eql(u8, bytes[0..zstd_magic.len], &zstd_magic);
}

fn absoluteSubPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    sub_path: []const u8,
) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try root_dir.realPath(io, &root_buffer);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_buffer[0..root_len], sub_path });
}

test "parseServeVmArgs accepts VM flags" {
    const options = try parseServeVmArgs(&.{
        "--listen=127.0.0.1:9999",
        "--root",
        "/tmp/actiond-vm-test",
        "--kernel",
        "/tmp/Image",
        "--initramfs=/tmp/initramfs.cpio.zst",
        "--runtime-image=/tmp/runtimes.sqfs",
        "--actiondfs-fstype=actiondfs_vec",
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
    try std.testing.expectEqualStrings("/tmp/initramfs.cpio.zst", options.initramfs.?);
    try std.testing.expectEqualStrings("/tmp/runtimes.sqfs", options.runtime_image.?);
    try std.testing.expectEqualStrings("actiondfs_vec", options.actiondfs_fstype);
    try std.testing.expectEqualStrings("/tmp/actiond-cas", options.cas.?);
    try std.testing.expectEqual(@as(u64, 768), options.memory_mib);
    try std.testing.expectEqual(@as(u32, 3), options.cpus);
    try std.testing.expectEqual(@as(u32, 1234), options.start_timeout_ms);
    try std.testing.expectEqual(@as(u32, 5678), options.connect_timeout_ms);
}

test "parseServeVmArgs permits embedded VM artifacts" {
    const options = try parseServeVmArgs(&.{});
    try std.testing.expectEqual(@as(?[]const u8, null), options.kernel);
    try std.testing.expectEqual(@as(?[]const u8, null), options.initramfs);
    try std.testing.expectEqualStrings(action_executor.default_actiondfs_fstype, options.actiondfs_fstype);
    try std.testing.expectError(error.MissingServeArgumentValue, parseServeVmArgs(&.{ "--kernel", "/tmp/Image", "--initramfs" }));
    try std.testing.expectError(error.UnknownServeArgument, parseServeVmArgs(&.{ "--kernel=/tmp/Image", "--initramfs=/tmp/initramfs", "--bad" }));
    try std.testing.expectError(error.UnsupportedActiondfsFSType, parseServeVmArgs(&.{ "--actiondfs-fstype=badfs" }));
}

test "prepareBootInitramfs leaves raw initramfs paths unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "initramfs.cpio",
        .data = "raw initramfs",
    });
    const raw_path = try absoluteSubPath(std.testing.io, std.testing.allocator, tmp.dir, "initramfs.cpio");
    defer std.testing.allocator.free(raw_path);

    try std.testing.expectEqual(@as(?[]u8, null), try prepareBootInitramfs(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        raw_path,
    ));
}

test "prepareBootKernel inflates zstd payloads without relying on filename suffix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const plain = "raw arm64 Image";
    const compressed = try compressZstdForTest(std.testing.allocator, plain);
    defer std.testing.allocator.free(compressed);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "embedded-linux-kernel",
        .data = compressed,
    });
    const compressed_path = try absoluteSubPath(std.testing.io, std.testing.allocator, tmp.dir, "embedded-linux-kernel");
    defer std.testing.allocator.free(compressed_path);

    const raw_path = (try prepareBootKernel(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        compressed_path,
    )).?;
    defer std.testing.allocator.free(raw_path);

    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, raw_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(plain, raw);
}

test "isZstdFrame detects zstd magic" {
    try std.testing.expect(isZstdFrame(&zstd_magic));
    try std.testing.expect(!isZstdFrame("not zstd"));
}

test "decompressZstdAlloc inflates libzstd frames" {
    const plain = "initramfs payload";
    const compressed = try compressZstdForTest(std.testing.allocator, plain);
    defer std.testing.allocator.free(compressed);

    const decompressed = try decompressZstdAlloc(std.testing.allocator, compressed, max_raw_initramfs_bytes);
    defer std.testing.allocator.free(decompressed);
    try std.testing.expectEqualStrings(plain, decompressed);
}

fn compressZstdForTest(allocator: std.mem.Allocator, plain: []const u8) ![]u8 {
    const bound = zstd.ZSTD_compressBound(plain.len);
    if (zstd.ZSTD_isError(bound) != 0) return error.ZstdCompressBoundFailed;

    const compressed = try allocator.alloc(u8, bound);
    defer allocator.free(compressed);
    const compressed_len = zstd.ZSTD_compress(compressed.ptr, compressed.len, plain.ptr, plain.len, 19);
    if (zstd.ZSTD_isError(compressed_len) != 0) return error.ZstdCompressFailed;

    return try allocator.dupe(u8, compressed[0..compressed_len]);
}
