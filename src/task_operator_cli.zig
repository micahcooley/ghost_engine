const std = @import("std");
const core = @import("ghost_core");
const compute_budget = core.compute_budget;
const conversation_session = core.conversation_session;
const external_evidence = core.external_evidence;
const operator_workflow = core.operator_workflow;
const response_engine = core.response_engine;
const sys = core.sys;

const Command = enum {
    project,
    start,
    run,
    resume_task,
    show,
    support,
    inspect,
    plan,
    verify,
    oracle,
    chat,
    replay,
};

pub fn main() !void {
    mainImpl() catch |err| switch (err) {
        error.InvalidArguments => {
            std.debug.print("ghost_task_operator: invalid arguments\nUse --help for usage.\n", .{});
            std.process.exit(2);
        },
        error.FileNotFound => {
            std.debug.print("ghost_task_operator: requested path or task state was not found\nUse --help for usage.\n", .{});
            std.process.exit(1);
        },
        error.AccessDenied => {
            std.debug.print("ghost_task_operator: requested path or task state could not be accessed\nUse --help for usage.\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
}

fn mainImpl() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        printUsage();
        return;
    }

    const command = parseCommand(args[1]) orelse {
        printUsage();
        return error.InvalidArguments;
    };

    const default_repo_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(default_repo_root);

    var repo_root: []const u8 = default_repo_root;
    var project_shard: ?[]const u8 = null;
    var task_id: ?[]const u8 = null;
    var intent_text: ?[]const u8 = null;
    var max_steps: u32 = 3;
    var max_items: usize = 8;
    var reopen = false;
    var emit_panic_dump = true;
    var allow_external_replay = true;
    var render_mode: operator_workflow.RenderMode = .summary;
    var request_label: ?[]const u8 = null;
    var chat_message: ?[]const u8 = null;
    var context_artifacts = std.ArrayList([]const u8).init(allocator);
    defer context_artifacts.deinit();
    var query_kind: ?core.code_intel.QueryKind = null;
    var target: ?[]const u8 = null;
    var other_target: ?[]const u8 = null;
    var patch_caps = core.patch_candidates.Caps{};
    var compute_request: compute_budget.Request = .{};
    var requested_reasoning: ?response_engine.ReasoningLevel = null;
    var compute_tier_explicit = false;
    var advanced = false;
    var evidence_urls = std.ArrayList([]const u8).init(allocator);
    defer evidence_urls.deinit();
    var evidence_queries = std.ArrayList(external_evidence.QueryInput).init(allocator);
    defer evidence_queries.deinit();
    var positionals = std.ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    for (args[2..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--repo=")) {
            repo_root = arg["--repo=".len..];
        } else if (std.mem.startsWith(u8, arg, "--project-shard=")) {
            const value = arg["--project-shard=".len..];
            if (value.len > 0) project_shard = value;
        } else if (std.mem.startsWith(u8, arg, "--task-id=")) {
            const value = arg["--task-id=".len..];
            if (value.len > 0) task_id = value;
        } else if (std.mem.startsWith(u8, arg, "--intent=")) {
            const value = arg["--intent=".len..];
            if (value.len > 0) intent_text = value;
        } else if (std.mem.startsWith(u8, arg, "--request=")) {
            const value = arg["--request=".len..];
            if (value.len > 0) request_label = value;
        } else if (std.mem.startsWith(u8, arg, "--message=")) {
            const value = arg["--message=".len..];
            if (value.len > 0) chat_message = value;
        } else if (std.mem.startsWith(u8, arg, "--context-artifact=")) {
            const value = arg["--context-artifact=".len..];
            if (value.len > 0) try context_artifacts.append(value);
        } else if (std.mem.startsWith(u8, arg, "--evidence-url=")) {
            const value = arg["--evidence-url=".len..];
            if (value.len > 0) try evidence_urls.append(value);
        } else if (std.mem.startsWith(u8, arg, "--evidence-query=")) {
            const value = arg["--evidence-query=".len..];
            if (value.len > 0) try evidence_queries.append(.{ .text = value });
        } else if (std.mem.startsWith(u8, arg, "--max-steps=")) {
            max_steps = std.fmt.parseUnsigned(u32, arg["--max-steps=".len..], 10) catch max_steps;
        } else if (std.mem.startsWith(u8, arg, "--max-items=")) {
            max_items = std.fmt.parseUnsigned(usize, arg["--max-items=".len..], 10) catch max_items;
        } else if (std.mem.startsWith(u8, arg, "--max-candidates=")) {
            patch_caps.max_candidates = std.fmt.parseUnsigned(usize, arg["--max-candidates=".len..], 10) catch patch_caps.max_candidates;
        } else if (std.mem.startsWith(u8, arg, "--max-files=")) {
            patch_caps.max_files = std.fmt.parseUnsigned(usize, arg["--max-files=".len..], 10) catch patch_caps.max_files;
        } else if (std.mem.startsWith(u8, arg, "--max-hunks=")) {
            patch_caps.max_hunks_per_candidate = std.fmt.parseUnsigned(usize, arg["--max-hunks=".len..], 10) catch patch_caps.max_hunks_per_candidate;
        } else if (std.mem.startsWith(u8, arg, "--max-lines=")) {
            patch_caps.max_lines_per_hunk = std.fmt.parseUnsigned(u32, arg["--max-lines=".len..], 10) catch patch_caps.max_lines_per_hunk;
        } else if (std.mem.startsWith(u8, arg, "--compute-tier=")) {
            compute_tier_explicit = true;
            compute_request.tier = parseComputeTier(arg["--compute-tier=".len..]) orelse {
                printUsage();
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, arg, "--reasoning=")) {
            requested_reasoning = response_engine.parseReasoningLevel(arg["--reasoning=".len..]) orelse {
                sys.print("invalid --reasoning value; expected quick, balanced, deep, or max\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--advanced")) {
            advanced = true;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-branches=")) {
            compute_request.overrides.max_branches = std.fmt.parseUnsigned(u32, arg["--budget-max-branches=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-proof-queue=")) {
            compute_request.overrides.max_proof_queue_size = std.fmt.parseUnsigned(usize, arg["--budget-max-proof-queue=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-repairs=")) {
            compute_request.overrides.max_repairs = std.fmt.parseUnsigned(u32, arg["--budget-max-repairs=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-mounted-packs=")) {
            compute_request.overrides.max_mounted_packs_considered = std.fmt.parseUnsigned(usize, arg["--budget-max-mounted-packs=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-activated-packs=")) {
            compute_request.overrides.max_packs_activated = std.fmt.parseUnsigned(usize, arg["--budget-max-activated-packs=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-pack-surfaces=")) {
            compute_request.overrides.max_pack_candidate_surfaces = std.fmt.parseUnsigned(usize, arg["--budget-max-pack-surfaces=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-graph-nodes=")) {
            compute_request.overrides.max_graph_nodes = std.fmt.parseUnsigned(u32, arg["--budget-max-graph-nodes=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-obligations=")) {
            compute_request.overrides.max_graph_obligations = std.fmt.parseUnsigned(u32, arg["--budget-max-obligations=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-ambiguity-sets=")) {
            compute_request.overrides.max_ambiguity_sets = std.fmt.parseUnsigned(u32, arg["--budget-max-ambiguity-sets=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-runtime-checks=")) {
            compute_request.overrides.max_runtime_checks = std.fmt.parseUnsigned(usize, arg["--budget-max-runtime-checks=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-wall-ms=")) {
            compute_request.overrides.max_wall_time_ms = std.fmt.parseUnsigned(u32, arg["--budget-max-wall-ms=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--budget-max-temp-bytes=")) {
            compute_request.overrides.max_temp_work_bytes = std.fmt.parseUnsigned(usize, arg["--budget-max-temp-bytes=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--reopen")) {
            reopen = true;
        } else if (std.mem.eql(u8, arg, "--no-panic-dump")) {
            emit_panic_dump = false;
        } else if (std.mem.eql(u8, arg, "--no-external")) {
            allow_external_replay = false;
        } else if (std.mem.startsWith(u8, arg, "--render=")) {
            const value = arg["--render=".len..];
            render_mode = operator_workflow.parseRenderMode(value) orelse {
                printUsage();
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            try positionals.append(arg);
        }
    }

    const reasoning_level = requested_reasoning orelse .balanced;
    if (requested_reasoning != null and compute_tier_explicit and !advanced) {
        sys.print("--reasoning and --compute-tier cannot be combined unless --advanced is set\n", .{});
        return error.InvalidArguments;
    }
    if (requested_reasoning != null and !compute_tier_explicit) {
        compute_request.tier = response_engine.computeTierForReasoningLevel(reasoning_level);
    }

    const evidence_request = if (evidence_urls.items.len > 0 or evidence_queries.items.len > 0)
        external_evidence.RequestInput{
            .urls = evidence_urls.items,
            .queries = evidence_queries.items,
        }
    else
        null;

    switch (command) {
        .project => {
            var mount = try operator_workflow.useProject(allocator, repo_root, project_shard);
            defer mount.deinit();
            const rendered = try operator_workflow.renderProject(allocator, &mount, render_mode);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .start => {
            const intent = intent_text orelse {
                printUsage();
                return error.InvalidArguments;
            };
            var session = try core.task_sessions.create(allocator, .{
                .repo_root = repo_root,
                .project_shard = project_shard,
                .intent_text = intent,
                .task_id = task_id,
                .evidence_request = evidence_request,
                .compute_budget_request = compute_request,
            });
            defer session.deinit();
            const rendered = try operator_workflow.renderTaskState(allocator, &session, render_mode);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .run => {
            const intent = intent_text orelse {
                printUsage();
                return error.InvalidArguments;
            };
            var session = try operator_workflow.runTask(allocator, .{
                .repo_root = repo_root,
                .project_shard = project_shard,
                .intent_text = intent,
                .task_id = task_id,
                .evidence_request = evidence_request,
                .compute_budget_request = compute_request,
                .max_steps = max_steps,
                .reopen = reopen,
                .emit_panic_dump = emit_panic_dump,
            });
            defer session.deinit();
            const rendered = try operator_workflow.renderTaskState(allocator, &session, render_mode);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .resume_task => {
            const resolved_task_id = task_id orelse if (positionals.items.len > 0) positionals.items[0] else null orelse {
                printUsage();
                return error.InvalidArguments;
            };
            var session = try operator_workflow.resumeTask(allocator, .{
                .project_shard = project_shard,
                .task_id = resolved_task_id,
                .evidence_request = evidence_request,
                .compute_budget_request = compute_request,
                .max_steps = max_steps,
                .reopen = reopen,
                .emit_panic_dump = emit_panic_dump,
            });
            defer session.deinit();
            const rendered = try operator_workflow.renderTaskState(allocator, &session, render_mode);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .show => {
            const resolved_task_id = task_id orelse if (positionals.items.len > 0) positionals.items[0] else null orelse {
                printUsage();
                return error.InvalidArguments;
            };
            var session = try operator_workflow.loadTask(allocator, project_shard, resolved_task_id);
            defer session.deinit();
            const rendered = try operator_workflow.renderTaskState(allocator, &session, render_mode);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .support => {
            const resolved_task_id = task_id orelse if (positionals.items.len > 0) positionals.items[0] else null orelse {
                printUsage();
                return error.InvalidArguments;
            };
            var session = try operator_workflow.loadTask(allocator, project_shard, resolved_task_id);
            defer session.deinit();
            const rendered = try operator_workflow.renderTaskSupport(allocator, &session, render_mode);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .inspect => {
            parseQueryPositionals(&query_kind, &target, &other_target, positionals.items, 2) catch {
                printUsage();
                return error.InvalidArguments;
            };
            var view = try operator_workflow.inspect(allocator, .{
                .repo_root = repo_root,
                .project_shard = project_shard,
                .intent_text = intent_text,
                .query_kind = query_kind,
                .target = target,
                .other_target = other_target,
                .max_items = max_items,
                .compute_budget_request = compute_request,
            });
            defer view.deinit();
            const rendered = try operator_workflow.renderCodeIntelView(allocator, &view, render_mode);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .plan, .verify, .oracle => {
            parseQueryPositionals(&query_kind, &target, &other_target, positionals.items, 2) catch {
                printUsage();
                return error.InvalidArguments;
            };
            const mode: operator_workflow.PatchWorkflowMode = switch (command) {
                .plan => .plan,
                .verify => .verify,
                .oracle => .oracle,
                else => unreachable,
            };
            var view = try operator_workflow.runPatchWorkflow(allocator, mode, .{
                .repo_root = repo_root,
                .project_shard = project_shard,
                .intent_text = intent_text,
                .request_label = request_label,
                .query_kind = query_kind,
                .target = target,
                .other_target = other_target,
                .caps = patch_caps,
                .compute_budget_request = compute_request,
            });
            defer view.deinit();
            const rendered = try operator_workflow.renderPatchWorkflowView(allocator, &view, render_mode);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .chat => {
            const message = chat_message orelse intent_text orelse if (positionals.items.len > 0) positionals.items[0] else null orelse {
                printUsage();
                return error.InvalidArguments;
            };
            var result = try conversation_session.turn(allocator, .{
                .repo_root = repo_root,
                .project_shard = project_shard,
                .session_id = task_id,
                .message = message,
                .context_artifacts = context_artifacts.items,
                .compute_budget_request = compute_request,
                .reasoning_level = reasoning_level,
            });
            defer result.deinit();
            const rendered = switch (render_mode) {
                .json => try conversation_session.renderJson(allocator, &result.session),
                .summary, .report => try allocator.dupe(u8, result.reply),
            };
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .replay => {
            if (task_id != null or (positionals.items.len == 1 and !looksLikePath(positionals.items[0]))) {
                const resolved_task_id = task_id orelse positionals.items[0];
                var view = try operator_workflow.replayTask(allocator, project_shard, resolved_task_id, allow_external_replay);
                defer view.deinit();
                const rendered = try operator_workflow.renderReplayView(allocator, &view, render_mode);
                defer allocator.free(rendered);
                sys.printOut(rendered);
                sys.printOut("\n");
            } else {
                const dump_path = if (positionals.items.len > 0) positionals.items[0] else null orelse {
                    printUsage();
                    return error.InvalidArguments;
                };
                var view = try operator_workflow.replayDumpPath(allocator, dump_path, allow_external_replay);
                defer view.deinit();
                const rendered = try operator_workflow.renderReplayView(allocator, &view, render_mode);
                defer allocator.free(rendered);
                sys.printOut(rendered);
                sys.printOut("\n");
            }
        },
    }
}

fn parseCommand(text: []const u8) ?Command {
    if (std.mem.eql(u8, text, "project")) return .project;
    if (std.mem.eql(u8, text, "start")) return .start;
    if (std.mem.eql(u8, text, "run")) return .run;
    if (std.mem.eql(u8, text, "resume")) return .resume_task;
    if (std.mem.eql(u8, text, "show")) return .show;
    if (std.mem.eql(u8, text, "status")) return .show;
    if (std.mem.eql(u8, text, "support")) return .support;
    if (std.mem.eql(u8, text, "inspect")) return .inspect;
    if (std.mem.eql(u8, text, "plan")) return .plan;
    if (std.mem.eql(u8, text, "verify")) return .verify;
    if (std.mem.eql(u8, text, "oracle")) return .oracle;
    if (std.mem.eql(u8, text, "chat")) return .chat;
    if (std.mem.eql(u8, text, "conversation")) return .chat;
    if (std.mem.eql(u8, text, "replay")) return .replay;
    return null;
}

fn parseQueryPositionals(
    query_kind: *?core.code_intel.QueryKind,
    target: *?[]const u8,
    other_target: *?[]const u8,
    positionals: []const []const u8,
    minimum: usize,
) !void {
    if (positionals.len == 0) return;
    if (positionals.len < minimum) return error.InvalidArguments;
    query_kind.* = operator_workflow.parseQueryKind(positionals[0]) orelse return error.InvalidArguments;
    target.* = positionals[1];
    other_target.* = if (positionals.len > 2) positionals[2] else null;
}

fn parseComputeTier(text: []const u8) ?compute_budget.Tier {
    inline for ([_]compute_budget.Tier{ .auto, .low, .medium, .high, .max }) |tier| {
        if (std.mem.eql(u8, text, @tagName(tier))) return tier;
    }
    return null;
}

fn looksLikePath(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, '/') != null or std.mem.endsWith(u8, value, ".bin");
}

fn printUsage() void {
    sys.print(
        "Usage: ghost_task_operator <project|start|run|resume|show|support|inspect|plan|verify|oracle|chat|replay> [args] [--intent=text] [--message=text] [--reasoning=quick|balanced|deep|max] [--context-artifact=id] [--repo=/abs/path] [--project-shard=id] [--task-id=id] [--request=text] [--evidence-url=url] [--evidence-query=text] [--max-steps=N] [--max-items=N] [--max-candidates=N] [--max-files=N] [--max-hunks=N] [--max-lines=N] [--reopen] [--no-panic-dump] [--no-external] [--render=summary|concise|json|report]\n\nExamples:\n  ghost_task_operator chat --message=\"explain this\" --reasoning=quick\n  ghost_task_operator chat --message=\"fix this bug\" --reasoning=deep\n  ghost_task_operator chat --message=\"verify and apply this\" --reasoning=max\n\nAdvanced/debug: --advanced allows explicit --compute-tier=auto|low|medium|high|max and --budget-max-* overrides. If --reasoning and --compute-tier are both provided, --compute-tier wins only with --advanced.\n",
        .{},
    );
}
