const std = @import("std");

const OutputSymlink = struct {
    path: []const u8,
    target: ?[]const u8 = null,
};

const Options = struct {
    out_file: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    out_count: usize = 16,
    sleep_ms: ?i64 = null,
    escape_process_group: bool = false,
    exercise_filesystem: bool = false,
    expect_action_signals: bool = false,
    expect_cgroup_limits: bool = false,
    expect_network_blocked: bool = false,
    expect_loopback: bool = false,
    expect_localhost_hosts: bool = false,
    scans: std.ArrayListUnmanaged([]const u8) = .empty,
    extra_out_files: std.ArrayListUnmanaged([]const u8) = .empty,
    out_symlinks: std.ArrayListUnmanaged(OutputSymlink) = .empty,

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.scans.deinit(allocator);
        self.extra_out_files.deinit(allocator);
        self.out_symlinks.deinit(allocator);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try expandArgs(io, arena, raw_args[1..]);

    var options = try parseArgs(allocator, args.items);
    defer options.deinit(allocator);

    if (options.expect_network_blocked) {
        try expectNetworkBlocked();
        try expectVsockBlocked();
        try expectBpfProgramsBlocked();
    }
    if (options.expect_loopback) try expectLoopbackTcp();
    if (options.expect_localhost_hosts) try expectLocalhostHosts(io, allocator);
    if (options.expect_action_signals) try expectActionSignals(io);
    if (options.expect_cgroup_limits) try expectCgroupLimits(io);
    if (options.escape_process_group) try escapeProcessGroup(io, options.sleep_ms orelse 30_000);
    if (options.sleep_ms) |milliseconds| try io.sleep(.fromMilliseconds(milliseconds), .awake);

    const cwd = std.Io.Dir.cwd();
    var hash = std.hash.Wyhash.init(0xaca1_0d5eed);
    for (options.scans.items) |path| try hashPath(io, allocator, cwd, path, &hash);
    const value = hash.final();

    if (options.out_file) |path| try writeSummary(io, allocator, cwd, path, value, options.scans.items.len);
    if (options.out_dir) |path| try writeTree(io, allocator, cwd, path, value, options.out_count);
    for (options.extra_out_files.items, 0..) |path, i| try writeGeneratedFile(io, allocator, cwd, path, value, i);
    for (options.out_symlinks.items) |link| {
        try createParentDirs(io, cwd, link.path);
        try cwd.symLink(io, link.target.?, link.path, .{});
    }
    if (options.exercise_filesystem) {
        const path = options.out_dir orelse return error.FilesystemChecksRequireOutputDirectory;
        try exerciseFilesystem(io, allocator, cwd, path, options.scans.items);
    }
}

fn expandArgs(
    io: std.Io,
    allocator: std.mem.Allocator,
    raw_args: []const []const u8,
) !std.ArrayListUnmanaged([]const u8) {
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer args.deinit(allocator);

    for (raw_args) |arg| {
        if (arg.len > 1 and arg[0] == '@') {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, arg[1..], allocator, .limited(64 * 1024 * 1024));
            var it = std.mem.splitScalar(u8, bytes, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (trimmed.len != 0) try args.append(allocator, trimmed);
            }
        } else {
            try args.append(allocator, arg);
        }
    }
    return args;
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Options {
    var options: Options = .{};
    errdefer options.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--out-file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            options.out_file = args[i];
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            options.out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--out-count")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            options.out_count = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--sleep-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            options.sleep_ms = try std.fmt.parseInt(i64, args[i], 10);
            if (options.sleep_ms.? < 0) return error.InvalidSleepDuration;
        } else if (std.mem.eql(u8, arg, "--escape-process-group")) {
            options.escape_process_group = true;
        } else if (std.mem.eql(u8, arg, "--out-extra-file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            try options.extra_out_files.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--out-symlink")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            try options.out_symlinks.append(allocator, .{ .path = args[i] });
        } else if (std.mem.eql(u8, arg, "--out-symlink-target")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            if (options.out_symlinks.items.len == 0) return error.MissingOutputSymlink;
            const link = &options.out_symlinks.items[options.out_symlinks.items.len - 1];
            if (link.target != null) return error.DuplicateOutputSymlinkTarget;
            link.target = args[i];
        } else if (std.mem.eql(u8, arg, "--scan")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            try options.scans.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--exercise-filesystem")) {
            options.exercise_filesystem = true;
        } else if (std.mem.eql(u8, arg, "--expect-action-signals")) {
            options.expect_action_signals = true;
        } else if (std.mem.eql(u8, arg, "--expect-cgroup-limits")) {
            options.expect_cgroup_limits = true;
        } else if (std.mem.eql(u8, arg, "--expect-network-blocked")) {
            options.expect_network_blocked = true;
        } else if (std.mem.eql(u8, arg, "--expect-loopback")) {
            options.expect_loopback = true;
        } else if (std.mem.eql(u8, arg, "--expect-localhost-hosts")) {
            options.expect_localhost_hosts = true;
        } else {
            return error.UnknownArgument;
        }
    }
    for (options.out_symlinks.items) |link| {
        if (link.target == null) return error.MissingOutputSymlinkTarget;
    }
    return options;
}

