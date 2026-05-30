const std = @import("std");
const body_sink = @import("body_sink.zig");
const bytestream = @import("bytestream.zig");
const bytestream_service = @import("bytestream_service.zig");
const action_cache = @import("action_cache.zig");
const action_cache_service = @import("action_cache_service.zig");
const action_executor = @import("action_executor.zig");
const cache_service = @import("cache_service.zig");
const capabilities_service = @import("capabilities_service.zig");
const cas = @import("cas.zig");
const execution_service = @import("execution_service.zig");
const grpc_record = @import("grpc_record.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");
const staged_cas_index = @import("staged_cas_index.zig");
const tree_service = @import("tree_service.zig");

pub const Error = error{
    ExtraGrpcMessage,
    MissingGrpcMessage,
    UnsupportedMethod,
};

pub const cas_find_missing_blobs = "/build.bazel.remote.execution.v2.ContentAddressableStorage/FindMissingBlobs";
pub const cas_batch_update_blobs = "/build.bazel.remote.execution.v2.ContentAddressableStorage/BatchUpdateBlobs";
pub const cas_batch_read_blobs = "/build.bazel.remote.execution.v2.ContentAddressableStorage/BatchReadBlobs";
pub const cas_get_tree = "/build.bazel.remote.execution.v2.ContentAddressableStorage/GetTree";
pub const ac_get_action_result = "/build.bazel.remote.execution.v2.ActionCache/GetActionResult";
pub const ac_update_action_result = "/build.bazel.remote.execution.v2.ActionCache/UpdateActionResult";
pub const bytestream_read = "/google.bytestream.ByteStream/Read";
pub const bytestream_write = "/google.bytestream.ByteStream/Write";
pub const capabilities_get = "/build.bazel.remote.execution.v2.Capabilities/GetCapabilities";
pub const execution_execute = "/build.bazel.remote.execution.v2.Execution/Execute";

