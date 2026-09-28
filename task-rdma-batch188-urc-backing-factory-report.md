# Batch188：URC QP backing typed factory

日期：2026-09-24。工作树：`feature/rdma-cmq-structural-phase2-batch160`。

## 实现边界

本批把 `rdma_qp_lifecycle_executor::materialize_plan()` 中重复的 URC 内部 backing
分配分支收束为 `src/core/rdma_qp_urc_backing_policy.sv` 的无状态 typed factory。
factory 只返回 detached 的 role/length 规格，并固定 RSQ→RDSQ→DSQ 顺序及
4 KiB/4 KiB/8 KiB 几何；RC、UD 和未知 transport 返回空数组。

executor 仍调用原有 `allocate_ref()`，每个成功或失败返回的引用仍按原 partial-plan
顺序追加到 `plan.urc_refs`，因此已有释放、owner 绑定、Host-memory 生命周期和
recovery/rollback 账本没有转移或复制。该批没有改变 URC QPC 编码、transport admission
或外部依赖契约。

## 验证

- `SSHPASS=123 DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common HOST_MEM_ROOT=/home/ubuntu/deps_virtio/host_mem scripts/run_vcs53.sh core rdma_qp_lifecycle_test`：PROCESS PASS、LOGICAL PASS，UVM warning/error/fatal 为 0/0/0。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check`：PASS。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py' -q`：继续保持 293/293 OK。

## 遗留边界

本批只收束 URC backing 几何和 factory seam，不宣称关闭 SQD/SQE drain/flush、跨 queue/
engine 全局并发、外部 ordering/error/backpressure、legacy descriptor、Phase-1C F2 或
最终全目录 ownership 审计；项目级计划继续保持 `active`。
