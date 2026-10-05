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
  `uvm_object_utils(rdma_sge)

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
endclass

class rdma_semantic_request extends uvm_object;
  `uvm_object_utils(rdma_semantic_request)

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

class rdma_qp_context_attributes extends uvm_object;
  `uvm_object_utils(rdma_qp_context_attributes)
  int unsigned path_mtu_bytes;
  bit [15:0] pkey;
  rdma_rdma_access_t access;
  rdma_address_vector address_vector;
  bit signature_enable;
  bit tx_flow_control;
  bit rx_flow_control;
  rdma_qpc_behavior behavior;
  rdma_qpc_transport_ext transport_ext;

  // 功能：构造QP context 属性，AV/behavior/transport_ext 为空。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_qp_context_attributes");
    super.new(name);
    path_mtu_bytes = 0;
    pkey = 0;
    access = '0;
    address_vector = null;
    signature_enable = 0;
    tx_flow_control = 0;
    rx_flow_control = 0;
    behavior = null;
    transport_ext = null;
  endfunction

  // 功能：复制QP context 属性的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 MTU/pkey/access/流控字段，深拷贝 AV、behavior 与 transport_ext。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（QP attributes copy mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_qp_context_attributes r;

    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "QP attributes copy mismatch")
    path_mtu_bytes = r.path_mtu_bytes;
    pkey = r.pkey;
    access = r.access;
    signature_enable = r.signature_enable;
    tx_flow_control = r.tx_flow_control;
    rx_flow_control = r.rx_flow_control;
    address_vector = rdma_deep_copy#(rdma_address_vector)::of(
      r.address_vector, "QP AV clone failure");
    behavior = rdma_deep_copy#(rdma_qpc_behavior)::of(
      r.behavior, "QP behavior clone failure");
    transport_ext = rdma_deep_copy#(rdma_qpc_transport_ext)::of(
      r.transport_ext, "QP extension clone failure");
  endfunction

  // 功能：校验 QP context 属性及其嵌套 AV/behavior/transport 扩展与 transport 一致。
  // 输入/输出及副作用：transport 为输入；只读，嵌套 validate 的 null status 先归一化再检查；返回 status。
  // 失败/边界：MTU 为 0 或 AV/behavior/扩展为空返回 INVALID_STATE；扩展 transport 不符及嵌套校验失败返回错误。
  virtual function rdma_status validate(rdma_transport_e transport);
    rdma_status status;

    if (path_mtu_bytes == 0 || address_vector == null || behavior == null ||
        transport_ext == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP context attributes are incomplete");
    // 嵌套扩展是可覆写边界；先把 null 状态归一化再调用 ok()，避免故障扩展导致空句柄解引用。
    status = rdma_status::nonnull(
      address_vector.validate(),
      "QP address vector validation returned null status"
    );
    if (!status.ok())
      return status;

    status = rdma_status::nonnull(
      behavior.validate(),
      "QP behavior validation returned null status"
    );
    if (!status.ok())
      return status;

    if (transport_ext.transport_kind() != transport)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP transport extension does not match");

    status = rdma_status::nonnull(
      transport_ext.validate(),
      "QP transport extension validation returned null status"
    );
    if (!status.ok())
      return status;

    return rdma_status::success();
  endfunction
endclass

class rdma_create_pd_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_create_pd_req)

  // 功能：构造create PD 请求。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_create_pd_req");
    super.new(name);
  endfunction
endclass

class rdma_register_mr_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_register_mr_req)

  rdma_handle pd_h;
  rdma_iova_t iova;
  longint unsigned length;
  rdma_rdma_access_t access;

  // 功能：构造register MR 请求，pd_h/iova/长度/access 置默认。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_register_mr_req");
    super.new(name);
    pd_h = null;
    iova = '0;
    length = '0;
    access = '0;
  endfunction

  // 功能：复制register MR 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；深拷贝 pd_h，覆盖 iova、长度、access。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（register MR request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_register_mr_req rhs_req;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "register MR request copy type mismatch")
    pd_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.pd_h, "PD handle clone type mismatch");
    iova = rhs_req.iova;
    length = rhs_req.length;
    access = rhs_req.access;
  endfunction

  // 功能：校验 MR 注册请求的 PD 句柄归属与长度。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：PD 句柄非 PD kind 或长度为 0 返回 INVALID_ARGUMENT；owner 归属不符透传其错误。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (pd_h != null && pd_h.kind != RDMA_RESOURCE_PD)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR requires a PD handle");
    status = rdma_handle_owner_status(pd_h, owner);
    if (!status.ok())
      return status;
    if (length == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR length is zero");
    return rdma_status::success();
  endfunction
endclass

class rdma_create_cq_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_create_cq_req)

  int unsigned depth;
  int unsigned cqe_size_bytes;
  rdma_handle ceq_h;
  rdma_queue_backing_spec ring_backing;

  // 功能：构造create CQ 请求，默认 CQE 64 字节并创建 ring_backing。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_create_cq_req");
    super.new(name);
    depth = '0;
    cqe_size_bytes = 64;
    ceq_h = null;
    ring_backing = rdma_queue_backing_spec::type_id::create("ring_backing");
  endfunction

  // 功能：复制create CQ 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 depth、cqe 大小，克隆 ceq_h，深拷贝 ring_backing。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（create CQ request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_cq_req rhs_req;
    rdma_queue_backing_spec cloned_backing;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "create CQ request copy type mismatch")
    depth = rhs_req.depth;
    cqe_size_bytes = rhs_req.cqe_size_bytes;
    ceq_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.ceq_h, "CEQ handle clone type mismatch");
    if (rhs_req.ring_backing == null) begin
      ring_backing = null;
    end
    else begin
      cloned_backing = rdma_deep_copy#(rdma_queue_backing_spec)::of(
        rhs_req.ring_backing, "CQ ring backing clone mismatch");
      ring_backing = cloned_backing;
    end
  endfunction

  // 功能：校验 CQ 请求的 depth、CQE 大小与 ring backing。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：depth 非 2 的幂、CQE 大小非 32/64/128、ring_backing 为空或其校验失败返回 INVALID_ARGUMENT。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ depth is not a nonzero power of two");
    if (!(cqe_size_bytes inside {32, 64, 128}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ entry size is invalid");
    if (ring_backing == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ ring backing is null");
    status = rdma_status::nonnull(
      ring_backing.validate(),
      "CQ ring backing validation returned null status"
    );
    if (!status.ok())
      return status;
    return rdma_status::success();
  endfunction
endclass

// 功能：校验 QP 的 queue backing spec 与所需 role、存储字节数一致。
// 输入/输出及副作用：spec、required_role、required_storage_bytes 只读；返回 status。
// 失败/边界：spec 为空返回 INVALID_STATE；存储大小为 0 或未 4KB 对齐、owned 带 slice、borrowed 模式/role 非法、
//   覆盖非规范或未覆盖整个 ring 返回 INVALID_ARGUMENT。
function automatic rdma_status rdma_qp_backing_spec_status(
  rdma_queue_backing_spec spec,
  rdma_queue_backing_role_e required_role,
  longint unsigned required_storage_bytes
);
  rdma_status status;
  longint unsigned next_logical_offset;

  if (spec == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE, "QP backing spec is null");
  if (required_storage_bytes == 0 ||
      !rdma_queue_aligned(required_storage_bytes, 4096))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "QP backing storage size is invalid");
  if (spec.mode == RDMA_QUEUE_BACKING_OWNED) begin
    if (spec.slices.size() != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "owned QP backing contains slices");
    return rdma_status::success();
  end
  if (spec.mode != RDMA_QUEUE_BACKING_BORROWED || spec.slices.size() == 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP backing mode invalid");
  next_logical_offset = 0;
  foreach (spec.slices[i]) begin
    if (spec.slices[i] == null || spec.slices[i].role != required_role)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP borrowed backing role invalid");
    if (!rdma_queue_aligned(spec.slices[i].logical_queue_offset,
                            required_role == RDMA_QUEUE_ROLE_QP_SQ_SGB ? 512 : 4096) ||
        spec.slices[i].logical_queue_offset != next_logical_offset ||
        next_logical_offset > required_storage_bytes ||
        spec.slices[i].length >
          required_storage_bytes - next_logical_offset)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP borrowed backing coverage is not canonical");
    status = rdma_queue_queue_range_status(spec.slices[i].mapping,
      spec.slices[i].mapping_offset, spec.slices[i].length,
      required_role == RDMA_QUEUE_ROLE_QP_SQ_SGB ? 512 : 4096);
    if (!status.ok()) return status;
    next_logical_offset += spec.slices[i].length;
  end
  if (next_logical_offset != required_storage_bytes)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "QP borrowed backing does not cover the ring");
  return rdma_status::success();
endfunction

class rdma_create_qp_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_create_qp_req)

  rdma_transport_e transport;
  int unsigned sq_depth;
  int unsigned rq_depth;
  int unsigned max_send_sge;
  int unsigned max_recv_sge;
  int unsigned max_inline_data;
  rdma_handle pd_h;
  rdma_handle send_cq_h;
  rdma_handle recv_cq_h;
  rdma_handle srq_h;
  rdma_queue_backing_spec sq_backing;
  rdma_queue_backing_spec sq_sgb_backing;
  rdma_queue_backing_spec rq_backing;
  rdma_qp_context_attributes context_attrs;

  // 功能：构造create QP 请求，默认 RC、max_recv_sge=1，并创建 SQ/RQ/SQ-SGB backing 规格。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_create_qp_req");
    super.new(name);
    transport = RDMA_TRANSPORT_RC;
    sq_depth = '0;
    rq_depth = '0;
    max_send_sge = '0;
    max_recv_sge = 1;
    max_inline_data = 0;
    pd_h = null;
    send_cq_h = null;
    recv_cq_h = null;
    srq_h = null;
    sq_backing = rdma_queue_backing_spec::type_id::create("sq_backing");
    rq_backing = rdma_queue_backing_spec::type_id::create("rq_backing");
    sq_sgb_backing = rdma_queue_backing_spec::type_id::create("sq_sgb_backing");
    context_attrs = null;
  endfunction

  // 功能：复制create QP 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 transport、深度、SGE/inline，深拷贝各句柄、backing 与 context_attrs。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（create QP request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_qp_req rhs_req;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "create QP request copy type mismatch")
    transport = rhs_req.transport;
    sq_depth = rhs_req.sq_depth;
    rq_depth = rhs_req.rq_depth;
    max_send_sge = rhs_req.max_send_sge;
    max_recv_sge = rhs_req.max_recv_sge;
    max_inline_data = rhs_req.max_inline_data;
    pd_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.pd_h, "PD handle clone type mismatch");
    send_cq_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.send_cq_h, "send CQ handle clone type mismatch");
    recv_cq_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.recv_cq_h, "receive CQ handle clone type mismatch");
    srq_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.srq_h, "SRQ handle clone type mismatch");
    sq_backing = rdma_deep_copy#(rdma_queue_backing_spec)::of(
      rhs_req.sq_backing, "SQ backing clone type mismatch");
    rq_backing = rdma_deep_copy#(rdma_queue_backing_spec)::of(
      rhs_req.rq_backing, "RQ backing clone type mismatch");
    sq_sgb_backing = rdma_deep_copy#(rdma_queue_backing_spec)::of(
      rhs_req.sq_sgb_backing, "SQ SGB backing clone type mismatch");
    context_attrs = rdma_deep_copy#(rdma_qp_context_attributes)::of(
      rhs_req.context_attrs, "QP context attributes clone mismatch");
  endfunction

  // 功能：校验 QP 创建请求的 transport、深度、SGE/inline 上限、PD/CQ/SRQ 句柄与各 backing 规格。
  // 输入/输出及副作用：只读对象字段，嵌套 validate 的 null status 先归一化；返回 status。
  // 失败/边界：transport/深度/SGE/能力上限非法、SQ-SGB backing 有无与需求不符、context_attrs 为空或校验失败、
  //   句柄缺失或 kind 错误、SRQ QP 的 RQ backing 非规范空、URC 内部 backing 地址非零，均返回 INVALID_ARGUMENT。
  virtual function rdma_status validate();
    rdma_status status;
    longint unsigned sq_storage_bytes;
    longint unsigned rq_storage_bytes;

    status = super.validate();
    if (!status.ok())
      return status;
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP transport is invalid");
    if (!rdma_is_power_of_two(sq_depth) ||
        !rdma_is_power_of_two(rq_depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP depth is not a nonzero power of two");
    if (max_send_sge == 0 || max_recv_sge == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP maximum SGE count is zero");
    if (max_send_sge > 32 || max_inline_data > 512 ||
        (!rdma_qp_needs_sq_sgb(transport,max_send_sge,max_recv_sge) && max_inline_data > 32))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP capabilities exceed limits");
    if (rdma_qp_needs_sq_sgb(transport,max_send_sge,max_recv_sge)) begin
      if (sq_sgb_backing == null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "SQ SGB backing null");
      status = rdma_qp_backing_spec_status(sq_sgb_backing, RDMA_QUEUE_ROLE_QP_SQ_SGB,
                                           ((longint'(sq_depth)*512 + 4095)/4096)*4096);
      if (!status.ok()) return status;
    end
    else if (sq_sgb_backing != null && sq_sgb_backing.slices.size() != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unexpected SQ SGB backing");
    sq_storage_bytes = ((longint'(sq_depth) * 64 + 4095) / 4096) * 4096;
    rq_storage_bytes = ((longint'(rq_depth) * 64 + 4095) / 4096) * 4096;
    status = rdma_qp_backing_spec_status(sq_backing,
                                         RDMA_QUEUE_ROLE_QP_SQ_RING,
                                         sq_storage_bytes);
    if (!status.ok()) return status;
    status = rdma_qp_backing_spec_status(rq_backing,
                                         RDMA_QUEUE_ROLE_QP_RQ_RING,
                                         rq_storage_bytes);
    if (!status.ok()) return status;
    if (context_attrs == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP context attributes are null");
    status = rdma_status::nonnull(
      context_attrs.validate(transport),
      "QP context attributes validation returned null status"
    );
    if (!status.ok())
      return status;
    if (pd_h != null && pd_h.kind != RDMA_RESOURCE_PD)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP requires a PD handle");
    status = rdma_handle_owner_status(pd_h, owner);
    if (!status.ok())
      return status;
    if (send_cq_h != null && send_cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP requires send and receive CQ handles");
    status = rdma_handle_owner_status(send_cq_h, owner);
    if (!status.ok())
      return status;
    if (recv_cq_h != null && recv_cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP requires send and receive CQ handles");
    status = rdma_handle_owner_status(recv_cq_h, owner);
    if (!status.ok())
      return status;
    if (srq_h != null) begin
      if (transport != RDMA_TRANSPORT_RC ||
          rq_backing.mode != RDMA_QUEUE_BACKING_OWNED ||
          rq_backing.slices.size() != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SRQ QP requires canonical empty RQ backing");
      if (srq_h.kind != RDMA_RESOURCE_SRQ)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP SRQ handle is invalid");
      status = rdma_handle_owner_status(srq_h, owner);
      if (!status.ok())
        return status;
    end
    if (transport == RDMA_TRANSPORT_URC) begin
      rdma_qpc_urc_ext urc_ext;
      if (!$cast(urc_ext, context_attrs.transport_ext) || urc_ext.queues == null ||
          urc_ext.queues.rsq_backing.value != 0 ||
          urc_ext.queues.rdsq_backing.value != 0 ||
          urc_ext.queues.dsq_backing.value != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "URC caller internal backing address is nonzero");
    end
    return rdma_status::success();
  endfunction

  // 功能：校验使用 SRQ 的 QP 请求，其 rq_depth 与 SRQ 的权威深度一致。
  // 输入/输出及副作用：authoritative_srq_depth 为输入；先调用 validate()，返回 status。
  // 失败/边界：请求未使用 SRQ 返回 INVALID_STATE；rq_depth 与 SRQ 深度不等返回 INVALID_ARGUMENT。
  virtual function rdma_status validate_srq_depth(
    int unsigned authoritative_srq_depth
  );
    rdma_status status;

    status = rdma_status::nonnull(validate(), "QP SRQ-depth validation returned null status");
    if (!status.ok())
      return status;
    if (srq_h == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP request does not use an SRQ");
    if (rq_depth != authoritative_srq_depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP RQ depth does not match SRQ depth");
    return rdma_status::success();
  endfunction

  // 功能：按 Function 队列能力校验 QP 的 SGE 数与 SQ/RQ ring 存储字节。
  // 输入/输出及副作用：queue_caps 为输入；先调用 validate()，返回 status。
  // 失败/边界：SGE 数超过 max_wq_sge 或能力为零、ring 超出 Function/PD 能力返回 INVALID_ARGUMENT。
  virtual function rdma_status validate_queue_caps(
    rdma_queue_capabilities queue_caps
  );
    rdma_status status;
    longint unsigned sq_logical_bytes;
    longint unsigned rq_logical_bytes;
    longint unsigned sq_storage_bytes;
    longint unsigned rq_storage_bytes;

    status = rdma_status::nonnull(validate(), "QP capability validation returned null status");
    if (!status.ok())
      return status;
    if (queue_caps.max_wq_sge == 0 ||
        queue_caps.max_queue_ring_bytes == 0 ||
        max_send_sge > queue_caps.max_wq_sge ||
        max_recv_sge > queue_caps.max_wq_sge)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP SGE count exceeds Function capability");
    sq_logical_bytes = longint'(sq_depth) * 64;
    rq_logical_bytes = longint'(rq_depth) * 64;
    sq_storage_bytes = ((sq_logical_bytes + 4095) / 4096) * 4096;
    rq_storage_bytes = ((rq_logical_bytes + 4095) / 4096) * 4096;
    if (sq_storage_bytes > queue_caps.max_queue_ring_bytes ||
        rq_storage_bytes > queue_caps.max_queue_ring_bytes ||
        sq_storage_bytes > 2 * 1024 * 1024 ||
        rq_storage_bytes > 2 * 1024 * 1024)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP ring exceeds Function or PD capability");
    return rdma_status::success();
  endfunction
endclass

class rdma_create_srq_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_create_srq_req)

  int unsigned depth;
  int unsigned max_sge;
  int unsigned limit_threshold;
  rdma_handle pd_h;
  rdma_queue_backing_spec payload_backing;

  // 功能：构造create SRQ 请求，limit_threshold 默认 16 并创建 payload_backing。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_create_srq_req");
    super.new(name);
    depth = '0;
    max_sge = '0;
    limit_threshold = 16;
    pd_h = null;
    payload_backing =
      rdma_queue_backing_spec::type_id::create("payload_backing");
  endfunction

  // 功能：复制create SRQ 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 depth、max_sge、limit_threshold，克隆 pd_h，深拷贝 payload_backing。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（create SRQ request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_srq_req rhs_req;
    rdma_queue_backing_spec cloned_backing;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "create SRQ request copy type mismatch")
    depth = rhs_req.depth;
    max_sge = rhs_req.max_sge;
    limit_threshold = rhs_req.limit_threshold;
    pd_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.pd_h, "PD handle clone type mismatch");
    if (rhs_req.payload_backing == null) begin
      payload_backing = null;
    end
    else begin
      cloned_backing = rdma_deep_copy#(rdma_queue_backing_spec)::of(
        rhs_req.payload_backing, "SRQ payload backing clone mismatch");
      payload_backing = cloned_backing;
    end
  endfunction

  // 功能：校验 SRQ 请求的 depth、max_sge、limit_threshold 与 payload backing。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：depth 非 2 的幂、max_sge 为 0、limit_threshold 小于 16/大于 depth/非 4 的倍数、
  //   backing 为空或校验失败返回 INVALID_ARGUMENT。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQ depth is not a nonzero power of two");
    if (max_sge == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQ maximum SGE count is zero");
    if (limit_threshold < 16 || limit_threshold > depth ||
        limit_threshold % 4 != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQ limit threshold is invalid");
    if (payload_backing == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQ payload backing is null");
    status = rdma_status::nonnull(
      payload_backing.validate(),
      "SRQ payload backing validation returned null status"
    );
    if (!status.ok())
      return status;
    return rdma_status::success();
  endfunction
endclass

class rdma_create_ceq_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_create_ceq_req)

  int unsigned depth, vector_id;
  rdma_queue_backing_spec ring_backing;

  // 功能：构造create CEQ 请求，并创建 ring_backing。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_create_ceq_req");
    super.new(name);
    depth = '0;
    vector_id = '0;
    ring_backing = rdma_queue_backing_spec::type_id::create("ring_backing");
  endfunction

  // 功能：复制create CEQ 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 depth、vector_id，深拷贝 ring_backing。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（create CEQ request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_ceq_req rhs_req;
    rdma_queue_backing_spec cloned_backing;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "create CEQ request copy type mismatch")
    depth = rhs_req.depth;
    vector_id = rhs_req.vector_id;
    if (rhs_req.ring_backing == null) begin
      ring_backing = null;
    end
    else begin
      cloned_backing = rdma_deep_copy#(rdma_queue_backing_spec)::of(
        rhs_req.ring_backing, "CEQ ring backing clone mismatch");
      ring_backing = cloned_backing;
    end
  endfunction

  // 功能：校验 CEQ 请求的 depth 与 ring backing。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：depth 非 2 的幂、ring_backing 为空或其校验失败返回 INVALID_ARGUMENT。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQ depth is not a nonzero power of two");
    if (ring_backing == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQ ring backing is null");
    status = rdma_status::nonnull(
      ring_backing.validate(),
      "CEQ ring backing validation returned null status"
    );
    if (!status.ok())
      return status;
    return rdma_status::success();
  endfunction
endclass

class rdma_create_aeq_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_create_aeq_req)

  int unsigned depth, vector_id;
  rdma_queue_backing_spec ring_backing;

  // 功能：构造create AEQ 请求，并创建 ring_backing。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_create_aeq_req");
    super.new(name);
    depth = '0;
    vector_id = '0;
    ring_backing = rdma_queue_backing_spec::type_id::create("ring_backing");
  endfunction

  // 功能：复制create AEQ 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖 depth、vector_id，深拷贝 ring_backing。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（create AEQ request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_aeq_req rhs_req;
    rdma_queue_backing_spec cloned_backing;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "create AEQ request copy type mismatch")
    depth = rhs_req.depth;
    vector_id = rhs_req.vector_id;
    if (rhs_req.ring_backing == null) begin
      ring_backing = null;
    end
    else begin
      cloned_backing = rdma_deep_copy#(rdma_queue_backing_spec)::of(
        rhs_req.ring_backing, "AEQ ring backing clone mismatch");
      ring_backing = cloned_backing;
    end
  endfunction

  // 功能：校验 AEQ 请求的 depth 与 ring backing。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：depth 非 2 的幂、ring_backing 为空或其校验失败返回 INVALID_ARGUMENT。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQ depth is not a nonzero power of two");
    if (ring_backing == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQ ring backing is null");
    status = rdma_status::nonnull(
      ring_backing.validate(),
      "AEQ ring backing validation returned null status"
    );
    if (!status.ok())
      return status;
    return rdma_status::success();
  endfunction
endclass

class rdma_destroy_resource_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_destroy_resource_req)

  rdma_handle target_h;

  // 功能：构造destroy 请求，target_h 为空。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_destroy_resource_req");
    super.new(name);
    target_h = null;
  endfunction

  // 功能：复制destroy 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；深拷贝 target_h。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（destroy request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_destroy_resource_req rhs_req;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "destroy request copy type mismatch")
    target_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.target_h, "target handle clone type mismatch");
  endfunction

  // 功能：校验 destroy 请求的目标句柄非空。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：target_h 为空返回 INVALID_ARGUMENT。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "destroy target handle is null");
    return rdma_status::success();
  endfunction
endclass

class rdma_modify_qp_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_modify_qp_req)

  rdma_handle qp_h;
  rdma_qp_state_e new_state;
  bit [23:0] destination_qpn;
  bit [23:0] send_psn;
  bit [23:0] recv_psn;
  bit destination_qpn_valid;
  bit send_psn_valid;
  bit recv_psn_valid;

  // 功能：构造modify QP 请求，目标状态默认 RESET，各 valid 位清零。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_modify_qp_req");
    super.new(name);
    qp_h = null;
    new_state = RDMA_QPS_RESET;
    destination_qpn = '0;
    send_psn = '0;
    recv_psn = '0;
    destination_qpn_valid = 1'b0;
    send_psn_valid = 1'b0;
    recv_psn_valid = 1'b0;
  endfunction

  // 功能：复制modify QP 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；深拷贝 qp_h，覆盖目标状态、QPN、PSN 及对应 valid 位。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（modify QP request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_modify_qp_req rhs_req;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "modify QP request copy type mismatch")
    qp_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.qp_h, "QP handle clone type mismatch");
    new_state = rhs_req.new_state;
    destination_qpn = rhs_req.destination_qpn;
    send_psn = rhs_req.send_psn;
    recv_psn = rhs_req.recv_psn;
    destination_qpn_valid = rhs_req.destination_qpn_valid;
    send_psn_valid = rhs_req.send_psn_valid;
    recv_psn_valid = rhs_req.recv_psn_valid;
  endfunction

  // 功能：校验 modify QP 请求的 QP 句柄与目标状态。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：qp_h 为空或非 QP kind、目标状态不在合法集合返回 INVALID_ARGUMENT。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "modify request requires a QP handle");
    if (!(new_state inside {RDMA_QPS_RESET, RDMA_QPS_INIT, RDMA_QPS_RTR,
                            RDMA_QPS_RTS, RDMA_QPS_SQD, RDMA_QPS_SQE,
                            RDMA_QPS_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "requested QP state is invalid");
    return rdma_status::success();
  endfunction

  // 功能：按 transport 校验 modify QP 请求，限制 UD 只能修改状态。
  // 输入/输出及副作用：transport 为输入；先调用 validate()（null status 归一化）；返回 status。
  // 失败/边界：transport 非法返回 INVALID_ARGUMENT；UD 携带 destination_qpn/PSN 等有效位返回 INVALID_ARGUMENT。
  virtual function rdma_status validate_for_transport(
    rdma_transport_e transport
  );
    rdma_status status;

    status = rdma_status::nonnull(validate(), "modify QP validation returned null status");
    if (!status.ok())
      return status;
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "modify QP transport is invalid");
    if (transport == RDMA_TRANSPORT_UD &&
        (destination_qpn_valid || send_psn_valid || recv_psn_valid))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD QP only supports state modification");
    return rdma_status::success();
  endfunction
endclass

class rdma_post_send_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_post_send_req)

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
        cloned_sge = rdma_deep_copy#(rdma_sge)::of(
          rhs_req.sges[i], "SGE clone type mismatch");
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

class rdma_post_recv_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_post_recv_req)

  rdma_handle target_h;
  // 私有 RQ 在其目标 QP 上完成；投递到共享 SRQ 的 receive 需要关联 QP 句柄，
  // 以便 CQE 路由回正确的 receive ledger。
  rdma_handle completion_qp_h;
  longint unsigned wr_id;
  rdma_sge sges[$];

  // 功能：构造post-receive 请求，target_h/completion_qp_h 为空。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_post_recv_req");
    super.new(name);
    target_h = null;
    completion_qp_h = null;
    wr_id = '0;
  endfunction

  // 功能：复制post-receive 请求的值字段，嵌套句柄克隆为独立快照。
  // 输入/输出及副作用：rhs 为源对象；深拷贝 target_h、completion_qp_h 与 SGE，覆盖 wr_id。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal（post-receive request copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_post_recv_req rhs_req;
    rdma_sge cloned_sge;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "post-receive request copy type mismatch")
    target_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.target_h, "receive target clone type mismatch");
    completion_qp_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_req.completion_qp_h, "receive completion QP clone type mismatch");
    wr_id = rhs_req.wr_id;
    sges.delete();
    foreach (rhs_req.sges[i]) begin
      if (rhs_req.sges[i] == null) begin
        sges.push_back(null);
      end
      else begin
        cloned_sge = rdma_deep_copy#(rdma_sge)::of(
          rhs_req.sges[i], "SGE clone type mismatch");
        sges.push_back(cloned_sge);
      end
    end
  endfunction

  // 功能：校验 post-receive 请求的目标与 completion QP 组合，以及 SGE 数量与句柄。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：目标非 QP/SRQ、私有 RQ 指定了 completion QP、共享 SRQ 缺 QP completion 句柄、SGE 超过 32 或
  //   句柄为空返回 INVALID_ARGUMENT；零长度 SGE 按驱动 wr.c 规则跳过，全部零长度时允许空 payload。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (target_h == null ||
        !(target_h.kind inside {RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "post-receive target is not a QP or SRQ");
    if (target_h.kind == RDMA_RESOURCE_QP) begin
      if (completion_qp_h != null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "private receive cannot specify a completion QP"
        );
    end
    else begin
      if (completion_qp_h == null ||
          completion_qp_h.kind != RDMA_RESOURCE_QP)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "shared SRQ receive requires a QP completion handle"
        );
    end

    // 驱动先按原始 ib_recv_wr->num_sge 检查 XTRDMA_MAX_SGE_NUM，再过滤零长度 SGE；
    // 保留原始数组边界可避免请求层接受硬件会直接拒绝的描述符列表。
    if (sges.size() > RDMA_MAX_WQ_SGE)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "receive SGE count exceeds driver limit of 32");

    // wr.c 把 num_sge=0 视为合法的空 inline RQE，故不加“至少一个 SGE”要求；codec 会发布
    // SGE_NUM=0 与 TPL=0。非空列表仍须通过下面的空句柄检查。
    foreach (sges[i]) begin
      if (sges[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "receive SGE handle is null");
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_packet extends uvm_object;
  `uvm_object_utils(rdma_packet)

  rdma_transport_e transport;
  rdma_network_opcode_e opcode;
  bit [23:0] destination_qpn;
  bit [23:0] source_qpn;
  bit [23:0] psn;
  byte unsigned header_bytes[$];
  string metadata[$];
  byte unsigned payload[$];

  // 功能：构造网络包，默认 RC、SEND，QPN/PSN 清零。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_packet");
    super.new(name);
    transport = RDMA_TRANSPORT_RC;
    opcode = RDMA_NET_SEND;
    destination_qpn = '0;
    source_qpn = '0;
    psn = '0;
  endfunction

  // 功能：复制网络包（含 header/metadata/payload）的值字段。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（packet copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_packet rhs_packet;

    super.do_copy(rhs);
    if (!$cast(rhs_packet, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "packet copy type mismatch")
    transport = rhs_packet.transport;
    opcode = rhs_packet.opcode;
    destination_qpn = rhs_packet.destination_qpn;
    source_qpn = rhs_packet.source_qpn;
    psn = rhs_packet.psn;
    header_bytes = rhs_packet.header_bytes;
    metadata = rhs_packet.metadata;
    payload = rhs_packet.payload;
  endfunction
endclass

class rdma_net_response_policy extends uvm_object;
  `uvm_object_utils(rdma_net_response_policy)

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
  `uvm_object_utils(rdma_net_fault)

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
