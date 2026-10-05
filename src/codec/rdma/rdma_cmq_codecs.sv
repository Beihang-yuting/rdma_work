// 目录：硬件编解码层 codec/rdma/rdma_cmq_codecs.sv。
// 职责：实现 rdma_hw_cmq_codecs 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_cmq_codecs.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 功能：rdma_cmq_context_codec_key 根据 CMQ context-body opcode 生成唯一的
//       registry key，把 opcode、image kind、对象类型和 variant 集中在两类 CMQ consumer
//       共享的映射中。
// 输入/输出及副作用：opcode 为 8 位驱动命令输入；函数返回值字段完整的
//       rdma_codec_key，不访问 registry、不创建 codec，也不修改调用方对象或资源账本。
// 失败/边界：未知或保留 opcode 返回 RDMA_IMAGE_NONE、object_type="invalid"、
//       variant="invalid" 的 fail-closed key；六个已登记 context opcode 的字段必须与
//       rdma_register_context_body_codecs 使用的 key 完全一致。
function automatic rdma_codec_key rdma_cmq_context_codec_key(
  input bit [7:0] opcode
);
  rdma_codec_key key;
  key.hw_version = "rdma";
  key.opcode = opcode;
  key.image_kind = RDMA_IMAGE_NONE;
  key.object_type = "invalid";
  key.variant = "invalid";
  case (opcode)
    RDMA_OP_KEY_ALLOC: begin
      key.image_kind = RDMA_IMAGE_MRT;
      key.object_type = "mrt";
      key.variant = "key_alloc";
    end
    RDMA_OP_MR_REGISTER: begin
      key.image_kind = RDMA_IMAGE_MRT;
      key.object_type = "mrt";
      key.variant = "register";
    end
    RDMA_OP_CQC_CREATE: begin
      key.image_kind = RDMA_IMAGE_CQC;
      key.object_type = "cqc";
      key.variant = "create";
    end
    RDMA_OP_CEQC_CREATE: begin
      key.image_kind = RDMA_IMAGE_CEQC;
      key.object_type = "ceqc";
      key.variant = "create";
    end
    RDMA_OP_AEQC_CREATE: begin
      key.image_kind = RDMA_IMAGE_AEQC;
      key.object_type = "aeqc";
      key.variant = "create";
    end
    RDMA_OP_SRFQC_CREATE: begin
      key.image_kind = RDMA_IMAGE_SRQC;
      key.object_type = "srqc";
      key.variant = "create";
    end
    default: begin
      // 默认值已完成 fail-closed 初始化；不把未知 opcode 猜测成 context body。
    end
  endcase
  return key;
endfunction

// 功能：rdma_cmq_is_context_opcode 根据同一份 canonical key 判断 opcode 是否需要
//       context-body registry，供 body encoder 与 request composer 共享 admission 分支。
// 输入/输出及副作用：opcode 为 8 位驱动命令输入；函数只读取
//       rdma_cmq_context_codec_key 的值映射并返回 bit，不登记、查找或修改任何状态。
// 失败/边界：未知、保留或映射为 RDMA_IMAGE_NONE 的 opcode 返回 0；该判断必须与
//       rdma_cmq_context_codec_key 的六个有效映射保持一致，不能回退到默认 codec。
function automatic bit rdma_cmq_is_context_opcode(input bit [7:0] opcode);
  rdma_codec_key key;
  key = rdma_cmq_context_codec_key(opcode);
  return key.image_kind != RDMA_IMAGE_NONE;
endfunction

class rdma_hw_cmq_envelope extends uvm_object;
  `uvm_object_utils(rdma_hw_cmq_envelope)

  bit valid;
  bit vfid_override;
  bit [10:0] use_vfid;
  bit wrap;
  bit [4:0] wqe_index;
  bit [7:0] opcode;

  // 功能：构造 rdma_hw_cmq_envelope，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：valid=1'b0；vfid_override=1'b0；use_vfid='0；wrap=1'b0；wqe_index='0；opcode='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_envelope 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_envelope");
    super.new(name);
    valid = 1'b0;
    vfid_override = 1'b0;
    use_vfid = '0;
    wrap = 1'b0;
    wqe_index = '0;
    opcode = '0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_cmq_envelope 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ envelope copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cmq_envelope rhs_envelope;
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

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“rdma CMQ use-vfid requires VFID override”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、vfid_override、use_vfid 并使用字段 rdma_status、vfid_override、use_vfid；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“rdma CMQ use-vfid requires VFID override”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status validate();
    if (!vfid_override && use_vfid != 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "rdma CMQ use-vfid requires VFID override"
      );
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  function string describe();
    return $sformatf(
      "CMQ envelope(valid=%0b override=%0b vfid=%0d wrap=%0b index=%0d opcode=0x%02x)",
      valid, vfid_override, use_vfid, wrap, wqe_index, opcode
    );
  endfunction
endclass

class rdma_hw_cmq_completion extends uvm_object;
  `uvm_object_utils(rdma_hw_cmq_completion)

  bit owner;
  bit [7:0] opcode;
  bit [7:0] command_ecode;
  bit [4:0] wqe_index;
  bit wrap;
  byte unsigned object_payload[];

  // 功能：构造 rdma_hw_cmq_completion，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：owner=1'b0；opcode='0；command_ecode='0；wqe_index='0；wrap=1'b0；object_payload=new[0]。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_completion 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_completion");
    super.new(name);
    owner = 1'b0;
    opcode = '0;
    command_ecode = '0;
    wqe_index = '0;
    wrap = 1'b0;
    object_payload = new[0];
  endfunction

  // 功能：将 rhs 中 rdma_hw_cmq_completion 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ completion copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cmq_completion rhs_completion;
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

class rdma_hw_cmq_completion_codec extends uvm_object;
  `uvm_object_utils(rdma_hw_cmq_completion_codec)

  // 功能：构造 rdma_hw_cmq_completion_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_completion_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_completion_codec");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_cmq_completion_codec 中，codec_error 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；codec_error 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：codec_error 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  local function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：在 rdma_hw_cmq_completion_codec 中，image_qword 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：image（输入）、qword_index（输入）；image_qword 读取 image、qword_index 并使用字段 value、base；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：image_qword 的结果直接由 return value 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 完成接收必须独立于可注入的 request registry；这里只接受已经定义
  // 公共 CQE 头或返回 payload 语义的 0.1.34 opcode。
  // 功能：supported_opcode 判断 completion codec 是否拥有指定 opcode 的解码契约。
  // 输入/输出及副作用：opcode 为 8 位驱动命令值输入；函数只读取固定支持集合，
  //   返回 bit，不修改 request registry、completion image 或 CMQ ring。
  // 失败/边界：未知 opcode，或仅有 request body 而没有 CQE payload 定义的命令，
  //   一律返回 0；该函数本身不改变 ready/completion 输出。
  local function bit supported_opcode(bit [7:0] opcode);
    return opcode inside {
      RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY,
      RDMA_OP_QPC_DELETE, RDMA_OP_QPC_QUERY,
      RDMA_OP_KEY_ALLOC, RDMA_OP_MR_REGISTER,
      RDMA_OP_MR_DEREGISTER, RDMA_OP_KEY_QUERY,
      RDMA_OP_OCC_FLUSH,
      RDMA_OP_CQC_CREATE, RDMA_OP_CQC_DELETE,
      RDMA_OP_CQC_QUERY, RDMA_OP_CEQC_CREATE,
      RDMA_OP_CEQC_DELETE, RDMA_OP_CEQC_QUERY,
      RDMA_OP_AEQC_CREATE, RDMA_OP_AEQC_DELETE,
      RDMA_OP_AEQC_QUERY, RDMA_OP_TQ_FLUSH,
      RDMA_OP_SRFQC_CREATE, RDMA_OP_SRFQC_DELETE,
      RDMA_OP_SRFQC_QUERY,
      RDMA_OP_SRC_ADDR_QUERY,
      RDMA_OP_IFA_QUERY,
      RDMA_OP_OCC_PD_SEARCH,
      RDMA_OP_OCC_PD_IDX_SEARCH,
      RDMA_OP_OCC_QPC, RDMA_OP_OCC_CQC, RDMA_OP_OCC_MRT,
      RDMA_OP_OCC_PBLE, RDMA_OP_OCC_SQRQE, RDMA_OP_OCC_SGB,
      RDMA_OP_OCC_IRQE, RDMA_OP_OCC_EIRQE, RDMA_OP_OCC_ORQE,
      RDMA_OP_OCC_UAQE,
      RDMA_OP_IDX_OCC_QPC, RDMA_OP_IDX_OCC_CQC, RDMA_OP_IDX_OCC_MRT,
      RDMA_OP_IDX_OCC_PBLE, RDMA_OP_IDX_OCC_SQRQE, RDMA_OP_IDX_OCC_SGB,
      RDMA_OP_IDX_OCC_IRQE, RDMA_OP_IDX_OCC_EIRQE, RDMA_OP_IDX_OCC_ORQE,
      RDMA_OP_IDX_OCC_UAQE
    };
  endfunction

  // 功能：allowed_qword_mask 按 opcode 和 qword_index 返回驱动 CQE 中可解释的
  //   位所有权，供 inspect_completion 的四态 raw-mask 检查使用。
  // 输入/输出及副作用：opcode 与 qword_index 为输入；函数只计算 bit [63:0] 掩码，
  //   不修改 descriptor、completion 对象或 CMQ ring。
  // 失败/边界：qword_index 超出 0..7、opcode 未声明 payload，或该 qword 仅含保留位
  //   时返回零；调用方负责把掩码之外的 0/1/X/Z 位判为 codec 错误。
  local function bit [63:0] allowed_qword_mask(
    bit [7:0] opcode,
    int unsigned qword_index
  );
    if (qword_index == 0) begin
      if (opcode inside {RDMA_OP_OCC_PD_SEARCH, RDMA_OP_OCC_PD_IDX_SEARCH,
                         RDMA_OP_OCC_QPC, RDMA_OP_OCC_CQC, RDMA_OP_OCC_MRT,
                         RDMA_OP_OCC_PBLE, RDMA_OP_OCC_SQRQE,
                         RDMA_OP_OCC_SGB, RDMA_OP_OCC_IRQE,
                         RDMA_OP_OCC_EIRQE, RDMA_OP_OCC_ORQE,
                         RDMA_OP_OCC_UAQE,
                         RDMA_OP_IDX_OCC_QPC, RDMA_OP_IDX_OCC_CQC,
                         RDMA_OP_IDX_OCC_MRT, RDMA_OP_IDX_OCC_PBLE,
                         RDMA_OP_IDX_OCC_SQRQE, RDMA_OP_IDX_OCC_SGB,
                         RDMA_OP_IDX_OCC_IRQE, RDMA_OP_IDX_OCC_EIRQE,
                         RDMA_OP_IDX_OCC_ORQE, RDMA_OP_IDX_OCC_UAQE})
        return 64'h8000_3fff_ff00_0000 |
               64'h03ff_c000_00ff_0fff;
      if (opcode inside {RDMA_OP_CEQC_QUERY, RDMA_OP_AEQC_QUERY})
        return 64'h8000_3fff_ff00_0fff;
      if (opcode == RDMA_OP_SRFQC_QUERY)
        return 64'h8000_3fff_ff00_ffff;
      if (opcode == RDMA_OP_IFA_QUERY)
        return 64'hb000_3fff_ff00_0000;
      return 64'h8000_3fff_ff00_0000;
    end
    case (opcode)
      RDMA_OP_KEY_QUERY:
        if (qword_index inside {[2:7]})
          return 64'hffff_ffff_ffff_ffff;
      RDMA_OP_CQC_QUERY:
        return 64'hffff_ffff_ffff_ffff;
      RDMA_OP_CEQC_QUERY,
      RDMA_OP_AEQC_QUERY:
        case (qword_index)
          0: return 64'h8000_3fff_ff00_0fff;
          2, 3, 4, 5: return 64'hffff_ffff_ffff_ffff;
          default: return 64'h0000_0000_0000_0000;
        endcase
      RDMA_OP_SRFQC_QUERY:
        case (qword_index)
          0: return 64'h8000_3fff_ff00_ffff;
          2, 3, 4, 5: return 64'hffff_ffff_ffff_ffff;
          default: return 64'h0000_0000_0000_0000;
        endcase
      RDMA_OP_SRC_ADDR_QUERY: begin
        case (qword_index)
          // index/valid/SMAC，保留位 51:49 必须保持为零。
          1: return 64'hfff1_ffff_ffff_ffff;
          2, 3: return 64'hffff_ffff_ffff_ffff;
          default: return 64'h0000_0000_0000_0000;
        endcase
      end
      RDMA_OP_IFA_QUERY: begin
        if (qword_index == 0)
          return 64'hb000_3fff_ff00_0000;
        if (qword_index == 1)
          return 64'h07ff_ffff_ffff_ffff;
      end
      RDMA_OP_OCC_PD_SEARCH,
      RDMA_OP_OCC_PD_IDX_SEARCH: begin
        case (qword_index)
          1: return 64'h0000_00ff_ffff_ffff;
          3: return 64'hffff_ffff_ffff_ffff;
          default: return 64'h0000_0000_0000_0000;
        endcase
      end
      RDMA_OP_OCC_QPC,
      RDMA_OP_OCC_CQC,
      RDMA_OP_OCC_MRT,
      RDMA_OP_OCC_PBLE,
      RDMA_OP_OCC_SQRQE,
      RDMA_OP_OCC_SGB,
      RDMA_OP_OCC_IRQE,
      RDMA_OP_OCC_EIRQE,
      RDMA_OP_OCC_ORQE,
      RDMA_OP_OCC_UAQE,
      RDMA_OP_IDX_OCC_QPC,
      RDMA_OP_IDX_OCC_CQC,
      RDMA_OP_IDX_OCC_MRT,
      RDMA_OP_IDX_OCC_PBLE,
      RDMA_OP_IDX_OCC_SQRQE,
      RDMA_OP_IDX_OCC_SGB,
      RDMA_OP_IDX_OCC_IRQE,
      RDMA_OP_IDX_OCC_EIRQE,
      RDMA_OP_IDX_OCC_ORQE,
      RDMA_OP_IDX_OCC_UAQE:
        case (qword_index)
          1: return 64'h0000_00ff_ffff_ffff;
          3: return 64'hffff_ffff_ffff_ffff;
          default: return 64'h0000_0000_0000_0000;
        endcase
      default: return 64'h0000_0000_0000_0000;
    endcase
    return 64'h0000_0000_0000_0000;
  endfunction

  // 功能：returned_payload_bounds 把每类查询/占用完成映射为 CQE payload 的起始
  //   字节偏移和长度，供 inspect_completion 复制 detached payload。
  // 输入/输出及副作用：opcode 为输入；first_byte 与 byte_count 为输出，入口先清零，
  //   函数只写这两个结果，不持有 image、completion 或外部 backing。
  // 失败/边界：KEY_QUERY=16/48、CQC_QUERY=8/56、CEQC/AEQC/SRFQC_QUERY=16/32、
  //   SRC_ADDR_QUERY=8/24、IFA_QUERY=8/8、OCC 查询=8/24；未列出的 opcode 输出 0/0。
  local function void returned_payload_bounds(
    bit [7:0] opcode,
    output int unsigned first_byte,
    output int unsigned byte_count
  );
    first_byte = 0;
    byte_count = 0;
    case (opcode)
      RDMA_OP_KEY_QUERY: begin
        first_byte = 16;
        byte_count = 48;
      end
      RDMA_OP_CQC_QUERY: begin
        first_byte = 8;
        byte_count = 56;
      end
      RDMA_OP_CEQC_QUERY,
      RDMA_OP_AEQC_QUERY,
      RDMA_OP_SRFQC_QUERY: begin
        first_byte = 16;
        byte_count = 32;
      end
      RDMA_OP_SRC_ADDR_QUERY: begin
        // 驱动从 byte8 读取 index，byte10 读取 MAC，byte16 读取 IPv6。
        // 这三段在 64B CQE 中覆盖连续 byte8..31，统一暴露为 24B payload。
        first_byte = 8;
        byte_count = 24;
      end
      RDMA_OP_IFA_QUERY: begin
        first_byte = 8;
        byte_count = 8;
      end
      RDMA_OP_OCC_PD_SEARCH,
      RDMA_OP_OCC_PD_IDX_SEARCH,
      RDMA_OP_OCC_QPC, RDMA_OP_OCC_CQC, RDMA_OP_OCC_MRT,
      RDMA_OP_OCC_PBLE, RDMA_OP_OCC_SQRQE, RDMA_OP_OCC_SGB,
      RDMA_OP_OCC_IRQE, RDMA_OP_OCC_EIRQE, RDMA_OP_OCC_ORQE,
      RDMA_OP_OCC_UAQE,
      RDMA_OP_IDX_OCC_QPC, RDMA_OP_IDX_OCC_CQC, RDMA_OP_IDX_OCC_MRT,
      RDMA_OP_IDX_OCC_PBLE, RDMA_OP_IDX_OCC_SQRQE, RDMA_OP_IDX_OCC_SGB,
      RDMA_OP_IDX_OCC_IRQE, RDMA_OP_IDX_OCC_EIRQE, RDMA_OP_IDX_OCC_ORQE,
      RDMA_OP_IDX_OCC_UAQE: begin
        // qword1 为 key，qword3 为 buffer；qword2 是驱动保留空洞。
        first_byte = 8;
        byte_count = 24;
      end
      default: begin
        first_byte = 0;
        byte_count = 0;
      end
    endcase
  endfunction

  // 功能：inspect_completion 校验 64B CMQ CQE 的元数据、owner、opcode 和每个
  //   qword 的四态 ownership mask，并把公共头与返回 payload 解码成 detached 对象。
  // 输入/输出及副作用：image 与 expected_owner 为输入；ready 与 completion 为输出，
  //   入口先分别置 0/null，成功时发布新建 completion，不取得 image backing 所有权。
  // 失败/边界：image 为空、长度/元数据错误、opcode 未支持或保留位含 X/Z/非零时，
  //   返回对应 RDMA_SC_* 错误并保持 ready=0、completion=null；owner 未匹配只返回成功且不消费 CQE。
  function rdma_status inspect_completion(
    rdma_hw_image image,
    bit expected_owner,
    output bit ready,
    output rdma_hw_cmq_completion completion
  );
    bit [63:0] qword0;
    bit [63:0] word;
    bit [7:0] opcode;
    bit owner;
    bit wrap;
    int unsigned first_byte;
    int unsigned byte_count;
    rdma_hw_cmq_completion candidate;

    ready = 1'b0;
    completion = null;
    if (image == null)
      return codec_error("rdma CMQ completion image is null");
    if (image.length != RDMA_CMQE_BYTES ||
        image.bytes.size() != RDMA_CMQE_BYTES)
      return codec_error("rdma CMQ completion length is not 64 bytes");
    if (image.alignment != RDMA_CMQE_BYTES ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_CMQ_CQE ||
        image.hardware_version != RDMA_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return codec_error("rdma CMQ completion metadata is invalid");
    qword0 = image_qword(image, 0);
    owner = qword0[63];
    if (owner != expected_owner)
      return rdma_status::success();
    opcode = (qword0 >> RDMA_CMQ_OPCODE_LSB) & 8'hff;
    wrap = (qword0 >> RDMA_CMQ_WRAP_LSB) & 1'b1;
    if (!supported_opcode(opcode))
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("unsupported rdma CMQ completion opcode 0x%02x", opcode)
      );

    for (int unsigned q = 0; q < 8; q++) begin
      word = image_qword(image, q);
      if (!rdma_raw_qword_mask_is_valid(
            word, allowed_qword_mask(opcode, q)))
        return codec_error($sformatf(
          "rdma CMQ completion qword %0d contains a reserved bit", q));
    end
    candidate = new("rdma_cmq_completion");
    candidate.owner = owner;
    candidate.opcode = opcode;
    candidate.command_ecode =
      (qword0 >> RDMA_CMQ_CMD_ECODE_LSB) & 8'hff;
    candidate.wqe_index =
      (qword0 >> RDMA_CMQ_WQE_INDEX_LSB) & 5'h1f;
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

class rdma_hw_qpc_command_body extends rdma_hw_model;
  `uvm_object_utils(rdma_hw_qpc_command_body)

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

  // 功能：构造 rdma_hw_qpc_command_body，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：qp_h=null；send_cq_h=null；recv_cq_h=null；qpc_buffer='0；next_state=RDMA_QPS_RESET；full_modify=1'b0；partial_modify=1'b0；wbe_template_count='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_qpc_command_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_qpc_command_body");
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

  // 功能：将 rhs 中 rdma_hw_qpc_command_body 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（QPC command body copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_qpc_command_body rhs_body;
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

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“QPC command QP”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、full_modify、partial_modify 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QPC modify modes are mutually exclusive”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf(
      "QPC command(qpn=%0d full=%0b partial=%0b next=%s buffer=0x%016x)",
      (qp_h == null) ? 0 : qp_h.object_id, full_modify, partial_modify,
      next_state.name(), qpc_buffer.value
    );
  endfunction
