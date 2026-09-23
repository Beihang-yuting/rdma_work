# Batch155：EQ facade operation envelope 收缩

日期：2026-09-23。工作树：`feature/rdma-structural-refactor-batch155`，基线：
`8b8ad4e`。

本批只收束 `rdma_eq_engine` 五个 public task 重复的配置/Function authority admission
和 delegate null-status 处理。CEQ/AEQ consumer、legacy producer 与带 secondary
authority producer 的 typed delegate 调用仍分别显式可见；重构计划继续保持
`active`。

## 代码收缩与可读性边界

- 新增受保护、非 virtual、无 I/O 的 `validate_operation_authority()`，统一
  `configured/delegate` 门禁、冻结 Function UID/generation/reset epoch、ACTIVE
  binding、`binding.validate()` 及 authority null-status 归一化的原有顺序。
- 新增受保护、非 virtual、无 I/O 的 `normalize_delegate_status()`，只把 delegate
  返回的 null status 转成带 task 名的 `RDMA_SC_INVALID_STATE`；非空成功/失败 status
  保留同一对象、code 和 message。
- `poll_ceqe()`、`poll_aeqe()`、`publish_ceqe()`、`publish_aeqe()` 与
  `publish_aeqe_with_secondary()` 仍各自调用类型化 delegate；没有引入 enum/bit
  dispatch、宽泛可选参数或隐藏的 producer/consumer 分派。
- 五个 wrapper 都先清空 typed result，authority 通过后才调用 delegate；delegate
  失败时再次清空未认证 result。`OK + result=null` 仍是合法返回，不会被归一化为失败。

生产源码 `src/core/rdma_eq_engine.sv` 从 327 行降至 272 行，净减少 55 行。为锁定
精确消息、sentinel 清理与 status 句柄身份，`tests/unit/rdma_eq_engine_test.sv` 从
1,093 行增至 1,147 行；两文件合计从 1,420 行降至 1,419 行。这里把生产入口的重复
复杂度下降作为主要收益，不用删除边界断言换取表面行数。

## 行为与所有权审计

逐入口复核保持以下顺序和可观察契约：

1. 未配置或 delegate 缺失先返回固定 `EQ facade is not configured`，不会调用 live
   authority 或 delegate。
2. 配置后先比较冻结的 Function UID/generation/reset epoch，再检查 binding ACTIVE
   状态和 `validate()`；stale incarnation 仍优先返回 `RDMA_SC_STALE_GENERATION`。
3. authority 成功后，各 wrapper 才显式调用原 delegate task。delegate null status
   使用原 task 名生成精确诊断；非空失败 status 句柄原样返回。
4. pre-admission 或 delegate 失败均清空 typed result；成功路径不要求 result 非空。

测试新增/加强了五个未配置入口的非空 sentinel 清理和固定消息、五条 delegate
null-status 精确消息，以及五条非空失败 status 的对象身份、code/message 与夹带 result
清理。reset epoch 漂移后的五个 delegate counter 仍保持不变，证明 authority 拒绝发生在
任何 event read/publish/doorbell 副作用之前。

本批没有移动 route、timeout retry、runtime/backing/cursor、Host-memory、MMIO、
recovery 或 ledger 所有权；CEQ/AEQ route 和 producer/consumer 副作用仍归共享
queue-data engine。CQ-flush secondary authority 也没有与 legacy AEQE 路径合并。

## 验证

全部 VCS 仿真通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

| Entry | Result | 日志 SHA-256 |
| --- | --- | --- |
| `rdma_eq_engine_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `97e0fa12529ac91ed5eaaed9781684788b89a98e4d3eb2a0cb34dd12f43ed342` |
| `rdma_queue_data_engine_poll_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `dd6ec3926973da702823ccdd9059882aaf2cc5591ee8374b02f4b9aa2413539e` |
| `rdma_queue_event_route_consume_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `418b230e399ef41c83138803a2066cffc9f7ae74e31866e00f03875751e81a03` |
| `rdma_aeqe_route_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `4c0225f48f77789414f741b9be9a15fa8f7eaec8eb87e98dcd1483f335567a08` |

本地 `git diff --check`、changed-SV style（base=`8b8ad4e`）、queue lifecycle、profile
naming、Phase-1A approval 与 Python unit 292/292 均通过。全目录中文契约/文件头 scanner
覆盖 189 个文件（187 `.sv`、2 `.svh`），共 5,467 methods（`.sv` 5,465、`.svh`
2），0 diagnostics。

最终文件 SHA-256：

- `src/core/rdma_eq_engine.sv`：
  `b77be477a41858b1ff624318214141fd0fe4fee3b39249ae79f9eda2a4b96d26`
- `tests/unit/rdma_eq_engine_test.sv`：
  `8bcb7a88df5aaf9be6daf5b0f1f2eb3ea7ceee54409b33aef245bef3c2e6fbfc`

## 未关闭边界

本批 focused GREEN 不等于整份结构重构完成。CEQ/AEQ malformed retry、route-miss/
doorbell-failure recovery exactly-once、SRQ 全生命周期、legacy descriptor、跨队列并发、
外部 PCIe error/ordering、engine-level 全局锁、全目录最终 ownership 审计和广义 F2
仍保持开放；计划状态继续为 `active`。
