// 目录：适配器接口层 adapter/rdma_pcie_api.sv。
// 职责：实现 rdma_pcie_api 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_pcie_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_pcie_api extends uvm_object;

  // 功能：构造 rdma_pcie_api，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_pcie_api 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_pcie_api");
    super.new(name);
  endfunction

  // 功能：在 rdma_pcie_api 中，cfg_read32 把 cfg_read32 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：target（输入）、offset（输入）、data（输出）、status（输出）；cfg_read32 驱动下游事务，并写入 data、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：cfg_read32 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  pure virtual task cfg_read32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    output bit [31:0] data,
    output rdma_status status
  );

  // 功能：在 rdma_pcie_api 中，cfg_write32 把 cfg_write32 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：target（输入）、offset（输入）、data（输入）、byte_enable（输入）、status（输出）；cfg_write32 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。

  // 失败/边界：cfg_write32 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  pure virtual task cfg_write32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    bit [31:0] data,
    bit [3:0] byte_enable,
    output rdma_status status
  );

  // 功能：在 rdma_pcie_api 中，mmio_write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：function_h（输入）、address（输入）、data（输入）、status（输出）；mmio_write 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：mmio_write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  pure virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );

  // 功能：在 rdma_pcie_api 中，dma_visibility_barrier 在截止时间内执行 DMA 可见性或 MMIO 顺序屏障，确保 doorbell 之前的数据写入已按序可见。
  // 输入/输出及副作用：function_h（输入）、status（输出）；dma_visibility_barrier 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：dma_visibility_barrier 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
  pure virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );

  // 功能：在 rdma_pcie_api 中，mmio_ordering_barrier 在截止时间内执行 DMA 可见性或 MMIO 顺序屏障，确保 doorbell 之前的数据写入已按序可见。
  // 输入/输出及副作用：function_h（输入）、status（输出）；mmio_ordering_barrier 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：mmio_ordering_barrier 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
  pure virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );

  // 功能：在 rdma_pcie_api 中，get_function_info 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：bdf（输入）、info（输出）；get_function_info 以 bdf.segment、bdf.bus、bdf.device、bdf.function 查询冻结 PCIe Function 信息，并写入 info；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：get_function_info 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  pure virtual function rdma_status get_function_info(
    rdma_bdf_t bdf,
    output rdma_pcie_function_info info
  );

  // 功能：在 rdma_pcie_api 中，decode_bar 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：address（输入）、result（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_bar 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  pure virtual function rdma_status decode_bar(
    rdma_bar_addr_t address,
    output rdma_bar_decode result
  );
endclass