endclass

class rdma_hw_object_id_command_body extends rdma_hw_model;
  `uvm_object_utils(rdma_hw_object_id_command_body)

  rdma_handle object_h;

  // 功能：构造 rdma_hw_object_id_command_body，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：object_h=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_object_id_command_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_object_id_command_body");
    super.new(name);
    object_h = null;
  endfunction

  // 功能：将 rhs 中 rdma_hw_object_id_command_body 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（object-ID command copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_object_id_command_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "object-ID command copy type mismatch")
    object_h = rdma_clone_handle_value(rhs_body.object_h,
                                       "object-ID command");
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“object-ID command handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、object_h 并使用字段 rdma_status、object_h；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“object-ID command handle is null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (object_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "object-ID command handle is null");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("object-ID command(kind=%s id=%0d)",
                     (object_h == null) ? "null" : object_h.kind.name(),
                     (object_h == null) ? 0 : object_h.object_id);
  endfunction
endclass

// CQC_DELETE 的 wire body 与 CQC_QUERY 不同：驱动会把 live CQC context
// 的前 56 字节原样复制到 WQE。单独的 typed body 让调用方必须提供完整
// context，避免把只有 CQN 的 legacy object body 错当成可发送请求。
class rdma_hw_cqc_delete_body extends rdma_hw_model;
  `uvm_object_utils(rdma_hw_cqc_delete_body)

  rdma_cqc_model cqc_context;

  // 功能：构造完整 CQC_DELETE body，并将嵌套 CQC context 初始化为空，等待
  //   调用方显式绑定待删除 CQ 的 context snapshot。
  // 输入/输出及副作用：name 为 UVM 实例名输入；只写入 cqc_context=null，
  //   不取得 CQ、CEQ 或 Host-memory 的所有权。
  // 失败/边界：构造成功不代表 body 可编码；未绑定 context 时 validate() 必须
  //   返回 INVALID_ARGUMENT，防止发布仅含 CQN 的不完整 wire image。
  function new(string name = "rdma_hw_cqc_delete_body");
    super.new(name);
    cqc_context = null;
  endfunction

  // 功能：复制 rhs 的完整 CQC_DELETE body，使用传统 UVM clone/copy 语义建立
  //   与源 context 分离的嵌套快照。
  // 输入/输出及副作用：rhs 为源对象输入；当前 cqc_context 被替换为新建的
  //   rdma_cqc_model，源 body/context 与 registry 不被修改。
  // 失败/边界：rhs 类型不符或 context clone/cast 失败时报告 UVM_FATAL；源
  //   context 为空时目标保持为空，不伪造默认 CQC。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cqc_delete_body source;
    rdma_cqc_model cloned_context;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQC delete body copy mismatch")

    cqc_context = null;
    if (source.cqc_context == null)
      return;

    cloned_context = rdma_deep_copy#(rdma_cqc_model)::of(
      source.cqc_context, "CQC delete context clone mismatch");
    cqc_context = cloned_context;
  endfunction

  // 功能：校验 CQC_DELETE body 的 exact wrapper、完整 CQC context 以及 CQ
  //   handle 的驱动对象类型/位宽，作为专用 layout codec 的唯一输入门禁。
  // 输入/输出及副作用：无显式参数；只读 cqc_context 及其嵌套字段，返回
  //   rdma_status，不修改 context、resource registry 或生命周期状态。
  // 失败/边界：null/派生 wrapper、context.validate() 失败、CQ handle 缺失、
  //   kind 非 RDMA_RESOURCE_CQ 或 object ID 超过 21 位时返回 INVALID_ARGUMENT
  //   或原始 validation status；失败路径不允许编码半成品。
  virtual function rdma_status validate();
    rdma_status status;

    if (cqc_context == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQC delete requires a complete CQC context"
      );
    if (cqc_context.get_object_type() != rdma_cqc_model::get_type())
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQC delete context wrapper must be exact rdma_cqc_model"
      );

    status = cqc_context.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQC delete context validation returned null"
      );
    if (!status.ok())
      return status;

    return rdma_context_handle_status(
      cqc_context.cq_h, RDMA_RESOURCE_CQ, 21, "CQC delete CQ"
    );
  endfunction

  // 功能：生成包含 CQ object ID 与 context 状态摘要的 CQC_DELETE 诊断文本，
  //   供日志、canonical 比较和恢复索引使用。
  // 输入/输出及副作用：无显式参数；只读取 cqc_context/cq_h，返回稳定 string，
  //   不修改任何对象或外部资源。
  // 失败/边界：context 或 CQ handle 为空时返回带 null 标记的文本；该文本不
  //   代替 validate()，也不应被当作 wire ABI 或安全 digest。
  virtual function string describe();
    return $sformatf(
      "CQC delete(cqn=%0d state=%s depth=%0d cqe_size=%0d)",
      (cqc_context == null || cqc_context.cq_h == null) ? 0 :
        cqc_context.cq_h.object_id,
      (cqc_context == null) ? "null" : cqc_context.state.name(),
      (cqc_context == null) ? 0 : cqc_context.depth,
      (cqc_context == null) ? 0 : cqc_context.cqe_size_bytes
    );
  endfunction
endclass

class rdma_hw_mr_deregister_body extends rdma_hw_model;
  `uvm_object_utils(rdma_hw_mr_deregister_body)

  rdma_handle mr_h;
  bit [7:0] stag_key;
  rdma_context_state_e next_state;

  // 功能：构造 rdma_hw_mr_deregister_body，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：mr_h=null；stag_key='0；next_state=RDMA_CONTEXT_INVALID。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_mr_deregister_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_mr_deregister_body");
    super.new(name);
    mr_h = null;
    stag_key = '0;
    next_state = RDMA_CONTEXT_INVALID;
  endfunction

  // 功能：将 rhs 中 rdma_hw_mr_deregister_body 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（MR deregister body copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_mr_deregister_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MR deregister body copy type mismatch")
    mr_h = rdma_clone_handle_value(rhs_body.mr_h, "MR deregister");
    stag_key = rhs_body.stag_key;
    next_state = rhs_body.next_state;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“MR deregister”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、next_state 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“MR deregister next state is unsupported”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("MR deregister(stag=%0d key=0x%02x next=%s)",
                     (mr_h == null) ? 0 : mr_h.object_id, stag_key,
                     next_state.name());
  endfunction
endclass

class rdma_hw_occ_flush_body extends rdma_hw_model;
  `uvm_object_utils(rdma_hw_occ_flush_body)

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

  // 功能：构造 rdma_hw_occ_flush_body，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：vf_flush=1'b0；mr_serial_flush=1'b0；qpc=1'b0；cqc=1'b0；mrt=1'b0；pble=1'b0；sqrqe=1'b0；sgb_irqe=1'b0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_occ_flush_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_occ_flush_body");
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

  // 功能：将 rhs 中 rdma_hw_occ_flush_body 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（OCC flush body copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_occ_flush_body rhs_body;
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

  // 功能：validate 按驱动的 VF、MR serial、QPN、QPN+PD 和 PD 五种 OCC flush 图案校验全部 selector 与 payload 字段。
  // 输入/输出及副作用：无显式参数；只读取 selector、qpn、mr_serial 和 pd_backing，返回与匹配图案或对齐错误对应的 rdma_status，不修改模型或外部资源。
  // 失败/边界：PD backing 非 4 KiB 对齐或字段组合不属于五种完整图案时
  //   返回 RDMA_SC_INVALID_ARGUMENT；QPN 图案允许驱动为 SMI 保留的 QPN 0，
  //   但仍要求 EIRQE/ORQE/UAQE 全部置位且其他字段为零。
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
                  mr_serial == 0 && pd_backing.value == 0;
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

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf(
      "OCC flush(vf=%0b mr_serial=%0b qpn=%0d serial=%0d pd=0x%016x)",
      vf_flush, mr_serial_flush, qpn, mr_serial, pd_backing.value
    );
  endfunction
endclass

