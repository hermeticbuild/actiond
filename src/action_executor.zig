const builtin = @import("builtin");
const std = @import("std");
const action_runner = @import("action_runner.zig");
const build_options = @import("actiond_build_options");
const cas = @import("cas.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");
const staged_cas_index = @import("staged_cas_index.zig");

const max_output_file_bytes = 1024 * 1024 * 1024;
const chroot_execroot_prefix = "/workspace/";
const worker_name = "actiond";
const supported_libc_runtimes = [_][]const u8{ "glibc2.31", "glibc2.35", "glibc2.39" };
var next_actiondfs_workspace_id = std.atomic.Value(u64).init(0);

inline fn executorTimingNow(io: std.Io) std.Io.Timestamp {
    return if (comptime build_options.executor_timing_logs)
        std.Io.Clock.awake.now(io)
    else
        undefined;
}

pub const RuntimeMountSources = struct {
    bin: ?[:0]const u8 = null,
    lib: ?[:0]const u8 = null,
    lib64: ?[:0]const u8 = null,
    usr_bin: ?[:0]const u8 = null,
    usr_lib: ?[:0]const u8 = null,
    etc: ?[:0]const u8 = null,

    fn deinit(self: *RuntimeMountSources, allocator: std.mem.Allocator) void {
        if (self.bin) |path| allocator.free(path);
        if (self.lib) |path| allocator.free(path);
        if (self.lib64) |path| allocator.free(path);
        if (self.usr_bin) |path| allocator.free(path);
        if (self.usr_lib) |path| allocator.free(path);
        if (self.etc) |path| allocator.free(path);
        self.* = .{};
    }
};

pub const RuntimeMountCache = struct {
    common: RuntimeMountSources = .{},
    glibc2_31: RuntimeMountSources = .{},
    glibc2_35: RuntimeMountSources = .{},
    glibc2_39: RuntimeMountSources = .{},
    bash: RuntimeMountSources = .{},

    fn deinit(self: *RuntimeMountCache, allocator: std.mem.Allocator) void {
        self.common.deinit(allocator);
        self.glibc2_31.deinit(allocator);
        self.glibc2_35.deinit(allocator);
        self.glibc2_39.deinit(allocator);
        self.bash.deinit(allocator);
        self.* = .{};
    }

    fn forLibc(self: *const RuntimeMountCache, libc: []const u8) ?*const RuntimeMountSources {
        if (std.mem.eql(u8, libc, "glibc2.31")) return &self.glibc2_31;
        if (std.mem.eql(u8, libc, "glibc2.35")) return &self.glibc2_35;
        if (std.mem.eql(u8, libc, "glibc2.39")) return &self.glibc2_39;
        return null;
    }

    fn forShell(self: *const RuntimeMountCache, shell: []const u8) ?*const RuntimeMountSources {
        if (std.mem.eql(u8, shell, "bash")) return &self.bash;
        return null;
    }
};

pub const ExecuteOptions = struct {
    runtime_root_path: ?[]const u8 = null,
    cas_blob_root_path: ?[]const u8 = null,
    actiondfs_stage_root_path: ?[]const u8 = null,
    staged_cas_index: ?*staged_cas_index.Index = null,
    runtime_mount_cache: ?RuntimeMountCache = null,
};

