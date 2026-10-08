# RDMA UVM driver

本仓库按 XTR RDMA 0.1.34 内核驱动的形状建模主机侧驱动（`src/drv`）与设备侧（`src/dev`），二者只经
真实硬件边界交互：CMQ 环、MMIO doorbell（BAR+0x2000 窗口）与按 IOVA 的 DMA。UVM 验证环境
（`src/tb`）在其上运行 seq → 驱动 → 设备 → 报文 → 内存的端到端数据检查。外部组件（dpu_common、host_mem、
`net_packet`、pcie_work）直接引用，不复制源码，由使用者经 `*_ROOT` 指定；对接代码在 `src/adapters/<组件>`。

## 目录与边界

- `src/types`、`src/model`：状态码、枚举、语义报文 `rdma_packet` 与硬件镜像等值模型。
- `src/codec`：QPC、SQE/RQE/CQE/CEQE/AEQE、doorbell、context body 与 CMQ 编解码；`rdma_defs.svh`
  为驱动头文件字段坐标（冻结清单 `hw/rdma/frozen_abi_manifest.txt`）。
- `src/drv`：驱动模型（probe/remove、CMQ、HMC、EQ、PD/MR/CQ/SRQ/QP verbs、post_send/post_recv/
  poll_cq、URC、CQ resize、flush/cq_clean）。
- `src/dev`：设备模型（CMQ 消费者与 context 存储、HMC 地址翻译、NIC 数据面、CQE/CEQE/AEQE、FLR）。
- `src/tb`：UVM env（资源层、ctrl/verb agent、链路、scoreboard、协议检查、覆盖率、序列）。
- `src/adapters/<组件>`：外部组件对接，每个组件一个目录：
  - `host_mem`：每个 Host 一个 host_mem manager，每个 Function 一个按 Function 记账的内存视图（IOVA =
    Host 地址，DMA 只能访问本 Function 的分配）；
  - `net_packet`：`rdma_packet` ↔ RoCEv2 帧编解码（`rdma_netpkt_codec`）；
  - `dpu`：dpu_common 拓扑 → 每个 Function 的设备、内存、BAR、驱动；
  - `pcie_work`：BAR 写与设备 DMA 经 PCIe TLP（pcie_work suite）；
  - `rxe`：经 TAP 与 Linux Soft-RoCE 互打（rxe suite）。
- `tests/unit`：模型与驱动单元测试、codec 测试；`tests/integration`：rxe 互打测试；`tests/rdma_env_test_pkg.sv`：
  env 测试。
- `hw/rdma`：从驱动归档提取的只读来源清单和 golden vectors；不复制外部源码。
- `docs/rdma-driver-shaped-arch.md`：驱动形状架构与迁移计划；`docs/rdma-uvm-flow-design.md`：UVM 流程；
  `docs/rdma-arch-slim-report.md`：feature/rdma-arch-slim 总报告；`docs/history`：只读历史记录。

## 外部依赖

CMQ/codec 基线来自 `/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz`，
其字段和 SHA-256 由 `hw/rdma/source_manifest.txt` 与
`tools/check_rdma_profile_names.py` 校验。外部组件由使用者提供 checkout 并经环境变量指定（不锁版本，
预检只确认关键文件存在）：

| 依赖 | 环境变量 | 用于 |
| --- | --- | --- |
| dpu_common | `DPU_COMMON_ROOT` | 全部 suite |
| host_mem | `HOST_MEM_ROOT` | 全部 suite |
| net_packet | `NET_PACKET_ROOT` | 全部 suite |
| pcie_work | `PCIE_WORK_ROOT` | pcie_work suite |

外部源码不会同步进本仓库，也不应把访问令牌写入 remote URL、脚本或配置文件。

## 本地静态检查

```bash
python3 tools/check_rdma_profile_names.py
python3 -m unittest discover -s tests/unit -p 'test_*.py'
git diff --check
```

本地 Python 检查不需要 VCS license，也不替代 53 主机上的 SystemVerilog 编译。

## VCS53 回归入口

所有 VCS 命令必须通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 的登录 bash 中执行：

```bash
export DPU_COMMON_ROOT=... HOST_MEM_ROOT=... NET_PACKET_ROOT=...
scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
scripts/run_vcs53.sh core regression
scripts/run_vcs53.sh cmq_gate regression
scripts/run_vcs53.sh env regression        # 结束时打印合并覆盖率 RDMA_COV merged=
PCIE_WORK_ROOT=... scripts/run_vcs53.sh pcie_work regression
scripts/run_vcs53.sh rxe regression        # 需先在 53 上 tools/rxe/rxe_tap_setup.sh up
```

也可以运行固定清单脚本：

```bash
scripts/run_queue_lifecycle_regression53.sh
```

每次 suite 都会生成本地临时 build/log，并调用 `scripts/check_uvm_summary.sh`；可接受的最终摘要必须是
`warning=0 error=0 fatal=0`。

## CMQ 门禁

CMQ wire gate 以真实的 `dpu_kernel_rdma-version_0.1.34.tar(1).gz` 归档、source manifest 和 C oracle
为唯一 ABI 来源：`rdma_drv_cmq_golden_test` 逐字节核对 70 个 opcode 的驱动请求，
`rdma_dev_cmq_test`、`rdma_drv_cmq_test`、`rdma_drv_dev_test` 和 `rdma_drv_verbs_test` 分别验证设备解码、
驱动往返、设备生命周期状态效果和 verbs 调用链。权威清单见 `sim/cmq_gate.list`。
