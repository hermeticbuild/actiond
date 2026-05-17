const builtin = @import("builtin");
const std = @import("std");
const action_cache = @import("action_cache.zig");
const action_runner = @import("action_runner.zig");
const cas = @import("cas.zig");
const execroot = @import("execroot.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

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
const worker_name = "actiond";

pub const ExecuteOptions = struct {
    runtime_root_path: ?[]const u8 = null,
};

pub fn executeAndCacheAction(
    io: std.Io,
    allocator: std.mem.Allocator,
    blob_store: cas.Store,
    result_store: action_cache.Store,
    work_root: std.Io.Dir,
    action_digest: cas.Digest,
) !action_runner.Outcome {
    var outcome = try executeActionWithOptions(io, allocator, blob_store, work_root, action_digest, .{});
    errdefer outcome.deinit(allocator);

    var result = try actionResultFromOutcomeOwned(allocator, outcome);
    defer result.deinit(allocator);
    try result_store.put(
        io,
        allocator,
        action_digest,
        result.result,
    );
    return outcome;
}

pub fn executeAction(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    action_digest: cas.Digest,
) !action_runner.Outcome {
    return executeActionWithOptions(io, allocator, store, work_root, action_digest, .{});
}

pub fn materializeActionInputTrees(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    action_digest: cas.Digest,
) !void {
    const action_bytes = store.readAlloc(io, allocator, action_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingActionBlob,
        else => return err,
    };
    defer allocator.free(action_bytes);
    var action_reader = protobuf.Reader.init(action_bytes);
    var action = try reapi.Action.decodeOwned(allocator, &action_reader);
    defer action.deinit(allocator);

    const command_digest = try cas.Digest.fromReapi(action.command_digest orelse return error.MissingCommandDigest);
    const command_bytes = store.readAlloc(io, allocator, command_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCommandBlob,
        else => return err,
    };
    defer allocator.free(command_bytes);
    var command_reader = protobuf.Reader.init(command_bytes);
    var command = try reapi.Command.decodeOwned(allocator, &command_reader);
    defer command.deinit(allocator);

    const input_root_digest = try cas.Digest.fromReapi(action.input_root_digest orelse return error.MissingInputRootDigest);
    try collectInputs(io, allocator, store, input_root_digest, "", command, !forceFileInputs(command, action.platform), null, null);
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

    const action_bytes = store.readAlloc(io, allocator, action_digest) catch |err| switch (err) {
        error.FileNotFound => return error.MissingActionBlob,
        else => return err,
    };
    defer allocator.free(action_bytes);
    var action_reader = protobuf.Reader.init(action_bytes);
    var action = try reapi.Action.decodeOwned(allocator, &action_reader);
    defer action.deinit(allocator);

    const command_digest = try cas.Digest.fromReapi(action.command_digest orelse return error.MissingCommandDigest);
    const command_bytes = store.readAlloc(io, allocator, command_digest) catch |err| switch (err) {
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
    const force_file_inputs = forceFileInputs(command, action.platform);
    const use_actiondfs_inputs = use_workspace_chroot and !force_file_inputs and kernelSupportsActiondfs(io, allocator);
    if (use_actiondfs_inputs) {
        var input_root_blob = store.openBlob(io, input_root_digest) catch |err| switch (err) {
            error.FileNotFound => return error.MissingDirectoryBlob,
            else => return err,
        };
        input_root_blob.close(io);
    } else {
        const allow_directory_inputs = use_workspace_chroot and !force_file_inputs;
        try collectInputs(io, allocator, store, input_root_digest, "", command, allow_directory_inputs, &inputs, &directory_inputs);
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

    var actiondfs_workspace: ?ActiondfsWorkspace = null;
    defer if (actiondfs_workspace) |*workspace| workspace.deinit(io, allocator);
    if (use_actiondfs_inputs) {
        actiondfs_workspace = try ActiondfsWorkspace.init(
            io,
            allocator,
            store,
            work_root_path,
            exec_root_path,
            input_root_digest,
        );
        actiondfs_upper_dir = try std.Io.Dir.openDirAbsolute(io, actiondfs_workspace.?.mounts[0].upperdir, .{});
        exec_root_dir = actiondfs_upper_dir.?;
    }

    const materializer = execroot.Materializer.init(store, exec_root_dir);
    var materialization: execroot.Materialization = .{};
    if (!use_actiondfs_inputs) {
        materialization = materializer.materializeInputs(io, allocator, inputs.items, .{
            .chroot_root_path = exec_root_path,
            .directory_inputs = directory_inputs.items,
            .copy_all_executable_inputs = false,
            .copy_executable_inputs = executable_copy_paths.items,
        }) catch |err| switch (err) {
            error.FileNotFound, error.MissingInputTree => return error.MissingInputBlob,
            else => return err,
        };
    }
    defer materialization.deinit(allocator);
    prepareOutputParents(io, exec_root_dir, command) catch |err| switch (err) {
        error.FileNotFound => return error.OutputParentCreateFailed,
        else => return err,
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
    defer {
        for (bind_mounts.items[borrowed_bind_mount_count..]) |mount| {
            allocator.free(mount.source);
            allocator.free(mount.target);
        }
        bind_mounts.deinit(allocator);
    }
    try bind_mounts.appendSlice(allocator, materialization.bind_mounts);
    if (options.runtime_root_path) |runtime_root| {
        if (libc_runtime == null) {
            try appendCommonRuntimeMounts(io, allocator, work_root, work_root_path, runtime_root, &bind_mounts);
        }
    }
    if (libc_runtime) |libc| {
        const runtime_root = options.runtime_root_path orelse return error.MissingRuntimeRoot;
        try appendLibcRuntimeMounts(io, allocator, work_root, work_root_path, runtime_root, libc, &bind_mounts);
    }

    const input_fetch_completed_wall = timestampNow(io);
    const input_fetch_completed = std.Io.Clock.awake.now(io);
    const execution_start_wall = timestampNow(io);
    const execution_start = std.Io.Clock.awake.now(io);
    var outcome = try action_runner.runCommandWithOptions(io, allocator, store, command, .{
        .chroot_dir = work_root_path,
        .chroot_cwd = chroot_cwd,
        .bind_mounts = bind_mounts.items,
        .actiondfs_mounts = if (actiondfs_workspace) |*workspace| workspace.mounts[0..] else &.{},
        .cgroup_limits = action_runner.CgroupLimits.fromPlatform(action.platform),
    });
    errdefer outcome.deinit(allocator);
    const execution_completed_wall = timestampNow(io);
    const execution_completed = std.Io.Clock.awake.now(io);
    const output_upload_start_wall = timestampNow(io);
    const output_upload_start = std.Io.Clock.awake.now(io);
    if (actiondfs_workspace) |*workspace| {
        try workspace.mountForCollection();
        var merged_dir = try std.Io.Dir.openDirAbsolute(io, workspace.mounts[0].overlay_target, .{ .iterate = true });
        defer merged_dir.close(io);
        try collectOutputFiles(io, allocator, store, merged_dir, command, &outcome);
    } else {
        try collectOutputFiles(io, allocator, store, exec_root_dir, command, &outcome);
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
        if (std.mem.eql(u8, property.value, "glibc2.31")) return "glibc2.31";
        if (std.mem.eql(u8, property.value, "glibc2.35")) return "glibc2.35";
        if (std.mem.eql(u8, property.value, "glibc2.39")) return "glibc2.39";
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

fn forceFileInputsFromPlatform(platform: ?reapi.Platform) bool {
    const value = platform orelse return false;
    for (value.properties) |property| {
        if (!std.mem.eql(u8, property.name, "actiond.input_mode")) continue;
        return std.mem.eql(u8, property.value, "files");
    }
    return false;
}

fn forceFileInputsFromCommand(command: reapi.Command) bool {
    for (command.environment_variables) |variable| {
        if (!std.mem.eql(u8, variable.name, "ACTIOND_INPUT_MODE")) continue;
        return std.mem.eql(u8, variable.value, "files");
    }
    return false;
}

fn forceFileInputs(command: reapi.Command, platform: ?reapi.Platform) bool {
    return forceFileInputsFromPlatform(platform) or forceFileInputsFromCommand(command);
}

fn kernelSupportsActiondfs(io: std.Io, allocator: std.mem.Allocator) bool {
    _ = allocator;
    if (comptime builtin.os.tag != .linux) return false;

    var proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{}) catch return false;
    defer proc.close(io);
    var file = proc.openFile(io, "filesystems", .{}) catch return false;
    defer file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    while (len < buffer.len) {
        const rc = std.os.linux.read(file.handle, buffer[len..].ptr, buffer.len - len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) break;
                len += n;
            },
            .INTR => continue,
            else => return false,
        }
    }
    const filesystems = buffer[0..len];

    var lines = std.mem.splitScalar(u8, filesystems, '\n');
    while (lines.next()) |line| {
        const fs = std.mem.trim(u8, line, " \t");
        if (std.mem.endsWith(u8, fs, "actiondfs")) return true;
    }
    return false;
}

fn selectExecutableInputCopyPaths(
    allocator: std.mem.Allocator,
    command: reapi.Command,
    inputs: []const execroot.Input,
    workspace_prefix: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    if (command.arguments.len == 0) return;
    const argv0 = command.arguments[0];
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        if (try execArgToInputPath(allocator, command.working_directory, argv0, workspace_prefix)) |candidate| {
            defer allocator.free(candidate);
            _ = try appendExecutableInputPath(allocator, inputs, candidate, out);
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
            defer allocator.free(candidate);
            _ = try appendExecutableInputPath(allocator, inputs, candidate, out);
        }
    }
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
        store: cas.Store,
        work_root_path: []const u8,
        workspace_path: []const u8,
        input_root_digest: cas.Digest,
    ) !ActiondfsWorkspace {
        const base_path = try std.fmt.allocPrint(allocator, "{s}.actiondfs", .{work_root_path});
        errdefer allocator.free(base_path);
        std.Io.Dir.cwd().deleteTree(io, base_path) catch {};
        try std.Io.Dir.cwd().createDirPath(io, base_path);

        const lower_path = try std.fmt.allocPrintSentinel(allocator, "{s}/lower", .{base_path}, 0);
        errdefer allocator.free(lower_path);
        const upper_path = try std.fmt.allocPrintSentinel(allocator, "{s}/upper", .{base_path}, 0);
        errdefer allocator.free(upper_path);
        const work_path = try std.fmt.allocPrint(allocator, "{s}/work", .{base_path});
        defer allocator.free(work_path);

        try std.Io.Dir.cwd().createDirPath(io, lower_path);
        try std.Io.Dir.cwd().createDirPath(io, upper_path);
        try std.Io.Dir.cwd().createDirPath(io, work_path);

        var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cas_root_len = try store.root.realPath(io, &cas_root_buffer);
        const cas_blob_root = try std.fmt.allocPrint(allocator, "{s}/blobs/sha256", .{cas_root_buffer[0..cas_root_len]});
        defer allocator.free(cas_blob_root);
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

fn collectOutputFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
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
            try collectOutputPath(io, allocator, store, work_root, path, &output_files, &output_directories);
        }
    } else {
        for (command.output_files) |path| {
            try collectOutputFile(io, allocator, store, work_root, path, &output_files);
        }
        for (command.output_directories) |path| {
            try collectOutputDirectory(io, allocator, store, work_root, path, &output_directories);
        }
    }

    outcome.output_files = try output_files.toOwnedSlice(allocator);
    outcome.output_directories = try output_directories.toOwnedSlice(allocator);
}

