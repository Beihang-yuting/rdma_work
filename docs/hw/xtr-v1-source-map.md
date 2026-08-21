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
| QPC `qpc_rc_boundary`, `qpc_ud_boundary`, `qpc_urc_boundary` | 512 each | big-endian per 64-bit qword; destination IP remains driver `memcpy` byte order | `qp.h` `XTRDMA_QPC_*`; byte placement from `qp.c:xtrdma_fill_rc_ud_qpc_info` and `xtrdma_fill_urc_qpc_info` | First three `context.hex` cases. Inputs freeze transport-specific backing, address-vector, PSN/sequence mirrors, thresholds and queue IDs. |
| CQC `cqc_create_body_boundary` | 64 | big-endian per 64-bit qword | `cq.h` `XTRDMA_CMQ_CQC_*`, `cmq.h` CQN; `cq.c` local stores copied by `cmq.c:xtrdma_sc_cq_create` | Final sparse WQE coordinates: local byte 0..55 becomes byte 8..63. |
| MRT register/key allocate, PBL0/1/2 | 64 each | big-endian per 64-bit qword | `cmq.h` `XTRDMA_CQPSQ_MRT_*`; `mr.c:xtrdma_hwreg_mr`, `cmq.c:xtrdma_sc_mr_register` | Four ordered cases freeze MR_REGISTER PBL0/1/2 plus KEY_ALLOC PBL0. KEY_ALLOC byte 16 bits 23:0 repeats its STAG; MR_REGISTER keeps them zero. |
| SRQC `srqc_create_body_boundary` | 64 | big-endian per 64-bit qword | `srq.h` `XTRDMA_SRFQ_CTX_*`; `srq.c:xtrdma_hw_create_srfqc` | Final sparse WQE coordinates: local byte 0..31 becomes byte 16..47. |
| CEQC/AEQC create body boundaries | 64 each | big-endian per 64-bit qword | `event.h` `XTRDMA_EQ_CTX_*`; `event.c:xtrdma_hw_create_eq` | Shared EQC layout at final byte 16..47, with distinct case/opcode/image ownership. |
| CMQ `qpc_create` | 64 | big-endian per 64-bit qword | `cmq.h` common/QPC fields and `xtrdma_cmq_opcode`; byte placement from `cmq.c` | `cmq.hex`: case 2, inputs 3, length 4, payload 5; `opcode=0,qpn=0x654321,index=27,valid=1,vfid_override=1,use_vfid=0x345,wrap=1,sq_cqn=0x15555,sign=1,rq_cqn=0xaaaa,buffer=0x123456789ab` |
| SQE `sqe_rc_boundary` | 64 | big-endian per 64-bit qword | `wr.h` `XTRDMA_SQ_WQE_*`; byte placement from `wr.c` | `queue.hex`: case 2, inputs 3, length 4, payload 5; `qpn=0x15555,opcode=13,index=0x4567,rkey=0xdeadbeef,icos=5,qp_sn=0xa6,dst_port=11,wrap=1,sign=1,se=1,fence=2,ce=2,valid=1,signature=0xc7,sge_num=4,remote_va=0x0123456789abcdef` |
| RQE `rqe_boundary` | 64 | big-endian per 64-bit qword | `wr.h` `XTRDMA_QP_RQ_*`; byte placement from `wr.c` | `queue.hex`: case 8, inputs 9, length 10, payload 11; `qpn=0xabcde,index=0x3456,payload=0x10203040,qp_sn=0x5a,opcode=9,wrap=1,valid=1,signature=0x96,sge_num=2` |
| CQE `cqe_error` | 64 | big-endian per 64-bit qword | `wr.h` `XTRDMA_CQE_*`; read placement from `wr.c` | `queue.hex`: case 14, inputs 15, length 16, payload 17; `qpn=0x2aaaa,index=0x4567,ecode=0xf4,payload=0x10203040,polarity=1,rq_cqe=1,wrap=1,packet_opcode=0x9a,immediate=0x89abcdef` |
| CEQE `ceqe_error` | 16 | big-endian per 64-bit qword | `defs.h` `XTRDMA_CEQE_*`; event placement from `event.c` | `queue.hex`: case 20, inputs 21, length 22, payload 23; `qpn=0x15555,cqn=0x1aaaaa,ecode=0xf4,pi=0xbeef,valid=1,packet_opcode=0x9a,wrap=1` |
| AEQE `aeqe_error` | 16 | big-endian per 64-bit qword | `defs.h` `XTRDMA_AEQE_*`; event placement from `event.c` | `queue.hex`: case 26, inputs 27, length 28, payload 29; `qpn=0x2aaaa,state=5,ecode=0xff,index=0x654321,valid=1,packet_opcode=0x81,wrap=1` |
| CMQ SQ doorbell `cmq_sq` | 8 | big-endian 64-bit payload | `cmq.h` `XTRDMA_CMQSQ_DB_*`; register offset from `xtrdma_hw.h` | `doorbell.hex`: case 2, inputs 3, length 4, payload 5; `pi=27,polarity=1,offset=0x0` |
| RQ doorbell `rq` | 8 | big-endian 64-bit payload | `wr.h` `XTRDMA_NOTIFY_*`; register offset from `xtrdma_hw.h` | `doorbell.hex`: case 8, inputs 9, length 10, payload 11; `qpn=0x15555,icos=5,pi=0x4567,wrap=1,offset=0x10` |
| CQ doorbell `cq` | 8 | big-endian 64-bit payload | `cq.h` `XTRDMA_NOTIFY_CQ_*`; register offset from `xtrdma_hw.h` | `doorbell.hex`: case 14, inputs 15, length 16, payload 17; `cqn=0x15555,host=5,ci=0x654321,wrap=1,arm=1,arm_state=2,arm_sn=3,offset=0x18` |

