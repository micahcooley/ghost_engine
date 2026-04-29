const std = @import("std");
const store = @import("knowledge_pack_store.zig");

const MAX_GUIDANCE_BYTES: usize = 512 * 1024;
const MAX_GUIDANCE_ENTRIES: usize = 256;
const MAX_ARRAY_ITEMS: usize = 128;
const MAX_STRING_BYTES: usize = 2048;

pub const IssueSeverity = enum {
    @"error",
    warning,
};

pub const ValidationIssue = struct {
    severity: IssueSeverity,
    code: []u8,
    path: []u8,
    message: []u8,

    pub fn deinit(self: *ValidationIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const GuidanceValidationReport = struct {
    allocator: std.mem.Allocator,
    pack_id: []u8,
    pack_version: []u8,
    manifest_path: []u8,
    guidance_path: ?[]u8,
    declared_guidance_path: bool,
    guidance_count: usize,
    error_count: usize,
    warning_count: usize,
    issues: []ValidationIssue,

    pub fn ok(self: *const GuidanceValidationReport) bool {
        return self.error_count == 0;
    }

    pub fn deinit(self: *GuidanceValidationReport) void {
        self.allocator.free(self.pack_id);
        self.allocator.free(self.pack_version);
        self.allocator.free(self.manifest_path);
        if (self.guidance_path) |path| self.allocator.free(path);
        for (self.issues) |*issue| issue.deinit(self.allocator);
        self.allocator.free(self.issues);
        self.* = undefined;
    }
};

pub const ValidationSummary = struct {
    allocator: std.mem.Allocator,
    reports: []GuidanceValidationReport,
    error_count: usize,
    warning_count: usize,

    pub fn ok(self: *const ValidationSummary) bool {
        return self.error_count == 0;
    }

    pub fn deinit(self: *ValidationSummary) void {
        for (self.reports) |*report| report.deinit();
        self.allocator.free(self.reports);
        self.* = undefined;
    }
};

const IssueBuilder = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ValidationIssue),
    errors: usize = 0,
    warnings: usize = 0,

    fn init(allocator: std.mem.Allocator) IssueBuilder {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(ValidationIssue).init(allocator),
        };
    }

    fn deinit(self: *IssueBuilder) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit();
    }

    fn add(self: *IssueBuilder, severity: IssueSeverity, code: []const u8, path: []const u8, message: []const u8) !void {
        switch (severity) {
            .@"error" => self.errors += 1,
            .warning => self.warnings += 1,
        }
        try self.items.append(.{
            .severity = severity,
            .code = try self.allocator.dupe(u8, code),
            .path = try self.allocator.dupe(u8, path),
            .message = try self.allocator.dupe(u8, message),
        });
    }

    fn toOwnedSlice(self: *IssueBuilder) ![]ValidationIssue {
        return self.items.toOwnedSlice();
    }
};

pub fn validateInstalledPack(allocator: std.mem.Allocator, pack_id: []const u8, pack_version: []const u8) !GuidanceValidationReport {
    var manifest = try store.loadManifest(allocator, pack_id, pack_version);
    defer manifest.deinit();
    const root = try store.packRootAbsPath(allocator, manifest.pack_id, manifest.pack_version);
    defer allocator.free(root);
    const manifest_path = try store.manifestAbsPath(allocator, manifest.pack_id, manifest.pack_version);
    defer allocator.free(manifest_path);
    return validateManifestGuidance(allocator, &manifest, root, manifest_path);
}

pub fn validateManifestPath(allocator: std.mem.Allocator, manifest_path_raw: []const u8) !GuidanceValidationReport {
    const manifest_path = try std.fs.path.resolve(allocator, &.{manifest_path_raw});
    defer allocator.free(manifest_path);
    var manifest = try store.loadManifestFromPath(allocator, manifest_path);
    defer manifest.deinit();
    const root = std.fs.path.dirname(manifest_path) orelse return error.InvalidKnowledgePackManifest;
    return validateManifestGuidance(allocator, &manifest, root, manifest_path);
}

