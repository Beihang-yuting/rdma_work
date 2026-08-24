# RDMA Task 14A Transactional PD/MR Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现一个可注入、同步事务式、generation-safe 且支持失败恢复的 UVM RDMA 控制面，完成纯软件 PD 和普通 xtr_v1 MR 的 create/register/deregister 生命周期。

**Architecture:** `rdma_control_plane` 只编排 resource manager、typed context、CMQ port、host_mem 和 HMC lease，不持有第二份资源真相。resource manager 原子提交生命周期和 persistent recovery record；生产 CMQ adapter 包装现有 multi-outstanding engine，mock port 支持逐 opcode/逐调用故障注入。

**Tech Stack:** SystemVerilog/UVM 1.2、Synopsys VCS（`10.11.10.53`）、现有 xtr_v1 codec/CMQ engine、`rdma_host_mem_api`、`rdma_hmc_allocator`、Python/pytest checker。

---

## 执行前提

- 实施时先使用 `superpowers:using-git-worktrees` 创建独立 worktree；不要直接在用户工作中的 dirty tree 上开发。
- 所有 SystemVerilog 仿真使用 `scripts/run_vcs53.sh`，该脚本在 53 上通过 bash login shell 调用 VCS。
- 不修改或复制 `host_mem`、`pcie_work`、`axis_vip`、`net_packet` 的源码；只调用现有 adapter/API。
- 不把 GitHub token 写入 URL、脚本、credential helper 或配置。
- 每个任务严格执行红—绿—提交；若预期失败没有出现，先解释测试为何没有锁定需求，再继续实现。

## 固定语义

- PD 只分配软件 ID，不发送 CMQ，也不申请 HMC。
- 普通 MR 注册固定发送 `KEY_ALLOC(0x04)`；`MR_REGISTER(0x05)` 不属于 14A。
- MR 销毁固定发送 `MR_DEREGISTER(0x06)`；PBL2 在其前发送 `OCC_FLUSH(0x0a)`，删除后按策略发送 `TQ_FLUSH(0x20)`。
- 软件 registry handle 的 kind-tagged `object_id` 不进入硬件字段；PD/MR context 分别使用 16-bit/24-bit local ID projection。
- borrowed backing 永不由控制面 release；control-plane-owned backing 恰好 release 一次。
- timeout、rollback failure 或硬件状态不确定时保留 `RDMA_RESOURCE_ERROR` 和 persistent recovery record。
- 同一 Function 的生命周期事务串行，不同 Function 可以并行。

## 文件边界

| 文件 | 单一职责 |
|---|---|
| `src/types/rdma_enum_types.svh` | 新增 RESOURCE_BUSY/RECOVERY_REQUIRED 状态码。 |
| `src/types/rdma_address_types.svh` | 发布硬件中立 `rdma_rdma_access_t`。 |
| `src/types/rdma_status.svh` | 为新状态码映射 category。 |
| `src/model/rdma_resource_refs.svh` | resource state、backing/HMC ownership reference value objects。 |
| `src/model/rdma_control_plane_models.svh` | MR backing descriptor、transaction/result/recovery value objects。 |
| `src/model/rdma_semantic_requests.svh` | MR 请求使用 RDMA access，不接受 caller-supplied lkey/rkey。 |
| `src/model/rdma_resources.svh` | 保存 owned/borrowed references、MR access、key 和 serial。 |
| `src/model/rdma_model_pkg.sv` | 按依赖顺序发布新增模型。 |
| `src/core/rdma_stag_key_policy.svh` | 可注入、确定性的 8-bit STAG key policy。 |
| `src/core/rdma_cmq_port.svh` | hardware-neutral execute/reconcile 抽象。 |
| `src/core/rdma_cmq_engine_port_adapter.svh` | 生产 port 到现有 CMQ engine 的适配。 |
| `src/core/rdma_resource_manager.svh` | local-ID 宽度、状态提交、busy 检查和 recovery registry。 |
| `src/core/rdma_cmq_engine.svh` | 增加不吞掉其他完成的 ticket-specific reconcile。 |
| `src/core/rdma_control_plane.svh` | PD/MR 同步事务、回滚、恢复和 Function 锁。 |
| `src/core/rdma_core_pkg.sv` | 以依赖顺序发布新 core 类。 |
| `tests/mocks/rdma_mock_control_plane.svh` | mock CMQ port、STAG key policy 和调用记录。 |
| `tests/unit/rdma_control_plane_models_test.svh` | 新 value objects 的 copy/validate 测试。 |
| `tests/unit/rdma_cmq_port_test.svh` | port execute/reconcile contract。 |
| `tests/unit/rdma_control_plane_test.svh` | PD/MR 正常、失败、恢复、并发主测试。 |
| `tests/unit/rdma_control_plane_cmq_engine_test.svh` | control plane 到真实 CMQ engine 的组合测试。 |
| `tests/rdma_unit_test_pkg.sv` | 发布 mock 和四个新测试。 |
| `docs/superpowers/plans/2026-08-20-rdma-uvm-driver-architecture.md` | 将原 Task 14 标注为 14A/14B/14C。 |

`sim/filelists/core.f` 不预期修改：新增 `.svh` 都由现有 package `.sv` include。若编译证明 filelist 需要改变，先记录实际编译错误，再做最小修正。

## 最终公开接口

实现期间以下名字是唯一命名基准：

```systemverilog
virtual class rdma_cmq_port extends uvm_object;
  pure virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
  pure virtual task reconcile(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
endclass

virtual class rdma_stag_key_policy extends uvm_object;
  pure virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
endclass

class rdma_control_plane extends uvm_object;
  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_cmq_port cmq_port,
    rdma_stag_key_policy key_policy,
    rdma_host_mem_api host_mem = null,
    rdma_hmc_allocator hmc_allocator = null,
    time command_timeout = 1us
  );
  task create_pd(rdma_function_binding binding,
                 rdma_create_pd_req request,
                 output rdma_pd pd,
                 output rdma_control_result result);
  task destroy_pd(rdma_function_binding binding,
                  rdma_handle pd_h,
                  output rdma_control_result result);
  task register_mr(rdma_function_binding binding,
                   rdma_register_mr_req request,
                   rdma_mr_backing_desc backing,
                   output rdma_mr mr,
                   output rdma_control_result result);
  task alloc_and_register_mr(rdma_function_binding binding,
                             rdma_register_mr_req request,
                             rdma_dma_request_context dma_context,
                             int unsigned alignment,
                             output rdma_dma_mapping mapping,
                             output rdma_mr mr,
                             output rdma_control_result result);
  task deregister_mr(rdma_function_binding binding,
                     rdma_handle mr_h,
                     output rdma_control_result result);
  task recover_resource(rdma_function_binding binding,
                        rdma_handle resource_h,
                        output rdma_control_result result);
endclass
```

`rdma_control_result.status` 是 caller-facing aggregate；`primary_status` 始终保留原操作错误。rollback 不完整时 `status.code == RDMA_SC_RECOVERY_REQUIRED`。

### Task 1: 修正状态码和 MR Access 语义

**Files:**
- Modify: `src/types/rdma_enum_types.svh:1`
- Modify: `src/types/rdma_address_types.svh:21`
- Modify: `src/types/rdma_status.svh:67`
- Modify: `src/model/rdma_context_layouts.svh:32`
- Modify: `src/model/rdma_semantic_requests.svh:169`
- Modify: `tests/unit/rdma_types_test.svh`
- Modify: `tests/unit/rdma_request_model_test.svh:190`

- [ ] **Step 1: 写状态码 category 和 MR access 的失败测试**

在 `rdma_types_test` 增加：

```systemverilog
expect_status_category("RESOURCE_BUSY", RDMA_SC_RESOURCE_BUSY,
                       RDMA_STATUS_RESOURCE);
expect_status_category("RECOVERY_REQUIRED", RDMA_SC_RECOVERY_REQUIRED,
                       RDMA_STATUS_STATE);
```

