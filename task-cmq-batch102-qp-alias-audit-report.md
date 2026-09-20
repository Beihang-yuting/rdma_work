# CMQ Batch 102：QP/queue lifecycle dynamic-array alias 审计

本批针对结构重构计划中遗留的
`initialize_plan`/`build_recovery` dynamic-array alias 风险进行代码边界审计。
符号实际位于 `src/core/rdma_queue_lifecycle_executor.sv`；QP 对应的恢复
构造路径位于 `src/core/rdma_qp_lifecycle_executor.sv` 的
`make_create_recovery`、`make_modify_recovery` 和 `destroy_locked`。本批没有
把普通 UVM `clone()` 强行替换到这些路径：mapping/context 中包含 opaque
release/completion authority，必须由 resource manager 的 authority-aware
projector 建立持久快照。已同步修正相关函数/task 的中文三段契约注释，使
“临时浅借用”与“持久 detached projection”边界可审查。

## 结论

这些赋值复制的是独立的 queue/array 容器，但容器元素为 class handle，因此
元素对象仍然共享；这不是最终账本的 detached copy，而是仅允许在紧随其后的
manager admission 前存在的 transient view。

| 路径 | 当前复制语义 | 生命周期与允许动作 | 持久化边界 |
| --- | --- | --- | --- |
| `rdma_queue_lifecycle_executor::initialize_plan`（源码 388–414 行） | `rings`、`refs`、`flush_targets` 的 queue shell 被复制，元素 handle 仍借用 `authoritative_plan`；`context_ref` 明确置空 | planner 只读取 plan 元数据并向 Host-memory 写 payload/PD；不得在该局部调用之外保存 view，也不得把通用 clone 当成 release authority | 不进入 registry；authoritative plan 继续由 caller/manager 持有 |
| `rdma_queue_lifecycle_executor::build_recovery`（源码 596–745 行） | `completed_steps`/`pending_steps` 是 enum 值复制；`rollback_statuses` 的 status handle，以及 `queue_plan` 内 rings/refs/flush/context handle 暂借输入 | 仅作为 `manager.mark_error` 的只读 carrier；交付前 caller 不得修改、并发访问或跨 task 保存 | `rdma_resource_manager::project_recovery_value`（1661–1773 行）先逐项 project status，再调用 `project_queue_plan_value`；之后才可由 registry/recovery API 返回 |
| `rdma_qp_lifecycle_executor::make_create_recovery`（源码 1722–1759 行） | `candidate_qpc`、`qp_plan`、`context_ref`、`staging_mapping` 为借用 handle；opcode/ticket 使用显式 clone | 仅供随后的 `mark_qp_error`；不释放、不修改 backing 或 QPC | `project_qp_recovery_value`（2821–2898 行）使用 `project_qpc_value`、`project_qp_plan_value`、`project_queue_context_value` 与 mapping authority hook |
| `rdma_qp_lifecycle_executor::make_modify_recovery`（源码 1761–1808 行） | prior/candidate QPC、authoritative plan/context、staging/query mapping 为借用 handle；`query_mapping_recovery_only` 保留语义位 | ticketless/ambiguous 证据仍必须先交 manager；不能用 generic plan clone 代替 recovery-only mapping clone | 同上；query mapping 按 `query_mapping_recovery_only` 分流到 `clone_recovery_mapping_value` 或 owned authority clone |
| `rdma_qp_lifecycle_executor::destroy_locked`（源码约 2940–2954 行） | ERROR/flush/delete 失败时直接把当前 `qp.qp_plan`/`context_ref` 挂到 transient recovery shell | 每个硬件/cleanup milestone 先由 manager 记录；shell 只在 `mark_qp_error` 调用期间有效 | `mark_qp_error` 的 recovery projection 与后续 `lookup_recovery` detached snapshot |

## 为什么不做“最小 deep-clone 修复”

1. `rdma_queue_backing_plan::do_copy` 和 `rdma_qp_backing_plan::do_copy`（`src/model/rdma_queue_lifecycle_models.sv`）会递归调用 mapping 的普通
   `clone()`。这能隔离字段，却不能证明 adapter 私有 allocation token、
   release completion 或 recovery-only opaque capability 仍然等价。
2. 队列 planner 的初始化 view 必须把原 mapping 交给 `host_mem.write`；把
   mapping 换成未经 authority hook 认证的 generic clone，可能导致真实 adapter
   的 allocation lookup/release 失败，或者把“值相等”误当成“同一释放能力”。
