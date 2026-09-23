# Phase 1C RDMA 硬件 ABI 修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复项目 RDMA 编解码层与 0.1.34 驱动 ABI 的字段、profile 基址和 runtime-shadow 差异，并以真实 raw image 测试锁定契约。

**Architecture:** 先建立 CQC 不变性 baseline，再按独立 codec 边界逐项落地。每项先 RED、再最小模型/codec 实现、再 focused GREEN；reserved mask 仅放行驱动明确声明的位。

**Tech Stack:** SystemVerilog/UVM codec models、VCS53 simulator、Python static checks、`rdma_hw_qword_builder`。

**Spec:** `/tmp/phase1c-spec.md`；驱动证据详见 `.superpowers/sdd/2026-09-11-rdma-cmq-contract-foundation/phase1c-audit.md`。

## Global Constraints

- 驱动 ABI 只读依据：`ubuntu@10.11.10.53` 归档 `dpu_kernel_rdma-version_0.1.34.tar(1).gz`。
- 不修改外部依赖；所有扩展在项目 codec/model 层完成。
- 禁止放宽整 qword 或删除 reserved 检查；每个允许位必须对应驱动宏。
- CQC 坐标是 baseline gate；任何任务完成前必须通过 CQC 回归。
- 每个任务遵循 RED→53 focused failure→最小实现→53 focused GREEN→`git diff --check` 与中文注释复审。
- VCS 仿真只能通过登录 bash 在 `ubuntu@10.11.10.53` 执行。

### Task 0: Freeze CQC baseline

**Files:**
- Modify: `tests/unit/rdma_cmq_codec_test.sv` only if an existing baseline assertion lacks raw coordinate coverage.
- Test: `tests/unit/rdma_cmq_codec_test.sv`, `tests/unit/rdma_cqe_size_codec_test.sv`。

**Interfaces:** Consume existing CQC codec/model; produce a no-regression gate for `cq.h:123-153` fields and CQE size code.

- [ ] **Step 1: Write the failing test** — add raw-word assertions for CQC CQ PI/wrap, CQE size `[63:62]`, CQ state/size, CI/wrap, arm fields, shadow PA and CEQN; add 32/64/128 CQE size cases.
- [ ] **Step 2: Run test to verify it fails** — `scripts/run_vcs53.sh core rdma_cmq_codec_test`; expected RED is a missing/incorrect raw coordinate assertion, not a simulator compile workaround.
- [ ] **Step 3: Implement minimal test fixture** — use `rdma_hw_qword_builder.get_words()` and driver masks; do not alter CQC codec fields already aligned.
- [ ] **Step 4: Run focused GREEN** — `scripts/run_vcs53.sh core rdma_cmq_codec_test` and `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`; summaries must be pristine.
- [ ] **Step 5: Commit** — `git add tests/unit/rdma_cmq_codec_test.sv tests/unit/rdma_cqe_size_codec_test.sv && git commit -m "test: freeze CQC ABI baseline"`。

### Task 1: CQE profile-relative 128B header (C2)

**Files:**
- Modify: `src/codec/rdma/rdma_queue_codecs.sv` (CQE codec only)。
- Test: `tests/unit/rdma_cqe_size_codec_test.sv`。

**Interfaces:** Consume `set_entry_bytes()/encode_with_entry_bytes()/decode_with_entry_bytes()`; preserve 32/64B base 0 and use 128B base byte64/qword8.

- [ ] **Step 1: Write RED** — construct a 128B raw image with header fields at byte64 and nonzero prefix sentinels; assert current codec rejects/misdecodes, then add expected byte64 decode and byte0-negative checks.
- [ ] **Step 2: Run RED** — `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`; expected failure is header-at-byte64 assertion.
- [ ] **Step 3: Implement** — create a profile-relative builder view or copy exactly the header window; run `check_reserved`, `encode_fields`, `decode_fields` against base 0 for 32/64 and base 64 for 128; preserve image metadata length/alignment.
- [ ] **Step 4: Run GREEN** — same command plus `scripts/run_vcs53.sh core rdma_queue_codec_test`; assert raw qword8 fields and zero/nonzero extension policy.
- [ ] **Step 5: Commit** — `git add src/codec/rdma/rdma_queue_codecs.sv tests/unit/rdma_cqe_size_codec_test.sv tests/unit/rdma_queue_codec_test.sv && git commit -m "fix: decode 128B CQE header at byte 64"`。

### Task 2: RQE SGB_PA (C1)

**Files:**
- Modify: `src/codec/rdma/rdma_queue_codecs.sv`, `src/codec/rdma/rdma_defs.svh` only if a missing field constant is required。
- Test: `tests/unit/rdma_queue_codec_test.sv`, `tests/unit/rdma_ud_urc_sqe_codec_test.sv`。

**Interfaces:** Add model field `bit [54:0] sgb_pa` (encoded address `PA >> 9`), copy/validate, and RQE qword4 encode/decode.

