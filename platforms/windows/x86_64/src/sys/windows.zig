const std = @import("std");

// --- GHOST ENGINE: DIRECT WINAPI CORE ---
// Zero-overhead Windows Kernel32 I/O and memory-mapping layer.

extern "kernel32" fn CreateFileW(n: [*:0]const u16, a: u32, s: u32, p: ?*anyopaque, d: u32, f: u32, t: ?*anyopaque) callconv(.winapi) *anyopaque;
extern "kernel32" fn WriteFile(h: *anyopaque, b: [*]const u8, n: u32, w: ?*u32, o: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: *anyopaque, b: [*]u8, n: u32, r: ?*u32, o: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetFileSizeEx(h: *anyopaque, lp: *i64) callconv(.winapi) i32;
extern "kernel32" fn CreateFileMappingW(h: *anyopaque, a: ?*anyopaque, p: u32, sh: u32, sl: u32, n: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn MapViewOfFile(m: *anyopaque, a: u32, oh: u32, ol: u32, s: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn FlushViewOfFile(lpBaseAddress: *const anyopaque, dwNumberOfBytesToFlush: usize) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) *anyopaque;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn ExitProcess(uExitCode: u32) callconv(.winapi) noreturn;
extern "kernel32" fn SetFilePointerEx(h: *anyopaque, dist: i64, new_pos: ?*i64, method: u32) callconv(.winapi) i32;
extern "kernel32" fn SetEndOfFile(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: u32, flProtect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(lpAddress: *anyopaque, dwSize: usize, dwFreeType: u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hLibModule: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*:0]u16, nSize: u32) callconv(.winapi) u32;



pub const WIN32_MEMORY_RANGE_ENTRY = extern struct {
    VirtualAddress: ?*anyopaque,
    NumberOfBytes: usize,
};

extern "kernel32" fn PrefetchVirtualMemory(hProcess: *anyopaque, NumberOfOffsets: usize, VirtualAddresses: [*]const WIN32_MEMORY_RANGE_ENTRY, Flags: u32) callconv(.winapi) i32;

pub fn prefetchMemory(addr: ?*anyopaque, size: usize) void {
    if (addr == null) return;
    const entry = WIN32_MEMORY_RANGE_ENTRY{
        .VirtualAddress = addr,
        .NumberOfBytes = size,
    };
    _ = PrefetchVirtualMemory(GetCurrentProcess(), 1, @as([*]const WIN32_MEMORY_RANGE_ENTRY, @ptrCast(&entry)), 0);
}

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: u64,
    ftLastAccessTime: u64,
    ftLastWriteTime: u64,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.c) *anyopaque;
extern "kernel32" fn FindNextFileW(hFindFile: *anyopaque, lpFindFileData: *WIN32_FIND_DATAW) callconv(.c) i32;
extern "kernel32" fn FindClose(hFindFile: *anyopaque) callconv(.c) i32;
pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.c) i32;

var global_silo_root: ?[]const u8 = null;

pub fn getExePath(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [1024]u16 = undefined;
    const len = GetModuleFileNameW(null, @as([*:0]u16, @ptrCast(&buf)), 1024);
    if (len == 0) return error.GetModuleFileNameFailed;

    
    // Convert UTF-16 to UTF-8
    const out_buf = try allocator.alloc(u8, len * 3);
    errdefer allocator.free(out_buf);
    
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const c = buf[i];
        if (c < 0x80) { 
            out_buf[out_idx] = @intCast(c); out_idx += 1; 
        } else if (c < 0x800) { 
            out_buf[out_idx] = @intCast(0xC0 | (c >> 6)); out_idx += 1;
            out_buf[out_idx] = @intCast(0x80 | (c & 0x3F)); out_idx += 1; 
        } else {
            out_buf[out_idx] = @intCast(0xE0 | (c >> 12)); out_idx += 1;
            out_buf[out_idx] = @intCast(0x80 | ((c >> 6) & 0x3F)); out_idx += 1;
            out_buf[out_idx] = @intCast(0x80 | (c & 0x3F)); out_idx += 1;
        }
    }
    return out_buf[0..out_idx];
}


pub fn getSiloRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (global_silo_root) |r| return r;
    
    const exe_path = try getExePath(allocator);
    defer allocator.free(exe_path);
    
    const bin_dir = std.fs.path.dirname(exe_path) orelse return error.NoDirName;
    const silo_root = std.fs.path.dirname(bin_dir) orelse bin_dir; // Step back from bin/
    
    global_silo_root = try allocator.dupe(u8, silo_root);
    return global_silo_root.?;
}

