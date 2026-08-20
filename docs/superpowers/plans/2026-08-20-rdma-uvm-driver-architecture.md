# RDMA UVM Driver Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个面向真实 RDMA DUT、核心无外部 VIP 强依赖、能够生成资源上下文/队列数据/doorbell 并显式管理 PCIe PF/VF 映射的 UVM 驱动。

**Architecture:** 实现分为语义请求、运行时资源、硬件字段模型和硬件映像四层；资源、codec、CMQ、数据队列、doorbell 和 Function 生命周期由独立组件负责。`host_mem`、`pcie_work`、`net_packet`、`axis_vip` 只通过可注入 adapter 接入，真实 DUT 始终是 DUT 模式下的唯一设备状态权威。

**Tech Stack:** SystemVerilog、UVM 1.2、Synopsys VCS、GNU Make、Bash；可选依赖为 `host_mem`、`pcie_work`、`net_packet` 和 `axis_vip`。

---

## 1. 实施边界与固定依据

本计划实现设计规格：
`docs/superpowers/specs/2026-08-20-rdma-uvm-driver-architecture-design.md`。

硬件定义以 53 主机 `/home/ubuntu/workspace/Desktop.zip` 中以下源码为基准：

- `dpu_kernel_rdma-version_0.1.32`，提交 `491faf2ba42627fffd4dd027607299c8bb591ec2`；
- `dpu_user_rdma-version_0.1.32`，提交 `6543ee80057ea3387cc2265f5e8cf8311839ffb3`；
- `host_mem` master，提交 `3b9e000d5df4d10efbb3029f43605e0362e0caca`；
- `pcie_work` main，提交 `cf24ddc01680e4da15c2670f21bcf87dcd9905bc`；
- `net_packet` master，提交 `6766c4f042484814548481065328ffbcffab590f`；
- `axis_vip` master，提交 `8bbd960f4f5b53d3c7c7026c531a6c317b8bd5de`；
- 第一版硬件 profile 命名为 `xtr_v1`，不能使用 `mlx5`/`mlx6`/`mlx7` 名字伪装成该 DUT 格式；mlx 驱动只用于资源生命周期和 verbs 行为参考。

第一轮交付的确定范围：

- 资源：Function、PD、MR、CQ、QP、SRQ、CMQ、CEQ、AEQ；
- QP transport：RC、UD、URC；
- 数据面 opcode：SEND、SEND_WITH_IMM、SEND_WITH_INV、WRITE、WRITE_WITH_IMM、READ、ATOMIC_CMP_AND_SWP、ATOMIC_FETCH_AND_ADD、BIND_MW、LOCAL_INV、REG_MR、FLUSH、RQE；
- CMQ：QPC/CQC/CEQC/AEQC/SRFQC 的 create/modify/delete/query，MR register/deregister，QP/TQ/OCC flush；其他 `xtrdma_cmq_opcode` 必须由 registry 返回 `RDMA_SC_UNSUPPORTED_OPCODE`，不能编码为零值 SQE；
- doorbell：CMQ SQ、SQ、RQ、SRQ、CQ、CEQ、AEQ、QP flush 和 TQ flush；
- 地址宽度：所有 backing、IOVA、HMC/FVM、BAR 地址均为 64 bit，config offset 为 12 bit；
- PCIe：真实 SR-IOV VF 默认一 VF 对应一个 RDMA logical Function；共享 PF 模式保留在模型中，但第一轮不启用。

## 2. 锁定的文件结构

```text
rdma_work/
├── src/
│   ├── types/
│   │   ├── rdma_types_pkg.sv
│   │   ├── rdma_address_types.svh
│   │   ├── rdma_enum_types.svh
│   │   ├── rdma_identity_types.svh
│   │   └── rdma_status.svh
│   ├── model/
│   │   ├── rdma_model_pkg.sv
│   │   ├── rdma_handle.svh
│   │   ├── rdma_hw_image.svh
│   │   ├── rdma_dma_mapping.svh
│   │   ├── rdma_function_binding.svh
│   │   ├── rdma_semantic_requests.svh
│   │   ├── rdma_resources.svh
│   │   ├── rdma_context_models.svh
│   │   └── rdma_queue_models.svh
│   ├── adapter/
│   │   ├── rdma_adapter_pkg.sv
│   │   ├── rdma_host_mem_api.svh
│   │   ├── rdma_pcie_api.svh
│   │   ├── rdma_function_table_api.svh
│   │   └── rdma_net_api.svh
│   ├── codec/
│   │   ├── rdma_codec_pkg.sv
│   │   ├── rdma_codec_base.svh
│   │   ├── rdma_codec_registry.svh
│   │   ├── rdma_bit_packer.svh
│   │   └── xtr_v1/
│   │       ├── rdma_xtr_v1_defs.svh
│   │       ├── rdma_xtr_v1_context_codecs.svh
│   │       ├── rdma_xtr_v1_cmq_codecs.svh
│   │       ├── rdma_xtr_v1_queue_codecs.svh
│   │       ├── rdma_xtr_v1_doorbell_codecs.svh
│   │       └── rdma_xtr_v1_error_codec.svh
│   ├── core/
│   │   ├── rdma_core_pkg.sv
│   │   ├── rdma_resource_manager.svh
│   │   ├── rdma_hmc_allocator.svh
│   │   ├── rdma_control_plane.svh
│   │   ├── rdma_doorbell_scheduler.svh
│   │   ├── rdma_cmq_engine.svh
│   │   ├── rdma_sq_engine.svh
│   │   ├── rdma_rq_engine.svh
│   │   ├── rdma_completion_engine.svh
│   │   ├── rdma_function_manager.svh
│   │   ├── rdma_responder_registry.svh
│   │   ├── rdma_scoreboard.svh
│   │   ├── rdma_coverage.svh
│   │   ├── rdma_env_config.svh
│   │   └── rdma_env.svh
│   └── adapters/
│       ├── host_mem/rdma_host_mem_adapter_pkg.sv
│       ├── pcie_work/rdma_pcie_work_adapter_pkg.sv
│       ├── net_packet/rdma_net_packet_adapter_pkg.sv
│       └── axis_vip/rdma_axis_vip_adapter_pkg.sv
├── hw/xtr_v1/
│   ├── source_manifest.txt
│   └── golden_vectors/
│       ├── context.hex
│       ├── cmq.hex
│       ├── queue.hex
│       └── doorbell.hex
├── tests/
│   ├── rdma_unit_test_pkg.sv
│   ├── unit/*.svh
│   ├── integration/*.svh
│   ├── mocks/*.svh
│   └── tb_top.sv
├── sim/
│   ├── Makefile
│   └── filelists/{core,host_mem,pcie_work,net_packet,axis_vip}.f
├── scripts/run_vcs53.sh
├── tools/check_xtr_v1_defs.py
└── docs/hw/xtr-v1-source-map.md
```

包依赖只能按下面方向出现：

```text
rdma_model_pkg -> rdma_types_pkg
rdma_adapter_pkg -> rdma_model_pkg + rdma_types_pkg
rdma_codec_pkg -> rdma_model_pkg + rdma_types_pkg
rdma_core_pkg -> rdma_adapter_pkg + rdma_codec_pkg + rdma_model_pkg + rdma_types_pkg

rdma_{host_mem,pcie_work,net_packet,axis_vip}_adapter_pkg
  -> 对应外部 package + rdma_adapter_pkg
```

`rdma_types_pkg`、`rdma_model_pkg`、`rdma_adapter_pkg`、`rdma_codec_pkg`、`rdma_core_pkg`
禁止 import `host_mem_pkg`、`pcie_tl_pkg`、`net_packet` 或 `axis_vip` package。

## 3. 统一接口与不变量

后续任务必须沿用以下签名，不得在各 engine 中重新定义近似类型：

```systemverilog
typedef struct packed { bit [63:0] value; } rdma_backing_addr_t;
typedef struct packed { bit [63:0] value; } rdma_iova_t;
typedef struct packed { bit [63:0] value; } rdma_hmc_fvm_addr_t;
typedef struct packed { bit [63:0] value; } rdma_bar_addr_t;
typedef struct packed { bit [11:0] value; } rdma_cfg_offset_t;
typedef struct packed {
  bit device_read;
  bit device_write;
  bit atomic;
} rdma_dma_permission_t;

typedef struct packed {
  bit [15:0] segment;
  bit [7:0] bus;
  bit [4:0] device;
  bit [2:0] function;
} rdma_bdf_t;

function automatic bit [15:0] rdma_bdf_requester_id(rdma_bdf_t bdf);
  return {bdf.bus, bdf.device, bdf.function};
endfunction

class rdma_codec_base extends uvm_object;
  pure virtual function rdma_status encode(
      rdma_hw_model model, output rdma_hw_image image);
  pure virtual function rdma_status decode(
      rdma_hw_image image, output rdma_hw_model model);
  pure virtual function string describe_fields();
endclass

virtual class rdma_host_mem_api extends uvm_object;
  pure virtual function rdma_status allocate(
      rdma_function_handle function_h, int unsigned size,
      int unsigned alignment, rdma_dma_direction_e direction,
      output rdma_dma_mapping mapping);
  pure virtual function rdma_status write(
      rdma_dma_mapping mapping, longint unsigned offset, byte data[]);
  pure virtual function rdma_status read(
      rdma_dma_mapping mapping, longint unsigned offset,
      int unsigned size, output byte data[]);
  pure virtual function rdma_status release(rdma_dma_mapping mapping);
endclass

virtual class rdma_pcie_api extends uvm_object;
  pure virtual task cfg_read32(rdma_bdf_t target, rdma_cfg_offset_t offset,
      output bit [31:0] data, output rdma_status status);
  pure virtual task cfg_write32(rdma_bdf_t target, rdma_cfg_offset_t offset,
      bit [31:0] data, bit [3:0] byte_enable, output rdma_status status);
  pure virtual task mmio_write(rdma_function_handle function_h,
      rdma_bar_addr_t address, byte data[], output rdma_status status);
  pure virtual task dma_visibility_barrier(
      rdma_function_handle function_h, output rdma_status status);
  pure virtual task mmio_ordering_barrier(
      rdma_function_handle function_h, output rdma_status status);
  pure virtual function rdma_status get_function_info(
      rdma_bdf_t bdf, output rdma_pcie_function_info info);
  pure virtual function rdma_status decode_bar(
      rdma_bar_addr_t address, output rdma_bar_decode result);
endclass

virtual class rdma_function_table_api extends uvm_object;
  pure virtual task program_notify(rdma_function_binding binding,
      output rdma_status status);
  pure virtual task clear_notify(rdma_function_binding binding,
      output rdma_status status);
  pure virtual task program_dmi(rdma_function_binding binding,
      output rdma_status status);
  pure virtual task clear_dmi(rdma_function_binding binding,
      output rdma_status status);
  pure virtual task program_vft(rdma_function_binding binding,
      output rdma_status status);
  pure virtual task clear_vft(rdma_function_binding binding,
      output rdma_status status);
endclass

virtual class rdma_net_observer extends uvm_object;
  pure virtual function void write(rdma_packet packet);
endclass


virtual class rdma_net_api extends uvm_object;
  pure virtual task send_packet(rdma_packet packet, output rdma_status status);
  pure virtual task receive_packet(output rdma_packet packet,
      output rdma_status status);
  pure virtual function void register_observer(rdma_net_observer observer);
  pure virtual function rdma_status configure_response_policy(
      rdma_net_response_policy policy);
  pure virtual function rdma_status inject_fault(rdma_net_fault fault);
endclass
```

Task 2 同时定义 `rdma_mapping_state_e`、`rdma_reset_kind_e`、`rdma_fault_kind_e`；Task 3
定义 `rdma_function_handle extends rdma_handle`、`rdma_pcie_identity`、
`rdma_pcie_function_info`、`rdma_bar_info` 和 `rdma_bar_decode`；Task 4 定义
`rdma_hw_model`、`rdma_packet`、`rdma_net_response_policy`、`rdma_net_fault` 和所有语义/
硬件模型；Task 19 定义 `rdma_trace_event`。

