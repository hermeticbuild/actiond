const builtin = @import("builtin");
const std = @import("std");
const cas = @import("cas.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    MissingArgv,
};

const max_stream_bytes = 16 * 1024 * 1024;

pub const Status = union(enum) {
    exited: u8,
    signaled: u8,
    stopped,
    unknown,
};

pub const Outcome = struct {
    pub const OutputFile = struct {
        path: []u8,
        digest: cas.Digest,
        is_executable: bool = false,
    };

    pub const OutputDirectory = struct {
        path: []u8,
        root_digest: cas.Digest,
    };

    status: Status,
    stdout: []u8,
    stderr: []u8,
    stdout_digest: ?cas.Digest = null,
    stderr_digest: ?cas.Digest = null,
    output_files: []OutputFile = &.{},
    output_directories: []OutputDirectory = &.{},

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        for (self.output_files) |output_file| allocator.free(output_file.path);
        for (self.output_directories) |output_directory| allocator.free(output_directory.path);
        allocator.free(self.output_files);
        allocator.free(self.output_directories);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn runCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    command: reapi.Command,
    cwd: ?[]const u8,
) !Outcome {
    if (command.arguments.len == 0) return error.MissingArgv;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    for (command.environment_variables) |variable| {
        try env_map.put(variable.name, variable.value);
    }

    const result = std.process.run(allocator, io, .{
        .argv = command.arguments,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = &env_map,
        .stdout_limit = .limited(max_stream_bytes),
        .stderr_limit = .limited(max_stream_bytes),
    }) catch |err| {
        std.log.err("failed to run action command: {s}; cwd={?s}; argv0={s}", .{
            @errorName(err),
            cwd,
            command.arguments[0],
        });
        return err;
    };
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    return .{
        .status = mapStatus(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
        .stdout_digest = try digestIfNonEmpty(io, store, result.stdout),
        .stderr_digest = try digestIfNonEmpty(io, store, result.stderr),
    };
}

fn digestIfNonEmpty(io: std.Io, store: cas.Store, bytes: []const u8) !?cas.Digest {
    if (bytes.len == 0) return null;
    return try store.putBytes(io, bytes);
}

fn mapStatus(term: std.process.Child.Term) Status {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |signal| .{ .signaled = std.math.cast(u8, @intFromEnum(signal)) orelse std.math.maxInt(u8) },
        .stopped => .stopped,
        .unknown => .unknown,
    };
}

test "runCommand captures streams and writes them to CAS" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);

    const store = cas.Store.init(cas_dir);
    var outcome = try runCommand(std.testing.io, std.testing.allocator, store, .{
        .arguments = &.{
            "/bin/sh",
            "-c",
            "printf '%s' \"$ACTIOND_TEST_VALUE\"; printf '%s' warn >&2",
        },
        .environment_variables = &.{
            .{ .name = "ACTIOND_TEST_VALUE", .value = "hello" },
        },
    }, null);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", outcome.stdout);
    try std.testing.expectEqualStrings("warn", outcome.stderr);

    const stdout = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.stdout_digest.?);
    defer std.testing.allocator.free(stdout);
    try std.testing.expectEqualStrings("hello", stdout);

    const stderr = try store.readAlloc(std.testing.io, std.testing.allocator, outcome.stderr_digest.?);
    defer std.testing.allocator.free(stderr);
    try std.testing.expectEqualStrings("warn", stderr);

    switch (outcome.status) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedStatus,
    }
}

test "runCommand honors cwd" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cas_dir = try tmp.dir.createDirPathOpen(std.testing.io, "cas", .{});
    defer cas_dir.close(std.testing.io);
    var work_dir = try tmp.dir.createDirPathOpen(std.testing.io, "work", .{});
    defer work_dir.close(std.testing.io);
    try work_dir.writeFile(std.testing.io, .{
        .sub_path = "marker.txt",
        .data = "present",
    });

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try work_dir.realPath(std.testing.io, &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    const store = cas.Store.init(cas_dir);
    var outcome = try runCommand(std.testing.io, std.testing.allocator, store, .{
        .arguments = &.{ "/bin/sh", "-c", "cat marker.txt" },
    }, cwd);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("present", outcome.stdout);
}
