# RDMA Task 14B Queue Resource Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 CQ、SRQ、CEQ、AEQ 的类型化、generation-safe、可恢复 UVM 生命周期，支持 owned/borrowed 64-bit DMA payload、xtr_v1 `INDIRECT_4K` page directory、HMC/GRM context slot 和严格的 delete/OCC 顺序。

**Architecture:** `rdma_control_plane` 继续拥有 transaction ID、per-Function lock 和 generation fence，并把已经加锁的队列事务委托给 `rdma_queue_lifecycle_executor`。类型化 policy 只推导布局、初始化图像和 CMQ descriptor；backing planner 只管理 role、IOVA、ownership 和 release authority；resource manager 保存唯一权威 snapshot 与逐步 recovery 进度。

**Tech Stack:** SystemVerilog/UVM 1.2、Synopsys VCS（`10.11.10.53`）、现有 xtr_v1 codec/CMQ engine、`rdma_host_mem_api`、新增 `rdma_context_backing_api`、Python 3/pytest 静态 checker。

---

## 执行前提

- 实施时先使用 `superpowers:using-git-worktrees` 创建独立 worktree；每个任务严格执行失败测试、确认失败、最小实现、确认通过、提交。
- 所有 SystemVerilog 仿真只通过 `scripts/run_vcs53.sh` 在 `10.11.10.53` 的 bash login shell 上运行。
- 不执行 `scripts/run_vcs53.sh core regression`：当前 Makefile 会把 `regression` 当成 UVM test class。最终验证使用本文列出的明确 test class 循环。
- 不修改或复制 `pcie_work`、`axis_vip`、`net_packet`、`host_mem` 源码；生产适配只修改本仓库中的 adapter。
- 不修改冻结的 xtr_v1 opcode、context field 或 CMQ envelope 定义。新增 queue PD entry codec 放在独立文件。
- 未跟踪的 `tests/unit/__pycache__/` 和 `tools/__pycache__/` 不加入任何提交。
- 每次 VCS 运行预期末尾均为 `UVM_WARNING : 0`、`UVM_ERROR : 0`、`UVM_FATAL : 0`；预期红灯必须是当前任务新增断言或缺失符号导致，而不是环境/许可证错误。

## 固定语义与非目标

- 本轮只实现 CQ/SRQ/CEQ/AEQ control-plane lifecycle，不实现 CQE/CEQE/AEQE 消费、SRQ WQE、doorbell、QP、BAR/MMIO 或中断处理。
- lifecycle 只生成 `RDMA_OBJECT_INDIRECT_4K`；每个有 PD 的 ring 为 4 KiB 到 2 MiB、1 到 512 页。`DIRECT_4K`、`HUGE_2M`、`L3_INDIRECT_4K` 请求明确返回 `RDMA_SC_UNSUPPORTED_OPCODE`。
- caller 只能传 `rdma_queue_backing_spec` 和 Function-scoped mapping slice，公共 API 不接受裸 DMA/IOVA/backing 地址。
- 设备地址永远从 `mapping.iova` 推导；`mapping.backing_addr` 只由 host_mem adapter 访问。PCIe BAR aperture 不参与 DMA 地址计算。
- payload 可以 owned 或 borrowed；PD 和 CQ/SRQ context slot 永远由控制面管理。borrowed payload 会被初始化，但永不被控制面 release。
- create 可见顺序固定为 payload → page directory → context slot/shadow → create CMQ。
- CQ destroy 固定为 delete → CQ_PD flush → context → PD → payload。
- SRQ destroy 固定为 SRFQ_PD flush → SRQ_PD flush → delete → context → SRFQ_PD → SRQ_PD → SGB → SRFQ_RING → SRQ_RING。
- CEQ/AEQ destroy 固定为 delete → PD → payload。
- live dependent/outstanding operation 返回 `RDMA_SC_RESOURCE_BUSY`，保持 ACTIVE，不发送任何 cleanup CMQ。
- QUERY success 携带 typed context 才证明 PRESENT；只有 opcode-specific invalid-context ecode 白名单才证明 ABSENT；QUERY 不能证明 OCC flush 完成。
- SRQ normal destroy 恢复 ACTIVE 时原子清除本次两个 pre-delete flush 完成位和 ticket；ERROR recovery 保留已经证明的进度。
- mapping/context release completion 与 registry 完成位是独立证据；重复 recovery 必须 exactly-once。

## 文件边界

| 文件 | 单一职责 |
|---|---|
| `src/model/rdma_function_binding.svh` | queue DMA、capability 和 interrupt vector 的不可变 Function snapshot。 |
| `src/model/rdma_dma_request_context.svh` | owned allocation 的 BDF/PASID/domain 请求上下文。 |
| `src/model/rdma_dma_mapping.svh` | mapping domain 权威与完整 access check。 |
| `src/model/rdma_queue_lifecycle_models.svh` | role、slice、layout、plan、context ref、flush target、preflight value objects。 |
| `src/model/rdma_semantic_requests.svh` | 四类 queue create 和 typed destroy 的 caller 语义。 |
| `src/model/rdma_resources.svh` | CQ/SRQ/CEQ/AEQ 的权威 queue plan snapshot。 |
| `src/model/rdma_control_plane_models.svh` | queue recovery intent、ambiguous operation 和完整 recovery snapshot。 |
| `src/adapter/rdma_context_backing_api.svh` | HMC/GRM context slot 的 acquire/write/release/completion-query 契约。 |
| `src/codec/xtr_v1/rdma_xtr_v1_queue_page_codec.svh` | 4 KiB PD entry/table 的 big-endian codec。 |
| `src/core/rdma_queue_lifecycle_policy.svh` | CQ/SRQ/CEQ/AEQ typed preflight、model/image 和 CMQ descriptor builder。 |
| `src/core/rdma_queue_backing_planner.svh` | owned/borrowed materialization、IOVA page list、重叠和 authority 校验。 |
| `src/core/rdma_queue_lifecycle_executor.svh` | 已加锁 create/destroy/recovery 顺序、rollback 和 progress persistence。 |
| `src/core/rdma_resource_manager.svh` | queue ID width、plan projection、narrow progress updates、ACTIVE restore。 |
| `src/core/rdma_control_plane.svh` | typed facade、transaction ID、共享 Function lock 和 generation fence。 |
| `tests/mocks/rdma_mock_context_backing.svh` | context slot authority、bounds、故障注入、调用顺序和 completion query。 |
| `tests/unit/rdma_queue_lifecycle_models_test.svh` | queue value object、copy、validation、request/resource snapshot。 |
| `tests/unit/rdma_context_backing_contract_test.svh` | context API slot/view/release 契约。 |
| `tests/unit/rdma_xtr_v1_queue_page_codec_test.svh` | PD entry/table golden image。 |
| `tests/unit/rdma_queue_lifecycle_test.svh` | 四类 queue create/destroy、失败注入、busy、并发主测试。 |
| `tests/unit/rdma_queue_recovery_test.svh` | reconcile/QUERY/OCC/exactly-once recovery。 |
| `tools/check_queue_lifecycle.py` | IOVA-only、core dependency、frozen ABI 和 API-shape 静态约束。 |
| `tests/unit/test_check_queue_lifecycle.py` | 静态 checker 的正反 fixture。 |

新增 `.svh` 都由现有 package `.sv` include；`sim/filelists/core.f` 和 `sim/filelists/host_mem.f` 不增加 `.svh` 条目。

## 最终命名与公开接口

以下名称是所有任务的唯一命名基准：

```systemverilog
typedef enum bit { RDMA_QUEUE_BACKING_OWNED,
                   RDMA_QUEUE_BACKING_BORROWED } rdma_queue_backing_mode_e;

typedef enum bit [3:0] {
  RDMA_QUEUE_ROLE_CQ_RING                = 4'd0,
  RDMA_QUEUE_ROLE_SRQ_RING               = 4'd1,
  RDMA_QUEUE_ROLE_SRFQ_RING              = 4'd2,
  RDMA_QUEUE_ROLE_SRQ_SGB                = 4'd3,
  RDMA_QUEUE_ROLE_CEQ_RING               = 4'd4,
  RDMA_QUEUE_ROLE_AEQ_RING               = 4'd5,
  RDMA_QUEUE_ROLE_CQ_PD                  = 4'd6,
  RDMA_QUEUE_ROLE_SRQ_PD                 = 4'd7,
  RDMA_QUEUE_ROLE_SRFQ_PD                = 4'd8,
  RDMA_QUEUE_ROLE_CEQ_PD                 = 4'd9,
  RDMA_QUEUE_ROLE_AEQ_PD                 = 4'd10,
  RDMA_QUEUE_ROLE_CQC_CONTEXT_SHADOW     = 4'd11,
  RDMA_QUEUE_ROLE_SRFQC_CONTEXT_SHADOW   = 4'd12
} rdma_queue_backing_role_e;

typedef enum bit { RDMA_QUEUE_FLUSH_PRE_DELETE,
                   RDMA_QUEUE_FLUSH_POST_DELETE } rdma_queue_flush_phase_e;
typedef enum bit { RDMA_QUEUE_RECOVER_CREATE_ROLLBACK,
                   RDMA_QUEUE_RECOVER_NORMAL_DESTROY } rdma_queue_recovery_intent_e;
typedef enum bit [1:0] { RDMA_QUEUE_AMBIG_NONE,
                         RDMA_QUEUE_AMBIG_CREATE,
                         RDMA_QUEUE_AMBIG_DELETE,
                         RDMA_QUEUE_AMBIG_OCC_FLUSH } rdma_queue_ambiguous_operation_e;

virtual class rdma_context_backing_api extends uvm_object;
  pure virtual function rdma_status acquire(
    rdma_function_binding binding,
    rdma_resource_kind_e resource_kind,
    int unsigned local_id,
    output rdma_context_backing_ref ref
  );
  pure virtual function rdma_status write(
    rdma_context_backing_ref ref,
    longint unsigned slot_relative_offset,
    byte unsigned data[]
  );
  pure virtual function rdma_status \release (
    rdma_context_backing_ref ref
  );
  pure virtual function rdma_status query_release_completion(
    rdma_context_backing_ref ref,
    output bit complete
  );
endclass

class rdma_queue_lifecycle_executor extends uvm_object;
  task create_locked(rdma_function_binding binding,
                     rdma_function_handle expected_owner,
                     rdma_semantic_request request,
                     longint unsigned transaction_id,
                     output rdma_queue_resource resource,
                     output rdma_control_result result);
  task destroy_locked(rdma_function_binding binding,
                      rdma_function_handle expected_owner,
                      rdma_destroy_resource_req request,
                      rdma_resource_kind_e expected_kind,
                      longint unsigned transaction_id,
                      output rdma_control_result result);
  task recover_locked(rdma_function_binding binding,
                      rdma_function_handle expected_owner,
                      rdma_handle resource_h,
                      longint unsigned transaction_id,
                      output rdma_control_result result);
endclass

class rdma_control_plane extends uvm_object;
  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_cmq_port cmq_port,
    rdma_stag_key_policy key_policy,
    rdma_host_mem_api host_mem = null,
    rdma_hmc_allocator hmc_allocator = null,
    rdma_context_backing_api context_backing = null,
    time command_timeout = 1us
  );
  task create_cq(rdma_function_binding binding, rdma_create_cq_req request,
                 output rdma_cq cq, output rdma_control_result result);
  task destroy_cq(rdma_function_binding binding,
                  rdma_destroy_resource_req request,
                  output rdma_control_result result);
  task create_srq(rdma_function_binding binding, rdma_create_srq_req request,
                  output rdma_srq srq, output rdma_control_result result);
  task destroy_srq(rdma_function_binding binding,
                   rdma_destroy_resource_req request,
                   output rdma_control_result result);
  task create_ceq(rdma_function_binding binding, rdma_create_ceq_req request,
                  output rdma_ceq ceq, output rdma_control_result result);
  task destroy_ceq(rdma_function_binding binding,
                   rdma_destroy_resource_req request,
                   output rdma_control_result result);
  task create_aeq(rdma_function_binding binding, rdma_create_aeq_req request,
                  output rdma_aeq aeq, output rdma_control_result result);
  task destroy_aeq(rdma_function_binding binding,
                   rdma_destroy_resource_req request,
                   output rdma_control_result result);
endclass
```