会等待 transport、barrier 或 completion 的方法一律是 task，固定调用形式为：

```systemverilog
doorbells.submit(desc, image, status);
cmq.submit(request, ticket, status);
cmq.submit_batch(requests, tickets, statuses);
control.create_qp(request, qp, status);
sq.post(request, ticket, status);
rq.post_recv(request, ticket, status);
completion.poll_cq(cq_handle, events, status);
functions.activate(binding, status);
functions.reset(function_handle, reset_kind, status);
```

`rdma_resource_manager` 只做同步的 ID/handle/lease registry；会发送 CMQ 的语义资源创建和
销毁由 `rdma_control_plane` task 完成。因此 UVM function 永远不调用 task。

统一执行约束：

1. `rdma_status` 对象必须非空；成功使用 `RDMA_SC_OK`，未知硬件码使用 `RDMA_SC_UNKNOWN_HW_ERROR`。
2. 任何提交操作的 handle generation 必须等于 binding generation。
3. `rdma_hw_image` 是唯一可以写入 backing memory 或 MMIO 的对象。
4. doorbell 固定执行 `backing write -> DMA barrier -> MMIO barrier -> MMIO write`。
5. 目标 VF 由 BAR 地址解码，RC Memory Write 的 requester ID 不能用作目标 VF identity。
6. VF DMA requester ID 必须等于该 binding 的 VF BDF，并同时通过 BME、IOVA domain、方向和边界检查。

## 4. 53 主机验证约定

每个“运行测试”步骤都从仓库根目录调用：

```bash
scripts/run_vcs53.sh core rdma_smoke_test
scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
scripts/run_vcs53.sh pcie_work rdma_pcie_work_adapter_test
scripts/run_vcs53.sh net_packet rdma_net_packet_adapter_test
scripts/run_vcs53.sh axis_vip rdma_axis_vip_adapter_test
```

脚本把当前未提交工作区同步到 53 上由 `mktemp` 创建的独立目录，并以
`bash -lc` 显式 source `~/.bashrc` 后运行 VCS；脚本退出时只删除该次创建的精确临时目录。
认证信息由交互式 SSH 或进程环境提供，禁止写入仓库。外部组件根路径通过
`HOST_MEM_ROOT`、`PCIE_WORK_ROOT`、`NET_PACKET_ROOT`、`AXIS_VIP_ROOT` 传入。

---

## 阶段一：基础类型、抽象 API、资源和 host memory

### Task 1: 建立核心编译与远端 VCS 测试骨架

**Files:**
- Create: `src/types/rdma_types_pkg.sv`
- Create: `tests/rdma_unit_test_pkg.sv`
- Create: `tests/unit/rdma_smoke_test.svh`
- Create: `tests/tb_top.sv`
- Create: `sim/filelists/core.f`
- Create: `sim/Makefile`
- Create: `scripts/run_vcs53.sh`

- [ ] **Step 1: 先写只依赖 `rdma_types_pkg` 的 smoke test 和可运行 harness**

