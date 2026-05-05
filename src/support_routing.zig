const std = @import("std");
const compute_budget = @import("compute_budget.zig");
const negative_knowledge = @import("negative_knowledge.zig");

pub const SourceKind = enum {
    artifact,
    fragment,
    entity,
    relation,
    obligation,
    knowledge_pack_preview,
    abstraction_record,
    task_history,
    external_evidence,
    corpus_entry,
};

pub const TrustClass = enum {
    exploratory,
    project,
    promoted,
    core,
};

pub const FreshnessState = enum {
    active,
    stale,
    unknown,
};

pub const SourceFamily = enum {
    code,
    docs,
    config,
    logs,
    tests,
    pack,
    task,
    external,
    other,
};

pub const ArtifactType = enum {
    code_file,
    doc,
    config,
    log,
    unit_test,
    pack_preview,
    abstraction,
    task_record,
    evidence_record,
    unknown,
};

pub const SkipReason = enum {
    none,
    low_support_potential,
    stale_or_low_trust,
    conflict_state,
    source_family_quota,
    selection_budget,
    considered_budget,
};

pub const Status = enum {
    selected,
    skipped,
    suppressed,
};

pub const SignalSource = enum {
    entity,
    relation,
    obligation,
    anchor,
    verifier_hint,
    schema,
    retained_token,
    retained_pattern,
    rune_vsa,
    fallback,
};

pub const Entry = struct {
    id: []const u8,
    source_kind: SourceKind,
    schema_domain_hint: []const u8 = "",
    artifact_type: ArtifactType = .unknown,
    entity_signals: u16 = 0,
    relation_signals: u16 = 0,
    obligation_signals: u16 = 0,
    anchor_signals: u16 = 0,
    verifier_hint_signals: u16 = 0,
    schema_signals: u16 = 0,
    retained_token_signals: u16 = 0,
    retained_pattern_signals: u16 = 0,
    rune_vsa_signals: u16 = 0,
    signal_source: SignalSource = .fallback,
    trust_class: TrustClass = .exploratory,
    freshness_state: FreshnessState = .unknown,
    provenance: []const u8 = "",
    source_family: SourceFamily = .other,
    exact_anchor: bool = false,
    schema_compatible: bool = false,
    conflict: bool = false,
    budget_cost: u16 = 1,
    stable_rank: u32 = 0,
};

pub const Caps = struct {
    max_considered: usize = 24,
    max_selected: usize = 8,
    max_suppressed_traces: usize = 16,
    max_code: usize = 5,
    max_docs: usize = 3,
    max_config: usize = 3,
    max_logs: usize = 2,
    max_tests: usize = 2,
    max_pack: usize = 3,
    max_task: usize = 2,
    max_external: usize = 2,
    max_other: usize = 2,
};

pub const Decision = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    provenance: []u8,
    source_kind: SourceKind,
    source_family: SourceFamily,
    status: Status,
    skip_reason: SkipReason = .none,
    support_potential_upper_bound: u16,
    considered_rank: u16 = 0,
    selected_rank: u16 = 0,
    selected_signal_source: SignalSource = .fallback,
    retained_token_signal_count: u16 = 0,
    retained_pattern_signal_count: u16 = 0,
    schema_entity_signal_count: u16 = 0,
    schema_relation_signal_count: u16 = 0,
    obligation_signal_count: u16 = 0,
    anchor_signal_count: u16 = 0,
    verifier_hint_signal_count: u16 = 0,
    fallback_signal_used: bool = false,

    pub fn deinit(self: *Decision) void {
        self.allocator.free(self.id);
        self.allocator.free(self.provenance);
        self.* = undefined;
    }
};

pub const Trace = struct {
    allocator: std.mem.Allocator,
    considered_count: usize = 0,
    selected_count: usize = 0,
    skipped_count: usize = 0,
    suppressed_count: usize = 0,
    budget_cap_hit: bool = false,
    negative_knowledge_routing_warning_count: usize = 0,
    negative_knowledge_trust_decay_candidate_count: usize = 0,
    entries: []Decision = &.{},

    pub fn deinit(self: *Trace) void {
        for (self.entries) |*entry| entry.deinit();
        if (self.entries.len != 0) self.allocator.free(self.entries);
        self.* = undefined;
    }
};

