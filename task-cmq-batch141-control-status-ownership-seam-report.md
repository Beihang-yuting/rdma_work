# Batch141：control-plane status ownership seam

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批 `src/core/rdma_control_plane.sv` 当前源码 SHA-256：
`c50b305eb0a3da0489870c3496056fe381f0cf7248fd5956149befd7947de0b5`。

## 实现边界

Batch140 为 KEY_ALLOC 保留了 `detached_status=0` 布尔开关。该开关让同一个入口
同时承担 raw backend status 和 detached clone 两种 ownership，调用点容易误读。
本批将它拆成两个显式阶段：

- `execute_control_command_raw_status()` 只负责 CMQ/command fail-closed guard、
  ticket/completion 初始化和一次 `cmq.execute()`，保留 backend 原始 status identity；
- `execute_control_command()` 复用 raw seam，再统一调用 `checked_status()` 生成
  detached status，供 MR rollback、deregister 和 recovery hardware-step 路径使用。

KEY_ALLOC 改为显式调用 raw seam，并在原调用点继续执行既有 null-status 归一化、timeout
ticket、recovery/rollback 和 generation 检查。没有改变 dispatch 次数、ticket/completion
生命周期、失败优先级或资源状态提交，也没有迁移到 `execute_observed()`。

## 验证

以下 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash，在包含本批 helper 的最终源码边界
执行：

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
python3 -m unittest discover -s tests/unit -p 'test_*.py'   # 292 tests, OK
```

## 保留的边界

本批只澄清 raw/detached status ownership，不改变 legacy CMQ compatibility seam 的
生命周期或错误语义；三个 consumer helper 内仍各保留一次兼容 `cmq.execute()`。
`execute_observed()` 全量迁移、detached ticket/completion ownership、legacy descriptor、
跨组件并发和完整 parent/core/integration regression 仍开放，计划继续保持 `active`。
