const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const shards = @import("shards.zig");

pub const benchmark_results_rel_dir = "benchmarks/ghost_serious_workflows/results";
pub const canonical_linux_benchmark_json = benchmark_results_rel_dir ++ "/latest-linux.json";
pub const canonical_linux_benchmark_md = benchmark_results_rel_dir ++ "/latest-linux.md";

pub fn isCanonicalBenchmarkReport(rel_path: []const u8) bool {
    return std.mem.eql(u8, rel_path, canonical_linux_benchmark_json) or
        std.mem.eql(u8, rel_path, canonical_linux_benchmark_md);
}

fn containsPathSegment(path: []const u8, segment: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, segment)) return true;
    }
    return false;
}

test "repo hygiene: test state is isolated under state/test" {
    try std.testing.expect(config.TEST_MODE);
    try std.testing.expectEqualStrings("state/test", config.STATE_SUBDIR);
    try std.testing.expect(!std.fs.path.isAbsolute(config.STATE_SUBDIR));

    var core = try shards.resolveCoreMetadata(std.testing.allocator);
    defer core.deinit();
    try std.testing.expect(std.mem.startsWith(u8, core.metadata.rel_root, "state/test/shards/core/core"));

    var project = try shards.resolveProjectMetadata(std.testing.allocator, "repo-hygiene-project");
    defer project.deinit();
    try std.testing.expect(std.mem.startsWith(u8, project.metadata.rel_root, "state/test/shards/projects/"));
}

test "repo hygiene: shard outputs use designated state subtrees" {
    var project = try shards.resolveProjectMetadata(std.testing.allocator, "repo-hygiene-paths");
    defer project.deinit();

    var paths = try shards.resolvePaths(std.testing.allocator, project.metadata);
    defer paths.deinit();

    try std.testing.expect(containsPathSegment(paths.code_intel_cache_abs_path, "state"));
    try std.testing.expect(containsPathSegment(paths.patch_candidates_root_abs_path, "patch_candidates"));
    try std.testing.expect(containsPathSegment(paths.task_sessions_root_abs_path, "tasks"));
    try std.testing.expect(containsPathSegment(paths.corpus_ingest_live_abs_path, "corpus_ingest"));
}

test "repo hygiene: benchmark report policy is canonical latest linux only" {
    if (builtin.os.tag == .linux) {
        try std.testing.expect(isCanonicalBenchmarkReport(canonical_linux_benchmark_json));
        try std.testing.expect(isCanonicalBenchmarkReport(canonical_linux_benchmark_md));
    }

    try std.testing.expect(!isCanonicalBenchmarkReport("benchmarks/ghost_serious_workflows/results/run-2026-04-24.json"));
    try std.testing.expect(!isCanonicalBenchmarkReport("benchmarks/ghost_serious_workflows/results/partial.json.tmp"));
    try std.testing.expect(!isCanonicalBenchmarkReport("benchmarks/ghost_serious_workflows/results/latest.md"));
}
