const builtin = @import("builtin");
const std = @import("std");
const control_transport_fd = @import("control_transport_fd.zig");
const vsock = @import("vsock.zig");

const linux = std.os.linux;
const mfd_exec: u32 = 0x0010;
const max_ack_bytes = 64;
const max_cpu_count = 32;

pub const fexec_argument = "--actiond-internal-fexec-firecracker";

pub const Options = struct {
    kernel_path: ?[]const u8,
    initramfs_path: ?[]const u8,
    runtime_image_path: ?[]const u8,
    cas_image_path: []const u8,
    vsock_path: []const u8,
    format_cas_image: bool = false,
    memory_mib: u64 = 512,
    cpu_count: u32 = 2,
    start_timeout_ms: u32 = 30_000,
    connect_timeout_ms: u32 = 60_000,
    connect_attempt_timeout_ms: u32 = 1_000,
    guest_cid: u32 = 3,
};

pub const Machine = struct {
    child: std.process.Child,
    io: std.Io,
    vsock_path: []u8,
    allocator: std.mem.Allocator,
    connect_timeout_ms: u32,
    connect_attempt_timeout_ms: u32,

    pub fn start(io: std.Io, allocator: std.mem.Allocator, options: Options) !Machine {
        if (comptime builtin.os.tag != .linux or (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64)) {
            return error.UnsupportedHost;
        }
        if (options.cpu_count == 0 or options.cpu_count > max_cpu_count) return error.InvalidCpuCount;
        if (options.memory_mib == 0) return error.InvalidMemorySize;
        if (options.vsock_path.len >= @sizeOf(@FieldType(linux.sockaddr.un, "path"))) return error.UnixSocketPathTooLong;

        const memory = try std.fmt.allocPrint(allocator, "{d}", .{options.memory_mib});
        defer allocator.free(memory);
        const cpus = try std.fmt.allocPrint(allocator, "{d}", .{options.cpu_count});
        defer allocator.free(cpus);
        const guest_cid = try std.fmt.allocPrint(allocator, "{d}", .{options.guest_cid});
        defer allocator.free(guest_cid);

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{
            "/proc/self/exe",
            fexec_argument,
            "--cas-image",
            options.cas_image_path,
            "--vsock-path",
            options.vsock_path,
            "--memory-mib",
            memory,
            "--cpus",
            cpus,
            "--guest-cid",
            guest_cid,
        });
        if (options.format_cas_image) try argv.append(allocator, "--format-cas-image");
        if (options.kernel_path) |path| try argv.appendSlice(allocator, &.{ "--kernel", path });
        if (options.initramfs_path) |path| try argv.appendSlice(allocator, &.{ "--initramfs", path });
        if (options.runtime_image_path) |path| try argv.appendSlice(allocator, &.{ "--runtime-image", path });

        std.log.info("starting embedded Firecracker guest_cid={d}", .{options.guest_cid});
        const vsock_path = try allocator.dupe(u8, options.vsock_path);
        errdefer allocator.free(vsock_path);
        errdefer std.Io.Dir.cwd().deleteFile(io, vsock_path) catch {};

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
            .vsock_path = vsock_path,
            .allocator = allocator,
            .connect_timeout_ms = options.connect_timeout_ms,
            .connect_attempt_timeout_ms = options.connect_attempt_timeout_ms,
        };
        try machine.waitForControlPort(options.start_timeout_ms);
        return machine;
    }

    pub fn deinit(self: *Machine) void {
        self.child.kill(self.io);
        std.Io.Dir.cwd().deleteFile(self.io, self.vsock_path) catch {};
        self.allocator.free(self.vsock_path);
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
            if (connectUnixVsock(self.io, self.vsock_path, port, attempt_timeout_ms)) |fd| return fd else |err| {
                if (try self.reapExitedChild()) |status| {
                    std.log.err("Firecracker exited before guest vsock became ready status=0x{x}", .{status});
                    return error.StartFailed;
                }
                const updated_elapsed_ms = started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
                if (updated_elapsed_ms >= @as(i64, timeout_ms)) {
                    std.log.err("timed out connecting to Firecracker vsock:{d}: {s}", .{ port, @errorName(err) });
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

const FexecOptions = struct {
    kernel_path: ?[]const u8 = null,
    initramfs_path: ?[]const u8 = null,
    runtime_image_path: ?[]const u8 = null,
    cas_image_path: []const u8 = "",
    vsock_path: []const u8 = "",
    memory_mib: u64 = 0,
    cpu_count: u8 = 0,
    guest_cid: u32 = 0,
    format_cas_image: bool = false,
};

pub fn fexecEmbedded(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    executable: []const u8,
    comptime embedded_assets: type,
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

    const options = try parseFexecOptions(args);
    const kernel = try assetPath(io, allocator, "actiond-kernel", options.kernel_path, embedded_assets.kernel);
    defer kernel.deinit(io, allocator);
    const initramfs = try assetPath(io, allocator, "actiond-initramfs", options.initramfs_path, embedded_assets.initramfs);
    defer initramfs.deinit(io, allocator);
    const runtime_image = try assetPath(io, allocator, "actiond-runtimes", options.runtime_image_path, embedded_assets.runtime_image);
    defer runtime_image.deinit(io, allocator);

    const config = try buildConfiguration(
        allocator,
        kernel.path,
        initramfs.path,
        runtime_image.path,
        options.cas_image_path,
        options.vsock_path,
        options.format_cas_image,
        options.memory_mib,
        options.cpu_count,
        options.guest_cid,
    );
    defer allocator.free(config);
    const config_fd = try createSealedMemfd(io, "actiond-firecracker-config", config, false);
    defer closeFd(config_fd);
    const config_path = try fdPathAlloc(allocator, config_fd);
    defer allocator.free(config_path);

    const executable_fd = try createSealedMemfd(io, "actiond-firecracker", executable, true);
    defer closeFd(executable_fd);
    const process_args = [_][:0]const u8{
        "firecracker",
        "--no-api",
        "--config-file",
        try allocator.dupeZ(u8, config_path),
        "--enable-pci",
    };
    defer allocator.free(process_args[3]);
    try execFd(allocator, environ, executable_fd, &process_args);
}

const AssetPath = struct {
    path: []const u8,
    fd: ?std.posix.fd_t = null,
    owned_path: ?[]u8 = null,

    fn deinit(self: AssetPath, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        if (self.fd) |fd| closeFd(fd);
        if (self.owned_path) |path| allocator.free(path);
    }
};

fn assetPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    override_path: ?[]const u8,
    embedded: []const u8,
) !AssetPath {
    if (override_path) |path| return .{ .path = path };
    const fd = try createSealedMemfd(io, name, embedded, false);
    errdefer closeFd(fd);
    const path = try fdPathAlloc(allocator, fd);
    return .{ .path = path, .fd = fd, .owned_path = path };
}

fn buildConfiguration(
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initramfs_path: []const u8,
    runtime_image_path: []const u8,
    cas_image_path: []const u8,
    vsock_path: []const u8,
    format_cas_image: bool,
    memory_mib: u64,
    cpu_count: u8,
    guest_cid: u32,
) ![]u8 {
    if (memory_mib == 0) return error.InvalidMemorySize;
    if (cpu_count == 0) return error.InvalidCpuCount;
    const format_argument = if (format_cas_image) " actiond.format_cas=1" else "";
    // TODO: Firecracker's Async block I/O engine remains developer preview; verify it when Firecracker changes the stability guarantee.
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "boot-source": {{
        \\    "kernel_image_path": {f},
        \\    "initrd_path": {f},
        \\    "boot_args": "init=/init console=ttyS0 reboot=k panic=-1 nomodule swiotlb=noforce actiond.cas_device=/dev/vda{s}"
        \\  }},
        \\  "drives": [
        \\    {{"drive_id":"cas","partuuid":null,"is_root_device":false,"cache_type":"Unsafe","is_read_only":false,"path_on_host":{f},"rate_limiter":null,"io_engine":"Async","socket":null}},
        \\    {{"drive_id":"runtimes","partuuid":null,"is_root_device":false,"cache_type":"Unsafe","is_read_only":true,"path_on_host":{f},"rate_limiter":null,"io_engine":"Sync","socket":null}}
        \\  ],
        \\  "machine-config": {{"vcpu_count":{d},"mem_size_mib":{d},"smt":false,"track_dirty_pages":false,"huge_pages":"None"}},
        \\  "vsock": {{"guest_cid":{d},"uds_path":{f}}}
        \\}}
    , .{
        std.json.fmt(kernel_path, .{}),
        std.json.fmt(initramfs_path, .{}),
        format_argument,
        std.json.fmt(cas_image_path, .{}),
        std.json.fmt(runtime_image_path, .{}),
        cpu_count,
        memory_mib,
        guest_cid,
        std.json.fmt(vsock_path, .{}),
    });
}

