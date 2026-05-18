const std = @import("std");
const weights = @import("weights.zig");
const inference = @import("inference.zig");
const gemma_config = @import("config.zig");
const vsa = @import("../vsa_math.zig");
const rune_encoder = @import("rune_encoder.zig");

pub const Intent = enum {
    query,
    etch,
    prove,
    converse,

    pub fn parse(raw: []const u8) ?Intent {
        if (std.mem.eql(u8, raw, "query")) return .query;
        if (std.mem.eql(u8, raw, "etch")) return .etch;
        if (std.mem.eql(u8, raw, "prove")) return .prove;
        if (std.mem.eql(u8, raw, "converse")) return .converse;
        return null;
    }
};

pub const Confidence = enum {
    low,
    medium,
    high,

    pub fn parse(raw: []const u8) ?Confidence {
        if (std.mem.eql(u8, raw, "low")) return .low;
        if (std.mem.eql(u8, raw, "medium")) return .medium;
        if (std.mem.eql(u8, raw, "high")) return .high;
        return null;
    }

    pub fn queryThreshold(self: Confidence) f32 {
        return switch (self) {
            .high => 0.75,
            .medium => 0.50,
            .low => 0.30,
        };
    }
};

pub const AgentStatus = enum {
    supported,
    unresolved,
    etched,
    converse,
};

pub const AgentInput = struct {
    intent: Intent,
    subject: []const u8,
    context_hints: []const []const u8 = &.{},
    confidence_required: Confidence = .high,
    needs_ghost: bool,
    original_message: []const u8 = "",
    source: []const u8 = "",
    explicit_store: bool = false,
    resonance: f32 = 0.0,
    decision_trace: bool = false,
    evidence_trace: bool = false,
    allocator: ?std.mem.Allocator = null,
};

pub const ResultPayload = struct {
    status: AgentStatus,
    subject: []const u8,
    confidence_required: Confidence,
    needs_ghost: bool,
    resonance: f32,
    proof_chain_present: bool,
    unresolved_reason: []const u8 = "",
    read_only: bool = true,
    matrix_mutation_allowed: bool = false,
    chat_response: ?[]const u8 = null,
};

pub fn route(input: AgentInput) ResultPayload {
    return switch (input.intent) {
        .query, .prove => runQueryAgent(input),
        .converse => runConversationAgent(input),
        .etch => runEtchAgent(input),
    };
}

pub fn runQueryAgent(input: AgentInput) ResultPayload {
    if (!input.needs_ghost) return unresolved(input, "query_requires_ghost");
    if (input.subject.len < 5) return unresolved(input, "subject_too_short");
    if (input.context_hints.len == 0 or input.context_hints.len > 5) return unresolved(input, "invalid_context_hint_count");
    
    const allocator = input.allocator orelse std.heap.page_allocator;
    const dynamic_res = evaluateNeuralIntent(allocator, input);

    if (dynamic_res < input.confidence_required.queryThreshold()) return unresolved(input, "resonance_below_threshold");
    if (!input.decision_trace or !input.evidence_trace) return unresolved(input, "missing_required_traces");
    return .{
        .status = .supported,
        .subject = input.subject,
        .confidence_required = input.confidence_required,
        .needs_ghost = true,
        .resonance = dynamic_res,
        .proof_chain_present = true,
        .read_only = true,
        .matrix_mutation_allowed = false,
    };
}

pub fn runConversationAgent(input: AgentInput) ResultPayload {
    if (input.needs_ghost) return unresolved(input, "conversation_must_not_require_ghost");
    if (input.intent != .converse) return unresolved(input, "invalid_conversation_intent");
    
    const allocator = input.allocator orelse std.heap.page_allocator;
    const dynamic_res = evaluateNeuralIntent(allocator, input);

    // Dynamic neural resonance check driven by gemma_trainer.md few-shot forward pass
    if (dynamic_res < 0.25) return unresolved(input, "low_semantic_resonance_for_conversation");

    const msg = if (input.original_message.len > 0) input.original_message else input.subject;

    var chat_resp: []const u8 = "I understand. I'm standing by for technical intent grounding or VSA search requests.";

    // Resolve GGUF weights path
    const weights_path = resolveDefaultWeightsPath(allocator) catch null;
    defer if (weights_path) |p| allocator.free(p);

    if (weights_path) |path| {
        if (weights.GGUFLoader.init(allocator, path)) |var_loader| {
            var loader = var_loader;
            defer loader.deinit();
            const harness = inference.ReferenceInferenceHarness.initWithLoader(allocator, &loader, 1536, 32, null);
            if (harness.forward(msg, 0)) |summary| {
                const csum = summary.checksum();
                // Use the authentic De-Rotor synthesized prose directly from the neural forward pass
                chat_resp = std.fmt.allocPrint(allocator, "{s} (Gemma 4 GGUF active, hypervector checksum 0x{x})", .{summary.prose, csum}) catch summary.prose;
            } else |_| {}
        } else |_| {
            const harness = inference.ReferenceInferenceHarness.init(allocator, 1536, 32, null);
            if (harness.forward(msg, 0)) |summary| {
                chat_resp = summary.prose;
            } else |_| {}
        }
    } else {
        const harness = inference.ReferenceInferenceHarness.init(allocator, 1536, 32, null);
        if (harness.forward(msg, 0)) |summary| {
            chat_resp = summary.prose;
        } else |_| {}
    }

    return .{
        .status = .converse,
        .subject = if (input.subject.len > 0) input.subject else input.original_message,
        .confidence_required = .low,
        .needs_ghost = false,
        .resonance = dynamic_res,
        .proof_chain_present = false,
        .read_only = true,
        .matrix_mutation_allowed = false,
        .chat_response = chat_resp,
    };
}

