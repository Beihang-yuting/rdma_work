// 目录/层次：协议与资源模型层 model/rdma_semantic_requests.sv。
// 职责：定义语义层的 QP 状态/WR/网络/CMQ opcode 枚举，以及各类资源与收发请求的值对象及 validate/do_copy。
// 依赖：依赖 rdma_status、rdma_handle、queue backing 与 QPC 模型；不访问硬件或外部资源。
// 所有权与生命周期：请求对象拥有自身字段与深拷贝的嵌套快照；句柄只表示资源身份，不接管资源。

typedef class rdma_address_vector;
typedef class rdma_qpc_behavior;
typedef class rdma_qpc_transport_ext;
typedef class rdma_qpc_urc_ext;

typedef enum bit [3:0] {
  RDMA_QPS_RESET = 4'd0,
  RDMA_QPS_INIT  = 4'd1,
  RDMA_QPS_RTR   = 4'd2,
  RDMA_QPS_RTS   = 4'd3,
  RDMA_QPS_SQD   = 4'd4,
  RDMA_QPS_SQE   = 4'd5,
  RDMA_QPS_ERROR = 4'd6
} rdma_qp_state_e;

typedef enum bit [4:0] {
  RDMA_WR_SEND            = 5'd0,
  RDMA_WR_SEND_WITH_IMM   = 5'd1,
  RDMA_WR_RDMA_WRITE      = 5'd2,
  RDMA_WR_WRITE_WITH_IMM  = 5'd3,
  RDMA_WR_RDMA_READ       = 5'd4,
  RDMA_WR_ATOMIC_CMP_SWAP = 5'd5,
  RDMA_WR_ATOMIC_FETCH_ADD= 5'd6,
  RDMA_WR_LOCAL_INVALIDATE= 5'd7,
  RDMA_WR_RECV            = 5'd8,
  RDMA_WR_SEND_WITH_INV   = 5'd9,
  RDMA_WR_REG_MR          = 5'd10,
  RDMA_WR_BIND_MW         = 5'd11,
  RDMA_WR_FLUSH           = 5'd12
} rdma_work_opcode_e;

typedef enum bit [1:0] {
  RDMA_TIMEOUT_NONE   = 2'd0,
  RDMA_TIMEOUT_CYCLES = 2'd1,
  RDMA_TIMEOUT_TIME   = 2'd2
} rdma_timeout_policy_e;

typedef enum bit [4:0] {
  RDMA_NET_SEND             = 5'd0,
  RDMA_NET_SEND_WITH_IMM    = 5'd1,
  RDMA_NET_RDMA_WRITE       = 5'd2,
  RDMA_NET_WRITE_WITH_IMM   = 5'd3,
  RDMA_NET_RDMA_READ_REQUEST= 5'd4,
  RDMA_NET_RDMA_READ_RESP   = 5'd5,
  RDMA_NET_ACK              = 5'd6,
  RDMA_NET_NAK              = 5'd7,
  // RC 原子请求使用 RoCEv2 AtomicETH；保留独立语义值，禁止降级为 SEND。
  RDMA_NET_ATOMIC_CMP_SWAP  = 5'd8,
  RDMA_NET_ATOMIC_FETCH_ADD = 5'd9,
  // RC 原子响应携带 Atomic ACK ETH 的原始值，供 responder 完成语义闭环。
  RDMA_NET_ATOMIC_ACK       = 5'd10
} rdma_network_opcode_e;

// 多包消息中报文的位置；单包消息为 ONLY。与 opcode 组合决定 BTH opcode 与扩展头。
typedef enum bit [1:0] {
  RDMA_SEG_ONLY   = 2'd0,
  RDMA_SEG_FIRST  = 2'd1,
  RDMA_SEG_MIDDLE = 2'd2,
  RDMA_SEG_LAST   = 2'd3
} rdma_packet_segment_e;

