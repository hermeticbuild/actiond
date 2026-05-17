const builtin = @import("builtin");
const std = @import("std");

pub const Error = error{
    ModuleLoadFailed,
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

pub const module_paths = [_][:0]const u8{
    "/modules/vsock.ko",
    "/modules/vmw_vsock_virtio_transport_common.ko",
    "/modules/vmw_vsock_virtio_transport.ko",
    "/modules/virtiofs.ko",
};

pub const host_cas_mount: Mount = .{ .source = "cas", .target = "/host-cas", .fstype = "virtiofs", .flags = std.os.linux.MS.RDONLY };
pub const runtime_image_share_mount: Mount = .{ .source = "runtimes", .target = "/runtime-image", .fstype = "virtiofs", .flags = std.os.linux.MS.RDONLY };
pub const runtime_image_share_path: [:0]const u8 = "/runtime-image/runtimes.sqfs";
pub const runtime_block_devices = [_][:0]const u8{
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
const loop_ctl_get_free: u32 = 0x4C82;
const loop_set_fd: u32 = 0x4C00;
const loop_major: u32 = 7;
const max_fixed_loop_devices = 8;
pub const runtimes_mount_target: [:0]const u8 = "/runtimes";
pub const cas_overlay_mount: Mount = .{
    .source = "overlay",
    .target = "/cas",
    .fstype = "overlay",
    .data = "lowerdir=/host-cas,upperdir=/work/cas-upper/upper,workdir=/work/cas-upper/work",
};
pub const worker_argv = [_][]const u8{ "/actiond", "--guest-worker" };

pub fn run(io: std.Io) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;

    for (mounts) |mount_spec| {
        try mount(stderr, mount_spec);
    }
    for (module_paths) |module_path| {
        try loadOptionalModule(stderr, module_path);
    }
    try ensureDir(io, "work/cas-upper/upper");
    try ensureDir(io, "work/cas-upper/work");
    try mount(stderr, host_cas_mount);
    try mount(stderr, cas_overlay_mount);
    try mountRuntimeImage(io, stderr);
    stderr.writeAll("linux-actiond guest init mounted filesystems; starting worker\n") catch {};
    stderr.flush() catch {};

    return std.process.replace(io, .{ .argv = &worker_argv });
}

fn mountRuntimeImage(io: std.Io, stderr: *std.Io.Writer) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    if (try mountRuntimeImageShare(stderr)) return;

    for (0..runtime_device_wait_attempts) |_| {
        if (try mountFirstRuntimeDevice(io, stderr)) return;
        sleepRuntimeDevicePollInterval();
    }

    stderr.writeAll("runtime block device not found\n") catch {};
    stderr.flush() catch {};
    return error.MountFailed;
}

fn mountRuntimeImageShare(stderr: *std.Io.Writer) !bool {
    if (!try tryMountVirtiofsRuntimeImageShare(stderr)) return false;
    return try mountLoopRuntimeImage(stderr, runtime_image_share_path);
}

fn tryMountVirtiofsRuntimeImageShare(stderr: *std.Io.Writer) !bool {
    const linux = std.os.linux;
    const rc = linux.mount(
        runtime_image_share_mount.source.ptr,
        runtime_image_share_mount.target.ptr,
        runtime_image_share_mount.fstype.ptr,
        runtime_image_share_mount.flags,
        0,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => return true,
        .NOENT, .NODEV, .INVAL => |errno| {
            stderr.print("runtime image virtiofs share not available: {s}\n", .{@tagName(errno)}) catch {};
            stderr.flush() catch {};
            return false;
        },
        else => |errno| {
            stderr.print("mount {s} on {s} type {s} failed: {s}\n", .{
                runtime_image_share_mount.source,
                runtime_image_share_mount.target,
                runtime_image_share_mount.fstype,
                @tagName(errno),
            }) catch {};
            stderr.flush() catch {};
            return error.MountFailed;
        },
    }
}

fn mountLoopRuntimeImage(stderr: *std.Io.Writer, image_path: [:0]const u8) !bool {
    const linux = std.os.linux;
    const image_rc = linux.open(image_path.ptr, .{ .CLOEXEC = true }, 0);
    switch (std.posix.errno(image_rc)) {
        .SUCCESS => {},
        else => |errno| {
            stderr.print("open runtime image {s} failed: {s}\n", .{ image_path, @tagName(errno) }) catch {};
            stderr.flush() catch {};
            return false;
        },
    }
    const image_fd: std.posix.fd_t = @intCast(image_rc);
    defer closeFd(image_fd);

    const control_rc = linux.open("/dev/loop-control", .{ .CLOEXEC = true }, 0);
    switch (std.posix.errno(control_rc)) {
        .SUCCESS => {},
        .NOENT, .NODEV => |errno| {
            stderr.print("loop control unavailable: {s}\n", .{@tagName(errno)}) catch {};
            stderr.flush() catch {};
            return try mountFixedLoopRuntimeImage(stderr, image_fd, image_path);
        },
        else => |errno| {
            stderr.print("open /dev/loop-control failed: {s}\n", .{@tagName(errno)}) catch {};
            stderr.flush() catch {};
            return error.MountFailed;
        },
    }
    const control_fd: std.posix.fd_t = @intCast(control_rc);
    defer closeFd(control_fd);

    const number_rc = linux.ioctl(control_fd, loop_ctl_get_free, 0);
    if (std.posix.errno(number_rc) != .SUCCESS) {
        stderr.print("LOOP_CTL_GET_FREE failed: {s}\n", .{@tagName(std.posix.errno(number_rc))}) catch {};
        stderr.flush() catch {};
        return try mountFixedLoopRuntimeImage(stderr, image_fd, image_path);
    }
    const loop_number: usize = @intCast(number_rc);

    var loop_path_buffer: [64]u8 = undefined;
    const loop_path = std.fmt.bufPrintZ(&loop_path_buffer, "/dev/loop{d}", .{loop_number}) catch return false;
    return try mountLoopDevice(stderr, loop_path, image_fd, image_path);
}

