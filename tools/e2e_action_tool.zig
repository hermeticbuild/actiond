const std = @import("std");

const Options = struct {
    out_file: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    out_count: usize = 16,
    scans: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.scans.deinit(allocator);
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

    const cwd = std.Io.Dir.cwd();
    var hash = std.hash.Wyhash.init(0xaca1_0d5eed);
    for (options.scans.items) |path| try hashPath(io, allocator, cwd, path, &hash);
    const value = hash.final();

    if (options.out_file) |path| try writeSummary(io, allocator, cwd, path, value, options.scans.items.len);
    if (options.out_dir) |path| try writeTree(io, allocator, cwd, path, value, options.out_count);
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
        } else if (std.mem.eql(u8, arg, "--scan")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            try options.scans.append(allocator, args[i]);
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
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
    try root.writeFile(io, .{
        .sub_path = path,
        .data = bytes,
    });
}

fn writeTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    value: u64,
    count: usize,
) !void {
    try root.createDirPath(io, path);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const child = try std.fmt.allocPrint(allocator, "{s}/generated-{d}.txt", .{ path, i });
        defer allocator.free(child);
        const data = try std.fmt.allocPrint(allocator, "index={d}\nhash={x}\n", .{ i, value +% i });
        defer allocator.free(data);
        try root.writeFile(io, .{
            .sub_path = child,
            .data = data,
        });
    }
}

fn createParentDirs(io: std.Io, root: std.Io.Dir, path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    try root.createDirPath(io, path[0..slash]);
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
