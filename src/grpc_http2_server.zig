const std = @import("std");
const build_options = @import("actiond_build_options");
const body_sink = @import("body_sink.zig");
const bytestream = @import("bytestream.zig");
const bytestream_service = @import("bytestream_service.zig");
const cas = @import("cas.zig");
const http2_frame = @import("http2_frame.zig");
const http2_hpack = @import("http2_hpack.zig");
const grpc_record = @import("grpc_record.zig");
const protobuf = @import("protobuf_wire.zig");
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
    handle_server_streaming_response: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, []const u8, body_sink.Writer) anyerror!void,
    start_client_streaming: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8) anyerror!ClientStream,
    handle_cancellable_server_streaming_response: ?*const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, []const u8, body_sink.Writer, ?*const std.atomic.Value(bool)) anyerror!void = null,

    pub fn fromReapiServer(server: *reapi_dispatch.Server) Dispatcher {
        return .{
            .ctx = server,
            .handle_unary = reapiUnary,
            .handle_server_streaming_response = reapiServerStreamingResponse,
            .start_client_streaming = reapiStartClientStreaming,
            .handle_cancellable_server_streaming_response = reapiCancellableServerStreamingResponse,
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

    pub fn handleCancellableServerStreamingResponse(
        self: Dispatcher,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        writer: body_sink.Writer,
        cancellation: ?*const std.atomic.Value(bool),
    ) !void {
        if (self.handle_cancellable_server_streaming_response) |handler| {
            return handler(self.ctx, io, allocator, method, body, writer, cancellation);
        }
        return self.handleServerStreamingResponse(io, allocator, method, body, writer);
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

    fn reapiCancellableServerStreamingResponse(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
        writer: body_sink.Writer,
        cancellation: ?*const std.atomic.Value(bool),
    ) !void {
        const server: *reapi_dispatch.Server = @ptrCast(@alignCast(ctx));
        return server.*.handleServerStreamingResponseWithCancellation(
            io,
            allocator,
            method,
            body,
            writer,
            cancellation,
        );
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
                .stream = bytestream_service.WriteGrpcStream.initWithIndex(
                    server.store,
                    server.cas_presence_index,
                ),
            };
            return .{
                .ctx = stream,
                .append_fn = ByteStreamWriteClientStream.append,
                .finish_fn = ByteStreamWriteClientStream.finish,
                .deinit_fn = ByteStreamWriteClientStream.deinit,
            };
        }
        _ = io;
        return error.UnsupportedMethod;
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
        const response = try self.stream.finish(io, allocator);
        return try encodeGrpcRequest(allocator, response);
    }

    fn deinit(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) void {
        const self: *ByteStreamWriteClientStream = @ptrCast(@alignCast(ctx));
        self.stream.deinit(io, allocator);
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
const default_max_concurrent_streams = 128;
const max_request_header_bytes = 64 * 1024;
const max_request_body_bytes = 128 * 1024 * 1024;
const max_connection_request_bytes = 128 * 1024 * 1024;
const inbound_initial_window_size = 1024 * 1024 * 1024;
const inbound_window_update_batch_size = 1024 * 1024;
const grpc_response_headers = [_]http2_hpack.HeaderView{
    .{ .name = ":status", .value = "200" },
    .{ .name = "content-type", .value = "application/grpc" },
};
const grpc_success_trailers = [_]http2_hpack.HeaderView{
    .{ .name = "grpc-status", .value = "0" },
};
const grpc_response_headers_block = staticHeaderBlock(&grpc_response_headers);
const grpc_success_trailers_block = staticHeaderBlock(&grpc_success_trailers);

fn staticHeaderBlock(comptime headers: []const http2_hpack.HeaderView) [http2_hpack.encodedHeaderBlockLen(headers)]u8 {
    var out: [http2_hpack.encodedHeaderBlockLen(headers)]u8 = undefined;
    _ = http2_hpack.encodeHeaderBlockInto(&out, headers) catch unreachable;
    return out;
}

var grpc_connections_started = std.atomic.Value(u64).init(0);
var grpc_connections_completed = std.atomic.Value(u64).init(0);
var grpc_connections_failed = std.atomic.Value(u64).init(0);
var grpc_response_tasks_started = std.atomic.Value(u64).init(0);
var grpc_response_tasks_completed = std.atomic.Value(u64).init(0);
var grpc_response_tasks_failed = std.atomic.Value(u64).init(0);
var grpc_response_concurrency_waits = std.atomic.Value(u64).init(0);
var grpc_success_fast_paths = std.atomic.Value(u64).init(0);
var grpc_success_fast_bytes = std.atomic.Value(u64).init(0);
var grpc_success_fallbacks = std.atomic.Value(u64).init(0);
var grpc_window_update_flushes = std.atomic.Value(u64).init(0);
var grpc_window_update_connection_bytes = std.atomic.Value(u64).init(0);
var grpc_window_update_stream_bytes = std.atomic.Value(u64).init(0);
var grpc_data_frames = std.atomic.Value(u64).init(0);
var grpc_data_bytes = std.atomic.Value(u64).init(0);
var grpc_file_payload_frames = std.atomic.Value(u64).init(0);
var grpc_file_payload_bytes = std.atomic.Value(u64).init(0);
var grpc_sendfile_attempts = std.atomic.Value(u64).init(0);
var grpc_sendfile_successes = std.atomic.Value(u64).init(0);
var grpc_sendfile_bytes = std.atomic.Value(u64).init(0);
var grpc_sendfile_fallbacks = std.atomic.Value(u64).init(0);
var grpc_sendfile_fallback_bytes = std.atomic.Value(u64).init(0);

fn addStat(counter: *std.atomic.Value(u64), value: usize) void {
    if (comptime build_options.executor_timing_logs) {
        _ = counter.fetchAdd(@intCast(value), .monotonic);
    }
}

pub fn appendStats(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    if (comptime build_options.executor_timing_logs) {
        const text = try std.fmt.allocPrint(allocator,
            \\grpc_connections_started {d}
            \\grpc_connections_completed {d}
            \\grpc_connections_failed {d}
            \\grpc_response_tasks_started {d}
            \\grpc_response_tasks_completed {d}
            \\grpc_response_tasks_failed {d}
            \\grpc_response_concurrency_waits {d}
            \\grpc_success_fast_paths {d}
            \\grpc_success_fast_bytes {d}
            \\grpc_success_fallbacks {d}
            \\grpc_window_update_flushes {d}
            \\grpc_window_update_connection_bytes {d}
            \\grpc_window_update_stream_bytes {d}
            \\grpc_data_frames {d}
            \\grpc_data_bytes {d}
            \\grpc_file_payload_frames {d}
            \\grpc_file_payload_bytes {d}
            \\grpc_sendfile_attempts {d}
            \\grpc_sendfile_successes {d}
            \\grpc_sendfile_bytes {d}
            \\grpc_sendfile_fallbacks {d}
            \\grpc_sendfile_fallback_bytes {d}
            \\
        , .{
            grpc_connections_started.load(.monotonic),
            grpc_connections_completed.load(.monotonic),
            grpc_connections_failed.load(.monotonic),
            grpc_response_tasks_started.load(.monotonic),
            grpc_response_tasks_completed.load(.monotonic),
            grpc_response_tasks_failed.load(.monotonic),
            grpc_response_concurrency_waits.load(.monotonic),
            grpc_success_fast_paths.load(.monotonic),
            grpc_success_fast_bytes.load(.monotonic),
            grpc_success_fallbacks.load(.monotonic),
            grpc_window_update_flushes.load(.monotonic),
            grpc_window_update_connection_bytes.load(.monotonic),
            grpc_window_update_stream_bytes.load(.monotonic),
            grpc_data_frames.load(.monotonic),
            grpc_data_bytes.load(.monotonic),
            grpc_file_payload_frames.load(.monotonic),
            grpc_file_payload_bytes.load(.monotonic),
            grpc_sendfile_attempts.load(.monotonic),
            grpc_sendfile_successes.load(.monotonic),
            grpc_sendfile_bytes.load(.monotonic),
            grpc_sendfile_fallbacks.load(.monotonic),
            grpc_sendfile_fallback_bytes.load(.monotonic),
        });
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
    }
}

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
};

const RequestBudget = struct {
    used: std.atomic.Value(usize) = .init(0),

    fn reserve(self: *RequestBudget, len: usize) !void {
        if (len > max_connection_request_bytes) return error.RequestBodyTooLarge;
        while (true) {
            const current = self.used.load(.monotonic);
            if (current > max_connection_request_bytes - len) return error.RequestBodyTooLarge;
            if (self.used.cmpxchgWeak(current, current + len, .monotonic, .monotonic) == null) return;
        }
    }

    fn release(self: *RequestBudget, len: usize) void {
        _ = self.used.fetchSub(len, .monotonic);
    }
};

const StreamState = struct {
    id: u31,
    request_budget: *RequestBudget,
    buffered_bytes: usize = 0,
    method: ?[]u8 = null,
    header_block: std.ArrayListUnmanaged(u8) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,
    client_stream: ?ClientStream = null,
    inbound_window_update_pending: usize = 0,

    fn init(id: u31, request_budget: *RequestBudget) StreamState {
        return .{ .id = id, .request_budget = request_budget };
    }

    fn appendHeaderBlock(self: *StreamState, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len > max_request_header_bytes or
            self.header_block.items.len > max_request_header_bytes - bytes.len)
        {
            return error.RequestHeadersTooLarge;
        }
        try self.request_budget.reserve(bytes.len);
        errdefer self.request_budget.release(bytes.len);
        try self.header_block.appendSlice(allocator, bytes);
        self.buffered_bytes += bytes.len;
    }

    fn appendBody(self: *StreamState, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len > max_request_body_bytes or
            self.body.items.len > max_request_body_bytes - bytes.len)
        {
            return error.RequestBodyTooLarge;
        }
        try self.request_budget.reserve(bytes.len);
        errdefer self.request_budget.release(bytes.len);
        try self.body.appendSlice(allocator, bytes);
        self.buffered_bytes += bytes.len;
    }

    fn deinit(self: *StreamState, io: std.Io, allocator: std.mem.Allocator) void {
        if (self.client_stream) |client_stream| client_stream.deinit(io, allocator);
        if (self.method) |method| allocator.free(method);
        self.header_block.deinit(allocator);
        self.body.deinit(allocator);
        self.request_budget.release(self.buffered_bytes);
        self.* = undefined;
    }
};

