# Batch75：queue codec base image metadata seam（草稿）

## 审查结论

本批只修改 `src/codec/rdma/rdma_queue_codecs.sv` 的
`rdma_hw_queue_codec_base`。新增只读 protected helper
`validate_queue_image_metadata(image, expected_length)`，把 queue image 的
null、generation 和布局 metadata 前置校验集中到一个纯校验入口；基类
`validate_image` 先调用 helper，再按原顺序反序列化并执行 `check_reserved`。

helper 保留原有拒绝顺序和消息：`queue image is null` →
`queue image generation is stale` → `queue image metadata is invalid`。长度、
bytes 数量、alignment 均改为比较显式 `expected_length`，其余 endian、image kind、
硬件版本、write target 以及 backing/HMC/BAR target 条件不变。helper 不修改
image、codec、builder 或外部资源所有权。

Batch72 的 `validate_cqe_image_metadata` 未改动。它需要先于 image null 检查
拒绝非法 `entry_size` 并保持 CQE profile-specific 错误文本；本批仅做 base seam，
因此没有让 CQE helper 委托 base helper，也没有改变 entry_size/null/error 优先级。

## 边界与精确 diff

- source before SHA-256：
  `4436de04e8f30042e992819542a0d09434e9dbda1914111051ee9463cc161c84`
- source after SHA-256：
  `2cf843be2f326d2d7099c07b6c156eff1303cd8bc14d71cad6d84638dc54d6a0`
- `diff -u --label` 纯 diff SHA-256：
  `253ac38bb57879099b35cbb3d795189124ba3b2590660f481f8e2c4c36cf7992`
- 变更范围：新增一个 base metadata helper；`validate_image` 仅改为调用 helper；
  CQE helper/callers、测试和其他源码文件未改动。

## 验证

- 远端 focused `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_codec_test`：
  wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM warning/error/fatal 0/0/0；日志
  `post-batch75-rdma_queue_codec_test.log` SHA-256：
  `bc1ae5c1b7698840f16b6efbb62691d9698fca27432fe2365607b9c30e8086ce`。
- `python3 tests/unit/test_check_changed_sv_style.py`：12/12，rc 0。
- `git diff --check`：rc 0。
- source before/after archive、精确 source diff、source review 与 archive validation
  位于 `.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch75-*`。
- 本批未运行完整 gate；由主代理在批次整合后统一执行。
