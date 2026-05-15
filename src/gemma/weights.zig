const std = @import("std");

pub const Error = error{
    InvalidMagic,
    UnsupportedGGUFVersion,
    UnexpectedEof,
    InvalidString,
    TensorNotFound,
    MetadataNotFound,
    TooManyTensorDimensions,
    InvalidAlignment,
    IntegerOverflow,
    UnsupportedNestedArray,
};

pub const default_alignment: u64 = 32;
pub const max_tensor_dims: usize = 8;

pub const TensorInfo = struct {
    name: []const u8,
    dimensions: [max_tensor_dims]u64 = [_]u64{0} ** max_tensor_dims,
    dimension_count: u32 = 0,
    ggml_type: u32,
    relative_offset: u64,
    absolute_offset: u64,
    byte_len: u64,

    pub fn elementCount(self: TensorInfo) u64 {
        var count: u64 = 1;
        for (0..self.dimension_count) |idx| count *= self.dimensions[idx];
        return count;
    }
};

pub const TensorView = struct {
    info: TensorInfo,
    bytes: []const u8,
};

pub const MetadataValue = union(enum) {
    uint: u64,
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    array: ArraySummary,

    pub const ArraySummary = struct {
        element_type: ValueType,
        len: u64,
    };
};

pub const ValueType = enum(u32) {
    u8 = 0,
    i8 = 1,
    u16 = 2,
    i16 = 3,
    u32 = 4,
    i32 = 5,
    f32 = 6,
    bool = 7,
    string = 8,
    array = 9,
    u64 = 10,
    i64 = 11,
    f64 = 12,
    _,

    pub fn label(self: ValueType) []const u8 {
        return switch (self) {
            .u8 => "u8",
            .i8 => "i8",
            .u16 => "u16",
            .i16 => "i16",
            .u32 => "u32",
            .i32 => "i32",
            .f32 => "f32",
            .bool => "bool",
            .string => "string",
            .array => "array",
            .u64 => "u64",
            .i64 => "i64",
            .f64 => "f64",
            else => "unknown",
        };
    }
};

pub const GGUFLoader = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    mmap: []align(std.heap.page_size_min) const u8,
    version: u32,
    tensor_count: u64,
    metadata_count: u64,
    alignment: u64 = default_alignment,
    data_start: u64,
    tensors: std.StringHashMap(TensorInfo),
    metadata: std.StringHashMap(MetadataValue),

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !GGUFLoader {
        const file = try std.fs.cwd().openFile(path, .{});
        var file_owned_by_loader = false;
        errdefer if (!file_owned_by_loader) file.close();

        const stat = try file.stat();
        if (stat.size == 0) return Error.UnexpectedEof;
        if (stat.size > std.math.maxInt(usize)) return Error.IntegerOverflow;

        const mapped = try std.posix.mmap(
            null,
            @intCast(stat.size),
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        var mmap_owned_by_loader = false;
        errdefer if (!mmap_owned_by_loader) std.posix.munmap(mapped);

        var loader = GGUFLoader{
            .allocator = allocator,
            .file = file,
            .mmap = mapped,
            .version = 0,
            .tensor_count = 0,
            .metadata_count = 0,
            .data_start = 0,
            .tensors = std.StringHashMap(TensorInfo).init(allocator),
            .metadata = std.StringHashMap(MetadataValue).init(allocator),
        };
        file_owned_by_loader = true;
        mmap_owned_by_loader = true;
        errdefer loader.deinit();

        try loader.parse();
        return loader;
    }

    pub fn deinit(self: *GGUFLoader) void {
        self.tensors.deinit();
        self.metadata.deinit();
        std.posix.munmap(self.mmap);
        self.file.close();
        self.* = undefined;
    }

    pub fn getTensor(self: *const GGUFLoader, name: []const u8) !TensorView {
        const info = self.tensors.get(name) orelse return Error.TensorNotFound;
        const start = try checkedU64ToUsize(info.absolute_offset);
        const len = try checkedU64ToUsize(info.byte_len);
        const end = try checkedAdd(usize, start, len);
        if (end > self.mmap.len) return Error.UnexpectedEof;
        return .{ .info = info, .bytes = self.mmap[start..end] };
    }

    pub fn getLayerWeights(self: *const GGUFLoader, allocator: std.mem.Allocator, layer_idx: u32, weight_name: []const u8) !TensorView {
        const full_name = try std.fmt.allocPrint(allocator, "blk.{d}.{s}", .{ layer_idx, weight_name });
        defer allocator.free(full_name);
        return self.getTensor(full_name);
    }

    pub fn metadataValue(self: *const GGUFLoader, key: []const u8) ?MetadataValue {
        return self.metadata.get(key);
    }

    pub fn metadataString(self: *const GGUFLoader, key: []const u8) ?[]const u8 {
        return switch (self.metadata.get(key) orelse return null) {
            .string => |value| value,
            else => null,
        };
    }

    pub fn metadataUint(self: *const GGUFLoader, key: []const u8) ?u64 {
        return switch (self.metadata.get(key) orelse return null) {
            .uint => |value| value,
            .int => |value| if (value >= 0) @intCast(value) else null,
            else => null,
        };
    }

    pub fn containsTensor(self: *const GGUFLoader, name: []const u8) bool {
        return self.tensors.contains(name);
    }

    pub fn countTensorPrefix(self: *const GGUFLoader, prefix: []const u8) usize {
        var count: usize = 0;
        var it = self.tensors.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) count += 1;
        }
        return count;
    }

    fn parse(self: *GGUFLoader) !void {
        var reader = Reader{ .bytes = self.mmap };
        const magic = try reader.readBytes(4);
        if (!std.mem.eql(u8, magic, "GGUF")) return Error.InvalidMagic;
        self.version = try reader.readU32();
        if (self.version < 2 or self.version > 3) return Error.UnsupportedGGUFVersion;
        self.tensor_count = try reader.readU64();
        self.metadata_count = try reader.readU64();

        for (0..self.metadata_count) |_| {
            const key = try reader.readString();
            const value = try readMetadataValue(&reader);
            try self.metadata.put(key, value);
        }

        self.alignment = self.metadataUint("general.alignment") orelse default_alignment;
        if (self.alignment == 0 or !std.math.isPowerOfTwo(self.alignment)) return Error.InvalidAlignment;

        const tensor_infos = try self.allocator.alloc(TensorInfo, try checkedU64ToUsize(self.tensor_count));
        defer self.allocator.free(tensor_infos);

        for (tensor_infos) |*tensor| {
            tensor.* = try readTensorInfo(&reader);
        }

        self.data_start = alignForwardU64(reader.cursor, self.alignment);
        for (tensor_infos, 0..) |tensor, idx| {
            var info = tensor;
            info.absolute_offset = try checkedAdd(u64, self.data_start, info.relative_offset);
            const next_relative = if (idx + 1 < tensor_infos.len) tensor_infos[idx + 1].relative_offset else self.mmap.len - self.data_start;
            if (next_relative < info.relative_offset) return Error.UnexpectedEof;
            info.byte_len = next_relative - info.relative_offset;
            const end = try checkedAdd(u64, info.absolute_offset, info.byte_len);
            if (end > self.mmap.len) return Error.UnexpectedEof;
            try self.tensors.put(info.name, info);
        }
    }
};

