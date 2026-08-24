const builtin = @import("builtin");
const std = @import("std");
const action_runner = @import("action_runner.zig");
const build_options = @import("actiond_build_options");
const cas = @import("cas.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");
const staged_cas_index = @import("staged_cas_index.zig");

const max_output_file_bytes = 1024 * 1024 * 1024;
const max_output_depfile_bytes = 16 * 1024 * 1024;
const max_output_aggregate_file_bytes = 4 * max_output_file_bytes;
const max_output_directory_proto_bytes = 64 * 1024 * 1024;
const max_output_tree_proto_bytes = 64 * 1024 * 1024;
const max_output_metadata_bytes = 128 * 1024 * 1024;
const max_output_entries = 256 * 1024;
const max_output_directory_depth = 128;
const chroot_execroot_prefix = "/execroot/";
const worker_name = "actiond";
const supported_libc_runtimes = [_][]const u8{ "glibc2.31", "glibc2.35", "glibc2.39" };
var next_actiondfs_workspace_id = std.atomic.Value(u64).init(0);

inline fn executorTimingNow(io: std.Io) std.Io.Timestamp {
    return if (comptime build_options.executor_timing_logs)
        std.Io.Clock.awake.now(io)
    else
        undefined;
}

fn checkExecutionCancellation(cancellation: ?*const std.atomic.Value(bool)) !void {
    if (cancellation) |value| {
        if (value.load(.acquire)) return error.ExecutionCancelled;
    }
}

pub const RuntimeMountSources = struct {
    bin: ?[:0]const u8 = null,
    lib: ?[:0]const u8 = null,
    lib64: ?[:0]const u8 = null,
    usr_bin: ?[:0]const u8 = null,
    usr_lib: ?[:0]const u8 = null,

    fn deinit(self: *RuntimeMountSources, allocator: std.mem.Allocator) void {
        if (self.bin) |path| allocator.free(path);
        if (self.lib) |path| allocator.free(path);
        if (self.lib64) |path| allocator.free(path);
        if (self.usr_bin) |path| allocator.free(path);
        if (self.usr_lib) |path| allocator.free(path);
        self.* = .{};
    }
};

