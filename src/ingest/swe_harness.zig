const std = @import("std");
const bench_loader = @import("bench_loader.zig");
const bootstrap = @import("bootstrap.zig");
const distiller = @import("../codec/distiller.zig");
const gutf = @import("../codec/gutf.zig");
const gip_mapping = @import("../gip/mapping.zig");
const gpu_lattice = @import("../gpu/vulkan_init.zig");
const patcher = @import("patcher.zig");
const sandbox = @import("../oracle/sandbox.zig");
const hypervector = @import("../vsa/hypervector.zig");
const vsa_vulkan = @import("../vsa_vulkan.zig");

pub const DEFAULT_ROWS_PATH = ".ghost/knowledge/swe_bench_pro/rows.jsonl";
pub const DEFAULT_KNOWLEDGE_DIR = ".ghost/knowledge/swe_bench_pro";
pub const DEFAULT_WORKSPACE_ROOT = "/tmp/ghost/swe";
pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 256 * 1024;

pub const Language = enum {
    python,
    javascript,
    zig,
    unknown,

    pub fn fromText(text: []const u8) Language {
        if (std.ascii.eqlIgnoreCase(text, "python") or std.ascii.eqlIgnoreCase(text, "py")) return .python;
        if (std.ascii.eqlIgnoreCase(text, "js") or
            std.ascii.eqlIgnoreCase(text, "javascript") or
            std.ascii.eqlIgnoreCase(text, "node") or
            std.ascii.eqlIgnoreCase(text, "typescript") or
            std.ascii.eqlIgnoreCase(text, "ts"))
        {
            return .javascript;
        }
        if (std.ascii.eqlIgnoreCase(text, "zig")) return .zig;
        return .unknown;
    }
};

pub const ProofStatus = enum {
    pending,
    cloned,
    base_reproduced,
    patch_applied,
    verified,
    invalid_environment,
    missing_patch,
    unsupported_language,
    failed_clone,
    failed_checkout,
    failed_test_patch,
    failed_gold_patch,
    failed_fail_to_pass,
    failed_pass_to_pass,
    cleanup_failed,
    false_positive,
    oracle_timeout,

    pub fn name(self: ProofStatus) []const u8 {
        return @tagName(self);
    }
};

pub fn gipOpForStatus(status: ProofStatus) gip_mapping.GipOpCode {
    return switch (status) {
        .pending, .cloned => .GIP_OP_GET_TELEMETRY,
        .base_reproduced, .patch_applied => .GIP_OP_ORACLE_PROVE,
        .verified => .GIP_OP_TRUTH_SYNC,
        .invalid_environment,
        .missing_patch,
        .unsupported_language,
        .failed_clone,
        .failed_checkout,
        .failed_test_patch,
        .failed_gold_patch,
        .failed_fail_to_pass,
        .failed_pass_to_pass,
        .cleanup_failed,
        .false_positive,
        => .GIP_OP_SEC_FAULT,
        .oracle_timeout => .GIP_OP_ORACLE_TIMEOUT,
    };
}

pub const Instance = struct {
    allocator: std.mem.Allocator,
    instance_id: []u8,
    repo: []u8,
    base_commit: []u8,
    repo_language: Language,
    problem_statement: []u8,
    interface_text: []u8,
    root_hint_path: []u8,
    patch: []u8,
    test_patch: []u8,
    fail_to_pass: [][]u8,
    pass_to_pass: [][]u8,
    selected_test_files: [][]u8,

    pub fn deinit(self: *Instance) void {
        self.allocator.free(self.instance_id);
        self.allocator.free(self.repo);
        self.allocator.free(self.base_commit);
        self.allocator.free(self.problem_statement);
        self.allocator.free(self.interface_text);
        self.allocator.free(self.root_hint_path);
        self.allocator.free(self.patch);
        self.allocator.free(self.test_patch);
        freeStringList(self.allocator, self.fail_to_pass);
        freeStringList(self.allocator, self.pass_to_pass);
        freeStringList(self.allocator, self.selected_test_files);
        self.* = undefined;
    }
};

pub const Options = struct {
    rows_path: []const u8 = DEFAULT_ROWS_PATH,
    workspace_root: []const u8 = DEFAULT_WORKSPACE_ROOT,
    knowledge_dir: []const u8 = DEFAULT_KNOWLEDGE_DIR,
    corpus_dir: ?[]const u8 = null,
    python_exe: []const u8 = "python3",
    pip_exe: []const u8 = "pip3",
    limit: usize = 5,
    cleanup: bool = true,
    enable_bootstrap: bool = true,
    enable_ephemeral_venv: bool = true,
    enable_preflight_pip: bool = true,
    enable_preflight_npm: bool = true,
    enable_reprioritization: bool = true,
    enable_gpu_lattice_query: bool = true,
    focus_supported_languages: bool = true,
    cluster_seed: ?[]const u8 = "qutebrowser",
    max_environment_attempts: u8 = 3,
    max_repair_attempts: u8 = 3,
    max_output_bytes: usize = DEFAULT_MAX_OUTPUT_BYTES,
    sandbox_spec: sandbox.SandboxSpec = .{ .timeout_ms = 300_000, .network_disabled = true },
};

pub const CommandResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }

    pub fn exitedOk(self: CommandResult) bool {
        return switch (self.term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }
};

const RuntimeEnv = struct {
    allocator: std.mem.Allocator,
    python_exe: []u8,
    pip_exe: []u8,
    venv_path: ?[]u8 = null,
    preflight_dependency_install: bool = false,
    commit_year: ?u16 = null,

    fn deinit(self: *RuntimeEnv) void {
        self.allocator.free(self.python_exe);
        self.allocator.free(self.pip_exe);
        if (self.venv_path) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

const RankedInstance = struct {
    instance: Instance,
    distance: ?u16 = null,

    fn deinit(self: *RankedInstance) void {
        self.instance.deinit();
        self.* = undefined;
    }
};

pub const LatticeBackend = enum {
    none,
    cpu,
    vulkan,

    pub fn name(self: LatticeBackend) []const u8 {
        return @tagName(self);
    }
};

const LatticeTelemetry = struct {
    backend: LatticeBackend = .none,
    rune_count: usize = 0,
    gip_opcode: gip_mapping.GipOpCode = .GIP_OP_LATTICE_QUERY,
};

pub const ProofResult = struct {
    allocator: std.mem.Allocator,
    instance_id: []u8,
    repo: []u8,
    status: ProofStatus,
    gip_opcode: gip_mapping.GipOpCode,
    workspace_path: []u8,
    build_root_path: ?[]u8 = null,
    build_root_relative: ?[]u8 = null,
    build_root_marker: ?[]u8 = null,
    build_root_candidates: usize = 0,
    build_root_gip_opcode: gip_mapping.GipOpCode = .GIP_OP_RESOLVE_BUILD_ROOT,
    landlock_gip_opcode: gip_mapping.GipOpCode = .GIP_OP_LANDLOCK_STRICT,
    landlock_allowed_paths: ?[]u8 = null,
    landlock_retry_path: ?[]u8 = null,
    oracle_timeout: bool = false,
    oracle_timeout_gip_opcode: gip_mapping.GipOpCode = .GIP_OP_ORACLE_TIMEOUT,
    repair_attempts: u8 = 0,
    repair_gip_opcode: gip_mapping.GipOpCode = .GIP_OP_REPAIR_ENV,
    ephemeral_venv_path: ?[]u8 = null,
    preflight_dependency_install: bool = false,
    patch_integrity_gip_opcode: gip_mapping.GipOpCode = .GIP_OP_PATCH_INTEGRITY,
    test_patch_mode: ?[]u8 = null,
    gold_patch_mode: ?[]u8 = null,
    gold_patch_changed_files: ?[]u8 = null,
    gold_patch_diff_stat: ?[]u8 = null,
    reprioritization_distance: ?u16 = null,
    reason: []u8,
    reproduced_base_failure: bool = false,
    fail_to_pass_passed: bool = false,
    pass_to_pass_passed: bool = false,
    rune_written: bool = false,
    cleanup_done: bool = false,
    environment_attempts: u8 = 0,
    gap_logged: bool = false,

    pub fn deinit(self: *ProofResult) void {
        self.allocator.free(self.instance_id);
        self.allocator.free(self.repo);
        self.allocator.free(self.workspace_path);
        if (self.build_root_path) |value| self.allocator.free(value);
        if (self.build_root_relative) |value| self.allocator.free(value);
        if (self.build_root_marker) |value| self.allocator.free(value);
        if (self.landlock_allowed_paths) |value| self.allocator.free(value);
        if (self.landlock_retry_path) |value| self.allocator.free(value);
        if (self.ephemeral_venv_path) |value| self.allocator.free(value);
        if (self.test_patch_mode) |value| self.allocator.free(value);
        if (self.gold_patch_mode) |value| self.allocator.free(value);
        if (self.gold_patch_changed_files) |value| self.allocator.free(value);
        if (self.gold_patch_diff_stat) |value| self.allocator.free(value);
        self.allocator.free(self.reason);
        self.* = undefined;
    }
};

pub const Summary = struct {
    allocator: std.mem.Allocator,
    total_rows: usize,
    attempted: usize,
    verified: usize,
    invalid_environment: usize,
    failed: usize,
    false_positive: usize = 0,
    skipped_by_language: usize = 0,
    lattice_backend: LatticeBackend = .none,
    lattice_query_count: usize = 0,
    lattice_query_gip_opcode: gip_mapping.GipOpCode = .GIP_OP_LATTICE_QUERY,
    results: []ProofResult,

    pub fn deinit(self: *Summary) void {
        for (self.results) |*result| result.deinit();
        self.allocator.free(self.results);
        self.* = undefined;
    }

    pub fn truthDensityPerMille(self: Summary) u16 {
        if (self.total_rows == 0) return 0;
        return @intCast((@as(u64, self.verified) * 1000) / self.total_rows);
    }
};

pub fn runRowsFile(allocator: std.mem.Allocator, options: Options) !Summary {
    var file = try std.fs.cwd().openFile(options.rows_path, .{});
    defer file.close();
    var buffered = std.io.bufferedReader(file.reader());
    const reader = buffered.reader();

    var ranked = std.ArrayList(RankedInstance).init(allocator);
    defer {
        for (ranked.items) |*item| item.deinit();
        ranked.deinit();
    }

    var results = std.ArrayList(ProofResult).init(allocator);
    errdefer {
        for (results.items) |*result| result.deinit();
        results.deinit();
    }

    var total_rows: usize = 0;
    var attempted: usize = 0;
    var verified: usize = 0;
    var invalid_environment: usize = 0;
    var failed: usize = 0;
    var false_positive: usize = 0;
    var skipped_by_language: usize = 0;

    while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', bench_loader.MAX_SINGLE_INSTANCE_BYTES)) |line_raw| {
        defer allocator.free(line_raw);
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        total_rows += 1;

        var instance = parseInstanceLine(allocator, line) catch |err| {
            if (attempted >= options.limit) continue;
            attempted += 1;
            failed += 1;
            try results.append(try syntheticFailure(allocator, "parse_error", err));
            continue;
        };
        errdefer instance.deinit();

        try ranked.append(.{ .instance = instance });
    }

    const lattice_telemetry = if (options.enable_reprioritization)
        try reprioritizeInstances(allocator, ranked.items, options.cluster_seed, options.enable_gpu_lattice_query)
    else
        LatticeTelemetry{};

    for (ranked.items) |*ranked_instance| {
        if (attempted >= options.limit) break;
        if (options.focus_supported_languages and !isSupportedStrikeLanguage(ranked_instance.instance)) {
            skipped_by_language += 1;
            continue;
        }
        attempted += 1;
        const result = proveInstance(allocator, ranked_instance.instance, options, ranked_instance.distance) catch |err| try instanceFailure(allocator, ranked_instance.instance, err);
        if (result.status == .verified) verified += 1 else if (result.status == .invalid_environment) invalid_environment += 1 else if (result.status == .false_positive) false_positive += 1 else failed += 1;
        try results.append(result);
        if (attempted >= options.limit) break;
    }

    return .{
        .allocator = allocator,
        .total_rows = total_rows,
        .attempted = attempted,
        .verified = verified,
        .invalid_environment = invalid_environment,
        .failed = failed,
        .false_positive = false_positive,
        .skipped_by_language = skipped_by_language,
        .lattice_backend = lattice_telemetry.backend,
        .lattice_query_count = lattice_telemetry.rune_count,
        .lattice_query_gip_opcode = lattice_telemetry.gip_opcode,
        .results = try results.toOwnedSlice(),
    };
}

fn isSupportedStrikeLanguage(instance: Instance) bool {
    return switch (instance.repo_language) {
        .python, .javascript => true,
        .zig, .unknown => false,
    };
}

fn syntheticFailure(allocator: std.mem.Allocator, instance_id: []const u8, err: anyerror) !ProofResult {
    return .{
        .allocator = allocator,
        .instance_id = try allocator.dupe(u8, instance_id),
        .repo = try allocator.dupe(u8, "unknown"),
        .status = .invalid_environment,
        .gip_opcode = gipOpForStatus(.invalid_environment),
        .workspace_path = try allocator.dupe(u8, ""),
        .reason = try std.fmt.allocPrint(allocator, "failed to parse instance row: {s}", .{@errorName(err)}),
    };
}

fn instanceFailure(allocator: std.mem.Allocator, instance: Instance, err: anyerror) !ProofResult {
    return .{
        .allocator = allocator,
        .instance_id = try allocator.dupe(u8, instance.instance_id),
        .repo = try allocator.dupe(u8, instance.repo),
        .status = .invalid_environment,
        .gip_opcode = gipOpForStatus(.invalid_environment),
        .workspace_path = try allocator.dupe(u8, ""),
        .reason = try std.fmt.allocPrint(allocator, "native harness error: {s}", .{@errorName(err)}),
    };
}

const CloneSource = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    offline: bool,

    fn deinit(self: *CloneSource) void {
        self.allocator.free(self.url);
        self.* = undefined;
    }
};

