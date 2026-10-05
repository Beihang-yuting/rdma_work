# Batch181：MMIO evidence policy 收束与 AMBIGUOUS 全方向矩阵

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标与边界

Batch175 已经建立 MMIO evidence 的迁移表，但 policy 与 runtime transaction models
混在同一文件，且只由 runtime 场景间接覆盖。 本批把无状态规则迁移到独立的
`src/core/rdma_queue_mmio_transition_policy.sv`，并用 detached matrix 直接验证
consumer/device producer 两个方向的 AMBIGUOUS、NO_SUBMIT、SUCCESS、
NOT_APPLICABLE 和 confirmation 边界。runtime 仍是唯一的 mutable evidence、lock、
pending 和 retry-confirmation owner。

## 实现

- `rdma_queue_mmio_transition_policy` 保留原 `decide()` 契约，独立文件只依赖
  `rdma_queue_mmio_evidence_e`，不持有 queue、resource、pending、adapter 或 MMIO 引用。
- `rdma_core_pkg.sv` 在 runtime value models 之后显式 include 新 policy；原 runtime
  的普通 recovery/noalloc caller 无需改变调用点或状态副作用。
- `rdma_queue_runtime_test` 增加 13 个 policy matrix case，覆盖 consumer 的
  `NONE→AMBIGUOUS`、AMBIGUOUS 终态/不可升级、NO_SUBMIT confirmation，device 的
  写入前置条件和 `NO_SUBMIT→NOT_APPLICABLE` confirmation，以及拒绝路径不消费授权。

## 验证

- VCS53 登录 bash：
  `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_runtime_test`
  编译、PROCESS、LOGICAL 均 PASS，UVM warning/error/fatal 为 0/0/0。
- 同一源码边界的 core regression 已完成；所有已观察的 PROCESS/LOGICAL 用例均 PASS，
  最后一项 `rdma_cq_shadow_flush_test` 亦为 PASS，未捕获 UVM warning/error/fatal。
- 后续提交前仍需重新执行 Python 全量门禁、changed-SV style、`git diff --check` 和
  parent/integration regression，避免把旧边界证据冒充当前工作树结果。

## 未关闭项

SRQ 全生命周期与跨资源 destroy dependency、跨队列/跨线程并发、SQD/SQE drain/flush、
legacy descriptor、外部 PCIe/Host-memory ordering/error/backpressure、manager 外部调用
窗口补偿、Phase-1C F2 canonical authority 和最终 ownership/中文契约审计继续 OPEN；项目
计划保持 `active`。
