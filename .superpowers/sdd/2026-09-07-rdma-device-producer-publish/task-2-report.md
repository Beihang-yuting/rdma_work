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

## RQE SGB_PA 驱动证据（Task 2 补充）

本次 RQE 编码修复以 10.11.10.53 上锁定的
`dpu_kernel_rdma-version_0.1.34/wr.h` 为唯一布局来源：

- `wr.h:171` 定义 `XTRDMA_RQ_SGB_PA_SHIFT 9`，因此软件物理地址必须
  512B 对齐，wire 值为 `physical_pa >> 9`。
- `wr.h:172` 定义 RQE SGE 区从 byte 32 开始；`wr.h:188` 定义
  `XTRDMA_QP_RQ_SGB_PA GENMASK_ULL(63, 9)`，对应 qword4 的 `[63:9]`、
  LSB 9、宽度 55。qword4 `[8:0]` 仍为 reserved。
- `hw/rdma/source_manifest.txt:10-11` 已用 `XTRDMA_RQE_*`/
  `XTRDMA_QP_RQ_*` 覆盖该符号，驱动 tarball SHA-256 未改变，因此本次
  不修改 source manifest。

`tools/check_rdma_profile_names.py` 同时登记 `XTRDMA_QP_RQ_SGB_PA` 的
字段映射、独立坐标参考和 `rqe_boundary` golden；SV 单测覆盖物理地址对齐、
55 位编码边界、detached decode/copy，以及 qword4 低 9 位非零时拒绝并保持
输出 model 为 `null`。
