# Batch145：host-producer route/epoch admission 收缩

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批最终源码 SHA-256：
`dde548fb979c0dd1e694651031edc2acb469766e57d2d9f221673001016bb431`。

## 实现边界

Batch144 已将 reservation 之后的 WQE 写回、producer doorbell、ledger commit 和
result/recovery 尾段收束到 `complete_host_producer_tail()`，但 `post_send()` 仍没有在
reservation 前复核 attachment 的 Function route/reset epoch，而 `post_recv()` 自己保留
了一份相同的 route-check→reserve 顺序。本批新增受保护的
`reserve_host_producer_cursor()`，把两步 admission 收束为一个无 Host-memory/MMIO
副作用的入口：

1. 先调用 `validate_attachment_route_epoch()`，比较 attachment 冻结的 route/epoch 与
   当前 binding identity；
2. 仅在 authority 仍有效时调用一次 `runtime.reserve_producer()`；
3. 失败时清空 detached cursor（包括 runtime 返回 null status 的 fault path），不创建
   pending、不写 backing、不发 doorbell，也不改 producer ledger。

`post_send()` 在 `sqe_authority_status()` 之后、首次 producer reservation 之前使用该
   helper；`post_recv()` 在已有 owner/target 检查之后复用同一入口。这样保留了 caller
   特有的 request/owner/SRQ route 失败优先级，同时消除了 send/receive 两处重复的
   route/epoch→reserve 编排。helper 不取得 queue、backing、request 或 handle 的外部
   生命周期所有权。

## 失败与正向证据

`rdma_queue_data_engine_post_test` 新增 `check_send_route_epoch_authority()`：fixture
先建立合法 RC SQ，再把 binding reset epoch 从 `1` 推进到 `2`，调用 `post_send()`，并
断言返回 `RDMA_SC_STALE_GENERATION`、result 为空、SQ producer/consumer cursor 与
used/pending 不变，Host-memory 和 PCIe 调用计数也不增加。该用例覆盖 direct queue-data
API，不依赖 facade 的额外 gate。

## 验证

以下命令均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_post_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_poll_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS；UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |

本地静态门禁：

- `git diff --check`：通过；
- changed-SV style、profile naming、queue lifecycle、Phase-1A：通过；
- Python unit：292/292，`OK`；
- 全目录中文契约/文件头 scanner：185 个 `.sv`、2 个 `.svh`，共 5,440 methods
  （`.sv` 5,438、`.svh` 2），0 diagnostics。

## 保留的边界

本批只收束 host-producer 的 route/epoch admission 与 cursor reservation，并关闭
`post_send()` 的 stale-epoch 直接 API 缺口；它不建立跨队列全局锁，也不解决 reservation
之后的 route 变化窗口。WQE/doorbell/commit hostile failure matrix、SRQ 全生命周期、
legacy descriptor、poll/recovery 组合、CQ→WQ 跨队列并发、snapshot 后 alias 和最终
ownership 审计仍开放，计划继续保持 `active`。
