// 目录：集成测试层 integration/rdma_rxe_test.sv。
// 层：集成测试（需宿主机 Soft-RoCE）。
// 职责：仿真 RDMA（驱动模型 + 设备模型）与 Linux Soft-RoCE（rdma_rxe）经 TAP 互打，验证业务流程与
//   RoCEv2 线上协议：设备发出的帧经 net_packet 编码（ICRC、pad、AckReq），rxe 接受并执行；rxe 的帧
//   经解码交给设备。双向覆盖 SEND（单包/多包/立即数）、WRITE（含立即数）、READ、FETCH_ADD、CMP_SWAP，
//   检查两端完成状态、立即数与内存数据，以及链路上没有被丢弃的帧。子类 rdma_rxe_fault_test 复用
//   本类的链路、对端与 QP 对建立（make_pair）覆盖 UD、SRQ、RNR、丢包与错误场景。
// 前置：tools/rxe/rxe_tap_setup.sh up（TAP + rxe 设备）；+RXE_PEER=<rxe_peer 路径>。
//   可选：+RXE_TAP（rtap0）、+RXE_DEV（rxe_rtap0）、+RXE_GID（1）、+RXE_IP（10.79.0.2）、
//   +RXE_SIM_IP（10.79.0.1）、+RXE_SIM_MAC（02:00:00:00:79:01，须与 setup 的静态邻居一致）、
//   +RXE_WAIT_US（链路空闲时每 100ns 仿真时间等待 rxe 的真实时间上限，默认 20）。
// 依赖：rdma_rxe_pkg、rdma_net_packet_adapter_pkg、rdma_dpu_test_system。
// 所有权：测试拥有 dpu 系统、链路与对端进程。
// 生命周期：build_phase 建 dpu 系统，run_phase 建链路/对端并运行，结束时关闭。
class rdma_rxe_test extends uvm_test;
  `uvm_component_utils(rdma_rxe_test)

  localparam int unsigned BUF_BYTES = 65536;
  localparam int unsigned POLL_LIMIT = 5000;

  rdma_dpu_system sys;
  rdma_rxe_link link;
  rdma_rxe_peer peer;
  rdma_drv_dev drv;
  rdma_drv_pd pd;
  rdma_drv_cq cq;
  rdma_drv_dma data_buf;
  rdma_drv_mr mr;
  rdma_drv_qp qp;
  bit [63:0] peer_addr;
  bit [31:0] peer_rkey;
  int unsigned peer_qpn;
  bit [47:0] rxe_mac;
  longint unsigned next_wr_id;

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_rxe_test", uvm_component parent = null);
    super.new(name, parent);
    next_wr_id = 1;
  endfunction

  // 功能：断言 status 成功。
  // 输入/输出及副作用：what 用于报告。
  // 失败/边界：失败报告 UVM_FATAL。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("RXE", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：字符串 plusarg，缺省取 fallback。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function string arg(string name, string fallback);
    string value;

    if ($value$plusargs({name, "=%s"}, value))
      return value;
    return fallback;
  endfunction

  // 功能：点分 IPv4 → 32 位。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：格式错误报告 UVM_FATAL。
  function bit [31:0] ip_of(string text);
    int a, b, c, d;

    if ($sscanf(text, "%d.%d.%d.%d", a, b, c, d) != 4)
      `uvm_fatal("RXE", {"bad IPv4 address ", text})
    return {8'(a), 8'(b), 8'(c), 8'(d)};
  endfunction

  // 功能：冒号分隔 MAC → 48 位。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：格式错误报告 UVM_FATAL。
  function bit [47:0] mac_of(string text);
    int b0, b1, b2, b3, b4, b5;

    if ($sscanf(text, "%h:%h:%h:%h:%h:%h", b0, b1, b2, b3, b4, b5) != 6)
      `uvm_fatal("RXE", {"bad MAC address ", text})
    return {8'(b0), 8'(b1), 8'(b2), 8'(b3), 8'(b4), 8'(b5)};
  endfunction

  // 功能：字节 → 十六进制串。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  function string hex_of(rdma_bytes_t data);
    string s;

    s = "";
    foreach (data[i])
      s = {s, $sformatf("%02x", data[i])};
    return s;
  endfunction

  // 功能：十六进制串 → 字节。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  function rdma_bytes_t bytes_of(string hex);
    rdma_bytes_t data;

    data = new[hex.len() / 2];
    foreach (data[i])
      data[i] = hex.substr(2 * i, 2 * i + 1).atohex();
    return data;
  endfunction

  // 功能：长度 n 的样式数据。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  function rdma_bytes_t pattern(int unsigned n, int unsigned seed);
    rdma_bytes_t data;

    data = new[n];
    foreach (data[i])
      data[i] = 8'(i * 13 + seed);
    return data;
  endfunction

  // 功能：8 字节小端值。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  function rdma_bytes_t le64(bit [63:0] v);
    rdma_bytes_t b;

    b = new[8];
    foreach (b[i])
      b[i] = v >> (8 * i);
    return b;
  endfunction

  // 功能：建 Host0 PF0 的 dpu 系统（mock 内存）。
  // 输入/输出及副作用：创建 sys。
  // 失败/边界：失败报告 UVM_FATAL。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sys = rdma_dpu_test_system::single_host("rxe_sys");
  endfunction

  // 功能：链路 → probe → 资源 → 对端 → 连接，随后双向用例，最后检查链路无丢帧。
  // 输入/输出及副作用：持有 objection。
  // 失败/边界：以 UVM_ERROR/FATAL 报告。
  task run_phase(uvm_phase phase);
    rdma_status status;

    phase.raise_objection(this);
    setup_link();
    sys.probe(0, status);
    expect_ok("probe", status);
    drv = sys.nodes[0].drv;
    setup_resources();
    setup_peer();
    make_pair("base");
    run_cases();
    `uvm_info("RXE", $sformatf("frames: sim->rxe %0d, rxe->sim %0d, dropped %0d",
                               link.tx_log.size(), link.rx_log.size(), link.rx_dropped), UVM_LOW)
    if (link.rx_dropped != 0)
      `uvm_error("RXE", $sformatf("%0d frames from rxe were not decodable", link.rx_dropped))
    peer.stop();
    link.close();
    phase.drop_objection(this);
  endtask

  // 功能：双向用例（+RXE_CASES=N 只跑前 N 个，调试用）；子类覆盖为其场景。
  // 输入/输出及副作用：见各用例。
  // 失败/边界：以 UVM_ERROR 报告。
  virtual task run_cases();
    int unsigned limit;

    if (!$value$plusargs("RXE_CASES=%d", limit))
      limit = 13;
    if (limit > 0) sim_send("SEND 300B", 300, 0, 0);
    if (limit > 1) sim_send("SEND 3000B (3 packets)", 3000, 0, 0);
    if (limit > 2) sim_send("SEND_IMM 100B", 100, 1, 32'hcafe_0001);
    if (limit > 3) sim_write("WRITE 2000B", 2000, 0);
    if (limit > 4) sim_write("WRITE_IMM 64B", 64, 1);
    if (limit > 5) sim_read("READ 1500B", 1500);
    if (limit > 6) sim_atomic("FETCH_ADD", 0, 64'd100, 64'd7, 64'd0, 64'd107);
    if (limit > 7) sim_atomic("CMP_SWAP", 1, 64'd5, 64'd5, 64'd9, 64'd9);
    if (limit > 8) rxe_send("rxe SEND 2500B", 2500, 0);
    if (limit > 9) rxe_send("rxe SEND_IMM 50B", 50, 1);
    if (limit > 10) rxe_write("rxe WRITE 1500B", 1500);
    if (limit > 11) rxe_read("rxe READ 1200B", 1200);
    if (limit > 12) rxe_atomic("rxe FETCH_ADD", 64'd1000, 64'd24);
  endtask

  // 功能：打开 TAP，配置编码地址（仿真侧为源），接到 NIC 并启动 NIC 与接收进程。
  // 输入/输出及副作用：创建 link，fork 进程。
  // 失败/边界：TAP 不可用报告 UVM_FATAL。
  task setup_link();
    rdma_function_identity id;
    string tap;
    string mac_text;
    int fd;
    rdma_dev dev;

    tap = arg("RXE_TAP", "rtap0");
    fd = $fopen({"/sys/class/net/", tap, "/address"}, "r");
    if (fd == 0 || $fgets(mac_text, fd) == 0)
      `uvm_fatal("RXE", {"TAP ", tap, " not found: run tools/rxe/rxe_tap_setup.sh up"})
    $fclose(fd);
    rxe_mac = mac_of(mac_text);
    link = rdma_rxe_link::type_id::create("rxe_link");
    link.adapter = rdma_net_packet_adapter::type_id::create("rxe_adapter");
    expect_ok("identity", sys.nodes[0].func.identity(id));
    expect_ok("adapter function", link.adapter.configure_function(id));
    link.adapter.src_mac = mac_of(arg("RXE_SIM_MAC", "02:00:00:00:79:01"));
    link.adapter.dst_mac = rxe_mac;
    link.adapter.src_ip = ip_of(arg("RXE_SIM_IP", "10.79.0.1"));
    link.adapter.dst_ip = ip_of(arg("RXE_IP", "10.79.0.2"));
    if (!link.open(tap))
      `uvm_fatal("RXE", {"cannot open TAP ", tap})
    link.wait_us = arg("RXE_WAIT_US", "20").atoi();
    dev = sys.nodes[0].dev;
    link.nic = dev.nic;
    dev.nic.port = link;
    fork
      dev.nic.run();
      link.run();
    join_none
  endtask

  // 功能：PD、64KiB 数据缓冲与覆盖它的 MR（本地写、远端读写、原子）。
  // 输入/输出及副作用：创建驱动资源。
  // 失败/边界：失败报告 UVM_FATAL。
  task setup_resources();
    bit [63:0] pages[$];
    rdma_status status;

    expect_ok("alloc PD", rdma_drv_pd::alloc(drv, pd));
    expect_ok("alloc buffer", sys.nodes[0].hw.alloc_dma(BUF_BYTES, 4096, data_buf));
    for (int p = 0; p < BUF_BYTES / 4096; p++)
      pages.push_back(data_buf.iova + p * 4096);
    rdma_drv_mr::reg_mr(drv, pd, data_buf.iova, BUF_BYTES, rdma_drv_mr::rights_of(1, 1, 1, 1),
                        pages, mr, status);
    expect_ok("reg MR", status);
  endtask

  // 功能：启动 rxe_peer：打开 rxe 设备、注册 64KiB MR、建 RC QP。
  // 输入/输出及副作用：启动子进程。
  // 失败/边界：启动失败报告 UVM_FATAL。
  task setup_peer();
    string reply;

    peer = rdma_rxe_peer::type_id::create("rxe_peer");
    if (!peer.start(arg("RXE_PEER", "")))
      `uvm_fatal("RXE", "cannot start rxe_peer (+RXE_PEER=<path>)")
    void'(peer.cmd({"open ", arg("RXE_DEV", "rxe_rtap0"), " ", arg("RXE_GID", "1")}));
    reply = peer.cmd($sformatf("mr %0d", BUF_BYTES));
    peer_addr = rdma_rxe_peer::field(reply, "addr");
    peer_rkey = rdma_rxe_peer::field(reply, "rkey");
  endtask

  // 功能：新建一对 RC QP 并互连，成为当前 QP 对（qp/cq/peer_qpn）：仿真侧新 CQ（可绑 SRQ）、PMTU 1024、
  //   min_rnr 1，timeout/retry/rnr_retry 取参数（timeout 0 为不超时）；rxe 侧新 QP，timeout 14、重试 7、
  //   RNR 重试取 rxe_rnr，rxe_srq 时绑定 rxe 进程的 SRQ。PSN：仿真发 0x200 起，rxe 发 0x100 起。
  //   先清空 rxe CQ 中的残留完成。
  // 输入/输出及副作用：创建 CQ/QP，修改当前 QP 对。
  // 失败/边界：失败报告 UVM_FATAL。
  task make_pair(string tag, int unsigned timeout = 0, int unsigned retry = 7,
                 int unsigned rnr_retry = 7, rdma_drv_srq srq = null, int unsigned rxe_rnr = 7,
                 bit rxe_srq = 0);
    rdma_drv_qp_init_attr init;
    rdma_drv_qp_attr attr;
    rdma_status status;

    peer_drain();
    rdma_drv_cq::create_cq(drv, 256, 0, cq, status);
    expect_ok({tag, " CQ"}, status);
    init = rdma_drv_qp_init_attr::type_id::create({tag, "_qp_attr"});
    init.pd = pd;
    init.send_cq = cq;
    init.recv_cq = cq;
    init.srq = srq;
    rdma_drv_qp::create_qp(drv, init, qp, status);
    expect_ok({tag, " QP"}, status);
    attr = rdma_drv_qp_attr::type_id::create({tag, "_init"});
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_ACCESS;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.access = RDMA_RIGHT_REMOTE_READ | RDMA_RIGHT_REMOTE_WRITE | RDMA_RIGHT_REMOTE_ATOMIC;
    qp.modify(drv, attr, status);
    expect_ok({tag, " INIT"}, status);
    peer_qpn = rdma_rxe_peer::field(peer.cmd(rxe_srq ? "qp rc srq" : "qp rc"), "qpn");
    attr = rdma_drv_qp_attr::type_id::create({tag, "_rtr"});
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_DEST_QPN |
                rdma_drv_qp_attr::M_RQ_PSN | rdma_drv_qp_attr::M_PATH_MTU |
                rdma_drv_qp_attr::M_AV | rdma_drv_qp_attr::M_MIN_RNR;
    attr.state = RDMA_DRV_QPS_RTR;
    attr.dest_qpn = peer_qpn;
    attr.rq_psn = 24'h100;
    attr.path_mtu = 1024;
    attr.dmac = rxe_mac;
    attr.min_rnr = 1;
    qp.modify(drv, attr, status);
    expect_ok({tag, " RTR"}, status);
    attr = rdma_drv_qp_attr::type_id::create({tag, "_rts"});
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN |
                rdma_drv_qp_attr::M_TIMEOUT | rdma_drv_qp_attr::M_RETRY_CNT |
                rdma_drv_qp_attr::M_RNR_RETRY;
    attr.state = RDMA_DRV_QPS_RTS;
    attr.sq_psn = 24'h200;
    attr.timeout = timeout;
    attr.retry_cnt = retry;
    attr.rnr_retry = rnr_retry;
    qp.modify(drv, attr, status);
    expect_ok({tag, " RTS"}, status);
    void'(peer.cmd($sformatf("rc_connect %0d %0d 0x200 0x100 %s 1024 14 7 %0d", peer_qpn, qp.qpn,
                             arg("RXE_SIM_IP", "10.79.0.1"), rxe_rnr)));
  endtask

  // 功能：取走 rxe CQ 中的全部完成（上一组用例的 flush 等残留）。
  // 输入/输出及副作用：与对端交互。
  // 失败/边界：无。
  function void peer_drain();
    for (int i = 0; i < 1000 && peer.cmd("poll 0") != "OK none"; i++)
      ;
  endfunction

  // 功能：等当前 CQ 的一个完成（每次 1us 仿真时间，期间链路等待 rxe），期望状态为 want。
  // 输入/输出及副作用：wc 输出。
  // 失败/边界：超时报告 UVM_ERROR 并输出 null；wr_id 或状态不符报告 UVM_ERROR。
  task wait_sim(string label, longint unsigned wr_id, output rdma_drv_wc wc,
                input rdma_drv_wc_status_e want = RDMA_DRV_WC_SUCCESS);
    rdma_drv_wc wcs[$];
    rdma_status status;

    wc = null;
    for (int t = 0; t < POLL_LIMIT && wcs.size() == 0; t++) begin
      rdma_drv_wr::poll_cq(drv, cq, 1, wcs, status);
      expect_ok("poll_cq", status);
      if (wcs.size() == 0)
        #1us;
    end
    if (wcs.size() == 0) begin
      `uvm_error(label, "no completion on the simulated side")
      return;
    end
    wc = wcs[0];
    if (wc.wr_id != wr_id || wc.status != want)
      `uvm_error(label, $sformatf("sim completion wr_id %0d %s (vendor %02h), expected %0d %s",
                                  wc.wr_id, wc.status.name(), wc.vendor_err, wr_id, want.name()))
  endtask

  // 功能：等 rxe 的一个完成（非阻塞轮询 + 1us 仿真时间推进，让仿真继续应答），期望 ibv_wc_status 为
  //   want（0 成功，9 REM_INV_REQ，10 REM_ACCESS，13 RNR_RETRY_EXC）。
  // 输入/输出及副作用：reply 输出应答行。
  // 失败/边界：超时或状态、wr_id 不符报告 UVM_ERROR。
  task wait_peer(string label, longint unsigned wr_id, output string reply,
                 input int unsigned want = 0);
    reply = "OK none";
    for (int t = 0; t < POLL_LIMIT && reply == "OK none"; t++) begin
      reply = peer.cmd("poll 0");
      if (reply == "OK none")
        #1us;
    end
    if (reply == "OK none")
      `uvm_error(label, "no completion on the rxe side")
    else if (rdma_rxe_peer::field(reply, "wr_id") != wr_id ||
             rdma_rxe_peer::field(reply, "status") != want)
      `uvm_error(label, {"rxe completion ", reply})
  endtask

  // 功能：rxe 缓冲 [off, off+n) 的内容。
  // 输入/输出及副作用：与对端交互。
  // 失败/边界：无。
  function rdma_bytes_t peer_rbuf(int unsigned off, int unsigned n);
    string reply;

    reply = peer.cmd($sformatf("rbuf %0d %0d", off, n));
    return bytes_of(reply.substr(3, reply.len() - 1));
  endfunction

  // 功能：比较两段字节。
  // 输入/输出及副作用：只读。
  // 失败/边界：不符报告 UVM_ERROR。
  function void expect_bytes(string label, rdma_bytes_t got, rdma_bytes_t want);
    if (got.size() != want.size()) begin
      `uvm_error(label, $sformatf("%0d bytes, expected %0d", got.size(), want.size()))
      return;
    end
    foreach (want[i])
      if (got[i] != want[i]) begin
        `uvm_error(label, $sformatf("byte %0d: %02h != %02h", i, got[i], want[i]))
        return;
      end
    `uvm_info("RXE", {label, ": OK"}, UVM_LOW)
  endfunction

  // 功能：仿真 → rxe 的 SEND（imm 时 SEND_WITH_IMM）：rxe 先投递 RECV，两端完成、数据与立即数一致。
  // 输入/输出及副作用：写本端缓冲 0 起；rxe 收到缓冲 0 起。
  // 失败/边界：不符报告 UVM_ERROR。
  task sim_send(string label, int unsigned n, bit imm, bit [31:0] imm_value);
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_bytes_t data;
    rdma_status status;
    string reply;
    longint unsigned recv_id;

    recv_id = next_wr_id++;
    void'(peer.cmd($sformatf("recv %0d 0 4096 %0d", peer_qpn, recv_id)));
    data = pattern(n, n);
    expect_ok("fill", sys.nodes[0].hw.write(data_buf, 0, data));
    wr = rdma_drv_send_wr::type_id::create("rxe_send");
    wr.wr_id = next_wr_id++;
    wr.opcode = imm ? RDMA_DRV_WR_SEND_IMM : RDMA_DRV_WR_SEND;
    wr.imm = imm_value;
    wr.sges.push_back(rdma_drv_sge::make(data_buf.iova, n, mr.key()));
    rdma_drv_wr::post_send(drv, qp, wr, status);
    expect_ok("post SEND", status);
    wait_sim(label, wr.wr_id, wc);
    wait_peer(label, recv_id, reply);
    if (rdma_rxe_peer::field(reply, "len") != n)
      `uvm_error(label, {"rxe receive length: ", reply})
    if (imm && rdma_rxe_peer::field(reply, "imm") != imm_value)
      `uvm_error(label, {"rxe immediate: ", reply})
    expect_bytes(label, peer_rbuf(0, n), data);
  endtask

  // 功能：仿真 → rxe 的 WRITE（imm 时 WRITE_WITH_IMM，rxe 消费一个 RECV）到 rxe 缓冲 0x4000。
  // 输入/输出及副作用：写 rxe 内存。
  // 失败/边界：不符报告 UVM_ERROR。
  task sim_write(string label, int unsigned n, bit imm);
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_bytes_t data;
    rdma_status status;
    string reply;
    longint unsigned recv_id;

    recv_id = 0;
    if (imm) begin
      recv_id = next_wr_id++;
      void'(peer.cmd($sformatf("recv %0d 0 4096 %0d", peer_qpn, recv_id)));
    end
    data = pattern(n, 7 + n);
    expect_ok("fill", sys.nodes[0].hw.write(data_buf, 'h1000, data));
    wr = rdma_drv_send_wr::type_id::create("rxe_write");
    wr.wr_id = next_wr_id++;
    wr.opcode = imm ? RDMA_DRV_WR_WRITE_IMM : RDMA_DRV_WR_WRITE;
    wr.imm = 32'h1234_5678;
    wr.sges.push_back(rdma_drv_sge::make(data_buf.iova + 'h1000, n, mr.key()));
    wr.remote_va = peer_addr + 'h4000;
    wr.rkey = peer_rkey;
    rdma_drv_wr::post_send(drv, qp, wr, status);
    expect_ok("post WRITE", status);
    wait_sim(label, wr.wr_id, wc);
    if (imm) begin
      wait_peer(label, recv_id, reply);
      if (rdma_rxe_peer::field(reply, "imm") != 32'h1234_5678)
        `uvm_error(label, {"rxe immediate: ", reply})
    end
    expect_bytes(label, peer_rbuf('h4000, n), data);
  endtask

  // 功能：仿真从 rxe 缓冲 0x8000 READ n 字节到本端缓冲 0x3000。
  // 输入/输出及副作用：写本端内存。
  // 失败/边界：不符报告 UVM_ERROR。
  task sim_read(string label, int unsigned n);
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_bytes_t data;
    rdma_bytes_t got;
    rdma_status status;

    data = pattern(n, 99);
    void'(peer.cmd({"wbuf 0x8000 ", hex_of(data)}));
    wr = rdma_drv_send_wr::type_id::create("rxe_read");
    wr.wr_id = next_wr_id++;
    wr.opcode = RDMA_DRV_WR_READ;
    wr.sges.push_back(rdma_drv_sge::make(data_buf.iova + 'h3000, n, mr.key()));
    wr.remote_va = peer_addr + 'h8000;
    wr.rkey = peer_rkey;
    rdma_drv_wr::post_send(drv, qp, wr, status);
    expect_ok("post READ", status);
    wait_sim(label, wr.wr_id, wc);
    expect_ok("read back", sys.nodes[0].hw.read(data_buf, 'h3000, n, got));
    expect_bytes(label, got, data);
  endtask

  // 功能：仿真对 rxe 缓冲 0xA000 做原子操作（cas=0 FETCH_ADD 加 a；cas=1 比较 a 交换 b），原值写回
  //   本端 0x5000；检查原值与 rxe 内存结果。
  // 输入/输出及副作用：读写两端内存。
  // 失败/边界：不符报告 UVM_ERROR。
  task sim_atomic(string label, bit cas, bit [63:0] init, bit [63:0] a, bit [63:0] b,
                  bit [63:0] after);
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_bytes_t got;
    rdma_status status;

    void'(peer.cmd({"wbuf 0xa000 ", hex_of(le64(init))}));
    wr = rdma_drv_send_wr::type_id::create("rxe_atomic");
    wr.wr_id = next_wr_id++;
    wr.opcode = cas ? RDMA_DRV_WR_CAS : RDMA_DRV_WR_FAA;
    wr.compare_add = a;
    wr.swap = b;
    wr.sges.push_back(rdma_drv_sge::make(data_buf.iova + 'h5000, 8, mr.key()));
    wr.remote_va = peer_addr + 'ha000;
    wr.rkey = peer_rkey;
    rdma_drv_wr::post_send(drv, qp, wr, status);
    expect_ok("post atomic", status);
    wait_sim(label, wr.wr_id, wc);
    expect_ok("read back", sys.nodes[0].hw.read(data_buf, 'h5000, 8, got));
    expect_bytes({label, " original"}, got, le64(init));
    expect_bytes({label, " remote"}, peer_rbuf('ha000, 8), le64(after));
  endtask

  // 功能：rxe → 仿真的 SEND（imm 时 SEND_WITH_IMM 0x5a5a0001）：仿真先投递 RECV 到 0x6000。
  // 输入/输出及副作用：写本端内存。
  // 失败/边界：不符报告 UVM_ERROR。
  task rxe_send(string label, int unsigned n, bit imm);
    rdma_drv_recv_wr rwr;
    rdma_drv_wc wc;
    rdma_bytes_t data;
    rdma_bytes_t got;
    rdma_status status;
    string reply;
    longint unsigned send_id;

    rwr = rdma_drv_recv_wr::type_id::create("rxe_recv");
    rwr.wr_id = next_wr_id++;
    rwr.sges.push_back(rdma_drv_sge::make(data_buf.iova + 'h6000, 'h1000, mr.key()));
    rdma_drv_wr::post_recv(drv, qp, rwr, status);
    expect_ok("post_recv", status);
    data = pattern(n, 3 * n);
    void'(peer.cmd({"wbuf 0x1000 ", hex_of(data)}));
    send_id = next_wr_id++;
    if (imm)
      void'(peer.cmd($sformatf("send %0d send_imm 0x1000 %0d %0d 0x5a5a0001", peer_qpn, n,
                               send_id)));
    else
      void'(peer.cmd($sformatf("send %0d send 0x1000 %0d %0d", peer_qpn, n, send_id)));
    wait_sim(label, rwr.wr_id, wc);
    wait_peer(label, send_id, reply);
    if (wc != null && (wc.byte_len != n || (imm && wc.imm != 32'h5a5a_0001)))
      `uvm_error(label, $sformatf("sim receive len %0d imm %08h", wc.byte_len, wc.imm))
    expect_ok("read back", sys.nodes[0].hw.read(data_buf, 'h6000, n, got));
    expect_bytes(label, got, data);
  endtask

  // 功能：rxe → 仿真的 WRITE 到本端缓冲 0x8000。
  // 输入/输出及副作用：写本端内存。
  // 失败/边界：不符报告 UVM_ERROR。
  task rxe_write(string label, int unsigned n);
    rdma_bytes_t data;
    rdma_bytes_t got;
    string reply;
    longint unsigned id;

    data = pattern(n, 5 * n);
    void'(peer.cmd({"wbuf 0x2000 ", hex_of(data)}));
    id = next_wr_id++;
    void'(peer.cmd($sformatf("send %0d write 0x2000 %0d %0d 0x%0h 0x%0h", peer_qpn, n, id,
                             data_buf.iova + 'h8000, mr.key())));
    wait_peer(label, id, reply);
    expect_ok("read back", sys.nodes[0].hw.read(data_buf, 'h8000, n, got));
    expect_bytes(label, got, data);
  endtask

  // 功能：rxe 从本端缓冲 0x9000 READ n 字节到 rxe 缓冲 0xc000。
  // 输入/输出及副作用：读本端内存。
  // 失败/边界：不符报告 UVM_ERROR。
  task rxe_read(string label, int unsigned n);
    rdma_bytes_t data;
    string reply;
    longint unsigned id;

    data = pattern(n, 11);
    expect_ok("fill", sys.nodes[0].hw.write(data_buf, 'h9000, data));
    id = next_wr_id++;
    void'(peer.cmd($sformatf("send %0d read 0xc000 %0d %0d 0x%0h 0x%0h", peer_qpn, n, id,
                             data_buf.iova + 'h9000, mr.key())));
    wait_peer(label, id, reply);
    expect_bytes(label, peer_rbuf('hc000, n), data);
  endtask

  // 功能：rxe 对本端缓冲 0xA000 做 FETCH_ADD（加 add），原值落到 rxe 缓冲 0xd000。
  // 输入/输出及副作用：读写两端内存。
  // 失败/边界：不符报告 UVM_ERROR。
  task rxe_atomic(string label, bit [63:0] init, bit [63:0] add);
    rdma_bytes_t got;
    string reply;
    longint unsigned id;

    expect_ok("fill", sys.nodes[0].hw.write(data_buf, 'ha000, le64(init)));
    id = next_wr_id++;
    void'(peer.cmd($sformatf("send %0d faa 0xd000 8 %0d 0x%0h 0x%0h 0 %0d", peer_qpn, id,
                             data_buf.iova + 'ha000, mr.key(), add)));
    wait_peer(label, id, reply);
    expect_bytes({label, " original"}, peer_rbuf('hd000, 8), le64(init));
    expect_ok("read back", sys.nodes[0].hw.read(data_buf, 'ha000, 8, got));
    expect_bytes({label, " local"}, got, le64(init + add));
  endtask
endclass
