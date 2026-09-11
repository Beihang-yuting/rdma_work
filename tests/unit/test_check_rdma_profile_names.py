#!/usr/bin/env python3
"""Focused tests for the rdma definition checker/reference encoder."""

from __future__ import annotations

import ast
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "tools" / "check_rdma_profile_names.py"
SPEC = importlib.util.spec_from_file_location("check_rdma_profile_names", CHECKER_PATH)
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


class ErrorCodeMappingTest(unittest.TestCase):
    SOURCES = {
        "defs.h": """
#define EC_FIRST 0x02
#define EC_SHARED 0x08
""",
        "wr.h": """
#define XTRDMA_CQE_ECODE GENMASK(31, 24)
enum xtrdma_cqe_ecode {
    XTRDMA_CQE_ECODE_TX_REQ_NML = 0,
    XTRDMA_CQE_ECODE_SQ_FLUSH_ERR = 0x08,
    XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT = 0xf0,
};
""",
    }
    SOURCE_VALUES = {
        ("defs.h", "EC_FIRST"): 0x02,
        ("defs.h", "EC_SHARED"): 0x08,
        ("wr.h", "XTRDMA_CQE_ECODE_TX_REQ_NML"): 0x00,
        ("wr.h", "XTRDMA_CQE_ECODE_SQ_FLUSH_ERR"): 0x08,
        (
            "wr.h",
            "XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT",
        ): 0xF0,
    }
    EXPECTED_ALIASES = (
        (
            ("defs.h", "EC_SHARED"),
            ("wr.h", "XTRDMA_CQE_ECODE_SQ_FLUSH_ERR"),
        ),
    )

    def require_checker_attribute(self, name: str):
        self.assertTrue(
            hasattr(CHECKER, name), f"checker API missing: {name}"
        )
        return getattr(CHECKER, name)

    def mappings(self):
        mapping_type = self.require_checker_attribute("ErrorCodeMapping")
        return tuple(
            mapping_type(path, symbol, f"RDMA_ECODE_{symbol}")
            for path, symbol in self.SOURCE_VALUES
        )

    def sv_text(self, overrides=None, extra: str = "") -> str:
        values = dict(self.SOURCE_VALUES)
        if overrides is not None:
            values.update(overrides)
        declarations = []
        for (_, symbol), value in values.items():
            declarations.append(
                f"localparam bit [7:0] RDMA_ECODE_{symbol} = 8'h{value:02x};"
            )
        declarations.append(
            "localparam bit [7:0] RDMA_CMQ_SUCCESS_ECODE = 8'h00;"
        )
        if extra:
            declarations.append(extra)
        return "\n".join(declarations)

    def validate_fixture(self, sources=None, sv_text=None, mappings=None):
        validate = self.require_checker_attribute(
            "validate_error_code_mappings"
        )
        return validate(
            self.mappings() if mappings is None else mappings,
            self.SOURCES if sources is None else sources,
            self.sv_text() if sv_text is None else sv_text,
        )

    def canonical_fixture(self):
        canonicalize = self.require_checker_attribute(
            "canonical_error_code_mappings"
        )
        mappings = self.mappings()
        values = self.validate_fixture(mappings=mappings)
        return canonicalize(mappings, values, self.EXPECTED_ALIASES)

    def codec_text(self) -> str:
        return """
`uvm_object_utils(rdma_hw_error_codec)
local function rdma_status_code_e classify(bit [7:0] hardware_code);
  case (hardware_code)
    RDMA_CMQ_SUCCESS_ECODE: return RDMA_SC_OK;
    RDMA_ECODE_EC_FIRST: return RDMA_SC_UNKNOWN_HW_ERROR;
    default: return RDMA_SC_UNKNOWN_HW_ERROR;
  endcase
endfunction
local function rdma_engine_kind_e inferred_engine(bit [7:0] hardware_code);
  case (hardware_code)
    RDMA_ECODE_EC_SHARED: return RDMA_ENGINE_CQ;
    default: return RDMA_ENGINE_CMQ;
  endcase
endfunction
local function string symbolic_name(bit [7:0] hardware_code);
  case (hardware_code)
    RDMA_CMQ_SUCCESS_ECODE: return "RDMA_CMQ_SUCCESS";
    RDMA_ECODE_EC_FIRST: return "EC_FIRST";
    RDMA_ECODE_EC_SHARED: return "EC_SHARED";
    RDMA_ECODE_XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT:
      return "XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT";
    default: return $sformatf("RDMA_UNKNOWN_ECODE_0x%02x", hardware_code);
  endcase
endfunction
function rdma_status_code_e decode_status(bit [7:0] hardware_code);
  rdma_status_code_e code;
  rdma_engine_kind_e source_engine;
  code = classify(hardware_code);
  source_engine = inferred_engine(hardware_code, code);
  candidate.message = symbolic_name(hardware_code);
  if (hardware_code == RDMA_CMQ_SUCCESS_ECODE) begin
    candidate.hardware_code = '0;
    return RDMA_SC_OK;
  end
  else begin
    candidate.hardware_code = {24'h0, hardware_code};
    return code;
  end
endfunction
"""

    def test_source_discovery_rejects_missing_and_extra_mapping(self) -> None:
        mappings = self.mappings()
        self.validate_fixture(mappings=mappings)

        with self.assertRaisesRegex(
            CHECKER.ValidationError, "missing error code mapping"
        ):
            self.validate_fixture(mappings=mappings[:-1])

        mapping_type = self.require_checker_attribute("ErrorCodeMapping")
        extra = mapping_type(
            "defs.h", "EC_GHOST", "RDMA_ECODE_EC_GHOST"
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "extra error code mapping"
        ):
            self.validate_fixture(mappings=mappings + (extra,))

    def test_mapping_identity_and_sv_names_must_be_unique(self) -> None:
        mappings = self.mappings()
        duplicate_identity = mappings[0]._replace(
            sv_name="RDMA_ECODE_DUPLICATE_IDENTITY"
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "duplicate error code source identity"
        ):
            self.validate_fixture(mappings=mappings + (duplicate_identity,))

        duplicate_sv_name = mappings[0]._replace(
            path=mappings[1].path,
            c_symbol=mappings[1].c_symbol,
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "duplicate error code SV name"
        ):
            self.validate_fixture(
                mappings=mappings[:1] + (duplicate_sv_name,) + mappings[2:]
            )

    def test_source_and_sv_constant_value_drift_are_rejected(self) -> None:
        drifted_sources = dict(self.SOURCES)
        drifted_sources["defs.h"] = drifted_sources["defs.h"].replace(
            "EC_FIRST 0x02", "EC_FIRST 0x03"
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "SV error code mismatch.*EC_FIRST"
        ):
            self.validate_fixture(sources=drifted_sources)

        with self.assertRaisesRegex(
            CHECKER.ValidationError, "SV error code mismatch.*EC_FIRST"
        ):
            self.validate_fixture(
                sv_text=self.sv_text(
                    {("defs.h", "EC_FIRST"): 0x03}
                )
            )

    def test_sv_error_constants_are_exact_and_eight_bits(self) -> None:
        missing = self.sv_text().replace(
            "localparam bit [7:0] RDMA_ECODE_EC_FIRST = 8'h02;", ""
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "missing SV error code constant"
        ):
            self.validate_fixture(sv_text=missing)

        extra = (
            "localparam bit [7:0] RDMA_ECODE_EC_GHOST = 8'h03;"
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "extra SV error code constant"
        ):
            self.validate_fixture(sv_text=self.sv_text(extra=extra))

        for alternate_extra in (
            "localparam logic [7:0] RDMA_ECODE_EC_GHOST = 8'h03;",
            "parameter bit [7:0] RDMA_ECODE_EC_GHOST = 8'h03;",
            "localparam byte unsigned RDMA_ECODE_EC_GHOST = 8'h03;",
        ):
            with self.subTest(alternate_extra=alternate_extra):
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "extra SV error code constant"
                ):
                    self.validate_fixture(
                        sv_text=self.sv_text(extra=alternate_extra)
                    )

        wrong_width = self.sv_text().replace(
            "bit [7:0] RDMA_ECODE_EC_FIRST",
            "bit [15:0] RDMA_ECODE_EC_FIRST",
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "must be declared bit \\[7:0\\]"
        ):
            self.validate_fixture(sv_text=wrong_width)

        commented = self.sv_text().replace(
            "localparam bit [7:0] RDMA_ECODE_EC_FIRST = 8'h02;",
            "// localparam bit [7:0] RDMA_ECODE_EC_FIRST = 8'h02;",
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "missing SV error code constant"
        ):
            self.validate_fixture(sv_text=commented)

    def test_sv_error_constant_alternate_duplicate_is_rejected(self) -> None:
        duplicate = (
            "typedef enum bit [7:0] { RDMA_ECODE_EC_FIRST } "
            "rdma_ghost_e;"
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "must have one canonical definition"
        ):
            self.validate_fixture(sv_text=self.sv_text(extra=duplicate))

    def test_alias_set_and_defs_first_policy_are_explicit(self) -> None:
        canonical = self.canonical_fixture()
        self.assertEqual(canonical[0x08].path, "defs.h")
        self.assertEqual(canonical[0x08].c_symbol, "EC_SHARED")

        canonicalize = self.require_checker_attribute(
            "canonical_error_code_mappings"
        )
        mappings = self.mappings()
        values = self.validate_fixture(mappings=mappings)
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "error code alias set drift"
        ):
            canonicalize(mappings, values, ())

    def test_fixed_mapping_is_complete_and_contains_wr_f0(self) -> None:
        mappings = self.require_checker_attribute("ERROR_CODE_MAPPINGS")
        identities = {(row.path, row.c_symbol) for row in mappings}
        self.assertEqual(len(mappings), 143)
        self.assertEqual(
            sum(row.path == "defs.h" for row in mappings), 133
        )
        self.assertEqual(sum(row.path == "wr.h" for row in mappings), 10)
        self.assertIn(
            (
                "wr.h",
                "XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT",
            ),
            identities,
        )

    def test_codec_symbolic_constant_and_string_drift_are_rejected(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        validate_codec(self.codec_text(), canonical)

        string_drift = self.codec_text().replace(
            'return "EC_FIRST";', 'return "EC_BROKEN";'
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "symbolic error code lookup"
        ):
            validate_codec(string_drift, canonical)

        constant_drift = self.codec_text().replace(
            'RDMA_ECODE_EC_FIRST: return "EC_FIRST";',
            'RDMA_ECODE_EC_SHARED: return "EC_FIRST";',
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "symbolic error code lookup"
        ):
            validate_codec(constant_drift, canonical)

        commented_function = self.codec_text()
        start = commented_function.index(
            "local function string symbolic_name"
        )
        end = commented_function.index("endfunction", start) + len(
            "endfunction"
        )
        commented_function = (
            commented_function[:start]
            + "/* "
            + commented_function[start:end]
            + " */"
            + commented_function[end:]
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "symbolic error code lookup function missing"
        ):
            validate_codec(commented_function, canonical)

    def test_codec_symbolic_unknown_default_is_exact(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        drifted_default = self.codec_text().replace(
            'default: return $sformatf("RDMA_UNKNOWN_ECODE_0x%02x", '
            'hardware_code);',
            'default: return "BOGUS";',
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "symbolic error code unknown default"
        ):
            validate_codec(drifted_default, canonical)

    def test_codec_symbolic_rejects_case_item_after_default(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        default = (
            '    default: return $sformatf("RDMA_UNKNOWN_ECODE_0x%02x", '
            "hardware_code);\n"
        )
        drifted = self.codec_text().replace(
            default,
            default + "    (8'hf1 - 1): return \"FORGED_F0\";\n",
        )
        self.assertNotEqual(drifted, self.codec_text())
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "symbolic error code unknown default"
        ):
            validate_codec(drifted, self.canonical_fixture())

    def test_codec_symbolic_lookup_rejects_unknown_specific_case(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        unknown_specific = self.codec_text().replace(
            'default: return $sformatf("RDMA_UNKNOWN_ECODE_0x%02x", '
            'hardware_code);',
            '8\'h42: return "NOT_THE_DEFAULT";\n'
            '    default: return $sformatf('
            '"RDMA_UNKNOWN_ECODE_0x%02x", hardware_code);',
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "symbolic error code lookup"
        ):
            validate_codec(unknown_specific, canonical)

    def test_codec_symbolic_rejects_case_external_unknown_return(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        early_return = self.codec_text().replace(
            "local function string symbolic_name(bit [7:0] hardware_code);\n",
            "local function string symbolic_name(bit [7:0] hardware_code);\n"
            "  if (hardware_code == 8'h42) return \"SPECIAL_UNKNOWN\";\n",
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "symbolic error code lookup"
        ):
            validate_codec(early_return, canonical)

    def test_codec_cannot_use_raw_literal_for_known_source_code(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        for literal in (
            "8'hf0", "8'd240", "8'b11110000", "8'o360",
            "8'shf0", "8'sb11110000", "8'so360",
        ):
            with self.subTest(literal=literal):
                raw_f0 = self.codec_text().replace(
                    "RDMA_ECODE_XTRDMA_CQE_ECODE_TX_EC_RCE_URC_"
                    "SQ_CPL_SRBM_DUP_PKT:",
                    f"{literal}:",
                )
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "raw literal.*known error code"
                ):
                    validate_codec(raw_f0, canonical)

    def test_codec_classify_rejects_case_external_known_code_returns(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        for condition in (
            "hardware_code == 16'h00f0",
            "hardware_code == 240",
            "hardware_code == (8'hf1 - 1)",
        ):
            with self.subTest(condition=condition):
                early_return = self.codec_text().replace(
                    "  case (hardware_code)\n",
                    f"  if ({condition}) return RDMA_SC_OK;\n"
                    "  case (hardware_code)\n",
                    1,
                )
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "classify|raw literal"
                ):
                    validate_codec(early_return, canonical)

    def test_codec_classify_rejects_case_item_after_default(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        drifted = self.codec_text().replace(
            "    default: return RDMA_SC_UNKNOWN_HW_ERROR;\n"
            "  endcase\n",
            "    default: return RDMA_SC_UNKNOWN_HW_ERROR;\n"
            "    (8'hf1 - 1): return RDMA_SC_OK;\n"
            "  endcase\n",
            1,
        )
        self.assertNotEqual(drifted, self.codec_text())
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "classify|case item|default"
        ):
            validate_codec(drifted, self.canonical_fixture())

    def test_codec_inferred_engine_rejects_external_known_code_returns(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        declaration = (
            "local function rdma_engine_kind_e inferred_engine("
            "bit [7:0] hardware_code);\n"
        )
        for condition in (
            "hardware_code == 240",
            "hardware_code == (8'hf1 - 1)",
            "hardware_code == (16'h00f0)",
        ):
            with self.subTest(condition=condition):
                early_return = self.codec_text().replace(
                    declaration,
                    declaration
                    + f"  if ({condition}) return RDMA_ENGINE_CQ;\n",
                )
                with self.assertRaisesRegex(
                    CHECKER.ValidationError,
                    "inferred_engine|hardware_code comparison",
                ):
                    validate_codec(early_return, canonical)

    def test_codec_inferred_engine_rejects_case_item_after_default(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        drifted = self.codec_text().replace(
            "    default: return RDMA_ENGINE_CMQ;\n",
            "    default: return RDMA_ENGINE_CMQ;\n"
            "    (8'hf1 - 1): return RDMA_ENGINE_CQ;\n",
            1,
        )
        self.assertNotEqual(drifted, self.codec_text())
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "inferred_engine|case item|default"
        ):
            validate_codec(drifted, self.canonical_fixture())

    def test_codec_other_function_rejects_known_code_expression(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        helper = """
local function bit raw_comparison_probe(bit [7:0] hardware_code);
  if (hardware_code == (8'hf1 - 1)) return 1'b1;
  return 1'b0;
endfunction
"""
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "hardware_code use"
        ):
            validate_codec(helper + self.codec_text(), canonical)

    def test_codec_decode_status_rejects_unapproved_hardware_code_uses(
        self,
    ) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        pinned_compare = (
            "  if (hardware_code == RDMA_CMQ_SUCCESS_ECODE) begin\n"
        )
        mutations = {
            "case equality": (
                "  if (hardware_code === 240) return RDMA_SC_OK;\n"
            ),
            "inequality else": """  if (hardware_code != 240)
    code = RDMA_SC_UNKNOWN_HW_ERROR;
  else
    return RDMA_SC_OK;
""",
            "part select": (
                "  if (hardware_code[7:0] == 240) return RDMA_SC_OK;\n"
            ),
            "arithmetic": (
                "  if ((hardware_code + 0) == 240) return RDMA_SC_OK;\n"
            ),
            "inside": (
                "  if (hardware_code inside {240}) return RDMA_SC_OK;\n"
            ),
        }
        for name, mutation in mutations.items():
            with self.subTest(name=name):
                bypass = self.codec_text().replace(
                    pinned_compare, mutation + pinned_compare
                )
                self.assertNotEqual(bypass, self.codec_text())
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "hardware_code use"
                ):
                    validate_codec(bypass, canonical)

    def test_codec_accepts_reverse_pinned_success_comparison(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        reverse = self.codec_text().replace(
            "hardware_code == RDMA_CMQ_SUCCESS_ECODE",
            "RDMA_CMQ_SUCCESS_ECODE == hardware_code",
        )
        try:
            validate_codec(reverse, self.canonical_fixture())
        except CHECKER.ValidationError as error:
            self.fail(f"reverse pinned success comparison was rejected: {error}")

    def test_codec_rejects_qualified_hardware_code_roles(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        mutations = {
            "classify callee": (
                "code = classify(hardware_code);",
                "code = other.classify(hardware_code);",
            ),
            "inferred callee": (
                "source_engine = inferred_engine(hardware_code, code);",
                "source_engine = other.inferred_engine(hardware_code, code);",
            ),
            "symbolic callee": (
                "candidate.message = symbolic_name(hardware_code);",
                "candidate.message = other.symbolic_name(hardware_code);",
            ),
            "zero assignment": (
                "candidate.hardware_code = '0;",
                "other.candidate.hardware_code = '0;",
            ),
            "extension assignment": (
                "candidate.hardware_code = {24'h0, hardware_code};",
                "other.candidate.hardware_code = {24'h0, hardware_code};",
            ),
        }
        for name, (valid, qualified) in mutations.items():
            with self.subTest(name=name):
                bypass = self.codec_text().replace(valid, qualified)
                self.assertNotEqual(bypass, self.codec_text())
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "hardware_code"
                ):
                    validate_codec(bypass, canonical)

    def test_codec_rejects_token_pasting_macro_bypass(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        pinned_compare = (
            "  if (hardware_code == RDMA_CMQ_SUCCESS_ECODE) begin\n"
        )
        macro_bypass = (
            "`define REVIEW_HC(a,b) a``b\n"
            + self.codec_text().replace(
                pinned_compare,
                "  if (`REVIEW_HC(hardware_,code) == 240) "
                "return RDMA_SC_OK;\n"
                + pinned_compare,
            )
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "preprocessor|macro"
        ):
            validate_codec(macro_bypass, self.canonical_fixture())

    def test_codec_preprocessor_audit_ignores_comments_and_strings(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        diagnostic = """
// `define REVIEW_HC(a,b) a``b
/* `REVIEW_HC(hardware_,code) */
string macro_text = "`REVIEW_HC(hardware_,code)";
""" + self.codec_text()
        try:
            validate_codec(diagnostic, self.canonical_fixture())
        except CHECKER.ValidationError as error:
            self.fail(f"comment/string backtick was parsed as code: {error}")

    def test_codec_raw_scan_ignores_quoted_diagnostic_text(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        diagnostic = (
            'string diagnostic = "diagnostic 8\'hf0 only";\n'
            + self.codec_text()
        )
        try:
            validate_codec(diagnostic, canonical)
        except CHECKER.ValidationError as error:
            self.fail(f"quoted raw literal was parsed as code: {error}")

    def test_codec_raw_scan_ignores_narrow_non_error_literals(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        narrow_literal = "bit diagnostic_flag = 1'b0;\n" + self.codec_text()
        try:
            validate_codec(narrow_literal, canonical)
        except CHECKER.ValidationError as error:
            self.fail(f"narrow non-error literal was rejected: {error}")

    def test_codec_raw_scan_ignores_wide_zero_extension_literals(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        extension = (
            "logic [31:0] diagnostic = {24'h0, 8'h42};\n"
            + self.codec_text()
        )
        try:
            validate_codec(extension, canonical)
        except CHECKER.ValidationError as error:
            self.fail(f"wide zero-extension literal was rejected: {error}")

    def test_codec_accepts_whitespace_in_based_literal(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        for literal in ("24 'h0", "24'h 0"):
            with self.subTest(literal=literal):
                spaced = self.codec_text().replace("24'h0", literal)
                self.assertNotEqual(spaced, self.codec_text())
                try:
                    validate_codec(spaced, self.canonical_fixture())
                except CHECKER.ValidationError as error:
                    self.fail(f"legal based-literal whitespace was rejected: {error}")

    def test_error_codec_uvm_test_checks_success_symbols(self) -> None:
        test_text = (
            REPO_ROOT / "tests" / "unit" /
            "rdma_error_codec_test.sv"
        ).read_text()
        start = test_text.index("function automatic void check_error")
        end = test_text.index("endfunction", start)
        check_error_body = test_text[start:end]
        self.assertRegex(
            check_error_body,
            re.compile(
                r"\n    end\n    if \(expected_symbol != \"\" && "
                r"decoded\.message != expected_symbol\)",
            ),
        )
        for label in ("ZERO_RETAINS_ENGINE", "ZERO_NONE_CANONICAL"):
            with self.subTest(label=label):
                self.assertRegex(
                    test_text,
                    re.compile(
                        rf'check_error\("{label}"[^;]*1\'b0,\s*'
                        r'"RDMA_CMQ_SUCCESS"\s*\);',
                        re.S,
                    ),
                )

    def test_sv_error_constant_cannot_be_forged_inside_string(self) -> None:
        declaration = (
            "localparam bit [7:0] RDMA_ECODE_EC_FIRST = 8'h02;"
        )
        forged = self.sv_text().replace(
            declaration,
            f'string forged = "{declaration}";',
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "missing SV error code constant"
        ):
            self.validate_fixture(sv_text=forged)

    def test_codec_requires_cmq_profile_symbol_for_zero_cases(self) -> None:
        validate_codec = self.require_checker_attribute(
            "validate_error_codec"
        )
        canonical = self.canonical_fixture()
        source_zero = self.codec_text().replace(
            "RDMA_CMQ_SUCCESS_ECODE: return RDMA_SC_OK;",
            "RDMA_ECODE_XTRDMA_CQE_ECODE_TX_REQ_NML: "
            "return RDMA_SC_OK;",
        )
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "hardware error case item"
        ):
            validate_codec(source_zero, canonical)

    def test_repo_f0_uses_source_pinned_constant_and_symbol(self) -> None:
        constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/rdma/rdma_defs.svh").read_text()
        )
        name = (
            "RDMA_ECODE_XTRDMA_CQE_ECODE_TX_EC_RCE_URC_"
            "SQ_CPL_SRBM_DUP_PKT"
        )
        self.assertEqual(constants.get(name), 0xF0)
        codec = (
            REPO_ROOT
            / "src/codec/rdma/rdma_error_codec.sv"
        ).read_text()
        self.assertRegex(codec, rf"\b{re.escape(name)}\s*:")
        self.assertNotRegex(codec, r"\b8'h[fF]0\s*:")


class SvDefinitionTest(unittest.TestCase):
    NEW_URC_FIELDS = {
        "RDMA_QPC_URC_RSQ_SIZE": (
            "XTRDMA_QPC_URC_RSQ_SIZE", 24, 59, 3, 251
        ),
        "RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM": (
            "XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM", 224, 16, 6, 1808
        ),
    }

    def test_duplicate_constant_is_fatal(self) -> None:
        text = """
localparam int unsigned RDMA_FIELD_OFFSET = 32;
localparam int unsigned RDMA_FIELD_OFFSET = 40;
"""
        with self.assertRaisesRegex(CHECKER.ValidationError, "duplicate"):
            CHECKER.parse_sv_constants(text)

    def test_sv_comment_stripping_preserves_quoted_markers(self) -> None:
        strip_comments = getattr(CHECKER, "strip_sv_comments", None)
        self.assertIsNotNone(strip_comments, "checker has no strip_sv_comments")
        stripped = strip_comments(
            'string url = "https://example.invalid/a/*literal*/";\n'
            '// localparam bit [7:0] RDMA_ECODE_LINE = 8\'h42;\n'
            '/* localparam bit [7:0] RDMA_ECODE_BLOCK = 8\'h43; */\n'
        )
        self.assertIn('"https://example.invalid/a/*literal*/"', stripped)
        self.assertNotIn("RDMA_ECODE_LINE", stripped)
        self.assertNotIn("RDMA_ECODE_BLOCK", stripped)

    def test_width_and_value_literals_are_parsed(self) -> None:
        constants = CHECKER.parse_sv_constants(
            """
localparam int unsigned RDMA_FIELD_WIDTH = 8;
localparam bit [7:0] RDMA_OP = 8'h35;
localparam bit [63:0] RDMA_WINDOW = 64'h2000;
"""
        )
        self.assertEqual(constants["RDMA_FIELD_WIDTH"], 8)
        self.assertEqual(constants["RDMA_OP"], 0x35)
        self.assertEqual(constants["RDMA_WINDOW"], 0x2000)

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

        colliding_value = first_value._replace(
            c_symbol="OTHER_CROSS_TABLE_VALUE",
            sv_name=f"{first_field.sv_stem}_OFFSET",
        )
        with self.assertRaisesRegex(CHECKER.ValidationError, "global SV constant"):
            validate(
                CHECKER.FIELD_MAPPINGS,
                CHECKER.VALUE_MAPPINGS + (colliding_value,),
                CHECKER.REFERENCE_FIELDS,
            )

        reference_stem = "RDMA_TEST_REFERENCE_COLLISION"
        colliding_reference = CHECKER.REFERENCE_FIELDS[0]._replace(
            c_symbol="OTHER_CROSS_TABLE_REFERENCE",
            sv_stem=reference_stem,
        )
        colliding_value = first_value._replace(
            c_symbol="OTHER_REFERENCE_VALUE",
            sv_name=f"{reference_stem}_OFFSET",
        )
        with self.assertRaisesRegex(CHECKER.ValidationError, "global SV constant"):
            validate(
                CHECKER.FIELD_MAPPINGS,
                CHECKER.VALUE_MAPPINGS + (colliding_value,),
                CHECKER.REFERENCE_FIELDS + (colliding_reference,),
            )

    def test_cmq_composer_does_not_retain_built_artifacts(self) -> None:
        source = (
            REPO_ROOT
            / "src/codec/rdma/rdma_cmq_codecs.sv"
        ).read_text()
        self.assertNotRegex(
            source,
            r"\bminted_(?:bodies|opcodes|snapshots)\s*\[\$\]",
        )

    def test_duplicate_source_symbol_at_another_offset_is_fatal(self) -> None:
        validate = CHECKER.validate_mapping_uniqueness
        first = next(
            mapping
            for mapping in CHECKER.FIELD_MAPPINGS
            if mapping.c_symbol != "XTRDMA_CMQSQ_WQE_MODIFY_DATA"
        )
        duplicate = first._replace(
            sv_stem="RDMA_TEST_DUPLICATE_SOURCE",
            word_byte_offset=first.word_byte_offset + 8,
        )
        with self.assertRaisesRegex(CHECKER.ValidationError, "source"):
            validate(
                CHECKER.FIELD_MAPPINGS + (duplicate,),
                CHECKER.VALUE_MAPPINGS,
                CHECKER.REFERENCE_FIELDS,
            )

    def test_unrelated_identical_source_duplicate_is_fatal(self) -> None:
        with self.assertRaisesRegex(CHECKER.ValidationError, "duplicated"):
            CHECKER.require_unique_expression(
                {"XTRDMA_SQ_WQE_QPN": ["GENMASK(20, 0)", "GENMASK(20, 0)"]},
                "XTRDMA_SQ_WQE_QPN",
                "wr.h",
            )

    def test_modify_data_source_exception_requires_exact_quartet(self) -> None:
        validate = CHECKER.validate_mapping_uniqueness
        symbol = "XTRDMA_CMQSQ_WQE_MODIFY_DATA"
        fields = tuple(
            mapping
            for mapping in CHECKER.FIELD_MAPPINGS
            if mapping.path == "cmq.h" and mapping.c_symbol == symbol
        )
        references = tuple(
            reference
            for reference in CHECKER.REFERENCE_FIELDS
            if reference.path == "cmq.h" and reference.c_symbol == symbol
        )

        validate(fields, (), references)
        for label, selected_fields, selected_references in (
            ("field missing", fields[:-1], references),
            ("reference missing", fields, references[:-1]),
        ):
            with self.subTest(label=label):
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "source"
                ):
                    validate(selected_fields, (), selected_references)

        extra_field = fields[0]._replace(
            sv_stem="RDMA_TEST_MODIFY_DATA4",
            word_byte_offset=64,
        )
        with self.assertRaisesRegex(CHECKER.ValidationError, "source"):
            validate(fields + (extra_field,), (), references)

    def test_field_declaration_expands_to_auditable_coordinates(self) -> None:
        constants = CHECKER.parse_sv_constants(
            "`RDMA_FIELD(RDMA_QPC_QPN, 0, 16, 21)\n"
        )
        self.assertEqual(constants["RDMA_QPC_QPN_WORD_BYTE_OFFSET"], 0)
        self.assertEqual(constants["RDMA_QPC_QPN_LSB"], 16)
        self.assertEqual(constants["RDMA_QPC_QPN_WIDTH"], 21)
        self.assertEqual(constants["RDMA_QPC_QPN_OFFSET"], 16)

    def test_new_urc_rows_match_source_reference_and_sv_coordinates(self) -> None:
        mappings = {mapping.sv_stem: mapping for mapping in CHECKER.FIELD_MAPPINGS}
        references = {
            reference.sv_stem: reference
            for reference in CHECKER.REFERENCE_FIELDS
        }
        sv_constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/rdma/rdma_defs.svh").read_text()
        )

        for stem, (c_symbol, byte_offset, lsb, width, offset) in \
                self.NEW_URC_FIELDS.items():
            with self.subTest(stem=stem):
                self.assertEqual(
                    mappings[stem],
                    CHECKER.FieldMapping("qp.h", c_symbol, stem, byte_offset),
                )
                self.assertEqual(
                    references[stem],
                    CHECKER.ReferenceField(
                        "qp.h", c_symbol, stem, byte_offset, lsb, width
                    ),
                )
                self.assertEqual(
                    {
                        "word_byte_offset": sv_constants[
                            f"{stem}_WORD_BYTE_OFFSET"
                        ],
                        "lsb": sv_constants[f"{stem}_LSB"],
                        "width": sv_constants[f"{stem}_WIDTH"],
                        "offset": sv_constants[f"{stem}_OFFSET"],
                    },
                    {
                        "word_byte_offset": byte_offset,
                        "lsb": lsb,
                        "width": width,
                        "offset": offset,
                    },
                )

    def test_new_urc_source_coordinate_drift_is_rejected(self) -> None:
        parsed_fields = {
            reference.sv_stem: (
                reference.path,
                reference.c_symbol,
                reference.lsb,
                reference.width,
            )
            for reference in CHECKER.REFERENCE_FIELDS
        }
        for stem in self.NEW_URC_FIELDS:
            with self.subTest(stem=stem):
                drifted = dict(parsed_fields)
                path, c_symbol, lsb, width = drifted[stem]
                drifted[stem] = (path, c_symbol, lsb ^ 1, width)
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "reference mask mismatch"
                ):
                    CHECKER.validate_reference_fields(
                        CHECKER.REFERENCE_FIELDS,
                        CHECKER.FIELD_MAPPINGS,
                        drifted,
                    )

    def test_new_urc_reference_coordinate_drift_is_rejected(self) -> None:
        parsed_fields = {
            reference.sv_stem: (
                reference.path,
                reference.c_symbol,
                reference.lsb,
                reference.width,
            )
            for reference in CHECKER.REFERENCE_FIELDS
        }
        for stem in self.NEW_URC_FIELDS:
            with self.subTest(stem=stem):
                references = list(CHECKER.REFERENCE_FIELDS)
                index = next(
                    index for index, reference in enumerate(references)
                    if reference.sv_stem == stem
                )
                references[index] = references[index]._replace(
                    lsb=references[index].lsb ^ 1
                )
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "reference mask mismatch"
                ):
                    CHECKER.validate_reference_fields(
                        tuple(references), CHECKER.FIELD_MAPPINGS, parsed_fields
                    )

    def test_new_urc_sv_constant_drift_is_rejected(self) -> None:
        validate_required = getattr(CHECKER, "validate_required_sv_constants")
        sv_constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/rdma/rdma_defs.svh").read_text()
        )
        for stem, (_, byte_offset, lsb, width, offset) in \
                self.NEW_URC_FIELDS.items():
            expected = {
                f"{stem}_WORD_BYTE_OFFSET": byte_offset,
                f"{stem}_LSB": lsb,
                f"{stem}_WIDTH": width,
                f"{stem}_OFFSET": offset,
            }
            with self.subTest(stem=stem):
                validate_required(sv_constants, expected)
                drifted = dict(sv_constants)
                drifted[f"{stem}_OFFSET"] ^= 1
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "SV constant mismatch"
                ):
                    validate_required(drifted, expected)

    def test_context_object_state_mode_and_right_values_are_mapped(self) -> None:
        mappings = {
            (mapping.path, mapping.c_symbol, mapping.sv_name)
            for mapping in CHECKER.VALUE_MAPPINGS
        }
        expected = {
            ("alloc.h", "XTRDMA_ALLOC_TYPE_DIRECT", "RDMA_ALLOC_TYPE_DIRECT"),
            ("alloc.h", "XTRDMA_ALLOC_TYPE_INDIRECT", "RDMA_ALLOC_TYPE_INDIRECT"),
            ("alloc.h", "XTRDMA_ALLOC_TYPE_HUGE", "RDMA_ALLOC_TYPE_HUGE"),
            ("alloc.h", "XTRDMA_ALLOC_TYPE_L3_INDIRECT", "RDMA_ALLOC_TYPE_L3_INDIRECT"),
            ("mr.h", "XTRDMA_ADDR_TYPE_VA_BASED", "RDMA_ADDR_TYPE_VA_BASED"),
            ("mr.h", "XTRDMA_ADDR_TYPE_ZERO_BASED", "RDMA_ADDR_TYPE_ZERO_BASED"),
            ("mr.h", "XTRDMA_MR_ST_INVLD", "RDMA_MR_ST_INVALID"),
            ("mr.h", "XTRDMA_MR_ST_FREE", "RDMA_MR_ST_FREE"),
            ("mr.h", "XTRDMA_MR_ST_VLD", "RDMA_MR_ST_VALID"),
            ("mr.h", "XTRDMA_HOST_PAGE_4K", "RDMA_HOST_PAGE_4K"),
            ("mr.h", "XTRDMA_HOST_PAGE_2M", "RDMA_HOST_PAGE_2M"),
            ("mr.h", "XTRDMA_HOST_PAGE_1G", "RDMA_HOST_PAGE_1G"),
            ("mr.h", "PBL_MODE_0", "RDMA_PBL_MODE_0"),
            ("mr.h", "PBL_MODE_1", "RDMA_PBL_MODE_1"),
            ("mr.h", "PBL_MODE_2", "RDMA_PBL_MODE_2"),
            ("mr.h", "XTRDMA_MR", "RDMA_MEM_TYPE_MR"),
            ("mr.h", "XTRDMA_MW_TYPE1", "RDMA_MEM_TYPE_MW_TYPE1"),
            ("mr.h", "XTRDMA_MW_TYPE2B", "RDMA_MEM_TYPE_MW_TYPE2B"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_LOCAL_WRITE", "RDMA_RIGHT_LOCAL_WRITE"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_REMOTE_READ", "RDMA_RIGHT_REMOTE_READ"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_REMOTE_WRITE", "RDMA_RIGHT_REMOTE_WRITE"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_BIND_WINDOW", "RDMA_RIGHT_BIND_WINDOW"),
            ("defs.h", "XTRDMA_ACCESS_FLAGS_REMOTE_ATOMIC", "RDMA_RIGHT_REMOTE_ATOMIC"),
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
        validate((REPO_ROOT / "src/codec/rdma/rdma_image_masks.svh").read_text())


class Task11DefinitionTest(unittest.TestCase):
    TASK11_FIELDS = {
        "RDMA_CMQ_NEXT_QP_STATE":
            ("XTRDMA_CMQSQ_WQE_NXT_QP_ST", 0, 60, 3),
        "RDMA_CMQ_MODIFY_MODE":
            ("XTRDMA_CMQSQ_WQE_MODIFY_MODE", 16, 62, 2),
        "RDMA_CMQ_MODIFY_START_QWORD0":
            ("XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD0", 16, 56, 6),
        "RDMA_CMQ_MODIFY_WBE0":
            ("XTRDMA_CMQSQ_WQE_MODIFY_WBE0", 16, 48, 8),
        "RDMA_CMQ_WBE_TEMPLATE_COUNT":
            ("XTRDMA_CMQSQ_WQE_WBE_TPL_NUM", 16, 46, 2),
        "RDMA_CMQ_MODIFY_START_QWORD1":
            ("XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD1", 16, 40, 6),
        "RDMA_CMQ_MODIFY_WBE1":
            ("XTRDMA_CMQSQ_WQE_MODIFY_WBE1", 16, 32, 8),
        "RDMA_CMQ_MODIFY_START_QWORD2":
            ("XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD2", 16, 24, 6),
        "RDMA_CMQ_MODIFY_WBE2":
            ("XTRDMA_CMQSQ_WQE_MODIFY_WBE2", 16, 16, 8),
        "RDMA_CMQ_MODIFY_START_QWORD3":
            ("XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD3", 16, 8, 6),
        "RDMA_CMQ_MODIFY_WBE3":
            ("XTRDMA_CMQSQ_WQE_MODIFY_WBE3", 16, 0, 8),
        "RDMA_CMQ_MODIFY_DATA0":
            ("XTRDMA_CMQSQ_WQE_MODIFY_DATA", 32, 0, 64),
        "RDMA_CMQ_MODIFY_DATA1":
            ("XTRDMA_CMQSQ_WQE_MODIFY_DATA", 40, 0, 64),
        "RDMA_CMQ_MODIFY_DATA2":
            ("XTRDMA_CMQSQ_WQE_MODIFY_DATA", 48, 0, 64),
        "RDMA_CMQ_MODIFY_DATA3":
            ("XTRDMA_CMQSQ_WQE_MODIFY_DATA", 56, 0, 64),
        "RDMA_CMQ_OCC_VF_FLUSH":
            ("XTRDMA_CMQSQ_OCC_FLUSH_VF_FLUSH", 0, 61, 1),
        "RDMA_CMQ_OCC_MR_SERIAL_FLUSH":
            ("XTRDMA_CMQSQ_OCC_FLUSH_MR_SN_FLUSH", 0, 60, 1),
        "RDMA_CMQ_OCC_QPN":
            ("XTRDMA_CMQSQ_OCC_FLUSH_QPN", 0, 0, 21),
        "RDMA_CMQ_OCC_QPC":
            ("XTRDMA_CMQSQ_OCC_FLUSH_QPC_FLAG", 8, 63, 1),
        "RDMA_CMQ_OCC_CQC":
            ("XTRDMA_CMQSQ_OCC_FLUSH_CQC_FLAG", 8, 62, 1),
        "RDMA_CMQ_OCC_MRT":
            ("XTRDMA_CMQSQ_OCC_FLUSH_MRT_FLAG", 8, 61, 1),
        "RDMA_CMQ_OCC_PBLE":
            ("XTRDMA_CMQSQ_OCC_FLUSH_PBLE_FLAG", 8, 60, 1),
        "RDMA_CMQ_OCC_SQRQE":
            ("XTRDMA_CMQSQ_OCC_FLUSH_SQRQE_FLAG", 8, 59, 1),
        "RDMA_CMQ_OCC_SGB_IRQE":
            ("XTRDMA_CMQSQ_OCC_FLUSH_SGB_IRQE_FLAG", 8, 58, 1),
        "RDMA_CMQ_OCC_EIRQE":
            ("XTRDMA_CMQSQ_OCC_FLUSH_EIRQE_FLAG", 8, 57, 1),
        "RDMA_CMQ_OCC_ORQE":
            ("XTRDMA_CMQSQ_OCC_FLUSH_ORQE_FLAG", 8, 56, 1),
        "RDMA_CMQ_OCC_UAQE":
            ("XTRDMA_CMQSQ_OCC_FLUSH_UAQE_FLAG", 8, 55, 1),
        "RDMA_CMQ_OCC_PD":
            ("XTRDMA_CMQSQ_OCC_FLUSH_PD_FLAG", 8, 54, 1),
        "RDMA_CMQ_OCC_MR_SERIAL":
            ("XTRDMA_CMQSQ_OCC_FLUSH_MR_SN", 8, 32, 12),
        "RDMA_CMQ_OCC_PD_BACKING":
            ("XTRDMA_CMQSQ_OCC_FLUSH_PD_PBA", 16, 12, 52),
    }

    EXPECTED_OWNERSHIP = {
        "RDMA_QPC_CREATE_BODY_OWNERSHIP": (
            0x0000000000FFFFFF, 0xFFFFF801FF1FFFFF,
            0x0000000000000000, 0xFFFFFFFFFFFFFE00, 0, 0, 0, 0,
        ),
        "RDMA_QPC_MODIFY_BODY_OWNERSHIP": (
            0x7000000000FFFFFF, 0xFFFFF801FF1FFFFF,
            0xFFFFFFFF3FFF3FFF, 0xFFFFFFFFFFFFFE00,
            0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
            0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
        ),
        "RDMA_QPC_DELETE_BODY_OWNERSHIP": (
            0x0000000000FFFFFF, 0xFFFFF800001FFFFF, 0, 0, 0, 0, 0, 0,
        ),
        "RDMA_QPC_QUERY_BODY_OWNERSHIP": (
            0x0000000000FFFFFF, 0, 0, 0xFFFFFFFFFFFFFE00, 0, 0, 0, 0,
        ),
        "RDMA_MRT_REGISTER_BODY_OWNERSHIP": (
            0x6000000000FFFFFF, 0x00000000FF000000,
            0xFFFFFFFFFF000000, 0xFF00BFFFFFFFFFFF,
            0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFF000,
            0xFFFFFFFFFFFFFFFF, 0,
        ),
        "RDMA_MRT_KEY_ALLOC_BODY_OWNERSHIP": (
            0x6000000000FFFFFF, 0x00000000FF000000,
            0xFFFFFFFFFFFFFFFF, 0xFF00BFFFFFFFFFFF,
            0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFF000,
            0xFFFFFFFFFFFFFFFF, 0,
        ),
        "RDMA_MR_DEREGISTER_BODY_OWNERSHIP": (
            0x6000000000FFFFFF, 0x00000000FF000000, 0, 0, 0, 0, 0, 0,
        ),
        "RDMA_OCC_FLUSH_BODY_OWNERSHIP": (
            0x30000000001FFFFF, 0xFFC00FFF00000000,
            0xFFFFFFFFFFFFF000, 0, 0, 0, 0, 0,
        ),
        "RDMA_CQ_OBJECT_ID_BODY_OWNERSHIP": (
            0x00000000001FFFFF, 0, 0, 0, 0, 0, 0, 0,
        ),
        "RDMA_EQ_OBJECT_ID_BODY_OWNERSHIP": (
            0x0000000000000FFF, 0, 0, 0, 0, 0, 0, 0,
        ),
        "RDMA_SRQ_OBJECT_ID_BODY_OWNERSHIP": (
            0x000000000000FFFF, 0, 0, 0, 0, 0, 0, 0,
        ),
        "RDMA_EMPTY_BODY_OWNERSHIP": (0, 0, 0, 0, 0, 0, 0, 0),
    }

    @staticmethod
    def parsed_reference_fields():
        return {
            reference.sv_stem: (
                reference.path,
                reference.c_symbol,
                reference.lsb,
                reference.width,
            )
            for reference in CHECKER.REFERENCE_FIELDS
        }

    def test_task11_rows_match_source_reference_and_sv_coordinates(self) -> None:
        mappings = {mapping.sv_stem: mapping for mapping in CHECKER.FIELD_MAPPINGS}
        references = {
            reference.sv_stem: reference
            for reference in CHECKER.REFERENCE_FIELDS
        }
        sv_constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/rdma/rdma_defs.svh").read_text()
        )
        for stem, (c_symbol, byte_offset, lsb, width) in self.TASK11_FIELDS.items():
            with self.subTest(stem=stem):
                self.assertEqual(
                    mappings[stem],
                    CHECKER.FieldMapping("cmq.h", c_symbol, stem, byte_offset),
                )
                self.assertEqual(
                    references[stem],
                    CHECKER.ReferenceField(
                        "cmq.h", c_symbol, stem, byte_offset, lsb, width
                    ),
                )
                self.assertEqual(
                    (
                        sv_constants[f"{stem}_WORD_BYTE_OFFSET"],
                        sv_constants[f"{stem}_LSB"],
                        sv_constants[f"{stem}_WIDTH"],
                        sv_constants[f"{stem}_OFFSET"],
                    ),
                    (byte_offset, lsb, width, byte_offset * 8 + lsb),
                )

    def test_task11_source_coordinate_drift_is_rejected(self) -> None:
        parsed_fields = self.parsed_reference_fields()
        for stem in self.TASK11_FIELDS:
            with self.subTest(stem=stem):
                drifted = dict(parsed_fields)
                path, c_symbol, lsb, width = drifted[stem]
                drifted[stem] = (path, c_symbol, lsb ^ 1, width)
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "reference mask mismatch"
                ):
                    CHECKER.validate_reference_fields(
                        CHECKER.REFERENCE_FIELDS,
                        CHECKER.FIELD_MAPPINGS,
                        drifted,
                    )

    def test_task11_reference_coordinate_drift_is_rejected(self) -> None:
        parsed_fields = self.parsed_reference_fields()
        for stem in self.TASK11_FIELDS:
            with self.subTest(stem=stem):
                references = list(CHECKER.REFERENCE_FIELDS)
                index = next(
                    index for index, reference in enumerate(references)
                    if reference.sv_stem == stem
                )
                references[index] = references[index]._replace(
                    word_byte_offset=references[index].word_byte_offset + 8
                )
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "reference byte offset mismatch"
                ):
                    CHECKER.validate_reference_fields(
                        tuple(references), CHECKER.FIELD_MAPPINGS, parsed_fields
                    )

    def test_task11_sv_constant_drift_is_rejected(self) -> None:
        sv_constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/rdma/rdma_defs.svh").read_text()
        )
        for stem, (_, byte_offset, lsb, width) in self.TASK11_FIELDS.items():
            expected = {
                f"{stem}_WORD_BYTE_OFFSET": byte_offset,
                f"{stem}_LSB": lsb,
                f"{stem}_WIDTH": width,
                f"{stem}_OFFSET": byte_offset * 8 + lsb,
            }
            with self.subTest(stem=stem):
                CHECKER.validate_required_sv_constants(sv_constants, expected)
                drifted = dict(sv_constants)
                drifted[f"{stem}_OFFSET"] ^= 1
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "SV constant mismatch"
                ):
                    CHECKER.validate_required_sv_constants(drifted, expected)

    def test_modify_mode_values_are_pinned_to_driver_enums(self) -> None:
        expected = {
            ("qp.h", "XTRDMA_MODIFY_MODE_ONLY_ST",
             "RDMA_QPC_MODIFY_STATE_ONLY"),
            ("qp.h", "XTRDMA_MODIFY_MODE_FULL_QPC",
             "RDMA_QPC_MODIFY_FULL"),
            ("qp.h", "XTRDMA_MODIFY_MODE_PARTIAL_QPC",
             "RDMA_QPC_MODIFY_PARTIAL"),
        }
        actual = {
            (mapping.path, mapping.c_symbol, mapping.sv_name)
            for mapping in CHECKER.VALUE_MAPPINGS
        }
        self.assertTrue(expected <= actual)
        constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/rdma/rdma_defs.svh").read_text()
        )
        expected_values = {
            "RDMA_QPC_MODIFY_STATE_ONLY": 0,
            "RDMA_QPC_MODIFY_FULL": 1,
            "RDMA_QPC_MODIFY_PARTIAL": 2,
        }
        CHECKER.validate_required_sv_constants(constants, expected_values)
        for name in expected_values:
            with self.subTest(name=name):
                drifted = dict(constants)
                drifted[name] += 1
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "SV constant mismatch"
                ):
                    CHECKER.validate_required_sv_constants(
                        drifted, expected_values
                    )

    def test_cmq_ownership_is_parsed_separately_and_exact(self) -> None:
        text = (REPO_ROOT /
                "src/codec/rdma/rdma_image_masks.svh").read_text()
        self.assertEqual(CHECKER.CMQ_BODY_OWNERSHIP, self.EXPECTED_OWNERSHIP)
        self.assertEqual(
            CHECKER.parse_sv_ownership(text), self.EXPECTED_OWNERSHIP
        )
        self.assertTrue(
            set(CHECKER.parse_sv_masks(text)).isdisjoint(self.EXPECTED_OWNERSHIP)
        )
        CHECKER.validate_cmq_body_ownership(self.EXPECTED_OWNERSHIP)

    def test_each_cmq_ownership_mask_drift_is_rejected(self) -> None:
        for name in self.EXPECTED_OWNERSHIP:
            with self.subTest(name=name):
                drifted = dict(self.EXPECTED_OWNERSHIP)
                words = list(drifted[name])
                words[0] ^= 1
                drifted[name] = tuple(words)
                with self.assertRaisesRegex(
                    CHECKER.ValidationError, "CMQ body ownership"
                ):
                    CHECKER.validate_cmq_body_ownership(drifted)


