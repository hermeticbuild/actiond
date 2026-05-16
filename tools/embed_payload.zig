const std = @import("std");
const actiond = @import("actiond");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.Usage;

    var payloads: std.ArrayListUnmanaged(actiond.embedded_payload.PayloadSpec) = .empty;
    defer payloads.deinit(arena);

    for (args[3..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.Usage;
        if (eq == 0 or eq + 1 >= arg.len) return error.Usage;
        try payloads.append(arena, .{
            .name = arg[0..eq],
            .path = arg[eq + 1 ..],
        });
    }

    try actiond.embedded_payload.appendPayloads(
        io,
        std.heap.smp_allocator,
        args[1],
        args[2],
        payloads.items,
    );
}
