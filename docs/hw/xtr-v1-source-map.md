# xtr_v1 hardware source map

This baseline is frozen at kernel commit
`491faf2ba42627fffd4dd027607299c8bb591ec2`.  The checker contains immutable
per-file SHA-256 values and rejects a different Git HEAD whenever Git metadata
is available.  It always hashes the actual source bytes, including checkouts
without `.git`.

## Coordinate and endian contract

Image byte 0 is the lowest hardware address.  A definition named `*_OFFSET`
is an **absolute logical bit offset before qword serialization**, calculated as
`*_WORD_BYTE_OFFSET * 8 + *_LSB`.  `*_LSB` is the bit number used by the
driver's `BIT[_ULL]` or `GENMASK[_ULL]` mask in the logical host `u64`.

It is not a directly writable raw memory-byte bit index.  The driver builds a
logical qword with `FIELD_PREP(mask, value)` and `set_64bit_val()` stores it with
`cpu_to_be64`.  The golden-vector generator follows exactly that rule.

**Task 10 codecs MUST use two-stage encoding: logical `FIELD_PREP` from
`LSB/WIDTH`, followed by per-qword big-endian serialization at
`WORD_BYTE_OFFSET`; they MUST NOT treat `OFFSET` as a raw memory-stream bit
index.**

Every mapped field has four SV constants (`WORD_BYTE_OFFSET`, `LSB`, `WIDTH`,
and derived logical `OFFSET`).  `tools/check_xtr_v1_defs.py` is the auditable
C-symbol-to-SV mapping table.  It parses only `BIT[_ULL](n)`,
`GENMASK[_ULL](h,l)`, and explicit integer values; an unknown mapped expression
is fatal and is never evaluated as Python or C.

## Images and golden cases

