# Task 4 report

## Scope
Implemented typed send request extensions (SEND_WITH_INV, REG_MR, BIND_MW, FLUSH fields), UD/URC transport validation and SQE encode_sqe facade. Added UD/URC codec subclasses using driver opcode mapping, destination QPN/Q_Key fields, direct/inline payload path and signature handling. Added SQ facade validate_transport and queue-data model propagation.

## TDD evidence
RED: `scripts/run_vcs53.sh core rdma_ud_urc_sqe_codec_test` initially failed at compile because `rdma_queue_codec::encode_sqe` was missing (expected shell API gap).
GREEN: `scripts/run_vcs53.sh core rdma_ud_urc_sqe_codec_test` completed compile/simulation without UVM error summary output.
GREEN: `scripts/run_vcs53.sh core rdma_wqe_extended_opcode_test` completed compile/simulation without UVM error summary output.
`git diff --check` passed.

## Compatibility decisions
The existing model had no typed control-opcode enum or encode_sqe facade. Added enum values and a static facade while preserving existing RC codec fields. MW has no pre-existing resource kind; added RDMA_RESOURCE_MW=9 for explicit authority checks. The UD/URC codecs reuse the established 64-byte WQE layout; no new register fields were invented beyond definitions already present in rdma_defs.svh.

## Concerns
FWQE SGB host-memory write ordering remains governed by queue_data_engine::write_and_verify; no PI commit occurs before write/readback success. Extended control WQEs carry authority handles in semantic requests but are not posted by queue_data_engine because no hardware control-WQE register profile exists in current defs.