class rdma_hw_cmq_empty_body extends rdma_hw_model;
  `uvm_object_utils(rdma_hw_cmq_empty_body)

  // 功能：构造 rdma_hw_cmq_empty_body，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_empty_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_empty_body");
    super.new(name);
  endfunction

  // 功能：将 rhs 中 rdma_hw_cmq_empty_body 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（empty CMQ body copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cmq_empty_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "empty CMQ body copy type mismatch")
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 的结果直接由 return rdma_status::success() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return "rdma empty CMQ command body";
  endfunction
endclass

class rdma_hw_cmq_body_token extends uvm_object;

  // 功能：构造 rdma_hw_cmq_body_token，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_body_token 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_body_token");
    super.new(name);
  endfunction
endclass

class rdma_hw_cmq_body_image extends rdma_hw_image;
  `uvm_object_utils(rdma_hw_cmq_body_image)

  local rdma_hw_cmq_body_token producer_token;
  local bit [7:0] producer_opcode;
  local rdma_hw_image immutable_snapshot;
  local bit initialized;

  // 功能：构造 rdma_hw_cmq_body_image，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：producer_token=null；producer_opcode='0；immutable_snapshot=null；initialized=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_body_image 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_body_image");
    super.new(name);
    producer_token = null;
    producer_opcode = '0;
    immutable_snapshot = null;
    initialized = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_cmq_body_image 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  virtual function void do_copy(uvm_object rhs);
    super.do_copy(rhs);
  endfunction

  // 功能：在 rdma_hw_cmq_body_image 中，matches_snapshot 逐字段核对快照、嵌套引用和 authority 值，确认复制结果既等值又无可变别名。
  // 输入/输出及副作用：无显式参数；matches_snapshot 读取 对象字段：immutable_snapshot、length、immutable_snapshot.length、alignment、immutable_snapshot.alignment、endian、immutable_snapshot.endian、image_kind 并使用字段 immutable_snapshot、length、immutable_snapshot.length、alignment、immutable_snapshot.alignment、endian、immutable_snapshot.endian、image_kind；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：matches_snapshot 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：initialize_once 更新字段 producer_token、producer_opcode、immutable_snapshot、initialized，并在提交前保持 Function authority、generation 和资源所有权约束。
  // 输入/输出及副作用：token（输入）、opcode（输入）；initialize_once 先依据 initialized；token == null 校验 token、opcode；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：initialize_once 返回 RDMA_SC_CODEC_ERROR；典型拒绝条件为“CMQ body artifact is already initialized”“CMQ body artifact producer token is null”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status initialize_once(
    rdma_hw_cmq_body_token token,
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
    immutable_snapshot = new("rdma_registered_cmq_body_snapshot");
    immutable_snapshot.copy(this);
    initialized = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cmq_body_image 中，authenticate 校验 body/profile 标识、owner generation 和镜像元数据，确认输入属于当前 codec 契约。
  // 输入/输出及副作用：token（输入）、opcode（输入）；authenticate 读取 token、opcode 并使用字段 rdma_status、initialized、producer_token、producer_opcode；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：authenticate 返回 RDMA_SC_CODEC_ERROR；具体拒绝条件包括 “CMQ body artifact is not registered by this composer”；“CMQ body artifact opcode is not exact”；“CMQ body artifact changed after build”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  function rdma_status authenticate(
    rdma_hw_cmq_body_token token,
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

virtual class rdma_hw_cmq_light_layout_codec extends uvm_object;
  localparam int unsigned BODY_BYTES = 64;

  // 功能：构造 rdma_hw_cmq_light_layout_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_light_layout_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_light_layout_codec");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_cmq_light_layout_codec 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_hw_cmq_body_image 中，codec_error 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；codec_error 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：codec_error 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：put 通过 qword builder 写入 CMQ light-body 的一个已授权字段，并把底层字段写入
  //   结果转换为该 codec 的诊断 status。
  // 输入/输出及副作用：builder、word_byte_offset、lsb、width、value（输入）；成功时更新
  //   builder 的 words/occupancy，函数不修改源 model 或取得外部资源所有权。
  // 失败/边界：builder 未初始化或字段越界、值宽度不符、字段重叠时透传底层失败并包装为
  //   CODEC_ERROR；调用方须在失败时丢弃正在构造的 image。
  protected function rdma_status put(
    rdma_hw_qword_builder builder,
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

  // 功能：validate_for_opcode 校验 opcode、model 与当前对象状态的一致性，并显式处理“cmq_light_body_builder”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）、model（输入）；validate_for_opcode 读取 opcode、model 并使用字段 image、status、builder、allowed、payload、candidate、candidate.length、candidate.alignment；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected pure virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );

  // 功能：在 rdma_hw_cmq_light_layout_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：opcode（输入）、model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected pure virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );

  // 功能：在 rdma_hw_cmq_body_image 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用字段 image、status、builder、allowed、payload、candidate、candidate.length、candidate.alignment；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 返回 函数体规定的失败状态；具体拒绝条件包括 “CMQ light-body mask lookup failed”；“CMQ light body writes request envelope bits”；“CMQ light-body qword %0d writes outside its mask”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected pure virtual function int unsigned owner_generation(
    rdma_hw_model model
  );

  // 功能：rdma_hw_cmq_light_layout_codec::encode 为派生 layout codec 创建 64B
  //   body image，先执行 opcode 专用校验/字段编码，再验证 body 与 envelope 的 ownership 不重叠。
  // 输入/输出及副作用：opcode、model 为只读输入，image 为输出；函数只发布带
  //   RDMA_IMAGE_CMQ_SQE 元数据的新 image，不修改 model 或其嵌套 handle。
  // 失败/边界：opcode/model 校验失败、mask lookup 失败、字段越界、保留位非零、
  //   envelope 位被 body 占用或序列化失败时返回错误，并保持 image=null。
  function rdma_status encode(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_hw_qword_builder builder;
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
      if (!rdma_raw_qword_mask_is_valid(words[q], allowed))
        return codec_error($sformatf(
          "CMQ light-body qword %0d writes outside its mask", q));
      if ((words[q] & request_envelope_mask(q)) !== 64'b0)
        return codec_error("CMQ light body writes request envelope bits");
    end
    payload = new[0];
    status = builder.serialize(payload);
    if (!status.ok()) return codec_error(status.message);
    candidate = rdma_hw_image::type_id::create("rdma_cmq_light_body");
    foreach (payload[i]) candidate.bytes.push_back(payload[i]);
    candidate.length = BODY_BYTES;
    candidate.alignment = BODY_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_CMQ_SQE;
    candidate.hardware_version = RDMA_HW_VERSION;
    candidate.function_generation = owner_generation(model);
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    image = candidate;
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_cmq_qpc_layout_codec
    extends rdma_hw_cmq_light_layout_codec;

  // 功能：构造 rdma_hw_cmq_qpc_layout_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_qpc_layout_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_qpc_layout_codec");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_cmq_qpc_layout_codec 中，encode_state 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：state（输入）、code（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_state 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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

  // 功能：validate_cq_handles 校验 body 与当前对象状态的一致性，并显式处理“QPC command send CQ”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：body（输入）；validate_cq_handles 读取 body 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected function rdma_status validate_cq_handles(
    rdma_hw_qpc_command_body body
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

  // 功能：validate_buffer 校验 body 与当前对象状态的一致性，并显式处理“QPC command buffer is not 512-byte aligned”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：body（输入）；validate_buffer 读取 body 并使用字段 rdma_status、value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected function rdma_status validate_buffer(
    rdma_hw_qpc_command_body body
  );
    if ((body.qpc_buffer.value & 64'h1ff) != 0)
      return invalid_argument("QPC command buffer is not 512-byte aligned");
    return rdma_status::success();
  endfunction

  // 功能：判断 has_modify_pairs 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：body（输入）；has_modify_pairs 读取 body 并使用字段 i；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：has_modify_pairs 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit has_modify_pairs(
    rdma_hw_qpc_command_body body
  );
    foreach (body.modify_start_qword[i]) begin
      if (body.modify_start_qword[i] != 0 || body.modify_wbe[i] != 0)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：判断 has_modify_data 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：body（输入）；has_modify_data 读取 body 并使用字段 i；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：has_modify_data 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit has_modify_data(
    rdma_hw_qpc_command_body body
  );
    foreach (body.modify_data[i])
      if (body.modify_data[i] != 0) return 1'b1;
    return 1'b0;
  endfunction

  // 功能：validate_for_opcode 校验 opcode、model 与当前对象状态的一致性，并显式处理“QPC light codec opcode is unsupported”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）、model（输入）；validate_for_opcode 读取 opcode、model 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_qpc_command_body body;
    rdma_status status;
    bit [2:0] state_code;
    if (!(opcode inside {RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY,
                         RDMA_OP_QPC_DELETE, RDMA_OP_QPC_QUERY}))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "QPC light codec opcode is unsupported");
    if (!$cast(body, model))
      return invalid_argument(
        "QPC light codec requires rdma_hw_qpc_command_body"
      );
    status = body.validate();
    if (!status.ok()) return status;
    if (opcode != RDMA_OP_QPC_MODIFY &&
        (body.full_modify || body.partial_modify))
      return invalid_argument("QPC modify mode used by a non-modify opcode");
    case (opcode)
      RDMA_OP_QPC_CREATE: begin
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
      RDMA_OP_QPC_MODIFY: begin
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
      RDMA_OP_QPC_DELETE: begin
        if (body.qpc_buffer.value != 0 ||
            body.next_state != RDMA_QPS_RESET ||
            body.wbe_template_count != 0 || has_modify_pairs(body) ||
            has_modify_data(body))
          return invalid_argument(
            "QPC delete contains create/modify/query fields"
          );
        return validate_cq_handles(body);
      end
      RDMA_OP_QPC_QUERY: begin
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

  // 功能：在 rdma_hw_cmq_qpc_layout_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用字段 generation；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_hw_qpc_command_body body;
    if (!$cast(body, model) || body.qp_h == null) return 0;
    return body.qp_h.generation;
  endfunction

  // 功能：在 rdma_hw_cmq_qpc_layout_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：opcode（输入）、model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_hw_qpc_command_body body;
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
      RDMA_OP_QPC_CREATE: begin
        `CMQ_QPC_PUT(RDMA_CMQ_QPN, body.qp_h.object_id)
        `CMQ_QPC_PUT(RDMA_CMQ_SQ_CQN, body.send_cq_h.object_id)
        `CMQ_QPC_PUT(RDMA_CMQ_SIGN_EN, 1)
        `CMQ_QPC_PUT(RDMA_CMQ_SIGNATURE, 0)
        `CMQ_QPC_PUT(RDMA_CMQ_RQ_CQN, body.recv_cq_h.object_id)
        `CMQ_QPC_PUT(RDMA_CMQ_QPC_BUFFER_ADDR,
                     body.qpc_buffer.value >> 9)
      end
      RDMA_OP_QPC_MODIFY: begin
        status = encode_state(body.next_state, state_code);
        if (!status.ok()) return status;
        modify_mode = body.full_modify ? RDMA_QPC_MODIFY_FULL :
                      body.partial_modify ? RDMA_QPC_MODIFY_PARTIAL :
                                            RDMA_QPC_MODIFY_STATE_ONLY;
        `CMQ_QPC_PUT(RDMA_CMQ_NEXT_QP_STATE, state_code)
        `CMQ_QPC_PUT(RDMA_CMQ_QPN, body.qp_h.object_id)
        `CMQ_QPC_PUT(RDMA_CMQ_SQ_CQN, body.send_cq_h.object_id)
        `CMQ_QPC_PUT(RDMA_CMQ_SIGN_EN, body.full_modify)
        `CMQ_QPC_PUT(RDMA_CMQ_SIGNATURE, 0)
        `CMQ_QPC_PUT(RDMA_CMQ_RQ_CQN, body.recv_cq_h.object_id)
        `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_MODE, modify_mode)
        `CMQ_QPC_PUT(RDMA_CMQ_WBE_TEMPLATE_COUNT,
                     body.wbe_template_count)
        if (body.full_modify) begin
          `CMQ_QPC_PUT(RDMA_CMQ_QPC_BUFFER_ADDR,
                       body.qpc_buffer.value >> 9)
        end
        else if (body.partial_modify) begin
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_START_QWORD0,
                       body.modify_start_qword[0])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_WBE0, body.modify_wbe[0])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_START_QWORD1,
                       body.modify_start_qword[1])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_WBE1, body.modify_wbe[1])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_START_QWORD2,
                       body.modify_start_qword[2])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_WBE2, body.modify_wbe[2])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_START_QWORD3,
                       body.modify_start_qword[3])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_WBE3, body.modify_wbe[3])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_DATA0, body.modify_data[0])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_DATA1, body.modify_data[1])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_DATA2, body.modify_data[2])
          `CMQ_QPC_PUT(RDMA_CMQ_MODIFY_DATA3, body.modify_data[3])
        end
      end
      RDMA_OP_QPC_DELETE: begin
        `CMQ_QPC_PUT(RDMA_CMQ_QPN, body.qp_h.object_id)
        `CMQ_QPC_PUT(RDMA_CMQ_SQ_CQN, body.send_cq_h.object_id)
        `CMQ_QPC_PUT(RDMA_CMQ_RQ_CQN, body.recv_cq_h.object_id)
      end
      RDMA_OP_QPC_QUERY: begin
        `CMQ_QPC_PUT(RDMA_CMQ_QPN, body.qp_h.object_id)
        `CMQ_QPC_PUT(RDMA_CMQ_QPC_BUFFER_ADDR,
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

class rdma_hw_cmq_object_id_layout_codec
    extends rdma_hw_cmq_light_layout_codec;
  protected bit [7:0] fixed_opcode;
  protected rdma_resource_kind_e fixed_kind;
  protected int unsigned fixed_width;

  // 功能：构造 rdma_hw_cmq_object_id_layout_codec，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：fixed_opcode=opcode；fixed_kind=kind；fixed_width=width。
  // 输入/输出及副作用：name、opcode、kind、width（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_object_id_layout_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(
    string name = "rdma_hw_cmq_object_id_layout_codec",
    bit [7:0] opcode = 0,
    rdma_resource_kind_e kind = RDMA_RESOURCE_CQ,
    int unsigned width = 21
  );
    super.new(name);
    fixed_opcode = opcode;
    fixed_kind = kind;
    fixed_width = width;
  endfunction

  // 功能：validate_for_opcode 校验 opcode、model 与当前对象状态的一致性，并显式处理“object-ID codec opcode does not match”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）、model（输入）；validate_for_opcode 读取 opcode、model 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_object_id_command_body body;
    rdma_status status;
    if (opcode != fixed_opcode)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "object-ID codec opcode does not match");
    if (!$cast(body, model))
      return invalid_argument(
        "object-ID codec requires rdma_hw_object_id_command_body"
      );
    status = body.validate();
    if (!status.ok()) return status;
    return rdma_context_handle_status(body.object_h, fixed_kind, fixed_width,
                                      "CMQ object-ID command");
  endfunction

  // 功能：在 rdma_hw_cmq_object_id_layout_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用字段 generation；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_hw_object_id_command_body body;
    if (!$cast(body, model) || body.object_h == null) return 0;
    return body.object_h.generation;
  endfunction

  // 功能：在 rdma_hw_cmq_object_id_layout_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：opcode（输入）、model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_hw_object_id_command_body body;
    if (!$cast(body, model))
      return invalid_argument("object-ID command body cast failed");
    return put(builder, 0, 0, fixed_width, body.object_h.object_id);
  endfunction
endclass

// CQC_DELETE 的 64B body 使用专用 layout：qword0 只有 CQN，qword1..7
// 承载驱动从 CQC context 原样 memcpy 的前 56 字节。该 codec 不复用
// object-ID codec，因而不会把 context 字段静默丢失或产生隐式错位。
class rdma_hw_cmq_cqc_delete_layout_codec
    extends rdma_hw_cmq_light_layout_codec;
  protected rdma_hw_cqc_create_body_codec context_codec;

  // 功能：构造 CQC_DELETE 专用 layout codec，并建立只读 context 编码器，
  //   用于把完整 CQC model 转成驱动要求的 56-byte raw context。
  // 输入/输出及副作用：name 为 UVM 实例名；context_codec 由本对象直接拥有，
  //   不取得 CQC model、CQ handle 或 Host-memory 的所有权。
  // 失败/边界：context codec 构造失败时 encode() 会返回 CODEC_ERROR；构造本身
  //   不发布 image，也不接受 generic object-ID body 作为降级路径。
  function new(string name = "rdma_hw_cmq_cqc_delete_layout_codec");
    super.new(name);
    context_codec = new("cmq_cqc_delete_context_codec");
  endfunction

  // 功能：校验 opcode 与 exact rdma_hw_cqc_delete_body wrapper，并执行完整
  //   CQC context 的语义验证。
  // 输入/输出及副作用：opcode/model 为只读输入；返回 rdma_status，不修改 body、
  //   context 或 codec 状态。
  // 失败/边界：opcode 不为 CQC_DELETE、model 为 null/派生或 body.validate()
  //   失败时拒绝；generic rdma_hw_object_id_command_body 永不被隐式接受。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_cqc_delete_body body;

    if (opcode != RDMA_OP_CQC_DELETE)
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        "CQC delete codec opcode does not match"
      );
    if (model == null ||
        model.get_object_type() != rdma_hw_cqc_delete_body::get_type() ||
        !$cast(body, model))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQC delete codec requires exact rdma_hw_cqc_delete_body"
      );
    return body.validate();
  endfunction

  // 功能：从 typed CQC_DELETE body 读取 CQ handle generation，供 CMQ image
  //   代际校验拒绝旧 Function binding。
  // 输入/输出及副作用：model 为只读输入；返回 generation 数值，不修改 body
  //   或任何资源账本。
  // 失败/边界：model/wrapper/context/CQ handle 任一缺失时返回 0；调用方必须将
  //   该值视为未绑定并在上层继续执行 generation authority 检查。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_hw_cqc_delete_body body;

    if (model == null ||
        model.get_object_type() != rdma_hw_cqc_delete_body::get_type() ||
        !$cast(body, model) || body.cqc_context == null ||
        body.cqc_context.cq_h == null)
      return 0;
    return body.cqc_context.cq_h.generation;
  endfunction

  // 功能：先用 CQC_CREATE context codec 编码完整 context，再按驱动 cmq.c
  //   的 memcpy(wqe + 1, ctx, 56) 规则把 context image 的 qword1..7
  //   （即 raw context qword0..6）放入 request qword1..7，并写入 CQN。
  // 输入/输出及副作用：opcode/model 为只读输入，builder 为当前 64B body 的
  //   可变写入器；成功时只更新 builder 的 qword0..7 ownership。
  // 失败/边界：context codec 缺失、context image metadata/长度错误、字段越界或
  //   memcpy overlap/range 错误时返回 CODEC_ERROR；context byte56..63 永不复制。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_hw_cqc_delete_body body;
    rdma_hw_image context_image;
    byte unsigned context_bytes[];
    rdma_status status;

    if (!$cast(body, model) || body.cqc_context == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQC delete body/context cast failed"
      );
    if (context_codec == null)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "CQC delete context codec is not initialized"
      );

    context_image = null;
    status = context_codec.encode(body.cqc_context, context_image);
    if (!status.ok())
      return status;
    if (context_image == null ||
        context_image.length != 64 ||
        context_image.bytes.size() != 64 ||
        context_image.image_kind != RDMA_IMAGE_CQC ||
        context_image.endian != RDMA_ENDIAN_BIG)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "CQC delete context image metadata is invalid"
      );

    status = put(builder, 0, 0, 21, body.cqc_context.cq_h.object_id);
    if (!status.ok())
      return status;

    context_bytes = new[56];
    // CQC_CREATE image 的 qword0 是独立的 CQN header，不属于驱动复制的
    // raw context；从 byte8 开始才对应 ctx_addr.va 的 byte0。
    for (int unsigned i = 0; i < 56; i++)
      context_bytes[i] = context_image.bytes[8 + i];
    status = builder.put_memcpy(8, context_bytes);
    if (!status.ok())
      return codec_error({"CQC delete context memcpy failed: ",
                          status.message});
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_cmq_mr_deregister_layout_codec
    extends rdma_hw_cmq_light_layout_codec;

  // 功能：构造 rdma_hw_cmq_mr_deregister_layout_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_mr_deregister_layout_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_mr_deregister_layout_codec");
    super.new(name);
  endfunction

  // 功能：validate_for_opcode 校验 opcode、model 与当前对象状态的一致性，并显式处理“MR deregister opcode does not match”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）、model（输入）；validate_for_opcode 读取 opcode、model 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_mr_deregister_body body;
    if (opcode != RDMA_OP_MR_DEREGISTER)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "MR deregister opcode does not match");
    if (!$cast(body, model))
      return invalid_argument(
        "MR deregister codec requires rdma_hw_mr_deregister_body"
      );
    return body.validate();
  endfunction

  // 功能：在 rdma_hw_cmq_mr_deregister_layout_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用字段 generation；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_hw_mr_deregister_body body;
    if (!$cast(body, model) || body.mr_h == null) return 0;
    return body.mr_h.generation;
  endfunction

  // 功能：在 rdma_hw_cmq_mr_deregister_layout_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：opcode（输入）、model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_hw_mr_deregister_body body;
    rdma_status status;
    bit [1:0] state_code;
    if (!$cast(body, model))
      return invalid_argument("MR deregister body cast failed");
    case (body.next_state)
      RDMA_CONTEXT_INVALID: state_code = RDMA_MR_ST_INVALID;
      RDMA_CONTEXT_VALID: state_code = RDMA_MR_ST_VALID;
      default: return invalid_argument("MR deregister state is unsupported");
    endcase
`define CMQ_MR_DEREG_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `CMQ_MR_DEREG_PUT(RDMA_MRT_BODY_STAG_IDX, body.mr_h.object_id)
    `CMQ_MR_DEREG_PUT(RDMA_MRT_BODY_NXT_ST, state_code)
    `CMQ_MR_DEREG_PUT(RDMA_MRT_BODY_STAG_KEY, body.stag_key)
`undef CMQ_MR_DEREG_PUT
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_cmq_occ_flush_layout_codec
    extends rdma_hw_cmq_light_layout_codec;

  // 功能：构造 rdma_hw_cmq_occ_flush_layout_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_occ_flush_layout_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_occ_flush_layout_codec");
    super.new(name);
  endfunction

  // 功能：validate_for_opcode 校验 opcode、model 与当前对象状态的一致性，并显式处理“OCC flush opcode does not match”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）、model（输入）；validate_for_opcode 读取 opcode、model 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_occ_flush_body body;
    if (opcode != RDMA_OP_OCC_FLUSH)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "OCC flush opcode does not match");
    if (!$cast(body, model))
      return invalid_argument(
        "OCC codec requires rdma_hw_occ_flush_body"
      );
    return body.validate();
  endfunction

  // 功能：在 rdma_hw_cmq_occ_flush_layout_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用输入参数和固定枚举/常量；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    return 0;
  endfunction

  // 功能：在 rdma_hw_cmq_occ_flush_layout_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：opcode（输入）、model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_hw_occ_flush_body body;
    rdma_status status;
    if (!$cast(body, model))
      return invalid_argument("OCC flush body cast failed");
