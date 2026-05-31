const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("actiond_build_options");
const cas = @import("cas.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    MissingArgv,
    UnsupportedHost,
};

const max_stream_bytes = 16 * 1024 * 1024;
const cgroup_period_us: u64 = 100_000;
const child_poll_timeout_ms = 100;

inline fn runnerTimingNow(io: std.Io) std.Io.Timestamp {
    return if (comptime build_options.executor_timing_logs)
        std.Io.Clock.awake.now(io)
    else
        undefined;
}

fn actionNamespaceFlags() usize {
    const linux = std.os.linux;
    return linux.CLONE.NEWNS | linux.CLONE.NEWNET;
}

pub const CgroupLimits = struct {
    memory_max_bytes: ?u64 = null,
    cpu_max_cores: ?u32 = null,
    pids_max: ?u32 = null,

    pub fn any(self: CgroupLimits) bool {
        return self.memory_max_bytes != null or self.cpu_max_cores != null or self.pids_max != null;
    }

    pub fn fromPlatform(platform: ?reapi.Platform) CgroupLimits {
        var out: CgroupLimits = .{};
        const value = platform orelse return out;
        for (value.properties) |property| {
            if (isMemoryProperty(property.name)) {
                out.memory_max_bytes = parseByteSize(property.value) catch out.memory_max_bytes;
            } else if (isCpuProperty(property.name)) {
                out.cpu_max_cores = std.fmt.parseInt(u32, property.value, 10) catch out.cpu_max_cores;
            } else if (isPidsProperty(property.name)) {
                out.pids_max = std.fmt.parseInt(u32, property.value, 10) catch out.pids_max;
            }
        }
        return out;
    }
};

pub const RunOptions = struct {
    chroot_dir: []const u8,
    chroot_cwd: []const u8 = "/",
    exec_path_override: ?[]const u8 = null,
    bind_mounts: []const BindMount = &.{},
    actiondfs_mounts: []const ActiondfsMount = &.{},
    cgroup_limits: CgroupLimits = .{},
    sandbox_uid: u32 = 65534,
    sandbox_gid: u32 = 65534,
};

pub const BindMount = struct {
    source: [:0]u8,
    target: [:0]u8,
};

pub const ActiondfsMount = union(enum) {
    strict: ActiondfsStrictMount,
    overlay: ActiondfsOverlayMount,
};

pub const ActiondfsStrictMount = struct {
    fstype: [:0]const u8,
    target: [:0]u8,
    stage_dir: [:0]u8,
    actiondfs_data: [:0]u8,
};

pub const ActiondfsOverlayMount = struct {
    fstype: [:0]const u8,
    lower_target: [:0]u8,
    overlay_target: [:0]u8,
    upperdir: [:0]u8,
    actiondfs_data: [:0]u8,
    overlay_data: [:0]u8,
};

pub const Status = union(enum) {
    exited: u8,
    signaled: u8,
    stopped,
    unknown,
};

pub const Outcome = struct {
    pub const OutputFile = struct {
        path: []u8,
        digest: cas.Digest,
        is_executable: bool = false,
    };

    pub const OutputDirectory = struct {
        path: []u8,
        tree_digest: cas.Digest,
        root_directory_digest: ?cas.Digest = null,
    };

    status: Status,
    stdout: []u8,
    stderr: []u8,
    stdout_digest: ?cas.Digest = null,
    stderr_digest: ?cas.Digest = null,
    output_files: []OutputFile = &.{},
    output_directories: []OutputDirectory = &.{},
    execution_metadata: ?reapi.ExecutedActionMetadata = null,
    runner_timing: ?RunTiming = null,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        for (self.output_files) |output_file| allocator.free(output_file.path);
        for (self.output_directories) |output_directory| allocator.free(output_directory.path);
        allocator.free(self.output_files);
        allocator.free(self.output_directories);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const RunTiming = struct {
    parent_prepare_ns: i96,
    fork_ns: i96,
    child_setup_ns: i96,
    process_io_ns: i96,
    wait_ns: i96,
    stdio_digest_ns: i96,
    bind_mounts: usize,
    actiondfs_mounts: usize,
    setup_signaled: bool,
};

pub fn runCommandWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    command: reapi.Command,
    options: RunOptions,
) !Outcome {
    if (command.arguments.len == 0) return error.MissingArgv;
    return runCommandChroot(io, allocator, store, command, options);
}

