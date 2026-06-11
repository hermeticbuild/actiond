const builtin = @import("builtin");
const std = @import("std");

pub const Guid = std.os.windows.GUID;

pub const Socket = usize;
const invalid_socket: Socket = std.math.maxInt(Socket);
const connect_retry_ms: u32 = 100;

const ConnectResult = struct {
    socket_handle: Socket = invalid_socket,
    error_code: i32 = 0,
};

const HcsOperation = *anyopaque;
const HcsSystem = *anyopaque;
const af_hyperv: i32 = 34;
const af_inet: i32 = 2;
const sock_stream: i32 = 1;
const ipproto_tcp: i32 = 6;
const hv_protocol_raw: i32 = 1;
const tcp_nodelay: i32 = 1;
const empty_wide_string = [_:0]u16{};

const SockAddrHv = extern struct {
    family: u16,
    reserved: u16 = 0,
    vm_id: Guid,
    service_id: Guid,
};

const SockAddrIn = extern struct {
    family: u16,
    port: u16,
    address: [4]u8,
    zero: [8]u8 = @splat(0),
};

const WsaData = extern struct {
    version: u16,
    high_version: u16,
    max_sockets: u16,
    max_udp_datagram: u16,
    vendor_info: ?[*:0]u8,
    description: [257]u8,
    system_status: [129]u8,
};

pub const Machine = struct {
    system: HcsSystem,
    vm_id: Guid,
    connect_timeout_ms: u32,

    pub fn start(
        allocator: std.mem.Allocator,
        configuration_utf8: []const u8,
        vm_id_utf8: [36]u8,
        files: []const []const u8,
        start_timeout_ms: u32,
        connect_timeout_ms: u32,
    ) !Machine {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedHost;
        try initializeWinsock();

        const vm_id_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, &vm_id_utf8);
        defer allocator.free(vm_id_w);
        const configuration_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, configuration_utf8);
        defer allocator.free(configuration_w);

        for (files) |path| {
            const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(path_w);
            try checkHresult(HcsGrantVmAccess(vm_id_w.ptr, path_w.ptr));
        }

        const create_operation = HcsCreateOperation(null, null) orelse return error.StartFailed;
        defer HcsCloseOperation(create_operation);

        var system: ?HcsSystem = null;
        try checkHresult(HcsCreateComputeSystem(
            vm_id_w.ptr,
            configuration_w.ptr,
            create_operation,
            null,
            &system,
        ));
        errdefer if (system) |created_system| HcsCloseComputeSystem(created_system);
        try waitOperation(create_operation, start_timeout_ms);
        const created_system = system orelse return error.StartFailed;

        const properties_operation = HcsCreateOperation(null, null) orelse return error.StartFailed;
        defer HcsCloseOperation(properties_operation);
        const properties_query = std.unicode.utf8ToUtf16LeStringLiteral("{}");
        try checkHresult(HcsGetComputeSystemProperties(created_system, properties_operation, properties_query));
        const properties = try waitOperationDocument(allocator, properties_operation, start_timeout_ms);
        defer allocator.free(properties);
        const runtime_id = try runtimeIdFromProperties(allocator, properties);

        const start_operation = HcsCreateOperation(null, null) orelse return error.StartFailed;
        defer HcsCloseOperation(start_operation);
        try checkHresult(HcsStartComputeSystem(created_system, start_operation, &empty_wide_string));
        try waitOperation(start_operation, start_timeout_ms);

        return .{
            .system = created_system,
            .vm_id = runtime_id,
            .connect_timeout_ms = connect_timeout_ms,
        };
    }

    pub fn deinit(self: *Machine) void {
        if (comptime builtin.os.tag != .windows) return;
        const operation = HcsCreateOperation(null, null);
        if (operation) |terminate_operation| {
            _ = HcsTerminateComputeSystem(self.system, terminate_operation, &empty_wide_string);
            _ = waitOperation(terminate_operation, 30_000) catch {};
            HcsCloseOperation(terminate_operation);
        }
        HcsCloseComputeSystem(self.system);
        self.* = undefined;
    }

    pub fn connectPort(self: *Machine, io: std.Io, port: u32) !Socket {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedHost;

        var remaining_ms = if (self.connect_timeout_ms == 0) connect_retry_ms else self.connect_timeout_ms;
        while (true) {
            const result = connectOnce(self.vm_id, port);
            if (result.socket_handle != invalid_socket) return result.socket_handle;

            const retry_ms = @min(connect_retry_ms, remaining_ms);
            if (remaining_ms <= retry_ms) {
                std.log.err("AF_HYPERV connect timed out port={d} WSAGetLastError={d}", .{ port, result.error_code });
                return error.ConnectTimedOut;
            }
            try io.sleep(.fromMilliseconds(retry_ms), .awake);
            remaining_ms -= retry_ms;
        }
    }
};

pub fn closeSocket(socket_handle: Socket) void {
    if (comptime builtin.os.tag != .windows) return;
    _ = closesocket(socket_handle);
}

