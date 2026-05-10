const std = @import("std");
const cas = @import("cas.zig");
const http2_frame = @import("http2_frame.zig");
const http2_hpack = @import("http2_hpack.zig");
const grpc_record = @import("grpc_record.zig");
const reapi = @import("reapi.zig");
const reapi_dispatch = @import("reapi_dispatch.zig");

pub const Dispatcher = struct {
    ctx: *anyopaque,
    handle_unary: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    handle_server_streaming: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    handle_client_streaming: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,

    pub fn fromReapiServer(server: *reapi_dispatch.Server) Dispatcher {
        return .{
            .ctx = server,
            .handle_unary = reapiUnary,
            .handle_server_streaming = reapiServerStreaming,
            .handle_client_streaming = reapiClientStreaming,
        };
    }

    pub fn handleUnary(
        self: Dispatcher,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        return self.handle_unary(self.ctx, io, allocator, method, body);
    }

    pub fn handleServerStreaming(
        self: Dispatcher,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        return self.handle_server_streaming(self.ctx, io, allocator, method, body);
    }

    pub fn handleClientStreaming(
        self: Dispatcher,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        return self.handle_client_streaming(self.ctx, io, allocator, method, body);
    }

    fn reapiUnary(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        const server: *reapi_dispatch.Server = @ptrCast(@alignCast(ctx));
        return server.*.handleUnary(io, allocator, method, body);
    }

    fn reapiServerStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        const server: *reapi_dispatch.Server = @ptrCast(@alignCast(ctx));
        return server.*.handleServerStreaming(io, allocator, method, body);
    }

    fn reapiClientStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        const server: *reapi_dispatch.Server = @ptrCast(@alignCast(ctx));
        return server.*.handleClientStreaming(io, allocator, method, body);
    }
};

pub const Error = error{
    InvalidClientPreface,
    InvalidDataPadding,
    InvalidHeadersPadding,
    InvalidHeadersPriority,
    MissingPathHeader,
    UnexpectedContinuation,
    UnsupportedMethod,
};

pub const max_frame_payload_len = 16 * 1024 * 1024;
const response_frame_payload_len = http2_frame.default_max_frame_size;

pub const Config = struct {
    listen: []const u8 = "127.0.0.1:8980",
};

const MethodKind = enum {
    unary,
    server_streaming,
    client_streaming,
};

const IncomingFrame = struct {
    header: http2_frame.Header,
    payload: []u8,

    fn deinit(self: *IncomingFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

const StreamState = struct {
    id: u31,
    method: ?[]u8 = null,
    header_block: std.ArrayListUnmanaged(u8) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,

    fn init(id: u31) StreamState {
        return .{ .id = id };
    }

    fn deinit(self: *StreamState, allocator: std.mem.Allocator) void {
        if (self.method) |method| allocator.free(method);
        self.header_block.deinit(allocator);
        self.body.deinit(allocator);
        self.* = undefined;
    }
};

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    server: reapi_dispatch.Server,
) !void {
    var owned_server = server;
    return serveDispatcher(io, allocator, config, Dispatcher.fromReapiServer(&owned_server));
}

pub fn serveDispatcher(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    dispatcher: Dispatcher,
) !void {
    const address = try std.Io.net.IpAddress.parseLiteral(config.listen);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("actiond gRPC listening on {s}\n", .{config.listen});
    try stderr.flush();

    while (true) {
        const stream = try listener.accept(io);
        const thread = try std.Thread.spawn(.{}, connectionThread, .{
            io,
            allocator,
            dispatcher,
            stream,
        });
        thread.detach();
    }
}

fn connectionThread(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    stream: std.Io.net.Stream,
) void {
    var owned_stream = stream;
    defer owned_stream.close(io);

    handleConnection(io, allocator, dispatcher, owned_stream) catch |err| {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
        const stderr = &stderr_writer.interface;
        stderr.print("actiond gRPC connection failed: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
    };
}

pub fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    stream: std.Io.net.Stream,
) !void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var stream_writer = stream.writer(io, &write_buffer);
    try handleConnectionStreams(
        io,
        allocator,
        dispatcher,
        &stream_reader.interface,
        &stream_writer.interface,
    );
}

