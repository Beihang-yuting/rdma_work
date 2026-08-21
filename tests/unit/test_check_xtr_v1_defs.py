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

    def test_explicit_values_are_decoded_without_eval(self) -> None:
        self.assertEqual(CHECKER.parse_value_expression("0x35"), 0x35)
        self.assertEqual(CHECKER.parse_value_expression("12"), 12)
        with self.assertRaisesRegex(CHECKER.ValidationError, "unsupported"):
            CHECKER.parse_value_expression("PREVIOUS + 1")


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

    def test_field_declaration_expands_to_auditable_coordinates(self) -> None:
        constants = CHECKER.parse_sv_constants(
            "`XTR_V1_FIELD(XTR_V1_QPC_QPN, 0, 16, 21)\n"
        )
        self.assertEqual(constants["XTR_V1_QPC_QPN_WORD_BYTE_OFFSET"], 0)
        self.assertEqual(constants["XTR_V1_QPC_QPN_LSB"], 16)
        self.assertEqual(constants["XTR_V1_QPC_QPN_WIDTH"], 21)
        self.assertEqual(constants["XTR_V1_QPC_QPN_OFFSET"], 16)


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
        self.assertEqual(len(references), 95)
        reference_stems = [reference.sv_stem for reference in references]
        self.assertEqual(len(set(reference_stems)), 95)
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
        self.assertEqual(len(used_stems), 95)
        self.assertEqual(set(used_stems), set(reference_stems))

    def test_reference_cases_have_stable_contract(self) -> None:
        cases = CHECKER.build_golden_cases()
        self.assertEqual(cases["context"][0].name, "qpc_common_boundary")
        self.assertEqual(len(cases["context"][0].payload), 512)
        self.assertEqual(len(cases["cmq"][0].payload), 64)
        self.assertEqual(len(cases["queue"][0].payload), 64)
        self.assertEqual(len(cases["doorbell"][0].payload), 8)
        self.assertEqual(
            cases["context"][0].payload[:8],
            bytes.fromhex("ac5abca15555a55a"),
        )

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
        }
        self.assertEqual(
            summaries,
            {
                "qpc_common_boundary":
                    "tver=2,mig=1,service=ud,host=5,vf=0xabc,icos=5,"
                    "qpn=0x15555,stat_idx=0xa5,ud_qkey_h=0x5a,pkey=0xbeef,"
                    "tx_endian_swap=1,rx_endian_swap=1,qp_state=5,pmtu=6,"
                    "qp_sn=0xc3,pd_idx=0xa55a,sq_pba=0x123456789abcd,"
                    "sq_size=11,sq_om=2",
                "cqc_boundary":
                    "sd_pba=0x123456789abcd,size=27,urc=1,state=2",
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