pub const Server = struct {
    store: cas.Store,
    action_cache_store: ?action_cache.Store = null,
    cas_presence_index: ?*staged_cas_index.Index = null,
    work_root: ?std.Io.Dir = null,
    execution_options: action_executor.ExecuteOptions = .{},

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

        if (std.mem.eql(u8, method, capabilities_get)) {
            var reader = protobuf.Reader.init(payload);
            const request = try reapi.GetCapabilitiesRequest.decode(&reader);
            return try encodeResponse(allocator, capabilities_service.getCapabilities(request));
        }

        if (std.mem.eql(u8, method, cas_find_missing_blobs)) {
            var reader = protobuf.Reader.init(payload);
            var request = try reapi.FindMissingBlobsRequest.decodeOwned(allocator, &reader);
            defer request.deinit(allocator);
            var response = try cache_service.findMissingBlobsWithIndex(
                io,
                allocator,
                self.store,
                self.cas_presence_index,
                request,
            );
            defer response.deinit(allocator);
            return try encodeResponse(allocator, response);
        }

        if (std.mem.eql(u8, method, cas_batch_update_blobs)) {
            var reader = protobuf.Reader.init(payload);
            var request = try reapi.BatchUpdateBlobsRequest.decodeOwned(allocator, &reader);
            defer request.deinit(allocator);
            var response = try cache_service.batchUpdateBlobsWithIndex(
                io,
                allocator,
                self.store,
                self.cas_presence_index,
                request,
            );
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

        if (std.mem.eql(u8, method, ac_get_action_result)) {
            const result_store = self.action_cache_store orelse return error.UnsupportedMethod;
            var reader = protobuf.Reader.init(payload);
            const request = try reapi.GetActionResultRequest.decode(&reader);
            var entry = try action_cache_service.getActionResult(io, allocator, result_store, request);
            defer entry.deinit(allocator);
            return try encodeResponse(allocator, entry.result);
        }

        if (std.mem.eql(u8, method, ac_update_action_result)) {
            const result_store = self.action_cache_store orelse return error.UnsupportedMethod;
            var reader = protobuf.Reader.init(payload);
            var request = try reapi.UpdateActionResultRequest.decodeOwned(allocator, &reader);
            defer request.deinit(allocator);
            const response = try action_cache_service.updateActionResult(io, allocator, result_store, request);
            return try encodeResponse(allocator, response);
        }

        return error.UnsupportedMethod;
    }

    pub fn handleServerStreamingResponse(
        self: Server,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        request_record: []const u8,
        writer: body_sink.Writer,
    ) !void {
        if (std.mem.eql(u8, method, bytestream_read)) {
            const payload = try singlePayload(request_record);
            var reader = protobuf.Reader.init(payload);
            const request = try bytestream.ReadRequest.decode(&reader);
            return try bytestream_service.writeReadGrpcRecords(io, allocator, self.store, request, writer);
        }

        if (std.mem.eql(u8, method, cas_get_tree)) {
            const payload = try singlePayload(request_record);
            var reader = protobuf.Reader.init(payload);
            const request = try reapi.GetTreeRequest.decode(&reader);
            return try tree_service.writeGetTreeGrpcRecords(io, allocator, self.store, request, writer);
        }

        if (std.mem.eql(u8, method, execution_execute)) {
            const payload = try singlePayload(request_record);
            const work_root = self.work_root orelse return error.UnsupportedMethod;
            var reader = protobuf.Reader.init(payload);
            const request = try reapi.ExecuteRequest.decode(&reader);
            var operation = try execution_service.execute(
                io,
                allocator,
                self.store,
                self.action_cache_store,
                work_root,
                request,
                self.execution_options,
            );
            defer operation.deinit(allocator);
            const response = try encodeResponse(allocator, operation.operation);
            defer allocator.free(response);
            return try writer.writeAll(io, allocator, response);
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
            const response = try bytestream_service.writeGrpcRecordsWithIndex(
                io,
                allocator,
                self.store,
                self.cas_presence_index,
                request_records,
            );
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

fn putProto(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    value: anytype,
) !cas.Digest {
    const bytes = try reapi.encodeAlloc(allocator, value);
    defer allocator.free(bytes);
    return try store.putBytes(io, bytes);
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

    var read_response_records: std.ArrayListUnmanaged(u8) = .empty;
    defer read_response_records.deinit(std.testing.allocator);
    var read_list_writer = body_sink.ArrayListWriter{ .out = &read_response_records };
    try server.handleServerStreamingResponse(
        std.testing.io,
        std.testing.allocator,
        bytestream_read,
        read_request,
        read_list_writer.writer(),
    );
    var read_reader = protobuf.Reader.init(try singlePayload(read_response_records.items));
    const read_response = try bytestream.ReadResponse.decode(&read_reader);
    try std.testing.expectEqualStrings("load", read_response.data);
}

test "Server dispatches GetTree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const child_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{.{ .name = "leaf.txt" }},
    });
    var child_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{.{ .name = "child", .digest = child_digest.toReapi(&child_hash) }},
    });

    const server = Server.init(store);
    var root_hash: [64]u8 = undefined;
    const request = try encodeRequest(std.testing.allocator, reapi.GetTreeRequest{
        .root_digest = root_digest.toReapi(&root_hash),
    });
    defer std.testing.allocator.free(request);

    var response_records: std.ArrayListUnmanaged(u8) = .empty;
    defer response_records.deinit(std.testing.allocator);
    var list_writer = body_sink.ArrayListWriter{ .out = &response_records };
    try server.handleServerStreamingResponse(
        std.testing.io,
        std.testing.allocator,
        cas_get_tree,
        request,
        list_writer.writer(),
    );

    var records = grpc_record.Iterator.init(response_records.items);
    const root_record = (try records.next()).?;
    var root_reader = protobuf.Reader.init(root_record.payload);
    var root_response = try reapi.GetTreeResponse.decodeOwned(std.testing.allocator, &root_reader);
    defer root_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), root_response.directories.len);
    try std.testing.expectEqualStrings("child", root_response.directories[0].directories[0].name);

    const child_record = (try records.next()).?;
    var child_reader = protobuf.Reader.init(child_record.payload);
    var child_response = try reapi.GetTreeResponse.decodeOwned(std.testing.allocator, &child_reader);
    defer child_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), child_response.directories.len);
    try std.testing.expectEqualStrings("leaf.txt", child_response.directories[0].files[0].name);
    try std.testing.expectEqual(@as(?grpc_record.Message, null), try records.next());
}

