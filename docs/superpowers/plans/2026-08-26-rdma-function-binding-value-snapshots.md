# RDMA Function Binding Value Snapshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 queue DMA authority、queue capability 和 interrupt vector 从 binding-owned UVM child class 迁移为 packed value snapshot，消除目标 VCS 中 nested child allocation 引发的 native SIGSEGV，同时保持 Task 1 的公开字段、validation 和 authority propagation 契约。

**Architecture:** 三个公开 snapshot 类型保留原名和字段名，但改为 package-scope packed struct；`rdma_function_binding` 和 resource-manager projection 使用结构体及 queue 的值赋值。DMA/capability validation 由 package helper 承担，PCIe identity、owner handle、mapping/request context 和外部 adapter 的现有 class/authority 规则保持不变。

**Tech Stack:** SystemVerilog、UVM 1.2、Synopsys VCS W-2024.09-SP1、`scripts/run_vcs53.sh`、10.11.10.53、production host_mem `/home/ubuntu/workspace/host_mem`。

---

## 实施边界与文件职责

- 工作目录固定为 `/home/ryan/workspace/ryan/rdma_work/.worktrees/queue-resource-lifecycle`，分支为 `feat/queue-resource-lifecycle`。
- 当前未提交的 17 个 tracked files 是已确认的 Task 1 RED diff；不得回退 domain/PASID/vector propagation，也不得修改外部 `host_mem`、PCIe VIP、axis VIP 或 VCS/UVM 源码。
- `src/model/rdma_function_binding.svh` 定义三个 value schema、两个 validation helper，以及 binding 的构造、复制和 validation。
- `src/core/rdma_resource_manager.svh` 负责 registry snapshot projection 与 identity equality；它直接复制 value snapshot，但继续深拷贝 PCIe/owner 等 class。
- `tests/unit/rdma_model_test.svh` 负责 class-handle alias RED 和 struct-value GREEN；其余六个 unit fixture 与一个 host_mem integration fixture 只迁移 vector 初始化语法。
- `src/model/rdma_dma_request_context.svh`、`src/model/rdma_dma_mapping.svh`、`src/core/rdma_control_plane.svh`、`src/core/rdma_doorbell_scheduler.svh`、`src/core/rdma_cmq_engine.svh`、`tests/mocks/rdma_mock_adapters.svh` 和 `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv` 保留现有 Task 1 authority propagation diff，不因 value conversion 改写。
- `tools/__pycache__/` 是唯一无关 untracked cache；不得 stage、删除或提交。
- 所有 VCS 仿真必须在 53 上运行，并显式带 `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123`。预期 GREEN 必须有 UVM warning/error/fatal `0/0/0`；SSH、许可证、编译基础设施错误不算 RED 或 GREEN。

### Task 1: 将 Binding Snapshot 迁移为值类型

**Files:**
- Modify: `src/model/rdma_function_binding.svh:112-450`
- Modify: `src/core/rdma_resource_manager.svh:647-735,1312-1374`
- Modify: `tests/unit/rdma_model_test.svh:1-259,475-566,983`
- Modify: `tests/unit/rdma_adapter_contract_test.svh:94-101`
- Modify: `tests/unit/rdma_cmq_engine_test.svh:2996-3002`
- Modify: `tests/unit/rdma_control_plane_cmq_engine_test.svh:273-279`
- Modify: `tests/unit/rdma_control_plane_test.svh:604-610`
- Modify: `tests/unit/rdma_doorbell_scheduler_test.svh:136-142`
- Modify: `tests/unit/rdma_resource_manager_test.svh:1609-1615,4310-4318,4479-4492`
- Modify: `tests/integration/rdma_host_mem_adapter_test.svh:159-167`
- Preserve and commit: `src/model/rdma_dma_request_context.svh`, `src/model/rdma_dma_mapping.svh`, `src/core/rdma_control_plane.svh`, `src/core/rdma_doorbell_scheduler.svh`, `src/core/rdma_cmq_engine.svh`, `tests/mocks/rdma_mock_adapters.svh`, `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv`

- [ ] **Step 1: 用 assignment alias 测试替换失效的 factory-override 测试**

删除 `tests/unit/rdma_model_test.svh` 顶部的 `rdma_test_queue_dma_override`、`rdma_test_queue_caps_override` 和 `rdma_test_interrupt_vector_override` 三个 class，并完整删除 `check_fixed_binding_child_schema()`。

在 `rdma_model_test` 中增加以下函数。该代码只使用 class 与 struct 都支持的 assignment/field access，因此 production conversion 前后均可编译：