pub fn getAnchorPath(allocator: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(sub_path)) return try allocator.dupe(u8, sub_path);
    const root = try getSiloRoot(allocator);
    return std.fs.path.join(allocator, &[_][]const u8{ root, sub_path });
}



pub fn findPluginFiles(allocator: std.mem.Allocator) ![][]const u8 {
    var results = std.ArrayListUnmanaged([]const u8).empty;
    var wbuf: [1024]u16 = undefined;
    const anchored_plugins = try getAnchorPath(allocator, "plugins\\*");
    defer allocator.free(anchored_plugins);
    const search_path = utf8ToW(anchored_plugins, &wbuf);
    
    var find_data: WIN32_FIND_DATAW = undefined;
    const hFind = FindFirstFileW(search_path, &find_data);
    if (hFind == INVALID_HANDLE) return results.toOwnedSlice(allocator);
    defer _ = FindClose(hFind);

    while (true) {
        var len: usize = 0;
        while (len < 260 and find_data.cFileName[len] != 0) len += 1;
        const utf16_slice = find_data.cFileName[0..len];
        
        // Convert UTF-16 to UTF-8
        var out_buf: [1024]u8 = undefined;
        var out_idx: usize = 0;
        for (utf16_slice) |c| {
            if (c < 0x80) { out_buf[out_idx] = @intCast(c); out_idx += 1; }
            else if (c < 0x800) { out_buf[out_idx] = @intCast(0xC0 | (c >> 6)); out_idx += 1; out_buf[out_idx] = @intCast(0x80 | (c & 0x3F)); out_idx += 1; }
        }

        const name = out_buf[0..out_idx];
        if (std.mem.endsWith(u8, name, ".sigil")) {
            const joined = try std.fs.path.join(allocator, &[_][]const u8{ "plugins", name });
            defer allocator.free(joined);
            const full_path = try getAnchorPath(allocator, joined);
            try results.append(allocator, full_path);
        }

        if (FindNextFileW(hFind, &find_data) == 0) break;
    }

    return results.toOwnedSlice(allocator);
}

pub fn findNativePlugins(allocator: std.mem.Allocator) ![][]const u8 {
    var results = std.ArrayListUnmanaged([]const u8).empty;
    var wbuf: [1024]u16 = undefined;
    const anchored_plugins = try getAnchorPath(allocator, "plugins\\*");
    defer allocator.free(anchored_plugins);
    const search_path = utf8ToW(anchored_plugins, &wbuf);
    
    var find_data: WIN32_FIND_DATAW = undefined;
    const hFind = FindFirstFileW(search_path, &find_data);
    if (hFind == INVALID_HANDLE) return results.toOwnedSlice(allocator);
    defer _ = FindClose(hFind);

    while (true) {
        var len: usize = 0;
        while (len < 260 and find_data.cFileName[len] != 0) len += 1;
        const utf16_slice = find_data.cFileName[0..len];
        
        // Convert UTF-16 to UTF-8
        var out_buf: [1024]u8 = undefined;
        var out_idx: usize = 0;
        for (utf16_slice) |c| {
            if (c < 0x80) { out_buf[out_idx] = @intCast(c); out_idx += 1; }
            else if (c < 0x800) { out_buf[out_idx] = @intCast(0xC0 | (c >> 6)); out_idx += 1; out_buf[out_idx] = @intCast(0x80 | (c & 0x3F)); out_idx += 1; }
        }

        const name = out_buf[0..out_idx];
        const is_dll = std.mem.endsWith(u8, name, ".dll");
        const is_so = std.mem.endsWith(u8, name, ".so");
        if (is_dll or is_so) {
            const joined = try std.fs.path.join(allocator, &[_][]const u8{ "plugins", name });
            defer allocator.free(joined);
            const full_path = try getAnchorPath(allocator, joined);
            try results.append(allocator, full_path);
        }

        if (FindNextFileW(hFind, &find_data) == 0) break;
    }

    return results.toOwnedSlice(allocator);
}

pub fn isTrainerActive(allocator: std.mem.Allocator) bool {
    var wbuf: [1024]u16 = undefined;
    const anchored = getAnchorPath(allocator, "plugins\\trainer.lock") catch return false;
    defer allocator.free(anchored);
    const h = CreateFileW(utf8ToW(anchored, &wbuf), 0x80000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 3, 0x80, null);
    if (h != INVALID_HANDLE) {
        _ = CloseHandle(h);
        return true;
    }
    return false;
}


pub const FileHandle = *anyopaque;
pub const INVALID_HANDLE = @as(*anyopaque, @ptrFromInt(0xFFFFFFFFFFFFFFFF));

