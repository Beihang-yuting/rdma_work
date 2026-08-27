# RDMA Function Binding Value Snapshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 提交现有 Task 1 value snapshot candidate：三个 snapshot 保持 unpacked value schema和完整 authority propagation，并以最小 VCS flag 修复 10.11.10.53 上 W-2024.09-SP1 的 class-codegen crash。

**Architecture:** 三个 snapshot 是 package-scope fixed-schema unpacked SystemVerilog value type，不依赖连续 bit layout。`sim/Makefile` 只增加 `-debug_access+class` 作为 W-2024.09-SP1 class-codegen workaround；它不是功能 RTL requirement。owned snapshot test 的第一次 PASID 必须来自 binding queue-DMA authority，同时保留 lock 前 request/access mutation 与 CMQ 后 caller PASID mutation。

**Tech Stack:** SystemVerilog、UVM 1.2、Synopsys VCS W-2024.09-SP1、`scripts/run_vcs53.sh`、10.11.10.53、production host_mem `/home/ubuntu/workspace/host_mem`。

---

## 恢复边界与已知证据

- 工作目录固定为 `/home/ryan/workspace/ryan/rdma_work/.worktrees/queue-resource-lifecycle`，分支为 `feat/queue-resource-lifecycle`。
- 保留原 Task 1 的 17 个 unstaged tracked files；最终再包含 `sim/Makefile` 和两份纠正文档，共 20 个 tracked files。
- `tools/__pycache__/` 是唯一无关 untracked cache；不得 stage、删除、修改或提交。
- packed、unpacked、primitive flatten 和 unpacked plus `-O0` candidates 都 compile/link 成功，但 `rdma_control_plane_test` 在 `[RNTST]` 后 native SIGSEGV；因此 representation alone 和 `-O0` 都不是修复。
- unpacked plus exactly `-debug_access+class` 能到达 8000 ps及 UVM 0/0/0；不得改用 `-debug_access+all`、`-kdb` 或其他 compiler workaround。
- 最终 flag 下，owned snapshot 的 `first_pasid = 20'h1a111` 会以 `RDMA_SC_DMA_TRANSLATION` 和 UVM errors 正常 RED；改为 `binding.queue_dma.pasid` 后 GREEN。这是 test authority correction，不是 crash/code-shape workaround。
- `src/codec/xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh` 和 `tests/mocks/rdma_mock_control_plane.svh` 必须与 `HEAD` 相同。不得留下 `DBG_CP`、typed-only return、对象名 guard、direct-call probe 或 diagnostic marker。
- 不修改 test name/order、timeout、fork structure、external host_mem、UVM 或 VCS installation。
- 所有 VCS 仿真必须在 53 上运行，并显式带 `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123`。

### Task 1: 提交 Unpacked Snapshots 与最小 VCS Workaround

**Files:**

- Preserve/commit: 原 Task 1 的 17 个 tracked implementation/test files
- Modify: `sim/Makefile`
- Modify: `tests/unit/rdma_control_plane_test.svh`
- Correct: `docs/superpowers/specs/2026-08-26-rdma-function-binding-value-snapshots-design.md`
- Correct: `docs/superpowers/plans/2026-08-26-rdma-function-binding-unpacked-value-snapshots.md`

- [ ] **Step 1: 观察最终 amendment 的两个 RED**

先确认原 17-file candidate 无额外 tracked change或诊断：

```bash
git diff --check
test "$(git status --short | awk '$1 != "??" {n++} END {print n+0}')" -eq 17
test -z "$(git diff -- src/codec/xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh tests/mocks/rdma_mock_control_plane.svh)"
! rg -n 'DBG_CP|typed-only return' src tests
```

运行 unpacked/no-workaround candidate：

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
```

预期：compile/link 成功，在 `[RNTST]` 后 native SIGSEGV且无 UVM summary。该结果与已记录的 packed、primitive flatten 和 `-O0` negative evidence共同证明 representation alone 不是修复。

增加最终 flag但保留无 authority 的固定 `first_pasid` 后，再运行同一命令。预期：无 native crash，owned snapshot 返回 `RDMA_SC_DMA_TRANSLATION` 并以非 pristine UVM summary RED。

- [ ] **Step 2: 做两个最小修改**

`sim/Makefile` 只为 `VCS_FLAGS` 增加 `-debug_access+class`，并加简短注释说明它是 W-2024.09-SP1 class-codegen miscompile workaround、不是功能 RTL requirement：

```make
# Work around a VCS W-2024.09-SP1 class-codegen miscompile; not an RTL requirement.
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -debug_access+class
```

`tests/unit/rdma_control_plane_test.svh` 的 owned snapshot case 使用：

```systemverilog
first_pasid = binding.queue_dma.pasid;
```

保留 `request.length`、`request.access` 的 lock 前 mutation和后续 `dma_context.pasid = 20'h2b222` mutation。不得同时修改 test name/order、timeout 或 fork structure。

