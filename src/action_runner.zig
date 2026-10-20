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
const child_exit_poll_timeout_ms = 1;
const classic_bpf_load_absolute_word: u16 = 0x20;
const classic_bpf_jump_equal_constant: u16 = 0x15;
const classic_bpf_bitwise_and_constant: u16 = 0x54;
const classic_bpf_return_constant: u16 = 0x06;
const x86_x32_syscall_bit: u32 = 0x40000000;
const audit_arch_aarch64: u32 = 0xc00000b7;
const audit_arch_x86_64: u32 = 0xc000003e;
const child_setup_frame_length = 1 + @sizeOf(u32);
const child_setup_ready_tag: u8 = 'R';
const child_setup_exec_failure_tag: u8 = 'X';

const SeccompFilterInstruction = extern struct {
    code: u16,
    jump_true: u8,
    jump_false: u8,
    data: u32,
};

const SeccompFilterProgram = extern struct {
    length: u16,
    instructions: [*]const SeccompFilterInstruction,
};

inline fn runnerTimingNow(io: std.Io) std.Io.Timestamp {
    return if (comptime build_options.executor_timing_logs)
        std.Io.Clock.awake.now(io)
    else
        undefined;
}

fn actionNamespaceFlags() usize {
    const linux = std.os.linux;
    return linux.CLONE.NEWNS | linux.CLONE.NEWNET | linux.CLONE.NEWPID;
}

fn actionCloneFlags() u32 {
    return @intCast(actionNamespaceFlags() | @intFromEnum(std.os.linux.SIG.CHLD));
}

pub const CgroupLimits = struct {
    memory_max_bytes: ?u64 = null,
    cpu_max_cores: ?u32 = null,
    pids_max: ?u32 = null,
    invalid: bool = false,

    pub fn any(self: CgroupLimits) bool {
        return self.memory_max_bytes != null or self.cpu_max_cores != null or self.pids_max != null;
    }

    pub fn fromPlatform(platform: ?reapi.Platform) CgroupLimits {
        var out: CgroupLimits = .{};
        const value = platform orelse return out;
        for (value.properties) |property| {
            if (isMemoryProperty(property.name)) {
                out.memory_max_bytes = parseByteSize(property.value) catch {
                    out.invalid = true;
                    continue;
                };
            } else if (isCpuProperty(property.name)) {
                const cores = std.fmt.parseInt(u32, property.value, 10) catch {
                    out.invalid = true;
                    continue;
                };
                if (cores == 0) {
                    out.invalid = true;
                    continue;
                }
                out.cpu_max_cores = cores;
            } else if (isPidsProperty(property.name)) {
                out.pids_max = std.fmt.parseInt(u32, property.value, 10) catch {
                    out.invalid = true;
                    continue;
                };
            }
        }
        return out;
    }
};

pub const RunOptions = struct {
    chroot_dir: []const u8,
    chroot_cwd: []const u8 = "/",
    bind_mounts: []const BindMount = &.{},
    actiondfs_mounts: []const ActiondfsMount = &.{},
    cgroup_limits: CgroupLimits = .{},
    timeout_ns: ?u64 = null,
    cancellation: ?*const std.atomic.Value(bool) = null,
    sandbox_uid: u32 = 65534,
    sandbox_gid: u32 = 65534,
};

const ExecutionControl = struct {
    started: ?std.Io.Timestamp,
    timeout_ns: ?u64,
    cancellation: ?*const std.atomic.Value(bool),

    fn init(io: std.Io, options: RunOptions) ExecutionControl {
        return .{
            .started = if (options.timeout_ns != null) std.Io.Clock.awake.now(io) else null,
            .timeout_ns = options.timeout_ns,
            .cancellation = options.cancellation,
        };
    }

    fn check(self: ExecutionControl, io: std.Io) !void {
        if (self.cancellation) |cancellation| {
            if (cancellation.load(.acquire)) return error.ExecutionCancelled;
        }
        const timeout_ns = self.timeout_ns orelse return;
        const elapsed_ns = self.started.?.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        if (elapsed_ns >= @as(i96, @intCast(timeout_ns))) return error.ExecutionDeadlineExceeded;
    }

    fn pollTimeoutMilliseconds(self: ExecutionControl, io: std.Io) !i32 {
        try self.check(io);
        const timeout_ns = self.timeout_ns orelse return child_poll_timeout_ms;
        const elapsed_ns = self.started.?.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        const remaining_ns = @as(i96, @intCast(timeout_ns)) - elapsed_ns;
        if (remaining_ns <= 0) return error.ExecutionDeadlineExceeded;
        const remaining_ms = @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(@as(i96, child_poll_timeout_ms), remaining_ms));
    }

    fn bounded(self: ExecutionControl) bool {
        return self.timeout_ns != null or self.cancellation != null;
    }
};

