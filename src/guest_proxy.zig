const std = @import("std");
const action_cache = @import("action_cache.zig");
const body_sink = @import("body_sink.zig");
const bytestream = @import("bytestream.zig");
const cas = @import("cas.zig");
const control_protocol = @import("control_protocol.zig");
const grpc_record = @import("grpc_record.zig");
const grpc_http2_server = @import("grpc_http2_server.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");
const reapi_dispatch = @import("reapi_dispatch.zig");

pub const Error = error{
    GuestApplicationError,
};

const max_batch_read_blob_bytes = 512 * 1024;
const max_batch_read_total_bytes = 4 * 1024 * 1024;

pub fn applicationError(body: []const u8) anyerror {
    if (std.mem.eql(u8, body, "FileNotFound")) return error.FileNotFound;
    if (std.mem.eql(u8, body, "UnsupportedMethod")) return error.UnsupportedMethod;
    return error.GuestApplicationError;
}

pub const OwnedResponse = struct {
    status: control_protocol.Status,
    body: []u8,

    pub fn deinit(self: *OwnedResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const ClientStream = struct {
    ctx: *anyopaque,
    append_fn: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8) anyerror!void,
    finish_fn: *const fn (*anyopaque, std.Io, std.mem.Allocator) anyerror!OwnedResponse,
    deinit_fn: *const fn (*anyopaque, std.Io, std.mem.Allocator) void,

    pub fn append(
        self: ClientStream,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        return self.append_fn(self.ctx, io, allocator, bytes);
    }

    pub fn finish(
        self: ClientStream,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !OwnedResponse {
        return self.finish_fn(self.ctx, io, allocator);
    }

    pub fn deinit(self: ClientStream, io: std.Io, allocator: std.mem.Allocator) void {
        self.deinit_fn(self.ctx, io, allocator);
    }
};

pub const Transport = struct {
    ctx: *anyopaque,
    round_trip: *const fn (
        *anyopaque,
        std.Io,
        std.mem.Allocator,
        control_protocol.Request,
    ) anyerror!OwnedResponse,
    start_client_streaming: *const fn (
        *anyopaque,
        std.Io,
        std.mem.Allocator,
        []const u8,
    ) anyerror!ClientStream,
    stream_server_response: *const fn (
        *anyopaque,
        std.Io,
        std.mem.Allocator,
        []const u8,
        []const u8,
        body_sink.Writer,
    ) anyerror!void,

    pub fn call(
        self: Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
        request: control_protocol.Request,
    ) !OwnedResponse {
        return self.round_trip(self.ctx, io, allocator, request);
    }

    pub fn startClientStreaming(
        self: Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
    ) !ClientStream {
        return self.start_client_streaming(self.ctx, io, allocator, method);
    }

    pub fn streamServerResponse(
        self: Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        writer: body_sink.Writer,
    ) !void {
        return self.stream_server_response(self.ctx, io, allocator, method, body, writer);
    }
};

pub const Proxy = struct {
    transport: Transport,
    local_server: ?*reapi_dispatch.Server = null,

    pub fn dispatcher(self: *Proxy) grpc_http2_server.Dispatcher {
        return .{
            .ctx = self,
            .handle_unary = unary,
            .handle_server_streaming = serverStreaming,
            .handle_server_streaming_response = serverStreamingResponse,
            .handle_client_streaming = clientStreaming,
            .start_client_streaming = startClientStreaming,
        };
    }

    fn unary(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        const self: *Proxy = @ptrCast(@alignCast(ctx));
        if (self.localDispatcher()) |local_dispatcher| {
            return local_dispatcher.handleUnary(io, allocator, method, body);
        }
        return self.forward(io, allocator, .unary, method, body);
    }

    fn serverStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        const self: *Proxy = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, method, reapi_dispatch.execution_execute)) {
            if (self.localDispatcher()) |local_dispatcher| {
                return local_dispatcher.handleServerStreaming(io, allocator, method, body);
            }
        }
        return self.forward(io, allocator, .server_streaming, method, body);
    }

    fn serverStreamingResponse(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        writer: body_sink.Writer,
    ) !void {
        const self: *Proxy = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, method, reapi_dispatch.execution_execute)) {
            return self.executeAndImport(io, allocator, body, writer);
        }
        if (self.localDispatcher()) |local_dispatcher| {
            return local_dispatcher.handleServerStreamingResponse(io, allocator, method, body, writer);
        }
        return self.transport.streamServerResponse(io, allocator, method, body, writer);
    }

    fn clientStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        const self: *Proxy = @ptrCast(@alignCast(ctx));
        if (self.localDispatcher()) |local_dispatcher| {
            return local_dispatcher.handleClientStreaming(io, allocator, method, body);
        }
        return self.forward(io, allocator, .client_streaming, method, body);
    }

    fn startClientStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
    ) !grpc_http2_server.ClientStream {
        const self: *Proxy = @ptrCast(@alignCast(ctx));
        if (self.localDispatcher()) |local_dispatcher| {
            return local_dispatcher.startClientStreaming(io, allocator, method);
        }
        var inner = try self.transport.startClientStreaming(io, allocator, method);
        errdefer inner.deinit(io, allocator);

        const stream = try allocator.create(ProxyClientStream);
        stream.* = .{
            .method = method,
            .inner = inner,
        };
        return .{
            .ctx = stream,
            .append_fn = ProxyClientStream.append,
            .finish_fn = ProxyClientStream.finish,
            .deinit_fn = ProxyClientStream.deinit,
        };
    }

    fn forward(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        kind: control_protocol.CallKind,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        var response = try self.transport.call(io, allocator, .{
            .kind = kind,
            .method = method,
            .body = body,
        });
        return switch (response.status) {
            .ok => response.body,
            .stream_chunk => {
                defer response.deinit(allocator);
                return error.GuestApplicationError;
            },
            .application_error => {
                defer response.deinit(allocator);
                const err = applicationError(response.body);
                if (err != error.FileNotFound) std.log.err("guest application error for {s}: {s}", .{ method, response.body });
                return err;
            },
        };
    }

    fn localDispatcher(self: *Proxy) ?grpc_http2_server.Dispatcher {
        const server = self.local_server orelse return null;
        return grpc_http2_server.Dispatcher.fromReapiServer(server);
    }

    fn executeAndImport(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        request_record: []const u8,
        writer: body_sink.Writer,
    ) !void {
        const response_record = try self.forward(io, allocator, .server_streaming, reapi_dispatch.execution_execute, request_record);
        defer allocator.free(response_record);
        if (self.local_server) |local_server| {
            try self.importExecuteOutputs(io, allocator, local_server.*, request_record, response_record);
        }
        try writer.writeAll(io, allocator, response_record);
    }

    fn importExecuteOutputs(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        local_server: reapi_dispatch.Server,
        request_record: []const u8,
        response_record: []const u8,
    ) !void {
        const action_digest = try executeRequestActionDigest(request_record);
        try self.importExecuteResponseBlobs(
            io,
            allocator,
            local_server.store,
            local_server.action_cache_store,
            action_digest,
            response_record,
        );
    }

    fn importExecuteResponseBlobs(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        host_store: cas.Store,
        host_action_cache: ?action_cache.Store,
        action_digest: cas.Digest,
        response_record: []const u8,
    ) !void {
        var it = grpc_record.Iterator.init(response_record);
        const do_not_cache = if (host_action_cache != null)
            try actionDoNotCache(io, allocator, host_store, action_digest)
        else
            true;

        while (try it.next()) |message| {
            var operation_reader = protobuf.Reader.init(message.payload);
            const operation = try reapi.Operation.decode(&operation_reader);
            const response_any = operation.response orelse continue;
            if (!std.mem.eql(u8, response_any.type_url, reapi.execute_response_type_url)) continue;

            var execute_response = try decodeExecuteResponseOwned(allocator, response_any.value);
            defer deinitExecuteResponseOwned(allocator, &execute_response);
            const result = execute_response.result orelse continue;

            try self.importActionResultBlobs(io, allocator, host_store, result);
            if (!do_not_cache) {
                try host_action_cache.?.put(io, allocator, action_digest, result);
            }
        }
    }

    fn importActionResultBlobs(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        host_store: cas.Store,
        result: reapi.ActionResult,
    ) !void {
        var queue = ImportQueue{};
        defer queue.deinit(allocator);

        if (result.stdout_digest) |digest| try queue.addReapi(allocator, digest);
        if (result.stderr_digest) |digest| try queue.addReapi(allocator, digest);
        for (result.output_files) |file| {
            if (file.digest) |digest| try queue.addReapi(allocator, digest);
        }
        for (result.output_directories) |directory| {
            if (directory.tree_digest) |digest| try queue.addReapi(allocator, digest);
        }

        try self.importQueuedBlobs(io, allocator, host_store, &queue);

        for (result.output_directories) |directory| {
            if (directory.tree_digest) |digest| {
                try self.enqueueTreeContents(io, allocator, host_store, &queue, try cas.Digest.fromReapi(digest));
            }
        }
        try self.importQueuedBlobs(io, allocator, host_store, &queue);
    }

    fn enqueueTreeContents(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        host_store: cas.Store,
        queue: *ImportQueue,
        tree_digest: cas.Digest,
    ) !void {
        _ = self;

        const tree_bytes = try host_store.readAlloc(io, allocator, tree_digest);
        defer allocator.free(tree_bytes);

        var tree_reader = protobuf.Reader.init(tree_bytes);
        while (try tree_reader.next()) |tag| {
            switch (tag.field_number) {
                1, 2 => {
                    var nested = try tree_reader.readMessage();
                    _ = try host_store.putBytes(io, nested.bytes);
                    var directory = try reapi.Directory.decodeOwned(allocator, &nested);
                    defer directory.deinit(allocator);
                    for (directory.files) |file| {
                        if (file.digest) |digest| try queue.addReapi(allocator, digest);
                    }
                },
                else => try tree_reader.skipField(tag.wire_type),
            }
        }
    }

    fn importQueuedBlobs(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        host_store: cas.Store,
        queue: *ImportQueue,
    ) !void {
        if (queue.pending.items.len == 0) return;

        var missing: std.ArrayListUnmanaged(cas.Digest) = .empty;
        defer missing.deinit(allocator);
        for (queue.pending.items) |digest| {
            if (!try host_store.has(io, digest)) {
                try missing.append(allocator, digest);
            }
        }
        queue.pending.clearRetainingCapacity();

        var batch: std.ArrayListUnmanaged(cas.Digest) = .empty;
        defer batch.deinit(allocator);
        var batch_size: u64 = 0;
        for (missing.items) |digest| {
            if (digest.size_bytes <= max_batch_read_blob_bytes and batch_size <= max_batch_read_total_bytes - digest.size_bytes) {
                try batch.append(allocator, digest);
                batch_size += digest.size_bytes;
                continue;
            }

            try self.flushBatchRead(io, allocator, host_store, &batch, &batch_size);
            if (digest.size_bytes <= max_batch_read_blob_bytes) {
                try batch.append(allocator, digest);
                batch_size = digest.size_bytes;
            } else {
                try self.importBlobStream(io, allocator, host_store, digest);
            }
        }
        try self.flushBatchRead(io, allocator, host_store, &batch, &batch_size);
    }

    fn flushBatchRead(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        host_store: cas.Store,
        batch: *std.ArrayListUnmanaged(cas.Digest),
        batch_size: *u64,
    ) !void {
        if (batch.items.len == 0) return;
        try self.importBatchReadBlobs(io, allocator, host_store, batch.items);
        batch.clearRetainingCapacity();
        batch_size.* = 0;
    }

    fn importBatchReadBlobs(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        host_store: cas.Store,
        digests: []const cas.Digest,
    ) !void {
        var hash_storage = try allocator.alloc([64]u8, digests.len);
        defer allocator.free(hash_storage);
        const request_digests = try allocator.alloc(reapi.Digest, digests.len);
        defer allocator.free(request_digests);
        for (digests, 0..) |digest, i| {
            request_digests[i] = digest.toReapi(&hash_storage[i]);
        }

        const request_proto = try reapi.encodeAlloc(allocator, reapi.BatchReadBlobsRequest{
            .digests = request_digests,
        });
        defer allocator.free(request_proto);
        const request_record = try grpc_record.encodeAlloc(allocator, .{ .payload = request_proto });
        defer allocator.free(request_record);

        const response_record = try self.forward(io, allocator, .unary, reapi_dispatch.cas_batch_read_blobs, request_record);
        defer allocator.free(response_record);
        var reader = protobuf.Reader.init(try singlePayload(response_record));
        var response = try reapi.BatchReadBlobsResponse.decodeOwned(allocator, &reader);
        defer response.deinit(allocator);
        if (response.responses.len != digests.len) return error.UnexpectedEof;

        for (response.responses) |item| {
            const digest = try cas.Digest.fromReapi(item.digest);
            if (!containsDigest(digests, digest)) return error.DigestMismatch;
            if (item.status.code != .ok) return error.FileNotFound;
            try host_store.putKnownBytes(io, digest, item.data);
        }
    }

    fn importBlobStream(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        host_store: cas.Store,
        digest: cas.Digest,
    ) !void {
        var hash: [64]u8 = undefined;
        const resource_name = try std.fmt.allocPrint(allocator, "blobs/{s}/{d}", .{ digest.formatHex(&hash), digest.size_bytes });
        defer allocator.free(resource_name);
        const request_proto = try reapi.encodeAlloc(allocator, bytestream.ReadRequest{ .resource_name = resource_name });
        defer allocator.free(request_proto);
        const request_record = try grpc_record.encodeAlloc(allocator, .{ .payload = request_proto });
        defer allocator.free(request_record);

        var importer = try GuestBlobImporter.init(io, host_store, digest);
        defer importer.deinit(io, allocator);
        try self.transport.streamServerResponse(
            io,
            allocator,
            reapi_dispatch.bytestream_read,
            request_record,
            importer.writer(),
        );
        try importer.finish(io);
    }
};

