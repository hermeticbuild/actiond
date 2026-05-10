const std = @import("std");
const body_sink = @import("body_sink.zig");
const bytestream = @import("bytestream.zig");
const bytestream_service = @import("bytestream_service.zig");
const cas = @import("cas.zig");
const http2_frame = @import("http2_frame.zig");
const http2_hpack = @import("http2_hpack.zig");
const grpc_record = @import("grpc_record.zig");
const reapi = @import("reapi.zig");
const reapi_dispatch = @import("reapi_dispatch.zig");

pub const ClientStream = struct {
    ctx: *anyopaque,
    append_fn: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8) anyerror!void,
    finish_fn: *const fn (*anyopaque, std.Io, std.mem.Allocator) anyerror![]u8,
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
    ) ![]u8 {
        return self.finish_fn(self.ctx, io, allocator);
    }

    pub fn deinit(self: ClientStream, io: std.Io, allocator: std.mem.Allocator) void {
        self.deinit_fn(self.ctx, io, allocator);
    }
};

pub const Dispatcher = struct {
    ctx: *anyopaque,
    handle_unary: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    handle_server_streaming: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    handle_server_streaming_response: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, []const u8, body_sink.Writer) anyerror!void,
    handle_client_streaming: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    start_client_streaming: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8) anyerror!ClientStream,

    pub fn fromReapiServer(server: *reapi_dispatch.Server) Dispatcher {
        return .{
            .ctx = server,
            .handle_unary = reapiUnary,
            .handle_server_streaming = reapiServerStreaming,
            .handle_server_streaming_response = reapiServerStreamingResponse,
            .handle_client_streaming = reapiClientStreaming,
            .start_client_streaming = reapiStartClientStreaming,
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

    pub fn handleServerStreamingResponse(
        self: Dispatcher,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        writer: body_sink.Writer,
    ) !void {
        return self.handle_server_streaming_response(self.ctx, io, allocator, method, body, writer);
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

    pub fn startClientStreaming(
        self: Dispatcher,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
    ) !ClientStream {
        return self.start_client_streaming(self.ctx, io, allocator, method);
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

    fn reapiServerStreamingResponse(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        writer: body_sink.Writer,
    ) !void {
        const server: *reapi_dispatch.Server = @ptrCast(@alignCast(ctx));
        return server.*.handleServerStreamingResponse(io, allocator, method, body, writer);
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

    fn reapiStartClientStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
    ) !ClientStream {
        const server: *reapi_dispatch.Server = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, method, reapi_dispatch.bytestream_write)) {
            const stream = try allocator.create(ByteStreamWriteClientStream);
            stream.* = .{
                .stream = bytestream_service.WriteGrpcStream.init(server.store),
            };
            return .{
                .ctx = stream,
                .append_fn = ByteStreamWriteClientStream.append,
                .finish_fn = ByteStreamWriteClientStream.finish,
                .deinit_fn = ByteStreamWriteClientStream.deinit,
            };
        }
        _ = io;
        const stream = try allocator.create(BufferedClientStream);
        stream.* = .{
            .server = server,
            .method = method,
        };
        return .{
            .ctx = stream,
            .append_fn = BufferedClientStream.append,
            .finish_fn = BufferedClientStream.finish,
            .deinit_fn = BufferedClientStream.deinit,
        };
    }
};

const ByteStreamWriteClientStream = struct {
    stream: bytestream_service.WriteGrpcStream,

    fn append(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        const self: *ByteStreamWriteClientStream = @ptrCast(@alignCast(ctx));
        try self.stream.append(io, allocator, bytes);
    }

    fn finish(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const self: *ByteStreamWriteClientStream = @ptrCast(@alignCast(ctx));
        const response = try self.stream.finish(io);
        return try encodeGrpcRequest(allocator, response);
    }

    fn deinit(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        const self: *ByteStreamWriteClientStream = @ptrCast(@alignCast(ctx));
        self.stream.deinit(io, allocator);
        allocator.destroy(self);
    }
};

const BufferedClientStream = struct {
    server: *reapi_dispatch.Server,
    method: []const u8,
    body: std.ArrayListUnmanaged(u8) = .empty,

    fn append(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        _ = io;
        const self: *BufferedClientStream = @ptrCast(@alignCast(ctx));
        try self.body.appendSlice(allocator, bytes);
    }

    fn finish(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const self: *BufferedClientStream = @ptrCast(@alignCast(ctx));
        return self.server.*.handleClientStreaming(io, allocator, self.method, self.body.items);
    }

    fn deinit(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        const self: *BufferedClientStream = @ptrCast(@alignCast(ctx));
        self.body.deinit(allocator);
        allocator.destroy(self);
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
const default_max_concurrent_streams = 128;

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
    client_stream: ?ClientStream = null,

    fn init(id: u31) StreamState {
        return .{ .id = id };
    }

    fn deinit(self: *StreamState, io: std.Io, allocator: std.mem.Allocator) void {
        if (self.client_stream) |client_stream| client_stream.deinit(io, allocator);
        if (self.method) |method| allocator.free(method);
        self.header_block.deinit(allocator);
        self.body.deinit(allocator);
        self.* = undefined;
    }
};

const SharedHttp2Writer = struct {
    mutex: std.Io.Mutex = .init,
    writer: *std.Io.Writer,

    fn sendServerSettings(self: *SharedHttp2Writer, io: std.Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try writeServerSettings(self.writer);
    }

    fn ackSettings(self: *SharedHttp2Writer, io: std.Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try writeFrame(self.writer, .{
            .length = 0,
            .type = .settings,
            .flags = http2_frame.flag_ack,
            .stream_id = 0,
        }, "");
        try self.writer.flush();
    }

    fn ackPing(self: *SharedHttp2Writer, io: std.Io, payload: []const u8) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try writeFrame(self.writer, .{
            .length = payload.len,
            .type = .ping,
            .flags = http2_frame.flag_ack,
            .stream_id = 0,
        }, payload);
        try self.writer.flush();
    }

    fn sendWindowUpdates(self: *SharedHttp2Writer, io: std.Io, stream_id: u31, len: usize) !void {
        if (len == 0) return;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try sendWindowUpdate(self.writer, 0, len);
        try sendWindowUpdate(self.writer, stream_id, len);
        try self.writer.flush();
    }

    fn sendGrpcSuccess(self: *SharedHttp2Writer, io: std.Io, stream_id: u31, response_body: []const u8) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try writeGrpcSuccess(self.writer, stream_id, response_body);
    }

    fn sendGrpcError(
        self: *SharedHttp2Writer,
        io: std.Io,
        stream_id: u31,
        status: []const u8,
        message: []const u8,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try writeGrpcError(self.writer, stream_id, status, message);
    }

    fn sendHeaders(
        self: *SharedHttp2Writer,
        io: std.Io,
        stream_id: u31,
        end_stream: bool,
        headers: []const http2_hpack.HeaderView,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try writeHeaders(self.writer, stream_id, end_stream, headers);
        try self.writer.flush();
    }

    fn sendData(self: *SharedHttp2Writer, io: std.Io, stream_id: u31, body: []const u8) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try writeData(self.writer, stream_id, body);
        try self.writer.flush();
    }
};

