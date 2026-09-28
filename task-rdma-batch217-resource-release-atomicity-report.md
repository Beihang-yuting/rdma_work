<!-- 目录：项目根目录；职责：记录 Batch217 恢复/释放原子提交与验证证据。 -->

# Batch217：恢复与释放提交边界

日期：2026-09-28。工作树：`feature/rdma-cmq-structural-phase2-batch160`。
计划仍为 active；未 commit、merge、push、reset 或 clean。

## 本批实现

- `restore_active()` 和 `mark_error_transition()` 复用已有双账本 helper。
  restore 在 recovery schema 规范化后更新 recovery source，但 epoch/resource 在此前冻结，
  所以后续 authority、completion、clone 和 observer 重入不能被末尾重新取快照掩盖。
- `commit_resource_releases()` 统一单资源 finalize/reservation 与 Function teardown。
  caller 在 admission 前冻结 epoch；helper 在同一 guard 内先检查整批 key/local ID，
  再同步删除 registry/recovery/staged、归还 ID，并可提交 generation retirement。
  第二项冲突不再留下第一项已删除的半提交。incarnation tombstone 和外部 ownership 不变。
- `lookup()` 不再回写 registry；两次 detached 投影完成后复核 source/epoch，
  成功才输出 resource，避免读取隐式覆盖后来的状态。
- `clear_recovery()` 将 source/epoch 捕获前移到 recovery-ready 判断之前。
- 非零 local ID 的未 staged MR 过去以默认 lkey=0 发布 ERROR，会被 MR key-index
  校验拒绝。本批在 reservation 时初始化 lkey index，低 8 位 key byte 保持零；
  不申请硬件 key，也不允许 ALLOCATED/ERROR MR 进入数据面。

## 新增动态覆盖

`rdma_resource_manager_test` 新增以下契约：

1. lookup 输出 detached，不替换 canonical registry 引用或推进 epoch。
2. release commit guard busy、旧 epoch、重复 key、第二项 free-list 冲突均全量拒绝。
3. Function teardown 冲突不部分回收、不提前退休；修复 fixture 后可重试。
4. 释放成功只推进一次 epoch、ID 恰好回收一次、local ID 可复用而 incarnation 不复用。
5. staged MR 的 ERROR publication 锁忙不清 staged、不产生 recovery-only 半提交。
6. owned mapping 的真实 completion hook 推进 manager epoch，restore 和 reserved ERROR
   completion 均拒绝旧 admission；同一请求撤销注入后可以重试。
7. SRQ 恢复最终 observer 注入 epoch、guard、registry source、recovery source 四种冲突，
   ERROR、ambiguity 和 flush 进度保持；随后正常 restore 清除进度和 recovery。
8. reserved ERROR 使用第二个 MR（local ID 非零），覆盖默认 key-index 缺陷。

## 验证进度

- 早期重入 focused：`/tmp/rdma_batch217_manager_reentry.log`，RED。
  4 个 UVM_ERROR 来自非零 MR local ID 的 ERROR publication 失败及后续级联断言；
  不将此日志记录为通过。随后修复 reservation key-index。
- core 全量：97/97 PROCESS、80/80 LOGICAL、97 pristine，wrapper rc=0，
  `/tmp/rdma_batch217_core_regression.log`。
- integration：10/10 pristine，wrapper rc=0，
  `/tmp/rdma_batch217_integration_retry.log`。
- CMQ gate：28/28 PROCESS、11/11 LOGICAL，wrapper rc=0，
  `/tmp/rdma_batch217_cmq_gate.log`。
- Host-memory：3/3 pristine，`/tmp/rdma_batch217_host_mem_retry.log`；
  PCIe adapter：1/1 pristine，`/tmp/rdma_batch217_pcie_work_pinned.log`，两项 wrapper rc=0。
- E2E dual-env、多 VF recovery、高流量：3/3 pristine，三个 wrapper rc=0，
  `/tmp/rdma_batch217_e2e.log`、`/tmp/rdma_batch217_e2e_multivf.log`、
  `/tmp/rdma_batch217_e2e_traffic.log`。
