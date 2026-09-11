#!/usr/bin/env python3
"""Validate the RDMA profile definitions and frozen hardware golden vectors.

The checked-in implementation profile is named ``rdma``.  XTR v1 remains only
the external hardware-source alias used by the pinned headers and golden-file
marker.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
from pathlib import Path
import re
import sys
from typing import NamedTuple

try:
    from .rdma_driver_contract import (
        ArchiveLock,
        ContractError,
        SourceManifestRecord,
        load_archive_lock,
        load_source_manifest,
    )
except ImportError:  # pragma: no cover - direct script execution
    if str(Path(__file__).resolve().parent) not in sys.path:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
    from rdma_driver_contract import (
        ArchiveLock,
        ContractError,
        SourceManifestRecord,
        load_archive_lock,
        load_source_manifest,
    )

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "hw" / "rdma" / "source_manifest.txt"
SV_DEFS_PATH = REPO_ROOT / "src" / "codec" / "rdma" / "rdma_defs.svh"
ERROR_CODEC_PATH = (
    REPO_ROOT / "src" / "codec" / "rdma" / "rdma_error_codec.sv"
)
SV_MASKS_PATH = REPO_ROOT / "src" / "codec" / "rdma" / "rdma_image_masks.svh"
GOLDEN_DIR = REPO_ROOT / "hw" / "rdma" / "golden_vectors"

# 生产源码和测试只允许使用内部 profile 名称 ``rdma``。硬件资料别名
# ``xtr_v1`` 只保留在 hw/ 和来源文档中，因此命名守卫扫描 src/tests/sim。
PROFILE_SCAN_ROOTS = ("src", "tests", "sim")
PROFILE_TEXT_SUFFIXES = {".sv", ".svh", ".f", ".mk", ".sh", ".py", ""}
PROFILE_FORBIDDEN_PATTERNS = (
    re.compile(r"\brdma_xtr_v1(?:_|\b)"),
    re.compile(r"\bXTR_V1_[A-Z0-9_]+\b"),
    re.compile(r"(?:^|[\"'])xtr_v1\|"),
    re.compile(r"(?:src/codec/|tests/[^\s]*/?)xtr_v1(?:/|[\"'])"),
)

REQUIRED_MANIFEST_ROWS = {
    ("cmq.h", "xtrdma_cmq_opcode"),
    ("qp.h", "XTRDMA_QPC_*"),
    ("cq.h", "XTRDMA_CMQ_CQC_*|XTRDMA_NOTIFY_CQ_*"),
    ("wr.h", "XTRDMA_SQ_WQE_*|XTRDMA_RQE_*|XTRDMA_CQE_*"),
    ("defs.h", "XTRDMA_CEQE_*|XTRDMA_AEQE_*|EC_*"),
    ("eth_header/rdma_register.h", "RDMA_HID_MAP_TABLE|RDMA_RPE_VFT_TABLE"),
    ("eth_header/register.h", "QSCH_G2P_DPORT_NODE_MODE"),
    ("alloc.h", "xtrdma_alloc_type"),
    ("mr.h", "MR/PBL/page/address-enums|xtrdma_reg_mr_info"),
    ("mr.c", "xtrdma_hwreg_mr"),
    ("rdma_main.h", "xtrdma_get_access"),
    ("srq.h", "XTRDMA_SRFQ_CTX_*"),
    ("srq.c", "xtrdma_hw_create_srfqc"),
    ("event.h", "XTRDMA_EQ_CTX_*"),
    ("event.c", "xtrdma_hw_create_eq"),
}

ENVELOPE_MASK = (0x8FFF3FFF00000000,) + (0,) * 7
BODY_MASKS = {
    "cqc_create": (
        0x00000000001FFFFF, 0xFF0FFFFFFFFFFFFF,
        0xFFFFFFFFFFFFF8FF, 0xFFFFFFFFFFF8C701,
        0xF000000000FFFFFF, 0x0000000000000FFF,
        0xFFFFFFFFFFFFFFC0, 0x0000000F00FFFFFF,
    ),
    "mrt_register_pbl0": (
        0x6000000000FFFFFF, 0x00000000FF000000,
        0xFFFFFFFFFF000000, 0xFF00BFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFF000,
        0x0000000000000FFF, 0,
    ),
    "mrt_key_alloc_pbl0": (
        0x6000000000FFFFFF, 0x00000000FF000000,
        0xFFFFFFFFFFFFFFFF, 0xFF00BFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFF000,
        0x0000000000000FFF, 0,
    ),
    "mrt_key_alloc_pbl1": (
        0x6000000000FFFFFF, 0x00000000FF000000,
        0xFFFFFFFFFFFFFFFF, 0xFF00BFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFF000,
        0xFFFFFFFFFFFFFFFF, 0,
    ),
    "mrt_key_alloc_pbl2": (
        0x6000000000FFFFFF, 0x00000000FF000000,
        0xFFFFFFFFFFFFFFFF, 0xFF00BFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 0xFFFFFFF000000000,
        0x0000000000000FFF, 0,
    ),
    "mrt_register_pbl1": (
        0x6000000000FFFFFF, 0x00000000FF000000,
        0xFFFFFFFFFF000000, 0xFF00BFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFF000,
        0xFFFFFFFFFFFFFFFF, 0,
    ),
    "mrt_register_pbl2": (
        0x6000000000FFFFFF, 0x00000000FF000000,
        0xFFFFFFFFFF000000, 0xFF00BFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 0xFFFFFFF000000000,
        0x0000000000000FFF, 0,
    ),
    "srqc_create": (
        0x000000000000FFFF, 0, 0xCFFFFFFFFFFFFFFF,
        0xFFFF000000000000, 0xFFFFFFFFFFFFF0FC,
        0x00000000FFFFFFFF, 0, 0,
    ),
    "ceqc_create": (
        0x0000000000000FFF, 0, 0xC1FFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFF800, 0x0000007FFFF0C000,
        0xFFFF00000007FFFF, 0, 0,
    ),
    "aeqc_create": (
        0x0000000000000FFF, 0, 0xC1FFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFF800, 0x0000007FFFF0C000,
        0xFFFF00000007FFFF, 0, 0,
    ),
}

# Task 11 CMQ composition ownership is intentionally frozen separately from
# the Task 10 context-body masks above.  These masks describe which final CMQ
# qword bits each exact opcode body may author.
CMQ_BODY_OWNERSHIP = {
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


class ValidationError(RuntimeError):
    """The checked definition baseline is inconsistent or unsupported."""


def find_profile_name_violations() -> list[str]:
    """扫描当前仓库，返回生产输入中残留的旧 profile token。"""

    violations: list[str] = []
    for root_name in PROFILE_SCAN_ROOTS:
        root = REPO_ROOT / root_name
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.suffix not in PROFILE_TEXT_SUFFIXES:
                continue
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except UnicodeDecodeError:
                continue
            relative = path.relative_to(REPO_ROOT)
            for line_number, line in enumerate(lines, 1):
                if any(pattern.search(line) for pattern in PROFILE_FORBIDDEN_PATTERNS):
                    violations.append(f"{relative}:{line_number}:{line.strip()}")
    return violations


def validate_profile_names() -> None:
    """若源码、测试或仿真配置仍引用旧 profile，则抛出可定位错误。"""

    violations = find_profile_name_violations()
    if violations:
        raise ValidationError("旧 profile 命名残留:\n  " + "\n  ".join(violations))


class FieldMapping(NamedTuple):
    path: str
    c_symbol: str
    sv_stem: str
    word_byte_offset: int
    lsb_adjust: int = 0


class ReferenceField(NamedTuple):
    path: str
    c_symbol: str
    sv_stem: str
    word_byte_offset: int
    lsb: int
    width: int


class ValueMapping(NamedTuple):
    path: str
    c_symbol: str
    sv_name: str
    subtract_symbol: str = ""


class ErrorCodeMapping(NamedTuple):
    path: str
    c_symbol: str
    sv_name: str


class BodyTranslation(NamedTuple):
    path: str
    c_symbol: str
    sv_stem: str
    local_word_byte_offset: int
    final_base_offset: int


# Every genuine error-code value identity discovered from the pinned headers.
# Values intentionally do not appear here: validate_error_code_mappings parses
# them independently from the fixed driver on every checker run.
ERROR_CODE_MAPPINGS = (
    ErrorCodeMapping("defs.h", "EC_TPE_DB_TYPE_INVLD", "RDMA_ECODE_EC_TPE_DB_TYPE_INVLD"),
    ErrorCodeMapping("defs.h", "EC_TPE_OCC_QPC_ERR", "RDMA_ECODE_EC_TPE_OCC_QPC_ERR"),
    ErrorCodeMapping("defs.h", "EC_TPE_TX_FLUSH", "RDMA_ECODE_EC_TPE_TX_FLUSH"),
    ErrorCodeMapping("defs.h", "EC_TPE_QP_FLUSH", "RDMA_ECODE_EC_TPE_QP_FLUSH"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_VF_QPN_UNMATCH", "RDMA_ECODE_EC_TPE_SQ_VF_QPN_UNMATCH"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_RTO_OVERTIME", "RDMA_ECODE_EC_TPE_SQ_RTO_OVERTIME"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_SIGN_ERR_OVERTIME", "RDMA_ECODE_EC_TPE_SQ_SIGN_ERR_OVERTIME"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_PSN_ERR_OVERTIME", "RDMA_ECODE_EC_TPE_SQ_PSN_ERR_OVERTIME"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_KEY_ERR", "RDMA_ECODE_EC_TPE_SQ_KEY_ERR"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_WQE_OPCODE_INVLD", "RDMA_ECODE_EC_TPE_SQ_WQE_OPCODE_INVLD"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_QP_ACCESS_ERR", "RDMA_ECODE_EC_TPE_SQ_QP_ACCESS_ERR"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_WQE_SIGN_ERR", "RDMA_ECODE_EC_TPE_SQ_WQE_SIGN_ERR"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_RETRY_FENCE_WQE", "RDMA_ECODE_EC_TPE_SQ_RETRY_FENCE_WQE"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_PAYLOAD_LEN_ABOVE", "RDMA_ECODE_EC_TPE_SQ_PAYLOAD_LEN_ABOVE"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_WRITE_LEN_UNMATCH", "RDMA_ECODE_EC_TPE_SQ_WRITE_LEN_UNMATCH"),
    ErrorCodeMapping("defs.h", "EC_TPE_SGB_KEY_ERR", "RDMA_ECODE_EC_TPE_SGB_KEY_ERR"),
    ErrorCodeMapping("defs.h", "EC_RTS2SQD_DB_QP_ST_UNMATCH", "RDMA_ECODE_EC_RTS2SQD_DB_QP_ST_UNMATCH"),
    ErrorCodeMapping("defs.h", "EC_RTS2SQD_DONE", "RDMA_ECODE_EC_RTS2SQD_DONE"),
    ErrorCodeMapping("defs.h", "EC_SQD2RTS_DB_QP_ST_UNMATCH", "RDMA_ECODE_EC_SQD2RTS_DB_QP_ST_UNMATCH"),
    ErrorCodeMapping("defs.h", "EC_TPE_EIRQ_RDSQ_VF_QPN_UNMATCH", "RDMA_ECODE_EC_TPE_EIRQ_RDSQ_VF_QPN_UNMATCH"),
    ErrorCodeMapping("defs.h", "EC_TPE_EIRQ_RDSQ_KEY_ERR", "RDMA_ECODE_EC_TPE_EIRQ_RDSQ_KEY_ERR"),
    ErrorCodeMapping("defs.h", "EC_TPE_EIRQ_RDSQ_WQE_OPCODE_INVLD", "RDMA_ECODE_EC_TPE_EIRQ_RDSQ_WQE_OPCODE_INVLD"),
    ErrorCodeMapping("defs.h", "EC_TPE_URC_RSQ_RTO_OVERTIME", "RDMA_ECODE_EC_TPE_URC_RSQ_RTO_OVERTIME"),
    ErrorCodeMapping("defs.h", "EC_TPE_TX_LOCAL_WQE_RTO_OVERTIME", "RDMA_ECODE_EC_TPE_TX_LOCAL_WQE_RTO_OVERTIME"),
    ErrorCodeMapping("defs.h", "EC_TPE_SQ_SGE_PLD_LEN_UNMATCH", "RDMA_ECODE_EC_TPE_SQ_SGE_PLD_LEN_UNMATCH"),
    ErrorCodeMapping("defs.h", "EC_TME_OCC_MR_ABNORMAL_RSLT", "RDMA_ECODE_EC_TME_OCC_MR_ABNORMAL_RSLT"),
    ErrorCodeMapping("defs.h", "EC_TME_PBL_INVLD", "RDMA_ECODE_EC_TME_PBL_INVLD"),
    ErrorCodeMapping("defs.h", "EC_TME_PKT_LEN_ZERO", "RDMA_ECODE_EC_TME_PKT_LEN_ZERO"),
    ErrorCodeMapping("defs.h", "EC_TME_PKT_ST_ERR", "RDMA_ECODE_EC_TME_PKT_ST_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_PKT_TYPE_ERR", "RDMA_ECODE_EC_TME_PKT_TYPE_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_PKT_PD_ERR", "RDMA_ECODE_EC_TME_PKT_PD_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_PKT_KEY_ERR", "RDMA_ECODE_EC_TME_PKT_KEY_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_PKT_TYPE1_NOT_VA", "RDMA_ECODE_EC_TME_PKT_TYPE1_NOT_VA"),
    ErrorCodeMapping("defs.h", "EC_TME_PKT_MR_LEN_ZERO", "RDMA_ECODE_EC_TME_PKT_MR_LEN_ZERO"),
    ErrorCodeMapping("defs.h", "EC_TME_PKT_LEN_ERR", "RDMA_ECODE_EC_TME_PKT_LEN_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_PKT_TYPE2B_QPN_ERR", "RDMA_ECODE_EC_TME_PKT_TYPE2B_QPN_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_PLD_LEN_CHK_ERR", "RDMA_ECODE_EC_TME_PLD_LEN_CHK_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_LOINVLD_NOT_PERMIT", "RDMA_ECODE_EC_TME_LOINVLD_NOT_PERMIT"),
    ErrorCodeMapping("defs.h", "EC_TME_LOINVLD_ST_INVLD", "RDMA_ECODE_EC_TME_LOINVLD_ST_INVLD"),
    ErrorCodeMapping("defs.h", "EC_TME_LOINVLD_TYPE1_MW", "RDMA_ECODE_EC_TME_LOINVLD_TYPE1_MW"),
    ErrorCodeMapping("defs.h", "EC_TME_LOINVLD_PD_ERR", "RDMA_ECODE_EC_TME_LOINVLD_PD_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_LOINVLD_KEY_ERR", "RDMA_ECODE_EC_TME_LOINVLD_KEY_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_LOINVLD_MR_WITH_MW", "RDMA_ECODE_EC_TME_LOINVLD_MR_WITH_MW"),
    ErrorCodeMapping("defs.h", "EC_TME_LOINVLD_TYPE2B_QPN_ERR", "RDMA_ECODE_EC_TME_LOINVLD_TYPE2B_QPN_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_PARENT_MR_ST_NOT_VLD", "RDMA_ECODE_EC_TME_BIND_PARENT_MR_ST_NOT_VLD"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_MW_ST_INVLD", "RDMA_ECODE_EC_TME_BIND_MW_ST_INVLD"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_MW_ST_NOT_FREE", "RDMA_ECODE_EC_TME_BIND_MW_ST_NOT_FREE"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_PARENT_MR_TYPE_ERR", "RDMA_ECODE_EC_TME_BIND_PARENT_MR_TYPE_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_MW_TYPE_ERR", "RDMA_ECODE_EC_TME_BIND_MW_TYPE_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_WQE_TYPE_ERR", "RDMA_ECODE_EC_TME_BIND_WQE_TYPE_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_PD_ERR", "RDMA_ECODE_EC_TME_BIND_PD_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_PARENT_MR_KEY_ERR", "RDMA_ECODE_EC_TME_BIND_PARENT_MR_KEY_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_PARENT_MR_RIGHT_B_ERR", "RDMA_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_B_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_PARENT_MR_RIGHT_LW_ERR", "RDMA_ECODE_EC_TME_BIND_PARENT_MR_RIGHT_LW_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_PARENT_MR_NOT_VA", "RDMA_ECODE_EC_TME_BIND_PARENT_MR_NOT_VA"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_MW_LEN_ERR", "RDMA_ECODE_EC_TME_BIND_MW_LEN_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_MW_TYPE1_OP_ERR", "RDMA_ECODE_EC_TME_BIND_MW_TYPE1_OP_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_MW_TYPE2B_ZERO_BIND", "RDMA_ECODE_EC_TME_BIND_MW_TYPE2B_ZERO_BIND"),
    ErrorCodeMapping("defs.h", "EC_TME_BIND_PARENT_MR_BIND_NUM_ERR", "RDMA_ECODE_EC_TME_BIND_PARENT_MR_BIND_NUM_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_FMR_ST_ERR", "RDMA_ECODE_EC_TME_FMR_ST_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_FMR_TYPE_ERR", "RDMA_ECODE_EC_TME_FMR_TYPE_ERR"),
    ErrorCodeMapping("defs.h", "EC_TME_FMR_PD_ERR", "RDMA_ECODE_EC_TME_FMR_PD_ERR"),
    ErrorCodeMapping("defs.h", "EC_TDE_DMA_ERR", "RDMA_ECODE_EC_TDE_DMA_ERR"),
    ErrorCodeMapping("defs.h", "EC_TDE_SRC_ADDR_TBL_INVLD", "RDMA_ECODE_EC_TDE_SRC_ADDR_TBL_INVLD"),
    ErrorCodeMapping("defs.h", "EC_CCE_RC_CCREQ", "RDMA_ECODE_EC_CCE_RC_CCREQ"),
    ErrorCodeMapping("defs.h", "EC_CCE_RC_ACK", "RDMA_ECODE_EC_CCE_RC_ACK"),
    ErrorCodeMapping("defs.h", "EC_CCE_URC_ACK", "RDMA_ECODE_EC_CCE_URC_ACK"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_SRFQ_OVER_LIMIT_TH", "RDMA_ECODE_EC_RPE_REQ_SRFQ_OVER_LIMIT_TH"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_SRFQ_PKT_LEN_UNMATCH_SGE", "RDMA_ECODE_EC_RPE_REQ_SRFQ_PKT_LEN_UNMATCH_SGE"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_SRFQ_WQE_ERR", "RDMA_ECODE_EC_RPE_REQ_SRFQ_WQE_ERR"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_SRFQ_ST_INVLD", "RDMA_ECODE_EC_RPE_REQ_SRFQ_ST_INVLD"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_DUP_DR_NML_URC", "RDMA_ECODE_EC_RPE_REQ_DUP_DR_NML_URC"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_DR_OWN_URC", "RDMA_ECODE_EC_RPE_REQ_DR_OWN_URC"),
    ErrorCodeMapping("defs.h", "EC_RPE_RC_URC_ACCESS_INVLD", "RDMA_ECODE_EC_RPE_RC_URC_ACCESS_INVLD"),
    ErrorCodeMapping("defs.h", "EC_RPE_ICRC_ERR_TRIM_PKT", "RDMA_ECODE_EC_RPE_ICRC_ERR_TRIM_PKT"),
    ErrorCodeMapping("defs.h", "EC_RPE_OCC_QPC_ERR", "RDMA_ECODE_EC_RPE_OCC_QPC_ERR"),
    ErrorCodeMapping("defs.h", "EC_RPE_RC_URC_OPCODE_INVLD", "RDMA_ECODE_EC_RPE_RC_URC_OPCODE_INVLD"),
    ErrorCodeMapping("defs.h", "EC_RPE_RX_FLUSH", "RDMA_ECODE_EC_RPE_RX_FLUSH"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_RQ_WQE_ERR_UD", "RDMA_ECODE_EC_RPE_REQ_RQ_WQE_ERR_UD"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_ATOMIC_OCTBYTE_ALIGN_ERR", "RDMA_ECODE_EC_RPE_REQ_ATOMIC_OCTBYTE_ALIGN_ERR"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_OPCODE_MIS_LAST", "RDMA_ECODE_EC_RPE_REQ_OPCODE_MIS_LAST"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_OPCODE_MIS_FST", "RDMA_ECODE_EC_RPE_REQ_OPCODE_MIS_FST"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_PKT_LEN_UNMATCH_PMTU_PAD", "RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_PMTU_PAD"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_PKT_LEN_UNMATCH_RETH", "RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_RETH"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC", "RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC"),
    ErrorCodeMapping("defs.h", "EC_RPE_REQ_RQ_WQE_ERR_RC_URC", "RDMA_ECODE_EC_RPE_REQ_RQ_WQE_ERR_RC_URC"),
    ErrorCodeMapping("defs.h", "EC_RPE_RSP_ORQ_WQE_ERR", "RDMA_ECODE_EC_RPE_RSP_ORQ_WQE_ERR"),
    ErrorCodeMapping("defs.h", "EC_RPE_RSP_OPCODE_MIS_LAST", "RDMA_ECODE_EC_RPE_RSP_OPCODE_MIS_LAST"),
    ErrorCodeMapping("defs.h", "EC_RPE_RSP_OPCODE_MIS_FST", "RDMA_ECODE_EC_RPE_RSP_OPCODE_MIS_FST"),
    ErrorCodeMapping("defs.h", "EC_RPE_RSP_PKT_LEN_UNMATCH_SGE_RC", "RDMA_ECODE_EC_RPE_RSP_PKT_LEN_UNMATCH_SGE_RC"),
    ErrorCodeMapping("defs.h", "EC_RPE_RSP_PKT_LEN_UNMATCH_PMTU_PAD", "RDMA_ECODE_EC_RPE_RSP_PKT_LEN_UNMATCH_PMTU_PAD"),
    ErrorCodeMapping("defs.h", "EC_RPE_RSP_PSN_UNMATCH_ORQ_LAST_PSN", "RDMA_ECODE_EC_RPE_RSP_PSN_UNMATCH_ORQ_LAST_PSN"),
    ErrorCodeMapping("defs.h", "EC_RPE_RSP_ORQE_PSN_ERR", "RDMA_ECODE_EC_RPE_RSP_ORQE_PSN_ERR"),
    ErrorCodeMapping("defs.h", "EC_RPE_RSP_NAK_RNR_ERR_OVERTIME", "RDMA_ECODE_EC_RPE_RSP_NAK_RNR_ERR_OVERTIME"),
    ErrorCodeMapping("defs.h", "EC_RPE_NAK_FATAL_ERR", "RDMA_ECODE_EC_RPE_NAK_FATAL_ERR"),
    ErrorCodeMapping("defs.h", "EC_RPE_RX_FLUSH_QP_INVLD", "RDMA_ECODE_EC_RPE_RX_FLUSH_QP_INVLD"),
    ErrorCodeMapping("defs.h", "EC_RPE_URC_DR_TCIE", "RDMA_ECODE_EC_RPE_URC_DR_TCIE"),
    ErrorCodeMapping("defs.h", "EC_RPE_NACK_CIE", "RDMA_ECODE_EC_RPE_NACK_CIE"),
    ErrorCodeMapping("defs.h", "EC_RME_OCC_MR_ABNORMAL_RSLT", "RDMA_ECODE_EC_RME_OCC_MR_ABNORMAL_RSLT"),
    ErrorCodeMapping("defs.h", "EC_RME_PBL_INVLD", "RDMA_ECODE_EC_RME_PBL_INVLD"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_SRFQ_PD_ERR", "RDMA_ECODE_EC_RME_PKT_SRFQ_PD_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_LEN_ZERO", "RDMA_ECODE_EC_RME_PKT_LEN_ZERO"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_ST_ERR", "RDMA_ECODE_EC_RME_PKT_ST_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_TYPE_ERR", "RDMA_ECODE_EC_RME_PKT_TYPE_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_PD_ERR", "RDMA_ECODE_EC_RME_PKT_PD_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_KEY_ERR", "RDMA_ECODE_EC_RME_PKT_KEY_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_RIGHT_ERR", "RDMA_ECODE_EC_RME_PKT_RIGHT_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_TYPE1_NOT_VA", "RDMA_ECODE_EC_RME_PKT_TYPE1_NOT_VA"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_MR_LEN_ZERO", "RDMA_ECODE_EC_RME_PKT_MR_LEN_ZERO"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_LEN_ERR", "RDMA_ECODE_EC_RME_PKT_LEN_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_SRFQ_MR_ERR", "RDMA_ECODE_EC_RME_PKT_SRFQ_MR_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_ROINVLD_NOT_PERMIT", "RDMA_ECODE_EC_RME_ROINVLD_NOT_PERMIT"),
    ErrorCodeMapping("defs.h", "EC_RME_ROINVLD_ST_INVLD", "RDMA_ECODE_EC_RME_ROINVLD_ST_INVLD"),
    ErrorCodeMapping("defs.h", "EC_RME_ROINVLD_TYPE1_MW", "RDMA_ECODE_EC_RME_ROINVLD_TYPE1_MW"),
    ErrorCodeMapping("defs.h", "EC_RME_ROINVLD_PD_ERR", "RDMA_ECODE_EC_RME_ROINVLD_PD_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_ROINVLD_KEY_ERR", "RDMA_ECODE_EC_RME_ROINVLD_KEY_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_ROINVLD_MR_WITH_MW", "RDMA_ECODE_EC_RME_ROINVLD_MR_WITH_MW"),
    ErrorCodeMapping("defs.h", "EC_RME_ROINVLD_TYPE2B_QPN_ERR", "RDMA_ECODE_EC_RME_ROINVLD_TYPE2B_QPN_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_PKT_TYPE2B_QPN_ERR", "RDMA_ECODE_EC_RME_PKT_TYPE2B_QPN_ERR"),
    ErrorCodeMapping("defs.h", "EC_RME_PLD_LEN_CHK_ERR", "RDMA_ECODE_EC_RME_PLD_LEN_CHK_ERR"),
    ErrorCodeMapping("defs.h", "EC_RCE_OCC_EIRQ_RDSQ_ERR", "RDMA_ECODE_EC_RCE_OCC_EIRQ_RDSQ_ERR"),
    ErrorCodeMapping("defs.h", "EC_RCE_OCC_UAQ_ERR", "RDMA_ECODE_EC_RCE_OCC_UAQ_ERR"),
    ErrorCodeMapping("defs.h", "EC_RCE_URC_TACK_RBM_DUP_PKT", "RDMA_ECODE_EC_RCE_URC_TACK_RBM_DUP_PKT"),
    ErrorCodeMapping("defs.h", "EC_RCE_OCC_CQC_ERR", "RDMA_ECODE_EC_RCE_OCC_CQC_ERR"),
    ErrorCodeMapping("defs.h", "EC_RCE_CQC_INVLD", "RDMA_ECODE_EC_RCE_CQC_INVLD"),
    ErrorCodeMapping("defs.h", "EC_RCE_CQ_FULL", "RDMA_ECODE_EC_RCE_CQ_FULL"),
    ErrorCodeMapping("defs.h", "EC_RCE_CQ_LOAD_PBA_ERR", "RDMA_ECODE_EC_RCE_CQ_LOAD_PBA_ERR"),
    ErrorCodeMapping("defs.h", "EC_RCE_COM_EST", "RDMA_ECODE_EC_RCE_COM_EST"),
    ErrorCodeMapping("defs.h", "EC_RCE_CEQC_INVLD", "RDMA_ECODE_EC_RCE_CEQC_INVLD"),
    ErrorCodeMapping("defs.h", "EC_RCE_CEQ_FULL", "RDMA_ECODE_EC_RCE_CEQ_FULL"),
    ErrorCodeMapping("defs.h", "EC_RCE_AEQC_INVLD", "RDMA_ECODE_EC_RCE_AEQC_INVLD"),
    ErrorCodeMapping("defs.h", "EC_RCE_AEQ_FULL", "RDMA_ECODE_EC_RCE_AEQ_FULL"),
    ErrorCodeMapping("defs.h", "EC_GLB_MBUS_ERR", "RDMA_ECODE_EC_GLB_MBUS_ERR"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_TX_REQ_NML", "RDMA_ECODE_XTRDMA_CQE_ECODE_TX_REQ_NML"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_TX_RSP_NML", "RDMA_ECODE_XTRDMA_CQE_ECODE_TX_RSP_NML"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_SQ_FLUSH_ERR", "RDMA_ECODE_XTRDMA_CQE_ECODE_SQ_FLUSH_ERR"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_TX_EC_CCE_URC_ACK", "RDMA_ECODE_XTRDMA_CQE_ECODE_TX_EC_CCE_URC_ACK"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_SRFQ_OVER_LIMIT_TH", "RDMA_ECODE_XTRDMA_CQE_ECODE_SRFQ_OVER_LIMIT_TH"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_RX_REQ_NML", "RDMA_ECODE_XTRDMA_CQE_ECODE_RX_REQ_NML"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_RX_RSP_NML", "RDMA_ECODE_XTRDMA_CQE_ECODE_RX_RSP_NML"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_RQ_FLUSH_ERR", "RDMA_ECODE_XTRDMA_CQE_ECODE_RQ_FLUSH_ERR"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_NAK_FATAL_ERR", "RDMA_ECODE_XTRDMA_CQE_ECODE_NAK_FATAL_ERR"),
    ErrorCodeMapping("wr.h", "XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT", "RDMA_ECODE_XTRDMA_CQE_ECODE_TX_EC_RCE_URC_SQ_CPL_SRBM_DUP_PKT"),
)

# The pinned sources intentionally give these five values two identities.
# Canonical symbolic lookup preserves the defs.h identity; every alias still
# receives its own independently checked SV constant.
EXPECTED_ERROR_CODE_ALIASES = (
    (("defs.h", "EC_TPE_QP_FLUSH"),
     ("wr.h", "XTRDMA_CQE_ECODE_SQ_FLUSH_ERR")),
    (("defs.h", "EC_CCE_URC_ACK"),
     ("wr.h", "XTRDMA_CQE_ECODE_TX_EC_CCE_URC_ACK")),
    (("defs.h", "EC_RPE_REQ_SRFQ_OVER_LIMIT_TH"),
     ("wr.h", "XTRDMA_CQE_ECODE_SRFQ_OVER_LIMIT_TH")),
    (("defs.h", "EC_RPE_RX_FLUSH"),
     ("wr.h", "XTRDMA_CQE_ECODE_RQ_FLUSH_ERR")),
    (("defs.h", "EC_RPE_NAK_FATAL_ERR"),
     ("wr.h", "XTRDMA_CQE_ECODE_NAK_FATAL_ERR")),
)


class GoldenInput(NamedTuple):
    name: str
    value: str


class GoldenCase(NamedTuple):
    name: str
    inputs: tuple[GoldenInput, ...]
    payload: bytes

    @property
    def summary(self) -> str:
        return ",".join(f"{item.name}={item.value}" for item in self.inputs)


# word_byte_offset comes from the fixed driver's set_64bit_val/get_64bit_val
# call sites. The C mask supplies LSB/WIDTH. OFFSET is a logical pre-serialize
# coordinate, not a raw bit number in the big-endian memory byte stream.
FIELD_MAPPINGS = (
    # QPC common/transport-visible fields (qp.c qword stores).
    FieldMapping("qp.h", "XTRDMA_QPC_TVER", "RDMA_QPC_TVER", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_MIG", "RDMA_QPC_MIG", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_SERVICE_TYPE", "RDMA_QPC_SERVICE_TYPE", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_HOST_ID", "RDMA_QPC_HOST_ID", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_VF_ID", "RDMA_QPC_VF_ID", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_ICOS", "RDMA_QPC_ICOS", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_QPN", "RDMA_QPC_QPN", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_STAT_IDX", "RDMA_QPC_STAT_IDX", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_UD_QKEY_H", "RDMA_QPC_UD_QKEY_H", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_UD_QKEY_L", "RDMA_QPC_UD_QKEY_L", 8),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RSQ_PBA_H", "RDMA_QPC_URC_RSQ_PBA_H", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RSQ_PBA_L", "RDMA_QPC_URC_RSQ_PBA_L", 8),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RSQ_SIZE", "RDMA_QPC_URC_RSQ_SIZE", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_PKEY", "RDMA_QPC_PKEY", 8),
    FieldMapping("qp.h", "XTRDMA_QPC_SHADOW_PBA", "RDMA_QPC_SHADOW_PBA", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_TX_ENDIAN_SWAP", "RDMA_QPC_TX_ENDIAN_SWAP", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_RX_ENDIAN_SWAP", "RDMA_QPC_RX_ENDIAN_SWAP", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_CE_EN", "RDMA_QPC_SQ_CE_EN", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_RA_RENCE", "RDMA_QPC_RA_FENCE", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_AA_FENCE", "RDMA_QPC_AA_FENCE", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_FC_EN", "RDMA_QPC_FC_EN", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_CC_TYPE", "RDMA_QPC_CC_TYPE", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_QP_ST", "RDMA_QPC_QP_ST", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_PMTU", "RDMA_QPC_PMTU", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_RNR_RETRY_TH", "RDMA_QPC_RNR_RETRY_TH", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_QP_SN", "RDMA_QPC_QP_SN", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_SRFQ", "RDMA_QPC_RC_SRFQ", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_SRFQN", "RDMA_QPC_RC_SRFQN", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_PD_IDX", "RDMA_QPC_PD_IDX", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_QP_ACCESS_FLAG", "RDMA_QPC_QP_ACCESS_FLAG", 32),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RDSQ_PBA", "RDMA_QPC_URC_RDSQ_PBA", 32),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RDSQ_SIZE", "RDMA_QPC_URC_RDSQ_SIZE", 32),
    FieldMapping("qp.h", "XTRDMA_QPC_PSN_RETRY_TH", "RDMA_QPC_PSN_RETRY_TH", 40),
    FieldMapping("qp.h", "XTRDMA_QPC_RTO_CODE", "RDMA_QPC_RTO_CODE", 40),
    FieldMapping("qp.h", "XTRDMA_QPC_VLAN", "RDMA_QPC_VLAN", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_IPV6", "RDMA_QPC_IPV6", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_TUNNEL", "RDMA_QPC_TUNNEL", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_LAG", "RDMA_QPC_LAG", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_FWD", "RDMA_QPC_FWD", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_DST_VPORT_ID", "RDMA_QPC_DST_VPORT_ID", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_SRC_ADDR_IDX", "RDMA_QPC_SRC_ADDR_IDX", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_DST_PORT", "RDMA_QPC_DST_PORT", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_DST_QPN", "RDMA_QPC_DST_QPN", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_DMAC", "RDMA_QPC_DMAC", 64),
    FieldMapping("qp.h", "XTRDMA_QPC_PRI", "RDMA_QPC_PRI", 64),
    FieldMapping("qp.h", "XTRDMA_QPC_CFI", "RDMA_QPC_CFI", 64),
    FieldMapping("qp.h", "XTRDMA_QPC_VLAN_ID", "RDMA_QPC_VLAN_ID", 64),
    FieldMapping("qp.h", "XTRDMA_QPC_FLOW_LABEL", "RDMA_QPC_FLOW_LABEL", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_SRC_VPORT_ID", "RDMA_QPC_SRC_VPORT_ID", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_DSCP", "RDMA_QPC_DSCP", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_ECN", "RDMA_QPC_ECN", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_HOPLIMIT", "RDMA_QPC_HOPLIMIT", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_CUR_UDP_SPORT", "RDMA_QPC_CUR_UDP_SPORT", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_TX_RBSN", "RDMA_QPC_URC_TX_RBSN", 96),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_TX_DBSN", "RDMA_QPC_URC_TX_DBSN", 96),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RX_RBSN", "RDMA_QPC_URC_RX_RBSN", 128),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RX_DBSN", "RDMA_QPC_URC_RX_DBSN", 128),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_TPE_CUR_SQ_PSN", "RDMA_QPC_RC_TPE_CUR_SQ_PSN", 160),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_LAST_READ_PSN", "RDMA_QPC_RC_LAST_READ_PSN", 208),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_PD_PBA_OR_PBA", "RDMA_QPC_SQ_PBA", 216),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_SIZE", "RDMA_QPC_SQ_SIZE", 216),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_OM", "RDMA_QPC_SQ_OM", 216),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_EIRQ_PSN_MAX", "RDMA_QPC_RC_EIRQ_PSN_MAX", 224),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM", "RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM", 224),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RX_SRBSN", "RDMA_QPC_URC_RX_SRBSN", 224),
    FieldMapping("qp.h", "XTRDMA_QPC_EIRQ_CUR_SEND_PSN", "RDMA_QPC_EIRQ_CUR_SEND_PSN", 232),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_CUR_TX_DPSN", "RDMA_QPC_URC_CUR_TX_DPSN", 232),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_CUR_TX_RPSN", "RDMA_QPC_URC_CUR_TX_RPSN", 232),
    FieldMapping("qp.h", "XTRDMA_QPC_EPSN_REQ", "RDMA_QPC_EPSN_REQ", 288),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RXED_DBSN", "RDMA_QPC_URC_RXED_DBSN", 296),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_RQ_SE_TH", "RDMA_QPC_URC_RQ_SE_TH", 320),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_SQ_CE_TH", "RDMA_QPC_URC_SQ_CE_TH", 320),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_TX_SRBSN", "RDMA_QPC_URC_TX_SRBSN", 328),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_MAX_TX_SRBSN", "RDMA_QPC_URC_MAX_TX_SRBSN", 328),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_PSN_MAX_RPE", "RDMA_QPC_RC_PSN_MAX_RPE", 344),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_EPSN_RSP", "RDMA_QPC_RC_EPSN_RSP", 352),
    FieldMapping("qp.h", "XTRDMA_QPC2_RC_EPSN_RSP", "RDMA_QPC2_RC_EPSN_RSP", 376),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_CUR_DSQ_PBA_H", "RDMA_QPC_URC_CUR_DSQ_PBA_H", 384),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_CUR_DSQ_PBA_L", "RDMA_QPC_URC_CUR_DSQ_PBA_L", 392),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_NXT_DSQ_PBA", "RDMA_QPC_URC_NXT_DSQ_PBA", 392),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_TPE_RPSN_MAX", "RDMA_QPC_URC_TPE_RPSN_MAX", 400),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_PSN_MAX_TPE", "RDMA_QPC_RC_PSN_MAX_TPE", 416),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_TPE_DPSN_MAX", "RDMA_QPC_URC_TPE_DPSN_MAX", 416),
    FieldMapping("qp.h", "XTRDMA_QPC_URC_NXT_DSQ_FETCH_NUM", "RDMA_QPC_URC_NXT_DSQ_FETCH_NUM", 416),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_RETRY_FPSN", "RDMA_QPC_RC_RETRY_FPSN", 424),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_RETRY_PSN", "RDMA_QPC_RC_RETRY_PSN", 432),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_CQN", "RDMA_QPC_SQ_CQN", 448),
    FieldMapping("qp.h", "XTRDMA_QPC_RQ_CQN", "RDMA_QPC_RQ_CQN", 448),
    FieldMapping("qp.h", "XTRDMA_QPC_LOAD_RQ_PI_TH", "RDMA_QPC_LOAD_RQ_PI_TH", 480),
    FieldMapping("qp.h", "XTRDMA_QPC_RQ_OR_SRQ_PD_PBA_OR_PBA", "RDMA_QPC_RQ_PBA", 496),
    FieldMapping("qp.h", "XTRDMA_QPC_RQ_OR_SRQ_SIZE", "RDMA_QPC_RQ_SIZE", 496),
    FieldMapping("qp.h", "XTRDMA_QPC_RQ_OR_SRQ_OM", "RDMA_QPC_RQ_OM", 496),
    # CQC local bytes 0..55 are copied to final body bytes 8..63.
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_SD_PBA", "RDMA_CQC_BODY_CQ_SD_PBA", 8),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_SIZE", "RDMA_CQC_BODY_CQ_SIZE", 8),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_URC_FLAG", "RDMA_CQC_BODY_URC_FLAG", 8),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_ST", "RDMA_CQC_BODY_CQ_ST", 8),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_NXT_CQ_PD_PBA_H", "RDMA_CQC_BODY_NXT_CQ_PD_PBA_H", 16),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CUR_PBA_VLD", "RDMA_CQC_BODY_CUR_PBA_VLD", 16),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CUR_CQ_PD_PBA", "RDMA_CQC_BODY_CUR_CQ_PD_PBA", 16),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_LOAD_CQ_CI_DONE", "RDMA_CQC_BODY_LOAD_CQ_CI_DONE", 24),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_LOAD_CQ_CI_TH", "RDMA_CQC_BODY_LOAD_CQ_CI_TH", 24),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_OM", "RDMA_CQC_BODY_CQ_OM", 24),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_NXT_PBA_VLD", "RDMA_CQC_BODY_NXT_PBA_VLD", 24),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_NXT_CQ_PD_PBA_L", "RDMA_CQC_BODY_NXT_CQ_PD_PBA_L", 24),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_PI", "RDMA_CQC_BODY_CQ_PI", 32),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_PI_WRAP", "RDMA_CQC_BODY_CQ_PI_WRAP", 32),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_LAST_ARM_SN", "RDMA_CQC_BODY_LAST_ARM_SN", 32),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQE_SIZE", "RDMA_CQC_BODY_CQE_SIZE", 32),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CEQN", "RDMA_CQC_BODY_CEQN", 40),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_SHADOW_PA", "RDMA_CQC_BODY_SHADOW_PA", 48),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_CI", "RDMA_CQC_BODY_CQ_CI", 56),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_CI_WRAP", "RDMA_CQC_BODY_CQ_CI_WRAP", 56),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_ARM_SN", "RDMA_CQC_BODY_ARM_SN", 56),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_ARM_ST", "RDMA_CQC_BODY_ARM_ST", 56),
    # CMQ request/completion words.
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_VALID", "RDMA_CMQ_VALID", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_VFID_OVERRIDE", "RDMA_CMQ_VFID_OVERRIDE", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_USE_VFID", "RDMA_CMQ_USE_VFID", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_WRAP", "RDMA_CMQ_WRAP", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_INDEX", "RDMA_CMQ_WQE_INDEX", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQCQ_OPCODE", "RDMA_CMQ_OPCODE", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQCQ_CMD_ECODE", "RDMA_CMQ_CMD_ECODE", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_QPN", "RDMA_CMQ_QPN", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_SQ_CQN", "RDMA_CMQ_SQ_CQN", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_SIGN_EN", "RDMA_CMQ_SIGN_EN", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_SIGNATURE", "RDMA_CMQ_SIGNATURE", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_RQ_CQN", "RDMA_CMQ_RQ_CQN", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR", "RDMA_CMQ_QPC_BUFFER_ADDR", 24),
    # Task 11 exact QPC command and OCC-flush body fields.
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_NXT_QP_ST", "RDMA_CMQ_NEXT_QP_STATE", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_MODE", "RDMA_CMQ_MODIFY_MODE", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD0", "RDMA_CMQ_MODIFY_START_QWORD0", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_WBE0", "RDMA_CMQ_MODIFY_WBE0", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_WBE_TPL_NUM", "RDMA_CMQ_WBE_TEMPLATE_COUNT", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD1", "RDMA_CMQ_MODIFY_START_QWORD1", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_WBE1", "RDMA_CMQ_MODIFY_WBE1", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD2", "RDMA_CMQ_MODIFY_START_QWORD2", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_WBE2", "RDMA_CMQ_MODIFY_WBE2", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD3", "RDMA_CMQ_MODIFY_START_QWORD3", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_WBE3", "RDMA_CMQ_MODIFY_WBE3", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_DATA", "RDMA_CMQ_MODIFY_DATA0", 32),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_DATA", "RDMA_CMQ_MODIFY_DATA1", 40),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_DATA", "RDMA_CMQ_MODIFY_DATA2", 48),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_DATA", "RDMA_CMQ_MODIFY_DATA3", 56),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_VF_FLUSH", "RDMA_CMQ_OCC_VF_FLUSH", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_MR_SN_FLUSH", "RDMA_CMQ_OCC_MR_SERIAL_FLUSH", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_QPN", "RDMA_CMQ_OCC_QPN", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_QPC_FLAG", "RDMA_CMQ_OCC_QPC", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_CQC_FLAG", "RDMA_CMQ_OCC_CQC", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_MRT_FLAG", "RDMA_CMQ_OCC_MRT", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_PBLE_FLAG", "RDMA_CMQ_OCC_PBLE", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_SQRQE_FLAG", "RDMA_CMQ_OCC_SQRQE", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_SGB_IRQE_FLAG", "RDMA_CMQ_OCC_SGB_IRQE", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_EIRQE_FLAG", "RDMA_CMQ_OCC_EIRQE", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_ORQE_FLAG", "RDMA_CMQ_OCC_ORQE", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_UAQE_FLAG", "RDMA_CMQ_OCC_UAQE", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_PD_FLAG", "RDMA_CMQ_OCC_PD", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_MR_SN", "RDMA_CMQ_OCC_MR_SERIAL", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_PD_PBA", "RDMA_CMQ_OCC_PD_BACKING", 16),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_CQC_WQE_CQN", "RDMA_CQC_BODY_CQN", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQCQ_WQE_SRFQN", "RDMA_SRQC_BODY_SRFQN", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQCQ_WQE_EQN", "RDMA_EQC_BODY_EQN", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQCQ_WQE_RETURN_OCC_IDX", "RDMA_CMQ_COMPLETION_RETURN_OCC_IDX", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQCQ_WQE_IFA_INFO", "RDMA_CMQ_COMPLETION_IFA_INFO", 8),
    # MRT register/key-allocate sparse body is already in final WQE coordinates.
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_STAG_IDX", "RDMA_MRT_BODY_STAG_IDX", 0),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_NXT_ST", "RDMA_MRT_BODY_NXT_ST", 0),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_STAG_KEY", "RDMA_MRT_BODY_STAG_KEY", 8),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PARENT_MR_STAG_IDX", "RDMA_MRT_BODY_PARENT_STAG_IDX", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PD_IDX", "RDMA_MRT_BODY_PD_IDX", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PLD_VF_ID", "RDMA_MRT_BODY_PLD_VF_ID", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PLD_VF_EN", "RDMA_MRT_BODY_PLD_VF_EN", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_RIGHT", "RDMA_MRT_BODY_RIGHT", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_TYPE", "RDMA_MRT_BODY_TYPE", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_HOST_PG_SIZE", "RDMA_MRT_BODY_HOST_PG_SIZE", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PBL_MODE", "RDMA_MRT_BODY_PBL_MODE", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_ADDR_MODE", "RDMA_MRT_BODY_ADDR_MODE", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_INVALIDATE_EN", "RDMA_MRT_BODY_INVALIDATE_EN", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_ST", "RDMA_MRT_BODY_ST", 16),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_LEN", "RDMA_MRT_BODY_LEN", 24),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_ODP", "RDMA_MRT_BODY_ODP", 24),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_STAG_KEY", "RDMA_MRT_BODY_INFO_STAG_KEY", 24),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_START_VA", "RDMA_MRT_BODY_START_VA", 32),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_FIRST_PBL_IDX", "RDMA_MRT_BODY_FIRST_PBL_IDX", 40),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_Payload_PBA_0", "RDMA_MRT_BODY_PAYLOAD_PBA0", 40),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO1_MR_SN", "RDMA_MRT_BODY_MR_SN", 48),
    FieldMapping("cmq.h", "XTRDMA_CQPSQ_MRT_INFO1_Payload_PBA_1", "RDMA_MRT_BODY_PAYLOAD_PBA1", 48),
    # SRQC and EQC local bytes 0..31 are copied to final body bytes 16..47.
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_ST", "RDMA_SRQC_BODY_SRFQ_ST", 16),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_LOAD_SRFQ_PI_TH", "RDMA_SRQC_BODY_LOAD_SRFQ_PI_TH", 16),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_SRFQC_SHADOW_PA", "RDMA_SRQC_BODY_SHADOW_PA", 16),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_PD_IDX", "RDMA_SRQC_BODY_PD_IDX", 24),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_PD_PBA_OR_PBA", "RDMA_SRQC_BODY_SRFQ_PBA", 32),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_SIZE", "RDMA_SRQC_BODY_SRFQ_SIZE", 32),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_OM", "RDMA_SRQC_BODY_SRFQ_OM", 32),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_PI_WRAP", "RDMA_SRQC_BODY_SRFQ_PI_WRAP", 40, 16),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_PI", "RDMA_SRQC_BODY_SRFQ_PI", 40, 16),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_SRQ_LIMIT_TH", "RDMA_SRQC_BODY_LIMIT_TH", 40),
    FieldMapping("srq.h", "XTRDMA_SRFQ_CTX_ARM_SN", "RDMA_SRQC_BODY_ARM_SN", 40),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_EQ_ST", "RDMA_EQC_BODY_EQ_ST", 16),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_EQ_SIZE", "RDMA_EQC_BODY_EQ_SIZE", 16),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_NXT_EQ_PBA", "RDMA_EQC_BODY_NXT_EQ_PBA", 16),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_CUR_EQ_PBA", "RDMA_EQC_BODY_CUR_EQ_PBA", 24),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_CUR_PBA_VLD", "RDMA_EQC_BODY_CUR_PBA_VLD", 24),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_EQ_PI_WRAP", "RDMA_EQC_BODY_EQ_PI_WRAP", 32),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_EQ_PI", "RDMA_EQC_BODY_EQ_PI", 32),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_EQ_OM", "RDMA_EQC_BODY_EQ_OM", 32),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_MSI_X_IDX", "RDMA_EQC_BODY_MSI_X_IDX", 40),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_EQ_CI_WRAP", "RDMA_EQC_BODY_EQ_CI_WRAP", 40),
    FieldMapping("event.h", "XTRDMA_EQ_CTX_EQ_CI", "RDMA_EQC_BODY_EQ_CI", 40),
    # SQE/RQE/CQE fields.
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_QPN", "RDMA_SQ_WQE_QPN", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ICOS", "RDMA_SQ_WQE_ICOS", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_QP_SN", "RDMA_SQ_WQE_QP_SN", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_OPCODE", "RDMA_SQ_WQE_OPCODE", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_DST_PORT", "RDMA_SQ_WQE_DST_PORT", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_INDEX", "RDMA_SQ_WQE_INDEX", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_WRAP", "RDMA_SQ_WQE_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_SIGN_EN", "RDMA_SQ_WQE_SIGN_EN", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_SE", "RDMA_SQ_WQE_SE", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_FENCE", "RDMA_SQ_WQE_FENCE", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_INLINE_LOCAL_QPC_RD", "RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_CE", "RDMA_SQ_WQE_CE", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_VALID", "RDMA_SQ_WQE_VALID", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_SIGNATURE", "RDMA_SQ_WQE_SIGNATURE", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_RC_SGE_NUM", "RDMA_SQ_WQE_RC_SGE_NUM", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_RC_REMOTE_KEY", "RDMA_SQ_WQE_RC_REMOTE_KEY", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_RC_REMOTE_VA", "RDMA_SQ_WQE_RC_REMOTE_VA", 24),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_SGB_PA", "RDMA_SQ_WQE_SGB_PA", 32, -0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN", "RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN", 8),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_IMMDT_INVLD_RKEY", "RDMA_SQ_WQE_RC_IMMEDIATE", 8),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_LOCAL_INVLD_STAG", "RDMA_SQ_WQE_LOCAL_INVLD_STAG", 8),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ATOMIC_SGE_NUM", "RDMA_SQ_WQE_ATOMIC_SGE_NUM", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ATOMIC_R_KEY", "RDMA_SQ_WQE_ATOMIC_R_KEY", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ATOMIC_R_VA", "RDMA_SQ_WQE_ATOMIC_R_VA", 24),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ATOMIC_L_LEN", "RDMA_SQ_WQE_ATOMIC_L_LEN", 32),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ATOMIC_L_KEY", "RDMA_SQ_WQE_ATOMIC_L_KEY", 32),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ATOMIC_L_VA", "RDMA_SQ_WQE_ATOMIC_L_VA", 40),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA", "RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA", 48),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ATOMIC_CAS_SWAP_DATA", "RDMA_SQ_WQE_ATOMIC_CAS_SWAP_DATA", 48),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA", "RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA", 56),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_DST_IPV4", "RDMA_SQ_WQE_UD_DST_IPV4", 48),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_DST_IPV6_L", "RDMA_SQ_WQE_UD_DST_IPV6_L", 48),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_DST_IPV6_H", "RDMA_SQ_WQE_UD_DST_IPV6_H", 56),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_HOPLIMIT", "RDMA_SQ_WQE_UD_HOPLIMIT", 40),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_DST_QPN", "RDMA_SQ_WQE_UD_DST_QPN", 40),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_DST_Q_KEY", "RDMA_SQ_WQE_UD_DST_Q_KEY", 40),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_MC", "RDMA_SQ_WQE_UD_MC", 32),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_TRAFFIC_CLASS", "RDMA_SQ_WQE_UD_TRAFFIC_CLASS", 32),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_PRI", "RDMA_SQ_WQE_UD_PRI", 24),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_CFI", "RDMA_SQ_WQE_UD_CFI", 24),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_VLAN_ID", "RDMA_SQ_WQE_UD_VLAN_ID", 24),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_PD_IDX", "RDMA_SQ_WQE_UD_PD_IDX", 24),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_FLOW_LABLE", "RDMA_SQ_WQE_UD_FLOW_LABEL", 24),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_SRC_ADDR_IDX", "RDMA_SQ_WQE_UD_SRC_ADDR_IDX", 24),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_DMAC", "RDMA_SQ_WQE_UD_DMAC", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_SGE_NUM", "RDMA_SQ_WQE_UD_SGE_NUM", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN", "RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN", 8),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_DST_VPORT_ID", "RDMA_SQ_WQE_UD_DST_VPORT_ID", 8),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_FWD", "RDMA_SQ_WQE_UD_FWD", 8),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_LAG", "RDMA_SQ_WQE_UD_LAG", 8),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_TUNNEL", "RDMA_SQ_WQE_UD_TUNNEL", 8),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_IPV6", "RDMA_SQ_WQE_UD_IPV6", 8),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_UD_VLAN", "RDMA_SQ_WQE_UD_VLAN", 8),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_QPN", "RDMA_RQE_QPN", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_QP_SN", "RDMA_RQE_QP_SN", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_WQE_OP", "RDMA_RQE_OPCODE", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_WQE_IDX", "RDMA_RQE_INDEX", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_WQE_IDX_WRAP", "RDMA_RQE_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_VALID", "RDMA_RQE_VALID", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_TPL", "RDMA_RQE_PAYLOAD_LEN", 8),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_SIGNATURE", "RDMA_RQE_SIGNATURE", 16),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_SGE_NUM", "RDMA_RQE_SGE_NUM", 16),
    FieldMapping("wr.h", "XTRDMA_CQE_POLARITY", "RDMA_CQE_POLARITY", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_RQ_CQE", "RDMA_CQE_RQ_CQE", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_QP_WQE_WRAP", "RDMA_CQE_WQE_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_QP_WQE_INDEX", "RDMA_CQE_WQE_INDEX", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_PKT_OPCODE", "RDMA_CQE_PKT_OPCODE", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_ECODE", "RDMA_CQE_ECODE", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_QPN", "RDMA_CQE_QPN", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_IMMDT_DATA_INVLD_KEY", "RDMA_CQE_IMMDT_DATA", 8),
    FieldMapping("wr.h", "XTRDMA_CQE_PAYLOAD_LEN", "RDMA_CQE_PAYLOAD_LEN", 8),
    FieldMapping("wr.h", "XTRDMA_CQE_SIGNATURE", "RDMA_CQE_SIGNATURE", 16),
    # CEQE/AEQE fields (event consumers use qwords at byte 0 and byte 8).
    FieldMapping("defs.h", "XTRDMA_CEQE_WQE_VLD", "RDMA_CEQE_VALID", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_QPN", "RDMA_CEQE_QPN", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_CQN", "RDMA_CEQE_CQN", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_ECODE", "RDMA_CEQE_ECODE", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_PKT_OPCODE", "RDMA_CEQE_PKT_OPCODE", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_RC_CQ_PI_WRAP", "RDMA_CEQE_CQ_PI_WRAP", 8),
    FieldMapping("defs.h", "XTRDMA_CEQE_RC_CQ_PI", "RDMA_CEQE_CQ_PI", 8),
    FieldMapping("defs.h", "XTRDMA_AEQE_WQE_VLD", "RDMA_AEQE_VALID", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_QP_ST", "RDMA_AEQE_QP_ST", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_PKT_OPCODE", "RDMA_AEQE_PKT_OPCODE", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_ECODE", "RDMA_AEQE_ECODE", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_QPN", "RDMA_AEQE_QPN", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_QUEUE_WQE_IDX_WARP", "RDMA_AEQE_WQE_WRAP", 8),
    FieldMapping("defs.h", "XTRDMA_AEQE_QUEUE_WQE_IDX", "RDMA_AEQE_WQE_INDEX", 8),
    # Doorbell payloads.
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_DB_PI", "RDMA_CMQ_DB_PI", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_DB_POL", "RDMA_CMQ_DB_POLARITY", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_PI_WRAP", "RDMA_NOTIFY_RQ_PI_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_PI", "RDMA_NOTIFY_RQ_PI", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_ICOS", "RDMA_NOTIFY_RQ_ICOS", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_QPN", "RDMA_NOTIFY_RQ_QPN", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_SRFQ_WRAP", "RDMA_NOTIFY_SRFQ_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_SRFQ_PI", "RDMA_NOTIFY_SRFQ_PI", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_SRFQN", "RDMA_NOTIFY_SRFQN", 0),
    FieldMapping("wr.h", "XTRDMA_SRFQ_LIMIT_INVLD", "RDMA_NOTIFY_SRQ_LIMIT_INVALID", 0),
    FieldMapping("defs.h", "XTRDMA_SRFQ_PI_INVLD", "RDMA_NOTIFY_SRQ_PI_INVALID", 0),
    FieldMapping("defs.h", "XTRDMA_SRFQ_LIMIT_TH", "RDMA_NOTIFY_SRQ_LIMIT", 0),
    FieldMapping("defs.h", "XTRDMA_SRFQ_ARM_SN", "RDMA_NOTIFY_SRQ_ARM_SN", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_CI_INVLD", "RDMA_NOTIFY_CQ_CI_INVALID", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_INVLD", "RDMA_NOTIFY_CQ_ARM_INVALID", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_DB_FLAG", "RDMA_NOTIFY_CQ_ARM", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_FLAG", "RDMA_NOTIFY_CQ_URC", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_ST", "RDMA_NOTIFY_CQ_ARM_ST", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_SN", "RDMA_NOTIFY_CQ_ARM_SN", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_RC_CI_WRAP", "RDMA_NOTIFY_CQ_CI_WRAP", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_RC_CI", "RDMA_NOTIFY_CQ_CI", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_SQ_WQE_WRAP", "RDMA_NOTIFY_CQ_URC_SQ_WRAP", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_SQ_WQE_IDX", "RDMA_NOTIFY_CQ_URC_SQ_CI", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_RQ_WQE_WRAP", "RDMA_NOTIFY_CQ_URC_RQ_WRAP", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_RQ_WQE_IDX", "RDMA_NOTIFY_CQ_URC_RQ_CI", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_HOST_ID", "RDMA_NOTIFY_CQ_HOST_ID", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_CQN", "RDMA_NOTIFY_CQ_CQN", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_CEQ_CI_WRAP", "RDMA_NOTIFY_CEQ_CI_WRAP", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_CEQ_CI", "RDMA_NOTIFY_CEQ_CI", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_CEQ_CEQN", "RDMA_NOTIFY_CEQ_CEQN", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_AEQ_CI_WRAP", "RDMA_NOTIFY_AEQ_CI_WRAP", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_AEQ_CI", "RDMA_NOTIFY_AEQ_CI", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_AEQ_AEQN", "RDMA_NOTIFY_AEQ_AEQN", 0),
    FieldMapping("qp.h", "XTRDMA_DST_PORT", "RDMA_NOTIFY_QP_DST_PORT", 0),
    FieldMapping("qp.h", "XTRDMA_QP_SN", "RDMA_NOTIFY_QP_SN", 0),
    FieldMapping("qp.h", "XTRDMA_DB_TYPE", "RDMA_NOTIFY_QP_DB_TYPE", 0),
    FieldMapping("qp.h", "XTRDMA_ICOS", "RDMA_NOTIFY_QP_ICOS", 0),
    FieldMapping("qp.h", "XTRDMA_QPN", "RDMA_NOTIFY_QP_QPN", 0),
)


# Local context qword placements independently transcribed from the driver
# copy sites. CQC is copied at final byte +8; SRQC/EQC at final byte +16.
BODY_TRANSLATIONS = (
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CQ_SD_PBA", "RDMA_CQC_BODY_CQ_SD_PBA", 0, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CQ_SIZE", "RDMA_CQC_BODY_CQ_SIZE", 0, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_URC_FLAG", "RDMA_CQC_BODY_URC_FLAG", 0, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CQ_ST", "RDMA_CQC_BODY_CQ_ST", 0, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_NXT_CQ_PD_PBA_H", "RDMA_CQC_BODY_NXT_CQ_PD_PBA_H", 8, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CUR_PBA_VLD", "RDMA_CQC_BODY_CUR_PBA_VLD", 8, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CUR_CQ_PD_PBA", "RDMA_CQC_BODY_CUR_CQ_PD_PBA", 8, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_LOAD_CQ_CI_DONE", "RDMA_CQC_BODY_LOAD_CQ_CI_DONE", 16, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_LOAD_CQ_CI_TH", "RDMA_CQC_BODY_LOAD_CQ_CI_TH", 16, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CQ_OM", "RDMA_CQC_BODY_CQ_OM", 16, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_NXT_PBA_VLD", "RDMA_CQC_BODY_NXT_PBA_VLD", 16, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_NXT_CQ_PD_PBA_L", "RDMA_CQC_BODY_NXT_CQ_PD_PBA_L", 16, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CQ_PI", "RDMA_CQC_BODY_CQ_PI", 24, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CQ_PI_WRAP", "RDMA_CQC_BODY_CQ_PI_WRAP", 24, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_LAST_ARM_SN", "RDMA_CQC_BODY_LAST_ARM_SN", 24, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CQE_SIZE", "RDMA_CQC_BODY_CQE_SIZE", 24, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CEQN", "RDMA_CQC_BODY_CEQN", 32, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_SHADOW_PA", "RDMA_CQC_BODY_SHADOW_PA", 40, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CQ_CI", "RDMA_CQC_BODY_CQ_CI", 48, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_CQ_CI_WRAP", "RDMA_CQC_BODY_CQ_CI_WRAP", 48, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_ARM_SN", "RDMA_CQC_BODY_ARM_SN", 48, 8),
    BodyTranslation("cq.h", "XTRDMA_CMQ_CQC_ARM_ST", "RDMA_CQC_BODY_ARM_ST", 48, 8),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_ST", "RDMA_SRQC_BODY_SRFQ_ST", 0, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_LOAD_SRFQ_PI_TH", "RDMA_SRQC_BODY_LOAD_SRFQ_PI_TH", 0, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_SRFQC_SHADOW_PA", "RDMA_SRQC_BODY_SHADOW_PA", 0, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_PD_IDX", "RDMA_SRQC_BODY_PD_IDX", 8, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_PD_PBA_OR_PBA", "RDMA_SRQC_BODY_SRFQ_PBA", 16, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_SIZE", "RDMA_SRQC_BODY_SRFQ_SIZE", 16, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_OM", "RDMA_SRQC_BODY_SRFQ_OM", 16, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_PI_WRAP", "RDMA_SRQC_BODY_SRFQ_PI_WRAP", 24, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_PI", "RDMA_SRQC_BODY_SRFQ_PI", 24, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_SRQ_LIMIT_TH", "RDMA_SRQC_BODY_LIMIT_TH", 24, 16),
    BodyTranslation("srq.h", "XTRDMA_SRFQ_CTX_ARM_SN", "RDMA_SRQC_BODY_ARM_SN", 24, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_EQ_ST", "RDMA_EQC_BODY_EQ_ST", 0, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_EQ_SIZE", "RDMA_EQC_BODY_EQ_SIZE", 0, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_NXT_EQ_PBA", "RDMA_EQC_BODY_NXT_EQ_PBA", 0, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_CUR_EQ_PBA", "RDMA_EQC_BODY_CUR_EQ_PBA", 8, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_CUR_PBA_VLD", "RDMA_EQC_BODY_CUR_PBA_VLD", 8, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_EQ_PI_WRAP", "RDMA_EQC_BODY_EQ_PI_WRAP", 16, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_EQ_PI", "RDMA_EQC_BODY_EQ_PI", 16, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_EQ_OM", "RDMA_EQC_BODY_EQ_OM", 16, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_MSI_X_IDX", "RDMA_EQC_BODY_MSI_X_IDX", 24, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_EQ_CI_WRAP", "RDMA_EQC_BODY_EQ_CI_WRAP", 24, 16),
    BodyTranslation("event.h", "XTRDMA_EQ_CTX_EQ_CI", "RDMA_EQC_BODY_EQ_CI", 24, 16),
)


VALUE_MAPPINGS = (
    ValueMapping("qp.h", "XTRDMA_QP_CONTEXT_SIZE", "RDMA_QPC_BYTES"),
    ValueMapping("cq.h", "XTRDMA_CQ_CONTEXT_SIZE", "RDMA_CQC_BYTES"),
    ValueMapping("cmq.h", "XTRDMA_CMQE_SIZE", "RDMA_CMQE_BYTES"),
    ValueMapping("wr.h", "XTRDMA_WQE_SIZE", "RDMA_WQE_BYTES"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_CEQE_SIZE", "RDMA_CEQE_BYTES"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_AEQE_SIZE", "RDMA_AEQE_BYTES"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_BAR_OFFSET", "RDMA_NOTIFY_WINDOW_OFFSET"),
    ValueMapping("map.h", "XTRDMA_USER_MMAP_DB_LEN", "RDMA_NOTIFY_WINDOW_SIZE"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_CMQ_DB", "RDMA_DB_CMQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_SQ_DB", "RDMA_DB_SQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_RQ_DB", "RDMA_DB_RQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_CQ_DB", "RDMA_DB_CQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_CEQ_DB", "RDMA_DB_CEQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_AEQ_DB", "RDMA_DB_AEQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_SRFQ_DB", "RDMA_DB_SRFQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_RTS2SQD_DB", "RDMA_DB_RTS2SQD_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_SQD2RTS_DB", "RDMA_DB_SQD2RTS_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_FLUSH_QP_DB", "RDMA_DB_QP_FLUSH_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_FLUSH_TX_DB", "RDMA_DB_TX_FLUSH_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("wr.h", "XTRDMA_SRFQ_LIMIT_INVLD_VAL", "RDMA_NOTIFY_SRQ_LIMIT_INVALID_VALUE"),
    ValueMapping("srq.h", "XTRDMA_SRFQ_DB_INVLD", "RDMA_NOTIFY_SRQ_PI_INVALID_VALUE"),
    ValueMapping("qp.h", "XTRDMA_DB_QP_FLUSH", "RDMA_DB_TYPE_QP_FLUSH"),
    ValueMapping("qp.h", "XTRDMA_DB_TX_FLUSH", "RDMA_DB_TYPE_TX_FLUSH"),
    ValueMapping("qp.h", "XTRDMA_DB_RTS2SQD", "RDMA_DB_TYPE_RTS2SQD"),
    ValueMapping("qp.h", "XTRDMA_DB_SQD2RTS", "RDMA_DB_TYPE_SQD2RTS"),
    ValueMapping("eth_header/register.h", "QSCH_G2P_DPORT_NODE_MODE", "RDMA_TX_FLUSH_DST_PORT"),
    # SQ WQE opcodes are implicit values in wr.h's xtrdma_sq_wqe_opcode enum.
    ValueMapping("wr.h", "XTRDMA_WQE_SEND", "RDMA_SQ_OPCODE_SEND"),
    ValueMapping("wr.h", "XTRDMA_WQE_SEND_WITH_IMM", "RDMA_SQ_OPCODE_SEND_WITH_IMM"),
    ValueMapping("wr.h", "XTRDMA_WQE_SEND_WITH_INV", "RDMA_SQ_OPCODE_SEND_WITH_INV"),
    ValueMapping("wr.h", "XTRDMA_WQE_WRITE", "RDMA_SQ_OPCODE_WRITE"),
    ValueMapping("wr.h", "XTRDMA_WQE_WRITE_WITH_IMM", "RDMA_SQ_OPCODE_WRITE_WITH_IMM"),
    ValueMapping("wr.h", "XTRDMA_WQE_READ", "RDMA_SQ_OPCODE_READ"),
    ValueMapping("wr.h", "XTRDMA_WQE_ATOMIC_CMP_AND_SWP", "RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP"),
    ValueMapping("wr.h", "XTRDMA_WQE_ATOMIC_FETCH_AND_ADD", "RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD"),
    ValueMapping("wr.h", "XTRDMA_WQE_LOCAL_INV", "RDMA_SQ_OPCODE_LOCAL_INV"),
    # Explicit enum values needed by the next CMQ/error-code codecs.
    ValueMapping("cmq.h", "XTRDMA_OP_QPC_CREATE", "RDMA_OP_QPC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_QPC_MODIFY", "RDMA_OP_QPC_MODIFY"),
    ValueMapping("cmq.h", "XTRDMA_OP_QPC_DELETE", "RDMA_OP_QPC_DELETE"),
    ValueMapping("cmq.h", "XTRDMA_OP_QPC_QUERY", "RDMA_OP_QPC_QUERY"),
    ValueMapping("cmq.h", "XTRDMA_OP_KEY_ALLOC", "RDMA_OP_KEY_ALLOC"),
    ValueMapping("cmq.h", "XTRDMA_OP_MR_REGISTER", "RDMA_OP_MR_REGISTER"),
    ValueMapping("cmq.h", "XTRDMA_OP_MR_DEREGISTER", "RDMA_OP_MR_DEREGISTER"),
    ValueMapping("cmq.h", "XTRDMA_OP_OCC_FLUSH", "RDMA_OP_OCC_FLUSH"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_RESIZE", "RDMA_OP_CQC_RESIZE"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_CREATE", "RDMA_OP_CQC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_MODIFY", "RDMA_OP_CQC_MODIFY"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_DELETE", "RDMA_OP_CQC_DELETE"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_QUERY", "RDMA_OP_CQC_QUERY"),
    ValueMapping("cmq.h", "XTRDMA_OP_CEQC_CREATE", "RDMA_OP_CEQC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_CEQC_DELETE", "RDMA_OP_CEQC_DELETE"),
    ValueMapping("cmq.h", "XTRDMA_OP_CEQC_QUERY", "RDMA_OP_CEQC_QUERY"),
    ValueMapping("cmq.h", "XTRDMA_OP_AEQC_CREATE", "RDMA_OP_AEQC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_AEQC_DELETE", "RDMA_OP_AEQC_DELETE"),
    ValueMapping("cmq.h", "XTRDMA_OP_AEQC_QUERY", "RDMA_OP_AEQC_QUERY"),
    ValueMapping("cmq.h", "XTRDMA_OP_QP_FLUSH", "RDMA_OP_QP_FLUSH"),
    ValueMapping("cmq.h", "XTRDMA_OP_TQ_FLUSH", "RDMA_OP_TQ_FLUSH"),
    ValueMapping("cmq.h", "XTRDMA_OP_SRFQC_CREATE", "RDMA_OP_SRFQC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_SRFQC_DELETE", "RDMA_OP_SRFQC_DELETE"),
    ValueMapping("cmq.h", "XTRDMA_OP_SRFQC_QUERY", "RDMA_OP_SRFQC_QUERY"),
    ValueMapping("cmq.h", "XTRDMA_OP_NOP", "RDMA_OP_NOP"),
    ValueMapping("qp.h", "XTRDMA_MODIFY_MODE_ONLY_ST", "RDMA_QPC_MODIFY_STATE_ONLY"),
    ValueMapping("qp.h", "XTRDMA_MODIFY_MODE_FULL_QPC", "RDMA_QPC_MODIFY_FULL"),
    ValueMapping("qp.h", "XTRDMA_MODIFY_MODE_PARTIAL_QPC", "RDMA_QPC_MODIFY_PARTIAL"),
    # Context object/state/mode codes consumed by Task 10 codecs.
    ValueMapping("alloc.h", "XTRDMA_ALLOC_TYPE_DIRECT", "RDMA_ALLOC_TYPE_DIRECT"),
    ValueMapping("alloc.h", "XTRDMA_ALLOC_TYPE_INDIRECT", "RDMA_ALLOC_TYPE_INDIRECT"),
    ValueMapping("alloc.h", "XTRDMA_ALLOC_TYPE_HUGE", "RDMA_ALLOC_TYPE_HUGE"),
    ValueMapping("alloc.h", "XTRDMA_ALLOC_TYPE_L3_INDIRECT", "RDMA_ALLOC_TYPE_L3_INDIRECT"),
    ValueMapping("mr.h", "XTRDMA_ADDR_TYPE_VA_BASED", "RDMA_ADDR_TYPE_VA_BASED"),
    ValueMapping("mr.h", "XTRDMA_ADDR_TYPE_ZERO_BASED", "RDMA_ADDR_TYPE_ZERO_BASED"),
    ValueMapping("mr.h", "XTRDMA_MR_ST_INVLD", "RDMA_MR_ST_INVALID"),
    ValueMapping("mr.h", "XTRDMA_MR_ST_FREE", "RDMA_MR_ST_FREE"),
    ValueMapping("mr.h", "XTRDMA_MR_ST_VLD", "RDMA_MR_ST_VALID"),
    ValueMapping("mr.h", "XTRDMA_HOST_PAGE_4K", "RDMA_HOST_PAGE_4K"),
    ValueMapping("mr.h", "XTRDMA_HOST_PAGE_2M", "RDMA_HOST_PAGE_2M"),
    ValueMapping("mr.h", "XTRDMA_HOST_PAGE_1G", "RDMA_HOST_PAGE_1G"),
    ValueMapping("mr.h", "PBL_MODE_0", "RDMA_PBL_MODE_0"),
    ValueMapping("mr.h", "PBL_MODE_1", "RDMA_PBL_MODE_1"),
    ValueMapping("mr.h", "PBL_MODE_2", "RDMA_PBL_MODE_2"),
    ValueMapping("mr.h", "XTRDMA_MR", "RDMA_MEM_TYPE_MR"),
    ValueMapping("mr.h", "XTRDMA_MW_TYPE1", "RDMA_MEM_TYPE_MW_TYPE1"),
    ValueMapping("mr.h", "XTRDMA_MW_TYPE2B", "RDMA_MEM_TYPE_MW_TYPE2B"),
    ValueMapping("mr.h", "XTRDMA_MW_INVLD_DISABLE", "RDMA_INVALIDATE_DISABLE"),
    ValueMapping("mr.h", "XTRDMA_MW_INVLD_EN", "RDMA_INVALIDATE_ENABLE"),
    ValueMapping("cq.h", "XTRDMA_CQC_ARM_ST_NO_EVENT", "RDMA_CQC_ARM_ST_NO_EVENT"),
    ValueMapping("cq.h", "XTRDMA_CQC_ARM_ST_NEXT_SE_ONLY_EVENT", "RDMA_CQC_ARM_ST_NEXT_SE"),
    ValueMapping("cq.h", "XTRDMA_CQC_ARM_ST_NEXT_COMP_EVENT", "RDMA_CQC_ARM_ST_NEXT_COMP"),
    ValueMapping("cq.h", "XTRDMA_CQC_CQ_ST_INVLD", "RDMA_CQC_ST_INVALID"),
    ValueMapping("cq.h", "XTRDMA_CQC_CQ_ST_VLD", "RDMA_CQC_ST_VALID"),
    ValueMapping("cq.h", "XTRDMA_CQC_CQ_ST_ERR", "RDMA_CQC_ST_ERROR"),
    ValueMapping("srq.h", "XTRDMA_SRQ_STATE_INVLD", "RDMA_SRQC_ST_INVALID"),
    ValueMapping("srq.h", "XTRDMA_SRQ_STATE_VALID", "RDMA_SRQC_ST_VALID"),
    ValueMapping("srq.h", "XTRDMA_SRQ_STATE_ERROR", "RDMA_SRQC_ST_ERROR"),
    ValueMapping("event.h", "XTRDMA_EVENT_STATE_INVLD", "RDMA_EQC_ST_INVALID"),
    ValueMapping("event.h", "XTRDMA_EVENT_STATE_VALID", "RDMA_EQC_ST_VALID"),
    ValueMapping("event.h", "XTRDMA_EVENT_STATE_ERROR", "RDMA_EQC_ST_ERROR"),
    ValueMapping("defs.h", "XTRDMA_ACCESS_FLAGS_LOCAL_WRITE", "RDMA_RIGHT_LOCAL_WRITE"),
    ValueMapping("defs.h", "XTRDMA_ACCESS_FLAGS_REMOTE_READ", "RDMA_RIGHT_REMOTE_READ"),
    ValueMapping("defs.h", "XTRDMA_ACCESS_FLAGS_REMOTE_WRITE", "RDMA_RIGHT_REMOTE_WRITE"),
    ValueMapping("defs.h", "XTRDMA_ACCESS_FLAGS_BIND_WINDOW", "RDMA_RIGHT_BIND_WINDOW"),
    ValueMapping("defs.h", "XTRDMA_ACCESS_FLAGS_REMOTE_ATOMIC", "RDMA_RIGHT_REMOTE_ATOMIC"),
)

# Normalized input-right sets and their hardware result bits, independently
# checked against the pinned xtrdma_get_access implementation.
ACCESS_PROJECTIONS = (
    ("IB_ACCESS_LOCAL_WRITE|IB_ACCESS_REMOTE_WRITE|IB_ACCESS_REMOTE_ATOMIC",
     "XTRDMA_ACCESS_FLAGS_LOCAL_WRITE"),
    ("IB_ACCESS_REMOTE_WRITE", "XTRDMA_ACCESS_FLAGS_REMOTE_WRITE"),
    ("IB_ACCESS_REMOTE_READ", "XTRDMA_ACCESS_FLAGS_REMOTE_READ"),
    ("IB_ACCESS_MW_BIND", "XTRDMA_ACCESS_FLAGS_BIND_WINDOW"),
    ("IB_ACCESS_REMOTE_ATOMIC", "XTRDMA_ACCESS_FLAGS_REMOTE_ATOMIC"),
)

PROFILE_VALUES = {
    "RDMA_HW_VERSION": 1,
    "RDMA_RQE_BYTES": 64,
    "RDMA_CQE_BYTES": 64,
    "RDMA_DB_BYTES": 8,
    # CMQ completion zero is a profile success code, not a claim that the
    # wr.h TX_REQ_NML identity describes a CMQ completion.
    "RDMA_CMQ_SUCCESS_ECODE": 0,
    # Raw destination-IP bytes are not a mask-backed qword field, so their
    # placement is frozen as independently checked profile metadata.
    "RDMA_QPC_DEST_IP_BYTE_OFFSET": 80,
    "RDMA_QPC_DEST_IP_BYTES": 16,
}


def parse_field_expression(expression: str) -> tuple[int, int]:
    expr = expression.strip()
    bit_match = re.fullmatch(r"BIT(?:_ULL)?\(\s*(\d+)\s*\)", expr)
    if bit_match:
        bit = int(bit_match.group(1))
        if bit > 63:
            raise ValidationError(f"invalid BIT position {bit}: {expression}")
        return bit, 1
    mask_match = re.fullmatch(
        r"GENMASK(?:_ULL)?\(\s*(\d+)\s*,\s*(\d+)\s*\)", expr
    )
    if mask_match:
        high, low = map(int, mask_match.groups())
        if high < low or high > 63:
            raise ValidationError(f"invalid GENMASK range: {expression}")
        return low, high - low + 1
    raise ValidationError(f"unsupported mapped C field expression: {expression}")


def parse_value_expression(expression: str) -> int:
    expr = expression.strip()
    if not re.fullmatch(r"(?:0[xX][0-9a-fA-F]+|[0-9]+)(?:[uUlL]+)?", expr):
        raise ValidationError(f"unsupported mapped C value expression: {expression}")
    expr = re.sub(r"[uUlL]+$", "", expr)
    return int(expr, 0)


def parse_sv_value(expression: str) -> int:
    expr = expression.strip().replace("_", "")
    match = re.fullmatch(r"(?:\d+)'([hHdD])([0-9a-fA-F]+)", expr)
    if match:
        return int(match.group(2), 16 if match.group(1).lower() == "h" else 10)
    if re.fullmatch(r"(?:0[xX][0-9a-fA-F]+|[0-9]+)", expr):
        return int(expr, 0)
    raise ValidationError(f"unsupported SV constant expression: {expression}")


def strip_sv_comments(text: str) -> str:
    """Remove SV comments while preserving strings and source layout."""
    result: list[str] = []
    index = 0
    state = "code"
    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "code":
            if char == '"':
                result.append(char)
                state = "string"
                index += 1
            elif char == "/" and following == "/":
                result.extend((" ", " "))
                state = "line_comment"
                index += 2
            elif char == "/" and following == "*":
                result.extend((" ", " "))
                state = "block_comment"
                index += 2
            else:
                result.append(char)
                index += 1
        elif state == "string":
            result.append(char)
            index += 1
            if char == "\\" and index < len(text):
                result.append(text[index])
                index += 1
            elif char == '"':
                state = "code"
        elif state == "line_comment":
            result.append(char if char in "\r\n" else " ")
            index += 1
            if char == "\n":
                state = "code"
        else:
            if char == "*" and following == "/":
                result.extend((" ", " "))
                state = "code"
                index += 2
            else:
                result.append(char if char in "\r\n" else " ")
                index += 1
    return "".join(result)


def mask_sv_strings(text: str) -> str:
    """Blank quoted SV strings while preserving source positions and lines."""
    result: list[str] = []
    index = 0
    in_string = False
    while index < len(text):
        char = text[index]
        if not in_string:
            if char == '"':
                result.append(" ")
                in_string = True
            else:
                result.append(char)
            index += 1
            continue

        result.append(char if char in "\r\n" else " ")
        index += 1
        if char == "\\" and index < len(text):
            escaped = text[index]
            result.append(escaped if escaped in "\r\n" else " ")
            index += 1
        elif char == '"':
            in_string = False
    return "".join(result)


def validate_error_codec_preprocessor(codec_code: str) -> None:
    """Allow only the one required macro invocation in the error codec."""
    approved = list(
        re.finditer(
            r"^[ \t]*`uvm_object_utils\(rdma_hw_error_codec\)"
            r"[ \t]*(?=\r?$)",
            codec_code,
            re.M,
        )
    )
    backticks = [match.start() for match in re.finditer(r"`", codec_code)]
    if (
        len(approved) != 1
        or len(backticks) != 1
        or not approved[0].start() <= backticks[0] < approved[0].end()
    ):
        raise ValidationError(
            "error codec preprocessor use differs from approved macro"
        )


def tokenize_sv_syntax(text: str) -> list[str]:
    """Tokenize enough SV syntax to audit hardware-code use sites."""
    based_literal = re.compile(
        r"\d+\s*'\s*[sS]?\s*[hHdDbBoO]\s*[0-9a-fA-F_xXzZ?]+"
    )
    token_pattern = re.compile(
        rf"{based_literal.pattern}"
        r"|[A-Za-z_]\w*|===|!==|==|!=|&&|\|\||<<|>>|[^\s]"
    )
    tokens = [match.group(0) for match in token_pattern.finditer(text)]
    return [
        re.sub(r"\s+", "", token)
        if based_literal.fullmatch(token)
        else token
        for token in tokens
    ]


class SvFunctionRegion(NamedTuple):
    name: str
    header_start: int
    body_start: int
    body_end: int


def parse_sv_function_regions(tokens: list[str]) -> list[SvFunctionRegion]:
    """Return non-nested function token ranges from a codec source."""
    regions: list[SvFunctionRegion] = []
    position = 0
    while position < len(tokens):
        try:
            header_start = tokens.index("function", position)
        except ValueError:
            break
        try:
            body_start = tokens.index(";", header_start + 1) + 1
            body_end = tokens.index("endfunction", body_start)
            arguments = tokens.index("(", header_start + 1, body_start)
        except ValueError as error:
            raise ValidationError("invalid SV function syntax in error codec") from error
        if arguments == header_start + 1:
            raise ValidationError("invalid SV function syntax in error codec")
        regions.append(
            SvFunctionRegion(
                tokens[arguments - 1], header_start, body_start, body_end
            )
        )
        position = body_end + 1
    return regions


def matching_token_patterns(
    tokens: list[str], pattern: list[str], start: int, end: int
) -> list[int]:
    """Return starts of an exact token pattern inside one function range."""
    return [
        index
        for index in range(start, end - len(pattern) + 1)
        if tokens[index:index + len(pattern)] == pattern
    ]


def matching_statement_patterns(
    tokens: list[str], pattern: list[str], start: int, end: int
) -> list[int]:
    """Return exact token patterns that also start at a statement boundary."""
    return [
        index
        for index in matching_token_patterns(tokens, pattern, start, end)
        if index == start or tokens[index - 1] in {";", "begin", "else"}
    ]


def validate_outer_case_default_is_last(
    case_body: str, function_name: str
) -> None:
    """Require one depth-zero default whose statement consumes the case tail."""
    tokens = tokenize_sv_syntax(case_body)
    case_depth = 0
    defaults: list[int] = []
    for index, token in enumerate(tokens):
        if token == "case":
            case_depth += 1
        elif token == "endcase":
            if case_depth == 0:
                raise ValidationError(
                    f"invalid nested case in {function_name} default"
                )
            case_depth -= 1
        elif (
            token == "default"
            and case_depth == 0
            and index + 1 < len(tokens)
            and tokens[index + 1] == ":"
        ):
            defaults.append(index)
    if case_depth != 0 or len(defaults) != 1:
        raise ValidationError(
            f"hardware error case must have one outer default: {function_name}"
        )

    statement_start = defaults[0] + 2
    statement_end: int | None = None
    if statement_start < len(tokens) and tokens[statement_start] == "begin":
        block_depth = 0
        for index in range(statement_start, len(tokens)):
            if tokens[index] == "begin":
                block_depth += 1
            elif tokens[index] == "end":
                block_depth -= 1
                if block_depth == 0:
                    statement_end = index + 1
                    break
    else:
        try:
            statement_end = tokens.index(";", statement_start) + 1
        except ValueError:
            pass
    if statement_end is None or statement_end != len(tokens):
        raise ValidationError(
            f"hardware error default must be final case item: {function_name}"
        )


def validate_hardware_code_uses(codec_code: str) -> None:
    """Fail closed unless every hardware_code token has a pinned role."""
    tokens = tokenize_sv_syntax(codec_code)
    regions = parse_sv_function_regions(tokens)
    regions_by_name: dict[str, list[SvFunctionRegion]] = {}
    for region in regions:
        regions_by_name.setdefault(region.name, []).append(region)

    required_names = {
        "classify", "inferred_engine", "symbolic_name", "decode_status"
    }
    for name in required_names:
        if len(regions_by_name.get(name, [])) != 1:
            raise ValidationError(f"hardware error function differs: {name}")

    approved: set[int] = set()
    formal_prefix = ["bit", "[", "7", ":", "0", "]"]
    for region in regions:
        formals = []
        for index in range(region.header_start, region.body_start):
            if tokens[index] != "hardware_code":
                continue
            if (
                tokens[max(region.header_start, index - len(formal_prefix)):index]
                == formal_prefix
                and index + 1 < region.body_start
                and tokens[index + 1] in {",", ")"}
            ):
                approved.add(index)
                formals.append(index)
        if region.name in required_names and len(formals) != 1:
            raise ValidationError(
                f"hardware_code formal differs in {region.name}"
            )

    case_pattern = ["case", "(", "hardware_code", ")"]
    for name in ("classify", "inferred_engine", "symbolic_name"):
        region = regions_by_name[name][0]
        selectors = matching_token_patterns(
            tokens, case_pattern, region.body_start, region.body_end
        )
        if len(selectors) != 1:
            raise ValidationError(f"hardware_code case selector differs in {name}")
        approved.add(selectors[0] + 2)

    symbolic = regions_by_name["symbolic_name"][0]
    format_pattern = ["$", "sformatf", "(", ",", "hardware_code", ")"]
    format_uses = matching_token_patterns(
        tokens, format_pattern, symbolic.body_start, symbolic.body_end
    )
    if len(format_uses) != 1:
        raise ValidationError("symbolic hardware_code format output differs")
    approved.add(format_uses[0] + 4)

    decode = regions_by_name["decode_status"][0]
    call_patterns = (
        (
            "classify",
            ["code", "=", "classify", "(", "hardware_code", ")", ";"],
            4,
        ),
        (
            "inferred_engine",
            [
                "source_engine", "=", "inferred_engine", "(",
                "hardware_code", ",", "code", ")", ";",
            ],
            4,
        ),
        (
            "symbolic_name",
            [
                "candidate", ".", "message", "=", "symbolic_name", "(",
                "hardware_code", ")", ";",
            ],
            6,
        ),
    )
    for callee, pattern, offset in call_patterns:
        starts = matching_statement_patterns(
            tokens, pattern, decode.body_start, decode.body_end
        )
        if len(starts) != 1:
            raise ValidationError(
                f"decode_status {callee} hardware_code call differs"
            )
        approved.add(starts[0] + offset)

    success = "RDMA_CMQ_SUCCESS_ECODE"
    success_patterns = (
        (["if", "(", "hardware_code", "==", success, ")"], 2),
        (["if", "(", success, "==", "hardware_code", ")"], 4),
    )
    success_uses: list[int] = []
    for pattern, offset in success_patterns:
        success_uses.extend(
            start + offset
            for start in matching_statement_patterns(
                tokens, pattern, decode.body_start, decode.body_end
            )
        )
    if len(success_uses) != 1:
        raise ValidationError(
            "hardware_code use in decode_status pinned success comparison differs"
        )
    approved.update(success_uses)

    assignment_patterns = (
        (["candidate", ".", "hardware_code", "=", "'", "0", ";"], (2,)),
        (
            [
                "candidate", ".", "hardware_code", "=", "{", "24'h0",
                ",", "hardware_code", "}", ";",
            ],
            (2, 7),
        ),
    )
    for pattern, offsets in assignment_patterns:
        starts = matching_statement_patterns(
            tokens, pattern, decode.body_start, decode.body_end
        )
        if len(starts) != 1:
            raise ValidationError("decode_status hardware_code assignment differs")
        approved.update(starts[0] + offset for offset in offsets)

    for index, token in enumerate(tokens):
        if token == "hardware_code" and index not in approved:
            raise ValidationError("hardware_code use is not approved")


def parse_sv_constants(text: str) -> dict[str, int]:
    text = mask_sv_strings(strip_sv_comments(text))
    constants: dict[str, int] = {}

    def add(name: str, value: int) -> None:
        if name in constants:
            raise ValidationError(f"duplicate SV constant: {name}")
        constants[name] = value

    pattern = re.compile(
        r"\blocalparam\s+(?:int\s+unsigned|longint\s+unsigned|bit\s*\[[^]]+\])"
        r"\s+(RDMA_[A-Za-z0-9_]+)\s*=\s*([^;]+);"
    )
    for match in pattern.finditer(text):
        name = match.group(1)
        add(name, parse_sv_value(match.group(2)))
    field_pattern = re.compile(
        r"`RDMA_FIELD\(\s*(RDMA_[A-Za-z0-9_]+)\s*,\s*(\d+)\s*,"
        r"\s*(\d+)\s*,\s*(\d+)\s*\)"
    )
    for match in field_pattern.finditer(text):
        stem = match.group(1)
        word_byte_offset, lsb, width = map(int, match.groups()[1:])
        add(f"{stem}_WORD_BYTE_OFFSET", word_byte_offset)
        add(f"{stem}_LSB", lsb)
        add(f"{stem}_WIDTH", width)
        add(f"{stem}_OFFSET", word_byte_offset * 8 + lsb)
    return constants


def parse_sq_field_mappings(text: str) -> dict[str, tuple[str, str, int, int]]:
    """Parse and validate the SQE field declarations from an SV defs file."""
    clean = mask_sv_strings(strip_sv_comments(text))
    declared: dict[str, tuple[int, int, int]] = {}
    pattern = re.compile(
        r"`RDMA_FIELD\(\s*(RDMA_SQ_[A-Za-z0-9_]+)\s*,\s*(\d+)\s*,"
        r"\s*(\d+)\s*,\s*(\d+)\s*\)"
    )
    for match in pattern.finditer(clean):
        stem, word, lsb, width = match.group(1), *map(int, match.groups()[1:])
        if stem in declared:
            raise ValidationError(f"duplicate SQ field mapping: {stem}")
        if width < 1 or lsb < 0 or lsb + width > 64:
            raise ValidationError(f"invalid SQ field coordinates: {stem}")
        declared[stem] = (word, lsb, width)
    mappings = {m.sv_stem: m for m in FIELD_MAPPINGS if m.sv_stem.startswith("RDMA_SQ_")}
    references = {r.sv_stem: r for r in REFERENCE_FIELDS if r.sv_stem.startswith("RDMA_SQ_")}
    missing = sorted(set(mappings) - set(declared))
    if missing:
        raise ValidationError(f"SQ field mapping missing: {missing}")
    extra = sorted(set(declared) - set(mappings))
    if extra:
        raise ValidationError(f"unexpected SQ field mapping: {extra}")
    for stem, (word, lsb, width) in declared.items():
        mapping = mappings[stem]
        reference = references.get(stem)
        if word != mapping.word_byte_offset:
            raise ValidationError(f"SQ field byte offset drift: {stem}")
        if reference is None or (lsb, width) != (reference.lsb, reference.width):
            raise ValidationError(f"SQ field coordinate drift: {stem}")
    return {
        stem: (mappings[stem].path, mappings[stem].c_symbol, lsb, width)
        for stem, (_, lsb, width) in declared.items()
    } | {
        # The 16-byte destination-IP memcpy is represented by the two
        # independently mapped IPv6 qwords; this name is a convenience alias
        # for callers that treat the raw range as one field.
        "RDMA_SQ_WQE_UD_DST_IP": ("wr.h", "XTRDMA_SQ_WQE_UD_DST_IPV6_L", 0, 64)
    }


def _sq_header(
    image: ReferenceImage,
    opcode: int,
    *,
    inline: bool = False,
    se: bool = False,
    index: int = 0x1234,
) -> None:
    """Populate the common SQE header using the pinned logical coordinates."""
    put_named(image, "RDMA_SQ_WQE_QPN", 0x15555)
    put_named(image, "RDMA_SQ_WQE_ICOS", 5)
    put_named(image, "RDMA_SQ_WQE_QP_SN", 0xA6)
    put_named(image, "RDMA_SQ_WQE_OPCODE", opcode)
    put_named(image, "RDMA_SQ_WQE_DST_PORT", 11)
    put_named(image, "RDMA_SQ_WQE_INDEX", index)
    put_named(image, "RDMA_SQ_WQE_WRAP", 0)
    put_named(image, "RDMA_SQ_WQE_SIGN_EN", 1)
    put_named(image, "RDMA_SQ_WQE_SE", int(se))
    put_named(image, "RDMA_SQ_WQE_FENCE", 0)
    put_named(image, "RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD", int(inline))
    put_named(image, "RDMA_SQ_WQE_CE", 1)
    put_named(image, "RDMA_SQ_WQE_VALID", 1)


def _sq_sge(sgb: ReferenceImage, slot: int, length: int, lkey: int, iova: int) -> None:
    """Encode one 16-byte SGE in the driver's two-qword format."""
    if slot < 0 or slot >= 32:
        raise ValidationError("SQ SGB slot is outside the 512-byte image")
    base = slot * 16 * 8
    put_field(sgb, base + 32, 32, length if length != (1 << 31) else 0)
    put_field(sgb, base, 32, lkey)
    put_field(sgb, base + 64, 64, iova)


