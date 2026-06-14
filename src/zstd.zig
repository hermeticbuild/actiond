const std = @import("std");

const magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

pub fn decompressAlloc(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    max_raw_bytes: u64,
) ![]u8 {
    const content_size = ZSTD_getFrameContentSize(compressed.ptr, compressed.len);
    if (content_size == contentSizeError()) return error.InvalidZstdFrame;
    if (content_size == contentSizeUnknown()) return error.UnknownZstdContentSize;
    if (content_size > max_raw_bytes) return error.FileTooBig;

    const raw = try allocator.alloc(u8, @intCast(content_size));
    errdefer allocator.free(raw);
    const actual_size = ZSTD_decompress(raw.ptr, raw.len, compressed.ptr, compressed.len);
    if (ZSTD_isError(actual_size) != 0 or actual_size != raw.len) return error.InvalidZstdFrame;
    return raw;
}

pub fn isFrame(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], &magic);
}

fn contentSizeUnknown() c_ulonglong {
    return std.math.maxInt(c_ulonglong);
}

fn contentSizeError() c_ulonglong {
    return std.math.maxInt(c_ulonglong) - 1;
}

extern fn ZSTD_getFrameContentSize(src: *const anyopaque, src_size: usize) c_ulonglong;
extern fn ZSTD_decompress(dst: *anyopaque, dst_capacity: usize, src: *const anyopaque, compressed_size: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;
