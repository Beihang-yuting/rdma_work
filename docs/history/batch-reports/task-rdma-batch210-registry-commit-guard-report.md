# Batch210：resource manager registry replacement commit guard

## 本批范围

新增 `rdma_resource_manager::commit_registry_replacement()`，把以下最终 registry 写回
统一为 detached validation → identity recheck → mutation guard → publication epoch 的
短事务窗口：

- `stage_allocated()`；
- `attach_cq_programming()` / `attach_qp_programming()`；
- `commit_programmed()` / `activate()`；
- `begin_quiesce()` / `begin_cq_resize()` / `replace_active_cq()`；
- `commit_qp_semantic_state()`。

helper 只在最终写回阶段持有 `mutation_guard`，不在 factory/clone/adapter callback 中持锁；
staged 标志只能沿一个方向变化，并在成功写回时推进 `publication_epoch`。QP programmed
reconciliation、QP ERROR/recovery 和 queue progress 的 registry+recovery 双账本路径继续
使用各自的专用事务，未强行合并不同业务所有权。

## 验证证据

- VCS53 登录 bash：`rdma_resource_manager_test` PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL `0/0/0`；随后 core regression `97/97` PROCESS PASS、全部
  LOGICAL PASS、UVM `0/0/0`；锁定 `/home/ubuntu/deps_virtio/dpu_common` 快照上的
  integration regression `10/10` 均 UVM pristine。
- 证据日志：`/tmp/rdma_batch210_resource_manager.log`、
  `/tmp/rdma_batch210_core_regression.log`、`/tmp/rdma_batch210_integration_regression.log`。
- Batch209 后的 Python 293/293、style、queue/profile/Phase-1A、manifest/keyword 与
  diff gates 保持通过；随后重新执行 core regression，确认跨 queue/QP/control-plane
  调用窗口不受影响。

## 后续开放项

本批只统一部分 registry replacement commit seam，不关闭 allocator/registry 跨线程或
跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期组合、跨 queue/engine 原子性、
SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2
whole-plan 或最终 ownership 审计；项目级计划继续保持 `active`。
