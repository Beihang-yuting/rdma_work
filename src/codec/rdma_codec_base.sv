// 目录：硬件编解码层 codec/rdma_codec_base.sv。
// 职责：实现 rdma_codec_base 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_codec_base.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_codec_base extends uvm_object;

  // 功能：构造 rdma_codec_base，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_codec_base 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_codec_base");
    super.new(name);
  endfunction

  // 功能：在 rdma_codec_base 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  pure virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );

  // 功能：在 rdma_codec_base 中，decode 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：image（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  pure virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理函数体中的显式空值、类型、代际或范围检查等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 equal、mismatch；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  pure virtual function rdma_status validate_model(rdma_hw_model model);

  // 功能：validate_image 校验 image 与当前对象状态的一致性，并显式处理函数体中的显式空值、类型、代际或范围检查等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image（输入）；validate_image 读取 image 并使用字段 equal、mismatch；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  pure virtual function rdma_status validate_image(rdma_hw_image image);

  // 功能：在 rdma_codec_base 中由 serialized_equal 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）、equal（输出）、mismatch（输出）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：serialized_equal 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function rdma_status serialized_equal(
    rdma_hw_model lhs,
    rdma_hw_model rhs,
    output bit equal,
    output string mismatch
  );
    equal = 1'b0;
    mismatch = "serialized equality is not implemented by this codec";
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, mismatch);
  endfunction

  // Endian is a codec/hardware-profile property.  The generic bit packer
  // deliberately performs no byte swapping.
  // 功能：hardware_endian 使用 当前对象字段 计算并返回 rdma_byte_endian_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；hardware_endian 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_byte_endian_e，不取得调用方资源所有权。
  // 失败/边界：hardware_endian 是只读访问器，按对象字段返回固定值；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  pure virtual function rdma_byte_endian_e hardware_endian();

  // 功能：describe_fields 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；describe_fields 读取 codec 的 profile_name、image_kind 和 image_bytes 描述字段，返回稳定诊断文本；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  pure virtual function string describe_fields();
endclass
