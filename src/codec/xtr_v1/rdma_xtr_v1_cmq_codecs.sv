// 目录：硬件编解码层 codec/xtr_v1/rdma_xtr_v1_cmq_codecs.sv。
// 职责：实现 rdma_xtr_v1_cmq_codecs 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_xtr_v1_cmq_codecs.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_cmq_envelope extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_cmq_envelope)

  bit valid;
  bit vfid_override;
  bit [10:0] use_vfid;
  bit wrap;
  bit [4:0] wqe_index;
  bit [7:0] opcode;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_envelope");
    super.new(name);
    valid = 1'b0;
    vfid_override = 1'b0;
    use_vfid = '0;
    wrap = 1'b0;
    wqe_index = '0;
    opcode = '0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_cmq_envelope rhs_envelope;
    super.do_copy(rhs);
    if (!$cast(rhs_envelope, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ envelope copy type mismatch")
    valid = rhs_envelope.valid;
    vfid_override = rhs_envelope.vfid_override;
    use_vfid = rhs_envelope.use_vfid;
    wrap = rhs_envelope.wrap;
    wqe_index = rhs_envelope.wqe_index;
    opcode = rhs_envelope.opcode;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    if (!vfid_override && use_vfid != 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "xtr_v1 CMQ use-vfid requires VFID override"
      );
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  function string describe();
    return $sformatf(
      "CMQ envelope(valid=%0b override=%0b vfid=%0d wrap=%0b index=%0d opcode=0x%02x)",
      valid, vfid_override, use_vfid, wrap, wqe_index, opcode
    );
  endfunction
endclass

class rdma_xtr_v1_cmq_completion extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_cmq_completion)

  bit owner;
  bit [7:0] opcode;
  bit [7:0] command_ecode;
  bit [4:0] wqe_index;
  bit wrap;
  byte unsigned object_payload[];

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_completion");
    super.new(name);
    owner = 1'b0;
    opcode = '0;
    command_ecode = '0;
    wqe_index = '0;
    wrap = 1'b0;
    object_payload = new[0];
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_cmq_completion rhs_completion;
    super.do_copy(rhs);
    if (!$cast(rhs_completion, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ completion copy type mismatch")
    owner = rhs_completion.owner;
    opcode = rhs_completion.opcode;
    command_ecode = rhs_completion.command_ecode;
    wqe_index = rhs_completion.wqe_index;
    wrap = rhs_completion.wrap;
    object_payload = rhs_completion.object_payload;
  endfunction
endclass

class rdma_xtr_v1_cmq_completion_codec extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_cmq_completion_codec)

  localparam bit [7:0] COMPLETION_KEY_QUERY_OPCODE = 8'h09;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_completion_codec");
    super.new(name);
  endfunction

  // 功能：处理 codec_error：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 message 用于执行 codec_error；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：codec_error 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：处理 image_qword：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, qword_index 用于执行 image_qword；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：image_qword 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function bit [63:0] image_qword(
    rdma_hw_image image,
    int unsigned qword_index
  );
    bit [63:0] value;
    int unsigned base;
    value = '0;
    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      value = {value[55:0], image.bytes[base + i]};
    return value;
  endfunction

  // Registered request opcodes plus the driver's response-only KEY_QUERY.
  // Keep completion admission independent of a mutable/injectable registry.
  // 功能：判断 supported_opcode 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：参数 inside 用于执行 supported_opcode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：supported_opcode 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  local function bit supported_opcode(bit [7:0] opcode);
    return opcode inside {
      XTR_V1_OP_QPC_CREATE, XTR_V1_OP_QPC_MODIFY,
      XTR_V1_OP_QPC_DELETE, XTR_V1_OP_QPC_QUERY,
      XTR_V1_OP_KEY_ALLOC, XTR_V1_OP_MR_REGISTER,
      XTR_V1_OP_MR_DEREGISTER, COMPLETION_KEY_QUERY_OPCODE,
      XTR_V1_OP_OCC_FLUSH,
      XTR_V1_OP_CQC_CREATE, XTR_V1_OP_CQC_DELETE,
      XTR_V1_OP_CQC_QUERY, XTR_V1_OP_CEQC_CREATE,
      XTR_V1_OP_CEQC_DELETE, XTR_V1_OP_CEQC_QUERY,
      XTR_V1_OP_AEQC_CREATE, XTR_V1_OP_AEQC_DELETE,
      XTR_V1_OP_AEQC_QUERY, XTR_V1_OP_TQ_FLUSH,
      XTR_V1_OP_SRFQC_CREATE, XTR_V1_OP_SRFQC_DELETE,
      XTR_V1_OP_SRFQC_QUERY
    };
  endfunction

  // 功能：处理 allowed_qword_mask：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 opcode, qword_index 用于执行 allowed_qword_mask；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：allowed_qword_mask 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function bit [63:0] allowed_qword_mask(
    bit [7:0] opcode,
    int unsigned qword_index
  );
    if (qword_index == 0)
      return 64'h8000_3fff_ff00_0000;
    case (opcode)
      COMPLETION_KEY_QUERY_OPCODE:
        if (qword_index inside {[2:7]})
          return 64'hffff_ffff_ffff_ffff;
      XTR_V1_OP_CQC_QUERY:
        return 64'hffff_ffff_ffff_ffff;
      XTR_V1_OP_CEQC_QUERY,
      XTR_V1_OP_AEQC_QUERY,
      XTR_V1_OP_SRFQC_QUERY:
        if (qword_index inside {[2:5]})
          return 64'hffff_ffff_ffff_ffff;
      default: return 64'h0000_0000_0000_0000;
    endcase
    return 64'h0000_0000_0000_0000;
  endfunction

  // 功能：处理 returned_payload_bounds：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 opcode, first_byte, byte_count 用于执行 returned_payload_bounds；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：returned_payload_bounds 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function void returned_payload_bounds(
    bit [7:0] opcode,
    output int unsigned first_byte,
    output int unsigned byte_count
  );
    first_byte = 0;
    byte_count = 0;
    case (opcode)
      COMPLETION_KEY_QUERY_OPCODE: begin
        first_byte = 16;
        byte_count = 48;
      end
      XTR_V1_OP_CQC_QUERY: begin
        first_byte = 8;
        byte_count = 56;
      end
      XTR_V1_OP_CEQC_QUERY,
      XTR_V1_OP_AEQC_QUERY,
      XTR_V1_OP_SRFQC_QUERY: begin
        first_byte = 16;
        byte_count = 32;
      end
      default: begin
        first_byte = 0;
        byte_count = 0;
      end
    endcase
  endfunction

  // 功能：处理 inspect_completion：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, expected_owner, ready, completion 用于执行 inspect_completion；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：inspect_completion 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status inspect_completion(
    rdma_hw_image image,
    bit expected_owner,
    output bit ready,
    output rdma_xtr_v1_cmq_completion completion
  );
    bit [63:0] qword0;
    bit [63:0] word;
    bit [7:0] opcode;
    bit owner;
    bit wrap;
    int unsigned first_byte;
    int unsigned byte_count;
    rdma_xtr_v1_cmq_completion candidate;

    ready = 1'b0;
    completion = null;
    if (image == null)
      return codec_error("xtr_v1 CMQ completion image is null");
    if (image.length != XTR_V1_CMQE_BYTES ||
        image.bytes.size() != XTR_V1_CMQE_BYTES)
      return codec_error("xtr_v1 CMQ completion length is not 64 bytes");
    if (image.alignment != XTR_V1_CMQE_BYTES ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_CMQ_CQE ||
        image.hardware_version != XTR_V1_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return codec_error("xtr_v1 CMQ completion metadata is invalid");
    qword0 = image_qword(image, 0);
    owner = qword0[63];
    if (owner != expected_owner)
      return rdma_status::success();
    opcode = (qword0 >> XTR_V1_CMQ_OPCODE_LSB) & 8'hff;
    wrap = (qword0 >> XTR_V1_CMQ_WRAP_LSB) & 1'b1;
    if (!supported_opcode(opcode))
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("unsupported xtr_v1 CMQ completion opcode 0x%02x", opcode)
      );

    for (int unsigned q = 0; q < 8; q++) begin
      word = image_qword(image, q);
      if ((word & ~allowed_qword_mask(opcode, q)) != 0)
        return codec_error($sformatf(
          "xtr_v1 CMQ completion qword %0d contains a reserved bit", q));
    end
    candidate = new("xtr_v1_cmq_completion");
    candidate.owner = owner;
    candidate.opcode = opcode;
    candidate.command_ecode =
      (qword0 >> XTR_V1_CMQ_CMD_ECODE_LSB) & 8'hff;
    candidate.wqe_index =
      (qword0 >> XTR_V1_CMQ_WQE_INDEX_LSB) & 5'h1f;
    candidate.wrap = wrap;
    returned_payload_bounds(opcode, first_byte, byte_count);
    candidate.object_payload = new[byte_count];
    foreach (candidate.object_payload[i])
      candidate.object_payload[i] = image.bytes[first_byte + i];
    completion = candidate;
    ready = 1'b1;
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_qpc_command_body extends rdma_hw_model;
  `uvm_object_utils(rdma_xtr_v1_qpc_command_body)

  rdma_handle qp_h;
  rdma_handle send_cq_h;
  rdma_handle recv_cq_h;
  rdma_backing_addr_t qpc_buffer;
  rdma_qp_state_e next_state;
  bit full_modify;
  bit partial_modify;
  bit [1:0] wbe_template_count;
  bit [5:0] modify_start_qword[4];
  bit [7:0] modify_wbe[4];
  bit [63:0] modify_data[4];

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_qpc_command_body");
    super.new(name);
    qp_h = null;
    send_cq_h = null;
    recv_cq_h = null;
    qpc_buffer = '0;
    next_state = RDMA_QPS_RESET;
    full_modify = 1'b0;
    partial_modify = 1'b0;
    wbe_template_count = '0;
    foreach (modify_start_qword[i]) begin
      modify_start_qword[i] = '0;
      modify_wbe[i] = '0;
      modify_data[i] = '0;
    end
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_qpc_command_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "QPC command body copy type mismatch")
    qp_h = rdma_clone_handle_value(rhs_body.qp_h, "QPC command QP");
    send_cq_h = rdma_clone_handle_value(rhs_body.send_cq_h,
                                        "QPC command send CQ");
    recv_cq_h = rdma_clone_handle_value(rhs_body.recv_cq_h,
                                        "QPC command receive CQ");
    qpc_buffer = rhs_body.qpc_buffer;
    next_state = rhs_body.next_state;
    full_modify = rhs_body.full_modify;
    partial_modify = rhs_body.partial_modify;
    wbe_template_count = rhs_body.wbe_template_count;
    foreach (modify_start_qword[i]) begin
      modify_start_qword[i] = rhs_body.modify_start_qword[i];
      modify_wbe[i] = rhs_body.modify_wbe[i];
      modify_data[i] = rhs_body.modify_data[i];
    end
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    rdma_status status;
    status = rdma_context_handle_status(qp_h, RDMA_RESOURCE_QP, 24,
                                        "QPC command QP");
    if (!status.ok()) return status;
    if (full_modify && partial_modify)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC modify modes are mutually exclusive");
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return $sformatf(
      "QPC command(qpn=%0d full=%0b partial=%0b next=%s buffer=0x%016x)",
      (qp_h == null) ? 0 : qp_h.object_id, full_modify, partial_modify,
      next_state.name(), qpc_buffer.value
    );
  endfunction
endclass

class rdma_xtr_v1_object_id_command_body extends rdma_hw_model;
  `uvm_object_utils(rdma_xtr_v1_object_id_command_body)

  rdma_handle object_h;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_object_id_command_body");
    super.new(name);
    object_h = null;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_object_id_command_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "object-ID command copy type mismatch")
    object_h = rdma_clone_handle_value(rhs_body.object_h,
                                       "object-ID command");
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    if (object_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "object-ID command handle is null");
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return $sformatf("object-ID command(kind=%s id=%0d)",
                     (object_h == null) ? "null" : object_h.kind.name(),
                     (object_h == null) ? 0 : object_h.object_id);
  endfunction
