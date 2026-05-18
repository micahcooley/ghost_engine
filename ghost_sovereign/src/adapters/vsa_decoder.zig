const std = @import("std");
const vsa = @import("vsa.zig");
const void_eng = @import("void.zig");

// --- GHOST VSA DECODER: LATTICE TO AST ---
// Principle: Sequential Hamming Unbinding.
// Mark: 0x98CAA04772E0DCE5 (Consensus)

pub const Decoder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    // UNBIND: Extract the N-th token from a manifold state
    pub fn unbindToken(self: *const Decoder, state: vsa.Hypervector, index: usize, dictionary: []const []const u8) []const u8 {
        _ = self;
        // 1. Generate the Position Hypervector for this index
        const pos_hv = vsa.Hypervector.initRandom(0x12345 ^ index);
        
        // 2. UNBIND: XOR the state with the position
        const candidate_hv = state.bind(pos_hv);
        
        // 3. SEARCH: Find the most resonant word in the dictionary
        var best_word: []const u8 = "??";
        var best_sim: u32 = 0;
        
        for (dictionary) |word| {
            const word_h = void_eng.textHash(word);
            const word_hv = vsa.Hypervector.initRandom(word_h);
            const sim = candidate_hv.similarity(word_hv);
            
            if (sim > best_sim) {
                best_sim = sim;
                best_word = word;
            }
        }
        
        return best_word;
    }

    // AST VERIFY: A simple state machine to ensure code structure
    pub fn verifyAST(self: *const Decoder, tokens: []const []const u8) bool {
        _ = self;
        var paren_count: i32 = 0;
        var brace_count: i32 = 0;
        
        for (tokens) |token| {
            if (std.mem.eql(u8, token, "(")) paren_count += 1;
            if (std.mem.eql(u8, token, ")")) paren_count -= 1;
            if (std.mem.eql(u8, token, "{")) brace_count += 1;
            if (std.mem.eql(u8, token, "}")) brace_count -= 1;
            
            if (paren_count < 0 or brace_count < 0) return false;
        }
        return paren_count == 0 and brace_count == 0;
    }
};
