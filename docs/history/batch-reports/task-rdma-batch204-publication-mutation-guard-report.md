# Batch204：resource publication mutation guard

日期：2026-09-25

## 目标

resource manager 的 detached publication、QP progress 和 queue progress 都在完成
projection/validation 后进入最终账本写入窗口。此前这些 commit 点没有共同的竞争门禁，
使并发调用只能依赖 epoch/duplicate 检查，难以明确表示“当前 commit 正在进行”。本批
增加一把只保护最终无外部调用写入窗口的 semaphore，避免把锁带入 factory、adapter 或
caller-owned backing 生命周期。

## 实现

- `rdma_resource_manager` 新增 `mutation_guard`，在构造时建立单 token owner。
- `commit_resource_publication()`、`commit_qp_progress()`、`commit_queue_progress()`
  在 validation 后、registry/recovery/epoch mutation 前尝试获取 guard；忙时返回
  `RDMA_SC_RESOURCE_BUSY`，candidate 和账本保持不变，成功或失败均归还 token。
- guard 不覆盖 stage projection、allocator reservation 或外部 callback；manager 仍是
  registry、recovery、allocator、generation 和 publication epoch 的唯一 owner。
- `rdma_resource_manager_probe` 暴露仅用于测试的 hold/release seam，publication 测试
  注入竞争并断言 busy commit 原子失败。

## 验证

- `scripts/run_vcs53.sh core rdma_resource_manager_test`：PROCESS PASS，LOGICAL PASS，
  UVM warning/error/fatal `0/0/0`。
- `scripts/run_vcs53.sh core regression`：97/97 PROCESS PASS、80/80 LOGICAL PASS，所有
  UVM summary warning/error/fatal `0/0/0`。
- `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common scripts/run_vcs53.sh integration regression`：
  10/10 integration tests，10/10 UVM report pristine，warning/error/fatal `0/0/0`。
- Python unit tests：`293/293 PASS`；CMQ manifest tests：`23/23 PASS`。
- changed-SV style、queue lifecycle、profile naming、Phase-1A approval 和 `git diff --check`：PASS。

## 范围与遗留

本批只关闭三个 detached commit seam 的最终写入竞争窗口，不宣称整个 resource registry
或 allocator 已具备跨线程/跨进程完整互斥；SRQ 全生命周期、跨 queue/engine 全局原子性、
SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2
whole-plan 和最终 ownership/生命周期注释审计仍由项目计划保持 `active`。