endclass

class rdma_xtr_v1_mr_deregister_body extends rdma_hw_model;
  `uvm_object_utils(rdma_xtr_v1_mr_deregister_body)

  rdma_handle mr_h;
  bit [7:0] stag_key;
  rdma_context_state_e next_state;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_mr_deregister_body");
    super.new(name);
    mr_h = null;
    stag_key = '0;
    next_state = RDMA_CONTEXT_INVALID;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_mr_deregister_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MR deregister body copy type mismatch")
    mr_h = rdma_clone_handle_value(rhs_body.mr_h, "MR deregister");
    stag_key = rhs_body.stag_key;
    next_state = rhs_body.next_state;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    rdma_status status;
    status = rdma_context_handle_status(mr_h, RDMA_RESOURCE_MR, 24,
                                        "MR deregister");
    if (!status.ok()) return status;
    if (!(next_state inside {RDMA_CONTEXT_INVALID, RDMA_CONTEXT_VALID}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR deregister next state is unsupported");
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return $sformatf("MR deregister(stag=%0d key=0x%02x next=%s)",
                     (mr_h == null) ? 0 : mr_h.object_id, stag_key,
                     next_state.name());
  endfunction
endclass

class rdma_xtr_v1_occ_flush_body extends rdma_hw_model;
  `uvm_object_utils(rdma_xtr_v1_occ_flush_body)

  bit vf_flush;
  bit mr_serial_flush;
  bit qpc;
  bit cqc;
  bit mrt;
  bit pble;
  bit sqrqe;
  bit sgb_irqe;
  bit eirqe;
  bit orqe;
  bit uaqe;
  bit pd;
  bit [20:0] qpn;
  bit [11:0] mr_serial;
  rdma_backing_addr_t pd_backing;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_occ_flush_body");
    super.new(name);
    vf_flush = 1'b0;
    mr_serial_flush = 1'b0;
    qpc = 1'b0;
    cqc = 1'b0;
    mrt = 1'b0;
    pble = 1'b0;
    sqrqe = 1'b0;
    sgb_irqe = 1'b0;
    eirqe = 1'b0;
    orqe = 1'b0;
    uaqe = 1'b0;
    pd = 1'b0;
    qpn = '0;
    mr_serial = '0;
    pd_backing = '0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_occ_flush_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "OCC flush body copy type mismatch")
    vf_flush = rhs_body.vf_flush;
    mr_serial_flush = rhs_body.mr_serial_flush;
    qpc = rhs_body.qpc;
    cqc = rhs_body.cqc;
    mrt = rhs_body.mrt;
    pble = rhs_body.pble;
    sqrqe = rhs_body.sqrqe;
    sgb_irqe = rhs_body.sgb_irqe;
    eirqe = rhs_body.eirqe;
    orqe = rhs_body.orqe;
    uaqe = rhs_body.uaqe;
    pd = rhs_body.pd;
    qpn = rhs_body.qpn;
    mr_serial = rhs_body.mr_serial;
    pd_backing = rhs_body.pd_backing;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    bit vf_pattern;
    bit serial_pattern;
    bit qpn_pattern;
    bit qpn_pd_pattern;
    bit pd_pattern;

    if ((pd_backing.value & 64'hfff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "OCC PD backing is not 4 KiB aligned");

    vf_pattern = vf_flush && !mr_serial_flush &&
                 qpc && cqc && mrt && pble && sqrqe && sgb_irqe &&
                 eirqe && orqe && uaqe && !pd && qpn == 0 &&
                 mr_serial == 0 && pd_backing.value == 0;
    serial_pattern = !vf_flush && mr_serial_flush &&
                     !qpc && !cqc && !mrt && pble && !sqrqe &&
                     !sgb_irqe && !eirqe && !orqe && !uaqe && !pd &&
                     qpn == 0 && pd_backing.value == 0;
    qpn_pattern = !vf_flush && !mr_serial_flush &&
                  !qpc && !cqc && !mrt && !pble && !sqrqe &&
                  !sgb_irqe && eirqe && orqe && uaqe && !pd &&
                  qpn != 0 && mr_serial == 0 && pd_backing.value == 0;
    qpn_pd_pattern = !vf_flush && !mr_serial_flush &&
                     !qpc && !cqc && !mrt && !pble && !sqrqe &&
                     !sgb_irqe && !eirqe && !orqe && !uaqe && pd &&
                     qpn != 0 && mr_serial == 0 && pd_backing.value != 0;
    pd_pattern = !vf_flush && !mr_serial_flush &&
                 !qpc && !cqc && !mrt && !pble && !sqrqe &&
                 !sgb_irqe && !eirqe && !orqe && !uaqe && pd &&
                 qpn == 0 && mr_serial == 0 && pd_backing.value != 0;

    if (vf_pattern || serial_pattern || qpn_pattern ||
        qpn_pd_pattern || pd_pattern)
      return rdma_status::success();
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      "OCC flush does not match a supported driver command pattern"
    );
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return $sformatf(
      "OCC flush(vf=%0b mr_serial=%0b qpn=%0d serial=%0d pd=0x%016x)",
      vf_flush, mr_serial_flush, qpn, mr_serial, pd_backing.value
    );
  endfunction
endclass

class rdma_xtr_v1_cmq_empty_body extends rdma_hw_model;
  `uvm_object_utils(rdma_xtr_v1_cmq_empty_body)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_empty_body");
    super.new(name);
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_cmq_empty_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "empty CMQ body copy type mismatch")
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return "xtr_v1 empty CMQ command body";
  endfunction
endclass

class rdma_xtr_v1_cmq_body_token extends uvm_object;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_body_token");
    super.new(name);
  endfunction
endclass

class rdma_xtr_v1_cmq_body_image extends rdma_hw_image;
  `uvm_object_utils(rdma_xtr_v1_cmq_body_image)

  local rdma_xtr_v1_cmq_body_token producer_token;
  local bit [7:0] producer_opcode;
  local rdma_hw_image immutable_snapshot;
  local bit initialized;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_body_image");
    super.new(name);
    producer_token = null;
    producer_opcode = '0;
    immutable_snapshot = null;
    initialized = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    super.do_copy(rhs);
  endfunction

  // 功能：处理 matches_snapshot：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 immutable_snapshot 用于执行 matches_snapshot；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：matches_snapshot 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function bit matches_snapshot();
    if (immutable_snapshot == null ||
        bytes.size() != immutable_snapshot.bytes.size() ||
        field_summary.size() != immutable_snapshot.field_summary.size())
      return 1'b0;
    if (length != immutable_snapshot.length ||
        alignment != immutable_snapshot.alignment ||
        endian != immutable_snapshot.endian ||
        image_kind != immutable_snapshot.image_kind ||
        hardware_version != immutable_snapshot.hardware_version ||
        function_generation != immutable_snapshot.function_generation ||
        write_target_kind != immutable_snapshot.write_target_kind ||
        backing_target.value != immutable_snapshot.backing_target.value ||
        hmc_target.value != immutable_snapshot.hmc_target.value ||
        bar_target.value != immutable_snapshot.bar_target.value)
      return 1'b0;
    foreach (bytes[i])
      if (bytes[i] != immutable_snapshot.bytes[i]) return 1'b0;
    foreach (field_summary[i])
      if (field_summary[i] != immutable_snapshot.field_summary[i])
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：处理 initialize_once：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 token, opcode 用于执行 initialize_once；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：initialize_once 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status initialize_once(
    rdma_xtr_v1_cmq_body_token token,
    bit [7:0] opcode
  );
    if (initialized)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "CMQ body artifact is already initialized"
      );
    if (token == null)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "CMQ body artifact producer token is null"
      );
    producer_token = token;
    producer_opcode = opcode;
    immutable_snapshot = new("xtr_v1_registered_cmq_body_snapshot");
    immutable_snapshot.copy(this);
    initialized = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：处理 authenticate：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 token, opcode 用于执行 authenticate；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：authenticate 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status authenticate(
    rdma_xtr_v1_cmq_body_token token,
    bit [7:0] opcode
  );
    if (!initialized || producer_token == null || token == null ||
        producer_token != token)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "CMQ body artifact is not registered by this composer"
      );
    if (producer_opcode != opcode)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "CMQ body artifact opcode is not exact"
      );
    if (!matches_snapshot())
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "CMQ body artifact changed after build"
      );
    return rdma_status::success();
  endfunction
