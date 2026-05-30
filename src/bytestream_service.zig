const std = @import("std");
const build_options = @import("actiond_build_options");
const body_sink = @import("body_sink.zig");
const bytestream = @import("bytestream.zig");
const cas = @import("cas.zig");
const grpc_record = @import("grpc_record.zig");
const protobuf = @import("protobuf_wire.zig");
const staged_cas_index = @import("staged_cas_index.zig");

pub const Error = error{
    DigestMismatch,
    EmptyWrite,
    IncompleteWrite,
    InvalidOffset,
    MissingResourceName,
};

pub const max_read_response_data_bytes = 1024 * 1024;

var read_records = std.atomic.Value(u64).init(0);
var read_bytes = std.atomic.Value(u64).init(0);
var read_file_records = std.atomic.Value(u64).init(0);
var read_file_bytes = std.atomic.Value(u64).init(0);
var read_buffer_records = std.atomic.Value(u64).init(0);
var read_buffer_bytes = std.atomic.Value(u64).init(0);

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

pub fn writeReadGrpcRecords(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request: bytestream.ReadRequest,
    writer: body_sink.Writer,
) !void {
    const resource = try bytestream.parseBlobResource(allocator, request.resource_name);
    if (request.read_offset < 0) return error.InvalidOffset;
    const offset: usize = @intCast(request.read_offset);
    if (offset > resource.digest.size_bytes) return error.InvalidOffset;

    const available: usize = @intCast(resource.digest.size_bytes - offset);
    const limit: usize = if (request.read_limit <= 0)
        available
    else
        @min(available, @as(usize, @intCast(request.read_limit)));

    var record: std.ArrayListUnmanaged(u8) = .empty;
    defer record.deinit(allocator);

    if (limit == 0) {
        try appendReadResponseRecord(allocator, &record, "");
        addReadStats(0, .buffer);
        try writer.writeAll(io, allocator, record.items);
    } else {
        var blob_file = try store.openBlob(io, resource.digest);
        defer blob_file.close(io);

        if (writer.canWriteFileWithPrefix()) {
            var remaining = limit;
            var file_offset = offset;
            while (remaining != 0) {
                const chunk_len = @min(remaining, max_read_response_data_bytes);
                record.clearRetainingCapacity();
                try appendReadResponsePrefix(allocator, &record, chunk_len);
                addReadStats(chunk_len, .file);
                try writer.writeFileWithPrefix(
                    io,
                    allocator,
                    record.items,
                    blob_file.handle,
                    @intCast(file_offset),
                    chunk_len,
                );
                file_offset += chunk_len;
                remaining -= chunk_len;
            }
            return;
        }

        if (offset != 0) try seekFd(blob_file.handle, @intCast(offset));
        const buffer = try allocator.alloc(u8, max_read_response_data_bytes);
        defer allocator.free(buffer);
        var remaining = limit;
        while (remaining != 0) {
            const read_len = @min(remaining, buffer.len);
            const n = try readFd(blob_file.handle, buffer[0..read_len]);
            if (n == 0) return error.UnexpectedEof;
            record.clearRetainingCapacity();
            try appendReadResponseRecord(allocator, &record, buffer[0..n]);
            addReadStats(n, .buffer);
            try writer.writeAll(io, allocator, record.items);
            remaining -= n;
        }
    }
}

fn appendReadResponseRecord(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    data: []const u8,
) !void {
    try appendReadResponsePrefix(allocator, out, data.len);
    out.appendSliceAssumeCapacity(data);
}

fn appendReadResponsePrefix(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    data_len: usize,
) !void {
    const payload_len = if (data_len == 0) 0 else protobuf.bytesFieldLen(10, data_len);
    const record_len = try grpc_record.encodedLen(payload_len);
    try out.ensureUnusedCapacity(allocator, record_len);
    out.appendAssumeCapacity(0);
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(payload_len), .big);
    out.appendSliceAssumeCapacity(&len_bytes);
    if (data_len != 0) {
        appendVarintAssumeCapacity(out, (@as(u64, 10) << 3) | @intFromEnum(protobuf.WireType.length_delimited));
        appendVarintAssumeCapacity(out, data_len);
    }
}

const ReadPath = enum {
    file,
    buffer,
};

fn addReadStats(bytes: usize, path: ReadPath) void {
    if (comptime build_options.executor_timing_logs) {
        _ = read_records.fetchAdd(1, .monotonic);
        _ = read_bytes.fetchAdd(@intCast(bytes), .monotonic);
        switch (path) {
            .file => {
                _ = read_file_records.fetchAdd(1, .monotonic);
                _ = read_file_bytes.fetchAdd(@intCast(bytes), .monotonic);
            },
            .buffer => {
                _ = read_buffer_records.fetchAdd(1, .monotonic);
                _ = read_buffer_bytes.fetchAdd(@intCast(bytes), .monotonic);
            },
        }
    }
}

