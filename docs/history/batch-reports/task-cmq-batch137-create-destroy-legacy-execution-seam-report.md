# Batch137：create/destroy legacy CMQ execution seam

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批 executor 源码 SHA-256：
`3f797603eae3ee43eb55cb6abd321e4d197caf04578afe43a631940a0d3bf202`。

## 实现边界

在 Batch136 已收束 rollback 三处重复逻辑后，本批继续把
`rdma_queue_lifecycle_executor.sv` 的 `create_locked()` 和 `destroy_locked()` 中剩余三
处直接 `cmq.execute()` 调用改为复用 `execute_queue_command()`。helper 仍是兼容
legacy `execute()` 的单一归一化入口，不改变 backend、`execute_observed()` 契约或外部
依赖。

每个调用点都把原阶段诊断消息显式传入；调用方仍在 helper 返回后执行原来的
`live_binding_fence()`，因此 create 的 retain/rollback 分支、destroy 的 flush/delete
ambiguity 分类、completion 缺失处理和 manager progress 提交顺序保持不变。当前该文件
的直接 `cmq.execute()` 仅剩 helper 内部一处；这不等于三个 Phase 1B consumer 已经迁移
到 `execute_observed()`。

跨三个 legacy consumer 类别仍有 11 个直接调用点（control-plane 6、QP lifecycle 5）；
它们的 observed-result 迁移仍需按各自的 timeout、rollback 和 recovery 语义分批验证。

## 验证

以下命令均通过 `ubuntu@10.11.10.53` 登录 bash：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_recovery_test
```

两项均 rc=0，compile/elab/link、PROCESS/LOGICAL PASS，UVM 均为
`INFO=3/WARNING=0/ERROR=0/FATAL=0`；`git diff --check`、changed-SV style、queue/profile
门禁通过。

## 结论与遗留边界

本批关闭 queue lifecycle executor 内 direct legacy execution 的重复调用点，保留
兼容入口以便后续逐个把 control-plane、QP lifecycle 和 queue lifecycle consumer 迁移
到 observed result。跨线程/跨进程锁、timeout/ambiguous 组合、完整 parent regression
和最终 ownership/中文契约复审仍开放，计划继续保持 `active`。
