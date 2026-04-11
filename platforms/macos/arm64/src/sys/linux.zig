const std = @import("std");
const os = std.os;

pub const FileHandle = i32;
pub const INVALID_HANDLE: i32 = -1;
pub const SECTOR_SIZE: usize = 4096;

pub const MappedFile = struct {
    file_handle: FileHandle,
    data: []u8,

    pub fn flush(self: *const MappedFile) void {
        _ = std.os.msync(self.data, std.os.MS.SYNC) catch {};
    }

    pub fn unmap(self: *MappedFile) void {
        std.os.munmap(self.data);
        std.os.close(self.file_handle);
    }
};

pub fn printOut(text: []const u8) void {
    _ = std.os.write(std.os.STDOUT_FILENO, text) catch {};
}

pub fn readStdin(buffer: []u8) ![]u8 {
    const bytes_read = try std.os.read(std.os.STDIN_FILENO, buffer);
    return buffer[0..bytes_read];
}

pub fn openForRead(path: []const u8) !FileHandle {
    return std.os.open(path, std.os.O.RDONLY, 0) catch error.FileNotFound;
}

pub fn openForWrite(path: []const u8) !FileHandle {
    return std.os.open(path, std.os.O.WRONLY | std.os.O.CREAT | std.os.O.TRUNC, 0o644) catch error.OpenFailed;
}

pub fn closeFile(handle: FileHandle) void {
    std.os.close(handle);
}

pub fn getFileSize(handle: FileHandle) !u32 {
    const stat = try std.os.fstat(handle);
    return @intCast(stat.size);
}

pub fn readAll(handle: FileHandle, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try std.os.read(handle, buffer[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}

pub fn writeAll(handle: FileHandle, data: []const u8) !void {
    var total: usize = 0;
    while (total < data.len) {
        const n = try std.os.write(handle, data[total..]);
        if (n == 0) break;
        total += n;
    }
}

pub fn createMappedFile(path: []const u8, size: usize) !MappedFile {
    const fd = try std.os.open(path, std.os.O.RDWR | std.os.O.CREAT, 0o644);
    try std.os.ftruncate(fd, size);
    const ptr = try std.os.mmap(null, size, std.os.PROT.READ | std.os.PROT.WRITE, std.os.MAP.SHARED, fd, 0);
    return MappedFile{
        .file_handle = fd,
        .data = ptr,
    };
}

pub fn allocSectorAligned(size: usize) ?[]u8 {
    const aligned_size = (size + SECTOR_SIZE - 1) & ~(SECTOR_SIZE - 1);
    // On Linux, mmap is always page-aligned (usually 4KB)
    const ptr = std.os.mmap(null, aligned_size, std.os.PROT.READ | std.os.PROT.WRITE, std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS, -1, 0) catch return null;
    return ptr;
}

pub fn freeSectorAligned(buf: []u8) void {
    std.os.munmap(buf);
}

pub fn getMilliTick() u64 {
    var ts: std.os.timespec = undefined;
    std.os.clock_gettime(std.os.CLOCK.MONOTONIC, &ts) catch return 0;
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1000000;
}

pub fn sleep(ms: u32) void {
    std.os.nanosleep(ms / 1000, (ms % 1000) * 1000000);
}

pub fn exit(code: u32) noreturn {
    std.os.exit(@intCast(code));
}

pub fn getArgs(allocator: std.mem.Allocator) ![][]const u8 {
    return std.process.argsAlloc(allocator);
}

pub fn isTrainerActive() bool {
    const fd = std.os.open("plugins/trainer.lock", std.os.O.RDONLY, 0) catch return false;
    std.os.close(fd);
    return true;
}

pub fn findPluginFiles(allocator: std.mem.Allocator) ![][]const u8 {
    var results = std.ArrayList([]const u8).init(allocator);
    var dir = std.fs.cwd().openIterableDir("plugins", .{}) catch return results.toOwnedSlice();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sigil")) {
            const path = try std.fmt.allocPrint(allocator, "plugins/{s}", .{entry.name});
            try results.append(path);
        }
    }
    return results.toOwnedSlice();
}
