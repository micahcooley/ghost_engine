const std = @import("std");
const absolute = @import("absolute_final");
const ar = @import("anchor_readout.zig");

const trials_per_class: usize = 100;
const smoothing_alpha: f64 = 0.5;

const LabeledPrompt = struct {
    label: []const u8,
    text: []const u8,
};

const prompts = [_]LabeledPrompt{
    .{ .label = "technical-low-level", .text = "Explain the memory layout of a Zig struct with aligned fields." },
    .{ .label = "creative-poetic", .text = "Write a haiku about the silence of a motherboard at night." },
    .{ .label = "math-hard", .text = "Solve for x where 7x^2 + 13x - 5000 = 0 using Diophantine approximation." },
    .{ .label = "typo-adversarial", .text = "hw do i fix teh broken lgc in my asic core??" },
    .{ .label = "instruction-complex", .text = "Refactor the existing Sovereign meta-architecture to use a sharded ring buffer for voxel persistence." },
    .{ .label = "casual-greeting", .text = "Hello, how is the weather in the cloud today?" },
    .{ .label = "system-status", .text = "Report on current manifold resonance and L1 cache utilization." },
    .{ .label = "code-zig", .text = "const std = @import(\"std\"); pub fn main() !void { std.debug.print(\"hello\", .{}); }" },
};

const ClassCounts = struct {
    counts: [ar.AnchorCount]u32,

    pub fn init() ClassCounts {
        return .{ .counts = [_]u32{0} ** ar.AnchorCount };
    }

    pub fn add(self: *ClassCounts, anchor_idx: u8) void {
        self.counts[anchor_idx] += 1;
    }

    pub fn distribution(self: *const ClassCounts, out: *[ar.AnchorCount]f64) void {
        var total: f64 = 0.0;
        for (self.counts) |c| total += @floatFromInt(c);
        const denom = total + smoothing_alpha * @as(f64, @floatFromInt(ar.AnchorCount));
        for (self.counts, 0..) |c, i| {
            out[i] = (@as(f64, @floatFromInt(c)) + smoothing_alpha) / denom;
        }
    }
};

fn klDivergence(p: *const [ar.AnchorCount]f64, q: *const [ar.AnchorCount]f64) f64 {
    var kl: f64 = 0.0;
    for (p, q) |pi, qi| {
        if (pi <= 0.0) continue;
        kl += pi * @log(pi / qi);
    }
    return kl;
}

fn entropy(p: *const [ar.AnchorCount]f64) f64 {
    var h: f64 = 0.0;
    for (p) |pi| {
        if (pi <= 0.0) continue;
        h -= pi * @log(pi);
    }
    return h;
}

