const builtin = @import("builtin");
const std = @import("std");
const control_transport_fd = @import("control_transport_fd.zig");
const vsock = @import("vsock.zig");

const linux = std.os.linux;
const mfd_exec = 0x0010;

pub const fexec_argument = "--actiond-internal-fexec-qemu";

pub const Options = struct {
    qemu_system_name: []const u8,
    accel: []const u8,
    machine: []const u8,
    target_arch: []const u8,
    kernel_path: []const u8,
    initramfs_path: []const u8,
    runtime_image_path: []const u8,
    cas_image_path: []const u8,
    qemu_data_path: ?[]const u8,
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
        if (comptime builtin.os.tag != .linux or (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64)) {
            return error.UnsupportedHost;
        }
        if (!std.mem.eql(u8, options.target_arch, @tagName(builtin.cpu.arch))) return error.UnsupportedHost;

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
        const kernel_append = try kernelAppendArg(allocator, options.target_arch, options.format_cas_image);
        defer allocator.free(kernel_append);
        const machine_option = try std.fmt.allocPrint(allocator, "{s},accel={s}", .{ options.machine, options.accel });
        defer allocator.free(machine_option);

        // TODO: Use KVM after the rules_qemu QEMU prebuilt is verified with
        // /dev/kvm on the Linux runner.
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{
            "/proc/self/exe",
            fexec_argument,
            options.qemu_system_name,
            "-machine",
            machine_option,
            "-cpu",
            "max",
        });
        if (options.qemu_data_path) |path| {
            try argv.appendSlice(allocator, &.{ "-L", path });
        }
        try argv.appendSlice(allocator, &.{
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
        });

        std.log.info("starting embedded {s} guest_cid={d}", .{ options.qemu_system_name, guest_cid });
        var child = try std.process.spawn(io, .{
            .argv = argv.items,
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

        const timeout_ms = if (self.connect_timeout_ms == 0)
            self.connect_attempt_timeout_ms
        else
            self.connect_timeout_ms;
        const started = std.Io.Clock.awake.now(self.io);
        while (true) {
            const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
            if (elapsed_ms >= @as(i64, timeout_ms)) return error.ConnectTimedOut;
            const remaining_ms: u32 = timeout_ms - @as(u32, @intCast(elapsed_ms));
            const attempt_timeout_ms = @min(self.connect_attempt_timeout_ms, remaining_ms);
            if (connectVsock(self.guest_cid, port, attempt_timeout_ms)) |fd| return fd else |err| {
                if (try self.reapExitedChild()) |status| {
                    std.log.err("QEMU exited before guest vsock became ready status=0x{x}", .{status});
                    return error.StartFailed;
                }
                const updated_elapsed_ms = started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
                if (updated_elapsed_ms >= @as(i64, timeout_ms)) {
                    std.log.err("timed out connecting to guest cid={d} vsock:{d}: {s}", .{ self.guest_cid, port, @errorName(err) });
                    return error.ConnectTimedOut;
                }
            }
            const before_sleep_ms = started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
            if (before_sleep_ms >= @as(i64, timeout_ms)) return error.ConnectTimedOut;
            const sleep_ms = @min(@as(u32, 100), timeout_ms - @as(u32, @intCast(before_sleep_ms)));
            try self.io.sleep(.fromMilliseconds(sleep_ms), .awake);
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
    std.log.err("execveat for embedded QEMU failed: {s}", .{@tagName(linux.errno(result))});
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

fn kernelAppendArg(allocator: std.mem.Allocator, target_arch: []const u8, format_cas_image: bool) ![]u8 {
    const console = if (std.mem.eql(u8, target_arch, "aarch64"))
        "ttyAMA0"
    else if (std.mem.eql(u8, target_arch, "x86_64"))
        "ttyS0"
    else
        return error.UnsupportedHost;
    return std.fmt.allocPrint(allocator, "init=/init console={s} panic=-1 actiond.cas_device=/dev/vda{s}", .{
        console,
        if (format_cas_image) " actiond.format_cas=1" else "",
    });
}

fn connectVsock(cid: u32, port: u32, timeout_ms: u32) !std.posix.fd_t {
    const socket_result = linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
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
    switch (linux.errno(connect_result)) {
        .SUCCESS => {},
        .AGAIN, .INPROGRESS => {
            var poll_fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
            const poll_result = linux.poll(poll_fds[0..].ptr, poll_fds.len, @intCast(timeout_ms));
            if (linux.errno(poll_result) != .SUCCESS or poll_result == 0) return error.ConnectFailed;

            var socket_error: i32 = 0;
            var socket_error_len: linux.socklen_t = @sizeOf(@TypeOf(socket_error));
            const socket_error_result = linux.getsockopt(
                fd,
                linux.SOL.SOCKET,
                linux.SO.ERROR,
                std.mem.asBytes(&socket_error).ptr,
                &socket_error_len,
            );
            if (linux.errno(socket_error_result) != .SUCCESS or socket_error != 0) return error.ConnectFailed;
        },
        else => return error.ConnectFailed,
    }
    const flags_result = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags_result) != .SUCCESS) return error.ConnectFailed;
    const blocking_result = linux.fcntl(fd, linux.F.SETFL, flags_result & ~@as(usize, linux.SOCK.NONBLOCK));
    if (linux.errno(blocking_result) != .SUCCESS) return error.ConnectFailed;
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

test "kernelAppendArg selects the x86 console and CAS block device" {
    const argument = try kernelAppendArg(std.testing.allocator, "x86_64", true);
    defer std.testing.allocator.free(argument);
    try std.testing.expectEqualStrings(
        "init=/init console=ttyS0 panic=-1 actiond.cas_device=/dev/vda actiond.format_cas=1",
        argument,
    );
}

test "kernelAppendArg selects the aarch64 console" {
    const argument = try kernelAppendArg(std.testing.allocator, "aarch64", false);
    defer std.testing.allocator.free(argument);
    try std.testing.expectEqualStrings(
        "init=/init console=ttyAMA0 panic=-1 actiond.cas_device=/dev/vda",
        argument,
    );
}
