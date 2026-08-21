#!/usr/bin/env python3
"""Focused tests for the xtr_v1 definition checker/reference encoder."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "tools" / "check_xtr_v1_defs.py"
SPEC = importlib.util.spec_from_file_location("check_xtr_v1_defs", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {CHECKER_PATH}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class CExpressionTest(unittest.TestCase):
    def test_bit_and_genmask_forms_are_decoded(self) -> None:
        self.assertEqual(CHECKER.parse_field_expression("BIT_ULL(63)"), (63, 1))
        self.assertEqual(CHECKER.parse_field_expression("BIT(7)"), (7, 1))
        self.assertEqual(
            CHECKER.parse_field_expression("GENMASK_ULL(54, 40)"), (40, 15)
        )
        self.assertEqual(CHECKER.parse_field_expression("GENMASK(3, 0)"), (0, 4))

    def test_unsupported_expression_is_fatal(self) -> None:
        with self.assertRaisesRegex(CHECKER.ValidationError, "unsupported"):
            CHECKER.parse_field_expression("(1UL << 63)")

    def test_bit_64_is_rejected_fail_closed(self) -> None:
        for expression in ("BIT(64)", "BIT_ULL(64)"):
            with self.subTest(expression=expression):
                with self.assertRaisesRegex(CHECKER.ValidationError, "BIT.*64"):
                    CHECKER.parse_field_expression(expression)

    def test_explicit_values_are_decoded_without_eval(self) -> None:
        self.assertEqual(CHECKER.parse_value_expression("0x35"), 0x35)
        self.assertEqual(CHECKER.parse_value_expression("12"), 12)
        with self.assertRaisesRegex(CHECKER.ValidationError, "unsupported"):
            CHECKER.parse_value_expression("PREVIOUS + 1")

    def test_implicit_enum_values_are_decoded_without_eval(self) -> None:
        _, enums = CHECKER.parse_c_symbols(
            """
enum sample {
    SAMPLE_ZERO,
    SAMPLE_ONE,
    SAMPLE_FIVE = 5,
    SAMPLE_SIX,
};
"""
        )
        self.assertEqual(enums["SAMPLE_ZERO"], ["0"])
        self.assertEqual(enums["SAMPLE_ONE"], ["1"])
        self.assertEqual(enums["SAMPLE_FIVE"], ["5"])
        self.assertEqual(enums["SAMPLE_SIX"], ["6"])


class SvDefinitionTest(unittest.TestCase):
    def test_duplicate_constant_is_fatal(self) -> None:
        text = """
localparam int unsigned XTR_V1_FIELD_OFFSET = 32;
localparam int unsigned XTR_V1_FIELD_OFFSET = 40;
"""
        with self.assertRaisesRegex(CHECKER.ValidationError, "duplicate"):
            CHECKER.parse_sv_constants(text)

    def test_width_and_value_literals_are_parsed(self) -> None:
        constants = CHECKER.parse_sv_constants(
            """
