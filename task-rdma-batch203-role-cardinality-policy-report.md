# Batch203：queue role cardinality policy

日期：2026-09-25

## 目标

resource manager 的 queue flush progress 和 cleanup progress 都需要先确认 role 在
detached plan 中恰好出现一次。原实现分别扫描 `flush_targets` 和 `refs`，两段循环的
null/计数/index 语义相同但容易漂移。本批只抽取扫描规则，不移动 manager 的 ledger
读取或 progress commit。

## 实现

- 新增 `src/core/rdma_queue_role_cardinality_policy.sv`，提供无状态
  `count_flush_targets()` 与 `count_backing_refs()`。
- `rdma_resource_manager::queue_flush_role_count()` 和 `queue_ref_role_count()` 保留
  兼容 wrapper，改为转发公共 policy；manager 继续唯一拥有 registry、recovery、
  allocator、lock-free commit 点和外部 backing 生命周期。
- `rdma_resource_manager_test` 增加 null/empty/single/duplicate/null-element 矩阵，
  直接锁定 cardinality 与最后命中 index 的契约。

## 验证

- `scripts/run_vcs53.sh core rdma_resource_manager_test`：PROCESS PASS，LOGICAL PASS，
  UVM warning/error/fatal `0/0/0`。
- `scripts/run_vcs53.sh core regression`：97/97 PROCESS PASS、80/80 LOGICAL PASS，所有
  UVM summary 均 warning/error/fatal `0/0/0`。
- `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common scripts/run_vcs53.sh integration regression`：
  10/10 integration tests 完成，10/10 UVM report pristine，warning/error/fatal `0/0/0`。
- Python unit tests：`293/293 PASS`。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `python3 tools/check_queue_lifecycle.py`：PASS。
- `python3 tools/check_rdma_profile_names.py`：PASS。
- `python3 tools/check_rdma_phase1a_approval.py`：APPROVED。
- `git diff --check HEAD`：PASS。

## 范围与遗留

本批只关闭 queue plan role-cardinality 扫描重复，不关闭 allocator/registry 跨线程或
跨进程互斥、manager 外部调用窗口、SRQ 完整生命周期、跨 queue/engine 全局原子性、
SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2
whole-plan 或最终 ownership/生命周期注释审计。项目计划继续保持 `active`。
