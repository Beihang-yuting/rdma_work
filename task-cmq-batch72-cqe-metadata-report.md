# CMQ Batch 72 — CQE profile metadata validation seam

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。
本批只修改 `src/codec/rdma/rdma_queue_codecs.sv`，保留已有未提交改动，不提交、
不 push、不修改外部依赖。

## 结果：实现完成，focused GREEN

在 `rdma_hw_cqe_codec` 中新增无副作用的 protected helper
`validate_cqe_image_metadata(image, entry_size)`，统一解码入口和 metadata-only
校验入口的 CQE profile 前置门禁。helper 保留原有拒绝顺序和文本：先检查
32/64/128B profile，再检查 image null、generation stale，最后检查 length/bytes、
alignment、BIG endian、image kind、hardware version、write target 以及 backing/HMC/BAR
target。两个 caller 仍各自负责 deserialize、reserved-bit、SIGN_EN 与字段模型逻辑，
因此没有把不同入口的后续失败优先级合并。

source before `e054702fd90b693c8365c49b25fdf035a92948743ceef8b8e3c5bc93f4afadfa`，
after `4436de04e8f30042e992819542a0d09434e9dbda1914111051ee9463cc161c84`
（5473 → 5480 行），精确 diff SHA
`0bc467e2e4abe9b7c036afcb0e43b1423ad75c4c48408a76b115a112622903d0`。

## 验证

source review/archive 校验和、before/after tar 与精确 diff 位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch72-*`。

- `rdma_cqe_size_codec_test`：wrapper rc 0、PROCESS/LOGICAL 1/1，严格 UVM
  warning/error/fatal 0/0/0；日志 SHA
  `399195d9981b79cba9900fdf8b5c757a9c7ab17fd75de84ab51a2b98c6dd70b2`。
- `rdma_queue_codec_test`：wrapper rc 0、PROCESS/LOGICAL 1/1，严格 UVM 0/0/0；日志 SHA
  `16444b4ed50df399f940d67a433e63a7f92b659a3626ce939ba5a65223a39c18`。
- 联合 `cmq_gate regression`：PROCESS 28/28、LOGICAL 11/11、无 gate FAIL、严格 UVM
  pristine 28/28；日志 SHA
  `f76944de9e94e10074bf810e9a56a3f916768dc0a4adc50c3dd36c7ba609c18a`。
- Python unit discover：292/292；manifest：22/22；changed-SV style rc 0（仅既有
  `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit）；`git diff --check` rc 0。

## 边界与后续

helper 不读取或修改 active profile、model、builder、image bytes 或外部 ring/backing
所有权；`decode_with_entry_bytes` 仍在 metadata 通过后把 model 保持为 null 直到完整
字段解码成功。CMQ 完整 gate、source archive/review 及最终结构复审由主代理继续固化；
本批不标记整个结构重构计划完成。
