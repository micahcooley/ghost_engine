const std = @import("std");
const agents = @import("agents.zig");
const forward_schedule = @import("forward_schedule.zig");
const gemma_config = @import("config.zig");
const inference = @import("inference.zig");
const model = @import("model.zig");
const q8_matmul = @import("q8_matmul.zig");
const weights = @import("weights.zig");
const vsa_math = @import("../vsa_math.zig");
const rune_encoder = @import("rune_encoder.zig");

const usage =
    \\Usage:
    \\  ghost_gemma weights inspect [--path <model.gguf>] [--json] [--tensor-prefix <prefix>] [--limit <n>]
    \\  ghost_gemma matmul calibrate [--path <model.gguf>] [--tensor <name>] [--rows <n>] [--seed <u64>] [--json]
    \\  ghost_gemma inference smoke --text <text> [--path <model.gguf>] [--top-k <n>] [--embedding-len <n>] [--session-id <u64>] [--json]
    \\  ghost_gemma inference plan [--path <model.gguf>] [--json] [--limit <n>]
    \\  ghost_gemma agent route --intent <query|etch|prove|converse> --subject <text> [--hint <text>...] [--confidence <low|medium|high>] [--needs-ghost <true|false>] [--resonance <f32>] [--decision-trace] [--evidence-trace] [--source <source>] [--explicit-store] [--json]
    \\
;

