// 目录：测试层 support/rdma_cmq_contract_reader.sv。
// 职责：只读解析 Task 4 CMQ field-mutation TSV，提供类型化证据行给 UVM gate。
// 依赖与所有权：仅依赖 rdma_types_pkg；不拥有文件内容或任何运行时资源。

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

  // 功能：构造空证据行，建立所有字段的确定性初始值。
  // 输入输出及副作用：name 仅用于 UVM 名称；所有字符串为空、数值为零，不打开文件。
  // 失败边界：构造函数不验证字段；未完成 parse 的行不得提交给 gate。
  function new(string name = "rdma_cmq_field_evidence_row");
    super.new(name);
    case_id = ""; entry = ""; opcode = ""; direction = "";
    byte_offset = 0; qword_index = 0; bit_index = 0;
    expected_class = ""; expected_field = ""; evidence_mode = "";
    correlation_group = ""; driver_result_class = ""; model_consumer = "";
    expected_outcome = ""; expected_status_code = "";
    expected_ready = ""; expected_value_delta = ""; oracle_case_id = "";
  endfunction
endclass

class rdma_cmq_contract_reader;
  localparam int unsigned COLUMN_COUNT = 18;

  // 功能：split_tab 将一行 TSV 按严格 tab 分隔为字段队列，并保留空字段。
  // 输入输出及副作用：line 输入；tokens 输出；函数只读字符串，不修改外部状态。
  // 失败边界：空行或缺少终止字段返回 0；连续 tab 产生空 token，由调用方拒绝。
  static function bit split_tab(string line, output string tokens[$]);
    int start;
    tokens.delete();
    start = 0;
    for (int i = 0; i <= line.len(); i++) begin
      if (i == line.len() || line.getc(i) == 8'h09) begin
        tokens.push_back(i == start ? "" : line.substr(start, i - 1));
        start = i + 1;
      end
    end
    return tokens.size() != 0;
  endfunction

  // 功能：parse_uint 解析无前导空格的十进制或 0x 前缀十六进制字段。
  // 输入输出及副作用：text 输入、value 输出；不产生 I/O 或对象所有权变化。
  // 失败边界：空值、负号、非法字符、溢出或非规范前导零均返回 0。
  static function bit parse_uint(string text, output int unsigned value);
    longint unsigned parsed;
    int base;
    int start;
    value = 0;
    if (text.len() == 0 || text.getc(0) == 8'h2d)
      return 0;
    base = 10;
    start = 0;
    if (text.len() > 2 && text.substr(0, 1) == "0x") begin
      base = 16;
      start = 2;
      if (text.len() == 2)
        return 0;
    end
    if (base == 10 && text.len() > 1 && text.getc(0) == 8'h30)
      return 0;
    parsed = 0;
    for (int i = start; i < text.len(); i++) begin
      int ch = text.getc(i);
      int digit;
      if (ch >= 8'h30 && ch <= 8'h39) digit = ch - 8'h30;
      else if (base == 16 && ch >= 8'h61 && ch <= 8'h66)
        digit = ch - 8'h61 + 10;
      else if (base == 16 && ch >= 8'h41 && ch <= 8'h46)
        return 0;
      else return 0;
      if (digit >= base || parsed > (64'hffff_ffff - digit) / base)
        return 0;
      parsed = parsed * base + digit;
    end
    value = int'(parsed);
    return 1;
  endfunction

  // 功能：parse_row 将一个数据行转换为完整类型化证据对象并校验坐标范围。
  // 输入输出及副作用：tokens 输入、row 输出；成功创建独立 row，不保留 tokens 引用。
  // 失败边界：列数不是 18、注释混入、坐标越界或数值非法时返回 0。
  static function bit parse_row(
      string tokens[$], output rdma_cmq_field_evidence_row row);
    row = null;
    if (tokens.size() != COLUMN_COUNT)
      return 0;
    foreach (tokens[i])
      if (tokens[i].len() == 0)
        return 0;
    row = rdma_cmq_field_evidence_row::type_id::create("cmq_evidence_row");
    row.case_id = tokens[0]; row.entry = tokens[1]; row.opcode = tokens[2];
    row.direction = tokens[3]; row.expected_class = tokens[7];
    row.expected_field = tokens[8]; row.evidence_mode = tokens[9];
    row.correlation_group = tokens[10]; row.driver_result_class = tokens[11];
    row.model_consumer = tokens[12]; row.expected_outcome = tokens[13];
    row.expected_status_code = tokens[14]; row.expected_ready = tokens[15];
    row.expected_value_delta = tokens[16]; row.oracle_case_id = tokens[17];
    if (!parse_uint(tokens[4], row.byte_offset) ||
        !parse_uint(tokens[5], row.qword_index) ||
        !parse_uint(tokens[6], row.bit_index)) begin
      row = null;
      return 0;
    end
    if ((row.direction != "REQUEST" && row.direction != "RESPONSE") ||
        (row.expected_class != "HOST_TYPED" &&
         row.expected_class != "HOST_FIXED" &&
         row.expected_class != "HW_TYPED" &&
         row.expected_class != "HW_OPAQUE" &&
         row.expected_class != "RESERVED_ZERO") ||
        (row.driver_result_class != "ENCODED" &&
         row.driver_result_class != "FIXED_ZERO" &&
         row.driver_result_class != "READY_OK" &&
         row.driver_result_class != "ECODE_ERROR" &&
         row.driver_result_class != "OPCODE_MISMATCH" &&
         row.driver_result_class != "REQUEST_LOOKUP_CHANGED" &&
         row.driver_result_class != "WRAP_MISMATCH" &&
         row.driver_result_class != "NOT_READY" &&
         row.driver_result_class != "STATIC_CANONICAL" &&
         row.driver_result_class != "STATIC_UNWRITABLE") ||
        (row.expected_outcome != "ACCEPT" &&
         row.expected_outcome != "REJECT" &&
         row.expected_outcome != "CANONICAL" &&
         row.expected_outcome != "READY" &&
         row.expected_outcome != "PUBLISH_ECODE" &&
         row.expected_outcome != "NOT_READY")) begin
      row = null;
      return 0;
    end
    if (row.byte_offset >= 64 || row.qword_index >= 8 || row.bit_index >= 64 ||
        row.byte_offset != row.qword_index * 8 + (7 - row.bit_index / 8)) begin
      row = null;
      return 0;
    end
    return 1;
  endfunction

  // 功能：read_all 读取并验证完整 mutation manifest，返回所有证据行及分类计数。
  // 输入输出及副作用：path 输入；rows 输出；文件以只读方式打开并在返回前关闭。
  // 失败边界：文件不可读、header 不匹配、重复坐标、分类计数不符或数据行带注释时返回 0。
  static function bit read_all(
      string path,
      output rdma_cmq_field_evidence_row rows[$],
      output string error);
    int fd;
    string line;
    string tokens[$];
    bit first;
    string seen[string];
    int typed, correlated, fixed, canonical, unwritable, raw;
    int request_qpc, response_qpc, doorbell;
    rdma_cmq_field_evidence_row row;
    string key;
    string expected_header = "case_id\tentry\topcode\tdirection\tbyte_offset\tqword_index\tbit_index\texpected_class\texpected_field\tevidence_mode\tcorrelation_group\tdriver_result_class\tmodel_consumer\texpected_outcome\texpected_status_code\texpected_ready\texpected_value_delta\toracle_case_id";
    rows.delete(); error = ""; first = 1;
    typed = 0; correlated = 0; fixed = 0;
    canonical = 0; unwritable = 0; raw = 0;
    request_qpc = 0; response_qpc = 0; doorbell = 0;
    fd = $fopen(path, "r");
    if (fd == 0) begin error = "cannot open mutation manifest"; return 0; end
    while (!$feof(fd)) begin
      if (!$fgets(line, fd)) break;
      if (line.len() > 0 && line.getc(0) == 8'h23) continue;
      if (line.len() > 0 && line.getc(line.len()-1) == 8'h0a)
        line = line.substr(0, line.len()-2);
      if (first) begin
        first = 0;
        if (line != expected_header ||
            !split_tab(line, tokens) || tokens.size() != COLUMN_COUNT) begin
          error = "invalid mutation header";
          $fclose(fd);
          return 0;
        end
        continue;
      end
      if (!split_tab(line, tokens)) begin
        error = "invalid empty row";
        $fclose(fd);
        return 0;
      end
      foreach (tokens[i])
        if (tokens[i].len() > 0 && tokens[i].getc(0) == 8'h23) begin
          error = "comment after data token";
          $fclose(fd);
          return 0;
        end
      if (!parse_row(tokens, row)) begin
        error = "malformed mutation row";
        $fclose(fd);
        return 0;
      end
      key = {row.case_id, ":", $sformatf("%0d", row.byte_offset), ":", $sformatf("%0d", row.bit_index)};
      if (seen.exists(key)) begin
        error = "duplicate case/coordinate";
        $fclose(fd);
        return 0;
      end
      seen[key] = "1"; rows.push_back(row);
      if (row.case_id == "cmq_sqe_qpc_create_request") request_qpc++;
      if (row.case_id == "cmq_cqe_qpc_create_response") response_qpc++;
      if (row.case_id == "cmq_sq_doorbell") doorbell++;
      case (row.evidence_mode)
        "TYPED_RECOMPOSE": typed++;
        "CORRELATED_RECOMPOSE": correlated++;
        "DRIVER_FIXED_REJECT": fixed++;
        "STATIC_CANONICAL": canonical++;
        "STATIC_UNWRITABLE": unwritable++;
        "RAW_DECODE_MUTATION": raw++;
        default: begin
          error = "unknown evidence mode";
          $fclose(fd);
          return 0;
        end
      endcase
    end
    $fclose(fd);
    if (first || rows.size() != 1088 || request_qpc != 512 ||
        response_qpc != 512 || doorbell != 64 || typed != 140 || correlated != 2 ||
        fixed != 12 || canonical != 9 || unwritable != 413 || raw != 512) begin
      error = "mutation manifest count mismatch"; return 0;
    end
    return 1;
  endfunction
endclass
