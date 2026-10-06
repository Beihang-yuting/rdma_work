// 目录：设备层 src/dev/rdma_dev_dma.sv。
// 职责：设备 DMA 端口：设备（CMQ 与数据面 NIC）对主机内存的全部读写都经由本端口的 task。默认实现
//   为后门：直接调用 rdma_host_mem_api.dma_read/dma_write（零仿真时间）；PCIe 集成以 factory 覆盖为
//   经 pcie_work EP 发 MemRd/MemWr 的实现。
// 依赖：rdma_host_mem_api。
// 所有权与生命周期：host_mem 只借用；由 rdma_dev_cmq.configure 创建，设备内 CMQ 与 NIC 共用。
class rdma_dev_dma extends uvm_object;
  `rdma_object_utils(rdma_dev_dma)

  rdma_host_mem_api host_mem;

  // 功能：构造未绑定的端口。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：未绑定 host_mem 时读写返回 INVALID_STATE。
  function new(string name = "rdma_dev_dma");
    super.new(name);
    host_mem = null;
  endfunction

  // 功能：按 IOVA 读 size 字节。
  // 输入/输出及副作用：bytes 输出；后门读主机内存。
  // 失败/边界：未绑定或 DMA 失败返回错误 status，bytes 为空。
  virtual task read(bit [63:0] iova, int unsigned size, output byte unsigned bytes[],
                    output rdma_status status);
    byte raw[];

    bytes = new[0];
    if (host_mem == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "device DMA port is not bound");
      return;
    end
    status = host_mem.dma_read(iova, size, raw);
    if (!status.ok())
      return;
    bytes = new[raw.size()];
    foreach (raw[i])
      bytes[i] = raw[i];
  endtask

  // 功能：按 IOVA 写 bytes。
  // 输入/输出及副作用：后门写主机内存。
  // 失败/边界：未绑定或 DMA 失败返回错误 status。
  virtual task write(bit [63:0] iova, byte unsigned bytes[], output rdma_status status);
    byte raw[];

    if (host_mem == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "device DMA port is not bound");
      return;
    end
    raw = new[bytes.size()];
    foreach (raw[i])
      raw[i] = bytes[i];
    status = host_mem.dma_write(iova, raw);
  endtask
endclass
