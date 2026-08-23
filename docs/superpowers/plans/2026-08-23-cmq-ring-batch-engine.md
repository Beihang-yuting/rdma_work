# CMQ Ring、Batch 与多 Outstanding Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现一个面向真实 DUT、由 host-memory CQE 驱动完成、支持 32-entry 全容量、混合 opcode batch、乱序完成、timeout quarantine 和 Function generation 生命周期的通用 UVM CMQ engine。

**Architecture:** `rdma_cmq_engine` 只管理通用 ring、ticket、完成和 backing 生命周期；`rdma_cmq_hw_profile` 隔离设备格式，`rdma_xtr_v1_cmq_hw_profile` 复用现有 composer、completion/error/doorbell codec。engine 通过注入的 `rdma_host_mem_api` 和 `rdma_doorbell_scheduler` 调用外部组件，不构造 `pcie_env`、`axis_env`、VIP 或真实 DUT；`prepare()` 返回 runtime descriptor，Task 23 编程真实 CMQ context 后再调用 `activate()`。

**Tech Stack:** SystemVerilog/UVM 1.2、Synopsys VCS（`10.11.10.53`）、`host_mem` adapter、现有 doorbell scheduler、xtr_v1 pinned driver commit `491faf2ba42627fffd4dd027607299c8bb591ec2`。

---

## 固定契约

- SQ/CQ depth 均为 32，entry 均为 64B；一个 4096B、4096B 对齐的 `RDMA_DMA_BIDIRECTIONAL` mapping，SQ offset `0`，CQ offset `2048`。
- 32 个 SQ slot 全部可用；只有 `publish_seq - retire_seq == 32` 才是 queue full。
- batch 中通过 validation/codec 的项按输入顺序压紧到连续 tentative slot；所有依赖写完后只发一次最终 PI/polarity doorbell。
- `publish_seq`、`retire_seq`、`cq_consume_seq` 都是 64-bit 单调序号；index 为 `seq % 32`，wrap 为 `(seq / 32) % 2`。
- timeout 只交付一次正常 completion，slot 留在 quarantine；迟到 CQE 只产生 diagnostic，不能产生第二个正常 completion。
- CQE 不携带软件 command ID。关联先用 Function generation + WQE index + wrap 找 slot，再从 slot 取 64-bit `{incarnation[58:0], token[4:0]}` command ID。
- malformed、unknown 或不匹配 CQE 保存 raw 64B image并 poison engine；只有 `reset()` 能离开 POISONED。
- `reset()`/`shutdown()` 必须释放 mapping；release 失败时保留 mapping authority 和可重试状态，不能伪装成成功清理。

本计划不实现 Task 14 的 PD/MR/CQ/QP/SRQ 控制面，不实现 Task 18 data-plane completion，
不猜测 Task 23 的 CMQ context register；也不复制 `pcie_env`、`axis_env`、`host_mem` 或
`axis_vip`。这些系统只通过已注入的抽象 adapter 或 runtime descriptor 与 engine 连接。

## 文件边界

| 文件 | 单一职责 |
|---|---|
| `src/model/rdma_dma_request_context.svh` | immutable-by-snapshot DMA requester、BDF、PASID 和 owner value object。 |
| `src/model/rdma_cmq_engine_models.svh` | opcode key、command、slot context、ticket、completion、diagnostic、runtime descriptor 和公开 engine state。 |
| `src/model/rdma_model_pkg.sv` | 按依赖顺序发布新 model。 |
| `src/adapter/rdma_host_mem_api.svh` | 把 allocation 输入从 Function handle 升级为 DMA request context。 |
| `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv` | 将 context 固化到真实 mapping/authority，拒绝调用方篡改。 |
| `tests/mocks/rdma_mock_adapters.svh` | mock host-memory context snapshot、mapping backing 和调用轨迹。 |
| `src/codec/rdma_cmq_hw_profile.svh` | hardware-neutral profile 抽象契约。 |
| `src/codec/xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh` | xtr_v1 SQE/CQE/error/doorbell glue。 |
| `src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh` | 显式 owner-ready CQE 解码并保留 bit63。 |
| `src/codec/rdma_codec_pkg.sv` | 发布抽象 profile 和 xtr_v1 profile。 |
| `src/core/rdma_cmq_engine.svh` | backing、ring、batch、completion、timeout、poison 和 lifecycle。 |
| `src/core/rdma_core_pkg.sv` | 导入 codec package并发布 engine。 |
| `tests/unit/rdma_cmq_engine_models_test.svh` | 新 value objects 的 copy/validate 边界。 |
| `tests/unit/rdma_xtr_v1_cmq_profile_test.svh` | profile 的 xtr_v1 位域、owner、target metadata 和 error 映射。 |
| `tests/unit/rdma_cmq_engine_test.svh` | prepare/activate、ring、batch、CQ、timeout、poison 和 lifecycle。 |
| `tests/unit/rdma_adapter_contract_test.svh` | 抽象 host-memory contract 和 mock authority。 |
| `tests/integration/rdma_host_mem_adapter_test.svh` | 真实 host_mem adapter 的 BDF/PASID/owner authority。 |
| `tests/rdma_unit_test_pkg.sv` | 发布三个新测试并保持 include 顺序。 |
| `sim/filelists/core.f`, `sim/filelists/host_mem.f` | 只读确认现有 types → model → codec → adapter → core 顺序；新文件由 package include，不预期修改。 |

## 最终公开接口

以下签名是后续任务的唯一命名基准；实现中不要再引入 `configure()`/`reap()` 等第二套别名：

```systemverilog
virtual class rdma_cmq_hw_profile extends uvm_object;
  pure virtual function string profile_name();
  pure virtual function rdma_status validate_profile();
  pure virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );
  pure virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );
  pure virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
endclass

class rdma_cmq_engine extends uvm_object;
  task prepare(
    rdma_function_binding binding,
    rdma_cmq cmq,
    bit pasid_valid,
    bit [19:0] pasid,
    rdma_host_mem_api host_mem,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_hw_profile profile,
    output rdma_cmq_runtime_desc runtime_desc,
    output rdma_status status
  );
  task activate(rdma_function_binding active_binding,
                output rdma_status status);
  task submit(rdma_cmq_command_desc request,
              output rdma_cmq_ticket ticket,
              output rdma_status status);
  task submit_batch(input rdma_cmq_command_desc requests[],
                    output rdma_cmq_ticket tickets[],
                    output rdma_status item_statuses[],
                    output rdma_status batch_status);
  task poll(output rdma_cmq_completion completions[$],
            output rdma_cmq_diagnostic diagnostics[$],
            output rdma_status status);
  task expire(output rdma_cmq_completion completions[$],
              output rdma_status status);
  task wait_for(rdma_cmq_ticket ticket,
                output rdma_cmq_completion completion,
                output rdma_status status);
  task cancel_generation(int unsigned generation,
                         output rdma_cmq_completion completions[$],
                         output rdma_status status);
  task reset(output rdma_cmq_completion completions[$],
             output rdma_status status);
  task shutdown(output rdma_status status);
endclass
```