test "Server dispatches ActionCache update and get" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var ac_dir = try tmp.dir.createDirPathOpen(std.testing.io, "ac", .{});
    defer ac_dir.close(std.testing.io);

    const action_digest = cas.Digest.fromBytes("action");
    const stdout_digest = cas.Digest.fromBytes("stdout");
    const tree_digest = cas.Digest.fromBytes("tree");
    const root_directory_digest = cas.Digest.fromBytes("root directory");
    var action_hash: [64]u8 = undefined;
    var stdout_hash: [64]u8 = undefined;
    var tree_hash: [64]u8 = undefined;
    var root_directory_hash: [64]u8 = undefined;

    const server: Server = .{
        .store = cas.Store.init(cas_dir),
        .action_cache_store = action_cache.Store.init(ac_dir),
    };

    const update_request = try encodeRequest(std.testing.allocator, reapi.UpdateActionResultRequest{
        .action_digest = action_digest.toReapi(&action_hash),
        .action_result = .{
            .exit_code = 2,
            .stdout_digest = stdout_digest.toReapi(&stdout_hash),
            .output_directories = &.{
                .{
                    .path = "out/tree",
                    .tree_digest = tree_digest.toReapi(&tree_hash),
                    .root_directory_digest = root_directory_digest.toReapi(&root_directory_hash),
                },
            },
        },
    });
    defer std.testing.allocator.free(update_request);

    const update_response_record = try server.handleUnary(
        std.testing.io,
        std.testing.allocator,
        ac_update_action_result,
        update_request,
    );
    defer std.testing.allocator.free(update_response_record);

    const get_request = try encodeRequest(std.testing.allocator, reapi.GetActionResultRequest{
        .action_digest = action_digest.toReapi(&action_hash),
    });
    defer std.testing.allocator.free(get_request);

    const get_response_record = try server.handleUnary(
        std.testing.io,
        std.testing.allocator,
        ac_get_action_result,
        get_request,
    );
    defer std.testing.allocator.free(get_response_record);

    var reader = protobuf.Reader.init(try singlePayload(get_response_record));
    var result = try reapi.ActionResult.decodeOwned(std.testing.allocator, &reader);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 2), result.exit_code);
    try std.testing.expect(result.stdout_digest.?.eql(stdout_digest.toReapi(&stdout_hash)));
    try std.testing.expectEqual(@as(usize, 1), result.output_directories.len);
    try std.testing.expectEqualStrings("out/tree", result.output_directories[0].path);
    try std.testing.expect(result.output_directories[0].tree_digest.?.eql(tree_digest.toReapi(&tree_hash)));
    try std.testing.expect(result.output_directories[0].root_directory_digest.?.eql(root_directory_digest.toReapi(&root_directory_hash)));
}

test "Server dispatches GetCapabilities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const server = Server.init(cas.Store.init(tmp.dir));
    const request = try encodeRequest(std.testing.allocator, reapi.GetCapabilitiesRequest{
        .instance_name = "local",
    });
    defer std.testing.allocator.free(request);

    const response_record = try server.handleUnary(
        std.testing.io,
        std.testing.allocator,
        capabilities_get,
        request,
    );
    defer std.testing.allocator.free(response_record);

    const payload = try singlePayload(response_record);
    try std.testing.expect(payload.len > 0);
}

test "Server dispatches cached Execute operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var ac_dir = try tmp.dir.createDirPathOpen(std.testing.io, "ac", .{});
    defer ac_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const blob_store = cas.Store.init(cas_dir);
    const action_digest = cas.Digest.fromBytes("cached dispatch action");
    const result_store = action_cache.Store.init(ac_dir);
    try result_store.put(std.testing.io, std.testing.allocator, action_digest, .{
        .exit_code = 0,
    });

    const server: Server = .{
        .store = blob_store,
        .action_cache_store = result_store,
        .work_root = work_dir,
    };

    var action_hash: [64]u8 = undefined;
    const request = try encodeRequest(std.testing.allocator, reapi.ExecuteRequest{
        .action_digest = action_digest.toReapi(&action_hash),
    });
    defer std.testing.allocator.free(request);

    var response_records: std.ArrayListUnmanaged(u8) = .empty;
    defer response_records.deinit(std.testing.allocator);
    var list_writer = body_sink.ArrayListWriter{ .out = &response_records };
    try server.handleServerStreamingResponse(
        std.testing.io,
        std.testing.allocator,
        execution_execute,
        request,
        list_writer.writer(),
    );

    var operation_reader = protobuf.Reader.init(try singlePayload(response_records.items));
    const operation = try reapi.Operation.decode(&operation_reader);
    try std.testing.expect(operation.done);
    try std.testing.expectEqualStrings(reapi.execute_response_type_url, operation.response.?.type_url);

    var execute_response_reader = protobuf.Reader.init(operation.response.?.value);
    const execute_response = try reapi.ExecuteResponse.decode(&execute_response_reader);
    try std.testing.expect(execute_response.cached_result);
    try std.testing.expectEqual(@as(i32, 0), execute_response.result.?.exit_code);
}