在 `rdma_request_model_test` 的 register-MR case 中替换 DMA permission 输入：

```systemverilog
register_mr.access = '{local_write:1'b1, remote_read:1'b1,
                       remote_write:1'b1, memory_window_bind:1'b0,
                       remote_atomic:1'b0};
expect_status("REGISTER_MR", register_mr.validate(), RDMA_SC_OK);
```

再加入编译期/行为检查：

```systemverilog
register_mr.access.remote_atomic = 1'b1;
if (!register_mr.access.remote_atomic)
  `uvm_error("REGISTER_MR_ACCESS", "remote atomic access was lost")
```

- [ ] **Step 2: 在 53 上运行测试，确认红灯**

Run:

```bash
scripts/run_vcs53.sh core rdma_types_test
scripts/run_vcs53.sh core rdma_request_model_test
```

Expected: 编译 FAIL，报告 `RDMA_SC_RESOURCE_BUSY` 或 `rdma_register_mr_req.access` 未定义。

- [ ] **Step 3: 发布新状态码和 access type**

在 `rdma_enum_types.svh` 追加且不重排已有编码：

```systemverilog
RDMA_SC_RESOURCE_BUSY       = 5'd15,
RDMA_SC_RECOVERY_REQUIRED  = 5'd16
```

在 `rdma_address_types.svh` 发布：

```systemverilog
typedef struct packed {
  bit local_write;
  bit remote_read;
  bit remote_write;
  bit memory_window_bind;
  bit remote_atomic;
} rdma_rdma_access_t;
```

从 `rdma_context_layouts.svh` 删除重复 typedef。更新 `category_for()`：

```systemverilog
RDMA_SC_RESOURCE_EXHAUSTED,
RDMA_SC_RESOURCE_BUSY:
  return RDMA_STATUS_RESOURCE;
RDMA_SC_INVALID_STATE,
RDMA_SC_STALE_GENERATION,
RDMA_SC_RECOVERY_REQUIRED:
  return RDMA_STATUS_STATE;
```

- [ ] **Step 4: 把 register request 改为语义 access**

`rdma_register_mr_req` 保留 PD、IOVA、length，移除 request 中的 lkey/rkey/DMA permissions，加入：

```systemverilog
rdma_rdma_access_t access;
```

构造和 copy 使用：

```systemverilog
access = '0;
access = rhs_req.access;
```

lkey/rkey 只保留在 `rdma_mr` 和 `rdma_mrt_model`，由控制面生成。

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_types_test
scripts/run_vcs53.sh core rdma_request_model_test
```

Expected: 两个测试 UVM warning/error/fatal 均为 `0/0/0`。

Commit:

```bash
git add src/types src/model/rdma_context_layouts.svh \
  src/model/rdma_semantic_requests.svh tests/unit/rdma_types_test.svh \
  tests/unit/rdma_request_model_test.svh
git commit -m "feat: define control-plane status and MR access semantics"
```

### Task 2: 增加 Ownership、Transaction 和 Recovery Value Objects

**Files:**
- Create: `src/model/rdma_resource_refs.svh`
- Create: `src/model/rdma_control_plane_models.svh`
- Modify: `src/model/rdma_resources.svh:1`
- Modify: `src/model/rdma_model_pkg.sv:7`
- Create: `tests/unit/rdma_control_plane_models_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv:17`

- [ ] **Step 1: 写 deep-copy、ownership 和 recovery validation 失败测试**

新增测试类并构造一个 active mapping、borrowed ref、PBL0 descriptor、result 和 recovery record：

```systemverilog
backing_ref.ownership = RDMA_OWNERSHIP_BORROWED;
backing_ref.mapping = mapping;
backing_ref.release_complete = 1'b0;
expect_status("BACKING_REF", backing_ref.validate(), RDMA_SC_OK);

descriptor.page_layout.pbl_mode = RDMA_MR_PBL0;
descriptor.page_layout.pba0 = mapping.backing_addr;
descriptor.backing_refs.push_back(backing_ref);
expect_status("MR_BACKING", descriptor.validate(), RDMA_SC_OK);

cloned_object = descriptor.clone();
if (!$cast(descriptor_clone, cloned_object) ||
    descriptor_clone.backing_refs[0] == descriptor.backing_refs[0] ||
    descriptor_clone.backing_refs[0].mapping == mapping)
  `uvm_error("MR_BACKING_COPY", "descriptor clone aliases source graph")

recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
recovery.pending_steps.push_back(RDMA_CTRL_STEP_HW_MR_DEREGISTER);
expect_status("RECOVERY", recovery.validate(), RDMA_SC_OK);
```

- [ ] **Step 2: 在 53 上运行，确认新类型未定义**

Run: `scripts/run_vcs53.sh core rdma_control_plane_models_test`

Expected: 编译 FAIL，首个错误为 `rdma_backing_ref` 或 ownership enum 未定义。

- [ ] **Step 3: 创建 resource-reference 模型**

把 `rdma_resource_state_e` 从 `rdma_resources.svh` 移入新文件，并定义：

```systemverilog
typedef enum bit {
  RDMA_OWNERSHIP_BORROWED,
  RDMA_OWNERSHIP_CONTROL_PLANE
} rdma_resource_ownership_e;

typedef enum bit [1:0] {
  RDMA_HW_PRESENCE_UNKNOWN,
  RDMA_HW_PRESENCE_PRESENT,
  RDMA_HW_PRESENCE_ABSENT
} rdma_hw_presence_e;

class rdma_backing_ref extends uvm_object;
  `uvm_object_utils(rdma_backing_ref)
  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  bit release_complete;
  function new(string name = "rdma_backing_ref");
    super.new(name);
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    release_complete = 1'b0;
  endfunction
  virtual function rdma_status validate();
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing reference mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE && !release_complete)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "live backing reference mapping is not active");
    if (release_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "borrowed backing cannot be marked released");
    return rdma_status::success();
  endfunction
  virtual function void do_copy(uvm_object rhs);
    rdma_backing_ref rhs_ref;
    uvm_object cloned_object;
    super.do_copy(rhs);
    if (!$cast(rhs_ref, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "backing reference copy mismatch")
    ownership = rhs_ref.ownership;
    release_complete = rhs_ref.release_complete;
    if (rhs_ref.mapping == null)
      mapping = null;
    else begin
      cloned_object = rhs_ref.mapping.clone();
      if (!$cast(mapping, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "backing mapping clone mismatch")
    end
  endfunction
endclass
```

同文件增加：

