const std = @import("std");
const ghost_core = @import("ghost_core");
const hv = ghost_core.phase2_hypervector;
const lattice = ghost_core.phase2_vulkan;

const MAX_POINTS: usize = 100;

const Point = struct {
    label: []const u8,
    x: f32,
    y: f32,
    z: f32,
    coherence: f32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const csv = args.len > 1 and std.mem.eql(u8, args[1], "--csv");
    var points = try generatePoints(allocator);
    defer points.deinit();
    if (csv) {
        try writeCsv(std.io.getStdOut().writer(), points.items);
    } else {
        try writeJson(std.io.getStdOut().writer(), points.items);
    }
}

fn generatePoints(allocator: std.mem.Allocator) !std.ArrayList(Point) {
    var out = std.ArrayList(Point).init(allocator);
    errdefer out.deinit();
    const anchors = [_]struct { label: []const u8, seed: u64 }{
        .{ .label = "warm_tape_saturation", .seed = 0x7461_7065 },
        .{ .label = "digital_distortion", .seed = 0x6469_7374 },
        .{ .label = "clean_gain", .seed = 0x6761_696e },
        .{ .label = "soft_clip", .seed = 0x636c_6970 },
    };
    const gate = lattice.stageGate(MAX_POINTS);
    _ = gate;
    var idx: usize = 0;
    while (idx < MAX_POINTS) : (idx += 1) {
        const anchor = anchors[idx % anchors.len];
        const vec = hv.deterministic(anchor.seed + idx);
        const x_word = vec.lanes[0] ^ vec.lanes[3];
        const y_word = vec.lanes[1] ^ vec.lanes[5];
        const z_word = vec.lanes[2] ^ vec.lanes[7];
        const neighbor = hv.deterministic(anchor.seed + ((idx + 1) % MAX_POINTS));
        try out.append(.{
            .label = anchor.label,
            .x = unitCoord(x_word),
            .y = unitCoord(y_word),
            .z = unitCoord(z_word),
            .coherence = hv.similarity(vec, neighbor),
        });
    }
    return out;
}

fn unitCoord(word: u64) f32 {
    const sample: u32 = @truncate(word >> 40);
    return (@as(f32, @floatFromInt(sample)) / @as(f32, @floatFromInt(std.math.maxInt(u24)))) * 2.0 - 1.0;
}

fn writeJson(writer: anytype, points: []const Point) !void {
    try writer.writeAll("{\"status\":\"ok\",\"latticeView\":{\"pointCount\":");
    try writer.print("{d}", .{points.len});
    try writer.writeAll(",\"points\":[");
    for (points, 0..) |point, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"label\":");
        try std.json.stringify(point.label, .{}, writer);
        try writer.print(",\"x\":{d:.6},\"y\":{d:.6},\"z\":{d:.6},\"coherence\":{d:.6}", .{ point.x, point.y, point.z, point.coherence });
        try writer.writeByte('}');
    }
    try writer.writeAll("]}}");
}

fn writeCsv(writer: anytype, points: []const Point) !void {
    try writer.writeAll("label,x,y,z,coherence\n");
    for (points) |point| {
        try writer.print("{s},{d:.6},{d:.6},{d:.6},{d:.6}\n", .{ point.label, point.x, point.y, point.z, point.coherence });
    }
}

test "lattice view exports one hundred points" {
    var points = try generatePoints(std.testing.allocator);
    defer points.deinit();
    try std.testing.expectEqual(@as(usize, 100), points.items.len);
}
