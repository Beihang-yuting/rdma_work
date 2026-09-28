# Batch202：borrowed ring 单角色策略

日期：2026-09-25

## 目标

CQ、CEQ、AEQ 的 borrowed ring backing 都需要验证“至少一个 slice，且所有 slice
属于同一 ring role”。此前三处 preflight 各自维护 null、空集合和错误 role 分支，
容易在后续业务扩展时出现错误码或边界条件漂移。本批只提取这个纯值 admission，
不改变队列生命周期执行顺序。

## 实现

- 新增 `src/core/rdma_queue_borrowed_role_policy.sv`。
- `validate_single_role()` 接收 detached `rdma_queue_backing_spec`、期望 role 和两条
  诊断文本，统一处理 null spec、null slice、错误 role、空 slice 以及重复合法 role。
- CQ/CEQ/AEQ preflight 改为调用该策略；各 caller 继续拥有 authority、vector、PD
  dependency、ring layout、backing clone 和 publication 顺序。
- 删除 `rdma_queue_lifecycle_policy` 中重复的 `backing_role_count()`，没有新增 ledger、
  lock 或外部 backing 所有权。

## 验证

- `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：PROCESS PASS，LOGICAL PASS，
  UVM warning/error/fatal `0/0/0`。
- `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common scripts/run_vcs53.sh integration rdma_dpu_integration_test`：
  wrapper rc=0，UVM warning/error/fatal `0/0/0`。
- Python unit tests：`293/293 PASS`。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `python3 tools/check_queue_lifecycle.py`：PASS。
- `python3 tools/check_rdma_profile_names.py`：PASS。
- `python3 tools/check_rdma_phase1a_approval.py`：APPROVED。
- `git diff --check HEAD`：PASS。

## 范围与遗留

本批只关闭 CQ/CEQ/AEQ borrowed-role 纯值校验的重复实现，不关闭 allocator/registry
跨线程或跨进程互斥、manager 外部调用窗口、SRQ 完整 create/post/recovery/destroy
组合、跨 queue/engine 全局原子性、SQD/SQE drain/flush、legacy descriptor、PCIe
ordering/error/backpressure、Phase-1C F2 whole-plan 或最终 ownership/生命周期注释审计。
项目级结构重构计划继续保持 `active`。