fn resolveCloneSource(allocator: std.mem.Allocator, repo: []const u8, corpus_dir: ?[]const u8) !CloneSource {
    if (corpus_dir) |dir| {
        const mirror_path = try resolveLocalMirrorPath(allocator, dir, repo) orelse return error.OfflineMirrorMissing;
        defer allocator.free(mirror_path);
        return .{
            .allocator = allocator,
            .url = try fileUrlFromAbsolutePath(allocator, mirror_path),
            .offline = true,
        };
    }
    return .{
        .allocator = allocator,
        .url = try std.fmt.allocPrint(allocator, "https://github.com/{s}.git", .{repo}),
        .offline = false,
    };
}

fn resolveLocalMirrorPath(allocator: std.mem.Allocator, corpus_dir: []const u8, repo: []const u8) !?[]u8 {
    if (!isSafeRepoName(repo)) return error.InvalidRepoName;
    const leaf = std.fs.path.basename(repo);
    const owner_repo = try ownerRepoMirrorName(allocator, repo);
    defer allocator.free(owner_repo);
    const candidates = [_][]const u8{ leaf, repo, owner_repo };
    for (candidates) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ corpus_dir, candidate });
        defer allocator.free(path);
        if (dirExists(path)) return try std.fs.cwd().realpathAlloc(allocator, path);
    }
    return null;
}

fn ownerRepoMirrorName(allocator: std.mem.Allocator, repo: []const u8) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, repo, '/') orelse return allocator.dupe(u8, repo);
    return std.fmt.allocPrint(allocator, "{s}__{s}", .{ repo[0..slash], repo[slash + 1 ..] });
}

fn isSafeRepoName(repo: []const u8) bool {
    if (repo.len == 0 or std.mem.indexOf(u8, repo, "..") != null) return false;
    for (repo) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.') continue;
        return false;
    }
    return true;
}

fn dirExists(path: []const u8) bool {
    var dir = if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, .{})
    else
        std.fs.cwd().openDir(path, .{});
    if (dir) |*opened| {
        opened.close();
        return true;
    } else |_| {
        return false;
    }
}

