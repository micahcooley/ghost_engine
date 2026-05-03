const std = @import("std");

pub const DEFAULT_MAX_ENTRIES: usize = 4096;
pub const DEFAULT_MAX_DEPTH: usize = 6;
pub const MAX_FILE_READ_BYTES: usize = 128 * 1024;
const MAX_OPERATOR_SUMMARY_ITEMS: usize = 5;

pub const AnalyzeOptions = struct {
    max_entries: usize = DEFAULT_MAX_ENTRIES,
    max_depth: usize = DEFAULT_MAX_DEPTH,
};

pub const Signal = struct {
    name: []const u8,
    path: []const u8,
    kind: []const u8,
    confidence: []const u8,
    reason: []const u8,
    evidence_paths: []const []const u8 = &.{},
    non_authorizing: bool = true,
    freshness_unknown: bool = true,
};

pub const RiskSurface = struct {
    id: []const u8,
    kind: []const u8,
    path: []const u8,
    related_paths: []const []const u8 = &.{},
    risk_level: []const u8,
    risk_kind: []const u8,
    reason: []const u8,
    evidence_paths: []const []const u8 = &.{},
    suggested_caution: []const u8,
    non_authorizing: bool = true,
    requires_verification: bool = true,
};

pub const VerifierGapCandidate = struct {
    id: []const u8,
    kind: []const u8 = "verifier_gap",
    missing_verifier: []const u8,
    reason: []const u8,
    related_paths: []const []const u8 = &.{},
    evidence_paths: []const []const u8 = &.{},
    non_authorizing: bool = true,
    blocks_support: bool = true,
};

pub const RootCandidate = struct {
    path: []const u8,
    kind: []const u8,
    confidence: []const u8,
    reason: []const u8,
    evidence_paths: []const []const u8 = &.{},
    detected_language: ?[]const u8 = null,
    non_authorizing: bool = true,
};

pub const SafeCommandCandidate = struct {
    id: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    purpose: []const u8,
    reason: []const u8,
    detected_from: []const u8,
    risk_level: []const u8,
    read_only: bool = false,
    mutation_risk_disclosure: []const u8,
    why_candidate_exists: []const u8,
    executes_by_default: bool = false,
    requires_user_confirmation: bool = true,
    non_authorizing: bool = true,
};

pub const VerifierPlanCandidate = struct {
    id: []const u8,
    argv: []const []const u8,
    cwd_hint: []const u8,
    purpose: []const u8,
    risk_level: []const u8,
    confidence: []const u8,
    requires_user_confirmation: bool = true,
    non_authorizing: bool = true,
    executes_by_default: bool = false,
    source_evidence_paths: []const []const u8 = &.{},
    why_candidate_exists: []const u8,
    unknowns: []const []const u8 = &.{},
};

pub const RecommendedGuidanceCandidate = struct {
    id: []const u8,
    kind: []const u8,
    pack_id: ?[]const u8 = null,
    guidance_id: []const u8,
    reason: []const u8,
    evidence_paths: []const []const u8 = &.{},
    related_languages: []const []const u8 = &.{},
    related_risks: []const []const u8 = &.{},
    related_verifier_gaps: []const []const u8 = &.{},
    suggested_next_action: []const u8,
    non_authorizing: bool = true,
    candidate_only: bool = true,
    requires_review: bool = true,
    mutates_state: bool = false,
    applies_by_default: bool = false,
};

pub const OperatorSummaryItem = struct {
    id: []const u8,
    kind: []const u8,
    reason: []const u8,
    evidence_paths: []const []const u8 = &.{},
    non_authorizing: bool = true,
};

pub const OperatorSummaryActionCandidate = struct {
    id: []const u8,
    kind: []const u8,
    reason: []const u8,
    references: []const []const u8 = &.{},
    candidate_only: bool = true,
    non_authorizing: bool = true,
    read_only: bool = true,
    executes_by_default: bool = false,
    applies_by_default: bool = false,
};

pub const OperatorSummary = struct {
    project_shape_summary: []const u8,
    primary_languages: []const []const u8 = &.{},
    primary_build_systems: []const []const u8 = &.{},
    source_root_count: usize = 0,
    test_root_count: usize = 0,
    ci_detected: bool = false,
    docs_detected: bool = false,
    config_surface_count: usize = 0,
    safe_command_candidate_count: usize = 0,
    risk_surface_count: usize = 0,
    verifier_gap_count: usize = 0,
    guidance_candidate_count: usize = 0,
    top_unknowns: []OperatorSummaryItem = &.{},
    top_risks: []OperatorSummaryItem = &.{},
    top_verifier_gaps: []OperatorSummaryItem = &.{},
    suggested_next_actions: []OperatorSummaryActionCandidate = &.{},
    non_authorizing: bool = true,
    read_only: bool = true,
};

pub const VerifierGapSummary = struct {
    known_possible_verifier_adapters: []Signal = &.{},
    missing_likely_verifier_adapters: []VerifierGapCandidate = &.{},
    unknown_verifier_status: []Signal = &.{},
    recommended_next_checks: []Signal = &.{},
};

pub const ProjectProfile = struct {
    workspace_root: []const u8,
    detected_languages: []Signal = &.{},
    detected_frameworks: []Signal = &.{},
    build_systems: []Signal = &.{},
    test_commands: []Signal = &.{},
    package_managers: []Signal = &.{},
    ci_configs: []Signal = &.{},
    docs: []Signal = &.{},
    config_files: []Signal = &.{},
    source_roots: []RootCandidate = &.{},
    test_roots: []RootCandidate = &.{},
    entry_points: []Signal = &.{},
    dependency_files: []Signal = &.{},
    risk_surfaces: []RiskSurface = &.{},
    safe_command_candidates: []SafeCommandCandidate = &.{},
    verifier_gap_summary: VerifierGapSummary = .{},
    recommended_packs: []Signal = &.{},
    recommended_guidance_candidates: []RecommendedGuidanceCandidate = &.{},
    unknowns: []Signal = &.{},
    confidence_summary: []const u8 = "draft profile; no correctness claims",
    non_authorizing: bool = true,
    trace: []Signal = &.{},
};

pub const ProjectGapReport = struct {
    missing_test_command: ?Signal = null,
    missing_build_command: ?Signal = null,
    missing_ci: ?Signal = null,
    missing_docs: ?Signal = null,
    missing_verifier_adapters: []VerifierGapCandidate = &.{},
    missing_pack_recommendations: []Signal = &.{},
    ambiguous_project_type: []Signal = &.{},
    unsafe_or_unknown_commands: []Signal = &.{},
    next_questions: []Signal = &.{},
    non_authorizing: bool = true,
};

pub const AutopsyResult = struct {
    operator_summary: OperatorSummary,
    project_profile: ProjectProfile,
    project_gap_report: ProjectGapReport,
    verifier_plan_candidates: []VerifierPlanCandidate = &.{},
    state: []const u8 = "draft",
    non_authorizing: bool = true,

    pub fn writeJson(self: AutopsyResult, writer: anytype) !void {
        try std.json.stringify(self, .{ .whitespace = .indent_2 }, writer);
    }
};

const Entry = struct {
    rel_path: []const u8,
    basename: []const u8,
    is_dir: bool,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    entries: []Entry,
    languages: std.ArrayList(Signal),
    frameworks: std.ArrayList(Signal),
    build_systems: std.ArrayList(Signal),
    test_commands: std.ArrayList(Signal),
    package_managers: std.ArrayList(Signal),
    ci_configs: std.ArrayList(Signal),
    docs: std.ArrayList(Signal),
    config_files: std.ArrayList(Signal),
    source_roots: std.ArrayList(RootCandidate),
    test_roots: std.ArrayList(RootCandidate),
    entry_points: std.ArrayList(Signal),
    dependency_files: std.ArrayList(Signal),
    risk_surfaces: std.ArrayList(RiskSurface),
    safe_commands: std.ArrayList(SafeCommandCandidate),
    verifier_plans: std.ArrayList(VerifierPlanCandidate),
    recommended_packs: std.ArrayList(Signal),
    recommended_guidance_candidates: std.ArrayList(RecommendedGuidanceCandidate),
    unknowns: std.ArrayList(Signal),
    trace: std.ArrayList(Signal),
    possible_verifiers: std.ArrayList(Signal),
    missing_verifiers: std.ArrayList(VerifierGapCandidate),
    unknown_verifiers: std.ArrayList(Signal),
    next_checks: std.ArrayList(Signal),
    gap_missing_verifiers: std.ArrayList(VerifierGapCandidate),
    missing_pack_recommendations: std.ArrayList(Signal),
    ambiguous_project_type: std.ArrayList(Signal),
    unsafe_or_unknown_commands: std.ArrayList(Signal),
    next_questions: std.ArrayList(Signal),

    fn init(allocator: std.mem.Allocator, root_abs: []const u8, entries: []Entry) Builder {
        return .{
            .allocator = allocator,
            .root_abs = root_abs,
            .entries = entries,
            .languages = .init(allocator),
            .frameworks = .init(allocator),
            .build_systems = .init(allocator),
            .test_commands = .init(allocator),
            .package_managers = .init(allocator),
            .ci_configs = .init(allocator),
            .docs = .init(allocator),
            .config_files = .init(allocator),
            .source_roots = .init(allocator),
            .test_roots = .init(allocator),
            .entry_points = .init(allocator),
            .dependency_files = .init(allocator),
            .risk_surfaces = .init(allocator),
            .safe_commands = .init(allocator),
            .verifier_plans = .init(allocator),
            .recommended_packs = .init(allocator),
            .recommended_guidance_candidates = .init(allocator),
            .unknowns = .init(allocator),
            .trace = .init(allocator),
            .possible_verifiers = .init(allocator),
            .missing_verifiers = .init(allocator),
            .unknown_verifiers = .init(allocator),
            .next_checks = .init(allocator),
            .gap_missing_verifiers = .init(allocator),
            .missing_pack_recommendations = .init(allocator),
            .ambiguous_project_type = .init(allocator),
            .unsafe_or_unknown_commands = .init(allocator),
            .next_questions = .init(allocator),
        };
    }

    fn signal(self: *Builder, name: []const u8, path: []const u8, kind: []const u8, confidence: []const u8, reason: []const u8) !Signal {
        const evidence_paths = try signalEvidencePaths(self.allocator, path);
        return .{
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, path),
            .kind = try self.allocator.dupe(u8, kind),
            .confidence = try self.allocator.dupe(u8, confidence),
            .reason = try self.allocator.dupe(u8, reason),
            .evidence_paths = evidence_paths,
        };
    }

    fn appendSignal(self: *Builder, list: *std.ArrayList(Signal), name: []const u8, path: []const u8, kind: []const u8, confidence: []const u8, reason: []const u8) !void {
        if (containsSignal(list.items, name, path, kind)) return;
        try list.append(try self.signal(name, path, kind, confidence, reason));
    }

    fn appendRisk(self: *Builder, id: []const u8, kind: []const u8, path: []const u8, risk_level: []const u8, reason_text: []const u8, caution: []const u8) !void {
        const paths = if (path.len == 0) &.{} else &[_][]const u8{path};
        try self.appendRiskWithPaths(id, kind, path, paths, risk_level, reason_text, caution);
    }

    fn appendRiskWithPaths(self: *Builder, id: []const u8, kind: []const u8, path: []const u8, related_paths: []const []const u8, risk_level: []const u8, reason_text: []const u8, caution: []const u8) !void {
        if (containsRisk(self.risk_surfaces.items, id)) return;
        const related = try dupeStringSlice(self.allocator, related_paths);
        const evidence = try dupeStringSlice(self.allocator, related_paths);
        try self.risk_surfaces.append(.{
            .id = try self.allocator.dupe(u8, id),
            .kind = try self.allocator.dupe(u8, kind),
            .path = try self.allocator.dupe(u8, path),
            .related_paths = related,
            .risk_level = try self.allocator.dupe(u8, risk_level),
            .risk_kind = try self.allocator.dupe(u8, kind),
            .reason = try self.allocator.dupe(u8, reason_text),
            .evidence_paths = evidence,
            .suggested_caution = try self.allocator.dupe(u8, caution),
        });
    }

    fn appendVerifierGap(self: *Builder, id: []const u8, missing_verifier: []const u8, reason_text: []const u8, related_paths: []const []const u8, blocks_support: bool) !void {
        if (containsVerifierGap(self.gap_missing_verifiers.items, id)) return;
        const candidate = try self.verifierGap(id, missing_verifier, reason_text, related_paths, blocks_support);
        try self.gap_missing_verifiers.append(candidate);
        if (!containsVerifierGap(self.missing_verifiers.items, id)) {
            try self.missing_verifiers.append(try self.verifierGap(id, missing_verifier, reason_text, related_paths, blocks_support));
        }
    }

    fn verifierGap(self: *Builder, id: []const u8, missing_verifier: []const u8, reason_text: []const u8, related_paths: []const []const u8, blocks_support: bool) !VerifierGapCandidate {
        return .{
            .id = try self.allocator.dupe(u8, id),
            .missing_verifier = try self.allocator.dupe(u8, missing_verifier),
            .reason = try self.allocator.dupe(u8, reason_text),
            .related_paths = try dupeStringSlice(self.allocator, related_paths),
            .evidence_paths = try dupeStringSlice(self.allocator, related_paths),
            .blocks_support = blocks_support,
        };
    }

    fn appendRootCandidate(self: *Builder, list: *std.ArrayList(RootCandidate), path: []const u8, kind: []const u8, confidence: []const u8, reason: []const u8) !void {
        if (containsRootCandidate(list.items, path, kind)) return;
        const evidence_paths = try rootEvidencePaths(self.allocator, self.entries, path);
        const language_hint = try rootLanguageHint(self.allocator, self.entries, path);
        try list.append(.{
            .path = try self.allocator.dupe(u8, path),
            .kind = try self.allocator.dupe(u8, kind),
            .confidence = try self.allocator.dupe(u8, confidence),
            .reason = try self.allocator.dupe(u8, reason),
            .evidence_paths = evidence_paths,
            .detected_language = language_hint,
        });
        try self.appendSignal(&self.trace, path, path, "root_candidate_evidence", confidence, reason);
    }

    fn appendCommand(self: *Builder, id: []const u8, argv: []const []const u8, detected_from: []const u8, reason: []const u8, risk_level: []const u8) !void {
        for (self.safe_commands.items) |candidate| {
            if (std.mem.eql(u8, candidate.id, id)) return;
        }
        for (argv) |part| {
            if (std.mem.eql(u8, part, "sudo") or std.mem.eql(u8, part, "install") or std.mem.indexOfScalar(u8, part, ';') != null) {
                try self.appendSignal(&self.unsafe_or_unknown_commands, id, detected_from, "unsafe_command_rejected", "high", "command candidate rejected by Pass 1 safety policy");
                return;
            }
        }
        const argv_copy = try self.allocator.alloc([]const u8, argv.len);
        for (argv, 0..) |part, i| argv_copy[i] = try self.allocator.dupe(u8, part);
        try self.safe_commands.append(.{
            .id = try self.allocator.dupe(u8, id),
            .argv = argv_copy,
            .cwd = try self.allocator.dupe(u8, self.root_abs),
            .purpose = try self.allocator.dupe(u8, verifierPlanPurpose(id)),
            .reason = try self.allocator.dupe(u8, reason),
            .detected_from = try self.allocator.dupe(u8, detected_from),
            .risk_level = try self.allocator.dupe(u8, risk_level),
            .mutation_risk_disclosure = try self.allocator.dupe(u8, commandMutationRiskDisclosure(id)),
            .why_candidate_exists = try std.fmt.allocPrint(self.allocator, "{s}; detected from {s}; candidate only and not executed", .{ reason, detected_from }),
        });
        try self.appendVerifierPlan(id, argv, detected_from, reason, risk_level);
    }

    fn appendVerifierPlan(self: *Builder, id: []const u8, argv: []const []const u8, detected_from: []const u8, reason: []const u8, risk_level: []const u8) !void {
        for (self.verifier_plans.items) |candidate| {
            if (std.mem.eql(u8, candidate.id, id)) return;
        }

        const argv_copy = try self.allocator.alloc([]const u8, argv.len);
        for (argv, 0..) |part, i| argv_copy[i] = try self.allocator.dupe(u8, part);

        const source_paths = try self.allocator.alloc([]const u8, 1);
        source_paths[0] = try self.allocator.dupe(u8, detected_from);

        const unknown_templates = verifierPlanUnknowns(id);
        const unknowns = try self.allocator.alloc([]const u8, unknown_templates.len);
        for (unknown_templates, 0..) |item, i| unknowns[i] = try self.allocator.dupe(u8, item);

        try self.verifier_plans.append(.{
            .id = try self.allocator.dupe(u8, id),
            .argv = argv_copy,
            .cwd_hint = try self.allocator.dupe(u8, self.root_abs),
            .purpose = try self.allocator.dupe(u8, verifierPlanPurpose(id)),
            .risk_level = try self.allocator.dupe(u8, risk_level),
            .confidence = try self.allocator.dupe(u8, verifierPlanConfidence(id, detected_from)),
            .source_evidence_paths = source_paths,
            .why_candidate_exists = try std.fmt.allocPrint(self.allocator, "{s}; derived from autopsy command candidate and not executed", .{reason}),
            .unknowns = unknowns,
        });
    }

    fn appendGuidanceCandidate(
        self: *Builder,
        id: []const u8,
        kind: []const u8,
        guidance_id: []const u8,
        reason_text: []const u8,
        evidence_paths: []const []const u8,
        related_languages: []const []const u8,
        related_risks: []const []const u8,
        related_verifier_gaps: []const []const u8,
        suggested_next_action: []const u8,
    ) !void {
        if (containsGuidanceCandidate(self.recommended_guidance_candidates.items, id)) return;
        try self.recommended_guidance_candidates.append(.{
            .id = try self.allocator.dupe(u8, id),
            .kind = try self.allocator.dupe(u8, kind),
            .guidance_id = try self.allocator.dupe(u8, guidance_id),
            .reason = try self.allocator.dupe(u8, reason_text),
            .evidence_paths = try dupeStringSlice(self.allocator, evidence_paths),
            .related_languages = try dupeStringSlice(self.allocator, related_languages),
            .related_risks = try dupeStringSlice(self.allocator, related_risks),
            .related_verifier_gaps = try dupeStringSlice(self.allocator, related_verifier_gaps),
            .suggested_next_action = try self.allocator.dupe(u8, suggested_next_action),
        });
    }

    fn finish(self: *Builder) !AutopsyResult {
        sortSignals(self.languages.items);
        sortSignals(self.frameworks.items);
        sortSignals(self.build_systems.items);
        sortSignals(self.test_commands.items);
        sortSignals(self.package_managers.items);
        sortSignals(self.ci_configs.items);
        sortSignals(self.docs.items);
        sortSignals(self.config_files.items);
        sortRootCandidates(self.source_roots.items);
        sortRootCandidates(self.test_roots.items);
        sortSignals(self.entry_points.items);
        sortSignals(self.dependency_files.items);
        sortRisks(self.risk_surfaces.items);
        sortCommands(self.safe_commands.items);
        sortVerifierPlans(self.verifier_plans.items);
        sortSignals(self.recommended_packs.items);
        sortGuidanceCandidates(self.recommended_guidance_candidates.items);
        sortSignals(self.unknowns.items);
        sortSignals(self.trace.items);
        sortSignals(self.possible_verifiers.items);
        sortVerifierGaps(self.missing_verifiers.items);
        sortSignals(self.unknown_verifiers.items);
        sortSignals(self.next_checks.items);
        sortVerifierGaps(self.gap_missing_verifiers.items);
        sortSignals(self.missing_pack_recommendations.items);
        sortSignals(self.ambiguous_project_type.items);
        sortSignals(self.unsafe_or_unknown_commands.items);
        sortSignals(self.next_questions.items);

        const missing_test = if (self.test_commands.items.len == 0)
            try self.signal("missing_test_command", "", "gap", "high", "no deterministic test command signal was detected")
        else
            null;
        const missing_build = if (!hasBuildCommand(self.safe_commands.items))
            try self.signal("missing_build_command", "", "gap", "medium", "no deterministic build command signal was detected")
        else
            null;
        const missing_ci = if (self.ci_configs.items.len == 0)
            try self.signal("missing_ci", "", "gap", "medium", "no CI configuration was detected")
        else
            null;
        const missing_docs = if (self.docs.items.len == 0)
            try self.signal("missing_docs", "", "gap", "medium", "no README or docs directory was detected")
        else
            null;
        const operator_summary = try buildOperatorSummary(self);

        return .{
            .operator_summary = operator_summary,
            .project_profile = .{
                .workspace_root = try self.allocator.dupe(u8, self.root_abs),
                .detected_languages = try self.languages.toOwnedSlice(),
                .detected_frameworks = try self.frameworks.toOwnedSlice(),
                .build_systems = try self.build_systems.toOwnedSlice(),
                .test_commands = try self.test_commands.toOwnedSlice(),
                .package_managers = try self.package_managers.toOwnedSlice(),
                .ci_configs = try self.ci_configs.toOwnedSlice(),
                .docs = try self.docs.toOwnedSlice(),
                .config_files = try self.config_files.toOwnedSlice(),
                .source_roots = try self.source_roots.toOwnedSlice(),
                .test_roots = try self.test_roots.toOwnedSlice(),
                .entry_points = try self.entry_points.toOwnedSlice(),
                .dependency_files = try self.dependency_files.toOwnedSlice(),
                .risk_surfaces = try self.risk_surfaces.toOwnedSlice(),
                .safe_command_candidates = try self.safe_commands.toOwnedSlice(),
                .verifier_gap_summary = .{
                    .known_possible_verifier_adapters = try self.possible_verifiers.toOwnedSlice(),
                    .missing_likely_verifier_adapters = try self.missing_verifiers.toOwnedSlice(),
                    .unknown_verifier_status = try self.unknown_verifiers.toOwnedSlice(),
                    .recommended_next_checks = try self.next_checks.toOwnedSlice(),
                },
                .recommended_packs = try self.recommended_packs.toOwnedSlice(),
                .recommended_guidance_candidates = try self.recommended_guidance_candidates.toOwnedSlice(),
                .unknowns = try self.unknowns.toOwnedSlice(),
                .confidence_summary = if (self.unknowns.items.len == 0) "high confidence for detected signals only; no correctness claims" else "partial profile; unknowns remain explicit and non-authorizing",
                .trace = try self.trace.toOwnedSlice(),
            },
            .project_gap_report = .{
                .missing_test_command = missing_test,
                .missing_build_command = missing_build,
                .missing_ci = missing_ci,
                .missing_docs = missing_docs,
                .missing_verifier_adapters = try self.gap_missing_verifiers.toOwnedSlice(),
                .missing_pack_recommendations = try self.missing_pack_recommendations.toOwnedSlice(),
                .ambiguous_project_type = try self.ambiguous_project_type.toOwnedSlice(),
                .unsafe_or_unknown_commands = try self.unsafe_or_unknown_commands.toOwnedSlice(),
                .next_questions = try self.next_questions.toOwnedSlice(),
            },
            .verifier_plan_candidates = try self.verifier_plans.toOwnedSlice(),
        };
    }
};