`rdma_queue_lifecycle_executor` 不创建 semaphore、不分配 transaction ID。它接收 facade 在锁内冻结的 `expected_owner`，在每次 CMQ terminal completion 后和 registry commit 前比较 live binding 的 Function UID/global ID/generation；facade 始终负责取得和释放 Task 14A 的同一把锁。

### Task 1: 固定 Queue DMA、Capability 和 Interrupt Snapshot

**Files:**
- Modify: `src/model/rdma_function_binding.svh`
- Modify: `src/model/rdma_dma_request_context.svh`
- Modify: `src/model/rdma_dma_mapping.svh`
- Modify: `src/core/rdma_resource_manager.svh`
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `src/core/rdma_doorbell_scheduler.svh`
- Modify: `src/core/rdma_cmq_engine.svh`
- Modify: `tests/mocks/rdma_mock_adapters.svh`
- Modify: `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv`
- Modify: `tests/unit/rdma_adapter_contract_test.svh`
- Modify: `tests/unit/rdma_cmq_engine_test.svh`
- Modify: `tests/unit/rdma_control_plane_cmq_engine_test.svh`
- Modify: `tests/unit/rdma_control_plane_test.svh`
- Modify: `tests/unit/rdma_doorbell_scheduler_test.svh`
- Modify: `tests/unit/rdma_model_test.svh`
- Modify: `tests/unit/rdma_resource_manager_test.svh`
- Modify: `tests/integration/rdma_host_mem_adapter_test.svh`

- [ ] **Step 1: 写 domain/PASID/vector snapshot 的失败测试**

在 `rdma_adapter_contract_test` 增加：

```systemverilog
binding.queue_dma.requester_bdf = binding.pcie.bdf;
binding.queue_dma.pasid_valid = 1'b1;
binding.queue_dma.pasid = 20'h34567;
binding.queue_dma.dma_domain_valid = 1'b1;
binding.queue_dma.dma_domain_id = 32'h1122_3344;
binding.queue_caps.min_cq_depth = 16;
binding.queue_caps.max_cq_depth = 32768;
binding.queue_caps.min_srq_depth = 16;
binding.queue_caps.max_srq_depth = 32768;
binding.queue_caps.max_ceq_depth = 4096;
binding.queue_caps.max_aeq_depth = 4096;
binding.queue_caps.max_wq_sge = 8;
binding.queue_caps.max_queue_ring_bytes = 32'h0020_0000;
binding.queue_caps.max_sgb_bytes = 32'h0040_0000;
vector.function_local_vector = 3;
vector.hardware_eq_vector = 17;
vector.msix_table_index = 5;
vector.enabled = 1'b1;
binding.interrupt_vectors.push_back(vector);
expect_status("QUEUE_BINDING", binding.validate(), RDMA_SC_OK);

mapping.dma_domain_valid = 1'b1;
mapping.dma_domain_id = 32'h1122_3344;
expect_status("DOMAIN_MATCH", mapping.check_access(
  binding.make_handle(), binding.queue_dma.requester_bdf,
  binding.queue_dma.pasid_valid, binding.queue_dma.pasid,
  binding.queue_dma.dma_domain_valid, binding.queue_dma.dma_domain_id,
  mapping.iova, 4096, RDMA_DMA_DEVICE_READ, read_permission), RDMA_SC_OK);
expect_status("DOMAIN_MISMATCH", mapping.check_access(
  binding.make_handle(), binding.queue_dma.requester_bdf,
  1'b1, 20'h34567, 1'b1, 32'h1122_3345,
  mapping.iova, 4096, RDMA_DMA_DEVICE_READ, read_permission),
  RDMA_SC_DMA_TRANSLATION);
```

同时把 host_mem integration 的 binding/context/mapping 断言改为 `queue_dma` 和 domain 字段，证明 allocate 返回值逐字段继承 request context。

- [ ] **Step 2: 确认新 snapshot 类型和新签名尚不存在**

Run:

```bash
scripts/run_vcs53.sh core rdma_adapter_contract_test
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected: core 编译 FAIL 于 `queue_dma` 或新 `check_access()` 参数；host_mem 编译 FAIL 于缺失 domain 字段。

- [ ] **Step 3: 定义并深拷贝 Function snapshots**

在 `rdma_function_binding.svh` 的 binding 之前增加：

```systemverilog
class rdma_queue_dma_context extends uvm_object;
  `uvm_object_utils(rdma_queue_dma_context)
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
endclass

class rdma_queue_capabilities extends uvm_object;
  `uvm_object_utils(rdma_queue_capabilities)
  int unsigned min_cq_depth, max_cq_depth;
  int unsigned min_srq_depth, max_srq_depth;
  int unsigned max_ceq_depth, max_aeq_depth;
  int unsigned max_wq_sge;
  longint unsigned max_queue_ring_bytes, max_sgb_bytes;
endclass

class rdma_interrupt_vector_binding extends uvm_object;
  `uvm_object_utils(rdma_interrupt_vector_binding)
  int unsigned function_local_vector;
  int unsigned hardware_eq_vector;
  int unsigned msix_table_index;
  bit enabled;
endclass
```

为三个类实现 constructor、`do_copy()` 和 `validate()`：invalid PASID 必须为 0；有效 domain 的 ID 可为 0；depth capability 必须非零、min 不大于 max；ring/SGB capability 上限必须非零；vector local ID 必须唯一。policy 后续对 ring 使用 `min(queue_caps.max_queue_ring_bytes, 2 MiB)`，不能因硬件能力大于本任务上限而判 binding 非法。`rdma_function_binding` 用以下字段替换旧的 `dma_domain_id/dma_domain_valid`：

```systemverilog
rdma_queue_dma_context queue_dma;
rdma_queue_capabilities queue_caps;
rdma_interrupt_vector_binding interrupt_vectors[$];
```

binding validation 还要求 `queue_dma.requester_bdf == pcie.bdf`、`rdma_vf_id <= 8'hff`，并深拷贝 vector queue。同步更新本任务 Files 中全部 active-binding fixture，使 queue DMA、capability 和 vector snapshot 均显式初始化，不用构造器隐含值掩盖旧测试。

- [ ] **Step 4: 传播 domain 并收紧 mapping access contract**

在 request context 和 mapping 中增加：

```systemverilog
bit dma_domain_valid;
int unsigned dma_domain_id;
```

把 `rdma_dma_mapping.check_access()` 改为最终签名：

```systemverilog
function rdma_status check_access(
  rdma_function_handle requested_function,
  rdma_bdf_t requested_requester_bdf,
  bit requested_pasid_valid,
  bit [19:0] requested_pasid,
  bit requested_dma_domain_valid,
  int unsigned requested_dma_domain_id,
  rdma_iova_t first_iova,
  longint unsigned length,
  rdma_dma_direction_e requested_direction,
  rdma_dma_permission_t requested_permissions
);
```

在范围检查前比较 PASID valid/value 和 domain valid/value，不一致返回 `RDMA_SC_DMA_TRANSLATION`。更新 resource-manager projection/equality、control-plane MR call sites、CMQ engine request-context/mapping authority、doorbell scheduler access check、mock clone/allocate 和生产 host_mem mapping authority snapshot，使 domain 不会在 clone、allocate、registry 或 recovery 中丢失。

- [ ] **Step 5: 运行兼容测试并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_adapter_contract_test
scripts/run_vcs53.sh core rdma_control_plane_test
scripts/run_vcs53.sh core rdma_resource_manager_test
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected: 四个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`，domain mismatch 断言返回 `RDMA_SC_DMA_TRANSLATION`。

Commit:

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
git commit -m "feat: define queue DMA and interrupt snapshots"
```

### Task 2: 定义 Queue Backing、Context、Flush 和 Preflight Value Objects

**Files:**
- Create: `src/model/rdma_queue_lifecycle_models.svh`
- Modify: `src/model/rdma_model_pkg.sv`
- Create: `tests/unit/rdma_queue_lifecycle_models_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 role、slice、plan、context ref 的失败测试**

新测试必须覆盖：13 个稳定 role、owned spec 不允许 slice、borrowed spec 只允许六个 payload role、deep clone 不别名、ring layout 4 KiB/512-page 限制、flush phase、context view bounds、IOVA 到 queue base checked projection。

```systemverilog
slice.role = RDMA_QUEUE_ROLE_CQ_RING;
slice.mapping = mapping;
slice.mapping_offset = 0;
slice.length = 8192;
slice.logical_queue_offset = 0;
spec.mode = RDMA_QUEUE_BACKING_BORROWED;
spec.slices.push_back(slice);
expect_status("BORROWED_SPEC", spec.validate(), RDMA_SC_OK);

layout.role = RDMA_QUEUE_ROLE_CQ_RING;
layout.entry_size_bytes = 64;
layout.depth = 128;
layout.logical_bytes = 8192;
layout.storage_bytes = 8192;
layout.page_count = 2;
layout.initial_polarity = 1'b1;
expect_status("RING_LAYOUT", layout.validate(), RDMA_SC_OK);

iova.value = 64'h0000_1234_5678_9000;
expect_status("IOVA_PROJECTION", rdma_queue_base_from_iova(iova, base),
              RDMA_SC_OK);
if (base.value != iova.value)
  `uvm_error("IOVA_PROJECTION", "queue base changed IOVA bits")
```

- [ ] **Step 2: 确认新模型尚未发布**

Run: `scripts/run_vcs53.sh core rdma_queue_lifecycle_models_test`

Expected: 编译 FAIL，首个缺失符号为 `rdma_queue_backing_spec`。

- [ ] **Step 3: 定义稳定 enum、slice、ring 和 backing refs**

在新文件中按“enum → leaf object → aggregate object”顺序定义顶部固定接口中的三个 enum，以及：

```systemverilog
class rdma_queue_backing_slice extends uvm_object;
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  longint unsigned mapping_offset, length, logical_queue_offset;
endclass

class rdma_queue_backing_spec extends uvm_object;
  rdma_queue_backing_mode_e mode;
  rdma_queue_backing_slice slices[$];
endclass

class rdma_queue_dma_page_ref extends uvm_object;
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  longint unsigned mapping_offset, logical_page_offset;
  rdma_iova_t page_iova;
endclass

class rdma_queue_ring_layout extends uvm_object;
  rdma_queue_backing_role_e role;
  int unsigned entry_size_bytes, depth;
  longint unsigned logical_bytes, storage_bytes;
  int unsigned page_count;
  bit initial_polarity;
  rdma_queue_dma_page_ref pages[$];
endclass

class rdma_queue_backing_ref extends uvm_object;
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  longint unsigned mapping_offset, length, logical_queue_offset;
  bit cleanup_complete;
endclass
```

