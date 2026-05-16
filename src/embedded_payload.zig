const std = @import("std");

pub const Error = error{
    CorruptEmbeddedPayload,
    DuplicateEmbeddedPayload,
    InvalidEmbeddedPayloadName,
    NoEmbeddedPayload,
};

pub const runtimes_name = "runtimes.sqfs";
pub const kernel_name = "linux_kernel";
pub const initramfs_name = "initramfs.cpio";

const magic = "ACTIOND_PAYLOAD_V1";
const trailer_len = 8 + magic.len;
const copy_buffer_len = 128 * 1024;
const hex_chars = "0123456789abcdef";

pub const PayloadSpec = struct {
    name: []const u8,
    path: []const u8,
};

const Entry = struct {
    name: []const u8,
    offset: u64,
    size: u64,
    hash: [32]u8,
};

pub fn appendPayloads(
    io: std.Io,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    base_path: []const u8,
    payloads: []const PayloadSpec,
) !void {
    var output = try std.Io.Dir.cwd().createFile(io, output_path, .{
        .read = true,
        .truncate = true,
        .permissions = .executable_file,
    });
    defer output.close(io);

    var base = try std.Io.Dir.cwd().openFile(io, base_path, .{});
    defer base.close(io);

    var write_offset: u64 = 0;
    try copyFileRange(io, base, output, 0, try base.length(io), &write_offset, null);

    var manifest: std.ArrayListUnmanaged(u8) = .empty;
    defer manifest.deinit(allocator);

    for (payloads) |payload| {
        try validateName(payload.name);
        if (manifestContainsName(manifest.items, payload.name)) return error.DuplicateEmbeddedPayload;

        var file = try std.Io.Dir.cwd().openFile(io, payload.path, .{});
        defer file.close(io);

        const offset = write_offset;
        const size = try file.length(io);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        try copyFileRange(io, file, output, 0, size, &write_offset, &hasher);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        const hash_hex = std.fmt.bytesToHex(hash, .lower);
        const line = try std.fmt.allocPrint(allocator, "{s} {d} {d} {s}\n", .{
            payload.name,
            offset,
            size,
            hash_hex,
        });
        defer allocator.free(line);
        try manifest.appendSlice(allocator, line);
    }

    try output.writePositionalAll(io, manifest.items, write_offset);
    write_offset += manifest.items.len;

    var manifest_len_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &manifest_len_bytes, manifest.items.len, .little);
    try output.writePositionalAll(io, &manifest_len_bytes, write_offset);
    write_offset += manifest_len_bytes.len;
    try output.writePositionalAll(io, magic, write_offset);
    try output.sync(io);
}

pub fn extractFromSelf(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    name: []const u8,
) !?[]u8 {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);
    return extractFromExecutablePath(io, allocator, root_dir, exe_path, name);
}

pub fn extractFromExecutablePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    executable_path: []const u8,
    name: []const u8,
) !?[]u8 {
    try validateName(name);

    var executable = try std.Io.Dir.cwd().openFile(io, executable_path, .{});
    defer executable.close(io);

    const manifest = readManifest(io, allocator, executable) catch |err| switch (err) {
        error.NoEmbeddedPayload => return null,
        else => return err,
    };
    defer allocator.free(manifest);

    const entry = findEntry(manifest, name) orelse return null;
    return try extractEntry(io, allocator, root_dir, executable, entry);
}

