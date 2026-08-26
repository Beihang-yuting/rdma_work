# RDMA Function Binding Child Snapshot Construction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除 `rdma_function_binding` constructor 中新增 nested UVM factory allocation 触发的 VCS SIGSEGV，同时保持 queue DMA、capability 和 interrupt vector snapshot 的固定 schema、非空构造和深拷贝语义。

**Architecture:** `queue_dma`、`queue_caps` 和 vector queue element 是 binding-owned fixed-schema value objects。binding constructor 与 `do_copy()` 使用直接 `new`/`copy`，不允许 child factory override；binding 本身及这些类型作为独立对象仍保留 UVM factory 注册。

**Tech Stack:** SystemVerilog、UVM 1.2、Synopsys VCS W-2024.09-SP1、`scripts/run_vcs53.sh`、10.11.10.53。

---

## 实施边界

- 工作目录固定为 `/home/ryan/workspace/ryan/rdma_work/.worktrees/queue-resource-lifecycle`。
- 当前 RED 对应的正式 Task 1 diff 已存在且未 staged；不得丢失或重写其他 16 个计划内文件。
- 仅修改 `src/model/rdma_function_binding.svh` 中 queue child 的构造/深拷贝方式，并在现有 `tests/unit/rdma_model_test.svh` 中补齐非别名断言；不修改外部 host_mem、PCIe VIP 或 axis VIP。
- `tools/__pycache__/` 是既有未跟踪缓存，不得 stage 或提交。
- 53 的 SSH wrapper 为 `/tmp/rdma_sshpass_wrapper_codex/ssh`；所有仿真命令必须带 `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123`。
- production host_mem 的有效路径是 `/home/ubuntu/workspace/host_mem`；计划旧路径 `/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem` 在 53 上不存在。

### Task 1: 固定 Binding-Owned Child Snapshot Construction

**Files:**
- Modify: `src/model/rdma_function_binding.svh:284-380`
- Modify: `tests/unit/rdma_model_test.svh:342-425`
- Test: `tests/unit/rdma_control_plane_test.svh`
- Test: `tests/unit/rdma_adapter_contract_test.svh`
- Test: `tests/unit/rdma_resource_manager_test.svh`
- Test: `tests/integration/rdma_host_mem_adapter_test.svh`

- [ ] **Step 1: 写 fixed-schema child 不接受 factory override 的失败测试**

在 `rdma_model_test.svh` 的 `rdma_model_test` class 之前增加三个仅测试使用的 override type：

```systemverilog
class rdma_test_queue_dma_override extends rdma_queue_dma_context;
  `uvm_object_utils(rdma_test_queue_dma_override)
  function new(string name = "rdma_test_queue_dma_override");
    super.new(name);
  endfunction
endclass

class rdma_test_queue_caps_override extends rdma_queue_capabilities;
  `uvm_object_utils(rdma_test_queue_caps_override)
  function new(string name = "rdma_test_queue_caps_override");
    super.new(name);
  endfunction
endclass

class rdma_test_interrupt_vector_override
  extends rdma_interrupt_vector_binding;
  `uvm_object_utils(rdma_test_interrupt_vector_override)
  function new(string name = "rdma_test_interrupt_vector_override");
    super.new(name);
  endfunction
