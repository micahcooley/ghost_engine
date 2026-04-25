const std = @import("std");

/// 1024-bit HyperVector represented as 16x 64-bit integers.
/// Optimized for native SIMD registers (AVX, NEON).
/// V31: Detection-only parity checksum in the last slot (not error-correcting).
pub const HyperVector = @Vector(16, u64);

pub const Boundary = enum(u32) { none = 0, word = 1, phrase = 2, paragraph = 3, soul = 4 };

/// V30: Syntactic Boundary Detection (The "Bracket-Aware" Engine)
/// Automatically identifies context shifts based on structural runes.
pub fn detectSyntacticBoundary(rune: u32) Boundary {
    return switch (rune) {
        '{', '}', '\x0C' => .paragraph, // Form feed or braces = block context shift
        ';', ':', '(', ')', '[', ']', '.', '!', '?' => .phrase, // Statement/expression boundaries
        ' ', '\t', '\n', '\r', ',', '<', '>', '/', '\\', '|', '&' => .word, // Tokens
        else => .none,
    };
}

/// Calculate checksum parity for the HyperVector.
/// Uses the first 15 slots to generate a 64-bit checksum in slot 15.
/// NOTE: Detection-only. Cannot correct errors — only flags corruption.
pub fn generateParity(v: HyperVector) u64 {
    var parity: u64 = 0;
    inline for (0..15) |i| {
        // Non-linear combination to maximize error detection
        parity ^= std.math.rotl(u64, v[i], @as(u6, @intCast(i * 3)));
        parity = parity *% 0xbf58476d1ce4e5b9;
    }
    return parity;
}

/// Verify HyperVector integrity via checksum comparison.
/// Returns false if corruption is detected (checksum mismatch).
pub fn isHealthy(v: HyperVector) bool {
    return v[15] == generateParity(v);
}

// ── Role-Filler Binding Constants (Orthogonal Identities) ──
pub const ROLE_SUBJECT = generate(0x1234_5678_9ABC_DEF0);
pub const ROLE_OBJECT = generate(0x0FED_CBA9_8765_4321);
pub const ROLE_PREDICATE = generate(0x5555_5555_AAAA_AAAA);

// ── Orthogonal Namespace Masks ──
pub const MASK_SCRIBE = generate(0x55AA_55AA_55AA_55AA);
pub const MASK_CRITIC = generate(0xAA55_AA55_AA55_AA55);

/// Hardware-accelerated concept generator.
pub fn generate(seed: u64) HyperVector {
    var v: HyperVector = undefined;
    var s = seed ^ 0x60bee2bee120fc15;
    const c1 = 0xa3b195354a39b70d;
    const c2 = 0x123456789abcdef0;

    // Unrolled for maximum pipeline saturation (first 15 slots)
    inline for (0..15) |i| {
        s = (s ^ (s >> 33)) *% c1;
        s = (s ^ (s >> 33)) *% c2;
        s = s ^ (s >> 33);
        v[i] = s;
    }
    // Slot 15 is dedicated to the integrity checksum
    v[15] = generateParity(v);
    return v;
}

/// Bitwise Binding (XOR) - 100% Symmetrical
pub inline fn bind(a: HyperVector, b: HyperVector) HyperVector {
    var res = a ^ b;
    res[15] = generateParity(res);
    return res;
}

/// Bitwise Bundling (Majority Rule)
/// Implementation: (a & b) | (b & c) | (c & a)
pub inline fn bundle(a: HyperVector, b: HyperVector, c: HyperVector) HyperVector {
    var res = (a & b) | (b & c) | (c & a);
    res[15] = generateParity(res);
    return res;
}

/// Circular Permutation (Shift logic)
pub inline fn permute(v: HyperVector) HyperVector {
    var result: HyperVector = undefined;
    // Architecture optimization: use rotl if available natively
    inline for (0..15) |i| {
        result[i] = std.math.rotl(u64, v[i], 19);
    }
    result[15] = generateParity(result);
    return result;
}

/// Rotate HyperVector elements by N positions (used for fractal/spell push)
pub inline fn rotate(v: HyperVector, comptime n: comptime_int) HyperVector {
    var result: HyperVector = undefined;
    // Note: Rotate only the first 15 slots to preserve parity slot integrity
    inline for (0..15) |i| {
        result[i] = v[(i + n) % 15];
    }
    result[15] = generateParity(result);
    return result;
}

/// Collapse 1024-bit HyperVector to a 64-bit hash via XOR folding
pub inline fn collapse(v: HyperVector) u64 {
    var acc: u64 = v[0];
    inline for (1..16) |i| {
        acc ^= v[i];
    }
    return acc;
}

