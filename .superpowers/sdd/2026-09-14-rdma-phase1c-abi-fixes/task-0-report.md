# Task 0 — CQC ABI baseline

## RED

命令：`scripts/run_vcs53.sh core rdma_cmq_codec_test`

结果：fix round 1 初次 raw literal 断言失败，`CQC_RAW_SHADOW` 报告 shadow PA 坐标不匹配（UVM_ERROR=1，流程退出码 1）；完整日志与 SHA256 固化于 evidence/task-0-red.log。该失败来自 ABI 断言坐标，而非编译 workaround。

## GREEN

- `scripts/run_vcs53.sh core rdma_cmq_codec_test`：通过；UVM warning=0、error=0、fatal=0，`LOGICAL PASS`。
- `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`：通过；UVM warning=0、error=0、fatal=0，`LOGICAL PASS`。

## 改动文件

- `tests/unit/rdma_cmq_codec_test.sv`：新增 `check_cqc_raw_word_baseline`，通过 `rdma_hw_qword_builder.put_memcpy/get_words` 读取八个逻辑 qword，使用 `body_mask(RDMA_IMAGE_CQC, RDMA_OP_CQC_CREATE, ...)` 驱动掩码，并断言 cq PI/wrap、CQE size `[63:62]`、CEQN、shadow PA、CI/wrap、arm 坐标。
- `tests/unit/rdma_cqe_size_codec_test.sv`：对 32/64/128B profile 增加原始镜像长度及首字节坐标断言。

## ABI raw 坐标证据

CQC raw baseline 覆盖 qword4 `[22:0]` CQ PI、`[23]` wrap、`[63:62]` CQE size；qword5 `[11:0]` CEQN；qword6 `[63:6]` shadow PA；qword7 `[22:0]` CI、`[23]` CI wrap、`[35:34]` arm state、`[33:32]` arm sequence。所有 qword 均逐项通过 driver `body_mask` 越界检查，并经 builder `get_words()` 与 big-endian image 坐标一致性校验。

## 风险

测试仅冻结当前 CQC_CREATE 64B body 的 raw 坐标；未修改生产 codec。VCS 日志包含既有 UVM `TEIF` 提示（mock function 内 task），但 focused 两项测试最终均为 pristine。

## Fix round 1 审计

修复日志：`/tmp/task0_fix_cmq2.log`（CQC GREEN，UVM pristine，LOGICAL PASS）；`/tmp/task0_fix_cqe.log` 受并行 Task18 未提交接口改动影响，在编译阶段因 `rdma_cmq_identity_shape_valid` 类型不兼容退出（非 Task0 文件）。此前真实 RED 原始日志为 `/tmp/task0_fix_cmq.log`，包含 `CQC_RAW_SHADOW` UVM_ERROR=1；修正独立 raw literal 后 CQC GREEN。

## Fix round 2 审计

可审计证据已固化在 `evidence/task-0-{red,green-cmq,green-cqe}.log`，每份记录 ubuntu@10.11.10.53、source HEAD、命令、shell exit code、UVM counts、PROCESS/LOGICAL 行及原始日志 SHA256。CQC 与 CQE focused GREEN 均为 pristine（warning/error/fatal=0，PROCESS/LOGICAL PASS）；RED 统一为真实 `CQC_RAW_SHADOW` UVM_ERROR=1。
