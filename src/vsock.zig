const builtin = @import("builtin");
const std = @import("std");

const linux = std.os.linux;

pub const control_port: u32 = 5000;
pub const any_cid: u32 = 0xffffffff;
pub const backlog: u32 = 128;

pub const Error = error{
    AcceptFailed,
    BindFailed,
    ListenFailed,
    SocketFailed,
    UnsupportedHost,
};

pub const Listener = struct {
    fd: i32,

    pub fn close(self: Listener) void {
        _ = linux.close(self.fd);
    }

    pub fn accept(self: Listener) !Connection {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

        const rc = linux.accept(self.fd, null, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc) },
            else => return error.AcceptFailed,
        }
    }
};

pub const Connection = struct {
    fd: i32,

    pub fn close(self: Connection) void {
        _ = linux.close(self.fd);
    }
};

pub fn listen(port: u32) !Listener {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const socket_rc = linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    switch (std.posix.errno(socket_rc)) {
        .SUCCESS => {},
        else => return error.SocketFailed,
    }
    const fd: i32 = @intCast(socket_rc);
    errdefer _ = linux.close(fd);

    var addr = address(port);
    const bind_rc = linux.bind(
        fd,
        @as(*const linux.sockaddr, @ptrCast(&addr)),
        @sizeOf(linux.sockaddr.vm),
    );
    switch (std.posix.errno(bind_rc)) {
        .SUCCESS => {},
        else => return error.BindFailed,
    }

    const listen_rc = linux.listen(fd, backlog);
    switch (std.posix.errno(listen_rc)) {
        .SUCCESS => {},
        else => return error.ListenFailed,
    }

    return .{ .fd = fd };
}

pub fn address(port: u32) linux.sockaddr.vm {
    return .{
        .port = port,
        .cid = any_cid,
        .flags = 0,
    };
}

test "vsock address uses any CID and requested port" {
    const addr = address(1234);
    try std.testing.expectEqual(@as(u32, 1234), addr.port);
    try std.testing.expectEqual(any_cid, addr.cid);
    try std.testing.expectEqual(linux.AF.VSOCK, addr.family);
}