const Ranked = struct {
    entry: Entry,
    upper: u16,
};

const FamilyCounts = struct {
    code: usize = 0,
    docs: usize = 0,
    config: usize = 0,
    logs: usize = 0,
    tests: usize = 0,
    pack: usize = 0,
    task: usize = 0,
    external: usize = 0,
    other: usize = 0,
};

/// Calculates the maximum possible support potential a candidate could theoretically reach.
/// This strictly serves as an optimistic routing/triage limit.
/// Do NOT use this to authorize real support boundaries. Candidate, evidence, and policy
/// findings evaluated here do NOT grant support. Actual support is exclusively
/// granted via explicit support gates during verifier execution.
pub fn supportPotentialUpperBound(entry: Entry) u16 {
    if (entry.conflict) return 0;
    var score: u16 = 0;
    if (entry.exact_anchor) score += 420;
    if (entry.schema_compatible) score += 160;
    score += @as(u16, @min(entry.anchor_signals, 12)) * 180;
    score += @as(u16, @min(entry.entity_signals, 12)) * 80;
    score += @as(u16, @min(entry.relation_signals, 12)) * 24;
    score += @as(u16, @min(entry.obligation_signals, 12)) * 22;
    score += @as(u16, @min(entry.verifier_hint_signals, 12)) * 20;
    score += @as(u16, @min(entry.schema_signals, 12)) * 16;
    score += @as(u16, @min(entry.retained_pattern_signals, 12)) * 8;
    score += @as(u16, @min(entry.retained_token_signals, 12)) * 5;
    score += @as(u16, @min(entry.rune_vsa_signals, 12)) * 3;
    score += switch (entry.trust_class) {
        .core => 220,
        .promoted => 180,
        .project => 140,
        .exploratory => 45,
    };
    score += switch (entry.freshness_state) {
        .active => 120,
        .unknown => 45,
        .stale => 0,
    };
    const cost_penalty: u16 = @min(entry.budget_cost, 20) * 6;
    if (score <= cost_penalty) return 0;
    return @min(score - cost_penalty, 1000);
}

pub fn select(allocator: std.mem.Allocator, entries: []const Entry, caps: Caps) !Trace {
    var ranked = try allocator.alloc(Ranked, entries.len);
    defer allocator.free(ranked);
    for (entries, 0..) |entry, idx| {
        ranked[idx] = .{ .entry = entry, .upper = supportPotentialUpperBound(entry) };
    }
    std.sort.heap(Ranked, ranked, {}, lessThanRanked);

    var decisions = std.ArrayList(Decision).init(allocator);
    errdefer {
        for (decisions.items) |*decision| decision.deinit();
        decisions.deinit();
    }
    var selected = std.ArrayList(Entry).init(allocator);
    defer selected.deinit();
    var counts = FamilyCounts{};
    var trace = Trace{ .allocator = allocator };
    var considered_rank: u16 = 0;
    var selected_rank: u16 = 0;

    for (ranked, 0..) |item, idx| {
        if (idx >= caps.max_considered) {
            trace.budget_cap_hit = true;
            trace.skipped_count += 1;
            try appendDecisionBounded(allocator, &decisions, caps, item.entry, item.upper, .suppressed, .considered_budget, 0, 0);
            continue;
        }
        trace.considered_count += 1;
        considered_rank += 1;

        var status: Status = .selected;
        var skip: SkipReason = .none;
        if (item.entry.conflict) {
            status = .suppressed;
            skip = .conflict_state;
        } else if (item.entry.freshness_state == .stale or item.entry.trust_class == .exploratory and item.upper < 260) {
            status = .skipped;
            skip = .stale_or_low_trust;
        } else if (item.upper < 220) {
            // Triage limit only. Passing this limit does not grant support authority;
            // it merely allows the candidate to be considered by later support gates.
            status = .skipped;
            skip = .low_support_potential;
        } else if (familyCount(counts, item.entry.source_family) >= familyLimit(caps, item.entry.source_family)) {
            status = .suppressed;
            skip = .source_family_quota;
        } else if (selected.items.len >= caps.max_selected) {
            status = .suppressed;
            skip = .selection_budget;
            trace.budget_cap_hit = true;
        }

        if (status == .selected) {
            selected_rank += 1;
            try selected.append(item.entry);
            incrementFamily(&counts, item.entry.source_family);
            trace.selected_count += 1;
        } else {
            trace.skipped_count += 1;
            if (status == .suppressed) trace.suppressed_count += 1;
        }
        try appendDecisionBounded(allocator, &decisions, caps, item.entry, item.upper, status, skip, considered_rank, if (status == .selected) selected_rank else 0);
    }

    trace.entries = try decisions.toOwnedSlice();
    return trace;
}

