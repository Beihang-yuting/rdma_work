<!-- 目录：项目根目录；职责：记录 Batch223 queue-data 值投影分离、语义核对及验证。 -->

# Batch223：queue-data 值投影与业务编排分离

日期：2026-09-28。沿用 `feature/rdma-structural-batch222`，基线为已验证的 `1a1322c`。
本轮只继续重构，不合并、不推送；本地主线保持 `5f8dfe9`。项目计划仍 active。

## 结构变化

新增一个集中式 `rdma_queue_data_projector.sv`，迁入 engine 中的 25 个值方法：

- raw factory、状态完整初始化/复制、consumer handle/image/cursor/status 物化；
- CQE、CEQE、AEQE candidate 结果图构造，保留单 owner 的 event 兼容入口；
- 完整 incarnation、attachment key、跨 generation 的 CQ cleanup key、CQ/QP route、
  cursor、CQC 几何/owner 和 pending route/epoch 值比较或投影。

所有方法均 `static function automatic`；类没有字段、锁、缓存、继承、UVM 注册或
provider 实例。engine 用 `value_ops` 类型别名缩短限定调用，不保留重复转发壳。
`make_engine_status_nonfatal` / `set_engine_status_noalloc` 分别改名为
`make_status_nonfatal` / `set_status_noalloc`，raw factory 实例名仍为原字符串
`queue_data_engine_status`，没有改变故障注入和分配顺序。

| 范围 | Batch222 | Batch223 | 变化 |
| --- | ---: | ---: | ---: |
| queue-data engine | 10,872 行 / 161 methods | 10,000 行 / 136 methods | −872 行 / −25 methods |
| projector | 无 | 889 行 / 25 methods | 单一无状态组件 |
| 两个生产文件合计 | 10,872 行 | 10,889 行 | +17 行 |

package 另增 1 行 include。净增加来自明确边界说明、限定调用换行和新文件的风格要求；
这批是 engine 职责与阅读范围收缩，不声称项目总代码量下降，也不代表万行 engine
已达到最终结构目标。没有新增单函数 policy 文件或额外运行对象。

## 保持的业务边界

27 个公开业务方法的完整声明保持不变，engine 所有状态字段保持不变。attachment/
QP link/CQ resize/unclaimed recovery 索引、binding、manager、runtime、backing、
scheduler、resize lock 及业务 admission/I/O/commit/replay 顺序均留在原 owner。
25 个受保护值入口迁出，三个内部测试 probe 文件同步改用显式类型限定。
所有外部依赖仓库和 dependency lock 均未修改，dpu_common 身份 authority 不变。

无状态不等于纯函数，也不等于无分配：

- raw factory 和 AEQE `set_profile_owner_authority()` 窗口原样保留。无分配状态
  helper 仍不调用 factory、clone 或 do_copy，consumer barrier 之后的限制不放宽。
- `prepare_cq_completion_candidate()` 会原位更新并复用输入 detached release slot
  的 posted/consumed/status；它不能接收 live ledger，也不代表 WQE 已释放。
- raw helper 最终返回 status 的工厂可能失败，此时 copy/candidate/final_success
  可能已经填充；CQ slot 循环失败也可能留下已处理的前项。调用方按失败状态丢弃
  输出的原行为不变，注释不再虚称所有失败必定清空全部输出或存在本地 fallback。
- 镜像投影保留向 raw factory 对象追加 bytes/field_summary 的原契约；不暗中清空
  override 预填队列，不在职责迁移中混入 clone/alias 或 factory 防御策略变更。
- 完整 live incarnation 与忽略 generation 的 CQ cleanup identity 继续分开。
  route 值比较保留全部 Host/root/segment/BDF 字段；显式 valid 的零 epoch 在值层
  仍可比较/复制，真正的资源准入与 reset authority 仍由 caller 决定。

## 迁移核对与测试

只读审计 `/tmp/rdma_batch223_audit.py` 固定对照 `1a1322c`，结果见
`/tmp/rdma_batch223_audit.log`：

- 161/161 个原方法的 token（包含字符串）一致，只允许类限定、上述两处改名和
  `protected function` → `static function automatic`。迁移 25、保留 136，未漏方法。
- 27 个公开方法声明一致；移除方法后的整个 engine 类壳只多一个类型别名。
- post/device-publish 两个测试文件全部 token 除限定和改名外一致；package 只有
  新组件单行 include，位于 data transaction models 后、engine 前。
- src/tests/unit 文件头及独占中文三段标签扫描为 193 files / 5,257 methods /
  0 diagnostics。该扫描不代替全项目历史注释语义验收。

新增 6 项 Python 边界门禁：无状态/static automatic、无 owner/runtime 访问、无
重复转发壳、package 顺序、无分配 helper 与 factory 边界、值测试不再构造 engine。
Python 全套 305/305 通过：`/tmp/rdma_batch223_python.log`。
changed-SV style、diff、queue lifecycle、profile naming、Phase-1A 通过；初始新文件
沿用旧式单行 if-return，被 style 拒绝，随后仅拆行修正，最终 style 无诊断：
`/tmp/rdma_batch223_style.log`。

