const std = @import("std");

// --- GHOST MANIFOLD: WEB-SCALE PERSISTENCE ---
// Principle: Memory-Mapped Voxel Grid.
// Target: 10GB Hard Limit.

pub const VoxelCount = 1000000;
pub const StoragePath = "state/ghost_voxels.bin";

pub const Manifold = struct {
    data: []i128,
    file: std.fs.File,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Manifold {
        var file = try std.fs.cwd().createFile(StoragePath, .{ .read = true, .truncate = false });
        try file.setEndPos(VoxelCount * @sizeOf(i128));
        
        const data = try std.posix.mmap(
            null,
            VoxelCount * @sizeOf(i128),
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            std.posix.MAP.SHARED,
            file.handle,
            0,
        );

        return .{
            .data = std.mem.bytesAsSlice(i128, data),
            .file = file,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Manifold) void {
        std.posix.munmap(std.mem.sliceAsBytes(self.data));
        self.file.close();
    }

    pub fn get(self: *const Manifold, coord: u64) i128 {
        return self.data[coord % VoxelCount];
    }

    pub fn set(self: *Manifold, coord: u64, val: i128) void {
        self.data[coord % VoxelCount] = val;
    }

    pub fn add(self: *Manifold, coord: u64, delta: i128) void {
        self.data[coord % VoxelCount] = self.data[coord % VoxelCount] +% delta;
    }
};
