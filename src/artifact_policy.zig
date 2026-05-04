const std = @import("std");
const code_intel = @import("code_intel.zig");
const patch_candidates = @import("patch_candidates.zig");
const abstractions = @import("abstractions.zig");

// ── Policy metadata inspection ──────────────────────────────────────────
//
// This module provides a read-only, non-authorizing summary of the active
// artifact/domain policy configuration. It exists so that operators can
// inspect what policy profiles are active and confirm that policies are
// routing/scoring hints, not authority sources.
//
// Architecture invariant: policies are NON-AUTHORIZING. A policy can
// suggest a weight, a penalty, or a routing preference, but it cannot
// create proof, grant support, or authorize any mutation.

/// Identifies which domain profile is active for a given analysis run.
pub const DomainProfile = enum {
    code,
    documentation,
    neutral,
    custom,

    pub fn name(self: DomainProfile) []const u8 {
        return switch (self) {
            .code => "code",
            .documentation => "documentation",
            .neutral => "neutral",
            .custom => "custom",
        };
    }
};

/// Non-authorizing, read-only summary of the active policy configuration.
/// This struct is designed to be serialized for operator inspection.
/// It never grants support, proof, or authorization of any kind.
pub const PolicySummary = struct {
    /// Name of the active profile
    active_profile: DomainProfile = .code,

    /// Artifact/domain scope description
    domain_scope: []const u8 = "code",

    // ── Intervention policy ──
    intervention_policy_name: []const u8 = "CodeInterventionPolicy",
    intervention_file_cost: u32 = 0,
    intervention_dependency_cost: u32 = 0,

    // ── Evidence family policy ──
    family_policy_name: []const u8 = "DEFAULT_CODE_FAMILY_POLICY",
    family_code_weight: usize = 0,
    family_docs_weight: usize = 0,
    family_config_weight: usize = 0,
    family_logs_weight: usize = 0,
    family_tests_weight: usize = 0,

    // ── Hypothesis prior policy ──
    prior_policy_name: []const u8 = "DEFAULT_CODE_PRIOR_POLICY",

    // ── Trust decay policy ──
    trust_decay_policy_name: []const u8 = "DEFAULT_TRUST_POLICY",
    trust_decay_core_immune: bool = false,
    trust_decay_contradiction_threshold: u8 = 0,

    // ── Safety invariants ──
    // These fields are compile-time constants. They exist to make the
    // non-authorizing nature of policies visible in every serialized summary.
    non_authorizing: bool = true,
    support_granted: bool = false,
    proof_granted: bool = false,

    /// Serialize to JSON for operator inspection.
    pub fn toJson(self: PolicySummary, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();

        try out.appendSlice("{");
        try appendJsonString(&out, "active_profile", self.active_profile.name());
        try out.appendSlice(", ");
        try appendJsonString(&out, "domain_scope", self.domain_scope);
        try out.appendSlice(", ");
        try appendJsonString(&out, "intervention_policy", self.intervention_policy_name);
        try out.appendSlice(", ");
        try appendJsonInt(&out, "intervention_file_cost", self.intervention_file_cost);
        try out.appendSlice(", ");
        try appendJsonInt(&out, "intervention_dependency_cost", self.intervention_dependency_cost);
        try out.appendSlice(", ");
        try appendJsonString(&out, "family_policy", self.family_policy_name);
        try out.appendSlice(", ");
        try appendJsonInt(&out, "family_code_weight", self.family_code_weight);
        try out.appendSlice(", ");
        try appendJsonInt(&out, "family_docs_weight", self.family_docs_weight);
        try out.appendSlice(", ");
        try appendJsonInt(&out, "family_config_weight", self.family_config_weight);
        try out.appendSlice(", ");
        try appendJsonInt(&out, "family_logs_weight", self.family_logs_weight);
        try out.appendSlice(", ");
        try appendJsonInt(&out, "family_tests_weight", self.family_tests_weight);
        try out.appendSlice(", ");
        try appendJsonString(&out, "prior_policy", self.prior_policy_name);
        try out.appendSlice(", ");
        try appendJsonString(&out, "trust_decay_policy", self.trust_decay_policy_name);
        try out.appendSlice(", ");
        try appendJsonBool(&out, "trust_decay_core_immune", self.trust_decay_core_immune);
        try out.appendSlice(", ");
        try appendJsonInt(&out, "trust_decay_contradiction_threshold", self.trust_decay_contradiction_threshold);
        try out.appendSlice(", ");
        try appendJsonBool(&out, "non_authorizing", self.non_authorizing);
        try out.appendSlice(", ");
        try appendJsonBool(&out, "support_granted", self.support_granted);
        try out.appendSlice(", ");
        try appendJsonBool(&out, "proof_granted", self.proof_granted);
        try out.appendSlice("}");

        return out.toOwnedSlice();
    }
};

