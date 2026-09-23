# Batch150：CMQ context helper 重复收缩

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批只处理 CMQ 编码层两个消费者之间逐字重复的 context-key/opcode 判定逻辑，
不改变 wire layout、registry registration、状态码优先级或外部依赖。重构计划继续保持
`active`。

## 代码收缩

- 在 `src/codec/rdma/rdma_cmq_codecs.sv` 文件级 package scope 新增
  `rdma_cmq_context_codec_key()` 和 `rdma_cmq_is_context_opcode()`。前者集中描述
  六个 context opcode 的 `image_kind/object_type/variant` 映射，后者从同一份 key
  判断是否进入 context-body registry。
- `rdma_hw_cmq_body_encoder` 与 `rdma_hw_cmq_request_composer` 的原
  `protected context_key()`/`is_context_opcode()` 入口保留为薄转发，以保持现有
  protected 可见性和潜在测试扩展点；两类不再各自复制 case/inside 逻辑。
- 未知或保留 opcode 仍返回 `RDMA_IMAGE_NONE`、`"invalid"`、`"invalid"`，并使
  `is_context` 为 0。六个映射保持逐值不变：KEY_ALLOC→MRT/mrt/key_alloc、
  MR_REGISTER→MRT/mrt/register、CQC_CREATE→CQC/cqc/create、CEQC_CREATE→
  CEQC/ceqc/create、AEQC_CREATE→AEQC/aeqc/create、SRFQC_CREATE→SRQC/srqc/create。
- 删除 `tests/unit/rdma_cmq_codec_test.sv` 中仅声明、无调用的旧 `context_key()`
  fixture；生产 codec/registry 测试仍通过实际 compose/lookup 路径覆盖映射。没有把
  测试 fixture 改为调用 DUT helper，避免失去独立的测试侧预期构造语义。
- 更新 `hw/rdma/frozen_abi_manifest.txt` 中 `rdma_cmq_codecs.sv` 的摘要；这是源码
  结构变化的 manifest 同步，不是 wire ABI 或字段坐标变化。context-body registry 的
  注册表仍保留其显式 registration 表，本批不宣称它与 helper 已形成全局单一数据源。

源码与测试文件合计净减少 53 行（codec：94 insertions/100 deletions；dead fixture：
47 行删除），没有修改外部依赖或 `dpu_common` authority。

## 验证

所有 VCS 命令均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境
执行。最终源码边界（含注释修订和 manifest 更新）结果如下：

| 入口 | 结果 |
| --- | --- |
| `rdma_cmq_codec_test` | PROCESS/LOGICAL PASS（1/1）；UVM `INFO=4/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_context_body_codec_test` | PROCESS/LOGICAL PASS（1/1）；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_context_cmq_regression_test` | PROCESS/LOGICAL PASS（1/1）；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `cmq_gate regression` | PROCESS 28/28、LOGICAL 11/11、UVM pristine 28/28；wrapper rc=0 |

最终日志 SHA-256：

- codec：`313facdf59b5fd7f4e76c8b57842cc020f1673afd82d0b5eefe5e07388792ff6`
- context-body：`de934f4f41f534a2307147abfcdcb99202d5d486e1b50b5d875ea3b428c295f9`
- context-CMQ：`484fae5e3b85e6d9c78347fe89e24e018d3c2b198f6a62aa10adc38c7043707d`
- CMQ gate：`36b186526a80bc240d3e7f2ab236c989c48f36c57e48ad3bb2bbb4167bd2ef23`

`rdma_cmq_codec_test` 和 CMQ gate 日志中的 report catcher 仍会显示既有测试设计的
`caught UVM_FATAL=1`，但最终 UVM severity summary 的 warning/error/fatal 均为 0，
且 wrapper 判定为 PASS；没有新增未捕获 fatal。

本地静态门禁全部通过：`git diff --check`、changed-SV style、queue lifecycle frozen
ABI、profile naming、Phase-1A approval、CMQ manifest/keyword tests，以及 Python
unit 292/292。全目录中文 function/task 与文件头复审覆盖 187 个文件（185 `.sv`、
2 `.svh`），共 5,462 个 method（`.sv` 5,460、`.svh` 2），0 diagnostics。

最终文件 SHA-256：

- `src/codec/rdma/rdma_cmq_codecs.sv`：`07fd199219f2ec8ce57e90a8e863cb259d3e02da8543970c7e3bc41c17ac3ac7`
- `tests/unit/rdma_cmq_codec_test.sv`：`5f6c14ce8fa0b34c8d89a38ed5f9d88bd1c782120021f4e8e5b74dd958b9103d`
- `hw/rdma/frozen_abi_manifest.txt`：`cac560ed8225ae163fa1641fa2a9b470fc0828d6184411eef21abeeddf634caa`

本批 focused/gate GREEN 不等同于整份结构重构计划完成；跨队列并发、SRQ 全生命周期、
legacy descriptor、外部 PCIe error/ordering 组合、engine-level 全局锁、全目录最终
ownership 审计及更广泛 F2 仍开放。
