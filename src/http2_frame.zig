const std = @import("std");

pub const client_connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const header_len = 9;
pub const default_initial_window_size: i32 = 65_535;
pub const default_max_frame_size: u32 = 16_384;
pub const max_frame_size_limit: u32 = 16_777_215;

pub const Error = error{
    FrameTooLarge,
    InvalidFrameSize,
    InvalidSettingsLength,
    InvalidWindowUpdate,
};

pub const Type = enum(u8) {
    data = 0,
    headers = 1,
    priority = 2,
    rst_stream = 3,
    settings = 4,
    push_promise = 5,
    ping = 6,
    goaway = 7,
    window_update = 8,
    continuation = 9,
};

pub const ErrorCode = enum(u32) {
    no_error = 0,
    protocol_error = 1,
    internal_error = 2,
    flow_control_error = 3,
    settings_timeout = 4,
    stream_closed = 5,
    frame_size_error = 6,
    refused_stream = 7,
    cancel = 8,
    compression_error = 9,
    connect_error = 10,
    enhance_your_calm = 11,
    inadequate_security = 12,
    http_1_1_required = 13,
};

pub const SettingId = enum(u16) {
    header_table_size = 1,
    enable_push = 2,
    max_concurrent_streams = 3,
    initial_window_size = 4,
    max_frame_size = 5,
    max_header_list_size = 6,
};

pub const flag_end_stream: u8 = 0x1;
pub const flag_ack: u8 = 0x1;
pub const flag_end_headers: u8 = 0x4;
pub const flag_padded: u8 = 0x8;
pub const flag_priority: u8 = 0x20;

pub const Header = struct {
    length: usize,
    type: Type,
    flags: u8,
    stream_id: u31,
};

pub const Setting = struct {
    id: SettingId,
    value: u32,
};

pub fn hasFlag(flags: u8, flag: u8) bool {
    return (flags & flag) != 0;
}

pub fn encodeHeader(dst: *[header_len]u8, header: Header) Error!void {
    if (header.length > max_frame_size_limit) return error.FrameTooLarge;

    dst[0] = @intCast((header.length >> 16) & 0xff);
    dst[1] = @intCast((header.length >> 8) & 0xff);
    dst[2] = @intCast(header.length & 0xff);
    dst[3] = @intFromEnum(header.type);
    dst[4] = header.flags;
    std.mem.writeInt(u32, dst[5..9], @as(u32, header.stream_id), .big);
    dst[5] &= 0x7f;
}

pub fn decodeHeader(src: *const [header_len]u8) Header {
    const length = (@as(usize, src[0]) << 16) | (@as(usize, src[1]) << 8) | src[2];
    const stream_id = std.mem.readInt(u32, src[5..9], .big) & 0x7fff_ffff;
    return .{
        .length = length,
        .type = @enumFromInt(src[3]),
        .flags = src[4],
        .stream_id = @truncate(stream_id),
    };
}

pub fn appendSettingsPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    settings: []const Setting,
) !void {
    try out.ensureUnusedCapacity(allocator, settings.len * 6);
    for (settings) |setting| {
        const start = out.items.len;
        out.items.len += 6;
        std.mem.writeInt(u16, out.items[start..][0..2], @intFromEnum(setting.id), .big);
        std.mem.writeInt(u32, out.items[start + 2 ..][0..4], setting.value, .big);
    }
}

pub const SettingsIterator = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) Error!SettingsIterator {
        if (bytes.len % 6 != 0) return error.InvalidSettingsLength;
        return .{ .bytes = bytes };
    }

    pub fn next(self: *SettingsIterator) ?Setting {
        if (self.offset == self.bytes.len) return null;
        const id_raw = std.mem.readInt(u16, self.bytes[self.offset..][0..2], .big);
        const value = std.mem.readInt(u32, self.bytes[self.offset + 2 ..][0..4], .big);
        self.offset += 6;
        const id = enumFromInt(SettingId, id_raw) catch return .{
            .id = .header_table_size,
            .value = value,
        };
        return .{ .id = id, .value = value };
    }
};

fn enumFromInt(comptime Enum: type, value: anytype) !Enum {
    inline for (@typeInfo(Enum).@"enum".fields) |field| {
        if (field.value == value) return @enumFromInt(value);
    }
    return error.InvalidEnumTag;
}

pub fn decodeWindowUpdate(payload: []const u8) Error!u31 {
    if (payload.len != 4) return error.InvalidWindowUpdate;
    const value = std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff;
    if (value == 0) return error.InvalidWindowUpdate;
    return @truncate(value);
}

test "frame header round trips" {
    var bytes: [header_len]u8 = undefined;
    try encodeHeader(&bytes, .{
        .length = 321,
        .type = .headers,
        .flags = flag_end_headers,
        .stream_id = 7,
    });

    const decoded = decodeHeader(&bytes);
    try std.testing.expectEqual(@as(usize, 321), decoded.length);
    try std.testing.expectEqual(Type.headers, decoded.type);
    try std.testing.expectEqual(flag_end_headers, decoded.flags);
    try std.testing.expectEqual(@as(u31, 7), decoded.stream_id);
}

test "settings payload round trips" {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try appendSettingsPayload(std.testing.allocator, &bytes, &.{
        .{ .id = .enable_push, .value = 0 },
        .{ .id = .initial_window_size, .value = 70_000 },
    });

    var iterator = try SettingsIterator.init(bytes.items);
    const first = iterator.next().?;
    try std.testing.expectEqual(SettingId.enable_push, first.id);
    try std.testing.expectEqual(@as(u32, 0), first.value);
    const second = iterator.next().?;
    try std.testing.expectEqual(SettingId.initial_window_size, second.id);
    try std.testing.expectEqual(@as(u32, 70_000), second.value);
    try std.testing.expectEqual(@as(?Setting, null), iterator.next());
}
