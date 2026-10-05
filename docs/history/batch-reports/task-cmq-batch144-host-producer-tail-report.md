# Batch144：SQ/RQ/SRQ host-producer completion tail seam

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批 `src/core/rdma_queue_data_engine.sv` 当前源码 SHA-256：
`1dfe2bf1038d2fe847e801e4f5eaad837b649c00f0efd9733427b5c448af7388`。

## 实现边界

`post_send()` 与 `post_recv()` 在 producer reservation、model 编码以及（SQ 的）
外部 SGB 写入之后，原先分别维护同一段 WQE 写回、readback、producer doorbell、ledger
commit、result 构造和 recovery pending 逻辑。本批提取
`complete_host_producer_tail()`，统一 reservation 成功后的尾段顺序：

1. 调用 `write_and_verify()` 写入并读回冻结的 WQE image；
2. 按冻结 cursor 计算 next cursor，并调用 `submit_producer_doorbell()`；
3. 调用 `attachment.runtime.commit_producer()` 提交 PI/used/ledger；
4. 成功时构造 detached `rdma_queue_post_result`，失败时保留原阶段 status 和
   recovery evidence。

SQ 的 `write_sgb_and_verify()` 仍由 `post_send()` 在 helper 之前独占执行；helper 只
接管 SQ/RQ/SRQ 共用的 WQE write/readback、doorbell、producer commit 和结果构造尾段。
它不取得 queue、backing、request 或 handle 的外部生命周期所有权。

失败语义保持原有优先级：WQE 写回/读回失败尝试安装 `NO_SUBMIT` pending，doorbell
或 producer commit 失败尝试安装 `AMBIGUOUS` evidence，pending clone 失败返回
`RESOURCE_EXHAUSTED`；recovery 调用失败不会覆盖首个阶段 status。SQ shadow gate
返回 `status=OK` 且 `doorbell_result=null` 时仍继续 producer commit。

helper 的输入是 caller 冻结的 attachment、queue handle、runtime kind、reserved
cursor、image、semantic request snapshot、`wr_id`/`signaled`、可选 SQ doorbell image
和 local id。它本身不重新证明 attachment、queue handle、runtime kind、cursor 与
reservation 的对应关系，也不新增 route/epoch admission。`post_recv()` 在 reservation
前保留显式 `validate_attachment_route_epoch()`；本批不把 `post_send()` 的既有
`lookup_attachment()`/`sqe_authority_status()` 路径描述成独立 route/epoch gate，
该更细的发送路径复核仍是后续边界。

## 验证

以下 VCS 仿真均在 `ubuntu@10.11.10.53` 登录 bash、最终源码边界执行：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_post_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_poll_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS；UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |

静态门禁同样通过：changed-SV style、`git diff --check`、queue lifecycle checker、
profile naming、Phase-1A checks，以及 Python unit 292/292 `OK`。全目录中文契约
scanner 使用 `sanitize_source`/`method_ranges`/`check_method_comments`/
`check_file_header` 扫描 `src/`、`tests/`、`sim/` 的 185 个 `.sv` 与 2 个 `.svh`，
共 5,438 methods（`.sv` 5,436、`.svh` 2），0 diagnostics。

## 保留的边界

本批只收束 host-producer reservation 后的重复尾段，不新增 reservation/authority
校验，也不宣称完成发送路径的显式 route/epoch 全覆盖。WQE/doorbell/commit fault 的
完整 hostile 组合、SRQ 全生命周期、legacy descriptor、跨队列并发、engine-level
全局锁、snapshot 后 alias 和最终 ownership 审计仍开放；计划继续保持 `active`。
