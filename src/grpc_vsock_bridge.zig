const std = @import("std");
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
    machine: anytype,
) !void {
    if (comptime @import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux) return error.UnsupportedHost;

    const address = try parseListenAddress(listen);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var connections: std.Io.Group = .init;
    defer connections.cancel(io);
    const ConnectionTask = struct {
        fn run(task_io: std.Io, task_machine: @TypeOf(machine), client_fd: std.posix.fd_t) void {
            connectionTask(task_io, task_machine, client_fd);
        }
    };

    std.log.info("actiond VM raw gRPC bridge listening on {s} -> vsock:{d}", .{ listen, vsock.grpc_port });
    while (true) {
        var accepted = listener.accept(io) catch |err| {
            if (err == error.Canceled) return err;
            std.log.err("raw gRPC bridge accept failed: {s}", .{@errorName(err)});
            sleepMilliseconds(io, 10);
            continue;
        };
        const client_fd = accepted.socket.handle;
        setTcpNoDelay(client_fd) catch |err| {
            std.log.debug("raw gRPC bridge TCP_NODELAY failed: {s}", .{@errorName(err)});
        };
        connections.concurrent(io, ConnectionTask.run, .{ io, machine, client_fd }) catch |err| {
            accepted.close(io);
            std.log.err("raw gRPC bridge connection task failed: {s}", .{@errorName(err)});
            sleepMilliseconds(io, 10);
            continue;
        };
    }
}

fn connectionTask(io: std.Io, machine: anytype, client_fd: std.posix.fd_t) void {
    defer closeFd(client_fd);
    const started = std.Io.Clock.awake.now(io);

    const guest_fd = machine.connectControlPort(vsock.grpc_port) catch |err| {
        std.log.err("raw gRPC bridge vsock connect failed: {s}", .{@errorName(err)});
        return;
    };
    defer closeFd(guest_fd);

    var client_to_guest_stats: PumpStats = .{};
    var guest_to_client_stats: PumpStats = .{};
    var pumps: std.Io.Group = .init;
    defer pumps.cancel(io);

    pumps.concurrent(io, pumpAndShutdown, .{ io, client_fd, guest_fd, &client_to_guest_stats }) catch |err| {
        std.log.err("raw gRPC bridge client-to-guest task failed: {s}", .{@errorName(err)});
        return;
    };
    pumps.concurrent(io, pumpAndShutdown, .{ io, guest_fd, client_fd, &guest_to_client_stats }) catch |err| {
        shutdownSend(guest_fd);
        std.log.err("raw gRPC bridge guest-to-client task failed: {s}", .{@errorName(err)});
        return;
    };

    pumps.await(io) catch |err| {
        if (err != error.Canceled) {
            std.log.err("raw gRPC bridge pump wait failed: {s}", .{@errorName(err)});
        }
        return;
    };
    logConnectionTiming(started, io, client_to_guest_stats, guest_to_client_stats);
}

fn pumpAndShutdown(io: std.Io, src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, stats: *PumpStats) !void {
    const src_file: std.Io.File = .{
        .handle = src_fd,
        .flags = .{ .nonblocking = false },
    };
    const dst_file: std.Io.File = .{
        .handle = dst_fd,
        .flags = .{ .nonblocking = false },
    };
    var buffer: [pump_buffer_len]u8 = undefined;
    while (true) {
        const n = src_file.readStreaming(io, &.{buffer[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Canceled => |e| return e,
            else => {
                stats.read_errors += 1;
                break;
            },
        };
        stats.read_calls += 1;
        if (n == 0) break;
        stats.bytes += n;
        writeAll(io, dst_file, buffer[0..n], stats) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => {
                stats.write_errors += 1;
                break;
            },
        };
    }
    shutdownSend(dst_fd);
}

fn writeAll(io: std.Io, file: std.Io.File, bytes: []const u8, stats: *PumpStats) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        stats.write_calls += 1;
        const n = try file.writeStreaming(io, &.{}, &.{bytes[offset..]}, 1);
        if (n == 0) return error.WriteFailed;
        offset += n;
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

fn setTcpNoDelay(fd: std.posix.fd_t) !void {
    var enabled: i32 = 1;
    try std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&enabled),
    );
}

fn parseListenAddress(listen: []const u8) !std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parseLiteral(listen) catch return error.InvalidListenAddress;
}

fn sleepMilliseconds(io: std.Io, milliseconds: u32) void {
    io.sleep(.fromMilliseconds(milliseconds), .awake) catch {};
}

test "parseListenAddress accepts IPv4 host and port" {
    const address = try parseListenAddress("127.0.0.1:8980");
    try std.testing.expectEqual(@as(u16, 8980), address.getPort());
}
