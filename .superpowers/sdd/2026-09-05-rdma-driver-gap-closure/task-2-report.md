# Task 2 报告：CQE 32/64/128B codec 与 layout

## 修改文件

- `src/codec/rdma/rdma_defs.svh`：增加 32/64/128B CQE 常量。
- `src/codec/rdma_codec_pkg.sv`：增加 `rdma_cqe_size_e`、`rdma_cqe_fields` 与 `rdma_cqe_layout::for_bytes`。
- `src/codec/rdma/rdma_queue_codecs.sv`：增加 `rdma_queue_codec::encode_cqe/decode_cqe`，大端编码、零填充和对齐/保留位检查。
- `src/core/rdma_queue_data_engine.sv`：CQ attach 接受 32/64/128B profile。
- `tests/unit/rdma_cqe_size_codec_test.sv`、`tests/rdma_unit_test_pkg.sv`：新增并注册往返测试。

## TDD 证据

- 首次运行测试在实现前/初始 API 缺失时失败（VCS 编译错误）。
- 修复后在 VCS 53 重新编译并取得 UVM 最终摘要；受影响的 resize、CQE、queue data engine
  和 Host-memory router 测试均为 `warning=0 error=0 fatal=0`。

## 验证摘要

- `scripts/run_vcs53.sh core rdma_cq_engine_resize_test`：VCS 53 编译和仿真通过，UVM
  `warning=0 error=0 fatal=0`。
- `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`：32/64/128B profile、qword2
  reserved bits 和字段宽度断言通过，UVM `warning=0 error=0 fatal=0`。
- `scripts/run_vcs53.sh core rdma_cmq_engine_test`：CMQ poisoned-ledger、reset
  release retry 和 opaque recovery 场景通过，UVM `warning=0 error=0 fatal=0`。