class Task12DoorbellDefinitionTest(unittest.TestCase):
    DOORBELL_NAMES = [
        "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
        "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
        "tx_flush",
    ]
    DOORBELL_OFFSETS = [
        0x000, 0x100, 0x010, 0x040, 0x040, 0x018, 0x018, 0x020,
        0x028, 0x048, 0x050, 0x058, 0x008,
    ]
    DOORBELL_FIELDS = {
        "RDMA_NOTIFY_SRQ_LIMIT_INVALID":
            ("wr.h", "XTRDMA_SRFQ_LIMIT_INVLD", 0, 62, 1),
        "RDMA_NOTIFY_SRQ_PI_INVALID":
            ("defs.h", "XTRDMA_SRFQ_PI_INVLD", 0, 63, 1),
        "RDMA_NOTIFY_SRQ_LIMIT":
            ("defs.h", "XTRDMA_SRFQ_LIMIT_TH", 0, 18, 14),
        "RDMA_NOTIFY_SRQ_ARM_SN":
            ("defs.h", "XTRDMA_SRFQ_ARM_SN", 0, 16, 2),
        "RDMA_NOTIFY_CQ_CI_INVALID":
            ("cq.h", "XTRDMA_NOTIFY_CQ_DB_CI_INVLD", 0, 63, 1),
        "RDMA_NOTIFY_CQ_ARM_INVALID":
            ("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_INVLD", 0, 62, 1),
        "RDMA_NOTIFY_CQ_URC":
            ("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_FLAG", 0, 60, 1),
        "RDMA_NOTIFY_CQ_URC_SQ_WRAP":
            ("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_SQ_WQE_WRAP", 0, 55, 1),
        "RDMA_NOTIFY_CQ_URC_SQ_CI":
            ("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_SQ_WQE_IDX", 0, 40, 15),
        "RDMA_NOTIFY_CQ_URC_RQ_WRAP":
            ("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_RQ_WQE_WRAP", 0, 39, 1),
        "RDMA_NOTIFY_CQ_URC_RQ_CI":
            ("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_RQ_WQE_IDX", 0, 24, 15),
        "RDMA_NOTIFY_QP_DST_PORT":
            ("qp.h", "XTRDMA_DST_PORT", 0, 48, 4),
        "RDMA_NOTIFY_QP_SN":
            ("qp.h", "XTRDMA_QP_SN", 0, 40, 8),
        "RDMA_NOTIFY_QP_DB_TYPE":
            ("qp.h", "XTRDMA_DB_TYPE", 0, 36, 4),
        "RDMA_NOTIFY_QP_ICOS":
            ("qp.h", "XTRDMA_ICOS", 0, 21, 3),
        "RDMA_NOTIFY_QP_QPN":
            ("qp.h", "XTRDMA_QPN", 0, 0, 21),
    }
    DOORBELL_VALUES = {
        ("wr.h", "XTRDMA_SRFQ_LIMIT_INVLD_VAL",
         "RDMA_NOTIFY_SRQ_LIMIT_INVALID_VALUE", 1),
        ("srq.h", "XTRDMA_SRFQ_DB_INVLD",
         "RDMA_NOTIFY_SRQ_PI_INVALID_VALUE", 1),
        ("qp.h", "XTRDMA_DB_QP_FLUSH", "RDMA_DB_TYPE_QP_FLUSH", 0xA),
        ("qp.h", "XTRDMA_DB_TX_FLUSH", "RDMA_DB_TYPE_TX_FLUSH", 0xB),
        ("qp.h", "XTRDMA_DB_RTS2SQD", "RDMA_DB_TYPE_RTS2SQD", 0xD),
        ("qp.h", "XTRDMA_DB_SQD2RTS", "RDMA_DB_TYPE_SQD2RTS", 0xE),
        ("eth_header/register.h", "QSCH_G2P_DPORT_NODE_MODE",
         "RDMA_TX_FLUSH_DST_PORT", 15),
    }

    @staticmethod
    def parsed_reference_fields():
        return {
            reference.sv_stem: (
                reference.path,
                reference.c_symbol,
                reference.lsb,
                reference.width,
            )
            for reference in CHECKER.REFERENCE_FIELDS
        }

    def test_all_doorbell_fields_are_source_pinned_and_exact(self) -> None:
        mappings = {mapping.sv_stem: mapping for mapping in CHECKER.FIELD_MAPPINGS}
        references = {
            reference.sv_stem: reference
            for reference in CHECKER.REFERENCE_FIELDS
        }
        for stem, (path, symbol, byte_offset, lsb, width) in \
                self.DOORBELL_FIELDS.items():
            with self.subTest(stem=stem):
                self.assertEqual(
                    mappings[stem],
                    CHECKER.FieldMapping(path, symbol, stem, byte_offset),
                )
                self.assertEqual(
                    references[stem],
                    CHECKER.ReferenceField(
                        path, symbol, stem, byte_offset, lsb, width
                    ),
                )

    def test_doorbell_field_coordinate_mutation_is_rejected(self) -> None:
        parsed_fields = self.parsed_reference_fields()
        stem = "RDMA_NOTIFY_CQ_URC_SQ_CI"
        references = list(CHECKER.REFERENCE_FIELDS)
        index = next(
            index for index, reference in enumerate(references)
            if reference.sv_stem == stem
        )
        references[index] = references[index]._replace(lsb=39)
        with self.assertRaisesRegex(
            CHECKER.ValidationError, "reference mask mismatch"
        ):
            CHECKER.validate_reference_fields(
                tuple(references), CHECKER.FIELD_MAPPINGS, parsed_fields
            )

    def test_all_doorbell_constants_are_source_pinned_and_exact(self) -> None:
        mappings = {
            (mapping.path, mapping.c_symbol, mapping.sv_name)
            for mapping in CHECKER.VALUE_MAPPINGS
        }
        constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/rdma/rdma_defs.svh").read_text()
        )
        for path, symbol, sv_name, value in self.DOORBELL_VALUES:
            with self.subTest(sv_name=sv_name):
                self.assertIn((path, symbol, sv_name), mappings)
                CHECKER.validate_required_sv_constants(
                    constants, {sv_name: value}
                )

    def test_doorbell_constant_mutation_is_rejected(self) -> None:
        constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/rdma/rdma_defs.svh").read_text()
        )
        expected = {
            sv_name: value
            for _, _, sv_name, value in self.DOORBELL_VALUES
        }
        drifted = dict(constants)
        drifted["RDMA_DB_TYPE_TX_FLUSH"] = 0xA
        with self.assertRaisesRegex(CHECKER.ValidationError, "SV constant mismatch"):
            CHECKER.validate_required_sv_constants(drifted, expected)

    def test_doorbell_goldens_have_exact_order_size_offsets_and_sq_header(self) -> None:
        cases_by_kind = CHECKER.build_golden_cases()
        cases = cases_by_kind["doorbell"]
        self.assertEqual([case.name for case in cases], self.DOORBELL_NAMES)
        self.assertEqual([len(case.payload) for case in cases], [8] * 13)
        offsets = [
            int({item.name: item.value for item in case.inputs}["offset"], 0)
            for case in cases
        ]
        self.assertEqual(offsets, self.DOORBELL_OFFSETS)
        sqe = next(
            case for case in cases_by_kind["queue"]
            if case.name == "sqe_rc_boundary"
        )
        self.assertEqual(cases[1].payload, sqe.payload[:8])

    def test_doorbell_case_name_and_payload_mutations_are_rejected(self) -> None:
        validate = getattr(CHECKER, "validate_doorbell_contract")
        cases_by_kind = CHECKER.build_golden_cases()
        cases = cases_by_kind["doorbell"]
        validate(cases, cases_by_kind["queue"])

        renamed = list(cases)
        renamed[1] = renamed[1]._replace(name="sq_header")
        with self.assertRaisesRegex(CHECKER.ValidationError, "order/name"):
            validate(renamed, cases_by_kind["queue"])

        changed = list(cases)
        payload = bytearray(changed[6].payload)
        payload[3] ^= 1
        changed[6] = changed[6]._replace(payload=bytes(payload))
        with self.assertRaisesRegex(CHECKER.ValidationError, "payload"):
            validate(changed, cases_by_kind["queue"])