pub fn analyze(allocator: std.mem.Allocator, workspace_root: []const u8, options: AnalyzeOptions) !AutopsyResult {
    const root_abs = try std.fs.cwd().realpathAlloc(allocator, workspace_root);
    defer allocator.free(root_abs);
    const entries = try collectEntries(allocator, root_abs, options);
    defer freeEntries(allocator, entries);

    var builder = Builder.init(allocator, root_abs, entries);
    try builder.appendSignal(&builder.trace, "project_autopsy_pass_1", "", "trace", "high", "bounded read-only filesystem inspection; no commands executed");
    try detectCommon(&builder);
    try detectLanguagesAndCommands(&builder);
    try detectRisks(&builder);
    try detectGaps(&builder, options, entries.len);
    try detectRecommendedGuidance(&builder);
    try detectGuidanceGaps(&builder);
    return builder.finish();
}

pub fn writeJson(allocator: std.mem.Allocator, workspace_root: []const u8, writer: anytype) !void {
    const result = try analyze(allocator, workspace_root, .{});
    try result.writeJson(writer);
}

fn detectCommon(builder: *Builder) !void {
    for (builder.entries) |entry| {
        if (entry.is_dir) {
            if (isConventionalSourceRoot(entry.rel_path)) {
                try builder.appendRootCandidate(&builder.source_roots, entry.rel_path, "source_root", sourceRootConfidence(entry.rel_path), sourceRootReason(entry.rel_path));
            }
            if (isConventionalTestRoot(entry.rel_path)) {
                try builder.appendRootCandidate(&builder.test_roots, entry.rel_path, "test_root", testRootConfidence(entry.rel_path), testRootReason(entry.rel_path));
            }
            if (std.mem.eql(u8, entry.rel_path, "docs")) try builder.appendSignal(&builder.docs, "docs", entry.rel_path, "documentation", "high", "docs directory exists; documentation is a claim surface, not proof");
            continue;
        }

        if (ciSurfaceName(entry.rel_path)) |name| {
            try builder.appendSignal(&builder.ci_configs, name, entry.rel_path, "ci_config", "high", "CI configuration file exists; intended workflow evidence only, not proof it passes");
        }

        if (documentationSurfaceName(entry.rel_path, entry.basename)) |name| {
            try builder.appendSignal(&builder.docs, name, entry.rel_path, "documentation", documentationConfidence(entry.rel_path, entry.basename), "documentation surface exists; docs are claims and not authority");
        }

        if (configSurfaceName(entry.rel_path, entry.basename)) |name| {
            try builder.appendSignal(&builder.config_files, name, entry.rel_path, "project_config", "high", "recognized project configuration surface exists; structural evidence only");
        }
        if (isDependencyFile(entry.basename)) try builder.appendSignal(&builder.dependency_files, entry.basename, entry.rel_path, "dependency_file", "high", "recognized dependency or lock file exists");
        if (isPackageManagerFile(entry.basename)) try builder.appendSignal(&builder.package_managers, packageManagerName(entry.basename), entry.rel_path, "package_manager", "high", "package manager file exists");
        if (isEntryPoint(entry.rel_path)) try builder.appendSignal(&builder.entry_points, entry.basename, entry.rel_path, "entry_point", "medium", "conventional entry point path exists");
        if (isColocatedSourceTest(entry.rel_path)) {
            try builder.appendRootCandidate(&builder.test_roots, "src", "test_root", "medium", "test-like files are colocated under source root; candidate only, not proof tests are complete");
        }
    }
}