pub const NVME_DIRECT_FLAGS: u32 = 0x20000000 | 0x80000000;
pub const SECTOR_SIZE: usize = 4096;
const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;

pub const MappedFile = struct {
    file_handle: FileHandle,
    map_handle: FileHandle,
    data: []u8,

    pub fn flush(self: *const MappedFile) void {
        _ = FlushViewOfFile(self.data.ptr, 0);
    }

    pub fn unmap(self: *MappedFile) void {
        _ = UnmapViewOfFile(self.data.ptr);
        _ = CloseHandle(self.map_handle);
        _ = CloseHandle(self.file_handle);
    }
};

pub fn getMilliTick() u64 {
    return GetTickCount64();
}

pub fn utf8ToW(path: []const u8, buf: []u16) [*:0]const u16 {
    var j: usize = 0;
    var i: usize = 0;
    while (i < path.len and j < buf.len - 1) {
        const c = path[i];
        if (c < 0x80) {
            buf[j] = c; i += 1;
        } else if (c < 0xe0) {
            buf[j] = (@as(u16, c & 0x1f) << 6) | (path[i + 1] & 0x3f); i += 2;
        } else {
            buf[j] = (@as(u16, c & 0x0f) << 12) | (@as(u16, path[i + 1] & 0x3f) << 6) | (path[i + 2] & 0x3f); i += 3;
        }
        j += 1;
    }
    buf[j] = 0;
    return @as([*:0]u16, @ptrCast(buf.ptr));
}

const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;

pub fn openForWrite(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const h = CreateFileW(utf8ToW(anchored, &wbuf), 0x40000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 4, 128, null);
    if (h == INVALID_HANDLE) return error.OpenFailed;
    return h;
}

pub fn openForWriteAppend(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const h = CreateFileW(utf8ToW(anchored, &wbuf), 0x40000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 4, 128, null);
    if (h == INVALID_HANDLE) return error.OpenFailed;
    _ = SetFilePointerEx(h, 0, null, 2);
    return h;
}

pub fn openForRead(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const h = CreateFileW(utf8ToW(anchored, &wbuf), 0x80000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 3, 0x80, null);
    if (h == INVALID_HANDLE) return error.FileNotFound;
    return h;
}

pub fn createMappedFile(allocator: std.mem.Allocator, path: []const u8, size: usize) !MappedFile {
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const wpath = utf8ToW(anchored, &wbuf);
    const fh = CreateFileW(wpath, 0xC0000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 4, 0x80, null);

    if (fh == INVALID_HANDLE) return error.CreateFailed;
    var current_size: i64 = 0;
    if (GetFileSizeEx(fh, &current_size) != 0) {
        if (@as(usize, @intCast(current_size)) != size) {
            _ = SetFilePointerEx(fh, @as(i64, @intCast(size - 1)), null, 0);
            var written: u32 = 0; const zero: u8 = 0;
            _ = WriteFile(fh, @as([*]const u8, @ptrCast(&zero)), 1, &written, null);
            _ = SetEndOfFile(fh);
            _ = SetFilePointerEx(fh, 0, null, 0);
        }
    }

    // Task 2: Bulletproof Silicon - Aligned Memory Mapping
    // We use VirtualAlloc to reserve a specific, page-aligned range first if needed,
    // but MapViewOfFile naturally aligns to the "allocation granularity" (usually 64KB).
    // To be 100% sure, we explicitly check alignment after mapping.
    const size_high: u32 = @intCast((size >> 32) & 0xFFFFFFFF);
    const size_low: u32 = @intCast(size & 0xFFFFFFFF);
    const mh = CreateFileMappingW(fh, null, 0x04, size_high, size_low, null) orelse {
        _ = CloseHandle(fh);
        return error.MapCreateFailed;
    };
    
    const ptr = MapViewOfFile(mh, 0x0002, 0, 0, size) orelse {
        _ = CloseHandle(mh);
        _ = CloseHandle(fh);
        return error.MapViewFailed;
    };

    // Verify alignment
    const addr = @intFromPtr(ptr);
    if (addr & (64 * 1024 - 1) != 0) {
        // This is extremely rare on Windows but we must handle it for "Bulletproof" status
        std.debug.print("[SYS FATAL] Memory mapping not 64KB aligned: 0x{X}\n", .{addr});
        _ = UnmapViewOfFile(ptr);
        _ = CloseHandle(mh);
        _ = CloseHandle(fh);
        return error.AlignmentFailure;
    }

    return MappedFile{ .file_handle = fh, .map_handle = mh, .data = @as([*]u8, @ptrCast(ptr))[0..size] };
}

