const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("actiond_build_options");
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
pub const digest_hex_len = 64;
pub const digest_shard_hex_len = 2;
pub const digest_sharded_path_len = digest_shard_hex_len + 1 + digest_hex_len;
pub const blob_path_len = blob_prefix.len + digest_sharded_path_len;
pub const tree_path_len = tree_prefix.len + digest_sharded_path_len;
const hex_chars = "0123456789abcdef";
const copy_buffer_len = 128 * 1024;
const temp_path_prefix = blob_prefix ++ ".tmp-";
const tree_temp_path_prefix = tree_prefix ++ ".tmp-";
const stale_retry_attempts = 128;
const stale_retry_sleep_ns = 2 * std.time.ns_per_ms;
const cas_blob_mode: std.posix.mode_t = 0o444;

var next_temp_id = std.atomic.Value(u64).init(0);
var put_file_calls = std.atomic.Value(u64).init(0);
var put_file_promote_attempts = std.atomic.Value(u64).init(0);
var put_file_promote_success = std.atomic.Value(u64).init(0);
var put_file_promote_existing = std.atomic.Value(u64).init(0);
var put_file_promote_bytes = std.atomic.Value(u64).init(0);
var put_file_promote_digest_bytes = std.atomic.Value(u64).init(0);
var put_file_promote_preexisting_hits = std.atomic.Value(u64).init(0);
var put_file_promote_cross_device_fallbacks = std.atomic.Value(u64).init(0);
var put_file_promote_permission_fallbacks = std.atomic.Value(u64).init(0);
var put_file_promote_open_ns = std.atomic.Value(u64).init(0);
var put_file_promote_stat_ns = std.atomic.Value(u64).init(0);
var put_file_promote_digest_ns = std.atomic.Value(u64).init(0);
var put_file_promote_preexisting_check_ns = std.atomic.Value(u64).init(0);
var put_file_promote_mkdir_ns = std.atomic.Value(u64).init(0);
var put_file_promote_chmod_ns = std.atomic.Value(u64).init(0);
var put_file_promote_rename_ns = std.atomic.Value(u64).init(0);
var put_file_promote_existing_ns = std.atomic.Value(u64).init(0);
var put_file_copy_calls = std.atomic.Value(u64).init(0);
var put_file_copy_bytes = std.atomic.Value(u64).init(0);

inline fn putFileStatsAdd(counter: *std.atomic.Value(u64), value: u64) void {
    if (comptime build_options.executor_timing_logs) {
        _ = counter.fetchAdd(value, .monotonic);
    }
}

inline fn putFileStatsNow(io: std.Io) std.Io.Timestamp {
    return if (comptime build_options.executor_timing_logs)
        std.Io.Clock.awake.now(io)
    else
        undefined;
}

