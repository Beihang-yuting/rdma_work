# Batch180：queue lifecycle opcode policy

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标与边界

queue lifecycle executor 在正常 create、query、delete、ambiguous recovery 和 queue
recovery 分支反复维护 CQ/SRQ/CEQ/AEQ 到 CMQ opcode 的同一张静态映射表。本批把该
纯值职责提取为 `src/core/rdma_queue_lifecycle_opcode_policy.sv`，不改变生命周期状态、
SRQ pre-delete flush、CQ post-delete flush、authority 检查或 commit 顺序。

## 实现

- 新增 `rdma_queue_lifecycle_opcode_policy`，提供 `create_opcode()`、`query_opcode()`、
  `delete_opcode()` 三个无状态静态函数。
- CQ/SRQ/CEQ/AEQ 分别映射到既有 CQC/SRFQC/CEQC/AEQC opcode；FUNCTION、PD、MR、QP、CMQ
  以及未知 kind fail-closed 为 `8'h00`。
- executor 保留兼容 wrapper，所有 caller 的函数名和错误路径不变；policy 不持有
  handle、owner、queue plan、recovery record、CMQ ticket 或外部 adapter 引用。
- `rdma_queue_lifecycle_models_test` 新增四类合法映射和 unsupported kind 拒绝断言。

## 验证

- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check`：PASS。
- VCS53 登录 bash：
  `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_models_test`
  编译、PROCESS、LOGICAL 均 PASS，UVM warning/error/fatal 为 0/0/0。
- 本批未改变外部依赖、CMQ manifest 或资源 owner；Python 与 parent regression 在提交前
  按当前工作树边界重新执行。

## 未关闭项

SRQ 全生命周期和 destroy dependency、跨队列/跨线程并发、SQD/SQE drain/flush、legacy
descriptor、外部 PCIe/Host-memory ordering/error/backpressure、manager 外部调用窗口补偿、
`RDMA_QUEUE_MMIO_AMBIGUOUS` 全方向不可重放证据、Phase-1C F2 canonical authority 和
最终 ownership/中文契约审计继续保持 OPEN；项目计划继续 `active`。
