# RDMA UVM driver

本仓库按 XTR RDMA 0.1.34 内核驱动的形状建模主机侧驱动（`src/drv`）与设备侧（`src/dev`），二者只经
真实硬件边界交互：CMQ 环、MMIO doorbell（BAR+0x2000 窗口）与按 IOVA 的 DMA。UVM 验证环境
（`src/tb`）在其上运行 seq → 驱动 → 设备 → 报文 → 内存的端到端数据检查。外部 host-mem、PCIe 与
`net_packet` 的对象由各自环境拥有，经 `src/adapter(s)` 接入。

## 目录与边界

- `src/types`、`src/model`：状态码、句柄、DMA mapping、报文与 context 等值模型。
- `src/codec`：QPC、SQE/RQE/CQE/CEQE/AEQE、doorbell、context body 与 CMQ 编解码；`rdma_defs.svh`
  为驱动头文件字段坐标（冻结清单 `hw/rdma/frozen_abi_manifest.txt`）。
- `src/drv`：驱动模型（probe/remove、CMQ、HMC、EQ、PD/MR/CQ/SRQ/QP verbs、post_send/post_recv/
  poll_cq、URC、CQ resize、flush/cq_clean）。
- `src/dev`：设备模型（CMQ 消费者与 context 存储、HMC 地址翻译、NIC 数据面、CQE/CEQE/AEQE、FLR）。
- `src/core`：CMQ 参考引擎（cmq.c 环/pending/watchdog）、transport 与 doorbell 调度器，供 CMQ golden
  门禁使用。
- `src/tb`：verb agent、wire、记分板、env 与流量序列。
- `src/adapter`、`src/adapters/*`：Host-memory、PCIe、网络抽象接口与 host_mem/net_packet/pcie_work 绑定。
- `tests/unit`：不依赖外部仓库的回归（core suite）；`tests/integration`：真实 host-mem、
  `net_packet` 或 pcie_work 依赖的回归。
- `hw/rdma`：从驱动归档提取的只读来源清单和 golden vectors；不复制外部源码。
- `docs/rdma-driver-shaped-arch.md`：驱动形状架构与迁移计划；`docs/rdma-uvm-flow-design.md`：UVM 流程；
  `docs/rdma-arch-slim-report.md`：feature/rdma-arch-slim 总报告；`docs/history`：只读历史记录。

## 固定依赖

CMQ/codec 基线来自 `/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz`，
其字段和 SHA-256 由 `hw/rdma/source_manifest.txt` 与
`tools/check_rdma_profile_names.py` 校验。可选外部依赖必须使用以下完整 checkout：

| 依赖 | 环境变量 | 固定版本 |
| --- | --- | --- |
| host_mem | `HOST_MEM_ROOT` | `3b9e000d5df4d10efbb3029f43605e0362e0caca` |
| net_packet | `NET_PACKET_ROOT` | `6766c4f042484814548481065328ffbcffab590f` |

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
scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
scripts/run_vcs53.sh core regression
scripts/run_vcs53.sh cmq_gate regression
HOST_MEM_ROOT=/path/to/host_mem \
  scripts/run_vcs53.sh host_mem regression
NET_PACKET_ROOT=/path/to/net_packet \
  scripts/run_vcs53.sh net_packet regression
HOST_MEM_ROOT=... NET_PACKET_ROOT=... \
  scripts/run_vcs53.sh e2e rdma_tb_e2e_test
```

也可以运行固定清单脚本：

```bash
scripts/run_queue_lifecycle_regression53.sh
scripts/run_host_mem_regression53.sh
```

每次 suite 都会生成本地临时 build/log，并调用 `scripts/check_uvm_summary.sh`；可接受的最终摘要必须是
`warning=0 error=0 fatal=0`。

## CMQ 门禁

CMQ wire gate 以真实的 `dpu_kernel_rdma-version_0.1.34.tar(1).gz` 归档、source manifest 和 C oracle
为唯一 ABI 来源：70 个 opcode 的请求逐字节对比驱动 golden（`rdma_cmq_request_golden_test`），字段
变异契约（`rdma_cmq_driver_field_mutation_test`），驱动模型与设备模型的 CMQ 往返（`rdma_drv_cmq_test`、
`rdma_dev_cmq_test`、`rdma_drv_verbs_test`）。清单见 `sim/cmq_gate.list`。