def _build_sq_golden_cases() -> tuple[list[GoldenCase], dict[str, bytes]]:
    """Build operation-specific SQE/SGB vectors from the pinned coordinates."""
    cases: list[GoldenCase] = []
    sgb_images: dict[str, bytes] = {"sgb_boundary": bytes(512)}
    sgb_iova = 0x20000  # 512-byte aligned address used by the SGB pointer field.

    def add(name: str, summary: str, image: ReferenceImage, sgb: bytes | None = None) -> None:
        cases.append(GoldenCase(name, parse_input_summary(summary), bytes(image)))
        if sgb is not None:
            sgb_images[name] = sgb

    def rc_payload(name: str, length: int, *, opcode: int = 1, inline: bool = True,
                   immediate: int | None = None, remote: bool = False) -> None:
        image = ReferenceImage(64)
        _sq_header(image, opcode, inline=inline, se=opcode in (1, 2, 5), index=length + 0x1200)
        put_named(image, "RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN", length)
        put_named(image, "RDMA_SQ_WQE_SIGNATURE", 0)
        put_named(image, "RDMA_SQ_WQE_RC_SGE_NUM", 0)
        if immediate is not None:
            put_named(image, "RDMA_SQ_WQE_RC_IMMEDIATE", immediate)
        if remote:
            put_named(image, "RDMA_SQ_WQE_RC_REMOTE_KEY", 0xDEADBEEF)
            put_named(image, "RDMA_SQ_WQE_RC_REMOTE_VA", 0x0123456789ABCDEF)
        sgb: bytes | None = None
        if inline and length <= 32:
            image[32:32 + length] = bytes((0xA0 + i) & 0xFF for i in range(length))
        elif inline:
            put_named(image, "RDMA_SQ_WQE_SGB_PA", sgb_iova)
            sgb = bytes((0xA0 + i) & 0xFF for i in range(length)) + bytes(512 - length)
        add(name, f"case={name},opcode={opcode},length={length},mode={'inline' if inline else 'direct'}", image, sgb)

    rc_payload("sqe_rc_boundary", 1)
    rc_payload("rc_inline_1", 1)
    rc_payload("rc_inline_32", 32)
    rc_payload("rc_inline_33", 33)
    rc_payload("rc_inline_512", 512)

    def direct_sge(name: str, count: int) -> None:
        image = ReferenceImage(64)
        _sq_header(image, 1, inline=False, se=True, index=0x1300 + count)
        put_named(image, "RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN", count * 8)
        put_named(image, "RDMA_SQ_WQE_SIGNATURE", 0)
        put_named(image, "RDMA_SQ_WQE_RC_SGE_NUM", count)
        for slot in range(count):
            base = 32 + slot * 16
            put_field(image, base * 8 + 32, 32, 8)
            put_field(image, base * 8, 32, 0x1000 + slot)
            put_field(image, (base + 8) * 8, 64, 0x100000 + slot * 8)
        add(name, f"case={name},opcode=1,count={count},mode=direct", image)

    direct_sge("rc_sge_direct_1", 1)
    direct_sge("rc_sge_direct_2", 2)

    def sgb_sge(name: str, count: int) -> None:
        image = ReferenceImage(64)
        _sq_header(image, 1, inline=False, se=True, index=0x1400 + count)
        put_named(image, "RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN", count * 8)
        put_named(image, "RDMA_SQ_WQE_SIGNATURE", 0)
        put_named(image, "RDMA_SQ_WQE_RC_SGE_NUM", count)
        put_named(image, "RDMA_SQ_WQE_SGB_PA", sgb_iova)
        sgb = ReferenceImage(512)
        for slot in range(count):
            _sq_sge(sgb, slot, 8, 0x2000 + slot, 0x200000 + slot * 8)
        add(name, f"case={name},opcode=1,count={count},mode=sgb", image, bytes(sgb))

    sgb_sge("rc_sge_sgb_3", 3)
    sgb_sge("rc_sge_sgb_32", 32)
    rc_payload("send_with_imm", 4, opcode=2, immediate=0x89ABCDEF)
    rc_payload("write_with_imm", 8, opcode=5, immediate=0x10203040, remote=True)
    rc_payload("read", 8, opcode=6, inline=False, remote=True)

    image = ReferenceImage(64)
    _sq_header(image, 14, inline=False, index=0x1500)
    put_named(image, "RDMA_SQ_WQE_LOCAL_INVLD_STAG", 0xCAFEBABE)
    add("local_invalidate", "case=local_invalidate,opcode=14,mode=none", image)

    def atomic(name: str, opcode: int, cas: bool) -> None:
        image = ReferenceImage(64)
        _sq_header(image, opcode, inline=False, index=0x1600 + int(cas))
        put_named(image, "RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN", 8)
        put_named(image, "RDMA_SQ_WQE_SIGNATURE", 0)
        put_named(image, "RDMA_SQ_WQE_ATOMIC_SGE_NUM", 1)
        put_named(image, "RDMA_SQ_WQE_ATOMIC_R_KEY", 0x12345678)
        put_named(image, "RDMA_SQ_WQE_ATOMIC_R_VA", 0x200000)
        put_named(image, "RDMA_SQ_WQE_ATOMIC_L_LEN", 8)
        put_named(image, "RDMA_SQ_WQE_ATOMIC_L_KEY", 0x87654321)
        put_named(image, "RDMA_SQ_WQE_ATOMIC_L_VA", 0x300000)
        if cas:
            put_named(image, "RDMA_SQ_WQE_ATOMIC_CAS_SWAP_DATA", 0x1111222233334444)
            put_named(image, "RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA", 0x5555666677778888)
        else:
            put_named(image, "RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA", 0x1111222233334444)
        add(name, f"case={name},opcode={opcode},length=8,mode=atomic", image)

    atomic("atomic_cas", 7, True)
    atomic("atomic_faa", 8, False)

    def ud(name: str, with_sgb: bool) -> None:
        image = ReferenceImage(64)
        _sq_header(image, 1, inline=not with_sgb, se=True, index=0x1700 + int(with_sgb))
        put_named(image, "RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN", 8 if with_sgb else 0)
        put_named(image, "RDMA_SQ_WQE_UD_SGE_NUM", 1 if with_sgb else 0)
        put_named(image, "RDMA_SQ_WQE_UD_DMAC", 0xA1B2C3D4E5F6)
        put_named(image, "RDMA_SQ_WQE_UD_PRI", 5)
        put_named(image, "RDMA_SQ_WQE_UD_CFI", 1)
        put_named(image, "RDMA_SQ_WQE_UD_VLAN_ID", 0x789)
        put_named(image, "RDMA_SQ_WQE_UD_PD_IDX", 0x1234)
        put_named(image, "RDMA_SQ_WQE_UD_FLOW_LABEL", 0x54321)
        put_named(image, "RDMA_SQ_WQE_UD_SRC_ADDR_IDX", 0xABC)
        put_named(image, "RDMA_SQ_WQE_UD_MC", 1)
        put_named(image, "RDMA_SQ_WQE_UD_TRAFFIC_CLASS", 0xAC)
        put_named(image, "RDMA_SQ_WQE_UD_HOPLIMIT", 0x7F)
        put_named(image, "RDMA_SQ_WQE_UD_DST_QPN", 0xABCDEF)
        put_named(image, "RDMA_SQ_WQE_UD_DST_Q_KEY", 0x89ABCDEF)
        put_named(image, "RDMA_SQ_WQE_UD_DST_VPORT_ID", 0x456)
        put_named(image, "RDMA_SQ_WQE_UD_FWD", 2)
        put_named(image, "RDMA_SQ_WQE_UD_LAG", 1)
        put_named(image, "RDMA_SQ_WQE_UD_TUNNEL", 0)
        put_named(image, "RDMA_SQ_WQE_UD_IPV6", 1)
        put_named(image, "RDMA_SQ_WQE_UD_VLAN", 1)
        put_named(image, "RDMA_SQ_WQE_SIGNATURE", 0)
        if with_sgb:
            put_named(image, "RDMA_SQ_WQE_SGB_PA", sgb_iova)
            sgb = ReferenceImage(512)
            _sq_sge(sgb, 0, 8, 0x3333, 0x400000)
            sgb_bytes = bytes(sgb)
        else:
            sgb_bytes = None
        # wr.c uses memcpy for the destination IP, preserving byte order.
        image[48:64] = bytes.fromhex("20010db8000000000000000000000001")
        add(name, f"case={name},opcode=1,length={8 if with_sgb else 0},mode={'sgb' if with_sgb else 'inline'}", image, sgb_bytes)

    ud("ud_inline", False)
    ud("ud_sgb", True)
    return cases, sgb_images


