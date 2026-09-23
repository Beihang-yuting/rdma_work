# pcie_work 接入与重构验收补充证据

本记录说明用户指定的 `https://github.com/Beihang-yuting/pcie_work` 如何接入重构后的
RDMA 分支，以及哪些验证已经完成。它只覆盖外部 PCIe/Host-memory 适配边界，不把
focused integration 结果扩大解释为整个 RDMA 结构重构完成；总计划仍保持 `active`。

## 固定依赖与供应链边界

| 依赖 | 固定值 | 锁定摘要 |
| --- | --- | --- |
| `pcie_work` | commit `1a80801e7d336ceeb492e7cdf57ba26ef27c2456` | 依赖闭包 tree SHA-256 `8a9853c2cb618b5f73f4d2fed2167fad3a7b08bce37298cfef9ea159b1c5feb1`，75 个文件行，全部 `APPROVED` |
| `host_mem` | commit `365b7553fc7dac6b4ad55886a8e4869153607c28` | 依赖闭包 tree SHA-256 `b9cd7d686c954823bdeafcea2f02013908fed51db5a8f4d39e96e5e877f6c770`，2 个直接源码行，全部 `APPROVED` |

锁文件为 [`hw/rdma/external_dependencies.tsv`](../hw/rdma/external_dependencies.tsv)。
以下命令在干净本地 clone 上均成功（只读校验，不修改外部仓库）：

```bash
python3 tools/check_external_dependency_lock.py verify \
  --lock hw/rdma/external_dependencies.tsv \
  --dependency pcie_work --root /tmp/pcie_work-clean.npb6I7
python3 tools/check_external_dependency_lock.py verify \
  --lock hw/rdma/external_dependencies.tsv \
  --dependency host_mem --root /tmp/host_mem-clean.5OFmNs
```

适配层只消费 pcie_work 的 `pcie_tl_func_manager`、`pcie_tl_bar_decoder`、
`pcie_tl_config_proxy`、`pcie_tl_func_context`、`pcie_tl_sriov_cap`、`pcie_tl_mem_tlp`
和 `pcie_tl_cq_route_t` 等公开类型；没有复制、覆盖或修改外部源码。pcie_work 上游
当前 commit 缺少 root `README.md`、`LICENSE` 和 tag/release 元数据，这是需要在正式
供应链审批中保留的 provenance 风险，不影响本次锁摘要校验。

GitHub `main` 在 2026-09-22 复核仍指向上述 commit（`git ls-remote` 返回
`1a80801e7d336ceeb492e7cdf57ba26ef27c2456`），因此本记录采用的是当前 main 快照，
不是过期分支。供应商 `pcie_tl_vip/tests` 当前有 68 个 TL test class，但本项目依赖锁
只编译公开 package closure 和本项目 adapter/SR-IOV test，不把未纳入的供应商测试数量
当作本项目回归通过数。

## 53 机验证

所有 VCS 命令都在 `ubuntu@10.11.10.53` 的登录 bash 中执行，外部候选目录为：

```text
/home/ubuntu/workspace/pcie_work.audit.current
/home/ubuntu/workspace/host_mem.audit.current
```

### adapter 契约

```bash
cd /home/ubuntu/workspace/rdma_pcie_current.3uxCsY/sim
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work.audit.current \
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current \
make pcie_work TEST=rdma_pcie_work_adapter_test
```

结果：compile/elab/link、仿真和 `check_uvm_summary.sh` 均通过；exit `0`，
`UVM_INFO=4`、`UVM_WARNING=0`、`UVM_ERROR=0`、`UVM_FATAL=0`。该结果证明重构后的
adapter 与 pcie_work main 的类型/调用契约兼容。

### SR-IOV真实 config-proxy 路径

```bash
cd /home/ubuntu/workspace/rdma_pcie_current.3uxCsY/sim
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work.audit.current \
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current \
make pcie_work TEST=rdma_sriov_enumeration_test
```

结果：compile/elab/link、仿真和 `check_uvm_summary.sh` 均通过；exit `0`，
`UVM_INFO=260`、`UVM_WARNING=0`、`UVM_ERROR=0`、`UVM_FATAL=0`。夹具使用真实
`pcie_tl_config_proxy` BAR sizing/config-space 往返，而不是 model bypass；fault proxy
在 build phase 预创建并在串行 fixture 之间复用，避免 UVM late-component 创建错误。
测试覆盖双 PF/VF 枚举、非零 BAR 回滚、null status fail-closed、既有 SR-IOV ownership
拒绝、非法 VF BAR owner 和 VF1 vendor-read 故障注入。

### host_mem candidate regression

在同一登录 bash 中运行 `make host_mem TEST=regression`，三项均通过：

| 测试 | UVM summary | 额外证据 |
| --- | --- | --- |
| `rdma_host_mem_adapter_test` | `INFO=17/WARNING=0/ERROR=0/FATAL=0` | 14 次 leak check 均为 0 |
| `rdma_queue_data_engine_host_mem_test` | `INFO=17/WARNING=0/ERROR=0/FATAL=0` | 12 个 CQ sample、1 个 event sample、leak=0 |
| `rdma_host_mem_umem_test` | `INFO=4/WARNING=0/ERROR=0/FATAL=0` | leak=0 |

早先出现的随机首地址和 CQC shadow 错误来自未同步最新测试夹具的远端 checkout；当前
测试分别显式选择 `HOST_MEM_FIRST_FIT`（只用于固定地址断言）并为真实 CQ/event fixture
启用 CQC context shadow，生产 adapter 与 host_mem 默认随机策略均未被改写。

### 供应商 TL error/ordering smoke

在同一登录 bash、临时 VCS build 目录中直接运行锁定 `pcie_work` 的 TL-only smoke：

| 测试 | UVM summary | 额外证据 |
| --- | --- | --- |
| `pcie_tl_smoke_err_test` | `INFO=5/WARNING=0/ERROR=0/FATAL=0` | poisoned/error 基础路径；日志 SHA-256 `8cf4c120ffd811fb0f0b272c5643007e13c5a11df070f0bebbe4ae6d8601d521` |
| `pcie_tl_smoke_ordering_test` | `INFO=6/WARNING=0/ERROR=0/FATAL=0` | scoreboard `2 requests / 1 completion / 1 matched`；日志 SHA-256 `2e3e43e290b2fd014058e54c1576aafff52a6a3804946712f49a7f64050e3219` |

这两项只证明供应商本体的窄 TL error/ordering 契约；RDMA adapter 与 TL fault 的组合、
timeout、malformed TLP、tag-conflict、DMA/backpressure、多 root 和 SR-IOV stress 仍需
单独接入本项目矩阵。

## 当前完成度判断

- pcie_work 采用方案：**已落地**（锁摘要、adapter seam、adapter focused 和 SR-IOV
  focused 均有证据）。
- host_mem candidate regression：**已完成**；pcie_work adapter/SR-IOV focused 与供应商
  TL-only error/ordering smoke 已完成，但 pcie_work 更广的 matrix 及与其余 RDMA
  integration suite 的组合证据仍未完成。
- RDMA 整体结构重构：**未完成**。当前可靠口径为结构实现约 `70%–80%`、完整验收约
  `55%–65%`；剩余项包括 Phase-1C F2 全局 `sge_num`、legacy CMQ consumer、UD
  receive/replay、legacy descriptor、malformed CQE/恢复组合、跨队列并发/全局锁、SRQ
  全 lifecycle、snapshot alias/ownership 和 coordinator 生命周期审计。

因此，pcie_work 接入是一个已经通过 focused gate 的里程碑，不是整项重构的完成标记。
