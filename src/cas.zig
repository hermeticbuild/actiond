const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("actiond_build_options");
const reapi = @import("reapi.zig");

pub const Error = error{
    DigestMismatch,
    InvalidDigestHash,
    InvalidDigestSize,
};

const blob_prefix = "blobs/sha256/";
pub const blob_prefix_len = blob_prefix.len;
pub const digest_hex_len = 64;
pub const digest_shard_hex_len = 2;
pub const digest_sharded_path_len = digest_shard_hex_len + 1 + digest_hex_len;
pub const blob_path_len = blob_prefix.len + digest_sharded_path_len;
pub const max_alloc_blob_bytes: usize = 64 * 1024 * 1024;
const hex_chars = "0123456789abcdef";
const copy_buffer_len = 128 * 1024;
const temp_path_prefix = blob_prefix ++ ".tmp-";
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
        const path = blobSubPath(digest, &path_buffer);
        const stat = self.root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
        return stat.kind == .file and stat.size == digest.size_bytes;
    }

    pub fn readAlloc(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        digest: Digest,
    ) ![]u8 {
        return self.readAllocLimit(io, allocator, digest, max_alloc_blob_bytes);
    }

    pub fn readAllocLimit(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        digest: Digest,
        max_bytes: usize,
    ) ![]u8 {
        if (digest.isEmpty()) return try allocator.alloc(u8, 0);
        return self.readAllocOnce(io, allocator, digest, max_bytes);
    }

    fn readAllocOnce(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        digest: Digest,
        max_bytes: usize,
    ) ![]u8 {
        var file = try self.openBlob(io, digest);
        defer file.close(io);

        const len = std.math.cast(usize, digest.size_bytes) orelse return error.FileTooBig;
        if (len > max_bytes) return error.FileTooBig;

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
        const path = blobSubPath(digest, &path_buffer);
        var file = (if (comptime builtin.os.tag == .linux)
            openFileLinuxRetry(self.root, path)
        else
            self.root.openFile(io, path, .{ .follow_symlinks = false })) catch |err| switch (err) {
            error.SymLinkLoop => return error.FailedPrecondition,
            else => |e| return e,
        };
        errdefer file.close(io);

        const stat = try file.stat(io);
        if (stat.kind != .file) return error.FailedPrecondition;
        if (stat.size != digest.size_bytes) return error.InvalidDigestSize;
        return file;
    }

    fn validateExistingBlob(self: Store, io: std.Io, digest: Digest) !void {
        var path_buffer: [blob_path_len]u8 = undefined;
        const path = blobSubPath(digest, &path_buffer);
        const stat = self.root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.IsDir,
            error.NotDir,
            => return error.FailedPrecondition,
            else => |e| return e,
        };
        if (stat.kind != .file or stat.size != digest.size_bytes) return error.FailedPrecondition;
    }

    fn requireExistingBlob(self: Store, io: std.Io, digest: Digest) !void {
        self.validateExistingBlob(io, digest) catch |err| switch (err) {
            error.FileNotFound => return error.FailedPrecondition,
            else => |e| return e,
        };
    }

    pub fn putFilePromoteWithStat(
        self: Store,
        io: std.Io,
        src_dir: std.Io.Dir,
        src_path: []const u8,
        stat: std.Io.Dir.Stat,
    ) !Digest {
        putFileStatsAdd(&put_file_calls, 1);
        if (stat.kind != .file) return error.FailedPrecondition;

        const open_start = putFileStatsNow(io);
        var src = try src_dir.openFile(io, src_path, .{ .follow_symlinks = false });
        addElapsedNs(&put_file_promote_open_ns, open_start, io);
        defer src.close(io);

        const opened_stat = try src.stat(io);
        if (opened_stat.kind != .file or
            opened_stat.inode != stat.inode or
            opened_stat.size != stat.size)
        {
            return error.FailedPrecondition;
        }

        return self.putOpenFilePromote(io, src_dir, src_path, &src, opened_stat);
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
                error.CrossDevice => return self.putOpenFileCopy(io, src, stat.size),
                error.PermissionDenied, error.AccessDenied => return self.putOpenFileCopy(io, src, stat.size),
                else => |e| return e,
            };
        }
        return self.putOpenFileCopy(io, src, stat.size);
    }

    fn putOpenFileCopy(
        self: Store,
        io: std.Io,
        src: *std.Io.File,
        expected_size: u64,
    ) !Digest {
        putFileStatsAdd(&put_file_copy_calls, 1);
        try validateOpenFileSize(io, src.*, expected_size);
        try seekFd(src.handle, 0);
        var writer = try BlobWriter.begin(io, self);
        defer writer.deinit(io);

        var size_bytes: u64 = 0;
        var buffer: [copy_buffer_len]u8 = undefined;
        while (true) {
            const n = try readFd(src.handle, &buffer);
            if (n == 0) break;
            if (@as(u64, n) > expected_size - size_bytes) return error.FailedPrecondition;
            try writer.writeAll(buffer[0..n]);
            size_bytes += n;
        }

        if (size_bytes != expected_size) return error.FailedPrecondition;
        try validateOpenFileSize(io, src.*, expected_size);
        const digest = try writer.finish(io, null);
        if (digest.size_bytes != expected_size) return error.FailedPrecondition;
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
        const digest = try digestFile(src.*, stat.size);
        addElapsedNs(&put_file_promote_digest_ns, digest_start, io);
        putFileStatsAdd(&put_file_promote_digest_bytes, digest.size_bytes);
        if (digest.size_bytes != stat.size) return error.FailedPrecondition;
        try validateOpenFileSize(io, src.*, stat.size);

        var final_path_buffer: [blob_path_len]u8 = undefined;
        const final_path = blobSubPath(digest, &final_path_buffer);

        const preexisting_start = putFileStatsNow(io);
        if (self.validateExistingBlob(io, digest)) |_| {
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

        validateOpenFileSize(io, src.*, stat.size) catch |err| {
            setFdMode(src.handle, original_mode) catch {};
            return err;
        };
        const rename_start = putFileStatsNow(io);
        src_dir.renamePreserve(src_path, self.root, final_path, io) catch |err| switch (err) {
            error.PathAlreadyExists, error.IsDir, error.NotDir => {
                const rename_ns = elapsedNsSince(rename_start, io);
                putFileStatsAdd(&put_file_promote_rename_ns, rename_ns);
                putFileStatsAdd(&put_file_promote_existing_ns, rename_ns);
                setFdMode(src.handle, original_mode) catch {};
                try self.requireExistingBlob(io, digest);
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

    pub fn beginBlobWriter(self: Store, io: std.Io) !BlobWriter {
        return BlobWriter.begin(io, self);
    }

    fn ensureLayoutIfNeeded(self: Store, io: std.Io) !void {
        if (!self.layout_ready) try self.ensureLayout(io);
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
        const final_path = blobSubPath(digest, &final_path_buffer);
        try self.store.root.createDirPath(io, digestParentPath(final_path));
        switch (self.temp_kind) {
            .named => {
                self.file.close(io);
                self.closed = true;
                self.store.root.renamePreserve(self.tempPath(), self.store.root, final_path, io) catch |err| switch (err) {
                    error.PathAlreadyExists, error.IsDir, error.NotDir => {
                        try self.store.requireExistingBlob(io, digest);
                        self.store.root.deleteFile(io, self.tempPath()) catch {};
                    },
                    else => |e| return e,
                };
            },
            .anonymous_linux => {
                if (comptime builtin.os.tag != .linux) unreachable;
                publishAnonymousLinux(self.file.handle, self.store.root.handle, final_path) catch |err| switch (err) {
                    error.PathAlreadyExists => try self.store.requireExistingBlob(io, digest),
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
        switch (std.os.linux.errno(rc)) {
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
        switch (std.os.linux.errno(rc)) {
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

pub fn blobSubPath(digest: Digest, out: *[blob_path_len]u8) []const u8 {
    return shardedDigestSubPath(blob_prefix, digest, out);
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

fn validateOpenFileSize(io: std.Io, file: std.Io.File, expected_size: u64) !void {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != expected_size) return error.FailedPrecondition;
}

fn digestFile(file: std.Io.File, expected_size: u64) !Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var size_bytes: u64 = 0;
    var buffer: [copy_buffer_len]u8 = undefined;
    while (true) {
        const n = try readFd(file.handle, &buffer);
        if (n == 0) break;
        if (@as(u64, n) > expected_size - size_bytes) return error.FailedPrecondition;
        hasher.update(buffer[0..n]);
        size_bytes += n;
    }
    if (size_bytes != expected_size) return error.FailedPrecondition;

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
        switch (std.os.linux.errno(rc)) {
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
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
            0,
        );
        switch (std.os.linux.errno(rc)) {
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
    while (std.os.linux.errno(std.os.linux.nanosleep(&request, &request)) == .INTR) {}
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
    try std.testing.expectError(
        error.InvalidDigestSize,
        Digest.fromReapi(.{ .hash = digest.formatHex(&reapi_hash), .size_bytes = -1 }),
    );
}

test "CAS subpaths use two-character digest prefix sharding" {
    const digest = Digest.fromBytes("hello");
    const expected_hash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

    var blob_path_buffer: [blob_path_len]u8 = undefined;
    const blob_path = blobSubPath(digest, &blob_path_buffer);
    try std.testing.expectEqualStrings("blobs/sha256/2c/" ++ expected_hash, blob_path);

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

test "Store rejects existing blobs requested with forged digest sizes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    const actual = try store.putBytes(std.testing.io, "hello");
    const forged_short: Digest = .{ .hash = actual.hash, .size_bytes = 4 };
    const forged_long: Digest = .{ .hash = actual.hash, .size_bytes = 6 };
    const forged_huge: Digest = .{ .hash = actual.hash, .size_bytes = std.math.maxInt(u64) };

    try std.testing.expect(try store.has(std.testing.io, actual));
    try std.testing.expect(!try store.has(std.testing.io, forged_short));
    try std.testing.expect(!try store.has(std.testing.io, forged_long));
    try std.testing.expect(!try store.has(std.testing.io, forged_huge));

    var empty_storage: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&empty_storage);
    for ([_]Digest{ forged_short, forged_long, forged_huge }) |forged| {
        try std.testing.expectError(
            error.InvalidDigestSize,
            store.readAlloc(std.testing.io, fixed_allocator.allocator(), forged),
        );
        try std.testing.expectError(error.InvalidDigestSize, store.openBlob(std.testing.io, forged));
    }
}

test "Store rejects oversized blob allocations before allocating" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    const oversized: Digest = .{
        .hash = Digest.fromBytes("oversized allocation").hash,
        .size_bytes = max_alloc_blob_bytes + 1,
    };
    var path_buffer: [blob_path_len]u8 = undefined;
    const path = blobSubPath(oversized, &path_buffer);
    try tmp.dir.createDirPath(std.testing.io, digestParentPath(path));
    var file = try tmp.dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.setLength(std.testing.io, oversized.size_bytes);

    var empty_storage: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&empty_storage);
    try std.testing.expectError(
        error.FileTooBig,
        store.readAlloc(std.testing.io, fixed_allocator.allocator(), oversized),
    );
    try std.testing.expectError(
        error.FileTooBig,
        store.readAllocLimit(std.testing.io, fixed_allocator.allocator(), oversized, max_alloc_blob_bytes),
    );
    try std.testing.expect(try store.has(std.testing.io, oversized));
}

test "Store rejects nonregular objects at CAS blob paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    const digest = Digest.fromBytes("directory masquerading as a CAS blob");
    var path_buffer: [blob_path_len]u8 = undefined;
    const path = blobSubPath(digest, &path_buffer);
    try tmp.dir.createDirPath(std.testing.io, path);

    try std.testing.expect(!try store.has(std.testing.io, digest));
    try std.testing.expectError(error.FailedPrecondition, store.openBlob(std.testing.io, digest));
    try std.testing.expectError(
        error.FailedPrecondition,
        store.readAlloc(std.testing.io, std.testing.allocator, digest),
    );
}

test "Store does not follow symlinks at CAS blob paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    const digest = Digest.fromBytes("symlink target");
    var path_buffer: [blob_path_len]u8 = undefined;
    const path = blobSubPath(digest, &path_buffer);
    var parent = try tmp.dir.createDirPathOpen(std.testing.io, digestParentPath(path), .{});
    defer parent.close(std.testing.io);
    try parent.writeFile(std.testing.io, .{
        .sub_path = "actual",
        .data = "symlink target",
    });
    try parent.symLink(std.testing.io, "actual", path[path.len - digest_hex_len ..], .{});

    try std.testing.expect(!try store.has(std.testing.io, digest));
    try std.testing.expectError(error.FailedPrecondition, store.openBlob(std.testing.io, digest));
    try std.testing.expectError(
        error.FailedPrecondition,
        store.readAlloc(std.testing.io, std.testing.allocator, digest),
    );
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

test "Store refuses to publish over a truncated existing CAS blob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    const payload = "complete CAS contents";
    const digest = Digest.fromBytes(payload);
    var path_buffer: [blob_path_len]u8 = undefined;
    const path = blobSubPath(digest, &path_buffer);
    try tmp.dir.createDirPath(std.testing.io, digestParentPath(path));
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "bad",
    });

    try std.testing.expectError(
        error.FailedPrecondition,
        store.putKnownBytes(std.testing.io, digest, payload),
    );
    try std.testing.expectEqual(@as(u64, 3), (try tmp.dir.statFile(std.testing.io, path, .{})).size);
    try std.testing.expect(!try store.has(std.testing.io, digest));
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

test "BlobWriter refuses to publish over an existing CAS directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    const payload = "directory collision payload";
    const digest = Digest.fromBytes(payload);
    var path_buffer: [blob_path_len]u8 = undefined;
    const path = blobSubPath(digest, &path_buffer);
    try tmp.dir.createDirPath(std.testing.io, path);

    var writer = try store.beginBlobWriter(std.testing.io);
    defer writer.deinit(std.testing.io);
    try writer.writeAll(payload);
    try std.testing.expectError(error.FailedPrecondition, writer.finish(std.testing.io, digest));
    try std.testing.expectEqual(
        std.Io.File.Kind.directory,
        (try tmp.dir.statFile(std.testing.io, path, .{ .follow_symlinks = false })).kind,
    );
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

    var src = try stage.openFile(std.testing.io, "out.txt", .{});
    defer src.close(std.testing.io);
    const digest = try store.putOpenFileCopy(std.testing.io, &src, "copy me".len);
    try std.testing.expect(digest.eql(Digest.fromBytes("copy me")));
    try std.testing.expect(try store.has(std.testing.io, digest));
    const stat = try stage.statFile(std.testing.io, "out.txt", .{});
    try std.testing.expectEqual(@as(u64, "copy me".len), stat.size);
}

test "Store file promotion rejects growth after the file was inspected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.writeFile(std.testing.io, .{
        .sub_path = "out.txt",
        .data = "original",
    });
    const original_stat = try stage.statFile(std.testing.io, "out.txt", .{});
    try stage.writeFile(std.testing.io, .{
        .sub_path = "out.txt",
        .data = "original but grown after inspection",
    });
    const grown_stat = try stage.statFile(std.testing.io, "out.txt", .{});
    try std.testing.expectEqual(original_stat.inode, grown_stat.inode);
    try std.testing.expect(grown_stat.size > original_stat.size);

    try std.testing.expectError(
        error.FailedPrecondition,
        store.putFilePromoteWithStat(std.testing.io, stage, "out.txt", original_stat),
    );
    try std.testing.expect(!try store.has(
        std.testing.io,
        Digest.fromBytes("original but grown after inspection"),
    ));
}

