# QPC 与 XTRDMA 0.1.34 驱动 ABI 位级审计

> 审计日期：2026-09-14  
> 审计对象：QPC 512-byte context、CMQ QPC command body、QPC_QUERY readback 与 qword63 runtime shadow  
> 结论：当前已冻结的 92 个 QPC 字段坐标与驱动一致；不能因为 debugfs 展示表比 `wr.h` 多出字段就扩大 qword63 readback mask。

## 1. 审计范围与证据

本审计只读比较驱动和模型，不修改驱动归档、不修改生产代码，也不把未确认的位加入 codec ownership。驱动基线是 `dpu_kernel_rdma-version_0.1.34`，模型基线是当前工作树的 QPC 定义、codec、CMQ image mask 和 unit test。

| 证据 | 用途 |
| --- | --- |
| `hw/rdma/source_manifest.txt:6,30` | 冻结 `qp.h` 的 SHA-256 和 QPC 512-byte/512-byte-address-shift 来源 |
| `hw/rdma/source_manifest.txt:10-11` | 冻结 `wr.h` 的 WQE、RQE、CQE 与 shadow 相关来源 |
| 驱动 `qp.h:20,177-430` | QPC 大小、RAM/INFO/D 顺序和 `XTRDMA_QPC_*` 位域 |
| 驱动 `qp.c:1080-1083,1226-1671` | QPC context 地址、RC/UD/URC 写入顺序和 `set_64bit_val()` 坐标 |
| 驱动 `wr.h:35-38` | 正式 QP shadow 四段位域 |
| 驱动 `wr.c:994-1010,1189-1205` | RQ shadow 的独立写路径和 SQ 门铃读取的 `HW_DROP_DB_CNT` |
| 驱动 `cmq.c:1314-1330` | QPC_QUERY 请求只携带 QPN 与 512-byte buffer address |
| 驱动 `tools/xtrdma_debugfs_tool.h:464-471,1016-1022` | debugfs 展示布局；仅作为冲突证据，不作为正式写/读 ABI |
| `tools/check_rdma_profile_names.py:469-562` | 92 条 QPC `FieldMapping` 的独立 C→SV 坐标校验 |
| `src/codec/rdma/rdma_defs.svh:331-435` | 92 个 SV `RDMA_FIELD`、IP raw range 和 qword63 readback mask |
| `src/codec/rdma/rdma_qpc_codecs.sv:107-298,487-514` | encode/decode ownership 分离、元数据校验和 reserved 检查 |
| `tests/unit/rdma_qpc_codec_test.sv:1253-1307` | canonical shadow 为零、合法 shadow readback、bit63 拒绝 |

本地审计副本中，`qp.h`、`qp.c`、`wr.h`、`wr.c` 和 debugfs 展示头的 SHA-256 分别为：

```text
qp.h                         6202ca6df10cca9bebdcdf5f766c145cd319e0c765edcfbd8677e6d4afa267bd
qp.c                         c2832eee56ce17128a4c548ed96298912ba0ce6f4ce61401f433c257396f7c3c
wr.h                         c75fb5770ef0ea1af404efbaf95cf79356d1096d331d7cdfcc46ea9ad9b3225b
wr.c                         f9267765b49faff2b5772c28dde862bec7079413b2278540cba3c6f2ea64f7fe
tools/xtrdma_debugfs_tool.h  0d7b10c9cdb396773cca082d5da68115eff0da57f4e8f9b8883140e7c0377f48
```

## 2. 坐标、顺序和端序

驱动把一个 QPC 视为 4 个 RAM、每个 RAM 4 个 INFO、每个 INFO 4 个 64-bit D qword。`qp.h` 的注释顺序从 `RAM_0 INFO_0 D3` 开始；因此：

```text
qword_index = RAM * 16 + INFO * 4 + (3 - D)
byte_offset  = qword_index * 8
```

