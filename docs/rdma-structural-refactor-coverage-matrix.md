# RDMA 结构重构覆盖矩阵

本矩阵把结构重构批次、职责边界、验证入口和遗留风险放在同一张可审查的表中。
它描述的是本项目模型/仿真契约覆盖，不等价于 Linux 驱动或真实 DUT 认证；所有
外部 PCIe、Host-memory 和 dpu_common 对象仍由各自环境拥有。

## 业务与验证映射

| 业务边界 | 已落地的结构 seam | 主要验证入口 | 当前状态 | 遗留边界 |
| --- | --- | --- | --- | --- |
| CMQ 值比较与提交证据 | Batch1 value contract、Batch2 typed snapshot、Batch5 body value、Batch6 journal value、Batch7 reset proof、Batch8 binding value | `rdma_cmq_engine_models_test`、`rdma_cmq_codec_test`、`rdma_cmq_completion_test`、CMQ gate | GREEN；Batch86 gate 28/28 process、11/11 logical、UVM 0/0/0 | legacy `execute()` 的三个 Phase 1B consumer 尚未完全移除 |
| CMQ completion/route authority | Batch27–30 CQE/CEQE/AEQE publish authority；Batch31–37 handle/route/cursor predicates | `rdma_cq_engine_test`、`rdma_cq_shadow_flush_test`、`rdma_eq_engine_test`、`rdma_aeqe_route_test` | focused 与 parent gate GREEN | 更深的 recovery/MMIO 语义仍由 owner task 维护 |
| queue-data attachment/recovery | Batch40、46–47、52–54、55–66、78–86：context geometry、route/epoch、CQ identity、pending attachment、CEQE route | `rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_device_publish_test`、`rdma_queue_event_route_consume_test` | Batch86 focused 与 integration GREEN | 仍需最终全目录 ownership/注释审查 |
| queue runtime | Batch37、41–42、45、48、50、53–54 的 cursor/credit/identity/value seam；Batch88 收敛 route/epoch 纯比较并完成注释合规刷新 | `rdma_queue_runtime_test`、`rdma_queue_lifecycle_test`、recovery focused suites、CMQ gate | Batch88 focused GREEN；Batch89–93 后 parent gate GREEN（28/28、11/11、UVM 0/0/0） | 不复制 runtime mutable ledger；Phase 1C F2 的全局 sge_num 收口仍暂停，RC inline-SGB 容量拒绝已由 Batch100 独立关闭 |
| resource manager | Batch38–44、51、67、74、76、79 的 segment/backing/type/owner/recovery projection；Batch89 收敛 SRQ restore flush progress；Batch97 role cardinality；Batch99 context progress authority/parity；Batch102 QP/queue transient alias audit | `rdma_resource_manager_test`、`rdma_queue_recovery_test`、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test` | Batch99/102 focused GREEN；Batch104 current parent/core gate GREEN（CMQ 28/28 process、11/11 logical；core 95/95 process、78/78 logical；UVM 0/0/0） | 更深 recovery/MMIO 与跨资源生命周期仍开放 |
| environment/backing composition | Batch91 复审 env/config、queue backing access、responder registry 的 detached snapshot、borrowed adapter、claim/seal 和 Function-incarnation 契约 | `rdma_env_composition_test`、`rdma_queue_backing_access_test`、`rdma_responder_registry_test`、reset integration suites | Batch91 focused、Batch101/103 reset integration 与 Batch104 current parent/core gate GREEN；UVM 0/0/0 | reset coordinator 跨 Function 的全目录生命周期复审及最终中文契约/所有权审查仍开放 |
| SQ payload transaction | Batch92 把 receipt/Function/SGE/mapping candidate staging 前移到 refs++/Host I/O 之前，并归一化外部 null status | `rdma_sq_payload_writer_test`、queue-data post paths | Batch92 focused GREEN；Batch89–93 后 parent gate GREEN | Host-memory partial write 后的补偿语义仍由 writer/adapter 契约维护 |
| CMQ poison/recovery contract | Batch93 校正 poison 的 FIFO 清理、diagnostic staging fallback 和 fail-closed 失败边界说明 | `rdma_cmq_engine_test`、`rdma_cmq_completion_test`、CMQ gate | Batch93 focused GREEN；parent gate GREEN（28/28、11/11、UVM 0/0/0） | 尚未加入同一 poll late-final+malformed CQE 的组合 fault fixture |
| codec/profile/wire | Batch9–26、68、72–75 的 tuple/profile/mask/CQE metadata 与 hostile factory fixture；Batch100 RC inline-SGB fixed-capacity guard（512B/32 chunks） | codec/profile/driver-field mutation tests、`rdma_defs`、`rdma_sq_codec_test`、`rdma_queue_codec_test`、`rdma_ud_urc_sqe_codec_test` | Batch100 focused GREEN（3/3 wrapper、PROCESS/LOGICAL PASS、UVM 0/0/0）；保留冻结 wire 坐标和 reserved bits | 不将结构重构扩大为 ABI/wire 修复；Phase 1C F2 更广泛的 sge_num/whole-plan 收口仍暂停 |
| Function context/binding | Batch87 候选式 build/reset/activate、identity consistency、owner handle 与 PCIe projection；Batch95 延迟 registration；Batch98 reset preflight；Batch101 跨 context prepare/commit 原子性 | `rdma_function_context_test`、`rdma_env_composition_test`、`rdma_device_env_test`、`rdma_reset_cascade_test` | Batch98 与 Batch101 focused integration GREEN，UVM 0/0/0；Batch101 关闭跨 context 半提交窗口 | reset coordinator 的全目录生命周期复审、当前源码的 parent/core 回归和最终注释审查仍开放 |
| SR-IOV/PCIe allocator | Batch87 null status、pre-existing ownership guard、BAR rollback、lease factory atomicity；Batch90 清理多 VF 失败时 `discovered` 部分输出并加入 VF1 注入 | `rdma_sriov_enumerator_authority_test`、`rdma_sriov_enumeration_test`、allocator focused | core authority GREEN；`pcie_work` integration 仍被外部锁阻断 | 不修改外部 pcie_work；需获批 snapshot 后再运行真实 integration |
| 外部环境与门禁 | dpu_common identity authority；VCS53 wrapper；manifest/style/diff gates；全目录中文契约 scanner | `scripts/run_vcs53.sh`、Python 292、manifest 22、`rdma_defs` 203、style、diff-check、5,286-method scanner | 当前源码静态门禁 GREEN；外部锁错误单独记录 | 任何 VCS 仿真必须继续在 53 主机登录 shell 执行；`pcie_work` 仍 OPEN |

## 证据索引

- 每批 focused 说明与 source/archive/log SHA 位于
  `.superpowers/sdd/2026-09-17-rdma-structural-refactor/task-cmq-batch*-*.md` 和
  对应 `evidence/batch*` 文件。
- 最新 Batch86 parent gate 见 `evidence/batch86.meta`；Batch87–93 的 authority、runtime、
  recovery、环境组合、SQ payload 和 poison 边界见 `evidence/batch87.meta` 至
  `evidence/batch93.meta` 及各自 artifact 清单/报告。Batch94–99 的 focused 证据、
  源码指纹和失败边界见 `evidence/batch97.*`、`evidence/batch98.*`、`evidence/batch99.*`
  及 `task-cmq-batch94*` 至 `task-cmq-batch99*` 报告。
- Batch100 的 RC inline-SGB capacity ABI 锚点、3 个 focused 日志和静态检查位于
  `.superpowers/sdd/2026-09-14-rdma-phase1c-abi-fixes/evidence/batch100-*`，报告为
  `task-cmq-batch100-phase1c-f2-report.md`；它只关闭本地容量拒绝缺口，不代表 Phase 1C F2
  全部收口。
- Batch101 的跨 context reset prepare/commit 日志和 artifact 指纹位于
  `evidence/batch101.*`，Batch102 的 QP/queue lifecycle alias 审计及静态检查位于
  `evidence/batch102.*`；两批报告分别为 `task-cmq-batch101-reset-atomicity-report.md`
  和 `task-cmq-batch102-qp-alias-audit-report.md`。Batch103 focused follow-up 与 Batch104
  current-source parent/core gate 日志位于 `evidence/batch103-*`、`evidence/batch104-*`。
- 当前源码最终静态证据位于 `evidence/final-static.meta`、`final-static-artifact-sha256.txt`、
  `final-static-python.log`、`final-static-cmq-manifest.log`、`final-static-style.log`、
  `final-static-diff-check.log`、`final-static-contract-scan.log` 和
  `final-static-rdma_defs.log`；全目录 scanner 覆盖 185 个 `.sv`、2 个 `.svh`、5,286 个
  function/task，0 diagnostics。冻结 ABI manifest 的摘要更新只反映当前源码字节，未改变 wire
  坐标或外部依赖。
- `pcie_work` 的正确 suite 阻断证据是
  `evidence/post-batch87-rdma_sriov_pcie_work-correct-blocked.log`；`rc=2` 只表示
  `external dependency is not approved: pcie_work`，不是 UVM 业务失败。

## 尚未关闭的验收项

1. Phase 1C F2 仍暂停于更广泛的 `sge_num` canonical-authority/whole-plan 收口；Batch100
   已在本项目 codec 内关闭 RC raw `INLINE_SGB` 的 `TPL=513 / SGE_NUM=33` 固定容量拒绝缺口，
   没有扩大数组或修改外部契约。详见 Batch100 报告与 phase1c evidence。
2. Batch99 最后源码边界的 parent/core gate 是 **pre-Batch101 inherited baseline**：
   `evidence/post-batch99-final2-cmq_gate-regression.log`（SHA-256
   `f8ee6a4ae9e2802c2eebf9d7c69a2103ba678d7f605adf57072efc74ff3f7283`），28/28 process、
   11/11 logical、28/28 UVM pristine；更早的 Batch93/99 gate 仅保留为历史边界证据。
   同一旧源码边界的 core regression 亦 GREEN：`evidence/post-batch99-final2-core-regression.log`
   （SHA-256 `c59989807df0feb7cc92e9b34cf0640190c7f0b521e864e7cff130e0e8a7a30b`），
   95/95 process、78/78 logical、95/95 UVM pristine；Batch104 已在 Batch101/102 后的当前
   源码边界重新验证 parent/core gate（CMQ 28/28 process、11/11 logical；core 95/95 process、
   78/78 logical；UVM pristine），因此旧 SHA 只作历史边界证据。
3. 全目录中文 function/task、文件头和静态门禁复审已在当前源码边界通过；仍需完成 reset
   coordinator 的更深生命周期/所有权语义复审，并在后续源码变化后重复这些门禁。
4. `pcie_work` external lock 仍为 OPEN；覆盖矩阵不替代真实外部依赖批准，在 lock 获批前
   SR-IOV integration 只能报告已知阻断，不能伪造 GREEN。

因此矩阵当前是“持续更新、计划 active”，不能据此把整份结构重构计划标记为完成。