- `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：依赖 runtime 恢复及生命周期
  回归通过，UVM `warning=0 error=0 fatal=0`。
- `scripts/run_vcs53.sh core rdma_queue_data_engine_post_test`、
  `rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_recovery_test`：均通过，
  UVM `warning=0 error=0 fatal=0`。
- `scripts/run_vcs53.sh core rdma_queue_host_mem_submitter_test`：通过，UVM
  `warning=0 error=0 fatal=0`。
- `DPU_COMMON_ROOT=/home/ubuntu/virtio_work_continue/dpu_common scripts/run_vcs53.sh
  integration rdma_host_mem_router_test`：通过，UVM `warning=0 error=0 fatal=0`。
- `HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem scripts/run_vcs53.sh host_mem
  rdma_host_mem_adapter_test`：host-mem pinned preflight、leak check 和 adapter 回归通过，
  UVM `warning=0 error=0 fatal=0`。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：109 个静态契约测试通过；
  同步补齐 VCS 53 regression manifest 中新增的 CQE/resize 与 integration-unit 条目。
- `git diff --check`：通过。

## Commit

Task 2 的实现包含基线 `9047f13ef597b5e2f816f70eddd5675d7c55dfc9` 之后的 recovery、
SRQ 覆盖和 CQE 测试修正；本报告随本地 Task 2 收尾提交一并更新，最终 SHA 以
`git log -1` 为准。按当前工作流约束，本次只创建本地 commit，不 merge、不 push。

## Concerns

- Added `rdma_cq_engine::resize` and shared-engine `resize_cq`: candidate runtime allocates a new slot ledger, copies producer/consumer owner state, activates, then atomically swaps attachment; validation/pending failures leave old attachment unchanged.
- Added sized CQE codec selection through poll and host-memory submitter `read_cqe_sized`.
- Resize now clones backing access, copies ring cursor/slot state, and updates authoritative CQ resource geometry only after candidate validation succeeds.
- Runtime slot state copy now deep-clones request/image/completion status snapshots.
- Added stateless `decode_with_entry_bytes` to prevent shared codec profile contamination across sequential 32/64/128B decodes.
- VCS 53 仿真已重新取得最终 UVM 摘要；早期 inline pass 等待记录仅保留在历史轮次中，
  不再作为当前阻塞项。
- The resize path now uses `rdma_queue_backing_planner::allocate_owned_cq_resize_ring` and the
  manager's authoritative replacement API, so a successful resize owns a fresh mapping rather
  than reusing the old CQ backing.

## Round4 补充

- `rdma_hw_cqe_codec` 新增 `decode_with_entry_bytes(image, entry_size, model)` 无状态入口；32/64/128B 解码使用调用方 profile 和独立 qword builder，不读写共享 `active_bytes`。原 `decode()` 仅依据 image 长度转发到该入口。
- Host-memory submitter 和 CQ poll 路径改为显式传入 attachment 的 entry size，避免共享 registry codec 在交错读请求之间串 profile。
- `rdma_queue_runtime::copy_ring_state` 增加 source depth/slot ledger 边界检查；resize 测试覆盖 allocation failure 的一次 allocate 调用、authority/mapping 回滚、成功 geometry/mapping 断言以及非法 geometry 不分配。
- 历史记录：该轮窗口只看到 `Starting vcs inline pass...`；后续已重新运行并取得最终
  UVM 摘要，因此不再作为当前 concern。

## Round4b 补充（commit `0adf192`）

- 新增 `src/core/rdma_queue_backing_planner.sv` 的 `allocate_owned_cq_resize_ring`，负责按 CQ depth/CQE profile 计算页对齐 backing、校验 Function capability，并在候选失败时通过 opaque release authority 回滚 mapping。
- 新增 `src/core/rdma_queue_runtime.sv` 的 `QUIESCING` 状态及 `begin_quiesce`、`restore_active`、`detach_quiesced`；`copy_ring_state` 现在拒绝 occupancy 超过目标深度，并在所有 slot 快照成功后一次性发布游标/账本。
- 新增 `src/core/rdma_resource_manager.sv` 的 `begin_cq_resize` 与 `replace_active_cq`，对 CQ identity、依赖拓扑、queue-plan 几何和 ACTIVE/QUIESCING 状态执行原子权威校验。
- `src/core/rdma_queue_data_engine.sv` 增加 planner、resize semaphore 及 dependent-runtime 回滚辅助函数。
- `git diff --cached --check` 通过；远端 `scripts/run_vcs53.sh core rdma_cq_engine_resize_test` 已解析并重编译全部 11 个 module（显示 `All of 11 modules done`），随后在链接/仿真阶段主动中止，未取得 PASS/FAIL；远端临时目录清理因 `csrc` 非空告警。
- 历史未决项：当时 `resize_cq()` 尚未接入 fresh backing；该问题已在 Round5
  通过 `allocate_owned_cq_resize_ring` 和 authoritative replacement 修复。

## Round5 最终补充（实现 commit `43eb51c6ac3c1eca87ba4911212ae200cefce81e`）

- `src/core/rdma_queue_data_engine.sv`：重写 `resize_cq()` 为完整事务：`resize_lock` 串行化；调用 `manager.begin_cq_resize`、CQ/runtime 与依赖 quiesce；通过 `allocate_owned_cq_resize_ring` 分配新 control-plane backing；复制旧 cursor/slot 状态；构造新 access、queue plan、detached CQ candidate 并调用 `manager.replace_active_cq` 原子发布。失败路径清理候选 mapping、恢复 runtime/dependents/manager ACTIVE 并释放锁。发布成功后切换 attachment、detach 旧 runtime、释放旧 CQ ring backing；清理失败返回 `RDMA_SC_RECOVERY_REQUIRED`。
- `tests/unit/rdma_cq_engine_resize_test.sv`：修正 detached `manager.lookup()` 快照不可用指针相等比较，改为按 CQ ring role 的 mapping `iova/size/state` 值比较；覆盖 allocation failure 回滚、成功新 geometry/mapping、非法 geometry 不分配。
- `git diff --check`：通过。
- `scripts/run_vcs53.sh core rdma_cq_engine_resize_test`：VCS 53 编译及仿真通过，UVM summary `warning=0 error=0 fatal=0`。
- 历史 CQE profile field 错误已在后续修复中通过实际字段宽度校正和保留位校验消除；
  当前 `rdma_cqe_size_codec_test` 已取得 `warning=0 error=0 fatal=0`。
- 发布后旧 backing cleanup 若底层 adapter 报错，manager/attachment 已切换到新 authority，
  函数返回 `RDMA_SC_RECOVERY_REQUIRED` 并保留 recovery record，供上层显式 retry；正常
  adapter 路径已验证无泄漏/回滚。

## 后续修复（实现 commits `366a3b19656c4e8e80c4ef1636d8100b18a5239f`、`f8fc517b966b6da3f9b04e1ae6b1399e4e1a4b8c`；最终实现基线 `9047f13`）

- 成功发布后在 detach/cleanup 前立即调用 `restore_cq_dependents`，避免旧 CQ runtime detach 或旧 backing cleanup 失败时依赖 QP/SRQ 永久停留 `QUIESCING`；cleanup 失败仍返回 `RDMA_SC_RECOVERY_REQUIRED`。
- `rdma_queue_data_engine::query_runtime_state` 提供只读 runtime 状态快照；resize 测试新增对 fixture QP 的 SQ/RQ 依赖 runtime 在成功 resize 后均为 `RDMA_QUEUE_RUNTIME_ACTIVE` 的断言。
- `git diff --check`：通过。
- `scripts/run_vcs53.sh core rdma_cq_engine_resize_test`：通过，UVM summary `warning=0 error=0 fatal=0`。

## Recovery 与 SRQ 覆盖补充（本地 Task 2 收尾）

- `rdma_queue_data_engine.sv` 新增 engine-owned `rdma_cq_resize_recovery`。CQ authority
  发布后立即保存旧 runtime、旧 backing release authority 和所有 SQ/RQ/SRQ dependent
  runtime；dependent restore、旧 runtime detach 或旧 backing release 失败时保留记录。
- 新增 `has_pending_cq_resize()` 和 `retry_cq_resize_cleanup()`。retry 对已 ACTIVE 的
  dependent 幂等跳过，可重复恢复部分 QUIESCING runtime、detach 旧 runtime，并通过
  opaque release authority 重试 Host-memory release；只有全部完成才删除记录。
- pending recovery 会阻止新的 CQ resize、CQ detach 和 engine reconfigure，避免丢失
  唯一的旧 backing 清理入口。retry 使用记录中的 CQ value snapshot，允许 Function
  generation 变化后完成旧事务清理，但不放宽普通 stale handle 操作。
- `rdma_cq_engine_resize_test.sv` 新增真实 SRQ、第二个使用该 SRQ 的 RC QP，并断言
  CQ resize 后 SQ/RQ/SRQ runtime 都恢复为 `RDMA_QUEUE_RUNTIME_ACTIVE`；新增 published
  cleanup failure、recovery record、detach/reconfigure 拒绝、retry 释放旧 backing 的断言。
- `rdma_cqe_size_codec_test.sv` 修正 QPN/WQE index 测试值的实际字段位宽；
  `rdma_hw_cqe_codec` 删除旧的有状态重复 `decode_with_entry_bytes`，保留无状态入口，
  避免共享 registry codec 的 profile 串扰。
- 最新 VCS 53 验证：
  `scripts/run_vcs53.sh core rdma_cq_engine_resize_test` 与
  `scripts/run_vcs53.sh core rdma_cqe_size_codec_test` 均通过，UVM
  `warning=0 error=0 fatal=0`。
- 受影响 core 回归、Host-memory integration 回归和 scoped review 已完成；本地 Task 2
  commit 完成后仍不自动 merge/push。
