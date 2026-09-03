# RDMA Send Queue Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 QP lifecycle、queue-data engine、真实 host-memory adapter、XTR v1 codec、doorbell scheduler 和 recovery ledger 之上，交付可验证的 RC/UD Send Queue 投递路径。

**Architecture:** `rdma_sq_engine` 是窄 facade，只委托一个已经配置的 `rdma_queue_data_engine`；PI/CI、credit、SGB slot、doorbell 和 outstanding tracking 各只有一个事实源。SQ engine 先深拷贝并验证 request/QP，必要时经可验证的 payload writer 写真实 host-memory，再按固定 header-last 顺序写 SGB/SQE、readback、发 DMA→MMIO barrier 和 SQ doorbell，最后一次性提交 runtime ledger、PSN 和 result。

**Tech Stack:** SystemVerilog/UVM transaction-level models, existing `rdma_host_mem_api`, `rdma_queue_runtime`, `rdma_resource_manager`, `rdma_doorbell_scheduler`, XTR v1 logical-qword codec, Python definition checker, Synopsys VCS on `ubuntu@10.11.10.53`.

**Spec:** `docs/superpowers/specs/2026-09-02-rdma-sq-engine-design.md`

## Global Constraints

- 只支持 pinned `xtrdma_post_send()` 实际接受的 RC/UD opcode；URC 返回 `RDMA_SC_UNSUPPORTED_OPCODE`，不推测 URC ABI。
- 不实现 device-side packetization、ACK/retry 状态机、AH/MR/MW lifecycle、batch post、blue-flame/FWQE、CQ moderation 或外部 `host_mem` 修改。
- WQE 固定 64 bytes，SGB slot 固定 512 bytes 且 512-byte aligned；inline 上限 512 bytes，SGB 最多 32 个 SGE descriptor。
- 非 inline request 携带 `payload` 时必须使用 `rdma_sq_payload_writer` 写入并逐字节 readback 已注册真实 mapping；不能忽略 payload 或信任裸 IOVA。
- `(Function generation, QP identity, WR ID)` 是唯一外部 outstanding key；每个 record 保存 detached cursor、PSN、mode、SGE 数、WQE/SGB image 和 writer receipt。
- RC WQE-level PSN 从 `rdma_qpc_rc_ext.send_psn` 初始化，只在完整 commit 后 modulo-24 加 1；SQE 的 8-bit `QP_SN` 只来自 `programmed_qpc.qp_sequence`。
- 固定顺序为 producer credit reservation → payload writer → build/track → SGB write/readback → SQE body → header-last → full readback/signature → DMA/MMIO barrier → SQ doorbell → runtime/PSN commit；reservation 本身不推进 PI/used，queue full 时不触碰 payload。
- 新增或修改的普通源码、class、package、test 使用 `.sv`；只有已有宏/bit-mask 文件保留 `.svh`。
- 不提交 host_mem 外部源码、build/cache、VCS 日志、SSH wrapper、凭据或环境文件。
- VCS 验证必须在 `10.11.10.53` 的 `ubuntu` login shell 中运行，密码只通过现有脚本流程提供，不写入仓库或 remote URL。

## File and Responsibility Map

- `src/model/rdma_semantic_requests.sv`: QP capability、SGB backing spec、send `fence` 和 detached UD address-vector value snapshot。
- `src/model/rdma_context_layouts.sv`: UD AV 的 `\priority[2:0]`、`multicast`、`forwarding_mode[1:0]` value fields、copy/validation。
- `src/model/rdma_queue_lifecycle_models.sv`: `RDMA_QUEUE_ROLE_QP_SQ_SGB`、SGB geometry、borrowed/owned segment validation 和 QP plan authority。
- `src/model/rdma_resources.sv`: QP detached capability/PSN/SGB authority fields与exactly-once cleanup metadata。
- `src/model/rdma_queue_models.sv`: payload mode、writer receipt、outstanding record 和 detached snapshots。
- `src/core/rdma_qp_lifecycle_executor.sv`: QP create rollback、SGB allocation/zeroing、destroy/reset cleanup。
- `src/core/rdma_resource_manager.sv`: SGB role projection、outstanding record tracking and retire fences。
- `src/core/rdma_sq_payload_writer.sv`: abstract writer and real `rdma_host_mem_api` implementation。
- `src/core/rdma_queue_runtime.sv`: per-slot SGB credit, reservation lease, recovery publication and CQ release hooks。
- `src/core/rdma_queue_data_engine.sv`: one SQ build/commit implementation, codec/readback/doorbell integration and SQ record authority。
- `src/core/rdma_sq_engine.sv`: public configure/attach/post/recover/query facade。
- `src/core/rdma_core_pkg.sv`: include order for writer, queue-data engine and facade。
- `src/codec/xtr_v1/rdma_xtr_v1_defs.svh`: only new pinned field/mask constants and transport opcode values。
- `src/codec/xtr_v1/rdma_xtr_v1_queue_codecs.sv`: complete RC/UD/atomic SQE encode/decode and signature validation。
- `docs/hw/xtr-v1-source-map.md`, `tools/check_xtr_v1_defs.py`: pinned C symbol ↔ SV coordinate/value/source mapping and checker coverage。
- `hw/xtr_v1/golden_vectors/sq.hex`: frozen 64-byte SQE and 512-byte SGB vectors。
- `tests/unit/rdma_sq_models_test.sv`, `tests/unit/rdma_sq_payload_writer_test.sv`, `tests/unit/rdma_xtr_v1_sq_codec_test.sv`, `tests/unit/rdma_sq_engine_test.sv`: focused unit suites。
- `tests/integration/rdma_sq_engine_host_mem_test.sv`: real host-memory allocation/write/readback/leak test。
- `tests/rdma_unit_test_pkg.sv`, `sim/filelists/core.f`, `sim/filelists/host_mem.f`: registration and compile order。

## Cross-task Interface Contract

The following names and signatures are fixed before implementation. Later tasks must use these exact types and return a non-null `rdma_status` on every public path.

