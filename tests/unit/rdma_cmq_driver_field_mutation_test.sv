// 目录：测试层 unit/rdma_cmq_driver_field_mutation_test.sv。
// 职责：逐行执行驱动派生 CMQ mutation 合同，并用 production composer、
//   completion decoder 和 doorbell encoder 闭合可启用的三条能力。
// 主要依赖：依赖只读 contract reader、Task 3 C oracle bytes、CMQ/QPC codec
//   与 hardware profile；预期坐标只来自冻结 TSV，不读取被测 SV mask。
// 所有权与生命周期：测试拥有每次 mutation 的 detached 图像和模型；不创建
//   Host-memory、PCIe 或 MMIO adapter，所有文件描述符在 helper 返回前关闭。

class rdma_cmq_driver_field_mutation_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_driver_field_mutation_test)

  localparam bit [23:0] CANONICAL_QPN = 24'ha1b2c3;
  localparam bit [20:0] CANONICAL_QPC_QPN = 21'h1b2c3;
  localparam bit [20:0] CANONICAL_SQ_CQN = 21'h155555;
  localparam bit [20:0] CANONICAL_RQ_CQN = 21'h0a3c5d;
  localparam bit [63:0] CANONICAL_QPC_IOVA =
    64'h0123_4567_89ab_c000;
  localparam int unsigned CANONICAL_INDEX = 21;
  localparam int unsigned DRIVER_SIGNATURE_BYTE = 12;
  localparam longint unsigned SQ_BACKING_BASE = 64'h0000_0000_4000_0000;

  rdma_cmq_field_evidence_row rows[$];
  rdma_cmq_profile_test profile_fixture;
  rdma_cmq_codec_test codec_fixture;
  rdma_hw_cmq_hw_profile profile;
  rdma_codec_base qpc_codec;
  rdma_hw_image canonical_qpc_request;
  rdma_hw_image production_qpc_request;

  int unsigned visited_bits;
  int unsigned typed_recompose_count;
  int unsigned correlated_recompose_count;
  int unsigned driver_fixed_reject_count;
  int unsigned raw_decode_mutation_count;
  int unsigned static_canonical_count;
  int unsigned static_unwritable_count;

  // 功能：构造 CMQ mutation gate，并为 profile、fixture 和六类证据计数建立确定初值。
  // 输入输出及副作用：name、parent 为 UVM component 输入；仅创建本地测试对象，不打开文件或启动事务。
  // 失败边界：构造成功不表示合同已闭合；reader、codec 或 oracle 的失败均在 run_phase 中报告。
  function new(
      string name = "rdma_cmq_driver_field_mutation_test",
      uvm_component parent = null
  );
    super.new(name, parent);

    profile_fixture = new("mutation_profile_fixture", null);
    codec_fixture = new("mutation_codec_fixture", null);
    profile = rdma_hw_cmq_hw_profile::type_id::create("mutation_profile");
    qpc_codec = null;
    canonical_qpc_request = null;
    production_qpc_request = null;

    visited_bits = 0;
    typed_recompose_count = 0;
    correlated_recompose_count = 0;
    driver_fixed_reject_count = 0;
    raw_decode_mutation_count = 0;
    static_canonical_count = 0;
    static_unwritable_count = 0;
  endfunction

  // 功能：hex_nibble 把 canonical 文件中的单个规范十六进制字符转换为四位数值。
  // 输入输出及副作用：ch 为只读 ASCII 输入，value 仅在成功时接收 0..15；函数不改变文件游标。
  // 失败边界：除 0-9、a-f、A-F 外的字符全部返回 0，避免 %x 宽松接受注释或残缺 token。
  function automatic bit hex_nibble(
      input int ch,
      output int unsigned value
  );
    value = 0;

    if (ch >= 8'h30 && ch <= 8'h39) begin
      value = ch - 8'h30;
      return 1'b1;
    end

    if (ch >= 8'h61 && ch <= 8'h66) begin
      value = ch - 8'h61 + 10;
      return 1'b1;
    end

    if (ch >= 8'h41 && ch <= 8'h46) begin
      value = ch - 8'h41 + 10;
      return 1'b1;
    end

    return 1'b0;
  endfunction

  // 功能：load_canonical_image 严格读取 Task 3 的单行 bytes.hex，并补齐 production API 所需的确定元数据。
  // 输入输出及副作用：relative_path、image_kind、length 为输入；返回新 image，文件只读且所有出口都会关闭 fd。
  // 失败边界：缺少 LF/CRLF、额外物理行、非单空格分隔、非两位 hex、注释、空 token 或字节数不符均返回 null。
  function automatic rdma_hw_image load_canonical_image(
      input string relative_path,
      input rdma_image_kind_e image_kind,
      input int unsigned length
  );
    int fd;
    int read_count;
    int unsigned high_nibble;
    int unsigned low_nibble;
    int token_digits;
    string raw_line;
    string extra_line;
    string line;
    rdma_hw_image image;

    fd = $fopen(relative_path, "r");
    if (fd == 0)
      return null;

    read_count = $fgets(raw_line, fd);
    if (read_count == 0 ||
        !rdma_cmq_contract_reader::strip_line_ending(raw_line, line) ||
        $fgets(extra_line, fd) != 0) begin
      $fclose(fd);
      return null;
    end

    image = rdma_hw_image::type_id::create("canonical_image");
    token_digits = 0;
    high_nibble = 0;
    low_nibble = 0;

    for (int i = 0; i < line.len(); i++) begin
      if (line.getc(i) == 8'h20) begin
        if (token_digits != 2) begin
          $fclose(fd);
          return null;
        end

        image.bytes.push_back(byte'((high_nibble << 4) | low_nibble));
        token_digits = 0;
      end
      else begin
        if (token_digits >= 2) begin
          $fclose(fd);
          return null;
        end

        if (token_digits == 0) begin
          if (!hex_nibble(line.getc(i), high_nibble)) begin
            $fclose(fd);
            return null;
          end
        end
        else begin
          if (!hex_nibble(line.getc(i), low_nibble)) begin
            $fclose(fd);
            return null;
          end
        end

        token_digits++;
      end
    end

    $fclose(fd);
    if (token_digits != 2)
      return null;

    image.bytes.push_back(byte'((high_nibble << 4) | low_nibble));
    if (image.bytes.size() != length)
      return null;

    image.length = length;
    image.alignment = length;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = image_kind;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 0;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;

    case (image_kind)
      RDMA_IMAGE_CMQ_SQE: begin
        image.function_generation = 7;
        image.write_target_kind = RDMA_HW_TARGET_BACKING;
        image.backing_target.value =
          SQ_BACKING_BASE + (CANONICAL_INDEX * 64);
      end

      RDMA_IMAGE_DOORBELL: begin
        image.function_generation = 7;
        image.write_target_kind = RDMA_HW_TARGET_BAR;
        image.bar_target.value = 0;
      end

      default: ;
    endcase

    return image;
  endfunction

  // 功能：images_equal 比较两个 detached hardware image 的字节、元数据和字段摘要是否完全相同。
  // 输入输出及副作用：lhs、rhs 只读；返回精确相等结果，不修改任一 image。
  // 失败边界：任一对象为空、队列尺寸不同或任一 target/generation 字段不同时返回 0。
  function automatic bit images_equal(
      input rdma_hw_image lhs,
      input rdma_hw_image rhs
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
      if (lhs.bytes[i] != rhs.bytes[i])
        return 1'b0;

    foreach (lhs.field_summary[i])
      if (lhs.field_summary[i] != rhs.field_summary[i])
        return 1'b0;

    return 1'b1;
  endfunction

  // 功能：clone_image 为 response mutation 创建完全 detached 的 raw image 副本。
  // 输入输出及副作用：source 只读；返回独立 clone，不改变 canonical bytes 或元数据。
  // 失败边界：source 为空、clone 返回空或动态类型错误时返回 null，并由调用方停止该行验证。
  function automatic rdma_hw_image clone_image(
      input rdma_hw_image source
  );
    uvm_object copy;
    rdma_hw_image result;

    if (source == null)
      return null;

    copy = source.clone();
    if (copy == null || !$cast(result, copy))
      return null;

    return result;
  endfunction

  // 功能：image_byte_xor 计算驱动签名算法使用的全 image 字节异或折叠值。
  // 输入输出及副作用：image 只读；返回所有 bytes 的 8 位 XOR，不修改 image 或 field_summary。
  // 失败边界：空 image 返回 0；调用方必须另行区分“空输入”和“合法零 parity”。
  function automatic byte unsigned image_byte_xor(
      input rdma_hw_image image
  );
    byte unsigned value;

    value = 0;
    if (image == null)
      return value;

    foreach (image.bytes[i])
      value ^= image.bytes[i];

    return value;
  endfunction

  // 功能：expected_qpc_signature 按 xtrdma_bytes_xor 数据流独立计算 QPC_CREATE signature byte。
  // 输入输出及副作用：sqe、source 只读；把 driver fields.tsv 固定的 byte12 视为未签名零位，返回 request/source XOR 的补码。
  // 失败边界：任一 image 为空或 SQE 不含 byte12 时返回 0；调用方会同时检查对象和长度，不能把该值当作成功证明。
  function automatic byte unsigned expected_qpc_signature(
      input rdma_hw_image sqe,
      input rdma_hw_image source
  );
    byte unsigned value;

    value = 0;
    if (sqe == null || source == null ||
        sqe.bytes.size() <= DRIVER_SIGNATURE_BYTE)
      return value;

    foreach (sqe.bytes[i]) begin
      if (i != DRIVER_SIGNATURE_BYTE)
        value ^= sqe.bytes[i];
    end

    foreach (source.bytes[i])
      value ^= source.bytes[i];

    return ~value;
  endfunction

  // 功能：handles_equal 比较资源句柄的 kind、Function authority、object ID 与 generation 值。
  // 输入输出及副作用：lhs、rhs 只读；返回值相等结果，不把引用相等误当作图独立性证明。
  // 失败边界：仅当双方都为空时空句柄相等；单边为空立即返回 0。
  function automatic bit handles_equal(
      input rdma_handle lhs,
      input rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;

    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：functions_equal 比较 CMQ command/slot 的完整 Function identity 快照。
  // 输入输出及副作用：lhs、rhs 只读；返回 UID、object ID 和 generation 的值相等结果。
  // 失败边界：双方都为空才相等；不会从默认 Function 或 topology 猜测缺失身份。
  function automatic bit functions_equal(
      input rdma_function_handle lhs,
      input rdma_function_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;

    return lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：qpc_graph_values_equal 比较 composer 可见的 command、body、source 与 slot 全部值，用于证明调用未篡改输入图。
  // 输入输出及副作用：两组 command/slot 均只读；函数只做深值比较，不修改对象或执行 codec。
  // 失败边界：任一必需对象、QPC body 或 opcode key 为空/类型不符时返回 0；不接受部分图相等。
  function automatic bit qpc_graph_values_equal(
      input rdma_cmq_command_desc lhs_command,
      input rdma_cmq_slot_context lhs_slot,
      input rdma_cmq_command_desc rhs_command,
      input rdma_cmq_slot_context rhs_slot
  );
    rdma_hw_qpc_command_body lhs_body;
    rdma_hw_qpc_command_body rhs_body;

    if (lhs_command == null || rhs_command == null ||
        lhs_slot == null || rhs_slot == null ||
        lhs_command.opcode_key == null || rhs_command.opcode_key == null ||
        !$cast(lhs_body, lhs_command.body) ||
        !$cast(rhs_body, rhs_command.body))
      return 1'b0;

    if (!functions_equal(lhs_command.function_h,
                         rhs_command.function_h) ||
        lhs_command.opcode_key.profile_name !=
          rhs_command.opcode_key.profile_name ||
        lhs_command.opcode_key.opcode != rhs_command.opcode_key.opcode ||
        lhs_command.opcode_key.variant != rhs_command.opcode_key.variant ||
        lhs_command.vfid_override != rhs_command.vfid_override ||
        lhs_command.use_vfid != rhs_command.use_vfid ||
        lhs_command.timeout != rhs_command.timeout ||
        !images_equal(lhs_command.qpc_signature_source,
                      rhs_command.qpc_signature_source))
      return 1'b0;

    if (!handles_equal(lhs_body.qp_h, rhs_body.qp_h) ||
        !handles_equal(lhs_body.send_cq_h, rhs_body.send_cq_h) ||
        !handles_equal(lhs_body.recv_cq_h, rhs_body.recv_cq_h) ||
        lhs_body.qpc_buffer.value != rhs_body.qpc_buffer.value ||
        lhs_body.next_state != rhs_body.next_state ||
        lhs_body.full_modify != rhs_body.full_modify ||
        lhs_body.partial_modify != rhs_body.partial_modify ||
        lhs_body.wbe_template_count != rhs_body.wbe_template_count)
      return 1'b0;

    foreach (lhs_body.modify_start_qword[i]) begin
      if (lhs_body.modify_start_qword[i] !=
            rhs_body.modify_start_qword[i] ||
          lhs_body.modify_wbe[i] != rhs_body.modify_wbe[i] ||
          lhs_body.modify_data[i] != rhs_body.modify_data[i])
        return 1'b0;
    end

    return functions_equal(lhs_slot.function_h, rhs_slot.function_h) &&
           handles_equal(lhs_slot.cmq_h, rhs_slot.cmq_h) &&
           lhs_slot.backing_addr.value == rhs_slot.backing_addr.value &&
           lhs_slot.relative_offset == rhs_slot.relative_offset &&
           lhs_slot.slot_sequence == rhs_slot.slot_sequence &&
           lhs_slot.sq_index == rhs_slot.sq_index &&
           lhs_slot.sq_wrap == rhs_slot.sq_wrap;
  endfunction

  // 功能：clone_qpc_graph 同时复制 command 与 slot，形成可用于调用前后不可变性比较的 detached 快照。
  // 输入输出及副作用：source_command/source_slot 只读；成功时输出两个独立 clone，不保留对源 body/source/handle 的引用。
  // 失败边界：任一输入为空、clone 或 cast 失败时清空两个输出并返回 0，禁止使用半完成快照。
  function automatic bit clone_qpc_graph(
      input rdma_cmq_command_desc source_command,
      input rdma_cmq_slot_context source_slot,
      output rdma_cmq_command_desc command_copy,
      output rdma_cmq_slot_context slot_copy
  );
    uvm_object copy;

    command_copy = null;
    slot_copy = null;
    if (source_command == null || source_slot == null)
      return 1'b0;

    copy = source_command.clone();
    if (copy == null || !$cast(command_copy, copy)) begin
      command_copy = null;
      return 1'b0;
    end

    copy = source_slot.clone();
    if (copy == null || !$cast(slot_copy, copy)) begin
      command_copy = null;
      slot_copy = null;
      return 1'b0;
    end

    return 1'b1;
  endfunction

  // 功能：ensure_qpc_codec 初始化一次 RC QPC production codec，供 signature source 的 typed decode/encode mutation 复用。
  // 输入输出及副作用：failure_reason 输出失败原因；成功时更新本测试拥有的 registry 与 qpc_codec 引用。
  // 失败边界：fixture 为空、注册失败、lookup 失败或返回 null codec 时返回 0，不继续构造未经认证的 source image。
  function automatic bit ensure_qpc_codec(
      output string failure_reason
  );
    rdma_status status;

    failure_reason = "";
    if (qpc_codec != null)
      return 1'b1;

    if (codec_fixture == null) begin
      failure_reason = "QPC fixture is null";
      return 1'b0;
    end

    codec_fixture.qpc_registry =
      rdma_codec_registry::type_id::create("mutation_qpc_registry");
    status = rdma_register_qpc_codecs(codec_fixture.qpc_registry);
    if (status == null || !status.ok()) begin
      failure_reason = "QPC codec registry registration failed";
      return 1'b0;
    end

    status = codec_fixture.qpc_registry.lookup(
      codec_fixture.qpc_key("rc"), qpc_codec
    );
    if (status == null || !status.ok() || qpc_codec == null) begin
      qpc_codec = null;
      failure_reason = "RC QPC codec lookup failed";
      return 1'b0;
    end

    return 1'b1;
  endfunction

  // 功能：build_qpc_graph 构造与 Task 3 C oracle 完全同值、且由 typed QPC codec 产生 signature source 的独立有效图。
  // 输入输出及副作用：输出 command、slot、source 和失败原因；仅创建本地对象并可能初始化 QPC registry。
  // 失败边界：fixture/codec 失败、source encode 失败或 source XOR 不为驱动 fixture 固定的零 parity 时返回 0，不修补最终 SQE。
  function automatic bit build_qpc_graph(
      output rdma_cmq_command_desc command,
      output rdma_cmq_slot_context slot,
      output rdma_hw_image source,
      output string failure_reason
  );
    rdma_status status;
    rdma_qpc_model qpc;
    rdma_hw_qpc_command_body body;
    rdma_cmq_opcode_key key;
    rdma_function_handle command_function;
    rdma_function_handle slot_function;
    rdma_handle cmq_h;

    command = null;
    slot = null;
    source = null;
    failure_reason = "";

    if (profile_fixture == null ||
        !ensure_qpc_codec(failure_reason))
      return 1'b0;

    qpc = codec_fixture.make_signature_qpc(CANONICAL_QPC_QPN);

    // C oracle 的 512-byte QPC pattern XOR 为零。这里仍走 production QPC
    // codec，只调整一个不参与 CMQ identity 的 typed 字节，使 source parity
    // 与驱动 fixture 相同；绝不把 C raw pattern 注入 composer。
    qpc.qp_sequence = 8'h07;
    status = qpc_codec.encode(qpc, source);
    if (status == null || !status.ok() || source == null) begin
      failure_reason = "typed QPC source encode failed";
      return 1'b0;
    end

    if (image_byte_xor(source) != 0) begin
      failure_reason = "typed QPC source parity does not match C oracle";
      return 1'b0;
    end

    command_function =
      profile_fixture.make_function("mutation_command_function");
    slot_function =
      profile_fixture.make_function("mutation_slot_function");
    cmq_h = profile_fixture.make_handle(
      "mutation_cmq", RDMA_RESOURCE_CMQ, 32'h44
    );

    body = codec_fixture.make_qpc_body(
      "mutation_qpc_body", RDMA_OP_QPC_CREATE
    );
    body.qp_h.object_id = CANONICAL_QPN;
    body.send_cq_h.object_id = CANONICAL_SQ_CQN;
    body.recv_cq_h.object_id = CANONICAL_RQ_CQN;
    body.qpc_buffer.value = CANONICAL_QPC_IOVA;
    body.qp_h.function_uid = command_function.function_uid;
    body.send_cq_h.function_uid = command_function.function_uid;
    body.recv_cq_h.function_uid = command_function.function_uid;
    body.qp_h.generation = command_function.generation;
    body.send_cq_h.generation = command_function.generation;
    body.recv_cq_h.generation = command_function.generation;

    key = rdma_cmq_opcode_key::type_id::create("mutation_qpc_key");
    key.profile_name = "rdma";
    key.opcode = RDMA_OP_QPC_CREATE;
    key.variant = "rc";

    command = rdma_cmq_command_desc::type_id::create("mutation_command");
    command.function_h = command_function;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = source;
    command.vfid_override = 1'b0;
    command.use_vfid = '0;
    command.timeout = 100;

    slot = profile_fixture.make_slot(
      "mutation_slot", slot_function, cmq_h
    );
    slot.backing_addr.value = SQ_BACKING_BASE;
    slot.relative_offset = CANONICAL_INDEX * 64;
    slot.slot_sequence = CANONICAL_INDEX;
    slot.sq_index = CANONICAL_INDEX;
    slot.sq_wrap = 1'b0;

    return 1'b1;
  endfunction

  // 功能：rewrite_qpc_source 从 clone 的 source 解码 typed QPC，修改 QPN 或 PD-index 的一个字段位，再由同一 production codec 重编码。
  // 输入输出及副作用：command、field、field_bit 输入；成功时仅替换 command.qpc_signature_source，不修改原始 baseline command。
  // 失败边界：decode/cast/encode 失败、QPN 超出 QPC 21-bit 投影或未知 field 时返回 0，并保留可定位原因。
  function automatic bit rewrite_qpc_source(
      input rdma_cmq_command_desc command,
      input string field,
      input int unsigned field_bit,
      output string failure_reason
  );
    rdma_status status;
    rdma_hw_model decoded_model;
    rdma_qpc_model qpc;
    rdma_hw_image encoded;
    int unsigned original_generation;

    failure_reason = "";
    if (command == null || command.qpc_signature_source == null ||
        !ensure_qpc_codec(failure_reason))
      return 1'b0;

    original_generation = command.qpc_signature_source.function_generation;
    decoded_model = null;
    status = qpc_codec.decode(
      command.qpc_signature_source, decoded_model
    );
    if (status == null || !status.ok() || decoded_model == null ||
        !$cast(qpc, decoded_model)) begin
      failure_reason = "typed QPC source decode failed";
      return 1'b0;
    end

    case (field)
      "qpn": begin
        if (field_bit >= 21) begin
          failure_reason = "QPC source QPN mutation exceeds 21-bit ABI";
          return 1'b0;
        end

        qpc.qp_h.object_id[field_bit] ^= 1'b1;
      end

      "signature": begin
        if (field_bit >= 8) begin
          failure_reason = "signature source PD-index bit exceeds eight bits";
          return 1'b0;
        end

        qpc.pd_h.object_id[field_bit] ^= 1'b1;
      end

      default: begin
        failure_reason = "unsupported typed QPC source field";
        return 1'b0;
      end
    endcase

    encoded = null;
    status = qpc_codec.encode(qpc, encoded);
    if (status == null || !status.ok() || encoded == null) begin
      failure_reason = "typed QPC source re-encode failed";
      return 1'b0;
    end

    // generation 是 image metadata，不在线上 512B QPC 中；decode 后的
    // projected handle 不携带它，因此重编码后恢复原冻结 generation。
    encoded.function_generation = original_generation;
    command.qpc_signature_source = encoded;
    return 1'b1;
  endfunction

  // 功能：mutate_qpc_request_inputs 按 ownership row 的语义字段复制图并翻转一个真实 composer 输入位。
  // 输入输出及副作用：row、baseline command/slot 输入；输出独立 mutant，不修改 baseline 的 body、source、handle 或 slot。
  // 失败边界：clone/cast 失败、字段坐标越界或非 ordinary typed 字段时返回 0；VALID/WRAP 和 fixed/static 行由专用路径处理。
  function automatic bit mutate_qpc_request_inputs(
      input rdma_cmq_field_evidence_row row,
      input rdma_cmq_command_desc baseline_command,
      input rdma_cmq_slot_context baseline_slot,
      output rdma_cmq_command_desc mutated_command,
      output rdma_cmq_slot_context mutated_slot,
      output string failure_reason
  );
    rdma_hw_qpc_command_body body;
    rdma_hw_qpc_command_body baseline_body;
    int unsigned field_bit;

    mutated_command = null;
    mutated_slot = null;
    failure_reason = "";

    if (row == null ||
        !clone_qpc_graph(baseline_command, baseline_slot,
                         mutated_command, mutated_slot) ||
        !$cast(body, mutated_command.body) ||
        !$cast(baseline_body, baseline_command.body)) begin
      failure_reason = "QPC mutation graph clone/cast failed";
      return 1'b0;
    end

    case (row.expected_field)
      "index": begin
        if (row.bit_index < 40 || row.bit_index > 44) begin
          failure_reason = "index driver coordinate is outside [44:40]";
          return 1'b0;
        end

        field_bit = row.bit_index - 40;
        mutated_slot.sq_index[field_bit] ^= 1'b1;
        mutated_slot.relative_offset = mutated_slot.sq_index * 64;
        mutated_slot.slot_sequence = mutated_slot.sq_index;
      end

      "qpn": begin
        if (row.bit_index > 23) begin
          failure_reason = "QPN driver coordinate exceeds 24 bits";
          return 1'b0;
        end

        body.qp_h.object_id[row.bit_index] ^= 1'b1;
        if (row.bit_index < 21 &&
            !rewrite_qpc_source(mutated_command, "qpn",
                                row.bit_index, failure_reason))
          return 1'b0;
      end

      "sq_cqn": begin
        if (row.bit_index < 43 || row.bit_index > 63) begin
          failure_reason = "SQ CQN driver coordinate is outside [63:43]";
          return 1'b0;
        end

        field_bit = row.bit_index - 43;
        body.send_cq_h.object_id[field_bit] ^= 1'b1;
      end

      "rq_cqn": begin
        if (row.bit_index > 20) begin
          failure_reason = "RQ CQN driver coordinate exceeds 21 bits";
          return 1'b0;
        end

        body.recv_cq_h.object_id[row.bit_index] ^= 1'b1;
      end

      "qpc_buffer_addr_pa": begin
        if (row.bit_index < 9 || row.bit_index > 63) begin
          failure_reason = "QPC buffer driver coordinate is outside [63:9]";
          return 1'b0;
        end

        // 驱动先把 PA 右移 9，再把 field-local bit j 写入 wire bit
        // (j + 9)。mutation TSV 保存的是 wire bit k，所以先还原
        // j=k-9，再用 j+9 写回 PA；这同时保留了低九位对齐约束。
        field_bit = row.bit_index - 9;
        body.qpc_buffer.value[field_bit + 9] ^= 1'b1;

        // 独立于 compose_sqe 的 source-level 断言：本分支只能翻转
        // C-derived wire coordinate 对应的 PA bit，不能因索引误用改动
        // 其它 bit 后再由最终 image delta 偶然掩盖。
        if ((body.qpc_buffer.value ^ baseline_body.qpc_buffer.value) !=
            (64'b1 << (field_bit + 9))) begin
          failure_reason = "QPC buffer field-local to wire mapping drift";
          return 1'b0;
        end
      end

      "signature": begin
        if (row.bit_index < 24 || row.bit_index > 31) begin
          failure_reason = "signature driver coordinate is outside [31:24]";
          return 1'b0;
        end

        field_bit = row.bit_index - 24;
        if (!rewrite_qpc_source(mutated_command, "signature",
                                field_bit, failure_reason))
          return 1'b0;
      end

      default: begin
        failure_reason = "unsupported ordinary QPC mutation field";
        return 1'b0;
      end
    endcase

    if (mutated_command == baseline_command ||
        mutated_slot == baseline_slot ||
        mutated_command.body == baseline_command.body ||
        mutated_command.qpc_signature_source ==
          baseline_command.qpc_signature_source) begin
      failure_reason = "QPC mutant aliases baseline graph";
      return 1'b0;
    end

    return 1'b1;
  endfunction

  // 功能：check_qpc_image_delta 验证一次 typed mutation 只改变 TSV 指定 wire 位，并独立核验派生 signature。
  // 输入输出及副作用：row、baseline/mutant image 与各自 source 均只读；仅产生断言，不修改图像。
  // 失败边界：对象为空、target 位 delta 非 1、额外非 signature 位变化或 signature 不符合驱动 XOR 算法时报告错误。
  task automatic check_qpc_image_delta(
      input rdma_cmq_field_evidence_row row,
      input rdma_hw_image baseline,
      input rdma_hw_image mutant,
      input rdma_hw_image baseline_source,
      input rdma_hw_image mutant_source
  );
    byte unsigned target_mask;
    byte unsigned delta;

    if (row == null || baseline == null || mutant == null ||
        baseline_source == null || mutant_source == null) begin
      `uvm_error("CMQ_QPC_DELTA", "QPC delta input is null")
      return;
    end

    target_mask = byte'(8'h1 << (row.bit_index % 8));
    foreach (baseline.bytes[i]) begin
      delta = baseline.bytes[i] ^ mutant.bytes[i];

      if (i == DRIVER_SIGNATURE_BYTE) begin
        if (i == row.byte_offset && delta != target_mask)
          `uvm_error("CMQ_QPC_TARGET_DELTA",
                     "signature source mutation changed wrong output bit")
      end
      else if (i == row.byte_offset) begin
        if (delta != target_mask)
          `uvm_error("CMQ_QPC_TARGET_DELTA",
                     "typed mutation changed wrong driver coordinate")
      end
      else if (delta != 0) begin
        `uvm_error("CMQ_QPC_EXTRA_DELTA",
                   $sformatf("unexpected non-signature byte delta at %0d", i))
      end
    end

    if (baseline.bytes[DRIVER_SIGNATURE_BYTE] !=
          expected_qpc_signature(baseline, baseline_source) ||
        mutant.bytes[DRIVER_SIGNATURE_BYTE] !=
          expected_qpc_signature(mutant, mutant_source))
      `uvm_error("CMQ_QPC_SIGNATURE",
                 "composer signature differs from driver XOR data flow")
  endtask

  // 功能：check_qpc_typed_row 对一条 ordinary HOST_TYPED row 构造两个独立图，调用两次 production compose_sqe 并比较 C 坐标。
  // 输入输出及副作用：row 只读；创建 baseline/mutant、输出 image 和不可变性快照，成功后更新 visited/typed 计数。
  // 失败边界：图构造、mutation、compose、canonical、metadata、expected response 或输入不可变性任一失败都会报告且不伪造证据。
  task automatic check_qpc_typed_row(
      input rdma_cmq_field_evidence_row row
  );
    rdma_cmq_command_desc baseline_command;
    rdma_cmq_slot_context baseline_slot;
    rdma_hw_image baseline_source;
    rdma_cmq_command_desc mutant_command;
    rdma_cmq_slot_context mutant_slot;
    rdma_cmq_command_desc baseline_snapshot;
    rdma_cmq_slot_context baseline_slot_snapshot;
    rdma_cmq_command_desc mutant_snapshot;
    rdma_cmq_slot_context mutant_slot_snapshot;
    rdma_hw_image baseline_sqe;
    rdma_hw_image mutant_sqe;
    rdma_cmq_expected_response baseline_expected;
    rdma_cmq_expected_response mutant_expected;
    rdma_status status;
    string failure_reason;

    if (row == null ||
        row.case_kind != RDMA_CMQ_CASE_QPC_REQUEST ||
        row.direction_kind != RDMA_CMQ_CONTRACT_REQUEST ||
        row.entry_kind != RDMA_CMQ_ENTRY_SQE ||
        row.evidence_kind != RDMA_CMQ_EVIDENCE_TYPED_RECOMPOSE ||
        row.opcode_value != RDMA_OP_QPC_CREATE ||
        !row.status_applicable || row.status_code_value != RDMA_SC_OK ||
        row.ready_value != 1 || !row.value_delta) begin
      `uvm_error("CMQ_QPC_TYPED_CONTRACT",
                 "ordinary QPC row has a non-typed contract")
      return;
    end

    if (!build_qpc_graph(baseline_command, baseline_slot,
                         baseline_source, failure_reason)) begin
      `uvm_error("CMQ_QPC_BASELINE_GRAPH", failure_reason)
      return;
    end

    if (!mutate_qpc_request_inputs(
          row, baseline_command, baseline_slot,
          mutant_command, mutant_slot, failure_reason)) begin
      `uvm_error("CMQ_QPC_MUTANT_GRAPH", failure_reason)
      return;
    end

    if (!clone_qpc_graph(baseline_command, baseline_slot,
                         baseline_snapshot, baseline_slot_snapshot) ||
        !clone_qpc_graph(mutant_command, mutant_slot,
                         mutant_snapshot, mutant_slot_snapshot)) begin
      `uvm_error("CMQ_QPC_SNAPSHOT", "QPC graph snapshot failed")
      return;
    end

    baseline_sqe = null;
    baseline_expected = null;
    status = profile.compose_sqe(
      baseline_command, baseline_slot, baseline_sqe, baseline_expected
    );
    if (status == null || !status.ok() || baseline_sqe == null ||
        baseline_expected == null) begin
      `uvm_error("CMQ_QPC_BASELINE_COMPOSE",
                 "production baseline composition failed")
      return;
    end

    mutant_sqe = null;
    mutant_expected = null;
    status = profile.compose_sqe(
      mutant_command, mutant_slot, mutant_sqe, mutant_expected
    );
    if (status == null || !status.ok() || mutant_sqe == null ||
        mutant_expected == null) begin
      `uvm_error("CMQ_QPC_MUTANT_COMPOSE",
                 "production mutant composition failed")
      return;
    end

    if (!images_equal(baseline_sqe, canonical_qpc_request))
      `uvm_error("CMQ_QPC_CANONICAL",
                 "field-local baseline differs from C canonical image")

    if (mutant_sqe.length != 64 || mutant_sqe.bytes.size() != 64 ||
        mutant_sqe.alignment != 64 ||
        mutant_sqe.endian != RDMA_ENDIAN_BIG ||
        mutant_sqe.image_kind != RDMA_IMAGE_CMQ_SQE ||
        mutant_sqe.hardware_version != RDMA_HW_VERSION ||
        mutant_sqe.function_generation != 7 ||
        mutant_sqe.write_target_kind != RDMA_HW_TARGET_BACKING ||
        mutant_sqe.backing_target.value !=
          SQ_BACKING_BASE + mutant_slot.relative_offset ||
        mutant_sqe.hmc_target.value != 0 ||
        mutant_sqe.bar_target.value != 0)
      `uvm_error("CMQ_QPC_MUTANT_METADATA",
                 "mutant SQE metadata/target differs from production contract")

    if (baseline_expected.hardware_opcode != RDMA_OP_QPC_CREATE ||
        baseline_expected.variant != "rc" ||
        mutant_expected.hardware_opcode != RDMA_OP_QPC_CREATE ||
        mutant_expected.variant != "rc")
      `uvm_error("CMQ_QPC_EXPECTED",
                 "composer expected-response identity is wrong")

    if (!qpc_graph_values_equal(
          baseline_command, baseline_slot,
          baseline_snapshot, baseline_slot_snapshot) ||
        !qpc_graph_values_equal(
          mutant_command, mutant_slot,
          mutant_snapshot, mutant_slot_snapshot))
      `uvm_error("CMQ_QPC_INPUT_MUTATION",
                 "compose_sqe mutated a caller-owned QPC graph")

    check_qpc_image_delta(
      row, baseline_sqe, mutant_sqe,
      baseline_command.qpc_signature_source,
      mutant_command.qpc_signature_source
    );

    visited_bits++;
    typed_recompose_count++;
  endtask

  // 功能：check_qpc_polarity_group 一次性执行 VALID/WRAP 两行相关证据，证明一个合法 slot wrap 迁移同时驱动两坐标。
  // 输入输出及副作用：case_id 选择 QPC request；创建两个独立 slot 状态并调用 production composer，原 rows 不修改。
  // 失败边界：相关组不是恰好 VALID+WRAP、任一 compose 失败、出现额外非 signature delta 或 signature XOR 错误时报告失败。
  task automatic check_qpc_polarity_group(
      input string case_id
  );
    rdma_cmq_field_evidence_row valid_row;
    rdma_cmq_field_evidence_row wrap_row;
    rdma_cmq_command_desc baseline_command;
    rdma_cmq_slot_context baseline_slot;
    rdma_hw_image baseline_source;
    rdma_cmq_command_desc wrapped_command;
    rdma_cmq_slot_context wrapped_slot;
    rdma_hw_image baseline_sqe;
    rdma_hw_image wrapped_sqe;
    rdma_cmq_expected_response expected;
    rdma_status status;
    string failure_reason;
    byte unsigned delta;

    valid_row = null;
    wrap_row = null;
    foreach (rows[i]) begin
      if (rows[i].case_id == case_id &&
          rows[i].correlation_group == "QPC_POLARITY_VALID_WRAP") begin
        if (rows[i].expected_field == "valid")
          valid_row = rows[i];
        else if (rows[i].expected_field == "wrap")
          wrap_row = rows[i];
      end
    end

    if (valid_row == null || wrap_row == null ||
        valid_row.evidence_kind !=
          RDMA_CMQ_EVIDENCE_CORRELATED_RECOMPOSE ||
        wrap_row.evidence_kind !=
          RDMA_CMQ_EVIDENCE_CORRELATED_RECOMPOSE) begin
      `uvm_error("CMQ_QPC_POLARITY_CONTRACT",
                 "QPC polarity group is not exactly VALID/WRAP")
      return;
    end

    if (!build_qpc_graph(baseline_command, baseline_slot,
                         baseline_source, failure_reason) ||
        !clone_qpc_graph(baseline_command, baseline_slot,
                         wrapped_command, wrapped_slot)) begin
      `uvm_error("CMQ_QPC_POLARITY_GRAPH", failure_reason)
      return;
    end

    wrapped_slot.slot_sequence = CANONICAL_INDEX + 32;
    wrapped_slot.sq_wrap = 1'b1;

    status = profile.compose_sqe(
      baseline_command, baseline_slot, baseline_sqe, expected
    );
    if (status == null || !status.ok() || baseline_sqe == null) begin
      `uvm_error("CMQ_QPC_POLARITY_BASELINE",
                 "baseline polarity composition failed")
      return;
    end

    status = profile.compose_sqe(
      wrapped_command, wrapped_slot, wrapped_sqe, expected
    );
    if (status == null || !status.ok() || wrapped_sqe == null) begin
      `uvm_error("CMQ_QPC_POLARITY_MUTANT",
                 "wrapped polarity composition failed")
      return;
    end

    foreach (baseline_sqe.bytes[i]) begin
      delta = baseline_sqe.bytes[i] ^ wrapped_sqe.bytes[i];

      if (i == valid_row.byte_offset) begin
        if (delta != byte'(8'h1 << (valid_row.bit_index % 8)))
          `uvm_error("CMQ_QPC_VALID_DELTA", "VALID delta is not exact")
      end
      else if (i == wrap_row.byte_offset) begin
        if (delta != byte'(8'h1 << (wrap_row.bit_index % 8)))
          `uvm_error("CMQ_QPC_WRAP_DELTA", "WRAP delta is not exact")
      end
      else if (i != DRIVER_SIGNATURE_BYTE && delta != 0) begin
        `uvm_error("CMQ_QPC_POLARITY_EXTRA",
                   "polarity transition changed an unrelated wire byte")
      end
    end

    if (baseline_sqe.bytes[DRIVER_SIGNATURE_BYTE] !=
          expected_qpc_signature(
            baseline_sqe, baseline_command.qpc_signature_source) ||
        wrapped_sqe.bytes[DRIVER_SIGNATURE_BYTE] !=
          expected_qpc_signature(
            wrapped_sqe, wrapped_command.qpc_signature_source))
      `uvm_error("CMQ_QPC_POLARITY_SIGNATURE",
                 "polarity signature delta does not follow driver XOR")

    visited_bits += 2;
    correlated_recompose_count += 2;
  endtask

  // 功能：check_qpc_driver_fixed_rejection 对一条 VFID fixed-zero row 构造合法图，并让 production profile 命中 opcode 专用拒绝。
  // 输入输出及副作用：row 只读；调用 zero baseline 与 nonzero mutant compose，成功后更新 visited/fixed 计数。
  // 失败边界：字段不是 override/use_vfid、baseline 不匹配 C、拒绝码非 INVALID_ARGUMENT、发布输出或改变输入图时报告错误。
  task automatic check_qpc_driver_fixed_rejection(
      input rdma_cmq_field_evidence_row row
  );
    rdma_cmq_command_desc command;
    rdma_cmq_slot_context slot;
    rdma_hw_image source;
    rdma_cmq_command_desc snapshot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_hw_image sqe;
    rdma_cmq_expected_response expected;
    rdma_status status;
    string failure_reason;
    int unsigned field_bit;

    if (row == null ||
        row.evidence_kind != RDMA_CMQ_EVIDENCE_DRIVER_FIXED_REJECT ||
        !row.status_applicable ||
        row.status_code_value != RDMA_SC_INVALID_ARGUMENT ||
        row.ready_value != 0 || !row.value_delta) begin
      `uvm_error("CMQ_QPC_FIXED_CONTRACT",
                 "driver-fixed row contract is invalid")
      return;
    end

    if (!build_qpc_graph(command, slot, source, failure_reason)) begin
      `uvm_error("CMQ_QPC_FIXED_GRAPH", failure_reason)
      return;
    end

    status = profile.compose_sqe(command, slot, sqe, expected);
    if (status == null || !status.ok() ||
        !images_equal(sqe, canonical_qpc_request)) begin
      `uvm_error("CMQ_QPC_FIXED_BASELINE",
                 "zero-VFID graph does not reproduce C canonical SQE")
      return;
    end

    if (row.expected_field == "vf_id_override") begin
      command.vfid_override = 1'b1;
    end
    else if (row.expected_field == "use_vfid") begin
      if (row.bit_index < 48 || row.bit_index > 58) begin
        `uvm_error("CMQ_QPC_FIXED_COORDINATE",
                   "USE_VFID coordinate is outside [58:48]")
        return;
      end

      field_bit = row.bit_index - 48;
      command.vfid_override = 1'b1;
      command.use_vfid[field_bit] = 1'b1;
    end
    else begin
      `uvm_error("CMQ_QPC_FIXED_FIELD",
                 "unknown driver-fixed QPC field")
      return;
    end

    if (!clone_qpc_graph(command, slot, snapshot, slot_snapshot)) begin
      `uvm_error("CMQ_QPC_FIXED_SNAPSHOT",
                 "fixed rejection snapshot failed")
      return;
    end

    sqe = rdma_hw_image::type_id::create("fixed_reject_sentinel_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "fixed_reject_sentinel_expected"
    );
    status = profile.compose_sqe(command, slot, sqe, expected);
    if (status == null || status.code != row.status_code_value)
      `uvm_error("CMQ_QPC_FIXED_STATUS",
                 "nonzero driver-fixed VFID returned wrong status")

    if (sqe != null || expected != null)
      `uvm_error("CMQ_QPC_FIXED_PUBLICATION",
                 "driver-fixed rejection published SQE/expected output")

    if (!qpc_graph_values_equal(
          command, slot, snapshot, slot_snapshot))
      `uvm_error("CMQ_QPC_FIXED_INPUT",
                 "driver-fixed rejection changed its input graph")

    visited_bits++;
    driver_fixed_reject_count++;
  endtask

  // 功能：check_request_static_row 证明 QPC static coordinate 等于 C/production canonical，且不把 raw request 注入 typed composer。
  // 输入输出及副作用：row、canonical_request 只读；读取预先由 production compose 得到的 canonical image，更新对应 static 计数。
  // 失败边界：类别错误、对象缺失、canonical bit 不一致，或 unwritable 位非零时报告错误；不宣称运行时拒绝。
  task automatic check_request_static_row(
      input rdma_cmq_field_evidence_row row,
      input rdma_hw_image canonical_request
  );
    byte unsigned bit_mask;
    bit c_value;
    bit production_value;

    if (row == null || canonical_request == null ||
        production_qpc_request == null ||
        row.status_applicable || row.ready_value != -1 ||
        row.value_delta) begin
      `uvm_error("CMQ_QPC_STATIC_CONTRACT",
                 "static QPC row carries runtime result data")
      return;
    end

    bit_mask = byte'(8'h1 << (row.bit_index % 8));
    c_value = (canonical_request.bytes[row.byte_offset] & bit_mask) != 0;
    production_value =
      (production_qpc_request.bytes[row.byte_offset] & bit_mask) != 0;

    if (c_value != production_value)
      `uvm_error("CMQ_QPC_STATIC_CANONICAL",
                 "C and production canonical bits differ")

    case (row.evidence_kind)
      RDMA_CMQ_EVIDENCE_STATIC_CANONICAL: begin
        if (!(row.expected_field == "opcode" ||
              row.expected_field == "sign_en"))
          `uvm_error("CMQ_QPC_STATIC_FIELD",
                     "canonical-static row is not opcode/SIGN_EN")

        static_canonical_count++;
      end

      RDMA_CMQ_EVIDENCE_STATIC_UNWRITABLE: begin
        if (row.expected_field != "-" || c_value || production_value)
          `uvm_error("CMQ_QPC_UNWRITABLE",
                     "unwritable request coordinate is not canonical zero")

        static_unwritable_count++;
      end

      default:
        `uvm_error("CMQ_QPC_STATIC_MODE", "unknown static evidence mode")
    endcase

    visited_bits++;
  endtask

  // 功能：check_request_case 执行 QPC_CREATE 的 512 行 request 合同，并把每行分派到 typed、correlated、fixed 或 static 证明。
  // 输入输出及副作用：case_id、opcode 选择冻结 case；构建一次 production canonical 并更新全部 request 证据计数。
  // 失败边界：case/opcode 身份错误、canonical compose 不匹配、行数漂移或未知 evidence 时报告错误且不启用能力。
  task automatic check_request_case(
      input string case_id,
      input bit [7:0] opcode
  );
    rdma_cmq_command_desc command;
    rdma_cmq_slot_context slot;
    rdma_hw_image source;
    rdma_cmq_expected_response expected;
    rdma_status status;
    string failure_reason;
    int unsigned row_count;

    if (case_id != "cmq_sqe_qpc_create_request" ||
        opcode != RDMA_OP_QPC_CREATE) begin
      `uvm_error("CMQ_REQUEST_IDENTITY",
                 "request gate selected an unknown case/opcode")
      return;
    end

    if (!build_qpc_graph(command, slot, source, failure_reason)) begin
      `uvm_error("CMQ_REQUEST_GRAPH", failure_reason)
      return;
    end

    status = profile.compose_sqe(
      command, slot, production_qpc_request, expected
    );
    if (status == null || !status.ok() ||
        production_qpc_request == null || expected == null ||
        !images_equal(production_qpc_request, canonical_qpc_request)) begin
      `uvm_error("CMQ_REQUEST_CANONICAL",
                 "production QPC_CREATE does not match the C oracle")
      return;
    end

    row_count = 0;
    foreach (rows[i]) begin
      if (rows[i].case_kind != RDMA_CMQ_CASE_QPC_REQUEST)
        continue;

      row_count++;
      case (rows[i].evidence_kind)
        RDMA_CMQ_EVIDENCE_TYPED_RECOMPOSE:
          check_qpc_typed_row(rows[i]);

        RDMA_CMQ_EVIDENCE_CORRELATED_RECOMPOSE: ;

        RDMA_CMQ_EVIDENCE_DRIVER_FIXED_REJECT:
          check_qpc_driver_fixed_rejection(rows[i]);

        RDMA_CMQ_EVIDENCE_STATIC_CANONICAL,
        RDMA_CMQ_EVIDENCE_STATIC_UNWRITABLE:
          check_request_static_row(rows[i], canonical_qpc_request);

        default:
          `uvm_error("CMQ_REQUEST_EVIDENCE",
                     "QPC request contains response evidence")
      endcase
    end

    check_qpc_polarity_group(case_id);
    if (row_count != 512)
      `uvm_error("CMQ_REQUEST_COUNT", "QPC request count is not 512")
  endtask

  // 功能：status_matches_row 比较 production API 返回的状态与 reader 类型化的 expected_status_code。
  // 输入输出及副作用：status、row 只读；返回精确 code 匹配结果，不按 message 文本放宽错误类别。
  // 失败边界：row 未声明运行时状态或 status 为空时返回 0；static 行不得调用本函数宣称执行结果。
  function automatic bit status_matches_row(
      input rdma_status status,
      input rdma_cmq_field_evidence_row row
  );
    return row != null && row.status_applicable && status != null &&
           status.code == row.status_code_value;
  endfunction

  // 功能：check_completion_typed_value 核对 accepted raw CQE 中 owner/index/wrap/opcode/ecode 的类型化值来自 mutation 后字节。
  // 输入输出及副作用：row、mutant、completion 只读；仅报告字段投影偏差，不修改 completion payload。
  // 失败边界：非 HW_TYPED 字段、对象为空或 decoder 输出与 raw qword0 不一致时报告错误。
  task automatic check_completion_typed_value(
      input rdma_cmq_field_evidence_row row,
      input rdma_hw_image mutant,
      input rdma_hw_cmq_completion completion
  );
    bit [63:0] qword0;

    if (row == null || mutant == null || completion == null) begin
      `uvm_error("CMQ_CQE_TYPED_VALUE", "accepted typed CQE is null")
      return;
    end

    qword0 = profile_fixture.get_qword(mutant, 0);
    case (row.expected_field)
      "index":
        if (completion.wqe_index != qword0[44:40])
          `uvm_error("CMQ_CQE_INDEX", "decoded CQE index delta is wrong")

      "wrap":
        if (completion.wrap != qword0[45])
          `uvm_error("CMQ_CQE_WRAP", "decoded CQE wrap delta is wrong")

      "opcode":
        if (completion.opcode != qword0[39:32])
          `uvm_error("CMQ_CQE_OPCODE", "decoded CQE opcode delta is wrong")

      "ecode":
        if (completion.command_ecode != qword0[31:24])
          `uvm_error("CMQ_CQE_ECODE", "decoded CQE ecode delta is wrong")

      default:
        `uvm_error("CMQ_CQE_TYPED_FIELD",
                   "accepted completion row has no typed output field")
    endcase
  endtask

  // 功能：check_completion_row 翻转一个 C CQE memory bit，分别执行 raw completion codec 与 production profile，并核对两层结果。
  // 输入输出及副作用：row、canonical 只读；创建 mutant，成功后更新 visited/raw 计数，不修改 canonical。
  // 失败边界：raw delta 非单 bit、状态/ready/publication 不符，或 ecode 未映射为非 OK command_status 时报告错误。
  task automatic check_completion_row(
      input rdma_cmq_field_evidence_row row,
      input rdma_hw_image canonical
  );
    rdma_hw_image mutant;
    rdma_hw_cmq_completion_codec completion_codec;
    rdma_hw_cmq_completion completion;
    rdma_cmq_decoded_cqe decoded;
    rdma_status raw_status;
    rdma_status profile_status;
    bit raw_ready;
    bit profile_ready;
    byte unsigned bit_mask;
    bit [63:0] qword0;

    if (row == null || canonical == null ||
        row.case_kind != RDMA_CMQ_CASE_QPC_RESPONSE ||
        row.direction_kind != RDMA_CMQ_CONTRACT_RESPONSE ||
        row.entry_kind != RDMA_CMQ_ENTRY_CQE ||
        row.evidence_kind != RDMA_CMQ_EVIDENCE_RAW_DECODE_MUTATION ||
        row.opcode_value != RDMA_OP_QPC_CREATE || !row.value_delta) begin
      `uvm_error("CMQ_CQE_CONTRACT", "response row contract is invalid")
      return;
    end

    mutant = clone_image(canonical);
    if (mutant == null || mutant == canonical) begin
      `uvm_error("CMQ_CQE_CLONE", "canonical CQE clone failed/aliased")
      return;
    end

    bit_mask = byte'(8'h1 << (row.bit_index % 8));
    mutant.bytes[row.byte_offset] ^= bit_mask;
    foreach (canonical.bytes[i]) begin
      if ((canonical.bytes[i] ^ mutant.bytes[i]) !=
          ((i == row.byte_offset) ? bit_mask : 0))
        `uvm_error("CMQ_CQE_RAW_DELTA",
                   "raw CQE mutation is not exactly one recorded bit")
    end

    completion_codec =
      rdma_hw_cmq_completion_codec::type_id::create("mutation_cqe_codec");
    raw_ready = 1'b0;
    completion = null;
    raw_status = completion_codec.inspect_completion(
      mutant, 1'b1, raw_ready, completion
    );

    if (!status_matches_row(raw_status, row) ||
        raw_ready != bit'(row.ready_value))
      `uvm_error("CMQ_CQE_RAW_RESULT",
                 "raw completion status/ready differs from manifest")

    if (!raw_ready && completion != null)
      `uvm_error("CMQ_CQE_RAW_PUBLICATION",
                 "not-ready/rejected raw CQE published completion")

    if (raw_ready)
      check_completion_typed_value(row, mutant, completion);

    profile_ready = 1'b0;
    decoded = null;
    profile_status = profile.inspect_cqe(
      mutant, 1'b1, profile_ready, decoded
    );
    if (!status_matches_row(profile_status, row) ||
        profile_ready != bit'(row.ready_value))
      `uvm_error("CMQ_CQE_PROFILE_RESULT",
                 "profile CQE status/ready differs from manifest")

    if (!profile_ready && decoded != null)
      `uvm_error("CMQ_CQE_PROFILE_PUBLICATION",
                 "not-ready/rejected profile CQE published decoded result")

    qword0 = profile_fixture.get_qword(mutant, 0);
    if (profile_ready) begin
      if (decoded == null || decoded.hardware_opcode != qword0[39:32] ||
          decoded.wqe_index != qword0[44:40] ||
          decoded.wqe_wrap != qword0[45] ||
          decoded.hardware_ecode != qword0[31:24])
        `uvm_error("CMQ_CQE_PROFILE_FIELDS",
                   "profile CQE typed fields differ from raw mutation")

      if (row.expected_field == "ecode" &&
          (decoded == null || decoded.command_status == null ||
           decoded.command_status.ok() ||
           !decoded.command_status.hardware_code_valid ||
           decoded.command_status.hardware_code[7:0] != qword0[31:24]))
        `uvm_error("CMQ_CQE_ECODE_MAPPING",
                   "raw ecode was not retained and published as command error")
    end

    visited_bits++;
    raw_decode_mutation_count++;
  endtask

  // 功能：check_completion_case 执行 QPC_CREATE response 的全部 512 个 raw bit mutation，并保持 driver result 与 model result 分层。
  // 输入输出及副作用：case_id、opcode 选择冻结 CQE case；只读 canonical artifact，逐行调用真实 decoder。
  // 失败边界：case/opcode 不符、canonical 基线未被接受、行数漂移或任一 row 结果偏差时报告错误。
  task automatic check_completion_case(
      input string case_id,
      input bit [7:0] opcode
  );
    rdma_hw_image canonical;
    rdma_hw_cmq_completion_codec completion_codec;
    rdma_hw_cmq_completion completion;
    rdma_status status;
    bit ready;
    int unsigned count;

    if (case_id != "cmq_cqe_qpc_create_response" ||
        opcode != RDMA_OP_QPC_CREATE) begin
      `uvm_error("CMQ_RESPONSE_IDENTITY",
                 "response gate selected an unknown case/opcode")
      return;
    end

    canonical = load_canonical_image(
      "../hw/rdma/c_oracle/cases/cmq_cqe_qpc_create_response.bytes.hex",
      RDMA_IMAGE_CMQ_CQE,
      64
    );
    if (canonical == null) begin
      `uvm_error("CMQ_RESPONSE_CANONICAL",
                 "failed to load canonical QPC CQE")
      return;
    end

    completion_codec =
      rdma_hw_cmq_completion_codec::type_id::create("canonical_cqe_codec");
    status = completion_codec.inspect_completion(
      canonical, 1'b1, ready, completion
    );
    if (status == null || !status.ok() || !ready || completion == null)
      `uvm_error("CMQ_RESPONSE_BASELINE",
                 "driver canonical CQE is not accepted by raw codec")

    count = 0;
    foreach (rows[i]) begin
      if (rows[i].case_kind == RDMA_CMQ_CASE_QPC_RESPONSE) begin
        count++;
        check_completion_row(rows[i], canonical);
      end
    end

    if (count != 512)
      `uvm_error("CMQ_RESPONSE_COUNT", "QPC response count is not 512")
  endtask

  // 功能：check_doorbell_request_case 用 production encode_doorbell 闭合五个 PI 位、一个 polarity 位及 58 个不可写位。
  // 输入输出及副作用：case_id 选择冻结 doorbell case；创建 CMQ handle 和 detached image，更新 typed/static/visited 计数。
  // 失败边界：canonical `(0x17,1)` 不匹配 C、typed delta 非单 bit、static 位非零或 encoder 状态/元数据错误时报告失败。
  task automatic check_doorbell_request_case(
      input string case_id
  );
    rdma_hw_image canonical;
    rdma_hw_image encoded;
    rdma_hw_image mutant;
    rdma_handle cmq_h;
    rdma_status status;
    byte unsigned bit_mask;
    byte unsigned delta;
    byte unsigned reachable_or[8];
    int unsigned mutant_pi;
    int unsigned count;

    if (case_id != "cmq_sq_doorbell") begin
      `uvm_error("CMQ_DOORBELL_IDENTITY", "unknown doorbell case")
      return;
    end

    canonical = load_canonical_image(
      "../hw/rdma/c_oracle/cases/cmq_sq_doorbell.bytes.hex",
      RDMA_IMAGE_DOORBELL,
      8
    );
    cmq_h = profile_fixture.make_handle(
      "mutation_doorbell_cmq", RDMA_RESOURCE_CMQ, 32'h44
    );
    status = profile.encode_doorbell(cmq_h, 5'h17, 1'b1, encoded);
    if (canonical == null || status == null || !status.ok() ||
        !images_equal(encoded, canonical)) begin
      `uvm_error("CMQ_DOORBELL_CANONICAL",
                 "production doorbell differs from C canonical image")
      return;
    end

    // CMQ SQ doorbell 的全部语义输入域只有 5-bit PI 与 1-bit polarity。
    // 枚举 64 个可达输入并对 production encoder 输出求 OR，可证明 static
    // 位在任何可达请求中都不可写，而不是只观察一次 canonical 图像。
    foreach (reachable_or[i])
      reachable_or[i] = 0;

    for (int unsigned pi = 0; pi < 32; pi++) begin
      for (int unsigned polarity = 0; polarity < 2; polarity++) begin
        mutant = null;
        status = profile.encode_doorbell(
          cmq_h, pi, bit'(polarity), mutant
        );
        if (status == null || !status.ok() || mutant == null) begin
          `uvm_error("CMQ_DOORBELL_DOMAIN",
                     "production encoder rejected a reachable input")
          continue;
        end

        foreach (reachable_or[byte_index])
          reachable_or[byte_index] |= mutant.bytes[byte_index];
      end
    end

    count = 0;
    foreach (rows[i]) begin
      if (rows[i].case_kind != RDMA_CMQ_CASE_SQ_DOORBELL)
        continue;

      count++;
      bit_mask = byte'(8'h1 << (rows[i].bit_index % 8));
      case (rows[i].evidence_kind)
        RDMA_CMQ_EVIDENCE_TYPED_RECOMPOSE: begin
          mutant = null;
          if (rows[i].expected_field == "pi") begin
            mutant_pi = 5'h17 ^
                        (1 << (rows[i].bit_index - 32));
            status = profile.encode_doorbell(
              cmq_h, mutant_pi, 1'b1, mutant
            );
          end
          else if (rows[i].expected_field == "polarity") begin
            status = profile.encode_doorbell(
              cmq_h, 5'h17, 1'b0, mutant
            );
          end
          else begin
            `uvm_error("CMQ_DOORBELL_TYPED_FIELD",
                       "typed doorbell row is not PI/polarity")
            continue;
          end

          if (!rows[i].status_applicable ||
              rows[i].status_code_value != RDMA_SC_OK ||
              rows[i].ready_value != 1 || !rows[i].value_delta ||
              status == null || !status.ok() || mutant == null)
            `uvm_error("CMQ_DOORBELL_TYPED_RESULT",
                       "doorbell encoder rejected a reachable state")

          foreach (encoded.bytes[byte_index]) begin
            delta = encoded.bytes[byte_index] ^ mutant.bytes[byte_index];
            if (delta !=
                ((byte_index == rows[i].byte_offset) ? bit_mask : 0))
              `uvm_error("CMQ_DOORBELL_DELTA",
                         "doorbell typed mutation is not one recorded bit")
          end

          typed_recompose_count++;
        end

        RDMA_CMQ_EVIDENCE_STATIC_UNWRITABLE: begin
          if (rows[i].status_applicable || rows[i].ready_value != -1 ||
              rows[i].value_delta ||
              (canonical.bytes[rows[i].byte_offset] & bit_mask) != 0 ||
              (encoded.bytes[rows[i].byte_offset] & bit_mask) != 0 ||
              (reachable_or[rows[i].byte_offset] & bit_mask) != 0)
            `uvm_error("CMQ_DOORBELL_UNWRITABLE",
                       "static doorbell coordinate is not canonical zero")

          static_unwritable_count++;
        end

        default:
          `uvm_error("CMQ_DOORBELL_EVIDENCE",
                     "doorbell row uses an invalid evidence mode")
      endcase

      visited_bits++;
    end

    if (count != 64)
      `uvm_error("CMQ_DOORBELL_COUNT", "doorbell count is not 64")
  endtask

  // 功能：check_cqc_embed_blocker 读取 CQC C-oracle field 与 capability 行，确认 payload target base=8 且 request 仍显式阻塞。
  // 输入输出及副作用：无参数；只读两个 TSV，并检查当前 mutation rows 中没有 CQC case，不执行或平移错误 composer。
  // 失败边界：文件缺失、字段/能力行不唯一、request_encodable 非零、blocker 改名或出现 CQC mutation 时报告错误。
  task automatic check_cqc_embed_blocker();
    int fields_fd;
    int capabilities_fd;
    int matched;
    int payload_target_matches;
    int capability_matches;
    string line;
    string field_name;
    string byte_offset;
    string lsb;
    string width;
    string field_value;
    string driver_symbol;
    string opcode;
    string opcode_value;
    string direction;
    string registered;
    string request_encodable;
    string response_decodable;
    string oracle_case_id;
    string owning_codec;
    string blocker;

    payload_target_matches = 0;
    fields_fd = $fopen(
      "../hw/rdma/c_oracle/cases/cmq_sqe_cqc_create_request.fields.tsv",
      "r"
    );
    if (fields_fd == 0) begin
      `uvm_error("CMQ_CQC_FIELDS", "cannot open CQC oracle fields")
      return;
    end

    while (!$feof(fields_fd)) begin
      matched = $fscanf(
        fields_fd, "%s\t%s\t%s\t%s\t%s\n",
        field_name, byte_offset, lsb, width, field_value
      );
      if (matched == 5 && field_name == "payload_target_byte" &&
          field_value == "8")
        payload_target_matches++;
    end
    $fclose(fields_fd);

    capability_matches = 0;
    capabilities_fd = $fopen("../hw/rdma/cmq_capabilities.tsv", "r");
    if (capabilities_fd == 0) begin
      `uvm_error("CMQ_CQC_CAPABILITY", "cannot open CMQ capabilities")
      return;
    end

    void'($fgets(line, capabilities_fd));
    while (!$feof(capabilities_fd)) begin
      matched = $fscanf(
        capabilities_fd,
        "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        driver_symbol, opcode, opcode_value, direction, registered,
        request_encodable, response_decodable, oracle_case_id,
        owning_codec, blocker
      );
      if (matched == 10 && opcode == "CQC_CREATE" &&
          direction == "REQUEST") begin
        capability_matches++;
        if (request_encodable != "0" ||
            blocker != "CONTEXT_EMBED_BASE_MISMATCH")
          `uvm_error("CMQ_CQC_BLOCKER",
                     "CQC_CREATE request blocker was incorrectly enabled")
      end
    end
    $fclose(capabilities_fd);

    foreach (rows[i]) begin
      if (rows[i].opcode == "CQC_CREATE")
        `uvm_error("CMQ_CQC_MUTATION",
                   "unsupported CQC_CREATE has a mutation row")
    end

    if (payload_target_matches != 1 || capability_matches != 1)
      `uvm_error("CMQ_CQC_BLOCKER_COUNT",
                 "CQC embed base/capability proof is not unique")
  endtask

  // 功能：check_final_counts 断言 gate 实际执行/静态消费的六类计数与冻结 1,088 行完全闭合。
  // 输入输出及副作用：读取本测试计数；产生一条稳定 summary 信息，不修改 rows 或 capability 文件。
  // 失败边界：任一类别、executed/static subtotal 或 grand total 漂移时报告错误，禁止仅用总行数掩盖漏执行。
  task automatic check_final_counts();
    int unsigned executed_total;
    int unsigned static_total;

    executed_total = typed_recompose_count +
                     correlated_recompose_count +
                     driver_fixed_reject_count +
                     raw_decode_mutation_count;
    static_total = static_canonical_count + static_unwritable_count;

    if (typed_recompose_count != 140 ||
        correlated_recompose_count != 2 ||
        driver_fixed_reject_count != 12 ||
        raw_decode_mutation_count != 512 ||
        static_canonical_count != 9 ||
        static_unwritable_count != 413 ||
        executed_total != 666 || static_total != 422 ||
        visited_bits != 1088)
      `uvm_error("CMQ_EVIDENCE_COUNTS",
                 "executed/static mutation evidence count drifted")

    `uvm_info(
      "CMQ_EVIDENCE_SUMMARY",
      $sformatf(
        {"TYPED_RECOMPOSE=%0d CORRELATED_RECOMPOSE=%0d ",
         "DRIVER_FIXED_REJECT=%0d RAW_DECODE_MUTATION=%0d ",
         "STATIC_CANONICAL=%0d STATIC_UNWRITABLE=%0d ",
         "EXECUTED_TOTAL=%0d STATIC_TOTAL=%0d GRAND_TOTAL=%0d"},
        typed_recompose_count, correlated_recompose_count,
        driver_fixed_reject_count, raw_decode_mutation_count,
        static_canonical_count, static_unwritable_count,
        executed_total, static_total, visited_bits
      ),
      UVM_LOW
    )
  endtask

  // 功能：run_phase 严格加载 mutation/oracle，依次执行 request、response、doorbell 与 CQC blocker，最后闭合分类计数。
  // 输入输出及副作用：phase 由 UVM 提供；持有 objection 期间只做本地文件读取和纯 codec/profile 调用，结束时释放 objection。
  // 失败边界：manifest 或 canonical request 无法读取时立即 fatal；其余偏差累计为 UVM_ERROR，绝不把缺失证据计为通过。
  virtual task run_phase(uvm_phase phase);
    string error;

    phase.raise_objection(this);

    if (!rdma_cmq_contract_reader::read_all(
          "../hw/rdma/cmq_field_mutation.tsv", rows, error))
      `uvm_fatal("CMQ_MANIFEST", error)

    canonical_qpc_request = load_canonical_image(
      "../hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.bytes.hex",
      RDMA_IMAGE_CMQ_SQE,
      64
    );
    if (canonical_qpc_request == null)
      `uvm_fatal("CMQ_QPC_CANONICAL",
                 "failed to load canonical QPC SQE")

    check_request_case(
      "cmq_sqe_qpc_create_request", RDMA_OP_QPC_CREATE
    );
    check_completion_case(
      "cmq_cqe_qpc_create_response", RDMA_OP_QPC_CREATE
    );
    check_doorbell_request_case("cmq_sq_doorbell");
    check_cqc_embed_blocker();
    check_final_counts();

    phase.drop_objection(this);
  endtask
endclass
