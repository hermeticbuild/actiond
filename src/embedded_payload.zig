const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    CorruptEmbeddedPayload,
    DuplicateEmbeddedPayload,
    InvalidEmbeddedPayloadName,
    NoEmbeddedPayload,
};

pub const runtimes_name = "runtimes.sqfs";
pub const kernel_name = "linux_kernel";
pub const initramfs_name = "initramfs.cpio.zst";

const magic = "ACTIOND_PAYLOAD_V1";
const trailer_len = 8 + magic.len;
const copy_buffer_len = 128 * 1024;
const hex_chars = "0123456789abcdef";
const mach_o_segment_name = "__ACTIOND";
const mach_o_kernel_section = "__kernel";
const mach_o_initramfs_section = "__initramfs";
const mach_o_runtimes_section = "__runtimes";
const mh_magic_64: u32 = 0xfeedfacf;
const lc_segment_64: u32 = 0x19;
const mach_header_64_len = 32;
const segment_command_64_len = 72;
const section_64_len = 80;

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
        error.NoEmbeddedPayload => return try extractMachOSection(io, allocator, root_dir, executable, name),
        else => return err,
    };
    defer allocator.free(manifest);

    const entry = findEntry(manifest, name) orelse return null;
    return try extractEntry(io, allocator, root_dir, executable, entry);
}

const Range = struct {
    offset: u64,
    size: u64,
};

fn extractMachOSection(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    executable: std.Io.File,
    name: []const u8,
) !?[]u8 {
    if (builtin.os.tag != .macos) return null;
    const section_name = machOSectionNameForPayload(name) orelse return null;
    const range = try findMachOSection(io, executable, mach_o_segment_name, section_name) orelse return null;
    return try extractRange(io, allocator, root_dir, executable, name, range);
}

fn machOSectionNameForPayload(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, kernel_name)) return mach_o_kernel_section;
    if (std.mem.eql(u8, name, initramfs_name)) return mach_o_initramfs_section;
    if (std.mem.eql(u8, name, runtimes_name)) return mach_o_runtimes_section;
    return null;
}

fn extractRange(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    executable: std.Io.File,
    name: []const u8,
    range: Range,
) ![]u8 {
    try root_dir.createDirPath(io, "embedded");

    const hash = try hashFileRange(io, executable, range.offset, range.size);
    const hash_hex = std.fmt.bytesToHex(hash, .lower);
    const output_rel = try std.fmt.allocPrint(allocator, "embedded/{s}-{s}", .{ name, hash_hex });
    defer allocator.free(output_rel);

    if (root_dir.statFile(io, output_rel, .{})) |stat| {
        if (stat.kind == .file and stat.size == range.size) {
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
    try copyFileRange(io, executable, output, range.offset, range.size, &write_offset, null);
    try output.sync(io);

    return try absoluteSubPath(io, allocator, root_dir, output_rel);
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

fn hashFileRange(
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    size: u64,
) ![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [copy_buffer_len]u8 = undefined;
    var read_total: u64 = 0;
    while (read_total < size) {
        const remaining = size - read_total;
        const chunk_len: usize = @intCast(@min(remaining, buffer.len));
        const n = try file.readPositionalAll(io, buffer[0..chunk_len], offset + read_total);
        if (n == 0) return error.CorruptEmbeddedPayload;
        hasher.update(buffer[0..n]);
        read_total += n;
    }

    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

fn findMachOSection(
    io: std.Io,
    file: std.Io.File,
    segment_name: []const u8,
    section_name: []const u8,
) !?Range {
    const file_len = try file.length(io);
    if (file_len < mach_header_64_len) return null;

    var header: [mach_header_64_len]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len) return error.CorruptEmbeddedPayload;
    if (std.mem.readInt(u32, header[0..4], .little) != mh_magic_64) return null;

    const ncmds = std.mem.readInt(u32, header[16..20], .little);
    const sizeofcmds = std.mem.readInt(u32, header[20..24], .little);
    if (@as(u64, mach_header_64_len) + sizeofcmds > file_len) return error.CorruptEmbeddedPayload;

    var command_offset: u64 = mach_header_64_len;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        if (command_offset + 8 > file_len) return error.CorruptEmbeddedPayload;

        var command_header: [8]u8 = undefined;
        if (try file.readPositionalAll(io, &command_header, command_offset) != command_header.len) {
            return error.CorruptEmbeddedPayload;
        }
        const cmd = std.mem.readInt(u32, command_header[0..4], .little);
        const cmdsize = std.mem.readInt(u32, command_header[4..8], .little);
        if (cmdsize < 8) return error.CorruptEmbeddedPayload;
        const next_command_offset = command_offset + cmdsize;
        if (next_command_offset > @as(u64, mach_header_64_len) + sizeofcmds) return error.CorruptEmbeddedPayload;

        if (cmd == lc_segment_64) {
            if (cmdsize < segment_command_64_len) return error.CorruptEmbeddedPayload;

            var segment: [segment_command_64_len]u8 = undefined;
            if (try file.readPositionalAll(io, &segment, command_offset) != segment.len) {
                return error.CorruptEmbeddedPayload;
            }
            const nsects = std.mem.readInt(u32, segment[64..68], .little);
            const sections_len = @as(u64, nsects) * section_64_len;
            if (@as(u64, segment_command_64_len) + sections_len > cmdsize) return error.CorruptEmbeddedPayload;

            if (fixedMachONameEquals(segment[8..24], segment_name)) {
                var section_offset = command_offset + segment_command_64_len;
                var section_index: u32 = 0;
                while (section_index < nsects) : (section_index += 1) {
                    var section: [section_64_len]u8 = undefined;
                    if (try file.readPositionalAll(io, &section, section_offset) != section.len) {
                        return error.CorruptEmbeddedPayload;
                    }
                    if (fixedMachONameEquals(section[0..16], section_name)) {
                        const size = std.mem.readInt(u64, section[40..48], .little);
                        const offset = std.mem.readInt(u32, section[48..52], .little);
                        if (@as(u64, offset) + size > file_len) return error.CorruptEmbeddedPayload;
                        return .{ .offset = offset, .size = size };
                    }
                    section_offset += section_64_len;
                }
            }
        }

        command_offset = next_command_offset;
    }

    return null;
}

fn fixedMachONameEquals(field: []const u8, name: []const u8) bool {
    const zero = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    return std.mem.eql(u8, field[0..zero], name);
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
