// 目录：模型层 model/rdma_flow_profiles.sv。
// 层次：RDMA 流量配置与冻结值模型。
// 职责：定义流量 plan、QP/QPC/HMC/message/netpacket/endpoint/fault profile，以及 resolver
//   发布给 driver、device、codec、sequencer 和 DUT link 的只读 snapshot 类型。
// 依赖：rdma_types_pkg 的状态、身份、地址和语义 opcode；不访问 link、env、AIP 或外部资源。
// 所有权与生命周期：profile 由测试或 AIP 适配层拥有且可修改；snapshot 由 resolver 独立创建，
//   freeze 后只作为值快照传递，外部 handle/资源仍由各自 owner 管理。

// 设计说明：同一个字段必须携带选择策略，才能区分用户固定值、resolver 自动关联、合法随机值和
//   故意注入的非法值。INVALID 只作为负向场景标记，正常 resolver 会拒绝它。
typedef enum bit [1:0] {
  RDMA_FIELD_AUTO         = 2'd0,
  RDMA_FIELD_FIXED        = 2'd1,
  RDMA_FIELD_RANDOM_LEGAL = 2'd2,
  RDMA_FIELD_INVALID      = 2'd3
} rdma_field_mode_e;

// 兼容调用方可能使用的 MODE 前缀命名；别名仍保持同一枚举值和验证语义。
localparam rdma_field_mode_e RDMA_FIELD_MODE_AUTO = RDMA_FIELD_AUTO;
localparam rdma_field_mode_e RDMA_FIELD_MODE_FIXED = RDMA_FIELD_FIXED;
localparam rdma_field_mode_e RDMA_FIELD_MODE_RANDOM_LEGAL = RDMA_FIELD_RANDOM_LEGAL;
localparam rdma_field_mode_e RDMA_FIELD_MODE_INVALID = RDMA_FIELD_INVALID;

typedef enum bit {
  RDMA_FLOW_MANAGED_LINK = 1'b0,
  RDMA_FLOW_STATIC_PEER  = 1'b1
} rdma_flow_link_mode_e;

typedef enum bit [1:0] {
  RDMA_FLOW_QP_RC  = 2'd0,
  RDMA_FLOW_QP_UD  = 2'd1,
  RDMA_FLOW_QP_URC = 2'd2
} rdma_flow_qp_type_e;

typedef enum bit [2:0] {
  RDMA_FLOW_FAULT_DROP          = 3'd0,
  RDMA_FLOW_FAULT_DUPLICATE     = 3'd1,
  RDMA_FLOW_FAULT_DELAY         = 3'd2,
  RDMA_FLOW_FAULT_REORDER       = 3'd3,
  RDMA_FLOW_FAULT_CORRUPT      = 3'd4,
  RDMA_FLOW_FAULT_BAD_ICRC      = 3'd5,
  RDMA_FLOW_FAULT_BAD_VLAN      = 3'd6,
  RDMA_FLOW_FAULT_BAD_FWD       = 3'd7
} rdma_flow_fault_kind_e;

typedef enum bit [1:0] {
  RDMA_FLOW_PBL_AUTO   = 2'd0,
  RDMA_FLOW_PBL_LINEAR = 2'd1,
  RDMA_FLOW_PBL_SPARSE = 2'd2,
  RDMA_FLOW_PBL_INVALID= 2'd3
} rdma_flow_pbl_mode_e;

typedef class rdma_qp_profile;
typedef class rdma_qpc_profile;
typedef class rdma_hmc_profile;
typedef class rdma_message_profile;
typedef class rdma_netpacket_profile;
typedef class rdma_endpoint_profile;
typedef class rdma_fault_profile;
typedef class rdma_qp_snapshot;
typedef class rdma_qpc_snapshot;
typedef class rdma_hmc_snapshot;
typedef class rdma_message_snapshot;
typedef class rdma_netpacket_snapshot;
typedef class rdma_endpoint_snapshot;
typedef class rdma_fault_snapshot;

// 功能：判断字段策略是否属于四个公开枚举值。
// 输入/输出及副作用：mode 为输入；返回 bit，不修改 profile 或 snapshot。
// 失败/边界：四个枚举值均有效；X/Z 在仿真比较中返回 0。
function automatic bit rdma_field_mode_valid(rdma_field_mode_e mode);
  return mode inside {RDMA_FIELD_AUTO, RDMA_FIELD_FIXED, RDMA_FIELD_RANDOM_LEGAL,
                      RDMA_FIELD_INVALID};
endfunction

// 功能：判断字段是否被明确标为故障注入用 INVALID 策略。
// 输入/输出及副作用：mode 为输入；返回 bit，无副作用。
// 失败/边界：AUTO/FIXED/RANDOM_LEGAL 均返回 0，X/Z 返回 0。
function automatic bit rdma_field_mode_is_invalid(rdma_field_mode_e mode);
  return mode == RDMA_FIELD_INVALID;
endfunction

// 功能：判断策略能否进入正常 profile/resolver 路径。
// 输入/输出及副作用：mode 为输入；返回 bit，无副作用。
// 失败/边界：AUTO/FIXED/RANDOM_LEGAL 返回 1；INVALID 或 X/Z 返回 0，INVALID 只能由 fault 规则显式使用。
function automatic bit rdma_field_mode_normal(rdma_field_mode_e mode);
  return rdma_field_mode_valid(mode) && !rdma_field_mode_is_invalid(mode);
endfunction