endclass
```

在 `rdma_model_test` 中增加以下 task，并在 `run_phase()` 的最后、`phase.drop_objection(this)` 之前调用一次：

```systemverilog
task automatic check_fixed_binding_child_schema();
  uvm_factory factory;
  rdma_function_binding source;
  rdma_function_binding copied;
  uvm_object copied_object;
  rdma_test_queue_dma_override dma_override;
  rdma_test_queue_caps_override caps_override;
  rdma_test_interrupt_vector_override vector_override;

  factory = uvm_factory::get();
  factory.set_type_override_by_type(
    rdma_queue_dma_context::get_type(),
    rdma_test_queue_dma_override::get_type()
  );
  factory.set_type_override_by_type(
    rdma_queue_capabilities::get_type(),
    rdma_test_queue_caps_override::get_type()
  );
  factory.set_type_override_by_type(
    rdma_interrupt_vector_binding::get_type(),
    rdma_test_interrupt_vector_override::get_type()
  );

  source = rdma_function_binding::type_id::create("fixed_schema_source");
  if ($cast(dma_override, source.queue_dma) ||
      $cast(caps_override, source.queue_caps))
    `uvm_error("BIND_FIXED_CONSTRUCTOR",
               "binding child constructor honored a factory override")

  source.queue_dma =
    rdma_test_queue_dma_override::type_id::create("source_dma_override");
  source.queue_dma.pasid_valid = 1'b1;
  source.queue_dma.pasid = 20'h34567;
  source.queue_dma.dma_domain_valid = 1'b1;
  source.queue_dma.dma_domain_id = 32'h1122_3344;
  source.queue_caps =
    rdma_test_queue_caps_override::type_id::create("source_caps_override");
  source.queue_caps.max_queue_ring_bytes = 64'h0020_0000;
  source.queue_caps.max_sgb_bytes = 64'h0040_0000;
  vector_override = rdma_test_interrupt_vector_override::type_id::create(
    "source_vector_override"
  );
  vector_override.function_local_vector = 3;
  vector_override.hardware_eq_vector = 17;
  vector_override.msix_table_index = 5;
  vector_override.enabled = 1'b1;
  source.interrupt_vectors.delete();
  source.interrupt_vectors.push_back(vector_override);

  copied_object = source.clone();
  if (!$cast(copied, copied_object)) begin
    `uvm_error("BIND_FIXED_COPY", "binding copy has the wrong type")
  end
  else begin
    if (copied.queue_dma == null) begin
      `uvm_error("BIND_FIXED_COPY", "binding queue DMA copy is null")
    end
    else begin
      if ($cast(dma_override, copied.queue_dma))
        `uvm_error("BIND_FIXED_COPY",
                   "binding queue DMA copy retained an overridden type")
      if (copied.queue_dma == source.queue_dma ||
          copied.queue_dma.pasid != source.queue_dma.pasid ||
          copied.queue_dma.dma_domain_id != source.queue_dma.dma_domain_id)
        `uvm_error("BIND_FIXED_COPY",
                   "binding queue DMA copy lost values or retained aliases")
    end
    if (copied.queue_caps == null) begin
      `uvm_error("BIND_FIXED_COPY", "binding queue caps copy is null")
    end
    else begin
      if ($cast(caps_override, copied.queue_caps))
        `uvm_error("BIND_FIXED_COPY",
                   "binding queue caps copy retained an overridden type")
      if (copied.queue_caps == source.queue_caps ||
          copied.queue_caps.max_queue_ring_bytes !=
            source.queue_caps.max_queue_ring_bytes ||
          copied.queue_caps.max_sgb_bytes != source.queue_caps.max_sgb_bytes)
        `uvm_error("BIND_FIXED_COPY",
                   "binding queue caps copy lost values or retained aliases")
    end
    if (copied.interrupt_vectors.size() != 1) begin
      `uvm_error("BIND_FIXED_COPY", "binding vector copy count changed")
    end
    else if (copied.interrupt_vectors[0] == null) begin
      `uvm_error("BIND_FIXED_COPY", "binding vector copy is null")
    end
    else begin
      if ($cast(vector_override, copied.interrupt_vectors[0]))
        `uvm_error("BIND_FIXED_COPY",
                   "binding vector copy retained an overridden type")
      if (copied.interrupt_vectors[0] == source.interrupt_vectors[0] ||
          copied.interrupt_vectors[0].hardware_eq_vector !=
            source.interrupt_vectors[0].hardware_eq_vector)
        `uvm_error("BIND_FIXED_COPY",
                   "binding vector copy lost values or retained aliases")
    end
  end
endtask
```

- [ ] **Step 2: 运行测试并确认两种 RED 都来自待修契约**

Run:

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_model_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
```

Expected:

