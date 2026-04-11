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
pub const openForRead = os_layer.openForRead;
pub const openForWrite = os_layer.openForWrite;
pub const closeFile = os_layer.closeFile;
pub const getFileSize = os_layer.getFileSize;
pub const readAll = os_layer.readAll;
pub const writeAll = os_layer.writeAll;
pub const createMappedFile = os_layer.createMappedFile;
pub const allocSectorAligned = os_layer.allocSectorAligned;
pub const freeSectorAligned = os_layer.freeSectorAligned;
pub const getMilliTick = os_layer.getMilliTick;
pub const sleep = os_layer.sleep;
pub const exit = os_layer.exit;
pub const getArgs = os_layer.getArgs;
pub const isTrainerActive = os_layer.isTrainerActive;
pub const findPluginFiles = os_layer.findPluginFiles;

// Dynamic Library Support (Optional depending on platform)
pub const NativeLibrary = if (@hasDecl(os_layer, "NativeLibrary")) os_layer.NativeLibrary else struct {
    pub fn open(_: []const u8) !@This() { return error.Unsupported; }
    pub fn lookup(_: @This(), _: type, _: [:0]const u8) ?*anyopaque { return null; }
    pub fn close(_: @This()) void {}
};

pub const findNativePlugins = if (@hasDecl(os_layer, "findNativePlugins")) os_layer.findNativePlugins else struct {
    pub fn f(_: std.mem.Allocator) ![][]const u8 {
        return &[_][]const u8{};
    }
}.f;

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