pub const BindMount = struct {
    source: [:0]u8,
    target: [:0]u8,
    read_only: bool = true,
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

    pub const OutputSymlink = struct {
        path: []u8,
        target: []u8,
    };

    status: Status,
    stdout: []u8,
    stderr: []u8,
    stdout_digest: ?cas.Digest = null,
    stderr_digest: ?cas.Digest = null,
    output_files: []OutputFile = &.{},
    output_directories: []OutputDirectory = &.{},
    output_symlinks: []OutputSymlink = &.{},
    output_file_symlinks: []OutputSymlink = &.{},
    output_directory_symlinks: []OutputSymlink = &.{},
    execution_metadata: ?reapi.ExecutedActionMetadata = null,
    runner_timing: ?RunTiming = null,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        for (self.output_files) |output_file| allocator.free(output_file.path);
        for (self.output_directories) |output_directory| allocator.free(output_directory.path);
        for (self.output_symlinks) |output_symlink| {
            allocator.free(output_symlink.path);
            allocator.free(output_symlink.target);
        }
        for (self.output_file_symlinks) |output_symlink| {
            allocator.free(output_symlink.path);
            allocator.free(output_symlink.target);
        }
        for (self.output_directory_symlinks) |output_symlink| {
            allocator.free(output_symlink.path);
            allocator.free(output_symlink.target);
        }
        allocator.free(self.output_files);
        allocator.free(self.output_directories);
        allocator.free(self.output_symlinks);
        allocator.free(self.output_file_symlinks);
        allocator.free(self.output_directory_symlinks);
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
        if (limits.invalid) return error.InvalidCgroupLimit;
        if (!limits.any()) return .{};

        var root = try std.Io.Dir.openDirAbsolute(io, "/sys/fs/cgroup", .{});
        defer root.close(io);

        try root.createDirPath(io, "actiond");
        if (limits.memory_max_bytes != null) try enableCgroupController(io, root, "+memory");
        if (limits.cpu_max_cores != null) try enableCgroupController(io, root, "+cpu");
        if (limits.pids_max != null) try enableCgroupController(io, root, "+pids");

        const id = next_cgroup_id.fetchAdd(1, .monotonic);
        const path = try std.fmt.allocPrint(allocator, "actiond/action-{d}", .{id});
        errdefer allocator.free(path);
        try root.createDirPath(io, path);
        errdefer root.deleteTree(io, path) catch {};

        if (limits.memory_max_bytes) |value| {
            try writeCgroupValue(io, allocator, root, path, "memory.max", "{d}", .{value});
        }
        if (limits.cpu_max_cores) |value| {
            const quota = @as(u64, value) * cgroup_period_us;
            try writeCgroupValue(io, allocator, root, path, "cpu.max", "{d} {d}", .{ quota, cgroup_period_us });
        }
        if (limits.pids_max) |value| {
            try writeCgroupValue(io, allocator, root, path, "pids.max", "{d}", .{value});
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

fn enableCgroupController(io: std.Io, root: std.Io.Dir, controller: []const u8) !void {
    try root.writeFile(io, .{
        .sub_path = "cgroup.subtree_control",
        .data = controller,
    });
    try root.writeFile(io, .{
        .sub_path = "actiond/cgroup.subtree_control",
        .data = controller,
    });
}

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
    switch (std.os.linux.errno(linux.fchown(fd, @intCast(uid), @intCast(gid)))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    switch (std.os.linux.errno(linux.fchmod(fd, 0o755))) {
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
    const execution_control = ExecutionControl.init(io, options);
    try execution_control.check(io);
    const chroot_dir = options.chroot_dir;

    var cgroup = try Cgroup.create(io, allocator, options.cgroup_limits);
    defer cgroup.deinit(io, allocator);
    try prepareChrootWritableDirs(io, chroot_dir, options.sandbox_uid, options.sandbox_gid);
    for (options.actiondfs_mounts) |mount| {
        switch (mount) {
            .strict => |strict| try prepareChrootWritableDirs(io, strict.stage_dir, options.sandbox_uid, options.sandbox_gid),
            .overlay => |overlay| try prepareChrootWritableDirs(io, overlay.upperdir, options.sandbox_uid, options.sandbox_gid),
        }
    }

    const chroot_z = try allocator.dupeZ(u8, chroot_dir);
    defer allocator.free(chroot_z);
    const cwd_z = try allocator.dupeZ(u8, options.chroot_cwd);
    defer allocator.free(cwd_z);
    var exec_candidates: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (exec_candidates.items) |candidate| allocator.free(candidate);
        exec_candidates.deinit(allocator);
    }
    try appendExecCandidates(allocator, command, &exec_candidates);

    const argv = try allocator.allocSentinel(?[*:0]const u8, command.arguments.len, null);
    defer allocator.free(argv);
    var argv_strings: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (argv_strings.items) |arg| allocator.free(arg);
        argv_strings.deinit(allocator);
    }
    for (command.arguments, 0..) |arg, i| {
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

    var stdin_pipe = try OwnedPipe.init();
    defer stdin_pipe.deinit();
    var stdout_pipe = try OwnedPipe.init();
    defer stdout_pipe.deinit();
    var stderr_pipe = try OwnedPipe.init();
    defer stderr_pipe.deinit();
    var setup_pipe = try OwnedPipe.init();
    defer setup_pipe.deinit();

    try execution_control.check(io);
    const fork_start = runnerTimingNow(io);
    const pid = try forkAction(.{
        .stdin_pipe = stdin_pipe.borrow(),
        .stdout_pipe = stdout_pipe.borrow(),
        .stderr_pipe = stderr_pipe.borrow(),
        .setup_pipe = setup_pipe.borrow(),
        .chroot_dir = chroot_z,
        .cwd = cwd_z,
        .exec_candidates = exec_candidates.items,
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

    stdin_pipe.close(0);
    stdin_pipe.close(1);
    stdout_pipe.close(1);
    stderr_pipe.close(1);
    setup_pipe.close(1);

    const setup_signaled = try readSetupSignal(
        io,
        setup_pipe.endpoint(0),
        execution_control,
    );
    setup_pipe.close(0);
    if (!setup_signaled) return error.SandboxSetupFailed;
    const setup_completed = runnerTimingNow(io);

    const child_result = try collectChildResult(
        io,
        allocator,
        stdout_pipe.release(0),
        stderr_pipe.release(0),
        pid,
        cgroup,
        execution_control,
        &child_waited,
    );
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
    exec_candidates: []const [:0]u8,
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
    const rc = linux.clone2(actionCloneFlags(), 0);
    switch (std.os.linux.errno(rc)) {
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
    childSyscallName(linux.fcntl(child_setup_fd, linux.F.SETFD, linux.FD_CLOEXEC), "fcntl_setup_cloexec");

    childSyscallName(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0), "prctl_no_new_privs");
    childCloseExtraFdsFrom(child_setup_fd + 1);
    childEnterSandboxProcess();
    if (action.cgroup_procs_path) |path| childWriteFile(path, "0\n");
    childBringUpLoopback();
    childSyscallName(linux.mount(null, "/", null, linux.MS.PRIVATE | linux.MS.REC, 0), "mount_private");
    for (action.actiondfs_mounts) |mount| switch (mount) {
        .strict => |strict| childMountActiondfsStrict(strict),
        .overlay => |overlay| childMountActiondfsOverlay(overlay),
    };
    for (action.bind_mounts) |mount| childBindMount(mount);
    childSyscallName(linux.chroot(action.chroot_dir.ptr), "chroot");
    childSyscallName(linux.chdir("/"), "chdir_root");
    childSyscallName(linux.mount("proc", "/proc", "proc", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, 0), "mount_proc");
    childDropPrivileges(action.sandbox_uid, action.sandbox_gid);
    childSyscallName(linux.chdir(action.cwd.ptr), "chdir");
    childInstallSocketFilter();
    childRestoreSigpipeDefault();
    childWriteSetupComplete();
    var exec_errno: std.posix.E = .NOENT;
    var saw_access_denied = false;
    for (action.exec_candidates) |candidate| {
        const execve_rc = linux.execve(candidate.ptr, action.argv, action.envp);
        exec_errno = std.os.linux.errno(execve_rc);
        switch (exec_errno) {
            .NOENT, .NOTDIR => continue,
            .ACCES => {
                saw_access_denied = true;
                continue;
            },
            else => break,
        }
    }
    if (saw_access_denied and (exec_errno == .NOENT or exec_errno == .NOTDIR))
        exec_errno = .ACCES;
    childWriteLiteral("actiond child setup failed: execve ");
    childWriteBytes(@tagName(exec_errno));
    childWriteLiteral("\n");
    childWriteSetupFrame(child_setup_exec_failure_tag, @intFromEnum(exec_errno));
    linux.exit(127);
}

fn childEnterSandboxProcess() void {
    const linux = std.os.linux;
    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => {
            childWriteLiteral("actiond child setup failed: fork_sandbox\n");
            linux.exit(127);
        },
    }

    const pid: linux.pid_t = @intCast(rc);
    if (pid == 0) return;

    childClose(child_setup_fd);
    childWaitForProcess(pid);
}

fn childWaitForProcess(pid: std.os.linux.pid_t) noreturn {
    const linux = std.os.linux;
    var raw_status: u32 = 0;
    while (true) {
        const wait_rc = linux.waitpid(-1, &raw_status, 0);
        switch (std.os.linux.errno(wait_rc)) {
            .SUCCESS => {
                if (@as(linux.pid_t, @intCast(wait_rc)) == pid) break;
            },
            .INTR => continue,
            else => {
                childWriteLiteral("actiond child setup failed: waitpid_sandbox\n");
                linux.exit(127);
            },
        }
    }

    if (linux.W.IFEXITED(raw_status)) {
        linux.exit(linux.W.EXITSTATUS(raw_status));
    }
    if (linux.W.IFSIGNALED(raw_status)) {
        linux.exit(@intCast(128 + @intFromEnum(linux.W.TERMSIG(raw_status))));
    }
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

fn childBindMount(mount: BindMount) void {
    const linux = std.os.linux;
    childSyscallName(linux.mount(mount.source.ptr, mount.target.ptr, null, linux.MS.BIND, 0), "mount_bind");
    if (!mount.read_only) return;
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
    childSyscallName(linux.capset(&header, &data[0]), "capset");
}

fn childInstallSocketFilter() void {
    const linux = std.os.linux;
    const instructions = actionSeccompFilterInstructions();
    const program = SeccompFilterProgram{
        .length = instructions.len,
        .instructions = &instructions,
    };
    childSyscallName(linux.prctl(
        @intFromEnum(linux.PR.SET_SECCOMP),
        linux.SECCOMP.MODE.FILTER,
        @intFromPtr(&program),
        0,
        0,
    ), "prctl_seccomp_socket_filter");
}

fn actionAuditArchitecture() u32 {
    return switch (builtin.cpu.arch) {
        .aarch64 => audit_arch_aarch64,
        .x86_64 => audit_arch_x86_64,
        else => @compileError("action socket filter requires an audit architecture"),
    };
}

fn actionSeccompFilterInstructions() [19]SeccompFilterInstruction {
    const linux = std.os.linux;
    return .{
        .{ .code = classic_bpf_load_absolute_word, .jump_true = 0, .jump_false = 0, .data = 4 },
        .{ .code = classic_bpf_jump_equal_constant, .jump_true = 0, .jump_false = 15, .data = actionAuditArchitecture() },
        .{ .code = classic_bpf_load_absolute_word, .jump_true = 0, .jump_false = 0, .data = 0 },
        .{ .code = classic_bpf_bitwise_and_constant, .jump_true = 0, .jump_false = 0, .data = ~x86_x32_syscall_bit },
        .{ .code = classic_bpf_jump_equal_constant, .jump_true = 4, .jump_false = 0, .data = @intFromEnum(linux.SYS.socket) },
        .{ .code = classic_bpf_jump_equal_constant, .jump_true = 10, .jump_false = 0, .data = @intFromEnum(linux.SYS.io_uring_setup) },
        .{ .code = classic_bpf_jump_equal_constant, .jump_true = 9, .jump_false = 0, .data = @intFromEnum(linux.SYS.bpf) },
        .{ .code = classic_bpf_jump_equal_constant, .jump_true = 3, .jump_false = 0, .data = @intFromEnum(linux.SYS.setsockopt) },
        .{ .code = classic_bpf_return_constant, .jump_true = 0, .jump_false = 0, .data = linux.SECCOMP.RET.ALLOW },
        .{ .code = classic_bpf_load_absolute_word, .jump_true = 0, .jump_false = 0, .data = 16 },
        .{ .code = classic_bpf_jump_equal_constant, .jump_true = 5, .jump_false = 7, .data = linux.AF.VSOCK },
        .{ .code = classic_bpf_load_absolute_word, .jump_true = 0, .jump_false = 0, .data = 24 },
        .{ .code = classic_bpf_jump_equal_constant, .jump_true = 0, .jump_false = 5, .data = linux.SOL.SOCKET },
        .{ .code = classic_bpf_load_absolute_word, .jump_true = 0, .jump_false = 0, .data = 32 },
        .{ .code = classic_bpf_jump_equal_constant, .jump_true = 1, .jump_false = 0, .data = linux.SO.ATTACH_FILTER },
        .{ .code = classic_bpf_jump_equal_constant, .jump_true = 0, .jump_false = 2, .data = linux.SO.ATTACH_REUSEPORT_CBPF },
        .{ .code = classic_bpf_return_constant, .jump_true = 0, .jump_false = 0, .data = @as(u32, linux.SECCOMP.RET.ERRNO) | @as(u32, @intFromEnum(std.posix.E.PERM)) },
        .{ .code = classic_bpf_return_constant, .jump_true = 0, .jump_false = 0, .data = linux.SECCOMP.RET.KILL_PROCESS },
        .{ .code = classic_bpf_return_constant, .jump_true = 0, .jump_false = 0, .data = linux.SECCOMP.RET.ALLOW },
    };
}

fn childDup2(old: std.posix.fd_t, new: std.posix.fd_t) void {
    childSyscallName(std.os.linux.dup2(old, new), "dup2");
}

fn childClose(fd: std.posix.fd_t) void {
    while (true) switch (std.os.linux.errno(std.os.linux.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

fn childCloseExtraFdsFrom(first_fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const rc = linux.close_range(@intCast(first_fd), std.math.maxInt(std.posix.fd_t), .{
        .UNSHARE = true,
        .CLOEXEC = false,
    });
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .NOSYS, .INVAL, .PERM => childCloseExtraFdsIndividually(first_fd),
        else => childSyscallName(rc, "close_range"),
    }
}

fn childCloseExtraFdsIndividually(first_fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const directory_rc = linux.open("/proc/self/fd", .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0);
    childSyscallName(directory_rc, "open_proc_fd");
    const directory_fd: std.posix.fd_t = @intCast(directory_rc);
    defer childClose(directory_fd);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_rc = linux.getdents64(directory_fd, &buffer, buffer.len);
        switch (linux.errno(read_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => childSyscallName(read_rc, "getdents_proc_fd"),
        }
        const bytes_read: usize = @intCast(read_rc);
        if (bytes_read == 0) return;

        var offset: usize = 0;
        while (offset < bytes_read) {
            const name_offset = @offsetOf(linux.dirent64, "name");
            if (bytes_read - offset <= name_offset) childInvalidProcFdEntry();
            const entry: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
            const record_length: usize = entry.reclen;
            if (record_length <= name_offset or record_length > bytes_read - offset)
                childInvalidProcFdEntry();
            const padded_name = buffer[offset + name_offset .. offset + record_length];
            const name_length = std.mem.indexOfScalar(u8, padded_name, 0) orelse
                childInvalidProcFdEntry();
            const fd = (childProcFdNumber(padded_name[0..name_length]) catch
                childInvalidProcFdEntry()) orelse {
                offset += record_length;
                continue;
            };
            offset += record_length;
            if (fd < first_fd or fd == directory_fd) continue;

            while (true) {
                const close_rc = linux.close(fd);
                switch (linux.errno(close_rc)) {
                    .SUCCESS, .BADF => break,
                    .INTR => continue,
                    else => childSyscallName(close_rc, "close_extra_fd"),
                }
            }
        }
    }
}

fn childProcFdNumber(name: []const u8) !?std.posix.fd_t {
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    if (name.len == 0) return error.InvalidProcFdEntry;
    for (name) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidProcFdEntry;
    }
    return std.fmt.parseInt(std.posix.fd_t, name, 10) catch error.InvalidProcFdEntry;
}

fn childInvalidProcFdEntry() noreturn {
    childWriteLiteral("actiond child setup failed: invalid_proc_fd_entry\n");
    std.os.linux.exit(127);
}

fn childWriteSetupComplete() void {
    childWriteSetupFrame(child_setup_ready_tag, 0);
}

fn childWriteSetupFrame(tag: u8, value: u32) void {
    const linux = std.os.linux;
    var frame: [child_setup_frame_length]u8 = undefined;
    frame[0] = tag;
    std.mem.writeInt(u32, frame[1..child_setup_frame_length], value, .little);

    var offset: usize = 0;
    while (offset < frame.len) {
        const rc = linux.write(child_setup_fd, frame[offset..].ptr, frame.len - offset);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) linux.exit(127);
                offset += rc;
            },
            .INTR => continue,
            else => childSyscallName(rc, "write_setup_frame"),
        }
    }
}

fn childRestoreSigpipeDefault() void {
    const action = defaultSigpipeAction();
    childSyscallName(std.os.linux.sigaction(.PIPE, &action, null), "sigaction_sigpipe_default");
}

fn defaultSigpipeAction() std.os.linux.Sigaction {
    return .{
        .handler = .{ .handler = std.os.linux.SIG.DFL },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
}

fn childWriteFile(path: [*:0]const u8, bytes: []const u8) void {
    const linux = std.os.linux;
    const fd_rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    childSyscallName(fd_rc, "open_cgroup");
    const fd: std.posix.fd_t = @intCast(fd_rc);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.os.linux.errno(rc)) {
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
    if (std.os.linux.errno(rc) == .SUCCESS) return;
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
    switch (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true }))) {
        .SUCCESS => return fds,
        .NFILE, .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

const OwnedPipe = struct {
    fds: [2]?std.posix.fd_t,

    fn init() !OwnedPipe {
        const fds = try linuxPipe();
        return .{ .fds = .{ fds[0], fds[1] } };
    }

    fn borrow(self: *const OwnedPipe) [2]std.posix.fd_t {
        return .{ self.endpoint(0), self.endpoint(1) };
    }

    fn endpoint(self: *const OwnedPipe, comptime index: usize) std.posix.fd_t {
        return self.fds[index].?;
    }

    fn release(self: *OwnedPipe, comptime index: usize) std.posix.fd_t {
        const fd = self.fds[index].?;
        self.fds[index] = null;
        return fd;
    }

    fn close(self: *OwnedPipe, comptime index: usize) void {
        if (self.fds[index]) |fd| {
            self.fds[index] = null;
            closeFd(fd);
        }
    }

    fn deinit(self: *OwnedPipe) void {
        self.close(0);
        self.close(1);
    }
};

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (std.os.linux.errno(std.os.linux.close(fd))) {
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
    const rc = linux.kill(pid, .KILL);
    if (linux.errno(rc) == .SUCCESS) {
        std.log.info("terminated action namespace init pid={d}", .{pid});
    }
    cgroup.kill(io, allocator);
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
    execution_control: ExecutionControl,
    child_waited: *bool,
) !ChildResult {
    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stderr.deinit(allocator);

    var poll_fds = [_]std.os.linux.pollfd{
        .{ .fd = stdout_fd, .events = std.os.linux.POLL.IN | std.os.linux.POLL.HUP | std.os.linux.POLL.ERR, .revents = 0 },
        .{ .fd = stderr_fd, .events = std.os.linux.POLL.IN | std.os.linux.POLL.HUP | std.os.linux.POLL.ERR, .revents = 0 },
    };
    defer for (&poll_fds) |*poll_fd| {
        if (poll_fd.fd >= 0) closeFd(poll_fd.fd);
    };
    var open_count: usize = 2;
    var status: ?Status = null;
    var waited_while_streams_open = false;

    while (open_count != 0) {
        try execution_control.check(io);
        if (status == null) {
            if (try waitForPidNoHang(pid)) |value| {
                status = value;
                child_waited.* = true;
                waited_while_streams_open = true;
                cgroup.kill(io, allocator);
            }
        }

        const rc = std.os.linux.poll(&poll_fds, poll_fds.len, try execution_control.pollTimeoutMilliseconds(io));
        switch (std.os.linux.errno(rc)) {
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
                child_waited.* = true;
                waited_while_streams_open = true;
                cgroup.kill(io, allocator);
            }
        }
    }

    const streams_completed = runnerTimingNow(io);
    const final_status = status orelse final_status: {
        const value = try waitForPidControlled(io, pid, execution_control);
        child_waited.* = true;
        break :final_status value;
    };
    const wait_completed = if (waited_while_streams_open)
        streams_completed
    else
        runnerTimingNow(io);

    const owned_stdout = try stdout.toOwnedSlice(allocator);
    errdefer allocator.free(owned_stdout);
    const owned_stderr = try stderr.toOwnedSlice(allocator);

    return .{
        .stdout = owned_stdout,
        .stderr = owned_stderr,
        .status = final_status,
        .streams_completed = streams_completed,
        .wait_completed = wait_completed,
    };
}

fn readSetupSignal(
    io: std.Io,
    fd: std.posix.fd_t,
    execution_control: ExecutionControl,
) !bool {
    var frame: [child_setup_frame_length]u8 = undefined;
    var frame_length: usize = 0;
    var ready_signaled = false;
    var poll_fds = [_]std.os.linux.pollfd{
        .{ .fd = fd, .events = std.os.linux.POLL.IN | std.os.linux.POLL.HUP | std.os.linux.POLL.ERR, .revents = 0 },
    };
    while (true) {
        try execution_control.check(io);
        const poll_rc = std.os.linux.poll(&poll_fds, poll_fds.len, try execution_control.pollTimeoutMilliseconds(io));
        switch (std.os.linux.errno(poll_rc)) {
            .SUCCESS => {
                if (poll_rc == 0) continue;
            },
            .INTR => continue,
            else => return error.Unexpected,
        }
        const rc = std.os.linux.read(fd, frame[frame_length..].ptr, frame.len - frame_length);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return frame_length == 0 and ready_signaled;
                frame_length += rc;
                if (frame_length != frame.len) continue;
                frame_length = 0;

                const value = std.mem.readInt(u32, frame[1..child_setup_frame_length], .little);
                switch (frame[0]) {
                    child_setup_ready_tag => {
                        if (ready_signaled or value != 0) return false;
                        ready_signaled = true;
                    },
                    child_setup_exec_failure_tag => return false,
                    else => return false,
                }
            },
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
    switch (std.os.linux.errno(rc)) {
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
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }

    return statusFromRawWait(raw_status);
}

fn waitForPidControlled(io: std.Io, pid: std.os.linux.pid_t, execution_control: ExecutionControl) !Status {
    if (!execution_control.bounded()) return waitForPid(pid);

    var poll_fds = [_]std.os.linux.pollfd{
        .{ .fd = -1, .events = 0, .revents = 0 },
    };
    while (true) {
        try execution_control.check(io);
        if (try waitForPidNoHang(pid)) |status| return status;
        const timeout_ms = @min(try execution_control.pollTimeoutMilliseconds(io), child_exit_poll_timeout_ms);
        const rc = std.os.linux.poll(&poll_fds, 0, timeout_ms);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS, .INTR => {},
            else => return error.Unexpected,
        }
    }
}