pub const PutFileStats = struct {
    calls: u64,
    promote_attempts: u64,
    promote_success: u64,
    promote_existing: u64,
    promote_bytes: u64,
    promote_digest_bytes: u64,
    promote_preexisting_hits: u64,
    promote_cross_device_fallbacks: u64,
    promote_permission_fallbacks: u64,
    promote_open_ns: u64,
    promote_stat_ns: u64,
    promote_digest_ns: u64,
    promote_preexisting_check_ns: u64,
    promote_mkdir_ns: u64,
    promote_chmod_ns: u64,
    promote_rename_ns: u64,
    promote_existing_ns: u64,
    copy_calls: u64,
    copy_bytes: u64,
};

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

        var writer = try self.beginBlobWriter(io);
        defer writer.deinit(io);
        try writer.writeAll(bytes);
        _ = try writer.finish(io, digest);
    }

    pub fn has(self: Store, io: std.Io, digest: Digest) !bool {
        if (digest.isEmpty()) return true;

        var path_buffer: [blob_path_len]u8 = undefined;
        const path = blobPath(digest, &path_buffer);
        self.root.access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
        return true;
    }

    pub fn deleteBlob(self: Store, io: std.Io, digest: Digest) !void {
        if (digest.isEmpty()) return;

        var path_buffer: [blob_path_len]u8 = undefined;
        const path = blobPath(digest, &path_buffer);
        self.root.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    pub fn hasTree(self: Store, io: std.Io, digest: Digest) !bool {
        var path_buffer: [tree_path_len]u8 = undefined;
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
        return self.readAllocOnce(io, allocator, digest);
    }

    fn readAllocOnce(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        digest: Digest,
    ) ![]u8 {
        const len = std.math.cast(usize, digest.size_bytes) orelse return error.FileTooBig;
        var file = try self.openBlob(io, digest);
        defer file.close(io);

        const bytes = try allocator.alloc(u8, len);
        errdefer allocator.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = try readFd(file.handle, bytes[offset..]);
            if (n == 0) return error.ReadFailed;
            offset += n;
        }
        return bytes;
    }

    pub fn openBlob(self: Store, io: std.Io, digest: Digest) !std.Io.File {
        var path_buffer: [blob_path_len]u8 = undefined;
        const path = blobPath(digest, &path_buffer);
        if (comptime builtin.os.tag == .linux) return openFileLinuxRetry(self.root, path);
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

        var src = try self.openBlob(io, digest);
        defer src.close(io);

        var dest = if (comptime builtin.os.tag == .linux)
            try createFileLinuxRetry(dest_dir, dest_path, permissions)
        else
            try dest_dir.createFile(io, dest_path, .{
                .truncate = true,
                .permissions = permissions,
            });
        defer dest.close(io);

        if (comptime builtin.os.tag == .linux) {
            if (try copyFdToFdLinux(src.handle, dest.handle, digest.size_bytes)) return;
        }

        var buffer: [copy_buffer_len]u8 = undefined;
        while (true) {
            const n = try readFd(src.handle, &buffer);
            if (n == 0) break;
            try writeFdAll(dest.handle, buffer[0..n]);
        }
    }

    pub fn putFilePromoteWithStat(
        self: Store,
        io: std.Io,
        src_dir: std.Io.Dir,
        src_path: []const u8,
        stat: std.Io.Dir.Stat,
    ) !Digest {
        putFileStatsAdd(&put_file_calls, 1);
        const open_start = putFileStatsNow(io);
        var src = try src_dir.openFile(io, src_path, .{});
        addElapsedNs(&put_file_promote_open_ns, open_start, io);
        defer src.close(io);
        return self.putOpenFilePromote(io, src_dir, src_path, &src, stat);
    }

    fn putOpenFilePromote(
        self: Store,
        io: std.Io,
        src_dir: std.Io.Dir,
        src_path: []const u8,
        src: *std.Io.File,
        stat: std.Io.Dir.Stat,
    ) !Digest {
        if (comptime builtin.os.tag == .linux) {
            return self.putOpenFileByRenameLinux(io, src_dir, src_path, src, stat) catch |err| switch (err) {
                error.CrossDevice => return self.putOpenFileCopy(io, src),
                error.PermissionDenied, error.AccessDenied => return self.putOpenFileCopy(io, src),
                else => |e| return e,
            };
        }
        return self.putOpenFileCopy(io, src);
    }

    fn putFileCopy(
        self: Store,
        io: std.Io,
        src_dir: std.Io.Dir,
        src_path: []const u8,
    ) !Digest {
        var src = try src_dir.openFile(io, src_path, .{});
        defer src.close(io);
        return self.putOpenFileCopy(io, &src);
    }

    fn putOpenFileCopy(
        self: Store,
        io: std.Io,
        src: *std.Io.File,
    ) !Digest {
        putFileStatsAdd(&put_file_copy_calls, 1);
        try seekFd(src.handle, 0);
        var writer = try BlobWriter.begin(io, self);
        defer writer.deinit(io);

        var size_bytes: u64 = 0;
        var buffer: [copy_buffer_len]u8 = undefined;
        while (true) {
            const n = try readFd(src.handle, &buffer);
            if (n == 0) break;
            try writer.writeAll(buffer[0..n]);
            size_bytes += n;
        }

        const digest = try writer.finish(io, null);
        putFileStatsAdd(&put_file_copy_bytes, size_bytes);
        return digest;
    }

    fn putOpenFileByRenameLinux(
        self: Store,
        io: std.Io,
        src_dir: std.Io.Dir,
        src_path: []const u8,
        src: *std.Io.File,
        stat: std.Io.Dir.Stat,
    ) !Digest {
        if (comptime builtin.os.tag != .linux) unreachable;
        putFileStatsAdd(&put_file_promote_attempts, 1);

        const original_mode = stat.permissions.toMode();

        const digest_start = putFileStatsNow(io);
        const digest = try digestFile(src.*);
        addElapsedNs(&put_file_promote_digest_ns, digest_start, io);
        putFileStatsAdd(&put_file_promote_digest_bytes, digest.size_bytes);

        var final_path_buffer: [blob_path_len]u8 = undefined;
        const final_path = blobPath(digest, &final_path_buffer);

        const preexisting_start = putFileStatsNow(io);
        if (self.root.statFile(io, final_path, .{})) |_| {
            addElapsedNs(&put_file_promote_preexisting_check_ns, preexisting_start, io);
            putFileStatsAdd(&put_file_promote_preexisting_hits, 1);
            putFileStatsAdd(&put_file_promote_existing, 1);
            return digest;
        } else |err| switch (err) {
            error.FileNotFound => addElapsedNs(&put_file_promote_preexisting_check_ns, preexisting_start, io),
            else => return err,
        }

        const mkdir_start = putFileStatsNow(io);
        try self.root.createDirPath(io, digestParentPath(final_path));
        addElapsedNs(&put_file_promote_mkdir_ns, mkdir_start, io);

        const chmod_start = putFileStatsNow(io);
        setFdMode(src.handle, cas_blob_mode) catch |err| switch (err) {
            error.PermissionDenied, error.AccessDenied => {
                addElapsedNs(&put_file_promote_chmod_ns, chmod_start, io);
                putFileStatsAdd(&put_file_promote_permission_fallbacks, 1);
                return err;
            },
            else => |e| return e,
        };
        addElapsedNs(&put_file_promote_chmod_ns, chmod_start, io);

        const rename_start = putFileStatsNow(io);
        src_dir.renamePreserve(src_path, self.root, final_path, io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const rename_ns = elapsedNsSince(rename_start, io);
                putFileStatsAdd(&put_file_promote_rename_ns, rename_ns);
                putFileStatsAdd(&put_file_promote_existing_ns, rename_ns);
                setFdMode(src.handle, original_mode) catch {};
                putFileStatsAdd(&put_file_promote_existing, 1);
                return digest;
            },
            error.CrossDevice => {
                putFileStatsAdd(&put_file_promote_rename_ns, elapsedNsSince(rename_start, io));
                setFdMode(src.handle, original_mode) catch {};
                putFileStatsAdd(&put_file_promote_cross_device_fallbacks, 1);
                return error.CrossDevice;
            },
            error.PermissionDenied, error.AccessDenied => {
                putFileStatsAdd(&put_file_promote_rename_ns, elapsedNsSince(rename_start, io));
                setFdMode(src.handle, original_mode) catch {};
                putFileStatsAdd(&put_file_promote_permission_fallbacks, 1);
                return err;
            },
            else => |e| {
                putFileStatsAdd(&put_file_promote_rename_ns, elapsedNsSince(rename_start, io));
                setFdMode(src.handle, original_mode) catch {};
                return e;
            },
        };
        addElapsedNs(&put_file_promote_rename_ns, rename_start, io);
        putFileStatsAdd(&put_file_promote_success, 1);
        putFileStatsAdd(&put_file_promote_bytes, digest.size_bytes);
        return digest;
    }

    pub fn materializeTree(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        digest: Digest,
    ) !void {
        if (try self.hasTree(io, digest)) return;
        try self.ensureLayoutIfNeeded(io);

        var final_path_buffer: [tree_path_len]u8 = undefined;
        const final_path = treeSubPath(digest, &final_path_buffer);
        try self.root.createDirPath(io, digestParentPath(final_path));

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
        try self.root.createDirPath(io, digestParentPath(final_path));
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
            var src_path_buffer: [blob_path_len]u8 = undefined;
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

pub fn snapshotPutFileStats() PutFileStats {
    if (comptime !build_options.executor_timing_logs) return std.mem.zeroes(PutFileStats);
    return .{
        .calls = put_file_calls.load(.monotonic),
        .promote_attempts = put_file_promote_attempts.load(.monotonic),
        .promote_success = put_file_promote_success.load(.monotonic),
        .promote_existing = put_file_promote_existing.load(.monotonic),
        .promote_bytes = put_file_promote_bytes.load(.monotonic),
        .promote_digest_bytes = put_file_promote_digest_bytes.load(.monotonic),
        .promote_preexisting_hits = put_file_promote_preexisting_hits.load(.monotonic),
        .promote_cross_device_fallbacks = put_file_promote_cross_device_fallbacks.load(.monotonic),
        .promote_permission_fallbacks = put_file_promote_permission_fallbacks.load(.monotonic),
        .promote_open_ns = put_file_promote_open_ns.load(.monotonic),
        .promote_stat_ns = put_file_promote_stat_ns.load(.monotonic),
        .promote_digest_ns = put_file_promote_digest_ns.load(.monotonic),
        .promote_preexisting_check_ns = put_file_promote_preexisting_check_ns.load(.monotonic),
        .promote_mkdir_ns = put_file_promote_mkdir_ns.load(.monotonic),
        .promote_chmod_ns = put_file_promote_chmod_ns.load(.monotonic),
        .promote_rename_ns = put_file_promote_rename_ns.load(.monotonic),
        .promote_existing_ns = put_file_promote_existing_ns.load(.monotonic),
        .copy_calls = put_file_copy_calls.load(.monotonic),
        .copy_bytes = put_file_copy_bytes.load(.monotonic),
    };
}

pub fn appendPutFileStats(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    if (comptime !build_options.executor_timing_logs) return;
    const stats = snapshotPutFileStats();
    const text = try std.fmt.allocPrint(allocator,
        \\cas_put_file_calls {d}
        \\cas_put_file_promote_attempts {d}
        \\cas_put_file_promote_success {d}
        \\cas_put_file_promote_existing {d}
        \\cas_put_file_promote_bytes {d}
        \\cas_put_file_promote_digest_bytes {d}
        \\cas_put_file_promote_preexisting_hits {d}
        \\cas_put_file_promote_cross_device_fallbacks {d}
        \\cas_put_file_promote_permission_fallbacks {d}
        \\cas_put_file_promote_open_ns {d}
        \\cas_put_file_promote_stat_ns {d}
        \\cas_put_file_promote_digest_ns {d}
        \\cas_put_file_promote_preexisting_check_ns {d}
        \\cas_put_file_promote_mkdir_ns {d}
        \\cas_put_file_promote_chmod_ns {d}
        \\cas_put_file_promote_rename_ns {d}
        \\cas_put_file_promote_existing_ns {d}
        \\cas_put_file_copy_calls {d}
        \\cas_put_file_copy_bytes {d}
        \\
    , .{
        stats.calls,
        stats.promote_attempts,
        stats.promote_success,
        stats.promote_existing,
        stats.promote_bytes,
        stats.promote_digest_bytes,
        stats.promote_preexisting_hits,
        stats.promote_cross_device_fallbacks,
        stats.promote_permission_fallbacks,
        stats.promote_open_ns,
        stats.promote_stat_ns,
        stats.promote_digest_ns,
        stats.promote_preexisting_check_ns,
        stats.promote_mkdir_ns,
        stats.promote_chmod_ns,
        stats.promote_rename_ns,
        stats.promote_existing_ns,
        stats.copy_calls,
        stats.copy_bytes,
    });
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub const BlobWriter = struct {
    store: Store,
    file: std.Io.File,
    temp_kind: TempKind,
    temp_path_buffer: [temp_path_prefix.len + 20]u8,
    temp_path_len: usize,
    hasher: std.crypto.hash.sha2.Sha256,
    size_bytes: u64 = 0,
    closed: bool = false,
    finished: bool = false,

    const TempKind = enum {
        named,
        anonymous_linux,
    };

    fn begin(io: std.Io, store: Store) !BlobWriter {
        try store.ensureLayoutIfNeeded(io);

        if (comptime builtin.os.tag == .linux) {
            if (try beginAnonymousLinux(store)) |file| {
                return .{
                    .store = store,
                    .file = file,
                    .temp_kind = .anonymous_linux,
                    .temp_path_buffer = undefined,
                    .temp_path_len = 0,
                    .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
                };
            }
        }

        while (true) {
            const id = next_temp_id.fetchAdd(1, .monotonic);
            var temp_path_buffer: [temp_path_prefix.len + 20]u8 = undefined;
            const temp_path = try std.fmt.bufPrint(&temp_path_buffer, "{s}{d}", .{ temp_path_prefix, id });
            const file = store.root.createFile(io, temp_path, .{
                .truncate = true,
                .exclusive = true,
                .permissions = .fromMode(cas_blob_mode),
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };

            return .{
                .store = store,
                .file = file,
                .temp_kind = .named,
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
        if (!self.finished and self.temp_kind == .named) {
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

        var final_path_buffer: [blob_path_len]u8 = undefined;
        const final_path = blobPath(digest, &final_path_buffer);
        try self.store.root.createDirPath(io, digestParentPath(final_path));
        switch (self.temp_kind) {
            .named => {
                self.file.close(io);
                self.closed = true;
                self.store.root.renamePreserve(self.tempPath(), self.store.root, final_path, io) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        self.store.root.deleteFile(io, self.tempPath()) catch {};
                    },
                    else => |e| return e,
                };
            },
            .anonymous_linux => {
                if (comptime builtin.os.tag != .linux) unreachable;
                publishAnonymousLinux(self.file.handle, self.store.root.handle, final_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => |e| return e,
                };
                self.file.close(io);
                self.closed = true;
            },
        }
        self.finished = true;
        return digest;
    }

    fn tempPath(self: *const BlobWriter) []const u8 {
        std.debug.assert(self.temp_kind == .named);
        return self.temp_path_buffer[0..self.temp_path_len];
    }
};

fn beginAnonymousLinux(store: Store) !?std.Io.File {
    if (comptime builtin.os.tag != .linux) unreachable;

    const path_z = try std.posix.toPosixPath(blob_prefix[0 .. blob_prefix.len - 1]);
    while (true) {
        const rc = std.os.linux.openat(
            store.root.handle,
            &path_z,
            .{
                .ACCMODE = .WRONLY,
                .TMPFILE = true,
                .DIRECTORY = true,
                .CLOEXEC = true,
            },
            @intCast(cas_blob_mode),
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => return .{ .handle = @intCast(rc), .flags = .{ .nonblocking = false } },
            .INTR => continue,
            .INVAL, .ISDIR, .NOENT, .OPNOTSUPP => return null,
            .ACCES => return error.AccessDenied,
            .DQUOT => return error.DiskQuota,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .ROFS => return error.ReadOnlyFileSystem,
            else => return error.Unexpected,
        }
    }
}

fn publishAnonymousLinux(file_fd: std.posix.fd_t, dest_dir_fd: std.posix.fd_t, dest_path: []const u8) !void {
    if (comptime builtin.os.tag != .linux) unreachable;

    const dest_path_z = try std.posix.toPosixPath(dest_path);
    linkAnonymousLinux(file_fd, dest_dir_fd, &dest_path_z, true) catch |err| switch (err) {
        error.FileNotFound => return linkAnonymousLinux(file_fd, dest_dir_fd, &dest_path_z, false),
        else => |e| return e,
    };
}

fn linkAnonymousLinux(
    file_fd: std.posix.fd_t,
    dest_dir_fd: std.posix.fd_t,
    dest_path_z: [*:0]const u8,
    empty_path: bool,
) !void {
    if (comptime builtin.os.tag != .linux) unreachable;

    var proc_path_buffer: ["/proc/self/fd/-2147483648\x00".len]u8 = undefined;
    const old_fd: std.posix.fd_t = if (empty_path) file_fd else std.os.linux.AT.FDCWD;
    const old_path: [*:0]const u8 = if (empty_path)
        ""
    else
        std.fmt.bufPrintSentinel(&proc_path_buffer, "/proc/self/fd/{d}", .{file_fd}, 0) catch unreachable;
    const flags: u32 = if (empty_path) std.os.linux.AT.EMPTY_PATH else std.os.linux.AT.SYMLINK_FOLLOW;

    while (true) {
        const rc = std.os.linux.linkat(old_fd, old_path, dest_dir_fd, dest_path_z, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .DQUOT => return error.DiskQuota,
            .EXIST => return error.PathAlreadyExists,
            .IO => return error.InputOutput,
            .LOOP => return error.SymLinkLoop,
            .MLINK => return error.LinkQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .ROFS => return error.ReadOnlyFileSystem,
            .XDEV => return error.CrossDeviceLink,
            else => return error.Unexpected,
        }
    }
}

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

fn blobPath(digest: Digest, out: *[blob_path_len]u8) []const u8 {
    return blobSubPath(digest, out);
}

pub fn blobSubPath(digest: Digest, out: *[blob_path_len]u8) []const u8 {
    return shardedDigestSubPath(blob_prefix, digest, out);
}

pub fn treeSubPath(digest: Digest, out: *[tree_path_len]u8) []const u8 {
    return shardedDigestSubPath(tree_prefix, digest, out);
}

pub fn digestShardedSubPath(digest: Digest, out: *[digest_sharded_path_len]u8) []const u8 {
    var hex: [64]u8 = undefined;
    const hash = digest.formatHex(&hex);

    @memcpy(out[0..digest_shard_hex_len], hash[0..digest_shard_hex_len]);
    out[digest_shard_hex_len] = '/';
    @memcpy(out[digest_shard_hex_len + 1 .. digest_sharded_path_len], hash);
    return out[0..digest_sharded_path_len];
}

fn shardedDigestSubPath(prefix: []const u8, digest: Digest, out: []u8) []const u8 {
    const len = prefix.len + digest_sharded_path_len;
    var sharded: [digest_sharded_path_len]u8 = undefined;
    const path = digestShardedSubPath(digest, &sharded);

    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..len], path);
    return out[0..len];
}

fn digestParentPath(path: []const u8) []const u8 {
    return path[0 .. path.len - (digest_hex_len + 1)];
}

fn digestFile(file: std.Io.File) !Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var size_bytes: u64 = 0;
    var buffer: [copy_buffer_len]u8 = undefined;
    while (true) {
        const n = try readFd(file.handle, &buffer);
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        size_bytes += n;
    }

    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return .{
        .hash = hash,
        .size_bytes = size_bytes,
    };
}

fn seekFd(fd: std.Io.File.Handle, offset: i64) !void {
    while (true) {
        const rc = std.posix.system.lseek(fd, offset, std.posix.SEEK.SET);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn elapsedNsSince(start: std.Io.Timestamp, io: std.Io) u64 {
    if (comptime !build_options.executor_timing_logs) return 0;
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
}

fn addElapsedNs(counter: *std.atomic.Value(u64), start: std.Io.Timestamp, io: std.Io) void {
    if (comptime !build_options.executor_timing_logs) return;
    _ = counter.fetchAdd(elapsedNsSince(start, io), .monotonic);
}

fn setFdMode(fd: std.Io.File.Handle, mode: std.posix.mode_t) !void {
    if (comptime builtin.os.tag != .linux) unreachable;
    while (true) {
        const rc = std.os.linux.fchmod(fd, @intCast(mode));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .IO => return error.InputOutput,
            .ROFS => return error.ReadOnlyFileSystem,
            else => return error.Unexpected,
        }
    }
}

fn readFd(fd: std.Io.File.Handle, buffer: []u8) !usize {
    var stale_attempts: usize = 0;
    while (true) {
        const rc = std.posix.system.read(fd, buffer.ptr, buffer.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .STALE => {
                if (stale_attempts >= stale_retry_attempts) return error.ReadFailed;
                stale_attempts += 1;
                sleepStaleRetry();
                continue;
            },
            else => return error.ReadFailed,
        }
    }
}

fn openFileLinuxRetry(dir: std.Io.Dir, path: []const u8) !std.Io.File {
    if (comptime builtin.os.tag != .linux) unreachable;

    var path_z: [blob_path_len:0]u8 = undefined;
    if (path.len > path_z.len) return error.NameTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var stale_attempts: usize = 0;
    while (true) {
        const rc = std.os.linux.openat(
            dir.handle,
            &path_z,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            0,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => return .{ .handle = @intCast(rc), .flags = .{ .nonblocking = false } },
            .INTR => continue,
            .STALE => {
                if (stale_attempts >= stale_retry_attempts) return error.FileNotFound;
                stale_attempts += 1;
                sleepStaleRetry();
                continue;
            },
            .NOENT, .SRCH => return error.FileNotFound,
            .ACCES => return error.AccessDenied,
            .ISDIR => return error.IsDir,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .LOOP => return error.SymLinkLoop,
            .FBIG, .OVERFLOW => return error.FileTooBig,
            else => return error.Unexpected,
        }
    }
}

fn sleepStaleRetry() void {
    if (comptime builtin.os.tag != .linux) return;
    var request: std.os.linux.timespec = .{
        .sec = 0,
        .nsec = stale_retry_sleep_ns,
    };
    while (std.posix.errno(std.os.linux.nanosleep(&request, &request)) == .INTR) {}
}

fn createFileLinuxRetry(
    dir: std.Io.Dir,
    path: []const u8,
    permissions: std.Io.File.Permissions,
) !std.Io.File {
    if (comptime builtin.os.tag != .linux) unreachable;

    const path_z = try std.posix.toPosixPath(path);
    const mode: std.os.linux.mode_t = @intCast(permissions.toMode());

    var stale_attempts: usize = 0;
    while (true) {
        const rc = std.os.linux.openat(
            dir.handle,
            &path_z,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            mode,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => return .{ .handle = @intCast(rc), .flags = .{ .nonblocking = false } },
            .INTR => continue,
            .STALE => {
                if (stale_attempts >= stale_retry_attempts) return error.FileNotFound;
                stale_attempts += 1;
                sleepStaleRetry();
                continue;
            },
            .NOENT, .SRCH => return error.FileNotFound,
            .ACCES => return error.AccessDenied,
            .ISDIR => return error.IsDir,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .LOOP => return error.SymLinkLoop,
            .FBIG, .OVERFLOW => return error.FileTooBig,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            else => return error.Unexpected,
        }
    }
}

fn copyFdToFdLinux(src: std.Io.File.Handle, dest: std.Io.File.Handle, size: u64) !bool {
    var remaining = size;
    var copied_any = false;
    while (remaining != 0) {
        const chunk: usize = @intCast(@min(remaining, 0x7ffff000));
        const rc = std.os.linux.sendfile(dest, src, null, chunk);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return if (copied_any) error.ReadFailed else false;
                remaining -= n;
                copied_any = true;
            },
            .INTR => continue,
            .INVAL, .NOSYS, .OPNOTSUPP, .XDEV, .STALE => {
                if (copied_any) return error.WriteFailed;
                return false;
            },
            .NOSPC => return error.NoSpaceLeft,
            .FBIG, .OVERFLOW => return error.FileTooBig,
            else => return error.WriteFailed,
        }
    }
    return true;
}

