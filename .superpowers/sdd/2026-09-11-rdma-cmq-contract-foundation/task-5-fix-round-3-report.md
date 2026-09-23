# Task 5 fix round 3 报告

## 修复目标

修复 source-walk 对 production class 名称的前缀误命中：
`rdma_hw_doorbell_codec_registry` 不能被当作真实的
`rdma_hw_doorbell_codec`，否则 checker 可能在错误 source 上寻找 writer，或
把缺失的 doorbell proof 错误投影为 capability。与此同时，回归 fixture 必须
保留真实 `RDMA_FIELD` 坐标声明，确保测试验证的是 class token 边界而不是缺少
字段声明导致的 `UNKNOWN_WRITER`。

## 实现

- 在 `tools/check_rdma_field_ownership.py` 增加
  `_has_sv_class_declaration()`，以完整 class 标识符的 token 边界判断声明，
  并统一用于 production context、缺失 class 检查、per-source writer 扫描和
  doorbell derived-mask 选择。
- 在 `tests/unit/test_check_rdma_field_ownership.py` 增加跨 source 回归：profile
  source 只含 `virtual class rdma_hw_doorbell_codec_registry`，真实 doorbell
  codec 位于另一 source；测试断言 writer 只能来自真实 codec。fixture 同时声明
  四个对应 `RDMA_FIELD` 坐标，使 `MACRO_PUT` 证据完整闭合。

## 验证

以下命令均在本 worktree fresh 执行：

```text
python3 -m unittest tests.unit.test_check_rdma_field_ownership -v
  PASS (59 tests)
python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
  PASS (228 tests)
SSHPASS=123 scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
  PASS (198 tests; rdma definitions PASS; RDMA CMQ oracle verification passed;
  field ownership verification passed)
  TYPED_RECOMPOSE=140 CORRELATED_RECOMPOSE=2 DRIVER_FIXED_REJECT=12
  RAW_DECODE_MUTATION=512 STATIC_CANONICAL=9 STATIC_UNWRITABLE=413
  EXECUTED_TOTAL=666 STATIC_TOTAL=422 GRAND_TOTAL=1088
git diff --check
  PASS
```

VCS 命令通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境
执行；UVM summary 与 field ownership gate 均无 warning/error/fatal。

## 风险与边界

本轮只收紧 checker 的 class declaration 识别并补充测试 fixture，不改变 wire
SV、C oracle、ownership 坐标、capability 范围或 progress ledger。若真实 source
缺失任一 production class，现有 fail-closed 检查仍会拒绝；若字段声明或 C-derived
坐标漂移，writer scanner 仍拒绝或记录整幅 image，不能由 registry 前缀绕过。