pub fn handleConnectionStreams(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    var preface: [http2_frame.client_connection_preface.len]u8 = undefined;
    try reader.readSliceAll(&preface);
    if (!std.mem.eql(u8, preface[0..], http2_frame.client_connection_preface)) {
        return error.InvalidClientPreface;
    }

    try sendServerSettings(writer);

    var hpack_decoder = http2_hpack.Decoder.init(allocator);
    defer hpack_decoder.deinit();

    var streams: std.ArrayListUnmanaged(StreamState) = .empty;
    defer {
        for (streams.items) |*stream| stream.deinit(allocator);
        streams.deinit(allocator);
    }

    var continuation_stream: ?u31 = null;
    while (true) {
        var incoming = readFrame(allocator, reader) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        defer incoming.deinit(allocator);

        if (continuation_stream != null and incoming.header.type != .continuation) {
            return error.UnexpectedContinuation;
        }

        switch (incoming.header.type) {
            .settings => {
                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_ack)) continue;
                _ = try http2_frame.SettingsIterator.init(incoming.payload);
                try writeFrame(writer, .{
                    .length = 0,
                    .type = .settings,
                    .flags = http2_frame.flag_ack,
                    .stream_id = 0,
                }, "");
                try writer.flush();
            },
            .ping => {
                if (!http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_ack)) {
                    try writeFrame(writer, .{
                        .length = incoming.payload.len,
                        .type = .ping,
                        .flags = http2_frame.flag_ack,
                        .stream_id = 0,
                    }, incoming.payload);
                    try writer.flush();
                }
            },
            .window_update => {
                _ = try http2_frame.decodeWindowUpdate(incoming.payload);
            },
            .headers => {
                const state = try getOrCreateStream(allocator, &streams, incoming.header.stream_id);
                const fragment = try headersFragment(incoming.header.flags, incoming.payload);
                try state.header_block.appendSlice(allocator, fragment);

                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_end_headers)) {
                    try finishHeaders(allocator, &hpack_decoder, state);
                    continuation_stream = null;
                } else {
                    continuation_stream = incoming.header.stream_id;
                }

                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_end_stream)) {
                    try respondAndRemove(io, allocator, dispatcher, writer, &streams, incoming.header.stream_id);
                }
            },
            .continuation => {
                if (continuation_stream != incoming.header.stream_id) return error.UnexpectedContinuation;
                const state = try getOrCreateStream(allocator, &streams, incoming.header.stream_id);
                try state.header_block.appendSlice(allocator, incoming.payload);
                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_end_headers)) {
                    try finishHeaders(allocator, &hpack_decoder, state);
                    continuation_stream = null;
                }
            },
            .data => {
                const state = try getOrCreateStream(allocator, &streams, incoming.header.stream_id);
                const data = try dataPayload(incoming.header.flags, incoming.payload);
                try state.body.appendSlice(allocator, data);
                if (data.len != 0) {
                    try sendWindowUpdate(writer, 0, data.len);
                    try sendWindowUpdate(writer, incoming.header.stream_id, data.len);
                    try writer.flush();
                }
                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_end_stream)) {
                    try respondAndRemove(io, allocator, dispatcher, writer, &streams, incoming.header.stream_id);
                }
            },
            .rst_stream => removeStream(allocator, &streams, incoming.header.stream_id),
            .goaway => return,
            .priority, .push_promise => {},
        }
    }
}

fn sendServerSettings(writer: *std.Io.Writer) !void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(std.heap.smp_allocator);
    try http2_frame.appendSettingsPayload(std.heap.smp_allocator, &payload, &.{
        .{ .id = .enable_push, .value = 0 },
        .{ .id = .max_concurrent_streams, .value = 128 },
        .{ .id = .initial_window_size, .value = 1024 * 1024 },
        .{ .id = .max_frame_size, .value = 1024 * 1024 },
    });
    try writeFrame(writer, .{
        .length = payload.items.len,
        .type = .settings,
        .flags = 0,
        .stream_id = 0,
    }, payload.items);
    try writer.flush();
}

fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) !IncomingFrame {
    var header_bytes: [http2_frame.header_len]u8 = undefined;
    try reader.readSliceAll(&header_bytes);
    const header = http2_frame.decodeHeader(&header_bytes);
    if (header.length > max_frame_payload_len) return error.FrameTooLarge;

    const payload = try allocator.alloc(u8, header.length);
    errdefer allocator.free(payload);
    try reader.readSliceAll(payload);

    return .{
        .header = header,
        .payload = payload,
    };
}

fn writeFrame(
    writer: *std.Io.Writer,
    header: http2_frame.Header,
    payload: []const u8,
) !void {
    var header_bytes: [http2_frame.header_len]u8 = undefined;
    var encoded_header = header;
    encoded_header.length = payload.len;
    try http2_frame.encodeHeader(&header_bytes, encoded_header);
    try writer.writeAll(&header_bytes);
    try writer.writeAll(payload);
}

fn sendWindowUpdate(writer: *std.Io.Writer, stream_id: u31, len: usize) !void {
    var remaining = len;
    while (remaining != 0) {
        const increment: u31 = @intCast(@min(remaining, std.math.maxInt(u31)));
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, increment, .big);
        try writeFrame(writer, .{
            .length = payload.len,
            .type = .window_update,
            .flags = 0,
            .stream_id = stream_id,
        }, &payload);
        remaining -= increment;
    }
}

fn headersFragment(flags: u8, payload: []const u8) ![]const u8 {
    var offset: usize = 0;
    var padding: usize = 0;
    if (http2_frame.hasFlag(flags, http2_frame.flag_padded)) {
        if (payload.len == 0) return error.InvalidHeadersPadding;
        padding = payload[0];
        offset = 1;
    }
    if (http2_frame.hasFlag(flags, http2_frame.flag_priority)) {
        if (payload.len < offset + 5) return error.InvalidHeadersPriority;
        offset += 5;
    }
    if (payload.len < offset + padding) return error.InvalidHeadersPadding;
    return payload[offset .. payload.len - padding];
}

fn dataPayload(flags: u8, payload: []const u8) ![]const u8 {
    var offset: usize = 0;
    var padding: usize = 0;
    if (http2_frame.hasFlag(flags, http2_frame.flag_padded)) {
        if (payload.len == 0) return error.InvalidDataPadding;
        padding = payload[0];
        offset = 1;
    }
    if (payload.len < offset + padding) return error.InvalidDataPadding;
    return payload[offset .. payload.len - padding];
}

fn getOrCreateStream(
    allocator: std.mem.Allocator,
    streams: *std.ArrayListUnmanaged(StreamState),
    id: u31,
) !*StreamState {
    for (streams.items) |*stream| {
        if (stream.id == id) return stream;
    }
    try streams.append(allocator, StreamState.init(id));
    return &streams.items[streams.items.len - 1];
}

fn finishHeaders(
    allocator: std.mem.Allocator,
    decoder: *http2_hpack.Decoder,
    state: *StreamState,
) !void {
    var headers = try decoder.decodeHeaderBlockAlloc(allocator, state.header_block.items);
    defer headers.deinit(allocator);

    for (headers.items) |field| {
        if (std.mem.eql(u8, field.name, ":path")) {
            if (state.method) |old| allocator.free(old);
            state.method = try allocator.dupe(u8, field.value);
            return;
        }
    }

    return error.MissingPathHeader;
}

fn respondAndRemove(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    writer: *std.Io.Writer,
    streams: *std.ArrayListUnmanaged(StreamState),
    id: u31,
) !void {
    for (streams.items, 0..) |*state, i| {
        if (state.id != id) continue;
        defer {
            state.deinit(allocator);
            _ = streams.orderedRemove(i);
        }
        return respondStream(io, allocator, dispatcher, writer, state);
    }
}