- `rdma_model_test` compile/run 成功但报告 `BIND_FIXED_CONSTRUCTOR` 和 `BIND_FIXED_COPY` UVM error，因为当前 constructor/do_copy 使用 factory create/clone。
- `rdma_control_plane_test` compile/link 成功；`[RNTST] Running test...` 后 VCS SIGSEGV，命令非零退出且没有 UVM summary。

若两项没有以上述原因失败，停止并检查测试或 formal diff；环境、SSH 或许可证错误不是 RED。

```systemverilog
queue_dma = rdma_queue_dma_context::type_id::create("queue_dma");
queue_caps = rdma_queue_capabilities::type_id::create("queue_caps");
```

- [ ] **Step 3: 用最小 constructor 修正消除 nested factory allocation**

在 `rdma_function_binding::new()` 中只替换两个 child 构造表达式，保留所有字段初始化和 queue delete：

```systemverilog
queue_dma = new("queue_dma");
queue_caps = new("queue_caps");
interrupt_vectors.delete();
```

不得改变 `pcie`、BAR、validation 或其他 model 的构造方式。

- [ ] **Step 4: 连续两次运行 constructor GREEN 验证**

Run twice:

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
```

Expected on both runs: simulation reaches 8000 ps；UVM summary is exactly 0 warning / 0 error / 0 fatal。若任一次仍 SIGSEGV，回退 Step 3 的两行单点变化并返回设计文档中的 A2/A3/A4 边界，不增加 workaround。

- [ ] **Step 5: 将 binding `do_copy()` 收紧为 direct-new plus copy**

用以下固定类型规则替换 `queue_dma`、`queue_caps` 和 vector element 的 `clone()` 路径：

```systemverilog
if (rhs_binding.queue_dma == null) begin
  queue_dma = null;
end
else begin
  queue_dma = new("queue_dma");
  queue_dma.copy(rhs_binding.queue_dma);
end
if (rhs_binding.queue_caps == null) begin
  queue_caps = null;
end
else begin
  queue_caps = new("queue_caps");
  queue_caps.copy(rhs_binding.queue_caps);
end
interrupt_vectors.delete();
foreach (rhs_binding.interrupt_vectors[i]) begin
  if (rhs_binding.interrupt_vectors[i] == null) begin
    interrupt_vectors.push_back(null);
  end
  else begin
    rdma_interrupt_vector_binding vector_copy;
    vector_copy = new($sformatf("interrupt_vector_%0d", i));
    vector_copy.copy(rhs_binding.interrupt_vectors[i]);
    interrupt_vectors.push_back(vector_copy);
  end
end
```

保留 `uvm_object cloned_object`，因为本方法的 `pcie` 和 `owner_h` deep clone 仍使用它；只删除三个 queue child 分支对该变量的赋值和 cast。

- [ ] **Step 6: 验证 deep-copy 重构保持 GREEN**

Run:

```bash
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_model_test
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_control_plane_test
```

Expected: both tests reach their UVM summaries with 0 warning / 0 error / 0 fatal；`rdma_control_plane_test` 不再产生 native crash。

- [ ] **Step 7: 执行 Task 1 全部 53 回归**

Run each command independently:

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

Expected for every command: compile/link succeeds and UVM summary is exactly 0 warning / 0 error / 0 fatal。`rdma_adapter_contract_test` 还必须保留 domain mismatch 返回 `RDMA_SC_DMA_TRANSLATION` 的断言。

- [ ] **Step 8: 审核范围并提交完整 Task 1**

Run:

```bash
git diff --check
git status --short
git diff --stat HEAD
git diff HEAD -- src/model/rdma_function_binding.svh \
  tests/unit/rdma_model_test.svh
```

Expected: no whitespace errors；只有原 Task 1 的 17 个 tracked files 被修改；`tools/__pycache__/` 仍是唯一无关 untracked；没有 diagnostic probe、temporary shim、watchdog variant 或外部组件变化。

Stage exactly the Task 1 files:

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
git commit -m "feat: define queue DMA and interrupt snapshots"
```

Expected: commit contains exactly the 17 Task 1 files；design and plan commits remain separate；cache is not committed。
