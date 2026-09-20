# RDMA CMQ contract foundation 验证记录

> 本记录只描述已实现的 CMQ contract foundation 和 gate 证据，不宣称已经接入
> Linux 内核驱动或真实 DUT。所有 wire 坐标仍以锁定的 0.1.34 驱动归档为准。

## 固定基线

| 项目 | 固定值 |
| --- | --- |
| driver archive | `dpu_kernel_rdma-version_0.1.34.tar(1).gz` |
| `RDMA_ARCHIVE_SHA256` | `c9d9286dde389f681f9bd1c29fff14f52c4c1ce11fa5f73a5f1f57da9f827522` |
| archive size | `289668` bytes |
| member count / list SHA-256 | `74` / `d27331088fff104e4f101357b7a0b490b1d33e66396cb060ec421cc94ab68797` |
| source manifest SHA-256 | `76bed8a53ace52a5a010347982904f0c6e2b251be6e611d518c24a862dbdbfe3` |
| C compiler | `/usr/bin/gcc`, `gcc 9.4.0`, `x86_64-linux-gnu`, 64-bit little-endian |
| Phase 1A approval | plan commit `00ac20e8db79a92a9bd7bc7700355e6b8f4cc1d1`, blob `c521b5fe81473d922d1a466d8ecc885bf3b1c899086e9543b4445518e526280b`, approver `ryan`, `2026-09-12T14:34:29Z` |
| approved decisions | `TASK8_FOUR_STATE_EFFECT=APPROVED`; `TASK9_EXECUTION_AND_DIGEST=APPROVED`; `TASK17_RESET_ORDER=APPROVED`; `TASK18_LEGACY_SEAM=APPROVED` |

外部依赖只按 `hw/rdma/external_dependencies.tsv` 中的 approved snapshot 使用；
`pcie_work` 仍是 `UNAPPROVED`，不会被 CMQ gate 自动发现或伪造为通过。

## 实现链与冻结语义

`rdma_cmq_engine_port_adapter` 将 production 请求路由到
`rdma_cmq_engine::execute_observed()`。每个调用返回 detached value；
`observation_status` 与普通 command status 分离，不能由空 ticket 或错误码推导
`attempt_effect`。跨 retry 的 `submission_effect` 按冻结 fold 规则累计，旧的
`HOST_VISIBLE`/`MMIO_VISIBLE`/`UNOBSERVED` 证据不能被后续
`PRE_SUBMIT_REJECTED` 覆盖。timeout ticket 进入 quarantine，迟到完成只产生诊断
而不返还信用；reset 使用 mutation-free candidate、failure-atomic backing release、
allocation-free journal commit 和 READY proof 顺序。

锁序固定为 `engine_lock -> scheduler Function transport lock`。MMIO observer 只能
更新预分配的 journal/index/cursor，不分配、等待、取锁、调用外部 service 或重入
engine。恢复映射必须重新认证 adapter-owned opaque allocation capability，公开
mapping 字段或 digest 相同也不足以证明同一次分配。

legacy `execute()` 仍暂时维护 `last_execute_no_submit_proven`，仅供以下三个尚未
迁移的 Phase 1B consumer 使用：

- `src/core/rdma_control_plane.sv`
- `src/core/rdma_queue_lifecycle_executor.sv`
- `src/core/rdma_qp_lifecycle_executor.sv`

production `execute_observed()` 不读写任何共享 `last_*` 字段；三处 consumer 完成
独立迁移后才允许删除 legacy accessor。

## CMQ gate 清单

`sim/cmq_gate.list` 的非注释行必须按以下顺序 exact-once 执行：

```text
rdma_cmq_engine_models_test
rdma_cmq_codec_test
rdma_cmq_completion_test
rdma_cmq_profile_test
rdma_doorbell_codec_test
rdma_doorbell_scheduler_test
rdma_queue_data_engine_post_test
rdma_cmq_engine_test
rdma_cmq_port_test
rdma_control_plane_cmq_engine_test
rdma_cmq_driver_field_mutation_test
```

`rdma_cmq_engine_test` 通过统一 logical runner 展开为十八个物理 process：base leaf
只承载 fixture 0–7，紧随的 base-suffix leaf 承载 fixture 8–15；capacity leaf 随后
从 fixture 16 开始。matrix leaf 仅承载 fixture 22–25，profile-wide CQE fixture
仍独占下一 process，retention-prefix 仍独占 rows 0..2，continuation 再承接 rows
3..14 与 fixture 28–29，随后 submission-profile leaf 独立承载 fixture 30–32。任一
process 的 simulator、summary 或日志检查失败都会使
logical gate 失败。mutation gate 还必须保持 `CQC_CREATE` request unsupported，并报告
其固定的 static/dynamic closed-evidence 计数。

## Fresh acceptance evidence

所有 VCS 命令只通过 53 主机的 login-shell `scripts/run_vcs53.sh` 执行。以下表格在
每次 fresh run 后填写完整命令、exit code、日志路径和 `UVM_WARNING/ERROR/FATAL`；
缺少摘要、出现 warning 或 VCS crash 都是 blocker，不能用旧日志替代。

| Scope | Command / log | Result |
| --- | --- | --- |
| focused queue/device publish | `SSHPASS=<runtime-only> ./scripts/run_vcs53.sh core rdma_queue_data_engine_device_publish_test`; `/tmp/rdma_engine_regression_20260916/02_rdma_queue_data_engine_device_publish_test.log` | PASS; `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0` |
| focused AEQE route | `SSHPASS=<runtime-only> ./scripts/run_vcs53.sh core rdma_aeqe_route_test`; `/tmp/rdma_engine_regression_20260916/03_rdma_aeqe_route_test.log` | PASS; `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0` |
| focused CQ/EQ/RQ/SQ facades | logs `/tmp/rdma_engine_regression_20260916/04_rdma_cq_engine_test.log` through `07_rdma_sq_engine_test.log` | PASS; each `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0` |
| local static gates | `python3 -m unittest ...`; `python3 tools/check_queue_lifecycle.py`; `python3 tools/check_changed_sv_style.py --base HEAD`; `git diff --check` | PASS at last recorded run; rerun before acceptance |
| final CMQ gate | `scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test`; `scripts/run_vcs53.sh cmq_gate regression` | PENDING fresh run |
| compatibility/full core | host_mem, integration, focused consumers and `scripts/run_vcs53.sh core regression` | PENDING fresh run |

## Explicit follow-up boundaries

本记录不把以下工作混入 CMQ contract foundation：

- MR control-plane、queue lifecycle、QP lifecycle 的 Phase 1B legacy consumer 迁移；
- CQC embed-at-8、OCC、AEQ/CEQ/CQE/RQE/QPC 等 wire 修复和其他 engine 重构；
- snapshot、ring、ledger 的物理抽取（CMQ Phase 2）；
- queue-data、queue-runtime、resource-manager、control-plane 和 lifecycle engine 的
  独立 spec/plan；
- Linux uverbs/ioctl/libibverbs 或真实 DUT 接入。

这些边界必须另立设计、测试和 approval，不得为了让本 gate 通过而放宽原始驱动
reserved mask、改变字段坐标或删除失败测试。
