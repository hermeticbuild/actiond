const std = @import("std");
const bytestream = @import("bytestream.zig");
const cas = @import("cas.zig");
const grpc_record = @import("grpc_record.zig");
const protobuf = @import("protobuf_wire.zig");

pub const Error = error{
    DigestMismatch,
    EmptyWrite,
    IncompleteWrite,
    InvalidOffset,
    MissingResourceName,
};

pub const max_read_response_data_bytes = 1024 * 1024;

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

pub fn readGrpcRecords(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request: bytestream.ReadRequest,
) ![]u8 {
    const resource = try bytestream.parseBlobResource(allocator, request.resource_name);
    if (request.read_offset < 0) return error.InvalidOffset;
    const offset: usize = @intCast(request.read_offset);
    if (offset > resource.digest.size_bytes) return error.InvalidOffset;

    const available: usize = @intCast(resource.digest.size_bytes - offset);
    const limit: usize = if (request.read_limit <= 0)
        available
    else
        @min(available, @as(usize, @intCast(request.read_limit)));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (limit == 0) {
        try appendReadResponseRecord(allocator, &out, "");
    } else {
        var blob_file = try store.openBlob(io, resource.digest);
        defer blob_file.close(io);
        if (offset != 0) try seekFd(blob_file.handle, @intCast(offset));

        const buffer = try allocator.alloc(u8, max_read_response_data_bytes);
        defer allocator.free(buffer);

        var remaining = limit;
        while (remaining != 0) {
            const read_len = @min(remaining, buffer.len);
            const n = try readFd(blob_file.handle, buffer[0..read_len]);
            if (n == 0) return error.UnexpectedEof;
            try appendReadResponseRecord(allocator, &out, buffer[0..n]);
            remaining -= n;
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn appendReadResponseRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    data: []const u8,
) !void {
    const payload_len = if (data.len == 0) 0 else protobuf.bytesFieldLen(10, data.len);
    const record_len = try grpc_record.encodedLen(payload_len);
    try out.ensureUnusedCapacity(allocator, record_len);
    out.appendAssumeCapacity(0);
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(payload_len), .big);
    out.appendSliceAssumeCapacity(&len_bytes);
    if (data.len != 0) {
        appendVarintAssumeCapacity(out, (@as(u64, 10) << 3) | @intFromEnum(protobuf.WireType.length_delimited));
        appendVarintAssumeCapacity(out, data.len);
        out.appendSliceAssumeCapacity(data);
    }
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

pub fn writeGrpcRecords(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request_records: []const u8,
) !bytestream.WriteResponse {
    var records = grpc_record.Iterator.init(request_records);
    var resource_name: ?[]const u8 = null;
    var expected_digest: ?cas.Digest = null;
    var writer: ?cas.BlobWriter = null;
    defer if (writer) |*value| value.deinit(io);

    var committed_size: u64 = 0;
    var finished = false;
    while (try records.next()) |message| {
        var reader = protobuf.Reader.init(message.payload);
        const request = try bytestream.WriteRequest.decode(&reader);
        if (resource_name == null) {
            if (request.resource_name.len == 0) return error.MissingResourceName;
            resource_name = request.resource_name;
            const resource = try bytestream.parseBlobResource(allocator, request.resource_name);
            expected_digest = resource.digest;
            writer = try store.beginBlobWriter(io);
        } else if (request.resource_name.len != 0 and !std.mem.eql(u8, request.resource_name, resource_name.?)) {
            return error.MissingResourceName;
        }

        if (request.write_offset < 0) return error.InvalidOffset;
        if (@as(u64, @intCast(request.write_offset)) != committed_size) return error.InvalidOffset;
        try writer.?.writeAll(request.data);
        committed_size += request.data.len;
        if (request.finish_write) finished = true;
    }

    if (resource_name == null) return error.EmptyWrite;
    if (!finished) return error.IncompleteWrite;
    _ = try writer.?.finish(io, expected_digest.?);
    return .{ .committed_size = @intCast(committed_size) };
}

fn appendVarintAssumeCapacity(out: *std.ArrayListUnmanaged(u8), value: u64) void {
    var current = value;
    while (true) {
        if (current < 0x80) {
            out.appendAssumeCapacity(@intCast(current));
            return;
        }
        out.appendAssumeCapacity(@intCast((current & 0x7f) | 0x80));
        current >>= 7;
    }
}

fn seekFd(fd: std.Io.File.Handle, offset: i64) !void {
    while (true) {
        const rc = std.posix.system.lseek(fd, offset, std.posix.SEEK.SET);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.InvalidOffset,
        }
    }
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

test "writeGrpcRecords streams chunks into CAS" {
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

    const first_proto = try protobuf.encodeAlloc(std.testing.allocator, bytestream.WriteRequest{
        .resource_name = resource_name,
        .write_offset = 0,
        .data = "he",
    });
    defer std.testing.allocator.free(first_proto);
    const first_record = try grpc_record.encodeAlloc(std.testing.allocator, .{ .payload = first_proto });
    defer std.testing.allocator.free(first_record);
    const second_proto = try protobuf.encodeAlloc(std.testing.allocator, bytestream.WriteRequest{
        .write_offset = 2,
        .data = "llo",
        .finish_write = true,
    });
    defer std.testing.allocator.free(second_proto);
    const second_record = try grpc_record.encodeAlloc(std.testing.allocator, .{ .payload = second_proto });
    defer std.testing.allocator.free(second_record);

    const records = try std.mem.concat(std.testing.allocator, u8, &.{ first_record, second_record });
    defer std.testing.allocator.free(records);

    const response = try writeGrpcRecords(std.testing.io, std.testing.allocator, store, records);
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

test "readGrpcRecords chunks large blobs into multiple gRPC messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const data = try std.testing.allocator.alloc(u8, max_read_response_data_bytes + 7);
    defer std.testing.allocator.free(data);
    @memset(data[0..max_read_response_data_bytes], 'a');
    @memset(data[max_read_response_data_bytes..], 'b');

    const digest = try store.putBytes(std.testing.io, data);
    var hash: [64]u8 = undefined;
    const resource_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "blobs/{s}/{d}",
        .{ digest.formatHex(&hash), digest.size_bytes },
    );
    defer std.testing.allocator.free(resource_name);

    const records = try readGrpcRecords(std.testing.io, std.testing.allocator, store, .{
        .resource_name = resource_name,
    });
    defer std.testing.allocator.free(records);

    var it = grpc_record.Iterator.init(records);
    const first = (try it.next()).?;
    var first_reader = protobuf.Reader.init(first.payload);
    const first_response = try bytestream.ReadResponse.decode(&first_reader);
    try std.testing.expectEqual(@as(usize, max_read_response_data_bytes), first_response.data.len);

    const second = (try it.next()).?;
    var second_reader = protobuf.Reader.init(second.payload);
    const second_response = try bytestream.ReadResponse.decode(&second_reader);
    try std.testing.expectEqualStrings("bbbbbbb", second_response.data);

    try std.testing.expectEqual(@as(?grpc_record.Message, null), try it.next());
}