pub const RuntimeMountCache = struct {
    common_etc: [:0]const u8,
    glibc2_31: RuntimeMountSources = .{},
    glibc2_35: RuntimeMountSources = .{},
    glibc2_39: RuntimeMountSources = .{},
    bash: RuntimeMountSources = .{},

    fn deinit(self: *RuntimeMountCache, allocator: std.mem.Allocator) void {
        allocator.free(self.common_etc);
        self.glibc2_31.deinit(allocator);
        self.glibc2_35.deinit(allocator);
        self.glibc2_39.deinit(allocator);
        self.bash.deinit(allocator);
        self.* = undefined;
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
    cancellation: ?*const std.atomic.Value(bool) = null,
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
    try checkExecutionCancellation(options.cancellation);
    const worker_start_wall = timestampNow(io);
    const input_fetch_start_wall = worker_start_wall;
    const total_start = executorTimingNow(io);
    const input_fetch_start = total_start;

    const command_digest = try cas.Digest.fromReapi(action.command_digest orelse return error.MissingCommandDigest);
    try checkExecutionCancellation(options.cancellation);
    const command_bytes = store.readAlloc(io, allocator, command_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCommandBlob,
        else => return err,
    };
    defer allocator.free(command_bytes);
    try checkExecutionCancellation(options.cancellation);
    var command_reader = protobuf.Reader.init(command_bytes);
    var command = try reapi.Command.decodeOwned(allocator, &command_reader);
    defer command.deinit(allocator);
    try checkExecutionCancellation(options.cancellation);
    var output_preflight: OutputCollectionBudget = .{ .cancellation = options.cancellation };
    try reserveDeclaredOutputs(&output_preflight, command);
    try checkExecutionCancellation(options.cancellation);
    const platform = executionPlatform(action, command);

    const input_root_digest = try cas.Digest.fromReapi(action.input_root_digest orelse return error.MissingInputRootDigest);
    const actiondfs_mode: ActiondfsMode = if (actionMutatesInputs(platform))
        .actiondfs_overlay
    else
        .actiondfs_strict;
    try validateOutputParentsAgainstInputsWithCancellation(io, allocator, store, input_root_digest, command, options.cancellation);
    try checkExecutionCancellation(options.cancellation);

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try work_root.realPath(io, &cwd_buffer);
    const work_root_path = cwd_buffer[0..cwd_len];
    try work_root.createDirPath(io, "execroot");
    const workspace_path = try std.fmt.allocPrint(allocator, "{s}/execroot", .{work_root_path});
    defer allocator.free(workspace_path);
    try prepareChrootBaseDirs(io, work_root);
    try checkExecutionCancellation(options.cancellation);

    var owned_cas_blob_root_path: ?[]u8 = null;
    defer if (owned_cas_blob_root_path) |path| allocator.free(path);
    const cas_blob_root_path = options.cas_blob_root_path orelse path: {
        var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cas_root_len = try store.root.realPath(io, &cas_root_buffer);
        const value = try std.fmt.allocPrint(allocator, "{s}/blobs/sha256", .{cas_root_buffer[0..cas_root_len]});
        owned_cas_blob_root_path = value;
        break :path value;
    };
    try checkExecutionCancellation(options.cancellation);
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
    try checkExecutionCancellation(options.cancellation);

    var actiondfs_stage_dir = try std.Io.Dir.openDirAbsolute(io, actiondfs_workspace.stagePath(), .{ .iterate = true });
    defer actiondfs_stage_dir.close(io);
    prepareOutputParentsWithCancellation(io, actiondfs_stage_dir, command, options.cancellation) catch |err| switch (err) {
        error.FileNotFound => return error.OutputParentCreateFailed,
        error.ExecutionCancelled => return error.ExecutionCancelled,
        else => {
            logExecuteSetupError("prepare output parents", action_digest, err);
            return err;
        },
    };
    try checkExecutionCancellation(options.cancellation);

    var chroot_cwd_owned: ?[]u8 = null;
    defer if (chroot_cwd_owned) |path| allocator.free(path);
    const chroot_cwd = if (command.working_directory.len == 0)
        "/execroot"
    else cwd: {
        try validatePath(command.working_directory);
        const value = try std.fmt.allocPrint(allocator, "/execroot/{s}", .{command.working_directory});
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
        try checkExecutionCancellation(options.cancellation);
        try appendCachedRuntimeMount(io, allocator, work_root, work_root_path, cache.common_etc, "etc", &bind_mounts);
        if (libc_runtime) |libc| {
            try checkExecutionCancellation(options.cancellation);
            const sources = cache.forLibc(libc) orelse return error.UnsupportedLibcRuntime;
            try appendCachedLibcRuntimeMounts(io, allocator, work_root, work_root_path, sources, &bind_mounts);
        }
        if (shell_runtime) |shell| {
            try checkExecutionCancellation(options.cancellation);
            const sources = cache.forShell(shell) orelse return error.UnsupportedShellRuntime;
            try appendCachedShellRuntimeMounts(io, allocator, work_root, work_root_path, sources, &bind_mounts);
        }
        borrowed_source_count = bind_mounts.items.len;
    } else {
        return error.MissingRuntimeMountCache;
    }
    try checkExecutionCancellation(options.cancellation);
    try appendDevNullMount(io, allocator, work_root, work_root_path, &bind_mounts);
    try checkExecutionCancellation(options.cancellation);

    const input_fetch_completed_wall = timestampNow(io);
    const input_fetch_completed = executorTimingNow(io);
    const execution_start_wall = timestampNow(io);
    const execution_start = executorTimingNow(io);
    try checkExecutionCancellation(options.cancellation);
    var outcome = try action_runner.runCommandWithOptions(io, allocator, store, command, .{
        .chroot_dir = work_root_path,
        .chroot_cwd = chroot_cwd,
        .bind_mounts = bind_mounts.items,
        .actiondfs_mounts = actiondfs_workspace.mounts[0..],
        .cgroup_limits = action_runner.CgroupLimits.fromPlatform(platform),
        .timeout_ns = if (action.timeout) |timeout| try timeout.toNanoseconds() else null,
        .cancellation = options.cancellation,
    });
    errdefer outcome.deinit(allocator);
    const execution_completed_wall = timestampNow(io);
    const execution_completed = executorTimingNow(io);
    const output_upload_start_wall = timestampNow(io);
    const output_upload_start = executorTimingNow(io);
    try checkExecutionCancellation(options.cancellation);
    if (options.staged_cas_index) |index| {
        if (outcome.stdout_digest) |digest| try index.add(io, allocator, digest);
        if (outcome.stderr_digest) |digest| try index.add(io, allocator, digest);
    }
    try actiondfs_workspace.mountForCollection();
    var collection_namespace = try ActiondfsCollectionNamespace.init(
        io,
        &actiondfs_workspace,
        work_root,
        actiondfs_stage_dir,
        bind_mounts.items,
        command,
    );
    defer collection_namespace.deinit(io);
    var output_dir = try std.Io.Dir.openDirAbsolute(io, actiondfs_workspace.collectionPath(), .{ .iterate = true });
    defer output_dir.close(io);
    try collectOutputFilesWithCancellation(
        io,
        allocator,
        store,
        options.staged_cas_index,
        output_dir,
        command,
        collection_namespace.lookup(work_root),
        options.cancellation,
        &outcome,
    );
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
    try checkExecutionCancellation(options.cancellation);
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
        switch (std.os.linux.errno(actiondfs_rc)) {
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
        switch (std.os.linux.errno(overlay_rc)) {
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

const OutputCollectionLookup = struct {
    chroot_root: std.Io.Dir,
    workspace_root: std.Io.Dir,
};

const ActiondfsCollectionNamespace = struct {
    workspace: *ActiondfsWorkspace,
    bind_mounts: []const action_runner.BindMount,
    mounted_bind_count: usize = 0,
    strict_workspace_mounted: bool = false,
    merged_workspace: ?std.Io.Dir = null,

    fn init(
        io: std.Io,
        workspace: *ActiondfsWorkspace,
        chroot_root: std.Io.Dir,
        stage_root: std.Io.Dir,
        bind_mounts: []const action_runner.BindMount,
        command: reapi.Command,
    ) !ActiondfsCollectionNamespace {
        var namespace: ActiondfsCollectionNamespace = .{
            .workspace = workspace,
            .bind_mounts = bind_mounts,
        };
        if (!try needsMergedLegacyOutputLookup(io, stage_root, command)) return namespace;
        if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;
        errdefer namespace.deinit(io);

        const linux = std.os.linux;
        if (workspace.mode == .actiondfs_strict) {
            const mount = switch (workspace.mounts[0]) {
                .strict => |strict| strict,
                .overlay => unreachable,
            };
            const mount_rc = linux.mount(
                mount.fstype.ptr,
                mount.target.ptr,
                mount.fstype.ptr,
                linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOATIME,
                @intFromPtr(mount.actiondfs_data.ptr),
            );
            if (std.os.linux.errno(mount_rc) != .SUCCESS) return error.MountFailed;
            namespace.strict_workspace_mounted = true;
        }

        for (bind_mounts) |bind_mount| {
            const mount_rc = linux.mount(bind_mount.source.ptr, bind_mount.target.ptr, null, linux.MS.BIND, 0);
            if (std.os.linux.errno(mount_rc) != .SUCCESS) return error.MountFailed;
            namespace.mounted_bind_count += 1;
            if (!bind_mount.read_only) continue;

            const remount_rc = linux.mount(
                null,
                bind_mount.target.ptr,
                null,
                linux.MS.BIND | linux.MS.REMOUNT | linux.MS.RDONLY | linux.MS.NOSUID | linux.MS.NODEV,
                0,
            );
            if (std.os.linux.errno(remount_rc) != .SUCCESS) return error.MountFailed;
        }

        namespace.merged_workspace = try chroot_root.openDir(io, "execroot", .{
            .iterate = true,
            .follow_symlinks = false,
        });
        return namespace;
    }

    fn lookup(self: *const ActiondfsCollectionNamespace, chroot_root: std.Io.Dir) ?OutputCollectionLookup {
        return if (self.merged_workspace) |workspace_root| .{
            .chroot_root = chroot_root,
            .workspace_root = workspace_root,
        } else null;
    }

    fn deinit(self: *ActiondfsCollectionNamespace, io: std.Io) void {
        if (self.merged_workspace) |workspace_root| workspace_root.close(io);
        if (comptime builtin.os.tag == .linux) {
            while (self.mounted_bind_count != 0) {
                self.mounted_bind_count -= 1;
                unmountCollectionTarget(self.bind_mounts[self.mounted_bind_count].target);
            }
            if (self.strict_workspace_mounted) {
                const mount = switch (self.workspace.mounts[0]) {
                    .strict => |strict| strict,
                    .overlay => unreachable,
                };
                unmountCollectionTarget(mount.target);
            }
        }
        self.* = undefined;
    }
};

fn unmountCollectionTarget(target: [:0]const u8) void {
    if (comptime builtin.os.tag != .linux) return;
    while (true) switch (std.os.linux.errno(std.os.linux.umount2(target.ptr, std.os.linux.MNT.DETACH))) {
        .SUCCESS, .INVAL, .NOENT => return,
        .INTR => continue,
        else => |err| {
            std.log.err("failed to unmount output collection target {s}: {s}", .{ target, @tagName(err) });
            return;
        },
    };
}

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
    const common_root = try std.fmt.allocPrint(allocator, "{s}/common/root", .{runtime_root_path});
    defer allocator.free(common_root);
    var cache: RuntimeMountCache = .{
        .common_etc = try requiredRuntimePath(io, allocator, common_root, "etc"),
    };
    errdefer cache.deinit(allocator);

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

fn requiredRuntimePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime_root: []const u8,
    source_rel: []const u8,
) ![:0]const u8 {
    return (try runtimePathIfExists(io, allocator, runtime_root, source_rel)) orelse error.MissingRuntimePath;
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
    output_symlinks: []reapi.OutputSymlink,
    output_file_symlinks: []reapi.OutputSymlink,
    output_directory_symlinks: []reapi.OutputSymlink,
    hash_strings: []const []u8,

    pub fn deinit(self: *OwnedActionResult, allocator: std.mem.Allocator) void {
        for (self.hash_strings) |hash| allocator.free(hash);
        allocator.free(self.hash_strings);
        allocator.free(self.output_files);
        allocator.free(self.output_directories);
        allocator.free(self.output_symlinks);
        allocator.free(self.output_file_symlinks);
        allocator.free(self.output_directory_symlinks);
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
    const output_symlinks = try allocator.alloc(reapi.OutputSymlink, outcome.output_symlinks.len);
    errdefer allocator.free(output_symlinks);
    const output_file_symlinks = try allocator.alloc(reapi.OutputSymlink, outcome.output_file_symlinks.len);
    errdefer allocator.free(output_file_symlinks);
    const output_directory_symlinks = try allocator.alloc(reapi.OutputSymlink, outcome.output_directory_symlinks.len);
    errdefer allocator.free(output_directory_symlinks);

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
    copyOutputSymlinks(output_symlinks, outcome.output_symlinks);
    copyOutputSymlinks(output_file_symlinks, outcome.output_file_symlinks);
    copyOutputSymlinks(output_directory_symlinks, outcome.output_directory_symlinks);

    const result: reapi.ActionResult = .{
        .output_files = output_files,
        .output_directories = output_directories,
        .output_symlinks = output_symlinks,
        .output_file_symlinks = output_file_symlinks,
        .output_directory_symlinks = output_directory_symlinks,
        .exit_code = switch (outcome.status) {
            .exited => |code| code,
            .signaled => |signal| 128 + @as(i32, signal),
            .stopped, .unknown => 1,
        },
        .stdout_digest = if (outcome.stdout_digest) |digest| try appendDigest(allocator, &hash_strings, digest) else null,
        .stderr_digest = if (outcome.stderr_digest) |digest| try appendDigest(allocator, &hash_strings, digest) else null,
        .execution_metadata = outcome.execution_metadata,
    };
    try validateActionResultEncodedLen(result.encodedLen());

    return .{
        .result = result,
        .output_files = output_files,
        .output_directories = output_directories,
        .output_symlinks = output_symlinks,
        .output_file_symlinks = output_file_symlinks,
        .output_directory_symlinks = output_directory_symlinks,
        .hash_strings = try hash_strings.toOwnedSlice(allocator),
    };
}

fn validateActionResultEncodedLen(encoded_bytes: usize) !void {
    if (encoded_bytes > max_output_metadata_bytes) return error.OutputMetadataTooLarge;
}

fn copyOutputSymlinks(
    outputs: []reapi.OutputSymlink,
    collected: []const action_runner.Outcome.OutputSymlink,
) void {
    for (outputs, collected) |*output, symlink| {
        output.* = .{
            .path = symlink.path,
            .target = symlink.target,
        };
    }
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

const OutputCollectionBudget = struct {
    entries: usize = 0,
    file_bytes: u64 = 0,
    metadata_bytes: usize = 0,
    cancellation: ?*const std.atomic.Value(bool) = null,

    fn checkCancelled(self: *const OutputCollectionBudget) !void {
        if (self.cancellation) |cancellation| {
            if (cancellation.load(.acquire)) return error.ExecutionCancelled;
        }
    }

    fn reserveEntry(self: *OutputCollectionBudget, name_bytes: usize) !void {
        try self.checkCancelled();
        if (self.entries >= max_output_entries) return error.TooManyOutputEntries;
        const doubled_name_bytes = std.math.mul(usize, name_bytes, 2) catch
            return error.OutputMetadataTooLarge;
        const entry_bytes = std.math.add(usize, doubled_name_bytes, 128) catch
            return error.OutputMetadataTooLarge;
        try self.reserveMetadata(entry_bytes);
        self.entries += 1;
    }

    fn reserveFile(self: *OutputCollectionBudget, file_bytes: u64) !void {
        try self.checkCancelled();
        if (file_bytes > max_output_file_bytes) return error.FileTooBig;
        if (file_bytes > max_output_aggregate_file_bytes - self.file_bytes)
            return error.OutputAggregateTooLarge;
        self.file_bytes += file_bytes;
    }

    fn reserveMetadata(self: *OutputCollectionBudget, metadata_bytes: usize) !void {
        try self.checkCancelled();
        if (metadata_bytes > max_output_metadata_bytes - self.metadata_bytes)
            return error.OutputMetadataTooLarge;
        self.metadata_bytes += metadata_bytes;
    }

    fn reserveDirectoryProto(self: *OutputCollectionBudget, encoded_bytes: usize) !void {
        if (encoded_bytes > max_output_directory_proto_bytes)
            return error.OutputDirectoryTooLarge;
        try self.reserveMetadata(encoded_bytes);
    }

    fn reserveTreeProto(self: *OutputCollectionBudget, encoded_bytes: usize) !void {
        if (encoded_bytes > max_output_tree_proto_bytes)
            return error.OutputTreeTooLarge;
        try self.reserveMetadata(encoded_bytes);
    }
};

fn reserveDeclaredOutputs(budget: *OutputCollectionBudget, command: reapi.Command) !void {
    if (command.output_paths.len != 0) {
        for (command.output_paths) |path| try reserveDeclaredOutput(budget, path, false);
        return;
    }

    for (command.output_files) |path| try reserveDeclaredOutput(budget, path, false);
    for (command.output_directories) |path| try reserveDeclaredOutput(budget, path, true);
}

fn reserveDeclaredOutput(
    budget: *OutputCollectionBudget,
    path: []const u8,
    allow_empty: bool,
) !void {
    try budget.checkCancelled();
    if (path.len == 0 and allow_empty) {
        try budget.reserveEntry(0);
        return;
    }
    if (path.len >= std.os.linux.PATH_MAX) return error.OutputPathTooLong;
    try validatePath(path);

    var depth: usize = 0;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        try budget.checkCancelled();
        if (component.len > std.os.linux.NAME_MAX) return error.OutputPathTooLong;
        depth += 1;
        if (depth > max_output_directory_depth) return error.OutputTreeTooDeep;
    }
    try budget.reserveEntry(path.len);
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
    try collectOutputFilesWithLookup(io, allocator, store, staged_index, work_root, command, null, outcome);
}

fn collectOutputFilesWithLookup(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    command: reapi.Command,
    lookup: ?OutputCollectionLookup,
    outcome: *action_runner.Outcome,
) !void {
    try collectOutputFilesWithCancellation(io, allocator, store, staged_index, work_root, command, lookup, null, outcome);
}

fn collectOutputFilesWithCancellation(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    command: reapi.Command,
    lookup: ?OutputCollectionLookup,
    cancellation: ?*const std.atomic.Value(bool),
    outcome: *action_runner.Outcome,
) !void {
    var budget: OutputCollectionBudget = .{ .cancellation = cancellation };
    try budget.checkCancelled();
    try reserveDeclaredOutputs(&budget, command);
    var output_files: std.ArrayListUnmanaged(action_runner.Outcome.OutputFile) = .empty;
    var output_directories: std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory) = .empty;
    var output_symlinks: std.ArrayListUnmanaged(action_runner.Outcome.OutputSymlink) = .empty;
    var output_file_symlinks: std.ArrayListUnmanaged(action_runner.Outcome.OutputSymlink) = .empty;
    var output_directory_symlinks: std.ArrayListUnmanaged(action_runner.Outcome.OutputSymlink) = .empty;
    errdefer {
        for (output_files.items) |output_file| allocator.free(output_file.path);
        for (output_directories.items) |output_directory| allocator.free(output_directory.path);
        freeCollectedOutputSymlinks(allocator, &output_symlinks);
        freeCollectedOutputSymlinks(allocator, &output_file_symlinks);
        freeCollectedOutputSymlinks(allocator, &output_directory_symlinks);
        output_files.deinit(allocator);
        output_directories.deinit(allocator);
    }

    if (command.output_paths.len != 0) {
        for (command.output_paths) |path| {
            try budget.checkCancelled();
            try collectOutputPath(io, allocator, store, staged_index, work_root, path, &budget, &output_files, &output_directories, &output_symlinks);
        }
    } else {
        for (command.output_files) |path| {
            try budget.checkCancelled();
            try collectLegacyOutputSymlink(io, allocator, work_root, path, .file, lookup, &budget, &output_file_symlinks);
        }
        for (command.output_directories) |path| {
            try budget.checkCancelled();
            if (path.len == 0) continue;
            try collectLegacyOutputSymlink(io, allocator, work_root, path, .directory, lookup, &budget, &output_directory_symlinks);
        }
        for (command.output_directories) |path| {
            try budget.checkCancelled();
            if (path.len != 0) continue;
            const root = if (lookup) |value| value.workspace_root else work_root;
            try collectOpenedOutputDirectory(io, allocator, store, staged_index, root, path, &budget, &output_directories);
        }
        for (command.output_files) |path| {
            try budget.checkCancelled();
            try collectOutputFile(io, allocator, store, staged_index, work_root, path, &budget, &output_files);
        }
        for (command.output_directories) |path| {
            try budget.checkCancelled();
            if (path.len == 0) continue;
            try collectOutputDirectory(io, allocator, store, staged_index, work_root, path, &budget, &output_directories);
        }
    }

    try budget.checkCancelled();
    outcome.output_files = try output_files.toOwnedSlice(allocator);
    outcome.output_directories = try output_directories.toOwnedSlice(allocator);
    outcome.output_symlinks = try output_symlinks.toOwnedSlice(allocator);
    outcome.output_file_symlinks = try output_file_symlinks.toOwnedSlice(allocator);
    outcome.output_directory_symlinks = try output_directory_symlinks.toOwnedSlice(allocator);
    try budget.checkCancelled();
}

fn freeCollectedOutputSymlinks(
    allocator: std.mem.Allocator,
    symlinks: *std.ArrayListUnmanaged(action_runner.Outcome.OutputSymlink),
) void {
    for (symlinks.items) |symlink| {
        allocator.free(symlink.path);
        allocator.free(symlink.target);
    }
    symlinks.deinit(allocator);
}

const OutputParentDirectory = struct {
    dir: std.Io.Dir,
    name: []const u8,
    owns_dir: bool,

    fn deinit(self: *OutputParentDirectory, io: std.Io) void {
        if (self.owns_dir) self.dir.close(io);
    }
};

fn openOutputParent(io: std.Io, work_root: std.Io.Dir, path: []const u8) !OutputParentDirectory {
    try validatePath(path);

    const parent_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{
        .dir = work_root,
        .name = path,
        .owns_dir = false,
    };

    var current_dir = work_root;
    var owns_current_dir = false;
    errdefer if (owns_current_dir) current_dir.close(io);

    var components = std.mem.splitScalar(u8, path[0..parent_end], '/');
    while (components.next()) |component| {
        const next_dir = current_dir.openDir(io, component, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
            else => return err,
        };
        if (owns_current_dir) current_dir.close(io);
        current_dir = next_dir;
        owns_current_dir = true;
    }

    return .{
        .dir = current_dir,
        .name = path[parent_end + 1 ..],
        .owns_dir = owns_current_dir,
    };
}

fn needsMergedLegacyOutputLookup(io: std.Io, stage_root: std.Io.Dir, command: reapi.Command) !bool {
    if (command.output_paths.len != 0) return false;

    for (command.output_directories) |path| {
        if (path.len == 0) return true;
    }
    for (command.output_files) |path| {
        if (try isStagedOutputSymlink(io, stage_root, path)) return true;
    }
    for (command.output_directories) |path| {
        if (try isStagedOutputSymlink(io, stage_root, path)) return true;
    }
    return false;
}

fn isStagedOutputSymlink(io: std.Io, stage_root: std.Io.Dir, path: []const u8) !bool {
    var parent = openOutputParent(io, stage_root, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer parent.deinit(io);

    const stat = parent.dir.statFile(io, parent.name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return stat.kind == .sym_link;
}

fn collectOutputPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    path: []const u8,
    budget: *OutputCollectionBudget,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
    output_symlinks: *std.ArrayListUnmanaged(action_runner.Outcome.OutputSymlink),
) !void {
    var parent = openOutputParent(io, work_root, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer parent.deinit(io);

    const stat = parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    switch (stat.kind) {
        .file => try collectOutputFileWithStat(io, allocator, store, staged_index, parent.dir, parent.name, path, stat, budget, output_files),
        .directory => try collectOutputDirectoryWithStat(io, allocator, store, staged_index, parent.dir, parent.name, path, budget, output_directories),
        .sym_link => try collectOutputSymlink(io, allocator, parent.dir, parent.name, path, budget, output_symlinks),
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
    budget: *OutputCollectionBudget,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
) !void {
    var parent = openOutputParent(io, work_root, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer parent.deinit(io);

    const stat = parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .sym_link) return;
    if (stat.kind != .file) return error.FailedPrecondition;
    try collectOutputFileWithStat(io, allocator, store, staged_index, parent.dir, parent.name, path, stat, budget, output_files);
}

fn collectOutputSymlink(
    io: std.Io,
    allocator: std.mem.Allocator,
    work_root: std.Io.Dir,
    entry_name: []const u8,
    path: []const u8,
    budget: *OutputCollectionBudget,
    output_symlinks: *std.ArrayListUnmanaged(action_runner.Outcome.OutputSymlink),
) !void {
    var target_buffer: [std.os.linux.PATH_MAX]u8 = undefined;
    const target_len = work_root.readLink(io, entry_name, &target_buffer) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (target_len >= target_buffer.len) return error.InvalidSymlinkTarget;
    const target = target_buffer[0..target_len];
    try (reapi.OutputSymlink{ .path = path, .target = target }).validate();
    try budget.reserveMetadata(target.len);

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_target = try allocator.dupe(u8, target);
    errdefer allocator.free(owned_target);
    try output_symlinks.append(allocator, .{
        .path = owned_path,
        .target = owned_target,
    });
}

fn collectLegacyOutputSymlink(
    io: std.Io,
    allocator: std.mem.Allocator,
    work_root: std.Io.Dir,
    path: []const u8,
    expected_kind: std.Io.File.Kind,
    lookup: ?OutputCollectionLookup,
    budget: *OutputCollectionBudget,
    output_symlinks: *std.ArrayListUnmanaged(action_runner.Outcome.OutputSymlink),
) !void {
    var parent = openOutputParent(io, work_root, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer parent.deinit(io);

    const stat = parent.dir.statFile(io, parent.name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .sym_link) return;

    if (lookup) |collection_lookup| {
        try validateLegacyOutputSymlinkTargetInChroot(
            io,
            allocator,
            collection_lookup,
            parent.dir,
            parent.name,
            path,
            expected_kind,
        );
    } else {
        try validateLegacyOutputSymlinkTarget(io, allocator, work_root, parent.dir, parent.name, path, expected_kind);
    }
    try collectOutputSymlink(io, allocator, parent.dir, parent.name, path, budget, output_symlinks);
}

const LinuxOpenHow = extern struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};

const openat2_resolve_no_magiclinks: u64 = 0x02;
const openat2_resolve_in_root: u64 = 0x10;
const max_output_symlink_expansions: usize = 40;

fn validateLegacyOutputSymlinkTargetInChroot(
    io: std.Io,
    allocator: std.mem.Allocator,
    lookup: OutputCollectionLookup,
    symlink_parent: std.Io.Dir,
    entry_name: []const u8,
    path: []const u8,
    expected_kind: std.Io.File.Kind,
) !void {
    var target_buffer: [std.os.linux.PATH_MAX]u8 = undefined;
    const target_len = symlink_parent.readLink(io, entry_name, &target_buffer) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
        else => return err,
    };
    if (target_len == 0 or target_len >= target_buffer.len) return error.FailedPrecondition;
    const target = target_buffer[0..target_len];

    const resolved_path = if (std.fs.path.isAbsolute(target))
        try allocator.dupeZ(u8, target)
    else if (std.mem.lastIndexOfScalar(u8, path, '/')) |parent_end|
        try std.fmt.allocPrintSentinel(allocator, "/execroot/{s}/{s}", .{ path[0..parent_end], target }, 0)
    else
        try std.fmt.allocPrintSentinel(allocator, "/execroot/{s}", .{target}, 0);
    defer allocator.free(resolved_path);

    const target_kind = if (comptime builtin.os.tag == .linux)
        try openat2OutputTargetKind(io, lookup.chroot_root, resolved_path)
    else
        try resolveOutputTargetKindPortable(io, allocator, lookup.chroot_root, resolved_path);
    if (target_kind != expected_kind) return error.FailedPrecondition;
}

fn openat2OutputTargetKind(io: std.Io, root: std.Io.Dir, path: [:0]const u8) !std.Io.File.Kind {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;
    const linux = std.os.linux;
    const open_flags: linux.O = .{
        .PATH = true,
        .CLOEXEC = true,
    };
    const flags: u32 = @bitCast(open_flags);
    const how: LinuxOpenHow = .{
        .flags = flags,
        .mode = 0,
        .resolve = openat2_resolve_in_root | openat2_resolve_no_magiclinks,
    };

    var attempts: usize = 0;
    while (true) {
        const rc = linux.syscall4(
            .openat2,
            @bitCast(@as(isize, root.handle)),
            @intFromPtr(path.ptr),
            @intFromPtr(&how),
            @sizeOf(LinuxOpenHow),
        );
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                var target_file: std.Io.File = .{
                    .handle = @intCast(rc),
                    .flags = .{ .nonblocking = false },
                };
                defer target_file.close(io);
                return (try target_file.stat(io)).kind;
            },
            .INTR, .AGAIN => {
                attempts += 1;
                if (attempts >= max_output_symlink_expansions) return error.FailedPrecondition;
            },
            .NOENT, .NOTDIR, .LOOP, .XDEV, .ACCES, .PERM, .NAMETOOLONG => return error.FailedPrecondition,
            .NOSYS, .INVAL => return error.UnsupportedSecureResolution,
            .MFILE, .NFILE, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

fn resolveOutputTargetKindPortable(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    initial_path: []const u8,
) !std.Io.File.Kind {
    var pending_path = try allocator.dupe(u8, initial_path);
    defer allocator.free(pending_path);

    var opened_directories: std.ArrayListUnmanaged(std.Io.Dir) = .empty;
    defer {
        for (opened_directories.items) |directory| directory.close(io);
        opened_directories.deinit(allocator);
    }
    var current_dir = root;
    var index: usize = 0;
    var expansions: usize = 0;

    while (true) {
        while (index < pending_path.len and pending_path[index] == '/') index += 1;
        if (index == pending_path.len) return .directory;

        const component_start = index;
        while (index < pending_path.len and pending_path[index] != '/') index += 1;
        const component = pending_path[component_start..index];
        const has_more_components = index < pending_path.len;

        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (opened_directories.pop()) |previous| previous.close(io);
            current_dir = if (opened_directories.items.len == 0)
                root
            else
                opened_directories.items[opened_directories.items.len - 1];
            continue;
        }

        const stat = current_dir.statFile(io, component, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
            else => return err,
        };
        if (stat.kind == .sym_link) {
            expansions += 1;
            if (expansions > max_output_symlink_expansions) return error.FailedPrecondition;

            var target_buffer: [std.os.linux.PATH_MAX]u8 = undefined;
            const target_len = current_dir.readLink(io, component, &target_buffer) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
                else => return err,
            };
            if (target_len == 0 or target_len >= target_buffer.len) return error.FailedPrecondition;
            const target = target_buffer[0..target_len];
            const next_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ target, pending_path[index..] });
            allocator.free(pending_path);
            pending_path = next_path;
            index = 0;

            if (std.fs.path.isAbsolute(target)) {
                while (opened_directories.pop()) |directory| directory.close(io);
                current_dir = root;
            }
            continue;
        }

        if (!has_more_components) return stat.kind;
        if (stat.kind != .directory) return error.FailedPrecondition;
        const next_dir = current_dir.openDir(io, component, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
            else => return err,
        };
        opened_directories.append(allocator, next_dir) catch |err| {
            next_dir.close(io);
            return err;
        };
        current_dir = next_dir;
    }
}

fn validateLegacyOutputSymlinkTarget(
    io: std.Io,
    allocator: std.mem.Allocator,
    work_root: std.Io.Dir,
    symlink_parent: std.Io.Dir,
    entry_name: []const u8,
    path: []const u8,
    expected_kind: std.Io.File.Kind,
) !void {
    var target_buffer: [std.os.linux.PATH_MAX]u8 = undefined;
    const target_len = symlink_parent.readLink(io, entry_name, &target_buffer) catch |err| switch (err) {
        error.FileNotFound => return error.FailedPrecondition,
        else => return err,
    };
    if (target_len == 0 or target_len >= target_buffer.len) return error.FailedPrecondition;
    const target = target_buffer[0..target_len];
    if (std.fs.path.isAbsolute(target)) return error.FailedPrecondition;

    var opened_directories: std.ArrayListUnmanaged(std.Io.Dir) = .empty;
    defer {
        for (opened_directories.items) |directory| directory.close(io);
        opened_directories.deinit(allocator);
    }
    var current_dir = work_root;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |parent_end| {
        var parent_components = std.mem.splitScalar(u8, path[0..parent_end], '/');
        while (parent_components.next()) |component| {
            const next_dir = current_dir.openDir(io, component, .{
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
                else => return err,
            };
            opened_directories.append(allocator, next_dir) catch |err| {
                next_dir.close(io);
                return err;
            };
            current_dir = next_dir;
        }
    }

    var target_components = std.mem.splitScalar(u8, target, '/');
    while (target_components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            const previous = opened_directories.pop() orelse return error.FailedPrecondition;
            previous.close(io);
            current_dir = if (opened_directories.items.len == 0)
                work_root
            else
                opened_directories.items[opened_directories.items.len - 1];
            continue;
        }

        if (target_components.peek() == null) {
            const target_stat = current_dir.statFile(io, component, .{
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
                else => return err,
            };
            if (target_stat.kind != expected_kind) return error.FailedPrecondition;
            return;
        }

        const next_dir = current_dir.openDir(io, component, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
            else => return err,
        };
        opened_directories.append(allocator, next_dir) catch |err| {
            next_dir.close(io);
            return err;
        };
        current_dir = next_dir;
    }

    if (expected_kind != .directory) return error.FailedPrecondition;
}

fn collectOutputFileWithStat(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    entry_name: []const u8,
    path: []const u8,
    stat: std.Io.Dir.Stat,
    budget: *OutputCollectionBudget,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
) !void {
    if (isDepfileOutput(path) and stat.size > max_output_depfile_bytes)
        return error.FileTooBig;
    try budget.reserveFile(stat.size);
    try budget.checkCancelled();

    const digest = putOutputFile(io, allocator, store, work_root, entry_name, path, stat) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try budget.checkCancelled();
    if (digest.size_bytes > stat.size or
        (!isDepfileOutput(path) and digest.size_bytes != stat.size))
    {
        return error.FailedPrecondition;
    }
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
    entry_name: []const u8,
    path: []const u8,
    stat: std.Io.Dir.Stat,
) !cas.Digest {
    if (!isDepfileOutput(path)) return store.putFilePromoteWithStat(io, work_root, entry_name, stat);
    if (stat.size > max_output_depfile_bytes) return error.FileTooBig;

    var file = work_root.openFile(io, entry_name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.SymLinkLoop => return error.FailedPrecondition,
        else => return err,
    };
    defer file.close(io);
    const opened_stat = try file.stat(io);
    if (opened_stat.kind != .file or
        opened_stat.inode != stat.inode or
        opened_stat.size != stat.size)
    {
        return error.FailedPrecondition;
    }
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_output_depfile_bytes + 1)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.FileTooBig,
        error.OutOfMemory => return err,
    };
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
    budget: *OutputCollectionBudget,
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    var parent = openOutputParent(io, work_root, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer parent.deinit(io);

    const stat = parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .sym_link) return;
    if (stat.kind != .directory) return error.FailedPrecondition;
    try collectOutputDirectoryWithStat(io, allocator, store, staged_index, parent.dir, parent.name, path, budget, output_directories);
}

fn collectOutputDirectoryWithStat(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    work_root: std.Io.Dir,
    entry_name: []const u8,
    path: []const u8,
    budget: *OutputCollectionBudget,
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    var dir = work_root.openDir(io, entry_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
        else => return err,
    };
    defer dir.close(io);
    try collectOpenedOutputDirectory(io, allocator, store, staged_index, dir, path, budget, output_directories);
}

fn collectOpenedOutputDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    dir: std.Io.Dir,
    path: []const u8,
    budget: *OutputCollectionBudget,
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    var tree = OutputTreeBuilder{};
    defer tree.deinit(allocator);
    const root_directory_digest = try putOutputDirectoryTree(io, allocator, store, staged_index, dir, &tree, budget);
    const tree_digest = try tree.putTreeProto(io, allocator, store, budget);
    if (staged_index) |index| try index.add(io, allocator, tree_digest);

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    try output_directories.append(allocator, .{
        .path = path_copy,
        .tree_digest = tree_digest,
        .root_directory_digest = root_directory_digest,
    });
}