const ImportQueue = struct {
    seen: std.AutoHashMapUnmanaged(cas.Digest, void) = .empty,
    pending: std.ArrayListUnmanaged(cas.Digest) = .empty,

    fn deinit(self: *ImportQueue, allocator: std.mem.Allocator) void {
        self.seen.deinit(allocator);
        self.pending.deinit(allocator);
        self.* = .{};
    }

    fn addReapi(
        self: *ImportQueue,
        allocator: std.mem.Allocator,
        digest: reapi.Digest,
    ) !void {
        try self.add(allocator, try cas.Digest.fromReapi(digest));
    }

    fn add(
        self: *ImportQueue,
        allocator: std.mem.Allocator,
        digest: cas.Digest,
    ) !void {
        if (digest.isEmpty()) return;
        const result = try self.seen.getOrPut(allocator, digest);
        if (result.found_existing) return;
        try self.pending.append(allocator, digest);
    }
};

fn containsDigest(haystack: []const cas.Digest, needle: cas.Digest) bool {
    for (haystack) |digest| {
        if (digest.eql(needle)) return true;
    }
    return false;
}

fn singlePayload(request_record: []const u8) ![]const u8 {
    var it = grpc_record.Iterator.init(request_record);
    const message = (try it.next()) orelse return error.MissingGrpcMessage;
    if ((try it.next()) != null) return error.ExtraGrpcMessage;
    return message.payload;
}

