# Batch154：CEQ/AEQ timeout 外壳收缩

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批只收束 `rdma_queue_data_engine` 中 `poll_ceqe()` 与 `poll_aeqe()` 重复的
deadline、`QUEUE_EMPTY` 重试、null-status 归一化和结果发布外壳。CEQE/AEQE 的
`*_once` 解码、owner/route、pending staging、doorbell、CI commit、recovery evidence
和 route-miss 语义保持各自独立；重构计划继续保持 `active`。

## 代码收缩

- 新增受保护 `poll_event_with_timeout()`，以 `is_aeq` 和诊断 `label` 选择
  `poll_ceqe_once()` 或 `poll_aeqe_once()`，集中实现 timeout=0 单次尝试、非零
  timeout 的 1ns `QUEUE_EMPTY` 重试、simulation-time overflow、null status 和
  `RDMA_SC_TIMEOUT` 返回。
- `poll_ceqe()` 与 `poll_aeqe()` 保留原 virtual public 入口，仅转发到 helper；调用方
  仍观察到原来的 CEQ/AEQ 错误消息前缀、result 清空契约和 detached result 语义。
- helper 不保存 event handle、不取得 runtime/ledger/backing/resource ownership，
  也不触碰 `poll_ceqe_once()`/`poll_aeqe_once()` 的首次 mutation、consumer doorbell
  或 recovery 流程。

## 行为审计

逐分支保持原 wrapper 顺序：初始化 `result/status` → deadline overflow 检查 → 单次
尝试 → null-status 归一化 → 非 `QUEUE_EMPTY` 或 zero-timeout 立即返回 → deadline
到期返回 timeout → `#1ns` 重试。`label="CEQ"`/`"AEQ"` 生成的诊断文本与原
wrapper 文本一致；唯一新增的是 `is_aeq` 仅选择单次入口，不改变下游状态机。

## 验证

VCS 仿真通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| Entry | Result |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_event_route_consume_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_aeqe_route_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_eq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`，覆盖 facade 非零 timeout/`RDMA_SC_TIMEOUT` 路径 |

四份日志均包含 `UVM report is pristine`、`PROCESS PASS` 和 `LOGICAL PASS`，wrapper
rc=0；日志 SHA-256 分别为：

- `5bf97a648b71b314e05b9e4c595f1621e772164b581c918f6f059681c5e53972`
- `32c982ee588c92f64183c8c684674909b7280c7ff521fec89301f3b7b49c6ce7`
- `57003654df1bee58cca4fb0053a2da9a7fa379a98dab106deac5d10113cf6e24`
- `74989ebace70c5f205f1a3cc5d80c36bbd0e099779466c8794be63453ef5d461`

本地静态门禁和全目录 scanner 已在三项 focused 稳定后补录；本批不宣称关闭 CEQ/AEQ
malformed retry、跨队列并发、SRQ 全生命周期、legacy descriptor、外部 PCIe
error/ordering、engine-level 全局锁或最终 ownership 审计。

`git diff --check`、changed-SV style、queue/profile/Phase-1A gates 和 Python 292/292
均通过；全目录 scanner 覆盖 189 个文件（187 `.sv`、2 `.svh`），5,465 methods
（`.sv` 5,463、`.svh` 2），0 diagnostics。

最终源码 SHA-256：

- `src/core/rdma_queue_data_engine.sv`：
  `09ba1abffcdd9e2a73e32d633948947bdea93ead1dd7129a0bfd278015568146`
