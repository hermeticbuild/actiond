const std = @import("std");
const zstd = std.compress.zstd;
const c = @cImport({
    @cDefine("ZSTD_STATIC_LINKING_ONLY", "1");
    @cInclude("zstd.h");
});

const max_input_file_bytes = 512 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return usage(io);

    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(max_input_file_bytes));
    const output = try compressZstd(arena, input, c.ZSTD_maxCLevel());

    var file = try std.Io.Dir.cwd().createFile(io, args[2], .{ .truncate = true });
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try file_writer.interface.writeAll(output);
    try file_writer.interface.flush();
}

fn usage(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll("usage: zstd_file INPUT OUTPUT\n");
    try stderr.flush();
    return error.InvalidArguments;
}

fn compressZstd(allocator: std.mem.Allocator, plain: []const u8, level: c_int) ![]u8 {
    const bound = c.ZSTD_compressBound(plain.len);
    if (c.ZSTD_isError(bound) != 0) return error.ZstdCompressBoundFailed;

    const output_buffer = try allocator.alloc(u8, bound);
    defer allocator.free(output_buffer);

    const context = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = c.ZSTD_freeCCtx(context);

    const compressed_len = c.ZSTD_compressCCtx(
        context,
        output_buffer.ptr,
        output_buffer.len,
        plain.ptr,
        plain.len,
        level,
    );
    if (c.ZSTD_isError(compressed_len) != 0) return error.ZstdCompressFailed;

    return try allocator.dupe(u8, output_buffer[0..compressed_len]);
}

test "max-level zstd compression round trips" {
    const plain = "kernel kernel kernel payload payload";
    const compressed = try compressZstd(std.testing.allocator, plain, c.ZSTD_maxCLevel());
    defer std.testing.allocator.free(compressed);

    var input = std.Io.Reader.fixed(compressed);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var window: [zstd.default_window_len + zstd.block_size_max]u8 = undefined;
    var decompressor: zstd.Decompress = .init(&input, &window, .{});
    const n = try decompressor.reader.streamRemaining(&output.writer);

    try std.testing.expectEqual(plain.len, n);
    try std.testing.expectEqualStrings(plain, output.writer.buffered());
}