endclass

virtual class rdma_xtr_v1_cmq_light_layout_codec extends uvm_object;
  localparam int unsigned BODY_BYTES = 64;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_light_layout_codec");
    super.new(name);
  endfunction

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：处理 codec_error：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 message 用于执行 codec_error；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：codec_error 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 builder, word_byte_offset, lsb, width, value 用于执行 put；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
  protected function rdma_status put(
    rdma_xtr_v1_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    bit [63:0] value
  );
    rdma_status status;
    status = builder.put_field(word_byte_offset, lsb, width, value);
    if (!status.ok())
      return codec_error({"CMQ light-body field write failed: ",
                          status.message});
    return status;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected pure virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 opcode, model, builder 用于执行 encode_fields；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  protected pure virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_xtr_v1_qword_builder builder
  );
  // 功能：处理 owner_generation：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 model 用于执行 owner_generation；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：owner_generation 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected pure virtual function int unsigned owner_generation(
    rdma_hw_model model
  );

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 opcode, model, image 用于执行 encode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  function rdma_status encode(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_xtr_v1_qword_builder builder;
    rdma_status status;
    byte unsigned payload[];
    bit [63:0] words[];
    bit [63:0] allowed;
    rdma_hw_image candidate;

    image = null;
    status = validate_for_opcode(opcode, model);
    if (!status.ok()) return status;
    builder = new("cmq_light_body_builder");
    status = builder.reset(BODY_BYTES);
    if (!status.ok()) return codec_error(status.message);
    status = encode_fields(opcode, model, builder);
    if (!status.ok()) return status;
    builder.get_words(words);
    foreach (words[q]) begin
      allowed = '0;
      if (!body_mask(RDMA_IMAGE_CMQ_SQE, opcode, 0, q, allowed))
        return codec_error("CMQ light-body mask lookup failed");
      if ((words[q] & ~allowed) != 0)
        return codec_error($sformatf(
          "CMQ light-body qword %0d writes outside its mask", q));
      if ((words[q] & request_envelope_mask(q)) != 0)
        return codec_error("CMQ light body writes request envelope bits");
    end
    payload = new[0];
    status = builder.serialize(payload);
    if (!status.ok()) return codec_error(status.message);
    candidate = rdma_hw_image::type_id::create("xtr_v1_cmq_light_body");
    foreach (payload[i]) candidate.bytes.push_back(payload[i]);
    candidate.length = BODY_BYTES;
    candidate.alignment = BODY_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_CMQ_SQE;
    candidate.hardware_version = XTR_V1_HW_VERSION;
    candidate.function_generation = owner_generation(model);
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    image = candidate;
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_cmq_qpc_layout_codec
    extends rdma_xtr_v1_cmq_light_layout_codec;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_qpc_layout_codec");
    super.new(name);
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 state, code 用于执行 encode_state；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  protected function rdma_status encode_state(
    rdma_qp_state_e state,
    output bit [2:0] code
  );
    case (state)
      RDMA_QPS_RESET: code = 3'd0;
      RDMA_QPS_INIT:  code = 3'd1;
      RDMA_QPS_RTR:   code = 3'd2;
      RDMA_QPS_RTS:   code = 3'd3;
      RDMA_QPS_ERROR: code = 3'd4;
      RDMA_QPS_SQD, RDMA_QPS_SQE: code = 3'd5;
      default: return invalid_argument("QPC command next state is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected function rdma_status validate_cq_handles(
    rdma_xtr_v1_qpc_command_body body
  );
    rdma_status status;
    status = rdma_context_handle_status(body.send_cq_h, RDMA_RESOURCE_CQ, 21,
                                        "QPC command send CQ");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(body.recv_cq_h, RDMA_RESOURCE_CQ, 21,
                                        "QPC command receive CQ");
    if (!status.ok()) return status;
    status = rdma_context_lifecycle_status(body.qp_h, body.send_cq_h,
                                           "QPC command send CQ");
    if (!status.ok()) return status;
    return rdma_context_lifecycle_status(body.qp_h, body.recv_cq_h,
                                         "QPC command receive CQ");
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected function rdma_status validate_buffer(
    rdma_xtr_v1_qpc_command_body body
  );
    if ((body.qpc_buffer.value & 64'h1ff) != 0)
      return invalid_argument("QPC command buffer is not 512-byte aligned");
    return rdma_status::success();
  endfunction

  // 功能：判断 has_modify_pairs 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：参数 body 用于执行 has_modify_pairs；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：has_modify_pairs 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit has_modify_pairs(
    rdma_xtr_v1_qpc_command_body body
  );
    foreach (body.modify_start_qword[i]) begin
      if (body.modify_start_qword[i] != 0 || body.modify_wbe[i] != 0)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：判断 has_modify_data 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：参数 body 用于执行 has_modify_data；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：has_modify_data 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit has_modify_data(
    rdma_xtr_v1_qpc_command_body body
  );
    foreach (body.modify_data[i])
      if (body.modify_data[i] != 0) return 1'b1;
    return 1'b0;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_xtr_v1_qpc_command_body body;
    rdma_status status;
    bit [2:0] state_code;
    if (!(opcode inside {XTR_V1_OP_QPC_CREATE, XTR_V1_OP_QPC_MODIFY,
                         XTR_V1_OP_QPC_DELETE, XTR_V1_OP_QPC_QUERY}))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "QPC light codec opcode is unsupported");
    if (!$cast(body, model))
      return invalid_argument(
        "QPC light codec requires rdma_xtr_v1_qpc_command_body"
      );
    status = body.validate();
    if (!status.ok()) return status;
    if (opcode != XTR_V1_OP_QPC_MODIFY &&
        (body.full_modify || body.partial_modify))
      return invalid_argument("QPC modify mode used by a non-modify opcode");
    case (opcode)
      XTR_V1_OP_QPC_CREATE: begin
        if (body.next_state != RDMA_QPS_RESET ||
            body.wbe_template_count != 0 || has_modify_pairs(body) ||
            has_modify_data(body))
          return invalid_argument(
            "QPC create contains modify-only fields"
          );
        status = validate_cq_handles(body);
        if (!status.ok()) return status;
        return validate_buffer(body);
      end
      XTR_V1_OP_QPC_MODIFY: begin
        status = validate_cq_handles(body);
        if (!status.ok()) return status;
        status = encode_state(body.next_state, state_code);
        if (!status.ok()) return status;
        if (body.full_modify) begin
          if (body.wbe_template_count > 1)
            return invalid_argument("QPC WBE template selector is invalid");
          if (has_modify_pairs(body) || has_modify_data(body))
            return invalid_argument(
              "full QPC modify contains partial-only fields"
            );
          return validate_buffer(body);
        end
        if (body.partial_modify) begin
          if (body.qpc_buffer.value != 0)
            return invalid_argument(
              "partial QPC modify contains an unused buffer"
            );
          if (body.wbe_template_count > 1)
            return invalid_argument("QPC WBE template selector is invalid");
        end
        else if (body.qpc_buffer.value != 0 ||
                 body.wbe_template_count != 0 || has_modify_pairs(body) ||
                 has_modify_data(body))
          return invalid_argument(
            "state-only QPC modify contains partial-only fields"
          );
      end
      XTR_V1_OP_QPC_DELETE: begin
        if (body.qpc_buffer.value != 0 ||
            body.next_state != RDMA_QPS_RESET ||
            body.wbe_template_count != 0 || has_modify_pairs(body) ||
            has_modify_data(body))
          return invalid_argument(
            "QPC delete contains create/modify/query fields"
          );
        return validate_cq_handles(body);
      end
      XTR_V1_OP_QPC_QUERY: begin
        if (body.send_cq_h != null || body.recv_cq_h != null ||
            body.next_state != RDMA_QPS_RESET ||
            body.wbe_template_count != 0 || has_modify_pairs(body) ||
            has_modify_data(body))
          return invalid_argument(
            "QPC query contains CQ or modify-only fields"
          );
        return validate_buffer(body);
      end
      default:
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "QPC light codec opcode is unsupported");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：处理 owner_generation：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 model 用于执行 owner_generation；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：owner_generation 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_xtr_v1_qpc_command_body body;
    if (!$cast(body, model) || body.qp_h == null) return 0;
    return body.qp_h.generation;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 opcode, model, builder 用于执行 encode_fields；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_xtr_v1_qword_builder builder
  );
    rdma_xtr_v1_qpc_command_body body;
    rdma_status status;
    bit [2:0] state_code;
    bit [1:0] modify_mode;
    if (!$cast(body, model))
      return invalid_argument("QPC command body cast failed");

