const builtin = @import("builtin");
const std = @import("std");
const action_cache = @import("action_cache.zig");
const action_executor = @import("action_executor.zig");
const cas = @import("cas.zig");
const embedded_payload = @import("embedded_payload.zig");
const grpc_http2_server = @import("grpc_http2_server.zig");
const reapi_dispatch = @import("reapi_dispatch.zig");
const runtime_mount = @import("runtime_mount.zig");

pub const Error = error{
    UnknownServeArgument,
    MissingServeArgumentValue,
    UnsupportedHost,
};

pub const ServeOptions = struct {
    listen: []const u8 = "127.0.0.1:8980",
    root: []const u8 = "/tmp/actiond",
    runtime_image: ?[]const u8 = null,
    runtime_root: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, arg, "--runtime-image")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.runtime_image = args[i];
        } else if (std.mem.startsWith(u8, arg, "--runtime-image=")) {
            options.runtime_image = arg["--runtime-image=".len..];
        } else if (std.mem.eql(u8, arg, "--runtime-root")) {
            i += 1;
            if (i >= args.len) return error.MissingServeArgumentValue;
            options.runtime_root = args[i];
        } else if (std.mem.startsWith(u8, arg, "--runtime-root=")) {
            options.runtime_root = arg["--runtime-root=".len..];
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
    if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

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

    const embedded_runtime_image = if (comptime builtin.os.tag == .linux)
        if (options.runtime_image == null and options.runtime_root == null)
            try embedded_payload.extractFromSelf(io, allocator, root_dir, embedded_payload.runtimes_name)
        else
            null
    else
        null;
    defer if (embedded_runtime_image) |path| allocator.free(path);

    var mounted_runtime = try runtime_mount.prepare(
        io,
        allocator,
        root_dir,
        options.runtime_image orelse embedded_runtime_image,
        options.runtime_root,
    );
    defer mounted_runtime.deinit(allocator);

    var execution_options = try action_executor.prepareExecuteOptions(io, allocator, cas.Store.initReady(cas_dir), .{
        .runtime_root_path = mounted_runtime.path(),
    });
    defer execution_options.deinit(allocator);

    const server: reapi_dispatch.Server = .{
        .store = cas.Store.initReady(cas_dir),
        .action_cache_store = action_cache.Store.initReady(ac_dir),
        .work_root = work_dir,
        .execution_options = execution_options.options,
    };

    return grpc_http2_server.serve(io, allocator, .{
        .listen = options.listen,
    }, server);
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

test "parseServeArgs accepts runtime image and runtime root flags" {
    const image_options = try parseServeArgs(&.{
        "--runtime-image",
        "/tmp/runtimes.sqfs",
    });
    try std.testing.expectEqualStrings("/tmp/runtimes.sqfs", image_options.runtime_image.?);
    try std.testing.expectEqual(@as(?[]const u8, null), image_options.runtime_root);

    const root_options = try parseServeArgs(&.{
        "--runtime-root=/mnt/actiond-runtimes",
    });
    try std.testing.expectEqualStrings("/mnt/actiond-runtimes", root_options.runtime_root.?);
    try std.testing.expectEqual(@as(?[]const u8, null), root_options.runtime_image);
}

test "parseServeArgs rejects unknown flags" {
    try std.testing.expectError(error.UnknownServeArgument, parseServeArgs(&.{"--bad"}));
    try std.testing.expectError(error.MissingServeArgumentValue, parseServeArgs(&.{"--root"}));
    try std.testing.expectError(error.MissingServeArgumentValue, parseServeArgs(&.{"--runtime-image"}));
    try std.testing.expectError(error.MissingServeArgumentValue, parseServeArgs(&.{"--runtime-root"}));
}
