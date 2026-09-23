# Queue transaction/backing null-status hardening report

> 日期：2026-09-16  
> 范围：`rdma_queue_txn_evidence`、`rdma_queue_backing_access` 及其单元测试。  
> 驱动 ABI：未修改任何原始驱动字段、位坐标、mask、offset、opcode 或 ecode。

## 结论

四个可达的扩展边界已经改为 fail-closed：当可覆写的 `validate()` 返回空
`rdma_status` 时，入口返回确定的 `RDMA_SC_INVALID_STATE`，不发布部分 evidence，
不登记 backing，也不访问 Host-memory backend。

## 根因与测试契约

修复前的四条路径都先调用可覆写 `validate()`，随后直接执行 `status.ok()`：

| 入口 | 风险 | RED 场景 |
| --- | --- | --- |
| `rdma_queue_txn_evidence::capture_urc_shadow` | `rdma_cq_shadow_snapshot::validate()` 返回 null 后空句柄解引用 | `rdma_null_shadow_validate` |
| `rdma_queue_txn_evidence::capture_request` | `rdma_semantic_request::validate()` 返回 null 后空句柄解引用 | `rdma_null_request_validate` |
| `rdma_queue_backing_access::attach_queue` | queue backing 校验返回 null 后空句柄解引用 | `rdma_null_queue_backing_validate` |
| `rdma_queue_backing_access::attach_qp` | QP backing 校验返回 null 后空句柄解引用 | `rdma_null_qp_backing_validate` |

新增测试位于：

- `tests/unit/rdma_queue_txn_journal_test.sv`
- `tests/unit/rdma_queue_backing_access_test.sv`

每个故障注入场景都检查三项契约：返回状态非空且为
`RDMA_SC_INVALID_STATE`；失败前已有的 snapshot/attachment 不被替换；
backing 场景不产生 Host-memory backend 调用。queue/QP 场景随后再绑定一个合法
reference，确认失败不会污染 attachment slot。

由于本轮明确不启动新的 VCS 仿真，RED/GREEN 的动态结果留给 53 主机验证；
静态基线已确认修复前四处分别是 `status = ...validate();` 紧邻
`if (!status.ok())` 的空句柄风险。

## 生产修复

### `src/model/rdma_queue_txn_types.sv`

- `capture_urc_shadow`：在读取 shadow 游标前检查 `status == null`，返回
  `"URC CQ shadow validation returned null status"`。
- `capture_request`：在 clone request 前检查 `status == null`，返回
  `"semantic request validation returned null status"`。
- 两个函数的三段中文契约注释同步列出 null-status 边界。

### `src/core/rdma_queue_backing_access.sv`

- `attach_queue`：返回 `invalid_state("queue backing validation returned null status")`。
- `attach_qp`：返回 `invalid_state("QP backing validation returned null status")`。
- 两个函数的失败边界注释同步列出校验器 null 返回；成功路径和 mapping
  authority 检查保持不变。

## `resource_manager` 复审结果

本轮没有修改 `src/core/rdma_resource_manager.sv`。复审到的资源管理路径已经对
直接的 `validate()` 结果做 null 归一化（例如 staged/commit/activate、CQ
programming/resize/replacement 路径）。其 projection helper
`project_resource_value` 在统一出口检查 `status == null` 并生成带 operation
标签的 `RDMA_SC_INVALID_STATE`；`project_public_resource_value` 只消费该已归一化
结果。`update_qp_recovery_progress` 和 `retain_qp_query_mapping` 仍有三处
`replacement_record/recovery_copy.validate()` 的直接调用，但这些对象都是
projection helper 通过 `new` 创建的 concrete record，不是调用方可覆写的
`validate()` 实例；本轮将它们记录为后续故障注入审计点，没有为了形式统一引入
无证据改动。

## 只读验证

已执行的检查：

- `python3 -m py_compile tools/check_changed_sv_style.py tools/check_queue_lifecycle.py tools/check_rdma_field_ownership.py`
- `python3 -m unittest -v tests/unit/test_check_changed_sv_style.py`（12 tests passed）
- diff-aware SV style check on the four changed files（0 diagnostics）
- `git diff --check`（passed）
- source-level TDD probe：四个 `HEAD` 基线均确认
  `validate(); if (!status.ok())`（RED），当前源码均确认先做
  `status == null` guard 并返回对应诊断（GREEN）。

待在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

1. 编译并运行 `rdma_queue_txn_journal_test`，确认两个 null-status 场景不崩溃且
   返回 `RDMA_SC_INVALID_STATE`。
2. 编译并运行 `rdma_queue_backing_access_test`，确认 queue/QP 两个场景不触碰
   Host-memory backend，并验证合法 retry。
3. 运行 queue/core 回归，确认新增 guard 不改变正常 backing、snapshot 或驱动
   wire contract。
