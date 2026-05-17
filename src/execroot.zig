const std = @import("std");
const action_runner = @import("action_runner.zig");
const cas = @import("cas.zig");

pub const Error = error{
    EmptyExecPath,
    EscapingExecPath,
};

pub const Input = struct {
    path: []const u8,
    digest: cas.Digest,
    is_executable: bool = false,
};

pub const DirectoryInput = struct {
    path: []const u8,
    digest: cas.Digest,
};

pub const MaterializeOptions = struct {
    chroot_root_path: ?[]const u8 = null,
    cas_blob_root_path: ?[]const u8 = null,
    staged_cas_blob_root_path: ?[]const u8 = null,
    directory_inputs: []const DirectoryInput = &.{},
    copy_all_executable_inputs: bool = true,
    copy_executable_inputs: []const []const u8 = &.{},
};

pub const Materialization = struct {
    bind_mounts: []action_runner.BindMount = &.{},

    pub fn deinit(self: *Materialization, allocator: std.mem.Allocator) void {
        for (self.bind_mounts) |mount| {
            allocator.free(mount.source);
            allocator.free(mount.target);
        }
        allocator.free(self.bind_mounts);
        self.* = .{};
    }
};

pub const Materializer = struct {
    store: cas.Store,
    root: std.Io.Dir,

    pub fn init(store: cas.Store, root: std.Io.Dir) Materializer {
        return .{
            .store = store,
            .root = root,
        };
    }

    pub fn copyInputs(
        self: Materializer,
        io: std.Io,
        allocator: std.mem.Allocator,
        inputs: []const Input,
    ) !void {
        var materialization = try self.materializeInputs(io, allocator, inputs, .{});
        defer materialization.deinit(allocator);
    }

    pub fn materializeInputs(
        self: Materializer,
        io: std.Io,
        allocator: std.mem.Allocator,
        inputs: []const Input,
        options: MaterializeOptions,
    ) !Materialization {
        var bind_mounts: std.ArrayListUnmanaged(action_runner.BindMount) = .empty;
        errdefer {
            for (bind_mounts.items) |mount| {
                allocator.free(mount.source);
                allocator.free(mount.target);
            }
            bind_mounts.deinit(allocator);
        }
        var cas_root_path: ?[]u8 = null;
        defer if (cas_root_path) |path| allocator.free(path);
        if (options.chroot_root_path != null) {
            var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const cas_root_len = try self.store.root.realPath(io, &cas_root_buffer);
            cas_root_path = try allocator.dupe(u8, cas_root_buffer[0..cas_root_len]);
        }

        if (options.directory_inputs.len != 0 and options.chroot_root_path == null) {
            return error.UnsupportedDirectoryInputsWithoutChroot;
        }

        for (options.directory_inputs) |input| {
            try validatePath(input.path);
            if (parentDir(input.path)) |parent| try self.root.createDirPath(io, parent);
            try self.materializeChrootDirectoryInput(
                io,
                allocator,
                input,
                options.chroot_root_path.?,
                cas_root_path,
                &bind_mounts,
            );
        }

        var last_parent: ?[]const u8 = null;
        for (inputs) |input| {
            try validatePath(input.path);
            if (parentDir(input.path)) |parent| {
                if (last_parent == null or !std.mem.eql(u8, last_parent.?, parent)) {
                    try self.root.createDirPath(io, parent);
                    last_parent = parent;
                }
            }

            if (options.chroot_root_path) |root_path| {
                try self.materializeChrootInput(
                    io,
                    allocator,
                    input,
                    root_path,
                    cas_root_path,
                    options,
                    &bind_mounts,
                );
            } else {
                try self.store.copyToFile(
                    io,
                    input.digest,
                    self.root,
                    input.path,
                    if (input.is_executable) .executable_file else .default_file,
                );
            }
        }

        return .{
            .bind_mounts = try bind_mounts.toOwnedSlice(allocator),
        };
    }

    fn materializeChrootInput(
        self: Materializer,
        io: std.Io,
        allocator: std.mem.Allocator,
        input: Input,
        root_path: []const u8,
        cas_root_path: ?[]const u8,
        options: MaterializeOptions,
        bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
    ) !void {
        const copy_resolved_executable = pathInList(input.path, options.copy_executable_inputs);
        const copy_executable = copy_resolved_executable or
            (input.is_executable and options.copy_all_executable_inputs);
        const permissions: std.Io.File.Permissions = if (input.is_executable or copy_resolved_executable)
            .executable_file
        else
            .default_file;
        if (copy_executable or input.digest.isEmpty()) {
            if (!input.digest.isEmpty()) {
                if (options.cas_blob_root_path) |blob_root_path| {
                    return copyBlobFromSourceRoots(
                        io,
                        allocator,
                        input.digest,
                        options.staged_cas_blob_root_path,
                        blob_root_path,
                        self.root,
                        input.path,
                        permissions,
                    );
                }
            }
            return self.store.copyToFile(io, input.digest, self.root, input.path, permissions);
        }

        const source = if (options.cas_blob_root_path) |blob_root_path|
            try selectBlobSourcePath(allocator, io, input.digest, options.staged_cas_blob_root_path, blob_root_path)
        else source: {
            var blob = try self.store.openBlob(io, input.digest);
            blob.close(io);
            var blob_path_buffer: [cas.blob_prefix_len + 64]u8 = undefined;
            const blob_path = cas.blobSubPath(input.digest, &blob_path_buffer);
            break :source try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ cas_root_path.?, blob_path }, 0);
        };
        errdefer allocator.free(source);
        try self.root.writeFile(io, .{
            .sub_path = input.path,
            .data = "",
            .flags = .{ .read = true, .permissions = .default_file },
        });
        const target = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ root_path, input.path }, 0);
        errdefer allocator.free(target);
        try bind_mounts.append(allocator, .{
            .source = source,
            .target = target,
        });
    }

    fn materializeChrootDirectoryInput(
        self: Materializer,
        io: std.Io,
        allocator: std.mem.Allocator,
        input: DirectoryInput,
        root_path: []const u8,
        cas_root_path: ?[]const u8,
        bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
    ) !void {
        if (!try self.store.hasTree(io, input.digest)) return error.MissingInputTree;
        try self.root.createDirPath(io, input.path);

        var tree_path_buffer: [cas.tree_prefix_len + 64]u8 = undefined;
        const tree_path = cas.treeSubPath(input.digest, &tree_path_buffer);
        const source = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ cas_root_path.?, tree_path }, 0);
        errdefer allocator.free(source);
        const target = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ root_path, input.path }, 0);
        errdefer allocator.free(target);
        try bind_mounts.append(allocator, .{
            .source = source,
            .target = target,
        });
    }
};

