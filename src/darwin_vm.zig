const builtin = @import("builtin");
const std = @import("std");
const control_transport_fd = @import("control_transport_fd.zig");
const vsock = @import("vsock.zig");

pub const Error = error{
    ConnectFailed,
    ConnectTimedOut,
    StartFailed,
    UnsupportedHost,
};

pub const Options = struct {
    kernel_path: []const u8,
    initramfs_path: []const u8,
    cas_path: []const u8,
    memory_mib: u64 = 512,
    cpu_count: u32 = 2,
    start_timeout_ms: u32 = 30_000,
    connect_timeout_ms: u32 = 60_000,
    connect_attempt_timeout_ms: u32 = 1_000,
};

pub const Machine = struct {
    handle: *anyopaque,
    connect_timeout_ms: u32,
    connect_attempt_timeout_ms: u32,

    pub fn start(allocator: std.mem.Allocator, options: Options) !Machine {
        if (comptime builtin.os.tag != .macos) return error.UnsupportedHost;

        const kernel_path = try allocator.dupeZ(u8, options.kernel_path);
        defer allocator.free(kernel_path);
        const initramfs_path = try allocator.dupeZ(u8, options.initramfs_path);
        defer allocator.free(initramfs_path);
        const cas_path = try allocator.dupeZ(u8, options.cas_path);
        defer allocator.free(cas_path);

        var errbuf: [1024]u8 = [_]u8{0} ** 1024;
        const handle = actiond_vm_start(
            kernel_path.ptr,
            initramfs_path.ptr,
            cas_path.ptr,
            options.memory_mib,
            options.cpu_count,
            options.start_timeout_ms,
            &errbuf,
            errbuf.len,
        ) orelse {
            std.log.err("Virtualization.framework failed to start VM: {s}", .{errorMessage(&errbuf)});
            return error.StartFailed;
        };

        return .{
            .handle = handle,
            .connect_timeout_ms = options.connect_timeout_ms,
            .connect_attempt_timeout_ms = options.connect_attempt_timeout_ms,
        };
    }

    pub fn deinit(self: *Machine) void {
        if (comptime builtin.os.tag != .macos) return;
        actiond_vm_stop(self.handle);
        actiond_vm_release(self.handle);
        self.* = undefined;
    }

    pub fn opener(self: *Machine) control_transport_fd.Opener {
        return .{
            .ctx = self,
            .open = open,
        };
    }

    fn open(ctx: *anyopaque) !std.posix.fd_t {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        return self.connectControlPort(vsock.control_port);
    }

    pub fn connectControlPort(self: *Machine, port: u32) !std.posix.fd_t {
        if (comptime builtin.os.tag != .macos) return error.UnsupportedHost;

        var remaining_ms = if (self.connect_timeout_ms == 0)
            self.connect_attempt_timeout_ms
        else
            self.connect_timeout_ms;
        var last_error: [1024]u8 = [_]u8{0} ** 1024;

        while (true) {
            var errbuf: [1024]u8 = [_]u8{0} ** 1024;
            const attempt_timeout_ms = @min(self.connect_attempt_timeout_ms, remaining_ms);
            const fd = actiond_vm_connect(
                self.handle,
                port,
                attempt_timeout_ms,
                &errbuf,
                errbuf.len,
            );
            if (fd >= 0) return @intCast(fd);

            @memcpy(last_error[0..], errbuf[0..]);
            if (remaining_ms <= attempt_timeout_ms) {
                std.log.err("timed out connecting to guest vsock:{d}: {s}", .{ port, errorMessage(&last_error) });
                return error.ConnectTimedOut;
            }
            remaining_ms -= attempt_timeout_ms;

            const sleep_ms = @min(@as(u32, 100), remaining_ms);
            sleepMilliseconds(sleep_ms);
            remaining_ms -= sleep_ms;
        }
    }
};

fn sleepMilliseconds(milliseconds: u32) void {
    var request: std.c.timespec = .{
        .sec = @intCast(milliseconds / std.time.ms_per_s),
        .nsec = @intCast((milliseconds % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    while (std.c.nanosleep(&request, &request) != 0) {}
}

fn errorMessage(buffer: *const [1024]u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}

extern fn actiond_vm_start(
    kernel_path: [*:0]const u8,
    initramfs_path: [*:0]const u8,
    cas_path: [*:0]const u8,
    memory_mib: u64,
    cpu_count: u32,
    start_timeout_ms: u32,
    errbuf: [*]u8,
    errbuf_len: usize,
) ?*anyopaque;

extern fn actiond_vm_connect(
    handle: *anyopaque,
    port: u32,
    timeout_ms: u32,
    errbuf: [*]u8,
    errbuf_len: usize,
) c_int;

extern fn actiond_vm_stop(handle: *anyopaque) void;
extern fn actiond_vm_release(handle: *anyopaque) void;

test "darwin VM start is macOS-only" {
    if (comptime builtin.os.tag != .macos) {
        try std.testing.expectError(error.UnsupportedHost, Machine.start(std.testing.allocator, .{
            .kernel_path = "/kernel",
            .initramfs_path = "/initramfs",
            .cas_path = "/cas",
        }));
    }
}