| Image/case | Bytes | Memory endian | Authoritative source and field group | Golden contract lines and fixed input summary |
|---|---:|---|---|---|
| QPC `qpc_rc_boundary`, `qpc_ud_boundary`, `qpc_urc_boundary` | 512 each | big-endian per 64-bit qword; destination IP remains driver `memcpy` byte order | `qp.h` `XTRDMA_QPC_*`; byte placement from `qp.c:xtrdma_fill_rc_ud_qpc_info` and `xtrdma_fill_urc_qpc_info` | First three `context.hex` cases. Inputs freeze transport-specific backing, traffic class, address-vector, PSN/sequence semantics, thresholds and queue IDs. `ICOS=traffic_class[7:5]`, `DSCP=traffic_class[7:2]`, and `ECN=traffic_class[1:0]`; UD ECN is 0 and RC/URC ECN is 2. |
| CQC `cqc_create_body_boundary` | 64 | big-endian per 64-bit qword | `cq.h` `XTRDMA_CMQ_CQC_*`, `cmq.h` CQN; `cq.c` local stores copied by `cmq.c:xtrdma_sc_cq_create` | Final sparse WQE coordinates: local byte 0..55 becomes byte 8..63. |
| MRT register/key allocate, PBL0/1/2 | 64 each | big-endian per 64-bit qword | `cmq.h` `XTRDMA_CQPSQ_MRT_*`; `mr.c:xtrdma_hwreg_mr`, `cmq.c:xtrdma_sc_alloc_key`, `cmq.c:xtrdma_sc_mr_register` | Six ordered cases freeze KEY_ALLOC (`0x04`) and MR_REGISTER (`0x05`) for PBL0/1/2. KEY_ALLOC byte 16 bits 23:0 repeats its STAG; MR_REGISTER keeps them zero. |
| SRQC `srqc_create_body_boundary` | 64 | big-endian per 64-bit qword | `srq.h` `XTRDMA_SRFQ_CTX_*`; `srq.c:xtrdma_hw_create_srfqc` | Final sparse WQE coordinates: local byte 0..31 becomes byte 16..47. |
| CEQC/AEQC create body boundaries | 64 each | big-endian per 64-bit qword | `event.h` `XTRDMA_EQ_CTX_*`; `event.c:xtrdma_hw_create_eq` | Shared EQC layout at final byte 16..47, with distinct case/opcode/image ownership. |
| CMQ `qpc_create` | 64 | big-endian per 64-bit qword | `cmq.h` common/QPC fields and `xtrdma_cmq_opcode`; byte placement from `cmq.c` | `cmq.hex`: case 2, inputs 3, length 4, payload 5; `opcode=0,qpn=0x654321,index=27,valid=1,vfid_override=1,use_vfid=0x345,wrap=1,sq_cqn=0x15555,sign=1,rq_cqn=0xaaaa,buffer=0x123456789ab` |
| SQE `sqe_rc_boundary` | 64 | big-endian per 64-bit qword | `wr.h` `XTRDMA_SQ_WQE_*`; byte placement from `wr.c` | `queue.hex`: case 2, inputs 3, length 4, payload 5; `qpn=0x15555,opcode=13,index=0x4567,rkey=0xdeadbeef,icos=5,qp_sn=0xa6,dst_port=11,wrap=1,sign=1,se=1,fence=2,ce=2,valid=1,signature=0xc7,sge_num=4,remote_va=0x0123456789abcdef` |
| RQE `rqe_boundary` | 64 | big-endian per 64-bit qword | `wr.h` `XTRDMA_QP_RQ_*`; byte placement from `wr.c` | `queue.hex`: case 8, inputs 9, length 10, payload 11; `qpn=0xabcde,index=0x3456,payload=0x10203040,qp_sn=0x5a,opcode=9,wrap=1,valid=1,signature=0x96,sge_num=2` |
| CQE `cqe_error` | 64 | big-endian per 64-bit qword | `wr.h` `XTRDMA_CQE_*`; read placement from `wr.c` | `queue.hex`: case 14, inputs 15, length 16, payload 17; `qpn=0x2aaaa,index=0x4567,ecode=0xf4,payload=0x10203040,polarity=1,rq_cqe=1,wrap=1,packet_opcode=0x9a,immediate=0x89abcdef` |
| CEQE `ceqe_error` | 16 | big-endian per 64-bit qword | `defs.h` `XTRDMA_CEQE_*`; event placement from `event.c` | `queue.hex`: case 20, inputs 21, length 22, payload 23; `qpn=0x15555,cqn=0x1aaaaa,ecode=0xf4,pi=0xbeef,valid=1,packet_opcode=0x9a,wrap=1` |
| AEQE `aeqe_error` | 16 | big-endian per 64-bit qword | `defs.h` `XTRDMA_AEQE_*`; event placement from `event.c` | `queue.hex`: case 26, inputs 27, length 28, payload 29; `qpn=0x2aaaa,state=5,ecode=0xff,index=0x654321,valid=1,packet_opcode=0x81,wrap=1` |
| CMQ SQ doorbell `cmq_sq` | 8 | big-endian 64-bit payload | `cmq.h` `XTRDMA_CMQSQ_DB_*`; register offset from `xtrdma_hw.h` | `doorbell.hex`: case 2, inputs 3, length 4, payload 5; `pi=27,polarity=1,offset=0x0` |
| SQ doorbell `sq` | 8 | exact big-endian qword from encoded SQE | `wr.h` `XTRDMA_SQ_WQE_*`; register offset from `xtrdma_hw.h` | `doorbell.hex`: case 8; byte-for-byte equal to `sqe_rc_boundary[0:8]`; `offset=0x100` |
| RQ doorbell `rq` | 8 | big-endian 64-bit payload | `wr.h` `XTRDMA_NOTIFY_*`; register offset from `xtrdma_hw.h` | `doorbell.hex`: case 14; `qpn=0x15555,icos=5,pi=0x4567,wrap=1,offset=0x10` |
| SRQ PI doorbell `srq_pi` | 8 | big-endian 64-bit payload | `wr.h` `XTRDMA_NOTIFY_SRFQ_*`, `XTRDMA_SRFQ_LIMIT_INVLD` | `doorbell.hex`: case 20; `srqn=0xa55a,pi=0x4567,wrap=1,limit_invalid=1,offset=0x40` |
| SRQ limit doorbell `srq_limit` | 8 | big-endian 64-bit payload | `defs.h` `XTRDMA_SRFQ_PI_INVLD`, `XTRDMA_SRFQ_LIMIT_TH`, `XTRDMA_SRFQ_ARM_SN` | `doorbell.hex`: case 26; `srqn=0xa55a,limit=0x2aaa,arm_sn=3,pi_invalid=1,offset=0x40` |
| RC/UD CQ doorbell `cq_rc_ud` | 8 | big-endian 64-bit payload | `cq.h` `XTRDMA_NOTIFY_CQ_*` RC fields | `doorbell.hex`: case 32; `cqn=0x15555,host=5,ci=0x654321,wrap=1,arm=1,arm_state=2,arm_sn=3,urc=0,offset=0x18` |
| URC CQ doorbell `cq_urc` | 8 | big-endian 64-bit payload | `cq.h` `XTRDMA_NOTIFY_CQ_*` URC fields | `doorbell.hex`: case 38; `cqn=0x12345,host=3,sq_ci=0x4567,sq_wrap=1,rq_ci=0x2345,rq_wrap=0,arm=1,arm_state=1,arm_sn=2,urc=1,offset=0x18` |
| CEQ doorbell `ceq` | 8 | big-endian 64-bit payload | `defs.h` `XTRDMA_NOTIFY_CEQ_*` | `doorbell.hex`: case 44; `ceqn=0x2aaaaa,ci=0x2aaaa,wrap=1,offset=0x20` |
| AEQ doorbell `aeq` | 8 | big-endian 64-bit payload | `defs.h` `XTRDMA_NOTIFY_AEQ_*` | `doorbell.hex`: case 50; `aeqn=0xaaa,ci=0x15555,wrap=1,offset=0x28` |
| QP transition doorbell `rts2sqd` | 8 | big-endian 64-bit payload | `qp.h` shared QP-control layout and `XTRDMA_DB_RTS2SQD` | `doorbell.hex`: case 56; `qpn=0x15555,dst_port=11,qp_sn=0xa6,icos=5,db_type=0xd,offset=0x48` |
| QP transition doorbell `sqd2rts` | 8 | big-endian 64-bit payload | `qp.h` shared QP-control layout and `XTRDMA_DB_SQD2RTS` | `doorbell.hex`: case 62; `qpn=0x15555,dst_port=11,qp_sn=0xa6,icos=5,db_type=0xe,offset=0x50` |
| QP flush doorbell `qp_flush` | 8 | big-endian 64-bit payload | `qp.h` shared QP-control layout and `XTRDMA_DB_QP_FLUSH` | `doorbell.hex`: case 68; `qpn=0x15555,dst_port=11,qp_sn=0xa6,icos=0,db_type=0xa,offset=0x58` |
| TX flush doorbell `tx_flush` | 8 | big-endian 64-bit payload | `qp.h` shared QP-control layout, `XTRDMA_DB_TX_FLUSH`; `eth_header/register.h` `QSCH_G2P_DPORT_NODE_MODE` | `doorbell.hex`: case 74; `qpn=0x2aaaa,dst_port=15,qp_sn=0,icos=0,db_type=0xb,offset=0x8` |

