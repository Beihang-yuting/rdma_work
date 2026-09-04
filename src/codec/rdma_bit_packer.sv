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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_bit_packer");
    super.new(name);
    occupancy = new[0];
    expected_byte_count = 0;
    initialized = 1'b0;
  endfunction

  // 功能：写入并校验运行所需的配置、身份或资源参数，建立后续操作的边界（接口 initialize）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：推进对象的运行/复位/恢复状态机，并清晰隔离旧 incarnation 的操作（接口 reset）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_status reset(int unsigned image_byte_count);
    return initialize(image_byte_count);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_access）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：执行接口 put_u64 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 put_u64）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 get_u64）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