pub fn selectWithNegativeKnowledge(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    caps: Caps,
    negative_records: []const negative_knowledge.Record,
    budget: compute_budget.Effective,
) !Trace {
    const nk = @import("negative_knowledge.zig");

    var ranked = try allocator.alloc(Ranked, entries.len);
    defer allocator.free(ranked);
    for (entries, 0..) |entry, idx| {
        var upper = supportPotentialUpperBound(entry);
        // Apply NK routing influence
        if (negative_records.len > 0) {
            var influence = try nk.influenceRoutingEntry(allocator, negative_records, entry, budget);
            defer influence.deinit();
            if (influence.triage_delta < 0) {
                const penalty = @as(u16, @intCast(@min(-influence.triage_delta, 200)));
                if (upper > penalty) upper -= penalty else upper = 0;
            }
        }
        ranked[idx] = .{ .entry = entry, .upper = upper };
    }
    std.sort.heap(Ranked, ranked, {}, lessThanRanked);

    var decisions = std.ArrayList(Decision).init(allocator);
    errdefer {
        for (decisions.items) |*decision| decision.deinit();
        decisions.deinit();
    }
    var selected = std.ArrayList(Entry).init(allocator);
    defer selected.deinit();
    var counts = FamilyCounts{};
    var trace = Trace{ .allocator = allocator };
    var considered_rank: u16 = 0;
    var selected_rank: u16 = 0;

    for (ranked, 0..) |item, idx| {
        if (idx >= caps.max_considered) {
            trace.budget_cap_hit = true;
            trace.skipped_count += 1;
            try appendDecisionBounded(allocator, &decisions, caps, item.entry, item.upper, .suppressed, .considered_budget, 0, 0);
            continue;
        }
        trace.considered_count += 1;
        considered_rank += 1;

        var status: Status = .selected;
        var skip: SkipReason = .none;
        if (item.entry.conflict) {
            status = .suppressed;
            skip = .conflict_state;
        } else if (item.entry.freshness_state == .stale or item.entry.trust_class == .exploratory and item.upper < 260) {
            status = .skipped;
            skip = .stale_or_low_trust;
        } else if (item.upper < 220) {
            // Triage limit only. Passing this limit does not grant support authority;
            // it merely allows the candidate to be considered by later support gates.
            status = .skipped;
            skip = .low_support_potential;
        } else if (familyCount(counts, item.entry.source_family) >= familyLimit(caps, item.entry.source_family)) {
            status = .suppressed;
            skip = .source_family_quota;
        } else if (selected.items.len >= caps.max_selected) {
            status = .suppressed;
            skip = .selection_budget;
            trace.budget_cap_hit = true;
        }

        if (status == .selected) {
            selected_rank += 1;
            try selected.append(item.entry);
            incrementFamily(&counts, item.entry.source_family);
            trace.selected_count += 1;
        } else {
            trace.skipped_count += 1;
            if (status == .suppressed) trace.suppressed_count += 1;
        }
        try appendDecisionBounded(allocator, &decisions, caps, item.entry, item.upper, status, skip, considered_rank, if (status == .selected) selected_rank else 0);
    }

    // Collect aggregate NK influence counts across all considered entries
    if (negative_records.len > 0) {
        for (ranked) |item| {
            var influence = try nk.influenceRoutingEntry(allocator, negative_records, item.entry, budget);
            defer influence.deinit();
            trace.negative_knowledge_routing_warning_count += influence.warnings.len;
            trace.negative_knowledge_trust_decay_candidate_count += influence.trust_decay_candidates.len;
        }
    }

    trace.entries = try decisions.toOwnedSlice();
    return trace;
}

