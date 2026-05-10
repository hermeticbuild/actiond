const std = @import("std");
const control_protocol = @import("control_protocol.zig");
const guest_proxy = @import("guest_proxy.zig");

pub const Error = error{
    OpenFailed,
    ReadFailed,
    UnexpectedEof,
    WriteFailed,
};

pub const Opener = struct {
    ctx: *anyopaque,
    open: *const fn (*anyopaque) anyerror!std.posix.fd_t,
};

pub const Client = struct {
    opener: Opener,

    pub fn transport(self: *Client) guest_proxy.Transport {
        return .{
            .ctx = self,
            .round_trip = roundTrip,
        };
    }

    fn roundTrip(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        request: control_protocol.Request,
    ) ![]u8 {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const fd = self.opener.open(self.opener.ctx) catch return error.OpenFailed;
        defer closeFd(fd);

        const request_frame = try control_protocol.encodeRequestAlloc(allocator, request);
        defer allocator.free(request_frame);
        try writeAll(fd, request_frame);

        var header_bytes: [control_protocol.encoded_header_len]u8 = undefined;
        try readExact(fd, &header_bytes);
        const header = try control_protocol.decodeHeader(&header_bytes);
        const payload_len = try header.payloadLen();

        const response_frame = try allocator.alloc(u8, control_protocol.encoded_header_len + payload_len);
        errdefer allocator.free(response_frame);
        @memcpy(response_frame[0..control_protocol.encoded_header_len], &header_bytes);
        try readExact(fd, response_frame[control_protocol.encoded_header_len..]);
        return response_frame;
    }
};

fn readExact(fd: std.posix.fd_t, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const rc = std.posix.system.read(fd, buffer[offset..].ptr, buffer.len - offset);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.UnexpectedEof;
                offset += n;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteFailed;
                offset += n;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

const SocketPairOpener = struct {
    fd: std.posix.fd_t,

    fn opener(self: *SocketPairOpener) Opener {
        return .{
            .ctx = self,
            .open = open,
        };
    }

    fn open(ctx: *anyopaque) !std.posix.fd_t {
        const self: *SocketPairOpener = @ptrCast(@alignCast(ctx));
        return self.fd;
    }
};

test "Client round trips a control frame over an fd" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var fds: [2]std.posix.socket_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
        &fds,
    ))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.fd_t) !void {
            defer closeFd(fd);
            var header_bytes: [control_protocol.encoded_header_len]u8 = undefined;
            try readExact(fd, &header_bytes);
            const header = try control_protocol.decodeHeader(&header_bytes);
            const payload_len = try header.payloadLen();
            const frame = try std.testing.allocator.alloc(u8, control_protocol.encoded_header_len + payload_len);
            defer std.testing.allocator.free(frame);
            @memcpy(frame[0..control_protocol.encoded_header_len], &header_bytes);
            try readExact(fd, frame[control_protocol.encoded_header_len..]);

            const request = try control_protocol.decodeRequest(frame);
            try std.testing.expectEqual(control_protocol.CallKind.unary, request.kind);
            try std.testing.expectEqualStrings("/svc/Call", request.method);
            try std.testing.expectEqualStrings("hello", request.body);

            const response = try control_protocol.encodeResponseAlloc(std.testing.allocator, .{
                .status = .ok,
                .body = "world",
            });
            defer std.testing.allocator.free(response);
            try writeAll(fd, response);
        }
    }.run, .{fds[0]});

    var opener = SocketPairOpener{ .fd = fds[1] };
    var client = Client{ .opener = opener.opener() };
    const response_frame = try client.transport().call(std.testing.allocator, .{
        .kind = .unary,
        .method = "/svc/Call",
        .body = "hello",
    });
    defer std.testing.allocator.free(response_frame);

    server_thread.join();
    const response = try control_protocol.decodeResponse(response_frame);
    try std.testing.expectEqual(control_protocol.Status.ok, response.status);
    try std.testing.expectEqualStrings("world", response.body);
}

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.posix.system.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}