QPC qword0 是 `RAM_0 INFO_0 D3`，qword63 是 `RAM_3 INFO_3 D0`，也就是 byte504..511。驱动先用 `BIT[_ULL]`/`GENMASK[_ULL]` 在 host logical `u64` 中做 `FIELD_PREP`，再由 `set_64bit_val()` 以 big-endian qword 写入内存。模型的 `RDMA_FIELD` 中 `WORD_BYTE_OFFSET`/`LSB`/`WIDTH` 表示这个逻辑坐标，`OFFSET = WORD_BYTE_OFFSET*8 + LSB` 不是串行大端字节流中的直接 bit index。

这一区分不能省略：把 `OFFSET` 当成 raw byte-stream bit 会同时破坏 qword 内端序和跨 qword 的字段位置。

## 3. 92 个已冻结字段的逐位结果

驱动 `qp.h` 中解析出的唯一 `XTRDMA_QPC_*` 位域宏为 190 个（源文件中有一个重复的 `XTRDMA_QPC_EIRQ_PBA_EXTRA` 定义，因此宏出现次数为 191，但唯一名字仍为 190）。checker 的 `FIELD_MAPPINGS` 与 `rdma_defs.svh` 各有 92 个 QPC 字段；逐一比较 C 的 `GENMASK/BIT`、qword byte offset、LSB 和 width 后，92/92 均一致。下表列出完整映射；同一 qword 中的字段用分号分隔，方括号是逻辑 qword 的 `[MSB:LSB]`。

