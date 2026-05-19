const std = @import("std");
const absolute = @import("absolute_final");

pub const default_manifold_bytes: usize = absolute.AbsoluteCore.ManifoldSize * @sizeOf(u64);

pub const Options = struct {
    state_path: []const u8 = absolute.AbsoluteCore.DefaultStatePath,
    size_bytes: usize = default_manifold_bytes,
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
    anchor_a: []const u8,
    anchor_b: []const u8,
    sequence: usize,

    pub fn activeWord(self: *const Snapshot) []const u8 {
        return self.active_word[0..self.active_word_len];
    }

    pub fn spectralPath(self: *const Snapshot) []const u8 {
        return self.spectral_path[0..self.spectral_path_len];
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

    pub fn explain(self: *const SovereignCore, allocator: std.mem.Allocator, thought: []const u8) ![]u8 {
        _ = thought;
        const snap = self.snapshot();
        return try std.fmt.allocPrint(
            allocator,
            "I have reached {s}.\nIn your language, this means the collision of [{s}] and [{s}].",
            .{ snap.activeWord(), snap.anchor_a, snap.anchor_b },
        );
    }
};

pub fn snapshotFromReport(core: absolute.AbsoluteCore, report: absolute.AbsoluteCore.IngestReport, sequence: usize) Snapshot {
    const idx = if (report.writes == 0) 0 else report.dominant_edge & core.address_mask;
    const peak = core.field[idx & core.address_mask];
    var word_buf = [_]u8{0} ** 8;
    const word_len = wordFromPeak(peak ^ report.edge_fingerprint, &word_buf);
    var path_buf = [_]u8{0} ** 96;
    const path_len = spectralPathFromReport(report, peak, &path_buf);
    return .{
        .field_bytes = core.field_count * @sizeOf(u64),
        .field_count = core.field_count,
        .input_bytes = report.bytes,
        .writes = report.writes,
        .peak_index = idx,
        .peak_voxel = peak,
        .dominant_delta = report.dominant_delta,
        .edge_fingerprint = report.edge_fingerprint,
        .resonance_density = densityForVoxel(peak),
        .active_word = word_buf,
        .active_word_len = word_len,
        .spectral_path = path_buf,
        .spectral_path_len = path_len,
        .anchor_a = anchorFromPeak(peak),
        .anchor_b = anchorFromPeak(peak ^ report.edge_fingerprint ^ report.dominant_delta),
        .sequence = sequence,
    };
}

pub fn densityForVoxel(voxel: u64) f64 {
    return @as(f64, @floatFromInt(@popCount(voxel))) / 64.0;
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
    };
    return anchors[@as(usize, @intCast((peak >> 20) & 0xF))];
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
            "Field Bytes: {d}\n" ++
            "Writes: {d}\n",
        .{
            snap.peak_voxel,
            snap.resonance_density,
            snap.activeWord(),
            snap.spectralPath(),
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
