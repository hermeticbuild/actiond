const std = @import("std");
const darwin_vm = @import("darwin_vm.zig");
const vsock = @import("vsock.zig");

pub const Error = error{
    InvalidListenAddress,
    UnsupportedHost,
};

const pump_buffer_len = 64 * 1024;
const bridge_log_min_bytes = 64 * 1024;
const bridge_log_min_ns = 10 * std.time.ns_per_ms;

const PumpStats = struct {
    bytes: u64 = 0,
    read_calls: u64 = 0,
    write_calls: u64 = 0,
    read_errors: u64 = 0,
    write_errors: u64 = 0,
};

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
        const thread = std.Thread.spawn(.{}, connectionThread, .{ io, machine, client_fd }) catch |err| {
            accepted.close(io);
            std.log.err("raw gRPC bridge connection spawn failed: {s}", .{@errorName(err)});
            sleepMilliseconds(10);
            continue;
        };
        thread.detach();
    }
}

fn connectionThread(io: std.Io, machine: *darwin_vm.Machine, client_fd: std.posix.fd_t) void {
    defer closeFd(client_fd);
    const started = std.Io.Clock.awake.now(io);

    const guest_fd = machine.connectControlPort(vsock.grpc_port) catch |err| {
        std.log.err("raw gRPC bridge vsock connect failed: {s}", .{@errorName(err)});
        return;
    };
    defer closeFd(guest_fd);

    var client_to_guest_stats: PumpStats = .{};
    var guest_to_client_stats: PumpStats = .{};
    const client_to_guest = std.Thread.spawn(.{}, pumpAndShutdown, .{ client_fd, guest_fd, &client_to_guest_stats }) catch return;
    const guest_to_client = std.Thread.spawn(.{}, pumpAndShutdown, .{ guest_fd, client_fd, &guest_to_client_stats }) catch {
        shutdownSend(guest_fd);
        client_to_guest.join();
        return;
    };

    client_to_guest.join();
    guest_to_client.join();
    logConnectionTiming(started, io, client_to_guest_stats, guest_to_client_stats);
}

fn pumpAndShutdown(src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, stats: *PumpStats) void {
    var buffer: [pump_buffer_len]u8 = undefined;
    while (true) {
        const n = readFd(src_fd, &buffer) catch {
            stats.read_errors += 1;
            break;
        };
        stats.read_calls += 1;
        if (n == 0) break;
        stats.bytes += n;
        writeAll(dst_fd, buffer[0..n], stats) catch {
            stats.write_errors += 1;
            break;
        };
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

fn writeAll(fd: std.posix.fd_t, bytes: []const u8, stats: *PumpStats) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        stats.write_calls += 1;
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

fn logConnectionTiming(started: std.Io.Timestamp, io: std.Io, client_to_guest: PumpStats, guest_to_client: PumpStats) void {
    const elapsed_ns = started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    const total_bytes = client_to_guest.bytes + guest_to_client.bytes;
    if (total_bytes < bridge_log_min_bytes and elapsed_ns < bridge_log_min_ns) return;

    std.log.info(
        "vm bridge timing elapsed_ns={d} client_to_guest_bytes={d} guest_to_client_bytes={d} client_to_guest_reads={d} client_to_guest_writes={d} guest_to_client_reads={d} guest_to_client_writes={d} read_errors={d} write_errors={d}",
        .{
            elapsed_ns,
            client_to_guest.bytes,
            guest_to_client.bytes,
            client_to_guest.read_calls,
            client_to_guest.write_calls,
            guest_to_client.read_calls,
            guest_to_client.write_calls,
            client_to_guest.read_errors + guest_to_client.read_errors,
            client_to_guest.write_errors + guest_to_client.write_errors,
        },
    );
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
