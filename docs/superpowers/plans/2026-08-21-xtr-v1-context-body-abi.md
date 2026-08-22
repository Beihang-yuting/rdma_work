# XTR v1 Context/Body ABI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement driver-accurate xtr_v1 QPC images, sparse CQC/MRT/SRQC/CEQC/AEQC command bodies, checked CMQ composition, completion decoding, and hardware error interpretation.

**Architecture:** Hardware-neutral UVM models describe resources, topology, access, and address layouts; xtr_v1 codecs project them into logical 64-bit qwords and only then serialize every qword big-endian. QPC remains a standalone 512-byte image, while the other five object codecs emit sparse 64-byte bodies in final CMQ WQE coordinates; a later CMQ composer owns the common envelope and rejects any mask overlap before OR-composition.

**Tech Stack:** SystemVerilog/UVM 1.2, Python 3 reference checker and golden generator, GNU Make, Synopsys VCS on `10.11.10.53`.

---

## Fixed baseline and execution contract

- Work only in `/home/ryan/workspace/ryan/rdma_work/.worktrees/rdma-uvm-driver` on branch `feat/rdma-uvm-driver`.
- Driver authority is commit `491faf2ba42627fffd4dd027607299c8bb591ec2` from `/home/ubuntu/workspace/Desktop.zip` on `10.11.10.53`.
- Never derive a golden vector or expected mask from the SystemVerilog codec under test.
- Run Python unit tests locally. Run every SystemVerilog compile/simulation through `scripts/run_vcs53.sh`; no local simulator result is an acceptance result.
- Execute tasks strictly in order. For every task use a fresh implementer with `superpowers:test-driven-development`, a fresh spec reviewer, then a fresh quality reviewer. The original implementer fixes review findings; each reviewer rechecks its own findings. The controller runs a fresh 53/VCS staging verification before starting the next task.
- For a clean replay, execute Task 9.5 -> URC frozen-ABI prerequisite -> Task 10A -> Task 10A.1 -> Task 10A.2 -> URC queue-model prerequisite -> Task 10B -> Task 10C. Both URC prerequisites come from `docs/superpowers/plans/2026-08-22-urc-qpc-create-semantics.md`; Task 10A.2 follows `docs/superpowers/specs/2026-08-22-qpc-path-mtu-ownership-design.md` and moves PMTU into common QPC state before any codec consumes it.
- On the current branch Task 10B is already complete. Before resuming Task 10C, apply and review both URC prerequisites; do not replay or rewrite the accepted qword-builder commit.
- A task is not complete until the RED command failed for the intended reason, the GREEN commands passed, reviewers accepted it, the 53 staging directory was cleaned, and the task commit contains only that task.

## File responsibility map

| File | Responsibility |
|---|---|
| `src/model/rdma_context_layouts.svh` | Hardware-neutral object mode, state, ring, page-table, address-vector, `rdma_urc_queue_config`, RDMA-access, and MR-page-layout value objects. No `XTR_V1_*` names. |
| `src/model/rdma_context_models.svh` | QPC/CQC/MRT/SRQC/CEQC/AEQC semantic field models, validation, deep copy, and descriptions. |
| `src/codec/xtr_v1/rdma_xtr_v1_defs.svh` | Audited xtr_v1 sizes, opcodes, values, and field coordinates. |
| `src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh` | Immutable per-image/per-opcode qword ownership masks shared by body validation and CMQ composition. |
| `src/codec/xtr_v1/rdma_xtr_v1_qword_codec.svh` | Logical-qword occupancy, field preparation, big-endian serialization, deserialization, and mask checking. |
| `src/codec/xtr_v1/rdma_xtr_v1_qpc_codecs.svh` | Standalone QPC common codec plus separate RC, UD, and URC projections. |
| `src/codec/xtr_v1/rdma_xtr_v1_context_body_codecs.svh` | CQC, KEY_ALLOC/MR_REGISTER MRT, SRQC, CEQC, and AEQC sparse body codecs. |
| `src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh` | CMQ request envelope, light command bodies, opcode/body ownership registry, signature, and checked composition. |
| `src/codec/xtr_v1/rdma_xtr_v1_error_codec.svh` | CMQ completion decode and raw hardware ecode classification with lossless raw-code retention. |
| `tools/check_xtr_v1_defs.py` | Independent fixed-driver parser, definition checker, mask checker, and golden builder. |
| `tests/support/rdma_xtr_v1_golden_reader.svh` | Strict multi-case golden parser used by all xtr_v1 UVM tests. |

Stable Task 10 canonical registry keys are:

```text
xtr_v1|1|qpc|rc|00
xtr_v1|1|qpc|ud|00
xtr_v1|1|qpc|urc|00
xtr_v1|2|cqc|create|0c
xtr_v1|3|mrt|key_alloc|04
xtr_v1|3|mrt|register|05
xtr_v1|4|srqc|create|35
xtr_v1|5|ceqc|create|10
xtr_v1|6|aeqc|create|14
```

`opcode` is part of identity even for an image body. PBL0/PBL1/PBL2 are validated variants inside the two MRT codecs, not wildcard registry keys.

### Task 9.5: Freeze the extended context/body ABI

**Files:**
- Modify: `hw/xtr_v1/source_manifest.txt`
- Modify: `hw/xtr_v1/golden_vectors/context.hex`
- Modify: `docs/hw/xtr-v1-source-map.md`
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_defs.svh`
- Create: `src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh`
- Modify: `tools/check_xtr_v1_defs.py`
- Modify: `tests/unit/test_check_xtr_v1_defs.py`
- Create: `tests/support/rdma_xtr_v1_golden_reader.svh`
- Modify: `tests/unit/rdma_xtr_v1_defs_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `sim/Makefile`

- [ ] **Step 1: Write checker and parser tests that express the frozen contract**

Extend `tests/unit/test_check_xtr_v1_defs.py` with exact source pins, global uniqueness, fail-closed expression parsing, masks, and case names:

```python
EXPECTED_CONTEXT_CASES = [
    "qpc_rc_boundary", "qpc_ud_boundary", "qpc_urc_boundary",
    "cqc_create_body_boundary", "mrt_register_pbl0_boundary",
    "mrt_register_pbl1_boundary", "mrt_register_pbl2_boundary",
    "mrt_key_alloc_pbl0_boundary", "srqc_create_body_boundary",
    "ceqc_create_body_boundary", "aeqc_create_body_boundary",
]

def test_context_body_contract(self):
    cases = CHECKER.build_golden_cases()["context"]
    self.assertEqual([case.name for case in cases], EXPECTED_CONTEXT_CASES)
    self.assertEqual([len(case.payload) for case in cases[:3]], [512] * 3)
    self.assertEqual([len(case.payload) for case in cases[3:]], [64] * 8)
    self.assertTrue(all(case.inputs and case.summary for case in cases))

def test_sv_value_and_reference_identity_is_globally_unique(self):
    CHECKER.validate_global_uniqueness(
        CHECKER.VALUE_MAPPINGS, CHECKER.FIELD_MAPPINGS,
        CHECKER.REFERENCE_FIELDS,
    )

def test_bit_64_is_rejected_without_modifying_output(self):
    image = bytearray(b"\x5a" * 8)
    before = bytes(image)
    with self.assertRaisesRegex(CHECKER.ValidationError, r"BIT(?:_ULL)?\(64\)"):
        CHECKER.parse_c_expression("BIT_ULL(64)")
    self.assertEqual(bytes(image), before)

def test_body_masks_do_not_own_request_envelope(self):
    envelope = (0x8fff3fff00000000,) + (0,) * 7
    for name, body_mask in CHECKER.BODY_MASKS.items():
        self.assertEqual([a & b for a, b in zip(envelope, body_mask)], [0] * 8, name)
```

Replace the single-case check in `rdma_xtr_v1_defs_test.svh` with a strict reader call that proves all names and full payload lengths are visited:

```systemverilog
expected_names = '{
  "qpc_rc_boundary", "qpc_ud_boundary", "qpc_urc_boundary",
  "cqc_create_body_boundary", "mrt_register_pbl0_boundary",
  "mrt_register_pbl1_boundary", "mrt_register_pbl2_boundary",
  "mrt_key_alloc_pbl0_boundary", "srqc_create_body_boundary",
  "ceqc_create_body_boundary", "aeqc_create_body_boundary"
};
status = rdma_xtr_v1_golden_reader::read_all(
  "../hw/xtr_v1/golden_vectors/context.hex", cases
);
expect_status("GOLDEN_READ", status, RDMA_SC_OK);
if (cases.size() != expected_names.size())
  `uvm_error("GOLDEN_COUNT", $sformatf("got %0d", cases.size()))
foreach (cases[i]) begin
  if (cases[i].name != expected_names[i]) `uvm_error("GOLDEN_NAME", cases[i].name)
  if (cases[i].payload.size() != ((i < 3) ? 512 : 64))
    `uvm_error("GOLDEN_BYTES", cases[i].name)
end
```

- [ ] **Step 2: Run RED checks**

Run locally:

```bash
python3 -m unittest -v tests.unit.test_check_xtr_v1_defs
```

Expected: FAIL because the new manifest entries, masks, 11-case golden contract, and parser API do not exist.

Run on 53:

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
```

Expected: nonzero exit with the first target diagnostic referring to `rdma_xtr_v1_golden_reader` or the 11-case contract, not an SSH/license failure.

- [ ] **Step 3: Add immutable source provenance and driver-derived definitions**

Append these exact manifest rows and make the checker require their commit, selector, and SHA-256:

