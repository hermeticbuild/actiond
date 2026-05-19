const builtin = @import("builtin");
const std = @import("std");
const action_runner = @import("action_runner.zig");
const cas = @import("cas.zig");
const execroot = @import("execroot.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");
const staged_cas_index = @import("staged_cas_index.zig");

pub const Error = error{
    MissingActionBlob,
    MissingCommandDigest,
    MissingCommandBlob,
    MissingDirectoryBlob,
    MissingDirectoryDigest,
    MissingFileDigest,
    MissingInputBlob,
    MissingInputRootDigest,
    MissingRuntimeRoot,
    OutputParentCreateFailed,
    InvalidDirectoryEntryName,
    UnsupportedLibcRuntime,
    UnsupportedOutputDirectoryEntry,
    UnsupportedRuntimeArch,
};

const max_output_file_bytes = 1024 * 1024 * 1024;
const chroot_execroot_prefix = "/workspace/";
const worker_name = "actiond";
const supported_libc_runtimes = [_][]const u8{ "glibc2.31", "glibc2.35", "glibc2.39" };

pub const RuntimeMountSources = struct {
    lib: ?[:0]const u8 = null,
    lib64: ?[:0]const u8 = null,
    usr_lib: ?[:0]const u8 = null,
    etc: ?[:0]const u8 = null,

    fn deinit(self: *RuntimeMountSources, allocator: std.mem.Allocator) void {
        if (self.lib) |path| allocator.free(path);
        if (self.lib64) |path| allocator.free(path);
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

    fn deinit(self: *RuntimeMountCache, allocator: std.mem.Allocator) void {
        self.common.deinit(allocator);
        self.glibc2_31.deinit(allocator);
        self.glibc2_35.deinit(allocator);
        self.glibc2_39.deinit(allocator);
        self.* = .{};
    }

    fn forLibc(self: *const RuntimeMountCache, libc: []const u8) ?*const RuntimeMountSources {
        if (std.mem.eql(u8, libc, "glibc2.31")) return &self.glibc2_31;
        if (std.mem.eql(u8, libc, "glibc2.35")) return &self.glibc2_35;
        if (std.mem.eql(u8, libc, "glibc2.39")) return &self.glibc2_39;
        return null;
    }
};

pub const ExecuteOptions = struct {
    runtime_root_path: ?[]const u8 = null,
    use_actiondfs: bool = false,
    cas_blob_root_path: ?[]const u8 = null,
    input_cas_blob_root_path: ?[]const u8 = null,
    staged_cas_blob_root_path: ?[]const u8 = null,
    staged_cas_index: ?*staged_cas_index.Index = null,
    runtime_mount_cache: ?RuntimeMountCache = null,
};

pub const PreparedExecuteOptions = struct {
    options: ExecuteOptions,
    owned_cas_blob_root_path: ?[]u8 = null,
    owns_runtime_mount_cache: bool = false,

    pub fn deinit(self: *PreparedExecuteOptions, allocator: std.mem.Allocator) void {
        if (self.owns_runtime_mount_cache) {
            if (self.options.runtime_mount_cache) |*cache| cache.deinit(allocator);
        }
        if (self.owned_cas_blob_root_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

const CasReadRoots = struct {
    primary_blob_root_path: ?[]const u8 = null,
    staged_blob_root_path: ?[]const u8 = null,
    staged_index: ?*staged_cas_index.Index = null,
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
    if (prepared.options.input_cas_blob_root_path == null) {
        prepared.options.input_cas_blob_root_path = prepared.options.cas_blob_root_path;
    }
    if (prepared.options.runtime_root_path) |runtime_root_path| {
        if (prepared.options.runtime_mount_cache == null) {
            prepared.options.runtime_mount_cache = try discoverRuntimeMounts(io, allocator, runtime_root_path);
            prepared.owns_runtime_mount_cache = true;
        }
    }

    return prepared;
}

fn casReadRoots(options: ExecuteOptions) CasReadRoots {
    return .{
        .primary_blob_root_path = options.input_cas_blob_root_path orelse options.cas_blob_root_path,
        .staged_blob_root_path = options.staged_cas_blob_root_path,
        .staged_index = options.staged_cas_index,
    };
}

fn actiondfsInputBlobRootPath(options: ExecuteOptions) ?[]const u8 {
    return options.input_cas_blob_root_path orelse options.cas_blob_root_path;
}

fn readCasBlobAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    read_roots: CasReadRoots,
    digest: cas.Digest,
) ![]u8 {
    if (digest.isEmpty()) return allocator.alloc(u8, 0);

    if (read_roots.staged_blob_root_path) |root| {
        if (read_roots.staged_index == null or read_roots.staged_index.?.contains(io, digest)) {
            if (readCasBlobFromRootAlloc(io, allocator, root, digest)) |bytes| return bytes else |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            }
        }
    }
    if (read_roots.primary_blob_root_path) |root| {
        if (readCasBlobFromRootAlloc(io, allocator, root, digest)) |bytes| return bytes else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
    }
    return store.readAlloc(io, allocator, digest);
}

fn readCasBlobFromRootAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    blob_root_path: []const u8,
    digest: cas.Digest,
) ![]u8 {
    const len = std.math.cast(usize, digest.size_bytes) orelse return error.FileTooBig;
    var hash: [64]u8 = undefined;
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ blob_root_path, digest.formatHex(&hash) }, 0);
    defer allocator.free(path);

    var file = try openAbsoluteBlobPath(io, path);
    defer file.close(io);

    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try readFdRetry(file.handle, bytes[offset..]);
        if (n == 0) return error.ReadFailed;
        offset += n;
    }
    return bytes;
}

fn openAbsoluteBlobPath(io: std.Io, path: [:0]const u8) !std.Io.File {
    if (comptime builtin.os.tag == .linux) return openAbsoluteBlobPathLinuxRetry(path);
    return std.Io.Dir.openFileAbsolute(io, path, .{});
}

fn openAbsoluteBlobPathLinuxRetry(path: [:0]const u8) !std.Io.File {
    const linux = std.os.linux;
    var stale_attempts: usize = 0;
    while (true) {
        const rc = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return .{ .handle = @intCast(rc), .flags = .{ .nonblocking = false } },
            .INTR => continue,
            .STALE => {
                if (stale_attempts >= 128) return error.FileNotFound;
                stale_attempts += 1;
                sleepShortRetry();
                continue;
            },
            .NOENT, .SRCH => return error.FileNotFound,
            .ACCES => return error.AccessDenied,
            .ISDIR => return error.IsDir,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .LOOP => return error.SymLinkLoop,
            .FBIG, .OVERFLOW => return error.FileTooBig,
            else => return error.Unexpected,
        }
    }
}

