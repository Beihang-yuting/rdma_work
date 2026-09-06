# RDMA 0.1.34 缺口收尾验证记录

本文档记录 Task 1–9 的验证入口和证据边界。命令中的外部路径是示例，必须替换为
53 主机上实际存在、且通过 Makefile preflight 的 checkout；本仓库不复制或修改这些
外部源码。所有 VCS 命令由 `scripts/run_vcs53.sh` 转发到 `ubuntu@10.11.10.53`
登录 bash 执行。

## 验证矩阵

| 层级 | 命令 | 依赖 | 通过条件 |
| --- | --- | --- | --- |
| Python 静态 | `python3 tools/check_rdma_profile_names.py` | 无 | profile、0.1.34 manifest 和 golden 约束通过 |
| Python 单元 | `python3 -m unittest discover -s tests/unit -p 'test_*.py'` | 无 | 所有用例 `OK` |
| 定义基线 | `scripts/run_vcs53.sh rdma_defs rdma_defs_test` | VCS53 | `rdma definitions: PASS` |
| core | `scripts/run_vcs53.sh core regression` | VCS53 | 编译并运行所有 core tests，UVM `warning=0 error=0 fatal=0` |
| dpu_common integration | `DPU_COMMON_ROOT=/path/to/dpu_common scripts/run_vcs53.sh integration regression` | dpu_common snapshot | route、PF/VF、reset 和 context tests 全通过 |
| host-mem | `HOST_MEM_ROOT=/path/to/host_mem scripts/run_vcs53.sh host_mem regression` | host_mem commit `3b9e000d5df4d10efbb3029f43605e0362e0caca` | UMEM/PBL/MW、queue backing 和 release 无泄漏 |
| net_packet | `NET_PACKET_ROOT=/path/to/net_packet scripts/run_vcs53.sh net_packet regression` | net_packet commit `6766c4f042484814548481065328ffbcffab590f` | RoCEv2/iWARP pack/unpack 和故障策略全通过 |

`AXIS_VIP_ROOT` 目前只保留在 `run_vcs53.sh` 的环境传递接口中；仓库尚无 AXIS VIP
adapter/filelist，因此不将它伪装成可通过的 suite。待外部 AXIS adapter 明确接口后，
应新增独立 filelist、preflight 和测试，再加入本矩阵。

## 固定来源与清洁边界

- RDMA 驱动归档：`/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz`。
- 归档前缀：`dpu_kernel_rdma-version_0.1.34`。
- 字段来源和 SHA-256：`hw/rdma/source_manifest.txt`。
- profile/字段/golden checker：`tools/check_rdma_profile_names.py`。
- core 不允许直接出现 `net_packet`、`axis_vip`、`pcie_work` 或
  `host_mem_manager` 实现符号；外部对象只能经 adapter 注入。
- 生产和测试普通 SystemVerilog 文件使用 `.sv`；`.svh` 仅用于宏或固定 mask。
- 新增/触及文件的入口、函数和 task 均应具备中文“功能 / 输入输出及副作用 /
  失败/边界”说明。

## 执行记录

本轮（2026-09-06，VCS W-2024.09-SP1，`ubuntu@10.11.10.53`）已重新执行以下命令，均以退出码 `0` 完成：

| 命令 | 结果摘要 |
| --- | --- |
| `python3 tools/check_rdma_profile_names.py` | `rdma profile naming: PASS` |
| `python3 -m unittest discover -s tests/unit -p 'test_*.py'` | `Ran 113 tests`，`OK` |
| `git diff --check` | 无输出，退出码 `0` |
| `scripts/run_vcs53.sh core regression` | 全部 core 用例完成，UVM `warning=0 error=0 fatal=0` |
| `DPU_COMMON_ROOT=/home/ubuntu/dpu-common-external scripts/run_vcs53.sh integration regression` | PF/VF、reset、context 用例完成，UVM `warning=0 error=0 fatal=0` |
| `HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem scripts/run_vcs53.sh host_mem regression` | adapter、queue、UMEM/PBL/MW 完成，host_mem leak check 为 `0 blocks outstanding`，UVM `warning=0 error=0 fatal=0` |
| `NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM scripts/run_vcs53.sh net_packet regression` | adapter 用例完成，UVM `warning=0 error=0 fatal=0` |

VCS 日志中的 `cannot set terminal process group`/`no job control` 是远端非交互登录 shell
的 bash 提示，不是仿真失败；实际判定以每个用例的 UVM summary 和脚本退出码为准。
构建目录、日志、SSH wrapper、外部源码和访问令牌均未加入 Git。若后续某个外部 suite
因依赖路径或 license 缺失无法运行，应记录为环境阻塞，不得把 core 或静态检查结果
冒充该 suite 的通过证据。
