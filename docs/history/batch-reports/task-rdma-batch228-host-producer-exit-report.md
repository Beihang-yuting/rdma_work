<!-- 目录：项目根目录；职责：记录 Batch228 host-producer 恢复出口重构与验证证据。 -->

# Batch228：统一 Host 提交尾段的恢复出口

日期：2026-09-28。基线 `508ba49`，沿用工作树 `.worktrees/rdma-structural-batch226`、
分支 `feature/rdma-structural-batch226`。不合并、不推送，main 保持 `083e0d7`；
已有缓存保留。项目级计划仍 active，本批不等于全部 producer 或项目重构完成。

## 结构与业务边界

`complete_host_producer_tail()` 中七处相同参数的 recovery installer 调用合并为一个
出口。单次 `do/while (0)` 保留原业务顺序：gate → WQE write/readback → result/handle
准备 → next cursor → doorbell → ledger commit → result 交付。失败分支只选择原诊断
标签和 MMIO 阶段；两个新增变量均为调用局部值，没有新增类、方法、owner 或实例状态。

| 失败位置 | 是否进入公共出口 | MMIO evidence / 原标签 |
| --- | --- | --- |
| gate，无先前 Host write | 否，直接返回 | 不构造 pending |
| gate，已实际写 SQ SGB | 是 | NO_SUBMIT / write_failure_label |
| WQE write/readback | 是 | NO_SUBMIT / write_failure_label |
| result factory/cast、result handle clone | 是 | NO_SUBMIT / result_name |
| next cursor | 是 | NO_SUBMIT / next_name |
| doorbell | 是 | AMBIGUOUS / doorbell_failure_label |
| ledger commit | 是 | AMBIGUOUS / commit_failure_label |
| 已提交 result-status 异常或正常成功 | 否，直接返回 | 不重新安装未提交 evidence |

Installer、admission、replay 与所有公开入口均不修改。Admission 非空拒绝仍原样透传，
null 才归一化为 RECOVERY_REQUIRED；同步纠正了原方法注释中的旧描述。AMBIGUOUS
即使调用者确认也不能 retry，只能显式 abort/detach。未接管 pending 不代表已有写入
被回滚，也不声称增加了 host unclaimed recovery 能力。不使用命名块 `disable`。

engine 9,931→9,929 行，生产净减 **2 行**；方法本体 152→147 行，词法 token
828→679。主要收益是七处长参数恢复调用变为一处，不能将其描述为大规模代码收缩。
139 methods、27 个公开方法及其声明全部不变。

## 复审与等价核对

只读审计 `/tmp/rdma_batch228_audit.py` 固定 `508ba49`，核对：

- 其余 138/139 方法全文 token、全部声明与类壳/owner/state 不变。
- 展开七个失败续接并规范化 prior-write 入口 guard 后，整个修改方法与基线 token
  一致；字符串保留，五类 NO_SUBMIT 与两类 AMBIGUOUS 的 bit/label 对应逐项检查。
- `src` 与 `tests/unit` 的 198 个 `.sv` 文件、5,316 methods 文件头和逐方法中文三段
  契约扫描无 diagnostics。词法扫描不替代全项目人工语义/可读性最终验收。

上下文复审涵盖 engine 文件入口及 owner、reserve/gate、SGB authority、installer/
admission、tail、replay/recover，fixture setup/cleanup 与 shared-SRQ 逆序销毁，新增
测试全文和注册上下文。其余旧方法以完整 token 对照沿用基线证据；不宣称逐行重新
人工验收所有旧实现。dpu_common authority、外部依赖、codec ABI 和外部生命周期不变。

## 新增验证

`rdma_host_producer_exit_test` 已注册 core，共 **53 cases**：

- SQ/RQ/SRQ × 14 模式：正常、gate 错误/null、WQE write/read 失败、result 空/错型、
  handle clone 空、next 空/错型/nonfatal status 空、doorbell、commit 错误/null。
- 两个真实三 SGE 外置 SQ SGB write/readback 后的 gate 拒绝。
- 七类恢复出口各叠加 pending factory null，检查原 failure label 和单次创建。
- Admission null / RESOURCE_BUSY，检查原返回语义及没有伪造 runtime pending。

每例使用独立 lifecycle fixture，检查故障实际命中、I/O 次数/顺序、result/status、
PI/CI/credit、单次 pending/admission、冻结 route/reset epoch 与恢复阶段。NO_SUBMIT
经公开确认 retry 提交一个槽位；AMBIGUOUS 分别检查未确认和确认后的拒绝且零额外
I/O，然后公开 abort/detach。SRQ 使用真实 shared queue，按 QP→SRQ→fixture 清理，
所有 case 最后检查零 live allocations。未接管 evidence 只验证拒绝和可清理性。

