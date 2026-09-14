# Phase 1C RDMA 硬件 ABI 修复规格

## 目标

使项目编解码层能够表达并验证归档 `dpu_kernel_rdma-version_0.1.34` 的 CQE、RQE、CEQE、AEQE、CQ doorbell、QPC shadow 以及 CQC 语义；保持未定义位 fail-closed，并让真实 raw image 的读写位置可由测试证明。

## ABI 依据

- RQE：`wr.h:171-188,197`。header qword0；TPL qword1 `[31:0]`；SG buffer physical address 位于 byte32/qword4 `[63:9]`，编码值为 `SGB_PA >> 9`，低 9 位必须为零。
- CQE：`cq.h:26-27`。32B header offset 0；128B header offset 64（qword8）。`wr.h:123-149` 定义 qword0/qword2 有效字段。
- CEQE：`defs.h:64-85`。qword0 valid/URC/QPN/SQ-RQ valid/CQN/ecode/opcode；qword1 RC CI 或 URC abnormal type、remote ecode、WQE/SQ/RQ indices。
- AEQE：`defs.h:98-114,118`。qword0 flags、abnormal type、CQN/EQN split、opcode/ecode/QPN；qword1 remote ecode、queue index、SRFQN/index；低字段重组使用 `CQN_EQN_LSHIFT=6`。
- CQ notify doorbell：`cq.h:107-121`。CI_INVLD bit63、ARM_INVLD bit62、ARM_DB_FLAG bit61、URC bit60、ARM_ST `[59:58]`、ARM_SN `[57:56]`；RC/URC CI fields、host ID、CQN 保持原坐标。
- QPC：`qp.h:20`。QPC 为 512B，byte504/qword63 为 8B runtime shadow；该区域可在硬件 readback 出现，不属于 create/modify 软件写字段。
- CQC：`cq.h:123-153`。CQ PI/wrap、CQE size、state/size、backing PBA、CI/wrap、arm、shadow PA、CEQN 坐标已与项目对齐，作为不可回归的 baseline。

## 范围与接口

1. 在 `src/codec/rdma/rdma_queue_codecs.sv` 扩展 RQE/CQE/CEQE/AEQE 模型、copy/validate 和 codec；新增字段必须有明确宽度、raw 位域和 reserved mask。
2. 在 `src/codec/rdma/rdma_doorbell_codecs.sv` 扩展 CQ doorbell invalid flags；不得改变 CQ doorbell BAR offset 或既有 RC/UD/URC 坐标。
3. 在 `src/codec/rdma/rdma_qpc_codecs.sv` 区分 readback decode 与 create/modify encode：readback 允许/保留 qword63 shadow，写路径继续禁止向 shadow 写入非零值。
4. CQC 不增加新字段；仅保留现有 `rdma_context_body_codecs.sv` 坐标并加入回归 gate。
5. 测试必须以 raw byte image 验证 wire position，同时验证 detached decode、范围错误、未对齐地址、错误 profile 和保留位错误。

## 非目标与强制约束

- 不修改外部驱动归档或任何外部依赖仓库；驱动头仅作为只读 ABI oracle。
- 禁止通过放宽整 qword、删除 `check_reserved`、忽略所有非零扩展字节来“修复”解码；每个放行位必须对应上述驱动宏。
- CQE 128B 只能把 header 基址移到 byte64；不得把整个 128B 当作从 qword0 开始的 32B header，也不得把前缀错误地当作有效字段。
- AEQE CQN/EQN 必须保持 high/low split 及 shift=6 证据，不得用未经证明的连续 scalar 替代。
- QPC qword63 shadow 只属于 readback 观察；create/modify 仍生成零 shadow 或明确拒绝非零输入。
- 每个函数/task 和新增文件遵守仓库 AGENTS.md 的中文“功能 / 输入输出及副作用 / 失败边界”三段注释与稀疏排版。
- 每个任务先写 RED 测试并在 53 登录 bash 环境确认失败，再实现最小改动并运行 focused GREEN；不得先改实现再补测试。

## 验收标准

- C1/C2 Critical：非零合法 RQE SGB_PA 与 CQE 128B byte64 header 均可 raw round-trip；旧错误坐标和非法对齐输入被拒绝。
- I1–I4：CQE、CEQE、AEQE、CQ doorbell 每个驱动有效字段都有正向 round-trip 和对应 reserved negative；RC/UD/URC profile 行为显式。
- I5：带非零 qword63 的 QPC readback 成功并保留/忽略 shadow；软件写入路径不发布 shadow 非零字节。
- CQC baseline 测试在所有 Phase1C 提交中保持通过。
- 53 远端 focused tests 的 UVM summary 必须为 warning=0/error=0/fatal=0；本机只运行静态检查，不能替代 VCS 仿真。

