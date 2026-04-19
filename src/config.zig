const std = @import("std");
const build_options = @import("build_options");

/// ── Sovereign Configuration: The Comptime Spine ──
/// Derived memory algebra for bit-perfect hardware alignment.

pub const TEST_MODE = build_options.test_mode;
pub const PLATFORM_SUBDIR = build_options.platform_subdir;
pub const STATE_SUBDIR = if (TEST_MODE) "state/test" else PLATFORM_SUBDIR ++ "/state";

pub const MAX_VRAM_GB: usize = 4; // Target hardware profile
pub const FLEET_MODE: bool = true; // Training and dashboard control paths expect a fleet handle, even on one GPU.

// --- VSA Engine Parameters ---
// Test mode uses a 128 MiB micro-matrix so `zig build test` stays a smoke test.
pub const SEMANTIC_SLOTS: usize = if (TEST_MODE) 16_384 else 524_288;

// --- Lattice Algebra ---
pub const UNIFIED_ENTRIES: usize = if (TEST_MODE) 33_554_432 else 536_870_912;
pub const UNIFIED_SIZE_BYTES: usize = UNIFIED_ENTRIES * @sizeOf(u16); 

// --- Semantic Algebra ---
// Accumulators: Slots * 1024 * u32 (1GB if slots=256K)
pub const SEMANTIC_ENTRIES: usize = SEMANTIC_SLOTS * 1024;
pub const SEMANTIC_SIZE_BYTES: usize = SEMANTIC_ENTRIES * @sizeOf(u32); 

// Tags: Slots * u64 (2MB if slots=256K)
pub const TAG_ENTRIES: usize = SEMANTIC_SLOTS;
pub const TAG_SIZE_BYTES: usize = TAG_ENTRIES * @sizeOf(u64); 

// --- Derived Totals ---
pub const TOTAL_STATE_BYTES: usize = UNIFIED_SIZE_BYTES + SEMANTIC_SIZE_BYTES + TAG_SIZE_BYTES;

// --- Operational Logic ---
pub const SURPRISE_THRESHOLD: u16 = 850; // Resonance > 850 = Already known (skip etching)
pub const SEARCH_TRIGGER_THRESHOLD: u16 = 750; // Sovereign Balance: Prevent I/O strangulation

// --- VSA Dimensions ---
pub const HYPERVECTOR_BITS: u16 = 1024; // Bit-width of each HyperVector (16 × u64)
pub const BMP_SPACE_SIZE: u32 = 65536; // Full Unicode BMP codepoint space
pub const BMP_PRINTABLE_RANGE: u32 = 256; // ASCII-printable range for beam search
pub const BATCH_SIZE: u32 = 1024; // GPU dispatch batch size
pub const SLOTS_PER_VECTOR: u32 = 1024; // u32 accumulators per semantic slot
pub const CHUNK_SIZE: u32 = 256; // BMP codepoints per chunk for hierarchical search
pub const MAX_STREAMS: u32 = 20480; // Max concurrent training streams per GPU frame

// --- Inference Parameters ---
pub const BEAM_NUM_LANES: u32 = 5;
pub const BEAM_ROLLOUT_DEPTH: u32 = 10;
pub const force_cpu_inference: bool = false; // Re-engage GPU inference while interrogating the live Vulkan path.
pub const SATURATION_BONUS: u32 = 64;
pub const SATURATION_LOCK_THRESHOLD: u32 = 32; // Minimum locked cells for saturation bonus
pub const SATURATION_SAMPLE_SIZE: u32 = 64; // Cells to sample per slot for saturation check
pub const BOREDOM_DRIFT_HIGH: u32 = 100; // Below this = heavy penalty (30)
pub const BOREDOM_DRIFT_LOW: u32 = 200; // Below this = mild penalty (15)
pub const BOREDOM_PENALTY_HIGH: u32 = 30;
pub const BOREDOM_PENALTY_LOW: u32 = 15;

// --- Boundary Detection Thresholds ---
pub const BOUNDARY_SOUL_THRESHOLD: u16 = 200;
pub const BOUNDARY_PARAGRAPH_THRESHOLD: u16 = 400;
pub const ENERGY_WORD_THRESHOLD: u16 = 400;
pub const ENERGY_PHRASE_THRESHOLD: u16 = 600;

// --- GPU Memory Budget Percentages ---
pub const VRAM_MATRIX_BUDGET_PERCENT: u32 = 60; // 60% of usable VRAM for meaning matrix
pub const VRAM_LATTICE_BUDGET_PERCENT: u32 = 30; // 30% of usable VRAM for lattice
pub const VRAM_HIGH_TIER_THRESHOLD: usize = 4 * 1024 * 1024 * 1024; // 4GB VRAM
pub const VRAM_HIGH_TIER_USABLE_PERCENT: u32 = 85; // Use 85% of VRAM on high-tier GPUs
pub const VRAM_LOW_TIER_USABLE_PERCENT: u32 = 70; // Use 70% of VRAM on low-tier GPUs
pub const IDEAL_MATRIX_SIZE: usize = 4 * 1024 * 1024 * 1024; // 4GB target
pub const IDEAL_LATTICE_SIZE: usize = 1 * 1024 * 1024 * 1024; // 1GB target
pub const MAX_MATRIX_SLOTS: u32 = 1_048_576; // Hard cap on semantic slots

// --- Block Checksum Constants ---
pub const CHECKSUM_BLOCK_SIZE: usize = 64 * 1024 * 1024; // 64MB per verification block
pub const CHECKSUM_BLOCK_COUNT: usize = UNIFIED_SIZE_BYTES / CHECKSUM_BLOCK_SIZE;
pub const CHECKSUM_RESERVED_BYTES: usize = 1024; // Reserved tail space for hashes

// --- Paths (Environment Agnostic) ---
pub fn getPath(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(sub_path)) return allocator.dupe(u8, sub_path);
    return std.fs.path.join(allocator, &.{ build_options.project_root, sub_path });
}

pub const LATTICE_REL_PATH = STATE_SUBDIR ++ "/unified_lattice.bin";
pub const SEMANTIC_REL_PATH = STATE_SUBDIR ++ "/semantic_monolith.bin";
pub const TAG_REL_PATH = STATE_SUBDIR ++ "/semantic_tags.bin";

// --- Integration Test Constants ---
pub const TEST_LATTICE_SIZE: usize = 1 * 1024 * 1024; // 1 MiB
pub const TEST_STRING = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG";