fn writeFdAll(fd: std.Io.File.Handle, bytes: []const u8) !void {
    var offset: usize = 0;
    var stale_attempts: usize = 0;
    while (offset < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteFailed;
                offset += n;
            },
            .INTR => continue,
            .STALE => {
                if (stale_attempts >= stale_retry_attempts) return error.WriteFailed;
                stale_attempts += 1;
                sleepStaleRetry();
                continue;
            },
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

test "CAS subpaths use two-character digest prefix sharding" {
    const digest = Digest.fromBytes("hello");
    const expected_hash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

    var blob_path_buffer: [blob_path_len]u8 = undefined;
    const blob_path = blobSubPath(digest, &blob_path_buffer);
    try std.testing.expectEqualStrings("blobs/sha256/2c/" ++ expected_hash, blob_path);

    var tree_path_buffer: [tree_path_len]u8 = undefined;
    const tree_path = treeSubPath(digest, &tree_path_buffer);
    try std.testing.expectEqualStrings("trees/sha256/2c/" ++ expected_hash, tree_path);

    var digest_path_buffer: [digest_sharded_path_len]u8 = undefined;
    const digest_path = digestShardedSubPath(digest, &digest_path_buffer);
    try std.testing.expectEqualStrings("2c/" ++ expected_hash, digest_path);
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

test "Store writes known blobs atomically and ignores existing blob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    const digest = Digest.fromBytes("hello");
    try store.putKnownBytes(std.testing.io, digest, "hello");
    try store.putKnownBytes(std.testing.io, digest, "hello");
    try std.testing.expect(try store.has(std.testing.io, digest));
    try std.testing.expectError(error.InvalidDigestSize, store.putKnownBytes(std.testing.io, digest, "hell"));
    try std.testing.expectError(error.DigestMismatch, store.putKnownBytes(std.testing.io, digest, "jello"));
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

    var tree_path_buffer: [tree_path_len]u8 = undefined;
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

test "Store putFile keeps the source file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.writeFile(std.testing.io, .{
        .sub_path = "out.txt",
        .data = "copy me",
    });

    const digest = try store.putFileCopy(std.testing.io, stage, "out.txt");
    try std.testing.expect(digest.eql(Digest.fromBytes("copy me")));
    try std.testing.expect(try store.has(std.testing.io, digest));
    const stat = try stage.statFile(std.testing.io, "out.txt", .{});
    try std.testing.expectEqual(@as(u64, "copy me".len), stat.size);
}

