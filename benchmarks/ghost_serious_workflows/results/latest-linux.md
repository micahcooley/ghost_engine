# Ghost Serious Workflow Benchmarks (linux)

- total cases: 15
- passed cases: 15
- failed cases: 0
- code impact correctness rate: 100%
- contradiction detection correctness rate: 100%
- unresolved-vs-unsupported correctness rate: 100%
- minimal-safe-refactor correctness rate: 100%
- execution-loop handling rate: 100%
- provenance/support completeness rate: 100%
- verified supported patch results: 5
- patch compile-pass rate: 85% (12/14)
- test-pass rate: 75% (9/12)
- runtime-pass rate: 0% (0/0)
- latency per verified result: 6940 ms
- cold start / warm start: 40 ms / 56 ms
- cold cache changed files / warm cache changed files: 11 / 0

Notes:
- patch compile-pass and test-pass rates are per attempted candidate verification step, not per benchmark case.
- runtime-pass rate is currently 0/0 because the suite has no positive runtime-verified patch fixture yet, not because runtime execution is failing.
- cold versus warm cache measurements are reported factually; the suite checks shard-local cache behavior, not a guarantee that warm latency is always lower.

## Case Results

- `impact_widget_to_service`: pass; expected `supported_success` got `supported_success`; status=supported; evidence=1; support_nodes=8
- `contradiction_call_site`: pass; expected `supported_success` got `supported_success`; status=supported; evidence=1; support_nodes=9
- `contradiction_signature`: pass; expected `supported_success` got `supported_success`; status=supported; evidence=1; support_nodes=9
- `contradiction_ownership`: pass; expected `supported_success` got `supported_success`; status=supported; evidence=2; support_nodes=11
- `ambiguous_target_unresolved`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; status=unresolved; evidence=0; support_nodes=6
- `cold_warm_code_intel_start`: pass; expected `supported_success` got `supported_success`; cold=40ms warm=56ms cold_changed=11 warm_changed=0
- `patch_verified_success`: pass; expected `supported_success` got `supported_success`; status=supported; verified=1; build=2/2; test=2/2
- `patch_minimal_refactor_selection`: pass; expected `supported_success` got `supported_success`; status=supported; verified=1; build=4/4; test=3/4
- `patch_retry_failure_handling`: pass; expected `supported_success` got `supported_success`; status=supported; verified=1; build=2/2; test=1/2
- `patch_refinement_retry`: pass; expected `supported_success` got `supported_success`; status=supported; verified=1; build=2/2; test=1/2
- `patch_all_fail_unresolved`: pass; expected `failed_verification_or_runtime` got `failed_verification_or_runtime`; status=unresolved; verified=0; build=0/2; test=0/0
- `patch_abstraction_support`: pass; expected `supported_success` got `supported_success`; status=supported; verified=1; build=2/2; test=2/2
- `execution_zig_run_success`: pass; expected `supported_success` got `supported_success`; signal=none; exit=0
- `execution_blocked_shell_refusal`: pass; expected `correct_unresolved_or_refused` got `correct_unresolved_or_refused`; signal=disallowed_command; exit=none
- `execution_timeout_is_bounded`: pass; expected `failed_verification_or_runtime` got `failed_verification_or_runtime`; signal=timed_out; exit=-15
