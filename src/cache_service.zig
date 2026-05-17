const std = @import("std");
const cas = @import("cas.zig");
const reapi = @import("reapi.zig");

pub fn findMissingBlobs(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request: reapi.FindMissingBlobsRequest,
) !reapi.FindMissingBlobsResponse {
    var missing: std.ArrayListUnmanaged(reapi.Digest) = .empty;
    errdefer missing.deinit(allocator);

    for (request.blob_digests) |digest| {
        const local = try cas.Digest.fromReapi(digest);
        if (!try store.has(io, local)) {
            try missing.append(allocator, digest);
        }
    }

    return .{ .missing_blob_digests = try missing.toOwnedSlice(allocator) };
}

pub fn deleteBlobs(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request: reapi.FindMissingBlobsRequest,
) !reapi.FindMissingBlobsResponse {
    var failed: std.ArrayListUnmanaged(reapi.Digest) = .empty;
    errdefer failed.deinit(allocator);

    for (request.blob_digests) |digest| {
        const local = cas.Digest.fromReapi(digest) catch {
            try failed.append(allocator, digest);
            continue;
        };
        store.deleteBlob(io, local) catch {
            try failed.append(allocator, digest);
        };
    }

    return .{ .missing_blob_digests = try failed.toOwnedSlice(allocator) };
}

pub fn batchUpdateBlobs(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request: reapi.BatchUpdateBlobsRequest,
) !reapi.BatchUpdateBlobsResponse {
    var responses: std.ArrayListUnmanaged(reapi.BatchUpdateBlobsResponse.Item) = .empty;
    errdefer responses.deinit(allocator);

    for (request.requests) |item| {
        const expected = cas.Digest.fromReapi(item.digest) catch {
            try responses.append(allocator, .{
                .digest = item.digest,
                .status = .{ .code = .invalid_argument, .message = "invalid digest" },
            });
            continue;
        };
        const actual = cas.Digest.fromBytes(item.data);
        if (!actual.eql(expected)) {
            try responses.append(allocator, .{
                .digest = item.digest,
                .status = .{ .code = .invalid_argument, .message = "digest mismatch" },
            });
            continue;
        }

        try store.putKnownBytes(io, expected, item.data);
        try responses.append(allocator, .{
            .digest = item.digest,
            .status = .{},
        });
    }

    return .{ .responses = try responses.toOwnedSlice(allocator) };
}

pub const BatchReadResult = struct {
    response: reapi.BatchReadBlobsResponse,

    pub fn deinit(self: *BatchReadResult, allocator: std.mem.Allocator) void {
        for (self.response.responses) |item| allocator.free(item.data);
        self.response.deinit(allocator);
        self.* = undefined;
    }
};

pub fn batchReadBlobs(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request: reapi.BatchReadBlobsRequest,
) !BatchReadResult {
    var responses: std.ArrayListUnmanaged(reapi.BatchReadBlobsResponse.Item) = .empty;
    errdefer {
        for (responses.items) |item| allocator.free(item.data);
        responses.deinit(allocator);
    }

    for (request.digests) |digest| {
        const local = cas.Digest.fromReapi(digest) catch {
            try responses.append(allocator, .{
                .digest = digest,
                .status = .{ .code = .invalid_argument, .message = "invalid digest" },
            });
            continue;
        };

        const data = store.readAlloc(io, allocator, local) catch |err| switch (err) {
            error.FileNotFound => {
                try responses.append(allocator, .{
                    .digest = digest,
                    .status = .{ .code = .not_found, .message = "blob not found" },
                });
                continue;
            },
            else => |e| return e,
        };
        errdefer allocator.free(data);

        try responses.append(allocator, .{
            .digest = digest,
            .data = data,
            .status = .{},
        });
    }

    return .{ .response = .{ .responses = try responses.toOwnedSlice(allocator) } };
}

test "findMissingBlobs returns only absent digests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const present = try store.putBytes(std.testing.io, "present");
    const absent = cas.Digest.fromBytes("absent");

    var present_hash: [64]u8 = undefined;
    var absent_hash: [64]u8 = undefined;
    var response = try findMissingBlobs(std.testing.io, std.testing.allocator, store, .{
        .blob_digests = &.{
            present.toReapi(&present_hash),
            absent.toReapi(&absent_hash),
        },
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.missing_blob_digests.len);
    try std.testing.expect(response.missing_blob_digests[0].eql(absent.toReapi(&absent_hash)));
}

test "deleteBlobs removes requested blobs and reports invalid digests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const present = try store.putBytes(std.testing.io, "present");
    const absent = cas.Digest.fromBytes("absent");

    var present_hash: [64]u8 = undefined;
    var absent_hash: [64]u8 = undefined;
    var response = try deleteBlobs(std.testing.io, std.testing.allocator, store, .{
        .blob_digests = &.{
            present.toReapi(&present_hash),
            absent.toReapi(&absent_hash),
            .{ .hash = "not-hex", .size_bytes = 1 },
        },
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(!try store.has(std.testing.io, present));
    try std.testing.expectEqual(@as(usize, 1), response.missing_blob_digests.len);
    try std.testing.expectEqualStrings("not-hex", response.missing_blob_digests[0].hash);
}

test "batchUpdateBlobs verifies digest before storing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const good = cas.Digest.fromBytes("good");
    const bad = cas.Digest.fromBytes("bad");

    var good_hash: [64]u8 = undefined;
    var bad_hash: [64]u8 = undefined;
    var response = try batchUpdateBlobs(std.testing.io, std.testing.allocator, store, .{
        .requests = &.{
            .{ .digest = good.toReapi(&good_hash), .data = "good" },
            .{ .digest = bad.toReapi(&bad_hash), .data = "different" },
        },
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), response.responses.len);
    try std.testing.expectEqual(reapi.StatusCode.ok, response.responses[0].status.code);
    try std.testing.expectEqual(reapi.StatusCode.invalid_argument, response.responses[1].status.code);
    try std.testing.expect(try store.has(std.testing.io, good));
    try std.testing.expect(!try store.has(std.testing.io, bad));
}

test "batchReadBlobs returns data or not_found status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const present = try store.putBytes(std.testing.io, "present");
    const absent = cas.Digest.fromBytes("absent");

    var present_hash: [64]u8 = undefined;
    var absent_hash: [64]u8 = undefined;
    var result = try batchReadBlobs(std.testing.io, std.testing.allocator, store, .{
        .digests = &.{
            present.toReapi(&present_hash),
            absent.toReapi(&absent_hash),
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.response.responses.len);
    try std.testing.expectEqual(reapi.StatusCode.ok, result.response.responses[0].status.code);
    try std.testing.expectEqualStrings("present", result.response.responses[0].data);
    try std.testing.expectEqual(reapi.StatusCode.not_found, result.response.responses[1].status.code);
}
