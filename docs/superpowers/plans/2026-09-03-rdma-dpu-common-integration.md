# RDMA 与 dpu_common 集成实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不修改外部 `dpu_common`、PCIe 和 Host-memory 实现的前提下，为 RDMA 建立多 Host/PF/VF/root 集成层、Function 级上下文和可恢复的 SQ/RQ/CQ/CEQ/AEQ/CMQ 数据路径，并将内部 profile 名称统一为 `rdma`。

**Architecture:** `rdma_dpu_env_pkg` 是唯一读取 `dpu_resource_pkg` 的翻译层，将冻结的 DPU snapshot 转换成 RDMA value snapshot。`rdma_device_env` 管理每个 PF/VF 的 `rdma_function_context`；context 组装现有 control/resource/codec/core 对象，并通过 Host-memory/PCIe router 访问外部组件。队列 engine 只编排事务，`rdma_queue_runtime` 和 transaction journal 统一拥有游标、credit、slot ledger 和恢复证据。

**Tech Stack:** SystemVerilog、UVM 1.2、VCS、现有 `rdma_types_pkg`/`rdma_model_pkg`/`rdma_codec_pkg`/`rdma_adapter_pkg`/`rdma_core_pkg`、外部 `dpu_resource_pkg`、指定 VCS 主机 `ubuntu@10.11.10.53`。

**Spec:** `docs/superpowers/specs/2026-09-03-rdma-dpu-common-integration-design.md`

## Global Constraints

- `dpu_common` 是 Host、PF/VF、BDF、BAR、global Function ID、跨服务资源和拓扑的唯一权威；RDMA 不重复解析或修改它。
- 普通源码、package 和测试使用 `.sv`；`.svh` 仅用于宏、固定 mask 或类似头文件内容。
- 新文件必须有中文文件头；公共 class 必须写明职责、创建者、所有权和释放规则；复杂状态迁移必须有中文注释。
- PCIe 和 Host-memory 路由键必须包含 `{host_topology_key, root_id, segment, bdf}`；禁止只使用 BDF，禁止多 root 隐式回退到 root0。
- `function_uid` 是 RDMA incarnation token；所有资源、mapping、doorbell、ticket 和 completion 还必须校验完整 Function key、generation 和 reset epoch。
- PI、CI、wrap、used/credit 和 slot ledger 只能由一个 `rdma_queue_runtime` 保存；engine 不得维护副本。
- `mmio_maybe_submitted=1` 的事务禁止自动重试；只能由外部确认后执行 `RETRY_NO_SUBMIT`、`FINALIZE_SUBMITTED` 或 `ABORT_AND_DETACH`。
- 不修改外部 PCIe、Host-memory、net 和 `dpu_common` 源码；不提交构建目录、日志、缓存、SSH wrapper 或凭据。
- 需要仿真时必须在 `ubuntu@10.11.10.53` 的 login bash 中运行，Host-memory 继续通过 pinned commit/hash preflight。

---

## 文件和组件地图

第一阶段创建集成层；第二阶段扩展身份和事务模型；第三阶段拆分 engine facade 并接入恢复；第四阶段执行 profile 命名迁移和完整回归。

