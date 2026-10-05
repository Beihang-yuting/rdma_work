# CMQ Batch 87：SR-IOV、allocator 与 Function context authority 原子性

本批承接 Batch86 的结构复审，集中修复三个边界：SR-IOV enumerator 的外部
PCIe status/既有 ownership/失败回滚，PCIe BAR allocator 的 UVM factory 原子性，
以及 Function context/binding 的候选式 identity、binding 和 owner handle 发布。
本批只修改本项目；没有修改 `dpu_common`、`pcie_work` 或 Host-memory 外部仓库，
没有提交、reset、clean、merge 或 push。

## 实现边界

- `rdma_sriov_enumerator` 将 PCIe/allocator 的 null status 统一转换为
  `RDMA_SC_INVALID_STATE`，在任何 BAR/Control/NumVFs 写入前拒绝已有
  `num_vfs`、`vf_enable` 或 `vf_mse` 的 PF；失败路径按 valid 位恢复已读到的 PF/VF
  BAR low/high DWORD，再逆序释放本次 lease。
- `rdma_pcie_bar_allocator` 使用 raw factory + 显式 `$cast`/exact-type 检查；
  null 或错误 lease subtype 不会改变 `m_leases`、`next_lease_id` 或 output lease。
  status factory 失败时采用等值的本地 fallback。测试在无原始 override 时用 report
  catcher 抑制 UVM `TYPDUP` 清理提示，并确认故障 wrapper 不再留在全局 factory。
- `rdma_function_context` 的 build/build_shared、activate、reset 均先完成候选
  factory/clone/configuration，再发布 context identity、binding、owner handle 和
  state；显式 source binding 还必须与 source identity 的完整 incarnation 一致。
- `rdma_function_binding` 的 handle/PCIe projection factory 失败保持旧值图不变，
  `make_handle()` 对 null factory 结果 fail-closed。

## 源码边界

以下哈希是本批验证边界的 SHA-256；对应 Git blob SHA-1 同步记录在
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch87.meta`。

| 文件 | 行数 | SHA-256 |
| --- | ---: | --- |
| `src/core/rdma_sriov_enumerator.sv` | 712 | `4346d34393c65277618b4f2c292d2886f2f2baee0744e9134bfd755cdf3205ec` |
| `src/core/rdma_pcie_bar_allocator.sv` | 353 | `44749d9fba9e91e681add1b4bf7c227ea6e1df2bf12fcb315a07c039d5135662` |
| `src/integration/rdma_function_context.sv` | 340 | `09083636eacf366bae2010fcacaf266d370d775d46a21d6024a60f7a205bf72a` |
| `src/model/rdma_function_binding.sv` | 945 | `ec5a2b37dcb11e4a984e4901ae8d771139b212f0e93fa8e03b2f4e0e1e7aa887` |
| `tests/integration/rdma_function_context_test.sv` | 355 | `28c5347744be84bc3878a78ee5fa7514c51444ea7590a76290764b2d78575a69` |
| `tests/integration/rdma_sriov_enumeration_test.sv` | 662 | `0bfb2770b3e98cecf1805f12e70cf377e7807e77c891bc545083ba6c4d165d59` |
| `tests/unit/rdma_sriov_enumerator_authority_test.sv` | 494 | `cf1ba01591989177860d16a7753456dae5b184d0c9fad05e1088cb4b9cf6e565` |

## 验证

所有 VCS 命令均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 的登录 bash
环境执行。fresh 日志和 SHA 位于 evidence 目录；旧的失败日志没有覆盖。

| 测试/检查 | wrapper | 结果 |
| --- | ---: | --- |
| `core rdma_sriov_enumerator_authority_test` | 0 | PROCESS/LOGICAL 1/1；UVM warning/error/fatal 0/0/0；含 null-status、三种 pre-existing SR-IOV guard、allocator null/wrong-subtype 与 factory restore |
| `core rdma_env_composition_test` | 0 | UVM pristine 0/0/0 |
| `integration rdma_function_context_test` | 0 | UVM pristine 0/0/0 |
| Python unit discovery | 0 | 292 tests OK |
| CMQ manifest | 0 | 22 tests OK |
| changed-SV style | 0 | 仅既有 `rdma_cmq_body_value_contract.sv:303` soft-limit hint |
| `git diff --check HEAD` | 0 | clean |

`pcie_work` integration 也用正确的 `pcie_work` suite 和
`PCIE_WORK_ROOT=/home/ubuntu/pcie_work_ryan`、`HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem`
执行；wrapper rc=2，唯一阻断为 `external dependency is not approved: pcie_work`。
该阻断属于仓库外锁策略，未计作生产代码测试失败，也未修改外部依赖锁。

本批不宣称整份结构重构计划完成。Phase 1C F2（`TPL=513 / SGE_NUM=33` capacity
gap）、Batch88 后续 runtime seam、覆盖矩阵和最终全目录中文契约/所有权复审仍开放。