fn fileUrlFromAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.ExpectedAbsolutePath;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("file://");
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(ch);
        } else {
            try out.writer().print("%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice();
}

pub fn proveInstance(allocator: std.mem.Allocator, instance: Instance, options: Options, reprioritization_distance: ?u16) !ProofResult {
    const workspace_path = try std.fs.path.join(allocator, &.{ options.workspace_root, instance.instance_id });
    errdefer allocator.free(workspace_path);

    var result = ProofResult{
        .allocator = allocator,
        .instance_id = try allocator.dupe(u8, instance.instance_id),
        .repo = try allocator.dupe(u8, instance.repo),
        .status = .pending,
        .gip_opcode = gipOpForStatus(.pending),
        .workspace_path = workspace_path,
        .reprioritization_distance = reprioritization_distance,
        .reason = try allocator.dupe(u8, "pending"),
    };
    errdefer result.deinit();

    if (instance.repo_language == .unknown) return finish(&result, .unsupported_language, "unsupported repo_language", options.cleanup);
    if (instance.fail_to_pass.len == 0) return finish(&result, .invalid_environment, "no fail_to_pass tests listed", options.cleanup);
    if (instance.pass_to_pass.len == 0) return finish(&result, .invalid_environment, "no pass_to_pass tests listed", options.cleanup);

    _ = std.fs.deleteTreeAbsolute(workspace_path) catch {};
    try std.fs.cwd().makePath(options.workspace_root);

    var clone_source = resolveCloneSource(allocator, instance.repo, options.corpus_dir) catch |err| switch (err) {
        error.OfflineMirrorMissing => {
            const reason = try std.fmt.allocPrint(allocator, "offline mirror not found for {s} under {s}", .{ instance.repo, options.corpus_dir orelse "" });
            defer allocator.free(reason);
            return finish(&result, .failed_clone, reason, options.cleanup);
        },
        else => return err,
    };
    defer clone_source.deinit();
    var clone = if (clone_source.offline) blk: {
        const clone_argv = [_][]const u8{ "git", "clone", "--recurse-submodules", "--shallow-submodules", clone_source.url, workspace_path };
        break :blk try runCapture(allocator, null, &clone_argv, options.max_output_bytes);
    } else blk: {
        const clone_argv = [_][]const u8{ "git", "clone", "--filter=blob:none", "--recurse-submodules", "--shallow-submodules", clone_source.url, workspace_path };
        break :blk try runCapture(allocator, null, &clone_argv, options.max_output_bytes);
    };
    defer clone.deinit(allocator);
    if (!clone.exitedOk()) return finish(&result, .failed_clone, commandDiagnostic(clone), options.cleanup);

    result.status = .cloned;
    result.gip_opcode = gipOpForStatus(.cloned);
    replaceReason(allocator, &result, "repository cloned") catch {};

    var checkout = try runCapture(allocator, workspace_path, &.{ "git", "checkout", "--force", instance.base_commit }, options.max_output_bytes);
    defer checkout.deinit(allocator);
    if (!checkout.exitedOk()) return finish(&result, .failed_checkout, commandDiagnostic(checkout), options.cleanup);

    if (instance.test_patch.len != 0) {
        var test_patch = try patcher.applyChecked(allocator, workspace_path, "ghost_swe_test.patch", instance.test_patch, options.max_output_bytes);
        defer test_patch.deinit();
        try recordPatchTelemetry(allocator, &result, .test_patch, test_patch);
        if (!test_patch.applied) return finish(&result, .failed_test_patch, test_patch.detail, options.cleanup);
    }

    if (instance.patch.len == 0) return finish(&result, .missing_patch, "dataset row has no gold patch", options.cleanup);

    var build_root = try bootstrap.resolveBuildRoot(allocator, workspace_path, if (instance.root_hint_path.len == 0) null else instance.root_hint_path);
    defer build_root.deinit();
    if (instance.repo_language == .javascript) {
        if (try javascriptWorkspaceRoot(allocator, workspace_path, build_root)) |override| {
            build_root.deinit();
            build_root = override;
        }
    }
    try setBuildRoot(allocator, &result, build_root);
    try setLandlockTelemetry(allocator, &result, build_root.root_path);

    const commit_year = resolveBaseCommitYear(allocator, workspace_path, instance.base_commit, options.max_output_bytes) catch null;

    var runtime = prepareRuntimeEnv(allocator, workspace_path, build_root.root_path, instance, options, commit_year) catch |err| {
        return finish(&result, .invalid_environment, @errorName(err), options.cleanup);
    };
    defer runtime.deinit();
    if (runtime.venv_path) |venv_path| result.ephemeral_venv_path = try allocator.dupe(u8, venv_path);
    result.preflight_dependency_install = runtime.preflight_dependency_install;

    while (true) {
        var base_fail = try runTestSet(allocator, &result, workspace_path, build_root.root_path, build_root.root_relative, runtime, instance, instance.fail_to_pass, options);
        defer base_fail.deinit(allocator);
        if (result.oracle_timeout) return finish(&result, .oracle_timeout, commandDiagnostic(base_fail), options.cleanup);
        if (base_fail.exitedOk()) return finish(&result, .false_positive, "fail_to_pass tests passed before patch; false positive discarded", options.cleanup);
        if (looksLikeEnvironmentFailure(base_fail.stderr) or looksLikeEnvironmentFailure(base_fail.stdout)) {
            const diagnostic = commandDiagnostic(base_fail);
            if (try bootstrapOrLogGap(allocator, &result, instance, runtime, options, diagnostic)) continue;
            return finish(&result, .invalid_environment, diagnostic, options.cleanup);
        }
        break;
    }
    result.reproduced_base_failure = true;
    result.status = .base_reproduced;
    result.gip_opcode = gipOpForStatus(.base_reproduced);
    replaceReason(allocator, &result, "base fail_to_pass reproduced") catch {};

    var patch = try patcher.applyChecked(allocator, workspace_path, "ghost_swe_gold.patch", instance.patch, options.max_output_bytes);
    defer patch.deinit();
    try recordPatchTelemetry(allocator, &result, .gold_patch, patch);
    if (!patch.applied) return finish(&result, .failed_gold_patch, patch.detail, options.cleanup);
    result.status = .patch_applied;
    result.gip_opcode = gipOpForStatus(.patch_applied);

    while (true) {
        var fail_after = try runTestSet(allocator, &result, workspace_path, build_root.root_path, build_root.root_relative, runtime, instance, instance.fail_to_pass, options);
        defer fail_after.deinit(allocator);
        if (result.oracle_timeout) return finish(&result, .oracle_timeout, commandDiagnostic(fail_after), options.cleanup);
        if (!fail_after.exitedOk()) {
            if (looksLikeEnvironmentFailure(fail_after.stderr) or looksLikeEnvironmentFailure(fail_after.stdout)) {
                const diagnostic = commandDiagnostic(fail_after);
                if (try bootstrapOrLogGap(allocator, &result, instance, runtime, options, diagnostic)) continue;
                return finish(&result, .invalid_environment, diagnostic, options.cleanup);
            }
            return finish(&result, .failed_fail_to_pass, commandDiagnostic(fail_after), options.cleanup);
        }
        break;
    }
    result.fail_to_pass_passed = true;

    while (true) {
        var pass_after = try runTestSet(allocator, &result, workspace_path, build_root.root_path, build_root.root_relative, runtime, instance, instance.pass_to_pass, options);
        defer pass_after.deinit(allocator);
        if (result.oracle_timeout) return finish(&result, .oracle_timeout, commandDiagnostic(pass_after), options.cleanup);
        if (!pass_after.exitedOk()) {
            if (looksLikeEnvironmentFailure(pass_after.stderr) or looksLikeEnvironmentFailure(pass_after.stdout)) {
                const diagnostic = commandDiagnostic(pass_after);
                if (try bootstrapOrLogGap(allocator, &result, instance, runtime, options, diagnostic)) continue;
                return finish(&result, .invalid_environment, diagnostic, options.cleanup);
            }
            return finish(&result, .failed_pass_to_pass, commandDiagnostic(pass_after), options.cleanup);
        }
        break;
    }
    result.pass_to_pass_passed = true;

    const rune = try distiller.distillVerifiedPatch(.{
        .instance_id = instance.instance_id,
        .repo = instance.repo,
        .base_commit = instance.base_commit,
        .patch = instance.patch,
        .fail_to_pass_count = instance.fail_to_pass.len,
        .pass_to_pass_count = instance.pass_to_pass.len,
        .semantic_class = .software_engineering,
    });
    try writeRune(allocator, options.knowledge_dir, rune);
    result.rune_written = true;
    result.status = .verified;
    result.gip_opcode = gipOpForStatus(.verified);
    replaceReason(allocator, &result, "verified by native fail_to_pass and pass_to_pass") catch {};

    if (options.cleanup) {
        if (!cleanupProofWorkspace(&result)) {
            result.cleanup_done = false;
            return finish(&result, .cleanup_failed, "failed to delete native SWE workspace", false);
        }
        result.cleanup_done = true;
    }
    return result;
}

fn bootstrapOrLogGap(
    allocator: std.mem.Allocator,
    result: *ProofResult,
    instance: Instance,
    runtime: RuntimeEnv,
    options: Options,
    diagnostic: []const u8,
) !bool {
    result.environment_attempts +|= 1;
    if (!options.enable_bootstrap or result.environment_attempts > options.max_environment_attempts) {
        const detail = if (result.reason.len != 0 and !std.mem.eql(u8, result.reason, "pending")) result.reason else "environment retry limit reached";
        try logEnvironmentGap(allocator, result, instance, options, diagnostic, detail);
        return false;
    }

    var fix = bootstrap.fixEnvironment(allocator, .{
        .workspace_path = result.build_root_path orelse result.workspace_path,
        .instance_id = instance.instance_id,
        .repo = instance.repo,
        .base_commit = instance.base_commit,
        .commit_year = runtime.commit_year,
        .repo_language = @tagName(instance.repo_language),
        .pip_exe = runtime.pip_exe,
        .sandbox_spec = options.sandbox_spec,
        .max_output_bytes = options.max_output_bytes,
    }, diagnostic) catch |err| {
        const detail = try std.fmt.allocPrint(allocator, "bootstrap failed: {s}", .{@errorName(err)});
        defer allocator.free(detail);
        try logEnvironmentGap(allocator, result, instance, options, diagnostic, detail);
        return false;
    };
    defer fix.deinit();

    if (vsa_vulkan.runtimeLogsEnabled()) {
        std.debug.print("[SWE] bootstrap attempt {d}: {s}: {s}\n", .{ result.environment_attempts, fix.status.name(), fix.detail });
    }
    try replaceReason(allocator, result, fix.detail);
    if (fix.status == .no_action) {
        try logEnvironmentGap(allocator, result, instance, options, diagnostic, fix.detail);
        return false;
    }
    return true;
}

fn logEnvironmentGap(
    allocator: std.mem.Allocator,
    result: *ProofResult,
    instance: Instance,
    options: Options,
    diagnostic: []const u8,
    fix_detail: []const u8,
) !void {
    if (result.gap_logged) return;
    try bootstrap.writeEnvironmentGap(allocator, options.knowledge_dir, .{
        .instance_id = instance.instance_id,
        .repo = instance.repo,
        .base_commit = instance.base_commit,
        .repo_language = @tagName(instance.repo_language),
        .attempts = result.environment_attempts,
        .reason = diagnostic,
        .fix_detail = fix_detail,
    });
    result.gap_logged = true;
}

fn finish(result: *ProofResult, status: ProofStatus, reason: []const u8, cleanup: bool) !ProofResult {
    result.status = status;
    result.gip_opcode = gipOpForStatus(status);
    try replaceReason(result.allocator, result, reason);
    if (cleanup and result.workspace_path.len != 0) {
        result.cleanup_done = cleanupProofWorkspace(result);
    }
    return result.*;
}

fn cleanupProofWorkspace(result: *const ProofResult) bool {
    if (result.ephemeral_venv_path) |venv_path| {
        std.fs.deleteTreeAbsolute(venv_path) catch {};
    }
    if (result.workspace_path.len == 0) return true;
    std.fs.deleteTreeAbsolute(result.workspace_path) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return false,
    };
    return true;
}

fn replaceReason(allocator: std.mem.Allocator, result: *ProofResult, reason: []const u8) !void {
    allocator.free(result.reason);
    const trimmed = std.mem.trim(u8, reason, " \t\r\n");
    result.reason = try allocator.dupe(u8, if (trimmed.len == 0) "no diagnostic" else trimmed[0..@min(trimmed.len, 2000)]);
}

fn setBuildRoot(allocator: std.mem.Allocator, result: *ProofResult, build_root: bootstrap.BuildRootResolution) !void {
    if (result.build_root_path) |value| allocator.free(value);
    if (result.build_root_relative) |value| allocator.free(value);
    if (result.build_root_marker) |value| allocator.free(value);
    result.build_root_path = try allocator.dupe(u8, build_root.root_path);
    result.build_root_relative = try allocator.dupe(u8, build_root.root_relative);
    result.build_root_marker = try allocator.dupe(u8, build_root.marker);
    result.build_root_candidates = build_root.candidates_considered;
    result.build_root_gip_opcode = build_root.gip_opcode;
}

fn setLandlockTelemetry(allocator: std.mem.Allocator, result: *ProofResult, build_root_path: []const u8) !void {
    if (result.landlock_allowed_paths) |value| allocator.free(value);
    var allowed = std.ArrayList(u8).init(allocator);
    errdefer allowed.deinit();
    try sandbox.renderAllowedPathsJson(allowed.writer(), allocator, build_root_path);
    result.landlock_allowed_paths = try allowed.toOwnedSlice();
    result.landlock_gip_opcode = .GIP_OP_LANDLOCK_STRICT;
}

fn javascriptWorkspaceRoot(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    current: bootstrap.BuildRootResolution,
) !?bootstrap.BuildRootResolution {
    if (std.mem.eql(u8, current.root_relative, ".")) return null;
    if (!fileExists(allocator, workspace_path, "package.json")) return null;
    if (!packageJsonHasScript(allocator, workspace_path, "test") and !looksLikeNodeMonorepo(allocator, workspace_path)) return null;
    return .{
        .allocator = allocator,
        .root_path = try allocator.dupe(u8, workspace_path),
        .root_relative = try allocator.dupe(u8, "."),
        .marker = try allocator.dupe(u8, "package.json"),
        .candidates_considered = current.candidates_considered,
    };
}