fn expectNetworkBlocked() !void {
    const linux = std.os.linux;
    if (@import("builtin").os.tag != .linux) return;

    const socket_rc = linux.socket(
        linux.AF.INET,
        linux.SOCK.DGRAM | linux.SOCK.CLOEXEC,
        linux.IPPROTO.UDP,
    );
    switch (std.os.linux.errno(socket_rc)) {
        .SUCCESS => {},
        .AFNOSUPPORT, .PROTONOSUPPORT => return,
        else => |err| {
            std.debug.print("network block check could not create socket: {s}\n", .{@tagName(err)});
            return error.NetworkCheckFailed;
        },
    }
    const fd: i32 = @intCast(socket_rc);
    defer _ = linux.close(fd);

    var addr = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, 80),
        .addr = std.mem.nativeToBig(u32, 0x01010101),
    };
    const connect_rc = linux.connect(
        fd,
        @as(*const linux.sockaddr, @ptrCast(&addr)),
        @sizeOf(linux.sockaddr.in),
    );
    switch (std.os.linux.errno(connect_rc)) {
        .NETUNREACH, .HOSTUNREACH, .NETDOWN, .ADDRNOTAVAIL, .ACCES, .PERM => return,
        .SUCCESS => {
            var local_addr: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in);
            var local_addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            switch (std.os.linux.errno(linux.getsockname(
                fd,
                @as(*linux.sockaddr, @ptrCast(&local_addr)),
                &local_addr_len,
            ))) {
                .SUCCESS => {
                    if (isBlockedLocalIpv4(local_addr.addr)) return;
                    const source = std.mem.bigToNative(u32, local_addr.addr);
                    std.debug.print(
                        "network block check selected non-loopback source address {d}.{d}.{d}.{d}\n",
                        .{
                            (source >> 24) & 0xff,
                            (source >> 16) & 0xff,
                            (source >> 8) & 0xff,
                            source & 0xff,
                        },
                    );
                    return error.NetworkReachable;
                },
                else => |err| {
                    std.debug.print("network block check returned unexpected getsockname errno: {s}\n", .{@tagName(err)});
                    return error.NetworkCheckFailed;
                },
            }
        },
        else => |err| {
            std.debug.print("network block check returned unexpected connect errno: {s}\n", .{@tagName(err)});
            return error.NetworkCheckFailed;
        },
    }
}

fn expectVsockBlocked() !void {
    const linux = std.os.linux;
    if (@import("builtin").os.tag != .linux) return;

    const socket_rc = linux.socket(
        linux.AF.VSOCK,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    switch (std.os.linux.errno(socket_rc)) {
        .PERM, .ACCES, .AFNOSUPPORT, .PROTONOSUPPORT => return,
        .SUCCESS => {
            const fd: i32 = @intCast(socket_rc);
            _ = linux.close(fd);
            std.debug.print("sandboxed action unexpectedly opened an AF_VSOCK socket\n", .{});
            return error.NetworkReachable;
        },
        else => |err| {
            std.debug.print("AF_VSOCK block check returned unexpected socket errno: {s}\n", .{@tagName(err)});
            return error.NetworkCheckFailed;
        },
    }
}

fn expectBpfProgramsBlocked() !void {
    const linux = std.os.linux;
    if (@import("builtin").os.tag != .linux) return;

    const seccomp_mode = linux.prctl(@intFromEnum(linux.PR.GET_SECCOMP), 0, 0, 0, 0);
    if (linux.errno(seccomp_mode) != .SUCCESS or seccomp_mode != linux.SECCOMP.MODE.FILTER) {
        std.debug.print("sandboxed action does not have an active seccomp filter\n", .{});
        return error.SeccompCheckFailed;
    }

    const blocked_calls = [_]struct { name: []const u8, result: usize }{
        .{
            .name = "seccomp",
            .result = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, null),
        },
        .{
            .name = "prctl(PR_SET_SECCOMP)",
            .result = linux.prctl(
                @intFromEnum(linux.PR.SET_SECCOMP),
                linux.SECCOMP.MODE.FILTER,
                0,
                0,
                0,
            ),
        },
        .{
            .name = "bpf",
            .result = linux.syscall3(.bpf, 0, 0, 0),
        },
    };
    for (blocked_calls) |blocked_call| {
        switch (linux.errno(blocked_call.result)) {
            .PERM, .ACCES => {},
            else => |err| {
                std.debug.print(
                    "sandboxed action unexpectedly reached {s}: {s}\n",
                    .{ blocked_call.name, @tagName(err) },
                );
                return error.SeccompCheckFailed;
            },
        }
    }

    const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket_rc) != .SUCCESS) {
        std.debug.print("BPF restriction check could not create an IPv4 socket\n", .{});
        return error.SeccompCheckFailed;
    }
    const fd: i32 = @intCast(socket_rc);
    defer _ = linux.close(fd);

    var enabled: c_int = 1;
    const enabled_bytes = std.mem.asBytes(&enabled);
    const denied_options = [_]u32{ linux.SO.ATTACH_FILTER, linux.SO.ATTACH_REUSEPORT_CBPF };
    for (denied_options) |option| {
        switch (linux.errno(linux.setsockopt(
            fd,
            linux.SOL.SOCKET,
            option,
            enabled_bytes.ptr,
            @intCast(enabled_bytes.len),
        ))) {
            .PERM, .ACCES => {},
            else => |err| {
                std.debug.print(
                    "sandboxed action unexpectedly reached BPF socket option {d}: {s}\n",
                    .{ option, @tagName(err) },
                );
                return error.SeccompCheckFailed;
            },
        }
    }

    const reuse_address = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        enabled_bytes.ptr,
        @intCast(enabled_bytes.len),
    );
    if (linux.errno(reuse_address) != .SUCCESS) {
        std.debug.print("sandbox seccomp filter rejected SO_REUSEADDR\n", .{});
        return error.SeccompCheckFailed;
    }
}

fn expectCgroupLimits(io: std.Io) !void {
    if (@import("builtin").os.tag != .linux) return;

    var file = std.Io.Dir.cwd().openFile(io, "/proc/self/cgroup", .{}) catch |err| {
        std.debug.print("cgroup limit check could not read /proc/self/cgroup: {s}\n", .{@errorName(err)});
        return error.CgroupCheckFailed;
    };
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    const size = readFd(file.handle, &buffer) catch |err| {
        std.debug.print("cgroup limit check could not read /proc/self/cgroup: {s}\n", .{@errorName(err)});
        return error.CgroupCheckFailed;
    };
    const membership = buffer[0..size];

    if (std.mem.indexOf(u8, membership, "0::/actiond/action-") == null) {
        std.debug.print("sandboxed action is not in its requested cgroup: {s}\n", .{membership});
        return error.CgroupCheckFailed;
    }
}

