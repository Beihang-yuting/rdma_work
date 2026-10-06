// 目录：单元测试层 unit/rdma_tb_flow_test.sv。
// 层：单元测试。
// 职责：两节点 seq → 驱动模型 → 设备模型 → 报文 → 内存全流程：每节点一个设备模型（rdma_dev）与
//   经 BAR/CMQ probe 的驱动模型（PD、CQ、RC/UD/URC QP、覆盖 64KiB 数据缓冲的 MR），rdma_tb_env
//   （verb agent + wire + 记分板）运行 rdma_tb_traffic_vseq，记分板判定完成与内存逐字节一致。
//   主机与设备之间只经 CMQ、MMIO doorbell 与 DMA 交互。
// 依赖：rdma_drv_*、rdma_dev、rdma_drv_dev_bar、rdma_mock_host_mem、rdma_tb_pkg。
// 所有权：测试拥有各节点内存、设备与驱动对象；env 组件只借用。
// 生命周期：节点在仿真期间常驻（不做 remove）。

class rdma_tb_flow_test extends uvm_test;
  `uvm_component_utils(rdma_tb_flow_test)

  localparam int unsigned DATA_MR_BYTES = 'h10000;

  rdma_tb_env env;
  rdma_host_mem_api mems[2];
  // QP 的 SQ/RQ 深度（子类可调小以覆盖环满与回绕）。
  int unsigned qp_depth;

  // 功能：构造测试。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_tb_flow_test", uvm_component parent = null);
    super.new(name, parent);
    qp_depth = 256;
  endfunction

  // 功能：创建两节点环境。
  // 输入/输出及副作用：创建 env。
  // 失败/边界：无。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = rdma_tb_env::type_id::create("env", this);
  endfunction

  // 功能：建立两节点资源、互连 QP 并运行流量，等待全部结算。
  // 输入/输出及副作用：持有 objection 直到流量结束。
  // 失败/边界：资源建立失败报 UVM_FATAL；数据错误由记分板报告。
  task run_phase(uvm_phase phase);
    rdma_tb_node_cfg nodes[int unsigned];

    phase.raise_objection(this);
    for (int unsigned n = 0; n < 2; n++)
      make_node(n, nodes[n]);
    for (int unsigned n = 0; n < 2; n++)
      connect_node(nodes[n], nodes[1 - n]);
    attach_fabric();
    env.configure(nodes);
    run_traffic();
    env.wait_idle(500us);
    if (env.sb.checked == 0)
      `uvm_error("TB_FLOW", "scoreboard checked nothing")
    foreach (nodes[n])
      if (nodes[n].dev.nic.errors.size() != 0)
        `uvm_error("TB_FLOW", $sformatf("node %0d device errors: %p", n,
                                        nodes[n].dev.nic.errors))
    phase.drop_objection(this);
  endtask

  // 功能：运行流量序列（子类可替换）。
  // 输入/输出及副作用：经 env 各节点 sequencer 下发 verb。
  // 失败/边界：结果由记分板判定。
  virtual task run_traffic();
    rdma_tb_traffic_vseq vseq;

    vseq = rdma_tb_traffic_vseq::type_id::create("vseq");
    vseq.env = env;
    vseq.start(null);
  endtask

  // 功能：建立一个节点：主机内存、设备、BAR、probe、PD、CQ、RC/UD QP、数据缓冲与覆盖它的 MR。
  // 输入/输出及副作用：返回节点配置；分配主机内存。
  // 失败/边界：任一步失败报 UVM_FATAL。
  task automatic make_node(int unsigned n, output rdma_tb_node_cfg cfg);
    rdma_drv_dev_bar bar;
    rdma_drv_hw hw;
    rdma_drv_config dcfg;
    rdma_function_handle fn;
    rdma_drv_pd pd;
    bit [63:0] pages[$];
    rdma_status status;

    cfg = rdma_tb_node_cfg::type_id::create($sformatf("node%0d_cfg", n));
    cfg.node_id = n;
    cfg.mac = 48'h02_00_00_00_10_00 + n;
    mems[n] = make_host_mem(n);
    cfg.dev = rdma_dev::type_id::create($sformatf("tb_dev%0d", n));
    cfg.dev.configure(mems[n]);
    bar = rdma_drv_dev_bar::type_id::create($sformatf("tb_bar%0d", n));
    bar.dev = cfg.dev;
    fn = rdma_function_handle::type_id::create($sformatf("tb_fn%0d", n));
    fn.kind = RDMA_RESOURCE_FUNCTION;
    fn.function_uid = n + 1;
    fn.generation = 1;
    hw = rdma_drv_hw::type_id::create($sformatf("tb_hw%0d", n));
    expect_ok("bind", hw.bind_hw(bar, mems[n], fn));
    dcfg = rdma_drv_config::type_id::create($sformatf("tb_drv_cfg%0d", n));
    cfg.drv = rdma_drv_dev::type_id::create($sformatf("tb_drv%0d", n));
    cfg.drv.probe(dcfg, hw, status);
    expect_ok("probe", status);
    expect_ok("alloc PD", rdma_drv_pd::alloc(cfg.drv, pd));
    rdma_drv_cq::create_cq(cfg.drv, 256, 0, cfg.cq, status);
    expect_ok("create CQ", status);
    // qp_index 0/1/2 = RC/UD/URC，与对端同索引 QP 互连；URC 用专属 CQ（rc_to_urc 下创建 RC QP）。
    add_qp(cfg, pd, RDMA_DRV_QPT_RC, n, cfg.cq);
    add_qp(cfg, pd, RDMA_DRV_QPT_UD, n, cfg.cq);
    rdma_drv_cq::create_cq(cfg.drv, 256, 0, cfg.urc_cq, status);
    expect_ok("create URC CQ", status);
    cfg.drv.cfg.rc_to_urc = 1'b1;
    add_qp(cfg, pd, RDMA_DRV_QPT_RC, n, cfg.urc_cq);
    cfg.drv.cfg.rc_to_urc = 1'b0;
    expect_ok("alloc data buffer", hw.alloc_dma(DATA_MR_BYTES, 4096, cfg.data_buf));
    for (int unsigned i = 0; i < DATA_MR_BYTES / 4096; i++)
      pages.push_back(cfg.data_buf.iova + i * 4096);
    rdma_drv_mr::reg_mr(cfg.drv, pd, cfg.data_buf.iova, DATA_MR_BYTES,
                        rdma_drv_mr::rights_of(1, 1, 1, 1), pages, cfg.data_mr, status);
    expect_ok("reg data MR", status);
  endtask

  // 功能：创建一个 QP（收发都用 cq）并登记为与对端节点同索引 QP 互连。
  // 输入/输出及副作用：追加 cfg.qps。
  // 失败/边界：失败报 UVM_FATAL。
  task automatic add_qp(rdma_tb_node_cfg cfg, rdma_drv_pd pd, rdma_drv_qp_type_e qp_type,
                        int unsigned n, rdma_drv_cq cq);
    rdma_drv_qp_init_attr attr;
    rdma_tb_qp_link link;
    rdma_status status;

    attr = rdma_drv_qp_init_attr::type_id::create("tb_qp_attr");
    attr.qp_type = qp_type;
    attr.pd = pd;
    attr.send_cq = cq;
    attr.recv_cq = cq;
    attr.max_send_sge = 4;
    attr.max_recv_sge = 4;
    attr.max_send_wr = qp_depth;
    attr.max_recv_wr = qp_depth;
    link = rdma_tb_qp_link::type_id::create("link");
    rdma_drv_qp::create_qp(cfg.drv, attr, link.qp, status);
    expect_ok($sformatf("create %s QP", qp_type.name()), status);
    link.peer_node = 1 - n;
    link.peer_qp_index = cfg.qps.size();
    cfg.qps.push_back(link);
  endtask

  // 功能：把节点 x 的各 QP 推到 RTS：RC 指向对端同索引 QP（目的 QPN、PSN、MTU、目的 MAC），
  //   UD 设置 Q_Key。
  // 输入/输出及副作用：修改 x 的 QP。
  // 失败/边界：失败报 UVM_FATAL。
  task automatic connect_node(rdma_tb_node_cfg x, rdma_tb_node_cfg y);
    rdma_drv_qp_attr attr;
    rdma_drv_qp qp;
    rdma_status status;

    foreach (x.qps[i]) begin
      qp = x.qps[i].qp;
      attr = rdma_drv_qp_attr::type_id::create("tb_init");
      attr.mask = rdma_drv_qp_attr::M_STATE;
      attr.state = RDMA_DRV_QPS_INIT;
      if (qp.qp_type == RDMA_DRV_QPT_UD) begin
        attr.mask |= rdma_drv_qp_attr::M_QKEY;
        attr.qkey = x.ud_qkey;
      end
      else begin
        attr.mask |= rdma_drv_qp_attr::M_ACCESS;
        attr.access = RDMA_RIGHT_REMOTE_READ | RDMA_RIGHT_REMOTE_WRITE |
                      RDMA_RIGHT_REMOTE_ATOMIC;
      end
      qp.modify(x.drv, attr, status);
      expect_ok("INIT", status);
      attr = rdma_drv_qp_attr::type_id::create("tb_rtr");
      attr.mask = rdma_drv_qp_attr::M_STATE;
      attr.state = RDMA_DRV_QPS_RTR;
      if (qp.qp_type == RDMA_DRV_QPT_RC) begin
        attr.mask |= rdma_drv_qp_attr::M_DEST_QPN | rdma_drv_qp_attr::M_RQ_PSN |
                     rdma_drv_qp_attr::M_PATH_MTU | rdma_drv_qp_attr::M_AV;
        attr.dest_qpn = y.qps[x.qps[i].peer_qp_index].qp.qpn;
        attr.rq_psn = 0;
        attr.path_mtu = x.mtu;
        attr.dmac = y.mac;
      end
      qp.modify(x.drv, attr, status);
      expect_ok("RTR", status);
      attr = rdma_drv_qp_attr::type_id::create("tb_rts");
      attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN;
      attr.state = RDMA_DRV_QPS_RTS;
      attr.sq_psn = 0;
      qp.modify(x.drv, attr, status);
      expect_ok("RTS", status);
    end
  endtask

  // 功能：子类钩子：节点的主机内存实现（默认 mock）。
  // 输入/输出及副作用：返回新内存对象。
  // 失败/边界：无。
  virtual function rdma_host_mem_api make_host_mem(int unsigned n);
    rdma_mock_host_mem mem;

    mem = rdma_mock_host_mem::type_id::create($sformatf("tb_mem%0d", n));
    return mem;
  endfunction

  // 功能：子类钩子：节点建立后、env 配置前完成 wire 的外部依赖配置（默认 loopback 无需配置）。
  // 输入/输出及副作用：可配置 env.fabric。
  // 失败/边界：无。
  virtual function void attach_fabric();
  endfunction

  // 功能：断言 status 成功。
  // 输入/输出及副作用：失败时报 UVM_FATAL。
  // 失败/边界：无。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("TB_FLOW", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction
endclass
