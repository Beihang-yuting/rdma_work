// 目录：适配器接口层 adapter/rdma_pcie_api.sv。
// 职责：定义 PCIe 后端抽象接口（配置空间、MMIO、屏障、Function/BAR 查询）与 SR-IOV 快照类型。
// 依赖：rdma_bdf_t、rdma_bar_addr_t、rdma_function_handle、rdma_status 等类型/模型。
// 所有权与生命周期：抽象接口不持有外部资源；快照为值拷贝，生命周期由调用方管理。

// 功能：保存 PCIe SR-IOV capability 的值快照，供枚举 sequence 读取 PF/VF 拓扑与 VF BAR。
// 输入/输出及副作用：字段由 discover_sriov() 填充；数组为值拷贝，修改不影响外部 manager。
// 失败/边界：cap_offset、first_vf_offset、vf_stride 或 total_vfs 为零时视为不可枚举；结构本身无错误码。
typedef struct {
  bit [11:0] cap_offset;
  bit [15:0] first_vf_offset;
  bit [15:0] vf_stride;
  bit [15:0] total_vfs;
  bit [15:0] num_vfs;
  bit        ari_capable_hierarchy;
  bit        ari_capable;
  bit        vf_enable;
  bit        vf_mse;
  bit [15:0] vf_device_id;
  bit [63:0] vf_bar_base[6];
  bit [63:0] vf_bar_size[6];
  bit [31:0] vf_bar_flags[6];
  bit [2:0]  vf_bar_owner[6];
} rdma_pcie_sriov_info;

virtual class rdma_pcie_api extends uvm_object;

  // 功能：构造 PCIe API 对象。
  // 输入/输出及副作用：name 为对象名。
  // 失败/边界：无。
  function new(string name = "rdma_pcie_api");
    super.new(name);
  endfunction

  // 功能：发现 PF 的 SR-IOV capability 并输出值快照；默认实现不支持，backend 可覆盖。
  // 输入/输出及副作用：pf_bdf 输入、info 输出；默认将 info 清零。
  // 失败/边界：默认返回 UNSUPPORTED_OPCODE，避免全零快照被误认为有效拓扑。
  virtual function rdma_status discover_sriov(
    rdma_bdf_t pf_bdf,
    output rdma_pcie_sriov_info info
  );
    info = '{default:'0};
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                             "PCIe backend does not expose SR-IOV discovery");
  endfunction

  // 功能：读取目标 BDF 配置空间的 32 位寄存器。
  // 输入/输出及副作用：target/offset 输入，data/status 输出。
  // 失败/边界：后端拒绝或 offset 越界通过 status 返回。
  pure virtual task cfg_read32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    output bit [31:0] data,
    output rdma_status status
  );

  // 功能：写目标 BDF 配置空间的 32 位寄存器。
  // 输入/输出及副作用：target/offset/data/byte_enable 输入，status 输出。
  // 失败/边界：配置空间拒绝、offset 越界、byte_enable 非法、权限错误或超时写入 status。
  pure virtual task cfg_write32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    bit [31:0] data,
    bit [3:0] byte_enable,
    output rdma_status status
  );

  // 功能：向 Function 的 BAR 地址写 MMIO 数据。
  // 输入/输出及副作用：function_h/address/data 输入，status 输出；成功后调用方才可推进本地游标。
  // 失败/边界：后端拒绝或范围溢出通过 status 返回，不推进游标。
  pure virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );

  // 功能：执行 DMA 可见性屏障，确保 doorbell 前的数据写已按序可见。
  // 输入/输出及副作用：function_h 输入，status 输出。
  // 失败/边界：失败或超时通过 status 发布，不隐式重试。
  pure virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );

  // 功能：执行 MMIO 顺序屏障，保证此前的 MMIO 写按序到达。
  // 输入/输出及副作用：function_h 输入，status 输出。
  // 失败/边界：失败或超时通过 status 发布，不隐式重试。
  pure virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );

  // 功能：按 BDF 查询冻结的 PCIe Function 信息，返回 detached 快照。
  // 输入/输出及副作用：bdf 输入，info 输出。
  // 失败/边界：记录缺失、不唯一或 generation/reset epoch 过期时返回错误，不回退默认值。
  pure virtual function rdma_status get_function_info(
    rdma_bdf_t bdf,
    output rdma_pcie_function_info info
  );

  // 功能：按 BAR 地址解码 BAR 描述。
  // 输入/输出及副作用：address 输入，result 输出 detached 解码结果。
  // 失败/边界：地址无法解码或校验失败时不发布部分字段。
  pure virtual function rdma_status decode_bar(
    rdma_bar_addr_t address,
    output rdma_bar_decode result
  );
endclass
