const builtin = @import("builtin");
const std = @import("std");
const control_transport_fd = @import("control_transport_fd.zig");
const vsock = @import("vsock.zig");

const linux = std.os.linux;
const fexec_qemu_argument = "--actiond-internal-fexec-qemu";
const mfd_exec = 0x0010;

pub const Error = error{
    ConnectFailed,
    ConnectTimedOut,
    FexecFailed,
    StartFailed,
    UnsupportedHost,
};

pub const Options = struct {
    kernel_path: []const u8,
    initramfs_path: []const u8,
    runtime_image_path: []const u8,
    cas_image_path: []const u8,
    qemu_data_path: []const u8,
    format_cas_image: bool = false,
    memory_mib: u64 = 512,
    cpu_count: u32 = 2,
    start_timeout_ms: u32 = 30_000,
    connect_timeout_ms: u32 = 60_000,
    connect_attempt_timeout_ms: u32 = 1_000,
    guest_cid: ?u32 = null,
};

pub const Machine = struct {
    child: std.process.Child,
    io: std.Io,
    guest_cid: u32,
    connect_timeout_ms: u32,
    connect_attempt_timeout_ms: u32,

    pub fn start(io: std.Io, allocator: std.mem.Allocator, options: Options) !Machine {
        if (comptime builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
            return error.UnsupportedHost;
        }

        const guest_cid = options.guest_cid orelse try randomGuestCid(io);
        const memory = try std.fmt.allocPrint(allocator, "{d}M", .{options.memory_mib});
        defer allocator.free(memory);
        const cpus = try std.fmt.allocPrint(allocator, "{d}", .{options.cpu_count});
        defer allocator.free(cpus);
        const vsock_device = try std.fmt.allocPrint(allocator, "vhost-vsock-pci,id=vsock0,guest-cid={d}", .{guest_cid});
        defer allocator.free(vsock_device);
        const cas_drive = try driveArg(allocator, "cas", options.cas_image_path, false);
        defer allocator.free(cas_drive);
        const runtime_drive = try driveArg(allocator, "runtimes", options.runtime_image_path, true);
        defer allocator.free(runtime_drive);
        const kernel_append = try kernelAppendArg(allocator, options.format_cas_image);
        defer allocator.free(kernel_append);

        // TODO: Use KVM after the rules_qemu QEMU prebuilt is verified with
        // /dev/kvm on the Linux runner.
        const argv = [_][]const u8{
            "/proc/self/exe",
            fexec_qemu_argument,
            "qemu-system-x86_64",
            "-machine",
            "q35,accel=tcg",
            "-cpu",
            "max",
            "-L",
            options.qemu_data_path,
            "-smp",
            cpus,
            "-m",
            memory,
            "-no-user-config",
            "-nodefaults",
            "-display",
            "none",
            "-monitor",
            "none",
            "-no-reboot",
            "-serial",
            "stdio",
            "-kernel",
            options.kernel_path,
            "-initrd",
            options.initramfs_path,
            "-append",
            kernel_append,
            "-device",
            vsock_device,
            "-drive",
            cas_drive,
            "-device",
            "virtio-blk-pci,drive=cas",
            "-drive",
            runtime_drive,
            "-device",
            "virtio-blk-pci,drive=runtimes",
        };

        std.log.info("starting embedded qemu-system-x86_64 guest_cid={d}", .{guest_cid});
        var child = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        errdefer child.kill(io);

        var machine: Machine = .{
            .child = child,
            .io = io,
            .guest_cid = guest_cid,
            .connect_timeout_ms = options.connect_timeout_ms,
            .connect_attempt_timeout_ms = options.connect_attempt_timeout_ms,
        };
        machine.waitForControlPort(options.start_timeout_ms) catch |err| {
            machine.deinit();
            return err;
        };
        return machine;
    }

    pub fn deinit(self: *Machine) void {
        self.child.kill(self.io);
        self.* = undefined;
    }

    pub fn opener(self: *Machine) control_transport_fd.Opener {
        return .{ .ctx = self, .open = open };
    }

    fn open(ctx: *anyopaque) !std.posix.fd_t {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        return self.connectControlPort(vsock.control_port);
    }

    pub fn connectControlPort(self: *Machine, port: u32) !std.posix.fd_t {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

        var remaining_ms = if (self.connect_timeout_ms == 0)
            self.connect_attempt_timeout_ms
        else
            self.connect_timeout_ms;
        while (true) {
            if (connectVsock(self.guest_cid, port)) |fd| return fd else |err| {
                if (try self.reapExitedChild()) |status| {
                    std.log.err("QEMU exited before guest vsock became ready status=0x{x}", .{status});
                    return error.StartFailed;
                }
                if (remaining_ms <= self.connect_attempt_timeout_ms) {
                    std.log.err("timed out connecting to guest cid={d} vsock:{d}: {s}", .{ self.guest_cid, port, @errorName(err) });
                    return error.ConnectTimedOut;
                }
            }
            const sleep_ms = @min(@as(u32, 100), remaining_ms);
            try self.io.sleep(.fromMilliseconds(sleep_ms), .awake);
            remaining_ms -= sleep_ms;
        }
    }

    fn waitForControlPort(self: *Machine, timeout_ms: u32) !void {
        const saved_timeout = self.connect_timeout_ms;
        self.connect_timeout_ms = timeout_ms;
        defer self.connect_timeout_ms = saved_timeout;

        const fd = try self.connectControlPort(vsock.control_port);
        closeFd(fd);
    }

    fn reapExitedChild(self: *Machine) !?u32 {
        const pid = self.child.id orelse return 0;
        while (true) {
            var status: u32 = undefined;
            const result = linux.waitpid(pid, &status, linux.W.NOHANG);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return null;
                    self.child.id = null;
                    return status;
                },
                .INTR => continue,
                .CHILD => {
                    self.child.id = null;
                    return 0;
                },
                else => return error.StartFailed,
            }
        }
    }
};

