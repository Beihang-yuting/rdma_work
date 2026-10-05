# Batch152：SQ/RQ/EQ facade 配置 admission 收缩

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批只收束 SQ、RQ、EQ 三个 facade 中逐字重复的配置前置校验；CQ 的
`configure_shared()`/`configure()` 保留其 URC completion-QP、shadow 和 shared-config
专属路径，不被泛化 helper 覆盖。重构计划继续保持 `active`。

## 代码收缩

- 新增 `src/core/rdma_queue_facade_configuration.sv`，提供 package-scope
  `rdma_validate_queue_facade_configuration()`。helper 统一检查依赖非空、timeout 非零、
  `shared_engine` 的 manager/binding/host_mem/doorbells/registry 五个引用逐一匹配，
  再按原顺序调用 `function_binding.validate()` 并检查 `RDMA_BIND_ACTIVE`。
- `rdma_sq_engine::configure()`、`rdma_rq_engine::configure()` 和
  `rdma_eq_engine::configure()` 仅保留 helper 转发、one-shot `configured` 门禁和
  delegate/authority/timeout 快照写入；失败时仍保留原 code/message、null status 传播
  和“先完成输入校验、再拒绝合法重配”的顺序。
- protected facade API、authority 快照字段、delegate 非拥有引用和 queue-data runtime/
  ledger/Host-memory/MMIO 所有权均未改变；helper 不保存输入引用，也不执行 I/O 或状态
  mutation。CQ 专属配置路径不共享该 helper，避免把特殊 transport 约束压平。
- 同批补充四个 facade 的 `validate_live_authority()` 失败边界注释，明确
  `delegate == null` 与 binding 缺失均会被拒绝；这是 Batch151 authority helper 的注释
  同步，不改变运行逻辑。

三个 facade 的重复配置 admission 各删除约 20 行，新增一个 62 行的 core helper；净
减少重复分支并形成单一错误优先级来源，而不是把 one-shot 状态所有权移出 facade。

## 验证

所有 VCS 命令均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境
执行。配置 helper 加入后的 focused 结果：

| 入口 | 结果 |
| --- | --- |
| `rdma_sq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_rq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_eq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

三项均完成 compile/elab/link，且 wrapper 报告 UVM pristine。Batch151 的 CQ focused
证据仍适用于本批未修改的 CQ authority 转发；本批未声称重新关闭 CQ 特殊配置矩阵。

本地静态门禁结果：

- `git diff --check`：PASS。
- `python3 tools/check_changed_sv_style.py --base 00b8ff6`：PASS。
- `check_queue_lifecycle.py`、`check_rdma_profile_names.py`、
  `check_rdma_phase1a_approval.py`：PASS。
- Python unit suite：292/292 PASS。
- 全目录中文 function/task 与文件头扫描覆盖 189 个文件（187 `.sv`、2 `.svh`），
  共 5,464 个 method（`.sv` 5,462、`.svh` 2），0 diagnostics。

最终源码 SHA-256：

- `src/core/rdma_queue_facade_configuration.sv`：
  `198adc762dcc55e96cd401564253c22def5fb08d24c5b010b8460e937b8a9141`
- `src/core/rdma_core_pkg.sv`：
  `5f8330c5c1dbd6e9a4d9db0e34ef64898fc752d705eb3e7b3e06a07e12ed5701`
- `src/core/rdma_sq_engine.sv`：
  `aa55da2e01673a4af87c017af8b629977587c81267f7fe75218667d08a8229ce`
- `src/core/rdma_rq_engine.sv`：
  `2235920d05d2b687336823aa84b5a378a25eaba13c85b6b631cb12f7ca9649e0`
- `src/core/rdma_eq_engine.sv`：
  `269c586e546703d60dfa0a057b89514cde191406d9c76825255ad1a86f6b9b25`

本批只关闭 SQ/RQ/EQ 配置 admission 的局部重复 seam，不覆盖 CQ 特殊配置、跨队列
并发、SRQ 全生命周期、legacy descriptor、外部 PCIe error/ordering 组合、engine-level
全局锁、全目录 ownership 最终审计或广义 F2；计划继续保持 `active`。
