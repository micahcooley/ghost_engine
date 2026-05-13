const std = @import("std");
const bench_loader = @import("bench_loader.zig");
const gip_mapping = @import("../gip/mapping.zig");
const search_client = @import("../net/search_client.zig");
const sandbox = @import("../oracle/sandbox.zig");

pub const FixStatus = enum {
    no_action,
    attempted,
    fixed,

    pub fn name(self: FixStatus) []const u8 {
        return @tagName(self);
    }
};

pub const FixContext = struct {
    workspace_path: []const u8,
    instance_id: []const u8,
    repo: []const u8,
    base_commit: []const u8,
    commit_year: ?u16 = null,
    repo_language: []const u8,
    pip_exe: []const u8,
    sandbox_spec: sandbox.SandboxSpec,
    max_output_bytes: usize,
    enable_live_discovery: bool = true,
};

pub const FixResult = struct {
    allocator: std.mem.Allocator,
    status: FixStatus,
    detail: []u8,

    pub fn deinit(self: *FixResult) void {
        self.allocator.free(self.detail);
        self.* = undefined;
    }
};

pub const GapRecord = struct {
    instance_id: []const u8,
    repo: []const u8,
    base_commit: []const u8,
    repo_language: []const u8,
    attempts: u8,
    reason: []const u8,
    fix_detail: []const u8,
};

pub const BuildRootResolution = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,
    root_relative: []u8,
    marker: []u8,
    candidates_considered: usize,
    gip_opcode: gip_mapping.GipOpCode = .GIP_OP_RESOLVE_BUILD_ROOT,

    pub fn deinit(self: *BuildRootResolution) void {
        self.allocator.free(self.root_path);
        self.allocator.free(self.root_relative);
        self.allocator.free(self.marker);
        self.* = undefined;
    }
};

const BuildRootCandidate = struct {
    root_relative: []u8,
    marker: []u8,

    fn deinit(self: *BuildRootCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.root_relative);
        allocator.free(self.marker);
        self.* = undefined;
    }
};

const CommandResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }

    fn exitedOk(self: CommandResult) bool {
        return switch (self.term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }
};

pub fn resolveBuildRoot(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    preferred_path: ?[]const u8,
) !BuildRootResolution {
    var candidates = std.ArrayList(BuildRootCandidate).init(allocator);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit();
    }

    var root = try std.fs.openDirAbsolute(workspace_path, .{ .iterate = true });
    defer root.close();
    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (pathHasSkippedRootHunterSegment(entry.path)) continue;
        if (!isBuildRootMarker(entry.basename)) continue;
        const rel_dir = std.fs.path.dirname(entry.path) orelse ".";
        try appendBuildRootCandidate(allocator, &candidates, rel_dir, entry.basename);
    }

    if (candidates.items.len == 0) {
        return .{
            .allocator = allocator,
            .root_path = try allocator.dupe(u8, workspace_path),
            .root_relative = try allocator.dupe(u8, "."),
            .marker = try allocator.dupe(u8, "workspace_root"),
            .candidates_considered = 0,
        };
    }

    const preferred = normalizePreferredPath(preferred_path);
    const selected_index = selectBuildRootCandidate(candidates.items, preferred);
    const selected = candidates.items[selected_index];
    return .{
        .allocator = allocator,
        .root_path = try absoluteRootPath(allocator, workspace_path, selected.root_relative),
        .root_relative = try allocator.dupe(u8, selected.root_relative),
        .marker = try allocator.dupe(u8, selected.marker),
        .candidates_considered = candidates.items.len,
    };
}

pub fn fixEnvironment(allocator: std.mem.Allocator, context: FixContext, diagnostic: []const u8) !FixResult {
    if (isJavascript(context.repo_language) and (!packageJsonExists(allocator, context.workspace_path) or containsIgnoreCase(diagnostic, "package.json"))) {
        return try fixNodeSubmodules(allocator, context);
    }
    if (isJavascript(context.repo_language)) {
        if (try parseMissingNodeModule(allocator, diagnostic)) |module_name| {
            defer allocator.free(module_name);
            return try installNodeModuleWithDiscovery(allocator, context, module_name, diagnostic);
        }
    }

    if (isPython(context.repo_language)) {
        if (containsIgnoreCase(diagnostic, "PytestRemovedIn9Warning")) {
            const requirements = [_][]const u8{"pytest<8"};
            return try pipInstall(allocator, context, &requirements);
        }

        const plugins = try parseMissingPytestPlugins(allocator, diagnostic);
        defer freeStringList(allocator, plugins);
        if (plugins.len != 0) {
            return try pipInstall(allocator, context, plugins);
        }

        if (try parseMissingPythonModule(allocator, diagnostic)) |module_name| {
            defer allocator.free(module_name);
            return try pipInstallWithDiscovery(allocator, context, module_name, diagnostic);
        }
    }

    return .{
        .allocator = allocator,
        .status = .no_action,
        .detail = try allocator.dupe(u8, "no deterministic bootstrap action matched environment failure"),
    };
}