pub fn ggmlTypeName(value: u32) []const u8 {
    return switch (value) {
        0 => "F32",
        1 => "F16",
        2 => "Q4_0",
        3 => "Q4_1",
        6 => "Q5_0",
        7 => "Q5_1",
        8 => "Q8_0",
        9 => "Q8_1",
        10 => "Q2_K",
        11 => "Q3_K",
        12 => "Q4_K",
        13 => "Q5_K",
        14 => "Q6_K",
        15 => "Q8_K",
        16 => "IQ2_XXS",
        17 => "IQ2_XS",
        18 => "IQ3_XXS",
        19 => "IQ1_S",
        20 => "IQ4_NL",
        21 => "IQ3_S",
        22 => "IQ2_S",
        23 => "IQ4_XS",
        24 => "I8",
        25 => "I16",
        26 => "I32",
        27 => "I64",
        28 => "F64",
        29 => "IQ1_M",
        30 => "BF16",
        31 => "Q4_0_4_4",
        32 => "Q4_0_4_8",
        33 => "Q4_0_8_8",
        34 => "TQ1_0",
        35 => "TQ2_0",
        36 => "MXFP4",
        else => "UNKNOWN",
    };
}

pub fn formatShape(writer: anytype, info: TensorInfo) !void {
    try writer.writeByte('[');
    for (0..info.dimension_count) |idx| {
        if (idx > 0) try writer.writeAll(", ");
        try writer.print("{d}", .{info.dimensions[idx]});
    }
    try writer.writeByte(']');
}

fn readTensorInfo(reader: *Reader) !TensorInfo {
    const name = try reader.readString();
    const dimension_count = try reader.readU32();
    if (dimension_count > max_tensor_dims) return Error.TooManyTensorDimensions;
    var dimensions = [_]u64{0} ** max_tensor_dims;
    for (0..dimension_count) |idx| dimensions[idx] = try reader.readU64();
    const ggml_type = try reader.readU32();
    const relative_offset = try reader.readU64();
    return .{
        .name = name,
        .dimensions = dimensions,
        .dimension_count = dimension_count,
        .ggml_type = ggml_type,
        .relative_offset = relative_offset,
        .absolute_offset = 0,
        .byte_len = 0,
    };
}

