# Task 2 报告：runtime consumer/recovery 边界

## 改动

- pending operation 增加 device producer、写入/doorbell/CI/release 阶段位、MMIO evidence、failure/route/epoch 快照字段。
- 增加 `enter_recovery_prepared`、pending/state 查询、reservation 匹配和阶段标记接口；consumer commit 对 device ring 递减 occupancy，recovery/quiesce 保留 reservation 隔离。
- 单测覆盖 device credit、重复 reservation、pending quiesce、stale commit 与 abort 清理。

## 验证

- 计划 red/focused 命令：`PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_runtime_test`。
- 本轮命令未进入 runtime 编译/仿真：共享工作树的并行 codec 任务尚未提供 `rdma_hw_cqe_codec::encode_with_entry_bytes`，随后本次重试又因 VCS license server 暂不可用退出 255。
- `git diff --check -- src/core/rdma_queue_runtime.sv tests/unit/rdma_queue_runtime_test.sv` 无输出。

## 剩余风险

- `enter_recovery()` 仍沿用旧 UVM clone 路径，非 fatal 深拷贝闭环需后续补强。
- `configure()` 当前签名不携带 route/reset epoch，因此 `query_route_epoch()` 仅能在未来 authority 注入适配后报告有效快照。