pub fn closeFile(handle: FileHandle) void { _ = CloseHandle(handle); }
pub fn getFileSize(handle: FileHandle) !u32 { var size: i64 = 0; if (GetFileSizeEx(handle, &size) == 0) return error.GetSizeFailed; return @intCast(size); }
pub fn writeAll(handle: FileHandle, data: []const u8) !void {
    var written: u32 = 0; var total: usize = 0;
    while (total < data.len) {
        const chunk = @min(data.len - total, 0x7FFFFFFF);
        if (WriteFile(handle, data[total..].ptr, @intCast(chunk), &written, null) == 0) return error.WriteFailed;
        if (written == 0) break; total += written;
    }
}
pub fn readAll(handle: FileHandle, buffer: []u8) !usize {
    var total: usize = 0; while (total < buffer.len) {
        var read_bytes: u32 = 0; const chunk = @min(buffer.len - total, 0x7FFFFFFF);
        if (ReadFile(handle, buffer[total..].ptr, @intCast(chunk), &read_bytes, null) == 0 or read_bytes == 0) break;
        total += read_bytes;
    }
    return total;
}

pub fn allocSectorAligned(size: usize) ?[]u8 {
    const aligned_size = (size + SECTOR_SIZE - 1) & ~(SECTOR_SIZE - 1);
    const ptr = VirtualAlloc(null, aligned_size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse return null;
    return @as([*]u8, @ptrCast(ptr))[0..aligned_size];
}
pub fn freeSectorAligned(buf: []u8) void { _ = VirtualFree(buf.ptr, 0, MEM_RELEASE); }

pub fn printOut(text: []const u8) void {
    const hOut = GetStdHandle(@as(u32, @bitCast(@as(i32, -11))));
    var written: u32 = 0; _ = WriteFile(hOut, text.ptr, @intCast(text.len), &written, null);
}
pub fn readStdin(buffer: []u8) ![]u8 {
    const hIn = GetStdHandle(@as(u32, @bitCast(@as(i32, -10))));
    var read_bytes: u32 = 0; if (ReadFile(hIn, buffer.ptr, @intCast(buffer.len), &read_bytes, null) == 0) return error.ReadFailed;
    return buffer[0..read_bytes];
}
pub fn sleep(ms: u32) void { Sleep(ms); }
pub fn exit(code: u32) noreturn { ExitProcess(code); }

pub const NativeLibrary = struct {
    handle: *anyopaque,

    pub fn open(path: []const u8) !NativeLibrary {
        var wbuf: [1024]u16 = undefined;
        const wpath = utf8ToW(path, &wbuf);
        const h = LoadLibraryW(wpath) orelse return error.LibraryLoadFailed;
        return NativeLibrary{ .handle = h };
    }

    pub fn lookup(self: NativeLibrary, T: type, name: [:0]const u8) ?T {
        const addr = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @as(T, @ptrCast(addr));
    }

    pub fn close(self: NativeLibrary) void {
        _ = FreeLibrary(self.handle);
    }
};

pub fn getArgs(allocator: std.mem.Allocator) ![][]const u8 {

    const cmd_w = GetCommandLineW();
    var utf8_list: std.ArrayList(u8) = .empty;
    defer utf8_list.deinit(allocator);
    var idx: usize = 0;
    while (cmd_w[idx] != 0) : (idx += 1) {
        const c = cmd_w[idx];
        if (c < 0x80) { try utf8_list.append(allocator, @intCast(c)); }
        else if (c < 0x800) { try utf8_list.append(allocator, @intCast(0xc0 | (c >> 6))); try utf8_list.append(allocator, @intCast(0x80 | (c & 0x3f))); }
        else { try utf8_list.append(allocator, @intCast(0xe0 | (c >> 12))); try utf8_list.append(allocator, @intCast(0x80 | ((c >> 6) & 0x3f))); try utf8_list.append(allocator, @intCast(0x80 | (c & 0x3f))); }
    }
    const utf8 = utf8_list.items;
    var args_list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < utf8.len) {
        while (i < utf8.len and utf8[i] == ' ') : (i += 1) {}
        if (i >= utf8.len) break;
        const start = i;
        if (utf8[i] == '"') {
            i += 1; const s2 = i;
            while (i < utf8.len and utf8[i] != '"') : (i += 1) {}
            try args_list.append(allocator, try allocator.dupe(u8, utf8[s2..i]));
            if (i < utf8.len) i += 1;
        } else {
            while (i < utf8.len and utf8[i] != ' ') : (i += 1) {}
            try args_list.append(allocator, try allocator.dupe(u8, utf8[start..i]));
        }
    }
    return args_list.toOwnedSlice(allocator);
}
