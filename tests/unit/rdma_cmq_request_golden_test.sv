// 目录：测试层 tests/unit/rdma_cmq_request_golden_test.sv。
// 职责：表驱动 CMQ opcode 的逐字节验收：按 golden（tools/cmq_request_oracle.py 用驱动原文填充函数
//   生成）的输入构造 field body，经生产 profile compose_sqe 后与驱动 SQE 比对；并检查字段拒绝路径与
//   这些 opcode 的公共 CQE 解码。
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
    if (cases.size() != 50)
      `uvm_error("REQUEST_GOLDEN", $sformatf("expected 50 golden cases, got %0d", cases.size()))
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
    check_field_rejections();
    check_header_completions();
    phase.drop_objection(this);
  endtask
endclass
