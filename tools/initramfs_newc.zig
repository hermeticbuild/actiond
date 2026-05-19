const std = @import("std");
const zstd = std.compress.zstd;
const c = @cImport({
    @cDefine("ZSTD_STATIC_LINKING_ONLY", "1");
    @cInclude("zstd.h");
});

const dir_mode: u32 = 0o040755;
const file_mode: u32 = 0o100755;
const symlink_mode: u32 = 0o120777;
const char_device_mode: u32 = 0o020666;
const max_input_file_bytes = 512 * 1024 * 1024;

const Entry = struct {
    name: []const u8,
    mode: u32,
    data: []const u8 = "",
    rdev_major: u32 = 0,
    rdev_minor: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return usage(io);

    const out_path = args[1];
    const actiond_path = args[2];
    const actiond = try std.Io.Dir.cwd().readFileAlloc(io, actiond_path, arena, .limited(max_input_file_bytes));

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    for ([_][]const u8{ "dev", "proc", "sys", "sys/fs/cgroup", "tmp", "work", "cas", "runtimes" }) |path| {
        try addDir(arena, &entries, path);
    }
    try addCharDevice(arena, &entries, "dev/console", 5, 1);
    try addCharDevice(arena, &entries, "dev/null", 1, 3);
    try addCharDevice(arena, &entries, "dev/zero", 1, 5);
    try addFile(arena, &entries, "init", file_mode, actiond);
    try addFile(arena, &entries, "actiond", file_mode, actiond);

    for (args[3..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--file=")) {
            const spec = arg["--file=".len..];
            const split = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidFileSpec;
            if (split == 0 or split + 1 >= spec.len) return error.InvalidFileSpec;
            const src = spec[0..split];
            const dest = stripLeadingSlash(spec[split + 1 ..]);
            const data = try std.Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(max_input_file_bytes));
            try addFile(arena, &entries, dest, file_mode, data);
        } else if (std.mem.startsWith(u8, arg, "--symlink=")) {
            const spec = arg["--symlink=".len..];
            const split = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidFileSpec;
            if (split == 0 or split + 1 >= spec.len) return error.InvalidFileSpec;
            const target = spec[0..split];
            const dest = stripLeadingSlash(spec[split + 1 ..]);
            try addSymlink(arena, &entries, dest, target);
        } else return usage(io);
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    for (entries.items, 1..) |entry, ino| {
        try writeEntry(&out.writer, @intCast(ino), entry);
    }
    try writeEntry(&out.writer, @intCast(entries.items.len + 1), .{
        .name = "TRAILER!!!",
        .mode = 0,
    });

    const payload = if (isZstdPath(out_path))
        try compressZstd(arena, out.writer.buffered(), initramfsZstdLevel())
    else
        out.writer.buffered();

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try file_writer.interface.writeAll(payload);
    try file_writer.interface.flush();
}

fn usage(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll("usage: initramfs_newc OUT ACTIOND [--file=SRC=DEST] [--symlink=TARGET=DEST]\n");
    try stderr.flush();
    return error.InvalidArguments;
}

fn addDir(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    raw_path: []const u8,
) !void {
    const path = stripSlashes(raw_path);
    if (path.len == 0 or containsName(entries.items, path)) return;
    const parent = std.fs.path.dirname(path);
    if (parent) |value| try addDir(allocator, entries, value);
    try entries.append(allocator, .{
        .name = try allocator.dupe(u8, path),
        .mode = dir_mode,
    });
}

fn addFile(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    raw_path: []const u8,
    mode: u32,
    data: []const u8,
) !void {
    const path = stripSlashes(raw_path);
    if (path.len == 0) return error.InvalidFileSpec;
    if (std.fs.path.dirname(path)) |parent| try addDir(allocator, entries, parent);
    if (containsName(entries.items, path)) return;
    try entries.append(allocator, .{
        .name = try allocator.dupe(u8, path),
        .mode = mode,
        .data = data,
    });
}

fn addSymlink(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    raw_path: []const u8,
    target: []const u8,
) !void {
    const path = stripSlashes(raw_path);
    if (path.len == 0 or target.len == 0) return error.InvalidFileSpec;
    if (std.fs.path.dirname(path)) |parent| try addDir(allocator, entries, parent);
    if (containsName(entries.items, path)) return;
    try entries.append(allocator, .{
        .name = try allocator.dupe(u8, path),
        .mode = symlink_mode,
        .data = try allocator.dupe(u8, target),
    });
}

