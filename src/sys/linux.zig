const std = @import("std");

// --- GHOST ENGINE: DIRECT LINUX CORE ---
// Zero-overhead Linux syscall layer.
// V32: Implement O_DIRECT for kernel-bypass NVMe performance.

const linux = std.os.linux;

pub const FileHandle = i32;
pub const INVALID_HANDLE: i32 = -1;

pub const O_DIRECT: u32 = 0o040000;
pub const NVME_DIRECT_FLAGS: u32 = linux.O.RDWR | linux.O.CREAT | O_DIRECT | linux.O.DSYNC;
pub const SECTOR_SIZE: usize = 4096;

pub const MappedFile = struct {
    file_handle: FileHandle,
    data: []u8,

    pub fn flush(self: *const MappedFile) void {
        // V32: Direct DMA flush. Bypasses standard OS buffering.
        _ = linux.msync(self.data.ptr, self.data.len, linux.MS.SYNC);
        _ = linux.fdatasync(self.file_handle);
    }

    pub fn unmap(self: *MappedFile) void {
        _ = linux.munmap(self.data.ptr, self.data.len);
        _ = linux.close(self.file_handle);
    }
};

pub fn directRead(handle: FileHandle, offset: u64, buffer: []u8) !void {
    const n = linux.pread(handle, buffer.ptr, buffer.len, offset);
    if (n < 0) return error.DirectReadFailed;
}

pub fn directWrite(handle: FileHandle, offset: u64, buffer: []const u8) !void {
    const n = linux.pwrite(handle, buffer.ptr, buffer.len, offset);
    if (n < 0) return error.DirectWriteFailed;
}

pub fn getMilliTick() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.tv_sec) * 1000 + @divFloor(ts.tv_nsec, 1_000_000));
}

var silo_root_buf: [1024]u8 = undefined;
var silo_root_len: usize = 0;

pub fn getSiloRoot(allocator: std.mem.Allocator) ![]const u8 {
    _ = allocator;
    if (silo_root_len > 0) return silo_root_buf[0..silo_root_len];

    var buf: [1024]u8 = undefined;
    const len = linux.readlink("/proc/self/exe", &buf, 1024);
    if (len < 0) return error.ProcSelfExeFailed;
    
    const exe_path = buf[0..@intCast(len)];
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.NoDirName;

    const silo_root = if (std.mem.endsWith(u8, exe_dir, "/bin"))
        std.fs.path.dirname(exe_dir) orelse exe_dir
    else
        exe_dir;

    if (silo_root.len > silo_root_buf.len) return error.PathTooLong;
    @memcpy(silo_root_buf[0..silo_root.len], silo_root);
    silo_root_len = silo_root.len;
    
    std.debug.print("[SYS] Silo root anchored: {s}\n", .{silo_root_buf[0..silo_root_len]});
    return silo_root_buf[0..silo_root_len];
}

pub fn getAnchorPath(allocator: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(sub_path)) return try allocator.dupe(u8, sub_path);
    const root = try getSiloRoot(allocator);
    return std.fs.path.join(allocator, &[_][]const u8{ root, sub_path });
}

pub fn openForWrite(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const fd = linux.open(anchored.ptr, linux.O.RDWR | linux.O.CREAT, 0o644);
    if (fd < 0) return error.OpenFailed;
    return @intCast(fd);
}

pub fn openForWriteAppend(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const fd = linux.open(anchored.ptr, NVME_DIRECT_FLAGS, 0o644);
    if (fd < 0) return error.OpenFailed;
    _ = linux.lseek(fd, 0, linux.SEEK.END);
    return @intCast(fd);
}

pub fn openForRead(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const fd = linux.open(anchored.ptr, linux.O.RDONLY, 0);
    if (fd < 0) return error.FileNotFound;
    return @intCast(fd);
}

pub fn openForReadWrite(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const fd = linux.open(anchored.ptr, linux.O.RDWR, 0);
    if (fd < 0) return error.OpenFailed;
    return @intCast(fd);
}

