# Host-memory null-status 注入审计

> 日期：2026-09-16  
> 范围：\`rdma_host_mem_api\`、\`rdma_host_mem_adapter\` 及其 host_mem 集成测试。  
> ABI 约束：本审计没有修改原始驱动头文件、位域、offset、opcode、ecode 或
> host_mem 外部依赖。

## 结论

host_mem 的 null-status 测试必须区分“可覆盖的 delegate 返回 null”和
“状态工厂自身返回 null”两类故障。当前工程只能稳定注入前者。

\`rdma_status::make()\` 先调用 \`rdma_status::type_id::create()\`，随后立即写入
\`status.category\`、\`status.code\` 等字段。因此，把 \`rdma_status\` 的 UVM factory
override 设置为返回 null，不会把 null 传到 adapter；故障会在状态工厂内部先触发
空句柄访问（NOA）。这种夹具不能作为 adapter fail-closed 的证据。

## 可达性矩阵

| 边界 | 当前 dispatch | 稳定注入方法 | 本轮结论 |
| --- | --- | --- | --- |
| \`rdma_dma_request_context.validate()\` | 非 virtual | 无法通过派生 context 覆盖；factory null 会在 \`rdma_status::make()\` 内 NOA | 只记录为待增加显式 delegate seam |
| \`rdma_umem.unpin_pages()\` | 非 virtual | 无法通过派生 UMEM 覆盖；adapter 只能直接调用 concrete 方法 | 不能声称已有 rollback-null 动态覆盖 |
| \`rdma_host_mem_allocation_identity.mark_release_complete()\` | virtual | \`rdma_failure_atomic_release_identity\` 测试 subclass 返回 error/null | 已有稳定 RED/GREEN 路径 |
| \`rdma_host_mem_adapter.validate_failure_atomic_release()\` | virtual | 生产实现可由测试 subclass 覆盖；本测试不再保留未接入的 null-validator 夹具 | 需要真实 allocation identity 场景后再增加动态测试 |
| \`rdma_host_mem_adapter.normalize_adapter_status()\` | protected concrete helper | \`rdma_host_mem_status_normalization_probe\` 公开调用并传入 null | 本轮新增稳定注入测试 |

## 本轮测试

\`tests/integration/rdma_host_mem_adapter_test.sv\` 新增
\`rdma_host_mem_status_normalization_probe\` 和
\`check_status_normalization_boundary()\`。该测试只把 null 作为 helper 的输入，
断言返回值非空、错误码为 \`RDMA_SC_INVALID_STATE\`，且诊断消息保留 operation
标签。它不设置全局 status factory override，不访问 host_mem，不修改 allocation
ledger，也不接触任何线上驱动 image。

已有的 \`rdma_failure_atomic_release_identity\` 场景继续覆盖
\`release_opaque()\` 的 non-null failure、null status、retry 和 exactly-once free：

1. seal 失败时 mapping 仍 active 且可读；
2. null seal status 不 free backing、不改变 release seal；
3. 成功 retry 只 free 一次并退休 opaque authority；
4. 释放后再次 read/release 被拒绝。

## 后续实现前提

若要动态覆盖 \`validate_failure_atomic_release()\` 的 null 返回、\`allocate()\` 的
request validation-null 或 \`pin_umem()\` 的 \`unpin_pages()\` null/error，生产
接口需要先提供明确的、非 ABI 的可覆盖 delegate（例如 validation/unpin service）。在
该 seam 或真实 allocation fixture 出现前，不应使用 raw UVM factory override，也不
应把静态 grep 结果写成运行期 RED 证据。

## 53 验证

在 \`ubuntu@10.11.10.53\` 的登录 bash 环境运行：

\`\`\`text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem \\
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
\`\`\`

结果：编译、仿真和严格 UVM summary 均通过，\`warning=0 error=0 fatal=0\`。
