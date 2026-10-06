// 目录：协议值模型层 model/rdma_hw_image.sv。
// 职责：保存硬件序列化字节、格式/代际/写入目标元数据与字段摘要，集中元数据值复制。
// 依赖：UVM object、rdma_types_pkg 的 endian/image kind 与 packed 地址类型。
// 所有权与生命周期：对象拥有 bytes/field_summary；target 仅为地址值，不授予写权限。

typedef enum bit [1:0] {
  RDMA_HW_TARGET_NONE    = 2'd0,
  RDMA_HW_TARGET_BACKING = 2'd1,
  RDMA_HW_TARGET_HMC_FVM = 2'd2,
  RDMA_HW_TARGET_BAR     = 2'd3
} rdma_hw_target_kind_e;

// 设计说明：模型只维护数据布局；元数据复制不分配、不调用虚方法，bytes/summary 由入口自行处理。
class rdma_hw_image extends uvm_object;
  `rdma_object_utils(rdma_hw_image)

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

  // 功能：构造空镜像（little endian、NONE kind/target，其余为零）。
  // 输入/输出及副作用：name 为 UVM 名；清空 bytes/summary，地址置零。
  // 失败/边界：默认对象不是可提交镜像。
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

  // 功能：把 source 的十项元数据按序复制到 destination。
  // 输入/输出及副作用：只改 destination 元数据，不动 bytes/field_summary，不分配对象。
  // 失败/边界：不检查空句柄，无 status；允许自复制。
  static function automatic void copy_metadata_noalloc(
    rdma_hw_image source, rdma_hw_image destination
  );
    destination.length = source.length;
    destination.alignment = source.alignment;
    destination.endian = source.endian;
    destination.image_kind = source.image_kind;
    destination.hardware_version = source.hardware_version;
    destination.function_generation = source.function_generation;
    destination.write_target_kind = source.write_target_kind;
    destination.backing_target = source.backing_target;
    destination.hmc_target = source.hmc_target;
    destination.bar_target = source.bar_target;
  endfunction

  // 功能：UVM copy 后复制 rhs 的 bytes、元数据与 summary。
  // 输入/输出及副作用：按 bytes、metadata、summary 顺序复制值；队列相互独立。
  // 失败/边界：类型不匹配触发 RDMA_COPY_TYPE fatal；rhs 须非空，不校验长度或 target。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_image rhs_image;

    super.do_copy(rhs);
    if (!$cast(rhs_image, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_hw_image copy type mismatch")
    bytes = rhs_image.bytes;
    copy_metadata_noalloc(rhs_image, this);
    field_summary = rhs_image.field_summary;
  endfunction
endclass

// 硬件格式模型基类（CMQ 字段 body 等派生）。
virtual class rdma_hw_model extends uvm_object;

  // 功能：构造 hw model 基类对象。
  // 输入/输出及副作用：name 为对象名。
  // 失败/边界：无。
  function new(string name = "rdma_hw_model");
    super.new(name);
  endfunction

  // 功能：校验 context 模型字段与状态一致性（由各派生类实现）。
  // 输入/输出及副作用：只读；返回 rdma_status。
  // 失败/边界：不一致时返回 INVALID_ARGUMENT/INVALID_STATE，不修改模型。
  pure virtual function rdma_status validate();

  // 功能：返回 context 模型的稳定文本描述（由各派生类实现）。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  pure virtual function string describe();
endclass
