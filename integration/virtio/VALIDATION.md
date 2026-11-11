# 组合环境验证记录

验证日期：2026-11-11。所有 VCS 编译/仿真均在 `ubuntu@10.11.10.53` 的 `bash -lic` 环境执行，VCS 为 W-2024.09-SP1、UVM 1.1d。实际编译的是本目录 `project_env_pkg` overlay：`project_env_cfg` 在本地直接包含 RDMA 配置，`project_env`/`project_base_test` 仍来自外部且未修改。

## 输入与产物

- RDMA 工作树：`/tmp/rdma-virtio-compose`。
- 当前依赖快照：`/tmp/rdma-virtio-current-deps/{virtio_work,dpu_common,host_mem,pcie_work,pcie_intel,net_packet,aip_core_set_param_expr}`。
- 组合回归产物：`/tmp/rdma-virtio-compose/output/combined_current`。
- 独立 RDMA 回归产物：`/tmp/rdma-virtio-compose/output/standalone_preserved`。
- 组合 binary SHA-256：`32f189eb6b44a5709a7220c571ea2ee4d9edb60c7dcd20107a9da4ddb9505fac`。
- 组合 build.log SHA-256：`b70481d6498398e1518fd8b0e6c059ee9d1c28ee317efa5f2c26d08d3270fe4e`。

[dependencies.tsv](dependencies.tsv) 记录实际源版本及工作树摘要。`worktree_entries/status_sha256` 来自 `git status --porcelain=v1 -uno`；源码摘要按排序后的相对路径、NUL、文件字节、NUL 累积 SHA-256。virtio 仅打包 `virtio_net_vip/src`、`integration/aip`、`integration/dpu`、`integration/project`、`filelists` 下的 `.sv/.svh/.f`，其他依赖打包 Git 跟踪及未忽略、实际存在的文件。AIP dist 库在该隔离副本中构建。virtio 和 PCIe 的工作树修改已包含，不能只 checkout 对应 HEAD 就认为输入完全相同。

## 实际结果

执行 [tests/run.sh](tests/run.sh)；三个正常结束进程的 UVM WARNING/ERROR/FATAL 均为 `0/0/0`。保存进程在 checkpoint 后 `quit`，通过独立保存标记验收。最终编译只有 VCS `-lca` 的 `LCA_FEATURES_ENABLED` 提示，无新增源码诊断。

| 日志 | 场景与检查 | 结果 |
| --- | --- | --- |
| `two_pf.log` | 同 Host 两个 PF；真实组合 build/connect、VIO/RDMA 共享快照和 pool、统一 loader、无自动配置/初始化 | `RDMA_VIRTIO_COMMANDS_PASS` |
| `multi_host_pf_vf.log` | 两 Host、每 Host 两 PF、每 PF 一个 VF；交换 Host→RC slot，逐节点检查正确 Host manager | `RDMA_VIRTIO_COMMANDS_PASS` |
| `save.log` | 两 Host、每 Host 两 PF；保存 count=10、poll=10 的活动配置及尚未应用的 count=17、poll=27 override | `RDMA_VIRTIO_SAVE_PASS` |
| `restore.log` | 同 binary 新进程 count=20、poll=33；restore 后一次重载先取得快照 override，clear 后再取得新 CLI | `RDMA_VIRTIO_RESTORE_PASS` |
| `vio_only.log` | `+rdma.enabled=0`；两 Host/双 PF 只建立 VIO，RDMA child、service、Function 参数和 Notify/RNET 均未创建 | `RDMA_VIRTIO_VIO_ONLY_PASS` |

命令矩阵同时验证：非法 RDMA count 不提交 DPU/VIO；非法 VIO 固定几何不提交 DPU/RDMA；成功重载原地保留 cfg/scenario、snapshot、pool 和命令句柄；`vio_release` 继续使用原 virtio 对象；`load_params wait=0` 可通过 AIP 原生后台路径完成；反序 `rdma_init/rdma_run` 被拒绝且没有初始化副作用。

组合配置现在由 `rdma_enabled` 门控。关闭时 `load_params` 只调用父类 VIO/DPU 重载，`dut_config` 直接使用 `vio_dpu_cfg_seq`；不会创建 RDMA 子环境、添加 RDMA service、生成 hardware plan 或发送 Notify/RNET，节省仿真时间。显式 `rdma_functions` 或 grant 会在构建前打开 RDMA，混合场景仍使用 `rdma_virtio_cfg_seq`。

本次门控复核在 53 的 `/tmp/rdma-codex.UrQZDM/output/virtio_gated3` 完成：`two_pf`、`multi_host_pf_vf`、`save`、`restore` 和新增 `vio_only` 均通过，`vio_only` 返回 `RDMA_VIRTIO_VIO_ONLY_PASS`；Task6 返回 `PROJECT_TASK6_PASS`，Intel 类型回归返回 `PROJECT_INTEL_TYPES_PASS`。

原 [run_commands.sh](../project/tests/run_commands.sh) 使用原 Task6 依赖快照 `/tmp/rdma-task6-current-deps/deps` 重跑，返回 `PROJECT_TASK6_PASS`。命令、prepare/probe 拒绝、跨进程 restore、无新 CLI 恢复和 namespace 检查均通过；重复注册与配置 fatal 为独立预期负例。未把负例的诊断混入正常通过计数。

本地检查包括 `git diff --check`、`bash -n integration/virtio/tests/run.sh`，以及以 `5966775` 为基线、最终提交为 head 的 `tools/check_changed_sv_style.py`。本次复审覆盖新增目录、原 RDMA 配置预检边界和两处 packet package 类型接入；旧源码中不准确的函数注释随接入一并校正。

## 验证边界

这里的双 PF/多 Host 是组合环境与共享资源验证，没有创建真实 RDMA QP。既有独立 RDMA 模型流量/命令回归另行通过。组合配置 sequence 已编译，真实 `dut_config` 写入、VIO/RDMA 混合收发、Intel credit/reset 和平台 DMA 收尾仍须接入 DUT 后验证。

本例不伪造 RDMA grant；平台仍需发布每个 Function 的 QP/SD/CEQ/AEQ 与路由授权，结构通过不等同于真实 RDMA 初始化通过，也没有新增 RDMA 资源权威。
