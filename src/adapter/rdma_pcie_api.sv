// 中文说明：rdma_pcie_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_pcie_api extends uvm_object;

  function new(string name = "rdma_pcie_api");
    super.new(name);
  endfunction

  pure virtual task cfg_read32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    output bit [31:0] data,
    output rdma_status status
  );

  pure virtual task cfg_write32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    bit [31:0] data,
    bit [3:0] byte_enable,
    output rdma_status status
  );

  pure virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );

  pure virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );

  pure virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );

  pure virtual function rdma_status get_function_info(
    rdma_bdf_t bdf,
    output rdma_pcie_function_info info
  );

  pure virtual function rdma_status decode_bar(
    rdma_bar_addr_t address,
    output rdma_bar_decode result
  );
endclass