const Options = struct {
    path: ?[]const u8 = null,
    json: bool = false,
    tensor_prefix: ?[]const u8 = null,
    limit: usize = 32,
    tensor: []const u8 = "blk.0.attn_q.weight",
    rows: usize = 8,
    seed: u64 = 0x67686f73745f7138,
    text: ?[]const u8 = null,
    top_k: ?usize = null,
    embedding_len: ?usize = null,
    session_id: u64 = 1,
    intent: ?agents.Intent = null,
    subject: ?[]const u8 = null,
    confidence: agents.Confidence = .high,
    needs_ghost: ?bool = null,
    resonance: f32 = 0.0,
    decision_trace: bool = false,
    evidence_trace: bool = false,
    source: []const u8 = "",
    explicit_store: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    const first = args.next() orelse return printUsageAndExit(1);
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "help")) return printUsageAndExit(0);
    if (!std.mem.eql(u8, first, "weights") and !std.mem.eql(u8, first, "matmul") and !std.mem.eql(u8, first, "inference") and !std.mem.eql(u8, first, "agent")) return fail("unknown command: {s}", .{first});
    const second = args.next() orelse return printUsageAndExit(1);
    const command = Command.parse(first, second) orelse return fail("unknown command: {s} {s}", .{ first, second });

    var options = Options{};
    var context_hints = std.ArrayList([]const u8).init(allocator);
    defer context_hints.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--path")) {
            options.path = args.next() orelse return failMissing("--path");
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            options.path = arg["--path=".len..];
        } else if (std.mem.eql(u8, arg, "--tensor-prefix")) {
            options.tensor_prefix = args.next() orelse return failMissing("--tensor-prefix");
        } else if (std.mem.startsWith(u8, arg, "--tensor-prefix=")) {
            options.tensor_prefix = arg["--tensor-prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            options.limit = try parseLimit(args.next() orelse return failMissing("--limit"));
        } else if (std.mem.startsWith(u8, arg, "--limit=")) {
            options.limit = try parseLimit(arg["--limit=".len..]);
        } else if (std.mem.eql(u8, arg, "--tensor")) {
            options.tensor = args.next() orelse return failMissing("--tensor");
        } else if (std.mem.startsWith(u8, arg, "--tensor=")) {
            options.tensor = arg["--tensor=".len..];
        } else if (std.mem.eql(u8, arg, "--rows")) {
            options.rows = try parseLimit(args.next() orelse return failMissing("--rows"));
        } else if (std.mem.startsWith(u8, arg, "--rows=")) {
            options.rows = try parseLimit(arg["--rows=".len..]);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            options.seed = try parseU64("--seed", args.next() orelse return failMissing("--seed"));
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            options.seed = try parseU64("--seed", arg["--seed=".len..]);
        } else if (std.mem.eql(u8, arg, "--text")) {
            options.text = args.next() orelse return failMissing("--text");
        } else if (std.mem.startsWith(u8, arg, "--text=")) {
            options.text = arg["--text=".len..];
        } else if (std.mem.eql(u8, arg, "--top-k")) {
            options.top_k = try parseLimit(args.next() orelse return failMissing("--top-k"));
        } else if (std.mem.startsWith(u8, arg, "--top-k=")) {
            options.top_k = try parseLimit(arg["--top-k=".len..]);
        } else if (std.mem.eql(u8, arg, "--embedding-len")) {
            options.embedding_len = try parseLimit(args.next() orelse return failMissing("--embedding-len"));
        } else if (std.mem.startsWith(u8, arg, "--embedding-len=")) {
            options.embedding_len = try parseLimit(arg["--embedding-len=".len..]);
        } else if (std.mem.eql(u8, arg, "--session-id")) {
            options.session_id = try parseU64("--session-id", args.next() orelse return failMissing("--session-id"));
        } else if (std.mem.startsWith(u8, arg, "--session-id=")) {
            options.session_id = try parseU64("--session-id", arg["--session-id=".len..]);
        } else if (std.mem.eql(u8, arg, "--intent")) {
            options.intent = agents.Intent.parse(args.next() orelse return failMissing("--intent")) orelse return fail("invalid --intent", .{});
        } else if (std.mem.startsWith(u8, arg, "--intent=")) {
            options.intent = agents.Intent.parse(arg["--intent=".len..]) orelse return fail("invalid --intent", .{});
        } else if (std.mem.eql(u8, arg, "--subject")) {
            options.subject = args.next() orelse return failMissing("--subject");
        } else if (std.mem.startsWith(u8, arg, "--subject=")) {
            options.subject = arg["--subject=".len..];
        } else if (std.mem.eql(u8, arg, "--hint")) {
            try context_hints.append(args.next() orelse return failMissing("--hint"));
        } else if (std.mem.startsWith(u8, arg, "--hint=")) {
            try context_hints.append(arg["--hint=".len..]);
        } else if (std.mem.eql(u8, arg, "--confidence")) {
            options.confidence = agents.Confidence.parse(args.next() orelse return failMissing("--confidence")) orelse return fail("invalid --confidence", .{});
        } else if (std.mem.startsWith(u8, arg, "--confidence=")) {
            options.confidence = agents.Confidence.parse(arg["--confidence=".len..]) orelse return fail("invalid --confidence", .{});
        } else if (std.mem.eql(u8, arg, "--needs-ghost")) {
            options.needs_ghost = try parseBool("--needs-ghost", args.next() orelse return failMissing("--needs-ghost"));
        } else if (std.mem.startsWith(u8, arg, "--needs-ghost=")) {
            options.needs_ghost = try parseBool("--needs-ghost", arg["--needs-ghost=".len..]);
        } else if (std.mem.eql(u8, arg, "--resonance")) {
            options.resonance = try parseF32("--resonance", args.next() orelse return failMissing("--resonance"));
        } else if (std.mem.startsWith(u8, arg, "--resonance=")) {
            options.resonance = try parseF32("--resonance", arg["--resonance=".len..]);
        } else if (std.mem.eql(u8, arg, "--decision-trace")) {
            options.decision_trace = true;
        } else if (std.mem.eql(u8, arg, "--evidence-trace")) {
            options.evidence_trace = true;
        } else if (std.mem.eql(u8, arg, "--source")) {
            options.source = args.next() orelse return failMissing("--source");
        } else if (std.mem.startsWith(u8, arg, "--source=")) {
            options.source = arg["--source=".len..];
        } else if (std.mem.eql(u8, arg, "--explicit-store")) {
            options.explicit_store = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            return printUsageAndExit(0);
        } else {
            return fail("unknown option: {s}", .{arg});
        }
    }

    if (command == .agent_route) {
        const result = try runAgentRouteCommand(allocator, options, context_hints.items);
        if (options.json) {
            try printAgentRouteJson(std.io.getStdOut().writer(), result);
        } else {
            try printAgentRouteHuman(std.io.getStdOut().writer(), result);
        }
        return;
    }

    const model_path = if (options.path) |path|
        try allocator.dupe(u8, path)
    else
        try resolveDefaultWeightsPath(allocator);
    defer allocator.free(model_path);

    var loader = weights.GGUFLoader.init(allocator, model_path) catch |err| {
        try std.io.getStdErr().writer().print("Error: failed to inspect GGUF '{s}': {s}\n", .{ model_path, @errorName(err) });
        std.process.exit(1);
    };
    defer loader.deinit();

    switch (command) {
        .weights_inspect => {
            if (options.json) {
                try printJson(std.io.getStdOut().writer(), loader, model_path, options);
            } else {
                try printHuman(std.io.getStdOut().writer(), loader, model_path, options);
            }
        },
        .matmul_calibrate => {
            const summary = q8_matmul.calibrateQ8_0(allocator, &loader, options.tensor, options.seed, options.rows) catch |err| {
                try std.io.getStdErr().writer().print("Error: Q8_0 calibration failed for tensor '{s}': {s}\n", .{ options.tensor, @errorName(err) });
                std.process.exit(1);
            };
            if (options.json) {
                try printCalibrationJson(std.io.getStdOut().writer(), model_path, summary, options.seed);
            } else {
                try printCalibrationHuman(std.io.getStdOut().writer(), model_path, summary, options.seed);
            }
        },
        .inference_smoke => {
            const text = options.text orelse return fail("--text is required for inference smoke", .{});
            const manifest = model.GhostGemmaModel.initFromLoader(&loader) catch |err| {
                try std.io.getStdErr().writer().print("Error: failed to read Gemma model shape from '{s}': {s}\n", .{ model_path, @errorName(err) });
                std.process.exit(1);
            };
            const embedding_len = options.embedding_len orelse manifest.shape.embedding_length;
            const top_k = options.top_k orelse gemma_config.default_attention_top_k;
            const harness = inference.ReferenceInferenceHarness.init(allocator, embedding_len, top_k);
            const summary = harness.forward(text, options.session_id) catch |err| {
                try std.io.getStdErr().writer().print("Error: inference smoke failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer summary.deinit(allocator);
            if (options.json) {
                try printInferenceSmokeJson(std.io.getStdOut().writer(), model_path, text, summary);
            } else {
                try printInferenceSmokeHuman(std.io.getStdOut().writer(), model_path, text, summary);
            }
        },
        .inference_plan => {
            const manifest = model.GhostGemmaModel.initFromLoader(&loader) catch |err| {
                try std.io.getStdErr().writer().print("Error: failed to read Gemma model shape from '{s}': {s}\n", .{ model_path, @errorName(err) });
                std.process.exit(1);
            };
            var schedule = forward_schedule.build(allocator, manifest.shape) catch |err| {
                try std.io.getStdErr().writer().print("Error: failed to build Gemma Vulkan schedule: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer schedule.deinit(allocator);
            if (options.json) {
                try printInferencePlanJson(std.io.getStdOut().writer(), model_path, schedule, options.limit);
            } else {
                try printInferencePlanHuman(std.io.getStdOut().writer(), model_path, schedule, options.limit);
            }
        },
        .agent_route => {
            unreachable;
        },
    }
}

const Command = enum {
    weights_inspect,
    matmul_calibrate,
    inference_smoke,
    inference_plan,
    agent_route,

    fn parse(first: []const u8, second: []const u8) ?Command {
        if (std.mem.eql(u8, first, "weights") and std.mem.eql(u8, second, "inspect")) return .weights_inspect;
        if (std.mem.eql(u8, first, "matmul") and std.mem.eql(u8, second, "calibrate")) return .matmul_calibrate;
        if (std.mem.eql(u8, first, "inference") and std.mem.eql(u8, second, "smoke")) return .inference_smoke;
        if (std.mem.eql(u8, first, "inference") and std.mem.eql(u8, second, "plan")) return .inference_plan;
        if (std.mem.eql(u8, first, "agent") and std.mem.eql(u8, second, "route")) return .agent_route;
        return null;
    }
};

fn printHuman(writer: anytype, loader: weights.GGUFLoader, model_path: []const u8, options: Options) !void {
    try writer.writeAll("Ghost Gemma Weight Inventory\n");
    try writer.writeAll("State: READ-ONLY / NON-AUTHORIZING / WEIGHT METADATA ONLY\n");
    try writer.print("Path: {s}\n", .{model_path});
    try writer.print("GGUF: version={d} tensors={d} metadata={d} alignment={d} dataStart={d}\n", .{
        loader.version,
        loader.tensor_count,
        loader.metadata_count,
        loader.alignment,
        loader.data_start,
    });
    try printMetadataLine(writer, loader, "general.architecture", "Architecture");
    try printMetadataLine(writer, loader, "general.name", "Name");
    try printMetadataLine(writer, loader, "gemma4.block_count", "Layer Count");
    try printMetadataLine(writer, loader, "gemma4.embedding_length", "Embedding Length");
    try printMetadataLine(writer, loader, "gemma4.feed_forward_length", "FFN Length");
    try printMetadataLine(writer, loader, "gemma4.attention.head_count", "Attention Heads");
    try printMetadataLine(writer, loader, "gemma4.attention.head_count_kv", "KV Heads");
    try printMetadataLine(writer, loader, "gemma4.attention.key_length", "Attention Key Length");
    try printMetadataLine(writer, loader, "gemma4.attention.key_length_swa", "Attention Key Length SWA");
    try printMetadataLine(writer, loader, "gemma4.attention.value_length", "Attention Value Length");
    try printMetadataLine(writer, loader, "gemma4.attention.value_length_swa", "Attention Value Length SWA");
    try printMetadataLine(writer, loader, "gemma4.embedding_length_per_layer_input", "Per-Layer Input Length");
    try printMetadataLine(writer, loader, "gemma4.context_length", "Context Length");
    try writer.print("Token embedding present: {s}\n", .{yesNo(loader.containsTensor("token_embd.weight"))});
    try writer.print("Output head present: {s}\n", .{yesNo(loader.containsTensor("output.weight"))});
    try writer.print("Ghost-native replacements: token_embd.weight and output.weight are inventoried but not used by the rune path.\n", .{});

    const prefix = options.tensor_prefix orelse "";
    try writer.print("\nTensor sample", .{});
    if (prefix.len > 0) try writer.print(" (prefix: {s})", .{prefix});
    try writer.print(":\n", .{});
    try printTensorRows(writer, loader, prefix, options.limit);
}

fn printJson(writer: anytype, loader: weights.GGUFLoader, model_path: []const u8, options: Options) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"kind\":\"gemma.weights.inspect\",");
    try writer.writeAll("\"state\":\"read_only_non_authorizing_weight_metadata_only\",");
    try writer.print("\"path\":{},", .{std.json.fmt(model_path, .{})});
    try writer.print("\"version\":{d},\"tensorCount\":{d},\"metadataCount\":{d},\"alignment\":{d},\"dataStart\":{d},", .{
        loader.version,
        loader.tensor_count,
        loader.metadata_count,
        loader.alignment,
        loader.data_start,
    });
    try writer.writeAll("\"metadata\":{");
    try printJsonMetadataField(writer, loader, "general.architecture", "architecture", true);
    try printJsonMetadataField(writer, loader, "general.name", "name", false);
    try printJsonMetadataField(writer, loader, "gemma4.block_count", "blockCount", false);
    try printJsonMetadataField(writer, loader, "gemma4.embedding_length", "embeddingLength", false);
    try printJsonMetadataField(writer, loader, "gemma4.feed_forward_length", "feedForwardLength", false);
    try printJsonMetadataField(writer, loader, "gemma4.attention.head_count", "attentionHeadCount", false);
    try printJsonMetadataField(writer, loader, "gemma4.attention.head_count_kv", "attentionHeadCountKv", false);
    try printJsonMetadataField(writer, loader, "gemma4.attention.key_length", "attentionKeyLength", false);
    try printJsonMetadataField(writer, loader, "gemma4.attention.key_length_swa", "attentionKeyLengthSwa", false);
    try printJsonMetadataField(writer, loader, "gemma4.attention.value_length", "attentionValueLength", false);
    try printJsonMetadataField(writer, loader, "gemma4.attention.value_length_swa", "attentionValueLengthSwa", false);
    try printJsonMetadataField(writer, loader, "gemma4.embedding_length_per_layer_input", "embeddingLengthPerLayerInput", false);
    try printJsonMetadataField(writer, loader, "gemma4.context_length", "contextLength", false);
    try writer.writeAll("},");
    try writer.print("\"tokenEmbeddingPresent\":{},\"outputHeadPresent\":{},", .{
        loader.containsTensor("token_embd.weight"),
        loader.containsTensor("output.weight"),
    });
    try writer.print("\"tensorPrefix\":{},\"tensorSample\":[", .{std.json.fmt(options.tensor_prefix orelse "", .{})});
    try printTensorRowsJson(writer, loader, options.tensor_prefix orelse "", options.limit);
    try writer.writeAll("]}\n");
}

fn printMetadataLine(writer: anytype, loader: weights.GGUFLoader, key: []const u8, label: []const u8) !void {
    const value = loader.metadataValue(key) orelse return;
    try writer.print("{s}: ", .{label});
    try printMetadataValue(writer, value);
    try writer.writeByte('\n');
}

fn printMetadataValue(writer: anytype, value: weights.MetadataValue) !void {
    switch (value) {
        .uint => |v| try writer.print("{d}", .{v}),
        .int => |v| try writer.print("{d}", .{v}),
        .float => |v| try writer.print("{d}", .{v}),
        .bool => |v| try writer.print("{s}", .{yesNo(v)}),
        .string => |v| try writer.print("{s}", .{v}),
        .array => |v| try writer.print("array<{s}>[{d}]", .{ v.element_type.label(), v.len }),
    }
}

fn printJsonMetadataField(writer: anytype, loader: weights.GGUFLoader, key: []const u8, out_key: []const u8, first: bool) !void {
    const value = loader.metadataValue(key) orelse return;
    if (!first) try writer.writeByte(',');
    try writer.print("{}:", .{std.json.fmt(out_key, .{})});
    switch (value) {
        .uint => |v| try writer.print("{d}", .{v}),
        .int => |v| try writer.print("{d}", .{v}),
        .float => |v| try writer.print("{d}", .{v}),
        .bool => |v| try writer.print("{}", .{v}),
        .string => |v| try writer.print("{}", .{std.json.fmt(v, .{})}),
        .array => |v| try writer.print("{{\"elementType\":{},\"len\":{d}}}", .{ std.json.fmt(v.element_type.label(), .{}), v.len }),
    }
}

fn printTensorRows(writer: anytype, loader: weights.GGUFLoader, prefix: []const u8, limit: usize) !void {
    var printed: usize = 0;
    var it = loader.tensors.iterator();
    while (it.next()) |entry| {
        if (prefix.len > 0 and !std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
        if (printed >= limit) break;
        const info = entry.value_ptr.*;
        try writer.print("  - {s} ", .{info.name});
        try weights.formatShape(writer, info);
        try writer.print(" type={s} offset={d} bytes={d}\n", .{
            weights.ggmlTypeName(info.ggml_type),
            info.relative_offset,
            info.byte_len,
        });
        printed += 1;
    }
    if (printed == 0) try writer.writeAll("  <none>\n");
}

fn printTensorRowsJson(writer: anytype, loader: weights.GGUFLoader, prefix: []const u8, limit: usize) !void {
    var printed: usize = 0;
    var it = loader.tensors.iterator();
    while (it.next()) |entry| {
        if (prefix.len > 0 and !std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
        if (printed >= limit) break;
        const info = entry.value_ptr.*;
        if (printed > 0) try writer.writeByte(',');
        try writer.print("{{\"name\":{},\"shape\":[", .{std.json.fmt(info.name, .{})});
        for (0..info.dimension_count) |idx| {
            if (idx > 0) try writer.writeByte(',');
            try writer.print("{d}", .{info.dimensions[idx]});
        }
        try writer.print("],\"type\":{},\"relativeOffset\":{d},\"byteLength\":{d}}}", .{
            std.json.fmt(weights.ggmlTypeName(info.ggml_type), .{}),
            info.relative_offset,
            info.byte_len,
        });
        printed += 1;
    }
}

fn printCalibrationHuman(writer: anytype, model_path: []const u8, summary: q8_matmul.CalibrationSummary, seed: u64) !void {
    try writer.writeAll("Ghost Gemma Q8_0 Matmul Calibration\n");
    try writer.writeAll("State: READ-ONLY / NON-AUTHORIZING / NUMERIC CALIBRATION ONLY\n");
    try writer.print("Path: {s}\n", .{model_path});
    try writer.print("Tensor: {s}\n", .{summary.tensor_name});
    try writer.print("Shape: rows={d} cols={d} calibratedRows={d}\n", .{ summary.rows, summary.cols, summary.output_count });
    try writer.print("Seed: {d}\n", .{seed});
    try writer.print("Checksum: 0x{x:0>16}\n", .{summary.checksum});
    try writer.print("L1 Norm: {d:.6}\n", .{summary.l1_norm});
    try writer.print("Max Abs: {d:.6}\n", .{summary.max_abs});
    try writer.writeAll("First Values:");
    for (summary.first_values) |value| try writer.print(" {d:.6}", .{value});
    try writer.writeByte('\n');
}

fn printCalibrationJson(writer: anytype, model_path: []const u8, summary: q8_matmul.CalibrationSummary, seed: u64) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"kind\":\"gemma.matmul.calibrate\",");
    try writer.writeAll("\"state\":\"read_only_non_authorizing_numeric_calibration_only\",");
    try writer.print("\"path\":{},", .{std.json.fmt(model_path, .{})});
    try writer.print("\"tensor\":{},\"rows\":{d},\"cols\":{d},\"outputCount\":{d},\"seed\":{d},", .{
        std.json.fmt(summary.tensor_name, .{}),
        summary.rows,
        summary.cols,
        summary.output_count,
        seed,
    });
    try writer.print("\"checksum\":\"0x{x:0>16}\",\"l1Norm\":{d},\"maxAbs\":{d},\"firstValues\":[", .{
        summary.checksum,
        summary.l1_norm,
        summary.max_abs,
    });
    for (summary.first_values, 0..) |value, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{d}", .{value});
    }
    try writer.writeAll("]}\n");
}