fn fixNodeSubmodules(allocator: std.mem.Allocator, context: FixContext) !FixResult {
    var argv = try buildBootstrapArgv(
        allocator,
        context,
        &.{ "git", "submodule", "update", "--init", "--recursive" },
    );
    defer argv.deinit();
    var result = try runCapture(allocator, null, argv.argv.items, context.max_output_bytes);
    defer result.deinit(allocator);

    if (result.exitedOk() and packageJsonExists(allocator, context.workspace_path)) {
        return .{
            .allocator = allocator,
            .status = .fixed,
            .detail = try allocator.dupe(u8, "git submodule update restored root package.json"),
        };
    }

    const diagnostic = commandDiagnostic(result);
    if (result.exitedOk()) {
        return .{
            .allocator = allocator,
            .status = .attempted,
            .detail = try allocator.dupe(u8, "git submodule update completed but root package.json is still missing"),
        };
    }
    return .{
        .allocator = allocator,
        .status = .attempted,
        .detail = try std.fmt.allocPrint(allocator, "git submodule update failed: {s}", .{shorten(diagnostic)}),
    };
}

fn pipInstall(allocator: std.mem.Allocator, context: FixContext, packages: []const []const u8) !FixResult {
    var inner = std.ArrayList([]const u8).init(allocator);
    defer inner.deinit();
    try inner.append(context.pip_exe);
    try inner.append("install");
    for (packages) |package| {
        if (!isSafeRequirementSpec(package)) {
            return .{
                .allocator = allocator,
                .status = .no_action,
                .detail = try std.fmt.allocPrint(allocator, "refused unsafe pip requirement name: {s}", .{package}),
            };
        }
        try inner.append(package);
    }

    var argv = try buildBootstrapArgv(allocator, context, inner.items);
    defer argv.deinit();
    var result = try runCapture(allocator, null, argv.argv.items, context.max_output_bytes);
    defer result.deinit(allocator);

    if (result.exitedOk()) {
        const joined = try joinRequirements(allocator, packages);
        defer allocator.free(joined);
        return .{
            .allocator = allocator,
            .status = .fixed,
            .detail = try std.fmt.allocPrint(allocator, "installed Python bootstrap requirements: {s}", .{joined}),
        };
    }

    return .{
        .allocator = allocator,
        .status = .attempted,
        .detail = try std.fmt.allocPrint(allocator, "pip install failed: {s}", .{shorten(commandDiagnostic(result))}),
    };
}

fn pipInstallWithDiscovery(
    allocator: std.mem.Allocator,
    context: FixContext,
    module_name: []const u8,
    diagnostic: []const u8,
) !FixResult {
    const direct_requirements = [_][]const u8{pipRequirementForModule(module_name)};
    var direct = try pipInstall(allocator, context, &direct_requirements);
    if (direct.status == .fixed or !context.enable_live_discovery) return direct;
    defer direct.deinit();

    const discovered = (try search_client.discoverPipRequirementForYear(allocator, module_name, diagnostic, context.commit_year)) orelse {
        return .{
            .allocator = allocator,
            .status = .attempted,
            .detail = try std.fmt.allocPrint(allocator, "{s}; local SearXNG produced no safe pip candidate{s}", .{ direct.detail, timeConstraintDetail(context.commit_year) }),
        };
    };
    defer allocator.free(discovered);

    const discovered_requirements = [_][]const u8{discovered};
    var resolved = try pipInstall(allocator, context, &discovered_requirements);
    if (resolved.status == .fixed) {
        const detail = try std.fmt.allocPrint(allocator, "{s}; local SearXNG mapped missing module {s} to pip requirement {s}{s}", .{ resolved.detail, module_name, discovered, timeConstraintDetail(context.commit_year) });
        allocator.free(resolved.detail);
        resolved.detail = detail;
    }
    return resolved;
}