// AETH syndrome：0x00 为 ACK；0x60|code 为 NAK，code 3 表示 remote access error。
localparam bit [7:0] RDMA_AETH_ACK = 8'h00;
localparam bit [7:0] RDMA_AETH_NAK_REMOTE_ACCESS = 8'h62;
// RNR NAK（timer 字段取 0）。
localparam bit [7:0] RDMA_AETH_RNR_NAK = 8'h20;
localparam bit [7:0] RDMA_AETH_NAK_INVALID_REQUEST = 8'h61;

typedef enum bit [5:0] {
  RDMA_CMQ_CREATE_PD  = 6'd0,
  RDMA_CMQ_REGISTER_MR= 6'd1,
  RDMA_CMQ_CREATE_CQ  = 6'd2,
  RDMA_CMQ_CREATE_QP  = 6'd3,
  RDMA_CMQ_CREATE_SRQ = 6'd4,
  RDMA_CMQ_CREATE_CEQ = 6'd5,
  RDMA_CMQ_CREATE_AEQ = 6'd6,
  RDMA_CMQ_DESTROY    = 6'd7,
  RDMA_CMQ_MODIFY_QP  = 6'd8,
  RDMA_CMQ_QUERY      = 6'd9
} rdma_cmq_opcode_e;

// 功能：判断 value 是否为非零的 2 的幂（队列深度、SGE 数量）。
// 输入/输出及副作用：value 为输入；返回 bit。
// 失败/边界：0 返回 0。
function automatic bit rdma_is_power_of_two(int unsigned value);
  return value != 0 && (value & (value - 1'b1)) == 0;
endfunction

// 功能：判断 work opcode 对指定 transport 是否合法（RC 最全，UD 仅 SEND 族，URC 无原子/MR 注册等）。
// 输入/输出及副作用：transport、opcode 为输入；返回 bit。
// 失败/边界：不在该 transport 允许集合内或 transport 未知返回 0。
function automatic bit rdma_send_opcode_valid_for_transport(
  rdma_transport_e transport,
  rdma_work_opcode_e opcode
);
  case (transport)
    RDMA_TRANSPORT_RC:
      return opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                            RDMA_WR_SEND_WITH_INV,
                            RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                            RDMA_WR_RDMA_READ, RDMA_WR_ATOMIC_CMP_SWAP,
                            RDMA_WR_ATOMIC_FETCH_ADD,
                            RDMA_WR_LOCAL_INVALIDATE,
                            RDMA_WR_REG_MR, RDMA_WR_BIND_MW, RDMA_WR_FLUSH};
    RDMA_TRANSPORT_UD:
      return opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                            RDMA_WR_SEND_WITH_INV};
    RDMA_TRANSPORT_URC:
      return opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                            RDMA_WR_SEND_WITH_INV,
                            RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                            RDMA_WR_RDMA_READ,
                            RDMA_WR_LOCAL_INVALIDATE};
    default:
      return 1'b0;
  endcase
endfunction

