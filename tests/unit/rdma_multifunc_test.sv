// 目录：单元测试层 tests/unit/rdma_multifunc_test.sv。
// 层：单元测试。
// 职责：多 Function 隔离与复位（驱动形状）：5 个 Function（PF0、VF0_1、VF0_2、PF1、VF1_1），每个
//   Function 一个设备模型 + 独立主机内存域（IOVA 数值相同）+ 独立驱动 probe，RC QP 连成环。验证：
//   非法 IOVA→本地访问错完成、CMQ 卡死→驱动命令超时、错 rkey→REM_ACCESS 完成、丢一包→重传成功、
//   持续丢包→重试耗尽（0x16）错完成，
//   每项故障只影响目标 Function；VF FLR、PF FLR（含其 VF）、整设备复位只清空范围内 Function 的
//   context，范围外流量不受影响，范围内驱动 remove/probe 后流量恢复。
// 依赖：rdma_drv_*、rdma_dev、rdma_drv_dev_bar、rdma_mock_host_mem。
// 所有权：测试拥有全部 Function 的内存、设备、驱动与链路。
// 生命周期：run_phase 内建立并运行到结束。

// 多 Function 网络：按目的 MAC 投递，可按源 MAC 丢弃指定数量的报文。
class rdma_mf_net extends uvm_object;
  `uvm_object_utils(rdma_mf_net)

  rdma_dev devs[bit [47:0]];
  int unsigned drops[bit [47:0]];
  int unsigned dropped;

  // 功能：构造网络。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_mf_net");
    super.new(name);
    dropped = 0;
  endfunction
endclass

// 一个 Function 的出口端口。
class rdma_mf_port extends rdma_dev_port;
  `uvm_object_utils(rdma_mf_port)

  rdma_mf_net net;
  bit [47:0] src;

  // 功能：构造端口。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_mf_port");
    super.new(name);
  endfunction

  // 功能：投递报文；该源 MAC 有待丢弃计数时丢弃。
  // 输入/输出及副作用：调用目的 NIC receive 或计数丢弃。
  // 失败/边界：未知目的 MAC 报告 UVM_ERROR。
  virtual task send(rdma_packet pkt, bit [47:0] dmac);
    if (net.drops.exists(src) && net.drops[src] != 0) begin
      net.drops[src]--;
      net.dropped++;
      return;
    end
    if (!net.devs.exists(dmac)) begin
      `uvm_error("MF_NET", $sformatf("no Function with MAC %012h", dmac))
      return;
    end
    net.devs[dmac].nic.receive(pkt);
  endtask
endclass

// 一个 Function：设备、主机内存域、驱动与资源；qp_out 连到环中下一个 Function 的 qp_in。
class rdma_mf_func extends uvm_object;
  `uvm_object_utils(rdma_mf_func)

  int unsigned pf;
  int unsigned vf_id;
  bit [47:0] mac;
  rdma_mock_host_mem mem;
  rdma_dev dev;
  rdma_drv_dev_bar bar;
  rdma_drv_hw hw;
  rdma_drv_dev drv;
  rdma_drv_pd pd;
  rdma_drv_cq cq;
  rdma_drv_dma data_buf;
  rdma_drv_mr mr;
  rdma_drv_qp qp_out;
  rdma_drv_qp qp_in;

  // 功能：构造空 Function。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_mf_func");
    super.new(name);
  endfunction
endclass

