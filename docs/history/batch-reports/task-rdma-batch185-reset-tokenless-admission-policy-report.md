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

## 主线历史记录与合并复验

2026-09-28 合并前，主线原改动已独立保存为 `bec0f8f`；以下保留其完整历史记录。
当前复验 `rdma_reset_coordinator_test` 在 VCS53 登录 bash 通过，UVM 0/0/0、wrapper rc=0，
见 `/tmp/rdma_merge222_main_reset.log`；重构分支最终全量证据见 Batch221 报告。
历史工作树、计数和“待复验”描述不代表合并后的验证状态。

# RDMA Batch 185：reset admission policy characterization

日期：2026-09-24。工作树：`main`，基线为当前工作树 `HEAD=94ba894`。本批选择
reset/coordinator 的最小 detached seam，不引入跨线程锁，也不改变既有 reset、router
或 manager 的业务顺序；结构重构计划继续保持 `active`。

## 实现边界

- `src/integration/rdma_reset_coordinator.sv`
  - 新增无状态 `rdma_reset_tokenless_admission_policy::evaluate()`，输入冻结的
    publication-active、transaction-active、cleanup 意图和 operation name，输出
    detached `rdma_status`。
  - `authorize_tokenless_dataplane()` 保持原有输入、状态读取和调用位置，仅委托该
    policy；Function/Host/Device epoch、owner/token、router binding 与外部 manager
    生命周期均未移动或改写。
  - policy 明确只覆盖同步 reset-admission：任一 reset 标志 active 且非 cleanup 时
    返回 `RDMA_SC_RESOURCE_BUSY`；cleanup 或非 active 返回 OK。它不是跨线程、跨进程
    或仿真调度级互斥。

- `tests/unit/rdma_reset_coordinator_test.sv`
  - 在现有 coordinator fixture 前加入五行 detached matrix：idle 放行、publication-only
    拒绝、transaction-only 拒绝、combined-active 拒绝、cleanup override 放行。
  - 测试只读取 policy 返回值，不注入或修改 coordinator ledger；既有 reset/lease/
    router integration 断言保持原样。

## 验证与证据

所有 VCS 仿真均通过 `SSHPASS=123 scripts/run_vcs53.sh integration
rdma_reset_coordinator_test` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| Entry | Result |
| --- | --- |
| `rdma_reset_coordinator_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM INFO=3、WARNING/ERROR/FATAL=0/0/0 |
| Python unit suite | `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292，OK |
| changed-SV style | `python3 tools/check_changed_sv_style.py --base HEAD`：PASS |
| diff whitespace | `git diff --check`：PASS |
| 中文契约扫描 | 当前源码边界 5,489 methods，0 diagnostics |

## 未关闭边界

本批不声称关闭 coordinator 跨线程/跨进程全局锁、跨队列 CQ→WQ 并发、engine-level
全局锁、manager 外部调用窗口补偿、SRQ lifecycle、legacy descriptor、外部 PCIe
ordering/error 或最终 ownership 审计。新增 policy 只是可独立复用和验证的同步 admission
characterization，不能替代这些并发与生命周期工作。
