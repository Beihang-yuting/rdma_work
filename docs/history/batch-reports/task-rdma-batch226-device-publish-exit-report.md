<!-- 目录：项目根目录；职责：记录 Batch226 设备发布共同恢复出口及验证证据。 -->

# Batch226：设备发布写后恢复出口

日期：2026-09-28。基线 `083e0d7`，独立工作树 `.worktrees/rdma-structural-batch226`，
分支 `feature/rdma-structural-batch226`。不合并、不推送；main 和用户缓存保持不变。
项目级计划仍 active，本批仅收束一种事务的失败出口。

## 结构与边界

`write_commit_device_entry()` 是 CQ/CEQ/AEQ 已有的共同设备发布事务。本批将
backend write 失败、readback 失败、回读字节不一致、producer commit 失败的四份
状态复制/recovery 尾段统一为一份。单次 `do…while(0)` 中各失败点只确定原错误和
复制失败诊断，再 `break` 到共同出口；不新增生产文件、方法、类、账本或 owner。

保留以下业务差异：

- 写前 preparation/cancel 原样保留；write 返回错误且 backend 未开始时仍取消预留。
- write 返回 OK 但 backend 未开始时仍直接进入 recovery，只有原来的一次状态复制。
- readback 在首个差异处退出 foreach，再退出本次 I/O 阶段；不会比较余下字节或 commit。
- commit 成功时交付原 result 并直接返回，不落入恢复出口。
- 共同出口保留前置字段复制及 `enter_device_publish_recovery()` 中的第二次复制；
  两者之间仍有 status factory 回调，不提前缓存 pending.failure_status/runtime 成员。
- live 与 replay 的 authority、确认、commit gate、错误文本和 evidence 策略不同，
  本批不合并两条业务流程。

禁止使用命名块 `disable`；`break` 只影响当前调用的循环。
新增的局部字符串只选择原有诊断，并指示 foreach 的首错退出，不是共享事务状态。

engine 9,934→9,916 行，生产净减 18 行；发布方法本体 288→268 行。
138 methods、27 个公开方法及类字段完全不变。测试/文档增量不计为生产收缩。

## 复审与等价核对

只读审计 `/tmp/rdma_batch226_audit.py` 固定 `083e0d7`：

- 137/138 方法全文 token 不变，全部声明及移除方法后的类壳 token 不变。
- 展开四个失败出口、将写前 if/else 规范化为提前 return，并移除单次循环/foreach
  续接后，整个发布方法与基线 token 相同，包含诊断字符串与调用/字段读取顺序。
- `src` 与 `tests/unit` 的 196 个 `.sv` 文件、5,295 个方法进行文件头/逐方法中文
  三段契约扫描，0 diagnostics。该扫描不代表全项目人工语义/可读性最终验收。

上下文复审覆盖文件入口和 owner 字段、发布准备/取消/接管/未接管 evidence、
producer commit 与 replay、backing write/read、fixture setup/cleanup、全部新增测试
及注册文件。其余方法以完整 token 核对沿用基线证据，不宣称重新人工验收全部旧实现。
外部依赖、dpu_common authority、codec ABI 与外部组件生命周期均未改动。

## 新增验证

`rdma_device_publish_exit_test` 已注册 core，三种 queue kind 各十项，共 30 个独立
lifecycle fixture：成功、write 错误、read 错误、首尾两个字节同时不一致、真实 runtime
锁忙导致 commit 拒绝、写前权限拒绝、OK 但未写、已写后的 null、未写的 null，以及
runtime 接管失败后的 engine-owned unclaimed recovery。

四类共同出口在首次状态复制的真实 factory 窗口替换 destination；在 admission 之前
断言恰有两次复制，且完整诊断相同、第二次写入新对象。特殊未写成功只允许原来一次
复制。所有 case 检查 I/O 次数和顺序、result、occupancy、reservation、pending authority
与诊断；需要恢复的 case 执行公开 retry，所有 case 再次发布并 cleanup 至零 live allocation。

这里直接进入已 reserve 的公共事务，image 是机制测试数据；公开 CQE/CEQE/AEQE
编码、路由、backing 字节以及 WQE 释放继续由既有集成回归覆盖，不冒充真实 DUT 验证。
六项 Python 门禁守卫共同尾段、两个未写旁路、foreach 首错、提交顺序、复制/replay
分界与矩阵注册。