class rdma_sge extends uvm_object;
  `rdma_object_utils(rdma_sge)

  rdma_iova_t iova;
  int unsigned length;
  bit [31:0] lkey;

  // 功能：构造SGE，iova/length/lkey 清零。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_sge");
    super.new(name);
    iova = '0;
    length = '0;
    lkey = '0;
  endfunction

  // 功能：复制SGE的值字段。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（rdma_sge copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_sge rhs_sge;

    super.do_copy(rhs);
    if (!$cast(rhs_sge, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_sge copy type mismatch")
    iova = rhs_sge.iova;
    length = rhs_sge.length;
    lkey = rhs_sge.lkey;
  endfunction

  // 功能：按值复制为新的 SGE，供请求/WQE 模型复制 SGE 列表。
  // 输入/输出及副作用：返回新对象，源不变。
  // 失败/边界：不经 uvm_object::copy——UVM 1.2 在嵌套 copy 中按源对象记录 global copy map，同一 SGE
  //   在列表中出现多次（别名）时第二次 clone 会提前返回而得到全零 SGE，进而被当作零长度 SGE 丢弃。
  function rdma_sge duplicate();
    rdma_sge copy;

    copy = rdma_sge::type_id::create(get_name());
    copy.iova = iova;
    copy.length = length;
    copy.lkey = lkey;
    return copy;
  endfunction
endclass

class rdma_semantic_request extends uvm_object;
  `rdma_object_utils(rdma_semantic_request)

  longint unsigned request_id;
  longint unsigned correlation_id;
  rdma_function_handle owner;
  rdma_status_code_e expected_status_code;
  rdma_timeout_policy_e timeout_policy;
  longint unsigned timeout_value;

  // 功能：构造语义请求基类，无 owner、期望状态 OK、无超时。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_semantic_request");
    super.new(name);
    request_id = '0;
    correlation_id = '0;
    owner = null;
    expected_status_code = RDMA_SC_OK;
    timeout_policy = RDMA_TIMEOUT_NONE;
    timeout_value = '0;
  endfunction

  // 功能：复制语义请求基类的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 ID、期望状态、超时字段，深拷贝 owner。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（semantic request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_semantic_request rhs_req;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "semantic request copy type mismatch")
    request_id = rhs_req.request_id;
    correlation_id = rhs_req.correlation_id;
    expected_status_code = rhs_req.expected_status_code;
    timeout_policy = rhs_req.timeout_policy;
    timeout_value = rhs_req.timeout_value;
    owner = rdma_deep_copy#(rdma_function_handle)::of(
      rhs_req.owner, "function handle clone type mismatch");
  endfunction

  // 功能：校验超时策略。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：策略非法，或策略非 NONE 而 timeout_value 为 0 返回 INVALID_ARGUMENT。
  virtual function rdma_status validate();
    if (!(timeout_policy inside {RDMA_TIMEOUT_NONE,
                                 RDMA_TIMEOUT_CYCLES,
                                 RDMA_TIMEOUT_TIME}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "timeout policy is invalid");
    if (timeout_policy != RDMA_TIMEOUT_NONE && timeout_value == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "selected timeout policy has zero value");
    return rdma_status::success();
  endfunction

endclass

class rdma_post_send_req extends rdma_semantic_request;
  `rdma_object_utils(rdma_post_send_req)

  rdma_handle qp_h;
  longint unsigned wr_id;
  rdma_transport_e transport;
  rdma_work_opcode_e opcode;
  rdma_sge sges[$];
  bit inline_data;
  byte unsigned payload[$];
  bit signaled;
  bit solicited;
  bit [31:0] immediate_data;
  rdma_iova_t remote_addr;
  bit [31:0] rkey;
  bit remote_access_valid;
  bit rkey_valid;
  bit [23:0] destination_qpn;
  bit [31:0] qkey;
  bit [31:0] invalidate_rkey;
  rdma_handle completion_qp_h;
  rdma_handle mr_h;
  rdma_handle mw_h;
  rdma_handle authority_h;
  int unsigned address_vector_id;
  rdma_address_vector address_vector;
  bit fence;
  bit address_vector_valid;
  rdma_iova_t sgb_iova;
  longint unsigned compare_value;
  longint unsigned swap_add_value;

  // 功能：构造post-send 请求，默认 RC、SEND，各 valid 位清零。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_post_send_req");
    super.new(name);
    qp_h = null;
    wr_id = '0;
    transport = RDMA_TRANSPORT_RC;
    opcode = RDMA_WR_SEND;
    inline_data = 1'b0;
    signaled = 1'b0;
    solicited = 1'b0;
    immediate_data = '0;
    remote_addr = '0;
    rkey = '0;
    remote_access_valid = 1'b0;
    rkey_valid = 1'b0;
    destination_qpn = '0;
    qkey = '0;
    invalidate_rkey = '0;
    completion_qp_h = null;
    mr_h = null;
    mw_h = null;
    authority_h = null;
    address_vector_id = '0;
    address_vector = null; fence = 0;
    address_vector_valid = 1'b0;
    sgb_iova = '0;
    compare_value = '0;
    swap_add_value = '0;
  endfunction

  // 功能：复制post-send 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；深拷贝 QP/completion QP/MR/MW/authority 句柄与 SGE，覆盖其余标量与 payload。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（post-send request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_post_send_req rhs_req;
    rdma_sge cloned_sge;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "post-send request copy type mismatch")
    qp_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.qp_h, "QP handle clone type mismatch");
    wr_id = rhs_req.wr_id;
    transport = rhs_req.transport;
    opcode = rhs_req.opcode;
    inline_data = rhs_req.inline_data;
    payload = rhs_req.payload;
    signaled = rhs_req.signaled;
    solicited = rhs_req.solicited;
    immediate_data = rhs_req.immediate_data;
    remote_addr = rhs_req.remote_addr;
    rkey = rhs_req.rkey;
    remote_access_valid = rhs_req.remote_access_valid;
    rkey_valid = rhs_req.rkey_valid;
    destination_qpn = rhs_req.destination_qpn;
    qkey = rhs_req.qkey;
    invalidate_rkey = rhs_req.invalidate_rkey;
    completion_qp_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.completion_qp_h, "completion QP clone failure");
    mr_h = rdma_deep_copy#(rdma_handle)::of(rhs_req.mr_h, "MR clone failure");
    mw_h = rdma_deep_copy#(rdma_handle)::of(rhs_req.mw_h, "MW clone failure");
    authority_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.authority_h, "authority clone failure");
    address_vector_id = rhs_req.address_vector_id;
    fence = rhs_req.fence;
    address_vector = rdma_deep_copy#(rdma_address_vector)::of(
      rhs_req.address_vector, "AV clone failure");
    address_vector_valid = rhs_req.address_vector_valid;
    sgb_iova = rhs_req.sgb_iova;
    compare_value = rhs_req.compare_value;
    swap_add_value = rhs_req.swap_add_value;
    sges.delete();
    foreach (rhs_req.sges[i]) begin
      if (rhs_req.sges[i] == null) begin
        sges.push_back(null);
      end
      else begin
        cloned_sge = rhs_req.sges[i].duplicate();
        sges.push_back(cloned_sge);
      end
    end
  endfunction

  // 功能：校验 post-send 请求的 QP/owner authority、transport、opcode、控制面字段与 SGE/payload 形状。
  // 输入/输出及副作用：只读 qp_h、owner、completion_qp_h、mr_h、mw_h、authority_h、transport、opcode、sges、payload；
  //   返回 status，不取得句柄所有权。
  // 失败/边界：kind/UID/generation 不一致、URC 缺 completion QP、control WQE payload 非空、SGE 为空或超过 32、
  //   FLUSH authority 失效等返回对应错误；普通 SEND/WRITE 的零 SGE、零长度 SGE 与 zero-byte inline 按驱动规则允许。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "post-send target is not a QP handle");
    // 请求 owner 是可选的 codec 元数据；一旦提供，发送 QP 必须属于同一 Function incarnation，
    // 避免调用方把完整但跨代的句柄混入 SQE。
    if (owner != null) begin
      status = rdma_handle_authority_status(qp_h, RDMA_RESOURCE_QP, owner,
                                            "post-send QP");
      if (!status.ok()) return status;
    end
    if (!rdma_send_opcode_valid_for_transport(transport, opcode))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "work opcode is invalid for transport");
    // 驱动先按原始 ib_send_wr->num_sge 检查硬件 32 项上限，再由各 WQE 编码路径过滤零长度条目；
    // 因此必须在此保留原始数组边界，否则 33 项（即使尾项长度为零）会越过驱动请求边界。
    if (sges.size() > RDMA_MAX_WQ_SGE)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "send SGE count exceeds driver limit of 32");
    if (opcode == RDMA_WR_LOCAL_INVALIDATE) begin
      if (inline_data || sges.size() != 0 || payload.size() != 0 || !rkey_valid)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "local invalidate shape or rkey is invalid");
    end
    else if (opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                            RDMA_WR_ATOMIC_FETCH_ADD}) begin
      if (inline_data || payload.size() != 0 || sges.size() != 1)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic send shape is invalid");
      if (sges[0] == null || sges[0].length != 8)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic send requires one 8-byte SGE");
      if ((sges[0].iova.value & 64'h7) != 0 ||
          (remote_addr.value & 64'h7) != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic send address is not 8-byte aligned");
    end
    else if (opcode == RDMA_WR_RDMA_READ) begin
      if (inline_data || payload.size() != 0 || sges.size() == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RDMA read shape is invalid");
      foreach (sges[i]) begin
        if (sges[i] == null || sges[i].length == 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "read SGE is null or has zero length");
      end
    end
    else if (opcode inside {RDMA_WR_REG_MR, RDMA_WR_BIND_MW, RDMA_WR_FLUSH}) begin
      if (sges.size() != 0 || payload.size() != 0 || inline_data)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "control WQE carries payload");
      if (opcode == RDMA_WR_REG_MR) begin
        status = rdma_handle_authority_status(
          mr_h, RDMA_RESOURCE_MR, owner == null ? qp_h : owner,
          "REG_MR authority");
        if (!status.ok()) return status;
      end
      if (opcode == RDMA_WR_BIND_MW) begin
        status = rdma_handle_authority_status(
          mr_h, RDMA_RESOURCE_MR, owner == null ? qp_h : owner,
          "BIND_MW MR authority");
        if (!status.ok()) return status;
        status = rdma_handle_authority_status(
          mw_h, RDMA_RESOURCE_MW, owner == null ? qp_h : owner,
          "BIND_MW MW authority");
        if (!status.ok()) return status;
      end
      if (opcode == RDMA_WR_FLUSH) begin
        status = rdma_handle_authority_status(
          authority_h, RDMA_RESOURCE_QP, owner == null ? qp_h : owner,
          "FLUSH authority");
        if (!status.ok()) return status;
        if (!authority_h.same_instance(qp_h))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "FLUSH authority is detached from the posting QP"
          );
      end
    end
    else begin
      // 驱动 wr.c 允许无有效 payload 的普通 SEND/WRITE WQE：num_sge 可为 0，零长度 SGE 在写入描述符
      // 计数前被丢弃。因此请求层只检查描述符归属，有效计数与长度由 codec 按非零条目计算。
      foreach (sges[i]) begin
        if (sges[i] == null)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "send SGE handle is null");
      end
    end
    if (opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                       RDMA_WR_RDMA_READ, RDMA_WR_ATOMIC_CMP_SWAP,
                       RDMA_WR_ATOMIC_FETCH_ADD}) begin
      if (!remote_access_valid || !rkey_valid)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "remote operation lacks address or rkey");
    end
    if (transport == RDMA_TRANSPORT_UD &&
        (destination_qpn == 0 || qkey == 0 || !address_vector_valid))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD send lacks destination QPN, qkey, or AV");
    if (transport == RDMA_TRANSPORT_UD &&
        (remote_access_valid || rkey_valid || remote_addr.value != 0))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD send carries RC-only remote fields");
    if (transport == RDMA_TRANSPORT_URC) begin
      status = rdma_handle_authority_status(
        completion_qp_h, RDMA_RESOURCE_QP, owner == null ? qp_h : owner,
        "URC completion QP");
      if (!status.ok()) return status;
    end
    else if (completion_qp_h != null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "completion QP is only valid for URC send"
      );
    return rdma_status::success();
  endfunction
endclass

class rdma_packet extends uvm_object;
  `rdma_object_utils(rdma_packet)

  rdma_transport_e transport;
  rdma_network_opcode_e opcode;
  rdma_packet_segment_e segment;
  bit [23:0] destination_qpn;
  bit [23:0] source_qpn;
  bit [23:0] psn;
  // header_bytes 是 BTH 之后扩展头的线上字节（IBTA 顺序：RETH、AETH、AtomicETH、
  //   AtomicAckETH、ImmDt），由 pack_headers()/unpack_headers() 与下列结构化字段互转。
  byte unsigned header_bytes[$];
  bit [63:0] reth_va;
  bit [31:0] reth_rkey;
  bit [31:0] reth_len;
  bit [7:0] aeth_syndrome;
  bit [23:0] aeth_msn;
  bit [31:0] imm;
  bit [63:0] atomic_va;
  bit [31:0] atomic_rkey;
  bit [63:0] atomic_swap_add;
  bit [63:0] atomic_compare;
  bit [63:0] atomic_orig;
  string metadata[$];
  byte unsigned payload[$];

  // 功能：构造网络包，默认 RC、SEND、ONLY，QPN/PSN 与扩展头清零。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_packet");
    super.new(name);
    transport = RDMA_TRANSPORT_RC;
    opcode = RDMA_NET_SEND;
    segment = RDMA_SEG_ONLY;
    destination_qpn = '0;
    source_qpn = '0;
    psn = '0;
    reth_va = '0;
    reth_rkey = '0;
    reth_len = '0;
    aeth_syndrome = '0;
    aeth_msn = '0;
    imm = '0;
    atomic_va = '0;
    atomic_rkey = '0;
    atomic_swap_add = '0;
    atomic_compare = '0;
    atomic_orig = '0;
  endfunction

  // 功能：判断报文是否携带 RETH（WRITE 首/单包与 READ 请求）。
  // 输入/输出及副作用：只读 opcode/segment。
  // 失败/边界：无。
  function bit has_reth();
    return (opcode inside {RDMA_NET_RDMA_WRITE, RDMA_NET_WRITE_WITH_IMM} &&
            segment inside {RDMA_SEG_FIRST, RDMA_SEG_ONLY}) ||
           opcode == RDMA_NET_RDMA_READ_REQUEST;
  endfunction

  // 功能：判断报文是否携带 AETH（READ 响应首/尾/单包、ACK/NAK、ATOMIC ACK）。
  // 输入/输出及副作用：只读 opcode/segment。
  // 失败/边界：无。
  function bit has_aeth();
    return (opcode == RDMA_NET_RDMA_READ_RESP && segment != RDMA_SEG_MIDDLE) ||
           opcode inside {RDMA_NET_ACK, RDMA_NET_NAK, RDMA_NET_ATOMIC_ACK};
  endfunction

  // 功能：判断报文是否携带 AtomicETH（CMP_SWAP/FETCH_ADD 请求）。
  // 输入/输出及副作用：只读 opcode。
  // 失败/边界：无。
  function bit has_atomic_eth();
    return opcode inside {RDMA_NET_ATOMIC_CMP_SWAP, RDMA_NET_ATOMIC_FETCH_ADD};
  endfunction

  // 功能：判断报文是否携带 ImmDt（带立即数的 SEND/WRITE 尾包或单包）。
  // 输入/输出及副作用：只读 opcode/segment。
  // 失败/边界：无。
  function bit has_immdt();
    return opcode inside {RDMA_NET_SEND_WITH_IMM, RDMA_NET_WRITE_WITH_IMM} &&
           segment inside {RDMA_SEG_LAST, RDMA_SEG_ONLY};
  endfunction

  // 功能：按 opcode/segment 计算扩展头总长度（与 pack_headers 一致）。
  // 输入/输出及副作用：只读 opcode/segment。
  // 失败/边界：无。
  function int unsigned header_length();
    int unsigned n;

    n = 0;
    if (has_reth())
      n += 16;
    if (has_aeth())
      n += 4;
    if (has_atomic_eth())
      n += 28;
    if (opcode == RDMA_NET_ATOMIC_ACK)
      n += 8;
    if (has_immdt())
      n += 4;
    return n;
  endfunction

  // 功能：按 IBTA 顺序把结构化扩展头序列化为 header_bytes（大端）。
  // 输入/输出及副作用：覆盖 header_bytes。
  // 失败/边界：无；不携带的头不输出。
  function void pack_headers();
    header_bytes.delete();
    if (has_reth()) begin
      put_be(reth_va, 8);
      put_be(reth_rkey, 4);
      put_be(reth_len, 4);
    end
    if (has_aeth())
      put_be({aeth_syndrome, aeth_msn}, 4);
    if (has_atomic_eth()) begin
      put_be(atomic_va, 8);
      put_be(atomic_rkey, 4);
      put_be(atomic_swap_add, 8);
      put_be(atomic_compare, 8);
    end
    if (opcode == RDMA_NET_ATOMIC_ACK)
      put_be(atomic_orig, 8);
    if (has_immdt())
      put_be(imm, 4);
  endfunction

  // 功能：从 header_bytes 解析结构化扩展头。
  // 输入/输出及副作用：写入 reth/aeth/atomic/imm 字段。
  // 失败/边界：字节不足时返回 0，已解析字段保持部分更新。
  function bit unpack_headers();
    int unsigned offset;
    bit [63:0] v;

    offset = 0;
    if (has_reth()) begin
      if (!get_be(offset, 8, v))
        return 1'b0;
      reth_va = v;
      if (!get_be(offset, 4, v))
        return 1'b0;
      reth_rkey = v[31:0];
      if (!get_be(offset, 4, v))
        return 1'b0;
      reth_len = v[31:0];
    end
    if (has_aeth()) begin
      if (!get_be(offset, 4, v))
        return 1'b0;
      aeth_syndrome = v[31:24];
      aeth_msn = v[23:0];
    end
    if (has_atomic_eth()) begin
      if (!get_be(offset, 8, v))
        return 1'b0;
      atomic_va = v;
      if (!get_be(offset, 4, v))
        return 1'b0;
      atomic_rkey = v[31:0];
      if (!get_be(offset, 8, v))
        return 1'b0;
      atomic_swap_add = v;
      if (!get_be(offset, 8, v))
        return 1'b0;
      atomic_compare = v;
    end
    if (opcode == RDMA_NET_ATOMIC_ACK) begin
      if (!get_be(offset, 8, v))
        return 1'b0;
      atomic_orig = v;
    end
    if (has_immdt()) begin
      if (!get_be(offset, 4, v))
        return 1'b0;
      imm = v[31:0];
    end
    return 1'b1;
  endfunction

  // 功能：把 value 的低 bytes 个字节按大端追加到 header_bytes。
  // 输入/输出及副作用：追加 header_bytes。
  // 失败/边界：bytes 超过 8 时只取低 8 字节。
  protected function void put_be(bit [63:0] value, int unsigned bytes);
    for (int i = int'(bytes) - 1; i >= 0; i--)
      header_bytes.push_back(value >> (8 * i));
  endfunction

  // 功能：从 header_bytes[offset] 读取 bytes 个大端字节到 value，并推进 offset。
  // 输入/输出及副作用：offset 为 inout 游标，value 输出。
  // 失败/边界：剩余字节不足时返回 0，offset 与 value 不变。
  protected function bit get_be(
    inout int unsigned offset,
    input int unsigned bytes,
    output bit [63:0] value
  );
    value = '0;
    if (offset + bytes > header_bytes.size())
      return 1'b0;
    for (int unsigned i = 0; i < bytes; i++)
      value = (value << 8) | header_bytes[offset + i];
    offset += bytes;
    return 1'b1;
  endfunction

  // 功能：复制网络包全部值字段（含扩展头、metadata、payload）。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（packet copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_packet rhs_packet;

    super.do_copy(rhs);
    if (!$cast(rhs_packet, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "packet copy type mismatch")
    transport = rhs_packet.transport;
    opcode = rhs_packet.opcode;
    segment = rhs_packet.segment;
    destination_qpn = rhs_packet.destination_qpn;
    source_qpn = rhs_packet.source_qpn;
    psn = rhs_packet.psn;
    header_bytes = rhs_packet.header_bytes;
    reth_va = rhs_packet.reth_va;
    reth_rkey = rhs_packet.reth_rkey;
    reth_len = rhs_packet.reth_len;
    aeth_syndrome = rhs_packet.aeth_syndrome;
    aeth_msn = rhs_packet.aeth_msn;
    imm = rhs_packet.imm;
    atomic_va = rhs_packet.atomic_va;
    atomic_rkey = rhs_packet.atomic_rkey;
    atomic_swap_add = rhs_packet.atomic_swap_add;
    atomic_compare = rhs_packet.atomic_compare;
    atomic_orig = rhs_packet.atomic_orig;
    metadata = rhs_packet.metadata;
    payload = rhs_packet.payload;
  endfunction
endclass

class rdma_net_response_policy extends uvm_object;
  `rdma_object_utils(rdma_net_response_policy)

  rdma_responder_mode_e responder_mode;
  int unsigned drop_every_n;
  int unsigned corrupt_every_n;
  longint unsigned delay_cycles;
  bit [31:0] deterministic_seed;

  // 功能：构造网络响应策略，默认 DUT 响应、无注入。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_net_response_policy");
    super.new(name);
    responder_mode = RDMA_RESPONDER_DUT;
    drop_every_n = '0;
    corrupt_every_n = '0;
    delay_cycles = '0;
    deterministic_seed = '0;
  endfunction

  // 功能：复制网络响应策略的值字段。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（network policy copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_net_response_policy rhs_policy;

    super.do_copy(rhs);
    if (!$cast(rhs_policy, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "network policy copy type mismatch")
    responder_mode = rhs_policy.responder_mode;
    drop_every_n = rhs_policy.drop_every_n;
    corrupt_every_n = rhs_policy.corrupt_every_n;
    delay_cycles = rhs_policy.delay_cycles;
    deterministic_seed = rhs_policy.deterministic_seed;
  endfunction
endclass

class rdma_net_fault extends uvm_object;
  `rdma_object_utils(rdma_net_fault)

  rdma_fault_kind_e kind;
  bit drop_packet;
  bit corrupt_byte;
  int unsigned corrupt_byte_index;
  byte unsigned corrupt_xor_mask;
  longint unsigned delay_cycles;
  bit [31:0] deterministic_seed;

  // 功能：构造网络故障描述，默认 PACKET_DROP 类别、各注入位清零。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_net_fault");
    super.new(name);
    kind = RDMA_FAULT_PACKET_DROP;
    drop_packet = 1'b0;
    corrupt_byte = 1'b0;
    corrupt_byte_index = '0;
    corrupt_xor_mask = '0;
    delay_cycles = '0;
    deterministic_seed = '0;
  endfunction

  // 功能：复制网络故障描述的值字段。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（network fault copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_net_fault rhs_fault;

    super.do_copy(rhs);
    if (!$cast(rhs_fault, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "network fault copy type mismatch")
    kind = rhs_fault.kind;
    drop_packet = rhs_fault.drop_packet;
    corrupt_byte = rhs_fault.corrupt_byte;
    corrupt_byte_index = rhs_fault.corrupt_byte_index;
    corrupt_xor_mask = rhs_fault.corrupt_xor_mask;
    delay_cycles = rhs_fault.delay_cycles;
    deterministic_seed = rhs_fault.deterministic_seed;
  endfunction
endclass
