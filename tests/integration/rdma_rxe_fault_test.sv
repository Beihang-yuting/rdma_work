// 目录：集成测试层 integration/rdma_rxe_fault_test.sv。
// 层：集成测试（需宿主机 Soft-RoCE）。
// 职责：在 rdma_rxe_test 的链路/对端之上与 Linux Soft-RoCE 互打 UD、SRQ、RNR、丢包与错误场景，每组用
//   新建的 QP 对（各自 CQ）：
//   - UD：双向 SEND（接收方缓冲前 40B 为 GRH、src_qp 为对端 QPN）；Q_Key 不符的 UD 报文被设备静默丢弃；
//     多 SGE：仿真 UD 发送从 3 个 SGE 收集，UD 接收把 GRH 与数据散写到 3 个 SGE。
//   - SRQ：仿真 RC QP 绑定 SRQ，rxe 的 SEND 依次消费 SRQ WQE；rxe RC QP 绑定 rxe 的 SRQ，仿真的 SEND（含
//     多包）依次消费 rxe SRQ WQE。
//   - RNR：rxe→仿真无 RECV 时设备回 RNR NAK（定时器编码 = 本端 min_rnr），rxe 按定时器重试成功；
//     仿真→rxe 收到 rxe 的 RNR NAK 后设备按定时器重试成功；RNR 重试耗尽为 vendor 0xB7。
//   - 丢包（链路注入）：仿真→rxe 中间包丢失，rxe 回 PSN 序列 NAK，设备从 NAK PSN 续传；rxe→仿真中间包
//     丢失，设备回 PSN 序列 NAK，rxe 重传；rxe 的 ACK 丢失，设备超时重传，rxe 按重复请求重发 ACK；READ
//     响应中间包丢失，设备只重新请求缺失部分。
//   - 错误：两方向错误 rkey 的 WRITE/READ 得到 remote access NAK；超出接收缓冲的 SEND：设备回 invalid
//     request NAK（与 mlx5 等硬件一致）；rdma_rxe（5.15）把它当作接收 WQE 错误回 remote operational
//     error NAK（0x63），测试按 rxe 实际行为断言。
// 依赖：rdma_rxe_test。
// 所有权：同 rdma_rxe_test。
// 生命周期：同 rdma_rxe_test。
class rdma_rxe_fault_test extends rdma_rxe_test;
  `uvm_component_utils(rdma_rxe_fault_test)

  localparam int unsigned IBV_WC_REM_INV_REQ_ERR = 9;
  localparam int unsigned IBV_WC_REM_ACCESS_ERR = 10;
  localparam bit [31:0] UD_QKEY = 32'h1234_5678;

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_rxe_fault_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：依次运行 UD、SRQ、RNR、丢包、错误场景。
  // 输入/输出及副作用：见各组。
  // 失败/边界：以 UVM_ERROR 报告。
  virtual task run_cases();
    run_ud();
    run_ud_sge();
    run_srq();
    run_rxe_srq();
    run_rnr();
    run_loss();
    run_errors();
  endtask

  // 功能：在 log[from..] 中找 AETH syndrome 满足 (syndrome & mask) == value 的 ACK/NAK。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：没有返回 null。
  function rdma_packet find_aeth(rdma_packet log[$], int unsigned from, bit [7:0] mask,
                                 bit [7:0] value);
    for (int unsigned i = from; i < log.size(); i++)
      if (log[i].opcode inside {RDMA_NET_ACK, RDMA_NET_NAK} &&
          (log[i].aeth_syndrome & mask) == value)
        return log[i];
    return null;
  endfunction

  // 功能：推进仿真时间直到 log[from..] 出现指定 AETH，或超时。
  // 输入/输出及副作用：推进时间；pkt 输出找到的报文。
  // 失败/边界：超时输出 null。
  task wait_aeth(bit rx, int unsigned from, bit [7:0] mask, bit [7:0] value,
                 output rdma_packet pkt);
    pkt = null;
    for (int t = 0; t < POLL_LIMIT && pkt == null; t++) begin
      #1us;
      pkt = find_aeth(rx ? link.rx_log : link.tx_log, from, mask, value);
    end
  endtask

  // 功能：仿真 WR（本端缓冲 local_off 起 len 字节）。
  // 输入/输出及副作用：返回新 WR。
  // 失败/边界：无。
  function rdma_drv_send_wr sim_wr(rdma_drv_wr_opcode_e op, int unsigned local_off,
                                   int unsigned len, bit [63:0] remote_va = 0,
                                   bit [31:0] rkey = 0);
    rdma_drv_send_wr wr;

    wr = rdma_drv_send_wr::type_id::create("rxe_fault_wr");
    wr.wr_id = next_wr_id++;
    wr.opcode = op;
    wr.sges.push_back(rdma_drv_sge::make(data_buf.iova + local_off, len, mr.key()));
    wr.remote_va = remote_va;
    wr.rkey = rkey;
    return wr;
  endfunction

  // 功能：投递 WR 到当前 QP（或给定 QP）。
  // 输入/输出及副作用：写 SQ。
  // 失败/边界：失败报告 UVM_FATAL。
  task post(rdma_drv_send_wr wr, rdma_drv_qp q = null);
    rdma_status status;

    rdma_drv_wr::post_send(drv, q == null ? qp : q, wr, status);
    expect_ok("post_send", status);
  endtask

  // 功能：在当前 QP（或给定 QP、SRQ）投递一个接收缓冲（本端 off 起 len 字节）。
  // 输入/输出及副作用：写 RQ/SRQ；id 输出 wr_id。
  // 失败/边界：失败报告 UVM_FATAL。
  task post_recv_at(int unsigned off, int unsigned len, output longint unsigned id,
                    input rdma_drv_qp q = null, input rdma_drv_srq srq = null);
    rdma_drv_recv_wr rwr;
    rdma_status status;

    rwr = rdma_drv_recv_wr::type_id::create("rxe_fault_recv");
    rwr.wr_id = next_wr_id++;
    rwr.sges.push_back(rdma_drv_sge::make(data_buf.iova + off, len, mr.key()));
    if (srq != null)
      rdma_drv_wr::post_srq_recv(drv, srq, rwr, status);
    else
      rdma_drv_wr::post_recv(drv, q == null ? qp : q, rwr, status);
    expect_ok("post_recv", status);
    id = rwr.wr_id;
  endtask

  // 功能：rxe 在当前 QP 投递接收缓冲（rxe 缓冲 off 起 len 字节）。
  // 输入/输出及副作用：与对端交互；返回 wr_id。
  // 失败/边界：无。
  function longint unsigned peer_recv(int unsigned off, int unsigned len);
    longint unsigned id;

    id = next_wr_id++;
    void'(peer.cmd($sformatf("recv %0d %0d %0d %0d", peer_qpn, off, len, id)));
    return id;
  endfunction

  // 功能：rxe 在当前 QP 发 SEND（rxe 缓冲 off 起 len 字节）。
  // 输入/输出及副作用：与对端交互；返回 wr_id。
  // 失败/边界：无。
  function longint unsigned peer_send(int unsigned off, int unsigned len);
    longint unsigned id;

    id = next_wr_id++;
    void'(peer.cmd($sformatf("send %0d send %0d %0d %0d", peer_qpn, off, len, id)));
    return id;
  endfunction

  // 功能：本端缓冲 off 处与 want 比较。
  // 输入/输出及副作用：读主机内存。
  // 失败/边界：不符报告 UVM_ERROR。
  function void expect_local(string label, int unsigned off, rdma_bytes_t want);
    rdma_bytes_t got;

    expect_ok("read back", sys.nodes[0].hw.read(data_buf, off, want.size(), got));
    expect_bytes(label, got, want);
  endfunction

  // 功能：log[from..] 中 opcode 为 op 的报文数。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function int unsigned count_op(rdma_packet log[$], int unsigned from, rdma_network_opcode_e op);
    int unsigned n;

    n = 0;
    for (int unsigned i = from; i < log.size(); i++)
      if (log[i].opcode == op)
        n++;
    return n;
  endfunction

  // 功能：建仿真 UD QP（当前 CQ 换为新 CQ，Q_Key = UD_QKEY，SQ PSN 0x300）。
  // 输入/输出及副作用：q 输出。
  // 失败/边界：失败报告 UVM_FATAL。
  task make_sim_ud(output rdma_drv_qp q);
    rdma_drv_qp_init_attr init;
    rdma_drv_qp_attr attr;
    rdma_status status;

    rdma_drv_cq::create_cq(drv, 256, 0, cq, status);
    expect_ok("UD CQ", status);
    init = rdma_drv_qp_init_attr::type_id::create("rxe_ud_attr");
    init.qp_type = RDMA_DRV_QPT_UD;
    init.pd = pd;
    init.send_cq = cq;
    init.recv_cq = cq;
    init.max_send_sge = 4;
    init.max_recv_sge = 4;
    rdma_drv_qp::create_qp(drv, init, q, status);
    expect_ok("UD QP", status);
    attr = rdma_drv_qp_attr::type_id::create("rxe_ud_init");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_QKEY;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.qkey = UD_QKEY;
    q.modify(drv, attr, status);
    expect_ok("UD INIT", status);
    attr = rdma_drv_qp_attr::type_id::create("rxe_ud_rtr");
    attr.mask = rdma_drv_qp_attr::M_STATE;
    attr.state = RDMA_DRV_QPS_RTR;
    q.modify(drv, attr, status);
    expect_ok("UD RTR", status);
    attr = rdma_drv_qp_attr::type_id::create("rxe_ud_rts");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN;
    attr.state = RDMA_DRV_QPS_RTS;
    attr.sq_psn = 24'h300;
    q.modify(drv, attr, status);
    expect_ok("UD RTS", status);
  endtask

  // 功能：UD 双向；rxe 发 Q_Key 不符的 UD 报文被设备静默丢弃（不消费 RECV）。
  // 输入/输出及副作用：创建一对 UD QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task run_ud();
    rdma_drv_qp ud;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_bytes_t data;
    string reply;
    string sim_ip;
    int unsigned pud;
    int unsigned drops;
    longint unsigned rid;
    longint unsigned sid;

    peer_drain();
    sim_ip = arg("RXE_SIM_IP", "10.79.0.1");
    make_sim_ud(ud);
    pud = rdma_rxe_peer::field(peer.cmd("qp ud"), "qpn");
    void'(peer.cmd($sformatf("ud_ready %0d 0x%0h 0x400", pud, UD_QKEY)));
    rid = next_wr_id++;
    void'(peer.cmd($sformatf("recv %0d 0x8000 1064 %0d", pud, rid)));
    data = pattern(200, 21);
    expect_ok("fill", sys.nodes[0].hw.write(data_buf, 'h400, data));
    wr = sim_wr(RDMA_DRV_WR_SEND, 'h400, 200);
    wr.dest_qpn = pud;
    wr.dmac = rxe_mac;
    wr.qkey = UD_QKEY;
    post(wr, ud);
    wait_sim("UD sim->rxe send", wr.wr_id, wc);
    wait_peer("UD sim->rxe recv", rid, reply);
    if (rdma_rxe_peer::field(reply, "len") != 240 ||
        rdma_rxe_peer::field(reply, "src_qp") != ud.qpn)
      `uvm_error("UD sim->rxe", {"rxe completion ", reply})
    expect_bytes("UD sim->rxe data", peer_rbuf('h8000 + 40, 200), data);
    post_recv_at('h6000, 'h1000, rid, ud);
    drops = sys.nodes[0].dev.nic.qkey_drops;
    data = pattern(300, 33);
    void'(peer.cmd({"wbuf 0x1000 ", hex_of(data)}));
    sid = next_wr_id++;
    void'(peer.cmd($sformatf("send_ud %0d 0x1000 300 %0d %s %0d 0x99", pud, sid, sim_ip,
                             ud.qpn)));
    wait_peer("UD bad Q_Key send", sid, reply);
    #20us;
    if (sys.nodes[0].dev.nic.qkey_drops != drops + 1)
      `uvm_error("UD bad Q_Key", $sformatf("qkey_drops %0d, expected %0d",
                                           sys.nodes[0].dev.nic.qkey_drops, drops + 1))
    sid = next_wr_id++;
    void'(peer.cmd($sformatf("send_ud %0d 0x1000 300 %0d %s %0d 0x%0h", pud, sid, sim_ip,
                             ud.qpn, UD_QKEY)));
    wait_sim("UD rxe->sim recv", rid, wc);
    wait_peer("UD rxe->sim send", sid, reply);
    if (wc != null && (wc.byte_len != 340 || wc.src_qp != pud))
      `uvm_error("UD rxe->sim", $sformatf("byte_len %0d src_qp %0d", wc.byte_len, wc.src_qp))
    expect_local("UD rxe->sim data", 'h6000 + 40, data);
  endtask

  // 功能：UD 多 SGE：仿真→rxe 的 UD SEND 从本端 3 个不连续 SGE（100+50+70B）收集，rxe 收到其拼接；
  //   rxe→仿真的 300B UD SEND 进入 3 个 SGE 的接收 WQE（64+100+200B）：GRH 占第一个 SGE 的前 40B，
  //   数据依次散写 24/100/176B。
  // 输入/输出及副作用：创建一对 UD QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task run_ud_sge();
    rdma_drv_qp ud;
    rdma_drv_send_wr wr;
    rdma_drv_recv_wr rwr;
    rdma_drv_wc wc;
    rdma_bytes_t data;
    rdma_bytes_t part;
    rdma_status status;
    string reply;
    int unsigned pud;
    int unsigned offs[3];
    int unsigned lens[3];
    int unsigned at;
    longint unsigned rid;
    longint unsigned sid;

    peer_drain();
    make_sim_ud(ud);
    pud = rdma_rxe_peer::field(peer.cmd("qp ud"), "qpn");
    void'(peer.cmd($sformatf("ud_ready %0d 0x%0h 0x500", pud, UD_QKEY)));
    offs = '{'h400, 'h900, 'he00};
    lens = '{100, 50, 70};
    data = new[0];
    wr = sim_wr(RDMA_DRV_WR_SEND, offs[0], lens[0]);
    foreach (offs[k]) begin
      part = pattern(lens[k], 100 + k);
      expect_ok("fill", sys.nodes[0].hw.write(data_buf, offs[k], part));
      data = {data, part};
      if (k > 0)
        wr.sges.push_back(rdma_drv_sge::make(data_buf.iova + offs[k], lens[k], mr.key()));
    end
    wr.dest_qpn = pud;
    wr.dmac = rxe_mac;
    wr.qkey = UD_QKEY;
    rid = next_wr_id++;
    void'(peer.cmd($sformatf("recv %0d 0x8000 1064 %0d", pud, rid)));
    post(wr, ud);
    wait_sim("UD SGE sim->rxe send", wr.wr_id, wc);
    wait_peer("UD SGE sim->rxe recv", rid, reply);
    if (rdma_rxe_peer::field(reply, "len") != 40 + data.size())
      `uvm_error("UD SGE sim->rxe", {"rxe completion ", reply})
    expect_bytes("UD SGE sim->rxe data", peer_rbuf('h8000 + 40, data.size()), data);
    offs = '{'h6000, 'h6800, 'h7000};
    lens = '{64, 100, 200};
    rwr = rdma_drv_recv_wr::type_id::create("rxe_ud_sge_recv");
    rwr.wr_id = next_wr_id++;
    foreach (offs[k])
      rwr.sges.push_back(rdma_drv_sge::make(data_buf.iova + offs[k], lens[k], mr.key()));
    rdma_drv_wr::post_recv(drv, ud, rwr, status);
    expect_ok("post UD SGE recv", status);
    data = pattern(300, 77);
    void'(peer.cmd({"wbuf 0x1000 ", hex_of(data)}));
    sid = next_wr_id++;
    void'(peer.cmd($sformatf("send_ud %0d 0x1000 300 %0d %s %0d 0x%0h", pud, sid,
                             arg("RXE_SIM_IP", "10.79.0.1"), ud.qpn, UD_QKEY)));
    wait_sim("UD SGE rxe->sim recv", rwr.wr_id, wc);
    wait_peer("UD SGE rxe->sim send", sid, reply);
    if (wc != null && (wc.byte_len != 340 || wc.src_qp != pud))
      `uvm_error("UD SGE rxe->sim", $sformatf("byte_len %0d src_qp %0d", wc.byte_len, wc.src_qp))
    at = 0;
    foreach (offs[k]) begin
      int unsigned skip;
      int unsigned n;

      skip = (k == 0) ? 40 : 0;
      n = lens[k] - skip;
      if (n > data.size() - at)
        n = data.size() - at;
      expect_local($sformatf("UD SGE rxe->sim sge %0d", k), offs[k] + skip,
                   rdma_be::slice(data, at, n));
      at += n;
    end
  endtask

  // 功能：rxe RC QP 绑定 rxe 进程的 SRQ（16 个 WQE），仿真的 600B 与 2500B（3 包）SEND 依次消费 rxe 投递的
  //   两个 SRQ WQE，rxe 完成的 wr_id 为 SRQ WQE 的 wr_id、qp 为该 QP。
  // 输入/输出及副作用：创建 rxe SRQ 与 QP 对。
  // 失败/边界：不符报告 UVM_ERROR。
  task run_rxe_srq();
    rdma_drv_send_wr wr[2];
    rdma_drv_wc wc;
    rdma_bytes_t data[2];
    string reply;
    longint unsigned rid[2];

    void'(peer.cmd("srq 16"));
    make_pair("rxe_srq", 0, 7, 7, null, 7, 1'b1);
    foreach (rid[k]) begin
      rid[k] = next_wr_id++;
      void'(peer.cmd($sformatf("srq_recv %0d 4096 %0d", 'h4000 + 'h1000 * k, rid[k])));
    end
    foreach (data[k]) begin
      data[k] = pattern(k == 0 ? 600 : 2500, 120 + k);
      expect_ok("fill", sys.nodes[0].hw.write(data_buf, 'h1000 * k, data[k]));
      wr[k] = sim_wr(RDMA_DRV_WR_SEND, 'h1000 * k, data[k].size());
      post(wr[k]);
    end
    foreach (data[k]) begin
      wait_sim($sformatf("rxe SRQ send %0d", k), wr[k].wr_id, wc);
      wait_peer($sformatf("rxe SRQ recv %0d", k), rid[k], reply);
      if (rdma_rxe_peer::field(reply, "len") != data[k].size() ||
          rdma_rxe_peer::field(reply, "qp") != peer_qpn)
        `uvm_error("rxe SRQ", {"rxe completion ", reply})
      expect_bytes($sformatf("rxe SRQ data %0d", k), peer_rbuf('h4000 + 'h1000 * k,
                   data[k].size()), data[k]);
    end
  endtask

  // 功能：仿真 RC QP 绑定 SRQ，rxe 两个 SEND 依次消费 SRQ 的两个 WQE。
  // 输入/输出及副作用：创建 SRQ 与 QP 对。
  // 失败/边界：不符报告 UVM_ERROR。
  task run_srq();
    rdma_drv_srq srq;
    rdma_drv_wc wc;
    rdma_bytes_t data[2];
    rdma_status status;
    string reply;
    longint unsigned rid[2];
    longint unsigned sid[2];

    rdma_drv_srq::create_srq(drv, pd, 16, 0, srq, status);
    expect_ok("create SRQ", status);
    make_pair("srq", 0, 7, 7, srq);
    post_recv_at('h6000, 'h800, rid[0], null, srq);
    post_recv_at('h7000, 'h800, rid[1], null, srq);
    foreach (data[k]) begin
      data[k] = pattern(700 + 500 * k, 40 + k);
      void'(peer.cmd($sformatf("wbuf 0x%0h %s", 'h1000 + 'h1000 * k, hex_of(data[k]))));
      sid[k] = peer_send('h1000 + 'h1000 * k, data[k].size());
    end
    foreach (data[k]) begin
      wait_sim($sformatf("SRQ recv %0d", k), rid[k], wc);
      wait_peer($sformatf("SRQ send %0d", k), sid[k], reply);
      if (wc != null && wc.byte_len != data[k].size())
        `uvm_error("SRQ", $sformatf("recv %0d byte_len %0d", k, wc.byte_len))
      expect_local($sformatf("SRQ data %0d", k), 'h6000 + 'h1000 * k, data[k]);
    end
  endtask

  // 功能：RNR：rxe→仿真（设备回 RNR NAK 0x21，之后投 RECV）、仿真→rxe（rxe 回 RNR NAK，设备重试，
  //   rxe 投 RECV 后完成）、RNR 重试 2 次耗尽（vendor 0xB7）。
  // 输入/输出及副作用：创建三对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task run_rnr();
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_packet nak;
    rdma_bytes_t data;
    string reply;
    int unsigned from;
    longint unsigned rid;
    longint unsigned sid;

    make_pair("rnr_rx");
    data = pattern(300, 51);
    void'(peer.cmd({"wbuf 0x1000 ", hex_of(data)}));
    from = link.tx_log.size();
    sid = peer_send('h1000, 300);
    wait_aeth(1'b0, from, 8'he0, 8'h20, nak);
    if (nak == null || nak.aeth_syndrome != 8'h21)
      `uvm_error("RNR rxe->sim", "device sent no RNR NAK with timer code 1")
    post_recv_at('h6000, 'h1000, rid);
    wait_sim("RNR rxe->sim recv", rid, wc);
    wait_peer("RNR rxe->sim send", sid, reply);
    expect_local("RNR rxe->sim data", 'h6000, data);
    make_pair("rnr_tx");
    data = pattern(400, 61);
    expect_ok("fill", sys.nodes[0].hw.write(data_buf, 'h400, data));
    from = link.rx_log.size();
    wr = sim_wr(RDMA_DRV_WR_SEND, 'h400, 400);
    post(wr);
    wait_aeth(1'b1, from, 8'he0, 8'h20, nak);
    if (nak == null)
      `uvm_error("RNR sim->rxe", "rxe sent no RNR NAK")
    rid = peer_recv(0, 4096);
    wait_sim("RNR sim->rxe send", wr.wr_id, wc);
    wait_peer("RNR sim->rxe recv", rid, reply);
    expect_bytes("RNR sim->rxe data", peer_rbuf(0, 400), data);
    make_pair("rnr_exhaust", 0, 7, 2);
    wr = sim_wr(RDMA_DRV_WR_SEND, 'h400, 64);
    post(wr);
    wait_sim("RNR exhausted", wr.wr_id, wc, RDMA_DRV_WC_GENERAL_ERR);
    if (wc != null && wc.vendor_err != RDMA_ECODE_EC_RPE_RSP_NAK_RNR_ERR_OVERTIME)
      `uvm_error("RNR exhausted", $sformatf("vendor %02h", wc.vendor_err))
  endtask

  // 功能：丢包：仿真→rxe 与 rxe→仿真 3 包 SEND 的第 2 包（PSN 序列 NAK 0x60 后续传）、rxe 的 ACK
  //   （设备超时后重发同一 SEND，共两次）、READ 3 包响应的第 2 包（设备只重新请求缺失部分，共两个
  //   READ 请求）。QP timeout 8（RTO 编码 18，约 1ms 仿真时间）。
  // 输入/输出及副作用：创建一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task run_loss();
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_bytes_t data;
    string reply;
    int unsigned from;
    int unsigned lost;
    longint unsigned rid;
    longint unsigned sid;

    make_pair("loss", 8);
    rid = peer_recv(0, 4096);
    data = pattern(3000, 71);
    expect_ok("fill", sys.nodes[0].hw.write(data_buf, 0, data));
    from = link.rx_log.size();
    link.drop_tx(2);
    wr = sim_wr(RDMA_DRV_WR_SEND, 0, 3000);
    post(wr);
    wait_sim("loss sim->rxe send", wr.wr_id, wc);
    wait_peer("loss sim->rxe recv", rid, reply);
    if (find_aeth(link.rx_log, from, 8'hff, RDMA_AETH_NAK_PSN_SEQ) == null)
      `uvm_error("loss sim->rxe", "rxe sent no PSN sequence NAK")
    expect_bytes("loss sim->rxe data", peer_rbuf(0, 3000), data);
    post_recv_at('h6000, 'h1000, rid);
    data = pattern(3000, 81);
    void'(peer.cmd({"wbuf 0x1000 ", hex_of(data)}));
    from = link.tx_log.size();
    link.drop_rx(2);
    sid = peer_send('h1000, 3000);
    wait_sim("loss rxe->sim recv", rid, wc);
    wait_peer("loss rxe->sim send", sid, reply);
    if (find_aeth(link.tx_log, from, 8'hff, RDMA_AETH_NAK_PSN_SEQ) == null)
      `uvm_error("loss rxe->sim", "device sent no PSN sequence NAK")
    expect_local("loss rxe->sim data", 'h6000, data);
    rid = peer_recv(0, 4096);
    from = link.tx_log.size();
    lost = link.rx_lost.size();
    link.drop_rx(1);
    wr = sim_wr(RDMA_DRV_WR_SEND, 0, 200);
    post(wr);
    wait_sim("loss ACK send", wr.wr_id, wc);
    wait_peer("loss ACK recv", rid, reply);
    if (count_op(link.tx_log, from, RDMA_NET_SEND) != 2 || link.rx_lost.size() != lost + 1)
      `uvm_error("loss ACK", $sformatf("%0d SEND transmissions, expected 2",
                                       count_op(link.tx_log, from, RDMA_NET_SEND)))
    data = pattern(3000, 91);
    void'(peer.cmd({"wbuf 0x8000 ", hex_of(data)}));
    from = link.tx_log.size();
    link.drop_rx(2);
    wr = sim_wr(RDMA_DRV_WR_READ, 'h3000, 3000, peer_addr + 'h8000, peer_rkey);
    post(wr);
    wait_sim("loss READ", wr.wr_id, wc);
    expect_local("loss READ data", 'h3000, data);
    if (count_op(link.tx_log, from, RDMA_NET_RDMA_READ_REQUEST) != 2)
      `uvm_error("loss READ", $sformatf("%0d READ requests, expected 2",
                                        count_op(link.tx_log, from, RDMA_NET_RDMA_READ_REQUEST)))
  endtask

  // 功能：错误（每例新 QP 对）：仿真 WRITE/READ 错误 rkey（REM_ACCESS）、仿真 SEND 超出 rxe 接收缓冲
  //   （rxe 回 NAK 0x63，REM_OP）；rxe WRITE/READ 错误 rkey（设备回 NAK 0x62，rxe 状态 10）、rxe SEND 超出仿真
  //   接收缓冲（设备回 NAK 0x61，rxe 状态 9，仿真接收完成为错误）。
  // 输入/输出及副作用：创建六对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task run_errors();
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    string reply;
    int unsigned from;
    longint unsigned rid;
    longint unsigned sid;

    make_pair("err_write");
    wr = sim_wr(RDMA_DRV_WR_WRITE, 0, 128, peer_addr + 'h4000, peer_rkey + 32'h100);
    post(wr);
    wait_sim("sim WRITE bad rkey", wr.wr_id, wc, RDMA_DRV_WC_REM_ACCESS_ERR);
    make_pair("err_read");
    wr = sim_wr(RDMA_DRV_WR_READ, 'h3000, 128, peer_addr + 'h8000, peer_rkey + 32'h100);
    post(wr);
    wait_sim("sim READ bad rkey", wr.wr_id, wc, RDMA_DRV_WC_REM_ACCESS_ERR);
    make_pair("err_send");
    rid = peer_recv(0, 256);
    wr = sim_wr(RDMA_DRV_WR_SEND, 0, 600);
    post(wr);
    wait_sim("sim SEND too long", wr.wr_id, wc, RDMA_DRV_WC_REM_OP_ERR);
    make_pair("err_rxe_write");
    from = link.tx_log.size();
    sid = next_wr_id++;
    void'(peer.cmd($sformatf("send %0d write 0x2000 128 %0d 0x%0h 0x%0h", peer_qpn, sid,
                             data_buf.iova + 'h8000, mr.key() + 32'h100)));
    wait_peer("rxe WRITE bad rkey", sid, reply, IBV_WC_REM_ACCESS_ERR);
    if (find_aeth(link.tx_log, from, 8'hff, RDMA_AETH_NAK_REMOTE_ACCESS) == null)
      `uvm_error("rxe WRITE bad rkey", "device sent no remote access NAK")
    make_pair("err_rxe_read");
    sid = next_wr_id++;
    void'(peer.cmd($sformatf("send %0d read 0xc000 128 %0d 0x%0h 0x%0h", peer_qpn, sid,
                             data_buf.iova + 'h9000, mr.key() + 32'h100)));
    wait_peer("rxe READ bad rkey", sid, reply, IBV_WC_REM_ACCESS_ERR);
    make_pair("err_rxe_send");
    post_recv_at('h6000, 256, rid);
    from = link.tx_log.size();
    sid = peer_send('h1000, 600);
    wait_peer("rxe SEND too long", sid, reply, IBV_WC_REM_INV_REQ_ERR);
    wait_sim("rxe SEND too long recv", rid, wc, RDMA_DRV_WC_GENERAL_ERR);
    if (find_aeth(link.tx_log, from, 8'hff, RDMA_AETH_NAK_INVALID_REQUEST) == null)
      `uvm_error("rxe SEND too long", "device sent no invalid request NAK")
  endtask
endclass
