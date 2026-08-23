# xtr_v1 Typed Doorbells Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Freeze every ordinary 8-byte xtr_v1 runtime doorbell emitted by the pinned driver and add a hardware-neutral scheduler that performs dependency writes, barriers, and Function-aware MMIO in strict order.

**Architecture:** Hardware-specific payload models and codecs live in `rdma_codec_pkg`; the scheduler consumes only a validated `rdma_hw_image`, Function binding, target handle, and injected `rdma_host_mem_api`/`rdma_pcie_api`. The scheduler never owns PCIe, host memory, or DUT state. It preflights the whole request before side effects, serializes one Function identity, permits different Functions to progress independently, writes payload dependencies before queue/context dependencies, then performs DMA barrier, MMIO barrier, and the final MMIO write.

**Tech Stack:** SystemVerilog/UVM 1.2, Python 3 frozen-definition checker, Synopsys VCS on `10.11.10.53`, pinned xtr_v1 kernel driver commit `491faf2ba42627fffd4dd027607299c8bb591ec2` from `/home/ubuntu/workspace/Desktop.zip`.

---

## Frozen-driver reconciliation

The following rules override the older broad Task 12 text in
`2026-08-20-rdma-uvm-driver-architecture.md`.

1. `XTRDMA_OP_TQ_FLUSH (0x20)` is a CMQ command and is already represented by
   the CMQ codec. It is not an MMIO doorbell. Offset `0x008` is the distinct
   TX-flush doorbell (`XTRDMA_DB_TX_FLUSH`). Rename the generic kind from
   `RDMA_DOORBELL_TQ_FLUSH` to `RDMA_DOORBELL_TX_FLUSH`; do not keep a
   semantically incorrect TQ alias.
2. Add `RDMA_DOORBELL_RTS2SQD` and `RDMA_DOORBELL_SQD2RTS`. The complete kind
   set is CMQ SQ, SQ, RQ, SRQ, CQ, CEQ, AEQ, RTS2SQD, SQD2RTS, QP flush, and
   TX flush.
3. Freeze thirteen golden cases in this exact order:
   `cmq_sq`, `sq`, `rq`, `srq_pi`, `srq_limit`, `cq_rc_ud`, `cq_urc`, `ceq`,
   `aeq`, `rts2sqd`, `sqd2rts`, `qp_flush`, `tx_flush`.
   Their fixed semantic inputs are:

   | Case | Fixed inputs |
   |---|---|
   | `cmq_sq` | `pi=27, polarity=1, offset=0x000` |
   | `sq` | qword 0 of `sqe_rc_boundary`, `offset=0x100` |
   | `rq` | `qpn=0x15555, icos=5, pi=0x4567, wrap=1, offset=0x010` |
   | `srq_pi` | `srqn=0xa55a, pi=0x4567, wrap=1, limit_invalid=1, offset=0x040` |
   | `srq_limit` | `srqn=0xa55a, limit=0x2aaa, arm_sn=3, pi_invalid=1, offset=0x040` |
   | `cq_rc_ud` | `cqn=0x15555, host=5, ci=0x654321, wrap=1, arm=1, arm_state=2, arm_sn=3, urc=0, offset=0x018` |
   | `cq_urc` | `cqn=0x12345, host=3, sq_ci=0x4567, sq_wrap=1, rq_ci=0x2345, rq_wrap=0, arm=1, arm_state=1, arm_sn=2, urc=1, offset=0x018` |
   | `ceq` | `ceqn=0x2aaaaa, ci=0x2aaaa, wrap=1, offset=0x020` |
   | `aeq` | `aeqn=0xaaa, ci=0x15555, wrap=1, offset=0x028` |
   | `rts2sqd` | `qpn=0x15555, dst_port=11, qp_sn=0xa6, icos=5, db_type=0xd, offset=0x048` |
   | `sqd2rts` | `qpn=0x15555, dst_port=11, qp_sn=0xa6, icos=5, db_type=0xe, offset=0x050` |
   | `qp_flush` | `qpn=0x15555, dst_port=11, qp_sn=0xa6, icos=0, db_type=0xa, offset=0x058` |
   | `tx_flush` | `qpn=0x2aaaa, dst_port=15, qp_sn=0, icos=0, db_type=0xb, offset=0x008` |
4. All thirteen images are one 8-byte logical qword serialized big-endian.
   The SQ case is the first qword of the already encoded SQE. It must be
   supplied as an exact eight-byte header by a typed SQ-doorbell model; the
   doorbell layer must not duplicate or reinterpret the future multi-opcode
   SQE codec.