`activate()` 不增加 PASID 参数。它校验 ACTIVE binding 的 Function/BDF，并校验内部
authority mapping 的 `pasid_valid/pasid` 仍等于 `prepare()` 固化的
`rdma_dma_request_context`；这是现有 `rdma_function_binding` 不含 PASID 时唯一不伪造来源的
一致性检查。

### Task 1: 引入 DMA Request Context 并原子迁移 Host-memory Contract

**Files:**
- Create: `src/model/rdma_dma_request_context.svh`
- Modify: `src/model/rdma_model_pkg.sv`
- Modify: `src/adapter/rdma_host_mem_api.svh`
- Modify: `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv`
- Modify: `tests/mocks/rdma_mock_adapters.svh`
- Modify: `tests/unit/rdma_adapter_contract_test.svh`
- Modify: `tests/unit/rdma_doorbell_scheduler_test.svh`
- Modify: `tests/integration/rdma_host_mem_adapter_test.svh`

- [ ] **Step 1: 写 context 和新 allocation contract 的失败测试**

在 `rdma_adapter_contract_test.svh` 增加统一 helper，并把所有 host-memory allocation 调用改为 context：

```systemverilog
function automatic rdma_dma_request_context make_dma_context(
  string name,
  rdma_function_handle function_h,
  rdma_bdf_t requester_bdf,
  bit pasid_valid = 1'b0,
  bit [19:0] pasid = '0,
  rdma_handle owner_h = null
);
  rdma_dma_request_context context;
  context = rdma_dma_request_context::type_id::create(name);
  context.function_h = rdma_mock_clone_function_handle(function_h);
  context.requester_bdf = requester_bdf;
  context.pasid_valid = pasid_valid;
  context.pasid = pasid;
  context.owner_h = (owner_h == null) ? null :
                    rdma_clone_handle_value(owner_h, "DMA context owner");
  return context;
endfunction
```

至少检查：deep copy 不别名；null/wrong-kind/zero-generation Function；
`pasid_valid==0 && pasid!=0`；跨 Function/generation owner；非零 VF BDF 和 20-bit PASID
原样进入 mock mapping；调用方事后修改 context 不改变 call record、mapping 或 authority。
`rdma_doorbell_scheduler_test.svh` 的 allocation 也必须使用与 `binding_a.pcie.bdf` 相同的
context，删除测试中手工改写 `mapping.requester_bdf` 的代码。

integration test 同时创建下面的 VF context，并把该文件所有旧 allocation 调用改用统一
context helper：

```systemverilog
request_context = rdma_dma_request_context::type_id::create("vf_dma_context");
request_context.function_h = make_function_handle("vf_function_h");
request_context.requester_bdf =
  '{segment:16'h0000, bus:8'h53, device:5'h02, function_num:3'h5};
request_context.pasid_valid = 1'b1;
request_context.pasid = 20'habcde;
request_context.owner_h = rdma_handle::type_id::create("cmq_owner");
request_context.owner_h.kind = RDMA_RESOURCE_CMQ;
request_context.owner_h.function_uid = request_context.function_h.function_uid;
request_context.owner_h.object_id = 32'h44;
request_context.owner_h.generation = request_context.function_h.generation;
status = adapter.allocate(request_context, 4096, 4096,
                          RDMA_DMA_BIDIRECTIONAL, mapping);
```

检查真实 mapping 五个 identity 字段都是 detached copy；分别篡改 BDF、PASID valid、
PASID、owner object ID 后，`read/write/release` 返回 `RDMA_SC_DMA_TRANSLATION`，原始 clone
仍可读写和释放。

- [ ] **Step 2: 在 53 上确认新 contract 失败**

Run:

```bash
scripts/run_vcs53.sh core rdma_adapter_contract_test
scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected RED: VCS 报告 `rdma_dma_request_context` 未定义，且旧
`allocate(rdma_function_handle, size, alignment, direction, mapping)`
签名不能匹配新测试。两个 suite 都必须先有 RED，避免提交一个会让 host_mem target 暂时
无法编译的半迁移 API。

- [ ] **Step 3: 实现 context、API 和 mock 的最小闭环**

`rdma_dma_request_context` 使用以下字段和 validation，不保存 binding 引用：

```systemverilog
class rdma_dma_request_context extends uvm_object;
  `uvm_object_utils(rdma_dma_request_context)
  rdma_function_handle function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  rdma_handle owner_h;

  function rdma_status validate();
    rdma_status status;
    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA request Function is invalid");
    if (function_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "DMA request Function generation is zero");
    if (!pasid_valid && pasid != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "invalid PASID must be zero");
    if (owner_h != null) begin
      status = rdma_handle_owner_status(owner_h, function_h);
      if (!status.ok()) return status;
    end
    return rdma_status::success();
  endfunction
endclass
```

`do_copy()` 必须 clone `function_h` 和可选 `owner_h`。把抽象 API 改成：

```systemverilog
pure virtual function rdma_status allocate(
  rdma_dma_request_context request_context,
  int unsigned size,
  int unsigned alignment,
  rdma_dma_direction_e direction,
  output rdma_dma_mapping mapping
);
```

mock 的 call record 保存 `rdma_dma_request_context request_context` snapshot；mock
`allocate()` 先 `request_context.validate()`，再把 context 的五个 authority 字段 clone/copy
进 mapping/region。`find_region()` 和 mutation checks 必须比较 Function、BDF、PASID、owner
全部 authority，而不是只比较 Function handle。

真实 adapter 使用相同新签名，并在任何 `mem.alloc()` 副作用之前完成 null/context
validation。成功分配时固定以下赋值：

```systemverilog
allocated_mapping.function_h = clone_function_handle(
  request_context.function_h);
allocated_mapping.requester_bdf = request_context.requester_bdf;
allocated_mapping.pasid_valid = request_context.pasid_valid;
allocated_mapping.pasid = request_context.pasid;
allocated_mapping.owner_h = rdma_clone_handle_value(
  request_context.owner_h, "host memory mapping owner");
```

继续使用现有 opaque allocation identity，且不得弱化 `mapping_values_match()`。context、
mapping authority 或 ledger clone 失败时释放刚取得的 backing，IOVA cursor 只能在全部成功
后提交。`rdma_model_pkg.sv` 的 include 顺序固定为 handle → function binding → DMA request
context → DMA mapping。

- [ ] **Step 4: 在 53 上确认 contract 和 scheduler 通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_adapter_contract_test
scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected GREEN: 三个测试均 `UVM_ERROR : 0`、`UVM_FATAL : 0`；scheduler dependency 不再
依赖调用方篡改 mapping BDF，真实 adapter 的 mutation/forgery cases 失败关闭且 leak count
为零。

- [ ] **Step 5: 提交抽象 contract 和 mock 迁移**

```bash
git add src/model/rdma_dma_request_context.svh src/model/rdma_model_pkg.sv \
  src/adapter/rdma_host_mem_api.svh \
  src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv \
  tests/mocks/rdma_mock_adapters.svh \
  tests/unit/rdma_adapter_contract_test.svh \
  tests/unit/rdma_doorbell_scheduler_test.svh \
  tests/integration/rdma_host_mem_adapter_test.svh
git commit -m "feat: preserve DMA requester authority end to end"
```

### Task 2: 定义 CMQ Engine 的公开 Value Objects

