// 目录：测试层 support/rdma_golden_reader.sv。
// 职责：验证 rdma_golden_reader 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_golden_reader.sv 属于测试辅助工具，提供 golden、解析和断言支持。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_golden_case;
  string name;
  string inputs;
  int unsigned byte_count;
  byte unsigned payload[];
endclass

class rdma_golden_reader;
  localparam int unsigned MAX_PAYLOAD_BYTES = 512;

  // 功能：在 rdma_golden_reader 中，strip_canonical_newline 按 golden 文件格式解析/规范化字节或文本，得到稳定的比较输入。
  // 输入/输出及副作用：line（输入）、content（输出）、error（输出）；strip_canonical_newline 读取 line、content、error 并使用字段 length、content、error，并写入 content、error；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：strip_canonical_newline 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  static function bit strip_canonical_newline(
      string line,
      output string content,
      output string error);
    int length = line.len();

    content = "";
    if (length == 0 || line.getc(length - 1) != 8'h0a) begin
      error = "line is missing canonical LF terminator";
      return 0;
    end
    if (length > 1 && line.getc(length - 2) == 8'h0d) begin
      error = "CRLF is not canonical";
      return 0;
    end
    if (length > 1)
      content = line.substr(0, length - 2);
    return 1;
  endfunction

  // 功能：判断 is_lower_name_char 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：ch（输入）；is_lower_name_char 读取 ch 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：is_lower_name_char 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  static function bit is_lower_name_char(int ch);
    return ((ch >= 8'h61 && ch <= 8'h7a) ||
            (ch >= 8'h30 && ch <= 8'h39) || ch == 8'h5f);
  endfunction

  // 功能：判断 valid_case_name 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：name（输入）；valid_case_name 读取 name 并使用字段 index；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：valid_case_name 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  static function bit valid_case_name(string name);
    if (name.len() == 0)
      return 0;
    for (int index = 0; index < name.len(); index++) begin
      if (!is_lower_name_char(name.getc(index)))
        return 0;
    end
    return 1;
  endfunction

  // 功能：在 rdma_golden_reader 中，parse_case_line 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：line（输入）、name（输出）、error（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：parse_case_line 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  static function bit parse_case_line(
      string line,
      output string name,
      output string error);
    string content;

    name = "";
    error = "";
    if (!strip_canonical_newline(line, content, error))
      return 0;
    if (content.len() <= 8 || content.substr(0, 7) != "# case: ") begin
      error = "missing or malformed case name";
      return 0;
    end
    name = content.substr(8, content.len() - 1);
    if (!valid_case_name(name)) begin
      error = "case name must match [a-z0-9_]+";
      name = "";
      return 0;
    end
    return 1;
  endfunction

  // 功能：在 rdma_golden_reader 中，parse_inputs_line 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：line（输入）、inputs（输出）、error（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：parse_inputs_line 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  static function bit parse_inputs_line(
      string line,
      output string inputs,
      output string error);
    string content;
    string keys[$];
    int token_start;
    int equals_pos;

    inputs = "";
    error = "";
    if (!strip_canonical_newline(line, content, error))
      return 0;
    if (content.len() <= 10 || content.substr(0, 9) != "# inputs: ") begin
      error = "missing or malformed input summary";
      return 0;
    end
    inputs = content.substr(10, content.len() - 1);
    token_start = 0;
    equals_pos = -1;
    for (int index = 0; index <= inputs.len(); index++) begin
      int ch = (index < inputs.len()) ? inputs.getc(index) : 8'h2c;
      if (ch == 8'h2c) begin
        string key;
        if (equals_pos <= token_start || index <= equals_pos + 1) begin
          error = "input summary token must be key=value";
          inputs = "";
          return 0;
        end
        key = inputs.substr(token_start, equals_pos - 1);
        foreach (keys[key_index]) begin
          if (keys[key_index] == key) begin
            error = "duplicate input name";
            inputs = "";
            return 0;
          end
        end
        keys.push_back(key);
        token_start = index + 1;
        equals_pos = -1;
      end else if (ch == 8'h3d) begin
        if (equals_pos >= 0 || index == token_start ||
            inputs.getc(token_start) < 8'h61 ||
            inputs.getc(token_start) > 8'h7a) begin
          error = "malformed input name";
          inputs = "";
          return 0;
        end
        equals_pos = index;
      end else if (!is_lower_name_char(ch)) begin
        error = "input summary has a noncanonical character";
        inputs = "";
        return 0;
      end
    end
    return 1;
  endfunction

  // 功能：在 rdma_golden_reader 中，parse_byte_count_line 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：line（输入）、byte_count（输出）、error（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：parse_byte_count_line 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  static function bit parse_byte_count_line(
      string line,
      output int unsigned byte_count,
      output string error);
    string content;
    longint unsigned parsed;

    byte_count = 0;
    error = "";
    if (!strip_canonical_newline(line, content, error))
      return 0;
    if (content.len() <= 9 || content.substr(0, 8) != "# bytes: ") begin
      error = "missing or malformed byte count";
      return 0;
    end
    if (content.getc(9) < 8'h31 || content.getc(9) > 8'h39) begin
      error = "byte count must be a positive canonical decimal";
      return 0;
    end
    parsed = 0;
    for (int index = 9; index < content.len(); index++) begin
      int ch = content.getc(index);
      if (ch < 8'h30 || ch > 8'h39) begin
        error = "byte count contains a non-decimal character";
        return 0;
      end
      parsed = parsed * 10 + (ch - 8'h30);
      if (parsed > 32'hffff_ffff) begin
        error = "byte count overflows int unsigned";
        return 0;
      end
    end
    byte_count = int'(parsed);
    return 1;
  endfunction

  // 功能：在 rdma_golden_reader 中，lower_hex_nibble 按 golden 文件格式解析/规范化字节或文本，得到稳定的比较输入。
  // 输入/输出及副作用：ch（输入）、value（输出）；lower_hex_nibble 读取 ch、value 并使用字段 value，并写入 value；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：lower_hex_nibble 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  static function bit lower_hex_nibble(int ch, output int value);
    value = 0;
    if (ch >= 8'h30 && ch <= 8'h39) begin
      value = ch - 8'h30;
      return 1;
    end
    if (ch >= 8'h61 && ch <= 8'h66) begin
      value = ch - 8'h61 + 10;
      return 1;
    end
    return 0;
  endfunction

  // 功能：在 rdma_golden_reader 中，parse_payload_line 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：line（输入）、expected_bytes（输入）、payload（输出）、error（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached
  //   解码快照，不接管调用方缓冲区。
  // 失败/边界：parse_payload_line 先检查 expected_bytes == 0；expected_bytes > MAX_PAYLOAD_BYTES；!strip_canonical_newline(line, content, error，再返回 RDMA_SC_CODEC_ERROR；RDMA_SC_OK；拒绝分支不提交部分状态，也不隐式重试。
  static function rdma_status_code_e parse_payload_line(
      string line,
      int unsigned expected_bytes,
      output byte unsigned payload[],
      output string error);
    string content;
    longint unsigned encoded_length;

    payload.delete();
    error = "";
    if (expected_bytes == 0) begin
      error = "payload byte count must be positive";
      return RDMA_SC_CODEC_ERROR;
    end
    if (expected_bytes > MAX_PAYLOAD_BYTES) begin
      error = $sformatf("payload byte count %0d exceeds reader maximum %0d",
                        expected_bytes, MAX_PAYLOAD_BYTES);
      return RDMA_SC_CODEC_ERROR;
    end
    if (!strip_canonical_newline(line, content, error))
      return RDMA_SC_CODEC_ERROR;
    encoded_length = expected_bytes;
    encoded_length = encoded_length * 3 - 1;
    if (content.len() != encoded_length) begin
      error = $sformatf("payload text length does not encode %0d bytes",
                        expected_bytes);
      return RDMA_SC_CODEC_ERROR;
    end
    payload = new[expected_bytes];
    foreach (payload[index]) begin
      int high;
      int low;
      longint unsigned position = index;
      position = position * 3;
      if (!lower_hex_nibble(content.getc(position), high) ||
          !lower_hex_nibble(content.getc(position + 1), low)) begin
        error = "payload bytes must use exactly two lowercase hex digits";
        payload.delete();
        return RDMA_SC_CODEC_ERROR;
      end
      if (index + 1 < expected_bytes &&
          content.getc(position + 2) != 8'h20) begin
        error = "payload bytes must use one ASCII space separator";
        payload.delete();
        return RDMA_SC_CODEC_ERROR;
      end
      payload[index] = byte'((high << 4) | low);
    end
    return RDMA_SC_OK;
  endfunction

  // 功能：在 rdma_golden_reader 中，read_all 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：path（输入）、cases（输出）、error（输出）；read_all 读取 path、cases、error 并使用字段 error、state、fd、current、cases，并写入 cases、error；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：read_all 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  static function bit read_all(
      string path,
      output rdma_golden_case cases[$],
      output string error);
    int fd;
    int state;
    string line;
    string content;
    rdma_golden_case current;
    rdma_golden_case parsed_cases[$];

    cases.delete();
    error = "";
    state = 0;
    fd = $fopen(path, "r");
    if (fd == 0) begin
      error = $sformatf("cannot open %s", path);
      return 0;
    end

    while ($fgets(line, fd)) begin
      case (state)
        0: begin
          if (!strip_canonical_newline(line, content, error) ||
              content != "# xtr_v1-golden-v1") begin
            if (error == "")
              error = "missing or malformed format marker";
            $fclose(fd);
            return 0;
          end
          current = new();
          state = 1;
        end
        1: begin
          if (!parse_case_line(line, current.name, error)) begin
            $fclose(fd);
            return 0;
          end
          foreach (parsed_cases[index]) begin
            if (parsed_cases[index].name == current.name) begin
              error = $sformatf("duplicate case name %s", current.name);
              $fclose(fd);
              return 0;
            end
          end
          state = 2;
        end
        2: begin
          if (!parse_inputs_line(line, current.inputs, error)) begin
            $fclose(fd);
            return 0;
          end
          state = 3;
        end
        3: begin
          if (!parse_byte_count_line(line, current.byte_count, error)) begin
            $fclose(fd);
            return 0;
          end
          state = 4;
        end
        4: begin
          if (parse_payload_line(line, current.byte_count,
                                 current.payload, error) != RDMA_SC_OK) begin
            $fclose(fd);
            return 0;
          end
          parsed_cases.push_back(current);
          state = 5;
        end
        5: begin
          if (!strip_canonical_newline(line, content, error) || content != "") begin
            if (error == "")
              error = "golden cases require one blank separator";
            $fclose(fd);
            return 0;
          end
          state = 0;
        end
      endcase
    end
    $fclose(fd);
    if (state != 5) begin
      error = (state == 0 && parsed_cases.size() != 0)
              ? "trailing blank separator"
              : "incomplete trailing case";
      return 0;
    end
    if (parsed_cases.size() == 0) begin
      error = "golden file has no cases";
      return 0;
    end
    cases = parsed_cases;
    return 1;
  endfunction
endclass