pub fn listenTcp(address: std.Io.net.Ip4Address) !Socket {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedHost;
    const socket_handle = socket(af_inet, sock_stream, ipproto_tcp);
    if (socket_handle == invalid_socket) return error.SocketFailed;
    errdefer closeSocket(socket_handle);

    const socket_address: SockAddrIn = .{
        .family = af_inet,
        .port = @byteSwap(address.port),
        .address = address.bytes,
    };
    if (bind(socket_handle, @ptrCast(&socket_address), @sizeOf(SockAddrIn)) != 0) return error.BindFailed;
    if (listen(socket_handle, 128) != 0) return error.ListenFailed;
    return socket_handle;
}

pub fn acceptSocket(listener: Socket) !Socket {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedHost;
    const socket_handle = accept(listener, null, null);
    if (socket_handle == invalid_socket) return error.AcceptFailed;
    return socket_handle;
}

pub fn shutdownSend(socket_handle: Socket) void {
    if (comptime builtin.os.tag != .windows) return;
    _ = shutdown(socket_handle, 1);
}

pub fn shutdownBoth(socket_handle: Socket) void {
    if (comptime builtin.os.tag != .windows) return;
    _ = shutdown(socket_handle, 2);
}

pub fn recvBytes(socket_handle: Socket, buffer: []u8) !usize {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedHost;
    const length: i32 = @intCast(@min(buffer.len, std.math.maxInt(i32)));
    const result = recv(socket_handle, buffer.ptr, length, 0);
    if (result < 0) {
        std.log.info("socket recv failed WSAGetLastError={d}", .{WSAGetLastError()});
        return error.ReceiveFailed;
    }
    return @intCast(result);
}

pub fn sendAll(socket_handle: Socket, bytes: []const u8) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedHost;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const length: i32 = @intCast(@min(bytes.len - offset, std.math.maxInt(i32)));
        const result = send(socket_handle, bytes[offset..].ptr, length, 0);
        if (result < 0) {
            std.log.info("socket send failed WSAGetLastError={d}", .{WSAGetLastError()});
            return error.SendFailed;
        }
        if (result == 0) return error.SendFailed;
        offset += @intCast(result);
    }
}

pub fn setTcpNoDelay(socket_handle: Socket) void {
    if (comptime builtin.os.tag != .windows) return;
    const enabled: i32 = 1;
    if (setsockopt(socket_handle, ipproto_tcp, tcp_nodelay, @ptrCast(&enabled), @sizeOf(i32)) != 0) {
        std.log.err("TCP_NODELAY failed WSAGetLastError={d}", .{WSAGetLastError()});
    }
}

pub fn randomGuid(io: std.Io) !Guid {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return .{
        .Data1 = std.mem.readInt(u32, bytes[0..4], .big),
        .Data2 = std.mem.readInt(u16, bytes[4..6], .big),
        .Data3 = std.mem.readInt(u16, bytes[6..8], .big),
        .Data4 = bytes[8..16].*,
    };
}

pub fn formatGuid(guid: Guid) [36]u8 {
    var output: [38]u8 = undefined;
    _ = std.fmt.bufPrint(&output, "{f}", .{guid}) catch unreachable;
    return output[1..37].*;
}

pub fn serviceGuid(port: u32) Guid {
    return .{
        .Data1 = port,
        .Data2 = 0xfacb,
        .Data3 = 0x11e6,
        .Data4 = .{ 0xbd, 0x58, 0x64, 0x00, 0x6a, 0x79, 0x86, 0xd3 },
    };
}

fn connectOnce(vm_id: Guid, port: u32) ConnectResult {
    const socket_handle = socket(af_hyperv, sock_stream, hv_protocol_raw);
    if (socket_handle == invalid_socket) return .{ .error_code = WSAGetLastError() };

    var address: SockAddrHv = .{
        .family = af_hyperv,
        .vm_id = vm_id,
        .service_id = serviceGuid(port),
    };
    if (bind(socket_handle, @ptrCast(&address), @sizeOf(SockAddrHv)) != 0) {
        const error_code = WSAGetLastError();
        closeSocket(socket_handle);
        return .{ .error_code = error_code };
    }
    if (connect(socket_handle, @ptrCast(&address), @sizeOf(SockAddrHv)) != 0) {
        const error_code = WSAGetLastError();
        closeSocket(socket_handle);
        return .{ .error_code = error_code };
    }
    return .{ .socket_handle = socket_handle };
}

fn initializeWinsock() !void {
    var data: WsaData = undefined;
    if (WSAStartup(0x0202, &data) != 0) return error.WinsockInitializationFailed;
}

