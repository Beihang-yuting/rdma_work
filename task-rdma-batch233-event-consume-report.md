# Batch233：CEQ / AEQ 路由后的消费事务收束

日期：2026-09-29。基线：`e1b8ed5`；沿用 `feature/rdma-structural-batch226`。
不合并、不推送，不改外部依赖，保留 main 与已有缓存。

## 业务边界与实现

CEQ 按 CQN 找 CQ；AEQ 按事件类别解析 QP/SRQ/CQ/EQ/Function，CQ flush 允许
CQ/QP 双命中或部分命中。两者的业务路由不能合成同一套猜测规则。
因此保留两个 `poll_*_once` 的 attachment/read/decode/owner/route/next 阶段，
只把路由后的结果物化与 continuation 准备收进原提交入口，改名为
`consume_routed_event`。不新增生产类、对象层、状态字段、锁、owner 或转发壳。

共同事务：命中时物化 event status/result，未命中时预建最终 OK，再准备
pending/doorbell/noalloc status；之后保持原有 admission → doorbell → MMIO
evidence → CI commit → recovery completion → result 顺序。runtime 仍是唯一
可变账本 owner。AEQ 的 attachment route/reset epoch gate 仍位于 peek/read 前，
CEQ 不添加额外 gate；CQ flush 的两路 OR 判定仍留在 AEQ caller。

CEQ 直接使用既有 `_ex` projector 并传 secondary=null，与原单 owner wrapper
展开等价；wrapper 本身保留供其它调用者使用，projector 无改动。
ecode 仍在 error codec factory 前读取；其后的 model 字段仍由原 projector 在
原 factory 回调窗口内读取，不提前快照可变字段。

特别保留既有失败语义：route miss 的最终 OK raw 分配返回 null/错型时，不 ack、
result=null，但返回先前 next cursor 的 OK status。共同 task 用 `inout status`
保留该引用，不在准备前清零；这不代表本批认可或修复这个历史返回策略。
error codec 仍沿用 typed factory，要求非空 codec，无 null fallback；本批只把
旧注释纠正为实际约束，不伪称已验证 codec 工厂的所有失败。

生产文件 9,910→9,864 行，净减 **46 行**；CEQ 单次入口 93→50 行，AEQ 单次
入口 109→68 行；两个入口加共同事务的代码 token 1,544→1,345。
方法数仍为 139，27 个公开声明不变；一个 protected task 改名/改签名，不能称
全部声明原封不动。其余 138 个保留声明、136 个其它方法正文与类壳不变。

## 验证设计与复审

扩展既有 `rdma_queue_event_route_consume_test`，不增加 UVM test/package/回归注册。
44-case 矩阵包括每种队列 13 个 route-hit 与 9 个 route-miss 场景：

- hit：正常消费；result、event model、final success、pending、doorbell descriptor、
  noalloc slot 的 null/错型各一例。
- miss：正常消费；pending、descriptor、noalloc slot、最终 OK 的 null/错型各一例。
- 每次故障核对注入确实命中、准确 code/message、result=null、PI/CI/wrap/used/
  pending/MMIO 不变；miss 最终状态故障还核对 status 为此前 cursor 状态的同一引用。
- 解除注入后正常 poll 恰好消费一次，核对 CI/wrap/occupancy/MMIO，命中交付完整
  detached 值，miss 丢弃 payload；再 poll 必须 QUEUE_EMPTY 且不重复 ack。

既有 malformed 修复重试与 NO_SUBMIT 显式恢复继续运行；完整 core 继续运行
AEQE CQ flush 双路/partial/miss、route/reset epoch 与 detached snapshot 等测试。
新增五项 Python 门禁守卫委托边界、两类路由规则、准备/提交顺序与无分配尾段、
miss 状态继承和 44-case 完整回归注册；原 consumer steps 门禁不削弱。

固定基线审计 `/tmp/rdma_batch233_audit.py` 将共同准备段按两种 caller 的实参
展开，并展开 CEQ 单 owner wrapper、折叠纯 literal 诊断拼接后逐 token 比较；
原 admission/commit 尾段完整 token 相同，未改方法、类壳、projector/model/package/
manifest 同样核对，其它 198 个 src/tests-unit SV 文件与基线字节相同。
全 src/tests-unit 的 200 个 SV 文件、5,340 个方法完成文件头/
逐方法中文三段契约扫描，零 diagnostics；词法扫描不是全项目语义最终验收。