fn waitForPidNoHang(pid: std.os.linux.pid_t) !?Status {
    var raw_status: u32 = 0;
    while (true) {
        const rc = std.os.linux.waitpid(pid, &raw_status, std.os.linux.W.NOHANG);
        switch (std.os.linux.errno(rc)) {
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

fn appendExecCandidates(
    allocator: std.mem.Allocator,
    command: reapi.Command,
    candidates: *std.ArrayListUnmanaged([:0]u8),
) !void {
    const argv0 = command.arguments[0];
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        try candidates.append(allocator, try allocator.dupeZ(u8, argv0));
        return;
    }

    const path_value = commandPath(command) orelse "/usr/local/bin:/usr/bin:/bin";
    var parts = std.mem.splitScalar(u8, path_value, ':');
    while (parts.next()) |part| {
        const candidate = if (part.len == 0)
            try allocator.dupeZ(u8, argv0)
        else
            try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ part, argv0 }, 0);
        errdefer allocator.free(candidate);
        try candidates.append(allocator, candidate);
    }
}

fn commandPath(command: reapi.Command) ?[]const u8 {
    for (command.environment_variables) |variable| {
        if (std.mem.eql(u8, variable.name, "PATH")) return variable.value;
    }
    return null;
}

fn evaluateActionSeccompFilterForTest(
    architecture: u32,
    syscall_number: u32,
    arguments: [6]u64,
) !u32 {
    const instructions = actionSeccompFilterInstructions();
    var accumulator: u32 = 0;
    var index: usize = 0;
    while (index < instructions.len) {
        const instruction = instructions[index];
        switch (instruction.code) {
            classic_bpf_load_absolute_word => {
                accumulator = switch (instruction.data) {
                    0 => syscall_number,
                    4 => architecture,
                    16, 24, 32, 40, 48, 56 => @truncate(arguments[(instruction.data - 16) / 8]),
                    else => return error.InvalidSeccompFilterInstruction,
                };
                index += 1;
            },
            classic_bpf_bitwise_and_constant => {
                accumulator &= instruction.data;
                index += 1;
            },
            classic_bpf_jump_equal_constant => {
                index += 1 + @as(usize, if (accumulator == instruction.data)
                    instruction.jump_true
                else
                    instruction.jump_false);
            },
            classic_bpf_return_constant => return instruction.data,
            else => return error.InvalidSeccompFilterInstruction,
        }
    }
    return error.InvalidSeccompFilterJump;
}

