const std = @import("std");

pub const Writer = struct {
    ctx: *anyopaque,
    write_all: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8) anyerror!void,
    write_file_with_prefix: ?*const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8, std.Io.File.Handle, u64, usize) anyerror!void = null,

    pub fn writeAll(
        self: Writer,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        return self.write_all(self.ctx, io, allocator, bytes);
    }

    pub fn canWriteFileWithPrefix(self: Writer) bool {
        return self.write_file_with_prefix != null;
    }

    pub fn writeFileWithPrefix(
        self: Writer,
        io: std.Io,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        file_handle: std.Io.File.Handle,
        offset: u64,
        len: usize,
    ) !void {
        const write_file = self.write_file_with_prefix orelse return error.UnsupportedOperation;
        return write_file(self.ctx, io, allocator, prefix, file_handle, offset, len);
    }
};

pub const ArrayListWriter = struct {
    out: *std.ArrayListUnmanaged(u8),

    pub fn writer(self: *ArrayListWriter) Writer {
        return .{
            .ctx = self,
            .write_all = writeAll,
        };
    }

    fn writeAll(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        _ = io;
        const self: *ArrayListWriter = @ptrCast(@alignCast(ctx));
        try self.out.appendSlice(allocator, bytes);
    }
};

test "ArrayListWriter appends body chunks" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    var list_writer = ArrayListWriter{ .out = &out };
    const writer = list_writer.writer();
    try writer.writeAll(std.testing.io, std.testing.allocator, "ab");
    try writer.writeAll(std.testing.io, std.testing.allocator, "cd");

    try std.testing.expectEqualStrings("abcd", out.items);
}
