# 集成验证与依赖记录

日期：2026-11-09；本记录区分历史已通过结果、当前发布门禁和外部能力缺口。所有 VCS 编译/运行由指定验证者在 `ubuntu@10.11.10.53` 登录 bash 环境执行；源码实现者没有在本机运行仿真。

## 可复现的依赖状态

[dependencies.tsv](dependencies.tsv) 保存七个参考仓库的完整 commit、工作树条目数、status/content SHA-256。它取自 Task6 的完整依赖 staging 清单，不是仅靠 HEAD 的版本声明。字段 `role=compiled` 表示编译依赖集合；Task6 模型/Tcl实际不编译 Intel，Intel由Task3及Task7完整入口消费。Virtio始终是 reference-only-not-staged。

| 依赖 | commit | 实际未提交差异摘要 |
| --- | --- | --- |
| dpu_common | `29c57d02d91ee8ba5f8b2c19007fa801a355d50d` | 15条；当前公共配置/sequence迁移，移除旧plan/executor接口，含package引用的新dpu_names.sv；完整WIP参与staging |
| host_mem | `bdad0ec66a899e5759cf172117719570a3bc0b30` | clean |
| pcie_work | `b63ca848d4e6d92b336a35a2e04837130c111a02` | 12条；旧executor移除与package清理；本轮依赖准备未改变RC/scoreboard语义 |
| aip_core_set_param_expr | `a0367231fd9568f68547123b7173d49b586b84f6` | clean；使用匹配预建dist loader/.so |
| net_packet | `b212855eb7bc8b0aba5c06b224757c880c6b28e0` | clean |
| pcie_intel | `77d2c6aeefff33732cfd6237c9e5f9919088f48d` | clean；完整Intel类型入口依赖 |
| virtio_work | `1ed3b200d3b6fe12c2c2dbecaaf1dca762fb27b6` | 3367条原始工作树清单，含生成物；仅参考，不staging、不编译，不把全部条目当源码依赖 |

Task6 依赖 staging：`/tmp/rdma-task6-current-deps/deps`。状态清单来源 `output/validation/task6_prep/dependency_state_seven.tsv`；远端完整文件manifest摘要位于同目录 `remote_current_dependency_hashes.txt` 和 `pcie_intel_remote_manifest_hash.txt`。本仓库不修改这些外部checkout。以后重跑须重新记录实际差异及content hash，不能把更新后的兄弟工作树默认为同一输入。

## 已有证据与当前门禁

| 范围 | 实际结论 | 原始记录 |
| --- | --- | --- |
| Task1/2 Host memory、外部快照 | 共享manager/Function账本、ID255/256、同源拒绝、无隐式MMIO、外部缺grant拒绝与模型显式初始化已验证；外部快照在Task5再次通过 | `.superpowers/sdd/2026-11-09-rdma-intel-project-integration/task-1-report.md`、`task-2-report.md`；`output/validation/task5/external*` |
| Task3 Intel transport/PCIe回归 | 双Host实际wrapper、literal8字节、DMA/Completion分片/隔离/reset epoch，以及normal/fault PCIe通过；不含真实DUT | `output/validation/task3/final2_transport_{compile,run}.log`、`final2_rdma_env_pcie{,_fault}_test.log` |
| Task4公共表（历史快照） |33-case PROJECT_CONFIG_PASS，W/E/F=0/0/0；完整预检、单bank和写序；仅routing/table readiness | `output/validation/task4` 与 `task-4-report.md` |
| Task5场景迁移 |13参数行通过；cfg/draw/single/mix/CAS、errors/SRQ/lifecycle/multifunc通过；10负例按预期非零；external snapshot通过、RXE仅编译通过 | `output/validation/task5` 与 `task-5-report.md`；源码manifest SHA-256 `80a1b3ad98f009ca4a467d9132eea193ca5c1fc590dba92ab73fa4fa6d0deb1b` |
| Task6模型/Tcl（commit3e08149） |完整门禁通过：commands/prepare failure/partial probe failure/save/restore/absent32/namespace及预期duplicate/config-fatal；同binary恢复10→override17→新CLI20并实际20 WRITE posts/completions；fresh basic/external snapshot均0/0/0。首个save超时不计通过，第二次成功save用于restore | `output/validation/task6/evidence_final.sha256` 与 `task-6-report.md` 独立最终验证节；源码manifest SHA-256 `c6341f742da148892dca2652dd97fb21269c852246840db9c877ab857c9f84f2` |
| Task7完整类型发布 |独立门禁通过：53上完整Intel类型编译/链接及既有双Host wire fixture运行成功，真实PROJECT_TRANSPORT_PASS与PROJECT_INTEL_TYPES_PASS，W/E/F=0/0/0；静态及文档检查通过。不代表真实RDMA DUT业务验收 | `output/validation/task7_intel/evidence.sha256`、`output/validation/task7/evidence_final.sha256` 与 `task-7-report.md` 独立最终验证节 |