fn detectLanguagesAndCommands(builder: *Builder) !void {
    if (has(builder.entries, "build.zig") or has(builder.entries, "build.zig.zon") or hasExtensionInDir(builder.entries, "src", ".zig")) {
        const path = if (has(builder.entries, "build.zig")) "build.zig" else "src";
        try builder.appendSignal(&builder.languages, "zig", path, "language", "high", "Zig project signal detected");
        try builder.appendSignal(&builder.build_systems, "zig_build", "build.zig", "build_system", "high", "build.zig exists");
        try builder.appendCommand("zig_build", &.{ "zig", "build" }, "build.zig", "Zig build candidate; not executed by autopsy", "medium");
        try builder.appendSignal(&builder.possible_verifiers, "code.build.zig_build", "build.zig", "verifier_adapter_candidate", "high", "Zig build command candidate detected");
        try builder.appendSignal(&builder.next_checks, "confirm_zig_targets", "build.zig", "next_check", "medium", "inspect build.zig targets before executing any verifier");
        if (try zigBuildStepExists(builder.allocator, builder.root_abs, "test")) {
            try builder.appendCommand("zig_build_test", &.{ "zig", "build", "test" }, "build.zig", "Zig test step detected; not executed by autopsy", "medium");
            try builder.appendSignal(&builder.test_commands, "zig build test", "build.zig", "test_command_candidate", "high", "Zig build test step exists");
            try builder.appendSignal(&builder.possible_verifiers, "code.test.zig_build_test", "build.zig", "verifier_adapter_candidate", "high", "Zig test step detected");
        }
        if (try zigBuildStepExists(builder.allocator, builder.root_abs, "bench-serious-workflows")) {
            try builder.appendCommand("zig_build_bench_serious_workflows", &.{ "zig", "build", "bench-serious-workflows" }, "build.zig", "bench-serious-workflows target name detected; not executed by autopsy", "medium");
            try builder.appendSignal(&builder.possible_verifiers, "code.bench.zig_bench_serious_workflows", "build.zig", "verifier_adapter_candidate", "medium", "benchmark target name detected");
        }
        if (try zigBuildStepExists(builder.allocator, builder.root_abs, "test-parity")) {
            try builder.appendCommand("zig_build_test_parity", &.{ "zig", "build", "test-parity" }, "build.zig", "test-parity target name detected; not executed by autopsy", "medium");
            try builder.appendSignal(&builder.possible_verifiers, "code.parity.zig_test_parity", "build.zig", "verifier_adapter_candidate", "medium", "parity test target name detected");
        }
    }

    if (has(builder.entries, "Cargo.toml")) {
        try builder.appendSignal(&builder.languages, "rust", "Cargo.toml", "language", "high", "Cargo manifest exists");
        try builder.appendSignal(&builder.build_systems, "cargo", "Cargo.toml", "build_system", "high", "Cargo manifest exists");
        try builder.appendSignal(&builder.package_managers, "cargo", "Cargo.toml", "package_manager", "high", "Cargo manifest exists");
        try builder.appendCommand("cargo_build", &.{ "cargo", "build" }, "Cargo.toml", "Cargo build candidate; not executed by autopsy", "medium");
        try builder.appendCommand("cargo_test", &.{ "cargo", "test" }, "Cargo.toml", "Cargo test candidate; not executed by autopsy", "medium");
        try builder.appendSignal(&builder.test_commands, "cargo test", "Cargo.toml", "test_command_candidate", "high", "Cargo test candidate detected");
    }

    if (has(builder.entries, "package.json") or has(builder.entries, "tsconfig.json")) {
        const path = if (has(builder.entries, "package.json")) "package.json" else "tsconfig.json";
        try builder.appendSignal(&builder.languages, "javascript_typescript", path, "language", "high", "Node/JS/TS project signal detected");
        if (has(builder.entries, "tsconfig.json")) try builder.appendSignal(&builder.frameworks, "typescript", "tsconfig.json", "language_tooling", "high", "TypeScript config exists");
        if (has(builder.entries, "package.json")) {
            try builder.appendSignal(&builder.build_systems, "npm_scripts", "package.json", "build_system", "medium", "package.json scripts may define build/test commands");
            const scripts = try packageScripts(builder.allocator, builder.root_abs, "package.json");
            if (scripts.has_test) {
                try builder.appendCommand("npm_test", &.{ "npm", "test" }, "package.json", "npm test script detected; not executed by autopsy", "medium");
                try builder.appendSignal(&builder.test_commands, "npm test", "package.json", "test_command_candidate", "high", "package.json test script exists");
            }
            if (scripts.has_run_test) {
                try builder.appendCommand("npm_run_test", &.{ "npm", "run", "test" }, "package.json", "npm run test script detected; not executed by autopsy", "medium");
            }
            if (scripts.has_build) {
                try builder.appendCommand("npm_run_build", &.{ "npm", "run", "build" }, "package.json", "npm build script detected; not executed by autopsy", "medium");
            }
        }
    }

    if (has(builder.entries, "pyproject.toml") or has(builder.entries, "requirements.txt") or has(builder.entries, "setup.py")) {
        const path = if (has(builder.entries, "pyproject.toml")) "pyproject.toml" else if (has(builder.entries, "requirements.txt")) "requirements.txt" else "setup.py";
        try builder.appendSignal(&builder.languages, "python", path, "language", "high", "Python project signal detected");
        if (has(builder.entries, "pyproject.toml")) try builder.appendSignal(&builder.build_systems, "pyproject", "pyproject.toml", "build_system", "medium", "pyproject.toml exists");
        if (has(builder.entries, "requirements.txt") or has(builder.entries, "pyproject.toml")) try builder.appendSignal(&builder.package_managers, "python_packaging", path, "package_manager", "medium", "Python dependency/config file exists");
        if (has(builder.entries, "pytest.ini") or try fileContains(builder.allocator, builder.root_abs, "pyproject.toml", "pytest") or try fileContains(builder.allocator, builder.root_abs, "requirements.txt", "pytest")) {
            try builder.appendCommand("pytest", &.{"pytest"}, path, "pytest signal detected; not executed by autopsy", "medium");
            try builder.appendSignal(&builder.test_commands, "pytest", path, "test_command_candidate", "high", "pytest signal detected");
        }
    }

    if (has(builder.entries, "go.mod")) {
        try builder.appendSignal(&builder.languages, "go", "go.mod", "language", "high", "Go module exists");
        try builder.appendSignal(&builder.build_systems, "go", "go.mod", "build_system", "high", "Go module exists");
        try builder.appendCommand("go_test_all", &.{ "go", "test", "./..." }, "go.mod", "Go test candidate; not executed by autopsy", "medium");
        try builder.appendSignal(&builder.test_commands, "go test ./...", "go.mod", "test_command_candidate", "high", "Go module test candidate detected");
    }

    if (has(builder.entries, "CMakeLists.txt") or has(builder.entries, "Makefile") or has(builder.entries, "meson.build")) {
        const path = if (has(builder.entries, "CMakeLists.txt")) "CMakeLists.txt" else if (has(builder.entries, "Makefile")) "Makefile" else "meson.build";
        try builder.appendSignal(&builder.languages, "c_cpp", path, "language", "medium", "C/C++ build file detected");
        try builder.appendSignal(&builder.build_systems, "c_cpp_build", path, "build_system", "high", "C/C++ build system file exists");
        if (has(builder.entries, "CMakeLists.txt")) {
            try builder.appendCommand("cmake_build", &.{ "cmake", "--build", "build" }, "CMakeLists.txt", "CMake build candidate; build dir presence affects readiness; not executed by autopsy", if (hasDir(builder.entries, "build")) "medium" else "high");
        }
    }

    if (has(builder.entries, "pom.xml") or has(builder.entries, "build.gradle") or has(builder.entries, "settings.gradle")) {
        const path = if (has(builder.entries, "pom.xml")) "pom.xml" else "build.gradle";
        try builder.appendSignal(&builder.languages, "java_kotlin", path, "language", "medium", "Java/Kotlin build file detected");
        try builder.appendSignal(&builder.build_systems, "java_build", path, "build_system", "high", "Java/Kotlin build system file exists");
    }

    if (has(builder.entries, "Dockerfile") or has(builder.entries, "docker-compose.yml")) {
        const path = if (has(builder.entries, "Dockerfile")) "Dockerfile" else "docker-compose.yml";
        try builder.appendSignal(&builder.languages, "docker", path, "runtime_surface", "medium", "Docker configuration detected");
    }
}

fn detectRisks(builder: *Builder) !void {
    for (builder.entries) |entry| {
        if (entry.is_dir) continue;
        const path = entry.rel_path;
        const lower = try std.ascii.allocLowerString(builder.allocator, path);
        defer builder.allocator.free(lower);
        if (containsAny(lower, &.{ "auth", "security", "secret", "token", "password" })) {
            try builder.appendRisk("risk.auth_security", "auth_security", path, "medium", "security-sensitive name detected; candidate only, not evidence of a defect", "treat as routing signal only; require explicit evidence before claims");
        }
        if (containsAny(lower, &.{ "migration", "database", "schema.sql", "db/" })) {
            try builder.appendRisk("risk.database_migration", "database_migration", path, "medium", "database or migration path detected; candidate only, not evidence of a defect", "inspect ordering and reversibility before recommending changes");
        }
        if (startsWith(path, ".github/") or std.mem.eql(u8, path, ".gitlab-ci.yml") or containsAny(lower, &.{ "deploy", "release" })) {
            try builder.appendRisk("risk.ci_deployment", "ci_deployment", path, "medium", "CI or deployment surface detected; intended workflow evidence only", "do not infer deployment safety from presence alone");
        }
        if (isDependencyFile(entry.basename) or std.mem.eql(u8, entry.basename, "build.zig") or std.mem.eql(u8, entry.basename, "Makefile") or std.mem.eql(u8, entry.basename, "CMakeLists.txt")) {
            try builder.appendRisk("risk.build_dependency", "build_dependency", path, "medium", "build or dependency file detected; structural evidence only", "command candidates still require confirmation and execution evidence");
        }
        if (containsAny(lower, &.{ "concurrency", "sync", "runtime", "thread", "mutex" })) {
            try builder.appendRisk("risk.concurrency_runtime", "concurrency_runtime", path, "medium", "runtime/concurrency-related name detected; candidate only, not evidence of behavior", "avoid broad behavioral claims without verifier evidence");
        }
        if (endsWith(path, ".sh")) {
            try builder.appendRisk("risk.shell_script", "shell_script", path, "medium", "shell script detected; candidate execution semantics are unknown", "inspect argv semantics before any execution proposal");
        }
        if (std.mem.startsWith(u8, entry.basename, ".env") or containsAny(lower, &.{ "config", ".toml", ".yaml", ".yml", ".json" })) {
            try builder.appendRisk("risk.config_env", "config_env", path, "low", "configuration or environment-like file detected; values were not verified", "unknown values are not evidence of runtime behavior");
        }
        if (containsAny(lower, &.{ "verifier", "test_", "_test", "tests", "bench" })) {
            try builder.appendRisk("risk.verifier_test_harness", "verifier_test_harness", path, "low", "test/verifier/benchmark surface detected; candidate only", "keep proposed checks separate from executed verifier results");
        }
    }
    try detectStructuralRisks(builder);
}

fn detectGaps(builder: *Builder, options: AnalyzeOptions, entry_count: usize) !void {
    if (builder.source_roots.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "source_root_unknown", "", "unknown", "high", "no source root candidate was determined from bounded structural evidence");
        try builder.appendSignal(&builder.next_questions, "identify_source_root", "", "next_question", "medium", "Which directory should be treated as the primary source root?");
    } else if (hasConflictingRootCandidates(builder.source_roots.items)) {
        try builder.appendSignal(&builder.unknowns, "source_root_ambiguous", "", "unknown", "medium", "multiple plausible source roots were detected and no canonical root was selected");
        try builder.appendSignal(&builder.next_questions, "choose_canonical_source_root", "", "next_question", "medium", "Which detected source root is canonical for future explicit verification?");
    }
    if (builder.test_roots.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "test_root_unknown", "", "unknown", "medium", "no test root candidate was determined; absence of evidence is not evidence that tests do not exist");
        try builder.appendSignal(&builder.next_questions, "identify_test_root", "", "next_question", "medium", "Where should Ghost look for tests during a future explicit verification pass?");
    } else if (hasConflictingRootCandidates(builder.test_roots.items)) {
        try builder.appendSignal(&builder.unknowns, "test_root_ambiguous", "", "unknown", "medium", "multiple plausible test roots were detected and no canonical root was selected");
        try builder.appendSignal(&builder.next_questions, "choose_canonical_test_root", "", "next_question", "medium", "Which detected test root is canonical for future explicit verification?");
    }
    if (builder.source_roots.items.len > 0 and builder.test_roots.items.len == 0) {
        const paths = try pathsFromRootCandidates(builder.allocator, builder.source_roots.items);
        try builder.appendVerifierGap("gap.test_root_verifier_missing", "test_root_verifier", "source roots were detected but no test root was detected; this is missing evidence, not evidence tests are absent", paths, true);
    }
    if (builder.ci_configs.items.len > 0 and builder.test_commands.items.len == 0) {
        const paths = try pathsFromSignals(builder.allocator, builder.ci_configs.items);
        try builder.appendVerifierGap("gap.ci_test_command_missing", "test_command_verifier", "CI configuration was detected but no safe test command candidate was detected; workflow status remains unknown", paths, true);
    }
    if ((has(builder.entries, "Dockerfile") or has(builder.entries, "docker-compose.yml") or has(builder.entries, "compose.yml")) and !hasRuntimeVerifierCandidate(builder.safe_commands.items)) {
        const paths = try matchingEntryPaths(builder.allocator, builder.entries, dockerOrComposeEntry);
        try builder.appendVerifierGap("gap.runtime_verifier_missing", "runtime_container_verifier", "Docker or Compose configuration was detected but no runtime verifier candidate was detected", paths, true);
    }
    if (hasTerraformConfig(builder.entries) and !hasConfigValidationCandidate(builder.safe_commands.items)) {
        const paths = try matchingEntryPaths(builder.allocator, builder.entries, terraformEntry);
        try builder.appendVerifierGap("gap.config_validation_missing", "config_validation_verifier", "Terraform/config-heavy files were detected but no validation verifier candidate was detected", paths, true);
    }
    if (builder.languages.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "project_type_unknown", "", "unknown", "high", "no known language/toolchain signal was detected");
        try builder.appendSignal(&builder.ambiguous_project_type, "project_type_unknown", "", "ambiguous_project_type", "high", "known Pass 1 project signals were absent");
        try builder.appendSignal(&builder.next_questions, "identify_project_type", "", "next_question", "high", "Which toolchain should Ghost inspect for this workspace?");
    }
    if (builder.ci_configs.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "ci_config_unknown", "", "unknown", "medium", "no CI configuration was detected inside the inspected workspace; this does not claim CI is absent globally");
    }
    if (builder.docs.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "documentation_unknown", "", "unknown", "medium", "no documentation surface was detected inside the inspected workspace; this does not claim documentation is absent globally");
    }
    if (builder.config_files.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "project_config_unknown", "", "unknown", "medium", "no project configuration surface was detected inside the inspected workspace; absence of evidence is not negative evidence");
    } else if (hasAmbiguousConfigSurfaces(builder.config_files.items)) {
        try builder.appendSignal(&builder.unknowns, "project_config_ambiguous", "", "unknown", "medium", "multiple project configuration surfaces were detected and no canonical config was selected");
        try builder.appendSignal(&builder.next_questions, "choose_canonical_project_config", "", "next_question", "medium", "Which detected project configuration surface should anchor future explicit verification?");
    }
    if (builder.safe_commands.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "safe_command_candidates_unknown", "", "unknown", "medium", "no safe command candidates were inferred");
        try builder.appendSignal(&builder.next_questions, "test_build_commands", "", "next_question", "medium", "What build or test command should be considered for future explicit verification?");
    }
    try builder.appendSignal(&builder.unknown_verifiers, "verifier_registration_status", "", "unknown", "high", "Project Autopsy only proposes verifier candidates; it does not inspect registry state or register adapters");
    try builder.appendVerifierGap("gap.verifier_execution_not_run", "verifier_execution_result", "No verifier execution result exists because autopsy is read-only; this is missing evidence, not negative evidence", &.{}, true);
    if (entry_count >= options.max_entries) try builder.appendSignal(&builder.unknowns, "traversal_entry_limit_reached", "", "unknown", "medium", "directory traversal hit max_entries bound");
}