fn parseFexecOptions(args: []const [:0]const u8) !FexecOptions {
    var options: FexecOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format-cas-image")) {
            options.format_cas_image = true;
            continue;
        }
        i += 1;
        if (i >= args.len) return error.MissingFirecrackerArgument;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--kernel")) options.kernel_path = value else if (std.mem.eql(u8, arg, "--initramfs")) options.initramfs_path = value else if (std.mem.eql(u8, arg, "--runtime-image")) options.runtime_image_path = value else if (std.mem.eql(u8, arg, "--cas-image")) options.cas_image_path = value else if (std.mem.eql(u8, arg, "--vsock-path")) options.vsock_path = value else if (std.mem.eql(u8, arg, "--memory-mib")) options.memory_mib = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--cpus")) options.cpu_count = try std.fmt.parseInt(u8, value, 10) else if (std.mem.eql(u8, arg, "--guest-cid")) options.guest_cid = try std.fmt.parseInt(u32, value, 10) else return error.UnknownFirecrackerArgument;
    }
    if (options.cas_image_path.len == 0 or options.vsock_path.len == 0) return error.MissingFirecrackerArgument;
    if (options.memory_mib == 0 or options.cpu_count == 0 or options.cpu_count > max_cpu_count or options.guest_cid < 3) return error.InvalidFirecrackerArgument;
    return options;
}

