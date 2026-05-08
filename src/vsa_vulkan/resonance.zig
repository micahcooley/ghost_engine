const std = @import("std");

pub const SPO_DIRECT_MATCH_BONUS: u32 = 4200;
pub const SPO_PARTIAL_MATCH_BONUS: u32 = 900;
pub const SPO_INVERSE_MATCH_PENALTY_PER_MILLE: u32 = 125;
pub const FRAME_ROLE_DIMS: usize = 8;

const RoleSalt = enum(u64) {
    subject = 0x9E37_79B1_85EB_CA87,
    predicate = 0xC2B2_AE3D_27D4_EB4F,
    object = 0x1656_67B1_9E37_79F9,
    frame = 0xA24B_AED4_963E_E407,
    role = 0x9FB2_1C65_1E98_DF25,
};

pub const FrameKind = enum(u8) {
    none,
    relation,
    commerce,
    breakage,
    containment,
    storage,
    control,
    code_inheritance,
    analogy,
};

pub const FrameRole = enum(usize) {
    actor = 0,
    counterparty = 1,
    object = 2,
    instrument = 3,
    source = 4,
    target = 5,
    property = 6,
    result = 7,
};

pub const RoleBoundVector = struct {
    subject: u64 = 0,
    predicate: u64 = 0,
    object: u64 = 0,

    pub fn bindForward(self: RoleBoundVector) u64 {
        return hashRoleBound(self.subject, self.predicate, self.object);
    }

    pub fn bindInverse(self: RoleBoundVector) u64 {
        return hashRoleBound(self.object, self.predicate, self.subject);
    }
};

pub const SemanticFrameVector = struct {
    subject_hash: u64 = 0,
    predicate_hash: u64 = 0,
    object_hash: u64 = 0,
    frame_hash: u64 = 0,
    structure_hash: u64 = 0,
    role_hashes: [FRAME_ROLE_DIMS]u64 = [_]u64{0} ** FRAME_ROLE_DIMS,
    forward_hash: u64 = 0,
    inverse_hash: u64 = 0,
    frame_kind: FrameKind = .none,
    valid: bool = false,

    pub fn directMatch(self: SemanticFrameVector, other: SemanticFrameVector) bool {
        return self.valid and other.valid and self.forward_hash != 0 and self.forward_hash == other.forward_hash;
    }

    pub fn inverseMatch(self: SemanticFrameVector, other: SemanticFrameVector) bool {
        return self.valid and other.valid and self.forward_hash != 0 and self.forward_hash == other.inverse_hash;
    }

    pub fn role(self: SemanticFrameVector, slot: FrameRole) u64 {
        return self.role_hashes[@intFromEnum(slot)];
    }
};

// Compatibility name for the manifest and daemon fields that still store the
// two 64-bit relation hashes. New extraction below is frame-based.
pub const SpoVector = SemanticFrameVector;

const FrameToken = struct {
    text: []const u8,
    hash: u64,
    predicate_hash: u64 = 0,
};

pub fn extractFrameVector(text: []const u8) SemanticFrameVector {
    var tokens: [96]FrameToken = undefined;
    const count = tokenizeFrame(text, &tokens);
    if (count == 0) return .{};
    const slice = tokens[0..count];
    if (extractSpecializedFrame(slice)) |frame| return frame;
    return extractRelationFrame(slice);
}

pub fn extractSpoVector(text: []const u8) SpoVector {
    return extractFrameVector(text);
}

pub fn relationScorePerMille(query: SemanticFrameVector, candidate: SemanticFrameVector) u16 {
    if (!query.valid or !candidate.valid) return 0;
    if (query.directMatch(candidate)) return 1000;
    if (query.inverseMatch(candidate)) return 0;

    const graph_score = graphIsomorphismScorePerMille(query, candidate);
    if (graph_score != 0) return graph_score;

    var score: u16 = 0;
    if (query.predicate_hash != 0 and query.predicate_hash == candidate.predicate_hash) score += 360;
    if (query.subject_hash != 0 and query.subject_hash == candidate.subject_hash) score += 320;
    if (query.object_hash != 0 and query.object_hash == candidate.object_hash) score += 320;
    return score;
}

