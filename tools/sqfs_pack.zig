const std = @import("std");
const zstd = std.compress.zstd;
const c = @cImport({
    @cDefine("ZSTD_STATIC_LINKING_ONLY", "1");
    @cInclude("zstd.h");
});

const superblock_size = 96;
const metadata_size = 8192;
const block_size = 128 * 1024;
const block_log = 17;
const max_input_file_bytes = 8 * 1024 * 1024 * 1024;

const squashfs_magic = 0x7371_7368;
const zstd_compression = 6;
const invalid_u32 = 0xffff_ffff;
const invalid_u64 = 0xffff_ffff_ffff_ffff;
const uncompressed_metadata_bit = 1 << 15;
const uncompressed_data_bit = 1 << 24;

const flag_uncompressed_inodes = 1 << 0;
const flag_uncompressed_data = 1 << 1;
const flag_uncompressed_fragments = 1 << 3;
const flag_no_fragments = 1 << 4;

const Type = enum {
    directory,
    file,
};

const Ref = struct {
    block: u32 = 0,
    offset: u16 = 0,
};

const Node = struct {
    name: []const u8,
    path: []const u8,
    kind: Type,
    mode: u16,
    parent: ?u32,
    children: std.ArrayListUnmanaged(u32) = .empty,
    inode_number: u32 = 0,
    inode_ref: Ref = .{},
    dir_ref: Ref = .{},
    dir_size: u32 = 3,
    size: u64 = 0,
    data_start: u64 = 0,
    block_sizes: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.children.deinit(allocator);
        self.block_sizes.deinit(allocator);
        self.* = undefined;
    }
};

const ScanEntry = struct {
    name: []u8,
    kind: std.Io.File.Kind,

    fn deinit(self: ScanEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

const Super = struct {
    inodes: u32,
    mkfs_time: u32,
    fragments: u32,
    root_inode: u64,
    bytes_used: u64,
    id_table_start: u64,
    inode_table_start: u64,
    directory_table_start: u64,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return usage(io);

    const input_dir = args[1];
    const out_path = args[2];

    var source = try std.Io.Dir.cwd().openDir(io, input_dir, .{});
    defer source.close(io);

    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    defer {
        for (nodes.items) |*node| node.deinit(allocator);
        nodes.deinit(allocator);
    }

    try nodes.append(allocator, .{
        .name = try allocator.dupe(u8, ""),
        .path = try allocator.dupe(u8, ""),
        .kind = .directory,
        .mode = 0o755,
        .parent = null,
        .inode_number = 1,
    });
    try scanDirectory(io, allocator, source, &nodes, 0, "");

    var image: std.Io.Writer.Allocating = .init(allocator);
    defer image.deinit();
    try image.writer.splatByteAll(0, superblock_size);

    try writeFileData(io, allocator, source, &nodes, &image.writer);

    var inode_stream: std.Io.Writer.Allocating = .init(allocator);
    defer inode_stream.deinit();
    try buildInodeStream(&inode_stream.writer, nodes.items, true);

    var directory_stream: std.Io.Writer.Allocating = .init(allocator);
    defer directory_stream.deinit();
    try buildDirectoryStream(&directory_stream.writer, nodes.items);

    inode_stream.clearRetainingCapacity();
    try buildInodeStream(&inode_stream.writer, nodes.items, false);

    const inode_table_start: u64 = @intCast(image.writer.end);
    try writeMetadataStream(&image.writer, inode_stream.writer.buffered());

    const directory_table_start: u64 = @intCast(image.writer.end);
    try writeMetadataStream(&image.writer, directory_stream.writer.buffered());

    const id_metadata_start: u64 = @intCast(image.writer.end);
    var id_payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &id_payload, 0, .little);
    try writeMetadataStream(&image.writer, &id_payload);

    const id_table_start: u64 = @intCast(image.writer.end);
    try writeU64(&image.writer, id_metadata_start);

    const bytes_used: u64 = @intCast(image.writer.end);
    writeSuperblock(image.writer.buffered()[0..superblock_size], .{
        .inodes = @intCast(nodes.items.len),
        .mkfs_time = 0,
        .fragments = 0,
        .root_inode = makeInode(nodes.items[0].inode_ref),
        .bytes_used = bytes_used,
        .id_table_start = id_table_start,
        .inode_table_start = inode_table_start,
        .directory_table_start = directory_table_start,
    });
    try padTo(&image.writer, 4096);

    var out = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer out.close(io);
    var file_buffer: [128 * 1024]u8 = undefined;
    var file_writer = out.writer(io, &file_buffer);
    try file_writer.interface.writeAll(image.writer.buffered());
    try file_writer.interface.flush();
}

fn usage(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll("usage: sqfs_pack INPUT_DIR OUT\n");
    try stderr.flush();
    return error.InvalidArguments;
}

fn scanDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    nodes: *std.ArrayListUnmanaged(Node),
    parent_index: u32,
    rel_path: []const u8,
) !void {
    var dir = try root.openDir(io, if (rel_path.len == 0) "." else rel_path, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged(ScanEntry) = .empty;
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }

    std.mem.sort(ScanEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: ScanEntry, rhs: ScanEntry) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    for (entries.items) |entry| {
        if (entry.name.len == 0 or entry.name.len > 256) return error.InvalidName;
        const child_path = if (rel_path.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_path, entry.name });
        errdefer allocator.free(child_path);

        const stat = try root.statFile(io, child_path, .{});
        const child_kind: Type = switch (stat.kind) {
            .directory => .directory,
            .file => .file,
            else => return error.UnsupportedFileKind,
        };
        const child_index: u32 = @intCast(nodes.items.len);
        try nodes.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .path = child_path,
            .kind = child_kind,
            .mode = modeFromStat(stat, child_kind),
            .parent = parent_index,
            .inode_number = child_index + 1,
            .size = if (child_kind == .file) stat.size else 0,
        });
        try nodes.items[parent_index].children.append(allocator, child_index);
        if (child_kind == .directory) {
            try scanDirectory(io, allocator, root, nodes, child_index, child_path);
        }
    }
}

