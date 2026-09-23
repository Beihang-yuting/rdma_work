# Batch158：设备发布 reservation/polarity admission 收缩

日期：2026-09-23。工作树：`feature/rdma-structural-refactor-batch158`，基线：
`33be6c7`。

本批只收束 `src/core/rdma_queue_data_engine.sv` 中 CQE、CEQE 和 AEQE 三个设备
producer 发布入口重复的 reservation/polarity admission。各入口的 Function/route
authority、codec 顺序、AEQE reservation 后 route/epoch 复核、设备写入与 commit
所有权保持在原调用点；本批不改变 driver wire 坐标、外部依赖或 runtime ledger
语义，结构重构计划继续保持 `active`。

## 共享 admission seam

- `reserve_device_publish_checked()` 统一清空 `reservation`/`status`，检查
  `attachment.runtime`，调用 `reserve_device_producer()`，并将 null status、非成功
  status 和“成功但没有 cursor”统一为可观察的非空失败。成功时只返回 runtime 保留的
  runtime 内部保留 reservation、对外返回 detached 快照；task 不编码、不写 backing、
  不推进 committed cursor，也不取得外部资源生命周期所有权。
- `check_device_publish_polarity()` 接受 `inout reservation`，依据同一 reservation
  计算 runtime expected polarity，并比较 CQE 的 `model.polarity`、CEQE 的 `model.valid`
  或 AEQE encode model 的 `valid`。匹配时保留 reservation 供 caller 继续编码；不匹配
  时复用 `finish_device_producer_cancel()`，保持原有 cancel/recovery 证据路径，并在
  返回前清零 reservation，防止 caller 误用已取消 cursor。
- 两个 task 都是 protected、非 virtual 的结构辅助，不包含 codec registry、Host-memory
  或 MMIO 操作；caller 继续决定错误标签和后续 `write_commit_device_entry()` 是否可达。

## 三个入口的顺序与不变量

| 入口 | 保留的调用顺序 | 本批不改变的副作用边界 |
| --- | --- | --- |
| `publish_cqe()` | CQE authority → reservation helper → polarity helper → codec lookup/cast/encode → `write_commit_device_entry()` | authority 失败不 reserve；codec 失败仍走原 cancel/recovery；写后 failure 仍由统一 commit tail 处理 |
| `publish_ceqe()` | CEQE authority → reservation helper → polarity helper → CEQE codec/PI 校验 → `write_commit_device_entry()` | RC PI/已提交 cursor 检查仍位于 codec 前后的原位置；CQ cursor 不被 CEQE 发布改写 |
| `publish_aeqe_common()` | AEQE authority → `prepare_aeqe_publish_image()` → reservation helper → `validate_attachment_route_epoch()` → polarity helper → `write_commit_device_entry()` | image staging 仍发生在 reservation 前；reservation 后 route/epoch 复核仍优先于 polarity；CQ flush secondary route 仍由 caller authority 负责 |

因此，authority/codec 的拒绝优先级、reservation 后 reset/route 变化窗口、polarity
不匹配的 cancel/recovery 语义和 write/commit 后端事务均保持原契约。成功路径只减少
重复控制流，不把三个不同的 wire model 合并成可选参数或宽泛的统一 codec。

## 验证与证据

所有 VCS 仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 的登录 bash
环境执行。Batch158 最终源码边界的 focused 结果如下：

| Entry | Result |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0`；pristine |
| `rdma_queue_data_engine_poll_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine |
| `rdma_aeqe_route_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine |
| `rdma_aeqe_f5_e2e_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=115/WARNING=0/ERROR=0/FATAL=0`；pristine |

本地门禁与复审口径为：

- `git diff --check`；
- `python3 tools/check_changed_sv_style.py --base 33be6c7`；
- `python3 tools/check_queue_lifecycle.py`、`python3 tools/check_rdma_profile_names.py`、
  `python3 tools/check_rdma_phase1a_approval.py`；
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 `OK`；
- 使用 `sanitize_source`、`method_ranges`、`check_method_comments` 和
  `check_file_header` 对 `src/`、`tests/`、`sim/` 的 SystemVerilog（含两个 `.svh`）
  做全目录复审：189 个文件（187 `.sv`、2 `.svh`），5,485 个 method（`.sv` 5,483、
  `.svh` 2），0 diagnostics。

本批没有修改测试 fixture 或外部依赖；Python 测试输出中出现的 fixture 预期
`fatal: not a git repository`/argparse usage 文本不影响返回码，最终测试套件仍为
292/292 `OK`。wrapper 完整日志 hash 与源码 SHA 在最终提交后由主线交接记录冻结，
避免把未提交工作树的临时字节指纹当成提交证据。

## 未关闭边界

本批不声称关闭以下问题：

- `configure_shared()`-only facade 的真实 live reset 认证；
- reservation 后跨线程/跨队列 route 变化及 engine-level 全局锁；
- SRQ 全生命周期、legacy descriptor 和 CEQ/AEQ malformed retry 组合；
- 外部 PCIe ordering/error、完整 parent/core/CMQ regression 与最终全目录 ownership
  审计；
- 广义 Phase 1C F2 及 `rdma_queue_txn_evidence::capture_urc_shadow()` 内部 status
  factory 的全部 typed-factory 闭包。

focused GREEN 只证明本批 admission seam 在当前源码边界的行为，不等于整份结构
重构计划完成；计划继续保持 `active`。