`define CMQ_OCC_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_VF_FLUSH, body.vf_flush)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_MR_SERIAL_FLUSH, body.mr_serial_flush)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_QPN, body.qpn)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_QPC, body.qpc)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_CQC, body.cqc)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_MRT, body.mrt)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_PBLE, body.pble)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_SQRQE, body.sqrqe)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_SGB_IRQE, body.sgb_irqe)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_EIRQE, body.eirqe)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_ORQE, body.orqe)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_UAQE, body.uaqe)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_PD, body.pd)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_MR_SERIAL, body.mr_serial)
    `CMQ_OCC_PUT(RDMA_CMQ_OCC_PD_BACKING,
                 body.pd_backing.value >> 12)
`undef CMQ_OCC_PUT
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_cmq_empty_layout_codec
    extends rdma_hw_cmq_light_layout_codec;

  // 功能：构造 rdma_hw_cmq_empty_layout_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_empty_layout_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_empty_layout_codec");
    super.new(name);
  endfunction

  // 功能：validate_for_opcode 校验 opcode、model 与当前对象状态的一致性，并显式处理“empty CMQ body opcode does not match”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）、model（输入）；validate_for_opcode 读取 opcode、model 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_cmq_empty_body body;
    if (opcode != RDMA_OP_TQ_FLUSH)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "empty CMQ body opcode does not match");
    if (model == null)
      return rdma_status::success();
    if (!$cast(body, model))
      return invalid_argument(
        "TQ flush codec requires rdma_hw_cmq_empty_body"
      );
    return body.validate();
  endfunction

  // 功能：在 rdma_hw_cmq_empty_layout_codec 中，owner_generation 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：model（输入）；owner_generation 读取 model 并使用输入参数和固定枚举/常量；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：owner_generation 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    return 0;
  endfunction

  // 功能：在 rdma_hw_cmq_empty_layout_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：opcode（输入）、model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_cmq_light_body_codec extends uvm_object;
  `uvm_object_utils(rdma_hw_cmq_light_body_codec)

  protected rdma_hw_cmq_light_layout_codec codecs[256];

  // 功能：构造 rdma_hw_cmq_light_body_codec，并把 0.1.34 的 light-body opcode
  //   映射到 QPC、MR、OCC、CQC_DELETE、object-ID 或 empty layout codec。
  // 输入/输出及副作用：name 为 UVM 实例名输入；new 初始化 codecs[256] 和本对象
  //   直接拥有的 codec 实例，不取得任何 CQ/QP/Host-memory 的所有权。
  // 失败/边界：构造完成不代表某 opcode 可发送；未登记的 opcode 由 encode 返回
  //   RDMA_SC_UNSUPPORTED_OPCODE，codec 实例创建失败由后续调用显式报告。
  function new(string name = "rdma_hw_cmq_light_body_codec");
    rdma_hw_cmq_qpc_layout_codec qpc_codec;
    rdma_hw_cmq_mr_deregister_layout_codec mr_deregister_codec;
    rdma_hw_cmq_occ_flush_layout_codec occ_flush_codec;
    rdma_hw_cmq_object_id_layout_codec object_id_codec;
    rdma_hw_cmq_cqc_delete_layout_codec cqc_delete_codec;
    rdma_hw_cmq_empty_layout_codec empty_codec;
    super.new(name);
    foreach (codecs[i]) codecs[i] = null;
    qpc_codec = new("cmq_qpc_layout");
    codecs[RDMA_OP_QPC_CREATE] = qpc_codec;
    codecs[RDMA_OP_QPC_MODIFY] = qpc_codec;
    codecs[RDMA_OP_QPC_DELETE] = qpc_codec;
    codecs[RDMA_OP_QPC_QUERY] = qpc_codec;
    mr_deregister_codec = new("cmq_mr_deregister_layout");
    codecs[RDMA_OP_MR_DEREGISTER] = mr_deregister_codec;
    occ_flush_codec = new("cmq_occ_flush_layout");
    codecs[RDMA_OP_OCC_FLUSH] = occ_flush_codec;
    cqc_delete_codec = new("cmq_cqc_delete_layout");
    codecs[RDMA_OP_CQC_DELETE] = cqc_delete_codec;
    object_id_codec = new(
      "cmq_cqc_query_layout", RDMA_OP_CQC_QUERY,
      RDMA_RESOURCE_CQ, 21);
    codecs[RDMA_OP_CQC_QUERY] = object_id_codec;
    object_id_codec = new(
      "cmq_ceqc_delete_layout", RDMA_OP_CEQC_DELETE,
      RDMA_RESOURCE_CEQ, 12);
    codecs[RDMA_OP_CEQC_DELETE] = object_id_codec;
    object_id_codec = new(
      "cmq_ceqc_query_layout", RDMA_OP_CEQC_QUERY,
      RDMA_RESOURCE_CEQ, 12);
    codecs[RDMA_OP_CEQC_QUERY] = object_id_codec;
    object_id_codec = new(
      "cmq_aeqc_delete_layout", RDMA_OP_AEQC_DELETE,
      RDMA_RESOURCE_AEQ, 12);
    codecs[RDMA_OP_AEQC_DELETE] = object_id_codec;
    object_id_codec = new(
      "cmq_aeqc_query_layout", RDMA_OP_AEQC_QUERY,
      RDMA_RESOURCE_AEQ, 12);
    codecs[RDMA_OP_AEQC_QUERY] = object_id_codec;
    empty_codec = new("cmq_tq_flush_layout");
    codecs[RDMA_OP_TQ_FLUSH] = empty_codec;
    object_id_codec = new(
      "cmq_srfqc_delete_layout", RDMA_OP_SRFQC_DELETE,
      RDMA_RESOURCE_SRQ, 16);
    codecs[RDMA_OP_SRFQC_DELETE] = object_id_codec;
    object_id_codec = new(
      "cmq_srfqc_query_layout", RDMA_OP_SRFQC_QUERY,
      RDMA_RESOURCE_SRQ, 16);
    codecs[RDMA_OP_SRFQC_QUERY] = object_id_codec;

  endfunction

  // 功能：在 rdma_hw_cmq_light_body_codec 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：opcode（输入）、model（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function rdma_status encode(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    image = null;
    if (codecs[opcode] == null)
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("no rdma CMQ light body codec for opcode 0x%02x",
                  opcode)
      );
    return codecs[opcode].encode(opcode, model, image);
  endfunction
endclass

class rdma_hw_cmq_body_encoder extends uvm_object;
  `uvm_object_utils(rdma_hw_cmq_body_encoder)

  protected rdma_hw_cmq_light_body_codec light_codec;
  protected rdma_codec_registry context_codecs;

  // 功能：构造 rdma_hw_cmq_body_encoder，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：light_codec=rdma_hw_cmq_light_body_codec::type_id::create(；context_codecs=rdma_codec_registry::type_id::create(；status=rdma_register_context_body_codecs(context_codecs)。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_body_encoder 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_body_encoder");
    rdma_status status;
    super.new(name);
    light_codec = rdma_hw_cmq_light_body_codec::type_id::create(
      "cmq_exact_light_body_codec");
    context_codecs = rdma_codec_registry::type_id::create(
      "cmq_exact_context_body_registry");
    status = rdma_register_context_body_codecs(context_codecs);
    if (!status.ok())
      `uvm_fatal("RDMA_CMQ_REGISTRY", status.convert2string())
  endfunction

  // 功能：在 rdma_hw_cmq_body_encoder 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：opcode（输入）、model（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function rdma_status encode(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_codec_base codec;
    rdma_status status;

    image = null;
    if (rdma_cmq_is_context_opcode(opcode)) begin
      status = context_codecs.lookup(rdma_cmq_context_codec_key(opcode), codec);
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

