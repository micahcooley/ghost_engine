const std = @import("std");

pub fn main() !void {
    const file = try std.fs.cwd().openFile("platforms/linux/x86_64/state/shards/core/core/rune_ranks.bin", .{});
    defer file.close();
    
    var buf: [524288]u8 = undefined;
    const len = try file.readAll(&buf);
    
    var found: usize = 0;
    for (buf[0..len], 0..) |rank, i| {
        if (rank != 0) {
            std.debug.print("Slot {d}: Rank {d}\n", .{i, rank});
            found += 1;
        }
    }
    std.debug.print("Total Non-Noise Slots: {d}\n", .{found});
}
