# Batch187：SRQ destroy detached value policy

日期：2026-09-24。工作树：`feature/rdma-cmq-structural-phase2-batch160`。

## 实现边界

本批从 SRQ 全生命周期 destroy/recovery 的窄 seam 抽取不携带对象引用的纯值
`rdma_srq_destroy_value_policy()`（`src/model/rdma_queue_lifecycle_models.sv`）。该
helper 只生成值数组和顺序标志：

- 硬件 OCC flush 固定为 `SRFQ_PD → SRQ_PD`，两个 target 均为
  `RDMA_QUEUE_FLUSH_PRE_DELETE`，`delete_before_flush=0`，因此保持 SRQ flush-before-
  delete 的既有硬件顺序。
- 本地释放 recipe 固定为 `SRFQ_PD → SRQ_PD → SRQ_SGB → SRFQ_RING → SRQ_RING`，
  `release_context_first=1`；`include_optional_sgb=0` 时仅省略可选 `SRQ_SGB`，对应
  `max_sge<=2` 的 plan cardinality。
- `rdma_srq_lifecycle_policy::hardware_cleanup_roles()` 与
  `local_cleanup_roles()` 现在只投影该 detached recipe。没有改变 manager、CMQ、QP
  dependency、borrowed backing 或 resource/registry commit；跨资源 QP→SRQ busy guard
  仍由 `destroy_locked()` 在任何 CMQ submit 前执行。

测试 `check_destroy_recipe_contract()` 同时验证 canonical recipe、无 SGB variant 和
policy/helper 一致性；既有 `DESTROY_BUSY_SRQ_DEPENDENT_QP`、SRQ restore/retry 和 flush
failure 场景继续覆盖跨资源阻断、失败恢复与 flush/delete 顺序。

## 验证

VCS 仿真在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

```text
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test
```

结果：wrapper rc=0；PROCESS PASS、LOGICAL PASS；UVM `warning/error/fatal = 0/0/0`。

证据日志：
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/post-batch187-srq-destroy-value-policy.log`

日志 SHA-256：
`8c28455e5bff66efbae3e6055b3953e55bdf378b863e56d91edf6d60f84d8d85`

静态检查：

- `git diff --check`：PASS（本批三个源码/测试文件）。
- `python3 tools/check_changed_sv_style.py --base 94ba894`：PASS。
- `python3 tools/check_queue_lifecycle.py`：PASS；其定向 Python 单测
  `python3 -m unittest discover -s tests/unit -p 'test_check_queue_lifecycle.py'`：15/15
  通过。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：293 tests，OK（其中
  预期的 CLI/外部仓库探针错误输出不影响 unittest 成功状态）。

## 源码指纹

| 文件 | SHA-256 |
| --- | --- |
| `src/model/rdma_queue_lifecycle_models.sv` | `c62257c977378743d0808005677965da1b34cf25cd5307ed97574cfaa8893dd6` |
| `src/core/rdma_queue_lifecycle_policy.sv` | `40f04366d703559951e8456a89ae971b6cf60b9b0d09b2a28c8efe0fc0e1bc28` |
| `tests/unit/rdma_queue_lifecycle_test.sv` | `bd4490ac850b2d5f8462f1a2ebc70f0dc6acdc9dbe3bc4ceedaf57b4562fb84f` |

本批不修改外部依赖；工作树中父任务已有的其它未提交改动保持原样，未执行
`reset`、`clean`、`merge`、`push` 或提交。

## 遗留边界

本批只抽取 SRQ destroy 的纯值 recipe，不引入 detached resource candidate，也不改变
QP lifecycle 的 SRQ identity capture、manager dependency ledger 或 recovery ownership。
后续若扩展 recipe，必须继续在 candidate staging 与 manager/registry commit 之间保持
失败不半提交，并补充 shared-QP recovery 组合证据。
