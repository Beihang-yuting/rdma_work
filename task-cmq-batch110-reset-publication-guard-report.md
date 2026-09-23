# CMQ Batch 110：reset publication guard 与当前源码验证

本批承接 Batch 109 的一对一 coordinator ownership/close seam，收口同一个
SystemVerilog function 调用栈内的 reset publication callback 重入。所有改动仅位于本项目；
没有修改外部依赖，也没有执行 reset、clean、merge 或 push。结构重构计划继续保持
`active`，本报告不把本批 GREEN 扩大解释为整份计划完成。

## 实现边界

- `src/integration/rdma_reset_coordinator.sv`
  - 增加 `m_reset_operation_active` 同步 publication guard，并提供
    `enter_reset_operation()`、`leave_reset_operation()` 和
    `finish_reset_operation()` 三个受保护 seam。
  - `request_vf_flr`、`request_pf_reset`、`request_host_reset`、
    `request_device_reset` 拆为受保护 implementation 与公开 wrapper；wrapper 在
    implementation 前取得 guard、在成功/错误/null-status 返回路径统一释放 guard。
  - implementation 返回 null status 时规范化为 `RDMA_SC_INVALID_STATE`；已有 guard 的
    同步嵌套入口返回 `RDMA_SC_RESOURCE_BUSY`，不触碰 Function/Host/Device ledger。
  - 注释明确该标志只覆盖同步调用栈，不是跨线程、跨进程或仿真调度级互斥；lease/token
    仍是跨 env ownership authority。

- `tests/unit/rdma_reset_coordinator_test.sv`
  - Host-router overflow fixture 改为先 attach、再注入 router-local `EPOCH_MAX`，避免
    首次 attach 的 `reset_local_host_epochs()` 清掉故障值。
  - publication guard focused 场景在清除测试 seam 后验证 legacy 空 Function scope 的
    Device reset 成功并推进 `device_epoch`；这与 coordinator 现有独立 Device publication
    语义一致，不再把它误判为 `INVALID_STATE`。

## VCS53 验证（当前源码边界）

所有仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行；
integration 使用 `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common`。验收条件为
wrapper rc=0、PROCESS/LOGICAL PASS，以及严格 UVM warning/error/fatal=0/0/0。

| 验证入口 | 结果 | 证据 |
| --- | --- | --- |
| `rdma_reset_coordinator_test` | rc=0；1/1；UVM 0/0/0 | `evidence/batch110-rdma_reset_coordinator_test.log` |
| `rdma_reset_coordinator_lifecycle_test`（修复后重跑） | rc=0；1/1；UVM 0/0/0 | `evidence/batch110-rdma_reset_coordinator_lifecycle_test.log` |
| `rdma_host_mem_router_test` | rc=0；1/1；UVM 0/0/0 | `evidence/batch110-rdma_host_mem_router_test.log` |
| `rdma_device_env_test` | rc=0；1/1；UVM 0/0/0 | `evidence/batch110-rdma_device_env_test.log` |
| `rdma_function_context_test` | rc=0；1/1；UVM 0/0/0 | `evidence/batch110-rdma_function_context_test.log` |
| `rdma_reset_cascade_test` | rc=0；1/1；UVM 0/0/0 | `evidence/batch110-rdma_reset_cascade_test.log` |
| integration regression（manifest 10 tests） | rc=0；10/10；每项 UVM 0/0/0 | `evidence/batch110-integration-regression.log` |
| CMQ gate regression | rc=0；28/28 process、11/11 logical；UVM 0/0/0 | `evidence/batch110-cmq-gate-regression.log` |
| core regression | rc=0；95/95 process、78/78 logical；UVM 0/0/0 | `evidence/batch110-core-regression.log` |
| `rdma_defs` contract/oracle | rc=0；203 tests；definitions/oracle/field ownership PASS | `evidence/batch110-rdma_defs.log` |

修复前的 lifecycle 两错误日志（`rdma_batch110_lifecycle_guard_retry.log`）仅作诊断，
没有复制进本批 GREEN 证据索引。

## 静态门禁与源码指纹

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292。
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22；SV keyword guard：3/3。
- queue lifecycle、profile names、Phase-1A approval：全部 rc=0/PASS。
- `PYTHONDONTWRITEBYTECODE=1 python3 tools/check_changed_sv_style.py --base HEAD`：rc=0，
  hard diagnostics=0；`git diff --check HEAD`：rc=0。
- 全目录 `sanitize_source`/`method_ranges`/`check_method_comments`/`check_file_header`
  scanner 覆盖 185 个 `.sv` 与 2 个 `.svh`，其中 `.sv` 5,380 个、`.svh` 2 个，合计
  5,382 个 function/task，0 diagnostics；可重现输出见
  `evidence/batch110-contract-scan.log`。

Batch110 evidence 元数据与日志位于 `evidence/batch110.meta`，当前变更源文件的逐文件
SHA-256 位于 `evidence/batch110-artifact-sha256.txt`；本批源码/测试/脚本与文档均以该清单对应的
当前工作树为准，不能复用更早源码边界的旧日志。

## 遗留边界

- publication guard 不是抢占式全局并发锁；跨线程/跨进程 coordinator ownership 和更深
  生命周期语义仍需后续设计与审计。
- Phase 1C F2 的广义 `sge_num` canonical-authority/whole-plan 收口仍暂停；本批没有
  扩大数组或修改 wire/外部 ABI。
- `pcie_work` integration 仍受外部锁阻断；唯一阻断文本必须保持：
  `external dependency is not approved: pcie_work`。