fn readMetadataValue(reader: *Reader) !MetadataValue {
    const raw_type = try reader.readU32();
    const value_type: ValueType = @enumFromInt(raw_type);
    return switch (value_type) {
        .u8 => .{ .uint = try reader.readU8() },
        .i8 => .{ .int = try reader.readI8() },
        .u16 => .{ .uint = try reader.readU16() },
        .i16 => .{ .int = try reader.readI16() },
        .u32 => .{ .uint = try reader.readU32() },
        .i32 => .{ .int = try reader.readI32() },
        .f32 => .{ .float = try reader.readF32() },
        .bool => .{ .bool = (try reader.readU8()) != 0 },
        .string => .{ .string = try reader.readString() },
        .array => blk: {
            const element_raw = try reader.readU32();
            const element_type: ValueType = @enumFromInt(element_raw);
            const len = try reader.readU64();
            if (element_type == .array) return Error.UnsupportedNestedArray;
            for (0..len) |_| try skipScalarValue(reader, element_type);
            break :blk .{ .array = .{ .element_type = element_type, .len = len } };
        },
        .u64 => .{ .uint = try reader.readU64() },
        .i64 => .{ .int = try reader.readI64() },
        .f64 => .{ .float = try reader.readF64() },
        else => return Error.UnsupportedGGUFVersion,
    };
}

fn skipScalarValue(reader: *Reader, value_type: ValueType) !void {
    switch (value_type) {
        .u8, .i8, .bool => try reader.skip(1),
        .u16, .i16 => try reader.skip(2),
        .u32, .i32, .f32 => try reader.skip(4),
        .u64, .i64, .f64 => try reader.skip(8),
        .string => _ = try reader.readString(),
        .array => return Error.UnsupportedNestedArray,
        else => return Error.UnsupportedGGUFVersion,
    }
}

const Reader = struct {
    bytes: []const u8,
    cursor: u64 = 0,

    fn readBytes(self: *Reader, len: usize) ![]const u8 {
        const start = try checkedU64ToUsize(self.cursor);
        const end = try checkedAdd(usize, start, len);
        if (end > self.bytes.len) return Error.UnexpectedEof;
        self.cursor = @intCast(end);
        return self.bytes[start..end];
    }

    fn skip(self: *Reader, len: usize) !void {
        _ = try self.readBytes(len);
    }

    fn readString(self: *Reader) ![]const u8 {
        const len = try self.readU64();
        const bytes = try self.readBytes(try checkedU64ToUsize(len));
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return Error.InvalidString;
        return bytes;
    }

    fn readU8(self: *Reader) !u8 {
        return (try self.readBytes(1))[0];
    }

    fn readI8(self: *Reader) !i8 {
        return @bitCast(try self.readU8());
    }

    fn readU16(self: *Reader) !u16 {
        return readLittle(u16, try self.readBytes(2));
    }

    fn readI16(self: *Reader) !i16 {
        return @bitCast(try self.readU16());
    }

    fn readU32(self: *Reader) !u32 {
        return readLittle(u32, try self.readBytes(4));
    }

    fn readI32(self: *Reader) !i32 {
        return @bitCast(try self.readU32());
    }

    fn readU64(self: *Reader) !u64 {
        return readLittle(u64, try self.readBytes(8));
    }

    fn readI64(self: *Reader) !i64 {
        return @bitCast(try self.readU64());
    }

    fn readF32(self: *Reader) !f32 {
        return @bitCast(try self.readU32());
    }

    fn readF64(self: *Reader) !f64 {
        return @bitCast(try self.readU64());
    }
};

fn readLittle(comptime T: type, bytes: []const u8) T {
    var value: T = 0;
    for (bytes, 0..) |byte, idx| {
        value |= @as(T, byte) << @intCast(idx * 8);
    }
    return value;
}

fn alignForwardU64(value: u64, alignment: u64) u64 {
    const mask = alignment - 1;
    return (value + mask) & ~mask;
}

fn checkedU64ToUsize(value: u64) !usize {
    if (value > std.math.maxInt(usize)) return Error.IntegerOverflow;
    return @intCast(value);
}

fn checkedAdd(comptime T: type, lhs: T, rhs: T) !T {
    return std.math.add(T, lhs, rhs) catch Error.IntegerOverflow;
}

test "GGML type names include quantized formats needed by Gemma" {
    try std.testing.expectEqualStrings("Q8_0", ggmlTypeName(8));
    try std.testing.expectEqualStrings("Q4_K", ggmlTypeName(12));
    try std.testing.expectEqualStrings("BF16", ggmlTypeName(30));
}

test "GGUF loader rejects invalid magic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "bad.gguf", .data = "NOPE" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("bad.gguf", &path_buf);
    try std.testing.expectError(Error.InvalidMagic, GGUFLoader.init(std.testing.allocator, path));
}