pub fn relationPenaltyPerMille(query: SemanticFrameVector, candidate: SemanticFrameVector) u16 {
    if (!query.valid or !candidate.valid) return 0;
    if (query.inverseMatch(candidate)) return 875;
    if (query.frame_kind != .none and query.frame_kind == candidate.frame_kind and query.role(.actor) == candidate.role(.object) and query.role(.object) == candidate.role(.actor)) return 700;
    return 0;
}

pub fn graphIsomorphismScorePerMille(query: SemanticFrameVector, candidate: SemanticFrameVector) u16 {
    if (!query.valid or !candidate.valid) return 0;
    var score: u16 = 0;
    if (query.frame_kind != .none and query.frame_kind == candidate.frame_kind) score += 280;
    if (frameFamiliesCompatible(query.frame_kind, candidate.frame_kind)) score += 300;
    if (query.structure_hash != 0 and query.structure_hash == candidate.structure_hash) score += 260;

    var matched_roles: u16 = 0;
    var query_roles: u16 = 0;
    var occupied_matches: u16 = 0;
    for (query.role_hashes, 0..) |role_hash, idx| {
        if (role_hash == 0) continue;
        query_roles += 1;
        if (candidate.role_hashes[idx] != 0) occupied_matches += 1;
        if (role_hash == candidate.role_hashes[idx]) matched_roles += 1;
    }
    if (query_roles != 0) {
        score += @intCast((@as(u32, occupied_matches) * 220) / query_roles);
        score += @intCast((@as(u32, matched_roles) * 240) / query_roles);
    }

    if (score > 1000) return 1000;
    return score;
}

fn frameFamiliesCompatible(lhs: FrameKind, rhs: FrameKind) bool {
    if (lhs == .none or rhs == .none) return false;
    if ((lhs == .storage and rhs == .containment) or (lhs == .containment and rhs == .storage)) return true;
    if ((lhs == .control and rhs == .analogy) or (lhs == .analogy and rhs == .control)) return true;
    return false;
}

fn tokenizeFrame(text: []const u8, out: *[96]FrameToken) usize {
    var count: usize = 0;
    var start: ?usize = null;
    var idx: usize = 0;
    while (idx <= text.len) : (idx += 1) {
        const at_end = idx == text.len;
        const byte = if (at_end) 0 else text[idx];
        if (!at_end and (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '$')) {
            if (start == null) start = idx;
            continue;
        }
        if (start) |s| {
            const token = std.mem.trim(u8, text[s..idx], "_-");
            if (token.len >= 1 and count < out.len and !isFrameStopToken(token)) {
                out[count] = .{
                    .text = token,
                    .hash = hashLowerAsciiToken(token),
                    .predicate_hash = normalizedPredicateHash(token),
                };
                count += 1;
            }
            start = null;
        }
    }
    return count;
}

fn extractSpecializedFrame(tokens: []const FrameToken) ?SemanticFrameVector {
    if (commerceVerbIndex(tokens)) |verb_idx| return commerceFrame(tokens, verb_idx);
    if (breakageCueIndex(tokens)) |verb_idx| return breakageFrame(tokens, verb_idx);
    if (codeInheritanceIndex(tokens)) |idx| return codeInheritanceFrame(tokens, idx);
    if (analogyCueIndex(tokens)) |idx| return analogyFrame(tokens, idx);
    if (storageCueIndex(tokens)) |idx| return storageFrame(tokens, idx);
    if (containmentCueIndex(tokens)) |idx| return containmentFrame(tokens, idx);
    return null;
}