fn looksLikeNodeMonorepo(allocator: std.mem.Allocator, workspace_path: []const u8) bool {
    if (fileExists(allocator, workspace_path, "lerna.json") or
        fileExists(allocator, workspace_path, "nx.json") or
        fileExists(allocator, workspace_path, "pnpm-workspace.yaml") or
        fileExists(allocator, workspace_path, "rush.json"))
    {
        return true;
    }
    const path = std.fs.path.join(allocator, &.{ workspace_path, "package.json" }) catch return false;
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 512 * 1024) catch return false;
    defer allocator.free(bytes);
    return std.mem.indexOf(u8, bytes, "\"workspaces\"") != null;
}

const PatchSlot = enum { test_patch, gold_patch };

fn recordPatchTelemetry(allocator: std.mem.Allocator, result: *ProofResult, slot: PatchSlot, patch: patcher.PatchResult) !void {
    result.patch_integrity_gip_opcode = patch.gip_opcode;
    switch (slot) {
        .test_patch => {
            if (result.test_patch_mode) |value| allocator.free(value);
            result.test_patch_mode = try allocator.dupe(u8, patch.mode.name());
        },
        .gold_patch => {
            if (result.gold_patch_mode) |value| allocator.free(value);
            if (result.gold_patch_changed_files) |value| allocator.free(value);
            if (result.gold_patch_diff_stat) |value| allocator.free(value);
            result.gold_patch_mode = try allocator.dupe(u8, patch.mode.name());
            result.gold_patch_changed_files = try allocator.dupe(u8, std.mem.trim(u8, patch.changed_files, " \t\r\n"));
            result.gold_patch_diff_stat = try allocator.dupe(u8, std.mem.trim(u8, patch.diff_stat, " \t\r\n"));
        },
    }
}

fn resolveBaseCommitYear(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    base_commit: []const u8,
    max_output_bytes: usize,
) !?u16 {
    var result = try runCapture(allocator, workspace_path, &.{ "git", "show", "-s", "--format=%cI", base_commit }, max_output_bytes);
    defer result.deinit(allocator);
    if (!result.exitedOk()) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len < 4) return null;
    return std.fmt.parseInt(u16, trimmed[0..4], 10) catch null;
}

fn ensureAnsibleTmp(allocator: std.mem.Allocator) !void {
    const home = std.posix.getenv("HOME") orelse "/home/micah";
    const path = try std.fs.path.join(allocator, &.{ home, ".ansible", "tmp" });
    defer allocator.free(path);
    try std.fs.cwd().makePath(path);
}

fn prepareRuntimeEnv(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    build_root_path: []const u8,
    instance: Instance,
    options: Options,
    commit_year: ?u16,
) !RuntimeEnv {
    try ensureAnsibleTmp(allocator);
    if (instance.repo_language == .javascript) {
        var runtime = RuntimeEnv{
            .allocator = allocator,
            .python_exe = try allocator.dupe(u8, options.python_exe),
            .pip_exe = try allocator.dupe(u8, options.pip_exe),
            .commit_year = commit_year,
        };
        errdefer runtime.deinit();
        if (options.enable_preflight_npm) {
            runtime.preflight_dependency_install = preflightNpmInstall(allocator, build_root_path, options) catch |err| blk: {
                if (vsa_vulkan.runtimeLogsEnabled()) {
                    std.debug.print("[SWE] preflight npm install skipped after failure: {s}\n", .{@errorName(err)});
                }
                break :blk false;
            };
        }
        return runtime;
    }

    if (instance.repo_language != .python or !options.enable_ephemeral_venv) {
        return .{
            .allocator = allocator,
            .python_exe = try allocator.dupe(u8, options.python_exe),
            .pip_exe = try allocator.dupe(u8, options.pip_exe),
            .commit_year = commit_year,
        };
    }

    const venv_path = try std.fs.path.join(allocator, &.{ workspace_path, "temp_venv" });
    errdefer allocator.free(venv_path);
    var create_venv = try runCapture(allocator, workspace_path, &.{ options.python_exe, "-m", "venv", venv_path }, options.max_output_bytes);
    defer create_venv.deinit(allocator);
    if (!create_venv.exitedOk()) return error.EphemeralVenvCreateFailed;

    const python_exe = try std.fs.path.join(allocator, &.{ venv_path, "bin", "python" });
    errdefer allocator.free(python_exe);
    const pip_exe = try std.fs.path.join(allocator, &.{ venv_path, "bin", "pip" });
    errdefer allocator.free(pip_exe);

    var runtime = RuntimeEnv{
        .allocator = allocator,
        .python_exe = python_exe,
        .pip_exe = pip_exe,
        .venv_path = venv_path,
        .commit_year = commit_year,
    };
    errdefer runtime.deinit();

    if (options.enable_preflight_pip) {
        runtime.preflight_dependency_install = preflightPipInstall(allocator, build_root_path, runtime.pip_exe, options) catch |err| blk: {
            if (vsa_vulkan.runtimeLogsEnabled()) {
                std.debug.print("[SWE] preflight pip install skipped after failure: {s}\n", .{@errorName(err)});
            }
            break :blk false;
        };
    }
    return runtime;
}

fn preflightPipInstall(
    allocator: std.mem.Allocator,
    build_root_path: []const u8,
    pip_exe: []const u8,
    options: Options,
) !bool {
    const requirements = try existingRequirementsFiles(allocator, build_root_path);
    defer freeStringList(allocator, requirements);
    if (requirements.len == 0) return false;

    var preflight_spec = options.sandbox_spec;
    preflight_spec.network_disabled = false;
    preflight_spec.timeout_ms = @min(preflight_spec.timeout_ms, 60_000);
    var installed_any = false;
    for (requirements) |req_path| {
        if (try pipInstallRequirementsFile(allocator, build_root_path, pip_exe, req_path, preflight_spec, options.max_output_bytes)) {
            installed_any = true;
            continue;
        }
        if (try pipInstallRelaxedRequirementsFile(allocator, build_root_path, pip_exe, req_path, preflight_spec, options.max_output_bytes)) {
            installed_any = true;
        }
    }
    if (!installed_any) return error.PreflightPipInstallFailed;
    return true;
}

fn preflightNpmInstall(
    allocator: std.mem.Allocator,
    build_root_path: []const u8,
    options: Options,
) !bool {
    if (!fileExists(allocator, build_root_path, "package.json")) return false;
    var preflight_spec = options.sandbox_spec;
    preflight_spec.network_disabled = false;
    preflight_spec.timeout_ms = @min(preflight_spec.timeout_ms, 60_000);

    _ = try verifyNodeEngines(allocator, build_root_path, options.max_output_bytes);
    const command = if (fileExists(allocator, build_root_path, "package-lock.json")) "ci" else "install";
    var argv = try sandbox.buildLandlockRunArgv(allocator, preflight_spec, build_root_path, &.{ "npm", command });
    defer argv.deinit();
    var result = try runCapture(allocator, null, argv.argv.items, options.max_output_bytes);
    defer result.deinit(allocator);
    if (!result.exitedOk()) return error.PreflightNpmInstallFailed;

    const runner = detectNodeTestRunner(allocator, build_root_path);
    return try npmInstallLocalRunner(allocator, build_root_path, runner, preflight_spec, options.max_output_bytes);
}

fn npmInstallLocalRunner(
    allocator: std.mem.Allocator,
    build_root_path: []const u8,
    runner: []const u8,
    preflight_spec: sandbox.SandboxSpec,
    max_output_bytes: usize,
) !bool {
    if (!isSafeNpmRunner(runner)) return error.UnsafeNodeRunner;
    var argv = try sandbox.buildLandlockRunArgv(allocator, preflight_spec, build_root_path, &.{ "npm", "install", "--no-save", runner });
    defer argv.deinit();
    var result = try runCapture(allocator, null, argv.argv.items, max_output_bytes);
    defer result.deinit(allocator);
    return result.exitedOk();
}

fn verifyNodeEngines(
    allocator: std.mem.Allocator,
    build_root_path: []const u8,
    max_output_bytes: usize,
) !bool {
    var node = try runCapture(allocator, build_root_path, &.{ "node", "--version" }, max_output_bytes);
    defer node.deinit(allocator);
    if (!node.exitedOk()) return error.NodeUnavailable;
    return true;
}

fn pipInstallRequirementsFile(
    allocator: std.mem.Allocator,
    build_root_path: []const u8,
    pip_exe: []const u8,
    req_path: []const u8,
    preflight_spec: sandbox.SandboxSpec,
    max_output_bytes: usize,
) !bool {
    var argv = try sandbox.buildLandlockRunArgv(allocator, preflight_spec, build_root_path, &.{ pip_exe, "install", "-r", req_path });
    defer argv.deinit();
    var result = try runCapture(allocator, null, argv.argv.items, max_output_bytes);
    defer result.deinit(allocator);
    return result.exitedOk();
}

fn pipInstallRelaxedRequirementsFile(
    allocator: std.mem.Allocator,
    build_root_path: []const u8,
    pip_exe: []const u8,
    req_path: []const u8,
    preflight_spec: sandbox.SandboxSpec,
    max_output_bytes: usize,
) !bool {
    const packages = try relaxedRequirementsFromFile(allocator, req_path);
    defer freeStringList(allocator, packages);
    if (packages.len == 0) return false;

    var installed_any = false;
    const chunk_size: usize = 12;
    var idx: usize = 0;
    while (idx < packages.len) {
        const end = @min(idx + chunk_size, packages.len);
        const chunk = packages[idx..end];
        if (try pipInstallPackageList(allocator, build_root_path, pip_exe, chunk, preflight_spec, max_output_bytes)) {
            installed_any = true;
        } else {
            for (chunk) |package| {
                const single = [_][]const u8{package};
                if (try pipInstallPackageList(allocator, build_root_path, pip_exe, &single, preflight_spec, max_output_bytes)) {
                    installed_any = true;
                }
            }
        }
        idx = end;
    }
    return installed_any;
}

