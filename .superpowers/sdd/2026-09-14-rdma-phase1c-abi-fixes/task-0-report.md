# Task 0 — CQC ABI baseline

## Historical RED (superseded by fix round 3)

命令：`scripts/run_vcs53.sh core rdma_cmq_codec_test`

结果：fix round 1 初次 raw literal 断言失败，`CQC_RAW_SHADOW` 报告 shadow PA 坐标不匹配（UVM_ERROR=1，流程退出码 1）；这是历史诊断结果，原始临时日志不作为最终 evidence，最终可复核 RED 以 fix round 3 的 `CQC_RAW_PI` 为准。

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

历史 RED 为 `CQC_RAW_SHADOW`，仅用于解释早期 literal 修正；旧摘要 evidence 已移除，避免与最终 source HEAD 混淆。最终可审计证据与 canonical RED/GREEN 结果见 fix round 3 的带 `349a757` 文件。

## Fix round 3 审计（source HEAD 349a757）

Task18 提交 `349a75750ea5a09f0ba18f011267f797798bc318` 后，重新在同一稳定 worktree 运行 focused tests；Task0 测试源码与 source HEAD 一致（CMQ blob `26a136a27800cc7e6c240e000532e2b8acaf7e53`，CQE blob `3b0cf3a29d29a6328233974b5b79f1ca91eeba42`）。

- Fresh RED：临时仅将 `words[4][22:0]` expected literal 从 `23'd17` 改为 `23'd16`，运行 `scripts/run_vcs53.sh core rdma_cmq_codec_test`，远端 shell exit=2；真实 `CQC_RAW_PI` UVM_ERROR=1，UVM warning=0/error=1/fatal=0，PROCESS/LOGICAL FAIL。变体立即恢复，完整 1809 行原始日志保存为 `evidence/task-0-red-cmq-349a757.log`，SHA256 `07cbe69ef1141e8f86898fa0fed0a986743b415203aa9556bf515dd941fde2f6`，元数据见同名 `.meta`。
- GREEN CMQ：同一 source HEAD、基线测试 blob，shell exit=0；UVM warning=0/error=0/fatal=0，PROCESS/LOGICAL PASS。完整 1805 行日志 `evidence/task-0-green-cmq-349a757.log`，SHA256 `b37258c1016ae06f862bf68f8dce58f8722b6a5262b348919c058a6a02fa037b`。
- GREEN CQE：同一 source HEAD，shell exit=0；UVM warning=0/error=0/fatal=0，PROCESS/LOGICAL PASS。完整 1793 行日志 `evidence/task-0-green-cqe-349a757.log`，SHA256 `306e67435b194d206bd4bee0443e231e8c7307afc6875d0d74b8e714109a7a4d`。

三个 `.meta` 文件记录远端主机、精确命令、source HEAD、测试 blob、shell exit、UVM counts、PROCESS/LOGICAL 行和原始日志 hash；旧 `/tmp` 路径不再作为证据来源。
