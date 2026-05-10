const std = @import("std");

pub const Error = error{
    InvalidFieldNumber,
    InvalidLength,
    InvalidVarint,
    NoSpaceLeft,
    UnexpectedEof,
    UnexpectedWireType,
};

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    length_delimited = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
};

pub const Tag = struct {
    field_number: u32,
    wire_type: WireType,
};

pub fn varintLen(value: u64) usize {
    var current = value;
    var len: usize = 1;
    while (current >= 0x80) {
        len += 1;
        current >>= 7;
    }
    return len;
}

pub fn tagLen(field_number: u32, wire_type: WireType) usize {
    std.debug.assert(field_number != 0);
    return varintLen((@as(u64, field_number) << 3) | @intFromEnum(wire_type));
}

pub fn boolFieldLen(field_number: u32) usize {
    return tagLen(field_number, .varint) + 1;
}

pub fn enumFieldLen(field_number: u32, value: anytype) usize {
    return tagLen(field_number, .varint) + varintLen(@intFromEnum(value));
}

pub fn int64FieldLen(field_number: u32, value: i64) usize {
    const bits: u64 = @bitCast(value);
    return tagLen(field_number, .varint) + varintLen(bits);
}

pub fn bytesFieldLen(field_number: u32, value_len: usize) usize {
    return tagLen(field_number, .length_delimited) + varintLen(value_len) + value_len;
}

pub fn stringFieldLen(field_number: u32, value_len: usize) usize {
    return bytesFieldLen(field_number, value_len);
}

pub fn messageFieldLen(field_number: u32, value_len: usize) usize {
    return tagLen(field_number, .length_delimited) + varintLen(value_len) + value_len;
}

