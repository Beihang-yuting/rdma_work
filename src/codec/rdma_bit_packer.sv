// 目录：硬件编解码层 codec/rdma_bit_packer.sv。
// 职责：按 bit 偏移向硬件 image 写入/读取字段，并用 occupancy 检测字段重叠。
// 依赖：依赖本层 types/model 契约（rdma_status 等）。
// 所有权与生命周期：仅拥有 occupancy 位图；调用方 image 由外部持有，packer 不保存其引用。

class rdma_bit_packer extends uvm_object;
  `rdma_object_utils(rdma_bit_packer)

  protected bit occupancy[];
  protected int unsigned expected_byte_count;
  protected bit initialized;

  // 功能：构造未初始化的 packer。
  // 输入/输出及副作用：name 为 UVM 对象名；occupancy 清空。
  // 失败/边界：未 initialize 前 validate_access 返回 INVALID_STATE。
  function new(string name = "rdma_bit_packer");
    super.new(name);
    occupancy = new[0];
    expected_byte_count = 0;
    initialized = 1'b0;
  endfunction

  // 功能：按 image 字节数分配并清零 occupancy 位图，标记 packer 已初始化。
  // 输入/输出及副作用：image_byte_count 为 image 字节数；成功时覆盖 occupancy/expected_byte_count。
  // 失败/边界：字节数 * 8 超出 int 范围时返回 INVALID_ARGUMENT，且不改变旧状态。
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

  // 功能：以新的 image 大小重新初始化，清除已占用位。
  // 输入/输出及副作用：同 initialize。
  // 失败/边界：同 initialize。
  function rdma_status reset(int unsigned image_byte_count);
    return initialize(image_byte_count);
  endfunction

  // 功能：校验 image 长度与字段位区间，输出区间结束位置（不含）。
  // 输入/输出及副作用：end_exclusive 先清零；只读状态，不修改 bytes/occupancy。
  // 失败/边界：未初始化返回 INVALID_STATE；长度不符、width 非 1..64、64-bit 溢出或越界返回 CODEC_ERROR。
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

  // 功能：把 value 低 width 位写入 bytes 的 bit_offset 处，并标记 occupancy。
  // 输入/输出及副作用：bytes 为 ref；成功时修改 bytes 与 occupancy。
  // 失败/边界：几何非法、value 超出 width 或与已写字段重叠时返回 CODEC_ERROR；全部检查先于写入。
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

  // 功能：从 bytes 的 bit_offset 处读取 width 位。
  // 输入/输出及副作用：value 先清零，成功时写入读取值；不修改 bytes/occupancy。
  // 失败/边界：几何校验失败时返回其错误，value 保持 0。
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
