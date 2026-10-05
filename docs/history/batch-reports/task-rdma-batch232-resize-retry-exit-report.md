# Batch232：CQ resize 重试失败出口收束

日期：2026-09-29。基线：`8e7145d`。继续在
`feature/rdma-structural-batch226` 实现，不合并、不推送；保留 main 与已有缓存。

## 选择与边界

正常 resize 与 retry 都有依赖恢复、旧 runtime detach、旧 backing release，
但错误包装、last_status 内容、幂等跳步及 authority admission 并不相同。
本批不把它们合成带大量策略参数的通用清理框架，只收束
`retry_cq_resize_cleanup` 内 17 份相同的失败续接：保存 `recovery.last_status`，
归还 `resize_lock`，返回原位置已物化的 status。

无记录、未配置、非法 handle 和锁忙继续在入口直接返回。发布前和发布后成功路径
仍各自删除记录、归还锁，然后才调用 `rdma_status::success`；不改为
`finish_resize(rdma_status::success())`，避免把成功 factory 回调移进锁内。
所有 authority 检查、status 分配及错误文本、进度 flag 和 backing 清理时机不变。
不增加方法、实例字段、owner、第二账本或新的 package 依赖。

实现采用函数内单次循环：只让已有记录的失败分支 break 到共同出口，不使用
跨自动调用有歧义的命名块 disable。生产文件 9,929→9,910 行，净减 **19 行**；
retry 方法 243→221 行、代码 token 1,437→1,227。139 个方法声明、27 个公开声明
和类壳不变。本批是重复续接收缩，不把它描述为完整 resize 事务层已经重构完成。

同步纠正 `has_pending_cq_resize` 和 retry 的旧注释：记录可以属于发布前或发布后；
入口拒绝不全是 RECOVERY_REQUIRED，成功也不覆盖历史 last_status。只修正说明，
没有借机改动这些业务行为。

## 验证设计

扩展既有 `rdma_cq_resize_exit_test`，不增加 UVM test 或构建注册项：

- 17 个记录内失败出口各有一个场景；另验证旧 CQ restore/detach 与两阶段 dependent
  restore 的四个 null-status 场景。每个 fixture 都先通过真实 resize 失败建立记录。
- 核对准确 code/message、返回 status 与 last_status 的同一引用、恢复记录未丢失、
  恰好一个锁 token、Host-memory 调用数和 live allocation。保留已完成的恢复进度，
  修复测试注入后完成 retry，再次调用必须以无记录拒绝，最终 fixture 零泄漏。
- status factory 回调中同 engine 重入返回 RESOURCE_BUSY；另一 engine 的失败 retry
  不能退出外层调用，也不能提前覆盖外层诊断。两套资源最终独立恢复和清理。
- 既有 16-case resize 回滚/发布后清理与跨 engine 嵌套测试继续运行。

新增五项 Python 门禁守卫唯一失败出口、入口拒绝、解锁后成功分配、阶段/进度顺序
与完整动态矩阵。固定基线 token 审计要求 17 个 break 展开后原方法等价，其余方法、
声明和类壳不变；全目录中文契约扫描只作为词法门禁，不冒充完整人工语义验收。

22-case 矩阵逐一命中 17 个失败出口，不等于穷举每个复合条件或所有外部实现。
cleanup helper 的 null/成功但 incomplete 等防御性分支和 manager null 返回仍通过
保留原 token 与已有契约门禁核对，不宣称本矩阵已动态覆盖。

复审覆盖 engine 文件入口/所有权声明、完整 retry 及其引用的 recovery 捕获、身份/
backing 校验、正常 resize、rollback、依赖恢复与锁收尾，以及整个 resize exit test。
`/tmp/rdma_batch232_audit.py` 固定对照 `8e7145d`：17 个续接展开后 token 等价，
其余 138 个方法正文不变，139 声明、类壳、model/package/回归清单不变。
src/tests-unit 全部 200 个 SV 文件、5,337 methods 的文件头/逐方法中文三段契约
扫描零 diagnostics。未改业务正文按全量 token 对照复用基线证据，不称为项目最终验收。

## 验证结果

重构前 VCS53 基线已通过新增 22-case retry 与既有 16-case resize 矩阵，
UVM WARNING/ERROR/FATAL 均为 0，wrapper 返回 0。首次编译暴露测试读取 protected
runtime kind，已改为公开 query_attachment_config；首次失败日志保留为
`/tmp/rdma_batch232_baseline.log`，修订后通过日志为
`/tmp/rdma_batch232_baseline_fixed.log`，不把失败运行计作通过。

Python 结构门禁在重构前准确报告三项失败（重复出口/解锁次数），重构后
11/11 通过；日志为 `/tmp/rdma_batch232_boundary_red.log` 与
`/tmp/rdma_batch232_boundary_green.log`。

最终源码已冻结为 `/tmp/rdma_batch232_inputs.sha256`；全部 VCS 通过项目 wrapper
在 `ubuntu@10.11.10.53` 登录 bash 运行，送测后只修改文档。
终版专项及完整回归均通过，全部 wrapper 返回 0。
`/tmp/rdma_batch232_verify_logs.sh` 已统一核对进程/逻辑计数、基线与终版/core 的
22/16 新旧矩阵、既有 162/24/148/53/126/30 矩阵、告警、Python/驱动、wrapper
退出码和输入 hashes；最终证据为 `/tmp/rdma_batch232_verification_summary.log`。

| 验证 | 结果 | 日志（`/tmp/`） |
| --- | --- | --- |
| 重构前行为基线 | 22-case retry、16-case resize，1 PROCESS / 1 LOGICAL | `rdma_batch232_baseline_fixed.log` |
| 终版 resize 专项 | 同一 22/16 矩阵，1 PROCESS / 1 LOGICAL | `rdma_batch232_focused_final.log` |
| core | 103/103 PROCESS、86/86 LOGICAL、103 pristine | `rdma_batch232_core.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine | `rdma_batch232_cmq.log` |
| integration | 10/10 pristine | `rdma_batch232_integration.log` |
| Host-memory / PCIe | 3/3、1/1 pristine | `rdma_batch232_host_mem.log` / `rdma_batch232_pcie_work.log` |
| E2E 双环境 / 多 VF / 高流量 | 各 1 pristine | `rdma_batch232_e2e.log` / `rdma_batch232_e2e_multivf.log` / `rdma_batch232_e2e_traffic.log` |
| 驱动归档 / oracle / 字段归属 | 203 自测、definitions、C oracle、1,088 项字段归属检查通过 | `rdma_batch232_driver_contract.log` |
| Python | 354/354 通过 | `rdma_batch232_python.log` |
| token / 注释门禁 | 17 续接展开等价、138 其它正文不变，200 files / 5,337 methods / 0 diagnostics | `rdma_batch232_audit.log` |
| style / diff / lifecycle / profile / Phase-1A | 通过 | `rdma_batch232_style.log`（空）及终端记录 |

三项 E2E 各有 4 条基线编译告警（2 FLWI、2 外部 SV-ANDNMD），无新增告警；
其它套件编译告警为 0，全部套件 UVM WARNING/ERROR/FATAL 均为 0。
外部依赖未修改，使用既有固定路径及构建入口的依赖锁校验：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

## 尚未关闭

本批不关闭完整 producer/resize 业务编排、跨 owner 原子性、跨队列并发、完整 SRQ
生命周期、legacy/external ordering/error、Phase-1C F2、其它 epoch 饱和、包 DAG
或全项目可读性最终验收。SQD/SQE 仍 unsupported，外部依赖不改，计划仍 active。