复审覆盖 engine 文件定位/所有权、两个 poll/timeout/decode/route 边界、event
result projector、pending/doorbell 准备、公共 consumer 步骤与原提交尾段，以及
整个 event route consume test。纠正三个旧测试 helper 的 role/错误说明：它们按
传入 role 查找 mapping，由 caller 保证只用于 CEQ/AEQ，不虚构额外 role 白名单。
不修改无关格式，不把测试代码增长计作生产代码收缩。

## 验证结果

重构前 `e1b8ed5` 生产代码已通过新增 44-case 矩阵和既有 event route 场景，
1 PROCESS / 1 LOGICAL，UVM 0/0/0，wrapper=0。首次基线的 case 无 default，之后
补了空 default 以通过静态规范；有效场景行为不变，没有隐藏失败的仿真运行。
Python 359/359、consumer boundary 11/11、token/注释扫描与静态门禁已通过。

所有 VCS 均通过项目 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash
执行。重构前基线、两次重构后专项及完整回归全部通过，所有 wrapper 返回 0。
`/tmp/rdma_batch233_verify_logs.sh` 已统一核对进程/逻辑数量、44-case 矩阵、既有
状态/设备发布/host-producer/resize 矩阵、告警、Python/驱动、wrapper 退出码、
静态检查和最终输入 hashes；汇总证据为 `/tmp/rdma_batch233_verification_summary.log`。

| 验证 | 结果 | 日志（`/tmp/`） |
| --- | --- | --- |
| 重构前行为基线 | 44-case 矩阵，1 PROCESS / 1 LOGICAL | `rdma_batch233_baseline.log` |
| 重构后专项 / 最终注释版专项 | 各 44-case、1 PROCESS / 1 LOGICAL | `rdma_batch233_focused_final.log` / `rdma_batch233_focused_comments.log` |
| core | 103/103 PROCESS、86/86 LOGICAL、103 pristine | `rdma_batch233_core.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine | `rdma_batch233_cmq.log` |
| integration | 10/10 pristine | `rdma_batch233_integration.log` |
| Host-memory / PCIe | 3/3、1/1 pristine | `rdma_batch233_host_mem.log` / `rdma_batch233_pcie_work.log` |
| E2E 双环境 / 多 VF / 高流量 | 各 1 pristine | `rdma_batch233_e2e.log` / `rdma_batch233_e2e_multivf.log` / `rdma_batch233_e2e_traffic.log` |
| 驱动归档 / oracle / 字段归属 | 203 自测、definitions、C oracle、1,088 项字段归属检查通过 | `rdma_batch233_driver_contract.log` |
| Python / consumer boundary | 359/359（两轮）、11/11 | `rdma_batch233_python.log` / `rdma_batch233_python_final.log` / `rdma_batch233_boundary.log` |
| 等价 / 注释契约 | 200 files / 5,340 methods / 0 diagnostics | `rdma_batch233_audit.log` |
| style / diff / lifecycle / profile / Phase-1A | 通过 | `rdma_batch233_style_final.log`（空）及同批静态日志 |

三项 E2E 各保留 4 条基线编译告警（2 FLWI、2 外部 SV-ANDNMD）；其它套件编译
告警为 0，全部套件 UVM WARNING/ERROR/FATAL 均为 0，无新增告警。

送测首版输入见 `/tmp/rdma_batch233_inputs.sha256`；启动完整回归后只纠正上述
注释，没有修改 executable token。审计脚本从仍在运行的远端隔离目录读取快照，
同时验证首版 raw hashes 与当前 token 一致，证据为
`/tmp/rdma_batch233_sent_token_audit.log`；当前文件 raw hashes 单独冻结在
`/tmp/rdma_batch233_final_inputs.sha256`，不把两份 raw 输入说成字节相同。

固定依赖仍为：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

## 尚未关闭

本批只收束 event 路由后的重复业务编排，不关闭完整 producer/resize 事务层、
跨 owner 原子性、跨队列并发、完整 SRQ 生命周期、legacy/external ordering/error、
Phase-1C F2、其它 epoch 饱和、包 DAG 与全项目可读性最终验收。SQD/SQE 仍
unsupported，两个重构计划仍 active。