const OutputParentInputDirectory = struct {
    bytes: []u8,
    directory: reapi.Directory,

    fn deinit(self: *OutputParentInputDirectory, allocator: std.mem.Allocator) void {
        self.directory.deinit(allocator);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const OutputParentValidator = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    root_digest: cas.Digest,
    cancellation: ?*const std.atomic.Value(bool) = null,
    directories: std.AutoHashMapUnmanaged(cas.Digest, OutputParentInputDirectory) = .empty,

    fn deinit(self: *OutputParentValidator) void {
        var values = self.directories.valueIterator();
        while (values.next()) |entry| entry.deinit(self.allocator);
        self.directories.deinit(self.allocator);
    }

    fn getDirectory(self: *OutputParentValidator, digest: cas.Digest) !*const reapi.Directory {
        try checkExecutionCancellation(self.cancellation);
        const entry = try self.directories.getOrPut(self.allocator, digest);
        if (entry.found_existing) return &entry.value_ptr.directory;
        errdefer _ = self.directories.remove(digest);

        const bytes = self.store.readAlloc(self.io, self.allocator, digest) catch |err| switch (err) {
            error.FileNotFound => return error.MissingInputDirectoryBlob,
            else => return err,
        };
        errdefer self.allocator.free(bytes);
        try checkExecutionCancellation(self.cancellation);
        var reader = protobuf.Reader.init(bytes);
        var directory = try reapi.Directory.decodeOwned(self.allocator, &reader);
        errdefer directory.deinit(self.allocator);
        try checkExecutionCancellation(self.cancellation);

        entry.value_ptr.* = .{
            .bytes = bytes,
            .directory = directory,
        };
        return &entry.value_ptr.directory;
    }

    fn validate(self: *OutputParentValidator, path: []const u8) !void {
        try checkExecutionCancellation(self.cancellation);
        if (path.len == 0) return;
        try validatePath(path);
        const parent_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
        if (parent_end == 0) return;

        var current_digest = self.root_digest;
        var components = std.mem.splitScalar(u8, path[0..parent_end], '/');
        while (components.next()) |component| {
            try checkExecutionCancellation(self.cancellation);
            const directory = try self.getDirectory(current_digest);
            if (findInputDirectoryEntry(reapi.FileNode, directory.files, component) != null)
                return error.OutputParentConflictsWithInputFile;
            if (findInputDirectoryEntry(reapi.SymlinkNode, directory.symlinks, component) != null)
                return error.OutputParentConflictsWithInputSymlink;

            const child = findInputDirectoryEntry(reapi.DirectoryNode, directory.directories, component) orelse return;
            current_digest = try cas.Digest.fromReapi(child.digest orelse return error.MissingInputDirectoryDigest);
        }
    }
};

fn findInputDirectoryEntry(comptime Entry: type, entries: []const Entry, name: []const u8) ?*const Entry {
    var first: usize = 0;
    var remaining = entries.len;
    while (remaining != 0) {
        const offset = remaining / 2;
        const index = first + offset;
        switch (std.mem.order(u8, entries[index].name, name)) {
            .eq => return &entries[index],
            .lt => {
                first = index + 1;
                remaining -= offset + 1;
            },
            .gt => remaining = offset,
        }
    }
    return null;
}

fn validateOutputParentsAgainstInputs(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    root_digest: cas.Digest,
    command: reapi.Command,
) !void {
    try validateOutputParentsAgainstInputsWithCancellation(io, allocator, store, root_digest, command, null);
}

fn validateOutputParentsAgainstInputsWithCancellation(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    root_digest: cas.Digest,
    command: reapi.Command,
    cancellation: ?*const std.atomic.Value(bool),
) !void {
    try checkExecutionCancellation(cancellation);
    var validator: OutputParentValidator = .{
        .io = io,
        .allocator = allocator,
        .store = store,
        .root_digest = root_digest,
        .cancellation = cancellation,
    };
    defer validator.deinit();

    if (command.output_paths.len != 0) {
        for (command.output_paths) |path| try validator.validate(path);
        return;
    }

    for (command.output_files) |path| try validator.validate(path);
    for (command.output_directories) |path| try validator.validate(path);
}

fn prepareOutputParents(
    io: std.Io,
    work_root: std.Io.Dir,
    command: reapi.Command,
) !void {
    try prepareOutputParentsWithCancellation(io, work_root, command, null);
}

fn prepareOutputParentsWithCancellation(
    io: std.Io,
    work_root: std.Io.Dir,
    command: reapi.Command,
    cancellation: ?*const std.atomic.Value(bool),
) !void {
    try checkExecutionCancellation(cancellation);
    if (command.output_paths.len != 0) {
        for (command.output_paths) |path| {
            try checkExecutionCancellation(cancellation);
            try createOutputParent(io, work_root, path);
        }
        return;
    }

    for (command.output_files) |path| {
        try checkExecutionCancellation(cancellation);
        try createOutputParent(io, work_root, path);
    }
    for (command.output_directories) |path| {
        try checkExecutionCancellation(cancellation);
        try createOutputParent(io, work_root, path);
    }
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
};

const OutputDirectoryFrame = struct {
    dir: std.Io.Dir,
    owns_dir: bool,
    parent_entry_name: ?[]const u8,
    entries: std.ArrayListUnmanaged(DirectoryEntry) = .empty,
    next_entry: usize = 0,
    files: std.ArrayListUnmanaged(reapi.FileNode) = .empty,
    directories: std.ArrayListUnmanaged(reapi.DirectoryNode) = .empty,
    symlinks: std.ArrayListUnmanaged(reapi.SymlinkNode) = .empty,

    fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        owns_dir: bool,
        parent_entry_name: ?[]const u8,
        budget: *OutputCollectionBudget,
    ) !OutputDirectoryFrame {
        var frame: OutputDirectoryFrame = .{
            .dir = dir,
            .owns_dir = owns_dir,
            .parent_entry_name = parent_entry_name,
        };
        errdefer frame.deinit(io, allocator);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            try budget.checkCancelled();
            try validateEntryName(entry.name);
            try budget.reserveEntry(entry.name.len);
            const owned_name = try allocator.dupe(u8, entry.name);
            frame.entries.append(allocator, .{ .name = owned_name }) catch |err| {
                allocator.free(owned_name);
                return err;
            };
        }

        std.mem.sort(DirectoryEntry, frame.entries.items, {}, struct {
            fn lessThan(_: void, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
        }.lessThan);
        return frame;
    }

    fn deinit(self: *OutputDirectoryFrame, io: std.Io, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.name);
        self.entries.deinit(allocator);
        self.files.deinit(allocator);
        self.directories.deinit(allocator);
        self.symlinks.deinit(allocator);
        if (self.owns_dir) self.dir.close(io);
        self.* = undefined;
    }

    fn takeDirectory(self: *OutputDirectoryFrame, allocator: std.mem.Allocator) !reapi.Directory {
        const files = try self.files.toOwnedSlice(allocator);
        errdefer allocator.free(files);
        const directories = try self.directories.toOwnedSlice(allocator);
        errdefer allocator.free(directories);
        const symlinks = try self.symlinks.toOwnedSlice(allocator);
        errdefer allocator.free(symlinks);
        return .{
            .files = files,
            .directories = directories,
            .symlinks = symlinks,
        };
    }
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
        budget: *OutputCollectionBudget,
    ) !cas.Digest {
        const root = self.root orelse return error.MissingRootDigest;
        const tree = reapi.Tree{
            .root = root,
            .children = self.children.items,
        };
        try budget.reserveTreeProto(tree.encodedLen());
        try budget.checkCancelled();
        const digest = try putProto(io, allocator, store, tree);
        try budget.checkCancelled();
        return digest;
    }
};

