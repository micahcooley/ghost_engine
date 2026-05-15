const std = @import("std");
const vsa = @import("hypervector.zig");

pub const LatticeHeader = extern struct {
    magic: [4]u8,
    version: u32,
    count: u32,
    capacity: u32,
};

pub const MmapLattice = struct {
    file: std.fs.File,
    lock_file: std.fs.File,
    mapped_memory: []align(std.heap.page_size_min) u8,
    header: *LatticeHeader,
    vectors: [*]vsa.HyperVector,

    pub fn initOrOpen(path: []const u8, initial_capacity: u32) !MmapLattice {
        var lock_file = try openLockFile(path);
        errdefer lock_file.close();
        try lock_file.lock(.exclusive);
        defer lock_file.unlock();

        var file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try createNew(path, initial_capacity),
            else => return err,
        };
        errdefer file.close();
        return try mapExisting(file, lock_file);
    }

    fn openLockFile(path: []const u8) !std.fs.File {
        var lock_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(&lock_path_buf, "{s}.rwlock", .{path});
        return std.fs.createFileAbsolute(lock_path, .{ .read = true, .truncate = false }) catch |err| switch (err) {
            error.PathAlreadyExists => try std.fs.openFileAbsolute(lock_path, .{ .mode = .read_write }),
            else => return err,
        };
    }

    fn createNew(path: []const u8, capacity: u32) !std.fs.File {
        const file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
        const size = @sizeOf(LatticeHeader) + (capacity * @sizeOf(vsa.HyperVector));
        try file.setEndPos(size);
        const header = LatticeHeader{
            .magic = .{ 'L', 'A', 'T', 'T' },
            .version = 1,
            .count = 0,
            .capacity = capacity,
        };
        try file.seekTo(0);
        try file.writer().writeStruct(header);
        return file;
    }

    fn mapExisting(file: std.fs.File, lock_file: std.fs.File) !MmapLattice {
        const stat = try file.stat();
        const memory = try std.posix.mmap(
            null,
            stat.size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        const header = @as(*LatticeHeader, @ptrCast(memory.ptr));
        if (!std.mem.eql(u8, &header.magic, "LATT")) return error.InvalidMagic;

        const vectors_ptr = @as([*]vsa.HyperVector, @ptrCast(@alignCast(memory.ptr + @sizeOf(LatticeHeader))));

        return MmapLattice{
            .file = file,
            .lock_file = lock_file,
            .mapped_memory = memory,
            .header = header,
            .vectors = vectors_ptr,
        };
    }

    pub fn deinit(self: *MmapLattice) void {
        std.posix.munmap(self.mapped_memory);
        self.file.close();
        self.lock_file.close();
    }

    pub const LockGuard = struct {
        lock_file: std.fs.File,
        active: bool = true,

        pub fn release(self: *LockGuard) void {
            if (!self.active) return;
            self.lock_file.unlock();
            self.active = false;
        }
    };

    pub fn lockForRead(self: *const MmapLattice) !LockGuard {
        try self.lock_file.lock(.shared);
        return .{ .lock_file = self.lock_file };
    }

    pub fn lockForWrite(self: *MmapLattice) !LockGuard {
        try self.lock_file.lock(.exclusive);
        return .{ .lock_file = self.lock_file };
    }

    pub fn tryLockForWrite(self: *MmapLattice) !?LockGuard {
        if (!try self.lock_file.tryLock(.exclusive)) return null;
        return .{ .lock_file = self.lock_file };
    }

    pub fn append(self: *MmapLattice, vector: vsa.HyperVector) !u32 {
        var guard = try self.lockForWrite();
        defer guard.release();

        if (self.header.count >= self.header.capacity) {
            return error.LatticeFull;
        }
        const index = self.header.count;
        self.vectors[index] = vector;
        @atomicStore(u32, &self.header.count, index + 1, .seq_cst);

        return index;
    }

    pub fn get(self: *const MmapLattice, index: u32) !vsa.HyperVector {
        var guard = try self.lockForRead();
        defer guard.release();

        if (index >= self.header.count) return error.IndexOutOfBounds;
        return self.vectors[index];
    }

    pub fn findNearest(self: *const MmapLattice, query: vsa.HyperVector, threshold_distance: u16) ?u32 {
        var guard = self.lockForRead() catch return null;
        defer guard.release();

        var best_dist: u16 = 1025;
        var best_idx: ?u32 = null;

        for (0..self.header.count) |i| {
            const dist = vsa.hammingDistance(query, self.vectors[i]);
            if (dist < best_dist) {
                best_dist = dist;
                best_idx = @intCast(i);
            }
        }

        if (best_dist <= threshold_distance) {
            return best_idx;
        }
        return null;
    }
};

test "mmap lattice append and read are guarded by file rwlock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "lattice.bin" });
    defer allocator.free(path);

    var writer = try MmapLattice.initOrOpen(path, 4);
    defer writer.deinit();
    var peer = try MmapLattice.initOrOpen(path, 4);
    defer peer.deinit();

    var read_guard = try writer.lockForRead();
    try std.testing.expect((try peer.tryLockForWrite()) == null);
    read_guard.release();

    const write_guard = try peer.tryLockForWrite();
    try std.testing.expect(write_guard != null);
    var active_write_guard = write_guard.?;
    active_write_guard.release();

    const vector = vsa.deterministic(42);
    const index = try writer.append(vector);
    try std.testing.expectEqual(@as(u32, 0), index);
    try std.testing.expectEqual(vector, try peer.get(index));
}

test "mmap lattice allows concurrent shared readers but excludes writers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "shared-readers.bin" });
    defer allocator.free(path);

    var first = try MmapLattice.initOrOpen(path, 2);
    defer first.deinit();
    var second = try MmapLattice.initOrOpen(path, 2);
    defer second.deinit();

    var first_read = try first.lockForRead();
    defer first_read.release();
    var second_read = try second.lockForRead();
    defer second_read.release();

    try std.testing.expect((try first.tryLockForWrite()) == null);
}