test "HTTP/2 request state bounds headers and connection-wide buffered bodies" {
    const headers = try std.testing.allocator.alloc(u8, max_request_header_bytes + 1);
    defer std.testing.allocator.free(headers);
    @memset(headers, 'a');

    {
        var request_budget = RequestBudget{};
        var state = StreamState.init(1, &request_budget);
        defer state.deinit(std.testing.io, std.testing.allocator);
        try std.testing.expectError(
            error.RequestHeadersTooLarge,
            state.appendHeaderBlock(std.testing.allocator, headers),
        );
        try state.appendHeaderBlock(std.testing.allocator, headers[0 .. max_request_header_bytes / 2]);
        try state.appendHeaderBlock(std.testing.allocator, headers[0 .. max_request_header_bytes / 2]);
        try std.testing.expectError(
            error.RequestHeadersTooLarge,
            state.appendHeaderBlock(std.testing.allocator, headers[0..1]),
        );
    }

    {
        var request_budget = RequestBudget{};
        try request_budget.reserve(max_connection_request_bytes);
        defer request_budget.release(max_connection_request_bytes);

        var state = StreamState.init(1, &request_budget);
        defer state.deinit(std.testing.io, std.testing.allocator);
        try std.testing.expectError(
            error.RequestBodyTooLarge,
            state.appendBody(std.testing.allocator, "x"),
        );
    }
}

test "HTTP/2 refuses more unfinished streams than advertised" {
    var request_budget = RequestBudget{};
    var streams: std.ArrayListUnmanaged(StreamState) = .empty;
    defer {
        for (streams.items) |*state| state.deinit(std.testing.io, std.testing.allocator);
        streams.deinit(std.testing.allocator);
    }

    for (0..default_max_concurrent_streams) |index| {
        _ = try getOrCreateStream(
            std.testing.allocator,
            &streams,
            @intCast(index + 1),
            &request_budget,
        );
    }
    try std.testing.expectError(
        error.TooManyConcurrentStreams,
        getOrCreateStream(
            std.testing.allocator,
            &streams,
            default_max_concurrent_streams + 1,
            &request_budget,
        ),
    );
}

