// 目录：硬件编解码层 codec/rdma_codec_base.sv。
// 职责：实现 rdma_codec_base 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_codec_base.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_codec_base extends uvm_object;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_codec_base");
    super.new(name);
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 model, image 用于执行 encode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  pure virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );

  // 功能：从硬件 image/缓冲区解码请求字段，验证布局和完整性后向调用方返回值或状态。
  // 输入/输出及副作用：参数 image, model 用于执行 decode；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像为空、长度不足或校验失败时不发布部分模型字段。
  pure virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  pure virtual function rdma_status validate_model(rdma_hw_model model);

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  pure virtual function rdma_status validate_image(rdma_hw_image image);

  // 功能：比较两个输入对象的协议字段或身份快照并返回确定的相等性结果，不修改任一输入。
  // 输入/输出及副作用：输入为待比较的两个值对象；返回 bit/状态结果，不修改任一输入或外部账本。
  //   任一对象为空、类型不符或字段未初始化时按接口约定返回不相等或错误。
  // 失败/边界：比较输入为空或类型不符时不得抛出未处理异常；结果必须保持确定且无副作用。
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
  // 功能：处理 hardware_endian：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 无显式输入参数 用于执行 hardware_endian；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：hardware_endian 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  pure virtual function rdma_byte_endian_e hardware_endian();

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  pure virtual function string describe_fields();
endclass