`define CMQ_QPC_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    case (opcode)
      XTR_V1_OP_QPC_CREATE: begin
        `CMQ_QPC_PUT(XTR_V1_CMQ_QPN, body.qp_h.object_id)
        `CMQ_QPC_PUT(XTR_V1_CMQ_SQ_CQN, body.send_cq_h.object_id)
        `CMQ_QPC_PUT(XTR_V1_CMQ_SIGN_EN, 1)
        `CMQ_QPC_PUT(XTR_V1_CMQ_SIGNATURE, 0)
        `CMQ_QPC_PUT(XTR_V1_CMQ_RQ_CQN, body.recv_cq_h.object_id)
        `CMQ_QPC_PUT(XTR_V1_CMQ_QPC_BUFFER_ADDR,
                     body.qpc_buffer.value >> 9)
      end
      XTR_V1_OP_QPC_MODIFY: begin
        status = encode_state(body.next_state, state_code);
        if (!status.ok()) return status;
        modify_mode = body.full_modify ? XTR_V1_QPC_MODIFY_FULL :
                      body.partial_modify ? XTR_V1_QPC_MODIFY_PARTIAL :
                                            XTR_V1_QPC_MODIFY_STATE_ONLY;
        `CMQ_QPC_PUT(XTR_V1_CMQ_NEXT_QP_STATE, state_code)
        `CMQ_QPC_PUT(XTR_V1_CMQ_QPN, body.qp_h.object_id)
        `CMQ_QPC_PUT(XTR_V1_CMQ_SQ_CQN, body.send_cq_h.object_id)
        `CMQ_QPC_PUT(XTR_V1_CMQ_SIGN_EN, body.full_modify)
        `CMQ_QPC_PUT(XTR_V1_CMQ_SIGNATURE, 0)
        `CMQ_QPC_PUT(XTR_V1_CMQ_RQ_CQN, body.recv_cq_h.object_id)
        `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_MODE, modify_mode)
        `CMQ_QPC_PUT(XTR_V1_CMQ_WBE_TEMPLATE_COUNT,
                     body.wbe_template_count)
        if (body.full_modify) begin
          `CMQ_QPC_PUT(XTR_V1_CMQ_QPC_BUFFER_ADDR,
                       body.qpc_buffer.value >> 9)
        end
        else if (body.partial_modify) begin
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_START_QWORD0,
                       body.modify_start_qword[0])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_WBE0, body.modify_wbe[0])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_START_QWORD1,
                       body.modify_start_qword[1])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_WBE1, body.modify_wbe[1])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_START_QWORD2,
                       body.modify_start_qword[2])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_WBE2, body.modify_wbe[2])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_START_QWORD3,
                       body.modify_start_qword[3])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_WBE3, body.modify_wbe[3])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_DATA0, body.modify_data[0])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_DATA1, body.modify_data[1])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_DATA2, body.modify_data[2])
          `CMQ_QPC_PUT(XTR_V1_CMQ_MODIFY_DATA3, body.modify_data[3])
        end
      end
      XTR_V1_OP_QPC_DELETE: begin
        `CMQ_QPC_PUT(XTR_V1_CMQ_QPN, body.qp_h.object_id)
        `CMQ_QPC_PUT(XTR_V1_CMQ_SQ_CQN, body.send_cq_h.object_id)
        `CMQ_QPC_PUT(XTR_V1_CMQ_RQ_CQN, body.recv_cq_h.object_id)
      end
      XTR_V1_OP_QPC_QUERY: begin
        `CMQ_QPC_PUT(XTR_V1_CMQ_QPN, body.qp_h.object_id)
        `CMQ_QPC_PUT(XTR_V1_CMQ_QPC_BUFFER_ADDR,
                     body.qpc_buffer.value >> 9)
      end
      default:
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "QPC command opcode is unsupported");
    endcase
`undef CMQ_QPC_PUT
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_cmq_object_id_layout_codec
    extends rdma_xtr_v1_cmq_light_layout_codec;
  protected bit [7:0] fixed_opcode;
  protected rdma_resource_kind_e fixed_kind;
  protected int unsigned fixed_width;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(
    string name = "rdma_xtr_v1_cmq_object_id_layout_codec",
    bit [7:0] opcode = 0,
    rdma_resource_kind_e kind = RDMA_RESOURCE_CQ,
    int unsigned width = 21
  );
    super.new(name);
    fixed_opcode = opcode;
    fixed_kind = kind;
    fixed_width = width;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_xtr_v1_object_id_command_body body;
    rdma_status status;
    if (opcode != fixed_opcode)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "object-ID codec opcode does not match");
    if (!$cast(body, model))
      return invalid_argument(
        "object-ID codec requires rdma_xtr_v1_object_id_command_body"
      );
    status = body.validate();
    if (!status.ok()) return status;
    return rdma_context_handle_status(body.object_h, fixed_kind, fixed_width,
                                      "CMQ object-ID command");
  endfunction

  // 功能：处理 owner_generation：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 model 用于执行 owner_generation；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：owner_generation 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_xtr_v1_object_id_command_body body;
    if (!$cast(body, model) || body.object_h == null) return 0;
    return body.object_h.generation;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 opcode, model, builder 用于执行 encode_fields；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_xtr_v1_qword_builder builder
  );
    rdma_xtr_v1_object_id_command_body body;
    if (!$cast(body, model))
      return invalid_argument("object-ID command body cast failed");
    return put(builder, 0, 0, fixed_width, body.object_h.object_id);
  endfunction
endclass

class rdma_xtr_v1_cmq_mr_deregister_layout_codec
    extends rdma_xtr_v1_cmq_light_layout_codec;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_mr_deregister_layout_codec");
    super.new(name);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_xtr_v1_mr_deregister_body body;
    if (opcode != XTR_V1_OP_MR_DEREGISTER)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "MR deregister opcode does not match");
    if (!$cast(body, model))
      return invalid_argument(
        "MR deregister codec requires rdma_xtr_v1_mr_deregister_body"
      );
    return body.validate();
  endfunction

  // 功能：处理 owner_generation：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 model 用于执行 owner_generation；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：owner_generation 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_xtr_v1_mr_deregister_body body;
    if (!$cast(body, model) || body.mr_h == null) return 0;
    return body.mr_h.generation;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 opcode, model, builder 用于执行 encode_fields；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_xtr_v1_qword_builder builder
  );
    rdma_xtr_v1_mr_deregister_body body;
    rdma_status status;
    bit [1:0] state_code;
    if (!$cast(body, model))
      return invalid_argument("MR deregister body cast failed");
    case (body.next_state)
      RDMA_CONTEXT_INVALID: state_code = XTR_V1_MR_ST_INVALID;
      RDMA_CONTEXT_VALID: state_code = XTR_V1_MR_ST_VALID;
      default: return invalid_argument("MR deregister state is unsupported");
    endcase
`define CMQ_MR_DEREG_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `CMQ_MR_DEREG_PUT(XTR_V1_MRT_BODY_STAG_IDX, body.mr_h.object_id)
    `CMQ_MR_DEREG_PUT(XTR_V1_MRT_BODY_NXT_ST, state_code)
    `CMQ_MR_DEREG_PUT(XTR_V1_MRT_BODY_STAG_KEY, body.stag_key)
`undef CMQ_MR_DEREG_PUT
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_cmq_occ_flush_layout_codec
    extends rdma_xtr_v1_cmq_light_layout_codec;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_occ_flush_layout_codec");
    super.new(name);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_xtr_v1_occ_flush_body body;
    if (opcode != XTR_V1_OP_OCC_FLUSH)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "OCC flush opcode does not match");
    if (!$cast(body, model))
      return invalid_argument(
        "OCC codec requires rdma_xtr_v1_occ_flush_body"
      );
    return body.validate();
  endfunction

  // 功能：处理 owner_generation：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 model 用于执行 owner_generation；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：owner_generation 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    return 0;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 opcode, model, builder 用于执行 encode_fields；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_xtr_v1_qword_builder builder
  );
    rdma_xtr_v1_occ_flush_body body;
    rdma_status status;
    if (!$cast(body, model))
      return invalid_argument("OCC flush body cast failed");
`define CMQ_OCC_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_VF_FLUSH, body.vf_flush)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_MR_SERIAL_FLUSH, body.mr_serial_flush)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_QPN, body.qpn)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_QPC, body.qpc)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_CQC, body.cqc)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_MRT, body.mrt)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_PBLE, body.pble)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_SQRQE, body.sqrqe)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_SGB_IRQE, body.sgb_irqe)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_EIRQE, body.eirqe)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_ORQE, body.orqe)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_UAQE, body.uaqe)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_PD, body.pd)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_MR_SERIAL, body.mr_serial)
    `CMQ_OCC_PUT(XTR_V1_CMQ_OCC_PD_BACKING,
                 body.pd_backing.value >> 12)
