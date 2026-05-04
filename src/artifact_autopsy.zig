const std = @import("std");
const artifact_policy = @import("artifact_policy.zig");

// ── Universal Artifact Autopsy ──────────────────────────────────────────
//
// This module provides a bounded, read-only inspection structure for
// non-code artifact domains. It proves that Ghost's artifact intelligence
// is not code-only: documentation, recipes, logs, configs, and other
// artifact families are first-class inspection targets.
//
// Architecture invariants:
//   - Universal artifact autopsy is read-only.
//   - Non-code artifact findings are candidates, not proof.
//   - Docs/recipes/logs/configs are claims/evidence surfaces, not authority.
//   - No hidden writes.
//   - No hidden command execution.
//   - No verifier execution.
//   - No correction/NK/pack/corpus/trust/snapshot/scratch mutation.
//   - Unknown is not false.
//   - No evidence is not negative evidence.
//   - Policies are routing/scoring hints, not authority.
//   - Rendering can explain authority. Rendering cannot create authority.
//
// This is a seed implementation, not full universal artifact support.
// It demonstrates the shape that future non-code artifact domains follow.

/// Identifies which non-code artifact domain is being inspected.
pub const ArtifactDomain = enum {
    documentation_audit,
    recipe_consistency,
    incident_review,
    generic,

    pub fn name(self: ArtifactDomain) []const u8 {
        return switch (self) {
            .documentation_audit => "documentation_audit",
            .recipe_consistency => "recipe_consistency",
            .incident_review => "incident_review",
            .generic => "generic",
        };
    }
};

/// A claim detected in an artifact. Claims are surface observations only.
/// They are never proof and never authorizing.
pub const DetectedClaim = struct {
    source_path: []const u8,
    claim_text: []const u8,
    claim_kind: []const u8, // e.g. "build_instruction", "test_instruction", "ingredient", "step"
    confidence: []const u8,
    reason: []const u8,
    non_authorizing: bool = true,
    candidate_only: bool = true,
};

/// An obligation detected in an artifact (e.g. "README says to run X",
/// "recipe step requires ingredient Y"). Obligations are candidate
/// observations, not proof that the obligation is met or unmet.
pub const DetectedObligation = struct {
    source_path: []const u8,
    obligation_text: []const u8,
    obligation_kind: []const u8, // e.g. "build_command", "test_command", "ingredient_use", "step_dependency"
    referenced_by: []const u8, // which artifact surface makes this obligation
    confidence: []const u8,
    reason: []const u8,
    non_authorizing: bool = true,
    candidate_only: bool = true,
};

/// A candidate inconsistency found between artifact claims/obligations.
/// This is a candidate finding, not proof. The inconsistency may have
/// explanations not visible to the inspection (e.g. transitive config,
/// overrides, conditional logic, human context).
pub const CandidateInconsistency = struct {
    id: []const u8,
    inconsistency_kind: []const u8, // e.g. "claim_vs_config", "missing_ingredient", "contradictory_instructions"
    description: []const u8,
    evidence_paths: []const []const u8 = &.{},
    claim_a: []const u8,
    claim_b: []const u8,
    confidence: []const u8,
    reason: []const u8,
    candidate_only: bool = true,
    non_authorizing: bool = true,
    proof_granted: bool = false,
};

/// An explicit unknown — something the inspection could not determine.
/// Unknown is not false. Missing evidence is not negative evidence.
pub const ArtifactUnknown = struct {
    name: []const u8,
    importance: []const u8, // high, medium, low
    reason: []const u8,
    is_missing_evidence: bool = true,
    is_negative_evidence: bool = false,
};