pub fn validateMountedPacks(allocator: std.mem.Allocator, paths: anytype) !ValidationSummary {
    const mounts = try store.listResolvedMounts(allocator, paths);
    defer {
        for (mounts) |*mount| mount.deinit();
        allocator.free(mounts);
    }

    var reports = std.ArrayList(GuidanceValidationReport).init(allocator);
    errdefer {
        for (reports.items) |*report| report.deinit();
        reports.deinit();
    }
    var errors: usize = 0;
    var warnings: usize = 0;

    for (mounts) |*mount| {
        if (!mount.entry.enabled) continue;
        const report = try validateResolvedMount(allocator, mount);
        errors += report.error_count;
        warnings += report.warning_count;
        try reports.append(report);
    }

    return .{
        .allocator = allocator,
        .reports = try reports.toOwnedSlice(),
        .error_count = errors,
        .warning_count = warnings,
    };
}

pub fn validateResolvedMount(allocator: std.mem.Allocator, mount: *const store.ResolvedMount) !GuidanceValidationReport {
    return validateManifestGuidance(allocator, &mount.manifest, mount.root_abs_path, mount.manifest_abs_path);
}

pub fn validateManifestGuidance(
    allocator: std.mem.Allocator,
    manifest: *const store.Manifest,
    pack_root_abs_path: []const u8,
    manifest_abs_path: []const u8,
) !GuidanceValidationReport {
    var issues = IssueBuilder.init(allocator);
    errdefer issues.deinit();

    const guidance_rel = manifest.storage.autopsy_guidance_rel_path;
    var guidance_path: ?[]u8 = null;
    errdefer if (guidance_path) |path| allocator.free(path);
    defer if (guidance_path) |path| allocator.free(path);
    var guidance_count: usize = 0;

    if (guidance_rel) |rel_path| {
        guidance_path = std.fs.path.resolve(allocator, &.{ pack_root_abs_path, rel_path }) catch |err| blk: {
            try issues.add(.@"error", "guidance_path_invalid", "$.storage.autopsyGuidanceRelPath", @errorName(err));
            break :blk null;
        };
        if (guidance_path) |path| {
            if (!pathWithinRoot(pack_root_abs_path, path)) {
                try issues.add(.@"error", "guidance_path_outside_pack", "$.storage.autopsyGuidanceRelPath", "autopsy guidance path must stay inside the pack root");
            } else {
                guidance_count = try validateGuidanceFile(allocator, path, manifest.pack_id, manifest.pack_version, &issues);
            }
        }
    }

    return .{
        .allocator = allocator,
        .pack_id = try allocator.dupe(u8, manifest.pack_id),
        .pack_version = try allocator.dupe(u8, manifest.pack_version),
        .manifest_path = try allocator.dupe(u8, manifest_abs_path),
        .guidance_path = if (guidance_path) |path| try allocator.dupe(u8, path) else null,
        .declared_guidance_path = guidance_rel != null,
        .guidance_count = guidance_count,
        .error_count = issues.errors,
        .warning_count = issues.warnings,
        .issues = try issues.toOwnedSlice(),
    };
}

fn validateGuidanceFile(
    allocator: std.mem.Allocator,
    guidance_path: []const u8,
    manifest_pack_id: []const u8,
    manifest_pack_version: []const u8,
    issues: *IssueBuilder,
) !usize {
    const bytes = readFileAbsoluteAlloc(allocator, guidance_path, MAX_GUIDANCE_BYTES) catch |err| {
        const code = if (err == error.FileNotFound) "guidance_file_missing" else "guidance_file_read_failed";
        try issues.add(.@"error", code, "$.storage.autopsyGuidanceRelPath", "manifest declares autopsy guidance, but the file could not be read");
        return 0;
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try issues.add(.@"error", "guidance_json_malformed", "$", "autopsy guidance file must be valid JSON");
        return 0;
    };
    defer parsed.deinit();

    return validateGuidanceValue(allocator, parsed.value, manifest_pack_id, manifest_pack_version, issues);
}