fn expectActionSignals(io: std.Io) !void {
    const linux = std.os.linux;
    if (@import("builtin").os.tag != .linux) return;

    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(io.userdata orelse
        return error.ActionSignalCheckFailed));
    if (threaded.old_sig_pipe.handler.handler != linux.SIG.DFL) {
        std.debug.print("sandboxed action did not inherit the default SIGPIPE disposition\n", .{});
        return error.ActionSignalCheckFailed;
    }

    if (linux.getpid() == 1) {
        std.debug.print("sandboxed action is PID 1 and does not receive default fatal signals\n", .{});
        return error.ActionSignalCheckFailed;
    }

    var pipe_fds: [2]std.posix.fd_t = undefined;
    switch (linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.ActionSignalCheckFailed,
    }
    _ = linux.close(pipe_fds[0]);

    const fork_rc = linux.fork();
    switch (linux.errno(fork_rc)) {
        .SUCCESS => {},
        else => {
            _ = linux.close(pipe_fds[1]);
            return error.ActionSignalCheckFailed;
        },
    }
    const child_pid: linux.pid_t = @intCast(fork_rc);
    if (child_pid == 0) {
        const action: linux.Sigaction = .{
            .handler = .{ .handler = linux.SIG.DFL },
            .mask = linux.sigemptyset(),
            .flags = 0,
        };
        if (linux.errno(linux.sigaction(.PIPE, &action, null)) != .SUCCESS)
            linux.exit(124);
        _ = linux.write(pipe_fds[1], "x", 1);
        linux.exit(125);
    }

    _ = linux.close(pipe_fds[1]);
    var status: u32 = 0;
    while (true) switch (linux.errno(linux.waitpid(child_pid, &status, 0))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.ActionSignalCheckFailed,
    };

    if (!linux.W.IFSIGNALED(status) or linux.W.TERMSIG(status) != linux.SIG.PIPE) {
        std.debug.print("sandboxed action descendant did not terminate on default SIGPIPE: status={d}\n", .{status});
        return error.ActionSignalCheckFailed;
    }
}

fn escapeProcessGroup(io: std.Io, milliseconds: i64) !void {
    const linux = std.os.linux;
    if (@import("builtin").os.tag != .linux) return error.UnsupportedHost;

    switch (linux.errno(linux.setsid())) {
        .SUCCESS => {},
        else => return error.TimeoutEscapeSessionFailed,
    }

    var ready_pipe: [2]std.posix.fd_t = undefined;
    switch (linux.errno(linux.pipe2(&ready_pipe, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.TimeoutEscapePipeFailed,
    }
    const fork_rc = linux.fork();
    switch (linux.errno(fork_rc)) {
        .SUCCESS => {},
        else => {
            _ = linux.close(ready_pipe[0]);
            _ = linux.close(ready_pipe[1]);
            return error.TimeoutEscapeForkFailed;
        },
    }
    const pid: linux.pid_t = @intCast(fork_rc);
    if (pid != 0) {
        _ = linux.close(ready_pipe[1]);
        defer _ = linux.close(ready_pipe[0]);
        var ready: [1]u8 = undefined;
        while (true) {
            const read_rc = linux.read(ready_pipe[0], &ready, 1);
            switch (linux.errno(read_rc)) {
                .SUCCESS => {
                    if (read_rc != 1 or ready[0] != '1') return error.TimeoutEscapeNotReady;
                    return;
                },
                .INTR => continue,
                else => return error.TimeoutEscapeNotReady,
            }
        }
    }

    _ = linux.close(ready_pipe[0]);
    switch (linux.errno(linux.setsid())) {
        .SUCCESS => {},
        else => linux.exit(126),
    }
    while (true) switch (linux.errno(linux.write(ready_pipe[1], "1", 1))) {
        .SUCCESS => break,
        .INTR => continue,
        else => linux.exit(124),
    };
    _ = linux.close(ready_pipe[1]);
    _ = io;
    var duration = linux.timespec{
        .sec = @divTrunc(milliseconds, 1_000),
        .nsec = @intCast(@mod(milliseconds, 1_000) * std.time.ns_per_ms),
    };
    while (true) switch (linux.errno(linux.nanosleep(&duration, &duration))) {
        .SUCCESS => break,
        .INTR => continue,
        else => linux.exit(125),
    };
    linux.exit(0);
}

fn isBlockedLocalIpv4(address_be: u32) bool {
    const address = std.mem.bigToNative(u32, address_be);
    return address == 0 or (address & 0xff000000) == 0x7f000000;
}

fn expectLocalhostHosts(io: std.Io, allocator: std.mem.Allocator) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        "/etc/hosts",
        allocator,
        .limited(64 * 1024),
    ) catch |err| {
        std.debug.print("localhost hosts check could not read /etc/hosts: {s}\n", .{@errorName(err)});
        return error.LocalhostHostsCheckFailed;
    };
    defer allocator.free(bytes);

    var has_ipv4_localhost = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
        const address = fields.next() orelse continue;
        if (!std.mem.eql(u8, address, "127.0.0.1")) continue;
        while (fields.next()) |name| {
            if (std.mem.eql(u8, name, "localhost")) {
                has_ipv4_localhost = true;
                break;
            }
        }
    }

    if (!has_ipv4_localhost) {
        std.debug.print("localhost hosts check did not find '127.0.0.1 localhost' in /etc/hosts\n", .{});
        return error.LocalhostHostsCheckFailed;
    }
}