The `.hex` grammar is stable: marker, case, inputs, byte count, then one
space-separated lowercase hex byte line.  Multiple cases are separated by one
blank line.  The checker independently regenerates the complete file and
requires byte-for-byte equality. `context.hex` contains exactly 11 cases in the
order listed above: three 512-byte QPC images followed by eight 64-byte sparse
bodies. Both the Python and SystemVerilog readers reject duplicate names,
malformed/truncated/extra bytes, and incomplete trailing cases. The SV reader
parses into a private queue and publishes no cases unless the complete file is
valid.

### Delivered context-to-CMQ layers

Standalone QPC images are context artifacts, not sparse CMQ bodies.  Their
registry keys and transport masks select the codec that authors the full
512-byte context used as the QPC create signature source.

| Standalone QPC golden case | Bytes / alignment / endian | Source functions | Codec registry key | Mask owner |
|---|---|---|---|---|
| `qpc_rc_boundary` | 512 / 512 / big-endian per qword | `rdma_xtr_v1_qpc_rc_codec::encode_extension`, `rdma_xtr_v1_qpc_codec_base::{encode,decode,serialized_equal}` | `xtr_v1\|1\|qpc\|rc\|00` | RC coordinates admitted by `qpc_allowed_mask(RDMA_TRANSPORT_RC, ...)`; no CMQ envelope ownership |
| `qpc_ud_boundary` | 512 / 512 / big-endian per qword | `rdma_xtr_v1_qpc_ud_codec::encode_extension`, `rdma_xtr_v1_qpc_codec_base::{encode,decode,serialized_equal}` | `xtr_v1\|1\|qpc\|ud\|00` | UD coordinates admitted by `qpc_allowed_mask(RDMA_TRANSPORT_UD, ...)`; no CMQ envelope ownership |
| `qpc_urc_boundary` | 512 / 512 / big-endian per qword | `rdma_xtr_v1_qpc_urc_codec::encode_extension`, `rdma_xtr_v1_qpc_codec_base::{encode,decode,serialized_equal}` | `xtr_v1\|1\|qpc\|urc\|00` | URC coordinates admitted by `qpc_allowed_mask(RDMA_TRANSPORT_URC, ...)`; no CMQ envelope ownership |