pub fn validateGuidanceBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    manifest_pack_id: []const u8,
    manifest_pack_version: []const u8,
) !GuidanceValidationReport {
    var issues = IssueBuilder.init(allocator);
    errdefer issues.deinit();
    var guidance_count: usize = 0;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try issues.add(.@"error", "guidance_json_malformed", "$", "autopsy guidance file must be valid JSON");
        return .{
            .allocator = allocator,
            .pack_id = try allocator.dupe(u8, manifest_pack_id),
            .pack_version = try allocator.dupe(u8, manifest_pack_version),
            .manifest_path = try allocator.dupe(u8, "<memory>"),
            .guidance_path = null,
            .declared_guidance_path = true,
            .guidance_count = 0,
            .error_count = issues.errors,
            .warning_count = issues.warnings,
            .issues = try issues.toOwnedSlice(),
        };
    };
    defer parsed.deinit();
    guidance_count = try validateGuidanceValue(allocator, parsed.value, manifest_pack_id, manifest_pack_version, &issues);

    return .{
        .allocator = allocator,
        .pack_id = try allocator.dupe(u8, manifest_pack_id),
        .pack_version = try allocator.dupe(u8, manifest_pack_version),
        .manifest_path = try allocator.dupe(u8, "<memory>"),
        .guidance_path = null,
        .declared_guidance_path = true,
        .guidance_count = guidance_count,
        .error_count = issues.errors,
        .warning_count = issues.warnings,
        .issues = try issues.toOwnedSlice(),
    };
}

fn validateGuidanceValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    manifest_pack_id: []const u8,
    manifest_pack_version: []const u8,
    issues: *IssueBuilder,
) !usize {
    _ = manifest_pack_version;
    const array = switch (value) {
        .array => |arr| arr,
        .object => |obj| blk: {
            const nested = obj.get("packGuidance") orelse obj.get("pack_guidance") orelse {
                try issues.add(.@"error", "guidance_top_level_unsupported", "$", "guidance JSON must be an array or an object with packGuidance/pack_guidance array");
                return 0;
            };
            if (nested != .array) {
                try issues.add(.@"error", "guidance_top_level_unsupported", "$.packGuidance", "packGuidance/pack_guidance must be an array");
                return 0;
            }
            break :blk nested.array;
        },
        else => {
            try issues.add(.@"error", "guidance_top_level_unsupported", "$", "guidance JSON must be an array or an object with packGuidance/pack_guidance array");
            return 0;
        },
    };

    if (array.items.len > MAX_GUIDANCE_ENTRIES) {
        try issues.add(.@"error", "guidance_entry_count_exceeds_bound", "$", "guidance file has too many entries");
    }

    for (array.items, 0..) |item, idx| {
        var path_buf: [128]u8 = undefined;
        const entry_path = try std.fmt.bufPrint(&path_buf, "$[{d}]", .{idx});
        const obj = valueObject(item) orelse {
            try issues.add(.@"error", "guidance_entry_not_object", entry_path, "each guidance entry must be an object");
            continue;
        };
        try validateGuidanceEntry(allocator, obj, idx, manifest_pack_id, issues);
    }
    return array.items.len;
}

fn validateGuidanceEntry(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    idx: usize,
    manifest_pack_id: []const u8,
    issues: *IssueBuilder,
) !void {
    if (!hasUsableIdentity(obj, manifest_pack_id)) {
        try addEntryIssue(allocator, issues, .@"error", idx, "", "guidance_entry_missing_identity", "each guidance entry must have pack_id/packId, source_pack/sourcePack, source_id/sourceId, or a usable manifest pack identity");
    }

    if (obj.get("match")) |match_value| {
        const match_obj = valueObject(match_value) orelse {
            try addEntryIssue(allocator, issues, .@"error", idx, ".match", "match_not_object", "match must be an object when present");
            return;
        };
        try validateMatch(allocator, match_obj, idx, issues);
    }

    try validateGuidanceArray(allocator, obj, idx, "signals", "signals", issues, validateSignal);
    try validateGuidanceArray(allocator, obj, idx, "unknowns", "unknowns", issues, validateUnknown);
    try validateGuidanceArray(allocator, obj, idx, "risks", "risks", issues, validateRisk);
    try validateGuidanceArray(allocator, obj, idx, "candidate_actions", "candidateActions", issues, validateAction);
    try validateGuidanceArray(allocator, obj, idx, "check_candidates", "checkCandidates", issues, validateCheck);
    try validateGuidanceArray(allocator, obj, idx, "evidence_expectations", "evidenceExpectations", issues, validateEvidenceExpectation);

    if (obj.get("influence")) |influence_value| {
        const influence = valueObject(influence_value) orelse {
            try addEntryIssue(allocator, issues, .@"error", idx, ".influence", "influence_not_object", "influence must be an object when present");
            return;
        };
        if (getBoolAny(influence, &.{ "is_proof_authority", "isProofAuthority", "proof_authority", "proofAuthority", "is_proof", "isProof" }) orelse false) {
            try addEntryIssue(allocator, issues, .warning, idx, ".influence", "pack_influence_proof_authority_clamped", "pack influence cannot be proof authority; runtime finalization clamps this to false");
        }
        if (getBoolAny(influence, &.{ "non_authorizing", "nonAuthorizing" })) |value| {
            if (!value) try addEntryIssue(allocator, issues, .warning, idx, ".influence", "pack_influence_authorizing_clamped", "pack influence cannot authorize support; runtime finalization clamps this to non-authorizing");
        }
    }
    if (getBoolAny(obj, &.{ "is_proof_authority", "isProofAuthority", "proof_authority", "proofAuthority", "is_proof", "isProof" }) orelse false) {
        try addEntryIssue(allocator, issues, .warning, idx, "", "pack_influence_proof_authority_clamped", "pack guidance cannot be proof authority; runtime finalization clamps influence authority to false");
    }
}