| 文件 | 职责 |
|---|---|
| `src/model/rdma_function_identity.sv` | 保存不可变 DPU Function key、global ID、UID、generation、reset epoch，并提供比较/诊断方法 |
| `src/model/rdma_queue_txn_types.sv` | 定义 producer/consumer pending 阶段、恢复动作、release plan 和事务证据 |
| `src/integration/rdma_dpu_env_pkg.sv` | 唯一导入 `dpu_resource_pkg`，包含集成层 class |
| `src/integration/rdma_dpu_identity_adapter.sv` | 将 DPU snapshot 的 Function、PCIe、BAR、MSI-X 信息转换为 RDMA identity/binding |
| `src/integration/rdma_host_mem_router.sv` | 按 Host/root/Function 选择现有 Host-memory manager，实现 `rdma_host_mem_api` |
| `src/integration/rdma_pcie_router.sv` | 按完整 Function route 选择 PCIe endpoint，实现 `rdma_pcie_api` |
| `src/integration/rdma_function_context.sv` | 组装一个 Function 的 binding、resource/control/data engines 和 recovery 状态 |
| `src/integration/rdma_device_env.sv` | 枚举 DPU Function、创建 context、执行 Host/Device reset 级联 |
| `src/integration/rdma_reset_coordinator.sv` | 定义 VF FLR、PF reset、Host reset、Device reset 的影响范围和 epoch 更新 |
| `src/core/rdma_queue_txn_journal.sv` | 管理 runtime 私有 pending evidence 和阶段转换 |
| `src/core/rdma_sq_engine.sv` | SQ post_send facade，调用 runtime、codec、Host-memory 和 doorbell |
| `src/core/rdma_rq_engine.sv` | RQ/SRQ post_recv facade |
| `src/core/rdma_cq_engine.sv` | CQ poll/decode/route/CI commit/WQE release facade |
| `src/core/rdma_eq_engine.sv` | CEQ/AEQ poll/decode/route/CI commit facade |
| `src/core/rdma_queue_runtime.sv` | 扩展 pending 阶段、reset epoch 和幂等 release；保持唯一 cursor/credit authority |
| `src/core/rdma_queue_data_engine.sv` | 兼容 facade；最终委托新 SQ/RQ/CQ/EQ engine，不再重复维护状态 |
| `src/codec/rdma/` | 当前 `src/codec/xtr_v1/` 的一次性 profile 命名迁移 |
| `sim/filelists/integration.f` | 引入外部 dpu_common 和 RDMA 集成层的 VCS filelist |
| `tests/integration/rdma_dpu_integration_test.sv` | 多 Host/PF/VF/root、路由和 reset 集成验证 |
| `tests/unit/rdma_queue_txn_journal_test.sv` | 事务阶段、ambiguous MMIO 和 release plan 单元验证 |

---

### Task 1: 建立 Function identity 和事务值模型

**Files:**
- Create: `src/model/rdma_function_identity.sv`
- Create: `src/model/rdma_queue_txn_types.sv`
- Modify: `src/model/rdma_model_pkg.sv`（在 `rdma_function_binding.sv` 前包含 identity，在 queue lifecycle models 后包含 txn types）
- Modify: `src/types/rdma_identity_types.sv`（增加 `rdma_reset_epoch_t` 和完整 route key value type）
- Modify: `src/model/rdma_function_binding.sv`（增加只读 identity、派生字段校验和 epoch accessor）
- Modify: `tests/rdma_unit_test_pkg.sv`（包含两个新增 unit test）
- Test: `tests/unit/rdma_function_identity_test.sv`
- Test: `tests/unit/rdma_queue_txn_journal_test.sv`（先覆盖值模型，不涉及 runtime）

**Interfaces:**
- `rdma_function_identity::configure(rdma_function_key_t key, int unsigned global_id, longint unsigned uid, int unsigned generation, longint unsigned reset_epoch)` 返回 `rdma_status`。
- `rdma_function_identity::same_function(rdma_function_identity rhs)` 和 `same_incarnation(rhs)` 返回 `bit`；前者比较 key/global ID，后者再比较 UID/generation/epoch。
- `rdma_function_identity::route_key()` 返回包含 `host_topology_key`、`root_id`、segment、BDF 的 `rdma_route_key_t`。
- `rdma_queue_txn_phase_e` 固定为 `NONE/RESERVED/PAYLOAD_WRITTEN/DOORBELL_MAYBE_SUBMITTED/CONSUMER_COMMITTED/WQE_RELEASE_PARTIAL/COMPLETED`。
- `rdma_queue_recovery_action_e` 固定为 `RETRY_NO_SUBMIT/FINALIZE_SUBMITTED/ABORT_AND_DETACH`。
- `rdma_queue_txn_evidence` 保存 Function identity、queue handle、cursor/next cursor、image、request/CQE snapshot、route、失败状态和 `mmio_maybe_submitted`。

