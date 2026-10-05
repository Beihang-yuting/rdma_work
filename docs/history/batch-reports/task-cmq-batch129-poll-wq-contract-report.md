# CMQ Batch 129：CQ poll WQ target contract selector/validator 提取

本批继续基于 Batch128，把 CQ poll 的 WQ target authority 从单一 resolver 拆成可复用的
只读 selector 与 validator。目标是让冻结 CQE/link 推导、attachment geometry/role
校验和 staged-output 的 canonical relookup 使用同一份 contract，同时把
`pending.completion_wq_kind` 降级为待验证的派生字段；不改变首次 runtime mutation、
CQ consumer commit 或 CQ→WQ release 的既有顺序。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护 `select_cq_poll_wq_target_contract()`：仅依据冻结 `cqe.rq_cqe`、
    `link.qp_h` 与 `link.srq_h` 推导 target handle、`rdma_queue_runtime_kind_e` 和
    `rdma_queue_backing_role_e`。send CQE 选择 QP/SQ，receive CQE 在私有 RQ 与共享
    SRQ 间分支；该 selector 不查询 attachment/runtime，不推进 cursor，不创建 pending，
    不写 ledger、Host-memory 或 MMIO。
  - 新增共享只读 `validate_cq_poll_wq_attachment()`：统一检查 target resource kind、
    attachment/runtime/access 非空、非零 depth、`RDMA_WQE_BYTES` entry geometry、
    runtime kind/backing role 以及 `same_handle_instance()` 的完整 handle incarnation。
    它只返回 status，不取得 queue/backing/外部资源所有权。
  - `resolve_cq_poll_wq_target()` 改为 selector→attachment lookup→validator；原有
    authority-first 顺序保留，target contract 校验仍先于 release-range snapshot。为兼容
    simulator 的 class-handle output 复制差异，resolver 在当前 frame 对 selector candidate
    做完整 incarnation 比较；null 或错误 incarnation 时从冻结 `link.qp_h`/`link.srq_h`
    回填 canonical handle，再执行 lookup/validator。
  - `poll_cqe_once()` 在进入 `enter_recovery_prepared()` 前重新从冻结 CQE/link 推导
    expected target，拒绝 `pending.completion_wq_kind` 与冻结 kind 不一致；staged
    attachment 先由共享 validator 校验，失败后按相同 target/kind canonical relookup
    并再次使用同一 validator；selector output 本身若为 null/错误 incarnation，也会在
    admission frame 从冻结 link canonicalize。所有检查失败均在首次 runtime mutation 前返回。
- `tests/unit/rdma_queue_data_engine_post_test.sv`
  - 在既有 probe 中增加 test-only `probe_validate_cq_poll_wq_attachment_fixture()`，
    覆盖正常 SQ、`runtime.depth=0`、`entry_size=32`、错误 backing role 和 stale
    `queue_h.generation` 五种 contract；每次注入后恢复 attachment 字段，不改变 fixture
    的 queue/runtime/mapping 所有权。
- `tests/unit/rdma_queue_data_engine_poll_test.sv`
  - 增加 `check_cq_poll_wq_attachment_validator()`，通过 `use_prepare_probe=1` fixture
    逐项断言 fault 0 为 `RDMA_SC_OK`、fault 1/2/3 为 `RDMA_SC_INVALID_STATE`、fault 4
    为 `RDMA_SC_STALE_GENERATION`；任务不提交 CQE、不推进 cursor、不写 Host-memory/MMIO。

## 保持的不变量与首错顺序

- target authority 来自上游已按 wire QPN 与 CQ route 冻结的 `link`；`cqe.qp_h` 不作为
  第二条可变 authority，避免 model handle 绕过 canonical route。selector 只做 target
  contract 推导，CQ route/epoch admission 仍由 caller 负责。
- selector 的跨 function class-handle output 只是候选；生产 resolver 与 poll admission
  都会以冻结 link 做 null/完整 incarnation canonicalization，因此 simulator output 丢失或
  携带错误 generation 不会改变 release authority，也不会让 pending kind 取得 authority。
- `pending.completion_wq_kind` 不能覆盖冻结 target；kind 漂移在 admission 前 fail-closed。
  staged attachment 与 canonical relookup 共享同一个 validator，避免首次 resolver 和
  admission 使用不同的 geometry/role/incarnation 门禁。