fn digestIfNonEmpty(io: std.Io, store: cas.Store, bytes: []const u8) !?cas.Digest {
    if (bytes.len == 0) return null;
    return try store.putBytes(io, bytes);
}

fn isMemoryProperty(name: []const u8) bool {
    return std.mem.eql(u8, name, "limits.memory.bytes") or
        std.mem.eql(u8, name, "memory") or
        std.mem.eql(u8, name, "memory_bytes") or
        std.mem.eql(u8, name, "resources:memory:bytes");
}

fn isCpuProperty(name: []const u8) bool {
    return std.mem.eql(u8, name, "limits.cpu.cores") or
        std.mem.eql(u8, name, "cpu") or
        std.mem.eql(u8, name, "cores") or
        std.mem.eql(u8, name, "resources:cpu:cores");
}

fn isPidsProperty(name: []const u8) bool {
    return std.mem.eql(u8, name, "limits.pids.max") or
        std.mem.eql(u8, name, "pids.max") or
        std.mem.eql(u8, name, "pids");
}

fn parseByteSize(value: []const u8) !u64 {
    if (value.len == 0) return error.InvalidCharacter;
    const suffix = value[value.len - 1];
    const multiplier: u64 = switch (suffix) {
        'k', 'K' => 1024,
        'm', 'M' => 1024 * 1024,
        'g', 'G' => 1024 * 1024 * 1024,
        else => 1,
    };
    const number = if (multiplier == 1) value else value[0 .. value.len - 1];
    return try std.math.mul(u64, try std.fmt.parseInt(u64, number, 10), multiplier);
}

var next_cgroup_id = std.atomic.Value(u64).init(0);

const Cgroup = struct {
    path: ?[]u8 = null,
    procs_path: ?[:0]u8 = null,

    fn create(io: std.Io, allocator: std.mem.Allocator, limits: CgroupLimits) !Cgroup {
        if (comptime builtin.os.tag != .linux) return .{};
        if (!limits.any()) return .{};

        var root = std.Io.Dir.openDirAbsolute(io, "/sys/fs/cgroup", .{}) catch return .{};
        defer root.close(io);

        root.createDirPath(io, "actiond") catch return .{};
        root.writeFile(io, .{
            .sub_path = "cgroup.subtree_control",
            .data = "+cpu +memory +pids",
        }) catch {};

        const id = next_cgroup_id.fetchAdd(1, .monotonic);
        const path = try std.fmt.allocPrint(allocator, "actiond/action-{d}", .{id});
        errdefer allocator.free(path);
        root.createDirPath(io, path) catch return .{};

        if (limits.memory_max_bytes) |value| {
            writeCgroupValue(io, allocator, root, path, "memory.max", "{d}", .{value}) catch {
                root.deleteTree(io, path) catch {};
                allocator.free(path);
                return .{};
            };
        }
        if (limits.cpu_max_cores) |value| {
            const quota = @as(u64, value) * cgroup_period_us;
            writeCgroupValue(io, allocator, root, path, "cpu.max", "{d} {d}", .{ quota, cgroup_period_us }) catch {
                root.deleteTree(io, path) catch {};
                allocator.free(path);
                return .{};
            };
        }
        if (limits.pids_max) |value| {
            writeCgroupValue(io, allocator, root, path, "pids.max", "{d}", .{value}) catch {
                root.deleteTree(io, path) catch {};
                allocator.free(path);
                return .{};
            };
        }

        const procs_path = try std.fmt.allocPrintSentinel(allocator, "/sys/fs/cgroup/{s}/cgroup.procs", .{path}, 0);
        errdefer allocator.free(procs_path);
        return .{
            .path = path,
            .procs_path = procs_path,
        };
    }

    fn kill(self: Cgroup, io: std.Io, allocator: std.mem.Allocator) void {
        const path = self.path orelse return;
        if (std.Io.Dir.openDirAbsolute(io, "/sys/fs/cgroup", .{})) |root| {
            var mutable_root = root;
            defer mutable_root.close(io);
            const kill_path = std.fmt.allocPrint(allocator, "{s}/cgroup.kill", .{path}) catch return;
            defer allocator.free(kill_path);
            mutable_root.writeFile(io, .{
                .sub_path = kill_path,
                .data = "1",
            }) catch {};
        } else |_| {}
    }

    fn deinit(self: *Cgroup, io: std.Io, allocator: std.mem.Allocator) void {
        if (self.path) |path| {
            self.kill(io, allocator);
            if (std.Io.Dir.openDirAbsolute(io, "/sys/fs/cgroup", .{})) |root| {
                var mutable_root = root;
                defer mutable_root.close(io);
                mutable_root.deleteTree(io, path) catch {};
            } else |_| {}
            allocator.free(path);
        }
        if (self.procs_path) |path| allocator.free(path);
        self.* = .{};
    }
};

