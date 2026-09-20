// 目录：协议与资源模型层 model/rdma_queue_models.sv。
// 职责：实现 rdma_queue_models 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_models.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 功能：rdma_clone_status_value 复制 source 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
// 输入/输出及副作用：source（输入）；rdma_clone_status_value 读取 source 并使用字段 result、result.category、result.code、result.hardware_code、result.hardware_code_valid、result.source_engine、result.function_uid、result.generation；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_clone_status_value 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
function automatic rdma_status rdma_clone_status_value(rdma_status source);
  rdma_status result;

  if (source == null)
    return null;
  result = rdma_status::type_id::create("status");
  result.category = source.category;
  result.code = source.code;
  result.hardware_code = source.hardware_code;
  result.hardware_code_valid = source.hardware_code_valid;
  result.source_engine = source.source_engine;
  result.function_uid = source.function_uid;
  result.generation = source.generation;
  result.resource_id = source.resource_id;
  result.command_id = source.command_id;
  result.wr_id = source.wr_id;
  result.severity = source.severity;
  result.retryable = source.retryable;
  result.message = source.message;
  return result;
endfunction

typedef enum bit [2:0] {
  RDMA_SQ_PAYLOAD_NONE,
  RDMA_SQ_PAYLOAD_INLINE_WQE,
  RDMA_SQ_PAYLOAD_INLINE_SGB,
  RDMA_SQ_PAYLOAD_SGE_WQE,
  RDMA_SQ_PAYLOAD_SGE_SGB,
  RDMA_SQ_PAYLOAD_ATOMIC_FIXED
} rdma_sq_payload_mode_e;

