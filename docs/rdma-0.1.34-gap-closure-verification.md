# RDMA 0.1.34 缺口收尾验证记录

本文档记录 RDMA 0.1.34 缺口收尾及 Task 28–31B 的验证入口和证据边界。命令中的外部路径必须替换为
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
| host-mem | `HOST_MEM_ROOT=/path/to/host_mem scripts/run_vcs53.sh host_mem regression` | host_mem commit `365b7553fc7dac6b4ad55886a8e4869153607c28`，并通过源码 SHA-256 preflight | UMEM/PBL/MW、queue backing 和 release 无泄漏 |
| net_packet | `NET_PACKET_ROOT=/path/to/net_packet scripts/run_vcs53.sh net_packet regression` | net_packet commit `6766c4f042484814548481065328ffbcffab590f` | RoCEv2/iWARP pack/unpack 和故障策略全通过 |
| multi-VF E2E | `PCIE_WORK_ROOT=... HOST_MEM_ROOT=... NET_PACKET_ROOT=... DPU_COMMON_ROOT=... scripts/run_vcs53.sh e2e rdma_multivf_recovery_test` | dpu_common、pinned host_mem、pinned net_packet | 双 Host/双 PF/四 VF 并发 fault matrix、FLR/generation recovery、CQE/CMQ、真实 mapping release 和 leak seal 全通过 |
| high-traffic E2E | `PCIE_WORK_ROOT=... HOST_MEM_ROOT=... NET_PACKET_ROOT=... DPU_COMMON_ROOT=... scripts/run_vcs53.sh e2e rdma_end_to_end_high_traffic_test` | dpu_common、pinned host_mem、pinned net_packet | 4096×256B、SQ/RQ/CQ window=16、completion batch=4；queue-full、PI/CI、CQE owner/released-slot、真实 mapping 和 Function-qualified event pending 全通过 |

`AXIS_VIP_ROOT` 目前只保留在 `run_vcs53.sh` 的环境传递接口中；仓库尚无 AXIS VIP
adapter/filelist，因此不将它伪装成可通过的 suite。待外部 AXIS adapter 明确接口后，
应新增独立 filelist、preflight 和测试，再加入本矩阵。

高流量 E2E 使用 fixture 中已创建的 CQ 作为 completion 依赖，并验证带完整 Function
身份的 `route_event()`/`end_pending()` 账本；本轮不额外创建 lifecycle-owned CEQ，
因此该用例不宣称真实硬件 CEQ 中断环路已经验证。`write_cq_entry()` 只写入真实
CQ backing，不推进 queue-data runtime 的硬件 producer/used 账本；所以本轮也不把
CQ producer 满载、硬件 CQ backpressure 或 CEQ 中断环路写成已覆盖项。真实 CQE
publish/CEQ 注入点稳定后，应另设独立测试和回归行，避免把组合层事件账本与硬件
中断行为混为一谈。

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

本轮（2026-09-07，VCS W-2024.09-SP1，`ubuntu@10.11.10.53`）重新执行了以下命令，均以退出码 `0` 完成：

