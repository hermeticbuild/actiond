const std = @import("std");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    DigestMismatch,
    InvalidDirectoryEntryName,
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
const tree_temp_path_prefix = tree_prefix ++ ".tmp-";

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

    pub fn deleteBlob(self: Store, io: std.Io, digest: Digest) !void {
        if (digest.isEmpty()) return;

        var path_buffer: [blob_prefix.len + 64]u8 = undefined;
        const path = blobPath(digest, &path_buffer);
        self.root.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
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

    pub fn materializeTree(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        digest: Digest,
    ) !void {
        if (try self.hasTree(io, digest)) return;
        try self.ensureLayoutIfNeeded(io);

        var final_path_buffer: [tree_prefix.len + 64]u8 = undefined;
        const final_path = treeSubPath(digest, &final_path_buffer);

        while (true) {
            const id = next_temp_id.fetchAdd(1, .monotonic);
            var temp_path_buffer: [tree_temp_path_prefix.len + 20]u8 = undefined;
            const temp_path = try std.fmt.bufPrint(&temp_path_buffer, "{s}{d}", .{ tree_temp_path_prefix, id });
            self.root.createDir(io, temp_path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };
            var temp_created = true;
            defer if (temp_created) self.root.deleteTree(io, temp_path) catch {};

            try self.materializeDirectoryContents(io, allocator, digest, temp_path);
            self.root.rename(temp_path, self.root, final_path, io) catch |err| switch (err) {
                error.DirNotEmpty => return,
                error.CrossDevice => {
                    try self.materializeTreeDirect(io, allocator, digest, final_path);
                    return;
                },
                else => |e| return e,
            };
            temp_created = false;
            return;
        }
    }

    pub fn beginBlobWriter(self: Store, io: std.Io) !BlobWriter {
        return BlobWriter.begin(io, self);
    }

    fn ensureLayoutIfNeeded(self: Store, io: std.Io) !void {
        if (!self.layout_ready) try self.ensureLayout(io);
    }

    fn materializeDirectoryContents(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        digest: Digest,
        dest_path: []const u8,
    ) !void {
        const directory_bytes = try self.readAlloc(io, allocator, digest);
        defer allocator.free(directory_bytes);

        var reader = protobuf.Reader.init(directory_bytes);
        var directory = try reapi.Directory.decodeOwned(allocator, &reader);
        defer directory.deinit(allocator);

        for (directory.files) |file| {
            try validateDirectoryEntryName(file.name);
            const file_digest = try Digest.fromReapi(file.digest orelse return error.InvalidDigestSize);
            const dest_file = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_path, file.name });
            defer allocator.free(dest_file);
            try self.materializeTreeFile(io, file_digest, dest_file, file.is_executable);
        }

        for (directory.directories) |child| {
            try validateDirectoryEntryName(child.name);
            const child_digest = try Digest.fromReapi(child.digest orelse return error.InvalidDigestSize);
            const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_path, child.name });
            defer allocator.free(child_path);
            try self.root.createDir(io, child_path, .default_dir);
            try self.materializeDirectoryContents(io, allocator, child_digest, child_path);
        }
    }

    fn materializeTreeDirect(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        digest: Digest,
        final_path: []const u8,
    ) !void {
        self.root.createDir(io, final_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => |e| return e,
        };
        var final_created = true;
        errdefer if (final_created) self.root.deleteTree(io, final_path) catch {};

        try self.materializeDirectoryContents(io, allocator, digest, final_path);
        final_created = false;
    }

    fn materializeTreeFile(
        self: Store,
        io: std.Io,
        digest: Digest,
        dest_path: []const u8,
        is_executable: bool,
    ) !void {
        if (!is_executable) {
            var src_path_buffer: [blob_prefix.len + 64]u8 = undefined;
            const src_path = blobPath(digest, &src_path_buffer);
            var should_copy = false;
            self.root.hardLink(src_path, self.root, dest_path, io, .{}) catch |err| switch (err) {
                error.PathAlreadyExists => return,
                error.CrossDevice, error.OperationUnsupported, error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => should_copy = true,
                else => |e| return e,
            };
            if (!should_copy) return;
        }

        try self.copyToFile(
            io,
            digest,
            self.root,
            dest_path,
            if (is_executable) .executable_file else .default_file,
        );
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

test "Store can remove only a blob file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    const digest = try store.putBytes(std.testing.io, "temporary");
    try std.testing.expect(try store.has(std.testing.io, digest));

    try store.deleteBlob(std.testing.io, digest);
    try std.testing.expect(!try store.has(std.testing.io, digest));
    try store.deleteBlob(std.testing.io, digest);
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

fn validateDirectoryEntryName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidDirectoryEntryName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidDirectoryEntryName;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidDirectoryEntryName;
    if (std.mem.eql(u8, name, ".")) return error.InvalidDirectoryEntryName;
    if (std.mem.eql(u8, name, "..")) return error.InvalidDirectoryEntryName;
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

test "Store materializes directory protos as tree directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    const leaf_digest = try store.putBytes(std.testing.io, "leaf");
    const tool_digest = try store.putBytes(std.testing.io, "#!/bin/sh\n");

    var leaf_hash: [64]u8 = undefined;
    const child_proto = try reapi.encodeAlloc(std.testing.allocator, reapi.Directory{
        .files = &.{
            .{ .name = "leaf.txt", .digest = leaf_digest.toReapi(&leaf_hash) },
        },
    });
    defer std.testing.allocator.free(child_proto);
    const child_digest = try store.putBytes(std.testing.io, child_proto);

    var child_hash: [64]u8 = undefined;
    var tool_hash: [64]u8 = undefined;
    const root_proto = try reapi.encodeAlloc(std.testing.allocator, reapi.Directory{
        .files = &.{
            .{ .name = "tool.sh", .digest = tool_digest.toReapi(&tool_hash), .is_executable = true },
        },
        .directories = &.{
            .{ .name = "sub", .digest = child_digest.toReapi(&child_hash) },
        },
    });
    defer std.testing.allocator.free(root_proto);
    const root_digest = try store.putBytes(std.testing.io, root_proto);

    try store.materializeTree(std.testing.io, std.testing.allocator, root_digest);
    try std.testing.expect(try store.hasTree(std.testing.io, root_digest));

    var tree_path_buffer: [tree_prefix_len + 64]u8 = undefined;
    const tree_path = treeSubPath(root_digest, &tree_path_buffer);
    const leaf_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/sub/leaf.txt", .{tree_path});
    defer std.testing.allocator.free(leaf_path);
    const leaf = try tmp.dir.readFileAlloc(std.testing.io, leaf_path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(leaf);
    try std.testing.expectEqualStrings("leaf", leaf);

    const tool_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/tool.sh", .{tree_path});
    defer std.testing.allocator.free(tool_path);
    const tool_stat = try tmp.dir.statFile(std.testing.io, tool_path, .{});
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        try std.testing.expect(tool_stat.permissions.toMode() & 0o111 != 0);
    }
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
