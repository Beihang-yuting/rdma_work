// 目录：集成测试层 integration/rdma_tb_host_mem_test.sv。
// 层：集成测试。
// 职责：rdma_tb_flow_test 在真实 host_mem 上运行：每节点一个外部 host_mem manager（不重叠的物理
//   区间与 IOVA 域）经 rdma_host_mem_adapter 供驱动分配与设备 DMA，wire 仍为 loopback；同一流量序列
//   与记分板。rdma_tb_e2e_test 在此之上把 wire 换成 net_packet。
// 依赖：rdma_tb_flow_test、rdma_host_mem_adapter、外部 host_mem_manager。
// 所有权：host_mem manager/adapter 由测试创建。
// 生命周期：仿真期间常驻。

class rdma_tb_host_mem_test extends rdma_tb_flow_test;
  `uvm_component_utils(rdma_tb_host_mem_test)

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_tb_host_mem_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：为节点建立独立的真实 host_mem（buddy 区间与 IOVA 基址按节点错开）。
  // 输入/输出及副作用：返回 adapter。
  // 失败/边界：无。
  virtual function rdma_host_mem_api make_host_mem(int unsigned n);
    rdma_host_mem_external_pkg::host_mem_manager host_mem;
    rdma_host_mem_adapter adapter;

    host_mem = rdma_host_mem_external_pkg::host_mem_manager::type_id::create(
      $sformatf("tb_host_mem%0d", n));
    host_mem.init_region(64'h0000_000a_0000_0000 + n * 64'h1_0000_0000,
                         64'h0000_000a_00ff_ffff + n * 64'h1_0000_0000,
                         MODE_BUDDY, 16, 8'ha0 + n);
    adapter = rdma_host_mem_adapter::type_id::create($sformatf("tb_host_adapter%0d", n));
    adapter.mem = host_mem;
    adapter.iova_base = 64'h0000_0030_0000_0000 + n * 64'h10_0000_0000;
    return adapter;
  endfunction
endclass
