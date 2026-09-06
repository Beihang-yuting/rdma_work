# RDMA UVM driver

本仓库实现面向 XTR RDMA 0.1.34 驱动的 UVM 语义模型、codec、控制面和数据面
队列引擎。生产 core 只依赖本仓库的抽象 adapter；Host/PF/VF/BDF/BAR、global
Function ID 和 topology 由 `dpu_common` 冻结快照提供，外部 host-mem、PCIe、AXIS
VIP 和 `net_packet` 的对象由各自环境拥有。

## 目录与边界

- `src/model`：Function、queue、QP/CQ、UMEM/PBL/MW 和事务证据的值模型。
- `src/codec`：QPC、SQE/RQE/CQE、doorbell、context body 和 CMQ 编解码。
- `src/core`：SQ/RQ/CQ/EQ、CMQ、资源管理和生命周期执行器；不包含外部 VIP 实现。
- `src/adapter`：Host-memory、PCIe、Function table、ABI v5 和网络抽象接口。
- `src/adapters/net_packet`：可选的 `net_packet` 报文生成/解析适配器。
- `tests/unit`：不依赖外部仓库的模型和 codec 回归。
- `tests/integration`：`dpu_common`、真实 host-mem 或 `net_packet` 依赖的回归。
- `hw/rdma`：从驱动归档提取的只读来源清单和 golden vectors；不复制外部源码。

## 固定依赖

CMQ/codec 基线来自 `/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz`，
其字段和 SHA-256 由 `hw/rdma/source_manifest.txt` 与
`tools/check_rdma_profile_names.py` 校验。可选外部依赖必须使用以下完整 checkout：

| 依赖 | 环境变量 | 固定版本 |
| --- | --- | --- |
| dpu_common | `DPU_COMMON_ROOT` | 由仿真环境提供的 snapshot 实现 |
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

所有 VCS 命令必须通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 的登录 bash
中执行。核心和集成分层如下：

```bash
scripts/run_vcs53.sh rdma_defs rdma_defs_test
scripts/run_vcs53.sh core regression
DPU_COMMON_ROOT=/path/to/dpu_common \
  scripts/run_vcs53.sh integration regression
HOST_MEM_ROOT=/path/to/host_mem \
  scripts/run_vcs53.sh host_mem regression
NET_PACKET_ROOT=/path/to/net_packet \
  scripts/run_vcs53.sh net_packet regression
```

也可以运行固定清单脚本：

```bash
scripts/run_queue_lifecycle_regression53.sh
scripts/run_host_mem_regression53.sh
```

每次 suite 都会生成本地临时 build/log，并调用
`scripts/check_uvm_summary.sh`；可接受的最终摘要必须是
`warning=0 error=0 fatal=0`。当前仓库没有独立的 AXIS VIP adapter/filelist，
因此 `AXIS_VIP_ROOT` 仅作为后续外部集成预留，不会被 core 编译或伪造为已通过。

更完整的命令、依赖 preflight、测试范围和已验证证据见
[`docs/rdma-0.1.34-gap-closure-verification.md`](docs/rdma-0.1.34-gap-closure-verification.md)。
