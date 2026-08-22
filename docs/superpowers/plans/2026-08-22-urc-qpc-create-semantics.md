# URC QPC Create Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refreeze `qpc_urc_boundary` as a constructible create/modify image, add an explicit hardware-neutral URC queue configuration object, and make the parent Task 10C contract encode, decode, compare, and reject URC images without exposing runtime snapshots.

**Architecture:** `rdma_qpc_urc_ext` owns four canonical sequence values and one deep-copied `rdma_urc_queue_config`; the xtr_v1 codec derives all hardware mirrors and queue codes from those semantic owners. The independent Python reference encoder freezes the two omitted driver fields and a canonical URC create image, while runtime SRBSN fields remain outside both the model and create-image mask.

**Tech Stack:** SystemVerilog, UVM 1.2, Python 3 `unittest`, Markdown, Git, Synopsys VCS on `10.11.10.53`.

---

## Scope and execution contract

- Work only in `/home/ryan/workspace/ryan/rdma_work/.worktrees/rdma-uvm-driver` on branch `feat/rdma-uvm-driver`.
- The authoritative driver remains commit `491faf2ba42627fffd4dd027607299c8bb591ec2` from `/home/ubuntu/workspace/Desktop.zip` on `10.11.10.53`.
- This plan implements the two prerequisites defined by `docs/superpowers/specs/2026-08-22-urc-qpc-create-semantics-design.md` and reconciles the parent ABI documents. It does not create `rdma_xtr_v1_qpc_codecs.svh`; the revised parent Task 10C owns that implementation.
- Run Python unit tests locally. Run all SystemVerilog compile/simulation and fixed-driver checks through `scripts/run_vcs53.sh`; local compilation is not an acceptance result.
- If the runner needs password authentication, read it into the current shell and export only process-local wrappers:

```bash
read -rsp 'VCS53 password: ' SSHPASS
export SSHPASS
ssh() { /usr/bin/sshpass -e /usr/bin/ssh "$@"; }
export -f ssh
export RSYNC_RSH='/usr/bin/sshpass -e /usr/bin/ssh'
```

- Execute Tasks 1, 2, and 3 in order. Each task gets its own commit and review. Do not resume parent Task 10C until Task 4 passes from a clean staging directory.
- A RED run counts only when it fails for the intended missing field/member/contract. SSH, license, unrelated syntax, or stale staging failures do not count.
- Preserve RC and UD golden payloads byte-for-byte. `qpc_urc_boundary` is the only payload case re-frozen by this plan.

## File responsibility map

| File | Responsibility in this plan |
|---|---|
| `tools/check_xtr_v1_defs.py` | Parse the two omitted `qp.h` masks, hold independent reference coordinates, build the canonical URC create image, and validate semantic transforms. |
| `tests/unit/test_check_xtr_v1_defs.py` | Lock source/reference/SV-coordinate drift, canonical semantic inputs, mirrors, runtime-zero fields, queue codes, and RC/UD stability. |
| `src/codec/xtr_v1/rdma_xtr_v1_defs.svh` | Publish audited byte/LSB/width constants for RSQ size and RDSQ fetch count. |
| `hw/xtr_v1/golden_vectors/context.hex` | Store the independently generated canonical 512-byte URC create payload while leaving the other ten cases unchanged. |
| `tests/unit/rdma_xtr_v1_defs_test.svh` | Compile-time/runtime checks for the two new SV definitions. |
| `docs/hw/xtr-v1-source-map.md` | Explain canonical create semantics versus runtime fields and record both newly frozen coordinates. |
| `src/model/rdma_context_layouts.svh` | Define the reusable hardware-neutral `rdma_urc_queue_config` value object. |
| `src/model/rdma_context_models.svh` | Make the URC extension own and deep-copy queue configuration; perform common QPC threshold-topology checks. |
| `tests/unit/rdma_context_model_test.svh` | Lock queue defaults, copy isolation, description, validation, cross-depth limits, and device-neutral width behavior. |
| `tests/unit/rdma_request_model_test.svh` | Prove QPC and CMQ request clones preserve all URC create semantics without aliasing. |
| `docs/superpowers/specs/2026-08-21-xtr-v1-context-body-abi-design.md` | Replace stale URC ownership, golden, mirror, mask, equality, and error language. |
| `docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md` | Insert replay prerequisites and make Task 10C executable against the canonical URC model. |

### Task 1: Freeze the missing URC fields and canonical create golden

**Files:**
- Modify: `tests/unit/test_check_xtr_v1_defs.py`
- Modify: `tests/unit/rdma_xtr_v1_defs_test.svh`
- Modify: `tools/check_xtr_v1_defs.py`
- Modify: `src/codec/xtr_v1/rdma_xtr_v1_defs.svh`
- Modify: `hw/xtr_v1/golden_vectors/context.hex`
- Modify: `docs/hw/xtr-v1-source-map.md`

- [ ] **Step 1: Write failing Python definition and semantic-golden tests**

Add this helper and test to `ReferenceEncodingTest` in
`tests/unit/test_check_xtr_v1_defs.py`. It deliberately names model properties and
entry/byte-address units; hardware codes are checked only as derived payload values.

```python
    def test_urc_create_fields_and_semantic_golden_are_canonical(self) -> None:
        expected_coordinates = {
            "XTR_V1_QPC_URC_RSQ_SIZE":
                ("qp.h", "XTRDMA_QPC_URC_RSQ_SIZE", 24, 59, 3),
            "XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM":
                ("qp.h", "XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM", 224, 16, 6),
        }
        mappings = {
            mapping.sv_stem: (
                mapping.path, mapping.c_symbol, mapping.word_byte_offset
            )
            for mapping in CHECKER.FIELD_MAPPINGS
        }
        references = {
            reference.sv_stem: (
                reference.path, reference.c_symbol,
                reference.word_byte_offset, reference.lsb, reference.width
            )
            for reference in CHECKER.REFERENCE_FIELDS
        }
        constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/xtr_v1/rdma_xtr_v1_defs.svh").read_text()
        )

        for stem, expected in expected_coordinates.items():
            with self.subTest(stem=stem):
                self.assertEqual(mappings[stem], expected[:3])
                self.assertEqual(references[stem], expected)
                self.assertEqual(constants[f"{stem}_WORD_BYTE_OFFSET"], expected[2])
                self.assertEqual(constants[f"{stem}_LSB"], expected[3])
                self.assertEqual(constants[f"{stem}_WIDTH"], expected[4])
                self.assertEqual(
                    constants[f"{stem}_OFFSET"], expected[2] * 8 + expected[3]
                )

        urc = CHECKER.build_golden_cases()["context"][2]
        inputs = {item.name: item.value for item in urc.inputs}
        expected_semantics = {
            "transport": "urc",
            "remote_qpn": "0x654321",
            "rbsn": "0xabcdef",
            "dbsn": "0x654321",
            "rpsn": "0x56789a",
            "dpsn": "0x456789",
            "rsq_backing": "0x123456789abcd000",
            "rdsq_backing": "0x23456789abcde000",
            "dsq_backing": "0x3456789abcdef000",
            "rsq_depth": "64",
            "rdsq_depth": "64",
            "rdsq_fetch_count": "8",
            "dsq_fetch_count": "8",
            "rq_sequence_threshold_entries": "2048",
            "sq_completion_threshold_entries": "4096",
            "sq_depth": "32768",
            "rq_depth": "16384",
            "path_mtu_bytes": "8192",
        }
        for name, value in expected_semantics.items():
            with self.subTest(input=name):
                self.assertEqual(inputs[name], value)
        for legacy_name in (
            "tx_rbsn", "rx_rbsn", "tx_dbsn", "rx_dbsn", "rxed_dbsn",
            "rx_srbsn", "tx_srbsn", "max_tx_srbsn", "rdsq_size",
            "rq_se_th", "sq_ce_th", "dsq_fetch",
        ):
            self.assertNotIn(legacy_name, inputs)

        validate = CHECKER.validate_context_contract
        cases = CHECKER.build_golden_cases()["context"]
        for item in urc.inputs:
            with self.subTest(coupled_input=item.name):
                corrupted = list(cases)
                if item.name == "transport":
                    bad_urc = urc._replace(inputs=tuple(
                        CHECKER.GoldenInput(entry.name, "rc")
                        if entry.name == "transport" else entry
                        for entry in urc.inputs
                    ))
                else:
                    bad_urc = self.mutate_input(urc, item.name)
                corrupted[2] = bad_urc
                with self.assertRaises(CHECKER.ValidationError):
                    validate(corrupted)

        mirrors = {
            "rbsn": (
                "XTR_V1_QPC_URC_TX_RBSN", "XTR_V1_QPC_URC_RX_RBSN"
            ),
            "dbsn": (
                "XTR_V1_QPC_URC_TX_DBSN", "XTR_V1_QPC_URC_RX_DBSN",
                "XTR_V1_QPC_URC_RXED_DBSN",
            ),
            "rpsn": (
                "XTR_V1_QPC_URC_CUR_TX_RPSN",
                "XTR_V1_QPC_URC_TPE_RPSN_MAX",
            ),
            "dpsn": (
                "XTR_V1_QPC_URC_CUR_TX_DPSN",
                "XTR_V1_QPC_URC_TPE_DPSN_MAX",
            ),
        }
        for input_name, stems in mirrors.items():
            expected = int(inputs[input_name], 0)
            for stem in stems:
                self.assertEqual(self.field_value(urc, stem), expected)

        for stem in (
            "XTR_V1_QPC_URC_RX_SRBSN",
            "XTR_V1_QPC_URC_TX_SRBSN",
            "XTR_V1_QPC_URC_MAX_TX_SRBSN",
        ):
            self.assertEqual(self.field_value(urc, stem), 0)

        self.assertEqual(self.field_value(urc, "XTR_V1_QPC_DST_QPN"), 0x654321)
        self.assertEqual(self.field_value(urc, "XTR_V1_QPC_URC_RSQ_SIZE"), 6)
        self.assertEqual(self.field_value(urc, "XTR_V1_QPC_URC_RDSQ_SIZE"), 6)
        self.assertEqual(
            self.field_value(urc, "XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM"), 8
        )
        self.assertEqual(
            self.field_value(urc, "XTR_V1_QPC_URC_NXT_DSQ_FETCH_NUM"), 8
        )
        self.assertEqual(self.field_value(urc, "XTR_V1_QPC_URC_RQ_SE_TH"), 11)
        self.assertEqual(self.field_value(urc, "XTR_V1_QPC_URC_SQ_CE_TH"), 12)
        self.assertEqual(self.field_value(urc, "XTR_V1_QPC_SQ_SIZE"), 15)
        self.assertEqual(self.field_value(urc, "XTR_V1_QPC_RQ_SIZE"), 14)
        self.assertEqual(self.field_value(urc, "XTR_V1_QPC_PMTU"), 5)
```