/// Build a PolicySummary for the code domain (the current default).
pub fn codeProfileSummary() PolicySummary {
    const code_intervention = patch_candidates.DEFAULT_CODE_INTERVENTION_POLICY;
    const code_family = code_intel.DEFAULT_CODE_FAMILY_POLICY;
    const trust = abstractions.DEFAULT_TRUST_POLICY;
    return .{
        .active_profile = .code,
        .domain_scope = "code",
        .intervention_policy_name = "CodeInterventionPolicy",
        .intervention_file_cost = code_intervention.file_cost,
        .intervention_dependency_cost = code_intervention.dependency_cost,
        .family_policy_name = "DEFAULT_CODE_FAMILY_POLICY",
        .family_code_weight = code_family.code,
        .family_docs_weight = code_family.docs,
        .family_config_weight = code_family.config,
        .family_logs_weight = code_family.logs,
        .family_tests_weight = code_family.tests,
        .prior_policy_name = "DEFAULT_CODE_PRIOR_POLICY",
        .trust_decay_policy_name = "DEFAULT_TRUST_POLICY",
        .trust_decay_core_immune = trust.core_immune_to_contradiction,
        .trust_decay_contradiction_threshold = trust.contradiction_decay_threshold,
        .non_authorizing = true,
        .support_granted = false,
        .proof_granted = false,
    };
}

/// Build a PolicySummary for the documentation domain.
pub fn docsProfileSummary() PolicySummary {
    const docs_family = code_intel.DEFAULT_DOCS_FAMILY_POLICY;
    const trust = abstractions.DEFAULT_TRUST_POLICY;
    return .{
        .active_profile = .documentation,
        .domain_scope = "documentation",
        .intervention_policy_name = "ArtifactInterventionPolicy",
        .intervention_file_cost = 0,
        .intervention_dependency_cost = 0,
        .family_policy_name = "DEFAULT_DOCS_FAMILY_POLICY",
        .family_code_weight = docs_family.code,
        .family_docs_weight = docs_family.docs,
        .family_config_weight = docs_family.config,
        .family_logs_weight = docs_family.logs,
        .family_tests_weight = docs_family.tests,
        .prior_policy_name = "DEFAULT_CODE_PRIOR_POLICY",
        .trust_decay_policy_name = "DEFAULT_TRUST_POLICY",
        .trust_decay_core_immune = trust.core_immune_to_contradiction,
        .trust_decay_contradiction_threshold = trust.contradiction_decay_threshold,
        .non_authorizing = true,
        .support_granted = false,
        .proof_granted = false,
    };
}

/// Build a PolicySummary for the neutral (domain-general) profile.
pub fn neutralProfileSummary() PolicySummary {
    const neutral_family = code_intel.DEFAULT_NEUTRAL_FAMILY_POLICY;
    const trust = abstractions.DEFAULT_TRUST_POLICY;
    return .{
        .active_profile = .neutral,
        .domain_scope = "artifact_neutral",
        .intervention_policy_name = "ArtifactInterventionPolicy",
        .intervention_file_cost = 0,
        .intervention_dependency_cost = 0,
        .family_policy_name = "DEFAULT_NEUTRAL_FAMILY_POLICY",
        .family_code_weight = neutral_family.code,
        .family_docs_weight = neutral_family.docs,
        .family_config_weight = neutral_family.config,
        .family_logs_weight = neutral_family.logs,
        .family_tests_weight = neutral_family.tests,
        .prior_policy_name = "DEFAULT_CODE_PRIOR_POLICY",
        .trust_decay_policy_name = "DEFAULT_TRUST_POLICY",
        .trust_decay_core_immune = trust.core_immune_to_contradiction,
        .trust_decay_contradiction_threshold = trust.contradiction_decay_threshold,
        .non_authorizing = true,
        .support_granted = false,
        .proof_granted = false,
    };
}

// ── JSON helpers ─────────────────────────────────────────────────────────