// 设计说明：profile base 只保存来源身份和 freeze 状态，子类保存具体配置。resolver 将来源
// identity 复制到 snapshot，避免后续修改 profile 影响已经发布的运行时输入。
virtual class rdma_flow_profile_base extends uvm_object;
  string source_id;
  longint unsigned reset_epoch;
  bit frozen;

  // 功能：构造尚未冻结的 profile，并初始化来源身份与 reset epoch。
  // 输入/输出及副作用：name 成为 UVM 对象名；source_id 为空、reset_epoch 为 0、frozen 为 0。
  // 失败/边界：构造不校验身份；resolver 在发布 snapshot 前必须补齐非空 source_id 和 epoch。
  function new(string name = "rdma_flow_profile_base");
    super.new(name);
    source_id = "";
    reset_epoch = '0;
    frozen = 1'b0;
  endfunction

  // 功能：把 profile 标记为不可再作为 mutable 输入使用。
  // 输入/输出及副作用：设置 frozen=1 并返回 1；不复制字段、不分配对象。
  // 失败/边界：重复 freeze 幂等返回 1；基类不阻止直接字段写入，调用方须遵守只读契约。
  virtual function bit freeze();
    frozen = 1'b1;
    return 1'b1;
  endfunction

  // 功能：检查 profile 已提供的来源身份；mutable 输入允许暂时没有 source_id/freeze。
  // 输入/输出及副作用：只读本对象；返回状态对象。
  // 失败/边界：frozen 对象必须有 source_id；尚未冻结的输入交由 resolver 补齐来源并生成 snapshot。
  virtual function rdma_status validate();
    if (frozen && source_id == "")
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flow profile source_id is empty");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 设计说明：QP profile 只保存用户可选的队列协议字段；local_qpn、CQ/QP handle 等资源关联
// 由 resolver 生成，防止每个调用方自行拼接 QP identity。
class rdma_qp_profile extends rdma_flow_profile_base;
  `rdma_object_utils(rdma_qp_profile)

  int unsigned index;
  rdma_field_mode_e qp_type_mode;
  rdma_flow_qp_type_e qp_type;
  rdma_field_mode_e sq_depth_mode;
  rdma_field_mode_e rq_depth_mode;
  rdma_field_mode_e mtu_mode;
  rdma_field_mode_e pkey_mode;
  rdma_field_mode_e qkey_mode;
  rdma_field_mode_e psn_mode;
  rdma_field_mode_e dest_qpn_mode;
  rdma_field_mode_e max_send_sge_mode;
  rdma_field_mode_e max_recv_sge_mode;
  rdma_field_mode_e max_inline_mode;
  int unsigned sq_depth;
  int unsigned rq_depth;
  int unsigned mtu;
  bit [15:0] pkey;
  bit [31:0] qkey;
  bit [23:0] psn;
  bit [23:0] dest_qpn;
  int unsigned max_send_sge;
  int unsigned max_recv_sge;
  int unsigned max_inline;
  int unsigned local_qpn;
  bit [63:0] qp_h;
  bit [63:0] send_cq_h;
  bit [63:0] recv_cq_h;

  // 功能：构造一个 RC QP profile，填充最小可用深度/MTU/SGE 默认值。
  // 输入/输出及副作用：初始化所有策略为 AUTO；资源 handle 与 QPN 清零。
  // 失败/边界：默认 profile 需由 resolver 分配 QPN/handle；直接用于建 QP 前必须设置 index。
  function new(string name = "rdma_qp_profile");
    super.new(name);
    index = 0;
    qp_type_mode = RDMA_FIELD_FIXED;
    qp_type = RDMA_FLOW_QP_RC;
    sq_depth_mode = RDMA_FIELD_AUTO;
    rq_depth_mode = RDMA_FIELD_AUTO;
    mtu_mode = RDMA_FIELD_AUTO;
    pkey_mode = RDMA_FIELD_AUTO;
    qkey_mode = RDMA_FIELD_AUTO;
    psn_mode = RDMA_FIELD_AUTO;
    dest_qpn_mode = RDMA_FIELD_AUTO;
    max_send_sge_mode = RDMA_FIELD_AUTO;
    max_recv_sge_mode = RDMA_FIELD_AUTO;
    max_inline_mode = RDMA_FIELD_AUTO;
    sq_depth = 64;
    rq_depth = 64;
    mtu = 1024;
    pkey = 16'hffff;
    qkey = 32'h8001_0000;
    psn = '0;
    dest_qpn = '0;
    max_send_sge = 4;
    max_recv_sge = 4;
    max_inline = 64;
    local_qpn = '0;
    qp_h = '0;
    send_cq_h = '0;
    recv_cq_h = '0;
  endfunction

  // 功能：校验 QP profile 的策略、队列深度、MTU 和资源字段。
  // 输入/输出及副作用：只读 profile；返回 OK 或定位到首个非法字段的 status。
  // 失败/边界：INVALID 策略、零深度/MTU/SGE、URC 之外的未知 QP 类型均拒绝；frozen/source 由基类检查。
  virtual function rdma_status validate();
    rdma_status s;
    s = super.validate();
    if (!s.ok()) return s;
    if (!rdma_field_mode_normal(qp_type_mode) || !rdma_field_mode_normal(sq_depth_mode) ||
        !rdma_field_mode_normal(rq_depth_mode) || !rdma_field_mode_normal(mtu_mode) ||
        !rdma_field_mode_normal(pkey_mode) || !rdma_field_mode_normal(qkey_mode) ||
        !rdma_field_mode_normal(psn_mode) || !rdma_field_mode_normal(dest_qpn_mode) ||
        !rdma_field_mode_normal(max_send_sge_mode) || !rdma_field_mode_normal(max_recv_sge_mode) ||
        !rdma_field_mode_normal(max_inline_mode))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP field mode is invalid");
    if (sq_depth == 0 || rq_depth == 0 || mtu == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP depth and MTU must be nonzero");
    if (max_send_sge == 0 || max_recv_sge == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP SGE limits must be nonzero");
    if (!(qp_type inside {RDMA_FLOW_QP_RC, RDMA_FLOW_QP_UD, RDMA_FLOW_QP_URC}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP type is unsupported");
    if (qp_type == RDMA_FLOW_QP_RC && qkey_mode == RDMA_FIELD_FIXED && qkey != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "RC QP cannot require a nonzero Q_Key");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 设计说明：QPC profile 承载路径和权限输入；PD/CQ/SRQ、CQN、shadow 与 backing 地址仍是
// resolver 自动产生的关联字段，netpacket 不能反向覆盖这些 QPC 值。
class rdma_qpc_profile extends rdma_flow_profile_base;
  `rdma_object_utils(rdma_qpc_profile)

  int unsigned qp_index;
  rdma_field_mode_e pd_ref_mode;
  rdma_field_mode_e send_cq_ref_mode;
  rdma_field_mode_e recv_cq_ref_mode;
  rdma_field_mode_e srq_ref_mode;
  rdma_field_mode_e dmac_mode;
  rdma_field_mode_e vlan_mode;
  rdma_field_mode_e fwd_mode;
  rdma_field_mode_e tunnel_mode;
  rdma_field_mode_e access_mode;
  bit [63:0] pd_ref;
  bit [63:0] send_cq_ref;
  bit [63:0] recv_cq_ref;
  bit [63:0] srq_ref;
  bit [47:0] dmac;
  bit [31:0] local_ip;
  bit [15:0] vlan;
  bit [7:0] fwd;
  bit [7:0] tunnel;
  rdma_rdma_access_t access;
  bit [63:0] qp_h;
  bit [31:0] send_cqn;
  bit [31:0] recv_cqn;
  bit [63:0] qpc_shadow;
  bit [63:0] sq_backing;
  bit [63:0] rq_backing;
  bit [63:0] pd_h;
  bit [63:0] srq_h;

  // 功能：构造路径字段为空的 QPC profile，并启用 resolver 自动关联。
  // 输入/输出及副作用：所有策略默认为 AUTO；权限默认允许本地写/远端读写/原子。
  // 失败/边界：构造不分配 PD/CQ/QP；dmac、IP、VLAN 等必须由固定值或 resolver 填充。
  function new(string name = "rdma_qpc_profile");
    super.new(name);
    qp_index = 0;
    pd_ref_mode = RDMA_FIELD_AUTO;
    send_cq_ref_mode = RDMA_FIELD_AUTO;
    recv_cq_ref_mode = RDMA_FIELD_AUTO;
    srq_ref_mode = RDMA_FIELD_AUTO;
    dmac_mode = RDMA_FIELD_AUTO;
    vlan_mode = RDMA_FIELD_AUTO;
    fwd_mode = RDMA_FIELD_AUTO;
    tunnel_mode = RDMA_FIELD_AUTO;
    access_mode = RDMA_FIELD_FIXED;
    pd_ref = '0;
    send_cq_ref = '0;
    recv_cq_ref = '0;
    srq_ref = '0;
    dmac = '0;
    local_ip = '0;
    vlan = '0;
    fwd = '0;
    tunnel = '0;
    access = '{local_write:1'b1, remote_read:1'b1, remote_write:1'b1,
              memory_window_bind:1'b0, remote_atomic:1'b1};
    qp_h = '0;
    send_cqn = '0;
    recv_cqn = '0;
    qpc_shadow = '0;
    sq_backing = '0;
    rq_backing = '0;
    pd_h = '0;
    srq_h = '0;
  endfunction

  // 功能：校验 QPC 的引用策略、路径字段和权限策略。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：INVALID 策略、零固定 DMAC、保留 FWD/tunnel 编码或访问权限策略 INVALID 拒绝。
  virtual function rdma_status validate();
    rdma_status s;
    s = super.validate();
    if (!s.ok()) return s;
    if (!rdma_field_mode_normal(pd_ref_mode) || !rdma_field_mode_normal(send_cq_ref_mode) ||
        !rdma_field_mode_normal(recv_cq_ref_mode) || !rdma_field_mode_normal(srq_ref_mode) ||
        !rdma_field_mode_normal(dmac_mode) || !rdma_field_mode_normal(vlan_mode) ||
        !rdma_field_mode_normal(fwd_mode) || !rdma_field_mode_normal(tunnel_mode) ||
        !rdma_field_mode_normal(access_mode))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QPC field mode is invalid");
    if (dmac_mode == RDMA_FIELD_FIXED && dmac == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "fixed QPC DMAC is zero");
    if (fwd_mode == RDMA_FIELD_FIXED && fwd > 8'h0f)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QPC FWD encoding is reserved");
    if (tunnel_mode == RDMA_FIELD_FIXED && tunnel > 8'h03)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QPC tunnel encoding is reserved");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 设计说明：HMC profile 将页大小、PBL 模式、SD 有效位和 VF 身份集中管理，避免 driver/dev
// 各自推导 PBA 对齐；地址由 resolver 生成后写入 snapshot。
class rdma_hmc_profile extends rdma_flow_profile_base;
  `rdma_object_utils(rdma_hmc_profile)

  rdma_field_mode_e page_size_mode;
  rdma_field_mode_e pbl_mode_mode;
  rdma_field_mode_e sd_vld_mode;
  rdma_field_mode_e vf_id_mode;
  rdma_field_mode_e pba_alignment_mode;
  int unsigned page_size;
  rdma_flow_pbl_mode_e pbl_mode;
  bit sd_vld;
  bit [15:0] vf_id;
  int unsigned pba_alignment;
  bit [63:0] hmc_pba;
  bit [63:0] pbl_base;
  bit [63:0] sd_base;

  // 功能：构造 HMC profile，默认 4KiB 页、linear PBL 和有效 SD。
  // 输入/输出及副作用：策略设为 AUTO（PBL mode 除外）；地址字段清零。
  // 失败/边界：尚未分配 HMC/PBL/SD 地址；page_size 与 alignment 必须在 freeze 前设为合法值。
  function new(string name = "rdma_hmc_profile");
    super.new(name);
    page_size_mode = RDMA_FIELD_AUTO;
    pbl_mode_mode = RDMA_FIELD_FIXED;
    sd_vld_mode = RDMA_FIELD_FIXED;
    vf_id_mode = RDMA_FIELD_AUTO;
    pba_alignment_mode = RDMA_FIELD_AUTO;
    page_size = 4096;
    pbl_mode = RDMA_FLOW_PBL_LINEAR;
    sd_vld = 1'b1;
    vf_id = '0;
    pba_alignment = 4096;
    hmc_pba = '0;
    pbl_base = '0;
    sd_base = '0;
  endfunction

  // 功能：校验 HMC 页/PBL/SD/VF 参数组合。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：页大小或 PBA 对齐非 2 的幂、PBL INVALID 或非法策略均拒绝；sd_vld=0
  //   是合法的“该 SD 项无效”配置，是否允许由上层测试组合决定。
  virtual function rdma_status validate();
    rdma_status s;
    s = super.validate();
    if (!s.ok()) return s;
    if (!rdma_field_mode_normal(page_size_mode) || !rdma_field_mode_normal(pbl_mode_mode) ||
        !rdma_field_mode_normal(sd_vld_mode) || !rdma_field_mode_normal(vf_id_mode) ||
        !rdma_field_mode_normal(pba_alignment_mode))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "HMC field mode is invalid");
    if (page_size == 0 || pba_alignment == 0 || (page_size & (page_size - 1)) != 0 ||
        (pba_alignment & (pba_alignment - 1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "HMC page/alignment must be powers of two");
    if (pbl_mode == RDMA_FLOW_PBL_INVALID)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "HMC PBL mode is invalid");
    if (hmc_pba != 0 && (hmc_pba % pba_alignment) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "HMC PBA is not aligned");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 设计说明：message profile 只描述一次业务 WR；WQE 物理位置、PSN 消耗和 MR 关联由 resolver
// 生成，payload 保留为值数组，避免后续修改调用方 buffer 影响 snapshot。
class rdma_message_profile extends rdma_flow_profile_base;
  `rdma_object_utils(rdma_message_profile)

  int unsigned index;
  int unsigned qp_index;
  rdma_field_mode_e opcode_mode;
  rdma_work_opcode_e opcode;
  rdma_field_mode_e sge_count_mode;
  rdma_field_mode_e local_offset_mode;
  rdma_field_mode_e length_mode;
  rdma_field_mode_e lkey_mode;
  rdma_field_mode_e rkey_mode;
  rdma_field_mode_e remote_va_mode;
  rdma_field_mode_e imm_mode;
  rdma_field_mode_e atomic_mode;
  int unsigned sge_count;
  int unsigned local_offset;
  int unsigned length;
  bit [31:0] lkey;
  bit [31:0] rkey;
  bit [63:0] remote_va;
  bit [31:0] imm;
  bit [63:0] atomic_compare;
  bit [63:0] atomic_swap_add;
  bit signaled;
  byte unsigned payload[$];
  bit [63:0] wqe_address;
  bit [31:0] psn_first;

  // 功能：构造一个默认 SEND message，长度和 payload 均为零，发送完成默认 signaled。
  // 输入/输出及副作用：策略默认为 AUTO；payload 为空且地址关联清零。
  // 失败/边界：SEND 之外的 opcode 需由调用方补齐 rkey/remote_va/atomic 字段。
  function new(string name = "rdma_message_profile");
    super.new(name);
    index = 0;
    qp_index = 0;
    opcode_mode = RDMA_FIELD_FIXED;
    opcode = RDMA_WR_SEND;
    sge_count_mode = RDMA_FIELD_AUTO;
    local_offset_mode = RDMA_FIELD_AUTO;
    length_mode = RDMA_FIELD_AUTO;
    lkey_mode = RDMA_FIELD_AUTO;
    rkey_mode = RDMA_FIELD_AUTO;
    remote_va_mode = RDMA_FIELD_AUTO;
    imm_mode = RDMA_FIELD_AUTO;
    atomic_mode = RDMA_FIELD_AUTO;
    sge_count = 1;
    local_offset = 0;
    length = 0;
    lkey = '0;
    rkey = '0;
    remote_va = '0;
    imm = '0;
    atomic_compare = '0;
    atomic_swap_add = '0;
    signaled = 1'b1;
    payload.delete();
    wqe_address = '0;
    psn_first = '0;
  endfunction

  // 功能：校验 message 的 opcode、长度、SGE 和原子/远端字段组合。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：INVALID 策略、零 SGE、长度超过 payload、SEND 携带远端地址、原子长度非 8B 均拒绝。
  virtual function rdma_status validate();
    rdma_status s;
    s = super.validate();
    if (!s.ok()) return s;
    if (!rdma_field_mode_normal(opcode_mode) || !rdma_field_mode_normal(sge_count_mode) ||
        !rdma_field_mode_normal(local_offset_mode) || !rdma_field_mode_normal(length_mode) ||
        !rdma_field_mode_normal(lkey_mode) || !rdma_field_mode_normal(rkey_mode) ||
        !rdma_field_mode_normal(remote_va_mode) || !rdma_field_mode_normal(imm_mode) ||
        !rdma_field_mode_normal(atomic_mode))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "message field mode is invalid");
    if (sge_count == 0 || length > 0 && payload.size() != 0 && length != payload.size())
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "message length or SGE count is invalid");
    if (opcode inside {RDMA_WR_ATOMIC_CMP_SWAP, RDMA_WR_ATOMIC_FETCH_ADD} && length != 8)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "atomic message length must be 8");
    if (opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM, RDMA_WR_RECV} &&
        rkey_mode == RDMA_FIELD_FIXED && rkey != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "SEND/RECV cannot require fixed rkey");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 设计说明：netpacket profile 只描述 wire/业务封装；QPN、PSN、目的 MAC 等同名 path 字段只做
