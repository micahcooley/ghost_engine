const std = @import("std");
const absolute = @import("absolute_final");
const si = @import("sovereign_interface.zig");

pub const TopK: usize = 3;
pub const AnchorCount: usize = 32;
pub const ConnectorCount: usize = 5;

pub const anchors = [AnchorCount][]const u8{
    "Physics",  "Silence", "Memory",     "Heat",
    "Syntax",   "Void",    "Pressure",   "Symmetry",
    "Light",    "Distance","Constraint", "Motion",
    "Archive",  "Signal",  "Friction",   "Proof",
    "Hardware", "Grammar", "Mind",       "Pulse",
    "Vector",   "Field",   "Name",       "Boundary",
    "Mirror",   "Weight",  "Stone",      "River",
    "Spark",    "Thread",  "Root",       "Weather",
};

pub const connectors = [ConnectorCount][]const u8{
    "and", "of", "from", "creates", "through",
};

pub const Readout = struct {
    neologism: [8]u8,
    neologism_len: usize,
    anchor_indices: [TopK]u8,
    peak_voxels: [TopK]u64,
    peak_indices: [TopK]usize,
    peak_scores: [TopK]u8,
    connector_indices: [TopK - 1]u8,
    edge_fingerprint: u64,
    dominant_delta: u64,

    pub fn anchorName(self: *const Readout, slot: usize) []const u8 {
        return anchors[self.anchor_indices[slot]];
    }

    pub fn connectorName(self: *const Readout, slot: usize) []const u8 {
        return connectors[self.connector_indices[slot]];
    }

    pub fn neologismText(self: *const Readout) []const u8 {
        return self.neologism[0..self.neologism_len];
    }
};

const Candidate = struct {
    score: u8,
    tie: u64,
    voxel: u64,
    index: usize,
};

fn resonanceWord(report: absolute.AbsoluteCore.IngestReport, voxel: u64) u64 {
    return voxel ^ report.edge_fingerprint ^ report.dominant_delta;
}

fn betterThan(a: Candidate, b: Candidate) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.tie > b.tie;
}

pub fn pickTopK(field: []const u64, report: absolute.AbsoluteCore.IngestReport) Readout {
    var per_anchor = [_]Candidate{.{ .score = 0, .tie = 0, .voxel = 0, .index = 0 }} ** AnchorCount;
    var per_anchor_seen = [_]bool{false} ** AnchorCount;

    for (field, 0..) |voxel, idx| {
        const word = resonanceWord(report, voxel);
        const anchor_idx: usize = @intCast((voxel >> 20) & 0x1F);
        const cand = Candidate{
            .score = @intCast(@popCount(word)),
            .tie = word ^ @as(u64, @intCast(idx)),
            .voxel = voxel,
            .index = idx,
        };
        if (!per_anchor_seen[anchor_idx] or betterThan(cand, per_anchor[anchor_idx])) {
            per_anchor[anchor_idx] = cand;
            per_anchor_seen[anchor_idx] = true;
        }
    }

    var slots = [_]Candidate{.{ .score = 0, .tie = 0, .voxel = 0, .index = 0 }} ** TopK;
    var slot_anchors = [_]u8{0} ** TopK;
    var slots_filled: usize = 0;
    for (per_anchor, 0..) |cand, ai| {
        if (!per_anchor_seen[ai]) continue;
        var k: usize = 0;
        while (k < slots_filled) : (k += 1) {
            if (betterThan(cand, slots[k])) break;
        }
        if (k == TopK) continue;
        const fill_end = if (slots_filled < TopK) slots_filled else TopK - 1;
        var shift: usize = fill_end;
        while (shift > k) : (shift -= 1) {
            slots[shift] = slots[shift - 1];
            slot_anchors[shift] = slot_anchors[shift - 1];
        }
        slots[k] = cand;
        slot_anchors[k] = @intCast(ai);
        if (slots_filled < TopK) slots_filled += 1;
    }

    var anchor_indices: [TopK]u8 = undefined;
    var peak_voxels: [TopK]u64 = undefined;
    var peak_indices: [TopK]usize = undefined;
    var peak_scores: [TopK]u8 = undefined;
    for (0..TopK) |k| {
        peak_voxels[k] = slots[k].voxel;
        peak_indices[k] = slots[k].index;
        peak_scores[k] = slots[k].score;
        anchor_indices[k] = slot_anchors[k];
    }

    var connector_indices: [TopK - 1]u8 = undefined;
    for (0..TopK - 1) |k| {
        const dist: u64 = @popCount(peak_voxels[k] ^ peak_voxels[k + 1]);
        const bucket = @min(@as(u64, ConnectorCount - 1), dist >> 4);
        connector_indices[k] = @intCast(bucket);
    }

    var word_buf: [8]u8 = [_]u8{0} ** 8;
    const word_len = si.wordFromPeak(peak_voxels[0] ^ report.edge_fingerprint, &word_buf);

    return .{
        .neologism = word_buf,
        .neologism_len = word_len,
        .anchor_indices = anchor_indices,
        .peak_voxels = peak_voxels,
        .peak_indices = peak_indices,
        .peak_scores = peak_scores,
        .connector_indices = connector_indices,
        .edge_fingerprint = report.edge_fingerprint,
        .dominant_delta = report.dominant_delta,
    };
}

