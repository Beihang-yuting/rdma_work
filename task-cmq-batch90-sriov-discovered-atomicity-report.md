# CMQ Batch 90：SR-IOV 多 VF 失败输出原子性修复

本批修复 `rdma_sriov_enumerator::enumerate_and_configure_pf` 在 VF0 已成功快照、
VF1 后续校验失败时仍把 VF0 留在 `discovered` 输出的问题。失败回滚现在统一接收
该 output queue 的 `ref`，在配置恢复与 lease 逆序释放后清空；入口仍先清空 output，
因此失败结果不会携带部分成功的 Function topology。

同时合并 SR-IOV fault adapter 中重复的 `cfg_read32/cfg_write32` 声明，把 null-status
注入与按序号故障注入放进唯一 override；新增第二个 VF vendor read 故障场景（预置
sentinel、`fail_vf_vendor_read_at=2`），断言 status 非成功、discovered 为空、lease 与
NumVFs/VFE/VF-MSE 均回到入口状态。外部 `pcie_work` integration 仍只受 approved-lock
阻断，未修改外部依赖。

## 源码边界

| 文件 | SHA-256 | Git blob SHA-1 |
| --- | --- | --- |
| `src/core/rdma_sriov_enumerator.sv` | `a3393e84f5599cb5b97ce098ee241133b24a4aabf3be24c4debde32598e377ce` | `b85a3a00f3e993a0274f19363d6a6894ece03f04` |
| `tests/integration/rdma_sriov_enumeration_test.sv` | `29e04d6fd9f606efc4a13e6e4f5f053f724c3c9a2b5f1881c1d80312bc264ca6` | `8eb1e75fc800a4aca39ce10ec64fc077ac54d586` |
| `tests/unit/rdma_sriov_enumerator_authority_test.sv` | `cf1ba01591989177860d16a7753456dae5b184d0c9fad05e1088cb4b9cf6e565` | `05aa1fde3b2524e9b666b6dce0d5f30b5fbe9869` |

## 验证

- `rdma_sriov_enumerator_authority_test`：wrapper rc=0，PROCESS/LOGICAL 1/1，严格
  UVM warning/error/fatal=0/0/0；日志 `evidence/post-batch89-rdma_sriov_enumerator_authority_test.log`
  SHA-256=`523e701c5e98fb8fb5be66e06a1a2e05820a41549767e058cd13909f519a3fd8`。
- core 编译解析了包含 integration fixture 的 `rdma_unit_test_pkg`，重复 override 已消除。
  直接以 `rdma_sriov_enumeration_test` 作为 core test 会因该 integration test 未在
  core factory 注册而得到 UVM `INVTST`，不计作生产逻辑失败；真实 `pcie_work` 入口仍
  由 external dependency approved lock 控制。
- `test_sv_keyword_guards.py` 通过；当前工作树最终静态门禁为 Python 292/292、manifest
  22/22、changed-SV style rc=0、`git diff --check` rc=0。Batch89–93 边界后的 parent
  gate wrapper rc=0、PROCESS 28/28、LOGICAL 11/11、严格 UVM warning/error/fatal=0/0/0；
  日志 SHA-256=`8838b7e379db7e56f1e4824924a91523cc4fe64bae3fb31ec22d757f8d62e620`。