fn pipInstallPackageList(
    allocator: std.mem.Allocator,
    build_root_path: []const u8,
    pip_exe: []const u8,
    packages: []const []const u8,
    preflight_spec: sandbox.SandboxSpec,
    max_output_bytes: usize,
) !bool {
    var inner = std.ArrayList([]const u8).init(allocator);
    defer inner.deinit();
    try inner.append(pip_exe);
    try inner.append("install");
    for (packages) |package| try inner.append(package);

    var argv = try sandbox.buildLandlockRunArgv(allocator, preflight_spec, build_root_path, inner.items);
    defer argv.deinit();
    var result = try runCapture(allocator, null, argv.argv.items, max_output_bytes);
    defer result.deinit(allocator);
    return result.exitedOk();
}

fn existingRequirementsFiles(allocator: std.mem.Allocator, build_root_path: []const u8) ![][]u8 {
    const candidates = [_][]const u8{
        "requirements.txt",
        "requirements-dev.txt",
        "requirements/test.txt",
        "requirements/tests.txt",
        "test-requirements.txt",
        "misc/requirements/requirements-tests.txt",
        "misc/requirements/requirements-pyqt.txt",
    };
    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit();
    }
    for (candidates) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ build_root_path, candidate });
        errdefer allocator.free(path);
        var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        file.close();
        try appendUniquePath(allocator, &out, path);
    }
    return out.toOwnedSlice();
}

fn appendUniquePath(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), path: []u8) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            allocator.free(path);
            return;
        }
    }
    try out.append(path);
}

fn fileExists(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ root, relative }) catch return false;
    defer allocator.free(path);
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn relaxedRequirementsFromFile(allocator: std.mem.Allocator, req_path: []const u8) ![][]u8 {
    const contents = try std.fs.cwd().readFileAlloc(allocator, req_path, DEFAULT_MAX_OUTPUT_BYTES);
    defer allocator.free(contents);

    var packages = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (packages.items) |package| allocator.free(package);
        packages.deinit();
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const package_name = try relaxedRequirementName(allocator, line) orelse continue;
        errdefer allocator.free(package_name);
        var duplicate = false;
        for (packages.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, package_name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            allocator.free(package_name);
            continue;
        }
        try packages.append(package_name);
    }
    return packages.toOwnedSlice();
}

fn relaxedRequirementName(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    const uncommented = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r\n");
    if (uncommented.len == 0 or uncommented[0] == '-') return null;
    if (std.mem.startsWith(u8, uncommented, "git+") or std.mem.indexOf(u8, uncommented, "://") != null) return null;
    var end: usize = 0;
    while (end < uncommented.len) : (end += 1) {
        const ch = uncommented[end];
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') continue;
        break;
    }
    const name = uncommented[0..end];
    if (!isSafeRequirementName(name)) return null;
    return try allocator.dupe(u8, name);
}

fn isSafeRequirementName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') continue;
        return false;
    }
    return true;
}

fn writeRune(allocator: std.mem.Allocator, knowledge_dir: []const u8, rune: distiller.DistilledRune) !void {
    try std.fs.cwd().makePath(knowledge_dir);
    const path = try std.fs.path.join(allocator, &.{ knowledge_dir, "verified_runes.gkpack" });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try distiller.writeGkpackRecord(file.writer(), rune);
}

fn runTestSet(
    allocator: std.mem.Allocator,
    result: *ProofResult,
    workspace_path: []const u8,
    build_root_path: []const u8,
    build_root_relative: []const u8,
    runtime: RuntimeEnv,
    instance: Instance,
    tests: [][]u8,
    options: Options,
) !CommandResult {
    if (instance.repo_language == .unknown) {
        return error.UnsupportedLanguage;
    }

    var inner = std.ArrayList([]const u8).init(allocator);
    defer inner.deinit();
    var owned_args = std.ArrayList([]u8).init(allocator);
    defer {
        for (owned_args.items) |arg| allocator.free(arg);
        owned_args.deinit();
    }
    switch (instance.repo_language) {
        .python => {
            try appendPythonPathEnv(allocator, &inner, &owned_args, build_root_path);
            try inner.append(runtime.python_exe);
            try inner.append("-m");
            try inner.append("pytest");
            if (tests.len == 0) {
                for (instance.selected_test_files) |file| try appendRebasedSelector(allocator, &inner, &owned_args, workspace_path, build_root_path, build_root_relative, file);
            } else {
                for (tests) |test_name| try appendRebasedSelector(allocator, &inner, &owned_args, workspace_path, build_root_path, build_root_relative, test_name);
            }
        },
        .javascript => {
            if (packageJsonHasScript(allocator, build_root_path, "test")) {
                try inner.append("npm");
                try inner.append("test");
                try inner.append("--");
            } else {
                try appendLocalNodeRunner(allocator, &inner, &owned_args, build_root_path, detectNodeTestRunner(allocator, build_root_path));
            }
            if (tests.len == 0) {
                for (instance.selected_test_files) |file| try appendRebasedSelector(allocator, &inner, &owned_args, workspace_path, build_root_path, build_root_relative, file);
            } else {
                for (tests) |test_name| try appendRebasedSelector(allocator, &inner, &owned_args, workspace_path, build_root_path, build_root_relative, test_name);
            }
        },
        .zig => {
            try inner.append("zig");
            try inner.append("test");
            if (instance.selected_test_files.len != 0) {
                try appendRebasedSelector(allocator, &inner, &owned_args, workspace_path, build_root_path, build_root_relative, instance.selected_test_files[0]);
            } else {
                try inner.append(".");
            }
        },
        .unknown => unreachable,
    }

    var extra_rw_paths = std.ArrayList([]const u8).init(allocator);
    defer extra_rw_paths.deinit();

    var attempts: u8 = 0;
    while (true) {
        var current = try runLeashedCommand(allocator, build_root_path, inner.items, options, extra_rw_paths.items);
        errdefer current.deinit(allocator);
        if (isOracleTimeout(current)) {
            result.oracle_timeout = true;
            return current;
        }
        if (current.exitedOk()) return current;

        const diagnostic = commandDiagnostic(current);
        if (try safeScratchpadFromDeniedOutput(allocator, diagnostic)) |path| {
            defer allocator.free(path);
            if (result.landlock_retry_path == null) {
                result.landlock_retry_path = try allocator.dupe(u8, path);
                try extra_rw_paths.append(result.landlock_retry_path.?);
                current.deinit(allocator);
                continue;
            }
        }

        if (attempts < options.max_repair_attempts) {
            if (try repairEnvironmentFromDiagnostic(allocator, result, build_root_path, runtime, instance.repo_language, options, diagnostic)) {
                attempts += 1;
                current.deinit(allocator);
                continue;
            }
        }
        return current;
    }
}

fn isOracleTimeout(result: CommandResult) bool {
    if (std.mem.indexOf(u8, result.stderr, sandbox.ORACLE_TIMEOUT_MARKER) != null) return true;
    return switch (result.term) {
        .Exited => |code| code == sandbox.ORACLE_TIMEOUT_EXIT_CODE,
        else => false,
    };
}

fn runLeashedCommand(
    allocator: std.mem.Allocator,
    build_root_path: []const u8,
    inner_argv: []const []const u8,
    options: Options,
    extra_rw_paths: []const []const u8,
) !CommandResult {
    var sandbox_argv = try sandbox.buildLandlockRunArgvWithExtra(allocator, options.sandbox_spec, build_root_path, inner_argv, extra_rw_paths);
    defer sandbox_argv.deinit();
    return runCapture(allocator, null, sandbox_argv.argv.items, options.max_output_bytes);
}

fn repairEnvironmentFromDiagnostic(
    allocator: std.mem.Allocator,
    result: *ProofResult,
    build_root_path: []const u8,
    runtime: RuntimeEnv,
    language: Language,
    options: Options,
    diagnostic: []const u8,
) !bool {
    const package = try repairPackageFromDiagnostic(allocator, language, diagnostic) orelse return false;
    defer allocator.free(package);
    if (!isSafeRepairPackage(package)) return false;

    result.repair_attempts +|= 1;
    result.gip_opcode = .GIP_OP_REPAIR_ENV;
    if (vsa_vulkan.runtimeLogsEnabled()) {
        std.debug.print("[SWE] repair env 0x8B: {s}\n", .{package});
    }

    const repair_argv = switch (language) {
        .python => &[_][]const u8{ runtime.pip_exe, "install", package },
        .javascript => &[_][]const u8{ "npm", "install", "--no-save", package },
        else => return false,
    };
    var sandbox_argv = try sandbox.buildLandlockRunArgv(allocator, options.sandbox_spec, build_root_path, repair_argv);
    defer sandbox_argv.deinit();
    var repair = try runCapture(allocator, null, sandbox_argv.argv.items, options.max_output_bytes);
    defer repair.deinit(allocator);
    return repair.exitedOk();
}

fn repairPackageFromDiagnostic(allocator: std.mem.Allocator, language: Language, diagnostic: []const u8) !?[]u8 {
    return switch (language) {
        .python => blk: {
            const raw = extractBetween(diagnostic, "ModuleNotFoundError: No module named '", "'") orelse break :blk null;
            break :blk try allocator.dupe(u8, pythonRepairPackage(raw));
        },
        .javascript => blk: {
            if (extractBetween(diagnostic, "Cannot find module '", "'")) |module| {
                break :blk try allocator.dupe(u8, module);
            }
            if (extractBetween(diagnostic, "npm error Missing script: \"", "\"")) |script| {
                break :blk try allocator.dupe(u8, script);
            }
            break :blk null;
        },
        else => null,
    };
}

fn extractBetween(text: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, prefix) orelse return null;
    const value_start = start + prefix.len;
    const end_rel = std.mem.indexOf(u8, text[value_start..], suffix) orelse return null;
    return text[value_start .. value_start + end_rel];
}

fn pythonRepairPackage(module: []const u8) []const u8 {
    if (std.mem.eql(u8, module, "yaml")) return "PyYAML";
    return module;
}

fn isSafeRepairPackage(package: []const u8) bool {
    if (package.len == 0 or package.len > 128) return false;
    for (package) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/' or ch == '@') continue;
        return false;
    }
    return true;
}

