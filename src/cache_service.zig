const std = @import("std");
const build_options = @import("actiond_build_options");
const cas = @import("cas.zig");
const reapi = @import("reapi.zig");
const staged_cas_index = @import("staged_cas_index.zig");

pub const max_batch_total_size_bytes: usize = 4 * 1024 * 1024;

pub fn findMissingBlobsWithIndex(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    presence_index: ?*staged_cas_index.Index,
    request: reapi.FindMissingBlobsRequest,
) !reapi.FindMissingBlobsResponse {
    var missing: std.ArrayListUnmanaged(reapi.Digest) = .empty;
    errdefer missing.deinit(allocator);

    for (request.blob_digests) |digest| {
        const local = try cas.Digest.fromReapi(digest);
        if (presence_index) |index| {
            if (index.contains(io, local)) continue;
        }
        if (!try store.has(io, local)) {
            try missing.append(allocator, digest);
        } else if (presence_index) |index| {
            try index.add(io, allocator, local);
        }
    }

    return .{ .missing_blob_digests = try missing.toOwnedSlice(allocator) };
}

pub fn batchUpdateBlobsWithIndex(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    presence_index: ?*staged_cas_index.Index,
    request: reapi.BatchUpdateBlobsRequest,
) !reapi.BatchUpdateBlobsResponse {
    const start = if (comptime build_options.executor_timing_logs)
        std.Io.Clock.awake.now(io)
    else
        undefined;
    var responses: std.ArrayListUnmanaged(reapi.BatchUpdateBlobsResponse.Item) = .empty;
    errdefer responses.deinit(allocator);

    var total_bytes: u64 = 0;
    var ok_count: usize = 0;
    var invalid_count: usize = 0;
    var remaining_batch_bytes: usize = max_batch_total_size_bytes;
    for (request.requests) |item| {
        total_bytes = std.math.add(u64, total_bytes, item.data.len) catch std.math.maxInt(u64);
        if (item.data.len > remaining_batch_bytes) {
            try responses.append(allocator, .{
                .digest = item.digest,
                .status = .{ .code = .resource_exhausted, .message = "batch update exceeds maximum size" },
            });
            invalid_count += 1;
            continue;
        }
        remaining_batch_bytes -= item.data.len;

        const expected = cas.Digest.fromReapi(item.digest) catch {
            try responses.append(allocator, .{
                .digest = item.digest,
                .status = .{ .code = .invalid_argument, .message = "invalid digest" },
            });
            invalid_count += 1;
            continue;
        };
        store.putKnownBytes(io, expected, item.data) catch |err| switch (err) {
            error.DigestMismatch, error.InvalidDigestSize => {
                try responses.append(allocator, .{
                    .digest = item.digest,
                    .status = .{ .code = .invalid_argument, .message = "digest mismatch" },
                });
                invalid_count += 1;
                continue;
            },
            else => |e| return e,
        };
        if (presence_index) |index| try index.add(io, allocator, expected);
        ok_count += 1;
        try responses.append(allocator, .{
            .digest = item.digest,
            .status = .{},
        });
    }

    if (comptime build_options.executor_timing_logs) {
        const elapsed_ns = elapsedNs(start, std.Io.Clock.awake.now(io));
        if (shouldLogCasUpload(request.requests.len, total_bytes, elapsed_ns)) {
            std.log.info(
                "cas batch_update timing blobs={d} ok={d} invalid={d} bytes={d} elapsed_ns={d}",
                .{ request.requests.len, ok_count, invalid_count, total_bytes, elapsed_ns },
            );
        }
    }

    return .{ .responses = try responses.toOwnedSlice(allocator) };
}

fn shouldLogCasUpload(blob_count: usize, bytes: u64, elapsed_ns: i96) bool {
    return blob_count >= 128 or
        bytes >= 1024 * 1024 or
        (bytes >= 64 * 1024 and elapsed_ns >= 10 * std.time.ns_per_ms);
}

