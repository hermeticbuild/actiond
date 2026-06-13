const builtin = @import("builtin");
const std = @import("std");
const control_protocol = @import("control_protocol.zig");
const control_transport_fd = @import("control_transport_fd.zig");
const grpc_vsock_bridge = @import("grpc_vsock_bridge.zig");
const zstd_test = if (builtin.is_test) @import("c") else struct {};

const max_compressed_initramfs_bytes = 128 * 1024 * 1024;
const max_raw_initramfs_bytes = 512 * 1024 * 1024;
const cas_image_probe_size = 4096;
const ext4_magic_offset = 1024 + 56;
const ext4_magic = [_]u8{ 0x53, 0xef };
const max_compressed_kernel_bytes = 128 * 1024 * 1024;
const max_raw_kernel_bytes = 512 * 1024 * 1024;
const zstd_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };
var next_embedded_asset_temp_id = std.atomic.Value(u64).init(0);

pub const ResolvedAssets = struct {
    kernel: []const u8 = "",
    initramfs: []const u8 = "",
    runtime_image: []const u8 = "",
    owned_kernel: ?[]u8 = null,
    owned_initramfs: ?[]u8 = null,
    owned_runtime_image: ?[]u8 = null,

    pub fn deinit(self: *ResolvedAssets, allocator: std.mem.Allocator) void {
        if (self.owned_kernel) |path| allocator.free(path);
        if (self.owned_initramfs) |path| allocator.free(path);
        if (self.owned_runtime_image) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const PreparedVm = struct {
    root_dir: std.Io.Dir,
    assets: ResolvedAssets = .{},
    cas_image_path: []const u8 = "",
    owned_cas_image_path: ?[]u8 = null,
    boot_kernel_path: []const u8 = "",
    owned_boot_kernel_path: ?[]u8 = null,
    boot_initramfs_path: []const u8 = "",
    owned_boot_initramfs_path: ?[]u8 = null,
    format_cas_image: bool = false,

    pub fn deinit(self: *PreparedVm, io: std.Io, allocator: std.mem.Allocator) void {
        if (self.owned_boot_initramfs_path) |path| allocator.free(path);
        if (self.owned_boot_kernel_path) |path| allocator.free(path);
        self.assets.deinit(allocator);
        if (self.owned_cas_image_path) |path| allocator.free(path);
        self.root_dir.close(io);
        self.* = undefined;
    }
};

pub fn prepareVm(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: ServeVmOptions,
    comptime embedded_assets: type,
) !PreparedVm {
    var prepared: PreparedVm = .{
        .root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.root, .{}),
    };
    errdefer prepared.deinit(io, allocator);

    if (options.cas_image) |path| {
        prepared.cas_image_path = path;
    } else {
        prepared.owned_cas_image_path = try std.fs.path.join(allocator, &.{ options.root, "cas.ext4" });
        prepared.cas_image_path = prepared.owned_cas_image_path.?;
    }
    prepared.format_cas_image = try ensureCasImageFile(io, prepared.cas_image_path, options.cas_image_size_mib);

    prepared.assets = try resolveAssets(io, allocator, prepared.root_dir, options, embedded_assets);
    prepared.owned_boot_kernel_path = try prepareBootKernel(io, allocator, prepared.root_dir, prepared.assets.kernel);
    prepared.boot_kernel_path = prepared.owned_boot_kernel_path orelse prepared.assets.kernel;
    prepared.owned_boot_initramfs_path = try prepareBootInitramfs(io, allocator, prepared.root_dir, prepared.assets.initramfs);
    prepared.boot_initramfs_path = prepared.owned_boot_initramfs_path orelse prepared.assets.initramfs;
    return prepared;
}

pub fn resolveAssets(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    options: ServeVmOptions,
    comptime embedded: type,
) !ResolvedAssets {
    var resolved: ResolvedAssets = .{};
    errdefer resolved.deinit(allocator);

    if (options.kernel) |path| {
        resolved.kernel = path;
    } else {
        resolved.owned_kernel = try materializeEmbeddedAsset(io, allocator, root_dir, "linux_kernel", embedded.kernel);
        resolved.kernel = resolved.owned_kernel.?;
    }
    if (options.initramfs) |path| {
        resolved.initramfs = path;
    } else {
        resolved.owned_initramfs = try materializeEmbeddedAsset(io, allocator, root_dir, "initramfs.cpio.zst", embedded.initramfs);
        resolved.initramfs = resolved.owned_initramfs.?;
    }
    if (options.runtime_image) |path| {
        resolved.runtime_image = path;
    } else {
        resolved.owned_runtime_image = try materializeEmbeddedAsset(io, allocator, root_dir, "runtimes.sqfs", embedded.runtime_image);
        resolved.runtime_image = resolved.owned_runtime_image.?;
    }
    return resolved;
}

fn materializeEmbeddedAsset(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    name: []const u8,
    bytes: []const u8,
) ![]u8 {
    try root_dir.createDirPath(io, "embedded");

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const output_rel = try std.fmt.allocPrint(allocator, "embedded/{s}-{s}", .{ name, std.fmt.bytesToHex(hash, .lower) });
    defer allocator.free(output_rel);

    if (root_dir.statFile(io, output_rel, .{})) |stat| {
        if (stat.kind == .file and stat.size == bytes.len and try embeddedAssetMatches(io, root_dir, output_rel, &hash)) {
            return absoluteSubPath(io, allocator, root_dir, output_rel);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (comptime builtin.os.tag == .windows) {
        var output = try root_dir.createFile(io, output_rel, .{ .truncate = true });
        defer output.close(io);
        try writeEmbeddedAsset(io, output, bytes);
        return absoluteSubPath(io, allocator, root_dir, output_rel);
    }

    var temp_path_buffer: [64]u8 = undefined;
    var output: std.Io.File = undefined;
    const temp_path = while (true) {
        const id = next_embedded_asset_temp_id.fetchAdd(1, .monotonic);
        const path = try std.fmt.bufPrint(&temp_path_buffer, "embedded/.asset-{d}", .{id});
        output = root_dir.createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        break path;
    };
    errdefer root_dir.deleteFile(io, temp_path) catch {};
    var output_open = true;
    defer if (output_open) output.close(io);
    try writeEmbeddedAsset(io, output, bytes);
    try output.sync(io);
    output.close(io);
    output_open = false;
    root_dir.renamePreserve(temp_path, root_dir, output_rel, io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (try embeddedAssetMatches(io, root_dir, output_rel, &hash)) {
                try root_dir.deleteFile(io, temp_path);
            } else {
                try root_dir.rename(temp_path, root_dir, output_rel, io);
            }
        },
        else => |e| return e,
    };
    return absoluteSubPath(io, allocator, root_dir, output_rel);
}

fn writeEmbeddedAsset(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    const chunk_size = 64 * 1024;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + chunk_size, bytes.len);
        try file.writePositionalAll(io, bytes[offset..end], offset);
        offset = end;
    }
}

