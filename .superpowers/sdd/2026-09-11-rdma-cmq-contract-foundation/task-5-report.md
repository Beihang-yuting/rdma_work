# Task 5 实现报告

## 状态

已完成 CMQ 专用 gate、类型化 TSV reader、mutation smoke test、QPC_CREATE
VFID 固定零校验和三条 proven capability 记录接线。

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
python3 -m unittest tests.unit.test_cmq_gate_manifest -v   PASS (2 tests)
python3 -m unittest tests.unit.test_check_rdma_field_ownership -v  PASS (52 tests)
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_driver_field_mutation_test  PASS
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_profile_test                PASS
```

VCS 两个测试均报告 warning/error/fatal 为 0。

## Concern

Task 4 checker 当前仍把 QPC capability blocker 固定要求为
`MISSING_PRODUCTION_PATH_EVIDENCE`，并无条件拒绝 request capability=1；Task 5
brief 要求将 proven rows 的 blocker 置为 `-` 并启用 capability，因此后续需要在
主任务中同步更新 checker 的 Task 5 证明条件后再运行 `rdma_defs` gate。