**Files:**
- Create: `src/model/rdma_cmq_engine_models.svh`
- Modify: `src/model/rdma_model_pkg.sv`
- Create: `tests/unit/rdma_cmq_engine_models_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写完整 model contract 的失败测试**

测试必须实例化并 deep-copy 以下图对象：

```systemverilog
rdma_cmq_opcode_key key;
rdma_cmq_command_desc command;
rdma_cmq_slot_context slot;
rdma_cmq_expected_response expected;
rdma_cmq_decoded_cqe decoded;
rdma_cmq_ticket ticket;
rdma_cmq_completion completion;
rdma_cmq_diagnostic diagnostic;
rdma_cmq_runtime_desc runtime_desc;
```

覆盖空 `profile_name/variant`、两者含 `|`、null body、zero timeout、Function generation
不匹配、slot index >= 32、offset/64B alignment 错误、zero command ID、zero absolute
deadline、null ticket/status、runtime SQ/CQ IOVA 加法溢出，以及 clone 后修改原始 nested
object 不影响 snapshot。xtr opcode 上 24bit 非零属于 Task 3 profile test，不放进通用 model。

- [ ] **Step 2: 在 53 上确认 models 未定义**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_models_test
```

Expected RED: VCS 报告第一处 `rdma_cmq_opcode_key` 未定义。

- [ ] **Step 3: 实现 models 和一致的字段命名**

使用以下 enum 和字段，后续任务不得改名：

```systemverilog
typedef enum bit [2:0] {
  RDMA_CMQ_ENGINE_UNCONFIGURED,
  RDMA_CMQ_ENGINE_PREPARED,
  RDMA_CMQ_ENGINE_ACTIVE,
  RDMA_CMQ_ENGINE_QUIESCED,
  RDMA_CMQ_ENGINE_POISONED
} rdma_cmq_engine_state_e;

typedef enum bit [1:0] {
  RDMA_CMQ_DIAG_LATE_COMPLETION,
  RDMA_CMQ_DIAG_MALFORMED_CQE,
  RDMA_CMQ_DIAG_UNKNOWN_CQE,
  RDMA_CMQ_DIAG_POISON
} rdma_cmq_diagnostic_kind_e;
```

对象字段固定为：

```systemverilog
// rdma_cmq_opcode_key
string profile_name; bit [31:0] opcode; string variant;

// rdma_cmq_command_desc
rdma_function_handle function_h; rdma_cmq_opcode_key opcode_key;
rdma_hw_model body; rdma_hw_image qpc_signature_source;
bit vfid_override; bit [10:0] use_vfid; time timeout;

// rdma_cmq_slot_context
rdma_function_handle function_h; rdma_handle cmq_h;
rdma_backing_addr_t backing_addr; longint unsigned relative_offset;
longint unsigned slot_sequence; int unsigned sq_index; bit sq_wrap;

// rdma_cmq_expected_response
bit [31:0] hardware_opcode; string variant;

// rdma_cmq_decoded_cqe
bit [31:0] hardware_opcode; int unsigned wqe_index; bit wqe_wrap;
bit [31:0] hardware_ecode; rdma_status command_status;
uvm_object response_payload;

// rdma_cmq_ticket
longint unsigned command_id; rdma_function_handle function_h;
rdma_handle cmq_h; longint unsigned slot_sequence;
int unsigned sq_index; bit sq_wrap; rdma_cmq_opcode_key opcode_key;
time absolute_deadline;

// rdma_cmq_completion
rdma_cmq_ticket ticket; rdma_status status;
rdma_hw_image raw_cqe; uvm_object decoded_response;

// rdma_cmq_diagnostic
rdma_cmq_diagnostic_kind_e kind; rdma_cmq_ticket ticket;
rdma_status status; rdma_hw_image raw_cqe;

// rdma_cmq_runtime_desc
rdma_function_handle function_h; rdma_handle cmq_h;
rdma_iova_t sq_iova; rdma_iova_t cq_iova;
int unsigned sq_depth; int unsigned cq_depth; int unsigned entry_bytes;
bit initial_sq_valid; bit initial_cq_owner; bit initial_doorbell_polarity;
```

所有 nested object 都 deep-copy。`rdma_cmq_opcode_key.validate()` 负责非空和 `|`；
硬件专属 opcode width 由 profile 检查。`completion.validate()` 要求 ticket/status 非空；
timeout/reset completion 允许 `raw_cqe==null`，硬件 completion 要求 64B raw image。
`rdma_model_pkg.sv` 必须在 `rdma_context_models.svh` 之后、
`rdma_queue_models.svh` 之前 include `rdma_cmq_engine_models.svh`，因为 command body 的静态
类型是前者定义的 `rdma_hw_model`。

- [ ] **Step 4: 在 53 上确认 model 测试通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_models_test
scripts/run_vcs53.sh core rdma_model_test
```

Expected GREEN: 新旧 model 测试都通过且 deep-copy negative cases 无 alias。

- [ ] **Step 5: 提交公开 models**

```bash
git add src/model/rdma_cmq_engine_models.svh src/model/rdma_model_pkg.sv \
  tests/unit/rdma_cmq_engine_models_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: define CMQ engine value models"
```

### Task 3: 定义 Hardware Profile 并实现 xtr_v1 Profile

**Files:**
- Create: `src/codec/rdma_cmq_hw_profile.svh`
- Create: `src/codec/xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh`
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Modify: `tests/unit/rdma_xtr_v1_cmq_completion_test.svh`
- Modify: `tests/unit/rdma_xtr_v1_context_cmq_regression_test.svh`
- Create: `tests/unit/rdma_xtr_v1_cmq_profile_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写 owner-ready、profile composition 和 error 的失败测试**

把 completion codec 的期望 API 固定为：

```systemverilog
status = completion_codec.inspect_completion(
  image, expected_owner, ready, completion);
```

测试 bit63 owner 不匹配时 `status.OK && !ready && completion==null`，且不检查 stale entry
其余 reserved bits；owner 匹配后 bit63 属于 allowed mask、decoded object 保留 owner，并对
所有其他 reserved bits fail closed。profile test 还要检查：

- `profile_name()=="xtr_v1"` 且 `validate_profile()` 成功，拒绝未初始化 profile、其他
  profile、opcode 上 24bit 非零和无效 VFID；
- `compose_sqe()` 产生 64B big-endian `RDMA_IMAGE_CMQ_SQE`，`valid=!sq_wrap`，index/wrap/opcode
  正确，target 为 `RDMA_HW_TARGET_BACKING` 且 address 等于 backing + offset；
- `inspect_cqe()` 返回 owner ready、5-bit index、wrap、opcode、原始 ecode、typed payload 和
  `rdma_xtr_v1_error_codec` 的 status；
- `encode_doorbell()` 复用 `cmq_sq` codec，PI/polarity 和 BAR offset `0x000` 正确。

- [ ] **Step 2: 在 53 上确认 profile API 失败**

