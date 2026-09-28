<!-- 目录：项目根目录；职责：记录 Batch221 resource 快照职责提取、等价性与验证证据。 -->

# Batch221：分离 resource 快照投影与事务 owner

日期：2026-09-28。工作树：`feature/rdma-cmq-structural-phase2-batch160`。
保留全部历史改动；本批不 commit、merge、push、reset 或 clean。项目级计划仍 active。

## 结构变化

新增一个集中式 `src/core/rdma_resource_projector.sv`，提取 manager 中 33 个 `project_*`
及其 mapping/identity 支撑方法，共 47 个方法。它没有实例字段、静态缓存、manager
引用、继承或 UVM 注册；所有入口为 `static function automatic`，临时对象按调用隔离。
`valid_kind()` 不重复搬迁，新组件直接使用既有 allocator policy。

manager 继续唯一拥有 registry、recovery、binding、allocator、incarnation/generation、
QP sequence、publication epoch 和 mutation guard。业务 admission、stage、commit、
rollback 与公开 API 保持原位；159 处调用改为显式组件限定，不添加转发空壳。
两个派生测试 probe 文件共 8 处调用同步迁移；其它同名比较器属于各自类，不跨组件替换。
core package 在 allocator policy 之后、manager 之前包含 projector，不新增反向依赖。

| 范围 | Batch220 | Batch221 | 变化 |
| --- | ---: | ---: | ---: |
| manager | 10,150 行 / 186 methods | 7,936 行 / 139 methods | −2,214 行 / −47 methods |
| projector | 无 | 2,217 行 / 47 methods | 单一集中组件 |
| 两个生产文件合计 | 10,150 行 | 10,153 行 | +3 行 |

这是职责与阅读范围的收缩，不是总代码量下降，也不表示 manager 已足够小。
package 另增 1 行 include；新增 Python 结构门禁不计作生产代码精简。

## 保持的业务边界

- 普通载体 direct-new，只复制内建字段；不把任意 carrier 的 clone 当作可信深拷贝。
- owned mapping 保留具体 subtype 和 opaque release capability；snapshot、clone、
  source/result authority hook 的顺序、字段/类型/alias 校验及错误文案保持不变。
- recovery-only mapping 保留独立 completion-query clone 路径，不能因抽取组件而重走
  曾失败的普通 authority hooks。原 clone 首次别名拒绝可能留下 output 引用的边界未改变，
  说明明确要求按失败 status 丢弃，不虚称所有失败均自动清空 output。
- slot token 对象必须 detached，但 completion_authority 必须还是同一非拥有引用；
  programmed CQC 保留既有受检查 clone；binding 保留受保护 identity snapshot 配置。
- mapping 的完整 route/reset epoch、ticket deadline、recovery 步骤与错误证据原样保留。
- projector 无状态但不是纯函数：factory、clone、identity、validate、authority 均可能
  同步重入；manager 仍必须锁外准备并在 commit 复核 epoch/source，不能因抽取而移除门禁。

47 个方法均重新编写紧邻的具体中文三段契约，分别说明 nullable 输入、输出清空、
部分填充、authority 借用和各类拒绝条件；补充文件头及 probe 的实际旁路观察边界。
没有修改外部依赖仓库、dependency lock 或模型/adapter 的公开契约。

## 迁移核对与静态验证

以本批开始时未提交的 Batch220 文件为冻结基线，不能用较早 HEAD 冒充前一批状态。
临时核对工具和基线位于 `/tmp/rdma_batch221.emzNcz/`；结果见
`/tmp/rdma_batch221_equivalence.log`：

- 185/186 个原 manager 方法的代码 token 流一致，仅允许类限定、static automatic
  修饰和空白变化；字符串字面量也参与核对。139 个保留方法包括全部公开 API。
  另外逐一比较 48 个公开方法的完整声明，全部与冻结基线一致；新组件没有对剩余
  manager 方法的裸调用，闭包未遗留隐式实例依赖。
  公开声明、control-plane 测试 token 与 package 单行 include 差异的独立核对见
  `/tmp/rdma_batch221_api_consumers.log`。
- `publication_identity_status()` 唯一额外代码为显式
  `default: fields_match = 1'b0;`，与进入 case 前已经为 false 的无匹配路径等价。
  该分支为新增文件的静态门禁要求；没有更改任何既有业务分支或错误优先级。
  首次 style 检查暴露原 case 缺少显式 default；修正后再次检查通过。
- resource-manager 测试 token 流保持一致，只变更调用限定和注释；control-plane
  两处 probe 仅改调用限定/排版，并纠正其并不执行 live generation 准入的旧说明。

新增 `test_resource_projector_boundary.py` 共 6 项，检查无类级状态、无 manager ledger
引用、全部 static automatic、无重复转发、package 顺序、probe 迁移和两类 clone 契约
继续分离。Python 全套 299/299 通过：`/tmp/rdma_batch221_python.log`。
changed-SV style、diff、queue lifecycle、profile naming 和 Phase-1A 通过。
style 证据：`/tmp/rdma_batch221_style.log`；仍有旧文件 soft-limit 提示。
src/tests/unit 全量文件头/方法标签扫描为 192 files / 5,249 methods / 0 diagnostics：
`/tmp/rdma_batch221_contract.log`。机械 GREEN 不代表历史泛化注释语义已全部验收。

