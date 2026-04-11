const std = @import("std");

// --- GHOST ENGINE: DIRECT LINUX/POSIX CORE ---
// Zero-overhead POSIX I/O and memory-mapping layer.

pub const FileHandle = i32;
pub const INVALID_HANDLE: i32 = -1;
pub const SECTOR_SIZE: usize = 4096;

pub const MappedFile = struct {
    file_handle: FileHandle,
    data: []u8,

    pub fn flush(self: *const MappedFile) void {
        _ = std.posix.msync(self.data, std.posix.MS.SYNC) catch {};
    }

    pub fn unmap(self: *MappedFile) void {
        std.posix.munmap(self.data);
        std.posix.close(self.file_handle);
    }
};

pub fn printOut(text: []const u8) void {
    _ = std.posix.write(std.posix.STDOUT_FILENO, text) catch {};
}

pub fn readStdin(buffer: []u8) ![]u8 {
    const bytes_read = try std.posix.read(std.posix.STDIN_FILENO, buffer);
    return buffer[0..bytes_read];
}

var global_silo_root: ?[]const u8 = null;

pub fn getExePath(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fs.selfExePathAlloc(allocator);
}

pub fn getSiloRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (global_silo_root) |r| return r;
    
    const exe_path = try getExePath(allocator);
    defer allocator.free(exe_path);
    
    const bin_dir = std.fs.path.dirname(exe_path) orelse return error.NoDirName;
    const silo_root = std.fs.path.dirname(bin_dir) orelse bin_dir; 
    
    global_silo_root = try allocator.dupe(u8, silo_root);
    return global_silo_root.?;
}

pub fn getAnchorPath(allocator: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(sub_path)) return try allocator.dupe(u8, sub_path);
    const root = try getSiloRoot(allocator);
    return std.fs.path.join(allocator, &[_][]const u8{ root, sub_path });
}

pub fn openForRead(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    return std.posix.open(anchored, .{ .ACCMODE = .RDONLY }, 0) catch error.FileNotFound;
}

pub fn openForWrite(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    return std.posix.open(anchored, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch error.OpenFailed;
}

pub fn closeFile(handle: FileHandle) void {
    std.posix.close(handle);
}

pub fn getFileSize(handle: FileHandle) !u32 {
    const stat = try std.posix.fstat(handle);
    return @intCast(stat.size);
}

pub fn readAll(handle: FileHandle, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try std.posix.read(handle, buffer[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}

pub fn writeAll(handle: FileHandle, data: []const u8) !void {
    var total: usize = 0;
    while (total < data.len) {
        const n = try std.posix.write(handle, data[total..]);
        if (n == 0) break;
        total += n;
    }
}

pub fn createMappedFile(allocator: std.mem.Allocator, path: []const u8, size: usize) !MappedFile {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const fd = try std.posix.open(anchored, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
    try std.posix.ftruncate(fd, size);
    const ptr = try std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    return MappedFile{
        .file_handle = fd,
        .data = ptr,
    };
}

pub fn allocSectorAligned(size: usize) ?[]u8 {
    const aligned_size = (size + SECTOR_SIZE - 1) & ~(SECTOR_SIZE - 1);
    const ptr = std.posix.mmap(null, aligned_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return null;
    return ptr;
}

pub fn freeSectorAligned(buf: []u8) void {
    std.posix.munmap(buf);
}

pub fn getMilliTick() u64 {
    var ts: std.posix.timespec = undefined;
    std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) catch return 0;
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1000000;
}

pub fn sleep(ms: u32) void {
    const ts = std.posix.timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1000000),
    };
    std.posix.nanosleep(&ts, null);
}

pub fn exit(code: u32) noreturn {
    std.posix.exit(@intCast(code));
}

pub fn getArgs(allocator: std.mem.Allocator) ![][]const u8 {
    return std.process.argsAlloc(allocator);
}

pub fn isTrainerActive(allocator: std.mem.Allocator) bool {
    const anchored = getAnchorPath(allocator, "plugins/trainer.lock") catch return false;
    defer allocator.free(anchored);
    const fd = std.posix.open(anchored, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    std.posix.close(fd);
    return true;
}

pub fn findPluginFiles(allocator: std.mem.Allocator) ![][]const u8 {
    var results = std.ArrayList([]const u8).init(allocator);
    const anchored_plugins = try getAnchorPath(allocator, "plugins");
    defer allocator.free(anchored_plugins);
    
    var dir = std.fs.openDirAbsolute(anchored_plugins, .{ .iterate = true }) catch return results.toOwnedSlice();
    defer dir.close();
    
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sigil")) {
            const joined = try std.fs.path.join(allocator, &[_][]const u8{ "plugins", entry.name });
            defer allocator.free(joined);
            const full_path = try getAnchorPath(allocator, joined);
            try results.append(full_path);
        }
    }
    return results.toOwnedSlice();
}

pub fn findNativePlugins(allocator: std.mem.Allocator) ![][]const u8 {
    var results = std.ArrayList([]const u8).init(allocator);
    const anchored_plugins = try getAnchorPath(allocator, "plugins");
    defer allocator.free(anchored_plugins);
    
    var dir = std.fs.openDirAbsolute(anchored_plugins, .{ .iterate = true }) catch return results.toOwnedSlice();
    defer dir.close();
    
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and (std.mem.endsWith(u8, entry.name, ".so") or std.mem.endsWith(u8, entry.name, ".dylib"))) {
            const joined = try std.fs.path.join(allocator, &[_][]const u8{ "plugins", entry.name });
            defer allocator.free(joined);
            const full_path = try getAnchorPath(allocator, joined);
            try results.append(full_path);
        }
    }
    return results.toOwnedSlice();
}

pub const NativeLibrary = struct {
    handle: *anyopaque,

    pub fn open(path: []const u8) !NativeLibrary {
        const h = std.posix.dlopen(path, std.posix.RTLD.LAZY) catch return error.LibraryLoadFailed;
        return NativeLibrary{ .handle = h };
    }

    pub fn lookup(self: NativeLibrary, T: type, name: [:0]const u8) ?T {
        const addr = std.posix.dlsym(self.handle, name) catch return null;
        return @as(T, @ptrCast(addr));
    }

    pub fn close(self: NativeLibrary) void {
        _ = std.posix.dlclose(self.handle);
    }
};
