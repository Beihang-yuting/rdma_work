# Task 28 实施报告：Responder region registry

## 变更

- 新增 `src/core/rdma_responder_registry.sv`，提供四类 responder domain、region 对象和 fail-closed registry。
- registry 校验 domain/mode/route/size/owner，使用 65 位中间值拒绝地址末端溢出。
- 按 domain 与 Host topology/root/segment 隔离区间；非 `MONITOR_ONLY` 区间重叠返回 `RDMA_SC_INVALID_STATE`。
- 为每个成功 claim 分配单调 lease，内部账本独立保存 owner、route、base、size 等字段，防止外部句柄篡改释放/冲突校验。
- `seal()` 幂等，seal 后禁止 claim 但允许 release；释放后区间可重新 claim。
- `rdma_core_pkg.sv` 和 `rdma_unit_test_pkg.sv` 已按依赖顺序注册实现和测试；回归 manifest 已加入新测试。

## 验证

- `scripts/run_vcs53.sh core rdma_responder_registry_test`：通过，UVM warning/error/fatal 均为 0。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：113 tests passed。
- `git diff --check`：通过。

## 注意事项

SystemVerilog 将 `release` 视为保留关键字，因此接口以 escaped identifier `\\release` 声明和调用；其语义名称仍为 release，调用形式为 `registry.\\release(region)`。

## Review fix round 1

- 增加与 `m_regions` 同步的不可变 lease 绑定队列，release 不再使用可变句柄字段选择账本；同时校验 lease、mode 及其余身份字段。
- `active_count()` 改为读取内部 active ledger，外部篡改 `region.active` 不影响计数。
- 测试新增句柄 lease 重定向、active 篡改和成功 claim 全量清理场景。