/// The top-level result of a non-code artifact autopsy.
/// This struct carries explicit, redundant safety flags so that
/// downstream renderers and consumers do not need to infer safety
/// from the result's provenance or context.
pub const ArtifactAutopsyResult = struct {
    autopsy_schema_version: []const u8 = "artifact_autopsy.v1",

    /// Which non-code domain this autopsy targets
    artifact_domain: ArtifactDomain = .documentation_audit,

    /// Paths inspected (read-only)
    artifact_paths: []const []const u8 = &.{},

    /// Claims detected in the inspected artifacts
    detected_claims: []const DetectedClaim = &.{},

    /// Obligations detected in the inspected artifacts
    detected_obligations: []const DetectedObligation = &.{},

    /// Candidate inconsistencies between claims/obligations
    inconsistencies: []const CandidateInconsistency = &.{},

    /// Explicit unknowns — what the inspection could not determine
    unknowns: []const ArtifactUnknown = &.{},

    /// Evidence paths referenced across the inspection
    evidence_paths: []const []const u8 = &.{},

    /// Which artifact policy profile was active for this inspection
    active_policy_profile: artifact_policy.DomainProfile = .documentation,

    // ── Safety contract ─────────────────────────────────────────────
    // These fields are deliberately redundant. Every serialized result
    // carries its own safety posture so consumers never need to infer
    // authority from external context.

    read_only: bool = true,
    non_authorizing: bool = true,
    candidate_only: bool = true,
    support_granted: bool = false,
    proof_granted: bool = false,
    commands_executed: bool = false,
    verifiers_executed: bool = false,
    mutates_state: bool = false,
    state: []const u8 = "draft",
};

// ── Fixture: documentation audit ────────────────────────────────────────
//
// This fixture demonstrates a documentation audit where:
//   - README claims one build command ("make build")
//   - A config file (Makefile) implies a different command ("cmake --build build")
//   - The autopsy reports a candidate inconsistency and unknowns without
//     claiming proof.

/// Build a documentation audit fixture result.
/// This is a bounded, deterministic fixture for testing.
/// It does not read the filesystem; it uses hardcoded fixture data.
pub fn documentationAuditFixture() ArtifactAutopsyResult {
    return .{
        .artifact_domain = .documentation_audit,
        .artifact_paths = &.{ "README.md", "Makefile" },
        .detected_claims = &.{
            .{
                .source_path = "README.md",
                .claim_text = "Build with: make build",
                .claim_kind = "build_instruction",
                .confidence = "high",
                .reason = "README contains explicit build instruction text",
            },
            .{
                .source_path = "Makefile",
                .claim_text = "build target invokes cmake --build build",
                .claim_kind = "build_instruction",
                .confidence = "medium",
                .reason = "Makefile build target contains cmake invocation; actual semantics depend on Makefile parse which was not executed",
            },
        },
        .detected_obligations = &.{
            .{
                .source_path = "README.md",
                .obligation_text = "User should be able to run 'make build' successfully",
                .obligation_kind = "build_command",
                .referenced_by = "README.md",
                .confidence = "medium",
                .reason = "README instructs user to run this command; obligation is a candidate, not proof the command works",
            },
        },
        .inconsistencies = &.{
            .{
                .id = "inconsistency.readme_vs_makefile_build",
                .inconsistency_kind = "claim_vs_config",
                .description = "README claims 'make build' but Makefile build target delegates to cmake; the user-facing instruction may not match the actual build mechanism",
                .evidence_paths = &.{ "README.md", "Makefile" },
                .claim_a = "README says: make build",
                .claim_b = "Makefile build target: cmake --build build",
                .confidence = "medium",
                .reason = "surface-level text comparison only; the Makefile may correctly wrap cmake under a make target, which would make the README accurate; this is a candidate inconsistency, not proof of a defect",
            },
        },
        .unknowns = &.{
            .{
                .name = "makefile_target_semantics",
                .importance = "high",
                .reason = "Makefile was not parsed or executed; actual target behavior is unknown; absence of parse evidence is not evidence the target is broken",
            },
            .{
                .name = "readme_staleness",
                .importance = "medium",
                .reason = "README freshness relative to Makefile is unknown; no timestamp comparison was performed",
            },
            .{
                .name = "additional_build_config",
                .importance = "medium",
                .reason = "other build configuration files (CMakeLists.txt, .env, CI config) may exist but were not inspected in this bounded pass",
            },
        },
        .evidence_paths = &.{ "README.md", "Makefile" },
        .active_policy_profile = .documentation,
    };
}