fn expectLoopbackTcp() !void {
    const linux = std.os.linux;
    if (@import("builtin").os.tag != .linux) return;

    const listener_fd = try tcpSocket();
    defer _ = linux.close(listener_fd);

    var bind_addr = linux.sockaddr.in{
        .port = 0,
        .addr = 0,
    };
    switch (std.os.linux.errno(linux.bind(
        listener_fd,
        @as(*const linux.sockaddr, @ptrCast(&bind_addr)),
        @sizeOf(linux.sockaddr.in),
    ))) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("loopback check could not bind 0.0.0.0:0: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }
    switch (std.os.linux.errno(linux.listen(listener_fd, 1))) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("loopback check could not listen: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }

    var bound_addr: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in);
    var bound_addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    switch (std.os.linux.errno(linux.getsockname(
        listener_fd,
        @as(*linux.sockaddr, @ptrCast(&bound_addr)),
        &bound_addr_len,
    ))) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("loopback check could not read listener address: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }

    const client_fd = try tcpSocket();
    defer _ = linux.close(client_fd);

    var connect_addr = linux.sockaddr.in{
        .port = bound_addr.port,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    switch (std.os.linux.errno(linux.connect(
        client_fd,
        @as(*const linux.sockaddr, @ptrCast(&connect_addr)),
        @sizeOf(linux.sockaddr.in),
    ))) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("loopback check could not connect to 127.0.0.1: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }

    const accepted_rc = linux.accept(listener_fd, null, null);
    switch (std.os.linux.errno(accepted_rc)) {
        .SUCCESS => _ = linux.close(@intCast(accepted_rc)),
        else => |err| {
            std.debug.print("loopback check could not accept local connection: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }
}

fn tcpSocket() !i32 {
    const linux = std.os.linux;
    const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    switch (std.os.linux.errno(socket_rc)) {
        .SUCCESS => return @intCast(socket_rc),
        else => |err| {
            std.debug.print("network check could not create TCP socket: {s}\n", .{@tagName(err)});
            return error.NetworkCheckFailed;
        },
    }
}

fn hashPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    hash: *std.hash.Wyhash,
) anyerror!void {
    const stat = try root.statFile(io, path, .{});
    hash.update(path);
    switch (stat.kind) {
        .file => try hashFile(io, root, path, hash),
        .directory => try hashDirectory(io, allocator, root, path, hash),
        else => {},
    }
}

fn hashDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    hash: *std.hash.Wyhash,
) anyerror!void {
    var dir = try root.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    for (names.items) |name| {
        const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
        defer allocator.free(child);
        try hashPath(io, allocator, root, child, hash);
    }
}

fn hashFile(io: std.Io, root: std.Io.Dir, path: []const u8, hash: *std.hash.Wyhash) !void {
    var file = try root.openFile(io, path, .{});
    defer file.close(io);

    var buffer: [128 * 1024]u8 = undefined;
    while (true) {
        const n = try readFd(file.handle, &buffer);
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }
}

fn writeSummary(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    value: u64,
    input_count: usize,
) !void {
    try createParentDirs(io, root, path);
    const bytes = try std.fmt.allocPrint(allocator, "inputs={d}\nhash={x}\n", .{ input_count, value });
    defer allocator.free(bytes);
    try writeDefaultFile(io, root, path, bytes);
}

fn writeTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    value: u64,
    count: usize,
) !void {
    root.createDirPath(io, path) catch |err| {
        std.debug.print("failed to create output tree {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    var tree_dir = root.openDir(io, path, .{}) catch |err| {
        std.debug.print("failed to open output tree after create {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer tree_dir.close(io);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const child_name = try std.fmt.allocPrint(allocator, "generated-{d}.txt", .{i});
        defer allocator.free(child_name);
        const child = try std.fmt.allocPrint(allocator, "{s}/generated-{d}.txt", .{ path, i });
        defer allocator.free(child);
        const data = try std.fmt.allocPrint(allocator, "index={d}\nhash={x}\n", .{ i, value +% i });
        defer allocator.free(data);
        writeDefaultFile(io, tree_dir, child_name, data) catch |err| {
            std.debug.print("failed to write output tree child via open dir {s}: {s}\n", .{ child, @errorName(err) });
            return err;
        };
    }
}

fn writeGeneratedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    value: u64,
    index: usize,
) !void {
    try createParentDirs(io, root, path);
    const data = try std.fmt.allocPrint(allocator, "path={s}\nindex={d}\nhash={x}\n", .{ path, index, value +% index });
    defer allocator.free(data);
    try writeDefaultFile(io, root, path, data);
}

fn writeDefaultFile(io: std.Io, root: std.Io.Dir, path: []const u8, data: []const u8) !void {
    var file = root.createFile(io, path, .{
        .read = true,
        .permissions = .default_file,
    }) catch |err| {
        std.debug.print("failed to create output file {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer file.close(io);
    file.writeStreamingAll(io, data) catch |err| {
        std.debug.print("failed to write output file {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

fn createParentDirs(io: std.Io, root: std.Io.Dir, path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    try root.createDirPath(io, path[0..slash]);
}

fn exerciseFilesystem(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    output_path: []const u8,
    inputs: []const []const u8,
) !void {
    const output_root_end = std.mem.indexOfScalar(u8, output_path, '/') orelse
        return filesystemFailure("filesystem output path did not include an output parent");
    var iterable_root = try root.openDir(io, ".", .{ .iterate = true });
    defer iterable_root.close(io);
    try expectDirectoryEntry(io, iterable_root, output_path[0..output_root_end], .directory, true);

    var output_dir = try root.openDir(io, output_path, .{ .iterate = true });
    defer output_dir.close(io);
    try output_dir.createDirPath(io, "filesystem");
    try requireFilesystem((try output_dir.stat(io)).nlink == 3, "creating a staged subdirectory did not increment the output directory link count");
    try exerciseInputDirectoryLinkCounts(io, root);
    var dir = try output_dir.openDir(io, "filesystem", .{ .iterate = true });
    defer dir.close(io);

    try exerciseDirectoryPermissions(io, dir);
    try exerciseFileMetadata(io, dir);
    try exerciseDirectoryIteration(io, dir);
    try exerciseLinkCounts(io, dir);
    try exerciseSymlinks(io, allocator, root, dir, inputs);
    try exerciseImmutableInputAuthorization(io, allocator, root, inputs);
    try syncDirectory(dir);
    try syncDirectory(output_dir);
}

fn exerciseDirectoryPermissions(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDir(io, "private-mode", .fromMode(0o700));
    try requireFilesystem(
        ((try dir.statFile(io, "private-mode", .{})).permissions.toMode() & 0o7777) == 0o700,
        "staged mkdir did not preserve the requested directory permissions",
    );

    var private = try dir.openDir(io, "private-mode", .{ .iterate = true });
    defer private.close(io);
    try requireFilesystem(
        ((try private.stat(io)).permissions.toMode() & 0o7777) == 0o700,
        "opened staged directory did not preserve the requested permissions",
    );

    try dir.createDir(io, "sticky-mode", .fromMode(0o1700));
    try requireFilesystem(
        ((try dir.statFile(io, "sticky-mode", .{})).permissions.toMode() & 0o7777) == 0o1700,
        "staged mkdir did not preserve the requested sticky directory permission",
    );

    if (comptime @import("builtin").os.tag == .linux) {
        switch (std.os.linux.errno(std.os.linux.fchmod(private.handle, 0o750))) {
            .SUCCESS => {},
            else => return filesystemFailure("chmod failed for a staged directory"),
        }
        try requireFilesystem(
            ((try dir.statFile(io, "private-mode", .{})).permissions.toMode() & 0o7777) == 0o750,
            "staged directory chmod did not preserve updated permissions",
        );
    }
}

fn exerciseInputDirectoryLinkCounts(io: std.Io, root: std.Io.Dir) !void {
    const paths = [_][]const u8{
        "nested_files",
        "nested_files/group_001",
        "nested_files/group_001/foo",
        "nested_files/group_001/foo/bar",
        "nested_files/group_001/foo/bar/baz",
    };
    for (paths, 0..) |path, index| {
        var dir = try root.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        const expected: std.Io.File.NLink = if (index + 1 == paths.len) 2 else 3;
        const actual = (try dir.stat(io)).nlink;
        if (actual != expected) {
            std.debug.print("immutable input directory {s} has {d} links, expected {d}\n", .{ path, actual, expected });
            return filesystemFailure("immutable input directory reported an incorrect link count");
        }
    }

    var nested = try root.openDir(io, "nested_files/group_001/foo/bar/baz", .{ .iterate = true });
    defer nested.close(io);
    var created = try nested.createFile(io, "actiondfs-stage-ancestry-check.txt", .{
        .read = true,
        .permissions = .default_file,
    });
    try created.writeStreamingAll(io, "iterative actiondfs staged ancestry\n");
    created.close(io);
    try nested.deleteFile(io, "actiondfs-stage-ancestry-check.txt");
    try requireFilesystem(
        (try nested.statFile(io, "0001.txt", .{})).kind == .file,
        "staging nested input-directory ancestry hid an immutable input",
    );
}

fn exerciseFileMetadata(io: std.Io, dir: std.Io.Dir) !void {
    var file = try dir.createFile(io, "payload.txt", .{
        .read = true,
        .permissions = .default_file,
    });
    defer file.close(io);
    const payload = "actiondfs staged payload\n";
    try file.writeStreamingAll(io, payload);
    try file.sync(io);
    try syncFileData(file);

    try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o640));
    var stat = try file.stat(io);
    try requireFilesystem((stat.permissions.toMode() & 0o7777) == 0o640, "staged chmod did not update file permissions");

    const requested_timestamp = std.Io.Timestamp.fromNanoseconds(1_700_000_000 * std.time.ns_per_s);
    try file.setTimestamps(io, .{
        .access_timestamp = .{ .new = requested_timestamp },
        .modify_timestamp = .{ .new = requested_timestamp },
    });
    stat = try file.stat(io);
    try requireFilesystem(stat.mtime.toSeconds() == 1_700_000_000, "staged utimens did not update file mtime");

    if (comptime @import("builtin").os.tag == .linux) {
        const linux = std.os.linux;
        const current_uid = linux.geteuid();
        if (current_uid != 0) {
            const other_uid = if (current_uid == std.math.maxInt(linux.uid_t)) current_uid - 1 else current_uid + 1;
            switch (std.os.linux.errno(linux.fchown(file.handle, other_uid, std.math.maxInt(linux.gid_t)))) {
                .PERM, .ACCES => {},
                .SUCCESS => return filesystemFailure("unprivileged staged fchown unexpectedly succeeded"),
                else => return filesystemFailure("unprivileged staged fchown returned an unexpected errno"),
            }

            {
                var privileged = try dir.createFile(io, "privileged-create.txt", .{
                    .read = true,
                    .permissions = std.Io.File.Permissions.fromMode(0o6755),
                });
                defer privileged.close(io);
                try requireFilesystem(
                    ((try privileged.stat(io)).permissions.toMode() & 0o6000) == 0o6000,
                    "staged create did not preserve setuid/setgid permissions",
                );
            }
            try dir.deleteFile(io, "privileged-create.txt");

            switch (std.os.linux.errno(linux.fchmod(file.handle, 0o6755))) {
                .SUCCESS => {},
                else => return filesystemFailure("staged setuid/setgid chmod failed"),
            }
            try requireFilesystem(
                ((try file.stat(io)).permissions.toMode() & 0o6000) == 0o6000,
                "staged chmod did not expose setuid/setgid permissions",
            );
            try file.setLength(io, payload.len);
            try requireFilesystem(
                ((try file.stat(io)).permissions.toMode() & 0o6000) == 0,
                "staged truncate did not clear setuid/setgid permissions",
            );
            try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o640));

            {
                var destination = try dir.createFile(io, "privileged-copy.txt", .{ .read = true });
                defer destination.close(io);
                switch (std.os.linux.errno(linux.fchmod(destination.handle, 0o6755))) {
                    .SUCCESS => {},
                    else => return filesystemFailure("staged copy destination setuid/setgid chmod failed"),
                }
                try requireFilesystem(
                    ((try destination.stat(io)).permissions.toMode() & 0o6000) == 0o6000,
                    "staged copy destination did not expose setuid/setgid permissions",
                );

                var source_offset: i64 = 0;
                var destination_offset: i64 = 0;
                const copied = linux.copy_file_range(
                    file.handle,
                    &source_offset,
                    destination.handle,
                    &destination_offset,
                    1,
                    0,
                );
                switch (linux.errno(copied)) {
                    .SUCCESS => {},
                    else => return filesystemFailure("staged copy_file_range failed"),
                }
                try requireFilesystem(copied == 1, "staged copy_file_range copied an unexpected byte count");
                try requireFilesystem(
                    ((try destination.stat(io)).permissions.toMode() & 0o6000) == 0,
                    "staged copy_file_range did not clear setuid/setgid permissions",
                );
            }
            try dir.deleteFile(io, "privileged-copy.txt");
        }
    }

    {
        var populated = try dir.createFile(io, "truncate-open.txt", .{ .read = true });
        try populated.writeStreamingAll(io, "nonempty staged file");
        populated.close(io);

        var truncated = try dir.createFile(io, "truncate-open.txt", .{
            .read = true,
            .truncate = true,
        });
        defer truncated.close(io);
        try requireFilesystem(
            (try truncated.stat(io)).size == 0,
            "staged O_TRUNC open did not clear the open file size",
        );
        try requireFilesystem(
            (try dir.statFile(io, "truncate-open.txt", .{})).size == 0,
            "staged O_TRUNC open did not clear the directory entry size",
        );
    }
    try dir.deleteFile(io, "truncate-open.txt");

    var second = try dir.openFile(io, "payload.txt", .{ .mode = .read_write });
    defer second.close(io);
    try file.setLength(io, 3);
    try expectFileSize(io, dir, "payload.txt", file, second, 3);
    try second.writePositionalAll(io, "A", 4096);
    try expectFileSize(io, dir, "payload.txt", file, second, 4097);
    try file.setLength(io, 2);
    try expectFileSize(io, dir, "payload.txt", file, second, 2);
    try second.writePositionalAll(io, "B", 8192);
    try expectFileSize(io, dir, "payload.txt", file, second, 8193);
    try file.setLength(io, 0);
    try second.writePositionalAll(io, payload, 0);
    try expectFileSize(io, dir, "payload.txt", file, second, payload.len);
    try file.sync(io);
    try syncFileData(second);
}

fn expectFileSize(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    first: std.Io.File,
    second: std.Io.File,
    expected: u64,
) !void {
    try requireFilesystem((try first.stat(io)).size == expected, "first open file reported a stale size");
    try requireFilesystem((try second.stat(io)).size == expected, "second open file reported a stale size");
    try requireFilesystem((try dir.statFile(io, path, .{})).size == expected, "staged path reported a stale size");
}

fn exerciseDirectoryIteration(io: std.Io, dir: std.Io.Dir) !void {
    try expectDirectoryEntry(io, dir, "payload.txt", .file, true);

    const streamed_count = 128;
    for (0..streamed_count) |index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "stream-{d:0>4}-entry-for-getdents.txt", .{index});
        try writeDefaultFile(io, dir, name, "streamed directory entry\n");
    }

    var iterator = dir.iterate();
    var streamed_seen = [_]bool{false} ** streamed_count;
    var streamed_found: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "stream-")) continue;
        const suffix = entry.name["stream-".len..];
        const separator = std.mem.indexOfScalar(u8, suffix, '-') orelse
            return filesystemFailure("streamed directory entry has an invalid name");
        const index = std.fmt.parseInt(usize, suffix[0..separator], 10) catch
            return filesystemFailure("streamed directory entry has an invalid index");
        try requireFilesystem(index < streamed_count, "streamed directory entry index exceeded its expected range");
        try requireFilesystem(!streamed_seen[index], "streamed directory iteration emitted the same entry twice");
        streamed_seen[index] = true;
        streamed_found += 1;
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        try requireFilesystem(entry.inode == stat.inode, "streamed directory inode did not match lstat inode");
        try requireFilesystem(entry.kind == stat.kind, "streamed directory type did not match lstat type");
    }
    try requireFilesystem(streamed_found == streamed_count, "streamed directory iteration omitted entries across getdents buffers");

    for (0..streamed_count) |index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "stream-{d:0>4}-entry-for-getdents.txt", .{index});
        try dir.deleteFile(io, name);
    }

    try writeDefaultFile(io, dir, "created-after-rewind.txt", "created after the initial directory listing\n");
    try expectDirectoryEntry(io, dir, "created-after-rewind.txt", .file, true);

    try dir.rename("created-after-rewind.txt", dir, "renamed-after-rewind.txt", io);
    try expectDirectoryEntry(io, dir, "created-after-rewind.txt", .file, false);
    try expectDirectoryEntry(io, dir, "renamed-after-rewind.txt", .file, true);

    try dir.deleteFile(io, "renamed-after-rewind.txt");
    try expectDirectoryEntry(io, dir, "renamed-after-rewind.txt", .file, false);
}

