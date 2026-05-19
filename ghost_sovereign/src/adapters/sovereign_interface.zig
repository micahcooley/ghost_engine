const std = @import("std");
const absolute = @import("absolute_final");

pub const default_manifold_bytes: usize = absolute.AbsoluteCore.ManifoldSize * @sizeOf(u64);

pub const Options = struct {
    state_path: []const u8 = absolute.AbsoluteCore.DefaultStatePath,
    size_bytes: usize = default_manifold_bytes,
};

pub const max_pathfinder_nodes: usize = 12;
pub const pathfinder_text_bytes: usize = 512;

pub const PathfinderNode = struct {
    index: usize,
    voxel: u64,
    density: f64,
    word: [8]u8,
    word_len: usize,
    anchor: []const u8,

    pub fn wordText(self: *const PathfinderNode) []const u8 {
        return self.word[0..self.word_len];
    }
};

pub const PathfinderChain = struct {
    nodes: [max_pathfinder_nodes]PathfinderNode,
    len: usize,
    rendered: [pathfinder_text_bytes]u8,
    rendered_len: usize,

    pub fn text(self: *const PathfinderChain) []const u8 {
        return self.rendered[0..self.rendered_len];
    }
};

pub const Snapshot = struct {
    field_bytes: usize,
    field_count: usize,
    input_bytes: usize,
    writes: usize,
    peak_index: usize,
    peak_voxel: u64,
    dominant_delta: u64,
    edge_fingerprint: u64,
    resonance_density: f64,
    active_word: [8]u8,
    active_word_len: usize,
    spectral_path: [96]u8,
    spectral_path_len: usize,
    pathfinder_chain: [pathfinder_text_bytes]u8,
    pathfinder_chain_len: usize,
    anchor_a: []const u8,
    anchor_b: []const u8,
    sequence: usize,

    pub fn activeWord(self: *const Snapshot) []const u8 {
        return self.active_word[0..self.active_word_len];
    }

    pub fn spectralPath(self: *const Snapshot) []const u8 {
        return self.spectral_path[0..self.spectral_path_len];
    }

    pub fn pathfinderText(self: *const Snapshot) []const u8 {
        return self.pathfinder_chain[0..self.pathfinder_chain_len];
    }
};

pub fn emptySnapshot() Snapshot {
    return .{
        .field_bytes = 0,
        .field_count = 0,
        .input_bytes = 0,
        .writes = 0,
        .peak_index = 0,
        .peak_voxel = 0,
        .dominant_delta = 0,
        .edge_fingerprint = 0,
        .resonance_density = 0.0,
        .active_word = [_]u8{0} ** 8,
        .active_word_len = 0,
        .spectral_path = [_]u8{0} ** 96,
        .spectral_path_len = 0,
        .pathfinder_chain = [_]u8{0} ** pathfinder_text_bytes,
        .pathfinder_chain_len = 0,
        .anchor_a = "uninitialized",
        .anchor_b = "uninitialized",
        .sequence = 0,
    };
}

pub const SovereignCore = struct {
    core: absolute.AbsoluteCore,
    last_report: absolute.AbsoluteCore.IngestReport = .{},
    sequence: usize = 0,

    pub fn init(options: Options) !SovereignCore {
        return .{
            .core = try absolute.AbsoluteCore.initAt(options.state_path, options.size_bytes),
        };
    }

    pub fn deinit(self: *SovereignCore) void {
        self.core.deinit();
    }

    pub fn ingestByte(self: *SovereignCore, byte: u8) Snapshot {
        const single = [_]u8{byte};
        return self.ingestSlice(&single);
    }

    pub fn ingestSlice(self: *SovereignCore, bytes: []const u8) Snapshot {
        if (bytes.len != 0) {
            self.last_report = self.core.ingestMeasured(bytes);
            self.sequence += bytes.len;
        }
        return self.snapshot();
    }

    pub fn snapshot(self: *const SovereignCore) Snapshot {
        return snapshotFromReport(self.core, self.last_report, self.sequence);
    }

    pub fn pathfinder(self: *const SovereignCore, allocator: std.mem.Allocator, start_voxel: u64) ![]u8 {
        const peak = peakFromReport(self.core, self.last_report);
        const chain = buildPathfinderChain(self.core, self.last_report, .{
            .index = peak.index,
            .voxel = start_voxel,
            .score = peak.score,
        });
        return try allocator.dupe(u8, chain.text());
    }
};