fn appendRebasedSelector(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]u8),
    workspace_path: []const u8,
    build_root_path: []const u8,
    build_root_relative: []const u8,
    selector: []const u8,
) !void {
    const normalized = try patcher.normalizeTestSelector(allocator, selector);
    defer allocator.free(normalized);
    const adjusted = try selectorRelativeToBuildRoot(allocator, workspace_path, build_root_path, build_root_relative, normalized);
    errdefer allocator.free(adjusted);
    try owned_args.append(adjusted);
    try argv.append(adjusted);
}

fn appendPythonPathEnv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]u8),
    build_root_path: []const u8,
) !void {
    try argv.append("env");
    const py_path = if (std.posix.getenv("PYTHONPATH")) |existing|
        try std.fmt.allocPrint(allocator, "PYTHONPATH={s}:{s}", .{ existing, build_root_path })
    else
        try std.fmt.allocPrint(allocator, "PYTHONPATH={s}", .{build_root_path});
    errdefer allocator.free(py_path);
    try owned_args.append(py_path);
    try argv.append(py_path);
}

fn appendLocalNodeRunner(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]u8),
    build_root_path: []const u8,
    runner: []const u8,
) !void {
    if (!isSafeNpmRunner(runner)) return error.UnsafeNodeRunner;
    const local = try std.fs.path.join(allocator, &.{ build_root_path, "node_modules", ".bin", runner });
    errdefer allocator.free(local);
    try owned_args.append(local);
    try argv.append(local);
}

fn selectorRelativeToBuildRoot(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    build_root_path: []const u8,
    build_root_relative: []const u8,
    selector: []const u8,
) ![]u8 {
    if (build_root_relative.len == 0 or std.mem.eql(u8, build_root_relative, ".")) return allocator.dupe(u8, selector);

    const selector_end = std.mem.indexOf(u8, selector, "::") orelse selector.len;
    const path_part = selector[0..selector_end];
    const suffix = selector[selector_end..];
    if (std.mem.eql(u8, path_part, build_root_relative)) {
        return std.fmt.allocPrint(allocator, ".{s}", .{suffix});
    }
    if (std.mem.startsWith(u8, path_part, build_root_relative) and path_part.len > build_root_relative.len and path_part[build_root_relative.len] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ path_part[build_root_relative.len + 1 ..], suffix });
    }
    if (try resolveSelectorPhysicalPath(allocator, workspace_path, build_root_path, build_root_relative, path_part)) |physical| {
        defer allocator.free(physical);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ physical, suffix });
    }
    return allocator.dupe(u8, selector);
}

fn resolveSelectorPhysicalPath(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    build_root_path: []const u8,
    build_root_relative: []const u8,
    path_part: []const u8,
) !?[]u8 {
    if (path_part.len == 0 or std.mem.indexOf(u8, path_part, "..") != null) return null;

    if (std.fs.path.isAbsolute(path_part) and pathExists(path_part)) {
        return try allocator.dupe(u8, path_part);
    }

    const build_candidate = try std.fs.path.join(allocator, &.{ build_root_path, path_part });
    defer allocator.free(build_candidate);
    if (pathExists(build_candidate)) return try allocator.dupe(u8, path_part);

    const workspace_candidate = try std.fs.path.join(allocator, &.{ workspace_path, path_part });
    defer allocator.free(workspace_candidate);
    if (pathExists(workspace_candidate)) return try allocator.dupe(u8, workspace_candidate);

    if (build_root_relative.len != 0 and !std.mem.eql(u8, build_root_relative, ".")) {
        var rel = build_root_relative;
        while (rel.len != 0 and !std.mem.eql(u8, rel, ".")) {
            if (std.mem.startsWith(u8, path_part, rel) and path_part.len > rel.len and path_part[rel.len] == '/') {
                const stripped = path_part[rel.len + 1 ..];
                const stripped_candidate = try std.fs.path.join(allocator, &.{ build_root_path, stripped });
                defer allocator.free(stripped_candidate);
                if (pathExists(stripped_candidate)) return try allocator.dupe(u8, stripped);
            }
            rel = std.fs.path.dirname(rel) orelse break;
        }
    }

    return try findSelectorByTail(allocator, workspace_path, path_part);
}

fn findSelectorByTail(allocator: std.mem.Allocator, workspace_path: []const u8, path_part: []const u8) !?[]u8 {
    const base = std.fs.path.basename(path_part);
    if (base.len == 0) return null;
    var root = std.fs.openDirAbsolute(workspace_path, .{ .iterate = true }) catch return null;
    defer root.close();
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (pathHasSkippedSelectorSegment(entry.path)) continue;
        if (!std.mem.eql(u8, entry.basename, base)) continue;
        if (!std.mem.endsWith(u8, entry.path, path_part) and !selectorTailMatches(entry.path, path_part)) continue;
        const abs = try std.fs.path.join(allocator, &.{ workspace_path, entry.path });
        return abs;
    }
    return null;
}

fn pathHasSkippedSelectorSegment(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".git") or
            std.mem.eql(u8, part, ".zig-cache") or
            std.mem.eql(u8, part, "zig-out") or
            std.mem.eql(u8, part, "node_modules") or
            std.mem.eql(u8, part, "temp_venv") or
            std.mem.eql(u8, part, "__pycache__"))
        {
            return true;
        }
    }
    return false;
}

fn selectorTailMatches(candidate: []const u8, selector: []const u8) bool {
    var wanted = selector;
    while (wanted.len != 0) {
        if (std.mem.endsWith(u8, candidate, wanted)) return true;
        const slash = std.mem.indexOfScalar(u8, wanted, '/') orelse break;
        wanted = wanted[slash + 1 ..];
    }
    return false;
}

fn pathExists(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn packageJsonHasScript(allocator: std.mem.Allocator, build_root_path: []const u8, script_name: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ build_root_path, "package.json" }) catch return false;
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 512 * 1024) catch return false;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const scripts = parsed.value.object.get("scripts") orelse return false;
    if (scripts != .object) return false;
    const script = scripts.object.get(script_name) orelse return false;
    return script == .string and std.mem.trim(u8, script.string, " \t\r\n").len != 0;
}

fn detectNodeTestRunner(allocator: std.mem.Allocator, build_root_path: []const u8) []const u8 {
    const path = std.fs.path.join(allocator, &.{ build_root_path, "package.json" }) catch return "jest";
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 512 * 1024) catch return "jest";
    defer allocator.free(bytes);
    if (std.mem.indexOf(u8, bytes, "\"vitest\"") != null) return "vitest";
    if (std.mem.indexOf(u8, bytes, "\"mocha\"") != null) return "mocha";
    if (std.mem.indexOf(u8, bytes, "\"ava\"") != null) return "ava";
    if (std.mem.indexOf(u8, bytes, "\"jest\"") != null) return "jest";
    return "jest";
}

fn isSafeNpmRunner(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') continue;
        return false;
    }
    return true;
}

fn runCapture(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    argv: []const []const u8,
    max_output_bytes: usize,
) !CommandResult {
    try bench_loader.ensureNoDockerArgv(argv);
    const child = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = max_output_bytes,
    });
    return .{ .term = child.term, .stdout = child.stdout, .stderr = child.stderr };
}

fn commandDiagnostic(result: CommandResult) []const u8 {
    if (result.stderr.len != 0) return result.stderr;
    if (result.stdout.len != 0) return result.stdout;
    return "command failed without stdout or stderr";
}

fn looksLikeEnvironmentFailure(text: []const u8) bool {
    const needles = [_][]const u8{
        "command not found",
        "No such file or directory",
        "Cannot find module",
        "Could not read package.json",
        "ModuleNotFoundError",
        "ImportError",
        "No module named",
        "npm ERR!",
        "npm error enoent",
        "missing script",
        "pytest: not found",
        "Missing required plugins",
        "PytestRemovedIn9Warning",
        "found no collectors",
        "Failed to connect to bus",
        "No medium found",
        "Permission denied",
        "Read-only file system",
        "ProtectHome",
        "missing dependency",
        "status=200",
    };
    for (needles) |needle| {
        if (indexOfIgnoreCase(text, needle) != null) return true;
    }
    return false;
}

fn safeScratchpadFromDeniedOutput(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (!containsIgnoreCase(text, "Permission denied") and !containsIgnoreCase(text, "EACCES")) return null;
    const prefixes = [_][]const u8{ "/tmp/", "/var/tmp/" };
    for (prefixes) |prefix| {
        if (std.mem.indexOf(u8, text, prefix)) |start| {
            var end = start;
            while (end < text.len and !std.ascii.isWhitespace(text[end]) and text[end] != '\'' and text[end] != '"' and text[end] != ':' and text[end] != ')') : (end += 1) {}
            const raw = std.mem.trimRight(u8, text[start..end], ".,;");
            if (raw.len <= prefix.len) continue;
            return try scratchpadAnchor(allocator, raw);
        }
    }
    return null;
}

fn scratchpadAnchor(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "/tmp/")) {
        var it = std.mem.splitScalar(u8, path["/tmp/".len..], '/');
        const first = it.next() orelse return allocator.dupe(u8, "/tmp");
        if (first.len == 0) return allocator.dupe(u8, "/tmp");
        return std.fmt.allocPrint(allocator, "/tmp/{s}", .{first});
    }
    if (std.mem.startsWith(u8, path, "/var/tmp/")) {
        var it = std.mem.splitScalar(u8, path["/var/tmp/".len..], '/');
        const first = it.next() orelse return allocator.dupe(u8, "/var/tmp");
        if (first.len == 0) return allocator.dupe(u8, "/var/tmp");
        return std.fmt.allocPrint(allocator, "/var/tmp/{s}", .{first});
    }
    return error.UnsafeScratchpad;
}

