const std = @import("std");
const flame = @import("flame");
const void_eng = @import("void");

pub const FluxEngine = struct {
    state: struct {
        chamber: [flame.ChamberCount]i128,
        scar_bank: [flame.ScarCount]u64,
        kernel: u64,
        closure_error: u128,
    },

    pub fn init(seed: u64) FluxEngine {
        var engine = FluxEngine{
            .state = .{
                .chamber = [_]i128{0} ** flame.ChamberCount,
                .scar_bank = [_]u64{0} ** flame.ScarCount,
                .kernel = 0x0F0074D1366FDDE3,
                .closure_error = 0,
            },
        };
        var s = seed ^ engine.state.kernel;
        for (&engine.state.chamber, 0..) |*slot, idx| {
            s = void_eng.splitMix64(s +% @as(u64, @intCast(idx + 1)));
            slot.* = @as(i128, @intCast(s % 4096));
        }
        engine.state.closure_error = closureError(&engine.state.chamber);
        return engine;
    }

    pub fn ingestTextSequence(self: *FluxEngine, seed: u64, text: []const u8, len: usize) void {
        _ = seed; 
        var h = self.state.kernel;
        for (0..len) |idx| {
            const b = text[idx % text.len];
            h = void_eng.splitMix64(h ^ b);
            for (0..flame.ChamberCount) |i| {
                const harmonic = @as(i128, b) * @as(i128, @intCast(i + 1)) * @as(i128, @intCast(i + 2));
                const shift_val = @as(i128, @intCast((h >> @as(u6, @intCast(i * 3))) & 0xFFFF));
                self.state.chamber[i] = (self.state.chamber[i] ^ shift_val) + harmonic;
            }
        }
        self.state.closure_error = closureError(&self.state.chamber);
    }

    pub fn shapeTextPressure(self: *FluxEngine, seed: u64, text: []const u8) void {
        const h = textHash(text) ^ void_eng.splitMix64(seed);
        const base_magnitude = @as(i128, @intCast(3_600_000_000 + (h % 7_200_000_000)));
        for (0..flame.ChamberCount) |i| {
            const phase = (h >> @as(u6, @intCast(i))) & 1;
            const sign: i128 = if (phase == 0) 1 else -1;
            const mag = @divTrunc(base_magnitude, @as(i128, @intCast(i + 1)));
            self.state.chamber[i] += mag * sign;
        }
        self.state.closure_error = closureError(&self.state.chamber);
    }

    pub fn maybeInventText(self: *const FluxEngine, text: []const u8, generation: u32) ?flame.InventionCandidate {
        _ = text; 
        const control_closure = closureError(&self.state.chamber);
        if (control_closure == 0) return null;
        var best: ?flame.InventionCandidate = null;
        const SingularityScar: u64 = 0x2E3C1E0915D7302E;
        const median = calculateMedian(self.state.chamber);
        const FluxBranches = 512; 
        for (0..FluxBranches) |branch| {
            var trial_chamber = self.state.chamber;
            const branch_seed = void_eng.splitMix64(branch);
            for (0..flame.ChamberCount) |i| {
                const gradient = trial_chamber[i] - median;
                const scar_mix = @as(i128, @intCast((SingularityScar >> @as(u6, @intCast(i * 6))) & 0xFFFFFFFF));
                const branch_mix = @as(i128, @intCast((branch_seed >> @as(u6, @intCast(i * 5))) & 0xFFFFFFFF));
                trial_chamber[i] = median - @divTrunc(gradient * 3, 2) + scar_mix ^ branch_mix;
            }
            for (0..150) |pass| {
                for (flame.Laws, 0..) |law, l_idx| {
                    const got = law.ca * trial_chamber[law.a] + law.cb * trial_chamber[law.b];
                    const err = law.t - got;
                    if (err == 0) continue;
                    const perturb = (branch_seed >> @as(u6, @intCast((pass * 7 + l_idx) % 63))) & 7;
                    const denom = law.ca * law.ca + law.cb * law.cb;
                    const da = @divTrunc(err * law.ca, denom);
                    const db = @divTrunc(err * law.cb, denom);
                    const pa = if (perturb == 1) @as(i128, 5) else if (perturb == 2) @as(i128, -5) else @as(i128, 0);
                    const pb = if (perturb == 3) @as(i128, 5) else if (perturb == 4) @as(i128, -5) else @as(i128, 0);
                    trial_chamber[law.a] += @max(-250000000, @min(250000000, da + pa));
                    trial_chamber[law.b] += @max(-250000000, @min(250000000, db + pb));
                }
            }
            const closure_after = closureError(&trial_chamber);
            const required_improvement = (control_closure * 90) / 100;
            if (closure_after + required_improvement >= control_closure) continue;
            const candidate = flame.InventionCandidate{
                .child_mark = self.state.kernel ^ branch_seed,
                .chamber_snapshot = trial_chamber,
                .closure_before = control_closure,
                .closure_after = closure_after,
                .closure_delta = @as(i128, @intCast(closure_after)) - @as(i128, @intCast(control_closure)),
                .scar = SingularityScar ^ branch_seed,
                .trigger_edge = 0,
                .generation = generation,
                .signature = [_]u64{0} ** flame.SignatureWords,
            };
            if (best == null or candidate.closure_after < best.?.closure_after) {
                best = candidate;
            }
        }
        return best;
    }
};

fn closureError(chamber: *const [flame.ChamberCount]i128) u128 {
    var sum: u128 = 0;
    for (flame.Laws) |law| {
        const got = law.ca * chamber[law.a] + law.cb * chamber[law.b];
        sum += @abs(got - law.t);
    }
    return sum;
}

fn calculateMedian(chamber: [flame.ChamberCount]i128) i128 {
    var sorted = chamber;
    for (0..flame.ChamberCount - 1) |i| {
        for (i + 1..flame.ChamberCount) |j| {
            if (sorted[j] < sorted[i]) {
                const temp = sorted[i];
                sorted[i] = sorted[j];
                sorted[j] = temp;
            }
        }
    }
    return sorted[flame.ChamberCount / 2];
}

fn textHash(text: []const u8) u64 {
    var h: u64 = 0x811C9DC5;
    for (text) |b| {
        h = (h ^ @as(u64, b)) *% 0x01000193;
    }
    return h;
}