fn modeFromStat(stat: std.Io.Dir.Stat, kind: Type) u16 {
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        const mode: u16 = @intCast(stat.permissions.toMode() & 0o7777);
        if (mode != 0) return mode;
    }
    return switch (kind) {
        .directory => 0o755,
        .file => 0o644,
    };
}

fn writeFileData(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    nodes: *std.ArrayListUnmanaged(Node),
    writer: *std.Io.Writer,
) !void {
    var buffer = try allocator.alloc(u8, block_size);
    defer allocator.free(buffer);

    for (nodes.items) |*node| {
        if (node.kind != .file) continue;
        node.data_start = @intCast(writer.end);
        if (node.size == 0) continue;

        var file = try root.openFile(io, node.path, .{});
        defer file.close(io);

        var remaining = node.size;
        while (remaining != 0) {
            const want: usize = @intCast(@min(@as(u64, block_size), remaining));
            try readFull(file.handle, buffer[0..want]);
            const disk_size = try writeDataBlock(allocator, writer, buffer[0..want]);
            try node.block_sizes.append(allocator, disk_size);
            remaining -= want;
        }
    }
}

fn readFull(fd: std.Io.File.Handle, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        while (true) {
            const rc = std.posix.system.read(fd, buffer[offset..].ptr, buffer.len - offset);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) return error.UnexpectedEndOfFile;
                    offset += n;
                    break;
                },
                .INTR => continue,
                else => return error.ReadFailed,
            }
        }
    }
}

fn writeDataBlock(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    plain: []const u8,
) !u32 {
    const compressed = try compressZstdMax(allocator, plain);
    defer allocator.free(compressed);

    if (compressed.len < plain.len) {
        if (compressed.len > uncompressed_data_bit - 1) return error.BlockTooLarge;
        try writer.writeAll(compressed);
        return @intCast(compressed.len);
    }

    try writer.writeAll(plain);
    return uncompressed_data_bit | @as(u32, @intCast(plain.len));
}

fn buildInodeStream(writer: *std.Io.Writer, nodes: []Node, update_refs: bool) !void {
    for (nodes) |*node| {
        const ref = metadataRef(writer.end);
        if (update_refs) {
            @constCast(node).inode_ref = ref;
        } else if (node.inode_ref.block != ref.block or node.inode_ref.offset != ref.offset) {
            return error.UnstableInodeStream;
        }

        switch (node.kind) {
            .directory => try writeDirectoryInode(writer, node, nodes),
            .file => try writeRegularInode(writer, node),
        }
    }
}