```systemverilog
class rdma_hmc_ref extends uvm_object;
  `uvm_object_utils(rdma_hmc_ref)
  rdma_function_handle owner;
  rdma_resource_kind_e object_kind;
  rdma_hmc_fvm_addr_t address;
  longint unsigned size;
  int unsigned first_pbl_index;
  rdma_resource_ownership_e ownership;
  bit release_complete;
  function new(string name = "rdma_hmc_ref");
    super.new(name);
    owner = null;
    object_kind = RDMA_RESOURCE_MR;
    address = '0;
    size = 0;
    first_pbl_index = 0;
    ownership = RDMA_OWNERSHIP_BORROWED;
    release_complete = 1'b0;
  endfunction
  virtual function rdma_status validate();
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC reference owner is invalid");
    if (object_kind != RDMA_RESOURCE_MR || size == 0 ||
        first_pbl_index == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR HMC reference metadata is invalid");
    if (release_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "borrowed HMC reference cannot be released");
    return rdma_status::success();
  endfunction
  virtual function void do_copy(uvm_object rhs);
    rdma_hmc_ref rhs_ref;
    uvm_object cloned_object;
    super.do_copy(rhs);
    if (!$cast(rhs_ref, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "HMC reference copy mismatch")
    if (rhs_ref.owner == null)
      owner = null;
    else begin
      cloned_object = rhs_ref.owner.clone();
      if (!$cast(owner, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "HMC owner clone mismatch")
    end
    object_kind = rhs_ref.object_kind;
    address = rhs_ref.address;
    size = rhs_ref.size;
    first_pbl_index = rhs_ref.first_pbl_index;
    ownership = rhs_ref.ownership;
    release_complete = rhs_ref.release_complete;
  endfunction
endclass
```

- [ ] **Step 4: 创建 control-plane 模型并固定 step enum**

在 `rdma_control_plane_models.svh` 定义：

```systemverilog
typedef enum bit [3:0] {
  RDMA_CTRL_STEP_RESOURCE_RESERVED,
  RDMA_CTRL_STEP_BACKING_ATTACHED,
  RDMA_CTRL_STEP_HMC_ATTACHED,
  RDMA_CTRL_STEP_HW_KEY_ALLOCATED,
  RDMA_CTRL_STEP_REGISTRY_PROGRAMMED,
  RDMA_CTRL_STEP_REGISTRY_ACTIVE,
  RDMA_CTRL_STEP_HW_OCC_FLUSHED,
  RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
  RDMA_CTRL_STEP_HW_DRAINED,
  RDMA_CTRL_STEP_BACKING_RELEASED,
  RDMA_CTRL_STEP_RESOURCE_RELEASED
} rdma_control_step_e;
```

实现并注册以下 value objects：

```systemverilog
class rdma_mr_backing_desc extends uvm_object;
  rdma_function_handle function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  rdma_backing_ref backing_refs[$];
  rdma_hmc_ref hmc_refs[$];
  rdma_mr_page_layout page_layout;
  virtual function rdma_status validate();
  virtual function void do_copy(uvm_object rhs);
endclass

class rdma_control_result extends uvm_object;
  longint unsigned transaction_id;
  rdma_status status;
  rdma_status primary_status;
  rdma_status rollback_statuses[$];
  rdma_handle resource_h;
  rdma_control_step_e completed_steps[$];
  rdma_resource_state_e final_resource_state;
  bit recovery_required;
  function bit ok();
    return status != null && status.ok();
  endfunction
  virtual function rdma_status validate();
  virtual function void do_copy(uvm_object rhs);
endclass

class rdma_recovery_record extends uvm_object;
  rdma_handle resource_h;
  rdma_hw_presence_e hardware_presence;
  rdma_control_step_e completed_steps[$];
  rdma_control_step_e pending_steps[$];
  rdma_backing_ref backing_refs[$];
  rdma_hmc_ref hmc_refs[$];
  rdma_cmq_ticket ambiguous_ticket;
  rdma_status primary_status;
  rdma_status rollback_statuses[$];
  virtual function rdma_status validate();
  virtual function void do_copy(uvm_object rhs);
endclass
```

`rdma_mr_backing_desc.validate()` 固定执行：

```systemverilog
rdma_status status;

if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION ||
    page_layout == null || backing_refs.size() == 0)
  return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                           "MR backing authority is incomplete");
foreach (backing_refs[i]) begin
  status = backing_refs[i].validate();
  if (!status.ok()) return status;
end
foreach (hmc_refs[i]) begin
  status = hmc_refs[i].validate();
  if (!status.ok()) return status;
end
status = page_layout.validate();
if (!status.ok()) return status;
case (page_layout.pbl_mode)
  RDMA_MR_PBL0:
    if (backing_refs.size() != 1 || hmc_refs.size() != 0 ||
        page_layout.pba0 != backing_refs[0].mapping.backing_addr)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PBL0 backing does not match its PBA");
  RDMA_MR_PBL1:
    if (backing_refs.size() != 2 || hmc_refs.size() != 0 ||
        page_layout.pba0 != backing_refs[0].mapping.backing_addr ||
        page_layout.pba1 != backing_refs[1].mapping.backing_addr)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PBL1 backing does not match its PBAs");
  RDMA_MR_PBL2:
    if (hmc_refs.size() != 1 || hmc_refs[0].first_pbl_index !=
        page_layout.first_pbl_index)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PBL2 backing does not match its HMC lease");
endcase
return rdma_status::success();
```

所有 object/queue 成员执行 detached deep copy；`rdma_control_result.validate()` 要求 recovery_required 时 status 为 RECOVERY_REQUIRED 且 final state 为 ERROR。`rdma_recovery_record.validate()` 要求 UNKNOWN hardware presence 必须带 ambiguous ticket 或 pending hardware step。

- [ ] **Step 5: 固定 package include 顺序并运行测试**

`rdma_model_pkg.sv` 顺序固定为：DMA mapping 后 include `rdma_resource_refs.svh`，context layouts 和 CMQ engine models 后 include `rdma_control_plane_models.svh`。

Run: `scripts/run_vcs53.sh core rdma_control_plane_models_test`

Expected: UVM warning/error/fatal 为 `0/0/0`。

- [ ] **Step 6: 提交**

```bash
git add src/model tests/unit/rdma_control_plane_models_test.svh \
  tests/rdma_unit_test_pkg.sv
git commit -m "feat: model control-plane ownership and recovery"
```

### Task 3: 迁移 Resource Snapshot 并引入 Hardware Projection/Key Policy

**Files:**
- Modify: `src/model/rdma_resources.svh:52`
- Create: `src/core/rdma_stag_key_policy.svh`
- Modify: `src/core/rdma_core_pkg.sv:8`
- Modify: `tests/unit/rdma_request_model_test.svh:650`
- Modify: `tests/unit/rdma_control_plane_models_test.svh`
- Create: `tests/mocks/rdma_mock_control_plane.svh`
- Modify: `tests/rdma_unit_test_pkg.sv:16`

- [ ] **Step 1: 写 backing-ref deep-copy 和 projection/key 失败测试**

替换旧 `backing_mappings` 断言，并加入：

```systemverilog
qp_resource.backing_refs.push_back(backing_ref);
cloned_object = qp_resource.clone();
if (!$cast(qp_resource_clone, cloned_object) ||
    qp_resource_clone.backing_refs[0] == qp_resource.backing_refs[0] ||
    qp_resource_clone.backing_refs[0].mapping ==
      qp_resource.backing_refs[0].mapping)
  `uvm_error("RESOURCE_REF_COPY", "resource backing graph aliases source")

status = policy.derive(mr_resource, stag_key);
expect_status("STAG_KEY", status, RDMA_SC_OK);
if (stag_key != mr_resource.handle.object_id[7:0])
  `uvm_error("STAG_KEY", "default key is not incarnation-derived")
```

- [ ] **Step 2: 运行测试确认红灯**

Run:

```bash
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_control_plane_models_test
```

Expected: 编译 FAIL，报告 `backing_refs` 或 `rdma_stag_key_policy` 未定义。

- [ ] **Step 3: 原子迁移 resource fields**

`rdma_resource` 用以下字段替换裸 mapping queue，并在 `do_copy()` 中逐项 clone：

```systemverilog
rdma_backing_ref backing_refs[$];
rdma_hmc_ref hmc_refs[$];
```

`rdma_mr` 用以下字段替换 DMA permission 字段：

```systemverilog
rdma_rdma_access_t access;
bit [11:0] mr_serial;
```

保留 `lkey/rkey`。validate 在 PROGRAMMED/ACTIVE/QUIESCING/ERROR 状态检查：24-bit index 与 `lkey[31:8]` 一致；remote access 存在时 `rkey == lkey`，否则 `rkey` 为 0 或 lkey。

- [ ] **Step 4: 实现可注入 key policy 和 mock**

```systemverilog
virtual class rdma_stag_key_policy extends uvm_object;
  function new(string name = "rdma_stag_key_policy");
    super.new(name);
  endfunction
  pure virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
endclass

class rdma_incarnation_stag_key_policy extends rdma_stag_key_policy;
  `uvm_object_utils(rdma_incarnation_stag_key_policy)
  function new(string name = "rdma_incarnation_stag_key_policy");
    super.new(name);
  endfunction
  virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
    stag_key = '0;
    if (mr == null || mr.handle == null ||
        mr.handle.kind != RDMA_RESOURCE_MR)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR STAG key source is invalid");
    stag_key = mr.handle.object_id[7:0];
    return rdma_status::success();
  endfunction
endclass
```

mock policy 返回配置的固定 key 并记录调用次数。

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_control_plane_models_test
```

Expected: 两个测试 `0/0/0`，且 `rg -n "backing_mappings" src tests` 无输出。

Commit:

```bash
git add src/model/rdma_resources.svh src/core/rdma_stag_key_policy.svh \
  src/core/rdma_core_pkg.sv tests
git commit -m "feat: track resource backing ownership and STAG keys"
```

### Task 4: 扩展 Resource Manager 生命周期与 Recovery Registry

**Files:**
- Modify: `src/core/rdma_resource_manager.svh:272`
- Modify: `tests/unit/rdma_resource_manager_test.svh`

- [ ] **Step 1: 写 local-ID width、状态转换、busy 和 recovery 测试**

测试文件内定义只用于边界注入的 subclass：

```systemverilog
class rdma_width_probe_manager extends rdma_resource_manager;
  function void set_next_local_id(rdma_resource_kind_e kind,
                                  int unsigned value);
    next_local_id[kind] = value;
  endfunction
endclass
```

分别把 PD/MR next ID 设置为 `16'hffff`/`24'hff_ffff`，最后一个 ID 成功，下一次返回 RESOURCE_EXHAUSTED，且 object serial/registry leak count 不变化。

新增以下行为检查：

```systemverilog
status = manager.activate(pd.handle);
expect_status("PD_ACTIVATE", status, RDMA_SC_OK);
status = manager.create_mr(binding, pd.handle, mr);
expect_status("MR_RESERVE", status, RDMA_SC_OK);
status = manager.begin_quiesce(pd.handle);
expect_status("PD_BUSY", status, RDMA_SC_RESOURCE_BUSY);

mr.iova.value = 64'h1000_0000;
mr.length = 64'h2000;
mr.lkey = {mr.local_mr_id[23:0], 8'h5a};
mr.rkey = mr.lkey;
mr.access = '{local_write:1'b1, remote_read:1'b1,
              remote_write:1'b0, memory_window_bind:1'b0,
              remote_atomic:1'b0};
status = manager.stage_allocated(mr);
expect_status("MR_STAGE", status, RDMA_SC_OK);
status = manager.commit_programmed(mr);
expect_status("MR_PROGRAM", status, RDMA_SC_OK);
expect_status("MR_ACTIVATE", manager.activate(mr.handle), RDMA_SC_OK);
```

再构造 recovery record，检查 `mark_error()`、`lookup_recovery()`、ERROR 状态禁止普通 release，以及 hardware ABSENT 且 pending steps 清空后才允许 `finalize_release()`。

- [ ] **Step 2: 在 53 上运行确认缺少 API**

Run: `scripts/run_vcs53.sh core rdma_resource_manager_test`

Expected: 编译 FAIL，报告 `activate`、`commit_programmed` 或 `mark_error` 未定义。

- [ ] **Step 3: 给 per-kind local ID 加硬件宽度上限**

在 `reserve_identity()` 分配前使用：

```systemverilog
protected function int unsigned local_id_limit(rdma_resource_kind_e kind);
  case (kind)
    RDMA_RESOURCE_PD: return 16'hffff;
    RDMA_RESOURCE_MR: return 24'hff_ffff;
    default: return 32'hffff_ffff;
  endcase
endfunction
```

free-list ID 和 next ID 都必须 `<= local_id_limit(kind)`；超过时返回 `RDMA_SC_RESOURCE_EXHAUSTED`，且不得消耗 object serial 或注册半成品 binding。

- [ ] **Step 4: 实现受控状态提交**

公开 API 固定为：

```systemverilog
virtual function rdma_status commit_programmed(rdma_resource candidate);
virtual function rdma_status stage_allocated(rdma_resource candidate);
virtual function rdma_status activate(rdma_handle handle);
virtual function rdma_status begin_quiesce(rdma_handle handle);
virtual function rdma_status restore_active(rdma_handle handle);
virtual function rdma_status mark_error(rdma_handle handle,
                                        rdma_recovery_record recovery);
virtual function rdma_status lookup_recovery(
  rdma_handle handle,
  output rdma_recovery_record recovery
);
virtual function rdma_status clear_recovery(rdma_handle handle);
virtual function rdma_status finalize_release(rdma_handle handle);
virtual function rdma_status release_reserved(rdma_handle handle);
virtual function rdma_status track_outstanding(
  rdma_handle handle,
  longint unsigned outstanding_id
);
virtual function rdma_status retire_outstanding(
  rdma_handle handle,
  longint unsigned outstanding_id
);
```

关键转换检查：

```systemverilog
if (registry[key].state != RDMA_RESOURCE_ACTIVE)
  return rdma_status::make(RDMA_SC_INVALID_STATE,
                           "only ACTIVE resource can begin quiesce");
if (has_dependents(registry[key]))
  return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                           "resource still has live dependents");
registry[key].state = RDMA_RESOURCE_QUIESCING;
```

`stage_allocated()` 要求 candidate handle 与 registry incarnation 相同、双方为 ALLOCATED、dynamic type 相同；它 deep-copy 完整 candidate 并保持 ALLOCATED，使 timeout 后 registry 仍拥有 key/backing authority。`commit_programmed()` 对 staged candidate 做同样的 identity/type 检查，强制 state PROGRAMMED、validate 成功后一次替换 registry。`activate()` 只允许 PD 的 ALLOCATED 或其他对象的 PROGRAMMED。

`track_outstanding()` 拒绝零 ID、重复 ID 和非 ACTIVE 资源；`retire_outstanding()` 拒绝未知 ID。`begin_quiesce()` 在 `outstanding_ids.size()!=0` 时返回 RESOURCE_BUSY。

- [ ] **Step 5: 实现 ERROR/recovery release gate**

`mark_error()` deep-copy recovery record。它允许按 exact registry key 把 stale generation 的已知 incarnation 标成 ERROR，但不允许普通 lookup/activate 绕过 generation 检查；该例外只服务 reset/recovery teardown。`finalize_release()` 对 ERROR 资源要求：

```systemverilog
recovery.hardware_presence == RDMA_HW_PRESENCE_ABSENT
recovery.pending_steps.size() == 0
```

否则返回 `RDMA_SC_RECOVERY_REQUIRED`。`force_release_key()` 删除 recovery side-table 后再回收 local ID。保留 `freeze()` 和 `release()` 作为兼容 wrapper，但 ACTIVE/ERROR 不得通过旧 API 绕过新 gate。

- [ ] **Step 6: 运行测试并提交**

Run: `scripts/run_vcs53.sh core rdma_resource_manager_test`

Expected: `0/0/0`，原有 stale-handle、generation 和 dependency cases 不退化。

Commit:

```bash
git add src/core/rdma_resource_manager.svh \
  tests/unit/rdma_resource_manager_test.svh
git commit -m "feat: commit recoverable resource lifecycle states"
```

### Task 5: 增加 CMQ Port、Mock 与 Ticket-specific Reconcile

**Files:**
- Create: `src/core/rdma_cmq_port.svh`
- Modify: `src/core/rdma_cmq_engine.svh:5195`
- Create: `src/core/rdma_cmq_engine_port_adapter.svh`
- Modify: `src/core/rdma_core_pkg.sv:10`
- Modify: `tests/mocks/rdma_mock_control_plane.svh`
- Create: `tests/unit/rdma_cmq_port_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 execute status、timeout ticket 和 reconcile 隔离测试**

测试 mock port：

```systemverilog
mock_cmq.fail_opcode(XTR_V1_OP_KEY_ALLOC,
                     rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                       "injected key failure"));
mock_cmq.execute(command, ticket, completion, status);
expect_status("CMQ_FAIL", status, RDMA_SC_DMA_PERMISSION);
if (ticket == null || mock_cmq.calls.size() != 1)
  `uvm_error("CMQ_FAIL", "mock did not retain command/ticket")

mock_cmq.timeout_opcode(XTR_V1_OP_KEY_ALLOC);
mock_cmq.execute(command, ticket, completion, status);
expect_status("CMQ_TIMEOUT", status, RDMA_SC_TIMEOUT);
mock_cmq.push_late_completion(ticket, rdma_status::success());
mock_cmq.reconcile(ticket, terminal_known, completion, status);
if (!status.ok() || !terminal_known || !completion.status.ok())
  `uvm_error("CMQ_RECONCILE", "late success was not reconciled")
```

真实 engine case 预装两个 timeout ticket，仅 reconcile 第一个，并断言第二个 diagnostic/quarantine 未被消费。

- [ ] **Step 2: 在 53 上运行确认 port 未定义**

Run: `scripts/run_vcs53.sh core rdma_cmq_port_test`

Expected: 编译 FAIL，报告 `rdma_cmq_port` 未定义。

- [ ] **Step 3: 实现抽象 port 和 mock**

抽象接口使用“最终 operation status”契约：submit/wait infrastructure 失败或 completion.status 均写入 `status`；timeout 时必须保留非 null ticket。

mock 保存以下 detached call record，并为每个 opcode 维护 FIFO outcome；不得用单个 associative value 覆盖同 opcode 的多次 create/rollback 调用。

```systemverilog
class rdma_mock_cmq_call extends uvm_object;
  longint unsigned sequence;
  bit [7:0] opcode;
  rdma_cmq_command_desc command;
  rdma_cmq_ticket ticket;
endclass

class rdma_mock_cmq_port extends rdma_cmq_port;
  rdma_mock_cmq_call calls[$];
  function void fail_opcode(bit [7:0] opcode, rdma_status status);
  function void timeout_opcode(bit [7:0] opcode);
  function void push_late_completion(rdma_cmq_ticket ticket,
                                     rdma_status status);
  function void get_opcodes(output bit [7:0] values[$]);
endclass
```

mock ticket 的 Function、opcode key、deadline 和 command ID 必须来自 command snapshot；timeout completion 的 status 为 TIMEOUT 且 raw CQE 为 null，普通 completion 使用合法 64B mock raw CQE。

- [ ] **Step 4: 给 engine 增加定向 reconcile**

公开 task：

```systemverilog
task reconcile_ticket(
  rdma_cmq_ticket ticket,
  output bit terminal_known,
  output rdma_cmq_completion completion,
  output rdma_status status
);
```

它在 engine lock 内校验 ticket authority，执行 `expire_locked()`/`poll_locked()`，只删除 matching ticket 的 terminal completion 或 late diagnostic。其他 ticket 的 `terminal_fifo`、`diagnostic_fifo` 和 quarantine slot 保持原顺序。没有 late terminal 时返回 `status=OK, terminal_known=0, completion=null`。

- [ ] **Step 5: 实现生产 adapter**

```systemverilog
class rdma_cmq_engine_port_adapter extends rdma_cmq_port;
  `uvm_object_utils(rdma_cmq_engine_port_adapter)
  protected rdma_cmq_engine engines[string];
  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h:%08h", owner.function_uid,
                     owner.object_id, owner.generation);
  endfunction
  function rdma_status bind_engine(rdma_function_handle owner,
                                   rdma_cmq_engine engine);
    string key;
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION ||
        engine == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ engine binding is invalid");
    key = function_key(owner);
    if (engines.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CMQ engine binding already exists");
    engines[key] = engine;
    return rdma_status::success();
  endfunction
  virtual task execute(rdma_cmq_command_desc command,
                       output rdma_cmq_ticket ticket,
                       output rdma_cmq_completion completion,
                       output rdma_status status);
    rdma_status wait_status;
    rdma_cmq_engine engine;
    ticket = null;
    completion = null;
    if (command == null || command.function_h == null ||
        !engines.exists(function_key(command.function_h))) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Function has no bound CMQ engine");
      return;
    end
    engine = engines[function_key(command.function_h)];
    engine.submit(command, ticket, status);
    if (status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CMQ submit returned null status");
      return;
    end
    if (!status.ok()) return;
    engine.wait_for(ticket, completion, wait_status);
    if (wait_status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CMQ wait returned null status");
      return;
    end
    if (!wait_status.ok()) begin
      status = rdma_cmq_clone_status_value(wait_status);
      return;
    end
    if (completion == null || completion.status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CMQ engine returned no completion status");
      return;
    end
    status = rdma_cmq_clone_status_value(completion.status);
  endtask
  virtual task reconcile(rdma_cmq_ticket ticket,
                         output bit terminal_known,
                         output rdma_cmq_completion completion,
                         output rdma_status status);
    rdma_cmq_engine engine;
    if (ticket == null || ticket.function_h == null ||
        !engines.exists(function_key(ticket.function_h))) begin
      terminal_known = 1'b0;
      completion = null;
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ticket has no bound CMQ engine");
      return;
    end
    engine = engines[function_key(ticket.function_h)];
    engine.reconcile_ticket(ticket, terminal_known, completion, status);
  endtask
endclass
```

adapter 的 route key 包含 generation；不同 Function/generation 的 engine 不共享完成队列。测试分别 bind 两个 engine，并确认 command A/B 路由到对应实例。

- [ ] **Step 6: 运行 port 和 engine 回归并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_port_test
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected: 两个测试 `0/0/0`。

Commit:

```bash
git add src/core tests/mocks/rdma_mock_control_plane.svh \
  tests/unit/rdma_cmq_port_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: adapt CMQ engine behind a recoverable port"
```

### Task 6: 建立 Control Plane Shell 和纯软件 PD 生命周期

**Files:**
- Create: `src/core/rdma_control_plane.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_control_plane_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 configure、PD create/no-CMQ 和 busy destroy 测试**

```systemverilog
status = control.configure(manager, mock_cmq, key_policy, mock_mem,
                           hmc_allocator, 1us);
expect_status("CONFIGURE", status, RDMA_SC_OK);
control.create_pd(binding, create_pd_req, pd, result);
if (!result.ok() || pd == null || pd.state != RDMA_RESOURCE_ACTIVE)
  `uvm_error("PD_CREATE", "PD did not become ACTIVE")
if (mock_cmq.calls.size() != 0)
  `uvm_error("PD_CREATE", "software PD emitted a CMQ command")

status = manager.create_mr(binding, pd.handle, reserved_mr);
expect_status("MR_DEP", status, RDMA_SC_OK);
control.destroy_pd(binding, pd.handle, result);
expect_status("PD_BUSY", result.status, RDMA_SC_RESOURCE_BUSY);
```

- [ ] **Step 2: 在 53 上运行确认 control plane 未定义**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: 编译 FAIL，报告 `rdma_control_plane` 未定义。

- [ ] **Step 3: 实现配置、不变量 helper 和 Function lock table**

control plane 保存注入引用、默认 timeout、单调 nonzero transaction ID，以及：

```systemverilog
protected semaphore lock_table_guard;
protected semaphore function_locks[string];

protected task acquire_function_lock(
  rdma_function_handle owner,
  output semaphore function_lock
);
  string key;
  key = $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  lock_table_guard.get(1);
  if (!function_locks.exists(key))
    function_locks[key] = new(1);
  function_lock = function_locks[key];
  lock_table_guard.put(1);
  function_lock.get(1);
endtask
```

所有 public task 使用同一 release path 归还 semaphore。configure 拒绝 null manager/CMQ/key policy、零 timeout 和重复配置。

- [ ] **Step 4: 实现 PD create/destroy**

create 顺序固定：validate request/binding identity、`manager.create_pd()`、`manager.activate()`、重新 lookup ACTIVE snapshot 到输出 `pd`。失败时 `release_reserved()`；result 记录 RESOURCE_RESERVED 和 REGISTRY_ACTIVE。不得把 manager 最初返回的 ALLOCATED clone 当成最终输出。

destroy 顺序固定：lookup ACTIVE PD、`begin_quiesce()`、`finalize_release()`。RESOURCE_BUSY 不改变 PD 状态。PD 路径不得访问 cmq/host_mem/HMC。

- [ ] **Step 5: 运行测试并提交**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: PD cases `0/0/0`，mock CMQ call count 为零。

Commit:

```bash
git add src/core/rdma_control_plane.svh src/core/rdma_core_pkg.sv \
  tests/unit/rdma_control_plane_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: create and destroy software PD resources"
```

### Task 7: 实现 Borrowed MR 的 KEY_ALLOC 注册路径

**Files:**
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `tests/unit/rdma_control_plane_test.svh`

- [ ] **Step 1: 写 borrowed PBL0 成功、projection 和权限失败测试**

成功 case：

```systemverilog
backing = make_borrowed_pbl0(binding, mapping);
control.register_mr(binding, mr_req, backing, mr, result);
if (!result.ok() || mr == null || mr.state != RDMA_RESOURCE_ACTIVE)
  `uvm_error("MR_REGISTER", "borrowed MR did not become ACTIVE")
if (mock_cmq.calls.size() != 1 ||
    mock_cmq.calls[0].opcode != XTR_V1_OP_KEY_ALLOC)
  `uvm_error("MR_REGISTER", "ordinary MR did not use KEY_ALLOC")
if (mr.lkey[31:8] != mr.local_mr_id[23:0] ||
    mr.lkey[7:0] != key_policy.fixed_key)
  `uvm_error("MR_KEY", "STAG projection/key is wrong")
```

从 captured command body cast `rdma_mrt_model`，断言 `mr_h.object_id==local_mr_id`、`pd_h.object_id==local_pd_id`，同时 registry handles 保持 kind-tagged incarnation。

负例覆盖 mapping Function/generation/BDF/PASID 不匹配、IOVA range overflow、缺 device_read、remote-write 缺 device_write、remote-atomic 缺 atomic。

再增加 PBL1/PBL2 成功行：PBL1 捕获 body 的 pba0/pba1；PBL2 使用 `hmc_allocator.lookup()` 可验证的 borrowed HMC ref，捕获 body 的 first-PBL index。PBL2 lease Function/generation/kind/index 任一不匹配都必须在 CMQ 前失败。

- [ ] **Step 2: 运行测试确认 register 仍未实现**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: FAIL，MR case 返回 INVALID_STATE 或 mock CMQ call count 为零。

- [ ] **Step 3: 实现 descriptor authority 和 projection helpers**

增加：

```systemverilog
protected function rdma_handle project_handle(
  rdma_handle software_h,
  int unsigned local_id,
  rdma_resource_kind_e expected_kind
);
```

返回新 handle，复制 Function UID/generation/kind，只把 object_id 设为 local ID。该 handle 只能进入 context/body，不能传给 manager lookup。

`validate_backing()` 对每个 mapping 调用 `check_access()`，并验证 request range 被 descriptor 覆盖；PBL0/PBL1 的 PBA 必须等于 backing references 的 backing address，PBL2 必须带匹配 first index 的 active HMC ref。

DMA authority 由 access 明确映射：

```systemverilog
required_permissions.device_read = 1'b1;
required_permissions.device_write = request.access.local_write ||
                                    request.access.remote_write ||
                                    request.access.remote_atomic;
required_permissions.atomic = request.access.remote_atomic;
required_direction = required_permissions.device_write ?
                     RDMA_DMA_BIDIRECTIONAL : RDMA_DMA_DEVICE_READ;
```

- [ ] **Step 4: 构造 authoritative MR 和 KEY_ALLOC command**

核心字段：

```systemverilog
mr.iova = request.iova;
mr.length = request.length;
mr.access = request.access;
mr.mr_serial = mr.handle.object_id[11:0];
mr.lkey = {mr.local_mr_id[23:0], stag_key};
mr.rkey = (request.access.remote_read || request.access.remote_write ||
           request.access.remote_atomic) ? mr.lkey : 32'b0;
```

MRT model：

```systemverilog
mrt.mr_h = project_handle(mr.handle, mr.local_mr_id, RDMA_RESOURCE_MR);
mrt.pd_h = project_handle(pd.handle, pd.local_pd_id, RDMA_RESOURCE_PD);
mrt.state = RDMA_CONTEXT_VALID;
mrt.iova = mr.iova;
mrt.length = mr.length;
mrt.lkey = mr.lkey;
mrt.rkey = mr.rkey;
mrt.access = mr.access;
mrt.object_type = 2'b0;
mrt.page_layout = clone_page_layout(backing.page_layout);
mrt.page_layout.mr_serial = mr.mr_serial;
```

command key 为 profile `xtr_v1`、opcode KEY_ALLOC、variant `key_alloc`，body 为 MRT model，timeout 为 configured timeout。

- [ ] **Step 5: 提交状态并处理明确失败**

顺序：reserve MR、填充 authoritative candidate、`stage_allocated(mr)`、CMQ execute、`commit_programmed(mr)`、`activate(mr.handle)`、重新 lookup ACTIVE snapshot 到输出 `mr`。KEY_ALLOC 明确失败时不发 deregister，释放 reservation；borrowed refs 不 release。

KEY_ALLOC timeout 时保留 ticket、mark ERROR、hardware presence UNKNOWN，返回 RECOVERY_REQUIRED。

- [ ] **Step 6: 运行测试并提交**

Run:

```bash
scripts/run_vcs53.sh core rdma_control_plane_test
scripts/run_vcs53.sh core rdma_xtr_v1_context_body_codec_test
```

Expected: 两个测试 `0/0/0`。

Commit:

```bash
git add src/core/rdma_control_plane.svh \
  tests/unit/rdma_control_plane_test.svh
git commit -m "feat: register borrowed MR through KEY_ALLOC"
```

### Task 8: 实现 Owned Host-memory Helper 和 Create Rollback

**Files:**
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `tests/mocks/rdma_mock_adapters.svh:257`
- Modify: `tests/mocks/rdma_mock_control_plane.svh`
- Modify: `tests/unit/rdma_control_plane_test.svh`

- [ ] **Step 1: 给 mock host_mem 增加 live-allocation 观察器并写失败矩阵**

```systemverilog
function int unsigned live_allocations();
  int unsigned count;
  count = 0;
  foreach (regions[i])
    if (regions[i].mapping != null &&
        regions[i].mapping.state == RDMA_MAPPING_ACTIVE)
      count++;
  return count;
endfunction
```

在 `rdma_mock_control_plane.svh` 增加 `rdma_fault_inject_resource_manager`，覆盖 Task 4 的 virtual transition API，并用 `fail_next_transition("commit_programmed", status)` 或 `fail_next_transition("activate", status)` 单次注入错误。测试 null/mismatched DMA context、remote-atomic helper rejection、allocate failure、KEY_ALLOC failure、commit_programmed failure、activate failure 和 rollback deregister failure。每行保存 baseline，检查 owned mapping live count、manager leak count、CMQ opcode sequence 和 final state。

- [ ] **Step 2: 运行测试确认 owned helper 未实现**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: FAIL，`alloc_and_register_mr()` 没有 allocation 或失败路径泄漏 mapping。

- [ ] **Step 3: 实现 owned PBL0 helper**

`alloc_and_register_mr()` 接受 caller 提供的 `rdma_dma_request_context`，但必须验证 function_h 与 binding owner 相同、requester BDF 与 binding BDF 相同、owner_h 为 null。PASID 直接使用经过验证的 context 快照，不从其他字段猜测。调用：

```systemverilog
host_mem.allocate(dma_context, request.length, alignment,
                  required_direction(request.access), mapping);
```

生成 PBL0 descriptor：pba0=mapping.backing_addr，host page size 4K，VA-based，ownership CONTROL_PLANE。alignment 小于 4096、非 power-of-two 或 host_mem 未注入时返回 INVALID_ARGUMENT/INVALID_STATE。由于现有 host_mem allocate contract 不能请求 atomic permission，owned helper 对 `remote_atomic=1` 返回 UNSUPPORTED_OPCODE；atomic MR 只能注册带 atomic authority 的 borrowed mapping。

- [ ] **Step 4: 实现显式逆序 action rollback**

事务只记录已完成步骤。create rollback 顺序固定：

```text
HW_KEY_ALLOCATED -> MR_DEREGISTER
HMC_ATTACHED      -> release owned HMC refs
BACKING_ATTACHED  -> release owned mappings
RESOURCE_RESERVED -> release_reserved
```

commit_programmed/activate 失败发生在 KEY_ALLOC success 之后时必须构造 `rdma_xtr_v1_mr_deregister_body` 并发送 MR_DEREGISTER。commit 前失败且 deregister 成功时使用 `release_reserved()`；activate 失败时资源已经 PROGRAMMED，先 `mark_error()` 为 hardware ABSENT、pending 清空，再 `finalize_release()`。rollback status 全部追加到 result；任一步失败就 mark ERROR，不继续执行依赖该步成功才能安全执行的释放。

- [ ] **Step 5: 运行测试并提交**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: 正常/完整 rollback 的 live allocation 回到 baseline；rollback failure 保留一项 ERROR resource 和一项 live owned mapping，UVM `0/0/0`。

Commit:

```bash
git add src/core/rdma_control_plane.svh tests/mocks/rdma_mock_adapters.svh \
  tests/mocks/rdma_mock_control_plane.svh \
  tests/unit/rdma_control_plane_test.svh
git commit -m "feat: roll back owned MR registrations"
```

### Task 9: 实现 MR Deregister、PBL2 Flush 和 Cleanup Gate

**Files:**
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `tests/unit/rdma_control_plane_test.svh`

- [ ] **Step 1: 写 PBL0/PBL2 顺序、borrowed/owned cleanup 和 busy 测试**

```systemverilog
bit [7:0] observed_opcodes[$];

control.deregister_mr(binding, borrowed_mr.handle, result);
if (!result.ok() || mock_mem.live_allocations() != borrowed_baseline)
  `uvm_error("MR_DEREG_BORROWED", "borrowed mapping was released")

control.deregister_mr(binding, pbl2_mr.handle, result);
mock_cmq.get_opcodes(observed_opcodes);
if (observed_opcodes != '{XTR_V1_OP_OCC_FLUSH,
                          XTR_V1_OP_MR_DEREGISTER,
                          XTR_V1_OP_TQ_FLUSH})
  `uvm_error("MR_DEREG_PBL2", "PBL2 command order is wrong")
```

PBL2 分别构造 borrowed lease 和 ownership 已转移给控制面的 lease：borrowed 注销后 HMC lease 仍 active，owned 注销后 `hmc_allocator.check_leaks()` 返回零。通过 `manager.track_outstanding(mr.handle, 64'h55)` 建立 authoritative outstanding 后，deregister 必须返回 RESOURCE_BUSY 且保持 ACTIVE、无 CMQ 调用；调用 `retire_outstanding()` 后同一 MR 才能 quiesce。

- [ ] **Step 2: 运行测试确认销毁路径未实现**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: FAIL，MR 未释放或 opcode 顺序不匹配。

- [ ] **Step 3: 实现 quiesce 和 typed destroy bodies**

- PBL2 OCC body：`mr_serial_flush=1`、`pble=1`、`mr_serial=mr.mr_serial`，其余 flag/addresses 为零。
- dereg body：projection MR handle、`stag_key=mr.lkey[7:0]`、`next_state=RDMA_CONTEXT_INVALID`。
- drain body：`rdma_xtr_v1_cmq_empty_body`，opcode TQ_FLUSH、variant `tq_flush`。

begin_quiesce 前拒绝非空 outstanding IDs。PBL0/PBL1 跳过 OCC；默认 xtr_v1 policy 在成功 deregister 后执行 TQ flush。

- [ ] **Step 4: 实现 destroy failure state table**

```text
OCC 明确失败                 -> restore ACTIVE
MR_DEREGISTER 明确失败       -> restore ACTIVE
OCC/MR_DEREGISTER timeout    -> ERROR, hardware UNKNOWN
MR_DEREGISTER 成功后续失败   -> ERROR, hardware ABSENT
全部硬件步骤成功             -> release owned refs -> finalize_release
```

owned release 失败不得 finalize；borrowed refs 直接标记 detached，不调用 host_mem/HMC release。

- [ ] **Step 5: 运行测试并提交**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: 所有销毁/失败表 case `0/0/0`，opcode 顺序精确匹配。

Commit:

```bash
git add src/core/rdma_control_plane.svh \
  tests/unit/rdma_control_plane_test.svh
git commit -m "feat: quiesce and deregister MR resources"
```

### Task 10: 实现 Timeout、Rollback Failure 和幂等 Recovery

**Files:**
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `tests/unit/rdma_control_plane_test.svh`

- [ ] **Step 1: 写 late success、late failure、unknown 和 cleanup retry 测试**

覆盖：

```systemverilog
mock_cmq.timeout_opcode(XTR_V1_OP_KEY_ALLOC);
control.register_mr(binding, req, backing, mr, result);
expect_status("TIMEOUT", result.status, RDMA_SC_RECOVERY_REQUIRED);
if (mr == null || mr.state != RDMA_RESOURCE_ERROR)
  `uvm_error("TIMEOUT", "ambiguous MR was discarded")

expect_status("LOOKUP_RECOVERY",
              manager.lookup_recovery(result.resource_h, recovery_record),
              RDMA_SC_OK);
mock_cmq.push_late_completion(recovery_record.ambiguous_ticket,
                              rdma_status::success());
control.recover_resource(binding, result.resource_h, recovery_result);
if (!recovery_result.ok())
  `uvm_error("RECOVER_LATE_SUCCESS", "late success was not undone")
```

另测 late KEY_ALLOC failure 只做 local cleanup；deregister 已成功但 host release 失败时，recovery 只重试 release，MR_DEREGISTER call count 不增加；连续调用两次 recovery 第二次返回 released/invalid-state contract，不重复 side effect。

- [ ] **Step 2: 运行测试确认 recovery 未完成**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: FAIL，ERROR resource 无法恢复或重复执行 delete/release。

- [ ] **Step 3: 实现 recovery dispatcher**

`recover_resource()` 只接受 ERROR。若 `ambiguous_ticket != null`，先调用 CMQ port reconcile：

```systemverilog
cmq_port.reconcile(record.ambiguous_ticket, terminal_known,
                   completion, reconcile_status);
```

- `terminal_known=0`：保持原 recovery record，返回 RECOVERY_REQUIRED。
- late success：把 hardware presence 更新为 PRESENT/ABSENT（根据原 command step），继续 pending undo。
- late hardware failure：把未成功的 hardware step 从 pending 移除，继续 local cleanup。
- RESET_CANCELLED：保持 UNKNOWN；仅 Function reset teardown 可以提供硬件失效证明。

- [ ] **Step 4: 每完成一步原子更新 recovery record**

每个 delete/release 成功后先更新 pending/completed，再执行下一步。发生新失败时覆盖 registry 中的 frozen recovery snapshot，但保留最初 primary_status 和累计 rollback_statuses。全部 pending 清空且 hardware ABSENT 后调用 `finalize_release()`。

- [ ] **Step 5: 运行测试并提交**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: recovery cases `0/0/0`；调用计数证明幂等。

Commit:

```bash
git add src/core/rdma_control_plane.svh \
  tests/unit/rdma_control_plane_test.svh
git commit -m "feat: recover ambiguous control-plane transactions"
```

### Task 11: 验证 Function 并发和 Generation Fence

**Files:**
- Modify: `tests/mocks/rdma_mock_control_plane.svh`
- Modify: `tests/unit/rdma_control_plane_test.svh`
- Modify: `src/core/rdma_control_plane.svh`

- [ ] **Step 1: 给 mock CMQ 加 blocking gate 并写并发测试**

mock port 为指定 command call 提供 `uvm_event entered` 和 `uvm_event release_gate`。测试 fork：

```systemverilog
fork
  control.register_mr(binding_a, req_a, backing_a, mr_a, result_a);
  control.register_mr(binding_a, req_a2, backing_a2, mr_a2, result_a2);
join_none
mock_cmq.wait_until_entered(1);
if (mock_cmq.entered_count() != 1)
  `uvm_error("SAME_FUNCTION_LOCK", "same Function was not serialized")
mock_cmq.release_all();
wait fork;
```

另用 binding A/B 启动两个 register，两个都应在 gate 前进入 CMQ。mock port 验证控制面并发；`rdma_cmq_engine_port_adapter` 的 route 测试为 A/B 分别 bind 独立 engine，保证生产路径也不把两个 Function 送到同一 prepared engine。第三个 case 在 KEY_ALLOC outstanding 时递增 binding generation，最终不得发布 ACTIVE。

- [ ] **Step 2: 运行测试观察并发/generation 失败**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: 若锁 key 或 commit fence 不正确，same-Function entered count 为 2，或 stale MR 进入 ACTIVE。

- [ ] **Step 3: 在三个边界执行 generation fence**

统一 helper 比较 binding source 与事务快照：

```systemverilog
protected function rdma_status generation_fence(
  rdma_function_binding binding,
  rdma_function_handle expected_owner
);
  if (binding == null || expected_owner == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "generation fence authority is null");
  if (binding.function_uid != expected_owner.function_uid ||
      binding.global_function_id != expected_owner.object_id)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "generation fence Function differs");
  if (binding.generation != expected_owner.generation)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             "Function generation changed during transaction");
  return rdma_status::success();
endfunction
```

在入口 snapshot 后、CMQ terminal 后、activate/finalize 前调用。CMQ success 后 generation stale 时，不通过普通 stale lookup 假装释放；对精确旧 incarnation 执行可证明的硬件 rollback，或用 recovery-only `mark_error()` 保留到 Function reset teardown。timeout 仍走 ERROR recovery。

- [ ] **Step 4: 运行并发测试和 CMQ multi-outstanding 回归**

Run:

```bash
scripts/run_vcs53.sh core rdma_control_plane_test
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected: 两个测试 `0/0/0`。

- [ ] **Step 5: 提交**

```bash
git add src/core/rdma_control_plane.svh \
  tests/mocks/rdma_mock_control_plane.svh \
  tests/unit/rdma_control_plane_test.svh
git commit -m "feat: fence concurrent control-plane transactions"
```

### Task 12: 真实 CMQ Engine 组合测试、全回归和路线图更新

**Files:**
- Create: `tests/unit/rdma_control_plane_cmq_engine_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `docs/superpowers/plans/2026-08-20-rdma-uvm-driver-architecture.md:1064`

- [ ] **Step 1: 写 production adapter 组合测试**

测试实例化：

```text
rdma_control_plane
-> rdma_cmq_engine_port_adapter
-> rdma_cmq_engine
-> rdma_xtr_v1_cmq_hw_profile
-> rdma_mock_host_mem + rdma_doorbell_scheduler + mock PCIe
```

completion responder 在检测到 CMQ SQ doorbell 后，从 SQE 读取 WQE index/wrap/opcode，为 KEY_ALLOC、MR_DEREGISTER 和 TQ_FLUSH 写入合法 64B success CQE，再允许 engine poll。测试执行 owned PBL0 MR register+deregister，并断言：

success CQE helper 固定为：

```systemverilog
function automatic rdma_hw_image make_xtr_success_cqe(
  bit [7:0] opcode,
  bit [4:0] wqe_index,
  bit wrap,
  bit owner,
  int unsigned generation
);
  rdma_hw_image image;
  bit [63:0] qword0;
  image = rdma_hw_image::type_id::create("control_success_cqe");
  repeat (64) image.bytes.push_back(8'h00);
  image.length = 64;
  image.alignment = 64;
  image.endian = RDMA_ENDIAN_BIG;
  image.image_kind = RDMA_IMAGE_CMQ_CQE;
  image.hardware_version = 1;
  image.function_generation = generation;
  image.write_target_kind = RDMA_HW_TARGET_NONE;
  qword0 = '0;
  qword0[63] = owner;
  qword0[45] = wrap;
  qword0[44:40] = wqe_index;
  qword0[39:32] = opcode;
  for (int unsigned i = 0; i < 8; i++)
    image.bytes[i] = qword0[63 - (i * 8) -: 8];
  return image;
endfunction
```

adapter 在 test setup 中显式执行 `bind_engine(binding.make_handle(), engine)`；responder 把 image bytes 写到 CMQ mapping 的 `2048 + cq_index*64`，不能调用 engine 私有 helper。

```systemverilog
if (!register_result.ok() || !destroy_result.ok())
  `uvm_error("REAL_ENGINE", "control-plane lifecycle failed")
if (engine.outstanding_count() != 0 || engine.quarantine_count() != 0)
  `uvm_error("REAL_ENGINE", "CMQ ticket leaked")
if (mock_mem.live_allocations() != cmq_backing_only_baseline)
  `uvm_error("REAL_ENGINE", "MR backing leaked")
```

- [ ] **Step 2: 在 53 上先运行，确认组合测试红灯**

Run: `scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test`

Expected: 在 responder/adapter 接线完成前 FAIL，报告 completion timeout 或 lifecycle status 非 OK。

- [ ] **Step 3: 完成 responder 接线并运行组合测试**

复用现有 CMQ engine test 的 SQ/CQ owner、64B endian 和 doorbell ordering 规则，不绕过 host_mem image。responder 只能写 CQ backing 并推进 hardware owner；不得直接调用 control plane 或篡改 engine 内部 registry。

Run: `scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test`

Expected: UVM warning/error/fatal 为 `0/0/0`。

- [ ] **Step 4: 更新总路线图**

在原 Task 14 下记录：

```markdown
- [x] Task 14A：事务框架、CMQ port、PD/MR lifecycle（本计划）
- [ ] Task 14B：CQ/SRQ/CEQ/AEQ lifecycle
- [ ] Task 14C：QP create/modify/destroy lifecycle
```

不要勾选整个 Task 14。

- [ ] **Step 5: 在 53 上运行完整验证**

Run:

```bash
python3 -m pytest -q
scripts/run_vcs53.sh xtr_defs regression
scripts/run_vcs53.sh core regression
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected:

- pytest 收集到的全部测试 PASS；
- xtr frozen checker 输出 PASS；
- core regression 所有 UVM 测试 warning/error/fatal 为 `0/0/0`；
- host_mem integration 为 `0/0/0`。

- [ ] **Step 6: 执行交付审计**

Run:

```bash
rg -n "backing_mappings|MR_REGISTER" src/core/rdma_control_plane.svh \
  src/model/rdma_resources.svh
git diff --check
git status --short
```

Expected: `backing_mappings` 无匹配；control plane 中 `MR_REGISTER` 无匹配；diff check 无输出；status 只显示本任务预期文件。

- [ ] **Step 7: 提交最终组合测试和文档**

```bash
git add tests/unit/rdma_control_plane_cmq_engine_test.svh \
  tests/rdma_unit_test_pkg.sv \
  docs/superpowers/plans/2026-08-20-rdma-uvm-driver-architecture.md
git commit -m "test: integrate PD MR control plane with CMQ engine"
```

## 最终完成条件

- PD create/destroy 从不触发 CMQ。
- borrowed、owned、PBL0、PBL1、PBL2 的 ownership/command contract 可由测试观察。
- 普通 MR 只使用 KEY_ALLOC，软件 handle 与硬件 projection 不混用。
- 每个 create/destroy 故障点都有确定的 rollback 或 ERROR recovery 结果。
- timeout ticket 不导致 STAG/mapping/HMC/local ID 提前复用。
- recovery 幂等，rollback error chain 可查询。
- 同 Function 串行、不同 Function 并行、generation 变化不提交旧资源。
- mock CMQ 单元测试和真实 CMQ engine 组合测试都通过。
- 53 上 core/full host_mem 回归和 Python/xtr checker 全部通过。
