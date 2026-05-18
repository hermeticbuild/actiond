const std = @import("std");
const darwin_vm = @import("darwin_vm.zig");
const vsock = @import("vsock.zig");

pub const Error = error{
    InvalidListenAddress,
    UnsupportedHost,
};

const pump_buffer_len = 64 * 1024;

pub fn serve(
    io: std.Io,
    listen: []const u8,
    machine: *darwin_vm.Machine,
) !void {
    if (comptime @import("builtin").os.tag != .macos) return error.UnsupportedHost;

    const address = try parseListenAddress(listen);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.log.info("actiond VM raw gRPC bridge listening on {s} -> vsock:{d}", .{ listen, vsock.grpc_port });
    while (true) {
        var accepted = listener.accept(io) catch |err| {
            std.log.err("raw gRPC bridge accept failed: {s}", .{@errorName(err)});
            sleepMilliseconds(10);
            continue;
        };
        const client_fd = accepted.socket.handle;
        const thread = std.Thread.spawn(.{}, connectionThread, .{ machine, client_fd }) catch |err| {
            accepted.close(io);
            std.log.err("raw gRPC bridge connection spawn failed: {s}", .{@errorName(err)});
            sleepMilliseconds(10);
            continue;
        };
        thread.detach();
    }
}

fn connectionThread(machine: *darwin_vm.Machine, client_fd: std.posix.fd_t) void {
    defer closeFd(client_fd);

    const guest_fd = machine.connectControlPort(vsock.grpc_port) catch |err| {
        std.log.err("raw gRPC bridge vsock connect failed: {s}", .{@errorName(err)});
        return;
    };
    defer closeFd(guest_fd);

    const client_to_guest = std.Thread.spawn(.{}, pumpAndShutdown, .{ client_fd, guest_fd }) catch return;
    const guest_to_client = std.Thread.spawn(.{}, pumpAndShutdown, .{ guest_fd, client_fd }) catch {
        shutdownSend(guest_fd);
        client_to_guest.join();
        return;
    };

    client_to_guest.join();
    guest_to_client.join();
}

fn pumpAndShutdown(src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t) void {
    var buffer: [pump_buffer_len]u8 = undefined;
    while (true) {
        const n = readFd(src_fd, &buffer) catch break;
        if (n == 0) break;
        writeAll(dst_fd, buffer[0..n]) catch break;
    }
    shutdownSend(dst_fd);
}

fn readFd(fd: std.posix.fd_t, buffer: []u8) !usize {
    while (true) {
        const rc = std.posix.system.read(fd, buffer.ptr, buffer.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
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

fn shutdownSend(fd: std.posix.fd_t) void {
    _ = std.c.shutdown(fd, std.c.SHUT.WR);
}

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.posix.system.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

fn parseListenAddress(listen: []const u8) !std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parseLiteral(listen) catch return error.InvalidListenAddress;
}

fn sleepMilliseconds(milliseconds: u32) void {
    var request: std.c.timespec = .{
        .sec = @intCast(milliseconds / std.time.ms_per_s),
        .nsec = @intCast((milliseconds % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    while (std.c.nanosleep(&request, &request) != 0) {}
}

test "parseListenAddress accepts IPv4 host and port" {
    const address = try parseListenAddress("127.0.0.1:8980");
    try std.testing.expectEqual(@as(u16, 8980), address.getPort());
}
