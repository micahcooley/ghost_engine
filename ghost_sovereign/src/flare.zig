const std = @import("std");
const flame = @import("flame.zig");

// --- GHOST FLARE (Suite 2: Mark 0xA17CABB1) ---
// Proposed intent: "One law with largest variance, single-flare collapse."

pub const FlareEngine = struct {
    state: flame.FlameState,

    pub fn init(seed: u64) FlareEngine {
        return .{ .state = flame.FlameState.init(seed) };
    }

    pub fn maybeInventText(self: *const FlareEngine, text: []const u8, gen: u32) ?flame.InventionCandidate {
        const control_closure = flame.closureError(&self.state);
        const h = flame.textHash(text);
        
        // SUITE 2 LOGIC: Single law variance
        var best_law_idx: usize = 0;
        var max_v: u128 = 0;
        for (flame.Laws, 0..) |law, i| {
            const v = @abs(law.ca * self.state.chamber[law.a] + law.cb * self.state.chamber[law.b] - law.t);
            if (v > max_v) {
                max_v = v;
                best_law_idx = i;
            }
        }
        
        var trial = self.state;
        const flare = flame.makeFlare(self.state.kernel ^ h, h ^ gen, @as(u32, @intCast(best_law_idx)));
        trial.chamber[flare.phase % flame.ChamberCount] += flare.heat;
        flame.relax(&trial, 100);
        
        const closure_after = flame.closureError(&trial);
        if (closure_after < control_closure) {
            return flame.InventionCandidate{
                .child_mark = self.state.kernel ^ h ^ gen,
                .chamber_snapshot = trial.chamber,
                .closure_before = control_closure,
                .closure_after = closure_after,
                .closure_delta = @as(i128, @intCast(closure_after)) - @as(i128, @intCast(control_closure)),
                .scar = flare.scar,
                .trigger_edge = @as(u8, @intCast(best_law_idx)),
                .generation = gen,
                .signature = [_]u64{0} ** flame.SignatureWords,
            };
        }
        return null;
    }
};