const SharedHttp2Writer = struct {
    mutex: std.Io.Mutex = .init,
    flow: FlowControl = .{},
    writer: *std.Io.Writer,
    inbound_connection_window_update_pending: usize = 0,

    fn deinit(self: *SharedHttp2Writer, allocator: std.mem.Allocator) void {
        self.flow.deinit(allocator);
    }

    fn registerStream(self: *SharedHttp2Writer, allocator: std.mem.Allocator, stream_id: u31) !void {
        try self.flow.registerStream(allocator, stream_id);
    }

    fn unregisterStream(self: *SharedHttp2Writer, stream_id: u31) void {
        self.flow.unregisterStream(stream_id);
    }

    fn shutdownStreams(self: *SharedHttp2Writer) void {
        self.flow.shutdown();
    }

    fn applyPeerSettings(self: *SharedHttp2Writer, payload: []const u8) !void {
        try self.flow.applySettings(payload);
    }

    fn applyWindowUpdate(self: *SharedHttp2Writer, stream_id: u31, increment: u31) void {
        self.flow.applyWindowUpdate(stream_id, increment);
    }

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

    fn sendWindowUpdates(
        self: *SharedHttp2Writer,
        io: std.Io,
        state: *StreamState,
        len: usize,
        end_stream: bool,
    ) !void {
        if (len == 0) return;
        self.inbound_connection_window_update_pending += len;
        state.inbound_window_update_pending += len;

        const connection_len = if (self.inbound_connection_window_update_pending >= inbound_window_update_batch_size)
            self.inbound_connection_window_update_pending
        else
            0;
        const stream_len = if (!end_stream and state.inbound_window_update_pending >= inbound_window_update_batch_size)
            state.inbound_window_update_pending
        else
            0;
        if (connection_len == 0 and stream_len == 0) return;

        if (connection_len != 0) self.inbound_connection_window_update_pending = 0;
        if (stream_len != 0) state.inbound_window_update_pending = 0;

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (connection_len != 0) {
            try sendWindowUpdate(self.writer, 0, connection_len);
            addStat(&grpc_window_update_connection_bytes, connection_len);
        }
        if (stream_len != 0) {
            try sendWindowUpdate(self.writer, state.id, stream_len);
            addStat(&grpc_window_update_stream_bytes, stream_len);
        }
        try self.writer.flush();
        addStat(&grpc_window_update_flushes, 1);
    }

    fn sendGrpcSuccess(self: *SharedHttp2Writer, io: std.Io, stream_id: u31, response_body: []const u8) !void {
        if (self.flow.tryReserveDataExact(stream_id, response_body.len)) {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            try writeStaticHeaders(self.writer, stream_id, false, &grpc_response_headers_block);
            if (response_body.len != 0) {
                try writeFrame(self.writer, .{
                    .length = response_body.len,
                    .type = .data,
                    .flags = 0,
                    .stream_id = stream_id,
                }, response_body);
                addStat(&grpc_data_frames, 1);
                addStat(&grpc_data_bytes, response_body.len);
            }
            try writeStaticHeaders(self.writer, stream_id, true, &grpc_success_trailers_block);
            try self.writer.flush();
            addStat(&grpc_success_fast_paths, 1);
            addStat(&grpc_success_fast_bytes, response_body.len);
            return;
        }

        addStat(&grpc_success_fallbacks, 1);
        try self.sendGrpcResponseHeaders(io, stream_id);
        try self.sendData(io, stream_id, response_body);
        try self.sendGrpcSuccessTrailers(io, stream_id);
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

    fn sendGrpcResponseHeaders(self: *SharedHttp2Writer, io: std.Io, stream_id: u31) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try writeStaticHeaders(self.writer, stream_id, false, &grpc_response_headers_block);
        try self.writer.flush();
    }

    fn sendGrpcSuccessTrailers(self: *SharedHttp2Writer, io: std.Io, stream_id: u31) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try writeStaticHeaders(self.writer, stream_id, true, &grpc_success_trailers_block);
        try self.writer.flush();
    }

    fn sendData(self: *SharedHttp2Writer, io: std.Io, stream_id: u31, body: []const u8) !void {
        var remaining = body;
        while (remaining.len != 0) {
            const chunk_len = try self.flow.reserveData(io, stream_id, remaining.len);
            const chunk = remaining[0..chunk_len];
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            try writeFrame(self.writer, .{
                .length = chunk.len,
                .type = .data,
                .flags = 0,
                .stream_id = stream_id,
            }, chunk);
            try self.writer.flush();
            addStat(&grpc_data_frames, 1);
            addStat(&grpc_data_bytes, chunk.len);
            remaining = remaining[chunk_len..];
        }
    }

    fn sendDataWithFile(
        self: *SharedHttp2Writer,
        io: std.Io,
        stream_id: u31,
        prefix: []const u8,
        file_handle: std.Io.File.Handle,
        file_offset: u64,
        file_len: usize,
    ) !void {
        var file: std.Io.File = .{
            .handle = file_handle,
            .flags = .{ .nonblocking = false },
        };
        var file_buffer: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &file_buffer);
        try file_reader.seekTo(file_offset);

        var prefix_remaining = prefix;
        var file_remaining = file_len;
        while (prefix_remaining.len != 0 or file_remaining != 0) {
            const requested = prefix_remaining.len + file_remaining;
            const frame_payload_len = try self.flow.reserveData(io, stream_id, requested);
            const prefix_len = @min(prefix_remaining.len, frame_payload_len);
            const file_chunk_len = frame_payload_len - prefix_len;

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            try writeFrameHeader(self.writer, .{
                .length = frame_payload_len,
                .type = .data,
                .flags = 0,
                .stream_id = stream_id,
            });
            if (prefix_len != 0) {
                try self.writer.writeAll(prefix_remaining[0..prefix_len]);
            }
            try self.writer.flush();

            if (file_chunk_len != 0) {
                try self.writeFilePayload(io, &file_reader, file_chunk_len);
            }
            try self.writer.flush();

            addStat(&grpc_data_frames, 1);
            addStat(&grpc_data_bytes, frame_payload_len);
            if (file_chunk_len != 0) {
                addStat(&grpc_file_payload_frames, 1);
                addStat(&grpc_file_payload_bytes, file_chunk_len);
            }
            prefix_remaining = prefix_remaining[prefix_len..];
            file_remaining -= file_chunk_len;
        }
    }

    fn writeFilePayload(
        self: *SharedHttp2Writer,
        io: std.Io,
        file_reader: *std.Io.File.Reader,
        len: usize,
    ) !void {
        _ = io;
        var remaining = len;
        while (remaining != 0) {
            addStat(&grpc_sendfile_attempts, 1);
            const sent = self.writer.sendFile(file_reader, .limited(remaining)) catch |err| switch (err) {
                error.EndOfStream => return error.UnexpectedEof,
                error.Unimplemented => 0,
                else => |e| return e,
            };
            if (sent != 0) {
                remaining -= sent;
                addStat(&grpc_sendfile_successes, 1);
                addStat(&grpc_sendfile_bytes, sent);
                continue;
            }

            file_reader.mode = file_reader.mode.toSimple();
            addStat(&grpc_sendfile_fallbacks, 1);
            addStat(&grpc_sendfile_fallback_bytes, remaining);
            const copied = try self.writer.sendFileReadingAll(file_reader, .limited(remaining));
            if (copied != remaining) return error.UnexpectedEof;
            remaining = 0;
        }
    }
};