The ten sparse bodies retain final CMQ SQE byte coordinates. Each body is
64-byte aligned and its mask is disjoint from the request envelope.

| Sparse-body golden case | Bytes / alignment / endian | Source functions | Codec registry key | Mask owner |
|---|---|---|---|---|
| `cqc_create_body_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_cqc_create_body_codec::{encode_body,decode_body}` through `rdma_xtr_v1_context_body_codec_base::{encode,decode,serialized_equal}` | `xtr_v1\|2\|cqc\|create\|0c` | `XTR_V1_CQC_CREATE_BODY_MASK` |
| `mrt_key_alloc_pbl0_boundary`, `mrt_key_alloc_pbl1_boundary`, `mrt_key_alloc_pbl2_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_mrt_key_alloc_body_codec::{encode_body,decode_body}` through `rdma_xtr_v1_mrt_body_codec_base::{encode_body,decode_body}` | `xtr_v1\|3\|mrt\|key_alloc\|04` | exact `XTR_V1_MRT_KEY_ALLOC_PBL{0,1,2}_BODY_MASK` selected by PBL mode |
| `mrt_register_pbl0_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_mrt_register_body_codec::{encode_body,decode_body}` through `rdma_xtr_v1_mrt_body_codec_base::{encode_body,decode_body}` | `xtr_v1\|3\|mrt\|register\|05` | `XTR_V1_MRT_REGISTER_PBL0_BODY_MASK` |
| `mrt_register_pbl1_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_mrt_register_body_codec::{encode_body,decode_body}` through `rdma_xtr_v1_mrt_body_codec_base::{encode_body,decode_body}` | `xtr_v1\|3\|mrt\|register\|05` | `XTR_V1_MRT_REGISTER_PBL1_BODY_MASK` |
| `mrt_register_pbl2_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_mrt_register_body_codec::{encode_body,decode_body}` through `rdma_xtr_v1_mrt_body_codec_base::{encode_body,decode_body}` | `xtr_v1\|3\|mrt\|register\|05` | `XTR_V1_MRT_REGISTER_PBL2_BODY_MASK` |
| `srqc_create_body_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_srqc_create_body_codec::{encode_body,decode_body}` through `rdma_xtr_v1_context_body_codec_base` | `xtr_v1\|4\|srqc\|create\|35` | `XTR_V1_SRQC_CREATE_BODY_MASK` |
| `ceqc_create_body_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_ceqc_create_body_codec::{encode_body,decode_body}` through `rdma_xtr_v1_context_body_codec_base` | `xtr_v1\|5\|ceqc\|create\|10` | `XTR_V1_CEQC_CREATE_BODY_MASK` |
| `aeqc_create_body_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_aeqc_create_body_codec::{encode_body,decode_body}` through `rdma_xtr_v1_context_body_codec_base` | `xtr_v1\|6\|aeqc\|create\|14` | `XTR_V1_AEQC_CREATE_BODY_MASK` |

Final create/register SQEs are checked compositions.  In every row the request
envelope owns qword-0 mask `8fff3fff00000000` and no bits in qwords 1..7;
the listed body mask owns the remaining admitted fields.  The composer mints
the registered body with `rdma_xtr_v1_cmq_request_composer::build_body`, merges
it with `compose_request`, and the response is admitted by
`rdma_xtr_v1_cmq_completion_codec::decode_completion`.

