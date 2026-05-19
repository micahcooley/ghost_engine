const std = @import("std");

// --- GHOST ABSOLUTE: SHARDED DICTIONARY WALKER ---
// Principle: mmap-backed bit-mixed lookups with 8 independent 4KB shards.
// Objective: make the core measurable without SIMD or bit reversal.

pub const AbsoluteCore = struct {
    pub const DefaultStatePath = "state/ghost_absolute.bin";
    // Manifold of 64-bit voxels (2^21 * 8 bytes = 16MB)
    pub const ManifoldSize = 2097152;
    pub const AddressMask = ManifoldSize - 1;
    pub const ShardCount = 8;
    pub const ShardBytes = 4 * 1024;
    pub const ShardSize = ShardBytes / @sizeOf(u64);
    pub const ShardMask = ShardSize - 1;
    // 32KB L1 window: 8 shards x 4KB. Each walker owns exactly one shard.
    pub const WindowSize = ShardCount * ShardSize;
    pub const WindowMask = WindowSize - 1;
    pub const BatchSize = 1024;

    pub const IngestReport = struct {
        bytes: usize = 0,
        writes: usize = 0,
        dominant_edge: usize = 0,
        dominant_delta: u64 = 0,
        edge_fingerprint: u64 = 0xBE496F1695F15480,
    };

    field: []u64,
    file: std.fs.File,
    field_count: usize,
    address_mask: usize,
    kernel: u64 = 0xBE496F1695F15480,

    pub fn init(size_bytes: usize) !AbsoluteCore {
        return initAt(DefaultStatePath, size_bytes);
    }

    pub fn initAt(state_path: []const u8, size_bytes: usize) !AbsoluteCore {
        if (std.fs.path.dirname(state_path)) |dir| {
            if (dir.len != 0) {
                if (std.fs.path.isAbsolute(dir)) {
                    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                } else {
                    try std.fs.cwd().makePath(dir);
                }
            }
        }
        const requested_count = @max(WindowSize, size_bytes / @sizeOf(u64));
        const count = std.math.ceilPowerOfTwo(usize, requested_count) catch ManifoldSize;
        var file = if (std.fs.path.isAbsolute(state_path))
            try std.fs.createFileAbsolute(state_path, .{ .read = true, .truncate = false })
        else
            try std.fs.cwd().createFile(state_path, .{ .read = true, .truncate = false });
        try file.setEndPos(count * 8);

        const data = try std.posix.mmap(
            null,
            count * 8,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );

        const field = std.mem.bytesAsSlice(u64, data);
        seedField(field);

        return .{
            .field = field,
            .file = file,
            .field_count = count,
            .address_mask = count - 1,
        };
    }

    pub fn deinit(self: *AbsoluteCore) void {
        std.posix.munmap(@alignCast(std.mem.sliceAsBytes(self.field)));
        self.file.close();
    }

    pub fn reset(self: *AbsoluteCore) void {
        seedField(self.field);
    }

    /// 8-walker bit-spill ingestion. The 32KB active window is split into
    /// 8 independent 4KB shards, so m1..m8 never write each other's slots.
    pub fn ingest(self: *AbsoluteCore, data: []const u8) void {
        _ = self.ingestMeasured(data);
    }

    pub fn ingestMeasured(self: *AbsoluteCore, data: []const u8) IngestReport {
        var report = IngestReport{ .bytes = data.len };
        var m1: usize = @truncate(self.kernel);
        var m2: usize = m1 ^ 0xAAAAAAAAAAAAAAAA;
        var m3: usize = m1 ^ 0x5555555555555555;
        var m4: usize = m1 ^ 0x3333333333333333;
        var m5: usize = m1 ^ 0xCCCCCCCCCCCCCCCC;
        var m6: usize = m1 ^ 0x6666666666666666;
        var m7: usize = m1 ^ 0x9999999999999999;
        var m8: usize = m1 ^ 0x7777777777777777;

        const field_mask = self.address_mask & ~@as(usize, WindowMask);
        var i: usize = 0;
        const total_len = data.len;

        while (i < total_len) {
            const window_start = m1 & field_mask;
            const window = self.field[window_start .. window_start + WindowSize];

            const batch_limit = if (i + BatchSize < total_len) BatchSize else total_len - i;
            const batch = data[i .. i + batch_limit];

            var j: usize = 0;
            while (j + 8 <= batch.len) : (j += 8) {
                mixWalker(window, window_start, 0, &m1, batch[j], 7, 0xBE496F1695F15480, &report);
                mixWalker(window, window_start, 1, &m2, batch[j + 1], 11, 0xC2B2AE3D27D4EB4F, &report);
                mixWalker(window, window_start, 2, &m3, batch[j + 2], 13, 0x165667B19E3779F9, &report);
                mixWalker(window, window_start, 3, &m4, batch[j + 3], 17, 0x85EBCA77C2B2AE63, &report);
                mixWalker(window, window_start, 4, &m5, batch[j + 4], 19, 0x27D4EB2F165667C5, &report);
                mixWalker(window, window_start, 5, &m6, batch[j + 5], 23, 0x94D049BB133111EB, &report);
                mixWalker(window, window_start, 6, &m7, batch[j + 6], 29, 0xD6E8FEB86659FD93, &report);
                mixWalker(window, window_start, 7, &m8, batch[j + 7], 31, 0x9E3779B97F4A7C15, &report);
            }
            if (j < batch.len) {
                mixWalker(window, window_start, 0, &m1, batch[j], 7, 0xBE496F1695F15480, &report);
                j += 1;
            }
            if (j < batch.len) {
                mixWalker(window, window_start, 1, &m2, batch[j], 11, 0xC2B2AE3D27D4EB4F, &report);
                j += 1;
            }
            if (j < batch.len) {
                mixWalker(window, window_start, 2, &m3, batch[j], 13, 0x165667B19E3779F9, &report);
                j += 1;
            }
            if (j < batch.len) {
                mixWalker(window, window_start, 3, &m4, batch[j], 17, 0x85EBCA77C2B2AE63, &report);
                j += 1;
            }
            if (j < batch.len) {
                mixWalker(window, window_start, 4, &m5, batch[j], 19, 0x27D4EB2F165667C5, &report);
                j += 1;
            }
            if (j < batch.len) {
                mixWalker(window, window_start, 5, &m6, batch[j], 23, 0x94D049BB133111EB, &report);
                j += 1;
            }
            if (j < batch.len) {
                mixWalker(window, window_start, 6, &m7, batch[j], 29, 0xD6E8FEB86659FD93, &report);
                j += 1;
            }
            if (j < batch.len) {
                mixWalker(window, window_start, 7, &m8, batch[j], 31, 0x9E3779B97F4A7C15, &report);
            }
            i += batch_limit;
        }
        return report;
    }

    pub fn resolve(self: *AbsoluteCore, intent: []const u8, dictionary: []const []const u8, writer: anytype) !void {
        self.ingest(intent);

        // Mark starts from a prompt-derived hash so different intents produce
        // different walks even when the field state shares structure.
        var h: u64 = self.kernel;
        for (intent) |b| h = (h ^ b) *% 0x100000001B3;
        var mark: usize = @as(usize, self.kernel) ^ @as(usize, h);

        var words: usize = 0;
        while (words < 20) : (words += 1) {
            const raw_voxel = self.field[mark & self.address_mask];
            // High 32 bits for the dictionary index: uncorrelated with the
            // rotation/walk math, so word selection isn't locked to the orbit.
            const word_idx = @as(usize, @truncate(raw_voxel >> 32)) % dictionary.len;
            try writer.writeAll(dictionary[word_idx]);
            if (words < 19) try writer.writeByte(' ');
            // Mix the iteration counter into the mark update so forward motion
            // is guaranteed even if raw_voxel happens to repeat across steps.
            mark = std.math.rotl(usize, mark ^ raw_voxel ^ @as(usize, words), 31);
        }
        try writer.writeAll(".\n");
    }

    fn seedField(field: []u64) void {
        var s: u64 = 0xBE496F1695F15480;
        for (field) |*v| {
            s = (s ^ (s >> 31)) ^ 0x9E3779B97F4A7C15;
            v.* = s;
        }
    }

    fn mixWalker(
        window: []u64,
        window_start: usize,
        comptime shard: usize,
        m: *usize,
        b: u8,
        rot: u6,
        lane_salt: u64,
        report: *IngestReport,
    ) void {
        const idx = (shard * ShardSize) + ((m.* ^ @as(usize, b)) & ShardMask);
        const prior = window[idx];
        const b64 = @as(u64, b);
        const spread = b64 ^ (b64 << 8) ^ (b64 << 16) ^ (b64 << 24) ^ (b64 << 32) ^ (b64 << 40) ^ (b64 << 48) ^ (b64 << 56);
        const mixed = std.math.rotl(u64, spread ^ lane_salt, rot);
        const next = prior ^ mixed;
        window[idx] = next;

        const absolute_idx = window_start + idx;
        const delta = prior ^ next;
        report.writes += 1;
        if (delta > report.dominant_delta) {
            report.dominant_delta = delta;
            report.dominant_edge = absolute_idx;
        }
        report.edge_fingerprint = std.math.rotl(
            u64,
            report.edge_fingerprint ^ @as(u64, @intCast(absolute_idx)) ^ next ^ mixed,
            rot,
        );

        m.* = std.math.rotl(
            usize,
            m.* ^ @as(usize, @truncate(prior)) ^ @as(usize, @truncate(mixed)) ^ absolute_idx,
            rot,
        );
    }
};