fn printInferenceSmokeHuman(writer: anytype, model_path: []const u8, text: []const u8, summary: inference.ForwardSummary) !void {
    try writer.writeAll("Ghost Gemma Native Inference Smoke\n");
    try writer.writeAll("State: READ-ONLY / NON-AUTHORIZING / PHASE HARNESS ONLY / NOT FULL MODEL INFERENCE\n");
    try writer.print("Path: {s}\n", .{model_path});
    try writer.print("Input: {s}\n", .{text});
    try writer.print("Runes: {d}\n", .{summary.rune_count});
    try writer.print("Embedding Length: {d}\n", .{summary.embedding_len});
    try writer.print("Top K: {d}\n", .{summary.top_k});
    try writer.print("Attention Total Resonance: {d:.6}\n", .{summary.attention_total_resonance});
    try writer.print("Output Rune Checksum: 0x{x:0>16}\n", .{summary.checksum()});
    try writer.writeAll("Output Rune First Words:");
    for (0..4) |idx| try writer.print(" 0x{x:0>16}", .{summary.output_rune[idx]});
    try writer.writeByte('\n');
}

fn printInferenceSmokeJson(writer: anytype, model_path: []const u8, text: []const u8, summary: inference.ForwardSummary) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"kind\":\"gemma.inference.smoke\",");
    try writer.print("\"state\":{},", .{std.json.fmt(summary.state, .{})});
    try writer.print("\"path\":{},\"input\":{},", .{ std.json.fmt(model_path, .{}), std.json.fmt(text, .{}) });
    try writer.print("\"runeCount\":{d},\"embeddingLength\":{d},\"topK\":{d},", .{
        summary.rune_count,
        summary.embedding_len,
        summary.top_k,
    });
    try writer.print("\"attentionTotalResonance\":{d},\"outputRuneChecksum\":\"0x{x:0>16}\",\"outputRuneFirstWords\":[", .{
        summary.attention_total_resonance,
        summary.checksum(),
    });
    for (0..4) |idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("\"0x{x:0>16}\"", .{summary.output_rune[idx]});
    }
    try writer.writeAll("]}\n");
}