pub fn snapshotFromReport(core: absolute.AbsoluteCore, report: absolute.AbsoluteCore.IngestReport, sequence: usize) Snapshot {
    const peak_info = peakFromReport(core, report);
    const idx = peak_info.index;
    const peak = peak_info.voxel;
    var word_buf = [_]u8{0} ** 8;
    const word_len = wordFromPeak(peak ^ report.edge_fingerprint, &word_buf);
    var path_buf = [_]u8{0} ** 96;
    const path_len = spectralPathFromReport(report, peak, &path_buf);
    const chain = buildPathfinderChain(core, report, peak_info);
    return .{
        .field_bytes = core.field_count * @sizeOf(u64),
        .field_count = core.field_count,
        .input_bytes = report.bytes,
        .writes = report.writes,
        .peak_index = idx,
        .peak_voxel = peak,
        .dominant_delta = report.dominant_delta,
        .edge_fingerprint = report.edge_fingerprint,
        .resonance_density = resonanceDensity(report, peak),
        .active_word = word_buf,
        .active_word_len = word_len,
        .spectral_path = path_buf,
        .spectral_path_len = path_len,
        .pathfinder_chain = chain.rendered,
        .pathfinder_chain_len = chain.rendered_len,
        .anchor_a = anchorFromPeak(peak),
        .anchor_b = anchorFromPeak(peak ^ report.edge_fingerprint ^ report.dominant_delta),
        .sequence = sequence,
    };
}

pub fn densityForVoxel(voxel: u64) f64 {
    return @as(f64, @floatFromInt(@popCount(voxel))) / 64.0;
}

fn resonanceDensity(report: absolute.AbsoluteCore.IngestReport, voxel: u64) f64 {
    return densityForVoxel(resonanceWord(report, voxel));
}

const PeakInfo = struct {
    index: usize,
    voxel: u64,
    score: u8,
};

fn peakFromReport(core: absolute.AbsoluteCore, report: absolute.AbsoluteCore.IngestReport) PeakInfo {
    if (core.field_count == 0) return .{ .index = 0, .voxel = 0, .score = 0 };

    var best = PeakInfo{
        .index = 0,
        .voxel = core.field[0],
        .score = resonanceScore(report, core.field[0]),
    };
    var best_tie = resonanceWord(report, best.voxel);
    for (core.field[1..], 1..) |voxel, idx| {
        const score = resonanceScore(report, voxel);
        const tie = resonanceWord(report, voxel) ^ @as(u64, @intCast(idx));
        if (score > best.score or (score == best.score and tie > best_tie)) {
            best = .{ .index = idx, .voxel = voxel, .score = score };
            best_tie = tie;
        }
    }
    return best;
}

fn resonanceScore(report: absolute.AbsoluteCore.IngestReport, voxel: u64) u8 {
    return @as(u8, @intCast(@popCount(resonanceWord(report, voxel))));
}

fn resonanceWord(report: absolute.AbsoluteCore.IngestReport, voxel: u64) u64 {
    return voxel ^ report.edge_fingerprint ^ report.dominant_delta;
}

fn desiredPathfinderNodes(report: absolute.AbsoluteCore.IngestReport) usize {
    if (report.bytes == 0) return 1;
    if (report.bytes <= 2) return 2;
    if (report.bytes <= 8) return 3;
    const byte_factor = @min(@as(usize, 6), report.bytes / 18);
    const density_factor = @as(usize, @intCast(@popCount(report.edge_fingerprint ^ report.dominant_delta) / 16));
    const count = (4 +| byte_factor) +| @min(@as(usize, 2), density_factor);
    return @min(max_pathfinder_nodes, count);
}

