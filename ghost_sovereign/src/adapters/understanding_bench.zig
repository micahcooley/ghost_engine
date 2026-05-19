const std = @import("std");
const absolute = @import("absolute_final");

const ConceptPair = struct { a: []const u8, b: []const u8 };

const related_pairs = [_]ConceptPair{
    .{ .a = "gravity", .b = "mass" },
    .{ .a = "star", .b = "planet" },
    .{ .a = "dog", .b = "animal" },
    .{ .a = "red", .b = "color" },
    .{ .a = "fire", .b = "heat" },
    .{ .a = "water", .b = "liquid" },
    .{ .a = "book", .b = "page" },
    .{ .a = "sun", .b = "day" },
    .{ .a = "moon", .b = "night" },
    .{ .a = "tree", .b = "forest" },
    .{ .a = "car", .b = "wheel" },
    .{ .a = "apple", .b = "fruit" },
    .{ .a = "doctor", .b = "patient" },
    .{ .a = "river", .b = "flow" },
    .{ .a = "bird", .b = "fly" },
    .{ .a = "ocean", .b = "wave" },
    .{ .a = "mountain", .b = "peak" },
    .{ .a = "snow", .b = "cold" },
    .{ .a = "music", .b = "song" },
    .{ .a = "light", .b = "bulb" },
    .{ .a = "baby", .b = "child" },
    .{ .a = "key", .b = "lock" },
    .{ .a = "bread", .b = "wheat" },
    .{ .a = "horse", .b = "saddle" },
    .{ .a = "gun", .b = "bullet" },
    .{ .a = "pen", .b = "write" },
    .{ .a = "bee", .b = "honey" },
    .{ .a = "shoe", .b = "foot" },
    .{ .a = "door", .b = "room" },
    .{ .a = "window", .b = "glass" },
    .{ .a = "clock", .b = "time" },
    .{ .a = "map", .b = "direction" },
    .{ .a = "piano", .b = "music" },
    .{ .a = "pencil", .b = "draw" },
    .{ .a = "rain", .b = "wet" },
    .{ .a = "desert", .b = "sand" },
    .{ .a = "knife", .b = "cut" },
    .{ .a = "table", .b = "chair" },
    .{ .a = "forest", .b = "leaf" },
    .{ .a = "bear", .b = "cave" },
    .{ .a = "cow", .b = "milk" },
    .{ .a = "chicken", .b = "egg" },
    .{ .a = "knee", .b = "leg" },
    .{ .a = "ankle", .b = "foot" },
    .{ .a = "eye", .b = "vision" },
    .{ .a = "ear", .b = "sound" },
    .{ .a = "nose", .b = "smell" },
    .{ .a = "mouth", .b = "taste" },
    .{ .a = "hand", .b = "finger" },
    .{ .a = "heart", .b = "blood" },
    .{ .a = "brain", .b = "thought" },
    .{ .a = "lung", .b = "breath" },
    .{ .a = "stomach", .b = "food" },
    .{ .a = "skin", .b = "touch" },
    .{ .a = "bone", .b = "skeleton" },
    .{ .a = "tongue", .b = "lick" },
    .{ .a = "ship", .b = "sea" },
    .{ .a = "engine", .b = "motor" },
    .{ .a = "cup", .b = "coffee" },
    .{ .a = "spoon", .b = "soup" },
    .{ .a = "fork", .b = "pasta" },
    .{ .a = "plate", .b = "dinner" },
    .{ .a = "pan", .b = "cook" },
    .{ .a = "oven", .b = "bake" },
    .{ .a = "fridge", .b = "cold" },
    .{ .a = "ice", .b = "freeze" },
    .{ .a = "smoke", .b = "fire" },
    .{ .a = "ash", .b = "burn" },
    .{ .a = "candle", .b = "wax" },
    .{ .a = "match", .b = "spark" },
    .{ .a = "hammer", .b = "nail" },
    .{ .a = "saw", .b = "wood" },
    .{ .a = "drill", .b = "hole" },
    .{ .a = "screw", .b = "twist" },
    .{ .a = "bolt", .b = "nut" },
    .{ .a = "chain", .b = "link" },
    .{ .a = "rope", .b = "knot" },
    .{ .a = "net", .b = "fish" },
    .{ .a = "hook", .b = "bait" },
    .{ .a = "boat", .b = "row" },
    .{ .a = "sail", .b = "wind" },
    .{ .a = "anchor", .b = "harbor" },
    .{ .a = "shore", .b = "beach" },
    .{ .a = "cliff", .b = "fall" },
    .{ .a = "valley", .b = "low" },
    .{ .a = "hill", .b = "climb" },
    .{ .a = "summit", .b = "top" },
    .{ .a = "cave", .b = "dark" },
    .{ .a = "tunnel", .b = "underground" },
};