- 目标 authority/geometry 门禁保持先于 `snapshot_release_range()`；本批不改变
  `enter_recovery_prepared()` 是 live poll 首个 runtime mutation 的约束，也不改变
  shadow/doorbell→CQ commit→CQ→WQ release→completion 的顺序。
- selector、validator 与 probe 均不复制或改写 runtime ledger，不取得外部 PCIe、
  Host-memory、network 或 queue backing 生命周期；外部依赖 `pcie_work` 未修改。

## 验证

所有已执行 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 入口完成；当前工作树已知结果如下：

| 入口/门禁 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_post_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `rdma_queue_event_route_consume_test` / `rdma_aeqe_route_test` | 均 PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `git diff --check` | PASS |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| 全目录中文契约/文件头 scanner | 185 个 `.sv`、2 个 `.svh`（187 files），5,416 methods（`.sv` 5,414、`.svh` 2），0 diagnostics |
| CMQ manifest / SV keyword / queue-profile / Phase-1A / Python | 22/22、3/3、PASS、PASS、292/292 |

## 源码指纹

以下 SHA-256 是本报告写入时工作树的快照；若后续修复 class-handle 边界，必须随报告和
覆盖矩阵一并刷新：

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `481c650da99d72e4d58d173a7e023074f81e19c24fb1a98265de8dd23dbfb1c7` |
| `tests/unit/rdma_queue_data_engine_post_test.sv` | `4e2737089818e7a07b7f8005d2c97befdc13297b509c712d0efdd9b7e83dec40` |
| `tests/unit/rdma_queue_data_engine_poll_test.sv` | `95b90b28f9c41d528f4a994cfaca2db0300c894d2628e57d9f22e78d0f47fde7` |
| `docs/rdma-structural-refactor-coverage-matrix.md` | `9aea9010321258c57a1f420b97057555c6ff0f1879ce6dba7daf4752aa28ea15` |
| `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md` | `cdc7d5cdd53d85337703b661de465d3a605813b411d48ba03162bb97e666fdbb` |

相对 Batch128，本批新增 selector、共享 validator 和一个 test-only probe，并把 poll
admission 的 staged/canonical attachment 校验收束为同一 contract；本批不代表 RQ/SRQ
与 UD 正向 poll、legacy descriptor、CEQ/AEQ malformed retry、engine-level 全局锁、
跨队列并发、广义 Phase 1C F2 或整份 structural refactor 已完成。

## 遗留边界与复审记录

- `select_cq_poll_wq_target_contract()` 通过 `output rdma_handle` 跨 function 传递 class
  handle。VCS53 当前 focused 测试通过，但 simulator 在跨边界复制 handle 时的 incarnation
  保真性仍需独立证据；生产 resolver 与 poll admission 已在当前 frame 依据冻结
  `link.qp_h`/`link.srq_h` 对 null/错误 incarnation 做 canonicalize，因此该 simulator
  风险不会把错误 output 交给 release，也不能退回信任 pending kind。
- 当前 hostile test 直接调用共享 validator，尚未强制 staged output 失真后真正进入
  `poll_cqe_once()` 的 canonical-relookup 分支；生产 fallback 已落地，但仍应补充完整
  admission fixture 取得端到端故障证据。
- `stage_cq_poll_candidate()` 仍在二次 validator 前生成 release-range snapshot；若要
  覆盖错误 runtime 但 metadata 相同的恶意 alias，需要额外审计 snapshot 与 canonical
  attachment 的一致性及首错优先级。
- probe CQE 未设置 `cqe.qp_h`。这是有意保持 target authority 来自上游冻结 link 的
  最小 fixture，但后续可增加 detached QP handle clone 以提高 fixture 逼真度；不应因此
  把 `cqe.qp_h` 当成第二 authority。
- 已复审本批修改涉及的 engine poll 入口、selector/validator、probe 与 focused test
  注释/所有权边界；全目录 scanner、device-publish 回归和 manifest/keyword/queue/profile/
  Phase-1A/Python 静态门禁均已在当前源码边界通过。计划与覆盖矩阵仍必须保持 `active`，
  因为上述 hostile fixture、snapshot alias、RQ/SRQ/UD 全矩阵与更深并发/所有权边界尚未关闭。
