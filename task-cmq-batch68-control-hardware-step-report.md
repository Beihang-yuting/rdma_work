# CMQ Batch 68 — control-plane hardware pending-step classifier

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

从 `rdma_control_plane::recover_resource` 中抽出 protected pure
`first_pending_hardware_step`：它按 `recovery.pending_steps` 的持久化顺序返回第一个
硬件阶段，并保留默认 `RDMA_CTRL_STEP_RESOURCE_RESERVED` 与 found bit。原 while 循环的
`HW_KEY_ALLOCATED` 拒绝、CMQ 执行、timeout evidence、case 状态迁移和
`persist_recovery_record` 提交点均未移动；completed-step reserved-only scan 与最终
pending scan 刻意留在后续边界。

source before `96feafbef6b0edd37f3aeef5ed7c0a1c3022265a97fbfded70b89360fa258084`，after
`e6834b25521473cb94e24c4616e9d33a159e61d8fa91227610a474d3550e3688`（4370 → 4389 行），
精确 diff SHA `ec472e6ed4b1f5343f001867e4d92ab01fab0ccd736300bd9534749d60cad2fa`。

## 验证

- source review/archive：review SHA
  `6712fbad81ef842b6bdc88e993d61a4d9ed23c770abd6590ecb78dd8e206e840`，archive validation
  SHA `659e0eac24c738a30c0193dcb6118f7e5b2547e7bc2732b9a57edeae2f7759a6`；
- `rdma_control_plane_test`：PROCESS/LOGICAL 1/1、UVM 0/0/0，日志 SHA
  `25087a04bd00fc98dbef36a9b2546d1eec451ac6b0184d6e8b92b7452f36d04d`；
- `rdma_control_plane_cmq_engine_test`：PROCESS/LOGICAL 1/1、UVM 0/0/0，日志 SHA
  `b59156094c90cfa92e31915ab0335122cb71abdd8798cc82a98765e15ba76340`；
- 邻接 `rdma_resource_manager_test`：PROCESS/LOGICAL 1/1、UVM 0/0/0，日志 SHA
  `405cbeb448b97f6a7a7b42227a02bc3072c313e94ebdfc2092d849a80b2da453`；
- 联合完整 gate：PROCESS 28/28、LOGICAL 11/11、严格 UVM pristine 28/28，日志 SHA
  `68072bc2feb8e205aa9075259255b041cc52e481d765af29051cc0774bc388f0`。

本批只改变扫描职责归属，不改变 recovery status、锁、CMQ、持久化或资源生命周期；
重复 completed/final 扫描、runtime/resource-manager 及 Phase 1C F2 仍开放。
