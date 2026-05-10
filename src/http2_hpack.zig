const std = @import("std");

const header = @import("http2_header.zig");

pub const Header = header.Header;
pub const HeaderList = header.HeaderList;
pub const HeaderView = header.HeaderView;

pub const Error = error{
    DynamicTableUnsupported,
    InvalidHuffman,
    InvalidInteger,
    InvalidIndex,
    InvalidString,
};

const StaticHeader = struct {
    name: []const u8,
    value: []const u8,
};

const static_table = [_]StaticHeader{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

const max_huffman_nodes = 768;

const HuffmanLeaf = struct {
    sym: u8,
    code_len: u8,
};

const HuffmanNode = union(enum) {
    internal: [256]u16,
    leaf: HuffmanLeaf,
};

const HuffmanTree = struct {
    nodes: [max_huffman_nodes]HuffmanNode,
    count: u16,
};

const FastGrpcStatusScan = union(enum) {
    status: ?i32,
    fallback,
};

fn FastScanResult(comptime T: type) type {
    return union(enum) {
        value: T,
        fallback,
    };
}

const huffman_codes = [_]u32{
    0x1ff8,    0x7fffd8,  0xfffffe2,  0xfffffe3, 0xfffffe4, 0xfffffe5,  0xfffffe6,  0xfffffe7,
    0xfffffe8, 0xffffea,  0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb,  0xfffffec,
    0xfffffed, 0xfffffee, 0xfffffef,  0xffffff0, 0xffffff1, 0xffffff2,  0x3ffffffe, 0xffffff3,
    0xffffff4, 0xffffff5, 0xffffff6,  0xffffff7, 0xffffff8, 0xffffff9,  0xffffffa,  0xffffffb,
    0x14,      0x3f8,     0x3f9,      0xffa,     0x1ff9,    0x15,       0xf8,       0x7fa,
    0x3fa,     0x3fb,     0xf9,       0x7fb,     0xfa,      0x16,       0x17,       0x18,
    0x0,       0x1,       0x2,        0x19,      0x1a,      0x1b,       0x1c,       0x1d,
    0x1e,      0x1f,      0x5c,       0xfb,      0x7ffc,    0x20,       0xffb,      0x3fc,
    0x1ffa,    0x21,      0x5d,       0x5e,      0x5f,      0x60,       0x61,       0x62,
    0x63,      0x64,      0x65,       0x66,      0x67,      0x68,       0x69,       0x6a,
    0x6b,      0x6c,      0x6d,       0x6e,      0x6f,      0x70,       0x71,       0x72,
    0xfc,      0x73,      0xfd,       0x1ffb,    0x7fff0,   0x1ffc,     0x3ffc,     0x22,
    0x7ffd,    0x3,       0x23,       0x4,       0x24,      0x5,        0x25,       0x26,
    0x27,      0x6,       0x74,       0x75,      0x28,      0x29,       0x2a,       0x7,
    0x2b,      0x76,      0x2c,       0x8,       0x9,       0x2d,       0x77,       0x78,
    0x79,      0x7a,      0x7b,       0x7ffe,    0x7fc,     0x3ffd,     0x1ffd,     0xffffffc,
    0xfffe6,   0x3fffd2,  0xfffe7,    0xfffe8,   0x3fffd3,  0x3fffd4,   0x3fffd5,   0x7fffd9,
    0x3fffd6,  0x7fffda,  0x7fffdb,   0x7fffdc,  0x7fffdd,  0x7fffde,   0xffffeb,   0x7fffdf,
    0xffffec,  0xffffed,  0x3fffd7,   0x7fffe0,  0xffffee,  0x7fffe1,   0x7fffe2,   0x7fffe3,
    0x7fffe4,  0x1fffdc,  0x3fffd8,   0x7fffe5,  0x3fffd9,  0x7fffe6,   0x7fffe7,   0xffffef,
    0x3fffda,  0x1fffdd,  0xfffe9,    0x3fffdb,  0x3fffdc,  0x7fffe8,   0x7fffe9,   0x1fffde,
    0x7fffea,  0x3fffdd,  0x3fffde,   0xfffff0,  0x1fffdf,  0x3fffdf,   0x7fffeb,   0x7fffec,
    0x1fffe0,  0x1fffe1,  0x3fffe0,   0x1fffe2,  0x7fffed,  0x3fffe1,   0x7fffee,   0x7fffef,
    0xfffea,   0x3fffe2,  0x3fffe3,   0x3fffe4,  0x7ffff0,  0x3fffe5,   0x3fffe6,   0x7ffff1,
    0x3ffffe0, 0x3ffffe1, 0xfffeb,    0x7fff1,   0x3fffe7,  0x7ffff2,   0x3fffe8,   0x1ffffec,
    0x3ffffe2, 0x3ffffe3, 0x3ffffe4,  0x7ffffde, 0x7ffffdf, 0x3ffffe5,  0xfffff1,   0x1ffffed,
    0x7fff2,   0x1fffe3,  0x3ffffe6,  0x7ffffe0, 0x7ffffe1, 0x3ffffe7,  0x7ffffe2,  0xfffff2,
    0x1fffe4,  0x1fffe5,  0x3ffffe8,  0x3ffffe9, 0xffffffd, 0x7ffffe3,  0x7ffffe4,  0x7ffffe5,
    0xfffec,   0xfffff3,  0xfffed,    0x1fffe6,  0x3fffe9,  0x1fffe7,   0x1fffe8,   0x7ffff3,
    0x3fffea,  0x3fffeb,  0x1ffffee,  0x1ffffef, 0xfffff4,  0xfffff5,   0x3ffffea,  0x7ffff4,
    0x3ffffeb, 0x7ffffe6, 0x3ffffec,  0x3ffffed, 0x7ffffe7, 0x7ffffe8,  0x7ffffe9,  0x7ffffea,
    0x7ffffeb, 0xffffffe, 0x7ffffec,  0x7ffffed, 0x7ffffee, 0x7ffffef,  0x7fffff0,  0x3ffffee,
};

const huffman_code_lens = [_]u8{
    13, 23, 28, 28, 28, 28, 28, 28,
    28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28,
    28, 28, 28, 28, 28, 28, 28, 28,
    6,  10, 10, 12, 13, 6,  8,  11,
    10, 10, 8,  11, 8,  6,  6,  6,
    5,  5,  5,  6,  6,  6,  6,  6,
    6,  6,  7,  8,  15, 6,  12, 10,
    13, 6,  7,  7,  7,  7,  7,  7,
    7,  7,  7,  7,  7,  7,  7,  7,
    7,  7,  7,  7,  7,  7,  7,  7,
    8,  7,  8,  13, 19, 13, 14, 6,
    15, 5,  6,  5,  6,  5,  6,  6,
    6,  5,  7,  7,  6,  6,  6,  5,
    6,  7,  6,  5,  5,  6,  7,  7,
    7,  7,  7,  15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23,
    22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23,
    23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21,
    23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23,
    20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25,
    26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24,
    21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23,
    22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27,
    27, 28, 27, 27, 27, 27, 27, 26,
};

const huffman_tree = buildHuffmanTree();

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: std.ArrayListUnmanaged(Header) = .empty,
    dynamic_size: usize = 0,
    max_dynamic_size: usize = 4096,

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Decoder) void {
        for (self.dynamic_table.items) |item| {
            freeIfNonEmpty(self.allocator, item.name);
            freeIfNonEmpty(self.allocator, item.value);
        }
        self.dynamic_table.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn decodeHeaderBlockAlloc(
        self: *Decoder,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !HeaderList {
        const chunks = [_][]const u8{bytes};
        return self.decodeHeaderBlockChunksAlloc(allocator, &chunks);
    }

    pub fn decodeHeaderBlockChunksAlloc(
        self: *Decoder,
        allocator: std.mem.Allocator,
        chunks: []const []const u8,
    ) !HeaderList {
        var out: std.ArrayListUnmanaged(Header) = .empty;
        errdefer {
            for (out.items) |item| {
                freeIfNonEmpty(allocator, item.name);
                freeIfNonEmpty(allocator, item.value);
            }
            out.deinit(allocator);
        }

        var cursor = ChunkCursor.init(chunks);
        while (cursor.hasRemaining()) {
            const first = try cursor.peekByte(error.InvalidInteger);
            if ((first & 0x80) != 0) {
                const entry = try self.lookupHeader(try cursor.readInteger(7));
                try header.appendClone(allocator, &out, entry);
                continue;
            }
            if ((first & 0xe0) == 0x20) {
                try self.setMaxDynamicSize(try cursor.readInteger(5));
                continue;
            }

            const indexing = (first & 0x40) != 0;
            const prefix_bits: u8 = if (indexing) 6 else 4;
            const name_index = try cursor.readInteger(prefix_bits);

            var name: []u8 = undefined;
            errdefer freeIfNonEmpty(allocator, name);
            if (name_index == 0) {
                name = try cursor.readStringAlloc(allocator);
            } else {
                const entry = try self.lookupHeader(name_index);
                name = try allocator.dupe(u8, entry.name);
            }

            const decoded_value = try cursor.readStringAlloc(allocator);

            if (indexing) {
                const inserted = try self.insertDynamicOwned(name, decoded_value);
                errdefer if (inserted) self.removeNewestDynamic();
                try header.appendClone(allocator, &out, .{
                    .name = name,
                    .value = decoded_value,
                });
            } else {
                try out.append(allocator, .{
                    .name = name,
                    .value = decoded_value,
                });
            }
        }

        return .{ .items = try out.toOwnedSlice(allocator) };
    }

    pub fn decodeGrpcStatusHeaderBlockChunks(
        self: *Decoder,
        allocator: std.mem.Allocator,
        chunks: []const []const u8,
    ) !?i32 {
        switch (try self.scanGrpcStatusHeaderBlockChunks(chunks)) {
            .status => |status| return status,
            .fallback => {},
        }
        return self.decodeGrpcStatusHeaderBlockChunksSlow(allocator, chunks);
    }

    fn scanGrpcStatusHeaderBlockChunks(
        self: *Decoder,
        chunks: []const []const u8,
    ) !FastGrpcStatusScan {
        var status: ?i32 = null;
        var cursor = ChunkCursor.init(chunks);
        while (cursor.hasRemaining()) {
            const first = try cursor.peekByte(error.InvalidInteger);
            if ((first & 0x80) != 0) {
                const entry = try self.lookupHeader(try cursor.readInteger(7));
                if (std.mem.eql(u8, entry.name, "grpc-status")) {
                    status = std.fmt.parseInt(i32, entry.value, 10) catch null;
                }
                continue;
            }
            if ((first & 0xe0) == 0x20) return .fallback;

            const indexing = (first & 0x40) != 0;
            if (indexing) return .fallback;

            const name_index = try cursor.readInteger(4);
            const is_grpc_status = if (name_index == 0) blk: {
                break :blk switch (try cursor.readPlainStringEquals("grpc-status")) {
                    .value => |matches| matches,
                    .fallback => return .fallback,
                };
            } else blk: {
                const entry = try self.lookupHeader(name_index);
                break :blk std.mem.eql(u8, entry.name, "grpc-status");
            };

            if (is_grpc_status) {
                status = switch (try cursor.readPlainStringInt(i32, 10)) {
                    .value => |value| value,
                    .fallback => return .fallback,
                };
            } else {
                switch (try cursor.skipPlainString()) {
                    .value => {},
                    .fallback => return .fallback,
                }
            }
        }
        return .{ .status = status };
    }

    fn decodeGrpcStatusHeaderBlockChunksSlow(
        self: *Decoder,
        allocator: std.mem.Allocator,
        chunks: []const []const u8,
    ) !?i32 {
        var status: ?i32 = null;
        var cursor = ChunkCursor.init(chunks);
        while (cursor.hasRemaining()) {
            const first = try cursor.peekByte(error.InvalidInteger);
            if ((first & 0x80) != 0) {
                const entry = try self.lookupHeader(try cursor.readInteger(7));
                if (std.mem.eql(u8, entry.name, "grpc-status")) {
                    status = std.fmt.parseInt(i32, entry.value, 10) catch null;
                }
                continue;
            }
            if ((first & 0xe0) == 0x20) {
                try self.setMaxDynamicSize(try cursor.readInteger(5));
                continue;
            }

            const indexing = (first & 0x40) != 0;
            const prefix_bits: u8 = if (indexing) 6 else 4;
            const name_index = try cursor.readInteger(prefix_bits);

            var owned_name: ?[]u8 = null;
            defer if (owned_name) |value| freeIfNonEmpty(allocator, value);

            const name = if (name_index == 0) blk: {
                const value = try cursor.readStringAlloc(allocator);
                owned_name = value;
                break :blk value;
            } else blk: {
                const entry = try self.lookupHeader(name_index);
                if (indexing) {
                    const value = try allocator.dupe(u8, entry.name);
                    owned_name = value;
                    break :blk value;
                }
                break :blk entry.name;
            };

            var value = try cursor.readStringAlloc(allocator);
            defer freeIfNonEmpty(allocator, value);

            if (std.mem.eql(u8, name, "grpc-status")) {
                status = std.fmt.parseInt(i32, value, 10) catch null;
            }

            if (!indexing) continue;

            const name_owned = owned_name orelse unreachable;
            if (try self.insertDynamicOwned(name_owned, value)) {
                owned_name = null;
                value = &.{};
            }
        }
        return status;
    }

    fn lookupHeader(self: *const Decoder, index: usize) !HeaderView {
        if (index == 0) return error.InvalidIndex;
        if (index <= static_table.len) {
            const entry = try lookupStaticHeader(index);
            return .{ .name = entry.name, .value = entry.value };
        }

        const dynamic_index = index - static_table.len;
        if (dynamic_index <= self.dynamic_table.items.len) {
            const entry = self.dynamic_table.items[dynamic_index - 1];
            return .{ .name = entry.name, .value = entry.value };
        }
        return error.InvalidIndex;
    }

    fn insertDynamicOwned(self: *Decoder, name: []u8, value: []u8) !bool {
        const entry_size = dynamicEntrySize(name, value);
        if (entry_size > self.max_dynamic_size) {
            self.clearDynamicTable();
            return false;
        }

        while (self.dynamic_size + entry_size > self.max_dynamic_size) {
            self.evictOldestDynamic();
        }

        try self.dynamic_table.insert(self.allocator, 0, .{
            .name = name,
            .value = value,
        });
        self.dynamic_size += entry_size;
        return true;
    }

    fn removeNewestDynamic(self: *Decoder) void {
        if (self.dynamic_table.items.len == 0) return;
        const entry = self.dynamic_table.orderedRemove(0);
        self.dynamic_size -= dynamicEntrySize(entry.name, entry.value);
        allocatorFreePair(self.allocator, entry.name, entry.value);
    }

    fn evictOldestDynamic(self: *Decoder) void {
        if (self.dynamic_table.items.len == 0) return;
        const entry = self.dynamic_table.pop().?;
        self.dynamic_size -= dynamicEntrySize(entry.name, entry.value);
        allocatorFreePair(self.allocator, entry.name, entry.value);
    }

    fn clearDynamicTable(self: *Decoder) void {
        while (self.dynamic_table.items.len != 0) self.evictOldestDynamic();
    }

    fn setMaxDynamicSize(self: *Decoder, size: usize) !void {
        self.max_dynamic_size = size;
        while (self.dynamic_size > self.max_dynamic_size) self.evictOldestDynamic();
    }
};

const ChunkCursor = struct {
    chunks: []const []const u8,
    chunk_index: usize = 0,
    chunk_offset: usize = 0,

    fn init(chunks: []const []const u8) ChunkCursor {
        var self = ChunkCursor{ .chunks = chunks };
        self.normalize();
        return self;
    }

    fn hasRemaining(self: *ChunkCursor) bool {
        self.normalize();
        return self.chunk_index < self.chunks.len;
    }

    fn peekByte(self: *ChunkCursor, comptime err: Error) Error!u8 {
        self.normalize();
        if (self.chunk_index >= self.chunks.len) return err;
        return self.chunks[self.chunk_index][self.chunk_offset];
    }

    fn readByte(self: *ChunkCursor, comptime err: Error) Error!u8 {
        const value = try self.peekByte(err);
        self.chunk_offset += 1;
        self.normalize();
        return value;
    }

    fn readInteger(self: *ChunkCursor, prefix_bits: u8) Error!usize {
        const first = try self.readByte(error.InvalidInteger);
        const prefix_mask: u8 = (@as(u8, 1) << @intCast(prefix_bits)) - 1;
        var value: usize = first & prefix_mask;
        if (value < prefix_mask) return value;

        var shift: usize = 0;
        while (true) {
            const byte = try self.readByte(error.InvalidInteger);
            value += @as(usize, byte & 0x7f) << @intCast(shift);
            if ((byte & 0x80) == 0) break;
            shift += 7;
        }
        return value;
    }

    fn readStringAlloc(self: *ChunkCursor, allocator: std.mem.Allocator) ![]u8 {
        const string = try self.readStringPrefix();

        const current = self.currentChunkRemainder();
        if (current.len >= string.encoded_len) {
            const bytes = current[0..string.encoded_len];
            self.chunk_offset += string.encoded_len;
            self.normalize();
            return if (string.huffman)
                decodeHuffmanStringAlloc(allocator, bytes)
            else
                allocator.dupe(u8, bytes);
        }

        const encoded = try self.readExactAlloc(allocator, string.encoded_len, error.InvalidString);
        defer freeIfNonEmpty(allocator, encoded);
        return if (string.huffman)
            decodeHuffmanStringAlloc(allocator, encoded)
        else
            allocator.dupe(u8, encoded);
    }

    fn readPlainStringEquals(self: *ChunkCursor, expected: []const u8) !FastScanResult(bool) {
        const string = try self.readStringPrefix();
        if (string.huffman) return .fallback;
        if (string.encoded_len != expected.len) {
            try self.skipExact(string.encoded_len, error.InvalidString);
            return .{ .value = false };
        }
        return .{ .value = try self.readExactEquals(expected, error.InvalidString) };
    }

    fn readPlainStringInt(
        self: *ChunkCursor,
        comptime T: type,
        comptime base: u8,
    ) !FastScanResult(?T) {
        const string = try self.readStringPrefix();
        if (string.huffman) return .fallback;
        if (string.encoded_len == 0) return .{ .value = null };

        var value: T = 0;
        var negative = false;
        var valid = true;
        var index: usize = 0;
        while (index < string.encoded_len) : (index += 1) {
            const byte = try self.readByte(error.InvalidString);
            if (index == 0 and byte == '-') {
                negative = true;
                if (@typeInfo(T).int.signedness != .signed or string.encoded_len == 1) valid = false;
                continue;
            }
            const digit = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'z' => byte - 'a' + 10,
                'A'...'Z' => byte - 'A' + 10,
                else => {
                    valid = false;
                    continue;
                },
            };
            if (digit >= base) {
                valid = false;
                continue;
            }
            if (valid) {
                value = std.math.mul(T, value, base) catch blk: {
                    valid = false;
                    break :blk value;
                };
                value = std.math.add(T, value, @intCast(digit)) catch blk: {
                    valid = false;
                    break :blk value;
                };
            }
        }
        if (!valid) return .{ .value = null };
        if (negative) value = std.math.negate(value) catch return .{ .value = null };
        return .{ .value = value };
    }

    fn skipPlainString(self: *ChunkCursor) !FastScanResult(void) {
        const string = try self.readStringPrefix();
        if (string.huffman) return .fallback;
        try self.skipExact(string.encoded_len, error.InvalidString);
        return .{ .value = {} };
    }

    fn readStringPrefix(self: *ChunkCursor) !struct { huffman: bool, encoded_len: usize } {
        const first = try self.peekByte(error.InvalidString);
        const huffman = (first & 0x80) != 0;
        return .{
            .huffman = huffman,
            .encoded_len = try self.readInteger(7),
        };
    }

    fn currentChunkRemainder(self: *ChunkCursor) []const u8 {
        self.normalize();
        if (self.chunk_index >= self.chunks.len) return "";
        return self.chunks[self.chunk_index][self.chunk_offset..];
    }

    fn readExactAlloc(
        self: *ChunkCursor,
        allocator: std.mem.Allocator,
        len: usize,
        comptime err: Error,
    ) ![]u8 {
        const out = try allocator.alloc(u8, len);
        errdefer freeIfNonEmpty(allocator, out);

        var remaining = len;
        var out_offset: usize = 0;
        while (remaining != 0) {
            const current = self.currentChunkRemainder();
            if (current.len == 0) return err;
            const take = @min(current.len, remaining);
            @memcpy(out[out_offset..][0..take], current[0..take]);
            out_offset += take;
            remaining -= take;
            self.chunk_offset += take;
            self.normalize();
        }
        return out;
    }

    fn readExactEquals(self: *ChunkCursor, expected: []const u8, comptime err: Error) !bool {
        var remaining = expected;
        var matches = true;
        while (remaining.len != 0) {
            const current = self.currentChunkRemainder();
            if (current.len == 0) return err;
            const take = @min(current.len, remaining.len);
            matches = matches and std.mem.eql(u8, current[0..take], remaining[0..take]);
            self.chunk_offset += take;
            remaining = remaining[take..];
            self.normalize();
        }
        return matches;
    }

    fn skipExact(self: *ChunkCursor, len: usize, comptime err: Error) !void {
        var remaining = len;
        while (remaining != 0) {
            const current = self.currentChunkRemainder();
            if (current.len == 0) return err;
            const take = @min(current.len, remaining);
            self.chunk_offset += take;
            remaining -= take;
            self.normalize();
        }
    }

    fn normalize(self: *ChunkCursor) void {
        while (self.chunk_index < self.chunks.len) {
            const chunk = self.chunks[self.chunk_index];
            if (self.chunk_offset < chunk.len) break;
            self.chunk_index += 1;
            self.chunk_offset = 0;
        }
    }
};