```systemverilog
class rdma_smoke_test extends uvm_test;
  `uvm_component_utils(rdma_smoke_test)
  function new(string name = "rdma_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("RDMA_SMOKE", "rdma core package compiled", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
```

`tests/rdma_unit_test_pkg.sv` import `uvm_pkg::*`、include `uvm_macros.svh` 并 include
该 test；`tests/tb_top.sv` import test package 并调用 `run_test()`。同时创建本任务列出的
Makefile、filelist 和远端脚本；`core.f` 第一行引用尚不存在的
`../src/types/rdma_types_pkg.sv`，使 Step 2 的失败来自待实现 package。

- [ ] **Step 2: 在 53 上确认缺少 package 时失败**

Run: `scripts/run_vcs53.sh core rdma_smoke_test`

Expected: VCS FAIL，首个错误为无法打开 `src/types/rdma_types_pkg.sv` 或找不到
`rdma_types_pkg`。

- [ ] **Step 3: 添加最小 package 并完成安全远端脚本校验**

`rdma_types_pkg.sv` 只放 package 壳。`sim/Makefile` 的核心命令固定为：

```make
BUILD ?= build/core
TEST ?= rdma_smoke_test
VCS ?= vcs
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps

core:
	mkdir -p $(BUILD)
	$(VCS) $(VCS_FLAGS) -f filelists/core.f -top tb_top -o $(BUILD)/simv
	$(BUILD)/simv +UVM_TESTNAME=$(TEST)
```

`scripts/run_vcs53.sh` 必须使用 `set -euo pipefail`，校验 suite/test 两个参数，调用
`mktemp -d /home/ubuntu/workspace/rdma_uvm.XXXXXX`，用 `rsync -az --exclude .git`
同步当前目录，并在 trap 中通过 `ssh` 删除返回的精确目录。远端命令为：

```bash
bash -lc 'source ~/.bashrc >/dev/null 2>&1; cd "$remote_dir/sim"; make "$suite" TEST="$test"'
```

其中 `remote_dir` 只能采用远端 `mktemp` 的原样输出，`test` 只允许
`[A-Za-z_][A-Za-z0-9_]*` 或字面值 `regression`；suite 只允许
`core|host_mem|pcie_work|net_packet|axis_vip|xtr_defs`。脚本还要把本地已设置的
`HOST_MEM_ROOT`、`PCIE_WORK_ROOT`、`NET_PACKET_ROOT`、`AXIS_VIP_ROOT` 逐个 shell quote 后
传入远端 make，不为未设置的变量构造默认路径。

- [ ] **Step 4: 在 53 上确认 smoke test 通过**

Run: `scripts/run_vcs53.sh core rdma_smoke_test`

Expected: VCS compile exit 0，UVM summary 为 `UVM_ERROR : 0`、`UVM_FATAL : 0`。

- [ ] **Step 5: 提交测试骨架**

```bash
git add src/types tests sim scripts/run_vcs53.sh
git commit -m "test: add RDMA UVM VCS harness"
```

### Task 2: 定义地址、身份、枚举和统一状态

**Files:**
- Create: `src/types/rdma_address_types.svh`
- Create: `src/types/rdma_enum_types.svh`
- Create: `src/types/rdma_identity_types.svh`
- Create: `src/types/rdma_status.svh`
- Modify: `src/types/rdma_types_pkg.sv`
- Create: `tests/unit/rdma_types_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写地址不混用、BDF、状态字段的失败测试**

```systemverilog
task run_phase(uvm_phase phase);
  rdma_bdf_t bdf = '{segment:16'h0, bus:8'h42, device:5'h03, function:3'h5};
  rdma_status s;
  rdma_backing_addr_t backing = '{value:64'h1_0000_1000};
  rdma_iova_t iova = '{value:64'h2_0000_1000};
  phase.raise_objection(this);
  s = rdma_status::make(RDMA_SC_DMA_PERMISSION, "wrong DMA domain");
  if (rdma_bdf_requester_id(bdf) != 16'h421d) `uvm_error("BDF", "requester ID mismatch")
  if (backing.value == iova.value) `uvm_error("ADDR", "address spaces collapsed")
  if (s.ok() || s.category != RDMA_STATUS_DMA) `uvm_error("STATUS", "bad status")
  phase.drop_objection(this);
endtask
```

- [ ] **Step 2: 在 53 上确认类型未定义**

Run: `scripts/run_vcs53.sh core rdma_types_test`

Expected: VCS FAIL，报告 `rdma_bdf_t` 或 `rdma_status` 未定义。

- [ ] **Step 3: 实现固定类型集合**

实现五种地址 wrapper、`rdma_bdf_t`、`rdma_function_key_t`，以及以下 enum：

```systemverilog
typedef enum int unsigned {
  RDMA_SC_OK, RDMA_SC_INVALID_ARGUMENT, RDMA_SC_INVALID_STATE,
  RDMA_SC_STALE_GENERATION, RDMA_SC_RESOURCE_EXHAUSTED,
  RDMA_SC_UNSUPPORTED_OPCODE, RDMA_SC_CODEC_ERROR,
  RDMA_SC_TIMEOUT, RDMA_SC_PCIE_COMPLETION, RDMA_SC_DMA_TRANSLATION,
  RDMA_SC_DMA_PERMISSION, RDMA_SC_QUEUE_FULL, RDMA_SC_QUEUE_EMPTY,
  RDMA_SC_UNKNOWN_HW_ERROR, RDMA_SC_RESET_CANCELLED
} rdma_status_code_e;

typedef enum int unsigned {
  RDMA_BIND_DISCOVERED, RDMA_BIND_PCIE_CONFIGURED, RDMA_BIND_BOUND,
  RDMA_BIND_PREPARED, RDMA_BIND_ACTIVE, RDMA_BIND_QUIESCING,
  RDMA_BIND_RESETTING, RDMA_BIND_RELEASED, RDMA_BIND_ERROR
} rdma_binding_state_e;
```

另定义 resource kind、transport、DMA direction/permission、mapping state、image kind、
doorbell kind、engine kind、severity、responder mode、reset kind 和 fault kind。fault enum
固定包含 WRONG_REQUESTER、IOVA_PERMISSION、CMQ_TIMEOUT、CQE_ERROR、PACKET_DROP、VF_FLR。
`rdma_status` 保存 category/code、hardware code、
engine、Function UID/generation、resource/command/WR ID、severity、retryable 和 message；
实现 `make()`、`success()`、`ok()`、`convert2string()`。

- [ ] **Step 4: 在 53 上运行类型测试**

Run: `scripts/run_vcs53.sh core rdma_types_test`

Expected: PASS，UVM summary 无 error/fatal。

- [ ] **Step 5: 提交基础类型**

```bash
git add src/types tests/unit/rdma_types_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: define RDMA identities addresses and status"
```

### Task 3: 定义 typed handle、DMA mapping、Function binding 和硬件映像

**Files:**
- Create: `src/model/rdma_model_pkg.sv`
- Create: `src/model/rdma_handle.svh`
- Create: `src/model/rdma_hw_image.svh`
- Create: `src/model/rdma_dma_mapping.svh`
- Create: `src/model/rdma_function_binding.svh`
- Modify: `sim/filelists/core.f`
- Create: `tests/unit/rdma_model_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 generation、notify aperture 和 DMA mapping 的失败测试**

```systemverilog
rdma_function_binding b;
rdma_function_handle fh;
b = rdma_function_binding::type_id::create("b");
b.generation = 7;
b.pcie.bar[0].base.value = 64'h8000_0000;
b.pcie.bar[0].size = 64'h4000;
b.notify_base.value = 64'h8000_2000;
b.notify_size = 64'h2000;
fh = b.make_handle();
if (!b.validate().ok()) `uvm_error("BIND", "valid VF binding rejected")
b.generation++;
if (b.accepts(fh)) `uvm_error("GEN", "stale handle accepted")
b.notify_base.value = 64'h8000_3000;
if (b.validate().ok()) `uvm_error("NOTIFY", "misaligned notify accepted")
```

- [ ] **Step 2: 在 53 上确认模型未定义**

Run: `scripts/run_vcs53.sh core rdma_model_test`

Expected: VCS FAIL，报告 `rdma_function_binding` 未定义。

- [ ] **Step 3: 实现模型基类与校验**

实现：

```systemverilog
class rdma_handle extends uvm_object;
  rdma_resource_kind_e kind;
  longint unsigned function_uid;
  int unsigned object_id;
  int unsigned generation;
  function bit same_instance(rdma_handle rhs);
endclass

class rdma_function_handle extends rdma_handle;
endclass

class rdma_bar_info extends uvm_object;
  bit [2:0] bar_id;
  rdma_bar_addr_t base;
  longint unsigned size;
  bit enabled;
endclass

class rdma_pcie_identity extends uvm_object;
  rdma_bdf_t bdf;
  rdma_bdf_t parent_pf_bdf;
  int unsigned vf_index;
  bit mse;
  bit bme;
  rdma_bar_info bar[6];
endclass

class rdma_pcie_function_info extends rdma_pcie_identity;
endclass

class rdma_bar_decode extends uvm_object;
  rdma_bdf_t target_bdf;
  bit [2:0] bar_id;
  longint unsigned bar_offset;
endclass

class rdma_dma_mapping extends uvm_object;
  rdma_function_handle function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  rdma_backing_addr_t backing_addr;
  rdma_iova_t iova;
  longint unsigned size;
  rdma_dma_direction_e direction;
  rdma_dma_permission_t permissions;
  rdma_mapping_state_e state;
  rdma_handle owner_h;
  function rdma_status check_access(
      rdma_function_handle requested_function,
      rdma_bdf_t requester_bdf,
      rdma_iova_t first_iova,
      longint unsigned length,
      rdma_dma_direction_e requested_direction,
      rdma_dma_permission_t requested_permissions);
endclass
```

`rdma_function_binding` 显式包含 `rdma_pcie_identity pcie`、notify 的
`host_id/pfvf_id`、RDMA logical identity 的 `rdma_vf_id/global_function_id/vsi_id`、
DMA domain、state、generation 和 owner；`validate()` 检查 8 KiB 对齐、窗口落在 BAR、
identity 不互推以及 ACTIVE 所需字段。`rdma_hw_image` 保存 byte queue、length、alignment、
endian、image kind、hardware version、Function generation、可选目标地址和字段摘要。

- [ ] **Step 4: 在 53 上运行模型测试**

Run: `scripts/run_vcs53.sh core rdma_model_test`

Expected: PASS；stale generation 和错误 notify 均被拒绝。

- [ ] **Step 5: 提交基础模型**

```bash
git add src/model sim/filelists/core.f tests
git commit -m "feat: add RDMA handles mappings and function binding"
```

### Task 4: 定义语义请求、资源对象和硬件字段模型基类

**Files:**
- Create: `src/model/rdma_semantic_requests.svh`
- Create: `src/model/rdma_resources.svh`
- Create: `src/model/rdma_context_models.svh`
- Create: `src/model/rdma_queue_models.svh`
- Modify: `src/model/rdma_model_pkg.sv`
- Create: `tests/unit/rdma_request_model_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写“sequence 只表达语义”的失败测试**

```systemverilog
rdma_create_qp_req req;
req = rdma_create_qp_req::type_id::create("req");
req.transport = RDMA_TRANSPORT_RC;
req.sq_depth = 1024;
req.rq_depth = 512;
req.max_send_sge = 4;
if (!req.validate().ok()) `uvm_error("REQ", "valid request rejected")
req.sq_depth = 1000;
if (req.validate().ok()) `uvm_error("REQ", "non-power-of-two depth accepted")
```

- [ ] **Step 2: 在 53 上确认 request class 未定义**

Run: `scripts/run_vcs53.sh core rdma_request_model_test`

Expected: VCS FAIL，报告 `rdma_create_qp_req` 未定义。

- [ ] **Step 3: 实现四层模型的剩余 class**

语义请求实现 create/destroy PD/MR/CQ/QP/SRQ/EQ、modify QP、post send/recv；网络模型
`rdma_packet` 保存 transport、network opcode、QPN、PSN、headers、metadata 和 payload，
response/fault 对象保存 policy、drop/corrupt/delay 参数和 deterministic seed。SGE 固定为：

```systemverilog
class rdma_sge extends uvm_object;
  rdma_iova_t iova;
  int unsigned length;
  bit [31:0] lkey;
endclass
```

所有资源继承 `rdma_resource`，共同字段为 handle、owner Function handle、state、backing
mapping 队列、dependency handle 队列和 outstanding ID 队列。实现各具体资源的队列深度、
PI/CI/wrap、hardware/global ID。硬件模型以 `rdma_hw_model` 为抽象基类；context 模型包含
QPC common + RC/UD/URC extension、CQC、MRT、SRQC、CEQC、AEQC；queue 模型包含
CMQ SQE/completion、数据 SQE/RQE/CQE/CEQE/AEQE 和 doorbell payload。

- [ ] **Step 4: 在 53 上运行请求模型测试**

Run: `scripts/run_vcs53.sh core rdma_request_model_test`

Expected: PASS；非法 depth 返回 `RDMA_SC_INVALID_ARGUMENT`。

- [ ] **Step 5: 提交语义与字段模型**

```bash
git add src/model tests
git commit -m "feat: add RDMA requests resources and hardware models"
```

### Task 5: 定义外部组件抽象 API 和 mock adapter

**Files:**
- Create: `src/adapter/rdma_adapter_pkg.sv`
- Create: `src/adapter/rdma_host_mem_api.svh`
- Create: `src/adapter/rdma_pcie_api.svh`
- Create: `src/adapter/rdma_function_table_api.svh`
- Create: `src/adapter/rdma_net_api.svh`
- Create: `tests/mocks/rdma_mock_adapters.svh`
- Modify: `sim/filelists/core.f`
- Create: `tests/unit/rdma_adapter_contract_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 mock 可注入且核心 package 无外部依赖的失败测试**

```systemverilog
rdma_mock_host_mem mem;
rdma_host_mem_api api;
rdma_dma_mapping m;
rdma_status s;
mem = rdma_mock_host_mem::type_id::create("mem");
api = mem;
s = api.allocate(function_h, 4096, 4096, RDMA_DMA_BIDIRECTIONAL, m);
if (!s.ok() || m.size != 4096) `uvm_error("API", "host adapter contract failed")
```

- [ ] **Step 2: 在 53 上确认抽象 API 未定义**

Run: `scripts/run_vcs53.sh core rdma_adapter_contract_test`

Expected: VCS FAIL，报告 `rdma_host_mem_api` 未定义。

- [ ] **Step 3: 实现四个抽象 API 和可记录调用的 mock**

除第 3 节固定签名外，`rdma_net_api` 提供 blocking `send_packet/receive_packet`、observer
注册、response policy 和 drop/corruption/delay 注入；`rdma_function_table_api` 提供
notify/DMI/VFT 的 program/clear。mock 为每次调用记录 Function handle、generation、地址、
payload 和调用序号，并支持按方法名注入一个确定的失败状态。

- [ ] **Step 4: 在 53 上运行 adapter contract test**

Run: `scripts/run_vcs53.sh core rdma_adapter_contract_test`

Expected: PASS；编译日志中不出现 `host_mem_pkg` 或 `pcie_tl_pkg` 查找错误。

- [ ] **Step 5: 提交抽象接口**

```bash
git add src/adapter tests/mocks tests/unit sim/filelists/core.f
git commit -m "feat: define injectable RDMA adapter contracts"
```

### Task 6: 实现 generation-safe 资源管理器

**Files:**
- Create: `src/core/rdma_core_pkg.sv`
- Create: `src/core/rdma_resource_manager.svh`
- Create: `src/core/rdma_hmc_allocator.svh`
- Modify: `sim/filelists/core.f`
- Create: `tests/unit/rdma_resource_manager_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 ID 分配、依赖和 stale handle 的失败测试**

```systemverilog
rdma_resource_manager rm;
rdma_pd pd;
rdma_handle old_h;
rdma_status s;
s = rm.create_pd(active_binding, pd);
if (!$cast(old_h, pd.handle.clone())) `uvm_fatal("RM", "handle clone cast failed")
if (!s.ok()) `uvm_error("RM", "PD create failed")
s = rm.release(pd.handle);
if (!s.ok()) `uvm_error("RM", "PD release failed")
active_binding.generation++;
s = rm.lookup(old_h, resource);
if (s.code != RDMA_SC_STALE_GENERATION) `uvm_error("RM", "stale handle accepted")
```

- [ ] **Step 2: 在 53 上确认 manager 未定义**

Run: `scripts/run_vcs53.sh core rdma_resource_manager_test`

Expected: VCS FAIL，报告 `rdma_resource_manager` 未定义。

- [ ] **Step 3: 实现 allocator、registry 和依赖释放检查**

每种 resource kind 使用独立 ID pool；registry key 为
`function_uid:generation:resource_kind:object_id`。提供 `create_*()`、`lookup()`、`freeze()`、
`release()`、`release_function()` 和 `check_leaks()`；仍被 QP/CQ/MR 依赖的资源返回
`RDMA_SC_INVALID_STATE`。释放后 ID 可以重用，但新的 handle generation 或 object serial
必须不同，旧 handle 永不重新生效。`rdma_hmc_allocator` 在独立 HMC/FVM aperture 中按
object kind、alignment 和 Function lease 分配 `rdma_hmc_fvm_addr_t`；它不调用 host_mem，
也不能把 HMC 地址写入 `rdma_dma_mapping.backing_addr/iova`。测试额外分配一个数值恰好与
IOVA 相等的 HMC 地址，确认 API 仍以不同 wrapper 和 lease registry 处理。

- [ ] **Step 4: 在 53 上运行资源管理器测试**

Run: `scripts/run_vcs53.sh core rdma_resource_manager_test`

Expected: PASS；重复 ID、依赖中释放和 use-after-free 全部被拒绝。

- [ ] **Step 5: 提交资源管理器**

```bash
git add src/core/rdma_core_pkg.sv src/core/rdma_resource_manager.svh \
  src/core/rdma_hmc_allocator.svh sim tests
git commit -m "feat: add generation safe RDMA resource manager"
```

### Task 7: 接入 64-bit host_mem 并建立显式 IOVA mapping

**Files:**
- Create: `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv`
- Create: `sim/filelists/host_mem.f`
- Modify: `sim/Makefile`
- Create: `tests/integration/rdma_host_mem_adapter_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 4 GiB 以上分配、读写、越界和释放测试**

先创建 `host_mem.f` 和 Makefile `host_mem` target，编译固定 commit 的 `host_mem_pkg.sv`、
`host_mem_manager.sv`、RDMA core 和本测试，但让 filelist 引用尚不存在的 adapter package。

```systemverilog
host_mem_manager hm;
rdma_host_mem_adapter a;
rdma_dma_mapping m;
byte wr[] = '{8'h11, 8'h22, 8'h33, 8'h44};
byte rd[];
hm.init_region(64'h1_0000_0000, 64'h1_00ff_ffff);
a = rdma_host_mem_adapter::type_id::create("a");
a.mem = hm;
s = a.allocate(function_h, 4096, 4096, RDMA_DMA_BIDIRECTIONAL, m);
if (!s.ok() || m.backing_addr.value < 64'h1_0000_0000) `uvm_error("MEM", "not 64-bit")
s = a.write(m, 4094, wr);
if (s.ok()) `uvm_error("MEM", "cross-boundary write accepted")
```

- [ ] **Step 2: 在 53 上确认 adapter 未定义**

Run:

```bash
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected: VCS FAIL，报告 `rdma_host_mem_adapter` 未定义。

- [ ] **Step 3: 用组合而非复制实现 host_mem adapter**

adapter 持有 `host_mem_pkg::host_mem_api mem`，依次调用 `alloc`、`write_mem`、`read_mem`、
`free`、`leak_check`。默认 identity mapping 明确同时填写 backing 和 IOVA；允许注入
`iova_base` 建立 offset mapping。所有 `offset + size` 使用 65 bit 中间值检查溢出，release
将 mapping 置为 `RDMA_MAPPING_RELEASED`，后续访问返回 `RDMA_SC_INVALID_STATE`。

- [ ] **Step 4: 在 53 上运行 host_mem adapter 测试**

Run:

```bash
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected: PASS；4 GiB 以上读写一致，越界和释放后访问均返回错误，leak count 为 0。

- [ ] **Step 5: 提交 host memory adapter**

```bash
git add src/adapters/host_mem sim tests
git commit -m "feat: adapt 64-bit host memory for RDMA DMA mappings"
```

---

## 阶段二：Codec registry、控制面上下文、CMQ 和 doorbell

### Task 8: 实现通用 bit packer、codec 基类和 registry

**Files:**
- Create: `src/codec/rdma_codec_pkg.sv`
- Create: `src/codec/rdma_codec_base.svh`
- Create: `src/codec/rdma_codec_registry.svh`
- Create: `src/codec/rdma_bit_packer.svh`
- Modify: `sim/filelists/core.f`
- Create: `tests/unit/rdma_codec_registry_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 key 隔离、冲突注册和越界 pack 的失败测试**

```systemverilog
rdma_codec_key k_rc = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_QPC,
                        object_type:"qpc", variant:"rc", opcode:0};