test "Outcome owns all REAPI output symlink paths and targets" {
    const allocator = std.testing.allocator;
    var outcome: Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = &.{},
        .stderr = &.{},
    };
    defer outcome.deinit(allocator);

    outcome.output_symlinks = try allocator.alloc(Outcome.OutputSymlink, 1);
    outcome.output_symlinks[0] = .{ .path = &.{}, .target = &.{} };
    outcome.output_symlinks[0].path = try allocator.dupe(u8, "out/link");
    outcome.output_symlinks[0].target = try allocator.dupe(u8, "../target");

    outcome.output_file_symlinks = try allocator.alloc(Outcome.OutputSymlink, 1);
    outcome.output_file_symlinks[0] = .{ .path = &.{}, .target = &.{} };
    outcome.output_file_symlinks[0].path = try allocator.dupe(u8, "out/file-link");
    outcome.output_file_symlinks[0].target = try allocator.dupe(u8, "target-file");

    outcome.output_directory_symlinks = try allocator.alloc(Outcome.OutputSymlink, 1);
    outcome.output_directory_symlinks[0] = .{ .path = &.{}, .target = &.{} };
    outcome.output_directory_symlinks[0].path = try allocator.dupe(u8, "out/directory-link");
    outcome.output_directory_symlinks[0].target = try allocator.dupe(u8, "target-directory");

    try std.testing.expectEqualStrings("../target", outcome.output_symlinks[0].target);
    try std.testing.expectEqualStrings("target-file", outcome.output_file_symlinks[0].target);
    try std.testing.expectEqualStrings("target-directory", outcome.output_directory_symlinks[0].target);
}