```systemverilog
function automatic void check_binding_snapshot_value_semantics();
  rdma_function_binding source;
  rdma_function_binding destination;

  source = make_valid_binding("value_snapshot_source");
  destination = make_valid_binding("value_snapshot_destination");
  source.queue_dma.pasid = 20'h34567;
  source.queue_dma.dma_domain_id = 32'h1122_3344;
  source.queue_caps.max_queue_ring_bytes = 64'h0020_0000;
  source.queue_caps.max_sgb_bytes = 64'h0040_0000;
  source.interrupt_vectors[0].hardware_eq_vector = 17;

  destination.queue_dma = source.queue_dma;
  destination.queue_caps = source.queue_caps;
  destination.interrupt_vectors = source.interrupt_vectors;

  destination.queue_dma.pasid = 20'h54321;
  destination.queue_dma.dma_domain_id = 32'h5566_7788;
  destination.queue_caps.max_queue_ring_bytes = 64'h0040_0000;
  destination.queue_caps.max_sgb_bytes = 64'h0080_0000;
  destination.interrupt_vectors[0].hardware_eq_vector = 29;

  if (source.queue_dma.pasid != 20'h34567 ||
      source.queue_dma.dma_domain_id != 32'h1122_3344 ||
      source.queue_caps.max_queue_ring_bytes != 64'h0020_0000 ||
      source.queue_caps.max_sgb_bytes != 64'h0040_0000 ||
      source.interrupt_vectors[0].hardware_eq_vector != 17)
    `uvm_error("BIND_VALUE_ALIAS",
               "assigned binding snapshots alias the source")
endfunction
```

把 `run_phase()` 末尾原来的调用：

```systemverilog
check_fixed_binding_child_schema();
```

替换为：

```systemverilog
check_binding_snapshot_value_semantics();
```

- [ ] **Step 2: 在 53 上观察 value-alias 与 native-crash 两条 RED**

分别运行：

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_model_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
```

预期：

- `rdma_model_test` 完成编译和运行，只因 `BIND_VALUE_ALIAS` 报 UVM error；旧 class handle/queue element assignment 会修改 source。
- `rdma_control_plane_test` 完成 compile/link，在 `[RNTST] Running test...` 后发生 VCS native SIGSEGV，命令非零退出且没有正常 UVM summary。
- 如果 model test 因语法、null、factory override 或其他 tag 失败，先修正测试而不改 production；如果 control-plane 失败来自 SSH、许可证或同步错误，不进入 GREEN。

- [ ] **Step 3: 定义 packed value schema 与 package validation helper**

在 `src/model/rdma_function_binding.svh` 中用以下定义完整替换三个 `uvm_object` class。不得保留 snapshot factory registration、constructor、`do_copy()`、class `validate()` 或 subtype：

```systemverilog
typedef struct packed {
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
} rdma_queue_dma_context;

typedef struct packed {
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

typedef struct packed {
  int unsigned function_local_vector;
  int unsigned hardware_eq_vector;
  int unsigned msix_table_index;
  bit enabled;
} rdma_interrupt_vector_binding;

function automatic rdma_status rdma_validate_queue_dma_context(
  input rdma_queue_dma_context context
);
  if (!context.pasid_valid && context.pasid != 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "invalid queue PASID must be zero");
  return rdma_status::success();
endfunction

function automatic rdma_status rdma_validate_queue_capabilities(
  input rdma_queue_capabilities capabilities
);
  if (capabilities.min_cq_depth == 0 ||
      capabilities.max_cq_depth == 0 ||
      capabilities.min_srq_depth == 0 ||
      capabilities.max_srq_depth == 0 ||
      capabilities.max_ceq_depth == 0 ||
      capabilities.max_aeq_depth == 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "queue depth capability is zero");
  if (capabilities.min_cq_depth > capabilities.max_cq_depth)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "minimum CQ depth exceeds maximum");
  if (capabilities.min_srq_depth > capabilities.max_srq_depth)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "minimum SRQ depth exceeds maximum");
  if (capabilities.max_wq_sge == 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "maximum WQ SGE capability is zero");
  if (capabilities.max_queue_ring_bytes == 0 ||
      capabilities.max_sgb_bytes == 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "queue ring or SGB byte capability is zero");
  return rdma_status::success();
endfunction
```

这些 helper 保持既有 status code/message；`dma_domain_valid == 1` 且 ID 为 0 合法，`max_queue_ring_bytes > 2 MiB` 也合法。

- [ ] **Step 4: 把 binding 构造、复制和 validation 改为值语义**

在 `rdma_function_binding::new()` 中使用零值初始化：