pub const PreparedExecuteOptions = struct {
    options: ExecuteOptions,
    owned_cas_blob_root_path: ?[]u8 = null,
    owned_actiondfs_stage_root_path: ?[]u8 = null,
    owns_runtime_mount_cache: bool = false,

    pub fn deinit(self: *PreparedExecuteOptions, allocator: std.mem.Allocator) void {
        if (self.owns_runtime_mount_cache) {
            if (self.options.runtime_mount_cache) |*cache| cache.deinit(allocator);
        }
        if (self.owned_cas_blob_root_path) |path| allocator.free(path);
        if (self.owned_actiondfs_stage_root_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const LoadedAction = struct {
    bytes: []u8,
    action: reapi.Action,

    pub fn deinit(self: *LoadedAction, allocator: std.mem.Allocator) void {
        self.action.deinit(allocator);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const ActiondfsMode = enum {
    actiondfs_strict,
    actiondfs_overlay,

    fn label(self: ActiondfsMode) []const u8 {
        return switch (self) {
            .actiondfs_strict => "actiondfs_strict",
            .actiondfs_overlay => "actiondfs_overlay",
        };
    }
};

pub fn prepareExecuteOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    base: ExecuteOptions,
) !PreparedExecuteOptions {
    var prepared: PreparedExecuteOptions = .{ .options = base };
    errdefer prepared.deinit(allocator);

    if (prepared.options.cas_blob_root_path == null) {
        var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cas_root_len = try store.root.realPath(io, &cas_root_buffer);
        const path = try std.fmt.allocPrint(allocator, "{s}/blobs/sha256", .{cas_root_buffer[0..cas_root_len]});
        prepared.owned_cas_blob_root_path = path;
        prepared.options.cas_blob_root_path = path;
    }
    if (prepared.options.actiondfs_stage_root_path == null) {
        var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cas_root_len = try store.root.realPath(io, &cas_root_buffer);
        const path = try std.fmt.allocPrint(allocator, "{s}/actiondfs-stage", .{cas_root_buffer[0..cas_root_len]});
        prepared.owned_actiondfs_stage_root_path = path;
        prepared.options.actiondfs_stage_root_path = path;
    }
    if (prepared.options.runtime_root_path) |runtime_root_path| {
        if (prepared.options.runtime_mount_cache == null) {
            prepared.options.runtime_mount_cache = try discoverRuntimeMounts(io, allocator, runtime_root_path);
            prepared.owns_runtime_mount_cache = true;
        }
    }

    return prepared;
}

fn executionPlatform(action: reapi.Action, command: reapi.Command) ?reapi.Platform {
    if (action.platform) |platform| return platform;
    return command.platform;
}

fn actionMutatesInputs(platform: ?reapi.Platform) bool {
    const value = platform orelse return false;
    for (value.properties) |property| {
        if (!std.mem.eql(u8, property.name, "mutates_inputs")) continue;
        if (property.value.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(property.value, "1") or
            std.ascii.eqlIgnoreCase(property.value, "true") or
            std.ascii.eqlIgnoreCase(property.value, "yes") or
            std.ascii.eqlIgnoreCase(property.value, "on"))
        {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(property.value, "0") or
            std.ascii.eqlIgnoreCase(property.value, "false") or
            std.ascii.eqlIgnoreCase(property.value, "no") or
            std.ascii.eqlIgnoreCase(property.value, "off"))
        {
            return false;
        }
        return true;
    }
    return false;
}

pub fn loadAction(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    action_digest: cas.Digest,
) !LoadedAction {
    const action_bytes = store.readAlloc(io, allocator, action_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingActionBlob,
        else => return err,
    };
    errdefer allocator.free(action_bytes);
    var action_reader = protobuf.Reader.init(action_bytes);
    return .{
        .bytes = action_bytes,
        .action = try reapi.Action.decodeOwned(allocator, &action_reader),
    };
}

pub fn executeDecodedActionWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    action_digest: cas.Digest,
    action: reapi.Action,
    options: ExecuteOptions,
) !action_runner.Outcome {
    const worker_start_wall = timestampNow(io);
    const input_fetch_start_wall = worker_start_wall;
    const total_start = executorTimingNow(io);
    const input_fetch_start = total_start;

    const command_digest = try cas.Digest.fromReapi(action.command_digest orelse return error.MissingCommandDigest);
    const command_bytes = store.readAlloc(io, allocator, command_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCommandBlob,
        else => return err,
    };
    defer allocator.free(command_bytes);
    var command_reader = protobuf.Reader.init(command_bytes);
    var command = try reapi.Command.decodeOwned(allocator, &command_reader);
    defer command.deinit(allocator);
    const platform = executionPlatform(action, command);

    const input_root_digest = try cas.Digest.fromReapi(action.input_root_digest orelse return error.MissingInputRootDigest);
    const actiondfs_mode: ActiondfsMode = if (actionMutatesInputs(platform))
        .actiondfs_overlay
    else
        .actiondfs_strict;

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try work_root.realPath(io, &cwd_buffer);
    const work_root_path = cwd_buffer[0..cwd_len];
    try work_root.createDirPath(io, "workspace");
    const workspace_path = try std.fmt.allocPrint(allocator, "{s}/workspace", .{work_root_path});
    defer allocator.free(workspace_path);
    try prepareChrootBaseDirs(io, work_root);

    var owned_cas_blob_root_path: ?[]u8 = null;
    defer if (owned_cas_blob_root_path) |path| allocator.free(path);
    const cas_blob_root_path = options.cas_blob_root_path orelse path: {
        var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cas_root_len = try store.root.realPath(io, &cas_root_buffer);
        const value = try std.fmt.allocPrint(allocator, "{s}/blobs/sha256", .{cas_root_buffer[0..cas_root_len]});
        owned_cas_blob_root_path = value;
        break :path value;
    };
    var actiondfs_workspace = try ActiondfsWorkspace.init(
        io,
        allocator,
        cas_blob_root_path,
        options.actiondfs_stage_root_path,
        work_root_path,
        workspace_path,
        input_root_digest,
        actiondfs_mode,
    );
    defer actiondfs_workspace.deinit(io, allocator);

    var actiondfs_stage_dir = try std.Io.Dir.openDirAbsolute(io, actiondfs_workspace.stagePath(), .{ .iterate = true });
    defer actiondfs_stage_dir.close(io);
    prepareOutputParents(io, actiondfs_stage_dir, command) catch |err| switch (err) {
        error.FileNotFound => return error.OutputParentCreateFailed,
        else => {
            logExecuteSetupError("prepare output parents", action_digest, err);
            return err;
        },
    };

    var chroot_cwd_owned: ?[]u8 = null;
    defer if (chroot_cwd_owned) |path| allocator.free(path);
    const chroot_cwd = if (command.working_directory.len == 0)
        "/workspace"
    else cwd: {
        try validatePath(command.working_directory);
        const value = try std.fmt.allocPrint(allocator, "/workspace/{s}", .{command.working_directory});
        chroot_cwd_owned = value;
        break :cwd value;
    };

    const libc_runtime = try libcRuntimeFromPlatform(platform);
    const shell_runtime = try shellRuntimeFromPlatform(platform);
    var bind_mounts: std.ArrayListUnmanaged(action_runner.BindMount) = .empty;
    var borrowed_source_count: usize = 0;
    defer {
        for (bind_mounts.items, 0..) |mount, i| {
            if (i >= borrowed_source_count) allocator.free(mount.source);
            allocator.free(mount.target);
        }
        bind_mounts.deinit(allocator);
    }
    if (options.runtime_mount_cache) |cache| {
        borrowed_source_count = std.math.maxInt(usize);
        if (libc_runtime) |libc| {
            const sources = cache.forLibc(libc) orelse return error.UnsupportedLibcRuntime;
            try appendCachedLibcRuntimeMounts(io, allocator, work_root, work_root_path, sources, &bind_mounts);
        } else {
            try appendCachedCommonRuntimeMounts(io, allocator, work_root, work_root_path, &cache.common, &bind_mounts);
        }
        if (shell_runtime) |shell| {
            const sources = cache.forShell(shell) orelse return error.UnsupportedShellRuntime;
            try appendCachedShellRuntimeMounts(io, allocator, work_root, work_root_path, sources, &bind_mounts);
        }
        borrowed_source_count = bind_mounts.items.len;
    } else if (libc_runtime != null or shell_runtime != null) {
        return error.MissingRuntimeMountCache;
    }
    try appendDevNullMount(io, allocator, work_root, work_root_path, &bind_mounts);

    const input_fetch_completed_wall = timestampNow(io);
    const input_fetch_completed = executorTimingNow(io);
    const execution_start_wall = timestampNow(io);
    const execution_start = executorTimingNow(io);
    var outcome = try action_runner.runCommandWithOptions(io, allocator, store, command, .{
        .chroot_dir = work_root_path,
        .chroot_cwd = chroot_cwd,
        .bind_mounts = bind_mounts.items,
        .actiondfs_mounts = actiondfs_workspace.mounts[0..],
        .cgroup_limits = action_runner.CgroupLimits.fromPlatform(platform),
    });
    errdefer outcome.deinit(allocator);
    const execution_completed_wall = timestampNow(io);
    const execution_completed = executorTimingNow(io);
    const output_upload_start_wall = timestampNow(io);
    const output_upload_start = executorTimingNow(io);
    if (options.staged_cas_index) |index| {
        if (outcome.stdout_digest) |digest| try index.add(io, allocator, digest);
        if (outcome.stderr_digest) |digest| try index.add(io, allocator, digest);
    }
    try actiondfs_workspace.mountForCollection();
    var output_dir = try std.Io.Dir.openDirAbsolute(io, actiondfs_workspace.collectionPath(), .{ .iterate = true });
    defer output_dir.close(io);
    try collectOutputFiles(io, allocator, store, options.staged_cas_index, output_dir, command, &outcome);
    const output_upload_completed_wall = timestampNow(io);
    const output_upload_completed = executorTimingNow(io);

    outcome.execution_metadata = .{
        .worker = worker_name,
        .queued_timestamp = worker_start_wall,
        .worker_start_timestamp = worker_start_wall,
        .worker_completed_timestamp = output_upload_completed_wall,
        .input_fetch_start_timestamp = input_fetch_start_wall,
        .input_fetch_completed_timestamp = input_fetch_completed_wall,
        .execution_start_timestamp = execution_start_wall,
        .execution_completed_timestamp = execution_completed_wall,
        .output_upload_start_timestamp = output_upload_start_wall,
        .output_upload_completed_timestamp = output_upload_completed_wall,
    };
    if (comptime build_options.executor_timing_logs) {
        logActionTiming(
            action_digest,
            total_start,
            input_fetch_start,
            input_fetch_completed,
            execution_start,
            execution_completed,
            output_upload_start,
            output_upload_completed,
            bind_mounts.items.len,
            outcome.output_files.len,
            outcome.output_directories.len,
            stressCaseFromCommand(command),
            actiondfs_mode,
        );
        if (outcome.runner_timing) |timing| logRunnerTiming(action_digest, timing);
    }
    return outcome;
}

fn libcRuntimeFromPlatform(platform: ?reapi.Platform) !?[]const u8 {
    const value = platform orelse return null;
    for (value.properties) |property| {
        if (!std.mem.eql(u8, property.name, "libc")) continue;
        if (property.value.len == 0 or std.mem.eql(u8, property.value, "none")) return null;
        for (supported_libc_runtimes) |name| {
            if (std.mem.eql(u8, property.value, name)) return name;
        }
        return error.UnsupportedLibcRuntime;
    }
    return null;
}

fn shellRuntimeFromPlatform(platform: ?reapi.Platform) !?[]const u8 {
    const value = platform orelse return null;
    for (value.properties) |property| {
        if (!std.mem.eql(u8, property.name, "requires-bash")) continue;
        if (property.value.len != 0) return error.UnsupportedShellRuntime;
        return "bash";
    }
    return null;
}

fn stressCaseFromCommand(command: reapi.Command) []const u8 {
    for (command.environment_variables) |variable| {
        if (std.mem.eql(u8, variable.name, "ACTIOND_STRESS_CASE") and variable.value.len != 0) return variable.value;
    }
    return "unknown";
}

const ActiondfsWorkspace = struct {
    base_path: []u8,
    mode: ActiondfsMode,
    lower_target: ?[:0]u8 = null,
    overlay_target: ?[:0]u8 = null,
    fstype: [:0]const u8,
    stage_dir: [:0]u8,
    actiondfs_data: [:0]u8,
    overlay_data: ?[:0]u8 = null,
    mounts: [1]action_runner.ActiondfsMount,
    collection_mounted: bool = false,

    fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        cas_blob_root: []const u8,
        stage_root_path: ?[]const u8,
        work_root_path: []const u8,
        workspace_path: []const u8,
        input_root_digest: cas.Digest,
        mode: ActiondfsMode,
    ) !ActiondfsWorkspace {
        const base_path = try createActiondfsBasePath(io, allocator, stage_root_path, work_root_path);
        errdefer allocator.free(base_path);

        var base_dir = try std.Io.Dir.openDirAbsolute(io, base_path, .{});
        defer base_dir.close(io);
        try base_dir.createDir(io, "stage", .default_dir);

        const stage_path = try std.fmt.allocPrintSentinel(allocator, "{s}/stage", .{base_path}, 0);
        errdefer allocator.free(stage_path);

        var root_hash: [64]u8 = undefined;

        const root_hex = input_root_digest.formatHex(&root_hash);
        const fstype: [:0]const u8 = build_options.actiondfs_fstype;
        const actiondfs_data = if (mode == .actiondfs_strict)
            try std.fmt.allocPrintSentinel(
                allocator,
                "root={s},root_size={d},cas={s},stage={s}",
                .{ root_hex, input_root_digest.size_bytes, cas_blob_root, stage_path },
                0,
            )
        else
            try std.fmt.allocPrintSentinel(
                allocator,
                "root={s},root_size={d},cas={s}",
                .{ root_hex, input_root_digest.size_bytes, cas_blob_root },
                0,
            );
        errdefer allocator.free(actiondfs_data);

        if (mode == .actiondfs_strict) {
            const target = try allocator.dupeZ(u8, workspace_path);
            errdefer allocator.free(target);
            return .{
                .base_path = base_path,
                .mode = mode,
                .fstype = fstype,
                .stage_dir = stage_path,
                .actiondfs_data = actiondfs_data,
                .mounts = .{.{ .strict = .{
                    .fstype = fstype,
                    .target = target,
                    .stage_dir = stage_path,
                    .actiondfs_data = actiondfs_data,
                } }},
            };
        }

        const lower_path = try std.fmt.allocPrintSentinel(allocator, "{s}/lower", .{base_path}, 0);
        errdefer allocator.free(lower_path);
        const work_path = try std.fmt.allocPrint(allocator, "{s}/work", .{base_path});
        defer allocator.free(work_path);
        try base_dir.createDir(io, "lower", .default_dir);
        try base_dir.createDir(io, "work", .default_dir);

        const overlay_data = try std.fmt.allocPrintSentinel(
            allocator,
            "lowerdir={s},upperdir={s},workdir={s}",
            .{ lower_path, stage_path, work_path },
            0,
        );
        errdefer allocator.free(overlay_data);
        const overlay_target = try allocator.dupeZ(u8, workspace_path);
        errdefer allocator.free(overlay_target);

        return .{
            .base_path = base_path,
            .mode = mode,
            .fstype = fstype,
            .lower_target = lower_path,
            .overlay_target = overlay_target,
            .stage_dir = stage_path,
            .actiondfs_data = actiondfs_data,
            .overlay_data = overlay_data,
            .mounts = .{.{ .overlay = .{
                .fstype = fstype,
                .lower_target = lower_path,
                .overlay_target = overlay_target,
                .upperdir = stage_path,
                .actiondfs_data = actiondfs_data,
                .overlay_data = overlay_data,
            } }},
        };
    }

    fn mountForCollection(self: *ActiondfsWorkspace) !void {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;
        if (self.collection_mounted) return;
        if (self.mode == .actiondfs_strict) return;

        const linux = std.os.linux;
        const actiondfs_rc = linux.mount(
            self.fstype.ptr,
            self.lower_target.?.ptr,
            self.fstype.ptr,
            linux.MS.RDONLY | linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOATIME,
            @intFromPtr(self.actiondfs_data.ptr),
        );
        switch (std.posix.errno(actiondfs_rc)) {
            .SUCCESS => {},
            else => return error.MountFailed,
        }
        errdefer _ = linux.umount2(self.lower_target.?.ptr, linux.MNT.DETACH);

        const overlay_rc = linux.mount(
            "overlay",
            self.overlay_target.?.ptr,
            "overlay",
            linux.MS.NOSUID | linux.MS.NODEV,
            @intFromPtr(self.overlay_data.?.ptr),
        );
        switch (std.posix.errno(overlay_rc)) {
            .SUCCESS => {},
            else => return error.MountFailed,
        }
        self.collection_mounted = true;
    }

    fn stagePath(self: *const ActiondfsWorkspace) [:0]const u8 {
        return self.stage_dir;
    }

    fn collectionPath(self: *const ActiondfsWorkspace) [:0]const u8 {
        return switch (self.mode) {
            .actiondfs_strict => self.stage_dir,
            .actiondfs_overlay => self.overlay_target.?,
        };
    }

    fn deinit(self: *ActiondfsWorkspace, io: std.Io, allocator: std.mem.Allocator) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.collection_mounted) {
                if (self.overlay_target) |target| _ = std.os.linux.umount2(target.ptr, std.os.linux.MNT.DETACH);
                if (self.lower_target) |target| _ = std.os.linux.umount2(target.ptr, std.os.linux.MNT.DETACH);
            }
        }
        std.Io.Dir.cwd().deleteTree(io, self.base_path) catch |err| {
            std.log.warn("failed to remove actiondfs workspace {s}: {s}", .{ self.base_path, @errorName(err) });
        };
        allocator.free(self.base_path);
        if (self.lower_target) |path| allocator.free(path);
        if (self.overlay_target) |path| allocator.free(path);
        allocator.free(self.stage_dir);
        allocator.free(self.actiondfs_data);
        if (self.overlay_data) |data| allocator.free(data);
        switch (self.mounts[0]) {
            .strict => |mount| allocator.free(mount.target),
            .overlay => {},
        }
        self.* = undefined;
    }
};

