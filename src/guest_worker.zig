const builtin = @import("builtin");
const std = @import("std");
const action_cache = @import("action_cache.zig");
const body_sink = @import("body_sink.zig");
const bytestream_service = @import("bytestream_service.zig");
const cas = @import("cas.zig");
const control_protocol = @import("control_protocol.zig");
const grpc_record = @import("grpc_record.zig");
const reapi = @import("reapi.zig");
const reapi_dispatch = @import("reapi_dispatch.zig");
const vsock = @import("vsock.zig");

pub const Error = error{
    UnsupportedHost,
};

pub fn run(io: std.Io) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const allocator = std.heap.smp_allocator;
    var cas_dir = try std.Io.Dir.openDirAbsolute(io, "/cas", .{});
    defer cas_dir.close(io);
    var work_dir = try std.Io.Dir.openDirAbsolute(io, "/work", .{});
    defer work_dir.close(io);
    var ac_dir = try work_dir.createDirPathOpen(io, "ac", .{});
    defer ac_dir.close(io);
    var action_work_dir = try work_dir.createDirPathOpen(io, "actions", .{});
    defer action_work_dir.close(io);
    var cleanup_dir = try std.Io.Dir.openDirAbsolute(io, "/work/cas-upper/upper", .{});
    defer cleanup_dir.close(io);

    try cas.Store.init(cas_dir).ensureLayout(io);
    try action_cache.Store.init(ac_dir).ensureLayout(io);

    const server: reapi_dispatch.Server = .{
        .store = cas.Store.initReady(cas_dir),
        .action_cache_store = action_cache.Store.initReady(ac_dir),
        .cleanup_store = cas.Store.initReady(cleanup_dir),
        .work_root = action_work_dir,
        .execution_options = .{
            .runtime_root_path = "/runtimes",
        },
    };

    const listener = try vsock.listen(vsock.control_port);
    defer listener.close();

    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    stderr.print("linux-actiond guest worker listening on vsock:{d}\n", .{vsock.control_port}) catch {};
    stderr.flush() catch {};

    while (true) {
        const connection = try listener.accept();
        const thread = std.Thread.spawn(.{}, connectionThread, .{ io, allocator, server, connection }) catch |err| {
            connection.close();
            try stderr.print("linux-actiond guest worker spawn failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            continue;
        };
        thread.detach();
    }
}

fn connectionThread(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: reapi_dispatch.Server,
    connection: vsock.Connection,
) void {
    defer connection.close();
    handleConnection(io, allocator, server, connection) catch |err| {
        var buffer: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
        const stderr = &stderr_writer.interface;
        stderr.print("linux-actiond guest worker connection failed: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
    };
}

fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: reapi_dispatch.Server,
    connection: vsock.Connection,
) !void {
    while (true) {
        handleConnectionFrame(io, allocator, server, connection) catch |err| switch (err) {
            error.UnexpectedEof => return,
            else => |e| return e,
        };
    }
}

fn handleConnectionFrame(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: reapi_dispatch.Server,
    connection: vsock.Connection,
) !void {
    var header_bytes: [control_protocol.encoded_header_len]u8 = undefined;
    try connection.readExact(&header_bytes);

    const header = try control_protocol.decodeHeader(&header_bytes);
    const kind = try control_protocol.decodeCallKind(header.tag);
    if (kind == .client_streaming_start) {
        try handleClientStreamingFrames(io, allocator, server, connection, header);
        return;
    }

    const payload_len = try header.payloadLen();
    const frame = try allocator.alloc(u8, control_protocol.encoded_header_len + payload_len);
    defer allocator.free(frame);
    @memcpy(frame[0..control_protocol.encoded_header_len], &header_bytes);
    try connection.readExact(frame[control_protocol.encoded_header_len..]);

    const request = try control_protocol.decodeRequest(frame);
    if (request.kind == .server_streaming_stream) {
        try handleServerStreamingStreamRequest(io, allocator, server, connection, request);
        return;
    }

    const response_body = dispatchControlRequest(io, allocator, server, request) catch |err| {
        try writeResponse(connection, .{
            .status = .application_error,
            .body = @errorName(err),
        });
        return;
    };
    defer allocator.free(response_body);

    try writeResponse(connection, .{
        .status = .ok,
        .body = response_body,
    });
}

const ControlStreamWriter = struct {
    connection: vsock.Connection,

    fn writer(self: *ControlStreamWriter) body_sink.Writer {
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
        _ = allocator;
        const self: *ControlStreamWriter = @ptrCast(@alignCast(ctx));
        try writeResponse(self.connection, .{
            .status = .stream_chunk,
            .body = bytes,
        });
    }
};

fn handleServerStreamingStreamRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: reapi_dispatch.Server,
    connection: vsock.Connection,
    request: control_protocol.Request,
) !void {
    var stream_writer = ControlStreamWriter{ .connection = connection };
    server.handleServerStreamingResponse(
        io,
        allocator,
        request.method,
        request.body,
        stream_writer.writer(),
    ) catch |err| {
        try writeResponse(connection, .{
            .status = .application_error,
            .body = @errorName(err),
        });
        return;
    };

    try writeResponse(connection, .{
        .status = .ok,
        .body = "",
    });
}

