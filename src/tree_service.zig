const std = @import("std");
const cas = @import("cas.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    MissingRootDigest,
};

pub const Result = struct {
    response: reapi.GetTreeResponse,
    directory_bytes: []const []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.response.deinit(allocator);
        for (self.directory_bytes) |bytes| allocator.free(bytes);
        allocator.free(self.directory_bytes);
        self.* = undefined;
    }
};

pub fn getTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request: reapi.GetTreeRequest,
) !Result {
    const root_digest = try cas.Digest.fromReapi(request.root_digest orelse return error.MissingRootDigest);

    var directories: std.ArrayListUnmanaged(reapi.Directory) = .empty;
    errdefer {
        for (directories.items) |*directory| directory.deinit(allocator);
        directories.deinit(allocator);
    }
    var directory_bytes: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (directory_bytes.items) |bytes| allocator.free(bytes);
        directory_bytes.deinit(allocator);
    }

    try appendDirectory(io, allocator, store, root_digest, &directories, &directory_bytes);

    const directory_slice = try directories.toOwnedSlice(allocator);
    errdefer {
        for (directory_slice) |*directory| directory.deinit(allocator);
        allocator.free(directory_slice);
    }
    const bytes_slice = try directory_bytes.toOwnedSlice(allocator);
    errdefer {
        for (bytes_slice) |bytes| allocator.free(bytes);
        allocator.free(bytes_slice);
    }

    return .{
        .response = .{ .directories = directory_slice },
        .directory_bytes = bytes_slice,
    };
}

fn appendDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    digest: cas.Digest,
    directories: *std.ArrayListUnmanaged(reapi.Directory),
    directory_bytes: *std.ArrayListUnmanaged([]u8),
) !void {
    const bytes = try store.readAlloc(io, allocator, digest);
    errdefer allocator.free(bytes);
    var reader = protobuf.Reader.init(bytes);
    var directory = try reapi.Directory.decodeOwned(allocator, &reader);
    var directory_owned = true;
    errdefer if (directory_owned) directory.deinit(allocator);

    try directory_bytes.append(allocator, bytes);
    try directories.append(allocator, directory);
    directory_owned = false;

    for (directory.directories) |child| {
        const child_digest = try cas.Digest.fromReapi(child.digest orelse return error.MissingRootDigest);
        try appendDirectory(io, allocator, store, child_digest, directories, directory_bytes);
    }
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

test "getTree returns root and child directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = cas.Store.init(tmp.dir);
    const child_file_digest = try store.putBytes(std.testing.io, "child");
    var child_file_hash: [64]u8 = undefined;
    const child_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .files = &.{
            .{ .name = "child.txt", .digest = child_file_digest.toReapi(&child_file_hash) },
        },
    });

    var child_hash: [64]u8 = undefined;
    const root_digest = try putProto(std.testing.io, std.testing.allocator, store, reapi.Directory{
        .directories = &.{
            .{ .name = "sub", .digest = child_digest.toReapi(&child_hash) },
        },
    });

    var root_hash: [64]u8 = undefined;
    var result = try getTree(std.testing.io, std.testing.allocator, store, .{
        .root_digest = root_digest.toReapi(&root_hash),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.response.directories.len);
    try std.testing.expectEqualStrings("sub", result.response.directories[0].directories[0].name);
    try std.testing.expectEqualStrings("child.txt", result.response.directories[1].files[0].name);
}