| qword | byte | 已映射字段（驱动符号 → SV 符号 `[MSB:LSB]`） |
| ---: | ---: | --- |
| 0 | 0 | `XTRDMA_QPC_TVER` → `RDMA_QPC_TVER` `[63:62]`; `MIG` → `MIG` `[61]`; `SERVICE_TYPE` → `SERVICE_TYPE` `[60:58]`; `HOST_ID` → `HOST_ID` `[54:52]`; `VF_ID` → `VF_ID` `[51:40]`; `ICOS` → `ICOS` `[39:37]`; `QPN` → `QPN` `[36:16]`; `STAT_IDX` → `STAT_IDX` `[15:8]`; `UD_QKEY_H` → `UD_QKEY_H` `[7:0]`; `URC_RSQ_PBA_H` → `URC_RSQ_PBA_H` `[3:0]` |
| 1 | 8 | `UD_QKEY_L` → `UD_QKEY_L` `[63:40]`; `URC_RSQ_PBA_L` → `URC_RSQ_PBA_L` `[63:16]`; `PKEY` → `PKEY` `[15:0]` |
| 2 | 16 | `SHADOW_PBA` → `SHADOW_PBA` `[63:9]`; `TX_ENDIAN_SWAP` → `TX_ENDIAN_SWAP` `[6]`; `RX_ENDIAN_SWAP` → `RX_ENDIAN_SWAP` `[5]`; `SQ_CE_EN` → `SQ_CE_EN` `[4]`; `RA_RENCE` → `RA_FENCE` `[3]`; `AA_FENCE` → `AA_FENCE` `[2]`; `FC_EN` → `FC_EN` `[1]` |
| 3 | 24 | `URC_RSQ_SIZE` → `URC_RSQ_SIZE` `[61:59]`; `CC_TYPE` → `CC_TYPE` `[63:62]`; `QP_ST` → `QP_ST` `[58:56]`; `PMTU` → `PMTU` `[50:48]`; `RNR_RETRY_TH` → `RNR_RETRY_TH` `[47:45]`; `QP_SN` → `QP_SN` `[39:32]`; `RC_SRFQ` → `RC_SRFQ` `[31]`; `RC_SRFQN` → `RC_SRFQN` `[30:16]`; `PD_IDX` → `PD_IDX` `[15:0]` |
| 4 | 32 | `QP_ACCESS_FLAG` → `QP_ACCESS_FLAG` `[4:0]`; `URC_RDSQ_PBA` → `URC_RDSQ_PBA` `[63:12]`; `URC_RDSQ_SIZE` → `URC_RDSQ_SIZE` `[10:8]` |
| 5 | 40 | `PSN_RETRY_TH` → `PSN_RETRY_TH` `[7:5]`; `RTO_CODE` → `RTO_CODE` `[4:0]` |
| 7 | 56 | `VLAN` → `VLAN` `[63]`; `IPV6` → `IPV6` `[62]`; `TUNNEL` → `TUNNEL` `[61]`; `LAG` → `LAG` `[60]`; `FWD` → `FWD` `[59:58]`; `DST_VPORT_ID` → `DST_VPORT_ID` `[54:44]`; `SRC_ADDR_IDX` → `SRC_ADDR_IDX` `[43:32]`; `DST_PORT` → `DST_PORT` `[27:24]`; `DST_QPN` → `DST_QPN` `[23:0]` |
| 8 | 64 | `DMAC` → `DMAC` `[63:16]`; `PRI` → `PRI` `[15:13]`; `CFI` → `CFI` `[12]`; `VLAN_ID` → `VLAN_ID` `[11:0]` |
| 9 | 72 | `SRC_VPORT_ID` → `SRC_VPORT_ID` `[62:52]`; `FLOW_LABEL` → `FLOW_LABEL` `[51:32]`; `DSCP` → `DSCP` `[31:26]`; `ECN` → `ECN` `[25:24]`; `HOPLIMIT` → `HOPLIMIT` `[23:16]`; `CUR_UDP_SPORT` → `CUR_UDP_SPORT` `[15:0]` |
| 12 | 96 | `URC_TX_RBSN` → `URC_TX_RBSN` `[47:24]`; `URC_TX_DBSN` → `URC_TX_DBSN` `[23:0]` |
| 16 | 128 | `URC_RX_RBSN` → `URC_RX_RBSN` `[47:24]`; `URC_RX_DBSN` → `URC_RX_DBSN` `[23:0]` |
| 20 | 160 | `RC_TPE_CUR_SQ_PSN` → `RC_TPE_CUR_SQ_PSN` `[23:0]` |
| 26 | 208 | `RC_LAST_READ_PSN` → `RC_LAST_READ_PSN` `[23:0]` |
| 27 | 216 | `SQ_PD_PBA_OR_PBA` → `SQ_PBA` `[63:12]`; `SQ_SIZE` → `SQ_SIZE` `[11:8]`; `SQ_OM` → `SQ_OM` `[7:6]` |
| 28 | 224 | `RC_EIRQ_PSN_MAX` → `RC_EIRQ_PSN_MAX` `[47:24]`; `URC_NXT_RDSQ_FETCH_NUM` → `URC_NXT_RDSQ_FETCH_NUM` `[21:16]`; `URC_RX_SRBSN` → `URC_RX_SRBSN` `[47:24]` |
| 29 | 232 | `EIRQ_CUR_SEND_PSN` → `EIRQ_CUR_SEND_PSN` `[23:0]`; `URC_CUR_TX_DPSN` → `URC_CUR_TX_DPSN` `[47:24]`; `URC_CUR_TX_RPSN` → `URC_CUR_TX_RPSN` `[23:0]` |
| 36 | 288 | `EPSN_REQ` → `EPSN_REQ` `[39:16]` |
| 37 | 296 | `URC_RXED_DBSN` → `URC_RXED_DBSN` `[23:0]` |
| 40 | 320 | `URC_RQ_SE_TH` → `URC_RQ_SE_TH` `[23:20]`; `URC_SQ_CE_TH` → `URC_SQ_CE_TH` `[19:16]` |
| 41 | 328 | `URC_TX_SRBSN` → `URC_TX_SRBSN` `[47:24]`; `URC_MAX_TX_SRBSN` → `URC_MAX_TX_SRBSN` `[23:0]` |
| 43 | 344 | `RC_PSN_MAX_RPE` → `RC_PSN_MAX_RPE` `[55:32]` |
| 44 | 352 | `RC_EPSN_RSP` → `RC_EPSN_RSP` `[39:16]` |
| 47 | 376 | `QPC2_RC_EPSN_RSP` → `QPC2_RC_EPSN_RSP` `[55:32]` |
| 48 | 384 | `URC_CUR_DSQ_PBA_H` → `URC_CUR_DSQ_PBA_H` `[39:0]` |
| 49 | 392 | `URC_CUR_DSQ_PBA_L` → `URC_CUR_DSQ_PBA_L` `[63:52]`; `URC_NXT_DSQ_PBA` → `URC_NXT_DSQ_PBA` `[51:0]` |
| 50 | 400 | `URC_TPE_RPSN_MAX` → `URC_TPE_RPSN_MAX` `[63:40]` |
| 52 | 416 | `RC_PSN_MAX_TPE` → `RC_PSN_MAX_TPE` `[63:40]`; `URC_TPE_DPSN_MAX` → `URC_TPE_DPSN_MAX` `[63:40]`; `URC_NXT_DSQ_FETCH_NUM` → `URC_NXT_DSQ_FETCH_NUM` `[37:32]` |
| 53 | 424 | `RC_RETRY_FPSN` → `RC_RETRY_FPSN` `[23:0]` |
| 54 | 432 | `RC_RETRY_PSN` → `RC_RETRY_PSN` `[23:0]` |
| 56 | 448 | `SQ_CQN` → `SQ_CQN` `[39:20]`; `RQ_CQN` → `RQ_CQN` `[19:0]` |
| 60 | 480 | `LOAD_RQ_PI_TH` → `LOAD_RQ_PI_TH` `[23:16]` |
| 62 | 496 | `RQ_OR_SRQ_PD_PBA_OR_PBA` → `RQ_PBA` `[63:12]`; `RQ_OR_SRQ_SIZE` → `RQ_SIZE` `[11:8]`; `RQ_OR_SRQ_OM` → `RQ_OM` `[7:6]` |

