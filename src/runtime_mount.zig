const builtin = @import("builtin");
const std = @import("std");

pub const Error = error{
    InvalidRuntimeOptions,
    LoopDeviceUnavailable,
    LoopDeviceBusy,
    MountFailed,
    UnsupportedHost,
};

const loop_set_fd: u32 = 0x4C00;
const loop_clr_fd: u32 = 0x4C01;
const loop_set_status64: u32 = 0x4C04;
const loop_ctl_get_free: u32 = 0x4C82;
const loop_flags_read_only: u32 = 1;
const loop_flags_autoclear: u32 = 4;
const max_loop_attach_attempts = 32;

const LoopInfo64 = extern struct {
    lo_device: u64 = 0,
    lo_inode: u64 = 0,
    lo_rdevice: u64 = 0,
    lo_offset: u64 = 0,
    lo_sizelimit: u64 = 0,
    lo_number: u32 = 0,
    lo_encrypt_type: u32 = 0,
    lo_encrypt_key_size: u32 = 0,
    lo_flags: u32 = 0,
    lo_file_name: [64]u8 = [_]u8{0} ** 64,
    lo_crypt_name: [64]u8 = [_]u8{0} ** 64,
    lo_encrypt_key: [32]u8 = [_]u8{0} ** 32,
    lo_init: [2]u64 = [_]u64{0} ** 2,
};

const AttachedLoop = struct {
    path: [:0]u8,
    fd: std.posix.fd_t,
};

pub const MountedRuntime = struct {
    root_path: ?[]u8 = null,
    mount_target_z: ?[:0]u8 = null,

    pub fn path(self: MountedRuntime) ?[]const u8 {
        return self.root_path;
    }

    pub fn deinit(self: *MountedRuntime, allocator: std.mem.Allocator) void {
        if (self.mount_target_z) |target| {
            if (comptime builtin.os.tag == .linux) {
                _ = std.os.linux.umount2(target.ptr, std.os.linux.MNT.DETACH);
            }
            allocator.free(target);
        }
        if (self.root_path) |path_value| allocator.free(path_value);
        self.* = .{};
    }
};

pub fn prepare(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    runtime_image: ?[]const u8,
    runtime_root: ?[]const u8,
) !MountedRuntime {
    if (runtime_image != null and runtime_root != null) return error.InvalidRuntimeOptions;
    if (runtime_root) |path_value| {
        return .{ .root_path = try allocator.dupe(u8, path_value) };
    }
    const image = runtime_image orelse return .{};
    return mountSquashfs(io, allocator, root_dir, image);
}

fn mountSquashfs(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    image_path: []const u8,
) !MountedRuntime {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    try root_dir.createDirPath(io, "runtimes");
    var runtimes_dir = try root_dir.openDir(io, "runtimes", .{});
    defer runtimes_dir.close(io);

    var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target_len = try runtimes_dir.realPath(io, &target_buffer);
    const target_path = target_buffer[0..target_len];
    const target_z = try allocator.dupeZ(u8, target_path);
    errdefer allocator.free(target_z);

    const loop_device = try attachLoopReadOnly(allocator, image_path);
    defer closeFd(loop_device.fd);
    defer allocator.free(loop_device.path);

    const fstype: [:0]const u8 = "squashfs";
    const rc = std.os.linux.mount(
        loop_device.path.ptr,
        target_z.ptr,
        fstype.ptr,
        std.os.linux.MS.RDONLY | std.os.linux.MS.NOSUID | std.os.linux.MS.NODEV,
        0,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => {
            clearLoopFd(loop_device.fd);
            return error.MountFailed;
        },
    }

    return .{
        .root_path = try allocator.dupe(u8, target_path),
        .mount_target_z = target_z,
    };
}

