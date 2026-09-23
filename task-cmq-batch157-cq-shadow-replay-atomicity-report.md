# Batch157：CQ shadow canonical detached replay 与 factory 原子性收口

日期：2026-09-23。工作树：`feature/rdma-structural-refactor-batch155`，基线：
`8b8ad4e`。

本批只处理 Batch156 留下的 CQ `flushed_shadow` 只写不读边界，并把 shadow 快照与
shared-handle 的 factory 失败收束为非致命、失败原子路径。普通 CQ
`poll_cqe()`/`publish_cqe()`/`resize()` operation envelope、queue-data mutation 和
外部依赖契约没有扩大；计划仍保持 `active`。

## Canonical replay 与所有权

- `rdma_cq_engine.sv` 删除可变的 `shadow_flush_result` 缓存。首次
  `flush_shadow()` 从 active shadow 建立两个独立 value graph：一个发布给 caller，
  一个保存到 `flushed_shadow`；两者及嵌套 `cq_h` 都是 detached 对象。
- replay 先校验 caller 的 Function UID、generation、reset epoch、CQ kind/object ID
  与 cache authority，再从 `flushed_shadow` 重新构造新的 snapshot。caller 修改上一轮
  输出、handle 或 payload 不会污染 cache；每次 replay 返回新的独立 `RDMA_SC_OK`
  status，不复用首刷 status 对象。
- replay 不再次调用 `capture_urc_shadow_evidence()`，不消费 active shadow，也不增加
  `shadow_flush_count`。首刷后 caller 未提供 authority snapshot 时仍返回
  `RDMA_SC_STALE_GENERATION`。
- `configure()+configure_shared()` 组合在每次 flush 前复用 live binding 的
  Function/reset-epoch 校验；reset epoch 漂移时 delegate 不被调用、cache 不被发布。
  普通组合还拒绝跨 Function UID/generation，避免新 CQ handle 把旧 delegate 变成另一
  Function 的发布 authority。
  `configure_shared()`-only facade 没有 live binding，只能验证冻结字段，无法独立观察
  外部 reset；该认证能力继续明确为 OPEN。

## Nonfatal factory 与失败原子性

- 新增 raw UVM factory helper，绕过 typed registry cast；null 或错误动态类型被转换为
  `RDMA_SC_RESOURCE_EXHAUSTED`，不触发 UVM `FCTTYP` fatal。
- queue-data engine 的 `capture_urc_shadow_evidence()` 同样使用 raw factory 和显式
  `$cast`；evidence candidate 的 null/错误动态类型或 null capture status 在发布
  `last_urc_evidence` 前失败，既有 evidence 保持不变。
- `clone_handle_value_nonfatal()` 手工复制 `rdma_handle` 的 kind、Function UID、object
  ID 和 generation；`clone_shadow_snapshot_value()` 独立分配 snapshot 与嵌套 handle。
  这两个 helper 在发布前都清空 output，失败时不写 facade、caller 或 cache。
- `configure_shared()` 先完成 CQ/QP 两个 handle clone，再一次性提交 shared authority、
  delegate、active shadow 和 one-shot 标志；任一 clone 失败都保留旧配置，不留下部分
  delegate 或 evidence。
- 首次 flush 在 URC evidence capture 前完成 caller/cache snapshot、nested handle 和
  success status 的全部本地准备。任一分配失败都保持 caller、active shadow、cache、
  count 和 evidence 不变；evidence 非空失败也在清除 active shadow 前原样返回。
- replay 的 snapshot/handle clone 采用同一 staging 规则。失败时 caller、cache、
  `shadow_flush_count` 和既有 evidence 均保持不变，解除 factory 故障后可重试成功。

## 测试覆盖

`tests/unit/rdma_cq_shadow_flush_test.sv` 新增一次性 null/错误类型 factory wrapper，
覆盖：

1. shared CQ 的 completion-QP clone 失败及配置重试；
2. 首刷 cache snapshot/handle/evidence candidate 分配失败、evidence 前无副作用及重试；
3. replay snapshot/handle 分配失败、caller/cache/count/evidence 原子保持及重试；
4. 首刷与 replay 的 detached handle/payload/status identity；
5. authority 拒绝、missing authority、URC evidence exactly-once 与 21-bit projected
   local CQ ID 边界。

历史 RED 证据保留在 `/tmp/batch157-red-rdma_cq_shadow_flush_test.log`：该日志对应
   旧测试断言（仍期待 caller/cache alias）的预期失败，wrapper rc=2，UVM
   `INFO=3/WARNING=0/ERROR=2/FATAL=0`，SHA-256
   `ee2286c3dc692d752f0b36c6ab8126a633f012ba7beb0f616798134e42dbf4c8`。当前实现与
   新断言的最终 GREEN 证据如下：

| 入口 | 结果 | 完整 wrapper 日志 SHA-256 |
| --- | --- | --- |
| `rdma_cq_engine_test` | rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `2b3ed52478718459184ac64ed03b75a52b4a8d443624a4469517c50f26e700ca` |
| `rdma_cq_engine_resize_test` | rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `7110ebc081a9ca2e41c2242d13ed6b554eddda586b3d8c9fae19e16bc353d4af` |
| `rdma_cq_shadow_flush_test` | rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `36581453cab2e5d2284146de8b515c1c582820f53b3ee47029ae99bc0057e8c8` |

所有 VCS 命令均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 的登录 bash
环境执行。

## 静态与源码指纹

- `git diff --check`、changed-SV style（base=`8b8ad4e`）、queue lifecycle、profile
  naming、Phase-1A approval、CMQ manifest 22/22、SV keyword 3/3、multivf manifest
  4/4、field ownership 61/61 均通过；完整静态合并日志
  `/tmp/batch157-static-fix.log` 的 SHA-256 为
  `73e0e60ee02883bcdda68f52e72e54f07760844a1e5db3c501376e782997d13a`。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py' -v`：292/292 `OK`；同一
  合并日志记录了该结果。
- 使用 `sanitize_source`、`method_ranges`、`check_method_comments` 和
  `check_file_header` 对 `src/`、`tests/`、`sim/` 全目录复审：189 个文件（187 `.sv`、
  2 `.svh`），5,483 个 method（`.sv` 5,481、`.svh` 2），0 diagnostics；摘要日志
  `/tmp/batch157-contract-scan-final.log` 的 SHA-256 为
  `30f48cc7d65cb1f2be3b8a8c3da4bee093f9487655e48f0d31c5eae9f9bf46c3`。
- 最终源码/测试 SHA-256：

  - `src/core/rdma_cq_engine.sv`：`655b4e58efaa296364b6067d498473f7f151fab194b1e7b86445521f0b4f6992`
  - `src/core/rdma_queue_data_engine.sv`：`cd4601cf64ce24d19b3027875d91f53f763c5f554cab2e0394c8858b845e2131`
  - `tests/unit/rdma_cq_shadow_flush_test.sv`：`a5d6f1201a3184bf455e2e733a4f27e727331c91a3791d77ffe3b33bbfe9e099`
  - `tests/unit/rdma_cq_engine_test.sv`：`f1b1593e924b527cc38c155e7cb0221f13a58db15bccb56cec769521edc14590`

## 未关闭边界

本批不声称关闭 `configure_shared()`-only facade 的真实 reset 认证、跨队列/跨线程并发、
SRQ 全生命周期、legacy descriptor、外部 PCIe ordering/error、engine-level 全局锁、
snapshot 后的全目录 ownership 审计、完整 CMQ/core regression 或广义 Phase 1C F2。
这些边界继续由后续独立批次处理，结构重构计划保持 `active`。
