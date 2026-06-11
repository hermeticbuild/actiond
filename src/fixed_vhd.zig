const std = @import("std");

pub const footer_size = 512;

pub fn createEmpty(
    io: std.Io,
    path: []const u8,
    virtual_size: u64,
) !void {
    const aligned_size = std.mem.alignForward(u64, virtual_size, footer_size);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try writeFooter(io, file, aligned_size);
}

pub fn wrapFile(
    io: std.Io,
    source_path: []const u8,
    output_path: []const u8,
) !void {
    try std.Io.Dir.copyFileAbsolute(source_path, output_path, io, .{
        .permissions = .default_file,
    });
    var output = try std.Io.Dir.openFileAbsolute(io, output_path, .{ .mode = .read_write });
    defer output.close(io);
    const output_stat = try output.stat(io);
    const virtual_size = std.mem.alignForward(u64, output_stat.size, footer_size);
    try writeFooter(io, output, virtual_size);
}

fn writeFooter(io: std.Io, file: std.Io.File, virtual_size: u64) !void {
    var unique_id: [16]u8 = undefined;
    try io.randomSecure(&unique_id);
    try file.setLength(io, virtual_size + footer_size);
    const footer = makeFooter(virtual_size, unique_id);
    try file.writePositionalAll(io, &footer, virtual_size);
}

fn makeFooter(virtual_size: u64, unique_id: [16]u8) [footer_size]u8 {
    var footer = [_]u8{0} ** footer_size;
    @memcpy(footer[0..8], "conectix");
    std.mem.writeInt(u32, footer[8..12], 2, .big);
    std.mem.writeInt(u32, footer[12..16], 0x00010000, .big);
    std.mem.writeInt(u64, footer[16..24], std.math.maxInt(u64), .big);
    std.mem.writeInt(u32, footer[24..28], 0, .big);
    @memcpy(footer[28..32], "actd");
    std.mem.writeInt(u32, footer[32..36], 0x00010000, .big);
    @memcpy(footer[36..40], "Wi2k");
    std.mem.writeInt(u64, footer[40..48], virtual_size, .big);
    std.mem.writeInt(u64, footer[48..56], virtual_size, .big);
    std.mem.writeInt(u32, footer[56..60], diskGeometry(virtual_size), .big);
    std.mem.writeInt(u32, footer[60..64], 2, .big);
    @memcpy(footer[68..84], &unique_id);

    var sum: u32 = 0;
    for (footer) |byte| sum +%= byte;
    std.mem.writeInt(u32, footer[64..68], ~sum, .big);
    return footer;
}

fn diskGeometry(virtual_size: u64) u32 {
    const total_sectors = @min(virtual_size / footer_size, @as(u64, 65535 * 16 * 255));
    var sectors_per_track: u32 = 17;
    var heads: u32 = 4;
    var cylinder_times_heads = total_sectors / sectors_per_track;

    if (cylinder_times_heads >= 1024 * 16) {
        sectors_per_track = 31;
        heads = 16;
        cylinder_times_heads = total_sectors / sectors_per_track;
    }
    if (cylinder_times_heads >= 1024 * 16) {
        sectors_per_track = 63;
        heads = 16;
        cylinder_times_heads = total_sectors / sectors_per_track;
    }
    if (cylinder_times_heads >= 1024 * 16) {
        heads = 255;
    }
    var cylinders: u32 = @intCast(total_sectors / sectors_per_track / heads);
    if (cylinders > 65535) cylinders = 65535;
    return (cylinders << 16) | (heads << 8) | sectors_per_track;
}

test "fixed VHD footer has a valid checksum" {
    const footer = makeFooter(1024 * 1024, [_]u8{0x5a} ** 16);
    const stored_checksum = std.mem.readInt(u32, footer[64..68], .big);
    var sum: u32 = 0;
    for (footer, 0..) |byte, index| {
        if (index < 64 or index >= 68) sum +%= byte;
    }
    try std.testing.expectEqual(~sum, stored_checksum);
    try std.testing.expectEqualStrings("conectix", footer[0..8]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, footer[60..64], .big));
}