test "appendExecCandidates preserves explicit executable path" {
    var candidates: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (candidates.items) |candidate| std.testing.allocator.free(candidate);
        candidates.deinit(std.testing.allocator);
    }

    try appendExecCandidates(std.testing.allocator, .{
        .arguments = &.{"external/tool/bin/tool"},
    }, &candidates);

    try std.testing.expectEqual(@as(usize, 1), candidates.items.len);
    try std.testing.expectEqualStrings("external/tool/bin/tool", candidates.items[0]);
}

test "appendExecCandidates preserves relative and empty PATH entries" {
    var candidates: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (candidates.items) |candidate| std.testing.allocator.free(candidate);
        candidates.deinit(std.testing.allocator);
    }

    try appendExecCandidates(std.testing.allocator, .{
        .arguments = &.{"tool"},
        .environment_variables = &.{.{ .name = "PATH", .value = ":tools:/bin" }},
    }, &candidates);

    try std.testing.expectEqual(@as(usize, 3), candidates.items.len);
    try std.testing.expectEqualStrings("tool", candidates.items[0]);
    try std.testing.expectEqualStrings("tools/tool", candidates.items[1]);
    try std.testing.expectEqualStrings("/bin/tool", candidates.items[2]);
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

test "CgroupLimits rejects invalid execution property values" {
    const limits = CgroupLimits.fromPlatform(.{
        .properties = &.{
            .{ .name = "memory", .value = "bad" },
            .{ .name = "cpu", .value = "bad" },
            .{ .name = "pids", .value = "bad" },
        },
    });

    try std.testing.expect(!limits.any());
    try std.testing.expect(limits.invalid);
}