// 0.1.34 CMQ 的请求和完成共享 64 字节 WQE。描述符把驱动 opcode、长度、
// 位所有权以及完成返回片段放在同一处，避免编码器和 checker 各自维护一份表。
class rdma_cmq_opcode_descriptor extends uvm_object;
  `uvm_object_utils(rdma_cmq_opcode_descriptor)

  bit [7:0] opcode;
  string symbolic_name;
  int unsigned request_bytes;
  int unsigned response_bytes;
  int unsigned completion_payload_offset;
  int unsigned completion_payload_length;
  bit [63:0] request_qword_masks[8];
  bit [63:0] response_qword_masks[8];
  rdma_status_code_e default_error;
  bit request_allowed;
  bit response_allowed;

  // 功能：构造 CMQ opcode 描述符并初始化为“未注册”安全状态。
  // 输入/输出及副作用：name 为 UVM 对象名输入；只初始化本地字段，不修改
  //   registry、CMQ ring 或外部资源。
  // 失败/边界：长度为零、允许位为零的对象不能通过 valid()，调用方不得提交。
  function new(string name = "rdma_cmq_opcode_descriptor");
    super.new(name);
    opcode = '0;
    symbolic_name = "";
    request_bytes = 0;
    response_bytes = 0;
    completion_payload_offset = 0;
    completion_payload_length = 0;
    foreach (request_qword_masks[i]) request_qword_masks[i] = '0;
    foreach (response_qword_masks[i]) response_qword_masks[i] = '0;
    default_error = RDMA_SC_UNKNOWN_HW_ERROR;
    request_allowed = 1'b0;
    response_allowed = 1'b0;
  endfunction

  // 功能：复制描述符值字段，生成与源对象隔离的 UVM 快照。
  // 输入/输出及副作用：rhs 为源对象输入；当前描述符字段被覆盖，源对象和
  //   registry 均不改变。
  // 失败/边界：rhs 类型不匹配时报告 UVM_FATAL，避免发布半成品描述符。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_opcode_descriptor source;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ opcode descriptor copy mismatch")
    opcode = source.opcode;
    symbolic_name = source.symbolic_name;
    request_bytes = source.request_bytes;
    response_bytes = source.response_bytes;
    completion_payload_offset = source.completion_payload_offset;
    completion_payload_length = source.completion_payload_length;
    request_qword_masks = source.request_qword_masks;
    response_qword_masks = source.response_qword_masks;
    default_error = source.default_error;
    request_allowed = source.request_allowed;
    response_allowed = source.response_allowed;
  endfunction

  // 功能：校验描述符长度、掩码和 completion payload slice 的自洽性。
  // 输入/输出及副作用：无显式输入；只读本对象字段，返回 bit，不推进 ring。
  // 失败/边界：非 64B CMQ 图像、越界 slice、请求/响应均未声明能力，或请求
  //   掩码覆盖 envelope 保留位时返回 0；response-only descriptor 仍可通过本
  //   校验，供真实 CQE 解码和字段审计使用。
  function bit valid();
    bit [63:0] envelope_mask;
    envelope_mask = 64'h8fff_3fff_0000_0000;
    if (opcode > RDMA_OP_OCC_PD_KICKOUT || symbolic_name == "")
      return 1'b0;
    if (request_bytes != RDMA_CMQE_BYTES ||
        response_bytes != RDMA_CMQE_BYTES ||
        (!request_allowed && !response_allowed))
      return 1'b0;
    if (completion_payload_offset + completion_payload_length >
        response_bytes)
      return 1'b0;
    if ((request_qword_masks[0] & envelope_mask) !== 64'b0)
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：返回稳定的 opcode/名称诊断文本，供 golden-vector 日志和错误定位。
  // 输入/输出及副作用：无显式输入；返回文本，不修改对象或资源账本。
  // 失败/边界：未初始化对象返回 unknown 文本并保留数值 opcode。
  function string describe();
    return $sformatf("CMQ opcode 0x%02x (%s) req=%0d rsp=%0d payload=%0d:%0d",
                     opcode, symbolic_name, request_bytes, response_bytes,
                     completion_payload_offset, completion_payload_length);
  endfunction
endclass

// CMQ registry 是 profile 的唯一 opcode 权威。它只保存固定 0.1.34 数据，
// lookup 返回快照，因此未知命令和调用方篡改都不会影响后续 ring 提交。
class rdma_cmq_codec_registry extends uvm_object;
  `uvm_object_utils(rdma_cmq_codec_registry)

  localparam int unsigned MAX_OPCODE = RDMA_OP_OCC_PD_KICKOUT;
  static rdma_cmq_opcode_descriptor descriptors[256];
  static bit initialized;

  // 功能：构造 registry 对象；实际描述符由静态 ensure_initialized 延迟建立。
  // 输入/输出及副作用：name 为 UVM 对象名输入；不分配外部资源、不修改 CMQ ring。
  // 失败/边界：构造不会假设外部 driver 存在；调用静态查询接口时若发现表不完整
  //   会返回明确的 CODEC_ERROR。
  function new(string name = "rdma_cmq_codec_registry");
    super.new(name);
    ensure_initialized();
  endfunction

  // 功能：返回驱动 0.1.34 的规范名称，集中维护名称而不是散落在 codec 分支。
  // 输入/输出及副作用：opcode 为输入；返回稳定 string，不修改 registry。
  // 失败/边界：未知 opcode 返回空字符串，调用方必须将其视为不支持。
  static function string opcode_name(bit [7:0] opcode);
    case (opcode)
      RDMA_OP_QPC_CREATE: return "QPC_CREATE";
      RDMA_OP_QPC_MODIFY: return "QPC_MODIFY";
      RDMA_OP_QPC_DELETE: return "QPC_DELETE";
      RDMA_OP_QPC_QUERY: return "QPC_QUERY";
      RDMA_OP_KEY_ALLOC: return "KEY_ALLOC";
      RDMA_OP_MR_REGISTER: return "MR_REGISTER";
      RDMA_OP_MR_DEREGISTER: return "MR_DEREGISTER";
      RDMA_OP_MW_ALLOC: return "MW_ALLOC";
      RDMA_OP_MW_DEALLOC: return "MW_DEALLOC";
      RDMA_OP_KEY_QUERY: return "KEY_QUERY";
      RDMA_OP_OCC_FLUSH: return "OCC_FLUSH";
      RDMA_OP_CQC_RESIZE: return "CQC_RESIZE";
      RDMA_OP_CQC_CREATE: return "CQC_CREATE";
      RDMA_OP_CQC_MODIFY: return "CQC_MODIFY";
      RDMA_OP_CQC_DELETE: return "CQC_DELETE";
      RDMA_OP_CQC_QUERY: return "CQC_QUERY";
      RDMA_OP_CEQC_CREATE: return "CEQC_CREATE";
      RDMA_OP_CEQC_MODIFY: return "CEQC_MODIFY";
      RDMA_OP_CEQC_DELETE: return "CEQC_DELETE";
      RDMA_OP_CEQC_QUERY: return "CEQC_QUERY";
      RDMA_OP_AEQC_CREATE: return "AEQC_CREATE";
      RDMA_OP_AEQC_MODIFY: return "AEQC_MODIFY";
      RDMA_OP_AEQC_DELETE: return "AEQC_DELETE";
      RDMA_OP_AEQC_QUERY: return "AEQC_QUERY";
      RDMA_OP_SD_UPDATE: return "SD_UPDATE";
      RDMA_OP_SD_QUERY: return "SD_QUERY";
      RDMA_OP_QP_FLUSH: return "QP_FLUSH";
      RDMA_OP_SRC_ADDR_UPDATE: return "SRC_ADDR_UPDATE";
      RDMA_OP_SRC_ADDR_QUERY: return "SRC_ADDR_QUERY";
      RDMA_OP_STAT_QUERY: return "STAT_QUERY";
      RDMA_OP_QPC_FORCE_DELETE: return "QPC_FORCE_DELETE";
      RDMA_OP_CQC_FORCE_DELETE: return "CQC_FORCE_DELETE";
      RDMA_OP_TQ_FLUSH: return "TQ_FLUSH";
      RDMA_OP_OCC_QPC: return "OCC_QPC";
      RDMA_OP_OCC_CQC: return "OCC_CQC";
      RDMA_OP_OCC_MRT: return "OCC_MRT";
      RDMA_OP_OCC_PBLE: return "OCC_PBLE";
      RDMA_OP_OCC_SQRQE: return "OCC_SQRQE";
      RDMA_OP_OCC_SGB: return "OCC_SGB";
      RDMA_OP_OCC_IRQE: return "OCC_IRQE";
      RDMA_OP_OCC_EIRQE: return "OCC_EIRQE";
      RDMA_OP_OCC_ORQE: return "OCC_ORQE";
      RDMA_OP_OCC_UAQE: return "OCC_UAQE";
      RDMA_OP_IDX_OCC_QPC: return "IDX_OCC_QPC";
      RDMA_OP_IDX_OCC_CQC: return "IDX_OCC_CQC";
      RDMA_OP_IDX_OCC_MRT: return "IDX_OCC_MRT";
      RDMA_OP_IDX_OCC_PBLE: return "IDX_OCC_PBLE";
      RDMA_OP_IDX_OCC_SQRQE: return "IDX_OCC_SQRQE";
      RDMA_OP_IDX_OCC_SGB: return "IDX_OCC_SGB";
      RDMA_OP_IDX_OCC_IRQE: return "IDX_OCC_IRQE";
      RDMA_OP_IDX_OCC_EIRQE: return "IDX_OCC_EIRQE";
      RDMA_OP_IDX_OCC_ORQE: return "IDX_OCC_ORQE";
      RDMA_OP_IDX_OCC_UAQE: return "IDX_OCC_UAQE";
      RDMA_OP_SRFQC_CREATE: return "SRFQC_CREATE";
      RDMA_OP_SRFQC_MODIFY: return "SRFQC_MODIFY";
      RDMA_OP_SRFQC_DELETE: return "SRFQC_DELETE";
      RDMA_OP_SRFQC_QUERY: return "SRFQC_QUERY";
      RDMA_OP_IFA_UPDATE: return "IFA_UPDATE";
      RDMA_OP_IFA_QUERY: return "IFA_QUERY";
      RDMA_OP_OCC_QPC_KICKOUT: return "OCC_QPC_KICKOUT";
      RDMA_OP_OCC_CQC_KICKOUT: return "OCC_CQC_KICKOUT";
      RDMA_OP_OCC_MRT_KICKOUT: return "OCC_MRT_KICKOUT";
      RDMA_OP_OCC_PBLE_KICKOUT: return "OCC_PBLE_KICKOUT";
      RDMA_OP_OCC_SQRQE_KICKOUT: return "OCC_SQRQE_KICKOUT";
      RDMA_OP_OCC_SGB_KICKOUT: return "OCC_SGB_KICKOUT";
      RDMA_OP_OCC_IRQE_KICKOUT: return "OCC_IRQE_KICKOUT";
      RDMA_OP_OCC_EIRQE_KICKOUT: return "OCC_EIRQE_KICKOUT";
      RDMA_OP_OCC_ORQE_KICKOUT: return "OCC_ORQE_KICKOUT";
      RDMA_OP_OCC_UAQE_KICKOUT: return "OCC_UAQE_KICKOUT";
      RDMA_OP_NOP: return "NOP";
      RDMA_OP_OCC_PD_SEARCH: return "OCC_PD_SEARCH";
      RDMA_OP_OCC_PD_IDX_SEARCH: return "OCC_PD_IDX_SEARCH";
      RDMA_OP_OCC_PD_KICKOUT: return "OCC_PD_KICKOUT";
      default: return "";
    endcase
  endfunction

  // 功能：判断指定 opcode 是否已有本模型中的完整 request body encoder。
  // 输入/输出及副作用：opcode 为驱动命令值输入；函数只读取固定的 0.1.34
  //   encoder 登记集合并返回 bit，不修改 descriptor、registry 或 ring。
  // 失败/边界：只有 context/light codec 已实际登记的命令返回 1；仅有 request
  //   mask 或 completion decoder 的 opcode 返回 0。
  static function bit has_request_encoder(bit [7:0] opcode);
    return opcode inside {
      RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY,
      RDMA_OP_QPC_DELETE, RDMA_OP_QPC_QUERY,
      RDMA_OP_KEY_ALLOC, RDMA_OP_MR_REGISTER,
      RDMA_OP_MR_DEREGISTER, RDMA_OP_OCC_FLUSH,
      RDMA_OP_CQC_CREATE, RDMA_OP_CQC_DELETE,
      RDMA_OP_CQC_QUERY, RDMA_OP_CEQC_CREATE,
      RDMA_OP_CEQC_DELETE, RDMA_OP_CEQC_QUERY,
      RDMA_OP_AEQC_CREATE, RDMA_OP_AEQC_DELETE,
      RDMA_OP_AEQC_QUERY, RDMA_OP_TQ_FLUSH,
      RDMA_OP_SRFQC_CREATE, RDMA_OP_SRFQC_DELETE,
      RDMA_OP_SRFQC_QUERY
    };
  endfunction

  // 功能：指示当前 descriptor 是否采用“零代际 body”过渡编码。
  // 输入/输出及副作用：opcode 为输入；返回 bit，不修改表或 ring。
  // 失败/边界：未注册 opcode 返回 0；专用上下文 opcode 保留原有 generation 规则。
  static function bit is_generationless(bit [7:0] opcode);
    return opcode inside {
      RDMA_OP_MW_ALLOC, RDMA_OP_MW_DEALLOC, RDMA_OP_KEY_QUERY,
      RDMA_OP_CQC_RESIZE, RDMA_OP_CQC_MODIFY, RDMA_OP_CEQC_MODIFY,
      RDMA_OP_AEQC_MODIFY, RDMA_OP_SD_UPDATE, RDMA_OP_SD_QUERY,
      RDMA_OP_SRC_ADDR_UPDATE, RDMA_OP_SRC_ADDR_QUERY, RDMA_OP_STAT_QUERY,
      RDMA_OP_QPC_FORCE_DELETE, RDMA_OP_CQC_FORCE_DELETE,
      RDMA_OP_OCC_FLUSH, RDMA_OP_TQ_FLUSH,
      RDMA_OP_OCC_QPC, RDMA_OP_OCC_CQC, RDMA_OP_OCC_MRT,
      RDMA_OP_OCC_PBLE, RDMA_OP_OCC_SQRQE, RDMA_OP_OCC_SGB,
      RDMA_OP_OCC_IRQE, RDMA_OP_OCC_EIRQE, RDMA_OP_OCC_ORQE,
      RDMA_OP_OCC_UAQE, RDMA_OP_IDX_OCC_QPC, RDMA_OP_IDX_OCC_CQC,
      RDMA_OP_IDX_OCC_MRT, RDMA_OP_IDX_OCC_PBLE, RDMA_OP_IDX_OCC_SQRQE,
      RDMA_OP_IDX_OCC_SGB, RDMA_OP_IDX_OCC_IRQE, RDMA_OP_IDX_OCC_EIRQE,
      RDMA_OP_IDX_OCC_ORQE, RDMA_OP_IDX_OCC_UAQE, RDMA_OP_SRFQC_MODIFY,
      RDMA_OP_IFA_UPDATE, RDMA_OP_IFA_QUERY, RDMA_OP_OCC_QPC_KICKOUT,
      RDMA_OP_OCC_CQC_KICKOUT, RDMA_OP_OCC_MRT_KICKOUT,
      RDMA_OP_OCC_PBLE_KICKOUT, RDMA_OP_OCC_SQRQE_KICKOUT,
      RDMA_OP_OCC_SGB_KICKOUT, RDMA_OP_OCC_IRQE_KICKOUT,
      RDMA_OP_OCC_EIRQE_KICKOUT, RDMA_OP_OCC_ORQE_KICKOUT,
      RDMA_OP_OCC_UAQE_KICKOUT, RDMA_OP_NOP, RDMA_OP_OCC_PD_SEARCH,
      RDMA_OP_OCC_PD_IDX_SEARCH, RDMA_OP_OCC_PD_KICKOUT
    };
  endfunction

  // 功能：返回驱动 0.1.34 中指定 opcode/qword 的请求字段所有权。
  // 输入/输出及副作用：opcode、qword 为输入；函数只计算掩码，不修改 registry。
  // 失败/边界：尚未建立语义模型的命令仍返回其硬件字段布局，但 body codec
  //   不会因此自动注册；未知 qword 返回零掩码。
  static function bit [63:0] request_mask(
    bit [7:0] opcode,
    int unsigned qword
  );
    bit [63:0] mask;
    mask = '0;
    if (qword > 7) return mask;
    case (opcode)
      RDMA_OP_MW_ALLOC: begin
        case (qword)
          0: begin
            // qword0 的 MRT 状态字段占用 62:61；bit63 属于
            // CMQ owner envelope，不能由命令 body 声明所有权。
            mask[62:61] = 2'b11;
            mask[23:0] = '1;
          end
          1: mask[31:24] = '1;
          2: begin
            // qword2 的有效片段为 [63:61]、[55:54]、bit48 和 [47:24]。
            // 用整字面量表达，避免把位段冒号误识别成 case label。
            mask = 64'hE0C1_FFFF_FF00_0000;
          end
          3: mask[63:56] = '1;
        endcase
      end
      RDMA_OP_MW_DEALLOC: begin
        case (qword)
          0: begin
            mask[62:61] = 2'b11;
            mask[23:0] = '1;
          end
          1: mask[31:24] = '1;
          2: begin
            mask[63:62] = '1;
            mask[48] = 1'b1;
            mask[47:24] = '1;
          end
          3: mask[63:56] = '1;
        endcase
      end
      RDMA_OP_KEY_QUERY:
        if (qword == 0) mask[23:0] = '1;
      RDMA_OP_CQC_RESIZE: begin
        case (qword)
          0: begin mask[27:24] = '1; mask[20:0] = '1; end
          1: mask[63:12] = '1;
          2: begin
            mask[63:59] = '1; mask[55:54] = '1;
            mask[53:51] = '1; mask[47] = 1'b1; mask[46:24] = '1;
          end
        endcase
      end
      RDMA_OP_CQC_MODIFY: begin
        if (qword == 0) begin
          mask[62:60] = '1;
          mask[31:22] = '1;
          mask[20:0] = '1;
        end
      end
      RDMA_OP_CEQC_MODIFY, RDMA_OP_AEQC_MODIFY,
      RDMA_OP_QPC_FORCE_DELETE, RDMA_OP_CQC_FORCE_DELETE,
      RDMA_OP_SD_QUERY, RDMA_OP_SRFQC_MODIFY:
        mask = '0;
      RDMA_OP_SD_UPDATE: begin
        case (qword)
          0: mask[7:0] = '1;
          1: begin mask[32] = 1'b1; mask[31:24] = '1; end
          2: mask = 64'h0000_0000_0000_0000;
          3: mask = 64'hffff_ffff_ffff_fe00;
          4: mask = 64'h0000_0000_0000_0fff;
          5: mask = 64'hffff_ffff_ffff_fff1;
          6: mask = 64'h0000_0000_0000_0fff;
          7: mask = 64'hffff_ffff_ffff_fff1;
        endcase
      end
      RDMA_OP_SRC_ADDR_UPDATE: begin
        case (qword)
          1: begin mask[63:52] = '1; mask[48] = 1'b1; mask[47:0] = '1; end
          2, 3: mask = 64'hffff_ffff_ffff_ffff;
        endcase
      end
      RDMA_OP_SRC_ADDR_QUERY:
        if (qword == 1) begin mask[63:52] = '1; mask[48] = 1'b1; end
      RDMA_OP_STAT_QUERY: begin
        case (qword)
          0: begin mask[62:61] = '1; mask[16] = 1'b1; mask[7:0] = '1; end
          3: mask = 64'hffff_ffff_ffff_ffff;
        endcase
      end
      RDMA_OP_OCC_QPC, RDMA_OP_OCC_CQC, RDMA_OP_OCC_MRT,
      RDMA_OP_OCC_PBLE, RDMA_OP_OCC_SQRQE, RDMA_OP_OCC_SGB,
      RDMA_OP_OCC_IRQE, RDMA_OP_OCC_EIRQE, RDMA_OP_OCC_ORQE,
      RDMA_OP_OCC_UAQE:
        if (qword == 1)
          mask[39:0] = '1;
        else if (qword == 3)
          mask = 64'hffff_ffff_ffff_ffff;
      RDMA_OP_OCC_QPC_KICKOUT, RDMA_OP_OCC_CQC_KICKOUT,
      RDMA_OP_OCC_MRT_KICKOUT, RDMA_OP_OCC_PBLE_KICKOUT,
      RDMA_OP_OCC_SQRQE_KICKOUT, RDMA_OP_OCC_SGB_KICKOUT,
      RDMA_OP_OCC_IRQE_KICKOUT, RDMA_OP_OCC_EIRQE_KICKOUT,
      RDMA_OP_OCC_ORQE_KICKOUT, RDMA_OP_OCC_UAQE_KICKOUT:
        if (qword == 1) mask[39:0] = '1;
      RDMA_OP_IDX_OCC_QPC, RDMA_OP_IDX_OCC_CQC, RDMA_OP_IDX_OCC_MRT,
      RDMA_OP_IDX_OCC_PBLE, RDMA_OP_IDX_OCC_SQRQE, RDMA_OP_IDX_OCC_SGB,
      RDMA_OP_IDX_OCC_IRQE, RDMA_OP_IDX_OCC_EIRQE, RDMA_OP_IDX_OCC_ORQE,
      RDMA_OP_IDX_OCC_UAQE:
        if (qword == 0) begin
          mask[23:16] = '1;
          mask[11:0] = '1;
        end
        else if (qword == 3)
          mask = 64'hffff_ffff_ffff_ffff;
      RDMA_OP_IFA_UPDATE: begin
        if (qword == 0)
          mask[61:60] = '1;
        else if (qword == 1) begin
          // 驱动 cmq.h 的 IFA update 数据定义到 bit57；bit58 只属于
          // IFA query response 的信息字段，不能混入 request ownership。
          // 保留位若被置位，后续 raw mask 校验必须拒绝该请求。
          mask = 64'h03ff_ffff_ffff_ffff;
        end
      end
      RDMA_OP_IFA_QUERY:
        if (qword == 0) mask[61:60] = '1;
      RDMA_OP_OCC_PD_SEARCH:
        if (qword == 1)
          mask[39:0] = '1;
        else if (qword == 3)
          mask = 64'hffff_ffff_ffff_ffff;
      RDMA_OP_OCC_PD_IDX_SEARCH:
        if (qword == 0) begin
          mask[23:16] = '1;
          mask[11:0] = '1;
        end
        else if (qword == 3)
          mask = 64'hffff_ffff_ffff_ffff;
      RDMA_OP_OCC_PD_KICKOUT:
        if (qword == 1) mask = 64'hffff_ffff_ffff_ffff;
      RDMA_OP_NOP: mask = '0;
      default: begin
        // 已有精确 body codec 的命令继续复用其 immutable ownership mask。
        if (!body_mask(RDMA_IMAGE_CMQ_SQE, opcode, 0, qword, mask))
          mask = '0;
      end
    endcase
    return mask;
  endfunction

  // 功能：返回 completion qword 的有效位掩码，保留位仍保持为零。
  // 输入/输出及副作用：opcode、qword 为输入；函数只计算掩码，不修改 registry。
  // 失败/边界：无 payload 的命令只允许公共 completion header。
  static function bit [63:0] response_mask(
    bit [7:0] opcode,
    int unsigned qword
  );
    bit [63:0] mask;
    mask = (qword == 0) ? 64'h8000_3fff_ff00_0000 : '0;
    if (qword > 7) return '0;
    case (opcode)
      RDMA_OP_KEY_QUERY:
        if (qword inside {[2:7]}) mask = '1;
      RDMA_OP_CQC_QUERY:
        if (qword inside {[1:7]}) mask = '1;
      RDMA_OP_CEQC_QUERY,
      RDMA_OP_AEQC_QUERY:
        if (qword == 0)
          mask = 64'h8000_3fff_ff00_0fff;
        else if (qword inside {[2:5]})
          mask = '1;
      RDMA_OP_SRFQC_QUERY:
        if (qword == 0)
          mask = 64'h8000_3fff_ff00_ffff;
        else if (qword inside {[2:5]})
          mask = '1;
      RDMA_OP_SRC_ADDR_QUERY: begin
        case (qword)
          1: mask = 64'hfff1_ffff_ffff_ffff;
          2, 3: mask = '1;
        endcase
      end
      RDMA_OP_IFA_QUERY: begin
        if (qword == 0)
          mask = 64'hb000_3fff_ff00_0000;
        else if (qword == 1)
          mask = 64'h07ff_ffff_ffff_ffff;
      end
      RDMA_OP_OCC_PD_SEARCH, RDMA_OP_OCC_PD_IDX_SEARCH: begin
        if (qword == 0)
          mask |= 64'h03ff_c000_00ff_0fff;
        else if (qword == 1) mask = 64'h0000_00ff_ffff_ffff;
        else if (qword == 3) mask = '1;
      end
      RDMA_OP_OCC_QPC, RDMA_OP_OCC_CQC, RDMA_OP_OCC_MRT,
      RDMA_OP_OCC_PBLE, RDMA_OP_OCC_SQRQE, RDMA_OP_OCC_SGB,
      RDMA_OP_OCC_IRQE, RDMA_OP_OCC_EIRQE, RDMA_OP_OCC_ORQE,
      RDMA_OP_OCC_UAQE,
      RDMA_OP_IDX_OCC_QPC, RDMA_OP_IDX_OCC_CQC, RDMA_OP_IDX_OCC_MRT,
      RDMA_OP_IDX_OCC_PBLE, RDMA_OP_IDX_OCC_SQRQE, RDMA_OP_IDX_OCC_SGB,
      RDMA_OP_IDX_OCC_IRQE, RDMA_OP_IDX_OCC_EIRQE, RDMA_OP_IDX_OCC_ORQE,
      RDMA_OP_IDX_OCC_UAQE:
        if (qword == 0)
          mask |= 64'h03ff_c000_00ff_0fff;
        else if (qword == 1)
          mask = 64'h0000_00ff_ffff_ffff;
        else if (qword == 3)
          mask = 64'hffff_ffff_ffff_ffff;
      default: ;
    endcase
    return mask;
  endfunction

  // 功能：一次性构造全部 0.1.34 描述符；所有字段在发布前完成固定值填充。
  // 输入/输出及副作用：无显式输入；写入静态 registry 一次，不触碰运行期 CMQ ring。
  // 失败/边界：重复调用幂等；若任一描述符生成后 valid() 失败，由 validate() 报告错误。
  static function void ensure_initialized();
    rdma_cmq_opcode_descriptor descriptor;
    if (initialized) return;
    initialized = 1'b1;
    foreach (descriptors[i]) descriptors[i] = null;
    for (int unsigned i = 0; i <= MAX_OPCODE; i++) begin
      descriptor = new($sformatf("cmq_opcode_%02x", i));
      descriptor.opcode = i[7:0];
      descriptor.symbolic_name = opcode_name(i[7:0]);
      descriptor.request_bytes = RDMA_CMQE_BYTES;
      descriptor.response_bytes = RDMA_CMQE_BYTES;
      descriptor.request_allowed = has_request_encoder(i[7:0]);
      descriptor.response_allowed = 1'b1;
      descriptor.default_error = RDMA_SC_UNKNOWN_HW_ERROR;
      for (int unsigned q = 1; q < 8; q++) begin
        descriptor.request_qword_masks[q] = request_mask(i[7:0], q);
        descriptor.response_qword_masks[q] = response_mask(i[7:0], q);
      end
      descriptor.request_qword_masks[0] = request_mask(i[7:0], 0);
      descriptor.response_qword_masks[0] = response_mask(i[7:0], 0);
      case (i[7:0])
        RDMA_OP_KEY_QUERY: begin
          descriptor.completion_payload_offset = 16;
          descriptor.completion_payload_length = 48;
        end
        RDMA_OP_CQC_QUERY: begin
          descriptor.completion_payload_offset = 8;
          descriptor.completion_payload_length = 56;
        end
        RDMA_OP_CEQC_QUERY, RDMA_OP_AEQC_QUERY, RDMA_OP_SRFQC_QUERY: begin
          descriptor.completion_payload_offset = 16;
          descriptor.completion_payload_length = 32;
        end
        RDMA_OP_SRC_ADDR_QUERY: begin
          descriptor.completion_payload_offset = 8;
          descriptor.completion_payload_length = 24;
        end
        RDMA_OP_IFA_QUERY: begin
          descriptor.completion_payload_offset = 8;
          descriptor.completion_payload_length = 8;
        end
        RDMA_OP_OCC_PD_SEARCH, RDMA_OP_OCC_PD_IDX_SEARCH: begin
          descriptor.completion_payload_offset = 8;
          descriptor.completion_payload_length = 24;
        end
        RDMA_OP_OCC_QPC, RDMA_OP_OCC_CQC, RDMA_OP_OCC_MRT,
        RDMA_OP_OCC_PBLE, RDMA_OP_OCC_SQRQE, RDMA_OP_OCC_SGB,
        RDMA_OP_OCC_IRQE, RDMA_OP_OCC_EIRQE, RDMA_OP_OCC_ORQE,
        RDMA_OP_OCC_UAQE,
        RDMA_OP_IDX_OCC_QPC, RDMA_OP_IDX_OCC_CQC, RDMA_OP_IDX_OCC_MRT,
        RDMA_OP_IDX_OCC_PBLE, RDMA_OP_IDX_OCC_SQRQE, RDMA_OP_IDX_OCC_SGB,
        RDMA_OP_IDX_OCC_IRQE, RDMA_OP_IDX_OCC_EIRQE,
        RDMA_OP_IDX_OCC_ORQE, RDMA_OP_IDX_OCC_UAQE: begin
          descriptor.completion_payload_offset = 8;
          descriptor.completion_payload_length = 24;
        end
        default: begin
          descriptor.completion_payload_offset = 0;
          descriptor.completion_payload_length = 0;
        end
      endcase
      descriptors[i] = descriptor;
    end
  endfunction

  // 功能：查询 opcode 是否存在于固定 registry。
  // 输入/输出及副作用：opcode 为输入；返回 bit，不修改任何状态。
  // 失败/边界：0x49 及以上和未定义值返回 0。
  static function bit is_supported(bit [7:0] opcode);
    ensure_initialized();
    return opcode <= MAX_OPCODE && descriptors[opcode] != null &&
           descriptors[opcode].valid();
  endfunction

  // 功能：查询指定 opcode 是否可由当前 CMQ request composer 编码并提交。
  // 输入/输出及副作用：opcode 为输入；函数读取静态 descriptor 快照并返回 bit，
  //   不修改 registry、body image 或 CMQ ring。
  // 失败/边界：未知 opcode、descriptor 非法或没有已登记 body encoder 时返回 0；
  //   completion-only opcode 仍可由 is_supported()/lookup() 查询，但不会通过本接口。
  static function bit is_request_supported(bit [7:0] opcode);
    ensure_initialized();
    return opcode <= MAX_OPCODE && descriptors[opcode] != null &&
           descriptors[opcode].valid() &&
           descriptors[opcode].request_allowed;
  endfunction

  // 功能：按 opcode 返回 detached 描述符快照，供编码器、测试和 golden reader 使用。
  // 输入/输出及副作用：opcode 为输入，descriptor 为输出；只读静态表，不推进 ring。
  // 失败/边界：未知 opcode 返回 RDMA_SC_UNSUPPORTED_OPCODE 且 descriptor 保持 null。
  static function rdma_status lookup(
    bit [7:0] opcode,
    output rdma_cmq_opcode_descriptor descriptor
  );
    uvm_object cloned_object;
    descriptor = null;
    ensure_initialized();
    if (!is_supported(opcode))
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("unsupported RDMA CMQ opcode 0x%02x", opcode));
    cloned_object = descriptors[opcode].clone();
    if (cloned_object == null || !$cast(descriptor, cloned_object))
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR, "CMQ opcode descriptor clone failed");
    return rdma_status::success();
  endfunction

  // 功能：验证 0.1.34 registry 的连续性与每个描述符的字段自洽性。
  // 输入/输出及副作用：无显式输入；返回 rdma_status，不修改 registry 或 ring。
  // 失败/边界：缺项、非法掩码或越界 completion slice 返回 CODEC_ERROR。
  static function rdma_status validate();
    ensure_initialized();
    for (int unsigned i = 0; i <= MAX_OPCODE; i++) begin
      if (descriptors[i] == null || !descriptors[i].valid())
        return rdma_status::make(
          RDMA_SC_CODEC_ERROR,
          $sformatf("CMQ opcode descriptor 0x%02x is invalid", i));
    end
    return rdma_status::success();
  endfunction

  // 功能：导出所有受支持 opcode，供 golden vectors 做顺序和数量校验。
  // 输入/输出及副作用：opcodes 为输出动态队列；只写入快照，不改变 registry。
  // 失败/边界：registry 无效时输出空队列，调用方应先检查 validate()。
  static function void list_supported(output bit [7:0] opcodes[$]);
    opcodes.delete();
    ensure_initialized();
    for (int unsigned i = 0; i <= MAX_OPCODE; i++)
      if (is_supported(i[7:0])) opcodes.push_back(i[7:0]);
  endfunction

  // 功能：导出所有具备真实 request body encoder 的 opcode，供 composer 门禁和
  //   capability golden 校验使用；completion-only opcode 不会出现在结果中。
  // 输入/输出及副作用：opcodes 为输出动态队列；只写入静态 registry 的排序快照，
  //   不推进 ring、不转移 image 所有权。
  // 失败/边界：registry 未初始化或 descriptor 无效时输出空队列；调用方应先检查
  //   validate()，并把空结果视为没有可发送命令。
  static function void list_request_supported(output bit [7:0] opcodes[$]);
    opcodes.delete();
    ensure_initialized();
    for (int unsigned i = 0; i <= MAX_OPCODE; i++)
      if (is_request_supported(i[7:0]))
        opcodes.push_back(i[7:0]);
  endfunction