fn npmInstall(allocator: std.mem.Allocator, context: FixContext, packages: []const []const u8) !FixResult {
    var inner = std.ArrayList([]const u8).init(allocator);
    defer inner.deinit();
    try inner.append("npm");
    try inner.append("install");
    try inner.append("--no-save");
    for (packages) |package| {
        if (!isSafeNpmPackage(package)) {
            return .{
                .allocator = allocator,
                .status = .no_action,
                .detail = try std.fmt.allocPrint(allocator, "refused unsafe npm package name: {s}", .{package}),
            };
        }
        try inner.append(package);
    }

    var argv = try buildBootstrapArgv(allocator, context, inner.items);
    defer argv.deinit();
    var result = try runCapture(allocator, null, argv.argv.items, context.max_output_bytes);
    defer result.deinit(allocator);

    if (result.exitedOk()) {
        const joined = try joinRequirements(allocator, packages);
        defer allocator.free(joined);
        return .{
            .allocator = allocator,
            .status = .fixed,
            .detail = try std.fmt.allocPrint(allocator, "installed Node bootstrap packages: {s}", .{joined}),
        };
    }
    return .{
        .allocator = allocator,
        .status = .attempted,
        .detail = try std.fmt.allocPrint(allocator, "npm install failed: {s}", .{shorten(commandDiagnostic(result))}),
    };
}

fn installNodeModuleWithDiscovery(
    allocator: std.mem.Allocator,
    context: FixContext,
    module_name: []const u8,
    diagnostic: []const u8,
) !FixResult {
    const direct_packages = [_][]const u8{module_name};
    var direct = try npmInstall(allocator, context, &direct_packages);
    if (direct.status == .fixed or !context.enable_live_discovery) return direct;
    defer direct.deinit();

    const discovered = (try search_client.discoverNpmPackageForYear(allocator, module_name, diagnostic, context.commit_year)) orelse {
        return .{
            .allocator = allocator,
            .status = .attempted,
            .detail = try std.fmt.allocPrint(allocator, "{s}; local SearXNG produced no safe npm candidate{s}", .{ direct.detail, timeConstraintDetail(context.commit_year) }),
        };
    };
    defer allocator.free(discovered);

    const discovered_packages = [_][]const u8{discovered};
    var resolved = try npmInstall(allocator, context, &discovered_packages);
    if (resolved.status == .fixed) {
        const detail = try std.fmt.allocPrint(allocator, "{s}; local SearXNG mapped missing module {s} to npm package {s}{s}", .{ resolved.detail, module_name, discovered, timeConstraintDetail(context.commit_year) });
        allocator.free(resolved.detail);
        resolved.detail = detail;
    }
    return resolved;
}

fn timeConstraintDetail(commit_year: ?u16) []const u8 {
    return if (commit_year) |year| switch (year) {
        0 => "",
        else => " using commit-year bounded search",
    } else "";
}

fn buildBootstrapArgv(
    allocator: std.mem.Allocator,
    context: FixContext,
    inner_argv: []const []const u8,
) !sandbox.SandboxArgv {
    var bootstrap_spec = context.sandbox_spec;
    bootstrap_spec.network_disabled = false;
    bootstrap_spec.timeout_ms = @min(bootstrap_spec.timeout_ms, 60_000);
    return sandbox.buildLandlockRunArgv(allocator, bootstrap_spec, context.workspace_path, inner_argv);
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

fn packageJsonExists(allocator: std.mem.Allocator, workspace_path: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ workspace_path, "package.json" }) catch return false;
    defer allocator.free(path);
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn appendBuildRootCandidate(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(BuildRootCandidate),
    root_relative: []const u8,
    marker: []const u8,
) !void {
    const normalized = if (root_relative.len == 0) "." else root_relative;
    for (candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate.root_relative, normalized)) return;
    }
    try candidates.append(.{
        .root_relative = try allocator.dupe(u8, normalized),
        .marker = try allocator.dupe(u8, marker),
    });
}

fn absoluteRootPath(allocator: std.mem.Allocator, workspace_path: []const u8, root_relative: []const u8) ![]u8 {
    if (std.mem.eql(u8, root_relative, ".") or root_relative.len == 0) return allocator.dupe(u8, workspace_path);
    return std.fs.path.join(allocator, &.{ workspace_path, root_relative });
}

