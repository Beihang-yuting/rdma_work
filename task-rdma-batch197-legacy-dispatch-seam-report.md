# Batch197：legacy CMQ raw dispatch 公共边界

## 变更

- 新增 `src/core/rdma_cmq_legacy_dispatch.sv`，提供无状态
  `rdma_cmq_dispatch_legacy_raw()`：统一清空 `ticket/completion/status`、检查
  `cmq/command`、调用一次 `cmq.execute()`。
- `rdma_control_plane::execute_control_command_raw_status()`、
  `rdma_queue_lifecycle_executor::execute_queue_command()` 和
  `rdma_qp_lifecycle_executor::execute_qp_legacy_command()` 复用该边界。
- 公共 helper 不处理 null-status 归一化、completion 完整性、generation fence 或
  ambiguity；这些语义仍由各自 owner 负责。队列原有 `cmq==null || command==null`
  的 `INVALID_ARGUMENT` guard 与控制面/QP 的错误码、文案保持不变。

## 所有权与业务不变式

- helper 不拥有 CMQ、command、ticket、completion、status，也不创建第二份 ledger、
  lock 或 recovery journal。
- 每个 caller 仍负责自己的 post-execute fence、status clone、completion 检查、
  timeout/late/ambiguity 分类和资源提交顺序。
- 本批只去除重复 dispatch 样板，不改变 CMQ 调用次数、外部 I/O 顺序、错误优先级、
  reset/recovery 语义或资源生命周期。

## 验证

- `rdma_control_plane_test`：VCS53 PROCESS/LOGICAL PASS，UVM warning/error/fatal
  `0/0/0`。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check HEAD`：PASS。

完整 core/integration regression 与最终门禁在本轮收尾阶段继续执行；本报告不把单项
focused GREEN 解读为项目级重构完成。
