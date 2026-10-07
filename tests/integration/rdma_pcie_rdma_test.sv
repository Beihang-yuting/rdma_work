// 目录：集成测试层 integration/rdma_pcie_rdma_test.sv。
// 层：集成测试。
// 职责：dpu_common → pcie_work → RDMA：dpu_common 声明 Host0（PF0、VF1）与 Host1（PF0），BAR 随机
//   放置；rdma_pcie_system 把快照投影为 PCIe 拓扑（每 Host 一条 RC↔EP 链），每个 Host 一个真实
//   host_mem 绑定到其 Root。各 Function 的驱动 probe、建资源、QP 互连与数据传输中：全部 BAR 写以
//   MemWr TLP 经 RC→EP 送达并经快照解码到设备；设备全部 DMA（CMQ、WQE/SGE、数据、CQE/EQE）以
//   requester ID 为 Function BDF 的 MemRd/MemWr 经 EP→RC 访问 Host 内存。检查 MMIO TLP 数与解码数
//   相等、DMA TLP 发出数与 RC 收到数相等且每个 Function 的 BDF 都出现、Host0↔Host1 的 SEND/WRITE
//   数据一致（驱动经 host_mem 读回设备经 PCIe 写入的数据）、MAILBOX BAR 的 MemWr 被拒绝。
// 依赖：rdma_pcie_work_pkg、rdma_dpu_adapter_pkg（dpu_common）、rdma_host_mem_adapter、外部
//   host_mem_manager、rdma_mf_net/rdma_mf_port。
// 所有权：测试拥有 dpu 系统、PCIe 系统与各 Host 的 host_mem。
// 生命周期：build_phase 建拓扑与 PCIe 环境，run_phase 运行。
class rdma_pcie_rdma_test extends uvm_test;
  `uvm_component_utils(rdma_pcie_rdma_test)

  localparam int unsigned BUF_BYTES = 16384;

  rdma_dpu_system sys;
  rdma_host_mem_factory mems;
  rdma_pcie_system pcie;
  rdma_mf_net net;
  bit [47:0] macs[$];
  rdma_drv_pd pds[$];
  rdma_drv_cq cqs[$];
  rdma_drv_dma bufs[$];
  rdma_drv_mr mrs[$];
  longint unsigned next_wr_id;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传。
  // 失败/边界：无。
  function new(string name = "rdma_pcie_rdma_test", uvm_component parent = null);
    super.new(name, parent);
    next_wr_id = 1;
  endfunction

  // 功能：断言 status 成功。
  // 输入/输出及副作用：what 用于报告。
  // 失败/边界：失败报告 UVM_FATAL。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("PCIE_RDMA", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：注册 PCIe 覆盖，声明并 build dpu 拓扑（每 Host 一个 host_mem），建 PCIe 系统并交给它
  //   各 Host 的内存。
  // 输入/输出及副作用：创建 sys 与 pcie 组件。
  // 失败/边界：失败报告 UVM_FATAL。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    rdma_pcie_system::install_overrides();
    sys = rdma_dpu_system::type_id::create("pcie_dpu");
    mems = rdma_host_mem_factory::type_id::create("pcie_mem_factory");
    sys.mem_factory = mems;
    sys.add_host(0);
    sys.add_host(1);
    sys.add_function(0, 0, DPU_FUNCTION_PF, 0);
    sys.add_function(0, 0, DPU_FUNCTION_VF, 1);
    sys.add_function(1, 0, DPU_FUNCTION_PF, 0);
    expect_ok("dpu system build", sys.build());
    pcie = rdma_pcie_system::type_id::create("pcie", this);
    pcie.dpu = sys;
    pcie.host_mems = mems.managers;
  endfunction

  // 功能：接网络、启动 NIC，经 PCIe probe 全部 Function 并建资源；Host0 PF0/VF1 各与 Host1 PF0 建
  //   一对 RC QP 并传数据；最后检查 DMA 与 MMIO 计数、MAILBOX 拒绝。
  // 输入/输出及副作用：持有 objection。
  // 失败/边界：以 UVM_ERROR/FATAL 报告。
  task run_phase(uvm_phase phase);
    rdma_status status;

    phase.raise_objection(this);
    net = rdma_mf_net::type_id::create("pcie_net");
    foreach (sys.nodes[i]) begin
      attach(i);
      sys.probe(i, status);
      expect_ok($sformatf("probe node %0d over PCIe", i), status);
      setup(i);
    end
    transfer(0, 2);
    transfer(1, 2);
    check_dma();
    check_mmio();
    phase.drop_objection(this);
  endtask

  // 功能：节点 i 挂到网络（MAC 02:00:00:00:<host>:<global ID>）并启动 NIC。
  // 输入/输出及副作用：设置 NIC 端口，fork NIC。
  // 失败/边界：无。
  task attach(int unsigned i);
    rdma_mf_port port;
    rdma_dev dev;

    macs.push_back({32'h0200_0000, 8'(sys.nodes[i].func.key.host_id),
                    8'(sys.nodes[i].func.global_id)});
    dev = sys.nodes[i].dev;
    port = rdma_mf_port::type_id::create($sformatf("pcie_port%0d", i));
    port.net = net;
    port.src = macs[i];
    dev.nic.port = port;
    net.devs[macs[i]] = dev;
    fork
      dev.nic.run();
    join_none
  endtask

  // 功能：节点 i 的 PD、CQ、16KiB 数据缓冲与覆盖它的 MR。
  // 输入/输出及副作用：追加资源表。
  // 失败/边界：失败报告 UVM_FATAL。
  task setup(int unsigned i);
    rdma_drv_dev drv;
    rdma_drv_pd pd;
    rdma_drv_cq cq;
    rdma_drv_dma data_buf;
    rdma_drv_mr mr;
    bit [63:0] pages[$];
    rdma_status status;

    drv = sys.nodes[i].drv;
    expect_ok("alloc PD", rdma_drv_pd::alloc(drv, pd));
    rdma_drv_cq::create_cq(drv, 64, 0, cq, status);
    expect_ok("create CQ", status);
    expect_ok("alloc buffer", sys.nodes[i].hw.alloc_dma(BUF_BYTES, 4096, data_buf));
    for (int p = 0; p < BUF_BYTES / 4096; p++)
      pages.push_back(data_buf.iova + p * 4096);
    rdma_drv_mr::reg_mr(drv, pd, data_buf.iova, BUF_BYTES, rdma_drv_mr::rights_of(1, 1, 1, 1),
                        pages, mr, status);
    expect_ok("reg MR", status);
    pds.push_back(pd);
    cqs.push_back(cq);
    bufs.push_back(data_buf);
    mrs.push_back(mr);
  endtask

  // 功能：在节点 i 建 RC QP。
  // 输入/输出及副作用：qp 输出。
  // 失败/边界：失败报告 UVM_FATAL。
  task make_qp(int unsigned i, output rdma_drv_qp qp);
    rdma_drv_qp_init_attr init;
    rdma_status status;

    init = rdma_drv_qp_init_attr::type_id::create("pcie_qp_attr");
    init.pd = pds[i];
    init.send_cq = cqs[i];
    init.recv_cq = cqs[i];
    rdma_drv_qp::create_qp(sys.nodes[i].drv, init, qp, status);
    expect_ok("create QP", status);
  endtask

  // 功能：qp 经 INIT/RTR/RTS 连接到对端（MTU 1024，timeout 3，min_rnr 1）。
  // 输入/输出及副作用：QP modify。
  // 失败/边界：失败报告 UVM_FATAL。
  task connect_qp(int unsigned i, rdma_drv_qp qp, int unsigned peer, rdma_drv_qp peer_qp);
    rdma_drv_qp_attr attr;
    rdma_status status;

    attr = rdma_drv_qp_attr::type_id::create("pcie_init");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_ACCESS;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.access = RDMA_RIGHT_REMOTE_READ | RDMA_RIGHT_REMOTE_WRITE;
    qp.modify(sys.nodes[i].drv, attr, status);
    expect_ok("INIT", status);
    attr = rdma_drv_qp_attr::type_id::create("pcie_rtr");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_DEST_QPN |
                rdma_drv_qp_attr::M_RQ_PSN | rdma_drv_qp_attr::M_PATH_MTU |
                rdma_drv_qp_attr::M_AV | rdma_drv_qp_attr::M_MIN_RNR;
    attr.state = RDMA_DRV_QPS_RTR;
    attr.dest_qpn = peer_qp.qpn;
    attr.rq_psn = 0;
    attr.path_mtu = 1024;
    attr.dmac = macs[peer];
    attr.min_rnr = 1;
    qp.modify(sys.nodes[i].drv, attr, status);
    expect_ok("RTR", status);
    attr = rdma_drv_qp_attr::type_id::create("pcie_rts");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN |
                rdma_drv_qp_attr::M_TIMEOUT;
    attr.state = RDMA_DRV_QPS_RTS;
    attr.sq_psn = 0;
    attr.timeout = 3;
    qp.modify(sys.nodes[i].drv, attr, status);
    expect_ok("RTS", status);
  endtask

  // 功能：节点 n 的 CQ 在 2000 次（每次 100ns）内得到 1 个完成并检查 wr_id/成功。
  // 输入/输出及副作用：轮询 CQ。
  // 失败/边界：超时报告 UVM_FATAL，不符报告 UVM_ERROR。
  task expect_one(string label, int unsigned n, longint unsigned wr_id);
    rdma_drv_wc wcs[$];
    rdma_status status;

    for (int t = 0; t < 2000 && wcs.size() == 0; t++) begin
      rdma_drv_wr::poll_cq(sys.nodes[n].drv, cqs[n], 1, wcs, status);
      expect_ok("poll", status);
      if (wcs.size() == 0)
        #100ns;
    end
    if (wcs.size() == 0)
      `uvm_fatal(label, "no completion")
    if (wcs[0].wr_id != wr_id || wcs[0].status != RDMA_DRV_WC_SUCCESS)
      `uvm_error(label, $sformatf("completion %0d/%s (ecode %02h), expected %0d", wcs[0].wr_id,
                                  wcs[0].status.name(), wcs[0].vendor_err, wr_id))
  endtask

  // 功能：节点 a→b：建一对 QP，SEND 300B 进 b 的 RECV、WRITE 128B，两端完成且 b 内存一致。
  // 输入/输出及副作用：创建 QP，读写缓冲。
  // 失败/边界：不符报告 UVM_ERROR。
  task transfer(int unsigned a, int unsigned b);
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_bytes_t data;
    rdma_bytes_t got;
    rdma_status status;

    make_qp(a, qa);
    make_qp(b, qb);
    connect_qp(a, qa, b, qb);
    connect_qp(b, qb, a, qa);
    rwr = rdma_drv_recv_wr::type_id::create("pcie_recv");
    rwr.wr_id = next_wr_id++;
    rwr.sges.push_back(rdma_drv_sge::make(bufs[b].iova + 'h1000, 'h400, mrs[b].key()));
    rdma_drv_wr::post_recv(sys.nodes[b].drv, qb, rwr, status);
    expect_ok("post_recv", status);
    data = new[300];
    foreach (data[k])
      data[k] = 8'(a * 31 + k);
    expect_ok("fill", sys.nodes[a].hw.write(bufs[a], 0, data));
    wr = rdma_drv_send_wr::type_id::create("pcie_send");
    wr.wr_id = next_wr_id++;
    wr.opcode = RDMA_DRV_WR_SEND;
    wr.sges.push_back(rdma_drv_sge::make(bufs[a].iova, 300, mrs[a].key()));
    rdma_drv_wr::post_send(sys.nodes[a].drv, qa, wr, status);
    expect_ok("post SEND", status);
    expect_one($sformatf("SEND %0d->%0d", a, b), a, wr.wr_id);
    expect_one($sformatf("RECV %0d->%0d", a, b), b, rwr.wr_id);
    expect_ok("read back", sys.nodes[b].hw.read(bufs[b], 'h1000, 300, got));
    foreach (data[k])
      if (got[k] != data[k]) begin
        `uvm_error("PCIE_RDMA", $sformatf("SEND %0d->%0d byte %0d differs", a, b, k))
        break;
      end
    wr = rdma_drv_send_wr::type_id::create("pcie_write");
    wr.wr_id = next_wr_id++;
    wr.opcode = RDMA_DRV_WR_WRITE;
    wr.sges.push_back(rdma_drv_sge::make(bufs[a].iova, 128, mrs[a].key()));
    wr.remote_va = bufs[b].iova + 'h2000;
    wr.rkey = mrs[b].key();
    rdma_drv_wr::post_send(sys.nodes[a].drv, qa, wr, status);
    expect_ok("post WRITE", status);
    expect_one($sformatf("WRITE %0d->%0d", a, b), a, wr.wr_id);
    expect_ok("read back", sys.nodes[b].hw.read(bufs[b], 'h2000, 128, got));
    for (int k = 0; k < 128; k++)
      if (got[k] != data[k]) begin
        `uvm_error("PCIE_RDMA", $sformatf("WRITE %0d->%0d byte %0d differs", a, b, k))
        break;
      end
  endtask

  // 功能：设备 DMA 全部经 PCIe：EP 发出的 MemRd/MemWr 都到达 RC（数量相等且均非零），每个 Function
  //   的 BDF 都以 requester ID 出现，RC 收到的请求都来自这些 BDF。
  // 输入/输出及副作用：只读计数。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_dma();
    int unsigned seen;
    bit counted[bit [15:0]];

    #1us;
    `uvm_info("PCIE_RDMA", $sformatf("DMA TLPs: MemRd %0d/%0d, MemWr %0d/%0d (EP sent/RC served)",
                                     pcie.dma_read_tlps, pcie.host_reads, pcie.dma_write_tlps,
                                     pcie.host_writes), UVM_LOW)
    if (pcie.dma_read_tlps == 0 || pcie.dma_write_tlps == 0 ||
        pcie.host_reads != pcie.dma_read_tlps || pcie.host_writes != pcie.dma_write_tlps)
      `uvm_error("PCIE_RDMA", "device DMA TLPs sent by the EPs and served by the RCs differ")
    seen = 0;
    foreach (sys.nodes[i]) begin
      if (!pcie.host_requesters.exists(sys.nodes[i].func.pcie_id.bdf))
        `uvm_error("PCIE_RDMA", $sformatf("%s BDF %04h issued no DMA",
                                          dpu_function_key_name(sys.nodes[i].func.key),
                                          sys.nodes[i].func.pcie_id.bdf))
      else if (!counted.exists(sys.nodes[i].func.pcie_id.bdf)) begin
        // 不同 Host 的 Function 可有相同 BDF（各自的 PCIe 域），只计一次。
        counted[sys.nodes[i].func.pcie_id.bdf] = 1'b1;
        seen += pcie.host_requesters[sys.nodes[i].func.pcie_id.bdf];
      end
    end
    if (seen != pcie.host_reads + pcie.host_writes)
      `uvm_error("PCIE_RDMA", "RC served DMA requests from an unknown requester ID")
  endtask

  // 功能：每次驱动 BAR 写都是一个 MemWr TLP 且在 EP 被解码到设备（发送数 = 各 BAR 记录数之和 =
  //   解码数，无拒绝）；随后对 Host0 PF0 的 MAILBOX BAR 发 MemWr，EP 拒绝且不到达设备。
  // 输入/输出及副作用：发一个 MemWr。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_mmio();
    pcie_tl_rw_seq seq;
    int unsigned recorded;
    int unsigned routed;

    recorded = 0;
    foreach (sys.nodes[i]) begin
      recorded += sys.nodes[i].bar.written_offsets.size();
      `uvm_info("PCIE_RDMA", $sformatf("%s BAR0 %016h (random placement)",
                                       dpu_function_key_name(sys.nodes[i].func.key),
                                       sys.nodes[i].func.bar0.base), UVM_LOW)
    end
    #1us;
    if (recorded == 0 || pcie.sent_writes != recorded || pcie.decoded_writes != recorded ||
        pcie.rejected_writes != 0)
      `uvm_error("PCIE_RDMA", $sformatf("BAR writes %0d, TLPs %0d, decoded %0d, rejected %0d",
                                        recorded, pcie.sent_writes, pcie.decoded_writes,
                                        pcie.rejected_writes))
    routed = sys.router.routed;
    seq = pcie_tl_rw_seq::type_id::create("mailbox_wr");
    seq.op = PCIE_RW_WRITE;
    seq.addr = sys.nodes[0].func.mailbox.base + RDMA_NOTIFY_WINDOW_OFFSET;
    seq.byte_len = 8;
    seq.wdata = new[8];
    seq.start(pcie.rc_seqr(0));
    #1us;
    if (pcie.rejected_writes != 1 || sys.router.routed != routed)
      `uvm_error("PCIE_RDMA", $sformatf("MAILBOX MemWr: rejected %0d, routed delta %0d",
                                        pcie.rejected_writes, sys.router.routed - routed))
  endtask
endclass
