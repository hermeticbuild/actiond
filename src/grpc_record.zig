const std = @import("std");

pub const Error = error{
    InvalidCompressionFlag,
    MessageTooLarge,
    UnexpectedEof,
    UnsupportedCompression,
};

pub const Message = struct {
    compressed: bool = false,
    payload: []const u8,
};

pub const header_len = 5;

pub fn encodedLen(payload_len: usize) !usize {
    if (payload_len > std.math.maxInt(u32)) return error.MessageTooLarge;
    return header_len + payload_len;
}

pub fn encodeAlloc(allocator: std.mem.Allocator, message: Message) ![]u8 {
    if (message.compressed) return error.UnsupportedCompression;
    const len = try encodedLen(message.payload.len);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);

    out[0] = 0;
    std.mem.writeInt(u32, out[1..header_len], @intCast(message.payload.len), .big);
    @memcpy(out[header_len..], message.payload);
    return out;
}

pub const Iterator = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Iterator) !?Message {
        if (self.offset == self.bytes.len) return null;
        if (self.bytes.len - self.offset < header_len) return error.UnexpectedEof;

        const compressed = switch (self.bytes[self.offset]) {
            0 => false,
            1 => true,
            else => return error.InvalidCompressionFlag,
        };
        if (compressed) return error.UnsupportedCompression;

        const payload_len = std.mem.readInt(u32, self.bytes[self.offset + 1 ..][0..4], .big);
        const frame_len: usize = header_len + payload_len;
        if (self.bytes.len - self.offset < frame_len) return error.UnexpectedEof;

        const payload = self.bytes[self.offset + header_len ..][0..payload_len];
        self.offset += frame_len;
        return .{ .payload = payload };
    }
};

test "encodeAlloc writes uncompressed gRPC record header" {
    const encoded = try encodeAlloc(std.testing.allocator, .{ .payload = "abc" });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 3, 'a', 'b', 'c' }, encoded);

    var it = Iterator.init(encoded);
    const message = (try it.next()).?;
    try std.testing.expectEqualStrings("abc", message.payload);
    try std.testing.expectEqual(@as(?Message, null), try it.next());
}

test "Iterator rejects compressed records for now" {
    var it = Iterator.init(&.{ 1, 0, 0, 0, 0 });
    try std.testing.expectError(error.UnsupportedCompression, it.next());
}

test "Iterator rejects truncated records" {
    var it = Iterator.init(&.{ 0, 0, 0 });
    try std.testing.expectError(error.UnexpectedEof, it.next());

    var with_len = Iterator.init(&.{ 0, 0, 0, 0, 4, 'a' });
    try std.testing.expectError(error.UnexpectedEof, with_len.next());
}
