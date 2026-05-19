const std = @import("std");
const absolute = @import("absolute_final");

const CycleSnapshot = struct {
    probe_index: usize,
    probe_voxel: u64,
    edge_fingerprint: u64,
    dominant_delta: u64,
};

fn captureCycle(
    state_path: []const u8,
    payload: []const u8,
    ingest: bool,
    probe_override: ?usize,
) !CycleSnapshot {
    var core = try absolute.AbsoluteCore.initAt(state_path, 16 * 1024 * 1024);
    defer core.deinit();

    var report = absolute.AbsoluteCore.IngestReport{};
    if (ingest) report = core.ingestMeasured(payload);

    const probe_index = probe_override orelse report.dominant_edge;
    const snap = CycleSnapshot{
        .probe_index = probe_index,
        .probe_voxel = core.field[probe_index],
        .edge_fingerprint = report.edge_fingerprint,
        .dominant_delta = report.dominant_delta,
    };
    try core.flush();
    return snap;
}

fn deleteIfExists(path: []const u8) !void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var state_path: []const u8 = "state/persistence_check.bin";
    var cold_path: []const u8 = "state/persistence_check_cold.bin";

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--state=")) {
            state_path = arg["--state=".len..];
        } else if (std.mem.startsWith(u8, arg, "--cold=")) {
            cold_path = arg["--cold=".len..];
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writer().writeAll(
                \\usage: persistence_check [--state path] [--cold path]
                \\
                \\Verifies that the mmap-backed manifold survives process restart.
                \\Writes data, closes, reopens, and checks sampled voxels match.
                \\
            );
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    const stdout = std.io.getStdOut().writer();
    try deleteIfExists(state_path);
    try deleteIfExists(cold_path);

    try stdout.writeAll("### PERSISTENCE CHECK ###\n");
    try stdout.print("warm path: {s}\n", .{state_path});
    try stdout.print("cold path: {s}\n\n", .{cold_path});

    const ingest_payload = "phase A: write the manifold with a known prompt that produces a non-trivial dominant_edge index inside the active window";
    const phase_a = try captureCycle(state_path, ingest_payload, true, null);
    try stdout.print("Phase A (cold init + ingest):\n", .{});
    try stdout.print("  edge_fingerprint   = 0x{X}\n", .{phase_a.edge_fingerprint});
    try stdout.print("  dominant_delta     = 0x{X}\n", .{phase_a.dominant_delta});
    try stdout.print("  dominant_edge idx  = {d}\n", .{phase_a.probe_index});
    try stdout.print("  field[probe]       = 0x{X}\n\n", .{phase_a.probe_voxel});

    const phase_b = try captureCycle(state_path, "", false, phase_a.probe_index);
    try stdout.print("Phase B (reopen, no ingest, probe same index):\n", .{});
    try stdout.print("  field[probe]       = 0x{X}\n\n", .{phase_b.probe_voxel});

    const phase_c = try captureCycle(cold_path, "", false, phase_a.probe_index);
    try stdout.print("Phase C (cold baseline, fresh path, no ingest, same probe idx):\n", .{});
    try stdout.print("  field[probe]       = 0x{X}\n\n", .{phase_c.probe_voxel});

    const warm_matches_phase_a = phase_b.probe_voxel == phase_a.probe_voxel;
    const warm_differs_from_cold = phase_b.probe_voxel != phase_c.probe_voxel;

    try stdout.writeAll("--- VERDICT ---\n");
    if (warm_matches_phase_a) {
        try stdout.writeAll("[PASS] Reopened voxel equals post-ingest voxel (mmap state survived restart).\n");
    } else {
        try stdout.writeAll("[FAIL] Reopened voxel DIFFERS from post-ingest voxel (state was lost).\n");
    }
    if (warm_differs_from_cold) {
        try stdout.writeAll("[PASS] Reopened state differs from a fresh seed (ingest's writes are observable).\n");
    } else {
        try stdout.writeAll("[FAIL] Reopened state matches a freshly seeded path (writes did not change the probe voxel).\n");
    }

    const phase_d = try captureCycle(state_path, "phase D: subsequent ingest after reopen", true, null);
    const fingerprint_advanced = phase_d.edge_fingerprint != phase_a.edge_fingerprint;
    try stdout.print("\nPhase D (reopen + ingest different prompt):\n", .{});
    try stdout.print("  edge_fingerprint   = 0x{X}\n", .{phase_d.edge_fingerprint});
    if (fingerprint_advanced) {
        try stdout.writeAll("[PASS] Second ingest produced a new edge_fingerprint (manifold accepted further writes).\n");
    } else {
        try stdout.writeAll("[FAIL] Second ingest produced the original fingerprint (writes did not stick).\n");
    }

    if (warm_matches_phase_a and warm_differs_from_cold and fingerprint_advanced) {
        try stdout.writeAll("\nOVERALL: PASS — persistence verified across restart cycle.\n");
    } else {
        try stdout.writeAll("\nOVERALL: FAIL — persistence is not behaving as expected; see flags above.\n");
        std.process.exit(1);
    }
}