fn printInferencePlanHuman(writer: anytype, model_path: []const u8, schedule: forward_schedule.Schedule, limit: usize) !void {
    try writer.writeAll("Ghost Gemma Vulkan Forward Schedule\n");
    try writer.writeAll("State: READ-ONLY / NON-AUTHORIZING / VULKAN SCHEDULE / NOT NUMERIC INFERENCE OUTPUT\n");
    try writer.print("Path: {s}\n", .{model_path});
    try writer.print("Blocks: {d}\n", .{schedule.block_count});
    try writer.print("Embedding Length: {d}\n", .{schedule.embedding_len});
    try writer.print("Scheduled Steps: {d}\n", .{schedule.steps.len});
    const shown = @min(limit, schedule.steps.len);
    try writer.print("Step Sample ({d}/{d}):\n", .{ shown, schedule.steps.len });
    for (schedule.steps[0..shown], 0..) |step, idx| {
        try writer.print("  - {d}: {s}", .{ idx, @tagName(step.stage) });
        if (step.layer) |layer| try writer.print(" layer={d}", .{layer});
        try writer.print(" shader={s}", .{step.stage.shaderName()});
        if (step.ffn_dim != 0) try writer.print(" ffnDim={d}", .{step.ffn_dim});
        if (step.q_width != 0) try writer.print(" qWidth={d}", .{step.q_width});
        if (step.kv_width != 0) try writer.print(" kvWidth={d}", .{step.kv_width});
        try writer.writeByte('\n');
    }
}

