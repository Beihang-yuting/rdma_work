# SDD ledger — plan: docs/superpowers/plans/2026-09-05-rdma-driver-gap-closure.md

## Setup

- Worktree: `.worktrees/rdma-gap-closure` on `feature/rdma-gap-closure`.
- Baseline: `53289bd` (`docs: add rdma gap closure implementation plan`).
- Local Python baseline could not run because this container has no `pytest`; VCS validation remains required on host 53.

## Preflight conflict scan

| Rows | Shared file/interface | Finding | Ruling |
| --- | --- | --- | --- |
| Task 1 ↔ Task 5 | `sim/Makefile`, `sim/filelists/net_packet.f` | Task 1 creates target/filelist skeleton; Task 5 fills dependency/adapter sources. | Task 1 may add only a compile-safe target/preflight shell; Task 5 owns external source ordering and adapter entries. |
| Task 1 ↔ Task 8 | `sim/Makefile` | Both update RDMA archive/version checker target. | Task 1 updates prefix and suite boundaries; Task 8 updates only codec manifest/hash/vector checks and must preserve Task 1 target behavior. |
| Task 2 ↔ Task 3 | `rdma_queue_codecs.sv`, `rdma_cq_engine.sv`, CQ layout | Task 2 produces variable CQE layout; Task 3 consumes it for shadow/flush. | Task 2 owns size/layout and encode/decode API; Task 3 may add only shadow/lifecycle fields and call Task 2 APIs. |
| Task 2 ↔ Task 4 | `rdma_queue_codecs.sv`, `rdma_queue_data_engine.sv` | Task 4 consumes CQE layout while adding SQE/WQE behavior. | Task 4 must not alter CQE field positions or size enum; reuse the public layout contract. |
| Task 3 ↔ Task 6 | `rdma_context_models.sv` | Task 3 adds CQ shadow authority; Task 6 adds ABI mmap/context descriptors. | Both preserve existing context model fields; ABI stores a value snapshot and never aliases shadow storage. |
| Task 4 ↔ Task 7 | semantic requests, host-mem mappings | WQE MR/MW fields depend on UMEM/PBL handles. | Task 4 uses opaque mapping/MW handles; Task 7 supplies validation and lifecycle without changing WQE opcode encoding. |
| Task 5 ↔ Task 9 | `rdma_unit_test_pkg.sv`, regression scripts | Task 5 adds integration test and suite; Task 9 registers it and runs all suites. | Task 5 adds test source only; Task 9 owns final package guards and regression lists. |
| Task 6 ↔ Task 7 | `rdma_host_mem_api.sv`, host-mem adapter | ABI maps regions while UMEM/PBL controls page lifetime. | ABI owns mmap refcount; host-mem owns page pin/unpin; release order is ABI region → MW → PBL → UMEM. |
| Task 8 ↔ all codec tasks | enum/registry and golden vectors | New opcodes must not invalidate existing codec contracts. | Registry additions are additive; existing names/values remain frozen and unknown opcodes still return `RDMA_SC_UNSUPPORTED_OPCODE`. |
| Task 9 self-consistency | test/package/docs files | Final task depends on all previous tests and external dependency paths. | Execute only after Tasks 1–8 commits; no production behavior is introduced in Task 9. |

## Task self-consistency scan

| Task | Test vs implementation/files | Ruling |
| --- | --- | --- |
| 1 | Python test checks regression script; Makefile/filelist changes are scoped to target/preflight. | Consistent. |
| 2 | CQE test calls layout/codec API produced by the listed files; resize test calls CQ engine API. | Consistent. |
| 3 | Shadow test calls `flush_shadow()` and checks idempotence; listed model/engine files own state. | Consistent. |
| 4 | SQE/WQE tests call codec/engine behavior listed in the task. | Consistent. |
| 5 | Integration test calls adapter/sink API and Makefile target; external `packet` is supplied by filelist. | Consistent. |
| 6 | ABI test calls negotiation/map/unmap and checks exactly-once release; listed API/model files own descriptors. | Consistent. |
| 7 | UMEM/PBL/MW test calls pin/build/bind/invalidate and checks refcounts; listed host-mem/model files own lifecycle. | Consistent. |
| 8 | Registry test and checker vectors cover additive opcode entries and 0.1.34 manifest. | Consistent. |
| 9 | Static comment test and suite commands cover final files; no behavior beyond registration/docs. | Consistent. |