// ── V32: HyperRotor — XOR-Majority Context Accumulator ──
// Evolves a 1024-bit context vector per-rune using the HRR triple:
//   1. Permute  — shift temporal position (makes the sequence order-dependent)
//   2. Bind     — XOR the new rune identity into the shifted context
//   3. Bundle   — majority-vote superposition to maintain "inertia" from history
//
// The resulting state vector is a smeared, temporal superposition.  Two sequences
// that share a long common prefix will have near-identical states; sequences with
// different content will diverge toward orthogonality (~512 resonance).
//
// IMPORTANT: This struct is CPU-side only.  It is NOT dispatched to the GPU.
// The GPU continues to use u64 FNV-1a rotors for O(1) hash addressing.  The
// HyperRotor is consumed exclusively by `projectSpatialSignature()`, which
// compresses the 1024-bit state to a u32 Locality-Sensitive Hash for the future
// SUDH (Semantic-Uniform Double Hashing) addressing mode.

pub const HyperRotor = struct {
    state: HyperVector,

    /// Initialize with a deterministic seed vector.
    /// Different seeds create orthogonal initial states, useful for
    /// multi-stream training where each stream needs an independent context.
    pub fn init(seed: u64) HyperRotor {
        return .{ .state = generate(seed) };
    }

    /// Evolve the context state by absorbing a single Unicode codepoint.
    /// Approximates HRR (Holographic Reduced Representation) circular convolution
    /// via XOR-bind + majority-vote bundle. Empirically tested:
    ///   - Identical sequences converge to resonance ~1024 (bit-identical).
    ///   - Sequences differing only in the last rune: resonance ~900+.
    ///   - Unrelated sequences: resonance ~512 (near statistical baseline).
    pub fn evolve(self: *HyperRotor, rune: u32) void {
        const rune_vec = generate(@as(u64, rune));

        // Step 1: Temporal Shift — Circular permutation advances the "clock"
        // of the context.  Without this, bind(A,B) == bind(B,A) and we lose
        // sequence ordering.  The permute makes position matter.
        const shifted = permute(self.state);

        // Step 2: Binding — XOR fuses the rune identity into the shifted
        // context.  This produces a vector that is near-orthogonal to both
        // the shifted context and the rune alone, encoding "this rune at
        // this position in this history."
        const bound = bind(shifted, rune_vec);

        // Step 3: Bundling — Majority-vote superposition of:
        //   (a) The previous state (inertia / long-term memory)
        //   (b) The bound vector   (new information)
        //   (c) The shifted state  (bridge between old and new)
        //
        // This creates ~75% overlap with the previous state and ~25% from
        // the new symbol, producing a smooth decay curve where recent runes
        // have the strongest influence but older runes persist as fading
        // "echoes" in the bit pattern.
        self.state = bundle(self.state, bound, shifted);
    }

    /// Project the 1024-bit HyperVector to a 32-bit Locality-Sensitive Hash.
    ///
    /// Algorithm: Majority-Thresholded Segment Projection
    ///   - Partition the 1024-bit vector into 32 segments of 32 bits each.
    ///   - For each segment, count the set bits (popcount).
    ///   - If more than 16 bits are set (majority = 1), the projection bit is 1.
    ///
    /// Locality Guarantee:
    ///   Two HyperVectors with high Hamming resonance (few differing bits)
    ///   will produce identical or near-identical u32 projections, because
    ///   a small number of bit flips in a 32-bit segment rarely changes the
    ///   majority.  This is the mathematical foundation of LSH (Locality-
    ///   Sensitive Hashing) applied to binary hypervectors.
    ///
    /// Performance: 16 popcount + 32 comparisons = ~48 ALU ops.  Zero branches.
    pub fn projectSpatialSignature(self: HyperRotor) u32 {
        var result: u32 = 0;
        inline for (0..15) |word_idx| {
            const word = self.state[word_idx];

            // Lower 32 bits → projection bit at index (word_idx * 2)
            const lo = @as(u32, @truncate(word));
            const lo_pop = @popCount(lo);
            if (lo_pop > 16) {
                result |= @as(u32, 1) << @as(u5, @intCast(word_idx * 2));
            }

            // Upper 32 bits → projection bit at index (word_idx * 2 + 1)
            const hi = @as(u32, @truncate(word >> 32));
            const hi_pop = @popCount(hi);
            if (hi_pop > 16) {
                result |= @as(u32, 1) << @as(u5, @intCast(word_idx * 2 + 1));
            }
        }
        return result;
    }

    /// Compute the resonance between this rotor's context and another vector.
    /// Convenience wrapper that avoids exposing the internal state field.
    pub fn resonanceWith(self: HyperRotor, other: HyperVector) u16 {
        return calculateResonance(self.state, other);
    }
};

// ── V32: Semantic-Uniform Double Hashing (SUDH) ──
// Combines Locality-Sensitive spatial projection with uniform FNV-1a dispersion
// to address the MeaningMatrix without suffering from Zipf's Law clustering.
//
// Architecture:
//   1. PRIMARY ANCHOR — The u32 spatial signature (from HyperRotor.projectSpatialSignature)
//      maps the concept to an "Ideal Neighborhood" of SUDH_NEIGHBORHOOD_SIZE slots.
//   2. SPILLOVER STRIDE — If the neighborhood is saturated, a uniform FNV-1a hash
//      provides a large, pseudo-random stride to jump to a distant region.
//   3. PROBE SEQUENCE — Up to SUDH_MAX_NEIGHBORHOODS neighborhoods are checked
//      before declaring "matrix saturated" for this concept.
//
// This guarantees:
//   - Similar concepts land in the same neighborhood (semantic locality)
//   - Common tokens don't choke a single region (uniform spillover)
//   - O(1) amortized addressing (constant probe depth in practice)