fn respondStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    writer: *std.Io.Writer,
    state: *const StreamState,
) !void {
    const method = state.method orelse return sendGrpcError(writer, state.id, "13", "MissingPathHeader");
    const response_body = dispatchGrpc(io, allocator, dispatcher, method, state.body.items) catch |err| {
        const status = if (err == error.UnsupportedMethod) "12" else "13";
        return sendGrpcError(writer, state.id, status, @errorName(err));
    };
    defer allocator.free(response_body);
    return sendGrpcSuccess(writer, state.id, response_body);
}

fn dispatchGrpc(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    method: []const u8,
    body: []const u8,
) ![]u8 {
    const kind = methodKind(method) orelse return error.UnsupportedMethod;
    return switch (kind) {
        .unary => try dispatcher.handleUnary(io, allocator, method, body),
        .server_streaming => try dispatcher.handleServerStreaming(io, allocator, method, body),
        .client_streaming => try dispatcher.handleClientStreaming(io, allocator, method, body),
    };
}

fn methodKind(method: []const u8) ?MethodKind {
    if (std.mem.eql(u8, method, reapi_dispatch.bytestream_read)) return .server_streaming;
    if (std.mem.eql(u8, method, reapi_dispatch.bytestream_write)) return .client_streaming;
    if (std.mem.eql(u8, method, reapi_dispatch.cas_get_tree)) return .server_streaming;
    if (std.mem.eql(u8, method, reapi_dispatch.execution_execute)) return .server_streaming;

    if (std.mem.eql(u8, method, reapi_dispatch.capabilities_get)) return .unary;
    if (std.mem.eql(u8, method, reapi_dispatch.cas_find_missing_blobs)) return .unary;
    if (std.mem.eql(u8, method, reapi_dispatch.cas_batch_update_blobs)) return .unary;
    if (std.mem.eql(u8, method, reapi_dispatch.cas_batch_read_blobs)) return .unary;
    if (std.mem.eql(u8, method, reapi_dispatch.ac_get_action_result)) return .unary;
    if (std.mem.eql(u8, method, reapi_dispatch.ac_update_action_result)) return .unary;

    return null;
}

fn sendGrpcSuccess(writer: *std.Io.Writer, stream_id: u31, response_body: []const u8) !void {
    try sendHeaders(writer, stream_id, false, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
    });
    try sendData(writer, stream_id, response_body);
    try sendHeaders(writer, stream_id, true, &.{
        .{ .name = "grpc-status", .value = "0" },
    });
    try writer.flush();
}

fn sendGrpcError(
    writer: *std.Io.Writer,
    stream_id: u31,
    status: []const u8,
    message: []const u8,
) !void {
    try sendHeaders(writer, stream_id, false, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
    });
    try sendHeaders(writer, stream_id, true, &.{
        .{ .name = "grpc-status", .value = status },
        .{ .name = "grpc-message", .value = message },
    });
    try writer.flush();
}

fn sendHeaders(
    writer: *std.Io.Writer,
    stream_id: u31,
    end_stream: bool,
    headers: []const http2_hpack.HeaderView,
) !void {
    const encoded = try http2_hpack.encodeHeaderBlockAlloc(std.heap.smp_allocator, headers);
    defer std.heap.smp_allocator.free(encoded);

    const flags = http2_frame.flag_end_headers |
        if (end_stream) http2_frame.flag_end_stream else @as(u8, 0);
    try writeFrame(writer, .{
        .length = encoded.len,
        .type = .headers,
        .flags = flags,
        .stream_id = stream_id,
    }, encoded);
}