pub const Writer = struct {
    const Mode = enum {
        grow,
        counting,
    };

    allocator: std.mem.Allocator = undefined,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    mode: Mode = .grow,
    counted_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn initCounting() Writer {
        return .{ .mode = .counting };
    }

    pub fn deinit(self: *Writer) void {
        if (self.mode == .grow) self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn writtenLen(self: *const Writer) usize {
        return switch (self.mode) {
            .grow => self.bytes.items.len,
            .counting => self.counted_len,
        };
    }

    pub fn writtenBytes(self: *const Writer) []const u8 {
        return switch (self.mode) {
            .grow => self.bytes.items,
            .counting => &.{},
        };
    }

    pub fn writeTag(self: *Writer, field_number: u32, wire_type: WireType) !void {
        if (field_number == 0) return error.InvalidFieldNumber;
        try self.writeVarint((@as(u64, field_number) << 3) | @intFromEnum(wire_type));
    }

    pub fn writeVarint(self: *Writer, value: u64) !void {
        var current = value;
        var encoded: [10]u8 = undefined;
        var len: usize = 0;

        while (true) {
            if (current < 0x80) {
                encoded[len] = @intCast(current);
                len += 1;
                break;
            }
            encoded[len] = @intCast((current & 0x7f) | 0x80);
            len += 1;
            current >>= 7;
        }

        try self.appendSlice(encoded[0..len]);
    }

    pub fn writeBoolField(self: *Writer, field_number: u32, value: bool) !void {
        try self.writeTag(field_number, .varint);
        try self.writeVarint(@intFromBool(value));
    }

    pub fn writeEnumField(self: *Writer, field_number: u32, value: anytype) !void {
        try self.writeTag(field_number, .varint);
        try self.writeVarint(@intFromEnum(value));
    }

    pub fn writeInt64Field(self: *Writer, field_number: u32, value: i64) !void {
        try self.writeTag(field_number, .varint);
        const bits: u64 = @bitCast(value);
        try self.writeVarint(bits);
    }

    pub fn writeBytesField(self: *Writer, field_number: u32, value: []const u8) !void {
        try self.writeTag(field_number, .length_delimited);
        try self.writeVarint(value.len);
        try self.appendSlice(value);
    }

    pub fn writeStringField(self: *Writer, field_number: u32, value: []const u8) !void {
        try self.writeBytesField(field_number, value);
    }

    pub fn writeMessageField(self: *Writer, field_number: u32, value: anytype) !void {
        const Value = @TypeOf(value);
        const nested_len = if (@hasDecl(Value, "encodedLen"))
            value.encodedLen()
        else len: {
            var nested = Writer.initCounting();
            try value.encode(&nested);
            break :len nested.writtenLen();
        };

        try self.writeTag(field_number, .length_delimited);
        try self.writeVarint(nested_len);
        try value.encode(self);
    }

    fn appendSlice(self: *Writer, value: []const u8) !void {
        switch (self.mode) {
            .grow => try self.bytes.appendSlice(self.allocator, value),
            .counting => self.counted_len += value.len,
        }
    }
};

pub const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Reader) !?Tag {
        if (self.offset == self.bytes.len) return null;

        const key = try self.readVarint();
        const field_number: u32 = @intCast(key >> 3);
        if (field_number == 0) return error.InvalidFieldNumber;

        const raw_wire = key & 0x7;
        if (raw_wire > @intFromEnum(WireType.fixed32)) return error.UnexpectedWireType;

        return .{
            .field_number = field_number,
            .wire_type = @enumFromInt(raw_wire),
        };
    }

    pub fn readBool(self: *Reader) !bool {
        return (try self.readVarint()) != 0;
    }

    pub fn readEnum(self: *Reader, comptime Enum: type) !Enum {
        return @enumFromInt(try self.readVarint());
    }

    pub fn readInt64(self: *Reader) !i64 {
        return @bitCast(try self.readVarint());
    }

    pub fn readBytes(self: *Reader) ![]const u8 {
        const len: usize = @intCast(try self.readVarint());
        if (len > self.bytes.len - self.offset) return error.UnexpectedEof;
        const start = self.offset;
        self.offset += len;
        return self.bytes[start..self.offset];
    }

    pub fn readString(self: *Reader) ![]const u8 {
        return self.readBytes();
    }

    pub fn readMessage(self: *Reader) !Reader {
        return Reader.init(try self.readBytes());
    }

    pub fn skipField(self: *Reader, wire_type: WireType) !void {
        switch (wire_type) {
            .varint => _ = try self.readVarint(),
            .fixed64 => try self.skipBytes(8),
            .length_delimited => _ = try self.readBytes(),
            .fixed32 => try self.skipBytes(4),
            .start_group, .end_group => return error.UnexpectedWireType,
        }
    }

    fn readVarint(self: *Reader) !u64 {
        var value: u64 = 0;
        var shift: u6 = 0;

        while (true) : (shift += 7) {
            if (self.offset >= self.bytes.len) return error.UnexpectedEof;
            if (shift >= 64) return error.InvalidVarint;

            const byte = self.bytes[self.offset];
            self.offset += 1;
            value |= @as(u64, byte & 0x7f) << shift;
            if ((byte & 0x80) == 0) return value;
        }
    }

    fn skipBytes(self: *Reader, len: usize) !void {
        if (len > self.bytes.len - self.offset) return error.UnexpectedEof;
        self.offset += len;
    }
};

pub fn encodeAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer = Writer.init(allocator);
    errdefer writer.deinit();

    try value.encode(&writer);
    return writer.bytes.toOwnedSlice(allocator);
}

test "varint encoding is canonical" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();

    try writer.writeVarint(300);
    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x02 }, writer.writtenBytes());

    var reader = Reader.init(writer.writtenBytes());
    try std.testing.expectEqual(@as(u64, 300), try reader.readVarint());
}

test "length-delimited skip lands on next field" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();

    try writer.writeStringField(1, "skip");
    try writer.writeBoolField(2, true);

    var reader = Reader.init(writer.writtenBytes());
    const first = (try reader.next()).?;
    try reader.skipField(first.wire_type);
    const second = (try reader.next()).?;
    try std.testing.expectEqual(@as(u32, 2), second.field_number);
    try std.testing.expect(try reader.readBool());
}
