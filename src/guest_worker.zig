const builtin = @import("builtin");
const std = @import("std");
const action_cache = @import("action_cache.zig");
const action_executor = @import("action_executor.zig");
const cas = @import("cas.zig");
const control_protocol = @import("control_protocol.zig");
const grpc_http2_server = @import("grpc_http2_server.zig");
const reapi_dispatch = @import("reapi_dispatch.zig");
const vsock = @import("vsock.zig");

pub const Error = error{
    UnsupportedHost,
};

pub const guest_cas_blob_root_path = "/cas/blobs/sha256";

pub fn run(io: std.Io) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const allocator = std.heap.smp_allocator;
    var cas_dir = try std.Io.Dir.openDirAbsolute(io, "/cas", .{});
    defer cas_dir.close(io);
    var work_dir = try std.Io.Dir.openDirAbsolute(io, "/work", .{});
    defer work_dir.close(io);
    var action_work_dir = try work_dir.createDirPathOpen(io, "actions", .{});
    defer action_work_dir.close(io);

    try cas.Store.init(cas_dir).ensureLayout(io);
    var ac_dir = try cas_dir.createDirPathOpen(io, "ac", .{});
    defer ac_dir.close(io);
    try action_cache.Store.init(ac_dir).ensureLayout(io);

    const execution_options = try action_executor.prepareExecuteOptions(io, allocator, cas.Store.initReady(cas_dir), .{
        .runtime_root_path = "/runtimes",
        .use_actiondfs = true,
        .cas_blob_root_path = guest_cas_blob_root_path,
        .input_cas_blob_root_path = guest_cas_blob_root_path,
    });

    const server: reapi_dispatch.Server = .{
        .store = cas.Store.initReady(cas_dir),
        .action_cache_store = action_cache.Store.initReady(ac_dir),
        .work_root = action_work_dir,
        .execution_options = execution_options.options,
    };

    const listener = try vsock.listen(vsock.control_port);
    defer listener.close();

    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    stderr.print("linux-actiond guest worker listening on vsock:{d}\n", .{vsock.control_port}) catch {};
    stderr.flush() catch {};

    const grpc_thread = try std.Thread.spawn(.{}, grpcListenerThread, .{ io, allocator, server });
    grpc_thread.detach();

    while (true) {
        const connection = try listener.accept();
        const thread = std.Thread.spawn(.{}, connectionThread, .{ io, allocator, connection }) catch |err| {
            connection.close();
            try stderr.print("linux-actiond guest worker spawn failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            continue;
        };
        thread.detach();
    }
}

fn grpcListenerThread(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: reapi_dispatch.Server,
) void {
    const listener = vsock.listen(vsock.grpc_port) catch |err| {
        logGuestError(io, "linux-actiond guest gRPC listen failed", err);
        return;
    };
    defer listener.close();

    logGuestInfo(io, "linux-actiond guest gRPC listening on vsock:{d}\n", .{vsock.grpc_port});
    var owned_server = server;
    const dispatcher = grpc_http2_server.Dispatcher.fromReapiServer(&owned_server);
    while (true) {
        const connection = listener.accept() catch |err| {
            logGuestError(io, "linux-actiond guest gRPC accept failed", err);
            continue;
        };
        const thread = std.Thread.spawn(.{}, grpcConnectionThread, .{ io, allocator, dispatcher, connection }) catch |err| {
            connection.close();
            logGuestError(io, "linux-actiond guest gRPC spawn failed", err);
            continue;
        };
        thread.detach();
    }
}

fn grpcConnectionThread(
    io: std.Io,
    allocator: std.mem.Allocator,
    dispatcher: grpc_http2_server.Dispatcher,
    connection: vsock.Connection,
) void {
    grpc_http2_server.handleConnectionFd(io, allocator, dispatcher, connection.fd) catch |err| {
        if (err != error.EndOfStream) {
            logGuestError(io, "linux-actiond guest gRPC connection failed", err);
        }
    };
}

fn logGuestError(io: std.Io, message: []const u8, err: anyerror) void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    stderr.print("{s}: {s}\n", .{ message, @errorName(err) }) catch {};
    stderr.flush() catch {};
}

fn logGuestInfo(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
}

fn connectionThread(
    io: std.Io,
    allocator: std.mem.Allocator,
    connection: vsock.Connection,
) void {
    defer connection.close();
    handleConnection(io, allocator, connection) catch |err| {
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
    connection: vsock.Connection,
) !void {
    while (true) {
        handleConnectionFrame(io, allocator, connection) catch |err| switch (err) {
            error.UnexpectedEof => return,
            else => |e| return e,
        };
    }
}

fn handleConnectionFrame(
    io: std.Io,
    allocator: std.mem.Allocator,
    connection: vsock.Connection,
) !void {
    var header_bytes: [control_protocol.encoded_header_len]u8 = undefined;
    try connection.readExact(&header_bytes);

    const header = try control_protocol.decodeHeader(&header_bytes);
    const kind = try control_protocol.decodeCallKind(header.tag);
    if (kind != .unary) return error.InvalidCallKind;

    const payload_len = try header.payloadLen();
    const frame = try allocator.alloc(u8, control_protocol.encoded_header_len + payload_len);
    defer allocator.free(frame);
    @memcpy(frame[0..control_protocol.encoded_header_len], &header_bytes);
    try connection.readExact(frame[control_protocol.encoded_header_len..]);

    const request = try control_protocol.decodeRequest(frame);
    const response_body = dispatchControlRequest(io, allocator, request) catch |err| {
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

pub fn dispatchControlRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: control_protocol.Request,
) ![]u8 {
    if (request.kind == .unary and std.mem.eql(u8, request.method, control_protocol.actiondfs_stats_method)) {
        if (request.body.len != 0) return error.InvalidCallKind;
        return try readActiondfsStats(io, allocator);
    }

    return error.UnsupportedMethod;
}

fn readActiondfsStats(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, "/proc/actiondfs_stats", .{});
    defer file.close(io);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = try readFd(file.handle, &buffer);
        if (n == 0) break;
        try out.appendSlice(allocator, buffer[0..n]);
        if (out.items.len > 1024 * 1024) return error.MessageTooLarge;
    }
    return try out.toOwnedSlice(allocator);
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

test "guest worker uses guest-native CAS for actiondfs reads" {
    try std.testing.expectEqualStrings("/cas/blobs/sha256", guest_cas_blob_root_path);
}

test "guest worker rejects malformed actiondfs stats requests before touching proc" {
    try std.testing.expectError(error.InvalidCallKind, dispatchControlRequest(std.testing.io, std.testing.allocator, .{
        .kind = .unary,
        .method = control_protocol.actiondfs_stats_method,
        .body = "unexpected",
    }));
}

test "guest worker rejects REAPI over the stats control channel" {
    try std.testing.expectError(error.UnsupportedMethod, dispatchControlRequest(std.testing.io, std.testing.allocator, .{
        .kind = .unary,
        .method = reapi_dispatch.capabilities_get,
        .body = "",
    }));
}