fn createSealedMemfd(io: std.Io, name: [:0]const u8, bytes: []const u8, executable: bool) !std.posix.fd_t {
    const base_flags: u32 = linux.MFD.ALLOW_SEALING;
    const flags: u32 = if (executable) base_flags | linux.MFD.CLOEXEC else base_flags;
    const fd = if (executable)
        try std.posix.memfd_create(name, flags | mfd_exec)
    else
        try std.posix.memfd_create(name, flags);
    errdefer closeFd(fd);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    try file.writePositionalAll(io, bytes, 0);
    if (executable) try file.setPermissions(io, .executable_file);
    const seals = linux.F.SEAL_SEAL | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE;
    const seal_result = linux.fcntl(fd, linux.F.ADD_SEALS, seals);
    if (linux.errno(seal_result) != .SUCCESS) return error.FexecFailed;
    return fd;
}

fn fdPathAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t) ![]u8 {
    return std.fmt.allocPrint(allocator, "/proc/self/fd/{d}", .{fd});
}

fn execFd(allocator: std.mem.Allocator, environ: std.process.Environ, fd: std.posix.fd_t, args: []const [:0]const u8) !noreturn {
    const argv = try allocator.allocSentinel(?[*:0]const u8, args.len, null);
    for (args, argv) |arg, *entry| entry.* = arg.ptr;
    const environment = environ.block.view().slice;
    const envp = try allocator.allocSentinel(?[*:0]const u8, environment.len, null);
    for (environment, envp) |entry, *output| output.* = entry;
    const result = linux.execveat(fd, "", argv.ptr, envp.ptr, .{ .SYMLINK_NOFOLLOW = false, .EMPTY_PATH = true });
    std.log.err("execveat for embedded Firecracker failed: {s}", .{@tagName(linux.errno(result))});
    return error.FexecFailed;
}

