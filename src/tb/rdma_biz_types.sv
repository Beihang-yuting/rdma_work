// 目录：验证组件层 tb/rdma_biz_types.sv。
// 层：验证组件（配置类型）。
// 职责：定义运行模式、Function 角色、业务类型枚举，以及业务模板的四组参数结构（QP、内存、报文属性、
//   流量分布）。这些是纯值类型，放在资源层与 item 之前，供 rdma_res_qp 记录每个 QP 的报文属性、
//   rdma_biz_cfg 组合成模板、参数适配层按字段加载。
// 依赖：无（只用内建类型）。
// 所有权：值类型，按值拷贝，不涉及对象所有权。
// 生命周期：编译期类型定义。

// 运行模式：PEER 为仿真模型之间对接；RXE 含 Soft-RoCE 远端 Function；DUT 为 RTL 设备 + 模型作 RM
//   （V1 只保留枚举与校验入口，DUT 桥接与 RM 在后续版本实现）。
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

// 内置业务类型；每种业务决定 QP 类型与允许的 verb 集合。
typedef enum {
  RDMA_BIZ_SEND,
  RDMA_BIZ_WRITE,
  RDMA_BIZ_READ,
  RDMA_BIZ_ATOMIC,
  RDMA_BIZ_UD,
  RDMA_BIZ_URC
} rdma_biz_kind_e;

// 业务 QP 参数。数值 0（depth/mtu/qkey）或 -1（timeout/retry/rnr_retry/min_rnr）表示继承
//   rdma_env_cfg 的同名默认值，在 finalize 时解析，便于插件（如 rxe）在 pre_build 调整环境默认值。
typedef struct {
  int unsigned depth;
  int unsigned mtu;
  int unsigned max_sge;
  int unsigned psn;
  bit [31:0] qkey;
  int timeout;
  int retry;
  int rnr_retry;
  int min_rnr;
} rdma_biz_qp_t;

// 业务内存参数：缓冲大小、消息槽（单条消息长度上限与轮转槽数）、MR 在缓冲内的偏移与远端权限。
typedef struct {
  int unsigned buf_bytes;
  int unsigned slot_bytes;
  int unsigned slots;
  int unsigned mr_offset;
  bit mr_remote_read;
  bit mr_remote_write;
  bit mr_remote_atomic;
} rdma_biz_mem_t;

// 业务报文属性：随 QP 绑定，帧编码链路（netpkt、DUT）编码该 QP 发出的报文时使用；0 表示沿用链路默认。
typedef struct {
  bit vlan_en;
  int unsigned vlan_id;
  bit [31:0] src_ip;
  bit [31:0] dst_ip;
  int unsigned udp_sport;
} rdma_biz_pkt_t;

// 业务流量分布：消息数、各 verb 权重、长度/SGE 表达式、数据模式候选、signaled 比例与方向。
typedef struct {
  int unsigned count;
  int unsigned w_send;
  int unsigned w_send_imm;
  int unsigned w_write;
  int unsigned w_write_imm;
  int unsigned w_read;
  int unsigned w_cas;
  int unsigned w_faa;
  string len;
  string sge;
  string data_mode;
  int unsigned signaled_pct;
  int unsigned dir;
} rdma_biz_trf_t;
