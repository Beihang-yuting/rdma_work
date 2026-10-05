<!-- 目录：项目根目录；职责：记录 Batch225 CQ resize 统一失败出口与验证证据。 -->

# Batch225：CQ resize 统一发布前回滚出口

日期：2026-09-28。基线 `aa2518f`，沿用 `feature/rdma-structural-batch222`。
本轮不合并、不推送，main 保持 `5f8dfe9`；项目级重构计划仍 active。

## 结构改动

`resize_cq()` 的 20 个发布前失败分支原本重复同一段 `abort_cq_resize()` 和
`finish_resize()`。现在使用函数内单次循环 `resize_transaction`（`do…while(0)`）：

- 发布前失败通过 `break` 退出当前调用的事务循环，统一执行原有回滚和锁释放；
  不新增函数、对象、旗标或 owner。
- manager replacement 成功后，attachment 和 recovery record 仍立即发布；后续
  dependent restore、旧 runtime detach、旧 backing release 失败均直接返回恢复错误。
- 成功路径也直接返回，绝不落入发布前回滚出口。原有入口拒绝和同尺寸 no-op 不变。

engine 从 9,977 行降到 9,934 行，生产净减 43 行；`resize_cq()` 方法本体从
371 行降到 324 行。全部 138 methods、27 个公开方法、类字段及锁/账本数量不变。
没有新生产文件；测试与文档增量不计入生产净减。

关键取舍是只统一控制流，不把候选准备拆成多份 owner，也不将原来在 factory、
clone、binding snapshot 后读取的字段提前保存到 helper 参数。cleanup 和 restore
仍使用失败发生后的 `old_attachment.runtime`、`candidate_ref` 和阶段位。

## 等价核对与复审

只读审计 `/tmp/rdma_batch225_audit.py` 固定基线 `aa2518f`，日志
`/tmp/rdma_batch225_audit_final.log`：

- 137/138 个方法全文 token 不变，全部 138 个声明及移除方法后的类壳 token 不变。
- 将公共尾段代回 20 个 `break`，移除单次循环边界后，`resize_cq()` 全文 token
  与基线一致，包含所有字符串、门禁、字段读取和调用顺序。
- `src` 与 `tests/unit` 的文件头/逐方法三段注释机械扫描：195 files、5,281 methods、
  0 diagnostics。该结果不是全项目人工语义/可读性最终验收。

上下文复审包括 resize 全流程、quiesce/restore/abort/retry、manager 的
begin/replace 原子提交契约、fixture setup/cleanup、全部新增测试及注册清单。
未变化方法核对完整 token 并沿用既有上下文证据；动态回归另行确认真实资源和恢复行为。
外部依赖、codec ABI、dpu_common authority 和外部组件生命周期不修改。

## 新增故障矩阵

`rdma_cq_resize_exit_test` 已注册到 core，包含 16 个场景、17 个独立完整 lifecycle fixture：

- runtime、backing access、plan、CQ candidate、recovery record、attachment 六个
  精确创建点各返回一次 null，分别搭配正常 rollback 与 candidate release 失败，共 12 项。
- 发布后的 dependent restore、旧 runtime detach、旧 backing release 各失败一次，共 3 项。
- 外层候选 factory 嵌套另一 engine 的 resize，内外候选都返回 null；验证内层失败
  返回后外层继续自己的回滚，两边分别保持旧 authority、唯一锁 token、无资源泄漏，
  并能分别再次扩容和完整 cleanup。

每项检查原错误或 RECOVERY_REQUIRED、故障实际命中、manager geometry/mapping、
pending recovery 与 live allocation 数量、锁恰好剩一个 token；随后 retry、确认
runtime ACTIVE、再次扩容成功并聚合 cleanup 至零 live allocation。
测试使用真实 manager/runtime 及 mock Host-memory，不代表真实 DUT 认证。

六项 Python 门禁覆盖唯一出口、20 个分支、发布后直接返回、阶段顺序、无新增续接协议、
原 rollback cleanup/restore 顺序及 core 注册，并明确禁止 resize 中使用 `disable`。

早期 focused 因测试误用 UVM 1.2 不提供的 `uvm_factory::set` 编译失败，已改为项目
既有 `uvm_coreservice_t::set_factory`，生产代码未因此修改。早期
`/tmp/rdma_batch225_focused.log` 保留，不计入最终通过。
Python 门禁初稿误把同尺寸 no-op 当作最后成功返回，已改用最后一次匹配；未改变生产代码。

