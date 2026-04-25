const std = @import("std");

// --- GHOST ENGINE: DIRECT WINAPI CORE ---
// Zero-overhead Windows Kernel32 I/O and memory-mapping layer.

extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) i32;

pub fn makePath(allocator: std.mem.Allocator, path: []const u8) !void {
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);

    // Simple recursive makePath
    var i: usize = 0;
    while (i < anchored.len) : (i += 1) {
        if (anchored[i] == '/' or anchored[i] == '\\') {
            if (i == 0) continue;
            const sub = anchored[0..i];
            const wsub = utf8ToW(sub, &wbuf);
            _ = CreateDirectoryW(wsub, null);
        }
    }
    const wpath = utf8ToW(anchored, &wbuf);
    if (CreateDirectoryW(wpath, null) == 0) {
        const err = GetLastError();
        if (err != 183) return error.DirectoryCreationFailed; // 183 = ERROR_ALREADY_EXISTS
    }
}

extern "kernel32" fn CreateFileW(n: [*:0]const u16, a: u32, s: u32, p: ?*anyopaque, d: u32, f: u32, t: ?*anyopaque) callconv(.winapi) *anyopaque;
extern "kernel32" fn WriteFile(h: *anyopaque, b: [*]const u8, n: u32, w: ?*u32, o: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: *anyopaque, b: [*]u8, n: u32, r: ?*u32, o: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetFileSizeEx(h: *anyopaque, lp: *i64) callconv(.winapi) i32;
extern "kernel32" fn CreateFileMappingW(h: *anyopaque, a: ?*anyopaque, p: u32, sh: u32, sl: u32, n: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn MapViewOfFile(m: *anyopaque, a: u32, oh: u32, ol: u32, s: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn FlushViewOfFile(lpBaseAddress: *const anyopaque, dwNumberOfBytesToFlush: usize) callconv(.winapi) i32;
extern "kernel32" fn FlushFileBuffers(hFile: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) *anyopaque;
extern "kernel32" fn PeekNamedPipe(h: *anyopaque, b: ?[*]u8, n: u32, r: ?*u32, a: ?*u32, p: ?*u32) callconv(.winapi) i32;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn ExitProcess(uExitCode: u32) callconv(.winapi) noreturn;
extern "kernel32" fn SetFilePointerEx(h: *anyopaque, dist: i64, new_pos: ?*i64, method: u32) callconv(.winapi) i32;
extern "kernel32" fn SetEndOfFile(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: u32, flProtect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(lpAddress: *anyopaque, dwSize: usize, dwFreeType: u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*:0]u16, nSize: u32) callconv(.winapi) u32;

// --- GHOST ENGINE: CONNECTIVITY & SURVEILLANCE ---
extern "kernel32" fn CreateNamedPipeW(lpName: [*:0]const u16, dwOpenMode: u32, dwPipeMode: u32, nMaxInstances: u32, nOutBufferSize: u32, nInBufferSize: u32, nDefaultTimeOut: u32, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) *anyopaque;
extern "kernel32" fn ConnectNamedPipe(hNamedPipe: *anyopaque, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn ReadDirectoryChangesW(hDirectory: *anyopaque, lpBuffer: *anyopaque, nBufferLength: u32, bWatchSubtree: i32, dwNotifyFilter: u32, lpBytesReturned: ?*u32, lpOverlapped: ?*anyopaque, lpCompletionRoutine: ?*anyopaque) callconv(.winapi) i32;

pub const PIPE_ACCESS_DUPLEX = 0x00000003;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const PIPE_READMODE_BYTE = 0x00000000;
pub const PIPE_WAIT = 0x00000000;

pub const FILE_NOTIFY_CHANGE_LAST_WRITE = 0x00000010;
pub const FILE_NOTIFY_CHANGE_FILE_NAME = 0x00000001;
pub const FILE_LIST_DIRECTORY = 0x00000001;

pub const FILE_NOTIFY_INFORMATION = extern struct {
    NextEntryOffset: u32,
    Action: u32,
    FileNameLength: u32,
    FileName: [1]u16,
};

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

extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) *anyopaque;
extern "kernel32" fn FindNextFileW(hFindFile: *anyopaque, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) i32;
extern "kernel32" fn FindClose(hFindFile: *anyopaque) callconv(.winapi) i32;

pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.c) i32;

// V30: Static buffer for anchored paths to eliminate leaks in multi-test runs.

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
            out_buf[out_idx] = @intCast(c);
            out_idx += 1;
        } else if (c < 0x800) {
            out_buf[out_idx] = @intCast(0xC0 | (c >> 6));
            out_idx += 1;
            out_buf[out_idx] = @intCast(0x80 | (c & 0x3F));
            out_idx += 1;
        } else {
            out_buf[out_idx] = @intCast(0xE0 | (c >> 12));
            out_idx += 1;
            out_buf[out_idx] = @intCast(0x80 | ((c >> 6) & 0x3F));
            out_idx += 1;
            out_buf[out_idx] = @intCast(0x80 | (c & 0x3F));
            out_idx += 1;
        }
    }
    const final_path = try allocator.dupe(u8, out_buf[0..out_idx]);
    allocator.free(out_buf);
    return final_path;
}

