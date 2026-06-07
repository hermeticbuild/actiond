const builtin = @import("builtin");
const std = @import("std");

pub const Error = error{
    MountFailed,
    UnsupportedHost,
};

pub const Mount = struct {
    source: [:0]const u8,
    target: [:0]const u8,
    fstype: [:0]const u8,
    flags: u32 = 0,
    data: ?[:0]const u8 = null,
};

pub const mounts = [_]Mount{
    .{ .source = "proc", .target = "/proc", .fstype = "proc" },
    .{ .source = "sysfs", .target = "/sys", .fstype = "sysfs" },
    .{ .source = "cgroup2", .target = "/sys/fs/cgroup", .fstype = "cgroup2" },
    .{ .source = "devtmpfs", .target = "/dev", .fstype = "devtmpfs" },
    .{ .source = "tmpfs", .target = "/tmp", .fstype = "tmpfs" },
    .{ .source = "tmpfs", .target = "/work", .fstype = "tmpfs" },
};

pub const block_devices = [_][:0]const u8{
    "/dev/vda",
    "/dev/vdb",
    "/dev/vdc",
    "/dev/vdd",
    "/dev/sda",
    "/dev/sdb",
    "/dev/nvme0n1",
};
const runtime_device_wait_attempts = 50;
const runtime_device_wait_ns = 100 * std.time.ns_per_ms;
pub const runtimes_mount_target: [:0]const u8 = "/runtimes";
pub const cas_mount_target: [:0]const u8 = "/cas";
pub const cas_mount_fstype: [:0]const u8 = "ext4";
pub const cas_format_cmdline_token = "actiond.format_cas=1";
pub const cas_mkfs_path = "/sbin/mkfs.ext4";
pub const cas_format_device = block_devices[0];
const cas_mount_flags = std.os.linux.MS.NOSUID |
    std.os.linux.MS.NODEV |
    std.os.linux.MS.NOATIME |
    std.os.linux.MS.LAZYTIME;
pub const worker_argv = [_][]const u8{ "/actiond", "--guest-worker" };

const CasMountAttempt = enum {
    mounted,
    unavailable,
    rejected,
};

pub fn run(io: std.Io) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;

    for (mounts) |mount_spec| {
        try mount(stderr, mount_spec);
    }
    try mountCasStore(io, stderr, readCasFormatFlag(io));
    try mountRuntimeImage(io, stderr);
    stderr.writeAll("linux-actiond guest init mounted filesystems; starting worker\n") catch {};
    stderr.flush() catch {};

    return std.process.replace(io, .{ .argv = &worker_argv });
}

fn mountCasStore(io: std.Io, stderr: *std.Io.Writer, format_if_needed: bool) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    for (0..runtime_device_wait_attempts) |_| {
        if (format_if_needed) {
            switch (try tryMountCasDevice(stderr, cas_format_device)) {
                .mounted => return,
                .unavailable => {},
                .rejected => {
                    try formatCasDevice(io, stderr, cas_format_device);
                    if (try tryMountCasDevice(stderr, cas_format_device) == .mounted) return;
                    stderr.print("formatted CAS block device {s} did not mount as ext4\n", .{cas_format_device}) catch {};
                    stderr.flush() catch {};
                    return error.MountFailed;
                },
            }
        } else if (try mountFirstCasDevice(io, stderr)) return;
        sleepRuntimeDevicePollInterval();
    }

    stderr.writeAll("CAS block device not found or not formatted as ext4\n") catch {};
    stderr.flush() catch {};
    return error.MountFailed;
}

fn mountRuntimeImage(io: std.Io, stderr: *std.Io.Writer) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    for (0..runtime_device_wait_attempts) |_| {
        if (try mountFirstRuntimeDevice(io, stderr)) return;
        sleepRuntimeDevicePollInterval();
    }

    stderr.writeAll("runtime block device not found\n") catch {};
    stderr.flush() catch {};
    return error.MountFailed;
}

fn mountFirstRuntimeDevice(io: std.Io, stderr: *std.Io.Writer) !bool {
    for (block_devices) |device| {
        if (try tryMountRuntimeDevice(stderr, device)) return true;
    }
    return try mountSysBlockRuntimeDevice(io, stderr);
}

fn mountFirstCasDevice(io: std.Io, stderr: *std.Io.Writer) !bool {
    for (block_devices) |device| {
        if (try tryMountCasDevice(stderr, device) == .mounted) return true;
    }
    return try mountSysBlockCasDevice(io, stderr);
}