fn attachLoopReadOnly(allocator: std.mem.Allocator, image_path: []const u8) !AttachedLoop {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const image_z = try allocator.dupeZ(u8, image_path);
    defer allocator.free(image_z);

    const backing_rc = std.os.linux.open(image_z.ptr, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    switch (std.posix.errno(backing_rc)) {
        .SUCCESS => {},
        else => return error.FileNotFound,
    }
    const backing_fd: std.posix.fd_t = @intCast(backing_rc);
    defer closeFd(backing_fd);

    const control_path: [:0]const u8 = "/dev/loop-control";
    const control_rc = std.os.linux.open(control_path.ptr, .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    }, 0);
    switch (std.posix.errno(control_rc)) {
        .SUCCESS => {},
        else => return error.LoopDeviceUnavailable,
    }
    const control_fd: std.posix.fd_t = @intCast(control_rc);
    defer closeFd(control_fd);

    var last_busy = false;
    var attempts: usize = 0;
    while (attempts < max_loop_attach_attempts) : (attempts += 1) {
        const number_rc = std.os.linux.ioctl(control_fd, loop_ctl_get_free, 0);
        switch (std.posix.errno(number_rc)) {
            .SUCCESS => {},
            else => return error.LoopDeviceUnavailable,
        }

        const loop_path = try std.fmt.allocPrintSentinel(allocator, "/dev/loop{d}", .{number_rc}, 0);
        errdefer allocator.free(loop_path);

        const loop_rc = std.os.linux.open(loop_path.ptr, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
        }, 0);
        switch (std.posix.errno(loop_rc)) {
            .SUCCESS => {},
            .BUSY => {
                allocator.free(loop_path);
                last_busy = true;
                continue;
            },
            else => {
                allocator.free(loop_path);
                return error.LoopDeviceUnavailable;
            },
        }
        const loop_fd: std.posix.fd_t = @intCast(loop_rc);
        errdefer closeFd(loop_fd);

        const set_fd_rc = std.os.linux.ioctl(loop_fd, loop_set_fd, @intCast(backing_fd));
        switch (std.posix.errno(set_fd_rc)) {
            .SUCCESS => {},
            .BUSY => {
                closeFd(loop_fd);
                allocator.free(loop_path);
                last_busy = true;
                continue;
            },
            else => {
                allocator.free(loop_path);
                return error.LoopDeviceUnavailable;
            },
        }

        var info: LoopInfo64 = .{};
        info.lo_flags = loop_flags_read_only | loop_flags_autoclear;
        const copy_len = @min(image_path.len, info.lo_file_name.len - 1);
        @memcpy(info.lo_file_name[0..copy_len], image_path[0..copy_len]);

        const status_rc = std.os.linux.ioctl(loop_fd, loop_set_status64, @intFromPtr(&info));
        switch (std.posix.errno(status_rc)) {
            .SUCCESS => {},
            else => {
                clearLoopFd(loop_fd);
                allocator.free(loop_path);
                return error.LoopDeviceUnavailable;
            },
        }

        return .{
            .path = loop_path,
            .fd = loop_fd,
        };
    }

    return if (last_busy) error.LoopDeviceBusy else error.LoopDeviceUnavailable;
}

fn clearLoopFd(loop_fd: std.posix.fd_t) void {
    if (comptime builtin.os.tag != .linux) return;
    _ = std.os.linux.ioctl(loop_fd, loop_clr_fd, 0);
}

fn closeFd(fd: std.posix.fd_t) void {
    if (comptime builtin.os.tag != .linux) return;
    while (true) switch (std.posix.errno(std.os.linux.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

test "prepare rejects conflicting runtime sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.InvalidRuntimeOptions, prepare(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        "/tmp/runtimes.sqfs",
        "/mnt/runtimes",
    ));
}

test "prepare accepts an already-mounted runtime root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mounted = try prepare(
        std.testing.io,
        std.testing.allocator,
        tmp.dir,
        null,
        "/mnt/actiond-runtimes",
    );
    defer mounted.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/mnt/actiond-runtimes", mounted.path().?);
    try std.testing.expectEqual(@as(?[:0]u8, null), mounted.mount_target_z);
}