fn connectUnixVsock(io: std.Io, path: []const u8, port: u32, timeout_ms: u32) !std.posix.fd_t {
    const started = std.Io.Clock.awake.now(io);
    const socket_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(socket_result) != .SUCCESS) return error.ConnectFailed;
    const fd: std.posix.fd_t = @intCast(socket_result);
    errdefer closeFd(fd);

    var address: linux.sockaddr.un = .{ .path = [_]u8{0} ** 108 };
    if (path.len >= address.path.len) return error.UnixSocketPathTooLong;
    @memcpy(address.path[0..path.len], path);
    const address_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    const connect_result = linux.connect(fd, @ptrCast(&address), address_len);
    switch (linux.errno(connect_result)) {
        .SUCCESS => {},
        .AGAIN, .INPROGRESS, .INTR => try pollSocket(io, fd, linux.POLL.OUT, started, timeout_ms),
        else => return error.ConnectFailed,
    }
    var socket_error: i32 = 0;
    var socket_error_len: linux.socklen_t = @sizeOf(@TypeOf(socket_error));
    const socket_error_result = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&socket_error).ptr, &socket_error_len);
    if (linux.errno(socket_error_result) != .SUCCESS or socket_error != 0) return error.ConnectFailed;

    var command_buffer: [32]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buffer, "CONNECT {d}\n", .{port});
    try writeSocket(io, fd, command, started, timeout_ms);
    var ack: [max_ack_bytes]u8 = undefined;
    var ack_len: usize = 0;
    while (ack_len < ack.len) {
        try pollSocket(io, fd, linux.POLL.IN, started, timeout_ms);
        const read_result = linux.read(fd, ack[ack_len..].ptr, 1);
        switch (linux.errno(read_result)) {
            .SUCCESS => {
                if (read_result != 1) return error.InvalidVsockAck;
                ack_len += 1;
                if (ack[ack_len - 1] == '\n') break;
            },
            .AGAIN, .INTR => continue,
            else => return error.InvalidVsockAck,
        }
    }
    try validateVsockAck(ack[0..ack_len]);

    const flags_result = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags_result) != .SUCCESS) return error.ConnectFailed;
    const blocking_result = linux.fcntl(fd, linux.F.SETFL, flags_result & ~@as(usize, linux.SOCK.NONBLOCK));
    if (linux.errno(blocking_result) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

fn writeSocket(io: std.Io, fd: std.posix.fd_t, bytes: []const u8, started: std.Io.Timestamp, timeout_ms: u32) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try pollSocket(io, fd, linux.POLL.OUT, started, timeout_ms);
        const result = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.ConnectFailed;
                offset += result;
            },
            .AGAIN, .INTR => continue,
            else => return error.ConnectFailed,
        }
    }
}

fn pollSocket(io: std.Io, fd: std.posix.fd_t, events: i16, started: std.Io.Timestamp, timeout_ms: u32) !void {
    while (true) {
        var poll_fds = [_]linux.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const result = linux.poll(&poll_fds, poll_fds.len, @intCast(try remainingTimeoutMs(io, started, timeout_ms)));
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result != 1) return error.ConnectTimedOut;
                if (poll_fds[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0) return error.ConnectFailed;
                return;
            },
            .INTR => continue,
            else => return error.ConnectFailed,
        }
    }
}

fn remainingTimeoutMs(io: std.Io, started: std.Io.Timestamp, timeout_ms: u32) !u32 {
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    if (elapsed_ms >= @as(i64, timeout_ms)) return error.ConnectTimedOut;
    return timeout_ms - @as(u32, @intCast(elapsed_ms));
}

fn validateVsockAck(ack: []const u8) !void {
    if (!std.mem.startsWith(u8, ack, "OK ") or ack.len <= 4 or ack[ack.len - 1] != '\n') return error.InvalidVsockAck;
    _ = std.fmt.parseInt(u32, ack[3 .. ack.len - 1], 10) catch return error.InvalidVsockAck;
}

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (linux.errno(linux.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

test "Firecracker configuration preserves drive order" {
    const configuration = try buildConfiguration(std.testing.allocator, "/proc/self/fd/4", "/proc/self/fd/5", "/proc/self/fd/6", "/tmp/cas.ext4", "/tmp/firecracker.vsock", true, 1024, 4, 3);
    defer std.testing.allocator.free(configuration);
    const cas = std.mem.indexOf(u8, configuration, "\"drive_id\":\"cas\"").?;
    const runtimes = std.mem.indexOf(u8, configuration, "\"drive_id\":\"runtimes\"").?;
    try std.testing.expect(cas < runtimes);
    try std.testing.expect(std.mem.indexOf(u8, configuration, "actiond.cas_device=/dev/vda actiond.format_cas=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration, "\"io_engine\":\"Async\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, configuration, "pci=off") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, configuration, .{});
    defer parsed.deinit();
}

test "validate Firecracker vsock acknowledgement" {
    try validateVsockAck("OK 1073741824\n");
    try std.testing.expectError(error.InvalidVsockAck, validateVsockAck("OK\n"));
    try std.testing.expectError(error.InvalidVsockAck, validateVsockAck("OK 4294967296\n"));
    try std.testing.expectError(error.InvalidVsockAck, validateVsockAck("OK 3"));
}
