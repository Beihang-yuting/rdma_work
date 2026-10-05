// 目录/层次：硬件编解码层 codec/rdma/rdma_cmq_codecs.sv。
// 职责：定义 CMQ envelope/completion 与各 command body 的值模型，以及 light/QPC layout codec、
//   body encoder、opcode/codec registry、envelope codec 与请求组装。
// 依赖：依赖 types/model 层的 rdma_status、rdma_hw_image/model、context 模型与 codec registry 基础设施。
// 所有权与生命周期：对象只拥有自身值快照与深拷贝的嵌套模型；registry 持有 codec/descriptor，调用方持有 image。

// 功能：按 CMQ context-body opcode 生成唯一的 registry key（opcode、image kind、对象类型、variant）。
// 输入/输出及副作用：opcode 为输入；返回 rdma_codec_key，不访问 registry。
// 失败/边界：未知或保留 opcode 返回 RDMA_IMAGE_NONE/"invalid" 的 fail-closed key；六个 context opcode 须与
//   rdma_register_context_body_codecs 使用的 key 一致。
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
      // 默认值已 fail-closed 初始化；不把未知 opcode 猜测成 context body。
    end
  endcase
  return key;
endfunction

// 功能：判断 opcode 是否需要 context-body registry。
// 输入/输出及副作用：opcode 为输入；复用 rdma_cmq_context_codec_key 的映射，返回 bit，无副作用。
// 失败/边界：未知、保留或映射为 RDMA_IMAGE_NONE 的 opcode 返回 0。
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

  // 功能：构造 rdma_hw_cmq_envelope，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_envelope");
    super.new(name);
    valid = 1'b0;
    vfid_override = 1'b0;
    use_vfid = '0;
    wrap = 1'b0;
    wqe_index = '0;
    opcode = '0;
  endfunction

  // 功能：复制 rdma_hw_cmq_envelope 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（CMQ envelope copy type mismatch）。
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

  // 功能：校验 envelope 的 use_vfid 与 vfid_override 的一致性。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：未置 vfid_override 而 use_vfid 非零返回 INVALID_ARGUMENT。
  function rdma_status validate();
    if (!vfid_override && use_vfid != 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "rdma CMQ use-vfid requires VFID override"
      );
    return rdma_status::success();
  endfunction

  // 功能：输出 rdma_hw_cmq_envelope 的稳定诊断文本。
  // 输入/输出及副作用：只读对象字段；返回 string。
  // 失败/边界：无。
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

  // 功能：构造 rdma_hw_cmq_completion，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_completion");
    super.new(name);
    owner = 1'b0;
    opcode = '0;
    command_ecode = '0;
    wqe_index = '0;
    wrap = 1'b0;
    object_payload = new[0];
  endfunction

  // 功能：复制 rdma_hw_cmq_completion 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（CMQ completion copy type mismatch）。
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

  // 功能：构造 rdma_hw_cmq_completion_codec，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_completion_codec");
    super.new(name);
  endfunction

  // 功能：构造 CODEC_ERROR 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  local function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：按大端从 image.bytes 取第 qword_index 个 64 位字。
  // 输入/输出及副作用：image 只读；返回 64 位值。
  // 失败/边界：不检查 image 为空或下标越界，调用方须先校验长度。
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

  // 完成接收须独立于可注入的 request registry；这里只接受已定义公共 CQE 头或返回 payload 语义的 0.1.34 opcode。
  // 功能：判断 completion codec 是否拥有指定 opcode 的解码契约。
  // 输入/输出及副作用：opcode 为输入；只读固定支持集合，返回 bit。
  // 失败/边界：未知 opcode 或仅有 request body 而无 CQE payload 定义的命令返回 0。
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

  // 功能：按 opcode 与 qword 下标返回驱动 CQE 中可解释位的掩码，供 inspect_completion 做四态 raw-mask 检查。
  // 输入/输出及副作用：opcode、qword_index 为输入；返回 64 位掩码，纯计算。
  // 失败/边界：下标超出 0..7、opcode 未声明 payload 或该 qword 仅含保留位时返回 0；掩码外的 0/1/X/Z 位由调用方判为 codec 错误。
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
          // index/valid/SMAC；保留位 51:49 必须保持为零。
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

  // 功能：把各类查询/占用完成映射为 CQE payload 的起始字节与长度。
  // 输入/输出及副作用：opcode 为输入；first_byte、byte_count 为输出，入口先清零。
  // 失败/边界：KEY_QUERY=16/48、CQC_QUERY=8/56、CEQC/AEQC/SRFQC_QUERY=16/32、SRC_ADDR_QUERY=8/24、
  //   IFA_QUERY=8/8、OCC 查询=8/24；其余 opcode 输出 0/0。
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
        // 驱动从 byte8 读取 index，byte10 读取 MAC，byte16 读取 IPv6；
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

  // 功能：校验 64B CMQ CQE 的元数据、owner、opcode 与各 qword 的四态 ownership mask，并解码为 detached completion。
  // 输入/输出及副作用：image、expected_owner 为输入；ready、completion 为输出，入口先置 0/null，成功时发布新 completion。
  // 失败/边界：image 为空、长度/元数据错误、opcode 不支持或保留位含 X/Z/非零时返回对应 RDMA_SC_* 错误，
  //   ready=0、completion=null；owner 不匹配返回成功且不消费 CQE。
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

  // 功能：构造 rdma_hw_qpc_command_body，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
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

  // 功能：复制 rdma_hw_qpc_command_body 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（QPC command body copy type mismatch）。
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

  // 功能：校验 QPC command body 的 QP 句柄与 modify 模式。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：QP 句柄非法透传其错误；full_modify 与 partial_modify 同时置位返回 INVALID_ARGUMENT。
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

  // 功能：输出 rdma_hw_qpc_command_body 的稳定诊断文本。
  // 输入/输出及副作用：只读对象字段；返回 string。
  // 失败/边界：无。
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

  // 功能：构造 rdma_hw_object_id_command_body，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_hw_object_id_command_body");
    super.new(name);
    object_h = null;
  endfunction

  // 功能：复制 rdma_hw_object_id_command_body 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（object-ID command copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_object_id_command_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "object-ID command copy type mismatch")
    object_h = rdma_clone_handle_value(rhs_body.object_h,
                                       "object-ID command");
  endfunction

  // 功能：校验 object-ID command 的 object_h 非空。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：object_h 为空返回 INVALID_ARGUMENT。
  virtual function rdma_status validate();
    if (object_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "object-ID command handle is null");
    return rdma_status::success();
  endfunction

  // 功能：输出 rdma_hw_object_id_command_body 的稳定诊断文本。
  // 输入/输出及副作用：只读对象字段；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("object-ID command(kind=%s id=%0d)",
                     (object_h == null) ? "null" : object_h.kind.name(),
                     (object_h == null) ? 0 : object_h.object_id);
  endfunction
