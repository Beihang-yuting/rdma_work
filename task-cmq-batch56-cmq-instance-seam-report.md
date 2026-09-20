# CMQ Batch 56 — CMQ direct instance comparison seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树
中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批整理 `src/core/rdma_cmq_engine.sv` 中五个低风险 direct
`rdma_handle::same_instance()` 调用（共五次替换）。

### 变更

以下调用改为 engine 已有的 `same_handle(lhs, rhs)` seam：

- `ticket_has_engine_authority` 的 CMQ handle；
- `checked_slot_context_snapshot` 的 Function 与 CMQ handle；
- `checked_doorbell_desc_snapshot` 的 Function 与 target handle。

`same_handle` 委托 `rdma_cmq_same_handle_instance`，非空时再调用原
`lhs.same_instance(rhs)`。五处原有的显式 null gate、clone/self 检查、值字段检查、alias
检查、错误状态和短路顺序均保留。`snapshot_command_with_profile_locked` 中另一个
不同前置契约的 direct call 刻意留待后续批次。

## 结构审计与静态验证

- source-before/source-after SHA：
  `b95e6fed1a4f123677ec3813260d989549427c200dc15f6757d7b4e81f230cc9` /
  `38f8bcac37c21001c91f52c2e70362aa4ea68c36f5d889beda9c20065ec94e3f`；行数
  14213 → 14222；direct `.same_instance(` 从 6 处降为刻意保留的 1 处。
- source review、archive/current SHA 校验与 wrapper 边界记录于
  `evidence/batch56-source-review.log`、`evidence/batch56-archive-validation.log`。
- `git diff --check`：rc 0；changed-SV style：rc 0，仅既有
  `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_cmq_engine_test`：wrapper rc 0、PROCESS/LOGICAL 18/18、严格 UVM 0/0/0；
- `rdma_cmq_engine_models_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0；
- `rdma_cmq_completion_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无 gate
  FAIL，严格 UVM pristine 28/28。日志 SHA：
  `d227816ace475ee9307e237a47184e0bde0da0d4bb23c413748cc13c4df60546`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志
  `evidence/batch56-python.log`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志
  `evidence/batch56-manifest.log`。

## 交付边界

本批没有改变 CMQ authority、journal/ledger、factory clone、alias 拓扑、锁、状态迁移或
transport I/O。剩余 command snapshot direct seam、QDE handle-instance seam、queue-data
resize/reset、runtime 深层 recovery/MMIO 和 Phase 1C F2 仍留待后续批次；整份结构重构计划
尚未完成。