fn executeRequestActionDigest(request_record: []const u8) !cas.Digest {
    var reader = protobuf.Reader.init(try singlePayload(request_record));
    const request = try reapi.ExecuteRequest.decode(&reader);
    return cas.Digest.fromReapi(request.action_digest orelse return error.MissingActionDigest);
}

fn actionDoNotCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    action_digest: cas.Digest,
) !bool {
    const action_bytes = try store.readAlloc(io, allocator, action_digest);
    defer allocator.free(action_bytes);
    var reader = protobuf.Reader.init(action_bytes);
    return (try reapi.Action.decode(&reader)).do_not_cache;
}

fn decodeExecuteResponseOwned(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !reapi.ExecuteResponse {
    var reader = protobuf.Reader.init(bytes);
    var out: reapi.ExecuteResponse = .{};
    errdefer deinitExecuteResponseOwned(allocator, &out);
    while (try reader.next()) |tag| {
        switch (tag.field_number) {
            1 => {
                var nested = try reader.readMessage();
                out.result = try reapi.ActionResult.decodeOwned(allocator, &nested);
            },
            2 => out.cached_result = try reader.readBool(),
            3 => {
                var nested = try reader.readMessage();
                out.status = try reapi.Status.decode(&nested);
            },
            5 => out.message = try reader.readString(),
            else => try reader.skipField(tag.wire_type),
        }
    }
    return out;
}

fn deinitExecuteResponseOwned(allocator: std.mem.Allocator, response: *reapi.ExecuteResponse) void {
    if (response.result) |*result| result.deinit(allocator);
    response.* = .{};
}

const GuestBlobImporter = struct {
    expected: cas.Digest,
    writer_impl: cas.BlobWriter,
    pending: std.ArrayListUnmanaged(u8) = .empty,

    fn init(io: std.Io, store: cas.Store, expected: cas.Digest) !GuestBlobImporter {
        return .{
            .expected = expected,
            .writer_impl = try store.beginBlobWriter(io),
        };
    }

    fn writer(self: *GuestBlobImporter) body_sink.Writer {
        return .{
            .ctx = self,
            .write_all = writeAll,
        };
    }

    fn writeAll(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        _ = io;
        const self: *GuestBlobImporter = @ptrCast(@alignCast(ctx));
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
            var reader = protobuf.Reader.init(self.pending.items[payload_start..][0..payload_len]);
            const response = try bytestream.ReadResponse.decode(&reader);
            try self.writer_impl.writeAll(response.data);
            offset += record_len;
        }

        if (offset != 0) {
            const remaining_len = self.pending.items.len - offset;
            if (remaining_len != 0) {
                std.mem.copyForwards(u8, self.pending.items[0..remaining_len], self.pending.items[offset..]);
            }
            self.pending.shrinkRetainingCapacity(remaining_len);
        }
    }

    fn finish(self: *GuestBlobImporter, io: std.Io) !void {
        if (self.pending.items.len != 0) return error.UnexpectedEof;
        _ = try self.writer_impl.finish(io, self.expected);
    }

    fn deinit(self: *GuestBlobImporter, io: std.Io, allocator: std.mem.Allocator) void {
        self.writer_impl.deinit(io);
        self.pending.deinit(allocator);
        self.* = undefined;
    }
};