fn appendDecisionBounded(
    allocator: std.mem.Allocator,
    decisions: *std.ArrayList(Decision),
    caps: Caps,
    entry: Entry,
    upper: u16,
    status: Status,
    skip: SkipReason,
    considered_rank: u16,
    selected_rank: u16,
) !void {
    if (status != .selected and decisions.items.len >= caps.max_selected + caps.max_suppressed_traces) return;
    try decisions.append(.{
        .allocator = allocator,
        .id = try allocator.dupe(u8, entry.id),
        .provenance = try allocator.dupe(u8, entry.provenance),
        .source_kind = entry.source_kind,
        .source_family = entry.source_family,
        .status = status,
        .skip_reason = skip,
        .support_potential_upper_bound = upper,
        .considered_rank = considered_rank,
        .selected_rank = selected_rank,
        .selected_signal_source = selectedSignalSource(entry),
        .retained_token_signal_count = entry.retained_token_signals,
        .retained_pattern_signal_count = entry.retained_pattern_signals,
        .schema_entity_signal_count = entry.entity_signals,
        .schema_relation_signal_count = entry.relation_signals,
        .obligation_signal_count = entry.obligation_signals,
        .anchor_signal_count = entry.anchor_signals,
        .verifier_hint_signal_count = entry.verifier_hint_signals,
        .fallback_signal_used = selectedSignalSource(entry) == .fallback or entry.retained_token_signals + entry.retained_pattern_signals + entry.rune_vsa_signals > 0 and entry.entity_signals + entry.relation_signals + entry.obligation_signals + entry.anchor_signals + entry.verifier_hint_signals + entry.schema_signals == 0,
    });
}

fn lessThanRanked(_: void, lhs: Ranked, rhs: Ranked) bool {
    if (lhs.upper != rhs.upper) return lhs.upper > rhs.upper;
    if (selectedSignalSource(lhs.entry) != selectedSignalSource(rhs.entry)) return signalSourceRank(selectedSignalSource(lhs.entry)) > signalSourceRank(selectedSignalSource(rhs.entry));
    if (lhs.entry.exact_anchor != rhs.entry.exact_anchor) return lhs.entry.exact_anchor;
    if (lhs.entry.trust_class != rhs.entry.trust_class) return trustRank(lhs.entry.trust_class, DEFAULT_TRUST_POLICY) > trustRank(rhs.entry.trust_class, DEFAULT_TRUST_POLICY);
    if (lhs.entry.source_family != rhs.entry.source_family) return @intFromEnum(lhs.entry.source_family) < @intFromEnum(rhs.entry.source_family);
    if (lhs.entry.stable_rank != rhs.entry.stable_rank) return lhs.entry.stable_rank < rhs.entry.stable_rank;
    return std.mem.lessThan(u8, lhs.entry.id, rhs.entry.id);
}

pub fn selectedSignalSource(entry: Entry) SignalSource {
    if (entry.anchor_signals > 0 or entry.exact_anchor) return .anchor;
    if (entry.entity_signals > 0) return .entity;
    if (entry.relation_signals > 0) return .relation;
    if (entry.obligation_signals > 0) return .obligation;
    if (entry.verifier_hint_signals > 0) return .verifier_hint;
    if (entry.schema_signals > 0 or entry.schema_compatible) return .schema;
    if (entry.retained_pattern_signals > 0) return .retained_pattern;
    if (entry.retained_token_signals > 0) return .retained_token;
    if (entry.rune_vsa_signals > 0) return .rune_vsa;
    return entry.signal_source;
}

