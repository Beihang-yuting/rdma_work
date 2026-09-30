// 目录：协议值模型层 model/rdma_hw_image.sv。
// 职责：保存硬件序列化字节、格式/代际/写入目标元数据与字段摘要，集中元数据值复制。
// 依赖：UVM object、rdma_types_pkg 的 endian/image kind 与三个 packed 地址值类型。
// 所有权与生命周期：对象拥有 bytes/field_summary 队列；target 是地址值，不是外部
//   backing/BAR capability，不授予写权限。调用方负责对象寿命、分配及业务 shape 校验。

typedef enum bit [1:0] {
  RDMA_HW_TARGET_NONE    = 2'd0,
  RDMA_HW_TARGET_BACKING = 2'd1,
  RDMA_HW_TARGET_HMC_FVM = 2'd2,
  RDMA_HW_TARGET_BAR     = 2'd3
} rdma_hw_target_kind_e;

// 设计说明：模型只维护数据布局，不接管业务快照策略。元数据复制不分配或调用虚方法；
//   bytes/summary 的替换、追加和 clone 后恢复仍由入口选择，避免改变原回调窗口。
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

  // 功能：构造空硬件镜像，默认 little endian、NONE image/target，长度/对齐/版本/代际为零。
  // 输入/输出及副作用：name 设置 UVM 名称；清空自有 bytes/summary，三个 target 地址置零。
  // 失败/边界：默认对象不是可提交镜像；构造不申请 backing，也不执行业务 shape 校验。
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

  // 功能：把 source 的十项格式、代际与目标地址值按固定顺序写入 destination。
  // 输入/输出及副作用：source/destination 为已存在的非空句柄；只修改 destination 元数据，
  //   不触碰 bytes/field_summary、UVM 名称或 subtype 扩展字段，不分配对象或调用回调。
  // 失败/边界：调用方必须保证两端非空；本 void 原语不做 shape/null 校验、不返回 status，
  //   允许同一对象自复制，不把地址值复制视为 authority 验证或资源所有权转移。
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

  // 功能：在 UVM 基类复制后，将 rhs 的 bytes、公共元数据和 summary 替换到当前镜像。
  // 输入/输出及副作用：rhs 输入；按 bytes→metadata→summary 顺序复制队列值，不调用 clone；
  //   非自别名时源值不变，两个对象的队列可独立修改。
  // 失败/边界：类型不兼容报 RDMA_COPY_TYPE fatal；要求 rhs 非空，不新增 null 降级，
  //   不保证 fatal 被外部抑制后可继续；自复制保值，不校验长度、target 或 subtype 扩展字段。
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