fn waitOperation(operation: HcsOperation, timeout_ms: u32) !void {
    var result_document: ?[*:0]u16 = null;
    const result = HcsWaitForOperationResult(operation, timeout_ms, &result_document);
    defer if (result_document) |document| CoTaskMemFree(document);
    if (result < 0) {
        if (result_document) |document| {
            std.log.err("HCS operation failed: {f}", .{std.unicode.fmtUtf16Le(std.mem.span(document))});
        }
        return error.HcsOperationFailed;
    }
}

fn waitOperationDocument(allocator: std.mem.Allocator, operation: HcsOperation, timeout_ms: u32) ![]u8 {
    var result_document: ?[*:0]u16 = null;
    const result = HcsWaitForOperationResult(operation, timeout_ms, &result_document);
    defer if (result_document) |document| CoTaskMemFree(document);
    if (result < 0) return error.HcsOperationFailed;
    const document = result_document orelse return error.HcsOperationFailed;
    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(document));
}

fn runtimeIdFromProperties(allocator: std.mem.Allocator, properties: []const u8) !Guid {
    const Properties = struct { RuntimeId: []const u8 };
    const parsed = try std.json.parseFromSlice(Properties, allocator, properties, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return parseGuid(parsed.value.RuntimeId);
}

fn parseGuid(value: []const u8) !Guid {
    const text = std.mem.trim(u8, value, "{}");
    if (text.len != 36 or text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-') {
        return error.HcsOperationFailed;
    }
    return Guid.parseNoBraces(text) catch error.HcsOperationFailed;
}

fn checkHresult(result: i32) !void {
    if (result < 0) return error.HcsOperationFailed;
}

extern "computecore" fn HcsCreateOperation(context: ?*const anyopaque, callback: ?*const anyopaque) callconv(.winapi) ?HcsOperation;
extern "computecore" fn HcsCloseOperation(operation: HcsOperation) callconv(.winapi) void;
extern "computecore" fn HcsWaitForOperationResult(operation: HcsOperation, timeout_ms: u32, result_document: *?[*:0]u16) callconv(.winapi) i32;
extern "computecore" fn HcsCreateComputeSystem(id: [*:0]const u16, configuration: [*:0]const u16, operation: HcsOperation, security_descriptor: ?*const anyopaque, system: *?HcsSystem) callconv(.winapi) i32;
extern "computecore" fn HcsCloseComputeSystem(system: HcsSystem) callconv(.winapi) void;
extern "computecore" fn HcsGetComputeSystemProperties(system: HcsSystem, operation: HcsOperation, property_query: [*:0]const u16) callconv(.winapi) i32;
extern "computecore" fn HcsStartComputeSystem(system: HcsSystem, operation: HcsOperation, options: [*:0]const u16) callconv(.winapi) i32;
extern "computecore" fn HcsTerminateComputeSystem(system: HcsSystem, operation: HcsOperation, options: [*:0]const u16) callconv(.winapi) i32;
extern "computecore" fn HcsGrantVmAccess(vm_id: [*:0]const u16, file_path: [*:0]const u16) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(memory: ?*const anyopaque) callconv(.winapi) void;
extern "ws2_32" fn WSAStartup(version: u16, data: *WsaData) callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
extern "ws2_32" fn socket(address_family: i32, socket_type: i32, protocol: i32) callconv(.winapi) Socket;
extern "ws2_32" fn bind(socket_handle: Socket, address: *const anyopaque, address_length: i32) callconv(.winapi) i32;
extern "ws2_32" fn connect(socket_handle: Socket, address: *const anyopaque, address_length: i32) callconv(.winapi) i32;
extern "ws2_32" fn listen(socket_handle: Socket, backlog: i32) callconv(.winapi) i32;
extern "ws2_32" fn accept(socket_handle: Socket, address: ?*anyopaque, address_length: ?*i32) callconv(.winapi) Socket;
extern "ws2_32" fn closesocket(socket_handle: Socket) callconv(.winapi) i32;
extern "ws2_32" fn shutdown(socket_handle: Socket, how: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(socket_handle: Socket, buffer: [*]u8, length: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(socket_handle: Socket, buffer: [*]const u8, length: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(socket_handle: Socket, level: i32, option_name: i32, option_value: *const anyopaque, option_length: i32) callconv(.winapi) i32;

test "formatGuid formats HCS identifiers" {
    const guid: Guid = .{
        .Data1 = 0x12345678,
        .Data2 = 0x9abc,
        .Data3 = 0x4def,
        .Data4 = .{ 0x80, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde },
    };
    try std.testing.expectEqualStrings("12345678-9abc-4def-8012-3456789abcde", &formatGuid(guid));
}

test "serviceGuid maps AF_VSOCK ports" {
    const guid = serviceGuid(5001);
    try std.testing.expectEqualStrings("00001389-facb-11e6-bd58-64006a7986d3", &formatGuid(guid));
}

test "parseGuid parses HCS runtime identifiers" {
    const guid = try parseGuid("12345678-9abc-4def-8012-3456789abcde");
    try std.testing.expectEqualStrings("12345678-9abc-4def-8012-3456789abcde", &formatGuid(guid));
}
