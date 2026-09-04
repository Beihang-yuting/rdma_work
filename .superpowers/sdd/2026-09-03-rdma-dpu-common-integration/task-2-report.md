# Task 2 报告

## 实现

- 新增 `rdma_dpu_env_pkg`、DPU identity adapter、Host-memory/PCIe router、reset coordinator、Function context 与 Device env。
- DMA request/mapping 增加完整 route key、reset epoch 快照和有效位；legacy core 请求保持兼容，integration router 强制完整 route。
- integration filelist、Makefile target 及最小可观察 UVM 测试已加入。

## API 适配

adapter 使用 dpu_device_snapshot 的 `list_functions/get_pcie_id/get_global_function_id`，并从 host+segment 构造显式 root 映射（当前 dpu_common API 未单独提供 root 字段）。资源 snapshot 要求 frozen。未修改外部 dpu_common、PCIe 或 host-memory 源码。

## 测试

本地环境无 VCS（`vcs: command not found`），因此无法执行仿真。`git diff --check` 通过。按约定应在 53 上设置 `DPU_COMMON_ROOT` 后运行 integration、router 和 core 测试。

## 未决问题

外部 dpu_common filelist 在当前 checkout 不存在，Makefile integration target 要求调用方提供 `DPU_COMMON_ROOT`。PCIe mmio handle 路由依赖 endpoint 信息；若多个 endpoint 无法返回唯一 function info，将返回 ambiguity，需上层传递完整 route。