- 驱动契约：203 项 checker 自测、真实归档、CMQ C oracle 和字段 ownership 校验通过，
  `/tmp/rdma_batch217_driver_contract.log`，wrapper rc=0。
- Python 全量最终复跑：293/293，`/tmp/rdma_batch217_python_final.log`。
- changed-SV style、diff、queue lifecycle、profile naming、Phase-1A：通过。
- 全 src 机械契约扫描：117 个 .sv / 2,788 methods / 0 diagnostics，
  `/tmp/rdma_batch217_contract_scan.log`。此扫描只检查文件头和逐函数三段标签，
  不等价于注释语义或全项目 ownership 已经人工验收。

所有上述 VCS 验证均通过 `scripts/run_vcs53.sh` 在 53 主机登录 bash 中执行；
通过用例的 UVM WARNING/ERROR/FATAL 全为 0/0/0。E2E 编译保留外部依赖原有的
FLWI / SV-ANDNMD 编译警告，不将“UVM pristine”表述为“编译零警告”。

### 预检拒绝与只读依赖选择

- integration 首次未传 DPU_COMMON_ROOT，预检退出；补齐既有 pinned 路径后通过。
- `/home/ubuntu/workspace/host_mem` 存在 source hash drift，预检正确拒绝；
  使用已有 `/home/ubuntu/workspace/host_mem.audit.current` 通过锁定校验。
- PCIe 的 `pcie_work.audit.current` 含两个未跟踪仿真输出，clean-tree 门禁拒绝。
  未删除这些文件；改用已有的干净 `/home/ubuntu/workspace/pcie_work_audit.POaPmh`，
  锁定 commit 为 `1a80801e7d336ceeb492e7cdf57ba26ef27c2456`。
- E2E 另消费 `/home/ubuntu/net_packet_latest` 与
  `/home/ubuntu/deps_virtio/dpu_common`，均通过现有依赖锁预检。
- 未修改任何外部源码、lock manifest 或依赖仓库状态。

### 最终源码指纹

- `src/core/rdma_resource_manager.sv`：
  `fa1c2639a0b499f61db0db53ec3ad753612045e3b3c8e276c67249278193c80b`。
- `tests/unit/rdma_resource_manager_test.sv`：
  `c145e6491449ef12fb10a7e1d86b89ef253d6481095d5ea0b9f6a9eb09e35adc`。
- core 全量启动后仅补充了 create_mr 中文说明及测试 observer 的无操作 default 分支；
  最终指纹另由 manager focused 复跑验证，日志为
  `/tmp/rdma_batch217_manager_verified.log`（PROCESS/LOGICAL PASS、UVM 0/0/0、wrapper rc=0）。

## 复审和剩余边界

本批复审 manager 文件入口、schema/projector、lookup、所有释放 caller、双账本 commit
及相关测试 fixture，修正所改函数中错误的 PI/CI、测试 trace 等模板说明。
未改外部依赖、硬件编码、CMQ 提交顺序或 dataplane。

仍需继续：普通 registry replacement 的 9 个生命周期 caller 尚未全部强制提供 OCC
snapshot；更广的 allocator 重入/补偿、queue 跨 owner 原子性、SRQ 完整业务组合、
Phase-1C F2 whole-plan、legacy/external ordering/error 和包 DAG 迁移未关闭。
现存大文件和历史泛化注释也不能因机械检查 GREEN 而视为可读性目标已达成。

下一批已经定位到具体 caller：`stage_allocated`、`attach_cq_programming`、
`commit_programmed`、`activate`、`begin_quiesce`、`begin_cq_resize`、
`replace_active_cq`、`attach_qp_programming`、`commit_qp_semantic_state`。
它们目前调用 `commit_registry_replacement` 时沿用可选 snapshot 的默认关闭值；
后续应统一要求 source/epoch，删除内部 helper 的可选绕过模式，而不是为每个业务
另建一个只有单函数的 policy 文件。QP exact-old recovery 路径须独立保留错误优先级。
