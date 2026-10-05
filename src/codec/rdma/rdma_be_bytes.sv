// 目录：编解码层 src/codec/rdma/rdma_be_bytes.sv。
// 职责：驱动与设备两侧共用的大端字节工具：按 rdma_defs.svh 的 (WORD_BYTE_OFFSET, LSB, WIDTH)
//   三元组读写字段，对应驱动 get_64bit_val/set_64bit_val + FIELD_GET/FIELD_PREP。
// 依赖：无（纯函数）。
// 所有权与生命周期：只有静态函数，不持有状态。

typedef byte unsigned rdma_bytes_t[];

// 按 rdma_defs.svh 字段三元组读写（驱动 FIELD_GET/FIELD_PREP + get/set_64bit_val）。
// _AT 用于只保存了 context 区的字节数组：BASE 为该区在 SQE 中的起始字节。
`define RDMA_BE_GET(BYTES, STEM) \
  rdma_be::field(BYTES, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH)
`define RDMA_BE_GET_AT(BYTES, STEM, BASE) \
  rdma_be::field(BYTES, STEM``_WORD_BYTE_OFFSET - (BASE), STEM``_LSB, STEM``_WIDTH)
`define RDMA_BE_SET(BYTES, STEM, VALUE) \
  rdma_be::set_field(BYTES, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH, VALUE);

virtual class rdma_be;
  // 功能：读取 offset 处的大端 qword。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：越界字节按 0。
  static function bit [63:0] qword(byte unsigned b[], int unsigned offset);
    bit [63:0] value;

    value = '0;
    for (int unsigned i = 0; i < 8; i++) begin
      value = value << 8;
      if (offset + i < b.size())
        value[7:0] = b[offset + i];
    end
    return value;
  endfunction

  // 功能：在 offset 处写入大端 qword。
  // 输入/输出及副作用：修改 b。
  // 失败/边界：越界字节被忽略。
  static function void put_qword(inout byte unsigned b[], input int unsigned offset,
                                 input bit [63:0] value);
    for (int unsigned i = 0; i < 8; i++)
      if (offset + i < b.size())
        b[offset + i] = value[63 - 8 * i -: 8];
  endfunction

  // 功能：取字段。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：width>=64 取整个 qword。
  static function bit [63:0] field(byte unsigned b[], int unsigned word_byte, int unsigned lsb,
                                   int unsigned width);
    bit [63:0] mask;

    mask = '1;
    if (width < 64)
      mask = (64'd1 << width) - 1;
    return (qword(b, word_byte) >> lsb) & mask;
  endfunction

  // 功能：写字段（读改写所在 qword）。
  // 输入/输出及副作用：修改 b。
  // 失败/边界：value 超宽部分被截断。
  static function void set_field(inout byte unsigned b[], input int unsigned word_byte,
                                 input int unsigned lsb, input int unsigned width,
                                 input bit [63:0] value);
    bit [63:0] mask;
    bit [63:0] word;

    mask = '1;
    if (width < 64)
      mask = (64'd1 << width) - 1;
    mask = mask << lsb;
    word = (qword(b, word_byte) & ~mask) | ((value << lsb) & mask);
    put_qword(b, word_byte, word);
  endfunction

  // 功能：全部字节异或（驱动 xtrdma_bytes_xor）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：空数组返回 0。
  static function bit [7:0] xor_bytes(byte unsigned b[]);
    bit [7:0] value;

    value = '0;
    foreach (b[i])
      value ^= b[i];
    return value;
  endfunction

  // 功能：截取 [offset, offset+size) 字节。
  // 输入/输出及副作用：返回新数组。
  // 失败/边界：越界部分按 0。
  static function rdma_bytes_t slice(byte unsigned b[], int unsigned offset, int unsigned size);
    rdma_bytes_t out;

    out = new[size];
    foreach (out[i]) begin
      out[i] = 8'h00;
      if (offset + i < b.size())
        out[i] = b[offset + i];
    end
    return out;
  endfunction

  // 功能：新建 size 字节的全零数组。
  // 输入/输出及副作用：返回新数组。
  // 失败/边界：无。
  static function rdma_bytes_t zeros(int unsigned size);
    rdma_bytes_t out;

    out = new[size];
    foreach (out[i])
      out[i] = 8'h00;
    return out;
  endfunction
endclass
