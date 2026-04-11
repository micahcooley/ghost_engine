const std = @import("std");

/// Ghost Engine Compute API Interface (Sovereign Threading Contract)
/// This allows the engine to swap between Vulkan, CUDA, and CPU backends.
pub const ComputeApi = struct {
    /// Human-readable name of the provider (e.g., "Vulkan-V23", "CUDA-X")
    name: []const u8,

    /// Returns the raw pointer to the Meaning Matrix memory managed by the provider.
    /// This memory must be host-visible and aligned.
    getMatrixData: *const fn () []u16,
    
    /// Returns the raw pointer to the Semantic Tags memory.
    getTagsData: *const fn () []u64,

    /// Returns the raw pointer to the Unified Lattice memory.
    getLatticeData: *const fn () []u16,

    /// Perform a batch etch operation. 
    /// 'starting_rotors' contains (lexical, semantic) pairs for each stream.
    /// 'chars' contains the raw byte stream to etch.
    etch: *const fn (total_batch: u32, starting_rotors: []const u64, chars: []const u8) anyerror!void,

    /// Query resonance for a specific context. Returns top-K energy scores.
    queryResonance: *const fn (lexical_rotor: u64, semantic_rotor: u64, allocator: std.mem.Allocator) anyerror![]u32,

    /// Perform recursive lookahead for reasoning.
    lookahead: *const fn (num_rotors: u32, depth: u32, allocator: std.mem.Allocator) anyerror![]u32,

    /// Apply thermal pruning to the lattice.
    prune: *const fn () anyerror!void,

    /// Update the operational tier (power/performance targets).
    setTier: *const fn (tier: u32) void,

    /// Transfer the lattice from host to device memory (V23 Async Bridge).
    transferLattice: *const fn () anyerror!void,
};

/// Plugin Entry Point
pub const ComputePlugin = struct {
    name: []const u8,
    version: u32,
    
    /// Factory function to initialize the provider
    init: *const fn (allocator: std.mem.Allocator) anyerror!*const ComputeApi,
    
    /// Cleanup function
    deinit: *const fn () void,
};
