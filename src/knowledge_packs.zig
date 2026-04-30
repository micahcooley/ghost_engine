const std = @import("std");
const abstractions = @import("abstractions.zig");
const autopsy_guidance_validator = @import("autopsy_guidance_validator.zig");
const config = @import("config.zig");
const corpus_ingest = @import("corpus_ingest.zig");
const feedback_distillation = @import("feedback_distillation.zig");
const shards = @import("shards.zig");
const store = @import("knowledge_pack_store.zig");
const sys = @import("sys.zig");
const TEMP_SHARD_PREFIX = "packbuild";

pub const Command = enum {
    create,
    inspect,
    list,
    mount,
    unmount,
    clone,
    remove,
    diff,
    @"export",
    import,
    verify,
    @"validate-autopsy-guidance",
    capabilities,
    @"list-versions",
    @"distill-list",
    @"distill-show",
    @"distill-export",
};

const CommandSpec = struct {
    command: Command,
    name: []const u8,
    aliases: []const []const u8 = &.{},
    summary: []const u8,
};

const command_registry = [_]CommandSpec{
    .{ .command = .create, .name = "create", .summary = "create a staged knowledge pack" },
    .{ .command = .inspect, .name = "inspect", .summary = "inspect a knowledge pack" },
    .{ .command = .list, .name = "list", .summary = "list installed knowledge packs" },
    .{ .command = .mount, .name = "mount", .summary = "mount a pack for a project" },
    .{ .command = .unmount, .name = "unmount", .summary = "unmount a pack for a project" },
    .{ .command = .clone, .name = "clone", .summary = "clone a knowledge pack" },
    .{ .command = .remove, .name = "remove", .summary = "remove a knowledge pack" },
    .{ .command = .diff, .name = "diff", .summary = "diff two pack versions" },
    .{ .command = .@"export", .name = "export", .summary = "export a pack artifact" },
    .{ .command = .import, .name = "import", .summary = "import a pack artifact" },
    .{ .command = .verify, .name = "verify", .summary = "verify an exported pack artifact" },
    .{ .command = .@"validate-autopsy-guidance", .name = "validate-autopsy-guidance", .summary = "validate persisted Context Autopsy guidance" },
    .{ .command = .capabilities, .name = "capabilities", .summary = "print machine-readable binary capabilities" },
    .{ .command = .@"list-versions", .name = "list-versions", .summary = "list versions for a pack" },
    .{ .command = .@"distill-list", .name = "distill-list", .summary = "list feedback distillation candidates" },
    .{ .command = .@"distill-show", .name = "distill-show", .summary = "show a feedback distillation candidate" },
    .{ .command = .@"distill-export", .name = "distill-export", .summary = "export an approved distillation candidate into a pack" },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        printUsage();
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        printUsage();
        return;
    }

    const command = parseCommand(args[1]) orelse {
        std.debug.print("unknown command: {s}\nUse --help to list supported ghost_knowledge_pack commands.\n", .{args[1]});
        printUsage();
        std.process.exit(2);
    };

    var pack_id: ?[]const u8 = null;
    var pack_version: ?[]const u8 = null;
    var domain_family: []const u8 = "general";
    var trust_class: []const u8 = "project";
    var source_summary: ?[]const u8 = null;
    var project_shard: ?[]const u8 = null;
    var source_project_shard: ?[]const u8 = null;
    var source_state: store.SourceState = .staged;
    var corpus_path: ?[]const u8 = null;
    var corpus_label: ?[]const u8 = null;
    var left_pack: ?[]const u8 = null;
    var left_version: ?[]const u8 = null;
    var right_pack: ?[]const u8 = null;
    var right_version: ?[]const u8 = null;
    var clone_pack_id: ?[]const u8 = null;
    var clone_pack_version: ?[]const u8 = null;
    var export_dir: ?[]const u8 = null;
    var force = false;
    var export_reason: []const u8 = "manual";
    var as_json = false;
    var candidate_id: ?[]const u8 = null;
    var approve = false;
    var manifest_path: ?[]const u8 = null;
    var all_mounted = false;
    var validation_limits = autopsy_guidance_validator.AutopsyGuidanceValidationLimits.default();

    for (args[2..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--pack-id=")) {
            pack_id = arg["--pack-id=".len..];
        } else if (std.mem.startsWith(u8, arg, "--version=")) {
            pack_version = arg["--version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--domain=")) {
            domain_family = arg["--domain=".len..];
        } else if (std.mem.startsWith(u8, arg, "--trust-class=")) {
            trust_class = arg["--trust-class=".len..];
        } else if (std.mem.startsWith(u8, arg, "--source-summary=")) {
            source_summary = arg["--source-summary=".len..];
        } else if (std.mem.startsWith(u8, arg, "--project-shard=")) {
            project_shard = arg["--project-shard=".len..];
        } else if (std.mem.startsWith(u8, arg, "--source-project-shard=")) {
            source_project_shard = arg["--source-project-shard=".len..];
        } else if (std.mem.startsWith(u8, arg, "--source-state=")) {
            source_state = store.parseSourceState(arg["--source-state=".len..]) orelse return error.InvalidArguments;
        } else if (std.mem.startsWith(u8, arg, "--corpus=")) {
            corpus_path = arg["--corpus=".len..];
        } else if (std.mem.startsWith(u8, arg, "--corpus-label=")) {
            corpus_label = arg["--corpus-label=".len..];
        } else if (std.mem.startsWith(u8, arg, "--left-pack=")) {
            left_pack = arg["--left-pack=".len..];
        } else if (std.mem.startsWith(u8, arg, "--left-version=")) {
            left_version = arg["--left-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--right-pack=")) {
            right_pack = arg["--right-pack=".len..];
        } else if (std.mem.startsWith(u8, arg, "--right-version=")) {
            right_version = arg["--right-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--to-pack-id=")) {
            clone_pack_id = arg["--to-pack-id=".len..];
        } else if (std.mem.startsWith(u8, arg, "--to-version=")) {
            clone_pack_version = arg["--to-version=".len..];
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if (std.mem.startsWith(u8, arg, "--manifest=")) {
            manifest_path = arg["--manifest=".len..];
        } else if (std.mem.eql(u8, arg, "--all-mounted")) {
            all_mounted = true;
        } else if (std.mem.startsWith(u8, arg, "--max-guidance-bytes=")) {
            validation_limits.max_guidance_bytes = parseLimitArg(arg, "--max-guidance-bytes=") catch |err| {
                printLimitErrorAndExit(err, "--max-guidance-bytes", validation_limits.max_guidance_bytes);
            };
        } else if (std.mem.startsWith(u8, arg, "--max-array-items=")) {
            validation_limits.max_array_items = parseLimitArg(arg, "--max-array-items=") catch |err| {
                printLimitErrorAndExit(err, "--max-array-items", validation_limits.max_array_items);
            };
        } else if (std.mem.startsWith(u8, arg, "--max-string-bytes=")) {
            validation_limits.max_string_bytes = parseLimitArg(arg, "--max-string-bytes=") catch |err| {
                printLimitErrorAndExit(err, "--max-string-bytes", validation_limits.max_string_bytes);
            };
        } else if (std.mem.startsWith(u8, arg, "--candidate-id=")) {
            candidate_id = arg["--candidate-id=".len..];
        } else if (std.mem.eql(u8, arg, "--approve")) {
            approve = true;
        } else if (std.mem.startsWith(u8, arg, "--export-dir=")) {
            export_dir = arg["--export-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.startsWith(u8, arg, "--export-reason=")) {
            export_reason = arg["--export-reason=".len..];
        } else {
            std.debug.print("unknown flag: {s}\nUse --help to list supported ghost_knowledge_pack flags.\n", .{arg});
            printUsage();
            std.process.exit(2);
        }
    }
    validateLimitsOrExit(validation_limits);

    switch (command) {
        .create => {
            const id = pack_id orelse return error.InvalidArguments;
            const version = pack_version orelse return error.InvalidArguments;
            var result = try createPack(allocator, .{
                .pack_id = id,
                .pack_version = version,
                .domain_family = domain_family,
                .trust_class = trust_class,
                .source_summary = source_summary,
                .source_project_shard = source_project_shard,
                .source_state = source_state,
                .corpus_path = corpus_path,
                .corpus_label = corpus_label,
            });
            defer result.manifest.deinit();
            defer allocator.free(result.root_abs_path);
            const rendered = try renderInspect(allocator, &result.manifest, result.root_abs_path, project_shard, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .inspect => {
            const id = pack_id orelse return error.InvalidArguments;
            const version = pack_version orelse return error.InvalidArguments;
            const root = try store.packRootAbsPath(allocator, id, version);
            defer allocator.free(root);
            var manifest = try store.loadManifest(allocator, id, version);
            defer manifest.deinit();
            const rendered = try renderInspect(allocator, &manifest, root, project_shard, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .list => {
            const rendered = try renderList(allocator, project_shard, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .mount => {
            const id = pack_id orelse return error.InvalidArguments;
            const version = pack_version orelse return error.InvalidArguments;
            try setMountedState(allocator, project_shard, id, version, true, true);
            sys.print("mounted {s}@{s}\n", .{ id, version });
        },
        .unmount => {
            const id = pack_id orelse return error.InvalidArguments;
            const version = pack_version orelse return error.InvalidArguments;
            try setMountedState(allocator, project_shard, id, version, false, false);
            sys.print("unmounted {s}@{s}\n", .{ id, version });
        },
        .clone => {
            const id = pack_id orelse return error.InvalidArguments;
            const version = pack_version orelse return error.InvalidArguments;
            const next_id = clone_pack_id orelse return error.InvalidArguments;
            const next_version = clone_pack_version orelse return error.InvalidArguments;
            var result = try clonePack(allocator, id, version, next_id, next_version, source_summary);
            defer result.manifest.deinit();
            defer allocator.free(result.root_abs_path);
            const rendered = try renderInspect(allocator, &result.manifest, result.root_abs_path, project_shard, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .remove => {
            const id = pack_id orelse return error.InvalidArguments;
            const version = pack_version orelse return error.InvalidArguments;
            try removePack(allocator, id, version);
            sys.print("removed {s}@{s}\n", .{ id, version });
        },
        .diff => {
            const rendered = try renderDiff(allocator, left_pack orelse return error.InvalidArguments, left_version orelse return error.InvalidArguments, right_pack orelse return error.InvalidArguments, right_version orelse return error.InvalidArguments, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .@"export" => {
            const id = pack_id orelse return error.InvalidArguments;
            const version = pack_version orelse return error.InvalidArguments;
            const dir = export_dir orelse return error.InvalidArguments;
            var result = try exportPack(allocator, .{
                .pack_id = id,
                .pack_version = version,
                .export_dir = dir,
                .export_reason = export_reason,
            });
            defer result.envelope.deinit();
            defer allocator.free(result.export_root_abs_path);
            const rendered = try renderExportSummary(allocator, &result.envelope, result.export_root_abs_path);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .import => {
            const dir = export_dir orelse return error.InvalidArguments;
            var result = try importPack(allocator, .{
                .source_dir = dir,
                .force = force,
            });
            defer result.manifest.deinit();
            defer allocator.free(result.root_abs_path);
            const rendered = try renderImportResult(allocator, &result);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .verify => {
            const dir = export_dir orelse return error.InvalidArguments;
            var result = try verifyExportArtifact(allocator, dir);
            defer {
                for (result.errors) |item| allocator.free(item);
                allocator.free(result.errors);
            }
            const rendered = try renderVerifyResult(allocator, &result);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
            if (!result.integrity_ok or !result.compatibility_ok) {
                return error.VerifyFailed;
            }
        },
        .@"validate-autopsy-guidance" => {
            var summary = try validateAutopsyGuidanceForCli(allocator, .{
                .pack_id = pack_id,
                .pack_version = pack_version,
                .manifest_path = manifest_path,
                .all_mounted = all_mounted,
                .project_shard = project_shard,
                .limits = validation_limits,
            });
            defer summary.deinit();
            const rendered = try renderAutopsyGuidanceValidation(allocator, &summary, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
            if (!summary.ok()) std.process.exit(1);
        },
        .capabilities => {
            const rendered = try renderCapabilities(allocator, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .@"list-versions" => {
            const id = pack_id orelse return error.InvalidArguments;
            const versions = try listPackVersions(allocator, id);
            defer {
                for (versions) |*v| {
                    allocator.free(v.pack_id);
                    allocator.free(v.version);
                    allocator.free(v.domain);
                    allocator.free(v.trust_class);
                }
                allocator.free(versions);
            }
            const rendered = try renderVersionList(allocator, versions, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .@"distill-list" => {
            const rendered = try renderDistillationList(allocator, project_shard, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .@"distill-show" => {
            const id = candidate_id orelse return error.InvalidArguments;
            const rendered = try renderDistillationShow(allocator, project_shard, id, as_json);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
        .@"distill-export" => {
            if (!approve) return error.DistillationExportRequiresApproval;
            const id = candidate_id orelse return error.InvalidArguments;
            const pack = pack_id orelse return error.InvalidArguments;
            const version = pack_version orelse return error.InvalidArguments;
            var result = try exportDistillationCandidate(allocator, .{
                .project_shard = project_shard,
                .candidate_id = id,
                .pack_id = pack,
                .pack_version = version,
                .domain_family = domain_family,
                .trust_class = trust_class,
                .source_summary = source_summary,
            });
            defer result.manifest.deinit();
            defer allocator.free(result.root_abs_path);
            const rendered = try renderDistillationExportResult(allocator, &result, id);
            defer allocator.free(rendered);
            sys.printOut(rendered);
            sys.printOut("\n");
        },
    }
}

pub const CreateOptions = struct {
    pack_id: []const u8,
    pack_version: []const u8,
    domain_family: []const u8,
    trust_class: []const u8,
    freshness_state: []const u8 = "active",
    source_summary: ?[]const u8,
    source_project_shard: ?[]const u8,
    source_state: store.SourceState,
    corpus_path: ?[]const u8,
    corpus_label: ?[]const u8,
};

pub const CreateResult = struct {
    manifest: store.Manifest,
    root_abs_path: []u8,
};

pub fn createPack(allocator: std.mem.Allocator, options: CreateOptions) !CreateResult {
    const pack_id = try store.sanitizePackId(allocator, options.pack_id);
    defer allocator.free(pack_id);
    const pack_version = try store.sanitizeVersion(allocator, options.pack_version);
    defer allocator.free(pack_version);

    const root_abs_path = try store.packRootAbsPath(allocator, pack_id, pack_version);
    errdefer allocator.free(root_abs_path);
    if (pathExists(root_abs_path)) return error.PathAlreadyExists;
    try sys.makePath(allocator, root_abs_path);

    var source = try prepareSource(allocator, options, pack_id, pack_version);
    defer source.deinit();

    const corpus_dst = try std.fs.path.join(allocator, &.{ root_abs_path, "corpus" });
    defer allocator.free(corpus_dst);
    const abstractions_dst = try std.fs.path.join(allocator, &.{ root_abs_path, "abstractions" });
    defer allocator.free(abstractions_dst);
    try sys.makePath(allocator, corpus_dst);
    try sys.makePath(allocator, abstractions_dst);

    try copyTreeAbsolute(source.corpus_abs_path, corpus_dst);
    try abstractions.exportCatalogBundle(allocator, &source.paths, source.export_state, abstractions_dst);
    try writeInfluenceManifest(allocator, root_abs_path, pack_id, pack_version);

    var content = try summarizePackContent(allocator, root_abs_path, pack_id, pack_version);
    errdefer content.deinit(allocator);

    var manifest = store.Manifest{
        .allocator = allocator,
        .schema_version = try allocator.dupe(u8, store.PACK_SCHEMA_VERSION),
        .pack_id = try allocator.dupe(u8, pack_id),
        .pack_version = try allocator.dupe(u8, pack_version),
        .domain_family = try allocator.dupe(u8, options.domain_family),
        .trust_class = try allocator.dupe(u8, options.trust_class),
        .compatibility = .{
            .engine_version = try allocator.dupe(u8, @import("ghost.zig").VERSION),
            .linux_first = true,
            .deterministic_only = true,
            .mount_schema = try allocator.dupe(u8, store.MOUNT_SCHEMA_VERSION),
        },
        .storage = .{
            .corpus_manifest_rel_path = try allocator.dupe(u8, "corpus/manifest.json"),
            .corpus_files_rel_path = try allocator.dupe(u8, "corpus"),
            .abstraction_catalog_rel_path = try allocator.dupe(u8, "abstractions/abstractions.gabs"),
            .reuse_catalog_rel_path = try allocator.dupe(u8, "abstractions/reuse.gabr"),
            .lineage_state_rel_path = try allocator.dupe(u8, "abstractions/lineage.gabs"),
            .influence_manifest_rel_path = try allocator.dupe(u8, "influence.json"),
            .autopsy_guidance_rel_path = null,
        },
        .provenance = .{
            .pack_lineage_id = try std.fmt.allocPrint(allocator, "pack:{s}@{s}", .{ pack_id, pack_version }),
            .source_kind = try allocator.dupe(u8, source.source_kind),
            .source_id = try allocator.dupe(u8, source.source_id),
            .source_state = source.source_state,
            .freshness_state = store.parsePackFreshness(options.freshness_state) orelse return error.InvalidArguments,
            .source_summary = try allocator.dupe(u8, source.source_summary),
            .source_lineage_summary = try allocator.dupe(u8, source.source_lineage_summary),
        },
        .content = content,
    };
    errdefer manifest.deinit();
    try store.saveManifest(allocator, root_abs_path, &manifest);

    return .{
        .manifest = manifest,
        .root_abs_path = root_abs_path,
    };
}

const PreparedSource = struct {
    allocator: std.mem.Allocator,
    paths: shards.Paths,
    corpus_abs_path: []u8,
    export_state: abstractions.ExportState,
    source_state: store.SourceState,
    source_kind: []u8,
    source_id: []u8,
    source_summary: []u8,
    source_lineage_summary: []u8,
    cleanup_root: ?[]u8 = null,

    fn deinit(self: *PreparedSource) void {
        if (self.cleanup_root) |root| {
            deleteTreeIfExistsAbsolute(root) catch {};
            self.allocator.free(root);
        }
        self.paths.deinit();
        self.allocator.free(self.corpus_abs_path);
        self.allocator.free(self.source_kind);
        self.allocator.free(self.source_id);
        self.allocator.free(self.source_summary);
        self.allocator.free(self.source_lineage_summary);
        self.* = undefined;
    }
};

fn prepareSource(allocator: std.mem.Allocator, options: CreateOptions, pack_id: []const u8, pack_version: []const u8) !PreparedSource {
    if (options.corpus_path) |corpus_path| {
        const temp_shard = try claimTemporaryBuildShard(allocator, pack_id, pack_version);
        defer allocator.free(temp_shard);
        var staged = try corpus_ingest.stage(allocator, .{
            .corpus_path = corpus_path,
            .project_shard = temp_shard,
            .trust_class = parseTrustClass(options.trust_class) orelse return error.InvalidArguments,
            .source_label = options.corpus_label,
        });
        defer staged.deinit();
        var metadata = try shards.resolveProjectMetadata(allocator, temp_shard);
        defer metadata.deinit();
        const paths = try shards.resolvePaths(allocator, metadata.metadata);
        try corpus_ingest.applyStaged(allocator, &paths);

        const corpus_abs = try allocator.dupe(u8, paths.corpus_ingest_live_abs_path);
        errdefer allocator.free(corpus_abs);
        const summary = if (options.source_summary) |value|
            try allocator.dupe(u8, value)
        else
            try std.fmt.allocPrint(allocator, "corpus_slice:{s}", .{corpus_path});
        errdefer allocator.free(summary);
        const lineage = try summarizeSourceLineage(allocator, paths.corpus_ingest_live_manifest_abs_path, paths.abstractions_live_abs_path);
        errdefer allocator.free(lineage);
        return .{
            .allocator = allocator,
            .paths = paths,
            .corpus_abs_path = corpus_abs,
            .export_state = .live,
            .source_state = .staged,
            .source_kind = try allocator.dupe(u8, "corpus_slice"),
            .source_id = try allocator.dupe(u8, corpus_path),
            .source_summary = summary,
            .source_lineage_summary = lineage,
            .cleanup_root = try allocator.dupe(u8, paths.root_abs_path),
        };
    }

    var metadata = try shards.resolveProjectMetadata(allocator, options.source_project_shard orelse return error.InvalidArguments);
    defer metadata.deinit();
    const paths = try shards.resolvePaths(allocator, metadata.metadata);
    const export_state: abstractions.ExportState = switch (options.source_state) {
        .staged => .staged,
        .live => .live,
    };
    const corpus_abs = try allocator.dupe(u8, switch (options.source_state) {
        .staged => paths.corpus_ingest_staged_abs_path,
        .live => paths.corpus_ingest_live_abs_path,
    });
    errdefer allocator.free(corpus_abs);
    const summary = if (options.source_summary) |value|
        try allocator.dupe(u8, value)
    else
        try std.fmt.allocPrint(allocator, "shard:{s}", .{metadata.metadata.id});
    errdefer allocator.free(summary);
    const lineage = try summarizeSourceLineage(
        allocator,
        switch (options.source_state) {
            .staged => paths.corpus_ingest_staged_manifest_abs_path,
            .live => paths.corpus_ingest_live_manifest_abs_path,
        },
        switch (options.source_state) {
            .staged => paths.abstractions_staged_abs_path,
            .live => paths.abstractions_live_abs_path,
        },
    );
    errdefer allocator.free(lineage);
    return .{
        .allocator = allocator,
        .paths = paths,
        .corpus_abs_path = corpus_abs,
        .export_state = export_state,
        .source_state = options.source_state,
        .source_kind = try allocator.dupe(u8, "project_shard"),
        .source_id = try allocator.dupe(u8, metadata.metadata.id),
        .source_summary = summary,
        .source_lineage_summary = lineage,
    };
}

pub fn clonePack(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8, next_pack_id: []const u8, next_pack_version: []const u8, source_summary_override: ?[]const u8) !CreateResult {
    const src_root = try store.packRootAbsPath(allocator, pack_id, pack_version);
    defer allocator.free(src_root);
    const dst_id = try store.sanitizePackId(allocator, next_pack_id);
    defer allocator.free(dst_id);
    const dst_version = try store.sanitizeVersion(allocator, next_pack_version);
    defer allocator.free(dst_version);
    const dst_root = try store.packRootAbsPath(allocator, dst_id, dst_version);
    errdefer allocator.free(dst_root);
    if (pathExists(dst_root)) return error.PathAlreadyExists;
    try copyTreeAbsolute(src_root, dst_root);

    var manifest = try store.loadManifest(allocator, pack_id, pack_version);
    errdefer manifest.deinit();
    manifest.allocator.free(manifest.pack_id);
    manifest.pack_id = try allocator.dupe(u8, dst_id);
    manifest.allocator.free(manifest.pack_version);
    manifest.pack_version = try allocator.dupe(u8, dst_version);
    manifest.allocator.free(manifest.provenance.pack_lineage_id);
    manifest.provenance.pack_lineage_id = try std.fmt.allocPrint(allocator, "pack:{s}@{s}", .{ dst_id, dst_version });
    if (source_summary_override) |value| {
        manifest.allocator.free(manifest.provenance.source_summary);
        manifest.provenance.source_summary = try allocator.dupe(u8, value);
    }
    const cloned_lineage = try std.fmt.allocPrint(
        allocator,
        "{s}|cloned_from={s}@{s}",
        .{ manifest.provenance.source_lineage_summary, pack_id, pack_version },
    );
    manifest.allocator.free(manifest.provenance.source_lineage_summary);
    manifest.provenance.source_lineage_summary = cloned_lineage;
    try store.saveManifest(allocator, dst_root, &manifest);
    return .{ .manifest = manifest, .root_abs_path = dst_root };
}

pub fn refreshPackManifestContent(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) !void {
    const root_abs_path = try store.packRootAbsPath(allocator, pack_id, pack_version);
    defer allocator.free(root_abs_path);

    var manifest = try store.loadManifest(allocator, pack_id, pack_version);
    defer manifest.deinit();

    const refreshed = try summarizePackContent(allocator, root_abs_path, manifest.pack_id, manifest.pack_version);
    manifest.content.deinit(allocator);
    manifest.content = refreshed;
    try store.saveManifest(allocator, root_abs_path, &manifest);
}

pub fn removePack(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) !void {
    const safe_pack_id = try store.sanitizePackId(allocator, pack_id);
    defer allocator.free(safe_pack_id);
    const safe_pack_version = try store.sanitizeVersion(allocator, pack_version);
    defer allocator.free(safe_pack_version);
    const root = try store.packRootAbsPath(allocator, safe_pack_id, safe_pack_version);
    defer allocator.free(root);
    try deleteTreeIfExistsAbsolute(root);
    try prunePackMountEntriesEverywhere(allocator, safe_pack_id, safe_pack_version);
}

pub fn setMountedState(allocator: std.mem.Allocator, project_shard: ?[]const u8, pack_id: []const u8, pack_version: []const u8, present: bool, enabled: bool) !void {
    var metadata = if (project_shard) |value|
        try shards.resolveProjectMetadata(allocator, value)
    else
        try shards.resolveDefaultProjectMetadata(allocator);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();

    var registry = try store.loadMountRegistry(allocator, &paths);
    defer registry.deinit();
    var index: ?usize = null;
    for (registry.entries, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.pack_id, pack_id) and std.mem.eql(u8, entry.pack_version, pack_version)) {
            index = idx;
            break;
        }
    }

    if (present) {
        var manifest = try store.loadManifest(allocator, pack_id, pack_version);
        defer manifest.deinit();
        if (index) |idx| {
            registry.entries[idx].enabled = enabled;
        } else {
            const next = try allocator.alloc(store.MountEntry, registry.entries.len + 1);
            errdefer allocator.free(next);
            for (registry.entries, 0..) |entry, idx| next[idx] = entry;
            next[registry.entries.len] = .{
                .allocator = allocator,
                .pack_id = try allocator.dupe(u8, pack_id),
                .pack_version = try allocator.dupe(u8, pack_version),
                .enabled = enabled,
            };
            allocator.free(registry.entries);
            registry.entries = next;
        }
    } else if (index) |idx| {
        var removed = registry.entries[idx];
        removed.deinit();
        var new_entries = try allocator.alloc(store.MountEntry, registry.entries.len - 1);
        var out_idx: usize = 0;
        for (registry.entries, 0..) |entry, idx2| {
            if (idx2 == idx) continue;
            new_entries[out_idx] = entry;
            out_idx += 1;
        }
        allocator.free(registry.entries);
        registry.entries = new_entries;
    }
    try store.saveMountRegistry(allocator, &paths, &registry);
}

fn renderInspect(allocator: std.mem.Allocator, manifest: *const store.Manifest, root_abs_path: []const u8, project_shard: ?[]const u8, as_json: bool) ![]u8 {
    const mount_state = try mountedStateFor(allocator, project_shard, manifest.pack_id, manifest.pack_version);
    defer if (mount_state.project_id) |value| allocator.free(value);

    if (as_json) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try std.json.stringify(.{
            .packId = manifest.pack_id,
            .version = manifest.pack_version,
            .domain = manifest.domain_family,
            .trustClass = manifest.trust_class,
            .root = root_abs_path,
            .sourceSummary = manifest.provenance.source_summary,
            .sourceKind = manifest.provenance.source_kind,
            .sourceId = manifest.provenance.source_id,
            .sourceState = store.sourceStateName(manifest.provenance.source_state),
            .freshnessState = store.packFreshnessName(manifest.provenance.freshness_state),
            .mounted = mount_state.mounted,
            .enabled = mount_state.enabled,
            .projectShard = mount_state.project_id,
            .compatibility = .{
                .engineVersion = manifest.compatibility.engine_version,
                .linuxFirst = manifest.compatibility.linux_first,
                .deterministicOnly = manifest.compatibility.deterministic_only,
            },
            .lineage = .{
                .packLineageId = manifest.provenance.pack_lineage_id,
                .sourceLineageSummary = manifest.provenance.source_lineage_summary,
            },
            .content = .{
                .corpusItemCount = manifest.content.corpus_item_count,
                .conceptCount = manifest.content.concept_count,
                .corpusHash = manifest.content.corpus_hash,
                .abstractionHash = manifest.content.abstraction_hash,
                .reuseHash = manifest.content.reuse_hash,
                .lineageHash = manifest.content.lineage_hash,
                .corpusPreview = manifest.content.corpus_preview,
                .conceptPreview = manifest.content.concept_preview,
            },
        }, .{ .whitespace = .indent_2 }, out.writer());
        return out.toOwnedSlice();
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.writer().print(
        "pack_id={s}\nversion={s}\ndomain={s}\ntrust_class={s}\nfreshness_state={s}\nroot={s}\nsource_summary={s}\nsource_kind={s}\nsource_id={s}\nsource_state={s}\nmounted={s}\nenabled={s}\ncorpus_items={d}\nconcepts={d}\ncorpus_hash={d}\nabstraction_hash={d}\nreuse_hash={d}\nlineage_hash={d}\ncorpus_preview={s}\nconcept_preview={s}",
        .{
            manifest.pack_id,
            manifest.pack_version,
            manifest.domain_family,
            manifest.trust_class,
            store.packFreshnessName(manifest.provenance.freshness_state),
            root_abs_path,
            manifest.provenance.source_summary,
            manifest.provenance.source_kind,
            manifest.provenance.source_id,
            store.sourceStateName(manifest.provenance.source_state),
            boolText(mount_state.mounted),
            boolText(mount_state.enabled),
            manifest.content.corpus_item_count,
            manifest.content.concept_count,
            manifest.content.corpus_hash,
            manifest.content.abstraction_hash,
            manifest.content.reuse_hash,
            manifest.content.lineage_hash,
            try joinPreview(allocator, manifest.content.corpus_preview),
            try joinPreview(allocator, manifest.content.concept_preview),
        },
    );
    return out.toOwnedSlice();
}

const MountedState = struct {
    mounted: bool = false,
    enabled: bool = false,
    project_id: ?[]u8 = null,
};

fn mountedStateFor(allocator: std.mem.Allocator, project_shard: ?[]const u8, pack_id: []const u8, pack_version: []const u8) !MountedState {
    if (project_shard == null) return .{};
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard.?);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    const mounts = try store.listResolvedMounts(allocator, &paths);
    defer {
        for (mounts) |*mount| mount.deinit();
        allocator.free(mounts);
    }
    var registry = try store.loadMountRegistry(allocator, &paths);
    defer registry.deinit();
    for (registry.entries) |entry| {
        if (!std.mem.eql(u8, entry.pack_id, pack_id) or !std.mem.eql(u8, entry.pack_version, pack_version)) continue;
        return .{
            .mounted = true,
            .enabled = entry.enabled,
            .project_id = try allocator.dupe(u8, paths.metadata.id),
        };
    }
    return .{ .project_id = try allocator.dupe(u8, paths.metadata.id) };
}

fn claimTemporaryBuildShard(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) ![]u8 {
    const projects_root = try config.getPath(allocator, config.PROJECT_SHARD_REL_DIR);
    defer allocator.free(projects_root);
    try sys.makePath(allocator, projects_root);

    var suffix: usize = 0;
    while (true) : (suffix += 1) {
        const shard_id = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{d}", .{ TEMP_SHARD_PREFIX, pack_id, pack_version, suffix });
        errdefer allocator.free(shard_id);
        var metadata = try shards.resolveProjectMetadata(allocator, shard_id);
        defer metadata.deinit();
        var paths = try shards.resolvePaths(allocator, metadata.metadata);
        defer paths.deinit();

        const parent = std.fs.path.dirname(paths.root_abs_path) orelse return error.InvalidArguments;
        try sys.makePath(allocator, parent);
        std.fs.makeDirAbsolute(paths.root_abs_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(shard_id);
                continue;
            },
            else => return err,
        };
        return shard_id;
    }
}

fn prunePackMountEntriesEverywhere(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) !void {
    const projects_root = try config.getPath(allocator, config.PROJECT_SHARD_REL_DIR);
    defer allocator.free(projects_root);

    var dir = std.fs.openDirAbsolute(projects_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        try prunePackMountEntriesForShard(allocator, entry.name, pack_id, pack_version);
    }
}

fn prunePackMountEntriesForShard(allocator: std.mem.Allocator, project_shard: []const u8, pack_id: []const u8, pack_version: []const u8) !void {
    var metadata = try shards.resolveProjectMetadata(allocator, project_shard);
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();

    var registry = try store.loadMountRegistry(allocator, &paths);
    defer registry.deinit();

    var kept = std.ArrayList(store.MountEntry).init(allocator);
    defer kept.deinit();
    var changed = false;
    for (registry.entries) |entry| {
        if (std.mem.eql(u8, entry.pack_id, pack_id) and std.mem.eql(u8, entry.pack_version, pack_version)) {
            var doomed = entry;
            doomed.deinit();
            changed = true;
            continue;
        }
        try kept.append(entry);
    }
    if (!changed) return;

    allocator.free(registry.entries);
    registry.entries = try kept.toOwnedSlice();
    try store.saveMountRegistry(allocator, &paths, &registry);
}

fn renderList(allocator: std.mem.Allocator, project_shard: ?[]const u8, as_json: bool) ![]u8 {
    const packs_root = try store.packsRootAbsPath(allocator);
    defer allocator.free(packs_root);

    var results = std.ArrayList(struct {
        manifest: store.Manifest,
        root: []u8,
    }).init(allocator);
    defer {
        for (results.items) |*item| {
            item.manifest.deinit();
            allocator.free(item.root);
        }
        results.deinit();
    }

    var top = std.fs.openDirAbsolute(packs_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (top) |*dir| {
        defer dir.close();
        var pack_it = dir.iterate();
        while (try pack_it.next()) |pack_entry| {
            if (pack_entry.kind != .directory) continue;
            const pack_dir_abs = try std.fs.path.join(allocator, &.{ packs_root, pack_entry.name });
            defer allocator.free(pack_dir_abs);
            var ver_dir = try std.fs.openDirAbsolute(pack_dir_abs, .{ .iterate = true });
            defer ver_dir.close();
            var ver_it = ver_dir.iterate();
            while (try ver_it.next()) |ver_entry| {
                if (ver_entry.kind != .directory) continue;
                const root = try std.fs.path.join(allocator, &.{ pack_dir_abs, ver_entry.name });
                errdefer allocator.free(root);
                const manifest_path = try std.fs.path.join(allocator, &.{ root, "manifest.json" });
                defer allocator.free(manifest_path);
                var manifest = try store.loadManifestFromPath(allocator, manifest_path);
                errdefer manifest.deinit();
                try results.append(.{ .manifest = manifest, .root = root });
            }
        }
    }

    if (as_json) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try out.writer().writeAll("[");
        for (results.items, 0..) |item, idx| {
            if (idx != 0) try out.writer().writeByte(',');
            const mount_state = try mountedStateFor(allocator, project_shard, item.manifest.pack_id, item.manifest.pack_version);
            defer if (mount_state.project_id) |value| allocator.free(value);
            try std.json.stringify(.{
                .packId = item.manifest.pack_id,
                .version = item.manifest.pack_version,
                .domain = item.manifest.domain_family,
                .trustClass = item.manifest.trust_class,
                .root = item.root,
                .mounted = mount_state.mounted,
                .enabled = mount_state.enabled,
            }, .{}, out.writer());
        }
        try out.writer().writeAll("]");
        return out.toOwnedSlice();
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    if (results.items.len == 0) {
        try out.writer().writeAll("no_packs=1");
        return out.toOwnedSlice();
    }
    for (results.items, 0..) |item, idx| {
        const mount_state = try mountedStateFor(allocator, project_shard, item.manifest.pack_id, item.manifest.pack_version);
        defer if (mount_state.project_id) |value| allocator.free(value);
        if (idx != 0) try out.writer().writeAll("\n\n");
        try out.writer().print(
            "pack_id={s}\nversion={s}\ndomain={s}\ntrust_class={s}\nmounted={s}\nenabled={s}\nroot={s}",
            .{
                item.manifest.pack_id,
                item.manifest.pack_version,
                item.manifest.domain_family,
                item.manifest.trust_class,
                boolText(mount_state.mounted),
                boolText(mount_state.enabled),
                item.root,
            },
        );
    }
    return out.toOwnedSlice();
}

fn renderDiff(allocator: std.mem.Allocator, left_pack: []const u8, left_version: []const u8, right_pack: []const u8, right_version: []const u8, as_json: bool) ![]u8 {
    var left = try store.loadManifest(allocator, left_pack, left_version);
    defer left.deinit();
    var right = try store.loadManifest(allocator, right_pack, right_version);
    defer right.deinit();

    if (as_json) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try std.json.stringify(.{
            .left = .{ .packId = left.pack_id, .version = left.pack_version },
            .right = .{ .packId = right.pack_id, .version = right.pack_version },
            .metadataChanged = .{
                .domain = !std.mem.eql(u8, left.domain_family, right.domain_family),
                .trustClass = !std.mem.eql(u8, left.trust_class, right.trust_class),
                .sourceSummary = !std.mem.eql(u8, left.provenance.source_summary, right.provenance.source_summary),
            },
            .contentChanged = .{
                .corpusItemCount = left.content.corpus_item_count != right.content.corpus_item_count,
                .conceptCount = left.content.concept_count != right.content.concept_count,
                .corpusHash = left.content.corpus_hash != right.content.corpus_hash,
                .abstractionHash = left.content.abstraction_hash != right.content.abstraction_hash,
                .reuseHash = left.content.reuse_hash != right.content.reuse_hash,
                .lineageHash = left.content.lineage_hash != right.content.lineage_hash,
                .leftCorpusPreview = left.content.corpus_preview,
                .rightCorpusPreview = right.content.corpus_preview,
                .leftConceptPreview = left.content.concept_preview,
                .rightConceptPreview = right.content.concept_preview,
            },
        }, .{ .whitespace = .indent_2 }, out.writer());
        return out.toOwnedSlice();
    }

    return std.fmt.allocPrint(
        allocator,
        "left={s}@{s}\nright={s}@{s}\ndomain_changed={s}\ntrust_class_changed={s}\nsource_summary_changed={s}\ncorpus_count: {d} -> {d}\nconcept_count: {d} -> {d}\ncorpus_hash: {d} -> {d}\nabstraction_hash: {d} -> {d}\nreuse_hash: {d} -> {d}\nlineage_hash: {d} -> {d}\nleft_corpus_preview={s}\nright_corpus_preview={s}\nleft_concept_preview={s}\nright_concept_preview={s}",
        .{
            left.pack_id,
            left.pack_version,
            right.pack_id,
            right.pack_version,
            boolText(!std.mem.eql(u8, left.domain_family, right.domain_family)),
            boolText(!std.mem.eql(u8, left.trust_class, right.trust_class)),
            boolText(!std.mem.eql(u8, left.provenance.source_summary, right.provenance.source_summary)),
            left.content.corpus_item_count,
            right.content.corpus_item_count,
            left.content.concept_count,
            right.content.concept_count,
            left.content.corpus_hash,
            right.content.corpus_hash,
            left.content.abstraction_hash,
            right.content.abstraction_hash,
            left.content.reuse_hash,
            right.content.reuse_hash,
            left.content.lineage_hash,
            right.content.lineage_hash,
            try joinPreview(allocator, left.content.corpus_preview),
            try joinPreview(allocator, right.content.corpus_preview),
            try joinPreview(allocator, left.content.concept_preview),
            try joinPreview(allocator, right.content.concept_preview),
        },
    );
}

fn summarizePackContent(allocator: std.mem.Allocator, root_abs_path: []const u8, pack_id: []const u8, pack_version: []const u8) !store.ContentSummary {
    const corpus_manifest = try std.fs.path.join(allocator, &.{ root_abs_path, "corpus", "manifest.json" });
    defer allocator.free(corpus_manifest);
    const abstraction_catalog = try std.fs.path.join(allocator, &.{ root_abs_path, "abstractions", "abstractions.gabs" });
    defer allocator.free(abstraction_catalog);
    const reuse_catalog = try std.fs.path.join(allocator, &.{ root_abs_path, "abstractions", "reuse.gabr" });
    defer allocator.free(reuse_catalog);
    const lineage_state = try std.fs.path.join(allocator, &.{ root_abs_path, "abstractions", "lineage.gabs" });
    defer allocator.free(lineage_state);

    var corpus_preview = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (corpus_preview.items) |item| allocator.free(item);
        corpus_preview.deinit();
    }
    var concept_preview = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (concept_preview.items) |item| allocator.free(item);
        concept_preview.deinit();
    }

    const corpus_item_count = try collectCorpusPreview(allocator, corpus_manifest, pack_id, pack_version, &corpus_preview);
    const concept_count = try collectConceptPreview(allocator, abstraction_catalog, &concept_preview);

    return .{
        .corpus_item_count = corpus_item_count,
        .concept_count = concept_count,
        .corpus_hash = try fileHashOrZero(corpus_manifest),
        .abstraction_hash = try fileHashOrZero(abstraction_catalog),
        .reuse_hash = try fileHashOrZero(reuse_catalog),
        .lineage_hash = try fileHashOrZero(lineage_state),
        .corpus_preview = try corpus_preview.toOwnedSlice(),
        .concept_preview = try concept_preview.toOwnedSlice(),
    };
}

fn collectCorpusPreview(allocator: std.mem.Allocator, manifest_abs_path: []const u8, pack_id: []const u8, pack_version: []const u8, out: *std.ArrayList([]u8)) !u32 {
    const bytes = try readFileAbsoluteAlloc(allocator, manifest_abs_path, 512 * 1024);
    defer allocator.free(bytes);
    const DiskItem = struct {
        syntheticRelPath: []const u8,
        dedup: []const u8,
    };
    const DiskManifest = struct {
        items: []const DiskItem,
    };
    const parsed = try std.json.parseFromSlice(DiskManifest, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var count: u32 = 0;
    for (parsed.value.items) |item| {
        if (!std.mem.eql(u8, item.dedup, "unique")) continue;
        count += 1;
        const rewritten = try rewriteSyntheticPath(allocator, pack_id, pack_version, item.syntheticRelPath);
        defer allocator.free(rewritten);
        try store.appendPreviewItem(allocator, out, rewritten);
    }
    return count;
}

fn collectConceptPreview(allocator: std.mem.Allocator, abstraction_catalog_abs_path: []const u8, out: *std.ArrayList([]u8)) !u32 {
    const bytes = readFileAbsoluteAlloc(allocator, abstraction_catalog_abs_path, 512 * 1024) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer allocator.free(bytes);
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (std.mem.startsWith(u8, line, "concept ")) {
            count += 1;
            try store.appendPreviewItem(allocator, out, line["concept ".len..]);
        } else if (std.mem.startsWith(u8, line, "schema_entity_signal ") or
            std.mem.startsWith(u8, line, "schema_relation_signal ") or
            std.mem.startsWith(u8, line, "obligation_signal ") or
            std.mem.startsWith(u8, line, "anchor_signal ") or
            std.mem.startsWith(u8, line, "verifier_hint_signal ") or
            std.mem.startsWith(u8, line, "schema_signal "))
        {
            const value_start = (std.mem.indexOfScalar(u8, line, ' ') orelse continue) + 1;
            try store.appendPreviewItem(allocator, out, line[value_start..]);
        }
    }
    return count;
}

fn summarizeSourceLineage(allocator: std.mem.Allocator, corpus_manifest_abs_path: []const u8, abstraction_catalog_abs_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "corpus_hash={d}|abstraction_hash={d}",
        .{ try fileHashOrZero(corpus_manifest_abs_path), try fileHashOrZero(abstraction_catalog_abs_path) },
    );
}

fn writeInfluenceManifest(allocator: std.mem.Allocator, root_abs_path: []const u8, pack_id: []const u8, pack_version: []const u8) !void {
    const abs_path = try std.fs.path.join(allocator, &.{ root_abs_path, "influence.json" });
    defer allocator.free(abs_path);
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try std.json.stringify(.{
        .schemaVersion = "ghost_pack_influence_v1",
        .packId = pack_id,
        .packVersion = pack_version,
        .description = "pack-local reuse and routing artifacts remain explicit files; they never authorize support without normal proof gates",
        .artifacts = .{
            .grounding = "abstractions/abstractions.gabs",
            .reinforcement = "abstractions/lineage.gabs",
            .reuse = "abstractions/reuse.gabr",
            .routing = "abstractions/abstractions.gabs",
        },
    }, .{ .whitespace = .indent_2 }, out.writer());
    try writeFileAbsolute(abs_path, out.items);
}

pub const ExportOptions = struct {
    pack_id: []const u8,
    pack_version: []const u8,
    export_dir: []const u8,
    export_reason: []const u8 = "manual",
};

pub const ExportResult = struct {
    envelope: store.ExportEnvelope,
    export_root_abs_path: []u8,
};

pub const ImportOptions = struct {
    source_dir: []const u8,
    force: bool = false,
};

pub const ImportResult = struct {
    manifest: store.Manifest,
    root_abs_path: []u8,
    was_overwrite: bool,
};

pub const VerifyResult = struct {
    integrity_ok: bool,
    compatibility_ok: bool,
    errors: [][]u8,
};

pub const PackVersionInfo = struct {
    pack_id: []u8,
    version: []u8,
    domain: []u8,
    trust_class: []u8,
    has_envelope: bool,
};

pub fn exportPack(allocator: std.mem.Allocator, options: ExportOptions) !ExportResult {
    const safe_id = try store.sanitizePackId(allocator, options.pack_id);
    defer allocator.free(safe_id);
    const safe_version = try store.sanitizeVersion(allocator, options.pack_version);
    defer allocator.free(safe_version);

    const src_root = try store.packRootAbsPath(allocator, safe_id, safe_version);
    defer allocator.free(src_root);

    var manifest = try store.loadManifest(allocator, safe_id, safe_version);
    defer manifest.deinit();

    const export_root = try std.fs.path.resolve(allocator, &.{options.export_dir});
    errdefer allocator.free(export_root);
    try ensureExportDestinationReady(allocator, export_root);
    try copyTreeAbsolute(src_root, export_root);

    const manifest_json_path = try std.fs.path.join(allocator, &.{ export_root, "manifest.json" });
    defer allocator.free(manifest_json_path);
    const manifest_hash = try fileHashOrZero(manifest_json_path);

    const corpus_manifest_path = try std.fs.path.join(allocator, &.{ export_root, manifest.storage.corpus_manifest_rel_path });
    defer allocator.free(corpus_manifest_path);
    const corpus_manifest_hash = try fileHashOrZero(corpus_manifest_path);

    const corpus_files_dir = std.fs.path.dirname(corpus_manifest_path) orelse export_root;
    const corpus_files_hash = try computeDirectoryHash(allocator, corpus_files_dir, null);

    const abstraction_path = try std.fs.path.join(allocator, &.{ export_root, manifest.storage.abstraction_catalog_rel_path });
    defer allocator.free(abstraction_path);
    const abstraction_hash = try fileHashOrZero(abstraction_path);

    const reuse_path = try std.fs.path.join(allocator, &.{ export_root, manifest.storage.reuse_catalog_rel_path });
    defer allocator.free(reuse_path);
    const reuse_hash = try fileHashOrZero(reuse_path);

    const lineage_path = try std.fs.path.join(allocator, &.{ export_root, manifest.storage.lineage_state_rel_path });
    defer allocator.free(lineage_path);
    const lineage_hash = try fileHashOrZero(lineage_path);

    const influence_path = try std.fs.path.join(allocator, &.{ export_root, manifest.storage.influence_manifest_rel_path });
    defer allocator.free(influence_path);
    const influence_hash = try fileHashOrZero(influence_path);

    const total_files_hash = try computeDirectoryHash(allocator, export_root, "export.json");

    var envelope = store.ExportEnvelope{
        .allocator = allocator,
        .schema_version = try allocator.dupe(u8, store.EXPORT_SCHEMA_VERSION),
        .exported_at = @intCast(std.time.timestamp()),
        .export_engine_version = try allocator.dupe(u8, @import("ghost.zig").VERSION),
        .pack_id = try allocator.dupe(u8, safe_id),
        .pack_version = try allocator.dupe(u8, safe_version),
        .integrity = .{
            .manifest_hash = manifest_hash,
            .corpus_manifest_hash = corpus_manifest_hash,
            .corpus_files_hash = corpus_files_hash,
            .abstraction_hash = abstraction_hash,
            .reuse_hash = reuse_hash,
            .lineage_hash = lineage_hash,
            .influence_hash = influence_hash,
            .total_files_hash = total_files_hash,
        },
        .provenance = .{
            .source_pack_lineage_id = try allocator.dupe(u8, manifest.provenance.pack_lineage_id),
            .source_kind = try allocator.dupe(u8, manifest.provenance.source_kind),
            .export_reason = try allocator.dupe(u8, options.export_reason),
        },
    };
    errdefer envelope.deinit();
    try store.saveExportEnvelope(allocator, export_root, &envelope);

    return .{
        .envelope = envelope,
        .export_root_abs_path = export_root,
    };
}

pub fn importPack(allocator: std.mem.Allocator, options: ImportOptions) !ImportResult {
    const source_dir = try std.fs.path.resolve(allocator, &.{options.source_dir});
    defer allocator.free(source_dir);

    const export_json_path = try std.fs.path.join(allocator, &.{ source_dir, "export.json" });
    defer allocator.free(export_json_path);
    var envelope = try store.loadExportEnvelope(allocator, export_json_path);
    defer envelope.deinit();

    if (!std.mem.eql(u8, envelope.export_engine_version, @import("ghost.zig").VERSION))
        return error.IncompatibleEngineVersion;
    if (!std.mem.eql(u8, envelope.schema_version, store.EXPORT_SCHEMA_VERSION))
        return error.InvalidExportEnvelope;

    const manifest_path = try std.fs.path.join(allocator, &.{ source_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    var artifact_manifest = try store.loadManifestFromPath(allocator, manifest_path);
    defer artifact_manifest.deinit();

    if (!std.mem.eql(u8, artifact_manifest.compatibility.mount_schema, store.MOUNT_SCHEMA_VERSION))
        return error.IncompatibleEngineVersion;

    verifyArtifactIntegrity(allocator, source_dir, &artifact_manifest, &envelope) catch |err| switch (err) {
        error.IntegrityCheckFailed => return error.IntegrityCheckFailed,
        else => return err,
    };

    try verifyNoPathTraversal(allocator, source_dir);

    const dst_root = try store.packRootAbsPath(allocator, envelope.pack_id, envelope.pack_version);
    errdefer allocator.free(dst_root);
    const was_overwrite = pathExists(dst_root);
    if (was_overwrite) {
        if (!options.force) return error.PackAlreadyExists;
        try deleteTreeIfExistsAbsolute(dst_root);
        try prunePackMountEntriesEverywhere(allocator, envelope.pack_id, envelope.pack_version);
    }

    try copyTreeAbsolute(source_dir, dst_root);

    const installed_export_json = try std.fs.path.join(allocator, &.{ dst_root, "export.json" });
    defer allocator.free(installed_export_json);
    std.fs.deleteFileAbsolute(installed_export_json) catch {};

    var installed_manifest = try store.loadManifest(allocator, envelope.pack_id, envelope.pack_version);
    errdefer installed_manifest.deinit();

    return .{
        .manifest = installed_manifest,
        .root_abs_path = dst_root,
        .was_overwrite = was_overwrite,
    };
}

pub fn verifyExportArtifact(allocator: std.mem.Allocator, source_dir_raw: []const u8) !VerifyResult {
    var errors = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (errors.items) |item| allocator.free(item);
        errors.deinit();
    }

    const source_dir = std.fs.path.resolve(allocator, &.{source_dir_raw}) catch |err| switch (err) {
        else => {
            try errors.append(try std.fmt.allocPrint(allocator, "cannot resolve source_dir: {s}", .{@errorName(err)}));
            return .{ .integrity_ok = false, .compatibility_ok = false, .errors = try errors.toOwnedSlice() };
        },
    };
    defer allocator.free(source_dir);

    var integrity_ok = true;
    var compatibility_ok = true;

    const export_json_path = std.fs.path.join(allocator, &.{ source_dir, "export.json" }) catch {
        try errors.append(try allocator.dupe(u8, "export.json not found"));
        return .{ .integrity_ok = false, .compatibility_ok = false, .errors = try errors.toOwnedSlice() };
    };
    defer allocator.free(export_json_path);

    var envelope = store.loadExportEnvelope(allocator, export_json_path) catch |err| {
        try errors.append(try std.fmt.allocPrint(allocator, "cannot load export.json: {s}", .{@errorName(err)}));
        return .{ .integrity_ok = false, .compatibility_ok = false, .errors = try errors.toOwnedSlice() };
    };
    defer envelope.deinit();

    if (!std.mem.eql(u8, envelope.export_engine_version, @import("ghost.zig").VERSION)) {
        compatibility_ok = false;
        try errors.append(try std.fmt.allocPrint(allocator, "engine version mismatch: artifact={s} engine={s}", .{ envelope.export_engine_version, @import("ghost.zig").VERSION }));
    }

    const manifest_path = std.fs.path.join(allocator, &.{ source_dir, "manifest.json" }) catch {
        integrity_ok = false;
        try errors.append(try allocator.dupe(u8, "manifest.json path error"));
        return .{ .integrity_ok = integrity_ok, .compatibility_ok = compatibility_ok, .errors = try errors.toOwnedSlice() };
    };
    defer allocator.free(manifest_path);

    var artifact_manifest = store.loadManifestFromPath(allocator, manifest_path) catch |err| {
        integrity_ok = false;
        try errors.append(try std.fmt.allocPrint(allocator, "cannot load manifest.json: {s}", .{@errorName(err)}));
        return .{ .integrity_ok = integrity_ok, .compatibility_ok = compatibility_ok, .errors = try errors.toOwnedSlice() };
    };
    defer artifact_manifest.deinit();

    if (!std.mem.eql(u8, artifact_manifest.compatibility.mount_schema, store.MOUNT_SCHEMA_VERSION)) {
        compatibility_ok = false;
        try errors.append(try std.fmt.allocPrint(allocator, "mount schema mismatch: artifact={s} engine={s}", .{ artifact_manifest.compatibility.mount_schema, store.MOUNT_SCHEMA_VERSION }));
    }

    verifyArtifactIntegrity(allocator, source_dir, &artifact_manifest, &envelope) catch |err| switch (err) {
        error.IntegrityCheckFailed => {
            integrity_ok = false;
            try errors.append(try allocator.dupe(u8, "integrity hash mismatch"));
        },
        else => {
            integrity_ok = false;
            try errors.append(try std.fmt.allocPrint(allocator, "integrity check error: {s}", .{@errorName(err)}));
        },
    };

    verifyNoPathTraversal(allocator, source_dir) catch |err| {
        integrity_ok = false;
        try errors.append(try std.fmt.allocPrint(allocator, "path traversal detected: {s}", .{@errorName(err)}));
    };

    return .{
        .integrity_ok = integrity_ok,
        .compatibility_ok = compatibility_ok,
        .errors = try errors.toOwnedSlice(),
    };
}

pub fn listPackVersions(allocator: std.mem.Allocator, pack_id: []const u8) ![]PackVersionInfo {
    const safe_id = try store.sanitizePackId(allocator, pack_id);
    defer allocator.free(safe_id);

    const packs_root = try store.packsRootAbsPath(allocator);
    defer allocator.free(packs_root);

    const pack_dir_abs = try std.fs.path.join(allocator, &.{ packs_root, safe_id });
    defer allocator.free(pack_dir_abs);

    var results = std.ArrayList(PackVersionInfo).init(allocator);
    errdefer {
        for (results.items) |*item| {
            allocator.free(item.pack_id);
            allocator.free(item.version);
            allocator.free(item.domain);
            allocator.free(item.trust_class);
        }
        results.deinit();
    }

    var dir = std.fs.openDirAbsolute(pack_dir_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try results.toOwnedSlice(),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const manifest_path = try std.fs.path.join(allocator, &.{ pack_dir_abs, entry.name, "manifest.json" });
        defer allocator.free(manifest_path);
        var manifest = store.loadManifestFromPath(allocator, manifest_path) catch continue;
        defer manifest.deinit();

        const version_dir = try std.fs.path.join(allocator, &.{ pack_dir_abs, entry.name });
        defer allocator.free(version_dir);
        const envelope_path = try std.fs.path.join(allocator, &.{ version_dir, "export.json" });
        defer allocator.free(envelope_path);
        const has_envelope = blk: {
            std.fs.accessAbsolute(envelope_path, .{}) catch break :blk false;
            break :blk true;
        };

        try results.append(.{
            .pack_id = try allocator.dupe(u8, manifest.pack_id),
            .version = try allocator.dupe(u8, manifest.pack_version),
            .domain = try allocator.dupe(u8, manifest.domain_family),
            .trust_class = try allocator.dupe(u8, manifest.trust_class),
            .has_envelope = has_envelope,
        });
    }
    return try results.toOwnedSlice();
}

fn verifyArtifactIntegrity(allocator: std.mem.Allocator, source_dir: []const u8, manifest: *const store.Manifest, envelope: *const store.ExportEnvelope) !void {
    const manifest_json_path = try std.fs.path.join(allocator, &.{ source_dir, "manifest.json" });
    defer allocator.free(manifest_json_path);
    const manifest_hash = try fileHashOrZero(manifest_json_path);

    const corpus_manifest_path = try std.fs.path.join(allocator, &.{ source_dir, manifest.storage.corpus_manifest_rel_path });
    defer allocator.free(corpus_manifest_path);
    const corpus_manifest_hash = try fileHashOrZero(corpus_manifest_path);

    const corpus_files_dir = std.fs.path.dirname(corpus_manifest_path) orelse source_dir;
    const corpus_files_hash = try computeDirectoryHash(allocator, corpus_files_dir, null);

    const abstraction_path = try std.fs.path.join(allocator, &.{ source_dir, manifest.storage.abstraction_catalog_rel_path });
    defer allocator.free(abstraction_path);
    const abstraction_hash = try fileHashOrZero(abstraction_path);

    const reuse_path = try std.fs.path.join(allocator, &.{ source_dir, manifest.storage.reuse_catalog_rel_path });
    defer allocator.free(reuse_path);
    const reuse_hash = try fileHashOrZero(reuse_path);

    const lineage_path = try std.fs.path.join(allocator, &.{ source_dir, manifest.storage.lineage_state_rel_path });
    defer allocator.free(lineage_path);
    const lineage_hash = try fileHashOrZero(lineage_path);

    const influence_path = try std.fs.path.join(allocator, &.{ source_dir, manifest.storage.influence_manifest_rel_path });
    defer allocator.free(influence_path);
    const influence_hash = try fileHashOrZero(influence_path);

    const total_files_hash = try computeDirectoryHash(allocator, source_dir, "export.json");

    if (manifest_hash != envelope.integrity.manifest_hash or
        corpus_manifest_hash != envelope.integrity.corpus_manifest_hash or
        corpus_files_hash != envelope.integrity.corpus_files_hash or
        abstraction_hash != envelope.integrity.abstraction_hash or
        reuse_hash != envelope.integrity.reuse_hash or
        lineage_hash != envelope.integrity.lineage_hash or
        influence_hash != envelope.integrity.influence_hash or
        total_files_hash != envelope.integrity.total_files_hash)
    {
        return error.IntegrityCheckFailed;
    }
}

fn verifyNoPathTraversal(allocator: std.mem.Allocator, source_dir: []const u8) !void {
    var dir = std.fs.openDirAbsolute(source_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    verifyNoPathTraversalWalk(allocator, source_dir, dir) catch return;
}

fn verifyNoPathTraversalWalk(allocator: std.mem.Allocator, root: []const u8, dir: std.fs.Dir) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.indexOf(u8, entry.name, "..") != null) return error.InvalidKnowledgePackManifest;
        switch (entry.kind) {
            .directory => {
                const child = try std.fs.path.join(allocator, &.{ root, entry.name });
                defer allocator.free(child);
                const real = std.fs.realpathAlloc(allocator, child) catch continue;
                defer allocator.free(real);
                if (!pathWithinRoot(root, real)) return error.InvalidKnowledgePackManifest;
                var child_dir = try std.fs.openDirAbsolute(child, .{ .iterate = true });
                defer child_dir.close();
                try verifyNoPathTraversalWalk(allocator, child, child_dir);
            },
            .file => {
                const child = try std.fs.path.join(allocator, &.{ root, entry.name });
                defer allocator.free(child);
                const real = std.fs.realpathAlloc(allocator, child) catch continue;
                defer allocator.free(real);
                if (!pathWithinRoot(root, real)) return error.InvalidKnowledgePackManifest;
            },
            else => {},
        }
    }
}

fn computeDirectoryHash(allocator: std.mem.Allocator, root_abs_path: []const u8, exclude_basename: ?[]const u8) !u64 {
    var hasher = std.hash.Fnv1a_64.init();
    try computeDirectoryHashWalk(allocator, root_abs_path, exclude_basename, &hasher);
    return hasher.final();
}

fn computeDirectoryHashWalk(allocator: std.mem.Allocator, root_abs_path: []const u8, exclude_basename: ?[]const u8, hasher: *std.hash.Fnv1a_64) !void {
    var dir = std.fs.openDirAbsolute(root_abs_path, .{ .iterate = true }) catch return;
    defer dir.close();

    const DirEntry = struct { name: []const u8, kind: std.fs.Dir.Entry.Kind };
    var entries = std.ArrayList(DirEntry).init(allocator);
    defer {
        for (entries.items) |item| allocator.free(item.name);
        entries.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (exclude_basename) |exclude| {
            if (std.mem.eql(u8, entry.name, exclude)) continue;
        }
        try entries.append(.{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
        });
    }
    std.mem.sort(DirEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (entries.items) |entry| {
        hasher.update(entry.name);
        switch (entry.kind) {
            .directory => {
                const child = try std.fs.path.join(allocator, &.{ root_abs_path, entry.name });
                defer allocator.free(child);
                try computeDirectoryHashWalk(allocator, child, null, hasher);
            },
            .file => {
                const child = try std.fs.path.join(allocator, &.{ root_abs_path, entry.name });
                defer allocator.free(child);
                var file = std.fs.openFileAbsolute(child, .{}) catch continue;
                defer file.close();
                var buffer: [4096]u8 = undefined;
                while (true) {
                    const read = file.read(&buffer) catch break;
                    if (read == 0) break;
                    hasher.update(buffer[0..read]);
                }
            },
            else => {},
        }
    }
}

fn renderExportSummary(allocator: std.mem.Allocator, envelope: *const store.ExportEnvelope, export_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "exported={s}@{s}\nroot={s}\nengine={s}\nexported_at={d}\nmanifest_hash={d}\ntotal_files_hash={d}\nexport_reason={s}",
        .{
            envelope.pack_id,
            envelope.pack_version,
            export_root,
            envelope.export_engine_version,
            envelope.exported_at,
            envelope.integrity.manifest_hash,
            envelope.integrity.total_files_hash,
            envelope.provenance.export_reason,
        },
    );
}

fn renderImportResult(allocator: std.mem.Allocator, result: *const ImportResult) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "imported={s}@{s}\nroot={s}\ntrust_class={s}\noverwritten={s}\nmounted=false",
        .{
            result.manifest.pack_id,
            result.manifest.pack_version,
            result.root_abs_path,
            result.manifest.trust_class,
            boolText(result.was_overwrite),
        },
    );
}

fn renderVerifyResult(allocator: std.mem.Allocator, result: *const VerifyResult) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.writer().print("integrity_ok={s}\ncompatibility_ok={s}\nerrors={d}", .{
        boolText(result.integrity_ok),
        boolText(result.compatibility_ok),
        result.errors.len,
    });
    for (result.errors) |err_text| {
        try out.writer().print("\n  - {s}", .{err_text});
    }
    return out.toOwnedSlice();
}

const AutopsyGuidanceCliOptions = struct {
    pack_id: ?[]const u8,
    pack_version: ?[]const u8,
    manifest_path: ?[]const u8,
    all_mounted: bool,
    project_shard: ?[]const u8,
    limits: autopsy_guidance_validator.AutopsyGuidanceValidationLimits,
};

fn validateAutopsyGuidanceForCli(allocator: std.mem.Allocator, options: AutopsyGuidanceCliOptions) !autopsy_guidance_validator.ValidationSummary {
    const modes: usize = (if (options.all_mounted) @as(usize, 1) else 0) +
        (if (options.manifest_path != null) @as(usize, 1) else 0) +
        (if (options.pack_id != null or options.pack_version != null) @as(usize, 1) else 0);
    if (modes != 1) return error.InvalidArguments;

    if (options.all_mounted) {
        var paths = try resolveProjectPathsForCli(allocator, options.project_shard);
        defer paths.deinit();
        return try autopsy_guidance_validator.validateMountedPacksWithLimits(allocator, &paths, options.limits);
    }

    var reports = std.ArrayList(autopsy_guidance_validator.GuidanceValidationReport).init(allocator);
    errdefer {
        for (reports.items) |*report| report.deinit();
        reports.deinit();
    }

    const report = if (options.manifest_path) |path|
        try autopsy_guidance_validator.validateManifestPathWithLimits(allocator, path, options.limits)
    else
        try autopsy_guidance_validator.validateInstalledPackWithLimits(
            allocator,
            options.pack_id orelse return error.InvalidArguments,
            options.pack_version orelse return error.InvalidArguments,
            options.limits,
        );

    const error_count = report.error_count;
    const warning_count = report.warning_count;
    try reports.append(report);

    return .{
        .allocator = allocator,
        .reports = try reports.toOwnedSlice(),
        .error_count = error_count,
        .warning_count = warning_count,
    };
}

fn renderAutopsyGuidanceValidation(
    allocator: std.mem.Allocator,
    summary: *const autopsy_guidance_validator.ValidationSummary,
    as_json: bool,
) ![]u8 {
    if (as_json) return renderAutopsyGuidanceValidationJson(allocator, summary);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.writer().print("autopsy_guidance_valid={s}\nreports={d}\nerrors={d}\nwarnings={d}", .{
        boolText(summary.ok()),
        summary.reports.len,
        summary.error_count,
        summary.warning_count,
    });
    try out.writer().print("\nexpected_schema={s}", .{autopsy_guidance_validator.EXPECTED_GUIDANCE_SCHEMA});
    for (summary.reports) |report| {
        try out.writer().print(
            "\n\npack={s}@{s}\nmanifest={s}\nguidance_declared={s}\nguidance_path={s}\nguidance_entries={d}\nerrors={d}\nwarnings={d}",
            .{
                report.pack_id,
                report.pack_version,
                report.manifest_path,
                boolText(report.declared_guidance_path),
                report.guidance_path orelse "<none>",
                report.guidance_count,
                report.error_count,
                report.warning_count,
            },
        );
        if (report.schema) |schema| {
            try out.writer().print("\nschema={s}", .{schema});
        } else if (report.legacy_unversioned_schema) {
            try out.writer().writeAll("\nschema=<legacy-unversioned>");
        }
        if (report.issues.len == 0) {
            try out.writer().writeAll("\n  pass");
        } else {
            for (report.issues) |issue| {
                try out.writer().print("\n  - {s} {s} {s}: {s}", .{
                    @tagName(issue.severity),
                    issue.code,
                    issue.path,
                    issue.message,
                });
            }
        }
    }
    return out.toOwnedSlice();
}

fn renderAutopsyGuidanceValidationJson(
    allocator: std.mem.Allocator,
    summary: *const autopsy_guidance_validator.ValidationSummary,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"ok\":");
    try w.writeAll(if (summary.ok()) "true" else "false");
    try w.writeAll(",\"expectedSchema\":");
    try writeJsonString(w, autopsy_guidance_validator.EXPECTED_GUIDANCE_SCHEMA);
    try w.writeAll(",\"supportedSchemaVersions\":[");
    try writeJsonString(w, autopsy_guidance_validator.AUTOPSY_GUIDANCE_SCHEMA_V1);
    try w.writeAll("]");
    try w.writeAll(",\"errorCount\":");
    try w.print("{d}", .{summary.error_count});
    try w.writeAll(",\"warningCount\":");
    try w.print("{d}", .{summary.warning_count});
    try w.writeAll(",\"reports\":[");
    for (summary.reports, 0..) |report, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"packId\":");
        try writeJsonString(w, report.pack_id);
        try w.writeAll(",\"version\":");
        try writeJsonString(w, report.pack_version);
        try w.writeAll(",\"manifestPath\":");
        try writeJsonString(w, report.manifest_path);
        try w.writeAll(",\"guidanceDeclared\":");
        try w.writeAll(if (report.declared_guidance_path) "true" else "false");
        try w.writeAll(",\"guidancePath\":");
        if (report.guidance_path) |path| try writeJsonString(w, path) else try w.writeAll("null");
        try w.writeAll(",\"guidanceCount\":");
        try w.print("{d}", .{report.guidance_count});
        try w.writeAll(",\"schema\":");
        if (report.schema) |schema| try writeJsonString(w, schema) else try w.writeAll("null");
        try w.writeAll(",\"legacyUnversionedSchema\":");
        try w.writeAll(if (report.legacy_unversioned_schema) "true" else "false");
        try w.writeAll(",\"errorCount\":");
        try w.print("{d}", .{report.error_count});
        try w.writeAll(",\"warningCount\":");
        try w.print("{d}", .{report.warning_count});
        try w.writeAll(",\"issues\":[");
        for (report.issues, 0..) |issue, issue_idx| {
            if (issue_idx != 0) try w.writeByte(',');
            try w.writeAll("{\"severity\":");
            try writeJsonString(w, @tagName(issue.severity));
            try w.writeAll(",\"code\":");
            try writeJsonString(w, issue.code);
            try w.writeAll(",\"path\":");
            try writeJsonString(w, issue.path);
            try w.writeAll(",\"message\":");
            try writeJsonString(w, issue.message);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

fn renderCapabilities(allocator: std.mem.Allocator, as_json: bool) ![]u8 {
    if (!as_json) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try out.writer().writeAll("binary=ghost_knowledge_pack\n");
        try out.writer().print("ghost_version={s}\ncommands=", .{@import("ghost.zig").VERSION});
        for (command_registry, 0..) |spec, idx| {
            if (idx != 0) try out.writer().writeAll(",");
            try out.writer().writeAll(spec.name);
        }
        try out.writer().print("\nautopsy_guidance_schema={s}", .{autopsy_guidance_validator.AUTOPSY_GUIDANCE_SCHEMA_V1});
        return out.toOwnedSlice();
    }

    const defaults = autopsy_guidance_validator.AutopsyGuidanceValidationLimits.default();
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"binaryName\":\"ghost_knowledge_pack\",\"ghostVersion\":");
    try writeJsonString(w, @import("ghost.zig").VERSION);
    try w.writeAll(",\"commands\":[");
    for (command_registry, 0..) |spec, idx| {
        if (idx != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, spec.name);
        try w.writeAll(",\"summary\":");
        try writeJsonString(w, spec.summary);
        try w.writeAll(",\"aliases\":[");
        for (spec.aliases, 0..) |alias, alias_idx| {
            if (alias_idx != 0) try w.writeByte(',');
            try writeJsonString(w, alias);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("],\"validateAutopsyGuidance\":{\"flags\":[\"--pack-id\",\"--version\",\"--manifest\",\"--all-mounted\",\"--project-shard\",\"--json\",\"--max-guidance-bytes\",\"--max-array-items\",\"--max-string-bytes\"],\"supportedSchemaVersions\":[");
    try writeJsonString(w, autopsy_guidance_validator.AUTOPSY_GUIDANCE_SCHEMA_V1);
    try w.writeAll("],\"preferredShape\":\"{\\\"schema\\\":\\\"ghost.autopsy_guidance.v1\\\",\\\"packGuidance\\\":[...]}\",\"legacyShapes\":[\"top_level_array\",\"packGuidance\",\"pack_guidance\"],\"validationLimits\":{\"defaults\":{");
    try w.print("\"maxGuidanceBytes\":{d},\"maxGuidanceEntries\":{d},\"maxArrayItems\":{d},\"maxStringBytes\":{d}", .{
        defaults.max_guidance_bytes,
        defaults.max_guidance_entries,
        defaults.max_array_items,
        defaults.max_string_bytes,
    });
    try w.writeAll("},\"hardCaps\":{");
    try w.print("\"maxGuidanceBytes\":{d},\"maxGuidanceEntries\":{d},\"maxArrayItems\":{d},\"maxStringBytes\":{d}", .{
        autopsy_guidance_validator.AutopsyGuidanceValidationLimits.hard_cap_guidance_bytes,
        autopsy_guidance_validator.AutopsyGuidanceValidationLimits.hard_cap_guidance_entries,
        autopsy_guidance_validator.AutopsyGuidanceValidationLimits.hard_cap_array_items,
        autopsy_guidance_validator.AutopsyGuidanceValidationLimits.hard_cap_string_bytes,
    });
    try w.writeAll("}}}}");
    return out.toOwnedSlice();
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn renderVersionList(allocator: std.mem.Allocator, versions: []PackVersionInfo, as_json: bool) ![]u8 {
    if (as_json) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try out.writer().writeAll("[");
        for (versions, 0..) |item, idx| {
            if (idx != 0) try out.writer().writeByte(',');
            try std.json.stringify(.{
                .packId = item.pack_id,
                .version = item.version,
                .domain = item.domain,
                .trustClass = item.trust_class,
                .hasEnvelope = item.has_envelope,
            }, .{}, out.writer());
        }
        try out.writer().writeAll("]");
        return out.toOwnedSlice();
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    if (versions.len == 0) {
        try out.writer().writeAll("no_versions=1");
        return out.toOwnedSlice();
    }
    for (versions, 0..) |item, idx| {
        if (idx != 0) try out.writer().writeAll("\n");
        try out.writer().print("pack_id={s}\nversion={s}\ndomain={s}\ntrust_class={s}\nhas_envelope={s}", .{
            item.pack_id,
            item.version,
            item.domain,
            item.trust_class,
            boolText(item.has_envelope),
        });
    }
    return out.toOwnedSlice();
}

pub const DistillationExportOptions = struct {
    project_shard: ?[]const u8,
    candidate_id: []const u8,
    pack_id: []const u8,
    pack_version: []const u8,
    domain_family: []const u8 = "general",
    trust_class: []const u8 = "exploratory",
    source_summary: ?[]const u8 = null,
};

fn renderDistillationList(allocator: std.mem.Allocator, project_shard: ?[]const u8, as_json: bool) ![]u8 {
    var paths = try resolveProjectPathsForCli(allocator, project_shard);
    defer paths.deinit();
    const candidates = try feedback_distillation.listCandidates(allocator, &paths);
    defer feedback_distillation.deinitCandidates(candidates);

    if (as_json) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try out.writer().writeByte('[');
        for (candidates, 0..) |candidate, idx| {
            if (idx != 0) try out.writer().writeByte(',');
            try std.json.stringify(.{
                .id = candidate.id,
                .type = feedback_distillation.candidateTypeName(candidate.candidate_type),
                .eligible = candidate.eligible,
                .successCount = candidate.success_count,
                .failureCount = candidate.failure_count,
                .independentCaseCount = candidate.independent_case_count,
                .contradictionCount = candidate.contradiction_count,
                .trustRecommendation = feedback_distillation.trustRecommendationName(candidate.trust_recommendation),
                .reuseScope = feedback_distillation.reuseScopeName(candidate.reuse_scope),
                .explanation = candidate.explanation,
            }, .{}, out.writer());
        }
        try out.writer().writeByte(']');
        return out.toOwnedSlice();
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    if (candidates.len == 0) {
        try out.writer().writeAll("no_distillation_candidates=1");
        return out.toOwnedSlice();
    }
    for (candidates, 0..) |candidate, idx| {
        if (idx != 0) try out.writer().writeAll("\n\n");
        try out.writer().print(
            "candidate_id={s}\ntype={s}\neligible={s}\nsuccesses={d}\nfailures={d}\nindependent_cases={d}\ncontradictions={d}\ntrust_recommendation={s}\nreuse_scope={s}\nwhy={s}",
            .{
                candidate.id,
                feedback_distillation.candidateTypeName(candidate.candidate_type),
                boolText(candidate.eligible),
                candidate.success_count,
                candidate.failure_count,
                candidate.independent_case_count,
                candidate.contradiction_count,
                feedback_distillation.trustRecommendationName(candidate.trust_recommendation),
                feedback_distillation.reuseScopeName(candidate.reuse_scope),
                candidate.explanation,
            },
        );
    }
    return out.toOwnedSlice();
}

fn renderDistillationShow(allocator: std.mem.Allocator, project_shard: ?[]const u8, candidate_id: []const u8, as_json: bool) ![]u8 {
    var paths = try resolveProjectPathsForCli(allocator, project_shard);
    defer paths.deinit();
    var candidate = (try feedback_distillation.findCandidate(allocator, &paths, candidate_id)) orelse return error.CandidateNotFound;
    defer candidate.deinit();

    if (as_json) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try std.json.stringify(.{
            .id = candidate.id,
            .type = feedback_distillation.candidateTypeName(candidate.candidate_type),
            .sourceFeedbackEvents = candidate.source_feedback_events,
            .successCount = candidate.success_count,
            .failureCount = candidate.failure_count,
            .ambiguityCount = candidate.ambiguity_count,
            .independentCaseCount = candidate.independent_case_count,
            .contradictionCount = candidate.contradiction_count,
            .provenance = candidate.provenance,
            .trustRecommendation = feedback_distillation.trustRecommendationName(candidate.trust_recommendation),
            .reuseScope = feedback_distillation.reuseScopeName(candidate.reuse_scope),
            .eligible = candidate.eligible,
            .explanation = candidate.explanation,
        }, .{ .whitespace = .indent_2 }, out.writer());
        return out.toOwnedSlice();
    }

    const source_events = try joinPreview(allocator, candidate.source_feedback_events);
    defer allocator.free(source_events);
    return std.fmt.allocPrint(
        allocator,
        "candidate_id={s}\ntype={s}\neligible={s}\nsuccesses={d}\nfailures={d}\nambiguities={d}\nindependent_cases={d}\ncontradictions={d}\nsource_feedback_events={s}\ntrust_recommendation={s}\nreuse_scope={s}\nwhy={s}\nprovenance_entries={d}",
        .{
            candidate.id,
            feedback_distillation.candidateTypeName(candidate.candidate_type),
            boolText(candidate.eligible),
            candidate.success_count,
            candidate.failure_count,
            candidate.ambiguity_count,
            candidate.independent_case_count,
            candidate.contradiction_count,
            source_events,
            feedback_distillation.trustRecommendationName(candidate.trust_recommendation),
            feedback_distillation.reuseScopeName(candidate.reuse_scope),
            candidate.explanation,
            candidate.provenance.len,
        },
    );
}

pub fn exportDistillationCandidate(allocator: std.mem.Allocator, options: DistillationExportOptions) !CreateResult {
    var paths = try resolveProjectPathsForCli(allocator, options.project_shard);
    defer paths.deinit();
    var candidate = (try feedback_distillation.findCandidate(allocator, &paths, options.candidate_id)) orelse return error.CandidateNotFound;
    defer candidate.deinit();
    if (!candidate.eligible) return error.DistillationCandidateIneligible;

    const safe_id = try store.sanitizePackId(allocator, options.pack_id);
    defer allocator.free(safe_id);
    const safe_version = try store.sanitizeVersion(allocator, options.pack_version);
    defer allocator.free(safe_version);
    var result = try ensureDistillationPack(allocator, .{
        .pack_id = safe_id,
        .pack_version = safe_version,
        .domain_family = options.domain_family,
        .trust_class = options.trust_class,
        .source_summary = options.source_summary,
        .source_project_shard = paths.metadata.id,
        .source_state = .live,
        .corpus_path = null,
        .corpus_label = null,
    });
    errdefer {
        result.manifest.deinit();
        allocator.free(result.root_abs_path);
    }

    const catalog_path = try std.fs.path.join(allocator, &.{ result.root_abs_path, result.manifest.storage.abstraction_catalog_rel_path });
    defer allocator.free(catalog_path);
    const records = try abstractions.loadCatalogSnapshotFromPath(allocator, catalog_path);
    defer abstractions.deinitRecordSlice(records);
    for (records) |record| {
        if (std.mem.eql(u8, record.concept_id, candidate.concept_id)) return error.DistillationCandidateAlreadyExported;
    }

    var next = try allocator.alloc(abstractions.Record, records.len + 1);
    defer allocator.free(next);
    for (records, 0..) |record, idx| next[idx] = try record.clone(allocator);
    defer {
        for (next[0..records.len]) |*record| record.deinit();
    }
    next[records.len] = try feedback_distillation.toPackRecord(allocator, &candidate);
    defer next[records.len].deinit();
    try abstractions.saveCatalogSnapshotToPath(allocator, catalog_path, next);
    try writeDistillationManifest(allocator, result.root_abs_path, &result.manifest, &candidate);
    try refreshPackManifestContent(allocator, result.manifest.pack_id, result.manifest.pack_version);
    result.manifest.deinit();
    result.manifest = try store.loadManifest(allocator, safe_id, safe_version);
    return result;
}

fn renderDistillationExportResult(allocator: std.mem.Allocator, result: *const CreateResult, candidate_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "distillation_exported=true\ncandidate_id={s}\npack_id={s}\nversion={s}\nroot={s}\ntrust_class={s}\nnon_authorizing=true",
        .{ candidate_id, result.manifest.pack_id, result.manifest.pack_version, result.root_abs_path, result.manifest.trust_class },
    );
}

fn ensureDistillationPack(allocator: std.mem.Allocator, options: CreateOptions) !CreateResult {
    const root = try store.packRootAbsPath(allocator, options.pack_id, options.pack_version);
    if (pathExists(root)) {
        const manifest = try store.loadManifest(allocator, options.pack_id, options.pack_version);
        return .{ .manifest = manifest, .root_abs_path = root };
    }
    try sys.makePath(allocator, root);
    const corpus_dir = try std.fs.path.join(allocator, &.{ root, "corpus" });
    defer allocator.free(corpus_dir);
    const abstractions_dir = try std.fs.path.join(allocator, &.{ root, "abstractions" });
    defer allocator.free(abstractions_dir);
    try sys.makePath(allocator, corpus_dir);
    try sys.makePath(allocator, abstractions_dir);
    const corpus_manifest = try std.fs.path.join(allocator, &.{ corpus_dir, "manifest.json" });
    defer allocator.free(corpus_manifest);
    try writeFileAbsolute(corpus_manifest, "{\"items\":[]}\n");
    const catalog_path = try std.fs.path.join(allocator, &.{ abstractions_dir, "abstractions.gabs" });
    defer allocator.free(catalog_path);
    try abstractions.saveCatalogSnapshotToPath(allocator, catalog_path, &.{});
    const reuse_path = try std.fs.path.join(allocator, &.{ abstractions_dir, "reuse.gabr" });
    defer allocator.free(reuse_path);
    try writeFileAbsolute(reuse_path, "GABR1\n");
    const lineage_path = try std.fs.path.join(allocator, &.{ abstractions_dir, "lineage.gabs" });
    defer allocator.free(lineage_path);
    try writeFileAbsolute(lineage_path, "GABS2\nrevision 0\n");
    try writeInfluenceManifest(allocator, root, options.pack_id, options.pack_version);

    var content = try summarizePackContent(allocator, root, options.pack_id, options.pack_version);
    errdefer content.deinit(allocator);
    var manifest = store.Manifest{
        .allocator = allocator,
        .schema_version = try allocator.dupe(u8, store.PACK_SCHEMA_VERSION),
        .pack_id = try allocator.dupe(u8, options.pack_id),
        .pack_version = try allocator.dupe(u8, options.pack_version),
        .domain_family = try allocator.dupe(u8, options.domain_family),
        .trust_class = try allocator.dupe(u8, options.trust_class),
        .compatibility = .{
            .engine_version = try allocator.dupe(u8, @import("ghost.zig").VERSION),
            .linux_first = true,
            .deterministic_only = true,
            .mount_schema = try allocator.dupe(u8, store.MOUNT_SCHEMA_VERSION),
        },
        .storage = .{
            .corpus_manifest_rel_path = try allocator.dupe(u8, "corpus/manifest.json"),
            .corpus_files_rel_path = try allocator.dupe(u8, "corpus"),
            .abstraction_catalog_rel_path = try allocator.dupe(u8, "abstractions/abstractions.gabs"),
            .reuse_catalog_rel_path = try allocator.dupe(u8, "abstractions/reuse.gabr"),
            .lineage_state_rel_path = try allocator.dupe(u8, "abstractions/lineage.gabs"),
            .influence_manifest_rel_path = try allocator.dupe(u8, "influence.json"),
            .autopsy_guidance_rel_path = null,
        },
        .provenance = .{
            .pack_lineage_id = try std.fmt.allocPrint(allocator, "pack:{s}@{s}", .{ options.pack_id, options.pack_version }),
            .source_kind = try allocator.dupe(u8, "feedback_distillation"),
            .source_id = try allocator.dupe(u8, options.source_project_shard orelse "unknown"),
            .source_state = .live,
            .freshness_state = .active,
            .source_summary = try allocator.dupe(u8, options.source_summary orelse "curated feedback distillation"),
            .source_lineage_summary = try allocator.dupe(u8, "distilled_candidates=explicit_review_required"),
        },
        .content = content,
    };
    errdefer manifest.deinit();
    try store.saveManifest(allocator, root, &manifest);
    return .{ .manifest = manifest, .root_abs_path = root };
}

fn writeDistillationManifest(allocator: std.mem.Allocator, root_abs_path: []const u8, manifest: *const store.Manifest, candidate: *const feedback_distillation.Candidate) !void {
    const path = try std.fs.path.join(allocator, &.{ root_abs_path, "distilled_feedback.json" });
    defer allocator.free(path);
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try std.json.stringify(.{
        .schemaVersion = "ghost_feedback_distillation_v1",
        .packId = manifest.pack_id,
        .packVersion = manifest.pack_version,
        .candidateId = candidate.id,
        .type = feedback_distillation.candidateTypeName(candidate.candidate_type),
        .sourceFeedbackEvents = candidate.source_feedback_events,
        .successCount = candidate.success_count,
        .failureCount = candidate.failure_count,
        .independentCaseCount = candidate.independent_case_count,
        .contradictionCount = candidate.contradiction_count,
        .reuseScope = feedback_distillation.reuseScopeName(candidate.reuse_scope),
        .nonAuthorizing = true,
    }, .{ .whitespace = .indent_2 }, out.writer());
    try writeFileAbsolute(path, out.items);
}

fn resolveProjectPathsForCli(allocator: std.mem.Allocator, project_shard: ?[]const u8) !shards.Paths {
    var metadata = if (project_shard) |value|
        try shards.resolveProjectMetadata(allocator, value)
    else
        try shards.resolveDefaultProjectMetadata(allocator);
    defer metadata.deinit();
    return try shards.resolvePaths(allocator, metadata.metadata);
}

fn parseLimitArg(arg: []const u8, prefix: []const u8) !usize {
    const raw = arg[prefix.len..];
    if (raw.len == 0) return error.InvalidLimit;
    return std.fmt.parseInt(usize, raw, 10) catch error.InvalidLimit;
}

fn printLimitErrorAndExit(err: anyerror, label: []const u8, value: usize) noreturn {
    const limits = autopsy_guidance_validator.AutopsyGuidanceValidationLimits;
    switch (err) {
        error.GuidanceBytesLimitOutOfRange => std.debug.print("{s} out of range: value={d} hard_cap={d}\n", .{ label, value, limits.hard_cap_guidance_bytes }),
        error.GuidanceEntriesLimitOutOfRange => std.debug.print("{s} out of range: value={d} hard_cap={d}\n", .{ label, value, limits.hard_cap_guidance_entries }),
        error.GuidanceArrayItemsLimitOutOfRange => std.debug.print("{s} out of range: value={d} hard_cap={d}\n", .{ label, value, limits.hard_cap_array_items }),
        error.GuidanceStringBytesLimitOutOfRange => std.debug.print("{s} out of range: value={d} hard_cap={d}\n", .{ label, value, limits.hard_cap_string_bytes }),
        else => std.debug.print("{s} must be a positive decimal integer\n", .{label}),
    }
    std.process.exit(2);
}

fn validateLimitsOrExit(limits: autopsy_guidance_validator.AutopsyGuidanceValidationLimits) void {
    limits.validate() catch |err| {
        switch (err) {
            error.GuidanceBytesLimitOutOfRange => printLimitErrorAndExit(err, "--max-guidance-bytes", limits.max_guidance_bytes),
            error.GuidanceEntriesLimitOutOfRange => printLimitErrorAndExit(err, "--max-guidance-entries", limits.max_guidance_entries),
            error.GuidanceArrayItemsLimitOutOfRange => printLimitErrorAndExit(err, "--max-array-items", limits.max_array_items),
            error.GuidanceStringBytesLimitOutOfRange => printLimitErrorAndExit(err, "--max-string-bytes", limits.max_string_bytes),
        }
    };
}

fn parseCommand(text: []const u8) ?Command {
    for (command_registry) |spec| {
        if (std.mem.eql(u8, text, spec.name)) return spec.command;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, text, alias)) return spec.command;
        }
    }
    return null;
}

fn parseTrustClass(text: []const u8) ?abstractions.TrustClass {
    return abstractions.parseTrustClassName(text);
}

fn printUsage() void {
    const stdout = std.io.getStdOut().writer();
    writeUsage(stdout) catch {};
}

fn writeUsage(writer: anytype) !void {
    try writer.writeAll("Usage: ghost_knowledge_pack <command> [flags]\n\nCommands:\n");
    for (command_registry) |spec| {
        try writer.print("  {s} - {s}\n", .{ spec.name, spec.summary });
    }
    try writer.writeAll("\nFlags: [--pack-id=id] [--version=v] [--domain=family] [--trust-class=exploratory|project|promoted|core] [--source-summary=text] [--project-shard=id] [--source-project-shard=id] [--source-state=staged|live] [--corpus=/abs/or/rel/path] [--corpus-label=text] [--to-pack-id=id] [--to-version=v] [--left-pack=id] [--left-version=v] [--right-pack=id] [--right-version=v] [--manifest=/abs/or/rel/manifest.json] [--all-mounted] [--max-guidance-bytes=n] [--max-array-items=n] [--max-string-bytes=n] [--candidate-id=id] [--approve] [--export-dir=/abs/path] [--force] [--export-reason=text] [--json]\n");
}

fn joinPreview(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    if (items.len == 0) return allocator.dupe(u8, "<none>");
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (items, 0..) |item, idx| {
        if (idx != 0) try out.writer().writeAll(",");
        try out.writer().writeAll(item);
    }
    return out.toOwnedSlice();
}

fn rewriteSyntheticPath(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, corpus_ingest.CORPUS_REL_PREFIX ++ "/")) {
        return std.fmt.allocPrint(allocator, "@pack/{s}/{s}/{s}", .{ pack_id, pack_version, path[corpus_ingest.CORPUS_REL_PREFIX.len + 1 ..] });
    }
    return std.fmt.allocPrint(allocator, "@pack/{s}/{s}/{s}", .{ pack_id, pack_version, path });
}

test "ghost_knowledge_pack command registry drives parsing and help" {
    var usage = std.ArrayList(u8).init(std.testing.allocator);
    defer usage.deinit();
    try writeUsage(usage.writer());

    for (command_registry) |spec| {
        try std.testing.expectEqual(spec.command, parseCommand(spec.name).?);
        try std.testing.expect(std.mem.indexOf(u8, usage.items, spec.name) != null);
        for (spec.aliases) |alias| {
            try std.testing.expectEqual(spec.command, parseCommand(alias).?);
        }
    }
    try std.testing.expect(parseCommand("not-a-command") == null);
}

test "ghost_knowledge_pack capabilities json lists validation compatibility surface" {
    const rendered = try renderCapabilities(std.testing.allocator, true);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"binaryName\":\"ghost_knowledge_pack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"name\":\"validate-autopsy-guidance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"--max-guidance-bytes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, autopsy_guidance_validator.AUTOPSY_GUIDANCE_SCHEMA_V1) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"validationLimits\"") != null);
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn fileHashOrZero(abs_path: []const u8) !u64 {
    const file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer file.close();
    var hasher = std.hash.Fnv1a_64.init();
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read = try file.read(&buffer);
        if (read == 0) break;
        hasher.update(buffer[0..read]);
    }
    return hasher.final();
}

fn pathExists(abs_path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(abs_path, .{}) catch return false;
    dir.close();
    return true;
}

fn ensureExportDestinationReady(allocator: std.mem.Allocator, export_root: []const u8) !void {
    _ = allocator;
    var dir = std.fs.openDirAbsolute(export_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    if (try it.next() != null) return error.ExportDestinationNotEmpty;
}

fn readFileAbsoluteAlloc(allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn writeFileAbsolute(abs_path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(abs_path)) |parent| {
        try sys.makePath(std.heap.page_allocator, parent);
    }
    var file = try std.fs.createFileAbsolute(abs_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn deleteTreeIfExistsAbsolute(abs_path: []const u8) !void {
    std.fs.deleteTreeAbsolute(abs_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn copyTreeAbsolute(src_root: []const u8, dst_root: []const u8) !void {
    try sys.makePath(std.heap.page_allocator, dst_root);
    var dir = try std.fs.openDirAbsolute(src_root, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const child_src = try std.fs.path.join(std.heap.page_allocator, &.{ src_root, entry.name });
        defer std.heap.page_allocator.free(child_src);
        const child_dst = try std.fs.path.join(std.heap.page_allocator, &.{ dst_root, entry.name });
        defer std.heap.page_allocator.free(child_dst);
        switch (entry.kind) {
            .directory => try copyTreeAbsolute(child_src, child_dst),
            .file => try copyFileAbsolute(child_src, child_dst),
            else => {},
        }
    }
}

fn copyFileAbsolute(src_abs_path: []const u8, dst_abs_path: []const u8) !void {
    if (std.fs.path.dirname(dst_abs_path)) |parent| {
        try sys.makePath(std.heap.page_allocator, parent);
    }
    var src = try std.fs.openFileAbsolute(src_abs_path, .{});
    defer src.close();
    var dst = try std.fs.createFileAbsolute(dst_abs_path, .{ .truncate = true });
    defer dst.close();
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read = try src.read(&buffer);
        if (read == 0) break;
        try dst.writeAll(buffer[0..read]);
    }
}

fn pathWithinRoot(root_abs_path: []const u8, candidate_abs_path: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate_abs_path, root_abs_path)) return false;
    if (candidate_abs_path.len == root_abs_path.len) return true;
    if (root_abs_path.len == 0) return false;
    return std.fs.path.isSep(candidate_abs_path[root_abs_path.len]);
}

const feedback = @import("feedback.zig");

test "user-approved distillation candidate exports into knowledge pack" {
    const allocator = std.testing.allocator;
    const pack_id = "distilled-feedback-export-test";
    const version = "v1";
    removePack(allocator, pack_id, version) catch {};
    defer removePack(allocator, pack_id, version) catch {};

    var metadata = try shards.resolveProjectMetadata(allocator, "distill-export-source-test");
    defer metadata.deinit();
    var paths = try shards.resolvePaths(allocator, metadata.metadata);
    defer paths.deinit();
    try deleteTreeIfExistsAbsolute(paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(paths.root_abs_path) catch {};

    try recordVerifierSuccessesForPackTest(allocator, &paths, "candidate:local_guard", 2);
    var result = try exportDistillationCandidate(allocator, .{
        .project_shard = paths.metadata.id,
        .candidate_id = "action_surface:candidate_local_guard",
        .pack_id = pack_id,
        .pack_version = version,
    });
    defer result.manifest.deinit();
    defer allocator.free(result.root_abs_path);

    try std.testing.expectEqualStrings(pack_id, result.manifest.pack_id);
    try std.testing.expect(result.manifest.content.concept_count >= 1);
    const distill_manifest = try std.fs.path.join(allocator, &.{ result.root_abs_path, "distilled_feedback.json" });
    defer allocator.free(distill_manifest);
    try std.fs.accessAbsolute(distill_manifest, .{});
}

test "distilled pack records priority hint but not final support authority" {
    const allocator = std.testing.allocator;
    const pack_id = "distilled-feedback-influence-test";
    const version = "v1";
    removePack(allocator, pack_id, version) catch {};
    defer removePack(allocator, pack_id, version) catch {};

    var source_metadata = try shards.resolveProjectMetadata(allocator, "distill-influence-source-test");
    defer source_metadata.deinit();
    var source_paths = try shards.resolvePaths(allocator, source_metadata.metadata);
    defer source_paths.deinit();
    try deleteTreeIfExistsAbsolute(source_paths.root_abs_path);
    defer deleteTreeIfExistsAbsolute(source_paths.root_abs_path) catch {};
    try recordVerifierSuccessesForPackTest(allocator, &source_paths, "candidate:priority_hint", 2);

    var result = try exportDistillationCandidate(allocator, .{
        .project_shard = source_paths.metadata.id,
        .candidate_id = "action_surface:candidate_priority_hint",
        .pack_id = pack_id,
        .pack_version = version,
    });
    defer result.manifest.deinit();
    defer allocator.free(result.root_abs_path);

    const catalog_path = try std.fs.path.join(allocator, &.{ result.root_abs_path, "abstractions", "abstractions.gabs" });
    defer allocator.free(catalog_path);
    const records = try abstractions.loadCatalogSnapshotFromPath(allocator, catalog_path);
    defer abstractions.deinitRecordSlice(records);
    try std.testing.expect(records.len > 0);
    try std.testing.expect(!records[0].valid_to_commit);
    try std.testing.expectEqual(abstractions.TrustClass.exploratory, records[0].trust_class);
    try std.testing.expect(records[0].reuse_score > 0 or records[0].quality_score > 0);
}

fn recordVerifierSuccessesForPackTest(allocator: std.mem.Allocator, paths: *const shards.Paths, candidate: []const u8, count: usize) !void {
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        var id_buf: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "verifier:success:case-{d}", .{idx});
        var artifact_buf: [64]u8 = undefined;
        const artifact = try std.fmt.bufPrint(&artifact_buf, "deep_path:{d}", .{idx});
        _ = try feedback.recordAndApply(allocator, paths, .{
            .id = id,
            .source = .verifier,
            .type = .success,
            .related_artifact = artifact,
            .related_intent = "refactor",
            .related_candidate = candidate,
            .outcome = "supported",
            .timestamp = "deterministic:test",
            .provenance = "test",
        });
    }
}
