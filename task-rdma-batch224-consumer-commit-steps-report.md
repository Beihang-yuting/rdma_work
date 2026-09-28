<!-- 目录：项目根目录；职责：记录 Batch224 consumer 公共提交步骤、语义核对与验证。 -->

# Batch224：统一 consumer 通知证据与 CI 提交步骤

日期：2026-09-28。基线 `bbbdc4f`，沿用 `feature/rdma-structural-batch222`。
本轮不合并、不推送，main 保持 `5f8dfe9`；项目级重构计划仍 active。

## 本批结构

CQ live poll、CEQ/AEQ live poll 和 consumer replay 原本各自维护相同的两段机制。
现在在既有 engine 内统一为：

- `submit_consumer_doorbell_recorded()`：调用原有可覆写 doorbell seam，校验返回值
  和 SUCCESS evidence，记录真实错误或成功通知；证据无法保存时升级恢复错误。
- `commit_consumer_cursor_recorded()`：开启 runtime gate，调用原有可覆写 CI seam，
  归一化 null 返回，并在失败时保留对应的 shadow/MMIO evidence。

三个 caller 各自调用这两个步骤，删除六处重复实现；不新增生产文件、provider、
运行对象、账本或锁。新增诊断 enum 仅选择原有 18 条固定字符串，不参与资源准入。

| 范围 | Batch223 | Batch224 |
| --- | ---: | ---: |
| queue-data engine | 10,000 行 / 136 methods | 9,977 行 / 138 methods |
| 生产文件净变化 | — | −23 行，新增两个共享步骤 |

本批主要收益是三条路径共用同一份机制，不把小幅行数减少当作整个架构已精简完成。
测试及文档新增行不计入生产净减口径。

## 保持的业务边界

- runtime 仍是唯一 cursor/used/pending/commit gate owner；engine 的全部状态字段不变。
- live caller 仍先校验 candidate，再 admission；CQ 自己决定 shadow 或 legacy doorbell，
  只有 CQ 执行 WQE release；event 自己决定 route miss 时消费但不交付结果。
- replay 仍只有 NO_SUBMIT 分支发送 doorbell；SUCCESS 跳过通知，AMBIGUOUS 拒绝重发；
  已 published 的 shadow、已 committed 的 CI、已 released 的 WQE 不重复执行。
- 无分配约束针对 seam 返回后的 continuation；scheduler 内的既有对象创建顺序不变。
  公共步骤只写 caller-owned status 槽，保留真实错误对象与硬件诊断，不拼接动态字符串。
- 公共步骤是 protected 内部能力，依赖 caller 已校验 runtime/cursor/descriptor/status
  和 pending；不增设另一套 admission，也不假设保存证据一定成功。
- 所有公开 API 和既有 virtual seam 声明不变；外部依赖、codec ABI、dpu_common
  authority 与外部 adapter 生命周期均不修改。

## 等价核对与复审

只读 `/tmp/rdma_batch224_audit.py` 固定基线 `bbbdc4f`，日志为
`/tmp/rdma_batch224_audit_final.log`：

- 133/136 个原方法完整 token（含字符串）不变，全部 136 个原声明不变，其中公开 27 个。
- 对另外三个 caller，将两个公共步骤按诊断 enum 特化、展开，并还原局部 completed/
  返回值协议后，与原 caller 全部 token 相同；包含门禁、虚拟 seam 调用顺序及错误文本。
- 移除方法后的 engine 类壳仅新增诊断 enum，未新增或迁移 mutable owner 字段。
- src/tests/unit 的文件头及逐方法三段注释扫描：194 files / 5,268 methods / 0 diagnostics。

复审覆盖两个新步骤、三个 caller 的完整方法和相邻 staging/seam、runtime 的 evidence
迁移与 noalloc commit 实现、新测试的全部 fixture/故障/断言路径、package 注册和回归
清单。未变化方法继承上一批证据并核对全文 token；机械扫描不替代全项目人工语义验收。

## 新增测试

`rdma_queue_consumer_steps_test` 使用真实 CEQ runtime、单项 committed occupancy 和
预建返回对象；只在 scheduler/CI seam 注入结果，不伪造外部 PCIe 或 CQ shadow 验证。
三种诊断上下文各执行 10 个 doorbell case、5 个 commit case，共 45 个：

- 正常成功、null status、缺 result、错误 evidence 的假成功；
- NO_SUBMIT/AMBIGUOUS 的真实错误对象、硬件字段及 pending 中的诊断保存；
- runtime 已无 pending 时的成功/失败 evidence 保存拒绝；
- gate 拒绝、null/真实 commit 错误、非法 failure evidence 保存失败；
- 返回 status 的对象身份、固定错误文本、调用次数、occupancy 和 committed marker。