fn validateMatch(allocator: std.mem.Allocator, obj: std.json.ObjectMap, idx: usize, issues: *IssueBuilder) !void {
    const fields = [_][]const u8{
        "intent_tags_any",
        "intentTagsAny",
        "intent_tags_all",
        "intentTagsAll",
        "context_keywords_any",
        "contextKeywordsAny",
        "context_keywords_all",
        "contextKeywordsAll",
        "artifact_kinds_any",
        "artifactKindsAny",
        "artifact_kinds_all",
        "artifactKindsAll",
        "situation_kinds_any",
        "situationKindsAny",
        "situation_kinds_all",
        "situationKindsAll",
        "required_context_fields",
        "requiredContextFields",
    };
    var total_items: usize = 0;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!containsName(&fields, entry.key_ptr.*)) {
            try addEntryIssue(allocator, issues, .warning, idx, ".match", "match_field_unknown", "unknown match field will not affect applicability");
            continue;
        }
        if (entry.value_ptr.* != .array) {
            try addEntryIssue(allocator, issues, .@"error", idx, ".match", "match_field_not_array", "match criteria fields must be string arrays");
            continue;
        }
        const arr = entry.value_ptr.array;
        if (arr.items.len > MAX_ARRAY_ITEMS) {
            try addEntryIssue(allocator, issues, .@"error", idx, ".match", "match_field_exceeds_bound", "match criteria array exceeds validator bound");
        }
        total_items += arr.items.len;
        for (arr.items) |item| {
            if (!validStringValue(item)) {
                try addEntryIssue(allocator, issues, .@"error", idx, ".match", "match_field_invalid_item", "match criteria arrays must contain non-empty bounded strings");
            }
        }
    }
    if (total_items > MAX_ARRAY_ITEMS) {
        try addEntryIssue(allocator, issues, .@"error", idx, ".match", "match_total_exceeds_bound", "combined match criteria exceed validator bound");
    }
}

fn validateGuidanceArray(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    idx: usize,
    snake: []const u8,
    camel: []const u8,
    issues: *IssueBuilder,
    comptime validateItem: fn (std.mem.Allocator, std.json.ObjectMap, usize, usize, *IssueBuilder) anyerror!void,
) !void {
    const value = obj.get(snake) orelse obj.get(camel) orelse return;
    if (value != .array) {
        try addEntryIssue(allocator, issues, .@"error", idx, snake, "guidance_section_not_array", "guidance sections must be arrays");
        return;
    }
    if (value.array.items.len > MAX_ARRAY_ITEMS) {
        try addEntryIssue(allocator, issues, .@"error", idx, snake, "guidance_section_exceeds_bound", "guidance section exceeds validator bound");
    }
    for (value.array.items, 0..) |item, item_idx| {
        const item_obj = valueObject(item) orelse {
            try addEntryIssue(allocator, issues, .@"error", idx, snake, "guidance_section_item_not_object", "guidance section items must be objects");
            continue;
        };
        try validateItem(allocator, item_obj, idx, item_idx, issues);
    }
}

fn validateSignal(allocator: std.mem.Allocator, obj: std.json.ObjectMap, entry_idx: usize, item_idx: usize, issues: *IssueBuilder) !void {
    try requireString(allocator, obj, entry_idx, item_idx, "signals", "name", "name", "signal_missing_name", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "signals", "kind", "kind", "signal_missing_kind", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "signals", "reason", "reason", "signal_missing_reason", issues);
    try optionalString(allocator, obj, entry_idx, item_idx, "signals", "confidence", "confidence", "signal_invalid_confidence", issues);
}

