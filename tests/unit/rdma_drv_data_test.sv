// 目录：单元测试层 tests/unit/rdma_drv_data_test.sv。
// 层：单元测试。
// 职责：两节点数据端到端（驱动模型 + 设备模型，仅经 CMQ/doorbell/DMA 交互）：RC 的 SEND（多 MTU、
//   3 SGE 走 SGB、inline）、WRITE、WRITE_IMM、READ、FAA、CAS、rkey 错误 NAK，CQ arm 产生 CEQE，
//   SEND 进 SRQ（post_srq_recv、SRFQ 环、CQE 的 SRFQ 回查与槽位释放），CQ resize 时未消费 CQE 迁移，
//   QP 转 ERR 的 flush 完成与 destroy 的 cq_clean，SRQ limit 的 AEQE，CQ destroy 的 cleanup_ceqes，
//   URC（rc_to_urc：frag CQ、CEQE 上报 HW 完成下标、SQ 完成合成、RQ CQE 在 frag 槽、flush、销毁）；
//   每项逐字节比对目的内存并检查完成的 wr_id/方向/状态。
// 依赖：rdma_drv_*、rdma_dev、rdma_drv_dev_bar、rdma_mock_host_mem。
// 所有权：测试拥有两个节点的内存、设备、驱动与链路。
// 生命周期：run_phase 内建立并运行到结束。

// 两节点链路：按目的 MAC 把报文交给对应节点的 NIC。
class rdma_drv_data_link extends rdma_dev_port;
  `uvm_object_utils(rdma_drv_data_link)

  rdma_dev nodes[bit [47:0]];
  int unsigned packets;

  // 功能：构造链路。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_data_link");
    super.new(name);
    packets = 0;
  endfunction

  // 功能：投递报文到目的 NIC。
  // 输入/输出及副作用：调用目的 NIC receive。
  // 失败/边界：未知 MAC 报告 UVM_ERROR。
  virtual task send(rdma_packet pkt, bit [47:0] dmac);
    packets++;
    if (!nodes.exists(dmac)) begin
      `uvm_error("DATA_LINK", $sformatf("no node with MAC %012h", dmac))
      return;
    end
    nodes[dmac].nic.receive(pkt);
  endtask
endclass