fn detectRecommendedGuidance(builder: *Builder) !void {
    if (findSignal(builder.languages.items, "zig")) |signal| {
        try builder.appendGuidanceCandidate(
            "guidance.zig_project_baseline",
            "pack_guidance_candidate",
            "zig_project_baseline",
            "Zig project structure was detected; recommend review of Zig baseline procedure guidance only",
            signal.evidence_paths,
            &.{"zig"},
            try riskIdsPresent(builder.allocator, builder.risk_surfaces.items, &.{ "risk.build_dependency", "risk.source_without_tests" }),
            try gapIdsPresent(builder.allocator, builder.gap_missing_verifiers.items, &.{ "gap.test_root_verifier_missing", "gap.verifier_execution_not_run" }),
            "review candidate guidance before explicitly selecting any verifier or pack",
        );
    }
    if (findSignal(builder.languages.items, "javascript_typescript")) |signal| {
        try builder.appendGuidanceCandidate(
            "guidance.node_project_baseline",
            "pack_guidance_candidate",
            "node_project_baseline",
            "Node/JavaScript/TypeScript project structure was detected; recommend review of Node baseline procedure guidance only",
            signal.evidence_paths,
            &.{"javascript_typescript"},
            try riskIdsPresent(builder.allocator, builder.risk_surfaces.items, &.{ "risk.build_dependency", "risk.source_without_tests" }),
            try gapIdsPresent(builder.allocator, builder.gap_missing_verifiers.items, &.{ "gap.test_root_verifier_missing", "gap.ci_test_command_missing", "gap.verifier_execution_not_run" }),
            "review package scripts and candidate guidance before explicit verification",
        );
    }
    if (findSignal(builder.languages.items, "python")) |signal| {
        try builder.appendGuidanceCandidate(
            "guidance.python_project_baseline",
            "pack_guidance_candidate",
            "python_project_baseline",
            "Python project structure was detected; recommend review of Python baseline procedure guidance only",
            signal.evidence_paths,
            &.{"python"},
            try riskIdsPresent(builder.allocator, builder.risk_surfaces.items, &.{ "risk.build_dependency", "risk.source_without_tests" }),
            try gapIdsPresent(builder.allocator, builder.gap_missing_verifiers.items, &.{ "gap.test_root_verifier_missing", "gap.verifier_execution_not_run" }),
            "review Python packaging and test guidance before explicit verification",
        );
    }
    if (findSignal(builder.languages.items, "rust")) |signal| {
        try builder.appendGuidanceCandidate(
            "guidance.rust_project_baseline",
            "pack_guidance_candidate",
            "rust_project_baseline",
            "Rust project structure was detected; recommend review of Rust baseline procedure guidance only",
            signal.evidence_paths,
            &.{"rust"},
            try riskIdsPresent(builder.allocator, builder.risk_surfaces.items, &.{ "risk.build_dependency", "risk.source_without_tests" }),
            try gapIdsPresent(builder.allocator, builder.gap_missing_verifiers.items, &.{ "gap.test_root_verifier_missing", "gap.verifier_execution_not_run" }),
            "review Cargo guidance before explicit verification",
        );
    }
    if (has(builder.entries, "Dockerfile") or has(builder.entries, "docker-compose.yml") or has(builder.entries, "compose.yml")) {
        const paths = try matchingEntryPaths(builder.allocator, builder.entries, dockerOrComposeEntry);
        try builder.appendGuidanceCandidate(
            "guidance.container_runtime_guidance",
            "pack_guidance_candidate",
            "container_runtime_guidance",
            "Docker or Compose runtime surface was detected; recommend review of container runtime guidance only",
            paths,
            try detectedLanguageNames(builder.allocator, builder.languages.items),
            try riskIdsPresent(builder.allocator, builder.risk_surfaces.items, &.{"risk.container_runtime_unverified"}),
            try gapIdsPresent(builder.allocator, builder.gap_missing_verifiers.items, &.{ "gap.runtime_verifier_missing", "gap.verifier_execution_not_run" }),
            "review runtime guidance and choose an explicit verifier before making container behavior claims",
        );
    }
    if (hasTerraformConfig(builder.entries)) {
        const paths = try matchingEntryPaths(builder.allocator, builder.entries, terraformEntry);
        try builder.appendGuidanceCandidate(
            "guidance.terraform_validation_guidance",
            "pack_guidance_candidate",
            "terraform_validation_guidance",
            "Terraform configuration was detected; recommend review of validation guidance only",
            paths,
            try detectedLanguageNames(builder.allocator, builder.languages.items),
            try riskIdsPresent(builder.allocator, builder.risk_surfaces.items, &.{"risk.config_validation_missing"}),
            try gapIdsPresent(builder.allocator, builder.gap_missing_verifiers.items, &.{ "gap.config_validation_missing", "gap.verifier_execution_not_run" }),
            "review Terraform validation guidance before explicitly selecting validation commands",
        );
    }
    if (builder.ci_configs.items.len > 0) {
        const paths = try pathsFromSignals(builder.allocator, builder.ci_configs.items);
        try builder.appendGuidanceCandidate(
            "guidance.ci_workflow_guidance",
            "pack_guidance_candidate",
            "ci_workflow_guidance",
            "CI configuration was detected; recommend review of CI workflow guidance only",
            paths,
            try detectedLanguageNames(builder.allocator, builder.languages.items),
            try riskIdsPresent(builder.allocator, builder.risk_surfaces.items, &.{ "risk.ci_deployment", "risk.ci_without_test_candidate" }),
            try gapIdsPresent(builder.allocator, builder.gap_missing_verifiers.items, &.{ "gap.ci_test_command_missing", "gap.verifier_execution_not_run" }),
            "review CI intent and candidate verifier gaps before treating workflow config as evidence",
        );
    }
    if (findRisk(builder.risk_surfaces.items, "risk.source_without_tests")) |risk| {
        try builder.appendGuidanceCandidate(
            "guidance.test_discovery_guidance",
            "pack_guidance_candidate",
            "test_discovery_guidance",
            "Source roots were detected without a test root candidate; recommend review of test discovery guidance only",
            risk.evidence_paths,
            try detectedLanguageNames(builder.allocator, builder.languages.items),
            &.{"risk.source_without_tests"},
            try gapIdsPresent(builder.allocator, builder.gap_missing_verifiers.items, &.{ "gap.test_root_verifier_missing", "gap.verifier_execution_not_run" }),
            "identify test roots and explicit verifier candidates before making coverage claims",
        );
    }
}

fn detectGuidanceGaps(builder: *Builder) !void {
    if (builder.recommended_guidance_candidates.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "pack_guidance_candidates_unknown", "", "unknown", "medium", "no known procedure guidance candidate matched bounded Project Autopsy signals; no pack availability was inferred");
        try builder.appendSignal(&builder.missing_pack_recommendations, "no_pack_recommendation", "", "gap", "medium", "Pass 1 does not auto-select or mount Knowledge Packs");
    }
}

fn detectStructuralRisks(builder: *Builder) !void {
    if (builder.source_roots.items.len > 0 and builder.test_roots.items.len == 0) {
        const paths = try pathsFromRootCandidates(builder.allocator, builder.source_roots.items);
        try builder.appendRiskWithPaths("risk.source_without_tests", "source_without_tests", "", paths, "medium", "source root candidates exist but no test root candidate was detected; missing evidence is not negative evidence", "identify or verify test roots before making coverage claims");
    }
    if (builder.config_files.items.len > 0 and builder.ci_configs.items.len == 0) {
        const paths = try pathsFromSignals(builder.allocator, builder.config_files.items);
        try builder.appendRiskWithPaths("risk.config_without_ci", "config_without_ci", "", paths, "medium", "build/package configuration exists but no CI config was detected in the inspected workspace", "do not infer CI absence globally; confirm intended verification workflow");
    }
    if (hasAmbiguousConfigSurfaces(builder.config_files.items)) {
        const paths = try pathsFromSignals(builder.allocator, builder.config_files.items);
        try builder.appendRiskWithPaths("risk.multiple_config_systems", "multiple_config_systems", "", paths, "medium", "multiple plausible project configuration systems were detected and no canonical system was selected", "choose the canonical config before deriving verifier expectations");
    }
    if (builder.docs.items.len > 0 and builder.config_files.items.len == 0) {
        const paths = try pathsFromSignals(builder.allocator, builder.docs.items);
        try builder.appendRiskWithPaths("risk.docs_without_config", "docs_without_config", "", paths, "low", "documentation exists but no project configuration surface was detected", "treat docs as claims until project configuration evidence is found");
    }
    if (builder.ci_configs.items.len > 0 and builder.test_commands.items.len == 0) {
        const paths = try pathsFromSignals(builder.allocator, builder.ci_configs.items);
        try builder.appendRiskWithPaths("risk.ci_without_test_candidate", "ci_without_test_candidate", "", paths, "medium", "CI configuration exists but no safe test command candidate was detected", "inspect CI intent or project scripts before claiming tests are runnable");
    }
    if (has(builder.entries, "Dockerfile") or has(builder.entries, "docker-compose.yml") or has(builder.entries, "compose.yml")) {
        const paths = try matchingEntryPaths(builder.allocator, builder.entries, dockerOrComposeEntry);
        try builder.appendRiskWithPaths("risk.container_runtime_unverified", "container_runtime_unverified", "", paths, "medium", "Docker or Compose configuration exists and runtime behavior remains unverified", "require an explicit runtime verifier before making container behavior claims");
    }
    if (hasTerraformConfig(builder.entries)) {
        const paths = try matchingEntryPaths(builder.allocator, builder.entries, terraformEntry);
        try builder.appendRiskWithPaths("risk.config_validation_missing", "config_validation_missing", "", paths, "medium", "Terraform/config-heavy files exist and no validation result was produced", "require explicit config validation evidence before support claims");
    }
}

fn collectEntries(allocator: std.mem.Allocator, root_abs: []const u8, options: AnalyzeOptions) ![]Entry {
    var list = std.ArrayList(Entry).init(allocator);
    var root = try std.fs.openDirAbsolute(root_abs, .{ .iterate = true });
    defer root.close();
    try collectDir(allocator, &list, root, "", 0, options);
    sortEntries(list.items);
    return list.toOwnedSlice();
}

fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| {
        allocator.free(entry.rel_path);
        allocator.free(entry.basename);
    }
    allocator.free(entries);
}

fn collectDir(allocator: std.mem.Allocator, list: *std.ArrayList(Entry), dir: std.fs.Dir, prefix: []const u8, depth: usize, options: AnalyzeOptions) !void {
    if (depth > options.max_depth or list.items.len >= options.max_entries) return;
    const LocalEntry = struct {
        name: []const u8,
        kind: std.fs.File.Kind,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    };
    var local = std.ArrayList(LocalEntry).init(allocator);
    defer {
        for (local.items) |item| allocator.free(item.name);
        local.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |raw| {
        if (std.mem.eql(u8, raw.name, ".git") or
            std.mem.eql(u8, raw.name, ".zig-cache") or
            std.mem.eql(u8, raw.name, ".ghost_zig_cache") or
            std.mem.eql(u8, raw.name, ".ghost_zig_global_cache") or
            std.mem.eql(u8, raw.name, ".ghost_zig_local_cache") or
            std.mem.eql(u8, raw.name, "corpus") or
            std.mem.eql(u8, raw.name, "zig-out") or
            std.mem.eql(u8, raw.name, "node_modules")) continue;
        try local.append(.{ .name = try allocator.dupe(u8, raw.name), .kind = raw.kind });
    }
    std.mem.sort(LocalEntry, local.items, {}, LocalEntry.lessThan);

    for (local.items) |raw| {
        if (list.items.len >= options.max_entries) return;
        const rel = if (prefix.len == 0) try allocator.dupe(u8, raw.name) else try std.fs.path.join(allocator, &.{ prefix, raw.name });
        std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        const is_dir = raw.kind == .directory;
        try list.append(.{ .rel_path = rel, .basename = try allocator.dupe(u8, raw.name), .is_dir = is_dir });
    }

    for (local.items) |raw| {
        if (list.items.len >= options.max_entries) return;
        const is_dir = raw.kind == .directory;
        if (is_dir and depth < options.max_depth) {
            var child = dir.openDir(raw.name, .{ .iterate = true }) catch continue;
            defer child.close();
            const rel = if (prefix.len == 0) raw.name else try std.fs.path.join(allocator, &.{ prefix, raw.name });
            defer if (prefix.len != 0) allocator.free(rel);
            try collectDir(allocator, list, child, rel, depth + 1, options);
        }
    }
}

const PackageScripts = struct { has_test: bool = false, has_run_test: bool = false, has_build: bool = false };

fn packageScripts(allocator: std.mem.Allocator, root_abs: []const u8, rel_path: []const u8) !PackageScripts {
    const text = readSmallFile(allocator, root_abs, rel_path) catch return .{};
    defer allocator.free(text);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return .{};
    defer parsed.deinit();
    const obj = parsed.value.object.get("scripts") orelse return .{};
    if (obj != .object) return .{};
    return .{
        .has_test = obj.object.contains("test"),
        .has_run_test = obj.object.contains("test"),
        .has_build = obj.object.contains("build"),
    };
}

fn fileContains(allocator: std.mem.Allocator, root_abs: []const u8, rel_path: []const u8, needle: []const u8) !bool {
    const text = readSmallFile(allocator, root_abs, rel_path) catch return false;
    defer allocator.free(text);
    return std.mem.indexOf(u8, text, needle) != null;
}

fn zigBuildStepExists(allocator: std.mem.Allocator, root_abs: []const u8, step_name: []const u8) !bool {
    const text = readSmallFile(allocator, root_abs, "build.zig") catch return false;
    defer allocator.free(text);
    return zigBuildStepExistsInText(text, step_name);
}

fn zigBuildStepExistsInText(text: []const u8, step_name: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, "step")) |idx| {
        if (idx == 0 or text[idx - 1] != '.' or lineHasCommentBefore(text, idx)) {
            cursor = idx + "step".len;
            continue;
        }
        var pos = idx + "step".len;
        while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
        if (pos >= text.len or text[pos] != '(') {
            cursor = pos;
            continue;
        }
        pos += 1;
        while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
        if (pos >= text.len or text[pos] != '"') {
            cursor = pos;
            continue;
        }
        pos += 1;
        const name_start = pos;
        while (pos < text.len and text[pos] != '"') pos += 1;
        if (pos < text.len and std.mem.eql(u8, text[name_start..pos], step_name)) return true;
        cursor = pos;
    }
    return false;
}

fn lineHasCommentBefore(text: []const u8, idx: usize) bool {
    var line_start = idx;
    while (line_start > 0 and text[line_start - 1] != '\n') line_start -= 1;
    return std.mem.indexOf(u8, text[line_start..idx], "//") != null;
}

fn readSmallFile(allocator: std.mem.Allocator, root_abs: []const u8, rel_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel_path) or std.mem.indexOf(u8, rel_path, "..") != null) return error.PathOutsideWorkspace;
    var root = try std.fs.openDirAbsolute(root_abs, .{});
    defer root.close();
    return root.readFileAlloc(allocator, rel_path, MAX_FILE_READ_BYTES);
}

fn has(entries: []const Entry, rel_path: []const u8) bool {
    for (entries) |entry| if (!entry.is_dir and std.mem.eql(u8, entry.rel_path, rel_path)) return true;
    return false;
}

fn hasDir(entries: []const Entry, rel_path: []const u8) bool {
    for (entries) |entry| if (entry.is_dir and std.mem.eql(u8, entry.rel_path, rel_path)) return true;
    return false;
}

fn isConventionalSourceRoot(path: []const u8) bool {
    return std.mem.eql(u8, path, "src") or
        std.mem.eql(u8, path, "lib") or
        std.mem.eql(u8, path, "app") or
        (startsWith(path, "packages/") and endsWith(path, "/src"));
}

fn isConventionalTestRoot(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, path, "test") or
        std.mem.eql(u8, path, "tests") or
        std.mem.eql(u8, path, "spec") or
        std.mem.eql(u8, path, "__tests__") or
        (startsWith(path, "packages/") and (std.mem.eql(u8, base, "test") or std.mem.eql(u8, base, "tests") or std.mem.eql(u8, base, "spec") or std.mem.eql(u8, base, "__tests__"))) or
        (startsWith(path, "src/") and (std.mem.eql(u8, base, "test") or std.mem.eql(u8, base, "tests") or std.mem.eql(u8, base, "spec") or std.mem.eql(u8, base, "__tests__")));
}

fn sourceRootConfidence(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "src")) return "high";
    return "medium";
}

fn sourceRootReason(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "src")) return "canonical src directory exists; source root candidate only, not correctness evidence";
    if (startsWith(path, "packages/")) return "package-local src directory exists within bounded traversal; monorepo source root candidate only";
    return "conventional source-like directory exists; candidate only and not proof of primary root";
}

fn testRootConfidence(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "test") or std.mem.eql(u8, path, "tests")) return "high";
    return "medium";
}

fn testRootReason(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "test") or std.mem.eql(u8, path, "tests")) return "conventional test directory exists; test root candidate only, not verifier execution evidence";
    if (startsWith(path, "packages/")) return "package-local test directory exists within bounded traversal; test root candidate only";
    if (startsWith(path, "src/")) return "test-like directory is colocated under source root; test root candidate only";
    return "conventional test-like directory exists; candidate only and not proof of test coverage";
}

fn isColocatedSourceTest(path: []const u8) bool {
    return startsWith(path, "src/") and !std.mem.eql(u8, path, "src") and
        (startsWith(std.fs.path.basename(path), "test_") or
            endsWith(path, "_test.zig") or
            endsWith(path, ".test.ts") or
            endsWith(path, ".test.js") or
            endsWith(path, ".spec.ts") or
            endsWith(path, ".spec.js"));
}

fn rootEvidencePaths(allocator: std.mem.Allocator, entries: []const Entry, root_path: []const u8) ![]const []const u8 {
    var paths = std.ArrayList([]const u8).init(allocator);
    try paths.append(try allocator.dupe(u8, root_path));
    for (entries) |entry| {
        if (entry.is_dir) continue;
        if (!pathWithinRoot(entry.rel_path, root_path)) continue;
        if (paths.items.len >= 5) break;
        try paths.append(try allocator.dupe(u8, entry.rel_path));
    }
    return paths.toOwnedSlice();
}

