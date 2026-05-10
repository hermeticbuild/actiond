const std = @import("std");
const reapi = @import("reapi.zig");

pub const Error = error{
    DigestMismatch,
    InvalidDigestHash,
    InvalidDigestSize,
};

const blob_prefix = "blobs/sha256/";
pub const blob_prefix_len = blob_prefix.len;
const tree_prefix = "trees/sha256/";
pub const tree_prefix_len = tree_prefix.len;
const hex_chars = "0123456789abcdef";
const copy_buffer_len = 128 * 1024;
const temp_path_prefix = blob_prefix ++ ".tmp-";

var next_temp_id = std.atomic.Value(u64).init(0);

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
    layout_ready: bool = false,

    pub fn init(root: std.Io.Dir) Store {
        return .{ .root = root };
    }

    pub fn initReady(root: std.Io.Dir) Store {
        return .{ .root = root, .layout_ready = true };
    }

    pub fn ensureLayout(self: Store, io: std.Io) !void {
        try self.root.createDirPath(io, "blobs/sha256");
        try self.root.createDirPath(io, "trees/sha256");
    }

    pub fn putBytes(self: Store, io: std.Io, bytes: []const u8) !Digest {
        const digest = Digest.fromBytes(bytes);
        try self.putKnownBytes(io, digest, bytes);
        return digest;
    }

    pub fn putKnownBytes(self: Store, io: std.Io, digest: Digest, bytes: []const u8) !void {
        if (digest.size_bytes != bytes.len) return error.InvalidDigestSize;
        try self.ensureLayoutIfNeeded(io);
        var path_buffer: [blob_prefix.len + 64]u8 = undefined;
        const path = blobPath(digest, &path_buffer);

        self.root.writeFile(io, .{
            .sub_path = path,
            .data = bytes,
            .flags = .{
                .read = true,
                .exclusive = true,
            },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
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

    pub fn hasTree(self: Store, io: std.Io, digest: Digest) !bool {
        var path_buffer: [tree_prefix.len + 64]u8 = undefined;
        const path = treeSubPath(digest, &path_buffer);
        const stat = self.root.statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
        return stat.kind == .directory;
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

    pub fn openBlob(self: Store, io: std.Io, digest: Digest) !std.Io.File {
        var path_buffer: [blob_prefix.len + 64]u8 = undefined;
        const path = blobPath(digest, &path_buffer);
        return self.root.openFile(io, path, .{});
    }

    pub fn copyToFile(
        self: Store,
        io: std.Io,
        digest: Digest,
        dest_dir: std.Io.Dir,
        dest_path: []const u8,
        permissions: std.Io.File.Permissions,
    ) !void {
        if (digest.isEmpty()) {
            return dest_dir.writeFile(io, .{
                .sub_path = dest_path,
                .data = "",
                .flags = .{ .read = true, .permissions = permissions },
            });
        }

        var src_path_buffer: [blob_prefix.len + 64]u8 = undefined;
        const src_path = blobPath(digest, &src_path_buffer);
        var src = try self.root.openFile(io, src_path, .{});
        defer src.close(io);

        var dest = try dest_dir.createFile(io, dest_path, .{
            .truncate = true,
            .permissions = permissions,
        });
        defer dest.close(io);

        var buffer: [copy_buffer_len]u8 = undefined;
        while (true) {
            const n = try readFd(src.handle, &buffer);
            if (n == 0) break;
            try writeFdAll(dest.handle, buffer[0..n]);
        }
    }

    pub fn putFile(
        self: Store,
        io: std.Io,
        src_dir: std.Io.Dir,
        src_path: []const u8,
    ) !Digest {
        var src = try src_dir.openFile(io, src_path, .{});
        defer src.close(io);

        var writer = try BlobWriter.begin(io, self);
        defer writer.deinit(io);

        var buffer: [copy_buffer_len]u8 = undefined;
        while (true) {
            const n = try readFd(src.handle, &buffer);
            if (n == 0) break;
            try writer.writeAll(buffer[0..n]);
        }

        return try writer.finish(io, null);
    }

    pub fn beginBlobWriter(self: Store, io: std.Io) !BlobWriter {
        return BlobWriter.begin(io, self);
    }

    fn ensureLayoutIfNeeded(self: Store, io: std.Io) !void {
        if (!self.layout_ready) try self.ensureLayout(io);
    }
};

pub const BlobWriter = struct {
    store: Store,
    file: std.Io.File,
    temp_path_buffer: [temp_path_prefix.len + 20]u8,
    temp_path_len: usize,
    hasher: std.crypto.hash.sha2.Sha256,
    size_bytes: u64 = 0,
    closed: bool = false,
    finished: bool = false,

    fn begin(io: std.Io, store: Store) !BlobWriter {
        try store.ensureLayoutIfNeeded(io);

        while (true) {
            const id = next_temp_id.fetchAdd(1, .monotonic);
            var temp_path_buffer: [temp_path_prefix.len + 20]u8 = undefined;
            const temp_path = try std.fmt.bufPrint(&temp_path_buffer, "{s}{d}", .{ temp_path_prefix, id });
            const file = store.root.createFile(io, temp_path, .{
                .truncate = true,
                .exclusive = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };

            return .{
                .store = store,
                .file = file,
                .temp_path_buffer = temp_path_buffer,
                .temp_path_len = temp_path.len,
                .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
            };
        }
    }

    pub fn deinit(self: *BlobWriter, io: std.Io) void {
        if (!self.closed) {
            self.file.close(io);
            self.closed = true;
        }
        if (!self.finished) {
            self.store.root.deleteFile(io, self.tempPath()) catch {};
        }
        self.* = undefined;
    }

    pub fn writeAll(self: *BlobWriter, bytes: []const u8) !void {
        self.hasher.update(bytes);
        self.size_bytes += bytes.len;
        try writeFdAll(self.file.handle, bytes);
    }

    pub fn finish(self: *BlobWriter, io: std.Io, expected: ?Digest) !Digest {
        var hash: [32]u8 = undefined;
        self.hasher.final(&hash);
        const digest: Digest = .{
            .hash = hash,
            .size_bytes = self.size_bytes,
        };
        if (expected) |value| {
            if (!digest.eql(value)) return error.DigestMismatch;
        }

        self.file.close(io);
        self.closed = true;

        var final_path_buffer: [blob_prefix.len + 64]u8 = undefined;
        const final_path = blobPath(digest, &final_path_buffer);
        self.store.root.renamePreserve(self.tempPath(), self.store.root, final_path, io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                self.store.root.deleteFile(io, self.tempPath()) catch {};
            },
            else => |e| return e,
        };
        self.finished = true;
        return digest;
    }

    fn tempPath(self: *const BlobWriter) []const u8 {
        return self.temp_path_buffer[0..self.temp_path_len];
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
    return blobSubPath(digest, out);
}

pub fn blobSubPath(digest: Digest, out: *[blob_prefix.len + 64]u8) []const u8 {
    @memcpy(out[0..blob_prefix.len], blob_prefix);
    var hex: [64]u8 = undefined;
    @memcpy(out[blob_prefix.len..], digest.formatHex(&hex));
    return out;
}

pub fn treeSubPath(digest: Digest, out: *[tree_prefix.len + 64]u8) []const u8 {
    @memcpy(out[0..tree_prefix.len], tree_prefix);
    var hex: [64]u8 = undefined;
    @memcpy(out[tree_prefix.len..], digest.formatHex(&hex));
    return out;
}

fn readFd(fd: std.Io.File.Handle, buffer: []u8) !usize {
    while (true) {
        const rc = std.posix.system.read(fd, buffer.ptr, buffer.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

fn writeFdAll(fd: std.Io.File.Handle, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteFailed;
                offset += n;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
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

test "Store writes known blobs without rehashing and ignores existing blob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    const digest = Digest.fromBytes("hello");
    try store.putKnownBytes(std.testing.io, digest, "hello");
    try store.putKnownBytes(std.testing.io, digest, "hello");
    try std.testing.expect(try store.has(std.testing.io, digest));
    try std.testing.expectError(error.InvalidDigestSize, store.putKnownBytes(std.testing.io, digest, "hell"));
}

test "BlobWriter streams data into CAS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    var writer = try store.beginBlobWriter(std.testing.io);
    defer writer.deinit(std.testing.io);
    try writer.writeAll("hel");
    try writer.writeAll("lo");
    const digest = try writer.finish(std.testing.io, Digest.fromBytes("hello"));

    const bytes = try store.readAlloc(std.testing.io, std.testing.allocator, digest);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
}
