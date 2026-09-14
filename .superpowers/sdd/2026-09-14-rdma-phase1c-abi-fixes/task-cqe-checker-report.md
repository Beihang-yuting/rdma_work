# Task CQE checker report

## Scope

本任务只修订冻结 ABI checker 的 `wr.h` CQE 字段映射；没有修改
`src/codec/rdma/rdma_queue_codecs.sv`，也没有把 CQE 的 union overlay 合并成
一个未审计的“大掩码”。字段坐标仍由 53 上锁定的 XTRDMA 0.1.34 驱动头文件
解析，`REFERENCE_FIELDS` 作为独立坐标证据，SV `RDMA_FIELD` 常量作为第三方
实现比对。

## Driver evidence

验证使用 53 上的归档：

```text
/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz
SHA-256: c9d9286dde389f681f9bd1c29fff14f52c4c1ce11fa5f73a5f1f57da9f827522
```

`wr.h` 的 CQE 定义覆盖 qword0 的 common/header 字段、qword1 的 immediate /
payload 字段、qword2 的 RC/UD/RQ-SRFQ overlay，以及 qword3 的 UD 地址字段。
补齐后的 27 个 source identity 与驱动逐一对应，坐标如下：

```text
qword0: POLARITY[63], QP_ST[62:60], RQ_CQE[59], SRFQ[58], SE[57],
        SIGN_EN[56], WQE_WRAP[55], WQE_INDEX[54:40], PKT_OPCODE[39:32],
        ECODE[31:24], VLAN[23], IPV6[22], CQE_FORMAT[21:20],
        RESIZE_CQE[19], UD_MC[18], QPN[17:0]
qword1: IMMDT_DATA_INVLD_KEY[63:32], PAYLOAD_LEN[31:0]
qword2: SIGNATURE[63:56], RC_REMOTE_SYNDROME[55:48], UD_SRC_QPN[55:32],
        RQE_CPL[31], SRFQN[27:16], SRFQE_WRAP[15], SRFQE_INDEX[14:0]
qword3: UD_SMAC[63:16], UD_VLAN_TAG[15:0]
```

这里的 `SIGNATURE` 也补进了 `REFERENCE_FIELDS`；此前它虽然出现在
`FIELD_MAPPINGS`，却没有独立 reference row，导致它不能接受第三方坐标复核。

## Checker changes

- `FIELD_MAPPINGS` 新增 17 个缺失 CQE source rows。
- `REFERENCE_FIELDS` 新增相同 17 个 rows，并补齐 `XTRDMA_CQE_SIGNATURE`。
- 新增 `WR_CQE_REQUIRED_SYMBOLS` 与 `validate_wr_cqe_mappings()`。该守卫独立锁定
  source identity 集合，拒绝删行、未知 CQE symbol、两张表的 stem/byte offset
  不一致；具体 LSB/width 仍由真实 C 宏解析后交给
  `validate_reference_fields()` 比对，避免把 Python 手工坐标当成唯一真相。
- `validate()` 在 source extraction 前调用完整性守卫。
- 已有 golden-placement 测试将未在 compact RC golden 中使用的 CQE overlay rows
  标记为 audit-only，不因此降低映射约束。

## TDD and verification

先加入 `test_wr_cqe_fields_cover_every_driver_wire_coordinate`，在实现前观察到
17 个缺失 symbol 的 RED；随后加入完整性守卫的删行/增行 RED fixture，再实现
最小映射和 guard。

通过的验证：

```text
python3 -m unittest tests.unit.test_check_rdma_profile_names -q
Ran 102 tests; OK

python3 tools/check_rdma_profile_names.py \
  --kernel-root /tmp/rdma_wr_audit_kernel.93Vmbj/kernel/dpu_kernel_rdma-version_0.1.34 \
  --archive-lock hw/rdma/archive_lock.env \
  --source-manifest hw/rdma/source_manifest.txt
rdma definitions: PASS
```

另以独立脚本逐一解析归档 `wr.h` 的 `BIT/GENMASK`，27 个 CQE rows 的
`(lsb,width)` 均与 reference row 相等；`git diff --check` 在提交前执行。

## AEQE inactive overlay note

`event.c` 对 AEQE 的 `URC_REMOTE_ECODE`、异常类型以及 SRFQ 坐标使用
`FIELD_GET`，并不先以 `URC_FLAG`/`SRFQ_EN` 把这些 wire bits 判作 reserved；
`defs.h` 的 mask 也把它们定义为有效字段。因此当前 codec 中
`validate_variant_fields()` 对 inactive overlay 的 canonical-zero 拒绝属于模型
策略，不是驱动保留位契约。此次 checker 不会伪造 canonical-zero 要求，保留该
codec 行为供 CQE/AEQE 合并后单独以 raw-image round-trip 评审；若放宽，应只移除
这两个 variant-specific nonzero 拒绝，仍保留 qword mask 的真正 reserved-bit
检查，不能整 qword 放宽。

## Deliberately out of scope

`wr.h` 中的 QPC/RQ shadow counters、SGE helper macros、REG_MR body helpers 和
RQ shadow cursor macros 不是 CQE wire entry 字段，未伪造为 `RDMA_*` 常量。RQE
inline SGE 与 `XTRDMA_QP_RQ_SIGN_EN` 也没有对应的当前 `rdma_defs.svh` typed
field；它们需另立 RQE contract 后再加入，不能借本任务的 CQE rows 隐式覆盖。