rdma_codec_key k_ud = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_QPC,
                        object_type:"qpc", variant:"ud", opcode:0};
if (!registry.register_codec(k_rc, rc_codec).ok()) `uvm_error("REG", "register failed")
if (registry.register_codec(k_rc, rc_codec).code != RDMA_SC_INVALID_STATE)
  `uvm_error("REG", "duplicate key accepted")
if (registry.lookup(k_ud, codec).code != RDMA_SC_UNSUPPORTED_OPCODE)
  `uvm_error("REG", "missing variant silently matched")
if (rdma_bit_packer::put_u64(bytes, 62, 4, 4'hf).ok())
  `uvm_error("PACK", "out-of-range field accepted")
```

- [ ] **Step 2: 在 53 上确认 codec package 未定义**

Run: `scripts/run_vcs53.sh core rdma_codec_registry_test`

Expected: VCS FAIL，报告 `rdma_codec_registry` 未定义。

- [ ] **Step 3: 实现确定性 key 和边界安全 packer**

registry 的规范 key 为
`hw_version|image_kind|object_type|variant|opcode`；opcode 使用两位十六进制字符串。
实现 `register_codec()`、`lookup()`、`clear()`、`list_keys()`。bit packer 提供 byte array
上的 `put/get_u64()`，统一以 image byte 0 为最低地址；每个 codec 自己声明硬件 endian，
packer 检查 bit range、value width、image length 和重叠字段。registry 冲突使用
`uvm_fatal`，普通 lookup miss 返回 `RDMA_SC_UNSUPPORTED_OPCODE`。

- [ ] **Step 4: 在 53 上运行 registry 测试**

Run: `scripts/run_vcs53.sh core rdma_codec_registry_test`

Expected: PASS；RC/UD key 不串用，越界与重复字段写入被拒绝。

- [ ] **Step 5: 提交 codec 基础设施**

```bash
git add src/codec sim/filelists/core.f tests
git commit -m "feat: add versioned RDMA codec registry"
```

### Task 9: 冻结 xtr_v1 硬件定义和 golden vector

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_defs.svh`
- Create: `hw/xtr_v1/source_manifest.txt`
- Create: `hw/xtr_v1/golden_vectors/context.hex`
- Create: `hw/xtr_v1/golden_vectors/cmq.hex`
- Create: `hw/xtr_v1/golden_vectors/queue.hex`
- Create: `hw/xtr_v1/golden_vectors/doorbell.hex`
- Create: `docs/hw/xtr-v1-source-map.md`
- Create: `tools/check_xtr_v1_defs.py`
- Modify: `sim/Makefile`
- Create: `tests/unit/rdma_xtr_v1_defs_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写关键尺寸、opcode 和位域的失败测试**

```systemverilog
if (XTR_V1_QPC_BYTES != 512) `uvm_error("DEFS", "QPC size")
if (XTR_V1_CQC_BYTES != 64) `uvm_error("DEFS", "CQC size")
if (XTR_V1_CMQE_BYTES != 64 || XTR_V1_WQE_BYTES != 64)
  `uvm_error("DEFS", "entry size")
if (XTR_V1_OP_QPC_CREATE != 8'h00 || XTR_V1_OP_CQC_CREATE != 8'h0c ||
    XTR_V1_OP_SRFQC_CREATE != 8'h35) `uvm_error("DEFS", "CMQ opcode")
if (XTR_V1_NOTIFY_WINDOW_OFFSET != 64'h2000 ||
    XTR_V1_NOTIFY_WINDOW_SIZE != 64'h2000) `uvm_error("DEFS", "notify window")
```

- [ ] **Step 2: 在 53 上确认定义缺失**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_defs_test`

Expected: VCS FAIL，报告 `XTR_V1_QPC_BYTES` 未定义。

- [ ] **Step 3: 从固定提交逐字段建立 manifest、常量和 checker**

`source_manifest.txt` 逐行记录 `commit path macro-or-enum sha256`。至少覆盖：

```text
491faf2ba42627fffd4dd027607299c8bb591ec2 cmq.h xtrdma_cmq_opcode 67f685b23af4f1be64322e56e270546d993db95494ecba253d38afd0780b6e06
491faf2ba42627fffd4dd027607299c8bb591ec2 qp.h XTRDMA_QPC_* c009d546acbd99eb818223fb5cfb348c5423b554c12638d0690aca4a7a35f35d
491faf2ba42627fffd4dd027607299c8bb591ec2 cq.h XTRDMA_CMQ_CQC_*|XTRDMA_NOTIFY_CQ_* 7d2e2b41e254b9be2f70214bf31cb67bfa5dadbc6eb47124394429ef1d134ee7
491faf2ba42627fffd4dd027607299c8bb591ec2 wr.h XTRDMA_SQ_WQE_*|XTRDMA_RQE_*|XTRDMA_CQE_* c75fb5770ef0ea1af404efbaf95cf79356d1096d331d7cdfcc46ea9ad9b3225b
491faf2ba42627fffd4dd027607299c8bb591ec2 defs.h XTRDMA_CEQE_*|XTRDMA_AEQE_*|EC_* 79e26543d2b9c0942be2819cd505f50118b6cd005a2c8d237dbf8a690963b9ae
491faf2ba42627fffd4dd027607299c8bb591ec2 eth_header/rdma_register.h RDMA_HID_MAP_TABLE|RDMA_RPE_VFT_TABLE af957673ba0b561cd27d4bd22394cc0bc56a0173bff66c59176a5a829e0acc13
```

checker 接收 `--kernel-root`，解析 `BIT_ULL`、`GENMASK_ULL`、显式 enum 值，和
`rdma_xtr_v1_defs.svh` 中的 offset/width/value 比较；不认识的 C 表达式必须报错退出，
不能跳过。`docs/hw/xtr-v1-source-map.md` 对每个 image 列出 byte size、endian、源文件、
字段组和 golden vector 行号。golden vector 由驱动相同的 mask/shift 规则生成，并固定
输入字段摘要，不能从待测 SV codec 自生成。

- [ ] **Step 4: 在 53 上校验定义并运行测试**

在 `sim/Makefile` 添加 `xtr_defs` target：用
`mktemp -d /tmp/rdma_xtr_v1_ref.XXXXXX` 创建引用目录，trap 删除该精确目录，从
`/home/ubuntu/workspace/Desktop.zip` 解出 kernel driver，然后运行：

```bash
python3 ../tools/check_xtr_v1_defs.py \
  --kernel-root "$ref_dir/dpu_kernel_rdma-version_0.1.32"
```

Run:

```bash
scripts/run_vcs53.sh xtr_defs check
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
```

Expected: checker 输出 `xtr_v1 definitions: PASS`；VCS test PASS。删除动作只针对本命令
创建的 `/tmp/rdma_xtr_v1_ref`。

- [ ] **Step 5: 提交硬件定义基线**

```bash
git add src/codec/xtr_v1/rdma_xtr_v1_defs.svh hw tools docs/hw sim/Makefile tests
git commit -m "feat: freeze xtr_v1 RDMA hardware definitions"
```

### Task 10: 实现 QPC/CQC/MRT/SRQC/EQC codec

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_context_codecs.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_context_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 为每种 context 写 golden encode/decode 和非法字段测试**

```systemverilog
foreach (golden_cases[i]) begin
  s = registry.lookup(golden_cases[i].key, codec);
  s = codec.encode(golden_cases[i].model, image);
  if (!s.ok() || image.bytes != golden_cases[i].bytes)
    `uvm_error("CTX_ENC", golden_cases[i].name)
  s = codec.decode(image, decoded);
  if (!s.ok() || !golden_cases[i].model.semantic_equal(decoded))
    `uvm_error("CTX_DEC", golden_cases[i].name)
end
```

case 必须包含 RC/UD/URC QPC、CQC、MRT、SRQC、CEQC、AEQC；每类至少一个全边界值
case 和一个 reserved-bit/对齐错误 case。

- [ ] **Step 2: 在 53 上确认 codec lookup 失败**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_context_codec_test`

Expected: FAIL，首个 registry lookup 返回 `RDMA_SC_UNSUPPORTED_OPCODE`。

- [ ] **Step 3: 实现公共 QPC 头加 transport extension 的 codec**

每个 codec 先 `validate_model()`，用 `rdma_bit_packer` 写固定长度 image，再
`validate_image()` 检查 reserved bit。QPC common codec 只处理 host/vf/qpn/pd/state/
queue base 等公共字段，RC/UD/URC extension 各自处理专有字段；禁止用一个 512-byte
case statement 混合三种 transport。所有 context codec 注册到 `xtr_v1` key。

- [ ] **Step 4: 在 53 上运行 context codec 测试**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_context_codec_test`

Expected: PASS；所有 golden vector byte-for-byte 相等且 round-trip 通过。

- [ ] **Step 5: 提交 context codec**

```bash
git add src/codec tests
git commit -m "feat: encode xtr_v1 RDMA contexts"
```

### Task 11: 实现多 opcode CMQ codec 和硬件错误码解释

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh`
- Create: `src/codec/xtr_v1/rdma_xtr_v1_error_codec.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_cmq_codec_test.svh`
- Create: `tests/unit/rdma_xtr_v1_error_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 CMQE 公共头、多 opcode、completion 和未知 error 测试**

```systemverilog
foreach (supported_ops[i]) begin
  req.opcode = supported_ops[i];
  s = cmq_registry.encode_request(req, image);
  if (!s.ok() || image.bytes.size() != 64)
    `uvm_error("CMQ", $sformatf("opcode %0h", req.opcode))
end
req.opcode = 8'hff;
if (cmq_registry.encode_request(req, image).code != RDMA_SC_UNSUPPORTED_OPCODE)
  `uvm_error("CMQ", "unknown opcode encoded")
s = error_codec.decode_status(8'he7, RDMA_ENGINE_CQ, status);
if (status.code != RDMA_SC_UNKNOWN_HW_ERROR || status.hardware_code != 8'he7)
  `uvm_error("ECODE", "unknown code lost")
```

- [ ] **Step 2: 在 53 上确认 CMQ codec 未注册**

Run:

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_error_codec_test
```

Expected: 两个 test FAIL，分别为 codec miss 和 error codec 未定义。

- [ ] **Step 3: 实现 CMQE 公共头与 opcode 专用 body**

CMQE 固定 64 bytes。公共头编码 valid、VF override/use_vfid、wrap、WQE index、opcode；
body codec 覆盖本阶段确定范围的 QPC/CQC/CEQC/AEQC/SRFQC、MR 和 flush 命令。
completion decode 提取 opcode、command error code、WQE index/wrap 和命令专用返回字段。
error codec 根据 `defs.h` 和 `wr.h` 归类 QP/CQ/SRQ/DMA/flush/remote error；原始 8-bit
ecode 总是保留。

- [ ] **Step 4: 在 53 上运行 CMQ 和 error codec 测试**

Run:

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_error_codec_test
```

Expected: PASS；支持 opcode 生成 64 bytes，未知 opcode/code 均返回确定状态。

- [ ] **Step 5: 提交 CMQ codec**

```bash
git add src/codec tests
git commit -m "feat: encode xtr_v1 CMQ commands and errors"
```

### Task 12: 实现所有 doorbell codec 和顺序调度器

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_doorbell_codecs.svh`
- Create: `src/core/rdma_doorbell_scheduler.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_doorbell_scheduler_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写多 doorbell golden 和调用顺序失败测试**

```systemverilog
scheduler.submit(desc, result, s);
if (!s.ok()) `uvm_error("DB", s.convert2string())
if (mock.calls != '{"host_write", "dma_barrier", "mmio_barrier", "mmio_write"})
  `uvm_error("ORDER", "doorbell ordering violated")
if (mock.mmio_address.value != binding.notify_base.value + desc.offset)
  `uvm_error("ADDR", "wrong notify address")
```

table-driven cases 覆盖 CMQ SQ、SQ、RQ、SRQ、CQ、CEQ、AEQ、QP flush、TQ flush 的
width、offset、endian、PI/CI/wrap 和 host/QP/CQ/EQ ID。

- [ ] **Step 2: 在 53 上确认 scheduler/codec 未定义**

Run: `scripts/run_vcs53.sh core rdma_doorbell_scheduler_test`

Expected: VCS FAIL，报告 `rdma_doorbell_scheduler` 未定义。

- [ ] **Step 3: 实现 doorbell descriptor、codec 和严格顺序**

`rdma_doorbell_desc` 包含 kind、Function handle、BAR ID/offset、width、byte order、payload
model、barrier policy、write-combining policy、allow_merge、dependency image IDs、timeout、
readback policy。scheduler 拒绝非 ACTIVE/stale binding、越过 notify window、错误 width、
未完成 dependency 和不允许 merge 的合并请求；然后调用 host write、两个 barrier 和
`pcie_api.mmio_write()`。同一 Function 内默认串行，不同 Function 可以并行。

- [ ] **Step 4: 在 53 上运行 doorbell 测试**

Run: `scripts/run_vcs53.sh core rdma_doorbell_scheduler_test`

Expected: PASS；所有 golden doorbell 相等，mock 调用顺序严格匹配。

- [ ] **Step 5: 提交 doorbell 子系统**

```bash
git add src/codec src/core tests
git commit -m "feat: schedule typed xtr_v1 RDMA doorbells"
```

### Task 13: 实现 CMQ ring、batch 和多 outstanding engine

**Files:**
- Create: `src/core/rdma_cmq_engine.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_cmq_engine_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写乱序 completion、ring wrap、局部失败和 timeout 测试**

```systemverilog
engine.configure(.depth(32), .entry_bytes(64));
engine.submit_batch(requests, tickets, submit_status);
mock_cq.push_completion(tickets[2].command_id, RDMA_SC_OK);
mock_cq.push_completion(tickets[0].command_id, RDMA_SC_CODEC_ERROR);
mock_cq.push_completion(tickets[1].command_id, RDMA_SC_OK);
engine.reap(completions);
if (completions[0].command_id == completions[1].command_id)
  `uvm_error("CMQ", "completion correlation failed")
if (engine.outstanding_count() != 0) `uvm_error("CMQ", "ticket leak")
```

- [ ] **Step 2: 在 53 上确认 CMQ engine 未定义**

Run: `scripts/run_vcs53.sh core rdma_cmq_engine_test`

Expected: VCS FAIL，报告 `rdma_cmq_engine` 未定义。

- [ ] **Step 3: 实现 command ID pool、ring 和完成匹配**

CMQ depth 固定初值 32、entry 64 bytes、allocation alignment 4096。`submit()` 只在 SQE
写入 backing 后推进 PI；`submit_batch()` 对每条命令保留独立状态；outstanding 以
command ID + Function generation 为 key；completion 可以乱序；PI/CI wrap 和 polarity
使用 monotonic counter 计算。实现 per-command timeout、cancel_generation()、reset() 和
ID 回收，batch 中一个命令失败不得覆盖其他命令状态。

- [ ] **Step 4: 在 53 上运行 CMQ engine 测试**

Run: `scripts/run_vcs53.sh core rdma_cmq_engine_test`

Expected: PASS；覆盖 33 次提交触发 wrap、乱序匹配、局部失败、timeout 和 reset cancel。

- [ ] **Step 5: 提交 CMQ engine**

```bash
git add src/core tests
git commit -m "feat: add batched multi-outstanding CMQ engine"
```

### Task 14: 用 CMQ 驱动控制面资源生命周期

**Files:**
- Create: `src/core/rdma_control_plane.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_control_plane_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 PD/MR/CQ/QP/SRQ/EQ 创建与逆序回滚测试**

```systemverilog
mock_cmq.fail_opcode(XTR_V1_OP_QPC_CREATE, RDMA_SC_PCIE_COMPLETION);
control.create_qp(req, qp, s);
if (s.code != RDMA_SC_PCIE_COMPLETION) `uvm_error("CTRL", "failure lost")
if (rm.exists(qp.handle) || mock_mem.live_allocations() != baseline_allocs)
  `uvm_error("ROLLBACK", "partial QP leaked")
if (mock_cmq.last_rollback_order() != '{"CQC_DELETE", "MR_DEREGISTER"})
  `uvm_error("ROLLBACK", "wrong reverse order")
```

- [ ] **Step 2: 在 53 上确认 create 仍未调用 CMQ**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: FAIL，mock CMQ 记录为空或 rollback 断言失败。

- [ ] **Step 3: 实现事务式 create/modify/destroy**

`rdma_control_plane` 的每个资源操作使用 action stack：allocation、mapping、context encode、CMQ submit、registry
publish；失败时反向执行 delete command、mapping release、ID release。资源只有 CMQ
成功后进入 ACTIVE；destroy 先 freeze，等待或取消 outstanding，再删除硬件对象并释放
backing。QP modify 根据 transport 选择 QPC codec，不能直接改裸 byte。

- [ ] **Step 4: 在 53 上运行控制面测试**

Run: `scripts/run_vcs53.sh core rdma_control_plane_test`

Expected: PASS；每个注入失败点均无资源、mapping 或 command ID 泄漏。

- [ ] **Step 5: 提交控制面生命周期**

```bash
git add src/core/rdma_control_plane.svh src/core/rdma_core_pkg.sv tests
git commit -m "feat: drive RDMA resource lifecycle through CMQ"
```

---

## 阶段三：SQ/RQ/CQ/EQ 数据面

### Task 15: 实现数据 SQE/RQE/CQE/CEQE/AEQE codec

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_queue_codecs.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_queue_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 为每个 opcode 和 completion 类型写 golden 测试**

```systemverilog
foreach (sqe_cases[i]) begin
  s = registry.lookup(sqe_cases[i].key, codec);
  s = codec.encode(sqe_cases[i].model, image);
  if (!s.ok() || image.bytes.size() != 64 || image.bytes != sqe_cases[i].golden)
    `uvm_error("SQE", sqe_cases[i].name)
end
s = cqe_codec.decode(cqe_image, decoded);
if (!s.ok() || decoded.wr_id != expected_wr_id || decoded.hardware_code != expected_ecode)
  `uvm_error("CQE", "decode mismatch")
```

table 必须逐项覆盖第 1 节列出的数据 opcode、inline/non-inline、1/4 SGE、RQE、正常和
异常 CQE、CEQE、AEQE、owner/polarity 和 wrap。

- [ ] **Step 2: 在 53 上确认 queue codec 未注册**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_queue_codec_test`

Expected: FAIL，首个 SQE registry lookup 返回 `RDMA_SC_UNSUPPORTED_OPCODE`。

- [ ] **Step 3: 以 opcode 派生 class 实现 codec**

每个 SQE codec 处理固定 64-byte WQE；inline payload 和 SGE list 的合法组合在模型校验
阶段决定。SGE 每项 16 bytes；当 WQE 容量不足时模型明确引用外部 SGB mapping。CQE
decode 保留原始 8-bit ecode 并调用 error codec；CEQE/AEQE 执行 valid、QP/CQ/EQ ID、
packet opcode、index 和 wrap 校验。reserved bit 非零返回 `RDMA_SC_CODEC_ERROR`。

- [ ] **Step 4: 在 53 上运行 queue codec 测试**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_queue_codec_test`

Expected: PASS；所有 opcode byte-for-byte 匹配 golden，decode round-trip 通过。

- [ ] **Step 5: 提交数据面 codec**

```bash
git add src/codec tests
git commit -m "feat: encode xtr_v1 RDMA queue entries"
```

### Task 16: 实现 SQ engine 的 payload、inline、SGE 和 PSN 跟踪

**Files:**
- Create: `src/core/rdma_sq_engine.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_sq_engine_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 inline、外部 payload、多 SGE、ring full 和顺序测试**

```systemverilog
post.opcode = RDMA_WR_SEND;
post.payload = new[96];
post.inline_requested = 0;
sq.post(post, ticket, s);
if (!s.ok()) `uvm_error("SQ", s.convert2string())
if (mock.calls != '{"payload_write", "sqe_write", "dma_barrier",
                    "mmio_barrier", "sq_doorbell"})
  `uvm_error("SQ_ORDER", "payload visibility order")
repeat (qp.sq_depth - 1) sq.post(post, ticket, s);
sq.post(post, ticket, s);
if (s.code != RDMA_SC_QUEUE_FULL)
  `uvm_error("SQ_FULL", "overflow accepted")
