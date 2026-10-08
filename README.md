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
  - `dpu`：dpu_common 拓扑 → 每个 Function 的设备、内存、BAR、驱动；Function key、BDF、global ID、BAR、
    parent 与 caps 按值冻结并在 attach 时对快照复核；MAILBOX/MSI-X local vector 0、mask/pending 与投递结果
    按 Function 隔离；
  - `pcie_work`：BAR 写与设备 DMA 经 PCIe TLP（pcie_work suite），启用 FC、事务记分板与覆盖率，并检查
    Completion timeout/UR/CA；
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
python3 tools/check_changed_sv_style.py --base HEAD --all
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

## completion 分支能力与边界

- SEND/WRITE 按 `ACK_REQ_TH` 周期请求中间 ACK，末段仍强制请求 ACK；请求方只在累计 ACK 真正前进时重启
  RTO，超时后从最高累计确认 PSN 的下一段继续。`PSN_RETRY_TH=7` 按无限重试处理，并拒绝越界、陈旧或
  opcode 不匹配的 ACK/NAK。RNR 后不采纳线上无法区分代次的中间累计 ACK，只允许 sequence NAK 安全恢复；
  正常代次仍拒绝已确认前缀的陈旧 sequence NAK。目标 QPC 的冻结 service type 是 transport 权威，QP 进入
  RESET/ERR/RTR 新协议 epoch 时清理分段、sequence/RNR 门控与原子重放状态。
- QP epoch 切换前必须先停流；若与旧 epoch 中 `PSN_RETRY_TH=7` 且无 RTO 的 WQE 并发切换，该 WQE 可能永久
  等待。`atomic_cache` 会在 RESET/ERR/RTR 清除，但同一超长 epoch 内没有权威 replay window 可安全退休。
  `ACK_REQ_TH` 仍直接按字段值解释，默认值路径已覆盖，0/1/7 尚未专项扩测；URC 也尚无独立部分重传专项。
- MAILBOX/MSI-X 只建模每 Function 的 local vector 0。Function key、BDF、global ID、三类 BAR、parent 与 caps
  均按值冻结，attach 时重新对 dpu_common snapshot 逐项复核。`mailbox_msix_vectors` 必须等于 1；全局 MSI-X
  数量不是每 Function 的本地容量。ACK offset 读取当前 64 位 publication token，软件必须精确回写；错误、
  重复、旧发布或跨 FLR/recover 的 token 返回 `RDMA_SC_STALE_GENERATION`。该机制只是适配器内的寄存器与
  事件队列，并非真实 PCIe MSI-X MemWr，CEQ/AEQ 也尚未全部自动接入。
- PCIe 适配器按 Host+BDF 保留 authority，启用 pcie_work 的 FC、事务记分板和覆盖率；设备 MemRd 的
  timeout 映射为可重试 `RDMA_SC_TIMEOUT`，UR/CA 映射为保留原始 Completion 状态的
  `RDMA_SC_PCIE_COMPLETION`。timeout tag 在本次仿真剩余生命周期内 quarantine，防止迟到 Completion
  与复用 tag 发生 ABA 混淆。正式依赖 `1a80801e` 与候选 `9aedf898` 的 basic/fault 均为 W/E/F=`0/0/0`；
  历史 `4b7b8d70` 只证明编译兼容，不能作为动态通过证据。只有 pcie_work suite 的 DMA 走 PCIe，其余 suite
  使用后门 DMA。

## completion 分支验证快照（2026-10-08）

| 门禁 | 结果 |
| --- | --- |
| Python unit | 173/173 通过 |
| profile naming / shell syntax / `git diff --check` | 通过 |
| changed-SV style | 无 hard diagnostic；23 条既有 soft-limit 长行 |
| `rdma_defs/rdma_cmq_driver_contract_test` | 通过 |
| core / cmq_gate / env | 15/15、5/5、9/9，均 exit 0，逐项 W/E/F=`0/0/0` |
| env 合并覆盖率 | `RDMA_COV merged=97.46` |
| pcie_work 正式依赖 `1a80801e` | basic/fault 均 exit 0，W/E/F=`0/0/0` |
| RXE | 3/3 pristine，全部 exit 0，逐项 W/E/F=`0/0/0`；`rdma_env_rxe_test` coverage total=67.4 |

## CMQ 门禁

CMQ wire gate 以真实的 `dpu_kernel_rdma-version_0.1.34.tar(1).gz` 归档、source manifest 和 C oracle
为唯一 ABI 来源：`rdma_drv_cmq_golden_test` 逐字节核对 70 个 opcode 的驱动请求，
`rdma_dev_cmq_test`、`rdma_drv_cmq_test`、`rdma_drv_dev_test` 和 `rdma_drv_verbs_test` 分别验证设备解码、
驱动往返、设备生命周期状态效果和 verbs 调用链。权威清单见 `sim/cmq_gate.list`。