const FlowControl = struct {
    const Stream = struct {
        id: u31,
        window: i64,
    };

    lock_state: SpinLock = .{},
    connection_window: i64 = http2_frame.default_initial_window_size,
    initial_stream_window: i64 = http2_frame.default_initial_window_size,
    max_frame_size: usize = http2_frame.default_max_frame_size,
    streams: std.ArrayListUnmanaged(Stream) = .empty,
    closed: bool = false,

    fn deinit(self: *FlowControl, allocator: std.mem.Allocator) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();
        self.streams.deinit(allocator);
    }

    fn registerStream(self: *FlowControl, allocator: std.mem.Allocator, stream_id: u31) !void {
        self.lock_state.lock();
        defer self.lock_state.unlock();

        if (self.closed) return error.StreamClosed;
        if (self.findStreamIndexLocked(stream_id) != null) return;
        try self.streams.append(allocator, .{
            .id = stream_id,
            .window = self.initial_stream_window,
        });
    }

    fn unregisterStream(self: *FlowControl, stream_id: u31) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();

        if (self.findStreamIndexLocked(stream_id)) |index| {
            _ = self.streams.orderedRemove(index);
        }
    }

    fn shutdown(self: *FlowControl) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();
        self.closed = true;
    }

    fn applySettings(self: *FlowControl, payload: []const u8) !void {
        var iterator = try http2_frame.SettingsIterator.init(payload);
        self.lock_state.lock();
        defer self.lock_state.unlock();

        while (iterator.next()) |setting| {
            switch (setting.id) {
                .initial_window_size => {
                    const old = self.initial_stream_window;
                    const new: i64 = @intCast(setting.value);
                    const delta = new - old;
                    self.initial_stream_window = new;
                    for (self.streams.items) |*stream| stream.window += delta;
                },
                .max_frame_size => {
                    if (setting.value >= http2_frame.default_max_frame_size and
                        setting.value <= http2_frame.max_frame_size_limit)
                    {
                        self.max_frame_size = @intCast(setting.value);
                    }
                },
                else => {},
            }
        }
    }

    fn applyWindowUpdate(self: *FlowControl, stream_id: u31, increment: u31) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();

        if (stream_id == 0) {
            self.connection_window += @as(i64, @intCast(increment));
            return;
        }
        if (self.findStreamIndexLocked(stream_id)) |index| {
            self.streams.items[index].window += @as(i64, @intCast(increment));
        }
    }

    fn reserveData(self: *FlowControl, io: std.Io, stream_id: u31, requested: usize) !usize {
        while (true) {
            self.lock_state.lock();
            if (self.findStreamIndexLocked(stream_id)) |index| {
                const stream_window = self.streams.items[index].window;
                const available = @min(self.connection_window, stream_window);
                if (available > 0) {
                    const chunk_len_i64 = @min(
                        @as(i64, @intCast(@min(requested, self.max_frame_size))),
                        available,
                    );
                    self.connection_window -= chunk_len_i64;
                    self.streams.items[index].window -= chunk_len_i64;
                    self.lock_state.unlock();
                    return @intCast(chunk_len_i64);
                }
                if (self.closed) {
                    self.lock_state.unlock();
                    return error.StreamClosed;
                }
                self.lock_state.unlock();
                try sleepMilliseconds(io, 1);
                continue;
            }
            self.lock_state.unlock();
            return error.StreamClosed;
        }
    }

    fn tryReserveDataExact(self: *FlowControl, stream_id: u31, requested: usize) bool {
        self.lock_state.lock();
        defer self.lock_state.unlock();

        if (requested > self.max_frame_size) return false;
        if (self.findStreamIndexLocked(stream_id)) |index| {
            const requested_i64: i64 = @intCast(requested);
            if (self.connection_window < requested_i64 or self.streams.items[index].window < requested_i64) {
                return false;
            }
            self.connection_window -= requested_i64;
            self.streams.items[index].window -= requested_i64;
            return true;
        }
        return false;
    }

    fn findStreamIndexLocked(self: *FlowControl, stream_id: u31) ?usize {
        for (self.streams.items, 0..) |stream, index| {
            if (stream.id == stream_id) return index;
        }
        return null;
    }
};

test "FlowControl shutdown releases response writers blocked on zero credit" {
    var flow = FlowControl{};
    defer flow.deinit(std.testing.allocator);
    try flow.registerStream(std.testing.allocator, 1);
    flow.connection_window = 0;
    flow.shutdown();

    try std.testing.expectError(error.StreamClosed, flow.reserveData(std.testing.io, 1, 1));
    try std.testing.expectError(error.StreamClosed, flow.registerStream(std.testing.allocator, 3));
}

const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

const ResponseTracker = struct {
    const ActiveResponse = struct {
        stream_id: u31,
        cancellation: std.atomic.Value(bool) = .init(false),
        next: ?*ActiveResponse = null,
    };

    active: std.atomic.Value(u32) = .init(0),
    lock: SpinLock = .{},
    first: ?*ActiveResponse = null,

    fn begin(
        self: *ResponseTracker,
        io: std.Io,
        allocator: std.mem.Allocator,
        stream_id: u31,
    ) !*ActiveResponse {
        _ = io;
        while (true) {
            const current = self.active.load(.monotonic);
            if (current >= default_max_concurrent_streams) {
                addStat(&grpc_response_concurrency_waits, 1);
                return error.TooManyConcurrentStreams;
            }
            if (self.active.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) == null) break;
        }

        errdefer _ = self.active.fetchSub(1, .monotonic);
        const response = try allocator.create(ActiveResponse);
        response.* = .{ .stream_id = stream_id };

        self.lock.lock();
        defer self.lock.unlock();
        response.next = self.first;
        self.first = response;
        return response;
    }

    fn finish(self: *ResponseTracker, allocator: std.mem.Allocator, response: *ActiveResponse) void {
        self.lock.lock();
        var previous: ?*ActiveResponse = null;
        var current = self.first;
        while (current) |entry| {
            if (entry == response) {
                if (previous) |parent| {
                    parent.next = entry.next;
                } else {
                    self.first = entry.next;
                }
                break;
            }
            previous = entry;
            current = entry.next;
        }
        self.lock.unlock();
        allocator.destroy(response);
        _ = self.active.fetchSub(1, .monotonic);
    }

    fn cancel(self: *ResponseTracker, stream_id: u31) void {
        self.lock.lock();
        defer self.lock.unlock();
        var current = self.first;
        while (current) |entry| : (current = entry.next) {
            if (entry.stream_id == stream_id) {
                entry.cancellation.store(true, .release);
                return;
            }
        }
    }

    fn cancelAll(self: *ResponseTracker) void {
        self.lock.lock();
        defer self.lock.unlock();
        var current = self.first;
        while (current) |entry| : (current = entry.next) {
            entry.cancellation.store(true, .release);
        }
    }

    fn wait(self: *ResponseTracker, io: std.Io) !void {
        while (self.active.load(.monotonic) != 0) {
            try sleepMilliseconds(io, 1);
        }
    }
};