fn mountSysBlockRuntimeDevice(io: std.Io, stderr: *std.Io.Writer) !bool {
    var sys_block = std.Io.Dir.cwd().openDir(io, "/sys/block", .{ .iterate = true }) catch return false;
    defer sys_block.close(io);

    var it = sys_block.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!isCandidateBlockDevice(entry.name)) continue;

        var device_buffer: [128]u8 = undefined;
        const device = std.fmt.bufPrintZ(&device_buffer, "/dev/{s}", .{entry.name}) catch continue;
        if (try tryMountRuntimeDevice(stderr, device)) return true;
    }
    return false;
}

fn mountSysBlockCasDevice(io: std.Io, stderr: *std.Io.Writer) !bool {
    var sys_block = std.Io.Dir.cwd().openDir(io, "/sys/block", .{ .iterate = true }) catch return false;
    defer sys_block.close(io);

    var it = sys_block.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!isCandidateBlockDevice(entry.name)) continue;

        var device_buffer: [128]u8 = undefined;
        const device = std.fmt.bufPrintZ(&device_buffer, "/dev/{s}", .{entry.name}) catch continue;
        if (try tryMountCasDevice(stderr, device) == .mounted) return true;
    }
    return false;
}

fn isCandidateBlockDevice(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "vd") or
        std.mem.startsWith(u8, name, "sd") or
        std.mem.startsWith(u8, name, "nvme");
}

fn tryMountRuntimeDevice(stderr: *std.Io.Writer, device: [:0]const u8) !bool {
    const linux = std.os.linux;
    const fd_rc = linux.open(device.ptr, .{ .CLOEXEC = true }, 0);
    switch (std.posix.errno(fd_rc)) {
        .SUCCESS => _ = linux.close(@intCast(fd_rc)),
        .NOENT, .NXIO, .NODEV, .NOTBLK => return false,
        else => return false,
    }

    const rc = linux.mount(
        device.ptr,
        runtimes_mount_target.ptr,
        "squashfs",
        linux.MS.RDONLY | linux.MS.NOSUID | linux.MS.NODEV,
        0,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {
            stderr.print("mounted runtime image from {s}\n", .{device}) catch {};
            stderr.flush() catch {};
            return true;
        },
        .INVAL, .NODEV, .NXIO, .NOENT, .BUSY => return false,
        else => |errno| {
            stderr.print("mount runtime image {s} on {s} failed: {s}\n", .{
                device,
                runtimes_mount_target,
                @tagName(errno),
            }) catch {};
            stderr.flush() catch {};
            return error.MountFailed;
        },
    }
}

fn tryMountCasDevice(stderr: *std.Io.Writer, device: [:0]const u8) !CasMountAttempt {
    const linux = std.os.linux;
    const fd_rc = linux.open(device.ptr, .{ .CLOEXEC = true }, 0);
    switch (std.posix.errno(fd_rc)) {
        .SUCCESS => _ = linux.close(@intCast(fd_rc)),
        .NOENT, .NXIO, .NODEV, .NOTBLK => return .unavailable,
        else => return .unavailable,
    }

    const data: [:0]const u8 = "errors=remount-ro";
    const rc = linux.mount(
        device.ptr,
        cas_mount_target.ptr,
        cas_mount_fstype.ptr,
        cas_mount_flags,
        @intFromPtr(data.ptr),
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {
            stderr.print("mounted guest CAS from {s}\n", .{device}) catch {};
            stderr.flush() catch {};
            return .mounted;
        },
        .INVAL => return .rejected,
        .NODEV, .NXIO, .NOENT, .BUSY => return .unavailable,
        else => |errno| {
            stderr.print("mount guest CAS {s} on {s} failed: {s}\n", .{
                device,
                cas_mount_target,
                @tagName(errno),
            }) catch {};
            stderr.flush() catch {};
            return error.MountFailed;
        },
    }
}

