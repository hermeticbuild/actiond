const builtin = @import("builtin");
const std = @import("std");
const zstd_test = if (builtin.is_test) @import("c") else struct {};

const max_compressed_initramfs_bytes = 128 * 1024 * 1024;
const max_raw_initramfs_bytes = 512 * 1024 * 1024;
const max_compressed_kernel_bytes = 128 * 1024 * 1024;
const max_raw_kernel_bytes = 512 * 1024 * 1024;
const zstd_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

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