```text
491faf2ba42627fffd4dd027607299c8bb591ec2 alloc.h xtrdma_alloc_type 6723ae4bdfdc283e6c4821d2ce59f5ca300629665527cf316e4c49c6dad53922
491faf2ba42627fffd4dd027607299c8bb591ec2 mr.h MR/PBL/page/address-enums|xtrdma_reg_mr_info de683e3e941e31ba07162ea2b4712a5ed2224d26362fd567916c0abfbfef58c8
491faf2ba42627fffd4dd027607299c8bb591ec2 mr.c xtrdma_hwreg_mr ac507832fb7f595ad168735946499c4612baf1eaebac7ede301f1f29621d8aed
491faf2ba42627fffd4dd027607299c8bb591ec2 rdma_main.h xtrdma_get_access 19f16fc6f4e0b2a8e3f9e14ec4ac9d2bde1e34472313866abe430be1f9258c7e
491faf2ba42627fffd4dd027607299c8bb591ec2 srq.h XTRDMA_SRFQ_CTX_* c0f7edd9bc65a4a574c082167221bdb7644c28e6f4387c1bd2a5db157b2341ae
491faf2ba42627fffd4dd027607299c8bb591ec2 srq.c xtrdma_hw_create_srfqc c511b0d669e9501ece1c3f02ac7079b6d900b34cf87a33b1dc800857b47fd766
491faf2ba42627fffd4dd027607299c8bb591ec2 event.h XTRDMA_EQ_CTX_* 9c1185a2279854c95ed00a949c2a8aa3f4a1588386de65bf7fa7662d08dfb99a
491faf2ba42627fffd4dd027607299c8bb591ec2 event.c xtrdma_hw_create_eq efdba325776236f3715c4e847d5bae90369263bd29b14192dd6234b498df189b
```

Add `XTR_V1_HW_VERSION=1`, `XTR_V1_OP_KEY_ALLOC=8'h04`, `XTR_V1_OP_OCC_FLUSH=8'h0a`, `XTR_V1_OP_CEQC_DELETE=8'h12`, `XTR_V1_OP_CEQC_QUERY=8'h13`, `XTR_V1_OP_AEQC_DELETE=8'h16`, `XTR_V1_OP_AEQC_QUERY=8'h17`, and `XTR_V1_OP_TQ_FLUSH=8'h20`, plus all `*_BODY_*` coordinates, object/state/mode values, and CMQ completion fields. Keep standalone QPC coordinates unprefixed by `BODY`; CQC local coordinates may remain only if the checker proves every final body coordinate is local `+8`. SRQC/EQC final coordinates must be local `+16`.

- [ ] **Step 4: Freeze masks and independently rebuild all 11 cases**

Define the request envelope qword mask as `64'h8fff3fff00000000`. Define the body masks, qword 0 first, exactly as:

```text
CQC create:
00000000001fffff ff0fffffffffffff fffffffffffff8ff fffffffffff8c701
f000000000ffffff 0000000000000fff ffffffffffffffc0 0000000f00ffffff

MRT register PBL0:
6000000000ffffff 00000000ff000000 ffffffffff000000 ff00bfffffffffff
ffffffffffffffff fffffffffffff000 0000000000000fff 0000000000000000

MRT key-alloc PBL0:
6000000000ffffff 00000000ff000000 ffffffffffffffff ff00bfffffffffff
ffffffffffffffff fffffffffffff000 0000000000000fff 0000000000000000

SRQC create:
000000000000ffff 0000000000000000 cfffffffffffffff ffff000000000000
fffffffffffff0fc 00000000ffffffff 0000000000000000 0000000000000000

CEQC/AEQC create:
0000000000000fff 0000000000000000 c1ffffffffffffff fffffffffffff800
0000007ffff0c000 ffff00000007ffff 0000000000000000 0000000000000000
```

For MRT PBL1 change qword 6 to `ffffffffffffffff`; for PBL2 change qword 5 to `fffffff000000000` and qword 6 to `0000000000000fff`. `mrt_key_alloc_pbl0_boundary` must differ from register PBL0 at byte 16 bits 23:0 by the self STAG index and use opcode `04` in its input contract.

Store those constants behind the immutable lookup API `request_envelope_mask(qword_index)` and `body_mask(image_kind, opcode, pbl_mode, qword_index, mask)` in `rdma_xtr_v1_image_masks.svh`. Task 9.5 freezes the values; Task 10B includes the file in the codec package and consumes the API for validation.

The Python builder must first fill logical qwords with independent occupancy, then emit `word.to_bytes(8, "big")`. Store every source input in `GoldenCase.inputs`; compute the human-readable summary from that immutable input collection, and verify a parsed summary reproduces the same input collection before writing `context.hex`.

- [ ] **Step 5: Make cleanup and the SV reader fail closed**

Implement `rdma_xtr_v1_golden_reader::read_all()` so a case is appended only after marker, name, nonempty input summary, byte count, and exactly that many hex bytes are consumed. Reject duplicate names, truncated payloads, extra payload bytes, malformed hex, and trailing incomplete cases with `RDMA_SC_CODEC_ERROR`.

Change the `xtr_defs` cleanup so a deletion failure changes a previously successful target to failure while preserving an existing command failure:

```bash
cleanup_status=$?
trap - EXIT
if ! rm -rf -- "$ref_dir"; then
  echo "Failed to remove xtr_v1 reference directory: $ref_dir" >&2
  if (( cleanup_status == 0 )); then cleanup_status=1; fi
fi
exit "$cleanup_status"
```

Keep the existing exact `/tmp/rdma_xtr_v1_ref.XXXXXX` path guard before deletion.

- [ ] **Step 6: Run GREEN checks**

Run locally:

```bash
python3 -m unittest -v tests.unit.test_check_xtr_v1_defs
```

The fixed source is consumed only by the first 53 command below; do not substitute another driver tree.

Run on 53:

```bash
scripts/run_vcs53.sh xtr_defs check
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
```

Expected: Python reports all tests OK; checker prints `xtr_v1 definitions: PASS`; VCS summary contains zero UVM errors/fatals; all 11 cases and their complete payloads were parsed.

- [ ] **Step 7: Commit Task 9.5**

```bash
git add hw/xtr_v1 docs/hw src/codec/xtr_v1/rdma_xtr_v1_defs.svh \
  src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh tools/check_xtr_v1_defs.py \
  tests/unit/test_check_xtr_v1_defs.py tests/support/rdma_xtr_v1_golden_reader.svh \
  tests/unit/rdma_xtr_v1_defs_test.svh tests/rdma_unit_test_pkg.sv sim/Makefile
git commit -m "feat: freeze xtr_v1 context body ABI"
```

### Task 10A: Refactor hardware-neutral context and layout models

**Files:**
- Create: `src/model/rdma_context_layouts.svh`
- Modify: `src/model/rdma_model_pkg.sv`
- Modify: `src/model/rdma_context_models.svh:1-570`
- Verify unchanged runtime ownership: `src/model/rdma_resources.svh:390-581`
- Create: `tests/unit/rdma_context_model_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: Write failing model ownership, copy, and validation tests**

Create `rdma_context_model_test.svh` with factory construction and deep-copy checks for every new value object. The test must explicitly prove that RDMA rights and PCIe DMA permissions are distinct types:

```systemverilog
rdma_rdma_access_t access;
rdma_dma_permission_t dma_permission;
access = '{local_write:1, remote_read:1, remote_write:1,
           memory_window_bind:0, remote_atomic:1};
dma_permission = '{device_read:1, device_write:0, atomic:0};
if (!access.remote_write || dma_permission.device_write)
  `uvm_error("ACCESS_TYPES", "RDMA rights leaked into PCIe DMA permission")
```

Construct one valid model of each type, clone it, mutate nested layout/address-vector objects on the clone, and verify the original is unchanged. Add negative rows for a mismatched handle kind, mixed function UID/generation, zero/non-power-of-two depth, 4KiB queue misalignment, 64B shadow misalignment, 512B QPC-context misalignment, out-of-range ring index, illegal mode, zero MRT length, length above 46 bits, inconsistent lkey/rkey, and contradictory PBL fields. The URC model rows must also require exact `RDMA_SC_INVALID_ARGUMENT` for `remote_qpn == 0`.

Keep runtime ownership assertions on resources:

```systemverilog
qp.sq_producer_index = 3;
qp.sq_consumer_index = 1;
qp.rq_producer_index = 2;
qp.rq_consumer_index = 0;
srq.max_sge = 4;
if (!qp.validate().ok() || !srq.validate().ok())
  `uvm_error("RUNTIME_OWNER", "QP/SRQ resources lost runtime state")
```

- [ ] **Step 2: Run RED on 53**

```bash
scripts/run_vcs53.sh core rdma_context_model_test
```

Expected: compile fails because `rdma_context_layouts.svh`, `rdma_rdma_access_t`, and the refactored model fields do not exist.

- [ ] **Step 3: Add the hardware-neutral layout vocabulary**

Include `rdma_context_layouts.svh` from `rdma_model_pkg.sv` immediately before `rdma_context_models.svh`. Define these types without any xtr_v1 constant:

```systemverilog
typedef enum bit [1:0] {
  RDMA_OBJECT_DIRECT_4K       = 2'd0,
  RDMA_OBJECT_INDIRECT_4K     = 2'd1,
  RDMA_OBJECT_HUGE_2M         = 2'd2,
  RDMA_OBJECT_L3_INDIRECT_4K  = 2'd3
} rdma_object_mode_e;

