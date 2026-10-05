// 目录：单元测试层 unit/rdma_tb_flow_test.sv。
// 职责：两节点 seq → 报文 → 内存全流程：每节点一个 queue-data engine fixture（mock host_mem），
//   注册数据 MR 后由 rdma_tb_env（verb agent + NIC 行为模型 + loopback wire + 记分板）
//   运行 rdma_tb_traffic_vseq，记分板判定完成与内存逐字节一致。
// 依赖：rdma_queue_data_engine_fixture、rdma_tb_pkg。
// 所有权与生命周期：fixture 与数据 MR 在仿真期间常驻（不做 cleanup），env 组件只借用。

class rdma_tb_flow_test extends uvm_test;
  `uvm_component_utils(rdma_tb_flow_test)

  localparam int unsigned DATA_MR_BYTES = 'h10000;

  rdma_tb_env env;
  rdma_queue_data_engine_fixture fixtures[2];

  // 功能：构造测试。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_tb_flow_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建两节点环境。
  // 输入/输出及副作用：创建 env。
  // 失败/边界：无。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = rdma_tb_env::type_id::create("env", this);
  endfunction

  // 功能：建立两节点资源并运行流量，等待全部结算。
  // 输入/输出及副作用：持有 objection 直到流量结束。
  // 失败/边界：资源建立失败报 UVM_FATAL；数据错误由记分板报告。
  task run_phase(uvm_phase phase);
    rdma_tb_node_cfg nodes[int unsigned];
    rdma_tb_traffic_vseq vseq;

    phase.raise_objection(this);
    for (int unsigned n = 0; n < 2; n++)
      make_node(n, nodes[n]);
    attach_fabric();
    env.configure(nodes);
    vseq = rdma_tb_traffic_vseq::type_id::create("vseq");
    vseq.env = env;
    vseq.start(null);
    env.wait_idle(500us);
    if (env.sb.checked == 0)
      `uvm_error("TB_FLOW", "scoreboard checked nothing")
    phase.drop_objection(this);
  endtask

  // 功能：建立一个节点：fixture（Function/PD/CQ/RC QP/engine）+ 数据 MR，并与对端 qp 0 互连。
  // 输入/输出及副作用：返回节点配置；分配 mock host 内存。
  // 失败/边界：任一步失败报 UVM_FATAL。
  task automatic make_node(int unsigned n, output rdma_tb_node_cfg cfg);
    rdma_queue_data_engine_fixture fx;
    rdma_tb_qp_link link;
    rdma_status status;

    fx = rdma_queue_data_engine_fixture::type_id::create($sformatf("tb_node%0d", n));
    fixtures[n] = fx;
    prepare_fixture(n, fx);
    fx.setup(status, 32, RDMA_CQE_BYTES, 16, 16, 1'b1);
    if (status == null || !status.ok())
      `uvm_fatal("TB_FLOW", $sformatf("node %0d fixture setup failed: %s", n,
                 status == null ? "null" : status.convert2string()))
    cfg = rdma_tb_node_cfg::type_id::create($sformatf("node%0d_cfg", n));
    cfg.node_id = n;
    cfg.engine = fx.engine;
    cfg.cq = fx.cq;
    link = rdma_tb_qp_link::type_id::create("link");
    link.qp = fx.qp;
    link.peer_node = 1 - n;
    link.peer_qp_index = 0;
    cfg.qps.push_back(link);
    register_data_mr(fx, cfg);
  endtask

  // 功能：分配 DATA_MR_BYTES 的 host 内存并经 resource manager 注册为全权限 ACTIVE MR。
  // 输入/输出及副作用：写 cfg.data_mr/data_mapping；manager 新增 MR。
  // 失败/边界：分配或生命周期任一步失败报 UVM_FATAL。
  function void register_data_mr(rdma_queue_data_engine_fixture fx, rdma_tb_node_cfg cfg);
    rdma_dma_request_context ctx;
    rdma_backing_ref ref_h;
    rdma_mr mr;
    rdma_status status;

    ctx = rdma_dma_request_context::type_id::create("tb_mr_ctx");
    ctx.function_h = fx.binding.make_handle();
    ctx.requester_bdf = fx.binding.queue_dma.requester_bdf;
    ctx.pasid_valid = fx.binding.queue_dma.pasid_valid;
    ctx.pasid = fx.binding.queue_dma.pasid;
    ctx.dma_domain_valid = fx.binding.queue_dma.dma_domain_valid;
    ctx.dma_domain_id = fx.binding.queue_dma.dma_domain_id;
    status = fx.mem.allocate(ctx, DATA_MR_BYTES, 4096, RDMA_DMA_BIDIRECTIONAL,
                             cfg.data_mapping);
    expect_ok("allocate data MR", status);
    expect_ok("create_mr", fx.manager.create_mr(fx.binding, fx.pd.handle, mr));
    mr.iova = cfg.data_mapping.iova;
    mr.length = DATA_MR_BYTES;
    mr.lkey = {mr.local_mr_id[23:0], 8'h3c};
    mr.rkey = mr.lkey;
    mr.access = '{local_write:1'b1, remote_read:1'b1, remote_write:1'b1,
                  memory_window_bind:1'b0, remote_atomic:1'b1};
    ref_h = rdma_backing_ref::type_id::create("tb_mr_ref");
    ref_h.mapping = cfg.data_mapping;
    ref_h.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    mr.backing_refs.push_back(ref_h);
    expect_ok("stage MR", fx.manager.stage_allocated(mr));
    expect_ok("commit MR", fx.manager.commit_programmed(mr));
    expect_ok("activate MR", fx.manager.activate(mr.handle));
    cfg.data_mr = mr;
  endfunction

  // 功能：子类钩子：fixture setup 前替换其 host 内存实现（默认使用 fixture 自带 mock）。
  // 输入/输出及副作用：可写 fx.mem。
  // 失败/边界：无。
  virtual function void prepare_fixture(int unsigned n, rdma_queue_data_engine_fixture fx);
  endfunction

  // 功能：子类钩子：节点建立后、env 配置前完成 wire 的外部依赖配置（默认 loopback 无需配置）。
  // 输入/输出及副作用：可读 fixtures、配置 env.fabric。
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
