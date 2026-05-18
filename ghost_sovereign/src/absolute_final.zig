const std = @import("std");

// --- GHOST ABSOLUTE: THE PRIMITIVE RESONANCE (Mark: 0xBE496F1695F15480) ---
// Principle: Bit-Spill Logic with Unrolled 8-Walker Parallelism.
// Objective: Achieve 500+ MB/s without SIMD or @bitReverse.

pub const AbsoluteCore = struct {
    // Manifold of 64-bit voxels (2^21 * 8 bytes = 16MB)
    pub const ManifoldSize = 2097152; 
    pub const AddressMask = ManifoldSize - 1;
    // 32KB Window (4096 voxels)
    pub const WindowSize = 4096;
    pub const WindowMask = WindowSize - 1;
    pub const BatchSize = 1024;

    field: []u64,
    file: std.fs.File,
    kernel: u64 = 0xBE496F1695F15480,

    pub fn init(size_bytes: usize) !AbsoluteCore {
        const count = std.math.ceilPowerOfTwo(usize, size_bytes / 8) catch ManifoldSize;
        var file = try std.fs.cwd().createFile("state/ghost_absolute.bin", .{ .read = true, .truncate = false });
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
        var s: u64 = 0xBE496F1695F15480;
        for (field) |*v| {
            s = (s ^ (s >> 31)) ^ 0x9E3779B97F4A7C15;
            v.* = s;
        }

        return .{
            .field = field,
            .file = file,
        };
    }

    pub fn deinit(self: *AbsoluteCore) void {
        std.posix.munmap(@alignCast(std.mem.sliceAsBytes(self.field)));
        self.file.close();
    }

    /// PRIMITIVE INGESTION: 8-Walker Bit-Spill (No SIMD, No BitReverse).
    /// This uses the CPU's out-of-order execution units by unrolling 8 independent streams.
    pub fn ingest(self: *AbsoluteCore, data: []const u8) void {
        var m1: usize = self.kernel;
        var m2: usize = m1 ^ 0xAAAAAAAAAAAAAAAA;
        var m3: usize = m1 ^ 0x5555555555555555;
        var m4: usize = m1 ^ 0x3333333333333333;
        var m5: usize = m1 ^ 0xCCCCCCCCCCCCCCCC;
        var m6: usize = m1 ^ 0x6666666666666666;
        var m7: usize = m1 ^ 0x9999999999999999;
        var m8: usize = m1 ^ 0x7777777777777777;

        const field_mask = AddressMask & ~@as(usize, WindowMask);
        var i: usize = 0;
        const total_len = data.len;

        while (i < total_len) {
            const window_start = m1 & field_mask;
            const window = self.field[window_start .. window_start + WindowSize];

            const batch_limit = if (i + BatchSize < total_len) BatchSize else total_len - i;
            const batch = data[i .. i + batch_limit];

            var j: usize = 0;
            // Hot Loop: 8-Walker Bit-Spill Unrolled
            // This physically saturates the CPU pipeline without using SIMD 'vectors'.
            while (j + 8 <= batch.len) : (j += 8) {
                // 1. COLLISION (XOR)
                const b1 = @as(u64, batch[j]);
                const b2 = @as(u64, batch[j+1]);
                const b3 = @as(u64, batch[j+2]);
                const b4 = @as(u64, batch[j+3]);
                const b5 = @as(u64, batch[j+4]);
                const b6 = @as(u64, batch[j+5]);
                const b7 = @as(u64, batch[j+6]);
                const b8 = @as(u64, batch[j+7]);

                // 2. MIXING: Prime-Weighted Bit-Rotates (1-cycle instruction)
                // This replaces the expensive software bit-reverse.
                window[(m1 ^ b1) & WindowMask] ^= std.math.rotl(u64, b1, 7);
                window[(m2 ^ b2) & WindowMask] ^= std.math.rotl(u64, b2, 11);
                window[(m3 ^ b3) & WindowMask] ^= std.math.rotl(u64, b3, 13);
                window[(m4 ^ b4) & WindowMask] ^= std.math.rotl(u64, b4, 17);
                window[(m5 ^ b5) & WindowMask] ^= std.math.rotl(u64, b5, 19);
                window[(m6 ^ b6) & WindowMask] ^= std.math.rotl(u64, b6, 23);
                window[(m7 ^ b7) & WindowMask] ^= std.math.rotl(u64, b7, 29);
                window[(m8 ^ b8) & WindowMask] ^= std.math.rotl(u64, b8, 31);

                // 3. STOCHASTIC HOP: Update walkers
                m1 = std.math.rotl(usize, m1 ^ @as(usize, @truncate(window[(m1 ^ b1) & WindowMask])), 1);
                m2 = std.math.rotl(usize, m2 ^ @as(usize, @truncate(window[(m2 ^ b2) & WindowMask])), 2);
                m3 = std.math.rotl(usize, m3 ^ @as(usize, @truncate(window[(m3 ^ b3) & WindowMask])), 3);
                m4 = std.math.rotl(usize, m4 ^ @as(usize, @truncate(window[(m4 ^ b4) & WindowMask])), 4);
                m5 = std.math.rotl(usize, m5 ^ @as(usize, @truncate(window[(m5 ^ b5) & WindowMask])), 5);
                m6 = std.math.rotl(usize, m6 ^ @as(usize, @truncate(window[(m6 ^ b6) & WindowMask])), 6);
                m7 = std.math.rotl(usize, m7 ^ @as(usize, @truncate(window[(m7 ^ b7) & WindowMask])), 7);
                m8 = std.math.rotl(usize, m8 ^ @as(usize, @truncate(window[(m8 ^ b8) & WindowMask])), 8);
            }
            i += batch_limit;
        }
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
            const raw_voxel = self.field[mark & AddressMask];
            // High 32 bits for the dictionary index — uncorrelated with the
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
};