endclass

class rdma_hw_cmq_body_registry extends uvm_object;
  `uvm_object_utils(rdma_hw_cmq_body_registry)

  protected bit registered[256];
  protected rdma_image_kind_e input_kinds[256];
  protected bit [63:0] body_masks[256][8];
  protected bit sealed;

  // 功能：构造 rdma_hw_cmq_body_registry，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：sealed=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_body_registry 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_body_registry");
    super.new(name);
    foreach (registered[i]) begin
      registered[i] = 1'b0;
      input_kinds[i] = RDMA_IMAGE_NONE;
      foreach (body_masks[i][q]) body_masks[i][q] = '0;
    end
    sealed = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_cmq_body_registry 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ body registry copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cmq_body_registry rhs_registry;
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
  // 输入/输出及副作用：opcode（输入）、input_kind（输入）、masks（输入）；调用方必须先完成输入对象的空值、authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
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

  // 功能：在 rdma_hw_cmq_body_registry 中，register_body 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：opcode（输入）、input_kind（输入）、masks（输入）；register_body 先依据 sealed；registered[opcode]；(masks[q] & request_envelope_mask(q 校验 opcode、input_kind、masks；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：register_body 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal，不保留部分有效快照。
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
      if ((masks[q] & request_envelope_mask(q)) !== 64'b0)
        return rdma_status::make(
          RDMA_SC_CODEC_ERROR,
          $sformatf("CMQ body opcode 0x%02x overlaps envelope qword %0d",
                    opcode, q)
        );
    end
    set_entry_unchecked(opcode, input_kind, masks);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cmq_body_registry 中，lookup 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：opcode（输入）、input_kind（输出）、masks（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：lookup 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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
        $sformatf("no rdma CMQ body registered for opcode 0x%02x", opcode)
      );
    input_kind = input_kinds[opcode];
    foreach (masks[q]) masks[q] = body_masks[opcode][q];
    return rdma_status::success();
  endfunction

  // 功能：validated_snapshot 复制 snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：snapshot（输出）；validated_snapshot 读取 snapshot 并使用字段 snapshot、status，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validated_snapshot 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  function rdma_status validated_snapshot(
    output rdma_hw_cmq_body_registry snapshot
  );
    rdma_status status;
    bit [63:0] masks[8];
    snapshot = rdma_hw_cmq_body_registry::type_id::create(
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

  // 功能：在 rdma_hw_cmq_body_registry 中，seal 冻结 codec/body registry，禁止运行期继续修改映射，保证 profile 选择结果稳定。
  // 输入/输出及副作用：无显式参数；seal 读取 对象字段：sealed 并使用字段 sealed；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：seal 无返回值，仅执行 sealed=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void seal();
    sealed = 1'b1;
  endfunction
endclass

// 功能：在 rdma_hw_cmq_body_registry 中，rdma_register_cmq_request_bodies 把 XTR v1 对应对象类型、opcode 和 variant 的 codec 注册到 profile registry，并拒绝重复键。
// 输入/输出及副作用：registry（输入）；rdma_register_cmq_request_bodies 读取 registry 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_register_cmq_request_bodies 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CMQ body registry is null”；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_register_cmq_request_bodies(
  rdma_hw_cmq_body_registry registry
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
  `CMQ_REGISTER_BODY(RDMA_OP_QPC_CREATE, RDMA_IMAGE_CMQ_SQE,
                     RDMA_QPC_CREATE_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_QPC_MODIFY, RDMA_IMAGE_CMQ_SQE,
                     RDMA_QPC_MODIFY_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_QPC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     RDMA_QPC_DELETE_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_QPC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     RDMA_QPC_QUERY_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_KEY_ALLOC, RDMA_IMAGE_MRT,
                     RDMA_MRT_KEY_ALLOC_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_MR_REGISTER, RDMA_IMAGE_MRT,
                     RDMA_MRT_REGISTER_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_MR_DEREGISTER, RDMA_IMAGE_CMQ_SQE,
                     RDMA_MR_DEREGISTER_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_OCC_FLUSH, RDMA_IMAGE_CMQ_SQE,
                     RDMA_OCC_FLUSH_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_CQC_CREATE, RDMA_IMAGE_CQC,
                     RDMA_CQC_CREATE_BODY_MASK)
  `CMQ_REGISTER_BODY(RDMA_OP_CQC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     RDMA_CQC_DELETE_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_CQC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     RDMA_CQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_CEQC_CREATE, RDMA_IMAGE_CEQC,
                     RDMA_CEQC_CREATE_BODY_MASK)
  `CMQ_REGISTER_BODY(RDMA_OP_CEQC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     RDMA_EQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_CEQC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     RDMA_EQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_AEQC_CREATE, RDMA_IMAGE_AEQC,
                     RDMA_AEQC_CREATE_BODY_MASK)
  `CMQ_REGISTER_BODY(RDMA_OP_AEQC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     RDMA_EQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_AEQC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     RDMA_EQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_TQ_FLUSH, RDMA_IMAGE_CMQ_SQE,
                     RDMA_EMPTY_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_SRFQC_CREATE, RDMA_IMAGE_SRQC,
                     RDMA_SRQC_CREATE_BODY_MASK)
  `CMQ_REGISTER_BODY(RDMA_OP_SRFQC_DELETE, RDMA_IMAGE_CMQ_SQE,
                     RDMA_SRQ_OBJECT_ID_BODY_OWNERSHIP)
  `CMQ_REGISTER_BODY(RDMA_OP_SRFQC_QUERY, RDMA_IMAGE_CMQ_SQE,
                     RDMA_SRQ_OBJECT_ID_BODY_OWNERSHIP)
`undef CMQ_REGISTER_BODY
  return rdma_status::success();