pub fn createMappedFile(allocator: std.mem.Allocator, path: []const u8, size: usize) !MappedFile {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    
    const fd = linux.open(anchored.ptr, linux.O.RDWR | linux.O.CREAT, 0o644);
    if (fd < 0) return error.CreateFailed;

    // Ensure size
    _ = linux.ftruncate(fd, size);

    const ptr = linux.mmap(null, size, linux.PROT.READ | linux.PROT.WRITE, linux.MAP.SHARED, fd, 0);
    if (ptr == linux.MAP.FAILED) {
        _ = linux.close(fd);
        return error.MapViewFailed;
    }

    return MappedFile{ .file_handle = @intCast(fd), .data = @as([*]u8, @ptrCast(ptr))[0..size] };
}

pub fn closeFile(handle: FileHandle) void { _ = linux.close(handle); }

pub fn getFileSize(handle: FileHandle) !u32 {
    var st: linux.Stat = undefined;
    if (linux.fstat(handle, &st) < 0) return error.GetSizeFailed;
    return @intCast(st.size);
}

pub fn writeAll(handle: FileHandle, data: []const u8) !void {
    var total: usize = 0;
    while (total < data.len) {
        const n = linux.write(handle, data[total..].ptr, data.len - total);
        if (n <= 0) return error.WriteFailed;
        total += @intCast(n);
    }
}

pub fn readAll(handle: FileHandle, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = linux.read(handle, buffer[total..].ptr, buffer.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

pub fn allocSectorAligned(size: usize) ?[]u8 {
    const aligned_size = (size + SECTOR_SIZE - 1) & ~(SECTOR_SIZE - 1);
    // On Linux, posix_memalign is standard, but for syscall level we use mmap with anonymous mapping
    const ptr = linux.mmap(null, aligned_size, linux.PROT.READ | linux.PROT.WRITE, linux.MAP.PRIVATE | linux.MAP.ANONYMOUS, -1, 0);
    if (ptr == linux.MAP.FAILED) return null;
    return @as([*]u8, @ptrCast(ptr))[0..aligned_size];
}

pub fn freeSectorAligned(buf: []u8) void { _ = linux.munmap(buf.ptr, buf.len); }

pub fn printOut(text: []const u8) void { _ = linux.write(1, text.ptr, text.len); }

pub fn sleep(ms: u32) void {
    const ts = linux.timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1000000),
    };
    _ = linux.nanosleep(&ts, null);
}

pub fn exit(code: u32) noreturn { linux.exit(code); }

pub fn acquireTrainerLock() bool {
    // Linux equivalent: Flocking a well-known lock file
    const path = "/tmp/ghost_trainer.lock";
    const fd = linux.open(path.ptr, linux.O.RDWR | linux.O.CREAT, 0o666);
    if (fd < 0) return false;
    
    const FL_LOCK_EX = 2;
    const FL_LOCK_NB = 4;
    // We use fcntl or flock here. Flock is simpler for this purpose.
    if (linux.flock(@intCast(fd), FL_LOCK_EX | FL_LOCK_NB) < 0) {
        _ = linux.close(fd);
        return false;
    }
    return true; 
}

pub fn isTrainerActive(allocator: std.mem.Allocator) bool {
    _ = allocator;
    const path = "/tmp/ghost_trainer.lock";
    const fd = linux.open(path.ptr, linux.O.RDWR, 0);
    if (fd < 0) return false;
    defer _ = linux.close(fd);
    
    const FL_LOCK_EX = 2;
    const FL_LOCK_NB = 4;
    const FL_LOCK_UN = 8;
    
    // Try to lock. If it fails, someone else has it.
    if (linux.flock(@intCast(fd), FL_LOCK_EX | FL_LOCK_NB) < 0) {
        return true;
    }
    // If we got it, it wasn't active. Release and return false.
    _ = linux.flock(@intCast(fd), FL_LOCK_UN);
    return false;
}
