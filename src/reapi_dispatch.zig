const std = @import("std");
const bytestream = @import("bytestream.zig");
const bytestream_service = @import("bytestream_service.zig");
const cache_service = @import("cache_service.zig");
const cas = @import("cas.zig");
const grpc_record = @import("grpc_record.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    ExtraGrpcMessage,
    MissingGrpcMessage,
    UnsupportedMethod,
};

pub const cas_find_missing_blobs = "/build.bazel.remote.execution.v2.ContentAddressableStorage/FindMissingBlobs";
pub const cas_batch_update_blobs = "/build.bazel.remote.execution.v2.ContentAddressableStorage/BatchUpdateBlobs";
pub const cas_batch_read_blobs = "/build.bazel.remote.execution.v2.ContentAddressableStorage/BatchReadBlobs";
pub const bytestream_read = "/google.bytestream.ByteStream/Read";
pub const bytestream_write = "/google.bytestream.ByteStream/Write";

pub const Server = struct {
    store: cas.Store,

    pub fn init(store: cas.Store) Server {
        return .{ .store = store };
    }

    pub fn handleUnary(
        self: Server,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        request_record: []const u8,
    ) ![]u8 {
        const payload = try singlePayload(request_record);

        if (std.mem.eql(u8, method, cas_find_missing_blobs)) {
            var reader = protobuf.Reader.init(payload);
            var request = try reapi.FindMissingBlobsRequest.decodeOwned(allocator, &reader);
            defer request.deinit(allocator);
            var response = try cache_service.findMissingBlobs(io, allocator, self.store, request);
            defer response.deinit(allocator);
            return try encodeResponse(allocator, response);
        }

        if (std.mem.eql(u8, method, cas_batch_update_blobs)) {
            var reader = protobuf.Reader.init(payload);
            var request = try reapi.BatchUpdateBlobsRequest.decodeOwned(allocator, &reader);
            defer request.deinit(allocator);
            var response = try cache_service.batchUpdateBlobs(io, allocator, self.store, request);
            defer response.deinit(allocator);
            return try encodeResponse(allocator, response);
        }

        if (std.mem.eql(u8, method, cas_batch_read_blobs)) {
            var reader = protobuf.Reader.init(payload);
            var request = try reapi.BatchReadBlobsRequest.decodeOwned(allocator, &reader);
            defer request.deinit(allocator);
            var result = try cache_service.batchReadBlobs(io, allocator, self.store, request);
            defer result.deinit(allocator);
            return try encodeResponse(allocator, result.response);
        }

        return error.UnsupportedMethod;
    }

    pub fn handleServerStreaming(
        self: Server,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        request_record: []const u8,
    ) ![]u8 {
        const payload = try singlePayload(request_record);

        if (std.mem.eql(u8, method, bytestream_read)) {
            var reader = protobuf.Reader.init(payload);
            const request = try bytestream.ReadRequest.decode(&reader);
            var result = try bytestream_service.read(io, allocator, self.store, request);
            defer result.deinit(allocator);
            return try encodeResponse(allocator, result.response);
        }

        return error.UnsupportedMethod;
    }

    pub fn handleClientStreaming(
        self: Server,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        request_records: []const u8,
    ) ![]u8 {
        if (std.mem.eql(u8, method, bytestream_write)) {
            var requests: std.ArrayListUnmanaged(bytestream.WriteRequest) = .empty;
            defer requests.deinit(allocator);

            var records = grpc_record.Iterator.init(request_records);
            while (try records.next()) |message| {
                var reader = protobuf.Reader.init(message.payload);
                try requests.append(allocator, try bytestream.WriteRequest.decode(&reader));
            }

            const response = try bytestream_service.write(io, allocator, self.store, requests.items);
            return try encodeResponse(allocator, response);
        }

        return error.UnsupportedMethod;
    }
};

fn singlePayload(record_bytes: []const u8) ![]const u8 {
    var it = grpc_record.Iterator.init(record_bytes);
    const message = (try it.next()) orelse return error.MissingGrpcMessage;
    if ((try it.next()) != null) return error.ExtraGrpcMessage;
    return message.payload;
}

fn encodeRequest(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const proto = try reapi.encodeAlloc(allocator, value);
    defer allocator.free(proto);
    return try grpc_record.encodeAlloc(allocator, .{ .payload = proto });
}

fn encodeResponse(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return encodeRequest(allocator, value);
}