fn writeCgroupValue(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    dir_path: []const u8,
    file_name: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name });
    defer allocator.free(path);
    const value = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(value);
    try root.writeFile(io, .{
        .sub_path = path,
        .data = value,
    });
}

fn prepareChrootWritableDirs(
    io: std.Io,
    chroot_dir: []const u8,
    uid: u32,
    gid: u32,
) !void {
    if (comptime builtin.os.tag != .linux) return;
    if (std.os.linux.geteuid() != 0) return;

    var root = try std.Io.Dir.openDirAbsolute(io, chroot_dir, .{ .iterate = true });
    defer root.close(io);
    try makeDirectoryWritableBySandbox(root.handle, uid, gid);
    try prepareChrootWritableSubdirs(io, root, uid, gid);
}

fn prepareChrootWritableSubdirs(
    io: std.Io,
    dir: std.Io.Dir,
    uid: u32,
    gid: u32,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var child = try dir.openDir(io, entry.name, .{ .iterate = true });
        errdefer child.close(io);
        try makeDirectoryWritableBySandbox(child.handle, uid, gid);
        try prepareChrootWritableSubdirs(io, child, uid, gid);
        child.close(io);
    }
}

fn makeDirectoryWritableBySandbox(fd: std.posix.fd_t, uid: u32, gid: u32) !void {
    const linux = std.os.linux;
    switch (std.posix.errno(linux.fchown(fd, @intCast(uid), @intCast(gid)))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    switch (std.posix.errno(linux.fchmod(fd, 0o755))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn runCommandChroot(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    command: reapi.Command,
    options: RunOptions,
) !Outcome {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;
    const runner_start = runnerTimingNow(io);
    const chroot_dir = options.chroot_dir;

    var cgroup = try Cgroup.create(io, allocator, options.cgroup_limits);
    defer cgroup.deinit(io, allocator);
    try prepareChrootWritableDirs(io, allocator, chroot_dir, options.sandbox_uid, options.sandbox_gid);
    for (options.actiondfs_mounts) |mount| {
        switch (mount) {
            .strict => |strict| try prepareChrootWritableDirs(io, strict.stage_dir, options.sandbox_uid, options.sandbox_gid),
            .overlay => |overlay| try prepareChrootWritableDirs(io, overlay.upperdir, options.sandbox_uid, options.sandbox_gid),
        }
    }

    const exec_path = if (options.exec_path_override) |path|
        try allocator.dupe(u8, path)
    else
        try resolveExecPath(io, allocator, command, chroot_dir);
    defer allocator.free(exec_path);

    const chroot_z = try allocator.dupeZ(u8, chroot_dir);
    defer allocator.free(chroot_z);
    const cwd_z = try allocator.dupeZ(u8, options.chroot_cwd);
    defer allocator.free(cwd_z);
    const exec_z = try allocator.dupeZ(u8, exec_path);
    defer allocator.free(exec_z);

    const argv = try allocator.allocSentinel(?[*:0]const u8, command.arguments.len, null);
    defer allocator.free(argv);
    var argv_strings: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (argv_strings.items) |arg| allocator.free(arg);
        argv_strings.deinit(allocator);
    }
    argv[0] = exec_z.ptr;
    for (command.arguments[1..], 1..) |arg, i| {
        const value = try allocator.dupeZ(u8, arg);
        try argv_strings.append(allocator, value);
        argv[i] = value.ptr;
    }

    const envp = try allocator.allocSentinel(?[*:0]const u8, command.environment_variables.len, null);
    defer allocator.free(envp);
    var env_strings: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (env_strings.items) |env| allocator.free(env);
        env_strings.deinit(allocator);
    }
    for (command.environment_variables, 0..) |variable, i| {
        const value = try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ variable.name, variable.value }, 0);
        try env_strings.append(allocator, value);
        envp[i] = value.ptr;
    }

    const stdin_pipe = try linuxPipe();
    errdefer closePipe(stdin_pipe);
    const stdout_pipe = try linuxPipe();
    errdefer closePipe(stdout_pipe);
    const stderr_pipe = try linuxPipe();
    errdefer closePipe(stderr_pipe);
    const setup_pipe = try linuxPipe();
    errdefer closePipe(setup_pipe);

    const fork_start = runnerTimingNow(io);
    const pid = try forkAction(.{
        .stdin_pipe = stdin_pipe,
        .stdout_pipe = stdout_pipe,
        .stderr_pipe = stderr_pipe,
        .setup_pipe = setup_pipe,
        .chroot_dir = chroot_z,
        .cwd = cwd_z,
        .exec_path = exec_z,
        .argv = argv.ptr,
        .envp = envp.ptr,
        .bind_mounts = options.bind_mounts,
        .actiondfs_mounts = options.actiondfs_mounts,
        .cgroup_procs_path = if (cgroup.procs_path) |path| path.ptr else null,
        .sandbox_uid = options.sandbox_uid,
        .sandbox_gid = options.sandbox_gid,
    });
    const fork_completed = runnerTimingNow(io);
    var child_waited = false;
    errdefer if (!child_waited) terminateChild(io, allocator, pid, cgroup);

    closeFd(stdin_pipe[0]);
    closeFd(stdin_pipe[1]);
    closeFd(stdout_pipe[1]);
    closeFd(stderr_pipe[1]);
    closeFd(setup_pipe[1]);
    errdefer {
        closeFd(stdout_pipe[0]);
        closeFd(stderr_pipe[0]);
        closeFd(setup_pipe[0]);
    }

    const setup_signaled = try readSetupSignal(setup_pipe[0]);
    closeFd(setup_pipe[0]);
    const setup_completed = runnerTimingNow(io);

    const child_result = try collectChildResult(io, allocator, stdout_pipe[0], stderr_pipe[0], pid, cgroup);
    const streams_completed = child_result.streams_completed;
    const wait_completed = child_result.wait_completed;
    child_waited = true;
    errdefer {
        allocator.free(child_result.stdout);
        allocator.free(child_result.stderr);
    }

    const digest_start = wait_completed;
    const stdout_digest = try digestIfNonEmpty(io, store, child_result.stdout);
    const stderr_digest = try digestIfNonEmpty(io, store, child_result.stderr);
    const digest_completed = runnerTimingNow(io);
    return .{
        .status = child_result.status,
        .stdout = child_result.stdout,
        .stderr = child_result.stderr,
        .stdout_digest = stdout_digest,
        .stderr_digest = stderr_digest,
        .runner_timing = if (comptime build_options.executor_timing_logs) .{
            .parent_prepare_ns = elapsedNs(runner_start, fork_start),
            .fork_ns = elapsedNs(fork_start, fork_completed),
            .child_setup_ns = elapsedNs(fork_completed, setup_completed),
            .process_io_ns = elapsedNs(setup_completed, streams_completed),
            .wait_ns = elapsedNs(streams_completed, wait_completed),
            .stdio_digest_ns = elapsedNs(digest_start, digest_completed),
            .bind_mounts = options.bind_mounts.len,
            .actiondfs_mounts = options.actiondfs_mounts.len,
            .setup_signaled = setup_signaled,
        } else null,
    };
}

