const std = @import("std");
const config = @import("../config.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/file.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

pub const FileHandle = c_int;
pub const INVALID_HANDLE: FileHandle = -1;

pub const SECTOR_SIZE: usize = 4096;
pub const O_DIRECT: c_int = if (@hasDecl(c, "O_DIRECT")) c.O_DIRECT else 0;

const open_write_flags: c_int = c.O_RDWR | c.O_CREAT | c.O_TRUNC;
const open_append_flags: c_int = c.O_RDWR | c.O_CREAT | c.O_APPEND |
    (if (@hasDecl(c, "O_DSYNC")) c.O_DSYNC else 0) |
    O_DIRECT;
const mmap_access = c.PROT_READ | c.PROT_WRITE;
const mmap_shared = c.MAP_SHARED;

const MappingBacking = enum {
    file,
    shared_memory,
    temporary_file,
};

pub const MappedFile = struct {
    file_handle: FileHandle,
    data: []u8,
    backing: MappingBacking = .file,

    pub fn flush(self: *const MappedFile) !void {
        try flushSlice(self.data);
        if (self.backing == .file and self.file_handle >= 0) {
            if (c.fdatasync(self.file_handle) != 0) return error.FlushFileBuffersFailed;
        }
    }

    pub fn unmap(self: *MappedFile) void {
        if (self.data.len != 0) {
            _ = c.munmap(@ptrCast(self.data.ptr), self.data.len);
        }
        if (self.file_handle >= 0) {
            _ = c.close(self.file_handle);
        }
        self.* = .{
            .file_handle = INVALID_HANDLE,
            .data = &[_]u8{},
            .backing = .file,
        };
    }
};

fn toOwnedZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return try allocator.dupeZ(u8, path);
}

fn isUnifiedLatticePath(path: []const u8, size: usize) bool {
    return size == config.UNIFIED_SIZE_BYTES and
        std.mem.eql(u8, std.fs.path.basename(path), "unified_lattice.bin");
}

fn wantsSharedLattice() bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOST_LATTICE_SHM") catch return false;
    defer std.heap.page_allocator.free(value);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

fn maybeAdviseHugePages(ptr: *anyopaque, size: usize) void {
    if (@hasDecl(c, "MADV_HUGEPAGE")) {
        _ = c.madvise(ptr, size, c.MADV_HUGEPAGE);
    }
}

fn ensureSized(fd: FileHandle, size: usize) !void {
    if (c.ftruncate(fd, @intCast(size)) != 0) return error.ResizeFailed;
}

fn mapFd(fd: FileHandle, size: usize, advise_hugepages: bool) ![]u8 {
    const raw_ptr = c.mmap(null, size, mmap_access, mmap_shared, fd, 0);
    if (@intFromPtr(raw_ptr) == @intFromPtr(c.MAP_FAILED)) return error.MapViewFailed;
    const ptr = raw_ptr orelse return error.MapViewFailed;
    if (advise_hugepages) maybeAdviseHugePages(ptr, size);
    return @as([*]u8, @ptrCast(@alignCast(ptr)))[0..size];
}

fn createSharedLatticeMapping(size: usize) !MappedFile {
    const shm_name = "/ghost_engine_unified_lattice";
    const fd = c.shm_open(shm_name, c.O_RDWR | c.O_CREAT, @as(c.mode_t, 0o666));
    if (fd < 0) return error.CreateFailed;
    errdefer _ = c.close(fd);

    try ensureSized(fd, size);
    const data = try mapFd(fd, size, true);
    return .{
        .file_handle = fd,
        .data = data,
        .backing = .shared_memory,
    };
}

pub fn flushSlice(bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (c.msync(@ptrCast(@constCast(bytes.ptr)), bytes.len, c.MS_SYNC) != 0) return error.FlushViewFailed;
}

pub fn directRead(handle: FileHandle, offset: u64, buffer: []u8) !void {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = c.pread(
            handle,
            @ptrCast(buffer[total..].ptr),
            buffer.len - total,
            @intCast(offset + total),
        );
        if (n <= 0) return error.DirectReadFailed;
        total += @intCast(n);
    }
}

pub fn directWrite(handle: FileHandle, offset: u64, buffer: []const u8) !void {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = c.pwrite(
            handle,
            @ptrCast(buffer[total..].ptr),
            buffer.len - total,
            @intCast(offset + total),
        );
        if (n <= 0) return error.DirectWriteFailed;
        total += @intCast(n);
    }
}

