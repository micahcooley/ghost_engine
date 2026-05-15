const std = @import("std");
const weights = @import("weights.zig");

pub const qk8_0 = 32;
pub const block_q8_0_bytes = 2 + qk8_0;

pub const TensorMatrixShape = struct {
    rows: usize,
    cols: usize,
};

pub const CalibrationSummary = struct {
    tensor_name: []const u8,
    rows: usize,
    cols: usize,
    output_count: usize,
    checksum: u64,
    l1_norm: f64,
    max_abs: f32,
    first_values: [8]f32,
};

pub fn matrixShape(info: weights.TensorInfo) !TensorMatrixShape {
    if (info.dimension_count != 2) return error.ExpectedMatrixTensor;
    return .{
        .cols = try checkedU64ToUsize(info.dimensions[0]),
        .rows = try checkedU64ToUsize(info.dimensions[1]),
    };
}

pub fn q8BlockCount(shape: TensorMatrixShape) !usize {
    const elements = try std.math.mul(usize, shape.rows, shape.cols);
    if (elements % qk8_0 != 0) return error.InvalidQ8TensorShape;
    return elements / qk8_0;
}

pub fn validateQ8Tensor(view: weights.TensorView) !TensorMatrixShape {
    if (view.info.ggml_type != 8) return error.ExpectedQ8_0Tensor;
    const shape = try matrixShape(view.info);
    const blocks = try q8BlockCount(shape);
    const expected_bytes = try std.math.mul(usize, blocks, block_q8_0_bytes);
    if (view.bytes.len != expected_bytes) return error.InvalidQ8TensorByteLength;
    return shape;
}

pub fn fillDeterministicInput(input: []f32, seed: u64) void {
    var state = seed;
    for (input, 0..) |*value, idx| {
        state = splitMix64(state +% @as(u64, @intCast(idx)) +% 0x9e3779b97f4a7c15);
        const centered = @as(i32, @intCast((state >> 40) & 0xFFFF)) - 32768;
        value.* = @as(f32, @floatFromInt(centered)) / 32768.0;
    }
}

pub fn matmulQ8_0Vector(view: weights.TensorView, input: []const f32, output: []f32) !void {
    const shape = try validateQ8Tensor(view);
    if (input.len != shape.cols) return error.InputLengthMismatch;
    if (output.len != shape.rows) return error.OutputLengthMismatch;
    @memset(output, 0.0);

    const row_stride_blocks = shape.cols / qk8_0;
    for (0..shape.rows) |row| {
        var sum: f32 = 0.0;
        for (0..row_stride_blocks) |block_col| {
            const block_index = row * row_stride_blocks + block_col;
            const block = view.bytes[block_index * block_q8_0_bytes ..][0..block_q8_0_bytes];
            const scale = halfToF32(readU16Le(block[0..2]));
            const qs = block[2..][0..qk8_0];
            const input_base = block_col * qk8_0;
            for (0..qk8_0) |i| {
                const q: i8 = @bitCast(qs[i]);
                sum += (@as(f32, @floatFromInt(q)) * scale) * input[input_base + i];
            }
        }
        output[row] = sum;
    }
}

pub fn calibrateQ8_0(
    allocator: std.mem.Allocator,
    loader: *const weights.GGUFLoader,
    tensor_name: []const u8,
    seed: u64,
    max_rows: ?usize,
) !CalibrationSummary {
    const view = try loader.getTensor(tensor_name);
    const shape = try validateQ8Tensor(view);
    const rows = if (max_rows) |cap| @min(cap, shape.rows) else shape.rows;
    const truncated_shape = TensorMatrixShape{ .rows = rows, .cols = shape.cols };
    const row_bytes = try std.math.mul(usize, shape.cols / qk8_0, block_q8_0_bytes);
    var truncated_info = view.info;
    truncated_info.dimensions[1] = rows;
    truncated_info.byte_len = rows * row_bytes;
    const truncated_view = weights.TensorView{
        .info = truncated_info,
        .bytes = view.bytes[0..truncated_info.byte_len],
    };

    const input = try allocator.alloc(f32, truncated_shape.cols);
    defer allocator.free(input);
    const output = try allocator.alloc(f32, truncated_shape.rows);
    defer allocator.free(output);
    fillDeterministicInput(input, seed);
    try matmulQ8_0Vector(truncated_view, input, output);

    var first = [_]f32{0.0} ** 8;
    for (0..@min(first.len, output.len)) |idx| first[idx] = output[idx];

    return .{
        .tensor_name = tensor_name,
        .rows = truncated_shape.rows,
        .cols = truncated_shape.cols,
        .output_count = output.len,
        .checksum = checksumF32(output),
        .l1_norm = l1Norm(output),
        .max_abs = maxAbs(output),
        .first_values = first,
    };
}

