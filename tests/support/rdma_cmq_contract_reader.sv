// 目录：测试层 support/rdma_cmq_contract_reader.sv。
// 职责：严格、只读地解析驱动派生的 CMQ 逐 bit mutation 合同，并把每列
//   规范化为 gate 可直接消费的类型化证据。
// 主要依赖：仅依赖 UVM object 基类；字段坐标和结果配对来自冻结 TSV，
//   不读取或复用被测 SystemVerilog codec 的 mask。
// 所有权与生命周期：reader 只拥有本次解析创建的 row；文件描述符在
//   read_all 返回前关闭，调用方取得 rows 队列中对象的所有权。

typedef enum bit [1:0] {
  RDMA_CMQ_CASE_QPC_REQUEST,
  RDMA_CMQ_CASE_QPC_RESPONSE,
  RDMA_CMQ_CASE_SQ_DOORBELL
} rdma_cmq_contract_case_e;

typedef enum bit [1:0] {
  RDMA_CMQ_ENTRY_SQE,
  RDMA_CMQ_ENTRY_CQE,
  RDMA_CMQ_ENTRY_SQ_DOORBELL
} rdma_cmq_contract_entry_e;

typedef enum bit {
  RDMA_CMQ_CONTRACT_REQUEST,
  RDMA_CMQ_CONTRACT_RESPONSE
} rdma_cmq_contract_direction_e;

typedef enum bit [2:0] {
  RDMA_CMQ_EVIDENCE_TYPED_RECOMPOSE,
  RDMA_CMQ_EVIDENCE_CORRELATED_RECOMPOSE,
  RDMA_CMQ_EVIDENCE_DRIVER_FIXED_REJECT,
  RDMA_CMQ_EVIDENCE_STATIC_CANONICAL,
  RDMA_CMQ_EVIDENCE_STATIC_UNWRITABLE,
  RDMA_CMQ_EVIDENCE_RAW_DECODE_MUTATION
} rdma_cmq_evidence_mode_e;