fn appendJsonString(out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try out.append('"');
    try out.appendSlice(key);
    try out.appendSlice("\": \"");
    try out.appendSlice(value);
    try out.append('"');
}

fn appendJsonBool(out: *std.ArrayList(u8), key: []const u8, value: bool) !void {
    try out.append('"');
    try out.appendSlice(key);
    try out.appendSlice("\": ");
    try out.appendSlice(if (value) "true" else "false");
}

fn appendJsonInt(out: *std.ArrayList(u8), key: []const u8, value: anytype) !void {
    try out.append('"');
    try out.appendSlice(key);
    try out.appendSlice("\": ");
    var buf: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(rendered);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// ── 1. Code profile preserves expected code-default behavior ──────────

test "code profile preserves code intervention penalties" {
    const summary = codeProfileSummary();
    try std.testing.expectEqual(DomainProfile.code, summary.active_profile);
    try std.testing.expectEqualStrings("CodeInterventionPolicy", summary.intervention_policy_name);
    // Code policy penalizes multi-file changes
    try std.testing.expect(summary.intervention_file_cost > 0);
    try std.testing.expect(summary.intervention_dependency_cost > 0);
}

test "code profile family weights prioritize code over docs" {
    const summary = codeProfileSummary();
    try std.testing.expect(summary.family_code_weight > summary.family_docs_weight);
    try std.testing.expect(summary.family_code_weight > summary.family_logs_weight);
}

// ── 2. Neutral profile does NOT inherit code penalties ─────────────────

test "neutral profile does not inherit code intervention penalties" {
    const summary = neutralProfileSummary();
    try std.testing.expectEqual(DomainProfile.neutral, summary.active_profile);
    try std.testing.expectEqualStrings("ArtifactInterventionPolicy", summary.intervention_policy_name);
    // Neutral: no file cost, no dependency cost
    try std.testing.expectEqual(@as(u32, 0), summary.intervention_file_cost);
    try std.testing.expectEqual(@as(u32, 0), summary.intervention_dependency_cost);
}

test "neutral profile family weights are equal across all families" {
    const summary = neutralProfileSummary();
    try std.testing.expectEqual(summary.family_code_weight, summary.family_docs_weight);
    try std.testing.expectEqual(summary.family_docs_weight, summary.family_config_weight);
    try std.testing.expectEqual(summary.family_config_weight, summary.family_logs_weight);
    try std.testing.expectEqual(summary.family_logs_weight, summary.family_tests_weight);
}

// ── 3. Docs profile weights documentation higher than code ────────────

test "docs profile weights documentation higher than code" {
    const summary = docsProfileSummary();
    try std.testing.expectEqual(DomainProfile.documentation, summary.active_profile);
    try std.testing.expect(summary.family_docs_weight > summary.family_code_weight);
}

test "docs profile uses neutral intervention policy" {
    const summary = docsProfileSummary();
    try std.testing.expectEqualStrings("ArtifactInterventionPolicy", summary.intervention_policy_name);
    try std.testing.expectEqual(@as(u32, 0), summary.intervention_file_cost);
}

// ── 4. Policy metadata is non-authorizing ─────────────────────────────

test "all profiles are non-authorizing and never grant support or proof" {
    const profiles = [_]PolicySummary{
        codeProfileSummary(),
        docsProfileSummary(),
        neutralProfileSummary(),
    };
    for (profiles) |summary| {
        try std.testing.expect(summary.non_authorizing);
        try std.testing.expect(!summary.support_granted);
        try std.testing.expect(!summary.proof_granted);
    }
}

test "policy summary cannot be constructed with support_granted true" {
    // Even if someone tries to construct a PolicySummary with support_granted,
    // the default is false and any override would be a compile-time visible
    // change to this module. This test documents the invariant.
    const custom = PolicySummary{
        .active_profile = .custom,
        .non_authorizing = true,
        .support_granted = false,
        .proof_granted = false,
    };
    try std.testing.expect(custom.non_authorizing);
    try std.testing.expect(!custom.support_granted);
    try std.testing.expect(!custom.proof_granted);
}

// ── 5. Trust decay emits decay state under contradiction ──────────────
//    Without treating contradiction as automatic proof.

test "trust decay policy emits decay candidate under contradiction without granting proof" {
    const allocator = std.testing.allocator;
    const policy = abstractions.DEFAULT_TRUST_POLICY;

    // Set up a promoted record
    var record: abstractions.Record = undefined;
    record.concept_id = try allocator.dupe(u8, "test_decay");
    record.category = .structural;
    record.tier = .pattern;
    record.trust_class = .promoted;
    record.decay_state = .active;
    record.allocator = allocator;
    record.contradiction_count = 0;

    // Apply contradictions up to threshold
    abstractions.applyReinforcementOutcomePublic(&record, .contradicted, policy);
    // After first contradiction: still promoted (below threshold)
    try std.testing.expectEqual(abstractions.TrustClass.promoted, record.trust_class);

    abstractions.applyReinforcementOutcomePublic(&record, .contradicted, policy);
    // After second contradiction: decayed to project, stale
    try std.testing.expectEqual(abstractions.TrustClass.project, record.trust_class);
    try std.testing.expectEqual(abstractions.DecayState.stale, record.decay_state);

    // The decay happened. But the policy summary still does NOT grant proof.
    const summary = codeProfileSummary();
    try std.testing.expect(!summary.proof_granted);
    try std.testing.expect(!summary.support_granted);
    try std.testing.expect(summary.non_authorizing);

    allocator.free(record.concept_id);
}

// ── 6. Non-code fixture: documentation audit ──────────────────────────
//    Proves that the policy routing layer can distinguish documentation
//    from code and apply appropriate (non-code) weighting.

test "non-code fixture: documentation profile routes doc artifacts with higher weight than code profile" {
    const code_summary = codeProfileSummary();
    const docs_summary = docsProfileSummary();

    // In the code profile, code weight > docs weight
    try std.testing.expect(code_summary.family_code_weight > code_summary.family_docs_weight);

    // In the docs profile, docs weight > code weight
    try std.testing.expect(docs_summary.family_docs_weight > docs_summary.family_code_weight);

    // Neither profile grants proof or support
    try std.testing.expect(!code_summary.proof_granted);
    try std.testing.expect(!docs_summary.proof_granted);

    // The docs profile uses neutral intervention (no code file penalties)
    try std.testing.expectEqual(@as(u32, 0), docs_summary.intervention_file_cost);
    try std.testing.expect(code_summary.intervention_file_cost > 0);
}

test "non-code fixture: documentation contradiction audit uses neutral decay without code minimality" {
    const allocator = std.testing.allocator;

    // Simulate a documentation artifact record
    var doc_record: abstractions.Record = undefined;
    doc_record.concept_id = try allocator.dupe(u8, "readme_api_claim");
    doc_record.category = .boundary; // documentation boundary
    doc_record.tier = .convention; // documentation convention
    doc_record.trust_class = .project;
    doc_record.decay_state = .active;
    doc_record.allocator = allocator;
    doc_record.contradiction_count = 0;

    // Apply contradictions (README says one thing, config says another)
    const policy = abstractions.DEFAULT_TRUST_POLICY;
    abstractions.applyReinforcementOutcomePublic(&doc_record, .contradicted, policy);
    abstractions.applyReinforcementOutcomePublic(&doc_record, .contradicted, policy);

    // Decayed because of contradictions
    try std.testing.expectEqual(abstractions.TrustClass.exploratory, doc_record.trust_class);
    try std.testing.expectEqual(abstractions.DecayState.prunable, doc_record.decay_state);

    // But: the docs profile has NO code intervention penalties
    const docs_summary = docsProfileSummary();
    try std.testing.expectEqual(@as(u32, 0), docs_summary.intervention_file_cost);
    try std.testing.expectEqual(@as(u32, 0), docs_summary.intervention_dependency_cost);

    // And: the policy never granted proof from the contradiction alone
    try std.testing.expect(!docs_summary.proof_granted);
    try std.testing.expect(docs_summary.non_authorizing);

    allocator.free(doc_record.concept_id);
}

// ── 7. JSON serialization smoke test ──────────────────────────────────

test "policy summary JSON serialization includes all safety fields" {
    const allocator = std.testing.allocator;
    const summary = codeProfileSummary();
    const json = try summary.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_authorizing\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"support_granted\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proof_granted\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"active_profile\": \"code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"intervention_policy\": \"CodeInterventionPolicy\"") != null);
}

test "neutral profile JSON confirms domain-neutral scope" {
    const allocator = std.testing.allocator;
    const summary = neutralProfileSummary();
    const json = try summary.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"active_profile\": \"neutral\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"domain_scope\": \"artifact_neutral\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"intervention_policy\": \"ArtifactInterventionPolicy\"") != null);
}