fn extractRelationFrame(tokens: []const FrameToken) SemanticFrameVector {
    for (tokens, 0..) |token, token_idx| {
        if (token.predicate_hash == 0) continue;
        const subject_idx = previousConcept(tokens, token_idx) orelse continue;
        const object_idx = nextConcept(tokens, token_idx + 1) orelse continue;
        const subject = tokens[subject_idx];
        const object = tokens[object_idx];
        if (subject.hash == object.hash) continue;
        var roles = [_]u64{0} ** FRAME_ROLE_DIMS;
        roles[@intFromEnum(FrameRole.actor)] = subject.hash;
        roles[@intFromEnum(FrameRole.object)] = object.hash;
        roles[@intFromEnum(FrameRole.property)] = token.predicate_hash;
        return buildFrame(.relation, token.predicate_hash, roles, subject.hash, token.predicate_hash, object.hash);
    }
    return .{};
}

fn commerceFrame(tokens: []const FrameToken, verb_idx: usize) SemanticFrameVector {
    var roles = [_]u64{0} ** FRAME_ROLE_DIMS;
    roles[@intFromEnum(FrameRole.actor)] = pronounOrPreviousConcept(tokens, verb_idx) orelse hashPredicateName("buyer");
    roles[@intFromEnum(FrameRole.object)] = commerceGoods(tokens, verb_idx) orelse hashPredicateName("goods");
    roles[@intFromEnum(FrameRole.instrument)] = currencyToken(tokens) orelse hashPredicateName("currency");
    roles[@intFromEnum(FrameRole.counterparty)] = conceptAfterMarker(tokens, "from") orelse 0;
    return buildFrame(.commerce, hashPredicateName("commerce"), roles, roles[@intFromEnum(FrameRole.actor)], hashPredicateName("commerce"), roles[@intFromEnum(FrameRole.object)]);
}

fn breakageFrame(tokens: []const FrameToken, cue_idx: usize) SemanticFrameVector {
    var roles = [_]u64{0} ** FRAME_ROLE_DIMS;
    roles[@intFromEnum(FrameRole.actor)] = pronounOrPreviousConcept(tokens, cue_idx) orelse 0;
    roles[@intFromEnum(FrameRole.object)] = firstTokenHash(tokens, &.{ "glass", "cup", "plate", "window", "phone", "screen", "bottle" }) orelse nextConceptHash(tokens, cue_idx + 1) orelse hashPredicateName("fragile_object");
    roles[@intFromEnum(FrameRole.target)] = firstTokenHash(tokens, &.{ "concrete", "floor", "pavement", "tile", "ground", "stone" }) orelse 0;
    roles[@intFromEnum(FrameRole.result)] = hashPredicateName("likely_broken");
    return buildFrame(.breakage, hashPredicateName("impact_breakage"), roles, roles[@intFromEnum(FrameRole.actor)], hashPredicateName("impact_breakage"), roles[@intFromEnum(FrameRole.object)]);
}

fn codeInheritanceFrame(tokens: []const FrameToken, cue_idx: usize) SemanticFrameVector {
    var roles = [_]u64{0} ** FRAME_ROLE_DIMS;
    roles[@intFromEnum(FrameRole.object)] = previousConceptHash(tokens, cue_idx) orelse hashPredicateName("class");
    roles[@intFromEnum(FrameRole.target)] = nextConceptHash(tokens, cue_idx + 1) orelse hashPredicateName("base_class");
    roles[@intFromEnum(FrameRole.property)] = hashPredicateName("inherits");
    return buildFrame(.code_inheritance, hashPredicateName("code_inheritance"), roles, roles[@intFromEnum(FrameRole.object)], hashPredicateName("inherits"), roles[@intFromEnum(FrameRole.target)]);
}

fn analogyFrame(tokens: []const FrameToken, cue_idx: usize) SemanticFrameVector {
    var roles = [_]u64{0} ** FRAME_ROLE_DIMS;
    roles[@intFromEnum(FrameRole.source)] = nextConceptHash(tokens, cue_idx + 1) orelse firstTokenHash(tokens, &.{ "bucket", "container", "brain" }) orelse 0;
    roles[@intFromEnum(FrameRole.target)] = firstTokenHash(tokens, &.{ "variable", "cpu", "processor", "memory" }) orelse previousConceptHash(tokens, cue_idx) orelse 0;
    roles[@intFromEnum(FrameRole.property)] = analogyPropertyHash(tokens);
    return buildFrame(.analogy, hashPredicateName("analogy"), roles, roles[@intFromEnum(FrameRole.source)], hashPredicateName("analogy"), roles[@intFromEnum(FrameRole.target)]);
}