每个 class 实现 constructor、deep `do_copy()` 和 `validate()`。所有 offset+length 使用 `offset > max-length` 形式检查溢出；page IOVA、ring slice 和 PD 为 4 KiB 对齐；SGB slice 为 512-byte 对齐。

- [ ] **Step 4: 定义 context、flush、plan 和 preflight aggregates**

```systemverilog
class rdma_context_backing_ref extends uvm_object;
  rdma_function_handle owner;
  rdma_resource_kind_e resource_kind;
  int unsigned local_id;
  uvm_object slot_token;
  rdma_hmc_ref hmc_ref;
  rdma_backing_addr_t shadow_pointer_base;
  longint unsigned slot_length, shadow_view_offset, shadow_view_length;
  bit release_complete;
endclass

class rdma_queue_flush_target extends uvm_object;
  rdma_queue_backing_role_e role;
  rdma_queue_flush_phase_e phase;
  rdma_queue_backing_ref pd_ref;
  bit flush_complete;
endclass

class rdma_queue_backing_plan extends uvm_object;
  rdma_resource_kind_e resource_kind;
  rdma_queue_ring_layout rings[$];
  rdma_queue_backing_ref refs[$];
  rdma_context_backing_ref context_ref;
  rdma_queue_flush_target flush_targets[$];
endclass

class rdma_queue_preflight extends uvm_object;
  rdma_resource_kind_e resource_kind;
  int unsigned depth, cqe_size_bytes, max_sge, limit_threshold;
  int unsigned local_vector, hardware_vector, msix_table_index;
  rdma_queue_backing_spec backing_spec;
  rdma_queue_ring_layout required_rings[$];
endclass
```

增加 `rdma_queue_base_from_iova()`，仅复制 `rdma_iova_t.value` 到 `rdma_backing_addr_t.value`，要求 4 KiB 对齐。`rdma_context_backing_ref.do_copy()` clone opaque token/HMC ref，但 token 的 adapter identity 必须保持共享 completion；clone 失败或返回 source alias 时 fail closed。plan validator 固定 CQ/SRQ/CEQ/AEQ 的合法 role 集合和 flush target 顺序，禁止 metadata role 出现在公共 spec。

把新文件 include 到 `rdma_model_pkg.sv` 的 `rdma_resource_refs.svh` 之后、`rdma_semantic_requests.svh` 之前；把新测试 include 到 unit package。

- [ ] **Step 5: 运行模型测试并提交**

Run: `scripts/run_vcs53.sh core rdma_queue_lifecycle_models_test`

Expected: `0 UVM_ERROR / 0 UVM_FATAL`，所有 clone identity 断言通过。

Commit:

```bash
git add src/model/rdma_queue_lifecycle_models.svh \
  src/model/rdma_model_pkg.sv \
  tests/unit/rdma_queue_lifecycle_models_test.svh \
  tests/rdma_unit_test_pkg.sv
git commit -m "feat: define queue lifecycle value objects"
```

### Task 3: 扩展 Typed Create Requests 与 Queue Resource Snapshot

**Files:**
- Modify: `src/model/rdma_semantic_requests.svh`
- Modify: `src/model/rdma_resources.svh`
- Modify: `src/core/rdma_resource_manager.svh`
- Modify: `tests/unit/rdma_request_model_test.svh`
- Modify: `tests/unit/rdma_queue_lifecycle_models_test.svh`
- Modify: `tests/unit/rdma_resource_manager_test.svh`

- [ ] **Step 1: 写请求默认值、非法输入和 snapshot 失败测试**

```systemverilog
cq_req.depth = 128;
cq_req.cqe_size_bytes = 64;
cq_req.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
expect_status("CQ_REQ", cq_req.validate(), RDMA_SC_OK);
cq_req.cqe_size_bytes = 48;
expect_status("CQ_CQE_SIZE", cq_req.validate(), RDMA_SC_INVALID_ARGUMENT);

srq_req.depth = 128;
srq_req.max_sge = 4;
srq_req.limit_threshold = 16;
srq_req.payload_backing.mode = RDMA_QUEUE_BACKING_OWNED;
expect_status("SRQ_REQ", srq_req.validate(), RDMA_SC_OK);
srq_req.limit_threshold = 18;
expect_status("SRQ_LIMIT", srq_req.validate(), RDMA_SC_INVALID_ARGUMENT);

ceq_req.vector_id = 3;
aeq_req.vector_id = 3;
expect_status("CEQ_REQ", ceq_req.validate(), RDMA_SC_OK);
expect_status("AEQ_REQ", aeq_req.validate(), RDMA_SC_OK);
```

resource-manager 测试把合法 plan stage 到 ALLOCATED CQ，再 lookup 并修改 caller 原对象，断言 registry 中的 `queue_plan` 没有变化。

- [ ] **Step 2: 确认扩展字段和 plan snapshot 尚不存在**

Run:

```bash
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_resource_manager_test
```

Expected: 编译 FAIL 于 `cqe_size_bytes`、`limit_threshold`、`vector_id` 或 `queue_plan`。

- [ ] **Step 3: 扩展四类 create request**

最终字段固定为：

```systemverilog
class rdma_create_cq_req extends rdma_semantic_request;
  int unsigned depth;
  int unsigned cqe_size_bytes;       // constructor default 64
  rdma_handle ceq_h;
  rdma_queue_backing_spec ring_backing;
endclass

class rdma_create_srq_req extends rdma_semantic_request;
  int unsigned depth, max_sge;
  int unsigned limit_threshold;      // constructor default 16
  rdma_handle pd_h;
  rdma_queue_backing_spec payload_backing;
endclass

class rdma_create_ceq_req extends rdma_semantic_request;
  int unsigned depth, vector_id;
  rdma_queue_backing_spec ring_backing;
endclass

class rdma_create_aeq_req extends rdma_semantic_request;
  int unsigned depth, vector_id;
  rdma_queue_backing_spec ring_backing;
endclass
```

请求自身只做结构校验：depth power-of-two；CQE size 属于 32/64/128；SRQ limit 在 16..depth 且 4 对齐；backing spec 非空且自身有效。capability、role 完整性、dependency 和 vector lookup 留给 policy preflight。

- [ ] **Step 4: 保存权威 queue plan 与 type-specific metadata**

在 `rdma_queue_resource` 增加 `rdma_queue_backing_plan queue_plan`。ALLOCATED reservation 允许 depth=0/plan=null；`stage_allocated()` 的 candidate 以及 PROGRAMMED/ACTIVE/QUIESCING/ERROR queue 必须具有完整有效 plan。queue authority 只保存在 `queue_plan`，继承自 `rdma_resource` 的 MR-compatible `backing_refs/hmc_refs` 对 queue 保持空，避免两份权威。派生资源增加：

```systemverilog
// rdma_cq
int unsigned cqe_size_bytes;

// rdma_srq
int unsigned limit_threshold;

// rdma_ceq / rdma_aeq
int unsigned function_local_vector;
int unsigned hardware_vector;
int unsigned msix_table_index;
```

constructor、copy、validate 必须深拷贝 plan。resource manager 的 built-in structural projection 逐层 new/copy queue plan、mapping 和 context ref；owned mapping 仍通过 `snapshot_release_authority()` 保留 opaque authority，borrowed mapping 只做不可释放投影。

- [ ] **Step 5: 运行模型/registry 测试并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_queue_lifecycle_models_test
scripts/run_vcs53.sh core rdma_resource_manager_test
```

Expected: 三个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`。

Commit:

```bash
git add src/model/rdma_semantic_requests.svh src/model/rdma_resources.svh \
  src/core/rdma_resource_manager.svh \
  tests/unit/rdma_request_model_test.svh \
  tests/unit/rdma_queue_lifecycle_models_test.svh \
  tests/unit/rdma_resource_manager_test.svh
git commit -m "feat: add typed queue lifecycle requests"
```

### Task 4: 增加 Context Backing API 与 Exactly-Once Mock

**Files:**
- Create: `src/adapter/rdma_context_backing_api.svh`
- Modify: `src/adapter/rdma_adapter_pkg.sv`
- Create: `tests/mocks/rdma_mock_context_backing.svh`
- Create: `tests/unit/rdma_context_backing_contract_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 acquire/write/bounds/release contract 失败测试**

```systemverilog
expect_status("CQC_ACQUIRE",
  context_api.acquire(binding, RDMA_RESOURCE_CQ, 21, ref), RDMA_SC_OK);
if (ref.slot_length != 64 || ref.shadow_view_offset != 48 ||
    ref.shadow_view_length != 8 || (ref.shadow_pointer_base.value & 63) != 0)
  `uvm_error("CQC_REF", "CQC slot/view geometry is incorrect")

bytes = new[8];
expect_status("CQC_SHADOW_WRITE", context_api.write(ref, 48, bytes),
              RDMA_SC_OK);
bytes = new[9];
expect_status("CQC_BOUNDS", context_api.write(ref, 48, bytes),
              RDMA_SC_DMA_TRANSLATION);

expect_status("CQC_RELEASE", context_api.\release (ref), RDMA_SC_OK);
expect_status("CQC_QUERY", context_api.query_release_completion(ref, complete),
              RDMA_SC_OK);
if (!complete || context_api.release_call_count != 1)
  `uvm_error("CQC_RELEASE", "release completion is not exactly-once")
```

SRQ case 断言 pointer base 4 KiB 对齐、slot 至少 32 byte、shadow view 为 offset 28/length 4；相邻 slot byte 在 write 后保持原值。

- [ ] **Step 2: 确认 adapter 和 mock 尚不存在**

Run: `scripts/run_vcs53.sh core rdma_context_backing_contract_test`

Expected: 编译 FAIL 于 `rdma_context_backing_api`。

- [ ] **Step 3: 发布窄 context API**

创建顶部固定接口，并 include 到 `rdma_adapter_pkg.sv` 的 host_mem API 之后。接口只接受强类型 ref；不接受 HMC FVM address、host backing address 或裸 slot address。

- [ ] **Step 4: 实现带 authority 的 mock**

mock 为每次 acquire 创建 opaque `rdma_mock_context_slot_token` 和共享 completion object，维护 slot byte array、call trace、per-method failure queue、release count。合法 geometry 固定为：

```systemverilog
RDMA_RESOURCE_CQ:  slot_length=64, shadow_view_offset=48,
                   shadow_view_length=8, pointer_alignment=64;
RDMA_RESOURCE_SRQ: slot_length=32, shadow_view_offset=28,
                   shadow_view_length=4, pointer_alignment=4096;
```

`write()` 先验证 ref owner/kind/local ID/token 和 `offset+size <= slot_length`，再原子更新该 slot 内 bytes；shadow view 必须完全位于 slot 内，但 API 同时允许 executor 写完整 slot。任何 write 都不能越过当前 slot 覆盖相邻 slot。`\release ` 成功后标记共享 completion；第二次盲目 release 返回 `RDMA_SC_INVALID_STATE`。`query_release_completion()` 只读共享 completion，使 clone 的 ref 能证明第一次 release 已完成。

- [ ] **Step 5: 运行 contract 测试并提交**

Run: `scripts/run_vcs53.sh core rdma_context_backing_contract_test`

Expected: `0 UVM_ERROR / 0 UVM_FATAL`，CQ/SRQ geometry、bounds 和 exactly-once 断言通过。

Commit:

```bash
git add src/adapter/rdma_context_backing_api.svh \
  src/adapter/rdma_adapter_pkg.sv \
  tests/mocks/rdma_mock_context_backing.svh \
  tests/unit/rdma_context_backing_contract_test.svh \
  tests/rdma_unit_test_pkg.sv