## VCS 验证

首轮 focused PROCESS/LOGICAL PASS，UVM 0/0/0、wrapper rc=0：
`/tmp/rdma_batch221_focused.log`。该轮及 `/tmp/rdma_batch221_core.log` 使用显式 default
和注释收尾前的快照，仅作为中间证据；最终验收使用收尾后启动的 core_final。
首轮 core 也已完整结束：97/97 PROCESS、80/80 LOGICAL、97 pristine、wrapper rc=0；
不将早期版本的通过次数与最终版本相加，最终验收仍单独计数。

最终 integration 10/10、Host-memory 3/3、PCIe adapter 1/1 pristine，wrapper rc=0：
`/tmp/rdma_batch221_integration.log`、`/tmp/rdma_batch221_host_mem.log`、
`/tmp/rdma_batch221_pcie_work.log`。
驱动契约 203 项自测、真实归档、CMQ C oracle 和 field ownership 通过，wrapper rc=0：
`/tmp/rdma_batch221_driver_contract.log`。
E2E dual-env、多 VF recovery、高流量三项均 pristine、wrapper rc=0：
`/tmp/rdma_batch221_e2e.log`、`/tmp/rdma_batch221_e2e_multivf.log`、
`/tmp/rdma_batch221_e2e_traffic.log`。
三项 E2E 各有 4 个既有编译警告：本项目 net adapter 的 2 个 FLWI，以及外部
net_packet IPv6 扩展的 2 个 SV-ANDNMD；UVM pristine 不代表编译零警告。
CMQ 最终 28/28 PROCESS、11/11 LOGICAL、28 pristine，wrapper rc=0：
`/tmp/rdma_batch221_cmq.log`。
core 最终 97/97 PROCESS、80/80 LOGICAL、97 pristine，wrapper rc=0：
`/tmp/rdma_batch221_core_final.log`。其中 resource-manager 的四个 admission fixture
仍覆盖 33/31/34/33 个真实窗口，共 131 次逐窗嵌套分配；registry OCC 的 10 个场景
也继续通过。未改变回调数量或利用静态提取绕过原重入检查。
所有最终 wrapper 均 rc=0；汇总计数与编译警告核对见
`/tmp/rdma_batch221_verification_summary.log`。本批验证已完成，但项目计划仍 active。

所有 VCS 通过 `scripts/run_vcs53.sh` 在 ubuntu@10.11.10.53 的登录 bash 执行；
依赖只读使用 HOST_MEM_ROOT=`/home/ubuntu/workspace/host_mem.audit.current`、
DPU_COMMON_ROOT=`/home/ubuntu/deps_virtio/dpu_common`、
NET_PACKET_ROOT=`/home/ubuntu/net_packet_latest`、
PCIE_WORK_ROOT=`/home/ubuntu/workspace/pcie_work_audit.POaPmh`。

最终回归输入指纹（SHA256）：

```text
src/core/rdma_resource_manager.sv
89c3775fedbaddf87f9fa1bfeb550136fcff3336bec168471156bde852759a73
src/core/rdma_resource_projector.sv
853ef8366afa80da3b22be8040d560d000e364ae25c9c61fa92214b11383410a
src/core/rdma_core_pkg.sv
038099562dc65ae56633e76a5769ebf3e5120b5bcfc60c2813710ab1e8a7e1e7
tests/unit/rdma_resource_manager_test.sv
509bcc8ca8fc9c066307235052ec7a96eee96d7c2b4295184bfffa4145f99a3f
tests/unit/rdma_control_plane_test.sv
e0284f459ce13238f58a1aea96a4d2afea7ddd4a07bcedd4f3024338c1882724
tests/unit/test_resource_projector_boundary.py
815642dce2bd2e738731d654984b927004d659d8a94821278b3e4882c8f7a32e
```

core_final、integration、CMQ、E2E、adapter 与 driver 检查均在上述源码/测试收尾后启动；
后续只更新报告和计划，不改动这些验证输入。首轮 focused/core 的早期快照另行保留。

## 复审范围与未关闭项

逐项复审迁移闭包的输入/输出、所有权、null/error、clone/hook 顺序及其 manager/probe
调用点；核对原 manager 全部 186 个方法的迁移/保留代码，读取 package 全部 include
顺序，扫描 src/tests/unit 全目录契约标签。静态扫描和 token 等价不替代动态回调测试，
也不声称本次已人工验收全项目每个历史函数注释。

下一步优先梳理 QP sequence 等 publication 后更新与 manager 剩余 schema/validation
重复路径，再推进 queue-data 的大职责拆分；不要继续堆单函数 policy 文件。
跨 owner 原子性、SRQ 完整业务组合、Phase-1C F2、legacy/external ordering/error、
包 DAG、其它 epoch 饱和策略及全项目注释语义审计继续 OPEN。
