# CMQ Batch 108：coordinator 跨环境 ownership / transaction 只读审计

本批是 Batch 107 后的只读架构审计，不修改生产代码或外部依赖。目标是明确为什么
当前 `m_reset_in_progress` 不能被扩大描述成 coordinator 全局锁，并把下一批需要先
决策的 ownership/transaction 契约固定下来。

## 已确认的可重入与别名 seam

- `rdma_device_env` 的 `m_reset_in_progress` 只覆盖同一 env 的四个 public
  `request_*_reset()` 入口。virtual `prepare_reset()` / `validate_reset_candidate()`
  callback 仍可直接调用公开的 `reset_coordinator.request_device_reset()` 或
  `commit_registration_atomic()`，也可通过另一个 env 共享同一 coordinator；outer
  candidate 的 expected epoch/count 随后可能与 coordinator ledger 分叉。
- callback 在 outer reset scope 中追加 registration 时，coordinator 会把新 Function
  纳入后续 epoch bump，但 selected context 集合已经冻结，存在“ledger 已推进、context
  未提交”的覆盖不一致。
- `commit_registration_atomic()` 会在成功尾部 attach/替换非拥有 Host router；
  `rdma_host_mem_router.attach_reset_coordinator()` 可被任意调用并允许 null 清除或换绑，
  没有 active mapping、owner token 或旧 coordinator 屏障。两个 coordinator 共享一个
  router 时，旧 coordinator 仍可推进该 router 的 local epoch，而 mapping 读取观察到的
  却可能是另一个 coordinator 的 epoch。
- 解绑 coordinator 后，router 的兼容读取把 coordinator 维度视为零；若 mapping 在
  zero epoch 创建，再 reset 后解绑，旧 mapping 存在重新通过逐维 stale 检查的风险。换绑
  到 epoch 偶合的另一个 coordinator 也不能仅凭数值区分 authority。
- 公开 `rdma_function_context.reset()` 不推进 coordinator ledger；若 callback 直接调用
  它，candidate fingerprint 可能仍引用旧 source 值图，随后 outer commit 覆盖 context
  更新，形成 direct-context 绕过 env transaction 的路径。

这些接口均为无 timing control 的 SystemVerilog function，因此本批不把问题描述成已实证
的 preemptive thread race；风险来自同步 callback 重入、公开 alias/rebind 和生命周期错配。

## 下一批必须先确定的契约

1. coordinator、device env、Host router 是严格一对一，还是允许显式 aggregate multi-env；
2. 覆盖 preflight→quiesce→candidate→epoch→commit 的 transaction lease/token 及 owner；
3. lease 期间 direct registration、attach/rebind、router detach、context.reset 的拒绝码和
   兼容入口；
4. detach/close/active mapping 的生命周期与回收顺序。

在这些选择确定前，简单增加一个 coordinator busy bit、局部 null 检查或额外 fingerprint
比较都会留下另一条绕过路径，且可能破坏既有 void/兼容 API。因此本批只记录 OPEN 边界，
不宣称全局并发/所有权已经收口，也不把 Batch 106/107 的 focused GREEN 扩大解释为完成。
