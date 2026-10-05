# Batch139：QP lifecycle legacy CMQ execution seam

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批 `src/core/rdma_qp_lifecycle_executor.sv` 当前源码 SHA-256：
`a05282231593a4ed576d2317064bcbe8839127836ceef4f72595320b4e01541b`。

## 实现边界

新增受保护 task `execute_qp_legacy_command()`，只负责 QP lifecycle 各阶段共有的
legacy raw dispatch：清空本次 ticket/completion/status，校验 CMQ/command 的最低
输入条件，并调用一次 `cmq.execute()`。它刻意不执行 generation fence、ambiguity
分类、completion 校验、timeout 解释或资源状态提交；这些语义继续留在调用方。

以下五个调用点改为复用该入口：

- QP presence query；
- QPC_CREATE；
- QPC_MODIFY（保留 completion.ticket fallback 后再分类）；
- recovery QPC_QUERY；
- 已有 `execute_terminal_command()` 的 rollback/terminal dispatch。

因此 QP 文件的 direct legacy dispatch 只剩 helper 内一处。该变化仍是兼容
normalization seam，不是 `execute_observed()` 迁移，也不改变 `last_execute_no_submit_proven`
或 ticket/completion 的 alias/ownership 语义。

清空 status 还使后端未写入 status 的 hostile adapter 结果归一为调用方既有
`normalize_status()` 的 fail-closed 分支，不会沿用前一阶段的成功对象；该边界不改变
正常 backend 的 timeout、completion 或 recovery 分类。

## 验证

以下 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash，在包含本批 helper 的最终源码边界执行：

```text
SSHPASS=123 scripts/run_vcs53.sh core rdma_qp_lifecycle_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_qp_recovery_test
```

两项均 compile/elab/link、PROCESS、LOGICAL PASS；每项 UVM 摘要为
`INFO=3 / WARNING=0 / ERROR=0 / FATAL=0`，report pristine。

本地静态门禁通过：

```text
git diff --check
python3 tools/check_changed_sv_style.py --base HEAD
python3 tools/check_rdma_profile_names.py
python3 tools/check_queue_lifecycle.py
```

## 保留的边界

本批只收束 raw legacy dispatch 的重复初始化/调用，不改变各阶段的 timeout、
ambiguity、generation fence、completion 缺失和 recovery 优先级。control-plane 的
KEY_ALLOC 仍是唯一未收束的 consumer direct call；control-plane/QP/queue 各 helper
内部的一次兼容 `cmq.execute()` 仍保留。完整 observed-result 迁移、detached
ticket/completion ownership、legacy descriptor、跨组件并发与完整 parent/core/integration
regression 仍开放，计划继续保持 `active`。