fn selectBlobSourcePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    digest: cas.Digest,
    staged_blob_root_path: ?[]const u8,
    blob_root_path: []const u8,
) ![:0]u8 {
    if (staged_blob_root_path) |staged_root| {
        const staged_path = try blobPathFromRoot(allocator, staged_root, digest);
        const exists = blobPathExists(io, staged_path) catch |err| {
            allocator.free(staged_path);
            return err;
        };
        if (exists) return staged_path;
        allocator.free(staged_path);
    }

    const path = try blobPathFromRoot(allocator, blob_root_path, digest);
    errdefer allocator.free(path);
    var file = try openBlobPath(io, path);
    file.close(io);
    return path;
}

fn blobPathFromRoot(
    allocator: std.mem.Allocator,
    blob_root_path: []const u8,
    digest: cas.Digest,
) ![:0]u8 {
    var hash: [64]u8 = undefined;
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ blob_root_path, digest.formatHex(&hash) }, 0);
}

fn blobPathExists(io: std.Io, path: [:0]const u8) !bool {
    var file = openBlobPath(io, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    file.close(io);
    return true;
}

fn copyBlobFromSourceRoots(
    io: std.Io,
    allocator: std.mem.Allocator,
    digest: cas.Digest,
    staged_blob_root_path: ?[]const u8,
    blob_root_path: []const u8,
    dest_dir: std.Io.Dir,
    dest_path: []const u8,
    permissions: std.Io.File.Permissions,
) !void {
    const source_path = try selectBlobSourcePath(allocator, io, digest, staged_blob_root_path, blob_root_path);
    defer allocator.free(source_path);

    var src = try openBlobPath(io, source_path);
    defer src.close(io);
    var dest = try dest_dir.createFile(io, dest_path, .{
        .truncate = true,
        .permissions = permissions,
    });
    defer dest.close(io);

    var buffer: [128 * 1024]u8 = undefined;
    while (true) {
        const n = try readFd(src.handle, &buffer);
        if (n == 0) break;
        try writeFdAll(dest.handle, buffer[0..n]);
    }
}

fn openBlobPath(io: std.Io, path: [:0]const u8) !std.Io.File {
    if (comptime @import("builtin").os.tag == .linux) {
        return openBlobPathLinuxRetry(path);
    }
    return std.Io.Dir.openFileAbsolute(io, path, .{});
}

fn openBlobPathLinuxRetry(path: [:0]const u8) !std.Io.File {
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
                sleepStaleRetry();
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

fn sleepStaleRetry() void {
    if (comptime @import("builtin").os.tag != .linux) return;
    var request: std.os.linux.timespec = .{
        .sec = 0,
        .nsec = 2 * std.time.ns_per_ms,
    };
    while (std.posix.errno(std.os.linux.nanosleep(&request, &request)) == .INTR) {}
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

fn writeFdAll(fd: std.Io.File.Handle, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteFailed;
                offset += n;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn pathInList(path: []const u8, paths: []const []const u8) bool {
    for (paths) |candidate| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0) return error.EmptyExecPath;
    if (std.fs.path.isAbsolute(path)) return error.EscapingExecPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EscapingExecPath;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0) return error.EscapingExecPath;
        if (std.mem.eql(u8, component, ".")) return error.EscapingExecPath;
        if (std.mem.eql(u8, component, "..")) return error.EscapingExecPath;
    }
}

fn createParentDirs(root: std.Io.Dir, io: std.Io, path: []const u8) !void {
    if (parentDir(path)) |parent| try root.createDirPath(io, parent);
}

fn parentDir(path: []const u8) ?[]const u8 {
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return path[0..last_slash];
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

test "Materializer copies CAS blobs into an execroot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    const hello = try store.putBytes(std.testing.io, "hello\n");
    const tool = try store.putBytes(std.testing.io, "#!/bin/sh\n");

    const materializer = Materializer.init(store, work_dir);
    try materializer.copyInputs(std.testing.io, std.testing.allocator, &.{
        .{ .path = "src/hello.txt", .digest = hello },
        .{ .path = "tools/run.sh", .digest = tool, .is_executable = true },
    });

    const restored = try work_dir.readFileAlloc(
        std.testing.io,
        "src/hello.txt",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("hello\n", restored);
    var hello_blob_path_buffer: [cas.blob_prefix_len + 64]u8 = undefined;
    const hello_blob_path = cas.blobSubPath(hello, &hello_blob_path_buffer);
    const hello_cas_stat = try cas_dir.statFile(std.testing.io, hello_blob_path, .{});
    const hello_work_stat = try work_dir.statFile(std.testing.io, "src/hello.txt", .{});
    try std.testing.expect(hello_cas_stat.inode != hello_work_stat.inode);

    const restored_tool = try work_dir.readFileAlloc(
        std.testing.io,
        "tools/run.sh",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(restored_tool);
    try std.testing.expectEqualStrings("#!/bin/sh\n", restored_tool);
}

test "Materializer prepares read-only bind mounts for chroot inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    const digest = try store.putBytes(std.testing.io, "large-ish immutable input");
    const tool = try store.putBytes(std.testing.io, "#!/bin/sh\n");

    var work_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const work_root_len = try work_dir.realPath(std.testing.io, &work_root_buffer);
    var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cas_root_len = try cas_dir.realPath(std.testing.io, &cas_root_buffer);
    const materializer = Materializer.init(store, work_dir);
    var materialization = try materializer.materializeInputs(std.testing.io, std.testing.allocator, &.{
        .{ .path = "inputs/data.txt", .digest = digest },
        .{ .path = "tools/run.sh", .digest = tool, .is_executable = true },
    }, .{
        .chroot_root_path = work_root_buffer[0..work_root_len],
    });
    defer materialization.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), materialization.bind_mounts.len);

    var blob_path_buffer: [cas.blob_prefix_len + 64]u8 = undefined;
    const blob_path = cas.blobSubPath(digest, &blob_path_buffer);
    const expected_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}",
        .{ cas_root_buffer[0..cas_root_len], blob_path },
    );
    defer std.testing.allocator.free(expected_source);
    const expected_target = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/inputs/data.txt",
        .{work_root_buffer[0..work_root_len]},
    );
    defer std.testing.allocator.free(expected_target);
    try std.testing.expectEqualStrings(expected_source, materialization.bind_mounts[0].source);
    try std.testing.expectEqualStrings(expected_target, materialization.bind_mounts[0].target);

    const placeholder = try work_dir.readFileAlloc(
        std.testing.io,
        "inputs/data.txt",
        std.testing.allocator,
        .limited(1),
    );
    defer std.testing.allocator.free(placeholder);
    try std.testing.expectEqual(@as(usize, 0), placeholder.len);

    const restored_tool = try work_dir.readFileAlloc(
        std.testing.io,
        "tools/run.sh",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(restored_tool);
    try std.testing.expectEqualStrings("#!/bin/sh\n", restored_tool);
}