`rdma_queue_detached_snapshot_probe` 改为继承 `uvm_object`，不再为了值测试构造
engine/planner；既有 CQE/CEQE/AEQE typed/raw 快照检查保留。新增独立用例检查：
null 与完整/cleanup key 的区别、SQ/RQ key 隔离、无 runtime attachment、CQ route
方向、cursor wrap、route 的 7 个组成字段、epoch/valid 漂移、零 epoch 兼容语义及
无效 pending authority 的清空。不访问 Host-memory、PCIe 或真实生命周期 owner。

## VCS 验证

本批完整回归通过，所有 wrapper 均返回 0。所有 VCS 均通过
`scripts/run_vcs53.sh` 在 ubuntu@10.11.10.53 的登录 bash 执行。

| 验证入口 | 状态 | 日志（`/tmp/`） |
| --- | --- | --- |
| detached snapshot focused | PROCESS/LOGICAL PASS、UVM pristine、wrapper rc=0 | `rdma_batch223_focused.log` |
| core 全量 | 97/97 PROCESS、80/80 LOGICAL、97 pristine，wrapper rc=0 | `rdma_batch223_core.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine，wrapper rc=0 | `rdma_batch223_cmq.log` |
| integration | 10/10 pristine，wrapper rc=0 | `rdma_batch223_integration.log` |
| E2E dual-env / 多 VF / 高流量 | 三项均 pristine，wrapper 均 rc=0 | `rdma_batch223_e2e.log` / `rdma_batch223_e2e_multivf.log` / `rdma_batch223_e2e_traffic.log` |
| Host-memory / PCIe adapter | 3/3、1/1 pristine，wrapper 均 rc=0 | `rdma_batch223_host_mem.log` / `rdma_batch223_pcie_work.log` |
| 驱动归档、CMQ C oracle、字段归属 | 203 项自测与真实归档检查通过，wrapper rc=0 | `rdma_batch223_driver_contract.log` |

最终日志计数、UVM severity、Python/驱动自测及 style 汇总验收通过，见
`/tmp/rdma_batch223_verification_summary.log`。提交前再次核对全部 7 个源码/测试
输入的 SHA256 与下列冻结指纹一致；161 方法迁移审计、changed-SV style 和
`git diff --check` 再次通过，回归后仅更新本批文档。

三项 E2E 各保留 4 个基线编译警告：本项目 net adapter 的 2 个 FLWI 和外部
net_packet IPv6 扩展的 2 个 SV-ANDNMD。UVM pristine 不等于编译零警告。

只读外部依赖：HOST_MEM_ROOT=`/home/ubuntu/workspace/host_mem.audit.current`、
DPU_COMMON_ROOT=`/home/ubuntu/deps_virtio/dpu_common`、
NET_PACKET_ROOT=`/home/ubuntu/net_packet_latest`、
PCIE_WORK_ROOT=`/home/ubuntu/workspace/pcie_work_audit.POaPmh`。

仿真输入 SHA256：

```text
4262c202696e13c95409d59bc8e9b44be9a956a41ef2b167406e6d678333b693  src/core/rdma_queue_data_engine.sv
30d37e82842e04042a1741bce15b821be9619157fa8cbdffebb544c705895701  src/core/rdma_queue_data_projector.sv
9e796a60bec7764f950a603373e769e1178398b7a43a70afb7142a4bff069231  src/core/rdma_core_pkg.sv
6a72425f71ea67d9f5769d7e3c790e8f14803260df79540727fba791d20ed5d6  tests/unit/rdma_queue_detached_snapshot_test.sv
2eab72d68d8258e366b02a54651cac850f24b1d3354deadf2f686232dc04b4e8  tests/unit/rdma_queue_data_engine_post_test.sv
508cf97c05aeae74a62224bbe1c503c5398cf0691048306c8f69750f0149eee8  tests/unit/rdma_queue_data_engine_device_publish_test.sv
1873d8f0227a5a79f577e8daf470319390768019770de54f48b61ff0aaa693dc  tests/unit/test_queue_data_projector_boundary.py
```

## 复审范围与未关闭项

复审迁移闭包的全部方法与原调用点、engine owner 类壳、package 全部依赖顺序、
三个受影响测试文件的 fixture/factory/恢复边界；新注释明确真实失败输出与 slot
副作用。全目录静态扫描和 161 方法等价核对不冒充全项目人工语义验收。
queue-data producer/consumer/resize 的事务编排收束、manager publication 后更新、
跨 owner 原子性、SRQ 完整业务组合、Phase-1C F2、legacy/external ordering/error、
包 DAG、其它 epoch 饱和策略和最终可读性审计继续 OPEN。
