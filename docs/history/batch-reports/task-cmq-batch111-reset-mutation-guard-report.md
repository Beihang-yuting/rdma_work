# CMQ Batch 111：reset mutation guard 与 Host epoch capability

本批承接 Batch 110 的同步 publication guard，继续收紧同一个 SystemVerilog function
调用栈内仍可绕过 guard 的 coordinator/router 可变入口。目标是让同步 publication
期间的 direct mutation 和 legacy Host epoch callback 都 fail-closed，同时保留
coordinator 已完成 owner/token 校验后的一次性内部 publication seam。本批只修改本项目；
没有修改外部依赖，也没有执行 reset、clean、merge 或 push。结构重构计划继续保持
`active`，本报告不把本批验证扩大解释为整份计划完成。

## 实现边界

- `src/integration/rdma_reset_coordinator.sv`
  - 复用统一 `reject_mutation_during_reset_operation()` seam，并让
    `validate_operation_lease()` 在 `allow_active=0` 时拒绝 publication window 内的
    direct mutation；不经统一 lease validator 的 `acquire_lease()`、`begin_reset()`、
    `end_reset()` 和 legacy `attach_host_router_status()` 入口也先经过同一 guard。
  - `end_reset()` 在同步 callback 仍处于 publication window 时 fail-closed，避免 callback
    提前结束 transaction 后继续改写 Function/Host/Device ledger；正常
    `request_*` wrapper 返回后才由外层清理 guard。
  - 新增 `rdma_reset_router_epoch_capability` 及 coordinator 暂存的目标 Host/方向信息。
    `request_host_reset_impl()` 以一次性 opaque capability 调用 router 的 Host epoch
    capacity/advance seam；legacy callback 不能再伪造 `allow_active=1` 绕过 publication
    guard。capability 在正常返回、错误返回和 `release_lease()`/初始化路径均清理。

- `src/integration/rdma_host_mem_router.sv`
  - `authorize_router_operation()` 在 router 已绑定 coordinator 时始终回到 coordinator
    做 guard/lease 校验；只有真正未绑定（`m_reset == null`）才保留 legacy null/0 语义。
  - `validate_host_epoch_capacity()` 与 `advance_host_epoch()` 接受可选 publication
    capability；无 capability 的 direct callback 在 publication active 时 fail-closed，
    只有 coordinator-issued capability 能进入内部 active publication。

- `tests/unit/rdma_reset_coordinator_test.sv`
  - lifecycle fixture 覆盖 legacy callback acquire lease、legacy attach/rebind、
    registration commit、router configure、direct Host epoch capacity/advance、
    begin/end/release reset transaction，以及 leased router attach/detach/rebind 和
    leased registration commit；guard 清除后再确认正常 end/detach/release。
  - router fixture 改为 `rdma_reset_host_router_probe`，先完成 attach 再注入 local
    `EPOCH_MAX`，避免首次 attach 的 local epoch reset 清掉故障注入值；半授权 owner/token
    改为合法 legacy `null/0`，使拒绝原因对应当前契约。

## 当前源码验证

所有 VCS 仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行，
integration 使用 `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common`，VCS 为
`W-2024.09-SP1_Full64`。严格验收条件为 wrapper rc=0、PROCESS/LOGICAL PASS，以及
UVM warning/error/fatal=0/0/0。

| 验证入口 | 当前结果 | 证据 |
| --- | --- | --- |
| `rdma_reset_coordinator_test` | rc=0；1/1；UVM 0/0/0 | `evidence/batch111-rdma_reset_coordinator_test.log` |
| `rdma_reset_coordinator_lifecycle_test` | rc=0；1/1；UVM 0/0/0 | `evidence/batch111-rdma_reset_coordinator_lifecycle_test.log` |
| 其余 focused（host router/device env/function context/reset cascade） | rc=0；4/4；每项 UVM 0/0/0 | `evidence/batch111-rdma_host_mem_router_test.log`、`batch111-rdma_device_env_test.log`、`batch111-rdma_function_context_test.log`、`batch111-rdma_reset_cascade_test.log` |
| integration regression（manifest 10 tests） | rc=0；10/10；每项 UVM 0/0/0 | `evidence/batch111-integration-regression.log` |
| CMQ gate regression | rc=0；28/28 process、11/11 logical；UVM 0/0/0 | `evidence/batch111-cmq-gate-regression.log` |
| Python unit suite | 292/292；OK | `evidence/batch111-python.log` |
| static gates | Python 292、manifest 22、SV keyword 3、style/diff/auxiliary 全部通过；当前 scanner 185 `.sv` + 2 `.svh`、5,387 methods、0 diagnostics | `evidence/batch111-contract-scan.log`、`evidence/batch111-static-aux.log` |
| core regression | rc=0；95/95 PROCESS、78/78 LOGICAL；UVM 0/0/0 | `evidence/batch111-core-regression.log` |

日志由当前 feature worktree 的 `scripts/run_vcs53.sh` wrapper 生成并冻结到 evidence 目录；
integration/CMQ refresh 同时保留对应的 `/tmp/rdma_batch111_*.log`，六个 focused 日志直接
写入 evidence。integration regression 与 focused 日志已在注释/文件头复审后的当前源码边界刷新。
静态 scanner 已在当前源码边界覆盖 185 个 `.sv`、2 个 `.svh`，共 5,387 个
function/task、0 diagnostics。core 旧日志曾在错误 worktree 编译，已明确排除；本批使用
`evidence/batch111-core-regression.log` 的当前 worktree 95/95、78/78 GREEN 结果，最终
源码和证据 SHA 已写入 `evidence/batch111.meta` 与 `evidence/batch111-artifact-sha256.txt`。

## 未关闭边界

- `m_reset_operation_active` 及 epoch capability 只覆盖同步 function call stack；它们不是
  跨线程、跨进程或仿真调度级全局锁。coordinator 更深并发/生命周期语义仍需后续设计。
- Host-router 的 tokenless dataplane `allocate()`、`write()`、`read()`、`release()` 和
  `release_opaque()` 本批没有强行纳入同步 guard；这些入口仍需结合 mapping stale/rollback
  兼容语义设计更深的 reset-admission 与生命周期契约，当前保持 OPEN。
- Phase 1C F2 的广义 `sge_num` canonical-authority/whole-plan 收口仍暂停；本批没有扩大
  数组或修改 wire/外部 ABI。
- `pcie_work` integration 仍受外部锁阻断；唯一阻断文本必须保持：
  `external dependency is not approved: pcie_work`。
