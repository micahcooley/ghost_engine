const std = @import("std");

pub const Tier = enum {
    auto,
    low,
    medium,
    high,
    max,
};

pub const Limit = enum {
    max_branches,
    max_proof_queue_size,
    max_repairs,
    max_mounted_packs_considered,
    max_packs_activated,
    max_pack_candidate_surfaces,
    max_routing_entries_considered,
    max_routing_entries_selected,
    max_routing_suppressed_traces,
    max_graph_nodes,
    max_graph_obligations,
    max_ambiguity_sets,
    max_runtime_checks,
    max_verifier_runs,
    max_verifier_time_ms,
    max_external_verifier_runs,
    max_verifier_evidence_bytes,
    max_wall_time_ms,
    max_temp_work_bytes,
};

pub const Stage = enum {
    code_intel_target_resolution,
    code_intel_pack_routing,
    code_intel_support_graph,
    code_intel_unresolved_support,
    patch_candidate_planning,
    patch_proof_handoff,
    patch_verification,
    patch_runtime_oracle,
    verifier_adapter_registry,
    verifier_adapter_run,
    verifier_adapter_evidence,
    task_session,
    artifact_ingestion,
    artifact_fragment_extraction,
    artifact_entity_extraction,
    artifact_schema_routing,
    support_aware_routing_index,
    artifact_obligation_attachment,
};

pub const Overrides = struct {
    max_branches: ?u32 = null,
    max_proof_queue_size: ?usize = null,
    max_repairs: ?u32 = null,
    max_mounted_packs_considered: ?usize = null,
    max_packs_activated: ?usize = null,
    max_pack_candidate_surfaces: ?usize = null,
    max_routing_entries_considered: ?usize = null,
    max_routing_entries_selected: ?usize = null,
    max_routing_suppressed_traces: ?usize = null,
    max_graph_nodes: ?u32 = null,
    max_graph_obligations: ?u32 = null,
    max_ambiguity_sets: ?u32 = null,
    max_runtime_checks: ?usize = null,
    max_verifier_runs: ?usize = null,
    max_verifier_time_ms: ?u32 = null,
    max_external_verifier_runs: ?usize = null,
    max_verifier_evidence_bytes: ?usize = null,
    max_wall_time_ms: ?u32 = null,
    max_temp_work_bytes: ?usize = null,
};

pub const Request = struct {
    tier: Tier = .auto,
    overrides: Overrides = .{},
};

pub const Effective = struct {
    requested_tier: Tier,
    effective_tier: Tier,
    max_branches: u32,
    max_proof_queue_size: usize,
    max_repairs: u32,
    max_mounted_packs_considered: usize,
    max_packs_activated: usize,
    max_pack_candidate_surfaces: usize,
    max_routing_entries_considered: usize,
    max_routing_entries_selected: usize,
    max_routing_suppressed_traces: usize,
    max_routing_code_family: usize,
    max_routing_docs_family: usize,
    max_routing_config_family: usize,
    max_routing_logs_family: usize,
    max_routing_tests_family: usize,
    max_routing_other_family: usize,
    max_graph_nodes: u32,
    max_graph_obligations: u32,
    max_ambiguity_sets: u32,
    max_runtime_checks: usize,
    max_verifier_runs: usize,
    max_verifier_time_ms: u32,
    max_external_verifier_runs: usize,
    max_verifier_evidence_bytes: usize,
    max_wall_time_ms: u32,
    max_temp_work_bytes: usize,
};

pub const Exhaustion = struct {
    allocator: std.mem.Allocator,
    limit: Limit,
    stage: Stage,
    used: u64,
    limit_value: u64,
    detail: []u8,
    skipped: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        limit: Limit,
        stage: Stage,
        used: u64,
        limit_value: u64,
        detail: []const u8,
        skipped: []const u8,
    ) !Exhaustion {
        return .{
            .allocator = allocator,
            .limit = limit,
            .stage = stage,
            .used = used,
            .limit_value = limit_value,
            .detail = try allocator.dupe(u8, detail),
            .skipped = try allocator.dupe(u8, skipped),
        };
    }

    pub fn clone(self: *const Exhaustion, allocator: std.mem.Allocator) !Exhaustion {
        return .{
            .allocator = allocator,
            .limit = self.limit,
            .stage = self.stage,
            .used = self.used,
            .limit_value = self.limit_value,
            .detail = try allocator.dupe(u8, self.detail),
            .skipped = try allocator.dupe(u8, self.skipped),
        };
    }

    pub fn deinit(self: *Exhaustion) void {
        self.allocator.free(self.detail);
        self.allocator.free(self.skipped);
        self.* = undefined;
    }
};

pub fn tierName(tier: Tier) []const u8 {
    return @tagName(tier);
}

