# CMQ Batch 131：poll WQ canonicalization 与 UD SEND 正向覆盖

本批继续基于 `feature/rdma-cmq-contract-foundation` 的重构后 queue-data engine，收束
CQ poll admission 前重复的 staged WQ target/canonical lookup 职责，并补充一条可公开
复核的 UD SEND CQE 正向链。生产改动不改变首次 runtime mutation 或提交顺序；测试仍由
fixture 管理 queue、runtime、mapping、Host-memory 与 Function 生命周期。

## 实现边界

- `src/core/rdma_queue_data_engine.sv` 新增只读
  `canonicalize_cq_poll_wq_attachment()`。函数以冻结 `cqe`、`link`、`pending` 和
  staged attachment 为输入，按同一 selector contract 重建 target；在任何
  `enter_recovery_prepared()` 之前检查 `pending.completion_wq_kind`、runtime/access、
  `RDMA_WQE_BYTES` geometry、backing role 与完整 handle incarnation。staged 引用
  失败时只按冻结 target 做一次 registry relookup，并再次调用共享 validator；函数
  不建立 pending、不推进 cursor/ledger、不写 Host-memory/MMIO，也不取得外部资源
  所有权。
- `poll_cqe_once()` 删除原地重复的 target fallback、kind 检查和 validator/relookup
  分支，只保留 staging 输出完整性检查、canonicalizer 调用和成功后的 attachment
  交接；`enter_recovery_prepared()`、doorbell、CQ consumer commit、CQ→WQ release、
  recovery completion 与 result publish 顺序保持不变。
- `rdma_queue_data_engine_probe` 新增 detached hostile fixture：
  `fault_kind=0` 验证真实 canonical attachment，`1..5` 分别验证 null、entry-size、
  backing-role、runtime-depth、stale-generation alias 的 canonical relookup，
  `6` 验证 pending kind 漂移在 lookup/副作用前返回 `RDMA_SC_INVALID_STATE`。alias
  只借用 runtime/access/context 引用，不修改 engine-owned attachment。
- `rdma_queue_data_engine_poll_test` 新增
  `make_cqe_for_outstanding_ud_send()` 和 `check_ud_send_cqe_e2e()`：fixture 切换
  到 UD CQ/QP，执行 `post_send`→公开 `publish_cqe`→`poll_cqe`，断言
  `RDMA_CQE_VARIANT_UD`、QPN/WQE index+wrap、`wr_id`、UD source-QPN/SMAC/VLAN
  overlay、单个 SQ release、SQ/CQ occupancy/cursor、RQ 保持空以及第二次
  `RDMA_SC_QUEUE_EMPTY`。`make_send()` 返回 null 时先检查对象再 clone QP handle，
  不解引用半成品 request。

## 验证

所有 VCS 仿真均在 `ubuntu@10.11.10.53` 登录 bash 环境通过
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行；最终源码边界结果如下：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_post_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |

静态门禁：

- `git diff --check`、`python3 tools/check_changed_sv_style.py --base 500793e`、queue
  lifecycle、RDMA profile、Phase-1A approval 均 PASS。
- 全目录中文契约/文件头 scanner：185 个 `.sv`、2 个 `.svh`，共 5,422 methods
  （`.sv` 5,420、`.svh` 2），0 diagnostics。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292 tests，OK。
- manifest/keyword/queue/profile/Phase-1A 辅助门禁保持 GREEN；本批未修改外部依赖。

## 源码指纹

以下 SHA-256 对应本报告所述最终源码边界；后续修改任一文件必须刷新本报告、计划和
覆盖矩阵中的证据：

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `1b7bb8fe152ddadc102c367165ae2f610834b3bb103dbf6bd1237b1cbb87c030` |
| `tests/unit/rdma_queue_data_engine_poll_test.sv` | `5378d8882074f413cc2a4df9053340d5dc203fe158503abaef43d93da71da771` |
| `tests/unit/rdma_queue_data_engine_post_test.sv` | `e10a350ba56af2d4f7a09f087a97512b63e29f987c4e1a6b60726e0af40b69be` |
| `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md` | `bcbfbb62952e7494233642d74957ecca73d7457eb9fa3e1ea42d5ac6e7ee5f6b` |
| `docs/rdma-structural-refactor-coverage-matrix.md` | `1c3bc451265d9e1335374e6bd3d536bb352a8f117c11b0a7fdc0ba2bf93a6eb2` |

## 开放边界

本批关闭 staged WQ canonicalization 的局部 admission seam，并取得 UD SEND 单路径
正向证据；不把它扩大解释为 SRQ 全生命周期、UD receive/replay、legacy descriptor
branch、poll/recovery 全阶段组合、CQ→WQ 跨队列并发、engine-level 全局锁、snapshot
后 alias 审计、device/consumer 组合 recovery 或最终 ownership 审计已完成。legacy
descriptor 的公开 poll 入口仍在 `context_backing == null` occupancy/read 前返回
`RDMA_SC_UNSUPPORTED_OPCODE`，兼容 recovery 分支保留并继续单独审计。

`pcie_work` integration 的阻断文本保持原文：
`external dependency is not approved: pcie_work`；未修改外部依赖，也未将阻断伪造为
业务失败或 GREEN。
