# CMQ Batch 122：local resource match scan 提取

本批继续基于 resource-manager 的类型化快照与 owner/incarnation 契约，收敛
`lookup_local_resource()` 中 registry 只读匹配和 detached 投影的职责边界。改动不改变
资源 key、Function authority、local-id wire 坐标或资源生命周期所有权；它只保证在
确认唯一 live candidate 之后才执行可能触发 factory 的 `project_resource_value()`。

## 实现边界

- `src/core/rdma_resource_manager.sv`
  - 新增受保护的 `scan_local_resource_matches()`，按完整 Function UID/object/generation、
    resource kind 和 local-id 遍历 `registry`，输出借用的唯一 live candidate，以及
    `found_stale`、`found_released` 和 `multiple_live` 证据。
  - helper 只读取 registry/resource 字段，不创建 `rdma_status`、不做 detached projection、
    不写 registry/staged/recovery 账本，也不取得 resource、Host-memory、PCIe 或其他
    外部对象的所有权。第二个 live candidate 只置 `multiple_live` 并停止扫描。
  - `lookup_local_resource()` 保留 owner/kind/local-id 前置校验和原错误优先级；收到唯一
    live candidate 后才调用 `project_resource_value()`，投影失败仍返回原 status 或
    `RDMA_SC_INVALID_STATE`，成功返回 detached resource 快照。

## 行为不变量与失败边界

- owner UID/object 不匹配的 registry entry 继续跳过；同 UID/object 但 generation 旧的
  entry 只置 `found_stale`，generation 检查仍先于 local-id 比较。
- 只有同一 local-id 且当前 generation 的 `RDMA_RESOURCE_RELEASED` entry 置
  `found_released`；`NEW`/`ERROR` entry 继续跳过。没有 live 命中时仍按 stale、released、
  unknown 顺序返回原错误码。
- 多个 live 命中在任何 projection/factory 分配前返回
  `RDMA_SC_INVALID_STATE`，且 `resource` 保持 null；这避免歧义路径发布半成品 detached
  snapshot。单一 live 命中仍保持原 projection、copy/alias 隔离和最终 `RDMA_SC_OK`。
- owner 为空、kind 非法、FUNCTION kind、local-id 超出硬件宽度、owner 状态不可用等
  前置拒绝仍由 caller 处理，helper 不重复推断默认 Function 或截断 local-id。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 的登录 bash 环境执行，入口为
`SSHPASS=123 scripts/run_vcs53.sh core <test>`。每项均满足 wrapper rc=0、PROCESS PASS、
LOGICAL PASS，且 UVM warning/error/fatal 为 `0/0/0`。

| 入口 | 结果 |
| --- | --- |
| `rdma_resource_manager_test` | PASS；resource allocation/projection、lifecycle、rollback 和 authority 边界通过 |
| `rdma_aeqe_route_test` | PASS；live/cross-Function/over-width/stale/released local lookup 通过 |
| `rdma_queue_recovery_test` | PASS；resource lookup 对 queue recovery/route 依赖无回归 |
| `rdma_queue_data_engine_post_test` | PASS；post、QP/RQ/SRQ/CQ 相关 resource lookup 无回归 |
| `git diff --check` | PASS |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `python3 tools/check_queue_lifecycle.py` | PASS |
| `python3 tools/check_rdma_profile_names.py` | PASS |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_cmq_gate_manifest` | 22 tests；OK |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_sv_keyword_guards` | 3 tests；OK |
| `python3 tools/check_rdma_phase1a_approval.py` | PASS；全部 approval 保持 APPROVED |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/unit -p 'test_*.py'` | 292 tests；OK；synthetic git/CLI negative-path stderr 为预期输出 |
| 当前源码全目录 scanner | 185 个 `.sv`、2 个 `.svh`，共 5,406 个 function/task（`.sv` 5,404、`.svh` 2）、0 diagnostics |

pytest 因环境缺少 pytest 未执行，不记为业务失败或 GREEN。`pcie_work` 仍按既有边界保持唯一阻断文本：
`external dependency is not approved: pcie_work`。

## 源码指纹

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_resource_manager.sv` | `27df8e94619111479e5c007ee83d270637f01066af9060940f6d2de8c33a0073` |

相对 Batch121 提交，本批只修改 resource-manager source，diff 为 80/33（新增/删除）行；
新增内容主要是只读匹配 helper 与 caller 的投影边界，删除内容是原 inline registry loop，
不把行数变化宣称为完整 resource-manager 复杂度收口。

## 遗留并发与范围风险

- `registry` 扫描、owner binding 校验与后续 projection 之间仍没有 manager-level 全局并发
  锁；并发 registration/release 需要后续原子性契约。
- duplicate-live 的 fail-closed 只覆盖本地 lookup cardinality；跨 manager、跨 Function
  reset incarnation、QP/queue transient alias 与更深 recovery/MMIO 生命周期仍由既有
  owner 契约维护。
- 完整 SRQ/跨队列 lifecycle、consumer/device recovery 组合矩阵、Phase 1C F2、coordinator
  跨线程/跨进程锁、manager 外部调用窗口补偿和 `pcie_work` 外部依赖锁仍 OPEN。

## Full-file review

提交前已从文件头到 EOF 复审 `src/core/rdma_resource_manager.sv`，重点核对 registry
遍历顺序、owner/generation/local-id 权威、released/stale/cardinality 优先级、projection
与 factory 生命周期、资源所有权、复位边界、中文三段函数注释和稀疏排版；未发现需要
扩大到外部依赖或改变 resource lifecycle 契约的问题。