- [ ] **Step 1: Write failing identity tests.** 创建两个相同 BDF 但不同 Host/root 的 identity，断言 `same_function()` 为假、route key 不相等；复制相同 identity 后仅增加 reset epoch，断言 `same_function()` 为真且 `same_incarnation()` 为假。
- [ ] **Step 2: Run identity tests to verify failure.** 在仓库根目录运行 `make -C sim core TEST=rdma_function_identity_test`；预期因类型和方法尚未定义而编译失败。
- [ ] **Step 3: Implement value types and copy/validate.** 增加 route key、reset epoch 和 identity class；所有 class handle 使用 clone/value snapshot，不保存调用方可变对象；`validate()` 拒绝零 generation、无效 BDF/route 和不一致的 global ID。
- [ ] **Step 4: Write failing transaction-model tests.** 构造 producer evidence，逐阶段调用 `advance(phase)`；断言非法回退、`mmio_maybe_submitted` 下的自动 retry 和缺失 image 的 finalize 均返回明确错误码。
- [ ] **Step 5: Implement transaction evidence.** 在 `rdma_queue_txn_types.sv` 中实现阶段转换表、恢复动作前置条件和 CQ release plan 的幂等已释放标记；诊断消息包含 Function 和 queue 标识。
- [ ] **Step 6: Integrate binding accessors.** `rdma_function_binding` 保存 identity 的 detached snapshot；`make_handle()` 和 `accepts()` 从 identity 派生 Function UID/global ID/generation，旧字段只作为兼容镜像并在 `validate()` 中检查一致性。
- [ ] **Step 7: Run focused tests.** 运行 `make -C sim core TEST=rdma_function_identity_test` 和 `make -C sim core TEST=rdma_queue_txn_journal_test`；预期全部 PASS 且 UVM summary 无 ERROR/FATAL。
- [ ] **Step 8: Commit.** `git add src/types/rdma_identity_types.sv src/model/rdma_function_identity.sv src/model/rdma_queue_txn_types.sv src/model/rdma_function_binding.sv src/model/rdma_model_pkg.sv tests/unit/rdma_function_identity_test.sv tests/unit/rdma_queue_txn_journal_test.sv && git commit -m "feat: add rdma function identity and transaction evidence"`

### Task 2: 实现 DPU identity adapter 和 Host/PCIe router

**Files:**
- Create: `src/integration/rdma_dpu_env_pkg.sv`
- Create: `src/integration/rdma_dpu_identity_adapter.sv`
- Create: `src/integration/rdma_host_mem_router.sv`
- Create: `src/integration/rdma_pcie_router.sv`
- Create: `src/integration/rdma_reset_coordinator.sv`
- Create: `src/integration/rdma_function_context.sv`
- Create: `src/integration/rdma_device_env.sv`
- Modify: `src/model/rdma_dma_request_context.sv`（增加 route key 和 reset epoch snapshot）
- Modify: `src/model/rdma_dma_mapping.sv`（增加 route/epoch 校验）
- Modify: `src/adapter/rdma_adapter_pkg.sv`（仅保留底层 API；router 由 integration package 包含）
- Modify: `tests/rdma_unit_test_pkg.sv`（在 `RDMA_DPU_INTEGRATION` 宏下导入 dpu_common/integration 并包含集成测试）
- Modify: `sim/Makefile`（增加带 `+define+RDMA_DPU_INTEGRATION` 的 integration target）
- Create: `sim/filelists/integration.f`
- Test: `tests/integration/rdma_dpu_integration_test.sv`
- Test: `tests/unit/rdma_host_mem_router_test.sv`
- Test: `tests/unit/rdma_pcie_router_test.sv`

