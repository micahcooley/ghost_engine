# Project Autopsy

Project Autopsy Pass 1 builds a deterministic, bounded, read-only profile of a
workspace before deeper reasoning or debugging.

It produces two draft, non-authorizing artifacts:

- `project_profile`: detected project signals such as languages, build systems,
  package managers, CI files, docs, config files, source/test roots, risk
  surfaces, safe command candidates, verifier gaps, unknowns, and a bounded
  trace.
- `project_gap_report`: missing or ambiguous signals such as no detected test
  command, build command, CI config, docs, verifier adapter status, pack
  recommendation, unsafe command candidate, or next question.

It also emits `verifier_plan_candidates`, a draft list derived from safe command
candidates. These are proposed verifier plans only; Autopsy does not approve,
register, schedule, or execute them.

## Read-Only Contract

Autopsy may inspect filenames and read small known files such as `build.zig`,
`package.json`, `pyproject.toml`, and `requirements.txt`.

Autopsy must not:

- execute commands
- install dependencies
- mutate workspace files
- write reports into the repo
- mount or mutate Knowledge Packs
- register, approve, or run verifiers
- promote any profile signal into proof of correctness

## Detected Signals

Pass 1 recognizes common workspace markers:

- Zig: `build.zig`, `build.zig.zon`, `src/*.zig`
- Rust: `Cargo.toml`
- Node, JavaScript, TypeScript: `package.json`, `tsconfig.json`
- Python: `pyproject.toml`, `requirements.txt`, `setup.py`
- Go: `go.mod`
- C/C++: `CMakeLists.txt`, `Makefile`, `meson.build`
- Java/Kotlin: `pom.xml`, `build.gradle`, `settings.gradle`
- Docker: `Dockerfile`, `docker-compose.yml`
- CI/docs/config: `.github/workflows/*.yml`, `.gitlab-ci.yml`,
  `README.md`, `docs/`, `CONTRIBUTING.md`, `LICENSE`, `.editorconfig`,
  `.env.example`, dependency files, and lockfiles

## Safe Command Candidates

Command candidates are data only. They use `argv[]`, never shell strings, and
always include:

- `cwd`
- `reason`
- `detected_from`
- `risk_level`
- `requires_user_confirmation: true`
- `non_authorizing: true`

Pass 1 rejects sudo, install, shell-string, network, and arbitrary mutation
commands. A candidate is not evidence that a command succeeds; it is only a
future verifier candidate.

## Verifier Plan Candidates

Verifier plan candidates are derived from detected Autopsy command candidates
and remain non-authorizing. Each plan includes:

- `argv`
- `cwd_hint`
- `purpose`
- `risk_level`
- `confidence`
- `requires_user_confirmation: true`
- `non_authorizing: true`
- `executes_by_default: false`
- `source_evidence_paths`
- `why_candidate_exists`
- `unknowns`

Zig workspaces may propose `zig build`, `zig build test`, and detected optional
targets such as `zig build bench-serious-workflows`. Node plans come only from
detected `package.json` scripts. Rust, Python, and Go plans come from
`Cargo.toml`, Python packaging/pytest signals, and `go.mod` respectively.

Unknown confidence is represented in `unknowns`; it is not treated as evidence
that a command is absent or invalid.

## Unknowns vs Negative Evidence

Missing evidence is represented as unknown or missing. For example, if no test
command is detected, the gap report records `missing_test_command`; it does not
claim that tests do not exist.

## Risk Surfaces

Risk surfaces are routing signals only. Pass 1 flags likely-sensitive paths such
as auth/security names, migrations/database areas, CI/deployment files, build
and dependency files, runtime/concurrency files, shell scripts, config/env files,
and verifier/test harness files.

These signals do not authorize correctness claims or edits.

## Future Learning Loop Role

Project Autopsy is intended to feed Ghost Learning Loop with bounded project
context before hypothesis generation, verifier selection, and debugging. Its
outputs remain draft/non-authorizing until separate proof-gated verification
produces evidence.
