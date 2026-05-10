const std = @import("std");
const protobuf = @import("protobuf_wire.zig");

pub const Digest = struct {
    hash: []const u8 = "",
    size_bytes: i64 = 0,

    pub fn encode(self: Digest, writer: *protobuf.Writer) !void {
        if (self.hash.len != 0) try writer.writeStringField(1, self.hash);
        if (self.size_bytes != 0) try writer.writeInt64Field(2, self.size_bytes);
    }

    pub fn encodedLen(self: Digest) usize {
        var len: usize = 0;
        if (self.hash.len != 0) len += protobuf.stringFieldLen(1, self.hash.len);
        if (self.size_bytes != 0) len += protobuf.int64FieldLen(2, self.size_bytes);
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !Digest {
        var out: Digest = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.hash = try reader.readString(),
                2 => out.size_bytes = try reader.readInt64(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }

    pub fn eql(lhs: Digest, rhs: Digest) bool {
        return lhs.size_bytes == rhs.size_bytes and std.mem.eql(u8, lhs.hash, rhs.hash);
    }
};

pub const StatusCode = enum(i32) {
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,
};

pub const Status = struct {
    code: StatusCode = .ok,
    message: []const u8 = "",

    pub fn encode(self: Status, writer: *protobuf.Writer) !void {
        if (self.code != .ok) try writer.writeInt32Field(1, @intFromEnum(self.code));
        if (self.message.len != 0) try writer.writeStringField(2, self.message);
    }

    pub fn encodedLen(self: Status) usize {
        var len: usize = 0;
        if (self.code != .ok) len += protobuf.int32FieldLen(1, @intFromEnum(self.code));
        if (self.message.len != 0) len += protobuf.stringFieldLen(2, self.message.len);
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !Status {
        var out: Status = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.code = @enumFromInt(try reader.readInt32()),
                2 => out.message = try reader.readString(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const DigestFunction = enum(u32) {
    unknown = 0,
    sha256 = 1,
};

pub const SemVer = struct {
    major: i32 = 0,
    minor: i32 = 0,
    patch: i32 = 0,

    pub fn encode(self: SemVer, writer: *protobuf.Writer) !void {
        if (self.major != 0) try writer.writeInt32Field(1, self.major);
        if (self.minor != 0) try writer.writeInt32Field(2, self.minor);
        if (self.patch != 0) try writer.writeInt32Field(3, self.patch);
    }

    pub fn encodedLen(self: SemVer) usize {
        var len: usize = 0;
        if (self.major != 0) len += protobuf.int32FieldLen(1, self.major);
        if (self.minor != 0) len += protobuf.int32FieldLen(2, self.minor);
        if (self.patch != 0) len += protobuf.int32FieldLen(3, self.patch);
        return len;
    }
};

pub const ActionCacheUpdateCapabilities = struct {
    update_enabled: bool = false,

    pub fn encode(self: ActionCacheUpdateCapabilities, writer: *protobuf.Writer) !void {
        if (self.update_enabled) try writer.writeBoolField(1, true);
    }

    pub fn encodedLen(self: ActionCacheUpdateCapabilities) usize {
        return if (self.update_enabled) protobuf.boolFieldLen(1) else 0;
    }
};

pub const CacheCapabilities = struct {
    digest_functions: []const DigestFunction = &.{},
    action_cache_update_capabilities: ?ActionCacheUpdateCapabilities = null,
    max_batch_total_size_bytes: i64 = 0,

    pub fn encode(self: CacheCapabilities, writer: *protobuf.Writer) !void {
        for (self.digest_functions) |function| try writer.writeEnumField(1, function);
        if (self.action_cache_update_capabilities) |caps| try writer.writeMessageField(2, caps);
        if (self.max_batch_total_size_bytes != 0) try writer.writeInt64Field(4, self.max_batch_total_size_bytes);
    }

    pub fn encodedLen(self: CacheCapabilities) usize {
        var len: usize = 0;
        for (self.digest_functions) |function| len += protobuf.enumFieldLen(1, function);
        if (self.action_cache_update_capabilities) |caps| len += protobuf.messageFieldLen(2, caps.encodedLen());
        if (self.max_batch_total_size_bytes != 0) len += protobuf.int64FieldLen(4, self.max_batch_total_size_bytes);
        return len;
    }
};

pub const ExecutionCapabilities = struct {
    digest_function: DigestFunction = .unknown,
    exec_enabled: bool = false,
    digest_functions: []const DigestFunction = &.{},

    pub fn encode(self: ExecutionCapabilities, writer: *protobuf.Writer) !void {
        if (self.digest_function != .unknown) try writer.writeEnumField(1, self.digest_function);
        if (self.exec_enabled) try writer.writeBoolField(2, true);
        for (self.digest_functions) |function| try writer.writeEnumField(5, function);
    }

    pub fn encodedLen(self: ExecutionCapabilities) usize {
        var len: usize = 0;
        if (self.digest_function != .unknown) len += protobuf.enumFieldLen(1, self.digest_function);
        if (self.exec_enabled) len += protobuf.boolFieldLen(2);
        for (self.digest_functions) |function| len += protobuf.enumFieldLen(5, function);
        return len;
    }
};

pub const ServerCapabilities = struct {
    cache_capabilities: ?CacheCapabilities = null,
    execution_capabilities: ?ExecutionCapabilities = null,
    low_api_version: ?SemVer = null,
    high_api_version: ?SemVer = null,

    pub fn encode(self: ServerCapabilities, writer: *protobuf.Writer) !void {
        if (self.cache_capabilities) |caps| try writer.writeMessageField(1, caps);
        if (self.execution_capabilities) |caps| try writer.writeMessageField(2, caps);
        if (self.low_api_version) |version| try writer.writeMessageField(4, version);
        if (self.high_api_version) |version| try writer.writeMessageField(5, version);
    }

    pub fn encodedLen(self: ServerCapabilities) usize {
        var len: usize = 0;
        if (self.cache_capabilities) |caps| len += protobuf.messageFieldLen(1, caps.encodedLen());
        if (self.execution_capabilities) |caps| len += protobuf.messageFieldLen(2, caps.encodedLen());
        if (self.low_api_version) |version| len += protobuf.messageFieldLen(4, version.encodedLen());
        if (self.high_api_version) |version| len += protobuf.messageFieldLen(5, version.encodedLen());
        return len;
    }
};

pub const GetCapabilitiesRequest = struct {
    instance_name: []const u8 = "",

    pub fn encode(self: GetCapabilitiesRequest, writer: *protobuf.Writer) !void {
        if (self.instance_name.len != 0) try writer.writeStringField(1, self.instance_name);
    }

    pub fn decode(reader: *protobuf.Reader) !GetCapabilitiesRequest {
        var out: GetCapabilitiesRequest = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.instance_name = try reader.readString(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const EnvironmentVariable = struct {
    name: []const u8 = "",
    value: []const u8 = "",

    pub fn encode(self: EnvironmentVariable, writer: *protobuf.Writer) !void {
        if (self.name.len != 0) try writer.writeStringField(1, self.name);
        if (self.value.len != 0) try writer.writeStringField(2, self.value);
    }

    pub fn encodedLen(self: EnvironmentVariable) usize {
        var len: usize = 0;
        if (self.name.len != 0) len += protobuf.stringFieldLen(1, self.name.len);
        if (self.value.len != 0) len += protobuf.stringFieldLen(2, self.value.len);
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !EnvironmentVariable {
        var out: EnvironmentVariable = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.name = try reader.readString(),
                2 => out.value = try reader.readString(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const Command = struct {
    arguments: []const []const u8 = &.{},
    environment_variables: []const EnvironmentVariable = &.{},
    output_files: []const []const u8 = &.{},
    output_directories: []const []const u8 = &.{},
    output_paths: []const []const u8 = &.{},
    output_directory_format: ?OutputDirectoryFormat = null,

    pub const OutputDirectoryFormat = enum(u32) {
        tree_only = 0,
        directory_only = 1,
        tree_and_directory = 2,
    };

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        allocator.free(self.arguments);
        allocator.free(self.environment_variables);
        allocator.free(self.output_files);
        allocator.free(self.output_directories);
        allocator.free(self.output_paths);
        self.* = .{};
    }

    pub fn encode(self: Command, writer: *protobuf.Writer) !void {
        for (self.arguments) |argument| try writer.writeStringField(1, argument);
        for (self.environment_variables) |variable| try writer.writeMessageField(2, variable);
        for (self.output_files) |path| try writer.writeStringField(3, path);
        for (self.output_directories) |path| try writer.writeStringField(4, path);
        for (self.output_paths) |path| try writer.writeStringField(7, path);
        if (self.output_directory_format) |format| try writer.writeEnumField(9, format);
    }

    pub fn encodedLen(self: Command) usize {
        var len: usize = 0;
        for (self.arguments) |argument| len += protobuf.stringFieldLen(1, argument.len);
        for (self.environment_variables) |variable| len += protobuf.messageFieldLen(2, variable.encodedLen());
        for (self.output_files) |path| len += protobuf.stringFieldLen(3, path.len);
        for (self.output_directories) |path| len += protobuf.stringFieldLen(4, path.len);
        for (self.output_paths) |path| len += protobuf.stringFieldLen(7, path.len);
        if (self.output_directory_format) |format| len += protobuf.enumFieldLen(9, format);
        return len;
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !Command {
        var arguments: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer arguments.deinit(allocator);
        var environment_variables: std.ArrayListUnmanaged(EnvironmentVariable) = .empty;
        errdefer environment_variables.deinit(allocator);
        var output_files: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer output_files.deinit(allocator);
        var output_directories: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer output_directories.deinit(allocator);
        var output_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer output_paths.deinit(allocator);

        var out: Command = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => try arguments.append(allocator, try reader.readString()),
                2 => {
                    var nested = try reader.readMessage();
                    try environment_variables.append(allocator, try EnvironmentVariable.decode(&nested));
                },
                3 => try output_files.append(allocator, try reader.readString()),
                4 => try output_directories.append(allocator, try reader.readString()),
                7 => try output_paths.append(allocator, try reader.readString()),
                9 => out.output_directory_format = try reader.readEnum(OutputDirectoryFormat),
                else => try reader.skipField(tag.wire_type),
            }
        }

        out.arguments = try arguments.toOwnedSlice(allocator);
        out.environment_variables = try environment_variables.toOwnedSlice(allocator);
        out.output_files = try output_files.toOwnedSlice(allocator);
        out.output_directories = try output_directories.toOwnedSlice(allocator);
        out.output_paths = try output_paths.toOwnedSlice(allocator);
        return out;
    }
};

pub const Action = struct {
    command_digest: ?Digest = null,
    input_root_digest: ?Digest = null,
    do_not_cache: bool = false,

    pub fn encode(self: Action, writer: *protobuf.Writer) !void {
        if (self.command_digest) |digest| try writer.writeMessageField(1, digest);
        if (self.input_root_digest) |digest| try writer.writeMessageField(2, digest);
        if (self.do_not_cache) try writer.writeBoolField(7, true);
    }

    pub fn encodedLen(self: Action) usize {
        var len: usize = 0;
        if (self.command_digest) |digest| len += protobuf.messageFieldLen(1, digest.encodedLen());
        if (self.input_root_digest) |digest| len += protobuf.messageFieldLen(2, digest.encodedLen());
        if (self.do_not_cache) len += protobuf.boolFieldLen(7);
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !Action {
        var out: Action = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => {
                    var nested = try reader.readMessage();
                    out.command_digest = try Digest.decode(&nested);
                },
                2 => {
                    var nested = try reader.readMessage();
                    out.input_root_digest = try Digest.decode(&nested);
                },
                7 => out.do_not_cache = try reader.readBool(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const FileNode = struct {
    name: []const u8 = "",
    digest: ?Digest = null,
    is_executable: bool = false,

    pub fn encode(self: FileNode, writer: *protobuf.Writer) !void {
        if (self.name.len != 0) try writer.writeStringField(1, self.name);
        if (self.digest) |digest| try writer.writeMessageField(2, digest);
        if (self.is_executable) try writer.writeBoolField(4, true);
    }

    pub fn encodedLen(self: FileNode) usize {
        var len: usize = 0;
        if (self.name.len != 0) len += protobuf.stringFieldLen(1, self.name.len);
        if (self.digest) |digest| len += protobuf.messageFieldLen(2, digest.encodedLen());
        if (self.is_executable) len += protobuf.boolFieldLen(4);
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !FileNode {
        var out: FileNode = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.name = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    out.digest = try Digest.decode(&nested);
                },
                4 => out.is_executable = try reader.readBool(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const DirectoryNode = struct {
    name: []const u8 = "",
    digest: ?Digest = null,

    pub fn encode(self: DirectoryNode, writer: *protobuf.Writer) !void {
        if (self.name.len != 0) try writer.writeStringField(1, self.name);
        if (self.digest) |digest| try writer.writeMessageField(2, digest);
    }

    pub fn encodedLen(self: DirectoryNode) usize {
        var len: usize = 0;
        if (self.name.len != 0) len += protobuf.stringFieldLen(1, self.name.len);
        if (self.digest) |digest| len += protobuf.messageFieldLen(2, digest.encodedLen());
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !DirectoryNode {
        var out: DirectoryNode = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.name = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    out.digest = try Digest.decode(&nested);
                },
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const Directory = struct {
    files: []const FileNode = &.{},
    directories: []const DirectoryNode = &.{},

    pub fn deinit(self: *Directory, allocator: std.mem.Allocator) void {
        allocator.free(self.files);
        allocator.free(self.directories);
        self.* = .{};
    }

    pub fn encode(self: Directory, writer: *protobuf.Writer) !void {
        for (self.files) |file| try writer.writeMessageField(1, file);
        for (self.directories) |directory| try writer.writeMessageField(2, directory);
    }

    pub fn encodedLen(self: Directory) usize {
        var len: usize = 0;
        for (self.files) |file| len += protobuf.messageFieldLen(1, file.encodedLen());
        for (self.directories) |directory| len += protobuf.messageFieldLen(2, directory.encodedLen());
        return len;
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !Directory {
        var files: std.ArrayListUnmanaged(FileNode) = .empty;
        errdefer files.deinit(allocator);
        var directories: std.ArrayListUnmanaged(DirectoryNode) = .empty;
        errdefer directories.deinit(allocator);

        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => {
                    var nested = try reader.readMessage();
                    try files.append(allocator, try FileNode.decode(&nested));
                },
                2 => {
                    var nested = try reader.readMessage();
                    try directories.append(allocator, try DirectoryNode.decode(&nested));
                },
                else => try reader.skipField(tag.wire_type),
            }
        }

        return .{
            .files = try files.toOwnedSlice(allocator),
            .directories = try directories.toOwnedSlice(allocator),
        };
    }
};

pub const ExecuteRequest = struct {
    instance_name: []const u8 = "",
    skip_cache_lookup: bool = false,
    action_digest: ?Digest = null,

    pub fn encode(self: ExecuteRequest, writer: *protobuf.Writer) !void {
        if (self.instance_name.len != 0) try writer.writeStringField(1, self.instance_name);
        if (self.skip_cache_lookup) try writer.writeBoolField(3, true);
        if (self.action_digest) |digest| try writer.writeMessageField(6, digest);
    }

    pub fn encodedLen(self: ExecuteRequest) usize {
        var len: usize = 0;
        if (self.instance_name.len != 0) len += protobuf.stringFieldLen(1, self.instance_name.len);
        if (self.skip_cache_lookup) len += protobuf.boolFieldLen(3);
        if (self.action_digest) |digest| len += protobuf.messageFieldLen(6, digest.encodedLen());
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !ExecuteRequest {
        var out: ExecuteRequest = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.instance_name = try reader.readString(),
                3 => out.skip_cache_lookup = try reader.readBool(),
                6 => {
                    var nested = try reader.readMessage();
                    out.action_digest = try Digest.decode(&nested);
                },
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const ActionResult = struct {
    output_files: []const OutputFile = &.{},
    exit_code: i32 = 0,
    stdout_digest: ?Digest = null,
    stderr_digest: ?Digest = null,

    pub fn deinit(self: *ActionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output_files);
        self.* = .{};
    }

    pub fn encode(self: ActionResult, writer: *protobuf.Writer) !void {
        for (self.output_files) |output_file| try writer.writeMessageField(2, output_file);
        if (self.exit_code != 0) try writer.writeInt32Field(4, self.exit_code);
        if (self.stdout_digest) |digest| try writer.writeMessageField(6, digest);
        if (self.stderr_digest) |digest| try writer.writeMessageField(8, digest);
    }

    pub fn encodedLen(self: ActionResult) usize {
        var len: usize = 0;
        for (self.output_files) |output_file| len += protobuf.messageFieldLen(2, output_file.encodedLen());
        if (self.exit_code != 0) len += protobuf.int32FieldLen(4, self.exit_code);
        if (self.stdout_digest) |digest| len += protobuf.messageFieldLen(6, digest.encodedLen());
        if (self.stderr_digest) |digest| len += protobuf.messageFieldLen(8, digest.encodedLen());
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !ActionResult {
        var out: ActionResult = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                2 => try reader.skipField(tag.wire_type),
                4 => out.exit_code = try reader.readInt32(),
                6 => {
                    var nested = try reader.readMessage();
                    out.stdout_digest = try Digest.decode(&nested);
                },
                8 => {
                    var nested = try reader.readMessage();
                    out.stderr_digest = try Digest.decode(&nested);
                },
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !ActionResult {
        var output_files: std.ArrayListUnmanaged(OutputFile) = .empty;
        errdefer output_files.deinit(allocator);
        var out: ActionResult = .{};

        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                2 => {
                    var nested = try reader.readMessage();
                    try output_files.append(allocator, try OutputFile.decode(&nested));
                },
                4 => out.exit_code = try reader.readInt32(),
                6 => {
                    var nested = try reader.readMessage();
                    out.stdout_digest = try Digest.decode(&nested);
                },
                8 => {
                    var nested = try reader.readMessage();
                    out.stderr_digest = try Digest.decode(&nested);
                },
                else => try reader.skipField(tag.wire_type),
            }
        }

        out.output_files = try output_files.toOwnedSlice(allocator);
        return out;
    }
};

pub const OutputFile = struct {
    path: []const u8 = "",
    digest: ?Digest = null,
    is_executable: bool = false,

    pub fn encode(self: OutputFile, writer: *protobuf.Writer) !void {
        if (self.path.len != 0) try writer.writeStringField(1, self.path);
        if (self.digest) |digest| try writer.writeMessageField(2, digest);
        if (self.is_executable) try writer.writeBoolField(4, true);
    }

    pub fn encodedLen(self: OutputFile) usize {
        var len: usize = 0;
        if (self.path.len != 0) len += protobuf.stringFieldLen(1, self.path.len);
        if (self.digest) |digest| len += protobuf.messageFieldLen(2, digest.encodedLen());
        if (self.is_executable) len += protobuf.boolFieldLen(4);
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !OutputFile {
        var out: OutputFile = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.path = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    out.digest = try Digest.decode(&nested);
                },
                4 => out.is_executable = try reader.readBool(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const Any = struct {
    type_url: []const u8 = "",
    value: []const u8 = "",

    pub fn encode(self: Any, writer: *protobuf.Writer) !void {
        if (self.type_url.len != 0) try writer.writeStringField(1, self.type_url);
        if (self.value.len != 0) try writer.writeBytesField(2, self.value);
    }

    pub fn encodedLen(self: Any) usize {
        var len: usize = 0;
        if (self.type_url.len != 0) len += protobuf.stringFieldLen(1, self.type_url.len);
        if (self.value.len != 0) len += protobuf.bytesFieldLen(2, self.value.len);
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !Any {
        var out: Any = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.type_url = try reader.readString(),
                2 => out.value = try reader.readBytes(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const execute_response_type_url = "type.googleapis.com/build.bazel.remote.execution.v2.ExecuteResponse";

pub const ExecuteResponse = struct {
    result: ?ActionResult = null,
    cached_result: bool = false,
    status: ?Status = null,
    message: []const u8 = "",

    pub fn encode(self: ExecuteResponse, writer: *protobuf.Writer) !void {
        if (self.result) |result| try writer.writeMessageField(1, result);
        if (self.cached_result) try writer.writeBoolField(2, true);
        if (self.status) |status| try writer.writeMessageField(3, status);
        if (self.message.len != 0) try writer.writeStringField(5, self.message);
    }

    pub fn encodedLen(self: ExecuteResponse) usize {
        var len: usize = 0;
        if (self.result) |result| len += protobuf.messageFieldLen(1, result.encodedLen());
        if (self.cached_result) len += protobuf.boolFieldLen(2);
        if (self.status) |status| len += protobuf.messageFieldLen(3, status.encodedLen());
        if (self.message.len != 0) len += protobuf.stringFieldLen(5, self.message.len);
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !ExecuteResponse {
        var out: ExecuteResponse = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => {
                    var nested = try reader.readMessage();
                    out.result = try ActionResult.decode(&nested);
                },
                2 => out.cached_result = try reader.readBool(),
                3 => {
                    var nested = try reader.readMessage();
                    out.status = try Status.decode(&nested);
                },
                5 => out.message = try reader.readString(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }

    pub fn toAny(self: ExecuteResponse, allocator: std.mem.Allocator) !Any {
        return .{
            .type_url = execute_response_type_url,
            .value = try encodeAlloc(allocator, self),
        };
    }
};

pub const Operation = struct {
    name: []const u8 = "",
    metadata: ?Any = null,
    done: bool = false,
    err: ?Status = null,
    response: ?Any = null,

    pub fn encode(self: Operation, writer: *protobuf.Writer) !void {
        if (self.name.len != 0) try writer.writeStringField(1, self.name);
        if (self.metadata) |metadata| try writer.writeMessageField(2, metadata);
        if (self.done) try writer.writeBoolField(3, true);
        if (self.err) |status| try writer.writeMessageField(4, status);
        if (self.response) |response| try writer.writeMessageField(5, response);
    }

    pub fn encodedLen(self: Operation) usize {
        var len: usize = 0;
        if (self.name.len != 0) len += protobuf.stringFieldLen(1, self.name.len);
        if (self.metadata) |metadata| len += protobuf.messageFieldLen(2, metadata.encodedLen());
        if (self.done) len += protobuf.boolFieldLen(3);
        if (self.err) |status| len += protobuf.messageFieldLen(4, status.encodedLen());
        if (self.response) |response| len += protobuf.messageFieldLen(5, response.encodedLen());
        return len;
    }

    pub fn decode(reader: *protobuf.Reader) !Operation {
        var out: Operation = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.name = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    out.metadata = try Any.decode(&nested);
                },
                3 => out.done = try reader.readBool(),
                4 => {
                    var nested = try reader.readMessage();
                    out.err = try Status.decode(&nested);
                },
                5 => {
                    var nested = try reader.readMessage();
                    out.response = try Any.decode(&nested);
                },
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const GetActionResultRequest = struct {
    instance_name: []const u8 = "",
    action_digest: ?Digest = null,

    pub fn encode(self: GetActionResultRequest, writer: *protobuf.Writer) !void {
        if (self.instance_name.len != 0) try writer.writeStringField(1, self.instance_name);
        if (self.action_digest) |digest| try writer.writeMessageField(2, digest);
    }

    pub fn decode(reader: *protobuf.Reader) !GetActionResultRequest {
        var out: GetActionResultRequest = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.instance_name = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    out.action_digest = try Digest.decode(&nested);
                },
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const UpdateActionResultRequest = struct {
    instance_name: []const u8 = "",
    action_digest: ?Digest = null,
    action_result: ?ActionResult = null,

    pub fn encode(self: UpdateActionResultRequest, writer: *protobuf.Writer) !void {
        if (self.instance_name.len != 0) try writer.writeStringField(1, self.instance_name);
        if (self.action_digest) |digest| try writer.writeMessageField(2, digest);
        if (self.action_result) |result| try writer.writeMessageField(3, result);
    }

    pub fn decode(reader: *protobuf.Reader) !UpdateActionResultRequest {
        var out: UpdateActionResultRequest = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.instance_name = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    out.action_digest = try Digest.decode(&nested);
                },
                3 => {
                    var nested = try reader.readMessage();
                    out.action_result = try ActionResult.decode(&nested);
                },
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const FindMissingBlobsRequest = struct {
    instance_name: []const u8 = "",
    blob_digests: []const Digest = &.{},

    pub fn deinit(self: *FindMissingBlobsRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.blob_digests);
        self.* = .{};
    }

    pub fn encode(self: FindMissingBlobsRequest, writer: *protobuf.Writer) !void {
        if (self.instance_name.len != 0) try writer.writeStringField(1, self.instance_name);
        for (self.blob_digests) |digest| try writer.writeMessageField(2, digest);
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !FindMissingBlobsRequest {
        var digests: std.ArrayListUnmanaged(Digest) = .empty;
        errdefer digests.deinit(allocator);
        var out: FindMissingBlobsRequest = .{};

        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.instance_name = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    try digests.append(allocator, try Digest.decode(&nested));
                },
                else => try reader.skipField(tag.wire_type),
            }
        }

        out.blob_digests = try digests.toOwnedSlice(allocator);
        return out;
    }
};

pub const FindMissingBlobsResponse = struct {
    missing_blob_digests: []const Digest = &.{},

    pub fn deinit(self: *FindMissingBlobsResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.missing_blob_digests);
        self.* = .{};
    }

    pub fn encode(self: FindMissingBlobsResponse, writer: *protobuf.Writer) !void {
        for (self.missing_blob_digests) |digest| try writer.writeMessageField(2, digest);
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !FindMissingBlobsResponse {
        var digests: std.ArrayListUnmanaged(Digest) = .empty;
        errdefer digests.deinit(allocator);

        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                2 => {
                    var nested = try reader.readMessage();
                    try digests.append(allocator, try Digest.decode(&nested));
                },
                else => try reader.skipField(tag.wire_type),
            }
        }

        return .{ .missing_blob_digests = try digests.toOwnedSlice(allocator) };
    }
};

pub const BatchUpdateBlobsRequest = struct {
    instance_name: []const u8 = "",
    requests: []const Item = &.{},

    pub const Item = struct {
        digest: Digest = .{},
        data: []const u8 = "",

        pub fn encode(self: Item, writer: *protobuf.Writer) !void {
            if (self.digest.hash.len != 0) try writer.writeMessageField(1, self.digest);
            if (self.data.len != 0) try writer.writeBytesField(2, self.data);
        }

        pub fn encodedLen(self: Item) usize {
            var len: usize = 0;
            if (self.digest.hash.len != 0) len += protobuf.messageFieldLen(1, self.digest.encodedLen());
            if (self.data.len != 0) len += protobuf.bytesFieldLen(2, self.data.len);
            return len;
        }

        pub fn decode(reader: *protobuf.Reader) !Item {
            var out: Item = .{};
            while (try reader.next()) |tag| {
                switch (tag.field_number) {
                    1 => {
                        var nested = try reader.readMessage();
                        out.digest = try Digest.decode(&nested);
                    },
                    2 => out.data = try reader.readBytes(),
                    else => try reader.skipField(tag.wire_type),
                }
            }
            return out;
        }
    };

    pub fn deinit(self: *BatchUpdateBlobsRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.requests);
        self.* = .{};
    }

    pub fn encode(self: BatchUpdateBlobsRequest, writer: *protobuf.Writer) !void {
        if (self.instance_name.len != 0) try writer.writeStringField(1, self.instance_name);
        for (self.requests) |request| try writer.writeMessageField(2, request);
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !BatchUpdateBlobsRequest {
        var requests: std.ArrayListUnmanaged(Item) = .empty;
        errdefer requests.deinit(allocator);
        var out: BatchUpdateBlobsRequest = .{};

        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.instance_name = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    try requests.append(allocator, try Item.decode(&nested));
                },
                else => try reader.skipField(tag.wire_type),
            }
        }

        out.requests = try requests.toOwnedSlice(allocator);
        return out;
    }
};

pub const BatchUpdateBlobsResponse = struct {
    responses: []const Item = &.{},

    pub const Item = struct {
        digest: Digest = .{},
        status: Status = .{},

        pub fn encode(self: Item, writer: *protobuf.Writer) !void {
            if (self.digest.hash.len != 0) try writer.writeMessageField(1, self.digest);
            try writer.writeMessageField(2, self.status);
        }

        pub fn decode(reader: *protobuf.Reader) !Item {
            var out: Item = .{};
            while (try reader.next()) |tag| {
                switch (tag.field_number) {
                    1 => {
                        var nested = try reader.readMessage();
                        out.digest = try Digest.decode(&nested);
                    },
                    2 => {
                        var nested = try reader.readMessage();
                        out.status = try Status.decode(&nested);
                    },
                    else => try reader.skipField(tag.wire_type),
                }
            }
            return out;
        }
    };

    pub fn deinit(self: *BatchUpdateBlobsResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.responses);
        self.* = .{};
    }

    pub fn encode(self: BatchUpdateBlobsResponse, writer: *protobuf.Writer) !void {
        for (self.responses) |response| try writer.writeMessageField(1, response);
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !BatchUpdateBlobsResponse {
        var responses: std.ArrayListUnmanaged(Item) = .empty;
        errdefer responses.deinit(allocator);

        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => {
                    var nested = try reader.readMessage();
                    try responses.append(allocator, try Item.decode(&nested));
                },
                else => try reader.skipField(tag.wire_type),
            }
        }

        return .{ .responses = try responses.toOwnedSlice(allocator) };
    }
};

pub const BatchReadBlobsRequest = struct {
    instance_name: []const u8 = "",
    digests: []const Digest = &.{},

    pub fn deinit(self: *BatchReadBlobsRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.digests);
        self.* = .{};
    }

    pub fn encode(self: BatchReadBlobsRequest, writer: *protobuf.Writer) !void {
        if (self.instance_name.len != 0) try writer.writeStringField(1, self.instance_name);
        for (self.digests) |digest| try writer.writeMessageField(2, digest);
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !BatchReadBlobsRequest {
        var digests: std.ArrayListUnmanaged(Digest) = .empty;
        errdefer digests.deinit(allocator);
        var out: BatchReadBlobsRequest = .{};

        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.instance_name = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    try digests.append(allocator, try Digest.decode(&nested));
                },
                else => try reader.skipField(tag.wire_type),
            }
        }

        out.digests = try digests.toOwnedSlice(allocator);
        return out;
    }
};

pub const BatchReadBlobsResponse = struct {
    responses: []const Item = &.{},

    pub const Item = struct {
        digest: Digest = .{},
        data: []const u8 = "",
        status: Status = .{},

        pub fn encode(self: Item, writer: *protobuf.Writer) !void {
            if (self.digest.hash.len != 0) try writer.writeMessageField(1, self.digest);
            if (self.data.len != 0) try writer.writeBytesField(2, self.data);
            try writer.writeMessageField(3, self.status);
        }

        pub fn decode(reader: *protobuf.Reader) !Item {
            var out: Item = .{};
            while (try reader.next()) |tag| {
                switch (tag.field_number) {
                    1 => {
                        var nested = try reader.readMessage();
                        out.digest = try Digest.decode(&nested);
                    },
                    2 => out.data = try reader.readBytes(),
                    3 => {
                        var nested = try reader.readMessage();
                        out.status = try Status.decode(&nested);
                    },
                    else => try reader.skipField(tag.wire_type),
                }
            }
            return out;
        }
    };

    pub fn deinit(self: *BatchReadBlobsResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.responses);
        self.* = .{};
    }

    pub fn encode(self: BatchReadBlobsResponse, writer: *protobuf.Writer) !void {
        for (self.responses) |response| try writer.writeMessageField(1, response);
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !BatchReadBlobsResponse {
        var responses: std.ArrayListUnmanaged(Item) = .empty;
        errdefer responses.deinit(allocator);

        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => {
                    var nested = try reader.readMessage();
                    try responses.append(allocator, try Item.decode(&nested));
                },
                else => try reader.skipField(tag.wire_type),
            }
        }

        return .{ .responses = try responses.toOwnedSlice(allocator) };
    }
};

pub const GetTreeRequest = struct {
    instance_name: []const u8 = "",
    root_digest: ?Digest = null,
    page_size: i32 = 0,
    page_token: []const u8 = "",

    pub fn encode(self: GetTreeRequest, writer: *protobuf.Writer) !void {
        if (self.instance_name.len != 0) try writer.writeStringField(1, self.instance_name);
        if (self.root_digest) |digest| try writer.writeMessageField(2, digest);
        if (self.page_size != 0) try writer.writeInt32Field(3, self.page_size);
        if (self.page_token.len != 0) try writer.writeStringField(4, self.page_token);
    }

    pub fn decode(reader: *protobuf.Reader) !GetTreeRequest {
        var out: GetTreeRequest = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => out.instance_name = try reader.readString(),
                2 => {
                    var nested = try reader.readMessage();
                    out.root_digest = try Digest.decode(&nested);
                },
                3 => out.page_size = try reader.readInt32(),
                4 => out.page_token = try reader.readString(),
                else => try reader.skipField(tag.wire_type),
            }
        }
        return out;
    }
};

pub const GetTreeResponse = struct {
    directories: []const Directory = &.{},
    next_page_token: []const u8 = "",

    pub fn deinit(self: *GetTreeResponse, allocator: std.mem.Allocator) void {
        for (self.directories) |directory| {
            var copy = directory;
            copy.deinit(allocator);
        }
        allocator.free(self.directories);
        self.* = .{};
    }

    pub fn encode(self: GetTreeResponse, writer: *protobuf.Writer) !void {
        for (self.directories) |directory| try writer.writeMessageField(1, directory);
        if (self.next_page_token.len != 0) try writer.writeStringField(2, self.next_page_token);
    }

    pub fn decodeOwned(allocator: std.mem.Allocator, reader: *protobuf.Reader) !GetTreeResponse {
        var directories: std.ArrayListUnmanaged(Directory) = .empty;
        errdefer {
            for (directories.items) |*directory| directory.deinit(allocator);
            directories.deinit(allocator);
        }

        var out: GetTreeResponse = .{};
        while (try reader.next()) |tag| {
            switch (tag.field_number) {
                1 => {
                    var nested = try reader.readMessage();
                    try directories.append(allocator, try Directory.decodeOwned(allocator, &nested));
                },
                2 => out.next_page_token = try reader.readString(),
                else => try reader.skipField(tag.wire_type),
            }
        }

        out.directories = try directories.toOwnedSlice(allocator);
        return out;
    }
};

pub fn encodeAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return protobuf.encodeAlloc(allocator, value);
}

test "Digest encodes with REAPI field numbers" {
    const digest: Digest = .{
        .hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .size_bytes = 11,
    };

    const encoded = try encodeAlloc(std.testing.allocator, digest);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(@as(u8, 0x0a), encoded[0]);
    try std.testing.expectEqual(@as(u8, 64), encoded[1]);
    try std.testing.expectEqual(@as(u8, 0x10), encoded[66]);
    try std.testing.expectEqual(@as(u8, 11), encoded[67]);

    var reader = protobuf.Reader.init(encoded);
    const decoded = try Digest.decode(&reader);
    try std.testing.expect(digest.eql(decoded));
}

test "Command decode preserves repeated fields" {
    const command: Command = .{
        .arguments = &.{ "/bin/sh", "-c", "echo hi" },
        .environment_variables = &.{
            .{ .name = "A", .value = "1" },
            .{ .name = "B", .value = "2" },
        },
        .output_files = &.{"out.txt"},
        .output_directories = &.{"logs"},
        .output_paths = &.{ "dist/app", "dist/app.dSYM" },
        .output_directory_format = .tree_and_directory,
    };

    const encoded = try encodeAlloc(std.testing.allocator, command);
    defer std.testing.allocator.free(encoded);

    var reader = protobuf.Reader.init(encoded);
    var decoded = try Command.decodeOwned(std.testing.allocator, &reader);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), decoded.arguments.len);
    try std.testing.expectEqualStrings("echo hi", decoded.arguments[2]);
    try std.testing.expectEqual(@as(usize, 2), decoded.environment_variables.len);
    try std.testing.expectEqualStrings("B", decoded.environment_variables[1].name);
    try std.testing.expectEqualStrings("out.txt", decoded.output_files[0]);
    try std.testing.expectEqualStrings("logs", decoded.output_directories[0]);
    try std.testing.expectEqualStrings("dist/app.dSYM", decoded.output_paths[1]);
    try std.testing.expectEqual(Command.OutputDirectoryFormat.tree_and_directory, decoded.output_directory_format.?);
}

test "Action and ExecuteRequest round-trip borrowed views" {
    const digest: Digest = .{
        .hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .size_bytes = 42,
    };
    const action: Action = .{
        .command_digest = digest,
        .input_root_digest = digest,
        .do_not_cache = true,
    };
    const request: ExecuteRequest = .{
        .instance_name = "local",
        .skip_cache_lookup = true,
        .action_digest = digest,
    };

    const action_bytes = try encodeAlloc(std.testing.allocator, action);
    defer std.testing.allocator.free(action_bytes);
    var action_reader = protobuf.Reader.init(action_bytes);
    const decoded_action = try Action.decode(&action_reader);
    try std.testing.expect(decoded_action.command_digest.?.eql(digest));
    try std.testing.expect(decoded_action.input_root_digest.?.eql(digest));
    try std.testing.expect(decoded_action.do_not_cache);

    const request_bytes = try encodeAlloc(std.testing.allocator, request);
    defer std.testing.allocator.free(request_bytes);
    var request_reader = protobuf.Reader.init(request_bytes);
    const decoded_request = try ExecuteRequest.decode(&request_reader);
    try std.testing.expectEqualStrings("local", decoded_request.instance_name);
    try std.testing.expect(decoded_request.skip_cache_lookup);
    try std.testing.expect(decoded_request.action_digest.?.eql(digest));
}

test "Directory decodes files and child directories" {
    const file_digest: Digest = .{
        .hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .size_bytes = 5,
    };
    const child_digest: Digest = .{
        .hash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .size_bytes = 9,
    };
    const directory: Directory = .{
        .files = &.{
            .{ .name = "hello.txt", .digest = file_digest, .is_executable = true },
        },
        .directories = &.{
            .{ .name = "src", .digest = child_digest },
        },
    };

    const encoded = try encodeAlloc(std.testing.allocator, directory);
    defer std.testing.allocator.free(encoded);

    var reader = protobuf.Reader.init(encoded);
    var decoded = try Directory.decodeOwned(std.testing.allocator, &reader);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.files.len);
    try std.testing.expectEqualStrings("hello.txt", decoded.files[0].name);
    try std.testing.expect(decoded.files[0].digest.?.eql(file_digest));
    try std.testing.expect(decoded.files[0].is_executable);
    try std.testing.expectEqual(@as(usize, 1), decoded.directories.len);
    try std.testing.expectEqualStrings("src", decoded.directories[0].name);
    try std.testing.expect(decoded.directories[0].digest.?.eql(child_digest));
}

test "CAS batch messages decode repeated request and response fields" {
    const digest: Digest = .{
        .hash = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .size_bytes = 4,
    };

    const update_request: BatchUpdateBlobsRequest = .{
        .instance_name = "local",
        .requests = &.{
            .{ .digest = digest, .data = "data" },
        },
    };
    const update_request_bytes = try encodeAlloc(std.testing.allocator, update_request);
    defer std.testing.allocator.free(update_request_bytes);
    var update_request_reader = protobuf.Reader.init(update_request_bytes);
    var decoded_update_request = try BatchUpdateBlobsRequest.decodeOwned(std.testing.allocator, &update_request_reader);
    defer decoded_update_request.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("local", decoded_update_request.instance_name);
    try std.testing.expectEqual(@as(usize, 1), decoded_update_request.requests.len);
    try std.testing.expect(decoded_update_request.requests[0].digest.eql(digest));
    try std.testing.expectEqualStrings("data", decoded_update_request.requests[0].data);

    const read_response: BatchReadBlobsResponse = .{
        .responses = &.{
            .{ .digest = digest, .data = "data", .status = .{} },
            .{ .digest = digest, .status = .{ .code = .not_found, .message = "missing" } },
        },
    };
    const read_response_bytes = try encodeAlloc(std.testing.allocator, read_response);
    defer std.testing.allocator.free(read_response_bytes);
    var read_response_reader = protobuf.Reader.init(read_response_bytes);
    var decoded_read_response = try BatchReadBlobsResponse.decodeOwned(std.testing.allocator, &read_response_reader);
    defer decoded_read_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded_read_response.responses.len);
    try std.testing.expectEqualStrings("data", decoded_read_response.responses[0].data);
    try std.testing.expectEqual(StatusCode.not_found, decoded_read_response.responses[1].status.code);
    try std.testing.expectEqualStrings("missing", decoded_read_response.responses[1].status.message);
}

test "GetTreeResponse round-trips directories" {
    const file_digest: Digest = .{
        .hash = "9999999999999999999999999999999999999999999999999999999999999999",
        .size_bytes = 9,
    };
    const response = GetTreeResponse{
        .directories = &.{
            .{
                .files = &.{
                    .{ .name = "file.txt", .digest = file_digest },
                },
            },
        },
    };

    const encoded = try encodeAlloc(std.testing.allocator, response);
    defer std.testing.allocator.free(encoded);

    var reader = protobuf.Reader.init(encoded);
    var decoded = try GetTreeResponse.decodeOwned(std.testing.allocator, &reader);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.directories.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.directories[0].files.len);
    try std.testing.expectEqualStrings("file.txt", decoded.directories[0].files[0].name);
    try std.testing.expect(decoded.directories[0].files[0].digest.?.eql(file_digest));
}

test "ActionResult round-trips exit code and stream digests" {
    const stdout_digest: Digest = .{
        .hash = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        .size_bytes = 3,
    };
    const stderr_digest: Digest = .{
        .hash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        .size_bytes = 4,
    };
    const result: ActionResult = .{
        .output_files = &.{
            .{ .path = "out/app", .digest = stdout_digest, .is_executable = true },
        },
        .exit_code = 7,
        .stdout_digest = stdout_digest,
        .stderr_digest = stderr_digest,
    };

    const encoded = try encodeAlloc(std.testing.allocator, result);
    defer std.testing.allocator.free(encoded);

    var reader = protobuf.Reader.init(encoded);
    var decoded = try ActionResult.decodeOwned(std.testing.allocator, &reader);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.output_files.len);
    try std.testing.expectEqualStrings("out/app", decoded.output_files[0].path);
    try std.testing.expect(decoded.output_files[0].is_executable);
    try std.testing.expect(decoded.output_files[0].digest.?.eql(stdout_digest));
    try std.testing.expectEqual(@as(i32, 7), decoded.exit_code);
    try std.testing.expect(decoded.stdout_digest.?.eql(stdout_digest));
    try std.testing.expect(decoded.stderr_digest.?.eql(stderr_digest));
}

test "Operation carries packed ExecuteResponse" {
    const response = ExecuteResponse{
        .result = .{ .exit_code = 5 },
        .cached_result = true,
        .status = .{},
    };
    const packed_response = try response.toAny(std.testing.allocator);
    defer std.testing.allocator.free(packed_response.value);

    const encoded = try encodeAlloc(std.testing.allocator, Operation{
        .name = "operations/local",
        .done = true,
        .response = packed_response,
    });
    defer std.testing.allocator.free(encoded);

    var reader = protobuf.Reader.init(encoded);
    const operation = try Operation.decode(&reader);
    try std.testing.expect(operation.done);
    try std.testing.expectEqualStrings("operations/local", operation.name);
    try std.testing.expectEqualStrings(execute_response_type_url, operation.response.?.type_url);

    var response_reader = protobuf.Reader.init(operation.response.?.value);
    const decoded_response = try ExecuteResponse.decode(&response_reader);
    try std.testing.expect(decoded_response.cached_result);
    try std.testing.expectEqual(@as(i32, 5), decoded_response.result.?.exit_code);
}