fn readFdRetry(fd: std.Io.File.Handle, buffer: []u8) !usize {
    var stale_attempts: usize = 0;
    while (true) {
        const rc = std.posix.system.read(fd, buffer.ptr, buffer.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .STALE => {
                if (stale_attempts >= 128) return error.ReadFailed;
                stale_attempts += 1;
                sleepShortRetry();
                continue;
            },
            else => return error.ReadFailed,
        }
    }
}

fn sleepShortRetry() void {
    if (comptime builtin.os.tag != .linux) return;
    var request: std.os.linux.timespec = .{
        .sec = 0,
        .nsec = 2 * std.time.ns_per_ms,
    };
    while (std.posix.errno(std.os.linux.nanosleep(&request, &request)) == .INTR) {}
}

pub fn executeActionWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    action_digest: cas.Digest,
    options: ExecuteOptions,
) !action_runner.Outcome {
    const worker_start_wall = timestampNow(io);
    const input_fetch_start_wall = worker_start_wall;
    const total_start = std.Io.Clock.awake.now(io);
    const input_fetch_start = total_start;

    const read_roots = casReadRoots(options);

    const action_bytes = readCasBlobAlloc(io, allocator, store, read_roots, action_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingActionBlob,
        else => return err,
    };
    defer allocator.free(action_bytes);
    var action_reader = protobuf.Reader.init(action_bytes);
    var action = try reapi.Action.decodeOwned(allocator, &action_reader);
    defer action.deinit(allocator);

    const command_digest = try cas.Digest.fromReapi(action.command_digest orelse return error.MissingCommandDigest);
    const command_bytes = readCasBlobAlloc(io, allocator, store, read_roots, command_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCommandBlob,
        else => return err,
    };
    defer allocator.free(command_bytes);
    var command_reader = protobuf.Reader.init(command_bytes);
    var command = try reapi.Command.decodeOwned(allocator, &command_reader);
    defer command.deinit(allocator);

    const input_root_digest = try cas.Digest.fromReapi(action.input_root_digest orelse return error.MissingInputRootDigest);
    var inputs: std.ArrayListUnmanaged(execroot.Input) = .empty;
    defer inputs.deinit(allocator);
    defer freeInputs(allocator, inputs.items);
    var directory_inputs: std.ArrayListUnmanaged(execroot.DirectoryInput) = .empty;
    defer directory_inputs.deinit(allocator);
    defer freeDirectoryInputs(allocator, directory_inputs.items);
    const use_workspace_chroot = options.runtime_root_path != null;
    const use_actiondfs_inputs = use_workspace_chroot and options.use_actiondfs;
    if (!use_actiondfs_inputs) {
        const allow_directory_inputs = use_workspace_chroot;
        try collectInputs(io, allocator, store, read_roots, input_root_digest, "", command, allow_directory_inputs, &inputs, &directory_inputs);
    }
    var executable_copy_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (executable_copy_paths.items) |path| allocator.free(path);
        executable_copy_paths.deinit(allocator);
    }
    if (!use_actiondfs_inputs) {
        try selectExecutableInputCopyPaths(
            allocator,
            command,
            inputs.items,
            if (use_workspace_chroot) "/workspace" else "",
            &executable_copy_paths,
        );
    }

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try work_root.realPath(io, &cwd_buffer);
    const work_root_path = cwd_buffer[0..cwd_len];

    const libc_runtime = try libcRuntimeFromPlatform(action.platform);
    var exec_root_dir = work_root;
    var workspace_dir: ?std.Io.Dir = null;
    defer if (workspace_dir) |*dir| dir.close(io);
    var actiondfs_upper_dir: ?std.Io.Dir = null;
    defer if (actiondfs_upper_dir) |*dir| dir.close(io);
    var actiondfs_exec_path_override: ?[]u8 = null;
    defer if (actiondfs_exec_path_override) |path| allocator.free(path);

    var exec_root_path_owned: ?[]u8 = null;
    defer if (exec_root_path_owned) |path| allocator.free(path);
    const exec_root_path = if (use_workspace_chroot) path: {
        try work_root.createDirPath(io, "workspace");
        const value = try std.fmt.allocPrint(allocator, "{s}/workspace", .{work_root_path});
        exec_root_path_owned = value;
        if (!use_actiondfs_inputs) {
            workspace_dir = try work_root.openDir(io, "workspace", .{});
            exec_root_dir = workspace_dir.?;
        }
        break :path value;
    } else work_root_path;
    try prepareChrootBaseDirs(io, work_root);

    var actiondfs_workspace: ?ActiondfsWorkspace = null;
    defer if (actiondfs_workspace) |*workspace| workspace.deinit(io, allocator);
    var owned_cas_blob_root_path: ?[]u8 = null;
    defer if (owned_cas_blob_root_path) |path| allocator.free(path);
    if (use_actiondfs_inputs) {
        const cas_blob_root_path = actiondfsInputBlobRootPath(options) orelse path: {
            var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const cas_root_len = try store.root.realPath(io, &cas_root_buffer);
            const value = try std.fmt.allocPrint(allocator, "{s}/blobs/sha256", .{cas_root_buffer[0..cas_root_len]});
            owned_cas_blob_root_path = value;
            break :path value;
        };
        actiondfs_workspace = try ActiondfsWorkspace.init(
            io,
            allocator,
            cas_blob_root_path,
            work_root_path,
            exec_root_path,
            input_root_digest,
        );
        actiondfs_upper_dir = try std.Io.Dir.openDirAbsolute(io, actiondfs_workspace.?.mounts[0].upperdir, .{});
        exec_root_dir = actiondfs_upper_dir.?;
        actiondfs_exec_path_override = resolveActiondfsExecutablePath(
            io,
            allocator,
            store,
            read_roots,
            input_root_digest,
            action_digest,
            command,
            if (use_workspace_chroot) "/workspace" else "",
        ) catch |err| {
            logExecuteSetupError("resolve actiondfs executable", action_digest, err);
            return err;
        };
    }

    const materializer = execroot.Materializer.init(store, exec_root_dir);
    var materialization: execroot.Materialization = .{};
    if (!use_actiondfs_inputs) {
        materialization = materializer.materializeInputs(io, allocator, inputs.items, .{
            .chroot_root_path = exec_root_path,
            .cas_blob_root_path = options.input_cas_blob_root_path orelse options.cas_blob_root_path,
            .staged_cas_blob_root_path = options.staged_cas_blob_root_path,
            .staged_cas_index = options.staged_cas_index,
            .directory_inputs = directory_inputs.items,
            .copy_executable_inputs = executable_copy_paths.items,
        }) catch |err| switch (err) {
            error.FileNotFound, error.MissingInputTree => return error.MissingInputBlob,
            else => {
                logExecuteSetupError("materialize inputs", action_digest, err);
                return err;
            },
        };
    }
    defer materialization.deinit(allocator);
    prepareOutputParents(io, exec_root_dir, command) catch |err| switch (err) {
        error.FileNotFound => return error.OutputParentCreateFailed,
        else => {
            logExecuteSetupError("prepare output parents", action_digest, err);
            return err;
        },
    };

    const chroot_cwd_prefix = if (use_workspace_chroot) "/workspace" else "";
    var chroot_cwd_owned: ?[]u8 = null;
    defer if (chroot_cwd_owned) |path| allocator.free(path);
    const chroot_cwd = if (command.working_directory.len == 0) cwd: {
        break :cwd if (use_workspace_chroot) "/workspace" else "/";
    } else cwd: {
        try execroot.validatePath(command.working_directory);
        const value = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ chroot_cwd_prefix, command.working_directory });
        chroot_cwd_owned = value;
        break :cwd value;
    };

    var bind_mounts: std.ArrayListUnmanaged(action_runner.BindMount) = .empty;
    const borrowed_bind_mount_count = materialization.bind_mounts.len;
    var runtime_mount_sources_are_borrowed = false;
    defer {
        for (bind_mounts.items[borrowed_bind_mount_count..]) |mount| {
            if (!runtime_mount_sources_are_borrowed) allocator.free(mount.source);
            allocator.free(mount.target);
        }
        bind_mounts.deinit(allocator);
    }
    try bind_mounts.appendSlice(allocator, materialization.bind_mounts);
    if (options.runtime_mount_cache) |cache| {
        runtime_mount_sources_are_borrowed = true;
        if (libc_runtime) |libc| {
            const sources = cache.forLibc(libc) orelse return error.UnsupportedLibcRuntime;
            try appendCachedLibcRuntimeMounts(io, allocator, work_root, work_root_path, sources, &bind_mounts);
        } else {
            try appendCachedCommonRuntimeMounts(io, allocator, work_root, work_root_path, &cache.common, &bind_mounts);
        }
    } else {
        if (options.runtime_root_path) |runtime_root| {
            if (libc_runtime == null) {
                try appendCommonRuntimeMounts(io, allocator, work_root, work_root_path, runtime_root, &bind_mounts);
            }
        }
        if (libc_runtime) |libc| {
            const runtime_root = options.runtime_root_path orelse return error.MissingRuntimeRoot;
            try appendLibcRuntimeMounts(io, allocator, work_root, work_root_path, runtime_root, libc, &bind_mounts);
        }
    }

    const input_fetch_completed_wall = timestampNow(io);
    const input_fetch_completed = std.Io.Clock.awake.now(io);
    const execution_start_wall = timestampNow(io);
    const execution_start = std.Io.Clock.awake.now(io);
    var outcome = try action_runner.runCommandWithOptions(io, allocator, store, command, .{
        .chroot_dir = work_root_path,
        .chroot_cwd = chroot_cwd,
        .exec_path_override = actiondfs_exec_path_override,
        .bind_mounts = bind_mounts.items,
        .actiondfs_mounts = if (actiondfs_workspace) |*workspace| workspace.mounts[0..] else &.{},
        .cgroup_limits = action_runner.CgroupLimits.fromPlatform(action.platform),
    });
    errdefer outcome.deinit(allocator);
    const execution_completed_wall = timestampNow(io);
    const execution_completed = std.Io.Clock.awake.now(io);
    const output_upload_start_wall = timestampNow(io);
    const output_upload_start = std.Io.Clock.awake.now(io);
    if (options.staged_cas_index) |index| {
        if (outcome.stdout_digest) |digest| try index.add(io, allocator, digest);
        if (outcome.stderr_digest) |digest| try index.add(io, allocator, digest);
    }
    if (actiondfs_workspace) |*workspace| {
        try workspace.mountForCollection();
        var merged_dir = try std.Io.Dir.openDirAbsolute(io, workspace.mounts[0].overlay_target, .{ .iterate = true });
        defer merged_dir.close(io);
        try collectOutputFiles(io, allocator, store, options.staged_cas_index, merged_dir, command, &outcome);
    } else {
        try collectOutputFiles(io, allocator, store, options.staged_cas_index, exec_root_dir, command, &outcome);
    }
    const output_upload_completed_wall = timestampNow(io);
    const output_upload_completed = std.Io.Clock.awake.now(io);

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
    logActionTiming(
        action_digest,
        total_start,
        input_fetch_start,
        input_fetch_completed,
        execution_start,
        execution_completed,
        output_upload_start,
        output_upload_completed,
        inputs.items.len,
        directory_inputs.items.len,
        bind_mounts.items.len,
        if (actiondfs_workspace != null) @as(usize, 1) else 0,
        outcome.output_files.len,
        outcome.output_directories.len,
        stressCaseFromCommand(command),
    );
    if (outcome.runner_timing) |timing| {
        logRunnerTiming(action_digest, timing);
    }
    return outcome;
}