```systemverilog
typedef enum bit [2:0] {
  RDMA_SQ_PAYLOAD_NONE,
  RDMA_SQ_PAYLOAD_INLINE_WQE,
  RDMA_SQ_PAYLOAD_INLINE_SGB,
  RDMA_SQ_PAYLOAD_SGE_WQE,
  RDMA_SQ_PAYLOAD_SGE_SGB,
  RDMA_SQ_PAYLOAD_ATOMIC_FIXED
} rdma_sq_payload_mode_e;

typedef enum bit [2:0] {
  RDMA_SQ_RECORD_PREPARED,
  RDMA_SQ_RECORD_RECOVERY_REQUIRED,
  RDMA_SQ_RECORD_POSTED,
  RDMA_SQ_RECORD_BOOKKEEPING_RECOVERY,
  RDMA_SQ_RECORD_RETIRED
} rdma_sq_record_state_e;

virtual class rdma_sq_payload_writer extends uvm_object;
  pure virtual function rdma_status stage_and_verify(
    rdma_dma_request_context request_context,
    rdma_sge sges[$],
    byte unsigned payload[$],
    output rdma_sq_payload_write_receipt receipt
  );
  pure virtual function rdma_status release_receipt(
    rdma_sq_payload_write_receipt receipt
  );
endclass

class rdma_sq_payload_write_receipt extends uvm_object;
  rdma_function_handle function_h;
  bit [31:0] function_generation;
  longint unsigned registration_ids[$];
  rdma_sge sges[$];
  byte unsigned payload[$];
  bit verified;
endclass

class rdma_sq_outstanding_record extends uvm_object;
  longint unsigned tracking_id;
  bit [31:0] function_generation;
  rdma_handle qp_h;
  bit [20:0] local_qpn;
  longint unsigned wr_id;
  int unsigned wqe_index;
  bit wqe_wrap;
  bit psn_valid;
  bit [23:0] psn;
  rdma_sq_payload_mode_e payload_mode;
  longint unsigned total_payload_len;
  int unsigned sge_count;
  rdma_hw_image wqe_image;
  bit sgb_valid;
  rdma_iova_t sgb_iova;
  byte unsigned sgb_image[$];
  rdma_sq_payload_write_receipt payload_receipt;
  bit signaled;
  rdma_sq_record_state_e state;
endclass

// Extensions to the existing result/pending models (fields are added to the
// already-defined classes; no second result or pending type is introduced).
// rdma_queue_post_result gains payload_mode, total_payload_len, sge_count,
// psn_valid, psn, sgb_valid, sgb_iova and sgb_image[$].
// rdma_queue_pending_operation gains rdma_sq_outstanding_record sq_record.
```

`rdma_sq_engine` delegates to these queue-data methods without creating another cursor or ledger:

```systemverilog
class rdma_sq_engine extends uvm_object;
  function rdma_status configure(
    rdma_queue_data_engine queue_engine,
    rdma_sq_payload_writer payload_writer = null
  );
  function rdma_status attach_qp(rdma_handle qp_h);
  function rdma_status detach_qp(rdma_handle qp_h);
  task post_send(rdma_post_send_req request,
                 output rdma_queue_post_result result,
                 output rdma_status status);
  function rdma_status recover_qp(rdma_handle qp_h,
    rdma_queue_recovery_action_e action,
    bit caller_confirmed_no_submit = 1'b0);
  function rdma_status query_outstanding(rdma_handle qp_h,
    longint unsigned wr_id,
    output rdma_sq_outstanding_record record);
endclass
```

The queue-data ownership and writer hand-off methods are likewise fixed:

```systemverilog
function rdma_status rdma_queue_data_engine::claim_sq_service_owner(
  uvm_object owner_token,
  rdma_sq_payload_writer payload_writer
);
function rdma_status rdma_queue_data_engine::recover_qp_sq(
  rdma_handle qp_h,
  rdma_queue_recovery_action_e action,
  bit caller_confirmed_no_submit = 1'b0
);
function rdma_status rdma_queue_data_engine::query_sq_outstanding(
  rdma_handle qp_h,
  longint unsigned wr_id,
  output rdma_sq_outstanding_record record
);
```

### Task 1: Extend semantic, QP capability and detached model contracts

**Files:**
- Modify: `src/model/rdma_context_layouts.sv`
- Modify: `src/model/rdma_semantic_requests.sv`
- Modify: `src/model/rdma_queue_lifecycle_models.sv`
- Modify: `src/model/rdma_resources.sv`
- Modify: `src/model/rdma_queue_models.sv`
- Create: `tests/unit/rdma_sq_models_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Produce `rdma_create_qp_req.max_inline_data`, `rdma_create_qp_req.sq_sgb_backing`, `rdma_qp.max_send_sge/max_recv_sge/max_inline_data`, and `rdma_qp_backing_plan.sq_sgb_ref`.
- Produce `RDMA_QUEUE_ROLE_QP_SQ_SGB`, `rdma_qp_sgb_layout(depth)`, and validation that a needed SGB is `depth*512` logical bytes, 4 KiB storage rounded up, every slot 512-byte aligned, and device-readable.
- Produce `rdma_post_send_req.fence` and detached `rdma_post_send_req.address_vector` value snapshot; retain `address_vector_id` only as correlation.

- [ ] **Step 1: Write the failing model tests**

```systemverilog
class rdma_sq_models_test extends uvm_test;
  `uvm_component_utils(rdma_sq_models_test)
  task run_phase(uvm_phase phase);
    longint unsigned logical_bytes, storage_bytes;
    rdma_status s; rdma_address_vector av, av_copy; uvm_object cloned;
    phase.raise_objection(this);
    if (!rdma_qp_needs_sq_sgb(RDMA_TRANSPORT_UD, 1, 1))
      `uvm_error("SQ_CAP", "UD did not require SQ SGB")
    s = rdma_qp_sq_sgb_geometry(16, logical_bytes, storage_bytes);
    if (s == null || !s.ok() || logical_bytes != 8192 || storage_bytes != 8192)
      `uvm_error("SQ_GEOMETRY", "16-slot SQ SGB geometry is incorrect")
    av = rdma_address_vector::type_id::create("av");
    av.\priority  = 3; av.multicast = 1; av.forwarding_mode = 2;
    cloned = av.clone();
    if (cloned == null || !$cast(av_copy, cloned) || av_copy == av ||
        av_copy.\priority  != 3 || !av_copy.multicast ||
        av_copy.forwarding_mode != 2)
      `uvm_error("SQ_AV", "AV clone lost detached UD WQE fields")
    phase.drop_objection(this);
  endtask
endclass
```

- [ ] **Step 2: Run the new test to verify it fails**

Run: `scripts/run_vcs53.sh core rdma_sq_models_test`

Expected: FAIL because the new capability fields, SGB role, and AV fields are not defined.

- [ ] **Step 3: Implement the minimal model contract**

```systemverilog
// rdma_create_qp_req
int unsigned max_inline_data;
rdma_queue_backing_spec sq_sgb_backing;

// rdma_address_vector
bit [2:0] \priority;
bit multicast;
bit [1:0] forwarding_mode;

// rdma_qp_backing_plan
rdma_qp_backing_ref sq_sgb_ref;

