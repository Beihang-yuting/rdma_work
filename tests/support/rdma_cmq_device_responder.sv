// 目录：测试支撑层 support/rdma_cmq_device_responder.sv。
// 职责：CMQ 设备侧模型（mock PCIe）：收到 CMQ SQ doorbell 后按顺序读取新 SQE、校验 envelope 与 doorbell
//   PI/polarity，并在 CQ 写入完成（owner 按 CQ 圈数翻转）；可注入 ecode、错误 opcode/wrap、扣留或丢弃完成。
// 依赖：rdma_mock_pcie、rdma_mock_host_mem。
// 所有权与生命周期：只借用 host_mem 与 CMQ backing mapping；记录观测到的 SQE/doorbell 字段供测试断言。

class rdma_cmq_device_responder extends rdma_mock_pcie;
  `uvm_object_utils(rdma_cmq_device_responder)

  localparam longint unsigned CMQ_CQ_OFFSET = 64'd2048;
  localparam int unsigned CMQE_BYTES = 64;
  localparam int unsigned CMQ_DEPTH = 32;

  protected rdma_mock_host_mem host_mem;
  protected rdma_dma_mapping cmq_mapping;
  protected rdma_function_handle expected_function;
  protected rdma_bar_addr_t expected_doorbell_address;
  protected longint unsigned sq_sequence;
  protected longint unsigned cq_sequence;
  protected bit [63:0] held_qwords[$];

  // 故障注入：对下一条命令生效后自动清除（hold 持续到 release_held）。
  bit hold;
  bit drop_next;
  bit [7:0] next_ecode;
  bit override_next_opcode;
  bit [7:0] next_opcode;
  bit flip_next_wrap;

  bit [7:0] observed_opcodes[$];
  bit [63:0] observed_qword1[$];
  bit [4:0] observed_wqe_indices[$];
  bit observed_wqe_wraps[$];
  bit observed_cq_owners[$];
  int unsigned observed_doorbell_pis[$];
  bit observed_doorbell_polarities[$];

  // 功能：构造未配置的 responder。
  // 输入/输出及副作用：name 为 UVM 实例名。
  // 失败/边界：无。
  function new(string name = "rdma_cmq_device_responder");
    super.new(name);
    host_mem = null;
    cmq_mapping = null;
    expected_function = null;
    clear_faults();
  endfunction

  // 功能：绑定 host_mem、CMQ backing 与 Function，复位设备侧游标与观测记录。
  // 输入/输出及副作用：保存非拥有引用。
  // 失败/边界：依赖缺失或 mapping 不是 4KiB ACTIVE backing 时返回 INVALID_ARGUMENT。
  function rdma_status configure_responder(
    rdma_mock_host_mem host_mem_arg,
    rdma_dma_mapping cmq_mapping_arg,
    rdma_function_binding binding
  );
    host_mem = null;
    cmq_mapping = null;
    expected_function = null;
    if (host_mem_arg == null || cmq_mapping_arg == null || binding == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "CMQ responder authority is incomplete");
    if (cmq_mapping_arg.state != RDMA_MAPPING_ACTIVE || cmq_mapping_arg.size != 4096)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "CMQ responder mapping is invalid");
    host_mem = host_mem_arg;
    cmq_mapping = cmq_mapping_arg;
    expected_function = binding.make_handle();
    expected_doorbell_address.value = binding.notify_base.value + RDMA_DB_CMQ_OFFSET;
    observed_opcodes.delete();
    observed_qword1.delete();
    observed_wqe_indices.delete();
    observed_wqe_wraps.delete();
    observed_cq_owners.delete();
    observed_doorbell_pis.delete();
    observed_doorbell_polarities.delete();
    held_qwords.delete();
    sq_sequence = 0;
    cq_sequence = 0;
    clear_faults();
    return rdma_status::success();
  endfunction

  // 功能：清除全部故障注入设置。
  // 输入/输出及副作用：修改注入字段。
  // 失败/边界：无。
  function void clear_faults();
    hold = 1'b0;
    drop_next = 1'b0;
    next_ecode = '0;
    override_next_opcode = 1'b0;
    next_opcode = '0;
    flip_next_wrap = 1'b0;
  endfunction

  // 功能：结束扣留模式，按序写出全部扣留的完成。
  // 输入/输出及副作用：写 CQ backing。
  // 失败/边界：写失败返回其 status。
  function rdma_status release_held();
    rdma_status status;

    hold = 1'b0;
    status = rdma_status::success();
    while (held_qwords.size() != 0 && status.ok())
      status = write_cqe(held_qwords.pop_front());
    return status;
  endfunction

  // 功能：被扣留的完成数。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function int unsigned held_count();
    return held_qwords.size();
  endfunction

  // 功能：取 8 字节大端 qword。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：不足 8 字节返回 0。
  protected function bit [63:0] be_qword(byte data[], int unsigned base = 0);
    bit [63:0] value;

    value = '0;
    if (data.size() < base + 8)
      return value;
    for (int unsigned i = 0; i < 8; i++)
      value = {value[55:0], data[base + i]};
    return value;
  endfunction

  // 功能：在下一个 CQ 槽写入以 qword0 为首的完成（其余字节为 0），owner 按 CQ 圈数取值。
  // 输入/输出及副作用：写 CQ backing，推进 cq_sequence。
  // 失败/边界：写失败返回其 status。
  protected function rdma_status write_cqe(bit [63:0] qword0);
    byte data[];
    rdma_status status;

    qword0[63] = !((cq_sequence / CMQ_DEPTH) & 1'b1);
    data = new[CMQE_BYTES];
    foreach (data[i])
      data[i] = 0;
    for (int unsigned i = 0; i < 8; i++)
      data[i] = qword0[63 - (i * 8) -: 8];
    status = host_mem.write(cmq_mapping,
                            CMQ_CQ_OFFSET + (cq_sequence % CMQ_DEPTH) * CMQE_BYTES, data);
    if (status != null && status.ok()) begin
      observed_cq_owners.push_back(qword0[63]);
      cq_sequence++;
    end
    return status;
  endfunction

  // 功能：处理 CMQ doorbell：校验 PI/polarity 按序推进，读取并校验新 SQE（valid=!wrap、index/wrap 与设备
  //   游标一致），按注入设置生成完成（或扣留/丢弃）。
  // 输入/输出及副作用：读 SQ、写 CQ，记录观测字段。
  // 失败/边界：非本 Function 的 CMQ doorbell、乱序 doorbell 或非法 SQE envelope 返回错误。
  virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );
    byte sqe_data[];
    bit [63:0] doorbell;
    bit [63:0] sqe;
    bit [63:0] cqe;

    super.mmio_write(function_h, address, data, status);
    if (status == null || !status.ok())
      return;
    if (host_mem == null || cmq_mapping == null || expected_function == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "CMQ responder is not configured");
      return;
    end
    if (function_h == null || !function_h.same_instance(expected_function) ||
        address != expected_doorbell_address || data.size() != 8) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "CMQ responder saw a non-CMQ doorbell");
      return;
    end
    doorbell = be_qword(data);
    if (doorbell[36:32] != (sq_sequence + 1) % CMQ_DEPTH ||
        doorbell[37] != (((sq_sequence + 1) / CMQ_DEPTH) & 1'b1)) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "CMQ SQ doorbell did not advance in order");
      return;
    end
    status = host_mem.read(cmq_mapping, (sq_sequence % CMQ_DEPTH) * CMQE_BYTES, CMQE_BYTES,
                           sqe_data);
    if (status == null || !status.ok())
      return;
    sqe = be_qword(sqe_data);
    if (sqe[63] != !sqe[45] || sqe[44:40] != sq_sequence % CMQ_DEPTH ||
        sqe[45] != ((sq_sequence / CMQ_DEPTH) & 1'b1)) begin
      status = rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "CMQ responder decoded an invalid SQE envelope");
      return;
    end
    observed_opcodes.push_back(sqe[39:32]);
    observed_qword1.push_back(be_qword(sqe_data, 8));
    observed_wqe_indices.push_back(sqe[44:40]);
    observed_wqe_wraps.push_back(sqe[45]);
    observed_doorbell_pis.push_back(doorbell[36:32]);
    observed_doorbell_polarities.push_back(doorbell[37]);
    sq_sequence++;
    cqe = '0;
    cqe[45] = sqe[45] ^ flip_next_wrap;
    cqe[44:40] = sqe[44:40];
    cqe[39:32] = override_next_opcode ? next_opcode : sqe[39:32];
    cqe[RDMA_CMQ_CMD_ECODE_LSB +: 8] = next_ecode;
    flip_next_wrap = 1'b0;
    override_next_opcode = 1'b0;
    next_ecode = '0;
    if (drop_next) begin
      drop_next = 1'b0;
      return;
    end
    if (hold) begin
      held_qwords.push_back(cqe);
      return;
    end
    status = write_cqe(cqe);
  endtask
endclass