pub fn actionResultFromOutcome(
    outcome: action_runner.Outcome,
    stdout_hash: *[64]u8,
    stderr_hash: *[64]u8,
) reapi.ActionResult {
    return .{
        .exit_code = switch (outcome.status) {
            .exited => |code| code,
            .signaled => |signal| 128 + @as(i32, signal),
            .stopped, .unknown => 1,
        },
        .stdout_digest = if (outcome.stdout_digest) |digest| digest.toReapi(stdout_hash) else null,
        .stderr_digest = if (outcome.stderr_digest) |digest| digest.toReapi(stderr_hash) else null,
        .execution_metadata = outcome.execution_metadata,
    };
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

fn stressCaseFromCommand(command: reapi.Command) []const u8 {
    for (command.environment_variables) |variable| {
        if (std.mem.eql(u8, variable.name, "ACTIOND_STRESS_CASE") and variable.value.len != 0) return variable.value;
    }
    return "unknown";
}

fn selectExecutableInputCopyPaths(
    allocator: std.mem.Allocator,
    command: reapi.Command,
    inputs: []const execroot.Input,
    workspace_prefix: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (candidates.items) |path| allocator.free(path);
        candidates.deinit(allocator);
    }
    try selectExecutableInputCandidatePaths(allocator, command, workspace_prefix, &candidates);

    for (candidates.items) |candidate| {
        _ = try appendExecutableInputPath(allocator, inputs, candidate, out);
    }
}

