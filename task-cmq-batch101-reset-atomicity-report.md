# CMQ Batch 101：跨 context reset prepare/commit 原子性

本批关闭 Batch 98 遗留的 `quiesce → epoch bump → rebuild` 跨 context 半提交窗口。
reset scope 现在先为全部选中 Function 构造 detached identity、binding、owner handle 和
identity-ledger 副本；所有 candidate 通过校验后才由 coordinator 发布唯一 epoch side effect。
epoch 发布后只执行不可失败的字段交换和 ledger assignment。

## 实现边界

- `src/integration/rdma_function_context.sv`
  - 新增 `rdma_function_reset_candidate.binding_identity_snapshot` 和
    `validation_complete`，在 `prepare_reset()` 阶段完成 binding identity snapshot。
  - `validate_reset_candidate()` 不再调用会分配新 snapshot 的 `identity_snapshot()`，改为
    读取 prepared snapshot、`matches_identity_snapshot()` 和 owner seam。
  - 新增 non-virtual `commit_reset_prevalidated()`；它只 assignment
    `identity`/`binding`/`state`，不调用 factory、clone、status 校验或外部 router。
  - 公共 `commit_reset()` 保留兼容校验；单 context `reset()` 显式执行 prepare → validate → commit。
- `src/model/rdma_function_binding.sv`
  - 新增无分配 `matches_identity_snapshot()` 与 `accepts_noalloc()`，供 epoch 后提交路径使用。
- `src/integration/rdma_device_env.sv`
  - `rebuild_scope()` 在 candidate/ledger 全量 prepare 和 validate 后才发布 epoch；发布后调用
    `commit_reset_prevalidated()`，不再保留可返回错误的逐 context commit 分支。
  - prepare/ledger/epoch 失败仍只恢复本次由 `ACTIVE` 转出的 context；既有 `QUIESCING` 状态不被覆盖。
  - `reset_status_after_rollback()` 对 null status fail-closed，并以 detached status 合并
    rollback code/metadata 与原始诊断，不就地改写外部传入的 rollback status；selected-context
    早退也经过同一恢复路径。
- focused tests
  - `rdma_function_context_test`：prepare→validate 后 arm identity/binding/handle factory，
    commit 仍成功并发布 detached candidate。
  - `rdma_reset_cascade_test`：PF scope 两个 context，在第二次 prepare 注入失败；断言第一
    candidate 未部分提交、全部 context state/generation/reset_epoch、identity ledger、
    Function/Host/Device/router epoch 均保持不变；新增 rollback-status probe，验证恢复失败
    的 code/双侧诊断可见、null status fail-closed 且输入 rollback status 不被污染。

## VCS53 验证

两项 integration wrapper 均返回 `WRAPPER_RC=0`，UVM summary 为
`warning=0 error=0 fatal=0`。运行环境使用 `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common`，
远端为 `ubuntu@10.11.10.53` 登录 bash（脚本通过 VCS agent 认证）。

```text
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
  scripts/run_vcs53.sh integration rdma_function_context_test
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
  scripts/run_vcs53.sh integration rdma_reset_cascade_test
```

证据日志：

| 测试 | 日志 | SHA-256 |
| --- | --- | --- |
| `rdma_function_context_test` | `evidence/batch101-rdma_function_context_test.log` | `8cedfb819663d413c4022de85640875fb7ce294abc33099f86ae680efe88d369` |
| `rdma_reset_cascade_test` | `evidence/batch101-rdma_reset_cascade_test.log` | `239f6029f8124111ea2e7e87dd54ce5117f5cc3db6d7810821b529110ca0eeff` |

本批未执行 commit/reset/clean/merge/push；工作树中的其他既有改动保持原样。
