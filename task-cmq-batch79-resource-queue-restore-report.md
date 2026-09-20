# CMQ Batch 79：resource-manager queue restore authority seam

本批只修改 `src/core/rdma_resource_manager.sv`，保留工作树中的其他既有未提交改动；不
修改测试、外部依赖，不提交或 push。目标是把 `restore_active` 的 lifecycle-queue
`ERROR` 分支中的只读 recovery/authoritative queue-plan authority proof 收敛为一个
明确边界，同时保留 replacement 投影、SRQ flush 复位、validate 和最终发布流程。

## 实现

新增 protected helper：

`queue_restore_authority_status(authoritative, recovery)`。

helper 保留原拒绝顺序和错误文本，依次完成：

- recovery null、`queue_recovery_valid`、hardware presence、ambiguous ticket、queue
  plan/kind shape；
- recovery context/ref 的 destructive local cleanup 扫描；
- authoritative queue cast、queue-plan/ref cardinality 与 context nullness；
- 每个 backing role 的唯一匹配、cleanup/value/mapping ACTIVE authority；
- control-plane-owned backing 的 same-owned authority、recovery→authoritative opaque
  release 查询，以及 additional segment 的 null/mapping/state/query 检查；
- context release/HMC null、release、address、size、first-PBL、index-valid authority。

helper 只读取快照并查询 opaque release completion，不修改 registry、recovery、queue
plan、mapping、SRQ flush progress，也不取得外部资源所有权。

`restore_active` 仍在 helper 前执行 staged allocation/recovery-record 存在性门禁；helper
成功后，原有 `project_recovery_value`、ambiguous 字段清除、SRQ flush-bit reset、
`recovery_replacement.validate()`、queue plan projection、observer、最终 resource
validate 和 registry/recovery 发布顺序全部保持 inline。

## 精确边界

- source before SHA-256：`27932c898e9bb6cbeecaaadf5a7ae62e1a552ed6f83d5422eb8079536ff8516b`
- source after SHA-256：`ea888b4b513ddd4a848050172d4054d826396c5d79535f8e1fd38fa18c4b9660`
- source lines：`8537 -> 8565`
- 精确 diff SHA-256：`9dc2b9724864169de5497ae9f21eb6b81699f4ba3ea0387ed5a74a10bbba77b3`
- 精确 diff：338 行；archive diff 仅包含目标源码文件中的一个 helper 插入和一个
  queue `ERROR` caller 替换。

before/after source archive、archive validation、diff reproduction、source review 和
测试日志位于：
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch79-*`。

## 验证

所有仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 测试 | wrapper | logical/physical | 严格 UVM（warning/error/fatal） |
| --- | --- | --- | --- |
| `rdma_resource_manager_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_lifecycle_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_recovery_test` | 0 | 1/1 | 0/0/0 |

静态检查：

- `python3 tools/check_changed_sv_style.py --base HEAD`：rc 0；仅保留既有
  `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit 提示；
- `git diff --check -- src/core/rdma_resource_manager.sv`：rc 0；
- before/after archive member hash 与精确 diff hash 校验一致，diff reproduction 通过；
- helper 的中文“功能 / 输入输出及副作用 / 失败边界”契约、拒绝顺序、所有权与
  replacement/publication 边界已记录在 `batch79-source-review.log`。

本批不标记整个结构重构计划完成；完整 gate 和最终全目录注释/所有权复审由主代理统一
安排。
