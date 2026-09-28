# Batch164：queue runtime detached value models

日期：2026-09-24。基线工作树：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标与边界

本批继续执行项目级结构重构计划 Phase C，将 `rdma_queue_runtime.sv` 中与 mutable
owner 无关的值模型独立出来。目标是降低 runtime 入口的阅读噪声，明确“值模型”和
“唯一账本 owner”的边界；不改变 reservation、pending/recovery、slot ledger、lock、
route/epoch 或外部 adapter 的业务顺序。

## 实现

- 新增 `src/core/rdma_queue_runtime_transaction_models.sv`，集中定义 runtime 专用的
  state/kind/recovery/MMIO 枚举，以及 `rdma_queue_cursor_snapshot`、
  `rdma_queue_pending_operation`、`rdma_queue_slot_ledger_entry`。
- `rdma_queue_runtime.sv` 删除上述 detached value model 定义，只保留 attachment、
  PI/CI、occupancy、reservation、slot/pending publication、recovery gate 和 semaphore
  的唯一 mutable owner；文件从约 5,073 行收缩到 4,760 行。
- `rdma_core_pkg.sv` 按依赖顺序先 include transaction models，再 include runtime；既有
  runtime、queue-data engine、facade 和测试继续通过相同类型/API 访问。
- `do_copy()` 的兼容语义保持原样：pending 的 queue/cursor/image/status 建立局部值对象，
  `request_snapshot/routed_qp_h` 仍是兼容的非拥有引用；关键 recovery 深拷贝仍由 runtime
  的 non-fatal clone helper 负责。新文件不访问 runtime lock、账本、Host-memory、PCIe
  或外部 adapter。

## 所有权与行为复审

- runtime 仍是 `slots[]`、`pending_operation_state`、device reservation、cursor mutation、
  attachment route/epoch 和 lock 的唯一 mutable owner；新文件没有第二份 ledger 或缓存。
- cursor 的 index+wrap、pending 的 MMIO/shadow/recovery phase、slot 的 posted/consumed
  状态均为 detached transaction evidence，未改变恢复时的 identity、geometry、completion
  或 reset-epoch 验证。
- package include 顺序只前移类型定义，不新增 import/cycle，也不改错误码、状态迁移、
  外部调用窗口或生命周期释放责任。

## 验证

- VCS53 登录 bash：`rdma_queue_runtime_test`、`rdma_queue_data_engine_post_test`、
  `rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_recovery_test` 均
  PROCESS/LOGICAL PASS，UVM `WARNING=0/ERROR=0/FATAL=0`。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：293/293 PASS。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS；`git diff --check`：PASS。
- 全目录中文契约/文件头 scanner：192 个 `.sv`、2 个 `.svh`，5,502 个 function/task，
  0 diagnostics。

## 未关闭边界

本批不宣称关闭 runtime 的跨队列/跨线程并发、SRQ 全生命周期、reset 统一验收、外部
ordering/error、manager 外部调用窗口补偿或最终 ownership 审计；项目级计划继续保持
`active`。
