const std = @import("std");
const reapi = @import("reapi.zig");

pub const Error = error{
    InvalidDigestHash,
    InvalidDigestSize,
};

const blob_prefix = "blobs/sha256/";
const hex_chars = "0123456789abcdef";

pub const Digest = struct {
    hash: [32]u8,
    size_bytes: u64,

    pub fn empty() Digest {
        return fromBytes("");
    }

    pub fn fromBytes(bytes: []const u8) Digest {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        return .{
            .hash = hash,
            .size_bytes = bytes.len,
        };
    }

    pub fn eql(lhs: Digest, rhs: Digest) bool {
        return lhs.size_bytes == rhs.size_bytes and std.mem.eql(u8, &lhs.hash, &rhs.hash);
    }

    pub fn isEmpty(self: Digest) bool {
        return self.eql(empty());
    }

    pub fn formatHex(self: Digest, out: *[64]u8) []const u8 {
        for (self.hash, 0..) |byte, i| {
            out[i * 2] = hex_chars[byte >> 4];
            out[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        return out;
    }

    pub fn toReapi(self: Digest, hash_out: *[64]u8) reapi.Digest {
        return .{
            .hash = self.formatHex(hash_out),
            .size_bytes = @intCast(self.size_bytes),
        };
    }

    pub fn fromReapi(value: reapi.Digest) !Digest {
        if (value.size_bytes < 0) return error.InvalidDigestSize;
        return .{
            .hash = try parseHexHash(value.hash),
            .size_bytes = @intCast(value.size_bytes),
        };
    }
};

pub const Store = struct {
    root: std.Io.Dir,

    pub fn init(root: std.Io.Dir) Store {
        return .{ .root = root };
    }

    pub fn ensureLayout(self: Store, io: std.Io) !void {
        try self.root.createDirPath(io, "blobs/sha256");
    }

    pub fn putBytes(self: Store, io: std.Io, bytes: []const u8) !Digest {
        const digest = Digest.fromBytes(bytes);
        try self.ensureLayout(io);

        var path_buffer: [blob_prefix.len + 64]u8 = undefined;
        const path = blobPath(digest, &path_buffer);

        self.root.access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try self.root.writeFile(io, .{
                    .sub_path = path,
                    .data = bytes,
                    .flags = .{
                        .read = true,
                        .exclusive = true,
                    },
                });
            },
            else => |e| return e,
        };

        return digest;
    }

    pub fn has(self: Store, io: std.Io, digest: Digest) !bool {
        if (digest.isEmpty()) return true;

        var path_buffer: [blob_prefix.len + 64]u8 = undefined;
        const path = blobPath(digest, &path_buffer);
        self.root.access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
        return true;
    }

    pub fn readAlloc(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        digest: Digest,
    ) ![]u8 {
        if (digest.isEmpty()) return try allocator.alloc(u8, 0);

        var path_buffer: [blob_prefix.len + 64]u8 = undefined;
        const path = blobPath(digest, &path_buffer);
        return self.root.readFileAlloc(io, path, allocator, .limited(digest.size_bytes + 1));
    }
};

pub fn parseHexHash(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidDigestHash;

    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*byte, i| {
        const high = try parseHexNibble(text[i * 2]);
        const low = try parseHexNibble(text[i * 2 + 1]);
        byte.* = (high << 4) | low;
    }
    return hash;
}

test "Store treats the empty digest as always present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    const empty_digest = Digest.empty();

    try std.testing.expect(try store.has(std.testing.io, empty_digest));
    const bytes = try store.readAlloc(std.testing.io, std.testing.allocator, empty_digest);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("", bytes);
}

fn blobPath(digest: Digest, out: *[blob_prefix.len + 64]u8) []const u8 {
    @memcpy(out[0..blob_prefix.len], blob_prefix);
    var hex: [64]u8 = undefined;
    @memcpy(out[blob_prefix.len..], digest.formatHex(&hex));
    return out;
}

fn parseHexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidDigestHash,
    };
}

test "Digest computes stable SHA-256 and converts through REAPI" {
    const digest = Digest.fromBytes("hello");
    var hex: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        digest.formatHex(&hex),
    );

    var reapi_hash: [64]u8 = undefined;
    const round_trip = try Digest.fromReapi(digest.toReapi(&reapi_hash));
    try std.testing.expect(digest.eql(round_trip));
}

test "Store writes blobs once and reads them by digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    const digest = try store.putBytes(std.testing.io, "hello");
    try std.testing.expect(try store.has(std.testing.io, digest));

    const second = try store.putBytes(std.testing.io, "hello");
    try std.testing.expect(digest.eql(second));

    const bytes = try store.readAlloc(std.testing.io, std.testing.allocator, digest);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
}
