// 目录：硬件编解码层 codec/rdma_bit_packer.sv。
// 职责：实现 rdma_bit_packer 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_bit_packer.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_bit_packer extends uvm_object;
  `uvm_object_utils(rdma_bit_packer)

  protected bit occupancy[];
  protected int unsigned expected_byte_count;
  protected bit initialized;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_bit_packer");
    super.new(name);
    occupancy = new[0];
    expected_byte_count = 0;
    initialized = 1'b0;
  endfunction

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
  function rdma_status initialize(int unsigned image_byte_count);
    if (image_byte_count > (32'h7fff_ffff / 8))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "image is too large for packer occupancy");
    occupancy = new[image_byte_count * 8];
    foreach (occupancy[i])
      occupancy[i] = 1'b0;
    expected_byte_count = image_byte_count;
    initialized = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：参数 image_byte_count 用于执行 reset；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function rdma_status reset(int unsigned image_byte_count);
    return initialize(image_byte_count);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected function rdma_status validate_access(
    byte unsigned bytes[],
    longint unsigned bit_offset,
    int unsigned width,
    output longint unsigned end_exclusive
  );
    bit [64:0] extended_end;
    bit [64:0] capacity_bits;

    end_exclusive = 0;
    if (!initialized)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "bit packer is not initialized");
    if (bytes.size() != expected_byte_count)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        $sformatf("image length %0d does not match initialized length %0d",
                  bytes.size(), expected_byte_count)
      );
    if (width < 1 || width > 64)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "field width must be in the range 1..64");

    extended_end = {1'b0, bit_offset} + width;
    if (extended_end[64])
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "field bit range overflows 64-bit offset");
    capacity_bits = {1'b0, expected_byte_count} << 3;
    if (extended_end > capacity_bits)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "field extends beyond image length");

    end_exclusive = extended_end[63:0];
    return rdma_status::success();
  endfunction

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 bytes, bit_offset, width, value 用于执行 put_u64；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
  function rdma_status put_u64(
    ref byte unsigned bytes[],
    input longint unsigned bit_offset,
    input int unsigned width,
    input bit [63:0] value
  );
    rdma_status status;
    longint unsigned end_exclusive;
    longint unsigned bit_index;
    longint unsigned byte_index;
    int unsigned bit_in_byte;

    status = validate_access(bytes, bit_offset, width, end_exclusive);
    if (!status.ok())
      return status;
    if (width < 64 && (value >> width) != 0)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "field value does not fit requested width");

    // Complete validation before mutating either image or occupancy.
    for (int unsigned i = 0; i < width; i++) begin
      bit_index = bit_offset + i;
      if (occupancy[bit_index])
        return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "field overlaps an earlier packed field");
    end

    for (int unsigned i = 0; i < width; i++) begin
      bit_index = bit_offset + i;
      byte_index = bit_index >> 3;
      bit_in_byte = bit_index[2:0];
      bytes[byte_index][bit_in_byte] = value[i];
      occupancy[bit_index] = 1'b1;
    end
    return rdma_status::success();
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function rdma_status get_u64(
    byte unsigned bytes[],
    longint unsigned bit_offset,
    int unsigned width,
    output bit [63:0] value
  );
    rdma_status status;
    longint unsigned end_exclusive;
    longint unsigned bit_index;
    longint unsigned byte_index;
    int unsigned bit_in_byte;
    bit [63:0] decoded;

    value = '0;
    status = validate_access(bytes, bit_offset, width, end_exclusive);
    if (!status.ok())
      return status;

    decoded = '0;
    for (int unsigned i = 0; i < width; i++) begin
      bit_index = bit_offset + i;
      byte_index = bit_index >> 3;
      bit_in_byte = bit_index[2:0];
      decoded[i] = bytes[byte_index][bit_in_byte];
    end
    value = decoded;
    return rdma_status::success();
  endfunction
endclass
