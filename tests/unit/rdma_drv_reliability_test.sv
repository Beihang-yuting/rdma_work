// 目录：单元测试层 tests/unit/rdma_drv_reliability_test.sv。
// 层：单元测试。
// 职责：两节点（复用 rdma_drv_data_test 的节点、链路与辅助）的可靠传输与异常路径：中间包丢失后从
//   PSN 序列 NAK 指出的 PSN 起重传、ACK/ATOMIC ACK 丢失后的重复请求处理（不重复执行）、READ 末段
//   响应丢失后只重新请求缺失部分、RNR NAK 按定时器编码等待的重试与耗尽（0xB7）、URC 的 SQ/RQ 异常
//   完成（ABNML CEQE 或 AEQE → REM_ACCESS/REM_INV_REQ + FLUSH、RQ 0x9C）、UD 的 Q_Key 校验与 40B
//   GRH、SRQ 3 SGE 走 SGB。
// 依赖：rdma_drv_data_test。
// 所有权：同 rdma_drv_data_test。
// 生命周期：run_phase 内建立并运行到结束。

class rdma_drv_reliability_test extends rdma_drv_data_test;
  `uvm_component_utils(rdma_drv_reliability_test)

  // 先错后对的 UD 发送 Q_Key（B 的 UD QP Q_Key 为 0x22220002）。
  bit [31:0] ud_qkeys[2];

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传。
  // 失败/边界：无。
  function new(string name = "rdma_drv_reliability_test", uvm_component parent = null);
    super.new(name, parent);
    ud_qkeys = '{32'h2222_0003, 32'h2222_0002};
  endfunction

  // 功能：依次执行各用例（RC QP 的 RTO 编码 3 = 32.768us，见 connect_qp）。
  // 输入/输出及副作用：见各用例。
  // 失败/边界：以 UVM_ERROR/FATAL 报告。
  virtual task run_cases();
    check_request_drop();
    check_ack_drop();
    check_rnr();
    check_ud();
    check_srq_sgb();
    check_urc_sq_abnormal();
    check_urc_rq_abnormal();
    check_urc_aeqe();
  endtask

  // 功能：断言 B 在 20us 内没有新的完成。
  // 输入/输出及副作用：轮询 B 的 CQ。
  // 失败/边界：有完成报告 UVM_ERROR。
  task expect_b_idle(string label);
    rdma_drv_wc wcs[$];
    rdma_status status;

    #20us;
    rdma_drv_wr::poll_cq(b.drv, b.cq, 4, wcs, status);
    expect_ok("poll idle", status);
    if (wcs.size() != 0)
      `uvm_error(label, $sformatf("%0d unexpected completions on B", wcs.size()))
  endtask

  // 功能：3 包 SEND 的第 2 包被丢：B 对第 3 包回 PSN 序列 NAK（期望 PSN = 第 2 包），A 只重发第 2、
  //   3 包（发往 B 共 5 包），两端各一个成功完成，数据一致，B 无多余完成。
  // 输入/输出及副作用：丢 1 包。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_request_drop();
    rdma_bytes_t data;
    rdma_drv_wc wc;
    longint unsigned rwr;
    int unsigned to_b;

    data = fill(a, 0, 2500, 8'h17);
    post_recv(b, '{4096}, '{4096}, rwr);
    to_b = link.sent_to[b.mac];
    link.drop_after[b.mac] = 1;
    link.drops[b.mac] = 1;
    send_and_wait("request drop", send_wr(a, RDMA_DRV_WR_SEND, '{0}, '{2500}));
    expect_recv("request drop rq", rwr, wc);
    expect_mem("request drop data", b, 4096, data);
    if (link.dropped != 1 || wc.byte_len != 2500 || link.sent_to[b.mac] - to_b != 5)
      `uvm_error("request drop", $sformatf("dropped %0d, byte_len %0d, packets to B %0d",
                                           link.dropped, wc.byte_len,
                                           link.sent_to[b.mac] - to_b))
    expect_b_idle("request drop");
  endtask

  // 功能：B→A 的响应被丢，A 等满 RTO（32.768us）后重发，B 按重复请求处理：SEND 只消费一个 RQE（第二个 RQE 留给
  //   下一条 SEND）；2 段 READ 的第 2 段响应被丢，A 只对第 2 段重新请求（发往 B 共 2 个请求，回 A
  //   共 3 个响应）；FAA 回缓存的原值且目标只加一次。
  // 输入/输出及副作用：每项丢 1 包。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_ack_drop();
    rdma_bytes_t data;
    rdma_bytes_t init;
    rdma_bytes_t sum;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    longint unsigned rwr[2];
    int unsigned to_a;
    int unsigned to_b;
    time started;

    data = fill(a, 'h100, 64, 8'h27);
    post_recv(b, '{'h1000}, '{'h100}, rwr[0]);
    post_recv(b, '{'h1100}, '{'h100}, rwr[1]);
    link.drops[a.mac] = 1;
    started = $time;
    send_and_wait("ACK drop", send_wr(a, RDMA_DRV_WR_SEND, '{'h100}, '{64}));
    if ($time - started < 32768ns || $time - started >= 34us)
      `uvm_error("ACK drop", $sformatf("completed after %0t, expected one 32.768us RTO",
                                       $time - started))
    expect_recv("ACK drop rq", rwr[0], wc);
    expect_mem("ACK drop data", b, 'h1000, data);
    expect_b_idle("ACK drop");
    data = fill(a, 'h200, 32, 8'h37);
    send_and_wait("after ACK drop", send_wr(a, RDMA_DRV_WR_SEND, '{'h200}, '{32}));
    expect_recv("after ACK drop rq", rwr[1], wc);
    expect_mem("after ACK drop data", b, 'h1100, data);
    data = fill(b, 'h2000, 2000, 8'h47);
    to_a = link.sent_to[a.mac];
    to_b = link.sent_to[b.mac];
    link.drop_after[a.mac] = 1;
    link.drops[a.mac] = 1;
    wr = send_wr(a, RDMA_DRV_WR_READ, '{'h2800}, '{2000});
    wr.remote_va = b.data_buf.iova + 'h2000;
    wr.rkey = b.mr.key();
    send_and_wait("READ response drop", wr);
    expect_mem("READ response drop data", a, 'h2800, data);
    if (link.sent_to[a.mac] - to_a != 3 || link.sent_to[b.mac] - to_b != 2)
      `uvm_error("READ response drop", $sformatf("responses to A %0d, requests to B %0d",
                                                 link.sent_to[a.mac] - to_a,
                                                 link.sent_to[b.mac] - to_b))
    init = rdma_be::zeros(8);
    init[0] = 8'h40;
    expect_ok("seed FAA", b.drv.hw.write(b.data_buf, 'h3800, init));
    link.drops[a.mac] = 1;
    wr = send_wr(a, RDMA_DRV_WR_FAA, '{'h3900}, '{8});
    wr.remote_va = b.data_buf.iova + 'h3800;
    wr.rkey = b.mr.key();
    wr.compare_add = 3;
    send_and_wait("ATOMIC ACK drop", wr);
    expect_mem("ATOMIC ACK drop orig", a, 'h3900, init);
    sum = rdma_be::zeros(8);
    sum[0] = 8'h43;
    expect_mem("ATOMIC ACK drop target", b, 'h3800, sum);
    if (link.dropped != 4)
      `uvm_error("ACK drop", $sformatf("dropped %0d, expected 4", link.dropped))
  endtask

  // 功能：B 无 RQE 时 SEND 得到 RNR NAK，2us 后 B 投 RECV，A 的 RNR 重试成功；另一对 QP 上 B 始终
  //   不投 RECV，RNR 重试（RNR_RETRY_TH=6）耗尽得到 vendor 0xB7，耗时为 6 次 RNR 定时器（编码 1 =
  //   10us，由 B 的 QPC LOCAL_RNR_CODE 经 NAK 带给 A）。
  // 输入/输出及副作用：创建一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_rnr();
    rdma_bytes_t data;
    rdma_drv_wc wc;
    rdma_drv_wc wcs[$];
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wr;
    longint unsigned rwr;
    time started;
    time elapsed;
    rdma_status status;

    data = fill(a, 'h300, 48, 8'h57);
    fork
      begin
        #2us;
        post_recv(b, '{'h1200}, '{'h100}, rwr);
      end
    join_none
    send_and_wait("RNR retry", send_wr(a, RDMA_DRV_WR_SEND, '{'h300}, '{48}));
    expect_recv("RNR retry rq", rwr, wc);
    expect_mem("RNR retry data", b, 'h1200, data);
    make_pair(null, qa, qb);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h300}, '{48});
    started = $time;
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post RNR exhausted", status);
    wait_wcs(a, 1, wcs);
    elapsed = $time - started;
    if (elapsed < 60us || elapsed >= 65us)
      `uvm_error("RNR exhausted", $sformatf("took %0t, expected 6 x 10us", elapsed))
    expect_wc("RNR exhausted", wcs[0], wr.wr_id, 1'b0, RDMA_DRV_WC_GENERAL_ERR);
    if (wcs[0].vendor_err != RDMA_ECODE_EC_RPE_RSP_NAK_RNR_ERR_OVERTIME)
      `uvm_error("RNR exhausted", $sformatf("vendor %02h", wcs[0].vendor_err))
  endtask

  // 功能：建一个 UD QP（max SGE 4，Q_Key = qkey）并推到 RTS。
  // 输入/输出及副作用：qp 输出。
  // 失败/边界：失败报告 UVM_FATAL。
  task make_ud(rdma_drv_data_node n, bit [31:0] qkey, output rdma_drv_qp qp);
    rdma_drv_qp_init_attr init;
    rdma_drv_qp_attr attr;
    rdma_status status;

    init = rdma_drv_qp_init_attr::type_id::create("ud_attr");
    init.qp_type = RDMA_DRV_QPT_UD;
    init.pd = n.pd;
    init.send_cq = n.cq;
    init.recv_cq = n.cq;
    init.max_send_sge = 4;
    init.max_recv_sge = 4;
    rdma_drv_qp::create_qp(n.drv, init, qp, status);
    expect_ok("create UD QP", status);
    attr = rdma_drv_qp_attr::type_id::create("ud_init");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_QKEY;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.qkey = qkey;
    qp.modify(n.drv, attr, status);
    expect_ok("UD INIT", status);
    attr = rdma_drv_qp_attr::type_id::create("ud_rtr");
    attr.mask = rdma_drv_qp_attr::M_STATE;
    attr.state = RDMA_DRV_QPS_RTR;
    qp.modify(n.drv, attr, status);
    expect_ok("UD RTR", status);
    attr = rdma_drv_qp_attr::type_id::create("ud_rts");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN;
    attr.state = RDMA_DRV_QPS_RTS;
    attr.sq_psn = 0;
    qp.modify(n.drv, attr, status);
    expect_ok("UD RTS", status);
  endtask

  // 功能：UD：Q_Key 不符的 SEND 被 B 静默丢弃（qkey_drops 加一，B 无完成）；Q_Key 正确的 SEND 在
  //   接收缓冲前 40B 写 GRH（IPv4 头 0x45、总长、TTL、UDP），数据从 +40 起，byte_len = 载荷 + 40。
  // 输入/输出及副作用：创建一对 UD QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_ud();
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    rdma_bytes_t grh;
    rdma_status status;

    make_ud(a, 32'h1111_0001, qa);
    make_ud(b, 32'h2222_0002, qb);
    rwr = rdma_drv_recv_wr::type_id::create("ud_recv");
    rwr.wr_id = next_wr_id++;
    rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h3000, 'h200, b.mr.key()));
    rdma_drv_wr::post_recv(b.drv, qb, rwr, status);
    expect_ok("post UD recv", status);
    data = fill(a, 'h400, 64, 8'h67);
    foreach (ud_qkeys[k]) begin
      wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h400}, '{64});
      wr.dest_qpn = qb.qpn;
      wr.dmac = b.mac;
      wr.qkey = ud_qkeys[k];
      rdma_drv_wr::post_send(a.drv, qa, wr, status);
      expect_ok("post UD send", status);
      wait_wcs(a, 1, wcs);
      expect_wc("UD sq", wcs[0], wr.wr_id, 1'b0);
      if (k == 0)
        expect_b_idle("UD bad Q_Key");
    end
    if (b.dev.nic.qkey_drops != 1)
      `uvm_error("UD", $sformatf("qkey_drops %0d, expected 1", b.dev.nic.qkey_drops))
    wait_wcs(b, 1, wcs);
    expect_wc("UD rq", wcs[0], rwr.wr_id, 1'b1);
    if (wcs[0].byte_len != 104 || wcs[0].src_qp != qa.qpn)
      `uvm_error("UD", $sformatf("byte_len %0d src_qp %0d", wcs[0].byte_len, wcs[0].src_qp))
    expect_mem("UD data", b, 'h3000 + 40, data);
    grh = rdma_be::zeros(40);
    grh[20] = 8'h45;
    grh[23] = 8'd116;
    grh[28] = 8'd64;
    grh[29] = 8'd17;
    expect_mem("UD GRH", b, 'h3000, grh);
  endtask

  // 功能：SRQ 上 3 个 SGE 的 RECV 写入 SGB（签名），SEND 0xA0 字节按 SGE 切分写入 B。
  // 输入/输出及副作用：创建 SRQ 与一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_srq_sgb();
    rdma_drv_srq srq;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    rdma_status status;

    rdma_drv_srq::create_srq(b.drv, b.pd, 16, 0, srq, status);
    expect_ok("create SRQ", status);
    make_pair(srq, qa, qb);
    rwr = rdma_drv_recv_wr::type_id::create("srq_sgb_recv");
    rwr.wr_id = next_wr_id++;
    for (int k = 0; k < 3; k++)
      rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h3400 + k * 'h100, 'h40,
                                            b.mr.key()));
    rdma_drv_wr::post_srq_recv(b.drv, srq, rwr, status);
    expect_ok("post SRQ SGB recv", status);
    data = fill(a, 'h500, 'ha0, 8'h77);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h500}, '{'ha0});
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post SEND to SRQ SGB", status);
    wait_wcs(a, 1, wcs);
    expect_wc("SRQ SGB sq", wcs[0], wr.wr_id, 1'b0);
    wait_wcs(b, 1, wcs);
    expect_wc("SRQ SGB rq", wcs[0], rwr.wr_id, 1'b1);
    expect_mem("SRQ SGB part 0", b, 'h3400, rdma_be::slice(data, 0, 'h40));
    expect_mem("SRQ SGB part 1", b, 'h3500, rdma_be::slice(data, 'h40, 'h40));
    expect_mem("SRQ SGB part 2", b, 'h3600, rdma_be::slice(data, 'h80, 'h20));
  endtask

  // 功能：rc_to_urc 下建一对 URC QP（各用新建的 64 深 CQ）。
  // 输入/输出及副作用：ua/ub/qa/qb 输出。
  // 失败/边界：失败报告 UVM_FATAL。
  task make_urc_pair(output rdma_drv_cq ua, output rdma_drv_cq ub, output rdma_drv_qp qa,
                     output rdma_drv_qp qb);
    rdma_status status;

    rdma_drv_cq::create_cq(a.drv, 64, 0, ua, status);
    expect_ok("create URC CQ on A", status);
    rdma_drv_cq::create_cq(b.drv, 64, 0, ub, status);
    expect_ok("create URC CQ on B", status);
    a.drv.cfg.rc_to_urc = 1'b1;
    b.drv.cfg.rc_to_urc = 1'b1;
    make_pair(null, qa, qb, ua, ub);
    a.drv.cfg.rc_to_urc = 1'b0;
    b.drv.cfg.rc_to_urc = 1'b0;
  endtask

  // 功能：URC SQ 异常：A 先发一个成功的 WRITE，再发错 rkey 的 WRITE 与一个 SEND；B 回 REMOTE_ACCESS
  //   NAK，A 设备上报 SQ ABNML CEQE 并停止该 SQ；A 依次得到 SUCCESS、REM_ACCESS_ERR、FLUSH_ERR。
  // 输入/输出及副作用：创建一对 URC QP 与 CQ。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_urc_sq_abnormal();
    rdma_drv_cq ua;
    rdma_drv_cq ub;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wrs[3];
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    rdma_status status;

    make_urc_pair(ua, ub, qa, qb);
    data = fill(a, 'h600, 32, 8'h87);
    wrs[0] = send_wr(a, RDMA_DRV_WR_WRITE, '{'h600}, '{32});
    wrs[0].remote_va = b.data_buf.iova + 'h3700;
    wrs[0].rkey = b.mr.key();
    wrs[1] = send_wr(a, RDMA_DRV_WR_WRITE, '{'h600}, '{32});
    wrs[1].remote_va = b.data_buf.iova + 'h3700;
    wrs[1].rkey = b.mr.key() ^ 32'h1;
    wrs[2] = send_wr(a, RDMA_DRV_WR_SEND, '{'h600}, '{32});
    foreach (wrs[k]) begin
      rdma_drv_wr::post_send(a.drv, qa, wrs[k], status);
      expect_ok("post URC abnormal", status);
    end
    wait_urc(a, ua, 3, wcs);
    expect_wc("URC ok before abnormal", wcs[0], wrs[0].wr_id, 1'b0);
    expect_wc("URC SQ abnormal", wcs[1], wrs[1].wr_id, 1'b0, RDMA_DRV_WC_REM_ACCESS_ERR);
    expect_wc("URC SQ flush", wcs[2], wrs[2].wr_id, 1'b0, RDMA_DRV_WC_FLUSH_ERR);
    if (wcs[1].vendor_err != RDMA_ECODE_EC_RPE_NAK_FATAL_ERR)
      `uvm_error("URC SQ abnormal", $sformatf("vendor %02h", wcs[1].vendor_err))
    expect_mem("URC write before abnormal", b, 'h3700, data);
  endtask

  // 功能：URC RQ 异常：B 的 RECV 只有 16B，A SEND 64B；B 设备上报 RQ ABNML CEQE（0x9C）并回
  //   INVALID_REQUEST NAK；B 得到 vendor 0x9C 的接收错误，A 得到 REM_INV_REQ_ERR。
  // 输入/输出及副作用：创建一对 URC QP 与 CQ。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_urc_rq_abnormal();
    rdma_drv_cq ua;
    rdma_drv_cq ub;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t scratch;
    rdma_status status;

    make_urc_pair(ua, ub, qa, qb);
    rwr = rdma_drv_recv_wr::type_id::create("urc_small_recv");
    rwr.wr_id = next_wr_id++;
    rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h3800, 'h10, b.mr.key()));
    rdma_drv_wr::post_recv(b.drv, qb, rwr, status);
    expect_ok("post URC small recv", status);
    scratch = fill(a, 'h700, 64, 8'h97);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h700}, '{64});
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post URC oversized SEND", status);
    wait_urc(b, ub, 1, wcs);
    expect_wc("URC RQ abnormal", wcs[0], rwr.wr_id, 1'b1, RDMA_DRV_WC_GENERAL_ERR);
    if (wcs[0].vendor_err != RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC)
      `uvm_error("URC RQ abnormal", $sformatf("vendor %02h", wcs[0].vendor_err))
    wait_urc(a, ua, 1, wcs);
    expect_wc("URC requester of RQ abnormal", wcs[0], wr.wr_id, 1'b0,
              RDMA_DRV_WC_REM_INV_REQ_ERR);
  endtask

  // 功能：URC 异常经 AEQ：A 设备改走 AEQE 上报；错 rkey 的 WRITE 后跟一个 SEND。驱动处理 AEQ 时记入
  //   SQ frag 的异常信息并把 QP 转 ERR，A 得到 REM_ACCESS_ERR 与 FLUSH_ERR，AEQ 记录 {0xB9, QPN}。
  // 输入/输出及副作用：创建一对 URC QP 与 CQ；临时切换 A 设备的上报通道。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_urc_aeqe();
    rdma_drv_cq ua;
    rdma_drv_cq ub;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wrs[2];
    rdma_drv_wc wcs[$];
    bit [31:0] events[$];
    rdma_status status;

    make_urc_pair(ua, ub, qa, qb);
    a.dev.nic.urc_abnormal_via_aeq = 1'b1;
    wrs[0] = send_wr(a, RDMA_DRV_WR_WRITE, '{'h600}, '{32});
    wrs[0].remote_va = b.data_buf.iova + 'h3700;
    wrs[0].rkey = b.mr.key() ^ 32'h1;
    wrs[1] = send_wr(a, RDMA_DRV_WR_SEND, '{'h600}, '{32});
    foreach (wrs[k]) begin
      rdma_drv_wr::post_send(a.drv, qa, wrs[k], status);
      expect_ok("post URC AEQE", status);
    end
    for (int t = 0; t < 200 && events.size() == 0; t++) begin
      #100ns;
      rdma_drv_wr::process_aeq(a.drv, events, status);
      expect_ok("process AEQ", status);
    end
    a.dev.nic.urc_abnormal_via_aeq = 1'b0;
    if (events.size() != 1 || events[0] != {RDMA_ECODE_EC_RPE_NAK_FATAL_ERR, 24'(qa.qpn)} ||
        qa.cur_state != RDMA_DRV_QPS_ERR)
      `uvm_error("URC AEQE", $sformatf("AEQ events %p, QP state %s", events,
                                       qa.cur_state.name()))
    wait_urc(a, ua, 2, wcs);
    expect_wc("URC AEQE abnormal", wcs[0], wrs[0].wr_id, 1'b0, RDMA_DRV_WC_REM_ACCESS_ERR);
    expect_wc("URC AEQE flush", wcs[1], wrs[1].wr_id, 1'b0, RDMA_DRV_WC_FLUSH_ERR);
  endtask
endclass
