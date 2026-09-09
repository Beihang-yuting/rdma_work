# Task 1 报告：device-producer runtime 基础状态

## 改动

- `rdma_queue_runtime` 增加 `host_produced`、device reservation 快照及状态化查询/极性 API。
- device CQ/CEQ/AEQ 配置按 PI/CI/wrap 重建初始 occupancy；host ring 保持空 WQE ledger。
- 新增 reservation、commit、cancel 事务及 detached output；`peek_consumer` 在未提交/空 ring 时返回 `RDMA_SC_QUEUE_EMPTY`。
- 单测加入 reserve→visibility→commit 及 host/device producer 方向隔离场景。

## 验证

- Red：`PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_runtime_test`；基线因缺少 `reserve_device_producer`、`query_occupancy`、`commit_device_producer` API 编译失败。
- Green：同命令在 `ubuntu@10.11.10.53` 登录 bash 环境执行，VCS 编译/仿真成功；UVM Report Summary 为 `UVM_ERROR : 0`、`UVM_FATAL : 0`，`check_uvm_summary.sh` 报告 pristine。
- `git diff --check -- src/core/rdma_queue_runtime.sv tests/unit/rdma_queue_runtime_test.sv` 无输出（通过）。

## 剩余风险

- device reservation 的写入后 recovery evidence 由后续 queue-data engine 任务安装；runtime 目前仅在 pending 标记存在时拒绝 cancel。
- 共享工作树包含其他任务改动；本任务仅提交 runtime 与对应单测文件。