pub fn encodeHeaderBlockAlloc(
    allocator: std.mem.Allocator,
    headers: []const HeaderView,
) ![]u8 {
    const out = try allocator.alloc(u8, encodedHeaderBlockLen(headers));
    errdefer allocator.free(out);
    return encodeHeaderBlockInto(out, headers);
}

pub fn encodedHeaderBlockLen(headers: []const HeaderView) usize {
    var total: usize = 0;
    for (headers) |value| total += literalHeaderWithoutIndexingLen(value);
    return total;
}

pub fn encodeHeaderBlockInto(out: []u8, headers: []const HeaderView) ![]u8 {
    var writer = SliceWriter{ .bytes = out };
    try writeHeaderBlock(&writer, headers);
    return out[0..writer.offset];
}

pub fn writeHeaderBlock(writer: anytype, headers: []const HeaderView) !void {
    for (headers) |value| {
        try writeLiteralHeaderWithoutIndexing(writer, value);
    }
}

pub fn decodeHeaderBlockAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !HeaderList {
    var decoder = Decoder.init(allocator);
    defer decoder.deinit();
    return decoder.decodeHeaderBlockAlloc(allocator, bytes);
}

pub fn decodeHeaderBlockChunksAlloc(
    allocator: std.mem.Allocator,
    chunks: []const []const u8,
) !HeaderList {
    var decoder = Decoder.init(allocator);
    defer decoder.deinit();
    return decoder.decodeHeaderBlockChunksAlloc(allocator, chunks);
}

