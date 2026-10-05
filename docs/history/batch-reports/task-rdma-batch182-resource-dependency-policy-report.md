# Batch182：resource dependent blocker policy

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标与边界

resource manager 的 activity snapshot 原先直接在 registry 扫描中维护 QP、SRQ 和其它
dependent 的分类分支，容易让 destroy/resize caller 重复解释“空闲 QP 可例外、SRQ/其它
依赖仍阻塞”的业务规则。本批只抽取这个纯值决策，不移动 registry 扫描、计数、lock、
recovery 或生命周期副作用。

## 实现

- 新增 `src/core/rdma_resource_dependency_policy.sv`，提供
  `classify()` 和 `blocks_parent_release()` 两个无状态函数。
- QP、SRQ 分别保留专属分类；FUNCTION、PD、MR、CQ、CMQ、CEQ、AEQ 及未知 kind
  fail-closed 为 OTHER。QP 只有 outstanding 时阻塞，SRQ/OTHER 无论是否 outstanding
  都阻塞，NONE 不阻塞。
- `rdma_resource_manager::snapshot_activity_blockers()` 仍唯一执行 registry 扫描和
  snapshot 写入，只调用 policy 解释 dependent kind，不复制资源账本或 authority。
- `rdma_resource_manager_test` 新增分类、空闲/在途和未知 kind 矩阵断言。

## 验证

- VCS53 登录 bash：`rdma_resource_manager_test` 编译、PROCESS、LOGICAL PASS，UVM
  warning/error/fatal 为 0/0/0。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check`：PASS。
- 当前源码边界的 core regression 仍在运行，完成后将重新执行一次包含本批的完整
  parent/core/integration 验证。

## 未关闭项

SRQ 全生命周期组合、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部
ordering/error/backpressure、manager 外部调用窗口补偿、Phase-1C F2 canonical authority
和最终 ownership/中文契约审计继续 OPEN；项目计划保持 `active`。