pub fn getMilliTick() u64 {
    return @intCast(std.time.milliTimestamp());
}

pub fn getExePath(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = c.readlink("/proc/self/exe", &buf, buf.len);
    if (len < 0) return error.ProcSelfExeFailed;
    return try allocator.dupe(u8, buf[0..@intCast(len)]);
}

var silo_root_buf: [std.fs.max_path_bytes]u8 = undefined;
var silo_root_len: usize = 0;

pub fn getSiloRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (silo_root_len > 0) return silo_root_buf[0..silo_root_len];

    const exe_path = try getExePath(allocator);
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.NoDirName;
    const silo_root = if (std.mem.endsWith(u8, exe_dir, "/bin"))
        std.fs.path.dirname(exe_dir) orelse exe_dir
    else
        exe_dir;

    if (silo_root.len > silo_root_buf.len) return error.PathTooLong;
    @memcpy(silo_root_buf[0..silo_root.len], silo_root);
    silo_root_len = silo_root.len;
    return silo_root_buf[0..silo_root_len];
}

pub fn getAnchorPath(allocator: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(sub_path)) return try allocator.dupe(u8, sub_path);
    const root = try getSiloRoot(allocator);
    return try std.fs.path.join(allocator, &[_][]const u8{ root, sub_path });
}

pub fn makePath(allocator: std.mem.Allocator, path: []const u8) !void {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    try std.fs.cwd().makePath(anchored);
}

fn collectMatchingFiles(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    suffix: []const u8,
) ![][]const u8 {
    var results = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (results.items) |path| allocator.free(path);
        results.deinit();
    }

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch return results.toOwnedSlice();
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, entry.name });
        try results.append(full_path);
    }

    return results.toOwnedSlice();
}

pub fn findPluginFiles(allocator: std.mem.Allocator) ![][]const u8 {
    const anchored = try getAnchorPath(allocator, "plugins");
    defer allocator.free(anchored);
    return collectMatchingFiles(allocator, anchored, ".sigil");
}

pub fn findCorpusFiles(allocator: std.mem.Allocator) ![][]const u8 {
    var results = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (results.items) |path| allocator.free(path);
        results.deinit();
    }

    const anchored = try getAnchorPath(allocator, "corpus");
    defer allocator.free(anchored);
    const project_corpus = try std.fs.path.join(allocator, &[_][]const u8{ @import("build_options").project_root, "corpus" });
    defer allocator.free(project_corpus);

    for ([_][]const u8{ anchored, project_corpus }) |candidate| {
        const matches = try collectMatchingFiles(allocator, candidate, ".txt");
        defer {
            for (matches) |path| allocator.free(path);
            allocator.free(matches);
        }
        for (matches) |path| {
            try results.append(try allocator.dupe(u8, path));
        }
        if (results.items.len > 0) break;
    }

    return results.toOwnedSlice();
}

fn openAnchored(allocator: std.mem.Allocator, path: []const u8, flags: c_int, mode: c.mode_t) !FileHandle {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const anchored_z = try toOwnedZ(allocator, anchored);
    defer allocator.free(anchored_z);

    const fd = c.open(anchored_z.ptr, flags, mode);
    if (fd < 0) return error.OpenFailed;
    return fd;
}

pub fn openForWrite(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    return try openAnchored(allocator, path, open_write_flags, 0o644);
}

pub fn openForWriteAppend(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    return try openAnchored(allocator, path, open_append_flags, 0o644);
}

