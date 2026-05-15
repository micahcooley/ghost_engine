const std = @import("std");
const inference = @import("domain_inference");
const anchors = @import("anchor_discovery");
const tensor = @import("semantic_tensor");
const z3_bridge = @import("z3_bridge");

const dsp_source =
    \\#include <juce_audio_processors/juce_audio_processors.h>
    \\
    \\static int emit_audio(void) {
    \\    audio_lock.lock();
    \\    defer audio_lock.unlock();
    \\    buffer_lock.lock();
    \\    defer buffer_lock.unlock();
    \\    processBlock(output_buffer);
    \\    return 1;
    \\}
    \\
    \\int audio_callback(void) {
    \\    return emit_audio();
    \\}
;

const database_source =
    \\#include <sqlite3.h>
    \\
    \\static int read_path(void) {
    \\    cache_lock.lock();
    \\    defer cache_lock.unlock();
    \\    txn_lock.lock();
    \\    defer txn_lock.unlock();
    \\    return 1;
    \\}
    \\
    \\static int write_path(void) {
    \\    txn_lock.lock();
    \\    defer txn_lock.unlock();
    \\    cache_lock.lock();
    \\    defer cache_lock.unlock();
    \\    return 2;
    \\}
    \\
    \\int database_commit(void) {
    \\    return read_path() + write_path();
    \\}
    \\
    \\int database_version(void) {
    \\    return 1;
    \\}
;

test "sovereign crucible runs inference anchors tensor and Z3 as one pipeline" {
    const units = [_]inference.TranslationUnitInput{
        .{ .path = "sovereign_universe/audio/plugin_processor.cpp", .source = dsp_source },
        .{ .path = "sovereign_universe/database/sqlite_backend.c", .source = database_source },
    };

    var domain_map = try inference.inferDomainMap(std.testing.allocator, &units);
    defer domain_map.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), domain_map.translation_units.len);
    try std.testing.expectEqual(@as(usize, 2), domain_map.clusters.len);

    const dsp_domains = domainForPath(domain_map, "sovereign_universe/audio/plugin_processor.cpp").?;
    const database_domains = domainForPath(domain_map, "sovereign_universe/database/sqlite_backend.c").?;
    try std.testing.expect(dsp_domains.contains(.dsp));
    try std.testing.expect(!dsp_domains.contains(.database));
    try std.testing.expect(database_domains.contains(.database));
    try std.testing.expect(!database_domains.contains(.dsp));

    const dsp_anchor = anchors.discoverAnchorForUnit(
        dsp_source,
        "sovereign_universe/audio/plugin_processor.cpp",
        domain_map,
    );
    const database_anchor = anchors.discoverAnchorForUnit(
        database_source,
        "sovereign_universe/database/sqlite_backend.c",
        domain_map,
    );

    try std.testing.expectEqual(anchors.DiscoveryTier.hal_sink, dsp_anchor.tier);
    try std.testing.expect(dsp_anchor.anchor != null);
    try std.testing.expectEqualStrings("audio_callback", dsp_anchor.anchor.?.function_name);
    try std.testing.expectEqualStrings("processBlock", dsp_anchor.anchor.?.sink_name.?);
    try std.testing.expectEqual(inference.PhysicalDomain.dsp, dsp_anchor.anchor.?.domain.?);

    try std.testing.expectEqual(anchors.DiscoveryTier.public_interface_fallback, database_anchor.tier);
    try std.testing.expect(database_anchor.anchor != null);
    try std.testing.expectEqualStrings("database_commit", database_anchor.anchor.?.function_name);

    const dsp_semantics = tensor.resolveIntentDomainSet(.secure, dsp_domains);
    const database_semantics = tensor.resolveIntentDomainSet(.secure, database_domains);

    try std.testing.expectEqual(tensor.ConfidenceBand.green_verified, dsp_semantics.confidence_band);
    try std.testing.expect(dsp_semantics.hasTarget(.heap_allocation_ban));
    try std.testing.expect(dsp_semantics.hasTarget(.bounds_checking));
    try std.testing.expect(!dsp_semantics.hasTarget(.query_plan_stability));

    try std.testing.expectEqual(tensor.ConfidenceBand.green_verified, database_semantics.confidence_band);
    try std.testing.expect(database_semantics.hasTarget(.input_validation));
    try std.testing.expect(database_semantics.hasTarget(.query_plan_stability));
    try std.testing.expect(!database_semantics.hasTarget(.realtime_thread_budget));

    const dsp_proof = try z3_bridge.proveLockInversionAbsence(
        std.testing.allocator,
        dsp_source,
        dsp_anchor,
        .{ .timeout_ms = 250 },
    );
    const database_proof = try z3_bridge.proveLockInversionAbsence(
        std.testing.allocator,
        database_source,
        database_anchor,
        .{ .timeout_ms = 250 },
    );

    try std.testing.expectEqual(z3_bridge.ProofStatus.proved_no_lock_inversion, dsp_proof.status);
    try std.testing.expectEqual(z3_bridge.ProofSignal.green_verified, dsp_proof.signal);
    try std.testing.expectEqual(tensor.ConfidenceBand.green_verified, dsp_proof.confidence_band);

    try std.testing.expectEqual(z3_bridge.ProofStatus.lock_inversion_possible, database_proof.status);
    try std.testing.expectEqual(z3_bridge.ProofSignal.failure, database_proof.signal);
    try std.testing.expectEqual(tensor.ConfidenceBand.yellow_heuristic, database_proof.confidence_band);
}

fn domainForPath(domain_map: inference.DomainMap, path: []const u8) ?inference.DomainSet {
    for (domain_map.translation_units) |unit| {
        if (std.mem.eql(u8, unit.path, path)) return unit.domains;
    }
    return null;
}