const ForkAction = struct {
    stdin_pipe: [2]std.posix.fd_t,
    stdout_pipe: [2]std.posix.fd_t,
    stderr_pipe: [2]std.posix.fd_t,
    setup_pipe: [2]std.posix.fd_t,
    chroot_dir: [:0]const u8,
    cwd: [:0]const u8,
    exec_path: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    bind_mounts: []const BindMount,
    actiondfs_mounts: []const ActiondfsMount,
    cgroup_procs_path: ?[*:0]const u8,
    sandbox_uid: u32,
    sandbox_gid: u32,
};

const child_setup_fd: std.posix.fd_t = 3;

fn forkAction(action: ForkAction) !std.os.linux.pid_t {
    const linux = std.os.linux;
    const rc = linux.fork();
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    const pid: std.os.linux.pid_t = @intCast(rc);
    if (pid != 0) return pid;

    childDup2(action.stdin_pipe[0], std.posix.STDIN_FILENO);
    childDup2(action.stdout_pipe[1], std.posix.STDOUT_FILENO);
    childDup2(action.stderr_pipe[1], std.posix.STDERR_FILENO);
    childClose(action.stdin_pipe[0]);
    childClose(action.stdin_pipe[1]);
    childClose(action.stdout_pipe[0]);
    childClose(action.stdout_pipe[1]);
    childClose(action.stderr_pipe[0]);
    childClose(action.stderr_pipe[1]);
    childClose(action.setup_pipe[0]);
    if (action.setup_pipe[1] != child_setup_fd) {
        childDup2(action.setup_pipe[1], child_setup_fd);
        childClose(action.setup_pipe[1]);
    }

    childSyscallName(linux.setpgid(0, 0), "setpgid");
    if (action.cgroup_procs_path) |path| childWriteFile(path, "0\n");
    childSyscallName(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0), "prctl_no_new_privs");
    childCloseExtraFdsFrom(child_setup_fd + 1);
    childSyscallName(linux.unshare(actionNamespaceFlags()), "unshare_namespaces");
    childBringUpLoopback();
    childSyscallName(linux.mount(null, "/", null, linux.MS.PRIVATE | linux.MS.REC, 0), "mount_private");
    for (action.actiondfs_mounts) |mount| switch (mount) {
        .strict => |strict| childMountActiondfsStrict(strict),
        .overlay => |overlay| childMountActiondfsOverlay(overlay),
    };
    for (action.bind_mounts) |mount| childBindMountReadOnly(mount);
    childSyscallName(linux.chroot(action.chroot_dir.ptr), "chroot");
    childSyscallName(linux.chdir(action.cwd.ptr), "chdir");
    childDropPrivileges(action.sandbox_uid, action.sandbox_gid);
    childWriteSetupComplete();
    const execve_rc = linux.execve(action.exec_path.ptr, action.argv, action.envp);
    childWriteLiteral("actiond child setup failed: execve ");
    childWriteBytes(@tagName(std.posix.errno(execve_rc)));
    childWriteLiteral("\n");
    linux.exit(127);
}