fn expectDirectoryEntry(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    expected_kind: std.Io.File.Kind,
    expected_present: bool,
) !void {
    var iterator = dir.iterate();
    var found = false;
    while (try iterator.next(io)) |entry| {
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        try requireFilesystem(entry.inode == stat.inode, "readdir inode did not match lstat inode");
        try requireFilesystem(entry.kind == stat.kind, "readdir file type did not match lstat file type");
        if (std.mem.eql(u8, entry.name, name)) {
            found = true;
            try requireFilesystem(entry.kind == expected_kind, "readdir returned an unexpected file type");
        }
    }
    try requireFilesystem(found == expected_present, "rewound directory listing did not reflect a mutation");
}

fn exerciseLinkCounts(io: std.Io, dir: std.Io.Dir) !void {
    var unlinked = try dir.createFile(io, "unlink-open.txt", .{ .read = true });
    defer unlinked.close(io);
    try requireFilesystem((try unlinked.stat(io)).nlink == 1, "new staged file did not report one link");
    try dir.deleteFile(io, "unlink-open.txt");
    try requireFilesystem((try unlinked.stat(io)).nlink == 0, "open unlinked staged file did not report zero links");

    var source = try dir.createFile(io, "rename-source.txt", .{ .read = true });
    defer source.close(io);
    var replaced = try dir.createFile(io, "rename-replaced.txt", .{ .read = true });
    defer replaced.close(io);
    const source_inode = (try source.stat(io)).inode;
    try dir.rename("rename-source.txt", dir, "rename-replaced.txt", io);
    try requireFilesystem((try replaced.stat(io)).nlink == 0, "rename replacement did not unlink the replaced inode");
    try requireFilesystem((try source.stat(io)).nlink == 1, "rename changed the moved file link count");
    try requireFilesystem((try dir.statFile(io, "rename-replaced.txt", .{})).inode == source_inode, "rename changed the moved file inode");
    try dir.deleteFile(io, "rename-replaced.txt");

    try dir.createDirPath(io, "left");
    try dir.createDirPath(io, "right");
    var left = try dir.openDir(io, "left", .{ .iterate = true });
    defer left.close(io);
    var right = try dir.openDir(io, "right", .{ .iterate = true });
    defer right.close(io);
    try requireFilesystem((try left.stat(io)).nlink == 2, "empty staged directory did not report two links");
    try requireFilesystem((try right.stat(io)).nlink == 2, "empty staged destination directory did not report two links");
    try left.createDirPath(io, "child");
    var child = try left.openDir(io, "child", .{ .iterate = true });
    defer child.close(io);
    try requireFilesystem((try left.stat(io)).nlink == 3, "mkdir did not increment parent link count");
    try left.rename("child", right, "child", io);
    try requireFilesystem((try left.stat(io)).nlink == 2, "cross-parent directory rename did not decrement the old parent link count");
    try requireFilesystem((try right.stat(io)).nlink == 3, "cross-parent directory rename did not increment the new parent link count");
    try right.deleteDir(io, "child");
    try requireFilesystem((try right.stat(io)).nlink == 2, "rmdir did not decrement parent link count");
    try requireFilesystem((try child.stat(io)).nlink == 0, "open removed staged directory did not report zero links");
}