localparam int unsigned XTR_V1_FIELD_WIDTH = 8;
localparam bit [7:0] XTR_V1_OP = 8'h35;
localparam bit [63:0] XTR_V1_WINDOW = 64'h2000;
"""
        )
        self.assertEqual(constants["XTR_V1_FIELD_WIDTH"], 8)
        self.assertEqual(constants["XTR_V1_OP"], 0x35)
        self.assertEqual(constants["XTR_V1_WINDOW"], 0x2000)

    def test_global_mapping_uniqueness_is_enforced(self) -> None:
        validate = getattr(CHECKER, "validate_mapping_uniqueness")
        validate(CHECKER.FIELD_MAPPINGS, CHECKER.VALUE_MAPPINGS,
                 CHECKER.REFERENCE_FIELDS)

        first_value = CHECKER.VALUE_MAPPINGS[0]
        with self.assertRaisesRegex(CHECKER.ValidationError, "SV value"):
            validate(
                CHECKER.FIELD_MAPPINGS,
                CHECKER.VALUE_MAPPINGS + (first_value._replace(c_symbol="OTHER"),),
                CHECKER.REFERENCE_FIELDS,
            )

        first_field = CHECKER.FIELD_MAPPINGS[0]
        with self.assertRaisesRegex(CHECKER.ValidationError, "field mapping"):
            validate(
                CHECKER.FIELD_MAPPINGS
                + (first_field._replace(c_symbol="OTHER_FIELD"),),
                CHECKER.VALUE_MAPPINGS,
                CHECKER.REFERENCE_FIELDS,
            )

    def test_field_declaration_expands_to_auditable_coordinates(self) -> None:
        constants = CHECKER.parse_sv_constants(
            "`XTR_V1_FIELD(XTR_V1_QPC_QPN, 0, 16, 21)\n"
        )
        self.assertEqual(constants["XTR_V1_QPC_QPN_WORD_BYTE_OFFSET"], 0)
        self.assertEqual(constants["XTR_V1_QPC_QPN_LSB"], 16)
        self.assertEqual(constants["XTR_V1_QPC_QPN_WIDTH"], 21)
        self.assertEqual(constants["XTR_V1_QPC_QPN_OFFSET"], 16)

    def test_context_object_state_mode_and_right_values_are_mapped(self) -> None:
        mappings = {
            (mapping.path, mapping.c_symbol, mapping.sv_name)
            for mapping in CHECKER.VALUE_MAPPINGS
        }
        expected = {
            ("alloc.h", "XTRDMA_ALLOC_TYPE_DIRECT", "XTR_V1_ALLOC_TYPE_DIRECT"),
            ("alloc.h", "XTRDMA_ALLOC_TYPE_INDIRECT", "XTR_V1_ALLOC_TYPE_INDIRECT"),
            ("alloc.h", "XTRDMA_ALLOC_TYPE_HUGE", "XTR_V1_ALLOC_TYPE_HUGE"),
            ("alloc.h", "XTRDMA_ALLOC_TYPE_L3_INDIRECT", "XTR_V1_ALLOC_TYPE_L3_INDIRECT"),
            ("mr.h", "XTRDMA_ADDR_TYPE_VA_BASED", "XTR_V1_ADDR_TYPE_VA_BASED"),
            ("mr.h", "XTRDMA_ADDR_TYPE_ZERO_BASED", "XTR_V1_ADDR_TYPE_ZERO_BASED"),
            ("mr.h", "XTRDMA_MR_ST_INVLD", "XTR_V1_MR_ST_INVALID"),
            ("mr.h", "XTRDMA_MR_ST_FREE", "XTR_V1_MR_ST_FREE"),
            ("mr.h", "XTRDMA_MR_ST_VLD", "XTR_V1_MR_ST_VALID"),
            ("mr.h", "XTRDMA_HOST_PAGE_4K", "XTR_V1_HOST_PAGE_4K"),
            ("mr.h", "XTRDMA_HOST_PAGE_2M", "XTR_V1_HOST_PAGE_2M"),
            ("mr.h", "XTRDMA_HOST_PAGE_1G", "XTR_V1_HOST_PAGE_1G"),
            ("mr.h", "PBL_MODE_0", "XTR_V1_PBL_MODE_0"),
            ("mr.h", "PBL_MODE_1", "XTR_V1_PBL_MODE_1"),
            ("mr.h", "PBL_MODE_2", "XTR_V1_PBL_MODE_2"),
            ("mr.h", "XTRDMA_MR", "XTR_V1_MEM_TYPE_MR"),
            ("mr.h", "XTRDMA_MW_TYPE1", "XTR_V1_MEM_TYPE_MW_TYPE1"),
            ("mr.h", "XTRDMA_MW_TYPE2B", "XTR_V1_MEM_TYPE_MW_TYPE2B"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_LOCAL_WRITE", "XTR_V1_RIGHT_LOCAL_WRITE"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_REMOTE_READ", "XTR_V1_RIGHT_REMOTE_READ"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_REMOTE_WRITE", "XTR_V1_RIGHT_REMOTE_WRITE"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_BIND_WINDOW", "XTR_V1_RIGHT_BIND_WINDOW"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_REMOTE_ATOMIC", "XTR_V1_RIGHT_REMOTE_ATOMIC"),
        }
        self.assertTrue(expected.issubset(mappings))
        self.assertEqual(
            CHECKER.ACCESS_PROJECTIONS,
            (
                ("IB_ACCESS_LOCAL_WRITE|IB_ACCESS_REMOTE_WRITE|IB_ACCESS_REMOTE_ATOMIC", "XTRDMA_ACCESS_FLAGS_LOCAL_WRITE"),
                ("IB_ACCESS_REMOTE_WRITE", "XTRDMA_ACCESS_FLAGS_REMOTE_WRITE"),
                ("IB_ACCESS_REMOTE_READ", "XTRDMA_ACCESS_FLAGS_REMOTE_READ"),
                ("IB_ACCESS_MW_BIND", "XTRDMA_ACCESS_FLAGS_BIND_WINDOW"),
                ("IB_ACCESS_REMOTE_ATOMIC", "XTRDMA_ACCESS_FLAGS_REMOTE_ATOMIC"),
            ),
        )

    def test_mask_file_exposes_qword_lookup_api_with_image_kind(self) -> None:
        validate = getattr(CHECKER, "validate_sv_mask_api")
        validate((REPO_ROOT / "src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh").read_text())


class MakefileCleanupTest(unittest.TestCase):
    def test_xtr_defs_cleanup_preserves_command_failure_and_reports_delete_failure(self) -> None:
        text = (REPO_ROOT / "sim" / "Makefile").read_text()
        recipe = text[text.index("xtr_defs:"):text.index("\nhost_mem_preflight:")]
        self.assertIn("command_status=$$?", recipe)
        self.assertIn("cleanup_status=0", recipe)
        self.assertIn("if ! rm -rf -- \"$$ref_dir\"; then", recipe)
        self.assertIn("cleanup_status=1", recipe)
        self.assertRegex(
            recipe,
            r'(?s)if \[\[ "\$\$command_status" != 0 \]\]; then.*?'
            r'exit \$\$command_status;.*?exit \$\$cleanup_status;',
        )
        self.assertIn(
            '^/tmp/rdma_xtr_v1_ref\\.[A-Za-z0-9]{6}$$', recipe
        )


class ReferenceEncodingTest(unittest.TestCase):
    def make_reference_image(self, byte_count: int):
        image_type = getattr(CHECKER, "ReferenceImage", bytearray)
        return image_type(byte_count)

    def require_checker_attribute(self, name: str):
        self.assertTrue(hasattr(CHECKER, name), f"checker has no {name}")
        return getattr(CHECKER, name)

    def test_absolute_offsets_use_big_endian_driver_qwords(self) -> None:
        image = self.make_reference_image(16)
        CHECKER.put_field(image, 16, 21, 0x15555)
        self.assertEqual(bytes(image[:8]), bytes.fromhex("0000000155550000"))

    def test_overflow_is_fatal(self) -> None:
        with self.assertRaisesRegex(CHECKER.ValidationError, "does not fit"):
            CHECKER.put_field(self.make_reference_image(8), 0, 4, 0x10)

    def test_zero_write_reserves_the_full_field_range(self) -> None:
        image = self.make_reference_image(8)
        CHECKER.put_field(image, 0, 8, 0)
        with self.assertRaisesRegex(CHECKER.ValidationError, "overlap"):
            CHECKER.put_field(image, 0, 8, 1)

    def test_partial_zero_overlap_is_fatal_and_atomic(self) -> None:
        image = self.make_reference_image(8)
        CHECKER.put_field(image, 0, 8, 0)
        payload_before = bytes(image)
        occupancy_before = tuple(getattr(image, "occupancy", ()))

        with self.assertRaisesRegex(CHECKER.ValidationError, "overlap"):
            CHECKER.put_field(image, 4, 8, 0xAB)

        self.assertEqual(bytes(image), payload_before)
        self.assertEqual(tuple(image.occupancy), occupancy_before)

    def test_nonoverlap_width64_and_endian_behavior_is_preserved(self) -> None:
        image = self.make_reference_image(16)
        CHECKER.put_field(image, 0, 4, 0xA)
        CHECKER.put_field(image, 4, 4, 0xB)
        CHECKER.put_field(image, 64, 64, 0x0123456789ABCDEF)
        self.assertEqual(bytes(image[:8]), bytes.fromhex("00000000000000ba"))
        self.assertEqual(bytes(image[8:]), bytes.fromhex("0123456789abcdef"))

    def test_plain_bytearray_cannot_bypass_occupancy_tracking(self) -> None:
        with self.assertRaisesRegex(CHECKER.ValidationError, "occupancy"):
            CHECKER.put_field(bytearray(8), 0, 8, 0)

    def test_reference_encoder_is_independent_of_sv_mapping_placement(self) -> None:
        expected = CHECKER.build_golden_cases()
        saved_mappings = CHECKER.FIELD_MAPPINGS
        had_legacy_lookup = hasattr(CHECKER, "FIELD_BY_STEM")
        saved_lookup = getattr(CHECKER, "FIELD_BY_STEM", None)
        try:
            CHECKER.FIELD_MAPPINGS = ()
            if had_legacy_lookup:
                CHECKER.FIELD_BY_STEM = {}
            try:
                actual = CHECKER.build_golden_cases()
            except (KeyError, CHECKER.ValidationError) as error:
                self.fail(f"golden encoder consulted SV mapping placement: {error}")
        finally:
            CHECKER.FIELD_MAPPINGS = saved_mappings
            if had_legacy_lookup:
                CHECKER.FIELD_BY_STEM = saved_lookup
        self.assertEqual(actual, expected)

    def test_reference_validation_rejects_missing_duplicate_and_drift(self) -> None:
        references = self.require_checker_attribute("REFERENCE_FIELDS")
        validate_references = self.require_checker_attribute(
            "validate_reference_fields"
        )
        first = references[0]

        with self.subTest("duplicate"):
            with self.assertRaisesRegex(CHECKER.ValidationError, "duplicate"):
                validate_references(references + (first,), CHECKER.FIELD_MAPPINGS)

        with self.subTest("missing mapping"):
            mappings_without_first = tuple(
                mapping for mapping in CHECKER.FIELD_MAPPINGS
                if mapping.sv_stem != first.sv_stem
            )
            with self.assertRaisesRegex(CHECKER.ValidationError, "missing"):
                validate_references(references, mappings_without_first)

        with self.subTest("byte offset mismatch"):
            drifted = first._replace(
                word_byte_offset=first.word_byte_offset + 8
            )
            with self.assertRaisesRegex(
                CHECKER.ValidationError, "byte offset mismatch"
            ):
                validate_references(
                    (drifted,) + references[1:], CHECKER.FIELD_MAPPINGS
                )

    def test_every_golden_field_has_explicit_reference_placement(self) -> None:
        references = self.require_checker_attribute("REFERENCE_FIELDS")
        reference_stems = [reference.sv_stem for reference in references]
        self.assertEqual(len(set(reference_stems)), len(references))
        for reference in references:
            with self.subTest(stem=reference.sv_stem):
                self.assertGreaterEqual(reference.word_byte_offset, 0)
                self.assertGreaterEqual(reference.lsb, 0)
                self.assertGreaterEqual(reference.width, 1)
                self.assertLessEqual(reference.lsb + reference.width, 64)
                self.assertNotEqual((reference.lsb, reference.width), (0, 0))

        used_stems = []
        original_put_named = CHECKER.put_named

        def record_put_named(image, stem, value):
            used_stems.append(stem)
            original_put_named(image, stem, value)

        try:
            CHECKER.put_named = record_put_named
            CHECKER.build_golden_cases()
        finally:
            CHECKER.put_named = original_put_named
        self.assertGreater(len(used_stems), 95)
        self.assertEqual(set(used_stems), set(reference_stems))

    def test_reference_cases_have_stable_contract(self) -> None:
        cases = CHECKER.build_golden_cases()
        context_cases = cases["context"]
        self.assertEqual(
            [case.name for case in context_cases],
            [
                "qpc_rc_boundary",
                "qpc_ud_boundary",
                "qpc_urc_boundary",
                "cqc_create_body_boundary",
                "mrt_register_pbl0_boundary",
                "mrt_register_pbl1_boundary",
                "mrt_register_pbl2_boundary",
                "mrt_key_alloc_pbl0_boundary",
                "srqc_create_body_boundary",
                "ceqc_create_body_boundary",
                "aeqc_create_body_boundary",
            ],
        )
        self.assertEqual(
            [len(case.payload) for case in context_cases],
            [512, 512, 512] + [64] * 8,
        )
        self.assertEqual(len(cases["cmq"][0].payload), 64)
        self.assertEqual(len(cases["queue"][0].payload), 64)
        self.assertEqual(len(cases["doorbell"][0].payload), 8)
        self.assertEqual(
            context_cases[0].payload[:8],
            bytes.fromhex("605abc615555a500"),
        )

    def test_context_case_summaries_are_an_immutable_input_contract(self) -> None:
        context_cases = CHECKER.build_golden_cases()["context"]
        self.assertEqual(CHECKER.GoldenCase._fields, ("name", "inputs", "payload"))
        for case in context_cases:
            with self.subTest(case=case.name):
                self.assertIsInstance(case.inputs, tuple)
                self.assertTrue(case.inputs)
                self.assertEqual(
                    CHECKER.parse_input_summary(case.summary), case.inputs
                )
                with self.assertRaises(AttributeError):
                    case.summary = "drift"
        summaries = [case.summary for case in context_cases]
        self.assertEqual(summaries, [
            "transport=rc,tver=1,mig=1,host=5,vf=0xabc,icos=3,qpn=0x15555,stat_idx=0xa5,pkey=0xbeef,shadow_pba=0x123456789ab,tx_swap=1,rx_swap=1,sq_ce=1,ra_fence=1,aa_fence=1,fc=1,state=3,pmtu=5,retry_count=7,rnr_retry=7,qp_sn=0xc3,srfq=1,srfqn=0x4567,pd=0xa55a,access=0x1f,dst_qpn=0x654321,dmac=0x112233445566,vlan_id=0xabc,flow=0xabcde,dscp=0x2a,ecn=2,hop=0x40,udp_sport=0xc123,send_psn=0xabcdef,recv_psn=0x123456,sq_pba=0x123456789abcd,sq_size=11,sq_om=2,sq_cqn=0xabcde,rq_cqn=0x54321,rq_pba=0x0fedcba987654,rq_size=10,rq_om=1",
            "transport=ud,tver=1,mig=0,host=6,vf=0x345,icos=5,qpn=0x2aaaa,stat_idx=0x5a,qkey=0x89abcdef,pkey=0x1234,shadow_pba=0x0fedcba9876,tx_swap=1,rx_swap=1,state=3,pmtu=4,qp_sn=0x7e,pd=0x5aa5,vlan=1,ipv6=1,tunnel=1,lag=1,fwd=2,dst_vport=0x456,src_addr=0xabc,dst_port=0xb,dst_qpn=0xabcdef,dmac=0xa1b2c3d4e5f6,pri=5,cfi=1,vlan_id=0x789,src_vport=0x345,flow=0x54321,dscp=0x2b,ecn=0,hop=0x7f,udp_sport=0xbeef,dest_ip=20010db8000000000000000000000001,sq_pba=0x1111122222333,sq_size=9,sq_om=3,sq_cqn=0x13579,rq_cqn=0x2468a,rq_pba=0x4444455555666,rq_size=8,rq_om=2",
            "transport=urc,tver=1,mig=1,host=7,vf=0x789,icos=7,qpn=0x3ffff,stat_idx=0xff,rsq_pba=0x123456789abcd,pkey=0xabcd,shadow_pba=0x123456789ab,state=3,pmtu=5,qp_sn=0xfe,pd=0xffff,rdsq_pba=0x23456789abcde,rdsq_size=7,tx_rbsn=0xabcdef,tx_dbsn=0x654321,rx_rbsn=0x123456,rx_dbsn=0xfedcba,rx_srbsn=0x345678,cur_dpsn=0x456789,cur_rpsn=0x56789a,rxed_dbsn=0x6789ab,rq_se_th=0xf,sq_ce_th=0xe,tx_srbsn=0x789abc,max_tx_srbsn=0x89abcd,dsq_pba=0x3456789abcdef,tpe_rpsn_max=0x9abcde,tpe_dpsn_max=0xabcdef,dsq_fetch=0x3f,sq_pba=0x456789abcdef0,sq_size=0xf,sq_om=3,sq_cqn=0xfffff,rq_cqn=0xabcde,rq_pba=0x56789abcdef01,rq_size=0xe,rq_om=2",
            "cqn=0x1fffff,sd_pba=0xfffffffffffff,size=0x1f,urc=1,state=3,next_hi=0xff,cur_valid=1,cur_pba=0xfffffffffffff,load_ci=1,threshold=7,mode=3,next_valid=1,next_lo=0xfffffffffff,pi=0x7fffff,pi_wrap=1,last_arm=3,cqe_size=3,ceqn=0xfff,shadow=0x3ffffffffffffff,ci=0x7fffff,ci_wrap=1,arm_sn=3,arm_state=3",
            "opcode=mr_register,stag=0xffffff,state=3,key=0xff,parent=0,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=3,host_page=3,pbl=0,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,pba0=0xfffffffffffff,mr_sn=0xfff",
            "opcode=mr_register,stag=0xffffff,state=3,key=0xff,parent=0,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=3,host_page=3,pbl=1,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,pba0=0xfffffffffffff,pba1=0xfffffffffffff,mr_sn=0xfff",
            "opcode=mr_register,stag=0xffffff,state=3,key=0xff,parent=0,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=3,host_page=3,pbl=2,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,first_pbl=0xfffffff,mr_sn=0xfff",
            "opcode=key_alloc,stag=0xffffff,state=3,key=0xff,parent=self,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=3,host_page=3,pbl=0,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,pba0=0xfffffffffffff,mr_sn=0xfff",
            "srfqn=0xffff,state=3,load_pi=0xff,shadow=0xfffffffffffff,pd=0xffff,pba=0xfffffffffffff,size=0xf,mode=3,pi_wrap=1,pi=0x7fff,limit=0x3fff,arm_sn=3",
            "eqn=0xfff,state=3,size=0x1f,next=0xfffffffffffff,current=0xfffffffffffff,current_valid=1,pi_wrap=1,pi=0x3ffff,mode=3,msix=0xffff,ci_wrap=1,ci=0x3ffff",
            "eqn=0xfff,state=3,size=0x1f,next=0xfffffffffffff,current=0xfffffffffffff,current_valid=1,pi_wrap=1,pi=0x3ffff,mode=3,msix=0xffff,ci_wrap=1,ci=0x3ffff",
        ])

    def test_body_masks_are_independent_exact_and_envelope_disjoint(self) -> None:
        masks = self.require_checker_attribute("BODY_MASKS")
        expected = {
            "cqc_create": (0x00000000001fffff, 0xff0fffffffffffff,
                0xfffffffffffff8ff, 0xfffffffffff8c701,
                0xf000000000ffffff, 0x0000000000000fff,
                0xffffffffffffffc0, 0x0000000f00ffffff),
            "mrt_register_pbl0": (0x6000000000ffffff, 0x00000000ff000000,
                0xffffffffff000000, 0xff00bfffffffffff,
                0xffffffffffffffff, 0xfffffffffffff000,
                0x0000000000000fff, 0),
            "mrt_key_alloc_pbl0": (0x6000000000ffffff, 0x00000000ff000000,
                0xffffffffffffffff, 0xff00bfffffffffff,
                0xffffffffffffffff, 0xfffffffffffff000,
                0x0000000000000fff, 0),
            "mrt_register_pbl1": (0x6000000000ffffff, 0x00000000ff000000,
                0xffffffffff000000, 0xff00bfffffffffff,
                0xffffffffffffffff, 0xfffffffffffff000,
                0xffffffffffffffff, 0),
            "mrt_register_pbl2": (0x6000000000ffffff, 0x00000000ff000000,
                0xffffffffff000000, 0xff00bfffffffffff,
                0xffffffffffffffff, 0xfffffff000000000,
                0x0000000000000fff, 0),
            "srqc_create": (0x000000000000ffff, 0,
                0xcfffffffffffffff, 0xffff000000000000,
                0xfffffffffffff0fc, 0x00000000ffffffff, 0, 0),
            "ceqc_create": (0x0000000000000fff, 0,
                0xc1ffffffffffffff, 0xfffffffffffff800,
                0x0000007ffff0c000, 0xffff00000007ffff, 0, 0),
            "aeqc_create": (0x0000000000000fff, 0,
                0xc1ffffffffffffff, 0xfffffffffffff800,
                0x0000007ffff0c000, 0xffff00000007ffff, 0, 0),
        }
        self.assertEqual(masks, expected)
        envelope = (0x8fff3fff00000000,) + (0,) * 7
        self.assertEqual(CHECKER.ENVELOPE_MASK, envelope)
        for key, body_mask in masks.items():
            with self.subTest(key=key):
                self.assertTrue(all((a & b) == 0 for a, b in zip(envelope, body_mask)))

    def test_context_goldens_obey_body_masks_and_coordinate_translations(self) -> None:
        validate = self.require_checker_attribute("validate_context_contract")
        validate(CHECKER.build_golden_cases()["context"])
        translations = self.require_checker_attribute("BODY_TRANSLATIONS")
        validate_translations = self.require_checker_attribute(
            "validate_body_translations"
        )
        validate_translations(translations, CHECKER.FIELD_MAPPINGS)
        translated_stems = {translation.sv_stem for translation in translations}
        expected_stems = {
            mapping.sv_stem
            for mapping in CHECKER.FIELD_MAPPINGS
            if ((mapping.path == "cq.h" and mapping.sv_stem.startswith("XTR_V1_CQC_BODY_"))
                or (mapping.path == "srq.h" and mapping.sv_stem.startswith("XTR_V1_SRQC_BODY_"))
                or (mapping.path == "event.h" and mapping.sv_stem.startswith("XTR_V1_EQC_BODY_")))
        }
        self.assertEqual(translated_stems, expected_stems)

        drifted = translations[0]._replace(
            local_word_byte_offset=translations[0].local_word_byte_offset + 8
        )
        with self.assertRaisesRegex(CHECKER.ValidationError, "translation"):
            validate_translations(
                (drifted,) + translations[1:], CHECKER.FIELD_MAPPINGS
            )

    def test_strict_golden_parser_rejects_all_structural_drift(self) -> None:
        parser = self.require_checker_attribute("parse_golden_text")
        rendered = CHECKER.render_golden(CHECKER.build_golden_cases()["context"])
        parsed = parser(rendered)
        self.assertEqual(parsed, CHECKER.build_golden_cases()["context"])
        corruptions = {
            "duplicate": rendered + rendered,
            "malformed byte": rendered.replace("60 5a", "gg 5a", 1),
            "truncated": rendered.rsplit(" ", 1)[0] + "\n",
            "extra": rendered.replace("\n\n# xtr", " 00\n\n# xtr", 1),
            "trailing": rendered + "# xtr_v1-golden-v1\n",
            "uppercase case": rendered.replace(
                "# case: qpc_rc_boundary", "# case: Qpc_rc_boundary", 1
            ),
            "duplicate input": rendered.replace(
                "# inputs: transport=rc,", "# inputs: transport=rc,transport=ud,", 1
            ),
        }
        for name, text in corruptions.items():
            with self.subTest(name=name):
                with self.assertRaises(CHECKER.ValidationError):
                    parser(text)

    def test_qpc_sq_fields_use_driver_qword_at_byte_216(self) -> None:
        offsets = {
            mapping.sv_stem: mapping.word_byte_offset
            for mapping in CHECKER.FIELD_MAPPINGS
        }
        for stem in (
            "XTR_V1_QPC_SQ_PBA",
            "XTR_V1_QPC_SQ_SIZE",
            "XTR_V1_QPC_SQ_OM",
        ):
            with self.subTest(stem=stem):
                self.assertEqual(offsets[stem], 216)

        qpc = CHECKER.build_golden_cases()["context"][0].payload
        self.assertEqual(qpc[216:224], bytes.fromhex("123456789abcdb80"))

    def test_golden_summaries_list_every_participating_input(self) -> None:
        cases = CHECKER.build_golden_cases()
        summaries = {
            case.name: case.summary
            for case_group in cases.values()
            for case in case_group
            if case_group is not cases["context"]
        }
        self.assertEqual(
            summaries,
            {
                "qpc_create":
                    "opcode=0,qpn=0x654321,index=27,valid=1,"
                    "vfid_override=1,use_vfid=0x345,wrap=1,sq_cqn=0x15555,"
                    "sign=1,rq_cqn=0xaaaa,buffer=0x123456789ab",
                "sqe_rc_boundary":
                    "qpn=0x15555,opcode=13,index=0x4567,rkey=0xdeadbeef,"
                    "icos=5,qp_sn=0xa6,dst_port=11,wrap=1,sign=1,se=1,"
                    "fence=2,ce=2,valid=1,signature=0xc7,sge_num=4,"
                    "remote_va=0x0123456789abcdef",
                "rqe_boundary":
                    "qpn=0xabcde,index=0x3456,payload=0x10203040,"
                    "qp_sn=0x5a,opcode=9,wrap=1,valid=1,signature=0x96,"
                    "sge_num=2",
                "cqe_error":
                    "qpn=0x2aaaa,index=0x4567,ecode=0xf4,"
                    "payload=0x10203040,polarity=1,rq_cqe=1,wrap=1,"
                    "packet_opcode=0x9a,immediate=0x89abcdef",
                "ceqe_error":
                    "qpn=0x15555,cqn=0x1aaaaa,ecode=0xf4,pi=0xbeef,"
                    "valid=1,packet_opcode=0x9a,wrap=1",
                "aeqe_error":
                    "qpn=0x2aaaa,state=5,ecode=0xff,index=0x654321,"
                    "valid=1,packet_opcode=0x81,wrap=1",
                "cmq_sq": "pi=27,polarity=1,offset=0x0",
                "rq": "qpn=0x15555,icos=5,pi=0x4567,wrap=1,offset=0x10",
                "cq":
                    "cqn=0x15555,host=5,ci=0x654321,wrap=1,arm=1,"
                    "arm_state=2,arm_sn=3,offset=0x18",
            },
        )


if __name__ == "__main__":
    unittest.main()