class rdma_multifunc_test extends uvm_test;
  `uvm_component_utils(rdma_multifunc_test)

  localparam int unsigned BUF_BYTES = 16384;

  rdma_mf_func funcs[$];
  rdma_mf_net net;
  longint unsigned next_wr_id;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传给 uvm_test。
  // 失败/边界：无。
  function new(string name = "rdma_multifunc_test", uvm_component parent = null);
    super.new(name, parent);
    next_wr_id = 1;
  endfunction

  // 功能：建拓扑与环，跑基线流量、四类故障与三级复位。
  // 输入/输出及副作用：持有 objection 直到结束。
  // 失败/边界：以 UVM_ERROR/FATAL 报告。
  task run_phase(uvm_phase phase);
    int unsigned none[$];

    phase.raise_objection(this);
    net = rdma_mf_net::type_id::create("net");
    add_func("pf0", 0, 0);
    add_func("vf0_1", 0, 1);
    add_func("vf0_2", 0, 2);
    add_func("pf1", 1, 0);
    add_func("vf1_1", 1, 1);
    foreach (funcs[i])
      if (funcs[i].data_buf.iova != funcs[0].data_buf.iova)
        `uvm_error("MF", "Function DMA domains do not reuse the same IOVA numbers")
    foreach (funcs[i])
      link_qps(i);
    check_traffic("baseline", none);
    fault_iova();
    fault_cmq_stall();
    fault_bad_rkey();
    fault_packet_drop();
    reset_scope("VF FLR", '{1});
    reset_scope("PF FLR", '{0, 1, 2});
    reset_scope("device reset", '{0, 1, 2, 3, 4});
    foreach (funcs[i])
      if (funcs[i].dev.nic.errors.size() != 0)
        `uvm_error("MF", $sformatf("%s device errors: %p", funcs[i].get_name(),
                                   funcs[i].dev.nic.errors))
    phase.drop_objection(this);
  endtask

  // 功能：断言 status 成功。
  // 输入/输出及副作用：what 用于报告。
  // 失败/边界：null 或失败报告 UVM_FATAL。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("MF", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：建立一个 Function：独立 mock 内存域、设备、BAR、端口并启动 NIC，随后 probe。
  // 输入/输出及副作用：追加 funcs，注册到网络。
  // 失败/边界：失败报告 UVM_FATAL。
  task add_func(string name, int unsigned pf, int unsigned vf_id);
    rdma_mf_func f;
    rdma_mf_port port;
    rdma_function_handle fn;

    f = rdma_mf_func::type_id::create(name);
    f.pf = pf;
    f.vf_id = vf_id;
    f.mac = 48'h02_00_00_00_00_00 | (pf << 8) | vf_id;
    f.mem = rdma_mock_host_mem::type_id::create({name, "_mem"});
    f.dev = rdma_dev::type_id::create({name, "_dev"});
    f.dev.configure(f.mem);
    port = rdma_mf_port::type_id::create({name, "_port"});
    port.net = net;
    port.src = f.mac;
    f.dev.nic.port = port;
    net.devs[f.mac] = f.dev;
    f.bar = rdma_drv_dev_bar::type_id::create({name, "_bar"});
    f.bar.dev = f.dev;
    fn = rdma_function_handle::type_id::create({name, "_fn"});
    fn.kind = RDMA_RESOURCE_FUNCTION;
    fn.function_uid = {pf[7:0], vf_id[7:0]} + 1;
    fn.generation = 1;
    f.hw = rdma_drv_hw::type_id::create({name, "_hw"});
    expect_ok("bind", f.hw.bind_hw(f.bar, f.mem, fn));
    fork
      f.dev.nic.run();
    join_none
    probe(f);
    funcs.push_back(f);
  endtask

  // 功能：驱动 probe（vf_id 按 Function）后建 PD、CQ、16KiB 数据缓冲与覆盖它的 MR。
  // 输入/输出及副作用：替换 f 的驱动与资源。
  // 失败/边界：失败报告 UVM_FATAL。
  task probe(rdma_mf_func f);
    rdma_drv_config cfg;
    bit [63:0] pages[$];
    rdma_status status;

    cfg = rdma_drv_config::type_id::create("mf_cfg");
    cfg.vf_id = f.vf_id;
    f.drv = rdma_drv_dev::type_id::create({f.get_name(), "_drv"});
    f.drv.probe(cfg, f.hw, status);
    expect_ok({f.get_name(), " probe"}, status);
    expect_ok("alloc PD", rdma_drv_pd::alloc(f.drv, f.pd));
    rdma_drv_cq::create_cq(f.drv, 64, 0, f.cq, status);
    expect_ok("create CQ", status);
    expect_ok("alloc data buffer", f.hw.alloc_dma(BUF_BYTES, 4096, f.data_buf));
    for (int i = 0; i < BUF_BYTES / 4096; i++)
      pages.push_back(f.data_buf.iova + i * 4096);
    rdma_drv_mr::reg_mr(f.drv, f.pd, f.data_buf.iova, BUF_BYTES,
                        rdma_drv_mr::rights_of(1, 1, 1, 1), pages, f.mr, status);
    expect_ok("reg MR", status);
    f.qp_out = null;
    f.qp_in = null;
  endtask

  // 功能：环上第 i 条链路：funcs[i].qp_out ↔ funcs[i+1].qp_in。两端旧 QP（设备仍在时）先销毁，
  //   再新建并互连（INIT 远端权限、RTR 目的 QPN/MTU 1024/目的 MAC、RTS）。
  // 输入/输出及副作用：替换两端 QP。
  // 失败/边界：失败报告 UVM_FATAL。
  task link_qps(int unsigned i);
    rdma_mf_func a;
    rdma_mf_func b;
    rdma_drv_qp_init_attr attr;
    rdma_status status;

    a = funcs[i];
    b = funcs[(i + 1) % funcs.size()];
    if (a.qp_out != null)
      a.qp_out.destroy(a.drv, status);
    if (b.qp_in != null)
      b.qp_in.destroy(b.drv, status);
    attr = rdma_drv_qp_init_attr::type_id::create("mf_attr");
    attr.pd = a.pd;
    attr.send_cq = a.cq;
    attr.recv_cq = a.cq;
    rdma_drv_qp::create_qp(a.drv, attr, a.qp_out, status);
    expect_ok("create qp_out", status);
    attr = rdma_drv_qp_init_attr::type_id::create("mf_attr");
    attr.pd = b.pd;
    attr.send_cq = b.cq;
    attr.recv_cq = b.cq;
    rdma_drv_qp::create_qp(b.drv, attr, b.qp_in, status);
    expect_ok("create qp_in", status);
    connect_qp(a.drv, a.qp_out, b.qp_in.qpn, b.mac);
    connect_qp(b.drv, b.qp_in, a.qp_out.qpn, a.mac);
  endtask

  // 功能：把 qp 推到 RTS 并指向对端 QPN/MAC。
  // 输入/输出及副作用：修改 qp。
  // 失败/边界：失败报告 UVM_FATAL。
  task connect_qp(rdma_drv_dev drv, rdma_drv_qp qp, bit [23:0] dest_qpn, bit [47:0] dmac);
    rdma_drv_qp_attr attr;
    rdma_status status;

    attr = rdma_drv_qp_attr::type_id::create("mf_init");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_ACCESS;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.access = RDMA_RIGHT_REMOTE_READ | RDMA_RIGHT_REMOTE_WRITE | RDMA_RIGHT_REMOTE_ATOMIC;
    qp.modify(drv, attr, status);
    expect_ok("INIT", status);
    attr = rdma_drv_qp_attr::type_id::create("mf_rtr");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_DEST_QPN |
                rdma_drv_qp_attr::M_RQ_PSN | rdma_drv_qp_attr::M_PATH_MTU |
                rdma_drv_qp_attr::M_AV;
    attr.state = RDMA_DRV_QPS_RTR;
    attr.dest_qpn = dest_qpn;
    attr.rq_psn = 0;
    attr.path_mtu = 1024;
    attr.dmac = dmac;
    qp.modify(drv, attr, status);
    expect_ok("RTR", status);
    attr = rdma_drv_qp_attr::type_id::create("mf_rts");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN;
    attr.state = RDMA_DRV_QPS_RTS;
    attr.sq_psn = 0;
    qp.modify(drv, attr, status);
    expect_ok("RTS", status);
  endtask

  // 功能：i 是否在 scope 中。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  function bit in_scope(int unsigned i, int unsigned scope[$]);
    foreach (scope[k])
      if (scope[k] == i)
        return 1'b1;
    return 1'b0;
  endfunction

  // 功能：轮询 f 的 CQ 直到 n 个完成或超时。
  // 输入/输出及副作用：wcs 输出。
  // 失败/边界：超时报告 UVM_FATAL。
  task wait_wcs(rdma_mf_func f, int unsigned n, output rdma_drv_wc wcs[$]);
    rdma_status status;

    wcs.delete();
    for (int t = 0; t < 4000 && wcs.size() < n; t++) begin
      rdma_drv_wr::poll_cq(f.drv, f.cq, n - wcs.size(), wcs, status);
      expect_ok("poll", status);
      if (wcs.size() < n)
        #100ns;
    end
    if (wcs.size() != n)
      `uvm_fatal("MF", $sformatf("%s: %0d of %0d completions", f.get_name(), wcs.size(), n))
  endtask

  // 功能：在 f 的数据缓冲 offset 处写入以 seed 起的 len 字节。
  // 输入/输出及副作用：写主机内存；返回数据。
  // 失败/边界：失败报告 UVM_FATAL。
  function rdma_bytes_t fill(rdma_mf_func f, int unsigned offset, int unsigned len,
                             byte unsigned seed);
    rdma_bytes_t data;

    data = new[len];
    foreach (data[i])
      data[i] = seed + i * 5;
    expect_ok("fill", f.drv.hw.write(f.data_buf, offset, data));
    return data;
  endfunction

  // 功能：读 f 的数据缓冲并与 expected 比较。
  // 输入/输出及副作用：读主机内存。
  // 失败/边界：不符报告 UVM_ERROR。
  function void expect_mem(string label, rdma_mf_func f, int unsigned offset,
                           rdma_bytes_t expected);
    rdma_bytes_t got;

    expect_ok("read back", f.drv.hw.read(f.data_buf, offset, expected.size(), got));
    foreach (expected[i])
      if (got[i] != expected[i]) begin
        `uvm_error(label, $sformatf("%s byte %0d is %02h, expected %02h", f.get_name(), i,
                                    got[i], expected[i]))
        return;
      end
  endfunction

  // 功能：发一个 WR 并等待发送方一个完成，检查状态与 wr_id。
  // 输入/输出及副作用：一次 post_send + 轮询；返回完成。
  // 失败/边界：不符报告 UVM_ERROR。
  task send_one(string label, rdma_mf_func a, rdma_drv_send_wr wr, rdma_drv_wc_status_e st,
                output rdma_drv_wc wc);
    rdma_drv_wc wcs[$];
    rdma_status status;

    rdma_drv_wr::post_send(a.drv, a.qp_out, wr, status);
    expect_ok({label, " post"}, status);
    wait_wcs(a, 1, wcs);
    wc = wcs[0];
    if (wc.wr_id != wr.wr_id || wc.status != st)
      `uvm_error(label, $sformatf("%s completion %0d/%s (ecode %02h), expected %0d/%s",
                                  a.get_name(), wc.wr_id, wc.status.name(), wc.vendor_err,
                                  wr.wr_id, st.name()))
  endtask

  // 功能：建发送 WR（本地 SGE 在 a 的数据缓冲）。
  // 输入/输出及副作用：返回新 WR。
  // 失败/边界：无。
  function rdma_drv_send_wr make_wr(rdma_mf_func a, rdma_drv_wr_opcode_e op, int unsigned offset,
                                    int unsigned len);
    rdma_drv_send_wr wr;

    wr = rdma_drv_send_wr::type_id::create("mf_wr");
    wr.wr_id = next_wr_id++;
    wr.opcode = op;
    wr.sges.push_back(rdma_drv_sge::make(a.data_buf.iova + offset, len, a.mr.key()));
    return wr;
  endfunction

  // 功能：环上每条两端都不在 excluded 中的链路：SEND 300B 进对端 RECV、WRITE 128B，逐字节比对。
  // 输入/输出及副作用：读写各 Function 内存。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_traffic(string label, int unsigned excluded[$]);
    rdma_mf_func a;
    rdma_mf_func b;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    rdma_status status;
    int unsigned j;

    foreach (funcs[i]) begin
      j = (i + 1) % funcs.size();
      if (in_scope(i, excluded) || in_scope(j, excluded))
        continue;
      a = funcs[i];
      b = funcs[j];
      rwr = rdma_drv_recv_wr::type_id::create("mf_recv");
      rwr.wr_id = next_wr_id++;
      rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h2000, 'h400, b.mr.key()));
      rdma_drv_wr::post_recv(b.drv, b.qp_in, rwr, status);
      expect_ok("post_recv", status);
      data = fill(a, 'h0, 300, 8'(i * 16 + 1));
      send_one({label, " SEND"}, a, make_wr(a, RDMA_DRV_WR_SEND, 'h0, 300), RDMA_DRV_WC_SUCCESS,
               wc);
      wait_wcs(b, 1, wcs);
      if (wcs[0].wr_id != rwr.wr_id || wcs[0].status != RDMA_DRV_WC_SUCCESS)
        `uvm_error(label, $sformatf("%s receive completion is wrong", b.get_name()))
      expect_mem({label, " SEND data"}, b, 'h2000, data);
      data = fill(a, 'h400, 128, 8'(i * 16 + 9));
      wr = make_wr(a, RDMA_DRV_WR_WRITE, 'h400, 128);
      wr.remote_va = b.data_buf.iova + 'h3000;
      wr.rkey = b.mr.key();
      send_one({label, " WRITE"}, a, wr, RDMA_DRV_WC_SUCCESS, wc);
      expect_mem({label, " WRITE data"}, b, 'h3000, data);
    end
  endtask

  // 功能：非法 IOVA：VF0_2 在自己的域里新分配一页 X 并写入图样；VF0_1 用 X 注册 MR 并从中 SEND。
  //   VF0_1 的域里没有 X，设备 DMA 失败，VF0_1 得到本地访问错完成；X 在 VF0_2 中不变；全环流量正常。
  // 输入/输出及副作用：分配一页、注册并注销一个 MR。
  // 失败/边界：不符报告 UVM_ERROR。
  task fault_iova();
    rdma_mf_func a;
    rdma_mf_func victim;
    rdma_drv_dma page;
    rdma_drv_mr mr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_bytes_t pattern;
    rdma_bytes_t got;
    bit [63:0] pages[$];
    int unsigned none[$];
    rdma_status status;

    a = funcs[1];
    victim = funcs[2];
    expect_ok("alloc victim page", victim.hw.alloc_dma(4096, 4096, page));
    pattern = new[64];
    foreach (pattern[k])
      pattern[k] = 8'h5a ^ k;
    expect_ok("write victim page", victim.hw.write(page, 0, pattern));
    pages.push_back(page.iova);
    rdma_drv_mr::reg_mr(a.drv, a.pd, page.iova, 4096, rdma_drv_mr::rights_of(1, 0, 0, 0),
                        pages, mr, status);
    expect_ok("reg foreign-IOVA MR", status);
    wr = rdma_drv_send_wr::type_id::create("mf_bad_iova");
    wr.wr_id = next_wr_id++;
    wr.opcode = RDMA_DRV_WR_SEND;
    wr.sges.push_back(rdma_drv_sge::make(page.iova, 64, mr.key()));
    send_one("IOVA fault", a, wr, RDMA_DRV_WC_GENERAL_ERR, wc);
    if (wc.vendor_err != RDMA_ECODE_EC_TPE_SQ_KEY_ERR)
      `uvm_error("IOVA fault", $sformatf("ecode %02h for a foreign IOVA", wc.vendor_err))
    expect_ok("read victim page", victim.hw.read(page, 0, 64, got));
    if (got != pattern)
      `uvm_error("IOVA fault", "victim page changed")
    mr.dereg(a.drv, status);
    expect_ok("dereg foreign-IOVA MR", status);
    check_traffic("after IOVA fault", none);
  endtask

  // 功能：CMQ 卡死：VF0_2 的设备 CMQ 停止消费，驱动 create_cq 超时；不含 VF0_2 的链路流量正常；
  //   FLR VF0_2 后 remove/probe 并重连，全环流量恢复。
  // 输入/输出及副作用：复位 VF0_2。
  // 失败/边界：不符报告 UVM_ERROR。
  task fault_cmq_stall();
    rdma_drv_cq cq;
    rdma_status status;

    funcs[2].dev.cmq.stall = 1'b1;
    rdma_drv_cq::create_cq(funcs[2].drv, 64, 0, cq, status);
    if (status.code != RDMA_SC_TIMEOUT)
      `uvm_error("CMQ stall", $sformatf("create_cq on a stalled CMQ returned %s",
                                        status.convert2string()))
    check_traffic("during CMQ stall", '{2});
    recover('{2});
  endtask

  // 功能：错 rkey：PF0 向 VF0_1 WRITE 用错 rkey，PF0 得到 REM_ACCESS 完成，VF0_1 内存不变，全环流量正常。
  // 输入/输出及副作用：一次被拒的 WRITE。
  // 失败/边界：不符报告 UVM_ERROR。
  task fault_bad_rkey();
    rdma_mf_func a;
    rdma_mf_func b;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_bytes_t snapshot;
    rdma_bytes_t scratch;
    int unsigned none[$];

    a = funcs[0];
    b = funcs[1];
    expect_ok("snapshot", b.drv.hw.read(b.data_buf, 'h3800, 64, snapshot));
    scratch = fill(a, 'h800, 64, 8'h77);
    wr = make_wr(a, RDMA_DRV_WR_WRITE, 'h800, 64);
    wr.remote_va = b.data_buf.iova + 'h3800;
    wr.rkey = b.mr.key() ^ 32'h1;
    send_one("bad rkey", a, wr, RDMA_DRV_WC_REM_ACCESS_ERR, wc);
    expect_mem("bad rkey target", b, 'h3800, snapshot);
    check_traffic("after bad rkey", none);
  endtask

  // 功能：丢包：PF1 发往 VF1_1 的 WRITE 丢一包，超时后重传成功且数据到达；再持续丢包，PSN 重试
  //   （PSN_RETRY_TH=6）耗尽后得到 vendor 0x16 的错误完成；该链路两端 QP 重建后全环流量正常。
  //   本项把 PF1 的响应超时缩短到 5us。
  // 输入/输出及副作用：重建链路 3。
  // 失败/边界：不符报告 UVM_ERROR。
  task fault_packet_drop();
    rdma_mf_func a;
    rdma_mf_func b;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    rdma_bytes_t data;
    int unsigned none[$];
    time saved;

    a = funcs[3];
    b = funcs[4];
    saved = a.dev.nic.response_timeout;
    a.dev.nic.response_timeout = 5us;
    net.drops[a.mac] = 1;
    data = fill(a, 'h0, 64, 8'h21);
    wr = make_wr(a, RDMA_DRV_WR_WRITE, 'h0, 64);
    wr.remote_va = b.data_buf.iova + 'h3400;
    wr.rkey = b.mr.key();
    send_one("packet drop", a, wr, RDMA_DRV_WC_SUCCESS, wc);
    expect_mem("packet drop retransmitted data", b, 'h3400, data);
    if (net.dropped != 1 || a.dev.nic.errors.size() != 0)
      `uvm_error("packet drop", $sformatf("dropped %0d, device errors %p", net.dropped,
                                          a.dev.nic.errors))
    net.drops[a.mac] = 7;
    wr = make_wr(a, RDMA_DRV_WR_WRITE, 'h0, 64);
    wr.remote_va = b.data_buf.iova + 'h3400;
    wr.rkey = b.mr.key();
    send_one("retry exhausted", a, wr, RDMA_DRV_WC_GENERAL_ERR, wc);
    if (wc.vendor_err != RDMA_ECODE_EC_TPE_SQ_RTO_OVERTIME || net.dropped != 8)
      `uvm_error("retry exhausted", $sformatf("vendor %02h, dropped %0d", wc.vendor_err,
                                              net.dropped))
    a.dev.nic.response_timeout = saved;
    link_qps(3);
    check_traffic("after packet drop", none);
  endtask

  // 功能：复位 scope 内 Function（FLR/PF FLR/设备复位）：范围内 context 清空、范围外计数不变且
  //   不涉及范围的链路流量正常；随后 recover。
  // 输入/输出及副作用：复位并重建范围内 Function。
  // 失败/边界：不符报告 UVM_ERROR。
  task reset_scope(string label, int unsigned scope[$]);
    int unsigned qps[int unsigned];
    int unsigned mrs[int unsigned];

    foreach (funcs[i]) begin
      qps[i] = funcs[i].dev.cmq.count(RDMA_DEV_QP);
      mrs[i] = funcs[i].dev.cmq.count(RDMA_DEV_MR);
    end
    foreach (scope[k])
      funcs[scope[k]].dev.flr();
    foreach (funcs[i]) begin
      if (in_scope(i, scope)) begin
        if (funcs[i].dev.cmq.count(RDMA_DEV_QP) != 0 ||
            funcs[i].dev.cmq.count(RDMA_DEV_CQ) != 0 ||
            funcs[i].dev.cmq.count(RDMA_DEV_MR) != 0)
          `uvm_error(label, $sformatf("%s kept contexts after reset", funcs[i].get_name()))
      end
      else if (funcs[i].dev.cmq.count(RDMA_DEV_QP) != qps[i] ||
               funcs[i].dev.cmq.count(RDMA_DEV_MR) != mrs[i])
        `uvm_error(label, $sformatf("%s outside the reset scope lost contexts",
                                    funcs[i].get_name()))
    end
    check_traffic({label, " (outside scope)"}, scope);
    recover(scope);
  endtask

  // 功能：scope 内 Function 恢复：确保设备已复位（CMQ 卡死场景由此复位），驱动 remove（不再下发
  //   硬件命令）、重新 probe 与建资源，重建涉及它们的链路，全环流量验证。
  // 输入/输出及副作用：替换驱动与 QP。
  // 失败/边界：失败报告 UVM_FATAL/ERROR。
  task recover(int unsigned scope[$]);
    int unsigned none[$];
    int unsigned j;
    rdma_status status;

    foreach (scope[k]) begin
      funcs[scope[k]].dev.flr();
      funcs[scope[k]].drv.remove(status, 1'b1);
      expect_ok("remove after reset", status);
      probe(funcs[scope[k]]);
    end
    foreach (funcs[i]) begin
      j = (i + 1) % funcs.size();
      if (in_scope(i, scope) || in_scope(j, scope))
        link_qps(i);
    end
    check_traffic("after recovery", none);
  endtask
endclass