pub fn checksumF32(values: []const f32) u64 {
    var hasher = std.hash.Wyhash.init(0x67686f73745f7138);
    for (values) |value| {
        const bits: u32 = @bitCast(value);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, bits, .little);
        hasher.update(&bytes);
    }
    return hasher.final();
}

pub fn l1Norm(values: []const f32) f64 {
    var total: f64 = 0.0;
    for (values) |value| total += @abs(@as(f64, @floatCast(value)));
    return total;
}

pub fn maxAbs(values: []const f32) f32 {
    var max_value: f32 = 0.0;
    for (values) |value| max_value = @max(max_value, @abs(value));
    return max_value;
}

fn splitMix64(input: u64) u64 {
    var z = input;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn readU16Le(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

pub fn halfToF32(bits: u16) f32 {
    const sign = (@as(u32, bits >> 15) & 0x1) << 31;
    const exp = @as(u32, (bits >> 10) & 0x1f);
    const frac = @as(u32, bits & 0x03ff);

    if (exp == 0) {
        if (frac == 0) return @bitCast(sign);
        var mant = frac;
        var exponent: i32 = -14;
        while ((mant & 0x0400) == 0) {
            mant <<= 1;
            exponent -= 1;
        }
        mant &= 0x03ff;
        const exp32: u32 = @intCast(exponent + 127);
        return @bitCast(sign | (exp32 << 23) | (mant << 13));
    }
    if (exp == 0x1f) {
        return @bitCast(sign | 0x7f800000 | (frac << 13));
    }
    const exp32 = exp + (127 - 15);
    return @bitCast(sign | (exp32 << 23) | (frac << 13));
}

fn checkedU64ToUsize(value: u64) !usize {
    if (value > std.math.maxInt(usize)) return error.IntegerOverflow;
    return @intCast(value);
}

test "half conversion handles common values" {
    try std.testing.expectEqual(@as(f32, 1.0), halfToF32(0x3c00));
    try std.testing.expectEqual(@as(f32, -2.0), halfToF32(0xc000));
    try std.testing.expectEqual(@as(f32, 0.5), halfToF32(0x3800));
}

test "Q8_0 matmul uses GGML block layout" {
    var bytes = [_]u8{0} ** (2 * block_q8_0_bytes);
    std.mem.writeInt(u16, bytes[0..2], 0x3c00, .little);
    for (0..qk8_0) |idx| bytes[2 + idx] = @bitCast(@as(i8, 1));
    std.mem.writeInt(u16, bytes[block_q8_0_bytes..][0..2], 0x4000, .little);
    for (0..qk8_0) |idx| bytes[block_q8_0_bytes + 2 + idx] = @bitCast(@as(i8, -1));

    const info = weights.TensorInfo{
        .name = "test.weight",
        .dimensions = .{ 32, 2, 0, 0, 0, 0, 0, 0 },
        .dimension_count = 2,
        .ggml_type = 8,
        .relative_offset = 0,
        .absolute_offset = 0,
        .byte_len = bytes.len,
    };
    const view = weights.TensorView{ .info = info, .bytes = &bytes };
    var input = [_]f32{1.0} ** qk8_0;
    var output = [_]f32{0.0} ** 2;
    try matmulQ8_0Vector(view, &input, &output);
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), output[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -64.0), output[1], 0.0001);
}
