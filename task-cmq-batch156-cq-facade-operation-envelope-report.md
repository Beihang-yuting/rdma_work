# Batch156：CQ facade operation envelope 收缩

日期：2026-09-23。工作树：`feature/rdma-structural-refactor-batch155`，基线：
`8b8ad4e`。

本批只收束 `rdma_cq_engine` 的 `poll_cqe()`、`publish_cqe()` 和 `resize()` 重复的
配置/Function authority admission 与 delegate null-status 处理。三条 typed delegate
seam 仍分别显式可见；shared-CQ `flush_shadow()` 的独立配置、inout authority 和 replay
契约没有并入普通 operation envelope。重构计划继续保持 `active`。

## 代码收缩与可读性边界

- 新增受保护、非 virtual 的 `validate_operation_authority()`，统一普通入口的
  `configured/delegate` 门禁、冻结 Function UID/generation/reset epoch、ACTIVE binding、
  `binding.validate()` 及 authority null-status 归一化顺序。
- 新增受保护、非 virtual 的 `normalize_delegate_status()`，只把 delegate 返回的 null
  status 转为带 seam 名的 `RDMA_SC_INVALID_STATE`；非空成功或失败 status 保留同一对象、
  code 和 message。
- `call_delegate_poll_cqe()`、`call_delegate_publish_cqe()` 和
  `call_delegate_resize_cq()` 保持独立 `protected virtual` 注入点。poll/publish 仍由各自
  wrapper 管理不同 typed result，resize 仍直接返回 status，没有引入 enum/bit dispatch
  或宽泛可选参数。
- `flush_shadow()` 明确排除在 helper 外：它允许 `configure_shared()`-only facade 工作，
  仅在普通 authority binding 存在时验证 live authority，并保留 caller shadow/replay 顺序。

生产源码从 500 行降至 498 行；剥离注释和空行后的生产语句行从 373 降至 344，减少
29 行重复 control flow。为满足逐函数中文契约并锁定边界，生产注释由 91 行增至 123 行。
测试从 888 行增至 948 行；这里以生产逻辑去重和可审计性为收益，不通过删除断言换取
表面行数。

## 行为与所有权审计

三个普通入口保持相同的可观察顺序：

1. 未配置或 delegate 缺失先返回固定 `CQ facade is not configured`，不进入 virtual seam；
   poll/publish 在 admission 前先清空 output result。
2. 配置后先比较冻结 Function UID/generation/reset epoch，再检查 binding ACTIVE 和
   `validate()`；stale incarnation 仍优先返回 `RDMA_SC_STALE_GENERATION`。
3. authority 成功后才显式调用对应 typed seam。delegate null status 分别生成
   `poll_cqe`、`publish_cqe` 或 `resize_cq` 精确消息；非空失败 status 句柄原样返回。
4. poll/publish 的任一失败都清空未认证 result；成功 `status + result=null` 仍按 delegate
   原语义转发。resize 没有 result，不伪造 geometry 成功。

`configure()` 禁止 `timeout==0`，因此普通 CQ facade 对空 ring 的可达外部结果是
`RDMA_SC_TIMEOUT`，不是 delegate 的单次 `RDMA_SC_QUEUE_EMPTY`。本批没有移动
poll 的 CI/WQE release、publish 的 reservation/cancel/recovery 或 resize 的
quiesce/backing/cleanup ownership；这些副作用仍归唯一 queue-data delegate。

测试新增或加强了三个未配置入口的固定消息和 poll/publish sentinel 清理、三条
delegate-null 精确消息、三条非空失败 status 对象身份与 code/message，以及 reset epoch
漂移后的三组 seam counter 不变断言。

## 验证

全部 VCS 仿真通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

| Entry | Result | 日志 SHA-256 |
| --- | --- | --- |
| `rdma_cq_engine_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `6bbb677a7d6ab116e36318154fc15c613b08318070073db51939ed0c3944bbcb` |
| `rdma_cq_engine_resize_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `6253e6c9a27b35b8cf634a7e72f25963f075e74f1b88c0fd179087ab2b583e77` |
| `rdma_cq_shadow_flush_test` | wrapper rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `0843be3677d04d3ae33ae1bceea5ca29b58af5f22d5350c9355a1fa43a7c0877` |

本地 `git diff --check`、changed-SV style（base=`8b8ad4e`）、queue lifecycle、profile
naming、Phase-1A approval 和 Python unit 292/292 均通过。全目录中文契约/文件头 scanner
覆盖 189 个文件（187 `.sv`、2 `.svh`），共 5,469 methods（`.sv` 5,467、`.svh`
2），0 diagnostics。

最终文件 SHA-256：

- `src/core/rdma_cq_engine.sv`：
  `9bfd344c65ce3824dd21bf4344f7d4839d9c336fa40e63c953729dc0a5c9d20a`
- `tests/unit/rdma_cq_engine_test.sv`：
  `622d00e2b0a68d5eb7048733a242772457d0b3cd09f29467f983048615fe0e6e`

## 未关闭边界

`flushed_shadow` 当前只写不读。首次 flush 后的 replay 只验证调用方 shadow authority 并
返回 cached status，不把缓存 snapshot 拷回；authority 匹配但 CI/arm/sequence 任意的
调用方 shadow 也可能成功且内容保持不变。该行为需要独立契约决策与测试，未混入本批。

此外，CEQ/AEQ malformed retry、跨队列并发、SRQ 全生命周期、legacy descriptor、
外部 PCIe error/ordering、engine-level 全局锁、全目录最终 ownership 审计和广义 F2
仍保持开放；focused GREEN 不等于整份结构重构完成。