pub fn fexecEmbedded(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    executable: []const u8,
    args: []const [:0]const u8,
) !noreturn {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

    const parent_pid = linux.getppid();
    const parent_death_result = linux.prctl(
        @intFromEnum(linux.PR.SET_PDEATHSIG),
        @intFromEnum(linux.SIG.KILL),
        0,
        0,
        0,
    );
    if (linux.errno(parent_death_result) != .SUCCESS) return error.FexecFailed;
    if (linux.getppid() != parent_pid) return error.ParentExited;

    const memfd_flags = linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING;
    const fd = std.posix.memfd_create("actiond-qemu", memfd_flags | mfd_exec) catch |err| switch (err) {
        // Linux added MFD_EXEC in 6.3. The fixed name is shorter than NAME_MAX,
        // so NameTooLong here means the kernel rejected MFD_EXEC.
        error.NameTooLong => try std.posix.memfd_create("actiond-qemu", memfd_flags),
        else => return err,
    };
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    try file.writePositionalAll(io, executable, 0);
    try file.setPermissions(io, .executable_file);

    const seals = linux.F.SEAL_SEAL | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE;
    const seal_result = linux.fcntl(fd, linux.F.ADD_SEALS, seals);
    if (linux.errno(seal_result) != .SUCCESS) return error.FexecFailed;

    const argv = try allocator.allocSentinel(?[*:0]const u8, args.len, null);
    for (args, argv) |arg, *entry| entry.* = arg.ptr;

    const environment = environ.block.view().slice;
    const envp = try allocator.allocSentinel(?[*:0]const u8, environment.len, null);
    for (environment, envp) |entry, *output| output.* = entry;

    const result = linux.execveat(fd, "", argv.ptr, envp.ptr, .{ .SYMLINK_NOFOLLOW = false, .EMPTY_PATH = true });
    std.log.err("execveat for embedded qemu-system-x86_64 failed: {s}", .{@tagName(linux.errno(result))});
    return error.FexecFailed;
}

fn driveArg(allocator: std.mem.Allocator, id: []const u8, path: []const u8, readonly: bool) ![]u8 {
    const readonly_arg = if (readonly) ",readonly=on" else "";
    const escaped_path = try escapeDriveValue(allocator, path);
    defer allocator.free(escaped_path);
    // TODO: Add aio=io_uring after the rules_qemu QEMU prebuilt and Linux
    // runner are verified with io_uring.
    return std.fmt.allocPrint(allocator, "if=none,id={s},file={s},format=raw{s},cache=none", .{
        id,
        escaped_path,
        readonly_arg,
    });
}

fn escapeDriveValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const escaped = try allocator.alloc(u8, value.len + std.mem.count(u8, value, ","));
    var output_index: usize = 0;
    for (value) |byte| {
        escaped[output_index] = byte;
        output_index += 1;
        if (byte == ',') {
            escaped[output_index] = ',';
            output_index += 1;
        }
    }
    return escaped;
}

fn randomGuestCid(io: std.Io) !u32 {
    var random: u32 = undefined;
    try io.randomSecure(std.mem.asBytes(&random));
    return 3 + random % (std.math.maxInt(u32) - 3);
}

fn kernelAppendArg(allocator: std.mem.Allocator, format_cas_image: bool) ![]u8 {
    return allocator.dupe(u8, if (format_cas_image)
        "init=/init console=ttyS0 panic=-1 actiond.cas_device=/dev/vda actiond.format_cas=1"
    else
        "init=/init console=ttyS0 panic=-1 actiond.cas_device=/dev/vda");
}

fn connectVsock(cid: u32, port: u32) !std.posix.fd_t {
    const socket_result = linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket_result) != .SUCCESS) return error.ConnectFailed;
    const fd: std.posix.fd_t = @intCast(socket_result);
    errdefer closeFd(fd);

    var address: linux.sockaddr.vm = .{
        .family = linux.AF.VSOCK,
        .reserved1 = 0,
        .port = port,
        .cid = cid,
        .flags = 0,
        .zero = [_]u8{0} ** 3,
    };
    const connect_result = linux.connect(
        fd,
        @ptrCast(&address),
        @sizeOf(linux.sockaddr.vm),
    );
    if (linux.errno(connect_result) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (linux.errno(linux.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

test "driveArg leaves io_uring disabled" {
    const drive = try driveArg(std.testing.allocator, "cas", "/tmp/cas.ext4", false);
    defer std.testing.allocator.free(drive);
    try std.testing.expectEqualStrings("if=none,id=cas,file=/tmp/cas.ext4,format=raw,cache=none", drive);
}

test "driveArg escapes commas in paths" {
    const drive = try driveArg(std.testing.allocator, "cas", "/tmp/actiond,vm/cas.ext4", false);
    defer std.testing.allocator.free(drive);
    try std.testing.expectEqualStrings("if=none,id=cas,file=/tmp/actiond,,vm/cas.ext4,format=raw,cache=none", drive);
}

test "kernelAppendArg identifies the CAS block device" {
    const argument = try kernelAppendArg(std.testing.allocator, true);
    defer std.testing.allocator.free(argument);
    try std.testing.expectEqualStrings(
        "init=/init console=ttyS0 panic=-1 actiond.cas_device=/dev/vda actiond.format_cas=1",
        argument,
    );
}
