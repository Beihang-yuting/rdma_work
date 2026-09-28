# Batch190：SQ SGE canonical authority whole-plan 收口

日期：2026-09-24。工作树：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标

在不改变 payload mode、错误优先级或 Host-memory 提交顺序的前提下，继续推进
Phase-1C F2：让 RC/UD SQ codec 与 SQ-SGB writer 共享同一个 detached SGE 数量/总长度
authority，避免各自遍历 SGEs 形成第二份 `sge_num` 事实源。

## 实现

- `src/codec/rdma/rdma_sge_authority.sv` 新增 `derive_send()`，统一过滤零长度 SGE，
  拒绝 null、保留 bit31、超过 32 项和超过 2GiB 的 payload，并以 detached output 发布
  canonical count/length；helper 不保存输入引用、不拥有 SGE/SGB/Host-memory。
- RC `body_and_header()` 在 direct-SGE/SGE-SGB 分支调用 `derive_send()`，保留原有
  `total_payload_len` 一致性检查和 payload-mode 门禁。
- UD `encode_fields()` 在 SGE 分支调用同一 helper，再按 canonical count 序列化 descriptor；
  UD effective-mode、TPL、SGE_NUM、signature 和 SGB padding 语义保持不变。
- `rdma_queue_data_engine::write_sgb_and_verify()` 在首次 Host-memory write 前复用
  helper，继续检查 encode 后 `sge_num` 漂移、descriptor 压紧计数、signature 与 backing
  IOVA；没有新增 mutable owner、lock、ledger 或外部资源生命周期。

## 验证

- `rdma_sqe_authority_test`：VCS53 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为
  `0/0/0`；新增零长度过滤、2GiB sentinel、null 和 reserved bit31 矩阵。
- `rdma_sq_codec_test`：VCS53 PROCESS/LOGICAL PASS，UVM `0/0/0`。
- 本地 Python discover：293/293 PASS；`git diff --check`、changed-SV style、queue
  lifecycle、profile、Phase-1A gates PASS。
- core 全回归正在 `ubuntu@10.11.10.53` 登录 bash 中执行；完成后补录 logical/physical
  计数和 UVM 汇总。

## 未关闭边界

本批只收口 SQ SGE 数量/总长度 authority 的重复实现；RQ raw/typed provenance、inline/
atomic/UD/URC whole-plan 组合、SRQ lifecycle、跨 queue/engine 并发、SQD/SQE drain/flush、
legacy descriptor、外部 ordering/error/backpressure、resource-manager 外部调用窗口和
最终 ownership 审计仍按项目计划保持 OPEN。
