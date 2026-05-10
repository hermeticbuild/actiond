const builtin = @import("builtin");
const std = @import("std");
const action_cache = @import("action_cache.zig");
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

    try cas.Store.init(cas_dir).ensureLayout(io);
    try action_cache.Store.init(ac_dir).ensureLayout(io);

    const server: reapi_dispatch.Server = .{
        .store = cas.Store.initReady(cas_dir),
        .action_cache_store = action_cache.Store.initReady(ac_dir),
        .work_root = action_work_dir,
    };

    const listener = try vsock.listen(vsock.control_port);
    defer listener.close();

    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("linux-actiond guest worker listening on vsock:{d}\n", .{vsock.control_port});
    try stderr.flush();

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
    const payload_len = try header.payloadLen();
    const frame = try allocator.alloc(u8, control_protocol.encoded_header_len + payload_len);
    defer allocator.free(frame);
    @memcpy(frame[0..control_protocol.encoded_header_len], &header_bytes);
    try connection.readExact(frame[control_protocol.encoded_header_len..]);

    const request = try control_protocol.decodeRequest(frame);
    const response_body = dispatchControlRequest(io, allocator, server, request) catch |err| {
        const response_frame = try control_protocol.encodeResponseAlloc(allocator, .{
            .status = .application_error,
            .body = @errorName(err),
        });
        defer allocator.free(response_frame);
        try connection.writeAll(response_frame);
        return;
    };
    defer allocator.free(response_body);

    const response_frame = try control_protocol.encodeResponseAlloc(allocator, .{
        .status = .ok,
        .body = response_body,
    });
    defer allocator.free(response_frame);
    try connection.writeAll(response_frame);
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
    };
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