fn childMountActiondfsStrict(mount: ActiondfsStrictMount) void {
    const linux = std.os.linux;
    childSyscallName(linux.mount(
        mount.fstype.ptr,
        mount.target.ptr,
        mount.fstype.ptr,
        linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOATIME,
        @intFromPtr(mount.actiondfs_data.ptr),
    ), "mount_actiondfs_strict");
}

fn childMountActiondfsOverlay(mount: ActiondfsOverlayMount) void {
    const linux = std.os.linux;
    childSyscallName(linux.mount(
        mount.fstype.ptr,
        mount.lower_target.ptr,
        mount.fstype.ptr,
        linux.MS.RDONLY | linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOATIME,
        @intFromPtr(mount.actiondfs_data.ptr),
    ), "mount_actiondfs");
    childSyscallName(linux.mount(
        "overlay",
        mount.overlay_target.ptr,
        "overlay",
        linux.MS.NOSUID | linux.MS.NODEV,
        @intFromPtr(mount.overlay_data.ptr),
    ), "mount_overlay");
}

fn childBringUpLoopback() void {
    const linux = std.os.linux;
    const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    childSyscallName(socket_rc, "socket_loopback");
    const fd: std.posix.fd_t = @intCast(socket_rc);
    defer childClose(fd);

    var ifr: linux.ifreq = std.mem.zeroes(linux.ifreq);
    @memcpy(ifr.ifrn.name[0.."lo".len], "lo");
    childSyscallName(linux.ioctl(fd, linux.SIOCGIFFLAGS, @intFromPtr(&ifr)), "ioctl_get_loopback");
    ifr.ifru.flags.UP = true;
    childSyscallName(linux.ioctl(fd, linux.SIOCSIFFLAGS, @intFromPtr(&ifr)), "ioctl_set_loopback");
}

