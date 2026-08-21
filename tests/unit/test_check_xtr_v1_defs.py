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
    def test_absolute_offsets_use_big_endian_driver_qwords(self) -> None:
        image = bytearray(16)
        CHECKER.put_field(image, 16, 21, 0x15555)
        self.assertEqual(bytes(image[:8]), bytes.fromhex("0000000155550000"))

    def test_overflow_is_fatal(self) -> None:
        with self.assertRaisesRegex(CHECKER.ValidationError, "does not fit"):
            CHECKER.put_field(bytearray(8), 0, 4, 0x10)

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


if __name__ == "__main__":
    unittest.main()
