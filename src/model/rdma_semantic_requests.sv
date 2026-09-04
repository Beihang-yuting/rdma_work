// 目录：协议与资源模型层 model/rdma_semantic_requests.sv。
// 职责：实现 rdma_semantic_requests 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_semantic_requests.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

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
  RDMA_WR_RECV            = 5'd8
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
  RDMA_NET_NAK              = 5'd7
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

// 功能：执行接口 rdma_is_power_of_two 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 rdma_is_power_of_two）。
// 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
//   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
// 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
function automatic bit rdma_is_power_of_two(int unsigned value);
  return value != 0 && (value & (value - 1'b1)) == 0;
endfunction

// 功能：执行接口 rdma_send_opcode_valid_for_transport 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 rdma_send_opcode_valid_for_transport）。
// 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
//   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
// 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
function automatic bit rdma_send_opcode_valid_for_transport(
  rdma_transport_e transport,
  rdma_work_opcode_e opcode
);
  case (transport)
    RDMA_TRANSPORT_RC:
      return opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                            RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                            RDMA_WR_RDMA_READ, RDMA_WR_ATOMIC_CMP_SWAP,
                            RDMA_WR_ATOMIC_FETCH_ADD,
                            RDMA_WR_LOCAL_INVALIDATE};
    RDMA_TRANSPORT_UD:
      return opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM};
    RDMA_TRANSPORT_URC:
      return opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_sge");
    super.new(name);
    iova = '0;
    length = '0;
    lkey = '0;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_semantic_request");
    super.new(name);
    request_id = '0;
    correlation_id = '0;
    owner = null;
    expected_status_code = RDMA_SC_OK;
    timeout_policy = RDMA_TIMEOUT_NONE;
    timeout_value = '0;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_semantic_request rhs_req;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "semantic request copy type mismatch")
    request_id = rhs_req.request_id;
    correlation_id = rhs_req.correlation_id;
    expected_status_code = rhs_req.expected_status_code;
    timeout_policy = rhs_req.timeout_policy;
    timeout_value = rhs_req.timeout_value;
    if (rhs_req.owner == null) begin
      owner = null;
    end
    else begin
      cloned_object = rhs_req.owner.clone();
      if (cloned_object == null || !$cast(owner, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "function handle clone type mismatch")
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_qp_context_attributes r;
    uvm_object c;

    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "QP attributes copy mismatch")
    path_mtu_bytes = r.path_mtu_bytes;
    pkey = r.pkey;
    access = r.access;
    signature_enable = r.signature_enable;
    tx_flow_control = r.tx_flow_control;
    rx_flow_control = r.rx_flow_control;
    if (r.address_vector == null) address_vector = null;
    else begin c = r.address_vector.clone(); if (c == null || !$cast(address_vector, c) || address_vector == r.address_vector) `uvm_fatal("RDMA_COPY_TYPE", "QP AV clone failure") end
    if (r.behavior == null) behavior = null;
    else begin c = r.behavior.clone(); if (c == null || !$cast(behavior, c) || behavior == r.behavior) `uvm_fatal("RDMA_COPY_TYPE", "QP behavior clone failure") end
    if (r.transport_ext == null) transport_ext = null;
    else begin c = r.transport_ext.clone(); if (c == null || !$cast(transport_ext, c) || transport_ext == r.transport_ext) `uvm_fatal("RDMA_COPY_TYPE", "QP extension clone failure") end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status validate(rdma_transport_e transport);
    rdma_status status;

    if (path_mtu_bytes == 0 || address_vector == null || behavior == null ||
        transport_ext == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP context attributes are incomplete");
    status = address_vector.validate(); if (!status.ok()) return status;
    status = behavior.validate(); if (!status.ok()) return status;
    if (transport_ext.transport_kind() != transport)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP transport extension does not match");
    status = transport_ext.validate(); if (!status.ok()) return status;
    return rdma_status::success();
  endfunction
endclass

class rdma_create_pd_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_create_pd_req)

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_register_mr_req");
    super.new(name);
    pd_h = null;
    iova = '0;
    length = '0;
    access = '0;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_register_mr_req rhs_req;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "register MR request copy type mismatch")
    if (rhs_req.pd_h == null) begin
      pd_h = null;
    end
    else begin
      cloned_object = rhs_req.pd_h.clone();
      if (cloned_object == null || !$cast(pd_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "PD handle clone type mismatch")
    end
    iova = rhs_req.iova;
    length = rhs_req.length;
    access = rhs_req.access;
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_create_cq_req");
    super.new(name);
    depth = '0;
    cqe_size_bytes = 64;
    ceq_h = null;
    ring_backing = rdma_queue_backing_spec::type_id::create("ring_backing");
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_cq_req rhs_req;
    uvm_object cloned_object;
    rdma_queue_backing_spec cloned_backing;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "create CQ request copy type mismatch")
    depth = rhs_req.depth;
    cqe_size_bytes = rhs_req.cqe_size_bytes;
    if (rhs_req.ceq_h == null) begin
      ceq_h = null;
    end
    else begin
      cloned_object = rhs_req.ceq_h.clone();
      if (cloned_object == null || !$cast(ceq_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "CEQ handle clone type mismatch")
    end
    if (rhs_req.ring_backing == null) begin
      ring_backing = null;
    end
    else begin
      cloned_object = rhs_req.ring_backing.clone();
      if (cloned_object == null ||
          !$cast(cloned_backing, cloned_object) ||
          cloned_backing == rhs_req.ring_backing)
        `uvm_fatal("RDMA_COPY_TYPE", "CQ ring backing clone mismatch")
      ring_backing = cloned_backing;
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
    status = ring_backing.validate();
    if (!status.ok())
      return status;
    return rdma_status::success();
  endfunction
