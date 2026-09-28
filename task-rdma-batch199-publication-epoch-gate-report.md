# Batch199：resource publication stage epoch gate

日期：2026-09-25

## 目标

继续 Phase C 的 resource transaction seam，覆盖 `stage_resource_publication()` 内部
外部 clone/factory 投影窗口。candidate 在第一次投影前捕获
`rdma_resource_manager::publication_epoch`，所有投影返回后再次检查该 epoch；如果
manager 在非拥有调用期间发生 allocator、registry、reservation 或 publication mutation，
stage 直接返回 `RDMA_SC_INVALID_STATE`，不把污染后的 detached 值交给 commit。

## 实现

- `rdma_resource_publication_candidate::manager_epoch` 现在明确表示 projection 开始时的
  manager mutation epoch，而非投影结束时重新采样的值。
- `stage_resource_publication()` 在第一次 `project_resource_value()` 前锁存 epoch，完成
  registry/published/owner/handle 四类投影后检查 epoch；检测到重入 mutation 时清除
  candidate 并返回 `"<copy_label> manager mutated during publication projection"`。
- `commit_resource_publication()` 保留 stage→commit stale epoch 检查、canonical key/identity
  校验和 duplicate incarnation 拒绝；成功提交后仍由 manager 唯一推进 epoch。
- `rdma_resource_identity_candidate` 与 Function 专用 identity candidate 同样保存 reserve
  完成后的 manager epoch；`publish_identity_candidate()` 和 `create_function()` 在构造
  authoritative resource 的窗口返回后拒绝 stale candidate，并先回滚 allocator/binding
  reservation，避免旧 reservation 与新 registry 拼接。
- Function 路径进一步通过 `publish_function_identity_candidate()` 统一 freshness、
  authoritative 完整性、registry publication 和失败回滚；create_function 只保留字段
  projection 与类型转换，未复制第二份 Function ledger。
- 测试 probe 增加 `observe_publication_epoch()`，publication stage/commit seam 验证
  candidate 捕获的 epoch 与 manager 当前 epoch 一致；另以 reserve→epoch mutation→publish
  验证普通及 Function stale identity 回滚；已有 concurrent create、hostile key/owner、
  duplicate commit 和 clear 后二次提交矩阵继续保留。

## 所有权与语义

candidate 仍是 detached 值，不拥有 registry、allocator、lock、adapter 或 backing；
`rdma_resource_manager` 仍是四份 publication ledger 的唯一 owner。epoch 只提供乐观
新鲜度证明，不构成跨线程互斥；真正的 allocator/registry 跨线程或跨进程并发仍是后续
开放项。业务错误码、registry publication 顺序和 Function 专用 generation/tombstone
路径未改变。

## 验证

- `scripts/run_vcs53.sh core rdma_resource_manager_test`：PROCESS PASS、LOGICAL PASS，
  UVM WARNING/ERROR/FATAL = `0/0/0`。
- `scripts/run_vcs53.sh core rdma_control_plane_test`：PROCESS/LOGICAL PASS，UVM `0/0/0`。
- `scripts/run_vcs53.sh core rdma_qp_lifecycle_test`：PROCESS/LOGICAL PASS，UVM `0/0/0`。
- `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：PROCESS/LOGICAL PASS，UVM `0/0/0`。
- Python 全量单测：293/293 PASS。
- `check_changed_sv_style.py`、`git diff --check`、queue lifecycle、profile naming、
  Phase-1A approval：全部 PASS。

## 未关闭范围

本批不宣称关闭 allocator/registry 真正跨线程或跨进程互斥、manager 更广泛外部调用窗口
补偿、SRQ 全生命周期、跨 queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、
外部 PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 或最终 ownership/中文
注释全目录审计；项目级计划继续保持 `active`。
