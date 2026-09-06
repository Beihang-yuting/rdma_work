# RDMA 0.1.34 Gap Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐 RDMA driver 0.1.34 的主要 codec、queue、ABI、host-mem、CMQ 缺口，并通过可选 adapter 把 `net_packet` 接入 RC/UD/URC 报文生成与解析。

**Architecture:** RDMA core 继续只依赖抽象 adapter 和 `dpu_common` snapshot；CQE、SQE/WQE、ABI/host-mem、CMQ 和 net_packet 分成边界清晰、可单独验证的任务。`rdma_net_packet_adapter` 位于 adapter 层，将 `rdma_packet` 值快照转换为外部 `packet`，通过注入 sink 连接 AXIS/PCIe/DUT，不在 core 创建外部环境。

**Tech Stack:** SystemVerilog、UVM 1.2、Synopsys VCS、GNU Make、Bash、Python checker；外部 `net_packet` 固定提交 `6766c4f042484814548481065328ffbcffab590f`（该提交实际包含 `src/core/packet.sv` 及 RDMA 协议头）。

**Spec:** `docs/superpowers/specs/2026-09-05-rdma-driver-gap-closure-design.md`

## Global Constraints

- `dpu_common` 是 Host/PF/VF/BDF/BAR/global Function ID/topology 的唯一权威，RDMA 只消费 snapshot。
- 外部 PCIe、host-mem、AXIS VIP、net_packet 的对象由外部环境拥有；RDMA 适配器不复制或释放外部对象。
- 普通源码和测试使用 `.sv`；`.svh` 只用于宏或固定 mask 文本包含。
- 新增或触及的文件必须从文件头开始写中文目录/职责/依赖/所有权说明；每个函数和 task 必须有紧邻的中文“功能 / 输入输出及副作用 / 失败边界”说明。
- 所有 VCS 仿真必须通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。
- 每个任务遵循 TDD：先写失败测试并确认失败，再写最小实现，最后在本机静态检查和 53 上回归。

---

### Task 1: 修正回归分层与 0.1.34 基线

**Files:**
- Modify: `scripts/run_queue_lifecycle_regression53.sh`
- Modify: `sim/Makefile`
- Modify: `sim/filelists/core.f`
- Create: `sim/filelists/net_packet.f`
- Test: `tests/unit/test_check_queue_lifecycle.py`

**Interfaces:**
- Consumes: 现有 `rdma_unit_test_pkg`、`DPU_COMMON_ROOT`、`NET_PACKET_ROOT` 环境变量。
- Produces: `make core` 只编译 core 测试；`make integration` 编译 integration 测试；`make net_packet` 在依赖存在且 hash 正确时编译 net_packet adapter 测试；`RDMA_ARCHIVE_PREFIX` 更新为 `dpu_kernel_rdma-version_0.1.34`。

- [ ] **Step 1: Write the failing test**

```python
def test_core_regression_does_not_include_integration_only_tests():
    text = Path("scripts/run_queue_lifecycle_regression53.sh").read_text()
    core_tests = text.split("CORE_TESTS=(", 1)[1].split(")", 1)[0]
    assert "rdma_dpu_integration_test" not in core_tests
    assert "rdma_queue_lifecycle_test" in core_tests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/unit/test_check_queue_lifecycle.py -q`

Expected: FAIL because integration-only tests are currently listed in the core regression path.

- [ ] **Step 3: Write minimal implementation**

Move integration-only names into an `INTEGRATION_TESTS` array, add `net_packet` to the Makefile phony targets, require `NET_PACKET_ROOT/src/core/packet.sv` and the pinned commit/hash in a preflight, and set `RDMA_ARCHIVE_PREFIX` to `dpu_kernel_rdma-version_0.1.34`. Keep `core.f` free of integration and external net_packet files.

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/unit/test_check_queue_lifecycle.py -q && git diff --check`

Expected: PASS and no whitespace errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/run_queue_lifecycle_regression53.sh sim/Makefile sim/filelists/core.f sim/filelists/net_packet.f tests/unit/test_check_queue_lifecycle.py
git commit -m "test: separate core integration and net packet regressions"
```

### Task 2: CQE 32/64/128B codec 与 CQ layout