fn signalSourceRank(source: SignalSource) u8 {
    return switch (source) {
        .anchor => 9,
        .entity => 8,
        .relation => 7,
        .obligation => 6,
        .verifier_hint => 5,
        .schema => 4,
        .retained_pattern => 3,
        .retained_token => 2,
        .rune_vsa => 1,
        .fallback => 0,
    };
}

pub const TrustDecayPolicy = struct {
    exploratory_rank: u8 = 0,
    project_rank: u8 = 1,
    promoted_rank: u8 = 2,
    core_rank: u8 = 3,
    contradiction_decay_threshold: u8 = 2,
    core_immune_to_contradiction: bool = false,
};

pub const DEFAULT_TRUST_POLICY = TrustDecayPolicy{};

pub fn trustRank(trust: TrustClass, policy: TrustDecayPolicy) u8 {
    return switch (trust) {
        .exploratory => policy.exploratory_rank,
        .project => policy.project_rank,
        .promoted => policy.promoted_rank,
        .core => policy.core_rank,
    };
}

fn familyLimit(caps: Caps, family: SourceFamily) usize {
    return switch (family) {
        .code => caps.max_code,
        .docs => caps.max_docs,
        .config => caps.max_config,
        .logs => caps.max_logs,
        .tests => caps.max_tests,
        .pack => caps.max_pack,
        .task => caps.max_task,
        .external => caps.max_external,
        .other => caps.max_other,
    };
}

fn familyCount(counts: FamilyCounts, family: SourceFamily) usize {
    return switch (family) {
        .code => counts.code,
        .docs => counts.docs,
        .config => counts.config,
        .logs => counts.logs,
        .tests => counts.tests,
        .pack => counts.pack,
        .task => counts.task,
        .external => counts.external,
        .other => counts.other,
    };
}

fn incrementFamily(counts: *FamilyCounts, family: SourceFamily) void {
    switch (family) {
        .code => counts.code += 1,
        .docs => counts.docs += 1,
        .config => counts.config += 1,
        .logs => counts.logs += 1,
        .tests => counts.tests += 1,
        .pack => counts.pack += 1,
        .task => counts.task += 1,
        .external => counts.external += 1,
        .other => counts.other += 1,
    }
}

pub fn sourceKindName(kind: SourceKind) []const u8 {
    return @tagName(kind);
}

pub fn statusName(status: Status) []const u8 {
    return @tagName(status);
}

pub fn skipReasonName(reason: SkipReason) []const u8 {
    return @tagName(reason);
}

pub fn sourceFamilyName(family: SourceFamily) []const u8 {
    return @tagName(family);
}

pub fn signalSourceName(source: SignalSource) []const u8 {
    return @tagName(source);
}

test "exact anchor beats generic deterministic candidate" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .id = "generic", .source_kind = .artifact, .source_family = .code, .schema_compatible = true, .trust_class = .core, .freshness_state = .active, .stable_rank = 0 },
        .{ .id = "exact", .source_kind = .artifact, .source_family = .docs, .exact_anchor = true, .trust_class = .project, .freshness_state = .active, .stable_rank = 1 },
    };
    var trace = try select(allocator, &entries, .{ .max_selected = 2 });
    defer trace.deinit();
    try std.testing.expectEqualStrings("exact", trace.entries[0].id);
}

test "structured entity and anchor signals outrank retained token fallback" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .id = "token-only", .source_kind = .artifact, .source_family = .docs, .retained_token_signals = 12, .trust_class = .core, .freshness_state = .active },
        .{ .id = "schema-anchor", .source_kind = .artifact, .source_family = .docs, .entity_signals = 1, .anchor_signals = 1, .trust_class = .project, .freshness_state = .active },
    };
    var trace = try select(allocator, &entries, .{ .max_selected = 2 });
    defer trace.deinit();
    try std.testing.expectEqualStrings("schema-anchor", trace.entries[0].id);
    try std.testing.expectEqual(SignalSource.anchor, trace.entries[0].selected_signal_source);
    try std.testing.expect(!trace.entries[0].fallback_signal_used);
}

