# Batch247：CEQ/AEQ 事件轮询准备阶段

日期：2026-09-30；基线：`85f67bd`；分支：`feature/rdma-structural-batch226`。
不合并、不推送，main 保持 `083e0d7`；保留既有缓存，不修改外部依赖。

## 改动与业务边界

将 `poll_ceqe_once` 与 `poll_aeqe_once` 重复的读取/解码前置收为同类 protected
task `prepare_event_poll_entry`。共享阶段只做 attachment lookup、peek consumer、
backing read、entry image 封装和 `decode_event_image`；不拥有 route、result、doorbell、
consumer commit 或 recovery。

AEQ 的 route/epoch 检查以 `check_route_epoch` 策略参数保留在共享准备阶段，CEQ 传
`1'b0`、AEQ 传 `1'b1`。next cursor 特意留在各 caller 的 route resolver 之后：原有
factory allocation 和首错顺序要求 route lookup/resolve 先于 cursor snapshot；这项
约束由已有 event fault fixture 捕获。CEQE/AEQE 类型化 cast、owner polarity、route
解析、结果物化、doorbell/CI commit、recovery 和 CQ flush partial 规则均留在 caller。

入口方法行数：`poll_ceqe_once` **50→40**，`poll_aeqe_once` **68→52**；engine 文件
含中文说明 **9,883→9,911 行**、代码/字符串 tokens **47,413→47,441**，方法
**140→141**。生产净增 28 行，是共享准备阶段的可读性整理，不称为总代码收缩。
没有新增 owner、锁、账本、公开 API 或外部依赖。

## 专项与顺序复审

复用既有 `rdma_queue_event_route_consume_test` 的公开 CEQ/AEQ poll 入口和
**44-case event prepare** 矩阵；未新增 SV fixture、未直接调用新 protected task，
现有 package/manifest 不增加注册。矩阵覆盖 result/model/final-status、prepared
pending、doorbell descriptor/noalloc status、route miss、factory null/错型和
next-cursor final allocation；重构前后均 UVM warning/error/fatal **0/0/0**。

新增 `test_event_poll_prepare_boundary.py` 三项门禁，并更新既有
`test_queue_consumer_steps_boundary.py` 以固定新的共享 seam：

- preparation 在 route/next/consume 前且只调用一次；共享阶段不访问 route/commit；
- AEQ route/epoch gate 是显式策略，next cursor 仍在 route resolver 后；
- 既有 44-case 测试只调用公开 `poll_ceqe`/`poll_aeqe`。

四项内存破坏注入（公开化 preparation、共享阶段 route、共享阶段提前 next cursor、
移除 AEQ gate）全部被 Python 门禁拒绝。第一次 refactored 专项故意暴露了 next
cursor 提前导致的 4 个 status-object identity 错误；恢复 route→next 顺序后最终
专项通过，失败日志保留为 `/tmp/rdma_batch246_refactored_event.log`，不计入最终结果。

固定 `85f67bd` 的结构审计：新增长期方法仅一个 protected preparation task；
已有方法声明和 class shell token 保持，211 个其它 tracked SV 文件字节不变。
目录契约扫描 **212 SV / 5,470 methods / 零诊断**。这不是全目录并发、外部
ordering/error/backpressure 或最终 ownership 审计的替代。

## 验证结果

全部最终选定 suite 的 wrapper 真实退出码均为 0。

| 验证项 | 最终结果 |
| --- | --- |
| 旧生产 event 专项 / 重构版 event 专项 | 各 44 event prepare cases，UVM 0/0/0 |
| core | 115 PROCESS / 98 LOGICAL，115 份 pristine |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过；每组保留 4 条既有编译告警 |
| Python | 424/424，包含本批 seam 和既有目录门禁 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属全通过 |
| 静态复审 | changed-SV style、lifecycle/profile/Phase-1A、审计、diff 全通过 |

所有仿真的 UVM WARNING/ERROR/FATAL 为零；E2E 的 4 条告警为既有 2 FLWI 与
2 条外部 net_packet SV-ANDNMD，其它 suite 无编译告警。Core/CMQ 计数保持既有
矩阵规模，本批没有新增 regression test，仅重用既有 event 专项。

完整日志前缀为 `/tmp/rdma_batch246_`（wrapper 脚本沿用 Batch246 前缀），本批
专项/审计日志为 `/tmp/rdma_batch247_*`；所有 VCS 均经 `scripts/run_vcs53.sh`
在 `ubuntu@10.11.10.53` 登录 bash 执行，固定外部 roots 只读消费。

## 尚未关闭

queue-data/resource/lifecycle 整体编排、CMQ submit/recovery/reset 与 protected
兼容层、跨组件并发、SRQ 完整组合、SQD/SQE drain/flush、外部
ordering/error/backpressure、Phase-1C F2 whole-plan 和最终 ownership 审计仍开放。
两个重构计划保持 `active`；本批不增加薄 facade，不把两个 caller 变短解释为整体
架构重构完成。