为便于阅读，表中少数重复出现的公共前缀被省略（例如 `MIG` 表示
`XTRDMA_QPC_MIG` → `RDMA_QPC_MIG`）；checker 的实际比较使用完整符号名，
不会把这些后缀当成新的字段。

表中的 qword 10/11（byte80..95）没有 `BIT/GENMASK` 字段：驱动 `qp.c` 直接 `memcpy(... + 80, dest_ip, 16)`。因此模型在 `rdma_qpc_codecs.sv` 对这 16-byte raw range 使用两个完整 qword 的 mask 是特例，不是“未知位一律放行”。该 range 必须继续由长度、byte offset、golden image 和 driver source hash 共同约束。

## 4. 190 个驱动宏与 92 个模型字段的差异

差异不是坐标错误，而是模型当前只选择了可消费的 canonical/transport-visible 子集。剩余 98 个唯一宏不能直接加入软件写 mask；它们至少需要独立的 owner、生命周期和 golden 证据。

### 4.1 qword0..7：条件性 create/modify 字段

这些字段位于驱动确实会组装的基础 context，但当前语义模型没有对应字段或只在特定 transport/模式下有效：

```text
RC_ORQ_PBA_H/L, RC_ORQ_SIZE,
RQ_CQE_MODE, SQ_CQE_MODE, LOCAL_RNR_CODE,
RC_EIRQ_PBA, RC_IRQ_SIZE, MC_ATTACHED, MC_LOOPBACK_EN, FMR_EN,
RC_UAQ_IRQ_PBA, URC_SRUAQ_SREQ_PBA, RC_UAQ_SIZE, URC_SRUAQ_SREQ_SIZE,
EIRQ_PBA_EXTRA, ACK_REQ_TH, PP_PKT_SPRAY, CC_PKTNUM_EN, SPRAY_MODE,
SRQ_SN, URC_WR_UNORDER_EN, QP1
```