test "relation and obligation signals improve deterministic priority without authorizing support" {
    const relation_entry = Entry{ .id = "relation", .source_kind = .relation, .source_family = .docs, .relation_signals = 1, .obligation_signals = 1, .trust_class = .project, .freshness_state = .active };
    const token_entry = Entry{ .id = "token", .source_kind = .artifact, .source_family = .docs, .retained_token_signals = 4, .trust_class = .project, .freshness_state = .active };
    try std.testing.expect(supportPotentialUpperBound(relation_entry) > supportPotentialUpperBound(token_entry));
    try std.testing.expectEqual(SignalSource.relation, selectedSignalSource(relation_entry));
}

test "stale low trust candidate is skipped while fresh high trust is selected" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .id = "stale", .source_kind = .external_evidence, .source_family = .external, .exact_anchor = true, .trust_class = .exploratory, .freshness_state = .stale },
        .{ .id = "fresh", .source_kind = .corpus_entry, .source_family = .docs, .schema_compatible = true, .trust_class = .core, .freshness_state = .active },
    };
    var trace = try select(allocator, &entries, .{ .max_selected = 2 });
    defer trace.deinit();
    try std.testing.expectEqual(@as(usize, 1), trace.selected_count);
    try std.testing.expectEqual(Status.selected, trace.entries[0].status);
    try std.testing.expectEqual(Status.skipped, trace.entries[1].status);
}

test "mixed pack corpus and artifact entries rank deterministically across runs" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .id = "pack/a", .source_kind = .knowledge_pack_preview, .source_family = .pack, .schema_compatible = true, .trust_class = .promoted, .freshness_state = .active, .stable_rank = 2 },
        .{ .id = "corpus/a", .source_kind = .corpus_entry, .source_family = .docs, .exact_anchor = true, .trust_class = .project, .freshness_state = .active, .stable_rank = 1 },
        .{ .id = "artifact/a", .source_kind = .artifact, .source_family = .code, .schema_compatible = true, .trust_class = .core, .freshness_state = .active, .stable_rank = 0 },
    };
    var first = try select(allocator, &entries, .{ .max_selected = 3 });
    defer first.deinit();
    var second = try select(allocator, &entries, .{ .max_selected = 3 });
    defer second.deinit();
    try std.testing.expectEqual(first.entries.len, second.entries.len);
    for (first.entries, second.entries) |left, right| try std.testing.expectEqualStrings(left.id, right.id);
}

test "source family quota preserves skipped trace" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .id = "a", .source_kind = .artifact, .source_family = .code, .exact_anchor = true, .trust_class = .core, .freshness_state = .active },
        .{ .id = "b", .source_kind = .artifact, .source_family = .code, .schema_compatible = true, .trust_class = .core, .freshness_state = .active },
    };
    var trace = try select(allocator, &entries, .{ .max_selected = 2, .max_code = 1, .max_suppressed_traces = 4 });
    defer trace.deinit();
    try std.testing.expectEqual(@as(usize, 1), trace.selected_count);
    try std.testing.expectEqual(@as(usize, 1), trace.suppressed_count);
    try std.testing.expectEqual(SkipReason.source_family_quota, trace.entries[1].skip_reason);
}

test "routing entries are non authorizing support hints only" {
    const entry = Entry{ .id = "exact", .source_kind = .artifact, .source_family = .code, .exact_anchor = true, .trust_class = .core, .freshness_state = .active };
    try std.testing.expect(supportPotentialUpperBound(entry) > 0);
    try std.testing.expectEqual(@as(u16, 0), supportPotentialUpperBound(.{ .id = "conflict", .source_kind = .artifact, .source_family = .code, .exact_anchor = true, .trust_class = .core, .freshness_state = .active, .conflict = true }));
}