pub fn parseInstanceLine(allocator: std.mem.Allocator, line: []const u8) !Instance {
    if (line.len > bench_loader.MAX_SINGLE_INSTANCE_BYTES) return error.InstanceTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInstanceJson;
    const obj = parsed.value.object;

    const language_text = getString(obj, "repo_language") orelse "";
    const fail_to_pass = try parseStringListField(allocator, obj, "fail_to_pass");
    errdefer freeStringList(allocator, fail_to_pass);
    const pass_to_pass = try parseStringListField(allocator, obj, "pass_to_pass");
    errdefer freeStringList(allocator, pass_to_pass);
    const selected_test_files = try parseStringListField(allocator, obj, "selected_test_files_to_run");
    errdefer freeStringList(allocator, selected_test_files);
    const interface_text = try dupeOptionalString(allocator, obj, "interface");
    errdefer allocator.free(interface_text);
    const root_hint_path = try deriveRootHintPath(allocator, obj, interface_text, selected_test_files, fail_to_pass);
    errdefer allocator.free(root_hint_path);

    return .{
        .allocator = allocator,
        .instance_id = try dupeRequiredString(allocator, obj, "instance_id"),
        .repo = try dupeRequiredString(allocator, obj, "repo"),
        .base_commit = try dupeRequiredString(allocator, obj, "base_commit"),
        .repo_language = Language.fromText(language_text),
        .problem_statement = try dupeRequiredString(allocator, obj, "problem_statement"),
        .interface_text = interface_text,
        .root_hint_path = root_hint_path,
        .patch = try dupeOptionalString(allocator, obj, "patch"),
        .test_patch = try dupeOptionalString(allocator, obj, "test_patch"),
        .fail_to_pass = fail_to_pass,
        .pass_to_pass = pass_to_pass,
        .selected_test_files = selected_test_files,
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn dupeRequiredString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    return try allocator.dupe(u8, getString(obj, key) orelse return error.MissingRequiredField);
}

fn dupeOptionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    return try allocator.dupe(u8, getString(obj, key) orelse "");
}

fn deriveRootHintPath(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    interface_text: []const u8,
    selected_test_files: [][]u8,
    fail_to_pass: [][]u8,
) ![]u8 {
    const direct_keys = [_][]const u8{ "file_path", "file", "path" };
    for (direct_keys) |key| {
        if (getString(obj, key)) |value| {
            if (try cleanMetadataPath(allocator, value)) |path| return path;
        }
    }
    if (try extractInterfacePath(allocator, interface_text)) |path| return path;
    for (selected_test_files) |file| {
        if (try cleanMetadataPath(allocator, file)) |path| return path;
    }
    for (fail_to_pass) |selector| {
        if (try cleanMetadataPath(allocator, selector)) |path| return path;
    }
    return allocator.dupe(u8, "");
}

fn extractInterfacePath(allocator: std.mem.Allocator, interface_text: []const u8) !?[]u8 {
    const path_marker = indexOfIgnoreCase(interface_text, "Path:") orelse
        (indexOfIgnoreCase(interface_text, "Location:") orelse return null);
    const marker_len: usize = if (std.ascii.eqlIgnoreCase(interface_text[path_marker..@min(interface_text.len, path_marker + "Path:".len)], "Path:")) "Path:".len else "Location:".len;
    const after = interface_text[path_marker + marker_len ..];
    const line_end = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    var line = std.mem.trim(u8, after[0..line_end], " \t\r\n\"'`");
    if (std.mem.indexOfScalar(u8, line, ',')) |comma| line = line[0..comma];
    return cleanMetadataPath(allocator, line);
}

fn cleanMetadataPath(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n\"'`");
    if (text.len == 0 or std.fs.path.isAbsolute(text)) return null;
    if (std.mem.indexOf(u8, text, "..") != null) return null;
    if (std.mem.indexOf(u8, text, " | ")) |pipe| text = std.mem.trim(u8, text[pipe + 3 ..], " \t\r\n\"'`");
    if (std.mem.indexOf(u8, text, "::")) |selector| text = text[0..selector];
    if (std.mem.indexOfAny(u8, text, " \t\r\n")) |space| text = text[0..space];
    text = std.mem.trim(u8, text, " \t\r\n\"'`.,;:)");
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '/') == null) return null;
    return try allocator.dupe(u8, text);
}

fn parseStringListField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![][]u8 {
    const value = obj.get(key) orelse return allocator.alloc([]u8, 0);
    return switch (value) {
        .array => |array| parseJsonArrayList(allocator, array.items),
        .string => |text| parseListText(allocator, text),
        else => error.InvalidListField,
    };
}

fn parseJsonArrayList(allocator: std.mem.Allocator, values: []const std.json.Value) ![][]u8 {
    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }
    for (values) |value| {
        if (value != .string) return error.InvalidListField;
        try out.append(try allocator.dupe(u8, value.string));
    }
    return out.toOwnedSlice();
}

fn parseListText(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch null;
    if (parsed) |*json| {
        defer json.deinit();
        if (json.value == .array) return parseJsonArrayList(allocator, json.value.array.items);
    }
    return parseQuotedListFallback(allocator, text);
}

fn parseQuotedListFallback(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }

    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        const quote = text[idx];
        if (quote != '\'' and quote != '"') continue;
        idx += 1;
        var item = std.ArrayList(u8).init(allocator);
        errdefer item.deinit();
        while (idx < text.len) : (idx += 1) {
            const ch = text[idx];
            if (ch == '\\' and idx + 1 < text.len) {
                idx += 1;
                try item.append(text[idx]);
                continue;
            }
            if (ch == quote) break;
            try item.append(ch);
        }
        try out.append(try item.toOwnedSlice());
    }
    return out.toOwnedSlice();
}

fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

test "relaxed requirements parser extracts safe package names" {
    const allocator = std.testing.allocator;
    const pinned = (try relaxedRequirementName(allocator, "PyYAML==5.4.1 ; python_version<'3.13' # old pin")).?;
    defer allocator.free(pinned);
    try std.testing.expectEqualStrings("PyYAML", pinned);

    const extras = (try relaxedRequirementName(allocator, "requests[security]>=2")).?;
    defer allocator.free(extras);
    try std.testing.expectEqualStrings("requests", extras);

    try std.testing.expect((try relaxedRequirementName(allocator, "-r nested.txt")) == null);
    try std.testing.expect((try relaxedRequirementName(allocator, "git+https://example.invalid/pkg.git")) == null);
}

fn reprioritizeInstances(
    allocator: std.mem.Allocator,
    items: []RankedInstance,
    seed_hint: ?[]const u8,
    enable_gpu_lattice_query: bool,
) !LatticeTelemetry {
    if (items.len <= 1) return .{};
    const hint = seed_hint orelse return .{};
    if (hint.len == 0) return .{};

    const seed_index = findClusterSeed(items, hint) orelse 0;
    const seed_rune = statementHypervector(items[seed_index].instance.problem_statement);
    const query_words = gpu_lattice.wordsFromU64Lanes(&seed_rune.lanes);

    const runes = try allocator.alloc(gpu_lattice.GreRune, items.len);
    defer allocator.free(runes);
    for (items, 0..) |item, idx| {
        const vector = statementHypervector(item.instance.problem_statement);
        runes[idx] = gpu_lattice.runeFromU64Lanes(@intCast(idx), 0, &vector.lanes);
    }

    const distances = try allocator.alloc(u32, items.len);
    defer allocator.free(distances);

    var backend: LatticeBackend = .cpu;
    if (enable_gpu_lattice_query and gpu_lattice.stageGate(items.len).usesGpu()) {
        if (try dispatchVulkanLatticeQuery(allocator, query_words, runes, distances)) {
            backend = .vulkan;
        } else if (vsa_vulkan.runtimeLogsEnabled()) {
            std.debug.print("[SWE] LATTICE_QUERY Vulkan dispatch unavailable; using CPU Hamming fallback.\n", .{});
        }
    }
    if (backend == .cpu) try gpu_lattice.hammingSearchCpu(query_words, runes, distances);

    for (items, 0..) |*item, idx| {
        item.distance = @intCast(@min(distances[idx], std.math.maxInt(u16)));
    }
    std.mem.sort(RankedInstance, items, {}, rankedInstanceLessThan);
    return .{ .backend = backend, .rune_count = items.len };
}

fn dispatchVulkanLatticeQuery(
    allocator: std.mem.Allocator,
    query_words: [gpu_lattice.VECTOR_WORDS]u32,
    runes: []const gpu_lattice.GreRune,
    out: []u32,
) !bool {
    if (out.len < runes.len) return error.OutputTooSmall;

    var owns_runtime = false;
    const engine = vsa_vulkan.getEngine() orelse blk: {
        const initialized = vsa_vulkan.initRuntime(allocator) catch return false;
        owns_runtime = true;
        break :blk initialized;
    };
    defer if (owns_runtime) vsa_vulkan.deinitRuntime();

    const distances = engine.dispatchLatticeQuery(query_words, runes) catch return false;
    if (distances.len != runes.len) return false;
    std.mem.copyForwards(u32, out[0..runes.len], distances);
    return true;
}

fn findClusterSeed(items: []const RankedInstance, hint: []const u8) ?usize {
    for (items, 0..) |item, idx| {
        if (containsIgnoreCase(item.instance.instance_id, hint) or
            containsIgnoreCase(item.instance.repo, hint) or
            containsIgnoreCase(item.instance.root_hint_path, hint) or
            containsIgnoreCase(item.instance.problem_statement, hint))
        {
            return idx;
        }
    }
    return null;
}

fn rankedInstanceLessThan(_: void, a: RankedInstance, b: RankedInstance) bool {
    const ad = a.distance orelse std.math.maxInt(u16);
    const bd = b.distance orelse std.math.maxInt(u16);
    if (ad != bd) return ad < bd;
    if (!std.mem.eql(u8, a.instance.repo, b.instance.repo)) return std.mem.lessThan(u8, a.instance.repo, b.instance.repo);
    return std.mem.lessThan(u8, a.instance.instance_id, b.instance.instance_id);
}

fn statementHypervector(text: []const u8) hypervector.HyperVector {
    var out = hypervector.zero();
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    var in_token = false;
    var tokens: usize = 0;

    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
            in_token = true;
            hash ^= std.ascii.toLower(ch);
            hash *%= 0x0000_0100_0000_01b3;
            continue;
        }
        if (in_token) {
            out = hypervector.bind(out, hypervector.deterministic(hash));
            tokens += 1;
            hash = 0xcbf2_9ce4_8422_2325;
            in_token = false;
        }
    }
    if (in_token) {
        out = hypervector.bind(out, hypervector.deterministic(hash));
        tokens += 1;
    }
    if (tokens == 0) return hypervector.deterministic(0);
    return out;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
}