fn childBindMountReadOnly(mount: BindMount) void {
    const linux = std.os.linux;
    childSyscallName(linux.mount(mount.source.ptr, mount.target.ptr, null, linux.MS.BIND, 0), "mount_bind");
    childSyscallName(linux.mount(
        null,
        mount.target.ptr,
        null,
        linux.MS.BIND | linux.MS.REMOUNT | linux.MS.RDONLY | linux.MS.NOSUID | linux.MS.NODEV,
        0,
    ), "mount_bind_ro");
}

const linux_capability_version_3: u32 = 0x20080522;

fn childDropPrivileges(uid: u32, gid: u32) void {
    const linux = std.os.linux;
    var empty_groups = [_]linux.gid_t{0};
    childSyscallName(linux.setgroups(0, &empty_groups), "setgroups");
    childSyscallName(linux.setresgid(@intCast(gid), @intCast(gid), @intCast(gid)), "setresgid");
    childSyscallName(linux.setresuid(@intCast(uid), @intCast(uid), @intCast(uid)), "setresuid");

    var header = linux.cap_user_header_t{
        .version = linux_capability_version_3,
        .pid = 0,
    };
    const data = [_]linux.cap_user_data_t{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };
    _ = linux.capset(&header, &data[0]);
}

fn childDup2(old: std.posix.fd_t, new: std.posix.fd_t) void {
    childSyscallName(std.os.linux.dup2(old, new), "dup2");
}

fn childClose(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.os.linux.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

fn childCloseExtraFdsFrom(first_fd: std.posix.fd_t) void {
    const rc = std.os.linux.close_range(@intCast(first_fd), std.math.maxInt(std.posix.fd_t), .{
        .UNSHARE = true,
        .CLOEXEC = false,
    });
    switch (std.posix.errno(rc)) {
        .SUCCESS, .NOSYS, .INVAL, .PERM => return,
        else => return,
    }
}

fn childWriteSetupComplete() void {
    _ = std.os.linux.write(child_setup_fd, "1", 1);
    childClose(child_setup_fd);
}

fn childWriteFile(path: [*:0]const u8, bytes: []const u8) void {
    const linux = std.os.linux;
    const fd_rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    childSyscallName(fd_rc, "open_cgroup");
    const fd: std.posix.fd_t = @intCast(fd_rc);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) linux.exit(127);
                offset += n;
            },
            .INTR => continue,
            else => linux.exit(127),
        }
    }
    childClose(fd);
}

fn childSyscallName(rc: usize, comptime name: []const u8) void {
    if (std.posix.errno(rc) == .SUCCESS) return;
    childWriteLiteral("actiond child setup failed: " ++ name ++ "\n");
    std.os.linux.exit(127);
}

fn childWriteLiteral(comptime bytes: []const u8) void {
    _ = std.os.linux.write(std.posix.STDERR_FILENO, bytes.ptr, bytes.len);
}

fn childWriteBytes(bytes: []const u8) void {
    _ = std.os.linux.write(std.posix.STDERR_FILENO, bytes.ptr, bytes.len);
}