// 一致性断言，resolver 从 QPC snapshot 生成默认值，禁止 netpacket 回写 QPC。
class rdma_netpacket_profile extends rdma_flow_profile_base;
  `rdma_object_utils(rdma_netpacket_profile)

  int unsigned message_index;
  rdma_field_mode_e transport_mode;
  rdma_transport_e transport;
  rdma_field_mode_e dmac_mode;
  rdma_field_mode_e smac_mode;
  rdma_field_mode_e source_ip_mode;
  rdma_field_mode_e destination_ip_mode;
  rdma_field_mode_e udp_source_port_mode;
  rdma_field_mode_e udp_destination_port_mode;
  rdma_field_mode_e vlan_mode;
  rdma_field_mode_e qpn_mode;
  rdma_field_mode_e psn_mode;
  bit [47:0] dmac;
  bit [47:0] smac;
  bit [31:0] source_ip;
  bit [31:0] destination_ip;
  bit [15:0] udp_source_port;
  bit [15:0] udp_destination_port;
  bit [15:0] vlan;
  bit [23:0] qpn;
  bit [23:0] psn;
  byte unsigned business_header[$];
  byte unsigned payload[$];

  // 功能：构造默认 RoCE/RC netpacket profile，并清空可选外层字段与业务数据。
  // 输入/输出及副作用：策略默认 AUTO，transport 固定为 RC；不取得 codec/link 所有权。
  // 失败/边界：默认 profile 尚不能编码，需 resolver 绑定 message/QPC 后补齐 QPN、PSN、MAC。
  function new(string name = "rdma_netpacket_profile");
    super.new(name);
    message_index = 0;
    transport_mode = RDMA_FIELD_FIXED;
    transport = RDMA_TRANSPORT_RC;
    dmac_mode = RDMA_FIELD_AUTO;
    smac_mode = RDMA_FIELD_AUTO;
    source_ip_mode = RDMA_FIELD_AUTO;
    destination_ip_mode = RDMA_FIELD_AUTO;
    udp_source_port_mode = RDMA_FIELD_AUTO;
    udp_destination_port_mode = RDMA_FIELD_AUTO;
    vlan_mode = RDMA_FIELD_AUTO;
    qpn_mode = RDMA_FIELD_AUTO;
    psn_mode = RDMA_FIELD_AUTO;
    dmac = '0;
    smac = '0;
    source_ip = '0;
    destination_ip = '0;
    udp_source_port = 4791;
    udp_destination_port = 4791;
    vlan = '0;
    qpn = '0;
    psn = '0;
    business_header.delete();
    payload.delete();
  endfunction

  // 功能：校验 netpacket 的传输类型、端口和策略。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：INVALID 策略、RESERVED transport、UDP 端口为零或固定 QPN 为零均拒绝。
  virtual function rdma_status validate();
    rdma_status s;
    s = super.validate();
    if (!s.ok()) return s;
    if (!rdma_field_mode_normal(transport_mode) || !rdma_field_mode_normal(dmac_mode) ||
        !rdma_field_mode_normal(smac_mode) || !rdma_field_mode_normal(source_ip_mode) ||
        !rdma_field_mode_normal(destination_ip_mode) || !rdma_field_mode_normal(udp_source_port_mode) ||
        !rdma_field_mode_normal(udp_destination_port_mode) || !rdma_field_mode_normal(vlan_mode) ||
        !rdma_field_mode_normal(qpn_mode) || !rdma_field_mode_normal(psn_mode))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "netpacket field mode is invalid");
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD, RDMA_TRANSPORT_URC}))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "netpacket transport is unsupported");
    if (udp_source_port == 0 || udp_destination_port == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "netpacket UDP port is zero");
    if (qpn_mode == RDMA_FIELD_FIXED && qpn == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "fixed netpacket QPN is zero");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 设计说明：endpoint profile 仅保存 DUT 网络边界的声明性参数；endpoint handle 和生命周期由外部
// plugin 拥有，snapshot 只保存可校验的端口、地址、队列和 epoch 值。
class rdma_endpoint_profile extends rdma_flow_profile_base;
  `rdma_object_utils(rdma_endpoint_profile)

  rdma_field_mode_e dut_port_mode;
  rdma_field_mode_e dut_mac_mode;
  rdma_field_mode_e peer_mac_mode;
  rdma_field_mode_e mtu_mode;
  rdma_field_mode_e frame_limit_mode;
  rdma_field_mode_e queue_depth_mode;
  int unsigned dut_port;
  bit [47:0] dut_mac;
  bit [47:0] peer_mac;
  int unsigned mtu;
  int unsigned frame_limit;
  int unsigned queue_depth;
  time tx_timeout;
  time rx_timeout;
  bit [63:0] endpoint_h;

  // 功能：构造 endpoint profile，默认端口0、1500B MTU和有限队列。
  // 输入/输出及副作用：初始化地址/handle为空；不创建或打开 endpoint。
  // 失败/边界：endpoint_h 是非拥有引用的值占位，实际生命周期必须由 plugin 管理。
  function new(string name = "rdma_endpoint_profile");
    super.new(name);
    dut_port_mode = RDMA_FIELD_FIXED;
    dut_mac_mode = RDMA_FIELD_AUTO;
    peer_mac_mode = RDMA_FIELD_AUTO;
    mtu_mode = RDMA_FIELD_FIXED;
    frame_limit_mode = RDMA_FIELD_AUTO;
    queue_depth_mode = RDMA_FIELD_AUTO;
    dut_port = 0;
    dut_mac = '0;
    peer_mac = '0;
    mtu = 1500;
    frame_limit = 2048;
    queue_depth = 64;
    tx_timeout = 1us;
    rx_timeout = 1us;
    endpoint_h = '0;
  endfunction

  // 功能：校验 endpoint 的端口、MTU、帧上限和队列容量。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：MTU/frame_limit/queue_depth 为零、固定 DUT MAC 为零或 frame 小于 MTU 均拒绝。
  virtual function rdma_status validate();
    rdma_status s;
    s = super.validate();
    if (!s.ok()) return s;
    if (!rdma_field_mode_normal(dut_port_mode) || !rdma_field_mode_normal(dut_mac_mode) ||
        !rdma_field_mode_normal(peer_mac_mode) || !rdma_field_mode_normal(mtu_mode) ||
        !rdma_field_mode_normal(frame_limit_mode) || !rdma_field_mode_normal(queue_depth_mode))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "endpoint field mode is invalid");
    if (mtu == 0 || frame_limit == 0 || queue_depth == 0 || frame_limit < mtu)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "endpoint size or queue is invalid");
    if (dut_mac_mode == RDMA_FIELD_FIXED && dut_mac == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "fixed endpoint DUT MAC is zero");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 设计说明：fault profile 只描述 link/endpoint 可观察的 frame 故障；它不能伪造 QPC、MR、PD 或
