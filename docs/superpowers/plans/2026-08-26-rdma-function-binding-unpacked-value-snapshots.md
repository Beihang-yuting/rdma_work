# RDMA Function Binding Unpacked Value Snapshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已经完成的 Task 1 packed value snapshot 表示最小迁移为 unpacked struct，在保持所有公开字段、值语义和 authority propagation 不变的前提下消除 10.11.10.53 上的 VCS native SIGSEGV。

**Architecture:** 三个 snapshot 继续是 package-scope fixed-schema SystemVerilog value type，唯一表示变化是从 `typedef struct packed` 改为 `typedef struct`。binding、resource-manager、fixture、codec 和 mock 的数据流完全不变；unpacked snapshot 不允许 bit-layout cast、streaming 或直接硬件 image serialization。

**Tech Stack:** SystemVerilog、UVM 1.2、Synopsys VCS W-2024.09-SP1、`scripts/run_vcs53.sh`、10.11.10.53、production host_mem `/home/ubuntu/workspace/host_mem`。

---

## 恢复边界

- 工作目录固定为 `/home/ryan/workspace/ryan/rdma_work/.worktrees/queue-resource-lifecycle`，分支为 `feat/queue-resource-lifecycle`。
- 当前 17 个 unstaged tracked files 是完成 class-to-value、domain/PASID propagation、resource projection、fixture migration 和 alias test 后的 packed RED 状态；全部保留。
- production change 只允许修改 `src/model/rdma_function_binding.svh` 中三个 typedef 的 `packed` keyword。不得修改 xtr_v1 codec、mock CMQ、control-plane test 顺序、对象名字、timeout 或 fork。
- `tools/__pycache__/` 是唯一无关 untracked cache；不得 stage、删除或提交。
- packed RED 的逐语句诊断已全部移除。`src/codec/xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh` 和 `tests/mocks/rdma_mock_control_plane.svh` 必须与 `HEAD` 相同，仓库不得残留 `DBG_CP` 或 typed-only return。
- 所有 VCS 仿真必须在 53 上运行，并显式带 `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123`。

### Task 1: 删除 Snapshot Packed Layout

**Files:**
- Modify: `src/model/rdma_function_binding.svh:112-142`
- Test: `tests/unit/rdma_model_test.svh`
- Test: `tests/unit/rdma_control_plane_test.svh`
- Preserve and commit: 原 Task 1 的其余 16 个 tracked files

- [ ] **Step 1: 重新观察 packed representation RED**

先确认无诊断或额外文件：

```bash
git diff --check
test "$(git status --short | awk '$1 != "??" {n++} END {print n+0}')" -eq 17
test -z "$(git diff -- src/codec/xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh tests/mocks/rdma_mock_control_plane.svh)"
! rg -n 'DBG_CP|typed-only return' src tests
```

