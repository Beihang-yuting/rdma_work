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

驱动 `exec_cmq_cmd` 分派 70 个 opcode。覆盖方式：

- 21 个 opcode 沿用专用 body 编码器（QPC×4、KEY_ALLOC、MR_REGISTER/DEREGISTER、OCC_FLUSH、
  CQC/CEQC/AEQC/SRFQC 的 CREATE/DELETE/QUERY、TQ_FLUSH），由 profile/codec/driver-field-mutation 测试覆盖。
- 其余 49 个 opcode 由表驱动字段 codec（`rdma_cmq_field_codec.sv`）编码。字段表
  `hw/rdma/cmq_request_fields.tsv` 与 `rdma_cmq_request_fields.svh` 由 `tools/gen_cmq_request_fields.py`
  从驱动 15 个填充函数与 `cmq.h/gid.h/defs.h` 字段宏生成；body（`rdma_hw_cmq_field_body`）按驱动 info
  结构体成员名携带取值，驱动变换（`num - 1`、`ether_addr_to_u64`、常量位、SD 数据 memcpy）在 codec 内实现。
  qword 所有权取 opcode descriptor 的 `request_mask`。
- SD_UPDATE：sd_num 超过 2 时写 sd_buf_addr 并置 sign_en，签名 = ~(整条 WQE 字节异或 ^ 主机侧额外 SD
  数据字节异或)；field codec 给出不含信封字节的部分签名，request composer 合并信封后补入。
- 驱动不调用填充函数的 7 个 opcode（CEQC/AEQC/SRFQC_MODIFY、SD_QUERY、QPC/CQC_FORCE_DELETE、NOP）
  在驱动中提交的是全零 WQE（无 valid/opcode）；模型发出仅含信封的 SQE，body 全零。这是唯一有意的偏离。
- 完成侧：查询类 opcode 沿用既有 payload 解码；其余 opcode 解码公共 CQE 头。
- 验收：`tools/cmq_request_oracle.py` 把驱动原文填充函数编译进用户态 harness，为 49 个 opcode（SD_UPDATE
  另含签名用例，共 50 例）生成 `hw/rdma/golden_vectors/cmq_requests.hex`；`rdma_cmq_request_golden_test`
  经生产 profile 组装后逐字节比对。驱动门禁（`make rdma_defs`）对锁定归档重跑生成器与 oracle 的 `--check`。
- 未完成：`cmq_capabilities.tsv` 的闭环标记仍由 `check_rdma_field_ownership.py` 只认 QPC/CQC_CREATE 的
  旧 oracle 证据；把 `cmq_requests.hex` 接入该门禁后可把 49 个请求方向行转为闭环。

## 4. 阶段

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P1 | 新引擎：驱动流程（环/PI/polarity/doorbell/CQE 校验/pending 链表/clean_pending/看门狗），保留 port 契约 | 新引擎测试（含 ring 满排队、wrap/polarity 翻转、wrap/opcode/ecode 失败、reset 排空、看门狗）+ 全量回归 |
| P2 | 旧引擎与旧测试（`rdma_cmq_engine_test` 2.6 万行、CMQ gate 分片、相关 Python 门禁）下线，port/control-plane 测试按新语义改写；删除只服务旧引擎的 journal/digest/typed-snapshot/body-value 模型与 profile 快照/canonicalization 接口 | 全量回归 |
| P3 | 其余 49 个 opcode 的表驱动字段 codec 与公共 CQE 解码（完成） | golden 逐字节比对 + 拒绝路径单测 |
| P4 | 驱动原文 harness 生成 golden（完成）；能力表闭环（未完成，见 §3） | oracle `--check` 与 SV 比对全通过 |