test "ResponseTracker cancels only the requested HTTP/2 stream" {
    var tracker = ResponseTracker{};
    const first = try tracker.begin(std.testing.io, std.testing.allocator, 1);
    defer tracker.finish(std.testing.allocator, first);
    const second = try tracker.begin(std.testing.io, std.testing.allocator, 3);
    defer tracker.finish(std.testing.allocator, second);

    tracker.cancel(1);
    try std.testing.expect(first.cancellation.load(.acquire));
    try std.testing.expect(!second.cancellation.load(.acquire));

    tracker.cancelAll();
    try std.testing.expect(second.cancellation.load(.acquire));
}

test "ResponseTracker refuses saturated HTTP/2 streams without blocking the frame reader" {
    var tracker = ResponseTracker{};
    var responses: [default_max_concurrent_streams]*ResponseTracker.ActiveResponse = undefined;
    var started: usize = 0;
    defer for (responses[0..started]) |response| tracker.finish(std.testing.allocator, response);

    for (&responses, 0..) |*response, index| {
        response.* = try tracker.begin(std.testing.io, std.testing.allocator, @intCast(index + 1));
        started += 1;
    }
    try std.testing.expectError(
        error.TooManyConcurrentStreams,
        tracker.begin(std.testing.io, std.testing.allocator, default_max_concurrent_streams + 1),
    );
    try std.testing.expectEqual(@as(u32, default_max_concurrent_streams), tracker.active.load(.monotonic));
}

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
    ignoreSigpipe();

    const address = try std.Io.net.IpAddress.parseLiteral(config.listen);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("actiond gRPC listening on {s}\n", .{config.listen});
    try stderr.flush();

    var connections: std.Io.Group = .init;
    defer connections.cancel(io);

    while (true) {
        const stream = listener.accept(io) catch |err| {
            if (err == error.Canceled) return err;
            try stderr.print("actiond gRPC accept failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            sleepMilliseconds(io, 10) catch {};
            continue;
        };
        setTcpNoDelay(stream) catch {};
        connections.concurrent(io, connectionTask, .{
            io,
            allocator,
            dispatcher,
            stream,
        }) catch |err| {
            var owned_stream = stream;
            owned_stream.close(io);
            try stderr.print("actiond gRPC connection task failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            sleepMilliseconds(io, 10) catch {};
            continue;
        };
    }
}

fn connectionTask(
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

pub fn handleConnectionFd(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    fd: std.posix.fd_t,
) !void {
    var file = std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    defer file.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var file_writer = file.writer(io, &write_buffer);
    try handleConnectionStreamsTracked(
        io,
        allocator,
        dispatcher,
        &file_reader.interface,
        &file_writer.interface,
    );
}

pub fn handleConnectionStreams(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    try handleConnectionStreamsTracked(
        io,
        allocator,
        dispatcher,
        reader,
        writer,
    );
}

fn handleConnectionStreamsTracked(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    addStat(&grpc_connections_started, 1);
    errdefer addStat(&grpc_connections_failed, 1);
    defer addStat(&grpc_connections_completed, 1);

    var preface: [http2_frame.client_connection_preface.len]u8 = undefined;
    try reader.readSliceAll(&preface);
    if (!std.mem.eql(u8, preface[0..], http2_frame.client_connection_preface)) {
        return error.InvalidClientPreface;
    }

    var shared_writer = SharedHttp2Writer{ .writer = writer };
    defer shared_writer.deinit(allocator);
    var responses = ResponseTracker{};
    var response_tasks: std.Io.Group = .init;
    defer {
        responses.cancelAll();
        shared_writer.shutdownStreams();
        response_tasks.cancel(io);
    }

    try shared_writer.sendServerSettings(io);

    var hpack_decoder = http2_hpack.Decoder.init(allocator);
    defer hpack_decoder.deinit();
    var frame_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer frame_payload.deinit(allocator);

    var request_budget = RequestBudget{};
    var streams: std.ArrayListUnmanaged(StreamState) = .empty;
    defer {
        for (streams.items) |*stream| stream.deinit(io, allocator);
        streams.deinit(allocator);
    }

    var continuation_stream: ?u31 = null;
    while (true) {
        const incoming = readFrame(allocator, reader, &frame_payload) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        if (continuation_stream != null and incoming.header.type != .continuation) {
            return error.UnexpectedContinuation;
        }

        switch (incoming.header.type) {
            .settings => {
                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_ack)) continue;
                try shared_writer.applyPeerSettings(incoming.payload);
                try shared_writer.ackSettings(io);
            },
            .ping => {
                if (!http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_ack)) {
                    try shared_writer.ackPing(io, incoming.payload);
                }
            },
            .window_update => {
                const increment = try http2_frame.decodeWindowUpdate(incoming.payload);
                shared_writer.applyWindowUpdate(incoming.header.stream_id, increment);
            },
            .headers => {
                const state = try getOrCreateStream(
                    allocator,
                    &streams,
                    incoming.header.stream_id,
                    &request_budget,
                );
                try shared_writer.registerStream(allocator, incoming.header.stream_id);
                const fragment = try headersFragment(incoming.header.flags, incoming.payload);
                try state.appendHeaderBlock(allocator, fragment);

                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_end_headers)) {
                    try finishHeaders(allocator, &hpack_decoder, state);
                    continuation_stream = null;
                } else {
                    continuation_stream = incoming.header.stream_id;
                }

                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_end_stream)) {
                    try respondAndRemove(io, allocator, dispatcher, &shared_writer, &responses, &response_tasks, &streams, incoming.header.stream_id);
                }
            },
            .continuation => {
                if (continuation_stream != incoming.header.stream_id) return error.UnexpectedContinuation;
                const state = try getOrCreateStream(
                    allocator,
                    &streams,
                    incoming.header.stream_id,
                    &request_budget,
                );
                try shared_writer.registerStream(allocator, incoming.header.stream_id);
                try state.appendHeaderBlock(allocator, incoming.payload);
                if (http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_end_headers)) {
                    try finishHeaders(allocator, &hpack_decoder, state);
                    continuation_stream = null;
                }
            },
            .data => {
                const state = try getOrCreateStream(
                    allocator,
                    &streams,
                    incoming.header.stream_id,
                    &request_budget,
                );
                try shared_writer.registerStream(allocator, incoming.header.stream_id);
                const data = try dataPayload(incoming.header.flags, incoming.payload);
                if (isClientStreaming(state)) {
                    try ensureClientStream(io, allocator, dispatcher, state);
                    try state.client_stream.?.append(io, allocator, data);
                } else {
                    try state.appendBody(allocator, data);
                }
                const end_stream = http2_frame.hasFlag(incoming.header.flags, http2_frame.flag_end_stream);
                try shared_writer.sendWindowUpdates(io, state, data.len, end_stream);
                if (end_stream) {
                    try respondAndRemove(io, allocator, dispatcher, &shared_writer, &responses, &response_tasks, &streams, incoming.header.stream_id);
                }
            },
            .rst_stream => {
                responses.cancel(incoming.header.stream_id);
                shared_writer.unregisterStream(incoming.header.stream_id);
                removeStream(io, allocator, &streams, incoming.header.stream_id);
            },
            .goaway => break,
            .priority, .push_promise => {},
        }
    }
    responses.cancelAll();
    shared_writer.shutdownStreams();
    try response_tasks.await(io);
    try responses.wait(io);
}

