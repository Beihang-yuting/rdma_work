# Batch140：KEY_ALLOC legacy CMQ execution seam

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批 `src/core/rdma_control_plane.sv` 当前源码 SHA-256：
`5b317d4b2b98358522fadc6ea41c7fac8c1c92ea11bf7a01d0c02f1ed96862ff`。

## 实现边界

在 Batch138 的 control-plane seam 基础上，本批把最后一个 `KEY_ALLOC` direct
consumer 也迁移到 `execute_control_command()`。该调用使用
`detached_status=0`，因此保留原始 backend status 引用和原有
`status == null || !status.ok()`、timeout ticket、recovery/rollback 分支；helper
仍统一负责 ticket/completion 清空、CMQ/command guard 和单次 `cmq.execute()`。

当前 `rdma_control_plane.sv`、`rdma_qp_lifecycle_executor.sv` 与
`rdma_queue_lifecycle_executor.sv` 均只在各自 helper 内保留一处 compatibility
`cmq.execute()`，三个 consumer 文件不再包含 direct dispatch call site。此批仍未
切换到 `execute_observed()`，也未改变 ticket/completion alias、legacy accessor 或
recovery effect 语义。

## 验证

以下 VCS 仿真均在 `ubuntu@10.11.10.53` 登录 bash 的最终源码边界执行：

```text
SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test
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

本批只消除 KEY_ALLOC 的 direct dispatch 重复入口；`detached_status=0` 是为保持
特殊路径的 status identity 而显式保留的兼容开关，不代表 observed-result 已接入。
三个 helper 内部的 legacy execute、`last_execute_no_submit_proven`、ticket/completion
所有权审计、legacy descriptor、完整 ambiguity/recovery 组合和 parent/core/integration
全回归仍开放，计划继续保持 `active`。
