# RDMA Batch183：SRQ/QP destroy admission policy 报告

日期：2026-09-24

## 目标

在不改变 resource manager owner、SRQ flush 顺序或错误码的前提下，将普通释放与
CQ resize 对 QP/SRQ/其它 dependent 的组合阻塞规则集中到纯值 policy，避免 manager
内联条件在 SRQ/QP 组合扩展时漂移。

## 实现

- `rdma_resource_dependency_policy` 新增 `rdma_resource_release_mode_e` 和
  `blocks_release(snapshot, mode)`。
- `RDMA_RESOURCE_RELEASE_STRICT` 保持普通 destroy/finalize 的
  `live_dependents || outstanding` 规则。
- `RDMA_RESOURCE_RELEASE_CQ_RESIZE` 允许空闲 QP 引用 CQ，但拒绝 SRQ/其它 dependent、
  带 outstanding 的 QP 以及 CQ 自身的 outstanding 操作；未知 mode fail-closed。
- `rdma_resource_manager::begin_cq_resize()` 改为调用该 policy；registry 扫描、锁、
  状态提交和外部 backing 生命周期仍由 manager 唯一拥有。
- `rdma_resource_manager_test::test_dependency_policy_matrix()` 增加 idle QP、busy QP、
  idle SRQ、resource outstanding 和 strict release 组合断言。

## 验证

- `rdma_resource_manager_test`：VCS53 登录 bash 中 PROCESS/LOGICAL PASS，UVM
  warning/error/fatal 为 `0/0/0`。
- 需要在本批源码同步后重跑完整 core、integration、CMQ gate、Python 和 style/diff
  验证；在这些结果全部回收前，本批不宣称整项计划完成。

## 未关闭边界

SRQ 全生命周期及完整跨资源 destroy dependency 组合、跨队列/跨线程并发、SQD/SQE
drain/flush、legacy descriptor、外部 ordering/error/backpressure、manager 外部调用窗口、
Phase-1C F2 canonical authority 与最终 ownership 审计继续保持 OPEN。