fn selectBuildRootCandidate(candidates: []const BuildRootCandidate, preferred_path: []const u8) usize {
    var best_index: usize = 0;
    var best_affinity = candidateAffinity(candidates[0].root_relative, preferred_path);
    var best_depth = pathDepth(candidates[0].root_relative);
    var best_marker = markerPriority(candidates[0].marker);

    for (candidates[1..], 1..) |candidate, idx| {
        const affinity = candidateAffinity(candidate.root_relative, preferred_path);
        const depth = pathDepth(candidate.root_relative);
        const priority = markerPriority(candidate.marker);
        if (affinity > best_affinity or
            (affinity == best_affinity and preferred_path.len != 0 and depth > best_depth) or
            (affinity == best_affinity and depth == best_depth and priority < best_marker) or
            (affinity == best_affinity and preferred_path.len == 0 and depth < best_depth))
        {
            best_index = idx;
            best_affinity = affinity;
            best_depth = depth;
            best_marker = priority;
        }
    }
    return best_index;
}

fn candidateAffinity(root_relative: []const u8, preferred_path: []const u8) usize {
    if (preferred_path.len == 0) return 0;
    if (std.mem.eql(u8, root_relative, ".") or root_relative.len == 0) return 1;
    if (std.mem.eql(u8, root_relative, preferred_path)) return 10_000 + pathDepth(root_relative);
    if (std.mem.startsWith(u8, preferred_path, root_relative) and preferred_path.len > root_relative.len and preferred_path[root_relative.len] == '/') {
        return 10_000 + pathDepth(root_relative);
    }
    return commonPrefixSegments(root_relative, preferred_path);
}

fn commonPrefixSegments(a: []const u8, b: []const u8) usize {
    var ait = std.mem.splitScalar(u8, a, '/');
    var bit = std.mem.splitScalar(u8, b, '/');
    var count: usize = 0;
    while (true) {
        const av = ait.next() orelse break;
        const bv = bit.next() orelse break;
        if (av.len == 0 or bv.len == 0 or !std.mem.eql(u8, av, bv)) break;
        count += 1;
    }
    return count;
}

fn pathDepth(path: []const u8) usize {
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return 0;
    var depth: usize = 1;
    for (path) |ch| {
        if (ch == '/') depth += 1;
    }
    return depth;
}

fn markerPriority(marker: []const u8) usize {
    if (std.mem.eql(u8, marker, "pyproject.toml")) return 0;
    if (std.mem.eql(u8, marker, "package.json")) return 1;
    if (std.mem.eql(u8, marker, "CMakeLists.txt")) return 2;
    if (std.mem.eql(u8, marker, "setup.py")) return 3;
    if (std.mem.eql(u8, marker, "tox.ini")) return 4;
    return 10;
}

fn normalizePreferredPath(preferred_path: ?[]const u8) []const u8 {
    const raw = preferred_path orelse return "";
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"'`");
    if (trimmed.len == 0 or std.fs.path.isAbsolute(trimmed)) return "";
    if (std.mem.indexOf(u8, trimmed, "..") != null) return "";
    const selector_end = std.mem.indexOf(u8, trimmed, "::") orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..selector_end], " \t\r\n\"'`");
}

fn isBuildRootMarker(name: []const u8) bool {
    return std.mem.eql(u8, name, "package.json") or
        std.mem.eql(u8, name, "pyproject.toml") or
        std.mem.eql(u8, name, "CMakeLists.txt") or
        std.mem.eql(u8, name, "setup.py") or
        std.mem.eql(u8, name, "tox.ini");
}

fn shouldSkipRootHunterDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".venv") or
        std.mem.eql(u8, name, "venv") or
        std.mem.eql(u8, name, "temp_venv") or
        std.mem.eql(u8, name, "__pycache__") or
        std.mem.eql(u8, name, "dist") or
        std.mem.eql(u8, name, "build");
}

fn pathHasSkippedRootHunterSegment(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (shouldSkipRootHunterDir(part)) return true;
    }
    return false;
}

pub fn parseMissingPytestPlugins(allocator: std.mem.Allocator, diagnostic: []const u8) ![][]u8 {
    const marker = "Missing required plugins:";
    const start = indexOfIgnoreCase(diagnostic, marker) orelse return allocator.alloc([]u8, 0);
    const after_marker = diagnostic[start + marker.len ..];
    const line_end = std.mem.indexOfScalar(u8, after_marker, '\n') orelse after_marker.len;
    const line = after_marker[0..line_end];

    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit();
    }

    var parts = std.mem.splitScalar(u8, line, ',');
    while (parts.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r\n.");
        if (name.len == 0) continue;
        if (!isSafeRequirementName(name)) return error.UnsafeRequirementName;
        try out.append(try allocator.dupe(u8, name));
    }
    return out.toOwnedSlice();
}

