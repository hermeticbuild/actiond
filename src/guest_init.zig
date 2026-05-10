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
};

pub const mounts = [_]Mount{
    .{ .source = "proc", .target = "/proc", .fstype = "proc" },
    .{ .source = "sysfs", .target = "/sys", .fstype = "sysfs" },
    .{ .source = "devtmpfs", .target = "/dev", .fstype = "devtmpfs" },
    .{ .source = "tmpfs", .target = "/tmp", .fstype = "tmpfs" },
    .{ .source = "tmpfs", .target = "/work", .fstype = "tmpfs" },
    .{ .source = "cas", .target = "/cas", .fstype = "virtiofs" },
};

pub const worker_argv = [_][]const u8{ "/actiond", "--guest-worker" };

pub fn run(io: std.Io) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;

    for (mounts) |mount_spec| {
        try mount(mount_spec);
    }
    try stderr.writeAll("linux-actiond guest init mounted filesystems; starting worker\n");
    try stderr.flush();

    return std.process.replace(io, .{ .argv = &worker_argv });
}

fn mount(mount_spec: Mount) !void {
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
        else => return error.MountFailed,
    }
}

test "guest init mount plan stays minimal" {
    try std.testing.expectEqual(@as(usize, 6), mounts.len);
    try std.testing.expectEqualStrings("virtiofs", mounts[5].fstype);
    try std.testing.expectEqualStrings("/cas", mounts[5].target);
    try std.testing.expectEqualStrings("/actiond", worker_argv[0]);
    try std.testing.expectEqualStrings("--guest-worker", worker_argv[1]);

    for (mounts) |mount_spec| {
        try std.testing.expect(!std.mem.eql(u8, mount_spec.fstype, "nfs"));
        try std.testing.expect(!std.mem.eql(u8, mount_spec.fstype, "cifs"));
    }
}
