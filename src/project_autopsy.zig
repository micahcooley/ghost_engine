const std = @import("std");

pub const DEFAULT_MAX_ENTRIES: usize = 4096;
pub const DEFAULT_MAX_DEPTH: usize = 6;
pub const MAX_FILE_READ_BYTES: usize = 128 * 1024;

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
};

pub const RiskSurface = struct {
    path: []const u8,
    risk_kind: []const u8,
    reason: []const u8,
    suggested_caution: []const u8,
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

pub const VerifierGapSummary = struct {
    known_possible_verifier_adapters: []Signal = &.{},
    missing_likely_verifier_adapters: []Signal = &.{},
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
    source_roots: []Signal = &.{},
    test_roots: []Signal = &.{},
    entry_points: []Signal = &.{},
    dependency_files: []Signal = &.{},
    risk_surfaces: []RiskSurface = &.{},
    safe_command_candidates: []SafeCommandCandidate = &.{},
    verifier_gap_summary: VerifierGapSummary = .{},
    recommended_packs: []Signal = &.{},
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
    missing_verifier_adapters: []Signal = &.{},
    missing_pack_recommendations: []Signal = &.{},
    ambiguous_project_type: []Signal = &.{},
    unsafe_or_unknown_commands: []Signal = &.{},
    next_questions: []Signal = &.{},
    non_authorizing: bool = true,
};

pub const AutopsyResult = struct {
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
    source_roots: std.ArrayList(Signal),
    test_roots: std.ArrayList(Signal),
    entry_points: std.ArrayList(Signal),
    dependency_files: std.ArrayList(Signal),
    risk_surfaces: std.ArrayList(RiskSurface),
    safe_commands: std.ArrayList(SafeCommandCandidate),
    verifier_plans: std.ArrayList(VerifierPlanCandidate),
    recommended_packs: std.ArrayList(Signal),
    unknowns: std.ArrayList(Signal),
    trace: std.ArrayList(Signal),
    possible_verifiers: std.ArrayList(Signal),
    missing_verifiers: std.ArrayList(Signal),
    unknown_verifiers: std.ArrayList(Signal),
    next_checks: std.ArrayList(Signal),
    gap_missing_verifiers: std.ArrayList(Signal),
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
        return .{
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, path),
            .kind = try self.allocator.dupe(u8, kind),
            .confidence = try self.allocator.dupe(u8, confidence),
            .reason = try self.allocator.dupe(u8, reason),
        };
    }

    fn appendSignal(self: *Builder, list: *std.ArrayList(Signal), name: []const u8, path: []const u8, kind: []const u8, confidence: []const u8, reason: []const u8) !void {
        if (containsSignal(list.items, name, path, kind)) return;
        try list.append(try self.signal(name, path, kind, confidence, reason));
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

    fn finish(self: *Builder) !AutopsyResult {
        sortSignals(self.languages.items);
        sortSignals(self.frameworks.items);
        sortSignals(self.build_systems.items);
        sortSignals(self.test_commands.items);
        sortSignals(self.package_managers.items);
        sortSignals(self.ci_configs.items);
        sortSignals(self.docs.items);
        sortSignals(self.config_files.items);
        sortSignals(self.source_roots.items);
        sortSignals(self.test_roots.items);
        sortSignals(self.entry_points.items);
        sortSignals(self.dependency_files.items);
        sortRisks(self.risk_surfaces.items);
        sortCommands(self.safe_commands.items);
        sortVerifierPlans(self.verifier_plans.items);
        sortSignals(self.recommended_packs.items);
        sortSignals(self.unknowns.items);
        sortSignals(self.trace.items);
        sortSignals(self.possible_verifiers.items);
        sortSignals(self.missing_verifiers.items);
        sortSignals(self.unknown_verifiers.items);
        sortSignals(self.next_checks.items);
        sortSignals(self.gap_missing_verifiers.items);
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

        return .{
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
    return builder.finish();
}

pub fn writeJson(allocator: std.mem.Allocator, workspace_root: []const u8, writer: anytype) !void {
    const result = try analyze(allocator, workspace_root, .{});
    try result.writeJson(writer);
}

fn detectCommon(builder: *Builder) !void {
    for (builder.entries) |entry| {
        if (entry.is_dir) {
            if (std.mem.eql(u8, entry.rel_path, "src")) try builder.appendSignal(&builder.source_roots, "src", entry.rel_path, "source_root", "high", "conventional source directory exists");
            if (std.mem.eql(u8, entry.rel_path, "test") or std.mem.eql(u8, entry.rel_path, "tests")) try builder.appendSignal(&builder.test_roots, entry.basename, entry.rel_path, "test_root", "high", "conventional test directory exists");
            if (std.mem.eql(u8, entry.rel_path, "docs")) try builder.appendSignal(&builder.docs, "docs", entry.rel_path, "docs_directory", "high", "docs directory exists");
            continue;
        }

        if (std.mem.eql(u8, entry.rel_path, ".github/workflows") or startsWith(entry.rel_path, ".github/workflows/")) {
            if (endsWith(entry.rel_path, ".yml") or endsWith(entry.rel_path, ".yaml")) try builder.appendSignal(&builder.ci_configs, "github_actions", entry.rel_path, "ci_config", "high", "GitHub Actions workflow file exists");
        } else if (std.mem.eql(u8, entry.rel_path, ".gitlab-ci.yml")) {
            try builder.appendSignal(&builder.ci_configs, "gitlab_ci", entry.rel_path, "ci_config", "high", "GitLab CI file exists");
        }

        if (std.ascii.eqlIgnoreCase(entry.basename, "README.md")) try builder.appendSignal(&builder.docs, "README.md", entry.rel_path, "readme", "high", "README file exists");
        if (std.ascii.eqlIgnoreCase(entry.basename, "CONTRIBUTING.md")) try builder.appendSignal(&builder.docs, "CONTRIBUTING.md", entry.rel_path, "contributing", "high", "contributing guide exists");
        if (std.mem.eql(u8, entry.basename, "LICENSE")) try builder.appendSignal(&builder.docs, "LICENSE", entry.rel_path, "license", "high", "license file exists");

        if (isConfigFile(entry.basename)) try builder.appendSignal(&builder.config_files, entry.basename, entry.rel_path, "config_file", "high", "recognized configuration file exists");
        if (isDependencyFile(entry.basename)) try builder.appendSignal(&builder.dependency_files, entry.basename, entry.rel_path, "dependency_file", "high", "recognized dependency or lock file exists");
        if (isPackageManagerFile(entry.basename)) try builder.appendSignal(&builder.package_managers, packageManagerName(entry.basename), entry.rel_path, "package_manager", "high", "package manager file exists");
        if (isEntryPoint(entry.rel_path)) try builder.appendSignal(&builder.entry_points, entry.basename, entry.rel_path, "entry_point", "medium", "conventional entry point path exists");
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
        try builder.appendSignal(&builder.config_files, "docker", path, "container_config", "high", "Docker config exists");
    }
}

fn detectRisks(builder: *Builder) !void {
    for (builder.entries) |entry| {
        if (entry.is_dir) continue;
        const path = entry.rel_path;
        const lower = try std.ascii.allocLowerString(builder.allocator, path);
        defer builder.allocator.free(lower);
        if (containsAny(lower, &.{ "auth", "security", "secret", "token", "password" })) {
            try builder.risk_surfaces.append(try risk(builder, path, "auth_security", "security-sensitive name detected", "treat as routing signal only; require explicit evidence before claims"));
        }
        if (containsAny(lower, &.{ "migration", "database", "schema.sql", "db/" })) {
            try builder.risk_surfaces.append(try risk(builder, path, "database_migration", "database or migration path detected", "inspect ordering and reversibility before recommending changes"));
        }
        if (startsWith(path, ".github/") or std.mem.eql(u8, path, ".gitlab-ci.yml") or containsAny(lower, &.{ "deploy", "release" })) {
            try builder.risk_surfaces.append(try risk(builder, path, "ci_deployment", "CI or deployment surface detected", "do not infer deployment safety from presence alone"));
        }
        if (isDependencyFile(entry.basename) or std.mem.eql(u8, entry.basename, "build.zig") or std.mem.eql(u8, entry.basename, "Makefile") or std.mem.eql(u8, entry.basename, "CMakeLists.txt")) {
            try builder.risk_surfaces.append(try risk(builder, path, "build_dependency", "build or dependency file detected", "command candidates still require confirmation and execution evidence"));
        }
        if (containsAny(lower, &.{ "concurrency", "sync", "runtime", "thread", "mutex" })) {
            try builder.risk_surfaces.append(try risk(builder, path, "concurrency_runtime", "runtime/concurrency-related name detected", "avoid broad behavioral claims without verifier evidence"));
        }
        if (endsWith(path, ".sh")) {
            try builder.risk_surfaces.append(try risk(builder, path, "shell_script", "shell script detected", "inspect argv semantics before any execution proposal"));
        }
        if (std.mem.startsWith(u8, entry.basename, ".env") or containsAny(lower, &.{ "config", ".toml", ".yaml", ".yml", ".json" })) {
            try builder.risk_surfaces.append(try risk(builder, path, "config_env", "configuration or environment-like file detected", "unknown values are not evidence of runtime behavior"));
        }
        if (containsAny(lower, &.{ "verifier", "test_", "_test", "tests", "bench" })) {
            try builder.risk_surfaces.append(try risk(builder, path, "verifier_test_harness", "test/verifier/benchmark surface detected", "keep proposed checks separate from executed verifier results"));
        }
    }
}

fn detectGaps(builder: *Builder, options: AnalyzeOptions, entry_count: usize) !void {
    if (builder.languages.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "project_type_unknown", "", "unknown", "high", "no known language/toolchain signal was detected");
        try builder.appendSignal(&builder.ambiguous_project_type, "project_type_unknown", "", "ambiguous_project_type", "high", "known Pass 1 project signals were absent");
        try builder.appendSignal(&builder.next_questions, "identify_project_type", "", "next_question", "high", "Which toolchain should Ghost inspect for this workspace?");
    }
    if (builder.safe_commands.items.len == 0) {
        try builder.appendSignal(&builder.unknowns, "safe_command_candidates_unknown", "", "unknown", "medium", "no safe command candidates were inferred");
        try builder.appendSignal(&builder.next_questions, "test_build_commands", "", "next_question", "medium", "What build or test command should be considered for future explicit verification?");
    }
    if (builder.recommended_packs.items.len == 0) {
        try builder.appendSignal(&builder.missing_pack_recommendations, "no_pack_recommendation", "", "gap", "medium", "Pass 1 does not auto-select or mount Knowledge Packs");
    }
    try builder.appendSignal(&builder.unknown_verifiers, "verifier_registration_status", "", "unknown", "high", "Project Autopsy only proposes verifier candidates; it does not inspect registry state or register adapters");
    try builder.appendSignal(&builder.gap_missing_verifiers, "verifier_execution_not_run", "", "verifier_gap", "high", "No verifier execution result exists because autopsy is read-only");
    if (entry_count >= options.max_entries) try builder.appendSignal(&builder.unknowns, "traversal_entry_limit_reached", "", "unknown", "medium", "directory traversal hit max_entries bound");
}

fn risk(builder: *Builder, path: []const u8, kind: []const u8, reason_text: []const u8, caution: []const u8) !RiskSurface {
    return .{
        .path = try builder.allocator.dupe(u8, path),
        .risk_kind = try builder.allocator.dupe(u8, kind),
        .reason = try builder.allocator.dupe(u8, reason_text),
        .suggested_caution = try builder.allocator.dupe(u8, caution),
    };
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

fn hasExtensionInDir(entries: []const Entry, dir_prefix: []const u8, extension: []const u8) bool {
    for (entries) |entry| {
        if (!entry.is_dir and startsWith(entry.rel_path, dir_prefix) and endsWith(entry.rel_path, extension)) return true;
    }
    return false;
}

fn isConfigFile(name: []const u8) bool {
    return std.mem.eql(u8, name, ".editorconfig") or std.mem.eql(u8, name, ".env.example") or
        std.mem.eql(u8, name, "Dockerfile") or std.mem.eql(u8, name, "docker-compose.yml") or
        std.mem.eql(u8, name, "tsconfig.json") or std.mem.eql(u8, name, "pytest.ini");
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

fn riskLessThan(_: void, a: RiskSurface, b: RiskSurface) bool {
    const p = std.mem.order(u8, a.path, b.path);
    if (p != .eq) return p == .lt;
    return std.mem.order(u8, a.risk_kind, b.risk_kind) == .lt;
}

fn sortRisks(items: []RiskSurface) void {
    std.mem.sort(RiskSurface, items, {}, riskLessThan);
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

fn containsCommand(items: []const SafeCommandCandidate, id: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn findVerifierPlan(items: []const VerifierPlanCandidate, id: []const u8) ?VerifierPlanCandidate {
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
    try makeFile(tmp.dir, ".editorconfig", "root=true\n");
    try makeFile(tmp.dir, ".env.example", "PORT=1\n");
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    defer std.heap.page_allocator.free(root);
    const result = try analyze(std.heap.page_allocator, root, .{});
    try std.testing.expect(containsNamedSignal(result.project_profile.ci_configs, "github_actions"));
    try std.testing.expect(containsNamedSignal(result.project_profile.docs, "README.md"));
    try std.testing.expect(containsNamedSignal(result.project_profile.config_files, ".editorconfig"));
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