fn handleClientStreamingFrames(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: reapi_dispatch.Server,
    connection: vsock.Connection,
    start_header: control_protocol.Header,
) !void {
    if (start_header.body_len != 0) return error.InvalidCallKind;

    const method = try allocator.alloc(u8, start_header.method_len);
    defer allocator.free(method);
    try connection.readExact(method);

    const response_body = dispatchClientStreamingFrames(
        io,
        allocator,
        server,
        connection,
        method,
    ) catch |err| {
        try writeResponse(connection, .{
            .status = .application_error,
            .body = @errorName(err),
        });
        return;
    };
    defer allocator.free(response_body);

    try writeResponse(connection, .{
        .status = .ok,
        .body = response_body,
    });
}

fn dispatchClientStreamingFrames(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: reapi_dispatch.Server,
    connection: vsock.Connection,
    method: []const u8,
) ![]u8 {
    if (!std.mem.eql(u8, method, reapi_dispatch.bytestream_write)) {
        return error.UnsupportedMethod;
    }

    var stream = bytestream_service.WriteGrpcStream.init(server.store);
    defer stream.deinit(io, allocator);

    var stream_error: ?anyerror = null;
    while (true) {
        var header_bytes: [control_protocol.encoded_header_len]u8 = undefined;
        try connection.readExact(&header_bytes);

        const header = try control_protocol.decodeHeader(&header_bytes);
        const kind = try control_protocol.decodeCallKind(header.tag);
        switch (kind) {
            .client_streaming_chunk => {
                if (header.method_len != 0) return error.InvalidCallKind;
                try readClientStreamingChunk(io, allocator, connection, header.body_len, &stream, &stream_error);
            },
            .client_streaming_finish => {
                if (header.method_len != 0 or header.body_len != 0) return error.InvalidCallKind;
                if (stream_error) |err| return err;
                const response = try stream.finish(io);
                return try encodeGrpcRequest(allocator, response);
            },
            else => return error.InvalidCallKind,
        }
    }
}

const client_streaming_read_buffer_len = 64 * 1024;

fn readClientStreamingChunk(
    io: std.Io,
    allocator: std.mem.Allocator,
    connection: vsock.Connection,
    body_len: u64,
    stream: *bytestream_service.WriteGrpcStream,
    stream_error: *?anyerror,
) !void {
    var buffer: [client_streaming_read_buffer_len]u8 = undefined;
    var remaining = body_len;
    while (remaining != 0) {
        const read_len: usize = @intCast(@min(remaining, buffer.len));
        try connection.readExact(buffer[0..read_len]);
        if (stream_error.* == null) {
            stream.append(io, allocator, buffer[0..read_len]) catch |err| {
                stream_error.* = err;
            };
        }
        remaining -= read_len;
    }
}

pub fn dispatchControlRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: reapi_dispatch.Server,
    request: control_protocol.Request,
) ![]u8 {
    return switch (request.kind) {
        .unary => try server.handleUnary(io, allocator, request.method, request.body),
        .server_streaming => try server.handleServerStreaming(io, allocator, request.method, request.body),
        .client_streaming => try server.handleClientStreaming(io, allocator, request.method, request.body),
        .server_streaming_stream,
        .client_streaming_start,
        .client_streaming_chunk,
        .client_streaming_finish,
        => error.InvalidCallKind,
    };
}

fn writeResponse(connection: vsock.Connection, response: control_protocol.Response) !void {
    var header: [control_protocol.encoded_header_len]u8 = undefined;
    try control_protocol.encodeResponseHeader(&header, response);
    try connection.writeAll(&header);
    try connection.writeAll(response.body);
}

test "guest worker is Linux-only" {
    if (comptime builtin.os.tag != .linux) {
        try std.testing.expectError(error.UnsupportedHost, run(std.testing.io));
    }
}

fn encodeGrpcRequest(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const proto = try reapi.encodeAlloc(allocator, value);
    defer allocator.free(proto);
    return try grpc_record.encodeAlloc(allocator, .{ .payload = proto });
}

test "guest worker dispatches control requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const server = reapi_dispatch.Server.init(cas.Store.init(tmp.dir));
    const body = try encodeGrpcRequest(std.testing.allocator, reapi.GetCapabilitiesRequest{});
    defer std.testing.allocator.free(body);

    const response_body = try dispatchControlRequest(std.testing.io, std.testing.allocator, server, .{
        .kind = .unary,
        .method = reapi_dispatch.capabilities_get,
        .body = body,
    });
    defer std.testing.allocator.free(response_body);

    var messages = grpc_record.Iterator.init(response_body);
    const message = (try messages.next()).?;
    try std.testing.expect(message.payload.len > 0);
}
