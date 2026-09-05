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

## Concerns

- Added `rdma_cq_engine::resize` and shared-engine `resize_cq`: candidate runtime allocates a new slot ledger, copies producer/consumer owner state, activates, then atomically swaps attachment; validation/pending failures leave old attachment unchanged.
- Added sized CQE codec selection through poll and host-memory submitter `read_cqe_sized`.
- Resize now clones backing access, copies ring cursor/slot state, and updates authoritative CQ resource geometry only after candidate validation succeeds.
- Runtime slot state copy now deep-clones request/image/completion status snapshots.
- VCS 53 compile completed and simulation entered inline pass but produced no final PASS/FAIL summary before timeout; rerun recommended.
- Concern/blocker: the existing `rdma_host_mem_api` has allocation but queue backing plans are lifecycle-owned and no safe engine-level API exists to allocate/construct/atomically replace a new CQ backing plan. Current resize creates an independent access wrapper over the lifecycle backing; it does not claim a new mapping allocation. This limitation is intentionally reported rather than misrepresented as fresh backing allocation.

## Round4 补充

- `rdma_hw_cqe_codec` 新增 `decode_with_entry_bytes(image, entry_size, model)` 无状态入口；32/64/128B 解码使用调用方 profile 和独立 qword builder，不读写共享 `active_bytes`。原 `decode()` 仅依据 image 长度转发到该入口。
- Host-memory submitter 和 CQ poll 路径改为显式传入 attachment 的 entry size，避免共享 registry codec 在交错读请求之间串 profile。
- `rdma_queue_runtime::copy_ring_state` 增加 source depth/slot ledger 边界检查；resize 测试覆盖 allocation failure 的一次 allocate 调用、authority/mapping 回滚、成功 geometry/mapping 断言以及非法 geometry 不分配。
- `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`：VCS 编译阶段通过；远端仿真进入 `Starting vcs inline pass...` 后在等待窗口内没有最终 PASS/FAIL 摘要，保留为 concern。
