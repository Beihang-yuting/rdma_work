# CMQ Batch 105：跨 context reset candidate 完整性 seal

本批验证 reset scope 的 candidate 在 virtual `prepare_reset()` /
`validate_reset_candidate()` seam 之间发生跨 context coherent mutation 时会被
拒绝，并且拒绝发生在 coordinator epoch publish 之前。Batch 105 是当前工作树的
focused follow-up；它不宣称整个 reset binding 图或结构重构计划已经完成。

## 实现边界

- `src/integration/rdma_device_env.sv`
  - `rdma_reset_candidate_fingerprint` 在每个 candidate 进入 virtual validation 前保存
    预期 identity incarnation、source identity/binding 值、candidate binding 值、PCIe/BAR、
    queue DMA/capability、notify/readiness、interrupt vectors 和 owner 字段。
  - `snapshot_binding_value_graph()` 只复制结构和值图，不调用 ACTIVE binding 的 readiness
    语义校验；这样 reset capture 不会把当前 fixture 的 MSE/BME/notify readiness 状态误当成
    candidate 完整性前置条件。
  - 所有 virtual callback 返回后，`verify()` 做无分配、无回调的 pointer/value 比较；任何
    candidate/source 漂移都在唯一 epoch side effect 前回滚 quiesce。
- `tests/integration/rdma_reset_cascade_test.sv`
  - `rdma_reset_candidate_mutation_context` 在第二个 Function 的 validation callback 中
    改写第一个 candidate 的 identity generation、binding identity snapshot 和 owner，随后
    委托基类校验当前 candidate。
  - `rdma_reset_candidate_integrity_test` 断言 mutation 被注入、reset 返回
    `RDMA_SC_INVALID_STATE`，且两个 context、identity ledger、Function/Host/Device/router
    epoch 保持旧值。
- `src/integration/rdma_function_context.sv`、`src/model/rdma_function_binding.sv` 和
  `src/integration/rdma_reset_coordinator.sv` 为 candidate prepare/identity/noalloc commit
  的既有契约依赖；本批验证使用当前工作树版本，不修改外部依赖仓库。

## VCS53 验证（当前源码刷新）

所有仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 的登录 bash 中执行，
依赖为 `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common`，VCS 为
`W-2024.09-SP1_Full64`。

| 测试 | wrapper rc | PROCESS/LOGICAL | UVM warning/error/fatal | 日志 SHA-256 |
| --- | ---: | --- | --- | --- |
| `rdma_reset_candidate_integrity_test` | 0 | 1/1 | 0/0/0 | `8e304df2b166e07cd415599a8b7004bfd40024307d42a8819dfe67fde2bd232e` |
| `rdma_reset_cascade_test` | 0 | 1/1 | 0/0/0 | `291dcc9aad4aa49251b1f033ece99ba7b631cd5e1da289c1dff8197f7a67495b` |
| `rdma_function_context_test` | 0 | 1/1 | 0/0/0 | `549de3537895c1e48bee657ff38be5bbb5ec6e93ae735330c8fa34654ca36ca3` |

Focused candidate output contains the hostile mutation path and ends with
`UVM report is pristine: warning=0 error=0 fatal=0`. The cascade and function-context logs
end with the same strict summary. An earlier diagnostic run that used the full semantic binding
validator during capture was rejected with `ACTIVE binding requires PCIe MSE`; that run is not
counted as acceptance evidence. The final structural snapshot helper removes that false
precondition. The refreshed logs are copied from the Batch 106 current-source rerun and therefore
also include the coordinator/router lifecycle changes made after the original Batch 105 snapshot.

## 静态证据

- `git diff --check HEAD`: rc 0，日志 `evidence/batch105-diff-check.log`。
- `PYTHONDONTWRITEBYTECODE=1 python3 tools/check_changed_sv_style.py --base HEAD`: rc 0，日志
  `evidence/batch105-style.log`；无 hard diagnostic。

## 源码与证据指纹

完整路径与 SHA-256 清单在
`evidence/batch105-artifact-sha256.txt`；关键源码指纹如下：

| 文件 | SHA-256 |
| --- | --- |
| `src/integration/rdma_device_env.sv` | `338818ce66cdf5c6c4959acaaaa0d36a91a079321366cef095f3d6d855468a0f` |
| `tests/integration/rdma_reset_cascade_test.sv` | `0117c2a4a29a4aeddcc8dc74b0364e9551f04d514b802d7a5e04155ec1a6edf0` |
| `src/integration/rdma_function_context.sv` | `8c429694125c1eede3df0c21a68a6d63909a907eb4a123fe1c7f700156975fa3` |
| `src/model/rdma_function_binding.sv` | `8aec2d7590ff3cf0de0f9357b0b7a601621fe2572aeb2ef2c4822dcbbf23c4d8` |
| `src/integration/rdma_reset_coordinator.sv` | `85a372f3d25530805ccb902e210e9888dfd5b82ef83a152abdf60eca231b61cc` |
| `src/integration/rdma_host_mem_router.sv` | `21e3940442a165cd75e429b2eb3bcb42b807c6016bd6c7565d9afe7d2d965274` |
| `tests/unit/rdma_reset_coordinator_test.sv` | `0beb81ce3d30dcb057f5beccd1d8c6edec8e1aa140b599d8703abca30f9844e8` |
| `scripts/run_queue_lifecycle_regression53.sh` | `407fc516ca784a13ab704389be80e96a1b61cce0d377b2180036773066457755` |
| `tests/integration/rdma_function_context_test.sv` | `04a8cc80bdf4222a60063b928274c2fc86f16ddd907b8af8f348ff2859c38980` |

本报告及证据只记录当前 worktree 的验证结果；未执行 reset、clean、merge、push 或
外部依赖修改。