var silo_root_buf: [1024]u8 = undefined;
var silo_root_len: usize = 0;

pub fn getSiloRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (silo_root_len > 0) return silo_root_buf[0..silo_root_len];

    const exe_path = try getExePath(allocator);
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.NoDirName;

    // If the exe lives inside a directory named "bin", step up one level.
    const silo_root = if (std.mem.endsWith(u8, exe_dir, "\\bin") or std.mem.endsWith(u8, exe_dir, "/bin"))
        std.fs.path.dirname(exe_dir) orelse exe_dir
    else
        exe_dir;

    if (silo_root.len > silo_root_buf.len) return error.PathTooLong;
    @memcpy(silo_root_buf[0..silo_root.len], silo_root);
    silo_root_len = silo_root.len;

    // std.debug.print("[SYS] Silo root anchored: {s}\n", .{silo_root_buf[0..silo_root_len]});
    return silo_root_buf[0..silo_root_len];
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
            if (c < 0x80) {
                out_buf[out_idx] = @intCast(c);
                out_idx += 1;
            } else if (c < 0x800) {
                out_buf[out_idx] = @intCast(0xC0 | (c >> 6));
                out_idx += 1;
                out_buf[out_idx] = @intCast(0x80 | (c & 0x3F));
                out_idx += 1;
            }
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

/// Scan the corpus/ directory for .txt files, returning full anchored paths.
/// Scan the corpus/ directory for .txt files, returning full anchored paths.
/// Scan the corpus/ directory for .txt files, returning full anchored paths.
/// Scan the corpus/ directory for .txt files, returning full anchored paths.
/// Scan the corpus/ directory for .txt files, returning full anchored paths.
pub fn findCorpusFiles(allocator: std.mem.Allocator) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |path| allocator.free(path);
        results.deinit(allocator);
    }

    const anchored = try getAnchorPath(allocator, "corpus");
    defer allocator.free(anchored);
    const project_corpus = try std.fs.path.join(allocator, &[_][]const u8{ @import("build_options").project_root, "corpus" });
    defer allocator.free(project_corpus);

    const candidates = [_][]const u8{ anchored, project_corpus };
    for (candidates) |candidate| {
        var wbuf: [1024]u16 = undefined;
        var pattern_buf: [1024]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "{s}\\*", .{candidate}) catch continue;
        const search_path = utf8ToW(pattern, &wbuf);

        var find_data: WIN32_FIND_DATAW = undefined;
        const hFind = FindFirstFileW(search_path, &find_data);
        if (hFind == INVALID_HANDLE) continue;
        defer _ = FindClose(hFind);

        while (true) {
            var len: usize = 0;
            while (len < 260 and find_data.cFileName[len] != 0) len += 1;
            const utf16_slice = find_data.cFileName[0..len];

            var out_buf: [1024]u8 = undefined;
            var out_idx: usize = 0;
            for (utf16_slice) |c| {
                if (c < 0x80) {
                    out_buf[out_idx] = @intCast(c);
                    out_idx += 1;
                } else if (c < 0x800) {
                    out_buf[out_idx] = @intCast(0xC0 | (c >> 6));
                    out_idx += 1;
                    out_buf[out_idx] = @intCast(0x80 | (c & 0x3F));
                    out_idx += 1;
                }
            }

            const name = out_buf[0..out_idx];
            if (std.mem.endsWith(u8, name, ".txt")) {
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ candidate, name });
                try results.append(allocator, full_path);
            }

            if (FindNextFileW(hFind, &find_data) == 0) break;
        }

        if (results.items.len > 0) break;
    }

    return results.toOwnedSlice(allocator);
}

