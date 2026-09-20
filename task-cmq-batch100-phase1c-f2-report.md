# CMQ Batch 100：Phase 1C F2 RC inline-SGB capacity

本批关闭 Phase 1C F2 审计发现的一个本地结构校验缺口：RC raw
INLINE_SGB image 原先只检查 `TPL > 32` 与 `SGE_NUM == ceil(TPL / 16)`，
没有把固定 SQ-SGB backing slot 的容量（512B、最多 32 个 16-byte chunk）
作为独立拒绝条件。因此伪造的 `TPL=513 / SGE_NUM=33` 可以通过
`check_reserved()`，再被 `decode()` 投影为 detached model。

## ABI 判定与边界

只读核对 `ubuntu@10.11.10.53` 上冻结的
`/home/ubuntu/rdma_driver_analysis/kernel/dpu_kernel_rdma-version_0.1.34`
得到以下约束：

- `xtrdma_hw.h:75-76` 固定 `XTRDMA_MAX_SGE_NUM=32`、
  `XTRDMA_MAX_INLINE_DATA=512`。
- `qp.h:29` 固定 `XTRDMA_FWQE_SGB_BUF_SIZE=512`；`wr.h:12` 固定 32B
  WQE 内联阈值，`wr.h:19` 固定 SGE chunk 为 16B，`wr.h:40` 要求 SGB PA
  按 512B（`GENMASK(63,9)`）对齐。
- `wr.c:127-134` 只在 payload 不超过固定 SGB slot 时允许大于 32B 的
  inline；`wr.c:307-320` 拒绝原始 SGE 数和 max-inline-data 超限；
  `wr.c:328-331` 以 `ALIGN(payload_len,16)>>4` 写入 inline `SGE_NUM`。

完整只读锚点保存在
`.superpowers/sdd/2026-09-14-rdma-phase1c-abi-fixes/evidence/batch100-abi-anchors.txt`。
这组约束证明容量拒绝属于本项目 codec 的职责；没有修改 dpu_common、PCIe、
Host-memory 或驱动 archive。

注意 raw 大端坐标：RC `TPL` 是 qword1 的低 32 位，物理 image bytes 为
`[12:15]`；bytes `[8:11]` 是 immediate/invalidate overlay。focused fixture
因此修改 `[12:15]`，避免把 reserved/immediate 位误当成 TPL。

## 实现边界

`src/codec/rdma/rdma_queue_codecs.sv` 的 RC
`check_reserved()` 在 INLINE_SGB 分支加入容量优先检查：

```systemverilog
if (length > RDMA_MAX_WQ_SGE * 16 || count > RDMA_MAX_WQ_SGE)
  return err("RC inline SGB exceeds the fixed 512-byte/32-chunk capacity");
```

容量检查先于原有 `length <= 32` 与 `count == ceil(length/16)` 几何检查，
保证真实 backing capacity 是第一拒绝依据，同时继续复用公共
`RDMA_MAX_WQ_SGE=32` 类型层常量。正常 RC encode、UD/RQE 的既有上限和
外部 ABI 坐标没有扩大或改写。

`tests/unit/rdma_sq_codec_test.sv` 新增 focused RED/GREEN fixture：

1. `make_rc_inline_request(512)` 编码出合法 512B/32-chunk RC inline-SGB，
   检查 TPL bytes `[12:15]=00 00 02 00`、`SGE_NUM` byte `[17]=0x20`、
   对齐 SGB PA 和完整 512B detached signature。
2. 复制该 raw image，只改 TPL bytes `[12:15]` 为 `00 00 02 01`、
   `SGE_NUM` byte `[17]` 为 `0x21`，并按同一 512B SGB 重新计算 signature。
3. `codec.validate_image()` 和 `codec.decode()` 均必须返回非 OK，且 decode
   output model 保持 null；既有 513B typed encode 拒绝和 33B 正向边界继续保留。

测试注释明确了“功能 / 输入/输出及副作用 / 失败/边界”，并说明本地 fixture
不取得外部 SGB/Host-memory 所有权。

## VCS53 证据

以下命令均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash
执行。日志和 meta 位于
`.superpowers/sdd/2026-09-14-rdma-phase1c-abi-fixes/evidence/`；所有 wrapper
rc、PROCESS/LOGICAL 结果和严格 UVM 计数均为通过。

| 测试 | wrapper / PROCESS / LOGICAL | UVM W/E/F | log SHA-256 |
| --- | --- | --- | --- |
| `rdma_sq_codec_test` | `0 / PASS 1 / PASS processes=1` | `0/0/0` | `6a26ad46799f65527f08e73b7b769a70e74223d9cf517ffdd0ada81c54c564c3` |
| `rdma_queue_codec_test` | `0 / PASS 1 / PASS processes=1` | `0/0/0` | `ac0705978594d2a0413f0736e985e7fcb4f5d974c3ee0724310cb78aa1b76237` |
| `rdma_ud_urc_sqe_codec_test` | `0 / PASS 1 / PASS processes=1` | `0/0/0` | `ace008563e39e4e97df0c731916e4ddc4d3466624a73f4e62ad9891d25b6c6d7` |

最终 focused SQ 源码/测试指纹：

| 文件 | SHA-256 |
| --- | --- |
| `src/codec/rdma/rdma_queue_codecs.sv` | `0fbcd36f47e88bbe9f5304a61b6d76ed7778518e420da63273da8243b5504026` |
| `tests/unit/rdma_sq_codec_test.sv` | `6812f8edb70383f111b5d92df46b3102754508db7d8db4535d4ed903d16e07c8` |

静态证据 `batch100-static.log`：

- `python3 tools/check_changed_sv_style.py --base HEAD`：rc=0；仅报告既有
  soft-limit（`rdma_resource_manager.sv` 两行、`rdma_cmq_body_value_contract.sv`
  一行），本批新增代码无额外 soft-limit。
- `git diff --check`：rc=0。

附加静态单元证据 `batch100-static-extra.log`：
`python3 tests/unit/test_check_changed_sv_style.py` 为 12/12 OK，
`PYTHONPATH=. python3 tests/unit/test_sv_keyword_guards.py` 为 3/3 OK（两者
rc=0）。

本报告只记录 Batch100 的 scoped F2 修复；没有改写 Phase 1C progress，也不把
整个结构重构计划或 F2 全部跨组件验收标为完成。父代理仍需将本批证据纳入最终
覆盖矩阵并完成全目录审查。