5. The optional FWQE fast path writes 64-byte SQE and 512-byte SGB MMIO
   payloads. It remains outside this task because it requires the later SQE
   engine, but the generic scheduler must not hard-code an 8-byte limit: it
   validates descriptor width against the codec-produced image and notify
   window.
6. SRQ has two layouts at offset `0x040`: PI/wrap update with
   `XTRDMA_SRFQ_LIMIT_INVLD=1`, and limit/arm update with
   `XTRDMA_SRFQ_PI_INVLD=1`. CQ has RC/UD and URC layouts at offset `0x018`.
7. The four QP-control doorbells share `dst_port[51:48]`, `qp_sn[47:40]`,
   `db_type[39:36]`, `icos[23:21]`, and `qpn[20:0]`. Codec-owned `db_type`
   values are QP flush `0xA`, TX flush `0xB`, RTS2SQD `0xD`, and SQD2RTS
   `0xE`; callers cannot override them. TX flush fixes destination port to
   `QSCH_G2P_DPORT_NODE_MODE=15`, QP sequence to zero, and ICOS to zero.
8. Every non-merge 8-byte write uses the same pre-write scheduling contract:
   dependencies, DMA visibility barrier, MMIO ordering barrier, MMIO write.
   Serializing all doorbells through the same per-Function lock guarantees a
   barrier between consecutive same-Function writes, matching the pinned
   driver's `xtrdma_iowrite64be()` non-combine intent.

## File map

| File | Responsibility |
|---|---|
| `src/types/rdma_enum_types.svh` | Correct and extend hardware-neutral doorbell kinds. |
| `src/model/rdma_queue_models.svh` | Validate the extended generic kind/target matrix. |
| `src/codec/xtr_v1/rdma_xtr_v1_defs.svh` | Frozen doorbell fields and driver constants. |
| `src/codec/xtr_v1/rdma_xtr_v1_doorbell_codecs.svh` | Typed payload models, concrete codecs, and registry. |
| `src/codec/rdma_codec_pkg.sv` | Publish the xtr_v1 doorbell layer. |
| `src/core/rdma_doorbell_scheduler.svh` | Descriptor, dependency, result, and ordered scheduler. |
| `src/core/rdma_core_pkg.sv` | Import adapter contracts and publish scheduler. |
| `sim/filelists/core.f`, `sim/filelists/host_mem.f` | Compile adapter package before core package. |
| `tools/check_xtr_v1_defs.py` | Independently parse all doorbell fields/constants and generate 13 goldens. |
| `tests/unit/test_check_xtr_v1_defs.py` | Fail-closed Python tests for new mappings and golden set. |
| `hw/xtr_v1/source_manifest.txt` | Pin any newly consumed driver source, including `eth_header/register.h`. |
| `hw/xtr_v1/golden_vectors/doorbell.hex` | Immutable 13-case payload oracle. |
| `docs/hw/xtr-v1-source-map.md` | Source, variant, offset, width, and endian provenance. |
| `tests/unit/rdma_xtr_v1_doorbell_codec_test.svh` | Golden, round-trip, range, reserved-bit, and registry tests. |
| `tests/unit/rdma_doorbell_scheduler_test.svh` | Binding, dependency, ordering, failure, and concurrency tests. |
| `tests/mocks/rdma_mock_adapters.svh` | Optional shared call trace used only to observe cross-adapter order. |
| `tests/rdma_unit_test_pkg.sv` | Publish both tests. |

### Task 12: Implement the frozen doorbell subsystem

- [ ] **Step 1: Add failing Python definition/golden tests**

Extend `tests/unit/test_check_xtr_v1_defs.py` first. Tests must require all of
the following before production changes:

- exact thirteen-case name/order and eight-byte payload length;
- exact relative offsets `0x000,0x100,0x010,0x040,0x040,0x018,0x018,0x020,`
  `0x028,0x048,0x050,0x058,0x008`;
- SRQ PI-invalid/limit-invalid fields, limit threshold, arm sequence, and SRQN;
- CQ CI-invalid, arm-invalid, URC selector, RC CI, both URC completion cursors,
  host ID, and CQN;
- QP-control fields, four DB type values, and TX destination-port value;
- mutation tests proving a changed field coordinate, constant, case name,
  payload byte, or source hash is rejected rather than skipped.

Run:

```bash
python3 -m unittest -v tests.unit.test_check_xtr_v1_defs
```

Expected RED: failures report missing mappings and the old three-case golden.
Record the exact failing test count in the commit message or handoff.

- [ ] **Step 2: Freeze definitions and regenerate the independent oracle**

