# Batch174：SQ/RQ canonical SGE authority seam

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标

收束 SQ 与 RQ 在不同 caller 中重复的 typed SGE 统计，明确 wire `SGE_NUM` 与
payload length 的唯一只读 authority 入口，继续推进 Phase-1C F2 的 whole-plan
canonical authority 收口。该批不改变 descriptor 布局、外部 adapter 契约或资源生命周期。

## 实现

- 新增 `src/codec/rdma/rdma_sge_authority.sv`，提供：
  - `count_nonzero()`：统计 SQ 中长度非零的 descriptor，不截断、不伪造 null
    SGE 的 shape 合法性；
  - `derive_receive()`：按驱动规则过滤零长度 RQ SGE，原子产出有效数量和总长度，
    拒绝 null、reserved bit31、超过 32 项和超过 2GiB 的部分统计。
- `rdma_hw_sqe_model::derive_payload_authority()` 复用 `count_nonzero()`，因此
  mode、inline/SGE effective layout 和 canonical `SGE_NUM` 继续由同一统计结果驱动。
- `rdma_hw_rqe_model::derive_typed_sge_authority()` 复用 `derive_receive()`；
  existing external-SGB provenance、snapshot、typed descriptor byte comparison
  和错误文案保持在 RQE model 内，helper 不取得任何 backing/ledger 所有权。
- `rdma_queue_codec_test` 增加合法零长度过滤、SQ count、null 和 reserved-bit
  原子失败 fixture，确保 helper output 不发布半成品 authority。

## 验证

```text
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_codec_test
PROCESS PASS logical=rdma_queue_codec_test physical=rdma_queue_codec_test
LOGICAL PASS logical=rdma_queue_codec_test processes=1
UVM warning/error/fatal = 0/0/0
```

本地 `python3 tools/check_changed_sv_style.py --base HEAD` 与 `git diff --check` 均通过。

## 未关闭项

本批只关闭 codec/model 的 SGE 统计重复；仍需继续补充 inline/SGE/atomic/UD/URC
whole-plan 组合证据、跨队列/跨线程并发、SRQ 全生命周期、SQD/SQE drain/flush、
legacy descriptor、外部 PCIe ordering/error、manager 外部调用窗口补偿、完整
parent/core/integration 汇总和最终 ownership/中文契约审计。项目级计划继续保持
`active`。