fn writeDirectoryInode(writer: *std.Io.Writer, node: *const Node, nodes: []const Node) !void {
    const nlink: u32 = 2 + countChildDirectories(node, nodes);
    if (node.dir_size <= std.math.maxInt(u16)) {
        try writeU16(writer, 1);
        try writeU16(writer, node.mode);
        try writeU16(writer, 0);
        try writeU16(writer, 0);
        try writeU32(writer, 0);
        try writeU32(writer, node.inode_number);
        try writeU32(writer, node.dir_ref.block);
        try writeU32(writer, nlink);
        try writeU16(writer, @intCast(node.dir_size));
        try writeU16(writer, node.dir_ref.offset);
        try writeU32(writer, parentInode(node, nodes));
    } else {
        try writeU16(writer, 8);
        try writeU16(writer, node.mode);
        try writeU16(writer, 0);
        try writeU16(writer, 0);
        try writeU32(writer, 0);
        try writeU32(writer, node.inode_number);
        try writeU32(writer, nlink);
        try writeU32(writer, node.dir_size);
        try writeU32(writer, node.dir_ref.block);
        try writeU32(writer, parentInode(node, nodes));
        try writeU16(writer, 0);
        try writeU16(writer, node.dir_ref.offset);
        try writeU32(writer, invalid_u32);
    }
}

fn writeRegularInode(writer: *std.Io.Writer, node: *const Node) !void {
    if (node.size <= std.math.maxInt(u32) and node.data_start <= std.math.maxInt(u32)) {
        try writeU16(writer, 2);
        try writeU16(writer, node.mode);
        try writeU16(writer, 0);
        try writeU16(writer, 0);
        try writeU32(writer, 0);
        try writeU32(writer, node.inode_number);
        try writeU32(writer, @intCast(node.data_start));
        try writeU32(writer, invalid_u32);
        try writeU32(writer, 0);
        try writeU32(writer, @intCast(node.size));
    } else {
        try writeU16(writer, 9);
        try writeU16(writer, node.mode);
        try writeU16(writer, 0);
        try writeU16(writer, 0);
        try writeU32(writer, 0);
        try writeU32(writer, node.inode_number);
        try writeU64(writer, node.data_start);
        try writeU64(writer, node.size);
        try writeU64(writer, 0);
        try writeU32(writer, 1);
        try writeU32(writer, invalid_u32);
        try writeU32(writer, 0);
        try writeU32(writer, invalid_u32);
    }
    for (node.block_sizes.items) |size| try writeU32(writer, size);
}

fn countChildDirectories(node: *const Node, nodes: []const Node) u32 {
    var count: u32 = 0;
    for (node.children.items) |child_index| {
        if (nodes[child_index].kind == .directory) count += 1;
    }
    return count;
}

fn parentInode(node: *const Node, nodes: []const Node) u32 {
    if (node.parent) |parent| return nodes[parent].inode_number;
    return node.inode_number;
}

fn buildDirectoryStream(writer: *std.Io.Writer, nodes: []Node) !void {
    for (nodes) |*node| {
        if (node.kind != .directory) continue;
        const start = writer.end;
        const ref = metadataRef(start);
        @constCast(node).dir_ref = ref;

        for (node.children.items) |child_index| {
            const child = nodes[child_index];
            try writeU32(writer, 0);
            try writeU32(writer, child.inode_ref.block);
            try writeU32(writer, child.inode_number);
            try writeU16(writer, child.inode_ref.offset);
            try writeU16(writer, 0);
            try writeU16(writer, directoryEntryType(child.kind));
            try writeU16(writer, @intCast(child.name.len - 1));
            try writer.writeAll(child.name);
        }

        const dir_bytes = writer.end - start;
        if (dir_bytes + 3 > std.math.maxInt(u32)) return error.DirectoryTooLarge;
        @constCast(node).dir_size = @intCast(dir_bytes + 3);
    }
}

fn directoryEntryType(kind: Type) u16 {
    return switch (kind) {
        .directory => 1,
        .file => 2,
    };
}

fn writeMetadataStream(writer: *std.Io.Writer, payload: []const u8) !void {
    var offset: usize = 0;
    while (offset < payload.len) {
        const n = @min(metadata_size, payload.len - offset);
        const plain = payload[offset..][0..n];
        try writeU16(writer, uncompressed_metadata_bit | @as(u16, @intCast(n)));
        try writer.writeAll(plain);
        offset += n;
    }
}

