// 目录：单元测试层 tests/unit/rdma_drv_verbs_test.sv。
// 职责：驱动 verbs 控制路径对设备模型的端到端效果：PD/MR（三种 PBL 模式与注销）、CQ（create 的 CQC
//   与 HMC 一致、arm 的 shadow 与 doorbell、destroy）、SRQ（create/limit/destroy）、RC QP 状态机
//   （RESET→INIT 无命令、INIT→RTR/RTR→RTS 全量签名、转 ERR 仅状态 + flush doorbell、destroy）与 UD QP，
//   CMQ 命令失败注入下 QP create/modify/destroy 的回退，最后 remove 归还全部 DMA 内存。
// 依赖：rdma_drv_*、rdma_dev、rdma_dpu_system（dpu_common）、rdma_host_mem（外部 host_mem）。
// 所有权与生命周期：测试拥有主机内存、设备与驱动对象。
class rdma_drv_verbs_test extends uvm_test;
  `uvm_component_utils(rdma_drv_verbs_test)

  rdma_host_mem mem;
  rdma_dev dev;
  rdma_drv_dev drv;
  rdma_drv_pd pd;
  rdma_drv_cq cq;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传给 uvm_test；sys/mem/dev/drv/pd/cq 为空，资源由 run_phase 创建销毁。
  // 失败/边界：parent=null 是顶层 test 的正常形式；任何 verbs 辅助必须晚于 probe 与基础 PD/CQ 建立。
  function new(string name = "rdma_drv_verbs_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：probe 后依次执行各 verbs 用例，最后 remove。
  // 输入/输出及副作用：持有 objection 直到结束。
  // 失败/边界：以 UVM_ERROR/FATAL 报告。
  task run_phase(uvm_phase phase);
    rdma_dpu_system sys;
    rdma_status status;

    phase.raise_objection(this);
    sys = rdma_dpu_test_system::single_host("verbs");
    mem = sys.nodes[0].mem;
    dev = sys.nodes[0].dev;
    sys.probe(0, status);
    expect_ok("probe", status);
    drv = sys.nodes[0].drv;
    expect_ok("alloc PD", rdma_drv_pd::alloc(drv, pd));
    check_mr();
    check_cq();
    check_srq();
    check_rc_qp();
    check_ud_qp();
    check_qp_failures();
    cq.destroy(drv, status);
    expect_ok("destroy CQ", status);
    pd.dealloc(drv);
    drv.remove(status);
    expect_ok("remove", status);
    if (mem.live_allocations() != 0)
      `uvm_error("REMOVE", $sformatf("%0d DMA allocations leaked", mem.live_allocations()))
    phase.drop_objection(this);
  endtask

  // 功能：断言 status 成功。
  // 输入/输出及副作用：what 用于报告。
  // 失败/边界：null 或失败报告 UVM_FATAL。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("DRV_VERBS", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：读设备 context 的字段（rdma_defs 三元组，base 为 context 在 SQE 中的起始偏移）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：对象不存在报告 UVM_FATAL。
  function bit [63:0] dev_field(rdma_dev_kind_e kind, int unsigned id, int unsigned word_byte,
                                int unsigned lsb, int unsigned width, int unsigned base = 0);
    rdma_dev_object obj;

    if (!dev.cmq.lookup(kind, id, obj))
      `uvm_fatal("DRV_VERBS", $sformatf("device has no %s %0d", kind.name(), id))
    return rdma_be::field(obj.bytes, word_byte - base, lsb, width);
  endfunction

  // 功能：MR：连续页→MODE_0、两页→MODE_1、三页→MODE_2（PBLE 写入 HMC PBL 页），设备 MRT 携带
  //   VA/PD/PBL 模式；注销后设备删除 MR，PBLE 归还。
  // 输入/输出及副作用：注册并注销三个 MR。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_mr();
    rdma_drv_mr mrs[3];
    bit [63:0] pages[$];
    int unsigned modes[3];
    rdma_status status;

    modes = '{RDMA_PBL_MODE_0, RDMA_PBL_MODE_1, RDMA_PBL_MODE_2};
    for (int m = 0; m < 3; m++) begin
      pages.delete();
      if (m == 0)
        pages = '{64'h10_0000, 64'h10_1000, 64'h10_2000};
      if (m == 1)
        pages = '{64'h20_0000, 64'h28_0000};
      if (m == 2)
        pages = '{64'h30_0000, 64'h38_0000, 64'h31_0000};
      rdma_drv_mr::reg_mr(drv, pd, 64'h7000_0000 + m * 64'h10_0000, pages.size() * 4096,
                       rdma_drv_mr::rights_of(1, 1, 1, 0), pages, mrs[m], status);
      expect_ok($sformatf("reg MR %0d", m), status);
      if (mrs[m].pbl_mode != modes[m] ||
          dev_field(RDMA_DEV_MR, mrs[m].stag >> 8, RDMA_MRT_BODY_PBL_MODE_WORD_BYTE_OFFSET,
                    RDMA_MRT_BODY_PBL_MODE_LSB, RDMA_MRT_BODY_PBL_MODE_WIDTH) != modes[m] ||
          dev_field(RDMA_DEV_MR, mrs[m].stag >> 8, RDMA_MRT_BODY_START_VA_WORD_BYTE_OFFSET,
                    RDMA_MRT_BODY_START_VA_LSB, RDMA_MRT_BODY_START_VA_WIDTH) != mrs[m].va ||
          dev_field(RDMA_DEV_MR, mrs[m].stag >> 8, RDMA_MRT_BODY_PD_IDX_WORD_BYTE_OFFSET,
                    RDMA_MRT_BODY_PD_IDX_LSB, RDMA_MRT_BODY_PD_IDX_WIDTH) != pd.pd_id)
        `uvm_error("MR", $sformatf("MR %0d device MRT does not match the registration", m))
    end
    if (drv.pble.in_use() != 4)
      `uvm_error("MR", $sformatf("PBLE pool holds %0d entries for a 3-page MR",
                                 drv.pble.in_use()))
    foreach (mrs[m]) begin
      mrs[m].dereg(drv, status);
      expect_ok($sformatf("dereg MR %0d", m), status);
    end
    if (dev.cmq.count(RDMA_DEV_MR) != 0 || drv.pble.in_use() != 0)
      `uvm_error("MR", "deregistration left MRs or PBLEs behind")
  endtask

  // 功能：CQ：设备 CQC 与驱动写入 HMC 槽的 56B 一致，PBA 正确；arm 写 shadow arm 字节并敲 CQ doorbell。
  // 输入/输出及副作用：创建 cq（供 QP 使用）。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_cq();
    rdma_dev_object obj;
    rdma_bytes_t hmc;
    int unsigned n_before;
    rdma_status status;

    rdma_drv_cq::create_cq(drv, 100, 0, cq, status);
    expect_ok("create CQ", status);
    if (cq.size != 1024)
      `uvm_error("CQ", $sformatf("CQ depth %0d for 100 requested entries", cq.size))
    expect_ok("read CQC", drv.hw.read(cq.ctx_page, cq.ctx_offset, 56, hmc));
    if (!dev.cmq.lookup(RDMA_DEV_CQ, cq.cqn, obj))
      `uvm_fatal("CQ", "device has no CQC")
    if (obj.bytes != hmc)
      `uvm_error("CQ", "device CQC differs from the HMC context slot")
    if (dev_field(RDMA_DEV_CQ, cq.cqn, RDMA_CQC_BODY_CUR_CQ_PD_PBA_WORD_BYTE_OFFSET,
                  RDMA_CQC_BODY_CUR_CQ_PD_PBA_LSB, RDMA_CQC_BODY_CUR_CQ_PD_PBA_WIDTH, 8) !=
        cq.mem_kbuf.base_iova() >> 12)
      `uvm_error("CQ", "CQC does not carry the CQ buffer address")
    n_before = dev.doorbell_offsets.size();
    cq.arm(drv, 1'b0, status);
    expect_ok("arm CQ", status);
    if (dev.doorbell_offsets.size() != n_before + 1 ||
        dev.doorbell_offsets[n_before] != RDMA_DB_CQ_OFFSET)
      `uvm_error("CQ", "arm did not ring the CQ doorbell")
    expect_ok("read shadow", drv.hw.read(cq.ctx_page, cq.ctx_offset + 51, 1, hmc));
    if (hmc[0] != (RDMA_CQC_ARM_ST_NEXT_COMP << 2))
      `uvm_error("CQ", $sformatf("shadow arm byte is %02h", hmc[0]))
  endtask

  // 功能：SRQ：create 的 SRFQC 携带 PD 与 limit/4，modify_limit 敲 SRFQ doorbell，destroy 删除。
  // 输入/输出及副作用：创建并销毁 SRQ。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_srq();
    rdma_drv_srq srq;
    int unsigned n_before;
    rdma_status status;

    rdma_drv_srq::create_srq(drv, pd, 100, 0, srq, status);
    expect_ok("create SRQ", status);
    if (dev_field(RDMA_DEV_SRQ, srq.srqn, RDMA_SRQC_BODY_LIMIT_TH_WORD_BYTE_OFFSET,
                  RDMA_SRQC_BODY_LIMIT_TH_LSB, RDMA_SRQC_BODY_LIMIT_TH_WIDTH, 16) != 4 ||
        dev_field(RDMA_DEV_SRQ, srq.srqn, RDMA_SRQC_BODY_PD_IDX_WORD_BYTE_OFFSET,
                  RDMA_SRQC_BODY_PD_IDX_LSB, RDMA_SRQC_BODY_PD_IDX_WIDTH, 16) != pd.pd_id)
      `uvm_error("SRQ", "SRFQC limit/PD do not match")
    n_before = dev.doorbell_offsets.size();
    srq.modify_limit(drv, 32, status);
    expect_ok("modify SRQ limit", status);
    if (dev.doorbell_offsets.size() != n_before + 1 ||
        dev.doorbell_offsets[n_before] != RDMA_DB_SRFQ_OFFSET)
      `uvm_error("SRQ", "modify_limit did not ring the SRFQ doorbell")
    srq.destroy(drv, status);
    expect_ok("destroy SRQ", status);
    if (dev.cmq.count(RDMA_DEV_SRQ) != 0)
      `uvm_error("SRQ", "device still holds the SRQ")
  endtask

  // 功能：建一个 QP 的初始属性。
  // 输入/输出及副作用：创建属性对象，选择 t，借用测试当前 pd/cq 同时作为收发 CQ，并把 send SGE 上限设 4。
  // 失败/边界：要求 pd/cq 已由 run_phase 建立；t 应为驱动支持的 RC/UD，函数不创建 SRQ 或校验资源状态。
  function rdma_drv_qp_init_attr qp_attr(rdma_drv_qp_type_e t);
    rdma_drv_qp_init_attr a;

    a = rdma_drv_qp_init_attr::type_id::create("init_attr");
    a.qp_type = t;
    a.pd = pd;
    a.send_cq = cq;
    a.recv_cq = cq;
    a.max_send_sge = 4;
    return a;
  endfunction

  // 功能：RC QP：create 的设备 QPC 等于驱动镜像；RESET→INIT 不发命令；INIT→RTR（DEST_QPN/PSN）、
  //   RTR→RTS 为全量签名修改且设备 QPC 同步；destroy 先转 ERR（flush doorbell）再删除。
  // 输入/输出及副作用：创建并销毁 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_rc_qp();
    rdma_drv_qp qp;
    rdma_drv_qp_attr attr;
    rdma_dev_object obj;
    int unsigned before_cmds;
    int unsigned before_dbs;
    rdma_status status;

    rdma_drv_qp::create_qp(drv, qp_attr(RDMA_DRV_QPT_RC), qp, status);
    expect_ok("create RC QP", status);
    if (qp.sq_sgb.size() != qp.sq_depth / 8)
      `uvm_error("QP", "max_send_sge>2 did not allocate SQ SGB pages")
    if (!dev.cmq.lookup(RDMA_DEV_QP, qp.qpn, obj))
      `uvm_fatal("QP", "device has no QPC after create")
    if (obj.bytes != qp.qpc)
      `uvm_error("QP", "device QPC differs from the driver image after create")
    attr = rdma_drv_qp_attr::type_id::create("to_init");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_ACCESS;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.access = RDMA_RIGHT_REMOTE_WRITE;
    before_cmds = dev.cmq.executed_opcodes.size();
    qp.modify(drv, attr, status);
    expect_ok("RESET->INIT", status);
    if (dev.cmq.executed_opcodes.size() != before_cmds)
      `uvm_error("QP", "RESET->INIT issued a CMQ command")
    attr = rdma_drv_qp_attr::type_id::create("to_rtr");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_DEST_QPN |
                rdma_drv_qp_attr::M_RQ_PSN;
    attr.state = RDMA_DRV_QPS_RTR;
    attr.dest_qpn = 24'h000077;
    attr.rq_psn = 24'h000100;
    qp.modify(drv, attr, status);
    expect_ok("INIT->RTR", status);
    // lookup 的输出参数与同一表达式中的读取顺序不保证，分两句写。
    if (!dev.cmq.lookup(RDMA_DEV_QP, qp.qpn, obj))
      `uvm_fatal("QP", "device has no QPC after modify")
    if (obj.bytes != qp.qpc ||
        rdma_be::field(obj.bytes, RDMA_QPC_DST_QPN_WORD_BYTE_OFFSET, RDMA_QPC_DST_QPN_LSB,
                       RDMA_QPC_DST_QPN_WIDTH) != 24'h77)
      `uvm_error("QP", "full modify did not deliver the RTR context")
    attr = rdma_drv_qp_attr::type_id::create("to_rts");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN;
    attr.state = RDMA_DRV_QPS_RTS;
    attr.sq_psn = 24'h000200;
    qp.modify(drv, attr, status);
    expect_ok("RTR->RTS", status);
    if (dev_field(RDMA_DEV_QP, qp.qpn, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET, RDMA_QPC_QP_ST_LSB,
                  RDMA_QPC_QP_ST_WIDTH) != 3)
      `uvm_error("QP", "device QP is not RTS")
    before_dbs = dev.doorbell_offsets.size();
    qp.destroy(drv, status);
    expect_ok("destroy RC QP", status);
    if (dev.doorbell_offsets.size() != before_dbs + 1 ||
        dev.doorbell_offsets[before_dbs] != RDMA_DB_QP_FLUSH_OFFSET)
      `uvm_error("QP", "transition to ERR did not ring the QP flush doorbell")
    if (dev.cmq.count(RDMA_DEV_QP) != 0)
      `uvm_error("QP", "device still holds the destroyed QP")
  endtask

  // 功能：UD QP：设备 QPC 的服务类型为 UD，总是分配 SGB；destroy 删除。
  // 输入/输出及副作用：创建并销毁 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_ud_qp();
    rdma_drv_qp qp;
    rdma_drv_qp_init_attr a;
    rdma_status status;

    a = qp_attr(RDMA_DRV_QPT_UD);
    a.max_send_sge = 1;
    rdma_drv_qp::create_qp(drv, a, qp, status);
    expect_ok("create UD QP", status);
    if (dev_field(RDMA_DEV_QP, qp.qpn, RDMA_QPC_SERVICE_TYPE_WORD_BYTE_OFFSET,
                  RDMA_QPC_SERVICE_TYPE_LSB, RDMA_QPC_SERVICE_TYPE_WIDTH) != 3 ||
        qp.sq_sgb.size() == 0)
      `uvm_error("QP", "UD QP context or SGB is wrong")
    qp.destroy(drv, status);
    expect_ok("destroy UD QP", status);
  endtask

  // 功能：设备 CMQ 注入失败：QPC_CREATE 失败时 create_qp 返回错误且 DMA 分配、QPN 与设备 QP 数
  //   全部回退；INIT→RTR 的 QPC_MODIFY 失败时返回错误且 cur_state 仍为 INIT；QPC_DELETE 失败时
  //   destroy 返回错误且不释放（与驱动一致），再次 destroy 成功后 DMA 归还。
  // 输入/输出及副作用：创建并销毁 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_qp_failures();
    rdma_drv_qp qp;
    rdma_drv_qp_attr attr;
    int unsigned live;
    int unsigned qpns;
    int unsigned dev_qps;
    rdma_status status;

    live = mem.live_allocations();
    qpns = drv.qp_ids.count();
    dev_qps = dev.cmq.count(RDMA_DEV_QP);
    dev.cmq.inject_failure(RDMA_OP_QPC_CREATE, 8'h40);
    rdma_drv_qp::create_qp(drv, qp_attr(RDMA_DRV_QPT_RC), qp, status);
    if (status.ok() || status.code != RDMA_SC_UNKNOWN_HW_ERROR)
      `uvm_error("QP_FAIL", $sformatf("failed QPC_CREATE returned %s", status.convert2string()))
    if (mem.live_allocations() != live || drv.qp_ids.count() != qpns ||
        dev.cmq.count(RDMA_DEV_QP) != dev_qps)
      `uvm_error("QP_FAIL", "failed create_qp leaked DMA, a QPN or a device QP")
    rdma_drv_qp::create_qp(drv, qp_attr(RDMA_DRV_QPT_RC), qp, status);
    expect_ok("create QP after injected failure", status);
    attr = rdma_drv_qp_attr::type_id::create("fail_init");
    attr.mask = rdma_drv_qp_attr::M_STATE;
    attr.state = RDMA_DRV_QPS_INIT;
    qp.modify(drv, attr, status);
    expect_ok("RESET->INIT", status);
    dev.cmq.inject_failure(RDMA_OP_QPC_MODIFY, 8'h41);
    attr = rdma_drv_qp_attr::type_id::create("fail_rtr");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_DEST_QPN;
    attr.state = RDMA_DRV_QPS_RTR;
    attr.dest_qpn = 24'h33;
    qp.modify(drv, attr, status);
    if (status.ok() || qp.cur_state != RDMA_DRV_QPS_INIT)
      `uvm_error("QP_FAIL", "failed QPC_MODIFY changed the QP state")
    dev.cmq.inject_failure(RDMA_OP_QPC_DELETE, 8'h42);
    qp.destroy(drv, status);
    if (status.ok() || dev.cmq.count(RDMA_DEV_QP) != dev_qps + 1)
      `uvm_error("QP_FAIL", "failed QPC_DELETE did not keep the QP")
    qp.destroy(drv, status);
    expect_ok("destroy after injected failure", status);
    if (mem.live_allocations() != live || drv.qp_ids.count() != qpns)
      `uvm_error("QP_FAIL", "QP resources were not returned after destroy")
  endtask
endclass