例如 `xtrdma_fill_rc_ud_qpc_info()` 会写 RC ORQ、EIRQ/UAQ backing 和条件字段；`xtrdma_fill_urc_qpc_info()` 会写 URC queue/config 字段。它们不能按“宏存在”自动加入：应先确定 RC/UD/URC 的 transport applicability、模型语义单位、是否为只初始化一次的配置，以及 modify 是否允许覆盖。

### 4.2 qword16..30：运行态序列、拥塞控制和计数器

典型未映射字段包括：

```text
RC_QCN_*、SQ_RECHK_FLAG、NXT_SQ_FETCH_NUM、RC_SSN、
URC_CUR_TX_SRSN、URC_LAST_READ_SRSN、RC_WAIT_NML_CCACK_FLAG、
CCE_*、RX/TX_*_BLK_CNT、RX/TX_*_PKT_CNT、NCWND、SPT_BM_SEL、
TPE_EIRQ_DB_RECHK_FLAG、RC_NXT_EIRQ_FETCH_NUM、RC_TPE_LAST_EIRQE_DONE
```

这些字段在 `qp.c:xtrdma_fill_qpc_ram2_info0()` 和 RC/URC 填充路径中可能有初始化或配置写入，但很多字段也代表硬件运行时镜像。必须区分“create/modify 输入配置”和“query/readback 观察值”；把两者混在一个 canonical write mask 会让软件伪造硬件状态。

### 4.3 qword32..47：HACC/DCQCN 与 RC response runtime

`WAIT_*`、`RTTM_*`、`FCWND*`、`CCTX/CCRX_*`、`LST_REQ_OPCODE`、`RC_LST_RSP_OPCODE` 和 `QPC2_RC_LST_RSP_OPCODE` 等字段属于 HACC/DCQCN 或协议响应镜像。当前没有 typed model owner，应该保持 opaque/readback-only，除非驱动团队提供每个字段的写入方和生命周期证明。

完整的 98 项名称（按 qword）如下，供后续逐项认领；此清单不是允许放行的 mask：

