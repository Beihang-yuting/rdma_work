# CMQ Batch 80：QDE recover_queue attachment identity predicate

本批只针对 `src/core/rdma_queue_data_engine.sv` 做一处受限重构，保留工作树中其他既有
未提交改动，不修改测试、外部依赖或其他源码文件。目标是把 `recover_queue` 三条恢复
扫描路径重复的 attachment/queue handle 完整身份判断集中到一个纯 helper，同时保留各
分支自己的 runtime、状态、动作、错误码和短路顺序。

## 实现

新增 protected helper `attachment_matches_queue_identity(attachment, queue_h)`：

- attachment、`attachment.queue_h` 或目标 `queue_h` 为空时返回 `0`；
- 非空句柄通过既有 `same_handle_instance` 比较完整 incarnation（kind、
  function UID、object ID、generation）；
- helper 只读取 attachment/handle，不查询 runtime、recovery、cursor 或 ledger，也
  不取得外部资源所有权。

`recover_queue` 的以下三处 identity gate 改为调用该 helper：

1. unclaimed recovery 的 stale attachment guard（runtime null 的首个检查仍在调用方）；
2. claimed recovery attachment scan（runtime 非空与 `RECOVERY_REQUIRED` 状态检查仍在
   helper 之后由调用方执行）；
3. reservation-only scan（runtime query、abort/detach 顺序保持 inline）。

identity 不匹配仍按原路径跳过或拒绝；错误文本、状态码、ambiguity 处理、证据保留和
   publication 顺序均未改变。`detach` 与 `detach_recovery_transaction` 中的 identity
   gate 明确排除在本批之外，避免扩大 helper 的职责边界。

## 精确边界

- source before SHA-256：`cd4849bfe85ada098613924bbb86115193c7cf622cbb60f31ddc96f97e9ca912`
- source after SHA-256：`9c9746a05e6f7f36a2292806a367389707849d1b8f2c41aca0759f03f6b3e80f`
- source lines：`9323 -> 9340`
- 精确 diff SHA-256：`bc2bcc9f045e0bb7b1c227666b86e2264cb1ad26791802c411141b15fcf1c0f5`
- source before archive SHA-256：`972bed34272a51b50972cc4fe38db6e8d848b20f4737ce128fb7bf16d0837b8f`
- source after archive SHA-256：`159e7af8ffc5390453f6fce6f33c29f08579ccb76985ffbf6293a911c7745489`

before/after source archive、archive validation、source review、精确 diff 和 focused
测试日志位于：
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch80-*`。

## 验证

所有仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 测试 | wrapper | logical/physical | 严格 UVM（warning/error/fatal） |
| --- | --- | --- | --- |
| `rdma_queue_data_engine_recovery_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_data_engine_poll_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_data_engine_device_publish_test` | 0 | 1/1 | 0/0/0 |

focused 日志 SHA-256 分别为：

- recovery：`d32bae606425b7163e9997d90326d86f1479469ebb68c7f03717f33444314e91`；
- poll：`07d86215b8bff2b4bc4dede8ae0655d23612590e0d8fe3a6cb0deebb44d8138b`；
- device publish：`05e41b6a96389f1f99e59bafdc0e5465066010dae9d38bdc79927bfd4527276e`。

静态检查：

- `python3 tools/check_changed_sv_style.py --base HEAD`：rc 0；仅保留既有
  `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit 提示；
- `git diff --check -- src/core/rdma_queue_data_engine.sv`：rc 0；
- source review 与 archive validation 均 PASS，且三处 caller 的原拒绝/短路顺序已逐项
  复核。

本批不标记整个结构重构计划完成；完整 gate、后续 authority seams 和最终全目录注释/
所有权复审由主代理统一安排。
