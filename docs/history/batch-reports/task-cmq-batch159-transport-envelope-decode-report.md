# Batch159：shared transport envelope decode 收缩

日期：2026-09-23。工作树：`feature/rdma-structural-refactor-batch159`，基线：
`9be3470`。

本批只收束 CMQ observed submit 与 recovery submit 之间重复的 transport envelope
解码外壳。新增 `decode_transport_envelope()`，把一次 transport 返回值降级为独立的
operation status、observation code/message 和 raw submission effect；observer arm、
effect fold、retry 分类、journal/CAS mutation 仍由各自 caller 负责。计划继续保持
`active`，本批不改变 CMQ wire 字段、外部 transport 生命周期或 recovery 状态机的
所有权。

## Shared decoder 的职责边界

- `decode_transport_envelope()` 先清空四个 output，再检查 envelope、status shape 和
  submission-effect enum。合法 status 通过 `copy_submit_status_direct()` 生成 detached
  status，不复用 caller-owned status；合法 effect 原样复制到 `raw_effect`。
- null envelope 按 `recovery_context` 选择 observed/recovery 的稳定 operation message
  与缺失 envelope observation message，并返回 `RDMA_SC_INVALID_STATE` 与
  `RDMA_SUBMIT_EFFECT_UNOBSERVED`。
- malformed status 只把 operation status 和 observation code/message 降级为
  `RDMA_SC_INVALID_STATE`；若 effect 合法，raw effect 仍保留其真实值。malformed effect
  统一降级为 `UNOBSERVED` 并设置 invalid-state observation；recovery 保留旧的 effect
  文案覆盖规则，observed 在 status/effect 同时非法时保留 combined 文案。
- decoder 是纯解码层：不读取或改变 observer arm，不执行 effect fold/classification，
  不安装/删除 journal，不取得 engine lock，不调用外部 scheduler 或 transport。它也不
  依据 envelope 自报 callback 把 effect 当作真实 MMIO authority。

## Caller 保留的状态迁移

`decode_observed_transport_evidence()` 继续根据 decoder 输出计算未 arm 且
`PRE_SUBMIT_REJECTED` 的 `rollback_pre`，随后由 submit task 执行 PRE journal removal，
再由既有 classifier 处理 authentic arm、cumulative effect、attempt effect 和 retry-safe。

recovery submit 在 transport 返回后调用同一 decoder，然后才执行 observer arm 分支、
MMIO visibility fold、未认证 MMIO 拒绝、recovery-required 判定、record/results 写入和
completion 状态更新。这样 status/effect 的 malformed 降级不会吞掉另一字段的有效事实，
也不会把 journal mutation 偷渡到 shared helper。

## 测试契约

`tests/unit/rdma_cmq_engine_test.sv` 为 probe 暴露
`decode_transport_envelope()`，并新增 `check_recovery_transport_envelope_contract()`
四行表：

1. null recovery envelope；
2. malformed operation status；
3. malformed submission effect（含 X/Z 值）；
4. status 与 effect 同时 malformed。

每行都断言 context-specific operation/observation 文案、状态码、raw effect 降级规则、
caller-owned envelope 未被修改，以及合法 source status 没有被 alias。该表在 mutation
fixture 前运行；既有 observed decision matrix 继续验证 shared decoder 输出进入
rollback/classification 后的状态、累计 effect 与 retry-safe 语义。

## 验证与证据

VCS 通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

| Entry | Result |
| --- | --- |
| `rdma_cmq_engine_test` | wrapper rc=0；18/18 PROCESS PASS、1/1 LOGICAL PASS；18 个 process 的 UVM report 均 pristine，`UVM_WARNING/ERROR/FATAL=0/0/0` |

静态验证与复审结果：

- `git diff --check`、changed-SV style、queue/profile/Phase-1A 及相关静态 gates 通过；
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 `OK`；
- 全目录中文契约 scanner 复用 `sanitize_source`、`method_ranges`、
  `check_method_comments` 和 `check_file_header`，覆盖 189 个文件（187 `.sv`、2
  `.svh`），5,488 methods（`.sv` 5,486、`.svh` 2），0 diagnostics。

本批没有修改外部依赖；完整 wrapper/source/log hash 应在提交后与 Batch159 commit 一并
冻结，避免把未提交工作树指纹当作主线证据。

## 未关闭边界

本批不声称关闭以下问题：

- malformed observed/recovery envelope 的更广泛组合矩阵与跨阶段 recovery 语义；
- 跨队列/跨线程并发及 engine-level 全局锁；
- SRQ 全生命周期、legacy descriptor、外部 PCIe ordering/error；
- 完整 CMQ/core/integration regression、全目录 ownership 审计；
- `rdma_queue_txn_evidence::capture_urc_shadow()` 内部 typed status/evidence factory
  边界，以及广义 Phase 1C F2。

focused GREEN 只证明 shared decoder 在当前 source boundary 的 shape、文案、alias 和
caller 状态迁移保持契约，不等于整份结构重构计划完成；计划继续保持 `active`。