pub fn limitName(limit: Limit) []const u8 {
    return @tagName(limit);
}

pub fn stageName(stage: Stage) []const u8 {
    return @tagName(stage);
}

pub fn resolve(request: Request) Effective {
    var effective = preset(if (request.tier == .auto) .medium else request.tier);
    effective.requested_tier = request.tier;
    effective.effective_tier = if (request.tier == .auto) .medium else request.tier;

    applyOverrideU32(&effective.max_branches, request.overrides.max_branches, 1);
    applyOverrideUsize(&effective.max_proof_queue_size, request.overrides.max_proof_queue_size, 1);
    applyOverrideU32(&effective.max_repairs, request.overrides.max_repairs, 0);
    applyOverrideUsize(&effective.max_mounted_packs_considered, request.overrides.max_mounted_packs_considered, 1);
    applyOverrideUsize(&effective.max_packs_activated, request.overrides.max_packs_activated, 1);
    applyOverrideUsize(&effective.max_pack_candidate_surfaces, request.overrides.max_pack_candidate_surfaces, 1);
    applyOverrideUsize(&effective.max_routing_entries_considered, request.overrides.max_routing_entries_considered, 1);
    applyOverrideUsize(&effective.max_routing_entries_selected, request.overrides.max_routing_entries_selected, 1);
    applyOverrideUsize(&effective.max_routing_suppressed_traces, request.overrides.max_routing_suppressed_traces, 0);
    applyOverrideU32(&effective.max_graph_nodes, request.overrides.max_graph_nodes, 1);
    applyOverrideU32(&effective.max_graph_obligations, request.overrides.max_graph_obligations, 1);
    applyOverrideU32(&effective.max_ambiguity_sets, request.overrides.max_ambiguity_sets, 1);
    applyOverrideUsize(&effective.max_runtime_checks, request.overrides.max_runtime_checks, 1);
    applyOverrideUsize(&effective.max_verifier_runs, request.overrides.max_verifier_runs, 0);
    applyOverrideU32(&effective.max_verifier_time_ms, request.overrides.max_verifier_time_ms, 1);
    applyOverrideUsize(&effective.max_external_verifier_runs, request.overrides.max_external_verifier_runs, 0);
    applyOverrideUsize(&effective.max_verifier_evidence_bytes, request.overrides.max_verifier_evidence_bytes, 0);
    applyOverrideU32(&effective.max_wall_time_ms, request.overrides.max_wall_time_ms, 1);
    applyOverrideUsize(&effective.max_temp_work_bytes, request.overrides.max_temp_work_bytes, 1024);

    if (effective.max_packs_activated > effective.max_mounted_packs_considered) {
        effective.max_packs_activated = effective.max_mounted_packs_considered;
    }
    if (effective.max_pack_candidate_surfaces < effective.max_packs_activated) {
        effective.max_pack_candidate_surfaces = effective.max_packs_activated;
    }
    if (effective.max_routing_entries_selected > effective.max_routing_entries_considered) {
        effective.max_routing_entries_selected = effective.max_routing_entries_considered;
    }
    if (effective.max_graph_obligations > effective.max_graph_nodes) {
        effective.max_graph_obligations = effective.max_graph_nodes;
    }
    if (effective.max_ambiguity_sets > effective.max_graph_nodes) {
        effective.max_ambiguity_sets = effective.max_graph_nodes;
    }
    if (effective.max_proof_queue_size > 4) {
        effective.max_proof_queue_size = 4;
    }
    return effective;
}

