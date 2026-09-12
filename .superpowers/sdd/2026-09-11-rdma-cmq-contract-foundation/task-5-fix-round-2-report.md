# Task 5 fix round 2 报告

## 修复目标

修复 Task 5 开启三条 proven capability 后的 expected projection 漂移：
`hw/rdma/field_ownership.tsv` 已将 QPC_CREATE request 的 static/fixed 字段标为
`SUPPORTED`，而 checker 仍按 evidence mode 只开放 typed/correlated 字段，导致
`rdma_defs` 在 ownership compare 阶段 fail-closed。

## 实现

- `build_expected_ownership()` 新增 `proven_cases` 输入，并拒绝未知 case。
- QPC_CREATE request 只有在 `cmq_sqe_qpc_create_request` 完整 proof 闭合时，才将
  所有 `HOST_TYPED`/`HOST_FIXED` 字段投影为 `SUPPORTED`；因此 opcode、SIGN_EN、
  `VFID_OVERRIDE` 和 `USE_VFID` 的 static/fixed rows 与动态 rows 使用同一 proof
  边界。
- QPC_CREATE response 仅开放 `HW_TYPED` 字段；`RESERVED_ZERO` 始终保持
  `UNSUPPORTED`。CQC_CREATE 不在 proven 集合中，保持关闭。
- SQ doorbell 仅在 `cmq_sq_doorbell` proof 闭合时开放。
- 新增 `closed_proven_cases()`，从逐列相等的实际 mutation report 与 C-derived
  candidate 按完整 512/512/64 image 行数推导 proven 集合；verify 在 mutation
  compare 成功后才生成 expected ownership/exclusion projection，避免手工 TSV
  或早期 capability 标志影响 proof。
- 增加回归测试，覆盖未证明方向 fail-closed、QPC static/fixed 字段提升、CQC/
  reserved 保持关闭。

## TDD 证据

RED：新增测试在旧实现上失败，原因是
`build_expected_ownership()` 不接受 `proven_cases`。

GREEN：实现后 targeted tests 通过：

```text
python3 -m unittest \
  tests.unit.test_check_rdma_field_ownership.FieldOwnershipFixtureTest.test_expected_ownership_is_fail_closed_by_proven_case \
  tests.unit.test_check_rdma_field_ownership.FieldOwnershipFixtureTest.test_expected_ownership_promotes_only_owned_proven_fields -v
  PASS (2 tests)
```

## 验证

```text
python3 -m unittest tests.unit.test_check_rdma_field_ownership -v
  PASS (58 tests)
python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
  PASS (227 tests)
SSHPASS=123 scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
  PASS (197 tests; field ownership candidate/report gate PASS)
```

`rdma_defs` 使用 53 登录 bash，且通过 `check_uvm_summary.sh`；本轮未修改原始
驱动归档、C oracle、SV wire layout 或其他 engine。

## 风险与边界

此修复只改变 checker 的 expected projection 时序与 capability 映射，不增加新的
proven case。若 mutation candidate、source-walk writer 或任一 ABI 坐标漂移，
`compare_mutation_report()` 或前置 source gate 会先失败，projection 不会开放。