class rdma_cmq_field_evidence_row extends uvm_object;
  `uvm_object_utils(rdma_cmq_field_evidence_row)

  string case_id;
  string entry;
  string opcode;
  string direction;
  int unsigned byte_offset;
  int unsigned qword_index;
  int unsigned bit_index;
  string expected_class;
  string expected_field;
  string evidence_mode;
  string correlation_group;
  string driver_result_class;
  string model_consumer;
  string expected_outcome;
  string expected_status_code;
  string expected_ready;
  string expected_value_delta;
  string oracle_case_id;

  rdma_cmq_contract_case_e case_kind;
  rdma_cmq_contract_entry_e entry_kind;
  rdma_cmq_contract_direction_e direction_kind;
  rdma_cmq_evidence_mode_e evidence_kind;
  bit [7:0] opcode_value;
  bit status_applicable;
  rdma_status_code_e status_code_value;
  int ready_value;
  bit value_delta;

  // 功能：构造一个尚未解析的 CMQ 证据行，并为所有原始列和类型化列建立确定初值。
  // 输入/输出及副作用：name 输入仅设置 UVM 对象名；函数初始化本对象，不打开文件，也不取得外部对象所有权。
  // 失败/边界：构造成功不代表合同有效；只有 parse_row 完整赋值并验证后的对象才允许进入 gate。
  function new(string name = "rdma_cmq_field_evidence_row");
    super.new(name);

    case_id = "";
    entry = "";
    opcode = "";
    direction = "";
    byte_offset = 0;
    qword_index = 0;
    bit_index = 0;
    expected_class = "";
    expected_field = "";
    evidence_mode = "";
    correlation_group = "";
    driver_result_class = "";
    model_consumer = "";
    expected_outcome = "";
    expected_status_code = "";
    expected_ready = "";
    expected_value_delta = "";
    oracle_case_id = "";

    case_kind = RDMA_CMQ_CASE_QPC_REQUEST;
    entry_kind = RDMA_CMQ_ENTRY_SQE;
    direction_kind = RDMA_CMQ_CONTRACT_REQUEST;
    evidence_kind = RDMA_CMQ_EVIDENCE_TYPED_RECOMPOSE;
    opcode_value = '0;
    status_applicable = 1'b0;
    status_code_value = RDMA_SC_OK;
    ready_value = -1;
    value_delta = 1'b0;
  endfunction
endclass

class rdma_cmq_contract_reader;
  localparam int unsigned COLUMN_COUNT = 18;

  // 功能：split_tab 按单个 tab 边界拆分一行 TSV，并保留连续 tab 形成的空字段供上层拒绝。
  // 输入/输出及副作用：line 为只读输入，tokens 在进入函数时清空并接收全部列；函数不修改 line 或文件状态。
  // 失败/边界：零长度 line 返回 0；尾随 tab 或连续 tab 仍返回列，由 parse_row 以空列失败。
  static function bit split_tab(string line, output string tokens[$]);
    int start;

    tokens.delete();
    if (line.len() == 0)
      return 1'b0;

    start = 0;
    for (int i = 0; i <= line.len(); i++) begin
      if (i == line.len() || line.getc(i) == 8'h09) begin
        tokens.push_back(
          (i == start) ? "" : line.substr(start, i - 1)
        );
        start = i + 1;
      end
    end

    return 1'b1;
  endfunction

  // 功能：strip_line_ending 接受规范 LF 或 CRLF 物理行，移除唯一行尾并返回不含换行的文本。
  // 输入/输出及副作用：raw 输入来自 $fgets，line 输出为新字符串；函数只读 raw，不改变文件游标。
  // 失败/边界：缺少 LF、出现孤立 CR/LF、空物理行或 CRCRLF 均返回 0，避免平台换行被静默归一化。
  static function bit strip_line_ending(
      input string raw,
      output string line
  );
    int last;

    line = "";
    if (raw.len() == 0 || raw.getc(raw.len() - 1) != 8'h0a)
      return 1'b0;

    last = raw.len() - 2;
    if (last >= 0 && raw.getc(last) == 8'h0d)
      last--;

    for (int i = 0; i <= last; i++) begin
      if (raw.getc(i) == 8'h0a || raw.getc(i) == 8'h0d)
        return 1'b0;
    end

    if (last >= 0)
      line = raw.substr(0, last);

    return 1'b1;
  endfunction

  // 功能：contains_forbidden_text 检测数据列中的注释起始符、空白或控制字符，防止 token 被宽松解析。
  // 输入/输出及副作用：token 为只读输入；返回是否存在 #、space、tab、CR、LF 或其他 ASCII 控制字符。
  // 失败/边界：空 token 由 parse_row 单独拒绝；本函数对非 ASCII 字节也保守返回 1。
  static function bit contains_forbidden_text(string token);
    int ch;

    for (int i = 0; i < token.len(); i++) begin
      ch = token.getc(i);
      if (ch == 8'h23 || ch == 8'h20 || ch == 8'h09 ||
          ch == 8'h0a || ch == 8'h0d || ch < 8'h21 || ch > 8'h7e)
        return 1'b1;
    end

    return 1'b0;
  endfunction

  // 功能：parse_decimal 把 mutation 坐标的规范十进制文本转换为 int unsigned。
  // 输入/输出及副作用：text 输入、value 输出；成功时写 value，不读取或修改任何合同对象。
  // 失败/边界：空值、符号、0x 前缀、非数字、非规范前导零或 32-bit 溢出均返回 0。
  static function bit parse_decimal(
      input string text,
      output int unsigned value
  );
    longint unsigned parsed;
    int digit;

    value = 0;
    if (text.len() == 0 ||
        (text.len() > 1 && text.getc(0) == 8'h30))
      return 1'b0;

    parsed = 0;
    for (int i = 0; i < text.len(); i++) begin
      if (text.getc(i) < 8'h30 || text.getc(i) > 8'h39)
        return 1'b0;

      digit = text.getc(i) - 8'h30;
      if (parsed > (64'hffff_ffff - digit) / 10)
        return 1'b0;

      parsed = (parsed * 10) + digit;
    end

    value = int'(parsed);
    return 1'b1;
  endfunction

  // 功能：expected_field_at 用冻结驱动合同的逻辑 qword 坐标判定一行应归属的语义字段或保留零区域。
  // 输入/输出及副作用：row 为只读、已完成 case/坐标解析的对象；返回规范 expected_field，不使用被测 SV mask。
  // 失败/边界：case_kind 只接受三个冻结 case；超出 case 长度的坐标由 parse_row 先拒绝，default 返回空串使调用方失败。
  static function string expected_field_at(
      rdma_cmq_field_evidence_row row
  );
    case (row.case_kind)
      RDMA_CMQ_CASE_QPC_REQUEST: begin
        if (row.qword_index == 0) begin
          if (row.bit_index == 63) begin
            return "valid";
          end
          if (row.bit_index == 59) begin
            return "vf_id_override";
          end
          if (row.bit_index inside {[48:58]}) begin
            return "use_vfid";
          end
          if (row.bit_index == 45) begin
            return "wrap";
          end
          if (row.bit_index inside {[40:44]}) begin
            return "index";
          end
          if (row.bit_index inside {[32:39]}) begin
            return "opcode";
          end
          if (row.bit_index inside {[0:23]}) begin
            return "qpn";
          end
          return "-";
        end

        if (row.qword_index == 1) begin
          if (row.bit_index inside {[0:20]}) begin
            return "rq_cqn";
          end
          if (row.bit_index inside {[24:31]}) begin
            return "signature";
          end
          if (row.bit_index == 32) begin
            return "sign_en";
          end
          if (row.bit_index inside {[43:63]}) begin
            return "sq_cqn";
          end
          return "-";
        end

        if (row.qword_index == 3 &&
            row.bit_index inside {[9:63]}) begin
          return "qpc_buffer_addr_pa";
        end

        return "-";
      end

      RDMA_CMQ_CASE_QPC_RESPONSE: begin
        if (row.qword_index != 0)
          return "-";

        if (row.bit_index == 63) begin
          return "owner";
        end
        if (row.bit_index == 45) begin
          return "wrap";
        end
        if (row.bit_index inside {[40:44]}) begin
          return "index";
        end
        if (row.bit_index inside {[32:39]}) begin
          return "opcode";
        end
        if (row.bit_index inside {[24:31]}) begin
          return "ecode";
        end
        return "-";
      end

      RDMA_CMQ_CASE_SQ_DOORBELL: begin
        if (row.bit_index inside {[32:36]}) begin
          return "pi";
        end
        if (row.bit_index == 37) begin
          return "polarity";
        end
        return "-";
      end

      default: return "";
    endcase
  endfunction

  // 功能：matches_contract 比较一行的分类、证据、driver 结果与 model 结果是否精确等于冻结组合。
  // 输入/输出及副作用：row 只读；其余字符串是该坐标的期望值；函数返回布尔值，不改写 row。
  // 失败/边界：任一列缺失、跨层混用或额外状态发布均返回 0，由 parse_row 报 malformed row。
  static function bit matches_contract(
      rdma_cmq_field_evidence_row row,
      string expected_class,
      string evidence_mode,
      string correlation_group,
      string driver_result_class,
      string expected_outcome,
      string expected_status_code,
      string expected_ready,
      string expected_value_delta
  );
    return row.expected_class == expected_class &&
           row.evidence_mode == evidence_mode &&
           row.correlation_group == correlation_group &&
           row.driver_result_class == driver_result_class &&
           row.expected_outcome == expected_outcome &&
           row.expected_status_code == expected_status_code &&
           row.expected_ready == expected_ready &&
           row.expected_value_delta == expected_value_delta;
  endfunction

  // 功能：validate_row_semantics 对 case 身份、consumer、字段所有权和运行时结果配对执行逐行 fail-closed 校验。
  // 输入/输出及副作用：row 为只读已解析对象；返回合同是否精确成立，不调用生产 codec 或修改证据。
  // 失败/边界：未知字段、错误 evidence/result 配对、static 行携带 status/ready、response 层混淆或 doorbell 路由漂移均返回 0。
  static function bit validate_row_semantics(
      rdma_cmq_field_evidence_row row
  );
    string field;

    field = expected_field_at(row);
    if (field.len() == 0 || row.expected_field != field ||
        row.oracle_case_id != row.case_id)
      return 1'b0;

    case (row.case_kind)
      RDMA_CMQ_CASE_QPC_REQUEST: begin
        if (row.entry != "CMQ_SQE" || row.opcode != "QPC_CREATE" ||
            row.direction != "REQUEST" ||
            row.model_consumer != "CMQ_REQUEST_COMPOSER")
          return 1'b0;

        case (field)
          "valid", "wrap":
            return matches_contract(
              row, "HOST_TYPED", "CORRELATED_RECOMPOSE",
              "QPC_POLARITY_VALID_WRAP", "ENCODED", "ACCEPT",
              "OK", "1", "1"
            );

          "index", "qpn", "sq_cqn", "rq_cqn",
          "qpc_buffer_addr_pa", "signature":
            return matches_contract(
              row, "HOST_TYPED", "TYPED_RECOMPOSE", "-",
              "ENCODED", "ACCEPT", "OK", "1", "1"
            );

          "vf_id_override", "use_vfid":
            return matches_contract(
              row, "HOST_FIXED", "DRIVER_FIXED_REJECT", "-",
              "FIXED_ZERO", "REJECT", "INVALID_ARGUMENT", "0", "1"
            );

          "opcode", "sign_en":
            return matches_contract(
              row, "HOST_FIXED", "STATIC_CANONICAL", "-",
              "STATIC_CANONICAL", "CANONICAL", "-", "-", "0"
            );

          "-":
            return matches_contract(
              row, "RESERVED_ZERO", "STATIC_UNWRITABLE", "-",
              "STATIC_UNWRITABLE", "REJECT", "-", "-", "0"
            );

          default: return 1'b0;
        endcase
      end

      RDMA_CMQ_CASE_QPC_RESPONSE: begin
        if (row.entry != "CMQ_CQE" || row.opcode != "QPC_CREATE" ||
            row.direction != "RESPONSE" ||
            row.model_consumer != "CMQ_COMPLETION_CODEC" ||
            row.evidence_mode != "RAW_DECODE_MUTATION" ||
            row.correlation_group != "-" ||
            row.expected_value_delta != "1")
          return 1'b0;

        case (field)
          "owner":
            return row.expected_class == "HW_TYPED" &&
                   row.driver_result_class == "NOT_READY" &&
                   row.expected_outcome == "NOT_READY" &&
                   row.expected_status_code == "OK" &&
                   row.expected_ready == "0";

          "index":
            return row.expected_class == "HW_TYPED" &&
                   row.driver_result_class == "REQUEST_LOOKUP_CHANGED" &&
                   row.expected_outcome == "ACCEPT" &&
                   row.expected_status_code == "OK" &&
                   row.expected_ready == "1";

          "wrap":
            return row.expected_class == "HW_TYPED" &&
                   row.driver_result_class == "WRAP_MISMATCH" &&
                   row.expected_outcome == "ACCEPT" &&
                   row.expected_status_code == "OK" &&
                   row.expected_ready == "1";

          "opcode": begin
            if (row.expected_class != "HW_TYPED" ||
                row.driver_result_class != "OPCODE_MISMATCH")
              return 1'b0;

            if (row.expected_status_code == "OK")
              return row.expected_outcome == "ACCEPT" &&
                     row.expected_ready == "1";

            return row.expected_status_code == "UNSUPPORTED_OPCODE" &&
                   row.expected_outcome == "REJECT" &&
                   row.expected_ready == "0";
          end

          "ecode":
            return row.expected_class == "HW_TYPED" &&
                   row.driver_result_class == "ECODE_ERROR" &&
                   row.expected_outcome == "PUBLISH_ECODE" &&
                   row.expected_status_code == "OK" &&
                   row.expected_ready == "1";

          "-":
            return row.expected_class == "RESERVED_ZERO" &&
                   row.driver_result_class == "READY_OK" &&
                   row.expected_outcome == "REJECT" &&
                   row.expected_status_code == "CODEC_ERROR" &&
                   row.expected_ready == "0";

          default: return 1'b0;
        endcase
      end

      RDMA_CMQ_CASE_SQ_DOORBELL: begin
        if (row.entry != "CMQ_SQ_DOORBELL" ||
            row.opcode != "CMQ_SQ" || row.direction != "REQUEST" ||
            row.model_consumer != "CMQ_DOORBELL_ENCODER" ||
            row.correlation_group != "-")
          return 1'b0;

        if (field == "pi" || field == "polarity")
          return matches_contract(
            row, "HOST_TYPED", "TYPED_RECOMPOSE", "-",
            "ENCODED", "ACCEPT", "OK", "1", "1"
          );

        if (field == "-")
          return matches_contract(
            row, "RESERVED_ZERO", "STATIC_UNWRITABLE", "-",
            "STATIC_UNWRITABLE", "REJECT", "-", "-", "0"
          );

        return 1'b0;
      end

      default: return 1'b0;
    endcase
  endfunction

  // 功能：parse_row 将恰好 18 个原始 TSV token 转换为一个带规范枚举、数值和业务配对的证据对象。
  // 输入/输出及副作用：tokens 输入；成功时 row 输出新对象，失败时输出 null；函数不保留 tokens 引用。
  // 失败/边界：空列、注释/空白混入、未知 case/enum/result、非十进制坐标、长度越界、byte/qword 映射或语义配对漂移均返回 0。
  static function bit parse_row(
      input string tokens[$],
      output rdma_cmq_field_evidence_row row
  );
    int unsigned image_length;

    row = null;
    if (tokens.size() != COLUMN_COUNT)
      return 1'b0;

    foreach (tokens[i]) begin
      if (tokens[i].len() == 0 || contains_forbidden_text(tokens[i]))
        return 1'b0;
    end

    row = rdma_cmq_field_evidence_row::type_id::create(
      "cmq_evidence_row"
    );
    row.case_id = tokens[0];
    row.entry = tokens[1];
    row.opcode = tokens[2];
    row.direction = tokens[3];
    row.expected_class = tokens[7];
    row.expected_field = tokens[8];
    row.evidence_mode = tokens[9];
    row.correlation_group = tokens[10];
    row.driver_result_class = tokens[11];
    row.model_consumer = tokens[12];
    row.expected_outcome = tokens[13];
    row.expected_status_code = tokens[14];
    row.expected_ready = tokens[15];
    row.expected_value_delta = tokens[16];
    row.oracle_case_id = tokens[17];

    if (!parse_decimal(tokens[4], row.byte_offset) ||
        !parse_decimal(tokens[5], row.qword_index) ||
        !parse_decimal(tokens[6], row.bit_index)) begin
      row = null;
      return 1'b0;
    end

    case (row.case_id)
      "cmq_sqe_qpc_create_request": begin
        row.case_kind = RDMA_CMQ_CASE_QPC_REQUEST;
        row.entry_kind = RDMA_CMQ_ENTRY_SQE;
        row.direction_kind = RDMA_CMQ_CONTRACT_REQUEST;
        row.opcode_value = RDMA_OP_QPC_CREATE;
        image_length = 64;
      end

      "cmq_cqe_qpc_create_response": begin
        row.case_kind = RDMA_CMQ_CASE_QPC_RESPONSE;
        row.entry_kind = RDMA_CMQ_ENTRY_CQE;
        row.direction_kind = RDMA_CMQ_CONTRACT_RESPONSE;
        row.opcode_value = RDMA_OP_QPC_CREATE;
        image_length = 64;
      end

      "cmq_sq_doorbell": begin
        row.case_kind = RDMA_CMQ_CASE_SQ_DOORBELL;
        row.entry_kind = RDMA_CMQ_ENTRY_SQ_DOORBELL;
        row.direction_kind = RDMA_CMQ_CONTRACT_REQUEST;
        row.opcode_value = 8'h00;
        image_length = 8;
      end

      default: begin
        row = null;
        return 1'b0;
      end
    endcase

    case (row.evidence_mode)
      "TYPED_RECOMPOSE":
        row.evidence_kind = RDMA_CMQ_EVIDENCE_TYPED_RECOMPOSE;
      "CORRELATED_RECOMPOSE":
        row.evidence_kind = RDMA_CMQ_EVIDENCE_CORRELATED_RECOMPOSE;
      "DRIVER_FIXED_REJECT":
        row.evidence_kind = RDMA_CMQ_EVIDENCE_DRIVER_FIXED_REJECT;
      "STATIC_CANONICAL":
        row.evidence_kind = RDMA_CMQ_EVIDENCE_STATIC_CANONICAL;
      "STATIC_UNWRITABLE":
        row.evidence_kind = RDMA_CMQ_EVIDENCE_STATIC_UNWRITABLE;
      "RAW_DECODE_MUTATION":
        row.evidence_kind = RDMA_CMQ_EVIDENCE_RAW_DECODE_MUTATION;
      default: begin
        row = null;
        return 1'b0;
      end
    endcase

    case (row.expected_status_code)
      "-": begin
        row.status_applicable = 1'b0;
        row.status_code_value = RDMA_SC_OK;
      end

      "OK": begin
        row.status_applicable = 1'b1;
        row.status_code_value = RDMA_SC_OK;
      end

      "INVALID_ARGUMENT": begin
        row.status_applicable = 1'b1;
        row.status_code_value = RDMA_SC_INVALID_ARGUMENT;
      end

      "CODEC_ERROR": begin
        row.status_applicable = 1'b1;
        row.status_code_value = RDMA_SC_CODEC_ERROR;
      end

      "UNSUPPORTED_OPCODE": begin
        row.status_applicable = 1'b1;
        row.status_code_value = RDMA_SC_UNSUPPORTED_OPCODE;
      end

      default: begin
        row = null;
        return 1'b0;
      end
    endcase

    if (row.expected_ready == "-")
      row.ready_value = -1;
    else if (row.expected_ready == "0")
      row.ready_value = 0;
    else if (row.expected_ready == "1")
      row.ready_value = 1;
    else begin
      row = null;
      return 1'b0;
    end

    if (row.expected_value_delta == "0")
      row.value_delta = 1'b0;
    else if (row.expected_value_delta == "1")
      row.value_delta = 1'b1;
    else begin
      row = null;
      return 1'b0;
    end

    if (row.byte_offset >= image_length ||
        row.qword_index >= (image_length / 8) || row.bit_index >= 64 ||
        row.byte_offset !=
          (row.qword_index * 8) + (7 - (row.bit_index / 8))) begin
      row = null;
      return 1'b0;
    end

    if (!validate_row_semantics(row)) begin
      row = null;
      return 1'b0;
    end

    return 1'b1;
  endfunction

  // 功能：read_all 读取完整 mutation manifest，验证物理文本、每行语义、坐标唯一性、correlation 闭合和冻结计数。
  // 输入/输出及副作用：path 输入；rows 和 error 输出；函数只读文件，并保证所有成功/失败出口前关闭 fd。
  // 失败/边界：header/换行/注释/空行异常、duplicate、任一行 fail-closed 校验失败，或 1088 行及六类计数漂移时返回 0 且 rows 清空。
  static function bit read_all(
      input string path,
      output rdma_cmq_field_evidence_row rows[$],
      output string error
  );
    string expected_header;
    string raw_line;
    string line;
    string tokens[$];
    string key;
    bit seen[string];
    int fd;
    int line_number;
    int typed;
    int correlated;
    int fixed;
    int canonical;
    int unwritable;
    int raw;
    int request_qpc;
    int response_qpc;
    int doorbell;
    int correlation_count;
    bit correlation_valid;
    bit correlation_wrap;
    rdma_cmq_field_evidence_row row;

    expected_header = {
      "case_id\tentry\topcode\tdirection\tbyte_offset\tqword_index\t",
      "bit_index\texpected_class\texpected_field\tevidence_mode\t",
      "correlation_group\tdriver_result_class\tmodel_consumer\t",
      "expected_outcome\texpected_status_code\texpected_ready\t",
      "expected_value_delta\toracle_case_id"
    };

    rows.delete();
    error = "";
    line_number = 0;
    typed = 0;
    correlated = 0;
    fixed = 0;
    canonical = 0;
    unwritable = 0;
    raw = 0;
    request_qpc = 0;
    response_qpc = 0;
    doorbell = 0;
    correlation_count = 0;
    correlation_valid = 1'b0;
    correlation_wrap = 1'b0;

    fd = $fopen(path, "r");
    if (fd == 0) begin
      error = "cannot open mutation manifest";
      return 1'b0;
    end

    while ($fgets(raw_line, fd)) begin
      line_number++;

      if (!strip_line_ending(raw_line, line)) begin
        error = $sformatf(
          "mutation manifest line %0d has invalid line ending",
          line_number
        );
        $fclose(fd);
        rows.delete();
        return 1'b0;
      end

      if (line_number == 1) begin
        if (line != expected_header) begin
          error = "invalid mutation header";
          $fclose(fd);
          rows.delete();
          return 1'b0;
        end
        continue;
      end

      if (line.len() == 0) begin
        error = $sformatf(
          "mutation manifest line %0d is empty",
          line_number
        );
        $fclose(fd);
        rows.delete();
        return 1'b0;
      end

      if (line.getc(0) == 8'h23)
        continue;

      if (!split_tab(line, tokens) || !parse_row(tokens, row)) begin
        error = $sformatf(
          "malformed mutation row at line %0d",
          line_number
        );
        $fclose(fd);
        rows.delete();
        return 1'b0;
      end

      key = {
        row.case_id, ":", $sformatf("%0d", row.qword_index), ":",
        $sformatf("%0d", row.bit_index)
      };
      if (seen.exists(key)) begin
        error = {"duplicate case/coordinate: ", key};
        $fclose(fd);
        rows.delete();
        return 1'b0;
      end

      seen[key] = 1'b1;
      rows.push_back(row);

      case (row.case_kind)
        RDMA_CMQ_CASE_QPC_REQUEST: request_qpc++;
        RDMA_CMQ_CASE_QPC_RESPONSE: response_qpc++;
        RDMA_CMQ_CASE_SQ_DOORBELL: doorbell++;
        default: ;
      endcase

      case (row.evidence_kind)
        RDMA_CMQ_EVIDENCE_TYPED_RECOMPOSE: typed++;
        RDMA_CMQ_EVIDENCE_CORRELATED_RECOMPOSE: correlated++;
        RDMA_CMQ_EVIDENCE_DRIVER_FIXED_REJECT: fixed++;
        RDMA_CMQ_EVIDENCE_STATIC_CANONICAL: canonical++;
        RDMA_CMQ_EVIDENCE_STATIC_UNWRITABLE: unwritable++;
        RDMA_CMQ_EVIDENCE_RAW_DECODE_MUTATION: raw++;
        default: ;
      endcase

      if (row.correlation_group == "QPC_POLARITY_VALID_WRAP") begin
        correlation_count++;
        if (row.expected_field == "valid") correlation_valid = 1'b1;
        if (row.expected_field == "wrap") correlation_wrap = 1'b1;
      end
    end

    $fclose(fd);

    if (line_number == 0 || rows.size() != 1088 || request_qpc != 512 ||
        response_qpc != 512 || doorbell != 64 || typed != 140 ||
        correlated != 2 || fixed != 12 || canonical != 9 ||
        unwritable != 413 || raw != 512) begin
      error = $sformatf(
        {"mutation manifest count mismatch: rows=%0d request=%0d ",
         "response=%0d doorbell=%0d typed=%0d correlated=%0d fixed=%0d ",
         "canonical=%0d unwritable=%0d raw=%0d"},
        rows.size(), request_qpc, response_qpc, doorbell, typed,
        correlated, fixed, canonical, unwritable, raw
      );
      rows.delete();
      return 1'b0;
    end

    if (correlation_count != 2 ||
        !correlation_valid || !correlation_wrap) begin
      error = "QPC polarity correlation group is not exactly VALID/WRAP";
      rows.delete();
      return 1'b0;
    end

    return 1'b1;
  endfunction
endclass