Run:

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_profile_test
```

Expected RED: VCS 报告 `rdma_cmq_hw_profile`/
`rdma_xtr_v1_cmq_hw_profile` 未定义，旧 completion codec 无 owner-ready API。

- [ ] **Step 3: 实现抽象 profile 与 xtr_v1 glue**

抽象类严格使用“最终公开接口”中的 `profile_name()`、`validate_profile()` 和三个 codec
pure virtual function。completion model 增加
`bit owner`，codec 改为：

```systemverilog
function rdma_status inspect_completion(
  rdma_hw_image image,
  bit expected_owner,
  output bit ready,
  output rdma_xtr_v1_cmq_completion completion
);
  // 完成 metadata/qword0 可读性检查后先取 bit63。
  owner = qword0[63];
  if (owner != expected_owner) begin
    ready = 1'b0;
    return rdma_status::success();
  end
  ready = 1'b1;
  // 随后执行 supported opcode、allowed mask 和 payload slice 校验。
endfunction
```

qword0 allowed mask 改为 `64'h8000_3fff_ff00_0000`。删除 codec 层的 expected
opcode/wrap 参数，二者由 engine 与 slot ledger 比较；同步迁移 completion 和 context
regression tests。

xtr profile 内部持有 `rdma_xtr_v1_cmq_request_composer`、
`rdma_xtr_v1_cmq_completion_codec`、`rdma_xtr_v1_error_codec` 和已注册 defaults 的
`rdma_xtr_v1_doorbell_codec_registry`。`validate_profile()` 验证这些对象均非 null且 doorbell
defaults 已成功注册，`prepare()` 必须在 allocation 前调用它。`compose_sqe()` 先 `build_body()` 再
`compose_request()`，最后只在 detached result 上填写 backing target metadata；不得修改
command、body 或 slot。`inspect_cqe()` 用 error codec 生成 `command_status`，但 Function、
generation、CMQ resource ID 和 command ID 由 engine 在关联 ticket 后补齐。

include 顺序固定为：

```systemverilog
`include "rdma_cmq_hw_profile.svh"
// existing xtr_v1 qword/doorbell/qpc/context/cmq/error codecs
`include "xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh"
```

- [ ] **Step 4: 在 53 上确认 profile 与既有 codec 回归通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_profile_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_completion_test
scripts/run_vcs53.sh core rdma_xtr_v1_context_cmq_regression_test
scripts/run_vcs53.sh core rdma_xtr_v1_doorbell_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_error_codec_test
```

Expected GREEN: owner=1 初始 ready、owner mismatch 空队列和 bit63 reserved-mask 行为都通过；
原 codec golden 无变化。

- [ ] **Step 5: 提交 profile 层**

```bash
git add src/codec/rdma_cmq_hw_profile.svh \
  src/codec/xtr_v1/rdma_xtr_v1_cmq_hw_profile.svh \
  src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh \
  src/codec/rdma_codec_pkg.sv \
  tests/unit/rdma_xtr_v1_cmq_completion_test.svh \
  tests/unit/rdma_xtr_v1_context_cmq_regression_test.svh \
  tests/unit/rdma_xtr_v1_cmq_profile_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: add injectable xtr_v1 CMQ hardware profile"
```

### Task 4: 实现 `prepare()` / `activate()` 与 Backing 生命周期

**Files:**
- Create: `src/core/rdma_cmq_engine.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_cmq_engine_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: 写两阶段激活和 allocation rollback 的失败测试**

在 engine test 定义只编码测试 opcode 的 `rdma_cmq_test_profile`，但 `prepare()` 测试不
绕过真实 `rdma_mock_host_mem`。构造 PREPARED binding、depth 32 的 CMQ resource，检查：

```systemverilog
engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567,
               mem, scheduler, profile, runtime_desc, status);
expect_status("PREPARE", status, RDMA_SC_OK);
if (runtime_desc.sq_iova.value != mem.regions[0].mapping.iova.value ||
    runtime_desc.cq_iova.value !=
      mem.regions[0].mapping.iova.value + 64'd2048)
  `uvm_error("CMQ_LAYOUT", "runtime IOVA layout is incorrect")
```

验证单次 allocation 的 size/alignment/direction 为
`4096/4096/RDMA_DMA_BIDIRECTIONAL`，request context 的 Function、nonzero BDF、PASID 和
CMQ owner 正确，完整 4096B 被清零。再覆盖
null adapter/profile、非 PREPARED/ACTIVE binding、depth != 32、无效 CMQ handle、PASID
invalid/nonzero、allocate failure、zero-write failure、runtime descriptor clone failure 的
rollback，mapping 只 release 一次且 engine 回到 UNCONFIGURED。额外注入 rollback release
failure：engine 必须保留 mapping authority并进入 POISONED，最小 `shutdown()` 可重试释放，
不能为了满足 UNCONFIGURED 断言而遗失 leak。

`activate()` 测试拒绝非 ACTIVE、UID/object/generation/BDF 不匹配和被篡改的 mapping
PASID；同 identity ACTIVE binding 成功后 state 为 ACTIVE。

- [ ] **Step 2: 在 53 上确认 engine 未定义**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected RED: VCS 报告 `rdma_cmq_engine` 未定义。

- [ ] **Step 3: 实现 prepare/activate 的最小 engine**

core package 增加 `import rdma_codec_pkg::*;`，在 scheduler 之后 include engine。engine 固定
常量和核心 authority 如下：

```systemverilog
localparam int unsigned CMQ_DEPTH = 32;
localparam int unsigned CMQE_BYTES = 64;
localparam int unsigned SQ_BYTES = 2048;
localparam int unsigned CQ_OFFSET = 2048;
localparam int unsigned BACKING_BYTES = 4096;

protected semaphore engine_lock;
protected rdma_cmq_engine_state_e engine_state;
protected rdma_function_binding prepared_binding;
protected rdma_dma_request_context dma_context;
protected rdma_cmq cmq_snapshot;
protected rdma_dma_mapping backing_mapping;
protected rdma_host_mem_api host_mem;
protected rdma_doorbell_scheduler scheduler;
protected rdma_cmq_hw_profile profile;
protected longint unsigned publish_seq;
protected longint unsigned retire_seq;
protected longint unsigned cq_consume_seq;
```

`prepare()` 在 lock 内先 clone/validate 所有输入，再构造 context：

```systemverilog
request_context.function_h = binding_snapshot.make_handle();
request_context.requester_bdf = binding_snapshot.pcie.bdf;
request_context.pasid_valid = pasid_valid;
request_context.pasid = pasid_valid ? pasid : '0;
request_context.owner_h = rdma_clone_handle_value(
  cmq_snapshot.handle, "CMQ DMA owner");
status = host_mem_arg.allocate(request_context, BACKING_BYTES,
                               BACKING_BYTES, RDMA_DMA_BIDIRECTIONAL,
                               candidate_mapping);