fn putOutputDirectoryTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    staged_index: ?*staged_cas_index.Index,
    dir: std.Io.Dir,
    tree: *OutputTreeBuilder,
    budget: *OutputCollectionBudget,
) !cas.Digest {
    var frames: std.ArrayListUnmanaged(OutputDirectoryFrame) = .empty;
    defer {
        for (frames.items) |*frame| frame.deinit(io, allocator);
        frames.deinit(allocator);
    }

    var root_frame = try OutputDirectoryFrame.init(io, allocator, dir, false, null, budget);
    frames.append(allocator, root_frame) catch |err| {
        root_frame.deinit(io, allocator);
        return err;
    };

    var root_digest: ?cas.Digest = null;
    while (frames.items.len != 0) {
        try budget.checkCancelled();
        const frame_index = frames.items.len - 1;
        if (frames.items[frame_index].next_entry == frames.items[frame_index].entries.items.len) {
            var frame = frames.pop().?;
            defer frame.deinit(io, allocator);

            var directory = try frame.takeDirectory(allocator);
            var directory_owned = true;
            errdefer if (directory_owned) directory.deinit(allocator);
            try budget.reserveDirectoryProto(directory.encodedLen());
            try budget.checkCancelled();
            const digest = try putProto(io, allocator, store, directory);
            try budget.checkCancelled();
            if (staged_index) |index| try index.add(io, allocator, digest);

            if (frame.parent_entry_name) |parent_entry_name| {
                try tree.children.append(allocator, directory);
                directory_owned = false;
                try frames.items[frames.items.len - 1].directories.append(allocator, .{
                    .name = try tree.dupe(allocator, parent_entry_name),
                    .digest = try tree.appendDigest(allocator, digest),
                });
            } else {
                tree.root = directory;
                directory_owned = false;
                root_digest = digest;
            }
            continue;
        }

        const entry_name = frames.items[frame_index].entries.items[frames.items[frame_index].next_entry].name;
        frames.items[frame_index].next_entry += 1;
        const entry_stat = frames.items[frame_index].dir.statFile(io, entry_name, .{
            .follow_symlinks = false,
        });
        const stat = entry_stat catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
            else => return err,
        };
        switch (stat.kind) {
            .file => {
                try budget.reserveFile(stat.size);
                try budget.checkCancelled();
                const digest = try store.putFilePromoteWithStat(io, frames.items[frame_index].dir, entry_name, stat);
                try budget.checkCancelled();
                if (digest.size_bytes != stat.size) return error.FailedPrecondition;
                if (staged_index) |index| try index.add(io, allocator, digest);
                try frames.items[frame_index].files.append(allocator, .{
                    .name = try tree.dupe(allocator, entry_name),
                    .digest = try tree.appendDigest(allocator, digest),
                    .is_executable = isExecutable(stat),
                });
            },
            .directory => {
                if (frames.items.len >= max_output_directory_depth)
                    return error.OutputTreeTooDeep;
                const child = frames.items[frame_index].dir.openDir(io, entry_name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch |err| switch (err) {
                    error.NotDir, error.SymLinkLoop => return error.FailedPrecondition,
                    else => return err,
                };
                var child_frame = try OutputDirectoryFrame.init(io, allocator, child, true, entry_name, budget);
                frames.append(allocator, child_frame) catch |err| {
                    child_frame.deinit(io, allocator);
                    return err;
                };
            },
            .sym_link => {
                var target_buffer: [std.os.linux.PATH_MAX]u8 = undefined;
                const target_len = try frames.items[frame_index].dir.readLink(io, entry_name, &target_buffer);
                if (target_len >= target_buffer.len) return error.InvalidSymlinkTarget;
                const symlink = reapi.SymlinkNode{
                    .name = entry_name,
                    .target = target_buffer[0..target_len],
                };
                try symlink.validate();
                try budget.reserveMetadata(symlink.target.len);
                try frames.items[frame_index].symlinks.append(allocator, .{
                    .name = try tree.dupe(allocator, symlink.name),
                    .target = try tree.dupe(allocator, symlink.target),
                });
            },
            else => return error.UnsupportedOutputDirectoryEntry,
        }
    }
    return root_digest orelse error.MissingRootDigest;
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
    try std.testing.expect(std.mem.endsWith(u8, cache.common_etc, "/runtimes/common/root/etc"));
    try std.testing.expect(cache.glibc2_35.lib != null);
    try std.testing.expect(cache.glibc2_35.usr_lib != null);
    try std.testing.expect(cache.glibc2_31.lib == null);
}