const ProxyClientStream = struct {
    method: []const u8,
    inner: ClientStream,

    fn append(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        const self: *ProxyClientStream = @ptrCast(@alignCast(ctx));
        try self.inner.append(io, allocator, bytes);
    }

    fn finish(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const self: *ProxyClientStream = @ptrCast(@alignCast(ctx));
        var response = try self.inner.finish(io, allocator);
        return switch (response.status) {
            .ok => response.body,
            .stream_chunk => {
                defer response.deinit(allocator);
                return error.GuestApplicationError;
            },
            .application_error => {
                defer response.deinit(allocator);
                const err = applicationError(response.body);
                if (err != error.FileNotFound) std.log.err("guest application error for {s}: {s}", .{ self.method, response.body });
                return err;
            },
        };
    }

    fn deinit(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        const self: *ProxyClientStream = @ptrCast(@alignCast(ctx));
        self.inner.deinit(io, allocator);
        allocator.destroy(self);
    }
};

const FakeTransport = struct {
    expected_kind: control_protocol.CallKind,
    expected_method: []const u8,
    expected_body: []const u8,
    response_body: []const u8,

    fn transport(self: *FakeTransport) Transport {
        return .{
            .ctx = self,
            .round_trip = roundTrip,
            .start_client_streaming = startClientStreaming,
            .stream_server_response = streamServerResponse,
        };
    }

    fn roundTrip(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        request: control_protocol.Request,
    ) !OwnedResponse {
        _ = io;
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(self.expected_kind, request.kind);
        try std.testing.expectEqualStrings(self.expected_method, request.method);
        try std.testing.expectEqualStrings(self.expected_body, request.body);
        return .{
            .status = .ok,
            .body = try allocator.dupe(u8, self.response_body),
        };
    }

    fn startClientStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
    ) !ClientStream {
        _ = ctx;
        _ = io;
        _ = allocator;
        _ = method;
        return error.UnsupportedMethod;
    }

    fn streamServerResponse(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        writer: body_sink.Writer,
    ) !void {
        const response = try roundTrip(ctx, io, allocator, .{
            .kind = .server_streaming,
            .method = method,
            .body = body,
        });
        defer {
            var owned = response;
            owned.deinit(allocator);
        }
        if (response.status != .ok) return error.GuestApplicationError;
        try writer.writeAll(io, allocator, response.body);
    }
};