fn validateUnknown(allocator: std.mem.Allocator, obj: std.json.ObjectMap, entry_idx: usize, item_idx: usize, issues: *IssueBuilder) !void {
    try requireString(allocator, obj, entry_idx, item_idx, "unknowns", "name", "name", "unknown_missing_name", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "unknowns", "importance", "importance", "unknown_missing_importance", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "unknowns", "reason", "reason", "unknown_missing_reason", issues);
    if (getBoolAny(obj, &.{ "is_negative_evidence", "isNegativeEvidence" }) orelse false) {
        try addItemIssue(allocator, issues, .warning, entry_idx, item_idx, "unknowns", "unknown_negative_evidence_clamped", "missing context cannot be negative evidence; runtime finalization clamps this to false");
    }
}

fn validateRisk(allocator: std.mem.Allocator, obj: std.json.ObjectMap, entry_idx: usize, item_idx: usize, issues: *IssueBuilder) !void {
    if (!hasStringAny(obj, &.{ "risk_kind", "riskKind", "name" })) {
        try addItemIssue(allocator, issues, .@"error", entry_idx, item_idx, "risks", "risk_missing_kind", "risk must have risk_kind/riskKind or name");
    }
    try requireString(allocator, obj, entry_idx, item_idx, "risks", "reason", "reason", "risk_missing_reason", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "risks", "suggested_caution", "suggestedCaution", "risk_missing_caution", issues);
    if (getBoolAny(obj, &.{ "non_authorizing", "nonAuthorizing" })) |value| {
        if (!value) try addItemIssue(allocator, issues, .warning, entry_idx, item_idx, "risks", "risk_authorizing_clamped", "risk surfaces cannot authorize support; runtime finalization clamps this to non-authorizing");
    }
}

fn validateAction(allocator: std.mem.Allocator, obj: std.json.ObjectMap, entry_idx: usize, item_idx: usize, issues: *IssueBuilder) !void {
    try requireString(allocator, obj, entry_idx, item_idx, "candidate_actions", "id", "id", "action_missing_id", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "candidate_actions", "summary", "summary", "action_missing_summary", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "candidate_actions", "action_type", "actionType", "action_missing_type", issues);
    if (getBoolAny(obj, &.{ "non_authorizing", "nonAuthorizing" })) |value| {
        if (!value) try addItemIssue(allocator, issues, .warning, entry_idx, item_idx, "candidate_actions", "action_authorizing_clamped", "candidate actions cannot authorize execution or support; runtime finalization clamps this to non-authorizing");
    }
    if (getBoolAny(obj, &.{ "requires_user_confirmation", "requiresUserConfirmation" })) |value| {
        if (!value) try addItemIssue(allocator, issues, .warning, entry_idx, item_idx, "candidate_actions", "action_confirmation_required", "candidate actions must require user confirmation before any external execution");
    }
}

fn validateCheck(allocator: std.mem.Allocator, obj: std.json.ObjectMap, entry_idx: usize, item_idx: usize, issues: *IssueBuilder) !void {
    try requireString(allocator, obj, entry_idx, item_idx, "check_candidates", "id", "id", "check_missing_id", issues);
    if (!hasStringAny(obj, &.{ "summary", "purpose" })) {
        try addItemIssue(allocator, issues, .@"error", entry_idx, item_idx, "check_candidates", "check_missing_purpose", "check candidates must have summary or purpose");
    }
    if (!hasStringAny(obj, &.{ "check_kind", "checkKind", "check_type", "checkType" })) {
        try addItemIssue(allocator, issues, .@"error", entry_idx, item_idx, "check_candidates", "check_missing_type", "check candidates must have check_kind/checkKind or check_type/checkType");
    }
    if (!hasStringAny(obj, &.{ "why_candidate_exists", "whyCandidateExists" })) {
        try addItemIssue(allocator, issues, .@"error", entry_idx, item_idx, "check_candidates", "check_missing_why", "check candidates must explain why the candidate exists");
    }
    if (getBoolAny(obj, &.{ "executes_by_default", "executesByDefault" }) orelse false) {
        try addItemIssue(allocator, issues, .warning, entry_idx, item_idx, "check_candidates", "check_executes_by_default_clamped", "check candidates cannot execute by default; runtime finalization clamps this to false");
    }
    if (getBoolAny(obj, &.{ "non_authorizing", "nonAuthorizing" })) |value| {
        if (!value) try addItemIssue(allocator, issues, .warning, entry_idx, item_idx, "check_candidates", "check_authorizing_clamped", "check candidates cannot authorize support; runtime finalization clamps this to non-authorizing");
    }
}