git commit -m "feat: add queue context backing contract"
```

### Task 5: 实现 xtr_v1 4 KiB Queue Page Directory Codec

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_queue_page_codec.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_queue_page_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写单 entry golden、完整 table 和非法输入测试**

```systemverilog
entry.page_iova.value = 64'h1234_5678_9abc_d000;
entry.rdma_vf_id = 8'h5a;
entry.valid = 1'b1;
expect_status("PD_ENTRY", codec.encode_entry(entry, bytes), RDMA_SC_OK);
expected = '{8'h12, 8'h34, 8'h56, 8'h78,
             8'h9a, 8'hbc, 8'hd5, 8'ha1};
if (bytes != expected)
  `uvm_error("PD_ENTRY", "PD entry is not 12 34 56 78 9a bc d5 a1")

pages.push_back(make_page(64'h0000_0001_0000_0000));
pages.push_back(make_page(64'h0000_0001_0000_1000));
expect_status("PD_TABLE", codec.encode_table(pages, 8'h05, table),
              RDMA_SC_OK);
if (table.size() != 4096 || table[16] != 0 || table[4095] != 0)
  `uvm_error("PD_TABLE", "unused PD entries are not zero")
```

再覆盖 unaligned IOVA、VF ID 超 8 bit、0 page、513 pages、重复/非单调 logical page offset，均返回 `RDMA_SC_INVALID_ARGUMENT` 且不改写 caller 的 output array。

- [ ] **Step 2: 确认 codec 尚未定义**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_queue_page_codec_test`

Expected: 编译 FAIL 于 `rdma_xtr_v1_queue_pd_codec`。

- [ ] **Step 3: 定义 typed entry 和 big-endian encoder**

```systemverilog
class rdma_xtr_v1_queue_pd_entry extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_pd_entry)
  rdma_iova_t page_iova;
  int unsigned rdma_vf_id;
  bit valid;
endclass

class rdma_xtr_v1_queue_pd_codec extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_pd_codec)
  function rdma_status encode_entry(
    rdma_xtr_v1_queue_pd_entry entry,
    inout byte unsigned bytes[]
  );
  function rdma_status encode_table(
    rdma_queue_dma_page_ref pages[$],
    int unsigned rdma_vf_id,
    inout byte unsigned bytes[]
  );
endclass
```

entry word 使用：

```systemverilog
word = (entry.page_iova.value & 64'hffff_ffff_ffff_f000) |
       ((longint'(entry.rdma_vf_id) & 64'hff) << 4) |
       longint'(entry.valid);
for (int unsigned i = 0; i < 8; i++)
  encoded[i] = word[63 - i*8 -: 8];
```

- [ ] **Step 4: 实现 512-entry table 的 fail-atomic encode**

先校验全部 page ref，再创建 `new[4096]` 的零数组；按 `logical_page_offset/4096` 写前 `page_count` 个 entry，要求逻辑 index 从 0 连续且 IOVA 4 KiB 对齐。只有全部成功后把 temporary array 赋给 output。

将 codec include 到 `rdma_xtr_v1_qword_codec.svh` 之后、context body codecs 之前。

- [ ] **Step 5: 运行 golden test 和 frozen codec 回归并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_queue_page_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_context_body_codec_test
```

Expected: 两个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`；golden bytes 精确匹配。

Commit:

```bash
git add src/codec/xtr_v1/rdma_xtr_v1_queue_page_codec.svh \
  src/codec/rdma_codec_pkg.sv \
  tests/unit/rdma_xtr_v1_queue_page_codec_test.svh \
  tests/rdma_unit_test_pkg.sv
git commit -m "feat: encode xtr v1 queue page directories"
```

### Task 6: 扩展 Resource Manager 的 Queue ID、Plan 与 Recovery Schema

**Files:**
- Modify: `src/model/rdma_control_plane_models.svh`
- Modify: `src/core/rdma_resource_manager.svh`
- Modify: `tests/unit/rdma_control_plane_models_test.svh`
- Modify: `tests/unit/rdma_resource_manager_test.svh`

- [ ] **Step 1: 写 ID width、queue recovery 和窄更新失败测试**

通过 resource-manager test subclass 暴露只用于测试的 `seed_next_local_id(kind, value)`，验证 CQ 21 bit、SRQ 16 bit、CEQ/AEQ 12 bit 的最后合法值可分配，再大一位返回 `RDMA_SC_RESOURCE_EXHAUSTED` 且 registry/ID pool 不变。

```systemverilog
recovery.queue_recovery_valid = 1'b1;
recovery.queue_intent = RDMA_QUEUE_RECOVER_NORMAL_DESTROY;
recovery.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_OCC_FLUSH;
recovery.ambiguous_role = RDMA_QUEUE_ROLE_SRFQ_PD;
recovery.queue_plan = srq.queue_plan;
expect_status("QUEUE_RECOVERY", recovery.validate(), RDMA_SC_OK);

expect_status("FLUSH_PROGRESS", manager.record_queue_flush_complete(
  srq.handle, RDMA_QUEUE_ROLE_SRFQ_PD), RDMA_SC_OK);
expect_status("CLEANUP_PROGRESS", manager.record_queue_cleanup_complete(
  srq.handle, RDMA_QUEUE_ROLE_SRQ_SGB), RDMA_SC_OK);
expect_status("CONTEXT_PROGRESS",
  manager.record_queue_context_cleanup_complete(srq.handle), RDMA_SC_OK);
```

还要验证 MR recovery record 在 `queue_recovery_valid=0` 时保持原有 schema 和行为。

- [ ] **Step 2: 确认 queue schema 和更新 API 尚不存在**

Run:

```bash
scripts/run_vcs53.sh core rdma_control_plane_models_test
scripts/run_vcs53.sh core rdma_resource_manager_test
```

Expected: 编译 FAIL 于 `queue_recovery_valid` 或 `record_queue_flush_complete`。

- [ ] **Step 3: 固定 queue local-ID 上限和 recovery fields**

`local_id_limit()` 增加：

```systemverilog
RDMA_RESOURCE_CQ:  return 21'h1f_ffff;
RDMA_RESOURCE_SRQ: return 16'hffff;
RDMA_RESOURCE_CEQ,
RDMA_RESOURCE_AEQ: return 12'hfff;
```

`rdma_control_step_e` 追加且不重排已有值：

```systemverilog
RDMA_CTRL_STEP_HW_CONTEXT_CREATED,
RDMA_CTRL_STEP_HW_CONTEXT_DELETED
```

同步把两个值加入 `rdma_control_step_valid()` 和 `rdma_control_step_is_hardware()`；旧 MR step 编码和值保持不变。

`rdma_recovery_record` 增加：

```systemverilog
bit queue_recovery_valid;
rdma_queue_recovery_intent_e queue_intent;
rdma_queue_ambiguous_operation_e ambiguous_queue_operation;
rdma_queue_backing_role_e ambiguous_role;
rdma_cmq_opcode_key queue_create_opcode;
rdma_cmq_opcode_key queue_delete_opcode;
rdma_cmq_opcode_key queue_query_opcode;
rdma_queue_backing_plan queue_plan;
```

MR path 要求 `queue_recovery_valid==0`；queue path 要求 kind 为 CQ/SRQ/CEQ/AEQ、plan kind 匹配、ambiguous OCC 必须携带合法 PD role/ticket。do_copy 深拷贝 opcode key 和 plan。

- [ ] **Step 4: 增加原子 progress update 与 queue restore**

实现：

```systemverilog
virtual function rdma_status record_queue_flush_complete(
  rdma_handle handle, rdma_queue_backing_role_e role);
virtual function rdma_status record_queue_cleanup_complete(
  rdma_handle handle, rdma_queue_backing_role_e role);
virtual function rdma_status record_queue_context_cleanup_complete(
  rdma_handle handle);
```

每个函数 clone recovery record 和 authoritative resource，验证 role 唯一、顺序前驱已完成，再同时更新 registry/recovery，最后一次性替换内部 entry。函数同时支持 QUIESCING resource（先更新 resource plan，发生后续错误时复制到 recovery）和 ERROR resource（原子更新 resource/recovery 两份 clone）。`restore_active()` 对 queue 只允许 PRESENT、无 ambiguous ticket、无 destructive local cleanup；SRQ 在同一 replacement 中清除两个 flush target 的 `flush_complete`、`ambiguous_role` 和本次 ticket，再转 ACTIVE。MR restore 分支保持原实现。

- [ ] **Step 5: 运行 manager 回归并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_control_plane_models_test
scripts/run_vcs53.sh core rdma_resource_manager_test
scripts/run_vcs53.sh core rdma_control_plane_test
```

Expected: 三个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`；MR recovery 回归不变。

Commit:

```bash
git add src/model/rdma_control_plane_models.svh \
  src/core/rdma_resource_manager.svh \
  tests/unit/rdma_control_plane_models_test.svh \
  tests/unit/rdma_resource_manager_test.svh
git commit -m "feat: persist queue lifecycle recovery progress"
```

### Task 7: 实现 CQ/SRQ/CEQ/AEQ Typed Policy Builders

**Files:**
- Create: `src/core/rdma_queue_lifecycle_policy.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_queue_lifecycle_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 preflight、context 初值、vector 和命令 descriptor 失败测试**

新测试直接实例化四个 policy，覆盖 capability 边界、CQE 32/64/128、SRQ max_sge/limit、cross-Function dependency、disabled vector、ring 超 2 MiB 和四类 opcode。

```systemverilog
expect_status("CQ_PREFLIGHT", cq_policy.preflight(
  binding, cq_req, manager, preflight), RDMA_SC_OK);
