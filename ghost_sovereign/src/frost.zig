const std = @import("std");
const flame = @import("flame.zig");

// --- GHOST FROST (Suite 3: Mark 0x8DB8D3B0) ---
// Proposed intent: "Three laws with largest variance from median, three entangled flares simultaneously."

pub const FrostEngine = struct {
    state: flame.FlameState,

    pub fn init(seed: u64) FrostEngine {
        return .{ .state = flame.FlameState.init(seed) };
    }

    pub fn maybeInventText(self: *const FrostEngine, text: []const u8, gen: u32) ?flame.InventionCandidate {
        const control_closure = flame.closureError(&self.state);
        const h = flame.textHash(text);

        // SUITE 3 LOGIC: Find top 3 variance laws
        var variances: [flame.LawCount]struct { idx: usize, v: u128 } = undefined;
        for (flame.Laws, 0..) |law, i| {
            variances[i] = .{ .idx = i, .v = @abs(law.ca * self.state.chamber[law.a] + law.cb * self.state.chamber[law.b] - law.t) };
        }
        std.mem.sort(struct { idx: usize, v: u128 }, &variances, {}, struct {
            fn lessThan(_: void, a: struct { idx: usize, v: u128 }, b: struct { idx: usize, v: u128 }) bool {
                return a.v > b.v;
            }
        }.lessThan);

        var trial = self.state;
        // Apply 3 entangled flares
        for (0..3) |i| {
            const flare = flame.makeFlare(self.state.kernel ^ h ^ i, h ^ gen, @as(u32, @intCast(variances[i].idx)));
            trial.chamber[flare.phase % flame.ChamberCount] += flare.heat;
        }
        flame.relax(&trial, 300);

        const closure_after = flame.closureError(&trial);
        if (closure_after < control_closure) {
            return flame.InventionCandidate{
                .child_mark = self.state.kernel ^ h ^ gen,
                .chamber_snapshot = trial.chamber,
                .closure_before = control_closure,
                .closure_after = closure_after,
                .closure_delta = @as(i128, @intCast(closure_after)) - @as(i128, @intCast(control_closure)),
                .scar = variances[0].v ^ variances[1].v ^ variances[2].v, // Combined scar
                .trigger_edge = @as(u8, @intCast(variances[0].idx)),
                .generation = gen,
                .signature = [_]u64{0} ** flame.SignatureWords,
            };
        }
        return null;
    }
};