const overlap_pairs = [_]ConceptPair{
    .{ .a = "gravity", .b = "granite" },
    .{ .a = "star", .b = "stare" },
    .{ .a = "star", .b = "starch" },
    .{ .a = "car", .b = "card" },
    .{ .a = "car", .b = "carbon" },
    .{ .a = "cat", .b = "cap" },
    .{ .a = "cat", .b = "cane" },
    .{ .a = "cat", .b = "case" },
    .{ .a = "dog", .b = "does" },
    .{ .a = "red", .b = "read" },
    .{ .a = "red", .b = "reed" },
    .{ .a = "moon", .b = "mood" },
    .{ .a = "moon", .b = "moor" },
    .{ .a = "tree", .b = "trek" },
    .{ .a = "tree", .b = "trend" },
    .{ .a = "sun", .b = "sung" },
    .{ .a = "book", .b = "boot" },
    .{ .a = "book", .b = "boost" },
    .{ .a = "fire", .b = "firm" },
    .{ .a = "fire", .b = "first" },
    .{ .a = "water", .b = "wafer" },
    .{ .a = "water", .b = "wager" },
    .{ .a = "bird", .b = "birch" },
    .{ .a = "bird", .b = "birth" },
    .{ .a = "horse", .b = "horde" },
    .{ .a = "horse", .b = "horror" },
    .{ .a = "pen", .b = "pet" },
    .{ .a = "pen", .b = "pew" },
    .{ .a = "key", .b = "keg" },
    .{ .a = "gun", .b = "gum" },
    .{ .a = "gun", .b = "gust" },
    .{ .a = "bread", .b = "breed" },
    .{ .a = "bread", .b = "breath" },
    .{ .a = "breath", .b = "breach" },
    .{ .a = "snow", .b = "snore" },
    .{ .a = "snow", .b = "snob" },
    .{ .a = "glass", .b = "glade" },
    .{ .a = "glass", .b = "gland" },
    .{ .a = "glass", .b = "glare" },
    .{ .a = "light", .b = "litmus" },
    .{ .a = "rain", .b = "rang" },
    .{ .a = "rain", .b = "rank" },
    .{ .a = "rain", .b = "range" },
    .{ .a = "bear", .b = "beat" },
    .{ .a = "bear", .b = "bead" },
    .{ .a = "bear", .b = "beak" },
    .{ .a = "knee", .b = "knew" },
    .{ .a = "knife", .b = "knight" },
    .{ .a = "knife", .b = "knit" },
    .{ .a = "mouth", .b = "mound" },
    .{ .a = "mouth", .b = "mourn" },
    .{ .a = "nose", .b = "nosy" },
    .{ .a = "nose", .b = "nominal" },
    .{ .a = "bone", .b = "bond" },
    .{ .a = "bone", .b = "bonus" },
    .{ .a = "hair", .b = "haiku" },
    .{ .a = "hair", .b = "hail" },
    .{ .a = "ship", .b = "shin" },
    .{ .a = "ship", .b = "shift" },
    .{ .a = "ship", .b = "shirt" },
    .{ .a = "engine", .b = "engulf" },
    .{ .a = "engine", .b = "engrave" },
    .{ .a = "bike", .b = "bilk" },
    .{ .a = "bike", .b = "bind" },
    .{ .a = "map", .b = "mar" },
    .{ .a = "map", .b = "mash" },
    .{ .a = "ski", .b = "skim" },
    .{ .a = "ski", .b = "skin" },
    .{ .a = "ski", .b = "skill" },
    .{ .a = "boat", .b = "boast" },
    .{ .a = "boat", .b = "boa" },
    .{ .a = "hill", .b = "hilt" },
    .{ .a = "hill", .b = "hilum" },
    .{ .a = "shore", .b = "shorn" },
    .{ .a = "shore", .b = "short" },
    .{ .a = "candle", .b = "candor" },
    .{ .a = "candle", .b = "candy" },
    .{ .a = "match", .b = "math" },
    .{ .a = "match", .b = "matte" },
    .{ .a = "hammer", .b = "hamper" },
    .{ .a = "drill", .b = "drilling" },
    .{ .a = "rope", .b = "rove" },
    .{ .a = "rope", .b = "rosy" },
    .{ .a = "fork", .b = "form" },
    .{ .a = "fork", .b = "fort" },
    .{ .a = "plate", .b = "plait" },
    .{ .a = "plate", .b = "plait" },
};

