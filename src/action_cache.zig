const std = @import("std");
const cas = @import("cas.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

pub const max_action_result_bytes: usize = 128 * 1024 * 1024;
const key_prefix = "sha256/";
var next_action_result_temp_id = std.atomic.Value(u64).init(0);

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
        try self.root.createDirPath(io, "sha256");
    }

    pub fn put(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        action_digest: cas.Digest,
        result: reapi.ActionResult,
    ) !void {
        if (result.encodedLen() > max_action_result_bytes) return error.ActionResultTooLarge;
        if (!self.layout_ready) try self.ensureLayout(io);
        const bytes = try reapi.encodeAlloc(allocator, result);
        defer allocator.free(bytes);

        const path = try keyPath(allocator, action_digest);
        defer allocator.free(path);
        while (true) {
            const id = next_action_result_temp_id.fetchAdd(1, .monotonic);
            const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ path, id });
            defer allocator.free(temp_path);

            var file = self.root.createFile(io, temp_path, .{
                .exclusive = true,
                .read = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };
            var closed = false;
            errdefer {
                if (!closed) file.close(io);
                self.root.deleteFile(io, temp_path) catch {};
            }

            try file.writeStreamingAll(io, bytes);
            file.close(io);
            closed = true;
            try self.root.rename(temp_path, self.root, path, io);
            return;
        }
    }

    pub fn get(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        action_digest: cas.Digest,
    ) !Entry {
        const path = try keyPath(allocator, action_digest);
        defer allocator.free(path);
        const bytes = try self.readActionResultBytes(io, allocator, path, max_action_result_bytes);
        errdefer allocator.free(bytes);

        var reader = protobuf.Reader.init(bytes);
        return .{
            .bytes = bytes,
            .result = try reapi.ActionResult.decodeOwned(allocator, &reader),
        };
    }

    fn readActionResultBytes(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        max_bytes: usize,
    ) ![]u8 {
        var file = self.root.openFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.SymLinkLoop, error.IsDir, error.NotDir => return error.FailedPrecondition,
            else => |e| return e,
        };
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.kind != .file) return error.FailedPrecondition;
        if (stat.size > max_bytes) return error.ActionResultTooLarge;
        const exclusive_limit = std.math.add(usize, max_bytes, 1) catch
            return error.ActionResultTooLarge;
        var reader = file.reader(io, &.{});
        return reader.interface.allocRemaining(allocator, .limited(exclusive_limit)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => return error.ActionResultTooLarge,
            else => |e| return e,
        };
    }
};

pub const Entry = struct {
    bytes: []u8,
    result: reapi.ActionResult,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

fn keyPath(allocator: std.mem.Allocator, action_digest: cas.Digest) ![]u8 {
    var hash: [64]u8 = undefined;
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}-{d}",
        .{ key_prefix, action_digest.formatHex(&hash), action_digest.size_bytes },
    );
}

test "Store persists ActionResult by action digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const action_digest = cas.Digest.fromBytes("action");
    const stdout_digest = cas.Digest.fromBytes("stdout");
    var stdout_hash: [64]u8 = undefined;

    const store = Store.init(tmp.dir);
    try store.put(std.testing.io, std.testing.allocator, action_digest, .{
        .exit_code = 3,
        .stdout_digest = stdout_digest.toReapi(&stdout_hash),
    });

    var entry = try store.get(std.testing.io, std.testing.allocator, action_digest);
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 3), entry.result.exit_code);
    try std.testing.expect(entry.result.stdout_digest.?.eql(stdout_digest.toReapi(&stdout_hash)));
}