def sq_reference_image(case_name: str = "sqe_rc_boundary") -> bytes:
    """Return an operation-specific SQE reference image."""
    for case in _build_sq_golden_cases()[0]:
        if case.name == case_name:
            return case.payload
    raise ValidationError(f"unknown SQ golden case: {case_name}")


def sq_reference_sgb(case_name: str = "sgb_boundary") -> bytes:
    """Return the detached 512-byte SGB image for a named SQ case."""
    sgb = _build_sq_golden_cases()[1]
    if case_name not in sgb:
        raise ValidationError(f"unknown SQ SGB case: {case_name}")
    return sgb[case_name]


def validate_sq_golden_vectors() -> None:
    path = GOLDEN_DIR / "sq.hex"
    if not path.is_file():
        raise ValidationError(f"SQ golden file missing: {path.relative_to(REPO_ROOT)}")
    parsed = parse_golden_text(path.read_text())
    expected, sgb_images = _build_sq_golden_cases()
    # Keep detached SGB images in the same strict golden grammar so descriptor
    # placement and inline payload bytes are independently authenticated.
    for name in ("rc_inline_33", "rc_inline_512", "rc_sge_sgb_3",
                 "rc_sge_sgb_32", "ud_sgb"):
        expected.append(
            GoldenCase(f"{name}_sgb", parse_input_summary(f"case={name}_sgb"), sgb_images[name])
        )
    expected.append(GoldenCase("sgb_boundary", parse_input_summary("case=sgb_boundary"), sgb_images["sgb_boundary"]))
    if parsed != expected:
        raise ValidationError("SQ golden vectors differ from generated references")