pub fn renderSummaryJson(writer: anytype, summary: Summary) !void {
    try writer.print(
        "{{\"totalRows\":{d},\"attempted\":{d},\"verified\":{d},\"invalidEnvironment\":{d},\"failed\":{d},\"falsePositive\":{d},\"skippedByLanguage\":{d},\"truthDensityPerMille\":{d},\"latticeBackend\":",
        .{ summary.total_rows, summary.attempted, summary.verified, summary.invalid_environment, summary.failed, summary.false_positive, summary.skipped_by_language, summary.truthDensityPerMille() },
    );
    try std.json.stringify(summary.lattice_backend.name(), .{}, writer);
    try writer.print(",\"latticeQueryCount\":{d},\"latticeQueryGipOpCode\":", .{summary.lattice_query_count});
    try std.json.stringify(@tagName(summary.lattice_query_gip_opcode), .{}, writer);
    try writer.writeAll(",\"results\":[");
    for (summary.results, 0..) |result, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"instanceId\":");
        try std.json.stringify(result.instance_id, .{}, writer);
        try writer.writeAll(",\"repo\":");
        try std.json.stringify(result.repo, .{}, writer);
        try writer.writeAll(",\"status\":");
        try std.json.stringify(result.status.name(), .{}, writer);
        try writer.writeAll(",\"gipOpCode\":");
        try std.json.stringify(@tagName(result.gip_opcode), .{}, writer);
        try writer.writeAll(",\"buildRootGipOpCode\":");
        try std.json.stringify(@tagName(result.build_root_gip_opcode), .{}, writer);
        try writer.writeAll(",\"buildRootPath\":");
        try std.json.stringify(result.build_root_path orelse "", .{}, writer);
        try writer.writeAll(",\"buildRootRelative\":");
        try std.json.stringify(result.build_root_relative orelse "", .{}, writer);
        try writer.writeAll(",\"buildRootMarker\":");
        try std.json.stringify(result.build_root_marker orelse "", .{}, writer);
        try writer.print(",\"buildRootCandidates\":{d}", .{result.build_root_candidates});
        try writer.writeAll(",\"landlockGipOpCode\":");
        try std.json.stringify(@tagName(result.landlock_gip_opcode), .{}, writer);
        try writer.writeAll(",\"landlockAllowedPaths\":");
        if (result.landlock_allowed_paths) |paths_json| try writer.writeAll(paths_json) else try writer.writeAll("null");
        try writer.writeAll(",\"landlockRetryPath\":");
        if (result.landlock_retry_path) |path| try std.json.stringify(path, .{}, writer) else try writer.writeAll("null");
        try writer.print(",\"oracleTimeout\":{}", .{result.oracle_timeout});
        try writer.writeAll(",\"oracleTimeoutGipOpCode\":");
        try std.json.stringify(@tagName(result.oracle_timeout_gip_opcode), .{}, writer);
        try writer.writeAll(",\"ephemeralVenvPath\":");
        if (result.ephemeral_venv_path) |path| try std.json.stringify(path, .{}, writer) else try writer.writeAll("null");
        try writer.print(",\"preflightDependencyInstall\":{}", .{result.preflight_dependency_install});
        try writer.writeAll(",\"patchIntegrityGipOpCode\":");
        try std.json.stringify(@tagName(result.patch_integrity_gip_opcode), .{}, writer);
        try writer.writeAll(",\"testPatchMode\":");
        if (result.test_patch_mode) |mode| try std.json.stringify(mode, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll(",\"goldPatchMode\":");
        if (result.gold_patch_mode) |mode| try std.json.stringify(mode, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll(",\"goldPatchChangedFiles\":");
        if (result.gold_patch_changed_files) |files| try std.json.stringify(files, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll(",\"goldPatchDiffStat\":");
        if (result.gold_patch_diff_stat) |stat| try std.json.stringify(stat, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll(",\"reprioritizationDistance\":");
        if (result.reprioritization_distance) |distance| try writer.print("{d}", .{distance}) else try writer.writeAll("null");
        try writer.writeAll(",\"repairGipOpCode\":");
        try std.json.stringify(@tagName(result.repair_gip_opcode), .{}, writer);
        try writer.print(",\"reproducedBaseFailure\":{},\"failToPassPassed\":{},\"passToPassPassed\":{},\"runeWritten\":{},\"cleanupDone\":{},\"environmentAttempts\":{d},\"repairAttempts\":{d},\"gapLogged\":{}", .{
            result.reproduced_base_failure,
            result.fail_to_pass_passed,
            result.pass_to_pass_passed,
            result.rune_written,
            result.cleanup_done,
            result.environment_attempts,
            result.repair_attempts,
            result.gap_logged,
        });
        try writer.writeAll(",\"reason\":");
        try std.json.stringify(result.reason, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

test "SWE row parser handles Python-style test lists and selected files" {
    const allocator = std.testing.allocator;
    var instance = try parseInstanceLine(allocator,
        \\{"instance_id":"i","repo":"owner/repo","base_commit":"abc","repo_language":"python","problem_statement":"fix","patch":"diff --git a/a b/a\n","test_patch":"","fail_to_pass":"['tests/a.py::test_one', 'tests/a.py::test_two']","pass_to_pass":"[\"tests/a.py::test_old\"]","selected_test_files_to_run":"[\"tests/a.py\"]"}
    );
    defer instance.deinit();
    try std.testing.expectEqual(Language.python, instance.repo_language);
    try std.testing.expectEqual(@as(usize, 2), instance.fail_to_pass.len);
    try std.testing.expectEqualStrings("tests/a.py::test_one", instance.fail_to_pass[0]);
    try std.testing.expectEqualStrings("tests/a.py", instance.selected_test_files[0]);
    try std.testing.expectEqualStrings("tests/a.py", instance.root_hint_path);
}

test "offline corpus mirror rewrites clone source to file URL" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("mirrors/qutebrowser");
    const root = try tmp.dir.realpathAlloc(allocator, "mirrors");
    defer allocator.free(root);

    var source = try resolveCloneSource(allocator, "qutebrowser/qutebrowser", root);
    defer source.deinit();
    try std.testing.expect(source.offline);
    try std.testing.expect(std.mem.startsWith(u8, source.url, "file://"));
    try std.testing.expect(std.mem.endsWith(u8, source.url, "/qutebrowser"));
}

test "offline corpus mirror fails before network when repo mirror is absent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try std.testing.expectError(error.OfflineMirrorMissing, resolveCloneSource(allocator, "owner/missing", root));
}

test "offline corpus file URLs escape spaces" {
    const allocator = std.testing.allocator;
    const url = try fileUrlFromAbsolutePath(allocator, "/tmp/ghost mirror/qutebrowser");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("file:///tmp/ghost%20mirror/qutebrowser", url);
}

test "proof status maps to deterministic GIP opcodes" {
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_ORACLE_PROVE, gipOpForStatus(.base_reproduced));
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_TRUTH_SYNC, gipOpForStatus(.verified));
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_SEC_FAULT, gipOpForStatus(.invalid_environment));
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_ORACLE_TIMEOUT, gipOpForStatus(.oracle_timeout));
}

test "environment failure classifier catches missing native dependencies" {
    try std.testing.expect(looksLikeEnvironmentFailure("ModuleNotFoundError: No module named 'qutebrowser'"));
    try std.testing.expect(looksLikeEnvironmentFailure("npm ERR! missing script: test"));
    try std.testing.expect(looksLikeEnvironmentFailure("ERROR: Missing required plugins: pytest-qt"));
    try std.testing.expect(looksLikeEnvironmentFailure("pytest.PytestRemovedIn9Warning: hook signature is deprecated"));
    try std.testing.expect(looksLikeEnvironmentFailure("ERROR: found no collectors for test_file.py::test_case"));
    try std.testing.expect(looksLikeEnvironmentFailure("open /home/micah/Documents/x: Permission denied"));
    try std.testing.expect(!looksLikeEnvironmentFailure("AssertionError: expected false to equal true"));
}

test "interface metadata path is preferred for build root hint" {
    const allocator = std.testing.allocator;
    var instance = try parseInstanceLine(allocator,
        \\{"instance_id":"i","repo":"owner/repo","base_commit":"abc","repo_language":"python","problem_statement":"fix","interface":"Type: Function\nPath: packages/ui/src/view.py, packages/api/src/api.py\n","patch":"diff --git a/a b/a\n","test_patch":"","fail_to_pass":"['packages/ui/tests/test_view.py::test_one']","pass_to_pass":"['packages/ui/tests/test_old.py::test_old']","selected_test_files_to_run":"[\"packages/ui/tests/test_view.py\"]"}
    );
    defer instance.deinit();
    try std.testing.expectEqualStrings("packages/ui/src/view.py", instance.root_hint_path);
}

test "test selectors are made relative to nested build root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("packages/ui/tests");
    try tmp.dir.writeFile(.{ .sub_path = "packages/ui/tests/test_view.py", .data = "" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const build_root = try std.fs.path.join(allocator, &.{ root, "packages/ui" });
    defer allocator.free(build_root);

    const selector = try selectorRelativeToBuildRoot(allocator, root, build_root, "packages/ui", "packages/ui/tests/test_view.py::test_one");
    defer allocator.free(selector);
    try std.testing.expectEqualStrings("tests/test_view.py::test_one", selector);
}

test "test selectors rebase to physical workspace file outside nested root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("nested/pkg");
    try tmp.dir.makePath("tests");
    try tmp.dir.writeFile(.{ .sub_path = "tests/test_api.py", .data = "" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const build_root = try std.fs.path.join(allocator, &.{ root, "nested/pkg" });
    defer allocator.free(build_root);

    const selector = try selectorRelativeToBuildRoot(allocator, root, build_root, "nested/pkg", "tests/test_api.py::test_case");
    defer allocator.free(selector);
    const expected = try std.fs.path.join(allocator, &.{ root, "tests/test_api.py::test_case" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, selector);
}
