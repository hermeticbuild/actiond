const std = @import("std");

const dir_mode: u32 = 0o040755;
const file_mode: u32 = 0o100755;
const module_mode: u32 = 0o100644;
const max_input_file_bytes = 512 * 1024 * 1024;

const Entry = struct {
    name: []const u8,
    mode: u32,
    data: []const u8 = "",
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
    for ([_][]const u8{ "dev", "proc", "sys", "tmp", "work", "cas", "modules" }) |path| {
        try addDir(arena, &entries, path);
    }
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
        } else {
            const data = try std.Io.Dir.cwd().readFileAlloc(io, arg, arena, .limited(max_input_file_bytes));
            const dest = try std.fmt.allocPrint(arena, "modules/{s}", .{std.fs.path.basename(arg)});
            try addFile(arena, &entries, dest, module_mode, data);
        }
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    for (entries.items, 1..) |entry, ino| {
        try writeEntry(&out.writer, @intCast(ino), entry);
    }
    try writeEntry(&out.writer, @intCast(entries.items.len + 1), .{
        .name = "TRAILER!!!",
        .mode = 0,
    });

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try file_writer.interface.writeAll(out.writer.buffered());
    try file_writer.interface.flush();
}

fn usage(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll("usage: initramfs_newc OUT ACTIOND [MODULE...] [--file=SRC=DEST]\n");
    try stderr.flush();
    return error.InvalidArguments;
}

fn addDir(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    raw_path: []const u8,
) !void {
    const path = stripSlashes(raw_path);
    if (path.len == 0 or contains(entries.items, path, dir_mode)) return;
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
    if (contains(entries.items, path, mode)) return;
    try entries.append(allocator, .{
        .name = try allocator.dupe(u8, path),
        .mode = mode,
        .data = data,
    });
}

fn contains(entries: []const Entry, name: []const u8, mode: u32) bool {
    _ = mode;
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
    try writeHex(writer, 0);
    try writeHex(writer, 0);
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