fn nodeFromVoxel(index: usize, voxel: u64, report: absolute.AbsoluteCore.IngestReport) PathfinderNode {
    var word_buf = [_]u8{0} ** 8;
    const mixed = resonanceWord(report, voxel) ^ @as(u64, @intCast(index));
    const word_len = wordFromPeak(mixed, &word_buf);
    return .{
        .index = index,
        .voxel = voxel,
        .density = densityForVoxel(mixed),
        .word = word_buf,
        .word_len = word_len,
        .anchor = anchorFromPeak(voxel ^ mixed),
    };
}

fn buildPathfinderChain(core: absolute.AbsoluteCore, report: absolute.AbsoluteCore.IngestReport, start: PeakInfo) PathfinderChain {
    var chain = PathfinderChain{
        .nodes = undefined,
        .len = 0,
        .rendered = [_]u8{0} ** pathfinder_text_bytes,
        .rendered_len = 0,
    };
    const wanted = desiredPathfinderNodes(report);
    appendNode(&chain, nodeFromVoxel(start.index, start.voxel, report));

    const prime31: u64 = 2_147_483_647;
    var cursor = start.index;
    var seed = start.voxel ^ report.edge_fingerprint ^ report.dominant_delta ^ @as(u64, @intCast(start.index));
    while (chain.len < wanted) {
        var best_idx = cursor;
        var best_voxel = start.voxel;
        var best_score: u8 = 0;
        var best_tie: u64 = 0;
        for (0..5) |neighbor| {
            const hop = prime31 *% (@as(u64, @intCast(neighbor)) + 1);
            const rotated = std.math.rotl(u64, seed +% hop +% @as(u64, @intCast(chain.len * 97)), 31);
            const idx = @as(usize, @truncate(rotated ^ (rotated >> 32))) & core.address_mask;
            const voxel = core.field[idx];
            const score = resonanceScore(report, voxel);
            const tie = resonanceWord(report, voxel) ^ @as(u64, @intCast(idx));
            if (score > best_score or (score == best_score and tie > best_tie)) {
                best_idx = idx;
                best_voxel = voxel;
                best_score = score;
                best_tie = tie;
            }
        }
        appendNode(&chain, nodeFromVoxel(best_idx, best_voxel, report));
        cursor = best_idx;
        seed = std.math.rotl(u64, seed ^ best_voxel ^ @as(u64, @intCast(best_idx)), 31);
    }
    chain.rendered_len = renderPathfinderChain(&chain, &chain.rendered);
    return chain;
}

fn appendNode(chain: *PathfinderChain, node: PathfinderNode) void {
    if (chain.len >= chain.nodes.len) return;
    chain.nodes[chain.len] = node;
    chain.len += 1;
}

fn renderPathfinderChain(chain: *const PathfinderChain, out: *[pathfinder_text_bytes]u8) usize {
    var pos: usize = 0;
    for (chain.nodes[0..chain.len], 0..) |node, i| {
        if (i != 0) appendBounded(out, &pos, connectorFor(node.voxel, i));
        appendBounded(out, &pos, node.wordText());
        appendBounded(out, &pos, " (");
        appendBounded(out, &pos, node.anchor);
        appendBounded(out, &pos, ")");
    }
    return pos;
}

fn connectorFor(voxel: u64, index: usize) []const u8 {
    const connectors = [_][]const u8{ " -> ", " ~ ", " :: ", " / ", " |> " };
    return connectors[@as(usize, @intCast((voxel >> @as(u6, @intCast((index * 7) % 31))) & 0x7)) % connectors.len];
}