fn embeddedAssetMatches(
    io: std.Io,
    root_dir: std.Io.Dir,
    path: []const u8,
    expected_hash: *const [32]u8,
) !bool {
    var file = try root_dir.openFile(io, path, .{});
    defer file.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var hash_buffer: [64 * 1024]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const len = try file_reader.interface.readSliceShort(&hash_buffer);
        hasher.update(hash_buffer[0..len]);
        if (len != hash_buffer.len) break;
    }
    var actual_hash: [32]u8 = undefined;
    hasher.final(&actual_hash);
    return std.mem.eql(u8, &actual_hash, expected_hash);
}

pub const ServeVmOptions = struct {
    listen: []const u8 = "127.0.0.1:8980",
    root: []const u8 = if (builtin.os.tag == .windows) "actiond-vm" else "/tmp/actiond-vm",
    cas_image: ?[]const u8 = null,
    cas_image_size_mib: u64 = 32 * 1024,
    kernel: ?[]const u8 = null,
    initramfs: ?[]const u8 = null,
    runtime_image: ?[]const u8 = null,
    memory_mib: u64 = 512,
    cpus: u32 = 2,
    start_timeout_ms: u32 = 30_000,
    connect_timeout_ms: u32 = 60_000,
    actiondfs_stats_path: ?[]const u8 = null,
};

const ServeVmOption = enum {
    listen,
    root,
    @"cas-image",
    @"cas-image-size-mib",
    kernel,
    initramfs,
    @"runtime-image",
    @"memory-mib",
    cpus,
    @"start-timeout-ms",
    @"connect-timeout-ms",
    @"actiondfs-stats-path",
};

pub fn parseServeVmArgs(args: []const []const u8) !ServeVmOptions {
    var options: ServeVmOptions = .{};
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        i += 1;

        if (!std.mem.startsWith(u8, arg, "--")) return error.UnknownServeArgument;
        const equals = std.mem.indexOfScalar(u8, arg, '=');
        const name = arg[2 .. equals orelse arg.len];
        const option = std.meta.stringToEnum(ServeVmOption, name) orelse return error.UnknownServeArgument;
        const value = if (equals) |index|
            arg[index + 1 ..]
        else value: {
            if (i >= args.len) return error.MissingServeArgumentValue;
            defer i += 1;
            break :value args[i];
        };

        switch (option) {
            .listen => options.listen = value,
            .root => options.root = value,
            .@"cas-image" => options.cas_image = value,
            .@"cas-image-size-mib" => options.cas_image_size_mib = try std.fmt.parseInt(u64, value, 10),
            .kernel => options.kernel = value,
            .initramfs => options.initramfs = value,
            .@"runtime-image" => options.runtime_image = value,
            .@"memory-mib" => options.memory_mib = try std.fmt.parseInt(u64, value, 10),
            .cpus => options.cpus = try std.fmt.parseInt(u32, value, 10),
            .@"start-timeout-ms" => options.start_timeout_ms = try std.fmt.parseInt(u32, value, 10),
            .@"connect-timeout-ms" => options.connect_timeout_ms = try std.fmt.parseInt(u32, value, 10),
            .@"actiondfs-stats-path" => options.actiondfs_stats_path = value,
        }
    }
    return options;
}