fn printInferencePlanJson(writer: anytype, model_path: []const u8, schedule: forward_schedule.Schedule, limit: usize) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"kind\":\"gemma.inference.plan\",");
    try writer.writeAll("\"state\":\"read_only_non_authorizing_vulkan_schedule_not_numeric_output\",");
    try writer.print("\"path\":{},\"blockCount\":{d},\"embeddingLength\":{d},\"stepCount\":{d},\"steps\":[", .{
        std.json.fmt(model_path, .{}),
        schedule.block_count,
        schedule.embedding_len,
        schedule.steps.len,
    });
    const shown = @min(limit, schedule.steps.len);
    for (schedule.steps[0..shown], 0..) |step, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"index\":{d},\"stage\":{},\"shader\":{}", .{
            idx,
            std.json.fmt(@tagName(step.stage), .{}),
            std.json.fmt(step.stage.shaderName(), .{}),
        });
        if (step.layer) |layer| try writer.print(",\"layer\":{d}", .{layer});
        if (step.ffn_dim != 0) try writer.print(",\"ffnDim\":{d}", .{step.ffn_dim});
        if (step.q_width != 0) try writer.print(",\"qWidth\":{d}", .{step.q_width});
        if (step.kv_width != 0) try writer.print(",\"kvWidth\":{d}", .{step.kv_width});
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

