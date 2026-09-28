# Batch163：resource allocator/factory transaction seam

日期：2026-09-24。基线工作树：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标与边界

本批继续执行项目级结构重构计划 Phase C 的第一步：把资源创建入口中反复出现的
identity 预留结果和 rollback 参数收束为一个 detached transaction candidate。目标是
降低 `create_pd/create_mr/create_cq/create_qp/create_srq/create_cmq/create_ceq/create_aeq`
的局部状态噪声与参数错配风险，不改变 resource manager 的所有权边界。

本批没有把 allocator 或 registry 移到新对象中，也没有增加锁、缓存、第二份 outstanding
账本或外部资源所有权。`rdma_resource_manager` 仍是 `next_local_id`、`free_local_ids`、
`next_object_serial`、binding registration、registry 和 publication 的唯一 mutable owner；
candidate 只在一次 reserve→construct→register→publish/rollback 窗口内存在。

## 实现

- 新增 `src/core/rdma_resource_transaction_models.sv`，定义
  `rdma_resource_identity_candidate`，集中保存 `kind`、detached `owner/handle`、
  `local_id`、`prior_serial`、`used_free_id` 和 `registered_binding`。
- 新增 `valid()` 和 `clear()`：前者拒绝空 owner/handle、Function kind 或 handle-kind
  不一致的 partial candidate；后者只清除 transient 引用，不自动修改 manager 账本。
- `rdma_resource_manager.sv` 新增 `reserve_identity_candidate()` 和
  `rollback_identity_candidate()`。前者复用原 `reserve_identity()`，后者唯一调用原有
  `rollback_identity_reservation()`；因此 ID/serial/binding rollback 语义保持集中。
- 八条对象资源创建路径改用 candidate。成功发布后清除 candidate；project/register
  失败统一回滚 candidate。`create_function()` 保留独立的 Function 身份与 binding
  registration 路径，因为它同时建立 Function incarnation 和 tombstone 语义，未被泛化
  helper 强行合并。
- `rdma_core_pkg.sv` 按“transaction model 先于 manager”顺序 include 新文件。

## 所有权与可观察行为复审

- candidate 不写 registry，也不接触 `outstanding_ids`、recovery record、reset epoch 或
  外部 Host-memory/PCIe/net adapter。
- 创建入口的 authority/dependency 校验、local-ID 宽度、serial exhaustion、错误码、
  publication clone/cast 和 sequence 更新顺序保持原样。
- register 失败或依赖/字段投影失败时，candidate 统一恢复 local-ID、object serial 和
  首次 binding registration；已发布资源不能通过 candidate 回滚。
- `create_qp()` 的 sequence key 仍在 publication 成功后由已构造的 authoritative QP
  计算，避免 clear candidate 改变 QP incarnation 证据。

## 验证

以下命令均在 VCS53 登录 bash 环境执行：

- `SSHPASS=123 scripts/run_vcs53.sh core rdma_resource_manager_test`：PROCESS/LOGICAL
  PASS，UVM `WARNING=0/ERROR=0/FATAL=0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：PROCESS/LOGICAL
  PASS，UVM `WARNING=0/ERROR=0/FATAL=0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_qp_lifecycle_test`：PROCESS/LOGICAL PASS，
  UVM `WARNING=0/ERROR=0/FATAL=0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_qp_recovery_test`：PROCESS/LOGICAL PASS，
  UVM `WARNING=0/ERROR=0/FATAL=0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test`：PROCESS/LOGICAL PASS，
  UVM `WARNING=0/ERROR=0/FATAL=0`。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：293/293 PASS。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `python3 tools/check_queue_lifecycle.py`、`python3 tools/check_rdma_phase1a_approval.py`
  与 profile naming gate：PASS。
- `git diff --check`：PASS。

当前源码文件计数为 193（191 `.sv`、2 `.svh`），全目录 function/task 计数为 5,504
（`.sv` 5,502、`.svh` 2），0 diagnostics；本批新增 5 个带三段中文契约的方法。
项目级结构重构计划和覆盖矩阵继续保持 `active`，未宣称整项重构完成。

## 后续开放项

`create_function()` 的专用 allocator seam、allocator/registry 并发、跨 incarnation
destroy dependency、QP/SRQ 组合生命周期、queue runtime immutable snapshot、reset 统一
验收、manager 外部调用窗口补偿、跨队列并发和最终 ownership 审计仍需后续独立批次与证据。