endclass

// 设计说明：CQC_DELETE 的 wire body 与 CQC_QUERY 不同——驱动会把 live CQC context 的前 56 字节原样复制到 WQE。
// 单独的 typed body 迫使调用方提供完整 context，避免把只有 CQN 的 object body 误当成可发送请求。
class rdma_hw_cqc_delete_body extends rdma_hw_model;
  `uvm_object_utils(rdma_hw_cqc_delete_body)

  rdma_cqc_model cqc_context;

  // 功能：构造 rdma_hw_cqc_delete_body，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cqc_delete_body");
    super.new(name);
    cqc_context = null;
  endfunction

  // 功能：复制 rdma_hw_cqc_delete_body 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（copy type mismatch）。
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

  // 功能：校验 CQC_DELETE body 的 exact wrapper、完整 CQC context 与 CQ 句柄，作为 layout codec 的输入门禁。
  // 输入/输出及副作用：只读 cqc_context 及嵌套字段；返回 status。
  // 失败/边界：context 为空/非精确 wrapper、context.validate() 失败、CQ 句柄缺失、kind 非 CQ 或 object ID 超过 21 位
  //   时返回 INVALID_ARGUMENT 或原始 validation status。
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

    status = rdma_status::nonnull(
      cqc_context.validate(),
      "CQC delete context validation returned null",
      RDMA_SC_INVALID_ARGUMENT
    );
    if (!status.ok())
      return status;

    return rdma_context_handle_status(
      cqc_context.cq_h, RDMA_RESOURCE_CQ, 21, "CQC delete CQ"
    );
  endfunction

  // 功能：输出 rdma_hw_cqc_delete_body 的稳定诊断文本。
  // 输入/输出及副作用：只读对象字段；返回 string。
  // 失败/边界：无。
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

  // 功能：构造 rdma_hw_mr_deregister_body，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_hw_mr_deregister_body");
    super.new(name);
    mr_h = null;
    stag_key = '0;
    next_state = RDMA_CONTEXT_INVALID;
  endfunction

  // 功能：复制 rdma_hw_mr_deregister_body 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（MR deregister body copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_mr_deregister_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MR deregister body copy type mismatch")
    mr_h = rdma_clone_handle_value(rhs_body.mr_h, "MR deregister");
    stag_key = rhs_body.stag_key;
    next_state = rhs_body.next_state;
  endfunction

  // 功能：校验 MR deregister body 的 MR 句柄与 next_state。
  // 输入/输出及副作用：只读对象字段；返回 status。
  // 失败/边界：MR 句柄非法透传其错误；next_state 不是 INVALID/VALID 返回 INVALID_ARGUMENT。
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

  // 功能：输出 rdma_hw_mr_deregister_body 的稳定诊断文本。
  // 输入/输出及副作用：只读对象字段；返回 string。
  // 失败/边界：无。
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

  // 功能：构造 rdma_hw_occ_flush_body，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
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

  // 功能：复制 rdma_hw_occ_flush_body 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（OCC flush body copy type mismatch）。
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

  // 功能：按 VF、MR serial、QPN、QPN+PD、PD 五种 OCC flush 图案校验 selector 与 payload 字段。
  // 输入/输出及副作用：只读 selector、qpn、mr_serial 与 pd_backing；返回 status。
  // 失败/边界：PD backing 非 4KiB 对齐或字段组合不属于五种完整图案返回 INVALID_ARGUMENT；
  //   QPN 图案允许驱动为 SMI 保留的 QPN 0，但仍要求 EIRQE/ORQE/UAQE 置位且其余字段为零。
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

  // 功能：输出 rdma_hw_occ_flush_body 的稳定诊断文本。
  // 输入/输出及副作用：只读对象字段；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf(
      "OCC flush(vf=%0b mr_serial=%0b qpn=%0d serial=%0d pd=0x%016x)",
      vf_flush, mr_serial_flush, qpn, mr_serial, pd_backing.value
    );
  endfunction
endclass

class rdma_hw_cmq_empty_body extends rdma_hw_model;
  `uvm_object_utils(rdma_hw_cmq_empty_body)

  // 功能：构造 rdma_hw_cmq_empty_body，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_empty_body");
    super.new(name);
  endfunction

  // 功能：复制 rdma_hw_cmq_empty_body 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（empty CMQ body copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cmq_empty_body rhs_body;
    super.do_copy(rhs);
    if (!$cast(rhs_body, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "empty CMQ body copy type mismatch")
  endfunction

  // 功能：校验空 CMQ body。
  // 输入/输出及副作用：无输入；返回 status。
  // 失败/边界：恒成功。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：输出 rdma_hw_cmq_empty_body 的稳定诊断文本。
  // 输入/输出及副作用：只读对象字段；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return "rdma empty CMQ command body";
  endfunction
endclass

class rdma_hw_cmq_body_token extends uvm_object;

  // 功能：构造 rdma_hw_cmq_body_token，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
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

  // 功能：构造 rdma_hw_cmq_body_image，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_body_image");
    super.new(name);
    producer_token = null;
    producer_opcode = '0;
    immutable_snapshot = null;
    initialized = 1'b0;
  endfunction

  // 功能：复制 rdma_hw_cmq_body_image 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    super.do_copy(rhs);
  endfunction

  // 功能：核对 body image 的各字段、嵌套引用与 authority 是否仍等于初始化时保存的不可变快照。
  // 输入/输出及副作用：只读对象字段与 immutable_snapshot；返回 bit。
  // 失败/边界：快照缺失或任一字段（长度、对齐、端序、kind、版本、target 等）不一致返回 0。
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

  // 功能：一次性初始化 body image：记录 producer token/opcode，并保存不可变快照。
  // 输入/输出及副作用：token、opcode 为输入；成功后置 initialized。
  // 失败/边界：已初始化或 token 为空返回 CODEC_ERROR。
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

  // 功能：认证 body image 确由该 composer 登记且自构建后未被改动。
  // 输入/输出及副作用：token、opcode 为输入；只读，返回 status。
  // 失败/边界：未初始化或 token 不符、opcode 不等、与不可变快照不一致，均返回 CODEC_ERROR。
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

  // 功能：构造 rdma_hw_cmq_body_image，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_light_layout_codec");
    super.new(name);
  endfunction

  // 功能：构造 INVALID_ARGUMENT 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 CODEC_ERROR 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：经 qword builder 写入 light-body 的一个字段，并把底层错误包装为 codec 诊断。
  // 输入/输出及副作用：builder、word_byte_offset、lsb、width、value 为输入；成功时更新 builder。
  // 失败/边界：builder 未初始化、字段越界、宽度不符或重叠时返回包装后的 CODEC_ERROR；调用方须丢弃正在构造的 image。
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

  // 功能：（纯虚）校验 opcode 与 model 是否适用于该 light body codec。
  // 输入/输出及副作用：opcode、model 为输入；返回 status。
  // 失败/边界：由子类定义，必需对象缺失或检查失败时返回非成功状态。
  protected pure virtual function rdma_status validate_for_opcode(
    bit [7:0] opcode,
    rdma_hw_model model
  );

  // 功能：（纯虚）把 model 按硬件布局编码进 builder。
  // 输入/输出及副作用：opcode、model 为输入，model 只读；builder 为输出；返回 status。
  // 失败/边界：由子类定义，失败时不发布部分字段。
  protected pure virtual function rdma_status encode_fields(
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );

  // 功能：（纯虚）返回 model 对应的 owner generation，用于填入 envelope。
  // 输入/输出及副作用：model 为输入；返回 generation。
  // 失败/边界：由子类定义。
  protected pure virtual function int unsigned owner_generation(
    rdma_hw_model model
  );

  // 功能：为派生 layout codec 创建 64B body image：先做 opcode 专用校验与字段编码，再确认 body 与 envelope 位不重叠。
  // 输入/输出及副作用：opcode、model 为只读输入；image 为输出，成功时为带 CMQ_SQE 元数据的新 image。
  // 失败/边界：校验失败、mask 查询失败、字段越界、保留位非零、占用 envelope 位或序列化失败返回错误，image 保持 null。
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

  // 功能：构造 rdma_hw_cmq_qpc_layout_codec，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_qpc_layout_codec");
    super.new(name);
  endfunction

  // 功能：把 QP 状态枚举编码为 3 位硬件状态码。
  // 输入/输出及副作用：state 为输入；code 为输出。
  // 失败/边界：SQD 与 SQE 共用编码 5；未知状态返回 INVALID_ARGUMENT。
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

  // 功能：校验 QPC command 的 send/recv CQ 句柄，及其与 QP 的生命周期一致性。
  // 输入/输出及副作用：body 只读；返回 status。
  // 失败/边界：CQ 句柄非法或与 QP 生命周期不匹配时透传对应错误。
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

  // 功能：校验 QPC command 的 buffer 地址 512 字节对齐。
  // 输入/输出及副作用：body 只读；返回 status。
  // 失败/边界：低 9 位非零返回 INVALID_ARGUMENT。
  protected function rdma_status validate_buffer(
    rdma_hw_qpc_command_body body
  );
    if ((body.qpc_buffer.value & 64'h1ff) != 0)
      return invalid_argument("QPC command buffer is not 512-byte aligned");
    return rdma_status::success();
  endfunction

  // 功能：判断 QPC modify body 是否带有 start_qword/wbe 对。
  // 输入/输出及副作用：body 只读；返回 bit。
  // 失败/边界：任一 start_qword 或 wbe 非零返回 1，否则 0。
  protected function bit has_modify_pairs(
    rdma_hw_qpc_command_body body
  );
    foreach (body.modify_start_qword[i]) begin
      if (body.modify_start_qword[i] != 0 || body.modify_wbe[i] != 0)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：判断 QPC modify body 是否带有非零 modify_data。
  // 输入/输出及副作用：body 只读；返回 bit。
  // 失败/边界：任一 modify_data 非零返回 1，否则 0。
  protected function bit has_modify_data(
    rdma_hw_qpc_command_body body
  );
    foreach (body.modify_data[i])
      if (body.modify_data[i] != 0) return 1'b1;
    return 1'b0;
  endfunction

  // 功能：校验 QPC light codec 的 opcode 与 model（CREATE/MODIFY/DELETE/QUERY）。
  // 输入/输出及副作用：opcode、model 为输入；调用 body.validate() 及状态/句柄/buffer 检查；返回 status。
  // 失败/边界：opcode 不支持返回 UNSUPPORTED_OPCODE；model 类型不符、非 MODIFY 带 modify 模式
  //   或其它检查失败返回 INVALID_ARGUMENT。
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

  // 功能：返回 model 的 QP 句柄 generation，供 envelope 使用。
  // 输入/输出及副作用：model 为输入；返回 generation。
  // 失败/边界：model 类型不符或句柄为空返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_hw_qpc_command_body body;
    if (!$cast(body, model) || body.qp_h == null) return 0;
    return body.qp_h.generation;
  endfunction

  // 功能：把 QPC command body 按硬件布局编码进 qword builder。
  // 输入/输出及副作用：opcode、model 为输入，model 只读；builder 为输出；返回 status。
  // 失败/边界：model 类型不符返回 INVALID_ARGUMENT；字段写入失败透传 put 的错误，失败时不发布部分字段。
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

  // 功能：构造 object-ID layout codec，并固定其 opcode、资源 kind 与 ID 位宽。
  // 输入/输出及副作用：name、opcode、kind、width 为输入；仅保存固定参数。
  // 失败/边界：无。
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

  // 功能：校验 object-ID codec 的 opcode 与 model。
  // 输入/输出及副作用：opcode、model 为输入；返回 status。
  // 失败/边界：opcode 与固定 opcode 不符返回 UNSUPPORTED_OPCODE；model 类型不符返回 INVALID_ARGUMENT；
  //   句柄 kind/位宽检查透传 rdma_context_handle_status。
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

  // 功能：返回 model 的 object 句柄 generation，供 envelope 使用。
  // 输入/输出及副作用：model 为输入；返回 generation。
  // 失败/边界：model 类型不符或句柄为空返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_hw_object_id_command_body body;
    if (!$cast(body, model) || body.object_h == null) return 0;
    return body.object_h.generation;
  endfunction

  // 功能：把 object-ID body（写入 object ID） 按硬件布局编码进 qword builder。
  // 输入/输出及副作用：opcode、model 为输入，model 只读；builder 为输出；返回 status。
  // 失败/边界：model 类型不符返回 INVALID_ARGUMENT；字段写入失败透传 put 的错误，失败时不发布部分字段。
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

// 设计说明：CQC_DELETE 的 64B body 使用专用 layout：qword0 只含 CQN，qword1..7 承载驱动从 CQC context
// 原样 memcpy 的前 56 字节。该 codec 不复用 object-ID codec，避免 context 字段被静默丢失或错位。
class rdma_hw_cmq_cqc_delete_layout_codec
    extends rdma_hw_cmq_light_layout_codec;
  protected rdma_hw_cqc_create_body_codec context_codec;

  // 功能：构造 rdma_hw_cmq_cqc_delete_layout_codec，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_cqc_delete_layout_codec");
    super.new(name);
    context_codec = new("cmq_cqc_delete_context_codec");
  endfunction

  // 功能：校验 opcode 与 exact rdma_hw_cqc_delete_body wrapper，并做完整 CQC context 的语义验证。
  // 输入/输出及副作用：opcode、model 只读；返回 status。
  // 失败/边界：opcode 非 CQC_DELETE 返回 UNSUPPORTED_OPCODE；model 为空/派生类型返回 INVALID_ARGUMENT；
  //   其余透传 body.validate()；通用 object-ID body 永不被隐式接受。
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

  // 功能：从 CQC_DELETE body 读取 CQ 句柄的 generation，供 CMQ image 代际校验拒绝旧 Function binding。
  // 输入/输出及副作用：model 只读；返回 generation。
  // 失败/边界：model/wrapper/context/CQ 句柄任一缺失返回 0，上层须继续做 generation authority 检查。
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

  // 功能：先用 CQC_CREATE context codec 编码完整 context，再按驱动 cmq.c 的 memcpy(wqe + 1, ctx, 56) 规则
  //   把 context image 的 qword1..7 放入 request qword1..7，并写入 CQN。
  // 输入/输出及副作用：opcode、model 只读；builder 为可变写入器，成功时更新 qword0..7 的 ownership。
  // 失败/边界：body/context 为空返回 INVALID_ARGUMENT；context codec 缺失、image 元数据/长度错误、字段越界或
  //   memcpy 范围错误返回 CODEC_ERROR；context byte56..63 永不复制。
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
    // CQC_CREATE image 的 qword0 是独立的 CQN header，不属于驱动复制的 raw context；
    // 从 byte8 开始才对应 ctx_addr.va 的 byte0。
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

  // 功能：构造 rdma_hw_cmq_mr_deregister_layout_codec，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_mr_deregister_layout_codec");
    super.new(name);
  endfunction

  // 功能：校验 MR deregister codec 的 opcode 与 model。
  // 输入/输出及副作用：opcode、model 为输入；返回 status。
  // 失败/边界：opcode 非 MR_DEREGISTER 返回 UNSUPPORTED_OPCODE；model 类型不符返回
  //   INVALID_ARGUMENT；其余透传 body.validate()。
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

  // 功能：返回 MR deregister body 中 MR 句柄的 generation，供 envelope 使用。
  // 输入/输出及副作用：model 为输入；返回 generation。
  // 失败/边界：model 类型不符或 mr_h 为空返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    rdma_hw_mr_deregister_body body;
    if (!$cast(body, model) || body.mr_h == null) return 0;
    return body.mr_h.generation;
  endfunction

  // 功能：把 MR deregister body 按硬件布局编码进 qword builder（含 next_state 对应的 MR 状态码）。
  // 输入/输出及副作用：opcode、model 为输入，model 只读；builder 为输出；返回 status。
  // 失败/边界：model 类型不符或 next_state 不被支持返回 INVALID_ARGUMENT；字段写入失败透传错误。
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

  // 功能：构造 rdma_hw_cmq_occ_flush_layout_codec，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_occ_flush_layout_codec");
    super.new(name);
  endfunction

  // 功能：校验 OCC flush codec 的 opcode 与 model。
  // 输入/输出及副作用：opcode、model 为输入；返回 status。
  // 失败/边界：opcode 非 OCC_FLUSH 返回 UNSUPPORTED_OPCODE；model 类型不符返回
  //   INVALID_ARGUMENT；其余透传 body.validate()。
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

  // 功能：OCC flush 无句柄代际，恒返回 0。
  // 输入/输出及副作用：model 未使用。
  // 失败/边界：恒返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    return 0;
  endfunction

  // 功能：把 OCC flush body 的 selector 与 payload 字段按硬件布局编码进 qword builder。
  // 输入/输出及副作用：opcode、model 为输入，model 只读；builder 为输出；返回 status。
  // 失败/边界：model 类型不符返回 INVALID_ARGUMENT；字段写入失败透传错误。
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

  // 功能：构造 rdma_hw_cmq_empty_layout_codec，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_empty_layout_codec");
    super.new(name);
  endfunction

  // 功能：校验 TQ_FLUSH（空 body）codec 的 opcode 与 model。
  // 输入/输出及副作用：opcode、model 为输入；返回 status。
  // 失败/边界：opcode 非 TQ_FLUSH 返回 UNSUPPORTED_OPCODE；model 为空视为成功；类型不符返回 INVALID_ARGUMENT。
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

  // 功能：空 body 无句柄代际，恒返回 0。
  // 输入/输出及副作用：model 未使用。
  // 失败/边界：恒返回 0。
  protected virtual function int unsigned owner_generation(
    rdma_hw_model model
  );
    return 0;
  endfunction

  // 功能：空 body 无字段可编码。
  // 输入/输出及副作用：参数均未使用，builder 不被修改。
  // 失败/边界：恒返回成功。
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

  // 功能：构造 light body codec，并登记各 opcode 对应的 layout codec。
  // 输入/输出及副作用：name 为 UVM 实例名；创建 QPC/MR/OCC/object-ID/CQC_DELETE/空 body 的 codec 并填入 codecs 表。
  // 失败/边界：无。
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

  // 功能：按 opcode 选择 light body codec 并编码。
  // 输入/输出及副作用：opcode、model 为输入；image 为输出（先置 null）。
  // 失败/边界：该 opcode 无登记 codec 返回 UNSUPPORTED_OPCODE；其余透传所选 codec 的结果。
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

  // 功能：构造 rdma_hw_cmq_body_encoder，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
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

  // 功能：编码 CMQ body：context opcode 走 context codec registry，其余走 light body codec。
  // 输入/输出及副作用：opcode、model 为输入；image 为输出（先置 null），成功后经 composer 认证。
  // 失败/边界：context codec 查询失败返回 CODEC_ERROR；其余透传所选 codec 的错误。
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

// 设计说明：0.1.34 CMQ 的请求与完成共享 64 字节 WQE；描述符把驱动 opcode、长度、位所有权与完成返回片段
// 放在同一处，避免编码器与 checker 各自维护一份表。
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

  // 功能：构造 rdma_cmq_opcode_descriptor，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
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

  // 功能：复制 rdma_cmq_opcode_descriptor 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（copy type mismatch）。
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

  // 功能：校验描述符的长度、掩码与 completion payload slice 自洽。
  // 输入/输出及副作用：只读本对象字段；返回 bit。
  // 失败/边界：opcode 超界或无名称、请求/响应长度非 64B、请求/响应均未声明能力、payload slice 越界、
  //   请求掩码覆盖 envelope 保留位时返回 0；response-only 描述符仍可通过。
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

  // 功能：输出 rdma_cmq_opcode_descriptor 的稳定诊断文本。
  // 输入/输出及副作用：只读对象字段；返回 string。
  // 失败/边界：无。
  function string describe();
    return $sformatf("CMQ opcode 0x%02x (%s) req=%0d rsp=%0d payload=%0d:%0d",
                     opcode, symbolic_name, request_bytes, response_bytes,
                     completion_payload_offset, completion_payload_length);
  endfunction
endclass

// 设计说明：CMQ registry 是 profile 的唯一 opcode 权威，只保存固定 0.1.34 数据；lookup 返回快照，
// 未知命令与调用方篡改都不会影响后续 ring 提交。
class rdma_cmq_codec_registry extends uvm_object;
  `uvm_object_utils(rdma_cmq_codec_registry)

  localparam int unsigned MAX_OPCODE = RDMA_OP_OCC_PD_KICKOUT;
  static rdma_cmq_opcode_descriptor descriptors[256];
  static bit initialized;

  // 功能：构造 registry，并确保静态描述符表已初始化。
  // 输入/输出及副作用：name 为 UVM 实例名；调用 ensure_initialized()。
  // 失败/边界：无。
  function new(string name = "rdma_cmq_codec_registry");
    super.new(name);
    ensure_initialized();
  endfunction

  // 功能：返回驱动 0.1.34 的规范 opcode 名称。
  // 输入/输出及副作用：opcode 为输入；返回 string。
  // 失败/边界：未知 opcode 返回空字符串，调用方须视为不支持。
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

  // 功能：判断 opcode 是否已有完整的 request body encoder。
  // 输入/输出及副作用：opcode 为输入；只读固定登记集合，返回 bit。
  // 失败/边界：仅 context/light codec 已登记的命令返回 1；只有 request mask 或 completion decoder 的返回 0。
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

  // 功能：判断 opcode 是否采用“零代际 body”过渡编码。
  // 输入/输出及副作用：opcode 为输入；返回 bit。
  // 失败/边界：不在固定集合内的 opcode 返回 0，专用 context opcode 保持原 generation 规则。
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

  // 功能：返回指定 opcode 与 qword 的请求字段位所有权掩码。
  // 输入/输出及副作用：opcode、qword 为输入；只计算掩码。
  // 失败/边界：qword>7 或无声明返回 0；尚无语义模型的命令仍返回硬件字段布局，但 body codec 不会因此注册。
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
            // qword0 的 MRT 状态字段占用 62:61；bit63 属于 CMQ owner envelope，不能由命令 body 声明所有权。
            mask[62:61] = 2'b11;
            mask[23:0] = '1;
          end
          1: mask[31:24] = '1;
          2: begin
            // qword2 的有效片段为 [63:61]、[55:54]、bit48 与 [47:24]；用整字面量表达，避免位段冒号被误识别为 case label。
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
          // 驱动 cmq.h 的 IFA update 数据定义到 bit57；bit58 只属于 IFA query response 的信息字段，
          // 不能混入 request ownership。保留位若被置位，后续 raw mask 校验须拒绝该请求。
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

  // 功能：返回 completion qword 的有效位掩码。
  // 输入/输出及副作用：opcode、qword 为输入；只计算掩码。
  // 失败/边界：无 payload 的命令只允许公共 completion header；qword>7 返回 0，保留位保持为零。
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

  // 功能：一次性构造全部 0.1.34 描述符并写入静态 registry。
  // 输入/输出及副作用：无输入；写静态 descriptors，不触碰 CMQ ring。
  // 失败/边界：重复调用幂等；描述符不自洽由 validate() 报告。
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

  // 功能：判断 opcode 是否存在于固定 registry。
  // 输入/输出及副作用：opcode 为输入；返回 bit。
  // 失败/边界：超过 MAX_OPCODE、未定义或描述符不合法返回 0。
  static function bit is_supported(bit [7:0] opcode);
    ensure_initialized();
    return opcode <= MAX_OPCODE && descriptors[opcode] != null &&
           descriptors[opcode].valid();
  endfunction

  // 功能：判断 opcode 是否可由 CMQ request composer 编码并提交。
  // 输入/输出及副作用：opcode 为输入；读取静态描述符，返回 bit。
  // 失败/边界：未知、描述符非法或无已登记 body encoder 返回 0；completion-only opcode 不通过本接口。
  static function bit is_request_supported(bit [7:0] opcode);
    ensure_initialized();
    return opcode <= MAX_OPCODE && descriptors[opcode] != null &&
           descriptors[opcode].valid() &&
           descriptors[opcode].request_allowed;
  endfunction

  // 功能：按 opcode 返回 detached 描述符快照。
  // 输入/输出及副作用：opcode 为输入；descriptor 为输出（clone 副本）。
  // 失败/边界：未知 opcode 返回 UNSUPPORTED_OPCODE，descriptor 保持 null。
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

  // 功能：校验 registry 的连续性与每个描述符自洽。
  // 输入/输出及副作用：无输入；返回 status。
  // 失败/边界：任一描述符缺失或 valid() 失败返回 CODEC_ERROR。
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

  // 功能：导出所有受支持 opcode，供 golden vector 校验顺序与数量。
  // 输入/输出及副作用：opcodes 为输出队列，先清空再按升序写入。
  // 失败/边界：registry 无效时可能得到空队列，调用方应先检查 validate()。
  static function void list_supported(output bit [7:0] opcodes[$]);
    opcodes.delete();
    ensure_initialized();
    for (int unsigned i = 0; i <= MAX_OPCODE; i++)
      if (is_supported(i[7:0])) opcodes.push_back(i[7:0]);
  endfunction

  // 功能：导出所有具备 request body encoder 的 opcode，供 composer 门禁与 capability golden 使用。
  // 输入/输出及副作用：opcodes 为输出队列，先清空再按升序写入。
  // 失败/边界：completion-only opcode 不出现；registry 无效时可能为空，调用方应先检查 validate()。
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

  // 功能：构造 rdma_hw_cmq_body_registry，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；只初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_body_registry");
    super.new(name);
    foreach (registered[i]) begin
      registered[i] = 1'b0;
      input_kinds[i] = RDMA_IMAGE_NONE;
      foreach (body_masks[i][q]) body_masks[i][q] = '0;
    end
    sealed = 1'b0;
  endfunction

  // 功能：复制 rdma_hw_cmq_body_registry 的值字段，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（CMQ body registry copy type mismatch）。
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

  // 功能：登记 opcode 的输入 image 类型与所有权掩码（不做校验）。
  // 输入/输出及副作用：opcode、input_kind、masks 为输入；写 registered/input_kinds/body_masks。
  // 失败/边界：无校验，调用方须先完成空值与掩码校验（见 register_body）。
  protected function void set_entry_unchecked(
    bit [7:0] opcode,
    rdma_image_kind_e input_kind,
    bit [63:0] masks[8]
  );
    registered[opcode] = 1'b1;
    input_kinds[opcode] = input_kind;
    foreach (masks[q]) body_masks[opcode][q] = masks[q];
  endfunction

  // 功能：登记一个 CMQ body 的 opcode、输入 image kind 与所有权掩码。
  // 输入/输出及副作用：opcode、input_kind、masks 为输入；成功时写入 registry 表。
  // 失败/边界：registry 已封存返回 INVALID_STATE；重复登记触发 RDMA_CMQ_BODY_DUPLICATE fatal；
  //   input_kind 不在允许集合返回 INVALID_ARGUMENT；掩码覆盖 envelope 位返回 CODEC_ERROR。
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

  // 功能：按 opcode 查询已登记的输入 image kind 与所有权掩码。
  // 输入/输出及副作用：opcode 为输入；input_kind、masks 为输出（先清零，值拷贝）。
  // 失败/边界：未登记返回 UNSUPPORTED_OPCODE，输出保持清零。
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

  // 功能：校验并复制出一个已封存的 registry 快照。
  // 输入/输出及副作用：snapshot 为输出；逐项经 register_body 复制登记并 seal。
  // 失败/边界：任一登记失败返回其 status，snapshot 置 null。
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

  // 功能：封存 registry，禁止运行期继续修改。
  // 输入/输出及副作用：置 sealed。
  // 失败/边界：无。
  function void seal();
    sealed = 1'b1;
  endfunction
endclass

// 功能：把 XTR 驱动 0.1.34 的各 request body 所有权掩码登记到 registry。
// 输入/输出及副作用：registry 为输入；逐个调用 register_body。
// 失败/边界：registry 为空返回 INVALID_ARGUMENT；任一登记失败即返回该 status。
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

  // 功能：构造 rdma_hw_cmq_envelope_codec，设置默认字段。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_envelope_codec");
    super.new(name);
  endfunction

  // 功能：把 valid/VFID/wrap/index/opcode 等 envelope 字段写入 64B builder，并确认占位只覆盖 envelope 位。
  // 输入/输出及副作用：envelope 只读；image 为输出，成功时为带 CMQ_SQE 元数据的 detached image。
  // 失败/边界：envelope 为空返回 INVALID_ARGUMENT；validate 失败、builder 序列化失败或占位与
  //   request_envelope_mask 不相等返回错误，image 保持 null。
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

  // 功能：构造 request composer，使用默认或注入的 body registry 与 envelope codec。
  // 输入/输出及副作用：name、ownership、envelope_codec 为输入；注入的 registry 复制为已校验的封存快照。
  // 失败/边界：默认 registry 登记失败或注入 registry 无效触发 RDMA_CMQ_REGISTRY fatal。
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

  // 功能：request composer 入口：先查静态 request 描述符，再交给 exact body encoder 生成 64B body image。
  // 输入/输出及副作用：opcode、model 为输入；image 为输出（先置 null），成功时由 mint_body 发布。
  // 失败/边界：未知 opcode 或无 request encoder 返回 UNSUPPORTED_OPCODE；编码失败时 image 为 null 并透传原状态。
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

  // 功能：构造 CODEC_ERROR 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：逐字段比较两个 hw image（元数据、字节与 field_summary）是否一致。
  // 输入/输出及副作用：lhs、rhs 只读；返回 bit。
  // 失败/边界：任一为空或任一字段不同返回 0。
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

  // 功能：逐字段比较两个 envelope 是否一致。
  // 输入/输出及副作用：lhs、rhs 只读；返回 bit。
  // 失败/边界：两者皆空视为相等，仅一方为空返回 0。
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

  // 功能：把 snapshot 的 envelope 字段恢复到 destination。
  // 输入/输出及副作用：destination、snapshot 为输入；覆盖 destination 的六个 envelope 字段。
  // 失败/边界：不检查空值，调用方须保证两者非空。
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

  // 功能：认证 body image 确为本 composer 登记的 artifact 且 opcode 一致。
  // 输入/输出及副作用：opcode、image 为输入；返回 status。
  // 失败/边界：image 不是 body artifact 返回 CODEC_ERROR；其余透传 artifact.authenticate。
  local function rdma_status authenticate_body(
    bit [7:0] opcode,
    rdma_hw_image image
  );
    rdma_hw_cmq_body_image artifact;
    if (!$cast(artifact, image))
      return codec_error("CMQ body is not a registered artifact");
    return artifact.authenticate(body_token, opcode);
  endfunction

  // 功能：经 exact body encoder 编码 body，并包装为登记的 body artifact。
  // 输入/输出及副作用：opcode、model 为输入；image 为输出（先置 null），成功时为已 initialize_once 的 artifact。
  // 失败/边界：编码失败透传其 status；encoder 返回空 image 返回 CODEC_ERROR。
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

  // 功能：按大端从 image.bytes 取第 qword_index 个 64 位字。
  // 输入/输出及副作用：image 只读；返回 64 位值。
  // 失败/边界：不检查 image 为空或下标越界，调用方须先校验长度。
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

  // 功能：按 opcode 查唯一 context-body codec，解码 body 并校验其 context identity。
  // 输入/输出及副作用：opcode、body 为输入；临时创建 decoded model，只返回 status。
  // 失败/边界：codec 缺失、lookup 失败、decode 失败或 decoded 为空返回 CODEC_ERROR，阻止后续 context request 提交。
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

  // 功能：核对 body image 的长度、对齐、端序、kind、硬件版本与 target 元数据是否符合期望。
  // 输入/输出及副作用：image、expected_kind、expected_length、expected_alignment、label 为输入；只读，返回 status。
  // 失败/边界：image 为空、长度或字节数不符、alignment/endian/kind/version 不符，或任一 target 非零返回 CODEC_ERROR。
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

  // 功能：校验 QPC CREATE/MODIFY body 的模式位与签名字段，并给出是否需要后续计算签名。
  // 输入/输出及副作用：opcode、body 为输入；needs_signature 为输出；只读。
  // 失败/边界：非 QPC CREATE/MODIFY 直接成功；签名字段初始非零、CREATE 未使能签名等不符合约束返回 CODEC_ERROR。
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

  // 功能：解码 QPC signature source，并校验其与 CMQ QPC body 的 QP 身份、transport variant、full-modify WBE 模板一致。
  // 输入/输出及副作用：source、body 的元数据与长度已由 compose_request 校验；只读，返回 status。
  // 失败/边界：service_type 无映射、codec lookup/decode 或类型转换失败、QP 句柄缺失或 kind 错误、QPN 低 21 位不一致、
  //   full modify 的 transport/WBE 组合不支持，均返回 CODEC_ERROR。
  //   CMQ header 的 24 位 QPN 与 QPC context 的 21 位 QPN 不同宽，只比较 ABI 共有的低 21 位。
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
    // 驱动的 CMQ header QPN 是 GENMASK(23, 0)，QPC context QPN 是 GENMASK_ULL(36, 16)，两者不同宽：
    // CMQ 保留完整 24 位 canonical 值，身份校验只比较 ABI 共同定义的低 21 位。
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

  // 功能：把 envelope image 与已编码 body image 按 qword 合并，校验 opcode/ownership/context authority，
  //   并在 QPC create/full modify 时计算最终签名。
  // 输入/输出及副作用：envelope、body、qpc_signature_source 只读；result 为输出（先置 null），成功时为完整 64B CMQ_SQE。
  // 失败/边界：envelope 为空、opcode 无 encoder、body 元数据/掩码/identity 不符、签名 source 缺失或多余、
  //   合并后含未拥有位均返回错误，result 保持 null。
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