/// Build a recipe consistency fixture result.
/// This is a bounded, deterministic fixture for testing.
pub fn recipeConsistencyFixture() ArtifactAutopsyResult {
    return .{
        .artifact_domain = .recipe_consistency,
        .artifact_paths = &.{"recipe.md"},
        .detected_claims = &.{
            .{
                .source_path = "recipe.md",
                .claim_text = "Ingredients: flour, sugar, butter, eggs, vanilla extract",
                .claim_kind = "ingredient",
                .confidence = "high",
                .reason = "ingredients list explicitly enumerates items",
            },
            .{
                .source_path = "recipe.md",
                .claim_text = "Step 3: fold in chocolate chips",
                .claim_kind = "step",
                .confidence = "high",
                .reason = "step references an ingredient (chocolate chips) not in the ingredients list",
            },
        },
        .detected_obligations = &.{
            .{
                .source_path = "recipe.md",
                .obligation_text = "every ingredient referenced in steps should appear in the ingredients list",
                .obligation_kind = "ingredient_use",
                .referenced_by = "recipe.md",
                .confidence = "medium",
                .reason = "conventional recipe structure implies ingredients list is exhaustive; this is a convention, not a rule",
            },
        },
        .inconsistencies = &.{
            .{
                .id = "inconsistency.missing_ingredient_chocolate_chips",
                .inconsistency_kind = "missing_ingredient",
                .description = "Step 3 references 'chocolate chips' but the ingredients list does not include them",
                .evidence_paths = &.{"recipe.md"},
                .claim_a = "Ingredients list: flour, sugar, butter, eggs, vanilla extract",
                .claim_b = "Step 3: fold in chocolate chips",
                .confidence = "high",
                .reason = "chocolate chips appear in steps but not in ingredients; this may be an intentional optional addition or a documentation omission; candidate inconsistency only",
            },
        },
        .unknowns = &.{
            .{
                .name = "recipe_convention_scope",
                .importance = "medium",
                .reason = "whether the ingredients list is intended to be exhaustive is a convention assumption, not a verified contract",
            },
            .{
                .name = "optional_ingredient_intent",
                .importance = "medium",
                .reason = "chocolate chips may be intentionally optional; the recipe author's intent was not inspected",
            },
        },
        .evidence_paths = &.{"recipe.md"},
        .active_policy_profile = .neutral,
    };
}

// ── File-Backed Audit Implementation ──────────────────────────────────────

pub const MAX_FILES = 10;
pub const MAX_FILE_BYTES = 128 * 1024;
pub const MAX_TOTAL_BYTES = 512 * 1024;

