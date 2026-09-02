# RDMA XTR v1 Queue Data Codecs and Host-Memory Submitter

**Date:** 2026-09-02  
**Status:** Draft for review  
**Scope:** SQE/RQE/CQE/CEQE/AEQE data images and a host-memory submission/readback adapter.  This specification deliberately does not implement queue engines, ring credit accounting, PI/CI advancement, or doorbell scheduling.

## Goals

The next data-plane layer must make queue entries deterministic, auditable, and usable by a later SQ/RQ/CQ engine.  It has two responsibilities:

1. Encode and decode the five fixed XTR v1 queue-entry formats using the existing `rdma_codec_base`, qword builder, registry, and frozen field definitions.
2. Reserve an API that submits those images through the real `rdma_host_mem_api`, including allocation, DMA-identity checks, host-memory write, immediate readback, completion read/decode, and exactly-once release.

The implementation must preserve the frozen XTR v1 ABI, opcode values, masks, CMQ envelope, endian convention, and pinned external host-memory adapter.  Public request objects must not add or expose a raw host CPU backing address as a submission capability.

## Non-goals and boundaries

This change does not create an SQ, RQ, CQ, CEQ, or AEQ engine.  In particular it does not own ring producer/consumer indices, credits, wrap progression, queue-full/empty policy, interrupt arming, or MMIO doorbells.  The submitter accepts an explicit byte offset and leaves slot selection to the future engine.

It does not change the generic semantic models' validation contract, the pinned host-memory source, or any frozen `xtr_v1_defs.svh` coordinate.  If a queue codec needs hardware-only metadata that is not present in a generic model, the metadata is carried by an XTR-v1-specific model subclass or a codec-side companion object; generic model fields are not reinterpreted.

## Existing contracts used

* `rdma_codec_base` supplies `encode`, `decode`, model/image validation, endian reporting, and optional serialized equality.
* `rdma_xtr_v1_qword_builder` authors logical qwords and serializes each qword in big-endian byte order.
* `rdma_codec_registry` provides canonical lookup keys of the form `xtr_v1|<image-kind>|<object>|<variant>|<opcode>` and rejects duplicate registrations.
* `rdma_hw_image` carries bytes, length, alignment, endian, image kind, hardware version, and function generation.
* `rdma_host_mem_api` provides `allocate(request_context, size, alignment, direction, mapping)`, `write(mapping, offset, data)`, `read(mapping, offset, size, data)`, and `release(mapping)`.
* `rdma_dma_mapping.check_access()` is authoritative for Function generation/identity, requester BDF, PASID, DMA domain, IOVA range, direction, and permissions.

## Codec architecture

Add `src/codec/xtr_v1/rdma_xtr_v1_queue_codecs.svh` and include it from `src/codec/rdma_codec_pkg.sv` after the qword/page helpers.  The file contains five codec families and their XTR-v1 model subclasses.  Each codec follows the same sequence:

1. Validate the concrete model and all hardware-only fields before creating an image.
2. Reset a qword builder to the exact fixed image size.
3. Write every admitted field once using the generated `XTR_V1_*_WORD_BYTE_OFFSET`, `_LSB`, and `_WIDTH` constants.
4. Leave reserved bits zero and serialize through the qword builder.
5. On decode, reject a wrong image kind, length, alignment, endian, hardware version, function generation, or non-zero reserved bits before publishing a model.

The codec must not use raw numeric offsets where a generated definition exists.  Field-overlap errors from the builder are codec errors.  `serialized_equal` compares canonical encoded bytes and does not silently ignore metadata or reserved-bit differences.

### Image profiles and registry keys

All queue images use `RDMA_ENDIAN_BIG`, hardware version `XTR_V1_HW_VERSION`, and the fixed alignment shown below.  `opcode` in the registry key is `8'h00` because the queue-entry opcode is a field inside the image, not a registry discriminator.

| Entry | Image kind | Size/alignment | Registry object/variant |
|---|---|---:|---|
| SQE | `RDMA_IMAGE_SQE` | 64 B / 64 B | `sqe/rc`, `sqe/ud`, `sqe/urc` |
| RQE | `RDMA_IMAGE_RQE` | 64 B / 64 B | `rqe/default` |
| CQE | `RDMA_IMAGE_CQE` | 64 B / 64 B | `cqe/default` |
| CEQE | `RDMA_IMAGE_CEQE` | 16 B / 16 B | `ceqe/default` |
| AEQE | `RDMA_IMAGE_AEQE` | 16 B / 16 B | `aeqe/default` |

Registration is idempotent only at the package bootstrap level: a second registration of an existing key remains an error, consistent with the registry contract.  Tests perform lookup by the exact keys above and also verify that unsupported variants do not fall through to a different transport.

### XTR-v1 model metadata

The generic queue models remain the semantic base.  Add registered XTR-v1 subclasses with hardware mirror fields and strict width validation:

