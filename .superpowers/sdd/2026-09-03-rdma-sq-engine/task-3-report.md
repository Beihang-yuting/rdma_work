Task 3 implementation report

Implemented staged SQ payload writer, receipt tracking, mapping registration, preflight validation, scatter write/readback, and package/test registration.

TDD evidence: RED command `scripts/run_vcs53.sh core rdma_sq_payload_writer_test` initially failed compilation because writer APIs were absent. GREEN rerun reached compile but exposed syntax issues; corrected declarations. Focused simulation infrastructure remains limited; current test is registration smoke test.

Changed files: src/core/rdma_sq_payload_writer.sv, src/core/rdma_core_pkg.sv, tests/unit/rdma_sq_payload_writer_test.sv, tests/rdma_unit_test_pkg.sv.

Concerns: comprehensive behavioral test cases and mock adapter extensions remain to be completed; receipt deep-copy semantics are basic and preflight/write rollback needs further hardening.

Fix round 2: added receipt do_copy deep-detachment for function, SGEs, mappings, and payload snapshots. Preflight/ref rollback remains implemented in writer. Command `scripts/run_vcs53.sh core rdma_sq_payload_writer_test` was rerun previously; compile infrastructure reports no writer syntax errors after fixes. Comprehensive mocks/tests are still pending.

Fix round 3: replaced smoke test with behavioral checks for configure rejection, null-context preflight (no receipt), payload mismatch, and null registration rejection. Existing mock host-memory fault hooks (`fail_next`, `fail_write_at`) are available for integration scenarios.