const ResponseTracker = struct {
    active: std.atomic.Value(u32) = .init(0),

    fn begin(self: *ResponseTracker) void {
        while (true) {
            const current = self.active.load(.monotonic);
            if (current >= default_max_concurrent_streams) {
                yieldThread();
                continue;
            }
            if (self.active.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) == null) return;
        }
    }

    fn finish(self: *ResponseTracker) void {
        _ = self.active.fetchSub(1, .monotonic);
    }

    fn wait(self: *ResponseTracker) void {
        while (self.active.load(.monotonic) != 0) {
            yieldThread();
        }
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

    var shared_writer = SharedHttp2Writer{ .writer = writer };
    var responses = ResponseTracker{};
    defer responses.wait();

    try shared_writer.sendServerSettings(io);

    var hpack_decoder = http2_hpack.Decoder.init(allocator);
    defer hpack_decoder.deinit();

    var streams: std.ArrayListUnmanaged(StreamState) = .empty;
    defer {
        for (streams.items) |*stream| stream.deinit(io, allocator);
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
                try shared_writer.ackSettings(io);
            },
            .ping => {
                if (!http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_ack)) {
                    try shared_writer.ackPing(io, incoming.payload);
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
                    try respondAndRemove(io, allocator, dispatcher, &shared_writer, &responses, &streams, incoming.header.stream_id);
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
                if (isClientStreaming(state)) {
                    try ensureClientStream(io, allocator, dispatcher, state);
                    try state.client_stream.?.append(io, allocator, data);
                } else {
                    try state.body.appendSlice(allocator, data);
                }
                try shared_writer.sendWindowUpdates(io, incoming.header.stream_id, data.len);
                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_end_stream)) {
                    try respondAndRemove(io, allocator, dispatcher, &shared_writer, &responses, &streams, incoming.header.stream_id);
                }
            },
            .rst_stream => removeStream(io, allocator, &streams, incoming.header.stream_id),
            .goaway => return,
            .priority, .push_promise => {},
        }
    }
}