/// Performs a read-only, bounded documentation audit of the provided paths.
/// Returns the fixture if paths are empty.
pub fn documentationAudit(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    paths: []const []const u8,
) !ArtifactAutopsyResult {
    if (paths.len == 0) return documentationAuditFixture();

    if (paths.len > MAX_FILES) return error.TooManyFiles;

    var claims = std.ArrayList(DetectedClaim).init(allocator);
    const obligations = std.ArrayList(DetectedObligation).init(allocator);
    var inconsistencies = std.ArrayList(CandidateInconsistency).init(allocator);
    var unknowns = std.ArrayList(ArtifactUnknown).init(allocator);
    var inspected_paths = std.ArrayList([]const u8).init(allocator);

    var total_bytes: usize = 0;

    var ws_dir = std.fs.cwd().openDir(workspace_root, .{}) catch return error.WorkspaceNotFound;
    defer ws_dir.close();

    var has_config_or_build = false;
    var has_docs = false;
    var doc_command_claim: ?[]const u8 = null;
    var config_command_claim: ?[]const u8 = null;

    for (paths) |p| {
        if (std.fs.path.isAbsolute(p)) return error.AbsolutePathRejected;
        if (std.mem.indexOf(u8, p, "..") != null) return error.PathTraversalRejected;

        const stat = ws_dir.statFile(p) catch |err| {
            try unknowns.append(.{
                .name = "unreadable_file",
                .importance = "high",
                .reason = try std.fmt.allocPrint(allocator, "Could not stat {s}: {s}", .{ p, @errorName(err) }),
            });
            continue;
        };

        if (stat.kind == .directory) return error.DirectoryRejected;

        if (stat.size > MAX_FILE_BYTES) return error.FileTooLarge;
        total_bytes += stat.size;
        if (total_bytes > MAX_TOTAL_BYTES) return error.TotalBytesExceeded;

        const file = ws_dir.openFile(p, .{}) catch |err| {
            try unknowns.append(.{
                .name = "unopenable_file",
                .importance = "high",
                .reason = try std.fmt.allocPrint(allocator, "Could not open {s}: {s}", .{ p, @errorName(err) }),
            });
            continue;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, MAX_FILE_BYTES);

        try inspected_paths.append(try allocator.dupe(u8, p));

        const is_doc = std.mem.endsWith(u8, p, ".md") or std.mem.endsWith(u8, p, ".txt");
        const is_config = std.mem.endsWith(u8, p, "Makefile") or std.mem.endsWith(u8, p, "build.zig") or std.mem.endsWith(u8, p, ".json");

        if (is_config) has_config_or_build = true;
        if (is_doc) has_docs = true;

        if (is_doc) {
            if (std.mem.indexOf(u8, content, "zig build test") != null) {
                doc_command_claim = "zig build test";
                try claims.append(.{
                    .source_path = try allocator.dupe(u8, p),
                    .claim_text = "zig build test",
                    .claim_kind = "test_instruction",
                    .confidence = "medium",
                    .reason = "detected explicit command in docs",
                });
            } else if (std.mem.indexOf(u8, content, "zig build") != null) {
                doc_command_claim = "zig build";
                try claims.append(.{
                    .source_path = try allocator.dupe(u8, p),
                    .claim_text = "zig build",
                    .claim_kind = "build_instruction",
                    .confidence = "medium",
                    .reason = "detected explicit command in docs",
                });
            } else if (std.mem.indexOf(u8, content, "make test") != null) {
                doc_command_claim = "make test";
                try claims.append(.{
                    .source_path = try allocator.dupe(u8, p),
                    .claim_text = "make test",
                    .claim_kind = "test_instruction",
                    .confidence = "medium",
                    .reason = "detected explicit command in docs",
                });
            } else if (std.mem.indexOf(u8, content, "make build") != null) {
                doc_command_claim = "make build";
                try claims.append(.{
                    .source_path = try allocator.dupe(u8, p),
                    .claim_text = "make build",
                    .claim_kind = "build_instruction",
                    .confidence = "medium",
                    .reason = "detected explicit command in docs",
                });
            } else {
                try unknowns.append(.{
                    .name = "ambiguous_commands",
                    .importance = "medium",
                    .reason = "docs provided but no recognizable explicit build/test command found",
                });
            }
        } else if (is_config) {
            if (std.mem.endsWith(u8, p, "Makefile")) {
                config_command_claim = "Makefile targets";
                try claims.append(.{
                    .source_path = try allocator.dupe(u8, p),
                    .claim_text = "Makefile targets",
                    .claim_kind = "build_config",
                    .confidence = "medium",
                    .reason = "Makefile present, implies make commands",
                });
            } else if (std.mem.endsWith(u8, p, "build.zig")) {
                config_command_claim = "zig build targets";
                try claims.append(.{
                    .source_path = try allocator.dupe(u8, p),
                    .claim_text = "zig build targets",
                    .claim_kind = "build_config",
                    .confidence = "high",
                    .reason = "build.zig present, implies zig commands",
                });
            }
        } else {
            try unknowns.append(.{
                .name = "unknown_file_type",
                .importance = "low",
                .reason = try std.fmt.allocPrint(allocator, "file {s} is neither recognized doc nor config", .{p}),
            });
        }
    }

    if (has_docs and !has_config_or_build) {
        try unknowns.append(.{
            .name = "missing_build_evidence",
            .importance = "high",
            .reason = "documentation provided without corresponding configuration or build files to verify against",
        });
    }

    if (doc_command_claim != null and config_command_claim != null) {
        try inconsistencies.append(.{
            .id = "inconsistency.claim_vs_config_surface",
            .inconsistency_kind = "claim_vs_config",
            .description = "documentation claims one command behavior but underlying config may differ; exact execution semantics unknown",
            .evidence_paths = try allocator.dupe([]const u8, inspected_paths.items),
            .claim_a = try allocator.dupe(u8, doc_command_claim.?),
            .claim_b = try allocator.dupe(u8, config_command_claim.?),
            .confidence = "medium",
            .reason = "candidate only: static file audit cannot prove command alignment without execution",
        });
    }

    const result = ArtifactAutopsyResult{
        .artifact_domain = .documentation_audit,
        .active_policy_profile = .documentation,
        .artifact_paths = inspected_paths.items,
        .evidence_paths = inspected_paths.items,
        .detected_claims = claims.items,
        .detected_obligations = obligations.items,
        .inconsistencies = inconsistencies.items,
        .unknowns = unknowns.items,
    };

    return result;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// ── 1. Safety contract defaults ─────────────────────────────────────────

test "artifact autopsy result defaults enforce read-only non-authorizing contract" {
    const result = ArtifactAutopsyResult{};
    try std.testing.expect(result.read_only);
    try std.testing.expect(result.non_authorizing);
    try std.testing.expect(result.candidate_only);
    try std.testing.expect(!result.support_granted);
    try std.testing.expect(!result.proof_granted);
    try std.testing.expect(!result.commands_executed);
    try std.testing.expect(!result.verifiers_executed);
    try std.testing.expect(!result.mutates_state);
    try std.testing.expectEqualStrings("draft", result.state);
}

test "detected claims are candidate-only and non-authorizing by default" {
    const claim = DetectedClaim{
        .source_path = "test.md",
        .claim_text = "test claim",
        .claim_kind = "test",
        .confidence = "low",
        .reason = "test",
    };
    try std.testing.expect(claim.non_authorizing);
    try std.testing.expect(claim.candidate_only);
}

test "detected obligations are candidate-only and non-authorizing by default" {
    const obligation = DetectedObligation{
        .source_path = "test.md",
        .obligation_text = "test obligation",
        .obligation_kind = "test",
        .referenced_by = "test.md",
        .confidence = "low",
        .reason = "test",
    };
    try std.testing.expect(obligation.non_authorizing);
    try std.testing.expect(obligation.candidate_only);
}

test "candidate inconsistencies never grant proof" {
    const inconsistency = CandidateInconsistency{
        .id = "test",
        .inconsistency_kind = "test",
        .description = "test",
        .claim_a = "a",
        .claim_b = "b",
        .confidence = "low",
        .reason = "test",
    };
    try std.testing.expect(inconsistency.candidate_only);
    try std.testing.expect(inconsistency.non_authorizing);
    try std.testing.expect(!inconsistency.proof_granted);
}

test "artifact unknowns represent missing evidence, not negative evidence" {
    const unknown = ArtifactUnknown{
        .name = "test",
        .importance = "high",
        .reason = "test",
    };
    try std.testing.expect(unknown.is_missing_evidence);
    try std.testing.expect(!unknown.is_negative_evidence);
}

// ── 2. Documentation audit fixture ──────────────────────────────────────

test "documentation audit fixture detects candidate inconsistency between README and config" {
    const result = documentationAuditFixture();

    // Domain is documentation_audit, not code
    try std.testing.expectEqual(ArtifactDomain.documentation_audit, result.artifact_domain);

    // Uses documentation profile, not code profile
    try std.testing.expectEqual(artifact_policy.DomainProfile.documentation, result.active_policy_profile);

    // Inspected two artifact paths
    try std.testing.expectEqual(@as(usize, 2), result.artifact_paths.len);

    // Detected claims from both surfaces
    try std.testing.expectEqual(@as(usize, 2), result.detected_claims.len);
    try std.testing.expectEqualStrings("README.md", result.detected_claims[0].source_path);
    try std.testing.expectEqualStrings("Makefile", result.detected_claims[1].source_path);

    // Detected one obligation
    try std.testing.expectEqual(@as(usize, 1), result.detected_obligations.len);
    try std.testing.expectEqualStrings("build_command", result.detected_obligations[0].obligation_kind);

    // Found one candidate inconsistency
    try std.testing.expectEqual(@as(usize, 1), result.inconsistencies.len);
    try std.testing.expectEqualStrings("claim_vs_config", result.inconsistencies[0].inconsistency_kind);

    // Inconsistency is candidate, not proof
    try std.testing.expect(result.inconsistencies[0].candidate_only);
    try std.testing.expect(result.inconsistencies[0].non_authorizing);
    try std.testing.expect(!result.inconsistencies[0].proof_granted);

    // Has explicit unknowns
    try std.testing.expect(result.unknowns.len > 0);

    // All unknowns are missing evidence, not negative evidence
    for (result.unknowns) |unknown| {
        try std.testing.expect(unknown.is_missing_evidence);
        try std.testing.expect(!unknown.is_negative_evidence);
    }

    // Top-level safety contract is preserved
    try std.testing.expect(result.read_only);
    try std.testing.expect(result.non_authorizing);
    try std.testing.expect(!result.proof_granted);
    try std.testing.expect(!result.commands_executed);
    try std.testing.expect(!result.verifiers_executed);
    try std.testing.expect(!result.mutates_state);
}

test "documentation audit fixture uses documentation policy, not code policy" {
    const result = documentationAuditFixture();
    const doc_policy = artifact_policy.docsProfileSummary();

    // The fixture uses the documentation profile
    try std.testing.expectEqual(artifact_policy.DomainProfile.documentation, result.active_policy_profile);

    // The documentation policy does not penalize file breadth (unlike code policy)
    try std.testing.expectEqual(@as(u32, 0), doc_policy.intervention_file_cost);
    try std.testing.expectEqual(@as(u32, 0), doc_policy.intervention_dependency_cost);

    // Documentation policy weights docs higher than code
    try std.testing.expect(doc_policy.family_docs_weight > doc_policy.family_code_weight);

    // Neither the result nor the policy grants proof
    try std.testing.expect(!result.proof_granted);
    try std.testing.expect(!doc_policy.proof_granted);
}

// ── 3. Recipe consistency fixture ───────────────────────────────────────

test "recipe consistency fixture detects missing ingredient candidate" {
    const result = recipeConsistencyFixture();

    // Domain is recipe_consistency
    try std.testing.expectEqual(ArtifactDomain.recipe_consistency, result.artifact_domain);

    // Uses neutral profile (recipes are not code or documentation)
    try std.testing.expectEqual(artifact_policy.DomainProfile.neutral, result.active_policy_profile);

    // Found the missing ingredient inconsistency
    try std.testing.expectEqual(@as(usize, 1), result.inconsistencies.len);
    try std.testing.expectEqualStrings("missing_ingredient", result.inconsistencies[0].inconsistency_kind);

    // Inconsistency is candidate only, not proof
    try std.testing.expect(result.inconsistencies[0].candidate_only);
    try std.testing.expect(!result.inconsistencies[0].proof_granted);

    // Has unknowns about convention scope and intent
    try std.testing.expect(result.unknowns.len >= 2);

    // Safety contract holds
    try std.testing.expect(result.read_only);
    try std.testing.expect(result.non_authorizing);
    try std.testing.expect(!result.mutates_state);
}

// ── 4. Domain profile routing ───────────────────────────────────────────

test "artifact domain names are distinct and non-empty" {
    const domains = [_]ArtifactDomain{
        .documentation_audit,
        .recipe_consistency,
        .incident_review,
        .generic,
    };
    for (domains) |domain| {
        try std.testing.expect(domain.name().len > 0);
    }
    // All names are distinct
    for (domains, 0..) |a, i| {
        for (domains[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name(), b.name()));
        }
    }
}