class SourceIdentityTest(unittest.TestCase):
    """验证 source manifest 是冻结源码身份的唯一权威。"""

    def _lock(self, archive_id: str = "fixture-archive"):
        """功能：构造最小 ArchiveLock fixture；输入输出及副作用：返回只读归档身份供校验器使用；失败边界：仅覆盖 source identity 所需字段。"""
        return CHECKER.ArchiveLock(
            archive_id=archive_id,
            sha256="0" * 64,
            size_bytes=1,
            prefix="fixture",
            member_list_sha256="1" * 64,
            member_count=1,
        )

    def _fixture(self, selector: str = "FIXTURE_SYMBOL", digest: str | None = None):
        """功能：创建临时锁定源码和 manifest；输入输出及副作用：返回临时目录、源码路径及记录；失败边界：调用方负责释放 TemporaryDirectory。"""
        temp = tempfile.TemporaryDirectory(prefix="rdma_source_identity.")
        root = Path(temp.name)
        source = root / "fixture.h"
        source.write_text("#define FIXTURE_SYMBOL 1\n", encoding="utf-8")
        actual_digest = __import__("hashlib").sha256(source.read_bytes()).hexdigest()
        record = CHECKER.SourceManifestRecord(
            archive_id="fixture-archive",
            path="fixture.h",
            selector=selector,
            sha256=actual_digest if digest is None else digest,
        )
        return temp, root, source, record

    def test_source_manifest_git_head_does_not_change_locked_source_identity(self) -> None:
        """功能：确认冻结源码只由 manifest 字节和 selector 决定；输入输出及副作用：临时写入无关 .git/HEAD 后完成校验；失败边界：源码、digest 或 selector 不匹配时由后续测试拒绝。"""
        temp, root, _, record = self._fixture()
        try:
            (root / ".git").mkdir()
            (root / ".git" / "HEAD").write_text(
                "0123456789abcdef0123456789abcdef01234567\n", encoding="utf-8"
            )
            required_rows = CHECKER.REQUIRED_MANIFEST_ROWS
            CHECKER.REQUIRED_MANIFEST_ROWS = {("fixture.h", "FIXTURE_SYMBOL")}
            try:
                sources = CHECKER.validate_source_manifest_sources(
                    root, self._lock(), [record]
                )
            finally:
                CHECKER.REQUIRED_MANIFEST_ROWS = required_rows
            self.assertIn("fixture.h", sources)
        finally:
            temp.cleanup()

    def test_source_digest_drift_is_rejected(self) -> None:
        """功能：验证 manifest 摘要漂移被拒绝；输入输出及副作用：使用错误 sha256 调用源码身份校验；失败边界：必须报告 source digest mismatch。"""
        temp, root, _, record = self._fixture(digest="f" * 64)
        try:
            with self.assertRaisesRegex(CHECKER.ValidationError, "source digest mismatch: fixture.h"):
                CHECKER.validate_source_manifest_sources(root, self._lock(), [record])
        finally:
            temp.cleanup()

    def test_selector_mismatch_is_rejected(self) -> None:
        """功能：验证 selector 未覆盖源码符号时被拒绝；输入输出及副作用：传入不存在的 selector；失败边界：必须报告 source selector matches no locked symbol/text。"""
        temp, root, _, record = self._fixture(selector="MISSING_SYMBOL")
        try:
            with self.assertRaisesRegex(CHECKER.ValidationError, "source selector matches no locked symbol/text: fixture.h"):
                CHECKER.validate_source_manifest_sources(root, self._lock(), [record])
        finally:
            temp.cleanup()

    def test_archive_identifier_mismatch_is_rejected(self) -> None:
        """功能：验证 manifest archive_identifier 必须等于 ArchiveLock；输入输出及副作用：使用不同归档身份；失败边界：必须报告 source manifest archive identifier mismatch。"""
        temp, root, _, record = self._fixture()
        try:
            with self.assertRaisesRegex(CHECKER.ValidationError, "source manifest archive identifier mismatch"):
                CHECKER.validate_source_manifest_sources(root, self._lock("other-archive"), [record])
        finally:
            temp.cleanup()

    def test_missing_source_is_rejected(self) -> None:
        """功能：验证 manifest 指向缺失文件时被拒绝；输入输出及副作用：删除 fixture 后执行校验；失败边界：必须报告 source file missing。"""
        temp, root, source, record = self._fixture()
        try:
            source.unlink()
            with self.assertRaisesRegex(CHECKER.ValidationError, "source file missing: fixture.h"):
                CHECKER.validate_source_manifest_sources(root, self._lock(), [record])
        finally:
            temp.cleanup()