首版使用命名块 `disable`，15-case focused 和首轮完整回归均通过，但额外 VCS53
语言探针揭示跨对象的嵌套自动函数调用会同时退出外层同名块，无法保持原 return 语义。
`/tmp/rdma_batch225_disable_probe.log` 记录了 Fatal，且进程仍返回 0；因此不能仅凭
退出码判断这个裸仿真探针成功。已改为当前调用内的单次循环 `break`，同一探针在
`/tmp/rdma_batch225_break_probe.log` 输出 `RESIZE_DISABLE_ACTIVATION_ISOLATION_PASS`，
无 Fatal，并将真实双 engine 嵌套窗口纳入第 16 个永久回归场景。
早期 `focused_final.log` 及不带 `_final` 的完整回归日志仅保留历史，不能验收最终源码。

## 验证状态

修订版完整验证通过，以下项目回归的 wrapper 均返回 0，全部 UVM summary 为 0/0/0。
最终计数、16-case 标记、警告数量及静态结果已汇总核对：
`/tmp/rdma_batch225_verification_summary.log`。送测后未再修改生产代码或测试输入。

| 验证 | 最终结果 | 日志（`/tmp/`） |
| --- | --- | --- |
| 16-case focused | 16 项、PROCESS/LOGICAL PASS、UVM pristine | `rdma_batch225_focused_isolation.log` |
| core 全量 | 99/99 PROCESS、82/82 LOGICAL、99 pristine | `rdma_batch225_core_final.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine | `rdma_batch225_cmq_final.log` |
| integration | 10/10 pristine | `rdma_batch225_integration_final.log` |
| E2E 双环境 / 多 VF / 高流量 | 三项各 1 pristine | `rdma_batch225_e2e_final.log` / `rdma_batch225_e2e_multivf_final.log` / `rdma_batch225_e2e_traffic_final.log` |
| Host-memory / PCIe adapter | 3/3、1/1 pristine | `rdma_batch225_host_mem_final.log` / `rdma_batch225_pcie_work_final.log` |
| 驱动归档 / C oracle / 字段归属 | 203 自测、definitions、oracle、字段归属均通过 | `rdma_batch225_driver_contract_final.log` |
| Python | 317/317 通过 | `rdma_batch225_python_final.log` |
| token / 注释结构审计 | 等价及 195 files / 5,281 methods / 0 diagnostics | `rdma_batch225_audit_final.log` |
| style / diff / lifecycle / profile / Phase-1A | 全部通过 | `rdma_batch225_style_final.log`（空）及终端记录 |

三项 E2E 各保留 4 条基线编译警告：本项目 net adapter 的 2 条 FLWI 和外部
net_packet IPv6 的 2 条 SV-ANDNMD，与上一批一致；其它上述 VCS 回归编译警告为 0。
UVM pristine 不代表编译零警告。

项目回归通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 中执行，
额外的裸 SV 语言探针也仅在该主机登录 bash 中编译运行。
只读外部依赖沿用 Batch224：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

最终完整回归送测输入 SHA256：

```text
93bdc994a72cd1637e2fa8ea3596cacafd3993a4bb3116397282b86fdbcb669b  src/core/rdma_queue_data_engine.sv
31125859d3d8d2961fa4b175f95a4120a50aae29774726497f01cb277fc7043b  tests/unit/rdma_cq_resize_exit_test.sv
faa33209cdcd4adfe845817e9b92f5db9ea8daeab5fd269657772dc78d4a4f65  tests/unit/test_cq_resize_exit_boundary.py
d9591a04057b532e8f16e4eec5d572d71526b9a28f7294ff24cd2786ac18f2c3  tests/rdma_unit_test_pkg.sv
eef2e6c237a893d4187d7886878bebb9294664f0d90eb66f51ee3329bd77fcf0  scripts/run_queue_lifecycle_regression53.sh
```

## 尚未关闭

本批只收束 CQ resize 的发布前回滚出口，不等于 Phase B 已验收。producer/resize
进一步业务编排、manager publication 后更新、跨 owner 原子性、SRQ 完整组合、
Phase-1C F2、legacy/external ordering/error、其它 epoch 饱和策略、包 DAG 与全项目
可读性验收仍 OPEN。