test "Store replaces ActionResult through a complete temporary sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    const action_digest = cas.Digest.fromBytes("atomically replaced action result");
    try store.put(std.testing.io, std.testing.allocator, action_digest, .{ .exit_code = 1 });
    const path = try keyPath(std.testing.allocator, action_digest);
    defer std.testing.allocator.free(path);
    const before = try tmp.dir.statFile(std.testing.io, path, .{});

    try store.put(std.testing.io, std.testing.allocator, action_digest, .{ .exit_code = 2 });
    const after = try tmp.dir.statFile(std.testing.io, path, .{});
    try std.testing.expect(before.inode != after.inode);

    var result = try store.get(std.testing.io, std.testing.allocator, action_digest);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 2), result.result.exit_code);

    var directory = try tmp.dir.openDir(std.testing.io, "sha256", .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tmp-") == null);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Store rejects symlink and directory ActionCache entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);
    const action_digest = cas.Digest.fromBytes("invalid cached action result");
    const path = try keyPath(std.testing.allocator, action_digest);
    defer std.testing.allocator.free(path);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "outside",
        .data = &.{ 0x20, 0x01 },
    });
    try tmp.dir.symLink(std.testing.io, "../outside", path, .{});
    try std.testing.expectError(
        error.FailedPrecondition,
        store.get(std.testing.io, std.testing.allocator, action_digest),
    );
    try tmp.dir.deleteFile(std.testing.io, path);

    try tmp.dir.createDirPath(std.testing.io, path);
    try std.testing.expectError(
        error.FailedPrecondition,
        store.get(std.testing.io, std.testing.allocator, action_digest),
    );
}

test "Store reads valid ActionResult larger than one mebibyte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_files = try std.testing.allocator.alloc(reapi.OutputFile, 20_000);
    defer std.testing.allocator.free(output_files);
    const output_path = "generated/deeply/nested/output/file/whose/metadata/exceeds/the/previous/cache/limit.txt";
    for (output_files) |*file| file.* = .{ .path = output_path };

    const result: reapi.ActionResult = .{ .output_files = output_files };
    try std.testing.expect(result.encodedLen() > 1024 * 1024);

    const store = Store.init(tmp.dir);
    const action_digest = cas.Digest.fromBytes("large action result");
    try store.put(std.testing.io, std.testing.allocator, action_digest, result);

    var entry = try store.get(std.testing.io, std.testing.allocator, action_digest);
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqual(output_files.len, entry.result.output_files.len);
    try std.testing.expectEqualStrings(output_path, entry.result.output_files[0].path);
    try std.testing.expectEqualStrings(output_path, entry.result.output_files[output_files.len - 1].path);
}

test "Store accepts an ActionResult whose encoded size equals its read limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    const action_digest = cas.Digest.fromBytes("exact action result size");
    try store.put(std.testing.io, std.testing.allocator, action_digest, .{ .exit_code = 7 });

    const path = try keyPath(std.testing.allocator, action_digest);
    defer std.testing.allocator.free(path);
    const stat = try tmp.dir.statFile(std.testing.io, path, .{});
    const exact_size: usize = @intCast(stat.size);
    const bytes = try store.readActionResultBytes(
        std.testing.io,
        std.testing.allocator,
        path,
        exact_size,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(exact_size, bytes.len);
    try std.testing.expectError(
        error.ActionResultTooLarge,
        store.readActionResultBytes(
            std.testing.io,
            std.testing.allocator,
            path,
            exact_size - 1,
        ),
    );
}

test "Store rejects oversized ActionResult before allocating encoded bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var repeated_path: [4096]u8 = undefined;
    @memset(&repeated_path, 'x');
    const output_count = max_action_result_bytes / repeated_path.len + 1;
    const output_files = try std.testing.allocator.alloc(reapi.OutputFile, output_count);
    defer std.testing.allocator.free(output_files);
    for (output_files) |*file| file.* = .{ .path = &repeated_path };

    const result: reapi.ActionResult = .{ .output_files = output_files };
    try std.testing.expect(result.encodedLen() > max_action_result_bytes);

    var empty_storage: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&empty_storage);
    const store = Store.init(tmp.dir);
    try std.testing.expectError(
        error.ActionResultTooLarge,
        store.put(
            std.testing.io,
            fixed_allocator.allocator(),
            cas.Digest.fromBytes("oversized action result"),
            result,
        ),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "sha256", .{}));
}

test "Store rejects oversized cached ActionResult before allocating contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = Store.init(tmp.dir);
    try store.ensureLayout(std.testing.io);
    const action_digest = cas.Digest.fromBytes("oversized cached action result");
    const path = try keyPath(std.testing.allocator, action_digest);
    defer std.testing.allocator.free(path);
    var file = try tmp.dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.setLength(std.testing.io, max_action_result_bytes + 1);

    var empty_storage: [0]u8 = .{};
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&empty_storage);
    try std.testing.expectError(
        error.ActionResultTooLarge,
        store.readActionResultBytes(
            std.testing.io,
            fixed_allocator.allocator(),
            path,
            max_action_result_bytes,
        ),
    );
}
