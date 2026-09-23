# CMQ Batch 113：SQ SGB writer authority gate

本批在重构后的 queue-data 路径收口 SQ external-SGB 的写入边界。目标是让
`write_sgb_and_verify()` 在第一次 Host-memory write 之前重新使用共享 payload
authority，并把已编码 SQE image 的 signature 与即将写入的 512-byte SGB 做一次
不可绕过的比对。该批只保护 SGB payload 的 mode/count、descriptor packing 和现有
8-bit signature contract；不扩大为 opcode、remote/control header 或外部 ABI 的重新
校验。所有改动仅位于本项目，未修改外部依赖，也未对主 worktree 执行 reset、clean、
merge 或 push；结构重构计划继续保持 `active`。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - `write_sgb_and_verify()` 接收同一 request 已编码的 `rdma_hw_image`，在任何
    backing write 前重新派生 canonical payload mode/count。
  - 拒绝 `model.sge_num` 与 canonical count 漂移、压紧后的有效 descriptor 数量
    不完整，以及非 external-SGB mode 携带 SGB backing 的组合。
  - 将实际构造的 512-byte SGB 转为 signature 输入，调用 `validate_sq_signature()`；
    image metadata、既有 signature 或 descriptor/inline bytes 不一致时 fail-closed，
    不推进 PI，也不产生该次 Host-memory write。该 gate 不重新解析全部 opcode、
    remote/control header，也不把调用方重写 header 后重算 signature 当成新的 authority。
  - `post_send()` 与 `replay_pending()` 传递同一 image，保持首次提交和恢复重放使用
    相同的 detached authority。

- `tests/unit/rdma_queue_data_engine_post_test.sv`
  - 通过真实 attachment、codec registry、SGB mapping 和 Host-memory trace 建立
    probe fixture；不复制 queue admission，也不提交 runtime cursor。
  - 覆盖 baseline 成功写入，以及 image 编码后篡改 `sge_num`、`payload_mode`、
    count 不变但 descriptor length 三类 mutation；三类 mutation 均在首次 write
    前拒绝且 Host-memory call trace 无新增记录。inline-byte mutation 的完整 fixture
    尚未加入本批。

## 当前源码验证

本批 focused VCS 验证均在 `ubuntu@10.11.10.53` 的登录 bash 环境运行，严格 UVM
warning/error/fatal 均为 `0/0/0`。

| 验证入口 | 当前结果 |
| --- | --- |
| `rdma_queue_data_engine_post_test` | rc=0；PROCESS/LOGICAL PASS；baseline 与三类 mutation 均符合预期 |
| `rdma_sq_codec_test` | rc=0；PROCESS/LOGICAL PASS；UVM 0/0/0 |
| `rdma_queue_codec_test` | rc=0；PROCESS/LOGICAL PASS；UVM 0/0/0 |
| `rdma_ud_urc_sqe_codec_test` | rc=0；PROCESS/LOGICAL PASS；UVM 0/0/0 |
| `check_changed_sv_style.py --base HEAD` | PASS |
| Python style/keyword tests | 15/15 PASS |
| `git diff --check` | PASS |

本地环境未安装 `pytest`（`No module named pytest`），因此不能把 `python3 -m pytest -q`
记为通过。正确的 E2E 入口在 `host_mem_preflight` 因外部依赖
`src/host_mem_manager.sv` hash drift 阻断；这不是本批业务回归结果，且未修改外部
依赖。`pcie_work` 的外部锁文本仍必须保持：
`external dependency is not approved: pcie_work`。

## 未关闭边界

- UD codec 对非零 inline/1–2 SGE 使用 external SGB 的 transport-aware effective
  mode，和通用 `rdma_hw_sqe_model`/queue-data writer 的默认推导仍需独立 focused
  RED 与后续修复；本批没有绕过 writer gate 或放宽非 external mode 拒绝。
- Phase 1C F2 的 whole-plan canonical authority、coordinator 跨线程/跨进程并发、
  更深生命周期审计及外部锁仍开放。`validate_sq_signature()` 沿用 8-bit XOR，当前
  focused fixture 只证明单一 descriptor mutation；多个字节的 delta 若抵消，不能
  替代更强的 detached-byte digest。本批不把局部 writer gate 宣称为任意 mutation
  的密码学完整性、整体 F2 或结构重构完成。

`model.sge_num`、canonical count 和 payload-mode enum 当前均为二态类型；本批没有
伪造不可达的 X/Z 注入，也没有把 `!=` 描述成四态验证器。若未来字段改为四态，需
同步 codec/model validator 与 focused negative test。
