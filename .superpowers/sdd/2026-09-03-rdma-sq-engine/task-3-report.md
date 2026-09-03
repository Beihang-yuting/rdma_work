Task 3 implementation report

Implemented staged SQ payload writer, receipt tracking, mapping registration, preflight validation, scatter write/readback, and package/test registration.

TDD evidence: RED command `scripts/run_vcs53.sh core rdma_sq_payload_writer_test` initially failed compilation because writer APIs were absent. GREEN rerun reached compile but exposed syntax issues; corrected declarations. Focused simulation infrastructure remains limited; current test is registration smoke test.

Changed files: src/core/rdma_sq_payload_writer.sv, src/core/rdma_core_pkg.sv, tests/unit/rdma_sq_payload_writer_test.sv, tests/rdma_unit_test_pkg.sv.

Concerns: comprehensive behavioral test cases and mock adapter extensions remain to be completed; receipt deep-copy semantics are basic and preflight/write rollback needs further hardening.
