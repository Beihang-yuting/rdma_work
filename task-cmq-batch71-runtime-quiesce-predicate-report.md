# Batch71：queue-runtime quiesce mutable-work predicate

## 审查结论

`src/core/rdma_queue_runtime.sv` 的 `begin_quiesce`、`restore_active` 与
`detach_quiesced` 原先各自展开同一个持锁判断：pending operation、device reservation
或 used slot 任一存在即拒绝冻结/恢复/隔离。该判断不负责错误码或状态迁移，适合收敛为
持锁只读 helper。

## 本批次改动

- 新增 `mutable_work_present_locked()`，只读取
  `pending_operation_state`、`device_reservation_valid` 和 `used`，不分配对象、不写
  runtime、不获取或释放锁，也不接管 ledger/backing 所有权。
- 三个 caller 改用 helper；`begin_quiesce` 的 pending → reservation → used 错误消息优先级、
  `restore_active`/`detach_quiesced` 的 generic 错误文本、state gate、lock.put(1) 位置和
  ACTIVE/QUIESCING/DETACHED 迁移均保持 inline。
- 同步修正被本批触及方法的中文注释标签为“输入/输出及副作用”“失败/边界”，不改变业务
  行为；`copy_ring_state` 中包含 recovery flags 的更严格 predicate 未复用本 helper。

## 边界与证据

source before 为 Batch69 runtime 快照
`f4a2670b5ddb4d502d0849a350eaf38722c87f1802372b64a34305763d40c8d2`（5043 行），source
after 为 `1f21730edab0060bd8aafe74b183d045ff0c138d5403488d0e7eeebdde42181e`（5054 行），
纯 diff SHA 为 `7d30a37ee6439e6f45db92108e6b0c1637d1614c969834536c372cc04148b02b`。
before/after archive、source diff、静态复审和完整 gate 证据位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch71-*`。

## 验证

- focused `rdma_queue_runtime_test`：PROCESS/LOGICAL 1/1、严格 UVM 0/0/0；日志 SHA
  `352b94ea336797f5fdba743046d575a878caf64bc2790348d17876d783569021`。
- focused `rdma_queue_lifecycle_test`：PROCESS/LOGICAL 1/1、严格 UVM 0/0/0；日志 SHA
  `7461c4969cb5f642179c375aa8696338962608ec290def6a948e0453bf99bf16`。
- focused `rdma_cq_engine_resize_test`：PROCESS/LOGICAL 1/1、严格 UVM 0/0/0；日志 SHA
  `98654e08a4f354d5d5be6cece74e3af49dcfa8a08fcad3a02eeac9abb3b0a885`。
- focused `rdma_queue_data_engine_recovery_test`：PROCESS/LOGICAL 1/1、严格 UVM 0/0/0；
  日志 SHA `2bc9029d9d9595795c3716dda161ebcd93879da55a6683baf0839a3b7b6156f4`。
- 联合 `cmq_gate regression`：PROCESS 28/28、LOGICAL 11/11、无 gate FAIL、严格 UVM
  pristine 28/28；日志 SHA
  `0d6de0ec2899e9c74e3e5f059d789b053918e11cc4053abd20dfa5a9bb1fe5b9`。
- Python unit discover：292/292；manifest：22/22；changed-SV style rc 0（仅既有
  `rdma_cmq_body_value_contract.sv:303` soft-limit）；`git diff --check` rc 0。

本批没有修改外部依赖、未提交或 push；CQE metadata、resource-manager 深层 recovery、
Phase 1C F2 和最终全目录注释/所有权复审仍开放。