**Interfaces:**
- `rdma_dpu_identity_adapter::from_snapshot(dpu_device_snapshot snapshot, dpu_resource_snapshot resources, input dpu_function_key_t key, output rdma_function_identity identity, output rdma_function_binding binding)` 返回 `rdma_status`。
- `rdma_host_mem_route_entry` 是 integration 层的 UVM value object，字段为 `int unsigned host_topology_key` 和 `rdma_host_mem_api manager`；`rdma_host_mem_router::configure(rdma_host_mem_route_entry entries[$])` 返回 `rdma_status`，其 `allocate/write/read/release` 签名与现有 `rdma_host_mem_api` 完全一致。
- `rdma_pcie_route_entry` 是 integration 层的 UVM value object，字段为 `rdma_route_key_t route` 和 `rdma_pcie_api endpoint`；`rdma_pcie_router::configure(rdma_pcie_route_entry entries[$])` 返回 `rdma_status`，实现现有 `rdma_pcie_api` 的 cfg/mmio/bar/barrier 方法。
- `rdma_reset_coordinator::request_vf_flr(identity)`, `request_pf_reset(identity)`, `request_host_reset(host_topology_key)`, `request_device_reset()` 均返回 `rdma_status`，并递增受影响 context 的 reset epoch。
- `rdma_function_context::build(identity, dpu_resource_snapshot, rdma_host_mem_router, rdma_pcie_router, registry, timeout)` 和 `rdma_device_env::build(dpu_device_snapshot, dpu_resource_snapshot, dpu_resource_manager, rdma_host_mem_router, rdma_pcie_router, registry, timeout)` 返回 `rdma_status`。

- [ ] **Step 1: Add integration filelist and compile probe.** 在 `integration.f` 中按 spec 顺序加入外部 dpu_common filelist、RDMA package 和 integration package；新增 smoke test 仅导入 `rdma_dpu_env_pkg`。
- [ ] **Step 2: Run compile probe to verify failure.** 在 `10.11.10.53` login shell 中运行 `make -C sim -f Makefile integration TEST=rdma_dpu_integration_test`；预期因 integration package/class 尚未定义而失败。
- [ ] **Step 3: Implement snapshot translation.** 使用 `dpu_device_snapshot.list_functions()`、`get_pcie_id()`、`get_global_function_id()` 和 `get_bar()` 读取冻结 snapshot；验证 VF parent PF、Host/root/domain 一致性；不缓存可变 DPU class handle。
- [ ] **Step 4: Implement Host-memory router.** 按 `host_topology_key` 选择 manager；为每个 mapping 记录完整 route、owner、generation、reset epoch；旧 epoch 的 read/write/release 返回 `RDMA_SC_STALE_GENERATION` 或 quarantine 状态。
- [ ] **Step 5: Implement PCIe router.** 建立完整 route key 到 endpoint 的表；cfg/mmio/bar/barrier 均拒绝不唯一 BDF；缺少 root/Host 时返回 ambiguity，不回退 root0。
- [ ] **Step 6: Implement reset coordinator.** 维护 Function/Host/Device context 影响集合；VF FLR 只隔离该 VF，PF reset 包含 PF+VF，Host reset 包含同 Host 全部 Function，Device reset 包含全部 context。
- [ ] **Step 7: Write routing tests.** 使用 Host0/PF0 和 Host1/PF0 的相同 BDF、不同 Host 的相同 IOVA、同 Host PF/VF manager 共享、root0/root1 和 sparse VF；断言路由和拒绝结果符合 spec。
- [ ] **Step 8: Run integration tests and commit.** 运行 `make -C sim -f Makefile integration TEST=rdma_dpu_integration_test`、两个 router unit test 和已有 `make -C sim core TEST=rdma_model_test`；全部通过后提交 `feat: add dpu common rdma routing integration`。

### Task 3: 修正 queue runtime 事务一致性和恢复

**Files:**
- Create: `src/core/rdma_queue_txn_journal.sv`
- Modify: `src/core/rdma_queue_runtime.sv`
- Modify: `src/core/rdma_queue_data_engine.sv`
- Modify: `src/core/rdma_doorbell_scheduler.sv`
- Modify: `src/core/rdma_cmq_engine.sv`
- Test: `tests/unit/rdma_queue_runtime_test.sv`
- Test: `tests/unit/rdma_queue_data_engine_recovery_test.sv`
- Test: `tests/unit/rdma_doorbell_scheduler_test.sv`
- Test: `tests/unit/rdma_cmq_engine_test.sv`