typedef enum bit [1:0] {
  RDMA_CONTEXT_INVALID = 2'd0,
  RDMA_CONTEXT_VALID   = 2'd1,
  RDMA_CONTEXT_ERROR   = 2'd2
} rdma_context_state_e;

typedef enum bit [1:0] {
  RDMA_MR_PBL0 = 2'd0,
  RDMA_MR_PBL1 = 2'd1,
  RDMA_MR_PBL2 = 2'd2
} rdma_mr_pbl_mode_e;

typedef enum bit [1:0] {
  RDMA_MR_PAGE_4K = 2'd0,
  RDMA_MR_PAGE_64K = 2'd1,
  RDMA_MR_PAGE_2M = 2'd2,
  RDMA_MR_PAGE_1G = 2'd3
} rdma_mr_host_page_size_e;

typedef enum bit {
  RDMA_MR_ADDRESS_VA_BASED   = 1'b0,
  RDMA_MR_ADDRESS_ZERO_BASED = 1'b1
} rdma_mr_address_mode_e;

typedef struct packed {
  bit local_write;
  bit remote_read;
  bit remote_write;
  bit memory_window_bind;
  bit remote_atomic;
} rdma_rdma_access_t;
```

Implement `rdma_ring_position`, `rdma_page_table_layout`, `rdma_address_vector`, and `rdma_mr_page_layout` as `uvm_object` value classes with `uvm_object_utils`, zero/default constructors, `do_copy`, `validate`, and `describe`. Their public fields are fixed as:

```systemverilog
class rdma_ring_position extends uvm_object;
  int unsigned index;
  bit wrap;
endclass

class rdma_page_table_layout extends uvm_object;
  rdma_object_mode_e mode;
  rdma_backing_addr_t sd_base;
  rdma_backing_addr_t current_base;
  bit current_valid;
  rdma_backing_addr_t next_base;
  bit next_valid;
endclass

class rdma_address_vector extends uvm_object;
  int unsigned source_address_index;
  int unsigned source_vport;
  int unsigned destination_vport;
  int unsigned destination_port;
  bit [47:0] destination_mac;
  byte unsigned destination_ip[16];
  bit ipv6;
  bit vlan_enable;
  bit cfi;
  bit lag_enable;
  bit tunnel_enable;
  bit forwarding_enable;
  bit [11:0] vlan_id;
  bit [7:0] traffic_class;
  bit [19:0] flow_label;
  bit [7:0] hop_limit;
  bit [15:0] udp_source_port;
endclass

class rdma_mr_page_layout extends uvm_object;
  rdma_mr_pbl_mode_e pbl_mode;
  rdma_mr_host_page_size_e host_page_size;
  rdma_backing_addr_t pba0;
  rdma_backing_addr_t pba1;
  int unsigned first_pbl_index;
  rdma_mr_address_mode_e address_mode;
  bit odp;
  bit invalidate_enable;
  bit payload_vf_enable;
  int unsigned payload_vf_id;
  int unsigned mr_serial;
endclass
```

`rdma_page_table_layout.validate()` requires every valid base to be 4KiB aligned. `rdma_mr_page_layout.validate()` requires PBL0 to use aligned `pba0` with zero `pba1/first_pbl_index`, PBL1 to use aligned `pba0/pba1` with zero `first_pbl_index`, and PBL2 to use nonzero `first_pbl_index` with zero `pba0/pba1`.

- [ ] **Step 4: Replace the six field models with serializable semantics only**

The public ownership block below shows the final model after Task 10A.2 and the URC
queue-model prerequisite, so it includes `rdma_qpc_behavior behavior;`, common
`path_mtu_bytes`, and the canonical URC queue object as architectural truth.
For a clean replay, Task 10A omits both the behavior member and common QPC MTU, but
retains the historical pre-10A.2 extension ownership: RC declares
`int unsigned retry_count, rnr_retry_count, path_mtu_bytes;`, and URC separately declares
`int unsigned path_mtu_bytes;`. Task 10A.1 adds the behavior type, member, and tests while
preserving both legacy extension MTU fields. Task 10A.2 then follows
`docs/superpowers/specs/2026-08-22-qpc-path-mtu-ownership-design.md` and executable
`docs/superpowers/plans/2026-08-22-qpc-path-mtu-ownership.md`: it adds the common MTU and
removes both extension duplicates. The URC queue-model prerequisite then follows
`docs/superpowers/plans/2026-08-22-urc-qpc-create-semantics.md` to reach the final block
shown below. Complete Task 10A -> Task 10A.1 -> Task 10A.2 -> URC queue-model
prerequisite -> Task 10B -> Task 10C in that portion of the clean replay; each
prerequisite remains an isolated commit.

Keep `rdma_hw_model` and the transport-extension base. Use the following exact public ownership:

```systemverilog
class rdma_qpc_model extends rdma_hw_model;
  rdma_handle qp_h, pd_h, send_cq_h, recv_cq_h, srq_h;
  rdma_transport_e transport;
  rdma_qp_state_e state;
  int unsigned host_id, vf_id, stat_index;
  bit [15:0] pkey;
  bit [7:0] qp_sequence;
  rdma_rdma_access_t access;
  int unsigned path_mtu_bytes;
  int unsigned sq_depth, rq_depth;
  rdma_backing_addr_t sq_backing, rq_backing, context_backing;
  rdma_object_mode_e sq_mode, rq_mode;
  rdma_address_vector address_vector;
  rdma_qpc_behavior behavior;
  bit signature_enable, tx_flow_control, rx_flow_control;
  rdma_qpc_transport_ext transport_ext;
endclass

class rdma_qpc_rc_ext extends rdma_qpc_transport_ext;
  bit [23:0] remote_qpn, send_psn, recv_psn;
  int unsigned retry_count, rnr_retry_count;
endclass

class rdma_qpc_ud_ext extends rdma_qpc_transport_ext;
  bit [31:0] qkey;
endclass

class rdma_urc_queue_config extends uvm_object;
  rdma_backing_addr_t rsq_backing, rdsq_backing, dsq_backing;
  int unsigned rsq_depth, rdsq_depth;
  int unsigned rdsq_fetch_count, dsq_fetch_count;
  int unsigned rq_sequence_threshold_entries;
  int unsigned sq_completion_threshold_entries;
endclass

class rdma_qpc_urc_ext extends rdma_qpc_transport_ext;
  bit [23:0] remote_qpn, rbsn, dbsn, rpsn, dpsn;
  rdma_urc_queue_config queues;
endclass

class rdma_cqc_model extends rdma_hw_model;
  rdma_handle cq_h, ceq_h;
  rdma_context_state_e state;
  int unsigned depth, cqe_size_bytes, threshold;
  rdma_page_table_layout page_layout;
  rdma_ring_position producer, consumer;
  bit urc_enable, load_ci_done;
  bit [1:0] last_arm_sequence, arm_sequence, arm_state;
  rdma_backing_addr_t shadow_backing;
endclass

class rdma_mrt_model extends rdma_hw_model;
  rdma_handle mr_h, pd_h;
  rdma_context_state_e state;
  rdma_iova_t iova;
  longint unsigned length;
  bit [31:0] lkey, rkey;
  rdma_rdma_access_t access;
  bit [1:0] object_type;
  rdma_mr_page_layout page_layout;
endclass

class rdma_srqc_model extends rdma_hw_model;
  rdma_handle srq_h, pd_h;
  rdma_context_state_e state;
  int unsigned depth, load_pi_threshold, limit_threshold;
  rdma_object_mode_e object_mode;
  rdma_backing_addr_t srfq_backing, shadow_backing;
  rdma_ring_position producer;
  bit [1:0] arm_sequence;
endclass

class rdma_ceqc_model extends rdma_hw_model;
  rdma_handle ceq_h;
  rdma_context_state_e state;
  int unsigned depth, vector_id;
  rdma_page_table_layout page_layout;
  rdma_ring_position producer, consumer;
endclass

class rdma_aeqc_model extends rdma_hw_model;
  rdma_handle aeq_h;
  rdma_context_state_e state;
  int unsigned depth, vector_id;
  rdma_page_table_layout page_layout;
  rdma_ring_position producer, consumer;
endclass
```

Remove QPC PI/CI fields, SRQC `max_sge` and consumer index, and EQC `interrupt_enable` from context models. Do not remove the corresponding QP/SRQ runtime state from `rdma_resources.svh`. Event interrupt enable remains policy outside the serialized model.

Validation shared by all models must check handle kind, one consistent function UID/generation pair across all handles, object-ID profile width, nested object non-null, and nested validation before returning success. An all-zero lifecycle pair is valid for a decode-created projection handle. QPC queues are 4KiB aligned; QPC context backing is 512B aligned; CQC shadow is 64B aligned. MRT requires `mr_h.object_id == lkey[31:8]`; any remote right requires `rkey == lkey`, otherwise `rkey` is zero or `lkey`. Validation must not mutate access rights; the MRT codec derives a normalized hardware rights value that sets local-write whenever remote-write or remote-atomic is set.

Generic URC validation requires `remote_qpn != 0`, a non-null `queues` object,
4KiB-aligned backing addresses, and nonzero power-of-two RSQ/RDSQ depths; a zero
remote QPN returns `RDMA_SC_INVALID_ARGUMENT`. Each threshold is either zero or a
power of two of at least two entries; RQ/SQ thresholds must not exceed the common QPC
RQ/SQ depths. Generic model validation does not limit fetch counts or impose device
field widths.

- [ ] **Step 5: Run GREEN model regression on 53**

```bash
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_model_test
scripts/run_vcs53.sh core rdma_resource_manager_test
```

Expected: all tests PASS; copy is deep; invalid topology fails atomically; resource PI/CI and SRQ max-SGE remain valid.

- [ ] **Step 6: Commit Task 10A**

```bash
git add src/model/rdma_context_layouts.svh src/model/rdma_model_pkg.sv \
  src/model/rdma_context_models.svh tests/unit/rdma_context_model_test.svh \
  tests/rdma_unit_test_pkg.sv