fn rootLanguageHint(allocator: std.mem.Allocator, entries: []const Entry, root_path: []const u8) !?[]const u8 {
    var hint: ?[]const u8 = null;
    for (entries) |entry| {
        if (entry.is_dir or !pathWithinRoot(entry.rel_path, root_path)) continue;
        const current = languageHintForPath(entry.rel_path) orelse continue;
        if (hint) |existing| {
            if (!std.mem.eql(u8, existing, current)) return try allocator.dupe(u8, "mixed");
        } else {
            hint = current;
        }
    }
    if (hint) |value| return try allocator.dupe(u8, value);
    return null;
}

fn languageHintForPath(path: []const u8) ?[]const u8 {
    if (endsWith(path, ".zig")) return "zig";
    if (endsWith(path, ".rs")) return "rust";
    if (endsWith(path, ".ts") or endsWith(path, ".tsx")) return "typescript";
    if (endsWith(path, ".js") or endsWith(path, ".jsx")) return "javascript";
    if (endsWith(path, ".py")) return "python";
    if (endsWith(path, ".go")) return "go";
    if (endsWith(path, ".c") or endsWith(path, ".cc") or endsWith(path, ".cpp") or endsWith(path, ".h") or endsWith(path, ".hpp")) return "c_cpp";
    if (endsWith(path, ".java") or endsWith(path, ".kt")) return "java_kotlin";
    return null;
}

fn pathWithinRoot(path: []const u8, root_path: []const u8) bool {
    return std.mem.eql(u8, path, root_path) or
        (startsWith(path, root_path) and path.len > root_path.len and path[root_path.len] == '/');
}

fn hasExtensionInDir(entries: []const Entry, dir_prefix: []const u8, extension: []const u8) bool {
    for (entries) |entry| {
        if (!entry.is_dir and startsWith(entry.rel_path, dir_prefix) and endsWith(entry.rel_path, extension)) return true;
    }
    return false;
}

fn signalEvidencePaths(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    if (path.len == 0) return &.{};
    const paths = try allocator.alloc([]const u8, 1);
    paths[0] = try allocator.dupe(u8, path);
    return paths;
}

fn dupeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    if (items.len == 0) return &.{};
    const copy = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, i| copy[i] = try allocator.dupe(u8, item);
    return copy;
}

fn pathsFromSignals(allocator: std.mem.Allocator, items: []const Signal) ![]const []const u8 {
    var paths = std.ArrayList([]const u8).init(allocator);
    for (items) |item| {
        if (item.path.len == 0) continue;
        if (containsString(paths.items, item.path)) continue;
        try paths.append(try allocator.dupe(u8, item.path));
        if (paths.items.len >= 8) break;
    }
    return paths.toOwnedSlice();
}

fn pathsFromRootCandidates(allocator: std.mem.Allocator, items: []const RootCandidate) ![]const []const u8 {
    var paths = std.ArrayList([]const u8).init(allocator);
    for (items) |item| {
        if (containsString(paths.items, item.path)) continue;
        try paths.append(try allocator.dupe(u8, item.path));
        if (paths.items.len >= 8) break;
    }
    return paths.toOwnedSlice();
}

fn matchingEntryPaths(allocator: std.mem.Allocator, entries: []const Entry, comptime predicate: fn (Entry) bool) ![]const []const u8 {
    var paths = std.ArrayList([]const u8).init(allocator);
    for (entries) |entry| {
        if (entry.is_dir or !predicate(entry)) continue;
        if (containsString(paths.items, entry.rel_path)) continue;
        try paths.append(try allocator.dupe(u8, entry.rel_path));
        if (paths.items.len >= 8) break;
    }
    return paths.toOwnedSlice();
}

fn dockerOrComposeEntry(entry: Entry) bool {
    return std.mem.eql(u8, entry.basename, "Dockerfile") or
        std.mem.eql(u8, entry.basename, "docker-compose.yml") or
        std.mem.eql(u8, entry.basename, "compose.yml");
}

fn terraformEntry(entry: Entry) bool {
    return endsWith(entry.rel_path, ".tf");
}

fn hasTerraformConfig(entries: []const Entry) bool {
    for (entries) |entry| {
        if (!entry.is_dir and terraformEntry(entry)) return true;
    }
    return false;
}

fn hasRuntimeVerifierCandidate(items: []const SafeCommandCandidate) bool {
    for (items) |item| {
        if (containsAny(item.id, &.{ "runtime", "docker", "compose", "container" })) return true;
    }
    return false;
}

fn hasConfigValidationCandidate(items: []const SafeCommandCandidate) bool {
    for (items) |item| {
        if (containsAny(item.id, &.{ "validate", "lint", "fmt", "terraform" })) return true;
    }
    return false;
}

fn ciSurfaceName(path: []const u8) ?[]const u8 {
    if (startsWith(path, ".github/workflows/") and (endsWith(path, ".yml") or endsWith(path, ".yaml"))) return "github_actions";
    if (std.mem.eql(u8, path, ".gitlab-ci.yml")) return "gitlab_ci";
    if (std.mem.eql(u8, path, ".circleci/config.yml") or std.mem.eql(u8, path, "circleci/config.yml")) return "circleci";
    if (std.mem.eql(u8, path, ".buildkite/pipeline.yml") or std.mem.eql(u8, path, "buildkite/pipeline.yml")) return "buildkite";
    if (std.mem.eql(u8, path, "Jenkinsfile")) return "jenkins";
    return null;
}

fn documentationSurfaceName(path: []const u8, basename: []const u8) ?[]const u8 {
    if (startsWithReadme(basename)) return "README";
    if (std.ascii.eqlIgnoreCase(basename, "CONTRIBUTING.md")) return "CONTRIBUTING";
    if (std.ascii.eqlIgnoreCase(basename, "CHANGELOG.md")) return "CHANGELOG";
    if (std.ascii.eqlIgnoreCase(basename, "SECURITY.md")) return "SECURITY";
    if (std.mem.eql(u8, basename, "LICENSE")) return "LICENSE";
    if (isAdrOrArchitectureDoc(path, basename)) return "architecture_doc";
    return null;
}

fn documentationConfidence(path: []const u8, basename: []const u8) []const u8 {
    _ = path;
    if (startsWithReadme(basename) or std.ascii.eqlIgnoreCase(basename, "SECURITY.md")) return "high";
    return "medium";
}

fn startsWithReadme(basename: []const u8) bool {
    return std.ascii.eqlIgnoreCase(basename, "README") or
        (basename.len > "README.".len and std.ascii.eqlIgnoreCase(basename[0.."README".len], "README") and basename["README".len] == '.');
}

fn isAdrOrArchitectureDoc(path: []const u8, basename: []const u8) bool {
    const lower_base = std.ascii.eqlIgnoreCase(basename, "ARCHITECTURE.md") or
        std.ascii.eqlIgnoreCase(basename, "ADR.md");
    return lower_base or
        (startsWith(path, "docs/adr/") and endsWith(path, ".md")) or
        (startsWith(path, "docs/architecture/") and endsWith(path, ".md"));
}

fn configSurfaceName(path: []const u8, basename: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, basename, "package.json")) return "package.json";
    if (std.mem.eql(u8, basename, "pyproject.toml")) return "pyproject.toml";
    if (std.mem.eql(u8, basename, "Cargo.toml")) return "Cargo.toml";
    if (std.mem.eql(u8, basename, "go.mod")) return "go.mod";
    if (std.mem.eql(u8, basename, "build.zig")) return "build.zig";
    if (std.mem.eql(u8, basename, "Makefile")) return "Makefile";
    if (std.mem.eql(u8, basename, "Dockerfile")) return "Dockerfile";
    if (std.mem.eql(u8, basename, "docker-compose.yml")) return "docker-compose.yml";
    if (std.mem.eql(u8, basename, "compose.yml")) return "compose.yml";
    if (std.mem.eql(u8, basename, "tsconfig.json")) return "tsconfig.json";
    if (std.mem.eql(u8, basename, "pytest.ini")) return "pytest.ini";
    if (std.mem.eql(u8, basename, ".editorconfig")) return ".editorconfig";
    if (std.mem.eql(u8, basename, ".env.example")) return ".env.example";
    if (isEslintOrPrettierConfig(basename)) return "js_lint_format_config";
    if (endsWith(path, ".tf")) return "terraform_config";
    return null;
}

fn isEslintOrPrettierConfig(basename: []const u8) bool {
    return std.mem.eql(u8, basename, ".eslintrc") or
        startsWith(basename, ".eslintrc.") or
        std.mem.eql(u8, basename, "eslint.config.js") or
        std.mem.eql(u8, basename, "eslint.config.mjs") or
        std.mem.eql(u8, basename, "eslint.config.cjs") or
        std.mem.eql(u8, basename, ".prettierrc") or
        startsWith(basename, ".prettierrc.") or
        std.mem.eql(u8, basename, "prettier.config.js") or
        std.mem.eql(u8, basename, "prettier.config.mjs") or
        std.mem.eql(u8, basename, "prettier.config.cjs");
}

fn hasAmbiguousConfigSurfaces(items: []const Signal) bool {
    var canonical_count: usize = 0;
    for (items) |item| {
        if (isCanonicalProjectConfigName(item.name)) canonical_count += 1;
    }
    return canonical_count > 1;
}

fn isCanonicalProjectConfigName(name: []const u8) bool {
    return std.mem.eql(u8, name, "package.json") or
        std.mem.eql(u8, name, "pyproject.toml") or
        std.mem.eql(u8, name, "Cargo.toml") or
        std.mem.eql(u8, name, "go.mod") or
        std.mem.eql(u8, name, "build.zig") or
        std.mem.eql(u8, name, "Makefile");
}

fn isConfigFile(name: []const u8) bool {
    return configSurfaceName(name, name) != null;
}

fn isDependencyFile(name: []const u8) bool {
    return std.mem.eql(u8, name, "build.zig.zon") or std.mem.eql(u8, name, "Cargo.lock") or
        std.mem.eql(u8, name, "package-lock.json") or std.mem.eql(u8, name, "pnpm-lock.yaml") or
        std.mem.eql(u8, name, "yarn.lock") or std.mem.eql(u8, name, "requirements.txt") or
        std.mem.eql(u8, name, "go.sum") or std.mem.eql(u8, name, "poetry.lock") or
        std.mem.eql(u8, name, "uv.lock") or std.mem.eql(u8, name, "pom.xml") or
        std.mem.eql(u8, name, "build.gradle");
}

fn isPackageManagerFile(name: []const u8) bool {
    return std.mem.eql(u8, name, "package.json") or std.mem.eql(u8, name, "package-lock.json") or
        std.mem.eql(u8, name, "pnpm-lock.yaml") or std.mem.eql(u8, name, "yarn.lock") or
        std.mem.eql(u8, name, "Cargo.toml") or std.mem.eql(u8, name, "requirements.txt") or
        std.mem.eql(u8, name, "pyproject.toml") or std.mem.eql(u8, name, "go.mod");
}

fn packageManagerName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "Cargo.toml")) return "cargo";
    if (std.mem.eql(u8, name, "go.mod")) return "go";
    if (std.mem.eql(u8, name, "pyproject.toml") or std.mem.eql(u8, name, "requirements.txt")) return "python_packaging";
    if (std.mem.eql(u8, name, "pnpm-lock.yaml")) return "pnpm";
    if (std.mem.eql(u8, name, "yarn.lock")) return "yarn";
    return "npm";
}

fn isEntryPoint(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/main.zig") or std.mem.eql(u8, path, "main.go") or
        std.mem.eql(u8, path, "src/main.rs") or std.mem.eql(u8, path, "src/index.ts") or
        std.mem.eql(u8, path, "src/index.js") or std.mem.eql(u8, path, "package.json");
}

fn containsSignal(items: []const Signal, name: []const u8, path: []const u8, kind: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.name, name) and std.mem.eql(u8, item.path, path) and std.mem.eql(u8, item.kind, kind)) return true;
    return false;
}

fn containsRisk(items: []const RiskSurface, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn containsVerifierGap(items: []const VerifierGapCandidate, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn containsGuidanceCandidate(items: []const RecommendedGuidanceCandidate, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn containsString(items: []const []const u8, value: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn containsRootCandidate(items: []const RootCandidate, path: []const u8, kind: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.path, path) and std.mem.eql(u8, item.kind, kind)) return true;
    return false;
}

fn hasConflictingRootCandidates(items: []const RootCandidate) bool {
    return items.len > 1;
}

fn hasBuildCommand(items: []const SafeCommandCandidate) bool {
    for (items) |item| {
        if (std.mem.indexOf(u8, item.id, "build") != null) return true;
    }
    return false;
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, text, needle) != null) return true;
    return false;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
}

fn endsWith(text: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, text, suffix);
}