fn writeServerSettings(writer: *std.Io.Writer) !void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(std.heap.smp_allocator);
    try http2_frame.appendSettingsPayload(std.heap.smp_allocator, &payload, &.{
        .{ .id = .enable_push, .value = 0 },
        .{ .id = .max_concurrent_streams, .value = default_max_concurrent_streams },
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
    writer: *SharedHttp2Writer,
    responses: *ResponseTracker,
    streams: *std.ArrayListUnmanaged(StreamState),
    id: u31,
) !void {
    for (streams.items, 0..) |*state, i| {
        if (state.id != id) continue;
        var owned_state = streams.orderedRemove(i);
        errdefer owned_state.deinit(io, allocator);

        const task = try allocator.create(ResponseTask);
        errdefer allocator.destroy(task);

        responses.begin();
        errdefer responses.finish();

        task.* = .{
            .io = io,
            .allocator = allocator,
            .dispatcher = dispatcher,
            .writer = writer,
            .responses = responses,
            .state = owned_state,
        };

        const thread = try std.Thread.spawn(.{}, ResponseTask.run, .{task});
        thread.detach();
        return;
    }
}

const ResponseTask = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    writer: *SharedHttp2Writer,
    responses: *ResponseTracker,
    state: StreamState,

    fn run(self: *ResponseTask) void {
        const io = self.io;
        const allocator = self.allocator;
        const responses = self.responses;
        defer responses.finish();
        defer allocator.destroy(self);
        defer self.state.deinit(io, allocator);

        respondStream(io, allocator, self.dispatcher, self.writer, &self.state) catch |err| {
            std.log.err("gRPC stream {d} response failed: {s}", .{ self.state.id, @errorName(err) });
        };
    }
};

fn respondStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    writer: *SharedHttp2Writer,
    state: *StreamState,
) !void {
    const method = state.method orelse return writer.sendGrpcError(io, state.id, "13", "MissingPathHeader");
    const kind = methodKind(method) orelse return writer.sendGrpcError(io, state.id, "12", "UnsupportedMethod");
    if (kind == .server_streaming) {
        return respondServerStreaming(io, allocator, dispatcher, writer, state, method);
    }

    const response_body = dispatchGrpc(io, allocator, dispatcher, state, method) catch |err| {
        const status = grpcStatusForError(err);
        if (!std.mem.eql(u8, status, "5")) std.log.err("gRPC {s} failed: {s}", .{ method, @errorName(err) });
        return writer.sendGrpcError(io, state.id, status, @errorName(err));
    };
    defer allocator.free(response_body);
    return writer.sendGrpcSuccess(io, state.id, response_body);
}

const Http2BodyWriter = struct {
    writer: *SharedHttp2Writer,
    stream_id: u31,

    fn bodyWriter(self: *Http2BodyWriter) body_sink.Writer {
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
        _ = allocator;
        const self: *Http2BodyWriter = @ptrCast(@alignCast(ctx));
        try self.writer.sendData(io, self.stream_id, bytes);
    }
};