test "Proxy forwards unary requests over control transport" {
    var fake = FakeTransport{
        .expected_kind = .unary,
        .expected_method = "/svc/Unary",
        .expected_body = "request",
        .response_body = "response",
    };
    var proxy = Proxy{ .transport = fake.transport() };
    const dispatcher = proxy.dispatcher();

    const response = try dispatcher.handleUnary(
        std.testing.io,
        std.testing.allocator,
        "/svc/Unary",
        "request",
    );
    defer std.testing.allocator.free(response);

    try std.testing.expectEqualStrings("response", response);
}

test "Proxy handles FindMissingBlobs against the host CAS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = cas.Store.init(tmp.dir);
    const present = try store.putBytes(std.testing.io, "present");
    const absent = cas.Digest.fromBytes("absent");
    var local_server = reapi_dispatch.Server.init(store);

    var fake = FakeTransport{
        .expected_kind = .unary,
        .expected_method = "/not-called",
        .expected_body = "",
        .response_body = "",
    };
    var proxy = Proxy{
        .transport = fake.transport(),
        .local_server = &local_server,
    };
    const dispatcher = proxy.dispatcher();

    var present_hash: [64]u8 = undefined;
    var absent_hash: [64]u8 = undefined;
    const request_proto = try reapi.encodeAlloc(std.testing.allocator, reapi.FindMissingBlobsRequest{
        .blob_digests = &.{
            present.toReapi(&present_hash),
            absent.toReapi(&absent_hash),
        },
    });
    defer std.testing.allocator.free(request_proto);
    const request_record = try grpc_record.encodeAlloc(std.testing.allocator, .{ .payload = request_proto });
    defer std.testing.allocator.free(request_record);

    const response_record = try dispatcher.handleUnary(
        std.testing.io,
        std.testing.allocator,
        reapi_dispatch.cas_find_missing_blobs,
        request_record,
    );
    defer std.testing.allocator.free(response_record);

    var records = grpc_record.Iterator.init(response_record);
    const message = (try records.next()).?;
    try std.testing.expect((try records.next()) == null);

    var response_reader = protobuf.Reader.init(message.payload);
    var response = try reapi.FindMissingBlobsResponse.decodeOwned(std.testing.allocator, &response_reader);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.missing_blob_digests.len);
    try std.testing.expect(response.missing_blob_digests[0].eql(absent.toReapi(&absent_hash)));
}

