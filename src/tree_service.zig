const std = @import("std");
const body_sink = @import("body_sink.zig");
const cas = @import("cas.zig");
const grpc_record = @import("grpc_record.zig");
const protobuf = @import("protobuf_wire.zig");
const reapi = @import("reapi.zig");

pub const Error = error{
    MissingRootDigest,
};

pub fn writeGetTreeGrpcRecords(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    request: reapi.GetTreeRequest,
    writer: body_sink.Writer,
) !void {
    const root_digest = try cas.Digest.fromReapi(request.root_digest orelse return error.MissingRootDigest);
    try writeDirectoryTree(io, allocator, store, root_digest, writer);
}

fn writeDirectoryTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: cas.Store,
    digest: cas.Digest,
    writer: body_sink.Writer,
) !void {
    const bytes = try store.readAlloc(io, allocator, digest);
    defer allocator.free(bytes);

    var reader = protobuf.Reader.init(bytes);
    var directory = try reapi.Directory.decodeOwned(allocator, &reader);
    defer directory.deinit(allocator);

    try writeGetTreeResponseRecord(io, allocator, writer, directory);

    for (directory.directories) |child| {
        const child_digest = try cas.Digest.fromReapi(child.digest orelse return error.MissingRootDigest);
        try writeDirectoryTree(io, allocator, store, child_digest, writer);
    }
}

fn writeGetTreeResponseRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: body_sink.Writer,
    directory: reapi.Directory,
) !void {
    const response = reapi.GetTreeResponse{
        .directories = &.{directory},
    };
    const payload = try reapi.encodeAlloc(allocator, response);
    defer allocator.free(payload);
    const record = try grpc_record.encodeAlloc(allocator, .{ .payload = payload });
    defer allocator.free(record);
    try writer.writeAll(io, allocator, record);
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

test "writeGetTreeGrpcRecords streams one response per directory" {
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

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var list_writer = body_sink.ArrayListWriter{ .out = &out };
    var root_hash: [64]u8 = undefined;
    try writeGetTreeGrpcRecords(std.testing.io, std.testing.allocator, store, .{
        .root_digest = root_digest.toReapi(&root_hash),
    }, list_writer.writer());

    var it = grpc_record.Iterator.init(out.items);
    const root_record = (try it.next()).?;
    var root_reader = protobuf.Reader.init(root_record.payload);
    var root_response = try reapi.GetTreeResponse.decodeOwned(std.testing.allocator, &root_reader);
    defer root_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), root_response.directories.len);
    try std.testing.expectEqualStrings("sub", root_response.directories[0].directories[0].name);

    const child_record = (try it.next()).?;
    var child_reader = protobuf.Reader.init(child_record.payload);
    var child_response = try reapi.GetTreeResponse.decodeOwned(std.testing.allocator, &child_reader);
    defer child_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), child_response.directories.len);
    try std.testing.expectEqualStrings("child.txt", child_response.directories[0].files[0].name);

    try std.testing.expectEqual(@as(?grpc_record.Message, null), try it.next());
}
