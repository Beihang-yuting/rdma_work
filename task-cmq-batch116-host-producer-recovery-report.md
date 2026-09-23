# CMQ Batch 116：host-producer recovery 阶段提取

本批继续基于重构后的 queue-data engine 收敛恢复职责边界。`replay_pending()` 同时
处理 device-producer、host-producer 和 consumer evidence；其中 host-producer 路径
还混合了可选 SQ external-SGB 重建、WQE 写回、producer doorbell 和 runtime ledger
提交。它们共享 pending/cursor，但 DMA 方向、MMIO evidence 和提交所有权不同，继续
堆在一个 task 中会让恢复失败路径难以复审。本批只抽出 host-producer 阶段，不改变
外部依赖或把 device/consumer recovery 合并到同一 helper。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护的 `replay_host_producer_pending()` task，输入为已经由
    `replay_pending()` 校验过的 `attachment`、`pending` 和冻结的 `next` cursor；task
    不重新 reserve cursor、不重算 payload，也不取得 attachment、QP link、mapping 或
    backing 的所有权。
  - SQ pending 且 request snapshot 仍携带非零 `sgb_iova` 时，helper 先查找
    `qp_links`、执行 `make_sqe()`，再调用 `write_sgb_and_verify()`；随后按原顺序写入
    冻结的 `pending.image`，发一次 producer doorbell，开启 recovery commit，执行
    `commit_producer()`，最后完成 recovery retry。
  - `replay_pending()` 保留 device-producer 分支和完整 consumer 分支，只在
    `pending.producer` 时调用新 task；主 task 仍保留 consumer 使用的 `link` 与
    `db_result`，删除不再使用的 `sgb_model`/`pending_send` 局部变量。
  - helper 对模型构造、SGB/WQE 写回、doorbell、commit gate、producer commit 和
    completion 的 null status 统一 fail-closed 为 `RDMA_SC_RECOVERY_REQUIRED`；已有
    非空失败状态和 recovery evidence 优先级保持不变。

## 行为不变量

- `pending.image` 缺失仍返回 `RDMA_SC_INVALID_STATE`；SGB/WQE 写失败仍记录
  `RDMA_QUEUE_MMIO_NO_SUBMIT`，doorbell 失败仍记录
  `RDMA_QUEUE_MMIO_AMBIGUOUS`，producer commit 失败仍记录
  `RDMA_QUEUE_MMIO_SUCCESS`。任何失败都不推进新的 cursor，pending 继续由 runtime
  recovery 持有。
- host-producer helper 不处理 `device_producer` 或 consumer completion evidence；
  device recovery 仍使用 `write_device()`/readback，consumer recovery 仍保留 CQ route、
  completion release 和 shadow/MMIO 证据路径。
- SGB 只在原 pending 的 SQ request snapshot 可 cast 且 `sgb_iova.value != 0` 时重放；
  缺 snapshot 或非 SQ 类型的既有兼容路径仍直接使用冻结 WQE image，不新增 payload
  推导或 Host-memory 写入。
- 成功路径仍只写同一 detached entry、发一次 producer doorbell 并提交同一
  `pending.cursor`；helper 不重新调用 reserve，也不改变 route/epoch 或 ownership
  authority。

## 验证

所有 VCS 仿真均在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_recovery_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0；恢复 pending、未确认 retry、producer failure evidence 和 completion 路径通过 |
| `rdma_queue_data_engine_post_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0；SQ/RQ/SRQ posting 与既有 SGB writer 约束通过 |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `git diff --check` | PASS |
| `python3 -m unittest discover -s tests/unit -p 'test_*.py'` | 292 tests；OK（测试中预期的 synthetic git/CLI negative-path 输出不影响最终通过） |

VCS 命令使用既有入口：
`SSHPASS=123 scripts/run_vcs53.sh core <test>`。本批没有修改测试 fixture、外部
`host_mem_manager.sv` 或 `pcie_work`；pytest 仍受环境缺少 pytest 限制，不把它记为
业务失败或 GREEN。

## 源码指纹与遗留边界

- `src/core/rdma_queue_data_engine.sv` SHA-256：
  `c904ea70a87054a873a16040b8569375ada72e61bc5fbc9cba1f9e2ae470a36b`
- 计划状态继续为 `active`；本批关闭的是 host-producer recovery 的局部结构 seam，
  不宣称已完成完整 SRQ/跨队列 lifecycle、device/consumer recovery 全阶段组合、
  Phase 1C F2 whole-plan authority、coordinator 跨线程/跨进程并发或整份结构重构。
- `pcie_work` 的阻断文本仍必须保持：
  `external dependency is not approved: pcie_work`。