fn formatCasDevice(io: std.Io, stderr: *std.Io.Writer, device: [:0]const u8) !void {
    const argv = [_][]const u8{ cas_mkfs_path, "-F", "-q", "-t", "ext4", device };

    stderr.print("formatting new guest CAS image on {s}\n", .{device}) catch {};
    stderr.flush() catch {};

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        stderr.print("spawn {s} failed: {s}\n", .{ cas_mkfs_path, @errorName(err) }) catch {};
        stderr.flush() catch {};
        return error.MountFailed;
    };
    errdefer child.kill(io);

    const term = child.wait(io) catch |err| {
        stderr.print("{s} wait failed: {s}\n", .{ cas_mkfs_path, @errorName(err) }) catch {};
        stderr.flush() catch {};
        return error.MountFailed;
    };
    switch (term) {
        .exited => |code| if (code == 0) return,
        .signal => |signal| {
            stderr.print("{s} terminated by signal {d}\n", .{ cas_mkfs_path, @intFromEnum(signal) }) catch {};
            stderr.flush() catch {};
            return error.MountFailed;
        },
        .stopped => |signal| {
            stderr.print("{s} stopped by signal {d}\n", .{ cas_mkfs_path, @intFromEnum(signal) }) catch {};
            stderr.flush() catch {};
            return error.MountFailed;
        },
        .unknown => |status| {
            stderr.print("{s} exited with unknown status {d}\n", .{ cas_mkfs_path, status }) catch {};
            stderr.flush() catch {};
            return error.MountFailed;
        },
    }

    stderr.print("{s} exited unsuccessfully\n", .{cas_mkfs_path}) catch {};
    stderr.flush() catch {};
    return error.MountFailed;
}

fn readCasFormatFlag(io: std.Io) bool {
    var buffer: [4096]u8 = undefined;
    const cmdline = std.Io.Dir.cwd().readFile(io, "/proc/cmdline", &buffer) catch return false;
    return cmdlineRequestsCasFormat(cmdline);
}

fn cmdlineRequestsCasFormat(cmdline: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, cmdline, ' ');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (std.mem.eql(u8, token, cas_format_cmdline_token)) return true;
    }
    return false;
}

fn sleepRuntimeDevicePollInterval() void {
    var request: std.os.linux.timespec = .{
        .sec = 0,
        .nsec = runtime_device_wait_ns,
    };
    while (std.posix.errno(std.os.linux.nanosleep(&request, &request)) == .INTR) {}
}

fn mount(stderr: *std.Io.Writer, mount_spec: Mount) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const rc = std.os.linux.mount(
        mount_spec.source.ptr,
        mount_spec.target.ptr,
        mount_spec.fstype.ptr,
        mount_spec.flags,
        if (mount_spec.data) |data| @intFromPtr(data.ptr) else 0,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |errno| {
            stderr.print("mount {s} on {s} type {s} failed: {s}\n", .{
                mount_spec.source,
                mount_spec.target,
                mount_spec.fstype,
                @tagName(errno),
            }) catch {};
            stderr.flush() catch {};
            return error.MountFailed;
        },
    }
}

test "guest init mount plan stays minimal" {
    try std.testing.expectEqual(@as(usize, 6), mounts.len);
    try std.testing.expectEqualStrings("ext4", cas_mount_fstype);
    try std.testing.expectEqualStrings("/cas", cas_mount_target);
    try std.testing.expectEqualStrings("actiond.format_cas=1", cas_format_cmdline_token);
    try std.testing.expectEqualStrings("/sbin/mkfs.ext4", cas_mkfs_path);
    try std.testing.expectEqualStrings("/dev/vda", cas_format_device);
    try std.testing.expect((cas_mount_flags & std.os.linux.MS.NOSUID) != 0);
    try std.testing.expect((cas_mount_flags & std.os.linux.MS.NODEV) != 0);
    try std.testing.expect((cas_mount_flags & std.os.linux.MS.NOATIME) != 0);
    try std.testing.expect((cas_mount_flags & std.os.linux.MS.LAZYTIME) != 0);
    try std.testing.expectEqualStrings("/actiond", worker_argv[0]);
    try std.testing.expectEqualStrings("--guest-worker", worker_argv[1]);

    for (mounts) |mount_spec| {
        try std.testing.expect(!std.mem.eql(u8, mount_spec.fstype, "nfs"));
        try std.testing.expect(!std.mem.eql(u8, mount_spec.fstype, "cifs"));
    }
}

test "guest init parses CAS format kernel flag as a token" {
    try std.testing.expect(cmdlineRequestsCasFormat("console=hvc0 actiond.format_cas=1 quiet\n"));
    try std.testing.expect(cmdlineRequestsCasFormat("actiond.format_cas=1"));
    try std.testing.expect(!cmdlineRequestsCasFormat("console=hvc0 quiet"));
    try std.testing.expect(!cmdlineRequestsCasFormat("fooactiond.format_cas=1"));
    try std.testing.expect(!cmdlineRequestsCasFormat("actiond.format_cas=0"));
}