fn signatureOf(core: *absolute.AbsoluteCore, prompt: []const u8) u64 {
    core.reset();
    const report = core.ingestMeasured(prompt);
    return core.field[report.dominant_edge];
}

fn hammingPair(core: *absolute.AbsoluteCore, pair: ConceptPair) u8 {
    const sig_a = signatureOf(core, pair.a);
    const sig_b = signatureOf(core, pair.b);
    return @intCast(@popCount(sig_a ^ sig_b));
}

fn meanAndVar(samples: []const u8) struct { mean: f64, variance: f64 } {
    if (samples.len == 0) return .{ .mean = 0, .variance = 0 };
    var sum: f64 = 0;
    for (samples) |s| sum += @floatFromInt(s);
    const mean = sum / @as(f64, @floatFromInt(samples.len));
    var sse: f64 = 0;
    for (samples) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean;
        sse += d * d;
    }
    const variance = if (samples.len > 1)
        sse / @as(f64, @floatFromInt(samples.len - 1))
    else
        0;
    return .{ .mean = mean, .variance = variance };
}

fn erfApprox(x: f64) f64 {
    const a1: f64 = 0.254829592;
    const a2: f64 = -0.284496736;
    const a3: f64 = 1.421413741;
    const a4: f64 = -1.453152027;
    const a5: f64 = 1.061405429;
    const p: f64 = 0.3275911;
    const sign: f64 = if (x < 0.0) -1.0 else 1.0;
    const ax = @abs(x);
    const t = 1.0 / (1.0 + p * ax);
    const poly = ((((a5 * t + a4) * t) + a3) * t + a2) * t + a1;
    const y = 1.0 - poly * t * @exp(-ax * ax);
    return sign * y;
}