// HMC 字段，INVALID profile 字段也必须由显式故障开关承担责任。
class rdma_fault_profile extends rdma_flow_profile_base;
  `rdma_object_utils(rdma_fault_profile)

  int unsigned index;
  bit enabled;
  rdma_flow_fault_kind_e kind;
  rdma_field_mode_e direction_mode;
  int unsigned direction;
  int unsigned function_index;
  int unsigned qp_index;
  bit [23:0] qpn;
  rdma_work_opcode_e opcode;
  rdma_packet_segment_e segment;
  int unsigned frame_offset;
  int unsigned skip;
  int unsigned count;
  int unsigned probability_percent;
  time delay;

  // 功能：构造禁用的 frame fault 规则，默认匹配任意方向/对象但不影响正常流量。
  // 输入/输出及副作用：enabled=0，计数窗口和概率清零；不注册到任何 link。
  // 失败/边界：只有 resolver 看到 enabled=1 时才检查 kind、概率与窗口；禁用规则可保留默认值。
  function new(string name = "rdma_fault_profile");
    super.new(name);
    index = 0;
    enabled = 1'b0;
    kind = RDMA_FLOW_FAULT_DROP;
    direction_mode = RDMA_FIELD_AUTO;
    direction = 0;
    function_index = '1;
    qp_index = '1;
    qpn = '0;
    opcode = RDMA_WR_SEND;
    segment = RDMA_SEG_ONLY;
    frame_offset = 0;
    skip = 0;
    count = 0;
    probability_percent = 0;
    delay = 0ns;
  endfunction

  // 功能：校验启用故障规则的动作、概率和计数窗口。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：启用时概率大于100、未知 kind、INVALID direction 或空窗口组合拒绝；禁用规则直接 OK。
  virtual function rdma_status validate();
    rdma_status s;
    s = super.validate();
    if (!s.ok()) return s;
    if (!enabled)
      return rdma_status::make(RDMA_SC_OK, "");
    if (!(kind inside {RDMA_FLOW_FAULT_DROP, RDMA_FLOW_FAULT_DUPLICATE,
                       RDMA_FLOW_FAULT_DELAY, RDMA_FLOW_FAULT_REORDER,
                       RDMA_FLOW_FAULT_CORRUPT, RDMA_FLOW_FAULT_BAD_ICRC,
                       RDMA_FLOW_FAULT_BAD_VLAN, RDMA_FLOW_FAULT_BAD_FWD}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "fault kind is unsupported");
    if (probability_percent > 100 || rdma_field_mode_is_invalid(direction_mode))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "fault probability or direction is invalid");
    if (count == 0 && skip != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "fault skip requires a nonzero count");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 以下 snapshot 类型复用对应 profile 的字段布局，但使用独立对象承载 resolver 结果，保证
// profile 修改不会改变已发布运行时输入。freeze() 由顶层 resolver 统一调用。
class rdma_qp_snapshot extends rdma_qp_profile;
  `rdma_object_utils(rdma_qp_snapshot)
  // 功能：构造尚未冻结的 QP snapshot 对象。
  // 输入/输出及副作用：调用基类初始化所有 QP 值；不复制任何 profile。
  // 失败/边界：必须由 resolver 填值并 freeze 后才能交给 driver/dev。
  function new(string name = "rdma_qp_snapshot");
    super.new(name);
  endfunction