test "Store file copying rejects bytes beyond the expected file size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.writeFile(std.testing.io, .{
        .sub_path = "out.txt",
        .data = "original but grown after inspection",
    });
    var src = try stage.openFile(std.testing.io, "out.txt", .{});
    defer src.close(std.testing.io);

    try std.testing.expectError(
        error.FailedPrecondition,
        store.putOpenFileCopy(std.testing.io, &src, "original".len),
    );
    try seekFd(src.handle, 0);
    try std.testing.expectError(
        error.FailedPrecondition,
        digestFile(src, "original".len),
    );
    try std.testing.expect(!try store.has(
        std.testing.io,
        Digest.fromBytes("original but grown after inspection"),
    ));
}

test "Store file promotion refuses an existing CAS symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    const payload = "promoted symlink collision";
    const digest = Digest.fromBytes(payload);
    var path_buffer: [blob_path_len]u8 = undefined;
    const path = blobSubPath(digest, &path_buffer);
    var blob_parent = try tmp.dir.createDirPathOpen(std.testing.io, digestParentPath(path), .{});
    defer blob_parent.close(std.testing.io);
    try blob_parent.writeFile(std.testing.io, .{
        .sub_path = "actual",
        .data = payload,
    });
    try blob_parent.symLink(std.testing.io, "actual", path[path.len - digest_hex_len ..], .{});

    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.writeFile(std.testing.io, .{
        .sub_path = "out.txt",
        .data = payload,
    });
    const stat = try stage.statFile(std.testing.io, "out.txt", .{});

    try std.testing.expectError(
        error.FailedPrecondition,
        store.putFilePromoteWithStat(std.testing.io, stage, "out.txt", stat),
    );
    try std.testing.expectEqual(
        std.Io.File.Kind.sym_link,
        (try tmp.dir.statFile(std.testing.io, path, .{ .follow_symlinks = false })).kind,
    );
    try std.testing.expectEqual(stat.inode, (try stage.statFile(std.testing.io, "out.txt", .{})).inode);
}

