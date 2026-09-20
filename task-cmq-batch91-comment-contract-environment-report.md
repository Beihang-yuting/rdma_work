# CMQ Batch 91：环境与 backing 边界契约复审

本批针对环境组合层、配置快照、queue backing access 和 responder registry 做完整函数级
契约复审。实现边界保持不变（`rdma_env.sv` 中既有的候选组合/factory 原子性改动不
属于本批新增）；本批把每个函数的中文说明统一为“功能 / 输入/输出及副作用 /
失败/边界”，并让说明与当前所有权、快照和拒绝分支一致。

## 源码边界

| 文件 | SHA-256 | 本批说明 |
| --- | --- | --- |
| `src/core/rdma_env.sv` | `5e2b5102e81235bb544e0f618165cd1473d28dedbbf06c2729abcd3bf2f06935` | 注释复审；保留既有候选组合实现 |
| `src/core/rdma_env_config.sv` | `051e9499f8f1dd19e0d23a51d5ae8d88a48bcf8da3e407842d818c4c7b98d639` | 注释复审 |
| `src/core/rdma_queue_backing_access.sv` | `aeaa5daf944a230d6398af5f7d55647be3ac02926865bf4ccd302ffeb95663b7` | 注释复审 |
| `src/core/rdma_responder_registry.sv` | `ecb4b23047cd0ff40bde6ed83b0c8db5eaf34c96997afbe698a38b3128b9e9d6` | 注释复审 |

## 复审结论

- 四个文件中的旧标签 `输入输出及副作用`、`失败边界` 已清零。
- env 14 个、env_config 3 个、backing access 25 个、responder registry 16 个
  function/task 均有紧邻的三段中文契约；说明覆盖 detached snapshot、borrowed
  adapter、Function incarnation、claim/seal、重复 attachment 和 null/status 拒绝。
- `git diff --check` 与 changed-SV style 均通过；style 仅保留已有
  `rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## 验证

在 `ubuntu@10.11.10.53` 登录 bash 环境运行的 focused 测试均通过：

- `rdma_env_composition_test`：wrapper rc=0；PROCESS/LOGICAL=1/1；严格 UVM
  warning/error/fatal=0/0/0；
  测试内部捕获的两个预期 build fatal 不计为 UVM fatal。
- `rdma_queue_backing_access_test`：wrapper rc=0；PROCESS/LOGICAL=1/1；严格 UVM
  warning/error/fatal=0/0/0；日志 SHA-256=`d73553a1483217150baab8ab5cdd2b3c16d8418a406d610d0afa8f08a8d07339`。
- `rdma_responder_registry_test`：wrapper rc=0；PROCESS/LOGICAL=1/1；严格 UVM
  warning/error/fatal=0/0/0；日志 SHA-256=`d98b859df932e4f37df4262d62199acb6a77629ca4e3e3f27bf0ab09c5a07800`。
- env 完整 wrapper 日志：
  `.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/post-batch91-rdma_env_composition_test.log`
- 日志 SHA-256：
  `1f71c22c150f75ab2de62beca5a454af896e310ec6e24e114884fd7440c4fb78`
- backing/responder 完整日志分别位于
  `evidence/post-batch91-rdma_queue_backing_access_test.log` 和
  `evidence/post-batch91-rdma_responder_registry_test.log`。

当前工作树 parent gate、Phase 1C F2、reset coordinator 生命周期和全目录最终复审
仍开放。