test "prepareExecuteOptions requires common runtime etc" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    try cas.Store.init(cas_dir).ensureLayout(std.testing.io);
    try tmp.dir.createDirPath(std.testing.io, "runtimes");

    var base_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buffer);
    const runtime_root_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/runtimes", .{base_buffer[0..base_len]});
    defer std.testing.allocator.free(runtime_root_path);

    try std.testing.expectError(error.MissingRuntimePath, prepareExecuteOptions(
        std.testing.io,
        std.testing.allocator,
        cas.Store.initReady(cas_dir),
        .{ .runtime_root_path = runtime_root_path },
    ));
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
        "/execroot",
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

test "OutputCollectionBudget bounds output entries, files, metadata, and protobuf messages" {
    var entries: OutputCollectionBudget = .{ .entries = max_output_entries };
    try std.testing.expectError(error.TooManyOutputEntries, entries.reserveEntry(1));

    var files: OutputCollectionBudget = .{};
    try std.testing.expectError(error.FileTooBig, files.reserveFile(max_output_file_bytes + 1));
    files.file_bytes = max_output_aggregate_file_bytes;
    try std.testing.expectError(error.OutputAggregateTooLarge, files.reserveFile(1));

    var metadata: OutputCollectionBudget = .{ .metadata_bytes = max_output_metadata_bytes };
    try std.testing.expectError(error.OutputMetadataTooLarge, metadata.reserveMetadata(1));
    try validateActionResultEncodedLen(max_output_metadata_bytes);
    try std.testing.expectError(
        error.OutputMetadataTooLarge,
        validateActionResultEncodedLen(max_output_metadata_bytes + 1),
    );

    var directory: OutputCollectionBudget = .{};
    try std.testing.expectError(
        error.OutputDirectoryTooLarge,
        directory.reserveDirectoryProto(max_output_directory_proto_bytes + 1),
    );

    var tree: OutputCollectionBudget = .{};
    try std.testing.expectError(
        error.OutputTreeTooLarge,
        tree.reserveTreeProto(max_output_tree_proto_bytes + 1),
    );

    var cancellation = std.atomic.Value(bool).init(true);
    var cancelled: OutputCollectionBudget = .{ .cancellation = &cancellation };
    try std.testing.expectError(error.ExecutionCancelled, cancelled.reserveEntry(1));

    var long_component = [_]u8{'x'} ** (std.os.linux.NAME_MAX + 1);
    var long_component_budget: OutputCollectionBudget = .{};
    try std.testing.expectError(
        error.OutputPathTooLong,
        reserveDeclaredOutput(&long_component_budget, &long_component, false),
    );

    var deep_path: [max_output_directory_depth * 2 + 1]u8 = undefined;
    for (0..max_output_directory_depth + 1) |index| {
        deep_path[index * 2] = 'x';
        if (index != max_output_directory_depth) deep_path[index * 2 + 1] = '/';
    }
    var deep_path_budget: OutputCollectionBudget = .{};
    try std.testing.expectError(
        error.OutputTreeTooDeep,
        reserveDeclaredOutput(&deep_path_budget, &deep_path, false),
    );
}

