# CMQ Batch 99：queue context progress authority/parity

本批修复 `rdma_resource_manager::record_queue_context_cleanup_complete` 在
ERROR queue 下对 recovery `context_ref` 的无条件解引用，并把 context cleanup
进度收敛为两侧 detached snapshot 的只读 authority admission。新增
`queue_context_progress_authority_status` 先检查 authoritative/recovery
`context_ref` presence parity，再检查 slot-token cast、共享
`completion_authority`、Function owner、resource kind/local ID、shadow geometry
和 HMC canonical 值；任一拒绝都发生在 `commit_queue_progress` 之前，因此不会
发布单侧 `release_complete`。

## 变更边界

- `src/core/rdma_resource_manager.sv`
  - 无 recovery 时保持 authoritative context 缺失/已完成的
    `RDMA_SC_INVALID_ARGUMENT` 语义。
  - recovery context 缺失、已完成、token/authority 不合法或 authority 漂移时
    返回明确 `RDMA_SC_INVALID_STATE`；authoritative token 本身不合法时返回
    `RDMA_SC_INVALID_ARGUMENT`。
  - 只有 helper 成功后才在 detached resource/recovery candidate 上同时置位，
    再由 `commit_queue_progress` 原子发布。
- `tests/unit/rdma_resource_manager_test.sv`
  - 增加 detached recovery context、mismatched completion authority 的故障
    注入和恢复 fixture。
  - 断言拒绝后 registry/recovery context progress 保持未完成，并保留既有成功
    路径的双侧完成断言。

## 源码指纹

| 文件 | SHA-256 | 当前工作树 blob SHA-1 |
| --- | --- | --- |
| `src/core/rdma_resource_manager.sv` | `248df15122b394ea10d31672c022cdad7a2433cec2707c0ba285f93c97bc888f` | `52e64562156960a7f604c7c577a5013f8a9e51f6` |
| `tests/unit/rdma_resource_manager_test.sv` | `0f900701c60e3cfc08abcb4156ae7f50a557d677851128afda309a1a2b562c7a` | `c0c89356e0631e47047b12a0ccbbc8106de841dd` |

## VCS53 focused verification

以下命令均在 `ubuntu@10.11.10.53` 登录 bash 环境由
`scripts/run_vcs53.sh` 执行，wrapper rc 均为 0；每个测试均为
PROCESS/LOGICAL 1/1，UVM warning/error/fatal 为 0/0/0。

| 测试 | evidence | SHA-256 |
| --- | --- | --- |
| `rdma_resource_manager_test` | `evidence/post-batch99-final-rdma_resource_manager_test.log` | `3a5eb495fa8b73d562d4b8ce0658a9671dce4aa4db739f3333caf1330025efd0` |
| `rdma_queue_lifecycle_test` | `evidence/post-batch99-rdma_queue_lifecycle_test.log` | `4d3c1f57bab4e09a921278d699959ab539a2a3303272121c136949afc3758c00` |
| `rdma_queue_recovery_test` | `evidence/post-batch99-rdma_queue_recovery_test.log` | `a2ad552735881eb7ad8d2c128aba64974364d5fcbbd1ab932777155e42849eb8` |

## 静态检查

- `python3 tools/check_changed_sv_style.py --base HEAD`：rc=0；仅保留既有
  soft-limit 提示（`rdma_cmq_body_value_contract.sv:303` 及已有长行）。
- `git diff --check HEAD`：rc=0。
- 未修改外部依赖；未执行 commit/reset/clean/merge/push；未更新 progress/matrix。

## 最终 parent gate（同一源码哈希）

`post-batch99-final2-cmq_gate-regression.log` 在最后一次注释同步后的源码边界执行，
wrapper rc=0、PROCESS 28/28、LOGICAL 11/11、UVM pristine 28/28，warning/error/fatal
均为 0/0/0；日志 SHA-256 为
`f8ee6a4ae9e2802c2eebf9d7c69a2103ba678d7f605adf57072efc74ff3f7283`。

同一源码哈希的 `post-batch99-final2-core-regression.log` 也已完成：wrapper rc=0、
PROCESS 95/95、LOGICAL 78/78、UVM pristine 95/95、warning/error/fatal 0/0/0；
日志 SHA-256 为 `c59989807df0feb7cc92e9b34cf0640190c7f0b521e864e7cff130e0e8a7a30b`。