fn exerciseSymlinks(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    dir: std.Io.Dir,
    inputs: []const []const u8,
) !void {
    try dir.symLink(io, "payload.txt", "payload.link", .{});
    try expectSymlink(io, dir, "payload.link", "payload.txt");
    try expectDirectoryEntry(io, dir, "payload.link", .sym_link, true);
    try expectSymlinkContents(io, dir, "payload.link");
    if (dir.symLink(io, "payload.txt", "payload.link", .{})) |_| {
        return filesystemFailure("creating a duplicate staged symlink unexpectedly succeeded");
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    }

    try dir.createDirPath(io, "links");
    var links = try dir.openDir(io, "links", .{ .iterate = true });
    defer links.close(io);
    try links.symLink(io, "../payload.txt", "relative.link", .{});
    try expectSymlink(io, links, "relative.link", "../payload.txt");
    try expectDirectoryEntry(io, links, "relative.link", .sym_link, true);
    try expectSymlinkContents(io, links, "relative.link");

    try dir.symLink(io, "links", "directory.link", .{ .is_directory = true });
    try expectSymlink(io, dir, "directory.link", "links");
    try expectDirectoryEntry(io, dir, "directory.link", .sym_link, true);
    var directory_target = try dir.openDir(io, "directory.link", .{ .iterate = true });
    defer directory_target.close(io);
    try expectSymlinkContents(io, directory_target, "relative.link");

    try dir.symLink(io, "payload.txt", "temporary.link", .{});
    const original_inode = (try dir.statFile(io, "temporary.link", .{ .follow_symlinks = false })).inode;
    try dir.rename("temporary.link", dir, "renamed.link", io);
    try expectSymlink(io, dir, "renamed.link", "payload.txt");
    try requireFilesystem((try dir.statFile(io, "renamed.link", .{ .follow_symlinks = false })).inode == original_inode, "renaming a staged symlink changed its inode");
    try expectDirectoryEntry(io, dir, "temporary.link", .sym_link, false);
    try expectDirectoryEntry(io, dir, "renamed.link", .sym_link, true);
    try dir.deleteFile(io, "renamed.link");
    try expectDirectoryEntry(io, dir, "renamed.link", .sym_link, false);

    for (inputs) |input| {
        if ((try root.statFile(io, input, .{})).kind != .file) continue;
        const absolute_target = try std.fmt.allocPrint(allocator, "/workspace/{s}", .{input});
        defer allocator.free(absolute_target);
        try dir.symLink(io, absolute_target, "absolute-input.link", .{});
        try expectSymlink(io, dir, "absolute-input.link", absolute_target);
        var input_file = try dir.openFile(io, "absolute-input.link", .{});
        input_file.close(io);
        try dir.deleteFile(io, "absolute-input.link");

        if (root.symLink(io, "payload.txt", input, .{})) |_| {
            return filesystemFailure("creating a symlink over an immutable input unexpectedly succeeded");
        } else |err| switch (err) {
            error.PathAlreadyExists, error.ReadOnlyFileSystem, error.AccessDenied, error.PermissionDenied => {},
            else => return err,
        }
        break;
    }
}