fn linuxPipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true }))) {
        .SUCCESS => return fds,
        .NFILE, .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn closePipe(pipe: [2]std.posix.fd_t) void {
    closeFd(pipe[0]);
    closeFd(pipe[1]);
}

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.os.linux.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

fn terminateChild(
    io: std.Io,
    allocator: std.mem.Allocator,
    pid: std.os.linux.pid_t,
    cgroup: Cgroup,
) void {
    terminateActionProcesses(io, allocator, pid, cgroup);
    _ = waitForPid(pid) catch {};
}

fn terminateActionProcesses(
    io: std.Io,
    allocator: std.mem.Allocator,
    pid: std.os.linux.pid_t,
    cgroup: Cgroup,
) void {
    const linux = std.os.linux;
    cgroup.kill(io, allocator);
    _ = linux.kill(-pid, .KILL);
    _ = linux.kill(pid, .KILL);
}

const ChildResult = struct {
    stdout: []u8,
    stderr: []u8,
    status: Status,
    streams_completed: std.Io.Timestamp,
    wait_completed: std.Io.Timestamp,
};

fn collectChildResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout_fd: std.posix.fd_t,
    stderr_fd: std.posix.fd_t,
    pid: std.os.linux.pid_t,
    cgroup: Cgroup,
) !ChildResult {
    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stderr.deinit(allocator);

    var poll_fds = [_]std.os.linux.pollfd{
        .{ .fd = stdout_fd, .events = std.os.linux.POLL.IN | std.os.linux.POLL.HUP | std.os.linux.POLL.ERR, .revents = 0 },
        .{ .fd = stderr_fd, .events = std.os.linux.POLL.IN | std.os.linux.POLL.HUP | std.os.linux.POLL.ERR, .revents = 0 },
    };
    var open_count: usize = 2;
    var status: ?Status = null;
    var waited_while_streams_open = false;

    while (open_count != 0) {
        if (status == null) {
            if (try waitForPidNoHang(pid)) |value| {
                status = value;
                waited_while_streams_open = true;
                terminateActionProcesses(io, allocator, pid, cgroup);
            }
        }

        const rc = std.os.linux.poll(&poll_fds, poll_fds.len, child_poll_timeout_ms);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Unexpected,
        }

        if (poll_fds[0].fd >= 0 and poll_fds[0].revents != 0) {
            if (try readPipeChunk(allocator, poll_fds[0].fd, &stdout)) {
                closeFd(poll_fds[0].fd);
                poll_fds[0].fd = -1;
                open_count -= 1;
            }
        }
        if (poll_fds[1].fd >= 0 and poll_fds[1].revents != 0) {
            if (try readPipeChunk(allocator, poll_fds[1].fd, &stderr)) {
                closeFd(poll_fds[1].fd);
                poll_fds[1].fd = -1;
                open_count -= 1;
            }
        }

        if (status == null) {
            if (try waitForPidNoHang(pid)) |value| {
                status = value;
                waited_while_streams_open = true;
                terminateActionProcesses(io, allocator, pid, cgroup);
            }
        }
    }

    const streams_completed = runnerTimingNow(io);
    const final_status = status orelse try waitForPid(pid);
    const wait_completed = if (waited_while_streams_open)
        streams_completed
    else
        runnerTimingNow(io);

    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .status = final_status,
        .streams_completed = streams_completed,
        .wait_completed = wait_completed,
    };
}