| qword | 未映射驱动宏 |
| ---: | --- |
| 0-7 | `RC_ORQ_PBA_H`; `RC_ORQ_PBA_L`; `URC_WR_UNORDER_EN`; `QP1`; `RC_ORQ_SIZE`; `RQ_CQE_MODE`; `SQ_CQE_MODE`; `LOCAL_RNR_CODE`; `RC_EIRQ_PBA`; `RC_IRQ_SIZE`; `MC_ATTACHED`; `MC_LOOPBACK_EN`; `FMR_EN`; `RC_UAQ_IRQ_PBA`; `URC_SRUAQ_SREQ_PBA`; `RC_UAQ_SIZE`; `URC_SRUAQ_SREQ_SIZE`; `EIRQ_PBA_EXTRA`; `ACK_REQ_TH`; `PP_PKT_SPRAY`; `CC_PKTNUM_EN`; `SPRAY_MODE`; `SRQ_SN` |
| 16-19 | `RC_QCN_MAIN_STATUS`; `RC_QCN_RECVDB_ALREADY_FLAG`; `RC_QCN_TIMER_REFRESH_CNT`; `RC_QCN_TIMER_REFRESH_LST_TIME`; `RC_QCN_COUNTER_REFRESH_CNT`; `RC_QCN_COUNTER_SINCE_REFRESH_BLK`; `RC_QCN_LST_ADD_REMAIN_BITS_TIME`; `RC_QCN_CONT_RECV_CNP_CNT`; `RC_QCN_ONCE_SPEED_UP_FLAG`; `RC_QCN_LIMIT_RP_LST_STATUS`; `RC_QCN_TARGET_WIN`; `RC_QCN_TARGET_RP`; `RC_QCN_LIMIT_RP`; `RC_QCN_REMAIN_CAN_SEND_BITS_SIGN`; `RC_QCN_REMAIN_CAN_SEND_BITS`; `RC_QCN_TOT_SEND_BLK_LST_DB` |
| 20-30 | `SQ_RECHK_FLAG`; `URC_CCE_UDP_SPT_BM_HIGH_BITS`; `NXT_SQ_FETCH_NUM`; `RC_SSN`; `URC_CUR_TX_SRSN`; `URC_CCE_UDP_SPT_BM_LOW_BITS`; `WAIT_NML_CCACK_RTO_DBCNT`; `RC_WAIT_NML_CCACK_FLAG`; `CCE_RTO_CODE`; `CCE_UDP_SPT_MODE`; `CCE_NEED_NML_DELAYM`; `RX_TOT_RECV_BlK_CNT`; `TX_TOT_SEND_BLK_CNT`; `FCWND`; `URC_LAST_READ_SRSN`; `RX_TOT_RECV_PKT_CNT`; `TX_TOT_SEND_PKT_CNT`; `NCWND`; `SPT_BM_SEL`; `TPE_EIRQ_DB_RECHK_FLAG`; `RC_NXT_EIRQ_FETCH_NUM`; `RC_TPE_LAST_EIRQE_DONE` |
| 32-35 | `WAIT_RSTF_CCACK_RTO_DBCNT`; `WAIT_RSTF_CCACK_FLAG`; `WAIT_MIN_CCACK_RTO_DBCNT`; `WAIT_MIND_CCACK_FLAG`; `TX_TOT_SEND_PKT_CNT_LAST_DB`; `TX_TOT_SEND_BLK_CNT_LAST_DB`; `TX_LST_SENDPKT_DB_TIME`; `TX_SEND_PKT_MID_RTO`; `TX_SEND_BLK_MID_RTO`; `TX_RECV_DB_ALREADY`; `FCWND_DEADLOCK_DB_CNT_HIGH8`; `RECV_NMLD_CCACK_CNT`; `RTTM_LAST_TIME_OR_CHANGE_UDP_SPT_MODE_LAST_TIME`; `RTTM_CNT`; `LST_NCWND_TIME_MARKER`; `LST_NCWND_INCREACE`; `FCWNDM_BEGIN_BLK`; `FCWNDM_BEGIN_TIME`; `GEN_NML_CCREQ_MID_CCACK_CNT`; `TARGET_DELAY`; `RTT`; `FCWNDM_BUSY`; `RECV_NML_CCACK_MORE_TDELAYTH`; `RECV_NML_CCACK_LESS_TDELAYTH`; `RECV_NMLD_CCACK_ALREADY`; `RECV_CCACK_ALREADY`; `CCTX_RECV_CCDB_CNT`; `CCE_CUR_CCACK_PSN`; `DELAY`; `FCWND_DEADLOCK_DB_CNT_LOW8`; `TX_RECV_RTO_DB_TIME_LST`; `CCRX_GEN_CCDB_CNT`; `GEN_CCACK_MID_PKT`; `GEN_CCACK_MID_BLK` |
| 36,44,47 | `LST_REQ_OPCODE`; `RC_LST_RSP_OPCODE`; `QPC2_RC_LST_RSP_OPCODE` |

## 5. qword63 runtime shadow：正式 ABI 与 debugfs 展示冲突

驱动的正式 `wr.h` 定义只有四段：

```c
XTRDMA_QP_SHADOW_HW_DROP_DB_CNT  GENMASK(54, 48)
XTRDMA_QP_SHADOW_SW_RING_DB_CNT GENMASK(38, 32)
XTRDMA_QP_SHADOW_SQ_PI          GENMASK(14, 0)
XTRDMA_QP_SHADOW_SQ_PI_WRAP     BIT_ULL(15)
```

因此当前 readback mask 为：

```text
0x007f_007f_0000_ffff
```

模型的边界是正确且有意的：