endclass

class rdma_qpc_snapshot extends rdma_qpc_profile;
  `rdma_object_utils(rdma_qpc_snapshot)
  // 功能：构造尚未冻结的 QPC snapshot。
  // 输入/输出及副作用：初始化 QPC 值；不取得外部资源所有权。
  // 失败/边界：resolver 未补齐 qpc_shadow/backing 前不能作为硬件上下文。
  function new(string name = "rdma_qpc_snapshot");
    super.new(name);
  endfunction
endclass

class rdma_hmc_snapshot extends rdma_hmc_profile;
  `rdma_object_utils(rdma_hmc_snapshot)
  // 功能：构造尚未冻结的 HMC snapshot。
  // 输入/输出及副作用：初始化页/PBL/SD 值；不分配 HMC。
  // 失败/边界：PBA/PBL/SD 地址仍须由 resolver 或资源 owner 填充。
  function new(string name = "rdma_hmc_snapshot");
    super.new(name);
  endfunction
endclass

class rdma_message_snapshot extends rdma_message_profile;
  `rdma_object_utils(rdma_message_snapshot)
  // 功能：构造尚未冻结的 message snapshot。
  // 输入/输出及副作用：初始化业务 WR 值；payload 仍为空并由 resolver 拷贝。
  // 失败/边界：未绑定 qp_index/PSN 时不能投递。
  function new(string name = "rdma_message_snapshot");
    super.new(name);
  endfunction
endclass

class rdma_netpacket_snapshot extends rdma_netpacket_profile;
  `rdma_object_utils(rdma_netpacket_snapshot)
  // 功能：构造尚未冻结的 netpacket snapshot。
  // 输入/输出及副作用：初始化 wire 字段；不创建 codec frame。
  // 失败/边界：必须由 resolver 与 QPC/message snapshot 做一致性检查后发布。
  function new(string name = "rdma_netpacket_snapshot");
    super.new(name);
  endfunction