endclass

// 功能：执行接口 rdma_qp_backing_spec_status 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 rdma_qp_backing_spec_status）。
// 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
//   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
// 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_qp_req rhs_req;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "create QP request copy type mismatch")
    transport = rhs_req.transport;
    sq_depth = rhs_req.sq_depth;
    rq_depth = rhs_req.rq_depth;
    max_send_sge = rhs_req.max_send_sge;
    max_recv_sge = rhs_req.max_recv_sge;
    max_inline_data = rhs_req.max_inline_data;
    if (rhs_req.pd_h == null) pd_h = null;
    else begin
      cloned_object = rhs_req.pd_h.clone();
      if (cloned_object == null || !$cast(pd_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "PD handle clone type mismatch")
    end
    if (rhs_req.send_cq_h == null) send_cq_h = null;
    else begin
      cloned_object = rhs_req.send_cq_h.clone();
      if (cloned_object == null || !$cast(send_cq_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "send CQ handle clone type mismatch")
    end
    if (rhs_req.recv_cq_h == null) recv_cq_h = null;
    else begin
      cloned_object = rhs_req.recv_cq_h.clone();
      if (cloned_object == null || !$cast(recv_cq_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "receive CQ handle clone type mismatch")
    end
    if (rhs_req.srq_h == null) srq_h = null;
    else begin
      cloned_object = rhs_req.srq_h.clone();
      if (cloned_object == null || !$cast(srq_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "SRQ handle clone type mismatch")
    end
    if (rhs_req.sq_backing == null) sq_backing = null;
    else begin
      cloned_object = rhs_req.sq_backing.clone();
      if (cloned_object == null || !$cast(sq_backing, cloned_object) ||
          sq_backing == rhs_req.sq_backing)
        `uvm_fatal("RDMA_COPY_TYPE", "SQ backing clone type mismatch")
    end
    if (rhs_req.rq_backing == null) rq_backing = null;
    else begin
      cloned_object = rhs_req.rq_backing.clone();
      if (cloned_object == null || !$cast(rq_backing, cloned_object) ||
          rq_backing == rhs_req.rq_backing)
        `uvm_fatal("RDMA_COPY_TYPE", "RQ backing clone type mismatch")
    end
    if (rhs_req.sq_sgb_backing == null) sq_sgb_backing = null;
    else begin
      cloned_object = rhs_req.sq_sgb_backing.clone();
      if (cloned_object == null || !$cast(sq_sgb_backing, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "SQ SGB backing clone type mismatch")
    end
    if (rhs_req.context_attrs == null) context_attrs = null;
    else begin
      cloned_object = rhs_req.context_attrs.clone();
      if (cloned_object == null || !$cast(context_attrs, cloned_object) ||
          context_attrs == rhs_req.context_attrs)
        `uvm_fatal("RDMA_COPY_TYPE", "QP context attributes clone mismatch")
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
    status = context_attrs.validate(transport);
    if (!status.ok()) return status;
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

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_srq_depth）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status validate_srq_depth(
    int unsigned authoritative_srq_depth
  );
    rdma_status status;

    status = validate();
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

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_queue_caps）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status validate_queue_caps(
    rdma_queue_capabilities queue_caps
  );
    rdma_status status;
    longint unsigned sq_logical_bytes;
    longint unsigned rq_logical_bytes;
    longint unsigned sq_storage_bytes;
    longint unsigned rq_storage_bytes;

    status = validate();
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_create_srq_req");
    super.new(name);
    depth = '0;
    max_sge = '0;
    limit_threshold = 16;
    pd_h = null;
    payload_backing =
      rdma_queue_backing_spec::type_id::create("payload_backing");
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_srq_req rhs_req;
    uvm_object cloned_object;
    rdma_queue_backing_spec cloned_backing;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "create SRQ request copy type mismatch")
    depth = rhs_req.depth;
    max_sge = rhs_req.max_sge;
    limit_threshold = rhs_req.limit_threshold;
    if (rhs_req.pd_h == null) begin
      pd_h = null;
    end
    else begin
      cloned_object = rhs_req.pd_h.clone();
      if (cloned_object == null || !$cast(pd_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "PD handle clone type mismatch")
    end
    if (rhs_req.payload_backing == null) begin
      payload_backing = null;
    end
    else begin
      cloned_object = rhs_req.payload_backing.clone();
      if (cloned_object == null ||
          !$cast(cloned_backing, cloned_object) ||
          cloned_backing == rhs_req.payload_backing)
        `uvm_fatal("RDMA_COPY_TYPE", "SRQ payload backing clone mismatch")
      payload_backing = cloned_backing;
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
    status = payload_backing.validate();
    if (!status.ok())
      return status;
    return rdma_status::success();
  endfunction
endclass

class rdma_create_ceq_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_create_ceq_req)

  int unsigned depth, vector_id;
  rdma_queue_backing_spec ring_backing;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_create_ceq_req");
    super.new(name);
    depth = '0;
    vector_id = '0;
    ring_backing = rdma_queue_backing_spec::type_id::create("ring_backing");
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_ceq_req rhs_req;
    uvm_object cloned_object;
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
      cloned_object = rhs_req.ring_backing.clone();
      if (cloned_object == null ||
          !$cast(cloned_backing, cloned_object) ||
          cloned_backing == rhs_req.ring_backing)
        `uvm_fatal("RDMA_COPY_TYPE", "CEQ ring backing clone mismatch")
      ring_backing = cloned_backing;
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
    status = ring_backing.validate();
    if (!status.ok())
      return status;
    return rdma_status::success();
  endfunction
endclass

class rdma_create_aeq_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_create_aeq_req)

  int unsigned depth, vector_id;
  rdma_queue_backing_spec ring_backing;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_create_aeq_req");
    super.new(name);
    depth = '0;
    vector_id = '0;
    ring_backing = rdma_queue_backing_spec::type_id::create("ring_backing");
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_create_aeq_req rhs_req;
    uvm_object cloned_object;
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
      cloned_object = rhs_req.ring_backing.clone();
      if (cloned_object == null ||
          !$cast(cloned_backing, cloned_object) ||
          cloned_backing == rhs_req.ring_backing)
        `uvm_fatal("RDMA_COPY_TYPE", "AEQ ring backing clone mismatch")
      ring_backing = cloned_backing;
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
    status = ring_backing.validate();
    if (!status.ok())
      return status;
    return rdma_status::success();
  endfunction
endclass

class rdma_destroy_resource_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_destroy_resource_req)

  rdma_handle target_h;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_destroy_resource_req");
    super.new(name);
    target_h = null;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_destroy_resource_req rhs_req;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "destroy request copy type mismatch")
    if (rhs_req.target_h == null) begin
      target_h = null;
    end
    else begin
      cloned_object = rhs_req.target_h.clone();
      if (cloned_object == null || !$cast(target_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "target handle clone type mismatch")
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_modify_qp_req rhs_req;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "modify QP request copy type mismatch")
    if (rhs_req.qp_h == null) begin
      qp_h = null;
    end
    else begin
      cloned_object = rhs_req.qp_h.clone();
      if (cloned_object == null || !$cast(qp_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "QP handle clone type mismatch")
    end
    new_state = rhs_req.new_state;
    destination_qpn = rhs_req.destination_qpn;
    send_psn = rhs_req.send_psn;
    recv_psn = rhs_req.recv_psn;
    destination_qpn_valid = rhs_req.destination_qpn_valid;
    send_psn_valid = rhs_req.send_psn_valid;
    recv_psn_valid = rhs_req.recv_psn_valid;
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_for_transport）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status validate_for_transport(
    rdma_transport_e transport
  );
    rdma_status status;

    status = validate();
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
  int unsigned address_vector_id;
  rdma_address_vector address_vector;
  bit fence;
  bit address_vector_valid;
  longint unsigned compare_value;
  longint unsigned swap_add_value;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
    address_vector_id = '0;
    address_vector = null; fence = 0;
    address_vector_valid = 1'b0;
    compare_value = '0;
    swap_add_value = '0;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_post_send_req rhs_req;
    uvm_object cloned_object;
    rdma_sge cloned_sge;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "post-send request copy type mismatch")
    if (rhs_req.qp_h == null) begin
      qp_h = null;
    end
    else begin
      cloned_object = rhs_req.qp_h.clone();
      if (cloned_object == null || !$cast(qp_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "QP handle clone type mismatch")
    end
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
    address_vector_id = rhs_req.address_vector_id;
    fence = rhs_req.fence;
    if (rhs_req.address_vector == null) address_vector = null;
    else begin cloned_object = rhs_req.address_vector.clone(); if (cloned_object == null || !$cast(address_vector, cloned_object)) `uvm_fatal("RDMA_COPY_TYPE", "AV clone failure"); end
    address_vector_valid = rhs_req.address_vector_valid;
    compare_value = rhs_req.compare_value;
    swap_add_value = rhs_req.swap_add_value;
    sges.delete();
    foreach (rhs_req.sges[i]) begin
      if (rhs_req.sges[i] == null) begin
        sges.push_back(null);
      end
      else begin
        cloned_object = rhs_req.sges[i].clone();
        if (cloned_object == null || !$cast(cloned_sge, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "SGE clone type mismatch")
        sges.push_back(cloned_sge);
      end
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "post-send target is not a QP handle");
    if (!rdma_send_opcode_valid_for_transport(transport, opcode))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "work opcode is invalid for transport");
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
    else begin
      if (!inline_data && sges.size() == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "non-inline send has no SGE");
      if (inline_data && payload.size() == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "inline send has no payload");
      foreach (sges[i]) begin
        if (sges[i] == null || sges[i].length == 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "send SGE is null or has zero length");
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
    return rdma_status::success();
  endfunction
endclass

class rdma_post_recv_req extends rdma_semantic_request;
  `uvm_object_utils(rdma_post_recv_req)

  rdma_handle target_h;
  // Private RQs complete on their target QP.  A receive posted to a shared
  // SRQ needs the associated QP handle so the CQE can be routed back to the
  // correct receive ledger.
  rdma_handle completion_qp_h;
  longint unsigned wr_id;
  rdma_sge sges[$];

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_post_recv_req");
    super.new(name);
    target_h = null;
    completion_qp_h = null;
    wr_id = '0;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_post_recv_req rhs_req;
    uvm_object cloned_object;
    rdma_sge cloned_sge;

    super.do_copy(rhs);
    if (!$cast(rhs_req, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "post-receive request copy type mismatch")
    if (rhs_req.target_h == null) begin
      target_h = null;
    end
    else begin
      cloned_object = rhs_req.target_h.clone();
      if (cloned_object == null || !$cast(target_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "receive target clone type mismatch")
    end
    if (rhs_req.completion_qp_h == null) begin
      completion_qp_h = null;
    end
    else begin
      cloned_object = rhs_req.completion_qp_h.clone();
      if (cloned_object == null || !$cast(completion_qp_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "receive completion QP clone type mismatch")
    end
    wr_id = rhs_req.wr_id;
    sges.delete();
    foreach (rhs_req.sges[i]) begin
      if (rhs_req.sges[i] == null) begin
        sges.push_back(null);
      end
      else begin
        cloned_object = rhs_req.sges[i].clone();
        if (cloned_object == null || !$cast(cloned_sge, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "SGE clone type mismatch")
        sges.push_back(cloned_sge);
      end
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
    if (sges.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "receive has no SGE");
    foreach (sges[i]) begin
      if (sges[i] == null || sges[i].length == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "receive SGE is null or has zero length");
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_packet");
    super.new(name);
    transport = RDMA_TRANSPORT_RC;
    opcode = RDMA_NET_SEND;
    destination_qpn = '0;
    source_qpn = '0;
    psn = '0;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_net_response_policy");
    super.new(name);
    responder_mode = RDMA_RESPONDER_DUT;
    drop_every_n = '0;
    corrupt_every_n = '0;
    delay_cycles = '0;
    deterministic_seed = '0;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