test "CgroupLimits rejects zero CPU execution property" {
    const limits = CgroupLimits.fromPlatform(.{
        .properties = &.{.{ .name = "cpu", .value = "0" }},
    });

    try std.testing.expect(!limits.any());
    try std.testing.expect(limits.invalid);
}

test "proc descriptor parsing includes descriptors above a lowered soft limit" {
    try std.testing.expectEqual(@as(?std.posix.fd_t, 1048576), try childProcFdNumber("1048576"));
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), try childProcFdNumber("."));
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), try childProcFdNumber(".."));
    try std.testing.expectError(error.InvalidProcFdEntry, childProcFdNumber("-1"));
    try std.testing.expectError(error.InvalidProcFdEntry, childProcFdNumber("2147483648"));
}

test "setup frame stores sandbox readiness" {
    var frame: [child_setup_frame_length]u8 = undefined;
    frame[0] = child_setup_ready_tag;
    std.mem.writeInt(u32, frame[1..child_setup_frame_length], 0, .little);

    try std.testing.expectEqual(child_setup_ready_tag, frame[0]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, frame[1..child_setup_frame_length], .little));
    try std.testing.expect(child_setup_frame_length <= 4096);
}

test "setup frame distinguishes execve failure from a program exit status" {
    var frame: [child_setup_frame_length]u8 = undefined;
    frame[0] = child_setup_exec_failure_tag;
    std.mem.writeInt(u32, frame[1..child_setup_frame_length], @intFromEnum(std.posix.E.NOENT), .little);

    try std.testing.expectEqual(child_setup_exec_failure_tag, frame[0]);
    try std.testing.expectEqual(
        @as(u32, @intFromEnum(std.posix.E.NOENT)),
        std.mem.readInt(u32, frame[1..child_setup_frame_length], .little),
    );
    try std.testing.expect(child_setup_exec_failure_tag != child_setup_ready_tag);
}

