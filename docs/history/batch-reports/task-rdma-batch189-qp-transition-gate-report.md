# Batch189：QP transition capability gate 收束

日期：2026-09-24。工作树：`feature/rdma-cmq-structural-phase2-batch160`。

## 实现边界

`rdma_qp_lifecycle_executor::modify_locked()` 过去在 transport 校验前单独判断
`RDMA_QPS_SQD/RDMA_QPS_SQE`，随后又调用 `rdma_qp_transition_decide()`，形成两份
状态条件。现在先缓存同一 policy decision：仅在 transport-specific request 校验前
消费其中的 `UNSUPPORTED_OPCODE` capability gate，以保持原错误优先级；后续直接复用
该 decision 映射 semantic-only/full-modify/invalid action，不再重复状态判断。

transition policy 仍是无状态值函数，不读取 outstanding ledger、QP/resource manager、
CMQ 或外部 adapter；executor 继续拥有 outstanding admission、QPC staging、CMQ 提交、
generation fence 和 resource commit。

## 验证

- `SSHPASS=123 DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common HOST_MEM_ROOT=/home/ubuntu/deps_virtio/host_mem scripts/run_vcs53.sh core rdma_qp_lifecycle_test`：PROCESS PASS、LOGICAL PASS，UVM warning/error/fatal 为 0/0/0。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check`：PASS。

## 遗留边界

本批只去除 QP transition capability 的重复条件，不实现 SQD/SQE drain/flush 语义；跨
queue/engine 全局并发、legacy descriptor、外部 ordering/error/backpressure、Phase-1C
F2 和最终 ownership 审计仍由项目级计划继续跟踪。
