const std = @import("std");
const sandbox = @import("oracle/sandbox.zig");
const swe_harness = @import("ingest/swe_harness.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2 and std.mem.eql(u8, args[1], sandbox.LANDLOCK_EXEC_FLAG)) {
        try sandbox.runLandlockExecFromArgs(allocator, args[2..]);
    }

    var options = swe_harness.Options{};
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--rows")) {
            idx += 1;
            if (idx >= args.len) return error.MissingRowsPath;
            options.rows_path = args[idx];
        } else if (std.mem.eql(u8, arg, "--workspace-root")) {
            idx += 1;
            if (idx >= args.len) return error.MissingWorkspaceRoot;
            options.workspace_root = args[idx];
        } else if (std.mem.eql(u8, arg, "--knowledge-dir")) {
            idx += 1;
            if (idx >= args.len) return error.MissingKnowledgeDir;
            options.knowledge_dir = args[idx];
        } else if (std.mem.eql(u8, arg, "--corpus-dir")) {
            idx += 1;
            if (idx >= args.len) return error.MissingCorpusDir;
            options.corpus_dir = args[idx];
        } else if (std.mem.eql(u8, arg, "--python")) {
            idx += 1;
            if (idx >= args.len) return error.MissingPythonPath;
            options.python_exe = args[idx];
        } else if (std.mem.eql(u8, arg, "--pip")) {
            idx += 1;
            if (idx >= args.len) return error.MissingPipPath;
            options.pip_exe = args[idx];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            idx += 1;
            if (idx >= args.len) return error.MissingLimit;
            options.limit = try std.fmt.parseInt(usize, args[idx], 10);
        } else if (std.mem.eql(u8, arg, "--batch-size")) {
            idx += 1;
            if (idx >= args.len) return error.MissingBatchSize;
            options.limit = try std.fmt.parseInt(usize, args[idx], 10);
        } else if (std.mem.eql(u8, arg, "--cluster-seed")) {
            idx += 1;
            if (idx >= args.len) return error.MissingClusterSeed;
            options.cluster_seed = args[idx];
        } else if (std.mem.eql(u8, arg, "--max-environment-attempts")) {
            idx += 1;
            if (idx >= args.len) return error.MissingEnvironmentAttemptLimit;
            options.max_environment_attempts = try std.fmt.parseInt(u8, args[idx], 10);
        } else if (std.mem.eql(u8, arg, "--max-repair-attempts")) {
            idx += 1;
            if (idx >= args.len) return error.MissingRepairAttemptLimit;
            options.max_repair_attempts = try std.fmt.parseInt(u8, args[idx], 10);
        } else if (std.mem.eql(u8, arg, "--linear")) {
            options.enable_reprioritization = false;
            options.cluster_seed = null;
        } else if (std.mem.eql(u8, arg, "--no-gpu-lattice")) {
            options.enable_gpu_lattice_query = false;
        } else if (std.mem.eql(u8, arg, "--include-unsupported-languages")) {
            options.focus_supported_languages = false;
        } else if (std.mem.eql(u8, arg, "--keep-workspaces")) {
            options.cleanup = false;
        } else if (std.mem.eql(u8, arg, "--no-bootstrap")) {
            options.enable_bootstrap = false;
        } else if (std.mem.eql(u8, arg, "--no-ephemeral-venv")) {
            options.enable_ephemeral_venv = false;
        } else if (std.mem.eql(u8, arg, "--no-preflight-pip")) {
            options.enable_preflight_pip = false;
        } else if (std.mem.eql(u8, arg, "--no-preflight-npm")) {
            options.enable_preflight_npm = false;
        } else {
            return error.UnknownArgument;
        }
    }

    const resolved_python = try resolveToolPath(allocator, options.python_exe);
    defer allocator.free(resolved_python);
    options.python_exe = resolved_python;
    const resolved_pip = try resolveToolPath(allocator, options.pip_exe);
    defer allocator.free(resolved_pip);
    options.pip_exe = resolved_pip;

    var summary = try swe_harness.runRowsFile(allocator, options);
    defer summary.deinit();
    try swe_harness.renderSummaryJson(std.io.getStdOut().writer(), summary);
}

fn resolveToolPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (std.mem.indexOfScalar(u8, path, '/') == null) return allocator.dupe(u8, path);
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn printUsage() !void {
    try std.io.getStdErr().writer().writeAll(
        \\Usage: ghost_swe_harness [options]
        \\
        \\Options:
        \\  --rows <path>             rows.jsonl path
        \\  --limit <n>               number of rows to attempt
        \\  --batch-size <n>          alias for --limit; useful for cluster batches
        \\  --workspace-root <path>   native clone root, default /tmp/ghost/swe
        \\  --knowledge-dir <path>    grounding output directory
        \\  --corpus-dir <path>       offline mirror root; clones file://<path>/<repo-leaf>
        \\  --python <path>           Python executable used to create temp_venv
        \\  --pip <path>              Pip executable for non-ephemeral fallback repairs
        \\  --cluster-seed <text>     prioritize rows by VSA Hamming distance to seed
        \\  --max-environment-attempts <n>
        \\  --max-repair-attempts <n> retry missing dependency repairs, default 3
        \\  --linear                  preserve input row order
        \\  --no-gpu-lattice          keep LATTICE_QUERY reprioritization on CPU
        \\  --include-unsupported-languages
        \\                            attempt non-Python/JS rows instead of skipping them
        \\  --keep-workspaces         do not delete /tmp/ghost/swe/<instance>
        \\  --no-bootstrap            disable environment repair
        \\  --no-ephemeral-venv       use configured Python/Pip directly
        \\  --no-preflight-pip        skip requirements.txt install in temp_venv
        \\  --no-preflight-npm        skip npm install/npm ci before JS tests
        \\
    );
}
