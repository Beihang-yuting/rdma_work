// 目录：单元测试层 tests/unit/rdma_drv_cmq_golden_test.sv。
// 层：单元测试。
// 职责：驱动模型 CMQ 编码的逐字节验收：hw/rdma/golden_vectors/cmq_requests.hex（tools/cmq_request_oracle.py
//   用驱动原文填充函数生成）的每个用例按其输入构造字段 body，经 rdma_drv_cmq::compose_fields（驱动模型
//   提交表驱动 opcode 的同一路径：字段表编码 + 信封 + 签名）得到 SQE，与驱动 SQE 逐字节比对；驱动不调用
//   填充函数的 opcode（全零 WQE）只比对 body 并要求头部为信封；另检查字段编码的拒绝路径。
// 依赖：rdma_drv_cmq、rdma_hw_cmq_field_codec、rdma_golden_reader。
// 所有权：golden 文件只读。
// 生命周期：run_phase 内运行。
class rdma_drv_cmq_golden_test extends uvm_test;
  `uvm_component_utils(rdma_drv_cmq_golden_test)

  localparam int unsigned GOLDEN_CASES = 51;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传。
  // 失败/边界：无。
  function new(string name = "rdma_drv_cmq_golden_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行 golden 比对与拒绝路径。
  // 输入/输出及副作用：持有 objection。
  // 失败/边界：以 UVM_ERROR 报告。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_golden_requests();
    check_field_rejections();
    phase.drop_objection(this);
  endtask

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

  // 功能：每个 golden 用例：有填充函数的 opcode 经 compose_fields 后 64B 全比对；无填充函数的
  //   opcode（驱动提交全零 WQE）由驱动模型以 new_sqe + seal 生成，比对 body 并要求头部为信封。
  // 输入/输出及副作用：读取 golden 文件。
  // 失败/边界：文件缺失、用例数不符、编码失败或字节不符时报告 UVM_ERROR。
  task automatic check_golden_requests();
    rdma_golden_case cases[$];
    rdma_hw_cmq_field_body body;
    rdma_cmq_field_spec_t specs[$];
    rdma_bytes_t sqe;
    rdma_bytes_t none;
    rdma_status status;
    string error;
    bit [7:0] opcode;
    int unsigned index;
    bit polarity;
    bit no_fill;
    bit [63:0] envelope;
    int unsigned compared;

    if (!rdma_golden_reader::read_all("../hw/rdma/golden_vectors/cmq_requests.hex", cases,
                                      error)) begin
      `uvm_error("REQUEST_GOLDEN", error)
      return;
    end
    if (cases.size() != GOLDEN_CASES)
      `uvm_error("REQUEST_GOLDEN", $sformatf("expected %0d golden cases, got %0d", GOLDEN_CASES,
                                             cases.size()))
    compared = 0;
    foreach (cases[c]) begin
      if (!parse_inputs(cases[c].name, cases[c].inputs, opcode, index, polarity, body))
        continue;
      void'(rdma_cmq_request_field_specs(opcode, specs));
      no_fill = specs.size() == 0;
      if (no_fill) begin
        sqe = rdma_drv_cmq::new_sqe(opcode);
        rdma_drv_cmq::seal(sqe, index, polarity, 1'b0, none);
      end
      else begin
        status = rdma_drv_cmq::compose_fields(opcode, body, index, polarity, sqe);
        if (!status.ok() || sqe.size() != RDMA_CMQE_BYTES) begin
          `uvm_error(cases[c].name, {"compose failed: ", status.convert2string()})
          continue;
        end
      end
      for (int b = no_fill ? 8 : 0; b < RDMA_CMQE_BYTES; b++)
        if (sqe[b] != cases[c].payload[b])
          `uvm_error(cases[c].name, $sformatf("byte %0d: model 0x%02x driver 0x%02x", b, sqe[b],
                                              cases[c].payload[b]))
      if (no_fill) begin
        envelope = (64'(polarity) << RDMA_CMQ_VALID_LSB) | (64'(!polarity) << RDMA_CMQ_WRAP_LSB) |
                   (64'(index) << RDMA_CMQ_WQE_INDEX_LSB) | (64'(opcode) << RDMA_CMQ_OPCODE_LSB);
        if (rdma_be::qword(sqe, 0) != envelope)
          `uvm_error(cases[c].name, "no-fill opcode must post a header-only SQE")
      end
      compared++;
    end
    if (compared != cases.size())
      `uvm_error("REQUEST_GOLDEN", $sformatf("compared %0d of %0d cases", compared, cases.size()))
  endtask

  // 功能：断言 compose_fields 以 expected 拒绝 body。
  // 输入/输出及副作用：只读。
  // 失败/边界：被接受或状态不符时报告 UVM_ERROR。
  function void expect_rejected(string label, bit [7:0] opcode, rdma_hw_cmq_field_body body,
                                rdma_status_code_e expected);
    rdma_bytes_t sqe;
    rdma_status status;

    status = rdma_drv_cmq::compose_fields(opcode, body, 0, 1'b1, sqe);
    if (status.code != expected)
      `uvm_error(label, $sformatf("expected %s, got %s", expected.name(), status.convert2string()))
  endfunction

  // 功能：字段编码的拒绝路径：未知成员、越宽取值、num 为 0、SD 额外数据长度不符、非 SD opcode 带
  //   SD 额外数据。
  // 输入/输出及副作用：每例新建 body。
  // 失败/边界：任一非法输入被接受时报告 UVM_ERROR。
  function void check_field_rejections();
    rdma_hw_cmq_field_body body;

    body = rdma_hw_cmq_field_body::type_id::create("unknown_member");
    body.values["no_such_member"] = 1;
    expect_rejected("FIELD_UNKNOWN", RDMA_OP_KEY_QUERY, body, RDMA_SC_INVALID_ARGUMENT);
    body = rdma_hw_cmq_field_body::type_id::create("too_wide");
    body.values["stag_idx"] = 64'h100_0000;
    expect_rejected("FIELD_TOO_WIDE", RDMA_OP_KEY_QUERY, body, RDMA_SC_INVALID_ARGUMENT);
    body = rdma_hw_cmq_field_body::type_id::create("zero_num");
    body.values["num"] = 0;
    expect_rejected("FIELD_MINUS_ONE", RDMA_OP_IDX_OCC_QPC, body, RDMA_SC_INVALID_ARGUMENT);
    body = rdma_hw_cmq_field_body::type_id::create("sd_extra");
    body.values["sd_num"] = 3;
    body.blobs["sd_data"] = new[32];
    expect_rejected("FIELD_SD_EXTRA", RDMA_OP_SD_UPDATE, body, RDMA_SC_INVALID_ARGUMENT);
    body = rdma_hw_cmq_field_body::type_id::create("extra_on_other");
    body.blobs["sd_extra_data"] = new[16];
    expect_rejected("FIELD_EXTRA_NON_SD", RDMA_OP_KEY_QUERY, body, RDMA_SC_INVALID_ARGUMENT);
  endfunction
endclass
