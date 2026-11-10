# RDMA 单场景参数与资源

`rdma_env_cfg.scenario` 是唯一资源/流量参数源。`rdma_traffic_vseq` 对每条 flow group 在两个端点各创建一组 PD、共享 buffer/MR，并按该组的 `qp_count` 创建独立 CQ/QP；同一 RDMA env 可以承载任意数量的 Function 和多条业务边。旧六业务模板、`rdma.biz.*` 和 `rdma.env` 下重复的 QP 参数已删除，无转发别名。

Function 拓扑来自 dpu_common 的冻结 snapshot，RDMA 不自建 Function ID。`rdma_env_cfg.flow_groups` 只保存两端的 `global Function ID` 与对称 QP 数量；空列表保持旧的 `f0/f1` 序列接口。Function 数量没有软件固定的两端限制，实际上限由 snapshot、Host/Function 能力、Notify bank 容量和 `global Function ID < 256` 共同决定。

| 参数组 | 字段与默认值 |
| --- | --- |
| `rdma.qp` | type=RC，depth=256，mtu=1024，max_sge=4，psn=0，qkey=0x80010000，timeout=14，retry=7，rnr_retry=7，min_rnr=1 |
| `rdma.mem` | buf_bytes=0x20000，slot_bytes=0x1000，slots=8，mr_offset=0；mr_remote_read/write/atomic=1 |
| `rdma.pkt` | vlan_en=0，vlan_id=0，src_ip=0，dst_ip=0，udp_sport=0 |
| `rdma.traffic` | op=send，count=32，len=[1:4096]，sge=1，data_mode=RANDOM,FIXED,INCREMENT,PATTERN，signaled_pct=100，dir=2 |

`op` 支持 send/send_imm/write/write_imm/read/cas/faa 或 mix。mix 使用 w_send/w_send_imm/w_write/w_write_imm/w_read/w_cas/w_faa，默认各为1；禁用操作显式置0。RC 支持全部七种操作，UD 只支持 send/send_imm，URC 是 RC 加 urc 标志，只支持 send/write/write_imm。非法非零权重组合拒绝，不自动忽略。RECV 自动配套投递。

SGE 默认从旧 `[1:4]` 改为 `1`，避免短消息非法抽样。显式表达式不会被改写；多 SGE 示例使用 len=[4:4096]、sge=[1:4]。原子固定8字节/单SGE，不读取 len/sge 表达式；远端发起 WR 的 SGE 固定1，不读取 sge；其它 WR 每项求值一次。抽样超出当前长度/槽/MTU/SGE边界直接报完整参数路径与合法范围，禁止裁剪或重抽。候选验证只检查确定性约束，不提前抽样 WR。

每条 flow group 的 SQ/RQ/CQ 共用 `rdma.qp.depth` 请求值；同组的每个 QP 拥有独立 CQ/QP，端点侧 PD、buffer、MR 复用。驱动将 RC/UD 深度取至少256、URC至少8并上取2的幂，上限32768。URC内部CQ fragment仍由驱动创建，不代表重复的场景CQ。不同 QP 暂不支持独立深度或 CQ 共享配置。

```sh
simv +UVM_TESTNAME=rdma_env_traffic_test +rdma.qp.type=RC \
  +rdma.traffic.op=write +rdma.qp.mtu=4096 \
  '+rdma.traffic.len={[1:256]:/30,[257:4096]:/70}'

simv +UVM_TESTNAME=rdma_env_traffic_test +rdma.qp.type=UD \
  +rdma.traffic.op=send '+rdma.traffic.len=[1:512]' +rdma.qp.mtu=512
```

所有 pkt override 只在 `rdma_link_netpkt` 软件帧编码中生效。当前 driver QP 属性和平台 endpoint 没有场景 VLAN/IP/UDP 配置接口；DUT或其他链路设置非默认 pkt 在发送/分配资源前拒绝。DUT冻结route snapshot的编码能力不等于这些场景参数已配置硬件。VLAN限12位，UDP端口限16位，IPv4支持点分或数值；IP/UDP零表示codec默认。

读取优先级：完整Tcl override > leaf override > 完整plusarg > leaf plusarg > 默认值。`set_param` 只改 AIP override 表，项目显式 `load_params` 事务才应用。RDMA不注册命令，也不读取DPU/VIO/PCIe参数。

项目调用 `rdma_aip_cfg_loader::make_runtime_candidate(active, candidate)`，随后 `env.validate_runtime_candidate(candidate)`，全部组件预检成功后调用 `env.apply_runtime_candidate(candidate)`。核心仅数据/校验/提交，不反向导入AIP。提交原地保留cfg/scenario/外部system、DPU快照、BAR与Host manager身份。构建和候选共用load读取逻辑，不使用finalized缓存。固定mode/link/vseq/checker/cov省略时保留活动默认值，显式改变拒绝；可变qp/mem/pkt/traffic与时间字段使用新构造默认值，不回退恢复快照的旧CLI值。

重载只允许初始化前。初始化一旦开始，即使失败或当前队列空闲也拒绝；尚无“释放到未初始化”的接口。不能进行traffic-only热更新。该限制保证所有实际消费者的QP/driver副本都在提交后首次创建，无软件配置与硬件状态分离。

普通标量使用AIP宏；`type`是SV关键字，使用与宏相同的现有`get_single_value`命名入口。len/sge/data_mode用现有原文查询保留分布，并通过lookup_override识别显式空值；不能用会立即随机选逗号项的aip_string。字段语义错误返回status且不提交；AIP非法语法或类型转换错误继承hard fatal，不能承诺这类错误可恢复。没有自建parser或fatal catcher。

测试入口：`rdma_scenario_cfg_test` 验证候选/优先级/身份与初始化门禁；`rdma_scenario_traffic_test` 检查每端资源数量，可用 `+EXPECT_DRAWS=N` 检查真实WR求值次数；`sim/param_regression.list`列出正向参数场景。所有VCS执行在53的登录bash环境，由验证者记录结果。

项目级唯一命令、独立编译和跨进程恢复见 [集成入口](../integration/project/README.md)；
实际验证结果见 [验证记录](../integration/project/VALIDATION.md)。本文件保留历史文件名，现行接口均为上述单场景路径。