const BlobFixture = struct {
    digest: cas.Digest,
    data: []const u8,
};

const FakeBatchReadTransport = struct {
    blobs: []const BlobFixture,
    batch_read_calls: usize = 0,
    first_batch_len: usize = 0,
    second_batch_len: usize = 0,
    byte_stream_calls: usize = 0,

    fn transport(self: *FakeBatchReadTransport) Transport {
        return .{
            .ctx = self,
            .round_trip = roundTrip,
            .start_client_streaming = startClientStreaming,
            .stream_server_response = streamServerResponse,
        };
    }

    fn roundTrip(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        request: control_protocol.Request,
    ) !OwnedResponse {
        _ = io;
        const self: *FakeBatchReadTransport = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(control_protocol.CallKind.unary, request.kind);
        try std.testing.expectEqualStrings(reapi_dispatch.cas_batch_read_blobs, request.method);

        var request_reader = protobuf.Reader.init(try singlePayload(request.body));
        var batch_request = try reapi.BatchReadBlobsRequest.decodeOwned(allocator, &request_reader);
        defer batch_request.deinit(allocator);
        if (self.batch_read_calls == 0) {
            self.first_batch_len = batch_request.digests.len;
        } else if (self.batch_read_calls == 1) {
            self.second_batch_len = batch_request.digests.len;
        }
        self.batch_read_calls += 1;

        var responses: std.ArrayListUnmanaged(reapi.BatchReadBlobsResponse.Item) = .empty;
        defer responses.deinit(allocator);
        for (batch_request.digests) |digest| {
            const local = try cas.Digest.fromReapi(digest);
            if (self.findBlob(local)) |data| {
                try responses.append(allocator, .{
                    .digest = digest,
                    .data = data,
                    .status = .{},
                });
            } else {
                try responses.append(allocator, .{
                    .digest = digest,
                    .status = .{ .code = .not_found, .message = "missing" },
                });
            }
        }

        const payload = try reapi.encodeAlloc(allocator, reapi.BatchReadBlobsResponse{
            .responses = responses.items,
        });
        defer allocator.free(payload);
        return .{
            .status = .ok,
            .body = try grpc_record.encodeAlloc(allocator, .{ .payload = payload }),
        };
    }

    fn findBlob(self: *FakeBatchReadTransport, digest: cas.Digest) ?[]const u8 {
        for (self.blobs) |blob| {
            if (blob.digest.eql(digest)) return blob.data;
        }
        return null;
    }

    fn startClientStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
    ) !ClientStream {
        _ = ctx;
        _ = io;
        _ = allocator;
        _ = method;
        return error.UnexpectedRoundTrip;
    }

    fn streamServerResponse(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        writer: body_sink.Writer,
    ) !void {
        _ = io;
        _ = allocator;
        _ = method;
        _ = body;
        _ = writer;
        const self: *FakeBatchReadTransport = @ptrCast(@alignCast(ctx));
        self.byte_stream_calls += 1;
        return error.UnexpectedRoundTrip;
    }
};