Extend `tools/check_xtr_v1_defs.py` using only parsed driver symbols. Add
`eth_header/register.h` to the immutable source manifest for
`QSCH_G2P_DPORT_NODE_MODE`; do not copy driver files into the repository.
Generate the thirteen cases from independent `ReferenceField` coordinates and
driver constants, never from SV codec code. Reuse the SQE boundary case's
first qword for the `sq` golden so the two independent golden outputs must
agree byte-for-byte.

Add the exact SV constants required by those generated cases, including CQ
URC, SRQ limit, QP-control, and DB type constants. Update the source map with
the distinction between CMQ TQ flush and MMIO TX flush.

Run:

```bash
python3 -m unittest -v tests.unit.test_check_xtr_v1_defs
python3 tools/check_xtr_v1_defs.py \
  --kernel-root /tmp/rdma_task12_ref.kHsqLz/dpu_kernel_rdma-version_0.1.32
```

Expected GREEN: all Python tests pass and the checker prints
`xtr_v1 definitions: PASS`.

- [ ] **Step 3: Commit the frozen driver delta**

```bash
git add tools/check_xtr_v1_defs.py tests/unit/test_check_xtr_v1_defs.py \
  src/codec/xtr_v1/rdma_xtr_v1_defs.svh \
  hw/xtr_v1/source_manifest.txt hw/xtr_v1/golden_vectors/doorbell.hex \
  docs/hw/xtr-v1-source-map.md
git commit -m "test: freeze xtr_v1 doorbell contracts"
```

- [ ] **Step 4: Add failing typed-codec tests**

Create `tests/unit/rdma_xtr_v1_doorbell_codec_test.svh` and include it from
`tests/rdma_unit_test_pkg.sv`. The wished-for public API is:

```systemverilog
rdma_xtr_v1_doorbell_codec_registry registry;
rdma_xtr_v1_doorbell_model_base model;
rdma_hw_image image;
rdma_hw_model decoded;
rdma_status status;

registry = rdma_xtr_v1_doorbell_codec_registry::type_id::create("registry");
status = registry.register_defaults();
status = registry.encode(model, image);
status = registry.decode(model.codec_variant(), image, decoded);
```

Use distinct typed models for CMQ SQ, SQ header, RQ, SRQ, CQ, CEQ, AEQ, and
QP-control payloads. SRQ and CQ expose typed variant enums. The QP-control
model exposes kind, qpn, dst_port, qp_sn, and icos but not a caller-writable
DB type. Every model retains a target handle for lifecycle validation.

Tests must:

- encode every golden and compare all eight bytes, metadata, and offset;
- decode and compare serialized equality for every variant;
- reject wrong model dynamic type, unknown/unregistered variant, out-of-range
  field, invalid target kind, stale target generation metadata, malformed
  image length/endian/version/target/offset, nonzero reserved bits, and a SQ
  header not exactly eight bytes;
- prove `sq` equals bytes 0..7 of `sqe_rc_boundary`;
- prove each registered codec has one stable canonical registry key and that
  duplicate registration fails closed.

Run on 53:

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_doorbell_codec_test
```

Expected RED: VCS compilation fails because the registry and typed models are
undefined.

- [ ] **Step 5: Implement the typed codecs minimally**

In `rdma_xtr_v1_doorbell_codecs.svh`, use a common codec base around
`rdma_xtr_v1_qword_builder`. Its `encode()` must set:

```systemverilog
image.length = XTR_V1_DB_BYTES;
image.alignment = XTR_V1_DB_BYTES;
image.endian = RDMA_ENDIAN_BIG;
image.image_kind = RDMA_IMAGE_DOORBELL;
image.hardware_version = XTR_V1_HW_VERSION;
image.function_generation = model.target_h.generation;
image.write_target_kind = RDMA_HW_TARGET_BAR;
image.bar_target.value = expected_relative_offset();
```

`validate_image()` must enforce all metadata plus exact reserved-zero bits for
the selected variant. The SQ codec may bypass field extraction only to carry
the exact typed eight-byte SQE header; all other codecs must use frozen
LSB/width constants. Registry selection uses a model-supplied canonical
variant string, not an unchecked default case.

Also extend `rdma_doorbell_kind_e` and generic doorbell validation as specified
above, and include the codec file in `rdma_codec_pkg.sv`.

Run:

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_doorbell_codec_test
scripts/run_vcs53.sh core rdma_request_model_test
```

Expected GREEN: both tests pass with zero UVM warnings, errors, and fatals.

- [ ] **Step 6: Commit the codec layer**

```bash
git add src/types/rdma_enum_types.svh src/model/rdma_queue_models.svh \
  src/codec/xtr_v1/rdma_xtr_v1_doorbell_codecs.svh \
  src/codec/rdma_codec_pkg.sv tests/rdma_unit_test_pkg.sv \
  tests/unit/rdma_request_model_test.svh \
  tests/unit/rdma_xtr_v1_doorbell_codec_test.svh
git commit -m "feat: encode typed xtr_v1 doorbells"
```

