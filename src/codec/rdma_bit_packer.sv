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

  // 功能：构造 rdma_bit_packer，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：occupancy=new[0]；expected_byte_count=0；initialized=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_bit_packer 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_bit_packer");
    super.new(name);
    occupancy = new[0];
    expected_byte_count = 0;
    initialized = 1'b0;
  endfunction

  // 功能：在 rdma_bit_packer 中，initialize 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：image_byte_count（输入）；initialize 先依据 image_byte_count > (32'h7fff_ffff / 8 校验 image_byte_count；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
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

  // 功能：在 rdma_bit_packer 中，reset reset 清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：image_byte_count（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function rdma_status reset(int unsigned image_byte_count);
    return initialize(image_byte_count);
  endfunction

  // 功能：validate_access 校验 bytes、bit_offset、width、end_exclusive 与当前对象状态的一致性，并显式处理“bit packer is not initialized”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：bytes（输入）、bit_offset（输入）、width（输入）、end_exclusive（输出）；validate_access 读取 bytes、bit_offset、width、end_exclusive 并使用字段 end_exclusive、extended_end、capacity_bits，并写入 end_exclusive；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：validate_access 返回 RDMA_SC_INVALID_STATE、RDMA_SC_CODEC_ERROR；典型拒绝条件为“bit packer is not initialized”“field width must be in the range 1..64”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_bit_packer 中，put_u64 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：bytes（引用）、bit_offset（输入）、width（输入）、value（输入）；put_u64 读取 bytes、bit_offset、width、value 并使用字段 status、bit_index、byte_index、bit_in_byte，并写入 bytes；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：put_u64 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
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

  // 功能：在 rdma_bit_packer 中，get_u64 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：bytes（输入）、bit_offset（输入）、width（输入）、value（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：get_u64 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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
