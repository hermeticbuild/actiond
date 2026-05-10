const builtin = @import("builtin");
const std = @import("std");
const action_cache = @import("action_cache.zig");
const action_executor = @import("action_executor.zig");
const cas = @import("cas.zig");
const grpc_http2_server = @import("grpc_http2_server.zig");
const reapi_dispatch = @import("reapi_dispatch.zig");

pub const Error = error{
    UnknownServeArgument,
    MissingServeArgumentValue,
};

pub const ServeOptions = struct {
    listen: []const u8 = "127.0.0.1:8980",
    root: []const u8 = "/tmp/actiond",
};

pub fn parseServeArgs(args: []const []const u8) !ServeOptions {
    var options: ServeOptions = .{};
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--listen")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.listen = args[i];
        } else if (std.mem.startsWith(u8, arg, "--listen=")) {
            options.listen = arg["--listen=".len..];
        } else if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.root = args[i];
        } else if (std.mem.startsWith(u8, arg, "--root=")) {
            options.root = arg["--root=".len..];
        } else {
            return error.UnknownServeArgument;
        }
        i += 1;
    }
    return options;
}

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: ServeOptions,
) !void {
    var root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.root, .{});
    defer root_dir.close(io);

    var cas_dir = try root_dir.createDirPathOpen(io, "cas", .{});
    defer cas_dir.close(io);
    var ac_dir = try root_dir.createDirPathOpen(io, "ac", .{});
    defer ac_dir.close(io);
    var work_dir = try root_dir.createDirPathOpen(io, "work", .{});
    defer work_dir.close(io);

    try cas.Store.init(cas_dir).ensureLayout(io);
    try action_cache.Store.init(ac_dir).ensureLayout(io);

    const server: reapi_dispatch.Server = .{
        .store = cas.Store.initReady(cas_dir),
        .action_cache_store = action_cache.Store.initReady(ac_dir),
        .work_root = work_dir,
        .execution_options = defaultExecutionOptions(),
    };

    return grpc_http2_server.serve(io, allocator, .{
        .listen = options.listen,
    }, server);
}

fn defaultExecutionOptions() action_executor.ExecuteOptions {
    return if (builtin.os.tag == .linux)
        .{ .isolation = .chroot }
    else
        .{};
}

test "parseServeArgs accepts split and equals flags" {
    const options = try parseServeArgs(&.{
        "--listen",
        "127.0.0.1:9999",
        "--root=/tmp/actiond-test",
    });

    try std.testing.expectEqualStrings("127.0.0.1:9999", options.listen);
    try std.testing.expectEqualStrings("/tmp/actiond-test", options.root);
}

test "parseServeArgs rejects unknown flags" {
    try std.testing.expectError(error.UnknownServeArgument, parseServeArgs(&.{"--bad"}));
    try std.testing.expectError(error.MissingServeArgumentValue, parseServeArgs(&.{"--root"}));
}