- [ ] **Step 3: 纠正两份 authoritative docs 与静态检查**

两份 docs 必须记录 packed/unpacked/primitive/`-O0` negative evidence、`-debug_access+class` GREEN、fixed-authority PASID RED/GREEN、20-file scope、最终 commands/acceptance和 non-goals。

运行：

```bash
test "$(rg -c '^typedef struct \{$' src/model/rdma_function_binding.svh)" -eq 3
! rg -n '^typedef struct packed \{' src/model/rdma_function_binding.svh
! rg -n '\$bits\s*\(\s*rdma_(queue_dma_context|queue_capabilities|interrupt_vector_binding)|rdma_(queue_dma_context|queue_capabilities|interrupt_vector_binding)\s*\x27\s*\(' src tests
! rg -n '\{(<<|>>).*\b(queue_dma|queue_caps|interrupt_vectors)\b|\b(queue_dma|queue_caps|interrupt_vectors)\b.*\{(<<|>>)' src tests
! rg -n 'DBG_CP|typed-only return' src tests
test -z "$(git diff -- src/codec/xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh tests/mocks/rdma_mock_control_plane.svh)"
test "$(rg -o -- '-debug_access\+class' sim/Makefile | wc -l)" -eq 1
! rg -n -- '-debug_access\+all|-kdb|-O0' sim/Makefile
rg -n 'first_pasid = binding\.queue_dma\.pasid' tests/unit/rdma_control_plane_test.svh
rg -n 'dma_context\.pasid = 20.h2b222' tests/unit/rdma_control_plane_test.svh
git diff --check
```

预期：schema unpacked；只有批准的 class flag；无 layout assumption、诊断、codec/mock diff或 whitespace error；两次 PASID mutation均保留。

- [ ] **Step 4: 在 53 上执行完整 Task 1 回归**

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

预期：8 项 compile/link/run 全部成功，每项 UVM warning/error/fatal 为 `0/0/0`。adapter contract 继续证明 domain mismatch 返回 `RDMA_SC_DMA_TRANSLATION`；model test 无 `BIND_VALUE_ALIAS`；host_mem test 继续证明 BDF/PASID/domain propagation。

再独立运行一次最终 control-plane：

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
```

预期：第二次也到达 8000 ps，UVM 0/0/0且无 native signal。两次 control-plane 必须都基于 exact committed diff和 final flags。

- [ ] **Step 5: 全量 self-review、精确 stage 并提交**

```bash
git diff --check
test "$(git status --short | awk '$1 != "??" {n++} END {print n+0}')" -eq 20
git diff --stat HEAD
git diff HEAD -- src/model/rdma_function_binding.svh sim/Makefile \
  tests/unit/rdma_control_plane_test.svh \
  docs/superpowers/specs/2026-08-26-rdma-function-binding-value-snapshots-design.md \
  docs/superpowers/plans/2026-08-26-rdma-function-binding-unpacked-value-snapshots.md
git status --short
```

逐文件审核完整 Task 1 diff和 scope。只 stage原 17 个 tracked files以及 `sim/Makefile`、两份 docs：

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
  tests/integration/rdma_host_mem_adapter_test.svh \
  sim/Makefile \
  docs/superpowers/specs/2026-08-26-rdma-function-binding-value-snapshots-design.md \
  docs/superpowers/plans/2026-08-26-rdma-function-binding-unpacked-value-snapshots.md
git diff --cached --check
test "$(git diff --cached --name-only | wc -l)" -eq 20
git diff --cached --name-only
git commit -m "feat: define queue DMA and interrupt snapshots"
```

接受条件：cached list 恰好 20 个 intended paths；commit 不含 `tools/__pycache__/`、codec、mock-control-plane、外部源码或诊断文件；worktree只剩无关 cache和指定 report。

## 非目标

- 不通过 packed/unpacked representation、primitive flatten、child class或 direct-new snapshot 声称单独修复 crash。
- 不使用 `-O0`、`-debug_access+all`、`-kdb`、对象名 guard、direct-call probe、diagnostic marker、codec/string formatting改写或 typed-only return。
- 不拆分或弱化 test，不改变 test name/order、timeout或 fork structure。
- 不修改 external host_mem、UVM、VCS installation或 Task 1 之外的 queue lifecycle policy、executor/recovery行为。
- 不恢复 snapshot packed layout；未来若需 hardware image，必须由独立 codec逐字段编码。