test "Materializer can bind executable chroot inputs outside the copy list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    const data = try store.putBytes(std.testing.io, "data\n");
    const tool = try store.putBytes(std.testing.io, "#!/bin/sh\n");

    var work_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const work_root_len = try work_dir.realPath(std.testing.io, &work_root_buffer);
    var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cas_root_len = try cas_dir.realPath(std.testing.io, &cas_root_buffer);
    const materializer = Materializer.init(store, work_dir);
    var materialization = try materializer.materializeInputs(std.testing.io, std.testing.allocator, &.{
        .{ .path = "inputs/data.txt", .digest = data, .is_executable = true },
        .{ .path = "tools/run.sh", .digest = tool, .is_executable = true },
    }, .{
        .chroot_root_path = work_root_buffer[0..work_root_len],
        .copy_all_executable_inputs = false,
        .copy_executable_inputs = &.{"tools/run.sh"},
    });
    defer materialization.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), materialization.bind_mounts.len);

    var blob_path_buffer: [cas.blob_prefix_len + 64]u8 = undefined;
    const blob_path = cas.blobSubPath(data, &blob_path_buffer);
    const expected_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}",
        .{ cas_root_buffer[0..cas_root_len], blob_path },
    );
    defer std.testing.allocator.free(expected_source);
    const expected_target = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/inputs/data.txt",
        .{work_root_buffer[0..work_root_len]},
    );
    defer std.testing.allocator.free(expected_target);
    try std.testing.expectEqualStrings(expected_source, materialization.bind_mounts[0].source);
    try std.testing.expectEqualStrings(expected_target, materialization.bind_mounts[0].target);

    const restored_tool = try work_dir.readFileAlloc(
        std.testing.io,
        "tools/run.sh",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(restored_tool);
    try std.testing.expectEqualStrings("#!/bin/sh\n", restored_tool);
}