fn literalHeaderWithoutIndexingLen(value: HeaderView) usize {
    var total = if (staticHeaderNameIndex(value.name)) |index|
        integerEncodedLen(4, index)
    else
        integerEncodedLen(4, 0) + stringEncodedLen(value.name);
    total += stringEncodedLen(value.value);
    return total;
}

fn stringEncodedLen(bytes: []const u8) usize {
    return integerEncodedLen(7, bytes.len) + bytes.len;
}

const SliceWriter = struct {
    bytes: []u8,
    offset: usize = 0,

    fn writeAll(self: *SliceWriter, bytes: []const u8) !void {
        if (self.offset + bytes.len > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.offset..][0..bytes.len], bytes);
        self.offset += bytes.len;
    }
};

fn writeLiteralHeaderWithoutIndexing(writer: anytype, value: HeaderView) !void {
    if (staticHeaderNameIndex(value.name)) |index| {
        try writeInteger(writer, 4, 0x00, index);
    } else {
        try writeInteger(writer, 4, 0x00, 0);
        try writeString(writer, value.name);
    }
    try writeString(writer, value.value);
}

fn writeString(writer: anytype, bytes: []const u8) !void {
    try writeInteger(writer, 7, 0x00, bytes.len);
    if (bytes.len != 0) try writer.writeAll(bytes);
}

