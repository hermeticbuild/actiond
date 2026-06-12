const builtin = @import("builtin");
const std = @import("std");
const vsock = @import("vsock.zig");
const windows_hcs = @import("windows_hcs.zig");

const pump_buffer_len = 64 * 1024;

pub fn serve(io: std.Io, listen_address: []const u8, machine: *windows_hcs.Machine) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedHost;
    const readiness_socket = try machine.connectPort(io, vsock.grpc_port);
    windows_hcs.closeSocket(readiness_socket);

    const address = std.Io.net.IpAddress.parseLiteral(listen_address) catch return error.InvalidListenAddress;
    const ip4 = switch (address) {
        .ip4 => |value| value,
        .ip6 => return error.InvalidListenAddress,
    };
    const listener = try windows_hcs.listenTcp(ip4);
    defer windows_hcs.closeSocket(listener);

    std.log.info("windows-actiond gRPC bridge listening on {s} -> Hyper-V socket port {d}", .{ listen_address, vsock.grpc_port });
    while (true) {
        const client = windows_hcs.acceptSocket(listener) catch |err| {
            std.log.err("gRPC bridge accept failed: {s}", .{@errorName(err)});
            io.sleep(.fromMilliseconds(10), .awake) catch {};
            continue;
        };
        windows_hcs.setTcpNoDelay(client);
        const thread = std.Thread.spawn(.{}, connectionTask, .{ io, machine, client }) catch |err| {
            windows_hcs.closeSocket(client);
            std.log.err("gRPC bridge connection task failed: {s}", .{@errorName(err)});
            continue;
        };
        thread.detach();
    }
}

fn connectionTask(io: std.Io, machine: *windows_hcs.Machine, client: windows_hcs.Socket) void {
    defer windows_hcs.closeSocket(client);

    const guest = machine.connectPort(io, vsock.grpc_port) catch |err| {
        std.log.err("Hyper-V socket connect failed: {s}", .{@errorName(err)});
        return;
    };
    defer windows_hcs.closeSocket(guest);

    const client_to_guest = std.Thread.spawn(.{}, pump, .{ client, guest }) catch |err| {
        std.log.err("gRPC bridge client-to-guest task failed: {s}", .{@errorName(err)});
        return;
    };
    pump(guest, client);
    client_to_guest.join();
}

fn pump(source: windows_hcs.Socket, destination: windows_hcs.Socket) void {
    var buffer: [pump_buffer_len]u8 = undefined;
    var failed = false;
    while (true) {
        const count = windows_hcs.recvBytes(source, &buffer) catch {
            failed = true;
            break;
        };
        if (count == 0) break;
        windows_hcs.sendAll(destination, buffer[0..count]) catch {
            failed = true;
            break;
        };
    }
    if (failed) {
        windows_hcs.shutdownBoth(source);
        windows_hcs.shutdownBoth(destination);
    } else {
        windows_hcs.shutdownSend(destination);
    }
}