fn selectExecutableInputCandidatePaths(
    allocator: std.mem.Allocator,
    command: reapi.Command,
    workspace_prefix: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    if (command.arguments.len == 0) return;
    const argv0 = command.arguments[0];
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        if (try execArgToInputPath(allocator, command.working_directory, argv0, workspace_prefix)) |candidate| {
            try out.append(allocator, candidate);
        }
        return;
    }

    const path_value = commandPath(command) orelse "/usr/local/bin:/usr/bin:/bin";
    var parts = std.mem.splitScalar(u8, path_value, ':');
    while (parts.next()) |part| {
        const prefix = if (part.len == 0) "/" else part;
        const exec_candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, argv0 });
        defer allocator.free(exec_candidate);
        if (try execArgToInputPath(allocator, command.working_directory, exec_candidate, workspace_prefix)) |candidate| {
            try out.append(allocator, candidate);
        }
    }
}

const LookupInputFile = struct {
    digest: cas.Digest,
    is_executable: bool,
};

fn resolveActiondfsExecutablePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    read_roots: CasReadRoots,
    input_root_digest: cas.Digest,
    action_digest: cas.Digest,
    command: reapi.Command,
    workspace_prefix: []const u8,
) !?[]u8 {
    var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (candidates.items) |path| allocator.free(path);
        candidates.deinit(allocator);
    }
    try selectExecutableInputCandidatePaths(allocator, command, workspace_prefix, &candidates);

    for (candidates.items) |candidate| {
        const input = lookupInputFile(io, allocator, store, read_roots, input_root_digest, candidate) catch |err| {
            logExecuteSetupError("lookup actiondfs executable", action_digest, err);
            return err;
        } orelse continue;
        if (!input.is_executable) return null;
        return try execPathForWorkspaceInput(allocator, candidate, workspace_prefix);
    }
    return null;
}

fn lookupInputFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    read_roots: CasReadRoots,
    root_digest: cas.Digest,
    path: []const u8,
) !?LookupInputFile {
    try execroot.validatePath(path);
    var components = std.mem.splitScalar(u8, path, '/');
    return lookupInputFileComponent(io, allocator, store, read_roots, root_digest, &components);
}

fn lookupInputFileComponent(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    read_roots: CasReadRoots,
    directory_digest: cas.Digest,
    components: *std.mem.SplitIterator(u8, .scalar),
) !?LookupInputFile {
    const component = components.next() orelse return null;
    if (component.len == 0) return null;
    try validateEntryName(component);

    const directory_bytes = readCasBlobAlloc(io, allocator, store, read_roots, directory_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingDirectoryBlob,
        else => return err,
    };
    defer allocator.free(directory_bytes);

    var reader = protobuf.Reader.init(directory_bytes);
    var directory = try reapi.Directory.decodeOwned(allocator, &reader);
    defer directory.deinit(allocator);

    if (components.peek() == null) {
        for (directory.files) |file| {
            try validateEntryName(file.name);
            if (!std.mem.eql(u8, file.name, component)) continue;
            return .{
                .digest = try cas.Digest.fromReapi(file.digest orelse return error.MissingFileDigest),
                .is_executable = file.is_executable,
            };
        }
        return null;
    }

    for (directory.directories) |child| {
        try validateEntryName(child.name);
        if (!std.mem.eql(u8, child.name, component)) continue;
        const digest = try cas.Digest.fromReapi(child.digest orelse return error.MissingDirectoryDigest);
        return lookupInputFileComponent(io, allocator, store, read_roots, digest, components);
    }
    return null;
}

fn execPathForWorkspaceInput(
    allocator: std.mem.Allocator,
    path: []const u8,
    workspace_prefix: []const u8,
) ![]u8 {
    if (workspace_prefix.len != 0) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace_prefix, path });
    return std.fmt.allocPrint(allocator, "/{s}", .{path});
}

fn execArgToInputPath(
    allocator: std.mem.Allocator,
    working_directory: []const u8,
    exec_arg: []const u8,
    workspace_prefix: []const u8,
) !?[]u8 {
    if (exec_arg.len == 0) return null;
    if (std.mem.indexOfScalar(u8, exec_arg, 0) != null) return null;

    if (std.fs.path.isAbsolute(exec_arg)) {
        if (workspace_prefix.len != 0) {
            if (!std.mem.startsWith(u8, exec_arg, workspace_prefix)) return null;
            if (exec_arg.len == workspace_prefix.len or exec_arg[workspace_prefix.len] != '/') return null;
            return normalizeRelativeInputPath(allocator, exec_arg[workspace_prefix.len + 1 ..]);
        }
        return normalizeRelativeInputPath(allocator, exec_arg[1..]);
    }

    if (working_directory.len == 0) return normalizeRelativeInputPath(allocator, exec_arg);
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ working_directory, exec_arg });
    defer allocator.free(joined);
    return normalizeRelativeInputPath(allocator, joined);
}

