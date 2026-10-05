// 目录：集成测试层 integration/rdma_tb_e2e_test.sv。
// 职责：rdma_tb_flow_test 的端到端版本：每节点真实 host_mem（manager + adapter + proxy），
//   wire 替换为经 net_packet RoCEv2 帧编码/解码（含 checksum/ICRC）的实现，复用同一流量序列与记分板。
// 依赖：rdma_tb_flow_test、rdma_real_host_mem_proxy、net_packet adapter/bridge。
// 所有权与生命周期：host_mem/adapter/proxy 由测试创建并在仿真期间常驻；wire 持有各节点 net adapter。

// 经 net_packet 帧编解码的 wire：源节点 adapter 编码发送，目的节点 adapter 从其 sink 解码接收。
class rdma_tb_net_wire extends rdma_wire;
  `uvm_component_utils(rdma_tb_net_wire)

  protected rdma_net_packet_adapter nets[int unsigned];
  protected rdma_net_packet_queue_sink sinks[int unsigned];

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_tb_net_wire", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：为节点创建并配置 net_packet adapter 与 sink。
  // 输入/输出及副作用：登记 nets/sinks。
  // 失败/边界：配置失败返回错误。
  function rdma_status add_node(int unsigned node_id, rdma_function_identity identity);
    rdma_status status;

    sinks[node_id] = rdma_net_packet_queue_sink::type_id::create($sformatf("sink%0d", node_id));
    nets[node_id] = rdma_net_packet_adapter::type_id::create($sformatf("net%0d", node_id));
    status = nets[node_id].configure_sink(sinks[node_id]);
    if (status.ok())
      status = nets[node_id].configure_function(identity);
    return status;
  endfunction

  // 功能：源 adapter 编码成帧发送，帧副本放入目的 sink，由目的 adapter 解码为语义报文。
  // 输入/输出及副作用：更新两端 adapter/sink 统计。
  // 失败/边界：节点未登记或编解码失败返回错误。
  virtual task carry(
    int unsigned src_node,
    int unsigned dst_node,
    rdma_packet packet,
    output rdma_packet delivered,
    output rdma_status status
  );
    delivered = null;
    if (!nets.exists(src_node) || !nets.exists(dst_node)) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "net wire node is not registered");
      return;
    end
    nets[src_node].send_packet(packet, status);
    if (status == null || !status.ok())
      return;
    sinks[dst_node].enqueue(nets[src_node].last_sent_packet);
    nets[dst_node].receive_packet(delivered, status);
  endtask
endclass

class rdma_tb_e2e_test extends rdma_tb_flow_test;
  `uvm_component_utils(rdma_tb_e2e_test)

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_tb_e2e_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：把 env 的 wire 替换为 net_packet 实现后建环境。
  // 输入/输出及副作用：注册 factory type override。
  // 失败/边界：无。
  function void build_phase(uvm_phase phase);
    rdma_wire::type_id::set_type_override(rdma_tb_net_wire::get_type());
    super.build_phase(phase);
  endfunction

  // 功能：为节点建立独立的真实 host_mem（不重叠的物理区间与 IOVA 域）并接入 fixture。
  // 输入/输出及副作用：写 fx.mem。
  // 失败/边界：无。
  virtual function void prepare_fixture(int unsigned n, rdma_queue_data_engine_fixture fx);
    rdma_host_mem_external_pkg::host_mem_manager host_mem;
    rdma_host_mem_adapter adapter;
    rdma_real_host_mem_proxy proxy;

    host_mem = rdma_host_mem_external_pkg::host_mem_manager::type_id::create(
      $sformatf("tb_host_mem%0d", n));
    host_mem.init_region(64'h0000_000a_0000_0000 + n * 64'h1_0000_0000,
                         64'h0000_000a_00ff_ffff + n * 64'h1_0000_0000,
                         MODE_BUDDY, 16, 8'ha0 + n);
    adapter = rdma_host_mem_adapter::type_id::create($sformatf("tb_host_adapter%0d", n));
    adapter.mem = host_mem;
    adapter.iova_base = 64'h0000_0030_0000_0000 + n * 64'h10_0000_0000;
    proxy = rdma_real_host_mem_proxy::type_id::create($sformatf("tb_mem_proxy%0d", n));
    proxy.delegate = adapter;
    fx.mem = proxy;
  endfunction

  // 功能：为每个节点登记 net_packet adapter（Function identity 取自 fixture binding）。
  // 输入/输出及副作用：配置 env.fabric。
  // 失败/边界：wire 类型不符或配置失败报 UVM_FATAL。
  virtual function void attach_fabric();
    rdma_tb_net_wire net;

    if (!$cast(net, env.fabric))
      `uvm_fatal("TB_E2E", "env fabric is not the net_packet wire")
    foreach (fixtures[n])
      expect_ok("net wire add_node",
                net.add_node(n, fixtures[n].binding.function_identity_snapshot()));
  endfunction
endclass
