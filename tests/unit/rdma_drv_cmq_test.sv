// 目录：单元测试层 tests/unit/rdma_drv_cmq_test.sv。
// 职责：驱动 CMQ（rdma_drv_cmq）与设备 CMQ（rdma_dev_cmq）经 BAR/DMA 端到端对接：CMQC 寄存器编程、
//   跨圈回绕、context 命令往返、ecode 透传，以及驱动签名被设备按 cmq.c 规则接受。
// 依赖：rdma_drv_hw/rdma_drv_cmq、rdma_dev、rdma_drv_dev_bar、rdma_mock_host_mem。
// 所有权与生命周期：测试拥有 mock 内存、设备与驱动对象。
class rdma_drv_cmq_test extends uvm_test;
  `uvm_component_utils(rdma_drv_cmq_test)

  rdma_mock_host_mem mem;
  rdma_dev dev;
  rdma_drv_dev_bar bar;
  rdma_drv_hw hw;
  rdma_drv_cmq cmq;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传给 uvm_test。
  // 失败/边界：无。
  function new(string name = "rdma_drv_cmq_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：建立驱动与设备，依次执行用例。
  // 输入/输出及副作用：持有 objection 直到用例结束。
  // 失败/边界：用例内以 UVM_ERROR/FATAL 报告。
  task run_phase(uvm_phase phase);
    rdma_function_handle fn;
    rdma_status status;

    phase.raise_objection(this);
    mem = rdma_mock_host_mem::type_id::create("drv_cmq_mem");
    dev = rdma_dev::type_id::create("drv_cmq_dev");
    dev.configure(mem);
    bar = rdma_drv_dev_bar::type_id::create("drv_cmq_bar");
    bar.dev = dev;
    fn = rdma_function_handle::type_id::create("drv_cmq_fn");
    fn.kind = RDMA_RESOURCE_FUNCTION;
    fn.function_uid = 64'h0a0b;
    fn.generation = 1;
    hw = rdma_drv_hw::type_id::create("drv_cmq_hw");
    expect_ok("bind", hw.bind_hw(bar, mem, fn));
    cmq = rdma_drv_cmq::type_id::create("drv_cmq");
    cmq.create_cmq(hw, status);
    expect_ok("create", status);
    check_registers();
    check_wrap();
    check_context_roundtrip();
    check_signed_qpc();
    expect_ok("destroy", cmq.destroy());
    phase.drop_objection(this);
  endtask

  // 功能：断言 status 成功。
  // 输入/输出及副作用：what 用于报告。
  // 失败/边界：null 或失败报告 UVM_FATAL。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("DRV_CMQ", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：create 按 xtrdma_sc_cmq_create 先写 CMQC_HIGH（SQ 基址）再写 CMQC_LOW（bit31 使能）。
  // 输入/输出及副作用：只读 BAR 记录。
  // 失败/边界：顺序或取值不符报告 UVM_ERROR。
  function void check_registers();
    if (bar.written_offsets.size() != 2 ||
        bar.written_offsets[0] != RDMA_NOTIFY_WINDOW_OFFSET + RDMA_DB_CMQC_HIGH_OFFSET ||
        bar.written_offsets[1] != RDMA_NOTIFY_WINDOW_OFFSET + RDMA_DB_CMQC_LOW_OFFSET ||
        bar.written_values[1] != 64'h8000_0000)
      `uvm_error("REGISTERS", "CMQ create did not program CMQC_HIGH then CMQC_LOW")
  endfunction

  // 功能：40 条 TQ_FLUSH 跨越 32 深度环，全部成功且设备按序执行。
  // 输入/输出及副作用：推进两侧环。
  // 失败/边界：任一失败报告 UVM_FATAL/ERROR。
  task check_wrap();
    rdma_bytes_t cqe;
    rdma_status status;

    for (int i = 0; i < 40; i++) begin
      cmq.exec(rdma_drv_cmq::new_sqe(RDMA_OP_TQ_FLUSH), cqe, status);
      expect_ok($sformatf("TQ_FLUSH %0d", i), status);
    end
    if (dev.cmq.executed_opcodes.size() != 40)
      `uvm_error("WRAP", $sformatf("device executed %0d commands",
                                   dev.cmq.executed_opcodes.size()))
  endtask

  // 功能：CQC_CREATE 后 CQC_QUERY 的 CQE 回填同一 CQC；删除不存在的 CQ 得到 CQC_INVLD 错误。
  // 输入/输出及副作用：修改设备 CQ 表。
  // 失败/边界：回填不符或错误未透传报告 UVM_ERROR。
  task check_context_roundtrip();
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;
    rdma_status status;

    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CQC_CREATE);
    rdma_be::set_field(sqe, RDMA_CQC_BODY_CQN_WORD_BYTE_OFFSET, RDMA_CQC_BODY_CQN_LSB,
                       RDMA_CQC_BODY_CQN_WIDTH, 7);
    for (int i = 8; i < 64; i++)
      sqe[i] = 8'h10 + i;
    cmq.exec(sqe, cqe, status);
    expect_ok("CQC_CREATE", status);
    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CQC_QUERY);
    rdma_be::set_field(sqe, RDMA_CQC_BODY_CQN_WORD_BYTE_OFFSET, RDMA_CQC_BODY_CQN_LSB,
                       RDMA_CQC_BODY_CQN_WIDTH, 7);
    cmq.exec(sqe, cqe, status);
    expect_ok("CQC_QUERY", status);
    for (int i = 8; i < 64; i++)
      if (cqe[i] != 8'h10 + i) begin
        `uvm_error("CQC_QUERY", $sformatf("CQE byte %0d is %02h", i, cqe[i]))
        break;
      end
    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CQC_DELETE);
    rdma_be::set_field(sqe, RDMA_CQC_BODY_CQN_WORD_BYTE_OFFSET, RDMA_CQC_BODY_CQN_LSB,
                       RDMA_CQC_BODY_CQN_WIDTH, 9);
    cmq.exec(sqe, cqe, status);
    if (status.ok() || cmq.last_ecode != RDMA_ECODE_EC_RCE_CQC_INVLD)
      `uvm_error("CQC_DELETE", "deleting an absent CQ did not report CQC_INVLD")
  endtask

  // 功能：QPC_CREATE 带签名（覆盖信封与 512B QPC）被设备接受并保存同一 QPC。
  // 输入/输出及副作用：分配 QPC 缓冲，修改设备 QP 表。
  // 失败/边界：签名被拒或内容不符报告 UVM_ERROR。
  task check_signed_qpc();
    rdma_drv_dma qpc_buf;
    rdma_bytes_t qpc;
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;
    rdma_dev_object obj;
    rdma_status status;

    expect_ok("alloc QPC buffer", hw.alloc_dma(4096, 4096, qpc_buf));
    qpc = rdma_be::zeros(RDMA_QPC_BYTES);
    foreach (qpc[i])
      qpc[i] = i * 5 + 1;
    expect_ok("write QPC", hw.write(qpc_buf, 0, qpc));
    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_QPC_CREATE);
    rdma_be::set_field(sqe, RDMA_CMQ_QPN_WORD_BYTE_OFFSET, RDMA_CMQ_QPN_LSB,
                       RDMA_CMQ_QPN_WIDTH, 3);
    rdma_be::set_field(sqe, RDMA_CMQ_QPC_BUFFER_ADDR_WORD_BYTE_OFFSET,
                       RDMA_CMQ_QPC_BUFFER_ADDR_LSB, RDMA_CMQ_QPC_BUFFER_ADDR_WIDTH,
                       qpc_buf.iova >> RDMA_CMQ_QPC_BUFFER_ADDR_LSB);
    cmq.exec_signed(sqe, 1'b1, qpc, cqe, status);
    expect_ok("QPC_CREATE", status);
    if (!dev.cmq.lookup(RDMA_DEV_QP, 3, obj) || obj.bytes != qpc)
      `uvm_error("QPC_CREATE", "device did not store the signed QPC")
    expect_ok("free QPC buffer", hw.free_dma(qpc_buf));
  endtask
endclass
