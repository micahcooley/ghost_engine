#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROWS_FILE="${ROOT_DIR}/.ghost/knowledge/swe_bench_pro/rows.jsonl"
CORPUS_DIR="${ROOT_DIR}/corpus_local_backup/code"

if [[ ! -f "${ROWS_FILE}" ]]; then
  echo "seed_corpus: rows file not found: ${ROWS_FILE}" >&2
  exit 1
fi

mkdir -p "${CORPUS_DIR}"

repo_list="$(mktemp)"
trap 'rm -f "${repo_list}"' EXIT

if command -v jq >/dev/null 2>&1; then
  jq -r 'select(.repo != null) | .repo' "${ROWS_FILE}" | sort -u >"${repo_list}"
else
  python3 - "${ROWS_FILE}" >"${repo_list}" <<'PY'
import json
import sys

repos = set()
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            repo = json.loads(line).get("repo")
        except json.JSONDecodeError:
            continue
        if isinstance(repo, str) and repo:
            repos.add(repo)

for repo in sorted(repos):
    print(repo)
PY
fi

while IFS= read -r repo; do
  [[ -n "${repo}" ]] || continue
  if [[ "${repo}" == *".."* || "${repo}" != */* ]]; then
    echo "seed_corpus: skipping unsafe repo field: ${repo}" >&2
    continue
  fi

  leaf="${repo##*/}"
  target="${CORPUS_DIR}/${leaf}"

  if [[ -d "${target}" ]]; then
    echo "seed_corpus: exists ${leaf}"
    continue
  fi

  echo "seed_corpus: cloning ${repo} -> ${target}"
  if ! git clone "https://github.com/${repo}.git" "${target}"; then
    echo "seed_corpus: clone failed for ${repo}" >&2
    rm -rf "${target}"
  fi
done <"${repo_list}"
