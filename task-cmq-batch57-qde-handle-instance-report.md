# CMQ Batch 57 — QDE handle instance comparison seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树
中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批在 `src/core/rdma_queue_data_engine.sv` 增加纯 helper
`same_handle_instance(lhs, rhs)`，并将六个已经具备完整 null/authority 前置门禁的
handle instance 比较改为复用该 seam：

- `validate_cqe_publish_authority` 的 QP link；
- `validate_ceqe_publish_authority` 的 routed CQ；
- `validate_ceqe_publish_authority` 的 CQ→CEQ dependency；
- `validate_ceqe_publish_authority` 的 send-CQ 与 recv-CQ association；
- `detach` 的 attachment scan。

helper 对任一 null 返回 `0`，非空时调用原始 `lhs.same_instance(rhs)`；它不检查
route、reset epoch、状态、ownership、锁或 alias。六个调用点原有的 null 短路、
`ensure_handle`/attachment/status 门禁、错误优先级、QP/CQ route 选择和 detach 的
resize-lock 生命周期均保持在 caller。源码边界 SHA 为：

- Batch57 before：`5900d640d3fa981c248f09812aaa696ce356a6285a60fa605ed0a48eccf96ef`；
- Batch57 after：`f1dd1e990d3c8616f23737572c41d33265df8045d344bc3656c6155c7c9d8dd6`；
- 行数：9244 → 9266；direct `.same_instance(` 从 28 处降为 24 处（剩余复杂
  recovery/producer 路径与 helper wrapper 延后）。

Batch57 的 focused/full gate 在上述 after 源码边界完成。随后 Batch58 已开始并把同一
文件推进至 `e8768d3cc2e33d8fb3fda30c3a4f7bbc1cbd2ea43ee572254ce4b59561819e21`；因此本批
archive/current 校验记录的是 Batch57 完成瞬间，而不是 Batch58 修改后的工作树。

## 结构审计与静态验证

- source review：`evidence/batch57-source-review.log`，SHA
  `4618f3ad22ced5d99d128500f0914680d5e0e99d0beb5d7f9342111c51571de8`；
  before/after archive SHA 分别为
  `f1dbd094d280dac271262d3fd3f2b679e51e881f2e5a569eb8c3e57a3624e8ca` /
  `a12cc9e089252df2a9b972679304aa0be11f6ba5469ece6d75765b0964557770`。
- archive validation：`evidence/batch57-archive-validation.log`，SHA
  `d7a88eddcf94dc54d39f3417b0d5ccbe99c521c88732dfd9e40b08b91c6748c3`；在 Batch57
  边界，before/after archive member 与记录/current source 均匹配。
- `git diff --check`：rc 0，日志 SHA
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `85d5948e57f7f09e2bf2ca7216967107e59e91fba4d4d671ca4428904bf2d9ec`；
- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `b22c2a3e2703f8c45b45ff3ab04b9c8036eb1772ffa4b7c7a43bb90c4ef0ecda`；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，
  日志 SHA `e3f8a9c61fbc3b146e2ddd363d31038053e06a77b57ab00039ae492a0efed811`；
- `rdma_queue_data_engine_post_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA
  `a490ea091927b46952012556b9876aa76a231d275ae477b0a6fcfd4cf986fcea`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `ed7a00c971f3d5bf951d1c1048090751c19115ade1611491053665000f4970dc`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `99a146f2544bfa72c88a4d457e6acd11b0aad5ab9436a4060fcd731d6e0e392a`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `ac4724e5bd2f98f797771d15f74c1e6beb9641566390fdc6dc61aba0295d8d2f`。

## 交付边界

本批没有改变 CQE/CEQE route authority、Function/generation 门禁、attachment 所有权、
detach 锁与 mutation 顺序、Host-memory/MMIO、reset/recovery 状态迁移或错误码。QDE
`find_qp_link_for_cq` route-scan seam 已在后续 Batch58 单独处理；CMQ command-snapshot
direct seam、其余复杂 QDE recovery/producer 比较、queue-data resize/reset、runtime
深层 recovery/MMIO 和 Phase 1C F2 仍留待后续批次，整份结构重构计划尚未完成。
