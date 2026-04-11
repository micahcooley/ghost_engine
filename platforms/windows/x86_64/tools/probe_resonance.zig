const std = @import("std");
const vsa_core = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // 1. Initialize Meaning Matrix (1GB)
    // std.heap.page_allocator uses VirtualAlloc on Windows.
    const mm_data = try allocator.alloc(u8, 1_048_576 * 1024);
    defer allocator.free(mm_data);
    @memset(mm_data, 128); // Neutral superposition
    
    var mm = vsa_core.MeaningMatrix{ .data = mm_data };
    
    const text = "Hello world. const int x = 5;";
    
    // 2. Training Pass: Burn the expected structure into the Lattice
    for (0..30) |_| {
        var rotor: u64 = ghost_state.FNV_OFFSET_BASIS;
        for (text) |ch| {
            const prev_rotor = rotor;
            rotor = (rotor ^ @as(u64, ch)) *% ghost_state.FNV_PRIME;
            
            const is_boundary = (ch == ' ' or ch == '.' or ch == ';' or ch == '=');
            
            // Burn the structured expectation into the Meaning Matrix
            // We leave boundaries neutral to simulate their high-variance diffuse state in a real corpus
            if (!is_boundary) {
                const char_vec = vsa_core.generate(@as(u64, ch));
                _ = mm.applyGravity(prev_rotor, char_vec);
            }
            
            if (is_boundary) {
                rotor = ghost_state.FNV_OFFSET_BASIS;
            }
        }
    }
    
    // 3. Test Pass: Measure the Energy Drop (Surprise)
    std.debug.print("Sovereign Resonance Audit\n", .{});
    std.debug.print("-------------------------\n", .{});
    std.debug.print("Char | Energy (Surprise)\n", .{});
    std.debug.print("-----+------------------\n", .{});
    
    var rotor: u64 = ghost_state.FNV_OFFSET_BASIS;
    
    for (text) |ch| {
        const prev_rotor = rotor;
        
        // 1. The Query: Expectation Vector
        const expectation_vector = mm.collapseToBinary(prev_rotor);
        
        // 2. The Reality: Actual char vector
        const char_vec = vsa_core.generate(@as(u64, ch));
        
        // 3. The Clash: Hamming Distance
        const hamming = vsa_core.hammingDistance(expectation_vector, char_vec);
        
        // 4. The Energy Metric
        const energy = 1024 - hamming;
        
        std.debug.print("'{c}'  | {d}\n", .{ch, energy});
        
        rotor = (rotor ^ @as(u64, ch)) *% ghost_state.FNV_PRIME;
        const is_boundary = (ch == ' ' or ch == '.' or ch == ';' or ch == '=');
        if (is_boundary) {
            rotor = ghost_state.FNV_OFFSET_BASIS;
        }
    }
}