Add a fail-closed drift test next to it. This reuses production validation rather
than duplicating a test-only checker:

```python
    def test_urc_create_field_source_reference_and_sv_drift_is_rejected(self) -> None:
        stems = (
            "XTR_V1_QPC_URC_RSQ_SIZE",
            "XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM",
        )
        references = tuple(
            reference for reference in CHECKER.REFERENCE_FIELDS
            if reference.sv_stem in stems
        )
        parsed_fields = {
            reference.sv_stem: (
                reference.path, reference.c_symbol,
                reference.lsb, reference.width,
            )
            for reference in references
        }
        CHECKER.validate_reference_fields(
            references, CHECKER.FIELD_MAPPINGS, parsed_fields
        )

        source_drift = dict(parsed_fields)
        first = references[0]
        source_drift[first.sv_stem] = (
            first.path, first.c_symbol, first.lsb + 1, first.width
        )
        with self.assertRaisesRegex(CHECKER.ValidationError, "reference mask"):
            CHECKER.validate_reference_fields(
                references, CHECKER.FIELD_MAPPINGS, source_drift
            )

        reference_drift = references[0]._replace(width=references[0].width - 1)
        with self.assertRaisesRegex(CHECKER.ValidationError, "reference mask"):
            CHECKER.validate_reference_fields(
                (reference_drift,) + references[1:],
                CHECKER.FIELD_MAPPINGS,
                parsed_fields,
            )

        constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/xtr_v1/rdma_xtr_v1_defs.svh").read_text()
        )
        expected = {
            f"{reference.sv_stem}_{suffix}": value
            for reference in references
            for suffix, value in (
                ("WORD_BYTE_OFFSET", reference.word_byte_offset),
                ("LSB", reference.lsb),
                ("WIDTH", reference.width),
                ("OFFSET", reference.word_byte_offset * 8 + reference.lsb),
            )
        }
        CHECKER.validate_required_sv_constants(constants, expected)
        drifted_constants = dict(constants)
        drifted_constants[f"{references[1].sv_stem}_LSB"] += 1
        with self.assertRaisesRegex(CHECKER.ValidationError, "SV constant"):
            CHECKER.validate_required_sv_constants(drifted_constants, expected)
```

At the start of the same test, capture the current RC and UD payloads before building
the expected URC case, and add these assertions after it so the narrow refreeze cannot
silently rewrite another transport:

```python
        cases = CHECKER.build_golden_cases()["context"]
        self.assertEqual(cases[0].payload[:8], bytes.fromhex("605abca15555a500"))
        self.assertEqual(cases[1].payload[:8], bytes.fromhex("4c6345a2aaaa5a89"))
```

- [ ] **Step 2: Write the failing SystemVerilog coordinate check**

Add the following condition in `rdma_xtr_v1_defs_test.run_phase()` immediately after
the existing representative QPC field check:

```systemverilog
    if (XTR_V1_QPC_URC_RSQ_SIZE_WORD_BYTE_OFFSET != 24 ||
        XTR_V1_QPC_URC_RSQ_SIZE_LSB != 59 ||
        XTR_V1_QPC_URC_RSQ_SIZE_WIDTH != 3 ||
        XTR_V1_QPC_URC_RSQ_SIZE_OFFSET != 251 ||
        XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM_WORD_BYTE_OFFSET != 224 ||
        XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM_LSB != 16 ||
        XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM_WIDTH != 6 ||
        XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM_OFFSET != 1808)
      `uvm_error("DEFS", "URC create prerequisite fields")
```

- [ ] **Step 3: Run RED locally and on the VCS host**

```bash
python3 -m unittest -v tests.unit.test_check_xtr_v1_defs
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
```

Expected: the Python suite fails because the new field mappings/constants and semantic
URC inputs do not exist. The VCS command fails at compile time on
`XTR_V1_QPC_URC_RSQ_SIZE_*` or `XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM_*`.

- [ ] **Step 4: Add the two driver-derived field definitions**

Add these exact rows to `FIELD_MAPPINGS` in `tools/check_xtr_v1_defs.py`:

```python
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RSQ_SIZE",
                 "XTR_V1_QPC_URC_RSQ_SIZE", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM",
                 "XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM", 224),
```

Add these independent rows to `REFERENCE_FIELDS`:

```python
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RSQ_SIZE",
                   "XTR_V1_QPC_URC_RSQ_SIZE", 24, 59, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM",
                   "XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM", 224, 16, 6),
```

Keep the three runtime-only SRBSN rows in both `FIELD_MAPPINGS` and
`REFERENCE_FIELDS`. They remain independent coordinate references and are written as
zero only by the Python golden builder; this does not add them to the codec's create
allowed mask.

Extract the existing required-constant loop into this helper and call it from
`validate()` for the complete `expected_constants` table:

```python
def validate_required_sv_constants(
    sv_constants: dict[str, int], expected_constants: dict[str, int]
) -> None:
    for name, expected in expected_constants.items():
        actual = sv_constants.get(name)
        if actual is None:
            raise ValidationError(f"required SV constant missing: {name}")
        if actual != expected:
            raise ValidationError(
                f"SV constant mismatch for {name}: {actual:#x} != {expected:#x}"
            )
```

```python
    validate_required_sv_constants(sv_constants, expected_constants)