fn createActiondfsBasePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    stage_root_path: ?[]const u8,
    work_root_path: []const u8,
) ![]u8 {
    const root = stage_root_path orelse {
        const base_path = try std.fmt.allocPrint(allocator, "{s}.actiondfs", .{work_root_path});
        errdefer allocator.free(base_path);
        try std.Io.Dir.cwd().createDir(io, base_path, .default_dir);
        return base_path;
    };

    try std.Io.Dir.cwd().createDirPath(io, root);
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer root_dir.close(io);

    while (true) {
        const id = next_actiondfs_workspace_id.fetchAdd(1, .monotonic);
        const name = try std.fmt.allocPrint(allocator, "action-{d}", .{id});
        defer allocator.free(name);
        root_dir.createDir(io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
    }
}

fn runtimeArch() ![]const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => error.UnsupportedRuntimeArch,
    };
}

fn discoverRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime_root_path: []const u8,
) !RuntimeMountCache {
    var cache: RuntimeMountCache = .{};
    errdefer cache.deinit(allocator);

    const common_root = try std.fmt.allocPrint(allocator, "{s}/common/root", .{runtime_root_path});
    defer allocator.free(common_root);
    cache.common.etc = try runtimePathIfExists(io, allocator, common_root, "etc");

    cache.glibc2_31 = try discoverLibcRuntimeMounts(io, allocator, runtime_root_path, "glibc2.31");
    cache.glibc2_35 = try discoverLibcRuntimeMounts(io, allocator, runtime_root_path, "glibc2.35");
    cache.glibc2_39 = try discoverLibcRuntimeMounts(io, allocator, runtime_root_path, "glibc2.39");
    cache.bash = try discoverShellRuntimeMounts(io, allocator, runtime_root_path, "bash");

    return cache;
}