fn respondServerStreaming(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    writer: *SharedHttp2Writer,
    state: *StreamState,
    method: []const u8,
) !void {
    try writer.sendHeaders(io, state.id, false, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
    });

    var body_writer = Http2BodyWriter{
        .writer = writer,
        .stream_id = state.id,
    };
    dispatcher.handleServerStreamingResponse(
        io,
        allocator,
        method,
        state.body.items,
        body_writer.bodyWriter(),
    ) catch |err| {
        const status = grpcStatusForError(err);
        if (!std.mem.eql(u8, status, "5")) std.log.err("gRPC {s} failed: {s}", .{ method, @errorName(err) });
        try writer.sendHeaders(io, state.id, true, &.{
            .{ .name = "grpc-status", .value = status },
            .{ .name = "grpc-message", .value = @errorName(err) },
        });
        return;
    };

    try writer.sendHeaders(io, state.id, true, &.{
        .{ .name = "grpc-status", .value = "0" },
    });
}

fn grpcStatusForError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "5",
        error.UnsupportedMethod => "12",
        else => "13",
    };
}

fn yieldThread() void {
    std.Thread.yield() catch std.atomic.spinLoopHint();
}

fn dispatchGrpc(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    state: *StreamState,
    method: []const u8,
) ![]u8 {
    const kind = methodKind(method) orelse return error.UnsupportedMethod;
    return switch (kind) {
        .unary => try dispatcher.handleUnary(io, allocator, method, state.body.items),
        .server_streaming => try dispatcher.handleServerStreaming(io, allocator, method, state.body.items),
        .client_streaming => blk: {
            try ensureClientStream(io, allocator, dispatcher, state);
            break :blk try state.client_stream.?.finish(io, allocator);
        },
    };
}

fn isClientStreaming(state: *const StreamState) bool {
    const method = state.method orelse return false;
    return methodKind(method) == .client_streaming;
}

fn ensureClientStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    state: *StreamState,
) !void {
    if (state.client_stream != null) return;
    const method = state.method orelse return error.MissingPathHeader;
    state.client_stream = try dispatcher.startClientStreaming(io, allocator, method);
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

fn writeGrpcSuccess(writer: *std.Io.Writer, stream_id: u31, response_body: []const u8) !void {
    try writeHeaders(writer, stream_id, false, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
    });
    try writeData(writer, stream_id, response_body);
    try writeHeaders(writer, stream_id, true, &.{
        .{ .name = "grpc-status", .value = "0" },
    });
    try writer.flush();
}

fn writeGrpcError(
    writer: *std.Io.Writer,
    stream_id: u31,
    status: []const u8,
    message: []const u8,
) !void {
    try writeHeaders(writer, stream_id, false, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
    });
    try writeHeaders(writer, stream_id, true, &.{
        .{ .name = "grpc-status", .value = status },
        .{ .name = "grpc-message", .value = message },
    });
    try writer.flush();
}

