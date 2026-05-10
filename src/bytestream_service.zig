const std = @import("std");
const bytestream = @import("bytestream.zig");
const cas = @import("cas.zig");

pub const Error = error{
    DigestMismatch,
    EmptyWrite,
    IncompleteWrite,
    InvalidOffset,
    MissingResourceName,
};

pub const ReadResult = struct {
    response: bytestream.ReadResponse,

    pub fn deinit(self: *ReadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.response.data);
        self.* = undefined;
    }
};

pub fn read(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request: bytestream.ReadRequest,
) !ReadResult {
    const resource = try bytestream.parseBlobResource(allocator, request.resource_name);
    const blob = try store.readAlloc(io, allocator, resource.digest);
    errdefer allocator.free(blob);

    if (request.read_offset < 0) return error.InvalidOffset;
    const offset: usize = @intCast(request.read_offset);
    if (offset > blob.len) return error.InvalidOffset;

    const available = blob.len - offset;
    const limit: usize = if (request.read_limit <= 0)
        available
    else
        @min(available, @as(usize, @intCast(request.read_limit)));

    if (offset == 0 and limit == blob.len) {
        return .{ .response = .{ .data = blob } };
    }

    const data = try allocator.dupe(u8, blob[offset..][0..limit]);
    allocator.free(blob);
    return .{ .response = .{ .data = data } };
}

pub fn write(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    requests: []const bytestream.WriteRequest,
) !bytestream.WriteResponse {
    if (requests.len == 0) return error.EmptyWrite;

    const resource_name = requests[0].resource_name;
    if (resource_name.len == 0) return error.MissingResourceName;
    const resource = try bytestream.parseBlobResource(allocator, resource_name);

    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(allocator);

    var finished = false;
    for (requests) |request| {
        if (request.resource_name.len != 0 and !std.mem.eql(u8, request.resource_name, resource_name)) {
            return error.MissingResourceName;
        }
        if (request.write_offset < 0) return error.InvalidOffset;
        if (@as(usize, @intCast(request.write_offset)) != data.items.len) return error.InvalidOffset;
        try data.appendSlice(allocator, request.data);
        if (request.finish_write) finished = true;
    }
    if (!finished) return error.IncompleteWrite;

    const actual = cas.Digest.fromBytes(data.items);
    if (!actual.eql(resource.digest)) return error.DigestMismatch;
    _ = try store.putBytes(io, data.items);

    return .{ .committed_size = @intCast(data.items.len) };
}

test "write assembles chunks and stores verified blob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const digest = cas.Digest.fromBytes("hello");
    var hash: [64]u8 = undefined;
    const resource_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "uploads/u/blobs/{s}/{d}",
        .{ digest.formatHex(&hash), digest.size_bytes },
    );
    defer std.testing.allocator.free(resource_name);

    const response = try write(std.testing.io, std.testing.allocator, store, &.{
        .{ .resource_name = resource_name, .write_offset = 0, .data = "he" },
        .{ .write_offset = 2, .data = "llo", .finish_write = true },
    });
    try std.testing.expectEqual(@as(i64, 5), response.committed_size);
    try std.testing.expect(try store.has(std.testing.io, digest));
}

test "write rejects offset and digest mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const digest = cas.Digest.fromBytes("hello");
    var hash: [64]u8 = undefined;
    const resource_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "uploads/u/blobs/{s}/{d}",
        .{ digest.formatHex(&hash), digest.size_bytes },
    );
    defer std.testing.allocator.free(resource_name);

    try std.testing.expectError(error.InvalidOffset, write(std.testing.io, std.testing.allocator, store, &.{
        .{ .resource_name = resource_name, .write_offset = 1, .data = "hello", .finish_write = true },
    }));
    try std.testing.expectError(error.DigestMismatch, write(std.testing.io, std.testing.allocator, store, &.{
        .{ .resource_name = resource_name, .write_offset = 0, .data = "HELLO", .finish_write = true },
    }));
}

test "read returns requested byte range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const digest = try store.putBytes(std.testing.io, "abcdef");
    var hash: [64]u8 = undefined;
    const resource_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "blobs/{s}/{d}",
        .{ digest.formatHex(&hash), digest.size_bytes },
    );
    defer std.testing.allocator.free(resource_name);

    var result = try read(std.testing.io, std.testing.allocator, store, .{
        .resource_name = resource_name,
        .read_offset = 2,
        .read_limit = 3,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("cde", result.response.data);
}