fn discoverLibcRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime_root_path: []const u8,
    libc: []const u8,
) !RuntimeMountSources {
    const arch = try runtimeArch();
    const runtime_root = try std.fmt.allocPrint(allocator, "{s}/libc/{s}/{s}/root", .{ runtime_root_path, libc, arch });
    defer allocator.free(runtime_root);

    var sources: RuntimeMountSources = .{};
    errdefer sources.deinit(allocator);
    sources.lib = try firstRuntimePathIfExists(io, allocator, runtime_root, &.{ "lib", "usr/lib" });
    sources.lib64 = try firstRuntimePathIfExists(io, allocator, runtime_root, &.{ "lib64", "usr/lib64" });
    sources.usr_lib = try runtimePathIfExists(io, allocator, runtime_root, "usr/lib");
    sources.etc = try runtimePathIfExists(io, allocator, runtime_root, "etc");
    return sources;
}

fn discoverShellRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime_root_path: []const u8,
    shell: []const u8,
) !RuntimeMountSources {
    const arch = try runtimeArch();
    const runtime_root = try std.fmt.allocPrint(allocator, "{s}/shell/{s}/{s}/root", .{ runtime_root_path, shell, arch });
    defer allocator.free(runtime_root);

    var sources: RuntimeMountSources = .{};
    errdefer sources.deinit(allocator);
    sources.bin = try runtimePathIfExists(io, allocator, runtime_root, "bin");
    sources.usr_bin = try runtimePathIfExists(io, allocator, runtime_root, "usr/bin");
    return sources;
}

fn firstRuntimePathIfExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime_root: []const u8,
    source_candidates: []const []const u8,
) !?[:0]const u8 {
    for (source_candidates) |source_rel| {
        if (try runtimePathIfExists(io, allocator, runtime_root, source_rel)) |path| return path;
    }
    return null;
}

fn runtimePathIfExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime_root: []const u8,
    source_rel: []const u8,
) !?[:0]const u8 {
    const source = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ runtime_root, source_rel }, 0);
    errdefer allocator.free(source);
    std.Io.Dir.cwd().access(io, source, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(source);
            return null;
        },
        else => |e| return e,
    };
    return source;
}

fn appendCachedCommonRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    sources: *const RuntimeMountSources,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    if (sources.etc) |source| try appendCachedRuntimeMount(io, allocator, chroot_dir, chroot_path, source, "etc", bind_mounts);
}

fn appendCachedLibcRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    sources: *const RuntimeMountSources,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    if (sources.lib) |source| try appendCachedRuntimeMount(io, allocator, chroot_dir, chroot_path, source, "lib", bind_mounts);
    if (sources.lib64) |source| try appendCachedRuntimeMount(io, allocator, chroot_dir, chroot_path, source, "lib64", bind_mounts);
    if (sources.usr_lib) |source| try appendCachedRuntimeMount(io, allocator, chroot_dir, chroot_path, source, "usr/lib", bind_mounts);
    if (sources.etc) |source| try appendCachedRuntimeMount(io, allocator, chroot_dir, chroot_path, source, "etc", bind_mounts);
}

fn appendCachedShellRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    sources: *const RuntimeMountSources,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    if (sources.bin) |source| try appendCachedRuntimeMount(io, allocator, chroot_dir, chroot_path, source, "bin", bind_mounts);
    if (sources.usr_bin) |source| try appendCachedRuntimeMount(io, allocator, chroot_dir, chroot_path, source, "usr/bin", bind_mounts);
}

fn appendCachedRuntimeMount(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    source: [:0]const u8,
    target_rel: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    try chroot_dir.createDirPath(io, target_rel);
    const target = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ chroot_path, target_rel }, 0);
    errdefer allocator.free(target);
    try bind_mounts.append(allocator, .{
        .source = @constCast(source),
        .target = target,
    });
}

pub const OwnedActionResult = struct {
    result: reapi.ActionResult,
    output_files: []reapi.OutputFile,
    output_directories: []reapi.OutputDirectory,
    hash_strings: []const []u8,

    pub fn deinit(self: *OwnedActionResult, allocator: std.mem.Allocator) void {
        for (self.hash_strings) |hash| allocator.free(hash);
        allocator.free(self.hash_strings);
        allocator.free(self.output_files);
        allocator.free(self.output_directories);
        self.* = undefined;
    }
};