fn printAgentRouteHuman(writer: anytype, result: agents.ResultPayload) !void {
    try writer.writeAll("Ghost Gemma Agent Route\n");
    try writer.writeAll("State: STRICT ROUTER / NON-AUTHORIZING UNLESS STATUS IS SUPPORTED / NO HIDDEN FALLBACK\n");
    try writer.print("Status: {s}\n", .{agents.statusName(result.status)});
    try writer.print("Subject: {s}\n", .{result.subject});
    try writer.print("Confidence Required: {s}\n", .{agents.confidenceName(result.confidence_required)});
    try writer.print("Needs Ghost: {s}\n", .{yesNo(result.needs_ghost)});
    try writer.print("Resonance: {d:.6}\n", .{result.resonance});
    try writer.print("Proof Chain Present: {s}\n", .{yesNo(result.proof_chain_present)});
    try writer.print("Read Only: {s}\n", .{yesNo(result.read_only)});
    try writer.print("Matrix Mutation Allowed: {s}\n", .{yesNo(result.matrix_mutation_allowed)});
    if (result.unresolved_reason.len > 0) try writer.print("Unresolved Reason: {s}\n", .{result.unresolved_reason});
}

fn printAgentRouteJson(writer: anytype, result: agents.ResultPayload) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"kind\":\"gemma.agent.route\",");
    try writer.writeAll("\"state\":\"strict_router_no_hidden_fallback\",");
    try writer.print("\"status\":{},\"subject\":{},", .{
        std.json.fmt(agents.statusName(result.status), .{}),
        std.json.fmt(result.subject, .{}),
    });
    try writer.print("\"confidenceRequired\":{},\"needsGhost\":{},\"resonance\":{d},", .{
        std.json.fmt(agents.confidenceName(result.confidence_required), .{}),
        result.needs_ghost,
        result.resonance,
    });
    try writer.print("\"proofChainPresent\":{},\"readOnly\":{},\"matrixMutationAllowed\":{},\"unresolvedReason\":{}", .{
        result.proof_chain_present,
        result.read_only,
        result.matrix_mutation_allowed,
        std.json.fmt(result.unresolved_reason, .{}),
    });
    try writer.writeAll("}\n");
}

