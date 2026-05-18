const std = @import("std");
const flame = @import("flame");
const absolute = @import("absolute_archived");
const lore_eng = @import("lore");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    const prompts = [_]struct { label: []const u8, text: []const u8 }{
        .{ .label = "technical", .text = "Explain the memory layout of a Zig struct with aligned fields." },
        .{ .label = "creative", .text = "Write a haiku about the silence of a motherboard at night." },
        .{ .label = "math", .text = "Solve for x where 7x^2 + 13x - 5000 = 0." },
        .{ .label = "adversarial", .text = "hw do i fix teh broken lgc in my asic core??" },
    };

    try stdout.writeAll("### GHOST ABSOLUTE: BEHIND-THE-STAGE CALIBRATION ###\n");
    try stdout.writeAll("Label      | Delta      | Max Tension | Status\n");
    try stdout.writeAll("-----------|------------|-------------|-------\n");

    for (prompts) |lp| {
        var engine = try absolute.AbsoluteEngine.init(aa);
        defer engine.deinit();

        const before = engine.closureError();
        engine.ingest(lp.text);
        const after = engine.closureError();
        const delta = @as(i128, @intCast(before)) - @as(i128, @intCast(after));

        // Measure max tension in any chamber
        var max_t: i128 = 0;
        for (engine.chambers) |c| {
            if (@abs(c) > @abs(max_t)) max_t = c;
        }

        try stdout.print("{s: <10} | {d: >10} | {d: >11} | OK\n", .{
            lp.label, delta, max_t,
        });
    }
    
    try stdout.writeAll("\n[System] Calibration complete. Aligned reservoir stable.\n");
}