const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HeaderView = Header;

pub const HeaderList = struct {
    items: []Header = &.{},

    pub fn deinit(self: *HeaderList, allocator: std.mem.Allocator) void {
        for (self.items) |header| {
            freeIfNonEmpty(allocator, header.name);
            freeIfNonEmpty(allocator, header.value);
        }
        if (self.items.len != 0) allocator.free(self.items);
        self.* = .{};
    }
};

pub fn cloneAlloc(allocator: std.mem.Allocator, view: HeaderView) !Header {
    const name = try dupeOrEmpty(allocator, view.name);
    errdefer freeIfNonEmpty(allocator, name);
    const value = try dupeOrEmpty(allocator, view.value);
    return .{
        .name = name,
        .value = value,
    };
}

pub fn appendClone(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Header),
    view: HeaderView,
) !void {
    const owned = try cloneAlloc(allocator, view);
    errdefer {
        freeIfNonEmpty(allocator, owned.name);
        freeIfNonEmpty(allocator, owned.value);
    }
    try list.append(allocator, owned);
}

fn dupeOrEmpty(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len == 0) return "";
    return try allocator.dupe(u8, bytes);
}

fn freeIfNonEmpty(allocator: std.mem.Allocator, bytes: []const u8) void {
    if (bytes.len == 0) return;
    allocator.free(bytes);
}