```

随后一次 `write(candidate_mapping, 0, zeros)` 清零 4096B。任何后续失败都调用一次
`release(candidate_mapping)`；release 成功才回到 UNCONFIGURED，release 失败则把 candidate
保存在 backing authority、进入 POISONED并允许 `shutdown()` 重试。只有 runtime descriptor
完整构造成功后才把 candidate 提交给正常 engine 字段并进入 PREPARED；内部 CMQ snapshot
的 `queue_iova/completion_iova` 同时设置为 SQ/CQ IOVA。runtime 固定
`initial_sq_valid=1`、`initial_cq_owner=1`、`initial_doorbell_polarity=0`。

`activate()` 对 ACTIVE binding clone 执行 `validate()`，比较 Function UID/object/generation
和 BDF；再比较 `backing_mapping` 的 Function/BDF/PASID/owner 与内部 context。全部通过后
原子替换 binding snapshot并进入 ACTIVE。查询函数只 clone 返回：

```systemverilog
function rdma_cmq_engine_state_e state();
function rdma_dma_mapping mapping_snapshot();
function longint unsigned published_count();
function longint unsigned retired_count();
function longint unsigned cq_consumed_count();
```

本任务的最小 `shutdown()` 只负责释放 prepare 已取得的 mapping并回到 UNCONFIGURED；Task 10
在同一 cleanup helper 上增加 outstanding cancel/FIFO 语义。

- [ ] **Step 4: 在 53 上确认两阶段生命周期通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
```

Expected GREEN: prepare/activate 和 rollback cases 通过；core 不需要具体 host_mem/PCIe/VIP
package即可编译。

- [ ] **Step 5: 提交 engine 生命周期骨架**

```bash
git add src/core/rdma_cmq_engine.svh src/core/rdma_core_pkg.sv \
  tests/unit/rdma_cmq_engine_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: prepare and activate CMQ runtime backing"
```

### Task 5: 实现 Batch Staging、压紧与单 Doorbell 发布

**Files:**
- Modify: `src/core/rdma_cmq_engine.svh`
- Modify: `tests/unit/rdma_cmq_engine_test.svh`

- [ ] **Step 1: 写混合 batch、局部 codec failure 和单 doorbell 失败测试**

mock profile 对 opcode `0x10/0x20` 编码不同 body，对 `0xee` 返回
`RDMA_SC_UNSUPPORTED_OPCODE`。提交输入 `{0x10, 0xee, 0x20}`，要求 tickets/status 与输入
等长，中间 ticket 为 null，成功项落到 SQ index 0/1 而非 0/2；shared trace 必须是：

```systemverilog
'{"host_write", "host_write", "pcie_dma_barrier",
  "pcie_mmio_barrier", "pcie_mmio_write"}
```

最后一次 MMIO payload 是 `final_pi=2, polarity=0`。提交空数组或全失败 batch 不调用
scheduler；`submit()` 必须只是单元素 wrapper，并只在成功发布后返回 ticket。另测调用方
在 task 运行期间修改 command/body 不影响已取得 snapshot。

- [ ] **Step 2: 在 53 上确认 submit API 失败**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected RED: VCS 报告 `submit_batch`/`submit` 未定义，或测试观察不到压紧和单 doorbell。

- [ ] **Step 3: 实现 tentative batch transaction**

engine 内部增加 slot record 和 token ledger：

```systemverilog
typedef enum bit [2:0] {
  CMQ_SLOT_FREE,
  CMQ_SLOT_PUBLISHED,
  CMQ_SLOT_COMPLETED,
  CMQ_SLOT_TIMED_OUT_QUARANTINED,
  CMQ_SLOT_LATE_COMPLETED,
  CMQ_SLOT_RESET_CANCELLED
} rdma_cmq_slot_state_e;

class rdma_cmq_slot_record extends uvm_object;
  longint unsigned slot_sequence;
  int unsigned sq_index;
  bit sq_wrap;
  rdma_cmq_slot_state_e state;
  rdma_cmq_ticket ticket;
  rdma_cmq_expected_response expected;
  bit [4:0] command_token;
endclass

protected rdma_cmq_slot_record slots[CMQ_DEPTH];
protected bit token_in_use[CMQ_DEPTH];
protected bit [58:0] token_incarnation[CMQ_DEPTH];
```

每项按以下固定次序处理：clone command → `command.validate()` → profile name check → deadline
overflow check → capacity check → reserve token/incarnation → 构造 slot context →
`profile.compose_sqe()` → 校验 immutable image metadata。SQE 必须满足：

```systemverilog
sqe.length == 64;
sqe.alignment == 64;
sqe.image_kind == RDMA_IMAGE_CMQ_SQE;
sqe.function_generation == prepared_binding.generation;
sqe.write_target_kind == RDMA_HW_TARGET_BACKING;
sqe.backing_target.value ==
  backing_mapping.backing_addr.value + (sq_index * CMQE_BYTES);
```

只给成功项构造 `rdma_doorbell_dependency`，stage 为
`RDMA_DB_DEP_QUEUE_CONTEXT`、relative offset 为 `sq_index*64`、ready=1、dependency ID 为
tentative slot sequence + 1。最终 doorbell image 来自 profile，descriptor 使用 ACTIVE
binding/CMQ handle、`RDMA_DB_BARRIER_DMA_MMIO`、non-combining、no readback，timeout 取所有
成功项剩余 deadline 的最小值。

scheduler 成功后才把 tentative slots、tickets、token 和 `publish_seq += success_count`
提交到 authority ledger。scheduler 失败时 tickets 保持 null，释放 token 但不回退已经
递增的 incarnation，原 validation/codec failure 保持原 status，其他 tentative 成功项获得
同一 transport status。仅有逐项 validation/codec/queue-full 失败时 `batch_status` 仍为 OK；
没有成功项时 `batch_status` 也为 OK且不发送 doorbell；只有 staging invariant 或 scheduler
事务失败才令 `batch_status` 非 OK。

- [ ] **Step 4: 在 53 上确认 batch 压紧和单 doorbell 通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
```

Expected GREEN: `{success, failure, success}` 只写两个连续 SQE、只发一次 doorbell，输出数组
严格对齐输入。

- [ ] **Step 5: 提交 batch 发布路径**

```bash
git add src/core/rdma_cmq_engine.svh tests/unit/rdma_cmq_engine_test.svh
git commit -m "feat: publish compacted CMQ batches with one doorbell"
```

### Task 6: 实现 32-entry 全容量、Wrap/Polarity 与事务回滚

**Files:**
- Modify: `src/core/rdma_cmq_engine.svh`
- Modify: `tests/unit/rdma_cmq_engine_test.svh`

- [ ] **Step 1: 写 32/33 容量边界和每个 transport failure 测试**

一次或多次 batch 填满 32 个 slot，验证 index `0..31` 都成功且第 33 项为
`RDMA_SC_QUEUE_FULL`，没有 host write/MMIO side effect。通过 test hook 将 slot 0 标成可退休
后，第 33 个有效发布必须满足：

```systemverilog
ticket.slot_sequence == 64'd32;
ticket.sq_index == 0;
ticket.sq_wrap == 1'b1;
encoded_sqe.valid == 1'b0;
encoded_sqe.wrap == 1'b1;
doorbell.pi == 1;
doorbell.polarity == 1'b1;
```

分别注入第 N 个 dependency write、DMA barrier、MMIO barrier 和 MMIO write failure，要求
`publish_seq`、outstanding、slot ledger 不变，所有 tentative ticket null，下一次成功提交
覆盖同一未发布 slot。增加把 `publish_seq` 设为 `64'hffff_ffff_ffff_fff0`、再 tentative
发布 32 项的 counter test hook，验证加法溢出 poison 而非
回绕。

- [ ] **Step 2: 在 53 上确认容量/rollback 测试失败**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected RED: 旧实现在第 32/33 边界、wrap/polarity 或失败回滚至少一项不满足。

