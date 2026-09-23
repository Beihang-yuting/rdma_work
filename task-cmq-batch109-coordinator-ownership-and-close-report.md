# CMQ Batch 109：coordinator ownership、双侧解绑与 close 生命周期

本批承接 Batch 108 的只读 ownership 审计，采用严格一对一的
`coordinator ↔ device_env ↔ Host-router` 绑定契约。目标是让 reset transaction、
registration、context candidate 和 router mapping 在同一 owner/token 边界内完成，
并让 `rdma_device_env::close()` 以双侧解绑结束生命周期。本批只修改本项目；没有
修改外部依赖，也没有执行 reset、clean、merge 或 push。结构重构计划仍保持
`active`，本报告不把 Batch 109 GREEN 扩大解释为整个计划完成。

## 实现边界

- `src/integration/rdma_reset_coordinator.sv`
  - 增加一对一 lease owner/token；`acquire_lease()`、`release_lease()`、
    `begin_reset()`、`end_reset()` 和 `authorize_owned_operation()` 统一检查
    transaction 入口。lease 只保存非拥有 owner 句柄，不充当仿真线程锁。
  - registration、Function/Host/Device epoch 仍采用 detached staging 和容量预检；
    active transaction 中的 tokenless direct registration/reset/context callback
    fail-closed。
  - coordinator/router attach 改为 bilateral owned attach/detach。legacy facade 通过
    coordinator 生成的一次性 capability 完成握手；仅伪造
    `coordinator_initiated=1` 不再取得绑定权限。
  - 不允许单侧 detach 或跨 coordinator replacement；有 active mapping 时保持旧
    binding 并返回 `RDMA_SC_RESOURCE_BUSY`，避免 epoch authority 分叉。

- `src/integration/rdma_host_mem_router.sv`
  - 保存非拥有 coordinator 引用，增加 active mapping guard、router-local epoch
    capacity 检查和 bilateral detach seam；mapping 释放/回滚仍保留旧的 stale-mapping
    兼容语义。
  - `read/write/release/release_opaque` 没有额外强制 lease gate，这是为保留已存在的
    stale mapping 与 rollback 行为，transaction 边界由 attach、detach 和 reset epoch
    publication 负责。

- `src/integration/rdma_device_env.sv`
  - `build()` 的可选 coordinator 形参显式声明为 `input ... = null`，避免 VCS 对 output
    形参之后的 class handle 方向推导异常导致调用方 coordinator 丢失。
  - reset scope 取得 lease 后，先冻结 detached candidate/value graph，再按
    preflight→quiesce→validate→epoch→commit 顺序执行；失败时释放 transaction 并保留
    原 context/binding。
  - `close()` 以双侧 owned detach、lease release 和非拥有引用清理结束生命周期；重复
    close 幂等，关闭后 reset/查询拒绝。

- `src/integration/rdma_function_context.sv`
  - candidate 以 source identity/binding/state marker 和 no-allocation value-graph seal
    绑定当前 context；`commit_reset()`、owned prevalidated commit 和 void prevalidated
    commit 均在最终 assignment 前复核 generation 前进、reset_epoch 不回退、binding
    snapshot 与 owner handle。
  - standalone/no-lease context 保留旧的 direct reset 兼容语义；leased context 的
    tokenless direct mutation 返回 busy/拒绝。
  - `candidate_matches_context_noalloc()` 显式拒绝 null context identity/binding，避免
    防御性检查自身产生空句柄解引用。

- 测试与 manifest
  - `rdma_function_context_test` 覆盖 validation 后 coherent generation 回退、owned
    prevalidated 与 void prevalidated reset_epoch 回退，并断言拒绝路径不改变
    identity/binding/state。
  - `rdma_device_env_test` 覆盖 close 双侧解绑、lease 释放、重复 close 幂等和关闭后
    查询/reset 拒绝。
  - `rdma_host_mem_router_test` 覆盖 active mapping 下跨 coordinator/foreign rebind、
    单侧 detach、伪造 capability 和 lease release 的失败原子性。
  - `rdma_reset_coordinator_test`、PF-root scope、lifecycle 与 candidate-integrity
    测试继续覆盖 registration incarnation、epoch staging、overflow、callback reentry
    和 detached candidate seal。

## VCS53 验证（当前源码边界）

所有仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 的登录 bash 环境执行，
integration 使用 `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common`，VCS 为
`W-2024.09-SP1_Full64`。验收条件为 wrapper rc=0、PROCESS/LOGICAL PASS，以及严格
UVM warning/error/fatal=0/0/0。

| 验证入口 | 结果 |
| --- | --- |
| `rdma_function_context_test` | rc=0；1/1；UVM 0/0/0 |
| `rdma_device_env_test` | rc=0；1/1；UVM 0/0/0 |
| `rdma_host_mem_router_test` | rc=0；1/1；UVM 0/0/0 |
| `rdma_reset_coordinator_test` | rc=0；1/1；UVM 0/0/0 |
| `rdma_reset_coordinator_lifecycle_test` | rc=0；1/1；UVM 0/0/0 |
| integration regression（manifest 10 tests） | rc=0；10/10；每项 UVM 0/0/0 |
| CMQ gate regression（当前源码） | rc=0；28/28 process、11/11 logical；UVM 0/0/0 |
| core regression（当前源码） | rc=0；95/95 process、78/78 logical；UVM 0/0/0 |
| changed-SV/style/manifest/contract static gate | rc=0；185 `.sv` + 2 `.svh`；5,346 methods；0 diagnostics；Python 292/292；manifest/style/keyword/queue/profile 38/38 |

本批当前受影响 SV/测试文件的排序 sha256 聚合为
`1bea8cac258318a5c61a5dbc2c4c077a0d6131cc0459643bd05e29f73c8c9468`；全目录
`src/tests/sim` canonical source aggregate 为
`4dd4a8f3eb6d8444df779812b207d6fdafbab9218f2856242817046e2c08ad8`（HEAD
`83a67db3224b03d0edcbdb9893a5d03c00f4e83a`；该聚合在最终 helper guard 修改后重新计算）。
CMQ gate、core gate 与最终静态门禁均已在该指纹下刷新，不能复用更早批次的旧日志。

## 静态与遗留边界

- 最终门禁需确认 `git diff --check`、changed-SV style、queue/profile/manifest/keyword
  检查、全目录中文 function/task/file-header scanner 和 Python unittest；新增/修改
  文件的注释必须与当前实现同步。
- 广义 Phase 1C F2 的 `sge_num` canonical-authority/whole-plan 收口仍暂停；本批没有
  扩大数组或修改 wire/外部 ABI。
- coordinator 更深的跨仿真线程/跨环境全局并发语义仍是 OPEN：当前 lease 是同步
  ownership/transaction admission，不是抢占式锁。
- `pcie_work` integration 仍受外部锁阻断；唯一阻断文本必须保持：
  `external dependency is not approved: pcie_work`。