test "Proxy imports execute outputs with batched CAS reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const host_store = cas.Store.init(tmp.dir);

    const output_digest = cas.Digest.fromBytes("output");
    const nested_file_digest = cas.Digest.fromBytes("nested");

    var nested_file_hash: [64]u8 = undefined;
    const child_directory = reapi.Directory{
        .files = &.{
            .{ .name = "nested.txt", .digest = nested_file_digest.toReapi(&nested_file_hash) },
        },
    };
    const child_directory_proto = try reapi.encodeAlloc(std.testing.allocator, child_directory);
    defer std.testing.allocator.free(child_directory_proto);
    const child_directory_digest = cas.Digest.fromBytes(child_directory_proto);

    var child_directory_hash: [64]u8 = undefined;
    const root_directory = reapi.Directory{
        .directories = &.{
            .{ .name = "sub", .digest = child_directory_digest.toReapi(&child_directory_hash) },
        },
    };
    const root_directory_proto = try reapi.encodeAlloc(std.testing.allocator, root_directory);
    defer std.testing.allocator.free(root_directory_proto);
    const root_directory_digest = cas.Digest.fromBytes(root_directory_proto);

    const tree_proto = try reapi.encodeAlloc(std.testing.allocator, reapi.Tree{
        .root = root_directory,
        .children = &.{child_directory},
    });
    defer std.testing.allocator.free(tree_proto);
    const tree_digest = cas.Digest.fromBytes(tree_proto);

    const blobs = [_]BlobFixture{
        .{ .digest = output_digest, .data = "output" },
        .{ .digest = tree_digest, .data = tree_proto },
        .{ .digest = nested_file_digest, .data = "nested" },
    };
    var fake = FakeBatchReadTransport{ .blobs = &blobs };
    var proxy = Proxy{ .transport = fake.transport() };

    var output_hash: [64]u8 = undefined;
    var tree_hash: [64]u8 = undefined;
    try proxy.importActionResultBlobs(std.testing.io, std.testing.allocator, host_store, .{
        .output_files = &.{
            .{ .path = "out.txt", .digest = output_digest.toReapi(&output_hash) },
        },
        .output_directories = &.{
            .{ .path = "tree", .tree_digest = tree_digest.toReapi(&tree_hash) },
        },
    });

    try std.testing.expectEqual(@as(usize, 2), fake.batch_read_calls);
    try std.testing.expectEqual(@as(usize, 2), fake.first_batch_len);
    try std.testing.expectEqual(@as(usize, 1), fake.second_batch_len);
    try std.testing.expectEqual(@as(usize, 0), fake.byte_stream_calls);

    const output = try host_store.readAlloc(std.testing.io, std.testing.allocator, output_digest);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("output", output);
    const nested = try host_store.readAlloc(std.testing.io, std.testing.allocator, nested_file_digest);
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("nested", nested);
    try std.testing.expect(try host_store.has(std.testing.io, tree_digest));
    try std.testing.expect(try host_store.has(std.testing.io, root_directory_digest));
    try std.testing.expect(try host_store.has(std.testing.io, child_directory_digest));
}