- [ ] **Step 3: 实现单调 counter 和全事务预检**

ring 使用量只由以下 helper 计算：

```systemverilog
protected function rdma_status ring_used(output longint unsigned used);
  if (publish_seq < retire_seq)
    return poison_status("CMQ publish counter precedes retire counter");
  used = publish_seq - retire_seq;
  if (used > CMQ_DEPTH)
    return poison_status("CMQ ring occupancy exceeds depth");
  return rdma_status::success();
endfunction
```

每次 `publish_seq + success_count` 先检查
`publish_seq > 64'hffff_ffff_ffff_ffff - success_count`。容量不足只失败当前及后续需要 slot 的
item，不覆盖早先 validation/codec status。profile 接收的 slot wrap 为 `(sequence/32)&1`；
最终 doorbell PI 为 `(publish_seq+count)%32`，polarity 为
`((publish_seq+count)/32)&1`。

不要添加 production “mark complete” API。容量测试通过写真实 CQ backing 并调用下一任务
即将实现的 `poll()`；在本任务的 RED/GREEN 过渡中只允许 test subclass 调用 protected
`retire_completed_prefix()`，提交前必须删除或限制为 test-only subclass access。

- [ ] **Step 4: 在 53 上确认容量和失败原子性通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected GREEN: 32 全容量、第 33 queue full、wrap 翻转和四类 transport rollback 均通过，
无 ID/ticket/slot 泄漏。

- [ ] **Step 5: 提交完整 publish ring**

```bash
git add src/core/rdma_cmq_engine.svh tests/unit/rdma_cmq_engine_test.svh
git commit -m "feat: support full-capacity CMQ ring publication"
```

### Task 7: 从真实 CQ Backing 轮询并关联乱序 Completion

**Files:**
- Modify: `src/core/rdma_cmq_engine.svh`
- Modify: `tests/unit/rdma_cmq_engine_test.svh`

- [ ] **Step 1: 写 owner、CQ wrap、乱序完成和 per-command ecode 测试**

测试不能直接调用 engine 内部 complete helper。用 mock host memory 写
`CQ_OFFSET + (cq_sequence % 32)*64`，profile 产生 CQE，然后调用 `poll()`。提交 ticket
`0,1,2`，按 CQ 物理位置连续写入关联 WQE `2,0,1`，要求 completion 输出到达顺序为
`2,0,1`；完成 2 时 `retire_seq==0`，完成 0 时为 1，完成 1 后为 3。

测试初始 owner=1，owner mismatch 正常返回空且不推进 `cq_consume_seq`；消费 32 个 CQE 后
expected owner 翻为 0。一个 CQE 使用非零 ecode，只有对应 completion 失败并保留 raw code，
其他 batch item 成功；raw 64B image、decoded payload、opcode/index/wrap 必须与写入一致。

- [ ] **Step 2: 在 53 上确认 CQ polling 未实现**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected RED: `poll()` 尚未从 CQ backing 读取/关联，或乱序完成错误地越过 retirement 前缀。

- [ ] **Step 3: 实现连续 CQ consume 和双 key registry**

engine 保持 command registry 和 hardware-entry registry 两套 key：

```systemverilog
protected rdma_cmq_slot_record command_registry[string];
protected rdma_cmq_slot_record entry_registry[string];

protected function string command_key(rdma_cmq_ticket ticket);
  return $sformatf("%016h:%08h:%08h:%016h",
    ticket.function_h.function_uid, ticket.function_h.object_id,
    ticket.function_h.generation, ticket.command_id);
endfunction

protected function string entry_key(int unsigned index, bit wrap);
  return $sformatf("%016h:%08h:%0d:%0b",
    prepared_binding.function_uid, prepared_binding.generation,
    index, wrap);
endfunction
```

每轮 `poll()` 读取恰好 64B，构造 detached `RDMA_IMAGE_CMQ_CQE` raw image，expected owner 为
`!((cq_consume_seq/32)&1)`。profile 返回 `ready==0` 时正常停止；ready 后必须验证 decoded/
status 非空、index<32、entry key 存在、slot state 可接受、expected hardware opcode 和 wrap
完全匹配。成功或硬件错误都：生成 completion、补齐 status identity、从 command registry
删除、回收 token、标记 COMPLETED、`cq_consume_seq++`、调用：

```systemverilog
while (retire_seq < publish_seq) begin
  index = retire_seq % CMQ_DEPTH;
  if (!(slots[index].state inside {CMQ_SLOT_COMPLETED,
                                    CMQ_SLOT_LATE_COMPLETED,
                                    CMQ_SLOT_RESET_CANCELLED})) break;
  entry_registry.delete(entry_key(index, slots[index].sq_wrap));
  clear_slot(index);
  retire_seq++;
end
```

completion 先进入内部 terminal FIFO，再由 `poll()` 一次取走当前全部结果；poll operation
status 在合法硬件 ecode 时仍为 OK，命令结果在 `completion.status`。

- [ ] **Step 4: 在 53 上确认真实 CQ backing 路径通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_profile_test
```

Expected GREEN: CQE 只通过 `host_mem.read()` 进入 engine，乱序关联和连续 retirement 同时
满足，32-entry CQ owner 翻转正确。

- [ ] **Step 5: 提交 CQ polling 路径**

```bash
git add src/core/rdma_cmq_engine.svh tests/unit/rdma_cmq_engine_test.svh
git commit -m "feat: poll and correlate CMQ completions from host memory"
```

### Task 8: 实现 Timeout、Command ID Incarnation 与 Late Diagnostic

**Files:**
- Modify: `src/core/rdma_cmq_engine.svh`
- Modify: `tests/unit/rdma_cmq_engine_test.svh`

- [ ] **Step 1: 写 per-command timeout、quarantine 和 ID 不复用测试**

同一 batch 设置不同 timeout，只推进仿真时间使 ticket 0 到期，调用 `expire()`，要求只返回
ticket 0 的 `RDMA_SC_TIMEOUT` completion；ticket 1 仍 outstanding。timeout 后 token 可回收，
但新 ticket 的完整 command ID 必须不同：

```systemverilog
if (new_ticket.command_id[4:0] == old_ticket.command_id[4:0] &&
    new_ticket.command_id == old_ticket.command_id)
  `uvm_error("CMQ_ID_ALIAS", "recycled token reused a public command ID")
```

timeout slot 保持 `TIMED_OUT_QUARANTINED` 并阻止 `retire_seq` 越过；向真实 CQ backing 写入
匹配迟到 CQE 后，`poll()` 不返回正常 completion，只返回一个
`RDMA_CMQ_DIAG_LATE_COMPLETION`，其 ticket/raw image 完整，slot 转为 LATE_COMPLETED 并允许
前缀 retirement。还要覆盖 59-bit incarnation 已达全 1 时该 token 永久
`RDMA_SC_RESOURCE_EXHAUSTED`，不得回绕成 command ID 0。

- [ ] **Step 2: 在 53 上确认 timeout 状态机失败**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected RED: `expire()` 未定义，或 timeout 错误释放 slot/重复 command ID/把 late CQE 当正常
completion。

- [ ] **Step 3: 实现协作式 expiry 和 tombstone**

command ID allocation 固定为：