fn mountFixedLoopRuntimeImage(stderr: *std.Io.Writer, image_fd: std.posix.fd_t, image_path: [:0]const u8) !bool {
    for (0..max_fixed_loop_devices) |number| {
        var loop_path_buffer: [64]u8 = undefined;
        const loop_path = std.fmt.bufPrintZ(&loop_path_buffer, "/dev/loop{d}", .{number}) catch continue;
        ensureLoopNode(loop_path, @intCast(number));
        if (try mountLoopDevice(stderr, loop_path, image_fd, image_path)) return true;
    }
    return false;
}

fn mountLoopDevice(
    stderr: *std.Io.Writer,
    loop_path: [:0]const u8,
    image_fd: std.posix.fd_t,
    image_path: [:0]const u8,
) !bool {
    const linux = std.os.linux;
    const loop_rc = linux.open(loop_path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    switch (std.posix.errno(loop_rc)) {
        .SUCCESS => {},
        else => |errno| {
            stderr.print("open {s} failed: {s}\n", .{ loop_path, @tagName(errno) }) catch {};
            stderr.flush() catch {};
            return false;
        },
    }
    const loop_fd: std.posix.fd_t = @intCast(loop_rc);

    const set_fd_rc = linux.ioctl(loop_fd, loop_set_fd, @intCast(image_fd));
    if (std.posix.errno(set_fd_rc) != .SUCCESS) {
        stderr.print("LOOP_SET_FD failed for {s}: {s}\n", .{ loop_path, @tagName(std.posix.errno(set_fd_rc)) }) catch {};
        stderr.flush() catch {};
        closeFd(loop_fd);
        return false;
    }
    closeFd(loop_fd);

    try mount(stderr, .{
        .source = loop_path,
        .target = runtimes_mount_target,
        .fstype = "squashfs",
        .flags = linux.MS.RDONLY | linux.MS.NOSUID | linux.MS.NODEV,
    });
    stderr.print("mounted runtime image from {s} via {s}\n", .{ image_path, loop_path }) catch {};
    stderr.flush() catch {};
    return true;
}

fn ensureLoopNode(path: [:0]const u8, minor: u32) void {
    const linux = std.os.linux;
    const mode: u32 = linux.S.IFBLK | 0o660;
    const dev: u32 = (loop_major << 8) | minor;
    switch (std.posix.errno(linux.mknod(path.ptr, mode, dev))) {
        .SUCCESS, .EXIST => {},
        else => {},
    }
}

fn mountFirstRuntimeDevice(io: std.Io, stderr: *std.Io.Writer) !bool {
    for (runtime_block_devices) |device| {
        if (try tryMountRuntimeDevice(stderr, device)) return true;
    }
    return try mountSysBlockRuntimeDevice(io, stderr);
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
        .INVAL, .NODEV, .NXIO, .NOENT => return false,
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

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.os.linux.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
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

fn ensureDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

fn loadOptionalModule(stderr: *std.Io.Writer, path: [:0]const u8) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const linux = std.os.linux;
    const open_rc = linux.open(path.ptr, .{ .CLOEXEC = true }, 0);
    switch (std.posix.errno(open_rc)) {
        .SUCCESS => {},
        .NOENT => return,
        else => |errno| {
            stderr.print("open module {s} failed: {s}\n", .{ path, @tagName(errno) }) catch {};
            stderr.flush() catch {};
            return error.ModuleLoadFailed;
        },
    }

    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);
    const params: [:0]const u8 = "";
    const load_rc = linux.syscall3(.finit_module, @intCast(fd), @intFromPtr(params.ptr), 0);
    switch (std.posix.errno(load_rc)) {
        .SUCCESS, .EXIST => {},
        else => |errno| {
            stderr.print("load module {s} failed: {s}\n", .{ path, @tagName(errno) }) catch {};
            stderr.flush() catch {};
            return error.ModuleLoadFailed;
        },
    }
}

test "guest init mount plan stays minimal" {
    try std.testing.expectEqual(@as(usize, 6), mounts.len);
    try std.testing.expectEqualStrings("virtiofs", host_cas_mount.fstype);
    try std.testing.expectEqualStrings("/host-cas", host_cas_mount.target);
    try std.testing.expectEqual(std.os.linux.MS.RDONLY, host_cas_mount.flags);
    try std.testing.expectEqualStrings("overlay", cas_overlay_mount.fstype);
    try std.testing.expectEqualStrings("/cas", cas_overlay_mount.target);
    try std.testing.expect(cas_overlay_mount.data != null);
    try std.testing.expectEqual(@as(usize, 4), module_paths.len);
    try std.testing.expectEqualStrings("/actiond", worker_argv[0]);
    try std.testing.expectEqualStrings("--guest-worker", worker_argv[1]);

    for (mounts) |mount_spec| {
        try std.testing.expect(!std.mem.eql(u8, mount_spec.fstype, "nfs"));
        try std.testing.expect(!std.mem.eql(u8, mount_spec.fstype, "cifs"));
    }
}
