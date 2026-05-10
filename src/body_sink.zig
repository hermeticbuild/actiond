const std = @import("std");

pub const Writer = struct {
    ctx: *anyopaque,
    write_all: *const fn (*anyopaque, std.Io, std.mem.Allocator, []const u8) anyerror!void,

    pub fn writeAll(
        self: Writer,
        io: std.Io,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        return self.write_all(self.ctx, io, allocator, bytes);
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