```

Add the exact SV fields in `rdma_xtr_v1_defs.svh`, ordered by byte coordinate:

```systemverilog
`XTR_V1_FIELD(XTR_V1_QPC_URC_RSQ_SIZE, 24, 59, 3)
`XTR_V1_FIELD(XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM, 224, 16, 6)
```

- [ ] **Step 5: Replace the URC reference builder with semantic inputs**

In `build_golden_cases()`, replace the existing URC block with the following exact
construction. It preserves the existing common URC values unless this design assigns
a new canonical value, and it records zero-valued behavior/address-vector properties
explicitly as model input rather than relying on a transport default.

```python
    def semantic_input(name: str, value) -> tuple[str, int, str]:
        return ("", 0, f"{name}={value}")

    urc_traffic_class = 0xFE
    urc_rsq_page = 0x123456789ABCD
    urc_rdsq_page = 0x23456789ABCDE
    urc_dsq_page = 0x3456789ABCDEF
    urc_sq_page = 0x456789ABCDEF0
    urc_rq_page = 0x56789ABCDEF01
    urc_shadow_page = 0x123456789AB
    urc_rsq_depth = 64
    urc_rdsq_depth = 64
    urc_sq_depth = 32768
    urc_rq_depth = 16384
    urc_rq_threshold = 2048
    urc_sq_threshold = 4096
    urc_remote_qpn = 0x654321
    urc_rbsn = 0xABCDEF
    urc_dbsn = 0x654321
    urc_rpsn = 0x56789A
    urc_dpsn = 0x456789

    qpc_urc = make_case("qpc_urc_boundary", 512, (
        semantic_input("transport", "urc"),
        semantic_input("traffic_class", f"{urc_traffic_class:#x}"),
        semantic_input("transport_version", 1),
        semantic_input("migration_enable", 1),
        semantic_input("host_id", 7),
        semantic_input("vf_id", "0x789"),
        semantic_input("qpn", "0x3ffff"),
        semantic_input("stat_index", "0xff"),
        semantic_input("pkey", "0xabcd"),
        semantic_input("context_backing", f"{urc_shadow_page << 9:#x}"),
        semantic_input("tx_endian_swap", 0),
        semantic_input("rx_endian_swap", 0),
        semantic_input("signature_enable", 0),
        semantic_input("read_after_write_fence", 0),
        semantic_input("atomic_after_atomic_fence", 0),
        semantic_input("tx_flow_control", 0),
        semantic_input("rx_flow_control", 0),
        semantic_input("state", 3),
        semantic_input("path_mtu_bytes", 8192),
        semantic_input("qp_sequence", "0xfe"),
        semantic_input("pd_id", "0xffff"),
        semantic_input("access", 0),
        semantic_input("remote_qpn", f"{urc_remote_qpn:#x}"),
        semantic_input("vlan_enable", 0),
        semantic_input("ipv6", 0),
        semantic_input("tunnel_enable", 0),
        semantic_input("lag_enable", 0),
        semantic_input("forwarding_enable", 0),
        semantic_input("destination_vport", 0),
        semantic_input("source_address_index", 0),
        semantic_input("destination_port", 0),
        semantic_input("destination_mac", 0),
        semantic_input("priority", 0),
        semantic_input("cfi", 0),
        semantic_input("vlan_id", 0),
        semantic_input("source_vport", 0),
        semantic_input("flow_label", 0),
        semantic_input("hop_limit", 0),
        semantic_input("udp_source_port", 0),
        semantic_input("destination_ip", "00000000000000000000000000000000"),
        semantic_input("rbsn", f"{urc_rbsn:#x}"),
        semantic_input("dbsn", f"{urc_dbsn:#x}"),
        semantic_input("rpsn", f"{urc_rpsn:#x}"),
        semantic_input("dpsn", f"{urc_dpsn:#x}"),
        semantic_input("rsq_backing", f"{urc_rsq_page << 12:#x}"),
        semantic_input("rdsq_backing", f"{urc_rdsq_page << 12:#x}"),
        semantic_input("dsq_backing", f"{urc_dsq_page << 12:#x}"),
        semantic_input("rsq_depth", urc_rsq_depth),
        semantic_input("rdsq_depth", urc_rdsq_depth),
        semantic_input("rdsq_fetch_count", 8),
        semantic_input("dsq_fetch_count", 8),
        semantic_input("rq_sequence_threshold_entries", urc_rq_threshold),
        semantic_input("sq_completion_threshold_entries", urc_sq_threshold),
        semantic_input("sq_backing", f"{urc_sq_page << 12:#x}"),
        semantic_input("sq_depth", urc_sq_depth),
        semantic_input("sq_mode", 3),
        semantic_input("send_cq_id", "0xfffff"),
        semantic_input("recv_cq_id", "0xabcde"),
        semantic_input("rq_backing", f"{urc_rq_page << 12:#x}"),
        semantic_input("rq_depth", urc_rq_depth),
        semantic_input("rq_mode", 2),
        ("XTR_V1_QPC_TVER", 1, ""),
        ("XTR_V1_QPC_MIG", 1, ""),
        ("XTR_V1_QPC_SERVICE_TYPE", 6, ""),
        ("XTR_V1_QPC_HOST_ID", 7, ""),
        ("XTR_V1_QPC_VF_ID", 0x789, ""),
        ("XTR_V1_QPC_ICOS", urc_traffic_class >> 5, ""),
        ("XTR_V1_QPC_QPN", 0x3FFFF, ""),
        ("XTR_V1_QPC_STAT_IDX", 0xFF, ""),
        ("XTR_V1_QPC_URC_RSQ_PBA_H", urc_rsq_page >> 48, ""),
        ("XTR_V1_QPC_URC_RSQ_PBA_L", urc_rsq_page & ((1 << 48) - 1), ""),
        ("XTR_V1_QPC_PKEY", 0xABCD, ""),
        ("XTR_V1_QPC_SHADOW_PBA", urc_shadow_page, ""),
        ("XTR_V1_QPC_TX_ENDIAN_SWAP", 0, ""),
        ("XTR_V1_QPC_RX_ENDIAN_SWAP", 0, ""),
        ("XTR_V1_QPC_SQ_CE_EN", 0, ""),
        ("XTR_V1_QPC_RA_FENCE", 0, ""),
        ("XTR_V1_QPC_AA_FENCE", 0, ""),
        ("XTR_V1_QPC_FC_EN", 0, ""),
        ("XTR_V1_QPC_URC_RSQ_SIZE", urc_rsq_depth.bit_length() - 1, ""),
        ("XTR_V1_QPC_QP_ST", 3, ""),
        ("XTR_V1_QPC_PMTU", 5, ""),
        ("XTR_V1_QPC_QP_SN", 0xFE, ""),
        ("XTR_V1_QPC_PD_IDX", 0xFFFF, ""),
        ("XTR_V1_QPC_QP_ACCESS_FLAG", 0, ""),
        ("XTR_V1_QPC_URC_RDSQ_PBA", urc_rdsq_page, ""),
        ("XTR_V1_QPC_URC_RDSQ_SIZE", urc_rdsq_depth.bit_length() - 1, ""),
        ("XTR_V1_QPC_VLAN", 0, ""),
        ("XTR_V1_QPC_IPV6", 0, ""),
        ("XTR_V1_QPC_TUNNEL", 0, ""),
        ("XTR_V1_QPC_LAG", 0, ""),
        ("XTR_V1_QPC_FWD", 0, ""),
        ("XTR_V1_QPC_DST_VPORT_ID", 0, ""),
        ("XTR_V1_QPC_SRC_ADDR_IDX", 0, ""),
        ("XTR_V1_QPC_DST_PORT", 0, ""),
        ("XTR_V1_QPC_DST_QPN", urc_remote_qpn, ""),
        ("XTR_V1_QPC_DMAC", 0, ""),
        ("XTR_V1_QPC_PRI", 0, ""),
        ("XTR_V1_QPC_CFI", 0, ""),
        ("XTR_V1_QPC_VLAN_ID", 0, ""),
        ("XTR_V1_QPC_SRC_VPORT_ID", 0, ""),
        ("XTR_V1_QPC_FLOW_LABEL", 0, ""),
        ("XTR_V1_QPC_DSCP", urc_traffic_class >> 2, ""),
        ("XTR_V1_QPC_ECN", urc_traffic_class & 3, ""),
        ("XTR_V1_QPC_HOPLIMIT", 0, ""),
        ("XTR_V1_QPC_CUR_UDP_SPORT", 0, ""),
        ("XTR_V1_QPC_URC_TX_RBSN", urc_rbsn, ""),
        ("XTR_V1_QPC_URC_RX_RBSN", urc_rbsn, ""),
        ("XTR_V1_QPC_URC_TX_DBSN", urc_dbsn, ""),
        ("XTR_V1_QPC_URC_RX_DBSN", urc_dbsn, ""),
        ("XTR_V1_QPC_URC_RXED_DBSN", urc_dbsn, ""),
        ("XTR_V1_QPC_URC_CUR_TX_RPSN", urc_rpsn, ""),
        ("XTR_V1_QPC_URC_TPE_RPSN_MAX", urc_rpsn, ""),
        ("XTR_V1_QPC_URC_CUR_TX_DPSN", urc_dpsn, ""),
        ("XTR_V1_QPC_URC_TPE_DPSN_MAX", urc_dpsn, ""),
        ("XTR_V1_QPC_URC_RX_SRBSN", 0, ""),
        ("XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM", 8, ""),
        ("XTR_V1_QPC_URC_RQ_SE_TH", urc_rq_threshold.bit_length() - 1, ""),
        ("XTR_V1_QPC_URC_SQ_CE_TH", urc_sq_threshold.bit_length() - 1, ""),
        ("XTR_V1_QPC_URC_TX_SRBSN", 0, ""),
        ("XTR_V1_QPC_URC_MAX_TX_SRBSN", 0, ""),
        ("XTR_V1_QPC_URC_CUR_DSQ_PBA_H", urc_dsq_page >> 12, ""),
        ("XTR_V1_QPC_URC_CUR_DSQ_PBA_L", urc_dsq_page & 0xFFF, ""),
        ("XTR_V1_QPC_URC_NXT_DSQ_PBA", urc_dsq_page + 1, ""),
        ("XTR_V1_QPC_URC_NXT_DSQ_FETCH_NUM", 8, ""),
        ("XTR_V1_QPC_SQ_PBA", urc_sq_page, ""),
        ("XTR_V1_QPC_SQ_SIZE", urc_sq_depth.bit_length() - 1, ""),
        ("XTR_V1_QPC_SQ_OM", 3, ""),
        ("XTR_V1_QPC_SQ_CQN", 0xFFFFF, ""),
        ("XTR_V1_QPC_RQ_CQN", 0xABCDE, ""),
        ("XTR_V1_QPC_RQ_PBA", urc_rq_page, ""),
        ("XTR_V1_QPC_RQ_SIZE", urc_rq_depth.bit_length() - 1, ""),
        ("XTR_V1_QPC_RQ_OM", 2, ""),
    ))