pub fn parseMissingPythonModule(allocator: std.mem.Allocator, diagnostic: []const u8) !?[]u8 {
    const marker = "No module named";
    const start = indexOfIgnoreCase(diagnostic, marker) orelse return null;
    var idx = start + marker.len;
    while (idx < diagnostic.len and std.ascii.isWhitespace(diagnostic[idx])) : (idx += 1) {}
    if (idx >= diagnostic.len) return null;

    const quote = diagnostic[idx];
    if (quote == '\'' or quote == '"') {
        idx += 1;
        const end_rel = std.mem.indexOfScalar(u8, diagnostic[idx..], quote) orelse return null;
        const name = diagnostic[idx .. idx + end_rel];
        if (name.len == 0 or !isSafeRequirementName(name)) return null;
        return try allocator.dupe(u8, name);
    }

    const start_name = idx;
    while (idx < diagnostic.len and !std.ascii.isWhitespace(diagnostic[idx]) and diagnostic[idx] != ',' and diagnostic[idx] != '.') : (idx += 1) {}
    const name = diagnostic[start_name..idx];
    if (name.len == 0 or !isSafeRequirementName(name)) return null;
    return try allocator.dupe(u8, name);
}

pub fn parseMissingNodeModule(allocator: std.mem.Allocator, diagnostic: []const u8) !?[]u8 {
    const marker = "Cannot find module";
    const start = indexOfIgnoreCase(diagnostic, marker) orelse return null;
    var idx = start + marker.len;
    while (idx < diagnostic.len and std.ascii.isWhitespace(diagnostic[idx])) : (idx += 1) {}
    if (idx >= diagnostic.len) return null;

    const quote = diagnostic[idx];
    if (quote == '\'' or quote == '"') {
        idx += 1;
        const end_rel = std.mem.indexOfScalar(u8, diagnostic[idx..], quote) orelse return null;
        const name = diagnostic[idx .. idx + end_rel];
        if (name.len == 0 or !isSafeNpmPackage(name) or name[0] == '.' or name[0] == '/') return null;
        return try allocator.dupe(u8, name);
    }

    const start_name = idx;
    while (idx < diagnostic.len and !std.ascii.isWhitespace(diagnostic[idx]) and diagnostic[idx] != ',' and diagnostic[idx] != '.') : (idx += 1) {}
    const name = diagnostic[start_name..idx];
    if (name.len == 0 or !isSafeNpmPackage(name) or name[0] == '.' or name[0] == '/') return null;
    return try allocator.dupe(u8, name);
}

pub fn writeEnvironmentGap(allocator: std.mem.Allocator, knowledge_dir: []const u8, record: GapRecord) !void {
    try std.fs.cwd().makePath(knowledge_dir);
    const path = try std.fs.path.join(allocator, &.{ knowledge_dir, "environment_gaps.gkpack" });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    const writer = file.writer();
    try writer.writeAll("{\"schema\":\"ghost.environment_gap.v1\",\"instanceId\":");
    try std.json.stringify(record.instance_id, .{}, writer);
    try writer.writeAll(",\"repo\":");
    try std.json.stringify(record.repo, .{}, writer);
    try writer.writeAll(",\"baseCommit\":");
    try std.json.stringify(record.base_commit, .{}, writer);
    try writer.writeAll(",\"repoLanguage\":");
    try std.json.stringify(record.repo_language, .{}, writer);
    try writer.print(",\"attempts\":{d},\"reason\":", .{record.attempts});
    try std.json.stringify(shorten(record.reason), .{}, writer);
    try writer.writeAll(",\"fixDetail\":");
    try std.json.stringify(shorten(record.fix_detail), .{}, writer);
    try writer.writeAll(",\"epistemicTag\":\"environment_gap\",\"nonAuthorizing\":true}\n");
}

fn joinRequirements(allocator: std.mem.Allocator, packages: []const []const u8) ![]u8 {
    var joined = std.ArrayList(u8).init(allocator);
    errdefer joined.deinit();
    for (packages, 0..) |package, idx| {
        if (idx != 0) try joined.appendSlice(",");
        try joined.appendSlice(package);
    }
    return joined.toOwnedSlice();
}

fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn isSafeRequirementName(name: []const u8) bool {
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') continue;
        return false;
    }
    return name.len != 0 and name.len <= 128;
}

fn isSafeRequirementSpec(name: []const u8) bool {
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '<' or ch == '>' or ch == '=' or ch == '!' or ch == '~') continue;
        return false;
    }
    return name.len != 0 and name.len <= 128;
}