function automatic bit rdma_qp_needs_sq_sgb(
  rdma_transport_e transport, int unsigned max_send_sge,
  int unsigned max_recv_sge
);
function automatic rdma_status rdma_qp_sq_sgb_geometry(
  int unsigned depth, output longint unsigned logical_bytes,
  output longint unsigned storage_bytes
);
```

Update constructors, `do_copy()`, `validate()`, `validate_queue_caps()`, QP plan clone/validation, and `rdma_qp` detached fields together. Reject inline >32 when no SGB is required, >512 always, `max_send_sge >32`, nonzero SGB backing when SGB is not required, and a noncanonical empty backing when it is required.

- [ ] **Step 4: Run focused and existing model tests**

Run: `scripts/run_vcs53.sh core rdma_sq_models_test` and `scripts/run_vcs53.sh core rdma_request_model_test`

Expected: both tests PASS with `UVM_WARNING=0`, `UVM_ERROR=0`, and `UVM_FATAL=0`; cloned requests and plans retain equal values but distinct object handles.

- [ ] **Step 5: Commit**

```bash
git add src/model/rdma_context_layouts.sv src/model/rdma_semantic_requests.sv src/model/rdma_queue_lifecycle_models.sv src/model/rdma_resources.sv src/model/rdma_queue_models.sv tests/unit/rdma_sq_models_test.sv tests/rdma_unit_test_pkg.sv
git commit -m "feat: model SQ capabilities and SGB authority"
```

### Task 2: Allocate, zero, retain and clean up QP SQ SGB backing

**Files:**
- Modify: `src/core/rdma_qp_lifecycle_executor.sv`
- Modify: `src/core/rdma_resource_manager.sv`
- Modify: `src/model/rdma_queue_lifecycle_models.sv`
- Modify: `src/model/rdma_resources.sv`
- Modify: `tests/unit/rdma_qp_lifecycle_test.sv`
- Modify: `tests/unit/rdma_qp_recovery_test.sv`
- Modify: `tests/unit/rdma_queue_data_engine_post_test.sv`

**Interfaces:**
- Consume `rdma_qp_backing_plan.sq_sgb_ref` from Task 1.
- Add protected executor helper `make_sq_sgb_ref(rdma_function_binding binding, rdma_handle qp_h, int unsigned depth, rdma_queue_backing_spec spec, output rdma_qp_backing_ref ref)`.
- Add `rdma_resource_manager` role projection and release-progress handling for `RDMA_QUEUE_ROLE_QP_SQ_SGB`; borrowed refs are never released by the executor.

- [ ] **Step 1: Write failing lifecycle tests**

```systemverilog
// In rdma_qp_lifecycle_test.sv after a successful UD QP create:
if (qp.qp_plan == null || qp.qp_plan.sq_sgb_ref == null)
  `uvm_error("SQ_SGB", "UD QP did not retain SQ SGB authority")
if (qp.qp_plan.sq_sgb_ref.length != qp.sq_depth * 512)
  `uvm_error("SQ_SGB_SIZE", "SQ SGB logical length is not depth*512")