fn elapsedNs(start: std.Io.Timestamp, end: std.Io.Timestamp) i96 {
    return start.durationTo(end).nanoseconds;
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

    var remaining_batch_bytes: usize = max_batch_total_size_bytes;
    for (request.digests) |digest| {
        const local = cas.Digest.fromReapi(digest) catch {
            try responses.append(allocator, .{
                .digest = digest,
                .status = .{ .code = .invalid_argument, .message = "invalid digest" },
            });
            continue;
        };

        const data = store.readAllocLimit(io, allocator, local, remaining_batch_bytes) catch |err| switch (err) {
            error.FileNotFound, error.InvalidDigestSize => {
                try responses.append(allocator, .{
                    .digest = digest,
                    .status = .{ .code = .not_found, .message = "blob not found" },
                });
                continue;
            },
            error.FileTooBig => {
                try responses.append(allocator, .{
                    .digest = digest,
                    .status = .{ .code = .resource_exhausted, .message = "batch read exceeds maximum size" },
                });
                continue;
            },
            else => |e| return e,
        };
        errdefer allocator.free(data);

        remaining_batch_bytes -= data.len;
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
    var response = try findMissingBlobsWithIndex(std.testing.io, std.testing.allocator, store, null, .{
        .blob_digests = &.{
            present.toReapi(&present_hash),
            absent.toReapi(&absent_hash),
        },
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.missing_blob_digests.len);
    try std.testing.expect(response.missing_blob_digests[0].eql(absent.toReapi(&absent_hash)));
}

test "findMissingBlobs treats forged digest sizes as missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const actual = try store.putBytes(std.testing.io, "present");
    const forged_short: cas.Digest = .{ .hash = actual.hash, .size_bytes = actual.size_bytes - 1 };
    const forged_huge: cas.Digest = .{ .hash = actual.hash, .size_bytes = std.math.maxInt(i64) };

    var actual_hash: [64]u8 = undefined;
    var short_hash: [64]u8 = undefined;
    var huge_hash: [64]u8 = undefined;
    var response = try findMissingBlobsWithIndex(std.testing.io, std.testing.allocator, store, null, .{
        .blob_digests = &.{
            actual.toReapi(&actual_hash),
            forged_short.toReapi(&short_hash),
            forged_huge.toReapi(&huge_hash),
        },
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), response.missing_blob_digests.len);
    try std.testing.expect(response.missing_blob_digests[0].eql(forged_short.toReapi(&short_hash)));
    try std.testing.expect(response.missing_blob_digests[1].eql(forged_huge.toReapi(&huge_hash)));
}

test "batchUpdateBlobs verifies digest before storing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const good = cas.Digest.fromBytes("good");
    const bad = cas.Digest.fromBytes("bad");

    var good_hash: [64]u8 = undefined;
    var bad_hash: [64]u8 = undefined;
    var response = try batchUpdateBlobsWithIndex(std.testing.io, std.testing.allocator, store, null, .{
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

test "batchUpdateBlobs enforces the advertised aggregate request size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    var index = staged_cas_index.Index{};
    defer index.deinit(std.testing.io, std.testing.allocator);

    const first_bytes = try std.testing.allocator.alloc(u8, 3 * 1024 * 1024);
    defer std.testing.allocator.free(first_bytes);
    @memset(first_bytes, 0x41);
    const second_bytes = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(second_bytes);
    @memset(second_bytes, 0x42);

    const first = cas.Digest.fromBytes(first_bytes);
    const second = cas.Digest.fromBytes(second_bytes);
    const third = cas.Digest.fromBytes("small");
    const invalid = cas.Digest.fromBytes("expected");
    var first_hash: [64]u8 = undefined;
    var second_hash: [64]u8 = undefined;
    var third_hash: [64]u8 = undefined;
    var invalid_hash: [64]u8 = undefined;
    var response = try batchUpdateBlobsWithIndex(std.testing.io, std.testing.allocator, store, &index, .{
        .requests = &.{
            .{ .digest = first.toReapi(&first_hash), .data = first_bytes },
            .{ .digest = second.toReapi(&second_hash), .data = second_bytes },
            .{ .digest = third.toReapi(&third_hash), .data = "small" },
            .{ .digest = invalid.toReapi(&invalid_hash), .data = "different" },
        },
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), response.responses.len);
    try std.testing.expectEqual(reapi.StatusCode.ok, response.responses[0].status.code);
    try std.testing.expectEqual(reapi.StatusCode.resource_exhausted, response.responses[1].status.code);
    try std.testing.expectEqual(reapi.StatusCode.ok, response.responses[2].status.code);
    try std.testing.expectEqual(reapi.StatusCode.invalid_argument, response.responses[3].status.code);
    try std.testing.expect(try store.has(std.testing.io, first));
    try std.testing.expect(!try store.has(std.testing.io, second));
    try std.testing.expect(try store.has(std.testing.io, third));
    try std.testing.expect(index.contains(std.testing.io, first));
    try std.testing.expect(!index.contains(std.testing.io, second));
    try std.testing.expect(index.contains(std.testing.io, third));
}

test "batchUpdateBlobs charges invalid uploads against the aggregate request limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    var index = staged_cas_index.Index{};
    defer index.deinit(std.testing.io, std.testing.allocator);

    const invalid_bytes = try std.testing.allocator.alloc(u8, 3 * 1024 * 1024);
    defer std.testing.allocator.free(invalid_bytes);
    @memset(invalid_bytes, 0x43);

    var first_invalid = cas.Digest.fromBytes(invalid_bytes);
    first_invalid.hash[0] ^= 0xff;
    var second_invalid = first_invalid;
    second_invalid.hash[1] ^= 0xff;
    const valid = cas.Digest.fromBytes("small");
    var first_hash: [64]u8 = undefined;
    var second_hash: [64]u8 = undefined;
    var valid_hash: [64]u8 = undefined;
    var response = try batchUpdateBlobsWithIndex(std.testing.io, std.testing.allocator, store, &index, .{
        .requests = &.{
            .{ .digest = first_invalid.toReapi(&first_hash), .data = invalid_bytes },
            .{ .digest = second_invalid.toReapi(&second_hash), .data = invalid_bytes },
            .{ .digest = valid.toReapi(&valid_hash), .data = "small" },
        },
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), response.responses.len);
    try std.testing.expectEqual(reapi.StatusCode.invalid_argument, response.responses[0].status.code);
    try std.testing.expectEqual(reapi.StatusCode.resource_exhausted, response.responses[1].status.code);
    try std.testing.expectEqual(reapi.StatusCode.ok, response.responses[2].status.code);
    try std.testing.expect(!try store.has(std.testing.io, first_invalid));
    try std.testing.expect(!try store.has(std.testing.io, second_invalid));
    try std.testing.expect(try store.has(std.testing.io, valid));
    try std.testing.expect(!index.contains(std.testing.io, first_invalid));
    try std.testing.expect(!index.contains(std.testing.io, second_invalid));
    try std.testing.expect(index.contains(std.testing.io, valid));
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

test "batchReadBlobs rejects forged digest sizes without allocating their size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const actual = try store.putBytes(std.testing.io, "present");
    const forged_short: cas.Digest = .{ .hash = actual.hash, .size_bytes = actual.size_bytes - 1 };
    const forged_huge: cas.Digest = .{ .hash = actual.hash, .size_bytes = std.math.maxInt(i64) };

    var short_hash: [64]u8 = undefined;
    var huge_hash: [64]u8 = undefined;
    var actual_hash: [64]u8 = undefined;
    var result = try batchReadBlobs(std.testing.io, std.testing.allocator, store, .{
        .digests = &.{
            forged_short.toReapi(&short_hash),
            forged_huge.toReapi(&huge_hash),
            actual.toReapi(&actual_hash),
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.response.responses.len);
    try std.testing.expectEqual(reapi.StatusCode.not_found, result.response.responses[0].status.code);
    try std.testing.expectEqual(reapi.StatusCode.not_found, result.response.responses[1].status.code);
    try std.testing.expectEqual(reapi.StatusCode.ok, result.response.responses[2].status.code);
    try std.testing.expectEqualStrings("present", result.response.responses[2].data);
}

test "batchReadBlobs enforces the advertised aggregate response size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const first_bytes = try std.testing.allocator.alloc(u8, 3 * 1024 * 1024);
    defer std.testing.allocator.free(first_bytes);
    @memset(first_bytes, 0x41);
    const second_bytes = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(second_bytes);
    @memset(second_bytes, 0x42);

    const first = try store.putBytes(std.testing.io, first_bytes);
    const second = try store.putBytes(std.testing.io, second_bytes);
    const third = try store.putBytes(std.testing.io, "small");
    var first_hash: [64]u8 = undefined;
    var second_hash: [64]u8 = undefined;
    var third_hash: [64]u8 = undefined;
    var result = try batchReadBlobs(std.testing.io, std.testing.allocator, store, .{
        .digests = &.{
            first.toReapi(&first_hash),
            second.toReapi(&second_hash),
            third.toReapi(&third_hash),
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.response.responses.len);
    try std.testing.expectEqual(reapi.StatusCode.ok, result.response.responses[0].status.code);
    try std.testing.expectEqualSlices(u8, first_bytes, result.response.responses[0].data);
    try std.testing.expectEqual(reapi.StatusCode.resource_exhausted, result.response.responses[1].status.code);
    try std.testing.expectEqual(reapi.StatusCode.ok, result.response.responses[2].status.code);
    try std.testing.expectEqualStrings("small", result.response.responses[2].data);
}
