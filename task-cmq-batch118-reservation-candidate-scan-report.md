# CMQ Batch 118：reservation-only candidate 扫描提取

本批继续基于重构后的 queue-data engine 收敛 `recover_queue()` 的职责边界。原有
reservation-only 分支在同一个 `attachments` 遍历中同时完成 queue identity/runtime
筛选、reservation 查询、action 判断以及 detach；只读筛选和有副作用阶段交错，
使首错优先级、借用引用生命周期和 recovery authority 难以单独复审。本批只提取
候选收集阶段，不改变 reservation evidence、错误码、detach 顺序或外部依赖契约。

## 实现边界

- `src/core/rdma_queue_data_engine.sv:1305-1334`
  - 新增受保护的 `collect_reservation_only_candidates()`。函数先清空 caller 提供的
    `candidates` 输出队列；`queue_h` 为空时返回空队列。
  - 按 `attachments` associative array 的既有 `foreach` 遍历顺序检查完整 queue
    incarnation。`attachment_matches_queue_identity()` 统一比较 kind、Function UID、
    object ID 和 generation；null candidate、null queue handle、foreign identity 或
    null runtime 均跳过。
  - 输出只保存 attachment/runtime 的借用引用，不取得 ownership、不延长任何对象
    生命周期；函数不查询 runtime state、pending 或 reservation，也不访问 Host-memory、
    MMIO、QP link、ledger、cursor、索引或外部 mapping。
- `src/core/rdma_queue_data_engine.sv:9532-9561`
  - `recover_queue()` 改为先调用候选收集 helper，再逐个执行原有
    `query_device_reservation()`。
  - null status 映射为 `RDMA_SC_RECOVERY_REQUIRED`、非成功 status 的立即返回、
    reservation-valid/action 判断、`detach_recovery_transaction()` 调用和成功/失败
    返回顺序均保留在 caller；unclaimed handoff 和 claimed scan 的优先级不变。
  - 本批没有新增测试 fixture、没有修改外部 `host_mem_manager.sv` 或 `pcie_work`，
    也没有改变 `attachments` 的生命周期管理。

## 行为不变量

- candidate collection 是只读、无 I/O 的结构阶段；没有匹配项时返回空队列，不能被
  解读为 reservation 已确认或 recovery 已完成。
- helper 只保持现有 associative `foreach` 的遍历顺序，不承诺跨实现的排序；caller
  仍在同一个 `recover_queue()` task 内立即查询并处理借用引用。未来若引入并发或
  callback，必须重新验证该引用的生命周期边界。
- foreign generation、不同 kind、Function/object identity 不匹配以及 null runtime
  均被忽略；第一个 reservation query 的 null/错误 status 仍具有原来的首错优先级。
- reservation 有效且 action 不是 `RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH` 时，仍返回
  原 `RDMA_SC_RECOVERY_REQUIRED`；有效 abort 仍只通过
  `detach_recovery_transaction()` 完成。helper 不新增多 reservation ambiguity 判定，
  也不改变无 pending 时的 `RDMA_SC_INVALID_STATE`。
- 本批明确不修复以下既有契约风险：非法 action 预检晚于 unclaimed handoff；未确认
  retry 可能发生 unclaimed→runtime ownership migration；reservation-only 多 matching
  candidate 尚未判 ambiguity；`runtime.recover()` confirmation 成功后
  `query_pending()` 失败时的一次性授权语义。它们应在独立契约修复/测试批次处理。

## 验证

所有 VCS 仿真均在 `ubuntu@10.11.10.53` 的登录 bash 环境，经由
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行。验收条件为 wrapper rc=0、
PROCESS/LOGICAL PASS，以及 UVM warning/error/fatal=0/0/0。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0；unclaimed/claimed authority、reservation-only abort/detach 与 fault-order 回归通过 |
| `rdma_queue_data_engine_recovery_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0；confirmed/unconfirmed retry、ambiguous evidence 与 recovery failure 路径通过 |
| `rdma_queue_data_engine_post_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0；post pipeline、RQ/SRQ 和既有 writer 约束通过 |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `git diff --check` | PASS |
| `python3 tools/check_queue_lifecycle.py` | PASS |
| `python3 tools/check_rdma_profile_names.py` | PASS |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_cmq_gate_manifest` | 22 tests；OK |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_sv_keyword_guards` | 3 tests；OK |
| `python3 tools/check_rdma_phase1a_approval.py` | PASS；四项 approval 均保持 APPROVED |
| `python3 -m unittest discover -s tests/unit -p 'test_*.py'` | 292 tests；OK（测试中预期的 synthetic git/CLI negative-path 输出不影响最终通过） |

Batch118 没有重新运行全目录中文 function/task、文件头和 method/comment scanner；
Batch111 的 185 `.sv`、2 `.svh`、5,387 methods、0 diagnostics 只作为历史证据，
不能冒充本批修改后的当前计数。pytest 仍因环境缺少 pytest 未执行，也不被记为业务
失败或 GREEN。

## 源码指纹与遗留边界

- `src/core/rdma_queue_data_engine.sv` SHA-256：
  `4807e21e93e3fb3eacddd1443cc563109253adcf810ddd6fce1937473197961f`
- 本批总 diff 为 54 行新增、24 行删除；重点是把 identity/runtime 筛选与
  reservation query/detach 的副作用阶段分开，行数增加主要来自契约注释，不把行数
  变化宣称为复杂度或功能减少。
- 计划状态继续为 `active`。reservation-only 多匹配、hostile action/未确认 retry
  authority、完整 SRQ/跨队列 lifecycle、device/consumer recovery 全阶段组合、Phase 1C
  F2 whole-plan authority、coordinator 跨线程/跨进程并发、全目录后续生命周期审计仍
  OPEN。
- `pcie_work` 的外部锁阻断文本必须保持：
  `external dependency is not approved: pcie_work`。

## Full-file review

提交前已从 `rdma_queue_data_engine.sv` 文件头复审至 EOF，确认新增 helper、caller
局部变量、中文三段函数说明、借用引用生命周期和 reservation/recovery 错误路径与现有
文件职责一致；没有发现需要在本批扩大到外部依赖或测试 fixture 的变更。
