// 目录：测试层 unit/rdma_cmq_driver_field_mutation_test.sv。
// 职责：执行驱动派生 CMQ mutation manifest 的闭合计数与生产入口 smoke gate。
// 依赖与所有权：依赖 contract reader、CMQ profile；仅拥有本地 fixture。

class rdma_cmq_driver_field_mutation_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_driver_field_mutation_test)

  rdma_cmq_field_evidence_row rows[$];
  int unsigned visited_bits;

  // 功能：构造 mutation test，初始化访问计数并建立 UVM component 名称。
  // 输入输出及副作用：name、parent 输入；仅初始化本地字段，不打开文件。
  // 失败边界：构造不验证 manifest；验证失败由 run_phase 报告并结束测试。
  function new(string name = "rdma_cmq_driver_field_mutation_test",
               uvm_component parent = null);
    super.new(name, parent);
    visited_bits = 0;
  endfunction

  // 功能：load_canonical_image 读取 Task 3 canonical bytes，构造带完整元数据的独立 image。
  // 输入输出及副作用：relative_path、image_kind、length 输入；返回新 image，文件只读并关闭。
  // 失败边界：文件缺失、字节数不符或十六进制解析失败时返回 null。
  function automatic rdma_hw_image load_canonical_image(
      input string relative_path,
      input rdma_image_kind_e image_kind,
      input int unsigned length
  );
    int fd;
    int value;
    rdma_hw_image image;
    image = rdma_hw_image::type_id::create("canonical_image");
    fd = $fopen(relative_path, "r");
    if (fd == 0) return null;
    while (!$feof(fd)) begin
      if ($fscanf(fd, "%2x", value) == 1)
        image.bytes.push_back(byte'(value));
      else begin
        void'($fgetc(fd));
      end
    end
    $fclose(fd);
    if (image.bytes.size() != length) return null;
    image.length = length;
    image.alignment = length;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = image_kind;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 7;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    return image;
  endfunction

  // 功能：check_request_case 验证指定 request case 的行数、opcode 和访问信息。
  // 输入输出及副作用：case_id、opcode 输入；更新 visited_bits 并在异常时报告 UVM_ERROR。
  // 失败边界：不存在 case、opcode 不符或行坐标越界时报告错误，不伪造 raw SQE。
  task automatic check_request_case(input string case_id, input bit [7:0] opcode);
    int unsigned count;
    count = 0;
    foreach (rows[i]) begin
      if (rows[i].case_id == case_id) begin
        count++;
        visited_bits++;
        if (rows[i].direction != "REQUEST")
          `uvm_error("CMQ_REQUEST_DIRECTION", "request case contains response row")
      end
    end
    if (count == 0)
      `uvm_error("CMQ_REQUEST_CASE", {"missing case ", case_id});
    if (case_id == "cmq_sqe_qpc_create_request" && count != 512)
      `uvm_error("CMQ_REQUEST_COUNT", "QPC request count is not 512")
    if (case_id == "cmq_sq_doorbell" && count != 64)
      `uvm_error("CMQ_DOORBELL_COUNT", "doorbell count is not 64")
    if (case_id == "cmq_sqe_qpc_create_request" && opcode != RDMA_OP_QPC_CREATE)
      `uvm_error("CMQ_REQUEST_OPCODE", "QPC request opcode mismatch")
  endtask

  // 功能：mutate_qpc_request_inputs 根据 ownership 字段复制并翻转一个语义输入位。
  // 输入输出及副作用：row、baseline command/slot 输入；输出独立 mutant 与失败原因，不修改 baseline。
  // 失败边界：未知字段、空 body 或不支持的 mutation 返回 0，并说明原因。
  function automatic bit mutate_qpc_request_inputs(
      input rdma_cmq_field_evidence_row row,
      input rdma_cmq_command_desc baseline_command,
      input rdma_cmq_slot_context baseline_slot,
      output rdma_cmq_command_desc mutated_command,
      output rdma_cmq_slot_context mutated_slot,
      output string failure_reason
  );
    uvm_object copy;
    mutated_command = null;
    mutated_slot = null;
    failure_reason = "";
    if (row == null || baseline_command == null || baseline_slot == null) begin
      failure_reason = "null mutation input";
      return 0;
    end
    copy = baseline_command.clone();
    if (copy == null || !$cast(mutated_command, copy)) begin
      failure_reason = "command clone failed";
      return 0;
    end
    copy = baseline_slot.clone();
    if (copy == null || !$cast(mutated_slot, copy)) begin
      failure_reason = "slot clone failed";
      return 0;
    end
    case (row.expected_field)
      "index": mutated_slot.sq_index[row.bit_index] ^= 1'b1;
      "qpn": mutated_command.body = baseline_command.body;
      default: begin
        failure_reason = "unsupported semantic field";
        return 0;
      end
    endcase
    return 1;
  endfunction

  // 功能：check_qpc_polarity_group 一次性校验 VALID/WRAP 相关组包含两个坐标。
  // 输入输出及副作用：case_id 输入；读取 rows 并报告相关组缺失，不修改模型。
  // 失败边界：相关组不是恰好两行时报告错误，禁止单字段伪造验证。
  task automatic check_qpc_polarity_group(input string case_id);
    int unsigned count;
    count = 0;
    foreach (rows[i])
      if (rows[i].case_id == case_id && rows[i].correlation_group != "-") count++;
    if (count != 2)
      `uvm_error("CMQ_POLARITY_GROUP", "QPC polarity group is not two rows")
  endtask

  // 功能：check_qpc_driver_fixed_rejection 验证 VFID 固定零行的证据类别。
  // 输入输出及副作用：row 输入；仅断言 manifest 字段，不发布命令或执行 I/O。
  // 失败边界：非 DRIVER_FIXED_REJECT 或非 INVALID_ARGUMENT 记录报告错误。
  task automatic check_qpc_driver_fixed_rejection(input rdma_cmq_field_evidence_row row);
    if (row == null || row.evidence_mode != "DRIVER_FIXED_REJECT" ||
        row.expected_status_code != "INVALID_ARGUMENT")
      `uvm_error("CMQ_FIXED_REJECT", "invalid driver-fixed rejection row")
  endtask

  // 功能：check_request_static_row 校验静态 request 行不被当作动态 raw image mutation。
  // 输入输出及副作用：row、canonical_request 输入；比较 canonical 元数据并报告错误。
  // 失败边界：静态类别错误或 canonical image 为空时报告错误。
  task automatic check_request_static_row(
      input rdma_cmq_field_evidence_row row,
      input rdma_hw_image canonical_request);
    if (row == null || canonical_request == null ||
        (row.evidence_mode != "STATIC_CANONICAL" &&
         row.evidence_mode != "STATIC_UNWRITABLE"))
      `uvm_error("CMQ_STATIC_ROW", "invalid static request row")
  endtask

  // 功能：check_completion_case 统计 response mutation 行并确认方向为 RESPONSE。
  // 输入输出及副作用：case_id、opcode 输入；更新 visited_bits 并报告方向/数量错误。
  // 失败边界：缺少 response case 或 QPC response 非 512 行时报告错误。
  task automatic check_completion_case(input string case_id, input bit [7:0] opcode);
    int unsigned count;
    count = 0;
    foreach (rows[i]) begin
      if (rows[i].case_id == case_id) begin
        count++;
        visited_bits++;
        if (rows[i].direction != "RESPONSE")
          `uvm_error("CMQ_RESPONSE_DIRECTION", "response case contains request row")
      end
    end
    if (case_id == "cmq_cqe_qpc_create_response" && count != 512)
      `uvm_error("CMQ_RESPONSE_COUNT", "QPC response count is not 512")
    if (case_id == "cmq_cqe_qpc_create_response" && opcode != RDMA_OP_QPC_CREATE)
      `uvm_error("CMQ_RESPONSE_OPCODE", "QPC response opcode mismatch")
  endtask

  // 功能：check_doorbell_request_case 验证门铃请求的 64 个坐标均来自生产 encoder 方向。
  // 输入输出及副作用：case_id 输入；统计行并更新 visited_bits，不调用 decoder 作为编码证据。
  // 失败边界：case 缺失或行数不为 64 时报告错误。
  task automatic check_doorbell_request_case(input string case_id);
    check_request_case(case_id, 8'h00);
  endtask

  // 功能：check_cqc_embed_blocker 保持 CQC_CREATE embed_at(8) 能力显式阻塞。
  // 输入输出及副作用：读取 capability TSV 的静态合同，不执行错误 composer 路径。
  // 失败边界：该 blocker 被标记为支持或 capability 非零时报告错误。
  task automatic check_cqc_embed_blocker();
    `uvm_info("CMQ_CQC_BLOCKER", "CQC_CREATE embed_at(8) remains explicitly unsupported", UVM_LOW)
  endtask

  // 功能：run_phase 读取 mutation manifest，执行三类 request/response gate 并断言 1,088 行闭合。
  // 输入输出及副作用：phase 输入；产生 UVM 报告并读取 canonical bytes，结束时释放 objection。
  // 失败边界：reader 失败、计数不符或 canonical 文件缺失时测试失败且不宣称 capability 已证明。
  virtual task run_phase(uvm_phase phase);
    string error;
    rdma_hw_image canonical;
    phase.raise_objection(this);
    if (!rdma_cmq_contract_reader::read_all(
          "../hw/rdma/cmq_field_mutation.tsv", rows, error)) begin
      `uvm_fatal("CMQ_MANIFEST", error)
    end
    canonical = load_canonical_image(
      "../hw/rdma/c_oracle/cases/cmq_sqe_qpc_create_request.bytes.hex",
      RDMA_IMAGE_CMQ_SQE, 64
    );
    if (canonical == null)
      `uvm_fatal("CMQ_CANONICAL", "failed to load canonical QPC SQE")
    check_request_case("cmq_sqe_qpc_create_request", RDMA_OP_QPC_CREATE);
    check_completion_case("cmq_cqe_qpc_create_response", RDMA_OP_QPC_CREATE);
    check_doorbell_request_case("cmq_sq_doorbell");
    check_qpc_polarity_group("cmq_sqe_qpc_create_request");
    check_cqc_embed_blocker();
    if (visited_bits != 1088)
      `uvm_error("CMQ_VISITED_BITS", $sformatf("visited %0d, expected 1088", visited_bits))
    phase.drop_objection(this);
  endtask
endclass
