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

pub const MaterializeOptions = struct {
    chroot_root_path: ?[]const u8 = null,
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
                try self.materializeChrootInput(io, allocator, input, root_path, cas_root_path.?, &bind_mounts);
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
        cas_root_path: []const u8,
        bind_mounts: *std.ArrayListUnmanaged(action_runner.BindMount),
    ) !void {
        const permissions: std.Io.File.Permissions = if (input.is_executable) .executable_file else .default_file;
        if (input.is_executable or input.digest.isEmpty()) {
            return self.store.copyToFile(io, input.digest, self.root, input.path, permissions);
        }

        self.store.hardLinkToFile(io, input.digest, self.root, input.path, permissions) catch |err| switch (err) {
            error.CrossDevice,
            error.OperationUnsupported,
            error.AccessDenied,
            error.PermissionDenied,
            => {
                var blob = try self.store.openBlob(io, input.digest);
                blob.close(io);
                try self.root.writeFile(io, .{
                    .sub_path = input.path,
                    .data = "",
                    .flags = .{ .read = true, .permissions = .default_file },
                });
                var blob_path_buffer: [cas.blob_prefix_len + 64]u8 = undefined;
                const blob_path = cas.blobSubPath(input.digest, &blob_path_buffer);
                const source = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ cas_root_path, blob_path }, 0);
                errdefer allocator.free(source);
                const target = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ root_path, input.path }, 0);
                errdefer allocator.free(target);
                try bind_mounts.append(allocator, .{
                    .source = source,
                    .target = target,
                });
            },
            else => |e| return e,
        };
    }
};

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

test "Materializer hardlinks immutable non-executable inputs for chroot actions when possible" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    const digest = try store.putBytes(std.testing.io, "large-ish immutable input");

    var work_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const work_root_len = try work_dir.realPath(std.testing.io, &work_root_buffer);
    const materializer = Materializer.init(store, work_dir);
    var materialization = try materializer.materializeInputs(std.testing.io, std.testing.allocator, &.{
        .{ .path = "inputs/data.txt", .digest = digest },
    }, .{
        .chroot_root_path = work_root_buffer[0..work_root_len],
    });
    defer materialization.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), materialization.bind_mounts.len);

    var blob_path_buffer: [cas.blob_prefix_len + 64]u8 = undefined;
    const blob_path = cas.blobSubPath(digest, &blob_path_buffer);
    const cas_stat = try cas_dir.statFile(std.testing.io, blob_path, .{});
    const work_stat = try work_dir.statFile(std.testing.io, "inputs/data.txt", .{});
    try std.testing.expectEqual(cas_stat.inode, work_stat.inode);
    try std.testing.expect(cas_stat.nlink >= 2);
}