```

- [ ] **Step 2: 在 53 上确认 SQ engine 未定义**

Run: `scripts/run_vcs53.sh core rdma_sq_engine_test`

Expected: VCS FAIL，报告 `rdma_sq_engine` 未定义。

- [ ] **Step 3: 实现 WR 到一个或多个 image 的转换**

`post()` 检查 ACTIVE Function/QP、generation、QP state、opcode/transport 合法性、SGE
mapping 权限和 queue credits；分配 WR ID，组织 inline/SGE/SGB/payload image，更新 PSN 和
monotonic PI，写完全部依赖 image 后才提交 SQ doorbell。保存 WR ID -> WQE index/wrap/
PSN/function generation 的 outstanding 记录。atomic 要求 8-byte 对齐，read/write 检查
remote length 和 local SGE 总长。

- [ ] **Step 4: 在 53 上运行 SQ engine 测试**

Run: `scripts/run_vcs53.sh core rdma_sq_engine_test`

Expected: PASS；覆盖 inline、1/4 SGE、外部 SGB、跨 ring wrap、full、错误权限和 stale QP。

- [ ] **Step 5: 提交 SQ engine**

```bash
git add src/core tests
git commit -m "feat: add RDMA send queue engine"
```

### Task 17: 实现 RQ/SRQ engine 和 receive buffer 管理

**Files:**
- Create: `src/core/rdma_rq_engine.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_rq_engine_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 RQ、SRQ、empty/full 和权限测试**

```systemverilog
recv.sges = '{rx_sge0, rx_sge1};
rq.post_recv(recv, ticket, s);
if (!s.ok()) `uvm_error("RQ", s.convert2string())
if (mock.last_db.kind != RDMA_DB_RQ || mock.last_db.pi != 1)
  `uvm_error("RQ_DB", "wrong RQ doorbell")
srq.post_recv(recv, ticket, s);
if (!s.ok() || mock.last_db.kind != RDMA_DB_SRQ)
  `uvm_error("SRQ_DB", "wrong SRQ doorbell")
```

- [ ] **Step 2: 在 53 上确认 RQ engine 未定义**

Run: `scripts/run_vcs53.sh core rdma_rq_engine_test`

Expected: VCS FAIL，报告 `rdma_rq_engine` 未定义。

- [ ] **Step 3: 实现 per-QP RQ 和共享 SRQ 两条路径**

两条路径共用 RQE codec 和 mapping 权限检查，但分别维护 PI/CI/wrap、credit 和 doorbell
格式。post 前要求 mapping 允许 DEVICE_WRITE；同一个 receive buffer 在 completion 前不可
重复 post；零长度仅在 profile 明确允许时接受。SRQ 保存 consumer QP 关联，但 owner 仍是
SRQ Function generation。

- [ ] **Step 4: 在 53 上运行 RQ/SRQ 测试**

Run: `scripts/run_vcs53.sh core rdma_rq_engine_test`

Expected: PASS；RQ 与 SRQ doorbell 不混用，buffer lease 在 completion 后归还。

- [ ] **Step 5: 提交 RQ/SRQ engine**

```bash
git add src/core tests
git commit -m "feat: add RDMA receive queue engines"
```

### Task 18: 实现 CQ/CEQ/AEQ completion engine

**Files:**
- Create: `src/core/rdma_completion_engine.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_completion_engine_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 owner/wrap、关联、异常、overrun 和 stale completion 测试**

```systemverilog
mock_mem.push_image(cq.mapping, cqe_for(ticket.wr_id, .polarity(cq.expected_owner)));
completion.poll_cq(cq.handle, events, s);
if (!s.ok() || events.size() != 1 || events[0].wr_id != ticket.wr_id)
  `uvm_error("CQ", "completion not correlated")