- `qpc_allowed_mask()` 不包含 qword63 shadow，故 canonical encode 的 qword63 必须全零；
- `qpc_decode_allowed_mask()` 只在 qword63 合并上面四段 readback mask；
- 其他位（包括 bit63）继续走 fail-closed reserved 检查；
- shadow 位只作为观察证据，不投影成 `rdma_qpc_model` 的可写语义字段。

驱动运行时也支持这四段的实际使用：`wr.c:1200-1205` 从 `qp_ctx.shadow_area` qword0 读取 `HW_DROP_DB_CNT`，用于 SQ 门铃流控；`qp.c:1080-1083` 将 shadow area 绑定到 `XTRDMA_QPC_SHADOW_AREA_OFFSET=504`。这证明 `[54:48]` 不是文档死字段。

但 debugfs 的 RC 展示表（`tools/xtrdma_debugfs_tool.h:464-471`）还显示 `RQ_PI_LOCK[56]`、`SW_SQ_PI_WRAP[31]`、`SW_SQ_PI[30:16]`、`SW_RQ_PI_WRAP[15]` 和 `SW_RQ_PI[14:0]`；URC 表（`1016-1022`）也显示 bit31/30:16。由此形成看似更宽的 `0x017f_007f_ffffffff` 视图。不能直接采用，原因是：

1. 这些额外字段没有对应的 `XTRDMA_QP_SHADOW_*` 正式宏；debugfs 是展示/解析表，不是驱动写入契约。
2. `wr.c:994-1010` 的 RQ PI 更新是另一条 `set_16bit_val(..., XTRDMA_RQ_SHADOW_PI_OFFSET)` 路径，不能据此把 RQ cursor 拼进 QPC qword63 的正式 mask。
3. RC 表才有 `RQ_PI_LOCK`，URC 表没有，说明展示布局本身可能包含 transport-specific/composite view，而非同一个物理 qword 的统一 ABI。

处置：保持 `0x007f_007f_0000_ffff`，把 bit56/31/30:16 标为待驱动 owner/硬件实证确认。只有拿到正式头文件宏、硬件 dump 与 offset/生命周期证据后，才能新增独立 readback view；不能为了通过真实 query 而放宽当前 QPC codec。

## 6. 三种 image 语义必须分开

### 6.1 Canonical create/modify QPC image（512 bytes）

`rdma_hw_qpc_codec_base::encode()` 产生 512-byte、512-byte aligned、big-endian 的 standalone QPC image。它是语义模型的 canonical create/modify projection：已映射字段由 codec 负责，qword10/11 是 16-byte destination-IP raw range，qword63 shadow 不属于软件写 ownership。`validate_qpc_encode_mask()` 要求 builder occupancy 与 writable mask 完全相等，因此不会偷偷携带未建模字段。

这不是“驱动所有 190 个字段的完整镜像”。驱动 `xtrdma_fill_rc_ud_qpc_info()`/`xtrdma_fill_urc_qpc_info()` 还会写条件性 queue、拥塞和运行态字段；若要表达它们，应建立独立 profile/extension，而不是扩大当前 canonical mask。

### 6.2 CMQ QPC command body（64 bytes）

CMQ SQE 是 64 bytes，QPC_CREATE/MODIFY 的 body 只放命令 envelope、QPN/flags、QPC buffer address 或 modify data；完整 512-byte context 通过 Host-memory buffer/签名语义关联。`rdma_image_masks.svh` 的 `RDMA_QPC_*_BODY_OWNERSHIP` 是 CMQ body mask，不是 standalone QPC 512-byte mask。两者不能互相替代，也不能用 CMQ body 的零位推断 QPC context 的保留位。

### 6.3 QPC_QUERY request 与 readback image

驱动 `xtrdma_sc_qp_query()`（`cmq.c:1314-1330`）只在请求中编码 QPN、opcode/index/valid 和 byte24 的 `QPC_BUFFER_ADDR`；硬件随后把完整 512-byte query context 写入该 buffer。当前 QPC `decode()` 会先执行完整 64-qword reserved/mask 校验，再投影 92 个语义字段，因此它适合“已声明字段 + 正式 shadow”的严格认证，不应声称支持任意硬件 query dump。