| Final CMQ SQE context source | Bytes / alignment / endian | Source functions | CMQ registry key | Body mask owner |
|---|---|---|---|---|
| `qpc_rc_boundary`, `qpc_ud_boundary`, `qpc_urc_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_cmq_request_composer::{build_body,compose_request}`, `rdma_xtr_v1_cmq_completion_codec::decode_completion` | body registry opcode `00`, input `RDMA_IMAGE_CMQ_SQE` | `XTR_V1_QPC_CREATE_BODY_OWNERSHIP`; the composer owns the checksum signature while the 512-byte QPC remains standalone |
| `cqc_create_body_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_cmq_request_composer::{build_body,compose_request}`, `rdma_xtr_v1_cmq_completion_codec::decode_completion` | body registry opcode `0c`, input `RDMA_IMAGE_CQC` | `XTR_V1_CQC_CREATE_BODY_MASK` |
| `mrt_key_alloc_pbl0_boundary`, `mrt_key_alloc_pbl1_boundary`, `mrt_key_alloc_pbl2_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_cmq_request_composer::{build_body,compose_request}`, `rdma_xtr_v1_cmq_completion_codec::decode_completion` | body registry opcode `04`, input `RDMA_IMAGE_MRT` | `XTR_V1_MRT_KEY_ALLOC_BODY_OWNERSHIP`; exact PBL0/PBL1/PBL2 mask is authenticated by the context codec |
| `mrt_register_pbl0_boundary`, `mrt_register_pbl1_boundary`, `mrt_register_pbl2_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_cmq_request_composer::{build_body,compose_request}`, `rdma_xtr_v1_cmq_completion_codec::decode_completion` | body registry opcode `05`, input `RDMA_IMAGE_MRT` | exact PBL0/PBL1/PBL2 register mask selected by the authenticated body |
| `srqc_create_body_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_cmq_request_composer::{build_body,compose_request}`, `rdma_xtr_v1_cmq_completion_codec::decode_completion` | body registry opcode `35`, input `RDMA_IMAGE_SRQC` | `XTR_V1_SRQC_CREATE_BODY_MASK` |
| `ceqc_create_body_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_cmq_request_composer::{build_body,compose_request}`, `rdma_xtr_v1_cmq_completion_codec::decode_completion` | body registry opcode `10`, input `RDMA_IMAGE_CEQC` | `XTR_V1_CEQC_CREATE_BODY_MASK` |
| `aeqc_create_body_boundary` | 64 / 64 / big-endian per qword | `rdma_xtr_v1_cmq_request_composer::{build_body,compose_request}`, `rdma_xtr_v1_cmq_completion_codec::decode_completion` | body registry opcode `14`, input `RDMA_IMAGE_AEQC` | `XTR_V1_AEQC_CREATE_BODY_MASK` |

KEY_ALLOC opcode `04` is the ordinary MR allocation path for PBL0/PBL1/PBL2
and writes a self-parent STAG (`parent_stag_idx == stag_idx`). MR_REGISTER
opcode `05` also carries PBL0/PBL1/PBL2 layouts but writes
`parent_stag_idx == 0`.

### Canonical URC create/modify image

`qpc_urc_boundary` is the canonical URC create/modify semantic image. Its
summary records model units rather than independent hardware mirror values:
queue backings are unshifted byte addresses, queue depths and completion/
sequence thresholds are entry counts, and RDSQ/DSQ fetch values are counts.
The reference encoder performs the page-number and exact-log2 projections.

The sequence fields have one semantic owner per mirror group. `rbsn` supplies
TX/RX RBSN, `dbsn` supplies TX/RX/RXED DBSN, `rpsn` supplies current/TPE-max
RPSN, and `dpsn` supplies current/TPE-max DPSN. `RX_SRBSN`, `TX_SRBSN`, and
`MAX_TX_SRBSN` are runtime state without create-model owners; the canonical
create/modify image explicitly writes all three as zero. The Python reference
image's occupancy tracks independent coordinate coverage and does not define a
future codec create mask.

Two URC coordinates omitted from the earlier transcription are now frozen:

| Fixed C symbol | SV stem | word byte | LSB | width | logical offset |
|---|---|---:|---:|---:|---:|
| `XTRDMA_QPC_URC_RSQ_SIZE` | `XTR_V1_QPC_URC_RSQ_SIZE` | 24 | 59 | 3 | 251 |
| `XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM` | `XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM` | 224 | 16 | 6 | 1808 |

The definitions checker independently parses each mask from the fixed
`qp.h`, compares it with the separately transcribed reference coordinates,
and then requires the exact generated byte/LSB/width/offset constants in the
SV definitions. A drift in any of those three sources is fatal.

## Request envelope and sparse-body ownership

The fixed CMQ request envelope owns qword 0 mask `8fff3fff00000000`; qwords
1..7 are zero. The immutable lookup in
`rdma_xtr_v1_image_masks.svh` supplies distinct masks for CQC create, MRT
register PBL0/PBL1/PBL2, MRT key-allocate PBL0, SRQC create, CEQC create and
AEQC create. Every body mask is disjoint from the envelope, and each golden
payload is zero outside its selected body mask. The checker holds an
independent copy of these values rather than deriving expected ownership from
the SV file.