```

The three runtime SRBSN tuples deliberately write zero in the independent golden
builder so their pinned coordinates remain exercised. Task 10C must still exclude
them from codec occupancy and the create allowed mask.

- [ ] **Step 6: Strengthen independent URC contract validation**

First replace the `ICOS`/`DSCP`/`ECN` checks in the common three-QPC loop. RC and UD
retain their historical derived-value summaries, while the refrozen URC summary can
contain model-only `traffic_class`:

```python
        if icos != traffic_class >> 5:
            raise ValidationError(f"{case.name} traffic class/ICOS mismatch")
        if dscp != traffic_class >> 2:
            raise ValidationError(f"{case.name} traffic class/DSCP mismatch")
        if ecn != (traffic_class & 0x3) or ecn != required_ecn[transport]:
            raise ValidationError(f"{case.name} ECN policy/input mismatch")
        for input_name, actual in (("icos", icos), ("dscp", dscp), ("ecn", ecn)):
            summarized = inputs_by_name(case).get(input_name)
            if summarized is not None and int(summarized, 0) != actual:
                raise ValidationError(
                    f"{case.name} derived {input_name} summary mismatch"
                )
```

Replace the current three-check URC tail in `validate_context_contract()` with this
exact transform validation:

```python
    urc = cases[2]
    direct_semantics = (
        ("XTR_V1_QPC_TVER", "transport_version"),
        ("XTR_V1_QPC_MIG", "migration_enable"),
        ("XTR_V1_QPC_HOST_ID", "host_id"),
        ("XTR_V1_QPC_VF_ID", "vf_id"),
        ("XTR_V1_QPC_QPN", "qpn"),
        ("XTR_V1_QPC_STAT_IDX", "stat_index"),
        ("XTR_V1_QPC_PKEY", "pkey"),
        ("XTR_V1_QPC_TX_ENDIAN_SWAP", "tx_endian_swap"),
        ("XTR_V1_QPC_RX_ENDIAN_SWAP", "rx_endian_swap"),
        ("XTR_V1_QPC_SQ_CE_EN", "signature_enable"),
        ("XTR_V1_QPC_RA_FENCE", "read_after_write_fence"),
        ("XTR_V1_QPC_AA_FENCE", "atomic_after_atomic_fence"),
        ("XTR_V1_QPC_QP_ST", "state"),
        ("XTR_V1_QPC_QP_SN", "qp_sequence"),
        ("XTR_V1_QPC_PD_IDX", "pd_id"),
        ("XTR_V1_QPC_QP_ACCESS_FLAG", "access"),
        ("XTR_V1_QPC_VLAN", "vlan_enable"),
        ("XTR_V1_QPC_IPV6", "ipv6"),
        ("XTR_V1_QPC_TUNNEL", "tunnel_enable"),
        ("XTR_V1_QPC_LAG", "lag_enable"),
        ("XTR_V1_QPC_FWD", "forwarding_enable"),
        ("XTR_V1_QPC_DST_VPORT_ID", "destination_vport"),
        ("XTR_V1_QPC_SRC_ADDR_IDX", "source_address_index"),
        ("XTR_V1_QPC_DST_PORT", "destination_port"),
        ("XTR_V1_QPC_DST_QPN", "remote_qpn"),
        ("XTR_V1_QPC_DMAC", "destination_mac"),
        ("XTR_V1_QPC_PRI", "priority"),
        ("XTR_V1_QPC_CFI", "cfi"),
        ("XTR_V1_QPC_VLAN_ID", "vlan_id"),
        ("XTR_V1_QPC_SRC_VPORT_ID", "source_vport"),
        ("XTR_V1_QPC_FLOW_LABEL", "flow_label"),
        ("XTR_V1_QPC_HOPLIMIT", "hop_limit"),
        ("XTR_V1_QPC_CUR_UDP_SPORT", "udp_source_port"),
        ("XTR_V1_QPC_SQ_OM", "sq_mode"),
        ("XTR_V1_QPC_SQ_CQN", "send_cq_id"),
        ("XTR_V1_QPC_RQ_CQN", "recv_cq_id"),
        ("XTR_V1_QPC_RQ_OM", "rq_mode"),
    )
    for stem, input_name in direct_semantics:
        if field_value(urc, stem) != numeric_input(urc, input_name):
            raise ValidationError(f"{urc.name} {stem}/{input_name} mismatch")

    flow_control = field_value(urc, "XTR_V1_QPC_FC_EN")
    if (flow_control != numeric_input(urc, "tx_flow_control")
            or flow_control != numeric_input(urc, "rx_flow_control")):
        raise ValidationError(f"{urc.name} flow-control input mismatch")
    if (field_value(urc, "XTR_V1_QPC_SHADOW_PBA") << 9
            != numeric_input(urc, "context_backing")):
        raise ValidationError(f"{urc.name} context backing/input mismatch")
    if (field_value(urc, "XTR_V1_QPC_SQ_PBA") << 12
            != numeric_input(urc, "sq_backing")):
        raise ValidationError(f"{urc.name} SQ backing/input mismatch")
    if (field_value(urc, "XTR_V1_QPC_RQ_PBA") << 12
            != numeric_input(urc, "rq_backing")):
        raise ValidationError(f"{urc.name} RQ backing/input mismatch")

    pmtu_codes = {1024: 2, 2048: 3, 4096: 4, 8192: 5}
    path_mtu_bytes = numeric_input(urc, "path_mtu_bytes")
    if (path_mtu_bytes not in pmtu_codes
            or field_value(urc, "XTR_V1_QPC_PMTU")
            != pmtu_codes[path_mtu_bytes]):
        raise ValidationError(f"{urc.name} path MTU/input mismatch")

    destination_ip = inputs_by_name(urc).get("destination_ip")
    if destination_ip is None or re.fullmatch(r"[0-9a-f]{32}", destination_ip) is None:
        raise ValidationError(f"{urc.name} destination IP input is malformed")
    destination_ip_offset = PROFILE_VALUES["XTR_V1_QPC_DEST_IP_BYTE_OFFSET"]
    destination_ip_bytes = PROFILE_VALUES["XTR_V1_QPC_DEST_IP_BYTES"]
    if urc.payload[
        destination_ip_offset:destination_ip_offset + destination_ip_bytes
    ].hex() != destination_ip:
        raise ValidationError(f"{urc.name} destination IP/input mismatch")

    rsq_page = ((field_value(urc, "XTR_V1_QPC_URC_RSQ_PBA_H") << 48)
                | field_value(urc, "XTR_V1_QPC_URC_RSQ_PBA_L"))
    rdsq_page = field_value(urc, "XTR_V1_QPC_URC_RDSQ_PBA")
    dsq_page = ((field_value(urc, "XTR_V1_QPC_URC_CUR_DSQ_PBA_H") << 12)
                | field_value(urc, "XTR_V1_QPC_URC_CUR_DSQ_PBA_L"))
    if rsq_page << 12 != numeric_input(urc, "rsq_backing"):
        raise ValidationError(f"{urc.name} split RSQ backing/input mismatch")
    if rdsq_page << 12 != numeric_input(urc, "rdsq_backing"):
        raise ValidationError(f"{urc.name} RDSQ backing/input mismatch")
    if dsq_page << 12 != numeric_input(urc, "dsq_backing"):
        raise ValidationError(f"{urc.name} split DSQ backing/input mismatch")
    if field_value(urc, "XTR_V1_QPC_URC_NXT_DSQ_PBA") != dsq_page + 1:
        raise ValidationError(f"{urc.name} derived next DSQ page mismatch")

    direct_fields = (
        ("XTR_V1_QPC_DST_QPN", "remote_qpn"),
        ("XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM", "rdsq_fetch_count"),
        ("XTR_V1_QPC_URC_NXT_DSQ_FETCH_NUM", "dsq_fetch_count"),
    )
    for stem, input_name in direct_fields:
        if field_value(urc, stem) != numeric_input(urc, input_name):
            raise ValidationError(f"{urc.name} {stem}/{input_name} mismatch")

    log2_fields = (
        ("XTR_V1_QPC_URC_RSQ_SIZE", "rsq_depth"),
        ("XTR_V1_QPC_URC_RDSQ_SIZE", "rdsq_depth"),
        ("XTR_V1_QPC_URC_RQ_SE_TH", "rq_sequence_threshold_entries"),
        ("XTR_V1_QPC_URC_SQ_CE_TH", "sq_completion_threshold_entries"),
        ("XTR_V1_QPC_SQ_SIZE", "sq_depth"),
        ("XTR_V1_QPC_RQ_SIZE", "rq_depth"),
    )
    for stem, input_name in log2_fields:
        semantic_value = numeric_input(urc, input_name)
        if semantic_value == 0 or semantic_value & (semantic_value - 1):
            raise ValidationError(f"{urc.name} {input_name} is not a power of two")
        if field_value(urc, stem) != semantic_value.bit_length() - 1:
            raise ValidationError(f"{urc.name} {stem}/{input_name} log2 mismatch")

    mirrors = {
        "rbsn": ("XTR_V1_QPC_URC_TX_RBSN", "XTR_V1_QPC_URC_RX_RBSN"),
        "dbsn": (
            "XTR_V1_QPC_URC_TX_DBSN", "XTR_V1_QPC_URC_RX_DBSN",
            "XTR_V1_QPC_URC_RXED_DBSN",
        ),
        "rpsn": (
            "XTR_V1_QPC_URC_CUR_TX_RPSN",
            "XTR_V1_QPC_URC_TPE_RPSN_MAX",
        ),
        "dpsn": (
            "XTR_V1_QPC_URC_CUR_TX_DPSN",
            "XTR_V1_QPC_URC_TPE_DPSN_MAX",
        ),
    }
    for input_name, stems in mirrors.items():
        expected = numeric_input(urc, input_name)
        if any(field_value(urc, stem) != expected for stem in stems):
            raise ValidationError(f"{urc.name} {input_name} mirror mismatch")

    for stem in (
        "XTR_V1_QPC_URC_RX_SRBSN",
        "XTR_V1_QPC_URC_TX_SRBSN",
        "XTR_V1_QPC_URC_MAX_TX_SRBSN",
    ):
        if field_value(urc, stem) != 0:
            raise ValidationError(f"{urc.name} runtime field {stem} is nonzero")