test "OwnedPipe disarms released and closed endpoints" {
    var pipe = OwnedPipe{ .fds = .{ 10, 11 } };

    try std.testing.expectEqual(@as(std.posix.fd_t, 10), pipe.release(0));
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), pipe.fds[0]);
    pipe.fds[1] = null;
    pipe.deinit();
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), pipe.fds[1]);
}

test "sandboxed actions restore the default SIGPIPE disposition" {
    const action = defaultSigpipeAction();
    try std.testing.expectEqual(std.os.linux.SIG.DFL, action.handler.handler);
    try std.testing.expectEqual(@as(@TypeOf(action.flags), 0), action.flags);
}

test "sandbox seccomp rejects AF_VSOCK and io_uring_setup" {
    const linux = std.os.linux;
    const denied = @as(u32, linux.SECCOMP.RET.ERRNO) | @as(u32, @intFromEnum(std.posix.E.PERM));

    try std.testing.expectEqual(denied, try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.socket),
        .{ linux.AF.VSOCK, 0, 0, 0, 0, 0 },
    ));
    try std.testing.expectEqual(denied, try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.io_uring_setup),
        .{ 0, 0, 0, 0, 0, 0 },
    ));
    try std.testing.expectEqual(@as(u32, linux.SECCOMP.RET.ALLOW), try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.socket),
        .{ linux.AF.INET, 0, 0, 0, 0, 0 },
    ));
}

