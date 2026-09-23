# CMQ Batch 76 — resource-manager MR restore authority seam

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。
本批只修改 `src/core/rdma_resource_manager.sv`，保留工作树中已有改动；不修改
测试、外部依赖，不提交或 push。

## 结果：MR ERROR restore authority helper 已完成

在 `rdma_resource_manager` 中新增 protected 只读 helper
`mr_restore_authority_status(authoritative, recovery)`，将
`restore_active` 的 MR `ERROR` 分支中纯校验部分集中到一个边界。helper 保留原有
拒绝顺序和错误文本，依次检查：

- recovery 硬件 presence、ambiguous ticket、pending steps，以及允许的
  `HW_OCC_FLUSHED` completed-step shape；
- authoritative/recovery backing 与 HMC reference cardinality；
- backing ref 的 null、mapping、ownership、release bit、mapping value 和 ACTIVE
  状态；
- control-plane-owned backing 的 owned mapping authority，以及
  authoritative→recovery 两次 `query_owned_release_completion` opaque completion
  查询；
- HMC owner、object kind、address、size、first PBL index、index-valid、ownership
  和 release 状态。

`restore_active` 仍保留 staged allocation/recovery-record 存在性门禁、recovery
record 获取、queue restore 分支、replacement validation，以及 registry/recovery
发布顺序。queue recovery 校验和 publication 未被 helper 吸收或重排；helper 不写
registry、recovery、mapping，也不取得外部资源所有权。

## 边界与精确 diff

- source before：`3a9e29f490d63a5c4cfb8008e50c6e3b4ca7a3f515156a0186253c3b58880b77`
  （8515 行）
- source after：`27932c898e9bb6cbeecaaadf5a7ae62e1a552ed6f83d5422eb8079536ff8516b`
  （8537 行）
- 精确 Batch76 source diff SHA-256：
  `025e365ee2211e9eac82612cf18b5f3fccb633ba15a96324be0fe5a5aa9a86cb`
- before archive SHA-256：
  `eb6aaa60f5b64daf847fb0a2d13de940b0694f8f0c4c75df3903605d0cf98ab6`
- after archive SHA-256：
  `987c7590d77ee9a04847bf67f00a557f949bc2afdc3f2fbf09f7de86e88145b7`

source archive、精确 diff、source review 和 archive validation 位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch76-*`。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 的登录 bash 环境和
`scripts/run_vcs53.sh` 执行：

- `rdma_resource_manager_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  warning/error/fatal 0/0/0；日志 SHA-256：
  `2e283f192c8236567035bca0b231efe25da6d289e44fefbd8b71308ddfc53074`。
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  warning/error/fatal 0/0/0；日志 SHA-256：
  `cd5e5d9c83395961e47c8f35051b98f337a1d192c90f3a8efca4c970c4a15577`。
- `rdma_queue_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  warning/error/fatal 0/0/0；日志 SHA-256：
  `55f7c2aa735ba58ff70a790a945a45fd4e280aff9e1e36bc673a86f5b54c60d3`。
- `python3 tools/check_changed_sv_style.py --base HEAD`：rc 0；仅报告既有
  `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit 提示。
- `git diff --check -- src/core/rdma_resource_manager.sv`：rc 0。

本批未运行完整 CMQ gate；完整 gate 由主代理在批次整合后统一执行，不能由本批
focused 结果替代。Batch76 未修改外部依赖、测试或 queue restore 分支，未提交或
push；后续仍需完成 queue/recovery 其余结构复审、完整 gate 和最终全目录注释/
所有权复审，整份结构重构计划未完成。