fn expectSymlink(io: std.Io, dir: std.Io.Dir, path: []const u8, expected_target: []const u8) !void {
    const stat = try dir.statFile(io, path, .{ .follow_symlinks = false });
    try requireFilesystem(stat.kind == .sym_link, "lstat did not identify a staged symlink");
    try requireFilesystem(stat.size == expected_target.len, "lstat reported an unexpected symlink size");
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const size = try dir.readLink(io, path, &buffer);
    try requireFilesystem(std.mem.eql(u8, buffer[0..size], expected_target), "readlink changed the staged symlink target text");
}

fn expectSymlinkContents(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    const size = try readFd(file.handle, &buffer);
    try requireFilesystem(std.mem.eql(u8, buffer[0..size], "actiondfs staged payload\n"), "opening a staged symlink did not read its target");
}

fn exerciseImmutableInputAuthorization(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    inputs: []const []const u8,
) !void {
    if (comptime @import("builtin").os.tag != .linux) return;
    const linux = std.os.linux;
    for (inputs) |input| {
        if ((try root.statFile(io, input, .{})).kind != .file) continue;
        var file = try root.openFile(io, input, .{});
        defer file.close(io);
        switch (std.os.linux.errno(linux.fchmod(file.handle, 0o600))) {
            .PERM, .ACCES, .ROFS => {},
            .SUCCESS => return filesystemFailure("chmod unexpectedly changed an immutable input"),
            else => return filesystemFailure("immutable input chmod returned an unexpected errno"),
        }

        const path = try allocator.dupeZ(u8, input);
        defer allocator.free(path);
        const times = [2]linux.timespec{
            .{ .sec = 1_700_000_000, .nsec = 0 },
            .{ .sec = 1_700_000_000, .nsec = 0 },
        };
        switch (std.os.linux.errno(linux.utimensat(root.handle, path.ptr, &times, 0))) {
            .PERM, .ACCES, .ROFS => {},
            .SUCCESS => return filesystemFailure("utimens unexpectedly changed an immutable input"),
            else => return filesystemFailure("immutable input utimens returned an unexpected errno"),
        }
        return;
    }
    return filesystemFailure("filesystem regression did not receive an immutable file input");
}