fn extractEntry(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    executable: std.Io.File,
    entry: Entry,
) ![]u8 {
    try root_dir.createDirPath(io, "embedded");

    const hash_hex = std.fmt.bytesToHex(entry.hash, .lower);
    const output_rel = try std.fmt.allocPrint(allocator, "embedded/{s}-{s}", .{ entry.name, hash_hex });
    defer allocator.free(output_rel);

    if (root_dir.statFile(io, output_rel, .{})) |stat| {
        if (stat.kind == .file and stat.size == entry.size) {
            return try absoluteSubPath(io, allocator, root_dir, output_rel);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var output = try root_dir.createFile(io, output_rel, .{
        .read = true,
        .truncate = true,
        .permissions = .default_file,
    });
    defer output.close(io);

    var write_offset: u64 = 0;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try copyFileRange(io, executable, output, entry.offset, entry.size, &write_offset, &hasher);
    var actual_hash: [32]u8 = undefined;
    hasher.final(&actual_hash);
    if (!std.mem.eql(u8, &actual_hash, &entry.hash)) return error.CorruptEmbeddedPayload;
    try output.sync(io);

    return try absoluteSubPath(io, allocator, root_dir, output_rel);
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

fn readManifest(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) ![]u8 {
    const file_len = try file.length(io);
    if (file_len < trailer_len) return error.NoEmbeddedPayload;

    var trailer: [trailer_len]u8 = undefined;
    const trailer_offset = file_len - trailer.len;
    const trailer_read = try file.readPositionalAll(io, &trailer, trailer_offset);
    if (trailer_read != trailer.len) return error.CorruptEmbeddedPayload;
    if (!std.mem.eql(u8, trailer[8..], magic)) return error.NoEmbeddedPayload;

    const manifest_len = std.mem.readInt(u64, trailer[0..8], .little);
    if (manifest_len > file_len - trailer_len) return error.CorruptEmbeddedPayload;
    if (manifest_len > std.math.maxInt(usize)) return error.CorruptEmbeddedPayload;
    const manifest_offset = trailer_offset - manifest_len;
    const manifest = try allocator.alloc(u8, @intCast(manifest_len));
    errdefer allocator.free(manifest);
    const manifest_read = try file.readPositionalAll(io, manifest, manifest_offset);
    if (manifest_read != manifest.len) return error.CorruptEmbeddedPayload;
    return manifest;
}

fn findEntry(manifest: []const u8, name: []const u8) ?Entry {
    var it = std.mem.splitScalar(u8, manifest, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const entry_name = fields.next() orelse return null;
        const offset_text = fields.next() orelse return null;
        const size_text = fields.next() orelse return null;
        const hash_text = fields.next() orelse return null;
        if (fields.next() != null) return null;
        if (!std.mem.eql(u8, entry_name, name)) continue;
        return .{
            .name = entry_name,
            .offset = std.fmt.parseInt(u64, offset_text, 10) catch return null,
            .size = std.fmt.parseInt(u64, size_text, 10) catch return null,
            .hash = parseHash(hash_text) catch return null,
        };
    }
    return null;
}

fn manifestContainsName(manifest: []const u8, name: []const u8) bool {
    return findEntry(manifest, name) != null;
}

fn copyFileRange(
    io: std.Io,
    source: std.Io.File,
    dest: std.Io.File,
    source_offset: u64,
    size: u64,
    dest_offset: *u64,
    maybe_hasher: ?*std.crypto.hash.sha2.Sha256,
) !void {
    var buffer: [copy_buffer_len]u8 = undefined;
    var copied: u64 = 0;
    while (copied < size) {
        const remaining = size - copied;
        const chunk_len: usize = @intCast(@min(remaining, buffer.len));
        const n = try source.readPositionalAll(io, buffer[0..chunk_len], source_offset + copied);
        if (n == 0) return error.CorruptEmbeddedPayload;
        if (maybe_hasher) |hasher| hasher.update(buffer[0..n]);
        try dest.writePositionalAll(io, buffer[0..n], dest_offset.*);
        copied += n;
        dest_offset.* += n;
    }
}

fn parseHash(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.CorruptEmbeddedPayload;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*byte, i| {
        const high = try parseHexNibble(text[i * 2]);
        const low = try parseHexNibble(text[i * 2 + 1]);
        byte.* = (high << 4) | low;
    }
    return out;
}

fn parseHexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.CorruptEmbeddedPayload,
    };
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidEmbeddedPayloadName;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return error.InvalidEmbeddedPayloadName,
    };
}

test "appendPayloads and extractFromExecutablePath round trip a payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "base",
        .data = "base executable\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "payload",
        .data = "payload bytes\n",
    });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root_path = root_buffer[0..root_len];

    const base_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/base", .{root_path});
    defer std.testing.allocator.free(base_path);
    const payload_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/payload", .{root_path});
    defer std.testing.allocator.free(payload_path);
    const bundle_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bundle", .{root_path});
    defer std.testing.allocator.free(bundle_path);

    try appendPayloads(std.testing.io, std.testing.allocator, bundle_path, base_path, &.{
        .{ .name = runtimes_name, .path = payload_path },
    });

    const extracted_path = (try extractFromExecutablePath(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        bundle_path,
        runtimes_name,
    )).?;
    defer std.testing.allocator.free(extracted_path);

    const extracted = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        extracted_path,
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(extracted);
    try std.testing.expectEqualStrings("payload bytes\n", extracted);
}

test "extractFromExecutablePath returns null for binaries without payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "plain",
        .data = "plain executable\n",
    });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const plain_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plain", .{root_buffer[0..root_len]});
    defer std.testing.allocator.free(plain_path);

    try std.testing.expectEqual(@as(?[]u8, null), try extractFromExecutablePath(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        plain_path,
        runtimes_name,
    ));
}
