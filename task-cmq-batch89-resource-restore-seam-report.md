# CMQ Batch 89：resource manager SRQ restore progress seam

本批把 `rdma_resource_manager::restore_active` 中三处重复的 SRQ flush-progress
清零动作收敛为一个局部 helper，并同步复审恢复流程与相邻 recovery-value 比较契约。
helper 只操作已经投影出的 detached candidate，不改变 registry、recovery record、
外部 mapping/backing 或 observer 的发布顺序。

## 实现边界

新增 protected `clear_srq_flush_progress(plan)`，由 ERROR recovery replacement、
ERROR queue plan replacement 和 QUIESCING SRQ replacement 三处调用。它保留原有
`foreach (flush_targets)` 的字段写入顺序；caller 仍负责 SRQ kind、null/type、authority
和 validation 门禁。恢复流程仍为：lookup → schema/authority → detached projection →
清 ambiguity/flush progress → candidate validate → observer → registry publish → 成功后
删除 ERROR recovery record。

同时把 `same_mapping_value`、`same_recovery_mapping_value`、`same_queue_recovery_progress`
和 `restore_active` 的中文契约改成与真实字段、null 语义、state 忽略规则、rollback
cardinality 及所有权边界一致。没有移动 mutable registry/lease/backing owner。

## 源码边界

| 文件 | SHA-256 | Git blob SHA-1 |
| --- | --- | --- |
| `src/core/rdma_resource_manager.sv` | `d0d23a153d57034ceadd3dc6f3e5b2a815412a7577c549b77ac516aa401e2095` | `ee89562a153c8117fe2774cc37d84a0c1a5a3840` |

工作树 HEAD 仍为 `917beeb769bab84cff95e9e4b2e5ebe9dfeadecd`，既有脏改动全部保留；
本批未修改外部依赖、未执行 commit/reset/clean/merge/push。

## VCS53 验证

以下测试均通过 `scripts/run_vcs53.sh core <test>` 在 `ubuntu@10.11.10.53` 登录
bash 环境执行，wrapper rc=0、PROCESS/LOGICAL 1/1、严格 UVM warning/error/fatal=0/0/0：

| 测试 | 日志 SHA-256 |
| --- | --- |
| `rdma_resource_manager_test` | `c954dfc0d827908bc3ed6cfbae5ec00e22bbfe21f5a2c0e942e9df9e0f060f1f` |
| `rdma_queue_lifecycle_test` | `cf471e0bd09e282981e9a1002bee5b02a30e7cb1fb721ab229ce02dd90f91f51` |
| `rdma_queue_recovery_test` | `c2677957810ccf1fc5a3d4b178ce9bf2e4a5c67e0d6fd2a12abe0c01e99a2542` |
| `rdma_qp_lifecycle_test` | `d5014485063177a51e8c73f0d98444b743651b58200e94b0f65795bc2ed490d5` |

Batch89 focused 结果与当前工作树 parent CMQ gate 均已归档；parent gate wrapper rc=0、
PROCESS 28/28、LOGICAL 11/11、严格 UVM warning/error/fatal=0/0/0，日志 SHA-256 为
`8838b7e379db7e56f1e4824924a91523cc4fe64bae3fb31ec22d757f8d62e620`。Phase 1C F2
（`TPL=513 / SGE_NUM=33`）仍保持 paused。
