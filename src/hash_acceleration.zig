const std = @import("std");
const config = @import("config.zig");
const vsa_vulkan = @import("vsa_vulkan.zig");

const BLOCK_BYTES: usize = 4096;
const MAX_GPU_BLOCKS: usize = 32768;

pub const Policy = enum {
    cpu,
    vulkan,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    policy: Policy,
    vulkan: ?*vsa_vulkan.VulkanEngine = null,
    owns_runtime: bool = false,

    pub fn init(allocator: std.mem.Allocator, purpose: []const u8) Context {
        const policy = readPolicy(allocator);
        var ctx = Context{
            .allocator = allocator,
            .policy = policy,
        };
        if (policy != .vulkan) return ctx;

        if (vsa_vulkan.getEngine()) |engine| {
            ctx.vulkan = engine;
            logVulkanReady(engine, purpose);
            return ctx;
        }

        const engine = vsa_vulkan.initRuntime(allocator) catch |err| {
            if (vsa_vulkan.runtimeLogsEnabled()) {
                std.debug.print("[ACCEL] Vulkan acceleration requested for {s}, but initialization failed: {any}. Falling back to CPU hashing/search metadata.\n", .{ purpose, err });
            }
            ctx.policy = .cpu;
            return ctx;
        };
        ctx.vulkan = engine;
        ctx.owns_runtime = true;
        logVulkanReady(engine, purpose);
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        if (self.owns_runtime) vsa_vulkan.deinitRuntime();
        self.* = undefined;
    }

    pub fn activeName(self: *const Context) []const u8 {
        return if (self.vulkan != null and self.policy == .vulkan) "vulkan" else "cpu";
    }
};

pub fn semanticHash64(ctx: ?*Context, allocator: std.mem.Allocator, text: []const u8) !u64 {
    const block_count = (text.len + BLOCK_BYTES - 1) / BLOCK_BYTES;
    if (block_count == 0) return mix64(0xcbf29ce484222325);
    if (block_count > MAX_GPU_BLOCKS) return semanticHash64Cpu(text);

    const seeds = try allocator.alloc(u64, block_count);
    defer allocator.free(seeds);
    for (seeds, 0..) |*seed, idx| {
        const start = idx * BLOCK_BYTES;
        const end = @min(text.len, start + BLOCK_BYTES);
        seed.* = blockSeed(text[start..end], idx);
    }

    if (ctx) |actual_ctx| {
        if (actual_ctx.policy == .vulkan) {
            if (actual_ctx.vulkan) |engine| {
                const job = engine.dispatchSemanticHashBatch(seeds) catch |err| {
                    if (vsa_vulkan.runtimeLogsEnabled()) {
                        std.debug.print("[ACCEL] Vulkan semantic hash dispatch failed: {any}. Falling back to CPU semantic hash.\n", .{err});
                    }
                    return semanticHash64Cpu(text);
                };
                const mixed_words = engine.waitSemanticHashBatch(job) catch |err| {
                    if (vsa_vulkan.runtimeLogsEnabled()) {
                        std.debug.print("[ACCEL] Vulkan semantic hash wait failed: {any}. Falling back to CPU semantic hash.\n", .{err});
                    }
                    return semanticHash64Cpu(text);
                };
                return foldGpuWords(mixed_words, seeds.len);
            }
        }
    }
    return foldCpuSeeds(seeds);
}

pub fn semanticHash64Batch(ctx: ?*Context, allocator: std.mem.Allocator, texts: []const []const u8, out: []u64) !void {
    if (out.len < texts.len) return error.OutputTooSmall;
    if (texts.len == 0) return;
    if (ctx == null or ctx.?.policy != .vulkan or ctx.?.vulkan == null) {
        for (texts, 0..) |text, idx| out[idx] = semanticHash64Cpu(text);
        return;
    }

    var total_blocks: usize = 0;
    for (texts) |text| total_blocks += @max(@as(usize, 1), (text.len + BLOCK_BYTES - 1) / BLOCK_BYTES);
    const seeds = try allocator.alloc(u64, total_blocks);
    defer allocator.free(seeds);
    const starts = try allocator.alloc(usize, texts.len);
    defer allocator.free(starts);
    const counts = try allocator.alloc(usize, texts.len);
    defer allocator.free(counts);

    var cursor: usize = 0;
    for (texts, 0..) |text, text_idx| {
        starts[text_idx] = cursor;
        if (text.len == 0) {
            seeds[cursor] = 0xcbf29ce484222325;
            counts[text_idx] = 1;
            cursor += 1;
            continue;
        }
        var offset: usize = 0;
        var block_idx: usize = 0;
        while (offset < text.len) : (block_idx += 1) {
            const end = @min(text.len, offset + BLOCK_BYTES);
            seeds[cursor] = blockSeed(text[offset..end], block_idx);
            cursor += 1;
            offset = end;
        }
        counts[text_idx] = block_idx;
    }

    const mixed = try allocator.alloc(u64, seeds.len);
    defer allocator.free(mixed);

    var seed_offset: usize = 0;
    while (seed_offset < seeds.len) {
        const batch_len = @min(MAX_GPU_BLOCKS, seeds.len - seed_offset);
        const job = ctx.?.vulkan.?.dispatchSemanticHashBatch(seeds[seed_offset .. seed_offset + batch_len]) catch |err| {
            if (vsa_vulkan.runtimeLogsEnabled()) {
                std.debug.print("[ACCEL] Vulkan batched semantic hash dispatch failed: {any}. Falling back to CPU semantic hashes.\n", .{err});
            }
            for (texts, 0..) |text, idx| out[idx] = semanticHash64Cpu(text);
            return;
        };
        const words = ctx.?.vulkan.?.waitSemanticHashBatch(job) catch |err| {
            if (vsa_vulkan.runtimeLogsEnabled()) {
                std.debug.print("[ACCEL] Vulkan batched semantic hash wait failed: {any}. Falling back to CPU semantic hashes.\n", .{err});
            }
            for (texts, 0..) |text, idx| out[idx] = semanticHash64Cpu(text);
            return;
        };
        for (0..batch_len) |idx| {
            const lo = @as(u64, words[idx * 2]);
            const hi = @as(u64, words[idx * 2 + 1]) << 32;
            mixed[seed_offset + idx] = hi | lo;
        }
        seed_offset += batch_len;
    }

    for (texts, 0..) |_, text_idx| {
        var acc: u64 = 0xcbf29ce484222325;
        for (0..counts[text_idx]) |block_idx| {
            acc ^= mixed[starts[text_idx] + block_idx];
            acc = mix64(acc +% @as(u64, block_idx));
        }
        out[text_idx] = acc;
    }
}