fn runAgentRouteCommand(allocator: std.mem.Allocator, options: Options, context_hints: []const []const u8) !agents.ResultPayload {
    const intent = options.intent orelse return fail("--intent is required for agent route", .{});
    const subject = options.subject orelse return fail("--subject is required for agent route", .{});
    const needs_ghost = options.needs_ghost orelse defaultNeedsGhost(intent);

    var resonance = options.resonance;
    if (resonance == 0.0) {
        const encoder = rune_encoder.RuneEncoder.init(allocator, 1024);
        const runes = try encoder.encode(subject, 0);
        defer rune_encoder.freeRunes(allocator, runes);
        if (runes.len > 0) {
            const target_vec = switch (intent) {
                .query, .prove => vsa_math.ROUTE_VEC_VSA,
                .converse => vsa_math.ROUTE_VEC_SCALAR,
                .etch => vsa_math.ROUTE_VEC_VSA,
            };
            const res_u16 = vsa_math.resonanceScore(runes[runes.len - 1].vector, target_vec);
            resonance = @as(f32, @floatFromInt(res_u16)) / 1024.0;
        }
    }

    return agents.route(.{
        .intent = intent,
        .subject = subject,
        .context_hints = context_hints,
        .confidence_required = options.confidence,
        .needs_ghost = needs_ghost,
        .original_message = subject,
        .source = options.source,
        .explicit_store = options.explicit_store,
        .resonance = resonance,
        .decision_trace = options.decision_trace,
        .evidence_trace = options.evidence_trace,
    });
}