pub fn actionResultFromOutcomeOwned(
    allocator: std.mem.Allocator,
    outcome: action_runner.Outcome,
) !OwnedActionResult {
    var hash_strings: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (hash_strings.items) |hash| allocator.free(hash);
        hash_strings.deinit(allocator);
    }

    var output_files = try allocator.alloc(reapi.OutputFile, outcome.output_files.len);
    errdefer allocator.free(output_files);
    var output_directories = try allocator.alloc(reapi.OutputDirectory, outcome.output_directories.len);
    errdefer allocator.free(output_directories);

    for (outcome.output_files, 0..) |output_file, i| {
        output_files[i] = .{
            .path = output_file.path,
            .digest = try appendDigest(allocator, &hash_strings, output_file.digest),
            .is_executable = output_file.is_executable,
        };
    }
    for (outcome.output_directories, 0..) |output_directory, i| {
        output_directories[i] = .{
            .path = output_directory.path,
            .tree_digest = try appendDigest(allocator, &hash_strings, output_directory.tree_digest),
            .root_directory_digest = if (output_directory.root_directory_digest) |digest| try appendDigest(allocator, &hash_strings, digest) else null,
        };
    }

    return .{
        .result = .{
            .output_files = output_files,
            .output_directories = output_directories,
            .exit_code = switch (outcome.status) {
                .exited => |code| code,
                .signaled => |signal| 128 + @as(i32, signal),
                .stopped, .unknown => 1,
            },
            .stdout_digest = if (outcome.stdout_digest) |digest| try appendDigest(allocator, &hash_strings, digest) else null,
            .stderr_digest = if (outcome.stderr_digest) |digest| try appendDigest(allocator, &hash_strings, digest) else null,
            .execution_metadata = outcome.execution_metadata,
        },
        .output_files = output_files,
        .output_directories = output_directories,
        .hash_strings = try hash_strings.toOwnedSlice(allocator),
    };
}

fn appendDigest(
    allocator: std.mem.Allocator,
    hash_strings: *std.ArrayListUnmanaged([]u8),
    digest: cas.Digest,
) !reapi.Digest {
    var buffer: [64]u8 = undefined;
    const owned_hash = try allocator.dupe(u8, digest.formatHex(&buffer));
    errdefer allocator.free(owned_hash);
    try hash_strings.append(allocator, owned_hash);
    return .{
        .hash = owned_hash,
        .size_bytes = @intCast(digest.size_bytes),
    };
}

fn timestampNow(io: std.Io) reapi.Timestamp {
    return timestampFromIo(std.Io.Clock.real.now(io));
}

fn timestampFromIo(timestamp: std.Io.Timestamp) reapi.Timestamp {
    const seconds = @divTrunc(timestamp.nanoseconds, std.time.ns_per_s);
    const nanos = timestamp.nanoseconds - seconds * std.time.ns_per_s;
    return .{
        .seconds = @intCast(seconds),
        .nanos = @intCast(nanos),
    };
}

fn elapsedNs(start: std.Io.Timestamp, end: std.Io.Timestamp) i96 {
    return start.durationTo(end).nanoseconds;
}

fn logActionTiming(
    action_digest: cas.Digest,
    total_start: std.Io.Timestamp,
    input_fetch_start: std.Io.Timestamp,
    input_fetch_completed: std.Io.Timestamp,
    execution_start: std.Io.Timestamp,
    execution_completed: std.Io.Timestamp,
    output_upload_start: std.Io.Timestamp,
    output_upload_completed: std.Io.Timestamp,
    bind_mounts: usize,
    output_files: usize,
    output_directories: usize,
    stress_case: []const u8,
    actiondfs_mode: ActiondfsMode,
) void {
    var hash: [64]u8 = undefined;
    std.log.info(
        "execute timing {s}/{d}: total_ns={d} input_fetch_ns={d} execution_ns={d} output_upload_ns={d} bind_mounts={d} output_files={d} output_directories={d} stress_case={s} input_mode={s}",
        .{
            action_digest.formatHex(&hash),
            action_digest.size_bytes,
            elapsedNs(total_start, output_upload_completed),
            elapsedNs(input_fetch_start, input_fetch_completed),
            elapsedNs(execution_start, execution_completed),
            elapsedNs(output_upload_start, output_upload_completed),
            bind_mounts,
            output_files,
            output_directories,
            stress_case,
            actiondfs_mode.label(),
        },
    );
}

fn logRunnerTiming(
    action_digest: cas.Digest,
    timing: action_runner.RunTiming,
) void {
    var hash: [64]u8 = undefined;
    std.log.info(
        "runner timing {s}/{d}: parent_prepare_ns={d} fork_ns={d} child_setup_ns={d} process_io_ns={d} wait_ns={d} stdio_digest_ns={d} bind_mounts={d} actiondfs_mounts={d} setup_signaled={}",
        .{
            action_digest.formatHex(&hash),
            action_digest.size_bytes,
            timing.parent_prepare_ns,
            timing.fork_ns,
            timing.child_setup_ns,
            timing.process_io_ns,
            timing.wait_ns,
            timing.stdio_digest_ns,
            timing.bind_mounts,
            timing.actiondfs_mounts,
            timing.setup_signaled,
        },
    );
}

fn logExecuteSetupError(phase: []const u8, action_digest: cas.Digest, err: anyerror) void {
    var hash: [64]u8 = undefined;
    std.log.err("execute setup {s}/{d}: {s} failed: {s}", .{
        action_digest.formatHex(&hash),
        action_digest.size_bytes,
        phase,
        @errorName(err),
    });
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyExecPath;
    if (std.fs.path.isAbsolute(path)) return error.EscapingExecPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EscapingExecPath;

    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.EscapingExecPath;
        }
    }
}

fn validateEntryName(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
    {
        return error.InvalidDirectoryEntryName;
    }
}

fn collectOutputFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    command: reapi.Command,
    outcome: *action_runner.Outcome,
) !void {
    var output_files: std.ArrayListUnmanaged(action_runner.Outcome.OutputFile) = .empty;
    var output_directories: std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory) = .empty;
    errdefer {
        for (output_files.items) |output_file| allocator.free(output_file.path);
        for (output_directories.items) |output_directory| allocator.free(output_directory.path);
        output_files.deinit(allocator);
        output_directories.deinit(allocator);
    }

    if (command.output_paths.len != 0) {
        for (command.output_paths) |path| {
            try collectOutputPath(io, allocator, store, staged_index, work_root, path, &output_files, &output_directories);
        }
    } else {
        for (command.output_files) |path| {
            try collectOutputFile(io, allocator, store, staged_index, work_root, path, &output_files);
        }
        for (command.output_directories) |path| {
            try collectOutputDirectory(io, allocator, store, staged_index, work_root, path, &output_directories);
        }
    }

    outcome.output_files = try output_files.toOwnedSlice(allocator);
    outcome.output_directories = try output_directories.toOwnedSlice(allocator);
}

fn collectOutputPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    path: []const u8,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    try validatePath(path);
    const stat = work_root.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    switch (stat.kind) {
        .file => try collectOutputFileWithStat(io, allocator, store, staged_index, work_root, path, stat, output_files),
        .directory => try collectOutputDirectoryWithStat(io, allocator, store, staged_index, work_root, path, output_directories),
        else => return error.FailedPrecondition,
    }
}

fn collectOutputFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    path: []const u8,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
) !void {
    try validatePath(path);
    const stat = work_root.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file) return error.FailedPrecondition;
    try collectOutputFileWithStat(io, allocator, store, staged_index, work_root, path, stat, output_files);
}

fn collectOutputFileWithStat(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    path: []const u8,
    stat: std.Io.Dir.Stat,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
) !void {
    if (stat.size > max_output_file_bytes) return error.FileTooBig;

    const digest = putOutputFile(io, allocator, store, work_root, path, stat) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (staged_index) |index| try index.add(io, allocator, digest);

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    try output_files.append(allocator, .{
        .path = path_copy,
        .digest = digest,
        .is_executable = isExecutable(stat),
    });
}