The `.hex` grammar is stable: marker, case, inputs, byte count, then one
space-separated lowercase hex byte line.  Multiple cases are separated by one
blank line.  The checker independently regenerates the complete file and
requires byte-for-byte equality. `context.hex` contains exactly 11 cases in the
order listed above: three 512-byte QPC images followed by eight 64-byte sparse
bodies. Both the Python and SystemVerilog readers reject duplicate names,
malformed/truncated/extra bytes, and incomplete trailing cases.

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

The context value baseline also freezes allocation modes direct/indirect/huge/
L3-indirect as `0/1/2/3`; MR VA/zero-based addressing as `0/1`; MR
invalid/free/valid as `0/1/2`; 4KiB/2MiB/1GiB pages and PBL0/PBL1/PBL2 as
`0/1/2`; and MR/MW-type1/MW-type2B as `0/1/2`. CQC, SRQC, and EQC
invalid/valid/error states are `0/1/2`. Hardware RDMA rights are independent
bits local-write `0x01`, remote-read `0x02`, remote-write `0x04`, MW-bind
`0x08`, and remote-atomic `0x10`; the pinned `xtrdma_get_access` projection
also freezes the rule that remote-write or remote-atomic implies local-write.

## Other pinned groups

- QPC is 512 bytes (`XTRDMA_QP_CONTEXT_SIZE`), CQC is 64 bytes
  (`XTRDMA_CQ_CONTEXT_SIZE`), and CMQE/WQE are 64 bytes.
- CEQE and AEQE are 16 bytes.  The frozen queue profile selects a 64-byte CQE.
- `defs.h` supplies CEQE/AEQE fields and representative error codes used by
  the later error codec.
- `xtrdma_hw.h` supplies every notify-register address.  SV doorbell offsets
  are relative to `XTRDMA_PF_NTFE_BAR_OFFSET`, so they can be added to a
  Function binding's `notify_base` without adding `0x2000` twice.
- `map.h` supplies the 8192-byte userspace doorbell mapping.  Thus the notify
  BAR window offset and size are both `0x2000`.
- `eth_header/rdma_register.h` pins `RDMA_HID_MAP_TABLE` and
  `RDMA_RPE_VFT_TABLE` provenance for later Function-table work; Task 9 does
  not infer their C bitfield layout from compiler-dependent struct packing.
- `alloc.h`, `mr.h`, `mr.c`, and `rdma_main.h` pin object mode, MR/PBL layout,
  the ordinary MR KEY_ALLOC projection, and access-right normalization.
- `srq.h`/`srq.c` and `event.h`/`event.c` pin the SRQC and EQC local layouts and
  their `+16` final-WQE translations.

All header masks and all `.c` placement sources named above have pinned bytes
in `hw/xtr_v1/source_manifest.txt`.  No external driver source is copied into
this repository.
