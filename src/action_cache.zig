const std = @import("std");
const cas = @import("cas.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

const key_prefix = "ac/sha256/";

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
        try self.root.createDirPath(io, "ac/sha256");
    }

    pub fn put(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        action_digest: cas.Digest,
        result: reapi.ActionResult,
    ) !void {
        if (!self.layout_ready) try self.ensureLayout(io);
        const bytes = try reapi.encodeAlloc(allocator, result);
        defer allocator.free(bytes);

        const path = try keyPath(allocator, action_digest);
        defer allocator.free(path);
        try self.root.writeFile(io, .{
            .sub_path = path,
            .data = bytes,
            .flags = .{ .read = true },
        });
    }

    pub fn get(
        self: Store,
        io: std.Io,
        allocator: std.mem.Allocator,
        action_digest: cas.Digest,
    ) !Entry {
        const path = try keyPath(allocator, action_digest);
        defer allocator.free(path);
        const bytes = try self.root.readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        errdefer allocator.free(bytes);

        var reader = protobuf.Reader.init(bytes);
        return .{
            .bytes = bytes,
            .result = try reapi.ActionResult.decodeOwned(allocator, &reader),
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