fn decodeHuffmanStringAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, bytes.len);

    var current: u16 = 1;
    var current_depth: u8 = 0;
    var cur: u32 = 0;
    var cbits: u8 = 0;
    var sbits: u8 = 0;

    for (bytes) |byte| {
        cur = (cur << 8) | byte;
        cbits += 8;
        sbits += 8;

        while (cbits >= 8) {
            const next = try lookupHuffmanChild(current, @truncate(cur >> @as(u5, @intCast(cbits - 8))));
            switch (huffman_tree.nodes[@intCast(next)]) {
                .internal => {
                    cbits -= 8;
                    current = next;
                    current_depth += 8;
                },
                .leaf => |leaf| {
                    const remaining_bits = leaf.code_len - current_depth;
                    if (remaining_bits > cbits) break;
                    try out.append(allocator, leaf.sym);
                    cbits -= remaining_bits;
                    current = 1;
                    current_depth = 0;
                    sbits = cbits;
                },
            }
        }
    }

    while (cbits > 0) {
        const next = try lookupHuffmanChild(
            current,
            if (cbits >= 8)
                @truncate(cur >> @as(u5, @intCast(cbits - 8)))
            else
                @truncate(cur << @as(u5, @intCast(8 - cbits))),
        );
        switch (huffman_tree.nodes[@intCast(next)]) {
            .internal => {
                if (cbits < 8) break;
                cbits -= 8;
                current = next;
            },
            .leaf => |leaf| {
                const remaining_bits = leaf.code_len - current_depth;
                if (remaining_bits > cbits) break;
                try out.append(allocator, leaf.sym);
                cbits -= remaining_bits;
                current = 1;
                current_depth = 0;
                sbits = cbits;
            },
        }
    }

    if (sbits > 7) return error.InvalidHuffman;
    if (cbits != 0) {
        const mask = (@as(u32, 1) << @as(u5, @intCast(cbits))) - 1;
        if ((cur & mask) != mask) return error.InvalidHuffman;
    }

    return out.toOwnedSlice(allocator);
}