fn readSetupSignal(fd: std.posix.fd_t) !bool {
    var byte: [1]u8 = undefined;
    while (true) {
        const rc = std.os.linux.read(fd, byte[0..].ptr, byte.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return rc == 1,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn readPipeChunk(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    out: *std.ArrayListUnmanaged(u8),
) !bool {
    var buffer: [16 * 1024]u8 = undefined;
    const rc = std.os.linux.read(fd, buffer[0..].ptr, buffer.len);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {
            const n: usize = @intCast(rc);
            if (n == 0) return true;
            if (out.items.len + n > max_stream_bytes) return error.StreamTooLong;
            try out.appendSlice(allocator, buffer[0..n]);
            return false;
        },
        .INTR => return false,
        else => return error.Unexpected,
    }
}

fn elapsedNs(start: std.Io.Timestamp, end: std.Io.Timestamp) i96 {
    return start.durationTo(end).nanoseconds;
}

fn waitForPid(pid: std.os.linux.pid_t) !Status {
    var raw_status: u32 = 0;
    while (true) {
        const rc = std.os.linux.waitpid(pid, &raw_status, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }

    return statusFromRawWait(raw_status);
}

fn waitForPidNoHang(pid: std.os.linux.pid_t) !?Status {
    var raw_status: u32 = 0;
    while (true) {
        const rc = std.os.linux.waitpid(pid, &raw_status, std.os.linux.W.NOHANG);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                break;
            },
            .INTR => continue,
            else => return error.Unexpected,
        }
    }

    return statusFromRawWait(raw_status);
}

fn statusFromRawWait(raw_status: u32) Status {
    if (std.os.linux.W.IFEXITED(raw_status)) {
        return .{ .exited = std.os.linux.W.EXITSTATUS(raw_status) };
    }
    if (std.os.linux.W.IFSIGNALED(raw_status)) {
        return .{ .signaled = @intCast(@intFromEnum(std.os.linux.W.TERMSIG(raw_status))) };
    }
    if (std.os.linux.W.IFSTOPPED(raw_status)) return .stopped;
    return .unknown;
}

fn resolveExecPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: reapi.Command,
    chroot_dir: []const u8,
) ![]u8 {
    const argv0 = command.arguments[0];
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) return allocator.dupe(u8, argv0);

    const path_value = commandPath(command) orelse "/usr/local/bin:/usr/bin:/bin";
    var parts = std.mem.splitScalar(u8, path_value, ':');
    while (parts.next()) |part| {
        const prefix = if (part.len == 0) "/" else part;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, argv0 });
        errdefer allocator.free(candidate);
        const host_candidate = if (std.fs.path.isAbsolute(candidate))
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ chroot_dir, candidate })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ chroot_dir, candidate });
        defer allocator.free(host_candidate);

        std.Io.Dir.cwd().access(io, host_candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(candidate);
                continue;
            },
            else => |e| return e,
        };
        return candidate;
    }
    return allocator.dupe(u8, argv0);
}

fn commandPath(command: reapi.Command) ?[]const u8 {
    for (command.environment_variables) |variable| {
        if (std.mem.eql(u8, variable.name, "PATH")) return variable.value;
    }
    return null;
}

test "CgroupLimits parses REAPI platform execution properties" {
    const limits = CgroupLimits.fromPlatform(.{
        .properties = &.{
            .{ .name = "limits.memory.bytes", .value = "128M" },
            .{ .name = "limits.cpu.cores", .value = "2" },
            .{ .name = "limits.pids.max", .value = "64" },
        },
    });

    try std.testing.expect(limits.any());
    try std.testing.expectEqual(@as(u64, 128 * 1024 * 1024), limits.memory_max_bytes.?);
    try std.testing.expectEqual(@as(u32, 2), limits.cpu_max_cores.?);
    try std.testing.expectEqual(@as(u32, 64), limits.pids_max.?);
}

test "CgroupLimits ignores invalid execution property values" {
    const limits = CgroupLimits.fromPlatform(.{
        .properties = &.{
            .{ .name = "memory", .value = "bad" },
            .{ .name = "cpu", .value = "bad" },
            .{ .name = "pids", .value = "bad" },
        },
    });

    try std.testing.expect(!limits.any());
}

test "action namespace flags isolate mounts and networking" {
    const linux = std.os.linux;
    const flags = actionNamespaceFlags();
    try std.testing.expect((flags & linux.CLONE.NEWNS) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWNET) != 0);
}

test "runCommandWithOptions rejects chroot execution on non-Linux hosts" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    try std.testing.expectError(error.UnsupportedHost, runCommandWithOptions(
        std.testing.io,
        std.testing.allocator,
        store,
        .{ .arguments = &.{"/tool"} },
        .{ .chroot_dir = "/" },
    ));
}
