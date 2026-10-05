# Batch166：lifecycle result seed

日期：2026-09-24。基线工作树：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标与边界

本批处理 Phase D 中 control-plane、queue lifecycle 和 QP lifecycle executor 重复的
“创建结果对象→写入 transaction id→设置未完成 status→清零 recovery”样板。目标是
统一 detached value staging，而不是把三个业务域合并为一个万能执行器；各 executor
仍独占 policy、CMQ 调用顺序、resource manager mutation、recovery 账本和外部 adapter
生命周期。

## 实现

- 新增 `src/model/rdma_lifecycle_transaction_models.sv`，定义
  `rdma_lifecycle_domain_e` 与 `rdma_lifecycle_result_seed`。
- seed 只保存 domain、transaction id 和 pending message；`validate()` 与
  `initialize_result()` 只生成 detached `rdma_control_result` 初始值，不读取或复制
  mutable ledger，也不持有 manager/CMQ/Host-memory/PCIe 引用。
- `rdma_queue_lifecycle_executor::make_result()`、
  `rdma_control_plane::make_result()` 和 QP executor 新增的 `make_result()` 共用 seed；
  QP create/modify/destroy/recover 只在 seed 完成后追加各自 `resource_h`、最终状态、
  completed steps 和 recovery 证据。
- transaction id 为 0 的拒绝仍由各入口保留，seed 不改变 exhaustion、错误优先级、
  CMQ 顺序或 commit owner。

## 所有权与行为复审

- seed 的状态只在事务结果发布前存在，未建立第二份 result ledger 或锁。
- 结果 status/primary_status 使用独立 clone；调用方后续修改结果不会回写 seed 或
  其他 executor 的诊断对象。
- seed 分配、校验或 clone 失败时保持 fail-closed；入口不继续进行外部 I/O，也不
  伪造成功结果。

## 验证

- VCS53 登录 bash：`rdma_control_plane_test`、`rdma_queue_lifecycle_test`、
  `rdma_qp_lifecycle_test` 均 PROCESS/LOGICAL PASS，UVM
  `WARNING=0/ERROR=0/FATAL=0`。
- `git diff --check`、changed-SV style 通过；VCS 编译同时覆盖新增 model package
  include 与三个 executor 的实际调用路径。

## 未关闭边界

本批不关闭 reset coordinator evidence/candidate、QP/SRQ 跨资源 destroy dependency、
跨队列/跨线程并发、SQD/SQE drain/flush、外部 PCIe ordering/error、manager 外部调用窗口
补偿或最终 ownership/Phase-1C F2 审计；项目级计划继续保持 `active`。
