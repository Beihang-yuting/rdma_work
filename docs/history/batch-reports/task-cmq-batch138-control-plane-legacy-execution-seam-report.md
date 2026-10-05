# Batch138：control-plane legacy CMQ execution seam

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批 `src/core/rdma_control_plane.sv` 当前源码 SHA-256：
`6c07f158ba417fbffd62568bb3a94a17b21447e2b45f965ab7c79e68476493bb`。

## 实现边界

本批继续收缩 Phase 1B 的 legacy CMQ consumer，但不把 legacy `execute()` 误报为
`execute_observed()` 迁移。新增受保护 task `execute_control_command()`，统一完成
一次 `cmq.execute()`、ticket/completion 清空和 `checked_status()` detached status
归一化；当 CMQ 引用缺失或 command 为空时 fail-closed 返回对应错误。以下五个同构
调用点改为复用该入口：

- `rollback_mr_creation()` 的 MR_DEREGISTER 回滚；
- `deregister_mr()` 的 OCC_FLUSH、MR_DEREGISTER、TQ_FLUSH 三个阶段；
- `execute_recovery_hardware_step()` 的恢复硬件步骤。

各调用方仍在 helper 返回后执行原有 timeout、ticket、generation fence、恢复记录、
ACTIVE 回滚和资源释放分支；helper 不推断 ambiguity、不重试、不推进生命周期游标。
`alloc_and_register_mr()` 的 KEY_ALLOC 调用暂时保留 direct `cmq.execute()`，因为其
成功路径与 timeout→recovery/rollback 分支对原始 status 对象的处理不同，需另批设计。
因此 control-plane 当前仅剩 helper 内一处兼容 direct call 加 KEY_ALLOC 一处，尚未
切换到 observed-result/ detached ticket-completion 所有权模型。

## 验证

以下 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash 执行：

```text
SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test
```

两项均 compile/elab/link、PROCESS、LOGICAL PASS；每项 UVM 摘要为
`INFO=3 / WARNING=0 / ERROR=0 / FATAL=0`，report pristine。

本地门禁通过：

```text
git diff --check
python3 tools/check_changed_sv_style.py --base HEAD
python3 tools/check_rdma_profile_names.py
python3 tools/check_queue_lifecycle.py
python3 -m unittest discover -s tests/unit -p 'test_*.py' -q  # 292 tests, OK
```

## 保留的边界

本批只做兼容入口去重和 fail-closed 输入保护；不改变 `execute_observed()` 的
submission/attempt effect、completion phase、observation status 或 recovery-required
语义，不删除 `last_execute_no_submit_proven`。QP lifecycle 的五处 direct call、control
plane 的 KEY_ALLOC、legacy descriptor、ticket/completion alias 审计、跨阶段 ambiguity
矩阵和完整 parent/core/integration regression 仍开放。总体结构重构计划继续保持
`active`，本批不构成全局 Phase 1B 完成。
