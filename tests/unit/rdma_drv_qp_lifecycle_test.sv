// 目录：单元测试层 tests/unit/rdma_drv_qp_lifecycle_test.sv。
// 层：单元测试。
// 职责：QP/队列生命周期（复用 rdma_drv_data_test 的两节点与辅助）：RTS→SQD（驱动等 AE
//   RTS2SQD_DONE）后新 WR 不发送、SQD→RTS 后恢复；RTS2SQD/SQD2RTS doorbell 状态不符的 AE；转 RESET
//   （驱动按 xtrdma 映射为 QPC ERR）与 INIT 状态的 QP 丢弃入站请求；QP/CQ/SRQ 销毁后设备 context
//   删除、按驱动的分配策略重建（SRQ 首个空位复用原编号，QP/CQ 轮转取下一编号）并恢复流量。
// 依赖：rdma_drv_data_test。
// 所有权：同 rdma_drv_data_test。
// 生命周期：run_phase 内运行。
class rdma_drv_qp_lifecycle_test extends rdma_drv_data_test;
  `uvm_component_utils(rdma_drv_qp_lifecycle_test)

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传给 rdma_drv_data_test；沿用其空节点与 next_wr_id 初始状态。
  // 失败/边界：parent=null 是顶层 test 的正常形式；生命周期用例依赖父类 run_phase 先建立并连接两个 QP。
  function new(string name = "rdma_drv_qp_lifecycle_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：依次执行生命周期用例。
  // 输入/输出及副作用：见各用例。
  // 失败/边界：以 UVM_ERROR/FATAL 报告。
  virtual task run_cases();
    check_sqd();
    check_sqd_doorbell_mismatch();
    check_reset_and_init_drop();
    check_rebuild_reuses_ids();
  endtask

  // 功能：在 n 的 qp 上投一个 RECV（SGE 指向节点缓冲 offset）。
  // 输入/输出及副作用：返回 wr_id。
  // 失败/边界：失败报告 UVM_FATAL。
  task recv_on(rdma_drv_data_node n, rdma_drv_qp qp, int unsigned offset, int unsigned len,
               output longint unsigned wr_id);
    rdma_drv_recv_wr wr;
    rdma_status status;

    wr = rdma_drv_recv_wr::type_id::create("lc_recv");
    wr.wr_id = next_wr_id++;
    wr.sges.push_back(rdma_drv_sge::make(n.data_buf.iova + offset, len, n.mr.key()));
    rdma_drv_wr::post_recv(n.drv, qp, wr, status);
    expect_ok("post_recv", status);
    wr_id = wr.wr_id;
  endtask

  // 功能：节点 CQ 在 polls 次（每次 100ns）内得到 n 个完成。
  // 输入/输出及副作用：wcs 输出。
  // 失败/边界：不足报告 UVM_FATAL。
  task wait_long(rdma_drv_data_node node, int unsigned n, int unsigned polls,
                 output rdma_drv_wc wcs[$]);
    rdma_status status;

    wcs.delete();
    for (int unsigned t = 0; t < polls && wcs.size() < n; t++) begin
      rdma_drv_wr::poll_cq(node.drv, node.cq, n - wcs.size(), wcs, status);
      expect_ok("poll", status);
      if (wcs.size() < n)
        #100ns;
    end
    if (wcs.size() != n)
      `uvm_fatal("LIFECYCLE", $sformatf("%s: %0d of %0d completions", node.get_name(), wcs.size(),
                                        n))
  endtask

  // 功能：断言节点 CQ 在 20us 内没有完成。
  // 输入/输出及副作用：轮询 CQ。
  // 失败/边界：有完成报告 UVM_ERROR。
  task expect_idle(string label, rdma_drv_data_node node);
    rdma_drv_wc wcs[$];
    rdma_status status;

    #20us;
    rdma_drv_wr::poll_cq(node.drv, node.cq, 4, wcs, status);
    expect_ok("poll idle", status);
    if (wcs.size() != 0)
      `uvm_error(label, $sformatf("%0d unexpected completions on %s", wcs.size(),
                                  node.get_name()))
  endtask

  // 功能：把 qp 转到 state（只带 M_STATE）。
  // 输入/输出及副作用：QP modify。
  // 失败/边界：status 输出。
  task move(rdma_drv_data_node n, rdma_drv_qp qp, rdma_drv_qp_state_e state,
            output rdma_status status);
    rdma_drv_qp_attr attr;

    attr = rdma_drv_qp_attr::type_id::create("lc_move");
    attr.mask = rdma_drv_qp_attr::M_STATE;
    attr.state = state;
    qp.modify(n.drv, attr, status);
  endtask

  // 功能：设备 QPC 的 QP_ST。
  // 输入/输出及副作用：只读设备 context。
  // 失败/边界：QPC 不存在报告 UVM_ERROR 并返回 0。
  function int unsigned qpc_state(rdma_drv_data_node n, rdma_drv_qp qp);
    rdma_dev_object obj;

    if (!n.dev.cmq.lookup(RDMA_DEV_QP, qp.qpn, obj)) begin
      `uvm_error("LIFECYCLE", $sformatf("QP %0d has no device QPC", qp.qpn))
      return 0;
    end
    return rdma_be::field(obj.bytes, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET, RDMA_QPC_QP_ST_LSB,
                          RDMA_QPC_QP_ST_WIDTH);
  endfunction

  // 功能：RTS→SQD：modify 返回时驱动已收到 RTS2SQD_DONE，QPC 为 SQD(5)；此后投递的 SEND 不发送
  //   （两端 20us 内无完成）；SQD→RTS 后该 SEND 完成并被 B 接收，数据一致。
  // 输入/输出及副作用：创建一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_sqd();
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    longint unsigned rid;
    rdma_status status;

    make_pair(null, qa, qb);
    recv_on(b, qb, 'h1000, 'h100, rid);
    move(a, qa, RDMA_DRV_QPS_SQD, status);
    expect_ok("RTS to SQD", status);
    if (qa.cur_state != RDMA_DRV_QPS_SQD || qpc_state(a, qa) != 5)
      `uvm_error("SQD", $sformatf("QP state %s, QPC %0d", qa.cur_state.name(), qpc_state(a, qa)))
    data = fill(a, 'h100, 64, 8'h19);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h100}, '{64});
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post SEND in SQD", status);
    expect_idle("SQD holds new WRs", a);
    expect_idle("SQD sends nothing", b);
    move(a, qa, RDMA_DRV_QPS_RTS, status);
    expect_ok("SQD to RTS", status);
    wait_wcs(a, 1, wcs);
    expect_wc("SQD resumed send", wcs[0], wr.wr_id, 1'b0);
    wait_wcs(b, 1, wcs);
    expect_wc("SQD resumed recv", wcs[0], rid, 1'b1);
    expect_mem("SQD resumed data", b, 'h1000, data);
  endtask

  // 功能：QP 在 RTS 时直接敲 RTS2SQD doorbell → AE EC_RTS2SQD_DB_QP_ST_UNMATCH；QPC 为 SQD 时敲
  //   SQD2RTS doorbell → AE EC_SQD2RTS_DB_QP_ST_UNMATCH。
  // 输入/输出及副作用：创建一对 QP；直接写 doorbell。
  // 失败/边界：未收到对应 AE 报告 UVM_ERROR。
  task check_sqd_doorbell_mismatch();
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    bit [63:0] db;
    bit [31:0] events[$];
    rdma_status status;

    make_pair(null, qa, qb);
    db = '0;
    db[RDMA_NOTIFY_QP_SN_LSB +: RDMA_NOTIFY_QP_SN_WIDTH] = qa.qp_sn;
    db[RDMA_NOTIFY_QP_DB_TYPE_LSB +: RDMA_NOTIFY_QP_DB_TYPE_WIDTH] = RDMA_DB_TYPE_RTS2SQD;
    db[RDMA_NOTIFY_QP_QPN_LSB +: RDMA_NOTIFY_QP_QPN_WIDTH] = qa.qpn;
    a.drv.hw.notify(RDMA_DB_RTS2SQD_OFFSET, db, status);
    expect_ok("raw RTS2SQD", status);
    #1us;
    rdma_drv_wr::process_aeq(a.drv, events, status);
    expect_ok("process AEQ", status);
    if (events.size() != 1 || events[0] != {RDMA_ECODE_EC_RTS2SQD_DB_QP_ST_UNMATCH, 24'(qa.qpn)})
      `uvm_error("SQD_MISMATCH", $sformatf("RTS2SQD in RTS gave AEQ events %p", events))
    move(a, qa, RDMA_DRV_QPS_SQD, status);
    expect_ok("RTS to SQD", status);
    db[RDMA_NOTIFY_QP_DB_TYPE_LSB +: RDMA_NOTIFY_QP_DB_TYPE_WIDTH] = RDMA_DB_TYPE_SQD2RTS;
    a.drv.hw.notify(RDMA_DB_SQD2RTS_OFFSET, db, status);
    expect_ok("raw SQD2RTS", status);
    events.delete();
    rdma_drv_wr::process_aeq(a.drv, events, status);
    expect_ok("process AEQ", status);
    if (events.size() != 1 || events[0] != {RDMA_ECODE_EC_SQD2RTS_DB_QP_ST_UNMATCH, 24'(qa.qpn)})
      `uvm_error("SQD_MISMATCH", $sformatf("SQD2RTS in SQD gave AEQ events %p", events))
  endtask

  // 功能：B 的 QP 转 RESET：驱动按 xtrdma 发 QPC_MODIFY(ERR)，设备 QPC 为 ERR(4)；A 发往它的 SEND
  //   被丢弃（state_drops 增加、B 无接收完成），A 重试耗尽得到 vendor 0x16。另一个只到 INIT 的 QP
  //   同样丢弃入站请求。
  // 输入/输出及副作用：创建两对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_reset_and_init_drop();
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_qp_init_attr init;
    rdma_drv_qp_attr attr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t scratch;
    longint unsigned rid;
    int unsigned drops;
    rdma_status status;

    make_pair(null, qa, qb);
    recv_on(b, qb, 'h1200, 'h100, rid);
    move(b, qb, RDMA_DRV_QPS_RESET, status);
    expect_ok("RTS to RESET", status);
    if (qb.cur_state != RDMA_DRV_QPS_RESET || qpc_state(b, qb) != 4)
      `uvm_error("RESET", $sformatf("QP state %s, QPC %0d", qb.cur_state.name(),
                                    qpc_state(b, qb)))
    drops = b.dev.nic.state_drops;
    scratch = fill(a, 'h200, 32, 8'h29);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h200}, '{32});
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post SEND to RESET QP", status);
    wait_long(a, 1, 5000, wcs);
    expect_wc("SEND to RESET QP", wcs[0], wr.wr_id, 1'b0, RDMA_DRV_WC_GENERAL_ERR);
    if (wcs[0].vendor_err != RDMA_ECODE_EC_TPE_SQ_RTO_OVERTIME || b.dev.nic.state_drops <= drops)
      `uvm_error("RESET", $sformatf("vendor %02h, state drops %0d", wcs[0].vendor_err,
                                    b.dev.nic.state_drops - drops))
    expect_idle("RESET QP receives nothing", b);
    // INIT 的 QP：创建后只到 INIT（不连对端），A 的另一 QP 指向它。
    init = rdma_drv_qp_init_attr::type_id::create("lc_init_qp");
    init.pd = b.pd;
    init.send_cq = b.cq;
    init.recv_cq = b.cq;
    rdma_drv_qp::create_qp(b.drv, init, qb, status);
    expect_ok("create INIT QP", status);
    attr = rdma_drv_qp_attr::type_id::create("lc_init");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_ACCESS;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.access = RDMA_RIGHT_REMOTE_WRITE;
    qb.modify(b.drv, attr, status);
    expect_ok("INIT", status);
    init = rdma_drv_qp_init_attr::type_id::create("lc_peer");
    init.pd = a.pd;
    init.send_cq = a.cq;
    init.recv_cq = a.cq;
    rdma_drv_qp::create_qp(a.drv, init, qa, status);
    expect_ok("create peer QP", status);
    connect_qp(a.drv, qa, qb.qpn, b.mac);
    drops = b.dev.nic.state_drops;
    wr = send_wr(a, RDMA_DRV_WR_WRITE, '{'h200}, '{32});
    wr.remote_va = b.data_buf.iova + 'h1300;
    wr.rkey = b.mr.key();
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post WRITE to INIT QP", status);
    wait_long(a, 1, 5000, wcs);
    expect_wc("WRITE to INIT QP", wcs[0], wr.wr_id, 1'b0, RDMA_DRV_WC_GENERAL_ERR);
    if (b.dev.nic.state_drops <= drops)
      `uvm_error("INIT", "INIT QP accepted an inbound request")
  endtask

  // 功能：QP/CQ/SRQ 销毁后设备 context 删除；重建时 SRQ 复用原编号（alloc_first），QP/CQ 按
  //   xtrdma_alloc_rsrc_from_next_pos 轮转取后面的编号；重建的 SRQ + QP 对上 SEND 正常完成。
  // 输入/输出及副作用：创建并销毁 CQ、SRQ 与两对 QP。
  // 失败/边界：编号不同或流量失败报告 UVM_ERROR。
  task check_rebuild_reuses_ids();
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_cq cq;
    rdma_drv_srq srq;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    int unsigned ids[3];
    rdma_dev_object obj;
    rdma_status status;

    rdma_drv_cq::create_cq(b.drv, 64, 0, cq, status);
    expect_ok("create CQ", status);
    rdma_drv_srq::create_srq(b.drv, b.pd, 16, 0, srq, status);
    expect_ok("create SRQ", status);
    make_pair(srq, qa, qb);
    ids = '{cq.cqn, srq.srqn, qb.qpn};
    qb.destroy(b.drv, status);
    expect_ok("destroy QP", status);
    qa.destroy(a.drv, status);
    expect_ok("destroy peer QP", status);
    srq.destroy(b.drv, status);
    expect_ok("destroy SRQ", status);
    cq.destroy(b.drv, status);
    expect_ok("destroy CQ", status);
    if (b.dev.cmq.lookup(RDMA_DEV_CQ, ids[0], obj) || b.dev.cmq.lookup(RDMA_DEV_SRQ, ids[1], obj) ||
        b.dev.cmq.lookup(RDMA_DEV_QP, ids[2], obj))
      `uvm_error("REBUILD", "device context survived destroy")
    rdma_drv_cq::create_cq(b.drv, 64, 0, cq, status);
    expect_ok("recreate CQ", status);
    rdma_drv_srq::create_srq(b.drv, b.pd, 16, 0, srq, status);
    expect_ok("recreate SRQ", status);
    make_pair(srq, qa, qb);
    if (cq.cqn <= ids[0] || srq.srqn != ids[1] || qb.qpn <= ids[2])
      `uvm_error("REBUILD", $sformatf("IDs %0d/%0d/%0d, before %p", cq.cqn, srq.srqn, qb.qpn, ids))
    rwr = rdma_drv_recv_wr::type_id::create("lc_srq_recv");
    rwr.wr_id = next_wr_id++;
    rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h1400, 'h100, b.mr.key()));
    rdma_drv_wr::post_srq_recv(b.drv, srq, rwr, status);
    expect_ok("post SRQ recv", status);
    data = fill(a, 'h300, 48, 8'h39);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h300}, '{48});
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post SEND after rebuild", status);
    wait_wcs(a, 1, wcs);
    expect_wc("rebuilt send", wcs[0], wr.wr_id, 1'b0);
    wait_wcs(b, 1, wcs);
    expect_wc("rebuilt recv", wcs[0], rwr.wr_id, 1'b1);
    expect_mem("rebuilt data", b, 'h1400, data);
  endtask
endclass