Task6最终任务静态退出0，仅32条软行宽；whitespace通过，旧sim/filelists与config.f不变。匹配AIP `.so` SHA-256为 `1eb87d3589b349c3c06efedb45e968d3a7eb3933427e65c3296231cfbbb407a7`；restore日志 SHA-256为 `251f9e6ebfaac833c340e27772bc490840917f4100549a3bd81e02bc04aaa58a`。最终恢复矩阵沿用同一binary执行精确runner-equivalent命令，未替换binary。

Task5 使用其记录的干净DPU基线；Task6/Task7使用上述完整当前WIP，因此历史结果不能自动替代新composition验证。Task6恢复脚本含测试专有observations，不等于通用平台恢复脚本。

Task3历史静态结论已更正：不可变范围 `08d2f71..cbe7c69` 检查退出1，有135硬错误（127注释标签、5目录/层次、3所有权/生命周期）及84软行宽提示。原始 `output/validation/task3/branch_style_audit.stderr` SHA-256为 `e44cd6fdd3c355592fb5d8e055d497311670247ceaa2a700aecc0478165b5dca`。Task7对9个任务文件规范标签/header；该阶段实际 `python3 tools/check_changed_sv_style.py --base 08d2f71` 返回0，无硬错误，仅202条软行宽提示，历史135硬错误已关闭。Task7范围 `--base 3e08149` 返回0，仅4条软行宽提示；未使用 `--all`，未把历史硬错误改称软提示，也未放宽checker。

## 发布验证命令

完整Intel入口使用 [run_intel.sh](tests/run_intel.sh)；模型/Tcl使用 [run_commands.sh](tests/run_commands.sh)，设置方法见 [README](README.md)。Intel成功必须同时有实际 `PROJECT_TRANSPORT_PASS` 输出、进程成功与W/E/F=0/0/0，runner最后才打印 `PROJECT_INTEL_TYPES_PASS`。未运行不能以脚本存在判定通过。

验证者在最终工作树运行真实diff范围检查，normal模式包含staged/untracked源文件，不用 `--all` 代替任务门禁：

```bash
python3 tools/check_changed_sv_style.py --base 08d2f71
git diff --check 08d2f71
git diff origin/feature/rdma-param-v1 -- sim/filelists
```

独立验证确认：`git diff --check 08d2f71`、`bash -n integration/project/tests/run_intel.sh` 均返回0；7个变更Markdown的围栏闭合，围栏外41个相对链接全部有效。完整类型26项加fixture4项共30项无重复，类型入口不含wrapper/test/top/注册。相对Task6基线 `3e08149`，旧 `sim/filelists` 及config/runtime/commands/namespace/transport清单字节不变。

本次通过验证的是**状态更新前的20文件快照**，其 `source_final.sha256` 清单SHA-256为 `4aa1da36b7f12108d9e6bfa80c17d9a1e140bd726f766870bc67f4a7e6c5435a`；不是本次验收文字更新后的文档哈希。远端 `/tmp/rdma-task7-final/rdma` 逐项校验通过；冻结七行依赖清单SHA-256为 `1603c54aedd0aecfe9559e7c16c7a707890c9675839685c78d6722c73c667b3e`。

53上 `bash integration/project/tests/run_intel.sh` 返回0，VCS W-2024.09-SP1报告 `All of 34 modules done`，实际双Host Intel MMIO/DMA、literal bytes、隔离和epoch检查通过。`build.log` SHA-256为 `f92b38903124cd3a505d1992aa109ae891cff2903270b3878813e7ef5cd843b1`；`run.log` SHA-256为 `ed93d5a421b760f487db76b12f55cd3b593752af5653c3366b1c808cc5513ded`。

Task7范围独立复审为SPEC PASS / QUALITY Approved，执行门禁已通过。随后全分支最终审查发现唯一I1：非空MSI-X遗漏无效尾项。修复提交 `f3e03b1` 已完成独立验证及专项复审，结论为Approved / I1 ADDRESSED，0新增Critical/Important/Minor；批准范围的实现、验证与最终技术复审门禁已关闭。原始 `final-review.md` 的发现及 `final-rereview.md` 的关闭结论均保留。

## 最终I1修复验证

53上使用冻结依赖重新编译配置fixture，VCS W-2024.09-SP1报告 `All of 16 modules done`；实际 `PROJECT_CONFIG_PASS` 为46例，W/E/F=0/0/0。覆盖全部2047尾行的旧字节预填、独立literal值、4094次高DWORD先写、可选2047次8B读回，以及4个尾项写失败、2个读回扰动、6个仅尾部零AF/MMIO预检负例；routing-only仍无MSI-X访问。调用真实继承尾项任务，table-only MSI-X使能无MMIO；可观察顺序为完整尾部处理先于Notify使能及后续类别。

