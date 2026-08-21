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
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_PD_PBA_OR_PBA", "XTR_V1_QPC_SQ_PBA", 416),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_SIZE", "XTR_V1_QPC_SQ_SIZE", 416),
    FieldMapping("qp.h", "XTRDMA_QPC_SQ_OM", "XTR_V1_QPC_SQ_OM", 416),
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


def put_field(image: bytearray, logical_offset: int, width: int, value: int) -> None:
    if width < 1 or width > 64 or value < 0 or value >= (1 << width):
        raise ValidationError(f"value {value:#x} does not fit width {width}")
    word_byte_offset = (logical_offset // 64) * 8
    lsb = logical_offset % 64
    if lsb + width > 64 or word_byte_offset + 8 > len(image):
        raise ValidationError("field crosses a logical qword or image boundary")
    word = int.from_bytes(image[word_byte_offset : word_byte_offset + 8], "big")
    mask = ((1 << width) - 1) << lsb
    if word & mask:
        raise ValidationError("reference fields overlap")
    word |= value << lsb
    image[word_byte_offset : word_byte_offset + 8] = word.to_bytes(8, "big")


FIELD_BY_STEM = {mapping.sv_stem: mapping for mapping in FIELD_MAPPINGS}


def put_named(image: bytearray, stem: str, value: int) -> None:
    mapping = FIELD_BY_STEM[stem]
    # The pinned mask values below are checked against C before golden files pass.
    _, expressions = _REFERENCE_FIELDS[mapping.c_symbol]
    lsb, width = expressions
    put_field(image, mapping.word_byte_offset * 8 + lsb, width, value)


# Independent pinned mask/shift inputs used by build_golden_cases. The checker
# separately proves each tuple against its real C BIT/GENMASK expression.
_REFERENCE_FIELDS = {
    mapping.c_symbol: (mapping.path, (0, 0)) for mapping in FIELD_MAPPINGS
}


def _install_reference_widths() -> None:
    # Keep this explicit and eval-free; it is the reference encoder's audited rule set.
    expressions = {
        "XTRDMA_QPC_TVER": (62, 2), "XTRDMA_QPC_MIG": (61, 1),
        "XTRDMA_QPC_SERVICE_TYPE": (58, 3), "XTRDMA_QPC_HOST_ID": (52, 3),
        "XTRDMA_QPC_VF_ID": (40, 12), "XTRDMA_QPC_ICOS": (37, 3),
        "XTRDMA_QPC_QPN": (16, 21), "XTRDMA_QPC_STAT_IDX": (8, 8),
        "XTRDMA_QPC_UD_QKEY_H": (0, 8), "XTRDMA_QPC_PKEY": (0, 16),
        "XTRDMA_QPC_TX_ENDIAN_SWAP": (6, 1), "XTRDMA_QPC_RX_ENDIAN_SWAP": (5, 1),
        "XTRDMA_QPC_QP_ST": (56, 3), "XTRDMA_QPC_PMTU": (48, 3),
        "XTRDMA_QPC_QP_SN": (32, 8), "XTRDMA_QPC_PD_IDX": (0, 16),
        "XTRDMA_CMQ_CQC_CQ_SD_PBA": (0, 52), "XTRDMA_CMQ_CQC_CQ_SIZE": (56, 5),
        "XTRDMA_CMQ_CQC_URC_FLAG": (61, 1), "XTRDMA_CMQ_CQC_CQ_ST": (62, 2),
        "XTRDMA_CMQSQ_WQE_VALID": (63, 1), "XTRDMA_CMQSQ_VFID_OVERRIDE": (59, 1),
        "XTRDMA_CMQSQ_USE_VFID": (48, 11), "XTRDMA_CMQSQ_WQE_WRAP": (45, 1),
        "XTRDMA_CMQSQ_WQE_INDEX": (40, 5), "XTRDMA_CMQCQ_OPCODE": (32, 8),
        "XTRDMA_CMQSQ_WQE_QPN": (0, 24), "XTRDMA_CMQSQ_WQE_SQ_CQN": (43, 21),
        "XTRDMA_CMQSQ_WQE_SIGN_EN": (32, 1), "XTRDMA_CMQSQ_WQE_RQ_CQN": (0, 21),
        "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR": (9, 55),
        "XTRDMA_SQ_WQE_QPN": (0, 21), "XTRDMA_SQ_WQE_ICOS": (21, 3),
        "XTRDMA_SQ_WQE_QP_SN": (24, 8), "XTRDMA_SQ_WQE_OPCODE": (32, 4),
        "XTRDMA_SQ_WQE_DST_PORT": (36, 4), "XTRDMA_SQ_WQE_INDEX": (40, 15),
        "XTRDMA_SQ_WQE_WRAP": (55, 1), "XTRDMA_SQ_WQE_SIGN_EN": (56, 1),
        "XTRDMA_SQ_WQE_SE": (57, 1), "XTRDMA_SQ_WQE_FENCE": (58, 2),
        "XTRDMA_SQ_WQE_CE": (61, 2), "XTRDMA_SQ_WQE_VALID": (63, 1),
        "XTRDMA_SQ_WQE_SIGNATURE": (56, 8), "XTRDMA_SQ_WQE_RC_SGE_NUM": (48, 8),
        "XTRDMA_SQ_WQE_RC_REMOTE_KEY": (0, 32), "XTRDMA_SQ_WQE_RC_REMOTE_VA": (0, 64),
        "XTRDMA_QP_RQ_QPN": (0, 24), "XTRDMA_QP_RQ_QP_SN": (24, 8),
        "XTRDMA_QP_RQ_WQE_OP": (32, 4), "XTRDMA_QP_RQ_WQE_IDX": (40, 15),
        "XTRDMA_QP_RQ_WQE_IDX_WRAP": (55, 1), "XTRDMA_QP_RQ_VALID": (63, 1),
        "XTRDMA_QP_RQ_TPL": (0, 32), "XTRDMA_QP_RQ_SIGNATURE": (56, 8),
        "XTRDMA_QP_RQ_SGE_NUM": (48, 8), "XTRDMA_CQE_POLARITY": (63, 1),
        "XTRDMA_CQE_RQ_CQE": (59, 1), "XTRDMA_CQE_QP_WQE_WRAP": (55, 1),
        "XTRDMA_CQE_QP_WQE_INDEX": (40, 15), "XTRDMA_CQE_PKT_OPCODE": (32, 8),
        "XTRDMA_CQE_ECODE": (24, 8), "XTRDMA_CQE_QPN": (0, 18),
        "XTRDMA_CQE_IMMDT_DATA_INVLD_KEY": (32, 32), "XTRDMA_CQE_PAYLOAD_LEN": (0, 32),
        "XTRDMA_CEQE_WQE_VLD": (63, 1), "XTRDMA_CEQE_QPN": (40, 21),
        "XTRDMA_CEQE_CQN": (16, 21), "XTRDMA_CEQE_ECODE": (8, 8),
        "XTRDMA_CEQE_PKT_OPCODE": (0, 8), "XTRDMA_CEQE_RC_CQ_PI_WRAP": (23, 1),
        "XTRDMA_CEQE_RC_CQ_PI": (0, 16), "XTRDMA_AEQE_WQE_VLD": (63, 1),
        "XTRDMA_AEQE_QP_ST": (60, 3), "XTRDMA_AEQE_PKT_OPCODE": (32, 8),
        "XTRDMA_AEQE_ECODE": (24, 8), "XTRDMA_AEQE_QPN": (0, 18),
        "XTRDMA_AEQE_QUEUE_WQE_IDX_WARP": (55, 1),
        "XTRDMA_AEQE_QUEUE_WQE_IDX": (32, 23),
        "XTRDMA_CMQSQ_DB_PI": (32, 5), "XTRDMA_CMQSQ_DB_POL": (37, 1),
        "XTRDMA_NOTIFY_PI_WRAP": (47, 1), "XTRDMA_NOTIFY_PI": (32, 15),
        "XTRDMA_NOTIFY_ICOS": (21, 3), "XTRDMA_NOTIFY_QPN": (0, 21),
        "XTRDMA_NOTIFY_SRFQ_WRAP": (47, 1), "XTRDMA_NOTIFY_SRFQ_PI": (32, 15),
        "XTRDMA_NOTIFY_SRFQN": (0, 16), "XTRDMA_NOTIFY_CQ_DB_ARM_DB_FLAG": (61, 1),
        "XTRDMA_NOTIFY_CQ_DB_ARM_ST": (58, 2), "XTRDMA_NOTIFY_CQ_DB_ARM_SN": (56, 2),
        "XTRDMA_NOTIFY_CQ_DB_RC_CI_WRAP": (47, 1), "XTRDMA_NOTIFY_CQ_DB_RC_CI": (24, 23),
        "XTRDMA_NOTIFY_CQ_HOST_ID": (21, 3), "XTRDMA_NOTIFY_CQ_DB_CQN": (0, 21),
        "XTRDMA_NOTIFY_CEQ_CI_WRAP": (50, 1), "XTRDMA_NOTIFY_CEQ_CI": (32, 18),
        "XTRDMA_NOTIFY_CEQ_CEQN": (0, 22), "XTRDMA_NOTIFY_AEQ_CI_WRAP": (50, 1),
        "XTRDMA_NOTIFY_AEQ_CI": (32, 18), "XTRDMA_NOTIFY_AEQ_AEQN": (0, 12),
    }
    for symbol, expression in expressions.items():
        path, _ = _REFERENCE_FIELDS[symbol]
        _REFERENCE_FIELDS[symbol] = (path, expression)


_install_reference_widths()


def build_golden_cases() -> dict[str, list[GoldenCase]]:
    qpc = bytearray(512)
    for stem, value in (
        ("XTR_V1_QPC_TVER", 2), ("XTR_V1_QPC_MIG", 1),
        ("XTR_V1_QPC_SERVICE_TYPE", 3), ("XTR_V1_QPC_HOST_ID", 5),
        ("XTR_V1_QPC_VF_ID", 0xABC), ("XTR_V1_QPC_ICOS", 5),
        ("XTR_V1_QPC_QPN", 0x15555), ("XTR_V1_QPC_STAT_IDX", 0xA5),
        ("XTR_V1_QPC_UD_QKEY_H", 0x5A), ("XTR_V1_QPC_PKEY", 0xBEEF),
        ("XTR_V1_QPC_TX_ENDIAN_SWAP", 1), ("XTR_V1_QPC_RX_ENDIAN_SWAP", 1),
        ("XTR_V1_QPC_QP_ST", 5), ("XTR_V1_QPC_PMTU", 6),
        ("XTR_V1_QPC_QP_SN", 0xC3), ("XTR_V1_QPC_PD_IDX", 0xA55A),
    ):
        put_named(qpc, stem, value)

    cqc = bytearray(64)
    for stem, value in (
        ("XTR_V1_CQC_CQ_SD_PBA", 0x123456789ABCD),
        ("XTR_V1_CQC_CQ_SIZE", 0x1B), ("XTR_V1_CQC_URC_FLAG", 1),
        ("XTR_V1_CQC_CQ_ST", 2),
    ):
        put_named(cqc, stem, value)

    cmq = bytearray(64)
    for stem, value in (
        ("XTR_V1_CMQ_VALID", 1), ("XTR_V1_CMQ_VFID_OVERRIDE", 1),
        ("XTR_V1_CMQ_USE_VFID", 0x345), ("XTR_V1_CMQ_WRAP", 1),
        ("XTR_V1_CMQ_WQE_INDEX", 0x1B), ("XTR_V1_CMQ_OPCODE", 0),
        ("XTR_V1_CMQ_QPN", 0x654321), ("XTR_V1_CMQ_SQ_CQN", 0x15555),
        ("XTR_V1_CMQ_SIGN_EN", 1), ("XTR_V1_CMQ_RQ_CQN", 0x0AAAA),
        ("XTR_V1_CMQ_QPC_BUFFER_ADDR", 0x123456789AB),
    ):
        put_named(cmq, stem, value)

    sqe = bytearray(64)
    for stem, value in (
        ("XTR_V1_SQ_WQE_QPN", 0x15555), ("XTR_V1_SQ_WQE_ICOS", 5),
        ("XTR_V1_SQ_WQE_QP_SN", 0xA6), ("XTR_V1_SQ_WQE_OPCODE", 0xD),
        ("XTR_V1_SQ_WQE_DST_PORT", 0xB), ("XTR_V1_SQ_WQE_INDEX", 0x4567),
        ("XTR_V1_SQ_WQE_WRAP", 1), ("XTR_V1_SQ_WQE_SIGN_EN", 1),
        ("XTR_V1_SQ_WQE_SE", 1), ("XTR_V1_SQ_WQE_FENCE", 2),
        ("XTR_V1_SQ_WQE_CE", 2), ("XTR_V1_SQ_WQE_VALID", 1),
        ("XTR_V1_SQ_WQE_SIGNATURE", 0xC7), ("XTR_V1_SQ_WQE_RC_SGE_NUM", 4),
        ("XTR_V1_SQ_WQE_RC_REMOTE_KEY", 0xDEADBEEF),
        ("XTR_V1_SQ_WQE_RC_REMOTE_VA", 0x0123456789ABCDEF),
    ):
        put_named(sqe, stem, value)

    rqe = bytearray(64)
    for stem, value in (
        ("XTR_V1_RQE_QPN", 0xABCDE), ("XTR_V1_RQE_QP_SN", 0x5A),
        ("XTR_V1_RQE_OPCODE", 9), ("XTR_V1_RQE_INDEX", 0x3456),
        ("XTR_V1_RQE_WRAP", 1), ("XTR_V1_RQE_VALID", 1),
        ("XTR_V1_RQE_PAYLOAD_LEN", 0x10203040),
        ("XTR_V1_RQE_SIGNATURE", 0x96), ("XTR_V1_RQE_SGE_NUM", 2),
    ):
        put_named(rqe, stem, value)

    cqe = bytearray(64)
    for stem, value in (
        ("XTR_V1_CQE_POLARITY", 1), ("XTR_V1_CQE_RQ_CQE", 1),
        ("XTR_V1_CQE_WQE_WRAP", 1), ("XTR_V1_CQE_WQE_INDEX", 0x4567),
        ("XTR_V1_CQE_PKT_OPCODE", 0x9A), ("XTR_V1_CQE_ECODE", 0xF4),
        ("XTR_V1_CQE_QPN", 0x2AAAA), ("XTR_V1_CQE_IMMDT_DATA", 0x89ABCDEF),
        ("XTR_V1_CQE_PAYLOAD_LEN", 0x10203040),
    ):
        put_named(cqe, stem, value)

    ceqe = bytearray(16)
    for stem, value in (
        ("XTR_V1_CEQE_VALID", 1), ("XTR_V1_CEQE_QPN", 0x15555),
        ("XTR_V1_CEQE_CQN", 0x1AAAAA), ("XTR_V1_CEQE_ECODE", 0xF4),
        ("XTR_V1_CEQE_PKT_OPCODE", 0x9A), ("XTR_V1_CEQE_CQ_PI_WRAP", 1),
        ("XTR_V1_CEQE_CQ_PI", 0xBEEF),
    ):
        put_named(ceqe, stem, value)

    aeqe = bytearray(16)
    for stem, value in (
        ("XTR_V1_AEQE_VALID", 1), ("XTR_V1_AEQE_QP_ST", 5),
        ("XTR_V1_AEQE_PKT_OPCODE", 0x81), ("XTR_V1_AEQE_ECODE", 0xFF),
        ("XTR_V1_AEQE_QPN", 0x2AAAA), ("XTR_V1_AEQE_WQE_WRAP", 1),
        ("XTR_V1_AEQE_WQE_INDEX", 0x654321),
    ):
        put_named(aeqe, stem, value)

    cmq_db = bytearray(8)
    put_named(cmq_db, "XTR_V1_CMQ_DB_PI", 0x1B)
    put_named(cmq_db, "XTR_V1_CMQ_DB_POLARITY", 1)
    rq_db = bytearray(8)
    for stem, value in (
        ("XTR_V1_NOTIFY_RQ_PI_WRAP", 1), ("XTR_V1_NOTIFY_RQ_PI", 0x4567),
        ("XTR_V1_NOTIFY_RQ_ICOS", 5), ("XTR_V1_NOTIFY_RQ_QPN", 0x15555),
    ):
        put_named(rq_db, stem, value)
    cq_db = bytearray(8)
    for stem, value in (
        ("XTR_V1_NOTIFY_CQ_ARM", 1), ("XTR_V1_NOTIFY_CQ_ARM_ST", 2),
        ("XTR_V1_NOTIFY_CQ_ARM_SN", 3), ("XTR_V1_NOTIFY_CQ_CI_WRAP", 1),
        ("XTR_V1_NOTIFY_CQ_CI", 0x654321), ("XTR_V1_NOTIFY_CQ_HOST_ID", 5),
        ("XTR_V1_NOTIFY_CQ_CQN", 0x15555),
    ):
        put_named(cq_db, stem, value)

    return {
        "context": [
            GoldenCase("qpc_common_boundary", "tver=2,mig=1,service=ud,host=5,vf=0xabc,icos=5,qpn=0x15555", bytes(qpc)),
            GoldenCase("cqc_boundary", "sd_pba=0x123456789abcd,size=27,urc=1,state=2", bytes(cqc)),
        ],
        "cmq": [GoldenCase("qpc_create", "opcode=0,qpn=0x654321,index=27,valid=1,buffer=0x123456789ab", bytes(cmq))],
        "queue": [
            GoldenCase("sqe_rc_boundary", "qpn=0x15555,opcode=13,index=0x4567,rkey=0xdeadbeef", bytes(sqe)),
            GoldenCase("rqe_boundary", "qpn=0xabcde,index=0x3456,payload=0x10203040", bytes(rqe)),
            GoldenCase("cqe_error", "qpn=0x2aaaa,index=0x4567,ecode=0xf4,payload=0x10203040", bytes(cqe)),
            GoldenCase("ceqe_error", "qpn=0x15555,cqn=0x1aaaaa,ecode=0xf4,pi=0xbeef", bytes(ceqe)),
            GoldenCase("aeqe_error", "qpn=0x2aaaa,state=5,ecode=0xff,index=0x654321", bytes(aeqe)),
        ],
        "doorbell": [
            GoldenCase("cmq_sq", "pi=27,polarity=1,offset=0x0", bytes(cmq_db)),
            GoldenCase("rq", "qpn=0x15555,icos=5,pi=0x4567,wrap=1,offset=0x10", bytes(rq_db)),
            GoldenCase("cq", "cqn=0x15555,host=5,ci=0x654321,wrap=1,arm=1,offset=0x18", bytes(cq_db)),
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
    for mapping in FIELD_MAPPINGS:
        macros, _ = parsed_sources[mapping.path]
        expression = require_unique_expression(macros, mapping.c_symbol, mapping.path)
        lsb, width = parse_field_expression(expression)
        ref_path, ref_field = _REFERENCE_FIELDS[mapping.c_symbol]
        if ref_field != (0, 0) and (ref_path != mapping.path or ref_field != (lsb, width)):
            raise ValidationError(f"reference encoder drift for {mapping.c_symbol}")
        expected_constants[f"{mapping.sv_stem}_WORD_BYTE_OFFSET"] = mapping.word_byte_offset
        expected_constants[f"{mapping.sv_stem}_LSB"] = lsb
        expected_constants[f"{mapping.sv_stem}_WIDTH"] = width
        expected_constants[f"{mapping.sv_stem}_OFFSET"] = mapping.word_byte_offset * 8 + lsb

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