```

- [ ] **Step 7: Regenerate only the mechanical context golden artifact**

After the independent builder and tests are in place, regenerate the complete file
from `GoldenCase` objects. This is a mechanical generated-artifact rewrite; inspect the
diff immediately afterward and reject any RC, UD, or body-case change.

```bash
python3 - <<'PY'
import importlib.util
from pathlib import Path

root = Path.cwd()
checker_path = root / "tools/check_xtr_v1_defs.py"
spec = importlib.util.spec_from_file_location("check_xtr_v1_defs", checker_path)
checker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(checker)
(root / "hw/xtr_v1/golden_vectors/context.hex").write_text(
    checker.render_golden(checker.build_golden_cases()["context"]),
    encoding="ascii",
)
PY
git diff -- hw/xtr_v1/golden_vectors/context.hex
```

Expected: only the `qpc_urc_boundary` input line and its 512-byte payload line change.
The case name, byte count, preceding RC/UD bytes, and following eight body cases remain
identical.

- [ ] **Step 8: Update the source map with the final ownership statement**

Replace the QPC row's URC sentence in `docs/hw/xtr-v1-source-map.md` and add the
coordinate paragraph below the image table:

```markdown
`qpc_urc_boundary` is a canonical create/modify semantic image: one `rbsn`, `dbsn`,
`rpsn`, and `dpsn` source drives every corresponding hardware mirror; RSQ/RDSQ/DSQ
backing inputs are unshifted byte addresses; depth and threshold inputs are entry
counts; fetch inputs are counts. `RX_SRBSN`, `TX_SRBSN`, and `MAX_TX_SRBSN` are
runtime-only and remain zero.

The fixed `qp.h` source additionally freezes `XTRDMA_QPC_URC_RSQ_SIZE` at byte 24,
logical qword LSB 59, width 3, and `XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM` at byte 224,
LSB 16, width 6. The checker parses both masks from the pinned source bytes and
compares them with an independent reference row and the published SV constants.
```

- [ ] **Step 9: Run GREEN checks**

```bash
python3 -m unittest -v tests.unit.test_check_xtr_v1_defs
scripts/run_vcs53.sh xtr_defs check
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
git diff --check
```

Expected: Python reports `OK`; the fixed-driver checker prints
`xtr_v1 definitions: PASS`; VCS exits zero with UVM warning/error/fatal `0/0/0`;
`git diff --check` is silent.

- [ ] **Step 10: Commit the frozen prerequisite**

```bash
git add tools/check_xtr_v1_defs.py tests/unit/test_check_xtr_v1_defs.py \
  src/codec/xtr_v1/rdma_xtr_v1_defs.svh \
  tests/unit/rdma_xtr_v1_defs_test.svh \
  hw/xtr_v1/golden_vectors/context.hex docs/hw/xtr-v1-source-map.md
git commit -m "feat: freeze canonical urc qpc create ABI"
```

Expected: one commit containing no model or codec implementation changes.

### Task 2: Introduce the hardware-neutral URC queue configuration

**Files:**
- Modify: `tests/unit/rdma_context_model_test.svh`
- Modify: `tests/unit/rdma_request_model_test.svh`
- Modify: `src/model/rdma_context_layouts.svh`
- Modify: `src/model/rdma_context_models.svh`

- [ ] **Step 1: Write failing queue value-object and extension tests**

Add these declarations to `rdma_context_model_test.run_phase()`:

```systemverilog
    rdma_urc_queue_config urc_queues;
    rdma_urc_queue_config urc_queues_clone;
    rdma_qpc_urc_ext urc_ext_clone;
```

Before the existing standalone URC extension setup, add the exact factory/default,
validation, description, and copy checks:

```systemverilog
    urc_queues = rdma_urc_queue_config::type_id::create("urc_queues");
    if (urc_queues.rsq_backing.value != 0 ||
        urc_queues.rdsq_backing.value != 0 ||
        urc_queues.dsq_backing.value != 0 ||
        urc_queues.rsq_depth != 0 || urc_queues.rdsq_depth != 0 ||
        urc_queues.rdsq_fetch_count != 0 ||
        urc_queues.dsq_fetch_count != 0 ||
        urc_queues.rq_sequence_threshold_entries != 0 ||
        urc_queues.sq_completion_threshold_entries != 0)
      `uvm_error("URC_QUEUE_DEFAULTS", "URC queue defaults are not zero")
    expect_invalid("URC_QUEUE_ZERO_DEPTH", urc_queues.validate());

    urc_queues.rsq_backing.value = 64'h0000_0001_6000_0000;
    urc_queues.rdsq_backing.value = 64'h0000_0001_7000_0000;
    urc_queues.dsq_backing.value = 64'h0000_0001_8000_0000;
    urc_queues.rsq_depth = 64;
    urc_queues.rdsq_depth = 128;
    urc_queues.rdsq_fetch_count = 8;
    urc_queues.dsq_fetch_count = 16;
    urc_queues.rq_sequence_threshold_entries = 16;
    urc_queues.sq_completion_threshold_entries = 32;
    expect_ok("URC_QUEUE_VALID", urc_queues.validate());
    if (!uvm_is_match("*rsq_depth=64*rdsq_depth=128*", urc_queues.describe()))
      `uvm_error("URC_QUEUE_DESCRIBE", "URC queue description lost topology")

    cloned_object = urc_queues.clone();
    if (!$cast(urc_queues_clone, cloned_object))
      `uvm_error("URC_QUEUE_CLONE", "URC queue clone lost dynamic type")
    else begin
      urc_queues_clone.rsq_backing.value += 64'h1000;
      urc_queues_clone.rsq_depth = 256;
      urc_queues_clone.rdsq_fetch_count = 32;
      if (urc_queues.rsq_backing.value != 64'h0000_0001_6000_0000 ||
          urc_queues.rsq_depth != 64 || urc_queues.rdsq_fetch_count != 8)
        `uvm_error("URC_QUEUE_CLONE", "URC queue clone aliases source")
    end