binding.generation++;
mock_mem.push_image(cq.mapping, cqe_for(ticket.wr_id, .polarity(cq.expected_owner)));
completion.poll_cq(cq.handle, events, s);
if (s.code != RDMA_SC_STALE_GENERATION)
  `uvm_error("CQ", "stale CQE accepted")
```

- [ ] **Step 2: 在 53 上确认 completion engine 未定义**

Run: `scripts/run_vcs53.sh core rdma_completion_engine_test`

Expected: VCS FAIL，报告 `rdma_completion_engine` 未定义。

- [ ] **Step 3: 实现 CQ、CEQ、AEQ 的独立 consumer**

每条队列单独维护 monotonic CI 和 expected owner；先读取完整 entry，再验证 owner，decode
后以 Function generation + WR/command/QP/CQ ID 关联 outstanding。正常 CQE 释放 SQ/RQ
credit；异常 CQE 发布 `rdma_status`；CEQE 触发 CQ poll；AEQE 发布 async event。消费一批后
分别提交 CQ/CEQ/AEQ doorbell。overrun、未知 ID 和旧 generation completion 都保留原始
image 并报告错误，不推进错误资源的状态。

- [ ] **Step 4: 在 53 上运行 completion 测试**

Run: `scripts/run_vcs53.sh core rdma_completion_engine_test`

Expected: PASS；normal/error/wrap/overrun/stale case 的 CI 和 credit 均符合预期。

- [ ] **Step 5: 提交 completion engine**

```bash
git add src/core tests
git commit -m "feat: consume RDMA CQ and event queues"
```

### Task 19: 实现四视图 scoreboard 和 analysis 事件

**Files:**
- Create: `src/core/rdma_scoreboard.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_scoreboard_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写跨视图关联和错误 identity 测试**

```systemverilog
scb.write_intent(intent_event);
scb.write_image(image_event);
scb.write_transport(dma_event);
scb.write_completion(completion_event);
if (scb.pending_count() != 0 || scb.mismatch_count() != 0)
  `uvm_error("SCB", scb.report_string())
dma_event.requester_bdf.function++;
scb.write_transport(dma_event);
if (scb.mismatch_count() != 1) `uvm_error("SCB", "wrong requester not detected")
```

- [ ] **Step 2: 在 53 上确认 scoreboard 未定义**

Run: `scripts/run_vcs53.sh core rdma_scoreboard_test`

Expected: VCS FAIL，报告 `rdma_scoreboard` 未定义。

- [ ] **Step 3: 实现 intent/image/transport/completion 四视图**

所有 event 继承 `rdma_trace_event`，关联 key 固定为 Function UID + generation + resource kind
+ object ID + command/WR ID。image view 保存实际 byte 和字段摘要；transport view 保存 config
target BDF/offset、BAR decode、requester ID、DMA 地址/长度/方向、completion status 和 MSI-X；
completion view 保存原始 CQE/AEQE。`check_phase` 报告 unmatched/mismatch，但负向测试可通过
expected status 精确消费一个预期错误。

- [ ] **Step 4: 在 53 上运行 scoreboard 测试**

Run: `scripts/run_vcs53.sh core rdma_scoreboard_test`

Expected: PASS；正确链路 pending 为 0，错误 requester 产生且仅产生一个 mismatch。

- [ ] **Step 5: 提交 scoreboard**

```bash
git add src/core tests
git commit -m "feat: correlate RDMA intent image transport and completion"
```

---

## 阶段四：PCIe Function、VF/BAR/notify/DMI/VFT 和 64-bit DMA

### Task 20: 实现 Function binding registry 和闭环校验

**Files:**
- Create: `src/core/rdma_function_manager.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_function_binding_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写多 VF 正常闭环和 identity 冲突测试**

```systemverilog
s = fm.register_prepared(binding0);
if (!s.ok()) `uvm_error("BIND", s.convert2string())
s = fm.register_prepared(binding1);
if (!s.ok()) `uvm_error("BIND", s.convert2string())
binding2.rdma_vf_id = binding0.rdma_vf_id;
if (fm.register_prepared(binding2).code != RDMA_SC_INVALID_ARGUMENT)
  `uvm_error("ID", "duplicate rdma_vf_id accepted")
binding2.rdma_vf_id = 9;
binding2.pfvf_id = binding0.pfvf_id;
if (fm.register_prepared(binding2).code != RDMA_SC_INVALID_ARGUMENT)
  `uvm_error("ID", "duplicate pfvf_id accepted")
```

- [ ] **Step 2: 在 53 上确认 function manager 未定义**

Run: `scripts/run_vcs53.sh core rdma_function_binding_test`

Expected: VCS FAIL，报告 `rdma_function_manager` 未定义。

- [ ] **Step 3: 实现多索引 registry 和双向闭环验证**

registry 分别按 BDF、notify base、pfvf_id、rdma_vf_id、Function UID 索引同一个 binding；
不使用 vf_index 算出任何逻辑 ID。`register_prepared()` 检查 BDF/BAR aperture、8 KiB notify
对齐、host_id 在 notify 与 DMI 一致、VFT `pfvf_id -> rdma_vf_id`、DMI
`rdma_vf_id -> host_id/global_function_id`、DMA domain owner。只有所有索引原子插入成功后
才能进入 PREPARED；任一冲突不留下部分索引。

- [ ] **Step 4: 在 53 上运行 binding 测试**

Run: `scripts/run_vcs53.sh core rdma_function_binding_test`

Expected: PASS；vf_index、BDF function、pfvf_id、rdma_vf_id 分别取不同数值仍可正确绑定。

- [ ] **Step 5: 提交 Function registry**

```bash
git add src/core tests
git commit -m "feat: validate explicit RDMA PCIe function bindings"
```

### Task 21: 实现 pcie_work adapter 的 config、SR-IOV 和 BAR 路由

**Files:**
- Create: `src/adapters/pcie_work/rdma_pcie_work_adapter_pkg.sv`
- Create: `sim/filelists/pcie_work.f`
- Modify: `sim/Makefile`
- Create: `tests/integration/rdma_pcie_work_adapter_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写真实 config 枚举结果驱动的 VF/BAR 测试**

先创建 `pcie_work.f` 和 Makefile `pcie_work` target，沿用该仓库公开 filelist并追加 RDMA
core/adapter/test；filelist 引用尚不存在的 adapter package，保证 Step 2 在该边界失败。

```systemverilog
adapter.func_mgr = pcie_env.func_mgr;
adapter.bar_decoder = pcie_tl_bar_decoder::type_id::create("decoder");
adapter.bar_decoder.func_mgr = adapter.func_mgr;
adapter.discover_sriov(pf_bdf, sriov_info, s);
if (!s.ok() || sriov_info.first_vf_offset == 0 || sriov_info.vf_stride == 0)
  `uvm_error("SRIOV", "capability not enumerated")
s = adapter.get_function_info(vf_bdf, info);
if (!s.ok() || info.bar[0].size != 64'h4000)
  `uvm_error("VF_BAR", "DPU VF BAR0 is not 16 KiB")
```

- [ ] **Step 2: 在 53 上确认外部 adapter 未定义**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  scripts/run_vcs53.sh pcie_work rdma_pcie_work_adapter_test
```

Expected: VCS FAIL，报告 `rdma_pcie_work_adapter` 未定义。

- [ ] **Step 3: 组合现有 pcie_work 对象并封装 Function-aware API**

adapter 持有 `pcie_tl_func_manager`、`pcie_tl_bar_decoder`、config proxy/RC sequencer 句柄；
显式连接 `bar_decoder.func_mgr` 并检查 `multi_function_mode`。model-only 使用
`PCIE_CFG_PROFILE_DPU_20F9_501X`：PF BAR0/2/4 为 32 MiB/64 KiB/64 KiB，VF BAR0/2/4
为 16 KiB/16 KiB/32 KiB。DUT 模式必须用 4 KiB config request 读取 SR-IOV capability、
FirstVFOffset、VFStride、TotalVFs、NumVFs、VF BAR 和 command register，不能用 profile
覆盖读取结果。BAR decode 调用 `pcie_tl_bar_decoder.decode()` 并转换为
`rdma_bar_decode`。

若非 bypass config write 后 `func_mgr.lookup_by_bdf()`、MSE/BME、VFE 或 BDF LUT 没有
同步，adapter 返回 `RDMA_SC_INVALID_STATE` 并报告缺失的 pcie_work 能力；禁止直接改一个
影子 context 后继续声称 DUT 已配置。

- [ ] **Step 4: 在 53 上运行 PCIe adapter 测试**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  scripts/run_vcs53.sh pcie_work rdma_pcie_work_adapter_test
```

Expected: PASS；两 VF 的 BDF、BAR aperture 和 notify address 不重叠，BAR decode 返回对应
VF BDF/BAR0/offset，disabled VF decode 被拒绝。

- [ ] **Step 5: 提交 pcie_work adapter**

```bash
git add src/adapters/pcie_work sim tests
git commit -m "feat: adapt PCIe SR-IOV functions and BAR routing"
```

### Task 22: 实现 config 枚举与 VF BAR 分配 sequence

**Files:**
- Modify: `src/core/rdma_function_manager.svh`
- Create: `tests/integration/rdma_sriov_enumeration_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写枚举顺序、64-bit BAR pair 和 VF aperture 测试**

```systemverilog
fm.enumerate_and_configure_pf(pf_bdf, 4, discovered, s);
if (!s.ok() || discovered.size() != 4) `uvm_error("ENUM", s.convert2string())
foreach (discovered[i]) begin
  expected_bdf = add_rid(pf_bdf, sriov.first_vf_offset + i * sriov.vf_stride);
  if (discovered[i].bdf != expected_bdf) `uvm_error("VF_BDF", "RID mismatch")
  if ((discovered[i].bar[0].base.value & (discovered[i].bar[0].size-1)) != 0)
    `uvm_error("VF_BAR", "BAR alignment")
end
```

- [ ] **Step 2: 在 53 上确认尚无 frontdoor 枚举流程**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  scripts/run_vcs53.sh pcie_work rdma_sriov_enumeration_test
```

Expected: FAIL，config call log 不符合枚举顺序或没有 binding 输出。

- [ ] **Step 3: 实现标准 SR-IOV 顺序**

流程固定为：枚举 PF/定位 capability；读取 FirstVFOffset/VFStride/TotalVFs；BAR sizing；
从可配置 64-bit MMIO allocator 分配 PF BAR 和 VF aggregate BAR；写 NumVFs、VF BAR、ARI、
VF MSE、VFE；计算每个 VF BDF；逐 VF 读取 vendor/device/command 验证 config space；调用
BAR decoder 验证 aperture。所有加法/乘法使用 65-bit 溢出检查。失败时关闭 VFE、清除
NumVFs 并释放本次 BAR lease，不改动其他 PF。

- [ ] **Step 4: 在 53 上运行枚举测试**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  scripts/run_vcs53.sh pcie_work rdma_sriov_enumeration_test
```

Expected: PASS；覆盖 FirstVFOffset 非 1、VFStride 非 1、64-bit BAR 超过 4 GiB、BAR sizing
失败回滚和两 PF 无重叠。

- [ ] **Step 5: 提交 SR-IOV 枚举流程**

```bash
git add src/core/rdma_function_manager.svh tests
git commit -m "feat: enumerate RDMA VFs from PCIe configuration"
```

### Task 23: 实现 notify/DMI/VFT table adapter 和事务式激活

**Files:**
- Modify: `src/adapters/pcie_work/rdma_pcie_work_adapter_pkg.sv`
- Modify: `src/core/rdma_function_manager.svh`
- Create: `tests/integration/rdma_function_activation_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写三表内容、激活顺序和每点失败回滚测试**

```systemverilog
fm.activate(binding, s);
if (!s.ok() || binding.state != RDMA_BIND_ACTIVE)
  `uvm_error("ACTIVATE", s.convert2string())