endclass

class rdma_endpoint_snapshot extends rdma_endpoint_profile;
  `rdma_object_utils(rdma_endpoint_snapshot)
  // 功能：构造尚未冻结的 endpoint snapshot。
  // 输入/输出及副作用：初始化 endpoint 值；不启动或关闭外部 endpoint。
  // 失败/边界：endpoint_h 只用于 route 校验，生命周期仍归 plugin。
  function new(string name = "rdma_endpoint_snapshot");
    super.new(name);
  endfunction
endclass

class rdma_fault_snapshot extends rdma_fault_profile;
  `rdma_object_utils(rdma_fault_snapshot)
  // 功能：构造尚未冻结的 fault snapshot。
  // 输入/输出及副作用：初始化禁用规则；不注入或统计故障。
  // 失败/边界：只有 resolver 发布后 link 才可消费该规则。
  function new(string name = "rdma_fault_snapshot");
    super.new(name);
  endfunction
endclass

// 设计说明：DUT link 的发送配置不能再用单个 message/netpacket 隐含代表整个 flow plan。
// 每个 route snapshot 把一个 message、它绑定的 QP/QPC 和 wire netpacket 绑成不可分割的
// 路由单元；link 按报文 QPN 选择路由，避免多 QP 场景误用第一个 QP 的 QPC。
class rdma_dut_link_route_snapshot extends uvm_object;
  `rdma_object_utils(rdma_dut_link_route_snapshot)

  int unsigned message_index;
  bit frozen;
  rdma_qp_snapshot qp;
  rdma_qpc_snapshot qpc;
  rdma_message_snapshot message;
  rdma_netpacket_snapshot netpacket;

  // 功能：构造尚未冻结的单 message DUT 路由快照，所有子对象由 resolver 后续绑定。
  // 输入/输出及副作用：初始化索引、冻结状态和子对象引用；不复制或取得资源所有权。
  // 失败/边界：缺少任一 QP/QPC/message/netpacket 的路由不能冻结，也不能交给 DUT link。
  function new(string name = "rdma_dut_link_route_snapshot");
    super.new(name);
    message_index = 0;
    frozen = 1'b0;
    qp = null;
    qpc = null;
    message = null;
    netpacket = null;
  endfunction

  // 功能：冻结 route 所引用的四个子 snapshot，形成 link 可复用的只读绑定单元。
  // 输入/输出及副作用：调用子对象 freeze 并设置 frozen；不修改字段值或外部资源生命周期。
  // 失败/边界：任一子对象为空、子对象 freeze 失败或 message/netpacket 索引不一致时返回 0。
  function bit freeze();
    if (qp == null || qpc == null || message == null || netpacket == null)
      return 1'b0;
    if (netpacket.message_index != message_index)
      return 1'b0;
    void'(qp.freeze());
    void'(qpc.freeze());
    void'(message.freeze());
    void'(netpacket.freeze());
    frozen = 1'b1;
    return 1'b1;
  endfunction

  // 功能：检查 route 的子 snapshot 身份、QP 索引和 netpacket message 索引一致。
  // 输入/输出及副作用：只读 route；返回首个失败状态，不改写任何子对象。
  // 失败/边界：未冻结、空子对象、QPC 不指向 QP、netpacket 不指向本 message 或任一子校验失败时拒绝。
  function rdma_status validate();
    rdma_status status;

    if (!frozen || qp == null || qpc == null || message == null || netpacket == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "DUT route snapshot is incomplete");
    if (qpc.qp_index != message.qp_index)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DUT route QPC does not match message QP");
    if (netpacket.message_index != message_index)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DUT route netpacket index conflicts");
    if (qp.source_id == "" || qp.source_id != qpc.source_id ||
        qp.source_id != message.source_id || qp.source_id != netpacket.source_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DUT route source identity conflicts");
    if (qp.reset_epoch == 0 || qp.reset_epoch != qpc.reset_epoch ||
        qp.reset_epoch != message.reset_epoch || qp.reset_epoch != netpacket.reset_epoch)
      return rdma_status::make(RDMA_SC_STALE_GENERATION, "DUT route reset epoch conflicts");
    status = qp.validate();
    if (!status.ok()) return status;
    status = qpc.validate();
    if (!status.ok()) return status;
    status = message.validate();
    if (!status.ok()) return status;
    status = netpacket.validate();
    if (!status.ok()) return status;
    return rdma_status::success();
  endfunction
endclass

// 设计说明：flow plan 是唯一可修改入口，固定 TX/RX QP 数量、配对关系和 message/netpacket/fault
// 列表；resolver 只读取它并生成独立 snapshot，不把两个方向的 QP 合并。
class rdma_flow_plan extends rdma_flow_profile_base;
  `rdma_object_utils(rdma_flow_plan)

  rdma_flow_link_mode_e link_mode;
  int unsigned tx_qp_count;
  int unsigned rx_qp_count;
  int tx_rx_pair[$];
  rdma_qp_profile tx_qps[$];
  rdma_qp_profile rx_qps[$];
  rdma_qpc_profile qpcs[$];
  rdma_hmc_profile hmcs[$];
  rdma_message_profile messages[$];
  rdma_netpacket_profile netpackets[$];
  rdma_endpoint_profile endpoints[$];
  rdma_fault_profile faults[$];
  bit allow_invalid_faults;

  // 功能：构造空 flow plan，默认 managed link，TX/RX QP 数均为零。
  // 输入/输出及副作用：清空所有 profile 列表与配对表；不创建下层资源。
  // 失败/边界：resolver 要求 TX/RX 数量与列表长度一致，空 plan 不能产生可运行 snapshot。
  function new(string name = "rdma_flow_plan");
    super.new(name);
    link_mode = RDMA_FLOW_MANAGED_LINK;
    tx_qp_count = 0;
    rx_qp_count = 0;
    tx_rx_pair.delete();
    tx_qps.delete();
    rx_qps.delete();
    qpcs.delete();
    hmcs.delete();
    messages.delete();
    netpackets.delete();
    endpoints.delete();
    faults.delete();
    allow_invalid_faults = 1'b0;
  endfunction

  // 功能：校验 plan 的方向数量、QP profile 列表、配对索引与嵌套 profile 句柄。
  // 输入/输出及副作用：只读 plan；返回首个失败状态。
  // 失败/边界：空方向、数量/列表不一致、null/重复 QP index、越界 peer 或未冻结 profile 均拒绝。
  virtual function rdma_status validate();
    rdma_status s;
    bit seen_tx[int unsigned];
    bit seen_rx[int unsigned];
    s = super.validate();
    if (!s.ok()) return s;
    if (tx_qp_count == 0 || rx_qp_count == 0 || tx_qps.size() != tx_qp_count ||
        rx_qps.size() != rx_qp_count)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flow plan QP counts do not match lists");
    foreach (tx_qps[i]) begin
      if (tx_qps[i] == null || seen_tx.exists(tx_qps[i].index))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flow plan TX QP is null or duplicated");
      seen_tx[tx_qps[i].index] = 1'b1;
    end
    foreach (rx_qps[i]) begin
      if (rx_qps[i] == null || seen_rx.exists(rx_qps[i].index))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flow plan RX QP is null or duplicated");
      seen_rx[rx_qps[i].index] = 1'b1;
    end
    foreach (tx_rx_pair[i])
      if (tx_rx_pair[i] < 0 || tx_rx_pair[i] >= int'(rx_qp_count))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flow plan peer index is out of range");
    foreach (messages[i])
      if (messages[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flow plan message is null");
    foreach (faults[i])
      if (faults[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flow plan fault is null");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 设计说明：顶层 resolved config 只保存 detached snapshot 和发布身份；freeze 后不能通过普通 API
// 再次替换数组。对象字段仍公开以兼容现有 UVM value model，消费者必须把 frozen 作为准入条件。
class rdma_resolved_config extends uvm_object;
  `rdma_object_utils(rdma_resolved_config)

  string source_id;
  longint unsigned reset_epoch;
  bit frozen;
  rdma_qp_snapshot tx_qps[$];
  rdma_qp_snapshot rx_qps[$];
  rdma_qpc_snapshot qpcs[$];
  rdma_hmc_snapshot hmcs[$];
  rdma_message_snapshot messages[$];
  rdma_netpacket_snapshot netpackets[$];
  rdma_endpoint_snapshot endpoints[$];
  rdma_fault_snapshot faults[$];

  // 功能：构造空 resolved config；数组独立且未冻结。
  // 输入/输出及副作用：name 传给 UVM；source_id/epoch 清零，所有 snapshot 列表为空。
  // 失败/边界：空对象不是可消费配置，resolver 必须完成填充和 freeze。
  function new(string name = "rdma_resolved_config");
    super.new(name);
    source_id = "";
    reset_epoch = '0;
    frozen = 1'b0;
    tx_qps.delete(); rx_qps.delete(); qpcs.delete(); hmcs.delete();
    messages.delete(); netpackets.delete(); endpoints.delete(); faults.delete();
  endfunction

  // 功能：冻结 resolved config 的顶层发布状态与全部子 snapshot。
  // 输入/输出及副作用：设置 frozen=1，并逐项调用子 snapshot freeze；返回是否全部非空。
  // 失败/边界：发现 null 子项返回 0 且顶层保持未冻结；重复调用幂等。
  function bit freeze();
    if (source_id == "" || reset_epoch == 0)
      return 1'b0;
    foreach (tx_qps[i]) if (tx_qps[i] == null) return 1'b0; else void'(tx_qps[i].freeze());
    foreach (rx_qps[i]) if (rx_qps[i] == null) return 1'b0; else void'(rx_qps[i].freeze());
    foreach (qpcs[i]) if (qpcs[i] == null) return 1'b0; else void'(qpcs[i].freeze());
    foreach (hmcs[i]) if (hmcs[i] == null) return 1'b0; else void'(hmcs[i].freeze());
    foreach (messages[i]) if (messages[i] == null) return 1'b0; else void'(messages[i].freeze());
    foreach (netpackets[i]) if (netpackets[i] == null) return 1'b0; else void'(netpackets[i].freeze());
    foreach (endpoints[i]) if (endpoints[i] == null) return 1'b0; else void'(endpoints[i].freeze());
    foreach (faults[i]) if (faults[i] == null) return 1'b0; else void'(faults[i].freeze());
    frozen = 1'b1;
    return 1'b1;
  endfunction

  // 功能：校验顶层发布身份、数量对应关系和每个子 snapshot 的合法性。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：未冻结、空 source/epoch、任一方向为空或子项 validate 失败均拒绝；TX/RX
  //   数量可以不同，配对关系由 flow plan 的 tx_rx_pair 单独约束。
  function rdma_status validate();
    rdma_status s;
    if (source_id == "" || reset_epoch == 0 || !frozen)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "resolved config is not frozen");
    if (tx_qps.size() == 0 || rx_qps.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "resolved TX/RX QP list is empty");
    foreach (tx_qps[i]) begin s = tx_qps[i].validate(); if (!s.ok()) return s; end
    foreach (rx_qps[i]) begin s = rx_qps[i].validate(); if (!s.ok()) return s; end
    foreach (qpcs[i]) begin s = qpcs[i].validate(); if (!s.ok()) return s; end
    foreach (hmcs[i]) begin s = hmcs[i].validate(); if (!s.ok()) return s; end
    foreach (messages[i]) begin s = messages[i].validate(); if (!s.ok()) return s; end
    foreach (netpackets[i]) begin s = netpackets[i].validate(); if (!s.ok()) return s; end
    foreach (endpoints[i]) begin s = endpoints[i].validate(); if (!s.ok()) return s; end
    foreach (faults[i]) begin s = faults[i].validate(); if (!s.ok()) return s; end
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass

// 设计说明：DUT link 只需要 endpoint、netpacket 和 fault 的冻结视图及 reset epoch；它不持有
// driver/dev/env。resolver 生成该轻量 snapshot 后，link 通过 route/epoch 校验再开始收发。
class rdma_dut_link_snapshot extends uvm_object;
  `rdma_object_utils(rdma_dut_link_snapshot)

  string source_id;
  longint unsigned reset_epoch;
  bit frozen;
  // 编码路径使用的发送方向快照；它们与 netpacket 共用 source_id/reset_epoch，均为非拥有引用。
  rdma_qp_snapshot qp;
  rdma_qpc_snapshot qpc;
  rdma_message_snapshot message;
  rdma_endpoint_snapshot endpoint;
  rdma_netpacket_snapshot netpacket;
  // 多 QP/multi-message flow 的完整路由表；上面的单数成员保留给旧调用者作为首路由兼容视图。
  rdma_dut_link_route_snapshot routes[$];
  rdma_fault_snapshot faults[$];
  bit [47:0] dut_mac;
  int unsigned dut_port;

  // 功能：构造空 DUT link snapshot，不创建 endpoint 或网络资源。
  // 输入/输出及副作用：清空 endpoint/netpacket/fault 引用，身份和端口置零。
  // 失败/边界：必须由 resolver 绑定 endpoint snapshot 并 freeze 后才能交给 link。
  function new(string name = "rdma_dut_link_snapshot");
    super.new(name);
    source_id = "";
    reset_epoch = '0;
    frozen = 1'b0;
    qp = null;
    qpc = null;
    message = null;
    endpoint = null;
    netpacket = null;
    routes.delete();
    faults.delete();
    dut_mac = '0;
    dut_port = '0;
  endfunction

  // 功能：冻结 link snapshot 及其 endpoint/netpacket/fault 子值。
  // 输入/输出及副作用：设置 frozen=1；子对象由本对象引用但不取得外部 endpoint 生命周期。
  // 失败/边界：source/epoch、endpoint/netpacket 缺失或 fault 为 null 时返回 0。
  function bit freeze();
    if (source_id == "" || reset_epoch == 0 || endpoint == null)
      return 1'b0;
    // 兼容手工构造 route 表：单数兼容视图缺失时从首路由补齐；空 route 表仍要求旧字段完整。
    if ((qp == null || qpc == null || message == null || netpacket == null) &&
        routes.size() != 0) begin
      qp = routes[0].qp;
      qpc = routes[0].qpc;
      message = routes[0].message;
      netpacket = routes[0].netpacket;
    end
    if (qp == null || qpc == null || message == null || netpacket == null)
      return 1'b0;
    void'(qp.freeze());
    void'(qpc.freeze());
    void'(message.freeze());
    void'(endpoint.freeze());
    void'(netpacket.freeze());
    foreach (routes[i]) begin
      if (routes[i] == null || !routes[i].freeze())
        return 1'b0;
    end
    foreach (faults[i]) begin
      if (faults[i] == null) return 1'b0;
      void'(faults[i].freeze());
    end
    dut_mac = endpoint.dut_mac;
    dut_port = endpoint.dut_port;
    frozen = 1'b1;
    return 1'b1;
  endfunction

  // 功能：校验 link snapshot 可由 DUT link 消费。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：未冻结、epoch/route 不一致、子 snapshot 非法均拒绝；不检查外部 endpoint 当前状态。
  function rdma_status validate();
    rdma_status s;
    if (!frozen || source_id == "" || reset_epoch == 0 || qp == null || qpc == null ||
        message == null || endpoint == null || netpacket == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "DUT link snapshot is incomplete");
    if (qp.source_id != source_id || qpc.source_id != source_id || message.source_id != source_id ||
        netpacket.source_id != source_id || endpoint.source_id != source_id ||
        qp.reset_epoch != reset_epoch || qpc.reset_epoch != reset_epoch ||
        message.reset_epoch != reset_epoch || netpacket.reset_epoch != reset_epoch ||
        endpoint.reset_epoch != reset_epoch)
      return rdma_status::make(RDMA_SC_STALE_GENERATION, "DUT link child snapshot epoch conflicts");
    s = qp.validate(); if (!s.ok()) return s;
    s = qpc.validate(); if (!s.ok()) return s;
    s = message.validate(); if (!s.ok()) return s;
    s = endpoint.validate(); if (!s.ok()) return s;
    s = netpacket.validate(); if (!s.ok()) return s;
    foreach (faults[i]) begin
      if (faults[i] == null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null link fault");
      s = faults[i].validate(); if (!s.ok()) return s;
    end
    if (dut_mac != endpoint.dut_mac || dut_port != endpoint.dut_port)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "DUT route does not match endpoint snapshot");
    foreach (routes[i]) begin
      if (routes[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null DUT route snapshot");
      s = routes[i].validate();
      if (!s.ok()) return s;
    end
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction
endclass