def validate_mapping_uniqueness(
    field_mappings: tuple[FieldMapping, ...],
    value_mappings: tuple[ValueMapping, ...],
    reference_fields: tuple[ReferenceField, ...],
) -> None:
    def unique(items, label: str) -> None:
        seen = set()
        for item in items:
            if item in seen:
                raise ValidationError(f"duplicate {label}: {item}")
            seen.add(item)

    def unique_sources(items, label: str) -> None:
        modify_data_source = ("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_DATA")
        modify_data_offsets = {32, 40, 48, 56}
        offsets_by_source: dict[tuple[str, str], list[int]] = {}
        for item in items:
            source = (item.path, item.c_symbol)
            offsets_by_source.setdefault(source, []).append(
                item.word_byte_offset
            )
        for source, offsets in offsets_by_source.items():
            if source == modify_data_source:
                if (len(offsets) != 4 or
                        set(offsets) != modify_data_offsets):
                    raise ValidationError(
                        f"duplicate {label} exception must contain exactly "
                        f"offsets 32, 40, 48, and 56: {source}"
                    )
            elif len(offsets) != 1:
                raise ValidationError(f"duplicate {label}: {source}")

    unique((mapping.sv_stem for mapping in field_mappings), "field mapping SV stem")
    unique_sources(field_mappings, "field mapping source")
    unique((mapping.sv_name for mapping in value_mappings), "SV value mapping")
    unique(((mapping.path, mapping.c_symbol) for mapping in value_mappings),
           "value mapping source")
    unique((reference.sv_stem for reference in reference_fields),
           "reference SV stem")
    unique_sources(reference_fields, "reference source")

    # expected_constants is keyed by the final emitted SV names.  Validate
    # that namespace before building the dictionary so no later table can
    # silently overwrite a field coordinate.
    final_names: dict[str, str] = {}

    def add_final(name: str, producer: str) -> None:
        previous = final_names.get(name)
        if previous is not None and previous != producer:
            raise ValidationError(
                f"duplicate global SV constant {name}: {previous} and {producer}"
            )
        final_names[name] = producer

    field_stems = {mapping.sv_stem for mapping in field_mappings}
    for mapping in field_mappings:
        producer = f"field/reference {mapping.sv_stem}"
        for suffix in ("WORD_BYTE_OFFSET", "LSB", "WIDTH", "OFFSET"):
            add_final(f"{mapping.sv_stem}_{suffix}", producer)
    for reference in reference_fields:
        producer = f"field/reference {reference.sv_stem}"
        if reference.sv_stem not in field_stems:
            for suffix in ("WORD_BYTE_OFFSET", "LSB", "WIDTH", "OFFSET"):
                add_final(f"{reference.sv_stem}_{suffix}", producer)
    for mapping in value_mappings:
        add_final(mapping.sv_name, f"value {mapping.sv_name}")
    for mapping in ERROR_CODE_MAPPINGS:
        add_final(mapping.sv_name, f"error code {mapping.path}:{mapping.c_symbol}")
    for name in PROFILE_VALUES:
        add_final(name, f"profile {name}")


def validate_profile_constants(
    sv_constants: dict[str, int],
    profile_values: dict[str, int],
) -> None:
    for name, expected in profile_values.items():
        actual = sv_constants.get(name)
        if actual is None:
            raise ValidationError(f"required profile constant missing: {name}")
        if actual != expected:
            raise ValidationError(
                f"profile constant mismatch for {name}: {actual:#x} != {expected:#x}"
            )


def validate_body_translations(
    translations: tuple[BodyTranslation, ...],
    field_mappings: tuple[FieldMapping, ...],
) -> None:
    expected = {
        mapping.sv_stem: mapping
        for mapping in field_mappings
        if ((mapping.path == "cq.h" and mapping.sv_stem.startswith("RDMA_CQC_BODY_"))
            or (mapping.path == "srq.h" and mapping.sv_stem.startswith("RDMA_SRQC_BODY_"))
            or (mapping.path == "event.h" and mapping.sv_stem.startswith("RDMA_EQC_BODY_")))
    }
    seen: set[str] = set()
    for translation in translations:
        if translation.sv_stem in seen:
            raise ValidationError(f"duplicate body translation: {translation.sv_stem}")
        seen.add(translation.sv_stem)
        mapping = expected.get(translation.sv_stem)
        if mapping is None:
            raise ValidationError(f"unexpected body translation: {translation.sv_stem}")
        if (mapping.path, mapping.c_symbol) != (
            translation.path, translation.c_symbol
        ):
            raise ValidationError(
                f"body translation source mismatch for {translation.sv_stem}"
            )
        final_offset = (
            translation.local_word_byte_offset + translation.final_base_offset
        )
        if mapping.word_byte_offset != final_offset:
            raise ValidationError(
                f"body translation offset mismatch for {translation.sv_stem}"
            )
    if seen != set(expected):
        missing = sorted(set(expected) - seen)
        raise ValidationError(f"missing body translations: {missing}")


def validate_sv_mask_api(text: str) -> None:
    envelope_signature = re.compile(
        r"function\s+automatic\s+bit\s*\[63:0\]\s+"
        r"request_envelope_mask\s*\(\s*int\s+unsigned\s+qword_index\s*\)\s*;",
        re.S,
    )
    body_signature = re.compile(
        r"function\s+automatic\s+bit\s+body_mask\s*\(\s*"
        r"rdma_image_kind_e\s+image_kind\s*,\s*bit\s*\[7:0\]\s+opcode\s*,\s*"
        r"int\s+unsigned\s+pbl_mode\s*,\s*int\s+unsigned\s+qword_index\s*,\s*"
        r"output\s+bit\s*\[63:0\]\s+mask\s*\)\s*;",
        re.S,
    )
    if envelope_signature.search(text) is None:
        raise ValidationError("request_envelope_mask qword API missing")
    if body_signature.search(text) is None:
        raise ValidationError("body_mask image-kind/qword API missing")
    for image_kind in (
        "RDMA_IMAGE_CQC", "RDMA_IMAGE_MRT", "RDMA_IMAGE_SRQC",
        "RDMA_IMAGE_CEQC", "RDMA_IMAGE_AEQC",
    ):
        if image_kind not in text:
            raise ValidationError(f"body_mask image-kind selector missing: {image_kind}")
    if text.count("qword_index > 7") < 2:
        raise ValidationError("mask qword bounds are not fail closed")


def validate_access_projections(text: str) -> None:
    function = re.search(
        r"\bstatic\s+inline\s+u8\s+xtrdma_get_access\s*\([^)]*\)\s*\{"
        r"(.*?)\breturn\s+hw_access\s*;\s*\}",
        text,
        re.S,
    )
    if function is None:
        raise ValidationError("xtrdma_get_access implementation missing")
    observed: dict[str, set[str]] = {}
    for statement in re.finditer(
        r"hw_access\s*\|=\s*(.*?)\?\s*"
        r"(XTRDMA_ACCESS_FLAGS_[A-Z_]+)\s*:\s*0\s*;",
        function.group(1),
        re.S,
    ):
        inputs = set(re.findall(r"access\s*&\s*(IB_ACCESS_[A-Z_]+)", statement.group(1)))
        observed[statement.group(2)] = inputs
    expected = {
        output: set(inputs.split("|"))
        for inputs, output in ACCESS_PROJECTIONS
    }
    if observed != expected:
        raise ValidationError("xtrdma_get_access projection mapping drift")


def parse_sv_masks(text: str) -> dict[str, tuple[int, ...]]:
    masks: dict[str, tuple[int, ...]] = {}
    pattern = re.compile(
        r"localparam\s+bit\s*\[63:0\]\s+"
        r"(RDMA_[A-Z0-9_]+_MASK)\s*\[0:7\]\s*=\s*'\{(.*?)\};",
        re.S,
    )
    for match in pattern.finditer(text):
        name = match.group(1)
        if name in masks:
            raise ValidationError(f"duplicate SV mask: {name}")
        values = tuple(
            parse_sv_value(item.strip()) for item in match.group(2).split(",")
        )
        if len(values) != 8:
            raise ValidationError(f"{name} must contain eight qword masks")
        masks[name] = values
    return masks


def parse_sv_ownership(text: str) -> dict[str, tuple[int, ...]]:
    ownership: dict[str, tuple[int, ...]] = {}
    pattern = re.compile(
        r"localparam\s+bit\s*\[63:0\]\s+"
        r"(RDMA_[A-Z0-9_]+_OWNERSHIP)\s*\[0:7\]\s*=\s*'\{(.*?)\};",
        re.S,
    )
    for match in pattern.finditer(text):
        name = match.group(1)
        if name in ownership:
            raise ValidationError(f"duplicate SV ownership: {name}")
        values = tuple(
            parse_sv_value(item.strip()) for item in match.group(2).split(",")
        )
        if len(values) != 8:
            raise ValidationError(f"{name} must contain eight qword masks")
        ownership[name] = values
    return ownership


def validate_cmq_body_ownership(
    ownership: dict[str, tuple[int, ...]],
) -> None:
    if ownership != CMQ_BODY_OWNERSHIP:
        raise ValidationError(
            "SV CMQ body ownership differs from independent reference"
        )
    for name, masks in ownership.items():
        if any(mask & envelope for mask, envelope in zip(masks, ENVELOPE_MASK)):
            raise ValidationError(
                f"CMQ body ownership overlaps request envelope: {name}"
            )


def strip_c_comments(line: str) -> str:
    return re.sub(r"/\*.*?\*/", "", line).strip()


def parse_c_symbols(text: str) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    macros: dict[str, list[str]] = {}
    for raw_line in text.splitlines():
        line = strip_c_comments(raw_line)
        match = re.match(
            r"^\s*#define\s+([A-Za-z_]\w*)(?:\([^)]*\))?\s+(.+?)\s*$", line
        )
        if match:
            macros.setdefault(match.group(1), []).append(match.group(2))

    enums: dict[str, list[str]] = {}
    for block in re.finditer(r"\benum\s+([A-Za-z_]\w*)\s*\{(.*?)\};", text, re.S):
        body = re.sub(r"/\*.*?\*/", "", block.group(2), flags=re.S)
        next_value: int | None = 0
        for item in body.split(","):
            clean = item.strip()
            if not clean:
                continue
            explicit = re.fullmatch(r"([A-Za-z_]\w*)\s*=\s*(.+)", clean, re.S)
            if explicit:
                name, expression = explicit.group(1), explicit.group(2).strip()
                enums.setdefault(name, []).append(expression)
                try:
                    next_value = parse_value_expression(expression) + 1
                except ValidationError:
                    next_value = None
                continue
            implicit = re.fullmatch(r"([A-Za-z_]\w*)", clean)
            if not implicit:
                continue
            if next_value is None:
                expression = "<implicit-after-unsupported-expression>"
            else:
                expression = str(next_value)
                next_value += 1
            enums.setdefault(implicit.group(1), []).append(expression)
    return macros, enums


def require_unique_expression(
    symbols: dict[str, list[str]], symbol: str, source_path: str
) -> str:
    expressions = symbols.get(symbol, [])
    if not expressions:
        raise ValidationError(f"mapped symbol {symbol} missing from {source_path}")
    if len(expressions) != 1:
        # wr.h in the pinned driver repeats UD_DST_Q_KEY verbatim. Keep this
        # exception scoped to that audited source identity; every other
        # duplicate remains a fail-closed mapping error.
        if (source_path == "wr.h" and symbol == "XTRDMA_SQ_WQE_UD_DST_Q_KEY"
                and len(set(expressions)) == 1):
            return expressions[0]
        raise ValidationError(f"mapped symbol {symbol} is duplicated in {source_path}")
    return expressions[0]


def discover_error_code_values(
    source_text: dict[str, str],
) -> dict[tuple[str, str], int]:
    """Discover genuine code values by pinned path and source-name pattern."""
    values: dict[tuple[str, str], int] = {}
    patterns = {
        "defs.h": re.compile(r"^EC_[A-Za-z0-9_]+$"),
        # The trailing underscore excludes the XTRDMA_CQE_ECODE field mask.
        "wr.h": re.compile(r"^XTRDMA_CQE_ECODE_[A-Za-z0-9_]+$"),
    }
    for path, pattern in patterns.items():
        text = source_text.get(path)
        if text is None:
            raise ValidationError(f"error code source missing: {path}")
        macros, enums = parse_c_symbols(text)
        names = {name for name in macros if pattern.fullmatch(name)}
        names.update(name for name in enums if pattern.fullmatch(name))
        for name in names:
            macro_expressions = macros.get(name, [])
            enum_expressions = enums.get(name, [])
            expressions = macro_expressions + enum_expressions
            if len(expressions) != 1:
                raise ValidationError(
                    f"error code {name} is duplicated in {path}"
                )
            expression = expressions[0]
            value = parse_value_expression(expression)
            if not 0 <= value <= 0xFF:
                raise ValidationError(
                    f"error code {path}:{name} is outside 8-bit range: {value:#x}"
                )
            values[(path, name)] = value
    return values


def validate_error_code_mappings(
    mappings: tuple[ErrorCodeMapping, ...],
    source_text: dict[str, str],
    sv_text: str,
) -> dict[tuple[str, str], int]:
    """Check identity completeness and independently derived SV code values."""
    sv_text = mask_sv_strings(strip_sv_comments(sv_text))
    identities = [(mapping.path, mapping.c_symbol) for mapping in mappings]
    if len(identities) != len(set(identities)):
        raise ValidationError("duplicate error code source identity")
    sv_names = [mapping.sv_name for mapping in mappings]
    if len(sv_names) != len(set(sv_names)):
        raise ValidationError("duplicate error code SV name")
    for mapping in mappings:
        expected_name = f"RDMA_ECODE_{mapping.c_symbol}"
        if mapping.sv_name != expected_name:
            raise ValidationError(
                f"error code SV name loses source identity: {mapping.sv_name}"
            )

    source_values = discover_error_code_values(source_text)
    discovered = set(source_values)
    declared = set(identities)
    missing = sorted(discovered - declared)
    extra = sorted(declared - discovered)
    if missing:
        raise ValidationError(f"missing error code mapping: {missing}")
    if extra:
        raise ValidationError(f"extra error code mapping: {extra}")

    sv_constants = parse_sv_constants(sv_text)
    expected_sv_names = set(sv_names)
    identifier_counts: dict[str, int] = {}
    for name in re.findall(r"\bRDMA_ECODE_[A-Za-z0-9_]+\b", sv_text):
        identifier_counts[name] = identifier_counts.get(name, 0) + 1
    actual_sv_names = set(identifier_counts)
    missing_sv = sorted(expected_sv_names - actual_sv_names)
    extra_sv = sorted(actual_sv_names - expected_sv_names)
    if missing_sv:
        raise ValidationError(f"missing SV error code constant: {missing_sv}")
    if extra_sv:
        raise ValidationError(f"extra SV error code constant: {extra_sv}")

    assignments: dict[str, int] = {}
    for name in re.findall(
        r"\b(RDMA_ECODE_[A-Za-z0-9_]+)\b\s*=", sv_text
    ):
        assignments[name] = assignments.get(name, 0) + 1
    declarations: dict[str, list[tuple[int, int]]] = {}
    for match in re.finditer(
            r"\blocalparam\s+bit\s*\[\s*(\d+)\s*:\s*(\d+)\s*\]\s+"
            r"(RDMA_ECODE_[A-Za-z0-9_]+)\s*=",
            sv_text,
    ):
        declarations.setdefault(match.group(3), []).append(
            (int(match.group(1)), int(match.group(2)))
        )
    for mapping in mappings:
        if identifier_counts.get(mapping.sv_name) != 1:
            raise ValidationError(
                f"SV error code {mapping.sv_name} must have one canonical definition"
            )
        if (
            assignments.get(mapping.sv_name) != 1
            or declarations.get(mapping.sv_name) != [(7, 0)]
        ):
            raise ValidationError(
                f"SV error code {mapping.sv_name} must be declared bit [7:0]"
            )
        expected = source_values[(mapping.path, mapping.c_symbol)]
        actual = sv_constants[mapping.sv_name]
        if actual != expected:
            raise ValidationError(
                f"SV error code mismatch for {mapping.c_symbol}: "
                f"{actual:#x} != {expected:#x}"
            )
    return source_values


def canonical_error_code_mappings(
    mappings: tuple[ErrorCodeMapping, ...],
    source_values: dict[tuple[str, str], int],
    expected_aliases=EXPECTED_ERROR_CODE_ALIASES,
) -> dict[int, ErrorCodeMapping]:
    """Select one lookup identity per value after exact alias validation."""
    by_value: dict[int, list[ErrorCodeMapping]] = {}
    for mapping in mappings:
        identity = (mapping.path, mapping.c_symbol)
        if identity not in source_values:
            raise ValidationError(f"error code value missing for {identity}")
        by_value.setdefault(source_values[identity], []).append(mapping)

    observed_aliases = {
        frozenset((mapping.path, mapping.c_symbol) for mapping in group)
        for group in by_value.values()
        if len(group) > 1
    }
    required_aliases = {
        frozenset(group) for group in expected_aliases
    }
    if observed_aliases != required_aliases:
        raise ValidationError(
            "error code alias set drift: "
            f"observed={sorted(map(sorted, observed_aliases))}, "
            f"expected={sorted(map(sorted, required_aliases))}"
        )

    canonical: dict[int, ErrorCodeMapping] = {}
    for value, group in by_value.items():
        defs_mappings = [mapping for mapping in group if mapping.path == "defs.h"]
        if len(defs_mappings) > 1:
            raise ValidationError(
                f"multiple defs.h identities alias error code {value:#x}"
            )
        canonical[value] = defs_mappings[0] if defs_mappings else group[0]
    return canonical