pub fn prepareBootInitramfs(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    initramfs_path: []const u8,
) !?[]u8 {
    return prepareZstdBootFile(
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

pub fn prepareBootKernel(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    kernel_path: []const u8,
) !?[]u8 {
    return prepareZstdBootFile(
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
    const content_size = ZSTD_getFrameContentSize(compressed.ptr, compressed.len);
    if (content_size == zstdContentSizeError()) return error.InvalidCompressedBootArtifact;
    if (content_size == zstdContentSizeUnknown()) return error.UnknownCompressedBootArtifactSize;
    if (content_size > max_raw_bytes) return error.FileTooBig;

    const raw = try allocator.alloc(u8, @intCast(content_size));
    errdefer allocator.free(raw);
    const actual_size = ZSTD_decompress(raw.ptr, raw.len, compressed.ptr, compressed.len);
    if (ZSTD_isError(actual_size) != 0) return error.InvalidCompressedBootArtifact;
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

extern fn ZSTD_getFrameContentSize(src: *const anyopaque, src_size: usize) c_ulonglong;
extern fn ZSTD_decompress(dst: *anyopaque, dst_capacity: usize, src: *const anyopaque, compressed_size: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;

pub fn absolutePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator) catch allocator.dupe(u8, path);
    }
    if (std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator)) |absolute_path| return absolute_path else |_| {}

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPath(io, &cwd_buffer);
    return std.fs.path.join(allocator, &.{ cwd_buffer[0..cwd_len], path });
}

pub fn absoluteSubPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    sub_path: []const u8,
) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try root_dir.realPath(io, &root_buffer);
    return std.fs.path.join(allocator, &.{ root_buffer[0..root_len], sub_path });
}

pub fn ensureCasImageFile(io: std.Io, path: []const u8, size_mib: u64) !bool {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
        if (stat.kind != .file) return error.InvalidCasImage;
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var probe: [cas_image_probe_size]u8 = undefined;
        if (try file.readPositionalAll(io, &probe, 0) != probe.len) return error.InvalidCasImage;
        if (std.mem.eql(u8, probe[ext4_magic_offset..][0..ext4_magic.len], &ext4_magic)) return false;
        for (probe) |byte| if (byte != 0) return error.InvalidCasImage;
        return true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (size_mib == 0) return error.InvalidCasImage;
    try createParentDirs(io, path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    const size_bytes = try std.math.mul(u64, size_mib, 1024 * 1024);
    try file.setLength(io, size_bytes);
    return true;
}

pub fn serveGrpcBridge(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: ServeVmOptions,
    machine: anytype,
) !void {
    var fd_client = control_transport_fd.Client{ .opener = machine.opener() };
    defer fd_client.deinit(io);
    var background_tasks: std.Io.Group = .init;
    defer background_tasks.cancel(io);
    if (options.actiondfs_stats_path) |path| {
        const stats_path = try allocator.dupe(u8, path);
        errdefer allocator.free(stats_path);
        try background_tasks.concurrent(io, actiondfsStatsTask, .{ io, allocator, &fd_client, stats_path });
    }
    return grpc_vsock_bridge.serve(io, options.listen, machine);
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

test "parseServeVmArgs accepts VM flags" {
    const options = try parseServeVmArgs(&.{
        "--listen=127.0.0.1:9999",
        "--root",
        "/tmp/actiond-vm-test",
        "--kernel",
        "/tmp/Image",
        "--initramfs=/tmp/initramfs.cpio.zst",
        "--runtime-image=/tmp/runtimes.sqfs",
        "--cas-image",
        "/tmp/actiond-cas.ext4",
        "--cas-image-size-mib=4096",
        "--memory-mib=768",
        "--cpus",
        "3",
        "--start-timeout-ms=1234",
        "--connect-timeout-ms",
        "5678",
        "--actiondfs-stats-path=/tmp/actiondfs_stats.txt",
    });

    try std.testing.expectEqualStrings("127.0.0.1:9999", options.listen);
    try std.testing.expectEqualStrings("/tmp/actiond-vm-test", options.root);
    try std.testing.expectEqualStrings("/tmp/Image", options.kernel.?);
    try std.testing.expectEqualStrings("/tmp/initramfs.cpio.zst", options.initramfs.?);
    try std.testing.expectEqualStrings("/tmp/runtimes.sqfs", options.runtime_image.?);
    try std.testing.expectEqualStrings("/tmp/actiond-cas.ext4", options.cas_image.?);
    try std.testing.expectEqual(@as(u64, 4096), options.cas_image_size_mib);
    try std.testing.expectEqual(@as(u64, 768), options.memory_mib);
    try std.testing.expectEqual(@as(u32, 3), options.cpus);
    try std.testing.expectEqual(@as(u32, 1234), options.start_timeout_ms);
    try std.testing.expectEqual(@as(u32, 5678), options.connect_timeout_ms);
    try std.testing.expectEqualStrings("/tmp/actiondfs_stats.txt", options.actiondfs_stats_path.?);
}

test "parseServeVmArgs permits embedded VM artifacts" {
    const options = try parseServeVmArgs(&.{});
    try std.testing.expectEqual(@as(?[]const u8, null), options.kernel);
    try std.testing.expectEqual(@as(?[]const u8, null), options.initramfs);
    try std.testing.expectError(error.MissingServeArgumentValue, parseServeVmArgs(&.{ "--kernel", "/tmp/Image", "--initramfs" }));
    try std.testing.expectError(error.UnknownServeArgument, parseServeVmArgs(&.{ "--kernel=/tmp/Image", "--initramfs=/tmp/initramfs", "--bad" }));
}

test "materializeEmbeddedAsset caches bytes by digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try materializeEmbeddedAsset(std.testing.io, std.testing.allocator, tmp.dir, "kernel", "payload");
    defer std.testing.allocator.free(first);
    const second = try materializeEmbeddedAsset(std.testing.io, std.testing.allocator, tmp.dir, "kernel", "payload");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, first, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("payload", bytes);
}

test "materializeEmbeddedAsset replaces corrupt cached bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try materializeEmbeddedAsset(std.testing.io, std.testing.allocator, tmp.dir, "kernel", "payload");
    defer std.testing.allocator.free(first);
    var file = try std.Io.Dir.createFileAbsolute(std.testing.io, first, .{ .truncate = true });
    try file.writePositionalAll(std.testing.io, "corrupt", 0);
    file.close(std.testing.io);

    const second = try materializeEmbeddedAsset(std.testing.io, std.testing.allocator, tmp.dir, "kernel", "payload");
    defer std.testing.allocator.free(second);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, second, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("payload", bytes);
}