```

Replace the old direct URC backing/threshold assignments with:

```systemverilog
    urc_ext = rdma_qpc_urc_ext::type_id::create("urc_ext");
    urc_ext.remote_qpn = 24'h112233;
    urc_ext.rbsn = 24'h010203;
    urc_ext.dbsn = 24'h040506;
    urc_ext.rpsn = 24'h070809;
    urc_ext.dpsn = 24'h0a0b0c;
    urc_ext.queues.copy(urc_queues);
    expect_ok("URC_EXT_VALID", urc_ext.validate());
    if (!uvm_is_match("*rpsn=460809*dpsn=658188*queues=*",
                      urc_ext.describe()))
      `uvm_error("URC_EXT_DESCRIBE", "URC extension description is incomplete")

    cloned_object = urc_ext.clone();
    if (!$cast(urc_ext_clone, cloned_object))
      `uvm_error("URC_EXT_CLONE", "URC extension clone lost dynamic type")
    else if (urc_ext_clone.queues == null ||
             urc_ext_clone.queues == urc_ext.queues)
      `uvm_error("URC_EXT_CLONE", "URC extension queue was not deep-copied")
    else begin
      urc_ext_clone.queues.dsq_backing.value += 64'h1000;
      urc_ext_clone.queues.sq_completion_threshold_entries = 64;
      if (urc_ext.queues.dsq_backing.value != 64'h0000_0001_8000_0000 ||
          urc_ext.queues.sq_completion_threshold_entries != 32)
        `uvm_error("URC_EXT_CLONE", "URC extension clone aliases source")
    end
```

Add these validation mutations after the valid extension check; restore each field
before moving to the next case:

```systemverilog
    urc_ext.queues = null;
    expect_invalid("URC_QUEUE_NULL", urc_ext.validate());
    urc_ext.queues = urc_queues;

    urc_queues.rsq_backing.value++;
    expect_invalid("URC_RSQ_ALIGNMENT", urc_ext.validate());
    urc_queues.rsq_backing.value--;
    urc_queues.rdsq_backing.value++;
    expect_invalid("URC_RDSQ_ALIGNMENT", urc_ext.validate());
    urc_queues.rdsq_backing.value--;
    urc_queues.dsq_backing.value++;
    expect_invalid("URC_DSQ_ALIGNMENT", urc_ext.validate());
    urc_queues.dsq_backing.value--;

    urc_queues.rsq_depth = 48;
    expect_invalid("URC_RSQ_DEPTH", urc_ext.validate());
    urc_queues.rsq_depth = 64;
    urc_queues.rdsq_depth = 0;
    expect_invalid("URC_RDSQ_DEPTH", urc_ext.validate());
    urc_queues.rdsq_depth = 128;
    urc_queues.rq_sequence_threshold_entries = 1;
    expect_invalid("URC_RQ_THRESHOLD_ONE", urc_ext.validate());
    urc_queues.rq_sequence_threshold_entries = 3;
    expect_invalid("URC_RQ_THRESHOLD_NON_POWER_TWO", urc_ext.validate());
    urc_queues.rq_sequence_threshold_entries = 16;
    urc_queues.sq_completion_threshold_entries = 6;
    expect_invalid("URC_SQ_THRESHOLD_NON_POWER_TWO", urc_ext.validate());
    urc_queues.sq_completion_threshold_entries = 32;

    urc_queues.rsq_depth = 1024;
    urc_queues.rdsq_depth = 2048;
    urc_queues.rdsq_fetch_count = 1000;
    urc_queues.dsq_fetch_count = 2000;
    urc_queues.rq_sequence_threshold_entries = 0;
    urc_queues.sq_completion_threshold_entries = 0;
    expect_ok("URC_QUEUE_DEVICE_NEUTRAL_WIDTH", urc_ext.validate());
```

Switch the existing valid QPC to URC and test cross-object topology after restoring
the canonical small values:

```systemverilog
    urc_queues.rsq_depth = 64;
    urc_queues.rdsq_depth = 128;
    urc_queues.rdsq_fetch_count = 8;
    urc_queues.dsq_fetch_count = 16;
    urc_queues.rq_sequence_threshold_entries = qpc.rq_depth;
    urc_queues.sq_completion_threshold_entries = qpc.sq_depth;
    qpc.transport = RDMA_TRANSPORT_URC;
    qpc.transport_ext = urc_ext;
    expect_ok("URC_QPC_THRESHOLDS_AT_DEPTH", qpc.validate());
    urc_queues.rq_sequence_threshold_entries = qpc.rq_depth << 1;
    expect_invalid("URC_RQ_THRESHOLD_EXCEEDS_DEPTH", qpc.validate());
    urc_queues.rq_sequence_threshold_entries = qpc.rq_depth;
    urc_queues.sq_completion_threshold_entries = qpc.sq_depth << 1;
    expect_invalid("URC_SQ_THRESHOLD_EXCEEDS_DEPTH", qpc.validate());
    urc_queues.sq_completion_threshold_entries = qpc.sq_depth;
    expect_ok("URC_QPC_THRESHOLDS_RESTORED", qpc.validate());
```

- [ ] **Step 2: Extend the request/CMQ clone test before implementation**

In `rdma_request_model_test.svh`, replace the direct URC queue assignments with:

```systemverilog
    urc_ext.queues.rsq_backing.value = 64'h0000_0000_6100_0000;
    urc_ext.queues.rdsq_backing.value = 64'h0000_0000_6200_0000;
    urc_ext.queues.dsq_backing.value = 64'h0000_0000_6300_0000;
    urc_ext.queues.rsq_depth = 64;
    urc_ext.queues.rdsq_depth = 128;
    urc_ext.queues.rdsq_fetch_count = 8;
    urc_ext.queues.dsq_fetch_count = 16;
    urc_ext.queues.rq_sequence_threshold_entries = 128;
    urc_ext.queues.sq_completion_threshold_entries = 256;
```

Extend the existing CMQ clone predicates and mutation branch with the complete nested
queue ownership check:

```systemverilog
    else if (urc_ext_clone.remote_qpn != 24'h765432 ||
        urc_ext_clone.rbsn != 24'h112244 ||
        urc_ext_clone.dbsn != 24'h223355 ||
        urc_ext_clone.rpsn != 24'h334466 ||
        urc_ext_clone.dpsn != 24'h445577 ||
        urc_ext_clone.queues == null ||
        urc_ext_clone.queues == urc_ext.queues ||
        urc_ext_clone.queues.rsq_backing.value != 64'h0000_0000_6100_0000 ||
        urc_ext_clone.queues.rdsq_backing.value != 64'h0000_0000_6200_0000 ||
        urc_ext_clone.queues.dsq_backing.value != 64'h0000_0000_6300_0000 ||
        urc_ext_clone.queues.rsq_depth != 64 ||
        urc_ext_clone.queues.rdsq_depth != 128 ||
        urc_ext_clone.queues.rdsq_fetch_count != 8 ||
        urc_ext_clone.queues.dsq_fetch_count != 16 ||
        urc_ext_clone.queues.rq_sequence_threshold_entries != 128 ||
        urc_ext_clone.queues.sq_completion_threshold_entries != 256)
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost URC create semantics")
    else begin
      cmq_clone.function_h.function_uid++;
      cmq_clone.target_h.object_id++;
      qpc_clone.sq_depth = 2048;
      urc_ext_clone.remote_qpn++;
      urc_ext_clone.queues.rsq_backing.value += 64'h1000;
      urc_ext_clone.queues.rdsq_fetch_count++;
      if (cmq_create_qp.function_h.function_uid !=
            64'h1234_5678_9abc_def0 ||
          cmq_create_qp.target_h.object_id != 32'h404 ||
          qpc.sq_depth != 1024 || urc_ext.remote_qpn != 24'h765432 ||
          urc_ext.queues.rsq_backing.value != 64'h0000_0000_6100_0000 ||
          urc_ext.queues.rdsq_fetch_count != 8)
        `uvm_error("CMQ_CLONE", "CMQ clone mutation reached source")
    end
```

- [ ] **Step 3: Run RED on the VCS host**

```bash
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
```

Expected: both commands fail compilation on the missing `rdma_urc_queue_config` type
or missing `rdma_qpc_urc_ext.queues` member.

- [ ] **Step 4: Implement `rdma_urc_queue_config`**

Append this class to `src/model/rdma_context_layouts.svh` after
`rdma_address_vector` and before the MR page-layout class:

```systemverilog
class rdma_urc_queue_config extends uvm_object;
  `uvm_object_utils(rdma_urc_queue_config)

  rdma_backing_addr_t rsq_backing;
  rdma_backing_addr_t rdsq_backing;
  rdma_backing_addr_t dsq_backing;
  int unsigned rsq_depth;
  int unsigned rdsq_depth;
  int unsigned rdsq_fetch_count;
  int unsigned dsq_fetch_count;
  int unsigned rq_sequence_threshold_entries;
  int unsigned sq_completion_threshold_entries;

  function new(string name = "rdma_urc_queue_config");
    super.new(name);
    rsq_backing = '0;
    rdsq_backing = '0;
    dsq_backing = '0;
    rsq_depth = '0;
    rdsq_depth = '0;
    rdsq_fetch_count = '0;
    dsq_fetch_count = '0;
    rq_sequence_threshold_entries = '0;
    sq_completion_threshold_entries = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_urc_queue_config rhs_config;

    super.do_copy(rhs);
    if (!$cast(rhs_config, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "URC queue configuration copy mismatch")
    rsq_backing = rhs_config.rsq_backing;
    rdsq_backing = rhs_config.rdsq_backing;
    dsq_backing = rhs_config.dsq_backing;
    rsq_depth = rhs_config.rsq_depth;
    rdsq_depth = rhs_config.rdsq_depth;
    rdsq_fetch_count = rhs_config.rdsq_fetch_count;
    dsq_fetch_count = rhs_config.dsq_fetch_count;
    rq_sequence_threshold_entries =
      rhs_config.rq_sequence_threshold_entries;
    sq_completion_threshold_entries =
      rhs_config.sq_completion_threshold_entries;
  endfunction

  virtual function rdma_status validate();
    if ((rsq_backing.value & 64'hfff) != 0 ||
        (rdsq_backing.value & 64'hfff) != 0 ||
        (dsq_backing.value & 64'hfff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC queue backing is not 4 KiB aligned");
    if (!rdma_is_power_of_two(rsq_depth) ||
        !rdma_is_power_of_two(rdsq_depth))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "URC RSQ/RDSQ depth is not a nonzero power of two"
      );
    if ((rq_sequence_threshold_entries != 0 &&
         (rq_sequence_threshold_entries < 2 ||
          !rdma_is_power_of_two(rq_sequence_threshold_entries))) ||
        (sq_completion_threshold_entries != 0 &&
         (sq_completion_threshold_entries < 2 ||
          !rdma_is_power_of_two(sq_completion_threshold_entries))))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "URC queue threshold is not zero or a power of two of at least two"
      );
    return rdma_status::success();
  endfunction

  virtual function string describe();
    return $sformatf(
      "URCQueues(rsq=0x%016x rdsq=0x%016x dsq=0x%016x rsq_depth=%0d rdsq_depth=%0d rdsq_fetch=%0d dsq_fetch=%0d rq_threshold=%0d sq_threshold=%0d)",
      rsq_backing.value, rdsq_backing.value, dsq_backing.value,
      rsq_depth, rdsq_depth, rdsq_fetch_count, dsq_fetch_count,
      rq_sequence_threshold_entries, sq_completion_threshold_entries
    );
  endfunction
endclass
```

The generic class intentionally has no 3-bit/4-bit/6-bit checks and permits fetch
count zero. Those are xtr_v1 profile constraints in Task 10C.

- [ ] **Step 5: Replace direct URC queue fields with one owned object**

Replace `rdma_qpc_urc_ext` in `src/model/rdma_context_models.svh` with:

```systemverilog
class rdma_qpc_urc_ext extends rdma_qpc_transport_ext;
  `uvm_object_utils(rdma_qpc_urc_ext)

  bit [23:0] remote_qpn;
  bit [23:0] rbsn;
  bit [23:0] dbsn;
  bit [23:0] rpsn;
  bit [23:0] dpsn;
  rdma_urc_queue_config queues;

  function new(string name = "rdma_qpc_urc_ext");
    super.new(name);
    remote_qpn = '0;
    rbsn = '0;
    dbsn = '0;
    rpsn = '0;
    dpsn = '0;
    queues = rdma_urc_queue_config::type_id::create("queues");
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_urc_ext rhs_ext;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "URC QPC extension copy mismatch")
    remote_qpn = rhs_ext.remote_qpn;
    rbsn = rhs_ext.rbsn;
    dbsn = rhs_ext.dbsn;
    rpsn = rhs_ext.rpsn;
    dpsn = rhs_ext.dpsn;
    if (rhs_ext.queues == null) begin
      queues = null;
    end
    else begin
      cloned_object = rhs_ext.queues.clone();
      if (cloned_object == null || !$cast(queues, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "URC queue configuration clone mismatch")
    end
  endfunction

  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_URC;
  endfunction

  virtual function rdma_status validate();
    if (remote_qpn == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC QPC remote QPN is zero");
    if (queues == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC queue configuration is null");
    return queues.validate();
  endfunction

  virtual function string describe();
    string queue_text;

    queue_text = (queues == null) ? "null" : queues.describe();
    return $sformatf(
      "URC(remote_qpn=%0d rbsn=%0d dbsn=%0d rpsn=%0d dpsn=%0d queues=%s)",
      remote_qpn, rbsn, dbsn, rpsn, dpsn, queue_text
    );
  endfunction
endclass
```

- [ ] **Step 6: Add common-QPC threshold topology validation**

In `rdma_qpc_model.validate()`, replace the final
`return transport_ext.validate();` with:

```systemverilog
    status = transport_ext.validate();
    if (!status.ok()) return status;
    if (transport == RDMA_TRANSPORT_URC) begin
      if (urc_ext.queues.rq_sequence_threshold_entries > rq_depth)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "URC RQ sequence threshold exceeds common RQ depth"
        );
      if (urc_ext.queues.sq_completion_threshold_entries > sq_depth)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "URC SQ completion threshold exceeds common SQ depth"
        );
    end
    return rdma_status::success();
```

This code is safe after `transport_ext.validate()` because a URC extension with a null
`queues` object has already returned `RDMA_SC_INVALID_ARGUMENT`.

- [ ] **Step 7: Run GREEN model checks**

```bash
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_model_test
git diff --check
rg -n 'fetch_threshold|queue_threshold|\.rsq_backing|\.rdsq_backing|\.dsq_backing' \
  src/model tests/unit
```

Expected: all three VCS tests exit zero with UVM warning/error/fatal `0/0/0`;
`git diff --check` is silent; the final search shows queue backing only through
`.queues` or within `rdma_urc_queue_config`, and shows no old threshold member.

- [ ] **Step 8: Commit the model prerequisite**

```bash
git add src/model/rdma_context_layouts.svh \
  src/model/rdma_context_models.svh \
  tests/unit/rdma_context_model_test.svh \
  tests/unit/rdma_request_model_test.svh
git commit -m "feat: model urc qpc create queues"
```

Expected: one commit containing the hardware-neutral model and migrated model tests,
with no xtr_v1 codec implementation.

### Task 3: Reconcile the parent ABI and executable Task 10C contract

**Files:**
- Modify: `docs/superpowers/specs/2026-08-21-xtr-v1-context-body-abi-design.md`
- Modify: `docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md`

- [ ] **Step 1: Replace stale URC ownership in the parent design**

In parent design section 6.2, replace the paragraph beginning `URC extension` with:

```markdown
URC create/modify semantics use one `rdma_qpc_urc_ext` containing `remote_qpn`,
`rbsn/dbsn/rpsn/dpsn`, and a non-null `rdma_urc_queue_config`. The queue object owns
unshifted byte-address `rsq_backing/rdsq_backing/dsq_backing`, entry-count
`rsq_depth/rdsq_depth`, count-valued `rdsq_fetch_count/dsq_fetch_count`, and
entry-count `rq_sequence_threshold_entries/sq_completion_threshold_entries`.

xtr_v1 maps `rbsn` to `TX_RBSN/RX_RBSN`, `dbsn` to
`TX_DBSN/RX_DBSN/RXED_DBSN`, `rpsn` to `CUR_TX_RPSN/TPE_RPSN_MAX`, and `dpsn` to
`CUR_TX_DPSN/TPE_DPSN_MAX`. Decode requires every group to agree before publishing
the canonical scalar. `RX_SRBSN/TX_SRBSN/MAX_TX_SRBSN` are runtime state: they have
no create-model owner, are excluded from the create allowed mask, and any nonzero
decode value is `RDMA_SC_CODEC_ERROR`.

RSQ/RDSQ depths encode as exact `log2(entries)` in 3 bits. RDSQ/DSQ fetch counts
encode directly in 6 bits. A zero threshold encodes as code 0; a nonzero threshold
encodes as exact `log2(entries)` in 4 bits. DSQ current page is
`dsq_backing.value >> 12`; next page must equal current page plus one without 52-bit
overflow. All inverse transforms are checked during decode.
```

In section 7, append this exact equality rule after the common PMTU rule:

```markdown
URC `serialized_equal()` additionally compares `remote_qpn`, all four canonical
sequence values, and every field in `rdma_urc_queue_config`. It does not compare the
three runtime SRBSN fields because successful create-image decode requires those bits
to be zero.
```

Replace the `qpc_urc_boundary` bullet in section 9.2 with:

```markdown
- `qpc_urc_boundary`：非零 remote QPN；由四个 canonical sequence owner 派生的全部
  mirror；以 byte address/entry count/count 为单位的 RSQ/RDSQ/DSQ queue config；
  RSQ/RDSQ depth、RDSQ/DSQ fetch、RQ/SQ threshold；三个 runtime SRBSN 字段为零；
```

- [ ] **Step 2: Update replay order and final public ownership in the parent plan**

Replace the clean-replay sentence near the top of the parent plan with:

```markdown
For a clean replay, execute Task 9.5 -> URC frozen-ABI prerequisite -> Task 10A ->
Task 10A.1 -> Task 10A.2 -> URC queue-model prerequisite -> Task 10B -> Task 10C.
The two URC prerequisites follow
`docs/superpowers/plans/2026-08-22-urc-qpc-create-semantics.md`. On the current branch
Task 10B is already complete, so apply both prerequisites and their reviews before
resuming Task 10C; do not replay or rewrite the accepted qword-builder commit.
```

Replace the old URC class in the Task 10A final ownership block with both final types:

```systemverilog
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
```

After the generic QPC alignment validation paragraph, add:

```markdown
Generic URC validation requires a non-null queue object, aligned backing addresses,
nonzero power-of-two RSQ/RDSQ depths, and thresholds that are zero or powers of two
of at least two entries. RQ/SQ thresholds cannot exceed common QPC RQ/SQ depths.
Fetch counts and device field widths are not constrained by the generic model.
```

- [ ] **Step 3: Replace Task 10C's stale URC tests with the canonical matrix**

In Task 10C Step 1, replace the URC-specific test paragraph with:

```markdown
Build the URC source model only from the `qpc_urc_boundary` semantic input summary:
all backing values are byte addresses and all depth/threshold values are entry counts.
Require encode to match all 512 frozen bytes, decode to return the same canonical
values, and `serialized_equal()` to compare every queue-config member.

Add table-driven corruption cases for each mirror group (`TX_RBSN/RX_RBSN`, the three
DBSN fields, the two RPSN fields, and the two DPSN fields), each runtime field
(`RX_SRBSN/TX_SRBSN/MAX_TX_SRBSN`), RSQ/RDSQ depth, both fetch counts, both threshold
codes, DSQ next-page relation, and reserved bits. Mirror, runtime, relation, metadata,
length, and reserved corruption return `RDMA_SC_CODEC_ERROR`; every failure leaves a
pre-populated decode output null.

Add encode-invalid cases for an RSQ or RDSQ depth whose log2 exceeds 3 bits, either
fetch count above 63, either nonzero threshold whose log2 exceeds 4 bits, any queue
backing whose page number exceeds 52 bits, and a DSQ current page equal to the maximum
52-bit value. Each returns `RDMA_SC_INVALID_ARGUMENT` and leaves a pre-populated image
output null. Keep generic-model tests proving that the same widths are representable
before the xtr_v1 codec is called.

For threshold code zero, add a non-golden encode/decode case with both semantic
thresholds zero and require canonical decode back to zero. For nonzero codes, require
exact inverse `1 << code` entry counts.
```

- [ ] **Step 4: Replace Task 10C's stale URC implementation paragraph**

Replace the stale Task 10C Step 4 sentence that says URC directly encodes
`fetch_threshold` and `queue_threshold` with:

```markdown
For URC, require a non-null `queues` object and project `remote_qpn` to `DST_QPN`.
Write `rbsn` to `TX_RBSN/RX_RBSN`; `dbsn` to
`TX_DBSN/RX_DBSN/RXED_DBSN`; `rpsn` to `CUR_TX_RPSN/TPE_RPSN_MAX`; and `dpsn` to
`CUR_TX_DPSN/TPE_DPSN_MAX`. Decode reads every member of a group, rejects mismatch as
`RDMA_SC_CODEC_ERROR`, and assigns a canonical scalar only after the group agrees.

Validate each queue backing is 4KiB aligned and its page number fits 52 bits before
shifting. Split RSQ and DSQ current page across their high/low fields; write RDSQ as one
52-bit page. Encode RSQ/RDSQ depth as exact `log2(entries)` fitting 3 bits, fetch counts
directly fitting 6 bits, and threshold zero as code zero or nonzero power-of-two entry
count as log2 fitting 4 bits. Write DSQ next page as current page plus one and reject
52-bit overflow. Decode performs each exact inverse and rejects a next-page mismatch.

The URC create allowed mask includes the two newly frozen fields
`RSQ_SIZE` and `NXT_RDSQ_FETCH_NUM` plus every other common/URC create-owned field. It
excludes `RX_SRBSN`, `TX_SRBSN`, `MAX_TX_SRBSN`, `CC_TYPE`, `RTO_CODE`, and
`LOAD_RQ_PI_TH`; a nonzero excluded bit is `RDMA_SC_CODEC_ERROR`. Encode still authors
every allowed field, including semantic zero, so 64-qword occupancy equals the selected
mask exactly.
```

- [ ] **Step 5: Make the parent Task 10C GREEN gate complete**

Replace Task 10C Step 6 commands with:

```bash
scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test
scripts/run_vcs53.sh core rdma_xtr_v1_qword_codec_test
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
```

The expected statement must be:

```markdown
Expected: every command exits zero with UVM warning/error/fatal `0/0/0`; RC and UD
remain byte-identical to their frozen vectors; URC matches the canonical create vector;
all mirror/runtime/queue corruption cases return the exact status and preserve atomic
outputs; registry isolation still holds.
```

- [ ] **Step 6: Audit and commit the reconciliation**

```bash
rg -n 'fetch_threshold|queue_threshold|RX_SRBSN|TX_SRBSN|MAX_TX_SRBSN|URC queue' \
  docs/superpowers/specs/2026-08-21-xtr-v1-context-body-abi-design.md \
  docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md
git diff --check
git add docs/superpowers/specs/2026-08-21-xtr-v1-context-body-abi-design.md \
  docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md
git commit -m "docs: reconcile urc qpc create semantics"
```

Expected: old member names appear only in explicit historical/replacement statements;
runtime SRBSN references consistently say excluded/zero/error; `git diff --check` is
silent; one documentation-only commit is created.

### Task 4: Run the prerequisite acceptance gate before Task 10C

**Files:**
- Verify: `tools/check_xtr_v1_defs.py`
- Verify: `hw/xtr_v1/golden_vectors/context.hex`
- Verify: `src/model/rdma_context_layouts.svh`
- Verify: `src/model/rdma_context_models.svh`
- Verify: `docs/superpowers/plans/2026-08-21-xtr-v1-context-body-abi.md`

- [ ] **Step 1: Confirm commit isolation and a clean worktree**

```bash
git status --short
git log --oneline -3
git diff HEAD~3..HEAD --check
```

Expected: status is empty; the three newest commits are frozen ABI, queue model, and
documentation reconciliation in that order; the range check is silent.

- [ ] **Step 2: Run local independent-checker regression**

```bash
python3 -m unittest -v tests.unit.test_check_xtr_v1_defs
```

Expected: all Python tests pass with final `OK`.

- [ ] **Step 3: Run fresh fixed-driver and VCS regression on 53**

```bash
scripts/run_vcs53.sh xtr_defs check
scripts/run_vcs53.sh core rdma_xtr_v1_defs_test
scripts/run_vcs53.sh core rdma_xtr_v1_qword_codec_test
scripts/run_vcs53.sh core rdma_context_model_test
scripts/run_vcs53.sh core rdma_request_model_test
scripts/run_vcs53.sh core rdma_codec_registry_test
```

Expected: the checker prints `xtr_v1 definitions: PASS`; every VCS command exits zero
with UVM warning/error/fatal `0/0/0`; the runner removes each fresh remote staging
directory successfully.

- [ ] **Step 4: Audit final ownership before resuming parent Task 10C**

```bash
rg -n 'class rdma_urc_queue_config|rdma_urc_queue_config queues' \
  src/model/rdma_context_layouts.svh src/model/rdma_context_models.svh
rg -n 'XTR_V1_QPC_URC_RSQ_SIZE|XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM' \
  tools/check_xtr_v1_defs.py src/codec/xtr_v1/rdma_xtr_v1_defs.svh \
  tests/unit/test_check_xtr_v1_defs.py tests/unit/rdma_xtr_v1_defs_test.svh
rg -n 'fetch_threshold|queue_threshold' src tests
```

Expected: the first search shows one class and one owned extension member; the second
shows mapping/reference/definition/test coverage for both fields; the last search has
no matches. Parent Task 10C may start only after these results and its updated plan have
been reviewed.
