// 目录：测试支撑层 tests/support/rdma_host_mem_factory.sv。
// 层：测试支撑。
// 职责：真实 host_mem 的 Function 内存工厂：每个 Host 一个 host_mem manager（区间按 Host 错开，host_id
//   为 Host 号），每个 Function 一个恒等 IOVA 的 adapter（PCIe 上没有 IOMMU，设备发出的 IOVA 即 Host
//   内存地址）。
// 依赖：rdma_host_mem_external_pkg（外部 host_mem_manager）、rdma_host_mem_adapter。
// 所有权：工厂拥有各 Host 的 manager。
// 生命周期：随测试存在。
class rdma_host_mem_factory extends rdma_dpu_mem_factory;
  `uvm_object_utils(rdma_host_mem_factory)

  localparam bit [63:0] REGION_BASE = 64'h0000_0040_0000_0000;
  localparam bit [63:0] REGION_STRIDE = 64'h0000_0001_0000_0000;
  localparam bit [63:0] REGION_BYTES = 64'h0000_0000_0100_0000;

  host_mem_api managers[int unsigned];

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_host_mem_factory");
    super.new(name);
  endfunction

  // 功能：Function f 的主机内存：其 Host 的 manager（首次使用时建立）之上的恒等 IOVA adapter。
  // 输入/输出及副作用：可能新建 manager；返回新 adapter。
  // 失败/边界：无。
  virtual function rdma_host_mem_api make(rdma_dpu_function f);
    rdma_host_mem_external_pkg::host_mem_manager manager;
    rdma_host_mem_adapter adapter;
    int unsigned h;

    h = f.key.host_id;
    if (!managers.exists(h)) begin
      manager = rdma_host_mem_external_pkg::host_mem_manager::type_id::create(
        $sformatf("host_mem%0d", h));
      manager.init_region(REGION_BASE + h * REGION_STRIDE,
                          REGION_BASE + h * REGION_STRIDE + REGION_BYTES - 1, MODE_BUDDY, 16);
      manager.set_host_id(h);
      managers[h] = manager;
    end
    adapter = rdma_host_mem_adapter::type_id::create($sformatf("host_mem_f%0d", f.global_id));
    adapter.mem = managers[h];
    return adapter;
  endfunction
endclass