```systemverilog
protected function rdma_status allocate_command_id(
  output bit [4:0] token,
  output longint unsigned command_id
);
  for (int unsigned i = 0; i < CMQ_DEPTH; i++) begin
    if (token_in_use[i]) continue;
    if (token_incarnation[i] == 59'h7ff_ffff_ffff_ffff) continue;
    token_incarnation[i]++;
    token_in_use[i] = 1'b1;
    token = i[4:0];
    command_id = {token_incarnation[i], token};
    return rdma_status::success();
  end
  return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                           "CMQ command ID pool is exhausted");
endfunction
```

`expire_locked()` 扫描 PUBLISHED slots，使用 `ticket.absolute_deadline <= $time`；对每项只生成
一次 timeout completion、删除 command key、回收 token、保留 entry key/ticket/expected 并
改为 TIMED_OUT_QUARANTINED。`poll()` 和 `wait_for()` 调用同一 helper，不能复制三套 timeout
逻辑。

迟到 CQE 命中 quarantined slot 时，先验证 opcode/wrap，再生成 diagnostic；不调用正常
completion enqueue，不再次回收 token。diagnostic status 使用
`RDMA_SC_TIMEOUT`、`source_engine=RDMA_ENGINE_CMQ`，并填 Function/generation/resource/
command identity。随后消费 CQE、标记 LATE_COMPLETED、推进 retirement。

- [ ] **Step 4: 在 53 上确认 timeout/late/ID 测试通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected GREEN: timeout 只影响到期 command，late CQE 只有 diagnostic，token 重用不产生
64-bit ID alias，incarnation exhaustion fail closed。

- [ ] **Step 5: 提交 timeout 与 ID 生命周期**

```bash
git add src/core/rdma_cmq_engine.svh tests/unit/rdma_cmq_engine_test.svh
git commit -m "feat: quarantine timed out CMQ commands safely"
```

### Task 9: 实现 Malformed/Unknown CQE Poison 隔离

**Files:**
- Modify: `src/core/rdma_cmq_engine.svh`
- Modify: `tests/unit/rdma_cmq_engine_test.svh`

- [ ] **Step 1: 写所有 poison 入口的失败测试**

逐个使用新的 engine instance 覆盖：owner ready 后 reserved bit 非零、unsupported opcode、
known slot 的 opcode mismatch、WQE index/wrap 无 active/tombstone、profile 返回 null decoded、
profile 返回 null command status、counter/slot ledger 不一致。每个 case 要求：

- `poll()` 返回非 OK；engine state 为 `RDMA_CMQ_ENGINE_POISONED`；
- diagnostic 保留原始 64B image和 identity-rich status；无法可信关联时 ticket 必须 null；
- `cq_consume_seq` 不推进，错误 slot 不改变，后续 `submit/poll/expire/wait_for` 均拒绝；
- `last_poison_snapshot()` 为 detached copy，调用方修改不影响 engine。

- [ ] **Step 2: 在 53 上确认 poison fail-closed 尚未满足**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected RED: malformed CQE 被跳过、错误关联到 ticket，或 engine 继续处理后续 CQE。

- [ ] **Step 3: 实现单一 poison transition**

所有 invariant failure 只通过以下 helper 进入 poison：

```systemverilog
protected function rdma_status poison(
  rdma_cmq_diagnostic_kind_e kind,
  string message,
  rdma_hw_image raw_cqe,
  rdma_cmq_ticket trusted_ticket = null
);
  rdma_status failure;
  rdma_cmq_diagnostic diagnostic;
  failure = rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  failure.source_engine = RDMA_ENGINE_CMQ;
  failure.function_uid = prepared_binding.function_uid;
  failure.generation = prepared_binding.generation;
  failure.resource_id = cmq_snapshot.handle.object_id;
  if (trusted_ticket != null)
    failure.command_id = trusted_ticket.command_id;
  diagnostic = make_diagnostic(kind, trusted_ticket, failure, raw_cqe);
  last_poison = clone_diagnostic(diagnostic);
  diagnostic_fifo.push_back(diagnostic);
  engine_state = RDMA_CMQ_ENGINE_POISONED;
  return failure;
endfunction
```

profile codec failure用 `RDMA_CMQ_DIAG_MALFORMED_CQE`；合法解码但找不到 entry 用
`RDMA_CMQ_DIAG_UNKNOWN_CQE`；engine 自身 counter/ledger invariant 用
`RDMA_CMQ_DIAG_POISON`。只有在 entry key 和 slot incarnation 已可信命中后才可附 ticket。
poison 路径不能消费 CQE、清 slot、回收 token或生成正常 completion。

- [ ] **Step 4: 在 53 上确认 poison 隔离通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_completion_test
```

Expected GREEN: 每个 malformed/unknown case 停在首个错误并保留 raw evidence；正常 owner
mismatch 仍只是 queue empty，不 poison。

- [ ] **Step 5: 提交 poison 隔离**

```bash
git add src/core/rdma_cmq_engine.svh tests/unit/rdma_cmq_engine_test.svh
git commit -m "feat: poison CMQ engine on untrusted completions"
```

### Task 10: 实现 Completion FIFO、`wait_for()`、Cancel、Reset 与 Shutdown

**Files:**
- Modify: `src/core/rdma_cmq_engine.svh`
- Modify: `tests/unit/rdma_cmq_engine_test.svh`

- [ ] **Step 1: 写交付 FIFO 和完整 lifecycle 的失败测试**

测试以下可观察语义：

1. ticket B 先完成，`wait_for(ticket A)` 不吞 B；A 完成后返回 A，下一次 `poll()` 仍返回 B。
2. 任一 completion 最多交付一次；unknown/already-delivered ticket 的 wait 返回
   `RDMA_SC_INVALID_ARGUMENT`。
3. `cancel_generation(current)` 对每个仍 PUBLISHED command 产生
   `RDMA_SC_RESET_CANCELLED`，清 timeout tombstone、token、slot/registry并进入 QUIESCED；已
   timeout且已交付的 command 不再产生 reset completion。
4. `cancel_generation(other)` 返回 `RDMA_SC_STALE_GENERATION` 且零副作用。
5. `reset()` 输出 FIFO 中尚未交付的 terminal results 加本次 cancel results，随后恰好
   release 一次 mapping并回到 UNCONFIGURED；旧 mapping read/write 被 adapter 拒绝。
6. poison 后 `reset()` 能恢复；重新以新 generation prepare/activate 后，旧 generation CQE/
   mapping 不影响新 engine。
7. `shutdown()` 在 PREPARED/ACTIVE/QUIESCED 下清理 mapping；第二次调用幂等成功。注入
   release failure 时返回失败并保留 mapping，下一次 retry 成功，不报告假 clean。

- [ ] **Step 2: 在 53 上确认 lifecycle API 未完成**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected RED: `wait_for/cancel_generation/reset/shutdown` 至少一项未定义或丢失 queued
completion/mapping authority。

- [ ] **Step 3: 实现单一 terminal FIFO 和清理路径**

engine 只保存一个正常 terminal FIFO 和一个 diagnostic FIFO：

```systemverilog
protected rdma_cmq_completion terminal_fifo[$];
protected rdma_cmq_diagnostic diagnostic_fifo[$];
```

`poll()` 先处理 CQ/expiry，再 drain 全部当前 FIFO；`expire()` 只处理 expiry 再 drain；
`wait_for()` 循环执行 `poll_locked()` + `expire_locked()`，只从 FIFO 删除 command ID 匹配
目标 ticket 的元素，其余保持原顺序。目标未完成时等待
`min(1ns, ticket.absolute_deadline-$time)`；deadline 到达后同一 expiry helper 必须产生
timeout completion，不能 busy-loop。

cancel status 固定补齐 identity：

```systemverilog
cancel_status = rdma_status::make(RDMA_SC_RESET_CANCELLED,
                                  "CMQ command cancelled by generation reset");
