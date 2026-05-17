const std = @import("std");
const cas = @import("cas.zig");

pub const Index = struct {
    lock_flag: std.atomic.Value(u32) = .init(0),
    digests: std.AutoHashMapUnmanaged(cas.Digest, void) = .empty,

    pub fn deinit(self: *Index, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        self.lock();
        defer self.unlock();
        self.digests.deinit(allocator);
        self.* = .{};
    }

    pub fn add(self: *Index, io: std.Io, allocator: std.mem.Allocator, digest: cas.Digest) !void {
        _ = io;
        if (digest.isEmpty()) return;
        self.lock();
        defer self.unlock();
        try self.digests.put(allocator, digest, {});
    }

    pub fn remove(self: *Index, io: std.Io, digest: cas.Digest) void {
        _ = io;
        self.lock();
        defer self.unlock();
        _ = self.digests.remove(digest);
    }

    pub fn contains(self: *Index, io: std.Io, digest: cas.Digest) bool {
        _ = io;
        self.lock();
        defer self.unlock();
        return self.digests.contains(digest);
    }

    fn lock(self: *Index) void {
        while (self.lock_flag.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Index) void {
        self.lock_flag.store(0, .release);
    }
};

test "staged CAS index tracks digests exactly" {
    var index = Index{};
    defer index.deinit(std.testing.io, std.testing.allocator);

    const digest = cas.Digest.fromBytes("blob");
    try std.testing.expect(!index.contains(std.testing.io, digest));
    try index.add(std.testing.io, std.testing.allocator, digest);
    try std.testing.expect(index.contains(std.testing.io, digest));
    index.remove(std.testing.io, digest);
    try std.testing.expect(!index.contains(std.testing.io, digest));
}