test "Store file promotion rejects a symlink replacing the inspected file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "external.txt",
        .data = "external contents",
    });
    const external_before = try tmp.dir.statFile(std.testing.io, "external.txt", .{});

    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.writeFile(std.testing.io, .{
        .sub_path = "out.txt",
        .data = "staged contents",
    });
    const original_stat = try stage.statFile(std.testing.io, "out.txt", .{});
    try stage.deleteFile(std.testing.io, "out.txt");
    try stage.symLink(std.testing.io, "../external.txt", "out.txt", .{});

    try std.testing.expectError(
        error.SymLinkLoop,
        store.putFilePromoteWithStat(std.testing.io, stage, "out.txt", original_stat),
    );

    const external_after = try tmp.dir.statFile(std.testing.io, "external.txt", .{});
    try std.testing.expectEqual(external_before.inode, external_after.inode);
    try std.testing.expectEqual(external_before.permissions.toMode(), external_after.permissions.toMode());
    try std.testing.expectEqual(external_before.size, external_after.size);
    try std.testing.expectEqual(
        std.Io.File.Kind.sym_link,
        (try stage.statFile(std.testing.io, "out.txt", .{ .follow_symlinks = false })).kind,
    );
    try std.testing.expect(!try store.has(std.testing.io, Digest.fromBytes("external contents")));
}

test "Store file promotion rejects a different file replacing the inspected file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);

    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.writeFile(std.testing.io, .{
        .sub_path = "out.txt",
        .data = "original contents",
    });
    var original_file = try stage.openFile(std.testing.io, "out.txt", .{});
    defer original_file.close(std.testing.io);
    const original_stat = try original_file.stat(std.testing.io);
    try stage.deleteFile(std.testing.io, "out.txt");
    try stage.writeFile(std.testing.io, .{
        .sub_path = "out.txt",
        .data = "replacement contents",
    });

    try std.testing.expectError(
        error.FailedPrecondition,
        store.putFilePromoteWithStat(std.testing.io, stage, "out.txt", original_stat),
    );

    const replacement_stat = try stage.statFile(std.testing.io, "out.txt", .{});
    try std.testing.expectEqual(@as(u64, "replacement contents".len), replacement_stat.size);
    try std.testing.expect(!try store.has(std.testing.io, Digest.fromBytes("replacement contents")));
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
    const stat = try stage.statFile(std.testing.io, "out.txt", .{});
    const digest = try store.putFilePromoteWithStat(std.testing.io, stage, "out.txt", stat);
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