const FakeStreamingTransport = struct {
    expected_method: []const u8,
    response_body: []const u8,
    received: std.ArrayListUnmanaged(u8) = .empty,

    fn transport(self: *FakeStreamingTransport) Transport {
        return .{
            .ctx = self,
            .round_trip = roundTrip,
            .start_client_streaming = startClientStreaming,
            .stream_server_response = streamServerResponse,
        };
    }

    fn roundTrip(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        request: control_protocol.Request,
    ) !OwnedResponse {
        _ = ctx;
        _ = io;
        _ = allocator;
        _ = request;
        return error.UnexpectedRoundTrip;
    }

    fn startClientStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
    ) !ClientStream {
        _ = io;
        _ = allocator;
        const self: *FakeStreamingTransport = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqualStrings(self.expected_method, method);
        return .{
            .ctx = self,
            .append_fn = append,
            .finish_fn = finish,
            .deinit_fn = deinitStream,
        };
    }

    fn append(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        _ = io;
        const self: *FakeStreamingTransport = @ptrCast(@alignCast(ctx));
        try self.received.appendSlice(allocator, bytes);
    }

    fn finish(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !OwnedResponse {
        _ = io;
        const self: *FakeStreamingTransport = @ptrCast(@alignCast(ctx));
        return .{
            .status = .ok,
            .body = try allocator.dupe(u8, self.response_body),
        };
    }

    fn deinitStream(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = ctx;
        _ = io;
        _ = allocator;
    }

    fn streamServerResponse(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        writer: body_sink.Writer,
    ) !void {
        _ = ctx;
        _ = io;
        _ = allocator;
        _ = method;
        _ = body;
        _ = writer;
        return error.UnexpectedRoundTrip;
    }
};

test "Proxy forwards client streaming chunks over streaming transport" {
    var fake = FakeStreamingTransport{
        .expected_method = "/svc/Write",
        .response_body = "response",
    };
    defer fake.received.deinit(std.testing.allocator);
    var proxy = Proxy{ .transport = fake.transport() };
    const dispatcher = proxy.dispatcher();

    var stream = try dispatcher.startClientStreaming(
        std.testing.io,
        std.testing.allocator,
        "/svc/Write",
    );
    defer stream.deinit(std.testing.io, std.testing.allocator);
    try stream.append(std.testing.io, std.testing.allocator, "req");
    try stream.append(std.testing.io, std.testing.allocator, "uest");
    const response = try stream.finish(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqualStrings("request", fake.received.items);
    try std.testing.expectEqualStrings("response", response);
}
