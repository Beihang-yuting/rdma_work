# Task 2 报告：CQE 32/64/128B codec 与 layout

## 修改文件

- `src/codec/rdma/rdma_defs.svh`：增加 32/64/128B CQE 常量。
- `src/codec/rdma_codec_pkg.sv`：增加 `rdma_cqe_size_e`、`rdma_cqe_fields` 与 `rdma_cqe_layout::for_bytes`。
- `src/codec/rdma/rdma_queue_codecs.sv`：增加 `rdma_queue_codec::encode_cqe/decode_cqe`，大端编码、零填充和对齐/保留位检查。
- `src/core/rdma_queue_data_engine.sv`：CQ attach 接受 32/64/128B profile。
- `tests/unit/rdma_cqe_size_codec_test.sv`、`tests/rdma_unit_test_pkg.sv`：新增并注册往返测试。

## TDD 证据

- 首次运行测试在实现前/初始 API 缺失时失败（VCS 编译错误）。
- 实现后 VCS 53 已完成编译并进入仿真；远端仿真进程长时间无最终 PASS/FAIL 输出，记录为 concern。

## 验证摘要

- `python3 -m py_compile tools/check_rdma_profile_names.py`：通过。
- `git diff --check`：通过。
- `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`：编译通过，仿真阶段远端无输出。

## Commit

Final fix commit: `3c8441f35434ed9a5065085d6cc82ef48529d818` (supersedes `ab1e7d99498d9d2a04aff3f5c8fe3485638fa7fb`).
Follow-up profile API fix commit is recorded below.

## Concerns

- Added `rdma_cq_engine::resize` and shared-engine `resize_cq`: candidate runtime allocates a new slot ledger, copies producer/consumer owner state, activates, then atomically swaps attachment; validation/pending failures leave old attachment unchanged.
- Added sized CQE codec selection through poll and host-memory submitter `read_cqe_sized`.
- Resize now clones backing access, copies ring cursor/slot state, and updates authoritative CQ resource geometry only after candidate validation succeeds.
- Runtime slot state copy now deep-clones request/image/completion status snapshots.
- Added stateless `decode_with_entry_bytes` to prevent shared codec profile contamination across sequential 32/64/128B decodes.
- VCS 53 compile completed and simulation entered inline pass but produced no final PASS/FAIL summary before timeout; rerun recommended.
- Concern/blocker: the existing `rdma_host_mem_api` has allocation but queue backing plans are lifecycle-owned and no safe engine-level API exists to allocate/construct/atomically replace a new CQ backing plan. Current resize creates an independent access wrapper over the lifecycle backing; it does not claim a new mapping allocation. This limitation is intentionally reported rather than misrepresented as fresh backing allocation.

## Round4 补充

- `rdma_hw_cqe_codec` 新增 `decode_with_entry_bytes(image, entry_size, model)` 无状态入口；32/64/128B 解码使用调用方 profile 和独立 qword builder，不读写共享 `active_bytes`。原 `decode()` 仅依据 image 长度转发到该入口。
- Host-memory submitter 和 CQ poll 路径改为显式传入 attachment 的 entry size，避免共享 registry codec 在交错读请求之间串 profile。
- `rdma_queue_runtime::copy_ring_state` 增加 source depth/slot ledger 边界检查；resize 测试覆盖 allocation failure 的一次 allocate 调用、authority/mapping 回滚、成功 geometry/mapping 断言以及非法 geometry 不分配。
- `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`：VCS 编译阶段通过；远端仿真进入 `Starting vcs inline pass...` 后在等待窗口内没有最终 PASS/FAIL 摘要，保留为 concern。

## Round4b 补充（commit `0adf192`）