fn normalizeRelativeInputPath(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len == 0) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            out.deinit(allocator);
            return null;
        }
        if (std.mem.indexOfScalar(u8, component, 0) != null) {
            out.deinit(allocator);
            return null;
        }
        if (out.items.len != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, component);
    }

    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn appendExecutableInputPath(
    allocator: std.mem.Allocator,
    inputs: []const execroot.Input,
    candidate: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !bool {
    for (inputs) |input| {
        if (!std.mem.eql(u8, input.path, candidate)) continue;
        if (!input.is_executable) return true;
        if (pathInCopyList(candidate, out.items)) return true;
        try out.append(allocator, try allocator.dupe(u8, candidate));
        return true;
    }
    return false;
}

fn pathInCopyList(path: []const u8, paths: []const []const u8) bool {
    for (paths) |candidate| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn commandPath(command: reapi.Command) ?[]const u8 {
    for (command.environment_variables) |variable| {
        if (std.mem.eql(u8, variable.name, "PATH")) return variable.value;
    }
    return null;
}

const ActiondfsWorkspace = struct {
    base_path: []u8,
    lower_target: [:0]u8,
    overlay_target: [:0]u8,
    upperdir: [:0]u8,
    actiondfs_data: [:0]u8,
    overlay_data: [:0]u8,
    mounts: [1]action_runner.ActiondfsOverlayMount,
    collection_mounted: bool = false,

    fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        cas_blob_root: []const u8,
        work_root_path: []const u8,
        workspace_path: []const u8,
        input_root_digest: cas.Digest,
    ) !ActiondfsWorkspace {
        const base_path = try std.fmt.allocPrint(allocator, "{s}.actiondfs", .{work_root_path});
        errdefer allocator.free(base_path);
        try std.Io.Dir.cwd().createDir(io, base_path, .default_dir);

        const lower_path = try std.fmt.allocPrintSentinel(allocator, "{s}/lower", .{base_path}, 0);
        errdefer allocator.free(lower_path);
        const upper_path = try std.fmt.allocPrintSentinel(allocator, "{s}/upper", .{base_path}, 0);
        errdefer allocator.free(upper_path);
        const work_path = try std.fmt.allocPrint(allocator, "{s}/work", .{base_path});
        defer allocator.free(work_path);

        var base_dir = try std.Io.Dir.openDirAbsolute(io, base_path, .{});
        defer base_dir.close(io);
        try base_dir.createDir(io, "lower", .default_dir);
        try base_dir.createDir(io, "upper", .default_dir);
        try base_dir.createDir(io, "work", .default_dir);

        var root_hash: [64]u8 = undefined;

        const actiondfs_data = try std.fmt.allocPrintSentinel(
            allocator,
            "root={s},cas={s}",
            .{ input_root_digest.formatHex(&root_hash), cas_blob_root },
            0,
        );
        errdefer allocator.free(actiondfs_data);
        const overlay_data = try std.fmt.allocPrintSentinel(
            allocator,
            "lowerdir={s},upperdir={s},workdir={s}",
            .{ lower_path, upper_path, work_path },
            0,
        );
        errdefer allocator.free(overlay_data);
        const overlay_target = try allocator.dupeZ(u8, workspace_path);
        errdefer allocator.free(overlay_target);

        return .{
            .base_path = base_path,
            .lower_target = lower_path,
            .overlay_target = overlay_target,
            .upperdir = upper_path,
            .actiondfs_data = actiondfs_data,
            .overlay_data = overlay_data,
            .mounts = .{.{
                .fstype = "actiondfs",
                .lower_target = lower_path,
                .overlay_target = overlay_target,
                .upperdir = upper_path,
                .actiondfs_data = actiondfs_data,
                .overlay_data = overlay_data,
            }},
        };
    }

    fn mountForCollection(self: *ActiondfsWorkspace) !void {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;
        if (self.collection_mounted) return;

        const linux = std.os.linux;
        const actiondfs_rc = linux.mount(
            "actiondfs",
            self.lower_target.ptr,
            "actiondfs",
            linux.MS.RDONLY | linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOATIME,
            @intFromPtr(self.actiondfs_data.ptr),
        );
        switch (std.posix.errno(actiondfs_rc)) {
            .SUCCESS => {},
            else => return error.MountFailed,
        }
        errdefer _ = linux.umount2(self.lower_target.ptr, linux.MNT.DETACH);

        const overlay_rc = linux.mount(
            "overlay",
            self.overlay_target.ptr,
            "overlay",
            linux.MS.NOSUID | linux.MS.NODEV,
            @intFromPtr(self.overlay_data.ptr),
        );
        switch (std.posix.errno(overlay_rc)) {
            .SUCCESS => {},
            else => return error.MountFailed,
        }
        self.collection_mounted = true;
    }

    fn deinit(self: *ActiondfsWorkspace, io: std.Io, allocator: std.mem.Allocator) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.collection_mounted) {
                _ = std.os.linux.umount2(self.overlay_target.ptr, std.os.linux.MNT.DETACH);
                _ = std.os.linux.umount2(self.lower_target.ptr, std.os.linux.MNT.DETACH);
            }
        }
        std.Io.Dir.cwd().deleteTree(io, self.base_path) catch |err| {
            std.log.warn("failed to remove actiondfs workspace {s}: {s}", .{ self.base_path, @errorName(err) });
        };
        allocator.free(self.base_path);
        allocator.free(self.lower_target);
        allocator.free(self.overlay_target);
        allocator.free(self.upperdir);
        allocator.free(self.actiondfs_data);
        allocator.free(self.overlay_data);
        self.* = undefined;
    }
};

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

fn appendCommonRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    runtime_root_path: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    const runtime_root = try std.fmt.allocPrint(allocator, "{s}/common/root", .{runtime_root_path});
    defer allocator.free(runtime_root);
    _ = try appendRuntimeMountIfExists(io, allocator, chroot_dir, chroot_path, runtime_root, "etc", "etc", bind_mounts);
}

fn appendLibcRuntimeMounts(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    runtime_root_path: []const u8,
    libc: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    const arch = try runtimeArch();
    const runtime_root = try std.fmt.allocPrint(allocator, "{s}/libc/{s}/{s}/root", .{ runtime_root_path, libc, arch });
    defer allocator.free(runtime_root);

    try appendFirstExistingRuntimeMount(io, allocator, chroot_dir, chroot_path, runtime_root, &.{ "lib", "usr/lib" }, "lib", bind_mounts);
    try appendFirstExistingRuntimeMount(io, allocator, chroot_dir, chroot_path, runtime_root, &.{ "lib64", "usr/lib64" }, "lib64", bind_mounts);
    _ = try appendRuntimeMountIfExists(io, allocator, chroot_dir, chroot_path, runtime_root, "usr/lib", "usr/lib", bind_mounts);
    _ = try appendRuntimeMountIfExists(io, allocator, chroot_dir, chroot_path, runtime_root, "etc", "etc", bind_mounts);
}

