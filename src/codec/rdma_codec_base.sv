// 目录：硬件编解码层 codec/rdma_codec_base.sv。
// 职责：实现 rdma_codec_base 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

virtual class rdma_codec_base extends uvm_object;

  // 功能：构造 codec 基类对象。
  // 输入/输出及副作用：name 为 UVM 对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_codec_base");
    super.new(name);
  endfunction

  // 功能：按硬件布局把 model 编码为 image（子类实现）。
  // 输入/输出及副作用：model 只读；image 输出完整硬件图像。
  // 失败/边界：model/image 为空、长度/对齐/保留位非法或校验失败时不发布部分字段。
  pure virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );

  // 功能：把硬件 image 解码为 model（子类实现）。
  // 输入/输出及副作用：image 只读；model 输出 detached 解码快照。
  // 失败/边界：image/model 为空、长度/对齐/保留位非法或校验失败时不发布部分字段。
  pure virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );

  // 功能：校验 model 是否合法（子类实现）。
  // 输入/输出及副作用：model 只读；返回 rdma_status。
  // 失败/边界：对象为空或身份/范围/generation 检查失败时返回非成功状态。
  pure virtual function rdma_status validate_model(rdma_hw_model model);

  // 功能：校验 image 是否合法（子类实现）。
  // 输入/输出及副作用：image 只读；返回 rdma_status。
  // 失败/边界：对象为空或长度/布局检查失败时返回非成功状态。
  pure virtual function rdma_status validate_image(rdma_hw_image image);

  // 功能：比较两个 model 的序列化内容是否一致；基类默认不支持。
  // 输入/输出及副作用：lhs/rhs 只读；equal 恒为 0，mismatch 返回固定说明。
  // 失败/边界：基类总返回 UNSUPPORTED_OPCODE，具体 codec 需覆盖。
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
  // 功能：返回该 codec 的硬件字节序。
  // 输入/输出及副作用：无参数，只读（子类实现）。
  // 失败/边界：无。
  pure virtual function rdma_byte_endian_e hardware_endian();

  // 功能：返回 codec 的稳定描述文本，供日志使用（子类实现）。
  // 输入/输出及副作用：无参数；只读。
  // 失败/边界：未配置时由子类返回 UNCONFIGURED 等占位文本。
  pure virtual function string describe_fields();
endclass
