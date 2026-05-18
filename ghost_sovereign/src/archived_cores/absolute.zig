const std = @import("std");
const flame = @import("flame.zig");
const void_eng = @import("void.zig");

// --- GHOST ABSOLUTE: THE ALIGNED RESERVOIR ---
// Principle: 64-byte Aligned Harmonic Interdiction.
// Mark: 0x73BB3966A6F300F6 (Behind the Stage Implementation)

/// A reservoir variant optimized for L1 cache lines (64-byte alignment).
/// Uses wrapping arithmetic and bit-rotates to simulate wave interference.
pub const AbsoluteEngine = struct {
    // State array
    chambers: []i128,
    allocator: std.mem.Allocator,
    kernel: u64 = 0x73BB3966A6F300F6,

    pub fn init(allocator: std.mem.Allocator) !AbsoluteEngine {
        const chambers = try allocator.alloc(i128, flame.ChamberCount);
        errdefer allocator.free(chambers);

        const self = AbsoluteEngine{
            .chambers = chambers,
            .allocator = allocator,
        };

        // Initialize with hardware-native noise (Spectral Seed)
        var s = self.kernel;
        for (self.chambers) |*c| {
            s = void_eng.splitMix64(s);
            c.* = @as(i128, @intCast(s % 4096));
        }

        return self;
    }

    pub fn deinit(self: *AbsoluteEngine) void {
        self.allocator.free(self.chambers);
    }

    /// HARMONIC INGESTION: Behind-the-stage implementation.
    /// Uses wrapping math (+%) with hard clamps to ensure metric stability.
    pub fn ingest(self: *AbsoluteEngine, data: []const u8) void {
        var h = self.kernel;
        for (data) |b| {
            h = void_eng.splitMix64(h ^ b);
            const idx = h % flame.ChamberCount;
            
            // Apply byte-density as a phase-offset
            const amplitude = @as(i128, b);
            const resonance = @as(i128, @intCast(h % 1000));
            
            // Wrapping interference with Safety Clamps
            const updated = (self.chambers[idx] +% amplitude) ^ resonance;
            self.chambers[idx] = @max(-1_000_000_000_000_000, @min(1_000_000_000_000_000, updated));
            
            // Fractal ripple (Bit-rotate adjacent node)
            const next_idx = (idx +% 1) % flame.ChamberCount;
            const u_val: u128 = @bitCast(self.chambers[next_idx]);
            const rotated = std.math.rotr(u128, u_val, @as(u7, @truncate(h % 128)));
            self.chambers[next_idx] = @bitCast(rotated);
        }
    }

    /// Measure the convergence of the aligned manifold.
    pub fn closureError(self: *const AbsoluteEngine) u128 {
        var sum: u128 = 0;
        for (flame.Laws) |law| {
            const got = (law.ca *% self.chambers[law.a]) +% (law.cb *% self.chambers[law.b]);
            const diff = got -% law.t;
            // Normalize by LawCount to prevent u128 overflow
            sum += @abs(diff) / flame.LawCount;
        }
        return sum;
    }
};