fn signalLessThan(_: void, a: Signal, b: Signal) bool {
    const p = std.mem.order(u8, a.path, b.path);
    if (p != .eq) return p == .lt;
    const k = std.mem.order(u8, a.kind, b.kind);
    if (k != .eq) return k == .lt;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn sortSignals(items: []Signal) void {
    std.mem.sort(Signal, items, {}, signalLessThan);
}

fn rootCandidateLessThan(_: void, a: RootCandidate, b: RootCandidate) bool {
    const p = std.mem.order(u8, a.path, b.path);
    if (p != .eq) return p == .lt;
    return std.mem.order(u8, a.kind, b.kind) == .lt;
}

fn sortRootCandidates(items: []RootCandidate) void {
    std.mem.sort(RootCandidate, items, {}, rootCandidateLessThan);
}

fn riskLessThan(_: void, a: RiskSurface, b: RiskSurface) bool {
    const p = std.mem.order(u8, a.id, b.id);
    if (p != .eq) return p == .lt;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn sortRisks(items: []RiskSurface) void {
    std.mem.sort(RiskSurface, items, {}, riskLessThan);
}

fn verifierGapLessThan(_: void, a: VerifierGapCandidate, b: VerifierGapCandidate) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn sortVerifierGaps(items: []VerifierGapCandidate) void {
    std.mem.sort(VerifierGapCandidate, items, {}, verifierGapLessThan);
}

fn commandLessThan(_: void, a: SafeCommandCandidate, b: SafeCommandCandidate) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn sortCommands(items: []SafeCommandCandidate) void {
    std.mem.sort(SafeCommandCandidate, items, {}, commandLessThan);
}

fn verifierPlanLessThan(_: void, a: VerifierPlanCandidate, b: VerifierPlanCandidate) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn sortVerifierPlans(items: []VerifierPlanCandidate) void {
    std.mem.sort(VerifierPlanCandidate, items, {}, verifierPlanLessThan);
}

fn guidanceCandidateLessThan(_: void, a: RecommendedGuidanceCandidate, b: RecommendedGuidanceCandidate) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn sortGuidanceCandidates(items: []RecommendedGuidanceCandidate) void {
    std.mem.sort(RecommendedGuidanceCandidate, items, {}, guidanceCandidateLessThan);
}

fn riskIdsPresent(allocator: std.mem.Allocator, items: []const RiskSurface, ids: []const []const u8) ![]const []const u8 {
    var present = std.ArrayList([]const u8).init(allocator);
    for (ids) |id| {
        if (findRisk(items, id) != null) try present.append(id);
    }
    return present.toOwnedSlice();
}

fn gapIdsPresent(allocator: std.mem.Allocator, items: []const VerifierGapCandidate, ids: []const []const u8) ![]const []const u8 {
    var present = std.ArrayList([]const u8).init(allocator);
    for (ids) |id| {
        if (findVerifierGap(items, id) != null) try present.append(id);
    }
    return present.toOwnedSlice();
}

fn detectedLanguageNames(allocator: std.mem.Allocator, items: []const Signal) ![]const []const u8 {
    if (items.len == 0) return &.{};
    var names = std.ArrayList([]const u8).init(allocator);
    for (items) |item| {
        if (containsString(names.items, item.name)) continue;
        try names.append(item.name);
    }
    return names.toOwnedSlice();
}

fn buildOperatorSummary(builder: *Builder) !OperatorSummary {
    const language_names = try cappedSignalNames(builder.allocator, builder.languages.items, MAX_OPERATOR_SUMMARY_ITEMS);
    const build_system_names = try cappedSignalNames(builder.allocator, builder.build_systems.items, MAX_OPERATOR_SUMMARY_ITEMS);
    const shape = try std.fmt.allocPrint(
        builder.allocator,
        "shape candidate: languages={d}, build_systems={d}, source_roots={d}, test_roots={d}, ci_detected={}, docs_detected={}, config_surfaces={d}; draft summary only",
        .{
            builder.languages.items.len,
            builder.build_systems.items.len,
            builder.source_roots.items.len,
            builder.test_roots.items.len,
            builder.ci_configs.items.len > 0,
            builder.docs.items.len > 0,
            builder.config_files.items.len,
        },
    );

    return .{
        .project_shape_summary = shape,
        .primary_languages = language_names,
        .primary_build_systems = build_system_names,
        .source_root_count = builder.source_roots.items.len,
        .test_root_count = builder.test_roots.items.len,
        .ci_detected = builder.ci_configs.items.len > 0,
        .docs_detected = builder.docs.items.len > 0,
        .config_surface_count = builder.config_files.items.len,
        .safe_command_candidate_count = builder.safe_commands.items.len,
        .risk_surface_count = builder.risk_surfaces.items.len,
        .verifier_gap_count = builder.gap_missing_verifiers.items.len,
        .guidance_candidate_count = builder.recommended_guidance_candidates.items.len,
        .top_unknowns = try topUnknownItems(builder.allocator, builder.unknowns.items),
        .top_risks = try topRiskItems(builder.allocator, builder.risk_surfaces.items),
        .top_verifier_gaps = try topVerifierGapItems(builder.allocator, builder.gap_missing_verifiers.items),
        .suggested_next_actions = try summaryNextActions(builder),
    };
}

fn cappedSignalNames(allocator: std.mem.Allocator, items: []const Signal, cap: usize) ![]const []const u8 {
    if (items.len == 0 or cap == 0) return &.{};
    var names = std.ArrayList([]const u8).init(allocator);
    for (items) |item| {
        if (containsString(names.items, item.name)) continue;
        try names.append(try allocator.dupe(u8, item.name));
        if (names.items.len >= cap) break;
    }
    return names.toOwnedSlice();
}

fn topUnknownItems(allocator: std.mem.Allocator, items: []const Signal) ![]OperatorSummaryItem {
    var summary = std.ArrayList(OperatorSummaryItem).init(allocator);
    for (items) |item| {
        try summary.append(.{
            .id = try allocator.dupe(u8, item.name),
            .kind = try allocator.dupe(u8, item.kind),
            .reason = try allocator.dupe(u8, item.reason),
            .evidence_paths = try dupeStringSlice(allocator, item.evidence_paths),
        });
        if (summary.items.len >= MAX_OPERATOR_SUMMARY_ITEMS) break;
    }
    return summary.toOwnedSlice();
}

fn topRiskItems(allocator: std.mem.Allocator, items: []const RiskSurface) ![]OperatorSummaryItem {
    var summary = std.ArrayList(OperatorSummaryItem).init(allocator);
    for (items) |item| {
        try summary.append(.{
            .id = try allocator.dupe(u8, item.id),
            .kind = try allocator.dupe(u8, item.kind),
            .reason = try allocator.dupe(u8, item.reason),
            .evidence_paths = try dupeStringSlice(allocator, item.evidence_paths),
        });
        if (summary.items.len >= MAX_OPERATOR_SUMMARY_ITEMS) break;
    }
    return summary.toOwnedSlice();
}

fn topVerifierGapItems(allocator: std.mem.Allocator, items: []const VerifierGapCandidate) ![]OperatorSummaryItem {
    var summary = std.ArrayList(OperatorSummaryItem).init(allocator);
    for (items) |item| {
        try summary.append(.{
            .id = try allocator.dupe(u8, item.id),
            .kind = try allocator.dupe(u8, item.kind),
            .reason = try allocator.dupe(u8, item.reason),
            .evidence_paths = try dupeStringSlice(allocator, item.evidence_paths),
        });
        if (summary.items.len >= MAX_OPERATOR_SUMMARY_ITEMS) break;
    }
    return summary.toOwnedSlice();
}

fn summaryNextActions(builder: *Builder) ![]OperatorSummaryActionCandidate {
    var actions = std.ArrayList(OperatorSummaryActionCandidate).init(builder.allocator);
    for (builder.safe_commands.items) |item| {
        try actions.append(try summaryAction(
            builder.allocator,
            "review_safe_command_candidate",
            "safe_command_candidate",
            item.id,
            "review safe command candidate metadata; command remains unexecuted unless separately approved outside Autopsy",
        ));
        if (actions.items.len >= MAX_OPERATOR_SUMMARY_ITEMS) return actions.toOwnedSlice();
    }
    for (builder.gap_missing_verifiers.items) |item| {
        try actions.append(try summaryAction(
            builder.allocator,
            "resolve_verifier_gap_candidate",
            "verifier_gap_candidate",
            item.id,
            "inspect missing-verifier gap and choose explicit evidence needed before support claims",
        ));
        if (actions.items.len >= MAX_OPERATOR_SUMMARY_ITEMS) return actions.toOwnedSlice();
    }
    for (builder.recommended_guidance_candidates.items) |item| {
        try actions.append(try summaryAction(
            builder.allocator,
            "review_guidance_candidate",
            "guidance_candidate",
            item.id,
            "review guidance candidate; guidance is not applied or mounted by Autopsy",
        ));
        if (actions.items.len >= MAX_OPERATOR_SUMMARY_ITEMS) return actions.toOwnedSlice();
    }
    for (builder.next_questions.items) |item| {
        try actions.append(try summaryAction(
            builder.allocator,
            "answer_next_question_candidate",
            "next_question_candidate",
            item.name,
            item.reason,
        ));
        if (actions.items.len >= MAX_OPERATOR_SUMMARY_ITEMS) return actions.toOwnedSlice();
    }
    return actions.toOwnedSlice();
}

fn summaryAction(allocator: std.mem.Allocator, prefix: []const u8, kind: []const u8, reference_id: []const u8, reason: []const u8) !OperatorSummaryActionCandidate {
    const refs = try allocator.alloc([]const u8, 1);
    refs[0] = try allocator.dupe(u8, reference_id);
    return .{
        .id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, reference_id }),
        .kind = try allocator.dupe(u8, kind),
        .reason = try allocator.dupe(u8, reason),
        .references = refs,
    };
}

fn verifierPlanPurpose(id: []const u8) []const u8 {
    if (std.mem.indexOf(u8, id, "bench") != null) return "benchmark verifier plan candidate";
    if (std.mem.indexOf(u8, id, "test") != null or std.mem.eql(u8, id, "pytest")) return "test verifier plan candidate";
    if (std.mem.indexOf(u8, id, "build") != null) return "build verifier plan candidate";
    return "bounded verifier plan candidate";
}

fn commandMutationRiskDisclosure(id: []const u8) []const u8 {
    if (std.mem.indexOf(u8, id, "bench") != null) return "candidate may write benchmark outputs, caches, or reports if a user later executes it";
    if (std.mem.indexOf(u8, id, "test") != null or std.mem.eql(u8, id, "pytest")) return "candidate may write test caches, snapshots, coverage, or temporary outputs if a user later executes it";
    if (std.mem.indexOf(u8, id, "build") != null) return "candidate may write build artifacts or caches if a user later executes it";
    return "candidate execution effects are unknown because Project Autopsy does not run commands";
}

fn verifierPlanConfidence(id: []const u8, detected_from: []const u8) []const u8 {
    if (detected_from.len == 0) return "unknown";
    if (std.mem.indexOf(u8, id, "bench") != null or std.mem.indexOf(u8, id, "parity") != null) return "medium";
    return "high_for_candidate_existence_only";
}

fn verifierPlanUnknowns(id: []const u8) []const []const u8 {
    if (std.mem.indexOf(u8, id, "bench") != null) {
        return &.{
            "command was not executed by Project Autopsy",
            "benchmark target runtime cost and generated-report impact are unknown",
            "verifier adapter registration and approval lifecycle were not inspected",
        };
    }
    if (std.mem.startsWith(u8, id, "cmake_")) {
        return &.{
            "command was not executed by Project Autopsy",
            "build directory readiness is unknown",
            "verifier adapter registration and approval lifecycle were not inspected",
        };
    }
    return &.{
        "command was not executed by Project Autopsy",
        "command success, duration, and output are unknown",
        "verifier adapter registration and approval lifecycle were not inspected",
    };
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
}

fn sortEntries(items: []Entry) void {
    std.mem.sort(Entry, items, {}, entryLessThan);
}

fn makeFile(dir: std.fs.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    try dir.writeFile(.{ .sub_path = path, .data = content });
}

fn containsNamedSignal(items: []const Signal, name: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.name, name)) return true;
    return false;
}

fn findSignal(items: []const Signal, name: []const u8) ?Signal {
    for (items) |item| if (std.mem.eql(u8, item.name, name)) return item;
    return null;
}

fn findRisk(items: []const RiskSurface, id: []const u8) ?RiskSurface {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

fn findVerifierGap(items: []const VerifierGapCandidate, id: []const u8) ?VerifierGapCandidate {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

fn containsCommand(items: []const SafeCommandCandidate, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn findRootCandidate(items: []const RootCandidate, path: []const u8) ?RootCandidate {
    for (items) |item| if (std.mem.eql(u8, item.path, path)) return item;
    return null;
}

fn findVerifierPlan(items: []const VerifierPlanCandidate, id: []const u8) ?VerifierPlanCandidate {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

fn findGuidanceCandidate(items: []const RecommendedGuidanceCandidate, id: []const u8) ?RecommendedGuidanceCandidate {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

fn findSummaryAction(items: []const OperatorSummaryActionCandidate, reference_id: []const u8) ?OperatorSummaryActionCandidate {
    for (items) |item| {
        if (containsString(item.references, reference_id)) return item;
    }
    return null;
}

fn findSummaryItem(items: []const OperatorSummaryItem, id: []const u8) ?OperatorSummaryItem {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

test "project autopsy detects Zig project from build.zig" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test-parity\", \"\"); }");
    try makeFile(tmp.dir, "src/main.zig", "pub fn main() void {}");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsNamedSignal(result.project_profile.detected_languages, "zig"));
    try std.testing.expect(containsNamedSignal(result.project_profile.build_systems, "zig_build"));
}

test "project autopsy recommends Zig baseline guidance candidate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"\"); }");
    try makeFile(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const candidate = findGuidanceCandidate(result.project_profile.recommended_guidance_candidates, "guidance.zig_project_baseline") orelse return error.MissingGuidanceCandidate;
    try std.testing.expectEqualStrings("pack_guidance_candidate", candidate.kind);
    try std.testing.expect(candidate.pack_id == null);
    try std.testing.expectEqualStrings("zig_project_baseline", candidate.guidance_id);
    try std.testing.expect(candidate.evidence_paths.len > 0);
    try std.testing.expectEqualStrings("build.zig", candidate.evidence_paths[0]);
    try std.testing.expectEqualStrings("zig", candidate.related_languages[0]);
    try std.testing.expect(candidate.non_authorizing);
    try std.testing.expect(candidate.candidate_only);
    try std.testing.expect(candidate.requires_review);
    try std.testing.expect(!candidate.mutates_state);
    try std.testing.expect(!candidate.applies_by_default);
}

test "project autopsy detects source and test root candidates with evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "src/main.zig", "pub fn main() void {}");
    try makeFile(tmp.dir, "tests/main_test.zig", "test \"x\" {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const source = findRootCandidate(result.project_profile.source_roots, "src") orelse return error.MissingSourceRoot;
    try std.testing.expectEqualStrings("source_root", source.kind);
    try std.testing.expectEqualStrings("high", source.confidence);
    try std.testing.expect(source.non_authorizing);
    try std.testing.expect(source.evidence_paths.len >= 2);
    try std.testing.expectEqualStrings("src", source.evidence_paths[0]);
    try std.testing.expect(source.detected_language != null);
    try std.testing.expectEqualStrings("zig", source.detected_language.?);

    const tests = findRootCandidate(result.project_profile.test_roots, "tests") orelse return error.MissingTestRoot;
    try std.testing.expectEqualStrings("test_root", tests.kind);
    try std.testing.expectEqualStrings("high", tests.confidence);
    try std.testing.expect(tests.non_authorizing);
    try std.testing.expect(tests.evidence_paths.len >= 2);
    try std.testing.expectEqualStrings("tests", tests.evidence_paths[0]);
}

test "project autopsy treats missing test root as unknown not negative evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "src/main.zig", "pub fn main() void {}");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    try std.testing.expect(findRootCandidate(result.project_profile.source_roots, "src") != null);
    try std.testing.expectEqual(@as(usize, 0), result.project_profile.test_roots.len);
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "test_root_unknown"));
}

test "project autopsy treats tests only project as unknown source root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "tests/main_test.zig", "test \"x\" {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    try std.testing.expectEqual(@as(usize, 0), result.project_profile.source_roots.len);
    try std.testing.expect(findRootCandidate(result.project_profile.test_roots, "tests") != null);
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "source_root_unknown"));
}

test "project autopsy reports ambiguous multiple roots with confidence reasons" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "src/main.ts", "export const x = 1;\n");
    try makeFile(tmp.dir, "lib/helper.ts", "export const y = 1;\n");
    try makeFile(tmp.dir, "test/main.test.ts", "test('x', () => {});\n");
    try makeFile(tmp.dir, "spec/helper.spec.ts", "test('y', () => {});\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const src = findRootCandidate(result.project_profile.source_roots, "src") orelse return error.MissingSourceRoot;
    const lib = findRootCandidate(result.project_profile.source_roots, "lib") orelse return error.MissingSourceRoot;
    try std.testing.expect(src.reason.len > 0);
    try std.testing.expect(lib.reason.len > 0);
    try std.testing.expect(src.evidence_paths.len >= 2);
    try std.testing.expect(lib.evidence_paths.len >= 2);
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "source_root_ambiguous"));
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "test_root_ambiguous"));
}

test "project autopsy proposes Zig build and test commands without execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"\"); _ = b.step(\"bench-serious-workflows\", \"\"); _ = b.step(\"test-parity\", \"\"); }");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "zig_build"));
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "zig_build_test"));
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "zig_build_bench_serious_workflows"));
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "zig_build_test_parity"));
}

test "project autopsy requires explicit Zig test step evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"bench-serious-workflows\", \"\"); }");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "zig_build"));
    try std.testing.expect(!containsCommand(result.project_profile.safe_command_candidates, "zig_build_test"));
    try std.testing.expect(!containsNamedSignal(result.project_profile.test_commands, "zig build test"));
    try std.testing.expect(findVerifierPlan(result.verifier_plan_candidates, "zig_build_test") == null);
}