fn lookupHuffmanChild(current: u16, index: u8) !u16 {
    return switch (huffman_tree.nodes[@intCast(current)]) {
        .internal => |children| {
            const next = children[index];
            if (next == 0) return error.InvalidHuffman;
            return next;
        },
        .leaf => unreachable,
    };
}

fn buildHuffmanTree() HuffmanTree {
    @setEvalBranchQuota(200000);

    var tree: HuffmanTree = .{
        .nodes = undefined,
        .count = 2,
    };
    tree.nodes[1] = .{ .internal = emptyHuffmanChildren() };

    var leaf_indices: [256]u16 = undefined;
    for (0..huffman_codes.len) |sym| {
        if (tree.count >= max_huffman_nodes) @compileError("increase max_huffman_nodes");
        leaf_indices[sym] = tree.count;
        tree.nodes[tree.count] = .{ .leaf = .{
            .sym = @intCast(sym),
            .code_len = huffman_code_lens[sym],
        } };
        tree.count += 1;
    }

    for (0..huffman_codes.len) |sym| {
        const code = huffman_codes[sym];
        var code_len = huffman_code_lens[sym];
        var current: u16 = 1;

        while (code_len > 8) {
            code_len -= 8;
            const idx: usize = @intCast((code >> code_len) & 0xff);
            switch (tree.nodes[current]) {
                .internal => |*children| {
                    if (children[idx] == 0) {
                        if (tree.count >= max_huffman_nodes) @compileError("increase max_huffman_nodes");
                        children[idx] = tree.count;
                        tree.nodes[tree.count] = .{ .internal = emptyHuffmanChildren() };
                        tree.count += 1;
                    }
                    current = children[idx];
                },
                .leaf => unreachable,
            }
        }

        const shift = 8 - code_len;
        const start: usize = @intCast((code << shift) & 0xff);
        const slots: usize = @as(usize, 1) << @intCast(shift);
        switch (tree.nodes[current]) {
            .internal => |*children| {
                for (0..slots) |offset| {
                    children[start + offset] = leaf_indices[sym];
                }
            },
            .leaf => unreachable,
        }
    }

    return tree;
}