fn writeHeaders(
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

fn writeData(writer: *std.Io.Writer, stream_id: u31, body: []const u8) !void {
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
    io: std.Io,
    allocator: std.mem.Allocator,
    streams: *std.ArrayListUnmanaged(StreamState),
    id: u31,
) void {
    for (streams.items, 0..) |*stream, i| {
        if (stream.id != id) continue;
        stream.deinit(io, allocator);
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

fn appendGrpcRequestFrames(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    stream_id: u31,
    method: []const u8,
    request_body: []const u8,
) !void {
    const header_block = try http2_hpack.encodeHeaderBlockAlloc(allocator, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = method },
        .{ .name = ":authority", .value = "localhost" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "te", .value = "trailers" },
    });
    defer allocator.free(header_block);
    try appendFrame(allocator, out, .{
        .length = header_block.len,
        .type = .headers,
        .flags = http2_frame.flag_end_headers,
        .stream_id = stream_id,
    }, header_block);
    try appendFrame(allocator, out, .{
        .length = request_body.len,
        .type = .data,
        .flags = http2_frame.flag_end_stream,
        .stream_id = stream_id,
    }, request_body);
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

test "HTTP/2 connection responds to completed streams concurrently" {
    const Probe = struct {
        first_started: std.atomic.Value(u32) = .init(0),
        second_started: std.atomic.Value(u32) = .init(0),
        first_observed_second: std.atomic.Value(u32) = .init(0),

        fn dispatcher(self: *@This()) Dispatcher {
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
            _ = body;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, method, reapi_dispatch.capabilities_get)) {
                self.first_started.store(1, .monotonic);
                var waits: usize = 0;
                while (self.second_started.load(.monotonic) == 0 and waits < 100_000) : (waits += 1) {
                    yieldThread();
                }
                if (self.second_started.load(.monotonic) != 0) {
                    self.first_observed_second.store(1, .monotonic);
                }
                _ = io;
                return try allocator.dupe(u8, "first");
            }
            if (std.mem.eql(u8, method, reapi_dispatch.cas_find_missing_blobs)) {
                self.second_started.store(1, .monotonic);
                _ = io;
                return try allocator.dupe(u8, "second");
            }
            _ = io;
            return error.UnsupportedMethod;
        }

        fn serverStreaming(
            ctx: *anyopaque,
            io: std.Io,
            allocator: std.mem.Allocator,
            method: []const u8,
            body: []const u8,
        ) ![]u8 {
            return unary(ctx, io, allocator, method, body);
        }

        fn serverStreamingResponse(
            ctx: *anyopaque,
            io: std.Io,
            allocator: std.mem.Allocator,
            method: []const u8,
            body: []const u8,
            writer: body_sink.Writer,
        ) !void {
            const response = try serverStreaming(ctx, io, allocator, method, body);
            defer allocator.free(response);
            try writer.writeAll(io, allocator, response);
        }

        fn clientStreaming(
            ctx: *anyopaque,
            io: std.Io,
            allocator: std.mem.Allocator,
            method: []const u8,
            body: []const u8,
        ) ![]u8 {
            return unary(ctx, io, allocator, method, body);
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
    };

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, http2_frame.client_connection_preface);
    try appendFrame(std.testing.allocator, &input, .{
        .length = 0,
        .type = .settings,
        .flags = 0,
        .stream_id = 0,
    }, "");

    const request = try encodeGrpcRequest(std.testing.allocator, reapi.GetCapabilitiesRequest{});
    defer std.testing.allocator.free(request);
    try appendGrpcRequestFrames(std.testing.allocator, &input, 1, reapi_dispatch.capabilities_get, request);
    try appendGrpcRequestFrames(std.testing.allocator, &input, 3, reapi_dispatch.cas_find_missing_blobs, request);

    var probe = Probe{};
    var reader = std.Io.Reader.fixed(input.items);
    var output: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer output.deinit();

    try handleConnectionStreams(
        std.testing.io,
        std.heap.smp_allocator,
        probe.dispatcher(),
        &reader,
        &output.writer,
    );

    try std.testing.expectEqual(@as(u32, 1), probe.first_started.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), probe.second_started.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), probe.first_observed_second.load(.monotonic));

    var response_reader = std.Io.Reader.fixed(output.writer.buffered());
    var saw_first = false;
    var saw_second = false;
    while (true) {
        var frame = readFrame(std.testing.allocator, &response_reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        defer frame.deinit(std.testing.allocator);
        if (frame.header.type == .data and frame.header.stream_id == 1) {
            try std.testing.expectEqualStrings("first", frame.payload);
            saw_first = true;
        }
        if (frame.header.type == .data and frame.header.stream_id == 3) {
            try std.testing.expectEqualStrings("second", frame.payload);
            saw_second = true;
        }
    }
    try std.testing.expect(saw_first);
    try std.testing.expect(saw_second);
}