**Interfaces:**
- `rdma_queue_txn_journal::begin(evidence)`, `advance(phase)`, `mark_mmio_maybe_submitted()`, `mark_wqe_release(index, wrap)`, `complete()`, `abort()` 均返回 `rdma_status`。
- `rdma_queue_runtime::commit_consumer(cursor)` 只提交 CI；关联 WQE runtime 的 `commit_release(release_token)` 单独执行幂等 release，重复 token 返回 success 且不重复减少 credit。
- `rdma_queue_data_engine::recover_queue(queue_h, rdma_queue_recovery_action_e action, output rdma_status status)` 实现三种显式恢复动作，禁止 ambiguous MMIO 自动 retry。
- `rdma_doorbell_scheduler::submit()` 返回结果中明确 `known_no_mmio` 与 `mmio_maybe_submitted`。
- `rdma_cmq_engine` 在命令 timeout/ambiguous 时 quarantine ticket 并置 `POISONED`，直到显式恢复。

- [ ] **Step 1: Add failing recovery tests.** 在 queue data recovery test 中注入 host write failure、readback mismatch、DMA barrier timeout、MMIO timeout、generation 变化和本地 commit failure；断言 pending phase、MMIO ambiguity 和 queue state。
- [ ] **Step 2: Run focused recovery tests to capture current failure.** 运行 `make -C sim core TEST=rdma_queue_data_engine_recovery_test`；记录当前 CQ 在 CI commit 前释放 WQE 的失败断言。
- [ ] **Step 3: Implement journal.** 将 pending 从散落 bit 扩展为显式 phase/evidence；所有 evidence 使用 detached clone；只允许单调阶段转换，`abort()` 后禁止再次 commit。
- [ ] **Step 4: Fix producer ordering.** 调整 `post_send/post_recv` 为 snapshot → validate → reserve → encode → write/readback → DMA barrier → producer doorbell → commit；write 失败标记 known-no-MMIO，doorbell 失败保留 ambiguity。
- [ ] **Step 5: Fix consumer ordering.** 调整 `poll_cqe_once()` 为 read/decode/route → release plan → DMA barrier → CI doorbell → `commit_consumer()` → WQE release → publish result；release plan 幂等并记录已释放位置。
- [ ] **Step 6: Implement explicit recovery.** `RETRY_NO_SUBMIT` 只重放确认未提交的 image；`FINALIZE_SUBMITTED` 只补本地 commit/release；`ABORT_AND_DETACH` quarantine queue 并隔离 mapping/ledger。generation 或 reset epoch 变化时三者均拒绝旧事务。
- [ ] **Step 7: Harden doorbell and CMQ.** 为 scheduler 增加阶段结果和不可重试 ambiguous 错误；为 CMQ ticket 加 generation/epoch，timeout 后停止新命令并保持 POISONED。
- [ ] **Step 8: Run regression and commit.** 运行 queue runtime、queue data recovery、doorbell、CMQ 四个单元测试以及 `make -C sim core TEST=rdma_queue_data_engine_post_test`、`make -C sim core TEST=rdma_queue_data_engine_poll_test`；全部通过后提交 `fix: make rdma queue transactions recoverable`。

### Task 4: 拆分 SQ/RQ/CQ/EQ engine facade

**Files:**
- Create: `src/core/rdma_sq_engine.sv`
- Create: `src/core/rdma_rq_engine.sv`
- Create: `src/core/rdma_cq_engine.sv`
- Create: `src/core/rdma_eq_engine.sv`
- Modify: `src/core/rdma_core_pkg.sv`
- Modify: `src/core/rdma_queue_data_engine.sv`（兼容入口委托新 facade）
- Modify: `tests/rdma_unit_test_pkg.sv`（包含四个 engine unit test）
- Test: `tests/unit/rdma_sq_engine_test.sv`
- Test: `tests/unit/rdma_rq_engine_test.sv`
- Test: `tests/unit/rdma_cq_engine_test.sv`
- Test: `tests/unit/rdma_eq_engine_test.sv`

**Interfaces:**
- 所有 engine 的 `configure(resource_manager, function_binding, host_mem, doorbells, registry, timeout)` 返回 `rdma_status`。
- `rdma_sq_engine::post_send(request, output rdma_queue_post_result result, output rdma_status status)`。
- `rdma_rq_engine::post_recv(request, output rdma_queue_post_result result, output rdma_status status)`。
- `rdma_cq_engine::poll_cqe(cq_h, output rdma_queue_completion_result result, output rdma_status status)`。
- `rdma_eq_engine::poll_ceqe(ceq_h, output rdma_queue_event_result result, output rdma_status status)`。
- `rdma_eq_engine::poll_aeqe(aeq_h, output rdma_queue_event_result result, output rdma_status status)`。
- Facade 只持有引用或 detached evidence，不拥有外部 manager、Function context 或第二份 runtime。

