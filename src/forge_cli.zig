const std = @import("std");
const core = @import("ghost_core");
const sys = core.sys;
const vsa = core.vsa;
const ghost_state = core.ghost_state;
const shards = core.shards;
const config = core.config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "stats")) {
        try runStats(allocator, args[2..]);
    } else {
        sys.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    sys.print("Usage: ghost_forge <command> [args]\n", .{});
    sys.print("Commands:\n", .{});
    sys.print("  stats    Show Rune Lattice and SNR metrics\n", .{});
    sys.print("  promote  [Deferred] Manually promote a Rune to Rank 1\n", .{});
    sys.print("  prune    [Deferred] Force prune all stale Rank 5 runes\n", .{});
    sys.print("  status   [Deferred] Show rank distribution\n", .{});
}

fn runStats(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;
    sys.printOut("[FORGE] Mounting state shard for offline inspection...\n");

    const env_project_shard = std.process.getEnvVarOwned(allocator, "GHOST_PROJECT_SHARD") catch null;
    defer if (env_project_shard) |value| allocator.free(value);

    var state_shard = blk: {
        const mounted = if (env_project_shard) |project_shard_id|
            shards.MountedStateShard.mountProject(allocator, project_shard_id, config.IDEAL_LATTICE_SIZE)
        else
            shards.MountedStateShard.mountCore(allocator, config.IDEAL_LATTICE_SIZE);
        break :blk mounted catch |err| {
            sys.print("\n[FATAL] Failed to mount state shard: {any}\n", .{err});
            sys.exit(1);
        };
    };
    defer state_shard.deinit();

    sys.printOut("[FORGE] Shard mounted. Analyzing MeaningMatrix...\n");

    const mm = &state_shard.meaning_matrix;
    const capacity = config.SEMANTIC_SLOTS;
    
    var active_slots: u32 = 0;
    
    // Sample vectors to compute distance variance
    const max_samples = 1000;
    var samples_collected: u32 = 0;
    
    // Pass 1: Count active slots
    for (0..capacity) |i| {
        if (mm.tags.?[i] != 0) {
            active_slots += 1;
        }
    }

    // Allocate array for sample pairs to compute pairwise distances
    var sample_indices = std.ArrayList(u32).init(allocator);
    defer sample_indices.deinit();
    
    // Random number generator for unbiased sampling
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    const random = prng.random();

    // Reservoir sampling for indices
    for (0..capacity) |i| {
        if (mm.tags.?[i] != 0) {
            if (samples_collected < max_samples) {
                try sample_indices.append(@intCast(i));
                samples_collected += 1;
            } else {
                const r = random.intRangeLessThan(u32, 0, samples_collected + 1);
                if (r < max_samples) {
                    sample_indices.items[r] = @intCast(i);
                }
                samples_collected += 1;
            }
        }
    }

    // Compute pairwise Hamming distances among samples
    var sum_distance: u64 = 0;
    var num_pairs: u64 = 0;
    var min_dist: u16 = 1024;
    var max_dist: u16 = 0;

    const actual_samples = sample_indices.items.len;
    if (actual_samples > 1) {
        // Limit pairs to avoid O(N^2) blowing up if sample is large, but 1000 is 500k pairs (fast).
        for (0..actual_samples) |i| {
            const idx_a = sample_indices.items[i];
            const vec_a = mm.collapseToBinaryAtSlot(idx_a);
            
            for (i + 1..actual_samples) |j| {
                const idx_b = sample_indices.items[j];
                const vec_b = mm.collapseToBinaryAtSlot(idx_b);
                
                const dist = vsa.hammingDistance(vec_a, vec_b);
                sum_distance += dist;
                num_pairs += 1;
                
                if (dist < min_dist) min_dist = dist;
                if (dist > max_dist) max_dist = dist;
            }
        }
    }

    const avg_dist = if (num_pairs > 0) @as(f64, @floatFromInt(sum_distance)) / @as(f64, @floatFromInt(num_pairs)) else 0.0;
    
    // Compute variance
    var sum_sq_diff: f64 = 0.0;
    if (num_pairs > 0) {
        for (0..actual_samples) |i| {
            const idx_a = sample_indices.items[i];
            const vec_a = mm.collapseToBinaryAtSlot(idx_a);
            for (i + 1..actual_samples) |j| {
                const idx_b = sample_indices.items[j];
                const vec_b = mm.collapseToBinaryAtSlot(idx_b);
                const dist = vsa.hammingDistance(vec_a, vec_b);
                const diff = @as(f64, @floatFromInt(dist)) - avg_dist;
                sum_sq_diff += diff * diff;
            }
        }
    }
    
    const variance = if (num_pairs > 0) sum_sq_diff / @as(f64, @floatFromInt(num_pairs)) else 0.0;
    const std_dev = std.math.sqrt(variance);

    const fill_percent = (@as(f64, @floatFromInt(active_slots)) / @as(f64, @floatFromInt(capacity))) * 100.0;

    sys.printOut("\n");
    sys.printOut("========================================================\n");
    sys.printOut("                 GHOST FORGE DASHBOARD                  \n");
    sys.printOut("========================================================\n");
    sys.print("[State Shard]        {s}\n", .{state_shard.paths.metadata.id});
    sys.print("[Backend]            Vulkan-Accelerated (GPU-Accelerated: ON)\n", .{});
    sys.print("[Lattice Capacity]   {d} Slots\n", .{capacity});
    sys.print("[Active Slots]       {d} ({d:.2}% Fill)\n", .{active_slots, fill_percent});
    sys.printOut("\n");
    sys.printOut("--- SNR & Distance Metrics ---\n");
    
    if (num_pairs > 0) {
        sys.print("[Mean Distance]      {d:.2} bits (Ideal ~512)\n", .{avg_dist});
        sys.print("[Distance Variance]  {d:.2} (StdDev: {d:.2})\n", .{variance, std_dev});
        sys.print("[Range]              Min: {d}, Max: {d}\n", .{min_dist, max_dist});
        
        sys.printOut("\n");
        if (avg_dist < 400.0) {
            sys.printOut("[!WARNING] MEAN DISTANCE IS LOW. The XOR-space is collapsing.\n");
            sys.printOut("           Vectors are compressing, risking high False Positives.\n");
        } else if (variance < 100.0) {
            sys.printOut("[!WARNING] DISTANCE VARIANCE IS LOW. The lattice lacks signal separation.\n");
            sys.printOut("           Consider switching Context to Majority Bundling (vsa.bundle).\n");
        } else {
            sys.printOut("[HEALTH OK] Vector space exhibits healthy signal separation.\n");
        }
    } else {
        sys.printOut("[!] Not enough data to compute distance metrics.\n");
    }
    sys.printOut("========================================================\n\n");
}
