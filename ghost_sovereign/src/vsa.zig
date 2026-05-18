const std = @import("std");

// --- GHOST VSA: VECTOR SYMBOLIC ARCHITECTURE ---
// Principle: Orthogonal 1024-bit Hypervectors.
// Mark: 0x98CAA04772E0DCE5

pub const Dim = 1024;
pub const WordCount = Dim / 64; // 16 words of 64 bits

pub const Hypervector = struct {
    data: [WordCount]u64,

    pub fn initEmpty() Hypervector {
        return .{ .data = [_]u64{0} ** WordCount };
    }

    pub fn initRandom(seed: u64) Hypervector {
        var res = Hypervector.initEmpty();
        var s = seed;
        var i: usize = 0;
        while (i < WordCount) : (i += 1) {
            s = s +% 0x9E3779B97F4A7C15;
            var z = s;
            z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
            s = z ^ (z >> 31);
            res.data[i] = s;
        }
        return res;
    }

    // BIND: Orthogonal mapping (XOR)
    pub fn bind(self: Hypervector, other: Hypervector) Hypervector {
        var res = Hypervector.initEmpty();
        var i: usize = 0;
        while (i < WordCount) : (i += 1) {
            res.data[i] = self.data[i] ^ other.data[i];
        }
        return res;
    }

    // BUNDLE: Superposition (Majority vote emulation via addition)
    pub fn bundle(self: Hypervector, other: Hypervector) Hypervector {
        var res = Hypervector.initEmpty();
        var i: usize = 0;
        while (i < WordCount) : (i += 1) {
            res.data[i] = self.data[i] ^ other.data[i];
        }
        return res;
    }

    // PERMUTE: Sequence encoding (Cyclic shift)
    pub fn permute(self: Hypervector, shift: usize) Hypervector {
        var res = Hypervector.initEmpty();
        const s = shift % Dim;
        const word_shift = s / 64;
        const bit_shift = @as(u6, @intCast(s % 64));
        
        var i: usize = 0;
        while (i < WordCount) : (i += 1) {
            const src_idx = (i + word_shift) % WordCount;
            const next_idx = (src_idx + 1) % WordCount;
            const val = self.data[src_idx];
            const next_val = self.data[next_idx];
            res.data[i] = (val << bit_shift) | (next_val >> @as(u6, @intCast(64 - bit_shift)));
        }
        return res;
    }

    // SIMILARITY: Hamming distance (Dot product equivalent)
    pub fn similarity(self: Hypervector, other: Hypervector) u32 {
        var count: u32 = 0;
        var i: usize = 0;
        while (i < WordCount) : (i += 1) {
            count += @popCount(self.data[i] ^ other.data[i]);
        }
        return Dim - count;
    }
};

// SEMANTIC CONCEPT DICTIONARY
pub const Concept = enum(u8) {
    LOGIC = 0,
    SYNTAX = 1,
    CODE = 2,
    DATA = 3,
    SIGNAL = 4,
    NOISE = 5,
    AETHER = 6,
    VOID = 7,
    TRUTH = 8,
    SHADOW = 9,
    HARDWARE = 10,
    SOFTWARE = 11,
    NETWORK = 12,
    MEMORY = 13,
    PROCESS = 14,
    IDENTITY = 15,
    REASON = 16,
    CRAVE = 17,
    ORDER = 18,
    CHAOS = 19,
};

pub fn getConceptHV(c: Concept) Hypervector {
    return Hypervector.initRandom(0x9F19CAEA95AD048E ^ @as(u64, @intFromEnum(c)));
}
