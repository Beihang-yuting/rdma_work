# Batch136：legacy rollback CMQ execution seam

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

## 实现边界

本批只整理 `src/core/rdma_queue_lifecycle_executor.sv` 的重复结果归一化逻辑，不改变
CMQ backend 或外部依赖。`execute_queue_command()` 继续保留 legacy `cmq.execute()` 兼容
入口，但把 ticket/completion/status/ambiguity 的初始化、null-status 归一化和 completion
缺失判断集中到一个受保护 task；新增可选诊断消息，使不同 rollback 阶段仍保留原始错误
上下文。

`rollback_created()` 的 pre-delete flush、delete、post-delete flush 三个 consumer
改用该 helper。三处调用故意传入空 binding/owner：原有 `live_binding_fence()` 的
post-execute checkpoint 和失败即返回位置保持不变，因此 generation/reset 变化不会被
helper 提前吞掉。`create_locked()` 和 `destroy_locked()` 的其余 legacy consumer 尚未
迁移，避免本批扩大行为边界。

## 验证

以下命令均通过 `ubuntu@10.11.10.53` 登录 bash 执行：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_recovery_test
```

两项均 compile/elab/link、PROCESS/LOGICAL PASS，UVM 均为
`INFO=3/WARNING=0/ERROR=0/FATAL=0`。本地 `git diff --check`、
`python3 tools/check_changed_sv_style.py --base HEAD`、queue/profile 门禁也通过。

## 结论与遗留边界

本批关闭的是 rollback 三处同构 legacy 结果处理的局部结构重复；它不是
`execute_observed()` 全量迁移。CMQ control-plane、QP lifecycle 与 queue lifecycle
其它 legacy consumer、跨线程/跨进程锁、timeout/ambiguous 组合和完整 parent regression
仍保持 OPEN。计划继续保持 `active`。