test "Materializer prepares read-only bind mounts for chroot tree inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    try store.ensureLayout(std.testing.io);
    const tree_digest = cas.Digest.fromBytes("tree proto");
    var tree_path_buffer: [cas.tree_prefix_len + 64]u8 = undefined;
    const tree_path = cas.treeSubPath(tree_digest, &tree_path_buffer);
    try cas_dir.createDirPath(std.testing.io, tree_path);

    var work_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const work_root_len = try work_dir.realPath(std.testing.io, &work_root_buffer);
    var cas_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cas_root_len = try cas_dir.realPath(std.testing.io, &cas_root_buffer);
    const materializer = Materializer.init(store, work_dir);
    var materialization = try materializer.materializeInputs(std.testing.io, std.testing.allocator, &.{}, .{
        .chroot_root_path = work_root_buffer[0..work_root_len],
        .directory_inputs = &.{
            .{ .path = "tree-artifact", .digest = tree_digest },
        },
    });
    defer materialization.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), materialization.bind_mounts.len);
    const expected_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}",
        .{ cas_root_buffer[0..cas_root_len], tree_path },
    );
    defer std.testing.allocator.free(expected_source);
    const expected_target = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/tree-artifact",
        .{work_root_buffer[0..work_root_len]},
    );
    defer std.testing.allocator.free(expected_target);
    try std.testing.expectEqualStrings(expected_source, materialization.bind_mounts[0].source);
    try std.testing.expectEqualStrings(expected_target, materialization.bind_mounts[0].target);

    const stat = try work_dir.statFile(std.testing.io, "tree-artifact", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
}

