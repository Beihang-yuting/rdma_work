# Batch167 reset epoch candidate seam report

## 目标

把 reset coordinator 的 Function epoch staged map 变成显式 detached candidate，减少
VF/PF/Host/Device reset 实现对临时 associative map 的重复表达，同时保持 coordinator
仍是唯一的 epoch ledger owner。

## 实现

- 新增 `src/model/rdma_reset_transaction_models.sv` 与
  `rdma_reset_epoch_candidate`；candidate 只拥有自己的 map、`valid` 标志和
  `capture/validate/clear` 生命周期。
- `prepare_function_epoch_commit()` 统一 capture、scope 预检、递增和 validate；四个
  reset implementation 只在所有其它 scope 检查通过后复制 `candidate.function_epochs`
  并提交 `m_function_epochs`。
- candidate 不读取或复制 lease、authority、router、resource、recovery 或外部对象，
  reset policy、quiesce/release 顺序和 publication owner 保持在 coordinator。
- 单元测试覆盖 detached alias、unknown 值、空但 valid 的 candidate、clear 后拒绝提交
  以及现有 reset scope 行为。

## 验证

在 `ubuntu@10.11.10.53` 登录 bash 中使用锁定的
`DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common` 执行：

- `rdma_reset_coordinator_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- `rdma_reset_coordinator_pf_root_scope_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- `rdma_reset_coordinator_lifecycle_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。

`dpu-common-external` 当前 HEAD/hash 与项目锁不一致，因此未用于验收；没有修改外部
依赖仓库或本项目锁文件。

## 未关闭边界

跨线程/跨进程 coordinator 并发、QP/SRQ 跨资源 destroy dependency、SQD/SQE drain/flush、
外部 PCIe ordering/error、manager 外部调用窗口补偿和最终 ownership 审计仍保持 OPEN；
项目级计划继续为 `active`。
