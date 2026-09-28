<!-- 目录：项目根目录；职责：记录 Batch218 registry 强制快照提交与验证边界。 -->

# Batch218：统一 registry 快照提交契约

日期：2026-09-28。工作树：`feature/rdma-cmq-structural-phase2-batch160`。
本批未 commit、merge、push、reset 或 clean；项目级重构仍 active。

## 实现范围

`commit_registry_replacement()` 的 epoch/source 改为必填参数，删除
`check_snapshot=0` 可选绕过。保留原有唯一 owner 和 mutation guard，不增加 policy 文件、
持久账本或生产测试 observer；11 个 caller 使用同一提交接口。

补齐的九个入口：stage_allocated、attach_cq_programming、commit_programmed、activate、
begin_quiesce、begin_cq_resize、replace_active_cq、attach_qp_programming、
commit_qp_semantic_state。它们在首次外部投影/schema/lookup 前捕获 epoch，lookup/schema
完成后捕获 canonical source；后续 validate/clone/completion 重入不能被重新采样掩盖。
既有 track_outstanding/retire_outstanding 只调整 helper 参数，原 admission 不变。

QP exact-old recovery 仍只在 lookup 返回 STALE_GENERATION 且 registry 保留同一旧
incarnation 时进入；source 在 fallback projection 前冻结。保留候选错误、lookup 错误、
fallback projection 错误先于最终 OCC 的顺序；不扩大旧句柄正常使用权限。

更新所改入口的具体中文契约，删除误称更新 PI/CI、绑定 adapter 的历史模板说明。
此批以统一强制契约消除安全例外，不声称 manager 的万行规模已经完成收缩。

## 验证设计

`check_registry_transition_windows()` 创建九个入口和独立旧代际 QP 场景：

- 先运行正常流程计数真实 CQC clone/mapping authority/completion 回调；逐个回调注入 epoch 更新。
- 最后一个回调另注入 guard busy；在已读取 source 的路径独立注入等值 source 替换，
  不推进 epoch，避免仅靠 epoch 测试掩盖引用门禁缺失。
- 检查生命周期、staged、recovery 数量、QP plan/QPC、semantic state、CQ CQC 和 epoch。
- 验证失败可重试、成功恰好推进一次 epoch；旧 QP 重复附着拒绝，已移除旧 incarnation
  保留 STALE_GENERATION。

最终十个场景观测到的回调窗口依次为 2/1/3/3/4/4/3/2/6/2，共 30 个；
动态覆盖 30 次 epoch 冲突、10 次 guard 冲突、7 次 source 冲突，以及正常提交/重试。

初次 fixture 缺少 CQ 的 CEQ 依赖，在成功基线的 validate 阶段返回 INVALID_ARGUMENT，
未进入故障窗口；已补齐 CEQ 和 CQC CEQ local handle。失败日志保留，不算通过：
`/tmp/rdma_batch218_manager.log`，以及同一旧 fixture 的首次 core 日志
`/tmp/rdma_batch218_core.log`。

第二次 `/tmp/rdma_batch218_manager_retry.log` 已通过七个 CQ 场景，但 QP 的基线没有
completion 回调，测试以“无有效注入窗口”fatal 退出（0 error/1 fatal）。QP 真实投影
使用 snapshot_release_authority，随后将测试计数/注入接入此契约；不在生产代码增加 hook。
最终 focused 的十个场景全部通过，不把第二次日志冒充成功证据。

## 最终验证结果

- 资源管理器 focused：PROCESS/LOGICAL PASS、UVM 0/0/0、wrapper rc=0，
  `/tmp/rdma_batch218_manager_final.log`。
- core 全量最终源码复跑：97/97 PROCESS、80/80 LOGICAL、97 pristine、wrapper rc=0，
  `/tmp/rdma_batch218_core_final.log`。