test "project autopsy requires explicit optional Zig step evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"\"); }");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "zig_build"));
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "zig_build_test"));
    try std.testing.expect(!containsCommand(result.project_profile.safe_command_candidates, "zig_build_bench_serious_workflows"));
    try std.testing.expect(!containsCommand(result.project_profile.safe_command_candidates, "zig_build_test_parity"));
    try std.testing.expect(findVerifierPlan(result.verifier_plan_candidates, "zig_build_bench_serious_workflows") == null);
    try std.testing.expect(findVerifierPlan(result.verifier_plan_candidates, "zig_build_test_parity") == null);
}

test "project autopsy ignores commented and non-step Zig target names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig",
        \\pub fn build(b: *std.Build) void {
        \\    // _ = b.step("test", "");
        \\    _ = not_step("bench-serious-workflows", "");
        \\    _ = b.step_name;
        \\}
    );
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "zig_build"));
    try std.testing.expect(!containsCommand(result.project_profile.safe_command_candidates, "zig_build_test"));
    try std.testing.expect(!containsCommand(result.project_profile.safe_command_candidates, "zig_build_bench_serious_workflows"));
}

test "project autopsy emits non-executing verifier plan candidates for Zig commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"bench-serious-workflows\", \"\"); }");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    const build_plan = findVerifierPlan(result.verifier_plan_candidates, "zig_build") orelse return error.MissingVerifierPlan;
    try std.testing.expectEqualStrings("zig", build_plan.argv[0]);
    try std.testing.expectEqualStrings("build", build_plan.argv[1]);
    try std.testing.expect(build_plan.requires_user_confirmation);
    try std.testing.expect(build_plan.non_authorizing);
    try std.testing.expect(!build_plan.executes_by_default);
    try std.testing.expect(build_plan.source_evidence_paths.len == 1);
    try std.testing.expectEqualStrings("build.zig", build_plan.source_evidence_paths[0]);
    try std.testing.expect(build_plan.unknowns.len > 0);

    const bench_plan = findVerifierPlan(result.verifier_plan_candidates, "zig_build_bench_serious_workflows") orelse return error.MissingVerifierPlan;
    try std.testing.expectEqualStrings("medium", bench_plan.confidence);
    try std.testing.expect(std.mem.indexOf(u8, bench_plan.unknowns[1], "generated-report impact") != null);
}

test "project autopsy detects Node package scripts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "package.json", "{\"scripts\":{\"test\":\"vitest\",\"build\":\"vite build\"}}");
    try makeFile(tmp.dir, "tsconfig.json", "{}");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsNamedSignal(result.project_profile.detected_languages, "javascript_typescript"));
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "npm_test"));
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "npm_run_build"));
}

test "project autopsy recommends Node baseline guidance candidate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "package.json", "{\"scripts\":{\"test\":\"vitest\"}}");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const candidate = findGuidanceCandidate(result.project_profile.recommended_guidance_candidates, "guidance.node_project_baseline") orelse return error.MissingGuidanceCandidate;
    try std.testing.expectEqualStrings("node_project_baseline", candidate.guidance_id);
    try std.testing.expect(candidate.pack_id == null);
    try std.testing.expectEqualStrings("package.json", candidate.evidence_paths[0]);
    try std.testing.expectEqualStrings("javascript_typescript", candidate.related_languages[0]);
    try std.testing.expect(candidate.requires_review);
    try std.testing.expect(!candidate.mutates_state);
    try std.testing.expect(!candidate.applies_by_default);
}

test "project autopsy verifier plans are derived only from detected ecosystem artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "package.json", "{\"scripts\":{\"build\":\"vite build\"}}");
    try makeFile(tmp.dir, "Cargo.toml", "[package]\nname='x'\nversion='0.1.0'\n");
    try makeFile(tmp.dir, "go.mod", "module example.test/x\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(findVerifierPlan(result.verifier_plan_candidates, "npm_run_build") != null);
    try std.testing.expect(findVerifierPlan(result.verifier_plan_candidates, "npm_test") == null);
    try std.testing.expect(findVerifierPlan(result.verifier_plan_candidates, "cargo_build") != null);
    try std.testing.expect(findVerifierPlan(result.verifier_plan_candidates, "cargo_test") != null);
    try std.testing.expect(findVerifierPlan(result.verifier_plan_candidates, "go_test_all") != null);
}

test "project autopsy detects Python pyproject and requirements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "pyproject.toml", "[tool.pytest.ini_options]\n");
    try makeFile(tmp.dir, "requirements.txt", "pytest\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsNamedSignal(result.project_profile.detected_languages, "python"));
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "pytest"));
}

test "project autopsy keeps missing verifier confidence as explicit unknowns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "pyproject.toml", "[tool.pytest.ini_options]\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    const plan = findVerifierPlan(result.verifier_plan_candidates, "pytest") orelse return error.MissingVerifierPlan;
    try std.testing.expectEqualStrings("high_for_candidate_existence_only", plan.confidence);
    try std.testing.expect(plan.unknowns.len >= 3);
    try std.testing.expect(std.mem.indexOf(u8, plan.unknowns[1], "unknown") != null);
    try std.testing.expect(!plan.executes_by_default);
}

test "project autopsy detects CI docs and config files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, ".github/workflows/ci.yml", "name: ci\n");
    try makeFile(tmp.dir, "README.md", "# x\n");
    try makeFile(tmp.dir, "package.json", "{\"scripts\":{\"test\":\"node test.js\"}}\n");
    try makeFile(tmp.dir, ".editorconfig", "root=true\n");
    try makeFile(tmp.dir, ".env.example", "PORT=1\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    const ci = findSignal(result.project_profile.ci_configs, "github_actions") orelse return error.MissingCiConfig;
    try std.testing.expectEqualStrings("ci_config", ci.kind);
    try std.testing.expect(ci.non_authorizing);
    try std.testing.expect(ci.freshness_unknown);
    try std.testing.expectEqual(@as(usize, 1), ci.evidence_paths.len);
    try std.testing.expectEqualStrings(".github/workflows/ci.yml", ci.evidence_paths[0]);

    const docs = findSignal(result.project_profile.docs, "README") orelse return error.MissingDocs;
    try std.testing.expectEqualStrings("documentation", docs.kind);
    try std.testing.expect(docs.non_authorizing);
    try std.testing.expect(docs.freshness_unknown);
    try std.testing.expectEqualStrings("README.md", docs.evidence_paths[0]);

    const config_file = findSignal(result.project_profile.config_files, "package.json") orelse return error.MissingConfig;
    try std.testing.expectEqualStrings("project_config", config_file.kind);
    try std.testing.expect(config_file.non_authorizing);
    try std.testing.expect(config_file.freshness_unknown);
    try std.testing.expectEqualStrings("package.json", config_file.evidence_paths[0]);
    try std.testing.expect(containsNamedSignal(result.project_profile.config_files, ".editorconfig"));
}

test "project autopsy detects common CI config surfaces conservatively" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, ".github/workflows/ci.yaml", "name: ci\n");
    try makeFile(tmp.dir, ".gitlab-ci.yml", "stages: []\n");
    try makeFile(tmp.dir, ".circleci/config.yml", "version: 2.1\n");
    try makeFile(tmp.dir, "buildkite/pipeline.yml", "steps: []\n");
    try makeFile(tmp.dir, "Jenkinsfile", "pipeline {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsNamedSignal(result.project_profile.ci_configs, "github_actions"));
    try std.testing.expect(containsNamedSignal(result.project_profile.ci_configs, "gitlab_ci"));
    try std.testing.expect(containsNamedSignal(result.project_profile.ci_configs, "circleci"));
    try std.testing.expect(containsNamedSignal(result.project_profile.ci_configs, "buildkite"));
    try std.testing.expect(containsNamedSignal(result.project_profile.ci_configs, "jenkins"));
}

test "project autopsy emits scoped CI unknown when no CI config is found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "README.md", "# docs\n");
    try makeFile(tmp.dir, "package.json", "{}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expectEqual(@as(usize, 0), result.project_profile.ci_configs.len);
    const unknown = findSignal(result.project_profile.unknowns, "ci_config_unknown") orelse return error.MissingCiUnknown;
    try std.testing.expect(std.mem.indexOf(u8, unknown.reason, "inspected workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, unknown.reason, "globally") != null);
}

test "project autopsy reports docs directory without README as documentation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "docs/guide.md", "# guide\n");
    try makeFile(tmp.dir, "pyproject.toml", "[project]\nname = \"x\"\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    const docs = findSignal(result.project_profile.docs, "docs") orelse return error.MissingDocsDirectory;
    try std.testing.expectEqualStrings("documentation", docs.kind);
    try std.testing.expectEqualStrings("docs", docs.evidence_paths[0]);
    try std.testing.expect(result.project_gap_report.missing_docs == null);
}

test "project autopsy reports multiple config surfaces as candidates and ambiguity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "package.json", "{}\n");
    try makeFile(tmp.dir, "pyproject.toml", "[project]\nname = \"x\"\n");
    try makeFile(tmp.dir, "Cargo.toml", "[package]\nname = \"x\"\n");
    try makeFile(tmp.dir, "infra/main.tf", "terraform {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsNamedSignal(result.project_profile.config_files, "package.json"));
    try std.testing.expect(containsNamedSignal(result.project_profile.config_files, "pyproject.toml"));
    try std.testing.expect(containsNamedSignal(result.project_profile.config_files, "Cargo.toml"));
    try std.testing.expect(containsNamedSignal(result.project_profile.config_files, "terraform_config"));
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "project_config_ambiguous"));
    try std.testing.expect(containsNamedSignal(result.project_gap_report.next_questions, "choose_canonical_project_config"));
}

test "project autopsy unknown project preserves unknowns instead of false claims" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "notes.txt", "plain\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expectEqual(@as(usize, 0), result.project_profile.detected_languages.len);
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "project_type_unknown"));
}

test "project autopsy safe command candidates are argv only and require confirmation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    for (result.project_profile.safe_command_candidates) |candidate| {
        try std.testing.expect(candidate.argv.len > 0);
        try std.testing.expect(candidate.purpose.len > 0);
        try std.testing.expect(!candidate.read_only);
        try std.testing.expect(candidate.mutation_risk_disclosure.len > 0);
        try std.testing.expect(candidate.why_candidate_exists.len > 0);
        try std.testing.expect(!candidate.executes_by_default);
        try std.testing.expect(candidate.requires_user_confirmation);
        try std.testing.expect(candidate.non_authorizing);
        for (candidate.argv) |part| try std.testing.expect(std.mem.indexOfScalar(u8, part, ';') == null);
    }
}

test "project autopsy command candidates disclose candidate-only authority and mutation risk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"\"); _ = b.step(\"bench-serious-workflows\", \"\"); }");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    for (result.project_profile.safe_command_candidates) |candidate| {
        try std.testing.expectEqual(false, candidate.executes_by_default);
        try std.testing.expectEqual(false, candidate.read_only);
        try std.testing.expect(std.mem.indexOf(u8, candidate.why_candidate_exists, "candidate only and not executed") != null);
        try std.testing.expect(std.mem.indexOf(u8, candidate.mutation_risk_disclosure, "if a user later executes it") != null);
        try std.testing.expect(std.mem.indexOf(u8, candidate.mutation_risk_disclosure, "unknown") != null or
            std.mem.indexOf(u8, candidate.mutation_risk_disclosure, "write") != null);
    }
}

test "project autopsy rejects unsafe command candidates before verifier planning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    var builder = Builder.init(std.heap.page_allocator, root, &.{});
    try builder.appendCommand("unsafe_sudo", &.{ "sudo", "zig", "build" }, "manual", "unsafe test candidate", "high");
    try builder.appendCommand("unsafe_install", &.{ "npm", "install" }, "manual", "unsafe test candidate", "high");
    try builder.appendCommand("unsafe_shell_string", &.{"zig build; touch SHOULD_NOT_EXIST"}, "manual", "unsafe test candidate", "high");
    try std.testing.expectEqual(@as(usize, 0), builder.safe_commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), builder.verifier_plans.items.len);
    try std.testing.expect(containsNamedSignal(builder.unsafe_or_unknown_commands.items, "unsafe_sudo"));
    try std.testing.expect(containsNamedSignal(builder.unsafe_or_unknown_commands.items, "unsafe_install"));
    try std.testing.expect(containsNamedSignal(builder.unsafe_or_unknown_commands.items, "unsafe_shell_string"));
}

test "project autopsy detects build config security migration and runtime risks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "");
    try makeFile(tmp.dir, "src/auth/security.zig", "");
    try makeFile(tmp.dir, "migrations/001.sql", "");
    try makeFile(tmp.dir, "src/runtime/sync.zig", "");
    try makeFile(tmp.dir, "scripts/deploy.sh", "");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(result.project_profile.risk_surfaces.len >= 5);
}

test "project autopsy reports source without tests as risk and verifier gap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const risk_item = findRisk(result.project_profile.risk_surfaces, "risk.source_without_tests") orelse return error.MissingRisk;
    try std.testing.expectEqualStrings("source_without_tests", risk_item.kind);
    try std.testing.expectEqualStrings("medium", risk_item.risk_level);
    try std.testing.expect(risk_item.non_authorizing);
    try std.testing.expect(risk_item.requires_verification);
    try std.testing.expect(risk_item.evidence_paths.len > 0);
    try std.testing.expectEqualStrings("src", risk_item.evidence_paths[0]);

    const gap = findVerifierGap(result.project_gap_report.missing_verifier_adapters, "gap.test_root_verifier_missing") orelse return error.MissingVerifierGap;
    try std.testing.expectEqualStrings("test_root_verifier", gap.missing_verifier);
    try std.testing.expect(gap.non_authorizing);
    try std.testing.expect(gap.blocks_support);
    try std.testing.expect(std.mem.indexOf(u8, gap.reason, "missing evidence") != null);
}

test "project autopsy reports CI without safe test command as verifier gap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, ".github/workflows/ci.yml", "name: ci\n");
    try makeFile(tmp.dir, "README.md", "# docs\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const risk_item = findRisk(result.project_profile.risk_surfaces, "risk.ci_without_test_candidate") orelse return error.MissingRisk;
    try std.testing.expectEqualStrings("ci_without_test_candidate", risk_item.kind);
    try std.testing.expectEqualStrings(".github/workflows/ci.yml", risk_item.evidence_paths[0]);
    const gap = findVerifierGap(result.project_profile.verifier_gap_summary.missing_likely_verifier_adapters, "gap.ci_test_command_missing") orelse return error.MissingVerifierGap;
    try std.testing.expectEqualStrings("test_command_verifier", gap.missing_verifier);
    try std.testing.expect(gap.blocks_support);
}

test "project autopsy reports multiple config systems as risk surface" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "package.json", "{}\n");
    try makeFile(tmp.dir, "pyproject.toml", "[project]\nname = \"x\"\n");
    try makeFile(tmp.dir, "Cargo.toml", "[package]\nname = \"x\"\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const risk_item = findRisk(result.project_profile.risk_surfaces, "risk.multiple_config_systems") orelse return error.MissingRisk;
    try std.testing.expectEqualStrings("multiple_config_systems", risk_item.kind);
    try std.testing.expect(risk_item.evidence_paths.len >= 3);
    try std.testing.expect(risk_item.requires_verification);
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "project_config_ambiguous"));
}