- [ ] **Step 1: Write facade contract tests.** 使用 mock Host-memory/PCIe/codec，断言每个 facade 将操作转发到唯一 runtime；构造相同 QPN/CQN 的两个 Function，断言 handle 不串线。
- [ ] **Step 2: Run facade tests to verify failure.** 运行四个新 test；预期因 class 和 package include 尚不存在而编译失败。
- [ ] **Step 3: Implement SQ/RQ facades.** 从现有 `rdma_queue_data_engine` 提取 producer 预检、编码、访问和 doorbell 调用；将 queue handle、Function identity 和 epoch 校验放在入口；结果对象只从 detached snapshot 填充。
- [ ] **Step 4: Implement CQ/EQ facades.** 提取 consumer read/decode/route/CI commit/release 流程；CQ 使用 release token，CEQ/AEQ 只 commit CI 后发布 event result；无唯一 QPN/CQN 时返回 invalid state。
- [ ] **Step 5: Convert compatibility engine.** `rdma_queue_data_engine` 保留旧 public API，将 `post_send/post_recv/poll_cqe/poll_ceqe/poll_aeqe/recover_queue` 委托给新 facade；删除其重复的 producer/consumer state。
- [ ] **Step 6: Run facade and existing regressions.** 运行四个 facade test、现有 queue data post/poll/recovery、QP lifecycle 和 control-plane CMQ tests；验证旧调用方行为不变。
- [ ] **Step 7: Commit.** `git add src/core/rdma_sq_engine.sv src/core/rdma_rq_engine.sv src/core/rdma_cq_engine.sv src/core/rdma_eq_engine.sv src/core/rdma_core_pkg.sv src/core/rdma_queue_data_engine.sv tests/unit/rdma_*_engine_test.sv && git commit -m "refactor: split rdma queue data engines"`

### Task 5: 建立 device env 和 Function context

**Files:**
- Modify: `src/integration/rdma_function_context.sv`
- Modify: `src/integration/rdma_device_env.sv`
- Modify: `src/integration/rdma_reset_coordinator.sv`
- Modify: `src/integration/rdma_dpu_env_pkg.sv`
- Modify: `sim/filelists/integration.f`
- Test: `tests/integration/rdma_function_context_test.sv`
- Test: `tests/integration/rdma_reset_cascade_test.sv`

**Interfaces:**
- `rdma_function_context::build(identity, dpu_resource_snapshot, host_mem_router, pcie_router, registry, timeout)` 返回 `rdma_status`。
- `rdma_function_context::quiesce()`、`activate()`、`reset(new_generation, new_epoch)`、`lookup_queue(handle)` 返回 `rdma_status`。
- `rdma_device_env::build(dpu_device_snapshot, dpu_resource_snapshot, dpu_resource_manager, rdma_host_mem_router, rdma_pcie_router, registry, timeout)` 返回 `rdma_status`。
- `rdma_device_env::find_function(identity, output rdma_function_context context)` 和 `find_handle(function_h, output context)` 返回 `rdma_status`。
- `rdma_device_env::request_vf_flr/pf_reset/host_reset/device_reset` 委托 reset coordinator 并按级联顺序 quiesce/rebuild。

