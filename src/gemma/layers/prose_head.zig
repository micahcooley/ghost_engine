const std = @import("std");
const vsa = @import("../../vsa_math.zig");
const context_provider = @import("../context_provider.zig");

const shards = @import("../../shards.zig");
const abstractions = @import("../../abstractions.zig");

pub const ProseHead = struct {
    allocator: std.mem.Allocator,
    seed: u64 = 0x6765_6d6d_615f_7072,

    pub fn init(allocator: std.mem.Allocator) ProseHead {
        return .{ .allocator = allocator };
    }

pub fn synthesize(self: ProseHead, output_rune: vsa.HyperVector, context: []const context_provider.ContextEntry) ![]const u8 {
    if (context.len == 0) return self.allocator.dupe(u8, "System Ready. [Active Memory: 0 Runes]");

    var words = std.ArrayList([]const u8).init(self.allocator);
    defer words.deinit();

    // Perform De-Rotor unbinding pass against active memory context
    // We iteratively unbind the output hypervector using true VSA XOR unbinding
    var current_state = output_rune;
    var unbind_count: usize = 0;
    const max_words = @min(context.len * 2 + 5, 25);

    while (unbind_count < max_words) : (unbind_count += 1) {
        var best_entry: ?context_provider.ContextEntry = null;
        var best_resonance: f32 = -1.0;

        for (context) |entry| {
            const res = context_provider.resonanceScore(current_state, vsa.generate(entry.rotor[0]));
            if (res > best_resonance) {
                best_resonance = res;
                best_entry = entry;
            }
        }

        if (best_entry) |entry| {
            if (entry.text.len > 0) {
                var already_has = false;
                for (words.items) |w| {
                    if (std.mem.eql(u8, w, entry.text)) {
                        already_has = true;
                        break;
                    }
                }
                if (!already_has) {
                    try words.append(entry.text);
                }
            } else {
                try words.append("lattice");
            }
            // True VSA XOR unbinding using the native Rotor signature
            const unbind_vec = vsa.generate(entry.rotor[0]);
            current_state = current_state ^ unbind_vec; 
        } else {
            break;
        }

        if (best_resonance < 0.15 and unbind_count > 3) break;
    }

    if (words.items.len == 0) {
        const fallback_matrix = [_][]const u8{
            "active", "lattice", "concept", "node", "vector",
            "state", "matrix", "kernel", "system", "memory",
        };
        for (fallback_matrix[0..@min(context.len, 10)]) |fw| {
            try words.append(fw);
        }
    }


        // Join words into coherent prose
        var total_len: usize = 0;
        for (words.items, 0..) |w, i| total_len += w.len + if (i > 0) @as(usize, 1) else @as(usize, 0);
        
        var result = try self.allocator.alloc(u8, total_len);
        var cursor: usize = 0;
        for (words.items, 0..) |w, i| {
            if (i > 0) {
                result[cursor] = ' ';
                cursor += 1;
            }
            @memcpy(result[cursor..cursor + w.len], w);
            cursor += w.len;
        }
        return result;
    }
};

test "prose head synthesizes tokenless words from context entries" {
    const allocator = std.testing.allocator;
    const head = ProseHead.init(allocator);
    var vec: vsa.HyperVector = @splat(0);
    vec[0] = 0x12345678;

    const context = [_]context_provider.ContextEntry{
        .{ .slot = 0, .resonance = 0.9, .embedding = &[_]f32{}, .rune_id = 100, .rotor = .{100, 101}, .text = "memory" },
        .{ .slot = 1, .resonance = 0.8, .embedding = &[_]f32{}, .rune_id = 200, .rotor = .{200, 201}, .text = "lattice" },
    };

    const prose = try head.synthesize(vec, &context);
    defer allocator.free(prose);
    try std.testing.expect(prose.len > 0);
}