if (preflight.required_rings[0].entry_size_bytes != 64 ||
    preflight.required_rings[0].initial_polarity != 1'b1)
  `uvm_error("CQ_PREFLIGHT", "CQ layout is incorrect")

expect_status("SRQ_PREFLIGHT", srq_policy.preflight(
  binding, srq_req, manager, preflight), RDMA_SC_OK);
if (preflight.required_rings.size() != 3 ||
    preflight.required_rings[0].entry_size_bytes != 64 ||
    preflight.required_rings[2].entry_size_bytes != 512)
  `uvm_error("SRQ_PREFLIGHT", "SRQ/SRFQ/SGB layout is incorrect")

expect_status("CEQ_VECTOR", ceq_policy.preflight(
  binding, ceq_req, manager, preflight), RDMA_SC_OK);
if (preflight.hardware_vector != 17 || preflight.msix_table_index != 5)
  `uvm_error("CEQ_VECTOR", "local vector was not resolved")
```

model 断言固定 CQC threshold=2、load_ci_done=1、last_arm_sequence=1、当前 arm=0；SRQC load_pi_threshold=8、limit encoding=`limit_threshold/4`；CEQC/AEQC PI/CI/wrap=0。

- [ ] **Step 2: 确认 policy classes 尚不存在**

Run: `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`

Expected: 编译 FAIL 于 `rdma_cq_lifecycle_policy`。

- [ ] **Step 3: 定义窄 policy base 和四个具体 policy**

```systemverilog
virtual class rdma_queue_lifecycle_policy extends uvm_object;
  pure virtual function rdma_resource_kind_e resource_kind();
  pure virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
  pure virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
  pure virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
  pure virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
  pure virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
endclass
```

实现 `rdma_cq_lifecycle_policy`、`rdma_srq_lifecycle_policy`、`rdma_ceq_lifecycle_policy`、`rdma_aeq_lifecycle_policy`，只 down-cast 对应 typed request/resource。preflight 在 reservation 前验证 borrowed role completeness、capability、dependency、vector 和 checked size；EQ `hardware_eq_vector` 必须不大于 `16'hffff`，SRQ encoded limit 必须不大于 `14'h3fff`。

- [ ] **Step 4: 构造 canonical context/image/commands**

使用现有 `rdma_cqc_model`、`rdma_srqc_model`、`rdma_ceqc_model`、`rdma_aeqc_model` 和 codec registry。CQC slot image 为 canonical 64-byte CQC image，shadow bytes offset 48 为 8 个零字节；SRFQC shadow 为：

```systemverilog
shadow = new[4];
shadow[0] = 8'h00;
shadow[1] = 8'h00;
shadow[2] = byte'(((limit_threshold / 4) << 2) >> 8);
shadow[3] = byte'((limit_threshold / 4) << 2);
```

默认 limit 16 的结果必须是 `00 00 00 10`。create/delete/query opcode 分别固定为 CQC `0c/0e/0f`、SRFQC `35/37/38`、CEQC `10/12/13`、AEQC `14/16/17`。OCC body 固定 `pd=1, qpn=0, pd_backing=target.pd_ref.mapping.iova + mapping_offset`，其余 pattern 位为 0。

把 policy include 到 `rdma_resource_manager.svh` 之后、executor 之前。

- [ ] **Step 5: 运行 policy test 和 context codec 回归并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_queue_lifecycle_test
scripts/run_vcs53.sh core rdma_xtr_v1_context_body_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_codec_test
```

Expected: 三个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`；policy test 尚不发送 CMQ，只验证 typed outputs。

Commit:

```bash
git add src/core/rdma_queue_lifecycle_policy.svh src/core/rdma_core_pkg.sv \
  tests/unit/rdma_queue_lifecycle_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: build typed queue lifecycle policies"
```

### Task 8: 实现 Owned/Borrowed Queue Backing Planner

**Files:**
- Create: `src/core/rdma_queue_backing_planner.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Modify: `tests/unit/rdma_queue_lifecycle_test.svh`

- [ ] **Step 1: 写 layout、IOVA/backing 分离、重叠和 cleanup 失败测试**

覆盖 owned CQ、borrowed CQ、owned/borrowed SRQ 三 role、CEQ/AEQ；mapping IOVA 固定高于 4 GiB，backing_addr 故意不同：

```systemverilog
mapping.iova.value = 64'h0000_0021_0000_0000;
mapping.backing_addr.value = 64'h0000_0099_0000_0000;
expect_status("BORROWED_PLAN", planner.materialize(
  binding, preflight, resource.handle, plan), RDMA_SC_OK);
if (plan.rings[0].pages[0].page_iova.value !=
      64'h0000_0021_0000_0000)
  `uvm_error("BORROWED_PLAN", "page list did not use mapping IOVA")
if (plan.refs[0].mapping.backing_addr.value ==
      plan.rings[0].pages[0].page_iova.value)
  `uvm_error("BORROWED_PLAN", "fixture failed to separate address spaces")
```

负向矩阵：缺失/多余 role、logical hole、logical overlap、device IOVA overlap、host backing overlap、长度不足、unaligned offset、BDF/PASID/domain/generation/direction mismatch、SGB slot 跨 slice、checked multiplication overflow。

- [ ] **Step 2: 确认 planner 尚不存在**

Run: `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`

Expected: 编译 FAIL 于 `rdma_queue_backing_planner`。

- [ ] **Step 3: 实现 preflight-only borrowed validator**

```systemverilog
class rdma_queue_backing_planner extends uvm_object;
  function rdma_status configure(rdma_host_mem_api host_mem);
  function rdma_status validate_spec(
    rdma_function_binding binding, rdma_queue_preflight preflight);
  function rdma_status materialize(
    rdma_function_binding binding, rdma_queue_preflight preflight,
    rdma_handle resource_h, output rdma_queue_backing_plan plan);
  function rdma_status initialize_payload_and_pd(
    rdma_function_binding binding, rdma_queue_backing_plan plan,
    rdma_xtr_v1_queue_pd_codec pd_codec);
  function rdma_status cleanup_local_role(
    rdma_queue_backing_ref ref, output bit complete);
endclass
```

`validate_spec()` 在 identity reservation 前完成所有 borrowed 静态校验。每个 slice 调用扩展后的 `mapping.check_access()`；CQ/CEQ/AEQ 要求 DEVICE_WRITE，SRQ/SRFQ/SGB 要求 DEVICE_READ。不同 role 同时比较 IOVA range 和 backing range，任一重叠都失败。

- [ ] **Step 4: 实现 materialize、初始化和 role cleanup**

owned allocation request context完全从 `binding.queue_dma` 和新 resource handle 构造；payload 顺序为请求 role 顺序，PD 顺序固定。ring storage 使用 checked align-up；每页构造 `rdma_queue_dma_page_ref.page_iova = mapping.iova + offset`。PD mapping 总是 owned、4096 bytes、4096 alignment、DEVICE_READ。传给 `rdma_host_mem_api.allocate()` 的每个 role size 必须不大于 `32'hffff_ffff`，SGB 同时满足 Function capability 和该 API 宽度。

`initialize_payload_and_pd()` 为每个 payload ref 写满 `length` 个零字节，再用 Task 5 codec 写完整 4096-byte PD。`cleanup_local_role()` 对 borrowed 只返回 complete，不调用 release；owned 先 `release_completion_status()`，已完成则不重复，未完成才调用 `host_mem.\release `。

materialize 任一步失败时按 context 之前的 acquisition 逆序释放已取得的 PD/owned payload；borrowed 不 release。每个 ref 在加入 plan 前立即保存 authority snapshot。

- [ ] **Step 5: 运行 planner 矩阵并提交**

Run: `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`

Expected: `0 UVM_ERROR / 0 UVM_FATAL`；所有非法 borrowed 输入在 CMQ call count 为 0 时失败，owned cleanup count 精确为 1。

Commit:

```bash
git add src/core/rdma_queue_backing_planner.svh src/core/rdma_core_pkg.sv \
  tests/unit/rdma_queue_lifecycle_test.svh
git commit -m "feat: plan queue DMA backing and page directories"
```

### Task 9: 实现通用 Create Executor 与 CQ/CEQ/AEQ Create

**Files:**
- Create: `src/core/rdma_queue_lifecycle_executor.svh`
- Modify: `src/core/rdma_queue_lifecycle_policy.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Modify: `tests/mocks/rdma_mock_control_plane.svh`
- Modify: `tests/unit/rdma_queue_lifecycle_test.svh`

- [ ] **Step 1: 写 CQ/CEQ/AEQ create 顺序和 rollback 失败测试**

给三类资源各写 owned/borrowed create case，并把 host_mem、context 和 CMQ 接到同一个 call trace：

```systemverilog
executor.create_locked(binding, binding.make_handle(), cq_req, 64'd101,
                       queue, result);
if (!result.ok() || !$cast(cq, queue) || cq.state != RDMA_RESOURCE_ACTIVE)
  `uvm_error("CQ_CREATE", "CQ did not become ACTIVE")
expect_trace_prefix('{"host_write:CQ_RING", "host_write:CQ_PD",
                      "context_write:CQC_CONTEXT_SHADOW",
                      "cmq:0c"});
```

CEQ/AEQ 断言 payload→PD→CMQ，且 context call count 为 0。失败注入至少覆盖：payload allocate/write、PD allocate/write、CQC acquire/write、`stage_allocated`、create terminal failure、create timeout、post-CMQ generation change、`commit_programmed`、`activate`。每个 case 断言 ID、dependency、owned release count、borrowed release count 和 final state。

- [ ] **Step 2: 确认 executor 尚不存在**

Run: `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`

Expected: 编译 FAIL 于 `rdma_queue_lifecycle_executor`。

- [ ] **Step 3: 增加 policy reservation 和 executor configuration**

在 policy base 增加并由四类 policy 实现：

```systemverilog
pure virtual function rdma_status reserve_resource(
  rdma_resource_manager manager, rdma_function_binding binding,
  rdma_semantic_request request, output rdma_queue_resource resource);
```

CQ policy 调 `manager.create_cq(binding, cq_req.ceq_h, cq)`；SRQ 调 `create_srq`；CEQ/AEQ 调对应 create。executor 构造并配置：

```systemverilog
function rdma_status configure(
  rdma_resource_manager manager,
  rdma_cmq_port cmq,
  rdma_host_mem_api host_mem,
  rdma_context_backing_api context_backing,
  time command_timeout
);
```

executor 保存四个 policy、planner 和 PD codec；不保存 semaphore 或 transaction counter。

- [ ] **Step 4: 实现 fail-closed create transaction**

`create_locked()` 严格执行：

```text
validate live binding/expected_owner/request
-> policy.preflight + planner.validate_spec
-> policy.reserve_resource
-> verify local ID width
-> planner.materialize
-> CQ: context.acquire
-> manager.stage_allocated(authoritative snapshot)
-> planner.initialize_payload_and_pd
-> CQ: policy images + context.write full slot and shadow view
-> policy.build_create_command + cmq.execute
-> generation comparison
-> manager.commit_programmed
-> manager.activate
-> lookup ACTIVE snapshot
```

每个成功 acquisition 立即加入 transaction-local plan。create CMQ 前失败按 context→PD reverse→owned payload reverse→`release_reserved()`；borrowed payload 只 detach。create terminal failure且 completion contract 明确未创建时同样本地回滚。create success 后的 generation/commit/activate 失败：CQ 执行 delete→CQ_PD flush，CEQ/AEQ 执行 delete，然后本地 cleanup；任一 timeout/结果丢失调用 `mark_error()` 保存 queue recovery intent、ticket、plan 和 presence。

所有 `rdma_status` 返回都经过 null normalization；错误 aggregate 使用 `RDMA_SC_RECOVERY_REQUIRED`，primary error 保留在 `result.primary_status`。

- [ ] **Step 5: 运行 create 和现有 control-plane 回归并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_queue_lifecycle_test
scripts/run_vcs53.sh core rdma_control_plane_test
scripts/run_vcs53.sh core rdma_cmq_port_test
```

Expected: 三个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`；CQ/CEQ/AEQ 正向 create 为 ACTIVE，失败矩阵无泄漏。

Commit:

```bash
git add src/core/rdma_queue_lifecycle_executor.svh \
  src/core/rdma_queue_lifecycle_policy.svh src/core/rdma_core_pkg.sv \
  tests/mocks/rdma_mock_control_plane.svh \
  tests/unit/rdma_queue_lifecycle_test.svh
git commit -m "feat: execute CQ and EQ create transactions"
```

### Task 10: 实现 SRQ Compound Create、双 PD 和 SGB

**Files:**
- Modify: `src/core/rdma_queue_lifecycle_policy.svh`
- Modify: `src/core/rdma_queue_backing_planner.svh`
- Modify: `src/core/rdma_queue_lifecycle_executor.svh`
- Modify: `tests/unit/rdma_queue_lifecycle_test.svh`

- [ ] **Step 1: 写 SRQ role/order/shadow/create rollback 失败测试**

```systemverilog
srq_req.depth = 64;
srq_req.max_sge = 4;
srq_req.limit_threshold = 16;
srq_req.payload_backing.mode = RDMA_QUEUE_BACKING_OWNED;
executor.create_locked(binding, binding.make_handle(), srq_req, 64'd202,
                       queue, result);
if (!result.ok() || !$cast(srq, queue) || srq.state != RDMA_RESOURCE_ACTIVE)
  `uvm_error("SRQ_CREATE", "SRQ did not become ACTIVE")
expect_roles(srq.queue_plan,
  '{RDMA_QUEUE_ROLE_SRQ_RING, RDMA_QUEUE_ROLE_SRFQ_RING,
    RDMA_QUEUE_ROLE_SRQ_SGB, RDMA_QUEUE_ROLE_SRQ_PD,
    RDMA_QUEUE_ROLE_SRFQ_PD, RDMA_QUEUE_ROLE_SRFQC_CONTEXT_SHADOW});
expect_trace_prefix('{"host_write:SRQ_RING", "host_write:SRFQ_RING",
                      "host_write:SRQ_SGB", "host_write:SRQ_PD",
                      "host_write:SRFQ_PD",
                      "context_write:SRFQC_CONTEXT_SHADOW", "cmq:35"});
