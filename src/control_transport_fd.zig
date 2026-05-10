const std = @import("std");
const control_protocol = @import("control_protocol.zig");
const guest_proxy = @import("guest_proxy.zig");

pub const Error = error{
    OpenFailed,
    ReadFailed,
    UnexpectedEof,
    WriteFailed,
};

const connection_pool_size = 8;

const ConnectionSlot = struct {
    mutex: std.Io.Mutex = .init,
    fd: ?std.posix.fd_t = null,
};

pub const Opener = struct {
    ctx: *anyopaque,
    open: *const fn (*anyopaque) anyerror!std.posix.fd_t,
};

pub const Client = struct {
    opener: Opener,
    slots: [connection_pool_size]ConnectionSlot = [_]ConnectionSlot{.{}} ** connection_pool_size,
    next_slot: std.atomic.Value(u32) = .init(0),

    pub fn deinit(self: *Client, io: std.Io) void {
        for (&self.slots) |*slot| {
            slot.mutex.lockUncancelable(io);
            defer slot.mutex.unlock(io);
            if (slot.fd) |fd| {
                closeFd(fd);
                slot.fd = null;
            }
        }
    }

    pub fn transport(self: *Client) guest_proxy.Transport {
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
        const self: *Client = @ptrCast(@alignCast(ctx));
        const slot_index = self.next_slot.fetchAdd(1, .monotonic) % connection_pool_size;
        const slot = &self.slots[slot_index];
        try slot.mutex.lock(io);
        defer slot.mutex.unlock(io);

        const fd = try self.slotFd(slot);
        return self.roundTripFd(allocator, fd, request) catch |err| {
            if (slot.fd) |cached| closeFd(cached);
            slot.fd = null;
            return err;
        };
    }

    fn roundTripFd(
        self: *Client,
        allocator: std.mem.Allocator,
        fd: std.posix.fd_t,
        request: control_protocol.Request,
    ) ![]u8 {
        _ = self;

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

    fn slotFd(self: *Client, slot: *ConnectionSlot) !std.posix.fd_t {
        if (slot.fd) |fd| return fd;
        const fd = self.opener.open(self.opener.ctx) catch return error.OpenFailed;
        slot.fd = fd;
        return fd;
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
    opens: usize = 0,

    fn opener(self: *SocketPairOpener) Opener {
        return .{
            .ctx = self,
            .open = open,
        };
    }

    fn open(ctx: *anyopaque) !std.posix.fd_t {
        const self: *SocketPairOpener = @ptrCast(@alignCast(ctx));
        self.opens += 1;
        return try dupFd(self.fd);
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
    defer closeFd(fds[1]);

    var opener = SocketPairOpener{ .fd = fds[1] };
    var client = Client{ .opener = opener.opener() };
    defer client.deinit(std.testing.io);
    const response_frame = try client.transport().call(std.testing.io, std.testing.allocator, .{
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

test "Client reuses a cached fd for repeated calls on one thread" {
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
            for (0..connection_pool_size + 1) |_| {
                var header_bytes: [control_protocol.encoded_header_len]u8 = undefined;
                try readExact(fd, &header_bytes);
                const header = try control_protocol.decodeHeader(&header_bytes);
                const payload_len = try header.payloadLen();
                const frame = try std.testing.allocator.alloc(u8, control_protocol.encoded_header_len + payload_len);
                defer std.testing.allocator.free(frame);
                @memcpy(frame[0..control_protocol.encoded_header_len], &header_bytes);
                try readExact(fd, frame[control_protocol.encoded_header_len..]);

                const response = try control_protocol.encodeResponseAlloc(std.testing.allocator, .{
                    .status = .ok,
                    .body = "world",
                });
                defer std.testing.allocator.free(response);
                try writeAll(fd, response);
            }
        }
    }.run, .{fds[0]});
    defer closeFd(fds[1]);

    var opener = SocketPairOpener{ .fd = fds[1] };
    var client = Client{ .opener = opener.opener() };
    defer client.deinit(std.testing.io);
    for (0..connection_pool_size + 1) |_| {
        const response_frame = try client.transport().call(std.testing.io, std.testing.allocator, .{
            .kind = .unary,
            .method = "/svc/Call",
            .body = "hello",
        });
        defer std.testing.allocator.free(response_frame);

        const response = try control_protocol.decodeResponse(response_frame);
        try std.testing.expectEqual(control_protocol.Status.ok, response.status);
        try std.testing.expectEqualStrings("world", response.body);
    }

    try std.testing.expectEqual(@as(usize, connection_pool_size), opener.opens);
    server_thread.join();
}

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.posix.system.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

fn dupFd(fd: std.posix.fd_t) !std.posix.fd_t {
    while (true) {
        const rc = std.posix.system.dup(fd);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.OpenFailed,
        }
    }
}
