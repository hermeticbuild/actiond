const std = @import("std");
const cas = @import("cas.zig");
const protobuf = @import("protobuf_wire.zig");

pub const Error = error{
    InvalidResourceName,
    InvalidSize,
};

pub const BlobResource = struct {
    instance_name: []const u8 = "",
    upload_uuid: ?[]const u8 = null,
    digest: cas.Digest,
};

const Segment = struct {
    start: usize,
    end: usize,
};

pub fn parseBlobResource(allocator: std.mem.Allocator, resource_name: []const u8) !BlobResource {
    var segments: std.ArrayListUnmanaged(Segment) = .empty;
    defer segments.deinit(allocator);

    var start: usize = 0;
    while (start <= resource_name.len) {
        const end = std.mem.indexOfScalarPos(u8, resource_name, start, '/') orelse resource_name.len;
        if (end == start) return error.InvalidResourceName;
        try segments.append(allocator, .{ .start = start, .end = end });
        if (end == resource_name.len) break;
        start = end + 1;
    }

    var blobs_index: ?usize = null;
    for (segments.items, 0..) |segment, i| {
        if (std.mem.eql(u8, slice(resource_name, segment), "blobs")) {
            blobs_index = i;
            break;
        }
    }
    const i = blobs_index orelse return error.InvalidResourceName;
    if (i + 2 >= segments.items.len) return error.InvalidResourceName;
    if (i + 3 != segments.items.len) return error.InvalidResourceName;

    const hash = slice(resource_name, segments.items[i + 1]);
    const size_text = slice(resource_name, segments.items[i + 2]);
    const size = std.fmt.parseInt(u64, size_text, 10) catch return error.InvalidSize;

    var instance_name: []const u8 = "";
    var upload_uuid: ?[]const u8 = null;
    if (i >= 2 and std.mem.eql(u8, slice(resource_name, segments.items[i - 2]), "uploads")) {
        upload_uuid = slice(resource_name, segments.items[i - 1]);
        if (i > 2) instance_name = resource_name[0 .. segments.items[i - 2].start - 1];
    } else if (i > 0) {
        instance_name = resource_name[0 .. segments.items[i].start - 1];
    }

    return .{
        .instance_name = instance_name,
        .upload_uuid = upload_uuid,
        .digest = .{
            .hash = try cas.parseHexHash(hash),
            .size_bytes = size,
        },
    };
}

fn slice(bytes: []const u8, segment: Segment) []const u8 {
    return bytes[segment.start..segment.end];
}

pub const ReadRequest = struct {
    resource_name: []const u8 = "",
    read_offset: i64 = 0,
    read_limit: i64 = 0,

    pub fn encode(self: ReadRequest, writer: *protobuf.Writer) !void {
        if (self.resource_name.len != 0) try writer.writeStringField(1, self.resource_name);
        if (self.read_offset != 0) try writer.writeInt64Field(2, self.read_offset);
        if (self.read_limit != 0) try writer.writeInt64Field(3, self.read_limit);
    }

    pub fn decode(reader: *protobuf.Reader) !ReadRequest {
        var out: ReadRequest = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.resource_name = try reader.readString(),
                2 => out.read_offset = try reader.readInt64(),
                3 => out.read_limit = try reader.readInt64(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const ReadResponse = struct {
    data: []const u8 = "",

    pub fn encode(self: ReadResponse, writer: *protobuf.Writer) !void {
        if (self.data.len != 0) try writer.writeBytesField(10, self.data);
    }

    pub fn decode(reader: *protobuf.Reader) !ReadResponse {
        var out: ReadResponse = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                10 => out.data = try reader.readBytes(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const WriteRequest = struct {
    resource_name: []const u8 = "",
    write_offset: i64 = 0,
    finish_write: bool = false,
    data: []const u8 = "",

    pub fn encode(self: WriteRequest, writer: *protobuf.Writer) !void {
        if (self.resource_name.len != 0) try writer.writeStringField(1, self.resource_name);
        if (self.write_offset != 0) try writer.writeInt64Field(2, self.write_offset);
        if (self.finish_write) try writer.writeBoolField(3, true);
        if (self.data.len != 0) try writer.writeBytesField(10, self.data);
    }

    pub fn decode(reader: *protobuf.Reader) !WriteRequest {
        var out: WriteRequest = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.resource_name = try reader.readString(),
                2 => out.write_offset = try reader.readInt64(),
                3 => out.finish_write = try reader.readBool(),
                10 => out.data = try reader.readBytes(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const WriteResponse = struct {
    committed_size: i64 = 0,

    pub fn encode(self: WriteResponse, writer: *protobuf.Writer) !void {
        if (self.committed_size != 0) try writer.writeInt64Field(1, self.committed_size);
    }

    pub fn decode(reader: *protobuf.Reader) !WriteResponse {
        var out: WriteResponse = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.committed_size = try reader.readInt64(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

test "parseBlobResource accepts upload and non-upload resource names" {
    const digest = cas.Digest.fromBytes("hello");
    var hash: [64]u8 = undefined;
    _ = digest.formatHex(&hash);

    const plain_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "instance/blobs/{s}/{d}",
        .{ &hash, digest.size_bytes },
    );
    defer std.testing.allocator.free(plain_name);
    const plain = try parseBlobResource(std.testing.allocator, plain_name);
    try std.testing.expectEqualStrings("instance", plain.instance_name);
    try std.testing.expectEqual(@as(?[]const u8, null), plain.upload_uuid);
    try std.testing.expect(digest.eql(plain.digest));

    const upload_name = try std.fmt.allocPrint(
        std.testing.allocator,
        "instance/uploads/uuid-1/blobs/{s}/{d}",
        .{ &hash, digest.size_bytes },
    );
    defer std.testing.allocator.free(upload_name);
    const upload = try parseBlobResource(std.testing.allocator, upload_name);
    try std.testing.expectEqualStrings("instance", upload.instance_name);
    try std.testing.expectEqualStrings("uuid-1", upload.upload_uuid.?);
    try std.testing.expect(digest.eql(upload.digest));
}

test "ByteStream messages round-trip borrowed protobuf views" {
    const write_request: WriteRequest = .{
        .resource_name = "uploads/u/blobs/hash/4",
        .write_offset = 1,
        .finish_write = true,
        .data = "data",
    };

    const encoded = try @import("reapi.zig").encodeAlloc(std.testing.allocator, write_request);
    defer std.testing.allocator.free(encoded);

    var reader = protobuf.Reader.init(encoded);
    const decoded = try WriteRequest.decode(&reader);
    try std.testing.expectEqualStrings(write_request.resource_name, decoded.resource_name);
    try std.testing.expectEqual(write_request.write_offset, decoded.write_offset);
    try std.testing.expect(decoded.finish_write);
    try std.testing.expectEqualStrings(write_request.data, decoded.data);

    const response_encoded = try @import("reapi.zig").encodeAlloc(
        std.testing.allocator,
        WriteResponse{ .committed_size = 4 },
    );
    defer std.testing.allocator.free(response_encoded);
    var response_reader = protobuf.Reader.init(response_encoded);
    const response = try WriteResponse.decode(&response_reader);
    try std.testing.expectEqual(@as(i64, 4), response.committed_size);
}