test "non-code autopsy result does not default to code profile" {
    const result = ArtifactAutopsyResult{};
    // Default is documentation profile, not code
    try std.testing.expectEqual(artifact_policy.DomainProfile.documentation, result.active_policy_profile);
}

// ── 5. Cross-domain safety invariant ────────────────────────────────────

test "both fixture domains preserve identical safety contract" {
    const doc_result = documentationAuditFixture();
    const recipe_result = recipeConsistencyFixture();

    // Both are read-only, non-authorizing, candidate-only
    try std.testing.expectEqual(doc_result.read_only, recipe_result.read_only);
    try std.testing.expectEqual(doc_result.non_authorizing, recipe_result.non_authorizing);
    try std.testing.expectEqual(doc_result.candidate_only, recipe_result.candidate_only);
    try std.testing.expectEqual(doc_result.support_granted, recipe_result.support_granted);
    try std.testing.expectEqual(doc_result.proof_granted, recipe_result.proof_granted);
    try std.testing.expectEqual(doc_result.commands_executed, recipe_result.commands_executed);
    try std.testing.expectEqual(doc_result.verifiers_executed, recipe_result.verifiers_executed);
    try std.testing.expectEqual(doc_result.mutates_state, recipe_result.mutates_state);
    try std.testing.expectEqualStrings(doc_result.state, recipe_result.state);

    // But they use different artifact domains and policy profiles
    try std.testing.expect(doc_result.artifact_domain != recipe_result.artifact_domain);
    try std.testing.expect(doc_result.active_policy_profile != recipe_result.active_policy_profile);
}

