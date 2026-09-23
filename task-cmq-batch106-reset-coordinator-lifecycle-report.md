# CMQ Batch 106：reset coordinator 生命周期与 epoch 事务收口

本批沿着 Batch 105 的 candidate seal 继续复审 reset coordinator、Host-memory router
和 device-env 的生命周期边界。目标是让 registration、Function/Host/Device epoch 和
router-local Host epoch 在同一 scope 中先完成容量/authority 预检，再发布可观察副作用。
本批不宣称提供跨线程/跨 env 的全局锁，也不关闭 Phase 1C F2 或整个结构重构计划。

## 实现边界

- `src/integration/rdma_reset_coordinator.sv`
  - registration 保存不可变 Function snapshot 及其 absolute epoch baseline；重新登记只接受
    coordinator 推导出的当前 generation/reset_epoch，拒绝未来跳跃、回退、重复 stable key、
    跨 route UID/global Function ID 重用。
  - PF、Host、Device reset 先构造 detached `staged_epochs`，所有 Function capacity、generation
    和 absolute counter 预检通过后才整体替换 map；后续 Function 失败不会留下部分 bump。
  - Host reset 在调用 router 前检查 router-local capacity；router advance 返回 `rdma_status`，
    因而 Host/Function ledger 与外部 local epoch 的拒绝路径可观察且 fail-closed。
- `src/integration/rdma_host_mem_router.sv`
  - 新增只读 `validate_host_epoch_capacity()`；local epoch 达到全一最大值时拒绝递增，未配置
    route 保留旧的成功 no-op 兼容语义，不隐式创建 Host route。
- `src/integration/rdma_device_env.sv`
  - 保留 Batch 105 的 detached candidate value-graph fingerprint/无回调 verify，并新增
    env-local `m_reset_in_progress` guard；virtual prepare/validate 回调内同步重入的
    `request_*_reset()` 返回 `RDMA_SC_RESOURCE_BUSY`。
- `tests/unit/rdma_reset_coordinator_test.sv`
  - lifecycle focused fixture 覆盖 registration baseline、当前 incarnation 重登记、未来跳跃、
    回退、duplicate key/UID/global ID、Function/PF/Host/Device/router-local overflow、PF
    scope staged atomicity 和 env guard。
- `scripts/run_queue_lifecycle_regression53.sh`
  - 将 lifecycle 与 PF-root scope test 纳入 integration/unit manifest，保持既有入口兼容。

## VCS53 验证

所有仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行，远端依赖为
`DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common`，VCS 为 `W-2024.09-SP1_Full64`。
每个 wrapper 均 `rc=0`，PROCESS/LOGICAL 为 `1/1`，UVM warning/error/fatal 为 `0/0/0`。

| 测试 | 日志 | 日志 SHA-256 |
| --- | --- | --- |
| `rdma_reset_coordinator_test` | `evidence/batch106-rdma_reset_coordinator_test.log` | `4c782de3a500efd4ce3dcffab2f26dc03278ab62de390e54436c56d8d69cc906` |
| `rdma_reset_coordinator_pf_root_scope_test` | `evidence/batch106-rdma_reset_coordinator_pf_root_scope_test.log` | `26e157095d1275a71f6b596f829c9888f1094a9daed1237b814c584a9d2cb6b4` |
| `rdma_reset_coordinator_lifecycle_test` | `evidence/batch106-rdma_reset_coordinator_lifecycle_test.log` | `48a7e1e95ff89999c26cfb2b266ec854efa4a9549553eefd246c4650ee8d43c9` |
| `rdma_reset_candidate_integrity_test` | `evidence/batch106-rdma_reset_candidate_integrity_test.log` | `8e304df2b166e07cd415599a8b7004bfd40024307d42a8819dfe67fde2bd232e` |
| `rdma_reset_cascade_test` | `evidence/batch106-rdma_reset_cascade_test.log` | `291dcc9aad4aa49251b1f033ece99ba7b631cd5e1da289c1dff8197f7a67495b` |
| `rdma_function_context_test` | `evidence/batch106-rdma_function_context_test.log` | `549de3537895c1e48bee657ff38be5bbb5ec6e93ae735330c8fa34654ca36ca3` |
| `rdma_device_env_test` | `evidence/batch106-rdma_device_env_test.log` | `9a7730b4b5aa4f252ad180ae9a655e9ed29d57c09d4face067c2b5590f2dffd8` |
| `rdma_host_mem_router_test` | `evidence/batch106-rdma_host_mem_router_test.log` | `8ffdfbfc4d1b02346867d38d1bbbe05f290c9ed0fc61ec7a4486a3d916a02d7c` |

八个日志均以 `UVM report is pristine: warning=0 error=0 fatal=0` 结束，并保留 wrapper
`BATCH106_RC=0` 标记。完整源码/日志/静态证据指纹见 `evidence/batch106-artifact-sha256.txt`
和 `evidence/batch106.meta`。

## 本地静态门禁

- Python unittest：292 项通过；CMQ manifest：22 项通过；SV keyword guard：3 项通过。
- `check_queue_lifecycle.py`、`check_rdma_profile_names.py`、Phase 1A approval checker、
  changed-SV style 和 `git diff --check HEAD` 均返回 rc 0。
- 当前 `src/`、`tests/`、`sim/` 的 185 个 `.sv` 与 codec `.svh` 文件声明/文件头扫描共计
  5,316 个 function/task，0 diagnostics；扫描摘要见 `evidence/batch106-contract-scan.log`。

## 未关闭边界

- `m_reset_in_progress` 只是单个 `rdma_device_env` 的同步重入 guard，不是 coordinator 的
  全局并发锁；跨 env/thread serialization 仍需后续设计与验证。
- 广义 Phase 1C F2 的 `sge_num` canonical-authority/whole-plan 收口仍暂停。
- `pcie_work` 外部锁保持 OPEN，阻断文本必须继续是
  `external dependency is not approved: pcie_work`；未修改外部依赖。
- parent/core 全回归需要在这组源码冻结后另行刷新；本批 acceptance 仅覆盖上述 focused reset
  suite 和本地静态门禁。

本批未执行 reset、clean、merge、push 或外部依赖修改；工作树已有改动均予以保留，结构重构计划
继续保持 `active`。