状态 factory 回调测试返回真实非空 status，只替换 detached destination；没有把
`rdma_status::make()` 的 null-factory 容错当作已覆盖项。该基础方法仍直接解引用
factory 返回值，本批保持基线行为；公共 status 创建边界的统一加固应独立评估。

首轮 focused 完成全部场景但有三条测试断言错误：接管失败时 evidence 位于 engine
unclaimed 表，`query_runtime_occupancy()` 的 pending 位仅表示 runtime 接管状态。
已将该断言与公开 `query_runtime_pending()` 的证据检查分开，未修改生产行为。
首轮另有测试 repeat 的 64-bit 计数截断警告，已改为显式 int 循环。
`/tmp/rdma_batch226_focused.log` 仅保留失败历史，不计最终验收。

## 验证状态

修订版 focused 与完整回归全部通过，所有 wrapper 返回 0，全部 UVM summary 为
0/0/0。计数、30-case 标记、警告数量与静态结果汇总核对见
`/tmp/rdma_batch226_verification_summary.log`；送测后未再修改生产、测试或构建输入。

| 验证 | 最终结果 | 日志（`/tmp/`） |
| --- | --- | --- |
| focused | 30 cases、PROCESS/LOGICAL PASS | `rdma_batch226_focused_final.log` |
| core | 100/100 PROCESS、83/83 LOGICAL、100 pristine | `rdma_batch226_core_final.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine | `rdma_batch226_cmq_final.log` |
| integration | 10/10 pristine | `rdma_batch226_integration_final.log` |
| E2E 双环境 / 多 VF / 高流量 | 三项各 1 pristine | `rdma_batch226_e2e_final.log` / `rdma_batch226_e2e_multivf_final.log` / `rdma_batch226_e2e_traffic_final.log` |
| Host-memory / PCIe | 3/3、1/1 pristine | `rdma_batch226_host_mem_final.log` / `rdma_batch226_pcie_work_final.log` |
| 驱动归档 / C oracle / 字段归属 | 203 自测、definitions、oracle、字段归属通过 | `rdma_batch226_driver_contract_final.log` |
| Python | 323/323 通过 | `rdma_batch226_python.log` |
| token / 注释结构审计 | 等价、196 files / 5,295 methods / 0 diagnostics | `rdma_batch226_audit.log` |
| style / diff / lifecycle / profile / Phase-1A | 全部通过 | `rdma_batch226_style_final.log`（空）及终端记录 |

三项 E2E 各有 4 条既有编译警告：本项目 net adapter 的 2 条 FLWI 与外部
net_packet 的 2 条 SV-ANDNMD；其余上述 VCS 回归编译警告为 0。
UVM pristine 不等于编译零警告。

VCS 均通过项目 wrapper 在 `ubuntu@10.11.10.53` 登录 bash 执行，依赖沿用：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

最终送测输入 SHA256（结束前再次核对一致）：

```text
a14011e7f19ca33eb780825eca16730fd63a7458d7b38022e2a09b3c418fc0b7  src/core/rdma_queue_data_engine.sv
151dde7ab9260ae677acd9903533db5b03a8f193578a39768f337e0dcf818365  tests/unit/rdma_device_publish_exit_test.sv
c96e1954f44bd3b43a78e082b4c9397dae81700b027bd1830440ecb2a72fff4e  tests/unit/test_device_publish_exit_boundary.py
af2bbbc32acc92d191f48bbcb90ab030bacb72043b7f521c1e597e952565935d  tests/rdma_unit_test_pkg.sv
2599a18504245d05b7fc00351c21337c177cae9bd74fb1ab46598ae1504baa3c  scripts/run_queue_lifecycle_regression53.sh
```

## 尚未关闭

producer preparation/取消与更完整的事务编排、manager publication 后更新、runtime
快照与提交分界、跨 owner 原子性、SRQ 完整生命周期、跨队列并发、legacy/external
ordering/error、Phase-1C F2、其它 epoch 饱和策略、包 DAG 与全项目可读性验收仍 OPEN。
SQD/SQE 仍明确 unsupported，属于能力边界，不由本次纯结构重构隐式补齐。