pub fn appendStats(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    if (comptime build_options.executor_timing_logs) {
        const text = try std.fmt.allocPrint(allocator,
            \\bytestream_read_records {d}
            \\bytestream_read_bytes {d}
            \\bytestream_read_file_records {d}
            \\bytestream_read_file_bytes {d}
            \\bytestream_read_buffer_records {d}
            \\bytestream_read_buffer_bytes {d}
            \\
        , .{
            read_records.load(.monotonic),
            read_bytes.load(.monotonic),
            read_file_records.load(.monotonic),
            read_file_bytes.load(.monotonic),
            read_buffer_records.load(.monotonic),
            read_buffer_bytes.load(.monotonic),
        });
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
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
    return try writeGrpcRecordsWithIndex(io, allocator, store, null, request_records);
}

pub fn writeGrpcRecordsWithIndex(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    presence_index: ?*staged_cas_index.Index,
    request_records: []const u8,
) !bytestream.WriteResponse {
    var stream = WriteGrpcStream.initWithIndex(store, presence_index);
    defer stream.deinit(io, allocator);
    try stream.append(io, allocator, request_records);
    return try stream.finish(io, allocator);
}

pub const WriteGrpcStream = struct {
    store: cas.Store,
    presence_index: ?*staged_cas_index.Index = null,
    pending: std.ArrayListUnmanaged(u8) = .empty,
    resource_name: ?[]u8 = null,
    expected_digest: ?cas.Digest = null,
    writer: ?cas.BlobWriter = null,
    start: ?std.Io.Timestamp = null,
    record_count: usize = 0,
    committed_size: u64 = 0,
    finished: bool = false,

    pub fn init(store: cas.Store) WriteGrpcStream {
        return .{ .store = store };
    }

    pub fn initWithIndex(store: cas.Store, presence_index: ?*staged_cas_index.Index) WriteGrpcStream {
        return .{ .store = store, .presence_index = presence_index };
    }

    pub fn deinit(self: *WriteGrpcStream, io: std.Io, allocator: std.mem.Allocator) void {
        if (self.writer) |*writer| writer.deinit(io);
        if (self.resource_name) |resource_name| allocator.free(resource_name);
        self.pending.deinit(allocator);
        self.* = undefined;
    }

    pub fn append(
        self: *WriteGrpcStream,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        if (self.pending.items.len == 0) {
            var offset: usize = 0;
            while (bytes.len - offset >= grpc_record.header_len) {
                const header = bytes[offset..][0..grpc_record.header_len];
                const compressed = switch (header[0]) {
                    0 => false,
                    1 => true,
                    else => return error.InvalidCompressionFlag,
                };
                if (compressed) return error.UnsupportedCompression;

                const payload_len = std.mem.readInt(u32, header[1..grpc_record.header_len], .big);
                const record_len = try grpc_record.encodedLen(payload_len);
                if (bytes.len - offset < record_len) break;

                const payload_start = offset + grpc_record.header_len;
                try self.appendPayload(io, allocator, bytes[payload_start..][0..payload_len]);
                offset += record_len;
            }

            if (offset == bytes.len) return;
            try self.pending.appendSlice(allocator, bytes[offset..]);
            return;
        }

        try self.pending.appendSlice(allocator, bytes);
        var offset: usize = 0;
        while (self.pending.items.len - offset >= grpc_record.header_len) {
            const header = self.pending.items[offset..][0..grpc_record.header_len];
            const compressed = switch (header[0]) {
                0 => false,
                1 => true,
                else => return error.InvalidCompressionFlag,
            };
            if (compressed) return error.UnsupportedCompression;

            const payload_len = std.mem.readInt(u32, header[1..grpc_record.header_len], .big);
            const record_len = try grpc_record.encodedLen(payload_len);
            if (self.pending.items.len - offset < record_len) break;

            const payload_start = offset + grpc_record.header_len;
            try self.appendPayload(io, allocator, self.pending.items[payload_start..][0..payload_len]);
            offset += record_len;
        }

        if (offset != 0) {
            const remaining_len = self.pending.items.len - offset;
            if (remaining_len != 0) {
                std.mem.copyForwards(
                    u8,
                    self.pending.items[0..remaining_len],
                    self.pending.items[offset..],
                );
            }
            self.pending.shrinkRetainingCapacity(remaining_len);
        }
    }

    pub fn finish(self: *WriteGrpcStream, io: std.Io, allocator: std.mem.Allocator) !bytestream.WriteResponse {
        if (self.pending.items.len != 0) return error.UnexpectedEof;
        if (self.resource_name == null) return error.EmptyWrite;
        if (!self.finished) return error.IncompleteWrite;

        const digest = try self.writer.?.finish(io, self.expected_digest.?);
        if (self.presence_index) |index| try index.add(io, allocator, digest);
        if (comptime build_options.executor_timing_logs) {
            const elapsed_ns = elapsedNs(self.start.?, std.Io.Clock.awake.now(io));
            if (shouldLogCasUpload(self.record_count, self.committed_size, elapsed_ns)) {
                std.log.info(
                    "cas bytestream_write timing records={d} bytes={d} elapsed_ns={d}",
                    .{ self.record_count, self.committed_size, elapsed_ns },
                );
            }
        }
        return .{ .committed_size = @intCast(self.committed_size) };
    }

    fn appendPayload(
        self: *WriteGrpcStream,
        io: std.Io,
        allocator: std.mem.Allocator,
        payload: []const u8,
    ) !void {
        if (self.finished) return error.InvalidOffset;
        if (comptime build_options.executor_timing_logs) {
            if (self.start == null) self.start = std.Io.Clock.awake.now(io);
        }
        self.record_count += 1;

        var reader = protobuf.Reader.init(payload);
        const request = try bytestream.WriteRequest.decode(&reader);
        if (self.resource_name == null) {
            if (request.resource_name.len == 0) return error.MissingResourceName;
            const resource = try bytestream.parseBlobResource(allocator, request.resource_name);
            self.resource_name = try allocator.dupe(u8, request.resource_name);
            self.expected_digest = resource.digest;
            self.writer = try self.store.beginBlobWriter(io);
        } else if (request.resource_name.len != 0 and
            !std.mem.eql(u8, request.resource_name, self.resource_name.?))
        {
            return error.MissingResourceName;
        }

        if (request.write_offset < 0) return error.InvalidOffset;
        if (@as(u64, @intCast(request.write_offset)) != self.committed_size) return error.InvalidOffset;
        try self.writer.?.writeAll(request.data);
        self.committed_size += request.data.len;
        if (request.finish_write) self.finished = true;
    }
};

fn shouldLogCasUpload(record_count: usize, bytes: u64, elapsed_ns: i96) bool {
    return record_count >= 128 or
        bytes >= 1024 * 1024 or
        (bytes >= 64 * 1024 and elapsed_ns >= 10 * std.time.ns_per_ms);
}

fn elapsedNs(start: std.Io.Timestamp, end: std.Io.Timestamp) i96 {
    return start.durationTo(end).nanoseconds;
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

test "WriteGrpcStream accepts records split across appends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const digest = cas.Digest.fromBytes("split-record");
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
        .data = "split",
    });
    defer std.testing.allocator.free(first_proto);
    const first_record = try grpc_record.encodeAlloc(std.testing.allocator, .{ .payload = first_proto });
    defer std.testing.allocator.free(first_record);
    const second_proto = try protobuf.encodeAlloc(std.testing.allocator, bytestream.WriteRequest{
        .write_offset = 5,
        .data = "-record",
        .finish_write = true,
    });
    defer std.testing.allocator.free(second_proto);
    const second_record = try grpc_record.encodeAlloc(std.testing.allocator, .{ .payload = second_proto });
    defer std.testing.allocator.free(second_record);
    const records = try std.mem.concat(std.testing.allocator, u8, &.{ first_record, second_record });
    defer std.testing.allocator.free(records);

    var stream = WriteGrpcStream.init(store);
    defer stream.deinit(std.testing.io, std.testing.allocator);
    try stream.append(std.testing.io, std.testing.allocator, records[0..3]);
    try stream.append(std.testing.io, std.testing.allocator, records[3..11]);
    try stream.append(std.testing.io, std.testing.allocator, records[11..]);
    const response = try stream.finish(std.testing.io, std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 12), response.committed_size);
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

test "writeReadGrpcRecords chunks large blobs into multiple gRPC messages" {
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

    var records: std.ArrayListUnmanaged(u8) = .empty;
    defer records.deinit(std.testing.allocator);
    var list_writer = body_sink.ArrayListWriter{ .out = &records };
    try writeReadGrpcRecords(std.testing.io, std.testing.allocator, store, .{
        .resource_name = resource_name,
    }, list_writer.writer());

    var it = grpc_record.Iterator.init(records.items);
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