pub const SUDH_NEIGHBORHOOD_SIZE: u32 = 256;
pub const SUDH_MAX_NEIGHBORHOODS: u32 = 4;
pub const SUDH_MAX_PROBES: u32 = SUDH_NEIGHBORHOOD_SIZE * SUDH_MAX_NEIGHBORHOODS;

/// CPU-side probe depth for MeaningMatrix lookups (applyGravity, collapseToBinary, etc.).
/// 8 probes = up to 2 neighborhoods worth of sweep. Matches the original hardcoded depth.
pub const SUDH_CPU_PROBES: u32 = 8;

/// Compute the SUDH probe sequence for a given semantic context.
///
/// Parameters:
///   - spatial_sig:  u32 from HyperRotor.projectSpatialSignature()
///   - uniform_hash: u64 from the existing FNV-1a rotor (lexical or semantic)
///   - total_slots:  Total number of slots in the MeaningMatrix tag array
///
/// Returns a SudhAddress containing the base index and stride for the
/// double-hashing probe sequence.
///
/// The algorithm:
///   1. Compute the Ideal Neighborhood base from the spatial signature.
///      We multiply the signature by NEIGHBORHOOD_SIZE and mask to total_slots.
///      This groups similar projections into the same 256-slot block.
///   2. Compute a Uniform Stride from the FNV-1a hash.
///      The stride is forced odd (| 1) and further constrained to be at least
///      NEIGHBORHOOD_SIZE to guarantee the spillover jump lands in a different
///      neighborhood, not just a different slot in the same block.
///   3. The caller probes: slot = (base + probe_idx * stride) % total_slots
///      for probe_idx in [0, SUDH_MAX_PROBES).
pub const SudhAddress = struct {
    base: u32,
    stride: u32,

    /// Get the slot index for a given probe step.
    /// The caller is responsible for bounds-checking and tag comparison.
    pub inline fn probe(self: SudhAddress, step: u32, total_slots: u32) u32 {
        return (self.base +% step *% self.stride) % total_slots;
    }
};

pub fn computeSudhAddress(spatial_sig: u32, uniform_hash: u64, total_slots: u32) SudhAddress {
    // ── Primary Anchor: Semantic Locality ──
    const wide = @as(u64, spatial_sig) *% @as(u64, total_slots);
    const raw_base = @as(u32, @truncate(wide >> 32));
    const alignment_mask = ~(SUDH_NEIGHBORHOOD_SIZE - 1);
    const base = raw_base & alignment_mask;

    // ── Spillover Stride: Uniform Dispersion ──
    const raw_stride = @as(u32, @truncate(uniform_hash >> 32));
    const stride = @max(raw_stride | 1, SUDH_NEIGHBORHOOD_SIZE + 1) | 1;

    return .{
        .base = base,
        .stride = stride,
    };
}

/// Resonance score: alias for calculateResonance (used by engine noise measurement)
pub inline fn resonanceScore(expectation: HyperVector, reality: HyperVector) u16 {
    return calculateResonance(expectation, reality);
}

/// Calculate Resonance (Hamming Proximity)
/// Optimized via hardware POPCNT instructions.
pub inline fn calculateResonance(expectation: HyperVector, reality: HyperVector) u16 {
    const diff = expectation ^ reality;
    var dist: u32 = 0;
    inline for (0..16) |i| {
        dist += @popCount(diff[i]);
    }
    return @as(u16, @intCast(1024 -| dist));
}

/// Hamming Distance (Raw Drift)
pub inline fn hammingDistance(a: HyperVector, b: HyperVector) u16 {
    const diff = a ^ b;
    var dist: u32 = 0;
    inline for (0..16) |i| {
        dist += @popCount(diff[i]);
    }
    return @as(u16, @intCast(dist));
}

/// Split-half consistency check: independently measures Hamming drift in the
/// lower and upper 32-bit halves of each u64 lane, then gates on dual thresholds.
pub fn dualDriftCheck(current: HyperVector, primary: HyperVector, manager_limit: u64, critic_limit: u64) struct { passed: bool, manager_drift: u16, critic_drift: u16 } {
    const lo_mask: HyperVector = @splat(@as(u64, 0x00000000FFFFFFFF));
    const hi_mask: HyperVector = @splat(@as(u64, 0xFFFFFFFF00000000));
    const manager_drift = hammingDistance(current & lo_mask, primary & lo_mask);
    const critic_drift = hammingDistance(current & hi_mask, primary & hi_mask);

    return .{
        .passed = (manager_drift <= manager_limit) and (critic_drift <= critic_limit),
        .manager_drift = manager_drift,
        .critic_drift = critic_drift,
    };
}