// 一个节点：设备 + 驱动 + 资源。
class rdma_drv_data_node extends uvm_object;
  `uvm_object_utils(rdma_drv_data_node)

  bit [47:0] mac;
  rdma_mock_host_mem mem;
  rdma_dev dev;
  rdma_drv_dev drv;
  rdma_drv_pd pd;
  rdma_drv_cq cq;
  rdma_drv_qp qp;
  rdma_drv_dma data_buf;
  rdma_drv_mr mr;

  // 功能：构造空节点。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_data_node");
    super.new(name);
  endfunction
endclass

class rdma_drv_data_test extends uvm_test;
  `uvm_component_utils(rdma_drv_data_test)

  localparam int unsigned BUF_BYTES = 16384;

  rdma_drv_data_node a;
  rdma_drv_data_node b;
  rdma_drv_data_link link;
  longint unsigned next_wr_id;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传给 uvm_test。
  // 失败/边界：无。
  function new(string name = "rdma_drv_data_test", uvm_component parent = null);
    super.new(name, parent);
    next_wr_id = 100;
  endfunction

  // 功能：建两节点、连 RC QP，运行设备数据面并执行各用例。
  // 输入/输出及副作用：持有 objection 直到结束。
  // 失败/边界：以 UVM_ERROR/FATAL 报告。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    link = rdma_drv_data_link::type_id::create("link");
    build_node("a", 48'h02_00_00_00_00_0a, a);
    build_node("b", 48'h02_00_00_00_00_0b, b);
    fork
      a.dev.nic.run();
      b.dev.nic.run();
    join_none
    connect_qp(a.drv, a.qp, b.qp.qpn, b.mac);
    connect_qp(b.drv, b.qp, a.qp.qpn, a.mac);
    check_send();
    check_sgb_and_inline();
    check_write();
    check_read();
    check_atomics();
    check_remote_access_error();
    check_cq_event();
    check_srq();
    check_cq_resize();
    check_flush();
    check_srq_limit();
    check_ceq_cleanup();
    check_urc();
    if (a.dev.nic.errors.size() != 0 || b.dev.nic.errors.size() != 0)
      `uvm_error("DATA", $sformatf("device protocol errors: a=%p b=%p",
                                   a.dev.nic.errors, b.dev.nic.errors))
    if (link.packets == 0)
      `uvm_error("DATA", "no packet crossed the link")
    phase.drop_objection(this);
  endtask

  // 功能：断言 status 成功。
  // 输入/输出及副作用：what 用于报告。
  // 失败/边界：null 或失败报告 UVM_FATAL。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("DATA", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：建一个节点：mock 内存、设备、BAR、probe、PD、CQ、RC QP、16KiB 数据缓冲与覆盖它的 MR。
  // 输入/输出及副作用：node 输出；注册到链路。
  // 失败/边界：任一步失败报告 UVM_FATAL。
  task build_node(string name, bit [47:0] mac, output rdma_drv_data_node node);
    rdma_drv_dev_bar bar;
    rdma_drv_hw hw;
    rdma_drv_config cfg;
    rdma_function_handle fn;
    rdma_drv_qp_init_attr attr;
    bit [63:0] pages[$];
    rdma_status status;

    node = rdma_drv_data_node::type_id::create(name);
    node.mac = mac;
    node.mem = rdma_mock_host_mem::type_id::create({name, "_mem"});
    node.dev = rdma_dev::type_id::create({name, "_dev"});
    node.dev.configure(node.mem);
    node.dev.nic.port = link;
    link.nodes[mac] = node.dev;
    bar = rdma_drv_dev_bar::type_id::create({name, "_bar"});
    bar.dev = node.dev;
    fn = rdma_function_handle::type_id::create({name, "_fn"});
    fn.kind = RDMA_RESOURCE_FUNCTION;
    fn.function_uid = mac;
    fn.generation = 1;
    hw = rdma_drv_hw::type_id::create({name, "_hw"});
    expect_ok("bind", hw.bind_hw(bar, node.mem, fn));
    cfg = rdma_drv_config::type_id::create({name, "_cfg"});
    node.drv = rdma_drv_dev::type_id::create({name, "_drv"});
    node.drv.probe(cfg, hw, status);
    expect_ok("probe", status);
    expect_ok("alloc PD", rdma_drv_pd::alloc(node.drv, node.pd));
    rdma_drv_cq::create_cq(node.drv, 64, 0, node.cq, status);
    expect_ok("create CQ", status);
    attr = rdma_drv_qp_init_attr::type_id::create("attr");
    attr.pd = node.pd;
    attr.send_cq = node.cq;
    attr.recv_cq = node.cq;
    attr.max_send_sge = 4;
    attr.max_recv_sge = 4;
    attr.max_inline = 64;
    rdma_drv_qp::create_qp(node.drv, attr, node.qp, status);
    expect_ok("create QP", status);
    expect_ok("alloc data buffer", hw.alloc_dma(BUF_BYTES, 4096, node.data_buf));
    for (int i = 0; i < BUF_BYTES / 4096; i++)
      pages.push_back(node.data_buf.iova + i * 4096);
    rdma_drv_mr::reg_mr(node.drv, node.pd, node.data_buf.iova, BUF_BYTES,
                        rdma_drv_mr::rights_of(1, 1, 1, 1), pages, node.mr, status);
    expect_ok("reg MR", status);
  endtask

  // 功能：把 qp 连接到对端 QPN/MAC：INIT（权限）→ RTR（目的 QPN、PSN、MTU 1024、目的 MAC）→ RTS。
  // 输入/输出及副作用：修改 qp。
  // 失败/边界：失败报告 UVM_FATAL。
  task connect_qp(rdma_drv_dev drv, rdma_drv_qp qp, bit [23:0] dest_qpn, bit [47:0] dmac);
    rdma_drv_qp_attr attr;
    rdma_status status;

    attr = rdma_drv_qp_attr::type_id::create("init");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_ACCESS;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.access = RDMA_RIGHT_REMOTE_READ | RDMA_RIGHT_REMOTE_WRITE | RDMA_RIGHT_REMOTE_ATOMIC;
    qp.modify(drv, attr, status);
    expect_ok("INIT", status);
    attr = rdma_drv_qp_attr::type_id::create("rtr");
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
    attr = rdma_drv_qp_attr::type_id::create("rts");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN;
    attr.state = RDMA_DRV_QPS_RTS;
    attr.sq_psn = 0;
    qp.modify(drv, attr, status);
    expect_ok("RTS", status);
  endtask

  // 功能：在节点缓冲 offset 处写入以 seed 起步进 3 的 len 字节。
  // 输入/输出及副作用：写主机内存；返回写入的数据。
  // 失败/边界：失败报告 UVM_FATAL。
  function rdma_bytes_t fill(rdma_drv_data_node n, int unsigned offset, int unsigned len,
                             byte unsigned seed);
    rdma_bytes_t data;

    data = new[len];
    foreach (data[i])
      data[i] = seed + i * 3;
    expect_ok("fill", n.drv.hw.write(n.data_buf, offset, data));
    return data;
  endfunction

  // 功能：读节点缓冲并与 expected 比较。
  // 输入/输出及副作用：读主机内存。
  // 失败/边界：不符报告 UVM_ERROR。
  function void expect_mem(string label, rdma_drv_data_node n, int unsigned offset,
                           rdma_bytes_t expected);
    rdma_bytes_t got;

    expect_ok("read back", n.drv.hw.read(n.data_buf, offset, expected.size(), got));
    foreach (expected[i])
      if (got[i] != expected[i]) begin
        `uvm_error(label, $sformatf("byte %0d is %02h, expected %02h", i, got[i], expected[i]))
        return;
      end
  endfunction

  // 功能：轮询节点 CQ 直到得到 n 个完成或超时。
  // 输入/输出及副作用：wcs 输出。
  // 失败/边界：超时报告 UVM_FATAL（后续检查依赖完成）。
  task wait_wcs(rdma_drv_data_node node, int unsigned n, output rdma_drv_wc wcs[$]);
    rdma_status status;

    wcs.delete();
    for (int t = 0; t < 2000 && wcs.size() < n; t++) begin
      rdma_drv_wr::poll_cq(node.drv, node.cq, n - wcs.size(), wcs, status);
      expect_ok("poll", status);
      if (wcs.size() < n)
        #100ns;
    end
    if (wcs.size() != n)
      `uvm_fatal("DATA", $sformatf("%s: %0d of %0d completions", node.get_name(), wcs.size(), n))
  endtask

  // 功能：检查一个完成的 wr_id/方向/状态。
  // 输入/输出及副作用：只读。
  // 失败/边界：不符报告 UVM_ERROR。
  function void expect_wc(string label, rdma_drv_wc wc, longint unsigned wr_id, bit is_recv,
                          rdma_drv_wc_status_e st = RDMA_DRV_WC_SUCCESS);
    if (wc.wr_id != wr_id || wc.is_recv != is_recv || wc.status != st)
      `uvm_error(label, $sformatf("completion %0d/%0b/%s (ecode %02h), expected %0d/%0b/%s",
                                  wc.wr_id, wc.is_recv, wc.status.name(), wc.vendor_err, wr_id,
                                  is_recv, st.name()))
  endfunction

  // 功能：post 一个 recv，SGE 指向节点缓冲。
  // 输入/输出及副作用：wr_id 输出。
  // 失败/边界：失败报告 UVM_FATAL。
  task post_recv(rdma_drv_data_node n, int unsigned offsets[$], int unsigned lens[$],
                 output longint unsigned wr_id);
    rdma_drv_recv_wr wr;
    rdma_status status;

    wr = rdma_drv_recv_wr::type_id::create("recv");
    wr.wr_id = next_wr_id++;
    foreach (offsets[i])
      wr.sges.push_back(rdma_drv_sge::make(n.data_buf.iova + offsets[i], lens[i], n.mr.key()));
    rdma_drv_wr::post_recv(n.drv, n.qp, wr, status);
    expect_ok("post_recv", status);
    wr_id = wr.wr_id;
  endtask

  // 功能：建一个发送 WR（SGE 指向节点缓冲）。
  // 输入/输出及副作用：返回新 WR。
  // 失败/边界：无。
  function rdma_drv_send_wr send_wr(rdma_drv_data_node n, rdma_drv_wr_opcode_e op,
                                    int unsigned offsets[$], int unsigned lens[$]);
    rdma_drv_send_wr wr;

    wr = rdma_drv_send_wr::type_id::create("send");
    wr.wr_id = next_wr_id++;
    wr.opcode = op;
    foreach (offsets[i])
      wr.sges.push_back(rdma_drv_sge::make(n.data_buf.iova + offsets[i], lens[i], n.mr.key()));
    return wr;
  endfunction

  // 功能：A 投递 WR 并等待 A 的一个完成，检查其 wr_id 与状态。
  // 输入/输出及副作用：一次 post_send + 轮询。
  // 失败/边界：失败报告 UVM_ERROR/FATAL。
  task send_and_wait(string label, rdma_drv_send_wr wr,
                     rdma_drv_wc_status_e st = RDMA_DRV_WC_SUCCESS);
    rdma_drv_wc wcs[$];
    rdma_status status;

    rdma_drv_wr::post_send(a.drv, a.qp, wr, status);
    expect_ok({"post ", label}, status);
    wait_wcs(a, 1, wcs);
    expect_wc(label, wcs[0], wr.wr_id, 1'b0, st);
  endtask

  // 功能：B 等待一个接收完成并检查 wr_id，返回该完成。
  // 输入/输出及副作用：轮询 B 的 CQ。
  // 失败/边界：失败报告 UVM_ERROR/FATAL。
  task expect_recv(string label, longint unsigned wr_id, output rdma_drv_wc wc);
    rdma_drv_wc wcs[$];

    wait_wcs(b, 1, wcs);
    wc = wcs[0];
    expect_wc(label, wc, wr_id, 1'b1);
  endtask

  // 功能：SEND 2500B（MTU 1024 分 3 包）到 B 的 recv。
  // 输入/输出及副作用：两端各一个完成，B 内存等于 A 源数据。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_send();
    rdma_bytes_t data;
    rdma_drv_wc wc;
    longint unsigned rwr;

    data = fill(a, 0, 2500, 8'h11);
    post_recv(b, '{4096}, '{4096}, rwr);
    send_and_wait("SEND", send_wr(a, RDMA_DRV_WR_SEND, '{0}, '{2500}));
    expect_recv("SEND rq", rwr, wc);
    if (wc.byte_len != 2500)
      `uvm_error("SEND", $sformatf("receive byte_len %0d", wc.byte_len))
    expect_mem("SEND", b, 4096, data);
  endtask

  // 功能：3 个 SGE 的 SEND 走 SQ SGB、3 个 SGE 的 recv 走 RQ SGB；20B inline SEND。
  // 输入/输出及副作用：B 内存按接收 SGE 切分后等于源数据。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_sgb_and_inline();
    rdma_bytes_t d0;
    rdma_bytes_t d1;
    rdma_bytes_t d2;
    rdma_bytes_t part;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    longint unsigned rwr;

    d0 = fill(a, 100, 100, 8'h21);
    d1 = fill(a, 300, 150, 8'h31);
    d2 = fill(a, 600, 50, 8'h41);
    post_recv(b, '{8192, 8400, 8700}, '{120, 130, 100}, rwr);
    send_and_wait("SGB", send_wr(a, RDMA_DRV_WR_SEND, '{100, 300, 600}, '{100, 150, 50}));
    expect_recv("SGB rq", rwr, wc);
    part = new[120];
    foreach (part[i])
      part[i] = i < 100 ? d0[i] : d1[i - 100];
    expect_mem("SGB part0", b, 8192, part);
    part = rdma_be::slice(d1, 20, 130);
    expect_mem("SGB part1", b, 8400, part);
    expect_mem("SGB part2", b, 8700, d2);
    d0 = fill(a, 900, 20, 8'h51);
    post_recv(b, '{9000}, '{64}, rwr);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{900}, '{20});
    wr.inline_data = 1'b1;
    send_and_wait("inline", wr);
    expect_recv("inline rq", rwr, wc);
    expect_mem("inline", b, 9000, d0);
  endtask

  // 功能：WRITE 2000B 到 B 偏移 0x2800；WRITE_IMM 300B 到 0x3000 并在 B 消费一个 recv。
  // 输入/输出及副作用：B 内存等于源数据，WRITE_IMM 的接收完成携带立即数。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_write();
    rdma_bytes_t data;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    longint unsigned rwr;

    data = fill(a, 1000, 2000, 8'h61);
    wr = send_wr(a, RDMA_DRV_WR_WRITE, '{1000}, '{2000});
    wr.remote_va = b.data_buf.iova + 'h2800;
    wr.rkey = b.mr.key();
    send_and_wait("WRITE", wr);
    expect_mem("WRITE", b, 'h2800, data);
    data = fill(a, 3100, 300, 8'h71);
    post_recv(b, '{9500}, '{16}, rwr);
    wr = send_wr(a, RDMA_DRV_WR_WRITE_IMM, '{3100}, '{300});
    wr.remote_va = b.data_buf.iova + 'h3000;
    wr.rkey = b.mr.key();
    wr.imm = 32'hcafe_f00d;
    send_and_wait("WRITE_IMM", wr);
    expect_recv("WRITE_IMM rq", rwr, wc);
    if (wc.imm != 32'hcafe_f00d)
      `uvm_error("WRITE_IMM", $sformatf("immediate %08h", wc.imm))
    expect_mem("WRITE_IMM", b, 'h3000, data);
  endtask

  // 功能：READ B 偏移 0x2800 的 2000B 到 A 偏移 0x1800。
  // 输入/输出及副作用：A 内存等于 B 的源数据。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_read();
    rdma_bytes_t data;
    rdma_drv_send_wr wr;

    data = fill(b, 'h2800, 2000, 8'h81);
    wr = send_wr(a, RDMA_DRV_WR_READ, '{'h1800}, '{2000});
    wr.remote_va = b.data_buf.iova + 'h2800;
    wr.rkey = b.mr.key();
    send_and_wait("READ", wr);
    expect_mem("READ", a, 'h1800, data);
  endtask

  // 功能：FAA(+5) 与 CAS(命中) 作用于 B 偏移 0x3800 的 8B，原值回写到 A 的本地缓冲。
  // 输入/输出及副作用：B 的值依次变为 orig+5 与 swap；A 得到各自原值（小端）。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_atomics();
    rdma_bytes_t init;
    rdma_bytes_t expect_b;
    rdma_drv_send_wr wr;

    init = rdma_be::zeros(8);
    init[0] = 8'h10;
    expect_ok("seed atomic", b.drv.hw.write(b.data_buf, 'h3800, init));
    wr = send_wr(a, RDMA_DRV_WR_FAA, '{'h3900}, '{8});
    wr.remote_va = b.data_buf.iova + 'h3800;
    wr.rkey = b.mr.key();
    wr.compare_add = 5;
    send_and_wait("FAA", wr);
    expect_mem("FAA orig", a, 'h3900, init);
    expect_b = rdma_be::zeros(8);
    expect_b[0] = 8'h15;
    expect_mem("FAA target", b, 'h3800, expect_b);
    wr = send_wr(a, RDMA_DRV_WR_CAS, '{'h3a00}, '{8});
    wr.remote_va = b.data_buf.iova + 'h3800;
    wr.rkey = b.mr.key();
    wr.compare_add = 64'h15;
    wr.swap = 64'h77;
    send_and_wait("CAS", wr);
    expect_mem("CAS orig", a, 'h3a00, expect_b);
    expect_b[0] = 8'h77;
    expect_mem("CAS target", b, 'h3800, expect_b);
  endtask

  // 功能：错误 rkey 的 WRITE 被 B 以 NAK 拒绝，A 的完成为错误状态，B 内存不变。
  // 输入/输出及副作用：一个错误完成。
  // 失败/边界：被接受或内存被改报告 UVM_ERROR。
  task check_remote_access_error();
    rdma_bytes_t snapshot;
    rdma_bytes_t scratch;
    rdma_drv_send_wr wr;

    expect_ok("snapshot", b.drv.hw.read(b.data_buf, 'h3c00, 64, snapshot));
    scratch = fill(a, 'h3c00, 64, 8'h91);
    wr = send_wr(a, RDMA_DRV_WR_WRITE, '{'h3c00}, '{64});
    wr.remote_va = b.data_buf.iova + 'h3c00;
    wr.rkey = b.mr.key() ^ 32'h1;
    send_and_wait("bad rkey", wr, RDMA_DRV_WC_GENERAL_ERR);
    expect_mem("bad rkey target", b, 'h3c00, snapshot);
  endtask

  // 功能：A 的 CQ arm 后，下一个完成在 CEQ 产生带该 CQN 的 CEQE，驱动处理后 arm_sn 递增。
  // 输入/输出及副作用：一次 SEND。
  // 失败/边界：无 CEQE 或 CQN 不符报告 UVM_ERROR。
  task check_cq_event();
    rdma_bytes_t scratch;
    rdma_drv_wc wc;
    int unsigned cqns[$];
    longint unsigned rwr;
    int unsigned sn;
    rdma_status status;

    a.cq.arm(a.drv, 1'b0, status);
    expect_ok("arm", status);
    sn = a.cq.arm_sn;
    scratch = fill(a, 0, 8, 8'ha1);
    post_recv(b, '{100}, '{8}, rwr);
    send_and_wait("armed SEND", send_wr(a, RDMA_DRV_WR_SEND, '{0}, '{8}));
    expect_recv("armed SEND rq", rwr, wc);
    rdma_drv_wr::process_ceq(a.drv, a.drv.ceqs[0], cqns, status);
    expect_ok("process CEQ", status);
    if (cqns.size() != 1 || cqns[0] != a.cq.cqn || a.cq.arm_sn != sn + 1)
      `uvm_error("CQ_EVENT", $sformatf("CEQ delivered %p for CQ %0d", cqns, a.cq.cqn))
  endtask

  // 功能：B 建 SRQ 与绑定它的 RC QP，A 建对应 QP 并互连；B post_srq_recv 两个 WR，A 发两个 SEND，
  //   B 的接收完成按顺序回查到 SRQ wr_id，内存等于源数据，槽位全部释放。
  // 输入/输出及副作用：创建 SRQ 与一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_srq();
    rdma_drv_srq srq;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t data[2];
    longint unsigned rids[2];
    rdma_status status;

    rdma_drv_srq::create_srq(b.drv, b.pd, 16, 0, srq, status);
    expect_ok("create SRQ", status);
    make_pair(srq, qa, qb);
    foreach (rids[k]) begin
      rwr = rdma_drv_recv_wr::type_id::create("srq_recv");
      rwr.wr_id = next_wr_id++;
      rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h3d00 + k * 'h100, 'h100,
                                            b.mr.key()));
      rdma_drv_wr::post_srq_recv(b.drv, srq, rwr, status);
      expect_ok("post_srq_recv", status);
      rids[k] = rwr.wr_id;
    end
    foreach (data[k]) begin
      data[k] = fill(a, 'h3e00 + k * 'h80, 'h40 + k, 8'hb1 + k);
      wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h3e00 + k * 'h80}, '{'h40 + k});
      rdma_drv_wr::post_send(a.drv, qa, wr, status);
      expect_ok("post SEND to SRQ QP", status);
      wait_wcs(a, 1, wcs);
      expect_wc("SRQ sq", wcs[0], wr.wr_id, 1'b0);
      wait_wcs(b, 1, wcs);
      expect_wc("SRQ rq", wcs[0], rids[k], 1'b1);
      expect_mem("SRQ data", b, 'h3d00 + k * 'h100, data[k]);
    end
    if (srq.tail != 2 || srq.slot_used.sum() with (int'(item)) != 0)
      `uvm_error("SRQ", $sformatf("SRQ tail %0d / slots not released", srq.tail))
  endtask

  // 功能：A 连发 3 个 WRITE 不轮询，等设备写完 CQE 后把 A 的 CQ 从 1024 扩到 2048：3 个未消费 CQE
  //   按序迁移到新缓冲，随后的 WRITE 完成落在新缓冲的后续位置。
  // 输入/输出及副作用：resize A 的 CQ。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_cq_resize();
    rdma_drv_send_wr wrs[4];
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    rdma_status status;

    foreach (wrs[k]) begin
      data = fill(a, 'h3f00 + k * 'h40, 'h40, 8'hc1 + k);
      wrs[k] = send_wr(a, RDMA_DRV_WR_WRITE, '{'h3f00 + k * 'h40}, '{'h40});
      wrs[k].remote_va = b.data_buf.iova + 'h3f00 + k * 'h40;
      wrs[k].rkey = b.mr.key();
    end
    for (int k = 0; k < 3; k++) begin
      rdma_drv_wr::post_send(a.drv, a.qp, wrs[k], status);
      expect_ok("post WRITE before resize", status);
    end
    #5us;
    a.cq.resize(a.drv, 1000, status);
    expect_ok("resize CQ", status);
    if (a.cq.size != 2048)
      `uvm_error("CQ_RESIZE", $sformatf("CQ size %0d after resize", a.cq.size))
    wait_wcs(a, 3, wcs);
    for (int k = 0; k < 3; k++)
      expect_wc("CQ_RESIZE pending", wcs[k], wrs[k].wr_id, 1'b0);
    send_and_wait("WRITE after resize", wrs[3]);
    expect_mem("CQ_RESIZE data", b, 'h3fc0, data);
  endtask

  // 功能：新建一对 QP；B 投 3 个 RECV 后转 ERR：设备写 flush CQE，驱动为 3 个 RECV 依序生成 FLUSH 完成，
  //   之后不再有完成；销毁两端 QP（cq_clean 清除残留 flush CQE），两端 CQ 再轮询无错误、无完成。
  // 输入/输出及副作用：创建并销毁一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_flush();
    rdma_drv_qp_attr mod;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_wc wcs[$];
    longint unsigned rids[3];
    rdma_status status;

    make_pair(null, qa, qb);
    foreach (rids[k]) begin
      rwr = rdma_drv_recv_wr::type_id::create("flush_recv");
      rwr.wr_id = next_wr_id++;
      rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h100, 'h10, b.mr.key()));
      rdma_drv_wr::post_recv(b.drv, qb, rwr, status);
      expect_ok("post_recv before flush", status);
      rids[k] = rwr.wr_id;
    end
    mod = rdma_drv_qp_attr::type_id::create("to_err");
    mod.mask = rdma_drv_qp_attr::M_STATE;
    mod.state = RDMA_DRV_QPS_ERR;
    qb.modify(b.drv, mod, status);
    expect_ok("modify to ERR", status);
    wait_wcs(b, 3, wcs);
    foreach (rids[k])
      expect_wc("FLUSH rq", wcs[k], rids[k], 1'b1, RDMA_DRV_WC_FLUSH_ERR);
    #1us;
    rdma_drv_wr::poll_cq(b.drv, b.cq, 4, wcs, status);
    expect_ok("poll after flush", status);
    if (wcs.size() != 3)
      `uvm_error("FLUSH", $sformatf("%0d completions after the RQ drained", wcs.size() - 3))
    qa.destroy(a.drv, status);
    expect_ok("destroy flush peer", status);
    qb.destroy(b.drv, status);
    expect_ok("destroy flush QP", status);
    #1us;
    wcs.delete();
    rdma_drv_wr::poll_cq(a.drv, a.cq, 4, wcs, status);
    expect_ok("poll A after destroy", status);
    rdma_drv_wr::poll_cq(b.drv, b.cq, 4, wcs, status);
    expect_ok("poll B after destroy", status);
    if (wcs.size() != 0)
      `uvm_error("FLUSH", $sformatf("%0d completions after destroy", wcs.size()))
  endtask

  // 功能：新建一对已连接的 RC QP：qb 在 B（可绑定 srq），qa 在 A（a_cq/b_cq 为空时用节点默认 CQ）。
  // 输入/输出及副作用：qa/qb 输出。
  // 失败/边界：失败报告 UVM_FATAL。
  task make_pair(rdma_drv_srq srq, output rdma_drv_qp qa, output rdma_drv_qp qb,
                 input rdma_drv_cq a_cq = null, input rdma_drv_cq b_cq = null);
    rdma_drv_qp_init_attr attr;
    rdma_status status;

    attr = rdma_drv_qp_init_attr::type_id::create("pair_attr");
    attr.pd = b.pd;
    attr.send_cq = b_cq == null ? b.cq : b_cq;
    attr.recv_cq = attr.send_cq;
    attr.srq = srq;
    rdma_drv_qp::create_qp(b.drv, attr, qb, status);
    expect_ok("create pair QP on B", status);
    attr = rdma_drv_qp_init_attr::type_id::create("pair_attr");
    attr.pd = a.pd;
    attr.send_cq = a_cq == null ? a.cq : a_cq;
    attr.recv_cq = attr.send_cq;
    rdma_drv_qp::create_qp(a.drv, attr, qa, status);
    expect_ok("create pair QP on A", status);
    connect_qp(a.drv, qa, qb.qpn, b.mac);
    connect_qp(b.drv, qb, qa.qpn, a.mac);
  endtask

  // 功能：SRQ 投 8 个 RECV，limit 设为 4：消费 4 个后（剩 4）无事件，第 5 个后（剩 3）AEQ 上报一个
  //   {0x78, SRQN} 事件，之后不再重复。
  // 输入/输出及副作用：创建 SRQ 与一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_srq_limit();
    rdma_drv_srq srq;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    bit [31:0] events[$];
    rdma_bytes_t scratch;
    rdma_status status;

    rdma_drv_srq::create_srq(b.drv, b.pd, 16, 0, srq, status);
    expect_ok("create limit SRQ", status);
    make_pair(srq, qa, qb);
    for (int k = 0; k < 8; k++) begin
      rwr = rdma_drv_recv_wr::type_id::create("limit_recv");
      rwr.wr_id = next_wr_id++;
      rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h200, 'h10, b.mr.key()));
      rdma_drv_wr::post_srq_recv(b.drv, srq, rwr, status);
      expect_ok("post_srq_recv", status);
    end
    srq.modify_limit(b.drv, 4, status);
    expect_ok("modify SRQ limit", status);
    scratch = fill(a, 'h200, 'h10, 8'he1);
    for (int k = 0; k < 5; k++) begin
      if (k == 4) begin
        rdma_drv_wr::process_aeq(b.drv, events, status);
        expect_ok("process AEQ", status);
        if (events.size() != 0)
          `uvm_error("SRQ_LIMIT", $sformatf("AEQ events %p with 4 WQEs left", events))
      end
      wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h200}, '{'h10});
      rdma_drv_wr::post_send(a.drv, qa, wr, status);
      expect_ok("post SEND to limit SRQ", status);
      wait_wcs(a, 1, wcs);
      wait_wcs(b, 1, wcs);
    end
    rdma_drv_wr::process_aeq(b.drv, events, status);
    expect_ok("process AEQ", status);
    if (events.size() != 1 || events[0] != {RDMA_ECODE_XTRDMA_CQE_ECODE_SRFQ_OVER_LIMIT_TH,
                                            24'(srq.srqn)})
      `uvm_error("SRQ_LIMIT", $sformatf("AEQ events %p for SRQ %0d", events, srq.srqn))
  endtask

  // 功能：A 上新 CQ c2 与默认 CQ 各 arm 后依次产生 CEQE（先 c2 后默认 CQ），不处理 CEQ 即销毁 c2 的
  //   QP 与 c2：cleanup_ceqes 移除 c2 的 CEQE 并前移其后条目，随后 process_ceq 只得到默认 CQ。
  // 输入/输出及副作用：创建并销毁 c2 与一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_ceq_cleanup();
    rdma_drv_cq c2;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wr;
    int unsigned cqns[$];
    rdma_bytes_t scratch;
    rdma_status status;

    rdma_drv_cq::create_cq(a.drv, 64, 0, c2, status);
    expect_ok("create c2", status);
    make_pair(null, qa, qb, c2);
    scratch = fill(a, 'h300, 'h10, 8'hf1);
    c2.arm(a.drv, 1'b0, status);
    expect_ok("arm c2", status);
    wr = send_wr(a, RDMA_DRV_WR_WRITE, '{'h300}, '{'h10});
    wr.remote_va = b.data_buf.iova + 'h300;
    wr.rkey = b.mr.key();
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post WRITE on c2 QP", status);
    #5us;
    a.cq.arm(a.drv, 1'b0, status);
    expect_ok("arm A CQ", status);
    wr = send_wr(a, RDMA_DRV_WR_WRITE, '{'h300}, '{'h10});
    wr.remote_va = b.data_buf.iova + 'h300;
    wr.rkey = b.mr.key();
    send_and_wait("WRITE on A CQ", wr);
    qa.destroy(a.drv, status);
    expect_ok("destroy c2 QP", status);
    c2.destroy(a.drv, status);
    expect_ok("destroy c2", status);
    rdma_drv_wr::process_ceq(a.drv, a.drv.ceqs[0], cqns, status);
    expect_ok("process CEQ", status);
    if (cqns.size() != 1 || cqns[0] != a.cq.cqn)
      `uvm_error("CEQ_CLEANUP", $sformatf("CEQ delivered %p (c2 %0d, A CQ %0d)", cqns, c2.cqn,
                                          a.cq.cqn))
  endtask

  // 功能：处理节点 CEQ 并轮询 cq，直到得到 n 个完成或超时（URC 完成经 CEQE 上报）。
  // 输入/输出及副作用：wcs 输出。
  // 失败/边界：超时报告 UVM_FATAL。
  task wait_urc(rdma_drv_data_node node, rdma_drv_cq cq, int unsigned n,
                output rdma_drv_wc wcs[$]);
    int unsigned cqns[$];
    rdma_status status;

    wcs.delete();
    for (int t = 0; t < 2000 && wcs.size() < n; t++) begin
      rdma_drv_wr::process_ceq(node.drv, node.drv.ceqs[0], cqns, status);
      expect_ok("process CEQ", status);
      rdma_drv_wr::poll_cq(node.drv, cq, n - wcs.size(), wcs, status);
      expect_ok("poll URC", status);
      if (wcs.size() < n)
        #100ns;
    end
    if (wcs.size() != n)
      `uvm_fatal("URC", $sformatf("%s: %0d of %0d completions", node.get_name(), wcs.size(), n))
  endtask

  // 功能：rc_to_urc 下建一对 URC QP（各用专属 CQ）：A 发 2500B SEND、未 signaled WRITE、WRITE_IMM、
  //   READ；A 只得到 3 个 signaled 完成（按序），B 得到 2 个接收完成（含立即数），内存逐字节一致；
  //   B 再投 2 个 RECV 后转 ERR 得到 2 个 FLUSH；销毁后原始 CQ 退出 URC 模式。
  // 输入/输出及副作用：创建并销毁 2 个 CQ 与一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_urc();
    rdma_drv_cq ua;
    rdma_drv_cq ub;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_qp_attr mod;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wrs[4];
    rdma_drv_wc wcs[$];
    rdma_dev_object obj;
    rdma_bytes_t d_send;
    rdma_bytes_t d_write;
    rdma_bytes_t d_imm;
    rdma_bytes_t d_read;
    longint unsigned rids[2];
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
    if (!qa.urc || !qb.urc || qa.send_cq.original != ua || !ua.urc_flag)
      `uvm_error("URC", "rc_to_urc did not create URC QPs on frag CQs")
    // lookup 的输出参数与同一表达式中的读取顺序不保证，分两句写。
    if (!b.dev.cmq.lookup(RDMA_DEV_QP, qb.qpn, obj))
      `uvm_fatal("URC", "device has no URC QPC")
    if (rdma_be::field(obj.bytes, RDMA_QPC_SERVICE_TYPE_WORD_BYTE_OFFSET,
                       RDMA_QPC_SERVICE_TYPE_LSB, RDMA_QPC_SERVICE_TYPE_WIDTH) != 6)
      `uvm_error("URC", "device QPC service type is not URC")
    foreach (rids[k]) begin
      rwr = rdma_drv_recv_wr::type_id::create("urc_recv");
      rwr.wr_id = next_wr_id++;
      rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h400 + k * 'h1000, 'h1000,
                                            b.mr.key()));
      rdma_drv_wr::post_recv(b.drv, qb, rwr, status);
      expect_ok("post URC recv", status);
      rids[k] = rwr.wr_id;
    end
    d_send = fill(a, 'h0, 2500, 8'h13);
    d_write = fill(a, 'h1000, 300, 8'h23);
    d_imm = fill(a, 'h1200, 64, 8'h33);
    d_read = fill(b, 'h2c00, 1500, 8'h43);
    wrs[0] = send_wr(a, RDMA_DRV_WR_SEND, '{'h0}, '{2500});
    wrs[1] = send_wr(a, RDMA_DRV_WR_WRITE, '{'h1000}, '{300});
    wrs[1].signaled = 1'b0;
    wrs[1].remote_va = b.data_buf.iova + 'h2000;
    wrs[1].rkey = b.mr.key();
    wrs[2] = send_wr(a, RDMA_DRV_WR_WRITE_IMM, '{'h1200}, '{64});
    wrs[2].remote_va = b.data_buf.iova + 'h2400;
    wrs[2].rkey = b.mr.key();
    wrs[2].imm = 32'h0bad_cafe;
    wrs[3] = send_wr(a, RDMA_DRV_WR_READ, '{'h1800}, '{1500});
    wrs[3].remote_va = b.data_buf.iova + 'h2c00;
    wrs[3].rkey = b.mr.key();
    foreach (wrs[k]) begin
      rdma_drv_wr::post_send(a.drv, qa, wrs[k], status);
      expect_ok("post URC send", status);
    end
    wait_urc(a, ua, 3, wcs);
    expect_wc("URC SEND", wcs[0], wrs[0].wr_id, 1'b0);
    expect_wc("URC WRITE_IMM", wcs[1], wrs[2].wr_id, 1'b0);
    expect_wc("URC READ", wcs[2], wrs[3].wr_id, 1'b0);
    wait_urc(b, ub, 2, wcs);
    expect_wc("URC recv SEND", wcs[0], rids[0], 1'b1);
    expect_wc("URC recv WRITE_IMM", wcs[1], rids[1], 1'b1);
    if (wcs[0].byte_len != 2500 || wcs[1].imm != 32'h0bad_cafe)
      `uvm_error("URC", $sformatf("receive byte_len %0d / imm %08h", wcs[0].byte_len,
                                  wcs[1].imm))
    expect_mem("URC SEND data", b, 'h400, d_send);
    expect_mem("URC WRITE data", b, 'h2000, d_write);
    expect_mem("URC WRITE_IMM data", b, 'h2400, d_imm);
    expect_mem("URC READ data", a, 'h1800, d_read);
    foreach (rids[k]) begin
      rwr = rdma_drv_recv_wr::type_id::create("urc_flush_recv");
      rwr.wr_id = next_wr_id++;
      rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h400, 'h10, b.mr.key()));
      rdma_drv_wr::post_recv(b.drv, qb, rwr, status);
      expect_ok("post URC recv before flush", status);
      rids[k] = rwr.wr_id;
    end
    mod = rdma_drv_qp_attr::type_id::create("urc_err");
    mod.mask = rdma_drv_qp_attr::M_STATE;
    mod.state = RDMA_DRV_QPS_ERR;
    qb.modify(b.drv, mod, status);
    expect_ok("URC to ERR", status);
    wait_urc(b, ub, 2, wcs);
    foreach (rids[k])
      expect_wc("URC flush", wcs[k], rids[k], 1'b1, RDMA_DRV_WC_FLUSH_ERR);
    qa.destroy(a.drv, status);
    expect_ok("destroy URC QP A", status);
    qb.destroy(b.drv, status);
    expect_ok("destroy URC QP B", status);
    if (ua.urc_flag || ub.urc_flag || ua.frags.size() != 0)
      `uvm_error("URC", "original CQs still in URC mode after destroy")
    ua.destroy(a.drv, status);
    expect_ok("destroy URC CQ A", status);
    ub.destroy(b.drv, status);
    expect_ok("destroy URC CQ B", status);
  endtask
endclass
