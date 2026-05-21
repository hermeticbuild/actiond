const std = @import("std");

pub const Error = error{
    CorruptEmbeddedPayload,
    InvalidEmbeddedPayloadName,
};

pub const runtimes_name = "runtimes.sqfs";
pub const kernel_name = "linux_kernel";
pub const initramfs_name = "initramfs.cpio.zst";

const copy_buffer_len = 128 * 1024;

const mach_o_segment_name = "__ACTIOND";
const mach_o_kernel_section = "__kernel";
const mach_o_initramfs_section = "__initramfs";
const mach_o_runtimes_section = "__runtimes";
const mh_magic_64: u32 = 0xfeedfacf;
const lc_segment_64: u32 = 0x19;
const mach_header_64_len = 32;
const segment_command_64_len = 72;
const mach_o_section_64_len = 80;

const elf_runtimes_section = ".actiond.runtimes";

const Range = struct {
    offset: u64,
    size: u64,
};

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

    const range = try findPayloadSection(io, allocator, executable, name) orelse return null;
    return try extractRange(io, allocator, root_dir, executable, name, range);
}

fn findPayloadSection(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: std.Io.File,
    name: []const u8,
) !?Range {
    if (machOSectionNameForPayload(name)) |section_name| {
        if (try findMachOSection(io, executable, mach_o_segment_name, section_name)) |range| return range;
    }

    if (std.mem.eql(u8, name, runtimes_name)) {
        if (try findElfSection(io, allocator, executable, elf_runtimes_section)) |range| return range;
    }

    return null;
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

    try copyFileRange(io, executable, output, range.offset, range.size);
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

fn copyFileRange(
    io: std.Io,
    source: std.Io.File,
    dest: std.Io.File,
    source_offset: u64,
    size: u64,
) !void {
    var buffer: [copy_buffer_len]u8 = undefined;
    var copied: u64 = 0;
    while (copied < size) {
        const remaining = size - copied;
        const chunk_len: usize = @intCast(@min(remaining, buffer.len));
        const n = try source.readPositionalAll(io, buffer[0..chunk_len], source_offset + copied);
        if (n == 0) return error.CorruptEmbeddedPayload;
        try dest.writePositionalAll(io, buffer[0..n], copied);
        copied += n;
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
    if (!rangeWithinFile(file_len, mach_header_64_len, sizeofcmds)) return error.CorruptEmbeddedPayload;

    var command_offset: u64 = mach_header_64_len;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        if (!rangeWithinFile(file_len, command_offset, 8)) return error.CorruptEmbeddedPayload;

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
            const sections_len = @as(u64, nsects) * mach_o_section_64_len;
            if (@as(u64, segment_command_64_len) + sections_len > cmdsize) return error.CorruptEmbeddedPayload;

            if (fixedMachONameEquals(segment[8..24], segment_name)) {
                var section_offset = command_offset + segment_command_64_len;
                var section_index: u32 = 0;
                while (section_index < nsects) : (section_index += 1) {
                    var section: [mach_o_section_64_len]u8 = undefined;
                    if (try file.readPositionalAll(io, &section, section_offset) != section.len) {
                        return error.CorruptEmbeddedPayload;
                    }
                    if (fixedMachONameEquals(section[0..16], section_name)) {
                        const size = std.mem.readInt(u64, section[40..48], .little);
                        const offset = std.mem.readInt(u32, section[48..52], .little);
                        if (!rangeWithinFile(file_len, offset, size)) return error.CorruptEmbeddedPayload;
                        return .{ .offset = offset, .size = size };
                    }
                    section_offset += mach_o_section_64_len;
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

fn findElfSection(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    section_name: []const u8,
) !?Range {
    const file_len = try file.length(io);

    var read_buffer: [4096]u8 = undefined;
    var executable_reader = file.reader(io, &read_buffer);
    try executable_reader.seekTo(0);
    const header = std.elf.Header.read(&executable_reader.interface) catch |err| switch (err) {
        error.InvalidElfMagic,
        error.InvalidElfClass,
        error.InvalidElfEndian,
        error.InvalidElfVersion,
        error.EndOfStream,
        => return null,
        else => return err,
    };

    const section_header_size: u16 = if (header.is_64) @sizeOf(std.elf.Elf64_Shdr) else @sizeOf(std.elf.Elf32_Shdr);
    if (header.shoff == 0 or header.shnum == 0) return null;
    if (header.shentsize != section_header_size or header.shstrndx >= header.shnum) return error.CorruptEmbeddedPayload;
    if (!rangeWithinFile(file_len, header.shoff, @as(u64, section_header_size) * header.shnum)) {
        return error.CorruptEmbeddedPayload;
    }

    const shstrtab_header = try elfSectionHeaderAt(&header, &executable_reader, header.shstrndx);
    if (shstrtab_header.sh_type != std.elf.SHT_STRTAB) return error.CorruptEmbeddedPayload;
    if (!rangeWithinFile(file_len, shstrtab_header.sh_offset, shstrtab_header.sh_size)) return error.CorruptEmbeddedPayload;
    if (shstrtab_header.sh_size > std.math.maxInt(usize)) return error.CorruptEmbeddedPayload;

    const shstrtab = try allocator.alloc(u8, @intCast(shstrtab_header.sh_size));
    defer allocator.free(shstrtab);
    try executable_reader.seekTo(shstrtab_header.sh_offset);
    try executable_reader.interface.readSliceAll(shstrtab);

    var sections = header.iterateSectionHeaders(&executable_reader);
    while (try sections.next()) |section| {
        const current_name = try elfString(shstrtab, section.sh_name);
        if (!std.mem.eql(u8, current_name, section_name)) continue;
        if (section.sh_type != std.elf.SHT_PROGBITS) return error.CorruptEmbeddedPayload;
        if (!rangeWithinFile(file_len, section.sh_offset, section.sh_size)) return error.CorruptEmbeddedPayload;
        return .{ .offset = section.sh_offset, .size = section.sh_size };
    }

    return null;
}

fn elfSectionHeaderAt(
    header: *const std.elf.Header,
    executable_reader: *std.Io.File.Reader,
    section_index: u16,
) !std.elf.Elf64_Shdr {
    var sections = header.iterateSectionHeaders(executable_reader);
    var i: u16 = 0;
    while (i < section_index) : (i += 1) {
        _ = (try sections.next()) orelse return error.CorruptEmbeddedPayload;
    }
    return (try sections.next()) orelse error.CorruptEmbeddedPayload;
}

fn elfString(table: []const u8, name_offset: u32) ![]const u8 {
    if (name_offset >= table.len) return error.CorruptEmbeddedPayload;
    const tail = table[name_offset..];
    const zero = std.mem.indexOfScalar(u8, tail, 0) orelse return error.CorruptEmbeddedPayload;
    return tail[0..zero];
}

fn rangeWithinFile(file_len: u64, offset: u64, size: u64) bool {
    return offset <= file_len and size <= file_len - offset;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidEmbeddedPayloadName;
    for (name) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return error.InvalidEmbeddedPayloadName,
    };
}

test "extractFromExecutablePath extracts Mach-O payload section" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "mach-o payload bytes\n";
    const payload_offset = 0x100;
    const commands_len = segment_command_64_len + mach_o_section_64_len;
    const macho_len = payload_offset + payload.len;
    var macho = [_]u8{0} ** macho_len;

    std.mem.writeInt(u32, macho[0..4], mh_magic_64, .little);
    std.mem.writeInt(u32, macho[16..20], 1, .little);
    std.mem.writeInt(u32, macho[20..24], commands_len, .little);

    const segment_offset = mach_header_64_len;
    std.mem.writeInt(u32, macho[segment_offset..][0..4], lc_segment_64, .little);
    std.mem.writeInt(u32, macho[segment_offset + 4 ..][0..4], commands_len, .little);
    @memcpy(macho[segment_offset + 8 ..][0..mach_o_segment_name.len], mach_o_segment_name);
    std.mem.writeInt(u64, macho[segment_offset + 40 ..][0..8], payload_offset, .little);
    std.mem.writeInt(u64, macho[segment_offset + 48 ..][0..8], payload.len, .little);
    std.mem.writeInt(u32, macho[segment_offset + 64 ..][0..4], 1, .little);

    const section_offset = segment_offset + segment_command_64_len;
    @memcpy(macho[section_offset..][0..mach_o_runtimes_section.len], mach_o_runtimes_section);
    @memcpy(macho[section_offset + 16 ..][0..mach_o_segment_name.len], mach_o_segment_name);
    std.mem.writeInt(u64, macho[section_offset + 40 ..][0..8], payload.len, .little);
    std.mem.writeInt(u32, macho[section_offset + 48 ..][0..4], payload_offset, .little);

    @memcpy(macho[payload_offset..][0..payload.len], payload);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "macho",
        .data = &macho,
    });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const macho_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/macho", .{root_buffer[0..root_len]});
    defer std.testing.allocator.free(macho_path);

    const extracted_path = (try extractFromExecutablePath(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        macho_path,
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
    try std.testing.expectEqualStrings(payload, extracted);
}

test "extractFromExecutablePath extracts ELF payload section" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "payload bytes\n";
    const elf_header_64_len = @sizeOf(std.elf.Elf64_Ehdr);
    const elf_section_64_len = @sizeOf(std.elf.Elf64_Shdr);
    const payload_offset = 0x80;
    const shstrtab_offset = 0xc0;
    const section_headers_offset = 0x100;
    const section_count = 3;
    const elf_len = section_headers_offset + elf_section_64_len * section_count;
    var elf = [_]u8{0} ** elf_len;

    @memcpy(elf[0..4], std.elf.MAGIC);
    elf[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    elf[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    elf[std.elf.EI.VERSION] = 1;
    std.mem.writeInt(u16, elf[16..18], 2, .little);
    std.mem.writeInt(u16, elf[18..20], 0xb7, .little);
    std.mem.writeInt(u32, elf[20..24], 1, .little);
    std.mem.writeInt(u64, elf[40..48], section_headers_offset, .little);
    std.mem.writeInt(u16, elf[52..54], elf_header_64_len, .little);
    std.mem.writeInt(u16, elf[58..60], elf_section_64_len, .little);
    std.mem.writeInt(u16, elf[60..62], section_count, .little);
    std.mem.writeInt(u16, elf[62..64], 1, .little);

    @memcpy(elf[payload_offset..][0..payload.len], payload);
    const shstrtab = "\x00.shstrtab\x00.actiond.runtimes\x00";
    @memcpy(elf[shstrtab_offset..][0..shstrtab.len], shstrtab);
    const shstrtab_name_offset = 1;
    const runtimes_name_offset = shstrtab_name_offset + ".shstrtab".len + 1;

    writeElf64SectionHeader(
        elf[section_headers_offset + elf_section_64_len ..][0..elf_section_64_len],
        shstrtab_name_offset,
        std.elf.SHT_STRTAB,
        shstrtab_offset,
        shstrtab.len,
    );
    writeElf64SectionHeader(
        elf[section_headers_offset + elf_section_64_len * 2 ..][0..elf_section_64_len],
        runtimes_name_offset,
        std.elf.SHT_PROGBITS,
        payload_offset,
        payload.len,
    );

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "elf",
        .data = &elf,
    });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const elf_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/elf", .{root_buffer[0..root_len]});
    defer std.testing.allocator.free(elf_path);

    const extracted_path = (try extractFromExecutablePath(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        elf_path,
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
    try std.testing.expectEqualStrings(payload, extracted);
}

fn writeElf64SectionHeader(
    out: []u8,
    name_offset: u32,
    section_type: u32,
    file_offset: u64,
    size: u64,
) void {
    std.mem.writeInt(u32, out[0..4], name_offset, .little);
    std.mem.writeInt(u32, out[4..8], section_type, .little);
    std.mem.writeInt(u64, out[24..32], file_offset, .little);
    std.mem.writeInt(u64, out[32..40], size, .little);
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