test "Store promotes same-filesystem files into CAS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.writeFile(std.testing.io, .{
        .sub_path = "out.txt",
        .data = "promote me",
    });

    const before = snapshotPutFileStats();
    var src = try stage.openFile(std.testing.io, "out.txt", .{});
    defer src.close(std.testing.io);
    const stat = try src.stat(std.testing.io);
    const digest = try store.putOpenFilePromote(std.testing.io, stage, "out.txt", &src, stat);
    const after = snapshotPutFileStats();
    try std.testing.expect(digest.eql(Digest.fromBytes("promote me")));
    try std.testing.expect(try store.has(std.testing.io, digest));
    if (comptime build_options.executor_timing_logs) {
        try std.testing.expectEqual(before.calls + 1, after.calls);
    } else {
        try std.testing.expectEqual(before.calls, after.calls);
    }
    if (comptime builtin.os.tag == .linux) {
        if (comptime build_options.executor_timing_logs) {
            try std.testing.expectEqual(before.promote_attempts + 1, after.promote_attempts);
            try std.testing.expectEqual(before.promote_success + 1, after.promote_success);
            try std.testing.expectEqual(before.promote_bytes + @as(u64, "promote me".len), after.promote_bytes);
        } else {
            try std.testing.expectEqual(before.promote_attempts, after.promote_attempts);
            try std.testing.expectEqual(before.promote_success, after.promote_success);
            try std.testing.expectEqual(before.promote_bytes, after.promote_bytes);
        }
        try std.testing.expectError(error.FileNotFound, stage.statFile(std.testing.io, "out.txt", .{}));
    } else {
        if (comptime build_options.executor_timing_logs) {
            try std.testing.expectEqual(before.copy_calls + 1, after.copy_calls);
            try std.testing.expectEqual(before.copy_bytes + @as(u64, "promote me".len), after.copy_bytes);
        } else {
            try std.testing.expectEqual(before.copy_calls, after.copy_calls);
            try std.testing.expectEqual(before.copy_bytes, after.copy_bytes);
        }
        const staged_stat = try stage.statFile(std.testing.io, "out.txt", .{});
        try std.testing.expectEqual(@as(u64, "promote me".len), staged_stat.size);
    }
}