## Rulings

- Ruling: use `e2af70204f53ede65e366c7a65f695c59acdbbc5` for `net_packet` — it is the current GitHub `main` commit supplied by the user; cost if wrong is reproducibility drift requiring a later dependency pin update.
- Ruling: work in the isolated feature worktree — the user selected subagent-driven execution; cost if wrong is extra cleanup, but the original `main` remains untouched.
- Ruling: Task 2's listed `src/types/rdma_defs.sv` does not exist; use the existing `src/codec/rdma/rdma_defs.svh` for compile-time constants/macros and do not create a duplicate `.sv` definition — cost if wrong is a later path-only review adjustment, while duplicating constants would create conflicting symbols.
- Ruling: Task 2's illustrative static `rdma_queue_codec::encode_cqe/decode_cqe` API may be implemented through the existing registered codec classes if that preserves the requested behavior; cost if wrong is adapter/test API churn, but codec registry compatibility is more important than an unestablished static helper name.

Task 1: fix round 1/5 (4 findings addressed pending scoped re-review; commits 3592e23..102fdfb)
Task 1: complete (commits 53289bd..102fdfb, review clean)
Task 2: fix round 1/5 (resize/runtime/layout/reserved-byte findings addressed pending scoped re-review; commits 0b0c692..ab1e7d9)
Task 2: fix round 2/5 (slot deep-copy added; fresh backing/quiesce/profile isolation findings open; commits ab1e7d9..6844386)
Task 2: fix round 3/5 (deep-copy/report honesty added; fresh backing/quiesce/profile isolation findings open; commits 6844386..ea93487)
Task 2: fix round 4/5 (planner/manager/runtime resize primitives added but resize_cq integration remains open; Critical finding from scoped review; commits 1b15aeb..59c3ab9)
Task 2: fix round 5/5 (resize_cq wired to fresh backing/authority replacement; dependent runtime restore and value-based rollback assertions added; pending scoped re-review; commits 59c3ab9..f8fc517)
Task 2: follow-up recovery/SRQ round (engine-owned published-cleanup recovery, retry API,
  detach/reconfigure guards, SRQ dependent fixture, stateless CQE decode cleanup and field-width
  assertion fix; CMQ/QP route+epoch projection and opaque rollback hardening; committed baseline
  `9047f13`, final local follow-up commit pending).

## Task 2 follow-up verification ledger

- `git diff --check`: passed after the current follow-up edits.
- `scripts/run_vcs53.sh core rdma_cq_engine_resize_test`: passed on
  `ubuntu@10.11.10.53`, UVM `warning=0 error=0 fatal=0`.
- `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`: passed on
  `ubuntu@10.11.10.53`, UVM `warning=0 error=0 fatal=0`.
- `scripts/run_vcs53.sh core rdma_queue_data_engine_post_test`、
  `rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_recovery_test`：均通过，UVM
  `warning=0 error=0 fatal=0`。
- `scripts/run_vcs53.sh core rdma_queue_host_mem_submitter_test`：通过，UVM
  `warning=0 error=0 fatal=0`。
- `HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem scripts/run_vcs53.sh host_mem
  rdma_host_mem_adapter_test`：通过，Host-memory leak check 全部为 0，UVM
  `warning=0 error=0 fatal=0`。
- `DPU_COMMON_ROOT=/home/ubuntu/virtio_work_continue/dpu_common scripts/run_vcs53.sh
  integration rdma_host_mem_router_test`：通过，UVM `warning=0 error=0 fatal=0`。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：109 个静态契约测试通过；
  regression manifest 已补齐 CQE/resize 和 integration-unit 测试发现项。
- `scripts/run_vcs53.sh core rdma_cmq_engine_test`、`rdma_queue_lifecycle_test`：最新复跑均通过，
  UVM `warning=0 error=0 fatal=0`；CMQ reset release failure 期间 terminal FIFO 保留逻辑已覆盖。
- scoped review 发现的 recovery 代际句柄、route/epoch authority、success+null mapping
  契约和 owned-ref 几何校验问题均已修复；host-mem adapter 的宏转义也已在真实
  host_mem filelist 下重新编译验证。
- 最终提交前删除 `tools/__pycache__/` 生成物；本 Task 只创建本地 commit，不 merge、不 push。