cancel_status.source_engine = RDMA_ENGINE_RESET;
cancel_status.function_uid = ticket.function_h.function_uid;
cancel_status.generation = ticket.function_h.generation;
cancel_status.resource_id = ticket.cmq_h.object_id;
cancel_status.command_id = ticket.command_id;
```

`cancel_generation()` 只取消 PUBLISHED commands；quarantine 直接清 tombstone且不再生成
completion。quarantine 的 token 已在 timeout 时回收，清 tombstone 时严禁再次把同 token
标成 free，因为它可能已属于新 incarnation；只有仍 PUBLISHED slot 才回收当前 token。
保留此前 terminal FIFO，再把新 cancel completion 追加。清完 registry/slot 后
令三个 counter 回零并进入 QUIESCED。

`reset()` 在同一 lock 内执行：收集未交付 FIFO → cancel current generation → append cancel
results → 尝试 release mapping。只有 release 成功才清 authority、profile/adapter 引用、
counter、FIFO、diagnostic/poison并进入 UNCONFIGURED。release 失败保留足够 authority供重试，
state 保持 POISONED（或原 QUIESCED），返回 adapter failure。`shutdown()` 复用相同 release
helper，但不返回 completion；若存在未交付 command，先 cancel并明确丢弃 shutdown-only
结果，不能泄漏 slot/token。

最后实现 detached 查询：

```systemverilog
function int unsigned outstanding_count();
function int unsigned quarantine_count();
function rdma_cmq_diagnostic last_poison_snapshot();
```

- [ ] **Step 4: 在 53 上确认 lifecycle 和重新初始化通过**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
scripts/run_vcs53.sh core rdma_adapter_contract_test
scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected GREEN: completion 恰好交付一次，cancel/reset/shutdown 无 token、slot、registry 或
mapping leak；release failure 可安全 retry。

- [ ] **Step 5: 提交完整 lifecycle**

```bash
git add src/core/rdma_cmq_engine.svh tests/unit/rdma_cmq_engine_test.svh
git commit -m "feat: complete CMQ generation and reset lifecycle"
```

### Task 11: 运行 53 全回归并做最终质量审计

**Files:**
- Modify only if a regression exposes a Task 13 defect; do not fold unrelated Task 31 harness work into this task.

- [ ] **Step 1: 先添加或确认 regression guard 的失败证据**

在最终测试中确认以下 assertions 已存在；缺少任何一项先补测试并运行 focused case 得到
RED：32 全容量、batch 单 doorbell、CQ owner 翻转、`2→0→1` completion、timeout late-only
diagnostic、malformed poison、release-failure retry、非零 VF BDF/PASID authority。不要用
`scripts/run_vcs53.sh core regression`，该脚本目前会把 `regression` 当 UVM class，属于
Task 31。

- [ ] **Step 2: 在 53 上记录新增 guard 的预期失败**

Run:

```bash
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

Expected RED only when Step 1 found and added a missing guard: failure must identify the uncovered Task 13
invariant。若所有 guard 已在 Tasks 1–10 建立，记录“无需新增 RED；已有各任务 RED 证据”，
不要人为破坏 production code。

- [ ] **Step 3: 只修复 Task 13 范围内的 regression defect**

允许修改的 production 范围仅为本计划 file map。修复继续遵循：profile 中放 xtr_v1 位域，
engine 中放通用 state/ring，adapter 中放 allocation authority。禁止通过放宽 reserved bits、
跳过 BDF/PASID、直接注入 completion、保留 31-entry 空槽或重复 doorbell 来让测试通过。

- [ ] **Step 4: 在 53 上逐项运行全部正常注册测试**

先跑 Python 和 frozen driver checker：

```bash
python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
scripts/run_vcs53.sh xtr_defs regression
scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

再逐个运行 core tests（每个命令都必须看到 `UVM_ERROR : 0`、`UVM_FATAL : 0`）：

```bash
scripts/run_vcs53.sh core rdma_smoke_test
scripts/run_vcs53.sh core rdma_types_test
scripts/run_vcs53.sh core rdma_model_test
scripts/run_vcs53.sh core rdma_cmq_engine_models_test
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_adapter_contract_test
scripts/run_vcs53.sh core rdma_resource_manager_test
scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
scripts/run_vcs53.sh core rdma_codec_registry_test
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
scripts/run_vcs53.sh core rdma_xtr_v1_qword_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_doorbell_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_context_body_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_error_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_completion_test
scripts/run_vcs53.sh core rdma_xtr_v1_context_cmq_regression_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_profile_test
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

最后执行本地静态检查：

```bash
git diff --check
rg -n "XTR_V1_|rdma_xtr_v1" src/core/rdma_cmq_engine.svh
rg -n "pcie_env|axis_env|axis_vip|host_mem_pkg" src/core src/model src/codec/rdma_cmq_hw_profile.svh
git status --short
```

Expected: `git diff --check` 无输出；engine 的 xtr_v1 搜索无输出；core/model/abstract profile
没有具体 env/VIP 依赖；仅预期的未提交修复显示在 status 中。

- [ ] **Step 5: 提交最终 regression 修复或记录 clean evidence**

若 Step 3 有修复：

```bash
git add src/model src/adapter src/adapters/host_mem src/codec src/core \
  tests
git commit -m "test: close CMQ engine regression gaps"
```

若无修复，不创建空提交。记录 base/head SHA、所有 53 命令结果，并确认最终
`git status --short` 无输出。

## 完成定义

实施完成时必须同时满足：

1. `rdma_cmq_engine` 不 import 或构造具体 PCIe/AXIS/host_mem/VIP environment。
2. requester BDF/PASID/owner 从 PREPARED binding/context 一直保存在真实 mapping authority。
3. `prepare()` 成功不代表可 submit；只有同 identity ACTIVE binding `activate()` 后才可用。
4. batch 成功项压紧、所有 SQE 先写、DMA barrier、MMIO barrier、一次最终 doorbell。
5. 32 个 entry 全可 outstanding，第 33 个无 retired slot 时才 queue full。
6. CQE 只从真实 backing read，支持返回 WQE `2→0→1` 而 retirement 仍按 `0→1→2`。
7. timeout、late CQE、hardware ecode、malformed CQE、cancel、reset 均恰好交付规定的结果，
   不泄漏 command ID、slot、registry 或 mapping。
8. xtr_v1 owner/valid、wrap、doorbell polarity 与 pinned driver一致，且 xtr 位域只在 profile/
   codec 层。
9. 所有正常注册 core tests、host_mem integration、Python checker、xtr frozen checker 和
   `git diff --check` 通过。
