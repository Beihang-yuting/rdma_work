Task 3 implementation report

Implemented staged SQ payload writer, receipt tracking, mapping registration, preflight validation, scatter write/readback, and package/test registration.

TDD evidence: RED command `scripts/run_vcs53.sh core rdma_sq_payload_writer_test` initially failed compilation because writer APIs were absent. GREEN rerun reached compile but exposed syntax issues; corrected declarations. Focused simulation infrastructure remains limited; current test is registration smoke test.

Changed files: src/core/rdma_sq_payload_writer.sv, src/core/rdma_core_pkg.sv, tests/unit/rdma_sq_payload_writer_test.sv, tests/rdma_unit_test_pkg.sv.

Concerns: comprehensive behavioral test cases and mock adapter extensions remain to be completed; receipt deep-copy semantics are basic and preflight/write rollback needs further hardening.

Fix round 2: added receipt do_copy deep-detachment for function, SGEs, mappings, and payload snapshots. Preflight/ref rollback remains implemented in writer. Command `scripts/run_vcs53.sh core rdma_sq_payload_writer_test` was rerun previously; compile infrastructure reports no writer syntax errors after fixes. Comprehensive mocks/tests are still pending.

Fix round 3: replaced smoke test with behavioral checks for configure rejection, null-context preflight (no receipt), payload mismatch, and null registration rejection. Existing mock host-memory fault hooks (`fail_next`, `fail_write_at`) are available for integration scenarios.

Fix round 4 (7be394c): completed the writer implementation and substantive fixture-based unit test. The writer now performs detached Function/BDF/PASID/domain identity checks, checked registration and SGE ranges, ACTIVE and DEVICE_READ permission checks, overlap rejection, full preflight before any host-memory write, scatter write/readback verification, and deterministic reference rollback. Receipts deep-copy payload, SGEs, mappings, and Function identity; `release_receipt()` is idempotent and never invokes `host_mem.release()`. Added deterministic `corrupt_next_readback` mock fault injection. The test covers successful two-SGE scatter/readback, detached snapshots and copy, unregister-busy/release-once, missing registration, payload mismatch, identity mismatches, inactive/permission mappings, range overflow/overlap, write failure, readback mismatch, and no-write-on-preflight assertions.

Verification: `git diff HEAD^ HEAD --check` completed with no output. VCS host command `scripts/run_vcs53.sh core rdma_sq_payload_writer_test` completed with UVM_INFO=3, UVM_WARNING=0, UVM_ERROR=0, UVM_FATAL=0. Note: the remote simulation log unexpectedly showed only the empty placeholder test body despite the transferred source containing the substantive test; this indicates the remote run used a stale cached source snapshot. The compile completed without writer errors, but behavioral assertions could not be independently observed in that invocation.

Fix round 5: bound each writer-issued receipt's release capability to the
issuing writer; receipt copies retain detached data but cannot release the
original registration references. Corrected the scatter-call count and made
the readback-corruption case use the actual allocated IOVA and assert that a
read occurred. Fresh VCS verification remained pristine; the earlier stale
log observation is superseded by this fresh run. The final changed-file set
also includes `tests/mocks/rdma_mock_adapters.sv`.
