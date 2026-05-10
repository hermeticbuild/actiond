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
};

pub const mounts = [_]Mount{
    .{ .source = "proc", .target = "/proc", .fstype = "proc" },
    .{ .source = "sysfs", .target = "/sys", .fstype = "sysfs" },
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

pub const cas_mount: Mount = .{ .source = "cas", .target = "/cas", .fstype = "virtiofs" };
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
    try mount(stderr, cas_mount);
    try stderr.writeAll("linux-actiond guest init mounted filesystems; starting worker\n");
    try stderr.flush();

    return std.process.replace(io, .{ .argv = &worker_argv });
}

fn mount(stderr: *std.Io.Writer, mount_spec: Mount) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const rc = std.os.linux.mount(
        mount_spec.source.ptr,
        mount_spec.target.ptr,
        mount_spec.fstype.ptr,
        0,
        0,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |errno| {
            try stderr.print("mount {s} on {s} type {s} failed: {s}\n", .{
                mount_spec.source,
                mount_spec.target,
                mount_spec.fstype,
                @tagName(errno),
            });
            try stderr.flush();
            return error.MountFailed;
        },
    }
}

fn loadOptionalModule(stderr: *std.Io.Writer, path: [:0]const u8) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const linux = std.os.linux;
    const open_rc = linux.open(path.ptr, .{ .CLOEXEC = true }, 0);
    switch (std.posix.errno(open_rc)) {
        .SUCCESS => {},
        .NOENT => return,
        else => |errno| {
            try stderr.print("open module {s} failed: {s}\n", .{ path, @tagName(errno) });
            try stderr.flush();
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
            try stderr.print("load module {s} failed: {s}\n", .{ path, @tagName(errno) });
            try stderr.flush();
            return error.ModuleLoadFailed;
        },
    }
}

test "guest init mount plan stays minimal" {
    try std.testing.expectEqual(@as(usize, 5), mounts.len);
    try std.testing.expectEqualStrings("virtiofs", cas_mount.fstype);
    try std.testing.expectEqualStrings("/cas", cas_mount.target);
    try std.testing.expectEqual(@as(usize, 4), module_paths.len);
    try std.testing.expectEqualStrings("/actiond", worker_argv[0]);
    try std.testing.expectEqualStrings("--guest-worker", worker_argv[1]);

    for (mounts) |mount_spec| {
        try std.testing.expect(!std.mem.eql(u8, mount_spec.fstype, "nfs"));
        try std.testing.expect(!std.mem.eql(u8, mount_spec.fstype, "cifs"));
    }
}
