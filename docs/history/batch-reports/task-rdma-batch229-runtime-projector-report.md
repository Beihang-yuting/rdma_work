<!-- 目录：项目根目录；职责：记录 Batch229 runtime 值快照与 mutable owner 分离及验收证据。 -->

# Batch229：runtime 值快照与账本 owner 分离

日期：2026-09-28。基线 `cf502a5`；沿用工作树 `.worktrees/rdma-structural-batch226`、
分支 `feature/rdma-structural-batch226`。不合并、不推送，main 保持 `083e0d7`；原有
缓存保留。项目计划仍 active，不把本批职责迁移等同于完整 runtime 或全项目验收。

## 结构变化

新增集中式 `rdma_queue_runtime_projector.sv`，迁入 20 个受保护值方法：

- raw factory、带直接构造 fallback 的 runtime status、无分配 status 初始化和成功判断；
- handle/cursor/image/status/address-vector/request/slot/pending 的深复制；
- 完整 handle identity、冻结 identity scalar、route/epoch、image/status/AV/request
  和 pending immutable evidence 比较。

全部为 `static function automatic`；新类没有字段、锁、缓存、继承、UVM 注册或实例。
runtime 只增加 `value_ops` 类型别名，不创建 provider。公开 `cursor_equal()` 保留原
签名，委托值层的一份比较实现；这是已有公开 API 的兼容入口，不为其余 20 个方法
保留转发壳。状态工厂名 `runtime_status`、失败文案与调用顺序全部不变。

| 范围 | 基线 | 本批 | 变化 |
| --- | ---: | ---: | ---: |
| runtime | 4,646 行 / 94 methods | 3,814 行 / 74 methods | −832 行 / −20 methods |
| projector | 无 | 884 行 / 21 methods | 一份集中式无状态值组件 |
| 两文件合计 | 4,646 行 | 4,698 行 | +52 行 |

package 另增 1 行 include，models 只更新 helper 所在层次的注释。新增中文边界说明、
单行 if-return 展开和兼容入口使生产总代码净增 53 行；这是 owner 文件职责与阅读
范围收缩，不宣称总代码量下降。没有新增事务层级或第二账本。

## 保持的业务边界

runtime 仍独占唯一 lock、queue identity/route/epoch、PI/CI/used、slots、device
reservation、pending、retry confirmation 和 release/commit gates。Admission、
cursor geometry、consumer shadow/MMIO policy、状态迁移和锁窗口都留在原方法。
全部 58 个公开方法声明不变；`cursor_equal` 不校验 depth 的既有语义保留。

值层“无状态”不代表“无回调/无分配/跨 owner 原子快照”。深复制继续在原位置调用
raw factory；若输入来自 live ledger，原 caller 必须保持原锁/admission 约束。状态
分配空/错型继续直接 new fallback，不能与 queue-data projector 的返回 null 策略
混用。`set_runtime_status_noalloc` 仍只写调用者 slot，不分配也不调用虚拟复制。

同时复审并纠正迁出方法的旧注释，未改变实现：

- 不支持的 semantic request subclass 返回 INVALID_ARGUMENT，不是 RESOURCE_EXHAUSTED。
- device-producer pending 缺 queue/cursor/next/image 时拒绝；nested clone 原错误透传。
- pending immutable 比较要求 cursor/next 非空，但其它 nullable 对象两侧均空可相等；
  MMIO/完成阶段位由 owner 的单调合并规则处理，不能凭该比较单独授权恢复。
- image 队列逐项复制，不把仿真器自身内存耗尽描述为可捕获的 status。
- request.owner 为 null 时原实现保留 factory candidate 的既有 owner；不暗中增加
  清空、alias 防御或预填对象规范化。本批不扩展 hostile factory 能力。

## 复审与等价证据

`/tmp/rdma_batch229_audit.py` 固定对照 `cf502a5`：94/94 原方法 token（保留字符串）
等价，只允许显式类型限定与 protected→static automatic；公开 cursor wrapper 单独
展开对照。全部 58 公开声明不变；runtime 类壳仅多类型别名，原 state/owner 全部
不变。Models 代码 token 不变，package 只有一个按依赖顺序加入的 include。

`src` 与 `tests/unit` 全部 200 个 `.sv` 文件、5,326 methods 文件头及逐函数中文
三段契约扫描 0 diagnostics。上下文复审覆盖迁移闭包的全部方法、runtime 文件入口、
owner/锁、configure/query/copy-ring、pending clone/merge、prepared/noalloc/recover
调用边界和完整 package/models 注册上下文、新测试与门禁全文。原业务方法通过完整
token 对照沿用基线证据；不把自动扫描冒充全项目人工语义/可读性最终验收。

## 新增验证

独立 `rdma_queue_runtime_projector_test` 不构造 runtime、engine、manager 或外部
adapter，直接使用值组件：

- send/receive 完整 pending 图的 detached 引用、nullable SGE、复制阶段位与相等性；
  两类型分别改变九类 immutable evidence，比较必须拒绝。
