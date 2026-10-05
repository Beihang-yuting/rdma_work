# Batch171：QP/SRQ 组合依赖快照

## 目标

继续收束 `rdma_resource_manager` 的生命周期 admission。此前 blocker snapshot 只输出
总 dependent 数量和 resource 自身 outstanding；CQ resize 仍需要重新遍历 registry 才能
区分“空闲 QP 允许继续引用 CQ”和“非 QP 或有在途操作的 dependent”。本批把这段组合
观察提升为 detached 值，不改变 registry、allocator、recovery 或外部资源所有权。

## 实现

- `rdma_resource_activity_blocker_snapshot` 新增 QP/SRQ 分类计数、非 QP 标志、dependent
  自身 outstanding 计数，以及 `has_qp_dependents_with_outstanding`。
- `snapshot_activity_blockers()` 仍是唯一读取 `registry` 与 `resource.outstanding_ids`
  的入口；分类只依据登记资源的完整 `handle.kind`，不从 QP/SRQ 业务字段重新推导关系。
- `begin_cq_resize()` 复用同一 detached snapshot：保留空闲 QP 引用 CQ 的既有允许语义，
  但对非 QP dependent 或携带 manager-visible outstanding 的 QP 原子拒绝。
- resource-manager dependency fixture 增加 PD→SRQ→QP hostile combination 断言，确认
  SRQ 的唯一 dependent 是 QP，PD 同时能报告 QP、SRQ 和其它 dependent 分类。

## 验证

- `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_resource_manager_test`
  - PROCESS PASS / LOGICAL PASS
  - UVM WARNING/ERROR/FATAL = 0/0/0
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check`：PASS。

本批没有复制 mutable registry/lock，也没有改变 QP/SRQ destroy 的提交 owner；项目级计划
继续保持 `active`，跨队列并发、SRQ 全生命周期、SQD/SQE drain/flush、外部 ordering/error
矩阵和最终 ownership 审计仍是开放项。