- integration：10/10 pristine、wrapper rc=0，`/tmp/rdma_batch218_integration.log`。
- CMQ gate：28/28 PROCESS、11/11 LOGICAL、28 pristine，wrapper rc=0，
  `/tmp/rdma_batch218_cmq.log`。
- E2E dual-env、多 VF recovery、高流量：3/3 pristine、wrapper rc=0，
  `/tmp/rdma_batch218_e2e.log`、`/tmp/rdma_batch218_e2e_multivf.log`；
  高流量 `/tmp/rdma_batch218_e2e_traffic.log`。
- 驱动契约：203 项自测、真实归档、CMQ C oracle 和 field ownership 通过，wrapper rc=0，
  `/tmp/rdma_batch218_driver_contract_retry.log`；首次传 regression
  被 Make 参数门禁拒绝（`/tmp/rdma_batch218_driver_contract.log`），未执行仿真。
- Python：最终复跑 293/293，wrapper rc=0，`/tmp/rdma_batch218_python_verified.log`。
- Host-memory 3/3、PCIe adapter 1/1 pristine，两个 wrapper rc=0：
  `/tmp/rdma_batch218_host_mem.log`、`/tmp/rdma_batch218_pcie_work.log`。
- changed-SV style、diff、queue lifecycle、profile naming、Phase-1A：通过；
  style 的既有 soft-limit 提示不等价于可读性验收。
- src 与 tests/unit 全量机械契约扫描：191 个 `.sv`、5,241 methods、0 diagnostics，
  `/tmp/rdma_batch218_contract_verified.log`。只检查文件头和三段注释标签，不能替代语义复审。

所有 VCS 使用 53 主机登录 bash 与隔离目录；依赖继续使用既有 pinned 只读副本，
不修改 dependency lock 或外部仓库。Batch217 的完整通过证据独立保留，不能代替本批验证。
E2E 编译仍含外部依赖既有 FLWI/SV-ANDNMD 警告；UVM pristine 不代表编译零警告。

依赖路径沿用 Batch217：HOST_MEM_ROOT=`/home/ubuntu/workspace/host_mem.audit.current`、
DPU_COMMON_ROOT=`/home/ubuntu/deps_virtio/dpu_common`、
NET_PACKET_ROOT=`/home/ubuntu/net_packet_latest`、
PCIE_WORK_ROOT=`/home/ubuntu/workspace/pcie_work_audit.POaPmh`，均通过现有 dependency lock。

最终生产源码 SHA256：`ac7797e7202db523dadd8d973e3715c1a86384a799a0ca9ec7f1a2a6ebfe3890`；
测试源码 SHA256：`4dd4c04932c7dc4b89764162f3485cb0df0ed729d8319663095c879daf60e828`。
focused/core-final 使用这组指纹。integration/CMQ/E2E 编译的生产源码与此一致；早启动的
integration/CMQ/dual-env 在测试 fixture 收尾前启动，不承担新单测最终覆盖的证明。

本批复审文件入口、11 个 replacement caller、schema/lookup 的 source 捕获顺序、
exact-old QP fallback、最终 guard 内外的调用边界和全部新增测试 fixture；另对 src 与
tests/unit 做全文件头/逐方法标签扫描。全项目注释语义与 ownership 的人工验收仍未完成，
不把机械 GREEN 或本批测试通过泛化为全部代码质量目标已完成。

## 剩余工作

下一批 allocator 补偿需要首先刻画“同 kind 后续 reservation/publication 已成功，旧
candidate 因 stale epoch 回滚”的场景：当前 rollback_local_id_reservation 的递减游标、
rollback_identity_reservation 的 prior_serial 回写、rollback_binding_registration 的删除
必须验证不会撤销后来的资源权威。单纯增加一个 guard 不能消除跨外部窗口的补偿风险。

跨 queue/owner 原子性、SRQ 全业务组合、Phase-1C F2、legacy/external ordering/error、
包 DAG 和历史泛化注释语义审计仍 OPEN；本批不作为整体重构完成证据。
