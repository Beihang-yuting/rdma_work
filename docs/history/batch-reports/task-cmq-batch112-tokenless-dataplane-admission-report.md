# CMQ Batch 112：tokenless dataplane reset admission

本批承接 Batch 111 的 coordinator mutation guard，把绑定 coordinator 的
Host-memory router 数据面入口纳入同一同步 reset-admission 契约。目标是让
`allocate()`、`write()`、`read()` 在 reset transaction 或 publication window 内
fail-closed，同时保留 `release()`/`release_opaque()` 作为明确的 stale-drain 与
allocation-rollback cleanup seam。所有改动仅位于本项目；没有修改外部依赖，也没有
执行 reset、clean、merge 或 push。结构重构计划继续保持 `active`。

## 实现边界

- `src/integration/rdma_reset_coordinator.sv`
  - 新增 `authorize_tokenless_dataplane()`，统一观察
    `m_reset_operation_active` 和 `m_reset_transaction_active`；普通数据面在任一
    同步 reset 窗口内返回 `RDMA_SC_RESOURCE_BUSY`，cleanup 入口可显式声明 drain
    语义继续执行。
  - 该 seam 明确只是同一 SystemVerilog 调用栈的 admission 检查，不是跨线程、跨
    进程或仿真调度级锁；manager 外部调用期间的同步重入仍由返回后的二次检查与
    opaque rollback 处理。

- `src/integration/rdma_host_mem_router.sv`
  - `allocate()` 在调用外部 manager 前后各做一次 dataplane admission，并在后一次
    检查失败时以 `release_opaque()` 回滚尚未写入 router ledger 的 backing，保持
    manager/router 两侧 failure-atomic。
  - `write()`/`read()` 在 manager 调用前拒绝 active reset；`read()` 入口及所有
    失败路径清空 output data，避免调用方误用旧数据。
  - `release()`/`release_opaque()` 明确允许在 reset active 时排空 current/stale
    mapping；manager 失败或 null status 时保留 ledger 供重试。

- `tests/unit/rdma_host_mem_router_test.sv`
  - 覆盖 publication-only guard（transaction 未开启）、active reset、manager
    同步重入、opaque rollback、cleanup release/retry，以及 Host reset 后携带当前
    Function incarnation 的 fresh context allocate/write/read 恢复路径。
  - 对拒绝路径断言 manager call count、router ledger 和 read output 均无意外副作用。

## 当前源码验证

源码提交指纹：`367a75bb909ac19abecc15c043ce4b95d6595f8b`。

所有 VCS 仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 的登录 bash
环境执行，integration 使用 `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common`，
严格 UVM warning/error/fatal 均为 `0/0/0`。

| 验证入口 | 当前结果 |
| --- | --- |
| `rdma_host_mem_router_test` | rc=0；1/1；UVM 0/0/0 |
| `rdma_reset_coordinator_test` | rc=0；1/1；UVM 0/0/0 |
| integration regression | rc=0；10/10；每项 UVM 0/0/0 |
| Python unit suite | 292/292；OK |
| changed-SV style / `git diff --check` | PASS |

## 未关闭边界

- manager 的外部同步调用窗口不能被本批描述成跨线程原子锁；`write()` 在 manager
  已产生不可撤销副作用后没有通用补偿机制，调用方仍需遵守外部 manager 契约。
- Phase 1C F2 的广义 `sge_num` canonical-authority/whole-plan 收口仍暂停；本批
  没有修改 wire 坐标或外部 ABI。
- `pcie_work` integration 仍受外部锁阻断；唯一阻断文本必须保持：
  `external dependency is not approved: pcie_work`。