fn collectOutputPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
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
        .file => try collectOutputFileWithStat(io, allocator, store, work_root, path, stat, output_files),
        .directory => try collectOutputDirectoryWithStat(io, allocator, store, work_root, path, output_directories),
        else => return error.FailedPrecondition,
    }
}

fn collectOutputFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
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
    try collectOutputFileWithStat(io, allocator, store, work_root, path, stat, output_files);
}

fn collectOutputFileWithStat(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    path: []const u8,
    stat: std.Io.Dir.Stat,
    output_files: *std.ArrayListUnmanaged(action_runner.Outcome.OutputFile),
) !void {
    if (stat.size > max_output_file_bytes) return error.FileTooBig;

    const digest = store.putFile(io, work_root, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    try output_files.append(allocator, .{
        .path = path_copy,
        .digest = digest,
        .is_executable = isExecutable(stat),
    });
}

fn collectOutputDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
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
    try collectOutputDirectoryWithStat(io, allocator, store, work_root, path, output_directories);
}

fn collectOutputDirectoryWithStat(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    work_root: std.Io.Dir,
    path: []const u8,
    output_directories: *std.ArrayListUnmanaged(action_runner.Outcome.OutputDirectory),
) !void {
    var dir = try work_root.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var tree = OutputTreeBuilder{};
    defer tree.deinit(allocator);
    _ = try putOutputDirectoryTree(io, allocator, store, dir, &tree, true);
    const tree_digest = try tree.putTreeProto(io, allocator, store);

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
                try files.append(allocator, .{
                    .name = try tree.dupe(allocator, entry.name),
                    .digest = try tree.appendDigest(allocator, digest),
                    .is_executable = isExecutable(stat),
                });
            },
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                const digest = try putOutputDirectoryTree(io, allocator, store, child, tree, false);
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
    directory_digest: cas.Digest,
    prefix: []const u8,
    command: reapi.Command,
    allow_directory_inputs: bool,
    inputs: ?*std.ArrayListUnmanaged(execroot.Input),
    directory_inputs: ?*std.ArrayListUnmanaged(execroot.DirectoryInput),
) !void {
    const directory_bytes = store.readAlloc(io, allocator, directory_digest) catch |err| switch (err) {
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
            try collectInputs(io, allocator, store, digest, child_prefix, command, allow_directory_inputs, inputs, directory_inputs);
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

test "actiond input mode platform property can force file inputs" {
    try std.testing.expect(forceFileInputsFromPlatform(.{
        .properties = &.{.{ .name = "actiond.input_mode", .value = "files" }},
    }));
    try std.testing.expect(!forceFileInputsFromPlatform(.{
        .properties = &.{.{ .name = "actiond.input_mode", .value = "trees" }},
    }));
    try std.testing.expect(!forceFileInputsFromPlatform(null));
}

test "actiond input mode command environment can force file inputs" {
    try std.testing.expect(forceFileInputsFromCommand(.{
        .environment_variables = &.{.{ .name = "ACTIOND_INPUT_MODE", .value = "files" }},
    }));
    try std.testing.expect(!forceFileInputsFromCommand(.{
        .environment_variables = &.{.{ .name = "ACTIOND_INPUT_MODE", .value = "trees" }},
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

    try collectInputs(std.testing.io, std.testing.allocator, store, root_digest, "", .{}, true, &files, &dirs);

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

    try collectOutputFiles(std.testing.io, std.testing.allocator, store, work_dir, .{
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