fn validateEvidenceExpectation(allocator: std.mem.Allocator, obj: std.json.ObjectMap, entry_idx: usize, item_idx: usize, issues: *IssueBuilder) !void {
    try requireString(allocator, obj, entry_idx, item_idx, "evidence_expectations", "id", "id", "evidence_missing_id", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "evidence_expectations", "summary", "summary", "evidence_missing_summary", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "evidence_expectations", "expectation_kind", "expectationKind", "evidence_missing_kind", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "evidence_expectations", "expected_signal", "expectedSignal", "evidence_missing_expected_signal", issues);
    try requireString(allocator, obj, entry_idx, item_idx, "evidence_expectations", "reason", "reason", "evidence_missing_reason", issues);
}

fn requireString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    entry_idx: usize,
    item_idx: usize,
    section: []const u8,
    snake: []const u8,
    camel: []const u8,
    code: []const u8,
    issues: *IssueBuilder,
) !void {
    const value = obj.get(snake) orelse obj.get(camel) orelse {
        try addItemIssue(allocator, issues, .@"error", entry_idx, item_idx, section, code, "required string field is missing");
        return;
    };
    if (!validStringValue(value)) {
        try addItemIssue(allocator, issues, .@"error", entry_idx, item_idx, section, code, "required field must be a non-empty bounded string");
    }
}

fn optionalString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    entry_idx: usize,
    item_idx: usize,
    section: []const u8,
    snake: []const u8,
    camel: []const u8,
    code: []const u8,
    issues: *IssueBuilder,
) !void {
    const value = obj.get(snake) orelse obj.get(camel) orelse return;
    if (!validStringValue(value)) {
        try addItemIssue(allocator, issues, .@"error", entry_idx, item_idx, section, code, "optional string field must be a non-empty bounded string when present");
    }
}

fn hasUsableIdentity(obj: std.json.ObjectMap, manifest_pack_id: []const u8) bool {
    if (manifest_pack_id.len != 0) return true;
    return hasStringAny(obj, &.{ "pack_id", "packId", "source_pack", "sourcePack", "source_id", "sourceId", "source", "sourceKind" });
}

fn hasStringAny(obj: std.json.ObjectMap, names: []const []const u8) bool {
    for (names) |name| {
        if (obj.get(name)) |value| {
            if (validStringValue(value)) return true;
        }
    }
    return false;
}

fn getBoolAny(obj: std.json.ObjectMap, names: []const []const u8) ?bool {
    for (names) |name| {
        if (obj.get(name)) |value| {
            if (value == .bool) return value.bool;
        }
    }
    return null;
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}

fn validStringValue(value: std.json.Value) bool {
    if (value != .string) return false;
    const trimmed = std.mem.trim(u8, value.string, " \r\n\t");
    return trimmed.len > 0 and trimmed.len <= MAX_STRING_BYTES;
}

fn containsName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn addEntryIssue(
    allocator: std.mem.Allocator,
    issues: *IssueBuilder,
    severity: IssueSeverity,
    entry_idx: usize,
    suffix: []const u8,
    code: []const u8,
    message: []const u8,
) !void {
    const separator = if (suffix.len != 0 and suffix[0] != '.' and suffix[0] != '[') "." else "";
    const path = try std.fmt.allocPrint(allocator, "$[{d}]{s}{s}", .{ entry_idx, separator, suffix });
    defer allocator.free(path);
    try issues.add(severity, code, path, message);
}

fn addItemIssue(
    allocator: std.mem.Allocator,
    issues: *IssueBuilder,
    severity: IssueSeverity,
    entry_idx: usize,
    item_idx: usize,
    section: []const u8,
    code: []const u8,
    message: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "$[{d}].{s}[{d}]", .{ entry_idx, section, item_idx });
    defer allocator.free(path);
    try issues.add(severity, code, path, message);
}

