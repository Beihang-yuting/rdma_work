# CMQ Batch 96：AEQE split-ID 纯值职责收敛

本批将 `rdma_queue_data_engine::resolve_aeqe_routes` 中 CQ/EQ split-ID 的重复
计算收敛到模型已有的 `logical_cqn_eqn()`。路由 miss、status 首错、secondary
owner、manager 查找和发布顺序均保留在 queue-data owner 内；本批只移动无状态的
值计算职责。

## 变更边界

- `src/core/rdma_queue_data_engine.sv`：复用 canonical logical CQN/EQN helper，
  不改变 route、epoch 或 owner 生命周期。
- `tests/unit/rdma_aeqe_route_test.sv`、`tests/unit/rdma_queue_codec_test.sv`：
  覆盖 AEQE route 与 codec 组合边界。

## 验证

在 `ubuntu@10.11.10.53` 登录 bash 环境运行的 focused wrapper 均 rc=0、
PROCESS/LOGICAL=1/1、UVM warning/error/fatal=0/0/0：

- `rdma_aeqe_route_test`：
  `evidence/post-batch96-rdma_aeqe_route_test.log`，SHA-256
  `af7f2e5e3eb9abd61383df65f21ba3ec0530b3808d42967585ac156ad8bc3dff`。
- `rdma_queue_codec_test`：
  `evidence/post-batch96-rdma_queue_codec_test.log`，SHA-256
  `ae0a14575ea11eb73690b49feb9a4ef23daf67a76690d1603e101b480356fe02`。

Batch96 后的 core regression 记录为 95/0 process、78 logical pass，但其源码边界
早于 Batch97–99，不能作为最终源码边界证明；后续 gate 必须重新执行。