test "executeDecodedActionWithOptions rejects excessive declared outputs before creating directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const output_paths = try std.testing.allocator.alloc([]const u8, max_output_entries + 1);
    defer std.testing.allocator.free(output_paths);
    for (output_paths) |*path| path.* = "generated/never-created.txt";

    const command_bytes = try reapi.encodeAlloc(std.testing.allocator, reapi.Command{
        .output_paths = output_paths,
    });
    defer std.testing.allocator.free(command_bytes);
    const store = cas.Store.init(cas_dir);
    const command_digest = try store.putBytes(std.testing.io, command_bytes);
    var command_hash: [64]u8 = undefined;

    try std.testing.expectError(error.TooManyOutputEntries, executeDecodedActionWithOptions(
        std.testing.io,
        std.testing.allocator,
        store,
        work_dir,
        cas.Digest.fromBytes("action"),
        .{ .command_digest = command_digest.toReapi(&command_hash) },
        .{},
    ));
    try std.testing.expectError(error.FileNotFound, work_dir.statFile(std.testing.io, "execroot", .{}));
    try std.testing.expectError(error.FileNotFound, work_dir.statFile(std.testing.io, "generated", .{}));
}

test "executeDecodedActionWithOptions rejects cancellation before action preparation" {
    var cancellation = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.ExecutionCancelled, executeDecodedActionWithOptions(
        std.testing.io,
        std.testing.allocator,
        cas.Store.init(std.Io.Dir.cwd()),
        std.Io.Dir.cwd(),
        cas.Digest.fromBytes(""),
        .{},
        .{ .cancellation = &cancellation },
    ));
}

test "output parent validation and preparation stop before cancelled filesystem work" {
    var cancellation = std.atomic.Value(bool).init(true);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    try std.testing.expectError(error.ExecutionCancelled, validateOutputParentsAgainstInputsWithCancellation(
        std.testing.io,
        std.testing.allocator,
        cas.Store.init(work_dir),
        cas.Digest.fromBytes(""),
        .{ .output_paths = &.{"generated/out.txt"} },
        &cancellation,
    ));
    try std.testing.expectError(error.ExecutionCancelled, prepareOutputParentsWithCancellation(
        std.testing.io,
        work_dir,
        .{ .output_paths = &.{"generated/out.txt"} },
        &cancellation,
    ));
    try std.testing.expectError(error.FileNotFound, work_dir.statFile(std.testing.io, "generated", .{}));
}

test "collectOutputFiles stops cancelled output collection before filesystem lookups" {
    var cancellation = std.atomic.Value(bool).init(true);
    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = &.{},
        .stderr = &.{},
    };
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectError(error.ExecutionCancelled, collectOutputFilesWithCancellation(
        std.testing.io,
        std.testing.allocator,
        cas.Store.init(std.Io.Dir.cwd()),
        null,
        std.Io.Dir.cwd(),
        .{ .output_paths = &.{"missing"} },
        null,
        &cancellation,
        &outcome,
    ));
}

test "collectOutputFiles bounds missing declared output paths before filesystem lookups" {
    const output_paths = try std.testing.allocator.alloc([]const u8, max_output_entries + 1);
    defer std.testing.allocator.free(output_paths);
    for (output_paths) |*path| path.* = "missing";

    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = &.{},
        .stderr = &.{},
    };
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectError(error.TooManyOutputEntries, collectOutputFiles(
        std.testing.io,
        std.testing.allocator,
        cas.Store.init(std.Io.Dir.cwd()),
        null,
        std.Io.Dir.cwd(),
        .{ .output_paths = output_paths },
        &outcome,
    ));
}

test "collectOutputFiles rejects oversized files nested in output directory trees" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);
    try work_dir.createDirPath(std.testing.io, "tree/nested");
    {
        var oversized = try work_dir.createFile(std.testing.io, "tree/nested/oversized.bin", .{});
        defer oversized.close(std.testing.io);
        try oversized.setLength(std.testing.io, max_output_file_bytes + 1);
    }

    const commands = [_]reapi.Command{
        .{ .output_paths = &.{"tree"} },
        .{ .output_directories = &.{"tree"} },
    };
    for (commands) |command| {
        var outcome: action_runner.Outcome = .{
            .status = .{ .exited = 0 },
            .stdout = try std.testing.allocator.alloc(u8, 0),
            .stderr = try std.testing.allocator.alloc(u8, 0),
        };
        defer outcome.deinit(std.testing.allocator);
        try std.testing.expectError(error.FileTooBig, collectOutputFiles(
            std.testing.io,
            std.testing.allocator,
            cas.Store.init(cas_dir),
            null,
            work_dir,
            command,
            &outcome,
        ));
    }
}

test "collectOutputFiles rejects oversized depfiles before allocating their contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);
    {
        var oversized = try work_dir.createFile(std.testing.io, "attack.d", .{});
        defer oversized.close(std.testing.io);
        try oversized.setLength(std.testing.io, max_output_depfile_bytes + 1);
    }

    const commands = [_]reapi.Command{
        .{ .output_paths = &.{"attack.d"} },
        .{ .output_files = &.{"attack.d"} },
    };
    for (commands) |command| {
        var outcome: action_runner.Outcome = .{
            .status = .{ .exited = 0 },
            .stdout = &.{},
            .stderr = &.{},
        };
        defer outcome.deinit(std.testing.allocator);
        try std.testing.expectError(error.FileTooBig, collectOutputFiles(
            std.testing.io,
            std.testing.allocator,
            cas.Store.init(cas_dir),
            null,
            work_dir,
            command,
            &outcome,
        ));
    }
}

test "collectOutputFiles rejects output directory trees beyond the traversal depth limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    var current = try work_dir.createDirPathOpen(std.testing.io, "tree", .{});
    defer current.close(std.testing.io);
    for (0..max_output_directory_depth) |_| {
        const child = try current.createDirPathOpen(std.testing.io, "child", .{});
        current.close(std.testing.io);
        current = child;
    }

    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.testing.allocator.alloc(u8, 0),
    };
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectError(error.OutputTreeTooDeep, collectOutputFiles(
        std.testing.io,
        std.testing.allocator,
        cas.Store.init(cas_dir),
        null,
        work_dir,
        .{ .output_paths = &.{"tree"} },
        &outcome,
    ));
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

test "collectOutputFiles reports modern output symlinks without resolving their targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);
    try work_dir.createDirPath(std.testing.io, "links");
    try work_dir.writeFile(std.testing.io, .{ .sub_path = "links/actual.txt", .data = "artifact" });
    try work_dir.symLink(std.testing.io, "actual.txt", "links/file", .{});
    try work_dir.symLink(std.testing.io, "missing/target", "links/dangling", .{});
    try work_dir.symLink(std.testing.io, "/execroot/absolute", "links/absolute", .{});
    try work_dir.symLink(std.testing.io, "../outside", "links/parent", .{});

    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.testing.allocator.alloc(u8, 0),
    };
    defer outcome.deinit(std.testing.allocator);

    try collectOutputFiles(std.testing.io, std.testing.allocator, cas.Store.init(cas_dir), null, work_dir, .{
        .output_paths = &.{ "links/actual.txt", "links/file", "links/dangling", "links/absolute", "links/parent" },
    }, &outcome);

    try std.testing.expectEqual(@as(usize, 1), outcome.output_files.len);
    try std.testing.expectEqual(@as(usize, 0), outcome.output_directories.len);
    try std.testing.expectEqual(@as(usize, 4), outcome.output_symlinks.len);
    try std.testing.expectEqual(@as(usize, 0), outcome.output_file_symlinks.len);
    try std.testing.expectEqual(@as(usize, 0), outcome.output_directory_symlinks.len);
    try std.testing.expectEqualStrings("actual.txt", outcome.output_symlinks[0].target);
    try std.testing.expectEqualStrings("missing/target", outcome.output_symlinks[1].target);
    try std.testing.expectEqualStrings("/execroot/absolute", outcome.output_symlinks[2].target);
    try std.testing.expectEqualStrings("../outside", outcome.output_symlinks[3].target);

    var result = try actionResultFromOutcomeOwned(std.testing.allocator, outcome);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), result.result.output_symlinks.len);
    try std.testing.expectEqual(@as(usize, 0), result.result.output_file_symlinks.len);
    try std.testing.expectEqual(@as(usize, 0), result.result.output_directory_symlinks.len);
    try std.testing.expectEqualStrings("links/dangling", result.result.output_symlinks[1].path);
    try std.testing.expectEqualStrings("missing/target", result.result.output_symlinks[1].target);

    const encoded = try reapi.encodeAlloc(std.testing.allocator, result.result);
    defer std.testing.allocator.free(encoded);
    var reader = protobuf.Reader.init(encoded);
    var decoded = try reapi.ActionResult.decodeOwned(std.testing.allocator, &reader);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), decoded.output_symlinks.len);
    try std.testing.expectEqualStrings("/execroot/absolute", decoded.output_symlinks[2].target);
}