pub fn runEtchAgent(input: AgentInput) ResultPayload {
    if (!input.needs_ghost) return unresolved(input, "etch_requires_ghost");
    if (!input.explicit_store or !std.mem.eql(u8, input.source, "user_explicit")) return unresolved(input, "etch_requires_explicit_user_source");
    if (input.subject.len < 10) return unresolved(input, "subject_too_short_for_etch");
    if (input.context_hints.len < 2) return unresolved(input, "etch_requires_two_context_hints");

    const allocator = input.allocator orelse std.heap.page_allocator;
    const dynamic_res = evaluateNeuralIntent(allocator, input);

    return .{
        .status = .etched,
        .subject = input.subject,
        .confidence_required = input.confidence_required,
        .needs_ghost = true,
        .resonance = dynamic_res,
        .proof_chain_present = false,
        .read_only = false,
        .matrix_mutation_allowed = true,
    };
}

fn evaluateNeuralIntent(allocator: std.mem.Allocator, input: AgentInput) f32 {
    if (input.resonance > 0.0) return input.resonance; // Honor explicit test/CLI override

    const text = if (input.subject.len > 0) input.subject else input.original_message;
    const input_vec = rune_encoder.buildHyperRotor(text);

    // Attempt to load gemma_trainer.md to perform few-shot VSA resonance matching
    if (resolveTrainerPath(allocator)) |trainer_path| {
        defer allocator.free(trainer_path);
        if (std.fs.cwd().openFile(trainer_path, .{})) |file| {
            defer file.close();
            if (file.readToEndAlloc(allocator, 1024 * 1024)) |content| {
                defer allocator.free(content);

                var max_res: f32 = -1.0;
                var lines = std.mem.splitScalar(u8, content, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \r\t");
                    if (!std.mem.startsWith(u8, trimmed, "{\"messages\"")) continue;

                    // Parse the JSON line to extract user content and assistant intent
                    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
                        defer parsed.deinit();
                        const root = parsed.value;
                        if (root == .object) {
                            if (root.object.get("messages")) |msgs| {
                                if (msgs == .array and msgs.array.items.len >= 2) {
                                    const user_msg = msgs.array.items[0];
                                    const asst_msg = msgs.array.items[1];
                                    if (user_msg == .object and asst_msg == .object) {
                                        if (user_msg.object.get("content")) |u_content| {
                                            if (asst_msg.object.get("content")) |a_content| {
                                                if (u_content == .string and a_content == .string) {
                                                    // Parse the inner assistant JSON
                                                    if (std.json.parseFromSlice(std.json.Value, allocator, a_content.string, .{})) |inner_parsed| {
                                                        defer inner_parsed.deinit();
                                                        const inner = inner_parsed.value;
                                                        if (inner == .object) {
                                                            if (inner.object.get("intent")) |intent_val| {
                                                                if (intent_val == .string) {
                                                                    if (Intent.parse(intent_val.string)) |sample_intent| {
                                                                        if (sample_intent == input.intent) {
                                                                            const sample_vec = rune_encoder.buildHyperRotor(u_content.string);
                                                                            const r = vsa.calculateResonance(input_vec, sample_vec);
                                                                            const rf = @as(f32, @floatFromInt(r)) / 1024.0;
                                                                            if (rf > max_res) max_res = rf;
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    } else |_| {}
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else |_| {}
                }

                if (max_res >= 0.0) {
                    return max_res;
                }
            } else |_| {}
        } else |_| {}
    } else |_| {}

    // Fallback to orthogonal route vector resonance if trainer file is unavailable or has no matching samples
    var hasher = std.hash.Wyhash.init(0x12345678);
    hasher.update(text);
    const subject_vec = vsa.generate(hasher.final());

    const target_vec = switch (input.intent) {
        .query, .prove => vsa.ROUTE_VEC_Z3,
        .converse => vsa.ROUTE_VEC_SCALAR,
        .etch => vsa.ROUTE_VEC_VSA,
    };

    const res = vsa.calculateResonance(subject_vec, target_vec);
    return @as(f32, @floatFromInt(res)) / 1024.0;
}


fn unresolved(input: AgentInput, reason: []const u8) ResultPayload {
    return .{
        .status = .unresolved,
        .subject = input.subject,
        .confidence_required = input.confidence_required,
        .needs_ghost = input.needs_ghost,
        .resonance = input.resonance,
        .proof_chain_present = input.decision_trace and input.evidence_trace,
        .unresolved_reason = reason,
        .read_only = true,
        .matrix_mutation_allowed = false,
    };
}

pub fn statusName(status: AgentStatus) []const u8 {
    return switch (status) {
        .supported => "supported",
        .unresolved => "unresolved",
        .etched => "etched",
        .converse => "converse",
    };
}

pub fn intentName(intent: Intent) []const u8 {
    return switch (intent) {
        .query => "query",
        .etch => "etch",
        .prove => "prove",
        .converse => "converse",
    };
}

pub fn confidenceName(confidence: Confidence) []const u8 {
    return switch (confidence) {
        .low => "low",
        .medium => "medium",
        .high => "high",
    };
}

fn resolveDefaultWeightsPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("GHOST_ENGINE_ROOT")) |root| {
        return std.fs.path.join(allocator, &.{ root, gemma_config.default_weights_path });
    }

    if (std.fs.cwd().access(gemma_config.default_weights_path, .{})) |_| {
        return allocator.dupe(u8, gemma_config.default_weights_path);
    } else |_| {}

    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch {
        return allocator.dupe(u8, gemma_config.default_weights_path);
    };
    defer allocator.free(exe_dir);

    var current_dir: []const u8 = exe_dir;
    while (true) {
        const candidate = std.fs.path.join(allocator, &.{ current_dir, gemma_config.default_weights_path }) catch break;
        if (std.fs.cwd().access(candidate, .{})) |_| {
            return candidate;
        } else |_| {}
        allocator.free(candidate);

        const next_dir = std.fs.path.dirname(current_dir);
        if (next_dir) |p| {
            if (std.mem.eql(u8, p, current_dir)) break;
            current_dir = p;
        } else {
            break;
        }
    }

    return allocator.dupe(u8, gemma_config.default_weights_path);
}

fn resolveTrainerPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("GHOST_ENGINE_ROOT")) |root| {
        return std.fs.path.join(allocator, &.{ root, "gemma_trainer.md" });
    }

    if (std.fs.cwd().access("gemma_trainer.md", .{})) |_| {
        return allocator.dupe(u8, "gemma_trainer.md");
    } else |_| {}

    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch {
        return allocator.dupe(u8, "gemma_trainer.md");
    };
    defer allocator.free(exe_dir);

    var current_dir: []const u8 = exe_dir;
    while (true) {
        const candidate = std.fs.path.join(allocator, &.{ current_dir, "gemma_trainer.md" }) catch break;
        if (std.fs.cwd().access(candidate, .{})) |_| {
            return candidate;
        } else |_| {}
        allocator.free(candidate);

        const next_dir = std.fs.path.dirname(current_dir);
        if (next_dir) |p| {
            if (std.mem.eql(u8, p, current_dir)) break;
            current_dir = p;
        } else {
            break;
        }
    }

    return allocator.dupe(u8, "gemma_trainer.md");
}

test "query agent refuses support without both traces" {
    const hints = [_][]const u8{"memory"};
    const result = route(.{
        .intent = .query,
        .subject = "memory allocation",
        .context_hints = &hints,
        .confidence_required = .high,
        .needs_ghost = true,
        .resonance = 0.95,
        .decision_trace = true,
        .evidence_trace = false,
    });
    try std.testing.expectEqual(AgentStatus.unresolved, result.status);
    try std.testing.expectEqualStrings("missing_required_traces", result.unresolved_reason);
}

test "query agent supports only after resonance and proof gates pass" {
    const hints = [_][]const u8{"memory"};
    const result = route(.{
        .intent = .query,
        .subject = "memory allocation",
        .context_hints = &hints,
        .confidence_required = .high,
        .needs_ghost = true,
        .resonance = 0.95,
        .decision_trace = true,
        .evidence_trace = true,
    });
    try std.testing.expectEqual(AgentStatus.supported, result.status);
    try std.testing.expect(result.read_only);
    try std.testing.expect(!result.matrix_mutation_allowed);
}

test "etch agent requires explicit user source" {
    const hints = [_][]const u8{ "ghost", "memory" };
    const result = route(.{
        .intent = .etch,
        .subject = "store memory allocation policy",
        .context_hints = &hints,
        .needs_ghost = true,
        .source = "gemma_output",
        .explicit_store = true,
    });
    try std.testing.expectEqual(AgentStatus.unresolved, result.status);
}

test "conversation agent refuses ghost requirement" {
    const result = route(.{
        .intent = .converse,
        .subject = "hello",
        .needs_ghost = true,
    });
    try std.testing.expectEqual(AgentStatus.unresolved, result.status);
}

test "evaluateNeuralIntent matches few-shot samples from gemma_trainer.md" {
    const hints = [_][]const u8{"malloc", "C"};
    const result = route(.{
        .intent = .query,
        .subject = "how does malloc work in C",
        .context_hints = &hints,
        .confidence_required = .high,
        .needs_ghost = true,
        .resonance = 0.0, // Force few-shot VSA resonance matching
        .decision_trace = true,
        .evidence_trace = true,
    });
    try std.testing.expectEqual(AgentStatus.supported, result.status);
    try std.testing.expect(result.resonance > 0.5);
}

