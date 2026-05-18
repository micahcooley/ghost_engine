const std = @import("std");
const flame = @import("flame.zig");

pub const VoidEngine = struct {
    state: flame.FlameState,

    pub fn init(seed: u64) VoidEngine {
        return .{
            .state = flame.FlameState.init(seed),
        };
    }

    pub fn ingestTextSequence(self: *VoidEngine, seed: u64, text: []const u8, len: usize) void {
        _ = seed;
        var h = self.state.kernel;
        for (0..len) |idx| {
            const b = text[idx % text.len];
            h = flame.splitMix64(h ^ b ^ idx);
            // Sparse routing: each character touches 8 chambers determined by hash.
            // Contribution is bounded (+/-b), so chamber values stay in the same
            // scale as the law targets and different prompts trigger different laws.
            var rh = h;
            for (0..8) |_| {
                rh = flame.splitMix64(rh);
                const chamber_idx = rh % flame.ChamberCount;
                const sign: i128 = if (rh & (1 << 63) == 0) 1 else -1;
                self.state.chamber[chamber_idx] += @as(i128, b) * sign;
            }
            h = rh;
        }
        self.state.closure_error = flame.closureError(&self.state);
    }
    
    pub fn ingestSequence(self: *VoidEngine, seed: u64, len: usize) void {
        var h = seed ^ self.state.kernel;
        for (0..len) |idx| {
            h = flame.splitMix64(h ^ @as(u64, @intCast(idx)));
            for (0..flame.ChamberCount) |i| {
                const shift_val = @as(i128, @intCast((h >> @as(u6, @intCast(i * 3 % 60))) & 0xFFFF));
                self.state.chamber[i] = (self.state.chamber[i] ^ shift_val) + @as(i128, @intCast(h % 2048));
            }
        }
        self.state.closure_error = flame.closureError(&self.state);
    }

    pub fn shapeTextPressure(self: *VoidEngine, seed: u64, text: []const u8) void {
        const h = flame.textHash(text) ^ flame.splitMix64(seed);
        const base_magnitude = @as(i128, @intCast(12_600_000_000 + (h % 24_200_000_000)));
        for (0..flame.ChamberCount) |i| {
            const phase = (h >> @as(u6, @intCast(i % 60))) & 1;
            const sign: i128 = if (phase == 0) 1 else -1;
            const mag = @divTrunc(base_magnitude, @as(i128, @intCast(i + 1)));
            self.state.chamber[i] += mag * sign;
        }
        self.state.scar_bank[h % flame.ScarCount] ^= flame.splitMix64(h ^ 0x0DE7E4B4E9B4D825);
        self.state.closure_error = flame.closureError(&self.state);
    }

    pub fn maybeInventText(self: *const VoidEngine, text: []const u8, generation: u32) ?flame.InventionCandidate {
        const control_closure = flame.closureError(&self.state);
        if (control_closure == 0) return null;
        var best: ?flame.InventionCandidate = null;
        const context_hash = flame.textHash(text);
        const state_fingerprint = residualFingerprint(&self.state) ^ context_hash;
        const NullScar: u64 = 0x3563447E3EBAEF14;
        const median = calculateMedian(&self.state);
        const VoidBranches = 256; 
        for (0..VoidBranches) |branch| {
            var trial = self.state;
            const branch_seed = flame.splitMix64(state_fingerprint ^ branch ^ generation);
            for (0..flame.ChamberCount) |i| {
                const gradient = trial.chamber[i] - median;
                const scar_mix = @as(i128, @intCast((NullScar >> @as(u6, @intCast(i * 6 % 60))) & 0xFFFFFFFF));
                const branch_mix = @as(i128, @intCast((branch_seed >> @as(u6, @intCast(i * 5 % 60))) & 0xFFFFFFFF));
                trial.chamber[i] = median - @divTrunc(gradient * 2, 1) + scar_mix ^ branch_mix;
            }
            for (0..500) |pass| {
                for (flame.Laws) |law| {
                    const got = law.ca * trial.chamber[law.a] + law.cb * trial.chamber[law.b];
                    const err = law.t - got;
                    if (err == 0) continue;
                    const denom = law.ca * law.ca + law.cb * law.cb;
                    if (denom == 0) continue;
                    
                    // ASYMPTOTIC DAMPENING: Mark 0x250E9228E4F5F2DB
                    // We reduce the update magnitude as passes increase to ensure convergence.
                    const dampener = @as(i128, @intCast(1 + (pass / 10)));
                    const da = @divTrunc(err * law.ca, denom * dampener);
                    const db = @divTrunc(err * law.cb, denom * dampener);
                    
                    // SAFETY CLAMPS: Prevent integer overflow panics
                    trial.chamber[law.a] += @max(-1_000_000_000_000, @min(1_000_000_000_000, da));
                    trial.chamber[law.b] += @max(-1_000_000_000_000, @min(1_000_000_000_000, db));
                }
            }
            const closure_after = flame.closureError(&trial);
            const required_improvement = (control_closure * 99) / 100;
            if (closure_after + required_improvement >= control_closure) continue;
            const candidate = flame.InventionCandidate{
                .child_mark = self.state.kernel ^ branch_seed,
                .chamber_snapshot = trial.chamber,
                .closure_before = control_closure,
                .closure_after = closure_after,
                .closure_delta = @as(i128, @intCast(closure_after)) - @as(i128, @intCast(control_closure)),
                .scar = NullScar ^ branch_seed,
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

fn calculateMedian(state: *const flame.FlameState) i128 {
    var sorted: [flame.ChamberCount]i128 = state.chamber;
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

pub fn splitMix64(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub fn textHash(text: []const u8) u64 {
    var h: u64 = 0x811C9DC5;
    for (text) |b| {
        h = (h ^ @as(u64, b)) *% 0x01000193;
    }
    return h;
}

fn residualFingerprint(state: *const flame.FlameState) u64 {
    var h: u64 = 0x811C9DC5;
    for (state.chamber) |val| {
        const uval: u128 = @bitCast(val);
        h = (h ^ @as(u64, @truncate(uval))) *% 0x01000193;
        h = (h ^ @as(u64, @truncate(uval >> 64))) *% 0x01000193;
    }
    return h;
}