if ((qp.qp_plan.sq_sgb_ref.mapping.iova.value & 64'h1ff) != 0)
  `uvm_error("SQ_SGB_ALIGN", "SQ SGB IOVA is not 512-byte aligned")
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/run_vcs53.sh core rdma_qp_lifecycle_test`

Expected: FAIL at missing `sq_sgb_ref` or zero SGB geometry. Existing queue-data fixtures with `max_send_sge=4` are also updated in this task to set `max_inline_data=512` and provide the canonical owned SQ-SGB spec.

- [ ] **Step 3: Implement allocation and rollback**

```systemverilog
status = make_sq_sgb_ref(binding, qp_snapshot.handle, request.sq_depth,
                         request.sq_sgb_backing, plan.sq_sgb_ref);
if (!status.ok()) begin
  // invoke the existing rollback_unattached_qp(candidate, plan, staging,
  // primary_status, result) task; it releases owned refs in reverse order
  // and only detaches a borrowed sq_sgb_ref.
  rollback_unattached_qp(candidate, plan, null, status, result);
  return;
end
status = zero_sq_sgb_ref(request_context, plan.sq_sgb_ref,
                         longint'(request.sq_depth) * 512);
```

Add the protected helper `function rdma_status zero_sq_sgb_ref(rdma_dma_request_context context, rdma_qp_backing_ref ref, longint unsigned length);` and make each slot `mapping_offset + index*512`, reject a segment boundary inside a slot, preserve the mapping and exact image on write/readback failure, append the role to create recovery, and release owned SGB only after QP ERROR/flush/QPC delete. Extend all manager schema/equality/projection paths so a retained SGB cannot be dropped by recovery copies.

- [ ] **Step 4: Run lifecycle, rollback, and recovery tests**

Run: `scripts/run_vcs53.sh core rdma_qp_lifecycle_test`, `scripts/run_vcs53.sh core rdma_qp_recovery_test`

Expected: owned create failure releases SGB exactly once, borrowed create never calls `host_mem.release()`, normal destroy releases after flush, and ambiguous/reset recovery retains the SGB authority.

- [ ] **Step 5: Commit**

```bash
git add src/core/rdma_qp_lifecycle_executor.sv src/core/rdma_resource_manager.sv src/model/rdma_queue_lifecycle_models.sv src/model/rdma_resources.sv tests/unit/rdma_qp_lifecycle_test.sv tests/unit/rdma_qp_recovery_test.sv tests/unit/rdma_queue_data_engine_post_test.sv
git commit -m "feat: add QP SQ SGB lifecycle ownership"
```

### Task 3: Implement the verified staged-payload writer

**Files:**
- Create: `src/core/rdma_sq_payload_writer.sv`
- Modify: `src/core/rdma_core_pkg.sv`
- Modify: `tests/mocks/rdma_mock_adapters.sv`
- Create: `tests/unit/rdma_sq_payload_writer_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- `rdma_host_mem_sq_payload_writer.configure(rdma_host_mem_api api, rdma_function_binding binding, time timeout)`.
- `register_mapping(rdma_dma_mapping mapping, output longint unsigned registration_id)` and `unregister_mapping(longint unsigned registration_id)`.
- A successful `stage_and_verify()` increments receipt-held registration references; `release_receipt(receipt)` decrements them exactly once on no-side-effect abort or record retirement, allowing `unregister_mapping()` only when all counts are zero.
- Implement the exact `rdma_sq_payload_writer.stage_and_verify(rdma_dma_request_context request_context, rdma_sge sges[$], byte unsigned payload[$], output rdma_sq_payload_write_receipt receipt)` and `release_receipt(rdma_sq_payload_write_receipt receipt)` contracts from the cross-task interface section.

- [ ] **Step 1: Write failing writer tests**

```systemverilog
writer.register_mapping(active_mapping, registration_id);
request_context = make_dma_context(fixture.binding);
sges.delete(); sge = rdma_sge::type_id::create("sge");
sge.iova.value = active_mapping.iova.value + 32; sge.length = 4;
sges.push_back(sge); payload = '{8'h11, 8'h22, 8'h33, 8'h44};
s = writer.stage_and_verify(request_context, sges, payload, receipt);
if (s == null || !s.ok() || receipt == null || !receipt.verified)
  `uvm_error("WRITER_OK", "verified staged payload was rejected")
if (receipt.payload[2] !== 8'h33) `uvm_error("WRITER_SNAPSHOT", "receipt is not detached")
```

The test-local context helper copies the binding identity into a detached request context:

```systemverilog
function automatic rdma_dma_request_context make_dma_context(
  rdma_function_binding binding
);
  rdma_dma_request_context c;
  c = rdma_dma_request_context::type_id::create("writer_context");
  c.function_h = binding.make_handle();
  c.requester_bdf = binding.queue_dma.requester_bdf;
  c.pasid_valid = binding.queue_dma.pasid_valid;
  c.pasid = binding.queue_dma.pasid;
  c.dma_domain_valid = binding.queue_dma.dma_domain_valid;
  c.dma_domain_id = binding.queue_dma.dma_domain_id;
  return c;
endfunction
```

Add cases for missing registration, wrong Function generation/BDF/PASID/domain, inactive mapping, missing device-read permission, overlapping registrations, range overflow, payload length mismatch, write failure and readback mismatch.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/run_vcs53.sh core rdma_sq_payload_writer_test`

Expected: FAIL because the abstract writer and registration APIs do not exist.

- [ ] **Step 3: Implement preflight, scatter, write and readback**

```systemverilog
receipt = null;
status = request_context.validate();
if (!status.ok()) return status;
status = validate_registered_ranges(request_context, sges, payload.size());
if (!status.ok()) return status;
foreach (sges[i]) begin
  status = host_mem.write(registration.mapping,
                          sges[i].iova.value - registration.mapping.iova.value,
                          chunk);
  if (!status.ok()) return status;
  status = host_mem.read(registration.mapping,
                         sges[i].iova.value - registration.mapping.iova.value,
                         sges[i].length, readback);
  if (!status.ok() || !bytes_equal(chunk, readback))
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                             "staged payload readback mismatch");
end
receipt = make_detached_receipt(request_context, sges, payload, ids);
receipt.verified = 1'b1;
return rdma_status::success();
```

Complete all checks before the first write; scatter payload in SGE order; use checked 64-bit sums; record registration IDs and byte snapshots; reject unregister while a receipt is referenced by a live record; never call `release()` because registration ownership remains with the caller.

- [ ] **Step 4: Run focused writer tests**

Run: `scripts/run_vcs53.sh core rdma_sq_payload_writer_test`

Expected: all success/failure cases PASS and failed preflight produces no mock `write` call; write/readback failures return non-OK with null receipt.

- [ ] **Step 5: Commit**

```bash
git add src/core/rdma_sq_payload_writer.sv src/core/rdma_core_pkg.sv tests/mocks/rdma_mock_adapters.sv tests/unit/rdma_sq_payload_writer_test.sv tests/rdma_unit_test_pkg.sv
git commit -m "feat: verify staged SQ payloads through host memory"
```

### Task 4: Freeze SQE coordinates, reserved masks and golden-vector tooling

**Files:**
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_defs.svh`
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh`
- Modify: `docs/hw/xtr-v1-source-map.md`
- Modify: `tools/check_xtr_v1_defs.py`
- Modify: `tests/unit/test_check_xtr_v1_defs.py`
- Create: `hw/xtr_v1/golden_vectors/sq.hex`

**Interfaces:**
- Add checker-validated `XTR_V1_SQ_WQE_*` coordinates for common header, RC body, UD body, atomic body and SGB pointer.
- Add named logical-qword ownership/reserved masks and `XTR_V1_SQ_OPCODE_*` mappings for all supported RC/UD opcodes.
- Add checker reference APIs `parse_sq_field_mappings(text)`, `sq_reference_image(case_name)`, `sq_reference_sgb(case_name)`, and `validate_sq_golden_vectors()`; values are generated from pinned source coordinates, never raw unreviewed literals.

- [ ] **Step 1: Write failing checker tests**

```python
def test_sq_fields_and_golden_vectors_are_required(self):
    fields = CHECKER.parse_sq_field_mappings(CHECKER.SV_DEFS_PATH.read_text())
    self.assertIn("XTR_V1_SQ_WQE_QPN", fields)
    self.assertIn("XTR_V1_SQ_WQE_SIGNATURE", fields)
    self.assertIn("XTR_V1_SQ_WQE_UD_DST_IP", fields)
    self.assertTrue((CHECKER.GOLDEN_DIR / "sq.hex").exists())
    CHECKER.validate_sq_golden_vectors()
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m unittest tests/unit/test_check_xtr_v1_defs.py -v`

Expected: FAIL because SQ field parsing, masks and `sq.hex` are not yet present.

- [ ] **Step 3: Add pinned definitions and vectors**

```systemverilog
`XTR_V1_FIELD(XTR_V1_SQ_WQE_RC_TOTAL_LEN, 8, 0, 32)
`XTR_V1_FIELD(XTR_V1_SQ_WQE_RC_IMMEDIATE, 8, 32, 32)
`XTR_V1_FIELD(XTR_V1_SQ_WQE_SGB_PA, 32, 9, 55)
`XTR_V1_FIELD(XTR_V1_SQ_WQE_UD_DMAC, 16, 0, 48)
localparam bit [63:0] XTR_V1_SQ_WQE_HEADER_MASK = 64'hefff_ffff_ffff_ffff;
```

Use the pinned `wr.h`, `qp.c`, `xtrdma_hw.h`, `defs.h` coordinates and existing qword-big-endian convention; add source-map rows and checker failures for missing, extra, duplicate, width-drifted, alias-drifted or raw-literal mappings. Freeze at least RC inline 1/32/33/512, direct 1/2 SGE, SGE SGB 3/32, SEND_WITH_IMM, WRITE_WITH_IMM, READ, LOCAL_INVALIDATE, CAS, FAA, UD inline/non-inline, and signature bytes.

- [ ] **Step 4: Run checker and Python unit tests**

Run: `python3 tools/check_xtr_v1_defs.py --kernel-root /tmp/rdma-source-audit.GZSVuv/dpu_kernel_rdma-version_0.1.32` and `python3 -m unittest tests/unit/test_check_xtr_v1_defs.py -v`

Expected: definition checker and all Python tests PASS; checker reports the exact pinned source commit and no missing/extra SQ mapping.

- [ ] **Step 5: Commit**

```bash
git add src/codec/xtr_v1/rdma_xtr_v1_defs.svh src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh docs/hw/xtr-v1-source-map.md tools/check_xtr_v1_defs.py tests/unit/test_check_xtr_v1_defs.py hw/xtr_v1/golden_vectors/sq.hex
git commit -m "feat: pin XTR v1 SQE layout and goldens"
```

### Task 5: Implement RC normal and signature codec

**Files:**
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_queue_codecs.sv`
- Modify: `tests/unit/rdma_xtr_v1_queue_codec_test.sv`
- Create: `tests/unit/rdma_xtr_v1_sq_codec_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Extend `rdma_xtr_v1_sqe_model` with body fields needed by the contract: `total_payload_len`, `inline_bytes`, `sgb_iova`, `invalidate_key`, `atomic_local_iova`, `atomic_value`, and `atomic_compare`.
- Add `rdma_sq_payload_mode_e payload_mode` to the XTR SQE model; the base semantic `inline_data` bit remains the request-shape input and is not serialized independently.
- Extend `rdma_sqe_ud_ext` with a cloned `rdma_address_vector address_vector`; destination QPN/QKey remain in that transport extension so the codec has one detached transport snapshot.
- `rdma_xtr_v1_sqe_rc_codec` must encode/decode SEND, SEND_WITH_IMM, RDMA_WRITE, WRITE_WITH_IMM, RDMA_READ, LOCAL_INVALIDATE, CAS and FAA; `encode()` returns a 64-byte `rdma_hw_image` with signature enabled.
- Add `function rdma_status validate_sq_signature(rdma_hw_image wqe, byte unsigned sgb[$], output bit valid)`.

- [ ] **Step 1: Write failing RC codec tests**

```systemverilog
sq = make_rc_inline_request(32);
s = encode_rc_sqe(sq, image);
if (s == null || !s.ok() || image.bytes.size() != 64)
  `uvm_error("RC_INLINE", "32-byte RC inline SQE did not encode")
if (!signature_is_ff(image.bytes, null))
  `uvm_error("RC_SIG", "RC signature XOR is not 8'hff")
sq = make_rc_atomic_request(RDMA_WR_ATOMIC_CMP_SWAP);
s = encode_rc_sqe(sq, image);
if (s == null || !s.ok() || image.bytes[32] !== 8'h00)
  `uvm_error("RC_ATOMIC", "atomic fixed body was not emitted")
```

Define the request builders in the same test class so every field is explicit:

```systemverilog
function automatic rdma_xtr_v1_sqe_model make_rc_inline_request(int unsigned n);
  rdma_xtr_v1_sqe_model x;
  x = rdma_xtr_v1_sqe_model::type_id::create("rc_inline");
  x.transport = RDMA_TRANSPORT_RC; x.qp_h = test_qp_handle();
  x.opcode = RDMA_WR_SEND; x.hw_opcode = 4'h0; x.qpn = 21'h12;
  x.valid = 1'b1; x.sign_en = 1'b1; x.payload_mode =
    n <= 32 ? RDMA_SQ_PAYLOAD_INLINE_WQE : RDMA_SQ_PAYLOAD_INLINE_SGB;
  x.inline_bytes = new[n]; foreach (x.inline_bytes[i]) x.inline_bytes[i] = i;
  x.total_payload_len = n; return x;
endfunction

function automatic rdma_handle test_qp_handle();
  rdma_handle h;
  h = rdma_handle::type_id::create("sq_test_qp");
  h.kind = RDMA_RESOURCE_QP; h.function_uid = 64'h1122_3344;
  h.object_id = 21'h12; h.generation = 7; return h;
endfunction

function automatic rdma_xtr_v1_sqe_model make_rc_atomic_request(
  rdma_work_opcode_e opcode
);
  rdma_xtr_v1_sqe_model x;
  x = rdma_xtr_v1_sqe_model::type_id::create("rc_atomic");
  x.transport = RDMA_TRANSPORT_RC; x.qp_h = test_qp_handle();
  x.opcode = opcode; x.hw_opcode = opcode == RDMA_WR_ATOMIC_CMP_SWAP ? 4'h8 : 4'h9;
  x.payload_mode = RDMA_SQ_PAYLOAD_ATOMIC_FIXED; x.atomic_local_iova.value = 64'h8000;
  x.atomic_value = 64'h1122; x.atomic_compare = 64'h3344; x.total_payload_len = 8;
  return x;
endfunction
```

The test helpers are concrete registry lookups, not mocks:

```systemverilog
function automatic rdma_status encode_rc_sqe(
  rdma_xtr_v1_sqe_model sq, output rdma_hw_image image
);
  rdma_codec_registry registry; rdma_codec_base codec; rdma_status status;
  registry = rdma_codec_registry::type_id::create("sq_codec_registry");
  status = rdma_xtr_v1_register_queue_codecs(registry);
  if (status == null || !status.ok()) return status;
  status = registry.lookup('{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_SQE,
    object_type:"sqe", variant:"rc", opcode:8'h00}, codec);
  if (status == null || !status.ok()) return status;
  return codec.encode(sq, image);
endfunction

function automatic bit signature_is_ff(
  rdma_hw_image image, byte unsigned sgb[$]
);
  bit valid; rdma_status status;
  status = validate_sq_signature(image, sgb, valid);
  return status != null && status.ok() && valid;
endfunction
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_sq_codec_test`

Expected: FAIL because the current codec only serializes a skeletal RC SQE and does not construct body/signature bytes.

- [ ] **Step 3: Implement logical-qword RC encoding**

```systemverilog
qword[0] = field_prep(XTR_V1_SQ_WQE_QPN, x.qpn) |
           field_prep(XTR_V1_SQ_WQE_QP_SN, x.qp_sn) |
           field_prep(XTR_V1_SQ_WQE_OPCODE, x.hw_opcode) |
           field_prep(XTR_V1_SQ_WQE_SIGN_EN, 1'b1) |
           field_prep(XTR_V1_SQ_WQE_VALID, x.valid);
qword[1] = {x.immediate_data, x.total_payload_len[31:0]};
qword[2] = {x.signature, x.sge_num, 16'h0, x.rkey};
qword[3] = x.remote_va.value;
write_rc_body(qword, x.payload_mode, x.inline_bytes, x.sges, x.sgb_iova);
qword[2][63:56] = ~xor_bytes_except_signature(qword, sgb);
```

Keep inline bytes raw, descriptors and numeric fields qword-big-endian, encode 2 GiB length as zero, zero all unused tail bytes, enforce direct-SGE ≤2 and SGB-SGE 3..32, encode atomic fixed qwords 4..7 with 8-byte alignment, and reject any reserved bit or unsupported shape before producing an image.

- [ ] **Step 4: Run RC codec, legacy queue codec and golden tests**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_sq_codec_test`, `scripts/run_vcs53.sh core rdma_xtr_v1_queue_codec_test`

Expected: PASS for every RC golden, decode/re-encode equality, qword endian, reserved-mask, 2 GiB-zero and signature check; all legacy queue codec tests remain PASS.

- [ ] **Step 5: Commit**

```bash
git add src/codec/xtr_v1/rdma_xtr_v1_queue_codecs.sv tests/unit/rdma_xtr_v1_queue_codec_test.sv tests/unit/rdma_xtr_v1_sq_codec_test.sv tests/rdma_unit_test_pkg.sv
git commit -m "feat: encode RC SQE bodies and signatures"
```

### Task 6: Implement UD and atomic transport codec paths

**Files:**
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_queue_codecs.sv`
- Modify: `src/model/rdma_queue_models.sv`
- Modify: `tests/unit/rdma_xtr_v1_sq_codec_test.sv`

**Interfaces:**
- Consume detached AV fields (`destination_mac`, `\priority`, `multicast`, `forwarding_mode`, VLAN, traffic class, flow label, source index, destination vport, hop limit, raw 16-byte destination IP) and UD request `destination_qpn/qkey`.
- Implement `rdma_xtr_v1_sqe_ud_codec` for SEND/SEND_WITH_IMM; nonzero UD payload always uses SGB and never overwrites AH metadata.
- Implement atomic fixed body in the RC codec for CAS/FAA; reject payload and any non-single-8-byte-SGE shape.
- Reuse the `encode_rc_sqe()` helper from Task 5 and add `encode_ud_sqe(rdma_xtr_v1_sqe_model, output rdma_hw_image)` plus `make_ud_request(int unsigned payload_length)` helpers with the same registry lookup pattern but `variant:"ud"`.

- [ ] **Step 1: Write failing UD/atomic tests**

```systemverilog
sq = make_ud_request(33);
sq.address_vector.traffic_class = 8'h5a;
sq.address_vector.destination_ip = '{default:8'h00};
sq.address_vector.destination_ip[0] = 8'h20;
s = encode_ud_sqe(sq, image);
if (s == null || !s.ok() || image.bytes[32] !== 8'h00)
  `uvm_error("UD_SGB", "UD payload overwrote AH/SGB metadata")
if (image.bytes[48] !== 8'h20) `uvm_error("UD_IP", "UD destination IP was byte-swapped")
sq.opcode = RDMA_WR_RDMA_WRITE;
s = encode_ud_sqe(sq, image);
if (s == null || s.code != RDMA_SC_UNSUPPORTED_OPCODE)
  `uvm_error("UD_OPCODE", "UD unsupported opcode was accepted")
```

Implement the builder and registry helper explicitly:

```systemverilog
function automatic rdma_xtr_v1_sqe_model make_ud_request(int unsigned n);
  rdma_xtr_v1_sqe_model x; rdma_sqe_ud_ext ext; rdma_address_vector av;
  x = rdma_xtr_v1_sqe_model::type_id::create("ud_request");
  x.transport = RDMA_TRANSPORT_UD; x.opcode = RDMA_WR_SEND;
  x.qp_h = test_qp_handle(); x.qpn = 21'h12; x.hw_opcode = 4'h0;
  ext = rdma_sqe_ud_ext::type_id::create("ud_ext");
  ext.destination_qpn = 24'h3456; ext.qkey = 32'h1111_2222;
  av = rdma_address_vector::type_id::create("ud_av");
  av.destination_mac = 48'h0102_0304_0506; av.\priority  = 3;
  av.destination_ip[0] = 8'h20; av.traffic_class = 8'h5a;
  ext.address_vector = av; ext.address_vector_valid = 1'b1;
  x.transport_ext = ext; x.payload_mode = RDMA_SQ_PAYLOAD_INLINE_SGB;
  x.inline_bytes = new[n]; foreach (x.inline_bytes[i]) x.inline_bytes[i] = i;
  x.total_payload_len = n; x.valid = 1'b1; x.sign_en = 1'b1; return x;
endfunction
```

`encode_ud_sqe()` uses the registry key `{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_SQE, object_type:"sqe", variant:"ud", opcode:8'h00}` and calls `codec.encode()`.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_sq_codec_test`

Expected: FAIL because current UD codec has no AH/SGB body and no raw destination-IP handling.

- [ ] **Step 3: Implement UD body and atomic validation**

```systemverilog
qword[1] = {x.immediate_data, vlan_bits, ipv6, tunnel, lag,
            x.total_payload_len[13:0]};
qword[2] = {x.signature, x.sge_num, av.destination_mac};
qword[3] = {av.\priority, av.cfi, av.vlan_id, pd_index,
            av.flow_label, av.source_address_index};
qword[4] = {(x.sgb_iova.value >> 9), av.multicast, av.traffic_class};
qword[5] = {av.hop_limit, x.destination_qpn, x.qkey};
foreach (av.destination_ip[i]) raw_ip_bytes[48+i] = av.destination_ip[i];
```

Use explicit width checks instead of truncation, derive PD index from attached QP authority, zero all unowned bits, enforce UD total length ≤16383, and include only the exact payload/descriptor bytes in the signature XOR. Atomic CAS writes swap then compare; FAA writes add then zero.

- [ ] **Step 4: Run transport codec and golden tests**

Run: `scripts/run_vcs53.sh core rdma_xtr_v1_sq_codec_test`

Expected: PASS for UD inline/non-inline, SEND_WITH_IMM, raw IP, AH metadata, atomic CAS/FAA, reserved bits, signature and unsupported-shape cases.

- [ ] **Step 5: Commit**

```bash
git add src/codec/xtr_v1/rdma_xtr_v1_queue_codecs.sv src/model/rdma_queue_models.sv tests/unit/rdma_xtr_v1_sq_codec_test.sv
git commit -m "feat: encode UD and atomic SQE shapes"
```

### Task 7: Integrate one SQ implementation with runtime, credit, outstanding and PSN

**Files:**
- Modify: `src/core/rdma_queue_runtime.sv`
- Modify: `src/core/rdma_queue_data_engine.sv`
- Modify: `src/core/rdma_resource_manager.sv`
- Modify: `src/model/rdma_queue_models.sv`
- Modify: `tests/unit/rdma_queue_data_engine_post_test.sv`
- Modify: `tests/unit/rdma_queue_data_engine_recovery_test.sv`
- Create: `tests/unit/rdma_sq_engine_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Add queue-data delegation methods `recover_qp_sq(rdma_handle qp_h, rdma_queue_recovery_action_e action, bit caller_confirmed_no_submit)` and `query_sq_outstanding(rdma_handle qp_h, longint unsigned wr_id, output rdma_sq_outstanding_record record)`; `post_send(rdma_post_send_req request, output rdma_queue_post_result result, output rdma_status status)` remains the sole SQ producer implementation.
- Add per-QP extension containing cloned programmed QPC, `programming_revision`, capability, optional SGB access, next PSN, posting semaphore and outstanding associative index. Empty detach retains this extension/watermark; a new Function/QP generation replaces it.
- Extend `rdma_queue_data_attachment` with one borrowed `sgb_access` configured from `qp.qp_plan.sq_sgb_ref`; it is an access capability only and is cleared on detach, never released.
- Extend `rdma_queue_slot_ledger_entry` with a reference to the same authoritative `rdma_sq_outstanding_record`; use the exact signature `commit_producer(rdma_queue_cursor_snapshot reservation, rdma_semantic_request request, longint unsigned wr_id, bit signaled, rdma_hw_image image, rdma_sq_outstanding_record sq_record = null)` and return that record from `match_and_release()`. The slot record is the SGB reuse credit, so no second SGB credit counter is introduced.
- Add monotonically allocated nonzero `next_sq_tracking_id` in the one queue-data engine and manager-tracked QP resource; IDs wrap only after proving the candidate is absent from all live records.

- [ ] **Step 1: Write failing engine tests**

```systemverilog
fixture.setup(status);
send = fixture.make_send(64'h101);
send.inline_data = 1'b1; send.sges.delete(); send.payload.delete();
repeat (33) send.payload.push_back(8'hab);
fixture.engine.post_send(send, result, status);
if (status == null || !status.ok() || result.payload_mode != RDMA_SQ_PAYLOAD_INLINE_SGB)
  `uvm_error("SQ_MODE", "33-byte inline request did not select INLINE_SGB")
record = null;
status = fixture.engine.query_sq_outstanding(fixture.qp.handle, send.wr_id, record);
if (status == null || !status.ok() || record.psn != 24'h123456)
  `uvm_error("SQ_PSN", "candidate PSN was not detached in record")
```

Add tests for full ring (no payload write), PI wrap/valid polarity, duplicate WR ID, SGB slot reuse only after CQ release, writer receipt retention, and same-QP concurrent posts returning `RDMA_SC_RESOURCE_BUSY` for the second lease.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/run_vcs53.sh core rdma_sq_engine_test`

Expected: FAIL because result/record mode, SGB ledger and PSN authority are not implemented.

- [ ] **Step 3: Implement fixed post order and atomic publication**

```systemverilog
snapshot = clone_and_validate_request(request);
status = validate_qp_generation_and_capability(snapshot, ext);
if (!status.ok()) return;
status = attachment.runtime.reserve_producer(cursor);
if (!status.ok()) return;
status = maybe_stage_payload(snapshot, ext, receipt);
if (!status.ok()) return;
candidate_psn = ext.next_psn;
status = build_detached_sqe_and_sgb(snapshot, cursor, candidate_psn, record);
if (!status.ok()) return;
status = manager.track_outstanding(snapshot.qp_h, record.tracking_id);
if (!status.ok()) return;
status = write_sgb_readback_then_body_header_last(record);
if (!status.ok()) return enter_sq_recovery(record, status, mmio_maybe_submitted);
status = submit_sq_doorbell_after_dma_mmio_barrier(record);
if (!status.ok()) return enter_sq_recovery(record, status, mmio_maybe_submitted);
status = attachment.runtime.commit_producer(cursor, snapshot, snapshot.wr_id,
                                             snapshot.signaled, record.wqe_image,
                                             record);
if (!status.ok()) return enter_sq_recovery(record, status, 1'b1);
record.state = RDMA_SQ_RECORD_POSTED;
if (record.psn_valid) ext.next_psn = (record.psn + 24'h1) & 24'hff_ffff;
publish_result_only_after_all_commits(record, result, status);
```

Build `rdma_dma_request_context` from the attached Function binding, select modes at 32/33, 2/3, 32/33, 512/513 boundaries, track before the first memory write, preserve exact images on every failure, release records/SGB credits from CQ release, and keep PSN unchanged for failures/retries/UD.
Add `rdma_qp.programming_revision` and increment it only after successful authoritative QPC create/modify publication. The SQ extension records the seen revision: a changed revision resets the RC watermark from the new `send_psn` only when manager tracking proves there is no live/pending SQ record; ordinary drain/detach/re-attach with the same revision preserves the advanced watermark.

- [ ] **Step 4: Run SQ engine and recovery tests**

Run: `scripts/run_vcs53.sh core rdma_sq_engine_test`, `scripts/run_vcs53.sh core rdma_queue_data_engine_post_test`, `scripts/run_vcs53.sh core rdma_queue_data_engine_recovery_test`

Expected: all tests PASS with no warnings/errors/fatals; known-no-MMIO retry reuses cursor/PSN/image/receipt, ambiguous MMIO forbids retry, and CQ release retires unsignaled predecessors exactly once.

- [ ] **Step 5: Commit**

```bash
git add src/core/rdma_queue_runtime.sv src/core/rdma_queue_data_engine.sv src/core/rdma_resource_manager.sv src/model/rdma_queue_models.sv tests/unit/rdma_queue_data_engine_post_test.sv tests/unit/rdma_queue_data_engine_recovery_test.sv tests/unit/rdma_sq_engine_test.sv tests/rdma_unit_test_pkg.sv
git commit -m "feat: integrate SQ runtime records and PSN commit"
```

### Task 8: Add the narrow facade and recovery ownership rules

**Files:**
- Create: `src/core/rdma_sq_engine.sv`
- Modify: `src/core/rdma_core_pkg.sv`
- Modify: `src/core/rdma_queue_data_engine.sv`
- Modify: `tests/unit/rdma_sq_engine_test.sv`

**Interfaces:**
- Implement the exact public `rdma_sq_engine` API in the cross-task interface section.
- `configure()` accepts exactly one configured queue-data engine and optional writer; it must reject a second owner or a queue engine without an active Function binding.
- `detach_qp()` delegates only after no posted/pending/bookkeeping records; ambiguous MMIO returns `RDMA_SC_RESOURCE_BUSY` and leaves manager tracking/SGB authority intact.

- [ ] **Step 1: Write failing facade tests**

```systemverilog
facade = rdma_sq_engine::type_id::create("facade");
s = facade.configure(fixture.engine, writer);
if (s == null || !s.ok()) `uvm_error("FACADE_CFG", "facade configure failed")
s = facade.configure(fixture.engine, writer);
if (s == null || s.code != RDMA_SC_INVALID_STATE)
  `uvm_error("FACADE_OWNER", "second queue-data owner was accepted")
s = facade.attach_qp(fixture.qp.handle);
if (s == null || !s.ok()) `uvm_error("FACADE_ATTACH", "QP attach failed")
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/run_vcs53.sh core rdma_sq_engine_test`

Expected: FAIL because `rdma_sq_engine` is not defined and queue-data delegation methods are absent.

- [ ] **Step 3: Implement delegation without a second authority**

```systemverilog
task post_send(rdma_post_send_req request,
               output rdma_queue_post_result result,
               output rdma_status status);
  result = null; status = null;
  if (!configured || queue_engine == null) begin
    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "SQ facade is not configured");
    return;
  end
  queue_engine.post_send(request, result, status);
endtask
```

`configure()` first calls `queue_engine.claim_sq_service_owner(this, payload_writer)` exactly once. Delegate attach/recover/query to the existing queue-data engine, validate QP kind/function/generation/ACTIVE/RTS before attachment, and leave all cursor, SGB, PSN and outstanding storage in the queue-data extension. Dropping a facade reference never invokes `host_mem.release()`; lifecycle teardown remains the only SGB release authority.

- [ ] **Step 4: Run facade and recovery tests**

Run: `scripts/run_vcs53.sh core rdma_sq_engine_test`

Expected: PASS for duplicate owner, duplicate attach, stale generation, non-RTS, URC unsupported, known-no-MMIO retry, ambiguous retry refusal, query snapshots and detach busy behavior.

- [ ] **Step 5: Commit**

```bash
git add src/core/rdma_sq_engine.sv src/core/rdma_core_pkg.sv src/core/rdma_queue_data_engine.sv tests/unit/rdma_sq_engine_test.sv
git commit -m "feat: expose SQ engine facade and recovery API"
```

### Task 9: Connect CQ release, package registration and real host-memory integration

**Files:**
- Create: `tests/integration/rdma_sq_engine_host_mem_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `sim/filelists/core.f`
- Modify: `sim/filelists/host_mem.f`
- Modify: `src/core/rdma_queue_data_engine.sv`
- Modify: `tests/unit/rdma_queue_data_engine_poll_test.sv`

**Interfaces:**
- Consume Task 7 `retire_sq_record()` and Task 8 facade API.
- Integration test must use the existing pinned `host_mem_manager` through `rdma_host_mem_adapter`, inspect actual SQE/SGB bytes, and check the adapter leak counter after QP/CQ/CEQ destroy.
- Extend the existing `rdma_queue_data_engine_fixture` with `function rdma_status read_qp_sgb(int unsigned index, output byte data[]);` which reads exactly 512 bytes through the SQ attachment's borrowed SGB access.

- [ ] **Step 1: Write the failing real-memory test**

```systemverilog
fixture.mem = real_host_mem_proxy;
fixture.setup(status);
request = make_staged_non_inline_request(3, 48);
fixture.engine.post_send(request, posted, status);
if (status == null || !status.ok()) `uvm_error("REAL_SQ_POST", "real SQ post failed")
fixture.read_qp_entry(1'b1, posted.index, actual_sqe);
fixture.read_qp_sgb(posted.index, actual_sgb);
if (!bytes_equal(actual_sqe, posted.image.bytes))
  `uvm_error("REAL_SQE", "actual host-memory SQE differs from image")
if (!bytes_equal(actual_sgb, posted.sgb_image))
  `uvm_error("REAL_SGB", "actual host-memory SGB differs from image")
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/run_vcs53.sh host_mem rdma_sq_engine_host_mem_test`

Expected: FAIL because the integration test and actual SQ SGB access are not registered.

- [ ] **Step 3: Register test and connect CQ retirement**

```systemverilog
`include "integration/rdma_sq_engine_host_mem_test.sv"
```

Add the test to the host-memory compilation unit, add core package include ordering for `rdma_sq_engine.sv`, make CQ polling retire every released SQ ledger entry and associated SGB slot/manager tracking, and preserve a bookkeeping-recovery record if local retire fails after the CQ doorbell.

- [ ] **Step 4: Run real-memory and poll tests**

Run: `scripts/run_vcs53.sh host_mem rdma_sq_engine_host_mem_test`, `scripts/run_vcs53.sh core rdma_queue_data_engine_poll_test`

Expected: PASS with actual payload scatter/readback, exact SQE/SGB bytes and doorbell trace; leak count is zero after lifecycle destroy and no CQ completion is consumed twice.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/rdma_sq_engine_host_mem_test.sv tests/rdma_unit_test_pkg.sv sim/filelists/core.f sim/filelists/host_mem.f src/core/rdma_queue_data_engine.sv tests/unit/rdma_queue_data_engine_poll_test.sv
git commit -m "test: verify SQ engine with real host memory"
```

### Task 10: Run the complete verification gate and audit repository contents

**Files:**
- Modify only files from Tasks 1–9 if a verified failure requires a targeted fix.
- Do not add build output, generated logs, external source, credentials, SSH wrappers or environment files.

**Interfaces:**
- Final gate consumes all prior test binaries, checker mappings, golden vectors and recovery fixtures.
- No API or file-extension change is allowed unless the corresponding unit test and this plan are updated in the same commit.

- [ ] **Step 1: Run Python and definition checks**

```bash
python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
python3 tools/check_xtr_v1_defs.py --kernel-root /tmp/rdma-source-audit.GZSVuv/dpu_kernel_rdma-version_0.1.32
```

Expected: all Python tests PASS and the checker exits zero.

- [ ] **Step 2: Run the required VCS suites on the simulation host**

```bash
scripts/run_vcs53.sh core rdma_sq_engine_test
scripts/run_vcs53.sh host_mem rdma_sq_engine_host_mem_test
scripts/run_vcs53.sh core regression
scripts/run_host_mem_regression53.sh
scripts/run_vcs53.sh xtr_defs regression
```

Expected: each command exits zero and reports `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0`; real-host-memory integration reports zero leaks.

- [ ] **Step 3: Audit extension names and generated artifacts**

```bash
rg --files src tests | rg '\.(svh)$' | sort
git status --short
git diff --check origin/main HEAD
```

Expected: only the existing macro/bit-mask `.svh` files remain (`rdma_xtr_v1_defs.svh`, `rdma_xtr_v1_image_masks.svh` and UVM macro include usage); `git status` contains only intentional source/tests/docs/golden/checker changes; `git diff --check` is clean.

- [ ] **Step 4: Re-run focused boundaries after any targeted fix**

Run the exact failing test first, then the full five-command gate from Step 2. Record the command and observed status in the commit message/body when a fix is required.

Expected: no unverified success claim; every final assertion is backed by a fresh command result.

- [ ] **Step 5: Finish with a clean verification state**

```bash
git status --short
```

Expected: empty output after all verified fixes were committed in the owning task; do not create an empty verification commit.

## Plan Self-Review

1. **Spec coverage:** Tasks 1–2 cover capability fields, SGB allocation/ownership/rollback/destroy/reset; Task 3 covers writer registration, identity/permission/range checks, scatter/write/readback and receipt lifetime; Tasks 4–6 cover all pinned XTR v1 SQE coordinates, RC/UD/atomic bodies, raw IP, endian, masks, signatures and goldens; Task 7 covers one PI/CI/credit/runtime authority, fixed commit order, outstanding key, PSN and CQ release; Task 8 covers facade and recovery semantics; Tasks 9–10 cover real host-memory evidence, VCS, Python checker, extension rules and clean repository state.
2. **Failure semantics:** Each write/readback/doorbell/commit failure enters a retained recovery record; known-no-MMIO retry reuses frozen evidence, ambiguous MMIO does not guess, and output objects remain null until complete success.
3. **Type consistency:** `rdma_sq_payload_mode_e`, `rdma_sq_record_state_e`, `rdma_sq_payload_write_receipt`, `rdma_sq_outstanding_record`, writer signatures and facade signatures are defined once in the contract and reused unchanged by Tasks 1–10.
4. **Naming audit:** No new ordinary `.svh` is planned; existing macro/mask `.svh` files are the only definition headers touched.
