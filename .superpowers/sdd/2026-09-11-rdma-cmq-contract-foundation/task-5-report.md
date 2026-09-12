# Task 5 实现报告

## 状态

已完成 CMQ 专用 gate、类型化 TSV reader、mutation smoke test、QPC_CREATE
VFID 固定零校验和三条 proven capability 记录接线。

Fix round 2 已完成：ownership 的 expected projection 现在由已闭合的
C-derived mutation candidate 驱动。QPC_CREATE request 的 HOST_TYPED/HOST_FIXED
字段（包括 opcode、SIGN_EN 和固定零 VFID）只在 request case 完整闭合后标为
SUPPORTED；未证明的 response/doorbell 方向、CQC_CREATE 和 RESERVED_ZERO 保持
UNSUPPORTED。

Fix round 1 已完成：

- I-1：SV production macro source-walk 对 malformed continuation、malformed
  `` `define`` 和同名 production macro（包括正文完全相同的重复定义）统一
  fail-closed；跨 source 重复也报告来源路径。
- I-2：anchor range proof 只接受 declared buffer 与精确
  ``base/length`` 在同一 flow node 的完整表达式；增加结束边界，拒绝
  ``wqe[0][1]``、成员后缀和别名前缀伪造，并继续检查 target 顺序/终点。
- QPC buffer mutation 先把 TSV wire bit 转为 field-local bit，再按
  ``body.qpc_buffer.value[field_local_bit + 9]`` 写入，并用 source-level
  delta 断言保护该 field-local→wire 映射；最终 image 仍由 production
  ``compose_sqe`` 产生，未使用 SV mask 反推 expected bytes。
- capability 只在 C-derived mutation candidate 与实际 report 完全逐列相等、
  且 source writer proof 完整时开启；CQC_CREATE request 继续保持
  ``CONTEXT_EMBED_BASE_MISMATCH`` blocker，不执行其 composer。

## 实现

- 新增 `tests/support/rdma_cmq_contract_reader.sv`，严格解析 18 列 mutation
  manifest，检查列数、坐标、重复项和六类证据计数（1088 行）。
- 新增 `tests/unit/rdma_cmq_driver_field_mutation_test.sv`，提供 brief 要求的
  helper 接口，加载 Task 3 canonical SQE，并验证 request/response/doorbell
  case 几何、相关 polarity 组和 CQC embed blocker。
- 新增 `sim/cmq_gate.list` 与 `tests/unit/test_cmq_gate_manifest.py`，并将
  mutation test 注册到 package 和 `CORE_TESTS`。
- `rdma_hw_cmq_hw_profile::compose_sqe()` 在 QPC_CREATE body/image 构造前拒绝
  非零 `vfid_override`/`use_vfid`。
- `cmq_capabilities.tsv` 开启 QPC_CREATE request/response 与 CMQ doorbell；
  相关 ownership 行同步标为 SUPPORTED；CQC_CREATE 保持 blocker。

## 验证

```text
python3 -m unittest tests.unit.test_cmq_gate_manifest -v
  PASS (2 tests)
python3 -m unittest tests.unit.test_check_rdma_field_ownership -v
  PASS (58 tests)
python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
  PASS (227 tests)
/home/ryan/.local/bin/python3.8 -m unittest
  tests.unit.test_check_rdma_field_ownership -v
  PASS (58 tests)
SSHPASS=123 scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
  PASS (197 tests; field ownership candidate and report gate PASS; fresh after fix round 2)
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_driver_field_mutation_test
  PASS
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_profile_test
  PASS
SSHPASS=123 scripts/run_vcs53.sh cmq_gate regression
  PASS (6 CMQ tests)
```

mutation test 的实际 summary：

```text
TYPED_RECOMPOSE=140 CORRELATED_RECOMPOSE=2 DRIVER_FIXED_REJECT=12
RAW_DECODE_MUTATION=512 STATIC_CANONICAL=9 STATIC_UNWRITABLE=413
EXECUTED_TOTAL=666 STATIC_TOTAL=422 GRAND_TOTAL=1088
```

所有通过的 VCS case 均由 `check_uvm_summary.sh` 检查，UVM
`warning=0 error=0 fatal=0`。

Fix round 2 前的 `rdma_defs` 失败（ownership capability drift）不再作为通过
证据；上面的 53 机结果是修复后重新执行的唯一有效记录。

## ABI 与边界说明

- 原始驱动 `cmq.h`/`cmq.c` 和 C oracle 是唯一 wire authority；reader、
  mutation test 与 checker 均不从 `RDMA_CMQ_*_MASK` 生成 expected bytes。
- QPC CMQ header 的 QPN 是 24 bit，而 QPC context QPN 是 21 bit；
  `validate_qpc_signature_source` 只比较两者 ABI 共有的低 21 bit，保留
  header 的完整 24 bit，不把高三位静默截断到线上字段。
- 当前 capability 证明范围仍只有 QPC_CREATE request/response 和 SQ doorbell；
  CQC_CREATE 由于真实 context embed base 与现有 composer 不一致，明确保持
  blocker，不能通过静态 mutation 数量“解锁”。
