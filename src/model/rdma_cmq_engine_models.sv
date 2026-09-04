// 目录：协议与资源模型层 model/rdma_cmq_engine_models.sv。
// 职责：实现 rdma_cmq_engine_models 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_cmq_engine_models.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [2:0] {
  RDMA_CMQ_ENGINE_UNCONFIGURED,
  RDMA_CMQ_ENGINE_PREPARED,
  RDMA_CMQ_ENGINE_ACTIVE,
  RDMA_CMQ_ENGINE_QUIESCED,
  RDMA_CMQ_ENGINE_POISONED
} rdma_cmq_engine_state_e;

typedef enum bit [1:0] {
  RDMA_CMQ_DIAG_LATE_COMPLETION,
  RDMA_CMQ_DIAG_MALFORMED_CQE,
  RDMA_CMQ_DIAG_UNKNOWN_CQE,
  RDMA_CMQ_DIAG_POISON
} rdma_cmq_diagnostic_kind_e;

  // 功能：处理 rdma_cmq_string_has_separator：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 i 用于执行 rdma_cmq_string_has_separator；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_string_has_separator 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic bit rdma_cmq_string_has_separator(string value);
  for (int unsigned i = 0; i < value.len(); i++) begin
    if (value.getc(i) == 8'h7c)
      return 1'b1;
  end
  return 1'b0;
endfunction

  // 功能：处理 rdma_cmq_function_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 function_h, label 用于执行 rdma_cmq_function_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_function_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_status rdma_cmq_function_status(
  rdma_function_handle function_h,
  string label
);
  if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " Function handle is invalid"});
  if (function_h.generation == 0)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             {label, " Function generation is zero"});
  return rdma_status::success();
endfunction

  // 功能：处理 rdma_cmq_handle_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 cmq_h, function_h, label 用于执行 rdma_cmq_handle_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_handle_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_status rdma_cmq_handle_status(
  rdma_handle cmq_h,
  rdma_function_handle function_h,
  string label
);
  rdma_status status;

  if (cmq_h == null || cmq_h.kind != RDMA_RESOURCE_CMQ)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " CMQ handle is invalid"});
  status = rdma_handle_owner_status(cmq_h, function_h);
  if (!status.ok())
    return status;
  return rdma_status::success();
endfunction

  // 功能：处理 rdma_cmq_clone_image_value：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source, label 用于执行 rdma_cmq_clone_image_value；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_clone_image_value 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_hw_image rdma_cmq_clone_image_value(
  rdma_hw_image source,
  string label
);
  uvm_object cloned_object;
  rdma_hw_image result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " image clone mismatch"})
  return result;
endfunction

  // 功能：处理 rdma_cmq_clone_hw_model_value：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source, label 用于执行 rdma_cmq_clone_hw_model_value；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_clone_hw_model_value 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_hw_model rdma_cmq_clone_hw_model_value(
  rdma_hw_model source,
  string label
);
  uvm_object cloned_object;
  rdma_hw_model result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " hardware model clone mismatch"})
  return result;