fn storageFrame(tokens: []const FrameToken, cue_idx: usize) SemanticFrameVector {
    var roles = [_]u64{0} ** FRAME_ROLE_DIMS;
    roles[@intFromEnum(FrameRole.actor)] = previousConceptHash(tokens, cue_idx) orelse firstTokenHash(tokens, &.{ "variable", "memory", "bucket", "container" }) orelse 0;
    roles[@intFromEnum(FrameRole.object)] = nextConceptHash(tokens, cue_idx + 1) orelse firstTokenHash(tokens, &.{ "data", "value", "values" }) orelse hashPredicateName("value");
    roles[@intFromEnum(FrameRole.property)] = hashPredicateName("storage");
    return buildFrame(.storage, hashPredicateName("storage"), roles, roles[@intFromEnum(FrameRole.actor)], hashPredicateName("store"), roles[@intFromEnum(FrameRole.object)]);
}

fn containmentFrame(tokens: []const FrameToken, cue_idx: usize) SemanticFrameVector {
    var roles = [_]u64{0} ** FRAME_ROLE_DIMS;
    roles[@intFromEnum(FrameRole.actor)] = previousConceptHash(tokens, cue_idx) orelse firstTokenHash(tokens, &.{ "bucket", "container", "variable" }) orelse 0;
    roles[@intFromEnum(FrameRole.object)] = nextConceptHash(tokens, cue_idx + 1) orelse firstTokenHash(tokens, &.{ "data", "value", "water", "thing" }) orelse hashPredicateName("contained_value");
    roles[@intFromEnum(FrameRole.property)] = hashPredicateName("containment");
    return buildFrame(.containment, hashPredicateName("containment"), roles, roles[@intFromEnum(FrameRole.actor)], hashPredicateName("contain"), roles[@intFromEnum(FrameRole.object)]);
}

fn buildFrame(kind: FrameKind, predicate: u64, roles: [FRAME_ROLE_DIMS]u64, subject_hash: u64, predicate_hash: u64, object_hash: u64) SemanticFrameVector {
    const frame_hash = hashFrameKind(kind, predicate);
    const structure_hash = hashFrameStructure(kind, roles);
    const forward = hashFrameBound(frame_hash, roles, false);
    return .{
        .subject_hash = subject_hash,
        .predicate_hash = predicate_hash,
        .object_hash = object_hash,
        .frame_hash = frame_hash,
        .structure_hash = structure_hash,
        .role_hashes = roles,
        .forward_hash = forward,
        .inverse_hash = hashFrameBound(frame_hash, roles, true),
        .frame_kind = kind,
        .valid = forward != 0,
    };
}

fn hashFrameKind(kind: FrameKind, predicate: u64) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    updateHashU64(&hasher, @intFromEnum(RoleSalt.frame));
    updateHashU64(&hasher, @intFromEnum(kind));
    updateHashU64(&hasher, predicate);
    return hasher.final();
}

fn hashFrameStructure(kind: FrameKind, roles: [FRAME_ROLE_DIMS]u64) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    updateHashU64(&hasher, @intFromEnum(RoleSalt.frame));
    updateHashU64(&hasher, @intFromEnum(kind));
    for (roles, 0..) |role_hash, idx| {
        if (role_hash == 0) continue;
        updateHashU64(&hasher, @intFromEnum(RoleSalt.role));
        updateHashU64(&hasher, idx);
    }
    return hasher.final();
}