fn appendFirstExistingRuntimeMount(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    runtime_root: []const u8,
    source_candidates: []const []const u8,
    target_rel: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !void {
    for (source_candidates) |source_rel| {
        if (try appendRuntimeMountIfExists(io, allocator, chroot_dir, chroot_path, runtime_root, source_rel, target_rel, bind_mounts)) return;
    }
}

fn appendRuntimeMountIfExists(
    io: std.Io,
    allocator: std.mem.Allocator,
    chroot_dir: std.Io.Dir,
    chroot_path: []const u8,
    runtime_root: []const u8,
    source_rel: []const u8,
    target_rel: []const u8,
    bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
) !bool {
    const source = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ runtime_root, source_rel }, 0);
    errdefer allocator.free(source);
    std.Io.Dir.cwd().access(io, source, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(source);
            return false;
        },
        else => |e| return e,
    };

    try chroot_dir.createDirPath(io, target_rel);
    const target = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ chroot_path, target_rel }, 0);
    errdefer allocator.free(target);
    try bind_mounts.append(allocator, .{
        .source = source,
        .target = target,
    });
    return true;
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
    file_inputs: usize,
    directory_inputs: usize,
    bind_mounts: usize,
    actiondfs_mounts: usize,
    output_files: usize,
    output_directories: usize,
    stress_case: []const u8,
) void {
    var hash: [64]u8 = undefined;
    std.log.info(
        "execute timing {s}/{d}: total_ns={d} input_fetch_ns={d} execution_ns={d} output_upload_ns={d} file_inputs={d} directory_inputs={d} bind_mounts={d} actiondfs_mounts={d} output_files={d} output_directories={d} stress_case={s}",
        .{
            action_digest.formatHex(&hash),
            action_digest.size_bytes,
            elapsedNs(total_start, output_upload_completed),
            elapsedNs(input_fetch_start, input_fetch_completed),
            elapsedNs(execution_start, execution_completed),
            elapsedNs(output_upload_start, output_upload_completed),
            file_inputs,
            directory_inputs,
            bind_mounts,
            actiondfs_mounts,
            output_files,
            output_directories,
            stress_case,
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
    try execroot.validatePath(path);
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
    try execroot.validatePath(path);
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

    const digest = putOutputFile(io, allocator, store, work_root, path) catch |err| switch (err) {
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
) !cas.Digest {
    if (!isDepfileOutput(path)) return store.putFile(io, work_root, path);

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
    try execroot.validatePath(path);
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
    _ = try putOutputDirectoryTree(io, allocator, store, staged_index, dir, &tree, true);
    const tree_digest = try tree.putTreeProto(io, allocator, store);
    if (staged_index) |index| try index.add(io, allocator, tree_digest);

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    try output_directories.append(allocator, .{
        .path = path_copy,
        .tree_digest = tree_digest,
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
    try execroot.validatePath(path);
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (last_slash == 0) return;
    try work_root.createDirPath(io, path[0..last_slash]);
}

fn prepareChrootBaseDirs(io: std.Io, chroot_root: std.Io.Dir) !void {
    try chroot_root.createDirPath(io, "tmp");
    try chroot_root.createDirPath(io, "var/tmp");
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
                const digest = try store.putFile(io, dir, entry.name);
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

fn collectInputs(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    read_roots: CasReadRoots,
    directory_digest: cas.Digest,
    prefix: []const u8,
    command: reapi.Command,
    allow_directory_inputs: bool,
    inputs: ?*std.ArrayListUnmanaged(execroot.Input),
    directory_inputs: ?*std.ArrayListUnmanaged(execroot.DirectoryInput),
) !void {
    const directory_bytes = readCasBlobAlloc(io, allocator, store, read_roots, directory_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingDirectoryBlob,
        else => return err,
    };
    defer allocator.free(directory_bytes);

    var reader = protobuf.Reader.init(directory_bytes);
    var directory = try reapi.Directory.decodeOwned(allocator, &reader);
    defer directory.deinit(allocator);

    for (directory.files) |file| {
        try validateEntryName(file.name);
        if (inputs) |list| {
            const path = try joinPath(allocator, prefix, file.name);
            errdefer allocator.free(path);
            const digest = try cas.Digest.fromReapi(file.digest orelse return error.MissingFileDigest);
            try list.append(allocator, .{
                .path = path,
                .digest = digest,
                .is_executable = file.is_executable,
            });
        }
    }

    for (directory.directories) |child| {
        try validateEntryName(child.name);
        const digest = try cas.Digest.fromReapi(child.digest orelse return error.MissingDirectoryDigest);
        const child_prefix = try joinPath(allocator, prefix, child.name);
        errdefer allocator.free(child_prefix);
        if (allow_directory_inputs and canBindDirectoryInput(child_prefix, command)) {
            try store.materializeTree(io, allocator, digest);
            if (directory_inputs) |list| {
                try list.append(allocator, .{
                    .path = child_prefix,
                    .digest = digest,
                });
            } else {
                allocator.free(child_prefix);
            }
        } else {
            try collectInputs(io, allocator, store, read_roots, digest, child_prefix, command, allow_directory_inputs, inputs, directory_inputs);
            allocator.free(child_prefix);
        }
    }
}

fn canBindDirectoryInput(path: []const u8, command: reapi.Command) bool {
    if (command.output_paths.len != 0) {
        return !overlapsAnyOutput(path, command.output_paths);
    }
    return !overlapsAnyOutput(path, command.output_files) and
        !overlapsAnyOutput(path, command.output_directories);
}

fn overlapsAnyOutput(path: []const u8, output_paths: []const []const u8) bool {
    for (output_paths) |output_path| {
        if (pathsOverlap(path, output_path)) return true;
    }
    return false;
}

fn pathsOverlap(lhs: []const u8, rhs: []const u8) bool {
    return pathContains(lhs, rhs) or pathContains(rhs, lhs);
}

fn pathContains(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    return child.len > parent.len and
        std.mem.startsWith(u8, child, parent) and
        child[parent.len] == '/';
}

fn validateEntryName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidDirectoryEntryName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidDirectoryEntryName;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidDirectoryEntryName;
    if (std.mem.eql(u8, name, ".")) return error.InvalidDirectoryEntryName;
    if (std.mem.eql(u8, name, "..")) return error.InvalidDirectoryEntryName;
}

fn joinPath(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn freeInputs(allocator: std.mem.Allocator, inputs: []const execroot.Input) void {
    for (inputs) |input| allocator.free(input.path);
}

fn freeDirectoryInputs(allocator: std.mem.Allocator, inputs: []const execroot.DirectoryInput) void {
    for (inputs) |input| allocator.free(input.path);
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

test "selectExecutableInputCopyPaths keeps only the direct command executable" {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| std.testing.allocator.free(path);
        paths.deinit(std.testing.allocator);
    }

    try selectExecutableInputCopyPaths(
        std.testing.allocator,
        .{ .arguments = &.{"tool/action-tool"} },
        &.{
            .{ .path = "tool/action-tool", .digest = cas.Digest.empty(), .is_executable = true },
            .{ .path = "inputs/data.txt", .digest = cas.Digest.empty(), .is_executable = true },
        },
        "/workspace",
        &paths,
    );

    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqualStrings("tool/action-tool", paths.items[0]);
}

test "selectExecutableInputCopyPaths trusts executable metadata" {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| std.testing.allocator.free(path);
        paths.deinit(std.testing.allocator);
    }

    try selectExecutableInputCopyPaths(
        std.testing.allocator,
        .{ .arguments = &.{"tool/action-tool"} },
        &.{.{ .path = "tool/action-tool", .digest = cas.Digest.empty(), .is_executable = false }},
        "/workspace",
        &paths,
    );

    try std.testing.expectEqual(@as(usize, 0), paths.items.len);
}

test "selectExecutableInputCopyPaths maps workspace absolute command paths" {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| std.testing.allocator.free(path);
        paths.deinit(std.testing.allocator);
    }

    _ = try selectExecutableInputCopyPaths(
        std.testing.allocator,
        .{ .arguments = &.{"/workspace/tool/action-tool"} },
        &.{.{ .path = "tool/action-tool", .digest = cas.Digest.empty(), .is_executable = true }},
        "/workspace",
        &paths,
    );

    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqualStrings("tool/action-tool", paths.items[0]);
}

test "selectExecutableInputCopyPaths normalizes relative working directory commands" {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| std.testing.allocator.free(path);
        paths.deinit(std.testing.allocator);
    }

    _ = try selectExecutableInputCopyPaths(
        std.testing.allocator,
        .{
            .arguments = &.{"./action-tool"},
            .working_directory = "tool",
        },
        &.{.{ .path = "tool/action-tool", .digest = cas.Digest.empty(), .is_executable = true }},
        "/workspace",
        &paths,
    );

    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqualStrings("tool/action-tool", paths.items[0]);
}

test "selectExecutableInputCopyPaths searches input PATH candidates" {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| std.testing.allocator.free(path);
        paths.deinit(std.testing.allocator);
    }

    _ = try selectExecutableInputCopyPaths(
        std.testing.allocator,
        .{
            .arguments = &.{"action-tool"},
            .environment_variables = &.{.{ .name = "PATH", .value = "/usr/bin:/workspace/tool" }},
        },
        &.{.{ .path = "tool/action-tool", .digest = cas.Digest.empty(), .is_executable = true }},
        "/workspace",
        &paths,
    );

    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqualStrings("tool/action-tool", paths.items[0]);
}

test "resolveActiondfsExecutablePath resolves executable input from input root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "cas", .default_dir);

    var cas_dir = try tmp.dir.openDir(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    const store = cas.Store.initReady(cas_dir);
    try store.ensureLayout(std.testing.io);

    const tool_digest = try store.putBytes(std.testing.io, "tool bytes");
    var tool_hash: [64]u8 = undefined;
    const bin_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{.{
            .name = "llvm-ar",
            .digest = tool_digest.toReapi(&tool_hash),
            .is_executable = true,
        }},
    });
    var bin_hash: [64]u8 = undefined;
    const toolchain_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{.{
            .name = "bin",
            .digest = bin_digest.toReapi(&bin_hash),
        }},
    });
    var toolchain_hash: [64]u8 = undefined;
    const external_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{.{
            .name = "llvm-toolchain",
            .digest = toolchain_digest.toReapi(&toolchain_hash),
        }},
    });
    var external_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{.{
            .name = "external",
            .digest = external_digest.toReapi(&external_hash),
        }},
    });

    const exec_path = try resolveActiondfsExecutablePath(
        std.testing.io,
        std.testing.allocator,
        store,
        .{},
        root_digest,
        root_digest,
        .{ .arguments = &.{"external/llvm-toolchain/bin/llvm-ar"} },
        "/workspace",
    );
    defer if (exec_path) |path| std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/workspace/external/llvm-toolchain/bin/llvm-ar", exec_path.?);
}

