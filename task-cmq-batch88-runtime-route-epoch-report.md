# CMQ Batch 88：queue runtime route/epoch 值比较 seam

本批在 `rdma_queue_runtime` 内收敛两个已经重复、且只应执行纯值比较的 route/epoch
条件。它是 Batch87 之后的独立小批次，不移动 runtime 的 mutable ledger、锁、
reservation 或状态迁移责任。

## 实现边界

新增 protected 纯 helper `same_route_epoch_value(lhs_route, lhs_epoch, rhs_route,
rhs_epoch)`，只比较两组已冻结的 packed route key 与 reset epoch。helper 不检查
valid bit、route-key 格式或 freshness；这些拒绝条件继续由 caller 负责。以下两处
改为复用 helper：

- `copy_ring_state`：保留 target/source lock 边界、`route_valid == epoch_valid` 半有效
  拒绝和原 `RDMA_SC_INVALID_ARGUMENT` 错误文本。
- `enter_recovery_prepared`：保留四个 valid-bit、`rdma_route_key_valid`、pending
  identity、reservation 和 recovery state 检查；只替换最后的 route/epoch equality。

未修改外部依赖、public/protected API 签名、状态迁移顺序、I/O 或账本所有权；未执行
commit、reset、clean、merge 或 push。

## 源码边界

| 文件 | SHA-256 | Git blob SHA-1 |
| --- | --- | --- |
| `src/core/rdma_queue_runtime.sv` | `ed7617ec8415212730024a066b5ef647c61e4bd45509cada95ec27b85fc13cc1` | `59481d3d9e284c4315d5d3fb50379a7e16501a34` |

该文件包含当前工作树中此前已完成的 runtime seams；本批新增 helper 及两个调用点
均在上述最终源码哈希中冻结。HEAD 仍为
`917beeb769bab84cff95e9e4b2e5ebe9dfeadecd`，工作树既有脏改动全部保留。

## VCS53 验证

三个 focused suite 均通过 `scripts/run_vcs53.sh core <test>` 在
`ubuntu@10.11.10.53` 登录 bash 环境执行：

| 测试 | wrapper | PROCESS/LOGICAL | UVM warning/error/fatal |
| --- | ---: | ---: | ---: |
| `rdma_queue_runtime_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_data_engine_recovery_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_lifecycle_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_data_engine_post_test` | 0 | 1/1 | 0/0/0 |

日志 SHA-256 分别为：

- `evidence/post-batch88-rdma_queue_runtime_test.log`：
  `93789a667e1e39966dba548ca3aa7762aaf04878253db7d170da81964d28ac55`；
- `evidence/post-batch88-rdma_queue_data_engine_recovery_test.log`：
  `0a1ae2d6b0fb2217bbea18959ac3013e6efd22df94ac11a97e867c27f2268e75`；
- `evidence/post-batch88-rdma_queue_lifecycle_test.log`：
  `8157178fb2bc614617825dbe43a668993f47fc7b565f14fc12495b4a91baf3a1`。
- `evidence/post-batch88-rdma_queue_data_engine_post_test.log`：
  `188247c8d0d3baae13b26a42ac641918451b508a6e199f41a86a3a792152d1d2`。

注释合规复审同时修正了 runtime 17 个旧式标签和 factory/inout 说明；没有改变实现。
Python 292/292、manifest 22/22、changed-SV style rc=0（仅既有
`rdma_cmq_body_value_contract.sv:303` soft-limit hint），`git diff --check` rc=0。
Batch89–93 修改稳定后补跑的当前工作树 parent CMQ gate 已通过：wrapper rc=0、
PROCESS 28/28、LOGICAL 11/11、严格 UVM pristine 28/28（warning/error/fatal 均为
0/0/0）。完整日志为 `evidence/post-batch93-cmq_gate-regression.log`，SHA-256=
`8838b7e379db7e56f1e4824924a91523cc4fe64bae3fb31ec22d757f8d62e620`；该 gate 作为
Batch88–93 联合当前工作树证据，不复用 Batch86/87 旧源码边界。

Phase 1C F2、后续 runtime/resource-manager recovery seam、完整目录中文契约/所有权
复审和覆盖矩阵仍开放，整份结构重构计划未完成。