def validate_error_codec(
    codec_text: str,
    canonical: dict[int, ErrorCodeMapping],
) -> None:
    """Bind codec literals and symbolic lookup to validated source identities."""
    codec_text = strip_sv_comments(codec_text)
    codec_code = mask_sv_strings(codec_text)
    validate_error_codec_preprocessor(codec_code)
    known_values = set(canonical)
    for literal in re.finditer(
        r"\b(\d+)\s*'\s*[sS]?\s*([hHdDbBoO])\s*([0-9a-fA-F_]+)",
        codec_code,
    ):
        width = int(literal.group(1))
        if width != 8:
            continue
        base = {"h": 16, "d": 10, "b": 2, "o": 8}[
            literal.group(2).lower()
        ]
        try:
            value = int(literal.group(3).replace("_", ""), base)
        except ValueError:
            continue
        value &= (1 << width) - 1
        if value in known_values:
            raise ValidationError(
                f"raw literal {literal.group(0)} used for known error code"
            )
    allowed_names = {
        mapping.sv_name
        for value, mapping in canonical.items()
        if value != 0
    }
    allowed_names.add("RDMA_CMQ_SUCCESS_ECODE")
    for function_name in ("classify", "inferred_engine"):
        function = re.search(
            rf"\blocal\s+function\b[^;]*\b{function_name}\s*\([^;]*\)\s*;"
            r"(.*?)\bendfunction\b",
            codec_code,
            re.S,
        )
        if function is None:
            raise ValidationError(
                f"hardware error function missing: {function_name}"
            )
        whole_case = re.fullmatch(
            r"\s*case\s*\(\s*hardware_code\s*\)(.*?)"
            r"\bendcase\b\s*",
            function.group(1),
            re.S,
        )
        if whole_case is None:
            raise ValidationError(f"invalid {function_name} function body")
        case_body = whole_case.group(1)
        validate_outer_case_default_is_last(case_body, function_name)
        explicit_case = re.search(
            r"(.*?)^[ \t]*default[ \t]*:",
            case_body,
            re.S | re.M,
        )
        if explicit_case is None:
            raise ValidationError(
                f"hardware error case missing default: {function_name}"
            )
        item_pattern = re.compile(
            r"^[ \t]*(?P<labels>[^:;]+?)[ \t]*:[ \t]*"
            r"\s*return\b[^;]*;",
            re.M | re.S,
        )
        position = 0
        for item in item_pattern.finditer(explicit_case.group(1)):
            if explicit_case.group(1)[position:item.start()].strip():
                raise ValidationError(
                    f"invalid hardware error case item in {function_name}"
                )
            labels = [label.strip() for label in item.group("labels").split(",")]
            if not labels or any(label not in allowed_names for label in labels):
                raise ValidationError(
                    f"invalid hardware error case item in {function_name}: "
                    f"{item.group('labels').strip()}"
                )
            position = item.end()
        if explicit_case.group(1)[position:].strip():
            raise ValidationError(
                f"invalid hardware error case item in {function_name}"
            )

    symbolic_function = re.search(
        r"\blocal\s+function\s+string\s+symbolic_name\s*\([^)]*\)\s*;"
        r"(.*?)\bendfunction\b",
        codec_code,
        re.S,
    )
    if symbolic_function is None:
        raise ValidationError("symbolic error code lookup function missing")
    symbolic_body = codec_text[
        symbolic_function.start(1):symbolic_function.end(1)
    ]
    symbolic_code_body = codec_code[
        symbolic_function.start(1):symbolic_function.end(1)
    ]
    case_block = re.fullmatch(
        r"\s*case\s*\(\s*hardware_code\s*\)(.*?)\bendcase\b\s*",
        symbolic_code_body,
        re.S,
    )
    if case_block is None:
        raise ValidationError("symbolic error code lookup function body differs")
    case_body = symbolic_body[case_block.start(1):case_block.end(1)]
    defaults = list(
        re.finditer(r"^[ \t]*default[ \t]*:", case_body, re.M)
    )
    if len(defaults) != 1:
        raise ValidationError("symbolic error code unknown default differs")
    explicit_text = case_body[:defaults[0].start()]
    default_text = case_body[defaults[0].start():]
    if re.fullmatch(
        r"\s*default\s*:\s*return\s*\$sformatf\(\s*"
        r'"RDMA_UNKNOWN_ECODE_0x%02x"\s*,\s*hardware_code\s*'
        r"\)\s*;\s*",
        default_text,
        re.S,
    ) is None:
        raise ValidationError("symbolic error code unknown default differs")

    observed: list[tuple[str, str]] = []
    item_pattern = re.compile(
        r"^[ \t]*(?P<labels>[^:;]+?)[ \t]*:\s*return\s*"
        r'"(?P<value>(?:\\.|[^"\\])*)"\s*;',
        re.M | re.S,
    )
    position = 0
    for item in item_pattern.finditer(explicit_text):
        if explicit_text[position:item.start()].strip():
            raise ValidationError(
                "symbolic error code lookup differs from canonical source mapping"
            )
        observed.extend(
            (label.strip(), item.group("value"))
            for label in item.group("labels").split(",")
        )
        position = item.end()
    if explicit_text[position:].strip():
        raise ValidationError(
            "symbolic error code lookup differs from canonical source mapping"
        )
    expected = [
        ("RDMA_CMQ_SUCCESS_ECODE", "RDMA_CMQ_SUCCESS")
    ]
    expected.extend(
        (mapping.sv_name, mapping.c_symbol)
        for value, mapping in sorted(canonical.items())
        if value != 0
    )
    if len(observed) != len(set(observed)) or set(observed) != set(expected):
        raise ValidationError(
            "symbolic error code lookup differs from canonical source mapping"
        )

    used_names = set(re.findall(r"\bRDMA_ECODE_[A-Za-z0-9_]+\b", codec_code))
    unknown_names = sorted(used_names - allowed_names)
    if unknown_names:
        raise ValidationError(
            f"codec consumes noncanonical error code constant: {unknown_names}"
        )
    validate_hardware_code_uses(codec_code)


class ReferenceImage(bytearray):
    """Golden payload plus occupancy masks for its logical qwords."""

    def __init__(self, byte_count: int):
        super().__init__(byte_count)
        self.occupancy = [0] * ((byte_count + 7) // 8)


def put_field(
    image: ReferenceImage, logical_offset: int, width: int, value: int
) -> None:
    if not isinstance(image, ReferenceImage):
        raise ValidationError("reference image occupancy tracking is required")
    if width < 1 or width > 64 or value < 0 or value >= (1 << width):
        raise ValidationError(f"value {value:#x} does not fit width {width}")
    word_byte_offset = (logical_offset // 64) * 8
    lsb = logical_offset % 64
    if lsb + width > 64 or word_byte_offset + 8 > len(image):
        raise ValidationError("field crosses a logical qword or image boundary")
    mask = ((1 << width) - 1) << lsb
    word_index = word_byte_offset // 8
    if image.occupancy[word_index] & mask:
        raise ValidationError("reference fields overlap")
    word = int.from_bytes(image[word_byte_offset : word_byte_offset + 8], "big")
    word |= value << lsb
    image[word_byte_offset : word_byte_offset + 8] = word.to_bytes(8, "big")
    image.occupancy[word_index] |= mask


def put_named(image: ReferenceImage, stem: str, value: int) -> None:
    reference = REFERENCE_BY_STEM.get(stem)
    if reference is None:
        raise ValidationError(f"reference placement missing for {stem}")
    put_field(
        image,
        reference.word_byte_offset * 8 + reference.lsb,
        reference.width,
        value,
    )


# Golden placement is independently transcribed from the pinned driver call
# sites and masks. It is intentionally not derived from FIELD_MAPPINGS.
REFERENCE_FIELDS = (
    ReferenceField("qp.h", "XTRDMA_QPC_TVER", "RDMA_QPC_TVER", 0, 62, 2),
    ReferenceField("qp.h", "XTRDMA_QPC_MIG", "RDMA_QPC_MIG", 0, 61, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_SERVICE_TYPE", "RDMA_QPC_SERVICE_TYPE", 0, 58, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_HOST_ID", "RDMA_QPC_HOST_ID", 0, 52, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_VF_ID", "RDMA_QPC_VF_ID", 0, 40, 12),
    ReferenceField("qp.h", "XTRDMA_QPC_ICOS", "RDMA_QPC_ICOS", 0, 37, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_QPN", "RDMA_QPC_QPN", 0, 16, 21),
    ReferenceField("qp.h", "XTRDMA_QPC_STAT_IDX", "RDMA_QPC_STAT_IDX", 0, 8, 8),
    ReferenceField("qp.h", "XTRDMA_QPC_UD_QKEY_H", "RDMA_QPC_UD_QKEY_H", 0, 0, 8),
    ReferenceField("qp.h", "XTRDMA_QPC_PKEY", "RDMA_QPC_PKEY", 8, 0, 16),
    ReferenceField("qp.h", "XTRDMA_QPC_TX_ENDIAN_SWAP", "RDMA_QPC_TX_ENDIAN_SWAP", 16, 6, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_RX_ENDIAN_SWAP", "RDMA_QPC_RX_ENDIAN_SWAP", 16, 5, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_QP_ST", "RDMA_QPC_QP_ST", 24, 56, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_PMTU", "RDMA_QPC_PMTU", 24, 48, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_QP_SN", "RDMA_QPC_QP_SN", 24, 32, 8),
    ReferenceField("qp.h", "XTRDMA_QPC_PD_IDX", "RDMA_QPC_PD_IDX", 24, 0, 16),
    ReferenceField("qp.h", "XTRDMA_QPC_SQ_PD_PBA_OR_PBA", "RDMA_QPC_SQ_PBA", 216, 12, 52),
    ReferenceField("qp.h", "XTRDMA_QPC_SQ_SIZE", "RDMA_QPC_SQ_SIZE", 216, 8, 4),
    ReferenceField("qp.h", "XTRDMA_QPC_SQ_OM", "RDMA_QPC_SQ_OM", 216, 6, 2),
    ReferenceField("cmq.h", "XTRDMA_CMQCQ_OPCODE", "RDMA_CMQ_OPCODE", 0, 32, 8),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_QPN", "RDMA_CMQ_QPN", 0, 0, 24),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_INDEX", "RDMA_CMQ_WQE_INDEX", 0, 40, 5),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_VALID", "RDMA_CMQ_VALID", 0, 63, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_VFID_OVERRIDE", "RDMA_CMQ_VFID_OVERRIDE", 0, 59, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_USE_VFID", "RDMA_CMQ_USE_VFID", 0, 48, 11),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_WRAP", "RDMA_CMQ_WRAP", 0, 45, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_SQ_CQN", "RDMA_CMQ_SQ_CQN", 8, 43, 21),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_SIGN_EN", "RDMA_CMQ_SIGN_EN", 8, 32, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_RQ_CQN", "RDMA_CMQ_RQ_CQN", 8, 0, 21),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR", "RDMA_CMQ_QPC_BUFFER_ADDR", 24, 9, 55),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_NXT_QP_ST", "RDMA_CMQ_NEXT_QP_STATE", 0, 60, 3),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_MODE", "RDMA_CMQ_MODIFY_MODE", 16, 62, 2),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD0", "RDMA_CMQ_MODIFY_START_QWORD0", 16, 56, 6),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_WBE0", "RDMA_CMQ_MODIFY_WBE0", 16, 48, 8),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_WBE_TPL_NUM", "RDMA_CMQ_WBE_TEMPLATE_COUNT", 16, 46, 2),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD1", "RDMA_CMQ_MODIFY_START_QWORD1", 16, 40, 6),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_WBE1", "RDMA_CMQ_MODIFY_WBE1", 16, 32, 8),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD2", "RDMA_CMQ_MODIFY_START_QWORD2", 16, 24, 6),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_WBE2", "RDMA_CMQ_MODIFY_WBE2", 16, 16, 8),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_START_QWORD3", "RDMA_CMQ_MODIFY_START_QWORD3", 16, 8, 6),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_WBE3", "RDMA_CMQ_MODIFY_WBE3", 16, 0, 8),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_DATA", "RDMA_CMQ_MODIFY_DATA0", 32, 0, 64),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_DATA", "RDMA_CMQ_MODIFY_DATA1", 40, 0, 64),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_DATA", "RDMA_CMQ_MODIFY_DATA2", 48, 0, 64),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_MODIFY_DATA", "RDMA_CMQ_MODIFY_DATA3", 56, 0, 64),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_VF_FLUSH", "RDMA_CMQ_OCC_VF_FLUSH", 0, 61, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_MR_SN_FLUSH", "RDMA_CMQ_OCC_MR_SERIAL_FLUSH", 0, 60, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_QPN", "RDMA_CMQ_OCC_QPN", 0, 0, 21),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_QPC_FLAG", "RDMA_CMQ_OCC_QPC", 8, 63, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_CQC_FLAG", "RDMA_CMQ_OCC_CQC", 8, 62, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_MRT_FLAG", "RDMA_CMQ_OCC_MRT", 8, 61, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_PBLE_FLAG", "RDMA_CMQ_OCC_PBLE", 8, 60, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_SQRQE_FLAG", "RDMA_CMQ_OCC_SQRQE", 8, 59, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_SGB_IRQE_FLAG", "RDMA_CMQ_OCC_SGB_IRQE", 8, 58, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_EIRQE_FLAG", "RDMA_CMQ_OCC_EIRQE", 8, 57, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_ORQE_FLAG", "RDMA_CMQ_OCC_ORQE", 8, 56, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_UAQE_FLAG", "RDMA_CMQ_OCC_UAQE", 8, 55, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_PD_FLAG", "RDMA_CMQ_OCC_PD", 8, 54, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_MR_SN", "RDMA_CMQ_OCC_MR_SERIAL", 8, 32, 12),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_OCC_FLUSH_PD_PBA", "RDMA_CMQ_OCC_PD_BACKING", 16, 12, 52),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_QPN", "RDMA_SQ_WQE_QPN", 0, 0, 21),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_OPCODE", "RDMA_SQ_WQE_OPCODE", 0, 32, 4),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_INDEX", "RDMA_SQ_WQE_INDEX", 0, 40, 15),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_RC_REMOTE_KEY", "RDMA_SQ_WQE_RC_REMOTE_KEY", 16, 0, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ICOS", "RDMA_SQ_WQE_ICOS", 0, 21, 3),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_QP_SN", "RDMA_SQ_WQE_QP_SN", 0, 24, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_DST_PORT", "RDMA_SQ_WQE_DST_PORT", 0, 36, 4),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_WRAP", "RDMA_SQ_WQE_WRAP", 0, 55, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_SIGN_EN", "RDMA_SQ_WQE_SIGN_EN", 0, 56, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_SE", "RDMA_SQ_WQE_SE", 0, 57, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_FENCE", "RDMA_SQ_WQE_FENCE", 0, 58, 2),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_CE", "RDMA_SQ_WQE_CE", 0, 61, 2),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_VALID", "RDMA_SQ_WQE_VALID", 0, 63, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_SIGNATURE", "RDMA_SQ_WQE_SIGNATURE", 16, 56, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_RC_SGE_NUM", "RDMA_SQ_WQE_RC_SGE_NUM", 16, 48, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_RC_REMOTE_VA", "RDMA_SQ_WQE_RC_REMOTE_VA", 24, 0, 64),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_INLINE_LOCAL_QPC_RD", "RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD", 0, 60, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_SGB_PA", "RDMA_SQ_WQE_SGB_PA", 32, 9, 55),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN", "RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN", 8, 0, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_IMMDT_INVLD_RKEY", "RDMA_SQ_WQE_RC_IMMEDIATE", 8, 32, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_LOCAL_INVLD_STAG", "RDMA_SQ_WQE_LOCAL_INVLD_STAG", 8, 32, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ATOMIC_SGE_NUM", "RDMA_SQ_WQE_ATOMIC_SGE_NUM", 16, 48, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ATOMIC_R_KEY", "RDMA_SQ_WQE_ATOMIC_R_KEY", 16, 0, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ATOMIC_R_VA", "RDMA_SQ_WQE_ATOMIC_R_VA", 24, 0, 64),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ATOMIC_L_LEN", "RDMA_SQ_WQE_ATOMIC_L_LEN", 32, 32, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ATOMIC_L_KEY", "RDMA_SQ_WQE_ATOMIC_L_KEY", 32, 0, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ATOMIC_L_VA", "RDMA_SQ_WQE_ATOMIC_L_VA", 40, 0, 64),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA", "RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA", 48, 0, 64),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ATOMIC_CAS_SWAP_DATA", "RDMA_SQ_WQE_ATOMIC_CAS_SWAP_DATA", 48, 0, 64),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA", "RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA", 56, 0, 64),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_DST_IPV4", "RDMA_SQ_WQE_UD_DST_IPV4", 48, 0, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_DST_IPV6_L", "RDMA_SQ_WQE_UD_DST_IPV6_L", 48, 0, 64),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_DST_IPV6_H", "RDMA_SQ_WQE_UD_DST_IPV6_H", 56, 0, 64),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_HOPLIMIT", "RDMA_SQ_WQE_UD_HOPLIMIT", 40, 56, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_DST_QPN", "RDMA_SQ_WQE_UD_DST_QPN", 40, 32, 24),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_DST_Q_KEY", "RDMA_SQ_WQE_UD_DST_Q_KEY", 40, 0, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_MC", "RDMA_SQ_WQE_UD_MC", 32, 8, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_TRAFFIC_CLASS", "RDMA_SQ_WQE_UD_TRAFFIC_CLASS", 32, 0, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_PRI", "RDMA_SQ_WQE_UD_PRI", 24, 61, 3),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_CFI", "RDMA_SQ_WQE_UD_CFI", 24, 60, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_VLAN_ID", "RDMA_SQ_WQE_UD_VLAN_ID", 24, 48, 12),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_PD_IDX", "RDMA_SQ_WQE_UD_PD_IDX", 24, 32, 16),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_FLOW_LABLE", "RDMA_SQ_WQE_UD_FLOW_LABEL", 24, 12, 20),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_SRC_ADDR_IDX", "RDMA_SQ_WQE_UD_SRC_ADDR_IDX", 24, 0, 12),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_DMAC", "RDMA_SQ_WQE_UD_DMAC", 16, 0, 48),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_SGE_NUM", "RDMA_SQ_WQE_UD_SGE_NUM", 16, 48, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN", "RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN", 8, 0, 14),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_DST_VPORT_ID", "RDMA_SQ_WQE_UD_DST_VPORT_ID", 8, 14, 11),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_FWD", "RDMA_SQ_WQE_UD_FWD", 8, 26, 2),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_LAG", "RDMA_SQ_WQE_UD_LAG", 8, 28, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_TUNNEL", "RDMA_SQ_WQE_UD_TUNNEL", 8, 29, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_IPV6", "RDMA_SQ_WQE_UD_IPV6", 8, 30, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_UD_VLAN", "RDMA_SQ_WQE_UD_VLAN", 8, 31, 1),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_QPN", "RDMA_RQE_QPN", 0, 0, 24),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_WQE_IDX", "RDMA_RQE_INDEX", 0, 40, 15),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_TPL", "RDMA_RQE_PAYLOAD_LEN", 8, 0, 32),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_QP_SN", "RDMA_RQE_QP_SN", 0, 24, 8),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_WQE_OP", "RDMA_RQE_OPCODE", 0, 32, 4),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_WQE_IDX_WRAP", "RDMA_RQE_WRAP", 0, 55, 1),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_VALID", "RDMA_RQE_VALID", 0, 63, 1),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_SIGNATURE", "RDMA_RQE_SIGNATURE", 16, 56, 8),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_SGE_NUM", "RDMA_RQE_SGE_NUM", 16, 48, 8),
    ReferenceField("wr.h", "XTRDMA_CQE_QPN", "RDMA_CQE_QPN", 0, 0, 18),
    ReferenceField("wr.h", "XTRDMA_CQE_QP_WQE_INDEX", "RDMA_CQE_WQE_INDEX", 0, 40, 15),
    ReferenceField("wr.h", "XTRDMA_CQE_ECODE", "RDMA_CQE_ECODE", 0, 24, 8),
    ReferenceField("wr.h", "XTRDMA_CQE_PAYLOAD_LEN", "RDMA_CQE_PAYLOAD_LEN", 8, 0, 32),
    ReferenceField("wr.h", "XTRDMA_CQE_POLARITY", "RDMA_CQE_POLARITY", 0, 63, 1),
    ReferenceField("wr.h", "XTRDMA_CQE_RQ_CQE", "RDMA_CQE_RQ_CQE", 0, 59, 1),
    ReferenceField("wr.h", "XTRDMA_CQE_QP_WQE_WRAP", "RDMA_CQE_WQE_WRAP", 0, 55, 1),
    ReferenceField("wr.h", "XTRDMA_CQE_PKT_OPCODE", "RDMA_CQE_PKT_OPCODE", 0, 32, 8),
    ReferenceField("wr.h", "XTRDMA_CQE_IMMDT_DATA_INVLD_KEY", "RDMA_CQE_IMMDT_DATA", 8, 32, 32),
    ReferenceField("defs.h", "XTRDMA_CEQE_QPN", "RDMA_CEQE_QPN", 0, 40, 21),
    ReferenceField("defs.h", "XTRDMA_CEQE_CQN", "RDMA_CEQE_CQN", 0, 16, 21),
    ReferenceField("defs.h", "XTRDMA_CEQE_ECODE", "RDMA_CEQE_ECODE", 0, 8, 8),
    ReferenceField("defs.h", "XTRDMA_CEQE_RC_CQ_PI", "RDMA_CEQE_CQ_PI", 8, 0, 16),
    ReferenceField("defs.h", "XTRDMA_CEQE_WQE_VLD", "RDMA_CEQE_VALID", 0, 63, 1),
    ReferenceField("defs.h", "XTRDMA_CEQE_PKT_OPCODE", "RDMA_CEQE_PKT_OPCODE", 0, 0, 8),
    ReferenceField("defs.h", "XTRDMA_CEQE_RC_CQ_PI_WRAP", "RDMA_CEQE_CQ_PI_WRAP", 8, 23, 1),
    ReferenceField("defs.h", "XTRDMA_AEQE_QPN", "RDMA_AEQE_QPN", 0, 0, 18),
    ReferenceField("defs.h", "XTRDMA_AEQE_QP_ST", "RDMA_AEQE_QP_ST", 0, 60, 3),
    ReferenceField("defs.h", "XTRDMA_AEQE_ECODE", "RDMA_AEQE_ECODE", 0, 24, 8),
    ReferenceField("defs.h", "XTRDMA_AEQE_QUEUE_WQE_IDX", "RDMA_AEQE_WQE_INDEX", 8, 32, 23),
    ReferenceField("defs.h", "XTRDMA_AEQE_WQE_VLD", "RDMA_AEQE_VALID", 0, 63, 1),
    ReferenceField("defs.h", "XTRDMA_AEQE_PKT_OPCODE", "RDMA_AEQE_PKT_OPCODE", 0, 32, 8),
    ReferenceField("defs.h", "XTRDMA_AEQE_QUEUE_WQE_IDX_WARP", "RDMA_AEQE_WQE_WRAP", 8, 55, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_DB_PI", "RDMA_CMQ_DB_PI", 0, 32, 5),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_DB_POL", "RDMA_CMQ_DB_POLARITY", 0, 37, 1),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_QPN", "RDMA_NOTIFY_RQ_QPN", 0, 0, 21),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_ICOS", "RDMA_NOTIFY_RQ_ICOS", 0, 21, 3),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_PI", "RDMA_NOTIFY_RQ_PI", 0, 32, 15),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_PI_WRAP", "RDMA_NOTIFY_RQ_PI_WRAP", 0, 47, 1),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_SRFQ_WRAP", "RDMA_NOTIFY_SRFQ_WRAP", 0, 47, 1),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_SRFQ_PI", "RDMA_NOTIFY_SRFQ_PI", 0, 32, 15),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_SRFQN", "RDMA_NOTIFY_SRFQN", 0, 0, 16),
    ReferenceField("wr.h", "XTRDMA_SRFQ_LIMIT_INVLD", "RDMA_NOTIFY_SRQ_LIMIT_INVALID", 0, 62, 1),
    ReferenceField("defs.h", "XTRDMA_SRFQ_PI_INVLD", "RDMA_NOTIFY_SRQ_PI_INVALID", 0, 63, 1),
    ReferenceField("defs.h", "XTRDMA_SRFQ_LIMIT_TH", "RDMA_NOTIFY_SRQ_LIMIT", 0, 18, 14),
    ReferenceField("defs.h", "XTRDMA_SRFQ_ARM_SN", "RDMA_NOTIFY_SRQ_ARM_SN", 0, 16, 2),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_CQN", "RDMA_NOTIFY_CQ_CQN", 0, 0, 21),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_HOST_ID", "RDMA_NOTIFY_CQ_HOST_ID", 0, 21, 3),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_RC_CI", "RDMA_NOTIFY_CQ_CI", 0, 24, 23),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_RC_CI_WRAP", "RDMA_NOTIFY_CQ_CI_WRAP", 0, 47, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_DB_FLAG", "RDMA_NOTIFY_CQ_ARM", 0, 61, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_ST", "RDMA_NOTIFY_CQ_ARM_ST", 0, 58, 2),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_SN", "RDMA_NOTIFY_CQ_ARM_SN", 0, 56, 2),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_CI_INVLD", "RDMA_NOTIFY_CQ_CI_INVALID", 0, 63, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_INVLD", "RDMA_NOTIFY_CQ_ARM_INVALID", 0, 62, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_FLAG", "RDMA_NOTIFY_CQ_URC", 0, 60, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_SQ_WQE_WRAP", "RDMA_NOTIFY_CQ_URC_SQ_WRAP", 0, 55, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_SQ_WQE_IDX", "RDMA_NOTIFY_CQ_URC_SQ_CI", 0, 40, 15),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_RQ_WQE_WRAP", "RDMA_NOTIFY_CQ_URC_RQ_WRAP", 0, 39, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_URC_SW_CPL_RQ_WQE_IDX", "RDMA_NOTIFY_CQ_URC_RQ_CI", 0, 24, 15),
    ReferenceField("defs.h", "XTRDMA_NOTIFY_CEQ_CI_WRAP", "RDMA_NOTIFY_CEQ_CI_WRAP", 0, 50, 1),
    ReferenceField("defs.h", "XTRDMA_NOTIFY_CEQ_CI", "RDMA_NOTIFY_CEQ_CI", 0, 32, 18),
    ReferenceField("defs.h", "XTRDMA_NOTIFY_CEQ_CEQN", "RDMA_NOTIFY_CEQ_CEQN", 0, 0, 22),
    ReferenceField("defs.h", "XTRDMA_NOTIFY_AEQ_CI_WRAP", "RDMA_NOTIFY_AEQ_CI_WRAP", 0, 50, 1),
    ReferenceField("defs.h", "XTRDMA_NOTIFY_AEQ_CI", "RDMA_NOTIFY_AEQ_CI", 0, 32, 18),
    ReferenceField("defs.h", "XTRDMA_NOTIFY_AEQ_AEQN", "RDMA_NOTIFY_AEQ_AEQN", 0, 0, 12),
    ReferenceField("qp.h", "XTRDMA_DST_PORT", "RDMA_NOTIFY_QP_DST_PORT", 0, 48, 4),
    ReferenceField("qp.h", "XTRDMA_QP_SN", "RDMA_NOTIFY_QP_SN", 0, 40, 8),
    ReferenceField("qp.h", "XTRDMA_DB_TYPE", "RDMA_NOTIFY_QP_DB_TYPE", 0, 36, 4),
    ReferenceField("qp.h", "XTRDMA_ICOS", "RDMA_NOTIFY_QP_ICOS", 0, 21, 3),
    ReferenceField("qp.h", "XTRDMA_QPN", "RDMA_NOTIFY_QP_QPN", 0, 0, 21),
    # Extended QPC placements used by the three transport boundary cases.
    ReferenceField("qp.h", "XTRDMA_QPC_UD_QKEY_L", "RDMA_QPC_UD_QKEY_L", 8, 40, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RSQ_PBA_H", "RDMA_QPC_URC_RSQ_PBA_H", 0, 0, 4),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RSQ_PBA_L", "RDMA_QPC_URC_RSQ_PBA_L", 8, 16, 48),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RSQ_SIZE", "RDMA_QPC_URC_RSQ_SIZE", 24, 59, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_SHADOW_PBA", "RDMA_QPC_SHADOW_PBA", 16, 9, 55),
    ReferenceField("qp.h", "XTRDMA_QPC_SQ_CE_EN", "RDMA_QPC_SQ_CE_EN", 16, 4, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_RA_RENCE", "RDMA_QPC_RA_FENCE", 16, 3, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_AA_FENCE", "RDMA_QPC_AA_FENCE", 16, 2, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_FC_EN", "RDMA_QPC_FC_EN", 16, 1, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_RNR_RETRY_TH", "RDMA_QPC_RNR_RETRY_TH", 24, 45, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_SRFQ", "RDMA_QPC_RC_SRFQ", 24, 31, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_SRFQN", "RDMA_QPC_RC_SRFQN", 24, 16, 15),
    ReferenceField("qp.h", "XTRDMA_QPC_QP_ACCESS_FLAG", "RDMA_QPC_QP_ACCESS_FLAG", 32, 0, 5),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RDSQ_PBA", "RDMA_QPC_URC_RDSQ_PBA", 32, 12, 52),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RDSQ_SIZE", "RDMA_QPC_URC_RDSQ_SIZE", 32, 8, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_PSN_RETRY_TH", "RDMA_QPC_PSN_RETRY_TH", 40, 5, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_VLAN", "RDMA_QPC_VLAN", 56, 63, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_IPV6", "RDMA_QPC_IPV6", 56, 62, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_TUNNEL", "RDMA_QPC_TUNNEL", 56, 61, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_LAG", "RDMA_QPC_LAG", 56, 60, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_FWD", "RDMA_QPC_FWD", 56, 58, 2),
    ReferenceField("qp.h", "XTRDMA_QPC_DST_VPORT_ID", "RDMA_QPC_DST_VPORT_ID", 56, 44, 11),
    ReferenceField("qp.h", "XTRDMA_QPC_SRC_ADDR_IDX", "RDMA_QPC_SRC_ADDR_IDX", 56, 32, 12),
    ReferenceField("qp.h", "XTRDMA_QPC_DST_PORT", "RDMA_QPC_DST_PORT", 56, 24, 4),
    ReferenceField("qp.h", "XTRDMA_QPC_DST_QPN", "RDMA_QPC_DST_QPN", 56, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_DMAC", "RDMA_QPC_DMAC", 64, 16, 48),
    ReferenceField("qp.h", "XTRDMA_QPC_PRI", "RDMA_QPC_PRI", 64, 13, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_CFI", "RDMA_QPC_CFI", 64, 12, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_VLAN_ID", "RDMA_QPC_VLAN_ID", 64, 0, 12),
    ReferenceField("qp.h", "XTRDMA_QPC_SRC_VPORT_ID", "RDMA_QPC_SRC_VPORT_ID", 72, 52, 11),
    ReferenceField("qp.h", "XTRDMA_QPC_FLOW_LABEL", "RDMA_QPC_FLOW_LABEL", 72, 32, 20),
    ReferenceField("qp.h", "XTRDMA_QPC_DSCP", "RDMA_QPC_DSCP", 72, 26, 6),
    ReferenceField("qp.h", "XTRDMA_QPC_ECN", "RDMA_QPC_ECN", 72, 24, 2),
    ReferenceField("qp.h", "XTRDMA_QPC_HOPLIMIT", "RDMA_QPC_HOPLIMIT", 72, 16, 8),
    ReferenceField("qp.h", "XTRDMA_QPC_CUR_UDP_SPORT", "RDMA_QPC_CUR_UDP_SPORT", 72, 0, 16),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_TX_RBSN", "RDMA_QPC_URC_TX_RBSN", 96, 24, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_TX_DBSN", "RDMA_QPC_URC_TX_DBSN", 96, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RX_RBSN", "RDMA_QPC_URC_RX_RBSN", 128, 24, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RX_DBSN", "RDMA_QPC_URC_RX_DBSN", 128, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_TPE_CUR_SQ_PSN", "RDMA_QPC_RC_TPE_CUR_SQ_PSN", 160, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_LAST_READ_PSN", "RDMA_QPC_RC_LAST_READ_PSN", 208, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_EIRQ_PSN_MAX", "RDMA_QPC_RC_EIRQ_PSN_MAX", 224, 24, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM", "RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM", 224, 16, 6),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RX_SRBSN", "RDMA_QPC_URC_RX_SRBSN", 224, 24, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_EIRQ_CUR_SEND_PSN", "RDMA_QPC_EIRQ_CUR_SEND_PSN", 232, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_CUR_TX_DPSN", "RDMA_QPC_URC_CUR_TX_DPSN", 232, 24, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_CUR_TX_RPSN", "RDMA_QPC_URC_CUR_TX_RPSN", 232, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_EPSN_REQ", "RDMA_QPC_EPSN_REQ", 288, 16, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RXED_DBSN", "RDMA_QPC_URC_RXED_DBSN", 296, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_RQ_SE_TH", "RDMA_QPC_URC_RQ_SE_TH", 320, 20, 4),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_SQ_CE_TH", "RDMA_QPC_URC_SQ_CE_TH", 320, 16, 4),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_TX_SRBSN", "RDMA_QPC_URC_TX_SRBSN", 328, 24, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_MAX_TX_SRBSN", "RDMA_QPC_URC_MAX_TX_SRBSN", 328, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_PSN_MAX_RPE", "RDMA_QPC_RC_PSN_MAX_RPE", 344, 32, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_EPSN_RSP", "RDMA_QPC_RC_EPSN_RSP", 352, 16, 24),
    ReferenceField("qp.h", "XTRDMA_QPC2_RC_EPSN_RSP", "RDMA_QPC2_RC_EPSN_RSP", 376, 32, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_CUR_DSQ_PBA_H", "RDMA_QPC_URC_CUR_DSQ_PBA_H", 384, 0, 40),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_CUR_DSQ_PBA_L", "RDMA_QPC_URC_CUR_DSQ_PBA_L", 392, 52, 12),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_NXT_DSQ_PBA", "RDMA_QPC_URC_NXT_DSQ_PBA", 392, 0, 52),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_TPE_RPSN_MAX", "RDMA_QPC_URC_TPE_RPSN_MAX", 400, 40, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_PSN_MAX_TPE", "RDMA_QPC_RC_PSN_MAX_TPE", 416, 40, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_TPE_DPSN_MAX", "RDMA_QPC_URC_TPE_DPSN_MAX", 416, 40, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_URC_NXT_DSQ_FETCH_NUM", "RDMA_QPC_URC_NXT_DSQ_FETCH_NUM", 416, 32, 6),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_RETRY_FPSN", "RDMA_QPC_RC_RETRY_FPSN", 424, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_RC_RETRY_PSN", "RDMA_QPC_RC_RETRY_PSN", 432, 0, 24),
    ReferenceField("qp.h", "XTRDMA_QPC_SQ_CQN", "RDMA_QPC_SQ_CQN", 448, 20, 20),
    ReferenceField("qp.h", "XTRDMA_QPC_RQ_CQN", "RDMA_QPC_RQ_CQN", 448, 0, 20),
    ReferenceField("qp.h", "XTRDMA_QPC_RQ_OR_SRQ_PD_PBA_OR_PBA", "RDMA_QPC_RQ_PBA", 496, 12, 52),
    ReferenceField("qp.h", "XTRDMA_QPC_RQ_OR_SRQ_SIZE", "RDMA_QPC_RQ_SIZE", 496, 8, 4),
    ReferenceField("qp.h", "XTRDMA_QPC_RQ_OR_SRQ_OM", "RDMA_QPC_RQ_OM", 496, 6, 2),
    # Sparse body placements, independently transcribed in final WQE coordinates.
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_CQC_WQE_CQN", "RDMA_CQC_BODY_CQN", 0, 0, 21),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_SD_PBA", "RDMA_CQC_BODY_CQ_SD_PBA", 8, 0, 52),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_SIZE", "RDMA_CQC_BODY_CQ_SIZE", 8, 56, 5),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_URC_FLAG", "RDMA_CQC_BODY_URC_FLAG", 8, 61, 1),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_ST", "RDMA_CQC_BODY_CQ_ST", 8, 62, 2),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_NXT_CQ_PD_PBA_H", "RDMA_CQC_BODY_NXT_CQ_PD_PBA_H", 16, 0, 8),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CUR_PBA_VLD", "RDMA_CQC_BODY_CUR_PBA_VLD", 16, 11, 1),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CUR_CQ_PD_PBA", "RDMA_CQC_BODY_CUR_CQ_PD_PBA", 16, 12, 52),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_LOAD_CQ_CI_DONE", "RDMA_CQC_BODY_LOAD_CQ_CI_DONE", 24, 0, 1),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_LOAD_CQ_CI_TH", "RDMA_CQC_BODY_LOAD_CQ_CI_TH", 24, 8, 3),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_OM", "RDMA_CQC_BODY_CQ_OM", 24, 14, 2),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_NXT_PBA_VLD", "RDMA_CQC_BODY_NXT_PBA_VLD", 24, 19, 1),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_NXT_CQ_PD_PBA_L", "RDMA_CQC_BODY_NXT_CQ_PD_PBA_L", 24, 20, 44),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_PI", "RDMA_CQC_BODY_CQ_PI", 32, 0, 23),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_PI_WRAP", "RDMA_CQC_BODY_CQ_PI_WRAP", 32, 23, 1),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_LAST_ARM_SN", "RDMA_CQC_BODY_LAST_ARM_SN", 32, 60, 2),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQE_SIZE", "RDMA_CQC_BODY_CQE_SIZE", 32, 62, 2),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CEQN", "RDMA_CQC_BODY_CEQN", 40, 0, 12),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_SHADOW_PA", "RDMA_CQC_BODY_SHADOW_PA", 48, 6, 58),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_CI", "RDMA_CQC_BODY_CQ_CI", 56, 0, 23),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_CI_WRAP", "RDMA_CQC_BODY_CQ_CI_WRAP", 56, 23, 1),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_ARM_SN", "RDMA_CQC_BODY_ARM_SN", 56, 32, 2),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_ARM_ST", "RDMA_CQC_BODY_ARM_ST", 56, 34, 2),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_STAG_IDX", "RDMA_MRT_BODY_STAG_IDX", 0, 0, 24),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_NXT_ST", "RDMA_MRT_BODY_NXT_ST", 0, 61, 2),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_STAG_KEY", "RDMA_MRT_BODY_STAG_KEY", 8, 24, 8),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PARENT_MR_STAG_IDX", "RDMA_MRT_BODY_PARENT_STAG_IDX", 16, 0, 24),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PD_IDX", "RDMA_MRT_BODY_PD_IDX", 16, 24, 16),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PLD_VF_ID", "RDMA_MRT_BODY_PLD_VF_ID", 16, 40, 8),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PLD_VF_EN", "RDMA_MRT_BODY_PLD_VF_EN", 16, 48, 1),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_RIGHT", "RDMA_MRT_BODY_RIGHT", 16, 49, 5),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_TYPE", "RDMA_MRT_BODY_TYPE", 16, 54, 2),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_HOST_PG_SIZE", "RDMA_MRT_BODY_HOST_PG_SIZE", 16, 56, 2),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_PBL_MODE", "RDMA_MRT_BODY_PBL_MODE", 16, 58, 2),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_ADDR_MODE", "RDMA_MRT_BODY_ADDR_MODE", 16, 60, 1),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_INVALIDATE_EN", "RDMA_MRT_BODY_INVALIDATE_EN", 16, 61, 1),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_ST", "RDMA_MRT_BODY_ST", 16, 62, 2),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_LEN", "RDMA_MRT_BODY_LEN", 24, 0, 46),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_ODP", "RDMA_MRT_BODY_ODP", 24, 47, 1),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_STAG_KEY", "RDMA_MRT_BODY_INFO_STAG_KEY", 24, 56, 8),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_START_VA", "RDMA_MRT_BODY_START_VA", 32, 0, 64),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_FIRST_PBL_IDX", "RDMA_MRT_BODY_FIRST_PBL_IDX", 40, 36, 28),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO0_Payload_PBA_0", "RDMA_MRT_BODY_PAYLOAD_PBA0", 40, 12, 52),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO1_MR_SN", "RDMA_MRT_BODY_MR_SN", 48, 0, 12),
    ReferenceField("cmq.h", "XTRDMA_CQPSQ_MRT_INFO1_Payload_PBA_1", "RDMA_MRT_BODY_PAYLOAD_PBA1", 48, 12, 52),
    ReferenceField("cmq.h", "XTRDMA_CMQCQ_WQE_SRFQN", "RDMA_SRQC_BODY_SRFQN", 0, 0, 16),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_ST", "RDMA_SRQC_BODY_SRFQ_ST", 16, 62, 2),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_LOAD_SRFQ_PI_TH", "RDMA_SRQC_BODY_LOAD_SRFQ_PI_TH", 16, 52, 8),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_SRFQC_SHADOW_PA", "RDMA_SRQC_BODY_SHADOW_PA", 16, 0, 52),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_PD_IDX", "RDMA_SRQC_BODY_PD_IDX", 24, 48, 16),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_PD_PBA_OR_PBA", "RDMA_SRQC_BODY_SRFQ_PBA", 32, 12, 52),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_SIZE", "RDMA_SRQC_BODY_SRFQ_SIZE", 32, 4, 4),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_OM", "RDMA_SRQC_BODY_SRFQ_OM", 32, 2, 2),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_PI_WRAP", "RDMA_SRQC_BODY_SRFQ_PI_WRAP", 40, 31, 1),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_SRFQ_PI", "RDMA_SRQC_BODY_SRFQ_PI", 40, 16, 15),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_SRQ_LIMIT_TH", "RDMA_SRQC_BODY_LIMIT_TH", 40, 2, 14),
    ReferenceField("srq.h", "XTRDMA_SRFQ_CTX_ARM_SN", "RDMA_SRQC_BODY_ARM_SN", 40, 0, 2),
    ReferenceField("cmq.h", "XTRDMA_CMQCQ_WQE_EQN", "RDMA_EQC_BODY_EQN", 0, 0, 12),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_EQ_ST", "RDMA_EQC_BODY_EQ_ST", 16, 62, 2),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_EQ_SIZE", "RDMA_EQC_BODY_EQ_SIZE", 16, 52, 5),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_NXT_EQ_PBA", "RDMA_EQC_BODY_NXT_EQ_PBA", 16, 0, 52),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_CUR_EQ_PBA", "RDMA_EQC_BODY_CUR_EQ_PBA", 24, 12, 52),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_CUR_PBA_VLD", "RDMA_EQC_BODY_CUR_PBA_VLD", 24, 11, 1),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_EQ_PI_WRAP", "RDMA_EQC_BODY_EQ_PI_WRAP", 32, 38, 1),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_EQ_PI", "RDMA_EQC_BODY_EQ_PI", 32, 20, 18),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_EQ_OM", "RDMA_EQC_BODY_EQ_OM", 32, 14, 2),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_MSI_X_IDX", "RDMA_EQC_BODY_MSI_X_IDX", 40, 48, 16),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_EQ_CI_WRAP", "RDMA_EQC_BODY_EQ_CI_WRAP", 40, 18, 1),
    ReferenceField("event.h", "XTRDMA_EQ_CTX_EQ_CI", "RDMA_EQC_BODY_EQ_CI", 40, 0, 18),
)