test "appendLibcRuntimeMounts maps runtime directories into chroot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const arch = try runtimeArch();
    const runtime_usr_lib = try std.fmt.allocPrint(std.testing.allocator, "runtimes/libc/glibc2.35/{s}/root/usr/lib", .{arch});
    defer std.testing.allocator.free(runtime_usr_lib);
    const runtime_etc = try std.fmt.allocPrint(std.testing.allocator, "runtimes/libc/glibc2.35/{s}/root/etc", .{arch});
    defer std.testing.allocator.free(runtime_etc);
    try tmp.dir.createDirPath(std.testing.io, runtime_usr_lib);
    try tmp.dir.createDirPath(std.testing.io, runtime_etc);
    try tmp.dir.createDirPath(std.testing.io, "chroot");

    var chroot_dir = try tmp.dir.openDir(std.testing.io, "chroot", .{});
    defer chroot_dir.close(std.testing.io);

    var base_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buffer);
    const base_path = base_buffer[0..base_len];
    const runtime_root_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/runtimes", .{base_path});
    defer std.testing.allocator.free(runtime_root_path);
    const chroot_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/chroot", .{base_path});
    defer std.testing.allocator.free(chroot_path);

    var bind_mounts: std.ArrayListUnmanaged(action_runner.BindMount) = .empty;
    defer {
        for (bind_mounts.items) |mount| {
            std.testing.allocator.free(mount.source);
            std.testing.allocator.free(mount.target);
        }
        bind_mounts.deinit(std.testing.allocator);
    }

    try appendLibcRuntimeMounts(
        std.testing.io,
        std.testing.allocator,
        chroot_dir,
        chroot_path,
        runtime_root_path,
        "glibc2.35",
        &bind_mounts,
    );

    try std.testing.expectEqual(@as(usize, 3), bind_mounts.items.len);
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[0].target, "/chroot/lib"));
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[1].target, "/chroot/usr/lib"));
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[2].target, "/chroot/etc"));
}

test "appendCommonRuntimeMounts maps runtime etc into chroot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "runtimes/common/root/etc");
    try tmp.dir.createDirPath(std.testing.io, "chroot");

    var chroot_dir = try tmp.dir.openDir(std.testing.io, "chroot", .{});
    defer chroot_dir.close(std.testing.io);

    var base_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &base_buffer);
    const base_path = base_buffer[0..base_len];
    const runtime_root_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/runtimes", .{base_path});
    defer std.testing.allocator.free(runtime_root_path);
    const chroot_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/chroot", .{base_path});
    defer std.testing.allocator.free(chroot_path);

    var bind_mounts: std.ArrayListUnmanaged(action_runner.BindMount) = .empty;
    defer {
        for (bind_mounts.items) |mount| {
            std.testing.allocator.free(mount.source);
            std.testing.allocator.free(mount.target);
        }
        bind_mounts.deinit(std.testing.allocator);
    }

    try appendCommonRuntimeMounts(
        std.testing.io,
        std.testing.allocator,
        chroot_dir,
        chroot_path,
        runtime_root_path,
        &bind_mounts,
    );

    try std.testing.expectEqual(@as(usize, 1), bind_mounts.items.len);
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[0].source, "/runtimes/common/root/etc"));
    try std.testing.expect(std.mem.endsWith(u8, bind_mounts.items[0].target, "/chroot/etc"));
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

    try std.testing.expect(!prepared.options.use_actiondfs);
    try std.testing.expect(prepared.options.cas_blob_root_path != null);
    try std.testing.expect(std.mem.endsWith(u8, prepared.options.cas_blob_root_path.?, "/cas/blobs/sha256"));

    const cache = prepared.options.runtime_mount_cache.?;
    try std.testing.expect(cache.common.etc != null);
    try std.testing.expect(cache.glibc2_35.lib != null);
    try std.testing.expect(cache.glibc2_35.usr_lib != null);
    try std.testing.expect(cache.glibc2_31.lib == null);
}