fn emptyHuffmanChildren() [256]u16 {
    return [_]u16{0} ** 256;
}

fn integerEncodedLen(prefix_bits: u8, value: usize) usize {
    const prefix_mask: u8 = (@as(u8, 1) << @intCast(prefix_bits)) - 1;
    if (value < prefix_mask) return 1;

    var len: usize = 2;
    var remaining = value - prefix_mask;
    while (remaining >= 128) {
        len += 1;
        remaining = (remaining - (remaining & 0x7f)) >> 7;
    }
    return len;
}

fn writeInteger(writer: anytype, prefix_bits: u8, prefix_base: u8, value: usize) !void {
    var scratch: [16]u8 = undefined;
    var used: usize = 0;

    const prefix_mask: u8 = (@as(u8, 1) << @intCast(prefix_bits)) - 1;
    if (value < prefix_mask) {
        scratch[0] = prefix_base | @as(u8, @intCast(value));
        try writer.writeAll(scratch[0..1]);
        return;
    }

    scratch[used] = prefix_base | prefix_mask;
    used += 1;
    var remaining = value - prefix_mask;
    while (remaining >= 128) {
        scratch[used] = @as(u8, @intCast((remaining & 0x7f) | 0x80));
        used += 1;
        remaining = (remaining - (remaining & 0x7f)) >> 7;
    }
    scratch[used] = @intCast(remaining);
    used += 1;
    try writer.writeAll(scratch[0..used]);
}