3. QP recovery 的 `query_mapping_recovery_only` 明确要求走
   `clone_recovery_mapping_value`，而 owned mapping 要走
   `clone_owned_mapping_value`；这两条路径会检查类型、值、detached handle 与
   completion authority。绕过它们在 executor 中 clone 会破坏释放/恢复语义。
4. transient shell 没有暴露给 registry：`manager.mark_error`/
   `manager.mark_qp_error` 在提交前执行 authority-aware projection，失败则不
     发布账本。因而在当前生命周期顺序下，直接浅借用是有明确边界的；真正应
     加强的是禁止越过 admission 保存 shell，而不是盲目复制对象图。

## Authority-aware projector 证据

- `src/core/rdma_resource_manager.sv:1941–1987`：队列 backing ref 依据
  ownership 选择 `clone_owned_mapping_value` 或 `project_mapping_value`，并逐个
  project additional segment。
- `src/core/rdma_resource_manager.sv:2024–2061`：queue context 复制 owner、slot
  token、HMC，并验证 token 的 opaque `completion_authority` 保持相同。
- `src/core/rdma_resource_manager.sv:2295–2363`：QP plan 逐字段构造 detached
  rings/refs/URC refs/context，不把 source queue element handle 放入结果。
- `src/core/rdma_resource_manager.sv:2821–2898`：QP recovery 依据 mapping
  recovery-only 标志选择正确的 authority hook；所有失败都清空 output。
- `src/core/rdma_resource_manager.sv:1661–1773`：queue recovery 的
  rollback status 逐项 `project_status_value`，随后才写入 detached queue plan。

## 测试与回归证据

现有 focused 测试已经覆盖“持久投影不别名”而不是错误地把 transient shell 当作
独立 owner：

- `tests/unit/rdma_queue_lifecycle_test.sv:3908–3911` 断言 registry 返回的
  `recovery.queue_plan` 不等于 active `queue.queue_plan`；同一 task 在
  3939–3993 行检查每个 owned/borrowed mapping、segment、release completion 和
  context cleanup authority。
- `tests/unit/rdma_qp_lifecycle_test.sv:2051–2070` 断言持久 QP plan 的 borrowed
  slices 不等于 caller mapping，并检查主 mapping 与 segment owner 均绑定到同一
  QP；这证明 detached publication 后不能借由 caller alias 改写 authority。
- `tests/unit/rdma_qp_recovery_test.sv:284–299` 从 manager 返回的 detached
  recovery snapshot 注入 forged owner/geometry，`validate()` 分别拒绝
  `RDMA_SC_INVALID_STATE` 与 `RDMA_SC_INVALID_ARGUMENT`。
- Batch 99 同一源码边界的 `rdma_queue_lifecycle_test`、
  `rdma_queue_recovery_test` focused wrapper 均为 PROCESS/LOGICAL 1/1、UVM
  warning/error/fatal 0/0/0；日志分别为
  `evidence/post-batch99-rdma_queue_lifecycle_test.log`（SHA-256
  `4d3c1f57bab4e09a921278d699959ab539a2a3303272121c136949afc3758c00`）和
  `evidence/post-batch99-rdma_queue_recovery_test.log`（SHA-256
  `a2ad552735881eb7ad8d2c128aba64964d5fcbbd1ab932777155e42849eb8`）。
- 同一边界的 parent CMQ gate 与 core regression 已分别达到 28/28 与 95/95，
  无 warning/error/fatal；最终日志 SHA-256 为
  `f8ee6a4ae9e2802c2eebf9d7c69a2103ba678d7f605adf57072efc74ff3f7283` 与
  `c59989807df0feb7cc92e9b34cf0640190c7f0b521e864e7cff130e0e8a7a30b`。

本批没有新增仿真 test：只同步了契约注释，未改变运行时行为；上述 focused/core/
CMQ 证据用于确认审计边界对应的 authority projection 仍为 GREEN。

## 开放风险与后续约束

- 若未来 planner 或 recovery builder 需要修改 plan element 字段，应新增显式
  “保留 mapping authority 的 wrapper projection” helper，并先证明每个 nested
  mapping/context 的 opaque capability 等价，再改变浅借用语义。
- 若要把 transient shell 异步排队，必须新增 immutable value contract 或在
  manager 内完成 projection 后再排队；禁止把当前 `queue_plan`/`qp_plan` handle
  直接放入跨 task registry。
- Batch 102 不关闭 reset 跨 context 原子 rebuild、Phase 1C F2 或 `pcie_work`
  外部依赖锁；结构重构计划仍保持 active。