REFERENCE_BY_STEM = {reference.sv_stem: reference for reference in REFERENCE_FIELDS}


def validate_reference_fields(
    reference_fields: tuple[ReferenceField, ...],
    field_mappings: tuple[FieldMapping, ...],
    parsed_fields: dict[str, tuple[str, str, int, int]] | None = None,
) -> None:
    mappings_by_stem = {}
    for mapping in field_mappings:
        if mapping.sv_stem in mappings_by_stem:
            raise ValidationError(f"duplicate field mapping for {mapping.sv_stem}")
        mappings_by_stem[mapping.sv_stem] = mapping

    seen_stems = set()
    seen_sources = set()
    for reference in reference_fields:
        source_key = (
            reference.path,
            reference.c_symbol,
            reference.word_byte_offset,
        )
        if reference.sv_stem in seen_stems or source_key in seen_sources:
            raise ValidationError(f"duplicate reference field for {reference.sv_stem}")
        seen_stems.add(reference.sv_stem)
        seen_sources.add(source_key)
        if (
            reference.word_byte_offset < 0
            or reference.lsb < 0
            or reference.width < 1
            or reference.lsb + reference.width > 64
        ):
            raise ValidationError(f"invalid reference coordinates for {reference.sv_stem}")

        mapping = mappings_by_stem.get(reference.sv_stem)
        if mapping is None:
            raise ValidationError(f"reference mapping missing for {reference.sv_stem}")
        if mapping.path != reference.path or mapping.c_symbol != reference.c_symbol:
            raise ValidationError(f"reference source mismatch for {reference.sv_stem}")
        if mapping.word_byte_offset != reference.word_byte_offset:
            raise ValidationError(f"reference byte offset mismatch for {reference.sv_stem}")

        if parsed_fields is not None:
            parsed = parsed_fields.get(reference.sv_stem)
            if parsed is None:
                raise ValidationError(f"parsed reference field missing for {reference.sv_stem}")
            expected = (
                reference.path,
                reference.c_symbol,
                reference.lsb,
                reference.width,
            )
            if parsed != expected:
                raise ValidationError(f"reference mask mismatch for {reference.sv_stem}")


def parse_input_summary(summary: str) -> tuple[GoldenInput, ...]:
    if not summary:
        raise ValidationError("golden input summary must not be empty")
    inputs: list[GoldenInput] = []
    names: set[str] = set()
    for token in summary.split(","):
        match = re.fullmatch(r"([a-z][a-z0-9_]*)=([a-z0-9_]+)", token)
        if match is None:
            raise ValidationError(f"malformed golden input token: {token}")
        name, value = match.groups()
        if name in names:
            raise ValidationError(f"duplicate golden input name: {name}")
        names.add(name)
        inputs.append(GoldenInput(name, value))
    return tuple(inputs)


