# CMQ Batch 78：QDE CQ route predicate seam

本批只针对 `src/core/rdma_queue_data_engine.sv` 做一处受限重构，保留工作树中已有的
其他未提交改动，不修改测试、外部依赖或其他源码文件。目标是把 CQE 路由判断中重复的
“按 receive 标志选择 send/receive CQ，再比较完整 handle incarnation”集中到一个纯
helper，避免 exact-QPN、wide-QPN 和 poll fallback 三条路径发生语义漂移。

## 实现

新增 protected helper `qp_link_cq_route_matches(link, cq_h, rq_cqe)`：

- `link` 或 `cq_h` 为空时返回 `0`；
- `rq_cqe == 0` 只选择并比较 `send_cq_h`；
- `rq_cqe == 1` 只选择并比较 `recv_cq_h`；
- 选择出的句柄通过既有 `same_handle_instance` 比较完整 incarnation；
- helper 只读输入，不访问或修改 runtime、attachment、cursor、ledger、scheduler，
  也不取得外部资源所有权。

以下三处原有同义谓词改为调用 helper：

1. exact-QPN CQE route scan（当前约第 5667 行）；
2. projected/wide-QPN CQE route scan（当前约第 5683 行）；
3. poll fallback 的防御性 route re-lookup（当前约第 6814 行）。

QPN 宽度检查、duplicate 命中、transport/SRQ、route/epoch、状态码和错误优先级仍由
各调用方保留。CEQE route gate、`quiesce_cq_dependents` 和 CQ replay route gates
没有纳入本批，避免扩大 helper 的职责边界。

## 精确边界

- source before SHA-256：`66443b3113f909eaf5a2e15d168c13d2c8503de9f367b595aabac4055c836394`
- source after SHA-256：`cd4849bfe85ada098613924bbb86115193c7cf622cbb60f31ddc96f97e9ca912`
- source lines：`9307 -> 9323`
- 精确 diff SHA-256：`00fe6ad4de48bdb778c63245da0367215ed360d42ce8140e0b9f9db36fc04125`
- 精确 diff：70 行；archive diff 仅包含目标源码文件的一个 helper 和三处调用替换。

before/after source archive、archive validation、source review、精确 diff 和测试日志
位于：
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch78-*`。

## 验证

所有仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 测试 | wrapper | logical/physical | 严格 UVM（warning/error/fatal） |
| --- | --- | --- | --- |
| `rdma_queue_data_engine_poll_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_data_engine_device_publish_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_host_codec_final_fix_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_producer_doorbell_final_fix_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_cqe_codec_final_fix_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_entry_image_final_fix_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_ceqe_codec_final_fix_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_aeqe_codec_final_fix_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_recovery_lifecycle_final_fix_test` | 0 | 1/1 | 0/0/0 |

按先前步骤尝试的聚合名 `rdma_queue_data_engine_final_fix_test` 并未在 factory 注册，
因此只产生 UVM `BDTYP/INVTST` 命名诊断（warning=1、fatal=1），不计入功能测试总数；
manifest 中实际注册的七个 concrete final-fix test 均已逐项通过。

静态检查：

- `python3 tools/check_changed_sv_style.py --base HEAD`：rc 0；仅保留既有的
  `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit 提示；
- `git diff --check`：rc 0；
- helper 四段中文契约注释、空值/方向/identity 边界和调用方错误顺序已在 source review
  中逐项复核。

本批不标记整个结构重构计划完成；完整 gate 和跨目录最终复审由主代理统一安排。