fn runTrial(core: *absolute.AbsoluteCore, trial_idx: u32, prompt: []const u8) ar.Readout {
    core.reset();
    var salt_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &salt_bytes, trial_idx, .little);
    _ = core.ingestMeasured(&salt_bytes);
    const report = core.ingestMeasured(prompt);
    return ar.pickTopK(core.field, report);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var state_path: []const u8 = "state/anchor_distribution.bin";
    var csv_path: ?[]const u8 = null;
    var trials = trials_per_class;

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--state=")) {
            state_path = arg["--state=".len..];
        } else if (std.mem.startsWith(u8, arg, "--csv=")) {
            csv_path = arg["--csv=".len..];
        } else if (std.mem.startsWith(u8, arg, "--trials=")) {
            trials = try std.fmt.parseInt(usize, arg["--trials=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writer().writeAll(
                \\usage: anchor_distribution [--state path] [--csv path] [--trials N]
                \\
                \\Runs N trials of each calibration prompt with state perturbation,
                \\collects top-3 anchor picks, and computes pairwise symmetric KL
                \\divergence between prompt-class distributions.
                \\
            );
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("### ANCHOR DISTRIBUTION TEST ###\n", .{});
    try stdout.print("classes: {d}   trials_per_class: {d}   anchors: {d}   smoothing_alpha: {d:.2}\n\n", .{
        prompts.len, trials, ar.AnchorCount, smoothing_alpha,
    });

    var counts: [prompts.len]ClassCounts = undefined;
    for (&counts) |*c| c.* = ClassCounts.init();

    var core = try absolute.AbsoluteCore.initAt(state_path, 16 * 1024 * 1024);
    defer core.deinit();

    var trial: u32 = 0;
    while (trial < trials) : (trial += 1) {
        for (prompts, 0..) |lp, ci| {
            const readout = runTrial(&core, trial, lp.text);
            for (readout.anchor_indices) |a| counts[ci].add(a);
        }
    }

    var distributions: [prompts.len][ar.AnchorCount]f64 = undefined;
    for (counts, 0..) |c, i| c.distribution(&distributions[i]);

    if (csv_path) |path| {
        var csv_file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer csv_file.close();
        var csv_w = csv_file.writer();
        try csv_w.writeAll("class");
        for (ar.anchors) |name| try csv_w.print(",{s}", .{name});
        try csv_w.writeByte('\n');
        for (distributions, 0..) |dist, i| {
            try csv_w.print("{s}", .{prompts[i].label});
            for (dist) |p| try csv_w.print(",{d:.6}", .{p});
            try csv_w.writeByte('\n');
        }
    }

    try stdout.writeAll("Class                | Entropy(nats) | Top-3 anchors\n");
    try stdout.writeAll("---------------------|---------------|----------------------------------------\n");
    for (distributions, 0..) |dist, i| {
        var top = [_]usize{ 0, 0, 0 };
        var top_p = [_]f64{ 0, 0, 0 };
        for (dist, 0..) |p, idx| {
            inline for (0..3) |k| {
                if (p > top_p[k]) {
                    var s: usize = 2;
                    while (s > k) : (s -= 1) {
                        top_p[s] = top_p[s - 1];
                        top[s] = top[s - 1];
                    }
                    top_p[k] = p;
                    top[k] = idx;
                    break;
                }
            }
        }
        try stdout.print("{s: <20} | {d: >13.4} | {s} ({d:.3}), {s} ({d:.3}), {s} ({d:.3})\n", .{
            prompts[i].label,
            entropy(&dist),
            ar.anchors[top[0]], top_p[0],
            ar.anchors[top[1]], top_p[1],
            ar.anchors[top[2]], top_p[2],
        });
    }

    try stdout.writeAll("\nPairwise symmetric KL (nats):\n");
    try stdout.writeAll("                     ");
    for (prompts) |lp| try stdout.print("| {s: <11}", .{lp.label[0..@min(lp.label.len, 11)]});
    try stdout.writeByte('\n');

    var kl_sum: f64 = 0.0;
    var kl_pairs: usize = 0;
    var kl_min: f64 = std.math.inf(f64);
    var kl_max: f64 = 0.0;

    for (distributions, 0..) |row_p, ri| {
        try stdout.print("{s: <20} ", .{prompts[ri].label});
        for (distributions, 0..) |col_p, ci| {
            if (ci == ri) {
                try stdout.print("| {s: <11}", .{"-"});
                continue;
            }
            const kl_ab = klDivergence(&row_p, &col_p);
            const kl_ba = klDivergence(&col_p, &row_p);
            const sym = 0.5 * (kl_ab + kl_ba);
            try stdout.print("| {d: <11.4}", .{sym});
            if (ci > ri) {
                kl_sum += sym;
                kl_pairs += 1;
                if (sym < kl_min) kl_min = sym;
                if (sym > kl_max) kl_max = sym;
            }
        }
        try stdout.writeByte('\n');
    }

    const mean_kl = if (kl_pairs == 0) 0.0 else kl_sum / @as(f64, @floatFromInt(kl_pairs));
    try stdout.writeAll("\n--- SUMMARY ---\n");
    try stdout.print("Pairs evaluated:        {d}\n", .{kl_pairs});
    try stdout.print("Mean pairwise KL (nats): {d:.4}\n", .{mean_kl});
    try stdout.print("Min pairwise KL  (nats): {d:.4}\n", .{kl_min});
    try stdout.print("Max pairwise KL  (nats): {d:.4}\n", .{kl_max});
    try stdout.print("Acceptance target:       >= 0.5000 nats (mean)\n", .{});
    if (mean_kl >= 0.5) {
        try stdout.print("RESULT: PASS — anchor readout discriminates prompt classes.\n", .{});
    } else {
        try stdout.print("RESULT: FAIL — anchor distributions overlap too much; readout is not class-conditional.\n", .{});
    }
}

test "smoothed distribution sums to one" {
    var c = ClassCounts.init();
    c.add(0);
    c.add(0);
    c.add(7);
    var d: [ar.AnchorCount]f64 = undefined;
    c.distribution(&d);
    var total: f64 = 0;
    for (d) |p| total += p;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), total, 1e-9);
}

test "kl divergence is zero for identical distributions" {
    var p: [ar.AnchorCount]f64 = undefined;
    for (&p) |*x| x.* = 1.0 / @as(f64, ar.AnchorCount);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), klDivergence(&p, &p), 1e-9);
}