test "project autopsy reports Docker runtime verifier gap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "Dockerfile", "FROM scratch\n");
    try makeFile(tmp.dir, "compose.yml", "services: {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const risk_item = findRisk(result.project_profile.risk_surfaces, "risk.container_runtime_unverified") orelse return error.MissingRisk;
    try std.testing.expectEqualStrings("container_runtime_unverified", risk_item.kind);
    try std.testing.expect(risk_item.evidence_paths.len >= 2);
    const gap = findVerifierGap(result.project_gap_report.missing_verifier_adapters, "gap.runtime_verifier_missing") orelse return error.MissingVerifierGap;
    try std.testing.expectEqualStrings("runtime_container_verifier", gap.missing_verifier);
    try std.testing.expect(gap.non_authorizing);

    const candidate = findGuidanceCandidate(result.project_profile.recommended_guidance_candidates, "guidance.container_runtime_guidance") orelse return error.MissingGuidanceCandidate;
    try std.testing.expectEqualStrings("container_runtime_guidance", candidate.guidance_id);
    try std.testing.expect(candidate.evidence_paths.len >= 2);
    try std.testing.expectEqualStrings("risk.container_runtime_unverified", candidate.related_risks[0]);
    try std.testing.expect(containsString(candidate.related_verifier_gaps, "gap.runtime_verifier_missing"));
    try std.testing.expect(candidate.candidate_only);
    try std.testing.expect(!candidate.applies_by_default);
}

test "project autopsy reports config validation gap for terraform" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "infra/main.tf", "terraform {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const risk_item = findRisk(result.project_profile.risk_surfaces, "risk.config_validation_missing") orelse return error.MissingRisk;
    try std.testing.expectEqualStrings("config_validation_missing", risk_item.kind);
    try std.testing.expectEqualStrings("infra/main.tf", risk_item.evidence_paths[0]);
    const gap = findVerifierGap(result.project_gap_report.missing_verifier_adapters, "gap.config_validation_missing") orelse return error.MissingVerifierGap;
    try std.testing.expectEqualStrings("config_validation_verifier", gap.missing_verifier);

    const candidate = findGuidanceCandidate(result.project_profile.recommended_guidance_candidates, "guidance.terraform_validation_guidance") orelse return error.MissingGuidanceCandidate;
    try std.testing.expectEqualStrings("terraform_validation_guidance", candidate.guidance_id);
    try std.testing.expectEqualStrings("infra/main.tf", candidate.evidence_paths[0]);
    try std.testing.expectEqualStrings("risk.config_validation_missing", candidate.related_risks[0]);
    try std.testing.expect(containsString(candidate.related_verifier_gaps, "gap.config_validation_missing"));
    try std.testing.expect(candidate.requires_review);
    try std.testing.expect(!candidate.mutates_state);
}

test "project autopsy emits multiple review-required guidance candidates for ambiguous project" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "package.json", "{\"scripts\":{\"test\":\"vitest\"}}\n");
    try makeFile(tmp.dir, "Cargo.toml", "[package]\nname = \"x\"\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const node = findGuidanceCandidate(result.project_profile.recommended_guidance_candidates, "guidance.node_project_baseline") orelse return error.MissingGuidanceCandidate;
    const rust = findGuidanceCandidate(result.project_profile.recommended_guidance_candidates, "guidance.rust_project_baseline") orelse return error.MissingGuidanceCandidate;
    try std.testing.expect(node.requires_review);
    try std.testing.expect(rust.requires_review);
    try std.testing.expect(node.candidate_only);
    try std.testing.expect(rust.candidate_only);
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "project_config_ambiguous"));
}

test "project autopsy operator summary captures rich project shape and top fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"\"); }");
    try makeFile(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    try makeFile(tmp.dir, "tests/main_test.zig", "test \"x\" {}\n");
    try makeFile(tmp.dir, ".github/workflows/ci.yml", "name: ci\n");
    try makeFile(tmp.dir, "README.md", "# docs\n");
    try makeFile(tmp.dir, ".env.example", "PORT=1\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    const summary = result.operator_summary;
    try std.testing.expectEqualStrings("zig", summary.primary_languages[0]);
    try std.testing.expectEqualStrings("zig_build", summary.primary_build_systems[0]);
    try std.testing.expectEqual(@as(usize, 1), summary.source_root_count);
    try std.testing.expectEqual(@as(usize, 1), summary.test_root_count);
    try std.testing.expect(summary.ci_detected);
    try std.testing.expect(summary.docs_detected);
    try std.testing.expect(summary.config_surface_count >= 2);
    try std.testing.expectEqual(summary.safe_command_candidate_count, result.project_profile.safe_command_candidates.len);
    try std.testing.expectEqual(summary.risk_surface_count, result.project_profile.risk_surfaces.len);
    try std.testing.expectEqual(summary.verifier_gap_count, result.project_gap_report.missing_verifier_adapters.len);
    try std.testing.expectEqual(summary.guidance_candidate_count, result.project_profile.recommended_guidance_candidates.len);
    try std.testing.expect(summary.top_risks.len <= MAX_OPERATOR_SUMMARY_ITEMS);
    try std.testing.expect(summary.top_unknowns.len <= MAX_OPERATOR_SUMMARY_ITEMS);
    try std.testing.expect(summary.top_verifier_gaps.len <= MAX_OPERATOR_SUMMARY_ITEMS);
    try std.testing.expect(summary.suggested_next_actions.len <= MAX_OPERATOR_SUMMARY_ITEMS);
    try std.testing.expect(std.mem.indexOf(u8, summary.project_shape_summary, "draft summary only") != null);
}

test "project autopsy operator summary keeps no-test project as missing evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    const summary = result.operator_summary;

    try std.testing.expectEqual(@as(usize, 1), summary.source_root_count);
    try std.testing.expectEqual(@as(usize, 0), summary.test_root_count);
    const unknown = findSummaryItem(summary.top_unknowns, "test_root_unknown") orelse return error.MissingSummaryUnknown;
    try std.testing.expectEqualStrings("test_root_unknown", unknown.id);
    try std.testing.expect(std.mem.indexOf(u8, unknown.reason, "absence of evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, unknown.reason, "tests do not exist") != null);
    const gap = findVerifierGap(result.project_gap_report.missing_verifier_adapters, "gap.test_root_verifier_missing") orelse return error.MissingVerifierGap;
    try std.testing.expect(std.mem.indexOf(u8, gap.reason, "missing evidence") != null);
}

test "project autopsy operator summary references guidance candidates as candidate-only next actions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "Dockerfile", "FROM scratch\n");
    try makeFile(tmp.dir, "compose.yml", "services: {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    _ = findGuidanceCandidate(result.project_profile.recommended_guidance_candidates, "guidance.container_runtime_guidance") orelse return error.MissingGuidanceCandidate;
    const action = findSummaryAction(result.operator_summary.suggested_next_actions, "guidance.container_runtime_guidance") orelse return error.MissingSummaryAction;
    try std.testing.expectEqualStrings("guidance_candidate", action.kind);
    try std.testing.expect(action.candidate_only);
    try std.testing.expect(action.non_authorizing);
    try std.testing.expect(action.read_only);
    try std.testing.expect(!action.executes_by_default);
    try std.testing.expect(!action.applies_by_default);
    try std.testing.expect(std.mem.indexOf(u8, action.reason, "not applied") != null);
}

test "project autopsy operator summary preserves read-only non-authorizing invariants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"\"); }");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    const summary = result.operator_summary;

    try std.testing.expect(summary.non_authorizing);
    try std.testing.expect(summary.read_only);
    for (summary.suggested_next_actions) |action| {
        try std.testing.expect(action.candidate_only);
        try std.testing.expect(action.non_authorizing);
        try std.testing.expect(action.read_only);
        try std.testing.expect(!action.executes_by_default);
        try std.testing.expect(!action.applies_by_default);
    }
}

test "project autopsy does not report false missing test gap when tests and safe command exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"\"); }");
    try makeFile(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    try makeFile(tmp.dir, "tests/main_test.zig", "test \"x\" {}\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    try std.testing.expect(findRisk(result.project_profile.risk_surfaces, "risk.source_without_tests") == null);
    try std.testing.expect(findRisk(result.project_profile.risk_surfaces, "risk.ci_without_test_candidate") == null);
    try std.testing.expect(findVerifierGap(result.project_gap_report.missing_verifier_adapters, "gap.test_root_verifier_missing") == null);
    try std.testing.expect(result.project_gap_report.missing_test_command == null);
    try std.testing.expect(containsCommand(result.project_profile.safe_command_candidates, "zig_build_test"));
}

test "project autopsy gap report includes missing test command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(result.project_gap_report.missing_test_command != null);
}

test "project autopsy gap report records missing build ci and docs as gaps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "notes.txt", "plain\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(result.project_gap_report.missing_build_command != null);
    try std.testing.expect(result.project_gap_report.missing_ci != null);
    try std.testing.expect(result.project_gap_report.missing_docs != null);
    try std.testing.expect(result.project_gap_report.non_authorizing);
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "project_type_unknown"));
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "safe_command_candidates_unknown"));
}

test "project autopsy emits no fake available pack for unknown project" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "notes.txt", "plain\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    try std.testing.expectEqual(@as(usize, 0), result.project_profile.recommended_guidance_candidates.len);
    try std.testing.expectEqual(@as(usize, 0), result.project_profile.recommended_packs.len);
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "pack_guidance_candidates_unknown"));
    try std.testing.expect(containsNamedSignal(result.project_gap_report.missing_pack_recommendations, "no_pack_recommendation"));
}

test "project autopsy non-authorizing invariant is preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(result.non_authorizing);
    try std.testing.expect(result.project_profile.non_authorizing);
    try std.testing.expect(result.project_gap_report.non_authorizing);
}

test "project autopsy output ordering is deterministic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "package.json", "{\"scripts\":{\"build\":\"x\",\"test\":\"x\"}}");
    try makeFile(tmp.dir, "build.zig", "");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const a = try analyze(std.heap.page_allocator, root, .{});
    const b = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expectEqualStrings(a.project_profile.detected_languages[0].name, b.project_profile.detected_languages[0].name);
    try std.testing.expectEqualStrings(a.project_profile.safe_command_candidates[0].id, b.project_profile.safe_command_candidates[0].id);
}

test "project autopsy JSON output keeps stable draft safety fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"\"); }");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});

    var first = std.ArrayList(u8).init(std.testing.allocator);
    defer first.deinit();
    var second = std.ArrayList(u8).init(std.testing.allocator);
    defer second.deinit();
    try result.writeJson(first.writer());
    try result.writeJson(second.writer());
    try std.testing.expectEqualStrings(first.items, second.items);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first.items, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    try std.testing.expectEqualStrings("draft", root_obj.get("state").?.string);
    try std.testing.expect(root_obj.get("non_authorizing").?.bool);

    const profile_obj = root_obj.get("project_profile").?.object;
    try std.testing.expect(profile_obj.get("non_authorizing").?.bool);
    for (profile_obj.get("risk_surfaces").?.array.items) |risk_value| {
        const risk_obj = risk_value.object;
        try std.testing.expect(risk_obj.get("id").?.string.len > 0);
        try std.testing.expect(risk_obj.get("kind").?.string.len > 0);
        try std.testing.expect(risk_obj.get("risk_level").?.string.len > 0);
        try std.testing.expect(risk_obj.get("evidence_paths").?.array.items.len > 0);
        try std.testing.expect(risk_obj.get("requires_verification").?.bool);
        try std.testing.expect(risk_obj.get("non_authorizing").?.bool);
    }
    for (profile_obj.get("safe_command_candidates").?.array.items) |candidate_value| {
        const candidate = candidate_value.object;
        try std.testing.expect(candidate.get("purpose").?.string.len > 0);
        try std.testing.expect(!candidate.get("read_only").?.bool);
        try std.testing.expect(candidate.get("mutation_risk_disclosure").?.string.len > 0);
        try std.testing.expect(candidate.get("why_candidate_exists").?.string.len > 0);
        try std.testing.expect(!candidate.get("executes_by_default").?.bool);
        try std.testing.expect(candidate.get("requires_user_confirmation").?.bool);
        try std.testing.expect(candidate.get("non_authorizing").?.bool);
        try std.testing.expect(candidate.get("argv").?.array.items.len > 0);
    }

    for (root_obj.get("verifier_plan_candidates").?.array.items) |plan_value| {
        const plan = plan_value.object;
        try std.testing.expect(plan.get("requires_user_confirmation").?.bool);
        try std.testing.expect(plan.get("non_authorizing").?.bool);
        try std.testing.expect(!plan.get("executes_by_default").?.bool);
    }

    for (profile_obj.get("recommended_guidance_candidates").?.array.items) |candidate_value| {
        const candidate = candidate_value.object;
        try std.testing.expectEqualStrings("pack_guidance_candidate", candidate.get("kind").?.string);
        try std.testing.expect(candidate.get("pack_id").? == .null);
        try std.testing.expect(candidate.get("guidance_id").?.string.len > 0);
        try std.testing.expect(candidate.get("reason").?.string.len > 0);
        try std.testing.expect(candidate.get("suggested_next_action").?.string.len > 0);
        try std.testing.expect(candidate.get("non_authorizing").?.bool);
        try std.testing.expect(candidate.get("candidate_only").?.bool);
        try std.testing.expect(candidate.get("requires_review").?.bool);
        try std.testing.expect(!candidate.get("mutates_state").?.bool);
        try std.testing.expect(!candidate.get("applies_by_default").?.bool);
    }

    const gap_report_obj = root_obj.get("project_gap_report").?.object;
    for (gap_report_obj.get("missing_verifier_adapters").?.array.items) |gap_value| {
        const gap_obj = gap_value.object;
        try std.testing.expect(gap_obj.get("id").?.string.len > 0);
        try std.testing.expectEqualStrings("verifier_gap", gap_obj.get("kind").?.string);
        try std.testing.expect(gap_obj.get("missing_verifier").?.string.len > 0);
        try std.testing.expect(gap_obj.get("blocks_support").?.bool);
        try std.testing.expect(gap_obj.get("non_authorizing").?.bool);
    }
}

test "project autopsy rejects traversal reads outside workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    try std.testing.expectError(error.PathOutsideWorkspace, readSmallFile(std.heap.page_allocator, root, "../outside"));
}

test "project autopsy traversal is bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..20) |i| {
        const name = try std.fmt.allocPrint(std.heap.page_allocator, "dir_{d}/file_{d}.txt", .{ i, i });
        defer std.heap.page_allocator.free(name);
        try makeFile(tmp.dir, name, "x");
    }
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{ .max_entries = 5, .max_depth = 4 });
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "traversal_entry_limit_reached"));
}

test "project autopsy max depth keeps deeper evidence unknown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "level1/build.zig", "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"\"); }");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{ .max_entries = 100, .max_depth = 0 });
    try std.testing.expect(!containsCommand(result.project_profile.safe_command_candidates, "zig_build"));
    try std.testing.expect(result.project_gap_report.missing_build_command != null);
    try std.testing.expect(containsNamedSignal(result.project_profile.unknowns, "project_type_unknown"));
}

test "project autopsy does not execute commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "package.json", "{\"scripts\":{\"test\":\"touch SHOULD_NOT_EXIST\"}}");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    _ = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("SHOULD_NOT_EXIST", .{}));
}

test "project autopsy does not write files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeFile(tmp.dir, "build.zig", "");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    _ = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("project_profile.json", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(".ghost", .{}));
}