- [ ] **Step 1: Write RED** — set aligned physical `sgb_pa` semantic value and assert raw qword4 `[63:9]`; add low-9-bit misalignment and >55-bit shifted overflow tests with null decode output.
- [ ] **Step 2: Run RED** — `scripts/run_vcs53.sh core rdma_queue_codec_test`; expected reserved-bit failure or absent field.
- [ ] **Step 3: Implement** — add a width-checked model field; encode `sgb_pa` to qword4 `[63:9]` using the exact shift, decode back with zero low bits; keep qword3/qword5-7 reserved masks unchanged.
- [ ] **Step 4: Run GREEN** — `scripts/run_vcs53.sh core rdma_queue_codec_test` and `scripts/run_vcs53.sh core rdma_ud_urc_sqe_codec_test`; verify raw bytes, detached copy and malformed rejection.
- [ ] **Step 5: Commit** — `git add src/codec/rdma/rdma_queue_codecs.sv src/codec/rdma/rdma_defs.svh tests/unit/rdma_queue_codec_test.sv tests/unit/rdma_ud_urc_sqe_codec_test.sv && git commit -m "fix: encode RQE SGB physical address"`。

### Task 3: CQE header/qword2 fields (I1)

**Files:**
- Modify: `src/codec/rdma/rdma_queue_codecs.sv`, `src/codec/rdma/rdma_defs.svh` if constants are absent。
- Test: `tests/unit/rdma_queue_codec_test.sv`, `tests/integration/rdma_queue_data_engine_poll_test.sv`。

**Interfaces:** Extend `rdma_hw_cqe_model` with QP state, SRFQ/SE/sign enable, VLAN/IPv6/CQE format/resize/UD-MC, RC syndrome, UD source QPN, RQE completion, SRFQN/wrap/index.

- [ ] **Step 1: Write RED** — inject raw qword0/qword2 valid bits from `wr.h:123-149`; assert current reserved checker rejects; include RC, UD, RQ and resize variants.
- [ ] **Step 2: Run RED** — `scripts/run_vcs53.sh core rdma_queue_codec_test`; expected reserved-bit failures.
- [ ] **Step 3: Implement** — add typed fields, copy/validate, exact per-profile masks and encode/decode macros relative to Task1 base; reject profile-inapplicable fields rather than silently dropping them.
- [ ] **Step 4: Run GREEN** — queue codec and queue-data poll tests; compare raw words and detached model values, including reserved negatives.
- [ ] **Step 5: Commit** — `git add src/codec/rdma/rdma_queue_codecs.sv src/codec/rdma/rdma_defs.svh tests/unit/rdma_queue_codec_test.sv tests/integration/rdma_queue_data_engine_poll_test.sv && git commit -m "fix: model CQE header and completion fields"`。

### Task 4: CEQE URC/abnormal fields (I2)

**Files:**
- Modify: `src/codec/rdma/rdma_queue_codecs.sv`。
- Test: `tests/unit/rdma_queue_codec_test.sv`, `tests/unit/rdma_eq_engine_test.sv`, `tests/unit/rdma_queue_data_engine_final_fix_test.sv`。

**Interfaces:** Add CEQE URC flag, SQ/RQ valid bits and qword1 abnormal type/remote ecode/WQE and hardware completion index fields; preserve RC CI fields.

- [ ] **Step 1: Write RED** — construct URC and abnormal CEQE raw words from `defs.h:64-85`; assert current reserved mask rejects.
- [ ] **Step 2: Run RED** — `scripts/run_vcs53.sh core rdma_queue_codec_test`; expected URC/abnormal reserved failure.
- [ ] **Step 3: Implement** — extend model/copy/validate and exact qword masks; if URC is intentionally unsupported, return explicit unsupported-profile status and test that branch instead of reserved error.
- [ ] **Step 4: Run GREEN** — run queue codec, EQ engine and final-fix tests; verify RC and URC raw positions and detached event propagation.
- [ ] **Step 5: Commit** — `git add src/codec/rdma/rdma_queue_codecs.sv tests/unit/rdma_queue_codec_test.sv tests/unit/rdma_eq_engine_test.sv tests/unit/rdma_queue_data_engine_final_fix_test.sv && git commit -m "fix: decode CEQE URC fields"`。

### Task 5: AEQE abnormal/URC fields (I3)

**Files:**
- Modify: `src/codec/rdma/rdma_queue_codecs.sv`。
- Test: `tests/unit/rdma_queue_codec_test.sv`, `tests/unit/rdma_eq_engine_test.sv`, `tests/unit/rdma_queue_data_engine_final_fix_test.sv`。

**Interfaces:** Add AEQE SRFQ_EN/overflow/URC/CQ-invalid/abnormal type, CQN/EQN high/low, remote ecode, SRFQN/index; expose recombination helper using shift 6.