* `rdma_xtr_v1_sqe_model extends rdma_sqe_model`: `qpn[20:0]`, `icos[2:0]`, `qp_sn[7:0]`, `dst_port[3:0]`, `index[14:0]`, `wrap`, `sign_en`, `se`, `fence[1:0]`, `ce[1:0]`, `valid`, `signature[7:0]`, and the transport-specific RC/UD/URC extension selected by the base `transport` field.  RC additionally maps `rkey[31:0]`, `remote_va[63:0]`, and `sge_num[7:0]`; RQE-style payload metadata is not inferred from host pointers.
* `rdma_xtr_v1_rqe_model extends rdma_rqe_model`: `qpn[23:0]`, `qp_sn[7:0]`, `opcode[3:0]`, `index[14:0]`, `wrap`, `valid`, `payload_len[31:0]`, `signature[7:0]`, and `sge_num[7:0]`.
* `rdma_xtr_v1_cqe_model extends rdma_cqe_model`: `qpn[17:0]`, `wqe_index[14:0]`, `wqe_wrap`, `rq_cqe`, `polarity`, `packet_opcode[7:0]`, `ecode[7:0]`, `payload_len[31:0]`, `immediate_data[31:0]`, and `signature[7:0]`.
* `rdma_xtr_v1_ceqe_model extends rdma_ceqe_model`: `qpn[20:0]`, `cqn[20:0]`, `ecode[7:0]`, `packet_opcode[7:0]`, `cq_pi[15:0]`, `cq_pi_wrap`, and `valid`.  The semantic CQ handle remains available for software ownership checks; its numeric ID must agree with `cqn` when present.
* `rdma_xtr_v1_aeqe_model extends rdma_aeqe_model`: `qpn[17:0]`, `qp_state[2:0]`, `ecode[7:0]`, `packet_opcode[7:0]`, `wqe_index[22:0]`, `wqe_wrap`, and `valid`.

Every subclass implements copy/clone, `validate`, and a concise `describe`.  Decode creates a fresh subclass and does not mutate a caller-provided object on failure.  Generic fields are mapped only where the frozen layout defines an unambiguous owner (for example CQE payload length and immediate data); `wr_id`, host pointers, and software handles are not serialized unless a field explicitly exists.

### Exact field ownership

The implementation uses the definitions already present near the queue section of `src/codec/xtr_v1/rdma_xtr_v1_defs.svh`:

* SQE qword 0 owns QPN, ICOS, QP SN, work opcode, destination port, WQE index, wrap, signature-enable, SE, fence, CE, and valid.  Qword 2 owns signature, SGE count, and RC remote key; qword 3 owns RC remote VA.  UD and URC extensions may only populate fields that have an existing frozen coordinate; unsupported extension data is rejected rather than packed opportunistically.
* RQE qword 0 owns QPN, QP SN, opcode, index, wrap, and valid; qword 1 owns payload length; qword 2 owns signature and SGE count.
* CQE qword 0 owns polarity, RQ-CQE, WQE wrap/index, packet opcode, ecode, and QPN; qword 1 owns payload length and immediate data; qword 2 owns signature.
* CEQE and AEQE each have two logical qwords.  CEQE uses qword 0 for valid/QPN/CQN/error/opcode and qword 1 for CQ PI/wrap.  AEQE uses qword 0 for valid/QP state/opcode/error/QPN and qword 1 for WQE wrap/index.

Reserved bits in every qword are required to be zero on encode and decode.  Error-code values are validated against the existing XTR v1 symbolic error-code table; an unknown hardware value is retained only through the existing error-code/status codec contract and never aliased to a work opcode.

## Host-memory submitter API

Add `src/adapter/rdma_xtr_v1_queue_host_mem_submitter.svh`, import `rdma_codec_pkg::*` in `rdma_adapter_pkg`, and include the new file from `src/adapter/rdma_adapter_pkg.sv` after the existing host-memory API include.  The codec package is compiled before the adapter package in the current file lists, so this dependency does not form a package cycle.  The public API is:

```systemverilog
class rdma_xtr_v1_queue_host_mem_target extends uvm_object;
  // Opaque capability: mapping and request identity are local/private fields.
endclass

class rdma_xtr_v1_queue_host_mem_submitter extends uvm_object;
  rdma_host_mem_api host_mem;       // injected real adapter, never fabricated
  rdma_codec_registry registry;     // injected/bootstrapped queue registry

  function rdma_status allocate_target(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_xtr_v1_queue_host_mem_target target
  );
  function rdma_status write_sqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    rdma_xtr_v1_sqe_model model,
    output rdma_hw_image image
  );
  function rdma_status write_rqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    rdma_xtr_v1_rqe_model model,
    output rdma_hw_image image
  );
  function rdma_status read_cqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_xtr_v1_cqe_model model,
    output rdma_hw_image image
  );
  function rdma_status read_ceqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_xtr_v1_ceqe_model model,
    output rdma_hw_image image
  );
  function rdma_status read_aeqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_xtr_v1_aeqe_model model,
    output rdma_hw_image image
  );
  function rdma_status release_target(
    rdma_xtr_v1_queue_host_mem_target target
  );
endclass
```

