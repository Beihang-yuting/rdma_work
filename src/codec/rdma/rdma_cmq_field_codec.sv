// 目录：硬件编解码层 codec/rdma/rdma_cmq_field_codec.sv。
// 职责：为没有专用 body 编码器的 CMQ opcode 提供表驱动编码：字段表由 tools/gen_cmq_request_fields.py
//   从驱动 cmq.c 填充函数生成（rdma_cmq_request_fields.svh），body 以驱动 info 结构体成员名携带取值。
// 依赖：rdma_cmq_codec_registry::request_mask（qword 所有权）、RDMA_CMQ_SIGNATURE/SIGN_EN 字段定义。
// 所有权与生命周期：codec 无状态；body 拥有自身取值副本；编码输出 image 由调用方拥有。

// 设计说明：一个 body 承载一个驱动 info 结构体：标量成员放 values，数组成员（MAC、IPv6、SD 数据）放
//   blobs；是否合法由编码时按 opcode 字段表检查。
class rdma_hw_cmq_field_body extends rdma_hw_model;
  `rdma_object_utils(rdma_hw_cmq_field_body)

  longint unsigned values[string];
  byte unsigned blobs[string][];

  // 功能：构造空 body。
  // 输入/输出及副作用：name 为 UVM 实例名。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_field_body");
    super.new(name);
  endfunction

  // 功能：复制全部标量与数组成员。
  // 输入/输出及副作用：覆盖当前取值。
  // 失败/边界：类型不符时 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cmq_field_body source;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ field body copy type mismatch")
    values = source.values;
    blobs.delete();
    foreach (source.blobs[name])
      blobs[name] = source.blobs[name];
  endfunction

  // 功能：body 本身无 opcode 无关约束；字段名、宽度与长度在编码时按 opcode 检查。
  // 输入/输出及副作用：无。
  // 失败/边界：恒成功。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：返回取值摘要。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("CMQ field body(%0d values, %0d blobs)", values.num(), blobs.num());
  endfunction
endclass

// 设计说明：按驱动填充函数逐字段写入 qword；变换与驱动一致（minus_one = num - 1，mac48 =
//   ether_addr_to_u64，const 为驱动写死的常量）。SD_UPDATE 在 sd_num 超过 2 时写 sd_buf_addr 并给出
//   不含信封字节的部分签名，信封字节由 request composer 合并后补入。
class rdma_hw_cmq_field_codec extends uvm_object;
  `rdma_object_utils(rdma_hw_cmq_field_codec)

  localparam int unsigned BODY_BYTES = 64;
  localparam int unsigned SD_CARRIED = 2;
  localparam int unsigned SD_CHUNK_BYTES = 16;

  // 功能：构造无状态 codec。
  // 输入/输出及副作用：name 为 UVM 实例名。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_field_codec");
    super.new(name);
  endfunction

  // 功能：opcode 是否由字段表覆盖。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  static function bit supports(bit [7:0] opcode);
    rdma_cmq_field_spec_t specs[$];

    return rdma_cmq_request_field_specs(opcode, specs);
  endfunction

  // 功能：按字段表把 body 编码为 64B body image（信封位为 0）。
  // 输入/输出及副作用：image 输出新对象。
  // 失败/边界：opcode 不在表内、body 类型不符、出现表外成员、取值越宽、数组长度不符或写出 qword
  //   所有权之外的位时返回错误且 image=null。
  function rdma_status encode(bit [7:0] opcode, rdma_hw_model model,
                              output rdma_hw_image image);
    rdma_cmq_field_spec_t specs[$];
    rdma_hw_cmq_field_body body;
    bit [63:0] words[8];
    rdma_status status;

    image = null;
    if (!rdma_cmq_request_field_specs(opcode, specs))
      return unsupported(opcode);
    if (!$cast(body, model) || body == null)
      return invalid_argument("CMQ field codec requires rdma_hw_cmq_field_body");
    status = check_members(body, specs);
    if (!status.ok())
      return status;
    foreach (words[q])
      words[q] = '0;
    foreach (specs[i]) begin
      status = place(body, specs[i], words);
      if (!status.ok())
        return status;
    end
    if (opcode == RDMA_OP_SD_UPDATE) begin
      status = sign_sd_update(body, words);
      if (!status.ok())
        return status;
    end
    foreach (words[q])
      if ((words[q] & ~rdma_cmq_codec_registry::request_mask(opcode, q)) != 0)
        return codec_error($sformatf(
          "CMQ field body qword %0d writes outside opcode 0x%02x ownership", q, opcode));
    image = make_image(words);
    return rdma_status::success();
  endfunction

  // 功能：body 只能出现表内成员（常量与计算字段不接受输入）。
  // 输入/输出及副作用：纯检查。
  // 失败/边界：未知成员或标量/数组放错位置时返回 INVALID_ARGUMENT。
  protected function rdma_status check_members(rdma_hw_cmq_field_body body,
                                               rdma_cmq_field_spec_t specs[$]);
    bit scalar[string];
    bit blob[string];

    foreach (specs[i]) begin
      if (specs[i].param == "")
        continue;
      if (is_blob(specs[i]))
        blob[specs[i].param] = 1'b1;
      else
        scalar[specs[i].param] = 1'b1;
    end
    foreach (body.values[name])
      if (!scalar.exists(name))
        return invalid_argument({"CMQ field body has unknown scalar member ", name});
    foreach (body.blobs[name])
      if (!blob.exists(name) && name != "sd_extra_data")
        return invalid_argument({"CMQ field body has unknown array member ", name});
    return rdma_status::success();
  endfunction

  // 功能：把一个字段按驱动变换写入 words。
  // 输入/输出及副作用：修改 words。
  // 失败/边界：取值越宽、minus_one 取值为 0、数组长度不符时返回错误。
  protected function rdma_status place(rdma_hw_cmq_field_body body, rdma_cmq_field_spec_t spec,
                                       ref bit [63:0] words[8]);
    longint unsigned value;
    byte unsigned data[];

    if (is_blob(spec)) begin
      data = new[0];
      if (body.blobs.exists(spec.param))
        data = body.blobs[spec.param];
      if (spec.transform == "mac48")
        return put(words, spec, mac_to_u64(data));
      if (data.size() != spec.width / 8)
        return invalid_argument($sformatf("CMQ field %s must carry %0d bytes", spec.param,
                                          spec.width / 8));
      foreach (data[i])
        words[(spec.qword_byte + i) / 8][63 - ((spec.qword_byte + i) % 8) * 8 -: 8] = data[i];
      return rdma_status::success();
    end
    if (spec.transform.substr(0, 5) == "const:")
      return put(words, spec, spec.transform.substr(6, spec.transform.len() - 1).atoi());
    if (spec.transform inside {"sd_signature", "sd_sign_en"})
      return rdma_status::success();
    value = body.values.exists(spec.param) ? body.values[spec.param] : 0;
    if (spec.transform == "sd_extended") begin
      if (sd_num(body) <= SD_CARRIED) begin
        if (value != 0)
          return invalid_argument("SD_UPDATE sd_buf_addr is only used when sd_num exceeds 2");
        return rdma_status::success();
      end
      return put(words, spec, value);
    end
    if (spec.transform == "minus_one") begin
      if (value == 0)
        return invalid_argument({"CMQ field ", spec.param, " must be at least 1"});
      value--;
    end
    return put(words, spec, value);
  endfunction

  // 功能：驱动 update_sd 的签名：sd_num 超过 2 时置 sign_en，签名为 ~(body 字节异或 ^ 额外 SD 数据
  //   字节异或)；信封字节异或由 composer 合并后补入。
  // 输入/输出及副作用：修改 words[1]。
  // 失败/边界：额外 SD 数据长度与 sd_num 不符时返回 INVALID_ARGUMENT。
  protected function rdma_status sign_sd_update(rdma_hw_cmq_field_body body,
                                                ref bit [63:0] words[8]);
    byte unsigned extra[];
    byte unsigned signature;
    int unsigned expected;

    extra = new[0];
    if (body.blobs.exists("sd_extra_data"))
      extra = body.blobs["sd_extra_data"];
    expected = sd_num(body) > SD_CARRIED ? (sd_num(body) - SD_CARRIED) * SD_CHUNK_BYTES : 0;
    if (extra.size() != expected)
      return invalid_argument($sformatf("SD_UPDATE sd_extra_data must carry %0d bytes", expected));
    if (sd_num(body) <= SD_CARRIED)
      return rdma_status::success();
    words[1][RDMA_CMQ_SIGN_EN_LSB] = 1'b1;
    signature = '0;
    foreach (words[q])
      for (int unsigned b = 0; b < 8; b++)
        signature ^= words[q][b * 8 +: 8];
    foreach (extra[i])
      signature ^= extra[i];
    words[1][RDMA_CMQ_SIGNATURE_LSB +: 8] = ~signature;
    return rdma_status::success();
  endfunction

  // 功能：SD_UPDATE body 的 sd_num。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：缺省为 0。
  protected function longint unsigned sd_num(rdma_hw_cmq_field_body body);
    return body.values.exists("sd_num") ? body.values["sd_num"] : 0;
  endfunction

  // 功能：字段是否以字节数组承载（memcpy 字段与 MAC）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function bit is_blob(rdma_cmq_field_spec_t spec);
    return spec.transform == "mac48" || spec.transform.substr(0, 5) == "bytes:";
  endfunction

  // 功能：驱动 ether_addr_to_u64：6 字节 MAC，首字节为最高位。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：长度不为 6 时返回全 1（随后的宽度检查会拒绝）。
  protected function longint unsigned mac_to_u64(byte unsigned data[]);
    longint unsigned value;

    if (data.size() != 6)
      return '1;
    value = 0;
    foreach (data[i])
      value = (value << 8) | data[i];
    return value;
  endfunction

  // 功能：把 value 写入字段位置（宽度不足时拒绝，与 FIELD_PREP 的编译期检查等价）。
  // 输入/输出及副作用：修改 words。
  // 失败/边界：value 超出字段宽度返回 INVALID_ARGUMENT。
  protected function rdma_status put(ref bit [63:0] words[8], input rdma_cmq_field_spec_t spec,
                                     input longint unsigned value);
    bit [63:0] field_mask;

    field_mask = spec.width >= 64 ? '1 : ((64'd1 << spec.width) - 1);
    if ((value & ~field_mask) != 0)
      return invalid_argument($sformatf("CMQ field %s value 0x%0h exceeds %0d bits",
                                        spec.param, value, spec.width));
    words[spec.qword_byte / 8] |= (value & field_mask) << spec.lsb;
    return rdma_status::success();
  endfunction

  // 功能：按大端 qword 序列化为 CMQ SQE body image。
  // 输入/输出及副作用：返回新 image。
  // 失败/边界：无。
  protected function rdma_hw_image make_image(bit [63:0] words[8]);
    rdma_hw_image image;

    image = rdma_hw_image::type_id::create("rdma_cmq_field_body");
    foreach (words[q])
      for (int unsigned i = 0; i < 8; i++)
        image.bytes.push_back(words[q][63 - i * 8 -: 8]);
    image.length = BODY_BYTES;
    image.alignment = BODY_BYTES;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_SQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 0;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return image;
  endfunction

  // 功能：构造错误 status。
  // 输入/输出及副作用：纯构造。
  // 失败/边界：无。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 codec 错误 status。
  // 输入/输出及副作用：纯构造。
  // 失败/边界：无。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：构造不支持 opcode 的 status。
  // 输入/输出及副作用：纯构造。
  // 失败/边界：无。
  protected function rdma_status unsupported(bit [7:0] opcode);
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                             $sformatf("CMQ opcode 0x%02x has no field layout", opcode));
  endfunction
endclass