fn sendData(writer: *std.Io.Writer, stream_id: u31, body: []const u8) !void {
    var remaining = body;
    while (remaining.len != 0) {
        const chunk_len = @min(remaining.len, response_frame_payload_len);
        const chunk = remaining[0..chunk_len];
        try writeFrame(writer, .{
            .length = chunk.len,
            .type = .data,
            .flags = 0,
            .stream_id = stream_id,
        }, chunk);
        remaining = remaining[chunk_len..];
    }
}

fn removeStream(
    allocator: std.mem.Allocator,
    streams: *std.ArrayListUnmanaged(StreamState),
    id: u31,
) void {
    for (streams.items, 0..) |*stream, i| {
        if (stream.id != id) continue;
        stream.deinit(allocator);
        _ = streams.orderedRemove(i);
        return;
    }
}

fn encodeGrpcRequest(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const proto = try reapi.encodeAlloc(allocator, value);
    defer allocator.free(proto);
    return try grpc_record.encodeAlloc(allocator, .{ .payload = proto });
}

fn appendFrame(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    header: http2_frame.Header,
    payload: []const u8,
) !void {
    var header_bytes: [http2_frame.header_len]u8 = undefined;
    var encoded_header = header;
    encoded_header.length = payload.len;
    try http2_frame.encodeHeader(&header_bytes, encoded_header);
    try out.appendSlice(allocator, &header_bytes);
    try out.appendSlice(allocator, payload);
}

test "HTTP/2 connection dispatches a capabilities unary request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, http2_frame.client_connection_preface);
    try appendFrame(std.testing.allocator, &input, .{
        .length = 0,
        .type = .settings,
        .flags = 0,
        .stream_id = 0,
    }, "");

    const header_block = try http2_hpack.encodeHeaderBlockAlloc(std.testing.allocator, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = reapi_dispatch.capabilities_get },
        .{ .name = ":authority", .value = "localhost" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "te", .value = "trailers" },
    });
    defer std.testing.allocator.free(header_block);
    try appendFrame(std.testing.allocator, &input, .{
        .length = header_block.len,
        .type = .headers,
        .flags = http2_frame.flag_end_headers,
        .stream_id = 1,
    }, header_block);

    const request = try encodeGrpcRequest(std.testing.allocator, reapi.GetCapabilitiesRequest{});
    defer std.testing.allocator.free(request);
    try appendFrame(std.testing.allocator, &input, .{
        .length = request.len,
        .type = .data,
        .flags = http2_frame.flag_end_stream,
        .stream_id = 1,
    }, request);

    var reader = std.Io.Reader.fixed(input.items);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var server = reapi_dispatch.Server.init(cas.Store.init(tmp.dir));
    try handleConnectionStreams(
        std.testing.io,
        std.testing.allocator,
        Dispatcher.fromReapiServer(&server),
        &reader,
        &output.writer,
    );

    const bytes = output.writer.buffered();
    var response_reader = std.Io.Reader.fixed(bytes);

    var frame_count: usize = 0;
    var saw_response_data = false;
    var saw_success_trailer = false;
    var decoder = http2_hpack.Decoder.init(std.testing.allocator);
    defer decoder.deinit();

    while (true) {
        var frame = readFrame(std.testing.allocator, &response_reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        defer frame.deinit(std.testing.allocator);
        frame_count += 1;

        if (frame.header.type == .data and frame.header.stream_id == 1) {
            try std.testing.expect(frame.payload.len > 0);
            saw_response_data = true;
        }

        if (frame.header.type == .headers and frame.header.stream_id == 1 and
            http2_frame.hasFlag(frame.header.flags, http2_frame.flag_end_stream))
        {
            var trailers = try decoder.decodeHeaderBlockAlloc(std.testing.allocator, frame.payload);
            defer trailers.deinit(std.testing.allocator);
            for (trailers.items) |field| {
                if (std.mem.eql(u8, field.name, "grpc-status")) {
                    try std.testing.expectEqualStrings("0", field.value);
                    saw_success_trailer = true;
                }
            }
        }
    }

    try std.testing.expect(frame_count >= 5);
    try std.testing.expect(saw_response_data);
    try std.testing.expect(saw_success_trailer);
}