pub fn openForRead(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const anchored_z = try toOwnedZ(allocator, anchored);
    defer allocator.free(anchored_z);

    const fd = c.open(anchored_z.ptr, c.O_RDONLY, @as(c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    return fd;
}

pub fn openForReadWrite(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    return try openAnchored(allocator, path, c.O_RDWR, 0o644);
}

pub fn openDirectory(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    return try openAnchored(allocator, path, c.O_RDONLY | c.O_DIRECTORY, 0);
}

pub fn createMappedFile(allocator: std.mem.Allocator, path: []const u8, size: usize) !MappedFile {
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);

    if (isUnifiedLatticePath(anchored, size) and wantsSharedLattice()) {
        return createSharedLatticeMapping(size);
    }

    const anchored_z = try toOwnedZ(allocator, anchored);
    defer allocator.free(anchored_z);

    const fd = c.open(anchored_z.ptr, c.O_RDWR | c.O_CREAT, @as(c.mode_t, 0o644));
    if (fd < 0) return error.CreateFailed;
    errdefer _ = c.close(fd);

    try ensureSized(fd, size);
    const data = try mapFd(fd, size, isUnifiedLatticePath(anchored, size));
    return .{
        .file_handle = fd,
        .data = data,
        .backing = .file,
    };
}

pub fn createTemporaryMappedFile(allocator: std.mem.Allocator, prefix: []const u8, size: usize) !MappedFile {
    const template = try std.fmt.allocPrintZ(allocator, "/tmp/{s}-XXXXXX", .{prefix});
    defer allocator.free(template);

    const fd = c.mkstemp(template.ptr);
    if (fd < 0) return error.CreateFailed;
    errdefer _ = c.close(fd);

    if (c.unlink(template.ptr) != 0) return error.CreateFailed;

    try ensureSized(fd, size);
    const data = try mapFd(fd, size, false);
    return .{
        .file_handle = fd,
        .data = data,
        .backing = .temporary_file,
    };
}

pub fn closeFile(handle: FileHandle) void {
    _ = c.close(handle);
}

pub fn getFileSize(handle: FileHandle) !u32 {
    const st = std.posix.fstat(handle) catch return error.GetSizeFailed;
    return @intCast(st.size);
}

pub fn writeAll(handle: FileHandle, data: []const u8) !void {
    var total: usize = 0;
    while (total < data.len) {
        const n = c.write(handle, @ptrCast(data[total..].ptr), data.len - total);
        if (n <= 0) return error.WriteFailed;
        total += @intCast(n);
    }
}

pub fn readAll(handle: FileHandle, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = c.read(handle, @ptrCast(buffer[total..].ptr), buffer.len - total);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        total += @intCast(n);
    }
    return total;
}

pub fn allocSectorAligned(size: usize) ?[]u8 {
    const aligned_size = std.mem.alignForward(usize, size, SECTOR_SIZE);
    const ptr = c.mmap(null, aligned_size, mmap_access, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, 0);
    if (@intFromPtr(ptr) == @intFromPtr(c.MAP_FAILED)) return null;
    return @as([*]u8, @ptrCast(@alignCast(ptr)))[0..aligned_size];
}

pub fn freeSectorAligned(buf: []u8) void {
    if (buf.len == 0) return;
    _ = c.munmap(@ptrCast(buf.ptr), buf.len);
}

pub fn printOut(text: []const u8) void {
    _ = c.write(1, @ptrCast(text.ptr), text.len);
}

pub fn readStdin(buffer: []u8) ![]u8 {
    const n = c.read(0, @ptrCast(buffer.ptr), buffer.len);
    if (n < 0) return error.ReadFailed;
    return buffer[0..@intCast(n)];
}

pub fn pollStdin() bool {
    var fds = [_]c.struct_pollfd{.{
        .fd = 0,
        .events = c.POLLIN,
        .revents = 0,
    }};
    return c.poll(&fds[0], @intCast(fds.len), 0) > 0 and (fds[0].revents & c.POLLIN) != 0;
}

pub fn sleep(ms: u32) void {
    std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
}

pub fn exit(code: u32) noreturn {
    std.process.exit(@truncate(code));
}

pub fn getArgs(allocator: std.mem.Allocator) ![][]const u8 {
    const raw_args = try std.process.argsAlloc(allocator);
    const args = try allocator.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| args[i] = arg;
    return args;
}

pub fn acquireTrainerLock() bool {
    const fd = c.open("/tmp/ghost_trainer.lock", c.O_RDWR | c.O_CREAT, @as(c.mode_t, 0o666));
    if (fd < 0) return false;
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        _ = c.close(fd);
        return false;
    }
    return true;
}

pub fn isTrainerActive(_: std.mem.Allocator) bool {
    const fd = c.open("/tmp/ghost_trainer.lock", c.O_RDWR | c.O_CREAT, @as(c.mode_t, 0o666));
    if (fd < 0) return false;
    defer _ = c.close(fd);

    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return true;
    _ = c.flock(fd, c.LOCK_UN);
    return false;
}