| 命令 | 结果摘要 |
| --- | --- |
| `python3 tools/check_rdma_profile_names.py` | `rdma profile naming: PASS` |
| `python3 -m unittest discover -s tests/unit -p 'test_*.py'` | `Ran 122 tests`，`OK` |
| `git diff --check` | 无输出，退出码 `0` |
| `python3 -m unittest tests.unit.test_e2e_multivf_manifest tests.unit.test_multivf_recovery_guards` | `Ran 9 tests`，`OK` |
| `scripts/run_vcs53.sh core rdma_coverage_test` | coverage collector 编译/仿真完成，UVM `warning=0 error=0 fatal=0` |
| `scripts/run_vcs53.sh core rdma_smoke_test` | core smoke 编译/仿真完成，UVM `warning=0 error=0 fatal=0` |
| `PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified HOST_MEM_ROOT=/home/ubuntu/host_mem_latest NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM DPU_COMMON_ROOT=/home/ubuntu/dpu-common-external scripts/run_vcs53.sh e2e rdma_end_to_end_transport_test` | RC/UD/URC transport matrix 编译、elaboration、link 和仿真退出码 `0`；UVM `warning=0 error=0 fatal=0`，Host-memory leak check 为零 |
| `PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified HOST_MEM_ROOT=/home/ubuntu/host_mem_latest NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM DPU_COMMON_ROOT=/home/ubuntu/dpu-common-external scripts/run_vcs53.sh e2e rdma_end_to_end_dual_env_test` | 双 env 传输场景编译、elaboration、link 和仿真退出码 `0`；UVM `warning=0 error=0 fatal=0`，Host-memory leak check 为零 |
| `PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified HOST_MEM_ROOT=/home/ubuntu/host_mem_latest NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM DPU_COMMON_ROOT=/home/ubuntu/dpu-common-external scripts/run_vcs53.sh e2e rdma_end_to_end_high_traffic_test` | 4096×256B、16-entry SQ/RQ/CQ window、每 4 个 completion drain；编译、elaboration、link 和仿真退出码 `0`；UVM `INFO=7/WARNING=0/ERROR=0/FATAL=0`，4 次 Host-memory leak check 均为 `0 blocks outstanding` |
| `PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified HOST_MEM_ROOT=/home/ubuntu/host_mem_latest NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM DPU_COMMON_ROOT=/home/ubuntu/dpu-common-external scripts/run_vcs53.sh e2e rdma_multivf_recovery_test` | 双 Host/双 PF/四 VF fault matrix 完成；两路 Host-memory leak check 均为 `0 blocks outstanding`，UVM `warning=0 error=0 fatal=0` |
| `HOST_MEM_ROOT=/home/ubuntu/host_mem_latest scripts/run_vcs53.sh host_mem regression` | adapter、queue data-engine 和 UMEM 三项均退出码 `0`；每项 UVM `warning=0 error=0 fatal=0`，真实 manager leak check 为 `0 blocks outstanding` |
| `scripts/run_vcs53.sh core regression`、integration/net_packet 全量回归 | 这些全量回归的最近一次基线证据保留在上一轮记录；本轮针对 fail-closed 改动重新执行了上面列出的 coverage、smoke、host-mem、transport、dual-env 和 multi-VF 入口，不将未重跑的全量结果冒充本轮证据 |

本轮 host-mem preflight 使用 `365b7553fc7dac6b4ad55886a8e4869153607c28`，并校验：

- `src/host_mem_pkg.sv` SHA-256：`e874491da16334b12d9299355a3148275309a0c5a2c3303cda2fc7c3382ed74f`；
- `src/host_mem_manager.sv` SHA-256：`6b5eb9bbd94d410b1382a665ddb60347132558fc7882cbed1115f69fa0c1d410`。

VCS 日志中的 `cannot set terminal process group`/`no job control` 是远端非交互登录 shell
的 bash 提示，不是仿真失败；实际判定以每个用例的 UVM summary 和脚本退出码为准。
构建目录、日志、SSH wrapper、外部源码和访问令牌均未加入 Git。若后续某个外部 suite
因依赖路径或 license 缺失无法运行，应记录为环境阻塞，不得把 core 或静态检查结果
冒充该 suite 的通过证据。

## CMQ 仿真诊断边界

在 53 机上，`rdma_cmq_engine_test` 的 VCS 进程会在打印 `Running test ...` 后、任何
测试 UVM 输出前收到 `SIGSEGV`；相同现象可在当前工作树、`HEAD` 基线和 `-no_save`
运行中复现，且发生时进程峰值约 0.5 GB。该现象属于既有 VCS/主机资源或 class-codegen
问题，而不是本轮 multi-VF fixture 引入的业务失败；因此没有修改 CMQ 业务逻辑来掩盖
它。后续若要重新定位，应在资源充足的 53 机上保留独立的最小化诊断，不把该崩溃写成
multi-VF E2E 的通过/失败判据。
