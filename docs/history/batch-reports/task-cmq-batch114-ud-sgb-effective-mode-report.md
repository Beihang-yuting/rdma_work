# CMQ Batch 114：UD transport-aware SGB effective mode

本批承接 Batch113 暴露的 UD authority 缺口。重构后的通用
`rdma_hw_sqe_model.derive_payload_authority()` 原先把小 inline payload 和一至两项
SGE 解析为 `INLINE_WQE`/`SGE_WQE`，而 UD codec 按驱动 ABI 将所有非零 payload 放入
external SQ-SGB；queue-data writer 因此会在合法请求的首次 backing write 前误拒绝。
本批把 transport-aware effective mode 放回共享 authority derivation，保持 writer
gate 严格不变。所有改动仅位于本项目，未修改外部依赖；结构重构计划继续保持
`active`。

## 实现边界

- `src/codec/rdma/rdma_queue_codecs.sv`
  - `derive_payload_authority()` 在 `transport == RDMA_TRANSPORT_UD` 且 payload
    非零时，将 `INLINE_WQE` 统一提升为 `INLINE_SGB`，将 `SGE_WQE` 统一提升为
    `SGE_SGB`；显式携带但实际为 zero-byte 的 `INLINE_SGB` 也归一回
    `INLINE_WQE`，与 UD codec 的 wire-effective 结果一致。
  - canonical inline byte count 与有效 SGE count 不变，因此 `SGE_NUM`、TPL 和
    descriptor filtering 仍由同一 authority 计算；RC/URC 的 direct-SGE 语义不变。
  - make_sqe、UD codec、SGB writer 和 replay 通过同一个 resolver 看到相同的
    effective mode，不在 writer 中放宽非 external-SGB 拒绝。

- `tests/unit/rdma_queue_data_engine_post_test.sv`
  - 新增真实 UD SQ attachment/probe fixture，复用 route、mapping、codec registry
    和生产 writer；覆盖 1-byte inline、1-SGE、2-SGE 三个非零 payload variant。
  - 每个 variant 都要求 writer 返回 OK 且 Host-memory trace 新增 backing write；
    fixture 不推进 runtime cursor、PI、doorbell 或 completion ledger。

- `tests/unit/rdma_ud_urc_sqe_codec_test.sv`
  - 增加纯 authority 对照：UD inline/SGE 必须得到 external mode，显式 zero-byte
    `INLINE_SGB` 必须归一为 `INLINE_WQE`，RC 一项 SGE 必须继续得到 direct mode。

## 当前源码验证

所有 VCS 仿真均在 `ubuntu@10.11.10.53` 的登录 bash 环境执行，严格 UVM
warning/error/fatal 均为 `0/0/0`。

| 验证入口 | 当前结果 |
| --- | --- |
| `rdma_queue_data_engine_post_test` | rc=0；PROCESS/LOGICAL PASS；UD 1B inline/1-SGE/2-SGE writer GREEN |
| `rdma_ud_urc_sqe_codec_test` | rc=0；PROCESS/LOGICAL PASS；UVM 0/0/0 |
| `rdma_queue_codec_test` | rc=0；PROCESS/LOGICAL PASS；UVM 0/0/0 |
| `rdma_sq_codec_test` | rc=0；PROCESS/LOGICAL PASS；UVM 0/0/0 |
| `check_changed_sv_style.py --base HEAD` | PASS |
| Python style/keyword tests | 15/15 PASS |
| `git diff --check` | PASS |

修复前的 focused RED 已确认同一 UD 1-SGE fixture 返回
`SQE SGB writer received a non-external payload mode` 且没有新增 Host-memory call；
该结果用于定位而非当前 GREEN 证据。正确的 E2E 入口仍受 host_mem preflight 的
外部 `src/host_mem_manager.sv` hash drift 阻断；没有修改外部依赖，也没有把该阻断
记录成业务失败。`pcie_work` 锁文本仍必须保持：
`external dependency is not approved: pcie_work`。

## 未关闭边界

- 本批 focused probe 直接覆盖 make_sqe→codec→writer；完整公开 `post_send()` 与
  `replay_pending()` 的 UD 成功/恢复矩阵仍需后续 integration/focused 证据。
- Batch113 所述 8-bit XOR signature 的多字节抵消限制、Phase 1C F2 whole-plan
  authority、coordinator 跨线程/跨进程并发、更深生命周期审计和外部锁仍开放；本批
  不把局部 transport mode 修复宣称为整体 F2 或结构重构完成。
