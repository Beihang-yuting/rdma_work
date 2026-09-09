# Task 3 实现报告

## 变更

- 在 `rdma_queue_backing_access` 增加 `write_device(offset, data, backend_write_started)`。
- 新增跨 span 方向权限、预检原子性和 backend 进入标志测试辅助 task，并在现有 focused test 中调用。

## 验证

- RED：`PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_backing_access_test`；按预期因缺少 `write_device` 编译失败（同时暴露了并行 Task 1 尚未完成的 runtime 测试接口错误）。
- GREEN：待 Task 1 runtime 接口完成后在 VCS53 登录 bash 环境重跑 focused test，并记录真实结果。
- `git diff --check -- src/core/rdma_queue_backing_access.sv tests/unit/rdma_queue_backing_access_test.sv`：通过。

## 风险

预检仅覆盖 mapping/check_access 与 span 几何；Host-memory adapter 的短写契约仍由上层 readback 的长度比较负责。backend 在第二个 span 失败时，首个 span 已按接口契约写入，调用方需依据返回状态决定恢复策略。