class rdma_cmq_sqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_sqe_model)

  rdma_cmq_opcode_e opcode;
  longint unsigned command_id;
  rdma_function_handle function_h;
  rdma_handle target_h;
  rdma_hw_model context_model;
  int unsigned flags;

  // 功能：构造 rdma_cmq_sqe_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：opcode=RDMA_CMQ_QUERY；command_id='0；function_h=null；target_h=null；context_model=null；flags='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_sqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_sqe_model");
    super.new(name);
    opcode = RDMA_CMQ_QUERY;
    command_id = '0;
    function_h = null;
    target_h = null;
    context_model = null;
    flags = '0;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_sqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ SQE model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_sqe_model rhs_sqe;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_sqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ SQE model copy mismatch")
    opcode = rhs_sqe.opcode;
    command_id = rhs_sqe.command_id;
    function_h = rdma_clone_function_handle_value(rhs_sqe.function_h,
                                                  "CMQ SQE");
    target_h = rdma_clone_handle_value(rhs_sqe.target_h, "CMQ SQE target");
    flags = rhs_sqe.flags;
    if (rhs_sqe.context_model == null) begin
      context_model = null;
    end
    else begin
      cloned_object = rhs_sqe.context_model.clone();
      if (cloned_object == null || !$cast(context_model, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "CMQ context clone mismatch")
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CMQ opcode is unsupported”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、opcode、command_id、function_h、function_h.kind、context_model、target_h、target_h.kind 并使用字段 context_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_UNSUPPORTED_OPCODE、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CMQ opcode is unsupported”“CMQ command ID is zero”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status context_status;
    rdma_qpc_model qpc_context;
    rdma_cqc_model cqc_context;
    rdma_mrt_model mrt_context;
    rdma_srqc_model srqc_context;
    rdma_ceqc_model ceqc_context;
    rdma_aeqc_model aeqc_context;

    if (!(opcode inside {RDMA_CMQ_CREATE_PD, RDMA_CMQ_REGISTER_MR,
                         RDMA_CMQ_CREATE_CQ, RDMA_CMQ_CREATE_QP,
                         RDMA_CMQ_CREATE_SRQ, RDMA_CMQ_CREATE_CEQ,
                         RDMA_CMQ_CREATE_AEQ, RDMA_CMQ_DESTROY,
                         RDMA_CMQ_MODIFY_QP, RDMA_CMQ_QUERY}))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "CMQ opcode is unsupported");
    if (command_id == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command ID is zero");
    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command lacks function identity");
    if (opcode inside {RDMA_CMQ_REGISTER_MR, RDMA_CMQ_CREATE_CQ,
                       RDMA_CMQ_CREATE_QP, RDMA_CMQ_CREATE_SRQ,
                       RDMA_CMQ_CREATE_CEQ, RDMA_CMQ_CREATE_AEQ,
                       RDMA_CMQ_MODIFY_QP} && context_model == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command lacks required context");
    case (opcode)
      RDMA_CMQ_REGISTER_MR:
        if (!$cast(mrt_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "REGISTER_MR requires MRT context");
      RDMA_CMQ_CREATE_CQ:
        if (!$cast(cqc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_CQ requires CQC context");
      RDMA_CMQ_CREATE_QP:
        if (!$cast(qpc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_QP requires QPC context");
      RDMA_CMQ_CREATE_SRQ:
        if (!$cast(srqc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_SRQ requires SRQC context");
      RDMA_CMQ_CREATE_CEQ:
        if (!$cast(ceqc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_CEQ requires CEQC context");
      RDMA_CMQ_CREATE_AEQ:
        if (!$cast(aeqc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CREATE_AEQ requires AEQC context");
      RDMA_CMQ_MODIFY_QP: begin
        if (target_h == null || target_h.kind != RDMA_RESOURCE_QP)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "MODIFY_QP requires QP target");
        if (!$cast(qpc_context, context_model))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "MODIFY_QP requires QPC context");
      end
      RDMA_CMQ_DESTROY,
      RDMA_CMQ_QUERY:
        if (target_h == null)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CMQ command requires target handle");
      default: begin
      end
    endcase
    if (context_model != null) begin
      context_status = context_model.validate();
      if (!context_status.ok())
        return context_status;
    end
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("CMQ_SQE(opcode=%s command_id=%0d)",
                     opcode.name(), command_id);
  endfunction
endclass

class rdma_cmq_completion_model extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_completion_model)

  rdma_cmq_opcode_e opcode;
  longint unsigned command_id;
  rdma_status status;
  rdma_handle result_h;

  // 功能：构造 rdma_cmq_completion_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：opcode=RDMA_CMQ_QUERY；command_id='0；status=null；result_h=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_completion_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_completion_model");
    super.new(name);
    opcode = RDMA_CMQ_QUERY;
    command_id = '0;
    status = null;
    result_h = null;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_completion_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ completion copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_completion_model rhs_completion;

    super.do_copy(rhs);
    if (!$cast(rhs_completion, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ completion copy mismatch")
    opcode = rhs_completion.opcode;
    command_id = rhs_completion.command_id;
    status = rdma_clone_status_value(rhs_completion.status);
    result_h = rdma_clone_handle_value(rhs_completion.result_h,
                                       "CMQ completion result");
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CMQ completion opcode is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、opcode、command_id 并使用字段 rdma_status、opcode、command_id；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CMQ completion opcode is invalid”“CMQ completion lacks command ID or status”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (!(opcode inside {RDMA_CMQ_CREATE_PD, RDMA_CMQ_REGISTER_MR,
                         RDMA_CMQ_CREATE_CQ, RDMA_CMQ_CREATE_QP,
                         RDMA_CMQ_CREATE_SRQ, RDMA_CMQ_CREATE_CEQ,
                         RDMA_CMQ_CREATE_AEQ, RDMA_CMQ_DESTROY,
                         RDMA_CMQ_MODIFY_QP, RDMA_CMQ_QUERY}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ completion opcode is invalid");
    if (command_id == 0 || status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ completion lacks command ID or status");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    string status_text;

    status_text = (status == null) ? "null" : status.convert2string();
    return $sformatf("CMQ_CQE(opcode=%s command_id=%0d status=%s)",
                     opcode.name(), command_id, status_text);
  endfunction
endclass

virtual class rdma_sqe_transport_ext extends uvm_object;

  // 功能：构造 rdma_sqe_transport_ext，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_sqe_transport_ext 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_sqe_transport_ext");
    super.new(name);
  endfunction

  // 功能：transport_kind 使用 当前对象字段 计算并返回 rdma_transport_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；transport_kind 读取 对象字段：compare_value、swap_add_value 并使用字段 name、remote_addr、rkey、remote_access_valid、rkey_valid、compare_value、swap_add_value；函数返回 rdma_transport_e，不取得调用方资源所有权。
  // 失败/边界：transport_kind 是只读访问器，按对象字段返回固定值；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  pure virtual function rdma_transport_e transport_kind();

  // 功能：validate 校验 opcode 与当前对象状态的一致性，并显式处理“rdma_sqe_rc_ext”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）；validate 读取 opcode 并使用字段 name、remote_addr、rkey、remote_access_valid、rkey_valid、compare_value、swap_add_value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 无返回值，仅执行 name="rdma_sqe_rc_ext")、remote_addr='0、rkey='0、remote_access_valid=1'b0；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  pure virtual function rdma_status validate(rdma_work_opcode_e opcode);

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  pure virtual function string describe();
endclass

class rdma_sqe_rc_ext extends rdma_sqe_transport_ext;
  `uvm_object_utils(rdma_sqe_rc_ext)

  rdma_iova_t remote_addr;
  bit [31:0] rkey;
  bit remote_access_valid;
  bit rkey_valid;
  longint unsigned compare_value;
  longint unsigned swap_add_value;

  // 功能：构造 rdma_sqe_rc_ext，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：remote_addr='0；rkey='0；remote_access_valid=1'b0；rkey_valid=1'b0；compare_value='0；swap_add_value='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_sqe_rc_ext 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_sqe_rc_ext");
    super.new(name);
    remote_addr = '0;
    rkey = '0;
    remote_access_valid = 1'b0;
    rkey_valid = 1'b0;
    compare_value = '0;
    swap_add_value = '0;
  endfunction

  // 功能：将 rhs 中 rdma_sqe_rc_ext 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（RC SQE extension copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_sqe_rc_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "RC SQE extension copy mismatch")
    remote_addr = rhs_ext.remote_addr;
    rkey = rhs_ext.rkey;
    remote_access_valid = rhs_ext.remote_access_valid;
    rkey_valid = rhs_ext.rkey_valid;
    compare_value = rhs_ext.compare_value;
    swap_add_value = rhs_ext.swap_add_value;
  endfunction

  // 功能：transport_kind 使用 当前对象字段 计算并返回 rdma_transport_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；transport_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_transport_e，不取得调用方资源所有权。
  // 失败/边界：transport_kind 是只读访问器，返回 RDMA_TRANSPORT_RC；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_RC;
  endfunction

  // 功能：validate 校验 opcode 与当前对象状态的一致性，并显式处理“RC local invalidate rkey is absent”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）；validate 读取 opcode 并使用字段 rdma_status、rkey_valid、remote_access_valid、remote_addr.value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“RC local invalidate rkey is absent”“RC remote operation lacks address or rkey”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate(rdma_work_opcode_e opcode);
    if (opcode == RDMA_WR_LOCAL_INVALIDATE && !rkey_valid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RC local invalidate rkey is absent");
    if (opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                       RDMA_WR_RDMA_READ, RDMA_WR_ATOMIC_CMP_SWAP,
                       RDMA_WR_ATOMIC_FETCH_ADD}) begin
      if (!remote_access_valid || !rkey_valid)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC remote operation lacks address or rkey");
    end
    if (opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                       RDMA_WR_ATOMIC_FETCH_ADD}) begin
      if ((remote_addr.value & 64'h7) != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RC atomic remote address is not 8-byte aligned"
        );
    end
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("RC_SQE(remote_addr=0x%016x rkey=0x%08x)",
                     remote_addr.value, rkey);
  endfunction
endclass

class rdma_sqe_ud_ext extends rdma_sqe_transport_ext;
  `uvm_object_utils(rdma_sqe_ud_ext)

  bit [23:0] destination_qpn;
  bit [31:0] qkey;
  int unsigned address_vector_id;
  rdma_address_vector address_vector;
  bit address_vector_valid;

  // 功能：构造 rdma_sqe_ud_ext，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：destination_qpn='0；qkey='0；address_vector_id='0；address_vector=null；address_vector_valid=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_sqe_ud_ext 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_sqe_ud_ext");
    super.new(name);
    destination_qpn = '0;
    qkey = '0;
    address_vector_id = '0;
    address_vector = null;
    address_vector_valid = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_sqe_ud_ext 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（UD SQE extension copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_sqe_ud_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "UD SQE extension copy mismatch")
    destination_qpn = rhs_ext.destination_qpn;
    qkey = rhs_ext.qkey;
    address_vector_id = rhs_ext.address_vector_id;
    if (rhs_ext.address_vector == null)
      address_vector = null;
    else begin
      uvm_object cloned_object;
      cloned_object = rhs_ext.address_vector.clone();
      if (cloned_object == null || !$cast(address_vector, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "UD SQE address vector clone mismatch")
    end
    address_vector_valid = rhs_ext.address_vector_valid;
  endfunction

  // 功能：transport_kind 使用 当前对象字段 计算并返回 rdma_transport_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；transport_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_transport_e，不取得调用方资源所有权。
  // 失败/边界：transport_kind 是只读访问器，返回 RDMA_TRANSPORT_UD；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_UD;
  endfunction

  // 功能：validate 校验 opcode 与当前对象状态的一致性，并显式处理“UD SQE opcode is unsupported”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）；validate 读取 opcode 并使用字段 rdma_status、destination_qpn、qkey、address_vector_valid、address_vector；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_UNSUPPORTED_OPCODE、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“UD SQE opcode is unsupported”“UD SQE lacks destination QPN, qkey, or AV”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate(rdma_work_opcode_e opcode);
    if (!(opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM, RDMA_WR_SEND_WITH_INV}))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "UD SQE opcode is unsupported");
    if (destination_qpn == 0 || qkey == 0 || !address_vector_valid ||
        address_vector == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD SQE lacks destination QPN, qkey, or AV");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("UD_SQE(destination_qpn=%0d qkey=0x%08x)",
                     destination_qpn, qkey);
  endfunction
endclass

class rdma_sqe_urc_ext extends rdma_sqe_transport_ext;
  `uvm_object_utils(rdma_sqe_urc_ext)

  bit [23:0] destination_qpn;
  rdma_handle completion_qp_h;
  rdma_iova_t remote_addr;
  bit [31:0] rkey;
  bit remote_access_valid;
  bit rkey_valid;

  // 功能：构造 rdma_sqe_urc_ext，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：destination_qpn='0；remote_addr='0；rkey='0；remote_access_valid=1'b0；rkey_valid=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_sqe_urc_ext 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_sqe_urc_ext");
    super.new(name);
    destination_qpn = '0;
    completion_qp_h = null;
    remote_addr = '0;
    rkey = '0;
    remote_access_valid = 1'b0;
    rkey_valid = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_sqe_urc_ext 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（URC SQE extension copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_sqe_urc_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "URC SQE extension copy mismatch")
    destination_qpn = rhs_ext.destination_qpn;
    if (rhs_ext.completion_qp_h == null) completion_qp_h = null;
    else begin
      uvm_object cloned_object;
      cloned_object = rhs_ext.completion_qp_h.clone();
      if (cloned_object == null || !$cast(completion_qp_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "URC completion QP clone mismatch")
    end
    remote_addr = rhs_ext.remote_addr;
    rkey = rhs_ext.rkey;
    remote_access_valid = rhs_ext.remote_access_valid;
    rkey_valid = rhs_ext.rkey_valid;
  endfunction

  // 功能：transport_kind 使用 当前对象字段 计算并返回 rdma_transport_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；transport_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_transport_e，不取得调用方资源所有权。
  // 失败/边界：transport_kind 是只读访问器，返回 RDMA_TRANSPORT_URC；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_URC;
  endfunction

  // 功能：validate 校验 opcode 与当前对象状态的一致性，并显式处理“URC local invalidate rkey is absent”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）；validate 读取 opcode 并使用字段 rdma_status、rkey_valid、destination_qpn、remote_access_valid；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“URC local invalidate rkey is absent”“URC SQE destination QPN is zero”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate(rdma_work_opcode_e opcode);
    if (completion_qp_h == null || completion_qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC SQE requires completion QP authority");
    if (opcode == RDMA_WR_LOCAL_INVALIDATE) begin
      if (!rkey_valid)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "URC local invalidate rkey is absent");
      return rdma_status::success();
    end
    if (destination_qpn == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC SQE destination QPN is zero");
    if (opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                       RDMA_WR_RDMA_READ}) begin
      if (!remote_access_valid || !rkey_valid)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "URC remote operation lacks address or rkey");
    end
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("URC_SQE(destination_qpn=%0d remote_addr=0x%016x)",
                     destination_qpn, remote_addr.value);
  endfunction
endclass

class rdma_sqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_sqe_model)

  rdma_transport_e transport;
  rdma_work_opcode_e opcode;
  rdma_handle qp_h;
  longint unsigned wr_id;
  rdma_sge sges[$];
  bit inline_data;
  byte unsigned payload[$];
  bit signaled;
  bit solicited;
  bit fence;
  bit [31:0] immediate_data;
  rdma_sqe_transport_ext transport_ext;

  // 功能：构造 rdma_sqe_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：transport=RDMA_TRANSPORT_RC；opcode=RDMA_WR_SEND；qp_h=null；wr_id='0；inline_data=1'b0；signaled=1'b0；solicited=1'b0；fence=1'b0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_sqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_sqe_model");
    super.new(name);
    transport = RDMA_TRANSPORT_RC;
    opcode = RDMA_WR_SEND;
    qp_h = null;
    wr_id = '0;
    inline_data = 1'b0;
    signaled = 1'b0;
    solicited = 1'b0;
    fence = 1'b0;
    immediate_data = '0;
    transport_ext = null;
  endfunction

  // 功能：将 rhs 中 rdma_sqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（data SQE model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_sqe_model rhs_sqe;
    uvm_object cloned_object;
    rdma_sge cloned_sge;

    super.do_copy(rhs);
    if (!$cast(rhs_sqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "data SQE model copy mismatch")
    transport = rhs_sqe.transport;
    opcode = rhs_sqe.opcode;
    qp_h = rdma_clone_handle_value(rhs_sqe.qp_h, "data SQE QP");
    wr_id = rhs_sqe.wr_id;
    inline_data = rhs_sqe.inline_data;
    payload = rhs_sqe.payload;
    signaled = rhs_sqe.signaled;
    solicited = rhs_sqe.solicited;
    fence = rhs_sqe.fence;
    immediate_data = rhs_sqe.immediate_data;
    sges.delete();
    foreach (rhs_sqe.sges[i]) begin
      if (rhs_sqe.sges[i] == null) begin
        sges.push_back(null);
      end
      else begin
        cloned_object = rhs_sqe.sges[i].clone();
        if (cloned_object == null || !$cast(cloned_sge, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "SQE SGE clone mismatch")
        sges.push_back(cloned_sge);
      end
    end
    if (rhs_sqe.transport_ext == null) begin
      transport_ext = null;
    end
    else begin
      cloned_object = rhs_sqe.transport_ext.clone();
      if (cloned_object == null || !$cast(transport_ext, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "SQE transport extension clone mismatch")
    end
  endfunction

  // 功能：validate_payload_shape 根据 wr.c 的发包规则校验本地 payload
  //       形状，统一处理 local invalidate、atomic、RDMA READ 和普通 SEND/
  //       WRITE 的 SGE 约束。
  // 输入/输出及副作用：无显式参数；读取 opcode、inline_data、payload 和
  //       sges，返回 rdma_status，不修改 SGE、请求对象或外部资源所有权。
  // 失败/边界：拒绝 atomic 非单个 8-byte SGE、RDMA READ 无非零 SGE、local
  //       invalidate 携带数据及 null SGE；普通非原子操作允许 inline 空
  //       payload、num_sge=0 或全零长度 SGE 列表，以匹配驱动过滤语义。
  protected function rdma_status validate_payload_shape();
    if (opcode == RDMA_WR_LOCAL_INVALIDATE) begin
      if (inline_data || sges.size() != 0 || payload.size() != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "local invalidate SQE carries data");
    end
    else if (opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                            RDMA_WR_ATOMIC_FETCH_ADD}) begin
      if (inline_data || payload.size() != 0 || sges.size() != 1)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic SQE shape is invalid");
      if (sges[0] == null || sges[0].length != 8)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic SQE requires one 8-byte SGE");
      if ((sges[0].iova.value & 64'h7) != 0)
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "atomic SQE local address is not 8-byte aligned");
    end
    else if (opcode == RDMA_WR_RDMA_READ) begin
      if (inline_data || payload.size() != 0 || sges.size() == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RDMA read SQE shape is invalid");
      foreach (sges[i]) begin
        if (sges[i] == null || sges[i].length == 0)
          return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "read SQE SGE is null or has zero length");
      end
    end
    else begin
      // wr.c treats num_sge==0 and lists containing only zero-length SGEs as
      // a valid zero-payload WQE. The codec filters those entries before
      // selecting the wire layout; only null handles remain malformed.  The
      // same rule applies to IB_SEND_INLINE with payload_len==0: the driver
      // still publishes a legal inline-marked WQE.
      foreach (sges[i]) begin
        if (sges[i] == null)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "SQE SGE handle is null");
      end
    end

    return rdma_status::success();
  endfunction

  // 功能：validate 校验 SQE 模型的句柄、transport、opcode、payload 和 SGE
  //   形状，确认它可以进入对应的硬件编码器。
  // 输入/输出及副作用：无显式参数；只读 opcode、qp_h、transport、inline_data、
  //   payload、sges 和 transport_ext，返回 rdma_status，不取得句柄、队列或 DMA 所有权。
  // 失败/边界：QP/transport extension 缺失、opcode 不适配、null SGE 或 READ/atomic
  //   形状非法时返回 INVALID_ARGUMENT/UNSUPPORTED_OPCODE；普通 SEND/WRITE 的零
  //   SGE、零长度 SGE 和 zero-byte inline 按驱动规则允许，失败不提交部分状态。
  virtual function rdma_status validate();
    rdma_sqe_rc_ext rc_ext;
    rdma_sqe_ud_ext ud_ext;
    rdma_sqe_urc_ext urc_ext;
    rdma_status shape_status;

    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQE requires a QP handle");
    if (!rdma_send_opcode_valid_for_transport(transport, opcode))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "SQE opcode is unsupported for transport");
    shape_status = validate_payload_shape();
    if (!shape_status.ok())
      return shape_status;
    if (transport_ext == null || transport_ext.transport_kind() != transport)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQE transport extension does not match");
    case (transport)
      RDMA_TRANSPORT_RC:
        if (!$cast(rc_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "RC SQE lacks RC extension");
      RDMA_TRANSPORT_UD:
        if (!$cast(ud_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "UD SQE lacks UD extension");
      RDMA_TRANSPORT_URC:
        if (!$cast(urc_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "URC SQE lacks URC extension");
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SQE transport is unsupported");
    endcase
    return transport_ext.validate(opcode);
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    string extension_text;

    extension_text = (transport_ext == null) ? "null"
                                             : transport_ext.describe();
    return $sformatf("SQE(transport=%s opcode=%s wr_id=%0d %s)",
                     transport.name(), opcode.name(), wr_id, extension_text);
  endfunction
endclass

class rdma_rqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_rqe_model)

  rdma_handle target_h;
  longint unsigned wr_id;
  rdma_sge sges[$];

  // 功能：构造 rdma_rqe_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：target_h=null；wr_id='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_rqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_rqe_model");
    super.new(name);
    target_h = null;
    wr_id = '0;
  endfunction

  // 功能：将 rhs 中 rdma_rqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（RQE model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_rqe_model rhs_rqe;
    uvm_object cloned_object;
    rdma_sge cloned_sge;

    super.do_copy(rhs);
    if (!$cast(rhs_rqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "RQE model copy mismatch")
    target_h = rdma_clone_handle_value(rhs_rqe.target_h, "RQE target");
    wr_id = rhs_rqe.wr_id;
    sges.delete();
    foreach (rhs_rqe.sges[i]) begin
      if (rhs_rqe.sges[i] == null) begin
        sges.push_back(null);
      end
      else begin
        cloned_object = rhs_rqe.sges[i].clone();
        if (cloned_object == null || !$cast(cloned_sge, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "RQE SGE clone mismatch")
        sges.push_back(cloned_sge);
      end
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“RQE requires a QP or SRQ handle”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、target_h、target_h.kind、sges、length 并使用字段 rdma_status、target_h、target_h.kind、sges、length；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为
  // “RQE requires a QP or SRQ handle”或 SGE 句柄为空。驱动允许 num_sge=0，
  // 因而 sges 为空表示合法的空 payload RQE；若调用方显式放入 SGE，则每个
  // 元素仍必须为非空句柄，零长度元素交由 codec 按 wr.c 规则过滤。
  virtual function rdma_status validate();
    if (target_h == null ||
        !(target_h.kind inside {RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RQE requires a QP or SRQ handle");
    foreach (sges[i]) begin
      if (sges[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RQE SGE handle is null");
    end
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("RQE(wr_id=%0d sge_count=%0d)", wr_id, sges.size());
  endfunction
endclass

class rdma_cqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_cqe_model)

  rdma_handle qp_h;
  longint unsigned wr_id;
  rdma_work_opcode_e opcode;
  rdma_status status;
  int unsigned byte_len;
  bit [31:0] immediate_data;

  // 功能：构造 rdma_cqe_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：qp_h=null；wr_id='0；opcode=RDMA_WR_SEND；status=null；byte_len='0；immediate_data='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cqe_model");
    super.new(name);
    qp_h = null;
    wr_id = '0;
    opcode = RDMA_WR_SEND;
    status = null;
    byte_len = '0;
    immediate_data = '0;
  endfunction

  // 功能：将 rhs 中 rdma_cqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CQE model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cqe_model rhs_cqe;

    super.do_copy(rhs);
    if (!$cast(rhs_cqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQE model copy mismatch")
    qp_h = rdma_clone_handle_value(rhs_cqe.qp_h, "CQE QP");
    wr_id = rhs_cqe.wr_id;
    opcode = rhs_cqe.opcode;
    status = rdma_clone_status_value(rhs_cqe.status);
    byte_len = rhs_cqe.byte_len;
    immediate_data = rhs_cqe.immediate_data;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CQE requires QP handle and status”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、qp_h、qp_h.kind、opcode 并使用字段 rdma_status、qp_h、qp_h.kind、opcode；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQE requires QP handle and status”“CQE work opcode is invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP || status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQE requires QP handle and status");
    if (!(opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                         RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                         RDMA_WR_RDMA_READ, RDMA_WR_ATOMIC_CMP_SWAP,
                         RDMA_WR_ATOMIC_FETCH_ADD,
                         RDMA_WR_LOCAL_INVALIDATE, RDMA_WR_RECV}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQE work opcode is invalid");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("CQE(wr_id=%0d opcode=%s byte_len=%0d)",
                     wr_id, opcode.name(), byte_len);
  endfunction
endclass

class rdma_ceqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_ceqe_model)

  rdma_handle cq_h;
  int unsigned producer_index;
  bit wrap;
  bit solicited;

  // 功能：构造 rdma_ceqe_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：cq_h=null；producer_index='0；wrap=1'b0；solicited=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_ceqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_ceqe_model");
    super.new(name);
    cq_h = null;
    producer_index = '0;
    wrap = 1'b0;
    solicited = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_ceqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CEQE model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_ceqe_model rhs_ceqe;

    super.do_copy(rhs);
    if (!$cast(rhs_ceqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQE model copy mismatch")
    cq_h = rdma_clone_handle_value(rhs_ceqe.cq_h, "CEQE CQ");
    producer_index = rhs_ceqe.producer_index;
    wrap = rhs_ceqe.wrap;
    solicited = rhs_ceqe.solicited;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CEQE requires a CQ handle”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、cq_h、cq_h.kind 并使用字段 rdma_status、cq_h、cq_h.kind；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CEQE requires a CQ handle”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQE requires a CQ handle");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("CEQE(producer_index=%0d wrap=%0b)",
                     producer_index, wrap);
  endfunction
endclass

class rdma_aeqe_model extends rdma_hw_model;
  `uvm_object_utils(rdma_aeqe_model)

  rdma_handle target_h;
  int unsigned event_code;
  int unsigned syndrome;
  rdma_severity_e severity;

  // 功能：构造 rdma_aeqe_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：target_h=null；event_code='0；syndrome='0；severity=RDMA_SEVERITY_INFO。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_aeqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_aeqe_model");
    super.new(name);
    target_h = null;
    event_code = '0;
    syndrome = '0;
    severity = RDMA_SEVERITY_INFO;
  endfunction

  // 功能：将 rhs 中 rdma_aeqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（AEQE model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_aeqe_model rhs_aeqe;

    super.do_copy(rhs);
    if (!$cast(rhs_aeqe, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQE model copy mismatch")
    target_h = rdma_clone_handle_value(rhs_aeqe.target_h, "AEQE target");
    event_code = rhs_aeqe.event_code;
    syndrome = rhs_aeqe.syndrome;
    severity = rhs_aeqe.severity;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“AEQE target handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、target_h、severity 并使用字段 rdma_status、target_h、severity；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“AEQE target handle is null”“AEQE severity is invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQE target handle is null");
    if (!(severity inside {RDMA_SEVERITY_INFO, RDMA_SEVERITY_WARNING,
                           RDMA_SEVERITY_ERROR, RDMA_SEVERITY_FATAL}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQE severity is invalid");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("AEQE(event_code=%0d syndrome=%0d severity=%s)",
                     event_code, syndrome, severity.name());
  endfunction
endclass

class rdma_doorbell_model extends rdma_hw_model;
  `uvm_object_utils(rdma_doorbell_model)

  rdma_doorbell_kind_e kind;
  rdma_handle target_h;
  int unsigned queue_id;
  bit queue_id_valid;
  int unsigned producer_index;
  bit wrap;
  bit arm;
  bit solicited_only;

  // 功能：构造 rdma_doorbell_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：kind=RDMA_DOORBELL_CMQ_SQ；target_h=null；queue_id='0；queue_id_valid=1'b0；producer_index='0；wrap=1'b0；arm=1'b0；solicited_only=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_doorbell_model");
    super.new(name);
    kind = RDMA_DOORBELL_CMQ_SQ;
    target_h = null;
    queue_id = '0;
    queue_id_valid = 1'b0;
    producer_index = '0;
    wrap = 1'b0;
    arm = 1'b0;
    solicited_only = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_doorbell_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（doorbell model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_doorbell_model rhs_doorbell;

    super.do_copy(rhs);
    if (!$cast(rhs_doorbell, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "doorbell model copy mismatch")
    kind = rhs_doorbell.kind;
    target_h = rdma_clone_handle_value(rhs_doorbell.target_h,
                                       "doorbell target");
    queue_id = rhs_doorbell.queue_id;
    queue_id_valid = rhs_doorbell.queue_id_valid;
    producer_index = rhs_doorbell.producer_index;
    wrap = rhs_doorbell.wrap;
    arm = rhs_doorbell.arm;
    solicited_only = rhs_doorbell.solicited_only;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“doorbell kind is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、kind、target_h、target_h.kind 并使用字段 rdma_status、kind、target_h、target_h.kind；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“doorbell kind is invalid”“doorbell target handle is null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (!(kind inside {RDMA_DOORBELL_CMQ_SQ, RDMA_DOORBELL_SQ,
                       RDMA_DOORBELL_RQ, RDMA_DOORBELL_SRQ,
                       RDMA_DOORBELL_CQ, RDMA_DOORBELL_CEQ,
                       RDMA_DOORBELL_AEQ, RDMA_DOORBELL_QP_FLUSH,
                       RDMA_DOORBELL_TX_FLUSH,
                       RDMA_DOORBELL_RTS2SQD,
                       RDMA_DOORBELL_SQD2RTS}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell kind is invalid");
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell target handle is null");
    case (kind)
      RDMA_DOORBELL_CMQ_SQ:
        if (target_h.kind != RDMA_RESOURCE_CMQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CMQ doorbell requires a CMQ target");
      RDMA_DOORBELL_SQ,
      RDMA_DOORBELL_RQ,
      RDMA_DOORBELL_QP_FLUSH,
      RDMA_DOORBELL_TX_FLUSH,
      RDMA_DOORBELL_RTS2SQD,
      RDMA_DOORBELL_SQD2RTS:
        if (target_h.kind != RDMA_RESOURCE_QP)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "QP doorbell requires a QP target");
      RDMA_DOORBELL_SRQ:
        if (target_h.kind != RDMA_RESOURCE_SRQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "SRQ doorbell requires an SRQ target");
      RDMA_DOORBELL_CQ:
        if (target_h.kind != RDMA_RESOURCE_CQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CQ doorbell requires a CQ target");
      RDMA_DOORBELL_CEQ:
        if (target_h.kind != RDMA_RESOURCE_CEQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "CEQ doorbell requires a CEQ target");
      RDMA_DOORBELL_AEQ:
        if (target_h.kind != RDMA_RESOURCE_AEQ)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "AEQ doorbell requires an AEQ target");
      default: begin
      end
    endcase
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("DOORBELL(kind=%s queue_id=%0d producer=%0d wrap=%0b)",
                     kind.name(), queue_id, producer_index, wrap);
  endfunction
endclass