`read_ceqe` and `read_aeqe` have the same shape as `read_cqe`, with their concrete model and image outputs.  The target is intentionally opaque.  The submitter keeps the mapping, a private clone of the allocation request identity, and a release-authority snapshot in a private ledger keyed by the target capability; the target object itself exposes no mapping or backing CPU address.  The caller supplies only a target capability and a byte offset.

### Allocation and access rules

`allocate_target` validates the request context first, requires a non-null injected `host_mem`, and calls `host_mem.allocate` with the requested size, power-of-two alignment, and direction.  It rejects a null or malformed mapping, a stale Function generation, a zero-size allocation, an overflowing range, or an adapter result whose Function/BDF/PASID/domain identity does not match the request.  On any post-allocation failure it calls `host_mem.release` exactly once and does not return a target.

Each operation validates the target capability and computes `first_iova = mapping.iova + offset` only after checking offset/range overflow.  It then calls `mapping.check_access` with the target's saved Function identity, requester BDF, PASID, DMA domain, exact image length, and required permission:

* `write_sqe` and `write_rqe`: `RDMA_DMA_DEVICE_READ` plus `device_read` permission.
* `read_cqe`, `read_ceqe`, and `read_aeqe`: `RDMA_DMA_DEVICE_WRITE` plus `device_write` permission.

The operation is rejected if the mapping direction or permissions do not allow that access.  A target allocated bidirectionally may be used for both classes of operation; no implicit permission upgrade is performed.

### Write/readback transaction

`write_sqe`/`write_rqe` first encode into a detached image, validate that the image length and kind match the selected codec, and call `host_mem.write(mapping, offset, image.bytes)`.  They immediately call `host_mem.read` for the same range and compare every byte with the submitted image.  A short read, null data, or byte mismatch is an error and no submission record is published.  The output image is assigned only after the full transaction succeeds.

Completion reads perform the inverse transaction: read exactly 64/16 bytes, reject malformed bytes through the selected codec, decode into a fresh model, and publish both outputs only after successful validation.  No caller model is partially modified on a failed read or decode.

### Release and ownership

`release_target` is explicit and exactly-once.  It verifies the target's private release authority, calls `host_mem.release` once, and records completion only when the adapter reports success.  Releasing a null, foreign, already-released, or stale target returns an error without a second release call.  A failed release leaves the capability unreleased and returns the adapter status so the caller can retry or escalate; it never silently drops the mapping.  The submitter does not release targets in a destructor, because lifecycle ownership belongs to the caller/future queue engine.

## Error handling and atomicity

All methods return non-null `rdma_status`.  Argument, stale-generation, DMA translation, DMA permission, codec, and invalid-state errors use the existing status codes.  The implementation must preserve output atomicity: output handles, models, images, and targets remain null/unchanged until the complete operation succeeds.  A failed allocation path has exactly one release attempt for every successful underlying allocation.  No writer method records a submission before write and readback both pass.

## Testing strategy

Add unit coverage and register it in `tests/rdma_unit_test_pkg.sv`:

1. Five codec suites test golden vectors from `hw/xtr_v1/golden_vectors/queue.hex` (`sqe_rc_boundary`, `rqe_boundary`, `cqe_error`, `ceqe_error`, `aeqe_error`), encode/decode round trips, registry lookup, wrong length/endian/image kind, width overflow, reserved-bit rejection, invalid owner/wrap/polarity, and output atomicity.
2. Host-memory submitter tests inject the existing mock API for deterministic failures: allocation failure, malformed mapping, generation/BDF/PASID/domain mismatch, out-of-range offset, direction/permission denial, write failure, short/mismatched readback, malformed completion, duplicate release, foreign target, and exactly-once cleanup.
3. A real host-memory integration test uses the pinned adapter on VCS host `10.11.10.53` and verifies allocation, actual write, readback, CQE/CEQE/AEQE decode, and release.  The test must report `UVM_WARNING=0`, `UVM_ERROR=0`, and `UVM_FATAL=0`.
4. Existing full regression remains mandatory; no generated logs, wrappers, caches, or workflow reports are committed.

## File and integration impact

Expected source/test changes are limited to:

* new queue codec source and new submitter source;
* codec/adapter package include/import lines and registry bootstrap;
* XTR-v1 queue unit/integration tests and test-package registration;
* this design document, followed later by an implementation plan.

Frozen definitions, external host-memory implementation, unrelated queue lifecycle worktrees, and build artifacts remain untouched.

## Acceptance criteria

The design is ready for implementation when the reviewer agrees that (a) the five image profiles and field ownership match the frozen definitions/golden vectors, (b) the submitter really uses the injected `rdma_host_mem_api` and `check_access`, (c) allocation/release and output atomicity rules are testable, and (d) the scope stops before queue-engine behavior.