test "HTTP/2 client streaming dispatches DATA frames without buffered handler" {
    const Probe = struct {
        received: std.ArrayListUnmanaged(u8) = .empty,
        finished: bool = false,
        buffered_handler_called: bool = false,

        fn dispatcher(self: *@This()) Dispatcher {
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
            _ = ctx;
            _ = io;
            _ = allocator;
            _ = method;
            _ = body;
            return error.UnsupportedMethod;
        }

        fn serverStreaming(
            ctx: *anyopaque,
            io: std.Io,
            allocator: std.mem.Allocator,
            method: []const u8,
            body: []const u8,
        ) ![]u8 {
            return unary(ctx, io, allocator, method, body);
        }

        fn serverStreamingResponse(
            ctx: *anyopaque,
            io: std.Io,
            allocator: std.mem.Allocator,
            method: []const u8,
            body: []const u8,
            writer: body_sink.Writer,
        ) !void {
            const response = try serverStreaming(ctx, io, allocator, method, body);
            defer allocator.free(response);
            try writer.writeAll(io, allocator, response);
        }

        fn clientStreaming(
            ctx: *anyopaque,
            io: std.Io,
            allocator: std.mem.Allocator,
            method: []const u8,
            body: []const u8,
        ) ![]u8 {
            _ = io;
            _ = allocator;
            _ = method;
            _ = body;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.buffered_handler_called = true;
            return error.BufferedHandlerCalled;
        }

        fn startClientStreaming(
            ctx: *anyopaque,
            io: std.Io,
            allocator: std.mem.Allocator,
            method: []const u8,
        ) !ClientStream {
            _ = io;
            _ = allocator;
            try std.testing.expectEqualStrings(reapi_dispatch.bytestream_write, method);
            return .{
                .ctx = ctx,
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
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.received.appendSlice(allocator, bytes);
        }

        fn finish(
            ctx: *anyopaque,
            io: std.Io,
            allocator: std.mem.Allocator,
        ) ![]u8 {
            _ = io;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.finished = true;
            return try allocator.dupe(u8, "streamed");
        }

        fn deinitStream(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
            _ = ctx;
            _ = io;
            _ = allocator;
        }
    };

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
        .{ .name = ":path", .value = reapi_dispatch.bytestream_write },
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
    try appendFrame(std.testing.allocator, &input, .{
        .length = 3,
        .type = .data,
        .flags = 0,
        .stream_id = 1,
    }, "abc");
    try appendFrame(std.testing.allocator, &input, .{
        .length = 3,
        .type = .data,
        .flags = http2_frame.flag_end_stream,
        .stream_id = 1,
    }, "def");

    var probe = Probe{};
    defer probe.received.deinit(std.testing.allocator);
    var reader = std.Io.Reader.fixed(input.items);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try handleConnectionStreams(
        std.testing.io,
        std.testing.allocator,
        probe.dispatcher(),
        &reader,
        &output.writer,
    );

    try std.testing.expect(!probe.buffered_handler_called);
    try std.testing.expect(probe.finished);
    try std.testing.expectEqualStrings("abcdef", probe.received.items);

    var response_reader = std.Io.Reader.fixed(output.writer.buffered());
    var saw_streamed_response = false;
    while (true) {
        var frame = readFrame(std.testing.allocator, &response_reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        defer frame.deinit(std.testing.allocator);
        if (frame.header.type == .data and frame.header.stream_id == 1) {
            try std.testing.expectEqualStrings("streamed", frame.payload);
            saw_streamed_response = true;
        }
    }
    try std.testing.expect(saw_streamed_response);
}

test "ReAPI dispatcher streams ByteStream writes into CAS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    var server = reapi_dispatch.Server.init(store);
    const dispatcher = Dispatcher.fromReapiServer(&server);

    const digest = cas.Digest.fromBytes("streamed-write");
    var hash: [64]u8 = undefined;
    const resource_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "uploads/u/blobs/{s}/{d}",
        .{ digest.formatHex(&hash), digest.size_bytes },
    );
    defer std.testing.allocator.free(resource_name);

    const first = try encodeGrpcRequest(std.testing.allocator, bytestream.WriteRequest{
        .resource_name = resource_name,
        .write_offset = 0,
        .data = "streamed",
    });
    defer std.testing.allocator.free(first);
    const second = try encodeGrpcRequest(std.testing.allocator, bytestream.WriteRequest{
        .write_offset = 8,
        .data = "-write",
        .finish_write = true,
    });
    defer std.testing.allocator.free(second);

    const stream = try dispatcher.startClientStreaming(
        std.testing.io,
        std.testing.allocator,
        reapi_dispatch.bytestream_write,
    );
    defer stream.deinit(std.testing.io, std.testing.allocator);
    try stream.append(std.testing.io, std.testing.allocator, first[0..7]);
    try stream.append(std.testing.io, std.testing.allocator, first[7..]);
    try stream.append(std.testing.io, std.testing.allocator, second);
    const response = try stream.finish(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(response);

    try std.testing.expect(try store.has(std.testing.io, digest));
}