```

读取 mock context offset 28..31，断言 `00 00 00 10`。`max_sge=2` case 断言没有 SGB；borrowed `max_sge=4` 缺 SGB 或 SGB slot 跨 slice 在 reservation 前失败。

- [ ] **Step 2: 确认 SRQ compound case 仍为红灯**

Run: `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`

Expected: test FAIL，报告 SRQ create 未执行、role 不完整或 shadow bytes 错误。

- [ ] **Step 3: 固定 SRQ preflight 和 materialization**

SRQ policy 生成：SRQ_RING `depth*64`、SRFQ_RING `depth*64`；`max_sge>2` 时 SRQ_SGB `depth*512`。前两者分别有 SRQ_PD/SRFQ_PD；SGB 没有 PD。ring 都 checked align-up 到 4 KiB；SGB 必须小于 `queue_caps.max_sgb_bytes`，每个 512-byte logical slot 完整落在单一连续 slice 中。

planner acquisition 顺序固定为 SRQ_RING→SRFQ_RING→可选 SGB→SRQ_PD→SRFQ_PD；plan flush targets 固定为 SRFQ_PD/PRE_DELETE、SRQ_PD/PRE_DELETE。

- [ ] **Step 4: 构造 SRQC/context 并接入通用 create**

SRQC 固定：BASIC、INDIRECT、depth、load_pi_threshold=8、limit_threshold=`request.limit_threshold/4`、producer index/wrap=0、arm sequence=0、`srfq_backing` 从 SRFQ_PD IOVA checked projection取得、`shadow_backing` 只来自 context API。

context write 只覆盖 adapter 授权范围；先写 canonical slot bytes，再写 offset 28 的 4-byte shadow。SRQ create CMQ 后失败的硬件 rollback 固定为 SRFQ_PD flush→SRQ_PD flush→SRQC delete；任一 ambiguity 保存当前 role 和逐项 flush bit。

- [ ] **Step 5: 运行 SRQ 正反矩阵并提交**

Run: `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`

Expected: `0 UVM_ERROR / 0 UVM_FATAL`；SGB 条件、双 PD、shadow golden 和 rollback 顺序全部通过。

Commit:

```bash
git add src/core/rdma_queue_lifecycle_policy.svh \
  src/core/rdma_queue_backing_planner.svh \
  src/core/rdma_queue_lifecycle_executor.svh \
  tests/unit/rdma_queue_lifecycle_test.svh
git commit -m "feat: create compound SRQ queue backing"
```

### Task 11: 增加 Control-Plane Typed Facade 与共享 Lock/Fence

**Files:**
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `tests/mocks/rdma_mock_control_plane.svh`
- Modify: `tests/unit/rdma_control_plane_test.svh`
- Modify: `tests/unit/rdma_queue_lifecycle_test.svh`

- [ ] **Step 1: 写八个 typed API、kind guard 和 lock 失败测试**

```systemverilog
control_plane.create_cq(binding, cq_req, cq, result);
if (!result.ok() || cq == null || cq.state != RDMA_RESOURCE_ACTIVE)
  `uvm_error("CP_CREATE_CQ", "typed CQ facade failed")

destroy_req.owner = binding.make_handle();
destroy_req.target_h = cq.handle;
control_plane.destroy_ceq(binding, destroy_req, result);
if (result.status.code != RDMA_SC_INVALID_ARGUMENT || cmq.call_count != before)
  `uvm_error("CP_KIND_GUARD", "CEQ API accepted a CQ handle")
```

锁测试令同 Function 的 MR 操作和 CQ create 同时开始，断言 CMQ 区间不交叠；不同 Function 的两个 EQ create 通过 mock barrier 同时进入 execute。等锁时 rebind 的请求返回 `RDMA_SC_STALE_GENERATION` 且不分配 backing。

- [ ] **Step 2: 确认 typed facade 尚不存在**

Run:

```bash
scripts/run_vcs53.sh core rdma_control_plane_test
scripts/run_vcs53.sh core rdma_queue_lifecycle_test
```

Expected: 编译 FAIL 于 `create_cq` 或 `destroy_cq`。

- [ ] **Step 3: 扩展 configure 并构造唯一 executor**

把 `configure()` 改为顶部固定签名；更新本仓库所有调用点，使旧的 positional timeout 显式传到最后一个参数。成功 configure 时创建一个 executor 并调用：

```systemverilog
status = queue_executor.configure(manager, cmq, host_mem,
                                  context_backing, default_timeout);
```

MR-only 使用允许 `context_backing==null`；CQ/SRQ create 在对应 API 中 fail closed。owned 和 borrowed queue 都要求 `host_mem!=null`，因为两者都需要初始化内容。

- [ ] **Step 4: 实现共享 lock/fence typed wrapper**

每个 create/destroy wrapper 使用同一模板：reserve transaction ID→`configured_status()`→binding/request 校验→`acquire_function_lock(owner)`→再次 binding/owner/request 校验→调用 `*_locked()`→释放同一 semaphore。wrapper 不创建第二张 lock table。

create 结果从 generic resource 做严格 cast；cast/kind/state 不匹配转为 `RDMA_SC_INVALID_STATE`。destroy wrapper 在加锁前和加锁后都校验 `target_h.kind == expected_kind`。保持现有 `recover_resource()` 名称，Task 13 再路由 queue recovery。

- [ ] **Step 5: 运行 facade、MR 和并发回归并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_control_plane_test
scripts/run_vcs53.sh core rdma_queue_lifecycle_test
scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
```

Expected: 三个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`；同 Function 串行、不同 Function 并行。

Commit:

```bash
git add src/core/rdma_control_plane.svh \
  tests/mocks/rdma_mock_control_plane.svh \
  tests/unit/rdma_control_plane_test.svh \
  tests/unit/rdma_queue_lifecycle_test.svh
git commit -m "feat: expose typed queue lifecycle facade"
```

### Task 12: 实现 Busy-Safe Destroy 和固定 Hardware/Local 顺序

**Files:**
- Modify: `src/core/rdma_queue_lifecycle_policy.svh`
- Modify: `src/core/rdma_queue_lifecycle_executor.svh`
- Modify: `src/core/rdma_resource_manager.svh`
- Modify: `tests/unit/rdma_queue_lifecycle_test.svh`

- [ ] **Step 1: 写四类 destroy、busy 和 SRQ restore 失败测试**

正向 trace 精确断言：

```systemverilog
expect_trace("CQ_DESTROY",
  '{"cmq:0e", "cmq:0a:CQ_PD", "context_release",
    "host_release:CQ_PD", "detach_or_release:CQ_RING"});
expect_trace("SRQ_DESTROY",
  '{"cmq:0a:SRFQ_PD", "cmq:0a:SRQ_PD", "cmq:37",
    "context_release", "host_release:SRFQ_PD", "host_release:SRQ_PD",
    "detach_or_release:SRQ_SGB", "detach_or_release:SRFQ_RING",
    "detach_or_release:SRQ_RING"});