test "Materializer chooses staged blob root before immutable blob root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_dir = try tmp.dir.createDirPathOpen(std.testing.io, "store", .{});
    defer store_dir.close(std.testing.io);
    var lower_dir = try tmp.dir.createDirPathOpen(std.testing.io, "lower", .{});
    defer lower_dir.close(std.testing.io);
    var staged_dir = try tmp.dir.createDirPathOpen(std.testing.io, "staged", .{});
    defer staged_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const digest = cas.Digest.fromBytes("fresh-output");
    try cas.Store.init(lower_dir).putKnownBytes(std.testing.io, digest, "fresh-output");
    try cas.Store.init(staged_dir).putKnownBytes(std.testing.io, digest, "fresh-output");

    var work_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const work_root_len = try work_dir.realPath(std.testing.io, &work_root_buffer);
    var lower_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const lower_root_len = try lower_dir.realPath(std.testing.io, &lower_root_buffer);
    var staged_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const staged_root_len = try staged_dir.realPath(std.testing.io, &staged_root_buffer);
    const lower_blob_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/blobs/sha256", .{lower_root_buffer[0..lower_root_len]});
    defer std.testing.allocator.free(lower_blob_root);
    const staged_blob_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/blobs/sha256", .{staged_root_buffer[0..staged_root_len]});
    defer std.testing.allocator.free(staged_blob_root);

    const materializer = Materializer.init(cas.Store.init(store_dir), work_dir);
    var materialization = try materializer.materializeInputs(std.testing.io, std.testing.allocator, &.{
        .{ .path = "out/lib.a", .digest = digest },
    }, .{
        .chroot_root_path = work_root_buffer[0..work_root_len],
        .cas_blob_root_path = lower_blob_root,
        .staged_cas_blob_root_path = staged_blob_root,
    });
    defer materialization.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), materialization.bind_mounts.len);
    var hash: [64]u8 = undefined;
    const expected_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}",
        .{ staged_blob_root, digest.formatHex(&hash) },
    );
    defer std.testing.allocator.free(expected_source);
    try std.testing.expectEqualStrings(expected_source, materialization.bind_mounts[0].source);
}

test "Materializer copies resolved executable from immutable blob root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_dir = try tmp.dir.createDirPathOpen(std.testing.io, "store", .{});
    defer store_dir.close(std.testing.io);
    var lower_dir = try tmp.dir.createDirPathOpen(std.testing.io, "lower", .{});
    defer lower_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const digest = cas.Digest.fromBytes("#!/bin/sh\n");
    try cas.Store.init(lower_dir).putKnownBytes(std.testing.io, digest, "#!/bin/sh\n");

    var work_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const work_root_len = try work_dir.realPath(std.testing.io, &work_root_buffer);
    var lower_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const lower_root_len = try lower_dir.realPath(std.testing.io, &lower_root_buffer);
    const lower_blob_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/blobs/sha256", .{lower_root_buffer[0..lower_root_len]});
    defer std.testing.allocator.free(lower_blob_root);

    const materializer = Materializer.init(cas.Store.init(store_dir), work_dir);
    var materialization = try materializer.materializeInputs(std.testing.io, std.testing.allocator, &.{
        .{ .path = "tools/run.sh", .digest = digest, .is_executable = false },
    }, .{
        .chroot_root_path = work_root_buffer[0..work_root_len],
        .cas_blob_root_path = lower_blob_root,
        .copy_all_executable_inputs = false,
        .copy_executable_inputs = &.{"tools/run.sh"},
    });
    defer materialization.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), materialization.bind_mounts.len);
    const restored = try work_dir.readFileAlloc(
        std.testing.io,
        "tools/run.sh",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("#!/bin/sh\n", restored);
}