test "collectOutputFiles reports legacy file and directory symlinks separately" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);
    try work_dir.createDirPath(std.testing.io, "out/nested");
    try work_dir.writeFile(std.testing.io, .{ .sub_path = "out/target.txt", .data = "artifact" });
    try work_dir.createDirPath(std.testing.io, "out/target-dir");
    try work_dir.symLink(std.testing.io, "../target.txt", "out/nested/file-link", .{});
    try work_dir.symLink(std.testing.io, "target-dir", "out/directory-link", .{ .is_directory = true });

    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.testing.allocator.alloc(u8, 0),
    };
    defer outcome.deinit(std.testing.allocator);

    try collectOutputFiles(std.testing.io, std.testing.allocator, cas.Store.init(cas_dir), null, work_dir, .{
        .output_files = &.{ "out/target.txt", "out/nested/file-link" },
        .output_directories = &.{ "out/target-dir", "out/directory-link" },
    }, &outcome);

    try std.testing.expectEqual(@as(usize, 1), outcome.output_files.len);
    try std.testing.expectEqualStrings("out/target.txt", outcome.output_files[0].path);
    try std.testing.expectEqual(@as(usize, 1), outcome.output_directories.len);
    try std.testing.expectEqualStrings("out/target-dir", outcome.output_directories[0].path);
    try std.testing.expectEqual(@as(usize, 0), outcome.output_symlinks.len);
    try std.testing.expectEqual(@as(usize, 1), outcome.output_file_symlinks.len);
    try std.testing.expectEqual(@as(usize, 1), outcome.output_directory_symlinks.len);
    try std.testing.expectEqualStrings("out/nested/file-link", outcome.output_file_symlinks[0].path);
    try std.testing.expectEqualStrings("../target.txt", outcome.output_file_symlinks[0].target);
    try std.testing.expectEqualStrings("out/directory-link", outcome.output_directory_symlinks[0].path);
    try std.testing.expectEqualStrings("target-dir", outcome.output_directory_symlinks[0].target);

    var result = try actionResultFromOutcomeOwned(std.testing.allocator, outcome);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.result.output_symlinks.len);
    try std.testing.expectEqual(@as(usize, 1), result.result.output_file_symlinks.len);
    try std.testing.expectEqual(@as(usize, 1), result.result.output_directory_symlinks.len);
    try std.testing.expectEqualStrings("../target.txt", result.result.output_file_symlinks[0].target);
    try std.testing.expectEqualStrings("target-dir", result.result.output_directory_symlinks[0].target);
}

test "collectOutputFiles resolves absolute, input, and runtime legacy symlinks inside the action chroot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var chroot = try tmp.dir.createDirPathOpen(std.testing.io, "chroot", .{});
    defer chroot.close(std.testing.io);
    try chroot.createDirPath(std.testing.io, "execroot/out");
    try chroot.createDirPath(std.testing.io, "execroot/input-directory");
    try chroot.createDirPath(std.testing.io, "etc/runtime-directory");
    try chroot.writeFile(std.testing.io, .{ .sub_path = "execroot/input.txt", .data = "immutable input" });
    try chroot.writeFile(std.testing.io, .{ .sub_path = "etc/runtime.txt", .data = "runtime input" });
    try chroot.symLink(std.testing.io, "/etc/runtime.txt", "execroot/input-alias", .{});

    var workspace = try chroot.openDir(std.testing.io, "execroot", .{ .iterate = true });
    defer workspace.close(std.testing.io);
    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.createDirPath(std.testing.io, "out");
    try stage.symLink(std.testing.io, "../input.txt", "out/relative-input", .{});
    try stage.symLink(std.testing.io, "/execroot/input.txt", "out/absolute-input", .{});
    try stage.symLink(std.testing.io, "/etc/runtime.txt", "out/runtime-file", .{});
    try stage.symLink(std.testing.io, "../input-alias", "out/input-chain", .{});
    try stage.symLink(std.testing.io, "/execroot/input-directory", "out/input-directory", .{ .is_directory = true });
    try stage.symLink(std.testing.io, "/etc/runtime-directory", "out/runtime-directory", .{ .is_directory = true });

    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.testing.allocator.alloc(u8, 0),
    };
    defer outcome.deinit(std.testing.allocator);
    try collectOutputFilesWithLookup(
        std.testing.io,
        std.testing.allocator,
        cas.Store.init(cas_dir),
        null,
        stage,
        .{
            .output_files = &.{
                "out/relative-input",
                "out/absolute-input",
                "out/runtime-file",
                "out/input-chain",
            },
            .output_directories = &.{ "out/input-directory", "out/runtime-directory" },
        },
        .{ .chroot_root = chroot, .workspace_root = workspace },
        &outcome,
    );

    try std.testing.expectEqual(@as(usize, 4), outcome.output_file_symlinks.len);
    try std.testing.expectEqual(@as(usize, 2), outcome.output_directory_symlinks.len);
    try std.testing.expectEqualStrings("../input.txt", outcome.output_file_symlinks[0].target);
    try std.testing.expectEqualStrings("/execroot/input.txt", outcome.output_file_symlinks[1].target);
    try std.testing.expectEqualStrings("/etc/runtime.txt", outcome.output_file_symlinks[2].target);
    try std.testing.expectEqualStrings("../input-alias", outcome.output_file_symlinks[3].target);
    try std.testing.expectEqualStrings("/execroot/input-directory", outcome.output_directory_symlinks[0].target);
    try std.testing.expectEqualStrings("/etc/runtime-directory", outcome.output_directory_symlinks[1].target);
}

test "collectOutputFiles rejects dangling, incorrectly typed, and invalid traversals in action-visible legacy symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var chroot = try tmp.dir.createDirPathOpen(std.testing.io, "chroot", .{});
    defer chroot.close(std.testing.io);
    try chroot.createDirPath(std.testing.io, "execroot/out");
    try chroot.createDirPath(std.testing.io, "execroot/directory");
    try chroot.writeFile(std.testing.io, .{ .sub_path = "execroot/out/file.txt", .data = "input" });
    try chroot.symLink(std.testing.io, "/execroot/out/loop", "execroot/out/loop", .{});
    try chroot.symLink(std.testing.io, "/execroot/directory", "execroot/out/nested-directory", .{ .is_directory = true });

    var workspace = try chroot.openDir(std.testing.io, "execroot", .{ .iterate = true });
    defer workspace.close(std.testing.io);
    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.createDirPath(std.testing.io, "out");
    try stage.symLink(std.testing.io, "/execroot/missing", "out/dangling", .{});
    try stage.symLink(std.testing.io, "/execroot/directory", "out/directory-as-file", .{ .is_directory = true });
    try stage.symLink(std.testing.io, "/execroot/out/file.txt", "out/file-as-directory", .{});
    try stage.symLink(std.testing.io, "missing/../file.txt", "out/missing-parent", .{});
    try stage.symLink(std.testing.io, "file.txt/../file.txt", "out/file-parent", .{});
    try stage.symLink(std.testing.io, "loop", "out/loop", .{});
    try stage.symLink(std.testing.io, "nested-directory/../file.txt", "out/nested-parent", .{});

    const commands = [_]reapi.Command{
        .{ .output_files = &.{"out/dangling"} },
        .{ .output_files = &.{"out/directory-as-file"} },
        .{ .output_directories = &.{"out/file-as-directory"} },
        .{ .output_files = &.{"out/missing-parent"} },
        .{ .output_files = &.{"out/file-parent"} },
        .{ .output_files = &.{"out/loop"} },
        .{ .output_files = &.{"out/nested-parent"} },
    };
    for (commands) |command| {
        var outcome: action_runner.Outcome = .{
            .status = .{ .exited = 0 },
            .stdout = try std.testing.allocator.alloc(u8, 0),
            .stderr = try std.testing.allocator.alloc(u8, 0),
        };
        defer outcome.deinit(std.testing.allocator);
        try std.testing.expectError(error.FailedPrecondition, collectOutputFilesWithLookup(
            std.testing.io,
            std.testing.allocator,
            cas.Store.init(cas_dir),
            null,
            stage,
            command,
            .{ .chroot_root = chroot, .workspace_root = workspace },
            &outcome,
        ));
    }
}

test "collectOutputFiles rejects unsafe, dangling, and incorrectly typed legacy symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);
    try work_dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "artifact" });
    try work_dir.createDirPath(std.testing.io, "directory");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside.txt", .data = "secret" });
    try work_dir.symLink(std.testing.io, "missing", "dangling", .{});
    try work_dir.symLink(std.testing.io, "directory", "directory-as-file", .{ .is_directory = true });
    try work_dir.symLink(std.testing.io, "file.txt", "file-as-directory", .{});
    try work_dir.symLink(std.testing.io, "../outside.txt", "escaping", .{});
    try work_dir.symLink(std.testing.io, "/etc/passwd", "absolute", .{});
    try work_dir.symLink(std.testing.io, "absolute", "nested", .{});
    try work_dir.symLink(std.testing.io, "missing/../file.txt", "missing-parent", .{});
    try work_dir.symLink(std.testing.io, "file.txt/../file.txt", "file-parent", .{});
    try work_dir.symLink(std.testing.io, "/etc", "escape-directory", .{ .is_directory = true });
    try work_dir.symLink(std.testing.io, "escape-directory/../file.txt", "hidden-escape", .{});

    const invalid_commands = [_]reapi.Command{
        .{ .output_files = &.{"dangling"} },
        .{ .output_directories = &.{"dangling"} },
        .{ .output_files = &.{"directory-as-file"} },
        .{ .output_directories = &.{"file-as-directory"} },
        .{ .output_files = &.{"escaping"} },
        .{ .output_files = &.{"absolute"} },
        .{ .output_files = &.{"nested"} },
        .{ .output_files = &.{"missing-parent"} },
        .{ .output_files = &.{"file-parent"} },
        .{ .output_files = &.{"hidden-escape"} },
    };
    for (invalid_commands) |command| {
        var outcome: action_runner.Outcome = .{
            .status = .{ .exited = 0 },
            .stdout = try std.testing.allocator.alloc(u8, 0),
            .stderr = try std.testing.allocator.alloc(u8, 0),
        };
        defer outcome.deinit(std.testing.allocator);
        try std.testing.expectError(error.FailedPrecondition, collectOutputFiles(
            std.testing.io,
            std.testing.allocator,
            cas.Store.init(cas_dir),
            null,
            work_dir,
            command,
            &outcome,
        ));
    }
}