expect_trace("CEQ_DESTROY",
  '{"cmq:12", "host_release:CEQ_PD", "detach_or_release:CEQ_RING"});
expect_trace("AEQ_DESTROY",
  '{"cmq:16", "host_release:AEQ_PD", "detach_or_release:AEQ_RING"});
```

创建 CQ→CEQ、SRQ→PD 和 QP→CQ/SRQ dependents，调用 destroy 后断言 `RDMA_SC_RESOURCE_BUSY`、ACTIVE、CMQ call count 不变。SRQ 第一个 flush 已成功后，第二个 flush 在取得 ticket 前发生 submit/validation failure，断言恢复 ACTIVE，并把两个 flush bit 都清零；下一次 destroy 重新发送两个 flush。带 ticket 的 nonzero hardware ecode不被泛化为“无 destructive change”。

- [ ] **Step 2: 确认 destroy 顺序仍未实现**

Run: `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`

Expected: test FAIL，报告 destroy API 未释放资源、CMQ 顺序不匹配或 busy guard 缺失。

- [ ] **Step 3: 由 policy 发布不可重排 cleanup recipe**

在 policy base 增加：

```systemverilog
pure virtual function void hardware_cleanup_roles(
  output rdma_queue_backing_role_e flush_roles[$],
  output rdma_queue_flush_phase_e flush_phases[$],
  output bit delete_before_flush);
pure virtual function void local_cleanup_roles(
  output rdma_queue_backing_role_e roles[$],
  output bit release_context_first);
```

CQ 返回 delete-before-flush、CQ_PD/POST；SRQ 返回 flush-before-delete、SRFQ_PD/PRE 与 SRQ_PD/PRE；EQ 无 flush。local role 次序精确等于 Step 1 trace，缺失必需 role 或重复 role返回 invalid state。

- [ ] **Step 4: 实现 destroy_locked 与安全失败分类**

`destroy_locked()`：typed kind/owner/generation→lookup ACTIVE snapshot→`begin_quiesce()`→按 recipe 逐个 CMQ→每个成功 target 立即 `record_queue_flush_complete()`→本地逐 role cleanup 并立即持久化→`finalize_release()`。

SRQ 前一 flush 未可信成功不得发送后一 flush；两者未全成功不得 delete。normal destroy 的 terminal failure只有在 completion 明确保证命令未改变对象、hardware presence 仍 PRESENT 且尚未本地 cleanup 时调用 `restore_active()`。timeout/reset-cancel/结果丢失进入 ERROR。CQ delete 成功后把 presence 设 ABSENT，即使 post-delete flush 失败也不得恢复 ACTIVE。本地 cleanup 失败保持 ABSENT ERROR。

- [ ] **Step 5: 运行 destroy/busy 和 manager 回归并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_queue_lifecycle_test
scripts/run_vcs53.sh core rdma_resource_manager_test
```

Expected: 两个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`；所有 hardware/local trace 精确匹配。

Commit:

```bash
git add src/core/rdma_queue_lifecycle_policy.svh \
  src/core/rdma_queue_lifecycle_executor.svh \
  src/core/rdma_resource_manager.svh \
  tests/unit/rdma_queue_lifecycle_test.svh
git commit -m "feat: destroy queues in hardware-safe order"
```

### Task 13: 实现 Reconcile、QUERY、OCC 与 Exactly-Once Queue Recovery

**Files:**
- Modify: `src/core/rdma_queue_lifecycle_policy.svh`
- Modify: `src/core/rdma_queue_lifecycle_executor.svh`
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `tests/mocks/rdma_mock_control_plane.svh`
- Create: `tests/unit/rdma_queue_recovery_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 presence evidence、OCC barrier 和 repeated recovery 失败测试**

矩阵必须包括：create/delete timeout 的 late success/late failure/pending；typed QUERY success；CQC `f3`、CEQC `f7`、AEQC `fa` 的 ABSENT 白名单；SRFQ `7b` 和任意其他 nonzero ecode 保持 UNKNOWN；QUERY timeout/failure；ambiguous OCC 即使 QUERY 证明 ABSENT也不释放 PD。

```systemverilog
cmq.script_reconcile(ticket, 1'b0, null, rdma_status::success());
cmq.script_query_context(XTR_V1_OP_CQC_QUERY, cqc_context,
                         rdma_status::success());
control_plane.recover_resource(binding, cq.handle, result);
if (result.ok() || !result.recovery_required ||
    context_api.release_call_count != 0 || host_mem.release_call_count != 0)
  `uvm_error("QUERY_NOT_OCC", "QUERY incorrectly proved OCC completion")
```

local cleanup exactly-once case模拟 external release 已成功但 progress persistence 失败；第二次 recovery 必须先 query completion，release call count 仍为 1。

- [ ] **Step 2: 确认 queue recovery 仍走 MR-only 分支**

Run: `scripts/run_vcs53.sh core rdma_queue_recovery_test`

Expected: 编译或 test FAIL，报告 queue ERROR resource 不受支持、错误恢复为 ACTIVE 或重复 release。

- [ ] **Step 3: 增加 opcode-aware QUERY evidence classifier**

policy 增加：

```systemverilog
pure virtual function rdma_status classify_query_completion(
  rdma_queue_resource resource,
  rdma_cmq_completion completion,
  output rdma_hw_presence_e presence,
  output bit conclusive);
```

success 时先把 `completion.decoded_response` cast 为真实 engine 发布的 `rdma_xtr_v1_cmq_completion`，验证 response opcode 和 query ticket一致，再按 profile 的 returned-payload bounds 解码 `object_payload`：CQC 56 bytes，SRFQC/CEQC/AEQC 32 bytes。policy 用 authoritative resource local ID 和 snapshot 中未返回的静态字段补齐对应 typed context model，再用现有 context codec field rules验证返回字段；typed model/kind/local ID不匹配时不构成 evidence。只有该 typed decode成功才返回 PRESENT。失败只对白名单 `(CQC_QUERY,f3)`、`(CEQC_QUERY,f7)`、`(AEQC_QUERY,fa)` 返回 ABSENT；SRFQC `7b`、通用 INVALID_ARGUMENT、TIMEOUT 和未知码均 `conclusive=0`。

- [ ] **Step 4: 实现 policy-driven recover_locked**

算法固定为：加载 ERROR snapshot→如有 ticket 先 `cmq.reconcile()`→把 terminal evidence 投影到其 create/delete/role-tagged OCC→每次投影后立即 persist→只有 create/delete presence 未知时发送 QUERY→从首个未完成 hardware recipe step继续→presence ABSENT 且全部必需 OCC complete 后才做 local cleanup→每项 release 前 query completion→完成后 `finalize_release()`。

create rollback intent：PRESENT 走完整 hardware cleanup；ABSENT 走 remaining OCC/local cleanup。normal destroy intent从已保存 recipe 继续。CQ ABSENT+CQ_PD incomplete 从 post-delete flush 继续；SRQ PRESENT 从第一个 incomplete pre-delete flush 继续；CEQ/AEQ PRESENT 从 delete 继续。OCC ticket无法 reconcile 时不发送新的同 role flush，不跨越 barrier。

control plane 的 `recover_resource()` 在锁内 lookup kind：MR 保留 Task 14A 路径，CQ/SRQ/CEQ/AEQ 调 `queue_executor.recover_locked()`，其他 kind保持原错误。

- [ ] **Step 5: 运行 recovery 与 CMQ reconcile 回归并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_queue_recovery_test
scripts/run_vcs53.sh core rdma_cmq_port_test
scripts/run_vcs53.sh core rdma_control_plane_test
```

Expected: 三个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`；QUERY 不越过 OCC，所有 repeated recovery release count 为 1。

Commit:

```bash
git add src/core/rdma_queue_lifecycle_policy.svh \
  src/core/rdma_queue_lifecycle_executor.svh \
  src/core/rdma_control_plane.svh \
  tests/mocks/rdma_mock_control_plane.svh \
  tests/unit/rdma_queue_recovery_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: recover ambiguous queue lifecycle operations"
```

### Task 14: 完成逐点失败注入、并发与 Generation Fence

**Files:**
- Modify: `tests/mocks/rdma_mock_adapters.svh`
- Modify: `tests/mocks/rdma_mock_context_backing.svh`
- Modify: `tests/mocks/rdma_mock_control_plane.svh`
- Modify: `tests/unit/rdma_queue_lifecycle_test.svh`
- Modify: `tests/unit/rdma_queue_recovery_test.svh`
- Modify: `src/core/rdma_queue_lifecycle_executor.svh`

- [ ] **Step 1: 写 machine-readable failure matrix 和 barrier tests**

每个 mock 增加按 method+role+ordinal 的脚本入口，测试逐行迭代：

```systemverilog
failure_points = '{
  "reserve", "payload_allocate", "payload_write", "pd_allocate",
  "pd_write", "context_acquire", "context_write", "stage_allocated",
  "create_submit", "create_terminal", "commit_programmed", "activate",
  "pre_flush_0", "pre_flush_1", "delete", "post_flush_0",
  "context_release", "pd_release", "payload_release", "finalize_release"
};
foreach (failure_points[i]) begin
  fixture.reset();
  fixture.inject(failure_points[i], injected_status);
  fixture.run_and_check(failure_points[i]);
end
```

每行检查 resource state、presence、completed/pending steps、CMQ order、allocation/release counts、ID pool、dependencies 和 recovery plan。并发 barrier覆盖同 Function queue/MR 串行、不同 Function同时进入 CMQ、等待锁期间 rebind、CMQ completion 后 generation 增加、旧 generation late completion。

- [ ] **Step 2: 运行矩阵，记录第一个不满足 invariant 的红灯**

Run:

```bash
scripts/run_vcs53.sh core rdma_queue_lifecycle_test
scripts/run_vcs53.sh core rdma_queue_recovery_test
```

Expected: 至少一个 test FAIL，首个报告指出尚未覆盖的 ordinal failure、progress persistence 或 generation checkpoint。

- [ ] **Step 3: 实现可复现 mock scripting 和 scheduler barriers**

统一增加：

```systemverilog
function void fail_role_call(string method_name,
                             rdma_queue_backing_role_e role,
                             int unsigned ordinal,
                             rdma_status status);
task pause_cmq_opcode(bit [7:0] opcode);
task wait_until_paused(bit [7:0] opcode);
function void release_cmq_opcode(bit [7:0] opcode);
```

每次调用先记录不可变 snapshot，再按 `(method,role,ordinal)` 消费一个 outcome。pause 只阻塞目标 opcode，不持有 mock 内部全局 mutex，允许另一 Function 到达 barrier。reset 清空 outcome、barrier、call ordinal 和 release completion state。

- [ ] **Step 4: 补齐 executor checkpoints 和 fail-atomic persistence**

executor 在以下边界统一调用 live binding comparison：加锁入口、每个 CMQ terminal completion 后、每个 registry hardware-progress update 前、`commit_programmed()` 前、`activate()` 前、local cleanup前和 `finalize_release()` 前。旧 generation 永不 activate、restore 或 release新 generation authority。

每个 transaction-local update 先构造 replacement recovery/plan 并 validate，再调用 manager 窄更新；失败时保留此前权威 entry，不提前设置下一个 bit。SRQ 的 flush N complete 未持久化时不得发送 N+1。

- [ ] **Step 5: 运行失败矩阵与并发回归并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_queue_lifecycle_test
scripts/run_vcs53.sh core rdma_queue_recovery_test
scripts/run_vcs53.sh core rdma_control_plane_test
scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
```

Expected: 四个测试均为 `0 UVM_ERROR / 0 UVM_FATAL`；failure matrix 每一行通过且无 authority/ID/ticket 泄漏。

Commit:

```bash
git add tests/mocks/rdma_mock_adapters.svh \
  tests/mocks/rdma_mock_context_backing.svh \
  tests/mocks/rdma_mock_control_plane.svh \
  tests/unit/rdma_queue_lifecycle_test.svh \
  tests/unit/rdma_queue_recovery_test.svh \
  src/core/rdma_queue_lifecycle_executor.svh
git commit -m "test: cover queue lifecycle failure and concurrency matrix"
```

### Task 15: 增加 Production host_mem 64-bit Integration 与静态边界 Checker

**Files:**
- Modify: `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv`
- Modify: `tests/integration/rdma_host_mem_adapter_test.svh`
- Create: `tools/check_queue_lifecycle.py`
- Create: `tests/unit/test_check_queue_lifecycle.py`

- [ ] **Step 1: 写 64-bit integration 断言和 checker 反例 fixture**

host_mem integration 使用真实 adapter 创建 64-bit payload/PD mapping，执行 planner 初始化后读取 bytes：

```systemverilog
if (payload.iova.value <= 64'hffff_ffff ||
    payload.iova.value == payload.backing_addr.value)
  `uvm_error("QUEUE_64BIT", "fixture did not separate 64-bit IOVA/backing")
expect_status("QUEUE_PD_READ", adapter.read(pd_mapping, 0, 8, bytes),
              RDMA_SC_OK);
if (bytes[0] != payload.iova.value[63:56] || bytes[7][0] != 1'b1)
  `uvm_error("QUEUE_PD_READ", "PD did not encode payload IOVA")
```

Python fixture 必须令 checker 拒绝：policy/executor 中读取 `.backing_addr`、core package import PCIe/AXIS/net VIP、公共 create request 出现 `rdma_iova_t`/`rdma_backing_addr_t` 裸字段、queue base 从 backing address赋值、修改 frozen defs 中 queue opcodes。

- [ ] **Step 2: 确认 checker 不存在且 integration 尚未覆盖 queue PD**

Run:

```bash
python3 -m pytest -q tests/unit/test_check_queue_lifecycle.py
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected: pytest collection FAIL 于缺失 `tools/check_queue_lifecycle.py`；host_mem test FAIL 于缺失 queue planner/PD integration case。

- [ ] **Step 3: 完成 production mapping domain/authority 传播**

确认 production `allocate()` 从 request context复制 Function、BDF、PASID、domain；`make_authority_snapshot()`、`do_copy()`、`same_allocation` value checks 和 release completion保留 domain。write 成功返回前沿用 host_mem manager 的同步完成边界；不增加 PCIe/VIP 调用。

- [ ] **Step 4: 实现 fail-closed static checker**

`check_queue_lifecycle.py` 使用 `pathlib` 和受限正则；核心实现使用以下 fail-closed 结构：

```python
from pathlib import Path
import re
import subprocess

class ValidationError(RuntimeError):
    pass

def read(repo_root: Path, relative: str) -> str:
    return (repo_root / relative).read_text(encoding="utf-8")

def reject(text: str, pattern: str, message: str) -> None:
    if re.search(pattern, text, flags=re.MULTILINE | re.DOTALL):
        raise ValidationError(message)

def validate_iova_only(repo_root: Path) -> None:
    for relative in (
        "src/core/rdma_queue_lifecycle_policy.svh",
        "src/core/rdma_queue_lifecycle_executor.svh",
        "src/codec/xtr_v1/rdma_xtr_v1_queue_page_codec.svh",
    ):
        reject(read(repo_root, relative), r"\.backing_addr\b",
               f"{relative} reads host backing_addr")
    policy = read(repo_root, "src/core/rdma_queue_lifecycle_policy.svh")
    if "rdma_queue_base_from_iova" not in policy:
        raise ValidationError("queue policy lacks checked IOVA projection")

def validate_public_api_shape(repo_root: Path) -> None:
    requests = read(repo_root, "src/model/rdma_semantic_requests.svh")
    for class_name in ("rdma_create_cq_req", "rdma_create_srq_req",
                       "rdma_create_ceq_req", "rdma_create_aeq_req"):
        match = re.search(rf"class {class_name}\b(.*?)endclass", requests,
                          flags=re.DOTALL)
        if match is None:
            raise ValidationError(f"missing request class {class_name}")
        reject(match.group(1), r"\brdma_(?:iova|backing_addr)_t\b",
               f"{class_name} exposes a raw address wrapper")

def validate_core_dependencies(repo_root: Path) -> None:
    core_text = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (repo_root / "src/core").glob("*.svh")
    ) + read(repo_root, "src/core/rdma_core_pkg.sv")
    reject(core_text,
           r"\b(?:pcie_work|axis_vip|net_packet|host_mem_manager)\b",
           "core depends on an external implementation")

def validate_package_order(repo_root: Path) -> None:
    model_pkg = read(repo_root, "src/model/rdma_model_pkg.sv")
    required = ["rdma_resource_refs.svh",
                "rdma_queue_lifecycle_models.svh",
                "rdma_semantic_requests.svh", "rdma_resources.svh"]
    positions = [model_pkg.find(name) for name in required]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise ValidationError("model package queue include order is invalid")
    core_pkg = read(repo_root, "src/core/rdma_core_pkg.sv")
    required = ["rdma_resource_manager.svh", "rdma_queue_lifecycle_policy.svh",
                "rdma_queue_backing_planner.svh",
                "rdma_queue_lifecycle_executor.svh", "rdma_control_plane.svh"]
    positions = [core_pkg.find(name) for name in required]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise ValidationError("core package queue include order is invalid")

def validate_frozen_queue_abi(repo_root: Path) -> None:
    subprocess.run([
        "git", "diff", "--exit-code", "a0abd95", "--",
        "src/codec/xtr_v1/rdma_xtr_v1_defs.svh",
        "src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh",
        "src/codec/xtr_v1/rdma_xtr_v1_context_body_codecs.svh",
        "src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh",
    ], cwd=repo_root, check=True)

def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    for check in (validate_iova_only, validate_public_api_shape,
                  validate_core_dependencies, validate_package_order,
                  validate_frozen_queue_abi):
        check(repo_root)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

`validate_iova_only` 允许 planner/host adapter做 CPU backing access，但禁止 policy/executor/PD codec 出现 `.backing_addr`；OCC/context queue base 必须经过 `rdma_queue_base_from_iova`。API checker扫描四个 request class，拒绝 address wrapper 字段。dependency checker拒绝 `rdma_core_pkg` 和 core `.svh` import/引用外部实现。package checker固定 model/core include依赖顺序。ABI checker要求四个 frozen ABI 文件与已批准设计提交 `a0abd95` 完全一致；真实驱动字段/值仍由随后单独运行的既有 pinned-source checker验证，不定义第二份 opcode 真相。

- [ ] **Step 5: 运行 pytest、host_mem 和 frozen ABI 并提交**

Run:

```bash
python3 -m pytest -q tests/unit/test_check_xtr_v1_defs.py \
  tests/unit/test_check_queue_lifecycle.py
python3 tools/check_queue_lifecycle.py
scripts/run_vcs53.sh xtr_defs regression
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected: pytest 全 PASS；两个 checker exit 0；host_mem 为 `0 UVM_ERROR / 0 UVM_FATAL`。

Commit:

```bash
git add src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv \
  tests/integration/rdma_host_mem_adapter_test.svh \
  tools/check_queue_lifecycle.py tests/unit/test_check_queue_lifecycle.py
git commit -m "test: verify queue lifecycle adapter boundaries"
```

### Task 16: 增加明确的 53 Regression Runner 并执行完成验证

**Files:**
- Create: `scripts/run_queue_lifecycle_regression53.sh`
- Create: `tests/unit/test_run_queue_lifecycle_regression53.py`
- Modify: `docs/superpowers/specs/2026-08-26-rdma-queue-lifecycle-design.md`

- [ ] **Step 1: 写 runner manifest 的失败测试**

Python test读取 runner 的 `--list` 输出并要求没有伪 test `regression`，且包含所有现有 core tests和五个新增 tests。完整 discovery/test 逻辑为：

```python
from pathlib import Path
import re
import subprocess

REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER = REPO_ROOT / "scripts/run_queue_lifecycle_regression53.sh"
CLASS_RE = re.compile(
    r"class\s+(\w+)\s+extends\s+(\w+)\s*;"
)

def discover_uvm_tests(unit_root: Path) -> set[str]:
    parents: dict[str, str] = {}
    registered: set[str] = set()
    for path in unit_root.glob("*.svh"):
        text = path.read_text(encoding="utf-8")
        parents.update(CLASS_RE.findall(text))
        registered.update(re.findall(r"`uvm_component_utils\((\w+)\)", text))
    tests: set[str] = set()
    for class_name in registered:
        ancestor = class_name
        seen: set[str] = set()
        while ancestor in parents and ancestor not in seen:
            seen.add(ancestor)
            ancestor = parents[ancestor]
        if ancestor == "uvm_test":
            tests.add(class_name)
    tests.discard("rdma_harness_expected_failure_probe")
    return tests

def test_runner_lists_every_normal_unit_test() -> None:
    required = {
        "rdma_queue_lifecycle_models_test",
        "rdma_context_backing_contract_test",
        "rdma_xtr_v1_queue_page_codec_test",
        "rdma_queue_lifecycle_test",
        "rdma_queue_recovery_test",
    }
    listed = set(subprocess.check_output(
        [str(RUNNER), "--list"], text=True
    ).splitlines())
    assert required <= listed
    assert "regression" not in listed
    assert listed == discover_uvm_tests(REPO_ROOT / "tests" / "unit")
```

该 discovery 沿继承链识别 `rdma_cmq_port_test extends rdma_cmq_engine_test`，不会只匹配直接继承 `uvm_test` 的 class。

- [ ] **Step 2: 确认 runner 尚不存在**

Run: `python3 -m pytest -q tests/unit/test_run_queue_lifecycle_regression53.py`

Expected: FAIL，报告 `scripts/run_queue_lifecycle_regression53.sh` 不存在。

- [ ] **Step 3: 实现显式 test-class runner**

脚本使用以下固定 bash array列出 `tests/rdma_unit_test_pkg.sv` 注册的全部正常 core test class；`--list` 每行输出一个名称，默认逐个执行：

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly repo_root="$(git rev-parse --show-toplevel)"
readonly core_tests=(
  rdma_smoke_test
  rdma_types_test
  rdma_model_test
  rdma_cmq_engine_models_test
  rdma_control_plane_models_test
  rdma_context_model_test
  rdma_request_model_test
  rdma_adapter_contract_test
  rdma_resource_manager_test
  rdma_doorbell_scheduler_test
  rdma_cmq_engine_test
  rdma_cmq_port_test
  rdma_control_plane_test
  rdma_control_plane_cmq_engine_test
  rdma_codec_registry_test
  rdma_xtr_v1_defs_test
  rdma_xtr_v1_qword_codec_test
  rdma_xtr_v1_doorbell_codec_test
  rdma_xtr_v1_qpc_codec_test
  rdma_xtr_v1_context_body_codec_test
  rdma_xtr_v1_cmq_codec_test
  rdma_xtr_v1_error_codec_test
  rdma_xtr_v1_cmq_completion_test
  rdma_xtr_v1_cmq_profile_test
  rdma_xtr_v1_context_cmq_regression_test
  rdma_queue_lifecycle_models_test
  rdma_context_backing_contract_test
  rdma_xtr_v1_queue_page_codec_test
  rdma_queue_lifecycle_test
  rdma_queue_recovery_test
)

if [[ ${1-} == "--list" ]]; then
  printf '%s\n' "${core_tests[@]}"
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--list]" >&2
  exit 2
fi

cd "$repo_root"
for test_name in "${core_tests[@]}"; do
  scripts/run_vcs53.sh core "$test_name"
done
```

脚本 `set -euo pipefail`，从 `git rev-parse --show-toplevel` 定位根目录，不使用 `make core TEST=regression`，任一 test失败立即非零退出。

- [ ] **Step 4: 运行完整 Python/VCS/host_mem/frozen-ABI 验证**

Run:

```bash
python3 -m pytest -q tests/unit/test_check_xtr_v1_defs.py \
  tests/unit/test_check_queue_lifecycle.py \
  tests/unit/test_run_queue_lifecycle_regression53.py
python3 tools/check_queue_lifecycle.py
scripts/run_queue_lifecycle_regression53.sh
scripts/run_vcs53.sh xtr_defs regression
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected: 所有 pytest PASS；runner中的每个 core test均为 `0 UVM_ERROR / 0 UVM_FATAL`；xtr checker exit 0；host_mem integration 为 `0 UVM_ERROR / 0 UVM_FATAL`。

- [ ] **Step 5: 标记设计完成并提交验证入口**

把设计文档状态改为：

```text
状态：已实现；完成证据由 scripts/run_queue_lifecycle_regression53.sh、
tools/check_queue_lifecycle.py 和 host_mem integration test 提供
```

运行：

```bash
git diff --check
git status --short
```

Expected: 无 whitespace error；状态只包含本任务三个文件以及实施期间有意修改的 tracked 文件，不包含 `__pycache__`。

Commit:

```bash
git add scripts/run_queue_lifecycle_regression53.sh \
  tests/unit/test_run_queue_lifecycle_regression53.py \
  docs/superpowers/specs/2026-08-26-rdma-queue-lifecycle-design.md
git commit -m "test: add queue lifecycle VCS regression runner"
```

## 最终验收检查表

- [ ] CQ/SRQ/CEQ/AEQ owned/borrowed create/destroy 全部 ACTIVE→RELEASED，且 ID、dependency、mapping、context、ticket 无泄漏。
- [ ] CQE 32/64/128、SRQ max_sge/limit/SGB、EQ local→hardware vector 均有正反测试。
- [ ] 64-bit IOVA 与 backing address 分离；PD、queue base、OCC 只编码 IOVA；context pointer 只来自 context API。
- [ ] CQ/SRQ shadow bytes、payload/PD 全量初始化和 payload→PD→context→CMQ 顺序有 byte-level/call-trace 证据。
- [ ] CQ/SRQ/CEQ/AEQ destroy hardware/local 顺序精确匹配真实驱动；busy 不发 CMQ、不级联。
- [ ] timeout、reset-cancel、late completion、QUERY 和 OCC barrier 保持 presence/completion 两轴独立。
- [ ] SRQ restore ACTIVE 清空本次 pre-delete progress；ERROR recovery 保留已证明 progress。
- [ ] owned mapping/context exactly-once；borrowed payload release count 恒为 0。
- [ ] 同 Function lifecycle 串行、不同 Function并行、所有 generation fence通过。
- [ ] core package 不依赖 PCIe env、AXIS env、net_packet、host_mem 实现类或具体 VIP。
- [ ] `python3 -m pytest -q tests/unit/test_check_xtr_v1_defs.py tests/unit/test_check_queue_lifecycle.py tests/unit/test_run_queue_lifecycle_regression53.py` 全 PASS。
- [ ] `scripts/run_queue_lifecycle_regression53.sh` 在 53 上全部 `0 UVM_ERROR / 0 UVM_FATAL`。
- [ ] `scripts/run_vcs53.sh xtr_defs regression` 和 production host_mem integration通过。