`XTR_V1_HW_VERSION` is fixed to 1. The opcode baseline additionally freezes
KEY_ALLOC `0x04`, OCC_FLUSH `0x0a`, CEQC delete/query `0x12/0x13`, AEQC
delete/query `0x16/0x17`, and TQ_FLUSH `0x20`. CMQ completion coordinates are
kept separate from request-body coordinates.

`XTRDMA_OP_TQ_FLUSH (0x20)` is exclusively a CMQ command. It is not the
notify-window write at relative offset `0x008`; that MMIO register carries the
distinct TX-flush doorbell with codec-owned type `XTRDMA_DB_TX_FLUSH (0xB)`.

The context value baseline also freezes allocation modes direct/indirect/huge/
L3-indirect as `0/1/2/3`; MR VA/zero-based addressing as `0/1`; MR
invalid/free/valid as `0/1/2`; 4KiB/2MiB/1GiB pages and PBL0/PBL1/PBL2 as
`0/1/2`; and MR/MW-type1/MW-type2B as `0/1/2`. CQC, SRQC, and EQC
invalid/valid/error states are `0/1/2`, and CQC arm states are `0/1/2`.
Context body goldens use only these supported values (including CQE-size index
`2`) so Task 10 can round-trip them through the frozen semantic mappings.
Hardware RDMA rights are independent
bits local-write `0x01`, remote-read `0x02`, remote-write `0x04`, MW-bind
`0x08`, and remote-atomic `0x10`; the pinned `xtrdma_get_access` projection
also freezes the rule that remote-write or remote-atomic implies local-write.

## Other pinned groups

- QPC is 512 bytes (`XTRDMA_QP_CONTEXT_SIZE`), CQC is 64 bytes
  (`XTRDMA_CQ_CONTEXT_SIZE`), and CMQE/WQE are 64 bytes.
- The QPC destination-IP byte range is independently frozen and checked as
  `XTR_V1_QPC_DEST_IP_BYTE_OFFSET=80` and `XTR_V1_QPC_DEST_IP_BYTES=16`;
  golden construction and validation both consume that profile metadata.
- CEQE and AEQE are 16 bytes.  The frozen queue profile selects a 64-byte CQE.
- `defs.h` supplies CEQE/AEQE fields and the complete 133-symbol `EC_*`
  hardware error-code set.  `wr.h` supplies all 10 genuine
  `XTRDMA_CQE_ECODE_*` value symbols; the mask-only `XTRDMA_CQE_ECODE` field
  is excluded.  The checker discovers these identities from the pinned
  sources and requires an exact 143-row source-to-SV mapping, with an 8-bit
  SV constant independently checked against every C value.
- Those 143 identities encode 138 values.  The only permitted aliases are
  `0x08`, `0x76`, `0x78`, `0x8f`, and `0xb9`, each shared by one `defs.h` and
  one `wr.h` identity.  Symbolic lookup uses the `defs.h` identity for those
  aliases and the `wr.h` identity for wr-only values such as `0xf0`.
  CMQ completion `0x00` remains an explicit profile success symbol rather
  than being mislabeled as the wr.h TX-request-normal identity.  The checker
  rejects missing, extra, duplicate, value-drifted, or non-8-bit mappings,
  symbolic string/constant drift, unexpected aliases, and raw literals for
  every source-known code consumed by the error codec.
- `xtrdma_hw.h` supplies every notify-register address.  SV doorbell offsets
  are relative to `XTRDMA_PF_NTFE_BAR_OFFSET`, so they can be added to a
  Function binding's `notify_base` without adding `0x2000` twice.
- `map.h` supplies the 8192-byte userspace doorbell mapping.  Thus the notify
  BAR window offset and size are both `0x2000`.
- `eth_header/rdma_register.h` pins `RDMA_HID_MAP_TABLE` and
  `RDMA_RPE_VFT_TABLE` provenance for later Function-table work; Task 9 does
  not infer their C bitfield layout from compiler-dependent struct packing.
- `eth_header/register.h` independently pins the TX-flush fixed destination
  port `QSCH_G2P_DPORT_NODE_MODE=15`.
- `alloc.h`, `mr.h`, `mr.c`, and `rdma_main.h` pin object mode, MR/PBL layout,
  the ordinary MR KEY_ALLOC projection, and access-right normalization.
- `srq.h`/`srq.c` and `event.h`/`event.c` pin the SRQC and EQC local layouts and
  their `+16` final-WQE translations.

All header masks and all `.c` placement sources named above have pinned bytes
in `hw/xtr_v1/source_manifest.txt`.  No external driver source is copied into
this repository.