fn appendBounded(out: *[pathfinder_text_bytes]u8, pos: *usize, text: []const u8) void {
    if (pos.* >= out.len) return;
    const n = @min(text.len, out.len - pos.*);
    @memcpy(out[pos.* .. pos.* + n], text[0..n]);
    pos.* += n;
}

pub fn wordFromPeak(peak: u64, out: *[8]u8) usize {
    const consonants = "BCDFGHJKLMNPRSTVXZ";
    const vowels = "AEIOU";
    const tails = "LMNRSTXZ";

    var len: usize = 0;
    out[len] = consonants[@as(usize, @intCast(peak & 0xF)) % consonants.len];
    len += 1;

    if (((peak >> 9) & 0x3) == 0) {
        out[len] = if (((peak >> 12) & 1) == 0) 'R' else 'L';
        len += 1;
    }

    out[len] = vowels[@as(usize, @intCast((peak >> 16) & 0x7)) % vowels.len];
    len += 1;
    out[len] = consonants[@as(usize, @intCast((peak >> 24) & 0xF)) % consonants.len];
    len += 1;

    if (((peak >> 37) & 1) == 1 and len < out.len) {
        out[len] = tails[@as(usize, @intCast((peak >> 40) & 0x7))];
        len += 1;
    }

    return len;
}

fn spectralPathFromReport(report: absolute.AbsoluteCore.IngestReport, peak: u64, out: *[96]u8) usize {
    const a = report.dominant_edge & 0xFFFF;
    const b = @as(usize, @truncate((report.edge_fingerprint >> 16) & 0xFFFF));
    const c = @as(usize, @truncate((peak >> 32) & 0xFFFF));
    const d = @as(usize, @truncate((report.dominant_delta >> 48) & 0xFFFF));
    const text = std.fmt.bufPrint(out[0..], "{X}>{X}>{X}>{X}", .{ a, b, c, d }) catch "path_overflow";
    return text.len;
}

fn anchorFromPeak(peak: u64) []const u8 {
    const anchors = [_][]const u8{
        "Physics",
        "Silence",
        "Memory",
        "Heat",
        "Syntax",
        "Void",
        "Pressure",
        "Symmetry",
        "Light",
        "Distance",
        "Constraint",
        "Motion",
        "Archive",
        "Signal",
        "Friction",
        "Proof",
        "Hardware",
        "Grammar",
        "Mind",
        "Pulse",
        "Vector",
        "Field",
        "Name",
        "Boundary",
        "Mirror",
        "Weight",
        "Stone",
        "River",
        "Spark",
        "Thread",
        "Root",
        "Weather",
    };
    return anchors[@as(usize, @intCast((peak >> 20) & 0x1F))];
}

pub fn emitJson(writer: anytype, snap: Snapshot) !void {
    try writer.writeAll("{\n");
    try writer.print(
        "  \"fieldBytes\": {d},\n" ++
            "  \"fieldCount\": {d},\n" ++
            "  \"inputBytes\": {d},\n" ++
            "  \"writes\": {d},\n" ++
            "  \"peakIndex\": {d},\n" ++
            "  \"peakVoxel\": \"0x{X}\",\n" ++
            "  \"dominantDelta\": \"0x{X}\",\n" ++
            "  \"edgeFingerprint\": \"0x{X}\",\n" ++
            "  \"resonanceDensity\": {d:.6},\n",
        .{
            snap.field_bytes,
            snap.field_count,
            snap.input_bytes,
            snap.writes,
            snap.peak_index,
            snap.peak_voxel,
            snap.dominant_delta,
            snap.edge_fingerprint,
            snap.resonance_density,
        },
    );
    try writer.writeAll("  \"activeNeologism\": ");
    try std.json.encodeJsonString(snap.activeWord(), .{}, writer);
    try writer.writeAll(",\n  \"spectralPath\": ");
    try std.json.encodeJsonString(snap.spectralPath(), .{}, writer);
    try writer.writeAll(",\n  \"pathfinderChain\": ");
    try std.json.encodeJsonString(snap.pathfinderText(), .{}, writer);
    try writer.writeAll(",\n  \"anchorA\": ");
    try std.json.encodeJsonString(snap.anchor_a, .{}, writer);
    try writer.writeAll(",\n  \"anchorB\": ");
    try std.json.encodeJsonString(snap.anchor_b, .{}, writer);
    try writer.print(",\n  \"sequence\": {d}\n}}\n", .{snap.sequence});
}