- 十二个真实创建名各注入 null/错型，共 24 个故障，覆盖 pending/handle/cursor/
  image/status/send/recv/owner/AV/两类 SGE/slot。检查命中、RESOURCE_EXHAUSTED、
  不交付半成品，移除故障后 slot 能再次完整复制。
- status null/错型 fallback、无分配 status 清零/工厂计数、合法空 handle、非法空
  pending、不完整 device evidence、不支持的 semantic subclass、identity/route/cursor。
- 在外层 image factory 回调中递归克隆另一类型和 tag 的 pending，内外 source/copy
  均独立，证明 automatic 局部值未被嵌套调用覆盖；完成后恢复原全局 factory。

六项 Python 门禁固定静态无实例、无反向 owner 依赖、公开兼容与无额外转发壳、
package 顺序、fallback/noalloc/交付时机和独立测试注册。既有 runtime 的真实锁、
depth/wrap/credit、resize、prepared evidence 和 recovery 矩阵继续通过完整 core 验证。
合成值测试不替代业务 admission、跨队列并发或真实 DUT 验收。

## 验证状态

专项与完整回归全部通过，全部 wrapper 返回 0，UVM WARNING/ERROR/FATAL 均为 0。
`/tmp/rdma_batch229_verify_logs.sh` 核对最终计数、24-case 新矩阵、既有 53/126/30-case
矩阵、告警、Python/驱动、wrapper 退出码和源码校验值；统一结果记录在
`/tmp/rdma_batch229_verification_summary.log`。

| 验证 | 结果 | 日志（`/tmp/`） |
| --- | --- | --- |
| 独立 projector focused | 深复制、24-case factory、fallback/noalloc/嵌套复制通过；PROCESS/LOGICAL PASS | `rdma_batch229_focused.log` |
| core | 103/103 PROCESS、86/86 LOGICAL、103 pristine，含新旧值/恢复矩阵 | `rdma_batch229_core.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine | `rdma_batch229_cmq.log` |
| integration | 10/10 pristine | `rdma_batch229_integration.log` |
| E2E 双环境 / 多 VF / 高流量 | 三项各 1 pristine | `rdma_batch229_e2e.log` / `rdma_batch229_e2e_multivf.log` / `rdma_batch229_e2e_traffic.log` |
| Host-memory / PCIe | 3/3、1/1 pristine | `rdma_batch229_host_mem.log` / `rdma_batch229_pcie_work.log` |
| 驱动归档 / C oracle / 字段归属 | 203 自测、definitions、oracle、字段归属通过 | `rdma_batch229_driver_contract.log` |
| Python | 341/341 通过 | `rdma_batch229_python.log` |
| token / 注释结构审计 | 94 方法等价、200 files / 5,326 methods / 0 diagnostics | `rdma_batch229_audit.log` |
| style / diff / lifecycle / profile / Phase-1A | 通过 | `rdma_batch229_style.log`（空）及终端记录 |

三项 E2E 各保留 4 条基线编译告警：2 条 net adapter FLWI 和 2 条外部 net_packet
SV-ANDNMD；其它 VCS 套件无编译告警。UVM pristine 不等于编译零告警。

所有 VCS 都通过项目 wrapper 在 `ubuntu@10.11.10.53` 登录 bash 执行；外部依赖未改：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

专项与完整回归使用相同的 SV/构建输入；完整 Python 门禁在新增后独立执行。送测后
仅更新文档。输入校验值保存在 `/tmp/rdma_batch229_inputs.sha256`，提交前再次核对一致：

```text
b9938f806899fc7d6214ccda5f190279de141e730b3ef86445bd3daf839086d3  src/core/rdma_queue_runtime.sv
f3e52d39f7ab2f6f42d0dc64c578be430712b75d2822781aadc7756352a2e471  src/core/rdma_queue_runtime_projector.sv
00b2f165c647297b3012239cdd067d4b62a75616b1ff360cc23d1b9e379c7479  src/core/rdma_queue_runtime_transaction_models.sv
cf9c9182d86b72ee5f447cbc98a5393423a0655d960634bfca6ba3acba56dce4  src/core/rdma_core_pkg.sv
d41735b31d8e9ce3e9e413e713171b437985a87a2d19bb088ec166c47a2cd21f  tests/unit/rdma_queue_runtime_projector_test.sv
183512fbf7e550b8ce857ca2d5bc907e083d30edcd1f86c9960113b3a911b8c0  tests/unit/test_runtime_projector_boundary.py
a886df6cd93c64de371446a95b1eea44291fcaf1b49bd69c46584f7b51639930  tests/rdma_unit_test_pkg.sv
6104ba36f834ef65b13915664de75c8a5a0dc38132f5fe091cf86708ea2e2cb7  scripts/run_queue_lifecycle_regression53.sh
```

## 尚未关闭

producer/resize 完整编排、manager publication 后更新、runtime snapshot/commit 的
组合验收、跨 owner 原子性、SRQ 全生命周期、跨队列并发、legacy/external ordering/
error、Phase-1C F2、其它 epoch 饱和策略、包 DAG 与全项目可读性验收仍 OPEN。
SQD/SQE 仍 unsupported，外部依赖及 dpu_common 唯一 authority 不变。
