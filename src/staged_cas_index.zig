const std = @import("std");
const cas = @import("cas.zig");

pub const Index = struct {
    const shard_count = 256;

    const Shard = struct {
        lock_flag: std.atomic.Value(u32) = .init(0),
        digests: std.AutoHashMapUnmanaged(cas.Digest, void) = .empty,

        fn lock(self: *Shard) void {
            while (self.lock_flag.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }

        fn unlock(self: *Shard) void {
            self.lock_flag.store(0, .release);
        }
    };

    shards: [shard_count]Shard = [_]Shard{.{}} ** shard_count,

    pub fn deinit(self: *Index, io: std.Io, allocator: std.mem.Allocator) void {
        _ = io;
        for (&self.shards) |*shard| {
            shard.lock();
            shard.digests.deinit(allocator);
            shard.unlock();
        }
        self.* = .{};
    }

    pub fn add(self: *Index, io: std.Io, allocator: std.mem.Allocator, digest: cas.Digest) !void {
        _ = io;
        if (digest.isEmpty()) return;
        const shard = self.shardFor(digest);
        shard.lock();
        defer shard.unlock();
        try shard.digests.put(allocator, digest, {});
    }

    pub fn remove(self: *Index, io: std.Io, digest: cas.Digest) void {
        _ = io;
        const shard = self.shardFor(digest);
        shard.lock();
        defer shard.unlock();
        _ = shard.digests.remove(digest);
    }

    pub fn contains(self: *Index, io: std.Io, digest: cas.Digest) bool {
        _ = io;
        const shard = self.shardFor(digest);
        shard.lock();
        defer shard.unlock();
        return shard.digests.contains(digest);
    }

    fn shardFor(self: *Index, digest: cas.Digest) *Shard {
        return &self.shards[digest.hash[0]];
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
