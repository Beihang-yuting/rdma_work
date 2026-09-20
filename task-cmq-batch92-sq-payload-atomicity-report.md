# CMQ Batch 92：SQ payload receipt staging 原子性

本批收敛 `rdma_host_mem_sq_payload_writer::stage_and_verify` 的晚期失败窗口。此前
函数在完成权限/范围预检后先递增 registration `refs` 并执行 Host-memory write/read，
再创建 receipt、Function/SGE 快照和 mapping clone；晚期 factory/clone 失败会留下
不可见的 I/O 或引用副作用。

## 实现边界

新增 `build_receipt_candidate` 作为纯候选阶段：

- 先构造 receipt、Function handle、SGE 和每个 registration mapping 的 detached
  snapshot；任何 null/wrong factory 或 clone 都返回失败，candidate 保持 null。
- 只有候选完整成功后，才发布 `refs++` 并执行既有 Host-memory write/readback 顺序。
- write/read 返回 null 时统一归一化为 `RDMA_SC_INVALID_STATE`，并通过既有
  `release_ids` 回滚本次临时引用；成功路径仍返回原有 detached receipt。
- 没有复制 mutable registration ledger，也没有改变 caller-owned Host-memory 的
  生命周期或释放权限。

测试加入可控 mapping late-clone 故障和 Host-memory null-status 故障，分别断言：
  late clone 失败时 write/read 调用计数不增加、`refs==0`、receipt 为空；外部 null
  status 不被当作成功且引用被回滚。

## 源码边界

| 文件 | SHA-256 | Git blob SHA-1 |
| --- | --- | --- |
| `src/core/rdma_sq_payload_writer.sv` | `e53c2a5da7152b0e8c65f3a509015bc0416d1613c08486740f70beea129c71bc` | `3a2d13ff6195f01405816ca4cb98c1575b41836e` |
| `tests/unit/rdma_sq_payload_writer_test.sv` | `97ecf2af2d0872af6f7fc3f6ab7cd8c0e7de8cbd082e9272f7efae35c467d657` | `a7a526d14a1d73e3e91d9b33d8ff3eaf026c7409` |

## 验证

在 `ubuntu@10.11.10.53` 登录 bash 环境运行：

```text
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
SSHPASS=123 scripts/run_vcs53.sh core rdma_sq_payload_writer_test
```

结果为 wrapper rc=0、PROCESS/LOGICAL=1/1、严格 UVM warning/error/fatal=0/0/0。
完整日志位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/post-batch92-rdma_sq_payload_writer_test.log`，
SHA-256 为
`f414fd79f34f226d759fd593ac3af09413c9612caead6f187247864aa163b2ca`。

`git diff --check` 与 changed-SV style 均通过（仅保留已有 body-value soft-limit hint）。
当前工作树 parent gate、全量静态门禁、Phase 1C F2 与 reset coordinator 生命周期
仍未关闭。