fn readFileAbsoluteAlloc(allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn pathWithinRoot(root_abs_path: []const u8, candidate_abs_path: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate_abs_path, root_abs_path)) return false;
    if (candidate_abs_path.len == root_abs_path.len) return true;
    if (root_abs_path.len == 0) return false;
    return std.fs.path.isSep(candidate_abs_path[root_abs_path.len]);
}

const valid_guidance =
    \\{"packGuidance":[{"pack_id":"pack-a","match":{"intent_tags_any":["planning"]},"signals":[{"name":"sig","kind":"generic_signal","confidence":"medium","reason":"matched"}],"unknowns":[{"name":"gap","importance":"medium","reason":"missing"}],"risks":[{"risk_kind":"risk","reason":"risk exists","suggested_caution":"check first"}],"candidate_actions":[{"id":"act","summary":"candidate only","action_type":"generic_action"}],"check_candidates":[{"id":"chk","summary":"check only","check_kind":"soft","why_candidate_exists":"needs evidence"}],"evidence_expectations":[{"id":"ev","summary":"evidence required","expectation_kind":"soft","expected_signal":"sig","reason":"before claims"}]}]}
;

test "valid persisted autopsy guidance passes validation" {
    const allocator = std.testing.allocator;
    var report = try validateGuidanceBytes(allocator, valid_guidance, "pack-a", "v1");
    defer report.deinit();
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.guidance_count);
}

test "malformed JSON and unsupported shape fail validation without crashing" {
    const allocator = std.testing.allocator;
    var malformed = try validateGuidanceBytes(allocator, "{not-json", "pack-a", "v1");
    defer malformed.deinit();
    try std.testing.expect(!malformed.ok());
    try std.testing.expectEqualStrings("guidance_json_malformed", malformed.issues[0].code);

    var unsupported = try validateGuidanceBytes(allocator, "{\"guidance\":[]}", "pack-a", "v1");
    defer unsupported.deinit();
    try std.testing.expect(!unsupported.ok());
    try std.testing.expectEqualStrings("guidance_top_level_unsupported", unsupported.issues[0].code);
}

test "missing required fields produce validation errors" {
    const allocator = std.testing.allocator;
    var report = try validateGuidanceBytes(allocator, "{\"packGuidance\":[{\"pack_id\":\"pack-a\",\"signals\":[{}]}]}", "pack-a", "v1");
    defer report.deinit();
    try std.testing.expect(!report.ok());
    try std.testing.expect(report.error_count >= 3);
}

test "unsafe candidate check influence fields produce warnings" {
    const allocator = std.testing.allocator;
    const body =
        \\{"packGuidance":[{"pack_id":"pack-a","is_proof_authority":true,"unknowns":[{"name":"gap","importance":"high","reason":"missing","is_negative_evidence":true}],"risks":[{"risk_kind":"risk","reason":"risk","suggested_caution":"caution","non_authorizing":false}],"candidate_actions":[{"id":"act","summary":"act","action_type":"command","non_authorizing":false,"requires_user_confirmation":false}],"check_candidates":[{"id":"chk","summary":"chk","check_kind":"hard","why_candidate_exists":"evidence","executes_by_default":true,"non_authorizing":false}],"influence":{"isProofAuthority":true,"nonAuthorizing":false}}]}
    ;
    var report = try validateGuidanceBytes(allocator, body, "pack-a", "v1");
    defer report.deinit();
    try std.testing.expect(report.ok());
    try std.testing.expect(report.warning_count >= 7);
}

test "non-matching guidance can still be valid" {
    const allocator = std.testing.allocator;
    const body =
        \\{"packGuidance":[{"pack_id":"pack-a","match":{"intent_tags_any":["never-matches"]},"signals":[{"name":"sig","kind":"generic_signal","reason":"valid guidance","confidence":"low"}]}]}
    ;
    var report = try validateGuidanceBytes(allocator, body, "pack-a", "v1");
    defer report.deinit();
    try std.testing.expect(report.ok());
}

