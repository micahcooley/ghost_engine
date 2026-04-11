const std = @import("std");
const builtin = @import("builtin");

pub const HardwareStats = struct {
    total_ram: u64,
    page_size: usize,
    has_avx512: bool,
    has_avx2: bool,
    has_sse4: bool,
    cpu_cores: u32,
};

pub fn probe() HardwareStats {
    var stats = HardwareStats{
        .total_ram = 0,
        .page_size = 4096,
        .has_avx512 = false,
        .has_avx2 = false,
        .has_sse4 = false,
        .cpu_cores = 1,
    };

    // ── CPU Features ──
    if (builtin.cpu.arch.isX86()) {
        const x86 = std.Target.x86;
        stats.has_avx512 = x86.featureSetHas(builtin.cpu.features, .avx512f);
        stats.has_avx2 = x86.featureSetHas(builtin.cpu.features, .avx2);
        stats.has_sse4 = x86.featureSetHas(builtin.cpu.features, .sse4_1);
    }

    // ── RAM and Page Size ──
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) void;
            extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) i32;
        };

        const SYSTEM_INFO = struct {
            wProcessorArchitecture: u16,
            wReserved: u16,
            dwPageSize: u32,
            lpMinimumApplicationAddress: ?*anyopaque,
            lpMaximumApplicationAddress: ?*anyopaque,
            dwActiveProcessorMask: usize,
            dwNumberOfProcessors: u32,
            dwProcessorType: u32,
            dwAllocationGranularity: u32,
            wProcessorLevel: u16,
            wProcessorRevision: u16,
        };

        const MEMORYSTATUSEX = struct {
            dwLength: u32,
            dwMemoryLoad: u32,
            ullTotalPhys: u64,
            ullAvailPhys: u64,
            ullTotalPageFile: u64,
            ullAvailPageFile: u64,
            ullTotalVirtual: u64,
            ullAvailVirtual: u64,
            ullAvailExtendedVirtual: u64,
        };

        var si: SYSTEM_INFO = undefined;
        kernel32.GetSystemInfo(&si);
        stats.page_size = si.dwPageSize;
        stats.cpu_cores = si.dwNumberOfProcessors;

        var mem: MEMORYSTATUSEX = undefined;
        mem.dwLength = @sizeOf(MEMORYSTATUSEX);
        if (kernel32.GlobalMemoryStatusEx(&mem) != 0) {
            stats.total_ram = mem.ullTotalPhys;
        }
    } else if (builtin.os.tag == .linux) {
        // Simple Linux probe via sysinfo or /proc
        const sys = struct {
            const SYS_sysinfo = 99; // x86_64
            fn sysinfo(info: *sysinfo_t) isize {
                return std.os.linux.syscall1(SYS_sysinfo, @intFromPtr(info));
            }
        };

        const sysinfo_t = struct {
            uptime: i64,
            loads: [3]usize,
            totalram: usize,
            freeram: usize,
            sharedram: usize,
            bufferram: usize,
            totalswap: usize,
            freeswap: usize,
            procs: u16,
            pad: u16,
            totalhigh: usize,
            freehigh: usize,
            mem_unit: u32,
            _f: [20 - 2 * @sizeOf(usize) - 4]u8,
        };

        var info: sysinfo_t = undefined;
        // Note: syscall numbers vary by arch. For now assuming x86_64 for simplicity in this snippet
        // or using std.os if available.
        // Actually, let's use a more portable way if possible, but the request mentioned lscpu/sysinfo.
        // In Zig 0.11+, we can use std.os.linux.sysinfo.
        
        // stats.page_size = std.mem.page_size; // Often works
        // But let's try to be more direct.
        
        // For total RAM on Linux:
        var meminfo_buf: [1024]u8 = undefined;
        if (std.fs.openFileAbsolute("/proc/meminfo", .{})) |file| {
            defer file.close();
            const bytes_read = file.readAll(&meminfo_buf) catch 0;
            const content = meminfo_buf[0..bytes_read];
            if (std.mem.indexOf(u8, content, "MemTotal:")) |idx| {
                const start = idx + 9;
                if (std.mem.indexOfScalar(u8, content[start..], '\n')) |end_off| {
                    const line = std.mem.trim(u8, content[start .. start + end_off], " \t\r");
                    if (std.mem.indexOfScalar(u8, line, ' ')) |space_off| {
                        const val_str = line[0..space_off];
                        stats.total_ram = (std.fmt.parseInt(u64, val_str, 10) catch 0) * 1024;
                    }
                }
            }
        } else |_| {}
    }

    return stats;
}
