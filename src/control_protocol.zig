const std = @import("std");

pub const Error = error{
    InvalidCallKind,
    MessageTooLarge,
    UnexpectedEof,
};

const magic = "ACTD";
const version: u8 = 1;
pub const encoded_header_len = 18;
const max_message_bytes = 64 * 1024 * 1024;

pub const CallKind = enum(u8) {
    unary = 0,
    server_streaming = 1,
    client_streaming = 2,
};

pub const Request = struct {
    kind: CallKind,
    method: []const u8,
    body: []const u8,
};

pub const Response = struct {
    status: Status,
    body: []const u8,
};

pub const Status = enum(u8) {
    ok = 0,
    application_error = 1,
};

pub const Header = struct {
    tag: u8,
    method_len: u32,
    body_len: u64,

    pub fn payloadLen(self: Header) !usize {
        if (self.body_len > max_message_bytes) return error.MessageTooLarge;
        return @as(usize, self.method_len) + @as(usize, @intCast(self.body_len));
    }
};

pub fn encodeRequestAlloc(allocator: std.mem.Allocator, request: Request) ![]u8 {
    return encodeAlloc(allocator, @intFromEnum(request.kind), request.method, request.body);
}

pub fn decodeRequest(bytes: []const u8) !Request {
    const decoded = try decode(bytes);
    return .{
        .kind = try decodeEnum(CallKind, decoded.tag),
        .method = decoded.method,
        .body = decoded.body,
    };
}

pub fn encodeResponseAlloc(allocator: std.mem.Allocator, response: Response) ![]u8 {
    return encodeAlloc(allocator, @intFromEnum(response.status), "", response.body);
}

pub fn decodeResponse(bytes: []const u8) !Response {
    const decoded = try decode(bytes);
    return .{
        .status = try decodeEnum(Status, decoded.tag),
        .body = decoded.body,
    };
}

fn decodeEnum(comptime Enum: type, tag: u8) !Enum {
    inline for (@typeInfo(Enum).@"enum".fields) |field| {
        if (field.value == tag) return @enumFromInt(tag);
    }
    return error.InvalidCallKind;
}

fn encodeAlloc(
    allocator: std.mem.Allocator,
    tag: u8,
    method: []const u8,
    body: []const u8,
) ![]u8 {
    if (method.len > std.math.maxInt(u32)) return error.MessageTooLarge;
    if (body.len > max_message_bytes) return error.MessageTooLarge;

    const total_len = encoded_header_len + method.len + body.len;
    var out = try allocator.alloc(u8, total_len);
    @memcpy(out[0..4], magic);
    out[4] = version;
    out[5] = tag;
    std.mem.writeInt(u32, out[6..10], @intCast(method.len), .little);
    std.mem.writeInt(u64, out[10..18], @intCast(body.len), .little);
    @memcpy(out[encoded_header_len..][0..method.len], method);
    @memcpy(out[encoded_header_len + method.len ..][0..body.len], body);
    return out;
}

const Decoded = struct {
    tag: u8,
    method: []const u8,
    body: []const u8,
};

fn decode(bytes: []const u8) !Decoded {
    const header = try decodeHeader(bytes);
    if (header.body_len > max_message_bytes) return error.MessageTooLarge;

    const method_start = encoded_header_len;
    const body_start = method_start + @as(usize, header.method_len);
    const end = body_start + @as(usize, @intCast(header.body_len));
    if (end > bytes.len) return error.UnexpectedEof;

    return .{
        .tag = header.tag,
        .method = bytes[method_start..body_start],
        .body = bytes[body_start..end],
    };
}

pub fn decodeHeader(bytes: []const u8) !Header {
    if (bytes.len < encoded_header_len) return error.UnexpectedEof;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidCallKind;
    if (bytes[4] != version) return error.InvalidCallKind;

    const header: Header = .{
        .tag = bytes[5],
        .method_len = std.mem.readInt(u32, bytes[6..10], .little),
        .body_len = std.mem.readInt(u64, bytes[10..18], .little),
    };
    const body_len = header.body_len;
    if (body_len > max_message_bytes) return error.MessageTooLarge;
    return header;
}

test "control protocol round-trips request envelope" {
    const encoded = try encodeRequestAlloc(std.testing.allocator, .{
        .kind = .server_streaming,
        .method = "/build.bazel.remote.execution.v2.Execution/Execute",
        .body = "grpc-records",
    });
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeRequest(encoded);
    try std.testing.expectEqual(CallKind.server_streaming, decoded.kind);
    try std.testing.expectEqualStrings("/build.bazel.remote.execution.v2.Execution/Execute", decoded.method);
    try std.testing.expectEqualStrings("grpc-records", decoded.body);
}

test "control protocol round-trips response envelope" {
    const encoded = try encodeResponseAlloc(std.testing.allocator, .{
        .status = .ok,
        .body = "response-records",
    });
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeResponse(encoded);
    try std.testing.expectEqual(Status.ok, decoded.status);
    try std.testing.expectEqualStrings("response-records", decoded.body);
}
