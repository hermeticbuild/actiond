const std = @import("std");

const Options = struct {
    out_file: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    out_count: usize = 16,
    expect_network_blocked: bool = false,
    expect_loopback: bool = false,
    expect_localhost_hosts: bool = false,
    scans: std.ArrayListUnmanaged([]const u8) = .empty,
    extra_out_files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.scans.deinit(allocator);
        self.extra_out_files.deinit(allocator);
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

    if (options.expect_network_blocked) try expectNetworkBlocked();
    if (options.expect_loopback) try expectLoopbackTcp();
    if (options.expect_localhost_hosts) try expectLocalhostHosts(io, allocator);

    const cwd = std.Io.Dir.cwd();
    var hash = std.hash.Wyhash.init(0xaca1_0d5eed);
    for (options.scans.items) |path| try hashPath(io, allocator, cwd, path, &hash);
    const value = hash.final();

    if (options.out_file) |path| try writeSummary(io, allocator, cwd, path, value, options.scans.items.len);
    if (options.out_dir) |path| try writeTree(io, allocator, cwd, path, value, options.out_count);
    for (options.extra_out_files.items, 0..) |path, i| try writeGeneratedFile(io, allocator, cwd, path, value, i);
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
        } else if (std.mem.eql(u8, arg, "--out-extra-file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            try options.extra_out_files.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--scan")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            try options.scans.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--expect-network-blocked")) {
            options.expect_network_blocked = true;
        } else if (std.mem.eql(u8, arg, "--expect-loopback")) {
            options.expect_loopback = true;
        } else if (std.mem.eql(u8, arg, "--expect-localhost-hosts")) {
            options.expect_localhost_hosts = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn expectNetworkBlocked() !void {
    const linux = std.os.linux;
    if (@import("builtin").os.tag != .linux) return;

    const socket_rc = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        linux.IPPROTO.TCP,
    );
    switch (std.posix.errno(socket_rc)) {
        .SUCCESS => {},
        .AFNOSUPPORT, .PROTONOSUPPORT => return,
        else => |err| {
            std.debug.print("network block check could not create socket: {s}\n", .{@tagName(err)});
            return error.NetworkCheckFailed;
        },
    }
    const fd: i32 = @intCast(socket_rc);
    defer _ = linux.close(fd);

    var addr = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, 80),
        .addr = std.mem.nativeToBig(u32, 0x01010101),
    };
    const connect_rc = linux.connect(
        fd,
        @as(*const linux.sockaddr, @ptrCast(&addr)),
        @sizeOf(linux.sockaddr.in),
    );
    switch (std.posix.errno(connect_rc)) {
        .NETUNREACH, .HOSTUNREACH, .NETDOWN, .ADDRNOTAVAIL, .ACCES, .PERM => return,
        .SUCCESS, .INPROGRESS, .ALREADY, .ISCONN => {
            std.debug.print("network block check found a reachable TCP path\n", .{});
            return error.NetworkReachable;
        },
        else => |err| {
            std.debug.print("network block check returned unexpected connect errno: {s}\n", .{@tagName(err)});
            return error.NetworkCheckFailed;
        },
    }
}

fn expectLocalhostHosts(io: std.Io, allocator: std.mem.Allocator) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        "/etc/hosts",
        allocator,
        .limited(64 * 1024),
    ) catch |err| {
        std.debug.print("localhost hosts check could not read /etc/hosts: {s}\n", .{@errorName(err)});
        return error.LocalhostHostsCheckFailed;
    };
    defer allocator.free(bytes);

    var has_ipv4_localhost = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
        const address = fields.next() orelse continue;
        if (!std.mem.eql(u8, address, "127.0.0.1")) continue;
        while (fields.next()) |name| {
            if (std.mem.eql(u8, name, "localhost")) {
                has_ipv4_localhost = true;
                break;
            }
        }
    }

    if (!has_ipv4_localhost) {
        std.debug.print("localhost hosts check did not find '127.0.0.1 localhost' in /etc/hosts\n", .{});
        return error.LocalhostHostsCheckFailed;
    }
}

fn expectLoopbackTcp() !void {
    const linux = std.os.linux;
    if (@import("builtin").os.tag != .linux) return;

    const listener_fd = try tcpSocket();
    defer _ = linux.close(listener_fd);

    var bind_addr = linux.sockaddr.in{
        .port = 0,
        .addr = 0,
    };
    switch (std.posix.errno(linux.bind(
        listener_fd,
        @as(*const linux.sockaddr, @ptrCast(&bind_addr)),
        @sizeOf(linux.sockaddr.in),
    ))) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("loopback check could not bind 0.0.0.0:0: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }
    switch (std.posix.errno(linux.listen(listener_fd, 1))) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("loopback check could not listen: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }

    var bound_addr: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in);
    var bound_addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    switch (std.posix.errno(linux.getsockname(
        listener_fd,
        @as(*linux.sockaddr, @ptrCast(&bound_addr)),
        &bound_addr_len,
    ))) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("loopback check could not read listener address: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }

    const client_fd = try tcpSocket();
    defer _ = linux.close(client_fd);

    var connect_addr = linux.sockaddr.in{
        .port = bound_addr.port,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    switch (std.posix.errno(linux.connect(
        client_fd,
        @as(*const linux.sockaddr, @ptrCast(&connect_addr)),
        @sizeOf(linux.sockaddr.in),
    ))) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("loopback check could not connect to 127.0.0.1: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }

    const accepted_rc = linux.accept(listener_fd, null, null);
    switch (std.posix.errno(accepted_rc)) {
        .SUCCESS => _ = linux.close(@intCast(accepted_rc)),
        else => |err| {
            std.debug.print("loopback check could not accept local connection: {s}\n", .{@tagName(err)});
            return error.LoopbackCheckFailed;
        },
    }
}

fn tcpSocket() !i32 {
    const linux = std.os.linux;
    const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    switch (std.posix.errno(socket_rc)) {
        .SUCCESS => return @intCast(socket_rc),
        else => |err| {
            std.debug.print("network check could not create TCP socket: {s}\n", .{@tagName(err)});
            return error.NetworkCheckFailed;
        },
    }
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
    try writeDefaultFile(io, root, path, bytes);
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
        try writeDefaultFile(io, root, child, data);
    }
}

fn writeGeneratedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    value: u64,
    index: usize,
) !void {
    try createParentDirs(io, root, path);
    const data = try std.fmt.allocPrint(allocator, "path={s}\nindex={d}\nhash={x}\n", .{ path, index, value +% index });
    defer allocator.free(data);
    try writeDefaultFile(io, root, path, data);
}

fn writeDefaultFile(io: std.Io, root: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try root.writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .read = true, .permissions = .default_file },
    });
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

test "parseArgs accepts network block check" {
    var options = try parseArgs(std.testing.allocator, &.{ "--expect-network-blocked", "--expect-loopback", "--expect-localhost-hosts", "--out-extra-file", "out/a.txt" });
    defer options.deinit(std.testing.allocator);
    try std.testing.expect(options.expect_network_blocked);
    try std.testing.expect(options.expect_loopback);
    try std.testing.expect(options.expect_localhost_hosts);
    try std.testing.expectEqual(@as(usize, 1), options.extra_out_files.items.len);
    try std.testing.expectEqualStrings("out/a.txt", options.extra_out_files.items[0]);
}