用例已进入 core package 和 CORE_TESTS，不是只编译未执行的 probe。六项 Python
结构门禁覆盖三 caller 接入、无分配/无额外 owner 边界、步骤顺序、replay 跳步策略、
18 条原诊断和回归注册。Python 全套 311/311 通过。

首轮 focused 的 commit 保存失败注入误用 `rdma_queue_mmio_evidence_e'(99)`：该 enum
宽度为 3 位，99 截断为合法 SUCCESS，导致三种上下文各三个断言失败。已改为明确的
非法值 `3'd7`，生产实现未改。重跑 45 项全部通过、wrapper rc=0；早期日志
`/tmp/rdma_batch224_focused.log` 保留，不计作通过。

E2E 首次命令误用了未注册的 `rdma_dual_env_coexist_test`，以 INVTST 失败退出；已改用
实际入口 `rdma_end_to_end_dual_env_test` 重跑，初次 `/tmp/rdma_batch224_e2e.log`
不计入最终结果。源码未因这次命令错误而修改。

## 验证状态

本批完整回归通过，以下最终入口的 wrapper 均返回 0。所有 VCS 通过
`scripts/run_vcs53.sh` 在 ubuntu@10.11.10.53 的登录 bash 执行；不在本机运行仿真。

| 验证 | 状态 | 日志（`/tmp/`） |
| --- | --- | --- |
| 45-case focused | 45 项、PROCESS/LOGICAL PASS、UVM pristine、wrapper rc=0 | `rdma_batch224_focused_final.log` |
| core 全量 | 98/98 PROCESS、81/81 LOGICAL、98 pristine、wrapper rc=0 | `rdma_batch224_core.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine、wrapper rc=0 | `rdma_batch224_cmq.log` |
| integration | 10/10 pristine、wrapper rc=0 | `rdma_batch224_integration.log` |
| E2E dual-env / 多 VF / 高流量 | 三项均 pristine，wrapper 均 rc=0 | `rdma_batch224_e2e_final.log` / `rdma_batch224_e2e_multivf.log` / `rdma_batch224_e2e_traffic.log` |
| Host-memory / PCIe adapter | 3/3、1/1 pristine，wrapper 均 rc=0 | `rdma_batch224_host_mem.log` / `rdma_batch224_pcie_work.log` |
| 驱动归档、C oracle、字段归属 | 203 自测、真实归档/definitions/oracle/字段归属通过、rc=0 | `rdma_batch224_driver_contract.log` |
| Python（最终冻结输入） | 311/311、rc=0 | `rdma_batch224_python_final.log` |
| style / diff / lifecycle / profile / Phase-1A | 通过 | `rdma_batch224_style_final.log`（空）及终端记录 |

最终日志计数、45-case 执行标记、UVM severity、编译警告数、Python/驱动结果及 style
汇总验收通过：`/tmp/rdma_batch224_verification_summary.log`。送测后未修改生产源码或
测试输入，提交前再次核对下面 5 个 SHA256 与冻结值一致；只更新本批文档。

只读依赖与上一批一致：HOST_MEM_ROOT=`/home/ubuntu/workspace/host_mem.audit.current`、
DPU_COMMON_ROOT=`/home/ubuntu/deps_virtio/dpu_common`、
NET_PACKET_ROOT=`/home/ubuntu/net_packet_latest`、
PCIE_WORK_ROOT=`/home/ubuntu/workspace/pcie_work_audit.POaPmh`。
三项 E2E 各有 4 条基线编译警告：本项目 net adapter 的 2 条 FLWI 与外部 net_packet
IPv6 的 2 条 SV-ANDNMD，与上一批相同；UVM pristine 不代表编译零警告。

最终送测输入 SHA256：

```text
6575c3a750e93b69931fd04317584fe080d51661f113702567a63e3647586071  src/core/rdma_queue_data_engine.sv
cf6fe2d0ab89a03bba19bf4bdefc7277c0532ea373f443dd4b41b048dcb5334a  tests/rdma_unit_test_pkg.sv
d45b01c399cc68aa33aca33bd85d5b4b1458aa7fafdaa2c51488c243430ea31f  scripts/run_queue_lifecycle_regression53.sh
8aa36494d8cfc1f0afdb4258f2ec8f766c565d5f7d696ed3126de37a5ed9c511  tests/unit/rdma_queue_consumer_steps_test.sv
f90fd4091d75346111df8753a793fd54d7cd8cb3584e83832311b76de0ae0a8f  tests/unit/test_queue_consumer_steps_boundary.py
```

## 尚未关闭

本批只统一两个 consumer 机制步骤；producer/resize 的进一步编排收束、manager
publication 后更新、跨 owner 原子性、SRQ 完整业务组合、Phase-1C F2、legacy/external
ordering/error、包 DAG、其它 epoch 饱和策略与全项目可读性验收继续 OPEN。