fn addCharDevice(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    raw_path: []const u8,
    major: u32,
    minor: u32,
) !void {
    const path = stripSlashes(raw_path);
    if (path.len == 0) return error.InvalidFileSpec;
    if (std.fs.path.dirname(path)) |parent| try addDir(allocator, entries, parent);
    if (containsName(entries.items, path)) return;
    try entries.append(allocator, .{
        .name = try allocator.dupe(u8, path),
        .mode = char_device_mode,
        .rdev_major = major,
        .rdev_minor = minor,
    });
}

fn containsName(entries: []const Entry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn stripSlashes(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, "/");
}

fn stripLeadingSlash(path: []const u8) []const u8 {
    var start: usize = 0;
    while (start < path.len and path[start] == '/') start += 1;
    return path[start..];
}

fn writeEntry(writer: *std.Io.Writer, ino: u32, entry: Entry) !void {
    const namesize = entry.name.len + 1;
    try writer.writeAll("070701");
    try writeHex(writer, ino);
    try writeHex(writer, entry.mode);
    try writeHex(writer, 0);
    try writeHex(writer, 0);
    try writeHex(writer, if ((entry.mode & 0o040000) != 0) 2 else 1);
    try writeHex(writer, 0);
    try writeHex(writer, @intCast(entry.data.len));
    try writeHex(writer, 0);
    try writeHex(writer, 0);
    try writeHex(writer, entry.rdev_major);
    try writeHex(writer, entry.rdev_minor);
    try writeHex(writer, @intCast(namesize));
    try writeHex(writer, 0);
    try writer.writeAll(entry.name);
    try writer.writeByte(0);
    try align4(writer);
    try writer.writeAll(entry.data);
    try align4(writer);
}

fn writeHex(writer: *std.Io.Writer, value: u32) !void {
    try writer.print("{x:0>8}", .{value});
}

fn align4(writer: *std.Io.Writer) !void {
    const pad = (4 - (writer.end % 4)) % 4;
    try writer.splatByteAll(0, pad);
}

fn isZstdPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zst");
}

fn initramfsZstdLevel() c_int {
    return c.ZSTD_maxCLevel();
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

test "addSymlink creates parent directory and records target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var entries: std.ArrayListUnmanaged(Entry) = .empty;

    try addSymlink(allocator, &entries, "/bin/touch", "/usr/bin/busybox");

    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings("bin", entries.items[0].name);
    try std.testing.expectEqual(dir_mode, entries.items[0].mode);
    try std.testing.expectEqualStrings("bin/touch", entries.items[1].name);
    try std.testing.expectEqual(symlink_mode, entries.items[1].mode);
    try std.testing.expectEqualStrings("/usr/bin/busybox", entries.items[1].data);
}

test "addCharDevice records device numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var entries: std.ArrayListUnmanaged(Entry) = .empty;

    try addCharDevice(allocator, &entries, "/dev/console", 5, 1);

    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings("dev", entries.items[0].name);
    try std.testing.expectEqualStrings("dev/console", entries.items[1].name);
    try std.testing.expectEqual(char_device_mode, entries.items[1].mode);
    try std.testing.expectEqual(@as(u32, 5), entries.items[1].rdev_major);
    try std.testing.expectEqual(@as(u32, 1), entries.items[1].rdev_minor);
}

test "zstd compression round trips initramfs payload" {
    const plain = "070701 initramfs payload payload payload TRAILER!!!";
    const compressed = try compressZstd(std.testing.allocator, plain, initramfsZstdLevel());
    defer std.testing.allocator.free(compressed);

    var input = std.Io.Reader.fixed(compressed);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var window: [zstd.default_window_len + zstd.block_size_max]u8 = undefined;
    var decompressor: zstd.Decompress = .init(&input, &window, .{});
    const n = try decompressor.reader.streamRemaining(&output.writer);

    try std.testing.expectEqual(plain.len, n);
    try std.testing.expectEqualStrings(plain, output.written());
}

test "zstd compression is selected by output suffix" {
    try std.testing.expect(isZstdPath("initramfs.cpio.zst"));
    try std.testing.expect(!isZstdPath("initramfs.cpio"));
}
