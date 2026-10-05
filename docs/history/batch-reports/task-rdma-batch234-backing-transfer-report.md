# Batch234：backing 分段读写收束

日期：2026-09-29；基线：`f4933f0`；分支：`feature/rdma-structural-batch226`。
不合并、不推送；main 保持 `083e0d7`，外部依赖与已有缓存不改。

## 实现与边界

`rdma_queue_backing_access` 原来为 `write/write_device` 维护两套 payload 切片/写入
循环，为 `read/readback` 维护两套预检/拼接/失败清空循环。本批只合并这些机制：

- `write_spans` 接管已经完整预检的 spans，按原顺序切片和调用后端；两个公开
  write 入口仍分别执行原来的 resolve/preflight/null-status 检查。
- `read_with_permission` 负责完整预检与逐段读取；公开 `read/readback` 显式选择
  DMA 方向和原诊断文本。它们不是可随意互换的读 API。

| 入口 | DMA 权限 | 业务含义 |
| --- | --- | --- |
| write | DEVICE_READ | host 写入供设备读取的 posting 数据 |
| write_device | DEVICE_WRITE | 模拟设备向 CQ/CEQ/AEQ backing 发布数据 |
| read | DEVICE_WRITE | host 读取设备发布的数据 |
| readback | DEVICE_READ | host 确认刚写入的 posting 数据 |

完整预检必须在首个 I/O 前完成；但这不是后端事务回滚能力：中途写失败可以留下
已成功写入的前缀，后续 span 不再执行，恢复仍由业务 owner 决定。读取失败必须
清空输出，短读和超长返回继续使用原有 `returned short data` 诊断。
`backend_write_started` 仍在 device 入口先清零、首个后端调用前置位；后端失败
后不能清零。公共 helper 只增加调用局部标记，不新增实例字段、owner、锁或账本。
span 的 mapping/offset/length 仍在原访问位置读取，不提前缓存 adapter 回调后字段。

生产文件 619→603 行，净减 **16 行**；四个原方法合计 951 tokens，四个入口与
两个 helper 合计 725 tokens（减少约 24%）。access 类方法 22→24，原 22 个声明与
11 个公开声明不变；另一个 span 类不变。不宣称整个项目或总代码已经大规模收缩。

同步复审完整文件：重写文件头、两个构造函数和读写契约，纠正“内存访问推进
PI/CI/ledger”的旧说明；`clone_for_resize` 的旧 null factory/owner clone 注释
也改为真实限制，不顺带修改其历史行为。其余函数检查范围、命名、生命周期、
错误路径与格式；未改方法按固定基线 token 对照复用已有证据。

## 验证设计

扩展原有 `rdma_queue_backing_access_test`，不新增 UVM test/package/回归注册。
80-case 矩阵采用真实 configure/attach/resolve/preflight 与 mock backend：

- queue/QP 两类 backing，各覆盖 write/device-write/read/readback。
- 三个页级 segment 分别位于独立 16-KiB mapping 的非零偏移。从第一页最后 8 bytes
  访问 4,112 bytes，实际覆盖 8 + 4,096 + 8，验证每段 mapping、offset、length 和顺序。
- 只授予本入口所需方向，正常成功；最后一段权限拒绝；首/末 backend null；
  首/中/末原始错误；read/readback 中段短读、末段长读；未对齐与超 coverage。
- 失败必须命中指定后端序号，返回准确 code/message 或原始错误引用/硬件码；
  预检失败零 I/O，读取失败输出为空，device started 与进入后端事实一致。
- 逐字节检查成功写入前缀、未访问段和 guard bytes；测试自己的失败写不产生写入，
  不据此宣称所有真实后端失败都是原子的。每例释放三个 mapping，零 live allocation；
  access 自身不得释放 borrowed mapping。

六项 Python 门禁固定唯一循环、四入口权限、device started/null 策略、读失败清空、
无 owner/账本和完整矩阵注册。固定 `f4933f0` 审计展开两种读和两种写，保留字符串；
只消去普通 write 中不可见的局部 started 标记及移入 helper 的局部声明。
四入口展开 token 等价，18 个其它 access 方法、span 类与两个类壳不变；其它 198 个
src/tests-unit SV 文件字节不变。200 个 SV 文件 / 5,347 methods 中文三段契约扫描
零 diagnostics；这不替代整个项目的最终语义/并发验收。

