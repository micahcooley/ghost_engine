const std = @import("std");
const core = @import("ghost_core");
const patch_candidates = core.patch_candidates;
const sys = core.sys;
const task_intent = core.task_intent;
const technical_drafts = core.technical_drafts;

const OutputFormat = enum {
    json,
    draft,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        printUsage();
        return error.InvalidArguments;
    }

    const default_repo_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(default_repo_root);

    var repo_root: []const u8 = default_repo_root;
    var project_shard: ?[]const u8 = null;
    var request_label: ?[]const u8 = null;
    var intent_text: ?[]const u8 = null;
    var caps = patch_candidates.Caps{};
    var output_format: OutputFormat = .json;
    var draft_type: technical_drafts.DraftType = .proof_backed_explanation;
    var positionals = std.ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--repo=")) {
            repo_root = arg["--repo=".len..];
        } else if (std.mem.startsWith(u8, arg, "--project-shard=")) {
            const value = arg["--project-shard=".len..];
            if (value.len > 0) project_shard = value;
        } else if (std.mem.startsWith(u8, arg, "--request=")) {
            const value = arg["--request=".len..];
            if (value.len > 0) request_label = value;
        } else if (std.mem.startsWith(u8, arg, "--intent=")) {
            const value = arg["--intent=".len..];
            if (value.len > 0) intent_text = value;
        } else if (std.mem.startsWith(u8, arg, "--max-candidates=")) {
            caps.max_candidates = std.fmt.parseUnsigned(usize, arg["--max-candidates=".len..], 10) catch caps.max_candidates;
        } else if (std.mem.startsWith(u8, arg, "--max-files=")) {
            caps.max_files = std.fmt.parseUnsigned(usize, arg["--max-files=".len..], 10) catch caps.max_files;
        } else if (std.mem.startsWith(u8, arg, "--max-hunks=")) {
            caps.max_hunks_per_candidate = std.fmt.parseUnsigned(usize, arg["--max-hunks=".len..], 10) catch caps.max_hunks_per_candidate;
        } else if (std.mem.startsWith(u8, arg, "--max-lines=")) {
            caps.max_lines_per_hunk = std.fmt.parseUnsigned(u32, arg["--max-lines=".len..], 10) catch caps.max_lines_per_hunk;
        } else if (std.mem.startsWith(u8, arg, "--render=")) {
            const value = arg["--render=".len..];
            if (std.mem.eql(u8, value, "json")) {
                output_format = .json;
            } else if (std.mem.eql(u8, value, "draft")) {
                output_format = .draft;
            } else {
                printUsage();
                return error.InvalidArguments;
            }
        } else if (std.mem.startsWith(u8, arg, "--draft-type=")) {
            draft_type = technical_drafts.parseDraftType(arg["--draft-type=".len..]) orelse {
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

    var parsed_intent: ?task_intent.Task = null;
    defer if (parsed_intent) |*intent| intent.deinit();

    var query_kind: core.code_intel.QueryKind = .impact;
    var target: []const u8 = undefined;
    var other_target: ?[]const u8 = null;

    if (intent_text) |text| {
        parsed_intent = try task_intent.parse(allocator, text, .{});
        const intent = parsed_intent.?;
        if (intent.status != .grounded or intent.dispatch.flow != .patch_candidates or intent.dispatch.query_kind == null or intent.target.spec == null) {
            printUsage();
            return error.InvalidArguments;
        }
        query_kind = translateIntentQueryKind(intent.dispatch.query_kind.?);
        target = intent.target.spec.?;
        other_target = intent.other_target.spec;
        request_label = intent.raw_input;
        if (intent.requested_alternatives > 0 and intent.requested_alternatives > caps.max_candidates) {
            caps.max_candidates = intent.requested_alternatives;
        }
    } else {
        if (positionals.items.len < 2) {
            printUsage();
            return error.InvalidArguments;
        }
        query_kind = parseQueryKind(positionals.items[0]) orelse {
            printUsage();
            return error.InvalidArguments;
        };
        target = positionals.items[1];
        other_target = if (positionals.items.len > 2) positionals.items[2] else null;
    }

    var result = try patch_candidates.run(allocator, .{
        .repo_root = repo_root,
        .project_shard = project_shard,
        .query_kind = query_kind,
        .target = target,
        .other_target = other_target,
        .request_label = request_label,
        .intent = if (parsed_intent) |*intent| intent else null,
        .caps = caps,
        .persist_code_intel = true,
        .cache_persist = true,
        .stage_result = false,
    });
    defer result.deinit();

    const rendered = switch (output_format) {
        .json => try patch_candidates.renderJson(allocator, &result),
        .draft => try technical_drafts.render(allocator, .{ .patch_candidates = &result }, .{
            .draft_type = draft_type,
            .max_items = caps.max_support_items,
        }),
    };
    defer allocator.free(rendered);
    sys.printOut(rendered);
    sys.printOut("\n");
}

fn parseQueryKind(text: []const u8) ?core.code_intel.QueryKind {
    if (std.mem.eql(u8, text, "impact")) return .impact;
    if (std.mem.eql(u8, text, "breaks-if")) return .breaks_if;
    if (std.mem.eql(u8, text, "contradicts")) return .contradicts;
    return null;
}

fn translateIntentQueryKind(kind: task_intent.QueryKind) core.code_intel.QueryKind {
    return switch (kind) {
        .impact => .impact,
        .breaks_if => .breaks_if,
        .contradicts => .contradicts,
    };
}

fn printUsage() void {
    sys.print(
        "Usage: ghost_patch_candidates <impact|breaks-if|contradicts> <target> [other-target] [--intent=text] [--request=text] [--repo=/abs/path] [--project-shard=id] [--max-candidates=N] [--max-files=N] [--max-hunks=N] [--max-lines=N] [--render=json|draft] [--draft-type=proof-backed-explanation|refactor-plan|contradiction-report|code-change-summary|technical-design-alternatives]\n",
        .{},
    );
}
