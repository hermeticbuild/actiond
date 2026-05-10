const std = @import("std");
const control_protocol = @import("control_protocol.zig");
const grpc_http2_server = @import("grpc_http2_server.zig");

pub const Error = error{
    GuestApplicationError,
};

pub const Transport = struct {
    ctx: *anyopaque,
    round_trip: *const fn (
        *anyopaque,
        std.Io,
        std.mem.Allocator,
        control_protocol.Request,
    ) anyerror![]u8,

    pub fn call(
        self: Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
        request: control_protocol.Request,
    ) ![]u8 {
        return self.round_trip(self.ctx, io, allocator, request);
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

    fn forward(
        self: *Proxy,
        io: std.Io,
        allocator: std.mem.Allocator,
        kind: control_protocol.CallKind,
        method: []const u8,
        body: []const u8,
    ) ![]u8 {
        const response_frame = try self.transport.call(io, allocator, .{
            .kind = kind,
            .method = method,
            .body = body,
        });
        defer allocator.free(response_frame);

        const response = try control_protocol.decodeResponse(response_frame);
        return switch (response.status) {
            .ok => try allocator.dupe(u8, response.body),
            .application_error => {
                std.log.err("guest application error for {s}: {s}", .{ method, response.body });
                return error.GuestApplicationError;
            },
        };
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
        };
    }

    fn roundTrip(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        request: control_protocol.Request,
    ) ![]u8 {
        _ = io;
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(self.expected_kind, request.kind);
        try std.testing.expectEqualStrings(self.expected_method, request.method);
        try std.testing.expectEqualStrings(self.expected_body, request.body);
        return try control_protocol.encodeResponseAlloc(allocator, .{
            .status = .ok,
            .body = self.response_body,
        });
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