- [ ] **Step 1: Write context lifecycle tests.** 用两个 Host、两个 PF、稀疏 VF 生成 snapshot；断言每个 context 拥有独立 resource manager/doorbell/runtime，重复 build 和缺失 parent PF 被拒绝。
- [ ] **Step 2: Run lifecycle tests to verify failure.** 在 VCS 主机运行 integration context test；预期因 env/context 尚未完成而失败。
- [ ] **Step 3: Implement context build.** 固化 identity，创建 binding、resource manager、scheduler、CMQ/control plane 和 SQ/RQ/CQ/EQ facade；所有依赖注入失败都释放已创建对象并返回明确状态。
- [ ] **Step 4: Implement device enumeration/index.** 从冻结 snapshot 列举 Function，按完整 route key 建立 context associative index；相同本地 QPN/CQN 只在同一 context 内有效。
- [ ] **Step 5: Implement reset cascade.** quiesce 阻止新事务，处理 pending journal，再递增受影响 epoch、隔离 mapping/ticket/completion，最后按新的 generation 重建 context。
- [ ] **Step 6: Run context/reset regression.** 运行 context、reset cascade、router、queue facade、control-plane CMQ 和 QP lifecycle tests；在指定 VCS 主机执行 `make -C sim -f Makefile integration TEST=rdma_reset_cascade_test`。
- [ ] **Step 7: Commit.** `git add src/integration sim/filelists/integration.f tests/integration && git commit -m "feat: add rdma device and function contexts"`

### Task 6: 完成 profile 命名迁移和完整验证

**Files:**
- Rename: `src/codec/xtr_v1/` → `src/codec/rdma/`
- Rename: `src/adapter/rdma_xtr_v1_queue_host_mem_submitter.sv` → `src/adapter/rdma_queue_host_mem_submitter.sv`
- Rename: `tests/support/rdma_xtr_v1_golden_reader.sv` → `tests/support/rdma_golden_reader.sv`
- Rename: `tests/unit/rdma_xtr_v1_cmq_codec_test.sv`, `rdma_xtr_v1_cmq_completion_test.sv`, `rdma_xtr_v1_cmq_profile_test.sv`, `rdma_xtr_v1_context_body_codec_test.sv`, `rdma_xtr_v1_context_cmq_regression_test.sv`, `rdma_xtr_v1_defs_test.sv`, `rdma_xtr_v1_doorbell_codec_test.sv`, `rdma_xtr_v1_error_codec_test.sv`, `rdma_xtr_v1_qpc_codec_test.sv`, `rdma_xtr_v1_queue_codec_test.sv`, `rdma_xtr_v1_queue_host_mem_submitter_test.sv`, `rdma_xtr_v1_queue_model_test.sv`, `rdma_xtr_v1_queue_page_codec_test.sv`, `rdma_xtr_v1_qword_codec_test.sv`, `rdma_xtr_v1_sq_codec_test.sv` to corresponding `rdma_*.sv` names
- Modify: `src/codec/rdma_codec_pkg.sv`
- Rename/update: `src/codec/rdma/` 内所有 `rdma_xtr_v1_*` class、`XTR_V1_*` 宏、registry key 为 `rdma_*`；数值 `RDMA_HW_VERSION=1` 保持不变
- Rename: `tools/check_xtr_v1_defs.py` → `tools/check_rdma_profile_names.py`
- Rename: `tests/unit/test_check_xtr_v1_defs.py` → `tests/unit/test_check_rdma_profile_names.py`
- Modify: `sim/Makefile`、`sim/filelists/core.f`、`sim/filelists/integration.f`
- Modify: `docs/hw/xtr-v1-source-map.md`（说明外部资料别名和内部 profile `rdma`）
- Rename: `hw/xtr_v1/` → `hw/rdma/`（golden vectors 和 source manifest 只改内部路径，不改外部资料内容）
- Test: 全部现有 unit/integration tests

**Interfaces:**
- codec registry key 使用 `hw_version:"rdma"`；不能再依赖字符串 `"xtr_v1"`。
- 迁移后的 class 名称以 `rdma_` 开头，硬件 ABI 常量固定为 `RDMA_HW_VERSION = 1`。
- golden vector reader/tool 的命令行和测试名使用 `rdma`，输入资料中出现的 XTR v1 只作为来源别名。