endfunction

class rdma_hw_cmq_envelope_codec extends uvm_object;
  `uvm_object_utils(rdma_hw_cmq_envelope_codec)

  // 功能：构造 rdma_hw_cmq_envelope_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_envelope_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_envelope_codec");
    super.new(name);
  endfunction

  // 功能：rdma_hw_cmq_envelope_codec::encode 将 valid/VFID/wrap/index/opcode 六个
  //   CMQ envelope 字段写入 64B builder，并验证 occupancy 只覆盖驱动 envelope 位。
  // 输入/输出及副作用：envelope 为只读输入，image 为输出；成功时发布带
  //   RDMA_IMAGE_CMQ_SQE 元数据的 detached image，不修改 envelope 或外部资源。
  // 失败/边界：envelope 为空、validate 失败、builder 序列化失败或 occupancy 与
  //   request_envelope_mask 不完全相等时返回错误，并保持 image=null。
  virtual function rdma_status encode(
    rdma_hw_cmq_envelope envelope,
    output rdma_hw_image image
  );
    rdma_hw_qword_builder builder;
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
    status = builder.reset(RDMA_CMQE_BYTES);
    if (!status.ok())
      return rdma_status::make(RDMA_SC_CODEC_ERROR, status.message);
`define CMQ_ENVELOPE_PUT(STEM, VALUE) \
    status = builder.put_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                               STEM``_WIDTH, VALUE); \
    if (!status.ok()) \
      return rdma_status::make(RDMA_SC_CODEC_ERROR, status.message);
    `CMQ_ENVELOPE_PUT(RDMA_CMQ_VALID, envelope.valid)
    `CMQ_ENVELOPE_PUT(RDMA_CMQ_VFID_OVERRIDE, envelope.vfid_override)
    `CMQ_ENVELOPE_PUT(RDMA_CMQ_USE_VFID, envelope.use_vfid)
    `CMQ_ENVELOPE_PUT(RDMA_CMQ_WRAP, envelope.wrap)
    `CMQ_ENVELOPE_PUT(RDMA_CMQ_WQE_INDEX, envelope.wqe_index)
    `CMQ_ENVELOPE_PUT(RDMA_CMQ_OPCODE, envelope.opcode)