fn putOutputFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    path: []const u8,
    stat: std.Io.Dir.Stat,
) !cas.Digest {
    if (!isDepfileOutput(path)) return store.putFilePromoteWithStat(io, work_root, path, stat);

    const bytes = try work_root.readFileAlloc(io, path, allocator, .limited(max_output_file_bytes));
    defer allocator.free(bytes);
    const normalized = try stripChrootExecrootPrefix(allocator, bytes);
    defer allocator.free(normalized);
    return try store.putBytes(io, normalized);
}

fn isDepfileOutput(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".d");
}

fn stripChrootExecrootPrefix(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, bytes, chroot_execroot_prefix) == null) {
        return try allocator.dupe(u8, bytes);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var remaining = bytes;
    while (std.mem.indexOf(u8, remaining, chroot_execroot_prefix)) |index| {
        try out.appendSlice(allocator, remaining[0..index]);
        remaining = remaining[index + chroot_execroot_prefix.len ..];
    }
    try out.appendSlice(allocator, remaining);
    return try out.toOwnedSlice(allocator);
}

fn collectOutputDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    path: []const u8,
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    try validatePath(path);
    const stat = work_root.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) return error.FailedPrecondition;
    try collectOutputDirectoryWithStat(io, allocator, store, staged_index, work_root, path, output_directories);
}

fn collectOutputDirectoryWithStat(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    path: []const u8,
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    var dir = try work_root.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var tree = OutputTreeBuilder{};
    defer tree.deinit(allocator);
    const root_directory_digest = try putOutputDirectoryTree(io, allocator, store, staged_index, dir, &tree, true);
    const tree_digest = try tree.putTreeProto(io, allocator, store);
    if (staged_index) |index| try index.add(io, allocator, tree_digest);

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    try output_directories.append(allocator, .{
        .path = path_copy,
        .tree_digest = tree_digest,
        .root_directory_digest = root_directory_digest,
    });
}

fn prepareOutputParents(
    io: std.Io,
    work_root: std.Io.Dir,
    command: reapi.Command,
) !void {
    if (command.output_paths.len != 0) {
        for (command.output_paths) |path| try createOutputParent(io, work_root, path);
        return;
    }

    for (command.output_files) |path| try createOutputParent(io, work_root, path);
    for (command.output_directories) |path| try createOutputParent(io, work_root, path);
}

fn createOutputParent(io: std.Io, work_root: std.Io.Dir, path: []const u8) !void {
    if (path.len == 0) return;
    try validatePath(path);
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (last_slash == 0) return;
    try work_root.createDirPath(io, path[0..last_slash]);
}

fn prepareChrootBaseDirs(io: std.Io, chroot_root: std.Io.Dir) !void {
    try chroot_root.createDirPath(io, "dev");
    try chroot_root.createDirPath(io, "proc");
    try chroot_root.createDirPath(io, "tmp");
    try chroot_root.createDirPath(io, "var/tmp");
}

fn appendDevNullMount(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    try chroot_dir.writeFile(io, .{
        .sub_path = "dev/null",
        .data = "",
    });
    const source = try allocator.dupeZ(u8, "/dev/null");
    errdefer allocator.free(source);
    const target = try std.fmt.allocPrintSentinel(allocator, "{s}/dev/null", .{chroot_path}, 0);
    errdefer allocator.free(target);
    try bind_mounts.append(allocator, .{
        .source = source,
        .target = target,
        .read_only = false,
    });
}

fn isExecutable(stat: std.Io.Dir.Stat) bool {
    if (comptime !std.Io.File.Permissions.has_executable_bit) return false;
    return stat.permissions.toMode() & 0o111 != 0;
}

const DirectoryEntry = struct {
    name: []u8,
    kind: std.Io.File.Kind,
};

const OutputTreeBuilder = struct {
    root: ?reapi.Directory = null,
    children: std.ArrayListUnmanaged(reapi.Directory) = .empty,
    strings: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *OutputTreeBuilder, allocator: std.mem.Allocator) void {
        if (self.root) |*root| root.deinit(allocator);
        for (self.children.items) |*child| child.deinit(allocator);
        self.children.deinit(allocator);
        for (self.strings.items) |value| allocator.free(value);
        self.strings.deinit(allocator);
        self.* = .{};
    }

    fn dupe(self: *OutputTreeBuilder, allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        const owned = try allocator.dupe(u8, value);
        errdefer allocator.free(owned);
        try self.strings.append(allocator, owned);
        return owned;
    }

    fn appendDigest(
        self: *OutputTreeBuilder,
        allocator: std.mem.Allocator,
        digest: cas.Digest,
    ) !reapi.Digest {
        var buffer: [64]u8 = undefined;
        const owned_hash = try self.dupe(allocator, digest.formatHex(&buffer));
        return .{
            .hash = owned_hash,
            .size_bytes = @intCast(digest.size_bytes),
        };
    }

    fn putTreeProto(
        self: *OutputTreeBuilder,
        io: std.Io,
        allocator: std.mem.Allocator,
        store: cas.Store,
    ) !cas.Digest {
        const root = self.root orelse return error.MissingRootDigest;
        return try putProto(io, allocator, store, reapi.Tree{
            .root = root,
            .children = self.children.items,
        });
    }
};

fn putOutputDirectoryTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    dir: std.Io.Dir,
    tree: *OutputTreeBuilder,
    is_root: bool,
) !cas.Digest {
    var entries: std.ArrayListUnmanaged(DirectoryEntry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }

    std.mem.sort(DirectoryEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    var files: std.ArrayListUnmanaged(reapi.FileNode) = .empty;
    errdefer files.deinit(allocator);
    var directories: std.ArrayListUnmanaged(reapi.DirectoryNode) = .empty;
    errdefer directories.deinit(allocator);

    for (entries.items) |entry| {
        try validateEntryName(entry.name);
        switch (entry.kind) {
            .file => {
                const stat = try dir.statFile(io, entry.name, .{});
                const digest = try store.putFilePromoteWithStat(io, dir, entry.name, stat);
                if (staged_index) |index| try index.add(io, allocator, digest);
                try files.append(allocator, .{
                    .name = try tree.dupe(allocator, entry.name),
                    .digest = try tree.appendDigest(allocator, digest),
                    .is_executable = isExecutable(stat),
                });
            },
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                const digest = try putOutputDirectoryTree(io, allocator, store, staged_index, child, tree, false);
                try directories.append(allocator, .{
                    .name = try tree.dupe(allocator, entry.name),
                    .digest = try tree.appendDigest(allocator, digest),
                });
            },
            else => return error.UnsupportedOutputDirectoryEntry,
        }
    }

    const file_slice = try files.toOwnedSlice(allocator);
    var file_slice_owned = true;
    errdefer if (file_slice_owned) allocator.free(file_slice);
    const directory_slice = try directories.toOwnedSlice(allocator);
    var directory_slice_owned = true;
    errdefer if (directory_slice_owned) allocator.free(directory_slice);
    var directory = reapi.Directory{
        .files = file_slice,
        .directories = directory_slice,
    };
    file_slice_owned = false;
    directory_slice_owned = false;
    var directory_owned = true;
    errdefer if (directory_owned) directory.deinit(allocator);

    const digest = try putProto(io, allocator, store, directory);
    if (staged_index) |index| try index.add(io, allocator, digest);
    if (is_root) {
        tree.root = directory;
    } else {
        try tree.children.append(allocator, directory);
    }
    directory_owned = false;
    return digest;
}