- [ ] **Step 1: Write RED** — raw images with each flag and split CQN/EQN values; assert current reserved failure and wrong/no-shift behavior.
- [ ] **Step 2: Run RED** — `scripts/run_vcs53.sh core rdma_queue_codec_test`; expected failures on nonzero fields.
- [ ] **Step 3: Implement** — encode/decode exact masks; retain high/low wire fields and calculate logical ID as `high | (low << 6)` only through a documented helper; reject overflow/unknown values.
- [ ] **Step 4: Run GREEN** — queue codec, EQ engine and final-fix tests with max split values and detached snapshots.
- [ ] **Step 5: Commit** — `git add src/codec/rdma/rdma_queue_codecs.sv tests/unit/rdma_queue_codec_test.sv tests/unit/rdma_eq_engine_test.sv tests/unit/rdma_queue_data_engine_final_fix_test.sv && git commit -m "fix: decode AEQE abnormal fields"`。

### Task 6: CQ notify doorbell invalid flags (I4)

**Files:**
- Modify: `src/codec/rdma/rdma_doorbell_codecs.sv`, `src/codec/rdma/rdma_defs.svh` if constants are absent。
- Test: `tests/unit/rdma_doorbell_codec_test.sv`, `tests/unit/rdma_cq_engine_test.sv`。

**Interfaces:** Add `ci_invalid` and `arm_invalid` model bits; encode/decode bits63/62; keep ARM_DB_FLAG bit61 and RC/URC CI coordinates unchanged.

- [ ] **Step 1: Write RED** — set each invalid flag independently for RC/UD and URC variants; assert raw bit63/62 currently cannot round-trip.
- [ ] **Step 2: Run RED** — `scripts/run_vcs53.sh core rdma_doorbell_codec_test`; expected field loss/reserved failure.
- [ ] **Step 3: Implement** — add fields to constructor/copy/validate and exact masks; preserve CQ DB offset `0x2018` and variant-specific CI widths.
- [ ] **Step 4: Run GREEN** — doorbell and CQ engine tests, including unknown/overflow rejection and raw offset assertion.
- [ ] **Step 5: Commit** — `git add src/codec/rdma/rdma_doorbell_codecs.sv src/codec/rdma/rdma_defs.svh tests/unit/rdma_doorbell_codec_test.sv tests/unit/rdma_cq_engine_test.sv && git commit -m "fix: encode CQ doorbell invalid flags"`。

### Task 7: QPC runtime shadow readback (I5)

**Files:**
- Modify: `src/codec/rdma/rdma_qpc_codecs.sv`, `src/codec/rdma/rdma_defs.svh` if a shadow constant/model field is needed。
- Test: `tests/unit/rdma_qpc_codec_test.sv`。

**Interfaces:** Add explicit readback shadow policy (detached `shadow_bytes[8]` or documented ignored bytes); keep create/modify encode zero/deny semantics.

- [ ] **Step 1: Write RED** — build a 512B readback image with nonzero bytes504-511; assert current decode returns private-reserved error; separately assert write model cannot publish nonzero shadow.
- [ ] **Step 2: Run RED** — `scripts/run_vcs53.sh core rdma_qpc_codec_test`; expected qword63 rejection.
- [ ] **Step 3: Implement** — make `validate_qpc_decode_mask` permit only qword63 shadow readback policy; keep `validate_qpc_encode_mask` requiring zero/absent shadow authorship; copy shadow into detached output if modeled.
- [ ] **Step 4: Run GREEN** — qpc codec test plus CQC baseline (`rdma_cmq_codec_test`, `rdma_cqe_size_codec_test`); verify all RC/UD/URC masks remain strict.
- [ ] **Step 5: Commit** — `git add src/codec/rdma/rdma_qpc_codecs.sv src/codec/rdma/rdma_defs.svh tests/unit/rdma_qpc_codec_test.sv && git commit -m "fix: separate QPC shadow readback policy"`。

## Final verification

- [ ] Run `scripts/run_vcs53.sh core rdma_cmq_codec_test` (CQC baseline).
- [ ] Run `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`.
- [ ] Run `scripts/run_vcs53.sh core rdma_queue_codec_test`.
- [ ] Run `scripts/run_vcs53.sh core rdma_doorbell_codec_test`.
- [ ] Run `scripts/run_vcs53.sh core rdma_qpc_codec_test`.
- [ ] Run `scripts/run_vcs53.sh core rdma_eq_engine_test` and the seven concrete
  tests registered by `tests/unit/rdma_queue_data_engine_final_fix_test.sv`:
  `rdma_queue_host_codec_final_fix_test`,
  `rdma_queue_producer_doorbell_final_fix_test`,
  `rdma_queue_cqe_codec_final_fix_test`,
  `rdma_queue_entry_image_final_fix_test`,
  `rdma_queue_ceqe_codec_final_fix_test`,
  `rdma_queue_aeqe_codec_final_fix_test`, and
  `rdma_queue_recovery_lifecycle_final_fix_test`. The source filename is not a
  registered UVM test name and must not be passed as `+UVM_TESTNAME`.
- [ ] Run `git diff --check` and the repository SV style checker against changed files; inspect file headers and every function's Chinese three-part comments.