fn compressZstdMax(allocator: std.mem.Allocator, plain: []const u8) ![]u8 {
    const bound = c.ZSTD_compressBound(plain.len);
    if (c.ZSTD_isError(bound) != 0) return error.ZstdCompressBoundFailed;

    const output_buffer = try allocator.alloc(u8, bound);
    defer allocator.free(output_buffer);

    const context = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = c.ZSTD_freeCCtx(context);

    const level = c.ZSTD_maxCLevel();
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

fn metadataRef(offset: usize) Ref {
    const block_index = offset / metadata_size;
    return .{
        .block = @intCast(block_index * (metadata_size + 2)),
        .offset = @intCast(offset % metadata_size),
    };
}

fn makeInode(ref: Ref) u64 {
    return (@as(u64, ref.block) << 16) | ref.offset;
}

fn writeSuperblock(dest: []u8, super: Super) void {
    var fixed = std.Io.Writer.fixed(dest);
    const writer = &fixed;
    writeU32(writer, squashfs_magic) catch unreachable;
    writeU32(writer, super.inodes) catch unreachable;
    writeU32(writer, super.mkfs_time) catch unreachable;
    writeU32(writer, block_size) catch unreachable;
    writeU32(writer, super.fragments) catch unreachable;
    writeU16(writer, zstd_compression) catch unreachable;
    writeU16(writer, block_log) catch unreachable;
    writeU16(writer, flag_uncompressed_inodes | flag_no_fragments) catch unreachable;
    writeU16(writer, 1) catch unreachable;
    writeU16(writer, 4) catch unreachable;
    writeU16(writer, 0) catch unreachable;
    writeU64(writer, super.root_inode) catch unreachable;
    writeU64(writer, super.bytes_used) catch unreachable;
    writeU64(writer, super.id_table_start) catch unreachable;
    writeU64(writer, invalid_u64) catch unreachable;
    writeU64(writer, super.inode_table_start) catch unreachable;
    writeU64(writer, super.directory_table_start) catch unreachable;
    writeU64(writer, invalid_u64) catch unreachable;
    writeU64(writer, invalid_u64) catch unreachable;
    std.debug.assert(fixed.end == superblock_size);
}

fn writeU16(writer: *std.Io.Writer, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn writeU32(writer: *std.Io.Writer, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn writeU64(writer: *std.Io.Writer, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn padTo(writer: *std.Io.Writer, alignment: usize) !void {
    const padding = (alignment - (writer.end % alignment)) % alignment;
    try writer.splatByteAll(0, padding);
}

test "metadata refs include two byte block headers" {
    try std.testing.expectEqual(Ref{ .block = 0, .offset = 0 }, metadataRef(0));
    try std.testing.expectEqual(Ref{ .block = 0, .offset = 8191 }, metadataRef(8191));
    try std.testing.expectEqual(Ref{ .block = 8194, .offset = 0 }, metadataRef(8192));
    try std.testing.expectEqual(Ref{ .block = 8194, .offset = 7 }, metadataRef(8199));
}

test "superblock writer emits squashfs v4 magic and table pointers" {
    var bytes: [superblock_size]u8 = undefined;
    writeSuperblock(&bytes, .{
        .inodes = 3,
        .mkfs_time = 0,
        .fragments = 0,
        .root_inode = 0,
        .bytes_used = 4096,
        .id_table_start = 4000,
        .inode_table_start = 128,
        .directory_table_start = 1024,
    });

    try std.testing.expectEqual(squashfs_magic, std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[4..8], .little));
    try std.testing.expectEqual(zstd_compression, std.mem.readInt(u16, bytes[20..22], .little));
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, bytes[28..30], .little));
    try std.testing.expectEqual(@as(u64, 4096), std.mem.readInt(u64, bytes[40..48], .little));
    try std.testing.expectEqual(@as(u64, 128), std.mem.readInt(u64, bytes[64..72], .little));
}

test "zstd max compression round trips" {
    const plain = "actiond runtime squashfs payload payload payload";
    const compressed = try compressZstdMax(std.testing.allocator, plain);
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

test "padTo extends to alignment without touching aligned writers" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try writer.writer.writeAll("abc");
    try padTo(&writer.writer, 4);
    try std.testing.expectEqual(@as(usize, 4), writer.writer.end);

    try padTo(&writer.writer, 4);
    try std.testing.expectEqual(@as(usize, 4), writer.writer.end);
}