test "sandbox seccomp rejects untrusted BPF and socket filter entry points" {
    const linux = std.os.linux;
    const denied = @as(u32, linux.SECCOMP.RET.ERRNO) | @as(u32, @intFromEnum(std.posix.E.PERM));

    try std.testing.expectEqual(denied, try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.bpf),
        .{ 0, 0, 0, 0, 0, 0 },
    ));
    for ([_]u32{ linux.SO.ATTACH_FILTER, linux.SO.ATTACH_REUSEPORT_CBPF }) |option| {
        try std.testing.expectEqual(denied, try evaluateActionSeccompFilterForTest(
            actionAuditArchitecture(),
            @intFromEnum(linux.SYS.setsockopt),
            .{ 7, linux.SOL.SOCKET, option, 0, 0, 0 },
        ));
    }
}

test "sandbox seccomp allows additional restrictive filters" {
    const linux = std.os.linux;
    const allowed: u32 = linux.SECCOMP.RET.ALLOW;

    try std.testing.expectEqual(allowed, try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.seccomp),
        .{ linux.SECCOMP.SET_MODE_FILTER, 0, 0, 0, 0, 0 },
    ));
    try std.testing.expectEqual(allowed, try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.prctl),
        .{ @intCast(@intFromEnum(linux.PR.SET_SECCOMP)), linux.SECCOMP.MODE.FILTER, 0, 0, 0, 0 },
    ));
}

test "sandbox seccomp allows unrelated socket options and prctl operations" {
    const linux = std.os.linux;
    const allowed: u32 = linux.SECCOMP.RET.ALLOW;

    try std.testing.expectEqual(allowed, try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.prctl),
        .{ @intCast(@intFromEnum(linux.PR.GET_SECCOMP)), 0, 0, 0, 0, 0 },
    ));
    try std.testing.expectEqual(allowed, try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.setsockopt),
        .{ 7, linux.SOL.SOCKET, linux.SO.REUSEADDR, 0, 0, 0 },
    ));
    try std.testing.expectEqual(allowed, try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.setsockopt),
        .{ 7, linux.SOL.IP, linux.SO.ATTACH_FILTER, 0, 0, 0 },
    ));
    try std.testing.expectEqual(allowed, try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture(),
        @intFromEnum(linux.SYS.read),
        .{ 0, 0, 0, 0, 0, 0 },
    ));
}

test "sandbox seccomp kills mismatched audit architectures" {
    const linux = std.os.linux;

    try std.testing.expectEqual(@as(u32, linux.SECCOMP.RET.KILL_PROCESS), try evaluateActionSeccompFilterForTest(
        actionAuditArchitecture() ^ 1,
        @intFromEnum(linux.SYS.read),
        .{ 0, 0, 0, 0, 0, 0 },
    ));
}

test "ExecutionControl rejects an expired action deadline" {
    const execution_control = ExecutionControl.init(std.testing.io, .{
        .chroot_dir = "/",
        .timeout_ns = 0,
    });

    try std.testing.expectError(error.ExecutionDeadlineExceeded, execution_control.check(std.testing.io));
}

test "ExecutionControl rejects a cancelled action" {
    var cancellation = std.atomic.Value(bool).init(true);
    const execution_control = ExecutionControl.init(std.testing.io, .{
        .chroot_dir = "/",
        .cancellation = &cancellation,
    });

    try std.testing.expectError(error.ExecutionCancelled, execution_control.check(std.testing.io));
}

test "action clone flags isolate mounts, networking, and action process IDs" {
    const linux = std.os.linux;
    const flags = actionCloneFlags();
    try std.testing.expect((flags & linux.CLONE.NEWNS) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWNET) != 0);
    try std.testing.expect((flags & linux.CLONE.NEWPID) != 0);
    try std.testing.expectEqual(@as(u32, @intFromEnum(linux.SIG.CHLD)), flags & linux.CSIGNAL);
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
