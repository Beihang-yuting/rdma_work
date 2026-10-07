// 目录：单元测试层 tests/unit/rdma_dev_cmq_test.sv。
// 职责：验证设备侧 CMQ 消费者 rdma_dev_cmq：CMQC 配置、doorbell 批处理与回绕、CQE envelope/owner，
//   以及 QP/MR/CQ/EQ/SRQ context 的创建、修改、查询、删除效果和协议错误拒绝。
//   SQE 按驱动 cmq.c 的字段布局直接构造（驱动编码本身由 CMQ golden 门禁保证）。
// 依赖：rdma_dev_cmq、rdma_host_mem（外部 host_mem）。
// 所有权与生命周期：测试拥有主机内存、缓冲与设备实例，随测试结束释放。
class rdma_dev_cmq_test extends uvm_test;
  `uvm_component_utils(rdma_dev_cmq_test)

  localparam int unsigned DEPTH = 32;
  localparam int unsigned CQ_OFFSET = DEPTH * 64;

  rdma_host_mem mem;
  rdma_dev_cmq dev;
  bit [63:0] ring;
  bit [63:0] qpc_buf;
  longint unsigned posted;
  // 丢弃型调用的 CQE 接收变量（VCS 对 void'() 丢弃动态数组返回值会崩溃）。
  rdma_bytes_t scratch;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传给 uvm_test。
  // 失败/边界：无。
  function new(string name = "rdma_dev_cmq_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：依次执行全部用例。
  // 输入/输出及副作用：持有 objection 直到用例结束。
  // 失败/边界：用例内部以 UVM_ERROR/FATAL 报告失败。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    setup();
    `uvm_info("DEV_CMQ", "check_envelope_and_wrap();", UVM_LOW)
    check_envelope_and_wrap();
    `uvm_info("DEV_CMQ", "check_qp();", UVM_LOW)
    check_qp();
    `uvm_info("DEV_CMQ", "check_mr();", UVM_LOW)
    check_mr();
    `uvm_info("DEV_CMQ", "check_cq_eq_srq();", UVM_LOW)
    check_cq_eq_srq();
    `uvm_info("DEV_CMQ", "check_errors();", UVM_LOW)
    check_errors();
    phase.drop_objection(this);
  endtask

  // 功能：分配 CMQ 环（4KiB）与 QPC 缓冲区（512B 对齐），配置并使能设备 CMQ。
  // 输入/输出及副作用：创建 mem/dev/ring/qpc_buf。
  // 失败/边界：任一步失败报告 UVM_FATAL。
  task setup();
    rdma_host_mems mems;

    mems = rdma_host_mems::type_id::create("dev_cmq_mems");
    mem = mems.make(0, "dev_cmq_mem");
    dev = rdma_dev_cmq::type_id::create("dev_cmq");
    ring = alloc(4096, 4096);
    qpc_buf = alloc(512, 512);
    dev.configure(mem);
    enable();
  endtask

  // 功能：从主机内存分配一段 DMA 缓冲。
  // 输入/输出及副作用：返回 IOVA。
  // 失败/边界：分配失败报告 UVM_FATAL。
  function bit [63:0] alloc(int unsigned size, int unsigned align);
    bit [63:0] iova;

    expect_ok("allocate", mem.alloc(size, align, iova));
    return iova;
  endfunction

  // 功能：按驱动 xtrdma_sc_cmq_create 写 CMQC_HIGH/LOW，并清零环与本地序号。
  // 输入/输出及副作用：写 ring 与设备寄存器，posted 归零。
  // 失败/边界：寄存器写失败报告 UVM_FATAL。
  task enable();
    byte zero[];
    rdma_status status;

    zero = new[4096];
    foreach (zero[i])
      zero[i] = 0;
    expect_ok("clear ring", mem.write(ring, zero));
    posted = 0;
    dev.write_register(RDMA_DB_CMQC_HIGH_OFFSET, ring, status);
    expect_ok("CMQC_HIGH", status);
    dev.write_register(RDMA_DB_CMQC_LOW_OFFSET, 64'h8000_0000, status);
    expect_ok("CMQC_LOW", status);
  endtask

  // 功能：断言 status 成功。
  // 输入/输出及副作用：what 用于报告。
  // 失败/边界：null 或失败时报告 UVM_FATAL。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("DEV_CMQ", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：新建 64B SQE 并写 qword0 的 opcode 与低位对象号。
  // 输入/输出及副作用：返回新数组。
  // 失败/边界：无。
  function rdma_bytes_t make_sqe(bit [7:0] opcode, bit [63:0] low_fields = 0);
    rdma_bytes_t sqe;

    sqe = new[64];
    foreach (sqe[i])
      sqe[i] = 0;
    rdma_be::put_qword(sqe, 0, low_fields | (64'(opcode) << RDMA_CMQ_OPCODE_LSB));
    return sqe;
  endfunction

  // 功能：提交一条不带签名的 SQE。
  // 输入/输出及副作用：写 ring 下一个槽，posted 加 1。
  // 失败/边界：同 post_signed。
  function void post(rdma_bytes_t sqe);
    rdma_bytes_t none;

    post_signed(sqe, 1'b0, none);
  endfunction

  // 功能：补 envelope（VALID=polarity、WRAP=!polarity、INDEX），可选按驱动规则计算 QPC 签名后写入环。
  // 输入/输出及副作用：sqe 为副本；写 ring，posted 加 1。
  // 失败/边界：内存写失败报告 UVM_FATAL。
  function void post_signed(rdma_bytes_t sqe, bit sign, rdma_bytes_t qpc);
    bit [63:0] word0;
    bit lap;
    bit [7:0] sum;
    byte data[];

    lap = (posted / DEPTH) & 1;
    word0 = rdma_be::qword(sqe, 0);
    word0[RDMA_CMQ_VALID_LSB] = !lap;
    word0[RDMA_CMQ_WRAP_LSB] = lap;
    word0[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH] = posted % DEPTH;
    rdma_be::put_qword(sqe, 0, word0);
    if (sign) begin
      rdma_be::set_field(sqe, RDMA_CMQ_SIGN_EN_WORD_BYTE_OFFSET, RDMA_CMQ_SIGN_EN_LSB, 1, 1);
      rdma_be::set_field(sqe, RDMA_CMQ_SIGNATURE_WORD_BYTE_OFFSET, RDMA_CMQ_SIGNATURE_LSB,
                              8, 0);
      sum = rdma_be::xor_bytes(sqe) ^ rdma_be::xor_bytes(qpc);
      rdma_be::set_field(sqe, RDMA_CMQ_SIGNATURE_WORD_BYTE_OFFSET, RDMA_CMQ_SIGNATURE_LSB,
                              8, ~sum);
    end
    data = new[64];
    foreach (data[i])
      data[i] = sqe[i];
    expect_ok("write SQE", mem.write(ring + (posted % DEPTH) * 64, data));
    posted++;
  endfunction

  // 功能：按驱动 xtrdma_sc_cmq_post_sq 敲 doorbell，PI/polarity 取自已提交序号。
  // 输入/输出及副作用：status 输出设备处理结果。
  // 失败/边界：设备拒绝时输出其错误。
  task ring_doorbell(output rdma_status status);
    bit [63:0] value;

    value = '0;
    value[RDMA_CMQ_DB_PI_LSB +: RDMA_CMQ_DB_PI_WIDTH] = posted % DEPTH;
    value[RDMA_CMQ_DB_POLARITY_LSB] = (posted / DEPTH) & 1;
    dev.write_register(RDMA_DB_CMQ_OFFSET, value, status);
  endtask

  // 功能：读第 seq 个 CQE 并检查 owner/wrap/index/opcode/ecode。
  // 输入/输出及副作用：返回 CQE 字节。
  // 失败/边界：字段不符报告 UVM_ERROR。
  function rdma_bytes_t check_cqe(string label, longint unsigned seq, bit [7:0] opcode,
                                      bit [7:0] ecode);
    byte data[];
    rdma_bytes_t cqe;
    bit [63:0] head;

    expect_ok("read CQE", mem.read(ring + CQ_OFFSET + (seq % DEPTH) * 64, 64, data));
    cqe = new[64];
    foreach (cqe[i])
      cqe[i] = data[i];
    head = rdma_be::qword(cqe, 0);
    if (head[RDMA_CMQ_VALID_LSB] != !((seq / DEPTH) & 1) ||
        head[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH] != seq % DEPTH ||
        head[RDMA_CMQ_WRAP_LSB] != ((seq / DEPTH) & 1) ||
        head[RDMA_CMQ_OPCODE_LSB +: 8] != opcode || head[RDMA_CMQ_CMD_ECODE_LSB +: 8] != ecode)
      `uvm_error(label, $sformatf("CQE %0d head %016h: opcode %02h ecode %02h expected",
                                  seq, head, opcode, ecode))
    return cqe;
  endfunction

  // 功能：提交单条命令、敲 doorbell 并检查其 CQE。
  // 输入/输出及副作用：cqe 输出 CQE 字节。
  // 失败/边界：doorbell 失败报告 UVM_FATAL，CQE 不符报告 UVM_ERROR。
  task exec(string label, rdma_bytes_t sqe, output rdma_bytes_t cqe,
            input bit [7:0] ecode = RDMA_CMQ_SUCCESS_ECODE);
    bit [7:0] opcode;
    rdma_status status;

    opcode = rdma_be::qword(sqe, 0) >> RDMA_CMQ_OPCODE_LSB;
    post(sqe);
    ring_doorbell(status);
    expect_ok({label, " doorbell"}, status);
    cqe = check_cqe(label, posted - 1, opcode, ecode);
  endtask

  // 功能：比较两段字节。
  // 输入/输出及副作用：只读。
  // 失败/边界：首个差异报告 UVM_ERROR。
  function void expect_bytes(string label, rdma_bytes_t got, int unsigned got_offset,
                             rdma_bytes_t want, int unsigned want_offset, int unsigned size);
    for (int unsigned i = 0; i < size; i++)
      if (got[got_offset + i] != want[want_offset + i]) begin
        `uvm_error(label, $sformatf("byte %0d: %02h != %02h", i, got[got_offset + i],
                                    want[want_offset + i]))
        return;
      end
  endfunction

  // 功能：批量 doorbell 与跨圈回绕：40 条 TQ_FLUSH，CQE owner 随圈翻转。
  // 输入/输出及副作用：推进设备与 ring。
  // 失败/边界：任一 CQE 或执行计数不符报告 UVM_ERROR。
  task check_envelope_and_wrap();
    rdma_status status;
    for (int i = 0; i < 3; i++)
      post(make_sqe(RDMA_OP_TQ_FLUSH));
    ring_doorbell(status);
    expect_ok("batch doorbell", status);
    for (int i = 0; i < 3; i++)
      scratch = (check_cqe("BATCH", i, RDMA_OP_TQ_FLUSH, RDMA_CMQ_SUCCESS_ECODE));
    for (int i = 0; i < 37; i++)
      exec("WRAP", make_sqe(RDMA_OP_TQ_FLUSH), scratch);
    if (dev.executed_opcodes.size() != 40)
      `uvm_error("WRAP", $sformatf("executed %0d commands", dev.executed_opcodes.size()))
  endtask

  // 功能：QP：CREATE 取缓冲区 QPC 并校验签名；仅状态/部分 MODIFY；QUERY 写回缓冲区；DELETE。
  // 输入/输出及副作用：修改 qpc_buf 与设备 QP 表。
  // 失败/边界：字节或状态不符报告 UVM_ERROR。
  task check_qp();
    rdma_status status;
    rdma_bytes_t qpc;
    rdma_bytes_t sqe;
    rdma_dev_object obj;
    byte data[];
    bit [63:0] layout;

    qpc = new[512];
    data = new[512];
    foreach (qpc[i]) begin
      qpc[i] = i * 7 + 3;
      data[i] = qpc[i];
    end
    expect_ok("write QPC", mem.write(qpc_buf, data));
    sqe = make_sqe(RDMA_OP_QPC_CREATE, 5);
    rdma_be::set_field(sqe, RDMA_CMQ_QPC_BUFFER_ADDR_WORD_BYTE_OFFSET,
                            RDMA_CMQ_QPC_BUFFER_ADDR_LSB, RDMA_CMQ_QPC_BUFFER_ADDR_WIDTH,
                            qpc_buf >> 9);
    post_signed(sqe, 1'b1, qpc);
    ring_doorbell(status);
    expect_ok("QPC_CREATE doorbell", status);
    scratch = (check_cqe("QPC_CREATE", posted - 1, RDMA_OP_QPC_CREATE, RDMA_CMQ_SUCCESS_ECODE));
    if (!dev.lookup(RDMA_DEV_QP, 5, obj))
      `uvm_fatal("QPC_CREATE", "QP 5 was not stored")
    expect_bytes("QPC_CREATE", obj.bytes, 0, qpc, 0, 512);

    sqe = make_sqe(RDMA_OP_QPC_MODIFY, 5);
    rdma_be::set_field(sqe, RDMA_CMQ_NEXT_QP_STATE_WORD_BYTE_OFFSET,
                            RDMA_CMQ_NEXT_QP_STATE_LSB, RDMA_CMQ_NEXT_QP_STATE_WIDTH, 3);
    exec("QPC_MODIFY_ST", sqe, scratch);
    if (rdma_be::field(obj.bytes, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET, RDMA_QPC_QP_ST_LSB,
                            RDMA_QPC_QP_ST_WIDTH) != 3)
      `uvm_error("QPC_MODIFY_ST", "QPC state field was not updated")

    sqe = make_sqe(RDMA_OP_QPC_MODIFY, 5);
    layout = '0;
    layout[RDMA_CMQ_MODIFY_MODE_LSB +: 2] = 2;
    layout[RDMA_CMQ_MODIFY_START_QWORD0_LSB +: 6] = 2;
    layout[RDMA_CMQ_MODIFY_WBE0_LSB +: 8] = 8'b1000_0011;
    rdma_be::put_qword(sqe, RDMA_CMQ_MODIFY_MODE_WORD_BYTE_OFFSET, layout);
    rdma_be::put_qword(sqe, RDMA_CMQ_MODIFY_DATA0_WORD_BYTE_OFFSET, 64'h1122_3344_5566_7788);
    exec("QPC_MODIFY_PARTIAL", sqe, scratch);
    if (obj.bytes[16] != 8'h11 || obj.bytes[22] != 8'h77 || obj.bytes[23] != 8'h88 ||
        obj.bytes[17] != qpc[17])
      `uvm_error("QPC_MODIFY_PARTIAL", "partial template was not applied by byte enable")

    foreach (data[i])
      data[i] = 0;
    expect_ok("clear QPC buffer", mem.write(qpc_buf, data));
    sqe = make_sqe(RDMA_OP_QPC_QUERY, 5);
    rdma_be::set_field(sqe, RDMA_CMQ_QPC_BUFFER_ADDR_WORD_BYTE_OFFSET,
                            RDMA_CMQ_QPC_BUFFER_ADDR_LSB, RDMA_CMQ_QPC_BUFFER_ADDR_WIDTH,
                            qpc_buf >> 9);
    exec("QPC_QUERY", sqe, scratch);
    expect_ok("read QPC buffer", mem.read(qpc_buf, 512, data));
    foreach (data[i])
      if (byte'(obj.bytes[i]) != data[i]) begin
        `uvm_error("QPC_QUERY", $sformatf("buffer byte %0d differs from the device QPC", i))
        break;
      end

    exec("QPC_DELETE", make_sqe(RDMA_OP_QPC_DELETE, 5), scratch);
    if (dev.count(RDMA_DEV_QP) != 0)
      `uvm_error("QPC_DELETE", "QP 5 is still stored")
  endtask

  // 功能：MR：REGISTER 保存 MRT，KEY_QUERY 回填 CQE 字节 16..63，DEREGISTER(INVALID) 删除。
  // 输入/输出及副作用：修改设备 MR 表。
  // 失败/边界：回填或删除不符报告 UVM_ERROR。
  task check_mr();
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;

    sqe = make_sqe(RDMA_OP_MR_REGISTER, 24'h42);
    for (int i = 8; i < 64; i++)
      sqe[i] = 8'h40 + i;
    exec("MR_REGISTER", sqe, scratch);
    exec("KEY_QUERY", make_sqe(RDMA_OP_KEY_QUERY, 24'h42), cqe);
    expect_bytes("KEY_QUERY", cqe, 16, sqe, 16, 48);
    exec("MR_DEREGISTER", make_sqe(RDMA_OP_MR_DEREGISTER, 24'h42), scratch);
    if (dev.count(RDMA_DEV_MR) != 0)
      `uvm_error("MR_DEREGISTER", "MR 0x42 is still stored")
  endtask

  // 功能：CQ/CEQ/AEQ/SRFQ：CREATE 保存 context，QUERY 按驱动偏移回填，DELETE 后查询得到 INVLD。
  // 输入/输出及副作用：修改设备 CQ/EQ/SRQ 表。
  // 失败/边界：回填、ecode 或删除不符报告 UVM_ERROR。
  task check_cq_eq_srq();
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;

    sqe = make_sqe(RDMA_OP_CQC_CREATE, 7);
    for (int i = 8; i < 64; i++)
      sqe[i] = 8'h80 + i;
    exec("CQC_CREATE", sqe, scratch);
    exec("CQC_QUERY", make_sqe(RDMA_OP_CQC_QUERY, 7), cqe);
    expect_bytes("CQC_QUERY", cqe, 8, sqe, 8, 56);
    exec("CQC_RESIZE", make_sqe(RDMA_OP_CQC_RESIZE, 7), scratch);
    exec("CQC_DELETE", make_sqe(RDMA_OP_CQC_DELETE, 7), scratch);
    exec("CQC_QUERY_GONE", make_sqe(RDMA_OP_CQC_QUERY, 7), scratch,
         RDMA_ECODE_EC_RCE_CQC_INVLD);

    sqe = make_sqe(RDMA_OP_CEQC_CREATE, 3);
    for (int i = 16; i < 48; i++)
      sqe[i] = 8'hc0 + i;
    exec("CEQC_CREATE", sqe, scratch);
    exec("CEQC_QUERY", make_sqe(RDMA_OP_CEQC_QUERY, 3), cqe);
    expect_bytes("CEQC_QUERY", cqe, 16, sqe, 16, 32);
    if (rdma_be::field(cqe, 0, 0, 12) != 3)
      `uvm_error("CEQC_QUERY", "CQE does not carry the EQN")
    exec("CEQC_DELETE", make_sqe(RDMA_OP_CEQC_DELETE, 3), scratch);
    exec("AEQC_DELETE_GONE", make_sqe(RDMA_OP_AEQC_DELETE, 1), scratch,
         RDMA_ECODE_EC_RCE_AEQC_INVLD);

    sqe = make_sqe(RDMA_OP_SRFQC_CREATE, 9);
    for (int i = 16; i < 48; i++)
      sqe[i] = 8'h20 + i;
    exec("SRFQC_CREATE", sqe, scratch);
    exec("SRFQC_QUERY", make_sqe(RDMA_OP_SRFQC_QUERY, 9), cqe);
    expect_bytes("SRFQC_QUERY", cqe, 16, sqe, 16, 32);
    exec("SRFQC_DELETE", make_sqe(RDMA_OP_SRFQC_DELETE, 9), scratch);
    if (dev.count(RDMA_DEV_SRQ) != 0)
      `uvm_error("SRFQC_DELETE", "SRFQ 9 is still stored")
  endtask

  // 功能：协议错误：未使能 doorbell、envelope 与环不符、QPC 签名不符、查询不存在的 MR。
  // 输入/输出及副作用：每例前复位并重新使能设备。
  // 失败/边界：设备接受非法命令时报告 UVM_ERROR。
  task check_errors();
    rdma_status status;
    rdma_bytes_t sqe;
    rdma_bytes_t qpc;

    dev.reset();
    post(make_sqe(RDMA_OP_TQ_FLUSH));
    ring_doorbell(status);
    if (status.ok())
      `uvm_error("DISABLED", "doorbell before CMQC enable was accepted")

    enable();
    posted = 1;
    post(make_sqe(RDMA_OP_TQ_FLUSH));
    posted = 1;
    ring_doorbell(status);
    if (status.ok())
      `uvm_error("ENVELOPE", "SQE in the wrong ring slot was accepted")

    // QPC 缓冲区此时保存 QUERY 写回的非零内容，按全零 QPC 计算的签名必然不符。
    enable();
    qpc = new[512];
    foreach (qpc[i])
      qpc[i] = 0;
    sqe = make_sqe(RDMA_OP_QPC_CREATE, 6);
    rdma_be::set_field(sqe, RDMA_CMQ_QPC_BUFFER_ADDR_WORD_BYTE_OFFSET,
                            RDMA_CMQ_QPC_BUFFER_ADDR_LSB, RDMA_CMQ_QPC_BUFFER_ADDR_WIDTH,
                            qpc_buf >> 9);
    post_signed(sqe, 1'b1, qpc);
    ring_doorbell(status);
    if (status.ok())
      `uvm_error("SIGNATURE", "QPC_CREATE with a stale signature was accepted")

    enable();
    post(make_sqe(RDMA_OP_KEY_QUERY, 24'h99));
    ring_doorbell(status);
    if (status.ok())
      `uvm_error("ABSENT_MR", "KEY_QUERY on an absent MR was accepted")
  endtask
endclass