fn parseLimit(raw: []const u8) !usize {
    const parsed = std.fmt.parseInt(usize, raw, 10) catch fail("invalid --limit value: {s}", .{raw});
    if (parsed == 0) return fail("--limit must be greater than zero", .{});
    return parsed;
}

fn parseU64(flag: []const u8, raw: []const u8) !u64 {
    return std.fmt.parseInt(u64, raw, 0) catch fail("invalid {s} value: {s}", .{ flag, raw });
}

fn parseF32(flag: []const u8, raw: []const u8) !f32 {
    return std.fmt.parseFloat(f32, raw) catch fail("invalid {s} value: {s}", .{ flag, raw });
}

fn parseBool(flag: []const u8, raw: []const u8) !bool {
    if (std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "false")) return false;
    return fail("invalid {s} value: {s}", .{ flag, raw });
}

fn defaultNeedsGhost(intent: agents.Intent) bool {
    return intent != .converse;
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn resolveDefaultWeightsPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("GHOST_ENGINE_ROOT")) |root| {
        return std.fs.path.join(allocator, &.{ root, gemma_config.default_weights_path });
    }

    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch {
        return allocator.dupe(u8, gemma_config.default_weights_path);
    };
    defer allocator.free(exe_dir);

    const parent = std.fs.path.dirname(exe_dir) orelse return allocator.dupe(u8, gemma_config.default_weights_path);
    const project_root = std.fs.path.dirname(parent) orelse return allocator.dupe(u8, gemma_config.default_weights_path);
    return std.fs.path.join(allocator, &.{ project_root, gemma_config.default_weights_path });
}

fn printUsageAndExit(code: u8) noreturn {
    const writer = if (code == 0) std.io.getStdOut().writer() else std.io.getStdErr().writer();
    writer.writeAll(usage) catch {};
    std.process.exit(code);
}

fn failMissing(flag: []const u8) noreturn {
    fail("{s} requires a value", .{flag});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print(fmt ++ "\n", args) catch {};
    std.process.exit(1);
}
