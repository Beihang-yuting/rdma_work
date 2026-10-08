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

### RDMA Completion、Root 隔离与错误传播

2026-10-08 在同一台 53 机上对 completion 分支运行：

```bash
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current \
NET_PACKET_ROOT=/home/ubuntu/net_packet_rocev2 \
PCIE_WORK_ROOT=<candidate> \
scripts/run_vcs53.sh pcie_work regression
```

以下两个完整依赖树都完成 compile/elab/link 和两项仿真：

| `pcie_work` 树 | `rdma_env_pcie_test` | `rdma_env_pcie_fault_test` |
| --- | --- | --- |
| 锁定树 `1a80801e7d336ceeb492e7cdf57ba26ef27c2456` | `INFO=13/WARNING=0/ERROR=0/FATAL=0` | `INFO=20/WARNING=0/ERROR=0/FATAL=0` |
| completion 候选 `9aedf898f44ca260f3120a3fb162b7bb9fbafb5e` | `INFO=13/WARNING=0/ERROR=0/FATAL=0` | `INFO=20/WARNING=0/ERROR=0/FATAL=0` |

fault test 中 Root0/Root1 的 scoreboard 最终分别为
`requests/completions/matched/timed_out=716/1335/341/2` 和
`593/703/181/1`，两边 `mismatched=0`、`unexpected=0`。测试显式让两个 Root 的 PF0
使用相同 BDF 与 tag：Root1 后登记并持有外部全局 registry 的同一键，Root0 先超时退休时不得删除或
唤醒 Root1，Root1 随后独立超时。两个 EP 各自 quarantine 该 `{requester_id, tag}`，且 tag pool
保持无重复项。

同一负向测试还覆盖直接设备 DMA 的 timeout、UR、CA，以及真实 CMQ SQE fetch 的 UR：timeout 映射为
可重试 `RDMA_SC_TIMEOUT`，UR/CA 映射为带原始 Completion code 的
`RDMA_SC_PCIE_COMPLETION`，失败读清空输出，设备和适配层错误账本一致。report catcher 只在每次
明确 arm 的窗口内降级三条预期 timeout error 和三条预期 UR/CA warning；窗口外报告仍保持原等级。

兼容实现刻意不调用版本行为不同的 `pcie_tl_ep_driver::handle_completion()`：适配层只使用两棵树共有的
`rb_note_completion()`，再按统一内存或 legacy 路径的既有 tag 所有权结算。外部
`pcie_rb_registry` 的键没有 Root 维度，因此清理前必须同时匹配原 request 句柄；若同 BDF/tag 已被
另一 Root 覆盖，当前 Root 严格不修改该键。timeout tag 不归还 pool，而在本次仿真剩余生命周期内
隔离，这是缺少 wire generation 时避免迟到 Completion ABA 的保守策略。

历史 `4b7b8d70fa3b1af3c317623553224d0bdcfd0a58` 只有旧 read-back/EP 行为，尚无
`pcie_dpu_integration`，因此不能被表述为完整 RDMA suite 回归。兼容性夹具使用首个具备当前集成壳的
`b1c9fcac3a19eecc2abbfc767bdba4f83c497656`，精确覆盖回 4b 的 `pcie_tl_tlp.sv` 与
`pcie_tl_ep_driver.sv` 后已通过编译和链接；仿真在 time 0 被 b1c9 的全局 BDF 唯一性检查拒绝，因为该
版本不能表示双 Root/segment 合法复用 BDF `0010`，尚未进入 read-back/tag 路径。因此 4b 只形成源码
API 兼容证据，不计作动态绿灯；动态结论来自上表两个完整依赖树。

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

这两项只证明供应商本体的窄 TL error/ordering 契约。RDMA adapter 与 timeout/UR/CA、同键
tag-conflict 和 multi-root 的组合已由上一节补齐；malformed TLP、DMA/backpressure 与更广的
SR-IOV stress 仍需单独接入本项目矩阵。

## 当前完成度判断

- pcie_work 采用方案：**已落地**（锁摘要、adapter seam、adapter focused 和 SR-IOV
  focused 均有证据）。
- host_mem candidate regression：**已完成**；pcie_work adapter/SR-IOV focused、RDMA
  Completion/Root 隔离回归与供应商 TL-only error/ordering smoke 已完成，但 pcie_work 更广的
  malformed/backpressure/SR-IOV stress matrix 及与其余 RDMA integration suite 的组合证据仍未完成。
- RDMA 整体结构重构：**未完成**。当前可靠口径为结构实现约 `70%–80%`、完整验收约
  `55%–65%`；剩余项包括 Phase-1C F2 全局 `sge_num`、legacy CMQ consumer、UD
  receive/replay、legacy descriptor、malformed CQE/恢复组合、跨队列并发/全局锁、SRQ
  全 lifecycle、snapshot alias/ownership 和 coordinator 生命周期审计。

因此，pcie_work 接入是一个已经通过 focused gate 的里程碑，不是整项重构的完成标记。
