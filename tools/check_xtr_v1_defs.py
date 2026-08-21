#!/usr/bin/env python3
"""Validate the pinned xtr_v1 hardware definition and golden-vector baseline."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
from pathlib import Path
import re
import subprocess
import sys
from typing import NamedTuple


FIXED_COMMIT = "491faf2ba42627fffd4dd027607299c8bb591ec2"
REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "hw" / "xtr_v1" / "source_manifest.txt"
SV_DEFS_PATH = REPO_ROOT / "src" / "codec" / "xtr_v1" / "rdma_xtr_v1_defs.svh"
GOLDEN_DIR = REPO_ROOT / "hw" / "xtr_v1" / "golden_vectors"

SOURCE_HASHES = {
    "cmq.h": "67f685b23af4f1be64322e56e270546d993db95494ecba253d38afd0780b6e06",
    "qp.h": "c009d546acbd99eb818223fb5cfb348c5423b554c12638d0690aca4a7a35f35d",
    "cq.h": "7d2e2b41e254b9be2f70214bf31cb67bfa5dadbc6eb47124394429ef1d134ee7",
    "wr.h": "c75fb5770ef0ea1af404efbaf95cf79356d1096d331d7cdfcc46ea9ad9b3225b",
    "defs.h": "79e26543d2b9c0942be2819cd505f50118b6cd005a2c8d237dbf8a690963b9ae",
    "eth_header/rdma_register.h": "af957673ba0b561cd27d4bd22394cc0bc56a0173bff66c59176a5a829e0acc13",
    "xtrdma_hw.h": "a917b3080d601bcf62d595383ab6c663c19c2a05c7a1854f481800c97dddc9cb",
    "map.h": "9b532a140458c3f9592b8a1d7531500e820f8f7b1650bf6fd7f41aa1d214c75d",
    "qp.c": "90e91142fbfbd009feda08b1137ef2c584e8da1054f83d6250c1f67cce1a165a",
    "cq.c": "a9db3e9ea40741dbb12735d55820d18c5ade3eea7cd4125d670557972f336cee",
    "wr.c": "df855a9c560fced5dae7e188a540fb1b333fb8746395f88522a185eb265e8230",
    "cmq.c": "0976654707f3ee68a96589121aae22db7a6cefb1eec3454e756ba16e411ab383",
    "event.c": "efdba325776236f3715c4e847d5bae90369263bd29b14192dd6234b498df189b",
}

REQUIRED_MANIFEST_ROWS = {
    ("cmq.h", "xtrdma_cmq_opcode"),
    ("qp.h", "XTRDMA_QPC_*"),
    ("cq.h", "XTRDMA_CMQ_CQC_*|XTRDMA_NOTIFY_CQ_*"),
    ("wr.h", "XTRDMA_SQ_WQE_*|XTRDMA_RQE_*|XTRDMA_CQE_*"),
    ("defs.h", "XTRDMA_CEQE_*|XTRDMA_AEQE_*|EC_*"),
    ("eth_header/rdma_register.h", "RDMA_HID_MAP_TABLE|RDMA_RPE_VFT_TABLE"),
}


class ValidationError(RuntimeError):
    """The checked definition baseline is inconsistent or unsupported."""


class FieldMapping(NamedTuple):
    path: str
    c_symbol: str
    sv_stem: str
    word_byte_offset: int


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


class GoldenCase(NamedTuple):
    name: str
    summary: str
    payload: bytes


# word_byte_offset comes from the fixed driver's set_64bit_val/get_64bit_val
# call sites. The C mask supplies LSB/WIDTH. OFFSET is a logical pre-serialize
# coordinate, not a raw bit number in the big-endian memory byte stream.
FIELD_MAPPINGS = (
    # QPC common/transport-visible fields (qp.c qword stores).
    FieldMapping("qp.h", "XTRDMA_QPC_TVER", "XTR_V1_QPC_TVER", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_MIG", "XTR_V1_QPC_MIG", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_SERVICE_TYPE", "XTR_V1_QPC_SERVICE_TYPE", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_HOST_ID", "XTR_V1_QPC_HOST_ID", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_VF_ID", "XTR_V1_QPC_VF_ID", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_ICOS", "XTR_V1_QPC_ICOS", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_QPN", "XTR_V1_QPC_QPN", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_STAT_IDX", "XTR_V1_QPC_STAT_IDX", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_UD_QKEY_H", "XTR_V1_QPC_UD_QKEY_H", 0),
    FieldMapping("qp.h", "XTRDMA_QPC_UD_QKEY_L", "XTR_V1_QPC_UD_QKEY_L", 8),
    FieldMapping("qp.h", "XTRDMA_QPC_PKEY", "XTR_V1_QPC_PKEY", 8),
    FieldMapping("qp.h", "XTRDMA_QPC_SHADOW_PBA", "XTR_V1_QPC_SHADOW_PBA", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_TX_ENDIAN_SWAP", "XTR_V1_QPC_TX_ENDIAN_SWAP", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_RX_ENDIAN_SWAP", "XTR_V1_QPC_RX_ENDIAN_SWAP", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_CE_EN", "XTR_V1_QPC_SQ_CE_EN", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_FC_EN", "XTR_V1_QPC_FC_EN", 16),
    FieldMapping("qp.h", "XTRDMA_QPC_CC_TYPE", "XTR_V1_QPC_CC_TYPE", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_QP_ST", "XTR_V1_QPC_QP_ST", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_PMTU", "XTR_V1_QPC_PMTU", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_RNR_RETRY_TH", "XTR_V1_QPC_RNR_RETRY_TH", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_QP_SN", "XTR_V1_QPC_QP_SN", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_SRFQ", "XTR_V1_QPC_RC_SRFQ", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_RC_SRFQN", "XTR_V1_QPC_RC_SRFQN", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_PD_IDX", "XTR_V1_QPC_PD_IDX", 24),
    FieldMapping("qp.h", "XTRDMA_QPC_QP_ACCESS_FLAG", "XTR_V1_QPC_QP_ACCESS_FLAG", 32),
    FieldMapping("qp.h", "XTRDMA_QPC_RTO_CODE", "XTR_V1_QPC_RTO_CODE", 40),
    FieldMapping("qp.h", "XTRDMA_QPC_VLAN", "XTR_V1_QPC_VLAN", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_IPV6", "XTR_V1_QPC_IPV6", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_DST_VPORT_ID", "XTR_V1_QPC_DST_VPORT_ID", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_SRC_ADDR_IDX", "XTR_V1_QPC_SRC_ADDR_IDX", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_DST_QPN", "XTR_V1_QPC_DST_QPN", 56),
    FieldMapping("qp.h", "XTRDMA_QPC_DMAC", "XTR_V1_QPC_DMAC", 64),
    FieldMapping("qp.h", "XTRDMA_QPC_VLAN_ID", "XTR_V1_QPC_VLAN_ID", 64),
    FieldMapping("qp.h", "XTRDMA_QPC_FLOW_LABEL", "XTR_V1_QPC_FLOW_LABEL", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_DSCP", "XTR_V1_QPC_DSCP", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_ECN", "XTR_V1_QPC_ECN", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_HOPLIMIT", "XTR_V1_QPC_HOPLIMIT", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_CUR_UDP_SPORT", "XTR_V1_QPC_CUR_UDP_SPORT", 72),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_PD_PBA_OR_PBA", "XTR_V1_QPC_SQ_PBA", 216),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_SIZE", "XTR_V1_QPC_SQ_SIZE", 216),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_OM", "XTR_V1_QPC_SQ_OM", 216),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_CQN", "XTR_V1_QPC_SQ_CQN", 448),
    FieldMapping("qp.h", "XTRDMA_QPC_RQ_CQN", "XTR_V1_QPC_RQ_CQN", 448),
    FieldMapping("qp.h", "XTRDMA_QPC_LOAD_RQ_PI_TH", "XTR_V1_QPC_LOAD_RQ_PI_TH", 480),
    FieldMapping("qp.h", "XTRDMA_QPC_RQ_OR_SRQ_PD_PBA_OR_PBA", "XTR_V1_QPC_RQ_PBA", 496),
    FieldMapping("qp.h", "XTRDMA_QPC_RQ_OR_SRQ_SIZE", "XTR_V1_QPC_RQ_SIZE", 496),
    FieldMapping("qp.h", "XTRDMA_QPC_RQ_OR_SRQ_OM", "XTR_V1_QPC_RQ_OM", 496),
    # CQC context (cq.c stores qwords at bytes 0..48).
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_SD_PBA", "XTR_V1_CQC_CQ_SD_PBA", 0),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_SIZE", "XTR_V1_CQC_CQ_SIZE", 0),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_URC_FLAG", "XTR_V1_CQC_URC_FLAG", 0),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_ST", "XTR_V1_CQC_CQ_ST", 0),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CUR_PBA_VLD", "XTR_V1_CQC_CUR_PBA_VLD", 8),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CUR_CQ_PD_PBA", "XTR_V1_CQC_CUR_CQ_PD_PBA", 8),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_LOAD_CQ_CI_TH", "XTR_V1_CQC_LOAD_CQ_CI_TH", 16),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_OM", "XTR_V1_CQC_CQ_OM", 16),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_NXT_PBA_VLD", "XTR_V1_CQC_NXT_PBA_VLD", 16),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_NXT_CQ_PD_PBA_L", "XTR_V1_CQC_NXT_CQ_PD_PBA_L", 16),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_PI", "XTR_V1_CQC_CQ_PI", 24),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_PI_WRAP", "XTR_V1_CQC_CQ_PI_WRAP", 24),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_LAST_ARM_SN", "XTR_V1_CQC_LAST_ARM_SN", 24),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQE_SIZE", "XTR_V1_CQC_CQE_SIZE", 24),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CEQN", "XTR_V1_CQC_CEQN", 32),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_SHADOW_PA", "XTR_V1_CQC_SHADOW_PA", 40),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_CI", "XTR_V1_CQC_CQ_CI", 48),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_CQ_CI_WRAP", "XTR_V1_CQC_CQ_CI_WRAP", 48),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_ARM_SN", "XTR_V1_CQC_ARM_SN", 48),
    FieldMapping("cq.h", "XTRDMA_CMQ_CQC_ARM_ST", "XTR_V1_CQC_ARM_ST", 48),
    # CMQ request/completion words.
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_VALID", "XTR_V1_CMQ_VALID", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_VFID_OVERRIDE", "XTR_V1_CMQ_VFID_OVERRIDE", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_USE_VFID", "XTR_V1_CMQ_USE_VFID", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_WRAP", "XTR_V1_CMQ_WRAP", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_INDEX", "XTR_V1_CMQ_WQE_INDEX", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQCQ_OPCODE", "XTR_V1_CMQ_OPCODE", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQCQ_CMD_ECODE", "XTR_V1_CMQ_CMD_ECODE", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_QPN", "XTR_V1_CMQ_QPN", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_SQ_CQN", "XTR_V1_CMQ_SQ_CQN", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_SIGN_EN", "XTR_V1_CMQ_SIGN_EN", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_SIGNATURE", "XTR_V1_CMQ_SIGNATURE", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_RQ_CQN", "XTR_V1_CMQ_RQ_CQN", 8),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR", "XTR_V1_CMQ_QPC_BUFFER_ADDR", 24),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_WQE_CQC_WQE_CQN", "XTR_V1_CMQ_CQC_CQN", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQCQ_WQE_SRFQN", "XTR_V1_CMQ_SRFQN", 0),
    # SQE/RQE/CQE fields.
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_QPN", "XTR_V1_SQ_WQE_QPN", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_ICOS", "XTR_V1_SQ_WQE_ICOS", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_QP_SN", "XTR_V1_SQ_WQE_QP_SN", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_OPCODE", "XTR_V1_SQ_WQE_OPCODE", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_DST_PORT", "XTR_V1_SQ_WQE_DST_PORT", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_INDEX", "XTR_V1_SQ_WQE_INDEX", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_WRAP", "XTR_V1_SQ_WQE_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_SIGN_EN", "XTR_V1_SQ_WQE_SIGN_EN", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_SE", "XTR_V1_SQ_WQE_SE", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_FENCE", "XTR_V1_SQ_WQE_FENCE", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_CE", "XTR_V1_SQ_WQE_CE", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_VALID", "XTR_V1_SQ_WQE_VALID", 0),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_SIGNATURE", "XTR_V1_SQ_WQE_SIGNATURE", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_RC_SGE_NUM", "XTR_V1_SQ_WQE_RC_SGE_NUM", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_RC_REMOTE_KEY", "XTR_V1_SQ_WQE_RC_REMOTE_KEY", 16),
    FieldMapping("wr.h", "XTRDMA_SQ_WQE_RC_REMOTE_VA", "XTR_V1_SQ_WQE_RC_REMOTE_VA", 24),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_QPN", "XTR_V1_RQE_QPN", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_QP_SN", "XTR_V1_RQE_QP_SN", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_WQE_OP", "XTR_V1_RQE_OPCODE", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_WQE_IDX", "XTR_V1_RQE_INDEX", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_WQE_IDX_WRAP", "XTR_V1_RQE_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_VALID", "XTR_V1_RQE_VALID", 0),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_TPL", "XTR_V1_RQE_PAYLOAD_LEN", 8),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_SIGNATURE", "XTR_V1_RQE_SIGNATURE", 16),
    FieldMapping("wr.h", "XTRDMA_QP_RQ_SGE_NUM", "XTR_V1_RQE_SGE_NUM", 16),
    FieldMapping("wr.h", "XTRDMA_CQE_POLARITY", "XTR_V1_CQE_POLARITY", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_RQ_CQE", "XTR_V1_CQE_RQ_CQE", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_QP_WQE_WRAP", "XTR_V1_CQE_WQE_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_QP_WQE_INDEX", "XTR_V1_CQE_WQE_INDEX", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_PKT_OPCODE", "XTR_V1_CQE_PKT_OPCODE", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_ECODE", "XTR_V1_CQE_ECODE", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_QPN", "XTR_V1_CQE_QPN", 0),
    FieldMapping("wr.h", "XTRDMA_CQE_IMMDT_DATA_INVLD_KEY", "XTR_V1_CQE_IMMDT_DATA", 8),
    FieldMapping("wr.h", "XTRDMA_CQE_PAYLOAD_LEN", "XTR_V1_CQE_PAYLOAD_LEN", 8),
    FieldMapping("wr.h", "XTRDMA_CQE_SIGNATURE", "XTR_V1_CQE_SIGNATURE", 16),
    # CEQE/AEQE fields (event consumers use qwords at byte 0 and byte 8).
    FieldMapping("defs.h", "XTRDMA_CEQE_WQE_VLD", "XTR_V1_CEQE_VALID", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_QPN", "XTR_V1_CEQE_QPN", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_CQN", "XTR_V1_CEQE_CQN", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_ECODE", "XTR_V1_CEQE_ECODE", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_PKT_OPCODE", "XTR_V1_CEQE_PKT_OPCODE", 0),
    FieldMapping("defs.h", "XTRDMA_CEQE_RC_CQ_PI_WRAP", "XTR_V1_CEQE_CQ_PI_WRAP", 8),
    FieldMapping("defs.h", "XTRDMA_CEQE_RC_CQ_PI", "XTR_V1_CEQE_CQ_PI", 8),
    FieldMapping("defs.h", "XTRDMA_AEQE_WQE_VLD", "XTR_V1_AEQE_VALID", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_QP_ST", "XTR_V1_AEQE_QP_ST", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_PKT_OPCODE", "XTR_V1_AEQE_PKT_OPCODE", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_ECODE", "XTR_V1_AEQE_ECODE", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_QPN", "XTR_V1_AEQE_QPN", 0),
    FieldMapping("defs.h", "XTRDMA_AEQE_QUEUE_WQE_IDX_WARP", "XTR_V1_AEQE_WQE_WRAP", 8),
    FieldMapping("defs.h", "XTRDMA_AEQE_QUEUE_WQE_IDX", "XTR_V1_AEQE_WQE_INDEX", 8),
    # Doorbell payloads.
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_DB_PI", "XTR_V1_CMQ_DB_PI", 0),
    FieldMapping("cmq.h", "XTRDMA_CMQSQ_DB_POL", "XTR_V1_CMQ_DB_POLARITY", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_PI_WRAP", "XTR_V1_NOTIFY_RQ_PI_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_PI", "XTR_V1_NOTIFY_RQ_PI", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_ICOS", "XTR_V1_NOTIFY_RQ_ICOS", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_QPN", "XTR_V1_NOTIFY_RQ_QPN", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_SRFQ_WRAP", "XTR_V1_NOTIFY_SRFQ_WRAP", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_SRFQ_PI", "XTR_V1_NOTIFY_SRFQ_PI", 0),
    FieldMapping("wr.h", "XTRDMA_NOTIFY_SRFQN", "XTR_V1_NOTIFY_SRFQN", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_DB_FLAG", "XTR_V1_NOTIFY_CQ_ARM", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_ST", "XTR_V1_NOTIFY_CQ_ARM_ST", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_SN", "XTR_V1_NOTIFY_CQ_ARM_SN", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_RC_CI_WRAP", "XTR_V1_NOTIFY_CQ_CI_WRAP", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_RC_CI", "XTR_V1_NOTIFY_CQ_CI", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_HOST_ID", "XTR_V1_NOTIFY_CQ_HOST_ID", 0),
    FieldMapping("cq.h", "XTRDMA_NOTIFY_CQ_DB_CQN", "XTR_V1_NOTIFY_CQ_CQN", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_CEQ_CI_WRAP", "XTR_V1_NOTIFY_CEQ_CI_WRAP", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_CEQ_CI", "XTR_V1_NOTIFY_CEQ_CI", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_CEQ_CEQN", "XTR_V1_NOTIFY_CEQ_CEQN", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_AEQ_CI_WRAP", "XTR_V1_NOTIFY_AEQ_CI_WRAP", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_AEQ_CI", "XTR_V1_NOTIFY_AEQ_CI", 0),
    FieldMapping("defs.h", "XTRDMA_NOTIFY_AEQ_AEQN", "XTR_V1_NOTIFY_AEQ_AEQN", 0),
)


VALUE_MAPPINGS = (
    ValueMapping("qp.h", "XTRDMA_QP_CONTEXT_SIZE", "XTR_V1_QPC_BYTES"),
    ValueMapping("cq.h", "XTRDMA_CQ_CONTEXT_SIZE", "XTR_V1_CQC_BYTES"),
    ValueMapping("cmq.h", "XTRDMA_CMQE_SIZE", "XTR_V1_CMQE_BYTES"),
    ValueMapping("wr.h", "XTRDMA_WQE_SIZE", "XTR_V1_WQE_BYTES"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_CEQE_SIZE", "XTR_V1_CEQE_BYTES"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_AEQE_SIZE", "XTR_V1_AEQE_BYTES"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_BAR_OFFSET", "XTR_V1_NOTIFY_WINDOW_OFFSET"),
    ValueMapping("map.h", "XTRDMA_USER_MMAP_DB_LEN", "XTR_V1_NOTIFY_WINDOW_SIZE"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_CMQ_DB", "XTR_V1_DB_CMQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_SQ_DB", "XTR_V1_DB_SQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_RQ_DB", "XTR_V1_DB_RQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_CQ_DB", "XTR_V1_DB_CQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_CEQ_DB", "XTR_V1_DB_CEQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_AEQ_DB", "XTR_V1_DB_AEQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_SRFQ_DB", "XTR_V1_DB_SRFQ_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_RTS2SQD_DB", "XTR_V1_DB_RTS2SQD_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_SQD2RTS_DB", "XTR_V1_DB_SQD2RTS_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_FLUSH_QP_DB", "XTR_V1_DB_QP_FLUSH_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    ValueMapping("xtrdma_hw.h", "XTRDMA_PF_NTFE_FLUSH_TX_DB", "XTR_V1_DB_TX_FLUSH_OFFSET", "XTRDMA_PF_NTFE_BAR_OFFSET"),
    # Explicit enum values needed by the next CMQ/error-code codecs.
    ValueMapping("cmq.h", "XTRDMA_OP_QPC_CREATE", "XTR_V1_OP_QPC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_QPC_MODIFY", "XTR_V1_OP_QPC_MODIFY"),
    ValueMapping("cmq.h", "XTRDMA_OP_QPC_DELETE", "XTR_V1_OP_QPC_DELETE"),
    ValueMapping("cmq.h", "XTRDMA_OP_QPC_QUERY", "XTR_V1_OP_QPC_QUERY"),
    ValueMapping("cmq.h", "XTRDMA_OP_MR_REGISTER", "XTR_V1_OP_MR_REGISTER"),
    ValueMapping("cmq.h", "XTRDMA_OP_MR_DEREGISTER", "XTR_V1_OP_MR_DEREGISTER"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_RESIZE", "XTR_V1_OP_CQC_RESIZE"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_CREATE", "XTR_V1_OP_CQC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_MODIFY", "XTR_V1_OP_CQC_MODIFY"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_DELETE", "XTR_V1_OP_CQC_DELETE"),
    ValueMapping("cmq.h", "XTRDMA_OP_CQC_QUERY", "XTR_V1_OP_CQC_QUERY"),
    ValueMapping("cmq.h", "XTRDMA_OP_CEQC_CREATE", "XTR_V1_OP_CEQC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_AEQC_CREATE", "XTR_V1_OP_AEQC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_QP_FLUSH", "XTR_V1_OP_QP_FLUSH"),
    ValueMapping("cmq.h", "XTRDMA_OP_SRFQC_CREATE", "XTR_V1_OP_SRFQC_CREATE"),
    ValueMapping("cmq.h", "XTRDMA_OP_SRFQC_DELETE", "XTR_V1_OP_SRFQC_DELETE"),
    ValueMapping("cmq.h", "XTRDMA_OP_SRFQC_QUERY", "XTR_V1_OP_SRFQC_QUERY"),
    ValueMapping("cmq.h", "XTRDMA_OP_NOP", "XTR_V1_OP_NOP"),
    ValueMapping("defs.h", "EC_TPE_DB_TYPE_INVLD", "XTR_V1_EC_TPE_DB_TYPE_INVLD"),
    ValueMapping("defs.h", "EC_TPE_SQ_KEY_ERR", "XTR_V1_EC_TPE_SQ_KEY_ERR"),
    ValueMapping("defs.h", "EC_TPE_SQ_WQE_OPCODE_INVLD", "XTR_V1_EC_TPE_SQ_WQE_OPCODE_INVLD"),
    ValueMapping("defs.h", "EC_TME_PKT_KEY_ERR", "XTR_V1_EC_TME_PKT_KEY_ERR"),
    ValueMapping("defs.h", "EC_TDE_DMA_ERR", "XTR_V1_EC_TDE_DMA_ERR"),
    ValueMapping("defs.h", "EC_RPE_REQ_SRFQ_OVER_LIMIT_TH", "XTR_V1_EC_RPE_SRFQ_LIMIT"),
    ValueMapping("defs.h", "EC_RPE_ICRC_ERR_TRIM_PKT", "XTR_V1_EC_RPE_ICRC"),
    ValueMapping("defs.h", "EC_RPE_RX_FLUSH", "XTR_V1_EC_RPE_RX_FLUSH"),
    ValueMapping("defs.h", "EC_RCE_OCC_CQC_ERR", "XTR_V1_EC_RCE_OCC_CQC"),
    ValueMapping("defs.h", "EC_RCE_CQ_FULL", "XTR_V1_EC_RCE_CQ_FULL"),
    ValueMapping("defs.h", "EC_GLB_MBUS_ERR", "XTR_V1_EC_GLB_MBUS"),
)

PROFILE_VALUES = {
    "XTR_V1_RQE_BYTES": 64,
    "XTR_V1_CQE_BYTES": 64,
    "XTR_V1_DB_BYTES": 8,
}


def parse_field_expression(expression: str) -> tuple[int, int]:
    expr = expression.strip()
    bit_match = re.fullmatch(r"BIT(?:_ULL)?\(\s*(\d+)\s*\)", expr)
    if bit_match:
        return int(bit_match.group(1)), 1
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


def parse_sv_constants(text: str) -> dict[str, int]:
    constants: dict[str, int] = {}

    def add(name: str, value: int) -> None:
        if name in constants:
            raise ValidationError(f"duplicate SV constant: {name}")
        constants[name] = value

    pattern = re.compile(
        r"\blocalparam\s+(?:int\s+unsigned|longint\s+unsigned|bit\s*\[[^]]+\])"
        r"\s+(XTR_V1_[A-Za-z0-9_]+)\s*=\s*([^;]+);"
    )
    for match in pattern.finditer(text):
        name = match.group(1)
        add(name, parse_sv_value(match.group(2)))
    field_pattern = re.compile(
        r"`XTR_V1_FIELD\(\s*(XTR_V1_[A-Za-z0-9_]+)\s*,\s*(\d+)\s*,"
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
        for item in block.group(2).split(","):
            clean = strip_c_comments(item).strip()
            if not clean:
                continue
            match = re.fullmatch(r"([A-Za-z_]\w*)\s*=\s*([^\n]+)", clean)
            if match:
                enums.setdefault(match.group(1), []).append(match.group(2).strip())
    return macros, enums


def require_unique_expression(
    symbols: dict[str, list[str]], symbol: str, source_path: str
) -> str:
    expressions = symbols.get(symbol, [])
    if not expressions:
        raise ValidationError(f"mapped symbol {symbol} missing from {source_path}")
    if len(expressions) != 1:
        raise ValidationError(f"mapped symbol {symbol} is duplicated in {source_path}")
    return expressions[0]


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
    ReferenceField("qp.h", "XTRDMA_QPC_TVER", "XTR_V1_QPC_TVER", 0, 62, 2),
    ReferenceField("qp.h", "XTRDMA_QPC_MIG", "XTR_V1_QPC_MIG", 0, 61, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_SERVICE_TYPE", "XTR_V1_QPC_SERVICE_TYPE", 0, 58, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_HOST_ID", "XTR_V1_QPC_HOST_ID", 0, 52, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_VF_ID", "XTR_V1_QPC_VF_ID", 0, 40, 12),
    ReferenceField("qp.h", "XTRDMA_QPC_ICOS", "XTR_V1_QPC_ICOS", 0, 37, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_QPN", "XTR_V1_QPC_QPN", 0, 16, 21),
    ReferenceField("qp.h", "XTRDMA_QPC_STAT_IDX", "XTR_V1_QPC_STAT_IDX", 0, 8, 8),
    ReferenceField("qp.h", "XTRDMA_QPC_UD_QKEY_H", "XTR_V1_QPC_UD_QKEY_H", 0, 0, 8),
    ReferenceField("qp.h", "XTRDMA_QPC_PKEY", "XTR_V1_QPC_PKEY", 8, 0, 16),
    ReferenceField("qp.h", "XTRDMA_QPC_TX_ENDIAN_SWAP", "XTR_V1_QPC_TX_ENDIAN_SWAP", 16, 6, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_RX_ENDIAN_SWAP", "XTR_V1_QPC_RX_ENDIAN_SWAP", 16, 5, 1),
    ReferenceField("qp.h", "XTRDMA_QPC_QP_ST", "XTR_V1_QPC_QP_ST", 24, 56, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_PMTU", "XTR_V1_QPC_PMTU", 24, 48, 3),
    ReferenceField("qp.h", "XTRDMA_QPC_QP_SN", "XTR_V1_QPC_QP_SN", 24, 32, 8),
    ReferenceField("qp.h", "XTRDMA_QPC_PD_IDX", "XTR_V1_QPC_PD_IDX", 24, 0, 16),
    ReferenceField("qp.h", "XTRDMA_QPC_SQ_PD_PBA_OR_PBA", "XTR_V1_QPC_SQ_PBA", 216, 12, 52),
    ReferenceField("qp.h", "XTRDMA_QPC_SQ_SIZE", "XTR_V1_QPC_SQ_SIZE", 216, 8, 4),
    ReferenceField("qp.h", "XTRDMA_QPC_SQ_OM", "XTR_V1_QPC_SQ_OM", 216, 6, 2),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_SD_PBA", "XTR_V1_CQC_CQ_SD_PBA", 0, 0, 52),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_SIZE", "XTR_V1_CQC_CQ_SIZE", 0, 56, 5),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_URC_FLAG", "XTR_V1_CQC_URC_FLAG", 0, 61, 1),
    ReferenceField("cq.h", "XTRDMA_CMQ_CQC_CQ_ST", "XTR_V1_CQC_CQ_ST", 0, 62, 2),
    ReferenceField("cmq.h", "XTRDMA_CMQCQ_OPCODE", "XTR_V1_CMQ_OPCODE", 0, 32, 8),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_QPN", "XTR_V1_CMQ_QPN", 0, 0, 24),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_INDEX", "XTR_V1_CMQ_WQE_INDEX", 0, 40, 5),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_VALID", "XTR_V1_CMQ_VALID", 0, 63, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_VFID_OVERRIDE", "XTR_V1_CMQ_VFID_OVERRIDE", 0, 59, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_USE_VFID", "XTR_V1_CMQ_USE_VFID", 0, 48, 11),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_WRAP", "XTR_V1_CMQ_WRAP", 0, 45, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_SQ_CQN", "XTR_V1_CMQ_SQ_CQN", 8, 43, 21),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_SIGN_EN", "XTR_V1_CMQ_SIGN_EN", 8, 32, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_RQ_CQN", "XTR_V1_CMQ_RQ_CQN", 8, 0, 21),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR", "XTR_V1_CMQ_QPC_BUFFER_ADDR", 24, 9, 55),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_QPN", "XTR_V1_SQ_WQE_QPN", 0, 0, 21),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_OPCODE", "XTR_V1_SQ_WQE_OPCODE", 0, 32, 4),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_INDEX", "XTR_V1_SQ_WQE_INDEX", 0, 40, 15),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_RC_REMOTE_KEY", "XTR_V1_SQ_WQE_RC_REMOTE_KEY", 16, 0, 32),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_ICOS", "XTR_V1_SQ_WQE_ICOS", 0, 21, 3),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_QP_SN", "XTR_V1_SQ_WQE_QP_SN", 0, 24, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_DST_PORT", "XTR_V1_SQ_WQE_DST_PORT", 0, 36, 4),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_WRAP", "XTR_V1_SQ_WQE_WRAP", 0, 55, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_SIGN_EN", "XTR_V1_SQ_WQE_SIGN_EN", 0, 56, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_SE", "XTR_V1_SQ_WQE_SE", 0, 57, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_FENCE", "XTR_V1_SQ_WQE_FENCE", 0, 58, 2),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_CE", "XTR_V1_SQ_WQE_CE", 0, 61, 2),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_VALID", "XTR_V1_SQ_WQE_VALID", 0, 63, 1),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_SIGNATURE", "XTR_V1_SQ_WQE_SIGNATURE", 16, 56, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_RC_SGE_NUM", "XTR_V1_SQ_WQE_RC_SGE_NUM", 16, 48, 8),
    ReferenceField("wr.h", "XTRDMA_SQ_WQE_RC_REMOTE_VA", "XTR_V1_SQ_WQE_RC_REMOTE_VA", 24, 0, 64),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_QPN", "XTR_V1_RQE_QPN", 0, 0, 24),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_WQE_IDX", "XTR_V1_RQE_INDEX", 0, 40, 15),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_TPL", "XTR_V1_RQE_PAYLOAD_LEN", 8, 0, 32),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_QP_SN", "XTR_V1_RQE_QP_SN", 0, 24, 8),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_WQE_OP", "XTR_V1_RQE_OPCODE", 0, 32, 4),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_WQE_IDX_WRAP", "XTR_V1_RQE_WRAP", 0, 55, 1),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_VALID", "XTR_V1_RQE_VALID", 0, 63, 1),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_SIGNATURE", "XTR_V1_RQE_SIGNATURE", 16, 56, 8),
    ReferenceField("wr.h", "XTRDMA_QP_RQ_SGE_NUM", "XTR_V1_RQE_SGE_NUM", 16, 48, 8),
    ReferenceField("wr.h", "XTRDMA_CQE_QPN", "XTR_V1_CQE_QPN", 0, 0, 18),
    ReferenceField("wr.h", "XTRDMA_CQE_QP_WQE_INDEX", "XTR_V1_CQE_WQE_INDEX", 0, 40, 15),
    ReferenceField("wr.h", "XTRDMA_CQE_ECODE", "XTR_V1_CQE_ECODE", 0, 24, 8),
    ReferenceField("wr.h", "XTRDMA_CQE_PAYLOAD_LEN", "XTR_V1_CQE_PAYLOAD_LEN", 8, 0, 32),
    ReferenceField("wr.h", "XTRDMA_CQE_POLARITY", "XTR_V1_CQE_POLARITY", 0, 63, 1),
    ReferenceField("wr.h", "XTRDMA_CQE_RQ_CQE", "XTR_V1_CQE_RQ_CQE", 0, 59, 1),
    ReferenceField("wr.h", "XTRDMA_CQE_QP_WQE_WRAP", "XTR_V1_CQE_WQE_WRAP", 0, 55, 1),
    ReferenceField("wr.h", "XTRDMA_CQE_PKT_OPCODE", "XTR_V1_CQE_PKT_OPCODE", 0, 32, 8),
    ReferenceField("wr.h", "XTRDMA_CQE_IMMDT_DATA_INVLD_KEY", "XTR_V1_CQE_IMMDT_DATA", 8, 32, 32),
    ReferenceField("defs.h", "XTRDMA_CEQE_QPN", "XTR_V1_CEQE_QPN", 0, 40, 21),
    ReferenceField("defs.h", "XTRDMA_CEQE_CQN", "XTR_V1_CEQE_CQN", 0, 16, 21),
    ReferenceField("defs.h", "XTRDMA_CEQE_ECODE", "XTR_V1_CEQE_ECODE", 0, 8, 8),
    ReferenceField("defs.h", "XTRDMA_CEQE_RC_CQ_PI", "XTR_V1_CEQE_CQ_PI", 8, 0, 16),
    ReferenceField("defs.h", "XTRDMA_CEQE_WQE_VLD", "XTR_V1_CEQE_VALID", 0, 63, 1),
    ReferenceField("defs.h", "XTRDMA_CEQE_PKT_OPCODE", "XTR_V1_CEQE_PKT_OPCODE", 0, 0, 8),
    ReferenceField("defs.h", "XTRDMA_CEQE_RC_CQ_PI_WRAP", "XTR_V1_CEQE_CQ_PI_WRAP", 8, 23, 1),
    ReferenceField("defs.h", "XTRDMA_AEQE_QPN", "XTR_V1_AEQE_QPN", 0, 0, 18),
    ReferenceField("defs.h", "XTRDMA_AEQE_QP_ST", "XTR_V1_AEQE_QP_ST", 0, 60, 3),
    ReferenceField("defs.h", "XTRDMA_AEQE_ECODE", "XTR_V1_AEQE_ECODE", 0, 24, 8),
    ReferenceField("defs.h", "XTRDMA_AEQE_QUEUE_WQE_IDX", "XTR_V1_AEQE_WQE_INDEX", 8, 32, 23),
    ReferenceField("defs.h", "XTRDMA_AEQE_WQE_VLD", "XTR_V1_AEQE_VALID", 0, 63, 1),
    ReferenceField("defs.h", "XTRDMA_AEQE_PKT_OPCODE", "XTR_V1_AEQE_PKT_OPCODE", 0, 32, 8),
    ReferenceField("defs.h", "XTRDMA_AEQE_QUEUE_WQE_IDX_WARP", "XTR_V1_AEQE_WQE_WRAP", 8, 55, 1),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_DB_PI", "XTR_V1_CMQ_DB_PI", 0, 32, 5),
    ReferenceField("cmq.h", "XTRDMA_CMQSQ_DB_POL", "XTR_V1_CMQ_DB_POLARITY", 0, 37, 1),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_QPN", "XTR_V1_NOTIFY_RQ_QPN", 0, 0, 21),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_ICOS", "XTR_V1_NOTIFY_RQ_ICOS", 0, 21, 3),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_PI", "XTR_V1_NOTIFY_RQ_PI", 0, 32, 15),
    ReferenceField("wr.h", "XTRDMA_NOTIFY_PI_WRAP", "XTR_V1_NOTIFY_RQ_PI_WRAP", 0, 47, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_CQN", "XTR_V1_NOTIFY_CQ_CQN", 0, 0, 21),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_HOST_ID", "XTR_V1_NOTIFY_CQ_HOST_ID", 0, 21, 3),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_RC_CI", "XTR_V1_NOTIFY_CQ_CI", 0, 24, 23),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_RC_CI_WRAP", "XTR_V1_NOTIFY_CQ_CI_WRAP", 0, 47, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_DB_FLAG", "XTR_V1_NOTIFY_CQ_ARM", 0, 61, 1),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_ST", "XTR_V1_NOTIFY_CQ_ARM_ST", 0, 58, 2),
    ReferenceField("cq.h", "XTRDMA_NOTIFY_CQ_DB_ARM_SN", "XTR_V1_NOTIFY_CQ_ARM_SN", 0, 56, 2),
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
        source_key = (reference.path, reference.c_symbol)
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


def build_golden_cases() -> dict[str, list[GoldenCase]]:
    def make_case(name: str, byte_count: int, inputs) -> GoldenCase:
        image = ReferenceImage(byte_count)
        for stem, value, _ in inputs:
            if stem:
                put_named(image, stem, value)
        summary = ",".join(summary_part for _, _, summary_part in inputs)
        return GoldenCase(name, summary, bytes(image))

    qpc = make_case("qpc_common_boundary", 512, (
        ("XTR_V1_QPC_TVER", 2, "tver=2"),
        ("XTR_V1_QPC_MIG", 1, "mig=1"),
        ("XTR_V1_QPC_SERVICE_TYPE", 3, "service=ud"),
        ("XTR_V1_QPC_HOST_ID", 5, "host=5"),
        ("XTR_V1_QPC_VF_ID", 0xABC, "vf=0xabc"),
        ("XTR_V1_QPC_ICOS", 5, "icos=5"),
        ("XTR_V1_QPC_QPN", 0x15555, "qpn=0x15555"),
        ("XTR_V1_QPC_STAT_IDX", 0xA5, "stat_idx=0xa5"),
        ("XTR_V1_QPC_UD_QKEY_H", 0x5A, "ud_qkey_h=0x5a"),
        ("XTR_V1_QPC_PKEY", 0xBEEF, "pkey=0xbeef"),
        ("XTR_V1_QPC_TX_ENDIAN_SWAP", 1, "tx_endian_swap=1"),
        ("XTR_V1_QPC_RX_ENDIAN_SWAP", 1, "rx_endian_swap=1"),
        ("XTR_V1_QPC_QP_ST", 5, "qp_state=5"),
        ("XTR_V1_QPC_PMTU", 6, "pmtu=6"),
        ("XTR_V1_QPC_QP_SN", 0xC3, "qp_sn=0xc3"),
        ("XTR_V1_QPC_PD_IDX", 0xA55A, "pd_idx=0xa55a"),
        ("XTR_V1_QPC_SQ_PBA", 0x123456789ABCD, "sq_pba=0x123456789abcd"),
        ("XTR_V1_QPC_SQ_SIZE", 0xB, "sq_size=11"),
        ("XTR_V1_QPC_SQ_OM", 2, "sq_om=2"),
    ))

    cqc = make_case("cqc_boundary", 64, (
        ("XTR_V1_CQC_CQ_SD_PBA", 0x123456789ABCD, "sd_pba=0x123456789abcd"),
        ("XTR_V1_CQC_CQ_SIZE", 0x1B, "size=27"),
        ("XTR_V1_CQC_URC_FLAG", 1, "urc=1"),
        ("XTR_V1_CQC_CQ_ST", 2, "state=2"),
    ))

    cmq = make_case("qpc_create", 64, (
        ("XTR_V1_CMQ_OPCODE", 0, "opcode=0"),
        ("XTR_V1_CMQ_QPN", 0x654321, "qpn=0x654321"),
        ("XTR_V1_CMQ_WQE_INDEX", 0x1B, "index=27"),
        ("XTR_V1_CMQ_VALID", 1, "valid=1"),
        ("XTR_V1_CMQ_VFID_OVERRIDE", 1, "vfid_override=1"),
        ("XTR_V1_CMQ_USE_VFID", 0x345, "use_vfid=0x345"),
        ("XTR_V1_CMQ_WRAP", 1, "wrap=1"),
        ("XTR_V1_CMQ_SQ_CQN", 0x15555, "sq_cqn=0x15555"),
        ("XTR_V1_CMQ_SIGN_EN", 1, "sign=1"),
        ("XTR_V1_CMQ_RQ_CQN", 0x0AAAA, "rq_cqn=0xaaaa"),
        ("XTR_V1_CMQ_QPC_BUFFER_ADDR", 0x123456789AB, "buffer=0x123456789ab"),
    ))

    sqe = make_case("sqe_rc_boundary", 64, (
        ("XTR_V1_SQ_WQE_QPN", 0x15555, "qpn=0x15555"),
        ("XTR_V1_SQ_WQE_OPCODE", 0xD, "opcode=13"),
        ("XTR_V1_SQ_WQE_INDEX", 0x4567, "index=0x4567"),
        ("XTR_V1_SQ_WQE_RC_REMOTE_KEY", 0xDEADBEEF, "rkey=0xdeadbeef"),
        ("XTR_V1_SQ_WQE_ICOS", 5, "icos=5"),
        ("XTR_V1_SQ_WQE_QP_SN", 0xA6, "qp_sn=0xa6"),
        ("XTR_V1_SQ_WQE_DST_PORT", 0xB, "dst_port=11"),
        ("XTR_V1_SQ_WQE_WRAP", 1, "wrap=1"),
        ("XTR_V1_SQ_WQE_SIGN_EN", 1, "sign=1"),
        ("XTR_V1_SQ_WQE_SE", 1, "se=1"),
        ("XTR_V1_SQ_WQE_FENCE", 2, "fence=2"),
        ("XTR_V1_SQ_WQE_CE", 2, "ce=2"),
        ("XTR_V1_SQ_WQE_VALID", 1, "valid=1"),
        ("XTR_V1_SQ_WQE_SIGNATURE", 0xC7, "signature=0xc7"),
        ("XTR_V1_SQ_WQE_RC_SGE_NUM", 4, "sge_num=4"),
        ("XTR_V1_SQ_WQE_RC_REMOTE_VA", 0x0123456789ABCDEF,
         "remote_va=0x0123456789abcdef"),
    ))

    rqe = make_case("rqe_boundary", 64, (
        ("XTR_V1_RQE_QPN", 0xABCDE, "qpn=0xabcde"),
        ("XTR_V1_RQE_INDEX", 0x3456, "index=0x3456"),
        ("XTR_V1_RQE_PAYLOAD_LEN", 0x10203040, "payload=0x10203040"),
        ("XTR_V1_RQE_QP_SN", 0x5A, "qp_sn=0x5a"),
        ("XTR_V1_RQE_OPCODE", 9, "opcode=9"),
        ("XTR_V1_RQE_WRAP", 1, "wrap=1"),
        ("XTR_V1_RQE_VALID", 1, "valid=1"),
        ("XTR_V1_RQE_SIGNATURE", 0x96, "signature=0x96"),
        ("XTR_V1_RQE_SGE_NUM", 2, "sge_num=2"),
    ))

    cqe = make_case("cqe_error", 64, (
        ("XTR_V1_CQE_QPN", 0x2AAAA, "qpn=0x2aaaa"),
        ("XTR_V1_CQE_WQE_INDEX", 0x4567, "index=0x4567"),
        ("XTR_V1_CQE_ECODE", 0xF4, "ecode=0xf4"),
        ("XTR_V1_CQE_PAYLOAD_LEN", 0x10203040, "payload=0x10203040"),
        ("XTR_V1_CQE_POLARITY", 1, "polarity=1"),
        ("XTR_V1_CQE_RQ_CQE", 1, "rq_cqe=1"),
        ("XTR_V1_CQE_WQE_WRAP", 1, "wrap=1"),
        ("XTR_V1_CQE_PKT_OPCODE", 0x9A, "packet_opcode=0x9a"),
        ("XTR_V1_CQE_IMMDT_DATA", 0x89ABCDEF, "immediate=0x89abcdef"),
    ))

    ceqe = make_case("ceqe_error", 16, (
        ("XTR_V1_CEQE_QPN", 0x15555, "qpn=0x15555"),
        ("XTR_V1_CEQE_CQN", 0x1AAAAA, "cqn=0x1aaaaa"),
        ("XTR_V1_CEQE_ECODE", 0xF4, "ecode=0xf4"),
        ("XTR_V1_CEQE_CQ_PI", 0xBEEF, "pi=0xbeef"),
        ("XTR_V1_CEQE_VALID", 1, "valid=1"),
        ("XTR_V1_CEQE_PKT_OPCODE", 0x9A, "packet_opcode=0x9a"),
        ("XTR_V1_CEQE_CQ_PI_WRAP", 1, "wrap=1"),
    ))

    aeqe = make_case("aeqe_error", 16, (
        ("XTR_V1_AEQE_QPN", 0x2AAAA, "qpn=0x2aaaa"),
        ("XTR_V1_AEQE_QP_ST", 5, "state=5"),
        ("XTR_V1_AEQE_ECODE", 0xFF, "ecode=0xff"),
        ("XTR_V1_AEQE_WQE_INDEX", 0x654321, "index=0x654321"),
        ("XTR_V1_AEQE_VALID", 1, "valid=1"),
        ("XTR_V1_AEQE_PKT_OPCODE", 0x81, "packet_opcode=0x81"),
        ("XTR_V1_AEQE_WQE_WRAP", 1, "wrap=1"),
    ))

    cmq_db = make_case("cmq_sq", 8, (
        ("XTR_V1_CMQ_DB_PI", 0x1B, "pi=27"),
        ("XTR_V1_CMQ_DB_POLARITY", 1, "polarity=1"),
        ("", 0, "offset=0x0"),
    ))
    rq_db = make_case("rq", 8, (
        ("XTR_V1_NOTIFY_RQ_QPN", 0x15555, "qpn=0x15555"),
        ("XTR_V1_NOTIFY_RQ_ICOS", 5, "icos=5"),
        ("XTR_V1_NOTIFY_RQ_PI", 0x4567, "pi=0x4567"),
        ("XTR_V1_NOTIFY_RQ_PI_WRAP", 1, "wrap=1"),
        ("", 0, "offset=0x10"),
    ))
    cq_db = make_case("cq", 8, (
        ("XTR_V1_NOTIFY_CQ_CQN", 0x15555, "cqn=0x15555"),
        ("XTR_V1_NOTIFY_CQ_HOST_ID", 5, "host=5"),
        ("XTR_V1_NOTIFY_CQ_CI", 0x654321, "ci=0x654321"),
        ("XTR_V1_NOTIFY_CQ_CI_WRAP", 1, "wrap=1"),
        ("XTR_V1_NOTIFY_CQ_ARM", 1, "arm=1"),
        ("XTR_V1_NOTIFY_CQ_ARM_ST", 2, "arm_state=2"),
        ("XTR_V1_NOTIFY_CQ_ARM_SN", 3, "arm_sn=3"),
        ("", 0, "offset=0x18"),
    ))

    return {
        "context": [
            qpc,
            cqc,
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
            rq_db,
            cq_db,
        ],
    }


def render_golden(cases: list[GoldenCase]) -> str:
    lines: list[str] = []
    for index, case in enumerate(cases):
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


def load_manifest() -> list[tuple[str, str, str, str]]:
    rows = []
    for line_number, raw_line in enumerate(MANIFEST_PATH.read_text().splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        columns = line.split()
        if len(columns) != 4:
            raise ValidationError(f"manifest line {line_number} does not have four columns")
        rows.append(tuple(columns))
    if not rows:
        raise ValidationError("source manifest has no entries")
    return rows


def selector_matches(text: str, selector: str) -> bool:
    macros, _ = parse_c_symbols(text)
    for alternative in selector.split("|"):
        if fnmatch.fnmatchcase(alternative, "xtrdma_*opcode"):
            if re.search(rf"\benum\s+{re.escape(alternative)}\s*\{{", text):
                return True
        if any(fnmatch.fnmatchcase(name, alternative) for name in macros):
            return True
        if re.search(rf"\benum\s+{re.escape(alternative)}\s*\{{", text):
            return True
        if "*" not in alternative and re.search(rf"\b{re.escape(alternative)}\b", text):
            return True
    return False


def validate_git_head(kernel_root: Path) -> None:
    probe = subprocess.run(
        ["git", "-C", str(kernel_root), "rev-parse", "--is-inside-work-tree"],
        text=True, capture_output=True, check=False,
    )
    if probe.returncode != 0:
        return
    head = subprocess.run(
        ["git", "-C", str(kernel_root), "rev-parse", "HEAD"],
        text=True, capture_output=True, check=False,
    )
    if head.returncode != 0 or head.stdout.strip() != FIXED_COMMIT:
        actual = head.stdout.strip() or "<unreadable>"
        raise ValidationError(f"kernel HEAD {actual} does not match fixed {FIXED_COMMIT}")


def validate(kernel_root: Path) -> None:
    validate_git_head(kernel_root)
    rows = load_manifest()
    seen_rows = set()
    source_text: dict[str, str] = {}
    for commit, relative_path, selector, manifest_hash in rows:
        if commit != FIXED_COMMIT:
            raise ValidationError(f"manifest commit for {relative_path} is not fixed commit")
        expected_hash = SOURCE_HASHES.get(relative_path)
        if expected_hash is None or manifest_hash != expected_hash:
            raise ValidationError(f"manifest hash for {relative_path} is not the built-in pinned hash")
        source_path = kernel_root / relative_path
        if not source_path.is_file():
            raise ValidationError(f"source file missing: {relative_path}")
        actual_hash = hashlib.sha256(source_path.read_bytes()).hexdigest()
        if actual_hash != expected_hash:
            raise ValidationError(
                f"source hash mismatch for {relative_path}: {actual_hash} != {expected_hash}"
            )
        text = source_path.read_text()
        source_text[relative_path] = text
        if not selector_matches(text, selector):
            raise ValidationError(f"selector {selector} matches nothing in {relative_path}")
        seen_rows.add((relative_path, selector))
    missing_rows = REQUIRED_MANIFEST_ROWS - seen_rows
    if missing_rows:
        raise ValidationError(f"required manifest rows missing: {sorted(missing_rows)}")
    for path in SOURCE_HASHES:
        if path not in source_text:
            raise ValidationError(f"pinned source {path} has no manifest row")

    parsed_sources = {path: parse_c_symbols(text) for path, text in source_text.items()}
    sv_constants = parse_sv_constants(SV_DEFS_PATH.read_text())
    expected_constants: dict[str, int] = dict(PROFILE_VALUES)
    parsed_fields: dict[str, tuple[str, str, int, int]] = {}
    for mapping in FIELD_MAPPINGS:
        macros, _ = parsed_sources[mapping.path]
        expression = require_unique_expression(macros, mapping.c_symbol, mapping.path)
        lsb, width = parse_field_expression(expression)
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

    for name, expected in expected_constants.items():
        if name not in sv_constants:
            raise ValidationError(f"required SV constant missing: {name}")
        if sv_constants[name] != expected:
            raise ValidationError(
                f"SV constant mismatch for {name}: {sv_constants[name]:#x} != {expected:#x}"
            )

    for kind, cases in build_golden_cases().items():
        expected = render_golden(cases).encode()
        golden_path = GOLDEN_DIR / f"{kind}.hex"
        if not golden_path.is_file():
            raise ValidationError(f"golden file missing: {golden_path.relative_to(REPO_ROOT)}")
        if golden_path.read_bytes() != expected:
            raise ValidationError(f"golden byte mismatch: {golden_path.relative_to(REPO_ROOT)}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel-root", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        validate(args.kernel_root.resolve())
    except (OSError, ValidationError) as error:
        print(f"xtr_v1 definitions: FAIL: {error}", file=sys.stderr)
        return 1
    print("xtr_v1 definitions: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
