# CMQ Batch 97：resource-manager queue role cardinality seam

本批修复 `rdma_resource_manager::record_queue_flush_complete` 与
`record_queue_cleanup_complete` 在 ERROR queue（`has_recovery=1`）下的 role
索引前置条件。两个入口现在分别通过纯只读 `queue_flush_role_count` /
`queue_ref_role_count` 统计 authoritative snapshot 中的匹配 role，并且只在
数量恰好为一时使用输出索引；随后才读取 recovery snapshot、比较 mapping/ref
authority 并提交双快照进度。缺失或重复的 authoritative role 继续返回
`RDMA_SC_INVALID_ARGUMENT`，不会被 recovery 分支改写成 authority 错误，也不会
解引用未初始化的 `flush_targets`/`refs` 下标。所有拒绝路径仍在
`commit_queue_progress` 之前，不发布单侧 `flush_complete` 或 `cleanup_complete`。

## 源码边界

| 文件 | SHA-256 | 当前工作树 blob SHA-1 |
| --- | --- | --- |
| `src/core/rdma_resource_manager.sv` | `8cab9e0a65fb4e5fe534192a1c6d6073003941e7ab5788eac354870adeac532f` | `43763a025eeb3ebbd9bf2d4a4da29fbd585e4fbb` |
| `tests/unit/rdma_resource_manager_test.sv` | `857a7c4d5b9a995da11a3b14fd35716787aac4c8c32771f01d97bf634c7767bd` | `4e2a84705f431bbc27fb3b8dd45ca1dfacb67807` |

## VCS53 验证

在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

```text
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
SSHPASS=123 scripts/run_vcs53.sh core rdma_resource_manager_test
```

结果：wrapper rc=0，PROCESS/LOGICAL 1/1，严格 UVM warning/error/fatal=0/0/0。
日志：`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/post-batch97-rdma_resource_manager_test.log`
SHA-256：`30a128a7b9f04602b2459d747aeb633bff46119ab0a678d5a89abc09258f0042`。
新增 `RECOVERY_MISSING_FLUSH_ROLE` 与 `RECOVERY_MISSING_CLEANUP_ROLE` 场景均
断言 `RDMA_SC_INVALID_ARGUMENT`，并在后续 recovery progress 流程中保持原有
原子性测试通过。

静态检查：`git diff --check HEAD` 通过；changed-SV style 返回 0，仅报告既有
`src/model/rdma_cmq_body_value_contract.sv:303` soft-limit。未修改外部依赖，未
执行 commit/reset/clean/merge/push。