`undef CMQ_OCC_PUT
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_cmq_empty_layout_codec
    extends rdma_xtr_v1_cmq_light_layout_codec;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_empty_layout_codec");
    super.new(name);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_xtr_v1_cmq_empty_body body;
    if (opcode != XTR_V1_OP_TQ_FLUSH)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "empty CMQ body opcode does not match");
    if (model == null)
      return rdma_status::success();
    if (!$cast(body, model))
      return invalid_argument(
        "TQ flush codec requires rdma_xtr_v1_cmq_empty_body"
      );
    return body.validate();
  endfunction

  // 功能：处理 owner_generation：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 model 用于执行 owner_generation；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：owner_generation 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    return 0;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 opcode, model, builder 用于执行 encode_fields；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_xtr_v1_qword_builder builder
  );
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_cmq_light_body_codec extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_cmq_light_body_codec)

  protected rdma_xtr_v1_cmq_light_layout_codec codecs[256];

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_light_body_codec");
    rdma_xtr_v1_cmq_qpc_layout_codec qpc_codec;
    rdma_xtr_v1_cmq_mr_deregister_layout_codec mr_deregister_codec;
    rdma_xtr_v1_cmq_occ_flush_layout_codec occ_flush_codec;
    rdma_xtr_v1_cmq_object_id_layout_codec object_id_codec;
    rdma_xtr_v1_cmq_empty_layout_codec empty_codec;
    super.new(name);
    foreach (codecs[i]) codecs[i] = null;
    qpc_codec = new("cmq_qpc_layout");
    codecs[XTR_V1_OP_QPC_CREATE] = qpc_codec;
    codecs[XTR_V1_OP_QPC_MODIFY] = qpc_codec;
    codecs[XTR_V1_OP_QPC_DELETE] = qpc_codec;
    codecs[XTR_V1_OP_QPC_QUERY] = qpc_codec;
    mr_deregister_codec = new("cmq_mr_deregister_layout");
    codecs[XTR_V1_OP_MR_DEREGISTER] = mr_deregister_codec;
    occ_flush_codec = new("cmq_occ_flush_layout");
    codecs[XTR_V1_OP_OCC_FLUSH] = occ_flush_codec;
    object_id_codec = new(
      "cmq_cqc_delete_layout", XTR_V1_OP_CQC_DELETE,
      RDMA_RESOURCE_CQ, 21);
    codecs[XTR_V1_OP_CQC_DELETE] = object_id_codec;
    object_id_codec = new(
      "cmq_cqc_query_layout", XTR_V1_OP_CQC_QUERY,
      RDMA_RESOURCE_CQ, 21);
    codecs[XTR_V1_OP_CQC_QUERY] = object_id_codec;
    object_id_codec = new(
      "cmq_ceqc_delete_layout", XTR_V1_OP_CEQC_DELETE,
      RDMA_RESOURCE_CEQ, 12);
    codecs[XTR_V1_OP_CEQC_DELETE] = object_id_codec;
    object_id_codec = new(
      "cmq_ceqc_query_layout", XTR_V1_OP_CEQC_QUERY,
      RDMA_RESOURCE_CEQ, 12);
    codecs[XTR_V1_OP_CEQC_QUERY] = object_id_codec;
    object_id_codec = new(
      "cmq_aeqc_delete_layout", XTR_V1_OP_AEQC_DELETE,
      RDMA_RESOURCE_AEQ, 12);
    codecs[XTR_V1_OP_AEQC_DELETE] = object_id_codec;
    object_id_codec = new(
      "cmq_aeqc_query_layout", XTR_V1_OP_AEQC_QUERY,
      RDMA_RESOURCE_AEQ, 12);
    codecs[XTR_V1_OP_AEQC_QUERY] = object_id_codec;
    empty_codec = new("cmq_tq_flush_layout");
    codecs[XTR_V1_OP_TQ_FLUSH] = empty_codec;
    object_id_codec = new(
      "cmq_srfqc_delete_layout", XTR_V1_OP_SRFQC_DELETE,
      RDMA_RESOURCE_SRQ, 16);
    codecs[XTR_V1_OP_SRFQC_DELETE] = object_id_codec;
    object_id_codec = new(
      "cmq_srfqc_query_layout", XTR_V1_OP_SRFQC_QUERY,
      RDMA_RESOURCE_SRQ, 16);
    codecs[XTR_V1_OP_SRFQC_QUERY] = object_id_codec;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 opcode, model, image 用于执行 encode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  function rdma_status encode(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    image = null;
    if (codecs[opcode] == null)
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("no xtr_v1 CMQ light body codec for opcode 0x%02x",
                  opcode)
      );
    return codecs[opcode].encode(opcode, model, image);
  endfunction
endclass

class rdma_xtr_v1_cmq_body_encoder extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_cmq_body_encoder)

  protected rdma_xtr_v1_cmq_light_body_codec light_codec;
  protected rdma_codec_registry context_codecs;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_body_encoder");
    rdma_status status;
    super.new(name);
    light_codec = rdma_xtr_v1_cmq_light_body_codec::type_id::create(
      "cmq_exact_light_body_codec");
    context_codecs = rdma_codec_registry::type_id::create(
      "cmq_exact_context_body_registry");
    status = rdma_xtr_v1_register_context_body_codecs(context_codecs);
    if (!status.ok())
      `uvm_fatal("RDMA_CMQ_REGISTRY", status.convert2string())
  endfunction

  // 功能：处理 context_key：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 key 用于执行 context_key；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：context_key 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_codec_key context_key(bit [7:0] opcode);
    rdma_codec_key key;
    key.hw_version = "xtr_v1";
    key.opcode = opcode;
    case (opcode)
      XTR_V1_OP_KEY_ALLOC: begin
        key.image_kind = RDMA_IMAGE_MRT;
        key.object_type = "mrt";
        key.variant = "key_alloc";
      end
      XTR_V1_OP_MR_REGISTER: begin
        key.image_kind = RDMA_IMAGE_MRT;
        key.object_type = "mrt";
        key.variant = "register";
      end
      XTR_V1_OP_CQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_CQC;
        key.object_type = "cqc";
        key.variant = "create";
      end
      XTR_V1_OP_CEQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_CEQC;
        key.object_type = "ceqc";
        key.variant = "create";
      end
      XTR_V1_OP_AEQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_AEQC;
        key.object_type = "aeqc";
        key.variant = "create";
      end
      XTR_V1_OP_SRFQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_SRQC;
        key.object_type = "srqc";
        key.variant = "create";
      end
      default: begin
        key.image_kind = RDMA_IMAGE_NONE;
        key.object_type = "invalid";
        key.variant = "invalid";
      end
    endcase
    return key;
  endfunction

  // 功能：判断 is_context_opcode 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：参数 XTR_V1_OP_KEY_ALLOC, XTR_V1_OP_MR_REGISTER 用于执行 is_context_opcode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：is_context_opcode 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit is_context_opcode(bit [7:0] opcode);
    return opcode inside {XTR_V1_OP_KEY_ALLOC, XTR_V1_OP_MR_REGISTER,
                          XTR_V1_OP_CQC_CREATE, XTR_V1_OP_CEQC_CREATE,
                          XTR_V1_OP_AEQC_CREATE, XTR_V1_OP_SRFQC_CREATE};
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 opcode, model, image 用于执行 encode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  function rdma_status encode(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_codec_base codec;
    rdma_status status;

    image = null;
    if (is_context_opcode(opcode)) begin
      status = context_codecs.lookup(context_key(opcode), codec);
      if (!status.ok() || codec == null)
        return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "CMQ exact context-body lookup failed");
      status = codec.encode(model, image);
    end
    else
      status = light_codec.encode(opcode, model, image);
    if (!status.ok()) return status;
    if (image == null)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ exact body encoder published null");
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_cmq_body_registry extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_cmq_body_registry)

  protected bit registered[256];
  protected rdma_image_kind_e input_kinds[256];
  protected bit [63:0] body_masks[256][8];
  protected bit sealed;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_body_registry");
    super.new(name);
    foreach (registered[i]) begin
      registered[i] = 1'b0;
      input_kinds[i] = RDMA_IMAGE_NONE;
      foreach (body_masks[i][q]) body_masks[i][q] = '0;
    end
    sealed = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_cmq_body_registry rhs_registry;
    if (sealed) return;
    super.do_copy(rhs);
    if (!$cast(rhs_registry, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ body registry copy type mismatch")
    registered = rhs_registry.registered;
    input_kinds = rhs_registry.input_kinds;
    body_masks = rhs_registry.body_masks;
    sealed = rhs_registry.sealed;
  endfunction

  // 功能：执行 set_entry_unchecked 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 opcode, input_kind, masks 用于执行 set_entry_unchecked；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：set_entry_unchecked 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void set_entry_unchecked(
    bit [7:0] opcode,
    rdma_image_kind_e input_kind,
    bit [63:0] masks[8]
  );
    registered[opcode] = 1'b1;
    input_kinds[opcode] = input_kind;
    foreach (masks[q]) body_masks[opcode][q] = masks[q];
  endfunction

  // 功能：处理 register_body：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 opcode, input_kind, masks 用于执行 register_body；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：register_body 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status register_body(
    bit [7:0] opcode,
    rdma_image_kind_e input_kind,
    bit [63:0] masks[8]
  );
    if (sealed)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CMQ body registry is sealed");
    if (registered[opcode]) begin
      `uvm_fatal("RDMA_CMQ_BODY_DUPLICATE",
                 $sformatf("duplicate CMQ body registration for opcode 0x%02x",
                           opcode))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "duplicate CMQ body registration");
    end
    if (!(input_kind inside {RDMA_IMAGE_CMQ_SQE, RDMA_IMAGE_CQC,
                             RDMA_IMAGE_MRT, RDMA_IMAGE_SRQC,
                             RDMA_IMAGE_CEQC, RDMA_IMAGE_AEQC}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ body input image kind is invalid");
    foreach (masks[q]) begin
      if ((masks[q] & request_envelope_mask(q)) != 0)
        return rdma_status::make(
          RDMA_SC_CODEC_ERROR,
          $sformatf("CMQ body opcode 0x%02x overlaps envelope qword %0d",
                    opcode, q)
        );
    end
    set_entry_unchecked(opcode, input_kind, masks);
    return rdma_status::success();
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function rdma_status lookup(
    bit [7:0] opcode,
    output rdma_image_kind_e input_kind,
    output bit [63:0] masks[8]
  );
    input_kind = RDMA_IMAGE_NONE;
    foreach (masks[q]) masks[q] = '0;
    if (!registered[opcode])
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("no xtr_v1 CMQ body registered for opcode 0x%02x", opcode)
      );
    input_kind = input_kinds[opcode];
    foreach (masks[q]) masks[q] = body_masks[opcode][q];
    return rdma_status::success();
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validated_snapshot(
    output rdma_xtr_v1_cmq_body_registry snapshot
  );
    rdma_status status;
    bit [63:0] masks[8];
    snapshot = rdma_xtr_v1_cmq_body_registry::type_id::create(
      "cmq_validated_body_registry_snapshot");
    foreach (registered[opcode]) begin
      if (!registered[opcode]) continue;
      foreach (masks[q]) masks[q] = body_masks[opcode][q];
      status = snapshot.register_body(opcode, input_kinds[opcode], masks);
      if (!status.ok()) begin
        snapshot = null;
        return status;
      end
    end
    snapshot.seal();
    return rdma_status::success();
  endfunction

  // 功能：处理 seal：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 sealed 用于执行 seal；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：seal 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function void seal();
    sealed = 1'b1;
  endfunction
endclass

  // 功能：处理 rdma_xtr_v1_register_cmq_request_bodies：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 registry 用于执行 rdma_xtr_v1_register_cmq_request_bodies；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_xtr_v1_register_cmq_request_bodies 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_status rdma_xtr_v1_register_cmq_request_bodies(
  rdma_xtr_v1_cmq_body_registry registry
);
  bit [63:0] masks[8];
  rdma_status status;

  if (registry == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "CMQ body registry is null");
`define CMQ_REGISTER_BODY(OPCODE, KIND, SOURCE_MASK) \
  foreach (masks[q]) masks[q] = SOURCE_MASK[q]; \
  status = registry.register_body(OPCODE, KIND, masks); \
  if (!status.ok()) return status;
  `CMQ_REGISTER_BODY(XTR_V1_OP_QPC_CREATE, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_QPC_CREATE_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_QPC_MODIFY, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_QPC_MODIFY_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_QPC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_QPC_DELETE_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_QPC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_QPC_QUERY_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_KEY_ALLOC, RDMA_IMAGE_MRT,
                     XTR_V1_MRT_KEY_ALLOC_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_MR_REGISTER, RDMA_IMAGE_MRT,
                     XTR_V1_MRT_REGISTER_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_MR_DEREGISTER, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_MR_DEREGISTER_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_OCC_FLUSH, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_OCC_FLUSH_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_CQC_CREATE, RDMA_IMAGE_CQC,
                     XTR_V1_CQC_CREATE_BODY_MASK)
  `CMQ_REGISTER_BODY(XTR_V1_OP_CQC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_CQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_CQC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_CQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_CEQC_CREATE, RDMA_IMAGE_CEQC,
                     XTR_V1_CEQC_CREATE_BODY_MASK)
  `CMQ_REGISTER_BODY(XTR_V1_OP_CEQC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_EQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_CEQC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_EQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_AEQC_CREATE, RDMA_IMAGE_AEQC,
                     XTR_V1_AEQC_CREATE_BODY_MASK)
  `CMQ_REGISTER_BODY(XTR_V1_OP_AEQC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_EQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_AEQC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_EQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_TQ_FLUSH, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_EMPTY_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_SRFQC_CREATE, RDMA_IMAGE_SRQC,
                     XTR_V1_SRQC_CREATE_BODY_MASK)
  `CMQ_REGISTER_BODY(XTR_V1_OP_SRFQC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_SRQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(XTR_V1_OP_SRFQC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     XTR_V1_SRQ_OBJECT_ID_BODY_OWNERSHIP)
`undef CMQ_REGISTER_BODY
  return rdma_status::success();
