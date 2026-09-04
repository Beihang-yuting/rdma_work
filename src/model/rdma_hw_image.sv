// 目录：协议与资源模型层 model/rdma_hw_image.sv。
// 职责：实现 rdma_hw_image 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_hw_image.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [1:0] {
  RDMA_HW_TARGET_NONE    = 2'd0,
  RDMA_HW_TARGET_BACKING = 2'd1,
  RDMA_HW_TARGET_HMC_FVM = 2'd2,
  RDMA_HW_TARGET_BAR     = 2'd3
} rdma_hw_target_kind_e;

class rdma_hw_image extends uvm_object;
  `uvm_object_utils(rdma_hw_image)

  byte unsigned bytes[$];
  longint unsigned length;
  int unsigned alignment;
  rdma_byte_endian_e endian;
  rdma_image_kind_e image_kind;
  int unsigned hardware_version;
  int unsigned function_generation;
  rdma_hw_target_kind_e write_target_kind;
  rdma_backing_addr_t backing_target;
  rdma_hmc_fvm_addr_t hmc_target;
  rdma_bar_addr_t bar_target;
  string field_summary[$];

  // 功能：构造 rdma_hw_image，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：length='0；alignment='0；endian=RDMA_ENDIAN_LITTLE；image_kind=RDMA_IMAGE_NONE；hardware_version='0；function_generation='0；write_target_kind=RDMA_HW_TARGET_NONE；backing_target='0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_image 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_image");
    super.new(name);
    bytes.delete();
    length = '0;
    alignment = '0;
    endian = RDMA_ENDIAN_LITTLE;
    image_kind = RDMA_IMAGE_NONE;
    hardware_version = '0;
    function_generation = '0;
    write_target_kind = RDMA_HW_TARGET_NONE;
    backing_target = '0;
    hmc_target = '0;
    bar_target = '0;
    field_summary.delete();
  endfunction

  // 功能：将 rhs 中 rdma_hw_image 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（rdma_hw_image copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_image rhs_image;

    super.do_copy(rhs);
    if (!$cast(rhs_image, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_hw_image copy type mismatch")
    bytes = rhs_image.bytes;
    length = rhs_image.length;
    alignment = rhs_image.alignment;
    endian = rhs_image.endian;
    image_kind = rhs_image.image_kind;
    hardware_version = rhs_image.hardware_version;
    function_generation = rhs_image.function_generation;
    write_target_kind = rhs_image.write_target_kind;
    backing_target = rhs_image.backing_target;
    hmc_target = rhs_image.hmc_target;
    bar_target = rhs_image.bar_target;
    field_summary = rhs_image.field_summary;
  endfunction
endclass