- [ ] **Step 7: Add failing scheduler tests**

Create `tests/unit/rdma_doorbell_scheduler_test.svh`. The public scheduling API
is:

```systemverilog
rdma_doorbell_scheduler scheduler;
rdma_doorbell_desc desc;
rdma_doorbell_result result;
rdma_status status;

scheduler = rdma_doorbell_scheduler::type_id::create("scheduler");
status = scheduler.configure(host_mem_api, pcie_api);
scheduler.submit(binding, desc, result, status);
```

`rdma_doorbell_desc` contains kind, Function handle, target handle, notify BAR
ID, relative offset, width, endian, codec-produced payload image, barrier
policy, write-combining policy, `allow_merge`, `merge_requested`, ordered
dependency objects, timeout, and readback policy. A dependency contains a
nonzero unique ID, stage (`PAYLOAD` or `QUEUE_CONTEXT`), active DMA mapping,
mapping-relative offset, image, and `ready` flag.

Tests first establish RED for:

- full order `payload write -> queue/context write -> DMA barrier -> MMIO
  barrier -> MMIO write`, observed through one shared mock trace;
- MMIO address `binding.notify_base + desc.relative_offset` and exact payload;
- preflight rejection with zero side effects for inactive/stale binding,
  Function-handle mismatch, target UID/generation mismatch, wrong BAR,
  overflow/out-of-window address, width/endian/offset mismatch, unready or
  duplicate dependency, cross-Function/inactive/out-of-range/non-readable
  mapping, illegal merge, and unsupported readback;
- stop-on-first-failure for each host write and each barrier/MMIO call;
- same Function submissions cannot overlap, while a blocked Function A does
  not prevent Function B from reaching its barrier.

Run on 53:

```bash
scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
```

Expected RED: VCS compilation fails because `rdma_doorbell_scheduler` is
undefined.

- [ ] **Step 8: Implement the scheduler minimally**

Perform only the null/identity checks needed to derive the lock key, then
acquire one semaphore keyed by immutable Function UID plus Function object ID.
Perform the complete binding, descriptor, payload-image, and dependency
preflight under that lock before mutating external state. Hold the lock through
the final MMIO result. Do not use generation in the lock key, so
teardown/rebind cannot overlap the prior generation.

Preflight all dependency mappings and image ranges before the first write.
Then write all `PAYLOAD` entries in caller order, followed by all
`QUEUE_CONTEXT` entries in caller order. Stop immediately on any adapter
failure. Apply enabled barriers in fixed DMA-then-MMIO order and issue one
final `pcie_api.mmio_write()` using the Function handle and absolute address.
Publish `result` only after success; leave it null on every failure.

`rdma_core_pkg.sv` imports `rdma_adapter_pkg` and includes the scheduler.
Reorder both simulation filelists to compile adapter before core. The mock
trace is observational only and must not be required by production classes.

Run:

```bash
scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
scripts/run_vcs53.sh core rdma_xtr_v1_doorbell_codec_test
```

Expected GREEN: both pass with the exact ordering and zero UVM warnings,
errors, and fatals.

- [ ] **Step 9: Commit the scheduler layer**

```bash
git add src/core/rdma_doorbell_scheduler.svh src/core/rdma_core_pkg.sv \
  sim/filelists/core.f sim/filelists/host_mem.f \
  tests/mocks/rdma_mock_adapters.svh tests/rdma_unit_test_pkg.sv \
  tests/unit/rdma_doorbell_scheduler_test.svh
git commit -m "feat: schedule ordered RDMA doorbells"
```

- [ ] **Step 10: Run focused and full regression**

```bash
python3 -m unittest discover -s tests/unit -p 'test_*.py'
scripts/run_vcs53.sh xtr_defs check
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
scripts/run_vcs53.sh core rdma_xtr_v1_doorbell_codec_test
scripts/run_vcs53.sh core rdma_doorbell_scheduler_test
scripts/run_vcs53.sh core regression
```

Expected: every command passes; every VCS log has zero UVM warnings, errors,
and fatals. Confirm `git diff --check` and a clean worktree after commits.

- [ ] **Step 11: Audit scope and evidence**

Verify no PCIe environment, host memory implementation, DUT state model,
CMQ engine, SQE engine, or external VIP was copied into core. Verify TQ flush
appears only as CMQ opcode/body behavior and TX flush appears as the MMIO
doorbell kind. Record the base/head SHAs and all verification output for spec
and quality reviewers.
