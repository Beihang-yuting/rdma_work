# RDMA Batch200：resource allocator pure-value policy

日期：2026-09-25

## 目标

继续 Phase C 的 allocator/factory 收缩，把资源 kind 合法集合和硬件 local-ID 宽度映射
从 `rdma_resource_manager` 的 mutable owner 文件中提取为无状态 policy。该批不移动
free-list、serial、binding、registry 或 generation 账本，也不改变任何 create/release 顺序。

## 实现

- 新增 `src/core/rdma_resource_allocator_policy.sv`，提供
  `valid_kind()` 与 `local_id_limit()` 两个纯值函数。
- `rdma_resource_manager` 保留兼容的 protected wrapper，内部只委托 policy；allocator
  reservation、回收、宽度拒绝和 publication epoch 仍由 manager 唯一拥有。
- `rdma_resource_manager_test` 增加合法 kind、PD/MR/CQ/QP/SRQ/CEQ/AEQ 宽度以及
  FUNCTION/CMQ fallback 矩阵，未知枚举 fail-closed。

## 验证

验证结果：

- VCS53 `rdma_resource_manager_test`：PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL=`0/0/0`。
- core regression 在本批源码同步前已完成，全部列出的 core test 为 PROCESS/LOGICAL PASS；
  同一 wrapper 进入 integration 前因远端 `DPU_COMMON_ROOT` 未设置被 preflight 拒绝，未将
  该环境缺口误记为源码回归。
- Python 全量单测 `293/293 PASS`；changed-SV style、queue/profile/Phase-1A gates 与
  `git diff --check` PASS。

## 未关闭边界

本批只收缩静态 allocator policy，不宣称关闭 registry 跨线程/跨进程互斥、manager 更广泛
外部调用窗口、SRQ 全生命周期组合、跨 queue/engine 并发、SQD/SQE drain/flush、legacy
descriptor、外部 ordering/error/backpressure、Phase-1C F2 whole-plan 或最终 ownership
审计；项目计划继续保持 `active`。
