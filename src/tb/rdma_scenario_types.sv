// 目录：验证组件层 tb/rdma_scenario_types.sv。
// 层：验证组件（配置类型）。
// 职责：定义运行模式、Function 角色、传输类型枚举，以及统一场景的四组参数结构（QP、内存、报文属性、
//   流量分布）。这些是纯值类型，放在资源层与 item 之前，供 rdma_res_qp 记录每个 QP 的报文属性、
//   rdma_scenario_cfg 组合为单一场景、参数适配层按字段加载。
// 依赖：无（只用内建类型）。
// 所有权：值类型，按值拷贝，不涉及对象所有权。
// 生命周期：编译期类型定义。

// 运行模式：PEER 为仿真模型之间对接；RXE 含 Soft-RoCE 远端 Function；DUT 为 RTL 设备 + 模型作 RM
//   DUT 使用平台 endpoint 与冻结 route snapshot，不把软件模型当成真实硬件。
typedef enum {
  RDMA_ENV_MODE_PEER,
  RDMA_ENV_MODE_RXE,
  RDMA_ENV_MODE_DUT
} rdma_env_mode_e;

// Function 角色：MODEL 由 rdma_dev 模型充当设备；DUT 为 RTL 设备（模型退为 RM 影子）。
//   rxe 远端 Function 由插件经 remote_funcs 声明，不出现在 funcs 中。
typedef enum {
  RDMA_FUNC_ROLE_MODEL,
  RDMA_FUNC_ROLE_DUT
} rdma_func_role_e;

// 场景传输类型与 traffic.op 分离；URC 在驱动中仍是 RC 加 urc 标志。
typedef enum { RDMA_SCENARIO_RC, RDMA_SCENARIO_UD, RDMA_SCENARIO_URC } rdma_scenario_type_e;

// QP 参数直接持有生效值，不再借助环境同名默认值或继承哨兵。
typedef struct {
  rdma_scenario_type_e	kind;
  int unsigned	depth;
  int unsigned	mtu;
  int unsigned	max_sge;
  int unsigned	psn;
  int unsigned	dest_qpn;
  bit [31:0]	qkey;
  int	timeout;
  int	retry;
  int	rnr_retry;
  int	min_rnr;
} rdma_scenario_qp_t;

// 场景内存参数：缓冲大小、消息槽（单条消息长度上限与轮转槽数）、MR 在缓冲内的偏移与远端权限。
typedef struct {
  int unsigned	buf_bytes;
  int unsigned	slot_bytes;
  int unsigned	slots;
  int unsigned	mr_offset;
  bit	mr_remote_read;
  bit	mr_remote_write;
  bit	mr_remote_atomic;
} rdma_scenario_mem_t;

// 场景报文属性：随 QP 绑定，帧编码链路或 DUT TX 参数下发使用；
//   0 表示沿用链路默认。
typedef struct {
  bit	vlan_en;
  int unsigned	vlan_id;
  bit [47:0]	src_mac;
  bit [47:0]	dst_mac;
  bit [31:0]	src_ip;
  bit [31:0]	dst_ip;
  int unsigned	udp_sport;
} rdma_scenario_pkt_t;

// 场景流量分布：消息数、各 verb 权重、长度/SGE 与 payload/IMM 原始表达式、
//   数据模式候选、signaled 比例与方向。
typedef struct {
  string	op;
  int unsigned	count;
  int unsigned	w_send;
  int unsigned	w_send_imm;
  int unsigned	w_write;
  int unsigned	w_write_imm;
  int unsigned	w_read;
  int unsigned	w_cas;
  int unsigned	w_faa;
  string	len;
  string	sge;
  string	data_mode;
  string	data_fixed;
  string	data_pattern;
  string	imm;
  int unsigned	signaled_pct;
  int unsigned	dir;
} rdma_scenario_traffic_t;

// 一个可运行的 Function 对：两端使用 dpu_common 发布的 global Function ID，
// qp_count 表示该业务边上对称创建的 QP 数量。它描述流量拓扑，不拥有 QP 或内存。
typedef struct {
  int unsigned	f0_global_id;
  int unsigned	f1_global_id;
  int unsigned	qp_count;
} rdma_flow_group_t;
