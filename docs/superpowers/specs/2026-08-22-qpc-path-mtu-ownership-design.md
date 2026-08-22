# QPC Path MTU Ownership 设计

## 1. 目的和范围

本文是 `2026-08-21-xtr-v1-context-body-abi-design.md` 的窄范围修订，解决
Task 10C 测试设计阶段发现的 PMTU ownership 缺口：frozen UD QPC golden 包含
`PMTU=4`，但当前 `rdma_qpc_ud_ext` 没有 MTU 字段；RC 和 URC 则分别在 transport
extension 中重复保存 `path_mtu_bytes`。

本设计只修正硬件中立 QPC model 中的 path MTU ownership，并规定 Task 10C 的
xtr_v1 投影、错误和测试契约。它不改变 frozen field definitions 或 golden payload，
不实现其他 QPC 字段，也不涉及 PCIe、host_mem、doorbell、SQE 或 CMQ。

权威软件基线仍为固定驱动提交
`491faf2ba42627fffd4dd027607299c8bb591ec2`。

## 2. 固定驱动证据

固定 archive `/home/ubuntu/workspace/Desktop.zip` 中的驱动表明 PMTU 不是
transport-private 状态：

- `qp.h` 的公共 `struct xtrdma_qpc_ram0_info0` 包含
  `enum xtrdma_mtu pmtu`；
- QP 创建时，`xtrdma_init_qp_context()` 从 netdev 或显式 PMTU policy 初始化
  `ram0_info0->pmtu`；
- `xtrdma_fill_rc_ud_qpc_info()` 对 RC 和 UD 都把同一个
  `ram0_info0->pmtu` 写入 `XTRDMA_QPC_PMTU`；
- `xtrdma_fill_urc_qpc_info()` 同样把 `ram0_info0->pmtu` 写入该公共字段；
- `xtrdma_ib_modify_qp(IB_QP_PATH_MTU)` 更新同一个公共状态；
- `xtrdma_ib_query_qp()` 从该公共状态恢复 `attr->path_mtu`。

因此，UD codec 固定写 4096B 或给三个 transport extension 各自复制 MTU 都会偏离
真实驱动的数据模型。PMTU 必须由公共 QPC model 显式拥有。

## 3. 已选架构

`rdma_qpc_model` 增加：

```systemverilog
int unsigned path_mtu_bytes;
```

同时从 `rdma_qpc_rc_ext` 和 `rdma_qpc_urc_ext` 删除
`path_mtu_bytes`。`rdma_qpc_ud_ext` 保持只拥有 `qkey`，不增加 transport-private
MTU。最终 ownership 是：

| 语义 | owner |
|---|---|
| 所有 transport 的 path MTU | `rdma_qpc_model.path_mtu_bytes` |
| RC remote QPN、PSN、retry | `rdma_qpc_rc_ext` |
| UD QKey | `rdma_qpc_ud_ext` |
| URC sequence、queue backing、threshold | `rdma_qpc_urc_ext` |

QPC constructor 把 `path_mtu_bytes` 初始化为零，表示调用者尚未配置该必需语义。
`do_copy()` 复制公共字段，`describe()` 显示该值。因为 MTU 是 scalar，QPC 的既有
deep-copy 流程不需要增加嵌套对象。

## 4. 硬件中立校验与 xtr_v1 profile

通用 `rdma_qpc_model.validate()` 只要求 `path_mtu_bytes != 0`。它不把 model 限制到
xtr_v1 的能力；例如 256B、512B 或未来设备支持的其他非零 MTU 都是合法的硬件中立
语义。

xtr_v1 codec 单独执行 profile 校验和映射：

| model byte size | xtr_v1 PMTU code |
|---:|---:|
| 1024 | 2 |
| 2048 | 3 |
| 4096 | 4 |
| 8192 | 5 |

encode 遇到 256、512 或其他不在表内的非零值时返回
`RDMA_SC_INVALID_ARGUMENT`。codec 不根据 transport、netdev、golden case 或其他
policy 生成默认 MTU。

decode 执行逆映射。PMTU code 2/3/4/5 分别恢复为
1024/2048/4096/8192B；code 0/1/6/7 不属于本 xtr_v1 profile，按输入 image 损坏返回
`RDMA_SC_CODEC_ERROR`。

所有 encode/decode 继续服从原子输出契约：失败时 encode 不发布半写 image，decode
不发布半填 model。

## 5. Equality 和 golden 数据流

`serialized_equal()` 把 `rdma_qpc_model.path_mtu_bytes` 作为公共、可序列化语义进行
比较。它不得从 transport extension 读取 MTU，也不得忽略 UD MTU。

Task 10C 的三个 frozen golden builder 必须显式设置：

| golden case | common model MTU | encoded code |
|---|---:|---:|
| `qpc_rc_boundary` | 8192B | 5 |
| `qpc_ud_boundary` | 4096B | 4 |
| `qpc_urc_boundary` | 8192B | 5 |

这些值来自 frozen golden inputs，不是新的 transport 默认值。decode 后三种 transport
都从同一公共字段取得 MTU。

## 6. 测试和完成标准

### 6.1 Model 迁移测试

- 更新 context model builder，把原 RC extension MTU 移到 QPC common model；
- 更新 request model 的 RC、UD、URC 切换测试，始终从 QPC common model 设置和观察
  MTU；
- 验证 `path_mtu_bytes=0` 返回 `RDMA_SC_INVALID_ARGUMENT`；
- 验证 256B 在通用 model 中合法，证明 xtr_v1 profile 没有泄漏到 model；
- 验证 QPC clone 保留公共 MTU，并且 RC/URC extension 不再承载该字段；
- `describe()` 必须包含公共 MTU。

### 6.2 Task 10C codec 测试

- RC、UD、URC golden 逐 byte 比较都从公共 MTU 来源构造；
- 三种 transport 都验证 PMTU encode/decode round-trip；
- `serialized_equal()` 的逐字段 falsification 表加入公共 MTU mutation；
- 1024/2048/4096/8192B 分别验证映射 2/3/4/5；
- 256B、512B 和其他非零 unsupported size 在 encode 返回
  `RDMA_SC_INVALID_ARGUMENT`；
- PMTU code 0/1/6/7 在 decode 返回 `RDMA_SC_CODEC_ERROR`；
- 所有失败路径验证 caller output 保持 null/未发布。

### 6.3 执行顺序和验证环境

新增 prerequisite Task 10A.2：先迁移 model、model tests 和父设计/计划，再恢复
Task 10C。Task 10C 在 prerequisite 提交并通过审查前不得硬编码 UD PMTU。

SystemVerilog compile/simulation 只在 `10.11.10.53` 通过 fresh runner 执行。Task
10A.2 至少运行：

```text
rdma_context_model_test
rdma_request_model_test
rdma_model_test
rdma_resource_manager_test
```

Task 10C 恢复后还要运行 QPC codec、qword helper 和 context model 回归。每项完成标准
都是进程退出 0，且 UVM warning/error/fatal 为 0/0/0。

## 7. 对现有设计和计划的修订

本文取代原 ABI 设计和实施计划中把 `path_mtu_bytes` 放在 RC/URC extension 的代码块
与相关描述。原文“path MTU 在 model 中用 byte size 表示”继续有效，但现在明确指
`rdma_qpc_model.path_mtu_bytes`。

除 PMTU ownership、校验、equality 和测试来源外，QPC behavior、context backing、
transport extension、field mapping、private 512B mask、reserved-bit 和 error-code 契约
保持不变。