def build_golden_cases() -> dict[str, list[GoldenCase]]:
    def semantic_input(name: str, value: str | int):
        return ("", 0, f"{name}={value}")

    def make_case(name: str, byte_count: int, inputs) -> GoldenCase:
        summary = ",".join(
            summary_part for _, _, summary_part in inputs if summary_part
        )
        frozen_inputs = parse_input_summary(summary)
        image = ReferenceImage(byte_count)
        for stem, value, summary_part in inputs:
            if stem and summary_part:
                source = parse_input_summary(summary_part)[0]
                if re.fullmatch(r"(?:0x[0-9a-f]+|[0-9]+)", source.value):
                    # Split/derived values are checked after assembly by
                    # validate_context_contract; all other field values must
                    # be the exact frozen source input.
                    if (source.name not in {"qkey", "rsq_pba", "dsq_pba"}
                            and value != int(source.value, 0)):
                        raise ValidationError(
                            f"{name} field {stem} drifts from input {source.name}"
                        )
            if stem:
                put_named(image, stem, value)
        return GoldenCase(name, frozen_inputs, bytes(image))

    rc_send_psn = 0xABCDEF
    rc_recv_psn = 0x123456
    rc_traffic_class = 0xAA
    qpc_rc = make_case("qpc_rc_boundary", 512, (
        ("", 0, "transport=rc"),
        ("", 0, f"traffic_class={rc_traffic_class:#x}"),
        ("RDMA_QPC_TVER", 1, "tver=1"),
        ("RDMA_QPC_MIG", 1, "mig=1"),
        ("RDMA_QPC_SERVICE_TYPE", 0, ""),
        ("RDMA_QPC_HOST_ID", 5, "host=5"),
        ("RDMA_QPC_VF_ID", 0xABC, "vf=0xabc"),
        ("RDMA_QPC_ICOS", rc_traffic_class >> 5,
         f"icos={rc_traffic_class >> 5}"),
        ("RDMA_QPC_QPN", 0x15555, "qpn=0x15555"),
        ("RDMA_QPC_STAT_IDX", 0xA5, "stat_idx=0xa5"),
        ("RDMA_QPC_PKEY", 0xBEEF, "pkey=0xbeef"),
        ("RDMA_QPC_SHADOW_PBA", 0x123456789AB, "shadow_pba=0x123456789ab"),
        ("RDMA_QPC_TX_ENDIAN_SWAP", 1, "tx_swap=1"),
        ("RDMA_QPC_RX_ENDIAN_SWAP", 1, "rx_swap=1"),
        ("RDMA_QPC_SQ_CE_EN", 1, "sq_ce=1"),
        ("RDMA_QPC_RA_FENCE", 1, "ra_fence=1"),
        ("RDMA_QPC_AA_FENCE", 1, "aa_fence=1"),
        ("RDMA_QPC_FC_EN", 1, "fc=1"),
        ("RDMA_QPC_QP_ST", 3, "state=3"),
        ("RDMA_QPC_PMTU", 5, "pmtu=5"),
        ("RDMA_QPC_PSN_RETRY_TH", 7, "retry_count=7"),
        ("RDMA_QPC_RNR_RETRY_TH", 7, "rnr_retry=7"),
        ("RDMA_QPC_QP_SN", 0xC3, "qp_sn=0xc3"),
        ("RDMA_QPC_RC_SRFQ", 1, "srfq=1"),
        ("RDMA_QPC_RC_SRFQN", 0x4567, "srfqn=0x4567"),
        ("RDMA_QPC_PD_IDX", 0xA55A, "pd=0xa55a"),
        ("RDMA_QPC_QP_ACCESS_FLAG", 0x1F, "access=0x1f"),
        ("RDMA_QPC_DST_QPN", 0x654321, "dst_qpn=0x654321"),
        ("RDMA_QPC_DMAC", 0x112233445566, "dmac=0x112233445566"),
        ("RDMA_QPC_VLAN_ID", 0xABC, "vlan_id=0xabc"),
        ("RDMA_QPC_FLOW_LABEL", 0xABCDE, "flow=0xabcde"),
        ("RDMA_QPC_DSCP", rc_traffic_class >> 2,
         f"dscp={rc_traffic_class >> 2:#x}"),
        ("RDMA_QPC_ECN", 2, "ecn=2"),
        ("RDMA_QPC_HOPLIMIT", 0x40, "hop=0x40"),
        ("RDMA_QPC_CUR_UDP_SPORT", 0xC123, "udp_sport=0xc123"),
        ("RDMA_QPC_RC_TPE_CUR_SQ_PSN", rc_send_psn, f"send_psn={rc_send_psn:#x}"),
        ("RDMA_QPC_RC_LAST_READ_PSN", rc_send_psn, ""),
        ("RDMA_QPC_RC_PSN_MAX_RPE", rc_send_psn, ""),
        ("RDMA_QPC_RC_EPSN_RSP", rc_send_psn, ""),
        ("RDMA_QPC2_RC_EPSN_RSP", rc_send_psn, ""),
        ("RDMA_QPC_RC_PSN_MAX_TPE", rc_send_psn, ""),
        ("RDMA_QPC_RC_RETRY_FPSN", rc_send_psn, ""),
        ("RDMA_QPC_RC_RETRY_PSN", rc_send_psn, ""),
        ("RDMA_QPC_RC_EIRQ_PSN_MAX", rc_recv_psn, f"recv_psn={rc_recv_psn:#x}"),
        ("RDMA_QPC_EIRQ_CUR_SEND_PSN", rc_recv_psn, ""),
        ("RDMA_QPC_EPSN_REQ", rc_recv_psn, ""),
        ("RDMA_QPC_SQ_PBA", 0x123456789ABCD, "sq_pba=0x123456789abcd"),
        ("RDMA_QPC_SQ_SIZE", 0xB, "sq_size=11"),
        ("RDMA_QPC_SQ_OM", 2, "sq_om=2"),
        ("RDMA_QPC_SQ_CQN", 0xABCDE, "sq_cqn=0xabcde"),
        ("RDMA_QPC_RQ_CQN", 0x54321, "rq_cqn=0x54321"),
        ("RDMA_QPC_RQ_PBA", 0x0FEDCBA987654, "rq_pba=0x0fedcba987654"),
        ("RDMA_QPC_RQ_SIZE", 0xA, "rq_size=10"),
        ("RDMA_QPC_RQ_OM", 1, "rq_om=1"),
    ))

    ud_qkey = 0x89ABCDEF
    ud_dest_ip = bytes.fromhex("20010db8000000000000000000000001")
    ud_traffic_class = 0xAC
    qpc_ud = make_case("qpc_ud_boundary", 512, (
        ("", 0, "transport=ud"),
        ("", 0, f"traffic_class={ud_traffic_class:#x}"),
        ("RDMA_QPC_TVER", 1, "tver=1"),
        ("RDMA_QPC_MIG", 0, "mig=0"),
        ("RDMA_QPC_SERVICE_TYPE", 3, ""),
        ("RDMA_QPC_HOST_ID", 6, "host=6"),
        ("RDMA_QPC_VF_ID", 0x345, "vf=0x345"),
        ("RDMA_QPC_ICOS", ud_traffic_class >> 5,
         f"icos={ud_traffic_class >> 5}"),
        ("RDMA_QPC_QPN", 0x2AAAA, "qpn=0x2aaaa"),
        ("RDMA_QPC_STAT_IDX", 0x5A, "stat_idx=0x5a"),
        ("RDMA_QPC_UD_QKEY_H", ud_qkey >> 24, f"qkey={ud_qkey:#x}"),
        ("RDMA_QPC_UD_QKEY_L", ud_qkey & 0xFFFFFF, ""),
        ("RDMA_QPC_PKEY", 0x1234, "pkey=0x1234"),
        ("RDMA_QPC_SHADOW_PBA", 0x0FEDCBA9876, "shadow_pba=0x0fedcba9876"),
        ("RDMA_QPC_TX_ENDIAN_SWAP", 1, "tx_swap=1"),
        ("RDMA_QPC_RX_ENDIAN_SWAP", 1, "rx_swap=1"),
        ("RDMA_QPC_QP_ST", 3, "state=3"),
        ("RDMA_QPC_PMTU", 4, "pmtu=4"),
        ("RDMA_QPC_QP_SN", 0x7E, "qp_sn=0x7e"),
        ("RDMA_QPC_PD_IDX", 0x5AA5, "pd=0x5aa5"),
        ("RDMA_QPC_VLAN", 1, "vlan=1"),
        ("RDMA_QPC_IPV6", 1, "ipv6=1"),
        ("RDMA_QPC_TUNNEL", 1, "tunnel=1"),
        ("RDMA_QPC_LAG", 1, "lag=1"),
        ("RDMA_QPC_FWD", 2, "fwd=2"),
        ("RDMA_QPC_DST_VPORT_ID", 0x456, "dst_vport=0x456"),
        ("RDMA_QPC_SRC_ADDR_IDX", 0xABC, "src_addr=0xabc"),
        ("RDMA_QPC_DST_PORT", 0xB, "dst_port=0xb"),
        ("RDMA_QPC_DST_QPN", 0xABCDEF, "dst_qpn=0xabcdef"),
        ("RDMA_QPC_DMAC", 0xA1B2C3D4E5F6, "dmac=0xa1b2c3d4e5f6"),
        ("RDMA_QPC_PRI", 5, "pri=5"),
        ("RDMA_QPC_CFI", 1, "cfi=1"),
        ("RDMA_QPC_VLAN_ID", 0x789, "vlan_id=0x789"),
        ("RDMA_QPC_SRC_VPORT_ID", 0x345, "src_vport=0x345"),
        ("RDMA_QPC_FLOW_LABEL", 0x54321, "flow=0x54321"),
        ("RDMA_QPC_DSCP", ud_traffic_class >> 2,
         f"dscp={ud_traffic_class >> 2:#x}"),
        ("RDMA_QPC_ECN", 0, "ecn=0"),
        ("RDMA_QPC_HOPLIMIT", 0x7F, "hop=0x7f"),
        ("RDMA_QPC_CUR_UDP_SPORT", 0xBEEF, "udp_sport=0xbeef"),
        ("", 0, f"dest_ip={ud_dest_ip.hex()}"),
        ("RDMA_QPC_SQ_PBA", 0x1111122222333, "sq_pba=0x1111122222333"),
        ("RDMA_QPC_SQ_SIZE", 9, "sq_size=9"),
        ("RDMA_QPC_SQ_OM", 3, "sq_om=3"),
        ("RDMA_QPC_SQ_CQN", 0x13579, "sq_cqn=0x13579"),
        ("RDMA_QPC_RQ_CQN", 0x2468A, "rq_cqn=0x2468a"),
        ("RDMA_QPC_RQ_PBA", 0x4444455555666, "rq_pba=0x4444455555666"),
        ("RDMA_QPC_RQ_SIZE", 8, "rq_size=8"),
        ("RDMA_QPC_RQ_OM", 2, "rq_om=2"),
    ))
    qpc_ud_image = bytearray(qpc_ud.payload)
    dest_ip_offset = PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTE_OFFSET"]
    dest_ip_bytes = PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTES"]
    if len(ud_dest_ip) != dest_ip_bytes:
        raise ValidationError("QPC destination IP does not match profile byte count")
    qpc_ud_image[dest_ip_offset:dest_ip_offset + dest_ip_bytes] = ud_dest_ip
    qpc_ud = qpc_ud._replace(payload=bytes(qpc_ud_image))

    urc_traffic_class = 0xFE
    urc_context_backing = 0x123456789AB << 9
    urc_rsq_backing = 0x123456789ABCD << 12
    urc_rdsq_backing = 0x23456789ABCDE << 12
    urc_dsq_backing = 0x3456789ABCDEF << 12
    urc_sq_backing = 0x456789ABCDEF0 << 12
    urc_rq_backing = 0x56789ABCDEF01 << 12
    urc_rsq_depth = 64
    urc_rdsq_depth = 64
    urc_sq_depth = 32768
    urc_rq_depth = 16384
    urc_rq_sequence_threshold = 2048
    urc_sq_completion_threshold = 4096
    urc_remote_qpn = 0x654321
    urc_rbsn = 0xABCDEF
    urc_dbsn = 0x654321
    urc_rpsn = 0x56789A
    urc_dpsn = 0x456789
    urc_dest_ip = bytes(16)
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
        semantic_input("context_backing", f"{urc_context_backing:#x}"),
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
        semantic_input("vlan_enable", 0),
        semantic_input("ipv6", 0),
        semantic_input("tunnel_enable", 0),
        semantic_input("lag_enable", 0),
        semantic_input("forwarding_enable", 0),
        semantic_input("destination_vport", 0),
        semantic_input("source_address_index", 0),
        semantic_input("destination_port", 0),
        semantic_input("remote_qpn", f"{urc_remote_qpn:#x}"),
        semantic_input("destination_mac", 0),
        semantic_input("priority", 0),
        semantic_input("cfi", 0),
        semantic_input("vlan_id", 0),
        semantic_input("source_vport", 0),
        semantic_input("flow_label", 0),
        semantic_input("hop_limit", 0),
        semantic_input("udp_source_port", 0),
        semantic_input("destination_ip", urc_dest_ip.hex()),
        semantic_input("rbsn", f"{urc_rbsn:#x}"),
        semantic_input("dbsn", f"{urc_dbsn:#x}"),
        semantic_input("rpsn", f"{urc_rpsn:#x}"),
        semantic_input("dpsn", f"{urc_dpsn:#x}"),
        semantic_input("rsq_backing", f"{urc_rsq_backing:#x}"),
        semantic_input("rdsq_backing", f"{urc_rdsq_backing:#x}"),
        semantic_input("dsq_backing", f"{urc_dsq_backing:#x}"),
        semantic_input("rsq_depth", urc_rsq_depth),
        semantic_input("rdsq_depth", urc_rdsq_depth),
        semantic_input("rdsq_fetch_count", 8),
        semantic_input("dsq_fetch_count", 8),
        semantic_input("rq_sequence_threshold_entries", urc_rq_sequence_threshold),
        semantic_input("sq_completion_threshold_entries", urc_sq_completion_threshold),
        semantic_input("sq_backing", f"{urc_sq_backing:#x}"),
        semantic_input("sq_depth", urc_sq_depth),
        semantic_input("sq_mode", 3),
        semantic_input("send_cq_id", "0xfffff"),
        semantic_input("recv_cq_id", "0xabcde"),
        semantic_input("rq_backing", f"{urc_rq_backing:#x}"),
        semantic_input("rq_depth", urc_rq_depth),
        semantic_input("rq_mode", 2),
        ("RDMA_QPC_TVER", 1, ""),
        ("RDMA_QPC_MIG", 1, ""),
        ("RDMA_QPC_SERVICE_TYPE", 6, ""),
        ("RDMA_QPC_HOST_ID", 7, ""),
        ("RDMA_QPC_VF_ID", 0x789, ""),
        ("RDMA_QPC_ICOS", urc_traffic_class >> 5, ""),
        ("RDMA_QPC_QPN", 0x3FFFF, ""),
        ("RDMA_QPC_STAT_IDX", 0xFF, ""),
        ("RDMA_QPC_URC_RSQ_PBA_H", (urc_rsq_backing >> 12) >> 48, ""),
        ("RDMA_QPC_URC_RSQ_PBA_L", (urc_rsq_backing >> 12) & ((1 << 48) - 1), ""),
        ("RDMA_QPC_URC_RSQ_SIZE", urc_rsq_depth.bit_length() - 1, ""),
        ("RDMA_QPC_PKEY", 0xABCD, ""),
        ("RDMA_QPC_SHADOW_PBA", urc_context_backing >> 9, ""),
        ("RDMA_QPC_TX_ENDIAN_SWAP", 0, ""),
        ("RDMA_QPC_RX_ENDIAN_SWAP", 0, ""),
        ("RDMA_QPC_SQ_CE_EN", 0, ""),
        ("RDMA_QPC_RA_FENCE", 0, ""),
        ("RDMA_QPC_AA_FENCE", 0, ""),
        ("RDMA_QPC_FC_EN", 0, ""),
        ("RDMA_QPC_QP_ST", 3, ""),
        ("RDMA_QPC_PMTU", 5, ""),
        ("RDMA_QPC_QP_SN", 0xFE, ""),
        ("RDMA_QPC_PD_IDX", 0xFFFF, ""),
        ("RDMA_QPC_QP_ACCESS_FLAG", 0, ""),
        ("RDMA_QPC_URC_RDSQ_PBA", urc_rdsq_backing >> 12, ""),
        ("RDMA_QPC_URC_RDSQ_SIZE", urc_rdsq_depth.bit_length() - 1, ""),
        ("RDMA_QPC_VLAN", 0, ""),
        ("RDMA_QPC_IPV6", 0, ""),
        ("RDMA_QPC_TUNNEL", 0, ""),
        ("RDMA_QPC_LAG", 0, ""),
        ("RDMA_QPC_FWD", 0, ""),
        ("RDMA_QPC_DST_VPORT_ID", 0, ""),
        ("RDMA_QPC_SRC_ADDR_IDX", 0, ""),
        ("RDMA_QPC_DST_PORT", 0, ""),
        ("RDMA_QPC_DST_QPN", urc_remote_qpn, ""),
        ("RDMA_QPC_DMAC", 0, ""),
        ("RDMA_QPC_PRI", 0, ""),
        ("RDMA_QPC_CFI", 0, ""),
        ("RDMA_QPC_VLAN_ID", 0, ""),
        ("RDMA_QPC_SRC_VPORT_ID", 0, ""),
        ("RDMA_QPC_FLOW_LABEL", 0, ""),
        ("RDMA_QPC_DSCP", urc_traffic_class >> 2, ""),
        ("RDMA_QPC_ECN", urc_traffic_class & 0x3, ""),
        ("RDMA_QPC_HOPLIMIT", 0, ""),
        ("RDMA_QPC_CUR_UDP_SPORT", 0, ""),
        ("RDMA_QPC_URC_TX_RBSN", urc_rbsn, ""),
        ("RDMA_QPC_URC_TX_DBSN", urc_dbsn, ""),
        ("RDMA_QPC_URC_RX_RBSN", urc_rbsn, ""),
        ("RDMA_QPC_URC_RX_DBSN", urc_dbsn, ""),
        ("RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM", 8, ""),
        ("RDMA_QPC_URC_RX_SRBSN", 0, ""),
        ("RDMA_QPC_URC_CUR_TX_DPSN", urc_dpsn, ""),
        ("RDMA_QPC_URC_CUR_TX_RPSN", urc_rpsn, ""),
        ("RDMA_QPC_URC_RXED_DBSN", urc_dbsn, ""),
        ("RDMA_QPC_URC_RQ_SE_TH", urc_rq_sequence_threshold.bit_length() - 1, ""),
        ("RDMA_QPC_URC_SQ_CE_TH", urc_sq_completion_threshold.bit_length() - 1, ""),
        # Exercise the runtime coordinates at zero. ReferenceImage occupancy is
        # checker coverage, not ownership in a future codec create mask.
        ("RDMA_QPC_URC_TX_SRBSN", 0, ""),
        ("RDMA_QPC_URC_MAX_TX_SRBSN", 0, ""),
        ("RDMA_QPC_URC_CUR_DSQ_PBA_H", (urc_dsq_backing >> 12) >> 12, ""),
        ("RDMA_QPC_URC_CUR_DSQ_PBA_L", (urc_dsq_backing >> 12) & 0xFFF, ""),
        ("RDMA_QPC_URC_NXT_DSQ_PBA", (urc_dsq_backing >> 12) + 1, ""),
        ("RDMA_QPC_URC_TPE_RPSN_MAX", urc_rpsn, ""),
        ("RDMA_QPC_URC_TPE_DPSN_MAX", urc_dpsn, ""),
        ("RDMA_QPC_URC_NXT_DSQ_FETCH_NUM", 8, ""),
        ("RDMA_QPC_SQ_PBA", urc_sq_backing >> 12, ""),
        ("RDMA_QPC_SQ_SIZE", urc_sq_depth.bit_length() - 1, ""),
        ("RDMA_QPC_SQ_OM", 3, ""),
        ("RDMA_QPC_SQ_CQN", 0xFFFFF, ""),
        ("RDMA_QPC_RQ_CQN", 0xABCDE, ""),
        ("RDMA_QPC_RQ_PBA", urc_rq_backing >> 12, ""),
        ("RDMA_QPC_RQ_SIZE", urc_rq_depth.bit_length() - 1, ""),
        ("RDMA_QPC_RQ_OM", 2, ""),
    ))
    qpc_urc_image = bytearray(qpc_urc.payload)
    if len(urc_dest_ip) != dest_ip_bytes:
        raise ValidationError("URC QPC destination IP does not match profile byte count")
    qpc_urc_image[dest_ip_offset:dest_ip_offset + dest_ip_bytes] = urc_dest_ip
    qpc_urc = qpc_urc._replace(payload=bytes(qpc_urc_image))

    cqc = make_case("cqc_create_body_boundary", 64, (
        ("RDMA_CQC_BODY_CQN", 0x1FFFFF, "cqn=0x1fffff"),
        ("RDMA_CQC_BODY_CQ_SD_PBA", 0xFFFFFFFFFFFFF, "sd_pba=0xfffffffffffff"),
        ("RDMA_CQC_BODY_CQ_SIZE", 0x1F, "size=0x1f"),
        ("RDMA_CQC_BODY_URC_FLAG", 1, "urc=1"), ("RDMA_CQC_BODY_CQ_ST", 2, "state=2"),
        ("RDMA_CQC_BODY_NXT_CQ_PD_PBA_H", 0xFF, "next_hi=0xff"),
        ("RDMA_CQC_BODY_CUR_PBA_VLD", 1, "cur_valid=1"),
        ("RDMA_CQC_BODY_CUR_CQ_PD_PBA", 0xFFFFFFFFFFFFF, "cur_pba=0xfffffffffffff"),
        ("RDMA_CQC_BODY_LOAD_CQ_CI_DONE", 1, "load_ci=1"),
        ("RDMA_CQC_BODY_LOAD_CQ_CI_TH", 7, "threshold=7"),
        ("RDMA_CQC_BODY_CQ_OM", 3, "mode=3"), ("RDMA_CQC_BODY_NXT_PBA_VLD", 1, "next_valid=1"),
        ("RDMA_CQC_BODY_NXT_CQ_PD_PBA_L", 0xFFFFFFFFFFF, "next_lo=0xfffffffffff"),
        ("RDMA_CQC_BODY_CQ_PI", 0x7FFFFF, "pi=0x7fffff"),
        ("RDMA_CQC_BODY_CQ_PI_WRAP", 1, "pi_wrap=1"),
        ("RDMA_CQC_BODY_LAST_ARM_SN", 3, "last_arm=3"),
        ("RDMA_CQC_BODY_CQE_SIZE", 2, "cqe_size=2"),
        ("RDMA_CQC_BODY_CEQN", 0xFFF, "ceqn=0xfff"),
        ("RDMA_CQC_BODY_SHADOW_PA", 0x3FFFFFFFFFFFFFF, "shadow=0x3ffffffffffffff"),
        ("RDMA_CQC_BODY_CQ_CI", 0x7FFFFF, "ci=0x7fffff"),
        ("RDMA_CQC_BODY_CQ_CI_WRAP", 1, "ci_wrap=1"),
        ("RDMA_CQC_BODY_ARM_SN", 3, "arm_sn=3"), ("RDMA_CQC_BODY_ARM_ST", 2, "arm_state=2"),
    ))

    def make_mrt(name: str, pbl: int, key_alloc: bool) -> GoldenCase:
        opcode = 0x04 if key_alloc else 0x05
        stag = 0xFFFFFF
        state = 2
        key = 0xFF
        pd = 0xFFFF
        payload_vf = 0xFF
        rights = 0x1F
        mem_type = 2
        host_page = 2
        address_mode = 1
        invalidate = 1
        length = 0x3FFFFFFFFFFF
        start_va = 0xFFFFFFFFFFFFFFFF
        payload_pba = 0xFFFFFFFFFFFFF
        first_pbl = 0xFFFFFFF
        mr_sn = 0xFFF
        fields = [
            ("", 0, f"opcode={opcode:#04x}"),
            ("RDMA_MRT_BODY_STAG_IDX", stag, f"stag={stag:#x}"),
            ("RDMA_MRT_BODY_NXT_ST", state, f"state={state}"),
            ("RDMA_MRT_BODY_STAG_KEY", key, f"key={key:#x}"),
            ("RDMA_MRT_BODY_PD_IDX", pd, f"pd={pd:#x}"),
            ("RDMA_MRT_BODY_PLD_VF_ID", payload_vf,
             f"payload_vf={payload_vf:#x}"),
            ("RDMA_MRT_BODY_PLD_VF_EN", 1, "payload_vf_en=1"),
            ("RDMA_MRT_BODY_RIGHT", rights, f"rights={rights:#x}"),
            ("RDMA_MRT_BODY_TYPE", mem_type, f"type={mem_type}"),
            ("RDMA_MRT_BODY_HOST_PG_SIZE", host_page,
             f"host_page={host_page}"),
            ("RDMA_MRT_BODY_PBL_MODE", pbl, f"pbl={pbl}"),
            ("RDMA_MRT_BODY_ADDR_MODE", address_mode,
             f"address_mode={address_mode}"),
            ("RDMA_MRT_BODY_INVALIDATE_EN", invalidate,
             f"invalidate={invalidate}"),
            ("RDMA_MRT_BODY_ST", state, ""),
            ("RDMA_MRT_BODY_LEN", length, f"length={length:#x}"),
            ("RDMA_MRT_BODY_ODP", 1, "odp=1"),
            ("RDMA_MRT_BODY_INFO_STAG_KEY", key, ""),
            ("RDMA_MRT_BODY_START_VA", start_va,
             f"start_va={start_va:#x}"),
        ]
        if key_alloc:
            fields.insert(4, ("RDMA_MRT_BODY_PARENT_STAG_IDX", stag,
                              "parent=self"))
        else:
            fields.insert(4, ("RDMA_MRT_BODY_PARENT_STAG_IDX", 0,
                              "parent=0"))
        if pbl == 2:
            fields.append(("RDMA_MRT_BODY_FIRST_PBL_IDX", first_pbl,
                           f"first_pbl={first_pbl:#x}"))
        else:
            fields.append(("RDMA_MRT_BODY_PAYLOAD_PBA0", payload_pba,
                           f"pba0={payload_pba:#x}"))
        if pbl == 1:
            fields.append(("RDMA_MRT_BODY_PAYLOAD_PBA1", payload_pba,
                           f"pba1={payload_pba:#x}"))
        fields.append(("RDMA_MRT_BODY_MR_SN", mr_sn, f"mr_sn={mr_sn:#x}"))
        return make_case(name, 64, fields)

    mrt_pbl0 = make_mrt("mrt_register_pbl0_boundary", 0, False)
    mrt_pbl1 = make_mrt("mrt_register_pbl1_boundary", 1, False)
    mrt_pbl2 = make_mrt("mrt_register_pbl2_boundary", 2, False)
    mrt_key0 = make_mrt("mrt_key_alloc_pbl0_boundary", 0, True)
    mrt_key1 = make_mrt("mrt_key_alloc_pbl1_boundary", 1, True)
    mrt_key2 = make_mrt("mrt_key_alloc_pbl2_boundary", 2, True)

    srqc = make_case("srqc_create_body_boundary", 64, (
        ("RDMA_SRQC_BODY_SRFQN", 0xFFFF, "srfqn=0xffff"),
        ("RDMA_SRQC_BODY_SRFQ_ST", 2, "state=2"),
        ("RDMA_SRQC_BODY_LOAD_SRFQ_PI_TH", 0xFF, "load_pi=0xff"),
        ("RDMA_SRQC_BODY_SHADOW_PA", 0xFFFFFFFFFFFFF, "shadow=0xfffffffffffff"),
        ("RDMA_SRQC_BODY_PD_IDX", 0xFFFF, "pd=0xffff"),
        ("RDMA_SRQC_BODY_SRFQ_PBA", 0xFFFFFFFFFFFFF, "pba=0xfffffffffffff"),
        ("RDMA_SRQC_BODY_SRFQ_SIZE", 0xF, "size=0xf"),
        ("RDMA_SRQC_BODY_SRFQ_OM", 3, "mode=3"),
        ("RDMA_SRQC_BODY_SRFQ_PI_WRAP", 1, "pi_wrap=1"),
        ("RDMA_SRQC_BODY_SRFQ_PI", 0x7FFF, "pi=0x7fff"),
        ("RDMA_SRQC_BODY_LIMIT_TH", 0x3FFF, "limit=0x3fff"),
        ("RDMA_SRQC_BODY_ARM_SN", 3, "arm_sn=3"),
    ))

    def make_eq(name: str) -> GoldenCase:
        return make_case(name, 64, (
            ("RDMA_EQC_BODY_EQN", 0xFFF, "eqn=0xfff"),
            ("RDMA_EQC_BODY_EQ_ST", 2, "state=2"),
            ("RDMA_EQC_BODY_EQ_SIZE", 0x1F, "size=0x1f"),
            ("RDMA_EQC_BODY_NXT_EQ_PBA", 0xFFFFFFFFFFFFF, "next=0xfffffffffffff"),
            ("RDMA_EQC_BODY_CUR_EQ_PBA", 0xFFFFFFFFFFFFF, "current=0xfffffffffffff"),
            ("RDMA_EQC_BODY_CUR_PBA_VLD", 1, "current_valid=1"),
            ("RDMA_EQC_BODY_EQ_PI_WRAP", 1, "pi_wrap=1"),
            ("RDMA_EQC_BODY_EQ_PI", 0x3FFFF, "pi=0x3ffff"),
            ("RDMA_EQC_BODY_EQ_OM", 3, "mode=3"),
            ("RDMA_EQC_BODY_MSI_X_IDX", 0xFFFF, "msix=0xffff"),
            ("RDMA_EQC_BODY_EQ_CI_WRAP", 1, "ci_wrap=1"),
            ("RDMA_EQC_BODY_EQ_CI", 0x3FFFF, "ci=0x3ffff"),
        ))
    ceqc = make_eq("ceqc_create_body_boundary")
    aeqc = make_eq("aeqc_create_body_boundary")

    cmq = make_case("qpc_create", 64, (
        ("RDMA_CMQ_OPCODE", 0, "opcode=0"),
        ("RDMA_CMQ_QPN", 0x654321, "qpn=0x654321"),
        ("RDMA_CMQ_WQE_INDEX", 0x1B, "index=27"),
        ("RDMA_CMQ_VALID", 1, "valid=1"),
        ("RDMA_CMQ_VFID_OVERRIDE", 1, "vfid_override=1"),
        ("RDMA_CMQ_USE_VFID", 0x345, "use_vfid=0x345"),
        ("RDMA_CMQ_WRAP", 1, "wrap=1"),
        ("RDMA_CMQ_SQ_CQN", 0x15555, "sq_cqn=0x15555"),
        ("RDMA_CMQ_SIGN_EN", 1, "sign=1"),
        ("RDMA_CMQ_RQ_CQN", 0x0AAAA, "rq_cqn=0xaaaa"),
        ("RDMA_CMQ_QPC_BUFFER_ADDR", 0x123456789AB, "buffer=0x123456789ab"),
    ))

    sqe = make_case("sqe_rc_boundary", 64, (
        ("RDMA_SQ_WQE_QPN", 0x15555, "qpn=0x15555"),
        ("RDMA_SQ_WQE_OPCODE", 0xD, "opcode=13"),
        ("RDMA_SQ_WQE_INDEX", 0x4567, "index=0x4567"),
        ("RDMA_SQ_WQE_RC_REMOTE_KEY", 0xDEADBEEF, "rkey=0xdeadbeef"),
        ("RDMA_SQ_WQE_ICOS", 5, "icos=5"),
        ("RDMA_SQ_WQE_QP_SN", 0xA6, "qp_sn=0xa6"),
        ("RDMA_SQ_WQE_DST_PORT", 0xB, "dst_port=11"),
        ("RDMA_SQ_WQE_WRAP", 1, "wrap=1"),
        ("RDMA_SQ_WQE_SIGN_EN", 1, "sign=1"),
        ("RDMA_SQ_WQE_SE", 1, "se=1"),
        ("RDMA_SQ_WQE_FENCE", 2, "fence=2"),
        ("RDMA_SQ_WQE_CE", 2, "ce=2"),
        ("RDMA_SQ_WQE_VALID", 1, "valid=1"),
        ("RDMA_SQ_WQE_SIGNATURE", 0xC7, "signature=0xc7"),
        ("RDMA_SQ_WQE_RC_SGE_NUM", 4, "sge_num=4"),
        ("RDMA_SQ_WQE_RC_REMOTE_VA", 0x0123456789ABCDEF,
         "remote_va=0x0123456789abcdef"),
    ))

    rqe = make_case("rqe_boundary", 64, (
        ("RDMA_RQE_QPN", 0xABCDE, "qpn=0xabcde"),
        ("RDMA_RQE_INDEX", 0x3456, "index=0x3456"),
        ("RDMA_RQE_PAYLOAD_LEN", 0x10203040, "payload=0x10203040"),
        ("RDMA_RQE_QP_SN", 0x5A, "qp_sn=0x5a"),
        ("RDMA_RQE_OPCODE", 9, "opcode=9"),
        ("RDMA_RQE_WRAP", 1, "wrap=1"),
        ("RDMA_RQE_VALID", 1, "valid=1"),
        ("RDMA_RQE_SIGNATURE", 0x96, "signature=0x96"),
        ("RDMA_RQE_SGE_NUM", 2, "sge_num=2"),
    ))

    cqe = make_case("cqe_error", 64, (
        ("RDMA_CQE_QPN", 0x2AAAA, "qpn=0x2aaaa"),
        ("RDMA_CQE_WQE_INDEX", 0x4567, "index=0x4567"),
        ("RDMA_CQE_ECODE", 0xF4, "ecode=0xf4"),
        ("RDMA_CQE_PAYLOAD_LEN", 0x10203040, "payload=0x10203040"),
        ("RDMA_CQE_POLARITY", 1, "polarity=1"),
        ("RDMA_CQE_RQ_CQE", 1, "rq_cqe=1"),
        ("RDMA_CQE_WQE_WRAP", 1, "wrap=1"),
        ("RDMA_CQE_PKT_OPCODE", 0x9A, "packet_opcode=0x9a"),
        ("RDMA_CQE_IMMDT_DATA", 0x89ABCDEF, "immediate=0x89abcdef"),
    ))

    ceqe = make_case("ceqe_error", 16, (
        ("RDMA_CEQE_QPN", 0x15555, "qpn=0x15555"),
        ("RDMA_CEQE_CQN", 0x1AAAAA, "cqn=0x1aaaaa"),
        ("RDMA_CEQE_ECODE", 0xF4, "ecode=0xf4"),
        ("RDMA_CEQE_CQ_PI", 0xBEEF, "pi=0xbeef"),
        ("RDMA_CEQE_VALID", 1, "valid=1"),
        ("RDMA_CEQE_PKT_OPCODE", 0x9A, "packet_opcode=0x9a"),
        ("RDMA_CEQE_CQ_PI_WRAP", 1, "wrap=1"),
    ))

    aeqe = make_case("aeqe_error", 16, (
        ("RDMA_AEQE_QPN", 0x2AAAA, "qpn=0x2aaaa"),
        ("RDMA_AEQE_QP_ST", 5, "state=5"),
        ("RDMA_AEQE_ECODE", 0xFF, "ecode=0xff"),
        ("RDMA_AEQE_WQE_INDEX", 0x654321, "index=0x654321"),
        ("RDMA_AEQE_VALID", 1, "valid=1"),
        ("RDMA_AEQE_PKT_OPCODE", 0x81, "packet_opcode=0x81"),
        ("RDMA_AEQE_WQE_WRAP", 1, "wrap=1"),
    ))

    cmq_db = make_case("cmq_sq", 8, (
        ("RDMA_CMQ_DB_PI", 0x1B, "pi=27"),
        ("RDMA_CMQ_DB_POLARITY", 1, "polarity=1"),
        ("", 0, "offset=0x0"),
    ))
    sq_db = GoldenCase(
        "sq", parse_input_summary("offset=0x100"), sqe.payload[:8]
    )
    rq_db = make_case("rq", 8, (
        ("RDMA_NOTIFY_RQ_QPN", 0x15555, "qpn=0x15555"),
        ("RDMA_NOTIFY_RQ_ICOS", 5, "icos=5"),
        ("RDMA_NOTIFY_RQ_PI", 0x4567, "pi=0x4567"),
        ("RDMA_NOTIFY_RQ_PI_WRAP", 1, "wrap=1"),
        ("", 0, "offset=0x10"),
    ))
    srq_pi_db = make_case("srq_pi", 8, (
        ("RDMA_NOTIFY_SRFQN", 0xA55A, "srqn=0xa55a"),
        ("RDMA_NOTIFY_SRFQ_PI", 0x4567, "pi=0x4567"),
        ("RDMA_NOTIFY_SRFQ_WRAP", 1, "wrap=1"),
        ("RDMA_NOTIFY_SRQ_LIMIT_INVALID", 1, "limit_invalid=1"),
        ("", 0, "offset=0x40"),
    ))
    srq_limit_db = make_case("srq_limit", 8, (
        ("RDMA_NOTIFY_SRFQN", 0xA55A, "srqn=0xa55a"),
        ("RDMA_NOTIFY_SRQ_LIMIT", 0x2AAA, "limit=0x2aaa"),
        ("RDMA_NOTIFY_SRQ_ARM_SN", 3, "arm_sn=3"),
        ("RDMA_NOTIFY_SRQ_PI_INVALID", 1, "pi_invalid=1"),
        ("", 0, "offset=0x40"),
    ))
    cq_rc_ud_db = make_case("cq_rc_ud", 8, (
        ("RDMA_NOTIFY_CQ_CQN", 0x15555, "cqn=0x15555"),
        ("RDMA_NOTIFY_CQ_HOST_ID", 5, "host=5"),
        ("RDMA_NOTIFY_CQ_CI", 0x654321, "ci=0x654321"),
        ("RDMA_NOTIFY_CQ_CI_WRAP", 1, "wrap=1"),
        ("RDMA_NOTIFY_CQ_ARM", 1, "arm=1"),
        ("RDMA_NOTIFY_CQ_ARM_ST", 2, "arm_state=2"),
        ("RDMA_NOTIFY_CQ_ARM_SN", 3, "arm_sn=3"),
        ("RDMA_NOTIFY_CQ_URC", 0, "urc=0"),
        ("RDMA_NOTIFY_CQ_CI_INVALID", 0, ""),
        ("RDMA_NOTIFY_CQ_ARM_INVALID", 0, ""),
        ("", 0, "offset=0x18"),
    ))
    cq_urc_db = make_case("cq_urc", 8, (
        ("RDMA_NOTIFY_CQ_CQN", 0x12345, "cqn=0x12345"),
        ("RDMA_NOTIFY_CQ_HOST_ID", 3, "host=3"),
        ("RDMA_NOTIFY_CQ_URC_SQ_CI", 0x4567, "sq_ci=0x4567"),
        ("RDMA_NOTIFY_CQ_URC_SQ_WRAP", 1, "sq_wrap=1"),
        ("RDMA_NOTIFY_CQ_URC_RQ_CI", 0x2345, "rq_ci=0x2345"),
        ("RDMA_NOTIFY_CQ_URC_RQ_WRAP", 0, "rq_wrap=0"),
        ("RDMA_NOTIFY_CQ_ARM", 1, "arm=1"),
        ("RDMA_NOTIFY_CQ_ARM_ST", 1, "arm_state=1"),
        ("RDMA_NOTIFY_CQ_ARM_SN", 2, "arm_sn=2"),
        ("RDMA_NOTIFY_CQ_URC", 1, "urc=1"),
        ("RDMA_NOTIFY_CQ_CI_INVALID", 0, ""),
        ("RDMA_NOTIFY_CQ_ARM_INVALID", 0, ""),
        ("", 0, "offset=0x18"),
    ))
    ceq_db = make_case("ceq", 8, (
        ("RDMA_NOTIFY_CEQ_CEQN", 0x2AAAAA, "ceqn=0x2aaaaa"),
        ("RDMA_NOTIFY_CEQ_CI", 0x2AAAA, "ci=0x2aaaa"),
        ("RDMA_NOTIFY_CEQ_CI_WRAP", 1, "wrap=1"),
        ("", 0, "offset=0x20"),
    ))
    aeq_db = make_case("aeq", 8, (
        ("RDMA_NOTIFY_AEQ_AEQN", 0xAAA, "aeqn=0xaaa"),
        ("RDMA_NOTIFY_AEQ_CI", 0x15555, "ci=0x15555"),
        ("RDMA_NOTIFY_AEQ_CI_WRAP", 1, "wrap=1"),
        ("", 0, "offset=0x28"),
    ))

    def make_qp_control(name, qpn, dst_port, qp_sn, icos, db_type, offset):
        return make_case(name, 8, (
            ("RDMA_NOTIFY_QP_QPN", qpn, f"qpn={qpn:#x}"),
            ("RDMA_NOTIFY_QP_DST_PORT", dst_port,
             f"dst_port={dst_port}"),
            ("RDMA_NOTIFY_QP_SN", qp_sn, f"qp_sn={qp_sn:#x}"),
            ("RDMA_NOTIFY_QP_ICOS", icos, f"icos={icos}"),
            ("RDMA_NOTIFY_QP_DB_TYPE", db_type,
             f"db_type={db_type:#x}"),
            ("", 0, f"offset={offset:#x}"),
        ))

    rts2sqd_db = make_qp_control(
        "rts2sqd", 0x15555, 11, 0xA6, 5, 0xD, 0x48
    )
    sqd2rts_db = make_qp_control(
        "sqd2rts", 0x15555, 11, 0xA6, 5, 0xE, 0x50
    )
    qp_flush_db = make_qp_control(
        "qp_flush", 0x15555, 11, 0xA6, 0, 0xA, 0x58
    )
    tx_flush_db = make_qp_control(
        "tx_flush", 0x2AAAA, 15, 0, 0, 0xB, 0x08
    )

    return {
        "context": [
            qpc_rc,
            qpc_ud,
            qpc_urc,
            cqc,
            mrt_pbl0,
            mrt_pbl1,
            mrt_pbl2,
            mrt_key0,
            mrt_key1,
            mrt_key2,
            srqc,
            ceqc,
            aeqc,
        ],
        "cmq": [cmq],
        "queue": [
            sqe,
            rqe,
            cqe,
            ceqe,
            aeqe,
        ],
        "doorbell": [
            cmq_db,
            sq_db,
            rq_db,
            srq_pi_db,
            srq_limit_db,
            cq_rc_ud_db,
            cq_urc_db,
            ceq_db,
            aeq_db,
            rts2sqd_db,
            sqd2rts_db,
            qp_flush_db,
            tx_flush_db,
        ],
    }


def render_golden(cases: list[GoldenCase]) -> str:
    lines: list[str] = []
    for index, case in enumerate(cases):
        if parse_input_summary(case.summary) != case.inputs:
            raise ValidationError(f"golden input round-trip mismatch for {case.name}")
        if index:
            lines.append("")
        lines.extend(
            [
                "# xtr_v1-golden-v1",
                f"# case: {case.name}",
                f"# inputs: {case.summary}",
                f"# bytes: {len(case.payload)}",
                " ".join(f"{byte:02x}" for byte in case.payload),
            ]
        )
    return "\n".join(lines) + "\n"


def parse_golden_text(text: str) -> list[GoldenCase]:
    if not text.endswith("\n"):
        raise ValidationError("golden file must end with one newline")
    lines = text.splitlines()
    cases: list[GoldenCase] = []
    names = set()
    index = 0
    while index < len(lines):
        if index:
            if lines[index] != "":
                raise ValidationError("golden cases must have one blank separator")
            index += 1
        if index + 5 > len(lines):
            raise ValidationError("incomplete trailing golden case")
        marker, case_line, inputs_line, bytes_line, payload_line = lines[index:index + 5]
        if marker != "# xtr_v1-golden-v1":
            raise ValidationError("malformed golden format marker")
        case_match = re.fullmatch(r"# case: ([a-z0-9_]+)", case_line)
        inputs_match = re.fullmatch(r"# inputs: (\S+)", inputs_line)
        bytes_match = re.fullmatch(r"# bytes: ([1-9][0-9]*)", bytes_line)
        if not case_match or not inputs_match or not bytes_match:
            raise ValidationError("malformed golden case header")
        name = case_match.group(1)
        if name in names:
            raise ValidationError(f"duplicate golden case name: {name}")
        names.add(name)
        if not re.fullmatch(r"[0-9a-f]{2}(?: [0-9a-f]{2})*", payload_line):
            raise ValidationError(f"malformed hex payload for {name}")
        payload = bytes(int(token, 16) for token in payload_line.split(" "))
        byte_count = int(bytes_match.group(1))
        if len(payload) != byte_count:
            raise ValidationError(
                f"golden case {name} has {len(payload)} payload bytes, expected {byte_count}"
            )
        inputs = parse_input_summary(inputs_match.group(1))
        cases.append(GoldenCase(name, inputs, payload))
        index += 5
    if not cases:
        raise ValidationError("golden file has no cases")
    if render_golden(cases) != text:
        raise ValidationError("golden file is not in canonical form")
    return cases