最终 `--base 5f6266a` 静态返回0，仅8条软行宽；`--base 08d2f71` 返回0，仅209条软行宽、0硬错误，whitespace返回0。上文Task7的202条软提示及Task4的33例是各自历史快照，不是最终修复结果。受保护旧filelist、config/完整类型/fixture清单及Intel runner不变；本次未重跑无关的Task6 restore矩阵。

证据索引为 `output/validation/final_fix/attempt2/evidence.sha256`；两文件 `source_final.sha256` 清单SHA-256为 `cda9ae051f3d5d57ad73f7baadfe39907b4d546a741e1092c97f565a28477c96`，远端 `/tmp/rdma-final-fix-attempt2/rdma` 逐项校验通过。`build.log` SHA-256为 `04637dc9c116b3a6c4c022e8af0c9ed0906e8781397118716fea6a79f09a1630`；`run.log` SHA-256为 `d080c4f337ecf762ade6ae8a13bf8b55b037cc7c68d05aadd76a0ccbc038ee1f`。冻结七行依赖清单仍为 `1603c54aedd0aecfe9559e7c16c7a707890c9675839685c78d6722c73c667b3e`。首次运行因测试oracle遗漏Host1合法BDF读回失败，未计通过；原始日志及 `attempt1_evidence.sha256` 保留，修正后才得到上述46例结果。

控制方将独立记录实际工作区转交与证据归档。约定归档根为 `output/rdma-intel-integration-2026-11-09/`：其中 `validation/` 对应本文原始 `output/validation/`，`review/` 对应 `.superpowers/sdd/2026-11-09-rdma-intel-project-integration/`；实际转交确认以交付索引为准。

## 2026-11-10：公共 host_mem_pool 对齐

基线 `f3544deb12394b3a1f8af716f2601f5aad4b7da4`。本轮删除 RDMA 私有 Host 工厂与 PCIe 重复 manager 映射，直接借用平台的公共 pool；独立模型也按冻结 GPA 使用公共 pool。保留 Function 分配账本和完整 DMA 区间检查，生产代码净减少27行，无新增生产类、filelist 或外部仓库修改。

指定验证者在53的登录 bash 中使用新 staging `/tmp/rdma-mem-pool-20261110`，复用上述冻结 Task6 依赖，未替换为更新的外部 WIP。验证输入为状态文档更新前的14文件快照；`source_final.sha256` 的清单 SHA-256 为 `a62a9ecffa1798f031c342d61b7b6c3f3bca1e363947e7c97404ee00f3568969`，远端逐项核验通过。

| 范围 | 实际结果 |
| --- | --- |
| 公共 pool 聚焦测试 | 两个 Host 使用相同 GPA，数据和释放互不影响；同 Host 共享 backing，跨 Function 读写/释放拒绝，清理后无泄漏 |
| 默认模型、外部快照、设备 CMQ | 全部通过；外部 pool 缺失、Host/GPA 错配与重绑定被拒绝，失败不部分发布 |
| 普通 PCIe | fresh build 与 `rdma_env_pcie_test` 通过，消费同一 pool manager |
| 完整 Intel 入口 | fresh 编译/链接与双 Host MMIO/DMA fixture 通过，实际 `PROJECT_TRANSPORT_PASS` 和 `PROJECT_INTEL_TYPES_PASS` |
| 实际 AIP save/restore | 新编译的同一 binary 跨进程保存/恢复通过；`identity=1` 覆盖 pool/manager，重载后 count=20、WRITE posts/completions均20、pending=0、scoreboard errors=0、idle=1 |

上述运行全部 W/E/F=0/0/0。首次 env 编排使用了错误的预期输出目录，编译成功但未运行仿真；保留 `env_external/attempt1`，修正路径后的 `attempt2` 通过，源码未改变。

任务静态检查 `--base f3544de` 返回0、17条软行宽提示；全分支 `--base 08d2f71` 返回0、220条软提示、0硬错误；whitespace通过。旧 `sim/filelists`、集成清单/runner及参数候选策略文件保持不变；4份接口文档的围栏和33个活动相对链接通过。本轮不重跑无关参数/namespace/负例矩阵，不扩大真实 DUT 或 RDMA grant 的结论。

原始证据为 `output/validation/mem_pool_20261110/final_report.md`、`evidence_final.sha256` 及各门禁子目录；AIP restore 日志 SHA-256 为 `2d7d13f9080e4231be17f57cc024649301eb557d7f9c0696339f4fd525d3f85c`。本轮单独归档至 `output/rdma-host-mem-pool-2026-11-10/`，不覆盖上述11月9日交付证据；实际转交以新归档中的 `INDEX.md` 为准。

## 明确未验收的能力

未完成真实DUT引脚/网络接入；没有解决DPU RDMA QP/SD/CEQ/AEQ grant或纯RDMA资源snapshot的VIO前提；没有运行VIO混合业务或live RXE。合法VIO资源fixture不是RDMA授权；公共表完成不是driver ready。平台须提供真实reset/readiness、一次性绑定及DMA静止后的安全释放。