pub extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn OpenMutexA(dwDesiredAccess: u32, bInheritHandle: i32, lpName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub fn acquireTrainerLock() bool {
    const h = CreateMutexA(null, 1, "Global\\GhostTrainerLock");
    if (h == null) return false;
    if (GetLastError() == 183) return false; // ERROR_ALREADY_EXISTS
    return true; // We own the mutex, it will be automatically released when the process dies
}

pub fn isTrainerActive(allocator: std.mem.Allocator) bool {
    _ = allocator;
    const h = OpenMutexA(0x00100000, 0, "Global\\GhostTrainerLock"); // SYNCHRONIZE
    if (h != null) {
        _ = CloseHandle(h.?);
        return true;
    }
    return false;
}

pub const FileHandle = *anyopaque;
pub const INVALID_HANDLE = @as(*anyopaque, @ptrFromInt(0xFFFFFFFFFFFFFFFF));

pub const NVME_DIRECT_FLAGS: u32 = 0x20000000 | 0x80000000; // FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH
pub const SECTOR_SIZE: usize = 4096;
const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;

pub const MappedFile = struct {
    file_handle: FileHandle,
    map_handle: FileHandle,
    data: []u8,

    pub fn flush(self: *const MappedFile) !void {
        // V31: Direct DMA flush. Bypasses standard OS buffering.
        if (FlushViewOfFile(self.data.ptr, 0) == 0) return error.FlushViewFailed;
        if (FlushFileBuffers(self.file_handle) == 0) return error.FlushFileBuffersFailed;
    }

    pub fn unmap(self: *MappedFile) void {
        _ = UnmapViewOfFile(self.data.ptr);
        _ = CloseHandle(self.map_handle);
        _ = CloseHandle(self.file_handle);
        self.* = .{
            .file_handle = INVALID_HANDLE,
            .map_handle = INVALID_HANDLE,
            .data = &[_]u8{},
        };
    }
};

/// V31: DirectStorage-style DMA.
/// Loads data directly from NVMe into a sector-aligned buffer.
pub fn directRead(handle: FileHandle, offset: u64, buffer: []u8) !void {
    _ = SetFilePointerEx(handle, @intCast(offset), null, 0);
    var read_bytes: u32 = 0;
    if (ReadFile(handle, buffer.ptr, @intCast(buffer.len), &read_bytes, null) == 0) return error.DirectReadFailed;
    if (read_bytes != buffer.len) return error.DirectReadFailed;
}

pub fn directWrite(handle: FileHandle, offset: u64, buffer: []const u8) !void {
    _ = SetFilePointerEx(handle, @intCast(offset), null, 0);
    var written_bytes: u32 = 0;
    if (WriteFile(handle, buffer.ptr, @intCast(buffer.len), &written_bytes, null) == 0) return error.DirectWriteFailed;
    if (written_bytes != buffer.len) return error.DirectWriteFailed;
}

pub fn getMilliTick() u64 {
    return GetTickCount64();
}

pub fn createNamedPipe(name: []const u8) !FileHandle {
    var wbuf: [1024]u16 = undefined;
    const wname = utf8ToW(name, &wbuf);
    const h = CreateNamedPipeW(wname, PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 65536, 65536, 0, null);
    if (h == INVALID_HANDLE) return error.PipeCreateFailed;
    return h;
}

pub fn connectNamedPipe(h: FileHandle) !void {
    if (ConnectNamedPipe(h, null) == 0) {
        // ERROR_PIPE_CONNECTED (535) means someone already connected.
        // We can't easily get GetLastError here without more externs, but we'll assume it's okay for now.
    }
}

pub fn disconnectNamedPipe(h: FileHandle) void {
    _ = DisconnectNamedPipe(h);
}

pub fn watchDirectory(h: FileHandle, buffer: []u8) !usize {
    var returned: u32 = 0;
    if (ReadDirectoryChangesW(h, buffer.ptr, @intCast(buffer.len), 1, FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_FILE_NAME, &returned, null, null) == 0) {
        return error.WatchFailed;
    }
    return @intCast(returned);
}

pub fn utf8ToW(path: []const u8, buf: []u16) [*:0]const u16 {
    const len = std.unicode.utf8ToUtf16Le(buf, path) catch |err| {
        std.debug.print("[FATAL] Unicode conversion failed for path '{s}': {any}\n", .{ path, err });
        buf[0] = 0;
        return @ptrCast(buf.ptr);
    };
    buf[len] = 0;
    return @ptrCast(buf.ptr);
}

const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;

pub fn openForWrite(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const h = CreateFileW(utf8ToW(anchored, &wbuf), 0x40000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 4, 0x80, null);
    if (h == INVALID_HANDLE) return error.OpenFailed;
    return h;
}

pub fn openForWriteAppend(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const h = CreateFileW(utf8ToW(anchored, &wbuf), 0x40000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 4, NVME_DIRECT_FLAGS, null);
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

pub fn openForReadWrite(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const h = CreateFileW(utf8ToW(anchored, &wbuf), 0xC0000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 3, 0x80, null);
    if (h == INVALID_HANDLE) return error.OpenFailed;
    return h;
}

pub fn openDirectory(allocator: std.mem.Allocator, path: []const u8) !FileHandle {
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    const h = CreateFileW(utf8ToW(anchored, &wbuf), FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 3, 0x02000000, null);
    if (h == INVALID_HANDLE) return error.DirOpenFailed;
    return h;
}

pub fn createMappedFile(allocator: std.mem.Allocator, path: []const u8, size: usize) !MappedFile {
    std.debug.print("[DEBUG] createMappedFile: {s}\n", .{path});
    var wbuf: [1024]u16 = undefined;
    const anchored = try getAnchorPath(allocator, path);
    defer allocator.free(anchored);
    std.debug.print("[DEBUG] anchored path: {s}\n", .{anchored});
    const wpath = utf8ToW(anchored, &wbuf);
    const fh = CreateFileW(wpath, 0xC0000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, 4, 0x80, null);

    if (fh == INVALID_HANDLE) {
        std.debug.print("[DEBUG] CreateFileW failed\n", .{});
        return error.CreateFailed;
    }
    std.debug.print("[DEBUG] CreateFileW success\n", .{});
    var current_size: i64 = 0;
    if (GetFileSizeEx(fh, &current_size) != 0) {
        if (@as(usize, @intCast(current_size)) != size) {
            _ = SetFilePointerEx(fh, @as(i64, @intCast(size - 1)), null, 0);
            var written: u32 = 0;
            const zero: u8 = 0;
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

pub fn closeFile(handle: FileHandle) void {
    _ = CloseHandle(handle);
}
pub fn getFileSize(handle: FileHandle) !u32 {
    var size: i64 = 0;
    if (GetFileSizeEx(handle, &size) == 0) return error.GetSizeFailed;
    return @intCast(size);
}
pub fn writeAll(handle: FileHandle, data: []const u8) !void {
    var written: u32 = 0;
    var total: usize = 0;
    while (total < data.len) {
        const chunk = @min(data.len - total, 64 * 1024 * 1024);
        if (WriteFile(handle, data[total..].ptr, @intCast(chunk), &written, null) == 0) return error.WriteFailed;
        if (written == 0) break;
        total += written;
    }
}
pub fn readAll(handle: FileHandle, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        var read_bytes: u32 = 0;
        const chunk = @min(buffer.len - total, 0x7FFFFFFF);
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
pub fn freeSectorAligned(buf: []u8) void {
    _ = VirtualFree(buf.ptr, 0, MEM_RELEASE);
}

pub fn printOut(text: []const u8) void {
    const hOut = GetStdHandle(@as(u32, @bitCast(@as(i32, -11))));
    var written: u32 = 0;
    _ = WriteFile(hOut, text.ptr, @intCast(text.len), &written, null);
}
pub fn readStdin(buffer: []u8) ![]u8 {
    const hIn = GetStdHandle(@as(u32, @bitCast(@as(i32, -10))));
    var read_bytes: u32 = 0;
    if (ReadFile(hIn, buffer.ptr, @intCast(buffer.len), &read_bytes, null) == 0) return error.ReadFailed;
    return buffer[0..read_bytes];
}
pub fn pollStdin() bool {
    const hIn = GetStdHandle(@as(u32, @bitCast(@as(i32, -10))));
    var avail: u32 = 0;
    if (PeekNamedPipe(hIn, null, 0, null, &avail, null) == 0) return false;
    return avail > 0;
}
pub fn sleep(ms: u32) void {
    Sleep(ms);
}
pub fn exit(code: u32) noreturn {
    ExitProcess(code);
}

pub fn getArgs(allocator: std.mem.Allocator) ![][]const u8 {
    const cmd_w = GetCommandLineW();
    var utf8_list: std.ArrayList(u8) = .empty;
    defer utf8_list.deinit(allocator);
    var idx: usize = 0;
    while (cmd_w[idx] != 0) : (idx += 1) {
        const c = cmd_w[idx];
        if (c < 0x80) {
            try utf8_list.append(allocator, @intCast(c));
        } else if (c < 0x800) {
            try utf8_list.append(allocator, @intCast(0xc0 | (c >> 6)));
            try utf8_list.append(allocator, @intCast(0x80 | (c & 0x3f)));
        } else {
            try utf8_list.append(allocator, @intCast(0xe0 | (c >> 12)));
            try utf8_list.append(allocator, @intCast(0x80 | ((c >> 6) & 0x3f)));
            try utf8_list.append(allocator, @intCast(0x80 | (c & 0x3f)));
        }
    }
    const utf8 = utf8_list.items;
    var args_list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < utf8.len) {
        while (i < utf8.len and utf8[i] == ' ') : (i += 1) {}
        if (i >= utf8.len) break;
        const start = i;
        if (utf8[i] == '"') {
            i += 1;
            const s2 = i;
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