pub fn renderSentence(readout: *const Readout, out: []u8) usize {
    var pos: usize = 0;
    pos += writeInto(out, pos, readout.neologismText());
    pos += writeInto(out, pos, " is ");
    pos += writeInto(out, pos, readout.anchorName(0));
    for (0..TopK - 1) |k| {
        pos += writeInto(out, pos, " ");
        pos += writeInto(out, pos, readout.connectorName(k));
        pos += writeInto(out, pos, " ");
        pos += writeInto(out, pos, readout.anchorName(k + 1));
    }
    pos += writeInto(out, pos, ".");
    return pos;
}

fn writeInto(out: []u8, pos: usize, text: []const u8) usize {
    if (pos >= out.len) return 0;
    const n = @min(text.len, out.len - pos);
    @memcpy(out[pos .. pos + n], text[0..n]);
    return n;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var state_path: []const u8 = absolute.AbsoluteCore.DefaultStatePath;
    var message: []const u8 = "";
    var verbose: bool = false;

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--message=")) {
            message = arg["--message=".len..];
        } else if (std.mem.eql(u8, arg, "--message")) {
            message = args.next() orelse return error.MissingMessage;
        } else if (std.mem.startsWith(u8, arg, "--state=")) {
            state_path = arg["--state=".len..];
        } else if (std.mem.eql(u8, arg, "--state")) {
            state_path = args.next() orelse return error.MissingStatePath;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writer().writeAll(
                \\usage: anchor_readout [--message text] [--state path] [--verbose]
                \\
                \\Ingests the message into a (persistent) AbsoluteCore manifold,
                \\extracts the top-3 resonant anchors, picks Hamming-distance-keyed
                \\connectors, and prints the neologism sentence.
                \\
            );
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    var core = try absolute.AbsoluteCore.initAt(state_path, 16 * 1024 * 1024);
    defer core.deinit();
    const report = if (message.len == 0)
        absolute.AbsoluteCore.IngestReport{}
    else
        core.ingestMeasured(message);

    const readout = pickTopK(core.field, report);
    var sentence_buf: [256]u8 = [_]u8{0} ** 256;
    const sentence_len = renderSentence(&readout, &sentence_buf);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{sentence_buf[0..sentence_len]});

    if (verbose) {
        try stdout.print("  edge_fingerprint: 0x{X}\n", .{readout.edge_fingerprint});
        try stdout.print("  dominant_delta:   0x{X}\n", .{readout.dominant_delta});
        for (0..TopK) |k| {
            try stdout.print(
                "  peak[{d}]: idx={d:>7}  voxel=0x{X:0>16}  score={d:>2}  anchor=[{d:>2}]{s}\n",
                .{ k, readout.peak_indices[k], readout.peak_voxels[k], readout.peak_scores[k], readout.anchor_indices[k], readout.anchorName(k) },
            );
        }
        for (0..TopK - 1) |k| {
            const dist: u64 = @popCount(readout.peak_voxels[k] ^ readout.peak_voxels[k + 1]);
            try stdout.print(
                "  connector[{d}->{d}]: hamming={d:>2}  bucket={d}  word={s}\n",
                .{ k, k + 1, dist, readout.connector_indices[k], readout.connectorName(k) },
            );
        }
    }
}

test "renderSentence produces five tokens around three anchors" {
    const readout = Readout{
        .neologism = [_]u8{ 'M', 'L', 'E', 'H', 0, 0, 0, 0 },
        .neologism_len = 4,
        .anchor_indices = [_]u8{ 0, 1, 7 },
        .peak_voxels = [_]u64{ 0, 0, 0 },
        .peak_indices = [_]usize{ 0, 0, 0 },
        .peak_scores = [_]u8{ 0, 0, 0 },
        .connector_indices = [_]u8{ 1, 4 },
        .edge_fingerprint = 0,
        .dominant_delta = 0,
    };
    var buf: [128]u8 = [_]u8{0} ** 128;
    const n = renderSentence(&readout, &buf);
    try std.testing.expectEqualStrings("MLEH is Physics of Silence through Symmetry.", buf[0..n]);
}

test "pickTopK returns three distinct peaks with monotone scores" {
    const field = try std.testing.allocator.alloc(u64, 4096);
    defer std.testing.allocator.free(field);
    var seed: u64 = 0x9E3779B97F4A7C15;
    for (field) |*v| {
        seed = (seed ^ (seed >> 31)) *% 0x100000001B3;
        v.* = seed;
    }
    const report = absolute.AbsoluteCore.IngestReport{
        .bytes = 0,
        .writes = 0,
        .dominant_edge = 0,
        .dominant_delta = 0xC2B2AE3D27D4EB4F,
        .edge_fingerprint = 0xBE496F1695F15480,
    };
    const readout = pickTopK(field, report);
    try std.testing.expect(readout.peak_scores[0] >= readout.peak_scores[1]);
    try std.testing.expect(readout.peak_scores[1] >= readout.peak_scores[2]);
    try std.testing.expect(readout.peak_indices[0] != readout.peak_indices[1]);
    try std.testing.expect(readout.peak_indices[1] != readout.peak_indices[2]);
    for (readout.anchor_indices) |a| try std.testing.expect(a < AnchorCount);
    for (readout.connector_indices) |c| try std.testing.expect(c < ConnectorCount);
}