```systemverilog
queue_dma = '0;
queue_caps = '0;
interrupt_vectors.delete();
```

在 `do_copy()` 中删除三个 snapshot 的 null/clone/cast/vector loop，只保留 PCIe identity 与 owner handle 使用 `cloned_object`，并加入：

```systemverilog
queue_dma = rhs_binding.queue_dma;
queue_caps = rhs_binding.queue_caps;
interrupt_vectors = rhs_binding.interrupt_vectors;
```

在 `validate()` 中删除 snapshot-null 和 vector-null 分支，改为：

```systemverilog
status = rdma_validate_queue_dma_context(queue_dma);
if (!status.ok())
  return status;
if (queue_dma.requester_bdf != pcie.bdf)
  return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                           "queue requester BDF does not match PCIe BDF");
status = rdma_validate_queue_capabilities(queue_caps);
if (!status.ok())
  return status;
if (rdma_vf_id > 8'hff)
  return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                           "RDMA VF ID exceeds 8 bits");
foreach (interrupt_vectors[i]) begin
  for (int j = 0; j < i; j++) begin
    if (interrupt_vectors[j].function_local_vector ==
        interrupt_vectors[i].function_local_vector)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "interrupt Function-local vector is duplicated"
      );
  end
end
```

不得改变后续 BAR、notify、ACTIVE owner/domain/MSE/BME/ready validation。

- [ ] **Step 5: 把 resource-manager projection 和 equality 改为值操作**

在 `project_binding_value()` 中保留 source binding null check、`result = new(...)`、PCIe/owner 的独立 projection；删除 `result.queue_dma = null`、`result.queue_caps = null`、snapshot source null checks、snapshot `new` 和 vector element loop。PCIe projection成功后直接执行：

```systemverilog
result.queue_dma = source.queue_dma;
result.queue_caps = source.queue_caps;
result.interrupt_vectors = source.interrupt_vectors;
```

在 `same_binding_identity()` 中删除三个 snapshot 的 null 分支，使用明确逐字段比较，确保 domain valid/value 没有遗漏：

```systemverilog
if (lhs.queue_dma.requester_bdf != rhs.queue_dma.requester_bdf ||
    lhs.queue_dma.pasid_valid != rhs.queue_dma.pasid_valid ||
    lhs.queue_dma.pasid != rhs.queue_dma.pasid ||
    lhs.queue_dma.dma_domain_valid != rhs.queue_dma.dma_domain_valid ||
    lhs.queue_dma.dma_domain_id != rhs.queue_dma.dma_domain_id)
  return 1'b0;
if (lhs.queue_caps.min_cq_depth != rhs.queue_caps.min_cq_depth ||
    lhs.queue_caps.max_cq_depth != rhs.queue_caps.max_cq_depth ||
    lhs.queue_caps.min_srq_depth != rhs.queue_caps.min_srq_depth ||
    lhs.queue_caps.max_srq_depth != rhs.queue_caps.max_srq_depth ||
    lhs.queue_caps.max_ceq_depth != rhs.queue_caps.max_ceq_depth ||
    lhs.queue_caps.max_aeq_depth != rhs.queue_caps.max_aeq_depth ||
    lhs.queue_caps.max_wq_sge != rhs.queue_caps.max_wq_sge ||
    lhs.queue_caps.max_queue_ring_bytes !=
      rhs.queue_caps.max_queue_ring_bytes ||
    lhs.queue_caps.max_sgb_bytes != rhs.queue_caps.max_sgb_bytes)
  return 1'b0;
if (lhs.interrupt_vectors.size() != rhs.interrupt_vectors.size())
  return 1'b0;
foreach (lhs.interrupt_vectors[i]) begin
  if (lhs.interrupt_vectors[i].function_local_vector !=
        rhs.interrupt_vectors[i].function_local_vector ||
      lhs.interrupt_vectors[i].hardware_eq_vector !=
        rhs.interrupt_vectors[i].hardware_eq_vector ||
      lhs.interrupt_vectors[i].msix_table_index !=
        rhs.interrupt_vectors[i].msix_table_index ||
      lhs.interrupt_vectors[i].enabled != rhs.interrupt_vectors[i].enabled)
    return 1'b0;
end
```

- [ ] **Step 6: 迁移全部 vector fixture 并执行 snapshot 静态禁用项检查**

在以下 9 处删除 `rdma_interrupt_vector_binding::type_id::create(...)`，用同一条 value 初始化替换；保留其后的四个字段赋值和 `push_back()`：

```systemverilog
vector = '0;
```

位置为：

