# Batch153：CQ facade 配置 admission 收缩

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批把 CQ 普通 `configure()` 接入 Batch152 已建立的
`rdma_validate_queue_facade_configuration()`，消除第四个 facade 中重复的依赖
一致性和 Function binding admission。CQ 的 `configure_shared()`、URC
completion-QP/shadow 路径以及各 facade 自己拥有的 one-shot/authority 写入仍保持
独立；重构计划继续保持 `active`。

## 代码收缩

- `src/core/rdma_cq_engine.sv` 的普通 `configure()` 现在通过 `"CQ"` 标签转发到
  `rdma_validate_queue_facade_configuration()`。依赖为空或 timeout 为零、shared
  engine 的 manager/binding/host_mem/doorbells/registry 不一致、binding validation
  返回 null/失败以及非 `RDMA_BIND_ACTIVE` 的拒绝顺序和原消息前缀保持一致。
- CQ 的 `configured` one-shot 门禁、`shared_configured` 与 evidence delegate
  一致性门禁、delegate/authority/timeout 快照写入仍在 facade 内；helper 不保存
  引用、不访问 runtime、Host-memory、MMIO 或 ledger。
- `rdma_queue_facade_configuration.sv` 的职责说明扩展为 CQ/SQ/RQ/EQ 四个普通
  facade 配置入口；特殊 `configure_shared()` 不被泛化。

本批删除 CQ 普通配置中的 31 行重复 admission 分支，保留 11 行 helper 转发和
原有状态写入路径；没有新增 public/protected API，也没有移动资源所有权。

## 行为审计

逐分支对照原实现：

1. 空依赖/零 timeout 与 shared-engine 五引用 mismatch 仍先返回
   `RDMA_SC_INVALID_ARGUMENT`，并且不会写入 delegate 或 authority。
2. `function_binding.validate()` 的 null 结果仍归一化为 `RDMA_SC_INVALID_STATE`，
   非空失败状态原样透传；非 `RDMA_BIND_ACTIVE` 仍返回 `RDMA_SC_INVALID_STATE`。
3. 合法输入之后才检查 CQ `configured` one-shot；已绑定 shared evidence 的 CQ 仍
   单独检查 `evidence_engine == delegate`，因此 `configure_shared()` 的 URC 语义
   没有被 helper 覆盖。

## 验证

VCS 仿真通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

| Entry | Result |
| --- | --- |
| `rdma_cq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_cq_engine_resize_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_cq_shadow_flush_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

日志包含 `UVM report is pristine`、`PROCESS PASS` 和 `LOGICAL PASS`；wrapper rc=0。
本次日志 SHA-256：

`9ca824a37424758d49660518690e25de8bafa557a99d10b00c29e569c188418c`

resize/shadow 日志 SHA-256 分别为
`78ff5aab925e9f0bc41ed88ba992c646098f290282ca85c4a715ed0fed0c9c0a` 和
`15e6595cea0fe6d3fe0642b6e4dfc35c5772379f783c50c8ea36f9dee05b6cba`。

本地静态门禁和全目录契约 scanner 已在源码稳定边界补录；本批不宣称关闭 CQ shadow
flush、跨队列并发、SRQ 全生命周期、legacy descriptor、外部 PCIe
error/ordering、engine-level 全局锁或最终 ownership 审计。

静态结果：`git diff --check`、changed-SV style、queue/profile/Phase-1A gates 均
通过；Python unit suite 292/292 通过；全目录 scanner 覆盖 189 个文件（187 `.sv`、
2 `.svh`），5,464 methods（`.sv` 5,462、`.svh` 2），0 diagnostics。

最终源码 SHA-256：

- `src/core/rdma_queue_facade_configuration.sv`：
  `78effe19f63fcdaa0a321cb29596e248436fc52be65f52eededb4d74031b650c`
- `src/core/rdma_cq_engine.sv`：
  `6e50727544d1d1cb0024da711bcf022a37efa67eee8efd7f046e993e54f4b7d8`
- `src/core/rdma_core_pkg.sv`：
  `5f8330c5c1dbd6e9a4d9db0e34ef64898fc752d705eb3e7b3e06a07e12ed5701`