fn decodeInteger(bytes: []const u8, prefix_bits: u8) !struct { value: usize, consumed: usize } {
    if (bytes.len == 0) return error.InvalidInteger;
    const prefix_mask: u8 = (@as(u8, 1) << @intCast(prefix_bits)) - 1;
    var value: usize = bytes[0] & prefix_mask;
    if (value < prefix_mask) {
        return .{ .value = value, .consumed = 1 };
    }

    var shift: usize = 0;
    var index: usize = 1;
    while (true) {
        if (index >= bytes.len) return error.InvalidInteger;
        const byte = bytes[index];
        value += @as(usize, byte & 0x7f) << @intCast(shift);
        index += 1;
        if ((byte & 0x80) == 0) break;
        shift += 7;
    }
    return .{ .value = value, .consumed = index };
}

fn staticHeaderNameIndex(name: []const u8) ?usize {
    var index: usize = 0;
    while (index < static_table.len) : (index += 1) {
        if (std.mem.eql(u8, static_table[index].name, name)) return index + 1;
    }
    return null;
}

fn lookupStaticHeader(index: usize) !StaticHeader {
    if (index == 0 or index > static_table.len) return error.InvalidIndex;
    return static_table[index - 1];
}

fn dynamicEntrySize(name: []const u8, value: []const u8) usize {
    return 32 + name.len + value.len;
}

fn allocatorFreePair(allocator: std.mem.Allocator, name: []const u8, value: []const u8) void {
    freeIfNonEmpty(allocator, name);
    freeIfNonEmpty(allocator, value);
}

fn freeIfNonEmpty(allocator: std.mem.Allocator, bytes: []const u8) void {
    if (bytes.len == 0) return;
    allocator.free(bytes);
}

test "hpack literal header block round trips" {
    const encoded = try encodeHeaderBlockAlloc(std.testing.allocator, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/pkg.Service/Call" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "te", .value = "trailers" },
    });
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeHeaderBlockAlloc(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), decoded.items.len);
    try std.testing.expectEqualStrings(":method", decoded.items[0].name);
    try std.testing.expectEqualStrings("POST", decoded.items[0].value);
    try std.testing.expectEqualStrings("te", decoded.items[3].name);
    try std.testing.expectEqualStrings("trailers", decoded.items[3].value);
}

test "hpack streaming encoder matches allocated encoder" {
    const headers = [_]HeaderView{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/pkg.Service/Call" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "te", .value = "trailers" },
        .{ .name = "x-extra", .value = "abc" },
    };

    const encoded = try encodeHeaderBlockAlloc(std.testing.allocator, &headers);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(encoded.len, encodedHeaderBlockLen(&headers));

    var stack_encoded: [128]u8 = undefined;
    const into = try encodeHeaderBlockInto(stack_encoded[0..encoded.len], &headers);
    try std.testing.expectEqualSlices(u8, encoded, into);
    try std.testing.expectError(error.NoSpaceLeft, encodeHeaderBlockInto(stack_encoded[0 .. encoded.len - 1], &headers));
}

test "hpack chunked decoder matches contiguous decoder" {
    const headers = [_]HeaderView{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/pkg.Service/Call" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "te", .value = "trailers" },
        .{ .name = "x-extra", .value = "abc" },
    };

    const encoded = try encodeHeaderBlockAlloc(std.testing.allocator, &headers);
    defer std.testing.allocator.free(encoded);

    const chunks = [_][]const u8{
        encoded[0..2],
        encoded[2..7],
        encoded[7..],
    };

    var decoded = try decodeHeaderBlockChunksAlloc(std.testing.allocator, &chunks);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, headers.len), decoded.items.len);
    try std.testing.expectEqualStrings("x-extra", decoded.items[4].name);
    try std.testing.expectEqualStrings("abc", decoded.items[4].value);
}