fn hashFrameBound(frame_hash: u64, roles: [FRAME_ROLE_DIMS]u64, inverse: bool) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    updateHashU64(&hasher, frame_hash);
    if (inverse) {
        updateRoleHash(&hasher, .actor, roles[@intFromEnum(FrameRole.object)]);
        updateRoleHash(&hasher, .object, roles[@intFromEnum(FrameRole.actor)]);
    } else {
        updateRoleHash(&hasher, .actor, roles[@intFromEnum(FrameRole.actor)]);
        updateRoleHash(&hasher, .object, roles[@intFromEnum(FrameRole.object)]);
    }
    updateRoleHash(&hasher, .counterparty, roles[@intFromEnum(FrameRole.counterparty)]);
    updateRoleHash(&hasher, .instrument, roles[@intFromEnum(FrameRole.instrument)]);
    updateRoleHash(&hasher, .source, roles[@intFromEnum(FrameRole.source)]);
    updateRoleHash(&hasher, .target, roles[@intFromEnum(FrameRole.target)]);
    updateRoleHash(&hasher, .property, roles[@intFromEnum(FrameRole.property)]);
    updateRoleHash(&hasher, .result, roles[@intFromEnum(FrameRole.result)]);
    return hasher.final();
}

fn updateRoleHash(hasher: *std.hash.Fnv1a_64, slot: FrameRole, role_hash: u64) void {
    if (role_hash == 0) return;
    updateHashU64(hasher, @intFromEnum(RoleSalt.role));
    updateHashU64(hasher, @intFromEnum(slot));
    updateHashU64(hasher, role_hash);
}

fn previousConcept(tokens: []const FrameToken, predicate_idx: usize) ?usize {
    if (predicate_idx == 0) return null;
    var idx = predicate_idx;
    while (idx > 0) {
        idx -= 1;
        if (tokens[idx].predicate_hash == 0 and !isConceptStopToken(tokens[idx].text)) return idx;
    }
    return null;
}

fn nextConcept(tokens: []const FrameToken, start_idx: usize) ?usize {
    var idx = start_idx;
    while (idx < tokens.len) : (idx += 1) {
        if (tokens[idx].predicate_hash == 0 and !isConceptStopToken(tokens[idx].text)) return idx;
    }
    return null;
}

fn previousConceptHash(tokens: []const FrameToken, predicate_idx: usize) ?u64 {
    const idx = previousConcept(tokens, predicate_idx) orelse return null;
    return tokens[idx].hash;
}

fn nextConceptHash(tokens: []const FrameToken, start_idx: usize) ?u64 {
    const idx = nextConcept(tokens, start_idx) orelse return null;
    return tokens[idx].hash;
}

fn pronounOrPreviousConcept(tokens: []const FrameToken, cue_idx: usize) ?u64 {
    if (firstTokenHash(tokens, &.{ "i", "me", "my", "we", "us", "our" })) |hash| return hash;
    return previousConceptHash(tokens, cue_idx);
}

fn commerceGoods(tokens: []const FrameToken, verb_idx: usize) ?u64 {
    var idx = verb_idx + 1;
    while (idx < tokens.len) : (idx += 1) {
        if (matchesToken(tokens[idx].text, &.{ "for", "from", "with" })) break;
        if (isConceptStopToken(tokens[idx].text) or isCurrencyRune(tokens[idx].text)) continue;
        return tokens[idx].hash;
    }
    return null;
}

fn conceptAfterMarker(tokens: []const FrameToken, marker: []const u8) ?u64 {
    for (tokens, 0..) |token, idx| {
        if (!std.ascii.eqlIgnoreCase(token.text, marker)) continue;
        return nextConceptHash(tokens, idx + 1);
    }
    return null;
}

fn currencyToken(tokens: []const FrameToken) ?u64 {
    for (tokens) |token| {
        if (isCurrencyRune(token.text)) return token.hash;
    }
    return null;
}

