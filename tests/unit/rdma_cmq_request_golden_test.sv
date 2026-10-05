// 目录：测试层 tests/unit/rdma_cmq_request_golden_test.sv。
// 职责：驱动全部 70 个 CMQ opcode 的逐字节验收（表驱动 49 个 + 专用编码器 21 个）：
//   按 golden（tools/cmq_request_oracle.py 用驱动原文填充函数生成）的输入构造 field body，
//   经生产 profile compose_sqe 后与驱动 SQE 比对；并检查字段拒绝路径与这些 opcode 的公共 CQE 解码。
// 依赖：rdma_cmq_engine_test 的 binding/CMQ 构造、rdma_golden_reader、rdma_hw_cmq_hw_profile。
// 所有权与生命周期：测试只拥有本地 profile/binding/body；golden 文件只读。
// 设计说明：驱动对 CEQC/AEQC/SRFQC_MODIFY、SD_QUERY、QPC/CQC_FORCE_DELETE、NOP 不调用填充函数，
//   提交的是全零 WQE；模型对这些 opcode 发出仅含信封的 SQE（opcode/index/wrap/valid），body 全零。

class rdma_cmq_request_golden_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_request_golden_test)

  rdma_hw_cmq_hw_profile profile;
  rdma_function_binding binding;
  rdma_cmq cmq;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传。
  // 失败/边界：无。
  function new(string name = "rdma_cmq_request_golden_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：把 golden 输入串解析为 opcode/index/polarity 与 body 成员（数组成员按字段表识别）。
  // 输入/输出及副作用：body 输出新对象。
  // 失败/边界：格式不符时报告 UVM_ERROR 并返回 0。
  function automatic bit parse_inputs(string label, string inputs, output bit [7:0] opcode,
                                      output int unsigned index, output bit polarity,
                                      output rdma_hw_cmq_field_body body);
    rdma_cmq_field_spec_t specs[$];
    bit blob[string];
    string token;
    string key;
    string value;
    int start;
    longint unsigned scalar;

    body = rdma_hw_cmq_field_body::type_id::create({label, "_body"});
    opcode = 0;
    index = 0;
    polarity = 0;
    start = 0;
    for (int i = 0; i <= inputs.len(); i++) begin
      if (i < inputs.len() && inputs.getc(i) != ",")
        continue;
      token = inputs.substr(start, i - 1);
      start = i + 1;
      key = "";
      for (int j = 0; j < token.len(); j++)
        if (token.getc(j) == "=") begin
          key = token.substr(0, j - 1);
          value = token.substr(j + 3, token.len() - 1);
          break;
        end
      if (key == "") begin
        `uvm_error(label, {"malformed golden input token ", token})
        return 0;
      end
      if (key == "opcode") begin
        void'($sscanf(value, "%h", opcode));
        void'(rdma_cmq_request_field_specs(opcode, specs));
        foreach (specs[s])
          if (specs[s].transform == "mac48" || specs[s].transform.substr(0, 5) == "bytes:")
            blob[specs[s].param] = 1'b1;
        blob["sd_extra_data"] = 1'b1;
      end
      else if (key == "index")
        void'($sscanf(value, "%h", index));
      else if (key == "polarity")
        void'($sscanf(value, "%h", polarity));
      else if (blob.exists(key)) begin
        body.blobs[key] = new[value.len() / 2];
        foreach (body.blobs[key][b])
          void'($sscanf(value.substr(2 * b, 2 * b + 1), "%h", body.blobs[key][b]));
      end
      else begin
        void'($sscanf(value, "%h", scalar));
        body.values[key] = scalar;
      end
    end
    return 1;
  endfunction

  // 功能：经生产 profile 组装一条 SQE（slot 由 index 与 wrap = !polarity 决定）。
  // 输入/输出及副作用：sqe 输出。
  // 失败/边界：返回 compose_sqe 的 status。
  function automatic rdma_status compose(string label, bit [7:0] opcode, int unsigned index,
                                         bit polarity, rdma_hw_model body,
                                         output rdma_hw_image sqe);
    rdma_cmq_command_desc command;
    rdma_cmq_slot_context slot;
    rdma_cmq_expected_response expected;

    command = rdma_make_cmq_command(binding.make_handle(), opcode, "field", body, 1us, label);
    slot = rdma_cmq_slot_context::type_id::create({label, "_slot"});
    slot.function_h = binding.make_handle();
    slot.cmq_h = cmq.handle;
    slot.backing_addr.value = 64'h0000_0001_0000_0000;
    slot.sq_index = index;
    slot.sq_wrap = !polarity;
    slot.slot_sequence = longint'(slot.sq_wrap) * CMQ_DEPTH + index;
    slot.relative_offset = longint'(index) * 64;
    return profile.compose_sqe(command, slot, sqe, expected);
  endfunction

  // 功能：每个 golden 用例组装后与驱动 SQE 逐字节比对（无填充函数的 opcode 只比对 body）。
  // 输入/输出及副作用：读取 golden 文件。
  // 失败/边界：文件缺失、用例数不足、组装失败或字节不符时报告 UVM_ERROR。
  task automatic check_golden_requests();
    rdma_golden_case cases[$];
    rdma_hw_cmq_field_body body;
    rdma_hw_image sqe;
    rdma_cmq_field_spec_t specs[$];
    rdma_status status;
    string error;
    bit [7:0] opcode;
    int unsigned index;
    bit polarity;
    bit no_fill;
    bit [63:0] header;
    bit [63:0] envelope;
    int unsigned compared;

    if (!rdma_golden_reader::read_all("../hw/rdma/golden_vectors/cmq_requests.hex", cases,
                                      error)) begin
      `uvm_error("REQUEST_GOLDEN", error)
      return;
    end
    if (cases.size() != 51)
      `uvm_error("REQUEST_GOLDEN", $sformatf("expected 51 golden cases, got %0d", cases.size()))
    compared = 0;
    foreach (cases[c]) begin
      if (!parse_inputs(cases[c].name, cases[c].inputs, opcode, index, polarity, body))
        continue;
      status = compose(cases[c].name, opcode, index, polarity, body, sqe);
      if (status == null || !status.ok() || sqe == null || sqe.bytes.size() != 64) begin
        `uvm_error(cases[c].name, $sformatf("compose failed: %s",
                                           status == null ? "null" : status.convert2string()))
        continue;
      end
      void'(rdma_cmq_request_field_specs(opcode, specs));
      no_fill = specs.size() == 0;
      for (int b = no_fill ? 8 : 0; b < 64; b++)
        if (sqe.bytes[b] != cases[c].payload[b])
          `uvm_error(cases[c].name, $sformatf("byte %0d: model 0x%02x driver 0x%02x", b,
                                              sqe.bytes[b], cases[c].payload[b]))
      if (no_fill) begin
        header = '0;
        for (int b = 0; b < 8; b++)
          header = {header[55:0], sqe.bytes[b]};
        envelope = (64'(polarity) << RDMA_CMQ_VALID_LSB) | (64'(!polarity) << RDMA_CMQ_WRAP_LSB) |
                   (64'(index) << RDMA_CMQ_WQE_INDEX_LSB) | (64'(opcode) << RDMA_CMQ_OPCODE_LSB);
        if (header != envelope)
          `uvm_error(cases[c].name, "no-fill opcode must post a header-only SQE")
      end
      compared++;
    end
    if (compared != cases.size())
      `uvm_error("REQUEST_GOLDEN", $sformatf("compared %0d of %0d cases", compared, cases.size()))
  endtask

  // 功能：把 "k=v,..." 输入串拆成键值表（值保留原文）。
  // 输入/输出及副作用：kv 输出。
  // 失败/边界：无 '=' 的片段被忽略。
  function automatic void split_inputs(string inputs, output string kv[string]);
    int start;
    string token;

    kv.delete();
    start = 0;
    for (int i = 0; i <= inputs.len(); i++) begin
      if (i < inputs.len() && inputs.getc(i) != ",")
        continue;
      token = inputs.substr(start, i - 1);
      start = i + 1;
      for (int j = 0; j < token.len(); j++)
        if (token.getc(j) == "=") begin
          kv[token.substr(0, j - 1)] = token.substr(j + 1, token.len() - 1);
          break;
        end
    end
  endfunction

  // 功能：取 "0x..." 形式的数值输入。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：缺失键返回 0。
  function automatic longint unsigned num(string kv[string], string key);
    longint unsigned value;

    value = 0;
    if (kv.exists(key))
      void'($sscanf(kv[key].substr(2, kv[key].len() - 1), "%h", value));
    return value;
  endfunction

  // 功能：构造属于测试 binding 的资源句柄。
  // 输入/输出及副作用：返回新句柄。
  // 失败/边界：无。
  function automatic rdma_handle handle(rdma_resource_kind_e kind, longint unsigned id);
    rdma_handle h;

    h = rdma_handle::type_id::create("golden_handle");
    h.kind = kind;
    h.function_uid = binding.function_uid;
    h.object_id = id;
    h.generation = binding.generation;
    return h;
  endfunction

  // 功能：由字节构造带元数据的大端 image。
  // 输入/输出及副作用：返回新 image。
  // 失败/边界：无。
  function automatic rdma_hw_image make_raw(byte unsigned data[], rdma_image_kind_e kind);
    rdma_hw_image image;

    image = rdma_hw_image::type_id::create("golden_raw");
    foreach (data[i])
      image.bytes.push_back(data[i]);
    image.length = data.size();
    image.alignment = data.size();
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = kind;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = binding.generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    return image;
  endfunction

  // 功能：把驱动 SQE 去掉信封位后按上下文 codec 解码为模型（KEY_ALLOC/MR_REGISTER/*_CREATE 用）。
  // 输入/输出及副作用：model 输出。
  // 失败/边界：解码失败返回其 status。
  function automatic rdma_status decode_context(bit [7:0] opcode, byte unsigned sqe[],
                                                output rdma_hw_model model);
    rdma_codec_registry registry;
    rdma_codec_base codec;
    rdma_codec_key key;
    byte unsigned body[];
    bit [63:0] envelope;
    rdma_status status;

    model = null;
    registry = rdma_codec_registry::type_id::create("golden_context_codecs");
    status = rdma_register_context_body_codecs(registry);
    if (!status.ok())
      return status;
    key = rdma_cmq_context_codec_key(opcode);
    status = registry.lookup(key, codec);
    if (!status.ok())
      return status;
    body = sqe;
    envelope = request_envelope_mask(0);
    for (int b = 0; b < 8; b++)
      body[b] &= ~envelope[63 - b * 8 -: 8];
    status = codec.decode(make_raw(body, key.image_kind), model);
    if (status.ok())
      rebind(model);
    return status;
  endfunction

  // 功能：解码得到的句柄只含对象号；补上测试 binding 的 Function 身份与代际。
  // 输入/输出及副作用：修改 model 内句柄。
  // 失败/边界：未知模型类型不处理。
  function automatic void rebind(rdma_hw_model model);
    rdma_mrt_model mrt;
    rdma_cqc_model cqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_srqc_model srqc;
    rdma_handle handles[$];

    if ($cast(mrt, model)) handles = '{mrt.mr_h, mrt.pd_h};
    if ($cast(cqc, model)) handles = '{cqc.cq_h, cqc.ceq_h};
    if ($cast(ceqc, model)) handles = '{ceqc.ceq_h};
    if ($cast(aeqc, model)) handles = '{aeqc.aeq_h};
    if ($cast(srqc, model)) handles = '{srqc.srq_h, srqc.pd_h};
    foreach (handles[i])
      if (handles[i] != null) begin
        handles[i].function_uid = binding.function_uid;
        handles[i].generation = binding.generation;
      end
  endfunction

  // 功能：按驱动输入构造一个专用编码器 body（QPC/MR/OCC/对象 ID/空），上下文类由 decode_context 提供。
  // 输入/输出及副作用：body 与 qpc_source 输出。
  // 失败/边界：未知用例名报告 UVM_ERROR 并返回 0。
  function automatic bit build_dedicated(string name, bit [7:0] opcode, string kv[string],
                                         byte unsigned sqe[], rdma_golden_case ctx_by_name[string],
                                         output rdma_hw_model body,
                                         output rdma_hw_image qpc_source);
    rdma_hw_qpc_command_body qpc;
    rdma_hw_mr_deregister_body dereg;
    rdma_hw_occ_flush_body occ;
    rdma_hw_object_id_command_body object;
    rdma_resource_kind_e kind;
    string key;
    rdma_hw_cqc_delete_body cqc_delete;
    rdma_cqc_model cqc;
    rdma_hw_model decoded;
    rdma_qp_state_e states[6];
    rdma_status status;

    body = null;
    qpc_source = null;
    states = '{RDMA_QPS_RESET, RDMA_QPS_INIT, RDMA_QPS_RTR, RDMA_QPS_RTS, RDMA_QPS_ERROR,
               RDMA_QPS_SQD};
    if (name.substr(0, 3) == "qpc_") begin
      qpc = rdma_hw_qpc_command_body::type_id::create(name);
      qpc.qp_h = handle(RDMA_RESOURCE_QP, num(kv, "qpn"));
      if (kv.exists("sq_cqn")) begin
        qpc.send_cq_h = handle(RDMA_RESOURCE_CQ, num(kv, "sq_cqn"));
        qpc.recv_cq_h = handle(RDMA_RESOURCE_CQ, num(kv, "rq_cqn"));
      end
      qpc.qpc_buffer.value = num(kv, "qpc_buffer");
      qpc.next_state = kv.exists("next_state") ? states[num(kv, "next_state")] : RDMA_QPS_RESET;
      qpc.full_modify = kv.exists("modify_mode") && num(kv, "modify_mode") == RDMA_QPC_MODIFY_FULL;
      qpc.partial_modify = kv.exists("modify_mode") &&
                           num(kv, "modify_mode") == RDMA_QPC_MODIFY_PARTIAL;
      qpc.wbe_template_count = num(kv, "wbe_tpl_num");
      for (int q = 0; q < 4; q++) begin
        qpc.modify_start_qword[q] = num(kv, $sformatf("start_qword%0d", q));
        qpc.modify_wbe[q] = num(kv, $sformatf("wbe%0d", q));
        qpc.modify_data[q] = num(kv, $sformatf("data%0d", q));
      end
      if (kv.exists("qpc_source"))
        qpc_source = make_raw(ctx_by_name[kv["qpc_source"]].payload, RDMA_IMAGE_QPC);
      body = qpc;
      return 1;
    end
    case (name)
      "mr_deregister": begin
        dereg = rdma_hw_mr_deregister_body::type_id::create(name);
        dereg.mr_h = handle(RDMA_RESOURCE_MR, num(kv, "stag_index"));
        dereg.stag_key = num(kv, "stag_key");
        dereg.next_state = RDMA_CONTEXT_INVALID;
        if (num(kv, "states") == 2) dereg.next_state = RDMA_CONTEXT_VALID;
        body = dereg;
      end
      "occ_flush_vf", "occ_flush_serial", "occ_flush_qpn", "occ_flush_qpn_pd", "occ_flush_pd":
      begin
        occ = rdma_hw_occ_flush_body::type_id::create(name);
        {occ.qpc, occ.cqc, occ.mrt, occ.pble, occ.sqrqe} =
          {num(kv, "qpc_flag") != 0, num(kv, "cqc_flag") != 0, num(kv, "mrt_flag") != 0,
           num(kv, "pble_flag") != 0, num(kv, "sqrqe_flag") != 0};
        {occ.sgb_irqe, occ.eirqe, occ.orqe, occ.uaqe, occ.pd} =
          {num(kv, "sgb_irqe_flag") != 0, num(kv, "eirqe_flag") != 0, num(kv, "orqe_flag") != 0,
           num(kv, "uaqe_flag") != 0, num(kv, "pd_flag") != 0};
        occ.qpn = num(kv, "flush_qpn");
        occ.mr_serial = num(kv, "flush_mr_sn");
        occ.pd_backing.value = num(kv, "flush_pd_pba");
        occ.vf_flush = num(kv, "vf_flush");
        occ.mr_serial_flush = num(kv, "mr_sn_flush");
        body = occ;
      end
      "cqc_query", "ceqc_delete", "ceqc_query", "aeqc_delete", "aeqc_query",
      "srfqc_delete", "srfqc_query": begin
        object = rdma_hw_object_id_command_body::type_id::create(name);
        kind = RDMA_RESOURCE_SRQ;
        if (name.substr(0, 1) == "cq") kind = RDMA_RESOURCE_CQ;
        if (name.substr(0, 1) == "ce") kind = RDMA_RESOURCE_CEQ;
        if (name.substr(0, 1) == "ae") kind = RDMA_RESOURCE_AEQ;
        key = "srfqn";
        if (kv.exists("cqn")) key = "cqn";
        if (kv.exists("eqn")) key = "eqn";
        object.object_h = handle(kind, num(kv, key));
        body = object;
      end
      "tq_flush": begin
        body = rdma_hw_cmq_empty_body::type_id::create(name);
      end
      "cqc_delete": begin
        status = decode_context(RDMA_OP_CQC_CREATE, sqe, decoded);
        if (status.ok() && $cast(cqc, decoded)) begin
          cqc_delete = rdma_hw_cqc_delete_body::type_id::create(name);
          cqc_delete.cqc_context = cqc;
          body = cqc_delete;
        end
      end
      default: begin
        status = decode_context(opcode, sqe, decoded);
        if (!status.ok())
          `uvm_error(name, {"driver SQE does not decode: ", status.convert2string()})
        body = decoded;
      end
    endcase
    if (body == null)
      `uvm_error(name, "dedicated body could not be built")
    return body != null;
  endfunction

  // 功能：解码得到的上下文模型与驱动输入的关键字段逐项一致（独立于解码/重编码往返）。
  // 输入/输出及副作用：只读。
  // 失败/边界：不一致时报告 UVM_ERROR。
  function automatic void check_decoded_fields(string name, string kv[string], rdma_hw_model body);
    rdma_mrt_model mrt;
    rdma_cqc_model cqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_srqc_model srqc;
    rdma_hw_cqc_delete_body cqc_delete;

    if ($cast(mrt, body)) begin
      if (mrt.mr_h.object_id != num(kv, "stag_index") || mrt.lkey[7:0] != num(kv, "stag_key") ||
          mrt.pd_h.object_id != num(kv, "pd_idx") || mrt.length != num(kv, "len") ||
          mrt.iova.value != num(kv, "start_va") || mrt.object_type != num(kv, "type") ||
          mrt.page_layout.pbl_mode != num(kv, "pbl_mode") ||
          mrt.page_layout.payload_vf_id != num(kv, "pld_vf_id") ||
          mrt.page_layout.payload_vf_enable != num(kv, "pld_vf_en") ||
          mrt.page_layout.invalidate_enable != num(kv, "invalidate_en") ||
          mrt.page_layout.odp != num(kv, "odp") ||
          mrt.page_layout.mr_serial != num(kv, "mr_sn") ||
          mrt.page_layout.pba0.value != num(kv, "payload_pba_0") ||
          mrt.page_layout.pba1.value != num(kv, "payload_pba_1") ||
          mrt.page_layout.first_pbl_index != num(kv, "first_pbl_idx") ||
          mrt.state != RDMA_MR_STATE_VALID)
        `uvm_error(name, "decoded MRT fields differ from the driver inputs")
    end
    else if ($cast(cqc, body) && cqc.cq_h.object_id != num(kv, "cqn"))
      `uvm_error(name, "decoded CQN differs from the driver input")
    else if ($cast(cqc_delete, body) && cqc_delete.cqc_context.cq_h.object_id != num(kv, "cqn"))
      `uvm_error(name, "decoded CQN differs from the driver input")
    else if ($cast(ceqc, body) && ceqc.ceq_h.object_id != num(kv, "eqn"))
      `uvm_error(name, "decoded CEQN differs from the driver input")
    else if ($cast(aeqc, body) && aeqc.aeq_h.object_id != num(kv, "eqn"))
      `uvm_error(name, "decoded AEQN differs from the driver input")
    else if ($cast(srqc, body) && srqc.srq_h.object_id != num(kv, "srfqn"))
      `uvm_error(name, "decoded SRFQN differs from the driver input")
  endfunction

  // 功能：21 个专用编码 opcode 的驱动 golden（cmq_dedicated_oracle.py）逐字节比对。
  // 输入/输出及副作用：读取 golden 与 context.hex。
  // 失败/边界：用例数、构造、组装或字节不符时报告 UVM_ERROR。
  task automatic check_dedicated_requests();
    rdma_golden_case cases[$];
    rdma_golden_case ctx_case_list[$];
    rdma_golden_case ctx_by_name[string];
    rdma_cmq_command_desc command;
    rdma_cmq_slot_context slot;
    rdma_cmq_expected_response expected;
    rdma_hw_model body;
    rdma_hw_image qpc_source;
    rdma_hw_image sqe;
    rdma_status status;
    string kv[string];
    string error;
    bit [7:0] opcodes[$];
    bit [7:0] opcode;

    if (!rdma_golden_reader::read_all("../hw/rdma/golden_vectors/cmq_requests_dedicated.hex",
                                      cases, error) ||
        !rdma_golden_reader::read_all("../hw/rdma/golden_vectors/context.hex", ctx_case_list,
                                      error)) begin
      `uvm_error("DEDICATED_GOLDEN", error)
      return;
    end
    foreach (ctx_case_list[i])
      ctx_by_name[ctx_case_list[i].name] = ctx_case_list[i];
    if (cases.size() != 31)
      `uvm_error("DEDICATED_GOLDEN", $sformatf("expected 31 cases, got %0d", cases.size()))
    foreach (cases[c]) begin
      split_inputs(cases[c].inputs, kv);
      opcode = num(kv, "opcode");
      if (!(opcode inside {opcodes}))
        opcodes.push_back(opcode);
      if (!build_dedicated(cases[c].name, opcode, kv, cases[c].payload, ctx_by_name, body,
                           qpc_source))
        continue;
      check_decoded_fields(cases[c].name, kv, body);
      command = rdma_make_cmq_command(binding.make_handle(), opcode, "dedicated", body, 1us,
                                      cases[c].name);
      command.qpc_signature_source = qpc_source;
      slot = rdma_cmq_slot_context::type_id::create("dedicated_slot");
      slot.function_h = binding.make_handle();
      slot.cmq_h = cmq.handle;
      slot.backing_addr.value = 64'h0000_0001_0000_0000;
      slot.sq_index = num(kv, "index");
      slot.sq_wrap = !num(kv, "polarity");
      slot.slot_sequence = longint'(slot.sq_wrap) * CMQ_DEPTH + slot.sq_index;
      slot.relative_offset = longint'(slot.sq_index) * 64;
      status = profile.compose_sqe(command, slot, sqe, expected);
      if (status == null || !status.ok() || sqe == null) begin
        `uvm_error(cases[c].name, $sformatf("compose failed: %s",
                                           status == null ? "null" : status.convert2string()))
        continue;
      end
      foreach (cases[c].payload[b])
        if (sqe.bytes[b] != cases[c].payload[b])
          `uvm_error(cases[c].name, $sformatf("byte %0d: model 0x%02x driver 0x%02x", b,
                                              sqe.bytes[b], cases[c].payload[b]))
    end
    if (opcodes.size() != 21)
      `uvm_error("DEDICATED_GOLDEN", $sformatf("covered %0d dedicated opcodes", opcodes.size()))
  endtask

  // 功能：驱动 CQ 分派的每个 opcode（cmq_response_oracle.py）：驱动读取位全置 1 的 CQE 必须被接受，
  //   公共头一致，且 qword1..7 中驱动读取的字节全部落在模型回传负载切片内。
  // 输入/输出及副作用：读取 golden。
  // 失败/边界：拒绝、头字段不符、负载未覆盖或内容不符时报告 UVM_ERROR。
  task automatic check_driver_responses();
    rdma_golden_case cases[$];
    rdma_cmq_opcode_descriptor descriptor;
    rdma_cmq_decoded_cqe decoded;
    rdma_hw_cmq_completion completion;
    rdma_status status;
    string kv[string];
    string error;
    bit [63:0] consumed;
    bit [7:0] opcode;
    int unsigned first;
    int unsigned last;
    bit ready;

    if (!rdma_golden_reader::read_all("../hw/rdma/golden_vectors/cmq_responses.hex", cases,
                                      error)) begin
      `uvm_error("RESPONSE_GOLDEN", error)
      return;
    end
    if (cases.size() != 71)
      `uvm_error("RESPONSE_GOLDEN", $sformatf("expected 71 cases, got %0d", cases.size()))
    foreach (cases[c]) begin
      split_inputs(cases[c].inputs, kv);
      opcode = num(kv, "opcode");
      status = profile.inspect_cqe(make_raw(cases[c].payload, RDMA_IMAGE_CMQ_CQE), 1'b1, ready,
                                   decoded);
      if (status == null || !status.ok() || !ready || decoded == null) begin
        `uvm_error(cases[c].name, $sformatf("driver-consumed CQE rejected: %s",
                                           status == null ? "null" : status.convert2string()))
        continue;
      end
      if (decoded.hardware_opcode != opcode || decoded.wqe_index != num(kv, "index") ||
          decoded.wqe_wrap != num(kv, "wrap") || decoded.hardware_ecode != 0 ||
          !decoded.command_status.ok())
        `uvm_error(cases[c].name, "decoded CQE header differs from the driver fields")
      status = rdma_cmq_codec_registry::lookup(opcode, descriptor);
      if (!status.ok() || !$cast(completion, decoded.response_payload)) begin
        `uvm_error(cases[c].name, "completion descriptor or payload is missing")
        continue;
      end
      first = descriptor.completion_payload_offset;
      last = first + descriptor.completion_payload_length;
      for (int q = 1; q < 8; q++) begin
        consumed = num(kv, $sformatf("consumed%0d", q));
        for (int b = 0; b < 8; b++)
          if (consumed[63 - b * 8 -: 8] != 0 && !(q * 8 + b >= first && q * 8 + b < last))
            `uvm_error(cases[c].name,
                       $sformatf("driver reads CQE byte %0d outside the payload slice", q * 8 + b))
      end
      if (completion.object_payload.size() != last - first)
        `uvm_error(cases[c].name, "payload slice length differs from the descriptor")
      else
        foreach (completion.object_payload[i])
          if (completion.object_payload[i] != cases[c].payload[first + i])
            `uvm_error(cases[c].name, $sformatf("payload byte %0d differs", first + i))
    end
  endtask

  // 功能：字段 codec 的拒绝路径：未知成员、越宽取值、num 为 0、SD 额外数据长度不符、写出所有权外的位。
  // 输入/输出及副作用：每例新建 body 并组装。
  // 失败/边界：任一非法输入被接受时报告 UVM_ERROR。
  task automatic check_field_rejections();
    rdma_hw_cmq_field_body body;
    rdma_hw_image sqe;

    body = rdma_hw_cmq_field_body::type_id::create("unknown_member");
    body.values["no_such_member"] = 1;
    expect_status("FIELD_UNKNOWN", compose("unknown", RDMA_OP_KEY_QUERY, 0, 1, body, sqe),
                  RDMA_SC_INVALID_ARGUMENT);
    body = rdma_hw_cmq_field_body::type_id::create("too_wide");
    body.values["stag_idx"] = 64'h100_0000;
    expect_status("FIELD_TOO_WIDE", compose("wide", RDMA_OP_KEY_QUERY, 0, 1, body, sqe),
                  RDMA_SC_INVALID_ARGUMENT);
    body = rdma_hw_cmq_field_body::type_id::create("zero_num");
    body.values["num"] = 0;
    expect_status("FIELD_MINUS_ONE", compose("num", RDMA_OP_IDX_OCC_QPC, 0, 1, body, sqe),
                  RDMA_SC_INVALID_ARGUMENT);
    body = rdma_hw_cmq_field_body::type_id::create("sd_extra");
    body.values["sd_num"] = 3;
    body.blobs["sd_data"] = new[32];
    expect_status("FIELD_SD_EXTRA", compose("sd", RDMA_OP_SD_UPDATE, 0, 1, body, sqe),
                  RDMA_SC_INVALID_ARGUMENT);
    body = rdma_hw_cmq_field_body::type_id::create("sd_addr_mask");
    body.values["sd_num"] = 3;
    body.values["sd_buf_addr"] = 64'h1000_0001;
    body.blobs["sd_data"] = new[32];
    body.blobs["sd_extra_data"] = new[16];
    expect_status("FIELD_SD_ADDR_OWNERSHIP", compose("sdaddr", RDMA_OP_SD_UPDATE, 0, 1, body, sqe),
                  RDMA_SC_CODEC_ERROR);
    body = rdma_hw_cmq_field_body::type_id::create("extra_on_other");
    body.blobs["sd_extra_data"] = new[16];
    expect_status("FIELD_EXTRA_NON_SD", compose("extra", RDMA_OP_KEY_QUERY, 0, 1, body, sqe),
                  RDMA_SC_INVALID_ARGUMENT);
    body = rdma_hw_cmq_field_body::type_id::create("ifa_mask");
    body.values["data"] = 64'hffff_ffff_ffff_ffff;
    expect_status("FIELD_OWNERSHIP", compose("ifa", RDMA_OP_IFA_UPDATE, 0, 1, body, sqe),
                  RDMA_SC_CODEC_ERROR);
  endtask

  // 功能：每个表驱动 opcode 的公共 CQE（owner/opcode/index、ecode=0）都能被解码为成功。
  // 输入/输出及副作用：构造 raw CQE 并调用 profile.inspect_cqe。
  // 失败/边界：opcode 不被接受或状态非 OK 时报告 UVM_ERROR。
  task automatic check_header_completions();
    rdma_hw_image cqe;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_field_spec_t specs[$];
    rdma_status status;
    bit [63:0] qword0;
    bit ready;

    for (int unsigned op = 0; op <= RDMA_OP_OCC_PD_KICKOUT; op++) begin
      if (!rdma_cmq_request_field_specs(op[7:0], specs))
        continue;
      qword0 = (64'd1 << 63) | (64'(op) << RDMA_CMQ_OPCODE_LSB) |
               (64'd3 << RDMA_CMQ_WQE_INDEX_LSB);
      cqe = rdma_hw_image::type_id::create("header_cqe");
      for (int b = 0; b < 64; b++)
        cqe.bytes.push_back(b < 8 ? qword0[63 - b * 8 -: 8] : 8'h00);
      cqe.length = 64;
      cqe.alignment = 64;
      cqe.endian = RDMA_ENDIAN_BIG;
      cqe.image_kind = RDMA_IMAGE_CMQ_CQE;
      cqe.hardware_version = RDMA_HW_VERSION;
      cqe.function_generation = binding.generation;
      cqe.write_target_kind = RDMA_HW_TARGET_NONE;
      status = profile.inspect_cqe(cqe, 1'b1, ready, decoded);
      if (status == null || !status.ok() || !ready || decoded == null ||
          decoded.hardware_opcode != op || decoded.command_status == null ||
          !decoded.command_status.ok())
        `uvm_error("HEADER_CQE", $sformatf("opcode 0x%02x header-only CQE was not accepted: %s",
                                           op, status == null ? "null" : status.convert2string()))
    end
  endtask

  // 功能：依次运行 golden 比对、拒绝路径与 CQE 解码检查。
  // 输入/输出及副作用：持有一次 objection。
  // 失败/边界：子检查以 UVM_ERROR 报告失败。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    profile = rdma_hw_cmq_hw_profile::type_id::create("profile");
    binding = make_binding("golden_binding", RDMA_BIND_ACTIVE);
    cmq = make_cmq("golden_cmq", binding);
    check_golden_requests();
    check_dedicated_requests();
    check_driver_responses();
    check_field_rejections();
    check_header_completions();
    phase.drop_objection(this);
  endtask
endclass
