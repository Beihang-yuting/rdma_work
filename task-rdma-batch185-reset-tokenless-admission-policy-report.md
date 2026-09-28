# RDMA Batch 185：reset admission policy characterization

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`，保留既有
reset epoch candidate、owner/token、router 和外部 manager 语义；项目级结构重构计划继续
保持 `active`。

## 实现边界

- `src/integration/rdma_reset_coordinator.sv` 新增无状态
  `rdma_reset_tokenless_admission_policy::evaluate()`，输入冻结的
  publication-active、transaction-active、cleanup 意图和 operation name，输出 detached
  `rdma_status`；`authorize_tokenless_dataplane()` 保持原有状态读取和调用位置，仅委托
  policy。
- Function/Host/Device epoch、owner/token、router binding 与外部 manager 生命周期均未
  移动或改写。policy 只覆盖同步 reset-admission：任一 reset 标志 active 且非 cleanup
  时返回 `RDMA_SC_RESOURCE_BUSY`；cleanup 或非 active 返回 OK；它不是跨线程、跨进程或
  仿真调度级互斥。
- `tests/unit/rdma_reset_coordinator_test.sv` 增加 detached matrix，覆盖 idle 放行、
  publication-only 拒绝、transaction-only 拒绝、combined-active 拒绝和 cleanup override
  放行；既有 epoch candidate 与 reset/lease/router fixture 保持不变。

## 验证

- `rdma_reset_coordinator_test`：需在 53 机登录 bash 中执行并确认 PROCESS/LOGICAL PASS，
  UVM WARNING/ERROR/FATAL 为 `0/0/0`。
- Python、changed-SV style、`git diff --check` 与全目录中文契约扫描在本批源码边界
  复跑；跨线程/跨进程锁、SRQ lifecycle、外部 PCIe ordering/error 和最终 ownership
  审计仍由后续批次负责。