## 验证状态

首次旧版基线因测试使用不满足页对齐的 16-byte 段而在 attach 处 fatal，日志保留
`/tmp/rdma_batch234_baseline.log`，不计为通过。夹具已改成合法页级分段，修订测试
在 detached `f4933f0` 临时工作树 `/tmp/rdma_batch234_baseline.3D9yf3/tree` 重跑，
不回退或覆盖当前重构工作树。该树只保留本次测试变化，便于复核旧实现证据。
初次静态检查的单行 return 也已修正，原日志保留。

修订后的旧实现基线与重构版专项均通过全部 80 cases，完整 VCS53 回归与静态门禁
全部通过。最终汇总脚本核对每组 wrapper 的真实退出码均为 0，并检查完整进程数、
逻辑测试数、UVM 报告、编译告警、矩阵标记及冻结输入，不以单条 PASS 代替套件完成。

| 验证项 | 结果 |
| --- | --- |
| 修订旧版基线 / 重构版专项 | 各 1 PROCESS / 1 LOGICAL，分别完成全部 80 cases |
| core | 103 PROCESS / 86 LOGICAL，103 份 pristine UVM 报告；80-case 新矩阵及九组既有矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine UVM 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全部 pristine |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全部 pristine |
| Python / 新边界门禁 | 365/365；其中新边界六项另行独立通过 |
| 驱动契约 | 203 tests、definitions、C oracle 及字段归属 1,088 项通过 |
| 静态与等价审计 | changed-SV style、lifecycle、profile、Phase-1A、diff 与 token/中文契约检查通过 |

最终通过的上述仿真套件 UVM WARNING/ERROR/FATAL 均为零。三项 E2E 各保留 4 条基线
编译告警：2 条 FLWI、2 条外部 net_packet SV-ANDNMD；不将 pristine UVM 等同于
编译零告警，也不修改外部依赖来消除这些告警。其它上述套件编译告警为零；首次
夹具失败的旧日志仍保留，不计入最终通过结果。

证据路径（均保留在本机 `/tmp`）：

- 基线与专项：`rdma_batch234_baseline_fixed.log`、`rdma_batch234_focused_final.log`。
- 完整回归：`rdma_batch234_core.log`、`rdma_batch234_cmq.log`、
  `rdma_batch234_integration.log`、`rdma_batch234_host_mem.log`、
  `rdma_batch234_pcie_work.log`、`rdma_batch234_driver_contract.log`。
- E2E：`rdma_batch234_e2e.log`、`rdma_batch234_e2e_multivf.log`、
  `rdma_batch234_e2e_traffic.log`。
- wrapper 退出码：`rdma_batch234_group_{core,cmq,external,e2e,baseline_fixed}.log`。
- Python/静态/等价：`rdma_batch234_python.log`、`rdma_batch234_boundary.log`、
  `rdma_batch234_style_final.log`、`rdma_batch234_lifecycle.log`、
  `rdma_batch234_profile.log`、`rdma_batch234_phase1a.log`、`rdma_batch234_audit.log`。
- 送测后注释审计：`rdma_batch234_comment_audit.log`。
- 最终汇总：`rdma_batch234_verification_summary.log`，全部检查 PASS。

所有 VCS 均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行。
首版送测 hashes 为 `/tmp/rdma_batch234_inputs.sha256`；之后仅修正测试 run_phase
的 fatal/objection 注释，未改可执行内容。注释审计核对临时基线中的同一测试 raw hash
与终版 tokens 相同，其它输入 raw hashes 不变；最终 hashes 单独记录在
`/tmp/rdma_batch234_final_inputs.sha256`。

依赖沿用既有锁定路径：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

## 仍开放

此批只关闭重复搬运循环，不关闭 provider 回调重入/跨 mapping 原子快照、跨 owner
原子性、完整 producer/resize 编排、SRQ 全生命周期、跨队列并发、external ordering/
error、Phase-1C F2、其它 epoch 饱和、包 DAG 或全项目可读性验收；计划仍 active。