fn normalCdf(z: f64) f64 {
    return 0.5 * (1.0 + erfApprox(z / @sqrt(@as(f64, 2.0))));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var state_path: []const u8 = "state/understanding_bench.bin";
    var csv_path: ?[]const u8 = null;

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--state=")) {
            state_path = arg["--state=".len..];
        } else if (std.mem.startsWith(u8, arg, "--csv=")) {
            csv_path = arg["--csv=".len..];
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writer().writeAll(
                \\usage: understanding_bench [--state path] [--csv path]
                \\
                \\Tests whether the manifold clusters concept pairs by meaning
                \\(low Hamming distance for semantic-related pairs) or by
                \\spelling (low Hamming distance for prefix-overlapped pairs).
                \\Reports Welch's t-statistic, p-value, and Cohen's d.
                \\
            );
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    const stdout = std.io.getStdOut().writer();
    var core = try absolute.AbsoluteCore.initAt(state_path, 16 * 1024 * 1024);
    defer core.deinit();

    var related_h = try allocator.alloc(u8, related_pairs.len);
    defer allocator.free(related_h);
    var overlap_h = try allocator.alloc(u8, overlap_pairs.len);
    defer allocator.free(overlap_h);

    for (related_pairs, 0..) |p, i| related_h[i] = hammingPair(&core, p);
    for (overlap_pairs, 0..) |p, i| overlap_h[i] = hammingPair(&core, p);

    const rs = meanAndVar(related_h);
    const os = meanAndVar(overlap_h);

    const n_r: f64 = @floatFromInt(related_pairs.len);
    const n_o: f64 = @floatFromInt(overlap_pairs.len);
    const se = @sqrt(rs.variance / n_r + os.variance / n_o);
    const t_stat = if (se > 0) (rs.mean - os.mean) / se else 0.0;

    const num = rs.variance / n_r + os.variance / n_o;
    const denom = (rs.variance * rs.variance) / (n_r * n_r * (n_r - 1.0)) +
        (os.variance * os.variance) / (n_o * n_o * (n_o - 1.0));
    const df = if (denom > 0) num * num / denom else (n_r + n_o - 2.0);

    const z = t_stat;
    const p_two = 2.0 * (1.0 - normalCdf(@abs(z)));
    const p_related_lower = normalCdf(z);

    const pooled_sd_num = (n_r - 1.0) * rs.variance + (n_o - 1.0) * os.variance;
    const pooled_sd_denom = n_r + n_o - 2.0;
    const pooled_sd = @sqrt(pooled_sd_num / pooled_sd_denom);
    const cohens_d = if (pooled_sd > 0) (rs.mean - os.mean) / pooled_sd else 0;

    try stdout.writeAll("### UNDERSTANDING AUDIT ###\n");
    try stdout.print("related_pairs:           {d}\n", .{related_pairs.len});
    try stdout.print("spelling_overlap_pairs:  {d}\n", .{overlap_pairs.len});
    try stdout.print("signature:               core.field[report.dominant_edge] (u64)\n", .{});
    try stdout.print("metric:                  Hamming(A_sig, B_sig) in [0,64]\n\n", .{});

    try stdout.print("related_mean_hamming:    {d:.4}\n", .{rs.mean});
    try stdout.print("related_variance:        {d:.4}\n", .{rs.variance});
    try stdout.print("overlap_mean_hamming:    {d:.4}\n", .{os.mean});
    try stdout.print("overlap_variance:        {d:.4}\n\n", .{os.variance});

    try stdout.print("welch_t:                 {d:.4}\n", .{t_stat});
    try stdout.print("welch_df (approx):       {d:.2}\n", .{df});
    try stdout.print("p_two_tailed (~normal):  {d:.6}\n", .{p_two});
    try stdout.print("p_one_tailed (R < O):    {d:.6}\n", .{p_related_lower});
    try stdout.print("cohens_d (R - O / sd):   {d:.4}\n\n", .{cohens_d});

    if (csv_path) |path| {
        var csv_file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer csv_file.close();
        var csv_w = csv_file.writer();
        try csv_w.writeAll("class,a,b,hamming\n");
        for (related_pairs, 0..) |p, i| {
            try csv_w.print("related,{s},{s},{d}\n", .{ p.a, p.b, related_h[i] });
        }
        for (overlap_pairs, 0..) |p, i| {
            try csv_w.print("overlap,{s},{s},{d}\n", .{ p.a, p.b, overlap_h[i] });
        }
    }

    try stdout.writeAll("--- V11 ACCEPTANCE ---\n");
    try stdout.writeAll("Criterion: Hamming(related) < Hamming(overlap) AND p_one_tailed < 0.01\n");
    const passes = (rs.mean < os.mean) and (p_related_lower < 0.01);
    if (passes) {
        try stdout.writeAll("RESULT: PASS — manifold clusters concepts by meaning over spelling.\n");
    } else {
        try stdout.writeAll("RESULT: FAIL — the readout does NOT preserve semantic relations under this metric.\n");
        if (rs.mean >= os.mean) {
            try stdout.print("  Direction: spelling-overlap mean ({d:.2}) is LOWER than related mean ({d:.2}).\n", .{ os.mean, rs.mean });
            try stdout.writeAll("  Interpretation: the manifold clusters by byte similarity, not by meaning.\n");
        }
        if (p_related_lower >= 0.01) {
            try stdout.writeAll("  Power: difference is not statistically significant in the V11 direction.\n");
        }
        std.process.exit(2);
    }
}

test "meanAndVar matches known sample" {
    const samples = [_]u8{ 30, 32, 31, 29, 33 };
    const r = meanAndVar(&samples);
    try std.testing.expectApproxEqAbs(@as(f64, 31.0), r.mean, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), r.variance, 1e-9);
}

test "normalCdf is monotone and centered" {
    try std.testing.expect(normalCdf(0) > 0.499 and normalCdf(0) < 0.501);
    try std.testing.expect(normalCdf(1.96) > 0.974);
    try std.testing.expect(normalCdf(-1.96) < 0.026);
}