- 新增 `src/core/rdma_queue_backing_planner.sv` 的 `allocate_owned_cq_resize_ring`，负责按 CQ depth/CQE profile 计算页对齐 backing、校验 Function capability，并在候选失败时通过 opaque release authority 回滚 mapping。
- 新增 `src/core/rdma_queue_runtime.sv` 的 `QUIESCING` 状态及 `begin_quiesce`、`restore_active`、`detach_quiesced`；`copy_ring_state` 现在拒绝 occupancy 超过目标深度，并在所有 slot 快照成功后一次性发布游标/账本。
- 新增 `src/core/rdma_resource_manager.sv` 的 `begin_cq_resize` 与 `replace_active_cq`，对 CQ identity、依赖拓扑、queue-plan 几何和 ACTIVE/QUIESCING 状态执行原子权威校验。
- `src/core/rdma_queue_data_engine.sv` 增加 planner、resize semaphore 及 dependent-runtime 回滚辅助函数。
- `git diff --cached --check` 通过；远端 `scripts/run_vcs53.sh core rdma_cq_engine_resize_test` 已解析并重编译全部 11 个 module（显示 `All of 11 modules done`），随后在链接/仿真阶段主动中止，未取得 PASS/FAIL；远端临时目录清理因 `csrc` 非空告警。
- 未决项：现有 `rdma_queue_data_engine::resize_cq()` 尚未接入上述新分配和 authoritative replacement primitives，仍调用 `clone_for_resize()` 复用旧 mapping。因此本 commit 提供可评审的基础 API，但端到端 fresh-backing resize 尚未完成，不应宣称 resize 已闭环。

## Round5 最终补充（实现 commit `43eb51c6ac3c1eca87ba4911212ae200cefce81e`）

- `src/core/rdma_queue_data_engine.sv`：重写 `resize_cq()` 为完整事务：`resize_lock` 串行化；调用 `manager.begin_cq_resize`、CQ/runtime 与依赖 quiesce；通过 `allocate_owned_cq_resize_ring` 分配新 control-plane backing；复制旧 cursor/slot 状态；构造新 access、queue plan、detached CQ candidate 并调用 `manager.replace_active_cq` 原子发布。失败路径清理候选 mapping、恢复 runtime/dependents/manager ACTIVE 并释放锁。发布成功后切换 attachment、detach 旧 runtime、释放旧 CQ ring backing；清理失败返回 `RDMA_SC_RECOVERY_REQUIRED`。
- `tests/unit/rdma_cq_engine_resize_test.sv`：修正 detached `manager.lookup()` 快照不可用指针相等比较，改为按 CQ ring role 的 mapping `iova/size/state` 值比较；覆盖 allocation failure 回滚、成功新 geometry/mapping、非法 geometry 不分配。
- `git diff --check`：通过。
- `scripts/run_vcs53.sh core rdma_cq_engine_resize_test`：VCS 53 编译及仿真通过，UVM summary `warning=0 error=0 fatal=0`。
- `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`：编译通过但既有 CQE profile field 测试产生 `UVM_ERROR=3`（`CQE_PROFILE_FIELDS`）；该失败不涉及本轮 resize 代码，需后续 codec 轮次处理。
- 未决项：发布后旧 backing cleanup 若底层 adapter 报错，manager/attachment 已切换到新 authority，函数返回 `RDMA_SC_RECOVERY_REQUIRED` 供上层恢复；正常 adapter 路径已验证无泄漏/回滚。

## 后续修复（实现 commits `366a3b19656c4e8e80c4ef1636d8100b18a5239f`、`f8fc517b966b6da3f9b04e1ae6b1399e4e1a4b8c`；最终实现 HEAD `f8fc517`）

- 成功发布后在 detach/cleanup 前立即调用 `restore_cq_dependents`，避免旧 CQ runtime detach 或旧 backing cleanup 失败时依赖 QP/SRQ 永久停留 `QUIESCING`；cleanup 失败仍返回 `RDMA_SC_RECOVERY_REQUIRED`。
- `rdma_queue_data_engine::query_runtime_state` 提供只读 runtime 状态快照；resize 测试新增对 fixture QP 的 SQ/RQ 依赖 runtime 在成功 resize 后均为 `RDMA_QUEUE_RUNTIME_ACTIVE` 的断言。
- `git diff --check`：通过。
- `scripts/run_vcs53.sh core rdma_cq_engine_resize_test`：通过，UVM summary `warning=0 error=0 fatal=0`。