如果真实 QPC_QUERY 返回了上述 98 个未建模字段（尤其 DCQCN/HACC 或 runtime cursor），当前 strict decoder 应明确失败；未来若需要 debug/query 产品能力，应新增 `opaque_qpc_query_image` 或分 transport/profile 的 query decoder，保留 raw bytes 和来源，不要把 query-only 字段混进 create/modify writer。

## 7. 风险判定

| 等级 | 风险 | 当前处置 |
| --- | --- | --- |
| P0 ABI 误写 | 把 debugfs 额外位并入 qword63 mask，会让软件把硬件/另一路 RQ cursor 当成 QPC shadow 写出 | 不扩大 mask；保持 encode/decode 分离 |
| P0 误报完整支持 | 190 个驱动宏被误称为 92 个模型字段已全部支持 | 文档和接口明确区分 92 mapped / 98 unmapped |
| P1 query 失败 | 真实 QPC_QUERY 带 DCQCN/HACC/runtime 字段时 strict decode 拒绝 | 作为当前 fail-closed 行为记录；新增 opaque query API 后再扩展 |
| P1 raw range 漂移 | qword10/11 完整 mask 可能掩盖未来字段重用 | 保持独立 raw-byte 说明、golden bytes 和 source hash；驱动变更时重新审计 |
| P1 alias 误解 | `RC_EIRQ_PSN_MAX` 与 `URC_RX_SRBSN` 等共享坐标但语义互斥 | 保留 transport-specific field names；禁止把 alias 合成一个无 transport 的值 |
| P2 语义缺口 | 未映射 create/config 字段无法由当前模型生成完整驱动 context | 逐字段 owner/transport/applicability 评审，不做批量 mask 放宽 |

## 8. 建议的后续验证矩阵

以下是后续工作建议，本次审计不实现这些改动：

1. 对 qword0..62 的 92 个字段，按 RC/UD/URC 分别做单字段 golden mutation，确认 logical LSB、big-endian byte order 和 transport mask；对共享坐标 alias 做互斥测试。
2. 对 qword63，分别只置位 `[54:48]`、`[38:32]`、bit15、`[14:0]`，确认 readback 成功；分别置 bit63、bit56、bit31、bit30:16，确认仍拒绝。
3. 对 qword63 做 canonical encode、全零 decode、合法 shadow decode 三条独立路径，不能只用“encode 后再 decode”掩盖 mask 错误。
4. 对 byte80..95 使用全 16-byte 非对称 pattern 做 raw memcpy round-trip，并测试前后 qword 的 sentinel；确认 IP range 不被当作普通 logical bitfield。
5. 构造 QPC_QUERY request，核对 qword0 QPN、qword3 buffer address、512-byte alignment 和 `RDMA_IMAGE_CMQ_SQE` 元数据；随后分别用只含 92 mapped fields 的 query image 与含一个未建模字段的 image 验证 strict reject 行为。
6. 以后若新增 query/opaque profile，必须同时保存 raw 512 bytes、transport、Function/generation、source manifest digest 和 query opcode，禁止只发布投影模型。
7. 每次驱动归档更新，先重新解析 `qp.h`/`wr.h` 并比较 unique macro inventory，再审查 qword63 owner；debugfs 表变化不能单独触发 mask 修改。

## 9. 审计结论

当前 QPC codec 的安全边界应保持不变：92 个已映射字段逐位可信，qword10/11 是有明确来源的 16-byte raw range，qword63 只允许 `wr.h` 正式声明的四段 runtime shadow，其他 98 个驱动宏保持未认领。真实驱动 query/readback 与 canonical writer 是不同产品契约；在没有逐字段 owner 和 golden 证据前，严格拒绝未知位比“为了兼容 dump 而放宽 mask”更符合 fail-closed 设计。