fn writeServerSettings(writer: *std.Io.Writer) !void {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(std.heap.smp_allocator);
    try http2_frame.appendSettingsPayload(std.heap.smp_allocator, &payload, &.{
        .{ .id = .enable_push, .value = 0 },
        .{ .id = .max_concurrent_streams, .value = default_max_concurrent_streams },
        .{ .id = .initial_window_size, .value = inbound_initial_window_size },
        .{ .id = .max_frame_size, .value = 1024 * 1024 },
    });
    try writeFrame(writer, .{
        .length = payload.items.len,
        .type = .settings,
        .flags = 0,
        .stream_id = 0,
    }, payload.items);
    try sendWindowUpdate(
        writer,
        0,
        inbound_initial_window_size - @as(usize, @intCast(http2_frame.default_initial_window_size)),
    );
    try writer.flush();
}

fn readFrame(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    payload_buffer: *std.ArrayListUnmanaged(u8),
) !IncomingFrame {
    var header_bytes: [http2_frame.header_len]u8 = undefined;
    try reader.readSliceAll(&header_bytes);
    const header = http2_frame.decodeHeader(&header_bytes);
    if (header.length > max_frame_payload_len) return error.FrameTooLarge;

    try payload_buffer.ensureTotalCapacity(allocator, header.length);
    payload_buffer.items.len = header.length;
    try reader.readSliceAll(payload_buffer.items);

    return .{
        .header = header,
        .payload = payload_buffer.items,
    };
}

fn writeFrame(
    writer: *std.Io.Writer,
    header: http2_frame.Header,
    payload: []const u8,
) !void {
    var encoded_header = header;
    encoded_header.length = payload.len;
    try writeFrameHeader(writer, encoded_header);
    try writer.writeAll(payload);
}

fn writeFrameHeader(writer: *std.Io.Writer, header: http2_frame.Header) !void {
    var header_bytes: [http2_frame.header_len]u8 = undefined;
    try http2_frame.encodeHeader(&header_bytes, header);
    try writer.writeAll(&header_bytes);
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
    request_budget: *RequestBudget,
) !*StreamState {
    for (streams.items) |*stream| {
        if (stream.id == id) return stream;
    }
    if (streams.items.len >= default_max_concurrent_streams) return error.TooManyConcurrentStreams;
    try streams.append(allocator, StreamState.init(id, request_budget));
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
    response_tasks: *std.Io.Group,
    streams: *std.ArrayListUnmanaged(StreamState),
    id: u31,
) !void {
    for (streams.items, 0..) |*state, i| {
        if (state.id != id) continue;
        var owned_state = streams.orderedRemove(i);
        errdefer owned_state.deinit(io, allocator);
        errdefer writer.unregisterStream(id);

        const active_response = responses.begin(io, allocator, id) catch |err| switch (err) {
            error.TooManyConcurrentStreams => {
                try writer.sendGrpcError(io, id, "8", "TooManyConcurrentStreams");
                writer.unregisterStream(id);
                owned_state.deinit(io, allocator);
                return;
            },
            else => return err,
        };
        errdefer responses.finish(allocator, active_response);

        const task = ResponseTask{
            .io = io,
            .allocator = allocator,
            .dispatcher = dispatcher,
            .writer = writer,
            .responses = responses,
            .active_response = active_response,
            .state = owned_state,
        };

        try response_tasks.concurrent(io, ResponseTask.run, .{task});
        addStat(&grpc_response_tasks_started, 1);
        return;
    }
}

