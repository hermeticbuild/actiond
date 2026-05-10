const std = @import("std");
const control_protocol = @import("control_protocol.zig");
const grpc_http2_server = @import("grpc_http2_server.zig");

pub const Error = error{
    GuestApplicationError,
};

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
};

pub const Proxy = struct {
    transport: Transport,

    pub fn dispatcher(self: *Proxy) grpc_http2_server.Dispatcher {
        return .{
            .ctx = self,
            .handle_unary = unary,
            .handle_server_streaming = serverStreaming,
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
        return self.forward(io, allocator, .server_streaming, method, body);
    }

    fn clientStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        const self: *Proxy = @ptrCast(@alignCast(ctx));
        return self.forward(io, allocator, .client_streaming, method, body);
    }

    fn startClientStreaming(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        method: []const u8,
    ) !grpc_http2_server.ClientStream {
        const self: *Proxy = @ptrCast(@alignCast(ctx));
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
            .application_error => {
                defer response.deinit(allocator);
                std.log.err("guest application error for {s}: {s}", .{ method, response.body });
                return error.GuestApplicationError;
            },
        };
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
            .application_error => {
                defer response.deinit(allocator);
                std.log.err("guest application error for {s}: {s}", .{ self.method, response.body });
                return error.GuestApplicationError;
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

const FakeStreamingTransport = struct {
    expected_method: []const u8,
    response_body: []const u8,
    received: std.ArrayListUnmanaged(u8) = .empty,

    fn transport(self: *FakeStreamingTransport) Transport {
        return .{
            .ctx = self,
            .round_trip = roundTrip,
            .start_client_streaming = startClientStreaming,
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