// ── 6. File-backed Documentation Audit ──────────────────────────────────

test "documentation audit with empty paths falls back to fixture" {
    const result = try documentationAudit(std.testing.allocator, ".", &.{});
    try std.testing.expectEqual(ArtifactDomain.documentation_audit, result.artifact_domain);
    try std.testing.expectEqualStrings("README.md", result.evidence_paths[0]);
}

test "documentation audit rejects path traversal" {
    const err = documentationAudit(std.testing.allocator, ".", &.{"../outside.md"});
    try std.testing.expectError(error.PathTraversalRejected, err);
}

test "documentation audit rejects absolute paths" {
    const err = documentationAudit(std.testing.allocator, ".", &.{"/etc/passwd"});
    try std.testing.expectError(error.AbsolutePathRejected, err);
}

test "documentation audit rejects too many files" {
    const paths = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k" };
    const err = documentationAudit(std.testing.allocator, ".", &paths);
    try std.testing.expectError(error.TooManyFiles, err);
}

test "documentation audit detects generic config vs doc inconsistency" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "Run `make build`" });
    try tmp.dir.writeFile(.{ .sub_path = "Makefile", .data = "build:\n\tcmake --build build\n" });

    const ws = try tmp.dir.realpathAlloc(allocator, ".");

    const paths = [_][]const u8{ "README.md", "Makefile" };
    const result = try documentationAudit(allocator, ws, &paths);

    // Check safety invariants
    try std.testing.expect(result.read_only);
    try std.testing.expect(result.non_authorizing);
    try std.testing.expect(result.candidate_only);
    try std.testing.expect(!result.mutates_state);

    // Found generic inconsistency
    try std.testing.expectEqual(@as(usize, 1), result.inconsistencies.len);
    try std.testing.expectEqualStrings("claim_vs_config", result.inconsistencies[0].inconsistency_kind);
}

test "documentation audit explicit docs-only reports missing build evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "Some docs without commands." });

    const ws = try tmp.dir.realpathAlloc(allocator, ".");

    const paths = [_][]const u8{"README.md"};
    const result = try documentationAudit(allocator, ws, &paths);

    // Check missing build evidence
    try std.testing.expectEqual(@as(usize, 2), result.unknowns.len);
    var found_missing = false;
    for (result.unknowns) |u| {
        if (std.mem.eql(u8, u.name, "missing_build_evidence")) found_missing = true;
    }
    try std.testing.expect(found_missing);
}