test "actiondfs uses input CAS root for blob reads" {
    const options: ExecuteOptions = .{
        .cas_blob_root_path = "/cas/blobs/sha256",
        .input_cas_blob_root_path = "/host-cas/blobs/sha256",
    };

    try std.testing.expectEqualStrings("/host-cas/blobs/sha256", actiondfsInputBlobRootPath(options).?);
}

test "collectInputs materializes bindable tree directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    try store.ensureLayout(std.testing.io);

    const file_digest = try store.putBytes(std.testing.io, "leaf");
    var file_hash: [64]u8 = undefined;
    const child_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{
            .{ .name = "leaf.txt", .digest = file_digest.toReapi(&file_hash) },
        },
    });

    var child_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{
            .{ .name = "tree", .digest = child_digest.toReapi(&child_hash) },
        },
    });

    var files: std.ArrayListUnmanaged(execroot.Input) = .empty;
    defer files.deinit(std.testing.allocator);
    defer freeInputs(std.testing.allocator, files.items);
    var dirs: std.ArrayListUnmanaged(execroot.DirectoryInput) = .empty;
    defer dirs.deinit(std.testing.allocator);
    defer freeDirectoryInputs(std.testing.allocator, dirs.items);

    try collectInputs(std.testing.io, std.testing.allocator, store, .{}, root_digest, "", .{}, true, &files, &dirs);

    try std.testing.expectEqual(@as(usize, 0), files.items.len);
    try std.testing.expectEqual(@as(usize, 1), dirs.items.len);
    try std.testing.expectEqualStrings("tree", dirs.items[0].path);
    try std.testing.expect(dirs.items[0].digest.eql(child_digest));
    try std.testing.expect(try store.hasTree(std.testing.io, child_digest));

    var child_tree_path_buffer: [cas.tree_prefix_len + 64]u8 = undefined;
    const child_tree_path = cas.treeSubPath(child_digest, &child_tree_path_buffer);
    const leaf_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/leaf.txt", .{child_tree_path});
    defer std.testing.allocator.free(leaf_path);
    const leaf = try cas_dir.readFileAlloc(std.testing.io, leaf_path, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(leaf);
    try std.testing.expectEqualStrings("leaf", leaf);
}

test "collectInputs reads directory metadata from staged CAS root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_dir = try tmp.dir.createDirPathOpen(std.testing.io, "store", .{});
    defer store_dir.close(std.testing.io);
    var lower_dir = try tmp.dir.createDirPathOpen(std.testing.io, "lower", .{});
    defer lower_dir.close(std.testing.io);
    var staged_dir = try tmp.dir.createDirPathOpen(std.testing.io, "staged", .{});
    defer staged_dir.close(std.testing.io);

    const file_digest = cas.Digest.fromBytes("leaf");
    var file_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, cas.Store.init(staged_dir), reapi.Directory{
        .files = &.{.{ .name = "leaf.txt", .digest = file_digest.toReapi(&file_hash) }},
    });

    var lower_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const lower_root_len = try lower_dir.realPath(std.testing.io, &lower_root_buffer);
    const lower_blob_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/blobs/sha256", .{lower_root_buffer[0..lower_root_len]});
    defer std.testing.allocator.free(lower_blob_root);

    var staged_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const staged_root_len = try staged_dir.realPath(std.testing.io, &staged_root_buffer);
    const staged_blob_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/blobs/sha256", .{staged_root_buffer[0..staged_root_len]});
    defer std.testing.allocator.free(staged_blob_root);

    var files: std.ArrayListUnmanaged(execroot.Input) = .empty;
    defer files.deinit(std.testing.allocator);
    defer freeInputs(std.testing.allocator, files.items);

    try collectInputs(
        std.testing.io,
        std.testing.allocator,
        cas.Store.init(store_dir),
        .{
            .primary_blob_root_path = lower_blob_root,
            .staged_blob_root_path = staged_blob_root,
        },
        root_digest,
        "",
        .{},
        false,
        &files,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), files.items.len);
    try std.testing.expectEqualStrings("leaf.txt", files.items[0].path);
    try std.testing.expect(files.items[0].digest.eql(file_digest));
}

test "collectInputs expands directories that overlap outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    try store.ensureLayout(std.testing.io);

    const file_digest = try store.putBytes(std.testing.io, "leaf");
    var file_hash: [64]u8 = undefined;
    const child_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{
            .{ .name = "leaf.txt", .digest = file_digest.toReapi(&file_hash) },
        },
    });

    var child_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{
            .{ .name = "tree", .digest = child_digest.toReapi(&child_hash) },
        },
    });

    var files: std.ArrayListUnmanaged(execroot.Input) = .empty;
    defer files.deinit(std.testing.allocator);
    defer freeInputs(std.testing.allocator, files.items);
    var dirs: std.ArrayListUnmanaged(execroot.DirectoryInput) = .empty;
    defer dirs.deinit(std.testing.allocator);
    defer freeDirectoryInputs(std.testing.allocator, dirs.items);

    try collectInputs(
        std.testing.io,
        std.testing.allocator,
        store,
        .{},
        root_digest,
        "",
        .{ .output_paths = &.{"tree/out.txt"} },
        true,
        &files,
        &dirs,
    );

    try std.testing.expectEqual(@as(usize, 1), files.items.len);
    try std.testing.expectEqualStrings("tree/leaf.txt", files.items[0].path);
    try std.testing.expectEqual(@as(usize, 0), dirs.items.len);
    try std.testing.expect(!try store.hasTree(std.testing.io, child_digest));
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

    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, root);
    try std.testing.expect(!try store.hasTree(std.testing.io, root_digest));

    var result = try actionResultFromOutcomeOwned(std.testing.allocator, outcome);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.result.output_directories.len);
    try std.testing.expectEqualStrings("tree", result.result.output_directories[0].path);
    var tree_hash: [64]u8 = undefined;
    try std.testing.expect(result.result.output_directories[0].tree_digest.?.eql(outcome.output_directories[0].tree_digest.toReapi(&tree_hash)));
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