test "Server dispatches FindMissingBlobs over gRPC records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const present = try store.putBytes(std.testing.io, "present");
    const absent = cas.Digest.fromBytes("absent");
    const server = Server.init(store);

    var present_hash: [64]u8 = undefined;
    var absent_hash: [64]u8 = undefined;
    const request = try encodeRequest(std.testing.allocator, reapi.FindMissingBlobsRequest{
        .blob_digests = &.{
            present.toReapi(&present_hash),
            absent.toReapi(&absent_hash),
        },
    });
    defer std.testing.allocator.free(request);

    const response_record = try server.handleUnary(
        std.testing.io,
        std.testing.allocator,
        cas_find_missing_blobs,
        request,
    );
    defer std.testing.allocator.free(response_record);

    const response_payload = try singlePayload(response_record);
    var reader = protobuf.Reader.init(response_payload);
    var response = try reapi.FindMissingBlobsResponse.decodeOwned(std.testing.allocator, &reader);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.missing_blob_digests.len);
    try std.testing.expect(response.missing_blob_digests[0].eql(absent.toReapi(&absent_hash)));
}

test "Server dispatches BatchUpdateBlobs and BatchReadBlobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const server = Server.init(store);
    const digest = cas.Digest.fromBytes("payload");

    var hash: [64]u8 = undefined;
    const update_request = try encodeRequest(std.testing.allocator, reapi.BatchUpdateBlobsRequest{
        .requests = &.{
            .{ .digest = digest.toReapi(&hash), .data = "payload" },
        },
    });
    defer std.testing.allocator.free(update_request);

    const update_response_record = try server.handleUnary(
        std.testing.io,
        std.testing.allocator,
        cas_batch_update_blobs,
        update_request,
    );
    defer std.testing.allocator.free(update_response_record);

    var update_reader = protobuf.Reader.init(try singlePayload(update_response_record));
    var update_response = try reapi.BatchUpdateBlobsResponse.decodeOwned(std.testing.allocator, &update_reader);
    defer update_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(reapi.StatusCode.ok, update_response.responses[0].status.code);

    const read_request = try encodeRequest(std.testing.allocator, reapi.BatchReadBlobsRequest{
        .digests = &.{digest.toReapi(&hash)},
    });
    defer std.testing.allocator.free(read_request);

    const read_response_record = try server.handleUnary(
        std.testing.io,
        std.testing.allocator,
        cas_batch_read_blobs,
        read_request,
    );
    defer std.testing.allocator.free(read_response_record);

    var read_reader = protobuf.Reader.init(try singlePayload(read_response_record));
    var read_response = try reapi.BatchReadBlobsResponse.decodeOwned(std.testing.allocator, &read_reader);
    defer read_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(reapi.StatusCode.ok, read_response.responses[0].status.code);
    try std.testing.expectEqualStrings("payload", read_response.responses[0].data);
}

test "Server dispatches ByteStream Write and Read record streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const server = Server.init(store);
    const digest = cas.Digest.fromBytes("payload");
    var hash: [64]u8 = undefined;
    const resource_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "uploads/u/blobs/{s}/{d}",
        .{ digest.formatHex(&hash), digest.size_bytes },
    );
    defer std.testing.allocator.free(resource_name);

    const first = try encodeRequest(std.testing.allocator, bytestream.WriteRequest{
        .resource_name = resource_name,
        .write_offset = 0,
        .data = "pay",
    });
    defer std.testing.allocator.free(first);
    const second = try encodeRequest(std.testing.allocator, bytestream.WriteRequest{
        .write_offset = 3,
        .finish_write = true,
        .data = "load",
    });
    defer std.testing.allocator.free(second);
    const write_stream = try std.mem.concat(std.testing.allocator, u8, &.{ first, second });
    defer std.testing.allocator.free(write_stream);

    const write_response_record = try server.handleClientStreaming(
        std.testing.io,
        std.testing.allocator,
        bytestream_write,
        write_stream,
    );
    defer std.testing.allocator.free(write_response_record);
    var write_reader = protobuf.Reader.init(try singlePayload(write_response_record));
    const write_response = try bytestream.WriteResponse.decode(&write_reader);
    try std.testing.expectEqual(@as(i64, 7), write_response.committed_size);

    const read_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "blobs/{s}/{d}",
        .{ digest.formatHex(&hash), digest.size_bytes },
    );
    defer std.testing.allocator.free(read_name);
    const read_request = try encodeRequest(std.testing.allocator, bytestream.ReadRequest{
        .resource_name = read_name,
        .read_offset = 3,
    });
    defer std.testing.allocator.free(read_request);

    const read_response_record = try server.handleServerStreaming(
        std.testing.io,
        std.testing.allocator,
        bytestream_read,
        read_request,
    );
    defer std.testing.allocator.free(read_response_record);
    var read_reader = protobuf.Reader.init(try singlePayload(read_response_record));
    const read_response = try bytestream.ReadResponse.decode(&read_reader);
    try std.testing.expectEqualStrings("load", read_response.data);
}