test "ensureCasImageFile formats blank images and preserves ext4 images" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try absoluteSubPath(std.testing.io, std.testing.allocator, tmp.dir, "cas.ext4");
    defer std.testing.allocator.free(path);

    try std.testing.expect(try ensureCasImageFile(std.testing.io, path, 1));
    try std.testing.expect(try ensureCasImageFile(std.testing.io, path, 1));

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, &ext4_magic, ext4_magic_offset);
    file.close(std.testing.io);
    try std.testing.expect(!try ensureCasImageFile(std.testing.io, path, 1));
}

test "ensureCasImageFile rejects unknown existing images" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try absoluteSubPath(std.testing.io, std.testing.allocator, tmp.dir, "cas.ext4");
    defer std.testing.allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    try file.setLength(std.testing.io, 1024 * 1024);
    try file.writePositionalAll(std.testing.io, "not ext4", 0);
    file.close(std.testing.io);
    try std.testing.expectError(error.InvalidCasImage, ensureCasImageFile(std.testing.io, path, 1));
}

test "resolveAssets preserves explicit paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const embedded = struct {
        const kernel = "embedded kernel";
        const initramfs = "embedded initramfs";
        const runtime_image = "embedded runtimes";
    };

    var resolved = try resolveAssets(std.testing.io, std.testing.allocator, tmp.dir, .{
        .kernel = "/tmp/kernel",
        .initramfs = "/tmp/initramfs",
        .runtime_image = "/tmp/runtimes",
    }, embedded);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/tmp/kernel", resolved.kernel);
    try std.testing.expectEqualStrings("/tmp/initramfs", resolved.initramfs);
    try std.testing.expectEqualStrings("/tmp/runtimes", resolved.runtime_image);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "embedded", .{}));
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
    const bound = zstd_test.ZSTD_compressBound(plain.len);
    if (zstd_test.ZSTD_isError(bound) != 0) return error.ZstdCompressBoundFailed;

    const compressed = try allocator.alloc(u8, bound);
    defer allocator.free(compressed);
    const compressed_len = zstd_test.ZSTD_compress(compressed.ptr, compressed.len, plain.ptr, plain.len, 19);
    if (zstd_test.ZSTD_isError(compressed_len) != 0) return error.ZstdCompressFailed;

    return allocator.dupe(u8, compressed[0..compressed_len]);
}