六项 Python 门禁守卫单一出口、prior-write gate、诊断/MMIO 阶段、已提交旁路、业务
顺序/replay 独立和真实矩阵注册。它们不能代替动态验证。状态工厂 null 不属于本批
加固范围，不向仍直接解引用结果的 `rdma_status::make()` 注入 null。

测试开发期间有两轮失败，均修正测试而未改变生产语义：先前把 confirmed AMBIGUOUS
误当作可重试；随后 SGB fixture 只填写地址但保留单 SGE，未进入外置模式。修订为
两种确认状态均拒绝，以及三 SGE 的真实 512-byte SGB 写入并检查数据长度。
`rdma_batch228_focused_initial.log`、`rdma_batch228_focused_final.log` 和修订前已启动
的套件不计最终验收（包括同一旧 SGB fixture 失败的 `rdma_batch228_core_final.log`）；
下节只记录修订后完成的验证。

## 验证状态

修订后 focused 与完整回归全部通过，全部 wrapper 返回 0，UVM WARNING/ERROR/FATAL
均为 0。`/tmp/rdma_batch228_verify_logs.sh` 统一核对计数、53/126/30-case 标记、
编译告警、Python/驱动与退出码；结果为 `/tmp/rdma_batch228_verification_summary.log`。

| 验证 | 结果 | 日志（`/tmp/`） |
| --- | --- | --- |
| focused | 53 cases、PROCESS/LOGICAL PASS，1 pristine | `rdma_batch228_focused_corrected.log` |
| core | 102/102 PROCESS、85/85 LOGICAL、102 pristine，含新旧 53/126/30-case 矩阵 | `rdma_batch228_core_release.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine | `rdma_batch228_cmq_release.log` |
| integration | 10/10 pristine | `rdma_batch228_integration_release.log` |
| E2E 双环境 / 多 VF / 高流量 | 三项各 1 pristine | `rdma_batch228_e2e_release.log` / `rdma_batch228_e2e_multivf_release.log` / `rdma_batch228_e2e_traffic_release.log` |
| Host-memory / PCIe | 3/3、1/1 pristine | `rdma_batch228_host_mem_release.log` / `rdma_batch228_pcie_work_release.log` |
| 驱动归档 / C oracle / 字段归属 | 203 自测、definitions、oracle、字段归属通过 | `rdma_batch228_driver_contract_release.log` |
| Python | 335/335 通过 | `rdma_batch228_python.log` |
| token / 注释结构审计 | 等价、198 files / 5,316 methods / 0 diagnostics | `rdma_batch228_audit.log` |
| style / diff / lifecycle / profile / Phase-1A | 通过 | `rdma_batch228_style_final.log`（空）及终端记录 |

三项 E2E 各有 4 条既有编译告警：2 条本项目 net adapter FLWI、2 条外部 net_packet
SV-ANDNMD；其它 VCS 套件无编译告警，UVM WARNING/ERROR/FATAL 均为 0。
VCS 仿真统一通过项目 wrapper 在 `ubuntu@10.11.10.53` 登录 bash 执行，依赖未改：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

修订后 focused 和所有 `*_release.log` 使用相同的生产/测试/构建输入；之后只更新
文档。提交前用 `/tmp/rdma_batch228_inputs.sha256` 再次核对一致：

```text
724184e44a2c6ac738bb1cd290d05817876856b92801ee6f79f2ba9f989dd00a  src/core/rdma_queue_data_engine.sv
0af9e10b50990327bc117399bbb4dfc681a24c8b6d3618ca4c82c04c67cc3315  tests/unit/rdma_host_producer_exit_test.sv
6ddc00c7b080aeb4a1ae57a860d0e5a89d7aaae19b473a3227847762a8d371cc  tests/unit/test_host_producer_exit_boundary.py
0a6ad94909accac293d33a514c6309fd0b0dbe2f5fe1592e657be740ba83d969  tests/rdma_unit_test_pkg.sv
f0649c139db7bbbc3cdfcd4ddd6cd3406a3a813ea6a21090a7f467a10f003d7d  scripts/run_queue_lifecycle_regression53.sh
```

## 尚未关闭

更完整的 producer/resize 业务编排、manager publication 后更新、runtime 快照/提交
分界、跨 owner 原子性、SRQ 完整生命周期、跨队列并发、legacy/external ordering/
error、Phase-1C F2、其它 epoch 饱和策略、包 DAG 与全项目可读性验收仍 OPEN。
SQD/SQE 仍明确 unsupported。下一批应从这些业务边界选择可验证的职责收缩，
不为减少单个方法行数增加无业务意义的 wrapper 或第二账本。
