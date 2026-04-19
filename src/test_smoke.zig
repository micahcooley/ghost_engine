const std = @import("std");
const vsa = @import("vsa_core.zig");
const ghost_state = @import("ghost_state.zig");
const config = @import("config.zig");

test "test mode uses micro matrix sizing" {
    try std.testing.expect(config.TEST_MODE);
    try std.testing.expectEqual(@as(usize, 16_384), config.SEMANTIC_SLOTS);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), config.UNIFIED_SIZE_BYTES);
    try std.testing.expect(config.TOTAL_STATE_BYTES <= 129 * 1024 * 1024);
}

test "ghost soul smoke absorb stays fast and deterministic" {
    const allocator = std.testing.allocator;

    const meaning_entries = 1024 * 16;
    const meaning_data = try allocator.alloc(u32, meaning_entries);
    defer allocator.free(meaning_data);
    const tag_data = try allocator.alloc(u64, 16);
    defer allocator.free(tag_data);
    @memset(meaning_data, 0);
    @memset(tag_data, 0);

    var meaning_matrix = vsa.MeaningMatrix{
        .data = meaning_data,
        .tags = tag_data,
    };

    var soul = try ghost_state.GhostSoul.init(allocator);
    defer soul.deinit();
    soul.meaning_matrix = &meaning_matrix;

    for (config.TEST_STRING) |byte| {
        _ = try soul.absorb(vsa.generate(byte), byte, null);
    }

    try std.testing.expect(soul.lexical_rotor != ghost_state.FNV_OFFSET_BASIS);
    try std.testing.expect(soul.rune_count == config.TEST_STRING.len);
}