运行当前 packed candidate：

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
```

预期：compile/link 成功；`[RNTST] Running test rdma_control_plane_test...` 后 VCS native SIGSEGV，命令非零退出且没有正常 UVM summary。SSH、许可证、remote sync 或编译错误不算 representation RED。

- [ ] **Step 2: 做唯一的 unpacked production 修改**

在 `src/model/rdma_function_binding.svh` 中只把三个 typedef：

```systemverilog
typedef struct packed {
```

改为：

```systemverilog
typedef struct {
```

最终定义必须完整为：

```systemverilog
typedef struct {
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
} rdma_queue_dma_context;

typedef struct {
  int unsigned min_cq_depth;
  int unsigned max_cq_depth;
  int unsigned min_srq_depth;
  int unsigned max_srq_depth;
  int unsigned max_ceq_depth;
  int unsigned max_aeq_depth;
  int unsigned max_wq_sge;
  longint unsigned max_queue_ring_bytes;
  longint unsigned max_sgb_bytes;
} rdma_queue_capabilities;

typedef struct {
  int unsigned function_local_vector;
  int unsigned hardware_eq_vector;
  int unsigned msix_table_index;
  bit enabled;
} rdma_interrupt_vector_binding;
```

不得同时修改 constructor、`do_copy()`、validation helper、resource manager、fixture、codec、mock 或 tests。

- [ ] **Step 3: 静态证明 unpacked schema 与无 code-shape workaround**

运行：

```bash
test "$(rg -c '^typedef struct \{$' src/model/rdma_function_binding.svh)" -eq 3
! rg -n '^typedef struct packed \{' src/model/rdma_function_binding.svh
! rg -n '\$bits\s*\(\s*rdma_(queue_dma_context|queue_capabilities|interrupt_vector_binding)|rdma_(queue_dma_context|queue_capabilities|interrupt_vector_binding)\s*\x27\s*\(' src tests
! rg -n '\{(<<|>>).*\b(queue_dma|queue_caps|interrupt_vectors)\b|\b(queue_dma|queue_caps|interrupt_vectors)\b.*\{(<<|>>)' src tests
! rg -n 'DBG_CP|typed-only return' src tests
test -z "$(git diff -- src/codec/xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh tests/mocks/rdma_mock_control_plane.svh)"
git diff --check
```

预期：三个 unpacked typedef；没有 packed/layout assumption、诊断、对象名 workaround、codec/mock diff 或 whitespace error。

- [ ] **Step 4: 验证 value semantics 与连续两次 control-plane GREEN**

运行：

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_model_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
```

预期：model test 不出现 `BIND_VALUE_ALIAS`；三次均正常到达 UVM summary且 warning/error/fatal 为 `0/0/0`；两个 control-plane run 都到达 8000 ps且无 native signal。若任一次仍 SIGSEGV，立即停止，不增加 codec/mock/test-name workaround。

- [ ] **Step 5: 在 53 上执行 Task 1 全回归**

每条命令独立运行：

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_adapter_contract_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_resource_manager_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_model_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_cmq_engine_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem \
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

预期：8 项 compile/link/run 全部成功，每项 UVM warning/error/fatal 为 `0/0/0`。adapter contract 继续证明 domain mismatch 返回 `RDMA_SC_DMA_TRANSLATION`；host_mem test 继续证明 BDF/PASID/domain propagation。

- [ ] **Step 6: 审核范围并提交完整 Task 1**

运行：

```bash
git diff --check
test "$(git status --short | awk '$1 != "??" {n++} END {print n+0}')" -eq 17
git diff --stat HEAD
git diff HEAD -- src/model/rdma_function_binding.svh
git status --short
```

预期：恰好原 Task 1 的 17 个 tracked files 被修改；`tools/__pycache__/` 是唯一无关 untracked；三个计划/spec docs 已在独立 docs commit 中；没有第 18 个 codec/mock/diagnostic 文件。

只 stage 以下 17 个文件：

```bash
git add src/model/rdma_function_binding.svh \
  src/model/rdma_dma_request_context.svh src/model/rdma_dma_mapping.svh \
  src/core/rdma_resource_manager.svh src/core/rdma_control_plane.svh \
  src/core/rdma_doorbell_scheduler.svh src/core/rdma_cmq_engine.svh \
  tests/mocks/rdma_mock_adapters.svh \
  src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv \
  tests/unit/rdma_adapter_contract_test.svh \
  tests/unit/rdma_cmq_engine_test.svh \
  tests/unit/rdma_control_plane_cmq_engine_test.svh \
  tests/unit/rdma_control_plane_test.svh \
  tests/unit/rdma_doorbell_scheduler_test.svh \
  tests/unit/rdma_model_test.svh \
  tests/unit/rdma_resource_manager_test.svh \
  tests/integration/rdma_host_mem_adapter_test.svh
git diff --cached --check
git diff --cached --name-only
git commit -m "feat: define queue DMA and interrupt snapshots"
```

预期：cached name list 恰好为上述 17 个路径，commit 不包含 docs、cache、codec 或 mock-control-plane 诊断文件。