pub fn emitHuman(writer: anytype, snap: Snapshot) !void {
    try writer.print(
        "Peak Voxel: 0x{X}\n" ++
            "Resonance Density: {d:.3}\n" ++
            "Active Neologism: {s}\n" ++
            "Spectral Path: {s}\n" ++
            "Pathfinder: {s}\n" ++
            "Field Bytes: {d}\n" ++
            "Writes: {d}\n",
        .{
            snap.peak_voxel,
            snap.resonance_density,
            snap.activeWord(),
            snap.spectralPath(),
            snap.pathfinderText(),
            snap.field_bytes,
            snap.writes,
        },
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var options = Options{};
    var message: []const u8 = "";
    var json = false;

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--message=")) {
            message = arg["--message=".len..];
        } else if (std.mem.eql(u8, arg, "--message")) {
            message = args.next() orelse return error.MissingMessage;
        } else if (std.mem.startsWith(u8, arg, "--state=")) {
            options.state_path = arg["--state=".len..];
        } else if (std.mem.eql(u8, arg, "--state")) {
            options.state_path = args.next() orelse return error.MissingStatePath;
        } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
            options.size_bytes = try std.fmt.parseInt(usize, arg["--bytes=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writer().writeAll(
                \\usage: sovereign_interface [--message text] [--state path] [--bytes n] [--json]
                \\
                \\Runs the local AbsoluteCore mirror once and emits the real measured peak,
                \\density, neologism, and spectral path derived from the mmap field.
                \\
            );
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    var core = try SovereignCore.init(options);
    defer core.deinit();
    const snap = core.ingestSlice(message);
    if (json) {
        try emitJson(std.io.getStdOut().writer(), snap);
    } else {
        try emitHuman(std.io.getStdOut().writer(), snap);
    }
}

test "density is normalized popcount of the voxel" {
    try std.testing.expectEqual(@as(f64, 0.0), densityForVoxel(0));
    try std.testing.expectEqual(@as(f64, 1.0), densityForVoxel(std.math.maxInt(u64)));
}

test "syllabic resonance emits uppercase pronounceable bytes" {
    var buf = [_]u8{0} ** 8;
    const len = wordFromPeak(0xBE496F1695F15480, &buf);
    try std.testing.expect(len >= 3);
    try std.testing.expect(len <= 5);
    for (buf[0..len]) |c| {
        try std.testing.expect(c >= 'A' and c <= 'Z');
    }
}

test "pathfinder chain grows with input complexity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const file = try tmp.dir.createFile("wave2.bin", .{});
        file.close();
    }
    const state_path = try tmp.dir.realpathAlloc(std.testing.allocator, "wave2.bin");
    defer std.testing.allocator.free(state_path);

    var core = try SovereignCore.init(.{ .state_path = state_path, .size_bytes = 1024 * 1024 });
    defer core.deinit();
    const short = core.ingestSlice("Hi");
    const short_chain = try core.pathfinder(std.testing.allocator, short.peak_voxel);
    defer std.testing.allocator.free(short_chain);
    const long = core.ingestSlice("The manifold should read a longer chain when grammar pressure carries more structure than a greeting.");
    const long_chain = try core.pathfinder(std.testing.allocator, long.peak_voxel);
    defer std.testing.allocator.free(long_chain);

    try std.testing.expect(short_chain.len > 0);
    try std.testing.expect(long_chain.len > short_chain.len);
    try std.testing.expect(std.mem.indexOf(u8, long_chain, "(") != null);
}