if (table_mock.calls != '{"notify_program", "dmi_program", "runtime_init", "vft_program"})
  `uvm_error("ORDER", "activation order mismatch")
if (table_mock.notify.host_id != binding.host_id ||
    table_mock.dmi.rdma_vf_id != binding.rdma_vf_id ||
    table_mock.vft.pfvf_id != binding.pfvf_id)
  `uvm_error("TABLE", "identity chain mismatch")
```

- [ ] **Step 2: 在 53 上确认没有三表事务**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  scripts/run_vcs53.sh pcie_work rdma_function_activation_test
```

Expected: FAIL，table call log 为空或 binding 未进入 ACTIVE。

- [ ] **Step 3: 实现 xtr_v1 表项和逆序 rollback**

表项编码严格使用真实定义：notify entry 为 8 bytes，包含 8 KiB 对齐 base address、3-bit
host_id、8-bit pfvf_id；DMI entry 为 4 bytes，以 rdma_vf_id 索引，包含 valid、3-bit
host_id、10-bit global_function_id；VFT entry 为 4 bytes，以 pfvf_id 索引，包含 8-bit
rdma_vf_id 和 valid。notify 的 sel/index 作为 binding 独立字段，不从 vf_index 推导。

`rdma_pcie_work_function_table_adapter` 接收由 DUT testbench 注入的 table frontdoor；
frontdoor 明确给出 notify、DMI、VFT 的地址域和 responder owner。父驱动未公开的地址路由
不得由 adapter 猜测。激活顺序为 notify -> DMI -> runtime/CMQ/HMC/EQ -> VFT -> ACTIVE；
任一步失败按 VFT -> runtime -> DMI -> notify 清理。清理失败保留首个原因并把 binding
置为 ERROR。

- [ ] **Step 4: 在 53 上运行 Function 激活测试**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  scripts/run_vcs53.sh pcie_work rdma_function_activation_test
```

Expected: PASS；每个注入失败点的 valid bit 均清零、mapping/资源均回收，成功路径闭环一致。

- [ ] **Step 5: 提交 Function 激活流程**

```bash
git add src/adapters/pcie_work src/core/rdma_function_manager.svh tests
git commit -m "feat: activate RDMA functions through notify DMI and VFT"
```

### Task 24: 实现 Function-aware 64-bit DMA guard 和 host responder

**Files:**
- Modify: `src/adapters/pcie_work/rdma_pcie_work_adapter_pkg.sv`
- Create: `tests/integration/rdma_function_dma_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 requester、BME、domain、权限、越界和 4 GiB 以上测试**

```systemverilog
dma.requester_id = rdma_bdf_requester_id(binding.pcie.bdf);
dma.address = mapping.iova.value;
dma.length = 256;
dma.direction = RDMA_DMA_DEVICE_READ;
s = guard.authorize(dma, binding, mapping);
if (!s.ok()) `uvm_error("DMA", s.convert2string())
dma.requester_id++;
if (guard.authorize(dma, binding, mapping).code != RDMA_SC_DMA_PERMISSION)
  `uvm_error("DMA", "wrong requester accepted")
```

- [ ] **Step 2: 在 53 上确认 DMA 尚未按 Function 鉴权**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh pcie_work rdma_function_dma_test
```

Expected: FAIL，错误 requester 或关闭 BME 的请求仍被接受。

- [ ] **Step 3: 在 pcie_work adapter 边界集中实现 DMA guard**

检查顺序为 binding ACTIVE、generation、BME、requester BDF、可选 PASID、IOVA domain、
mapping state、direction/permission、`address + length` 65-bit 边界。host responder 使用注入
的同一个 `host_mem_api`，不重新 `init_region()`；地址保持 64 bit。辅助生成 EP DMA TLP 时
必须显式写 `requester_id = rdma_bdf_requester_id(binding.pcie.bdf)`，不得调用会随机 requester 的
通用 sequence。DUT 发起的 DMA 由 monitor 经过同一 guard 后再交给 responder。

- [ ] **Step 4: 在 53 上运行 DMA 测试**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh pcie_work rdma_function_dma_test
```

Expected: PASS；4 GiB 以上 read/write 数据一致，错误 requester/BME/PASID/domain/permission/
boundary 均返回确定错误，多 VF 使用相同 IOVA 数值时仍互相隔离。

- [ ] **Step 5: 提交 DMA guard**

```bash
git add src/adapters/pcie_work tests
git commit -m "feat: guard 64-bit RDMA DMA by PCIe function"
```

### Task 25: 实现 VF disable、FLR 和 generation 隔离

**Files:**
- Modify: `src/core/rdma_function_manager.svh`
- Create: `tests/integration/rdma_vf_reset_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 reset 顺序、相邻 VF 隔离和 stale completion 测试**

```systemverilog
old_generation = vf0.generation;
fm.reset(vf0.make_handle(), RDMA_RESET_FLR, s);
if (!s.ok() || vf0.generation != old_generation + 1)
  `uvm_error("FLR", s.convert2string())
if (vf1.state != RDMA_BIND_ACTIVE) `uvm_error("ISOLATION", "VF1 changed")
completion.function_generation = old_generation;
if (completion_engine.accept(completion).code != RDMA_SC_STALE_GENERATION)
  `uvm_error("STALE", "old completion accepted")
```

- [ ] **Step 2: 在 53 上确认 reset 流程未实现**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  scripts/run_vcs53.sh pcie_work rdma_vf_reset_test
```

Expected: FAIL，binding generation 未递增或 table/mapping 未清理。

- [ ] **Step 3: 实现严格 quiesce/flush/clear/disable 流程**

顺序固定为 QUIESCING、clear VFT、取消/等待 CMQ 与 DMA、TQ/QP/OCC flush、释放
CQ/QP/MR/HMC/interrupt、clear DMI、clear notify/mapping、disable VF/remove BDF LUT、
generation++、RELEASED。新 WR/doorbell 在 QUIESCING 后立即拒绝。每个阶段只按 Function
UID 筛选，不能清理同 PF 的其他 VF。旧 generation 的 deferred callback 在入口即丢弃。

- [ ] **Step 4: 在 53 上运行 VF reset 测试**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  scripts/run_vcs53.sh pcie_work rdma_vf_reset_test
```

Expected: PASS；每个失败注入点最终进入 ERROR 或 RELEASED，VF1 始终 ACTIVE 且数据不变。

- [ ] **Step 5: 提交 reset 生命周期**

```bash
git add src/core/rdma_function_manager.svh tests
git commit -m "feat: isolate RDMA VF reset by generation"
```

---

## 阶段五：net_packet、axis_vip、环境装配和端到端场景

网络依赖固定为：

- `net_packet` master `6766c4f042484814548481065328ffbcffab590f`；
- `axis_vip` master `8bbd960f4f5b53d3c7c7026c531a6c317b8bd5de`。

53 上使用独立依赖目录准备固定版本：

```bash
ssh ubuntu@10.11.10.53 "bash -lc 'source ~/.bashrc >/dev/null 2>&1; \
  mkdir -p /home/ubuntu/workspace/rdma_deps; \
  test -d /home/ubuntu/workspace/rdma_deps/net_packet-6766c4f/.git || \
    git clone https://github.com/Beihang-yuting/net_packet.git \
      /home/ubuntu/workspace/rdma_deps/net_packet-6766c4f; \
  git -C /home/ubuntu/workspace/rdma_deps/net_packet-6766c4f diff --quiet; \
  git -C /home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
    checkout --detach 6766c4f042484814548481065328ffbcffab590f; \
  test -d /home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960/.git || \
    git clone https://github.com/Beihang-yuting/axis_vip.git \
      /home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960; \
  git -C /home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960 diff --quiet; \
  git -C /home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960 \
    checkout --detach 8bbd960f4f5b53d3c7c7026c531a6c317b8bd5de'"
```

若目录已存在，分别用
`git -C /home/ubuntu/workspace/rdma_deps/net_packet-6766c4f rev-parse HEAD` 和
`git -C /home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960 rev-parse HEAD` 校验；只有目录由本计划
创建且没有本地修改时才删除并重建，不能覆盖其他人的 checkout。

### Task 26: 实现 net_packet 语义包适配

**Files:**
- Create: `src/adapters/net_packet/rdma_net_packet_adapter_pkg.sv`
- Create: `sim/filelists/net_packet.f`
- Modify: `sim/Makefile`
- Create: `tests/integration/rdma_net_packet_adapter_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 RDMA packet 生成、解析、drop/corruption/delay 测试**

先创建 `net_packet.f` 和 Makefile `net_packet` target，以 `+define+UVM` 编译固定 commit 的
`filelist.f` 并追加 RDMA adapter/test；adapter package 此时尚不存在。

```systemverilog
rdma_packet p;
p.transport = RDMA_TRANSPORT_RC;
p.opcode = RDMA_NET_WRITE_ONLY;
p.dest_qpn = 24'h123456;
p.psn = 24'h654321;
p.payload = '{8'hde, 8'had, 8'hbe, 8'hef};
s = adapter.encode_packet(p, bytes);
if (!s.ok()) `uvm_error("NET_ENC", s.convert2string())
s = adapter.decode_packet(bytes, decoded);
if (!s.ok() || !p.semantic_equal(decoded)) `uvm_error("NET_DEC", "round-trip")
```

- [ ] **Step 2: 在 53 上确认 net_packet adapter 未定义**

Run:

```bash
NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  scripts/run_vcs53.sh net_packet rdma_net_packet_adapter_test
```

Expected: VCS FAIL，报告 `rdma_net_packet_adapter` 未定义。

- [ ] **Step 3: 复用 packet/packet_item 而非重写发包器**

adapter 使用 `packet` 的 layer stack、RDMA/storage header 和 `raw_data`；生成路径为
`rdma_packet -> packet -> do_pack() -> raw_data`，接收路径用 parser/comparator 转回
`rdma_packet`。实现 `rdma_net_api` 的 observer 和 response policy；drop/corruption/delay
只作用于 adapter 选中的 packet，记录原始及修改后 byte。adapter 不创建 axis env，也不
直接驱动 pin。

- [ ] **Step 4: 在 53 上运行 net_packet adapter 测试**

Run:

```bash
NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  scripts/run_vcs53.sh net_packet rdma_net_packet_adapter_test
```

Expected: PASS；RC/UD/URC header 与 payload round-trip，三种 fault policy 可重复且有 seed。

- [ ] **Step 5: 提交 net_packet adapter**

```bash
git add src/adapters/net_packet sim tests
git commit -m "feat: adapt net_packet for RDMA traffic"
```

### Task 27: 实现 axis_vip beat 适配和 backpressure

**Files:**
- Create: `src/adapters/axis_vip/rdma_axis_vip_adapter_pkg.sv`
- Create: `sim/filelists/axis_vip.f`
- Modify: `sim/Makefile`
- Create: `tests/integration/rdma_axis_vip_adapter_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 packet-to-beat、tkeep/tlast、monitor 重组和 backpressure 测试**

先创建 `axis_vip.f` 和 Makefile `axis_vip` target，编译固定 axis/net filelist、RDMA core 和
测试；adapter package 此时尚不存在。

```systemverilog
adapter.master_sqr = axis_env.master_agent.sequencer;
adapter.send_packet(rdma_pkt, s);
if (!s.ok()) `uvm_error("AXIS_TX", s.convert2string())
if (beat_log[$].tlast != 1 || beat_log[$].tkeep != expected_last_tkeep)
  `uvm_error("AXIS_FMT", "last beat mismatch")
adapter.on_axis_packet(monitored_packet);
if (!observer.last_packet.semantic_equal(rdma_pkt))
  `uvm_error("AXIS_RX", "reassembly mismatch")
```

- [ ] **Step 2: 在 53 上确认 axis adapter 未定义**

Run:

```bash
NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  AXIS_VIP_ROOT=/home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960/axis_vip \
  scripts/run_vcs53.sh axis_vip rdma_axis_vip_adapter_test
```

Expected: VCS FAIL，报告 `rdma_axis_vip_adapter` 未定义。

- [ ] **Step 3: 复用 axis_transfer、sequencer 和 monitor analysis port**

发送侧使用现有 `axis_net_packet_seq`/`axis_transfer` 将 packet byte 按 DATA_WIDTH 切 beat，
最后一 beat 计算 tkeep 并置 tlast；tid/tdest/tuser 由 metadata 显式给出。接收侧连接
`axis_monitor.packet_ap`，转换为 byte 后发布给 `rdma_net_api` observer。backpressure 由
axis slave config/sequence 控制，RDMA adapter 只记录 stall latency。adapter 不创建
`axis_env`，只接收上层注入的 sequencer 和 analysis export。

- [ ] **Step 4: 在 53 上运行 axis_vip adapter 测试**

Run:

```bash
NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  AXIS_VIP_ROOT=/home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960/axis_vip \
  scripts/run_vcs53.sh axis_vip rdma_axis_vip_adapter_test
```

Expected: PASS；1 byte、总线宽度整倍数、非整倍数和 4 KiB packet 都可重组，随机
backpressure 不丢 beat。

- [ ] **Step 5: 提交 axis_vip adapter**

```bash
git add src/adapters/axis_vip sim tests
git commit -m "feat: adapt RDMA packets to AXIS VIP"
```

### Task 28: 实现 responder region 唯一性和 DUT/model/hybrid 模式

**Files:**
- Create: `src/core/rdma_responder_registry.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_responder_registry_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写重叠 responder 和模式策略测试**

```systemverilog
s = responders.claim(cfg_region, "real_dut", RDMA_RESPONDER_DUT);
if (!s.ok()) `uvm_error("RESP", s.convert2string())
s = responders.claim(cfg_region, "pcie_vip", RDMA_RESPONDER_VIP);
if (s.code != RDMA_SC_INVALID_STATE) `uvm_error("RESP", "double responder accepted")
s = responders.claim(host_dma_region, "host_mem", RDMA_RESPONDER_VIP);
if (!s.ok()) `uvm_error("RESP", "disjoint host responder rejected")
```

- [ ] **Step 2: 在 53 上确认 responder registry 未定义**

Run: `scripts/run_vcs53.sh core rdma_responder_registry_test`

Expected: VCS FAIL，报告 `rdma_responder_registry` 未定义。

- [ ] **Step 3: 实现按事务类型和地址域的唯一 claim**

claim key 包含 config/MMIO/memory/non-posted/network 类型、root/port、地址 base/size 和
owner。DUT 模式只允许 VIP claim host memory response 和 monitor；model-only 允许 config/
BAR model；hybrid 必须逐 region 声明。build phase 结束调用 `seal()`，之后不允许动态新增
可能与飞行事务冲突的 responder。重叠且两者都可响应同一 request 时 `uvm_fatal`。

- [ ] **Step 4: 在 53 上运行 responder registry 测试**

Run: `scripts/run_vcs53.sh core rdma_responder_registry_test`

Expected: PASS；完全重叠、部分重叠和 overflow range 都被检测，monitor-only 不算 responder。

- [ ] **Step 5: 提交 responder registry**

```bash
git add src/core tests
git commit -m "feat: prevent duplicate DUT and VIP responders"
```

### Task 29: 装配可选 adapter 的 rdma_env

**Files:**
- Create: `src/core/rdma_env_config.svh`
- Create: `src/core/rdma_env.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_env_composition_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 core-only、DUT、model-only 和 hybrid 装配测试**

```systemverilog
uvm_config_db#(rdma_env_config)::set(this, "env", "cfg", cfg);
env = rdma_env::type_id::create("env", this);
// core-only: no pcie/net adapter; codec/resource tests remain enabled.
// DUT: injected pcie+host, VIP responder only owns host DMA region.
// model-only: mock pcie/table/net may own declared regions.
// hybrid: only cfg.assist_regions may be VIP-owned.
```

每个 case 在 end_of_elaboration 检查 env 没有创建 `pcie_env` 或 `axis_env` 子组件。

- [ ] **Step 2: 在 53 上确认 rdma_env 未定义**

Run: `scripts/run_vcs53.sh core rdma_env_composition_test`

Expected: VCS FAIL，报告 `rdma_env` 未定义。

- [ ] **Step 3: 实现 config_db 注入和 capability gate**

`rdma_env_config` 包含 mode、hardware version、adapter enable/required bit、timeout、queue
profile 和 responder regions。`rdma_env` 创建 resource/codec/engine/scoreboard/function
manager；从 `uvm_config_db` 获取抽象 API handle。缺少 optional adapter 时设置
model-only/passive/disabled capability；缺少 required adapter 时 build fatal。所有 engine
只引用抽象 API，不向下 cast 外部 adapter class。PCIe adapter 的 config/MMIO/DMA/MSI-X
monitor analysis event 连接 scoreboard transport view；MSI-X event 必须携带 target Function、
vector 和 generation，不能只记录 vector number。

- [ ] **Step 4: 在 53 上运行组合测试和 core-only 回归**

Run:

```bash
scripts/run_vcs53.sh core rdma_env_composition_test
scripts/run_vcs53.sh core rdma_smoke_test
```

Expected: PASS；core filelist 不需要任何外部 package，四种配置的 capability 与预期一致。

- [ ] **Step 5: 提交 rdma_env**

```bash
git add src/core tests
git commit -m "feat: compose RDMA environment from optional adapters"
```

### Task 30: 实现 RC/UD/URC 端到端 virtual sequence

**Files:**
- Create: `tests/integration/rdma_end_to_end_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写从 Function 激活到 completion 的三 transport 场景**

```systemverilog
foreach (transports[i]) begin
  seq.transport = transports[i];
  seq.create_pd_mr_cq_qp();
  seq.post_receive();
  seq.post_send();
  seq.wait_completion(100us, status);
  if (!status.ok()) `uvm_error("E2E", status.convert2string())
  seq.destroy_resources();
end
if (env.scoreboard.pending_count() != 0 || env.resources.leak_count() != 0)
  `uvm_error("E2E", "pending event or resource leak")
```

- [ ] **Step 2: 在 53 上确认没有完整场景**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  AXIS_VIP_ROOT=/home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960/axis_vip \
  scripts/run_vcs53.sh axis_vip rdma_end_to_end_test
```

Expected: FAIL，test class 或 virtual sequence 未定义。

- [ ] **Step 3: 实现可复用场景 sequence 和真实 DUT 接口边界**

sequence 只调用 rdma_env 的语义 API：枚举/绑定 Function、创建资源、注入 payload、post
WR、等待 completion、销毁。model-only 使用明确的 mock device responder；真实 DUT testbench
注入 PCIe/AXIS adapter、table frontdoor 和 DUT reset/MSI-X monitor，sequence 本身不引用 DUT
层次路径。RC 覆盖 send/write/read/atomic，UD 覆盖 send，URC 覆盖 send/write/read；每个
场景检查 host payload、network packet、CQE 和 scoreboard 四视图。

- [ ] **Step 4: 在 53 上运行端到端场景**

Run: 与 Step 2 相同的命令。

Expected: PASS；RC/UD/URC 全部完成，UVM error/fatal 为 0，resource/mapping/outstanding/
scoreboard pending 均为 0。

- [ ] **Step 5: 提交端到端场景**

```bash
git add tests
git commit -m "test: add RDMA RC UD and URC end-to-end scenarios"
```

### Task 31: 实现多 VF 并发、错误恢复和回归入口

**Files:**
- Create: `tests/integration/rdma_multivf_recovery_test.svh`
- Create: `src/core/rdma_coverage.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `sim/Makefile`
- Create: `sim/regression.list`
- Create: `README.md`

- [ ] **Step 1: 写四 VF 并发和 fault matrix**

```systemverilog
fork
  vf_seq[0].start(null);
  vf_seq[1].start(null);
  vf_seq[2].start(null);
  vf_seq[3].start(null);
join
faults = '{RDMA_FAULT_WRONG_REQUESTER, RDMA_FAULT_IOVA_PERMISSION,
           RDMA_FAULT_CMQ_TIMEOUT, RDMA_FAULT_CQE_ERROR,
           RDMA_FAULT_PACKET_DROP, RDMA_FAULT_VF_FLR};