fn isCurrencyRune(token: []const u8) bool {
    if (matchesToken(token, &.{ "buck", "bucks", "dollar", "dollars", "usd", "euro", "euros", "yen" })) return true;
    if (token.len > 1 and token[0] == '$') return true;
    var digit_count: usize = 0;
    for (token) |byte| {
        if (std.ascii.isDigit(byte)) digit_count += 1;
    }
    return digit_count != 0;
}

fn firstTokenHash(tokens: []const FrameToken, forms: []const []const u8) ?u64 {
    for (tokens) |token| {
        if (matchesToken(token.text, forms)) return token.hash;
    }
    return null;
}

fn commerceVerbIndex(tokens: []const FrameToken) ?usize {
    for (tokens, 0..) |token, idx| {
        if (matchesToken(token.text, &.{ "buy", "buys", "bought", "buying", "purchase", "purchases", "purchased", "grab", "grabs", "grabbed", "get", "got", "paid", "pay", "pays" })) return idx;
    }
    return null;
}

fn breakageCueIndex(tokens: []const FrameToken) ?usize {
    for (tokens, 0..) |token, idx| {
        if (matchesToken(token.text, &.{ "drop", "dropped", "drops", "fell", "fall", "hit", "hits", "struck", "smash", "smashed" })) return idx;
    }
    return null;
}

fn codeInheritanceIndex(tokens: []const FrameToken) ?usize {
    for (tokens, 0..) |token, idx| {
        if (matchesToken(token.text, &.{ "inherit", "inherits", "inherited", "inheritance", "subclass", "extends", "base" })) return idx;
    }
    return null;
}

fn analogyCueIndex(tokens: []const FrameToken) ?usize {
    for (tokens, 0..) |token, idx| {
        if (matchesToken(token.text, &.{ "like", "analogy", "metaphor", "similar" })) return idx;
    }
    return null;
}

fn storageCueIndex(tokens: []const FrameToken) ?usize {
    for (tokens, 0..) |token, idx| {
        if (matchesToken(token.text, &.{ "store", "stores", "stored", "storing", "storage", "data" })) return idx;
    }
    return null;
}

fn containmentCueIndex(tokens: []const FrameToken) ?usize {
    for (tokens, 0..) |token, idx| {
        if (matchesToken(token.text, &.{ "contain", "contains", "contained", "containing", "holds", "hold", "bucket", "container" })) return idx;
    }
    return null;
}

fn analogyPropertyHash(tokens: []const FrameToken) u64 {
    if (firstTokenHash(tokens, &.{ "bucket", "container", "contain", "contains", "holds", "hold" }) != null) return hashPredicateName("containment_storage");
    if (firstTokenHash(tokens, &.{ "brain", "control", "controls", "processor", "cpu" }) != null) return hashPredicateName("control_coordination");
    return hashPredicateName("structural_similarity");
}

fn isFrameStopToken(token: []const u8) bool {
    const words = [_][]const u8{
        "a",    "an",   "the",   "to",    "of",     "by",   "with", "and",   "or",
        "does", "do",   "did",   "is",    "are",    "was",  "were", "be",    "being",
        "been", "can",  "could", "would", "should", "must", "may",  "might", "then",
        "than", "that", "this",
    };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(token, word)) return true;
    }
    return false;
}

fn isConceptStopToken(token: []const u8) bool {
    const words = [_][]const u8{
        "explain", "difference", "between",  "whether", "what",  "when",   "where",   "why", "how",
        "logical", "absurdity",  "specific", "vector",  "query", "likely", "because",
    };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(token, word)) return true;
    }
    return false;
}