`undef CMQ_ENVELOPE_PUT
    builder.get_occupancy(occupancy);
    foreach (occupancy[q]) begin
      if (occupancy[q] !== request_envelope_mask(q))
        return rdma_status::make(
          RDMA_SC_CODEC_ERROR,
          $sformatf("CMQ envelope qword %0d authorship mask mismatch", q)
        );
    end
    payload = new[0];
    status = builder.serialize(payload);
    if (!status.ok())
      return rdma_status::make(RDMA_SC_CODEC_ERROR, status.message);
    candidate = rdma_hw_image::type_id::create("rdma_cmq_envelope_image");
    foreach (payload[i]) candidate.bytes.push_back(payload[i]);
    candidate.length = RDMA_CMQE_BYTES;
    candidate.alignment = RDMA_CMQE_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_CMQ_SQE;
    candidate.hardware_version = RDMA_HW_VERSION;
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    image = candidate;
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_cmq_request_composer extends uvm_object;
  `uvm_object_utils(rdma_hw_cmq_request_composer)

  protected rdma_hw_cmq_body_registry ownership;
  protected rdma_hw_cmq_envelope_codec envelope_codec;
  local rdma_hw_cmq_envelope_codec canonical_envelope_codec;
  local rdma_hw_cmq_body_encoder body_encoder;
  local rdma_codec_registry context_codecs;
  local rdma_codec_registry qpc_codecs;
  local rdma_hw_cmq_body_token body_token;

  // 功能：构造 rdma_hw_cmq_request_composer，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：this.ownership=rdma_hw_cmq_body_registry::type_id::create(；status=rdma_register_cmq_request_bodies(this.ownership)；status=ownership.validated_snapshot(this.ownership)；this.envelope_codec=rdma_hw_cmq_envelope_codec::type_id::create(；this.envelope_codec=envelope_codec；canonical_envelope_codec=new("cmq_canonical_envelope_codec")；body_token=new("cmq_body_token")；body_encoder=new("cmq_exact_body_encoder")；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name、ownership、envelope_codec（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_request_composer 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(
    string name = "rdma_hw_cmq_request_composer",
    rdma_hw_cmq_body_registry ownership = null,
    rdma_hw_cmq_envelope_codec envelope_codec = null
  );
    rdma_status status;
    super.new(name);
    if (ownership == null) begin
      this.ownership = rdma_hw_cmq_body_registry::type_id::create(
        "cmq_default_body_registry");
      status = rdma_register_cmq_request_bodies(this.ownership);
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
      this.envelope_codec = rdma_hw_cmq_envelope_codec::type_id::create(
        "cmq_envelope_codec");
    else
      this.envelope_codec = envelope_codec;
    canonical_envelope_codec = new("cmq_canonical_envelope_codec");
    body_token = new("cmq_body_token");
    body_encoder = new("cmq_exact_body_encoder");
    context_codecs = rdma_codec_registry::type_id::create(
      "cmq_context_validation_registry");
    status = rdma_register_context_body_codecs(context_codecs);
    if (!status.ok())
      `uvm_fatal("RDMA_CMQ_REGISTRY", status.convert2string())
    qpc_codecs = rdma_codec_registry::type_id::create(
      "cmq_qpc_signature_validation_registry");
    status = rdma_register_qpc_codecs(qpc_codecs);
    if (!status.ok())
      `uvm_fatal("RDMA_CMQ_REGISTRY", status.convert2string())
  endfunction

  // 功能：build_body 在 request composer 入口先查询静态 request descriptor，再把
  //   opcode/model 转交给 exact body encoder 生成 64B body image。
  // 输入/输出及副作用：opcode、model 为输入，image 为输出；入口先清空 image，成功
  //   时由 mint_body 发布新 image，不修改 model、registry 或 CMQ ring。
  // 失败/边界：未知 opcode 或 descriptor 没有 request encoder 时返回
  //   RDMA_SC_UNSUPPORTED_OPCODE；body 校验/编码失败时保持 image=null 并透传原状态。
  function rdma_status build_body(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    image = null;
    if (!rdma_cmq_codec_registry::is_request_supported(opcode))
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("CMQ request opcode 0x%02x has no body encoder", opcode)
      );
    return mint_body(opcode, model, image);
  endfunction

  // 功能：在 rdma_hw_cmq_request_composer 中，codec_error 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；codec_error 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：codec_error 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：在 rdma_hw_cmq_request_composer 中，images_match 逐字段比较输入快照或镜像，确认其身份、布局和 payload 完全一致后返回布尔结果。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；images_match 读取 lhs、rhs 并使用字段 value；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：images_match 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：在 rdma_hw_cmq_request_composer 中，envelopes_match 逐字段比较输入快照或镜像，确认其身份、布局和 payload 完全一致后返回布尔结果。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；envelopes_match 读取 lhs、rhs 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：envelopes_match 先检查 lhs == null || rhs == null，再返回 lhs == rhs；拒绝分支不提交部分状态，也不隐式重试。
  local function bit envelopes_match(
    rdma_hw_cmq_envelope lhs,
    rdma_hw_cmq_envelope rhs
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
  // 输入/输出及副作用：destination（输入）、snapshot（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：restore_envelope 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  local function void restore_envelope(
    rdma_hw_cmq_envelope destination,
    rdma_hw_cmq_envelope snapshot
  );
    destination.valid = snapshot.valid;
    destination.vfid_override = snapshot.vfid_override;
    destination.use_vfid = snapshot.use_vfid;
    destination.wrap = snapshot.wrap;
    destination.wqe_index = snapshot.wqe_index;
    destination.opcode = snapshot.opcode;
  endfunction

  // 功能：在 rdma_hw_cmq_request_composer 中，authenticate_body 校验 body/profile 标识、owner generation 和镜像元数据，确认输入属于当前 codec 契约。
  // 输入/输出及副作用：opcode（输入）、image（输入）；authenticate_body 读取 opcode、image 并使用字段 body_token；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：authenticate_body 返回 RDMA_SC_CODEC_ERROR；典型拒绝条件为“CMQ body is not a registered artifact”；失败路径不提交部分状态或转移未声明资源。
  local function rdma_status authenticate_body(
    bit [7:0] opcode,
    rdma_hw_image image
  );
    rdma_hw_cmq_body_image artifact;
    if (!$cast(artifact, image))
      return codec_error("CMQ body is not a registered artifact");
    return artifact.authenticate(body_token, opcode);
  endfunction

  // 功能：在 rdma_hw_cmq_request_composer 中，mint_body 按容量、身份和生命周期约束预留或分配资源，并返回带 authority 证据的句柄或计划。
  // 输入/输出及副作用：opcode（输入）、model（输入）、image（输出）；mint_body 读取 opcode、model、image 并使用字段 image、raw_image、status、artifact，并写入 image；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：mint_body 返回 RDMA_SC_CODEC_ERROR；典型拒绝条件为“CMQ exact body encoder published null”；失败路径不提交部分状态或转移未声明资源。
  local function rdma_status mint_body(
    bit [7:0] opcode,
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_hw_cmq_body_image artifact;
    rdma_hw_image raw_image;
    rdma_status status;

    image = null;
    raw_image = null;
    status = body_encoder.encode(opcode, model, raw_image);
    if (!status.ok()) return status;
    if (raw_image == null)
      return codec_error("CMQ exact body encoder published null");
    artifact = new("rdma_registered_cmq_body");
    artifact.copy(raw_image);
    status = artifact.initialize_once(body_token, opcode);
    if (!status.ok()) return status;
    image = artifact;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cmq_request_composer 中，image_word 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：image（输入）、qword_index（输入）；image_word 读取 image、qword_index 并使用字段 word；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：image_word 是只读访问器，返回 word；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
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

  // 功能：validate_context_identity 按 opcode 查找唯一 context-body codec，解码 body 并以
  //   精确类型校验请求的 context identity。
  // 输入/输出及副作用：opcode、body（输入）；只读 registry 和 body，临时创建 decoded model，
  //   成功只返回 status，不发布或修改 caller 的 body/model。
  // 失败/边界：exact codec 缺失、lookup 返回错误/空 codec、body decode 失败或 decoded 为空时
  //   返回 CODEC_ERROR；任何失败都阻止后续 context request 提交。
  protected function rdma_status validate_context_identity(
    bit [7:0] opcode,
    rdma_hw_image body
  );
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    status = context_codecs.lookup(rdma_cmq_context_codec_key(opcode), codec);
    if (!status.ok() || codec == null)
      return codec_error("CMQ exact context-body codec lookup failed");
    decoded = null;
    status = codec.decode(body, decoded);
    if (!status.ok() || decoded == null)
      return codec_error({"CMQ body violates exact opcode codec: ",
                          (status == null) ? "null status" : status.message});
    return rdma_status::success();
  endfunction

  // 功能：validate_image_metadata 核对 context body image 的长度、对齐、端序、image kind、
  //   硬件版本和所有 backing/target 元数据是否符合调用方期望。
  // 输入/输出及副作用：image、expected_kind、expected_length、expected_alignment、label
  //   （输入）；只读 image，返回带 label 的 rdma_status，不修改 bytes、metadata 或外部资源。
  // 失败/边界：image 为空、长度或 byte 数不符、alignment/endian/kind/version 不符，或
  //   write/backing/HMC/BAR target 非零时返回 CODEC_ERROR；失败阻止后续 body decode/compose。
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
        image.hardware_version != RDMA_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return codec_error({label, " metadata is invalid"});
    return rdma_status::success();
  endfunction

  // 功能：validate_qpc_mode_image 校验 opcode、body、needs_signature 与当前对象状态的一致性，并显式处理“CMQ QPC body signature must initially be zero”；“CMQ QPC create must enable signature”；“CMQ state-only QPC modify has extra payload”；“CMQ full QPC modify must enable signature”；“CMQ full QPC modify has partial payload”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：opcode（输入）、body（输入）、needs_signature（输出）；validate_qpc_mode_image 读取 opcode、body、needs_signature 并使用字段 needs_signature、qword1、sign_en、signature、qword2、mode、partial_payload_nonzero、q，并写入 needs_signature；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
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
    if (!(opcode inside {RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY}))
      return rdma_status::success();
    qword1 = image_word(body, 1);
    sign_en = qword1[RDMA_CMQ_SIGN_EN_LSB];
    signature = qword1[RDMA_CMQ_SIGNATURE_LSB +: 8];
    if (signature !== 8'h00)
      return codec_error("CMQ QPC body signature must initially be zero");
    if (opcode == RDMA_OP_QPC_CREATE) begin
      if (!sign_en)
        return codec_error("CMQ QPC create must enable signature");
      needs_signature = 1'b1;
      return rdma_status::success();
    end
    qword2 = image_word(body, 2);
    mode = qword2[RDMA_CMQ_MODIFY_MODE_LSB +: 2];
    partial_payload_nonzero = 1'b0;
    for (int unsigned q = 4; q < 8; q++)
      partial_payload_nonzero |= image_word(body, q) !== 64'b0;
    case (mode)
      RDMA_QPC_MODIFY_STATE_ONLY: begin
        if (sign_en || image_word(body, 3) !== 64'b0 ||
            !rdma_raw_qword_mask_is_valid(
              qword2,
              64'h3 << RDMA_CMQ_MODIFY_MODE_LSB |
              64'h3 << RDMA_CMQ_WBE_TEMPLATE_COUNT_LSB) ||
            partial_payload_nonzero)
          return codec_error("CMQ state-only QPC modify has extra payload");
      end
      RDMA_QPC_MODIFY_FULL: begin
        if (!sign_en)
          return codec_error("CMQ full QPC modify must enable signature");
        if (!rdma_raw_qword_mask_is_valid(
              qword2,
              64'h3 << RDMA_CMQ_MODIFY_MODE_LSB |
              64'h3 << RDMA_CMQ_WBE_TEMPLATE_COUNT_LSB) ||
            partial_payload_nonzero)
          return codec_error("CMQ full QPC modify has partial payload");
        needs_signature = 1'b1;
      end
      RDMA_QPC_MODIFY_PARTIAL: begin
        if (sign_en || image_word(body, 3) !== 64'b0)
          return codec_error("CMQ partial QPC modify has signature/buffer");
      end
      default:
        return codec_error("CMQ QPC modify mode is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：validate_qpc_signature_source 解码 QPC signature source，并校验它与
  //   CMQ QPC body 的共享 QP 身份、transport variant 和 full-modify WBE 模板一致。
  // 输入/输出及副作用：source 和 body 须已由 compose_request 校验元数据与
  //   长度；函数只读 source 的 service_type、qp_h.kind/object_id、transport，
  //   以及 body 的 QPN、modify_mode、WBE 字段，返回 rdma_status，不修改输入或
  //   转移资源所有权。
  // 失败/边界：service_type 无映射、codec lookup/decode 或类型转换失败、QP handle
  //   缺失或 kind 错误、QPN 低 21 位不一致，以及 full modify 的 transport/WBE
  //   组合不受支持时返回 CODEC_ERROR；元数据不合法由调用者在进入本函数前
  //   拒绝。
  //   CMQ header 的 24-bit QPN 与 QPC context 的 21-bit QPN 不同宽，只比较 ABI
  //   共有的低 21 位，不截断任一线上字段。
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
    bit [20:0] body_qpc_qpn;
    bit [20:0] source_qpc_qpn;
    bit [1:0] modify_mode;
    bit [1:0] wbe_template;
    bit [1:0] expected_wbe_template;

    service_type = (image_word(source, 0) >>
                    RDMA_QPC_SERVICE_TYPE_LSB) & 3'h7;
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_QPC;
    key.object_type = "qpc";
    key.opcode = RDMA_OP_QPC_CREATE;
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
    // 驱动的 CMQ header QPN 是 GENMASK(23, 0)，而 QPC context QPN
    // 是 GENMASK_ULL(36, 16)。两者不是同宽字段：CMQ 保留完整 24-bit
    // canonical 值，身份校验只比较 ABI 共同定义的低 21 位。
    body_qpn = (image_word(body, 0) >> RDMA_CMQ_QPN_LSB) & 24'hff_ffff;
    if (decoded_qpc.qp_h == null ||
        decoded_qpc.qp_h.kind != RDMA_RESOURCE_QP)
      return codec_error(
        "QPC signature source QPN does not match the CMQ body"
      );
    body_qpc_qpn = body_qpn[20:0];
    source_qpc_qpn = decoded_qpc.qp_h.object_id[20:0];
    if (source_qpc_qpn != body_qpc_qpn)
      return codec_error(
        "QPC signature source QPN does not match the CMQ body"
      );
    modify_mode = (image_word(body, 2) >>
                   RDMA_CMQ_MODIFY_MODE_LSB) & 2'h3;
    if (modify_mode == RDMA_QPC_MODIFY_FULL) begin
      wbe_template = (image_word(body, 2) >>
                      RDMA_CMQ_WBE_TEMPLATE_COUNT_LSB) & 2'h3;
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

  // 功能：compose_request 将 envelope image 与已编码 body image 按 qword 合并，
  //   校验 opcode/ownership/context authority，并在 QPC full/create 场景计算最终签名。
  // 输入/输出及副作用：envelope、body、qpc_signature_source 为只读输入，result 为
  //   输出；入口清空 result，成功时发布完整 64B RDMA_IMAGE_CMQ_SQE，不修改输入 image。
  // 失败/边界：envelope 为空、opcode 无 encoder、body 元数据/掩码/identity 不符、
  //   QPC signature source 缺失或多余、合并后含未拥有位时返回错误并保持 result=null。
  function rdma_status compose_request(
    rdma_hw_cmq_envelope envelope,
    rdma_hw_image body,
    rdma_hw_image qpc_signature_source,
    output rdma_hw_image result
  );
    rdma_hw_image envelope_image;
    rdma_hw_image canonical_envelope_image;
    rdma_hw_image candidate;
    rdma_hw_cmq_envelope envelope_snapshot;
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
    if (!rdma_cmq_codec_registry::is_request_supported(envelope.opcode))
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("CMQ request opcode 0x%02x has no body encoder",
                  envelope.opcode)
      );
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
    status = validate_image_metadata(body, input_kind, RDMA_CMQE_BYTES,
                                     RDMA_CMQE_BYTES, "CMQ body image");
    if (!status.ok()) return status;
    for (int unsigned q = 0; q < 8; q++) begin
      body_word = image_word(body, q);
      if (!rdma_raw_qword_mask_is_valid(body_word, masks[q]))
        return codec_error($sformatf(
          "CMQ body qword %0d contains a bit outside opcode ownership", q));
    end
    for (int unsigned q = 0; q < 8; q++) begin
      if ((request_envelope_mask(q) & masks[q]) !== 64'b0)
        return codec_error($sformatf(
          "CMQ envelope/body ownership overlaps in qword %0d", q));
    end
    if (rdma_cmq_is_context_opcode(envelope_snapshot.opcode)) begin
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
                                       RDMA_QPC_BYTES,
                                       RDMA_QPC_BYTES,
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

    candidate = rdma_hw_image::type_id::create("rdma_cmq_request");
    for (int unsigned q = 0; q < 8; q++) begin
      envelope_word = image_word(envelope_image, q);
      body_word = image_word(body, q);
      merged_word = envelope_word | body_word;
      for (int unsigned i = 0; i < 8; i++)
        candidate.bytes.push_back(merged_word[63 - (i * 8) -: 8]);
    end
    if (needs_signature) begin
      signature_byte = RDMA_CMQ_SIGNATURE_WORD_BYTE_OFFSET +
                       (7 - (RDMA_CMQ_SIGNATURE_LSB >> 3));
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
      if (!rdma_raw_qword_mask_is_valid(
            merged_word, request_envelope_mask(q) | masks[q]))
        return codec_error("composed CMQ request contains an unowned bit");
    end
    if (((image_word(candidate, 0) >> RDMA_CMQ_OPCODE_LSB) & 8'hff) !=
        envelope_snapshot.opcode)
      return codec_error("composed CMQ opcode is not exact");

    candidate.length = RDMA_CMQE_BYTES;
    candidate.alignment = RDMA_CMQE_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_CMQ_SQE;
    candidate.hardware_version = RDMA_HW_VERSION;
    candidate.function_generation = body.function_generation;
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    result = candidate;
    return rdma_status::success();
  endfunction
endclass
