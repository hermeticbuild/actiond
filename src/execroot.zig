const std = @import("std");
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
        _ = allocator;
        for (inputs) |input| {
            try validatePath(input.path);
            try createParentDirs(self.root, io, input.path);

            try self.store.copyToFile(
                io,
                input.digest,
                self.root,
                input.path,
                if (input.is_executable) .executable_file else .default_file,
            );
        }
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
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    try root.createDirPath(io, path[0..last_slash]);
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

    const restored_tool = try work_dir.readFileAlloc(
        std.testing.io,
        "tools/run.sh",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(restored_tool);
    try std.testing.expectEqualStrings("#!/bin/sh\n", restored_tool);
}