fn normalizedPredicateHash(token: []const u8) u64 {
    if (matchesPredicate(token, &.{ "read", "reads", "reading" })) return hashPredicateName("read");
    if (matchesPredicate(token, &.{ "control", "controls", "controlled", "controlling" })) return hashPredicateName("control");
    if (matchesPredicate(token, &.{ "execute", "executes", "executed", "executing" })) return hashPredicateName("execute");
    if (matchesPredicate(token, &.{ "process", "processes", "processed", "processing" })) return hashPredicateName("process");
    if (matchesPredicate(token, &.{ "store", "stores", "stored", "storing" })) return hashPredicateName("store");
    if (matchesPredicate(token, &.{ "use", "uses", "used", "using" })) return hashPredicateName("use");
    if (matchesPredicate(token, &.{ "contain", "contains", "contained", "containing", "has", "have", "hold", "holds" })) return hashPredicateName("contain");
    if (matchesPredicate(token, &.{ "compile", "compiles", "compiled", "compiling" })) return hashPredicateName("compile");
    if (matchesPredicate(token, &.{ "access", "accesses", "accessed", "accessing" })) return hashPredicateName("access");
    if (matchesPredicate(token, &.{ "write", "writes", "wrote", "written", "writing" })) return hashPredicateName("write");
    if (matchesPredicate(token, &.{ "follow", "follows", "followed", "following" })) return hashPredicateName("follow");
    return 0;
}

fn matchesPredicate(token: []const u8, forms: []const []const u8) bool {
    return matchesToken(token, forms);
}

fn matchesToken(token: []const u8, forms: []const []const u8) bool {
    for (forms) |form| {
        if (std.ascii.eqlIgnoreCase(token, form)) return true;
    }
    return false;
}

fn hashPredicateName(name: []const u8) u64 {
    return hashLowerAsciiToken(name);
}

fn hashLowerAsciiToken(token: []const u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    for (token) |byte| {
        var lower: [1]u8 = .{std.ascii.toLower(byte)};
        hasher.update(&lower);
    }
    return hasher.final();
}

fn hashRoleBound(subject_hash: u64, predicate_hash: u64, object_hash: u64) u64 {
    var roles = [_]u64{0} ** FRAME_ROLE_DIMS;
    roles[@intFromEnum(FrameRole.actor)] = subject_hash;
    roles[@intFromEnum(FrameRole.object)] = object_hash;
    roles[@intFromEnum(FrameRole.property)] = predicate_hash;
    return hashFrameBound(hashFrameKind(.relation, predicate_hash), roles, false);
}

fn updateHashU64(hasher: *std.hash.Fnv1a_64, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

test "semantic frame vectorization preserves directed inverse relations" {
    const query = extractFrameVector("Does the CPU control the RAM?");
    const direct = extractFrameVector("The CPU controls the RAM.");
    const inverse = extractFrameVector("The RAM controls the CPU.");

    try std.testing.expect(query.valid);
    try std.testing.expect(direct.valid);
    try std.testing.expect(inverse.valid);
    try std.testing.expect(query.directMatch(direct));
    try std.testing.expect(query.inverseMatch(inverse));
    try std.testing.expectEqual(@as(u16, 1000), relationScorePerMille(query, direct));
    try std.testing.expect(relationPenaltyPerMille(query, inverse) >= 800);
}

test "frame matrix maps implicit buying roles" {
    const frame = extractFrameVector("I grabbed a coffee for five bucks.");
    try std.testing.expect(frame.valid);
    try std.testing.expectEqual(FrameKind.commerce, frame.frame_kind);
    try std.testing.expect(frame.role(.actor) != 0);
    try std.testing.expect(frame.role(.object) != 0);
    try std.testing.expect(frame.role(.instrument) != 0);
}

test "frame matrix captures breakage implication roles" {
    const frame = extractFrameVector("I dropped my glass on the concrete.");
    try std.testing.expect(frame.valid);
    try std.testing.expectEqual(FrameKind.breakage, frame.frame_kind);
    try std.testing.expect(frame.role(.object) != 0);
    try std.testing.expect(frame.role(.target) != 0);
    try std.testing.expect(frame.role(.result) != 0);
}

test "graph isomorphism links containment and storage analogy" {
    const variable = extractFrameVector("A variable stores a value.");
    const bucket = extractFrameVector("A bucket contains water.");
    try std.testing.expect(variable.valid);
    try std.testing.expect(bucket.valid);
    try std.testing.expect(graphIsomorphismScorePerMille(variable, bucket) >= 500);
}
