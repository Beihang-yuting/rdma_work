# CMQ 按驱动行为重构（设计与计划）

日期：2026-10-05。分支：`feature/rdma-arch-slim`。决定：方案 A——只重写 CMQ 引擎，保留 `rdma_cmq_port`
接口（`execute_observed`/`reconcile`）与上层恢复机制不变。驱动依据：rdma-driver-0.1.34 `cmq.c`/`cmq.h`
（sha256 与 `hw/rdma/source_manifest.txt` 一致；源码不入库）。

## 1. 驱动语义（目标行为）

- **初始化**：SQ/CQ 两个 64B 条目环，`request_array[SQ_SIZE]`，`sq_polarity = cq_polarity = 1`。
- **提交**（`process_cmq_cmd`）：pending 链表为空且 SQ 未满 → `exec_cmq_cmd`，否则挂入 pending 链表。
- **执行**（`exec_cmq_cmd`）：取当前 PI 为 `wqe_idx`，登记 `request_array[wqe_idx]`，按 opcode 填 WQE
  （带当前 SQ polarity），`post_sq`：PI+1，PI 回零时翻转 SQ polarity，doorbell = `{PI, POL=!sq_polarity}`。
- **完成**（`ce_handler` 循环）：读 `CQ[CI]`，valid 位 ≠ `cq_polarity` 即无新完成；按 CQE 中 `wqe_idx`
  找回请求；校验 CQE wrap = SQE wrap、CQE opcode = 请求 opcode、ecode = 0（任一不符即该请求失败）；
  CI+1，CI 回零时翻转 `cq_polarity`；完成后对 pending 链表补发（`process_bh`）。
- **等待**：轮询 `ce_handler` 直到本请求 done；驱动无超时、无重试、无歧义。
- **销毁**：`clean_pending_cmq_requests` 把环内在途与 pending 链表请求全部标记完成。

## 2. 模型取舍

- 保留：codec 层（`rdma_cmq_hw_profile` 的 `compose_sqe`/`inspect_cqe`/`encode_doorbell`、frozen ABI 编解码）、
  `rdma_cmq_transport`/doorbell scheduler、`rdma_cmq_execution_result` 结果契约、port adapter。
- 删除：submission journal/ledger、observed 候选与身份暂存、quarantine/迟到诊断、recovery 图认证与重试、
  reset isolation proof、逐层受检快照。
- 超时：驱动无限等待；模型保留 `command.timeout` 作为 TB 看门狗——超时返回 `RDMA_SC_TIMEOUT`、
  引擎进入 POISONED（须 reset），不再产生可对账的歧义 ticket；`reconcile_ticket` 恒返回
  `INVALID_STATE` 且无终态。
- doorbell 失败（驱动 `post_sq` 不会失败）：PI 已推进、环游标不可信，引擎进入 POISONED；
  POISONED 后 pending 链表中的请求立即以 `INVALID_STATE` 结束，不等待各自看门狗。
- 命令快照：`snapshot_command` 只做 `rdma_object_utils` 深拷贝 + `validate()`，body 合法性由
  `compose_sqe` 检查；mock port 复用同一函数。
- reset/shutdown：等价 `clean_pending`，在途与 pending 请求以 `RESET_CANCELLED` 完成。

## 3. 操作类型全覆盖

驱动 `exec_cmq_cmd` 分派 70 个 opcode（`cmq.c` 每个 opcode 一个 WQE 填充函数，约 1075 行）。SV 目前只有
6 类 body 模型（QPC、object_id、CQC delete、MR deregister、OCC flush、empty），能力表 147 行中仅
QPC_CREATE 请求/响应有闭环证据。全覆盖分两层：

1. 每个 opcode 有 SV body 模型与编码器，字段与驱动填充函数逐位一致；查询类命令（*_QUERY、STAT/IFA/
   SD/SRC_ADDR 查询）解码 CQE 回传负载。
2. 每个 opcode 有 C oracle（`hw/rdma/c_oracle`，按驱动填充函数生成）golden 向量，SV 编码逐字节比对，
   `cmq_capabilities.tsv` 对应行转为闭环。

## 4. 阶段

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P1 | 新引擎：驱动流程（环/PI/polarity/doorbell/CQE 校验/pending 链表/clean_pending/看门狗），保留 port 契约 | 新引擎测试（含 ring 满排队、wrap/polarity 翻转、wrap/opcode/ecode 失败、reset 排空、看门狗）+ 全量回归 |
| P2 | 旧引擎与旧测试（`rdma_cmq_engine_test` 2.6 万行、CMQ gate 分片、相关 Python 门禁）下线，port/control-plane 测试按新语义改写；删除只服务旧引擎的 journal/digest/typed-snapshot/body-value 模型与 profile 快照/canonicalization 接口 | 全量回归 |
| P3 | 70 个 opcode 的 body 模型/编码器与查询类 CQE 解码 | 每 opcode 编码单测 |
| P4 | C oracle 扩展到全部 opcode，生成 golden 向量，能力表闭环 | oracle 比对全通过 |
