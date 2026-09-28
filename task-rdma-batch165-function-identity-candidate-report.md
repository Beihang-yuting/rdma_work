# Batch165：Function identity candidate seam

日期：2026-09-24。基线工作树：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标与边界

本批继续执行 Phase C 的 resource-manager factory 收缩，处理 Batch163 保留的
`create_function()` 专用路径。Function 创建同时维护 generation binding、local Function ID、
incarnation registry 和 release tombstone，不能把这些语义粗暴并入普通对象 serial allocator；
本批只把它的 reserve/rollback 证据收束为专用 candidate。

## 实现

- `rdma_resource_transaction_models.sv` 新增 `rdma_function_identity_candidate`，保存 detached
  owner、handle、trusted binding、owner key、local ID、free-list 来源和首次 binding registration
  标记；candidate 不访问 registry、generation ledger 或外部对象。
- `rdma_resource_manager.sv` 新增 `reserve_function_identity_candidate()` 和
  `rollback_function_identity_candidate()`，复用原有 binding context、generation/tombstone
  admission、local-ID allocator 与 registration rollback 逻辑。
- `create_function()` 现在与普通创建入口采用同样清晰的
  `reserve candidate → construct → register/publish → clear` 形状，但保留 Function 独有的
  duplicate incarnation、older generation、released tombstone 和 binding projection 顺序；
  已发布 Function 仍只能通过正常 finalize/release API 结束生命周期。

## 行为与所有权复审

- Function generation/high-water、retired generation、binding snapshot 和 incarnation owner
  仍由 `rdma_resource_manager` 唯一拥有；candidate 只在未发布窗口存活。
- reserve 失败或构造、binding projection、registry publication 失败时，candidate 恢复
  local ID 与首次 registration；不会删除已有 tombstone、registry、outstanding 或 recovery
  记录，也不改变错误优先级。
- 普通 resource candidate 的 `kind != FUNCTION` 约束保持不变，避免通过一个 nullable 分支
  混淆普通 serial 和 Function incarnation 语义。

## 验证

- VCS53 登录 bash：`rdma_resource_manager_test`、`rdma_control_plane_test` 和
  `rdma_queue_lifecycle_test` 均 PROCESS/LOGICAL PASS，UVM
  `WARNING=0/ERROR=0/FATAL=0`。
- `git diff --check`、changed-SV style 通过；全目录中文契约 scanner 为 192 个 `.sv`、
  2 个 `.svh`，5,507 个 function/task，0 diagnostics。

## 未关闭边界

本批不关闭 allocator/registry 并发、跨 incarnation destroy dependency、QP/SRQ 组合生命
周期、queue runtime snapshot、reset 统一验收、manager 外部调用窗口补偿或最终 ownership
审计；项目级计划继续保持 `active`。