class MakefileCleanupTest(unittest.TestCase):
    def test_rdma_defs_routes_through_archive_verifier(self) -> None:
        """功能：确认 rdma_defs 使用统一 verifier；输入输出及副作用：读取 Makefile dry-run 文本；失败边界：禁止直接 tar/unzip 解压。"""
        rendered = subprocess.run(
            [
                "make", "--no-print-directory", "-n",
                "TEST=rdma_cmq_driver_contract_test", "rdma_defs",
            ],
            cwd=REPO_ROOT / "sim", check=True, text=True,
            stdout=subprocess.PIPE,
        ).stdout
        self.assertIn("verify_rdma_archive.py", rendered)
        self.assertIn("--lock ../hw/rdma/archive_lock.env", rendered)
        self.assertIn("--source-manifest ../hw/rdma/source_manifest.txt", rendered)
        self.assertNotRegex(rendered, r"(?:tar -x|unzip -q)")
        self.assertIn("set -euo pipefail", rendered)

    def test_rdma_defs_cleanup_preserves_command_failure_and_reports_delete_failure(self) -> None:
        sim_dir = REPO_ROOT / "sim"
        rendered = subprocess.run(
            [
                "make", "--no-print-directory", "-n",
                "TEST=rdma_cmq_driver_contract_test", "rdma_defs",
            ],
            cwd=sim_dir,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout

        with tempfile.TemporaryDirectory(prefix="rdma_profile_cleanup_test.") as temp:
            bin_dir = Path(temp)
            (bin_dir / "tar").write_text("#!/bin/bash\nexit 0\n")
            (bin_dir / "unzip").write_text("#!/bin/bash\nexit 0\n")
            (bin_dir / "python3").write_text(
                "#!/bin/bash\nexit \"${XTR_TEST_COMMAND_STATUS:?}\"\n"
            )
            # Remove the exact empty mktemp directory, but deliberately report
            # failure so the real recipe's EXIT trap must choose the status.
            (bin_dir / "rm").write_text(
                "#!/bin/bash\n/bin/rmdir \"$3\" || exit 99\nexit 1\n"
            )
            # The pinned 0.1.34 source is a tar.gz archive.  Keep an unzip
            # stub as well so this fixture remains valid if a local override
            # selects the legacy zip distribution.
            for command in ("tar", "unzip", "python3", "rm"):
                (bin_dir / command).chmod(0o755)

            for command_status, expected in ((0, 1), (7, 7)):
                with self.subTest(command_status=command_status):
                    env = os.environ.copy()
                    env["PATH"] = f"{bin_dir}:/usr/bin:/bin"
                    env["XTR_TEST_COMMAND_STATUS"] = str(command_status)
                    completed = subprocess.run(
                        ["/bin/bash", "-o", "pipefail", "-c", rendered],
                        cwd=sim_dir,
                        env=env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    self.assertEqual(completed.returncode, expected, completed.stderr)
                    self.assertIn(
                        "Failed to remove RDMA reference directory",
                        completed.stderr,
                    )


class ReferenceEncodingTest(unittest.TestCase):
    def make_reference_image(self, byte_count: int):
        image_type = getattr(CHECKER, "ReferenceImage", bytearray)
        return image_type(byte_count)

    def require_checker_attribute(self, name: str):
        self.assertTrue(hasattr(CHECKER, name), f"checker has no {name}")
        return getattr(CHECKER, name)

    def field_value(self, case, stem: str) -> int:
        reference = CHECKER.REFERENCE_BY_STEM[stem]
        word = int.from_bytes(
            case.payload[
                reference.word_byte_offset:reference.word_byte_offset + 8
            ],
            "big",
        )
        return (word >> reference.lsb) & ((1 << reference.width) - 1)

    def mutate_field(self, case, stem: str):
        reference = CHECKER.REFERENCE_BY_STEM[stem]
        current = self.field_value(case, stem)
        return self.set_field(case, stem, current ^ 1)

    def set_field(self, case, stem: str, value: int):
        reference = CHECKER.REFERENCE_BY_STEM[stem]
        start = reference.word_byte_offset
        image = bytearray(case.payload)
        word = int.from_bytes(image[start:start + 8], "big")
        mask = ((1 << reference.width) - 1) << reference.lsb
        word = (word & ~mask) | (value << reference.lsb)
        image[start:start + 8] = word.to_bytes(8, "big")
        return case._replace(payload=bytes(image))

    def mutate_input(self, case, name: str):
        inputs = []
        for item in case.inputs:
            if item.name != name:
                inputs.append(item)
                continue
            replacements = {
                "mr_register": "key_alloc",
                "key_alloc": "mr_register",
                "self": "0",
            }
            value = replacements.get(item.value)
            if value is None:
                value = hex(int(item.value, 0) ^ 1)
            inputs.append(CHECKER.GoldenInput(item.name, value))
        return case._replace(inputs=tuple(inputs))

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

    def test_destination_ip_profile_constants_are_checked_and_drive_placement(self) -> None:
        validate_profile = self.require_checker_attribute(
            "validate_profile_constants"
        )
        sv_constants = CHECKER.parse_sv_constants(
            (REPO_ROOT / "src/codec/rdma/rdma_defs.svh").read_text()
        )
        validate_profile(sv_constants, CHECKER.PROFILE_VALUES)
        self.assertEqual(CHECKER.PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTE_OFFSET"], 80)
        self.assertEqual(CHECKER.PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTES"], 16)

        drifted = dict(CHECKER.PROFILE_VALUES)
        drifted["RDMA_QPC_DEST_IP_BYTE_OFFSET"] += 1
        with self.assertRaisesRegex(CHECKER.ValidationError, "profile constant"):
            validate_profile(sv_constants, drifted)

        saved_offset = CHECKER.PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTE_OFFSET"]
        try:
            CHECKER.PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTE_OFFSET"] = 81
            ud = CHECKER.build_golden_cases()["context"][1]
        finally:
            CHECKER.PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTE_OFFSET"] = saved_offset
        self.assertEqual(
            ud.payload[81:97],
            bytes.fromhex("20010db8000000000000000000000001"),
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
        task11_audit_only = set(Task11DefinitionTest.TASK11_FIELDS)
        sq_audit_only = {
            reference.sv_stem
            for reference in references
            if reference.sv_stem.startswith("RDMA_SQ_")
            and reference.sv_stem not in used_stems
        }
        self.assertTrue(task11_audit_only <= set(reference_stems))
        self.assertEqual(
            set(used_stems), set(reference_stems) - task11_audit_only - sq_audit_only
        )

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
                "mrt_key_alloc_pbl1_boundary",
                "mrt_key_alloc_pbl2_boundary",
                "srqc_create_body_boundary",
                "ceqc_create_body_boundary",
                "aeqc_create_body_boundary",
            ],
        )
        self.assertEqual(
            [len(case.payload) for case in context_cases],
            [512, 512, 512] + [64] * 10,
        )
        self.assertEqual(len(cases["cmq"][0].payload), 64)
        self.assertEqual(len(cases["queue"][0].payload), 64)
        self.assertEqual(len(cases["doorbell"][0].payload), 8)
        self.assertEqual(
            context_cases[0].payload[:8],
            bytes.fromhex("605abca15555a500"),
        )
        self.assertEqual(
            context_cases[1].payload[:8],
            bytes.fromhex("4c6345a2aaaa5a89"),
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
            "transport=rc,traffic_class=0xaa,tver=1,mig=1,host=5,vf=0xabc,icos=5,qpn=0x15555,stat_idx=0xa5,pkey=0xbeef,shadow_pba=0x123456789ab,tx_swap=1,rx_swap=1,sq_ce=1,ra_fence=1,aa_fence=1,fc=1,state=3,pmtu=5,retry_count=7,rnr_retry=7,qp_sn=0xc3,srfq=1,srfqn=0x4567,pd=0xa55a,access=0x1f,dst_qpn=0x654321,dmac=0x112233445566,vlan_id=0xabc,flow=0xabcde,dscp=0x2a,ecn=2,hop=0x40,udp_sport=0xc123,send_psn=0xabcdef,recv_psn=0x123456,sq_pba=0x123456789abcd,sq_size=11,sq_om=2,sq_cqn=0xabcde,rq_cqn=0x54321,rq_pba=0x0fedcba987654,rq_size=10,rq_om=1",
            "transport=ud,traffic_class=0xac,tver=1,mig=0,host=6,vf=0x345,icos=5,qpn=0x2aaaa,stat_idx=0x5a,qkey=0x89abcdef,pkey=0x1234,shadow_pba=0x0fedcba9876,tx_swap=1,rx_swap=1,state=3,pmtu=4,qp_sn=0x7e,pd=0x5aa5,vlan=1,ipv6=1,tunnel=1,lag=1,fwd=2,dst_vport=0x456,src_addr=0xabc,dst_port=0xb,dst_qpn=0xabcdef,dmac=0xa1b2c3d4e5f6,pri=5,cfi=1,vlan_id=0x789,src_vport=0x345,flow=0x54321,dscp=0x2b,ecn=0,hop=0x7f,udp_sport=0xbeef,dest_ip=20010db8000000000000000000000001,sq_pba=0x1111122222333,sq_size=9,sq_om=3,sq_cqn=0x13579,rq_cqn=0x2468a,rq_pba=0x4444455555666,rq_size=8,rq_om=2",
            "transport=urc,traffic_class=0xfe,transport_version=1,migration_enable=1,host_id=7,vf_id=0x789,qpn=0x3ffff,stat_index=0xff,pkey=0xabcd,context_backing=0x2468acf135600,tx_endian_swap=0,rx_endian_swap=0,signature_enable=0,read_after_write_fence=0,atomic_after_atomic_fence=0,tx_flow_control=0,rx_flow_control=0,state=3,path_mtu_bytes=8192,qp_sequence=0xfe,pd_id=0xffff,access=0,vlan_enable=0,ipv6=0,tunnel_enable=0,lag_enable=0,forwarding_enable=0,destination_vport=0,source_address_index=0,destination_port=0,remote_qpn=0x654321,destination_mac=0,priority=0,cfi=0,vlan_id=0,source_vport=0,flow_label=0,hop_limit=0,udp_source_port=0,destination_ip=00000000000000000000000000000000,rbsn=0xabcdef,dbsn=0x654321,rpsn=0x56789a,dpsn=0x456789,rsq_backing=0x123456789abcd000,rdsq_backing=0x23456789abcde000,dsq_backing=0x3456789abcdef000,rsq_depth=64,rdsq_depth=64,rdsq_fetch_count=8,dsq_fetch_count=8,rq_sequence_threshold_entries=2048,sq_completion_threshold_entries=4096,sq_backing=0x456789abcdef0000,sq_depth=32768,sq_mode=3,send_cq_id=0xfffff,recv_cq_id=0xabcde,rq_backing=0x56789abcdef01000,rq_depth=16384,rq_mode=2",
            "cqn=0x1fffff,sd_pba=0xfffffffffffff,size=0x1f,urc=1,state=2,next_hi=0xff,cur_valid=1,cur_pba=0xfffffffffffff,load_ci=1,threshold=7,mode=3,next_valid=1,next_lo=0xfffffffffff,pi=0x7fffff,pi_wrap=1,last_arm=3,cqe_size=2,ceqn=0xfff,shadow=0x3ffffffffffffff,ci=0x7fffff,ci_wrap=1,arm_sn=3,arm_state=2",
            "opcode=0x05,stag=0xffffff,state=2,key=0xff,parent=0,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=2,host_page=2,pbl=0,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,pba0=0xfffffffffffff,mr_sn=0xfff",
            "opcode=0x05,stag=0xffffff,state=2,key=0xff,parent=0,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=2,host_page=2,pbl=1,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,pba0=0xfffffffffffff,pba1=0xfffffffffffff,mr_sn=0xfff",
            "opcode=0x05,stag=0xffffff,state=2,key=0xff,parent=0,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=2,host_page=2,pbl=2,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,first_pbl=0xfffffff,mr_sn=0xfff",
            "opcode=0x04,stag=0xffffff,state=2,key=0xff,parent=self,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=2,host_page=2,pbl=0,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,pba0=0xfffffffffffff,mr_sn=0xfff",
            "opcode=0x04,stag=0xffffff,state=2,key=0xff,parent=self,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=2,host_page=2,pbl=1,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,pba0=0xfffffffffffff,pba1=0xfffffffffffff,mr_sn=0xfff",
            "opcode=0x04,stag=0xffffff,state=2,key=0xff,parent=self,pd=0xffff,payload_vf=0xff,payload_vf_en=1,rights=0x1f,type=2,host_page=2,pbl=2,address_mode=1,invalidate=1,length=0x3fffffffffff,odp=1,start_va=0xffffffffffffffff,first_pbl=0xfffffff,mr_sn=0xfff",
            "srfqn=0xffff,state=2,load_pi=0xff,shadow=0xfffffffffffff,pd=0xffff,pba=0xfffffffffffff,size=0xf,mode=3,pi_wrap=1,pi=0x7fff,limit=0x3fff,arm_sn=3",
            "eqn=0xfff,state=2,size=0x1f,next=0xfffffffffffff,current=0xfffffffffffff,current_valid=1,pi_wrap=1,pi=0x3ffff,mode=3,msix=0xffff,ci_wrap=1,ci=0x3ffff",
            "eqn=0xfff,state=2,size=0x1f,next=0xfffffffffffff,current=0xfffffffffffff,current_valid=1,pi_wrap=1,pi=0x3ffff,mode=3,msix=0xffff,ci_wrap=1,ci=0x3ffff",
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
            "mrt_key_alloc_pbl1": (0x6000000000ffffff, 0x00000000ff000000,
                0xffffffffffffffff, 0xff00bfffffffffff,
                0xffffffffffffffff, 0xfffffffffffff000,
                0xffffffffffffffff, 0),
            "mrt_key_alloc_pbl2": (0x6000000000ffffff, 0x00000000ff000000,
                0xffffffffffffffff, 0xff00bfffffffffff,
                0xffffffffffffffff, 0xfffffff000000000,
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
            if ((mapping.path == "cq.h" and mapping.sv_stem.startswith("RDMA_CQC_BODY_"))
                or (mapping.path == "srq.h" and mapping.sv_stem.startswith("RDMA_SRQC_BODY_"))
                or (mapping.path == "event.h" and mapping.sv_stem.startswith("RDMA_EQC_BODY_")))
        }
        self.assertEqual(translated_stems, expected_stems)

        drifted = translations[0]._replace(
            local_word_byte_offset=translations[0].local_word_byte_offset + 8
        )
        with self.assertRaisesRegex(CHECKER.ValidationError, "translation"):
            validate_translations(
                (drifted,) + translations[1:], CHECKER.FIELD_MAPPINGS
            )

    def test_qpc_traffic_class_projection_and_ecn_policy_are_enforced(self) -> None:
        validate = self.require_checker_attribute("validate_context_contract")
        cases = CHECKER.build_golden_cases()["context"]
        for case, required_ecn in zip(cases[:3], (2, 0, 2)):
            inputs = {item.name: item.value for item in case.inputs}
            traffic_class = int(inputs["traffic_class"], 0)
            self.assertEqual(self.field_value(case, "RDMA_QPC_ICOS"),
                             traffic_class >> 5)
            self.assertEqual(self.field_value(case, "RDMA_QPC_DSCP"),
                             traffic_class >> 2)
            self.assertEqual(self.field_value(case, "RDMA_QPC_ECN"),
                             required_ecn)
            self.assertEqual(self.field_value(case, "RDMA_QPC_ECN"),
                             traffic_class & 0x3)

            for stem in ("RDMA_QPC_ICOS", "RDMA_QPC_DSCP",
                         "RDMA_QPC_ECN"):
                with self.subTest(case=case.name, stem=stem):
                    corrupted = list(cases)
                    corrupted[cases.index(case)] = self.mutate_field(case, stem)
                    with self.assertRaisesRegex(
                        CHECKER.ValidationError, "traffic class|ECN"
                    ):
                        validate(corrupted)

            with self.subTest(case=case.name, input="traffic_class_low_bits"):
                corrupted = list(cases)
                corrupted[cases.index(case)] = self.mutate_input(
                    case, "traffic_class"
                )
                with self.assertRaisesRegex(CHECKER.ValidationError, "ECN"):
                    validate(corrupted)

    def test_canonical_urc_semantics_drive_all_derived_fields(self) -> None:
        urc = CHECKER.build_golden_cases()["context"][2]
        inputs = {item.name: item.value for item in urc.inputs}
        expected_core = {
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
        for name, value in expected_core.items():
            with self.subTest(input=name):
                self.assertEqual(inputs[name], value)

        absent_legacy_names = {
            "tx_rbsn", "rx_rbsn", "tx_dbsn", "rx_dbsn", "rxed_dbsn",
            "rx_srbsn", "tx_srbsn", "max_tx_srbsn", "rdsq_size",
            "rq_se_th", "sq_ce_th", "dsq_fetch",
        }
        self.assertTrue(absent_legacy_names.isdisjoint(inputs))

        expected_fields = {
            "RDMA_QPC_DST_QPN": 0x654321,
            "RDMA_QPC_URC_RSQ_SIZE": 6,
            "RDMA_QPC_URC_RDSQ_SIZE": 6,
            "RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM": 8,
            "RDMA_QPC_URC_NXT_DSQ_FETCH_NUM": 8,
            "RDMA_QPC_URC_RQ_SE_TH": 11,
            "RDMA_QPC_URC_SQ_CE_TH": 12,
            "RDMA_QPC_SQ_SIZE": 15,
            "RDMA_QPC_RQ_SIZE": 14,
            "RDMA_QPC_PMTU": 5,
            "RDMA_QPC_URC_TX_RBSN": 0xABCDEF,
            "RDMA_QPC_URC_RX_RBSN": 0xABCDEF,
            "RDMA_QPC_URC_TX_DBSN": 0x654321,
            "RDMA_QPC_URC_RX_DBSN": 0x654321,
            "RDMA_QPC_URC_RXED_DBSN": 0x654321,
            "RDMA_QPC_URC_CUR_TX_RPSN": 0x56789A,
            "RDMA_QPC_URC_TPE_RPSN_MAX": 0x56789A,
            "RDMA_QPC_URC_CUR_TX_DPSN": 0x456789,
            "RDMA_QPC_URC_TPE_DPSN_MAX": 0x456789,
            "RDMA_QPC_URC_RX_SRBSN": 0,
            "RDMA_QPC_URC_TX_SRBSN": 0,
            "RDMA_QPC_URC_MAX_TX_SRBSN": 0,
        }
        for stem, expected in expected_fields.items():
            with self.subTest(field=stem):
                self.assertEqual(self.field_value(urc, stem), expected)

        rsq_page = (
            self.field_value(urc, "RDMA_QPC_URC_RSQ_PBA_H") << 48
        ) | self.field_value(urc, "RDMA_QPC_URC_RSQ_PBA_L")
        dsq_page = (
            self.field_value(urc, "RDMA_QPC_URC_CUR_DSQ_PBA_H") << 12
        ) | self.field_value(urc, "RDMA_QPC_URC_CUR_DSQ_PBA_L")
        self.assertEqual(rsq_page, 0x123456789ABCD)
        self.assertEqual(
            self.field_value(urc, "RDMA_QPC_URC_RDSQ_PBA"),
            0x23456789ABCDE,
        )
        self.assertEqual(dsq_page, 0x3456789ABCDEF)
        self.assertEqual(
            self.field_value(urc, "RDMA_QPC_URC_NXT_DSQ_PBA"),
            dsq_page + 1,
        )

    def test_canonical_urc_common_handle_is_named_qpn(self) -> None:
        urc = CHECKER.build_golden_cases()["context"][2]
        inputs = {item.name: item.value for item in urc.inputs}

        self.assertIn("qpn", inputs)
        self.assertEqual(inputs["qpn"], "0x3ffff")
        self.assertNotIn("qp_id", inputs)

    def test_every_urc_semantic_input_is_coupled_to_payload(self) -> None:
        validate = self.require_checker_attribute("validate_context_contract")
        cases = CHECKER.build_golden_cases()["context"]
        urc = cases[2]

        for item in urc.inputs:
            with self.subTest(input=item.name):
                if item.name == "transport":
                    mutated_inputs = tuple(
                        CHECKER.GoldenInput(entry.name, "rc")
                        if entry.name == "transport" else entry
                        for entry in urc.inputs
                    )
                    mutated = urc._replace(inputs=mutated_inputs)
                else:
                    mutated = self.mutate_input(urc, item.name)
                corrupted = list(cases)
                corrupted[2] = mutated
                with self.assertRaises(CHECKER.ValidationError):
                    validate(corrupted)

    def test_urc_accepts_optional_traffic_class_derived_summaries(self) -> None:
        validate = self.require_checker_attribute("validate_context_contract")
        cases = CHECKER.build_golden_cases()["context"]
        urc = cases[2]
        derived_inputs = (
            CHECKER.GoldenInput("icos", "7"),
            CHECKER.GoldenInput("dscp", "0x3f"),
            CHECKER.GoldenInput("ecn", "2"),
        )
        cases[2] = urc._replace(inputs=urc.inputs + derived_inputs)

        try:
            validate(cases)
        except CHECKER.ValidationError as error:
            self.fail(f"valid derived summaries were rejected: {error}")

    def test_body_goldens_use_only_driver_supported_semantic_values(self) -> None:
        validate = self.require_checker_attribute("validate_context_contract")
        cases = CHECKER.build_golden_cases()["context"]
        supported = {
            "cqc_create_body_boundary": {
                "RDMA_CQC_BODY_CQ_ST": {0, 1, 2},
                "RDMA_CQC_BODY_CQE_SIZE": {0, 1, 2},
                "RDMA_CQC_BODY_ARM_ST": {0, 1, 2},
            },
            "mrt_register_pbl0_boundary": {
                "RDMA_MRT_BODY_NXT_ST": {0, 1, 2},
                "RDMA_MRT_BODY_ST": {0, 1, 2},
                "RDMA_MRT_BODY_TYPE": {0, 1, 2},
                "RDMA_MRT_BODY_HOST_PG_SIZE": {0, 1, 2},
            },
            "mrt_register_pbl1_boundary": {
                "RDMA_MRT_BODY_NXT_ST": {0, 1, 2},
                "RDMA_MRT_BODY_ST": {0, 1, 2},
                "RDMA_MRT_BODY_TYPE": {0, 1, 2},
                "RDMA_MRT_BODY_HOST_PG_SIZE": {0, 1, 2},
            },
            "mrt_register_pbl2_boundary": {
                "RDMA_MRT_BODY_NXT_ST": {0, 1, 2},
                "RDMA_MRT_BODY_ST": {0, 1, 2},
                "RDMA_MRT_BODY_TYPE": {0, 1, 2},
                "RDMA_MRT_BODY_HOST_PG_SIZE": {0, 1, 2},
            },
            "mrt_key_alloc_pbl0_boundary": {
                "RDMA_MRT_BODY_NXT_ST": {0, 1, 2},
                "RDMA_MRT_BODY_ST": {0, 1, 2},
                "RDMA_MRT_BODY_TYPE": {0, 1, 2},
                "RDMA_MRT_BODY_HOST_PG_SIZE": {0, 1, 2},
            },
            "mrt_key_alloc_pbl1_boundary": {
                "RDMA_MRT_BODY_NXT_ST": {0, 1, 2},
                "RDMA_MRT_BODY_ST": {0, 1, 2},
                "RDMA_MRT_BODY_TYPE": {0, 1, 2},
                "RDMA_MRT_BODY_HOST_PG_SIZE": {0, 1, 2},
            },
            "mrt_key_alloc_pbl2_boundary": {
                "RDMA_MRT_BODY_NXT_ST": {0, 1, 2},
                "RDMA_MRT_BODY_ST": {0, 1, 2},
                "RDMA_MRT_BODY_TYPE": {0, 1, 2},
                "RDMA_MRT_BODY_HOST_PG_SIZE": {0, 1, 2},
            },
            "srqc_create_body_boundary": {
                "RDMA_SRQC_BODY_SRFQ_ST": {0, 1, 2},
            },
            "ceqc_create_body_boundary": {
                "RDMA_EQC_BODY_EQ_ST": {0, 1, 2},
            },
            "aeqc_create_body_boundary": {
                "RDMA_EQC_BODY_EQ_ST": {0, 1, 2},
            },
        }
        semantic_input = {
            "RDMA_CQC_BODY_CQ_ST": "state",
            "RDMA_CQC_BODY_CQE_SIZE": "cqe_size",
            "RDMA_CQC_BODY_ARM_ST": "arm_state",
            "RDMA_MRT_BODY_NXT_ST": "state",
            "RDMA_MRT_BODY_ST": "state",
            "RDMA_MRT_BODY_TYPE": "type",
            "RDMA_MRT_BODY_HOST_PG_SIZE": "host_page",
            "RDMA_SRQC_BODY_SRFQ_ST": "state",
            "RDMA_EQC_BODY_EQ_ST": "state",
        }
        by_name = {case.name: case for case in cases}
        for name, fields in supported.items():
            for stem, values in fields.items():
                case = by_name[name]
                with self.subTest(case=name, stem=stem):
                    self.assertIn(self.field_value(case, stem), values)
                    corrupted = list(cases)
                    index = cases.index(case)
                    # All listed semantic fields are two bits wide and value
                    # three is the only representable unsupported code.
                    corrupted[index] = self.set_field(case, stem, 3)
                    with self.assertRaisesRegex(
                        CHECKER.ValidationError, "unsupported semantic"
                    ):
                        validate(corrupted)
                    corrupted[index] = self.mutate_input(
                        case, semantic_input[stem]
                    )
                    with self.assertRaisesRegex(
                        CHECKER.ValidationError, "unsupported semantic"
                    ):
                        validate(corrupted)

    def test_mrt_inputs_and_payload_fields_are_fully_coupled(self) -> None:
        validate = self.require_checker_attribute("validate_context_contract")
        cases = CHECKER.build_golden_cases()["context"]
        by_name = {case.name: case for case in cases}
        fields_by_case = {
            "mrt_register_pbl0_boundary": (
                "RDMA_MRT_BODY_STAG_IDX", "RDMA_MRT_BODY_NXT_ST",
                "RDMA_MRT_BODY_STAG_KEY", "RDMA_MRT_BODY_PARENT_STAG_IDX",
                "RDMA_MRT_BODY_PD_IDX", "RDMA_MRT_BODY_PLD_VF_ID",
                "RDMA_MRT_BODY_PLD_VF_EN", "RDMA_MRT_BODY_RIGHT",
                "RDMA_MRT_BODY_TYPE", "RDMA_MRT_BODY_HOST_PG_SIZE",
                "RDMA_MRT_BODY_PBL_MODE", "RDMA_MRT_BODY_ADDR_MODE",
                "RDMA_MRT_BODY_INVALIDATE_EN", "RDMA_MRT_BODY_ST",
                "RDMA_MRT_BODY_LEN", "RDMA_MRT_BODY_ODP",
                "RDMA_MRT_BODY_INFO_STAG_KEY", "RDMA_MRT_BODY_START_VA",
                "RDMA_MRT_BODY_PAYLOAD_PBA0", "RDMA_MRT_BODY_MR_SN",
            ),
            "mrt_register_pbl1_boundary": ("RDMA_MRT_BODY_PAYLOAD_PBA1",),
            "mrt_register_pbl2_boundary": ("RDMA_MRT_BODY_FIRST_PBL_IDX",),
            "mrt_key_alloc_pbl0_boundary": (
                "RDMA_MRT_BODY_PARENT_STAG_IDX",
            ),
            "mrt_key_alloc_pbl1_boundary": (
                "RDMA_MRT_BODY_PARENT_STAG_IDX",
                "RDMA_MRT_BODY_PAYLOAD_PBA1",
            ),
            "mrt_key_alloc_pbl2_boundary": (
                "RDMA_MRT_BODY_PARENT_STAG_IDX",
                "RDMA_MRT_BODY_FIRST_PBL_IDX",
            ),
        }
        for name, stems in fields_by_case.items():
            case = by_name[name]
            for stem in stems:
                with self.subTest(case=name, payload_field=stem):
                    corrupted = list(cases)
                    corrupted[cases.index(case)] = self.mutate_field(case, stem)
                    with self.assertRaises(CHECKER.ValidationError):
                        validate(corrupted)

        for name in (
            "mrt_register_pbl0_boundary", "mrt_register_pbl1_boundary",
            "mrt_register_pbl2_boundary", "mrt_key_alloc_pbl0_boundary",
            "mrt_key_alloc_pbl1_boundary", "mrt_key_alloc_pbl2_boundary",
        ):
            case = by_name[name]
            for item in case.inputs:
                with self.subTest(case=name, input=item.name):
                    corrupted = list(cases)
                    corrupted[cases.index(case)] = self.mutate_input(case, item.name)
                    with self.assertRaises(CHECKER.ValidationError):
                        validate(corrupted)

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
            "RDMA_QPC_SQ_PBA",
            "RDMA_QPC_SQ_SIZE",
            "RDMA_QPC_SQ_OM",
        ):
            with self.subTest(stem=stem):
                self.assertEqual(offsets[stem], 216)

        qpc = CHECKER.build_golden_cases()["context"][0].payload
        self.assertEqual(qpc[216:224], bytes.fromhex("123456789abcdb80"))

    def test_sq_fields_and_golden_vectors_are_required(self) -> None:
        fields = CHECKER.parse_sq_field_mappings(CHECKER.SV_DEFS_PATH.read_text())
        self.assertIn("RDMA_SQ_WQE_QPN", fields)
        self.assertIn("RDMA_SQ_WQE_SIGNATURE", fields)
        self.assertIn("RDMA_SQ_WQE_UD_DST_IP", fields)
        self.assertTrue((CHECKER.GOLDEN_DIR / "sq.hex").exists())
        CHECKER.validate_sq_golden_vectors()

    def test_sq_field_mapping_has_no_python38_dict_union(self) -> None:
        """功能：检查 SQ 字段解析器不会执行 Python 3.9 才支持的字典合并。
        输入输出及副作用：读取解析器源码并遍历 ``parse_sq_field_mappings`` 的 AST，
        不修改文件或运行时状态；若通过则表示该函数的返回构造可在 Python 3.8 执行。
        失败边界：函数不存在，或其 AST 含有字典字面量/推导式参与 ``|`` 运算时失败，
        因为 Python 3.8 会在该分支抛出 ``TypeError``。
        """
        tree = ast.parse(CHECKER_PATH.read_text(encoding="utf-8"), str(CHECKER_PATH))
        function = next(
            (
                node
                for node in ast.walk(tree)
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                and node.name == "parse_sq_field_mappings"
            ),
            None,
        )
        self.assertIsNotNone(function, "parse_sq_field_mappings definition is required")
        assert function is not None

        dict_unions = [
            node.lineno
            for node in ast.walk(function)
            if isinstance(node, ast.BinOp)
            and isinstance(node.op, ast.BitOr)
            and any(
                isinstance(operand, (ast.Dict, ast.DictComp))
                for operand in (node.left, node.right)
            )
        ]
        self.assertEqual(
            dict_unions,
            [],
            "parse_sq_field_mappings must not use dict | dict on Python 3.8",
        )

    def test_sq_opcodes_are_pinned_to_wr_h_enum(self) -> None:
        constants = CHECKER.parse_sv_constants(CHECKER.SV_DEFS_PATH.read_text())
        expected = {
            "RDMA_SQ_OPCODE_SEND": 1,
            "RDMA_SQ_OPCODE_SEND_WITH_IMM": 2,
            "RDMA_SQ_OPCODE_SEND_WITH_INV": 3,
            "RDMA_SQ_OPCODE_WRITE": 4,
            "RDMA_SQ_OPCODE_WRITE_WITH_IMM": 5,
            "RDMA_SQ_OPCODE_READ": 6,
            "RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP": 7,
            "RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD": 8,
            "RDMA_SQ_OPCODE_LOCAL_INV": 14,
        }
        self.assertEqual({name: constants.get(name) for name in expected}, expected)

    def test_sq_masks_reject_reserved_bits(self) -> None:
        masks = CHECKER.parse_sv_masks(CHECKER.SV_MASKS_PATH.read_text())
        self.assertEqual(masks["RDMA_SQ_WQE_HEADER_MASK"][0], 0xEFFFFFFFFFFFFFFF)
        self.assertEqual(
            masks["RDMA_SQ_WQE_RC_BODY_MASK"],
            (0, 0xFFFFFFFFFFFFFFFF, 0xFF00FFFF00000000, 0xFFFFFFFFFFFFFFFF,
             0xFFFFFFFFFFFFFE00, 0, 0, 0),
        )
        self.assertEqual(
            masks["RDMA_SQ_WQE_UD_BODY_MASK"][1], 0xFFFFFFFFFEFFFFFF,
        )
        self.assertEqual(
            masks["RDMA_SQ_WQE_ATOMIC_BODY_MASK"],
            (0, 0xFFFFFFFF, 0xFF00FFFF00000000, 0xFFFFFFFFFFFFFFFF,
             0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
             0xFFFFFFFFFFFFFFFF),
        )

    def test_sq_golden_cases_have_operation_specific_images(self) -> None:
        cases = CHECKER.parse_golden_text((CHECKER.GOLDEN_DIR / "sq.hex").read_text())
        by_name = {case.name: case for case in cases}
        self.assertGreaterEqual(len(cases), 18)
        self.assertGreater(len({case.payload for case in cases if case.name != "sgb_boundary"}), 10)
        self.assertNotEqual(by_name["rc_inline_1"].payload, by_name["atomic_cas"].payload)
        self.assertNotEqual(by_name["ud_inline"].payload, by_name["ud_sgb"].payload)
        self.assertEqual(
            int.from_bytes(by_name["send_with_imm"].payload[:8], "big") >> 32 & 0xF,
            2,
        )
        self.assertEqual(
            int.from_bytes(by_name["atomic_cas"].payload[:8], "big") >> 32 & 0xF,
            7,
        )

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
                "sq": "offset=0x100",
                "rq": "qpn=0x15555,icos=5,pi=0x4567,wrap=1,offset=0x10",
                "srq_pi":
                    "srqn=0xa55a,pi=0x4567,wrap=1,limit_invalid=1,"
                    "offset=0x40",
                "srq_limit":
                    "srqn=0xa55a,limit=0x2aaa,arm_sn=3,pi_invalid=1,"
                    "offset=0x40",
                "cq_rc_ud":
                    "cqn=0x15555,host=5,ci=0x654321,wrap=1,arm=1,"
                    "arm_state=2,arm_sn=3,urc=0,offset=0x18",
                "cq_urc":
                    "cqn=0x12345,host=3,sq_ci=0x4567,sq_wrap=1,"
                    "rq_ci=0x2345,rq_wrap=0,arm=1,arm_state=1,arm_sn=2,"
                    "urc=1,offset=0x18",
                "ceq": "ceqn=0x2aaaaa,ci=0x2aaaa,wrap=1,offset=0x20",
                "aeq": "aeqn=0xaaa,ci=0x15555,wrap=1,offset=0x28",
                "rts2sqd":
                    "qpn=0x15555,dst_port=11,qp_sn=0xa6,icos=5,"
                    "db_type=0xd,offset=0x48",
                "sqd2rts":
                    "qpn=0x15555,dst_port=11,qp_sn=0xa6,icos=5,"
                    "db_type=0xe,offset=0x50",
                "qp_flush":
                    "qpn=0x15555,dst_port=11,qp_sn=0xa6,icos=0,"
                    "db_type=0xa,offset=0x58",
                "tx_flush":
                    "qpn=0x2aaaa,dst_port=15,qp_sn=0x0,icos=0,"
                    "db_type=0xb,offset=0x8",
            },
        )


if __name__ == "__main__":
    unittest.main()
