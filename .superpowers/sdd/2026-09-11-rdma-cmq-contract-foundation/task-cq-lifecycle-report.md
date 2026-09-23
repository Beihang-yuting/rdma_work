# CQ shared facade 生命周期修复报告

## 范围

本任务只处理 `rdma_cq_engine.configure_shared` 的 shared-CQ one-shot 配置门禁，并将 shadow 测试中的 QP authority fixture 对齐真实 21-bit 本地 QPN。未修改 EQ、SQ、RQ 或 QPC 文件。

## TDD 证据

- RED：`scripts/run_vcs53.sh core rdma_cq_shadow_flush_test`（53 登录认证由受控环境提供）。
  - 在测试 fixture 使用 `21'h1f_ffff` 后，首次配置和 flush 成功，但第二次合法配置未被拒绝。
  - UVM 报告：`UVM_ERROR ... rdma_cq_shadow_flush_test.sv(198) [CQ_CONFIG_GATE] active shared CQ accepted a second configuration`；error=1、fatal=0；`LOGICAL FAIL`。
  - 完整日志：`/tmp/cqflush_gate_red.log`。

- GREEN：同一命令在门禁修复后通过。
  - UVM 报告：info=3、warning=0、error=0、fatal=0；`UVM report is pristine`；`PROCESS PASS` / `LOGICAL PASS`。
  - 完整日志：`/tmp/cqflush_gate_green_final.log`。

- 最终独立复核：注释与排版修正后再次在 53 登录 bash 执行同一 focused test。
  - 命令：`scripts/run_vcs53.sh core rdma_cq_shadow_flush_test`（53 登录认证由受控环境提供）。
  - 结果：退出码 0；info=3、warning=0、error=0、fatal=0；`PROCESS PASS` / `LOGICAL PASS`。
  - 完整日志：`/tmp/cq_finalize_focused_final.log`。

## 修复

在 `configure_shared` 完成参数、资源类型、Function authority 和代际校验之后、句柄 clone 或任何状态写入之前，若 `shared_configured` 已置位则返回 `RDMA_SC_INVALID_STATE`。因此合法第二次配置保持原 authority、delegate、shadow、缓存和 flush 计数；非法输入仍先返回原具体错误。
