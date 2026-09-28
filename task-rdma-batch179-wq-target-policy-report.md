# Batch179：CQ poll WQ target policy

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标与边界

CQ poll 的 send、私有 RQ、共享 SRQ 目标选择原本在 queue-data engine 的 selector
中直接维护一张 runtime kind/backing role 分支表。该表只描述 detached route 映射，
不应与 attachment、cursor、ledger 或生命周期 owner 耦合。本批把这张值表提取为
`src/core/rdma_queue_wq_target_policy.sv` 的无状态 `rdma_queue_wq_target_policy::for_cqe()`。

## 实现

- 新增 `rdma_queue_wq_target_contract_t`，只携带 runtime kind 与 backing role。
- `for_cqe()` 统一处理 send、private RQ、shared SRQ 和未知 flag；send 忽略未选中的
  SRQ presence，receive 按 SRQ presence 选择 RQ/SRQ。
- `for_receive_target()` 统一 post_recv 入口的 QP→private RQ、SRQ→shared SRQ 映射，
  对 PD 等非 WQ resource kind fail-closed；该 policy 只返回值，不执行 completion-QP
  lookup 或 producer admission。
- `select_cq_poll_wq_target_contract()` 只消费 policy 输出，仍负责 QP/SRQ handle kind
  以及 target handle 选择；后续 attachment geometry、incarnation、route/epoch、WQE
  release 和 runtime mutation 未下放。
- 新增 `check_wq_target_policy()`，覆盖三种合法映射及 rq_cqe/srq_present 的 X/Z
  fail-closed 边界。

## 验证

- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check`：PASS。
- VCS53 登录 bash：
  `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_data_engine_post_test`
  编译、PROCESS、LOGICAL 均 PASS，UVM warning/error/fatal 为 0/0/0。
- Python 单测此前 293/293 PASS；本批仅新增 SystemVerilog policy 与 focused assertion，
  提交前需按当前边界再刷新 Python 门禁及完整 core/integration regression。

## 未关闭项

SRQ 全生命周期和 destroy dependency、跨队列/跨线程并发、SQD/SQE drain/flush、legacy
descriptor、外部 PCIe/Host-memory ordering/error/backpressure、manager 外部调用窗口补偿、
`RDMA_QUEUE_MMIO_AMBIGUOUS` 全方向不可重放证据、Phase-1C F2 canonical authority 和
最终 ownership/中文契约审计继续保持 OPEN；项目计划继续 `active`。