**Files:**
- Modify: `src/types/rdma_defs.sv`
- Modify: `src/codec/rdma/rdma_queue_codecs.sv`
- Modify: `src/core/rdma_queue_data_engine.sv`
- Modify: `src/core/rdma_cq_engine.sv`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Test: `tests/unit/rdma_cqe_size_codec_test.sv`
- Test: `tests/unit/rdma_cq_engine_resize_test.sv`

**Interfaces:**
- Consumes: `rdma_hw_image`, current CQ ring runtime and `rdma_doorbell_scheduler`。
- Produces: `rdma_cqe_size_e` (`RDMA_CQE_32B/64B/128B`), `rdma_cqe_layout` with `header_offset`, `rdma_queue_codec::encode_cqe()`/`decode_cqe()`, `rdma_cq_engine::resize()` and shared-CQ/URC shadow flush results。

- [ ] **Step 1: Write the failing test**

```systemverilog
task automatic test_cqe_sizes_round_trip();
  int unsigned sizes[3] = '{32, 64, 128};
  foreach (sizes[i]) begin
    rdma_cqe_layout layout = rdma_cqe_layout::for_bytes(sizes[i], 16);
    rdma_cqe_fields source = make_cqe_fields(32'h1234, 24'h56789a, 1'b1);
    byte unsigned image[$];
    rdma_cqe_fields decoded;
    if (rdma_queue_codec::encode_cqe(source, layout, image) != RDMA_SC_OK)
      `uvm_fatal("CQE_RED", "encode failed")
    if (rdma_queue_codec::decode_cqe(image, layout, decoded) != RDMA_SC_OK ||
        decoded.qpn != source.qpn || decoded.wr_id != source.wr_id)
      `uvm_error("CQE_ROUNDTRIP", "CQE size/layout round trip failed")
  end
endtask
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`

Expected: FAIL because CQE is restricted to 64 bytes and has no layout/header offset API.

- [ ] **Step 3: Write minimal implementation**

Add a size enum and checked layout constructor. Encode only fields valid for the selected profile, zero-fill reserved bytes, and reject images whose length or header offset is not aligned to the profile. Update the data engine to use the runtime CQE size instead of comparing against `RDMA_CQE_BYTES == 64`. Add resize as quiesce → allocate new ring → copy owner/CI state → activate; on allocation or validation failure keep the old ring unchanged.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/run_vcs53.sh core rdma_cqe_size_codec_test && scripts/run_vcs53.sh core rdma_cq_engine_resize_test`

Expected: both tests PASS with zero UVM warnings/errors/fatals.

- [ ] **Step 5: Commit**

```bash
git add src/types/rdma_defs.sv src/codec/rdma/rdma_queue_codecs.sv src/core/rdma_queue_data_engine.sv src/core/rdma_cq_engine.sv src/codec/rdma_codec_pkg.sv tests/unit/rdma_cqe_size_codec_test.sv tests/unit/rdma_cq_engine_resize_test.sv
git commit -m "feat: support variable size CQE layouts"
```

### Task 3: CQ shared/URC shadow、flush 与生命周期

**Files:**
- Modify: `src/model/rdma_context_models.sv`
- Modify: `src/model/rdma_queue_txn_types.sv`
- Modify: `src/core/rdma_cq_engine.sv`
- Modify: `src/core/rdma_queue_data_engine.sv`
- Test: `tests/unit/rdma_cq_shadow_flush_test.sv`

**Interfaces:**
- Consumes: Task 2 的 `rdma_cqe_layout`、queue runtime 和 function snapshot。
- Produces: `rdma_cq_shadow_snapshot`、`rdma_cq_engine::flush_shadow()`、`rdma_cq_engine::configure_shared()`，并将 URC 的 SQ CI/RQ CI/arm state/sequence 纳入可恢复事务证据。

- [ ] **Step 1: Write the failing test**

```systemverilog
task automatic test_shared_urc_shadow_flush_is_exactly_once();
  rdma_cq_engine cq = make_urc_shared_cq();
  rdma_cq_shadow_snapshot shadow;
  expect_status(cq.flush_shadow(shadow), RDMA_SC_OK);
  expect_status(cq.flush_shadow(shadow), RDMA_SC_OK);
  if (cq.shadow_flush_count != 1 || shadow.sq_ci != 12 || shadow.rq_ci != 9)
    `uvm_error("CQ_SHADOW", "URC shadow flush is not idempotent")
endtask
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/run_vcs53.sh core rdma_cq_shadow_flush_test`

Expected: FAIL because shared/URC shadow fields and idempotent flush are absent.