const ResponseTask = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    writer: *SharedHttp2Writer,
    responses: *ResponseTracker,
    active_response: *ResponseTracker.ActiveResponse,
    state: StreamState,

    fn run(task: ResponseTask) void {
        var self = task;
        const io = self.io;
        const allocator = self.allocator;
        const responses = self.responses;
        defer responses.finish(allocator, self.active_response);
        defer self.state.deinit(io, allocator);
        defer self.writer.unregisterStream(self.state.id);
        defer addStat(&grpc_response_tasks_completed, 1);

        respondStream(
            io,
            allocator,
            self.dispatcher,
            self.writer,
            &self.state,
            &self.active_response.cancellation,
        ) catch |err| {
            addStat(&grpc_response_tasks_failed, 1);
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
    cancellation: ?*const std.atomic.Value(bool),
) !void {
    const method = state.method orelse return writer.sendGrpcError(io, state.id, "13", "MissingPathHeader");
    const kind = methodKind(method) orelse return writer.sendGrpcError(io, state.id, "12", "UnsupportedMethod");
    if (kind == .server_streaming) {
        return respondServerStreaming(io, allocator, dispatcher, writer, state, method, cancellation);
    }

    const response_body = dispatchGrpc(io, allocator, dispatcher, state, method) catch |err| {
        const status = grpcStatusForError(err);
        if (shouldLogGrpcError(err, status)) std.log.err("gRPC {s} failed: {s}", .{ method, @errorName(err) });
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
            .write_file_with_prefix = writeFileWithPrefix,
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

    fn writeFileWithPrefix(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        file_handle: std.Io.File.Handle,
        offset: u64,
        len: usize,
    ) !void {
        _ = allocator;
        const self: *Http2BodyWriter = @ptrCast(@alignCast(ctx));
        try self.writer.sendDataWithFile(io, self.stream_id, prefix, file_handle, offset, len);
    }
};

fn respondServerStreaming(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    writer: *SharedHttp2Writer,
    state: *StreamState,
    method: []const u8,
    cancellation: ?*const std.atomic.Value(bool),
) !void {
    try writer.sendGrpcResponseHeaders(io, state.id);

    var body_writer = Http2BodyWriter{
        .writer = writer,
        .stream_id = state.id,
    };
    dispatcher.handleCancellableServerStreamingResponse(
        io,
        allocator,
        method,
        state.body.items,
        body_writer.bodyWriter(),
        cancellation,
    ) catch |err| {
        const status = grpcStatusForError(err);
        if (shouldLogGrpcError(err, status)) std.log.err("gRPC {s} failed: {s}", .{ method, @errorName(err) });
        try writer.sendHeaders(io, state.id, true, &.{
            .{ .name = "grpc-status", .value = status },
            .{ .name = "grpc-message", .value = @errorName(err) },
        });
        return;
    };

    try writer.sendGrpcSuccessTrailers(io, state.id);
}

fn shouldLogGrpcError(err: anyerror, status: []const u8) bool {
    if (std.mem.eql(u8, status, "5")) return false;
    return switch (err) {
        error.ExecutionCancelled, error.ExecutionDeadlineExceeded => false,
        else => true,
    };
}

fn grpcStatusForError(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyExecPath,
        error.EscapingExecPath,
        error.InvalidDigestHash,
        error.InvalidDigestSize,
        error.InvalidDirectoryEntryName,
        error.InvalidCgroupLimit,
        error.InvalidEnumValue,
        error.InvalidFieldNumber,
        error.InvalidLength,
        error.InvalidActionTimeout,
        error.InvalidOutputSymlinkPath,
        error.InvalidSymlinkName,
        error.InvalidSymlinkTarget,
        error.InvalidVarint,
        error.MissingInputDirectoryDigest,
        error.NonCanonicalDirectory,
        error.OutputParentConflictsWithInputFile,
        error.OutputParentConflictsWithInputSymlink,
        error.UnexpectedWireType,
        => "3",
        error.ExecutionCancelled => "1",
        error.ExecutionDeadlineExceeded => "4",
        error.FileNotFound => "5",
        error.ActionResultTooLarge,
        error.FileTooBig,
        error.OutputAggregateTooLarge,
        error.OutputDirectoryTooLarge,
        error.OutputMetadataTooLarge,
        error.OutputPathTooLong,
        error.OutputTreeTooDeep,
        error.OutputTreeTooLarge,
        error.RequestBodyTooLarge,
        error.RequestHeadersTooLarge,
        error.TooManyConcurrentStreams,
        error.TooManyOutputEntries,
        => "8",
        error.FailedPrecondition => "9",
        error.UnsupportedMethod => "12",
        else => "13",
    };
}

test "gRPC status maps invalid REAPI symlinks, directories, and execution paths" {
    const invalid_arguments = [_]anyerror{
        error.EmptyExecPath,
        error.EscapingExecPath,
        error.InvalidDigestHash,
        error.InvalidDigestSize,
        error.InvalidDirectoryEntryName,
        error.InvalidCgroupLimit,
        error.InvalidEnumValue,
        error.InvalidFieldNumber,
        error.InvalidLength,
        error.InvalidActionTimeout,
        error.InvalidOutputSymlinkPath,
        error.InvalidSymlinkName,
        error.InvalidSymlinkTarget,
        error.InvalidVarint,
        error.MissingInputDirectoryDigest,
        error.NonCanonicalDirectory,
        error.OutputParentConflictsWithInputFile,
        error.OutputParentConflictsWithInputSymlink,
        error.UnexpectedWireType,
    };
    for (invalid_arguments) |invalid_argument| {
        try std.testing.expectEqualStrings("3", grpcStatusForError(invalid_argument));
    }
}

test "gRPC status maps failed preconditions and preserves existing error mappings" {
    try std.testing.expectEqualStrings("1", grpcStatusForError(error.ExecutionCancelled));
    try std.testing.expectEqualStrings("4", grpcStatusForError(error.ExecutionDeadlineExceeded));
    try std.testing.expectEqualStrings("9", grpcStatusForError(error.FailedPrecondition));
    try std.testing.expectEqualStrings("5", grpcStatusForError(error.FileNotFound));
    try std.testing.expectEqualStrings("12", grpcStatusForError(error.UnsupportedMethod));
    try std.testing.expectEqualStrings("13", grpcStatusForError(error.OutOfMemory));
}

test "gRPC cancellation and deadline completion do not log server failures" {
    try std.testing.expect(!shouldLogGrpcError(error.ExecutionCancelled, "1"));
    try std.testing.expect(!shouldLogGrpcError(error.ExecutionDeadlineExceeded, "4"));
    try std.testing.expect(!shouldLogGrpcError(error.FileNotFound, "5"));
    try std.testing.expect(shouldLogGrpcError(error.OutOfMemory, "13"));
}

test "gRPC status maps bounded action outputs to RESOURCE_EXHAUSTED" {
    const exhausted = [_]anyerror{
        error.ActionResultTooLarge,
        error.FileTooBig,
        error.OutputAggregateTooLarge,
        error.OutputDirectoryTooLarge,
        error.OutputMetadataTooLarge,
        error.OutputPathTooLong,
        error.OutputTreeTooDeep,
        error.OutputTreeTooLarge,
        error.RequestBodyTooLarge,
        error.RequestHeadersTooLarge,
        error.TooManyConcurrentStreams,
        error.TooManyOutputEntries,
    };
    for (exhausted) |err| {
        try std.testing.expectEqualStrings("8", grpcStatusForError(err));
    }
}

fn sleepMilliseconds(io: std.Io, milliseconds: u32) !void {
    try io.sleep(.fromMilliseconds(milliseconds), .awake);
}

pub fn ignoreSigpipe() void {
    if (comptime std.posix.Sigaction == void) return;

    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

fn setTcpNoDelay(stream: std.Io.net.Stream) !void {
    var enabled: i32 = 1;
    try std.posix.setsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&enabled),
    );
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
        .server_streaming => unreachable,
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
    const encoded_len = http2_hpack.encodedHeaderBlockLen(headers);
    var stack_buffer: [512]u8 = undefined;
    var heap_allocated = false;
    const encoded = if (encoded_len <= stack_buffer.len)
        try http2_hpack.encodeHeaderBlockInto(stack_buffer[0..encoded_len], headers)
    else encoded: {
        const heap_encoded = try http2_hpack.encodeHeaderBlockAlloc(std.heap.smp_allocator, headers);
        heap_allocated = true;
        break :encoded heap_encoded;
    };
    defer if (heap_allocated) std.heap.smp_allocator.free(encoded);

    const flags = http2_frame.flag_end_headers |
        if (end_stream) http2_frame.flag_end_stream else @as(u8, 0);
    try writeFrame(writer, .{
        .length = encoded.len,
        .type = .headers,
        .flags = flags,
        .stream_id = stream_id,
    }, encoded);
}

