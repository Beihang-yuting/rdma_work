# CMQ Batch 117：claimed recovery attachment 扫描提取

本批继续收敛 queue-data engine 的 recovery 查询与执行边界。`recover_queue()` 在
unclaimed evidence handoff 之后，原本直接遍历 `attachments`，同时承担完整 queue
incarnation 比较、runtime 状态筛选和多 runtime 歧义判定；随后同一 task 又进入
reservation-only 查询、abort/detach 或 retry/replay。该扫描不需要查询 pending、访问
backing 或改变 runtime，却和有副作用阶段交错，增加了恢复顺序审查成本。本批只抽出
claimed candidate 的只读定位，不合并 reservation-only 扫描，也不修改外部依赖。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护的 `find_claimed_recovery_attachment()`，使用
    `attachment_matches_queue_identity()` 比较 kind、Function UID、object ID 和
    generation 的完整 incarnation；candidate、queue handle 或 runtime 缺失、identity
    不匹配、runtime 非 `RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED` 时均跳过。
  - 单个 matching claimed attachment 通过 `found` 输出；没有命中返回成功且
    `found=null`，由 `recover_queue()` 继续原 reservation-only 分支；同一完整 identity
    命中不同 runtime 时返回 `RDMA_SC_INVALID_STATE`，消息保持
    `queue has multiple pending recovery runtimes`。
  - `recover_queue()` 保留 unclaimed pair 校验、admission、map 删除和 handoff 优先级；
    helper 结果与既有 `found` 对象比较，同一 attachment 只接管一次，另一个 matching
    claimed runtime 仍按 ambiguity 拒绝。reservation 查询、action 判断、detach、runtime
    recover/query/replay 均留在 caller。
  - helper 只读 `attachments` 索引和 runtime state，不查询 pending/reservation，不删除
    map，不改 runtime/ledger，不访问 Host-memory、MMIO、QP link 或外部 mapping；局部
    `scan_key` 不污染 caller 的 unclaimed/reservation-only 索引键。

## 行为不变量

- unclaimed handoff 仍先于 claimed scan：admission 失败时保留 engine-owned evidence；
  admission 成功后同一 attachment 不重复接管，和另一个 matching runtime 并存时仍返回
  `RDMA_SC_INVALID_STATE`。
- foreign generation、不同 kind、Function/object identity 不匹配的 attachment 只被
  跳过；matching-but-null-runtime 也只被跳过，不提前伪造 `RECOVERY_REQUIRED`。无
  claimed candidate 时继续原 reservation-only 查询和 `queue has no pending recovery`
  错误路径。
- helper 不改变 `recover_queue()` 的 action 顺序：已有 `found` 时仍先处理
  `ABORT_AND_DETACH`，再检查非法 action、caller confirmation，最后调用 runtime
  recovery/replay；不把无 pending 路径改成非法 action 错误。
- 多 runtime ambiguity 在任何 reservation query、detach、MMIO 或 ledger mutation 前
  fail-closed；成功扫描本身不改变 attachment/runtime 生命周期，engine 仍只持有借用引用。

## 验证

所有 VCS 仿真均在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0；unclaimed handoff/abort、claimed detach failure、reservation-only 生命周期和 recovery fault 矩阵通过 |
| `rdma_queue_data_engine_recovery_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0 |
| `rdma_queue_data_engine_post_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0 |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `git diff --check` | PASS |

VCS 命令使用既有入口：
`SSHPASS=123 scripts/run_vcs53.sh core <test>`。本批没有修改测试 fixture、外部
`host_mem_manager.sv` 或 `pcie_work`；Python 292 单元门禁仍在当前分支通过，pytest
缺包限制不被伪装成业务结果。

## 源码指纹与遗留边界

- `src/core/rdma_queue_data_engine.sv` SHA-256：
  `0ebb629f85a928b3b9736df17c03562fe1815bb25feb431b5acf8e0e7ec596c6`
- 计划状态继续为 `active`；本批关闭的是 claimed candidate 定位的局部结构 seam，
  不宣称已完成 reservation-only 所有 hostile 组合、完整 SRQ/跨队列 lifecycle、
  device/consumer recovery 全阶段组合、Phase 1C F2 whole-plan authority、coordinator
  跨线程/跨进程并发或整份结构重构。
- `pcie_work` 的阻断文本仍必须保持：
  `external dependency is not approved: pcie_work`。
