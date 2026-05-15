const std = @import("std");
const core = @import("ghost.zig");
const execution = @import("execution.zig");
const vsa = core.vsa;

pub const HypothesisRank = enum(u8) {
    truth = 1,
    dark_space = 5,

    pub fn label(self: HypothesisRank) []const u8 {
        return switch (self) {
            .truth => "Rank-1 Truth",
            .dark_space => "Rank-5 Dark Space",
        };
    }
};

pub const ZigHypothesisRequest = struct {
    /// Absolute workspace root where the bounded experiment is allowed to write.
    workspace_root: []const u8,
    /// Relative .zig path to materialize inside workspace_root.
    relative_path: []const u8,
    /// Candidate source produced by an upstream projector/generator.
    source: []const u8,
    /// Human-readable intent that produced the candidate.
    intent: []const u8 = "",
    timeout_ms: u32 = execution.DEFAULT_TIMEOUT_MS,
    max_output_bytes: usize = execution.DEFAULT_MAX_OUTPUT_BYTES,
};

pub const ZigHypothesisResult = struct {
    allocator: std.mem.Allocator,
    intent: []u8,
    materialized_path: []u8,
    build_file_path: []u8,
    command: []u8,
    rank: HypothesisRank,
    exit_code: ?i32,
    failure_signal: execution.FailureSignal,
    duration_ms: u64,
    stdout: []u8,
    stderr: []u8,
    evidence: []u8,

    pub fn deinit(self: *ZigHypothesisResult) void {
        self.allocator.free(self.intent);
        self.allocator.free(self.materialized_path);
        self.allocator.free(self.build_file_path);
        self.allocator.free(self.command);
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.allocator.free(self.evidence);
        self.* = undefined;
    }
};

pub const Effector = struct {
    allocator: std.mem.Allocator,
    signatures: std.ArrayList(CommandSignature),

    pub const CommandSignature = struct {
        vector: vsa.HyperVector,
        shell_command: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) !Effector {
        var self = Effector{
            .allocator = allocator,
            .signatures = std.ArrayList(CommandSignature).init(allocator),
        };

        // Seed Rank-1 operations into the Effector's memory
        try self.registerCommand("pip install --break-system-packages jinja2");
        try self.registerCommand("chmod +x script.sh");

        return self;
    }

    pub fn deinit(self: *Effector) void {
        for (self.signatures.items) |sig| {
            self.allocator.free(sig.shell_command);
        }
        self.signatures.deinit();
    }

    fn featureVector(prefix: []const u8, text: []const u8) vsa.HyperVector {
        var h: u64 = 14695981039346656037;
        for (prefix) |c| {
            h ^= c;
            h *%= 1099511628211;
        }
        for (text) |c| {
            h ^= c;
            h *%= 1099511628211;
        }
        return vsa.generate(h);
    }

    pub fn registerCommand(self: *Effector, cmd: []const u8) !void {
        const vec = featureVector("effector_cmd", cmd);
        try self.signatures.append(.{ .vector = vec, .shell_command = try self.allocator.dupe(u8, cmd) });
    }

    pub fn resolveAndExecute(self: *Effector, candidate: vsa.HyperVector, diagnostic: vsa.HyperVector) !?[]const u8 {
        // 1. Unbind the diagnostic context to reveal the intended action
        const action_intent = vsa.bind(candidate, diagnostic); // XOR unbinds itself

        // 2. Search our known Effector signatures for a resonance match
        var best_match: ?[]const u8 = null;
        var best_distance: u16 = 512;

        for (self.signatures.items) |sig| {
            const dist = vsa.math.hammingDistance(action_intent, sig.vector);
            if (dist < 100) { // High resonance threshold
                if (dist < best_distance) {
                    best_distance = dist;
                    best_match = sig.shell_command;
                }
            }
        }

        if (best_match) |cmd| {
            std.debug.print("[EFFECTOR] Resolved Candidate Rune to Action: '{s}' (Distance: {d} bits)\n", .{ cmd, best_distance });
            std.debug.print("[EFFECTOR] Executing Shell Command...\n", .{});

            var child_args = [_][]const u8{ "/bin/sh", "-c", cmd };
            var child = std.process.Child.init(&child_args, self.allocator);
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            const term = try child.spawnAndWait();
            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        std.debug.print("[EFFECTOR] Command failed with exit code {d}\n", .{code});
                        return null; // Effector action failed
                    }
                },
                else => {
                    std.debug.print("[EFFECTOR] Command terminated abnormally\n", .{});
                    return null;
                },
            }

            return cmd;
        }

        return null;
    }
};