pub fn readPolicy(allocator: std.mem.Allocator) Policy {
    if (std.posix.getenv("GHOST_ACCELERATION")) |value| {
        return parsePolicy(value);
    }

    const config_path = config.getPath(allocator, "ghost_config.toml") catch return .cpu;
    defer allocator.free(config_path);
    const file = std.fs.openFileAbsolute(config_path, .{}) catch return .cpu;
    defer file.close();
    const stat = file.stat() catch return .cpu;
    const bytes = file.readToEndAlloc(allocator, @intCast(@min(stat.size, 64 * 1024))) catch return .cpu;
    defer allocator.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "acceleration")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \r\t");
        if (std.mem.indexOfScalar(u8, value, '#')) |comment| {
            value = std.mem.trim(u8, value[0..comment], " \r\t");
        }
        value = std.mem.trim(u8, value, "\"'");
        return parsePolicy(value);
    }
    return .cpu;
}

fn parsePolicy(value: []const u8) Policy {
    if (std.ascii.eqlIgnoreCase(value, "vulkan")) return .vulkan;
    return .cpu;
}

fn semanticHash64Cpu(text: []const u8) u64 {
    var offset: usize = 0;
    var idx: usize = 0;
    var acc: u64 = 0xcbf29ce484222325;
    while (offset < text.len) : (idx += 1) {
        const end = @min(text.len, offset + BLOCK_BYTES);
        const seed = blockSeed(text[offset..end], idx);
        acc ^= mix64(seed);
        acc = mix64(acc +% @as(u64, idx));
        offset = end;
    }
    return acc;
}

fn foldCpuSeeds(seeds: []const u64) u64 {
    var acc: u64 = 0xcbf29ce484222325;
    for (seeds, 0..) |seed, idx| {
        acc ^= mix64(seed);
        acc = mix64(acc +% @as(u64, idx));
    }
    return acc;
}

fn foldGpuWords(words: []const u32, block_count: usize) u64 {
    var acc: u64 = 0xcbf29ce484222325;
    var idx: usize = 0;
    while (idx < block_count) : (idx += 1) {
        const lo = @as(u64, words[idx * 2]);
        const hi = @as(u64, words[idx * 2 + 1]) << 32;
        acc ^= (hi | lo);
        acc = mix64(acc +% @as(u64, idx));
    }
    return acc;
}

fn blockSeed(block: []const u8, index: usize) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(block);
    var index_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &index_bytes, @as(u64, @intCast(index)), .little);
    hasher.update(&index_bytes);
    return hasher.final();
}

fn mix64(value: u64) u64 {
    var x = value;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn logVulkanReady(engine: *const vsa_vulkan.VulkanEngine, purpose: []const u8) void {
    if (!vsa_vulkan.runtimeLogsEnabled()) return;
    const name = trimDeviceName(engine.device_name[0..]);
    const navi10 = std.ascii.indexOfIgnoreCase(name, "5700 XT") != null or
        std.ascii.indexOfIgnoreCase(name, "Navi 10") != null;
    std.debug.print("[ACCEL] Vulkan Device Initialized for {s}: {s}\n", .{ purpose, name });
    if (!navi10) {
        std.debug.print("[ACCEL] Warning: primary Vulkan device is not reported as RX 5700 XT / Navi 10.\n", .{});
    }
}

fn trimDeviceName(name: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, name, 0) orelse name.len;
    return std.mem.trim(u8, name[0..end], " \r\n\t");
}