fn preset(tier: Tier) Effective {
    return switch (tier) {
        .auto, .medium => .{
            .requested_tier = tier,
            .effective_tier = .medium,
            .max_branches = 5,
            .max_proof_queue_size = 3,
            .max_repairs = 1,
            .max_mounted_packs_considered = 6,
            .max_packs_activated = 3,
            .max_pack_candidate_surfaces = 6,
            .max_routing_entries_considered = 24,
            .max_routing_entries_selected = 8,
            .max_routing_suppressed_traces = 16,
            .max_routing_code_family = 5,
            .max_routing_docs_family = 3,
            .max_routing_config_family = 3,
            .max_routing_logs_family = 2,
            .max_routing_tests_family = 2,
            .max_routing_other_family = 2,
            .max_graph_nodes = 96,
            .max_graph_obligations = 8,
            .max_ambiguity_sets = 6,
            .max_runtime_checks = 16,
            .max_verifier_runs = 8,
            .max_verifier_time_ms = 12_000,
            .max_external_verifier_runs = 3,
            .max_verifier_evidence_bytes = 64 * 1024,
            .max_wall_time_ms = 12_000,
            .max_temp_work_bytes = 256 * 1024,
        },
        .low => .{
            .requested_tier = .low,
            .effective_tier = .low,
            .max_branches = 2,
            .max_proof_queue_size = 1,
            .max_repairs = 0,
            .max_mounted_packs_considered = 2,
            .max_packs_activated = 1,
            .max_pack_candidate_surfaces = 2,
            .max_routing_entries_considered = 8,
            .max_routing_entries_selected = 3,
            .max_routing_suppressed_traces = 6,
            .max_routing_code_family = 2,
            .max_routing_docs_family = 1,
            .max_routing_config_family = 1,
            .max_routing_logs_family = 1,
            .max_routing_tests_family = 1,
            .max_routing_other_family = 1,
            .max_graph_nodes = 24,
            .max_graph_obligations = 3,
            .max_ambiguity_sets = 2,
            .max_runtime_checks = 4,
            .max_verifier_runs = 3,
            .max_verifier_time_ms = 4_000,
            .max_external_verifier_runs = 0,
            .max_verifier_evidence_bytes = 16 * 1024,
            .max_wall_time_ms = 4_000,
            .max_temp_work_bytes = 64 * 1024,
        },
        .high => .{
            .requested_tier = .high,
            .effective_tier = .high,
            .max_branches = 8,
            .max_proof_queue_size = 4,
            .max_repairs = 2,
            .max_mounted_packs_considered = 8,
            .max_packs_activated = 4,
            .max_pack_candidate_surfaces = 8,
            .max_routing_entries_considered = 40,
            .max_routing_entries_selected = 12,
            .max_routing_suppressed_traces = 24,
            .max_routing_code_family = 8,
            .max_routing_docs_family = 5,
            .max_routing_config_family = 5,
            .max_routing_logs_family = 4,
            .max_routing_tests_family = 4,
            .max_routing_other_family = 4,
            .max_graph_nodes = 160,
            .max_graph_obligations = 12,
            .max_ambiguity_sets = 8,
            .max_runtime_checks = 24,
            .max_verifier_runs = 12,
            .max_verifier_time_ms = 15_000,
            .max_external_verifier_runs = 5,
            .max_verifier_evidence_bytes = 96 * 1024,
            .max_wall_time_ms = 15_000,
            .max_temp_work_bytes = 512 * 1024,
        },
        .max => .{
            .requested_tier = .max,
            .effective_tier = .max,
            .max_branches = 12,
            .max_proof_queue_size = 4,
            .max_repairs = 3,
            .max_mounted_packs_considered = 12,
            .max_packs_activated = 6,
            .max_pack_candidate_surfaces = 12,
            .max_routing_entries_considered = 64,
            .max_routing_entries_selected = 16,
            .max_routing_suppressed_traces = 32,
            .max_routing_code_family = 12,
            .max_routing_docs_family = 8,
            .max_routing_config_family = 8,
            .max_routing_logs_family = 6,
            .max_routing_tests_family = 6,
            .max_routing_other_family = 6,
            .max_graph_nodes = 256,
            .max_graph_obligations = 16,
            .max_ambiguity_sets = 12,
            .max_runtime_checks = 32,
            .max_verifier_runs = 16,
            .max_verifier_time_ms = 15_000,
            .max_external_verifier_runs = 8,
            .max_verifier_evidence_bytes = 128 * 1024,
            .max_wall_time_ms = 15_000,
            .max_temp_work_bytes = 1024 * 1024,
        },
    };
}

fn applyOverrideU32(target: *u32, value: ?u32, min_value: u32) void {
    if (value) |override_value| target.* = @max(min_value, override_value);
}

fn applyOverrideUsize(target: *usize, value: ?usize, min_value: usize) void {
    if (value) |override_value| target.* = @max(min_value, override_value);
}

test "preset tiers remain deterministic and ordered" {
    const low = resolve(.{ .tier = .low });
    const medium = resolve(.{ .tier = .medium });
    const high = resolve(.{ .tier = .high });
    try std.testing.expect(low.max_branches < medium.max_branches);
    try std.testing.expect(medium.max_branches < high.max_branches);
    try std.testing.expect(low.max_proof_queue_size < high.max_proof_queue_size);
    try std.testing.expect(low.max_mounted_packs_considered < high.max_mounted_packs_considered);
}

test "auto resolves to medium and selective overrides are deterministic" {
    const effective = resolve(.{
        .tier = .auto,
        .overrides = .{
            .max_branches = 7,
            .max_repairs = 2,
        },
    });
    try std.testing.expectEqual(Tier.auto, effective.requested_tier);
    try std.testing.expectEqual(Tier.medium, effective.effective_tier);
    try std.testing.expectEqual(@as(u32, 7), effective.max_branches);
    try std.testing.expectEqual(@as(u32, 2), effective.max_repairs);
    try std.testing.expectEqual(@as(usize, 3), effective.max_proof_queue_size);
}
