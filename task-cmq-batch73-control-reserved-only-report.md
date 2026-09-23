# Batch73：control-plane reserved-only recovery classifier

## 结果

在 `rdma_control_plane::recover_resource` 中，将 ERROR MR 的 reserved-only 快速路径
复合 shape 判定抽为只读 `recovery_is_reserved_only(recovery)`。helper 保留硬件
`ABSENT`、无 ambiguous ticket、HMC/backing/pending shape 和 control-plane backing
ownership 条件，并复用 Batch70 的 completed hardware 扫描；caller 仍先执行
`recovery == null || primary_status == null`、MR state/owner 等门禁。

未改变 reserved fast path、destroy restore、CMQ reconciliation、hardware loop 的顺序、
错误优先级、锁、持久化或外部资源所有权。

## 边界与证据

source before `454b75aed1e778633318ca78bcfc8d1a02eb54faa169d9d34ac87b0724398d1c`（4415 行），
after `967c1149fc9e833e7b3393367def9daf54a2820f356d75f0837802d2d30abf7a`（4426 行），
精确 diff SHA `4a860ce05248691271e0e3a56037fe4f9268f6a50b2ad2494c9e0f2163007eac`。
完整 source review/archive 与 before/after tar 位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch73-*`。

## 验证

- `rdma_control_plane_test`：PROCESS/LOGICAL 1/1，严格 UVM 0/0/0；日志 SHA
  `bf683c059070654caa124a613633e0cdd35494c441214f69e7d66f9c73f13319`。
- `rdma_control_plane_cmq_engine_test`：PROCESS/LOGICAL 1/1，严格 UVM 0/0/0；日志 SHA
  `57fb750c82e31ea17fad95f086d74cae4be32fcf53134cce824f6c90e1a4b869`。
- `rdma_resource_manager_test`：PROCESS/LOGICAL 1/1，严格 UVM 0/0/0；日志 SHA
  `754b9f84ac1c39606a4ab4beb26a98ba7f5e7bd2f44c2f4359d37ce977e74920`。
- 联合 `cmq_gate regression`：PROCESS 28/28、LOGICAL 11/11、无 gate FAIL、严格 UVM
  pristine 28/28；日志 SHA
  `47df3dfd1ec7a5e11c7b51805c7dab46996ed99d73995b4077665e3e3a632acf`。
- Python unit discover：292/292；manifest：22/22；changed-SV style rc 0（仅既有
  `rdma_cmq_body_value_contract.sv:303` soft-limit）；`git diff --check` rc 0。

本批未修改外部依赖、未提交或 push；codec base metadata、resource-manager 深层 recovery、
Phase 1C F2 与最终全目录复审仍开放。