endfunction

  // 功能：处理 rdma_cmq_clone_object_value：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source, label 用于执行 rdma_cmq_clone_object_value；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_clone_object_value 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic uvm_object rdma_cmq_clone_object_value(
  uvm_object source,
  string label
);
  uvm_object result;

  if (source == null)
    return null;
  result = source.clone();
  if (result == null)
    `uvm_fatal("RDMA_COPY_TYPE", {label, " object clone returned null"})
  return result;
endfunction

  // 功能：处理 rdma_cmq_clone_status_value：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source 用于执行 rdma_cmq_clone_status_value；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_clone_status_value 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_status rdma_cmq_clone_status_value(
  rdma_status source
);
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

class rdma_cmq_opcode_key extends uvm_object;
  `uvm_object_utils(rdma_cmq_opcode_key)

  string profile_name;
  bit [31:0] opcode;
  string variant;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_opcode_key");
    super.new(name);
    profile_name = "";
    opcode = '0;
    variant = "";
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_opcode_key rhs_key;

    super.do_copy(rhs);
    if (!$cast(rhs_key, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ opcode key copy mismatch")
    profile_name = rhs_key.profile_name;
    opcode = rhs_key.opcode;
    variant = rhs_key.variant;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    if (profile_name.len() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ profile name is empty");
    if (variant.len() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ opcode variant is empty");
    if (rdma_cmq_string_has_separator(profile_name))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ profile name contains '|'");
    if (rdma_cmq_string_has_separator(variant))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ opcode variant contains '|'");
    return rdma_status::success();
  endfunction
endclass

  // 功能：处理 rdma_cmq_clone_opcode_key_value：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source, label 用于执行 rdma_cmq_clone_opcode_key_value；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_clone_opcode_key_value 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_cmq_opcode_key rdma_cmq_clone_opcode_key_value(
  rdma_cmq_opcode_key source,
  string label
);
  uvm_object cloned_object;
  rdma_cmq_opcode_key result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " opcode key clone mismatch"})
  return result;
endfunction

class rdma_cmq_command_desc extends uvm_object;
  `uvm_object_utils(rdma_cmq_command_desc)

  rdma_function_handle function_h;
  rdma_cmq_opcode_key opcode_key;
  rdma_hw_model body;
  rdma_hw_image qpc_signature_source;
  bit vfid_override;
  bit [10:0] use_vfid;
  time timeout;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_command_desc");
    super.new(name);
    function_h = null;
    opcode_key = null;
    body = null;
    qpc_signature_source = null;
    vfid_override = 1'b0;
    use_vfid = '0;
    timeout = 0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_command_desc rhs_command;

    super.do_copy(rhs);
    if (!$cast(rhs_command, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ command descriptor copy mismatch")
    function_h = rdma_clone_function_handle_value(rhs_command.function_h,
                                                   "CMQ command");
    opcode_key = rdma_cmq_clone_opcode_key_value(rhs_command.opcode_key,
                                                  "CMQ command");
    body = rdma_cmq_clone_hw_model_value(rhs_command.body, "CMQ command");
    qpc_signature_source = rdma_cmq_clone_image_value(
      rhs_command.qpc_signature_source, "CMQ command QPC signature source"
    );
    vfid_override = rhs_command.vfid_override;
    use_vfid = rhs_command.use_vfid;
    timeout = rhs_command.timeout;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    rdma_status status;

    status = rdma_cmq_function_status(function_h, "CMQ command");
    if (!status.ok())
      return status;
    if (opcode_key == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command opcode key is null");
    status = opcode_key.validate();
    if (!status.ok())
      return status;
    if (body == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command body is null");
    status = body.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CMQ command body returned null status");
    if (!status.ok())
      return status;
    if (timeout == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ command timeout is zero");
    if (qpc_signature_source != null &&
        qpc_signature_source.function_generation != function_h.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ QPC signature source generation does not match Function"
      );
    return rdma_status::success();
  endfunction
endclass

class rdma_cmq_slot_context extends uvm_object;
  `uvm_object_utils(rdma_cmq_slot_context)

  rdma_function_handle function_h;
  rdma_handle cmq_h;
  rdma_backing_addr_t backing_addr;
  longint unsigned relative_offset;
  longint unsigned slot_sequence;
  int unsigned sq_index;
  bit sq_wrap;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_slot_context");
    super.new(name);
    function_h = null;
    cmq_h = null;
    backing_addr = '0;
    relative_offset = '0;
    slot_sequence = '0;
    sq_index = '0;
    sq_wrap = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_slot_context rhs_slot;

    super.do_copy(rhs);
    if (!$cast(rhs_slot, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ slot context copy mismatch")
    function_h = rdma_clone_function_handle_value(rhs_slot.function_h,
                                                   "CMQ slot");
    cmq_h = rdma_clone_handle_value(rhs_slot.cmq_h, "CMQ slot");
    backing_addr = rhs_slot.backing_addr;
    relative_offset = rhs_slot.relative_offset;
    slot_sequence = rhs_slot.slot_sequence;
    sq_index = rhs_slot.sq_index;
    sq_wrap = rhs_slot.sq_wrap;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    rdma_status status;

    status = rdma_cmq_function_status(function_h, "CMQ slot");
    if (!status.ok())
      return status;
    status = rdma_cmq_handle_status(cmq_h, function_h, "CMQ slot");
    if (!status.ok())
      return status;
    if (sq_index >= 32)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ SQ slot index is outside depth 32");
    if ((relative_offset & 64'h3f) != 0 ||
        relative_offset != (longint'(sq_index) * 64))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ SQ slot offset is invalid");
    if ((backing_addr.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ SQ backing is not 64-byte aligned");
    if (sq_index != (slot_sequence % 32) ||
        sq_wrap != ((slot_sequence / 32) % 2))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ SQ slot sequence position is invalid");
    if (backing_addr.value >
        (64'hffff_ffff_ffff_ffff - relative_offset))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "CMQ SQ slot backing address overflows");
    return rdma_status::success();
  endfunction
endclass

class rdma_cmq_expected_response extends uvm_object;
  `uvm_object_utils(rdma_cmq_expected_response)

  bit [31:0] hardware_opcode;
  string variant;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_expected_response");
    super.new(name);
    hardware_opcode = '0;
    variant = "";
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_expected_response rhs_expected;

    super.do_copy(rhs);
    if (!$cast(rhs_expected, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ expected response copy mismatch")
    hardware_opcode = rhs_expected.hardware_opcode;
    variant = rhs_expected.variant;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    if (variant.len() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ expected response variant is empty");
    if (rdma_cmq_string_has_separator(variant))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ expected response variant contains '|'"
      );
    return rdma_status::success();
  endfunction
endclass

class rdma_cmq_decoded_cqe extends uvm_object;
  `uvm_object_utils(rdma_cmq_decoded_cqe)

  bit [31:0] hardware_opcode;
  int unsigned wqe_index;
  bit wqe_wrap;
  bit [31:0] hardware_ecode;
  rdma_status command_status;
  uvm_object response_payload;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_decoded_cqe");
    super.new(name);
    hardware_opcode = '0;
    wqe_index = '0;
    wqe_wrap = 1'b0;
    hardware_ecode = '0;
    command_status = null;
    response_payload = null;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_decoded_cqe rhs_decoded;

    super.do_copy(rhs);
    if (!$cast(rhs_decoded, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ decoded CQE copy mismatch")
    hardware_opcode = rhs_decoded.hardware_opcode;
    wqe_index = rhs_decoded.wqe_index;
    wqe_wrap = rhs_decoded.wqe_wrap;
    hardware_ecode = rhs_decoded.hardware_ecode;
    command_status = rdma_cmq_clone_status_value(rhs_decoded.command_status);
    response_payload = rdma_cmq_clone_object_value(
      rhs_decoded.response_payload, "CMQ decoded response payload"
    );
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    if (command_status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ decoded CQE status is null");
    if (wqe_index >= 32)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ decoded CQE WQE index exceeds 5 bits");
    return rdma_status::success();
  endfunction
endclass

class rdma_cmq_ticket extends uvm_object;
  `uvm_object_utils(rdma_cmq_ticket)

  longint unsigned command_id;
  rdma_function_handle function_h;
  rdma_handle cmq_h;
  longint unsigned slot_sequence;
  int unsigned sq_index;
  bit sq_wrap;
  rdma_cmq_opcode_key opcode_key;
  time absolute_deadline;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_ticket");
    super.new(name);
    command_id = '0;
    function_h = null;
    cmq_h = null;
    slot_sequence = '0;
    sq_index = '0;
    sq_wrap = 1'b0;
    opcode_key = null;
    absolute_deadline = 0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_ticket rhs_ticket;

    super.do_copy(rhs);
    if (!$cast(rhs_ticket, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ ticket copy mismatch")
    command_id = rhs_ticket.command_id;
    function_h = rdma_clone_function_handle_value(rhs_ticket.function_h,
                                                   "CMQ ticket");
    cmq_h = rdma_clone_handle_value(rhs_ticket.cmq_h, "CMQ ticket");
    slot_sequence = rhs_ticket.slot_sequence;
    sq_index = rhs_ticket.sq_index;
    sq_wrap = rhs_ticket.sq_wrap;
    opcode_key = rdma_cmq_clone_opcode_key_value(rhs_ticket.opcode_key,
                                                  "CMQ ticket");
    absolute_deadline = rhs_ticket.absolute_deadline;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    rdma_status status;

    if (command_id == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket command ID is zero");
    if (absolute_deadline == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket absolute deadline is zero");
    status = rdma_cmq_function_status(function_h, "CMQ ticket");
    if (!status.ok())
      return status;
    status = rdma_cmq_handle_status(cmq_h, function_h, "CMQ ticket");
    if (!status.ok())
      return status;
    if (opcode_key == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket opcode key is null");
    status = opcode_key.validate();
    if (!status.ok())
      return status;
    if (sq_index >= 32)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket SQ index is outside depth 32");
    if (sq_index != (slot_sequence % 32) ||
        sq_wrap != ((slot_sequence / 32) % 2))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ ticket SQ sequence position is invalid");
    return rdma_status::success();
  endfunction
endclass

  // 功能：处理 rdma_cmq_clone_ticket_value：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source, label 用于执行 rdma_cmq_clone_ticket_value；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_clone_ticket_value 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_cmq_ticket rdma_cmq_clone_ticket_value(
  rdma_cmq_ticket source,
  string label
);
  uvm_object cloned_object;
  rdma_cmq_ticket result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " ticket clone mismatch"})
  return result;
endfunction

  // 功能：处理 rdma_cmq_raw_cqe_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 raw_cqe, ticket, label 用于执行 rdma_cmq_raw_cqe_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_cmq_raw_cqe_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_status rdma_cmq_raw_cqe_status(
  rdma_hw_image raw_cqe,
  rdma_cmq_ticket ticket,
  string label
);
  if (raw_cqe == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE is null"});
  if (raw_cqe.length != 64 || raw_cqe.bytes.size() != 64)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE is not 64 bytes"});
  if (raw_cqe.alignment != 64)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE alignment is not 64 bytes"});
  if (!(raw_cqe.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE endian is invalid"});
  if (raw_cqe.image_kind != RDMA_IMAGE_CMQ_CQE ||
      raw_cqe.hardware_version == 0 ||
      raw_cqe.function_generation == 0 ||
      raw_cqe.write_target_kind != RDMA_HW_TARGET_NONE ||
      raw_cqe.backing_target.value != 0 ||
      raw_cqe.hmc_target.value != 0 || raw_cqe.bar_target.value != 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " raw CQE metadata is invalid"});
  if (ticket != null && ticket.function_h != null &&
      raw_cqe.function_generation != ticket.function_h.generation)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             {label, " raw CQE generation is stale"});
  return rdma_status::success();
endfunction

class rdma_cmq_completion extends uvm_object;
  `uvm_object_utils(rdma_cmq_completion)

  rdma_cmq_ticket ticket;
  rdma_status status;
  rdma_hw_image raw_cqe;
  uvm_object decoded_response;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_completion");
    super.new(name);
    ticket = null;
    status = null;
    raw_cqe = null;
    decoded_response = null;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_completion rhs_completion;

    super.do_copy(rhs);
    if (!$cast(rhs_completion, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ completion copy mismatch")
    ticket = rdma_cmq_clone_ticket_value(rhs_completion.ticket,
                                         "CMQ completion");
    status = rdma_cmq_clone_status_value(rhs_completion.status);
    raw_cqe = rdma_cmq_clone_image_value(rhs_completion.raw_cqe,
                                         "CMQ completion raw CQE");
    decoded_response = rdma_cmq_clone_object_value(
      rhs_completion.decoded_response, "CMQ completion decoded response"
    );
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    rdma_status validation_status;

    if (ticket == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ completion ticket is null");
    validation_status = ticket.validate();
    if (!validation_status.ok())
      return validation_status;
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ completion status is null");
    if (raw_cqe == null) begin
      if (!(status.code inside {RDMA_SC_TIMEOUT,
                                RDMA_SC_RESET_CANCELLED}))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ hardware completion has no raw CQE"
        );
      return rdma_status::success();
    end
    return rdma_cmq_raw_cqe_status(raw_cqe, ticket, "CMQ completion");
  endfunction
endclass

class rdma_cmq_diagnostic extends uvm_object;
  `uvm_object_utils(rdma_cmq_diagnostic)

  rdma_cmq_diagnostic_kind_e kind;
  rdma_cmq_ticket ticket;
  rdma_status status;
  rdma_hw_image raw_cqe;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_diagnostic");
    super.new(name);
    kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    ticket = null;
    status = null;
    raw_cqe = null;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_diagnostic rhs_diagnostic;

    super.do_copy(rhs);
    if (!$cast(rhs_diagnostic, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ diagnostic copy mismatch")
    kind = rhs_diagnostic.kind;
    ticket = rdma_cmq_clone_ticket_value(rhs_diagnostic.ticket,
                                         "CMQ diagnostic");
    status = rdma_cmq_clone_status_value(rhs_diagnostic.status);
    raw_cqe = rdma_cmq_clone_image_value(rhs_diagnostic.raw_cqe,
                                         "CMQ diagnostic raw CQE");
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    rdma_status validation_status;

    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ diagnostic status is null");
    if (kind == RDMA_CMQ_DIAG_LATE_COMPLETION && ticket == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "late CMQ completion has no ticket");
    if (ticket != null) begin
      validation_status = ticket.validate();
      if (!validation_status.ok())
        return validation_status;
    end
    return rdma_cmq_raw_cqe_status(raw_cqe, ticket, "CMQ diagnostic");
  endfunction
endclass

class rdma_cmq_runtime_desc extends uvm_object;
  `uvm_object_utils(rdma_cmq_runtime_desc)

  rdma_function_handle function_h;
  rdma_handle cmq_h;
  rdma_iova_t sq_iova;
  rdma_iova_t cq_iova;
  int unsigned sq_depth;
  int unsigned cq_depth;
  int unsigned entry_bytes;
  bit initial_sq_valid;
  bit initial_cq_owner;
  bit initial_doorbell_polarity;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_cmq_runtime_desc");
    super.new(name);
    function_h = null;
    cmq_h = null;
    sq_iova = '0;
    cq_iova = '0;
    sq_depth = '0;
    cq_depth = '0;
    entry_bytes = '0;
    initial_sq_valid = 1'b0;
    initial_cq_owner = 1'b0;
    initial_doorbell_polarity = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_runtime_desc rhs_runtime;

    super.do_copy(rhs);
    if (!$cast(rhs_runtime, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ runtime descriptor copy mismatch")
    function_h = rdma_clone_function_handle_value(rhs_runtime.function_h,
                                                   "CMQ runtime");
    cmq_h = rdma_clone_handle_value(rhs_runtime.cmq_h, "CMQ runtime");
    sq_iova = rhs_runtime.sq_iova;
    cq_iova = rhs_runtime.cq_iova;
    sq_depth = rhs_runtime.sq_depth;
    cq_depth = rhs_runtime.cq_depth;
    entry_bytes = rhs_runtime.entry_bytes;
    initial_sq_valid = rhs_runtime.initial_sq_valid;
    initial_cq_owner = rhs_runtime.initial_cq_owner;
    initial_doorbell_polarity = rhs_runtime.initial_doorbell_polarity;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    rdma_status status;

    status = rdma_cmq_function_status(function_h, "CMQ runtime");
    if (!status.ok())
      return status;
    status = rdma_cmq_handle_status(cmq_h, function_h, "CMQ runtime");
    if (!status.ok())
      return status;
    if (sq_depth != 32 || cq_depth != 32 || entry_bytes != 64)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ runtime geometry must be 32 entries by 64 bytes"
      );
    if (sq_iova.value > (64'hffff_ffff_ffff_ffff - 64'd2048))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "CMQ SQ-to-CQ IOVA addition overflows");
    if (cq_iova.value > (64'hffff_ffff_ffff_ffff - 64'd2047))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "CMQ CQ IOVA range overflows");
    if ((sq_iova.value & 64'hfff) != 0 ||
        (cq_iova.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ runtime IOVA alignment is invalid");
    if (cq_iova.value != (sq_iova.value + 64'd2048))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ CQ IOVA is not SQ IOVA plus 2048");
    return rdma_status::success();
  endfunction
endclass
