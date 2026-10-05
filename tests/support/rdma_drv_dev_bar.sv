// 目录：测试支撑层 tests/support/rdma_drv_dev_bar.sv。
// 职责：把驱动模型的 BAR 寄存器写直接交给设备模型（无 PCIe 传输层的单元测试连线）。
// 依赖：rdma_drv_bar、rdma_dev。
// 所有权与生命周期：只借用设备实例；记录写入序列供测试断言。
class rdma_drv_dev_bar extends rdma_drv_bar;
  `uvm_object_utils(rdma_drv_dev_bar)

  rdma_dev dev;
  bit [63:0] written_offsets[$];
  bit [63:0] written_values[$];

  // 功能：构造未连接的 BAR。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：dev 为 null 时写返回 INVALID_STATE。
  function new(string name = "rdma_drv_dev_bar");
    super.new(name);
    dev = null;
  endfunction

  // 功能：记录并转交寄存器写。
  // 输入/输出及副作用：调用 dev.write_register。
  // 失败/边界：未连接设备返回 INVALID_STATE；设备拒绝时透传其 status。
  virtual task write64(bit [63:0] offset, bit [63:0] value, output rdma_status status);
    written_offsets.push_back(offset);
    written_values.push_back(value);
    if (dev == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "BAR is not connected to a device");
      return;
    end
    status = dev.write_register(offset, value);
  endtask
endclass