test "missing guidance file declared by manifest fails validation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var manifest = store.Manifest{
        .allocator = allocator,
        .schema_version = try allocator.dupe(u8, store.PACK_SCHEMA_VERSION),
        .pack_id = try allocator.dupe(u8, "pack-a"),
        .pack_version = try allocator.dupe(u8, "v1"),
        .domain_family = try allocator.dupe(u8, "context"),
        .trust_class = try allocator.dupe(u8, "project"),
        .compatibility = .{
            .engine_version = try allocator.dupe(u8, "test"),
            .mount_schema = try allocator.dupe(u8, store.MOUNT_SCHEMA_VERSION),
        },
        .storage = .{
            .corpus_manifest_rel_path = try allocator.dupe(u8, "corpus/manifest.json"),
            .corpus_files_rel_path = try allocator.dupe(u8, "corpus"),
            .abstraction_catalog_rel_path = try allocator.dupe(u8, "abstractions/abstractions.gabs"),
            .reuse_catalog_rel_path = try allocator.dupe(u8, "abstractions/reuse.gabr"),
            .lineage_state_rel_path = try allocator.dupe(u8, "abstractions/lineage.gabs"),
            .influence_manifest_rel_path = try allocator.dupe(u8, "influence.json"),
            .autopsy_guidance_rel_path = try allocator.dupe(u8, "autopsy/missing.json"),
        },
        .provenance = .{
            .pack_lineage_id = try allocator.dupe(u8, "pack:pack-a@v1"),
            .source_kind = try allocator.dupe(u8, "test"),
            .source_id = try allocator.dupe(u8, "test"),
            .source_state = .staged,
            .freshness_state = .active,
            .source_summary = try allocator.dupe(u8, "test"),
            .source_lineage_summary = try allocator.dupe(u8, "test"),
        },
        .content = .{},
    };
    defer manifest.deinit();

    var report = try validateManifestGuidance(allocator, &manifest, root, "/tmp/manifest.json");
    defer report.deinit();
    try std.testing.expect(!report.ok());
    try std.testing.expectEqualStrings("guidance_file_missing", report.issues[0].code);
}

test "validator does not mutate manifest or guidance files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("autopsy");
    try tmp.dir.writeFile(.{ .sub_path = "autopsy/guidance.json", .data = valid_guidance });
    const manifest_body =
        \\{"schemaVersion":"ghost_knowledge_pack_v1","packId":"pack-a","packVersion":"v1","domainFamily":"context","trustClass":"project","compatibility":{"engineVersion":"test","linuxFirst":true,"deterministicOnly":true,"mountSchema":"ghost_knowledge_pack_mounts_v1"},"storage":{"corpusManifestRelPath":"corpus/manifest.json","corpusFilesRelPath":"corpus","abstractionCatalogRelPath":"abstractions/abstractions.gabs","reuseCatalogRelPath":"abstractions/reuse.gabr","lineageStateRelPath":"abstractions/lineage.gabs","influenceManifestRelPath":"influence.json","autopsyGuidanceRelPath":"autopsy/guidance.json"},"provenance":{"packLineageId":"pack:pack-a@v1","sourceKind":"test","sourceId":"test","sourceState":"staged","freshnessState":"active","sourceSummary":"test","sourceLineageSummary":"test"},"content":{"corpusItemCount":0,"conceptCount":0,"corpusHash":0,"abstractionHash":0,"reuseHash":0,"lineageHash":0,"corpusPreview":[],"conceptPreview":[]}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "manifest.json", .data = manifest_body });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "manifest.json" });
    defer allocator.free(manifest_path);
    const guidance_path = try std.fs.path.join(allocator, &.{ root, "autopsy/guidance.json" });
    defer allocator.free(guidance_path);

    const before_manifest = try readFileAbsoluteAlloc(allocator, manifest_path, MAX_GUIDANCE_BYTES);
    defer allocator.free(before_manifest);
    const before_guidance = try readFileAbsoluteAlloc(allocator, guidance_path, MAX_GUIDANCE_BYTES);
    defer allocator.free(before_guidance);

    var report = try validateManifestPath(allocator, manifest_path);
    defer report.deinit();
    try std.testing.expect(report.ok());

    const after_manifest = try readFileAbsoluteAlloc(allocator, manifest_path, MAX_GUIDANCE_BYTES);
    defer allocator.free(after_manifest);
    const after_guidance = try readFileAbsoluteAlloc(allocator, guidance_path, MAX_GUIDANCE_BYTES);
    defer allocator.free(after_guidance);
    try std.testing.expectEqualStrings(before_manifest, after_manifest);
    try std.testing.expectEqualStrings(before_guidance, after_guidance);
}
