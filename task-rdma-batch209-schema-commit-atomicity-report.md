# Batch209：resource manager schema detached commit 原子性

## 本批范围

本批只处理 `src/core/rdma_resource_manager.sv` 的 schema 复审写回边界：

- `registry_schema_status()` 先投影全部 registry 条目，再一次性写回；
- `recovery_schema_status()` 先投影全部 recovery 条目，再一次性写回；
- `recovery_entry_schema_status()` 对单 key 使用同一 detached→guarded commit 规则；
- 外部 clone/factory 投影阶段不持有 `mutation_guard`，最终写回阶段检查
  `publication_epoch` 和原对象引用，避免回调重入或并发替换覆盖新账本。

registry/recovery 仍由 manager 唯一拥有；本批没有移动 allocator、adapter、Host-memory、
PCIe、mapping 或 backing 的生命周期，也没有新增第二份可变账本。

## 失败与边界

任一 carrier 类型不匹配、投影返回 null、commit window 忙、epoch 改变或原条目引用被
替换时，函数返回明确错误且不写入已投影条目。未知 recovery key 继续保持幂等成功。
hostile fixture 将一个 PD key 替换为 MR carrier，验证前一项成功投影不会被部分发布。

## 验证证据

- VCS53 登录 bash：`rdma_resource_manager_test` PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL `0/0/0`。
- 证据日志：`/tmp/rdma_batch209_resource_manager.log`。
- Python unit：`python3 -m unittest discover -s tests/unit -p 'test_*.py'`，293/293 PASS。
- changed-SV style、queue lifecycle、profile naming、Phase-1A approval 和
  `git diff --check HEAD` 通过；外部依赖锁验证需使用锁定的 pcie_work/host_mem 审计快照，
  当前开发 checkout 的 HEAD 与锁定提交不同，因此不把该工作树直接结果冒充为供应链通过。

## 后续开放项

本批不关闭 allocator/registry 跨线程或跨进程完整互斥、manager 更广泛外部调用窗口、
SRQ 全生命周期组合、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、
PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 或最终 ownership 审计；项目级计划
继续保持 `active`。