fn putProto(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    value: anytype,
) !cas.Digest {
    const bytes = try reapi.encodeAlloc(allocator, value);
    defer allocator.free(bytes);
    return try store.putBytes(io, bytes);
}

test "libc runtime platform property accepts pinned runtimes" {
    try std.testing.expectEqualStrings("glibc2.31", (try libcRuntimeFromPlatform(.{
        .properties = &.{.{ .name = "libc", .value = "glibc2.31" }},
    })).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try libcRuntimeFromPlatform(.{
        .properties = &.{.{ .name = "libc", .value = "none" }},
    }));
    try std.testing.expectError(error.UnsupportedLibcRuntime, libcRuntimeFromPlatform(.{
        .properties = &.{.{ .name = "libc", .value = "glibc2.17" }},
    }));
}

test "execution platform falls back to command platform" {
    const platform = executionPlatform(
        .{},
        .{ .platform = .{ .properties = &.{.{ .name = "libc", .value = "glibc2.35" }} } },
    );
    try std.testing.expectEqualStrings("libc", platform.?.properties[0].name);
    try std.testing.expectEqualStrings("glibc2.35", platform.?.properties[0].value);

    const action_platform = executionPlatform(
        .{ .platform = .{ .properties = &.{.{ .name = "libc", .value = "glibc2.39" }} } },
        .{ .platform = .{ .properties = &.{.{ .name = "libc", .value = "glibc2.35" }} } },
    );
    try std.testing.expectEqualStrings("glibc2.39", action_platform.?.properties[0].value);
}

test "actionMutatesInputs parses platform property" {
    try std.testing.expect(!actionMutatesInputs(null));
    try std.testing.expect(!actionMutatesInputs(.{
        .properties = &.{.{ .name = "mutates_inputs", .value = "false" }},
    }));
    try std.testing.expect(!actionMutatesInputs(.{
        .properties = &.{.{ .name = "mutates_inputs", .value = "0" }},
    }));
    try std.testing.expect(actionMutatesInputs(.{
        .properties = &.{.{ .name = "mutates_inputs", .value = "1" }},
    }));
    try std.testing.expect(actionMutatesInputs(.{
        .properties = &.{.{ .name = "mutates_inputs", .value = "yes" }},
    }));
    try std.testing.expect(actionMutatesInputs(.{
        .properties = &.{.{ .name = "mutates_inputs", .value = "legacy-tool" }},
    }));
}

test "prepareExecuteOptions caches CAS and runtime mount sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    try cas.Store.init(cas_dir).ensureLayout(std.testing.io);

    const arch = try runtimeArch();
    const runtime_usr_lib = try std.fmt.allocPrint(std.testing.allocator, "runtimes/libc/glibc2.35/{s}/root/usr/lib", .{arch});
    defer std.testing.allocator.free(runtime_usr_lib);
    try tmp.dir.createDirPath(std.testing.io, runtime_usr_lib);
    try tmp.dir.createDirPath(std.testing.io, "runtimes/common/root/etc");

    var base_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buffer);
    const base_path = base_buffer[0..base_len];
    const runtime_root_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/runtimes", .{base_path});
    defer std.testing.allocator.free(runtime_root_path);

    var prepared = try prepareExecuteOptions(std.testing.io, std.testing.allocator, cas.Store.initReady(cas_dir), .{
        .runtime_root_path = runtime_root_path,
    });
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.options.cas_blob_root_path != null);
    try std.testing.expect(std.mem.endsWith(u8, prepared.options.cas_blob_root_path.?, "/cas/blobs/sha256"));

    const cache = prepared.options.runtime_mount_cache.?;
    try std.testing.expect(cache.common.etc != null);
    try std.testing.expect(cache.glibc2_35.lib != null);
    try std.testing.expect(cache.glibc2_35.usr_lib != null);
    try std.testing.expect(cache.glibc2_31.lib == null);
}

test "prepareExecuteOptions places actiondfs stage beside CAS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    try cas.Store.init(cas_dir).ensureLayout(std.testing.io);

    var prepared = try prepareExecuteOptions(std.testing.io, std.testing.allocator, cas.Store.initReady(cas_dir), .{});
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.options.actiondfs_stage_root_path != null);
    try std.testing.expect(std.mem.endsWith(u8, prepared.options.actiondfs_stage_root_path.?, "/cas/actiondfs-stage"));
}

test "actiondfs workspace uses build-time filesystem name without mount option noise" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root_path = root_buffer[0..root_len];
    const work_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/work", .{root_path});
    defer std.testing.allocator.free(work_path);
    try tmp.dir.createDir(std.testing.io, "work", .default_dir);

    var workspace = try ActiondfsWorkspace.init(
        std.testing.io,
        std.testing.allocator,
        "/cas/blobs/sha256",
        null,
        work_path,
        "/workspace",
        cas.Digest.empty(),
        .actiondfs_strict,
    );
    defer workspace.deinit(std.testing.io, std.testing.allocator);

    try std.testing.expectEqualStrings(build_options.actiondfs_fstype, workspace.fstype);
    try std.testing.expect(std.mem.indexOf(u8, workspace.actiondfs_data, "stats=") == null);
    switch (workspace.mounts[0]) {
        .strict => |mount| try std.testing.expectEqualStrings(build_options.actiondfs_fstype, mount.fstype),
        .overlay => return error.UnexpectedMountMode,
    }
}

test "validatePath rejects absolute and escaping paths" {
    try validatePath("src/main.c");
    try std.testing.expectError(error.EmptyExecPath, validatePath(""));
    try std.testing.expectError(error.EscapingExecPath, validatePath("/abs"));
    try std.testing.expectError(error.EscapingExecPath, validatePath("../escape"));
    try std.testing.expectError(error.EscapingExecPath, validatePath("a/../escape"));
    try std.testing.expectError(error.EscapingExecPath, validatePath("a//b"));
    try std.testing.expectError(error.EscapingExecPath, validatePath("./b"));
}