test "hpack grpc-status scanner reads common trailers without allocation" {
    const encoded = try encodeHeaderBlockAlloc(std.testing.allocator, &.{
        .{ .name = "grpc-status", .value = "0" },
    });
    defer std.testing.allocator.free(encoded);

    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var decoder = Decoder.init(fixed.allocator());
    defer decoder.deinit();

    try std.testing.expectEqual(
        @as(?i32, 0),
        try decoder.decodeGrpcStatusHeaderBlockChunks(fixed.allocator(), &.{encoded}),
    );
}

test "hpack grpc-status scanner handles chunked common trailers without allocation" {
    const encoded = try encodeHeaderBlockAlloc(std.testing.allocator, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "grpc-status", .value = "0" },
    });
    defer std.testing.allocator.free(encoded);

    const chunks = [_][]const u8{
        encoded[0..3],
        encoded[3..15],
        encoded[15..],
    };

    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var decoder = Decoder.init(fixed.allocator());
    defer decoder.deinit();

    try std.testing.expectEqual(
        @as(?i32, 0),
        try decoder.decodeGrpcStatusHeaderBlockChunks(fixed.allocator(), &chunks),
    );
}

test "hpack grpc-status scanner returns null for initial headers without allocation" {
    const encoded = try encodeHeaderBlockAlloc(std.testing.allocator, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
    });
    defer std.testing.allocator.free(encoded);

    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var decoder = Decoder.init(fixed.allocator());
    defer decoder.deinit();

    try std.testing.expectEqual(
        @as(?i32, null),
        try decoder.decodeGrpcStatusHeaderBlockChunks(fixed.allocator(), &.{encoded}),
    );
}

test "hpack decodes Huffman-encoded strings" {
    const encoded = [_]u8{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
    const decoded = try decodeHuffmanStringAlloc(std.testing.allocator, &encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("www.example.com", decoded);
}

test "hpack decodes long Huffman codes without bit underflow" {
    var symbol: ?u8 = null;
    for (0..huffman_code_lens.len) |index| {
        const len = huffman_code_lens[index];
        if (len <= 8) continue;
        if (index < 0x20 or index > 0x7e) continue;
        symbol = @intCast(index);
        break;
    }

    const sym = symbol orelse return error.TestUnexpectedValue;
    const code = huffman_codes[sym];
    const code_len = huffman_code_lens[sym];
    const total_bytes = (code_len + 7) / 8;
    const shift = total_bytes * 8 - code_len;
    const padded = (code << @as(u5, @intCast(shift))) | ((@as(u32, 1) << @as(u5, @intCast(shift))) - 1);

    var encoded: [4]u8 = [_]u8{0} ** 4;
    for (0..total_bytes) |byte_index| {
        const offset = (total_bytes - byte_index - 1) * 8;
        encoded[byte_index] = @truncate(padded >> @as(u5, @intCast(offset)));
    }

    const decoded = try decodeHuffmanStringAlloc(std.testing.allocator, encoded[0..total_bytes]);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(sym, decoded[0]);
}

test "hpack decodes every single-symbol Huffman encoding" {
    for (0..256) |sym| {
        const encoded = try encodeSingleHuffmanSymbolAlloc(std.testing.allocator, @intCast(sym));
        defer std.testing.allocator.free(encoded);

        const decoded = try decodeHuffmanStringAlloc(std.testing.allocator, encoded);
        defer std.testing.allocator.free(decoded);

        try std.testing.expectEqualSlices(u8, &.{@intCast(sym)}, decoded);
    }
}

fn encodeSingleHuffmanSymbolAlloc(allocator: std.mem.Allocator, sym: u8) ![]u8 {
    const code = huffman_codes[sym];
    const code_len = huffman_code_lens[sym];
    const out_len = (code_len + 7) / 8;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var bits_remaining = code_len;
    var out_index: usize = 0;
    while (out_index < out.len) : (out_index += 1) {
        if (bits_remaining >= 8) {
            const shift = bits_remaining - 8;
            out[out_index] = @truncate(code >> @as(u5, @intCast(shift)));
            bits_remaining -= 8;
        } else if (bits_remaining > 0) {
            const chunk = @as(u8, @truncate(code & ((@as(u32, 1) << @as(u5, @intCast(bits_remaining))) - 1)));
            out[out_index] = (chunk << @as(u3, @intCast(8 - bits_remaining))) | (@as(u8, 1) << @as(u3, @intCast(8 - bits_remaining))) - 1;
            bits_remaining = 0;
        } else {
            out[out_index] = 0xff;
        }
    }
    return out;
}