- [ ] **Step 3: Write minimal implementation**

Store shadow fields with the same function/generation/epoch authority as the CQ. `flush_shadow()` snapshots and clears only once per active epoch; stale or cross-function snapshots return `RDMA_SC_STALE_GENERATION` without clearing state. Shared CQ configuration must require a valid completion QP handle for URC and reject mismatched Function authority.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/run_vcs53.sh core rdma_cq_shadow_flush_test`

Expected: PASS with exactly one shadow flush.

- [ ] **Step 5: Commit**

```bash
git add src/model/rdma_context_models.sv src/model/rdma_queue_txn_types.sv src/core/rdma_cq_engine.sv src/core/rdma_queue_data_engine.sv tests/unit/rdma_cq_shadow_flush_test.sv
git commit -m "feat: add shared cq and urc shadow lifecycle"
```

### Task 4: UD/URC SQE 与新增 WQE 语义

**Files:**
- Modify: `src/codec/rdma/rdma_queue_codecs.sv`
- Modify: `src/model/rdma_semantic_requests.sv`
- Modify: `src/core/rdma_sq_engine.sv`
- Modify: `src/core/rdma_rq_engine.sv`
- Modify: `src/core/rdma_queue_data_engine.sv`
- Test: `tests/unit/rdma_ud_urc_sqe_codec_test.sv`
- Test: `tests/unit/rdma_wqe_extended_opcode_test.sv`

**Interfaces:**
- Consumes: current SQ/RQ request models, host-mem SGE mappings and Task 2 CQE layout。
- Produces: non-empty UD/URC SQE codecs; typed request fields for `SEND_WITH_INV`, `REG_MR`, `BIND_MW`, `FLUSH`; `rdma_sq_engine::validate_transport()` and checked FWQE-SGB segmentation。

- [ ] **Step 1: Write the failing test**

```systemverilog
task automatic test_ud_sqe_and_send_with_inv_encode();
  rdma_send_request request = make_ud_send_with_inv_request();
  byte unsigned image[$];
  expect_status(rdma_queue_codec::encode_sqe(request, image), RDMA_SC_OK);
  if (image.size() == 0 || image[0] != 8'h17 || !contains_be32(image, request.invalidate_rkey))
    `uvm_error("SQE_RED", "UD SEND_WITH_INV codec did not encode opcode/IETH")
endtask
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/run_vcs53.sh core rdma_ud_urc_sqe_codec_test`

Expected: FAIL because UD/URC codec is currently a shell and extended WQE fields are missing.

- [ ] **Step 3: Write minimal implementation**

Map transport/opcode to the driver-defined opcode table, validate that UD has destination QPN/Q_Key and URC has completion QP, and reject RC-only fields on UD. Encode direct, inline and SGB payloads with checked 512-byte FWQE-SGB boundaries. `REG_MR`, `BIND_MW` and `FLUSH` must carry explicit MR/MW handle authority and never advance PI before host-mem writes complete.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/run_vcs53.sh core rdma_ud_urc_sqe_codec_test && scripts/run_vcs53.sh core rdma_wqe_extended_opcode_test`

Expected: PASS with invalid transport/opcode combinations rejected.

- [ ] **Step 5: Commit**

```bash
git add src/codec/rdma/rdma_queue_codecs.sv src/model/rdma_semantic_requests.sv src/core/rdma_sq_engine.sv src/core/rdma_rq_engine.sv src/core/rdma_queue_data_engine.sv tests/unit/rdma_ud_urc_sqe_codec_test.sv tests/unit/rdma_wqe_extended_opcode_test.sv
git commit -m "feat: implement ud urc and extended wqe semantics"
```

### Task 5: net_packet 报文生成/解析 adapter

**Files:**
- Create: `src/adapters/net_packet/rdma_net_packet_adapter_pkg.sv`
- Create: `src/adapters/net_packet/rdma_net_packet_bridge.sv`
- Modify: `src/adapter/rdma_adapter_pkg.sv`
- Create: `sim/filelists/net_packet.f`
- Modify: `sim/Makefile`
- Create: `tests/integration/rdma_net_packet_adapter_test.sv`

**Interfaces:**
- Consumes: `rdma_net_api`、`rdma_packet`、`rdma_net_response_policy`、`rdma_net_fault`、dpu_common Function snapshot，以及外部 `packet`/`rocev2_bth`/`iwarp_header` 类。
- Produces: `rdma_net_packet_adapter`（`send_packet`、`receive_packet`、`register_observer`、`configure_response_policy`、`inject_fault`）；`rdma_net_packet_sink` 的 `send(packet pkt, output rdma_status status)` 和 `receive(output packet pkt, output rdma_status status)`；`make net_packet TEST=rdma_net_packet_adapter_test`。

- [x] **Step 1: Write the failing test**

```systemverilog
task automatic test_rocev2_rc_send_round_trip();
  rdma_net_packet_adapter adapter = make_adapter_with_sink();
  rdma_packet tx = make_rc_packet(24'h12345, 24'h45678, 24'h000011);
  rdma_status status;
  adapter.send_packet(tx, status);
  if (status.code != RDMA_SC_OK || sink.sent_count != 1 ||
      sink.last_raw.size() < 64 || !sink.last_packet_has_rocev2)
    `uvm_error("NET_PACKET_RED", "RoCEv2 packet was not generated")
endtask
```

- [x] **Step 2: Run test to verify it fails**

Run: `NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  scripts/run_vcs53.sh net_packet rdma_net_packet_adapter_test`

Expected: FAIL because the adapter package, filelist and Makefile target do not exist.

- [x] **Step 3: Write minimal implementation**

Compile the external `net_packet` filelist before the adapter bridge. Build Ethernet + IPv4/IPv6 + UDP + RoCEv2 layers for RC/UD; fill BTH/RETH/AETH/DETH/IETH from `rdma_packet` metadata and payload, call `do_pack()`, then publish a value snapshot to the sink. For iWARP use the iWARP layer and preserve raw bytes. Apply drop/corrupt/delay only in the adapter after Function/generation/epoch validation. Receive parses `raw_data`, validates checksum/ICRC and converts to `rdma_packet`; no PI/CI or CQE state is changed here.

- [x] **Step 4: Run test to verify it passes**

Run: `NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f \
  scripts/run_vcs53.sh net_packet rdma_net_packet_adapter_test`

Expected: PASS for RC SEND, RC WRITE, UD SEND, iWARP and drop/corrupt/delay cases with zero UVM warnings/errors/fatals.

- [x] **Step 5: Commit**

```bash
git add src/adapters/net_packet src/adapter/rdma_adapter_pkg.sv sim/filelists/net_packet.f sim/Makefile tests/integration/rdma_net_packet_adapter_test.sv
git commit -m "feat: integrate net packet generator adapter"
```

### Task 6: ABI v5 adapter 与 mmap 生命周期

**Files:**
- Modify: `src/adapter/rdma_context_backing_api.sv`
- Modify: `src/adapter/rdma_host_mem_api.sv`
- Create: `src/adapter/rdma_abi_v5_api.sv`
- Modify: `src/model/rdma_context_models.sv`
- Test: `tests/unit/rdma_abi_v5_adapter_test.sv`

**Interfaces:**
- Consumes: function binding snapshot、queue backing descriptors、host-mem mapping API。
- Produces: `rdma_abi_v5_request/response`、`rdma_abi_v5_api::negotiate()`、`alloc_context()`、`map_region()`、`unmap_region()`，覆盖 context、8 KiB DB、QP/CQ/SRQ/shadow/FWQE-SGB mmap。

- [ ] **Step 1: Write the failing test**

```systemverilog
task automatic test_abi_v5_negotiation_and_refcount();
  rdma_abi_v5_api abi = new("abi");
  rdma_abi_v5_response response;
  expect_status(abi.negotiate(5, response), RDMA_SC_OK);
  expect_status(abi.map_region(RDMA_ABI_REGION_DOORBELL, 8192, response), RDMA_SC_OK);
  expect_status(abi.unmap_region(response.mapping_id), RDMA_SC_OK);
  expect_status(abi.unmap_region(response.mapping_id), RDMA_SC_OK);
  if (abi.release_count != 1) `uvm_error("ABI_REF", "mapping release was not exactly once")
endtask
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/run_vcs53.sh core rdma_abi_v5_adapter_test`

Expected: FAIL because no ABI v5 request/response or mmap descriptor exists.

- [ ] **Step 3: Write minimal implementation**

Define fixed ABI v5 version, region kind, length, user VA, IOVA, Function snapshot, generation and reference count. Reject unsupported versions, zero/unaligned sizes, stale snapshots and duplicate unmaps. `unmap_region()` is idempotent for the same mapping ID and never releases a borrowed host-mem mapping.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/run_vcs53.sh core rdma_abi_v5_adapter_test`

Expected: PASS with version mismatch, stale generation and duplicate unmap cases covered.

- [ ] **Step 5: Commit**

```bash
git add src/adapter/rdma_abi_v5_api.sv src/adapter/rdma_context_backing_api.sv src/adapter/rdma_host_mem_api.sv src/model/rdma_context_models.sv tests/unit/rdma_abi_v5_adapter_test.sv
git commit -m "feat: add rdma userspace abi v5 adapter"
```

### Task 7: UMEM、page pin/refcount、多级 PBL 与 MW

**Files:**
- Modify: `src/model/rdma_dma_mapping.sv`
- Modify: `src/model/rdma_context_models.sv`
- Modify: `src/adapter/rdma_host_mem_api.sv`
- Modify: `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv`
- Test: `tests/unit/rdma_umem_pbl_mw_test.sv`
- Test: `tests/integration/rdma_host_mem_umem_test.sv`

**Interfaces:**
- Consumes: Task 6 ABI mapping descriptors、existing host-mem allocator and PBL codec。
- Produces: `rdma_umem` (`pin_pages`/`unpin_pages`)、`rdma_pbl_builder::build_multilevel()`、`rdma_mw_binding` (`bind`/`invalidate`)；owned/borrowed mapping exactly-once lifecycle。

- [ ] **Step 1: Write the failing test**

```systemverilog
task automatic test_multilevel_pbl_and_mw_invalidate();
  rdma_umem umem = make_umem(2*1024*1024);
  rdma_pbl pbl;
  expect_status(umem.pin_pages(), RDMA_SC_OK);
  expect_status(rdma_pbl_builder::build_multilevel(umem, pbl), RDMA_SC_OK);
  rdma_mw_binding mw = make_mw();
  expect_status(mw.bind(umem, pbl), RDMA_SC_OK);
  expect_status(mw.invalidate(), RDMA_SC_OK);
  expect_status(mw.invalidate(), RDMA_SC_OK);
  if (umem.pin_count != 1 || umem.unpin_count != 1) `uvm_error("UMEM_REF", "UMEM refcount drift")
endtask
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/run_vcs53.sh core rdma_umem_pbl_mw_test`

Expected: FAIL because page pin/refcount, multilevel PBL and MW binding are not represented.

- [ ] **Step 3: Write minimal implementation**

Represent each pinned page with host VA, IOVA, length, permissions and generation. Build a checked multi-level directory with no page crossing beyond the configured page size, and encode directory IOVAs into MR context. MW bind validates MR authority and access rights; invalidate is idempotent and blocks subsequent DMA. Adapter release order is MW → PBL → UMEM, while borrowed pages are detached without unpin.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/run_vcs53.sh core rdma_umem_pbl_mw_test && HOST_MEM_ROOT=/home/ubuntu/workspace/rdma_deps/host_mem scripts/run_vcs53.sh host_mem rdma_host_mem_umem_test`

Expected: PASS and exactly-once pin/unpin evidence.

- [ ] **Step 5: Commit**

```bash
git add src/model/rdma_dma_mapping.sv src/model/rdma_context_models.sv src/adapter/rdma_host_mem_api.sv src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv tests/unit/rdma_umem_pbl_mw_test.sv tests/integration/rdma_host_mem_umem_test.sv
git commit -m "feat: model umem multilevel pbl and mw lifecycle"
```

### Task 8: CMQ 0.1.34 opcode registry 与 golden vectors

**Files:**
- Modify: `src/codec/rdma/rdma_cmq_codecs.sv`
- Modify: `src/codec/rdma/rdma_cmq_profile.sv`
- Modify: `src/types/rdma_enum_types.sv`
- Modify: `tests/unit/rdma_cmq_codec_test.sv`
- Modify: `tests/unit/rdma_cmq_profile_test.sv`
- Modify: `tools/check_rdma_profile_names.py`
- Modify: `sim/Makefile`
- Create: `tests/data/rdma_0_1_34_cmq_vectors.hex`

**Interfaces:**
- Consumes: 0.1.34 `cmq.h`/`defs.h`/`qp.h`/`cq.h` values and current codec registry。
- Produces: complete supported-opcode registry including MW, key query, SD, source-address, stat, force-delete, IDX_OCC, IFA and kickout; unknown opcode returns `RDMA_SC_UNSUPPORTED_OPCODE` without mutating the ring。

- [ ] **Step 1: Write the failing test**

```systemverilog
task automatic test_driver_034_opcode_registry_is_complete();
  foreach (driver_034_new_opcodes[i]) begin
    if (!rdma_cmq_codec_registry::is_supported(driver_034_new_opcodes[i]))
      `uvm_error("CMQ_REGISTRY", $sformatf("missing opcode %0h", driver_034_new_opcodes[i]))
  end
endtask
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/run_vcs53.sh core rdma_cmq_codec_test`

Expected: FAIL for the currently unregistered 0.1.34 opcodes.

- [ ] **Step 3: Write minimal implementation**

Add each opcode with explicit request/response payload length, allowed mask, completion payload slice and error mapping. Keep registry entries data-driven so encode/decode uses the same length and reserved-bit rules. Update the checker manifest to 0.1.34 SHA-256 values and add vectors for every newly registered command.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/run_vcs53.sh core rdma_cmq_codec_test && make -C sim rdma_defs`

Expected: PASS, with checker reporting zero field/value/hash mismatches against the pinned 0.1.34 archive.

- [ ] **Step 5: Commit**

```bash
git add src/codec/rdma/rdma_cmq_codecs.sv src/codec/rdma/rdma_cmq_profile.sv src/types/rdma_enum_types.sv tests/unit/rdma_cmq_codec_test.sv tests/unit/rdma_cmq_profile_test.sv tools/check_rdma_profile_names.py sim/Makefile tests/data/rdma_0_1_34_cmq_vectors.hex
git commit -m "feat: register rdma driver 0.1.34 cmq opcodes"
```

### Task 9: 全量集成回归与文档审查

**Files:**
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `scripts/run_queue_lifecycle_regression53.sh`
- Modify: `README.md`
- Create: `docs/rdma-0.1.34-gap-closure-verification.md`

**Interfaces:**
- Consumes: Tasks 1–8 的测试、adapter target 和外部依赖路径。
- Produces: core、integration、host_mem、net_packet、axis_vip 的可重复命令矩阵，中文注释/文件职责检查通过，UVM warning/error/fatal 为 0。

- [ ] **Step 1: Write the failing test**

```python
def test_all_new_sources_have_chinese_header_and_function_contracts():
    for path in Path("src").rglob("*.sv"):
        text = path.read_text()
        if "rdma_net_packet" in path.name or "abi_v5" in path.name:
            assert "目录：" in text and "功能：" in text and "失败/边界：" in text
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/unit/test_check_queue_lifecycle.py -q`

Expected: FAIL until all newly added source files and functions have concrete Chinese comments.

- [ ] **Step 3: Write minimal implementation**

Register new tests under the correct `ifdef` blocks, document external dependency setup and pin hashes, and review every touched source file from its header through all functions. Remove integration-only names from core lists and ensure no core file contains `net_packet`, `axis_vip`, `pcie_work` or `host_mem_manager` symbols.

- [ ] **Step 4: Run test to verify it passes**

Run on 53:

```bash
scripts/run_vcs53.sh core regression
scripts/run_vcs53.sh integration regression
HOST_MEM_ROOT=/home/ubuntu/workspace/rdma_deps/host_mem-3b9e000 scripts/run_vcs53.sh host_mem regression
NET_PACKET_ROOT=/home/ubuntu/workspace/rdma_deps/net_packet-6766c4f scripts/run_vcs53.sh net_packet regression
```

Expected: all suites compile and finish with zero UVM warnings/errors/fatals; static checker and `git diff --check` are clean.

- [ ] **Step 5: Commit**

```bash
git add tests/rdma_unit_test_pkg.sv scripts/run_queue_lifecycle_regression53.sh README.md docs/rdma-0.1.34-gap-closure-verification.md
git commit -m "test: verify rdma 0.1.34 gap closure"
```

## Execution Order and Review Gates

Execute Tasks 1–3 first because queue layout and regression boundaries are prerequisites for
the remaining tests. Execute Task 4 next, then Task 5 (net_packet) once SQE semantics are
stable. Tasks 6–8 may proceed independently after the queue contracts are frozen, but their
integration checks must use the same Function snapshot and reset epoch rules. Task 9 is the
final gate and must not be marked complete until every VCS command has run on host 53.