test "collectOutputFiles uploads requested output files and directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    try work_dir.createDirPath(std.testing.io, "out");
    try work_dir.writeFile(std.testing.io, .{
        .sub_path = "out/file.txt",
        .data = "artifact",
        .flags = .{ .permissions = .executable_file },
    });
    try work_dir.createDirPath(std.testing.io, "tree/sub");
    try work_dir.writeFile(std.testing.io, .{
        .sub_path = "tree/sub/file.txt",
        .data = "leaf",
    });

    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.testing.allocator.alloc(u8, 0),
    };
    defer outcome.deinit(std.testing.allocator);

    try collectOutputFiles(std.testing.io, std.testing.allocator, store, null, work_dir, .{
        .output_paths = &.{ "out/file.txt", "tree" },
        .output_directory_format = .tree_and_directory,
    }, &outcome);

    try std.testing.expectEqual(@as(usize, 1), outcome.output_files.len);
    try std.testing.expectEqualStrings("out/file.txt", outcome.output_files[0].path);
    try std.testing.expect(outcome.output_files[0].is_executable);
    const output = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.output_files[0].digest);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("artifact", output);

    try std.testing.expectEqual(@as(usize, 1), outcome.output_directories.len);
    try std.testing.expectEqualStrings("tree", outcome.output_directories[0].path);

    const tree_bytes = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.output_directories[0].tree_digest);
    defer std.testing.allocator.free(tree_bytes);
    var tree_reader = protobuf.Reader.init(tree_bytes);
    var root_directory: ?reapi.Directory = null;
    defer if (root_directory) |*directory| directory.deinit(std.testing.allocator);
    var child_directories: std.ArrayListUnmanaged(reapi.Directory) = .empty;
    defer {
        for (child_directories.items) |*directory| directory.deinit(std.testing.allocator);
        child_directories.deinit(std.testing.allocator);
    }
    while (try tree_reader.next()) |tag| switch (tag.field_number) {
        1 => {
            var nested = try tree_reader.readMessage();
            root_directory = try reapi.Directory.decodeOwned(std.testing.allocator, &nested);
        },
        2 => {
            var nested = try tree_reader.readMessage();
            try child_directories.append(std.testing.allocator, try reapi.Directory.decodeOwned(std.testing.allocator, &nested));
        },
        else => try tree_reader.skipField(tag.wire_type),
    };

    const root = root_directory orelse return error.MissingRootDigest;
    try std.testing.expectEqual(@as(usize, 1), root.directories.len);
    try std.testing.expectEqualStrings("sub", root.directories[0].name);
    try std.testing.expectEqual(@as(usize, 1), child_directories.items.len);
    try std.testing.expectEqual(@as(usize, 1), child_directories.items[0].files.len);
    try std.testing.expectEqualStrings("file.txt", child_directories.items[0].files[0].name);
    const child_file_digest = try cas.Digest.fromReapi(child_directories.items[0].files[0].digest orelse return error.MissingFileDigest);
    const child_file = try store.readAlloc(std.testing.io, std.testing.allocator, child_file_digest);
    defer std.testing.allocator.free(child_file);
    try std.testing.expectEqualStrings("leaf", child_file);

    var result = try actionResultFromOutcomeOwned(std.testing.allocator, outcome);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.result.output_directories.len);
    try std.testing.expectEqualStrings("tree", result.result.output_directories[0].path);
    var tree_hash: [64]u8 = undefined;
    try std.testing.expect(result.result.output_directories[0].tree_digest.?.eql(outcome.output_directories[0].tree_digest.toReapi(&tree_hash)));
    var root_hash: [64]u8 = undefined;
    try std.testing.expect(result.result.output_directories[0].root_directory_digest.?.eql(outcome.output_directories[0].root_directory_digest.?.toReapi(&root_hash)));
}

test "collectOutputFiles includes root directory digest for tree-only output directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    try work_dir.createDirPath(std.testing.io, "tree");
    try work_dir.writeFile(std.testing.io, .{
        .sub_path = "tree/file.txt",
        .data = "leaf",
    });

    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.testing.allocator.alloc(u8, 0),
    };
    defer outcome.deinit(std.testing.allocator);

    try collectOutputFiles(std.testing.io, std.testing.allocator, store, null, work_dir, .{
        .output_paths = &.{"tree"},
    }, &outcome);

    try std.testing.expectEqual(@as(usize, 1), outcome.output_directories.len);
    try std.testing.expect(outcome.output_directories[0].root_directory_digest != null);

    var result = try actionResultFromOutcomeOwned(std.testing.allocator, outcome);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.result.output_directories[0].tree_digest != null);
    try std.testing.expect(result.result.output_directories[0].root_directory_digest != null);
}

test "collectOutputFiles strips chroot execroot prefix from depfiles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    try store.ensureLayout(std.testing.io);
    try work_dir.createDirPath(std.testing.io, "bazel-out/pkg");
    try work_dir.writeFile(std.testing.io, .{
        .sub_path = "bazel-out/pkg/file.d",
        .data = "bazel-out/pkg/file.o: /workspace/external/tool/include/stddef.h /workspace/pkg/input.c\n",
    });

    var outcome: action_runner.Outcome = .{ .status = .{ .exited = 0 }, .stdout = &.{}, .stderr = &.{} };
    defer outcome.deinit(std.testing.allocator);
    try collectOutputFiles(std.testing.io, std.testing.allocator, store, null, work_dir, .{
        .output_files = &.{"bazel-out/pkg/file.d"},
    }, &outcome);

    const depfile = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.output_files[0].digest);
    defer std.testing.allocator.free(depfile);
    try std.testing.expectEqualStrings(
        "bazel-out/pkg/file.o: external/tool/include/stddef.h pkg/input.c\n",
        depfile,
    );
}

test "prepareOutputParents creates parent directories for declared outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    try prepareOutputParents(std.testing.io, work_dir, .{
        .output_files = &.{"gen/out.txt"},
    });
    _ = try work_dir.statFile(std.testing.io, "gen", .{});
}

test "prepareOutputParents creates parent directories for declared output directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    try prepareOutputParents(std.testing.io, work_dir, .{
        .output_directories = &.{"gen/tree"},
    });
    _ = try work_dir.statFile(std.testing.io, "gen", .{});
    try std.testing.expectError(error.FileNotFound, work_dir.statFile(std.testing.io, "gen/tree", .{}));
}

test "prepareOutputParents creates parent directories for declared output paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    try prepareOutputParents(std.testing.io, work_dir, .{
        .output_paths = &.{"bazel-out/bin/pkg/out.txt"},
    });
    _ = try work_dir.statFile(std.testing.io, "bazel-out/bin/pkg", .{});
}

test "prepareOutputParents ignores legacy output fields when output_paths is present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    try prepareOutputParents(std.testing.io, work_dir, .{
        .output_paths = &.{"new/out.txt"},
        .output_files = &.{"legacy/file.txt"},
        .output_directories = &.{"legacy/tree"},
    });

    _ = try work_dir.statFile(std.testing.io, "new", .{});
    try std.testing.expectError(error.FileNotFound, work_dir.statFile(std.testing.io, "legacy", .{}));
}

test "prepareOutputParents accepts Bazel-style external output paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const output_path =
        "bazel-out/darwin_arm64-fastbuild/bin/external/rules_zig++zig+zig_0.16.0_aarch64-macos/zig_toolchain.version_validation";

    try prepareOutputParents(std.testing.io, work_dir, .{
        .output_paths = &.{output_path},
    });
    _ = try work_dir.statFile(std.testing.io, "bazel-out/darwin_arm64-fastbuild/bin/external/rules_zig++zig+zig_0.16.0_aarch64-macos", .{});
}

test "prepareChrootBaseDirs creates temporary directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    try prepareChrootBaseDirs(std.testing.io, work_dir);
    try work_dir.access(std.testing.io, "tmp", .{});
    try work_dir.access(std.testing.io, "var/tmp", .{});
}