test "collectOutputFiles rejects intermediate symlink parents without modifying external files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);
    try tmp.dir.createDirPath(std.testing.io, "outside/directory");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "outside/secret.txt",
        .data = "external contents must not change",
    });
    const initial_stat = try tmp.dir.statFile(std.testing.io, "outside/secret.txt", .{});
    try work_dir.symLink(std.testing.io, "../outside", "out", .{ .is_directory = true });

    const commands = [_]reapi.Command{
        .{ .output_paths = &.{"out/secret.txt"} },
        .{ .output_files = &.{"out/secret.txt"} },
        .{ .output_directories = &.{"out/directory"} },
    };
    for (commands) |command| {
        var outcome: action_runner.Outcome = .{
            .status = .{ .exited = 0 },
            .stdout = try std.testing.allocator.alloc(u8, 0),
            .stderr = try std.testing.allocator.alloc(u8, 0),
        };
        defer outcome.deinit(std.testing.allocator);
        try std.testing.expectError(error.FailedPrecondition, collectOutputFiles(
            std.testing.io,
            std.testing.allocator,
            cas.Store.init(cas_dir),
            null,
            work_dir,
            command,
            &outcome,
        ));
    }

    const final_stat = try tmp.dir.statFile(std.testing.io, "outside/secret.txt", .{});
    try std.testing.expectEqual(initial_stat.permissions.toMode(), final_stat.permissions.toMode());
    const contents = try tmp.dir.readFileAlloc(
        std.testing.io,
        "outside/secret.txt",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("external contents must not change", contents);
}

test "collectOutputFiles serializes sorted symlinks in output directory trees" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);
    const store = cas.Store.init(cas_dir);
    try work_dir.createDirPath(std.testing.io, "tree/child");
    try work_dir.writeFile(std.testing.io, .{ .sub_path = "tree/child/file.txt", .data = "artifact" });
    try work_dir.symLink(std.testing.io, "../outside", "tree/z-link", .{});
    try work_dir.symLink(std.testing.io, "/execroot/input", "tree/a-link", .{});
    try work_dir.symLink(std.testing.io, "../missing", "tree/child/nested-link", .{});

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
    const tree_bytes = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.output_directories[0].tree_digest);
    defer std.testing.allocator.free(tree_bytes);
    var reader = protobuf.Reader.init(tree_bytes);
    var root: ?reapi.Directory = null;
    defer if (root) |*directory| directory.deinit(std.testing.allocator);
    var child: ?reapi.Directory = null;
    defer if (child) |*directory| directory.deinit(std.testing.allocator);
    while (try reader.next()) |tag| switch (tag.field_number) {
        1 => {
            var nested = try reader.readMessage();
            root = try reapi.Directory.decodeOwned(std.testing.allocator, &nested);
        },
        2 => {
            var nested = try reader.readMessage();
            child = try reapi.Directory.decodeOwned(std.testing.allocator, &nested);
        },
        else => try reader.skipField(tag.wire_type),
    };

    try std.testing.expectEqual(@as(usize, 2), root.?.symlinks.len);
    try std.testing.expectEqualStrings("a-link", root.?.symlinks[0].name);
    try std.testing.expectEqualStrings("/execroot/input", root.?.symlinks[0].target);
    try std.testing.expectEqualStrings("z-link", root.?.symlinks[1].name);
    try std.testing.expectEqualStrings("../outside", root.?.symlinks[1].target);
    try std.testing.expectEqual(@as(usize, 1), child.?.symlinks.len);
    try std.testing.expectEqualStrings("nested-link", child.?.symlinks[0].name);
    try std.testing.expectEqualStrings("../missing", child.?.symlinks[0].target);
}

test "collectOutputFiles supports the empty legacy output directory with merged inputs and staged outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    const store = cas.Store.init(cas_dir);
    var chroot = try tmp.dir.createDirPathOpen(std.testing.io, "chroot", .{});
    defer chroot.close(std.testing.io);
    try chroot.createDirPath(std.testing.io, "execroot");
    try chroot.writeFile(std.testing.io, .{ .sub_path = "execroot/input.txt", .data = "immutable input" });
    try chroot.writeFile(std.testing.io, .{ .sub_path = "execroot/output.txt", .data = "generated output" });
    var workspace = try chroot.openDir(std.testing.io, "execroot", .{ .iterate = true });
    defer workspace.close(std.testing.io);
    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.writeFile(std.testing.io, .{ .sub_path = "output.txt", .data = "generated output" });

    var outcome: action_runner.Outcome = .{
        .status = .{ .exited = 0 },
        .stdout = try std.testing.allocator.alloc(u8, 0),
        .stderr = try std.testing.allocator.alloc(u8, 0),
    };
    defer outcome.deinit(std.testing.allocator);
    try collectOutputFilesWithLookup(
        std.testing.io,
        std.testing.allocator,
        store,
        null,
        stage,
        .{
            .output_files = &.{"output.txt"},
            .output_directories = &.{""},
        },
        .{ .chroot_root = chroot, .workspace_root = workspace },
        &outcome,
    );

    try std.testing.expectEqual(@as(usize, 1), outcome.output_files.len);
    try std.testing.expectEqual(@as(usize, 1), outcome.output_directories.len);
    try std.testing.expectEqualStrings("", outcome.output_directories[0].path);

    const bytes = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.output_directories[0].root_directory_digest.?);
    defer std.testing.allocator.free(bytes);
    var reader = protobuf.Reader.init(bytes);
    var directory = try reapi.Directory.decodeOwned(std.testing.allocator, &reader);
    defer directory.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), directory.files.len);
    try std.testing.expectEqualStrings("input.txt", directory.files[0].name);
    try std.testing.expectEqualStrings("output.txt", directory.files[1].name);
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
        .data = "bazel-out/pkg/file.o: /execroot/external/tool/include/stddef.h /execroot/pkg/input.c\n",
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

test "validateOutputParentsAgainstInputs rejects an immutable root file as an output parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    const store = cas.Store.init(cas_dir);
    const file_digest = try store.putBytes(std.testing.io, "input");
    var file_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{.{ .name = "foo", .digest = file_digest.toReapi(&file_hash) }},
    });

    try std.testing.expectError(error.OutputParentConflictsWithInputFile, validateOutputParentsAgainstInputs(
        std.testing.io,
        std.testing.allocator,
        store,
        root_digest,
        .{ .output_paths = &.{"foo/bar"} },
    ));
}

test "validateOutputParentsAgainstInputs rejects a nested immutable file as a legacy output parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    const store = cas.Store.init(cas_dir);
    const file_digest = try store.putBytes(std.testing.io, "input");
    var file_hash: [64]u8 = undefined;
    const child_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{.{ .name = "generated", .digest = file_digest.toReapi(&file_hash) }},
    });
    var child_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{.{ .name = "src", .digest = child_digest.toReapi(&child_hash) }},
    });

    try std.testing.expectError(error.OutputParentConflictsWithInputFile, validateOutputParentsAgainstInputs(
        std.testing.io,
        std.testing.allocator,
        store,
        root_digest,
        .{ .output_files = &.{"src/generated/output.txt"} },
    ));
}

test "validateOutputParentsAgainstInputs rejects an immutable symlink as an output parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    const store = cas.Store.init(cas_dir);
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .symlinks = &.{.{ .name = "alias", .target = "real" }},
    });

    try std.testing.expectError(error.OutputParentConflictsWithInputSymlink, validateOutputParentsAgainstInputs(
        std.testing.io,
        std.testing.allocator,
        store,
        root_digest,
        .{ .output_directories = &.{"alias/tree"} },
    ));
}

test "validateOutputParentsAgainstInputs accepts existing input directories and missing descendants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    const store = cas.Store.init(cas_dir);
    const file_digest = try store.putBytes(std.testing.io, "input");
    var file_hash: [64]u8 = undefined;
    const child_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{.{ .name = "input.txt", .digest = file_digest.toReapi(&file_hash) }},
    });
    var child_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{.{ .name = "src", .digest = child_digest.toReapi(&child_hash) }},
    });

    try validateOutputParentsAgainstInputs(
        std.testing.io,
        std.testing.allocator,
        store,
        root_digest,
        .{ .output_paths = &.{ "src/new/a.txt", "src/other/b.txt" } },
    );
}

test "validateOutputParentsAgainstInputs ignores legacy output conflicts when output_paths is present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    const store = cas.Store.init(cas_dir);
    const file_digest = try store.putBytes(std.testing.io, "input");
    var file_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{.{ .name = "legacy", .digest = file_digest.toReapi(&file_hash) }},
    });

    try validateOutputParentsAgainstInputs(
        std.testing.io,
        std.testing.allocator,
        store,
        root_digest,
        .{
            .output_paths = &.{"new/output.txt"},
            .output_files = &.{"legacy/output.txt"},
            .output_directories = &.{"legacy/tree"},
        },
    );
}

test "needsMergedLegacyOutputLookup mounts only for actual legacy symlinks or the empty root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stage = try tmp.dir.createDirPathOpen(std.testing.io, "stage", .{});
    defer stage.close(std.testing.io);
    try stage.createDirPath(std.testing.io, "out");
    try stage.writeFile(std.testing.io, .{ .sub_path = "out/regular.txt", .data = "regular" });
    try stage.symLink(std.testing.io, "regular.txt", "out/link", .{});

    try std.testing.expect(!try needsMergedLegacyOutputLookup(std.testing.io, stage, .{
        .output_files = &.{"out/regular.txt"},
        .output_directories = &.{"out/missing-directory"},
    }));
    try std.testing.expect(!try needsMergedLegacyOutputLookup(std.testing.io, stage, .{
        .output_paths = &.{"out/regular.txt"},
        .output_files = &.{"out/link"},
        .output_directories = &.{""},
    }));
    try std.testing.expect(try needsMergedLegacyOutputLookup(std.testing.io, stage, .{
        .output_files = &.{"out/link"},
    }));
    try std.testing.expect(try needsMergedLegacyOutputLookup(std.testing.io, stage, .{
        .output_directories = &.{"out/link"},
    }));
    try std.testing.expect(try needsMergedLegacyOutputLookup(std.testing.io, stage, .{
        .output_directories = &.{""},
    }));
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