fn writeStaticHeaders(
    writer: *std.Io.Writer,
    stream_id: u31,
    end_stream: bool,
    encoded: []const u8,
) !void {
    const flags = http2_frame.flag_end_headers |
        if (end_stream) http2_frame.flag_end_stream else @as(u8, 0);
    try writeFrame(writer, .{
        .length = encoded.len,
        .type = .headers,
        .flags = flags,
        .stream_id = stream_id,
    }, encoded);
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
    var frame_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer frame_payload.deinit(std.testing.allocator);

    while (true) {
        const frame = readFrame(std.testing.allocator, &response_reader, &frame_payload) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
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
                .handle_server_streaming_response = serverStreamingResponse,
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
                    try io.sleep(.fromMilliseconds(1), .awake);
                }
                if (self.second_started.load(.monotonic) != 0) {
                    self.first_observed_second.store(1, .monotonic);
                }
                return try allocator.dupe(u8, "first");
            }
            if (std.mem.eql(u8, method, reapi_dispatch.cas_find_missing_blobs)) {
                self.second_started.store(1, .monotonic);
                return try allocator.dupe(u8, "second");
            }
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
    var frame_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer frame_payload.deinit(std.testing.allocator);
    while (true) {
        const frame = readFrame(std.testing.allocator, &response_reader, &frame_payload) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
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

test "HTTP/2 RST_STREAM cancels an active server-streaming request" {
    const Probe = struct {
        saw_cancellation: std.atomic.Value(bool) = .init(false),

        fn dispatcher(self: *@This()) Dispatcher {
            return .{
                .ctx = self,
                .handle_unary = unary,
                .handle_server_streaming_response = serverStreamingResponse,
                .start_client_streaming = startClientStreaming,
                .handle_cancellable_server_streaming_response = cancellableServerStreamingResponse,
            };
        }

        fn unary(
            _: *anyopaque,
            _: std.Io,
            _: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
        ) ![]u8 {
            return error.UnsupportedMethod;
        }

        fn serverStreamingResponse(
            _: *anyopaque,
            _: std.Io,
            _: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            _: body_sink.Writer,
        ) !void {
            return error.MissingCancellationToken;
        }

        fn cancellableServerStreamingResponse(
            ctx: *anyopaque,
            io: std.Io,
            _: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            _: body_sink.Writer,
            cancellation: ?*const std.atomic.Value(bool),
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const token = cancellation orelse return error.MissingCancellationToken;
            var attempts: usize = 0;
            while (!token.load(.acquire)) : (attempts += 1) {
                if (attempts >= 1_000) return error.CancellationNotObserved;
                try io.sleep(.fromMilliseconds(1), .awake);
            }
            self.saw_cancellation.store(true, .release);
            return error.ExecutionCancelled;
        }

        fn startClientStreaming(
            _: *anyopaque,
            _: std.Io,
            _: std.mem.Allocator,
            _: []const u8,
        ) !ClientStream {
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

    const request = try encodeGrpcRequest(std.testing.allocator, reapi.ExecuteRequest{});
    defer std.testing.allocator.free(request);
    try appendGrpcRequestFrames(std.testing.allocator, &input, 1, reapi_dispatch.execution_execute, request);
    const cancel_payload = [_]u8{ 0, 0, 0, 8 };
    try appendFrame(std.testing.allocator, &input, .{
        .length = cancel_payload.len,
        .type = .rst_stream,
        .flags = 0,
        .stream_id = 1,
    }, &cancel_payload);

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
    try std.testing.expect(probe.saw_cancellation.load(.acquire));
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
                .handle_server_streaming_response = serverStreamingResponse,
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
    var frame_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer frame_payload.deinit(std.testing.allocator);
    while (true) {
        const frame = readFrame(std.testing.allocator, &response_reader, &frame_payload) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
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

test "HTTP/2 ByteStream read streams file payload after gRPC framing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    var server = reapi_dispatch.Server.init(store);
    const dispatcher = Dispatcher.fromReapiServer(&server);

    const digest = try store.putBytes(std.testing.io, "abcdef");
    var hash: [64]u8 = undefined;
    const resource_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "blobs/{s}/{d}",
        .{ digest.formatHex(&hash), digest.size_bytes },
    );
    defer std.testing.allocator.free(resource_name);

    const request = try encodeGrpcRequest(std.testing.allocator, bytestream.ReadRequest{
        .resource_name = resource_name,
        .read_offset = 1,
        .read_limit = 4,
    });
    defer std.testing.allocator.free(request);

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, http2_frame.client_connection_preface);
    try appendFrame(std.testing.allocator, &input, .{
        .length = 0,
        .type = .settings,
        .flags = 0,
        .stream_id = 0,
    }, "");
    try appendGrpcRequestFrames(std.testing.allocator, &input, 1, reapi_dispatch.bytestream_read, request);

    var reader = std.Io.Reader.fixed(input.items);
    var output: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer output.deinit();

    try handleConnectionStreams(
        std.testing.io,
        std.heap.smp_allocator,
        dispatcher,
        &reader,
        &output.writer,
    );

    var response_reader = std.Io.Reader.fixed(output.writer.buffered());
    var response_records: std.ArrayListUnmanaged(u8) = .empty;
    defer response_records.deinit(std.testing.allocator);
    var saw_success_trailer = false;
    var frame_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer frame_payload.deinit(std.testing.allocator);
    var decoder = http2_hpack.Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    while (true) {
        const frame = readFrame(std.testing.allocator, &response_reader, &frame_payload) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (frame.header.type == .data and frame.header.stream_id == 1) {
            try response_records.appendSlice(std.testing.allocator, frame.payload);
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

    var it = grpc_record.Iterator.init(response_records.items);
    const message = (try it.next()).?;
    var proto_reader = protobuf.Reader.init(message.payload);
    const response = try bytestream.ReadResponse.decode(&proto_reader);
    try std.testing.expectEqualStrings("bcde", response.data);
    try std.testing.expectEqual(@as(?grpc_record.Message, null), try it.next());
    try std.testing.expect(saw_success_trailer);
}