fn isSafeNpmPackage(name: []const u8) bool {
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '@' or ch == '/') continue;
        return false;
    }
    return name.len != 0 and name.len <= 160 and std.mem.indexOf(u8, name, "..") == null;
}

fn pipRequirementForModule(module_name: []const u8) []const u8 {
    if (std.mem.eql(u8, module_name, "web")) return "web.py";
    if (std.mem.eql(u8, module_name, "yaml")) return "PyYAML";
    if (std.mem.eql(u8, module_name, "PIL")) return "Pillow";
    if (std.mem.eql(u8, module_name, "cv2")) return "opencv-python";
    if (std.mem.eql(u8, module_name, "sklearn")) return "scikit-learn";
    if (std.mem.eql(u8, module_name, "bs4")) return "beautifulsoup4";
    return module_name;
}

fn isPython(language: []const u8) bool {
    return std.ascii.eqlIgnoreCase(language, "python") or std.ascii.eqlIgnoreCase(language, "py");
}

fn isJavascript(language: []const u8) bool {
    return std.ascii.eqlIgnoreCase(language, "javascript") or std.ascii.eqlIgnoreCase(language, "js") or std.ascii.eqlIgnoreCase(language, "node");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(haystack, needle) != null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

fn shorten(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed[0..@min(trimmed.len, 2000)];
}

test "pytest plugin parser extracts deterministic pip requirements" {
    const allocator = std.testing.allocator;
    const plugins = try parseMissingPytestPlugins(allocator, "ERROR: Missing required plugins: pytest-bdd, pytest-qt, pytest-rerunfailures\n");
    defer freeStringList(allocator, plugins);
    try std.testing.expectEqual(@as(usize, 3), plugins.len);
    try std.testing.expectEqualStrings("pytest-bdd", plugins[0]);
    try std.testing.expectEqualStrings("pytest-qt", plugins[1]);
}

test "missing module parser refuses unsafe names" {
    const allocator = std.testing.allocator;
    const module = try parseMissingPythonModule(allocator, "ModuleNotFoundError: No module named 'pytest_mock'");
    defer allocator.free(module.?);
    try std.testing.expectEqualStrings("pytest_mock", module.?);
    try std.testing.expect((try parseMissingPythonModule(allocator, "No module named '../../bad'")) == null);
}

test "module names can map to package requirements without broad inference" {
    try std.testing.expectEqualStrings("web.py", pipRequirementForModule("web"));
    try std.testing.expectEqualStrings("PyYAML", pipRequirementForModule("yaml"));
    try std.testing.expectEqualStrings("PyQt5", pipRequirementForModule("PyQt5"));
    try std.testing.expect(isSafeRequirementSpec("pytest<8"));
    try std.testing.expect(!isSafeRequirementSpec("pytest;rm"));
}

test "node missing module parser extracts safe npm package names" {
    const allocator = std.testing.allocator;
    const module = try parseMissingNodeModule(allocator, "Error: Cannot find module '@scope/pkg'");
    defer allocator.free(module.?);
    try std.testing.expectEqualStrings("@scope/pkg", module.?);
    try std.testing.expect((try parseMissingNodeModule(allocator, "Cannot find module '../../bad'")) == null);
}

test "build root resolver chooses marker closest to hinted file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data = "{}" });
    try tmp.dir.makePath("packages/ui/src");
    try tmp.dir.writeFile(.{ .sub_path = "packages/ui/package.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "packages/ui/src/view.js", .data = "" });
    try tmp.dir.makePath("packages/api");
    try tmp.dir.writeFile(.{ .sub_path = "packages/api/pyproject.toml", .data = "[project]\nname='api'\n" });

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    var resolved = try resolveBuildRoot(allocator, root_path, "packages/ui/src/view.js");
    defer resolved.deinit();
    try std.testing.expectEqualStrings("packages/ui", resolved.root_relative);
    try std.testing.expectEqualStrings("package.json", resolved.marker);
    try std.testing.expectEqual(gip_mapping.GipOpCode.GIP_OP_RESOLVE_BUILD_ROOT, resolved.gip_opcode);
}

test "build root resolver falls back to workspace root without markers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    var resolved = try resolveBuildRoot(allocator, root_path, "src/main.zig");
    defer resolved.deinit();
    try std.testing.expectEqualStrings(".", resolved.root_relative);
    try std.testing.expectEqualStrings("workspace_root", resolved.marker);
    try std.testing.expectEqual(@as(usize, 0), resolved.candidates_considered);
}