git commit -m "refactor: model serializable RDMA context layouts"
```

### Task 10B: Add logical-qword and mask-validation helpers

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_qword_codec.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_qword_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: Write failing endian, occupancy, and mask tests**

```systemverilog
builder = new("builder");
expect_ok("RESET", builder.reset(16));
expect_ok("LOW_FIELD", builder.put_field(0, 0, 16, 16'h1234));
expect_ok("HIGH_FIELD", builder.put_field(0, 56, 8, 8'hab));
memcpy_bytes = '{8'hde, 8'had, 8'hbe, 8'hef};
expect_ok("MEMCPY", builder.put_memcpy(8, memcpy_bytes));
expect_ok("SERIALIZE", builder.serialize(bytes));
if (bytes != '{8'hab,8'h00,8'h00,8'h00,8'h00,8'h00,8'h12,8'h34,
               8'hde,8'had,8'hbe,8'hef,8'h00,8'h00,8'h00,8'h00})
  `uvm_error("BE_QWORD", "logical qword did not serialize big-endian")
```

Snapshot both words and occupancy before testing overlap, width 0/65, value overflow, non-qword byte offset, an image length not divisible by 8, out-of-range memcpy, and a body bit outside its mask. Each failure must leave words, occupancy, and output arguments unchanged. Load the serialized bytes with `deserialize()`, read fields with `get_field()`, and require the same values.

- [ ] **Step 2: Run RED on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_qword_codec_test
```

Expected: compile fails because `rdma_xtr_v1_qword_builder` is undefined.

- [ ] **Step 3: Implement the two-phase qword API**

Implement this public API:

```systemverilog
class rdma_xtr_v1_qword_builder extends uvm_object;
  function rdma_status reset(int unsigned byte_count);
  function rdma_status put_field(int unsigned word_byte_offset,
                                 int unsigned lsb,
                                 int unsigned width,
                                 bit [63:0] value);
  function rdma_status get_field(int unsigned word_byte_offset,
                                 int unsigned lsb,
                                 int unsigned width,
                                 output bit [63:0] value);
  function rdma_status put_memcpy(int unsigned final_byte_offset,
                                  byte unsigned value[]);
  function rdma_status serialize(output byte unsigned value[]);
  function rdma_status deserialize(byte unsigned value[]);
  function rdma_status validate_allowed_mask(
    rdma_image_kind_e image_kind,
    bit [7:0] opcode,
    rdma_mr_pbl_mode_e pbl_mode
  );
  function void get_words(output bit [63:0] value[]);
  function void get_occupancy(output bit [63:0] value[]);
endclass
```

`put_field()` accepts only qword-aligned `word_byte_offset`, computes the qword index, validates `lsb+width <= 64`, validates value width, completes an overlap scan, and only then updates `words[index] |= value << lsb` plus occupancy. `put_memcpy()` maps final byte `n` to logical qword bits `63-8*(n%8) : 56-8*(n%8)` and performs the same preflight-before-mutation rule. `serialize()` writes each word as bytes `[63:56]` through `[7:0]`; `deserialize()` performs the inverse and starts with zero occupancy because decoding must not pretend input fields were authored.

Include the Task 9.5 mask file and keep its frozen values behind pure lookup functions, not caller-mutable arrays:

```systemverilog
class rdma_xtr_v1_image_masks;
  static function bit [63:0] request_envelope_mask(int unsigned qword_index);
  static function rdma_status body_mask(rdma_image_kind_e image_kind,
                                        bit [7:0] opcode,
                                        rdma_mr_pbl_mode_e pbl_mode,
                                        int unsigned qword_index,
                                        output bit [63:0] mask);
endclass
```

Unknown kind/opcode/PBL combinations return `RDMA_SC_UNSUPPORTED_OPCODE`. `validate_allowed_mask()` rejects any word bit outside the returned mask and proves every body mask is disjoint from `request_envelope_mask()`; Task 10B must not edit the frozen mask values.

- [ ] **Step 4: Run GREEN helper regression on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_qword_codec_test
scripts/run_vcs53.sh core rdma_codec_registry_test
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
```

Expected: PASS; the byte sequence is exactly the test vector; all negative cases preserve prior state; existing raw-byte packer tests remain unchanged.

- [ ] **Step 5: Commit Task 10B**

```bash
git add src/codec/xtr_v1/rdma_xtr_v1_qword_codec.svh \
  src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh src/codec/rdma_codec_pkg.sv \
  tests/unit/rdma_xtr_v1_qword_codec_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: add xtr_v1 logical qword codec"
```

### Task 10C: Implement standalone RC/UD/URC QPC codecs

> **Task 10A.1 and Task 10A.2 prerequisites:** Follow
> `docs/superpowers/specs/2026-08-21-qpc-behavior-ownership-design.md` and
> `docs/superpowers/specs/2026-08-22-qpc-path-mtu-ownership-design.md`.
> QPC behavior is explicit model state; `context_backing` maps to `SHADOW_PBA`;
> xtr_v1 has one shared `FC_EN`; and QPC uses a private 512B allowed mask. Common
> `rdma_qpc_model.path_mtu_bytes` is the only PMTU source; codecs must not read MTU
> from a transport extension or synthesize a transport/golden default.
> The URC frozen-ABI and URC queue-model prerequisites both follow
> `docs/superpowers/plans/2026-08-22-urc-qpc-create-semantics.md`. On the current
> branch, apply and review both before resuming Task 10C; Task 10B and its accepted
> qword-builder commit remain in place and must not be replayed or rewritten.

**Files:**
- Modify: `src/codec/rdma_codec_base.svh`
- Create: `src/codec/xtr_v1/rdma_xtr_v1_qpc_codecs.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_qpc_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: Write failing registry, golden, round-trip, and corruption tests**

For RC, UD, and URC, look up the stable keys listed in the file map, encode the matching model, and compare all 512 bytes with `qpc_rc_boundary`, `qpc_ud_boundary`, and `qpc_urc_boundary`. Decode the image and use the codec API, not UVM object comparison:

```systemverilog
status = codec.serialized_equal(source_model, decoded_model, equal, mismatch);
expect_status({case_name, "_EQUAL_STATUS"}, status, RDMA_SC_OK);
if (!equal) `uvm_error("QPC_ROUNDTRIP", {case_name, ": ", mismatch})
```

Add a projected-handle test where source handles have nonzero `function_uid/generation` and decoded handles have zero lifecycle metadata; equality must still pass when kind/object ID match and fail when either differs. Verify the encoded image keeps source generation in `function_generation`, but payload bytes do not change when only lifecycle metadata changes.

Add a table-driven `serialized_equal()` falsification test. Clone a valid
decoded/canonical model and mutate, one at a time, `behavior.transport_version`,
`behavior.migration_enable`, `behavior.tx_endian_swap`, `behavior.rx_endian_swap`,
`behavior.read_after_write_fence`, `behavior.atomic_after_atomic_fence`,
`behavior.\priority `, common `path_mtu_bytes`, `context_backing` by one 512B unit,
`signature_enable`, TX flow control, and RX flow control. Each call must return
`RDMA_SC_OK` with `equal == 0` and a nonempty, useful `mismatch`. The individual TX and
RX mutations are legal generic-model states even though encode later rejects their
asymmetry.

Every golden builder explicitly sets `behavior`; transport selection must not supply
behavior defaults. Set `context_backing.value = frozen_shadow_pba << 9`, verify
`signature_enable -> SQ_CE_EN`, and use equal TX/RX flow-control values for positive
vectors. Add a separate positive encode/decode round trip at the accepted maxima
`behavior.transport_version = 3` (`tver=3`) and `behavior.\priority = 7`, with equal
TX/RX flow control; do not compare this maxima case to a fixed golden.

Every golden builder also explicitly sets common `path_mtu_bytes`: RC=8192B/code 5,
UD=4096B/code 4, and URC=8192B/code 5. These are case inputs, not defaults. Require all
three transport cases to complete encode/decode/serialized-equal round trips. Exercise
the complete supported table 1024/2048/4096/8192 -> 2/3/4/5.
Encode 256, 512, and another unsupported nonzero value such as 1500 and require exact
`RDMA_SC_INVALID_ARGUMENT`. Decode otherwise valid images with PMTU code 0/1/6/7 and
require exact `RDMA_SC_CODEC_ERROR`.

Build the URC source model only from the `qpc_urc_boundary` semantic input summary:
all backing values are byte addresses, and every depth or threshold is an entry count.
Encode must match all 512 frozen bytes; decode must restore the same canonical values;
`serialized_equal()` must compare every member of `queues` as well as the other URC
semantics.

Keep all canonical `qpc_urc_boundary` values and the frozen golden unchanged. Add a
separate positive, non-golden owner-discriminator routing test by cloning or building
a valid URC model with mutually distinct owners: `remote_qpn = 24'h123456`,
`dbsn = 24'h234567`, `rsq_depth = 32`, `rdsq_depth = 128`,
`rdsq_fetch_count = 7`, and `dsq_fetch_count = 13`. Keep every other field valid and
keep both thresholds within the common QPC RQ/SQ topology.

After encode, do not rely only on decode/round-trip. Deserialize the image and read
the exact frozen target-field coordinates, requiring
`XTR_V1_QPC_DST_QPN == 24'h123456`,
`XTR_V1_QPC_URC_TX_DBSN == 24'h234567`,
`XTR_V1_QPC_URC_RX_DBSN == 24'h234567`,
`XTR_V1_QPC_URC_RXED_DBSN == 24'h234567`,
`XTR_V1_QPC_URC_RSQ_SIZE == 5`,
`XTR_V1_QPC_URC_RDSQ_SIZE == 7`,
`XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM == 7`, and
`XTR_V1_QPC_URC_NXT_DSQ_FETCH_NUM == 13`. Then decode must return
`RDMA_SC_OK`, and `serialized_equal(source, decoded)` must return `RDMA_SC_OK` with
`equal == 1`. These direct coordinate assertions prevent a mutually swapped encoder
and decoder from passing through self-consistency. This is a non-golden routing test;
it must not modify or replace the fixed vector.

Add table-driven URC field-mutation cases for every sequence mirror group (two RBSN,
three DBSN, two RPSN, and two DPSN fields), each runtime field
`RX_SRBSN/TX_SRBSN/MAX_TX_SRBSN`, each RSQ/RDSQ depth code, both fetch values, both
threshold codes, the DSQ next-page relation, and reserved bits. A changed depth code,
fetch value, or threshold code whose exact inverse leaves the model topology valid
must decode with `RDMA_SC_OK`, publish the inverse-transformed canonical model, and
make `serialized_equal(source, decoded)` return `equal == 0`. Every representable
depth code and fetch value is valid by itself; tests must not classify those mutations
as unconditional corruption. The semantic-invalid decode matrix must include both a
threshold code whose inverse exceeds the common QPC RQ or SQ depth and an otherwise
valid URC image whose `DST_QPN` is cleared to zero; each must return exact
`RDMA_SC_CODEC_ERROR` and leave the decode output null. Mirror mismatch, runtime
nonzero, DSQ next-page relation, reserved-bit, metadata, or length corruption must
also return exact `RDMA_SC_CODEC_ERROR` and leave the decode output null.

Add URC encode-invalid cases for an RSQ or RDSQ depth whose `log2` exceeds 3 bits,
either fetch count greater than 63, either nonzero threshold whose `log2` exceeds
4 bits, and a DSQ current page equal to the maximum 52-bit value. Each returns exact
`RDMA_SC_INVALID_ARGUMENT` and leaves the image output null. The highest aligned byte
address `64'hffff_ffff_ffff_f000`, whose page is `(1 << 52) - 1`, must encode and decode
successfully for RSQ and RDSQ; the same DSQ current page is invalid because its next
page would overflow. A crafted decode image with DSQ current page at that maximum and
the narrow next-page field wrapped to zero must return `RDMA_SC_CODEC_ERROR` and leave
the decode output null. Retain tests proving the generic model can express queue
depths, fetch counts, and thresholds beyond xtr_v1 field widths. A non-golden
threshold-zero round trip must return zero; every nonzero threshold must decode by the
exact inverse `1 << code`.

Require exact negative status codes by error source. Caller-supplied encode models with
the wrong subclass or transport extension, field-width violations (including
QPN/CQN/PD/SRQ and behavior), queue/context alignment violations, invalid PMTU, retry,
or TC values, TX/RX flow-control mismatch, or other semantic invalidity return
`RDMA_SC_INVALID_ARGUMENT`. Image decode failures caused by wrong metadata or length,
QPC-private reserved-bit corruption, RC PSN mirror corruption, or image-derived
semantic invalidity return `RDMA_SC_CODEC_ERROR`; the latter includes URC
`DST_QPN == 0` and threshold inverse values that exceed common QPC depth. An absent
registry variant returns `RDMA_SC_UNSUPPORTED_OPCODE`. The image output remains
null/unpublished on every encode failure, and the model output remains null/unpublished
on every decode failure, including every PMTU failure above.

- [ ] **Step 2: Run RED on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test
```

Expected: compile fails on the missing `serialized_equal()` API or missing QPC codecs.

- [ ] **Step 3: Add serialized equality to the codec contract**

Add this non-pure virtual method to `rdma_codec_base` so existing Task 8 test codecs continue compiling:

```systemverilog
virtual function rdma_status serialized_equal(
  rdma_hw_model lhs,
  rdma_hw_model rhs,
  output bit equal,
  output string mismatch
);
  equal = 1'b0;
  mismatch = "serialized equality is not implemented by this codec";
  return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, mismatch);
endfunction
```

Every xtr_v1 QPC/body codec overrides it. The QPC override compares handles by
`kind/object_id`; it ignores ONLY every handle's `function_uid` and `generation`.
Aside from SQE-to-SQD canonicalization on state decode, it compares every other QPC
model and transport-extension semantic represented by the xtr_v1 image.

- [ ] **Step 4: Implement common QPC projection plus three transport codecs**

Create an abstract `rdma_xtr_v1_qpc_codec_base` with final image metadata:

```systemverilog
image.length = 512;
image.alignment = 512;
image.endian = RDMA_ENDIAN_BIG;
image.image_kind = RDMA_IMAGE_QPC;
image.hardware_version = XTR_V1_HW_VERSION;
image.function_generation = qpc.qp_h.generation;
image.write_target_kind = RDMA_HW_TARGET_NONE;
```

Derived classes are `rdma_xtr_v1_qpc_rc_codec`, `rdma_xtr_v1_qpc_ud_codec`, and `rdma_xtr_v1_qpc_urc_codec`. Each begins with a fresh 512-byte qword builder, calls common-field projection, calls only its own extension projection, validates the complete QPC allowed mask, serializes once, and assigns the output image only after all operations succeed.

The common projection writes `behavior.transport_version`, migration, both endian
swap bits, both fence bits, and priority into their frozen QPC fields. It writes
`SHADOW_PBA = context_backing.value >> 9` and `SQ_CE_EN = signature_enable`.
Reject unequal TX/RX flow control with `RDMA_SC_INVALID_ARGUMENT`, otherwise write the
shared value to `FC_EN`; decode restores both model fields from that bit and restores
the byte IOVA with `SHADOW_PBA << 9`.

Define this QPC-private mask interface in `rdma_xtr_v1_qpc_codecs.svh`:

```systemverilog
protected function bit qpc_allowed_mask(
  rdma_transport_e transport,
  int unsigned qword_index,
  output bit [63:0] mask
);
protected function rdma_status validate_qpc_encode_mask(
  rdma_xtr_v1_qword_builder builder,
  rdma_transport_e transport
);
protected function rdma_status validate_qpc_decode_mask(
  rdma_xtr_v1_qword_builder builder,
  rdma_transport_e transport
);
```

`qpc_allowed_mask()` covers exactly qwords 0..63 and supplies distinct RC, UD, and URC
masks derived from the frozen QPC field table. An unsupported transport or qword index
fails the lookup. `validate_qpc_encode_mask()` uses `get_occupancy()`, requires exactly
64 qwords, and requires `occupancy[qword] == allowed_mask[qword]`, so an authored field
counts even when its value is zero. `validate_qpc_decode_mask()` uses `get_words()`,
requires exactly 64 qwords, and rejects
`(words[qword] & ~allowed_mask[qword]) != 0` with `RDMA_SC_CODEC_ERROR`.

None of these helpers calls, extends, or modifies the 64B sparse-command `body_mask()`
or its frozen body masks. Leave `CC_TYPE`, `RTO_CODE`, and `LOAD_RQ_PI_TH`
zero/reserved until a separate approved design assigns their ownership.

Use explicit mapping helpers:

```systemverilog
case (qpc.transport)
  RDMA_TRANSPORT_RC:  service_type = 3'd0;
  RDMA_TRANSPORT_UD:  service_type = 3'd3;
  RDMA_TRANSPORT_URC: service_type = 3'd6;
  default: return unsupported_transport();
endcase

case (qpc.state)
  RDMA_QPS_RESET: state_code = 3'd0;
  RDMA_QPS_INIT:  state_code = 3'd1;
  RDMA_QPS_RTR:   state_code = 3'd2;
  RDMA_QPS_RTS:   state_code = 3'd3;
  RDMA_QPS_ERROR: state_code = 3'd4;
  RDMA_QPS_SQD, RDMA_QPS_SQE: state_code = 3'd5;
  default: return invalid_state();
endcase

case (qpc.path_mtu_bytes)
  1024: pmtu_code = 3'd2;
  2048: pmtu_code = 3'd3;
  4096: pmtu_code = 3'd4;
  8192: pmtu_code = 3'd5;
  default:
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "xtr_v1 path MTU is unsupported");
endcase

case (pmtu_code)
  3'd2: qpc.path_mtu_bytes = 1024;
  3'd3: qpc.path_mtu_bytes = 2048;
  3'd4: qpc.path_mtu_bytes = 4096;
  3'd5: qpc.path_mtu_bytes = 8192;
  default:
    return rdma_status::make(RDMA_SC_CODEC_ERROR,
                             "xtr_v1 PMTU code is invalid");
endcase
```

All queue backing fields require 4KiB alignment before `>>12`; depths require exact power-of-two encoding. Decode reverses those transformations and returns SQD for hardware state 5. Decode assigns the inverse PMTU mapping only into temporary QPC state, validates that state and the entire image, and publishes the output model only after the whole image passes.

For RC, write `send_psn` to byte offsets `160, 208, 344, 352, 376, 416, 424, 432` and `recv_psn` to `224, 232, 288`, using each offset's frozen LSB/width. Decode uses byte 352 and byte 288 as canonical values only after all mirrors match. Retry and RNR retry are exactly 3 bits.

For all address-vector transports, write `ICOS=traffic_class[7:5]` and `DSCP=traffic_class[7:2]`. Require `traffic_class[1:0]==0` for UD and `==2` for RC/URC. Use `put_memcpy()` for the 16 destination-IP bytes in driver `memcpy` order; encode MAC, VLAN/CFI, flow label, vports, destination port, source-address index, hop limit, UDP source port, LAG/tunnel/forward flags from the named model fields.

For URC encode, require non-null `queues` and `remote_qpn != 0`; a zero remote QPN
returns `RDMA_SC_INVALID_ARGUMENT`. Map the nonzero `remote_qpn` to `DST_QPN`. On
decode, `DST_QPN == 0` returns `RDMA_SC_CODEC_ERROR`, and the canonical `remote_qpn`
may be published only after this check passes. Map each canonical sequence scalar to
all of its mirrors:
`rbsn -> TX_RBSN/RX_RBSN`, `dbsn -> TX_DBSN/RX_DBSN/RXED_DBSN`,
`rpsn -> CUR_TX_RPSN/TPE_RPSN_MAX`, and
`dpsn -> CUR_TX_DPSN/TPE_DPSN_MAX`. Decode returns `RDMA_SC_CODEC_ERROR` on any
mirror mismatch and assigns a canonical scalar only after its entire group agrees.
Never feed RC `send_psn/recv_psn` mappings from a URC model.

Validate every URC backing as 4KiB aligned, compute its page value, and prove that
page fits 52 bits before authoring any field. Split the RSQ and DSQ current pages
across their frozen high/low fields and encode RDSQ in its single 52-bit field. Encode
RSQ/RDSQ depth as exact
`log2(entries)` fitting 3 bits, RDSQ/DSQ fetch counts directly fitting 6 bits, and
each threshold as code zero for zero or exact power-of-two `log2(entries)` fitting
4 bits for nonzero. For DSQ, compute `current + 1` in widened 53-bit arithmetic and
reject overflow before narrowing or authoring the next-page field. Decode performs
the exact inverse transforms, zero-extends the current and next page values, and checks
the relation in widened arithmetic; a maximum current page followed by a narrow
wrapped-zero next page is overflow, not a valid relation.

The URC create allowed mask includes the new `RSQ_SIZE` and `NXT_RDSQ_FETCH_NUM`
fields plus every common and URC create-owned field. It excludes
`RX_SRBSN/TX_SRBSN/MAX_TX_SRBSN`, `CC_TYPE`, `RTO_CODE`, and `LOAD_RQ_PI_TH`; any
nonzero excluded field returns `RDMA_SC_CODEC_ERROR`. Encode authors every allowed
field, including semantic zeros, and its 64-qword occupancy must exactly equal the
selected URC mask.

- [ ] **Step 5: Register exact keys without wildcard fallback**

Add a package-level helper:

```systemverilog
function automatic rdma_status rdma_xtr_v1_register_qpc_codecs(
  rdma_codec_registry registry
);
```

It registers exactly `(qpc,rc,00)`, `(qpc,ud,00)`, and `(qpc,urc,00)`. If any registration fails, return that status and do not attempt to alias one transport to another. Tests clear a private registry before calling it, so package initialization has no global mutable singleton.

- [ ] **Step 6: Run GREEN QPC regression on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_qword_codec_test
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
```

Expected: every command exits 0 with UVM warning/error/fatal counts 0/0/0; RC and UD
remain frozen byte-identical; URC matches the canonical create vector; valid
owner-discriminator exact-coordinate routing checks pass; valid
depth/fetch/threshold mutations decode to inverse canonical values with
`RDMA_SC_OK` and serialized inequality; zero-`DST_QPN`, topology-invalid threshold,
mirror, runtime, relation, reserved, metadata, and length cases return exact
`RDMA_SC_CODEC_ERROR` with null decode outputs; encode-invalid cases return exact
`RDMA_SC_INVALID_ARGUMENT`, upper-bound RSQ/RDSQ backings round-trip, and registry
isolation remains intact.

- [ ] **Step 7: Commit Task 10C**

```bash
git add src/codec/rdma_codec_base.svh \
  src/codec/xtr_v1/rdma_xtr_v1_qpc_codecs.svh src/codec/rdma_codec_pkg.sv \
  tests/unit/rdma_xtr_v1_qpc_codec_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: encode xtr_v1 QPC images"
```

### Task 10D: Implement sparse CQC/MRT/SRQC/CEQC/AEQC body codecs

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_context_body_codecs.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_context_body_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: Write failing body-golden and envelope-isolation tests**

Build eight cases matching the body golden cases. For each, lookup the exact create/register key, encode, require 64 bytes, compare every byte, decode, and call `serialized_equal()`. Then prove common envelope ownership remains zero:

```systemverilog
expect_ok("BODY_WORDS", bytes_to_be_words(image.bytes, words));
foreach (words[q]) begin
  if ((words[q] & rdma_xtr_v1_image_masks::request_envelope_mask(q)) != 0)
    `uvm_error("BODY_ENVELOPE", golden_case.name)
end
if (image.write_target_kind != RDMA_HW_TARGET_NONE)
  `uvm_error("BODY_TARGET", "sparse body obtained a write target")
```

Add corruption rows for CQC duplicate/state fields, MRT state/key mirrors, MRT PBL mutual exclusion, SRQC reserved gaps, EQC wrong kind, CEQC/AEQC cross-decode, all object-ID width boundaries, all address alignments, wrong opcode key, and one out-of-mask bit in each qword that has a reserved position.

- [ ] **Step 2: Run RED on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_context_body_codec_test
```

Expected: first registry lookup returns `RDMA_SC_UNSUPPORTED_OPCODE` because no body codecs are registered.

- [ ] **Step 3: Implement common sparse-body base behavior**

Create `rdma_xtr_v1_context_body_codec_base` with a protected `finish_body()` that assigns metadata only after mask validation and serialization:

```systemverilog
candidate.length = 64;
candidate.alignment = 64;
candidate.endian = RDMA_ENDIAN_BIG;
candidate.image_kind = expected_image_kind();
candidate.hardware_version = XTR_V1_HW_VERSION;
candidate.function_generation = owner_generation;
candidate.write_target_kind = RDMA_HW_TARGET_NONE;
candidate.backing_target = '0;
candidate.hmc_target = '0;
candidate.bar_target = '0;
```

`validate_image()` requires those exact metadata values, 64 payload bytes, all reserved bits zero, and an opcode-specific mask. Decode creates a temporary typed model, validates all mirrored fields and nested values, and assigns the output only on success.

- [ ] **Step 4: Implement CQC and EQ/SRQ create bodies in final WQE coordinates**

Implement these concrete classes:

```text
rdma_xtr_v1_cqc_create_body_codec
rdma_xtr_v1_srqc_create_body_codec
rdma_xtr_v1_ceqc_create_body_codec
rdma_xtr_v1_aeqc_create_body_codec
```

CQC writes CQN in qword 0 and the remaining local CQC fields at final bytes 8..63. Encode `depth` as log2, page-layout bases as `>>12`, shadow backing as `>>6`, ring positions as index/wrap, and CQE sizes 32/64/128 bytes as their frozen profile codes. CQC accepts indirect-4K, huge-2M, and L3-indirect-4K; direct-4K returns `RDMA_SC_INVALID_ARGUMENT`.

SRQC writes SRFQN at byte 0, then state/load threshold/shadow PBA at byte 16, PD at 24, SRFQ PBA/depth/mode at 32, and PI wrap/PI/limit/arm sequence at 40. `max_sge` and CI are neither read nor written.

Use one protected EQ-layout helper for CEQC and AEQC, while retaining distinct concrete codecs, handle kinds, image kinds, opcodes, and registry keys. It writes EQN at byte 0; state/depth/next PBA at 16; current PBA/valid at 24; PI/mode at 32; MSI-X/CI at 40. EQ accepts indirect-4K and L3-indirect-4K only.

- [ ] **Step 5: Implement separate KEY_ALLOC and MR_REGISTER bodies**

Create `rdma_xtr_v1_mrt_key_alloc_body_codec` for opcode `04` and `rdma_xtr_v1_mrt_register_body_codec` for opcode `05`. Both encode:

- byte 0: STAG index from `mr_h.object_id`, plus mirrored next state;
- byte 8: STAG key from `lkey[7:0]`;
- byte 16: PD, payload VF, normalized rights, object type, page size, PBL/address/invalidate modes, and mirrored state;
- byte 24: 46-bit length, ODP, and repeated STAG key;
- byte 32: `iova.value`;
- byte 40/48: PBL0/PBL1 PBA or PBL2 first index plus MR serial.

KEY_ALLOC additionally writes byte 16 bits 23:0 with the same STAG index. MR_REGISTER requires and emits zero in those bits. The decoders reject each other's image even if all other bytes match. Normalize rights to `[local-write, remote-read, remote-write, MW-bind, remote-atomic]`, forcing local-write when remote-write or remote-atomic is set.

Map context state by object profile: CQC/SRQC/CEQC/AEQC use invalid/valid/error codes `0/1/2`; MRT maps invalid to `XTRDMA_MR_ST_INVLD(0)` and valid to `XTRDMA_MR_ST_VLD(2)`, while generic error is unsupported for MRT create/register. Map host page size 4KiB/2MiB/1GiB to xtr_v1 codes `0/1/2` and reject the hardware-neutral 64KiB value in this profile. Map VA-based/zero-based addressing to xtr_v1 codes `0/1`; never cast semantic enum ordinals directly without the mapping function.

- [ ] **Step 6: Register the six body identities**

Add:

```systemverilog
function automatic rdma_status rdma_xtr_v1_register_context_body_codecs(
  rdma_codec_registry registry
);
```

Register CQC `0c`, MRT key-alloc `04`, MRT register `05`, SRQC `35`, CEQC `10`, and AEQC `14`. PBL mode selects an allowed mask inside the MRT codec; it never changes the opcode or causes a registry fallback.

- [ ] **Step 7: Run GREEN body regression on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_context_body_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
```

Expected: PASS; eight 64-byte bodies match golden; envelope bits are all zero; KEY_ALLOC and MR_REGISTER remain distinguishable; corrupted mirrors and reserved bits fail atomically.

- [ ] **Step 8: Commit Task 10D**

```bash
git add src/codec/xtr_v1/rdma_xtr_v1_context_body_codecs.svh \
  src/codec/rdma_codec_pkg.sv tests/unit/rdma_xtr_v1_context_body_codec_test.svh \
  tests/rdma_unit_test_pkg.sv
git commit -m "feat: encode xtr_v1 sparse context bodies"
```

### Task 11A: Implement CMQ envelope, opcode/body registry, and checked composition

**Files:**
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_defs.svh`
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh`
- Create: `src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_cmq_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: Write failing envelope ownership and composition tests**

Create one checked-composition case for every supported opcode:

```text
00 QPC_CREATE       01 QPC_MODIFY       02 QPC_DELETE       03 QPC_QUERY
04 KEY_ALLOC        05 MR_REGISTER      06 MR_DEREGISTER
0a OCC_FLUSH        0c CQC_CREATE       0e CQC_DELETE        0f CQC_QUERY
10 CEQC_CREATE      12 CEQC_DELETE      13 CEQC_QUERY
14 AEQC_CREATE      16 AEQC_DELETE      17 AEQC_QUERY
20 TQ_FLUSH         35 SRFQC_CREATE     37 SRFQC_DELETE      38 SRFQC_QUERY
```

For Task 10 bodies, encode through the registered body codec before composition. For light commands, build the typed command body described in Step 4. Require exactly one opcode in the final qword 0, exactly one copy of the object ID, and byte-for-byte preservation of every Task 10 body-owned bit.

Negative tests must mutate: one envelope bit outside `8fff3fff00000000`, one body bit outside the registered mask, a body image kind, hardware version, endian, length, opcode/body pairing, and a test-only registry entry whose envelope/body masks overlap. Each returns `RDMA_SC_CODEC_ERROR` with a null result. An unregistered opcode returns `RDMA_SC_UNSUPPORTED_OPCODE`.

- [ ] **Step 2: Write the QPC signature oracle test**

Build QPC create and full-QPC modify requests with signature byte initially zero. Compute the expected byte independently in the test:

```systemverilog
expected_signature = 8'h00;
foreach (unsigned_wqe[i]) expected_signature ^= unsigned_wqe[i];
foreach (qpc_image.bytes[i]) expected_signature ^= qpc_image.bytes[i];
expected_signature = ~expected_signature;
```

Require the composer to insert that byte at the frozen signature field. Recompute XOR over final WQE plus QPC and require `8'hff`. For partial modify, `sign_en` and signature stay zero and QPC payload is not accepted as a signature source.

- [ ] **Step 3: Run RED on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_codec_test
```

Expected: compile fails because the envelope, command bodies, and composer are undefined.

- [ ] **Step 4: Implement typed envelope and light command bodies**

Define these xtr_v1 command objects in `rdma_xtr_v1_cmq_codecs.svh`:

```systemverilog
class rdma_xtr_v1_cmq_envelope extends uvm_object;
  bit valid;
  bit vfid_override;
  bit [10:0] use_vfid;
  bit wrap;
  bit [4:0] wqe_index;
  bit [7:0] opcode;
endclass

class rdma_xtr_v1_qpc_command_body extends rdma_hw_model;
  rdma_handle qp_h, send_cq_h, recv_cq_h;
  rdma_backing_addr_t qpc_buffer;
  rdma_qp_state_e next_state;
  bit full_modify;
  bit partial_modify;
  bit [1:0] wbe_template_count;
  bit [5:0] modify_start_qword[4];
  bit [7:0] modify_wbe[4];
  bit [63:0] modify_data[4];
endclass

class rdma_xtr_v1_object_id_command_body extends rdma_hw_model;
  rdma_handle object_h;
endclass

class rdma_xtr_v1_mr_deregister_body extends rdma_hw_model;
  rdma_handle mr_h;
  bit [7:0] stag_key;
  rdma_context_state_e next_state;
endclass

class rdma_xtr_v1_occ_flush_body extends rdma_hw_model;
  bit vf_flush, mr_serial_flush;
  bit qpc, cqc, mrt, pble, sqrqe, sgb_irqe, eirqe, orqe, uaqe, pd;
  bit [20:0] qpn;
  bit [11:0] mr_serial;
  rdma_backing_addr_t pd_backing;
endclass
```

Implement an internal `rdma_xtr_v1_cmq_light_body_codec` registry with `encode(opcode, rdma_hw_model, image)` and one concrete codec per layout family: QPC command, object-ID command, MR deregister, OCC flush, and empty TQ flush. Every light-body image is 64 bytes, alignment 64, big-endian, hardware version 1, `RDMA_IMAGE_CMQ_SQE`, target `NONE`, with every envelope-owned bit zero. The body ownership registry selects the concrete codec by opcode; no `case` is allowed to accept an opcode absent from the supported list.

QPC create writes QPN at byte 0, SQ/RQ CQN plus `sign_en` and zero signature at byte 8, and 512B-shifted QPC buffer at byte 24. Full modify additionally writes next state, modify mode, and buffer; partial modify writes four `(start_qword,WBE)` pairs at byte 16 and four data qwords at bytes 32..56. Delete writes QPN plus SQ/RQ CQN; query writes QPN plus the query buffer at byte 24.

`rdma_xtr_v1_object_id_command_body` is parameterized by codec construction, not by an unchecked runtime enum: CQC delete/query requires CQ and 21 bits; CEQC delete/query requires CEQ and 12 bits; AEQC delete/query requires AEQ and 12 bits; SRFQC delete/query requires SRQ and 16 bits. MR deregister writes STAG index/next state at byte 0 and STAG key at byte 8. OCC flush uses qword 0 QPN/VF/MR-serial flags, qword 1 object flags/MR serial, and qword 2 `pd_backing >> 12`; TQ flush owns no body bits.

Do not register `QP_FLUSH(1a)` here: the fixed driver's CMQ submit switch does not emit it, and QP flush remains a Task 12 doorbell operation. Do not register empty fixed-driver `MODIFY` switch cases for CEQC/AEQC/SRFQC.

- [ ] **Step 5: Implement immutable ownership registry and envelope encoder**

Provide:

```systemverilog
class rdma_xtr_v1_cmq_body_registry extends uvm_object;
  function rdma_status register_body(bit [7:0] opcode,
                                     rdma_image_kind_e input_kind,
                                     bit [63:0] masks[8]);
  function rdma_status lookup(bit [7:0] opcode,
                              output rdma_image_kind_e input_kind,
                              output bit [63:0] masks[8]);
  function void seal();
endclass

class rdma_xtr_v1_cmq_envelope_codec extends uvm_object;
  function rdma_status encode(rdma_xtr_v1_cmq_envelope envelope,
                              output rdma_hw_image image);
endclass
```

Duplicate registration is fatal plus `RDMA_SC_INVALID_STATE`, matching the generic codec registry. `seal()` makes later registration return `RDMA_SC_INVALID_STATE`. During standard registration reject every opcode whose body mask intersects the request-envelope mask. Envelope encode starts from zero and owns only valid, VF override/use-vfid, wrap, index, and opcode.

- [ ] **Step 6: Implement the sole request composer**

Expose one entry point:

```systemverilog
function rdma_status compose_request(
  rdma_xtr_v1_cmq_envelope envelope,
  rdma_hw_image body,
  rdma_hw_image qpc_signature_source,
  output rdma_hw_image result
);
```

The implementation performs this order without mutating inputs:

1. Encode and validate the envelope image.
2. Lookup opcode ownership; reject missing opcode or wrong body image kind.
3. Validate body length/version/endian/alignment and all bits against the opcode body mask.
4. Recheck all eight `(envelope_mask & body_mask)==0` values.
5. OR corresponding big-endian logical qwords into a temporary 64-byte result.
6. For QPC create/full modify only, require a valid 512-byte QPC image, zero the signature field, XOR all 64 WQE bytes and all 512 QPC bytes, invert the 8-bit XOR, and insert the signature.
7. Validate final allowed masks and assign metadata `length=64`, `alignment=64`, big-endian, `RDMA_IMAGE_CMQ_SQE`, hardware version 1. Leave target `NONE`; the later CMQ engine assigns the ring entry target.
8. Assign `result` only after every validation passes.

VF override/use-vfid comes only from `envelope`; QPC `vf_id` and MRT payload VF remain body/context content and are never copied into envelope bits.

- [ ] **Step 7: Run GREEN CMQ request regression on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_context_body_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test
```

Expected: PASS for every listed opcode; unknown and empty-switch opcodes are rejected; signature XOR is `ff`; no Task 10 body can write the envelope.

- [ ] **Step 8: Commit Task 11A**

```bash
git add src/codec/xtr_v1/rdma_xtr_v1_defs.svh \
  src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh \
  src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh src/codec/rdma_codec_pkg.sv \
  tests/unit/rdma_xtr_v1_cmq_codec_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: compose checked xtr_v1 CMQ requests"
```

### Task 11B: Implement CMQ completion and hardware error-code decoding

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_error_codec.svh`
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_cmq_completion_test.svh`
- Create: `tests/unit/rdma_xtr_v1_error_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

- [ ] **Step 1: Write failing completion metadata and raw-preservation tests**

Define a 64-byte completion vector with opcode, command ecode, WQE index, and wrap in qword 0. Require:

```systemverilog
status = completion_codec.decode(image, completion);
expect_status("CQE_DECODE", status, RDMA_SC_OK);
if (completion.opcode != expected_opcode ||
    completion.command_ecode != expected_ecode ||
    completion.wqe_index != expected_index || completion.wrap != expected_wrap)
  `uvm_error("CQE_COMMON", "common completion fields changed")
```

Add wrong length/kind/version/endian, reserved-bit corruption, expected-opcode mismatch, and expected-wrap mismatch cases. The decoder must leave `completion=null` on structural failure. For query opcodes, retain the exact object payload bytes: CQC bytes 8..63, MRT bytes 16..63, and EQC/SRQC bytes 16..47.

- [ ] **Step 2: Write failing error classification table tests**

At minimum cover these stable representatives:

```systemverilog
check_error(8'h00, RDMA_ENGINE_CMQ, RDMA_SC_OK,               RDMA_ENGINE_CMQ);
check_error(8'h45, RDMA_ENGINE_DMA, RDMA_SC_DMA_TRANSLATION,  RDMA_ENGINE_DMA);
check_error(8'h4c, RDMA_ENGINE_DMA, RDMA_SC_DMA_PERMISSION,   RDMA_ENGINE_DMA);
check_error(8'h70, RDMA_ENGINE_DMA, RDMA_SC_PCIE_COMPLETION,  RDMA_ENGINE_DMA);
check_error(8'hf4, RDMA_ENGINE_CQ,  RDMA_SC_QUEUE_FULL,       RDMA_ENGINE_CQ);
check_error(8'hf8, RDMA_ENGINE_CEQ, RDMA_SC_QUEUE_FULL,       RDMA_ENGINE_CEQ);
check_error(8'hfb, RDMA_ENGINE_AEQ, RDMA_SC_QUEUE_FULL,       RDMA_ENGINE_AEQ);
check_error(8'hff, RDMA_ENGINE_PCIE,RDMA_SC_PCIE_COMPLETION,  RDMA_ENGINE_PCIE);
check_error(8'he7, RDMA_ENGINE_CQ,  RDMA_SC_UNKNOWN_HW_ERROR, RDMA_ENGINE_CQ);
```

Every nonzero result must set `hardware_code_valid=1`, retain the original 8-bit code in `hardware_code`, retain/canonicalize the source engine, set hardware category/severity consistently, and provide a nonempty symbolic message. Unknown values never collapse to success.

- [ ] **Step 3: Run RED on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_completion_test
scripts/run_vcs53.sh core rdma_xtr_v1_error_codec_test
```

Expected: compile fails because completion and error codec classes are absent.

- [ ] **Step 4: Implement lossless CMQ completion decoding**

Define:

```systemverilog
class rdma_xtr_v1_cmq_completion extends uvm_object;
  bit [7:0] opcode;
  bit [7:0] command_ecode;
  bit [4:0] wqe_index;
  bit wrap;
  byte unsigned object_payload[];
endclass
```

`decode_completion(image, expected_opcode, expected_wrap, completion)` validates `RDMA_IMAGE_CMQ_CQE`, 64 bytes, alignment 64, big endian, hardware version 1, then decodes logical qword 0. If expected opcode/wrap does not match, return `RDMA_SC_CODEC_ERROR`. Query payload slicing is fixed by opcode; non-query completions return an empty payload. Command ecode remains raw in the completion even when nonzero; the caller passes it to the error codec.

- [ ] **Step 5: Implement deterministic ecode classification**

Provide:

```systemverilog
class rdma_xtr_v1_error_codec extends uvm_object;
  function rdma_status decode_status(bit [7:0] hardware_code,
                                     rdma_engine_kind_e observed_engine,
                                     output rdma_status decoded);
endclass
```

Use exact constants from frozen `defs.h`/`wr.h`. Map PBL-invalid codes `45/c5` to DMA translation; PD/key/right/access families `4b..4c`, `55..56`, `60..63`, `c7`, `cb..cd`, `d7..d8` to DMA permission; `70` and global MBUS `ff` to PCIe completion; `f4/f8/fb` to queue full. Classify remaining TPE/TME/TDE/CCE/RPE/RME/RCE families as unknown hardware error while preserving the caller's observed engine when valid. Code zero is success. The CQE normal codes `01/80/81` are success only when decoding data-plane CQE context; they are nonzero CMQ errors in CMQ context.

Set `retryable=1` only for queue-full and transient completion/translation classes; permission and unknown errors are not retryable. Never discard the raw code or replace an explicit observed engine with `NONE`.

- [ ] **Step 6: Run GREEN completion/error regression on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_completion_test
scripts/run_vcs53.sh core rdma_xtr_v1_error_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_codec_test
```

Expected: PASS; structural corruption is distinguished from a valid nonzero command ecode; all known and unknown raw codes remain observable.

- [ ] **Step 7: Commit Task 11B**

```bash
git add src/codec/xtr_v1/rdma_xtr_v1_error_codec.svh \
  src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh src/codec/rdma_codec_pkg.sv \
  tests/unit/rdma_xtr_v1_cmq_completion_test.svh \
  tests/unit/rdma_xtr_v1_error_codec_test.svh tests/rdma_unit_test_pkg.sv
git commit -m "feat: decode xtr_v1 CMQ completions and errors"
```

### Task 11C: Run end-to-end context/CMQ regression and delivery audit

**Files:**
- Create: `tests/unit/rdma_xtr_v1_context_cmq_regression_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `docs/hw/xtr-v1-source-map.md`

- [ ] **Step 1: Write an end-to-end create/register regression test**

For RC/UD/URC QPC and every Task 10 body, perform model validation, body/context encode, checked composition, completion decode, and serialized equality where a body is returned. Use two envelopes with distinct VF override/use-vfid values and prove body bytes remain unchanged while only envelope-owned bits change. Also verify all failed operations leave the immutable input model and input body unchanged, and separately retained artifacts from prior successful calls remain unchanged. The output formal passed to any failing encode/decode call must be null/unpublished.

- [ ] **Step 2: Run RED on 53**

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_context_cmq_regression_test
```

Expected: simulation exits nonzero because the factory cannot find `rdma_xtr_v1_context_cmq_regression_test` before it is included in `rdma_unit_test_pkg.sv`.

- [ ] **Step 3: Include the test and finalize the source map**

Add the test include. Update `xtr-v1-source-map.md` with a table for QPC standalone versus sparse-body versus final CMQ SQE, including byte count, alignment, endian, source functions, registry key, mask owner, and all 11 context golden case names. Explicitly record that KEY_ALLOC `04` is the ordinary MR path with a self-parent STAG, while MR_REGISTER `05` leaves parent zero.

- [ ] **Step 4: Run the complete focused verification set**

Run locally:

```bash
python3 -m unittest -v tests.unit.test_check_xtr_v1_defs
git diff --check
```

Run fresh staging jobs on 53, one command per test:

```bash
scripts/run_vcs53.sh xtr_defs check
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_xtr_v1_qword_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_context_body_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_cmq_completion_test
scripts/run_vcs53.sh core rdma_xtr_v1_error_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_context_cmq_regression_test
scripts/run_vcs53.sh core rdma_codec_registry_test
scripts/run_vcs53.sh core rdma_model_test
scripts/run_vcs53.sh core rdma_resource_manager_test
```

Expected: every command exits zero, every UVM summary has `UVM_ERROR : 0` and `UVM_FATAL : 0`, checker prints `xtr_v1 definitions: PASS`, and each remote `rdma_uvm.XXXXXX` staging directory is removed.

- [ ] **Step 5: Audit scope and forbidden coupling**

Run:

```bash
if rg -n "XTR_V1_|xtr_v1" src/model src/types; then exit 1; fi
if rg -n "sq_(producer|consumer)_index|rq_(producer|consumer)_index|max_sge|interrupt_enable" \
  src/model/rdma_context_models.svh; then exit 1; fi
rg -n "RDMA_IMAGE_(CQC|MRT|SRQC|CEQC|AEQC)" src/codec/xtr_v1
```

Expected: both guarded searches exit zero with no matches; the third unguarded search shows sparse body codecs/masks but no direct ring write. Inspect `git diff b7f0ed7...HEAD -- src/codec src/model hw tools tests docs/hw sim` and verify there is no PCIe adapter, host_mem implementation, CMQ ring mutation, doorbell scheduling, SQE/RQE, or DUT state emulation in this focused change.

- [ ] **Step 6: Commit Task 11C**

```bash
git add tests/unit/rdma_xtr_v1_context_cmq_regression_test.svh \
  tests/rdma_unit_test_pkg.sv docs/hw/xtr-v1-source-map.md
git commit -m "test: verify xtr_v1 context CMQ composition"
```

## Completion criteria

This focused plan is complete only when all eight task commits exist in order, all review findings are closed, and the Task 11C verification evidence comes from fresh jobs on `10.11.10.53`. The next architecture task may consume only validated `rdma_hw_image`, typed command objects, registry keys, and status objects; it may not reach into codec internals or reinterpret raw fields.