endfunction

class rdma_xtr_v1_cmq_envelope_codec extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_cmq_envelope_codec)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_cmq_envelope_codec");
    super.new(name);
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 envelope, image 用于执行 encode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  virtual function rdma_status encode(
    rdma_xtr_v1_cmq_envelope envelope,
    output rdma_hw_image image
  );
    rdma_xtr_v1_qword_builder builder;
    rdma_status status;
    byte unsigned payload[];
    bit [63:0] occupancy[];
    rdma_hw_image candidate;

    image = null;
    if (envelope == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ envelope is null");
    status = envelope.validate();
    if (!status.ok()) return status;
    builder = new("cmq_envelope_builder");
    status = builder.reset(XTR_V1_CMQE_BYTES);
    if (!status.ok())
      return rdma_status::make(RDMA_SC_CODEC_ERROR, status.message);
`define CMQ_ENVELOPE_PUT(STEM, VALUE) \
    status = builder.put_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                               STEM``_WIDTH, VALUE); \
    if (!status.ok()) \
      return rdma_status::make(RDMA_SC_CODEC_ERROR, status.message);
    `CMQ_ENVELOPE_PUT(XTR_V1_CMQ_VALID, envelope.valid)
    `CMQ_ENVELOPE_PUT(XTR_V1_CMQ_VFID_OVERRIDE, envelope.vfid_override)
    `CMQ_ENVELOPE_PUT(XTR_V1_CMQ_USE_VFID, envelope.use_vfid)
    `CMQ_ENVELOPE_PUT(XTR_V1_CMQ_WRAP, envelope.wrap)
    `CMQ_ENVELOPE_PUT(XTR_V1_CMQ_WQE_INDEX, envelope.wqe_index)
    `CMQ_ENVELOPE_PUT(XTR_V1_CMQ_OPCODE, envelope.opcode)
`undef CMQ_ENVELOPE_PUT
    builder.get_occupancy(occupancy);
    foreach (occupancy[q]) begin
      if (occupancy[q] != request_envelope_mask(q))
        return rdma_status::make(
          RDMA_SC_CODEC_ERROR,
          $sformatf("CMQ envelope qword %0d authorship mask mismatch", q)
        );
    end
    payload = new[0];
    status = builder.serialize(payload);
    if (!status.ok())
      return rdma_status::make(RDMA_SC_CODEC_ERROR, status.message);
    candidate = rdma_hw_image::type_id::create("xtr_v1_cmq_envelope_image");
    foreach (payload[i]) candidate.bytes.push_back(payload[i]);
    candidate.length = XTR_V1_CMQE_BYTES;
    candidate.alignment = XTR_V1_CMQE_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_CMQ_SQE;
    candidate.hardware_version = XTR_V1_HW_VERSION;
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    image = candidate;
    return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_cmq_request_composer extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_cmq_request_composer)

  protected rdma_xtr_v1_cmq_body_registry ownership;
  protected rdma_xtr_v1_cmq_envelope_codec envelope_codec;
  local rdma_xtr_v1_cmq_envelope_codec canonical_envelope_codec;
  local rdma_xtr_v1_cmq_body_encoder body_encoder;
  local rdma_codec_registry context_codecs;
  local rdma_codec_registry qpc_codecs;
  local rdma_xtr_v1_cmq_body_token body_token;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(
    string name = "rdma_xtr_v1_cmq_request_composer",
    rdma_xtr_v1_cmq_body_registry ownership = null,
    rdma_xtr_v1_cmq_envelope_codec envelope_codec = null
  );
    rdma_status status;
    super.new(name);
    if (ownership == null) begin
      this.ownership = rdma_xtr_v1_cmq_body_registry::type_id::create(
        "cmq_default_body_registry");
      status = rdma_xtr_v1_register_cmq_request_bodies(this.ownership);
      if (!status.ok())
        `uvm_fatal("RDMA_CMQ_REGISTRY", status.convert2string())
      this.ownership.seal();
    end
    else begin
      status = ownership.validated_snapshot(this.ownership);
      if (!status.ok() || this.ownership == null)
        `uvm_fatal("RDMA_CMQ_REGISTRY", "invalid injected CMQ registry")
    end
    if (envelope_codec == null)
      this.envelope_codec = rdma_xtr_v1_cmq_envelope_codec::type_id::create(
        "cmq_envelope_codec");
    else
      this.envelope_codec = envelope_codec;
    canonical_envelope_codec = new("cmq_canonical_envelope_codec");
    body_token = new("cmq_body_token");
    body_encoder = new("cmq_exact_body_encoder");
    context_codecs = rdma_codec_registry::type_id::create(
      "cmq_context_validation_registry");
    status = rdma_xtr_v1_register_context_body_codecs(context_codecs);
    if (!status.ok())
      `uvm_fatal("RDMA_CMQ_REGISTRY", status.convert2string())
    qpc_codecs = rdma_codec_registry::type_id::create(
      "cmq_qpc_signature_validation_registry");
    status = rdma_xtr_v1_register_qpc_codecs(qpc_codecs);
    if (!status.ok())
      `uvm_fatal("RDMA_CMQ_REGISTRY", status.convert2string())
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function rdma_status build_body(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    return mint_body(opcode, model, image);
  endfunction

  // 功能：处理 codec_error：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 message 用于执行 codec_error；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：codec_error 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：处理 images_match：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 lhs, rhs 用于执行 images_match；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：images_match 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function bit images_match(
    rdma_hw_image lhs,
    rdma_hw_image rhs
  );
    if (lhs == null || rhs == null ||
        lhs.bytes.size() != rhs.bytes.size() ||
        lhs.field_summary.size() != rhs.field_summary.size())
      return 1'b0;
    if (lhs.length != rhs.length || lhs.alignment != rhs.alignment ||
        lhs.endian != rhs.endian || lhs.image_kind != rhs.image_kind ||
        lhs.hardware_version != rhs.hardware_version ||
        lhs.function_generation != rhs.function_generation ||
        lhs.write_target_kind != rhs.write_target_kind ||
        lhs.backing_target.value != rhs.backing_target.value ||
        lhs.hmc_target.value != rhs.hmc_target.value ||
        lhs.bar_target.value != rhs.bar_target.value)
      return 1'b0;
    foreach (lhs.bytes[i])
      if (lhs.bytes[i] != rhs.bytes[i]) return 1'b0;
    foreach (lhs.field_summary[i])
      if (lhs.field_summary[i] != rhs.field_summary[i]) return 1'b0;
    return 1'b1;
  endfunction

  // 功能：处理 envelopes_match：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 lhs, rhs 用于执行 envelopes_match；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：envelopes_match 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function bit envelopes_match(
    rdma_xtr_v1_cmq_envelope lhs,
    rdma_xtr_v1_cmq_envelope rhs
  );
    if (lhs == null || rhs == null) return lhs == rhs;
    return lhs.valid == rhs.valid &&
           lhs.vfid_override == rhs.vfid_override &&
           lhs.use_vfid == rhs.use_vfid &&
           lhs.wrap == rhs.wrap &&
           lhs.wqe_index == rhs.wqe_index &&
           lhs.opcode == rhs.opcode;
  endfunction

  // 功能：执行 restore_envelope 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 destination, snapshot 用于执行 restore_envelope；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：restore_envelope 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  local function void restore_envelope(
    rdma_xtr_v1_cmq_envelope destination,
    rdma_xtr_v1_cmq_envelope snapshot
  );
    destination.valid = snapshot.valid;
    destination.vfid_override = snapshot.vfid_override;
    destination.use_vfid = snapshot.use_vfid;
    destination.wrap = snapshot.wrap;
    destination.wqe_index = snapshot.wqe_index;
    destination.opcode = snapshot.opcode;
  endfunction

  // 功能：处理 authenticate_body：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 opcode, image 用于执行 authenticate_body；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：authenticate_body 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function rdma_status authenticate_body(
    bit [7:0] opcode,
    rdma_hw_image image
  );
    rdma_xtr_v1_cmq_body_image artifact;
    if (!$cast(artifact, image))
      return codec_error("CMQ body is not a registered artifact");
    return artifact.authenticate(body_token, opcode);
  endfunction

  // 功能：处理 mint_body：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 opcode, model, image 用于执行 mint_body；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：mint_body 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  local function rdma_status mint_body(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_xtr_v1_cmq_body_image artifact;
    rdma_hw_image raw_image;
    rdma_status status;

    image = null;
    raw_image = null;
    status = body_encoder.encode(opcode, model, raw_image);
    if (!status.ok()) return status;
    if (raw_image == null)
      return codec_error("CMQ exact body encoder published null");
    artifact = new("xtr_v1_registered_cmq_body");
    artifact.copy(raw_image);
    status = artifact.initialize_once(body_token, opcode);
    if (!status.ok()) return status;
    image = artifact;
    return rdma_status::success();
  endfunction

  // 功能：处理 image_word：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, qword_index 用于执行 image_word；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：image_word 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function bit [63:0] image_word(
    rdma_hw_image image,
    int unsigned qword_index
  );
    bit [63:0] word;
    word = '0;
    for (int unsigned i = 0; i < 8; i++)
      word[63 - (i * 8) -: 8] = image.bytes[(qword_index * 8) + i];
    return word;
  endfunction

  // 功能：处理 context_key：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 key 用于执行 context_key；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：context_key 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_codec_key context_key(bit [7:0] opcode);
    rdma_codec_key key;
    key.hw_version = "xtr_v1";
    key.opcode = opcode;
    case (opcode)
      XTR_V1_OP_KEY_ALLOC: begin
        key.image_kind = RDMA_IMAGE_MRT;
        key.object_type = "mrt";
        key.variant = "key_alloc";
      end
      XTR_V1_OP_MR_REGISTER: begin
        key.image_kind = RDMA_IMAGE_MRT;
        key.object_type = "mrt";
        key.variant = "register";
      end
      XTR_V1_OP_CQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_CQC;
        key.object_type = "cqc";
        key.variant = "create";
      end
      XTR_V1_OP_CEQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_CEQC;
        key.object_type = "ceqc";
        key.variant = "create";
      end
      XTR_V1_OP_AEQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_AEQC;
        key.object_type = "aeqc";
        key.variant = "create";
      end
      XTR_V1_OP_SRFQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_SRQC;
        key.object_type = "srqc";
        key.variant = "create";
      end
      default: begin
        key.image_kind = RDMA_IMAGE_NONE;
        key.object_type = "invalid";
        key.variant = "invalid";
      end
    endcase
    return key;
  endfunction

  // 功能：判断 is_context_opcode 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：参数 XTR_V1_OP_KEY_ALLOC, XTR_V1_OP_MR_REGISTER 用于执行 is_context_opcode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：is_context_opcode 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit is_context_opcode(bit [7:0] opcode);
    return opcode inside {XTR_V1_OP_KEY_ALLOC, XTR_V1_OP_MR_REGISTER,
                          XTR_V1_OP_CQC_CREATE, XTR_V1_OP_CEQC_CREATE,
                          XTR_V1_OP_AEQC_CREATE, XTR_V1_OP_SRFQC_CREATE};
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected function rdma_status validate_context_identity(
    bit [7:0] opcode,
    rdma_hw_image body
  );
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    status = context_codecs.lookup(context_key(opcode), codec);
    if (!status.ok() || codec == null)
      return codec_error("CMQ exact context-body codec lookup failed");
    decoded = null;
    status = codec.decode(body, decoded);
    if (!status.ok() || decoded == null)
      return codec_error({"CMQ body violates exact opcode codec: ",
                          (status == null) ? "null status" : status.message});
    return rdma_status::success();
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected function rdma_status validate_image_metadata(
    rdma_hw_image image,
    rdma_image_kind_e expected_kind,
    int unsigned expected_length,
    int unsigned expected_alignment,
    string label
  );
    if (image == null)
      return codec_error({label, " is null"});
    if (image.length != expected_length ||
        image.bytes.size() != expected_length)
      return codec_error({label, " length is invalid"});
    if (image.alignment != expected_alignment ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != expected_kind ||
        image.hardware_version != XTR_V1_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return codec_error({label, " metadata is invalid"});
    return rdma_status::success();
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected function rdma_status validate_qpc_mode_image(
    bit [7:0] opcode,
    rdma_hw_image body,
    output bit needs_signature
  );
    bit [63:0] qword1;
    bit [63:0] qword2;
    bit [1:0] mode;
    bit sign_en;
    byte unsigned signature;
    bit partial_payload_nonzero;
    needs_signature = 1'b0;
    if (!(opcode inside {XTR_V1_OP_QPC_CREATE, XTR_V1_OP_QPC_MODIFY}))
      return rdma_status::success();
    qword1 = image_word(body, 1);
    sign_en = qword1[XTR_V1_CMQ_SIGN_EN_LSB];
    signature = qword1[XTR_V1_CMQ_SIGNATURE_LSB +: 8];
    if (signature != 0)
      return codec_error("CMQ QPC body signature must initially be zero");
    if (opcode == XTR_V1_OP_QPC_CREATE) begin
      if (!sign_en)
        return codec_error("CMQ QPC create must enable signature");
      needs_signature = 1'b1;
      return rdma_status::success();
    end
    qword2 = image_word(body, 2);
    mode = qword2[XTR_V1_CMQ_MODIFY_MODE_LSB +: 2];
    partial_payload_nonzero = 1'b0;
    for (int unsigned q = 4; q < 8; q++)
      partial_payload_nonzero |= image_word(body, q) != 0;
    case (mode)
      XTR_V1_QPC_MODIFY_STATE_ONLY: begin
        if (sign_en || image_word(body, 3) != 0 ||
            (qword2 & ~(64'h3 << XTR_V1_CMQ_MODIFY_MODE_LSB |
                        64'h3 << XTR_V1_CMQ_WBE_TEMPLATE_COUNT_LSB)) != 0 ||
            partial_payload_nonzero)
          return codec_error("CMQ state-only QPC modify has extra payload");
      end
      XTR_V1_QPC_MODIFY_FULL: begin
        if (!sign_en)
          return codec_error("CMQ full QPC modify must enable signature");
        if ((qword2 & ~(64'h3 << XTR_V1_CMQ_MODIFY_MODE_LSB |
                        64'h3 << XTR_V1_CMQ_WBE_TEMPLATE_COUNT_LSB)) != 0 ||
            partial_payload_nonzero)
          return codec_error("CMQ full QPC modify has partial payload");
        needs_signature = 1'b1;
      end
      XTR_V1_QPC_MODIFY_PARTIAL: begin
        if (sign_en || image_word(body, 3) != 0)
          return codec_error("CMQ partial QPC modify has signature/buffer");
      end
      default:
        return codec_error("CMQ QPC modify mode is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected function rdma_status validate_qpc_signature_source(
    rdma_hw_image source,
    rdma_hw_image body
  );
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_model decoded_model;
    rdma_qpc_model decoded_qpc;
    rdma_status status;
    bit [2:0] service_type;
    bit [23:0] body_qpn;
    bit [1:0] modify_mode;
    bit [1:0] wbe_template;
    bit [1:0] expected_wbe_template;

    service_type = (image_word(source, 0) >>
                    XTR_V1_QPC_SERVICE_TYPE_LSB) & 3'h7;
    key.hw_version = "xtr_v1";
    key.image_kind = RDMA_IMAGE_QPC;
    key.object_type = "qpc";
    key.opcode = XTR_V1_OP_QPC_CREATE;
    case (service_type)
      3'd0: key.variant = "rc";
      3'd3: key.variant = "ud";
      3'd6: key.variant = "urc";
      default:
        return codec_error("QPC signature source service type is invalid");
    endcase
    status = qpc_codecs.lookup(key, codec);
    if (!status.ok() || codec == null)
      return codec_error("QPC signature source codec lookup failed");
    decoded_model = null;
    status = codec.decode(source, decoded_model);
    if (!status.ok() || decoded_model == null ||
        !$cast(decoded_qpc, decoded_model))
      return codec_error({"QPC signature source decode failed: ",
                          (status == null) ? "null status" :
                                             status.message});
    body_qpn = (image_word(body, 0) >> XTR_V1_CMQ_QPN_LSB) & 24'hff_ffff;
    if (decoded_qpc.qp_h == null ||
        decoded_qpc.qp_h.kind != RDMA_RESOURCE_QP ||
        decoded_qpc.qp_h.object_id != body_qpn)
      return codec_error(
        "QPC signature source QPN does not match the CMQ body"
      );
    modify_mode = (image_word(body, 2) >>
                   XTR_V1_CMQ_MODIFY_MODE_LSB) & 2'h3;
    if (modify_mode == XTR_V1_QPC_MODIFY_FULL) begin
      wbe_template = (image_word(body, 2) >>
                      XTR_V1_CMQ_WBE_TEMPLATE_COUNT_LSB) & 2'h3;
      case (decoded_qpc.transport)
        RDMA_TRANSPORT_RC,
        RDMA_TRANSPORT_UD: expected_wbe_template = 0;
        RDMA_TRANSPORT_URC: expected_wbe_template = 1;
        default:
          return codec_error(
            "QPC signature source transport is unsupported"
          );
      endcase
      if (wbe_template != expected_wbe_template)
        return codec_error(
          "full QPC modify WBE template does not match transport"
        );
    end
    return rdma_status::success();
  endfunction

  // 功能：处理 compose_request：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 envelope, body, qpc_signature_source, result 用于执行 compose_request；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：compose_request 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status compose_request(
    rdma_xtr_v1_cmq_envelope envelope,
    rdma_hw_image body,
    rdma_hw_image qpc_signature_source,
    output rdma_hw_image result
  );
    rdma_hw_image envelope_image;
    rdma_hw_image canonical_envelope_image;
    rdma_hw_image candidate;
    rdma_xtr_v1_cmq_envelope envelope_snapshot;
    rdma_image_kind_e input_kind;
    bit [63:0] masks[8];
    bit [63:0] envelope_word;
    bit [63:0] body_word;
    bit [63:0] merged_word;
    bit needs_signature;
    byte unsigned signature;
    int unsigned signature_byte;
    rdma_status status;

    result = null;
    if (envelope == null)
      return codec_error("CMQ envelope is null");
    envelope_snapshot = new("cmq_envelope_snapshot");
    envelope_snapshot.valid = envelope.valid;
    envelope_snapshot.vfid_override = envelope.vfid_override;
    envelope_snapshot.use_vfid = envelope.use_vfid;
    envelope_snapshot.wrap = envelope.wrap;
    envelope_snapshot.wqe_index = envelope.wqe_index;
    envelope_snapshot.opcode = envelope.opcode;
    envelope_image = null;
    status = envelope_codec.encode(envelope, envelope_image);
    if (!envelopes_match(envelope, envelope_snapshot)) begin
      restore_envelope(envelope, envelope_snapshot);
      return codec_error("CMQ envelope codec mutated its input");
    end
    if (!status.ok()) return status;
    canonical_envelope_image = null;
    status = canonical_envelope_codec.encode(envelope_snapshot,
                                             canonical_envelope_image);
    if (!status.ok()) return status;
    if (!images_match(envelope_image, canonical_envelope_image))
      return codec_error("CMQ envelope codec output is not canonical");
    envelope_image = canonical_envelope_image;

    status = ownership.lookup(envelope_snapshot.opcode, input_kind, masks);
    if (!status.ok()) return status;
    status = authenticate_body(envelope_snapshot.opcode, body);
    if (!status.ok()) return status;
    status = validate_image_metadata(body, input_kind, XTR_V1_CMQE_BYTES,
                                     XTR_V1_CMQE_BYTES, "CMQ body image");
    if (!status.ok()) return status;
    for (int unsigned q = 0; q < 8; q++) begin
      body_word = image_word(body, q);
      if ((body_word & ~masks[q]) != 0)
        return codec_error($sformatf(
          "CMQ body qword %0d contains a bit outside opcode ownership", q));
    end
    for (int unsigned q = 0; q < 8; q++) begin
      if ((request_envelope_mask(q) & masks[q]) != 0)
        return codec_error($sformatf(
          "CMQ envelope/body ownership overlaps in qword %0d", q));
    end
    if (is_context_opcode(envelope_snapshot.opcode)) begin
      status = validate_context_identity(envelope_snapshot.opcode, body);
      if (!status.ok()) return status;
    end

    needs_signature = 1'b0;
    status = validate_qpc_mode_image(envelope_snapshot.opcode, body,
                                     needs_signature);
    if (!status.ok()) return status;
    if (needs_signature) begin
      status = validate_image_metadata(qpc_signature_source,
                                       RDMA_IMAGE_QPC,
                                       XTR_V1_QPC_BYTES,
                                       XTR_V1_QPC_BYTES,
                                       "QPC signature source");
      if (!status.ok()) return status;
      if (qpc_signature_source.function_generation !=
          body.function_generation)
        return codec_error(
          "QPC signature source generation does not match the CMQ body"
        );
      status = validate_qpc_signature_source(qpc_signature_source, body);
      if (!status.ok()) return status;
    end
    else if (qpc_signature_source != null)
      return codec_error("QPC signature source is invalid for this opcode");

    candidate = rdma_hw_image::type_id::create("xtr_v1_cmq_request");
    for (int unsigned q = 0; q < 8; q++) begin
      envelope_word = image_word(envelope_image, q);
      body_word = image_word(body, q);
      merged_word = envelope_word | body_word;
      for (int unsigned i = 0; i < 8; i++)
        candidate.bytes.push_back(merged_word[63 - (i * 8) -: 8]);
    end
    if (needs_signature) begin
      signature_byte = XTR_V1_CMQ_SIGNATURE_WORD_BYTE_OFFSET +
                       (7 - (XTR_V1_CMQ_SIGNATURE_LSB >> 3));
      if (candidate.bytes[signature_byte] != 0)
        return codec_error("CMQ unsigned signature field is not zero");
      signature = 8'h00;
      foreach (candidate.bytes[i]) signature ^= candidate.bytes[i];
      foreach (qpc_signature_source.bytes[i])
        signature ^= qpc_signature_source.bytes[i];
      candidate.bytes[signature_byte] = ~signature;
    end

    for (int unsigned q = 0; q < 8; q++) begin
      merged_word = image_word(candidate, q);
      if ((merged_word & ~(request_envelope_mask(q) | masks[q])) != 0)
        return codec_error("composed CMQ request contains an unowned bit");
    end
    if (((image_word(candidate, 0) >> XTR_V1_CMQ_OPCODE_LSB) & 8'hff) !=
        envelope_snapshot.opcode)
      return codec_error("composed CMQ opcode is not exact");

    candidate.length = XTR_V1_CMQE_BYTES;
    candidate.alignment = XTR_V1_CMQE_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_CMQ_SQE;
    candidate.hardware_version = XTR_V1_HW_VERSION;
    candidate.function_generation = body.function_generation;
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    result = candidate;
    return rdma_status::success();
  endfunction
endclass
