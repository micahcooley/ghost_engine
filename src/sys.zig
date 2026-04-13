const std = @import("std");
const builtin = @import("builtin");

pub const os_layer = switch (builtin.os.tag) {
    .windows => @import("sys/windows.zig"),
    .linux => @import("sys/linux.zig"),
    .macos => @import("sys/linux.zig"), // macOS uses the Linux (POSIX) layer for now
    else => @compileError("Unsupported OS"),
};

pub const FileHandle = os_layer.FileHandle;
pub const INVALID_HANDLE = os_layer.INVALID_HANDLE;
pub const MappedFile = os_layer.MappedFile;
pub const SECTOR_SIZE = os_layer.SECTOR_SIZE;

// Common Interface
pub const printOut = os_layer.printOut;
pub const readStdin = os_layer.readStdin;
pub const pollStdin = os_layer.pollStdin;
pub const openForRead = os_layer.openForRead;
pub const openForWrite = os_layer.openForWrite;
pub const makePath = os_layer.makePath;
pub const closeFile = os_layer.closeFile;
pub const getFileSize = os_layer.getFileSize;
pub const readAll = os_layer.readAll;
pub const writeAll = os_layer.writeAll;
pub const createMappedFile = os_layer.createMappedFile;
pub fn flushMappedMemory(mapped_file: *const MappedFile) void {
    mapped_file.flush();
}
pub const allocSectorAligned = os_layer.allocSectorAligned;
pub const freeSectorAligned = os_layer.freeSectorAligned;
pub const getMilliTick = os_layer.getMilliTick;
pub const sleep = os_layer.sleep;
pub const exit = os_layer.exit;
pub const getArgs = os_layer.getArgs;
pub const isTrainerActive = os_layer.isTrainerActive;
pub const acquireTrainerLock = os_layer.acquireTrainerLock;
pub const findPluginFiles = os_layer.findPluginFiles;
pub const findCorpusFiles = if (@hasDecl(os_layer, "findCorpusFiles")) os_layer.findCorpusFiles else struct {
    pub fn f(_: std.mem.Allocator) ![][]const u8 {
        return &[_][]const u8{};
    }
}.f;

// Surveillance & Connectivity
pub const createNamedPipe: ?*const fn ([]const u8) anyerror!FileHandle = if (@hasDecl(os_layer, "createNamedPipe")) &os_layer.createNamedPipe else null;
pub const connectNamedPipe: ?*const fn (FileHandle) anyerror!void = if (@hasDecl(os_layer, "connectNamedPipe")) &os_layer.connectNamedPipe else null;
pub const disconnectNamedPipe: ?*const fn (FileHandle) void = if (@hasDecl(os_layer, "disconnectNamedPipe")) &os_layer.disconnectNamedPipe else null;
pub const openDirectory: ?*const fn (std.mem.Allocator, []const u8) anyerror!FileHandle = if (@hasDecl(os_layer, "openDirectory")) &os_layer.openDirectory else null;
pub const watchDirectory: ?*const fn (FileHandle, []u8) anyerror!usize = if (@hasDecl(os_layer, "watchDirectory")) &os_layer.watchDirectory else null;

pub const getSiloRoot = if (@hasDecl(os_layer, "getSiloRoot")) os_layer.getSiloRoot else struct {
    pub fn f(allocator: std.mem.Allocator) ![]const u8 {
        return try std.fs.realpathAlloc(allocator, ".");
    }
}.f;

pub const getAnchorPath = if (@hasDecl(os_layer, "getAnchorPath")) os_layer.getAnchorPath else struct {
    pub fn f(allocator: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(sub_path)) return try allocator.dupe(u8, sub_path);
        return std.fs.path.join(allocator, &[_][]const u8{ ".", sub_path });
    }
}.f;

// Common utilities
pub fn printInt(val: i64) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch return;
    printOut(s);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    printOut(s);
}