/// Materialize a candidate Zig hypothesis and test it through the bounded
/// argv-only execution harness. Passing `zig build` is the only promotion path.
pub fn testZigHypothesis(
    allocator: std.mem.Allocator,
    request: ZigHypothesisRequest,
) !ZigHypothesisResult {
    if (!std.fs.path.isAbsolute(request.workspace_root)) return error.WorkspaceRootMustBeAbsolute;
    try validateRelativeZigPath(request.relative_path);

    const workspace_root = try std.fs.path.resolve(allocator, &.{request.workspace_root});
    defer allocator.free(workspace_root);
    try std.fs.cwd().makePath(workspace_root);

    const materialized_path = try std.fs.path.resolve(allocator, &.{ workspace_root, request.relative_path });
    errdefer allocator.free(materialized_path);
    if (!pathWithinRoot(workspace_root, materialized_path)) return error.WorkspaceEscape;

    if (std.fs.path.dirname(materialized_path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }

    var source_file = try std.fs.createFileAbsolute(materialized_path, .{ .truncate = true });
    defer source_file.close();
    try source_file.writeAll(request.source);

    const build_file_path = try std.fs.path.join(allocator, &.{ workspace_root, "build.zig" });
    errdefer allocator.free(build_file_path);
    try writeHypothesisBuildFile(allocator, build_file_path, request.relative_path);

    var run_result = try execution.run(allocator, .{
        .workspace_root = workspace_root,
        .cwd = workspace_root,
        .max_output_bytes = request.max_output_bytes,
    }, .{
        .label = "zig_hypothesis_build",
        .kind = .zig_build,
        .phase = .build,
        .argv = &.{ "zig", "build" },
        .expectations = &.{.{ .success = {} }},
        .timeout_ms = request.timeout_ms,
    });
    defer run_result.deinit(allocator);

    const evidence = try execution.buildEvidence(allocator, &run_result);
    errdefer allocator.free(evidence);

    return .{
        .allocator = allocator,
        .intent = try allocator.dupe(u8, request.intent),
        .materialized_path = materialized_path,
        .build_file_path = build_file_path,
        .command = try allocator.dupe(u8, run_result.command),
        .rank = if (run_result.succeeded()) .truth else .dark_space,
        .exit_code = run_result.exit_code,
        .failure_signal = run_result.failure_signal,
        .duration_ms = run_result.duration_ms,
        .stdout = try allocator.dupe(u8, run_result.stdout),
        .stderr = try allocator.dupe(u8, run_result.stderr),
        .evidence = evidence,
    };
}

fn writeHypothesisBuildFile(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    root_source_rel_path: []const u8,
) !void {
    const contents = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\    const tests = b.addTest(.{{
        \\        .root_source_file = b.path("{s}"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    const run_tests = b.addRunArtifact(tests);
        \\    b.default_step.dependOn(&run_tests.step);
        \\}}
        \\
    , .{root_source_rel_path});
    defer allocator.free(contents);

    var file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

fn validateRelativeZigPath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidHypothesisPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidHypothesisPath;
    if (!std.mem.endsWith(u8, path, ".zig")) return error.InvalidHypothesisPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidHypothesisPath;
        for (part) |byte| {
            if (std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte)) continue;
            switch (byte) {
                '-', '_', '.' => continue,
                else => return error.InvalidHypothesisPath,
            }
        }
    }
}

fn pathWithinRoot(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    return candidate[root.len] == std.fs.path.sep;
}

test "Effector promotes compiling Zig hypothesis to Rank-1" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var result = try testZigHypothesis(allocator, .{ .workspace_root = root, .relative_path = "src/scene_graph_hypothesis.zig", .intent = "first draft of GPU-resident scene graph", .timeout_ms = 12_000, .source = 
        \\const std = @import("std");
        \\
        \\pub const Node = struct {
        \\    id: u32,
        \\    parent: ?u32 = null,
        \\    first_child: ?u32 = null,
        \\    next_sibling: ?u32 = null,
        \\    transform_index: u32 = 0,
        \\    clip_index: u32 = 0,
        \\    material_index: u32 = 0,
        \\};
        \\
        \\pub const SceneGraph = struct {
        \\    nodes: []Node,
        \\};
        \\
        \\test "scene graph node layout is stable enough for GPU upload" {
        \\    try std.testing.expect(@sizeOf(Node) <= 64);
        \\}
        \\
    });
    defer result.deinit();

    try std.testing.expectEqual(HypothesisRank.truth, result.rank);
    try std.testing.expect(result.exit_code != null);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code.?);
}

test "Effector keeps non-compiling Zig hypothesis in Rank-5 dark space" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var result = try testZigHypothesis(allocator, .{ .workspace_root = root, .relative_path = "src/broken_scene_graph.zig", .intent = "broken scene graph draft", .source = 
        \\pub fn broken() void {
        \\    this is not zig
        \\}
        \\
    });
    defer result.deinit();

    try std.testing.expectEqual(HypothesisRank.dark_space, result.rank);
    try std.testing.expect(result.failure_signal != .none);
}