- [ ] **Step 1: Add naming guard.** 创建 `tools/check_rdma_profile_names.py`，扫描源、filelist、tests、docs 中禁止新增内部 `xtr_v1` registry key/class 引用，仅允许迁移映射和来源文档注释。
- [ ] **Step 2: Run guard before migration.** 运行工具并记录现有引用清单，确保每个引用有对应迁移目标。
- [ ] **Step 3: Rename codec/profile files and symbols.** 使用版本控制 rename，逐文件更新 class、macro、include guard、registry registration、golden reader 和 tests；保留外部硬件资料映射注释。
- [ ] **Step 4: Update filelists and Makefile.** 将 `xtr_v1` include directory、archive variable 和 test target 名称迁移为 `rdma`；保留外部 archive 路径作为只读输入，不复制到仓库。
- [ ] **Step 5: Run static checks.** 运行 `git diff --check`、profile naming guard、`.sv/.svh` extension scan；确认普通源码没有误用 `.svh`，宏文件仍可用 `.svh`。
- [ ] **Step 6: Run complete VCS regression.** 在 `ubuntu@10.11.10.53` login shell 中运行 core、Host-memory 和 integration targets；再运行 `scripts/check_uvm_summary.sh` 检查每个日志无 UVM ERROR/FATAL。
- [ ] **Step 7: Review repository cleanliness.** `git status --short --ignored` 仅允许预期源代码/测试/文档变更；确认无 token、构建输出、日志、SSH wrapper、外部源码。
- [ ] **Step 8: Commit.** `git add src sim tests tools docs && git commit -m "refactor: rename rdma hardware profile"`

### Task 7: 最终架构验收和远程交付

**Files:**
- Modify: none by design；发现缺陷时回到对应任务的文件和 commit 修复
- Test: complete core, Host-memory and integration regression logs kept outside git

**Interfaces:**
- 验收入口：`make -C sim core TEST=rdma_smoke_test`、`make -C sim host_mem TEST=rdma_queue_data_engine_host_mem_test HOST_MEM_ROOT="$HOST_MEM_ROOT"`、`make -C sim integration TEST=rdma_dpu_integration_test`。
- 远程提交只同步本仓库源代码、测试、文档和必要的 filelist/tool；不上传环境无关文件或凭据。

- [ ] **Step 1: Run static and unit checks.** 在本地执行 `git diff --check`、profile guard、全部 unit tests；任何失败先定位并补测试，再修改实现。
- [ ] **Step 2: Run VCS on simulation host.** 使用 `scripts/run_vcs53.sh` 或等价 login-shell 命令运行 core、Host-memory、integration regression；保存摘要，不把原始日志加入 git。
- [ ] **Step 3: Inspect routing/recovery evidence.** 从测试日志确认相同 BDF/IOVA/QPN/CQN 隔离、reset 影响范围、ambiguous MMIO 不重试、CI commit 后幂等 WQE release。
- [ ] **Step 4: Check clean tree.** `git status --short` 必须只显示待提交的预期修复；`git ls-files` 不得包含 token、wrapper、build/cache/log 或外部组件源码。
- [ ] **Step 5: Commit verification fixes.** 若有修复，按对应任务单独提交，提交消息说明失败场景和验证命令。
- [ ] **Step 6: Push only after explicit user direction.** 先向用户报告 commit 列表、测试结果和待推送分支；收到明确推送指令后，使用不含 token 的 GitHub remote 配置推送。

## Plan Self-Review

- **Spec coverage:** Task 1 覆盖 identity/epoch/事务证据；Task 2 覆盖 DPU snapshot、Host-memory/PCIe route 和 reset coordinator；Task 3 覆盖 producer/consumer/CMQ 顺序及 recovery；Task 4 覆盖 SQ/RQ/CQ/EQ facade；Task 5 覆盖 device/function context 和 reset cascade；Task 6 覆盖 `xtr_v1`→`rdma` 命名迁移；Task 7 覆盖 VCS 验证和仓库清洁交付。
- **Placeholder scan:** 计划不使用占位符或“稍后补充”措辞；每个任务都给出文件、方法签名、测试命令和 commit 动作。
- **Type consistency:** Task 1 定义的 `rdma_function_identity`、`rdma_queue_txn_phase_e`、`rdma_queue_recovery_action_e` 和 `rdma_queue_txn_evidence` 被 Task 2–5 直接引用；Task 2 定义的 router 配置和 Task 5 的 context build 参数一致；Task 3 的 recovery API 被 Task 4/5 facade/context 委托。
- **Scope:** 计划只修改 RDMA 仓库，外部 `dpu_common`、PCIe、Host-memory 和 net 组件保持只读依赖；profile 命名迁移与架构集成保持在同一交付目标内并按阶段提交。