- `tests/unit/rdma_adapter_contract_test.svh` 一处；
- `tests/unit/rdma_cmq_engine_test.svh` 一处；
- `tests/unit/rdma_control_plane_cmq_engine_test.svh` 一处；
- `tests/unit/rdma_control_plane_test.svh` 一处；
- `tests/unit/rdma_doorbell_scheduler_test.svh` 一处；
- `tests/unit/rdma_model_test.svh` 一处；
- `tests/unit/rdma_resource_manager_test.svh` 两处，其中 composite fixture 使用 `composite_function_vector = '0;`；
- `tests/integration/rdma_host_mem_adapter_test.svh` 一处。

`tests/unit/rdma_resource_manager_test.svh` 的 composite projection 断言当前还把 class handle 相等当作 alias failure。删除以下三个布尔项，因为 struct 相等表示复制值正确，而不是 alias：

```systemverilog
composite_function_lookup.binding.queue_dma ==
  composite_function_binding.queue_dma ||
composite_function_lookup.binding.queue_caps ==
  composite_function_binding.queue_caps ||
composite_function_lookup.binding.interrupt_vectors[0] ==
  composite_function_vector ||
```

保留紧随其后的 domain、capability、vector 字段值断言，以及 binding/PCIe/owner class handle 非别名断言。

运行以下静态检查：

```bash
rg -n 'class rdma_(queue_dma_context|queue_capabilities|interrupt_vector_binding)|`uvm_object_utils\(rdma_(queue_dma_context|queue_capabilities|interrupt_vector_binding)\)|rdma_(queue_dma_context|queue_capabilities|interrupt_vector_binding)::(type_id::create|get_type)' src tests
rg -n '(queue_dma|queue_caps)\s*=\s*(null|new)|rhs_binding\.(queue_dma|queue_caps)\.clone|interrupt_vectors\[[^]]+\]\s*(==|!=)\s*null|null\s*(==|!=)\s*interrupt_vectors\[[^]]+\]|\b(vector|vector_copy|composite_function_vector)\s*=\s*new' src/model/rdma_function_binding.svh src/core/rdma_resource_manager.svh tests/unit/rdma_adapter_contract_test.svh tests/unit/rdma_cmq_engine_test.svh tests/unit/rdma_control_plane_cmq_engine_test.svh tests/unit/rdma_control_plane_test.svh tests/unit/rdma_doorbell_scheduler_test.svh tests/unit/rdma_model_test.svh tests/unit/rdma_resource_manager_test.svh tests/integration/rdma_host_mem_adapter_test.svh
rg -n '(queue_dma|queue_caps)\s*(==|!=)\s*null|null\s*(==|!=)\s*(queue_dma|queue_caps)|\.(queue_dma|queue_caps)\.(validate|copy|clone)\(|interrupt_vectors\[[^]]+\]\.(copy|clone)\(' src tests
```

预期：三条命令均无输出并以 status 1 表示没有匹配项。不得用注释或重命名绕过检查；PCIe identity、BAR 和 owner handle 的 class allocation/null/clone 仍允许。

- [ ] **Step 7: 在 53 上验证 alias GREEN 和 control-plane 连续两次无崩溃**

运行：

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_model_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
```

预期：三次均到达正常 UVM summary 且 warning/error/fatal 为 `0/0/0`；两个 control-plane run 都到达 8000 ps，无 native signal。`rdma_model_test` 不出现 `BIND_VALUE_ALIAS`，并继续覆盖 PCIe/owner class deep copy。

- [ ] **Step 8: 在 53 上执行 Task 1 全回归**

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

预期：8 项 compile/link/run 全部成功，每项 UVM warning/error/fatal 为 `0/0/0`。`rdma_adapter_contract_test` 必须继续证明 domain mismatch 返回 `RDMA_SC_DMA_TRANSLATION`；host_mem test 必须继续证明 request context/mapping 的 BDF、PASID 和 domain 逐字段传播。

- [ ] **Step 9: 审核准确范围并提交完整 Task 1**

运行：

```bash
git diff --check
git status --short
git diff --stat HEAD
git diff HEAD -- src/model/rdma_function_binding.svh \
  src/core/rdma_resource_manager.svh tests/unit/rdma_model_test.svh
```

预期：无 whitespace error；恰好原 Task 1 的 17 个 tracked files 被修改；`tools/__pycache__/` 仍是唯一无关 untracked；没有 diagnostic probe、temporary shim、watchdog variant 或外部组件变化。

只 stage 以下 17 个 Task 1 文件：

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

预期：cached name list 恰好为上述 17 个路径，commit 不包含两个计划文档或 cache；计划文档已在实施前的独立 docs commit 中提交。