foreach (faults[i]) run_fault_case(faults[i]);
```

- [ ] **Step 2: 在 53 上确认并发回归未定义**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  AXIS_VIP_ROOT=/home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960/axis_vip \
  scripts/run_vcs53.sh axis_vip rdma_multivf_recovery_test
```

Expected: FAIL，test class 或 fault runner 未定义。

- [ ] **Step 3: 实现并发场景、回归列表和使用文档**

四个 VF 使用不同 BDF/pfvf_id/rdma_vf_id/notify window/DMA domain，同时提交 CMQ 与 WR；
其中两个 VF 使用相同数值 IOVA 验证 domain 隔离。fault matrix 的每个 case 明确一个 expected
`rdma_status`，FLR case 检查旧 generation completion 被拒绝且其他 VF 无中断。Makefile
`regression` 逐行运行 `sim/regression.list` 并汇总 test/seed/pass/fail。README 给出 package
依赖、adapter 注入、三种模式、53 命令、地址空间和真实 DUT 接线清单。

`rdma_coverage` 订阅四视图 event，coverpoint 包含 transport、WR opcode、CMQ opcode、
doorbell kind、resource kind、Function count、queue wrap、DMA 高 32 bit 非零、status category、
reset stage；cross 至少包含 transport x WR opcode、Function x DMA domain、error x source engine、
doorbell x Function state。illegal bin 覆盖 ACTIVE 前 doorbell、错误 requester 成功 completion 和
stale generation 状态更新。

- [ ] **Step 4: 在 53 上运行完整回归**

Run:

```bash
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  AXIS_VIP_ROOT=/home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960/axis_vip \
  scripts/run_vcs53.sh axis_vip regression
```

Expected: regression summary 全部 PASS；每个 test 的 `UVM_ERROR : 0`、`UVM_FATAL : 0`；预期
负向错误只出现在 `rdma_status`/analysis event，不计入未预期 UVM error。

- [ ] **Step 5: 提交回归入口与文档**

```bash
git add src/core/rdma_coverage.svh src/core/rdma_core_pkg.sv tests sim README.md
git commit -m "test: add multi-VF RDMA recovery regression"
```

---

## 5. 最终验收命令

按以下顺序执行，任一步失败都不宣称实现完成：

```bash
git diff --check
rg -n "host_mem_pkg|pcie_tl_pkg|axis_pkg|packet_item" \
  src/types src/model src/adapter src/codec src/core
scripts/run_vcs53.sh core regression
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem regression
PCIE_WORK_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work \
  HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh pcie_work regression
NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  scripts/run_vcs53.sh net_packet regression
NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  AXIS_VIP_ROOT=/home/ubuntu/workspace/rdma_deps/axis_vip-8bbd960/axis_vip \
  scripts/run_vcs53.sh axis_vip regression
```

第二条 `rg` 的期望结果为空；外部 package 只能出现在 `src/adapters/*` 和对应 filelist。

验收记录必须包含：

- VCS 版本、每个外部仓库 commit、DUT RTL commit/profile；
- 每个 test 的 seed 和 log path；
- Function binding 表：BDF、BAR、notify、host_id、pfvf_id、rdma_vf_id、generation；
- 4 GiB 以上 DMA 的 requester ID、IOVA、backing address 和 completion；
- responder registry dump，证明真实 DUT 与 VIP 没有双重 responder；
- resource/mapping/command/WR leak count 全部为 0。

## 6. 阶段完成定义

- 阶段一完成后，core-only 能编译，64-bit host memory 和 generation-safe resource 可用。
- 阶段二完成后，多 QPC/context、多 CMQ opcode、batch/outstanding 和多 doorbell 可用。
- 阶段三完成后，SQ/RQ/CQ/EQ 数据面和四视图 scoreboard 可在 mock transport 上闭环。
- 阶段四完成后，真实 PCIe config 枚举、VF/BAR/三表绑定、64-bit DMA 和 FLR 可闭环。
- 阶段五完成后，net_packet/axis_vip 可选接入且 RC/UD/URC、多 VF、错误恢复回归通过。

每个阶段最后的 commit 必须保持前面阶段的 filelist 和回归仍然通过。
