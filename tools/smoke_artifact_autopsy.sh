#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIP="$ROOT/zig-out/bin/ghost_gip"

if [[ ! -x "$GIP" ]]; then
  echo "missing executable: $GIP" >&2
  echo "run 'zig build' before this smoke script" >&2
  exit 1
fi

TMP_DIR="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "$TMP_DIR/ghost_artifact_autopsy_smoke.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

run_gip() {
  local name="$1"
  local payload="$2"
  local out="$WORK_DIR/$name.json"
  printf '%s\n' "$payload" | "$GIP" --stdin --workspace "$ROOT" > "$out"
  printf '%s\n' "$out"
}

assert_jq() {
  local file="$1"
  local expr="$2"
  local label="$3"
  if ! jq -e "$expr" "$file" >/dev/null; then
    echo "assertion failed: $label" >&2
    echo "file: $file" >&2
    jq '.' "$file" >&2 || cat "$file" >&2
    exit 1
  fi
}

assert_grep() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "assertion failed: $label" >&2
    echo "file: $file" >&2
    cat "$file" >&2
    exit 1
  fi
}

if command -v jq >/dev/null 2>&1; then
  DOC_OUT="$(run_gip documentation_audit '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"documentation_audit","artifactPaths":["fixtures/artifact_autopsy/documentation/README.md","fixtures/artifact_autopsy/documentation/Makefile"]}')"
  assert_jq "$DOC_OUT" '.status == "ok"' "documentation audit status"
  assert_jq "$DOC_OUT" '.result.artifactAutopsyInspect.file_backed == true' "documentation audit is file-backed"
  assert_jq "$DOC_OUT" '.result.artifactAutopsyInspect.read_only == true and .result.artifactAutopsyInspect.non_authorizing == true and .result.artifactAutopsyInspect.candidate_only == true' "documentation audit safety flags"
  assert_jq "$DOC_OUT" '.result.artifactAutopsyInspect.inconsistencies[]? | select(.inconsistency_kind == "claim_vs_config")' "documentation audit claim/config candidate"

  UNUSED_OUT="$(run_gip recipe_unused '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"recipe_consistency","artifactPaths":["fixtures/artifact_autopsy/recipes/recipe_unused.md"]}')"
  assert_jq "$UNUSED_OUT" '.status == "ok"' "unused ingredient status"
  assert_jq "$UNUSED_OUT" '.result.artifactAutopsyInspect.inconsistencies[]? | select(.inconsistency_kind == "unused_ingredient")' "unused ingredient candidate"

  MISSING_OUT="$(run_gip recipe_missing '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"recipe_consistency","artifactPaths":["fixtures/artifact_autopsy/recipes/recipe_missing.md"]}')"
  assert_jq "$MISSING_OUT" '.status == "ok"' "missing ingredient status"
  assert_jq "$MISSING_OUT" '.result.artifactAutopsyInspect.inconsistencies[]? | select(.inconsistency_kind == "missing_ingredient")' "missing ingredient candidate"

  NO_ING_OUT="$(run_gip recipe_no_ingredients '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"recipe_consistency","artifactPaths":["fixtures/artifact_autopsy/recipes/recipe_no_ingredients.md"]}')"
  assert_jq "$NO_ING_OUT" '.status == "ok"' "no ingredients status"
  assert_jq "$NO_ING_OUT" '.result.artifactAutopsyInspect.unknowns[]? | select(.name == "missing_ingredients_section")' "missing ingredients unknown"

  NO_STEPS_OUT="$(run_gip recipe_no_steps '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"recipe_consistency","artifactPaths":["fixtures/artifact_autopsy/recipes/recipe_no_steps.md"]}')"
  assert_jq "$NO_STEPS_OUT" '.status == "ok"' "no steps status"
  assert_jq "$NO_STEPS_OUT" '.result.artifactAutopsyInspect.unknowns[]? | select(.name == "missing_steps_section")' "missing steps unknown"

  TRAVERSAL_OUT="$(run_gip traversal_rejected '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"documentation_audit","artifactPaths":["../README.md"]}')"
  assert_jq "$TRAVERSAL_OUT" '.status == "rejected"' "path traversal rejection status"
  assert_jq "$TRAVERSAL_OUT" '.error.code == "invalid_request"' "path traversal rejection code"
  assert_jq "$TRAVERSAL_OUT" '.error.message | contains("path traversal")' "path traversal rejection message"
else
  DOC_OUT="$(run_gip documentation_audit '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"documentation_audit","artifactPaths":["fixtures/artifact_autopsy/documentation/README.md","fixtures/artifact_autopsy/documentation/Makefile"]}')"
  assert_grep "$DOC_OUT" '"status":"ok"' "documentation audit status"
  assert_grep "$DOC_OUT" '"file_backed":true' "documentation audit is file-backed"
  assert_grep "$DOC_OUT" '"read_only":true' "documentation audit read-only flag"
  assert_grep "$DOC_OUT" '"non_authorizing":true' "documentation audit non-authorizing flag"
  assert_grep "$DOC_OUT" '"candidate_only":true' "documentation audit candidate-only flag"
  assert_grep "$DOC_OUT" '"inconsistency_kind":"claim_vs_config"' "documentation audit claim/config candidate"

  UNUSED_OUT="$(run_gip recipe_unused '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"recipe_consistency","artifactPaths":["fixtures/artifact_autopsy/recipes/recipe_unused.md"]}')"
  assert_grep "$UNUSED_OUT" '"status":"ok"' "unused ingredient status"
  assert_grep "$UNUSED_OUT" '"inconsistency_kind":"unused_ingredient"' "unused ingredient candidate"

  MISSING_OUT="$(run_gip recipe_missing '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"recipe_consistency","artifactPaths":["fixtures/artifact_autopsy/recipes/recipe_missing.md"]}')"
  assert_grep "$MISSING_OUT" '"status":"ok"' "missing ingredient status"
  assert_grep "$MISSING_OUT" '"inconsistency_kind":"missing_ingredient"' "missing ingredient candidate"

  NO_ING_OUT="$(run_gip recipe_no_ingredients '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"recipe_consistency","artifactPaths":["fixtures/artifact_autopsy/recipes/recipe_no_ingredients.md"]}')"
  assert_grep "$NO_ING_OUT" '"status":"ok"' "no ingredients status"
  assert_grep "$NO_ING_OUT" '"name":"missing_ingredients_section"' "missing ingredients unknown"

  NO_STEPS_OUT="$(run_gip recipe_no_steps '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"recipe_consistency","artifactPaths":["fixtures/artifact_autopsy/recipes/recipe_no_steps.md"]}')"
  assert_grep "$NO_STEPS_OUT" '"status":"ok"' "no steps status"
  assert_grep "$NO_STEPS_OUT" '"name":"missing_steps_section"' "missing steps unknown"

  TRAVERSAL_OUT="$(run_gip traversal_rejected '{"gipVersion":"gip.v0.1","kind":"artifact.autopsy.inspect","domain":"documentation_audit","artifactPaths":["../README.md"]}')"
  assert_grep "$TRAVERSAL_OUT" '"status":"rejected"' "path traversal rejection status"
  assert_grep "$TRAVERSAL_OUT" '"code":"invalid_request"' "path traversal rejection code"
  assert_grep "$TRAVERSAL_OUT" 'path traversal' "path traversal rejection message"
fi

echo "artifact autopsy smoke fixtures passed"
