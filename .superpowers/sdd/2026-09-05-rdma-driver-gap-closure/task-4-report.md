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

## Reviewer fix round

Commit `de80786` closes the review findings: UD now accepts SEND_WITH_INV and tests assert opcode, destination QPN and invalidate key; queue-data `make_sqe` copies inline/payload/remote/SGB fields; URC extension carries cloned completion-QP authority and the encode path returns explicit `RDMA_SC_UNSUPPORTED_OPCODE` when no profile exists; RC typed REG_MR/BIND_MW/FLUSH reach authority validation while codec publication remains explicitly unsupported; dead comment block was removed.

Verification rerun on `ubuntu@10.11.10.53` login bash:

`scripts/run_vcs53.sh core rdma_ud_urc_sqe_codec_test` — exit 0.

`scripts/run_vcs53.sh core rdma_wqe_extended_opcode_test` — exit 0.

`git diff --check` — passed.