def validate_context_contract(cases: list[GoldenCase]) -> None:
    def inputs_by_name(case: GoldenCase) -> dict[str, str]:
        return {item.name: item.value for item in case.inputs}

    def numeric_input(case: GoldenCase, name: str) -> int:
        value = inputs_by_name(case).get(name)
        if value is None or re.fullmatch(r"(?:0x[0-9a-f]+|[0-9]+)", value) is None:
            raise ValidationError(f"{case.name} missing numeric input {name}")
        return int(value, 0)

    def field_value(case: GoldenCase, stem: str) -> int:
        reference = REFERENCE_BY_STEM[stem]
        word = int.from_bytes(
            case.payload[
                reference.word_byte_offset:reference.word_byte_offset + 8
            ],
            "big",
        )
        return (word >> reference.lsb) & ((1 << reference.width) - 1)

    expected_names = [
        "qpc_rc_boundary", "qpc_ud_boundary", "qpc_urc_boundary",
        "cqc_create_body_boundary", "mrt_register_pbl0_boundary",
        "mrt_register_pbl1_boundary", "mrt_register_pbl2_boundary",
        "mrt_key_alloc_pbl0_boundary", "mrt_key_alloc_pbl1_boundary",
        "mrt_key_alloc_pbl2_boundary", "srqc_create_body_boundary",
        "ceqc_create_body_boundary", "aeqc_create_body_boundary",
    ]
    if [case.name for case in cases] != expected_names:
        raise ValidationError("context golden case order/name contract drift")
    if [len(case.payload) for case in cases] != [512, 512, 512] + [64] * 10:
        raise ValidationError("context golden byte-count contract drift")

    transport_codes = {"rc": 0, "ud": 3, "urc": 6}
    required_ecn = {"rc": 2, "ud": 0, "urc": 2}
    for case in cases[:3]:
        transport = inputs_by_name(case).get("transport")
        if transport not in transport_codes:
            raise ValidationError(f"{case.name} transport input is unsupported")
        if field_value(case, "RDMA_QPC_SERVICE_TYPE") != transport_codes[transport]:
            raise ValidationError(f"{case.name} transport/service-type mismatch")
        traffic_class = numeric_input(case, "traffic_class")
        if traffic_class > 0xFF:
            raise ValidationError(f"{case.name} traffic class exceeds eight bits")
        icos = field_value(case, "RDMA_QPC_ICOS")
        dscp = field_value(case, "RDMA_QPC_DSCP")
        ecn = field_value(case, "RDMA_QPC_ECN")
        inputs = inputs_by_name(case)
        if (icos != traffic_class >> 5
                or ("icos" in inputs
                    and icos != numeric_input(case, "icos"))):
            raise ValidationError(f"{case.name} traffic class/ICOS mismatch")
        if (dscp != traffic_class >> 2
                or ("dscp" in inputs
                    and dscp != numeric_input(case, "dscp"))):
            raise ValidationError(f"{case.name} traffic class/DSCP mismatch")
        if (ecn != (traffic_class & 0x3)
                or ecn != required_ecn[transport]
                or ("ecn" in inputs
                    and ecn != numeric_input(case, "ecn"))):
            raise ValidationError(f"{case.name} ECN policy/input mismatch")

    mask_keys = [
        "cqc_create", "mrt_register_pbl0", "mrt_register_pbl1",
        "mrt_register_pbl2", "mrt_key_alloc_pbl0", "mrt_key_alloc_pbl1",
        "mrt_key_alloc_pbl2", "srqc_create", "ceqc_create", "aeqc_create",
    ]
    for case, mask_key in zip(cases[3:], mask_keys):
        mask = BODY_MASKS[mask_key]
        for word_index, allowed in enumerate(mask):
            word = int.from_bytes(case.payload[word_index * 8:(word_index + 1) * 8], "big")
            if word & ~allowed:
                raise ValidationError(
                    f"{case.name} has nonzero data outside {mask_key} body mask"
                )
            if allowed & ENVELOPE_MASK[word_index]:
                raise ValidationError(f"{mask_key} body overlaps request envelope")

    semantic_domains = {
        "cqc_create_body_boundary": (
            ("RDMA_CQC_BODY_CQ_ST", "state"),
            ("RDMA_CQC_BODY_CQE_SIZE", "cqe_size"),
            ("RDMA_CQC_BODY_ARM_ST", "arm_state"),
        ),
        "mrt_register_pbl0_boundary": (
            ("RDMA_MRT_BODY_NXT_ST", "state"),
            ("RDMA_MRT_BODY_ST", "state"),
            ("RDMA_MRT_BODY_TYPE", "type"),
            ("RDMA_MRT_BODY_HOST_PG_SIZE", "host_page"),
        ),
        "mrt_register_pbl1_boundary": (
            ("RDMA_MRT_BODY_NXT_ST", "state"),
            ("RDMA_MRT_BODY_ST", "state"),
            ("RDMA_MRT_BODY_TYPE", "type"),
            ("RDMA_MRT_BODY_HOST_PG_SIZE", "host_page"),
        ),
        "mrt_register_pbl2_boundary": (
            ("RDMA_MRT_BODY_NXT_ST", "state"),
            ("RDMA_MRT_BODY_ST", "state"),
            ("RDMA_MRT_BODY_TYPE", "type"),
            ("RDMA_MRT_BODY_HOST_PG_SIZE", "host_page"),
        ),
        "mrt_key_alloc_pbl0_boundary": (
            ("RDMA_MRT_BODY_NXT_ST", "state"),
            ("RDMA_MRT_BODY_ST", "state"),
            ("RDMA_MRT_BODY_TYPE", "type"),
            ("RDMA_MRT_BODY_HOST_PG_SIZE", "host_page"),
        ),
        "mrt_key_alloc_pbl1_boundary": (
            ("RDMA_MRT_BODY_NXT_ST", "state"),
            ("RDMA_MRT_BODY_ST", "state"),
            ("RDMA_MRT_BODY_TYPE", "type"),
            ("RDMA_MRT_BODY_HOST_PG_SIZE", "host_page"),
        ),
        "mrt_key_alloc_pbl2_boundary": (
            ("RDMA_MRT_BODY_NXT_ST", "state"),
            ("RDMA_MRT_BODY_ST", "state"),
            ("RDMA_MRT_BODY_TYPE", "type"),
            ("RDMA_MRT_BODY_HOST_PG_SIZE", "host_page"),
        ),
        "srqc_create_body_boundary": (("RDMA_SRQC_BODY_SRFQ_ST", "state"),),
        "ceqc_create_body_boundary": (("RDMA_EQC_BODY_EQ_ST", "state"),),
        "aeqc_create_body_boundary": (("RDMA_EQC_BODY_EQ_ST", "state"),),
    }
    for case in cases[3:]:
        for stem, input_name in semantic_domains[case.name]:
            actual = field_value(case, stem)
            expected = numeric_input(case, input_name)
            if actual not in {0, 1, 2} or expected not in {0, 1, 2}:
                raise ValidationError(
                    f"{case.name} unsupported semantic value at {stem}"
                )
            if actual != expected:
                raise ValidationError(
                    f"{case.name} semantic {stem}/input {input_name} mismatch"
                )

    rc = cases[0]
    for stem in (
        "RDMA_QPC_RC_TPE_CUR_SQ_PSN", "RDMA_QPC_RC_LAST_READ_PSN",
        "RDMA_QPC_RC_PSN_MAX_RPE", "RDMA_QPC_RC_EPSN_RSP",
        "RDMA_QPC2_RC_EPSN_RSP", "RDMA_QPC_RC_PSN_MAX_TPE",
        "RDMA_QPC_RC_RETRY_FPSN", "RDMA_QPC_RC_RETRY_PSN",
    ):
        if field_value(rc, stem) != numeric_input(rc, "send_psn"):
            raise ValidationError(f"{rc.name} send PSN/input mismatch at {stem}")
    for stem in (
        "RDMA_QPC_RC_EIRQ_PSN_MAX", "RDMA_QPC_EIRQ_CUR_SEND_PSN",
        "RDMA_QPC_EPSN_REQ",
    ):
        if field_value(rc, stem) != numeric_input(rc, "recv_psn"):
            raise ValidationError(f"{rc.name} recv PSN/input mismatch at {stem}")

    ud = cases[1]
    qkey = ((field_value(ud, "RDMA_QPC_UD_QKEY_H") << 24)
            | field_value(ud, "RDMA_QPC_UD_QKEY_L"))
    if qkey != numeric_input(ud, "qkey"):
        raise ValidationError(f"{ud.name} split QKey/input mismatch")
    dest_ip_offset = PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTE_OFFSET"]
    dest_ip_bytes = PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTES"]
    if ud.payload[dest_ip_offset:dest_ip_offset + dest_ip_bytes].hex() != \
            inputs_by_name(ud).get("dest_ip"):
        raise ValidationError(f"{ud.name} destination IP/input mismatch")

    urc = cases[2]
    urc_inputs = inputs_by_name(urc)
    expected_urc_inputs = {
        "transport", "traffic_class", "transport_version",
        "migration_enable", "host_id", "vf_id", "qpn", "stat_index",
        "pkey", "context_backing", "tx_endian_swap", "rx_endian_swap",
        "signature_enable", "read_after_write_fence",
        "atomic_after_atomic_fence", "tx_flow_control", "rx_flow_control",
        "state", "path_mtu_bytes", "qp_sequence", "pd_id", "access",
        "vlan_enable", "ipv6", "tunnel_enable", "lag_enable",
        "forwarding_enable", "destination_vport", "source_address_index",
        "destination_port", "remote_qpn", "destination_mac", "priority",
        "cfi", "vlan_id", "source_vport", "flow_label", "hop_limit",
        "udp_source_port", "destination_ip", "rbsn", "dbsn", "rpsn",
        "dpsn", "rsq_backing", "rdsq_backing", "dsq_backing",
        "rsq_depth", "rdsq_depth", "rdsq_fetch_count", "dsq_fetch_count",
        "rq_sequence_threshold_entries", "sq_completion_threshold_entries",
        "sq_backing", "sq_depth", "sq_mode", "send_cq_id", "recv_cq_id",
        "rq_backing", "rq_depth", "rq_mode",
    }
    optional_derived_inputs = {"icos", "dscp", "ecn"}
    if set(urc_inputs) - optional_derived_inputs != expected_urc_inputs:
        raise ValidationError(f"{urc.name} semantic input contract mismatch")

    direct_urc_fields = (
        ("RDMA_QPC_TVER", "transport_version"),
        ("RDMA_QPC_MIG", "migration_enable"),
        ("RDMA_QPC_HOST_ID", "host_id"),
        ("RDMA_QPC_VF_ID", "vf_id"),
        ("RDMA_QPC_QPN", "qpn"),
        ("RDMA_QPC_STAT_IDX", "stat_index"),
        ("RDMA_QPC_PKEY", "pkey"),
        ("RDMA_QPC_TX_ENDIAN_SWAP", "tx_endian_swap"),
        ("RDMA_QPC_RX_ENDIAN_SWAP", "rx_endian_swap"),
        ("RDMA_QPC_SQ_CE_EN", "signature_enable"),
        ("RDMA_QPC_RA_FENCE", "read_after_write_fence"),
        ("RDMA_QPC_AA_FENCE", "atomic_after_atomic_fence"),
        ("RDMA_QPC_QP_ST", "state"),
        ("RDMA_QPC_QP_SN", "qp_sequence"),
        ("RDMA_QPC_PD_IDX", "pd_id"),
        ("RDMA_QPC_QP_ACCESS_FLAG", "access"),
        ("RDMA_QPC_VLAN", "vlan_enable"),
        ("RDMA_QPC_IPV6", "ipv6"),
        ("RDMA_QPC_TUNNEL", "tunnel_enable"),
        ("RDMA_QPC_LAG", "lag_enable"),
        ("RDMA_QPC_FWD", "forwarding_enable"),
        ("RDMA_QPC_DST_VPORT_ID", "destination_vport"),
        ("RDMA_QPC_SRC_ADDR_IDX", "source_address_index"),
        ("RDMA_QPC_DST_PORT", "destination_port"),
        ("RDMA_QPC_DST_QPN", "remote_qpn"),
        ("RDMA_QPC_DMAC", "destination_mac"),
        ("RDMA_QPC_PRI", "priority"),
        ("RDMA_QPC_CFI", "cfi"),
        ("RDMA_QPC_VLAN_ID", "vlan_id"),
        ("RDMA_QPC_SRC_VPORT_ID", "source_vport"),
        ("RDMA_QPC_FLOW_LABEL", "flow_label"),
        ("RDMA_QPC_HOPLIMIT", "hop_limit"),
        ("RDMA_QPC_CUR_UDP_SPORT", "udp_source_port"),
        ("RDMA_QPC_SQ_OM", "sq_mode"),
        ("RDMA_QPC_SQ_CQN", "send_cq_id"),
        ("RDMA_QPC_RQ_CQN", "recv_cq_id"),
        ("RDMA_QPC_RQ_OM", "rq_mode"),
    )
    for stem, input_name in direct_urc_fields:
        if field_value(urc, stem) != numeric_input(urc, input_name):
            raise ValidationError(
                f"{urc.name} {stem}/input {input_name} mismatch"
            )

    flow_control = field_value(urc, "RDMA_QPC_FC_EN")
    if (flow_control != numeric_input(urc, "tx_flow_control")
            or flow_control != numeric_input(urc, "rx_flow_control")):
        raise ValidationError(f"{urc.name} flow-control input mismatch")

    backing_fields = (
        ("RDMA_QPC_SHADOW_PBA", 9, "context_backing"),
        ("RDMA_QPC_URC_RDSQ_PBA", 12, "rdsq_backing"),
        ("RDMA_QPC_SQ_PBA", 12, "sq_backing"),
        ("RDMA_QPC_RQ_PBA", 12, "rq_backing"),
    )
    for stem, shift, input_name in backing_fields:
        if (field_value(urc, stem) << shift) != numeric_input(urc, input_name):
            raise ValidationError(
                f"{urc.name} {stem}/backing input {input_name} mismatch"
            )

    path_mtu_codes = {1024: 2, 2048: 3, 4096: 4, 8192: 5}
    path_mtu = numeric_input(urc, "path_mtu_bytes")
    if (path_mtu not in path_mtu_codes
            or field_value(urc, "RDMA_QPC_PMTU") != path_mtu_codes[path_mtu]):
        raise ValidationError(f"{urc.name} path MTU/input mismatch")

    dest_ip_offset = PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTE_OFFSET"]
    dest_ip_bytes = PROFILE_VALUES["RDMA_QPC_DEST_IP_BYTES"]
    destination_ip = urc_inputs["destination_ip"]
    if (re.fullmatch(r"[0-9a-f]{32}", destination_ip) is None
            or urc.payload[
                dest_ip_offset:dest_ip_offset + dest_ip_bytes
            ].hex() != destination_ip):
        raise ValidationError(f"{urc.name} destination IP/input mismatch")

    rsq_page = ((field_value(urc, "RDMA_QPC_URC_RSQ_PBA_H") << 48)
                | field_value(urc, "RDMA_QPC_URC_RSQ_PBA_L"))
    dsq_page = ((field_value(urc, "RDMA_QPC_URC_CUR_DSQ_PBA_H") << 12)
                | field_value(urc, "RDMA_QPC_URC_CUR_DSQ_PBA_L"))
    if rsq_page << 12 != numeric_input(urc, "rsq_backing"):
        raise ValidationError(f"{urc.name} split RSQ backing/input mismatch")
    if dsq_page << 12 != numeric_input(urc, "dsq_backing"):
        raise ValidationError(f"{urc.name} split DSQ backing/input mismatch")
    if field_value(urc, "RDMA_QPC_URC_NXT_DSQ_PBA") != dsq_page + 1:
        raise ValidationError(f"{urc.name} derived next DSQ address mismatch")

    def exact_log2(input_name: str) -> int:
        entries = numeric_input(urc, input_name)
        if entries == 0 or entries & (entries - 1):
            raise ValidationError(
                f"{urc.name} input {input_name} is not a power of two"
            )
        return entries.bit_length() - 1

    log2_fields = (
        ("RDMA_QPC_URC_RSQ_SIZE", "rsq_depth"),
        ("RDMA_QPC_URC_RDSQ_SIZE", "rdsq_depth"),
        ("RDMA_QPC_URC_RQ_SE_TH", "rq_sequence_threshold_entries"),
        ("RDMA_QPC_URC_SQ_CE_TH", "sq_completion_threshold_entries"),
        ("RDMA_QPC_SQ_SIZE", "sq_depth"),
        ("RDMA_QPC_RQ_SIZE", "rq_depth"),
    )
    for stem, input_name in log2_fields:
        if field_value(urc, stem) != exact_log2(input_name):
            raise ValidationError(
                f"{urc.name} {stem}/log2 input {input_name} mismatch"
            )

    fetch_fields = (
        ("RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM", "rdsq_fetch_count"),
        ("RDMA_QPC_URC_NXT_DSQ_FETCH_NUM", "dsq_fetch_count"),
    )
    for stem, input_name in fetch_fields:
        if field_value(urc, stem) != numeric_input(urc, input_name):
            raise ValidationError(
                f"{urc.name} {stem}/fetch input {input_name} mismatch"
            )

    mirror_groups = {
        "rbsn": (
            "RDMA_QPC_URC_TX_RBSN", "RDMA_QPC_URC_RX_RBSN",
        ),
        "dbsn": (
            "RDMA_QPC_URC_TX_DBSN", "RDMA_QPC_URC_RX_DBSN",
            "RDMA_QPC_URC_RXED_DBSN",
        ),
        "rpsn": (
            "RDMA_QPC_URC_CUR_TX_RPSN",
            "RDMA_QPC_URC_TPE_RPSN_MAX",
        ),
        "dpsn": (
            "RDMA_QPC_URC_CUR_TX_DPSN",
            "RDMA_QPC_URC_TPE_DPSN_MAX",
        ),
    }
    for input_name, stems in mirror_groups.items():
        owner = numeric_input(urc, input_name)
        if any(field_value(urc, stem) != owner for stem in stems):
            raise ValidationError(
                f"{urc.name} {input_name} sequence mirror mismatch"
            )

    for stem in (
        "RDMA_QPC_URC_RX_SRBSN", "RDMA_QPC_URC_TX_SRBSN",
        "RDMA_QPC_URC_MAX_TX_SRBSN",
    ):
        if field_value(urc, stem) != 0:
            raise ValidationError(f"{urc.name} runtime SRBSN field is nonzero")

    for case in cases[4:10]:
        direct_fields = (
            ("RDMA_MRT_BODY_STAG_IDX", "stag"),
            ("RDMA_MRT_BODY_NXT_ST", "state"),
            ("RDMA_MRT_BODY_STAG_KEY", "key"),
            ("RDMA_MRT_BODY_PD_IDX", "pd"),
            ("RDMA_MRT_BODY_PLD_VF_ID", "payload_vf"),
            ("RDMA_MRT_BODY_PLD_VF_EN", "payload_vf_en"),
            ("RDMA_MRT_BODY_RIGHT", "rights"),
            ("RDMA_MRT_BODY_TYPE", "type"),
            ("RDMA_MRT_BODY_HOST_PG_SIZE", "host_page"),
            ("RDMA_MRT_BODY_PBL_MODE", "pbl"),
            ("RDMA_MRT_BODY_ADDR_MODE", "address_mode"),
            ("RDMA_MRT_BODY_INVALIDATE_EN", "invalidate"),
            ("RDMA_MRT_BODY_ST", "state"),
            ("RDMA_MRT_BODY_LEN", "length"),
            ("RDMA_MRT_BODY_ODP", "odp"),
            ("RDMA_MRT_BODY_INFO_STAG_KEY", "key"),
            ("RDMA_MRT_BODY_START_VA", "start_va"),
            ("RDMA_MRT_BODY_MR_SN", "mr_sn"),
        )
        for stem, input_name in direct_fields:
            if field_value(case, stem) != numeric_input(case, input_name):
                raise ValidationError(
                    f"{case.name} MRT {stem}/input {input_name} mismatch"
                )

        inputs = inputs_by_name(case)
        stag = numeric_input(case, "stag")
        parent = field_value(case, "RDMA_MRT_BODY_PARENT_STAG_IDX")
        pbl = numeric_input(case, "pbl")
        if case.name.startswith("mrt_key_alloc_"):
            if (inputs.get("opcode") != "0x04"
                    or inputs.get("parent") != "self"
                    or parent != stag):
                raise ValidationError("KEY_ALLOC self-parent STAG mismatch")
        elif (inputs.get("opcode") != "0x05"
              or inputs.get("parent") != "0" or parent != 0):
            raise ValidationError("MR_REGISTER parent STAG field must be zero")

        pbl_fields = {
            0: (("RDMA_MRT_BODY_PAYLOAD_PBA0", "pba0"),),
            1: (
                ("RDMA_MRT_BODY_PAYLOAD_PBA0", "pba0"),
                ("RDMA_MRT_BODY_PAYLOAD_PBA1", "pba1"),
            ),
            2: (("RDMA_MRT_BODY_FIRST_PBL_IDX", "first_pbl"),),
        }
        if pbl not in pbl_fields:
            raise ValidationError(f"{case.name} unsupported MRT PBL mode")
        for stem, input_name in pbl_fields[pbl]:
            if field_value(case, stem) != numeric_input(case, input_name):
                raise ValidationError(
                    f"{case.name} MRT {stem}/input {input_name} mismatch"
                )

        expected_inputs = {
            "opcode", "stag", "state", "key", "parent", "pd",
            "payload_vf", "payload_vf_en", "rights", "type", "host_page",
            "pbl", "address_mode", "invalidate", "length", "odp",
            "start_va", "mr_sn",
            *(input_name for _, input_name in pbl_fields[pbl]),
        }
        if set(inputs) != expected_inputs:
            raise ValidationError(f"{case.name} MRT input contract mismatch")

    validate_body_translations(BODY_TRANSLATIONS, FIELD_MAPPINGS)


DOORBELL_CASE_NAMES = (
    "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
    "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
    "tx_flush",
)
DOORBELL_CASE_OFFSETS = (
    0x000, 0x100, 0x010, 0x040, 0x040, 0x018, 0x018, 0x020,
    0x028, 0x048, 0x050, 0x058, 0x008,
)


def validate_doorbell_contract(
    cases: list[GoldenCase], queue_cases: list[GoldenCase]
) -> None:
    if tuple(case.name for case in cases) != DOORBELL_CASE_NAMES:
        raise ValidationError("doorbell golden order/name contract drift")
    if any(len(case.payload) != 8 for case in cases):
        raise ValidationError("doorbell golden payload length contract drift")
    offsets = []
    for case in cases:
        inputs = {item.name: item.value for item in case.inputs}
        offset = inputs.get("offset")
        if offset is None or re.fullmatch(r"(?:0x[0-9a-f]+|[0-9]+)", offset) is None:
            raise ValidationError(f"doorbell {case.name} offset input is invalid")
        offsets.append(int(offset, 0))
    if tuple(offsets) != DOORBELL_CASE_OFFSETS:
        raise ValidationError("doorbell golden offset contract drift")

    sqe = next(
        (case for case in queue_cases if case.name == "sqe_rc_boundary"),
        None,
    )
    if sqe is None or len(sqe.payload) < 8 or cases[1].payload != sqe.payload[:8]:
        raise ValidationError("doorbell SQ payload is not the encoded SQE header")

    canonical = build_golden_cases()["doorbell"]
    for actual, expected in zip(cases, canonical):
        if actual.inputs != expected.inputs:
            raise ValidationError(
                f"doorbell {actual.name} input contract drift"
            )
        if actual.payload != expected.payload:
            raise ValidationError(
                f"doorbell {actual.name} payload contract drift"
            )


def selector_matches(text: str, selector: str) -> bool:
    """功能：判断源码文本是否覆盖 manifest selector 的任一替代项；输入输出及副作用：读取 text 和 selector，返回布尔覆盖结果且不修改输入；失败边界：空 selector 无匹配，glob 仅按符号名匹配，描述性 selector 按转义文本匹配。"""
    macros, enums = parse_c_symbols(text)
    enum_tags = re.findall(r"\benum\s+([A-Za-z_]\w*)\s*\{", text)
    symbols = tuple(macros) + tuple(enums) + tuple(enum_tags)
    for alternative in selector.split("|"):
        if not alternative:
            continue
        if "*" in alternative:
            if any(fnmatch.fnmatchcase(name, alternative) for name in symbols):
                return True
            continue
        if re.search(
            rf"(?<![A-Za-z0-9_]){re.escape(alternative)}(?![A-Za-z0-9_])",
            text,
        ):
            return True
    return False


def validate_source_manifest_sources(
    kernel_root: Path,
    archive_lock: ArchiveLock,
    records: list[SourceManifestRecord],
) -> dict[str, str]:
    """功能：依据 ArchiveLock 与 source manifest 验证冻结源码并读取文本；输入输出及副作用：读取 kernel_root 下记录文件，返回 path 到 UTF-8 文本映射；失败边界：归档身份、同路径摘要、缺失文件、摘要或 selector 漂移以及必需覆盖缺失时抛 ValidationError。"""
    if not records:
        raise ValidationError("source manifest has no entries")
    source_text: dict[str, str] = {}
    path_digests: dict[str, str] = {}
    seen_rows: set[tuple[str, str]] = set()
    for record in records:
        if record.archive_id != archive_lock.archive_id:
            raise ValidationError("source manifest archive identifier mismatch")
        previous_digest = path_digests.setdefault(record.path, record.sha256)
        if previous_digest != record.sha256:
            raise ValidationError(f"source manifest digest mismatch: {record.path}")
        source_path = kernel_root / record.path
        if not source_path.is_file():
            raise ValidationError(f"source file missing: {record.path}")
        actual_digest = hashlib.sha256(source_path.read_bytes()).hexdigest()
        if actual_digest != record.sha256:
            raise ValidationError(f"source digest mismatch: {record.path}")
        try:
            text = source_path.read_text(encoding="utf-8")
        except UnicodeDecodeError as error:
            raise ValidationError(f"source is not UTF-8: {record.path}") from error
        source_text[record.path] = text
        if not selector_matches(text, record.selector):
            raise ValidationError(
                f"source selector matches no locked symbol/text: {record.path}"
            )
        seen_rows.add((record.path, record.selector))
    missing_rows = REQUIRED_MANIFEST_ROWS - seen_rows
    if missing_rows:
        raise ValidationError(f"required manifest rows missing: {sorted(missing_rows)}")
    return source_text


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


def validate(
    kernel_root: Path,
    archive_lock_path: Path,
    source_manifest_path: Path,
) -> None:
    """功能：执行冻结 RDMA 定义、映射和 golden 全量契约校验；输入输出及副作用：读取 kernel_root、ArchiveLock、source manifest 与仓库定义并输出无副作用校验结果；失败边界：任一来源身份、映射、常量、mask 或 golden 漂移抛 ValidationError。"""
    try:
        archive_lock = load_archive_lock(archive_lock_path)
        records = load_source_manifest(source_manifest_path)
    except ContractError as error:
        raise ValidationError(str(error)) from error
    validate_mapping_uniqueness(FIELD_MAPPINGS, VALUE_MAPPINGS, REFERENCE_FIELDS)
    validate_body_translations(BODY_TRANSLATIONS, FIELD_MAPPINGS)
    source_text = validate_source_manifest_sources(kernel_root, archive_lock, records)

    parsed_sources = {path: parse_c_symbols(text) for path, text in source_text.items()}
    validate_access_projections(source_text["rdma_main.h"])
    sv_defs_text = SV_DEFS_PATH.read_text()
    error_values = validate_error_code_mappings(
        ERROR_CODE_MAPPINGS, source_text, sv_defs_text
    )
    canonical_error_codes = canonical_error_code_mappings(
        ERROR_CODE_MAPPINGS, error_values
    )
    validate_error_codec(ERROR_CODEC_PATH.read_text(), canonical_error_codes)
    sv_constants = parse_sv_constants(sv_defs_text)
    validate_profile_constants(sv_constants, PROFILE_VALUES)
    sv_mask_text = SV_MASKS_PATH.read_text()
    validate_sv_mask_api(sv_mask_text)
    sv_masks = parse_sv_masks(sv_mask_text)
    sv_ownership = parse_sv_ownership(sv_mask_text)
    validate_cmq_body_ownership(sv_ownership)
    expected_constants: dict[str, int] = dict(PROFILE_VALUES)
    parsed_fields: dict[str, tuple[str, str, int, int]] = {}
    for mapping in FIELD_MAPPINGS:
        macros, _ = parsed_sources[mapping.path]
        expression = require_unique_expression(macros, mapping.c_symbol, mapping.path)
        lsb, width = parse_field_expression(expression)
        lsb += mapping.lsb_adjust
        if lsb + width > 64:
            raise ValidationError(f"translated field exceeds qword: {mapping.sv_stem}")
        parsed_fields[mapping.sv_stem] = (
            mapping.path,
            mapping.c_symbol,
            lsb,
            width,
        )
        expected_constants[f"{mapping.sv_stem}_WORD_BYTE_OFFSET"] = mapping.word_byte_offset
        expected_constants[f"{mapping.sv_stem}_LSB"] = lsb
        expected_constants[f"{mapping.sv_stem}_WIDTH"] = width
        expected_constants[f"{mapping.sv_stem}_OFFSET"] = mapping.word_byte_offset * 8 + lsb

    validate_reference_fields(REFERENCE_FIELDS, FIELD_MAPPINGS, parsed_fields)

    for mapping in VALUE_MAPPINGS:
        macros, enums = parsed_sources[mapping.path]
        expressions = macros if mapping.c_symbol in macros else enums
        expression = require_unique_expression(expressions, mapping.c_symbol, mapping.path)
        value = parse_value_expression(expression)
        if mapping.subtract_symbol:
            subtract_expression = require_unique_expression(macros, mapping.subtract_symbol, mapping.path)
            value -= parse_value_expression(subtract_expression)
        expected_constants[mapping.sv_name] = value

    validate_required_sv_constants(sv_constants, expected_constants)

    expected_masks = {
        "RDMA_CMQ_ENVELOPE_MASK": ENVELOPE_MASK,
        "RDMA_CQC_CREATE_BODY_MASK": BODY_MASKS["cqc_create"],
        "RDMA_MRT_REGISTER_PBL0_BODY_MASK": BODY_MASKS["mrt_register_pbl0"],
        "RDMA_MRT_REGISTER_PBL1_BODY_MASK": BODY_MASKS["mrt_register_pbl1"],
        "RDMA_MRT_REGISTER_PBL2_BODY_MASK": BODY_MASKS["mrt_register_pbl2"],
        "RDMA_MRT_KEY_ALLOC_PBL0_BODY_MASK": BODY_MASKS["mrt_key_alloc_pbl0"],
        "RDMA_MRT_KEY_ALLOC_PBL1_BODY_MASK": BODY_MASKS["mrt_key_alloc_pbl1"],
        "RDMA_MRT_KEY_ALLOC_PBL2_BODY_MASK": BODY_MASKS["mrt_key_alloc_pbl2"],
        "RDMA_SRQC_CREATE_BODY_MASK": BODY_MASKS["srqc_create"],
        "RDMA_CEQC_CREATE_BODY_MASK": BODY_MASKS["ceqc_create"],
        "RDMA_AEQC_CREATE_BODY_MASK": BODY_MASKS["aeqc_create"],
        "RDMA_SQ_WQE_HEADER_MASK": (0xEFFFFFFFFFFFFFFF,) + (0,) * 7,
        "RDMA_SQ_WQE_INLINE_HEADER_MASK": (0xFFFFFFFFFFFFFFFF,) + (0,) * 7,
        "RDMA_SQ_WQE_RC_BODY_MASK": (0, 0xFFFFFFFFFFFFFFFF, 0xFF00FFFF00000000, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFE00, 0, 0, 0),
        "RDMA_SQ_WQE_RC_INLINE_BODY_MASK": (0, 0xFFFFFFFFFFFFFFFF, 0xFF00FFFF00000000, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF),
        "RDMA_SQ_WQE_RC_DIRECT_SGE_BODY_MASK": (0, 0xFFFFFFFFFFFFFFFF, 0xFF00FFFF00000000, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF),
        "RDMA_SQ_WQE_UD_BODY_MASK": (0, 0xFFFFFFFFFEFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF),
        "RDMA_SQ_WQE_ATOMIC_BODY_MASK": (0, 0xFFFFFFFF, 0xFF00FFFF00000000, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF),
        "RDMA_SQ_WQE_ATOMIC_FAA_BODY_MASK": (0, 0xFFFFFFFF, 0xFF00FFFF00000000, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0),
    }
    if sv_masks != expected_masks:
        raise ValidationError("SV image mask lookup differs from independent reference")

    validate_sq_golden_vectors()

    golden_cases = build_golden_cases()
    for kind, cases in golden_cases.items():
        expected = render_golden(cases).encode()
        golden_path = GOLDEN_DIR / f"{kind}.hex"
        if not golden_path.is_file():
            raise ValidationError(f"golden file missing: {golden_path.relative_to(REPO_ROOT)}")
        actual_bytes = golden_path.read_bytes()
        if actual_bytes != expected:
            raise ValidationError(f"golden byte mismatch: {golden_path.relative_to(REPO_ROOT)}")
        parsed_cases = parse_golden_text(actual_bytes.decode("ascii"))
        if parsed_cases != cases:
            raise ValidationError(f"golden parsed contract mismatch: {golden_path.relative_to(REPO_ROOT)}")
        if kind == "context":
            validate_context_contract(parsed_cases)
        elif kind == "doorbell":
            validate_doorbell_contract(parsed_cases, golden_cases["queue"])


def main(argv: list[str] | None = None) -> int:
    """功能：解析 CLI 并选择 profile-only 或冻结源码契约校验；输入输出及副作用：读取参数、打印 PASS/FAIL 并返回进程状态码；失败边界：冻结模式缺少三个路径参数或任一契约错误时返回 1。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--kernel-root",
        type=Path,
        help="校验冻结硬件资料；省略时只执行内部 profile 命名守卫",
    )
    parser.add_argument("--archive-lock", type=Path)
    parser.add_argument("--source-manifest", type=Path)
    args = parser.parse_args(argv)
    try:
        frozen_args = (args.kernel_root, args.archive_lock, args.source_manifest)
        if args.kernel_root is None and any(value is not None for value in frozen_args[1:]):
            raise ValidationError(
                "frozen-source mode requires --kernel-root, --archive-lock and --source-manifest"
            )
        if args.kernel_root is None:
            validate_profile_names()
            print("rdma profile naming: PASS")
            return 0
        if args.archive_lock is None or args.source_manifest is None:
            raise ValidationError(
                "frozen-source mode requires --kernel-root, --archive-lock and --source-manifest"
            )
        validate(
            args.kernel_root.resolve(),
            args.archive_lock.resolve(),
            args.source_manifest.resolve(),
        )
    except (OSError, ValidationError) as error:
        print(f"rdma definitions: FAIL: {error}", file=sys.stderr)
        return 1
    print("rdma definitions: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