fn syncFileData(file: std.Io.File) !void {
    if (comptime @import("builtin").os.tag != .linux) return;
    switch (std.os.linux.errno(std.os.linux.fdatasync(file.handle))) {
        .SUCCESS => {},
        else => return filesystemFailure("fdatasync failed for a staged file"),
    }
}

fn syncDirectory(dir: std.Io.Dir) !void {
    if (comptime @import("builtin").os.tag != .linux) return;
    switch (std.os.linux.errno(std.os.linux.fsync(dir.handle))) {
        .SUCCESS => {},
        else => return filesystemFailure("fsync failed for a staged directory"),
    }
}

fn requireFilesystem(condition: bool, comptime message: []const u8) !void {
    if (!condition) return filesystemFailure(message);
}

fn filesystemFailure(comptime message: []const u8) error{FilesystemRegressionFailed}!void {
    std.debug.print("filesystem regression failed: {s}\n", .{message});
    return error.FilesystemRegressionFailed;
}

fn readFd(fd: std.Io.File.Handle, buffer: []u8) !usize {
    while (true) {
        const rc = std.posix.system.read(fd, buffer.ptr, buffer.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

test "parseArgs accepts network and cgroup checks" {
    var options = try parseArgs(std.testing.allocator, &.{ "--expect-network-blocked", "--expect-loopback", "--expect-localhost-hosts", "--expect-action-signals", "--expect-cgroup-limits", "--out-extra-file", "out/a.txt" });
    defer options.deinit(std.testing.allocator);
    try std.testing.expect(options.expect_network_blocked);
    try std.testing.expect(options.expect_loopback);
    try std.testing.expect(options.expect_localhost_hosts);
    try std.testing.expect(options.expect_action_signals);
    try std.testing.expect(options.expect_cgroup_limits);
    try std.testing.expectEqual(@as(usize, 1), options.extra_out_files.items.len);
    try std.testing.expectEqualStrings("out/a.txt", options.extra_out_files.items[0]);
}

test "parseArgs accepts filesystem checks and declared output symlinks" {
    var options = try parseArgs(std.testing.allocator, &.{
        "--exercise-filesystem",
        "--out-symlink",
        "out/file.symlink",
        "--out-symlink-target",
        "file.txt",
        "--out-symlink",
        "out/directory.symlink",
        "--out-symlink-target",
        "directory",
    });
    defer options.deinit(std.testing.allocator);

    try std.testing.expect(options.exercise_filesystem);
    try std.testing.expectEqual(@as(usize, 2), options.out_symlinks.items.len);
    try std.testing.expectEqualStrings("out/file.symlink", options.out_symlinks.items[0].path);
    try std.testing.expectEqualStrings("file.txt", options.out_symlinks.items[0].target.?);
    try std.testing.expectEqualStrings("out/directory.symlink", options.out_symlinks.items[1].path);
    try std.testing.expectEqualStrings("directory", options.out_symlinks.items[1].target.?);
}

test "parseArgs accepts a detached deadline regression" {
    var options = try parseArgs(std.testing.allocator, &.{
        "--escape-process-group",
        "--sleep-ms",
        "30000",
    });
    defer options.deinit(std.testing.allocator);

    try std.testing.expect(options.escape_process_group);
    try std.testing.expectEqual(@as(i64, 30_000), options.sleep_ms.?);
    try std.testing.expectError(error.InvalidSleepDuration, parseArgs(std.testing.allocator, &.{ "--sleep-ms", "-1" }));
}

test "parseArgs rejects incomplete declared output symlinks" {
    try std.testing.expectError(error.MissingOutputSymlinkTarget, parseArgs(std.testing.allocator, &.{
        "--out-symlink",
        "out/file.symlink",
    }));
    try std.testing.expectError(error.MissingOutputSymlink, parseArgs(std.testing.allocator, &.{
        "--out-symlink-target",
        "file.txt",
    }));
    try std.testing.expectError(error.DuplicateOutputSymlinkTarget, parseArgs(std.testing.allocator, &.{
        "--out-symlink",
        "out/file.symlink",
        "--out-symlink-target",
        "file.txt",
        "--out-symlink-target",
        "another.txt",
    }));
}

test "network block source address classifier allows only unspecified and loopback" {
    try std.testing.expect(isBlockedLocalIpv4(std.mem.nativeToBig(u32, 0x00000000)));
    try std.testing.expect(isBlockedLocalIpv4(std.mem.nativeToBig(u32, 0x7f000001)));
    try std.testing.expect(!isBlockedLocalIpv4(std.mem.nativeToBig(u32, 0x0a000001)));
    try std.testing.expect(!isBlockedLocalIpv4(std.mem.nativeToBig(u32, 0xc0a80102)));
}
