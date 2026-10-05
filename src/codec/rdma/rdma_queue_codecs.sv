// 目录：硬件编解码层 src/codec/rdma。
// 职责：定义 XTR v1 队列项硬件模型，并实现 SQE/RQE/CQE/CEQE/AEQE 的
//   固定布局编解码、reserved/signature 校验及 post-send facade。
// 依赖：消费 rdma_queue_models 的语义快照、rdma_defs.svh 的冻结字段坐标、
//   rdma_hw_qword_builder 的大端 qword 操作和公共 handle/status 类型。
// 所有权与生命周期：codec 只拥有本地 builder、候选模型和 image 值快照；QP、
//   AV、SGB/Host-memory 与外部 handle 均为非拥有输入，生命周期由上层环境管理。

// XTR v1 定长队列项 codec：字段按逻辑 qword 组织，由 rdma_hw_qword_builder 按大端序列化。

// 功能：为 raw queue-image decode 构造只含 kind/object_id/generation 的投影 handle。
// 输入/输出及副作用：返回新建 rdma_handle，function_uid 保持构造默认值。
// 失败/边界：不校验 kind/id，结果不是可路由句柄；id/generation 为 0 原样返回，由后续 gate 拒绝。
function automatic rdma_handle rdma_hw_queue_projected_handle(
    string name, rdma_resource_kind_e kind, int unsigned id,
    int unsigned generation = 1);
  rdma_handle h;
  h = rdma_handle::type_id::create(name);
  h.kind = kind; h.object_id = id; h.generation = generation;
  return h;
endfunction

typedef class rdma_hw_rqe_codec;

class rdma_queue_codec;
  // 功能：把语义发送请求编码为 64B SQE 镜像，并按 transport 选择 RC/UD/URC codec。
  // 输入/输出及副作用：request 只读，image 为输出镜像；不取得 QP/AV/DMA 所有权。
  // 失败/边界：请求为空/校验失败、transport 未知、authority 不完整或 codec 拒绝时返回错误，image 为空。
  extern static function rdma_status encode_sqe(input rdma_post_send_req request,
                                          output byte unsigned image[]);
  // 功能：按 CQE layout 编码公共字段，生成零填充的大端字节镜像。
  // 输入/输出及副作用：成功时 image 长度等于 layout.bytes。
  // 失败/边界：layout 为空或无效返回 CODEC_ERROR，image 为空。
  static function rdma_status encode_cqe(input rdma_cqe_fields fields,
                                          input rdma_cqe_layout layout,
                                          output byte unsigned image[]);
    image = new[0];
    if (layout == null || !layout.valid())
      return rdma_status::make(RDMA_SC_CODEC_ERROR, "CQE layout is invalid");
    image = new[layout.bytes];
    foreach (image[i]) image[i] = 8'h00;
    image[layout.header_offset+0] = fields.qpn[31:24];
    image[layout.header_offset+1] = fields.qpn[23:16];
    image[layout.header_offset+2] = fields.qpn[15:8];
    image[layout.header_offset+3] = fields.qpn[7:0];
    image[layout.header_offset+4] = fields.wr_id[63:56];
    image[layout.header_offset+5] = fields.wr_id[55:48];
    image[layout.header_offset+6] = fields.wr_id[47:40];
    image[layout.header_offset+7] = fields.wr_id[39:32];
    image[layout.header_offset+8] = fields.wr_id[31:24];
    image[layout.header_offset+9] = fields.wr_id[23:16];
    image[layout.header_offset+10] = fields.wr_id[15:8];
    image[layout.header_offset+11] = fields.wr_id[7:0];
    image[layout.header_offset+12] = {7'h0, fields.valid};
    return rdma_status::success();
  endfunction

  // 功能：从 CQE 大端字节镜像解码公共字段。
  // 输入/输出及副作用：image/layout 为输入，fields 为输出；不修改 image。
  // 失败/边界：layout 无效、长度不符、保留位/保留字节非零返回 CODEC_ERROR。
  static function rdma_status decode_cqe(input byte unsigned image[],
                                          input rdma_cqe_layout layout,
                                          output rdma_cqe_fields fields);
    fields = '{default:'0};
    if (layout == null || !layout.valid() || image.size() != layout.bytes)
      return rdma_status::make(RDMA_SC_CODEC_ERROR, "CQE image/layout mismatch");
    fields.qpn = {image[layout.header_offset], image[layout.header_offset+1],
                  image[layout.header_offset+2], image[layout.header_offset+3]};
    fields.wr_id = {image[layout.header_offset+4], image[layout.header_offset+5],
                    image[layout.header_offset+6], image[layout.header_offset+7],
                    image[layout.header_offset+8], image[layout.header_offset+9],
                    image[layout.header_offset+10], image[layout.header_offset+11]};
    fields.valid = image[layout.header_offset+12][0];
    if (image[layout.header_offset+12][7:1] != 0)
      return rdma_status::make(RDMA_SC_CODEC_ERROR, "CQE reserved bits are nonzero");
    foreach (image[i]) begin
      if (i < layout.header_offset || i > layout.header_offset + 12) begin
        if (image[i] != 0)
          return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                   "CQE reserved bytes are nonzero");
      end
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_sqe_model extends rdma_sqe_model;
  `rdma_object_utils(rdma_hw_sqe_model)
  bit [20:0] qpn;
  bit [2:0] icos;
  bit [7:0] qp_sn;
  bit [3:0] dst_port;
  bit [14:0] index;
  bit wrap;
  bit sign_en;
  bit se;
  bit [1:0] fence;
  bit [1:0] ce;
  bit valid;
  bit [7:0] signature;
  bit [7:0] sge_num;
  bit [3:0] hw_opcode;
  bit [31:0] rkey;
  rdma_iova_t remote_va;
  rdma_sq_payload_mode_e payload_mode;
  longint unsigned total_payload_len;
  byte unsigned inline_bytes[];
  rdma_iova_t sgb_iova;
  bit [31:0] invalidate_key;
  bit [23:0] destination_qpn;
  bit [31:0] qkey;
  bit [31:0] mr_handle_id;
  bit [31:0] mw_handle_id;
  // 由已认证 QPC 冻结得到，仅用于 URC external-SGB READ 的 packet-count 字段；
  // 0 表示未认证 QPC，而不是默认 MTU。
  int unsigned path_mtu_bytes;
  rdma_iova_t atomic_local_iova;
  bit [31:0] atomic_local_lkey;
  longint unsigned atomic_value;
  longint unsigned atomic_compare;

  // 功能：构造 SQE 模型，其余字段取默认值。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name="rdma_hw_sqe_model");
    super.new(name);
    remote_va = '0;
    sgb_iova = '0;
    atomic_local_iova = '0;

    payload_mode = RDMA_SQ_PAYLOAD_NONE;
    total_payload_len = 0;
    inline_bytes = new[0];

    invalidate_key = 0;
    atomic_local_lkey = 0;
    destination_qpn = 0;
    qkey = 0;
    mr_handle_id = 0;
    mw_handle_id = 0;
    path_mtu_bytes = 0;

    atomic_value = 0;
    atomic_compare = 0;
  endfunction

  // 功能：把 rhs 的 SQE wire 字段、payload 形状和 URC/QP 相关值复制为独立值快照。
  // 输入/输出及副作用：先 super.do_copy；动态 byte 数组逐元素复制，句柄字段仅复制引用。
  // 失败/边界：rhs 为空或类型不符触发 RDMA_COPY_TYPE fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_sqe_model x;

    super.do_copy(rhs);
    if (!$cast(x, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "xtr SQE copy mismatch")

    qpn = x.qpn;
    icos = x.icos;
    qp_sn = x.qp_sn;
    dst_port = x.dst_port;
    index = x.index;
    wrap = x.wrap;
    sign_en = x.sign_en;
    se = x.se;
    fence = x.fence;
    ce = x.ce;
    valid = x.valid;
    signature = x.signature;
    sge_num = x.sge_num;
    hw_opcode = x.hw_opcode;
    rkey = x.rkey;
    remote_va = x.remote_va;

    payload_mode = x.payload_mode;
    total_payload_len = x.total_payload_len;
    inline_bytes = x.inline_bytes;
    sgb_iova = x.sgb_iova;

    invalidate_key = x.invalidate_key;
    atomic_local_iova = x.atomic_local_iova;
    destination_qpn = x.destination_qpn;
    qkey = x.qkey;
    mr_handle_id = x.mr_handle_id;
    mw_handle_id = x.mw_handle_id;
    path_mtu_bytes = x.path_mtu_bytes;

    atomic_local_lkey = x.atomic_local_lkey;
    atomic_value = x.atomic_value;
    atomic_compare = x.atomic_compare;
  endfunction

  // 功能：确认 inline_bytes 与 payload 两个 inline 字节容器没有分叉。
  // 输入/输出及副作用：只读 inline_bytes/payload，不修改模型。
  // 失败/边界：任一为空视为无冲突；均非空且长度或内容（case-inequality）不同返回 INVALID_ARGUMENT，
  //   避免签名与实际 SGB backing 不一致。
  function rdma_status validate_inline_payload_authority();
    if (inline_bytes.size() == 0 || payload.size() == 0)
      return rdma_status::success();
    if (inline_bytes.size() != payload.size())
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "SQE inline payload sources have different lengths");
    foreach (inline_bytes[i]) begin
      if (inline_bytes[i] !== payload[i])
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "SQE inline payload sources disagree");
    end
    return rdma_status::success();
  endfunction

  // 功能：选出 inline WQE/SGB 要签名并写入的唯一字节快照，优先 inline_bytes，否则复制 payload。
  // 输入/输出及副作用：resolved_bytes 为输出；复制值，不转移数组引用。
  // 失败/边界：两个非空源冲突时返回 INVALID_ARGUMENT 且输出置空；均为空时返回零长度成功快照。
  function rdma_status resolve_inline_payload_authority(
      output byte unsigned resolved_bytes[]
  );
    rdma_status status;

    resolved_bytes = new[0];
    status = validate_inline_payload_authority();
    if (!status.ok())
      return status;

    if (inline_bytes.size() != 0) begin
      resolved_bytes = new[inline_bytes.size()];
      foreach (inline_bytes[i])
        resolved_bytes[i] = inline_bytes[i];
    end
    else begin
      resolved_bytes = new[payload.size()];
      foreach (payload[i])
        resolved_bytes[i] = payload[i];
    end
    return rdma_status::success();
  endfunction

  // 功能：一次归一 payload mode、有效 SGE 数、inline 字节源/长度和最终硬件 SGE_NUM，
  //   供 validate、codec 与 queue-data writer 共用。
  // 输入/输出及副作用：只读模型字段；五个 output 返回结果，不修改模型。
  // 失败/边界：null/零长 SGE 不计数（null 仍由 shape gate 拒绝）；显式 SGE mode 无有效项归一为 NONE，
  //   未知 mode 原样交 validate 拒绝；total_payload_len 不参与字节源选择；
  //   UD 仅非零 inline/descriptor 才强制外部 SGB，零字节 inline 仍为 INLINE_WQE。
  function automatic void derive_payload_authority(
      output rdma_sq_payload_mode_e mode,
      output int unsigned valid_sge_count,
      output int unsigned inline_payload_bytes,
      output bit inline_bytes_are_authority,
      output int unsigned canonical_sge_num);
    rdma_sge_authority::count_nonzero(sges, valid_sge_count);

    inline_bytes_are_authority = inline_bytes.size() != 0;
    inline_payload_bytes = inline_bytes_are_authority ?
                           inline_bytes.size() : payload.size();

    if (payload_mode != RDMA_SQ_PAYLOAD_NONE) begin
      if (payload_mode inside {RDMA_SQ_PAYLOAD_SGE_WQE,
                               RDMA_SQ_PAYLOAD_SGE_SGB} &&
          valid_sge_count == 0)
        mode = RDMA_SQ_PAYLOAD_NONE;
      else
        mode = payload_mode;
    end
    else if (inline_data || inline_payload_bytes != 0) begin
      mode = inline_payload_bytes > 32 ? RDMA_SQ_PAYLOAD_INLINE_SGB :
                                        RDMA_SQ_PAYLOAD_INLINE_WQE;
    end
    else if (opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                            RDMA_WR_ATOMIC_FETCH_ADD}) begin
      mode = RDMA_SQ_PAYLOAD_ATOMIC_FIXED;
    end
    else if (valid_sge_count > 2) begin
      mode = RDMA_SQ_PAYLOAD_SGE_SGB;
    end
    else if (valid_sge_count != 0) begin
      mode = RDMA_SQ_PAYLOAD_SGE_WQE;
    end
    else begin
      mode = RDMA_SQ_PAYLOAD_NONE;
    end

    // 设计：UD 的 wr.c 路径把非零 inline 与非零 SGE descriptor 都放入 SQ-SGB。
    // 这里统一发布 effective wire mode，使 make_sqe、UD codec 与 SGB writer 不会
    // 把同一请求解释成两种布局。
    if (transport == RDMA_TRANSPORT_UD) begin
      if (mode == RDMA_SQ_PAYLOAD_INLINE_SGB &&
          inline_payload_bytes == 0)
        mode = RDMA_SQ_PAYLOAD_INLINE_WQE;
      else if (mode == RDMA_SQ_PAYLOAD_INLINE_WQE &&
          inline_payload_bytes != 0)
        mode = RDMA_SQ_PAYLOAD_INLINE_SGB;
      else if (mode == RDMA_SQ_PAYLOAD_SGE_WQE &&
               valid_sge_count != 0)
        mode = RDMA_SQ_PAYLOAD_SGE_SGB;
    end

    case (mode)
      RDMA_SQ_PAYLOAD_INLINE_WQE,
      RDMA_SQ_PAYLOAD_INLINE_SGB:
        canonical_sge_num = (inline_payload_bytes + 15) / 16;
      RDMA_SQ_PAYLOAD_SGE_WQE,
      RDMA_SQ_PAYLOAD_SGE_SGB:
        canonical_sge_num = valid_sge_count;
      RDMA_SQ_PAYLOAD_ATOMIC_FIXED:
        canonical_sge_num = 1;
      default:
        canonical_sge_num = 0;
    endcase
  endfunction

  // 功能：返回共享 payload authority 的 canonical SGE_NUM：empty=0、inline=ceil(bytes/16)、
  //   SGE=有效项数、atomic=1。
  // 输入/输出及副作用：只读模型，不写 sge_num。
  // 失败/边界：返回未截断 int，超出 wire 宽度由 validate/writer 拒绝。
  function automatic int unsigned derive_sge_num();
    rdma_sq_payload_mode_e mode;
    int unsigned valid_sge_count;
    int unsigned inline_payload_bytes;
    int unsigned canonical_sge_num;
    bit inline_bytes_are_authority;

    derive_payload_authority(mode, valid_sge_count, inline_payload_bytes,
                             inline_bytes_are_authority,
                             canonical_sge_num);
    return canonical_sge_num;
  endfunction

  // 功能：校验 SQE handle、字段宽度、payload shape 与 SGE_NUM 一致性。
  // 输入/输出及副作用：只读模型，返回 rdma_status。
  // 失败/边界：按 shape、QP handle、字段宽度、transport extension、mode、count 的优先级拒绝，
  //   返回 INVALID_ARGUMENT；null SGE、count 超 8 bit 或 sge_num 与 derive_sge_num 不符均拒绝。
  virtual function rdma_status validate();
    rdma_status shape_status;
    rdma_status inline_authority_status;
    rdma_sq_payload_mode_e canonical_mode;
    int unsigned valid_sge_count;
    int unsigned inline_payload_bytes;
    int unsigned canonical_sge_num;
    bit inline_bytes_are_authority;

    shape_status = validate_payload_shape();
    if (!shape_status.ok())
      return shape_status;

    inline_authority_status = validate_inline_payload_authority();
    if (inline_authority_status == null || !inline_authority_status.ok())
      return inline_authority_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "SQE inline payload authority returned null status") :
        inline_authority_status;

    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "SQE requires QP handle");

    if (qpn > 21'h7ffff || icos > 3'd7 || index > 15'h7fff)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "SQE field width overflow");

    if (transport_ext != null &&
        transport_ext.transport_kind() != transport)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "SQE transport extension mismatch");

    if (payload_mode > RDMA_SQ_PAYLOAD_ATOMIC_FIXED)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "SQE payload mode is invalid");

    derive_payload_authority(canonical_mode, valid_sge_count,
                             inline_payload_bytes,
                             inline_bytes_are_authority,
                             canonical_sge_num);
    if (canonical_sge_num > 8'hff || sge_num != canonical_sge_num)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "SQE SGE_NUM does not match canonical payload count");

    return rdma_status::success();
  endfunction

  // 功能：生成含 QPN、hw_opcode、ring index 的日志文本。
  // 输入/输出及副作用：只读字段，返回 string。
  // 失败/边界：字段未配置时按当前值输出。
  virtual function string describe();
    return $sformatf(
        "XTR_SQE(qpn=%0d opcode=%0d index=%0d)",
        qpn,
        hw_opcode,
        index);
  endfunction
endclass

class rdma_hw_rqe_model extends rdma_rqe_model;
  `rdma_object_utils(rdma_hw_rqe_model)
  bit [23:0] qpn;
  bit [7:0] qp_sn;
  bit [3:0] hw_opcode;
  bit [14:0] index;
  bit wrap;
  // wr.h XTRDMA_QP_RQ_SIGN_EN (bit 56)：接收 WQE 是否带签名。驱动对 external-SGB
  // 表项也会强制置位，故 codec 把请求语义值与 encode 时的 wire 级覆盖分开保存。
  bit sign_en;
  bit valid;

  bit [31:0] payload_len;
  bit [7:0] signature;
  bit [7:0] sge_num;

  // XTRDMA_QP_RQ_SGB_PA 不是字节地址，而是驱动按 9 位对齐右移后的物理 SGB 地址。
  bit [54:0] sgb_pa;

  // external RQE 镜像只带 SGB_PA；descriptor 字节是 queue-data/host-memory 提供的
  // detached authority，不能由 PA 推断。
  bit external_sgb_descriptor_authority_valid;
  byte unsigned external_sgb_descriptor_bytes[$];

  // decoded external image 没有 typed SGE 列表；provenance 为模型私有状态，只能经 checked API
  // 暴露，防止调用方翻转 public bit 伪造 detached replay。count/payload/SGB_PA/descriptor
  // 快照冻结同一份认证输入，之后被改写会在 resolve 阶段 fail-closed。
  local bit decoded_raw_sgb_provenance_valid;
  local bit [7:0] external_sgb_authority_sge_num;
  local bit [31:0] external_sgb_authority_payload_len;
  local bit [54:0] external_sgb_authority_sgb_pa;
  local byte unsigned external_sgb_authority_snapshot[$];

  // 功能：构造 RQE 模型，wire 字段清零。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name="rdma_hw_rqe_model");
    super.new(name);
    sign_en = 1'b0;
    sgb_pa = '0;
    external_sgb_descriptor_authority_valid = 1'b0;
    external_sgb_descriptor_bytes.delete();
    decoded_raw_sgb_provenance_valid = 1'b0;
    external_sgb_authority_sge_num = '0;
    external_sgb_authority_payload_len = '0;
    external_sgb_authority_sgb_pa = '0;
    external_sgb_authority_snapshot.delete();
  endfunction

  // 功能：安装调用方给出的 PA>>9 编码值。
  // 输入/输出及副作用：encoded_pa 为未截断 64 位输入；成功写 sgb_pa，失败保留旧值。
  // 失败/边界：encoded_pa[63:55] 任一置位超出 55 位字段，返回 INVALID_ARGUMENT。
  function rdma_status set_sgb_pa_encoded(bit [63:0] encoded_pa);
    if (encoded_pa[63:55] != 9'b0)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE encoded SGB_PA exceeds 55 bits");

    sgb_pa = encoded_pa[54:0];
    return rdma_status::success();
  endfunction

  // 功能：把驱动 API 的物理 SGB 地址转换为 PA>>9 模型字段。
  // 输入/输出及副作用：成功更新 sgb_pa，失败保留旧值。
  // 失败/边界：低 9 位非零（未 512B 对齐）或转换后超过 55 位返回 INVALID_ARGUMENT。
  function rdma_status set_sgb_pa_from_physical(bit [63:0] physical_pa);
    bit [63:0] encoded_pa;

    if (physical_pa[8:0] != 9'b0)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE physical SGB_PA is not 512-byte aligned");

    encoded_pa = physical_pa >> 9;
    return set_sgb_pa_encoded(encoded_pa);
  endfunction

  // 功能：把编码后的 SGB_PA 还原为物理地址。
  // 输入/输出及副作用：返回低 9 位补零的值快照。
  // 失败/边界：无。
  function bit [63:0] sgb_pa_as_physical();
    return {sgb_pa, 9'b0};
  endfunction

  // 功能：按驱动过滤规则从 SGE 列表计算有效 descriptor 数和总长度，是 RQE typed authority 的唯一来源。
  //   length==0 被过滤，0x8000_0000 保留为 2GiB sentinel。
  // 输入/输出及副作用：结果经 output 返回；只读 sges。
  // 失败/边界：列表超过 RDMA_MAX_WQ_SGE、含 null、含 sentinel 以外的 bit31 长度或总长超 2GiB
  //   返回 INVALID_ARGUMENT；失败时 output 归零。
  function rdma_status derive_typed_sge_authority(
      output int unsigned valid_sge_count,
      output longint unsigned valid_payload_len
  );
    return rdma_sge_authority::derive_receive(
        sges, valid_sge_count, valid_payload_len);
  endfunction

  // 功能：把 typed SGE 列表按驱动 length/lkey/IOVA 大端布局串行化，供 external-SGB 签名与比对。
  // 输入/输出及副作用：descriptor_bytes 为输出，成功时长度为有效 SGE_NUM*16。
  // 失败/边界：统计失败、有效数为零或长度无法按 16B 表达返回 INVALID_ARGUMENT，输出为空。
  function rdma_status build_typed_sgb_descriptor_bytes(
      output byte unsigned descriptor_bytes[]
  );
    int unsigned valid_sge_count;
    longint unsigned valid_payload_len;
    int unsigned descriptor_index;
    rdma_status status;

    descriptor_bytes = new[0];
    status = derive_typed_sge_authority(valid_sge_count, valid_payload_len);
    if (!status.ok())
      return status;
    if (valid_sge_count == 0)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE typed SGB descriptor list is empty");

    descriptor_bytes = new[valid_sge_count * 16];
    descriptor_index = 0;
    foreach (sges[i]) begin
      bit [31:0] descriptor_length;

      if (sges[i].length == 0)
        continue;

      descriptor_length = sges[i].length == 32'h8000_0000 ?
                          32'b0 : sges[i].length;
      for (int unsigned byte_index = 0; byte_index < 4; byte_index++) begin
        descriptor_bytes[descriptor_index++] =
            descriptor_length[31 - byte_index * 8 -: 8];
      end
      for (int unsigned byte_index = 0; byte_index < 4; byte_index++) begin
        descriptor_bytes[descriptor_index++] =
            sges[i].lkey[31 - byte_index * 8 -: 8];
      end
      for (int unsigned byte_index = 0; byte_index < 8; byte_index++) begin
        descriptor_bytes[descriptor_index++] =
            sges[i].iova.value[63 - byte_index * 8 -: 8];
      end
    end

    return rdma_status::success();
  endfunction

  // 功能：仅在 RQE codec 的 decode-active 窗口内标记 detached raw external image。
  //   codec handle 与 candidate identity 双重检查，防止调用方直接翻转状态。
  // 输入/输出及副作用：codec_handle 为 capability；成功只更新内部 provenance。
  // 失败/边界：codec 为 null/非 active、已有 marker、存在 typed SGE 或 descriptor authority
  //   返回 INVALID_STATE。
  function rdma_status mark_decoded_raw_sgb_provenance(
      rdma_hw_rqe_codec codec_handle);
    if (codec_handle == null ||
        !codec_handle.is_raw_decode_authorization_active(this) ||
        decoded_raw_sgb_provenance_valid ||
        sges.size() != 0 || external_sgb_descriptor_authority_valid)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "RQE raw SGB provenance requires an active codec decode");

    decoded_raw_sgb_provenance_valid = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：返回模型是否持有 codec 建立的 raw external-SGB 来源证明。
  // 输入/输出及副作用：只读，不暴露可写 marker。
  // 失败/边界：构造或 typed 模型返回 0；不能替代 resolve_payload_authority() 的校验。
  function bit has_decoded_raw_sgb_provenance();
    return decoded_raw_sgb_provenance_valid;
  endfunction

  // 功能：丢弃 external descriptor 字节及其冻结的 count/payload 快照，供重新授权。
  // 输入/输出及副作用：清除 authority bytes/valid 位和快照，不改 typed SGE 与 wire 字段。
  // 失败/边界：旧证明不可恢复；若仍是 detached raw，后续 encode 须重新安装 sge_num*16 字节。
  function void clear_external_sgb_descriptor_authority();
    external_sgb_descriptor_authority_valid = 1'b0;
    external_sgb_descriptor_bytes.delete();
    external_sgb_authority_sge_num = '0;
    external_sgb_authority_payload_len = '0;
    external_sgb_authority_sgb_pa = '0;
    external_sgb_authority_snapshot.delete();
  endfunction

  // 功能：校验 external descriptor 字节与 RQE 字段、typed SGE 或 raw provenance 的一致性。
  // 输入/输出及副作用：只读，返回状态。
  // 失败/边界：拒绝 N<=2、N>32、长度非 N*16、快照被改写、typed count/payload 或内容冲突，
  //   以及无 raw provenance 的空 sges 模型。
  function rdma_status validate_external_sgb_descriptor_authority();
    int unsigned valid_sge_count;
    longint unsigned valid_payload_len;
    byte unsigned typed_descriptor_bytes[];
    rdma_status status;

    if (!external_sgb_descriptor_authority_valid)
      return rdma_status::success();

    if (sge_num <= 2 || sge_num > RDMA_MAX_WQ_SGE)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE external SGB authority count is invalid");
    if (sgb_pa == 0)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE external SGB authority requires an SGB pointer");
    if (payload_len > 32'h8000_0000)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE external SGB payload length exceeds 2 GiB");
    if (external_sgb_descriptor_bytes.size() != int'(sge_num) * 16)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE external SGB descriptor authority length is invalid");
    if (external_sgb_authority_sge_num != sge_num ||
        external_sgb_authority_payload_len != payload_len ||
        external_sgb_authority_sgb_pa != sgb_pa)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "RQE external SGB authority snapshot is stale");
    if (external_sgb_authority_snapshot.size() !=
        external_sgb_descriptor_bytes.size())
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "RQE external SGB authority bytes are stale");
    foreach (external_sgb_descriptor_bytes[i]) begin
      if (external_sgb_descriptor_bytes[i] !==
          external_sgb_authority_snapshot[i])
        return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "RQE external SGB authority bytes are stale");
    end

    if (sges.size() == 0) begin
      if (!decoded_raw_sgb_provenance_valid)
        return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "RQE external SGB authority lacks raw provenance");
      return rdma_status::success();
    end

    status = rdma_sge_authority::validate_receive_declaration(
        sges, sge_num, payload_len, valid_sge_count, valid_payload_len);
    if (!status.ok())
      return status;

    status = build_typed_sgb_descriptor_bytes(typed_descriptor_bytes);
    if (!status.ok())
      return status;
    if (typed_descriptor_bytes.size() != external_sgb_descriptor_bytes.size())
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "RQE external SGB authority descriptor count is stale");
    foreach (typed_descriptor_bytes[i]) begin
      if (typed_descriptor_bytes[i] !== external_sgb_descriptor_bytes[i])
        return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "RQE external SGB authority bytes are stale");
    end

    return rdma_status::success();
  endfunction

  // 功能：统一解析 RQE 当前可发布的 SGE_NUM、payload 长度与 external descriptor authority，
  //   供 validate、codec encode 与 make_rqe 共用，避免 typed/raw 双事实源。
  // 输入/输出及副作用：结果经 output 返回；只读模型。
  // 失败/边界：有 external authority 时须通过快照/typed/raw provenance 检查；否则 typed 统计须与
  //   sge_num/payload_len 一致，并拒绝范围、null、保留 bit31、2GiB 溢出；失败时 output 归零。
  function rdma_status resolve_payload_authority(
      output int unsigned effective_sge_count,
      output longint unsigned effective_payload_len
  );
    rdma_status status;

    effective_sge_count = 0;
    effective_payload_len = 0;

    if (external_sgb_descriptor_authority_valid) begin
      status = validate_external_sgb_descriptor_authority();
      if (!status.ok())
        return status;
      effective_sge_count = sge_num;
      effective_payload_len = payload_len;
      return rdma_status::success();
    end

    return rdma_sge_authority::validate_receive_declaration(
        sges, sge_num, payload_len,
        effective_sge_count, effective_payload_len);
  endfunction

  // 功能：安装与当前 external-SGB RQE 对应的 descriptor 字节（驱动大端布局），作为签名 authority。
  // 输入/输出及副作用：descriptor_bytes 为输入快照；成功时复制并置 authority valid。
  // 失败/边界：仅 external 布局（sge_num>2）且长度恰为 sge_num*16 时接受；否则保留旧 authority，
  //   返回 INVALID_ARGUMENT。
  function rdma_status set_external_sgb_descriptor_bytes(
      input byte unsigned descriptor_bytes[]);
    int unsigned expected_bytes;
    int unsigned valid_sge_count;
    longint unsigned valid_payload_len;
    byte unsigned typed_descriptor_bytes[];
    rdma_status status;

    expected_bytes = int'(sge_num) * 16;
    if (sge_num <= 2 || sge_num > RDMA_MAX_WQ_SGE ||
        descriptor_bytes.size() != expected_bytes)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE external SGB descriptor authority length is invalid");

    if (sgb_pa == 0)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE external SGB descriptor authority requires an SGB pointer");
    if (payload_len > 32'h8000_0000)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE external SGB payload length exceeds 2 GiB");

    if (external_sgb_descriptor_authority_valid) begin
      status = validate_external_sgb_descriptor_authority();
      if (!status.ok())
        return status;
      if (external_sgb_authority_sge_num != sge_num ||
          external_sgb_authority_payload_len != payload_len ||
          external_sgb_authority_sgb_pa != sgb_pa ||
          external_sgb_descriptor_bytes.size() != descriptor_bytes.size())
        return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "RQE external SGB authority is already frozen");
      foreach (descriptor_bytes[i]) begin
        if (descriptor_bytes[i] !== external_sgb_descriptor_bytes[i])
          return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "RQE external SGB authority is already frozen");
      end
      return rdma_status::success();
    end

    if (sges.size() == 0) begin
      if (!decoded_raw_sgb_provenance_valid)
        return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "RQE external SGB authority lacks raw provenance");
    end
    else begin
      status = rdma_sge_authority::validate_receive_declaration(
          sges, sge_num, payload_len, valid_sge_count, valid_payload_len);
      if (!status.ok())
        return status;
      status = build_typed_sgb_descriptor_bytes(typed_descriptor_bytes);
      if (!status.ok())
        return status;
      foreach (typed_descriptor_bytes[i]) begin
        if (typed_descriptor_bytes[i] !== descriptor_bytes[i])
          return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "RQE external SGB descriptor bytes disagree with typed SGE");
      end
    end

    external_sgb_descriptor_bytes.delete();
    foreach (descriptor_bytes[i])
      external_sgb_descriptor_bytes.push_back(descriptor_bytes[i]);
    external_sgb_descriptor_authority_valid = 1'b1;
    external_sgb_authority_sge_num = sge_num;
    external_sgb_authority_payload_len = payload_len;
    external_sgb_authority_sgb_pa = sgb_pa;
    external_sgb_authority_snapshot.delete();
    foreach (descriptor_bytes[i])
      external_sgb_authority_snapshot.push_back(descriptor_bytes[i]);
    return rdma_status::success();
  endfunction

  // 功能：把 rhs 的 RQE header、SGB 地址和 external descriptor authority 复制为 detached 快照。
  // 输入/输出及副作用：descriptor byte queue 逐元素复制，target_h 按基类规则作非拥有句柄。
  // 失败/边界：rhs 为空或类型不符触发 RDMA_COPY_TYPE fatal；不在此重新推断长度 authority。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_rqe_model x;

    super.do_copy(rhs);
    if (!$cast(x, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "xtr RQE copy mismatch")

    qpn = x.qpn;
    qp_sn = x.qp_sn;
    hw_opcode = x.hw_opcode;
    index = x.index;
    wrap = x.wrap;
    sign_en = x.sign_en;
    valid = x.valid;
    payload_len = x.payload_len;
    signature = x.signature;
    sge_num = x.sge_num;
    sgb_pa = x.sgb_pa;
    external_sgb_descriptor_authority_valid =
        x.external_sgb_descriptor_authority_valid;
    decoded_raw_sgb_provenance_valid = x.decoded_raw_sgb_provenance_valid;
    external_sgb_authority_sge_num = x.external_sgb_authority_sge_num;
    external_sgb_authority_payload_len = x.external_sgb_authority_payload_len;
    external_sgb_authority_sgb_pa = x.external_sgb_authority_sgb_pa;
    external_sgb_descriptor_bytes.delete();
    foreach (x.external_sgb_descriptor_bytes[i])
      external_sgb_descriptor_bytes.push_back(x.external_sgb_descriptor_bytes[i]);
    external_sgb_authority_snapshot.delete();
    foreach (x.external_sgb_authority_snapshot[i])
      external_sgb_authority_snapshot.push_back(
          x.external_sgb_authority_snapshot[i]);
  endfunction

  // 功能：校验 RQE route handle、index 与 typed/raw payload authority，确认 sge_num/payload_len
  //   与唯一有效 SGE 来源一致后才允许编码。
  // 输入/输出及副作用：只读模型，返回 rdma_status。
  // 失败/边界：拒绝 handle 缺失/kind 错误、index 越界、raw SGE 数量/长度越界、typed count/payload
  //   不符、external 快照过期或无 provenance 的 detached authority。
  virtual function rdma_status validate();
    int unsigned effective_sge_count;
    longint unsigned effective_payload_len;
    rdma_status status;

    if (target_h == null ||
        !(target_h.kind inside {RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ}))
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE requires QP or SRQ handle");

    if (index > 15'h7fff)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE index exceeds width");

    status = resolve_payload_authority(
        effective_sge_count, effective_payload_len);
    if (!status.ok())
      return status;

    return rdma_status::success();
  endfunction

  // 功能：生成 RQE 日志文本。
  // 输入/输出及副作用：只读字段，返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf(
        "XTR_RQE(qpn=%0d opcode=%0d index=%0d sign_en=%0d sgb_pa=0x%0h)",
        qpn, hw_opcode, index, sign_en, sgb_pa);
  endfunction
endclass

class rdma_hw_cqe_model extends rdma_cqe_model;
  `rdma_object_utils(rdma_hw_cqe_model)

  // wr.h 的公共 qword0/qword1 字段。
  rdma_cqe_variant_e variant;
  bit [17:0] qpn;
  bit [2:0] qp_state;
  bit [14:0] wqe_index;
  bit wqe_wrap;
  bit polarity;
  bit rq_cqe;
  bit srfq;
  bit se;
  bit sign_en;
  bit vlan;
  bit ipv6;
  bit [1:0] cqe_format;
  bit resize_cqe;
  bit ud_mc;
  bit [7:0] packet_opcode;
  bit [7:0] ecode;
  bit [31:0] payload_len;
  bit [31:0] immediate_data;
  bit [31:0] immdt_data_invld_key;

  // qword2 overlay 字段：每种 CQE variant 只有一个 overlay 有效，其余值在编码镜像中必须为零。
  bit [7:0] signature;
  bit [7:0] rc_remote_syndrome;
  bit [23:0] ud_src_qpn;
  bit rqe_cpl;
  bit [11:0] srfqn;
  bit srfqe_wrap;
  bit [14:0] srfqe_index;

  // wr.h 中 qword2 是物理 union：decode 得到的 raw word 一直是 authority，
  // 直到调用方显式清除并为新镜像选定一个 typed overlay。
  bit raw_qword2_valid;
  bit [63:0] raw_qword2;

  // qword3 仅在显式授权的 UD completion 中出现。
  bit [47:0] ud_smac;
  bit [15:0] ud_vlan_tag;

  // CQE profile payload 是 detached 字节快照，与 payload_len 独立：
  // 驱动上报的总包长可以大于 CQE 项内携带的 inline 字节数。
  byte unsigned payload[$];

  // 功能：构造 CQE 模型。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cqe_model");
    super.new(name);
    variant = RDMA_CQE_VARIANT_RC;
    raw_qword2_valid = 1'b0;
    raw_qword2 = '0;
    payload.delete();
  endfunction

  // 功能：把 rhs 的 CQE variant、header/overlay 字段和 raw qword2 authority 复制为 detached 快照。
  // 输入/输出及副作用：payload queue 逐元素复制，QP/CQ 句柄按基类规则作非拥有引用。
  // 失败/边界：rhs 为空或类型不符触发 RDMA_COPY_TYPE fatal；raw 与 typed 字段同时复制，不改写保留位。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cqe_model x;

    super.do_copy(rhs);
    if (!$cast(x, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "xtr CQE copy mismatch")

    variant = x.variant;
    qpn = x.qpn;
    qp_state = x.qp_state;
    wqe_index = x.wqe_index;
    wqe_wrap = x.wqe_wrap;
    rq_cqe = x.rq_cqe;
    polarity = x.polarity;
    srfq = x.srfq;
    se = x.se;
    sign_en = x.sign_en;
    vlan = x.vlan;
    ipv6 = x.ipv6;
    cqe_format = x.cqe_format;
    resize_cqe = x.resize_cqe;
    ud_mc = x.ud_mc;
    packet_opcode = x.packet_opcode;
    ecode = x.ecode;
    payload_len = x.payload_len;
    immediate_data = x.immediate_data;
    immdt_data_invld_key = x.immdt_data_invld_key;
    signature = x.signature;
    rc_remote_syndrome = x.rc_remote_syndrome;
    ud_src_qpn = x.ud_src_qpn;
    rqe_cpl = x.rqe_cpl;
    srfqn = x.srfqn;
    srfqe_wrap = x.srfqe_wrap;
    srfqe_index = x.srfqe_index;
    raw_qword2_valid = x.raw_qword2_valid;
    raw_qword2 = x.raw_qword2;
    ud_smac = x.ud_smac;
    ud_vlan_tag = x.ud_vlan_tag;
    payload.delete();
    foreach (x.payload[i])
      payload.push_back(x.payload[i]);
  endfunction

  // 功能：返回显式 CQE variant，作为 qword2/qword3 overlay 的唯一语义 authority。
  // 输入/输出及副作用：只读 variant。
  // 失败/边界：不从 raw overlay 非零值猜传输类型；合法性由 validate() 检查，默认 RC 只是兼容初值。
  function rdma_cqe_variant_e resolved_variant();
    return variant;
  endfunction

  // 功能：放弃 decode 保存的 qword2 raw authority，允许清理后按显式 variant 重新编码。
  // 输入/输出及副作用：清除 raw_qword2_valid 和 raw_qword2，不改其他字段。
  // 失败/边界：不可恢复；若仍保留冲突的 RC/UD/RQ 字段，后续 encode 按 typed variant fail-closed。
  function void clear_raw_qword2_authority();
    raw_qword2_valid = 1'b0;
    raw_qword2 = '0;
  endfunction


  // 功能：校验 CQE QP handle、variant 取值，以及 typed 模型中不属于所选 variant 的字段必须为零。
  // 输入/输出及副作用：status 为 null 时创建 cqe_status。
  // 失败/边界：QP handle 缺失/kind 错误、variant 非法或跨 variant 字段非零返回 INVALID_ARGUMENT；
  //   raw decode（raw_qword2_valid）不做跨 variant 检查。
  virtual function rdma_status validate();
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "CQE requires QP handle");

    if (status == null)
      status = rdma_status::type_id::create("cqe_status");

    if (variant > RDMA_CQE_VARIANT_RQ_SRFQ)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "CQE variant is invalid");

    // raw decode 可同时暴露 qword2 的所有物理解释，由 codec 对照 raw_qword2 校验；
    // 新建 typed 模型则不得静默丢弃属于其他 variant 的字段。
    if (!raw_qword2_valid) begin
      if (resolved_variant() == RDMA_CQE_VARIANT_RC &&
          (ud_src_qpn != 0 || rqe_cpl != 0 || srfqn != 0 ||
           srfqe_wrap != 0 || srfqe_index != 0 || ud_smac != 0 ||
           ud_vlan_tag != 0))
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "CQE non-RC fields require an explicit overlay variant");

      if (resolved_variant() == RDMA_CQE_VARIANT_UD &&
          (rc_remote_syndrome != 0 || rqe_cpl != 0 || srfqn != 0 ||
           srfqe_wrap != 0 || srfqe_index != 0))
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "CQE RC/RQ fields are invalid for the UD variant");

      if (resolved_variant() == RDMA_CQE_VARIANT_RQ_SRFQ &&
          (rc_remote_syndrome != 0 || ud_src_qpn != 0 || ud_smac != 0 ||
           ud_vlan_tag != 0))
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "CQE RC/UD fields are invalid for the RQ/SRFQ variant");
    end

    return rdma_status::success();
  endfunction

  // 功能：生成 CQE 日志文本。
  // 输入/输出及副作用：只读字段，返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf(
        "XTR_CQE(qpn=%0d index=%0d variant=%0d ecode=0x%02x)",
        qpn, wqe_index, variant, ecode);
  endfunction
endclass

class rdma_hw_ceqe_model extends rdma_ceqe_model;
  `rdma_object_utils(rdma_hw_ceqe_model)
  bit [20:0] qpn;
  bit [20:0] cqn;
  bit [7:0] ecode;
  bit [7:0] packet_opcode;
  bit [15:0] cq_pi;
  bit cq_pi_wrap;
  bit valid;

  bit urc_flag;
  bit urc_sq_cqe_valid;
  bit urc_rq_cqe_valid;
  bit [1:0] urc_abnormal_cqe_type;
  bit [7:0] urc_abnormal_cqe_remote_ecode;
  bit urc_abnormal_cqe_wqe_idx_wrap;
  bit [14:0] urc_abnormal_cqe_wqe_idx;
  bit urc_hw_cpl_sq_wqe_idx_wrap;
  bit [14:0] urc_hw_cpl_sq_wqe_idx;
  bit urc_hw_cpl_rq_wqe_idx_wrap;
  bit [14:0] urc_hw_cpl_rq_wqe_idx;

  // qword1 含两种带物理别名的驱动视图：decode 后以原始 word 为 authority，
  // 避免通过猜测的语义视图改写未激活的 overlay。
  bit raw_qword1_valid;
  bit [63:0] raw_qword1;

  // 规范 CEQE 编码需要显式给出 routed CQ 的 transport；新建模型默认未认证，
  // 调用方不得从 urc_flag 默认值推断 RC/URC。
  rdma_transport_e profile_transport;
  bit profile_transport_valid;
  bit raw_qword1_replay_authorized;

  // 功能：构造 CEQE 模型，raw qword1 authority 默认无效。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：不校验 qpn/cqn 或 URC overlay，由 validate/decode 检查。
  function new(string name = "rdma_hw_ceqe_model");
    super.new(name);
    profile_transport = RDMA_TRANSPORT_RESERVED;
    profile_transport_valid = 1'b0;
    raw_qword1_valid = 1'b0;
    raw_qword1 = '0;
    raw_qword1_replay_authorized = 1'b0;
  endfunction

  // 功能：把 rhs 的 CEQE qword0/1 字段和 raw qword1 authority 复制到当前对象。
  // 输入/输出及副作用：super.do_copy 处理 CQ handle；本方法只复制值字段。
  // 失败/边界：rhs 为空或类型不符触发 RDMA_COPY_TYPE fatal；raw authority 不被清除或重算。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_ceqe_model x;

    super.do_copy(rhs);
    if (!$cast(x, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "xtr CEQE copy mismatch")

    qpn = x.qpn;
    cqn = x.cqn;
    ecode = x.ecode;
    packet_opcode = x.packet_opcode;
    cq_pi = x.cq_pi;
    cq_pi_wrap = x.cq_pi_wrap;
    valid = x.valid;
    urc_flag = x.urc_flag;
    urc_sq_cqe_valid = x.urc_sq_cqe_valid;
    urc_rq_cqe_valid = x.urc_rq_cqe_valid;
    urc_abnormal_cqe_type = x.urc_abnormal_cqe_type;
    urc_abnormal_cqe_remote_ecode = x.urc_abnormal_cqe_remote_ecode;
    urc_abnormal_cqe_wqe_idx_wrap = x.urc_abnormal_cqe_wqe_idx_wrap;
    urc_abnormal_cqe_wqe_idx = x.urc_abnormal_cqe_wqe_idx;
    urc_hw_cpl_sq_wqe_idx_wrap = x.urc_hw_cpl_sq_wqe_idx_wrap;
    urc_hw_cpl_sq_wqe_idx = x.urc_hw_cpl_sq_wqe_idx;
    urc_hw_cpl_rq_wqe_idx_wrap = x.urc_hw_cpl_rq_wqe_idx_wrap;
    urc_hw_cpl_rq_wqe_idx = x.urc_hw_cpl_rq_wqe_idx;
    raw_qword1_valid = x.raw_qword1_valid;
    raw_qword1 = x.raw_qword1;
    profile_transport = x.profile_transport;
    profile_transport_valid = x.profile_transport_valid;
    raw_qword1_replay_authorized = x.raw_qword1_replay_authorized;
  endfunction

  // 功能：冻结 routed CQ 提供的 CEQE wire profile，供编码判定 RC/UD 与 URC 的 overlay 归属。
  // 输入/输出及副作用：成功时写 profile_transport/profile_transport_valid，不改 qword 字段。
  // 失败/边界：CUSTOM、RESERVED 及未知 transport 被拒绝；重复设置相同值幂等，
  //   改为不同值返回 INVALID_STATE。
  function rdma_status set_profile_transport_authority(
      rdma_transport_e transport);
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}))
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "CEQE profile transport is unsupported");
    if (profile_transport_valid && profile_transport != transport)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "CEQE profile transport authority is already frozen");
    profile_transport = transport;
    profile_transport_valid = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：显式允许把 decode 保存的 qword1 原样重放，保留 inactive physical overlay。
  // 输入/输出及副作用：成功只置 raw_qword1_replay_authorized。
  // 失败/边界：无 raw_qword1_valid 返回 INVALID_STATE；授权不绕过 profile transport、
  //   raw/typed 一致性或 reserved 校验。
  function rdma_status authorize_raw_qword1_replay();
    if (!raw_qword1_valid)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "CEQE raw qword1 replay requires decoded authority");
    raw_qword1_replay_authorized = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：校验 CEQE 的 CQ handle。
  // 输入/输出及副作用：只读 cq_h；不校验 cqn 与 handle incarnation 的对应关系，
  //   该关系由 queue-data attachment authority 负责。
  // 失败/边界：cq_h 为空或 kind 非 CQ 返回 INVALID_ARGUMENT；未知 local CQN 由拥有 topology 的调用方拒绝。
  virtual function rdma_status validate();
    if (cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "CEQE requires CQ handle");

    return rdma_status::success();
  endfunction

  // 功能：生成 CEQE 日志文本。
  // 输入/输出及副作用：只读字段，返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("XTR_CEQE(qpn=%0d cqn=%0d urc=%0b)",
                     qpn, cqn, urc_flag);
  endfunction
endclass

class rdma_hw_aeqe_model extends rdma_aeqe_model;
  `rdma_object_utils(rdma_hw_aeqe_model)
  bit [17:0] qpn;
  bit [2:0] qp_state;
  bit [7:0] ecode;
  bit [7:0] packet_opcode;
  bit [22:0] wqe_index;
  bit wqe_wrap;
  bit valid;

  bit srfq_en;
  bit overflow_flag;
  bit urc_flag;
  bit cq_invalid_flag;
  bit [1:0] urc_abnormal_cqe_type;
  bit [12:0] cqn_eqn_high;
  bit [5:0] cqn_eqn_low;
  bit [7:0] urc_remote_ecode;
  bit [11:0] srfqn;
  bit [15:0] srfqe_idx;

  // 规范 AEQE 编码须绑定 event.c 选定的 owner route；新建模型这些字段无效，
  // 由 queue-data engine 在 manager lookup 后冻结。
  rdma_aeqe_event_class_e profile_class;
  rdma_resource_kind_e profile_owner_kind;
  bit profile_class_valid;
  bit profile_owner_valid;

  // raw decode 保留两个物理 qword，以便 replay 时保留驱动持有的 overlay 位；
  // typed 视图不作为写入 authority，replay 需单独授权，不由 ecode 推断。
  bit raw_qwords_valid;
  bit [63:0] raw_qword0;
  bit [63:0] raw_qword1;
  bit raw_replay_authorized;

  // 功能：构造 AEQE 模型，事件字段为零默认值。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：不校验 QP state、CQN/EQN 拆分或 ecode，由 validate/decode 检查。
  function new(string name = "rdma_hw_aeqe_model");
    super.new(name);
    profile_class = RDMA_AEQE_EVENT_QP;
    profile_owner_kind = RDMA_RESOURCE_QP;
    profile_class_valid = 1'b0;
    profile_owner_valid = 1'b0;
    raw_qwords_valid = 1'b0;
    raw_qword0 = '0;
    raw_qword1 = '0;
    raw_replay_authorized = 1'b0;
  endfunction

  // 功能：把 rhs 的 AEQE 事件字段、CQN/EQN 拆分值和 URC 扩展复制为 detached 事件快照。
  // 输入/输出及副作用：super.do_copy 处理目标句柄；本方法只覆盖本类值字段。
  // 失败/边界：rhs 为空或类型不符触发 RDMA_COPY_TYPE fatal；不重组 cqn_eqn。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_aeqe_model x;

    super.do_copy(rhs);
    if (!$cast(x, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "xtr AEQE copy mismatch")

    qpn = x.qpn;
    qp_state = x.qp_state;
    ecode = x.ecode;
    packet_opcode = x.packet_opcode;
    wqe_index = x.wqe_index;
    wqe_wrap = x.wqe_wrap;
    valid = x.valid;
    srfq_en = x.srfq_en;
    overflow_flag = x.overflow_flag;
    urc_flag = x.urc_flag;
    cq_invalid_flag = x.cq_invalid_flag;
    urc_abnormal_cqe_type = x.urc_abnormal_cqe_type;
    cqn_eqn_high = x.cqn_eqn_high;
    cqn_eqn_low = x.cqn_eqn_low;
    urc_remote_ecode = x.urc_remote_ecode;
    srfqn = x.srfqn;
    srfqe_idx = x.srfqe_idx;
    profile_class = x.profile_class;
    profile_owner_kind = x.profile_owner_kind;
    profile_class_valid = x.profile_class_valid;
    profile_owner_valid = x.profile_owner_valid;
    raw_qwords_valid = x.raw_qwords_valid;
    raw_qword0 = x.raw_qword0;
    raw_qword1 = x.raw_qword1;
    raw_replay_authorized = x.raw_replay_authorized;
  endfunction

  // 功能：冻结 AEQE 的 ecode class 与 primary resource kind，供 codec 与 publish route 校验 owner。
  // 输入/输出及副作用：event_class、owner_kind 为已完成 manager lookup 的输入；成功时写两个字段。
  // 失败/边界：class/kind 组合不符 event.c 分派或枚举未知返回 INVALID_ARGUMENT；
  //   重复切换到不同 authority 返回 INVALID_STATE，不会只冻结一半。
  function rdma_status set_profile_owner_authority(
      rdma_aeqe_event_class_e event_class,
      rdma_resource_kind_e owner_kind
  );
    bit valid_pair;

    valid_pair = 1'b0;
    case (event_class)
      RDMA_AEQE_EVENT_QP:
        valid_pair = owner_kind == RDMA_RESOURCE_QP;
      RDMA_AEQE_EVENT_SRQ:
        valid_pair = owner_kind == RDMA_RESOURCE_SRQ;
      RDMA_AEQE_EVENT_CQ:
        valid_pair = owner_kind == RDMA_RESOURCE_CQ;
      RDMA_AEQE_EVENT_EQ:
        valid_pair = owner_kind inside {RDMA_RESOURCE_CEQ,
                                        RDMA_RESOURCE_AEQ};
      RDMA_AEQE_EVENT_DIAGNOSTIC:
        valid_pair = owner_kind == RDMA_RESOURCE_FUNCTION;
      RDMA_AEQE_EVENT_FLUSH:
        valid_pair = owner_kind inside {RDMA_RESOURCE_FUNCTION,
                                        RDMA_RESOURCE_QP};
      default:
        valid_pair = 1'b0;
    endcase

    if (!valid_pair)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "AEQE profile class/owner kind is invalid");

    if ((profile_class_valid || profile_owner_valid) &&
        (profile_class != event_class || profile_owner_kind != owner_kind))
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "AEQE profile owner authority is already frozen");

    profile_class = event_class;
    profile_owner_kind = owner_kind;
    profile_class_valid = 1'b1;
    profile_owner_valid = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：显式允许把 decode 保存的两个 AEQE qword 原样重放。
  // 输入/输出及副作用：成功只置 raw_replay_authorized。
  // 失败/边界：decode 尚未建立 raw authority 返回 INVALID_STATE；授权不绕过 profile owner、
  //   raw/typed 一致性和 reserved mask 检查。
  function rdma_status authorize_raw_replay();
    if (!raw_qwords_valid)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "AEQE raw replay requires decoded qword authority");
    raw_replay_authorized = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：校验 AEQE 中与 owner route 无关的 wire 字段，供 publish 在 route lookup 前检查 severity。
  // 输入/输出及副作用：只读 severity，返回状态。
  // 失败/边界：severity 不在四个定义枚举内返回 INVALID_ARGUMENT；3-bit qp_state 的 0..7 均为合法 wire 值
  //   （6/7 仅由 canonical authoring 拒绝）；target_h 为空不在此拒绝，非 QP route 可由 wire ID 推导。
  function rdma_status validate_wire_fields();
    if (!(severity inside {RDMA_SEVERITY_INFO, RDMA_SEVERITY_WARNING,
                           RDMA_SEVERITY_ERROR, RDMA_SEVERITY_FATAL}))
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "AEQE severity is invalid");
    return rdma_status::success();
  endfunction

  // 功能：把 AEQE 的高/低拆分坐标重组为逻辑 EQ/CQ 编号。
  // 输入/输出及副作用：按 defs.h 的 CQN_EQN_LSHIFT=6 返回 19 位值。
  // 失败/边界：结果为 (cqn_eqn_high << 6) | cqn_eqn_low，不是两字段直接串接。
  function bit [18:0] logical_cqn_eqn();
    bit [18:0] high_part;

    high_part = cqn_eqn_high;
    high_part = high_part << RDMA_AEQE_CQN_EQN_LSHIFT;
    return high_part | cqn_eqn_low;
  endfunction

  // 功能：校验 AEQE 基础 wire 字段并确认已安装 target authority，作为 encode 分流前的共同前置条件。
  // 输入/输出及副作用：只读 target_h、severity、qp_state，返回状态。
  // 失败/边界：target_h 为空或 severity 非法返回 INVALID_ARGUMENT；QP_ST=6/7 可进入显式 raw replay，
  //   canonical 路径由 validate_canonical_fields 拒绝。
  virtual function rdma_status validate();
    rdma_status wire_status;

    wire_status = validate_wire_fields();
    if (wire_status == null || !wire_status.ok())
      return wire_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "AEQE wire validation returned null status") :
        wire_status;

    if (target_h == null)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "AEQE target handle is null");
    return rdma_status::success();
  endfunction

  // 功能：生成 AEQE 日志文本。
  // 输入/输出及副作用：只读字段，返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("XTR_AEQE(qpn=%0d ecode=0x%02x cqn_eqn=%0d)",
                     qpn, ecode, logical_cqn_eqn());
  endfunction
endclass

virtual class rdma_hw_queue_codec_base extends rdma_codec_base;

  // 功能：构造 queue codec 抽象基类。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：不校验 model/image，由具体 codec 的 encode/decode 入口负责。
  function new(string name="rdma_hw_queue_codec_base");
    super.new(name);
  endfunction
  // 功能：纯虚，返回派生 codec 对应的 image 类型。
  // 输入/输出及副作用：无。
  // 失败/边界：基类无默认值；类型与实际布局不符会在 metadata 校验时被拒绝。
  protected pure virtual function rdma_image_kind_e image_kind_expected();

  // 功能：纯虚，返回派生 codec 的固定 image 字节数，用于 builder reset 与长度检查。
  // 输入/输出及副作用：无。
  // 失败/边界：派生实现必须与驱动几何一致。
  protected pure virtual function int unsigned image_bytes();

  // 功能：纯虚，把 model 业务字段写入已 reset 的 qword builder。
  // 输入/输出及副作用：model 只读，b 为写入器；成功只更新 b。
  // 失败/边界：类型/范围/重叠/put 失败须返回错误，上层丢弃 b 的部分内容。
  protected pure virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b);

  // 功能：纯虚，从已反序列化的 builder 解码出 detached model 快照。
  // 输入/输出及副作用：b 只读，model 为输出。
  // 失败/边界：失败时返回错误，model 保持 null 或不发布不完整快照。
  protected pure virtual function rdma_status decode_fields(rdma_hw_qword_builder b, output rdma_hw_model model);

  // 功能：纯虚，按驱动 profile 检查 builder 中的 reserved 位和 variant 约束。
  // 输入/输出及副作用：b 只读。
  // 失败/边界：reserved 位非零、qword 数量错误或 variant 几何不符须返回 CODEC_ERROR。
  protected pure virtual function rdma_status check_reserved(rdma_hw_qword_builder b);

  // 功能：把错误消息封装为 CODEC_ERROR 状态。
  // 输入/输出及副作用：m 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status err(string m);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, m);
  endfunction
  // 功能：按 model 的实际类型取其关联 handle（QP/target/CQ）的 generation。
  // 输入/输出及副作用：只读 model。
  // 失败/边界：类型不识别或对应 handle 为空返回 0（视为 stale）。
  protected function int unsigned model_handle_generation(rdma_hw_model model);
    rdma_hw_sqe_model sq;
    rdma_hw_rqe_model rq;
    rdma_hw_cqe_model cq;
    rdma_hw_ceqe_model eq;
    rdma_hw_aeqe_model aq;

    if ($cast(sq, model) && sq.qp_h != null)
      return sq.qp_h.generation;

    if ($cast(rq, model) && rq.target_h != null)
      return rq.target_h.generation;

    if ($cast(cq, model) && cq.qp_h != null)
      return cq.qp_h.generation;

    if ($cast(eq, model) && eq.cq_h != null)
      return eq.cq_h.generation;

    if ($cast(aq, model) && aq.target_h != null)
      return aq.target_h.generation;

    return 0;
  endfunction

  // 功能：校验 queue model 非空且 handle generation 非零。
  // 输入/输出及副作用：只读 model。
  // 失败/边界：model 为空返回 INVALID_ARGUMENT；generation 为 0 返回 STALE_GENERATION。
  virtual function rdma_status validate_model(rdma_hw_model model);
    if (model == null)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue model is null");

    if (model_handle_generation(model) == 0)
      return rdma_status::make(
          RDMA_SC_STALE_GENERATION,
          "queue model handle generation is stale");

    return rdma_status::success();
  endfunction

  // 功能：按固定布局校验 queue image 的空值、generation 与 metadata 前置条件。
  // 输入/输出及副作用：image、expected_length 只读，返回 rdma_status。
  // 失败/边界：拒绝顺序 null -> generation -> metadata：image 为空返回 "queue image is null"；
  //   generation 为 0 返回 stale；length/bytes、对齐、端序、image kind、硬件版本或
  //   backing/HMC/BAR/write target 不符返回 "queue image metadata is invalid"。
  protected function rdma_status validate_queue_image_metadata(
      rdma_hw_image image,
      int unsigned expected_length
  );
    if (image == null)
      return err("queue image is null");

    if (image.function_generation == 0)
      return rdma_status::make(
          RDMA_SC_STALE_GENERATION,
          "queue image generation is stale");

    if (image.length != expected_length ||
        image.bytes.size() != expected_length ||
        image.alignment != expected_length ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != image_kind_expected() ||
        image.hardware_version != RDMA_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 ||
        image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return err("queue image metadata is invalid");

    return rdma_status::success();
  endfunction

  // 功能：先校验 image metadata，再反序列化 bytes 并执行派生 codec 的 reserved 检查。
  // 输入/输出及副作用：image 只读，使用局部 builder b。
  // 失败/边界：metadata 校验失败原样返回；deserialize 失败包装为 codec error；
  //   reserved 检查失败原样返回；任一失败都不发布解码模型。
  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_hw_qword_builder b;
    byte unsigned p[];
    rdma_status s;

    s = validate_queue_image_metadata(image, image_bytes());
    if (!s.ok())
      return s;

    p = new[image_bytes()];
    foreach (p[i])
      p[i] = image.bytes[i];

    b = new("queue_validate");
    s = b.deserialize(p);
    if (!s.ok())
      return err(s.message);

    return check_reserved(b);
  endfunction

  // 功能：返回硬件端序。
  // 输入/输出及副作用：固定返回 RDMA_ENDIAN_BIG。
  // 失败/边界：无。
  virtual function rdma_byte_endian_e hardware_endian();
    return RDMA_ENDIAN_BIG;
  endfunction

  // 功能：生成 queue image 长度描述文本。
  // 输入/输出及副作用：读取 image_bytes()，返回 string。
  // 失败/边界：无。
  virtual function string describe_fields();
    return $sformatf(
        "rdma %0d-byte queue image",
        image_bytes());
  endfunction

  // 功能：按硬件布局把 model 编码为 image，写入前依次校验 model、reserved 与 image metadata。
  // 输入/输出及副作用：model 只读；成功时通过 output 发布完整 image。
  // 失败/边界：model 为空、字段非法或 codec 校验失败时返回错误，不发布部分 image。
  virtual function rdma_status encode(rdma_hw_model model, output rdma_hw_image image);
    rdma_hw_qword_builder b;
    byte unsigned p[];
    rdma_hw_image c;
    rdma_status s;

    image = null;

    s = validate_model(model);
    if (!s.ok())
      return s;

    b = new("queue_encode");
    s = b.reset(image_bytes());
    if (!s.ok())
      return err(s.message);

    s = encode_fields(model, b);
    if (!s.ok())
      return s;

    s = check_reserved(b);
    if (!s.ok())
      return s;

    p = new[0];
    s = b.serialize(p);
    if (!s.ok())
      return err(s.message);

    c = rdma_hw_image::type_id::create("queue_image");
    foreach (p[i])
      c.bytes.push_back(p[i]);

    c.length = image_bytes();
    c.alignment = image_bytes();
    c.endian = RDMA_ENDIAN_BIG;
    c.image_kind = image_kind_expected();
    c.hardware_version = RDMA_HW_VERSION;
    c.function_generation = model_handle_generation(model);
    c.write_target_kind = RDMA_HW_TARGET_NONE;

    image = c;
    return rdma_status::success();
  endfunction

  // 功能：校验 image 后解码为 detached model 快照。
  // 输入/输出及副作用：image 只读；成功时通过 output 发布快照。
  // 失败/边界：image 为空、长度/对齐/保留位非法或 decode_fields 失败时返回错误，不发布部分模型。
  virtual function rdma_status decode(rdma_hw_image image, output rdma_hw_model model);
    rdma_hw_qword_builder b;
    byte unsigned p[];
    rdma_status s;
    rdma_hw_model candidate;

    model = null;

    s = validate_image(image);
    if (!s.ok())
      return s;

    p = new[image_bytes()];
    foreach (p[i])
      p[i] = image.bytes[i];

    b = new("queue_decode");
    s = b.deserialize(p);
    if (!s.ok())
      return err(s.message);

    s = decode_fields(b, candidate);
    if (!s.ok())
      return s;

    model = candidate;
    return rdma_status::success();
  endfunction

  // 功能：把两个 model 分别编码后逐字节比较序列化结果。
  // 输入/输出及副作用：equal 为输出结果，mismatch 为首个差异描述；模型只读。
  // 失败/边界：任一 encode 失败直接返回其状态；metadata/字节差异以 equal=0 和 mismatch 报告，
  //   返回 success。
  virtual function rdma_status serialized_equal(rdma_hw_model lhs, rdma_hw_model rhs, output bit equal, output string mismatch);
    rdma_hw_image a;
    rdma_hw_image b;
    rdma_status s;

    equal = 0;
    mismatch = "";

    s = encode(lhs, a);
    if (!s.ok())
      return s;

    s = encode(rhs, b);
    if (!s.ok())
      return s;

    if (a.image_kind != b.image_kind || a.length != b.length) begin
      mismatch = "queue metadata differs";
      return rdma_status::success();
    end

    foreach (a.bytes[i]) begin
      if (a.bytes[i] !== b.bytes[i]) begin
        mismatch = $sformatf("queue byte %0d differs", i);
        return rdma_status::success();
      end
    end

    equal = 1;
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_sqe_codec_base extends rdma_hw_queue_codec_base;

  // 功能：构造 SQE codec 基类。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：transport/payload 检查由 encode_fields 和派生 codec 完成。
  function new(string name = "rdma_hw_sqe_codec_base");
    super.new(name);
  endfunction

  // 功能：返回 RDMA_IMAGE_SQE。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_SQE;
  endfunction

  // 功能：返回 SQ WQE 固定字节数 RDMA_WQE_BYTES。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  protected virtual function int unsigned image_bytes();
    return RDMA_WQE_BYTES;
  endfunction

  // 功能：在任何 RC/UD/URC builder 写入前统一校验 SQE generation、hw model shape 与 canonical SGE_NUM。
  // 输入/输出及副作用：先调基类校验 handle generation，再 cast 并调用 rdma_hw_sqe_model::validate。
  // 失败/边界：handle 为空/stale、类型不符、null SGE 或 count 不符返回非成功；
  //   raw decode 不经过本 authoring gate。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_hw_sqe_model sqe;
    rdma_status status;

    status = super.validate_model(model);
    if (status == null || !status.ok())
      return status;
    if (!$cast(sqe, model))
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "SQE model type mismatch");
    return sqe.validate();
  endfunction

  // 功能：向 builder 写一个 SQE 字段，底层失败归类为 CODEC_ERROR。
  // 输入/输出及副作用：o/l/w/v 为字节偏移、LSB、宽度和值；成功只更新 b。
  // 失败/边界：put_field 失败（越界、宽度非法、位冲突）时返回 CODEC_ERROR 并保留原消息。
  protected function rdma_status put(
      rdma_hw_qword_builder b,
      int unsigned o,
      int unsigned l,
      int unsigned w,
      bit [63:0] v
  );
    rdma_status s;

    s = b.put_field(o, l, w, v);
    if (!s.ok())
      return rdma_status::make(RDMA_SC_CODEC_ERROR, s.message);

    return s;
  endfunction

  // 功能：从 builder 读一个 SQE 字段，底层失败归类为 CODEC_ERROR。
  // 输入/输出及副作用：o/l/w 为位坐标，v 为输出值。
  // 失败/边界：get_field 失败时返回 CODEC_ERROR，v 仅在成功后有效。
  protected function rdma_status get(
      rdma_hw_qword_builder b,
      int unsigned o,
      int unsigned l,
      int unsigned w,
      inout bit [63:0] v
  );
    rdma_status s;

    s = b.get_field(o, l, w, v);
    if (!s.ok())
      return rdma_status::make(RDMA_SC_CODEC_ERROR, s.message);

    return s;
  endfunction

  // 功能：检查 SQE qword0 的 reserved 位。
  // 输入/输出及副作用：只读 b。
  // 失败/边界：保留位非零返回 err("SQE header reserved bits are nonzero")。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b);
    bit [63:0] w[];
    b.get_words(w);
    if (!rdma_raw_qword_mask_is_valid(
          w[0], 64'hefff_ffff_ffff_ffff))
      return err("SQE header reserved bits are nonzero");
    return rdma_status::success();
  endfunction

  // 功能：把已通过 authoring gate 的 SQE 公共 header 写入 builder；RC 模型再写 remote key/VA。
  // 输入/输出及副作用：model 只读，不再调用 model.validate。
  // 失败/边界：model 非 rdma_hw_sqe_model 或 put 失败返回错误；非 RC 只写公共 header 后成功。
  protected virtual function rdma_status encode_fields(
      rdma_hw_model model,
      rdma_hw_qword_builder b);
    rdma_hw_sqe_model x;
    rdma_status s;

    if (!$cast(x, model))
      return err("SQE model type mismatch");

    s = put(b, RDMA_SQ_WQE_QPN_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_QPN_LSB, RDMA_SQ_WQE_QPN_WIDTH, x.qpn);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_ICOS_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_ICOS_LSB, RDMA_SQ_WQE_ICOS_WIDTH, x.icos);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_QP_SN_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_QP_SN_LSB, RDMA_SQ_WQE_QP_SN_WIDTH, x.qp_sn);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_OPCODE_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_OPCODE_LSB, RDMA_SQ_WQE_OPCODE_WIDTH, x.hw_opcode);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_DST_PORT_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_DST_PORT_LSB, RDMA_SQ_WQE_DST_PORT_WIDTH, x.dst_port);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_INDEX_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_INDEX_LSB, RDMA_SQ_WQE_INDEX_WIDTH, x.index);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_WRAP_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_WRAP_LSB, RDMA_SQ_WQE_WRAP_WIDTH, x.wrap);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_SIGN_EN_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_SIGN_EN_LSB, RDMA_SQ_WQE_SIGN_EN_WIDTH, x.sign_en);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_SE_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_SE_LSB, RDMA_SQ_WQE_SE_WIDTH, x.se);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_FENCE_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_FENCE_LSB, RDMA_SQ_WQE_FENCE_WIDTH, x.fence);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_CE_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_CE_LSB, RDMA_SQ_WQE_CE_WIDTH, x.ce);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_VALID_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_VALID_LSB, RDMA_SQ_WQE_VALID_WIDTH, x.valid);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_SIGNATURE_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_SIGNATURE_LSB, RDMA_SQ_WQE_SIGNATURE_WIDTH,
            x.signature);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_RC_SGE_NUM_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_RC_SGE_NUM_LSB, RDMA_SQ_WQE_RC_SGE_NUM_WIDTH,
            x.sge_num);
    if (!s.ok())
      return s;

    if (x.transport != RDMA_TRANSPORT_RC)
      return rdma_status::success();

    s = put(b, RDMA_SQ_WQE_RC_REMOTE_KEY_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_RC_REMOTE_KEY_LSB, RDMA_SQ_WQE_RC_REMOTE_KEY_WIDTH,
            x.rkey);
    if (!s.ok())
      return s;
    s = put(b, RDMA_SQ_WQE_RC_REMOTE_VA_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_RC_REMOTE_VA_LSB, RDMA_SQ_WQE_RC_REMOTE_VA_WIDTH,
            x.remote_va.value);
    if (!s.ok())
      return s;
    return rdma_status::success();
  endfunction

  // 功能：解码 SQE 公共 header 与 RC remote 坐标，生成 detached RC SEND 模型。
  // 输入/输出及副作用：b 已通过 raw/layout 校验；成功时发布新模型和投影 QP handle。
  // 失败/边界：字段读取失败返回 CODEC_ERROR 且不发布 model；投影 handle 只保留 raw identity，
  //   不构成 Function/route authority。
  protected virtual function rdma_status decode_fields(
      rdma_hw_qword_builder b,
      output rdma_hw_model model);
    rdma_hw_sqe_model x;
    rdma_sqe_rc_ext ext;
    bit [63:0] v;
    rdma_status s;

    model = null;
    x = rdma_hw_sqe_model::type_id::create("decoded_sqe");
    x.transport = RDMA_TRANSPORT_RC;
    x.opcode = RDMA_WR_SEND;
    x.inline_data = 1'b1;
    x.payload.push_back(0);
    x.qp_h = rdma_hw_queue_projected_handle(
        "decoded_qp", RDMA_RESOURCE_QP, 0);
    ext = rdma_sqe_rc_ext::type_id::create("decoded_rc_ext");
    x.transport_ext = ext;

    `define SQGET(S,T) \
      v = '0; \
      s = get(b, S``_WORD_BYTE_OFFSET, S``_LSB, S``_WIDTH, v); \
      if (!s.ok()) return s; \
      T = v;
    `SQGET(RDMA_SQ_WQE_QPN, x.qpn)
    `SQGET(RDMA_SQ_WQE_ICOS, x.icos)
    `SQGET(RDMA_SQ_WQE_QP_SN, x.qp_sn)
    `SQGET(RDMA_SQ_WQE_OPCODE, x.hw_opcode)
    `SQGET(RDMA_SQ_WQE_DST_PORT, x.dst_port)
    `SQGET(RDMA_SQ_WQE_INDEX, x.index)
    `SQGET(RDMA_SQ_WQE_WRAP, x.wrap)
    `SQGET(RDMA_SQ_WQE_SIGN_EN, x.sign_en)
    `SQGET(RDMA_SQ_WQE_SE, x.se)
    `SQGET(RDMA_SQ_WQE_FENCE, x.fence)
    `SQGET(RDMA_SQ_WQE_CE, x.ce)
    `SQGET(RDMA_SQ_WQE_VALID, x.valid)
    `SQGET(RDMA_SQ_WQE_SIGNATURE, x.signature)
    `SQGET(RDMA_SQ_WQE_RC_SGE_NUM, x.sge_num)
    `SQGET(RDMA_SQ_WQE_RC_REMOTE_KEY, x.rkey)
    `SQGET(RDMA_SQ_WQE_RC_REMOTE_VA, x.remote_va.value)
    `undef SQGET

    model = x;
    return rdma_status::success();
  endfunction

endclass

// 功能：对 SQE 与 SGB 字节（跳过 signature 字节 image[16]）做 XOR，生成 XTR v1 签名基值。
// 输入/输出及副作用：image、sgb 只读。
// 失败/边界：image 为 null 时仅对 sgb 计算（返回 0 起始值）。
function automatic bit [7:0] rdma_hw_sq_signature_xor(
    rdma_hw_image image,
    byte unsigned sgb[$]);
  bit [7:0] value;
  value = 8'h00;
  if (image == null)
    return value;
  foreach (image.bytes[i])
    if (i != 16)
      value ^= image.bytes[i];
  foreach (sgb[i])
    value ^= sgb[i];
  return value;
endfunction

// 功能：校验 WQE 签名字节是否等于 ~xor(WQE, SGB)。
// 输入/输出及副作用：wqe、sgb 为输入，valid 为输出匹配结果。
// 失败/边界：WQE metadata 非法或 sgb 长度既非 0 也非 512 返回 INVALID_ARGUMENT，valid=0；
//   签名不符只置 valid=0，仍返回 success。
function automatic rdma_status validate_sq_signature(
    rdma_hw_image wqe,
    byte unsigned sgb[$],
    output bit valid);
  bit [7:0] expected;
  valid = 1'b0;
  if (wqe == null || wqe.image_kind != RDMA_IMAGE_SQE ||
      wqe.length != RDMA_WQE_BYTES || wqe.bytes.size() != RDMA_WQE_BYTES)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "SQ signature image metadata is invalid");
  if (sgb.size() != 0 && sgb.size() != 512)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "SQ signature SGB must be exactly 512 bytes");
  expected = ~rdma_hw_sq_signature_xor(wqe, sgb);
  valid = (wqe.bytes[16] === expected);
  return rdma_status::success();
endfunction

class rdma_hw_sqe_rc_codec extends rdma_hw_sqe_codec_base;
  `rdma_object_utils(rdma_hw_sqe_rc_codec)
  protected rdma_sq_payload_mode_e last_mode;
  protected bit [3:0] last_hw_opcode;

  // 功能：构造 RC SQE codec，last_mode/last_hw_opcode 清零。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name="rdma_hw_sqe_rc_codec");
    super.new(name);
    last_mode = RDMA_SQ_PAYLOAD_NONE;
    last_hw_opcode = 0;
  endfunction

  // 功能：把语义 work opcode 映射为硬件 SQ opcode。
  // 输入/输出及副作用：opcode 为输入，hw_opcode 为输出。
  // 失败/边界：不在 SEND/WRITE/READ/ATOMIC/LOCAL_INVALIDATE 范围内返回 UNSUPPORTED_OPCODE。
  protected function rdma_status map_opcode(
      rdma_work_opcode_e opcode,
      output bit [3:0] hw_opcode);
    case (opcode)
      RDMA_WR_SEND:             hw_opcode = RDMA_SQ_OPCODE_SEND;
      RDMA_WR_SEND_WITH_IMM:    hw_opcode = RDMA_SQ_OPCODE_SEND_WITH_IMM;
      RDMA_WR_SEND_WITH_INV:    hw_opcode = RDMA_SQ_OPCODE_SEND_WITH_INV;
      RDMA_WR_RDMA_WRITE:       hw_opcode = RDMA_SQ_OPCODE_WRITE;
      RDMA_WR_WRITE_WITH_IMM:   hw_opcode = RDMA_SQ_OPCODE_WRITE_WITH_IMM;
      RDMA_WR_RDMA_READ:        hw_opcode = RDMA_SQ_OPCODE_READ;
      RDMA_WR_ATOMIC_CMP_SWAP:  hw_opcode = RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP;
      RDMA_WR_ATOMIC_FETCH_ADD: hw_opcode = RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD;
      RDMA_WR_LOCAL_INVALIDATE: hw_opcode = RDMA_SQ_OPCODE_LOCAL_INV;
      default:
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "RC SQE opcode is unsupported");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：合成 RC writer 的候选 payload 长度（声明长度与 inline 字节数），SGE 实长随后由遍历覆盖。
  // 输入/输出及副作用：x、mode、inline_payload_bytes 只读；不扫描 SGE。
  // 失败/边界：非零 total_payload_len 保持声明值供后续一致性检查；atomic 缺省 8，NONE/SGE 缺省 0；
  //   本函数不判错、不截断。
  protected function automatic longint unsigned payload_length(
      rdma_hw_sqe_model x,
      rdma_sq_payload_mode_e mode,
      int unsigned inline_payload_bytes);
    longint unsigned value;

    value = x.total_payload_len;
    if (value != 0)
      return value;
    if (mode inside {RDMA_SQ_PAYLOAD_INLINE_WQE,
                     RDMA_SQ_PAYLOAD_INLINE_SGB})
      return inline_payload_bytes;
    if (mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED)
      return 8;
    return 0;
  endfunction

  // 功能：写 RC SQE 公共 header 字段（QPN、opcode、index、SE/FENCE/CE、VALID 等）。
  // 输入/输出及副作用：x、mode、hw_opcode 为输入，b 为写入器；SIGN_EN 恒为 1。
  // 失败/边界：任一字段 put 失败时立即返回该错误。
  protected function rdma_status put_header(
      rdma_hw_sqe_model x,
      rdma_sq_payload_mode_e mode,
      bit [3:0] hw_opcode,
      rdma_hw_qword_builder b);
    rdma_status s;
    bit [1:0] ce_value;
    bit [1:0] fence_value;
    bit se_value;
    // 驱动将 UD 和 LOCAL_INVALIDATE 的完成类型标成 TX_CE(2)，普通 RC/URC
    // signaled WQE 使用 RX_CE(1)，否则 CQ 方向会被错误路由。
    ce_value = x.signaled ? ((x.transport == RDMA_TRANSPORT_UD ||
                              x.opcode == RDMA_WR_LOCAL_INVALIDATE) ? 2'd2 : 2'd1) : 2'd0;
    fence_value = x.opcode == RDMA_WR_LOCAL_INVALIDATE ? 2'd1 :
                  (x.transport == RDMA_TRANSPORT_URC &&
                   x.opcode == RDMA_WR_SEND_WITH_INV) ? 2'd1 :
                  (x.fence != 0 ? 2'd2 : 2'd0);
    se_value = x.opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                                RDMA_WR_WRITE_WITH_IMM} ? x.se : 1'b0;
    `define RCPUT(S,V) s=put(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return s;
    `RCPUT(RDMA_SQ_WQE_QPN,x.qpn)
    `RCPUT(RDMA_SQ_WQE_ICOS,x.icos)
    `RCPUT(RDMA_SQ_WQE_QP_SN,x.qp_sn)
    `RCPUT(RDMA_SQ_WQE_OPCODE,hw_opcode)
    `RCPUT(RDMA_SQ_WQE_DST_PORT,x.dst_port)
    `RCPUT(RDMA_SQ_WQE_INDEX,x.index)
    `RCPUT(RDMA_SQ_WQE_WRAP,x.wrap)
    `RCPUT(RDMA_SQ_WQE_SIGN_EN,1'b1)
    `RCPUT(RDMA_SQ_WQE_SE,se_value)
    `RCPUT(RDMA_SQ_WQE_FENCE,fence_value)
    `RCPUT(RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD,
           mode inside {RDMA_SQ_PAYLOAD_INLINE_WQE,
                        RDMA_SQ_PAYLOAD_INLINE_SGB})
    `RCPUT(RDMA_SQ_WQE_CE,ce_value)
    `RCPUT(RDMA_SQ_WQE_VALID,x.valid)
    `undef RCPUT
    return rdma_status::success();
  endfunction

  // 功能：把一个 SGE 的 length/lkey/IOVA 写入第 slot 个 descriptor 槽位。
  // 输入/输出及副作用：b 为写入器；length=0x8000_0000 编码为 0。
  // 失败/边界：sge 为空/零长，或长度使用保留 bit31（sentinel 除外）返回 INVALID_ARGUMENT；put 失败透传。
  protected function rdma_status put_sge(
      rdma_hw_qword_builder b,
      int unsigned slot,
      rdma_sge sge);
    rdma_status s;
    bit [31:0] encoded_length;
    if (sge == null || sge.length == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQE SGE is null or empty");
    if (sge.length != 32'h8000_0000 && sge.length[31])
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQE SGE length uses reserved bit 31");
    encoded_length = sge.length == 32'h8000_0000 ? 32'h0 : sge.length;
    s = put(b, 32 + slot * 16, 32, 32, encoded_length);
    if (!s.ok()) return s;
    s = put(b, 32 + slot * 16, 0, 32, sge.lkey);
    if (!s.ok()) return s;
    return put(b, 40 + slot * 16, 0, 64, sge.iova.value);
  endfunction

  // 功能：按共享 mode/count 推导校验 RC payload shape，把 inline、direct SGE、external SGB 或
  //   atomic 固定 body 写入 builder，并生成签名所需的外部 SGB 字节与公共 header 字段。
  // 输入/输出及副作用：x 只读，b 接收字段；mode 返回最终 payload mode，signature_sgb 返回 detached
  //   外部 payload/descriptor 字节；成功更新 b，不改 x。
  // 失败/边界：opcode/mode 不相容、READ 无 SGE、长度/保留位/SGE 阈值非法、SGB IOVA 未 512B 对齐、
  //   null SGE 或 builder 写入失败时返回非 OK，不发布 image。
  protected function rdma_status body_and_header(
      rdma_hw_sqe_model x,
      rdma_hw_qword_builder b,
      output rdma_sq_payload_mode_e mode,
      output byte unsigned signature_sgb[$]);
    rdma_status s;
    longint unsigned length;
    longint unsigned sge_length;
    bit [31:0] encoded_length;
    byte unsigned raw[];
    byte unsigned resolved_inline_bytes[];
    int unsigned valid_sge_count;
    int unsigned inline_payload_bytes;
    int unsigned canonical_sge_num;
    bit inline_bytes_are_authority;
    longint unsigned canonical_sge_payload_len;

    s = rdma_status::success();
    x.derive_payload_authority(mode, valid_sge_count,
                               inline_payload_bytes,
                               inline_bytes_are_authority,
                               canonical_sge_num);
    signature_sgb.delete();
    if (x.opcode == RDMA_WR_LOCAL_INVALIDATE &&
        mode != RDMA_SQ_PAYLOAD_NONE)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "local invalidate uses a payload mode");
    if (x.opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                         RDMA_WR_ATOMIC_FETCH_ADD}) begin
      if (mode != RDMA_SQ_PAYLOAD_ATOMIC_FIXED)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic opcode uses a non-atomic payload mode");
    end else if (mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED) begin
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "non-atomic opcode uses atomic payload mode");
    end
    if (mode == RDMA_SQ_PAYLOAD_NONE &&
        x.opcode == RDMA_WR_RDMA_READ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RDMA read requires a destination SGE");
    if (x.opcode == RDMA_WR_RDMA_READ &&
        !(mode inside {RDMA_SQ_PAYLOAD_SGE_WQE,
                       RDMA_SQ_PAYLOAD_SGE_SGB}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RDMA read requires an SGE payload mode");

    length = payload_length(x, mode, inline_payload_bytes);
    if (mode inside {RDMA_SQ_PAYLOAD_SGE_WQE,
                     RDMA_SQ_PAYLOAD_SGE_SGB}) begin
      s = rdma_sge_authority::derive_send(
          x.sges, valid_sge_count, canonical_sge_payload_len);
      if (!s.ok())
        return s;
      sge_length = canonical_sge_payload_len;
      if (x.total_payload_len != 0 && x.total_payload_len != sge_length)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC total payload length does not match SGEs");
      length = sge_length;
    end
    if (length > 64'h8000_0000)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RC payload length exceeds 2 GiB");
    if (mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED) begin
      if (x.total_payload_len != 0 && x.total_payload_len != 8)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic RC payload length is not eight bytes");
      length = 8;
    end
    if (mode == RDMA_SQ_PAYLOAD_NONE && x.total_payload_len != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "empty RC payload mode has nonzero length");
    encoded_length = length == 64'h8000_0000 ? 32'h0 : length[31:0];
    if (mode inside {RDMA_SQ_PAYLOAD_INLINE_WQE,
                     RDMA_SQ_PAYLOAD_INLINE_SGB}) begin
      s = x.resolve_inline_payload_authority(resolved_inline_bytes);
      if (s == null || !s.ok())
        return s == null ?
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "RC inline payload authority returned null status") :
          s;
      raw = new[resolved_inline_bytes.size()];
      foreach (resolved_inline_bytes[i])
        raw[i] = resolved_inline_bytes[i];
      if (raw.size() != length)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC inline payload length is inconsistent");
      if (mode == RDMA_SQ_PAYLOAD_INLINE_WQE && raw.size() > 32)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC inline WQE payload exceeds 32 bytes");
      if (mode == RDMA_SQ_PAYLOAD_INLINE_SGB && raw.size() <= 32)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC inline SGB payload is too short");
      if (mode == RDMA_SQ_PAYLOAD_INLINE_SGB && raw.size() > 512)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC inline SGB payload exceeds 512 bytes");
      if (mode == RDMA_SQ_PAYLOAD_INLINE_WQE) begin
        // 零字节 IB_SEND_INLINE 是合法形态；builder 已清零，须跳过空 memcpy（helper 会拒绝空源）。
        if (raw.size() != 0) begin
          s = b.put_memcpy(32, raw);
          if (!s.ok()) return err(s.message);
        end
      end else begin
        if ((x.sgb_iova.value & 64'h1ff) != 0 || x.sgb_iova.value == 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "RC inline SGB IOVA is not 512-byte aligned");
        s = put(b, RDMA_SQ_WQE_SGB_PA_WORD_BYTE_OFFSET,
                RDMA_SQ_WQE_SGB_PA_LSB, RDMA_SQ_WQE_SGB_PA_WIDTH,
                x.sgb_iova.value >> 9);
        if (!s.ok()) return s;
        foreach (raw[i]) signature_sgb.push_back(raw[i]);
        while (signature_sgb.size() < 512) signature_sgb.push_back(0);
      end
    end else if (mode inside {RDMA_SQ_PAYLOAD_SGE_WQE,
                              RDMA_SQ_PAYLOAD_SGE_SGB}) begin
      if (canonical_sge_num == 0 || canonical_sge_num > 32)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC SGE count is outside 1..32");
      if (mode == RDMA_SQ_PAYLOAD_SGE_WQE && canonical_sge_num > 2)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "direct RC SGE count exceeds two");
      if (mode == RDMA_SQ_PAYLOAD_SGE_SGB && canonical_sge_num < 3)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC SGB SGE count is below three");
      if (mode == RDMA_SQ_PAYLOAD_SGE_SGB) begin
        if ((x.sgb_iova.value & 64'h1ff) != 0 || x.sgb_iova.value == 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "RC SGE SGB IOVA is not 512-byte aligned");
        s = put(b, RDMA_SQ_WQE_SGB_PA_WORD_BYTE_OFFSET,
                RDMA_SQ_WQE_SGB_PA_LSB, RDMA_SQ_WQE_SGB_PA_WIDTH,
                x.sgb_iova.value >> 9);
        if (!s.ok()) return s;
        // SGE-SGB 的 descriptor 以 16B 大端存放在外部 512B SGB 中；不属于 64B WQE，但被 WQE 签名覆盖。
        foreach (x.sges[i]) begin
          bit [31:0] descriptor_length;
          bit [31:0] descriptor_lkey;
          bit [63:0] descriptor_iova;
          if (x.sges[i] == null)
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "RC SGE SGB contains a null SGE");
          if (x.sges[i].length == 0)
            continue;
          descriptor_length = x.sges[i].length == 32'h8000_0000 ?
                              32'h0000_0000 : x.sges[i].length;
          descriptor_lkey = x.sges[i].lkey;
          descriptor_iova = x.sges[i].iova.value;
          for (int unsigned byte_index = 0; byte_index < 4; byte_index++)
            signature_sgb.push_back(
                descriptor_length[31 - byte_index * 8 -: 8]);
          for (int unsigned byte_index = 0; byte_index < 4; byte_index++)
            signature_sgb.push_back(
                descriptor_lkey[31 - byte_index * 8 -: 8]);
          for (int unsigned byte_index = 0; byte_index < 8; byte_index++)
            signature_sgb.push_back(
                descriptor_iova[63 - byte_index * 8 -: 8]);
        end
        while (signature_sgb.size() < 512) signature_sgb.push_back(0);
      end else begin
        int unsigned slot;

        slot = 0;
        foreach (x.sges[i]) begin
          if (x.sges[i] == null)
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "RC direct SGE contains a null SGE");
          if (x.sges[i].length == 0)
            continue;
          s = put_sge(b, slot, x.sges[i]);
          if (!s.ok()) return s;
          slot++;
        end
      end
    end else if (mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED) begin
      rdma_sge local_sge;
      if (!(x.opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                             RDMA_WR_ATOMIC_FETCH_ADD}))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic payload mode used by non-atomic opcode");
      if (x.sges.size() != 1)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic RC SQE requires one SGE");
      local_sge = x.sges[0];
      if (local_sge == null || local_sge.length != 8 ||
          (local_sge.iova.value & 64'h7) != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic RC SQE local SGE is invalid");
      s = put(b, RDMA_SQ_WQE_ATOMIC_L_LEN_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_ATOMIC_L_LEN_LSB,
              RDMA_SQ_WQE_ATOMIC_L_LEN_WIDTH, 8); if (!s.ok()) return s;
      s = put(b, RDMA_SQ_WQE_ATOMIC_L_KEY_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_ATOMIC_L_KEY_LSB,
              RDMA_SQ_WQE_ATOMIC_L_KEY_WIDTH,
              local_sge.lkey);
      if (!s.ok()) return s;
      if ((x.atomic_local_iova.value & 64'h7) != 0 ||
          x.atomic_local_iova.value == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic local IOVA is not 8-byte aligned");
      s = put(b, RDMA_SQ_WQE_ATOMIC_L_VA_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_ATOMIC_L_VA_LSB,
              RDMA_SQ_WQE_ATOMIC_L_VA_WIDTH, x.atomic_local_iova.value);
      if (!s.ok()) return s;
      s = put(b, RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA_LSB,
              RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA_WIDTH, x.atomic_value);
      if (!s.ok()) return s;
      if (x.opcode == RDMA_WR_ATOMIC_CMP_SWAP)
        s = put(b, RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA_WORD_BYTE_OFFSET,
                RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA_LSB,
                RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA_WIDTH, x.atomic_compare);
      if (!s.ok()) return s;
    end
    if (x.opcode == RDMA_WR_LOCAL_INVALIDATE)
      s = put(b, RDMA_SQ_WQE_LOCAL_INVLD_STAG_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_LOCAL_INVLD_STAG_LSB,
              RDMA_SQ_WQE_LOCAL_INVLD_STAG_WIDTH, x.invalidate_key);
    else if (x.opcode == RDMA_WR_SEND_WITH_INV)
      s = put(b, RDMA_SQ_WQE_RC_IMMEDIATE_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_RC_IMMEDIATE_LSB,
              RDMA_SQ_WQE_RC_IMMEDIATE_WIDTH, x.invalidate_key);
    else if (x.opcode inside {RDMA_WR_SEND_WITH_IMM,
                              RDMA_WR_WRITE_WITH_IMM})
      s = put(b, RDMA_SQ_WQE_RC_IMMEDIATE_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_RC_IMMEDIATE_LSB,
              RDMA_SQ_WQE_RC_IMMEDIATE_WIDTH, x.immediate_data);
    else if (x.immediate_data != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RC immediate data is invalid for opcode");
    if (!s.ok()) return s;
    s = put(b, RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN_LSB,
            RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN_WIDTH, encoded_length);
    if (!s.ok()) return s;
    s = put(b, RDMA_SQ_WQE_RC_SGE_NUM_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_RC_SGE_NUM_LSB,
            RDMA_SQ_WQE_RC_SGE_NUM_WIDTH,
            canonical_sge_num);
    if (!s.ok()) return s;
    // RC 的 remote-key/remote-VA 与 UD 的 AV/DMAC 使用同一物理 qword，
    // UD 路径必须跳过 RC 字段写入，否则即使值为零也会触发 builder overlap。
    if (x.transport != RDMA_TRANSPORT_UD) begin
      s = put(b, RDMA_SQ_WQE_RC_REMOTE_KEY_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_RC_REMOTE_KEY_LSB,
              RDMA_SQ_WQE_RC_REMOTE_KEY_WIDTH,
              (x.opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                                RDMA_WR_RDMA_READ,
                                RDMA_WR_ATOMIC_CMP_SWAP,
                                RDMA_WR_ATOMIC_FETCH_ADD}) ? x.rkey : 0);
      if (!s.ok()) return s;
      s = put(b, RDMA_SQ_WQE_RC_REMOTE_VA_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_RC_REMOTE_VA_LSB,
              RDMA_SQ_WQE_RC_REMOTE_VA_WIDTH,
              (x.opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                                RDMA_WR_RDMA_READ,
                                RDMA_WR_ATOMIC_CMP_SWAP,
                                RDMA_WR_ATOMIC_FETCH_ADD}) ? x.remote_va.value : 0);
      if (!s.ok()) return s;
    end
    return put_header(x, mode, last_hw_opcode, b);
  endfunction

  // 功能：由 URC 子 codec 声明 raw image 的 qword5[63:40] 是否属于 TOTAL_PKT_NUM 字段。
  // 输入/输出及副作用：raw_mode、raw_opcode 来自本次 check_reserved 解析；只返回授权 bit。
  // 失败/边界：基类一律拒绝，不使用此前 encode 遗留的状态授权。
  protected virtual function bit allow_urc_read_total_packet_num(
      rdma_sq_payload_mode_e raw_mode,
      bit [3:0] raw_opcode);
    return 1'b0;
  endfunction

  // 功能：校验 RC SQE 的 header/body 保留位及 mode/长度几何。
  // 输入/输出及副作用：从 b 的 header 取 opcode、INLINE_LOCAL_QPC_RD、SGE_NUM 与 payload length，
  //   计算字段所有权；不改 b。
  // 失败/边界：不依赖 last_hw_opcode/last_mode（fresh 与复用的 codec 结果一致）；qword 数不为 8、
  //   opcode 未列入驱动 ABI、保留位非零或 mode/长度几何不符返回 CODEC_ERROR。
  protected virtual function rdma_status check_reserved(
      rdma_hw_qword_builder b);
    bit [63:0] w[];
    bit [63:0] allowed;
    byte unsigned raw[];
    rdma_status s;
    bit [3:0] raw_opcode;
    bit raw_remote_address;
    rdma_sq_payload_mode_e raw_mode;
    int unsigned count;
    int unsigned length;
    b.get_words(w);
    if (w.size() != 8)
      return err("RC SQE does not contain eight qwords");
    if (w[0][56] !== 1'b1)
      return err("SQE SIGN_EN is fixed to one by driver ABI");
    raw_opcode = w[0][35:32];
    if (!(raw_opcode inside {
        RDMA_SQ_OPCODE_SEND,
        RDMA_SQ_OPCODE_SEND_WITH_IMM,
        RDMA_SQ_OPCODE_SEND_WITH_INV,
        RDMA_SQ_OPCODE_WRITE,
        RDMA_SQ_OPCODE_WRITE_WITH_IMM,
        RDMA_SQ_OPCODE_READ,
        RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP,
        RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD,
        RDMA_SQ_OPCODE_LOCAL_INV}))
      return err("RC SQE hardware opcode is unknown");

    count = w[2][55:48];
    length = w[1][31:0];
    if (raw_opcode == RDMA_SQ_OPCODE_LOCAL_INV)
      raw_mode = RDMA_SQ_PAYLOAD_NONE;
    else if (raw_opcode inside {RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP,
                                RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD})
      raw_mode = RDMA_SQ_PAYLOAD_ATOMIC_FIXED;
    else if (w[0][60])
      raw_mode = length <= 32 ? RDMA_SQ_PAYLOAD_INLINE_WQE :
                 RDMA_SQ_PAYLOAD_INLINE_SGB;
    else if (count == 0)
      raw_mode = RDMA_SQ_PAYLOAD_NONE;
    else
      raw_mode = count <= 2 ? RDMA_SQ_PAYLOAD_SGE_WQE :
                 RDMA_SQ_PAYLOAD_SGE_SGB;

    raw_remote_address = raw_opcode inside {
      RDMA_SQ_OPCODE_WRITE,
      RDMA_SQ_OPCODE_WRITE_WITH_IMM,
      RDMA_SQ_OPCODE_READ
    };

    allowed = raw_mode inside {RDMA_SQ_PAYLOAD_INLINE_WQE,
                               RDMA_SQ_PAYLOAD_INLINE_SGB} ?
              64'hffff_ffff_ffff_ffff : 64'hefff_ffff_ffff_ffff;
    if (!rdma_raw_qword_mask_is_valid(w[0], allowed))
      return err("RC SQE header reserved bits are nonzero");
    foreach (w[q]) begin
      if (q == 0)
        continue;
      allowed = 0;
      case (raw_mode)
        RDMA_SQ_PAYLOAD_INLINE_WQE,
        RDMA_SQ_PAYLOAD_SGE_WQE: begin
          case (q)
            1: begin
              allowed = 64'h0000_0000_ffff_ffff;
              if (raw_opcode inside {RDMA_SQ_OPCODE_SEND_WITH_IMM,
                                     RDMA_SQ_OPCODE_SEND_WITH_INV,
                                     RDMA_SQ_OPCODE_WRITE_WITH_IMM,
                                     RDMA_SQ_OPCODE_LOCAL_INV})
                allowed |= 64'hffff_ffff_0000_0000;
            end
            2: begin
              allowed = 64'hffff_0000_0000_0000;
              if (raw_remote_address)
                allowed |= 64'h0000_0000_ffff_ffff;
            end
            3: allowed = raw_remote_address ?
                         64'hffff_ffff_ffff_ffff : 64'h0;
            4, 6: begin
              // wr.h 中直接 SGE 长度为 GENMASK(30,0)；长度的 bit31 即 qword bit63，仍是保留位。
              allowed = raw_mode == RDMA_SQ_PAYLOAD_SGE_WQE ?
                        64'h7fff_ffff_ffff_ffff :
                        64'hffff_ffff_ffff_ffff;
            end
            5, 7: allowed = 64'hffff_ffff_ffff_ffff;
            default: allowed = 0;
          endcase
        end
        RDMA_SQ_PAYLOAD_INLINE_SGB,
        RDMA_SQ_PAYLOAD_SGE_SGB: begin
          case (q)
            1: begin
              allowed = 64'h0000_0000_ffff_ffff;
              if (raw_opcode inside {RDMA_SQ_OPCODE_SEND_WITH_IMM,
                                     RDMA_SQ_OPCODE_SEND_WITH_INV,
                                     RDMA_SQ_OPCODE_WRITE_WITH_IMM,
                                     RDMA_SQ_OPCODE_LOCAL_INV})
                allowed |= 64'hffff_ffff_0000_0000;
            end
            2: begin
              allowed = 64'hffff_0000_0000_0000;
              if (raw_remote_address)
                allowed |= 64'h0000_0000_ffff_ffff;
            end
            3: allowed = raw_remote_address ?
                         64'hffff_ffff_ffff_ffff : 64'h0;
            4: allowed = 64'hffff_ffff_ffff_fe00;
            default: allowed = 0;
          endcase
          if (q == 5 && raw_mode == RDMA_SQ_PAYLOAD_SGE_SGB &&
              raw_opcode == RDMA_SQ_OPCODE_READ &&
              allow_urc_read_total_packet_num(raw_mode, raw_opcode))
            allowed = 64'hffff_ff00_0000_0000;
        end
        RDMA_SQ_PAYLOAD_ATOMIC_FIXED: begin
          case (q)
            1: allowed = 64'h0000_0000_ffff_ffff;
            2: allowed = 64'hffff_0000_ffff_ffff;
            3, 4, 5, 6: allowed = 64'hffff_ffff_ffff_ffff;
            7: allowed = raw_opcode == RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP ?
                         64'hffff_ffff_ffff_ffff : 64'h0;
            default: allowed = 0;
          endcase
        end
        RDMA_SQ_PAYLOAD_NONE: begin
          case (q)
            1: begin
              allowed = 64'h0000_0000_ffff_ffff;
              if (raw_opcode inside {RDMA_SQ_OPCODE_SEND_WITH_IMM,
                                     RDMA_SQ_OPCODE_SEND_WITH_INV,
                                     RDMA_SQ_OPCODE_WRITE_WITH_IMM,
                                     RDMA_SQ_OPCODE_LOCAL_INV})
                allowed |= 64'hffff_ffff_0000_0000;
            end
            2: allowed = 64'hff00_0000_0000_0000;
            default: allowed = 0;
          endcase
        end
        default: return err("RC SQE payload mode is invalid");
      endcase
      if (!rdma_raw_qword_mask_is_valid(w[q], allowed))
        return err($sformatf("RC SQE qword %0d reserved bits are nonzero", q));
    end

    if (raw_mode == RDMA_SQ_PAYLOAD_INLINE_WQE) begin
      if (length > 32 || count != ((length + 15) / 16))
        return err("RC inline WQE length or chunk count is invalid");
      s = b.serialize(raw);
      if (!s.ok()) return err(s.message);
      for (int unsigned i = 32 + length; i < RDMA_WQE_BYTES; i++)
        if (raw[i] !== 8'h00)
          return err("RC inline WQE unused tail is nonzero");
    end else if (raw_mode == RDMA_SQ_PAYLOAD_INLINE_SGB) begin
      // xtrdma_hw.h/wr.c 固定一个 SQ-SGB slot 为 512B、inline 以 16B chunk 编码：32B 以内必须留在 WQE，
      // 超过 512B 或 32 个 chunk 的 raw image 不能仅因 TPL/SGE_NUM 位宽够用而接受。
      // 先检查真实 slot 容量，再检查 count 与长度的几何关系。
      if (length > RDMA_MAX_WQ_SGE * 16 || count > RDMA_MAX_WQ_SGE)
        return err("RC inline SGB exceeds the fixed 512-byte/32-chunk capacity");
      if (length <= 32 || count != ((length + 15) / 16))
        return err("RC inline SGB length or chunk count is invalid");
    end else if (raw_mode == RDMA_SQ_PAYLOAD_SGE_WQE) begin
      if (count == 0 || count > 2)
        return err("RC direct SGE count is invalid");
      for (int unsigned q = 4 + count * 2; q < 8; q++)
        if (w[q] !== 64'b0)
          return err("RC direct SGE unused tail is nonzero");
    end else if (raw_mode == RDMA_SQ_PAYLOAD_SGE_SGB) begin
      if (count < 3 || count > 32)
        return err("RC SGB SGE count is invalid");
    end else if (raw_mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED) begin
      // wr.h/wr.c 把 atomic 的两处长度都固定为 8 字节（公共 total payload 与 qword4[63:32] 本地 SGE 长度）。
      // 须在 decode_fields 合成语义 SGE 前校验 raw 字段，避免掩盖畸形 wire 值。
      if (count != 1 ||
          w[1][31:0] !== 32'd8 ||
          w[4][63:32] !== 32'd8)
        return err("RC atomic length or SGE count is invalid");
    end else if (raw_mode == RDMA_SQ_PAYLOAD_NONE) begin
      // wr.c 在 payload 长度为 0 时以 num_sge==0 发布 SEND/WRITE；READ 与 atomic 已在上面归入各自 mode。
      if (raw_opcode == RDMA_SQ_OPCODE_READ ||
          raw_opcode inside {RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP,
                             RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD} ||
          count != 0 || w[1][31:0] != 0)
        return err("RC empty body opcode or length is invalid");
    end
    return rdma_status::success();
  endfunction

  // 功能：探测 raw WQE 以更新 last_hw_opcode/last_mode，再做基类校验与签名检查。
  // 输入/输出及副作用：image 只读；副作用是更新 last_hw_opcode/last_mode。
  // 失败/边界：基类校验失败原样返回；mode 不依赖外部 SGB 时签名不符返回 CODEC_ERROR。
  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_hw_qword_builder b;
    bit [63:0] w[];
    byte unsigned raw[];
    rdma_status s;
    b = new("rc_image_probe");
    if (image != null && image.bytes.size() == RDMA_WQE_BYTES) begin
      raw = new[RDMA_WQE_BYTES];
      foreach (raw[i]) raw[i] = image.bytes[i];
      s = b.deserialize(raw);
      if (s.ok()) begin
        b.get_words(w);
        last_hw_opcode = w[0][35:32];
        if (last_hw_opcode inside {RDMA_SQ_OPCODE_LOCAL_INV,
                                   RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP,
                                   RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD})
          last_mode = last_hw_opcode == RDMA_SQ_OPCODE_LOCAL_INV ?
                      RDMA_SQ_PAYLOAD_NONE : RDMA_SQ_PAYLOAD_ATOMIC_FIXED;
        else if (w[0][60])
          last_mode = w[1][31:0] <= 32 ? RDMA_SQ_PAYLOAD_INLINE_WQE :
                                         RDMA_SQ_PAYLOAD_INLINE_SGB;
        else if (w[2][55:48] == 0)
          // SGE count 为 0 是驱动合法的零 payload 形态，不能归为 count 从 1 起的 direct-SGE。
          last_mode = RDMA_SQ_PAYLOAD_NONE;
        else
          last_mode = w[2][55:48] <= 2 ? RDMA_SQ_PAYLOAD_SGE_WQE :
                                         RDMA_SQ_PAYLOAD_SGE_SGB;
      end
    end
    s = super.validate_image(image);
    if (!s.ok())
      return s;
    // 仅凭 image 无法认证 SGB 内的 payload（512B slot 不在 rdma_hw_image 中）；
    // 持有该 slot 的调用方须在结构校验通过后用 validate_sq_signature 校验。
    if (!(last_mode inside {RDMA_SQ_PAYLOAD_INLINE_SGB,
                            RDMA_SQ_PAYLOAD_SGE_SGB})) begin
      byte unsigned no_sgb[$];
      bit signature_valid;
      s = validate_sq_signature(image, no_sgb, signature_valid);
      if (!s.ok()) return s;
      if (!signature_valid)
        return err("RC SQE signature is invalid");
    end
    return rdma_status::success();
  endfunction

  // 功能：在 detached SQE candidate 上投影 RC extension，再编码 body/header/signature，
  //   使 wire 有效的 remote 字段不回写 caller model。
  // 输入/输出及副作用：model 只读，b 为待提交 builder；成功更新 b 与 last_*；opcode 映射成功后即使
  //   后续 body 被拒绝，last_hw_opcode 也可能已更新。源 model 不变。
  // 失败/边界：类型/clone/extension/opcode 失败、payload 几何非法或 builder 写入失败返回非 OK，
  //   candidate 与局部 builder 丢弃，不发布 image。
  protected virtual function rdma_status encode_fields(
      rdma_hw_model model,
      rdma_hw_qword_builder b);
    rdma_hw_sqe_model source;
    rdma_hw_sqe_model candidate;
    rdma_sqe_rc_ext ext;
    rdma_status s;
    rdma_sq_payload_mode_e mode;
    byte unsigned signature_sgb[$];
    byte unsigned serialized[];
    bit [7:0] signature;
    bit [3:0] hw_opcode;

    if (!$cast(source, model))
      return err("RC SQE model type mismatch");
    if (!rdma_deep_copy#(rdma_hw_sqe_model)::try_of(source, candidate))
      return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "RC SQE detached candidate allocation failed");
    if (candidate.transport != RDMA_TRANSPORT_RC)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RC codec received a non-RC SQE");
    s = map_opcode(candidate.opcode, hw_opcode);
    if (!s.ok())
      return s;
    if (candidate.transport_ext != null) begin
      if (!$cast(ext, candidate.transport_ext))
        return err("RC extension type mismatch");
      s = ext.validate(candidate.opcode);
      if (!s.ok())
        return s;
      if (ext.rkey_valid)
        candidate.rkey = ext.rkey;
      if (ext.remote_access_valid)
        candidate.remote_va = ext.remote_addr;
      if (candidate.opcode == RDMA_WR_LOCAL_INVALIDATE && ext.rkey_valid)
        candidate.invalidate_key = ext.rkey;
    end
    last_hw_opcode = hw_opcode;
    s = body_and_header(candidate, b, mode, signature_sgb);
    if (!s.ok())
      return s;
    last_mode = mode;
    s = b.serialize(serialized); if (!s.ok()) return err(s.message);
    signature = ~8'h00;
    foreach (serialized[i]) if (i != 16) signature ^= serialized[i];
    foreach (signature_sgb[i]) signature ^= signature_sgb[i];
    s = put(b, RDMA_SQ_WQE_SIGNATURE_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_SIGNATURE_LSB,
            RDMA_SQ_WQE_SIGNATURE_WIDTH, signature);
    return s;
  endfunction

  // 功能：把通过结构校验的 RC SQE 解码为 detached 模型。
  // 输入/输出及副作用：b 只读，model 输出；成功发布新 SQE、RC extension、投影 QP handle 与 direct
  //   descriptor。ordinary opcode 先按 raw INLINE_LOCAL_QPC_RD 判 inline，再以非 inline count=0 判 NONE，
  //   并恢复 inline_data/inline_bytes，使零字节 inline 可原样重编码。
  // 失败/边界：字段读取失败不发布 model；external-SGB raw image 只恢复 SGB 指针/count，
  //   没有 512B 字节就不伪造 payload，需 payload/signature authority 的调用方须另行提供 backing。
  protected virtual function rdma_status decode_fields(
      rdma_hw_qword_builder b,
      output rdma_hw_model model);
    rdma_hw_sqe_model x;
    rdma_sqe_rc_ext ext;
    bit [63:0] v;
    bit [63:0] words[];
    byte unsigned p[];
    rdma_status s;
    int unsigned count;
    x = rdma_hw_sqe_model::type_id::create("decoded_rc_sqe");
    x.transport = RDMA_TRANSPORT_RC;
    x.qp_h = rdma_hw_queue_projected_handle("decoded_qp", RDMA_RESOURCE_QP, 0);
    ext = rdma_sqe_rc_ext::type_id::create("decoded_rc_ext");
    x.transport_ext = ext;
    `define RCGET(S,T) v='0; s=get(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return s; T=v;
    `RCGET(RDMA_SQ_WQE_QPN,x.qpn) `RCGET(RDMA_SQ_WQE_ICOS,x.icos)
    `RCGET(RDMA_SQ_WQE_QP_SN,x.qp_sn) `RCGET(RDMA_SQ_WQE_OPCODE,x.hw_opcode)
    `RCGET(RDMA_SQ_WQE_DST_PORT,x.dst_port) `RCGET(RDMA_SQ_WQE_INDEX,x.index)
    `RCGET(RDMA_SQ_WQE_WRAP,x.wrap) `RCGET(RDMA_SQ_WQE_SIGN_EN,x.sign_en)
    `RCGET(RDMA_SQ_WQE_SE,x.se) `RCGET(RDMA_SQ_WQE_FENCE,x.fence)
    `RCGET(RDMA_SQ_WQE_CE,x.ce) `RCGET(RDMA_SQ_WQE_VALID,x.valid)
    `RCGET(RDMA_SQ_WQE_SIGNATURE,x.signature) `RCGET(RDMA_SQ_WQE_RC_SGE_NUM,x.sge_num)
    `RCGET(RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN,x.total_payload_len)
    `RCGET(RDMA_SQ_WQE_RC_IMMEDIATE,x.immediate_data)
    `RCGET(RDMA_SQ_WQE_RC_REMOTE_KEY,x.rkey)
    `RCGET(RDMA_SQ_WQE_RC_REMOTE_VA,x.remote_va.value) `undef RCGET
    x.sign_en = 1'b1;
    x.signaled = x.ce != 0;
    x.solicited = x.se;
    count = x.sge_num;
    if (x.hw_opcode == RDMA_SQ_OPCODE_LOCAL_INV) begin
      x.opcode = RDMA_WR_LOCAL_INVALIDATE;
      x.payload_mode = RDMA_SQ_PAYLOAD_NONE;
      s = get(b, RDMA_SQ_WQE_LOCAL_INVLD_STAG_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_LOCAL_INVLD_STAG_LSB,
              RDMA_SQ_WQE_LOCAL_INVLD_STAG_WIDTH, v);
      if (!s.ok()) return s; x.invalidate_key = v;
      ext.rkey = x.invalidate_key;
      ext.rkey_valid = 1'b1;
    end else if (x.hw_opcode == RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP ||
                 x.hw_opcode == RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD) begin
      x.opcode = x.hw_opcode == RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP ?
                 RDMA_WR_ATOMIC_CMP_SWAP : RDMA_WR_ATOMIC_FETCH_ADD;
      x.payload_mode = RDMA_SQ_PAYLOAD_ATOMIC_FIXED;
      s = get(b, RDMA_SQ_WQE_ATOMIC_L_VA_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_ATOMIC_L_VA_LSB,
              RDMA_SQ_WQE_ATOMIC_L_VA_WIDTH, v); if(!s.ok()) return s;
      x.atomic_local_iova.value = v;
      s = get(b, RDMA_SQ_WQE_ATOMIC_L_KEY_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_ATOMIC_L_KEY_LSB,
              RDMA_SQ_WQE_ATOMIC_L_KEY_WIDTH, v); if(!s.ok()) return s;
      x.atomic_local_lkey = v;
      begin
        rdma_sge local_sge;
        local_sge = rdma_sge::type_id::create("decoded_atomic_sge");
        local_sge.length = 8;
        local_sge.lkey = x.atomic_local_lkey;
        local_sge.iova.value = x.atomic_local_iova.value;
        x.sges.push_back(local_sge);
      end
      s = get(b, RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA_LSB,
              RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA_WIDTH, v); if(!s.ok()) return s;
      x.atomic_value = v;
      s = get(b, RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA_LSB,
              RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA_WIDTH, v); if(!s.ok()) return s;
      x.atomic_compare = v;
      ext.remote_access_valid = 1'b1;
      ext.rkey_valid = 1'b1;
      ext.remote_addr = x.remote_va;
      ext.rkey = x.rkey;
    end else begin
      case (x.hw_opcode)
        RDMA_SQ_OPCODE_SEND: x.opcode = RDMA_WR_SEND;
        RDMA_SQ_OPCODE_SEND_WITH_IMM: x.opcode = RDMA_WR_SEND_WITH_IMM;
        // opcode 3 为 SEND_WITH_INV；qword1[63:32] 是 invalidate_rkey 别名，须在 detached round-trip 中保留。
        RDMA_SQ_OPCODE_SEND_WITH_INV: begin
          x.opcode = RDMA_WR_SEND_WITH_INV;
          x.invalidate_key = x.immediate_data;
        end
        RDMA_SQ_OPCODE_WRITE: x.opcode = RDMA_WR_RDMA_WRITE;
        RDMA_SQ_OPCODE_WRITE_WITH_IMM: x.opcode = RDMA_WR_WRITE_WITH_IMM;
        RDMA_SQ_OPCODE_READ: x.opcode = RDMA_WR_RDMA_READ;
        default: x.opcode = RDMA_WR_SEND;
      endcase
      if (x.opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                           RDMA_WR_RDMA_READ}) begin
        ext.remote_access_valid = 1'b1;
        ext.rkey_valid = 1'b1;
        ext.remote_addr = x.remote_va;
        ext.rkey = x.rkey;
      end
      b.get_words(words);
      // INLINE_LOCAL_QPC_RD 是 ordinary opcode 的首要 raw mode authority：即使 TPL/count 为零也保留
      // inline 语义以便 byte-exact 重编码；非 inline 时 count==0 为 NONE，其余按 direct/external 阈值解析。
      if (words[0][60])
        x.payload_mode = x.total_payload_len <= 32 ?
                         RDMA_SQ_PAYLOAD_INLINE_WQE :
                         RDMA_SQ_PAYLOAD_INLINE_SGB;
      else if (count == 0)
        x.payload_mode = RDMA_SQ_PAYLOAD_NONE;
      else
        x.payload_mode = count <= 2 ? RDMA_SQ_PAYLOAD_SGE_WQE :
                                      RDMA_SQ_PAYLOAD_SGE_SGB;
      x.inline_data = x.payload_mode inside {
          RDMA_SQ_PAYLOAD_INLINE_WQE,
          RDMA_SQ_PAYLOAD_INLINE_SGB
      };
      if (x.payload_mode inside {RDMA_SQ_PAYLOAD_INLINE_SGB,
                                 RDMA_SQ_PAYLOAD_SGE_SGB}) begin
        s = get(b, RDMA_SQ_WQE_SGB_PA_WORD_BYTE_OFFSET,
                RDMA_SQ_WQE_SGB_PA_LSB,
                RDMA_SQ_WQE_SGB_PA_WIDTH, v);
        if (!s.ok()) return s;
        x.sgb_iova.value = v << 9;
      end
      if (x.payload_mode == RDMA_SQ_PAYLOAD_INLINE_WQE) begin
        s = b.serialize(p); if (!s.ok()) return err(s.message);
        x.inline_bytes = new[x.total_payload_len <= 32 ? x.total_payload_len : 0];
        foreach (x.inline_bytes[i]) x.inline_bytes[i] = p[32+i];
      end else if (x.payload_mode == RDMA_SQ_PAYLOAD_SGE_WQE) begin
        for (int unsigned i=0; i<count; i++) begin
          rdma_sge sg;
          sg = rdma_sge::type_id::create($sformatf("decoded_sge%0d",i));
          // 驱动只持有 SGE length[30:0]；bit31 已被 check_reserved 拒绝，raw decode 不投影到语义模型。
          s = get(b, 32+i*16, 32, 31, v);
          if (!s.ok())
            return s;
          sg.length = v[30:0] == 31'b0 ? 32'h8000_0000 : v[30:0];
          s = get(b, 32+i*16, 0, 32, v); if(!s.ok()) return s; sg.lkey=v;
          s = get(b, 40+i*16, 0, 64, v); if(!s.ok()) return s; sg.iova.value=v;
          x.sges.push_back(sg);
        end
      end
    end
    model = x;
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_sqe_ud_codec extends rdma_hw_sqe_rc_codec;
  `rdma_object_utils(rdma_hw_sqe_ud_codec)
  // 功能：构造 UD SQE codec。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_sqe_ud_codec");
    super.new(name);
  endfunction

  // 功能：校验 UD SQE 的 header、AH 元数据和 64B 固定几何。
  // 输入/输出及副作用：从 b 的 header 取 opcode 与 INLINE_LOCAL_QPC_RD，计算 qword0/1 字段所有权；不改 b。
  // 失败/边界：qword 数不为 8、SIGN_EN 为零、opcode 未定义、header 保留位或未定义 body 位非零时拒绝；
  //   不依赖上一次 encode 的 last_*。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b);
    bit [63:0] w[];
    bit [63:0] allowed_payload;
    bit [63:0] allowed_header;
    bit [3:0] raw_opcode;
    b.get_words(w);
    if (w.size() != 8)
      return err("UD SQE does not contain eight qwords");

    raw_opcode = w[0][35:32];
    if (!(raw_opcode inside {
        RDMA_SQ_OPCODE_SEND,
        RDMA_SQ_OPCODE_SEND_WITH_IMM,
        RDMA_SQ_OPCODE_SEND_WITH_INV,
        RDMA_SQ_OPCODE_WRITE,
        RDMA_SQ_OPCODE_WRITE_WITH_IMM,
        RDMA_SQ_OPCODE_READ,
        RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP,
        RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD,
        RDMA_SQ_OPCODE_LOCAL_INV}))
      return err("UD SQE hardware opcode is unknown");

    // offset=8 的 qword 由 payload length、vport、FWD/LAG/tunnel/IPv6/VLAN 及（按 opcode）立即数覆盖，
    // 仅 bit25 保留；offset=16 的 qword 由 signature、SGE_NUM、DMAC 完整覆盖。
    allowed_payload = 64'h0000_0000_fdff_ffff;
    if (raw_opcode inside {RDMA_SQ_OPCODE_SEND_WITH_IMM,
                           RDMA_SQ_OPCODE_SEND_WITH_INV})
      allowed_payload |= 64'hffff_ffff_0000_0000;
    // wr.c 经 xtrdma_get_inline_local_qpc_rd_flag() 对所有 IB_SEND_INLINE（含走 SGB 与零字节形态）
    // 置该位：它随 payload mode，而非字节的存放位置。
    allowed_header = w[0][60] ? 64'hffff_ffff_ffff_ffff :
                     64'hefff_ffff_ffff_ffff;
    if (w[0][56] !== 1'b1 ||
        !rdma_raw_qword_mask_is_valid(
          w[0], allowed_header) ||
        !rdma_raw_qword_mask_is_valid(w[1], allowed_payload))
      return err("UD SQE reserved bits are nonzero");
    return rdma_status::success();
  endfunction

  // 功能：把共享 payload authority 归一为驱动 xtrdma_set_ud_wqe() 的物理 8..56B 布局，
  //   使 TPL、INLINE、SGE_NUM、SGB 字节与 signature 同源。
  // 输入/输出及副作用：model 只读，b 输出；成功更新 builder 与 last_*；SGB 字节仅参与签名，
  //   Host-memory 由 queue-data writer 另行写入；opcode 映射后即使后续校验被拒，last_hw_opcode 也可能已更新。
  // 失败/边界：非 UD 扩展、tunnel、mode/opcode 不相容、inline 超 512B、descriptor 超 32、TPL 超 14 bit、
  //   SGB IOVA 未对齐或长度不一致时，在首个字段/signature 写入前返回错误。
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b);
    rdma_hw_sqe_model x;
    rdma_sqe_ud_ext ext;
    rdma_address_vector av;
    rdma_status s;
    rdma_sq_payload_mode_e authority_mode;
    rdma_sq_payload_mode_e mode;
    byte unsigned sgb[$];
    byte unsigned raw[];
    byte unsigned payload_bytes[];
    byte unsigned resolved_inline_bytes[];
    bit [3:0] op;
    bit [7:0] sig;
    bit [31:0] encoded_sge_length;
    longint unsigned length;
    int unsigned valid_sge_count;
    int unsigned inline_payload_bytes;
    int unsigned sge_count;
    bit inline_bytes_are_authority;
    longint unsigned canonical_sge_payload_len;

    if (!$cast(x, model)) return err("UD SQE model type mismatch");
    if (x.transport != RDMA_TRANSPORT_UD) return err("UD codec received non-UD SQE");
    if (!$cast(ext, x.transport_ext)) return err("UD extension type mismatch");
    s = ext.validate(x.opcode); if (!s.ok()) return s;
    s = map_opcode(x.opcode, op); if (!s.ok()) return s;
    last_hw_opcode = op;
    av = ext.address_vector;
    if (av == null) return err("UD SQE address vector is null");

    // 0.1.34 驱动 wr.c:735 固定以 FIELD_PREP(..., 0) 写 XTRDMA_SQ_WQE_UD_TUNNEL（wr.h:116，bit29），
    // 内核路径没有可编码的 tunnel capability；拒绝非零请求，避免生成驱动永远不会发出的 wire image，
    // 也不静默清除调用方输入。
    if (av.tunnel_enable)
      return rdma_status::make(
          RDMA_SC_UNSUPPORTED_OPCODE,
          "UD SQE tunnel flag is unsupported by kernel driver ABI");

    // semantic mode、过滤后 descriptor 数、inline 字节源/长度与 raw count 必须来自同一次 authority
    // 推导；后续遍历只校验、累计 TPL 和序列化，不再形成 UD 私有的 mode/count 公式。
    x.derive_payload_authority(authority_mode, valid_sge_count,
                               inline_payload_bytes,
                               inline_bytes_are_authority,
                               sge_count);
    sgb.delete();
    length = 0;
    case (authority_mode)
      RDMA_SQ_PAYLOAD_INLINE_WQE,
      RDMA_SQ_PAYLOAD_INLINE_SGB: begin
        length = inline_payload_bytes;
        if (x.total_payload_len != 0 && x.total_payload_len != length)
          return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "UD inline payload length is inconsistent");
        if (inline_payload_bytes > 512)
          return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "UD inline payload exceeds one 512-byte SGB slot");

        mode = length == 0 ? RDMA_SQ_PAYLOAD_INLINE_WQE :
                             RDMA_SQ_PAYLOAD_INLINE_SGB;
        if (length != 0) begin
          s = x.resolve_inline_payload_authority(resolved_inline_bytes);
          if (s == null || !s.ok()) begin
            if (s == null) begin
              return rdma_status::make(
                  RDMA_SC_INVALID_STATE,
                  "UD inline payload authority returned null status");
            end
            return s;
          end
          payload_bytes = new[resolved_inline_bytes.size()];
          foreach (resolved_inline_bytes[i])
            payload_bytes[i] = resolved_inline_bytes[i];
          foreach (payload_bytes[i])
            sgb.push_back(payload_bytes[i]);
          while (sgb.size() < 512)
            sgb.push_back(0);
        end
      end

      RDMA_SQ_PAYLOAD_SGE_WQE,
      RDMA_SQ_PAYLOAD_SGE_SGB: begin
        s = rdma_sge_authority::derive_send(
            x.sges, valid_sge_count, canonical_sge_payload_len);
        if (!s.ok())
          return s;
        if (valid_sge_count != sge_count)
          return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "UD payload authority count is inconsistent");
        length = canonical_sge_payload_len;

        foreach (x.sges[i]) begin
          if (x.sges[i].length == 0)
            continue;
          if (x.sges[i].length == 32'h8000_0000)
            encoded_sge_length = 32'h0000_0000;
          else
            encoded_sge_length = x.sges[i].length;
          for (int unsigned j = 0; j < 4; j++) begin
            sgb.push_back(encoded_sge_length >> (24-j*8));
          end
          for (int unsigned j = 0; j < 4; j++) begin
            sgb.push_back(x.sges[i].lkey >> (24-j*8));
          end
          for (int unsigned j = 0; j < 8; j++) begin
            sgb.push_back(x.sges[i].iova.value >> (56-j*8));
          end
        end
        if (x.total_payload_len != 0 && x.total_payload_len != length)
          return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "UD total payload length does not match SGEs");
        while (sgb.size() < 512)
          sgb.push_back(0);
        mode = RDMA_SQ_PAYLOAD_SGE_SGB;
      end

      RDMA_SQ_PAYLOAD_NONE: begin
        if (x.total_payload_len != 0)
          return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "empty UD payload mode has nonzero length");
        mode = RDMA_SQ_PAYLOAD_NONE;
      end

      RDMA_SQ_PAYLOAD_ATOMIC_FIXED:
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "UD SEND does not support atomic payload mode");

      default:
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "UD payload mode is invalid");
    endcase

    if (length > 14'h3fff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD payload length exceeds 14-bit field");
    if (length != 0 && (x.sgb_iova.value == 0 ||
                        (x.sgb_iova.value & 64'h1ff) != 0))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD nonzero payload requires aligned SGB IOVA");
    // UD driver 把非零 IB_SEND_INLINE payload 放进外部 SQ-SGB，但 INLINE_LOCAL_QPC_RD 仍置 1
    // （xtrdma_get_inline_local_qpc_rd_flag）；mode 须保留 INLINE_SGB，不能按物理存放位置改为 SGE_SGB。
    // 只有非 inline descriptor 使用 SGE_SGB。
    last_mode = mode;
    if (sge_count > 8'hff)
      return err("UD SGE count exceeds field width");

    `define UDPUT(S,V) s=put(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return s;
    `UDPUT(RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN,length)
    `UDPUT(RDMA_SQ_WQE_UD_DST_VPORT_ID,av.destination_vport)
    `UDPUT(RDMA_SQ_WQE_UD_FWD,av.forwarding_mode)
    `UDPUT(RDMA_SQ_WQE_UD_LAG,av.lag_enable)
    `UDPUT(RDMA_SQ_WQE_UD_TUNNEL,av.tunnel_enable)
    `UDPUT(RDMA_SQ_WQE_UD_IPV6,av.ipv6)
    `UDPUT(RDMA_SQ_WQE_UD_VLAN,av.vlan_enable)
    if (x.opcode == RDMA_WR_SEND_WITH_IMM)
      `UDPUT(RDMA_SQ_WQE_RC_IMMEDIATE,x.immediate_data)
    else if (x.opcode == RDMA_WR_SEND_WITH_INV)
      `UDPUT(RDMA_SQ_WQE_RC_IMMEDIATE,x.invalidate_key)
    `UDPUT(RDMA_SQ_WQE_UD_SGE_NUM,sge_count)
    `UDPUT(RDMA_SQ_WQE_UD_DMAC,av.destination_mac)
    `UDPUT(RDMA_SQ_WQE_UD_PRI,av.\priority )
    `UDPUT(RDMA_SQ_WQE_UD_CFI,av.cfi)
    `UDPUT(RDMA_SQ_WQE_UD_VLAN_ID,av.vlan_enable ? av.vlan_id : 0)
    `UDPUT(RDMA_SQ_WQE_UD_PD_IDX,av.source_vport)
    `UDPUT(RDMA_SQ_WQE_UD_FLOW_LABEL,av.flow_label)
    `UDPUT(RDMA_SQ_WQE_UD_SRC_ADDR_IDX,av.source_address_index)
    `UDPUT(RDMA_SQ_WQE_SGB_PA,x.sgb_iova.value >> 9)
    `UDPUT(RDMA_SQ_WQE_UD_MC,av.multicast)
    `UDPUT(RDMA_SQ_WQE_UD_TRAFFIC_CLASS,av.traffic_class)
    `UDPUT(RDMA_SQ_WQE_UD_HOPLIMIT,av.hop_limit == 0 ? 8'h40 : av.hop_limit)
    `UDPUT(RDMA_SQ_WQE_UD_DST_QPN,ext.destination_qpn)
    `UDPUT(RDMA_SQ_WQE_UD_DST_Q_KEY,ext.qkey)
    `undef UDPUT
    // driver 用 memcpy 写目标 IP；按大端 qword 组合可保持 image 字节序。
    s = put(b, RDMA_SQ_WQE_UD_DST_IPV6_L_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_UD_DST_IPV6_L_LSB, RDMA_SQ_WQE_UD_DST_IPV6_L_WIDTH,
            {av.destination_ip[0],av.destination_ip[1],av.destination_ip[2],av.destination_ip[3],
             av.destination_ip[4],av.destination_ip[5],av.destination_ip[6],av.destination_ip[7]});
    if (!s.ok()) return s;
    s = put(b, RDMA_SQ_WQE_UD_DST_IPV6_H_WORD_BYTE_OFFSET,
            RDMA_SQ_WQE_UD_DST_IPV6_H_LSB, RDMA_SQ_WQE_UD_DST_IPV6_H_WIDTH,
            {av.destination_ip[8],av.destination_ip[9],av.destination_ip[10],av.destination_ip[11],
             av.destination_ip[12],av.destination_ip[13],av.destination_ip[14],av.destination_ip[15]});
    if (!s.ok()) return s;
    s = put_header(x, mode, last_hw_opcode, b);
    if (!s.ok())
      return s;
    s = b.serialize(raw);
    if (!s.ok())
      return err(s.message);
    sig = ~8'h00;
    foreach (raw[i]) if (i != 16) sig ^= raw[i];
    foreach (sgb[i]) sig ^= sgb[i];
    return put(b, RDMA_SQ_WQE_SIGNATURE_WORD_BYTE_OFFSET,
               RDMA_SQ_WQE_SIGNATURE_LSB, RDMA_SQ_WQE_SIGNATURE_WIDTH, sig);
  endfunction

  // 功能：明确拒绝只含 64B WQE 的 UD decode，避免缺少外部 SGB/AH 的镜像被误判为 RC。
  // 输入/输出及副作用：不改 image 或 codec 状态。
  // 失败/边界：恒返回 UNSUPPORTED_OPCODE；须经带 SGB/AH 证据的专用入口才能建立 UD 模型。
  virtual function rdma_status validate_image(rdma_hw_image image);
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                              "UD decode requires external SGB and AH evidence");
  endfunction
endclass

class rdma_hw_sqe_urc_codec extends rdma_hw_sqe_rc_codec;
  `rdma_object_utils(rdma_hw_sqe_urc_codec)
  // 功能：构造 URC SQE codec。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_sqe_urc_codec");
    super.new(name);
  endfunction

  // 功能：判断 PMTU 是否为 0.1.34 驱动实际支持的 QPC 值。
  // 输入/输出及副作用：只读 path_mtu_bytes，返回 bit。
  // 失败/边界：仅 1024/2048/4096/8192 为真；256/512 在 qp.h 中是 reserved/不支持，零和其他值为假。
  protected function bit path_mtu_is_driver_valid(int unsigned path_mtu_bytes);
    return path_mtu_bytes inside {1024, 2048, 4096, 8192};
  endfunction

  // 功能：按 wr.c 的 ALIGN(length, PMTU)/PMTU 规则累计 external-SGB URC READ 的 packet 数。
  // 输入/输出及副作用：x、mode 输入，total_packet_num 输出；只读 SGE 快照与冻结 PMTU。
  // 失败/边界：仅 SGE_SGB + RDMA_READ 计算；PMTU 缺失/不支持、null SGE、保留长度位或累计值超 24 bit
  //   返回 INVALID_ARGUMENT，调用方不得编码。
  protected function rdma_status calculate_total_packet_num(
      rdma_hw_sqe_model x,
      rdma_sq_payload_mode_e mode,
      output bit [23:0] total_packet_num);
    longint unsigned packet_count;
    longint unsigned descriptor_packets;

    total_packet_num = '0;
    if (x == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC READ SQE model is null");

    if (x.opcode != RDMA_WR_RDMA_READ ||
        mode != RDMA_SQ_PAYLOAD_SGE_SGB)
      return rdma_status::success();

    if (!path_mtu_is_driver_valid(x.path_mtu_bytes))
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "URC READ lacks a supported programmed-QPC PMTU");

    packet_count = 0;
    foreach (x.sges[i]) begin
      if (x.sges[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "URC READ SGB contains a null SGE");
      if (x.sges[i].length == 0)
        continue;
      if (x.sges[i].length != 32'h8000_0000 &&
          x.sges[i].length[31])
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "URC READ SGE length uses reserved bit 31");

      descriptor_packets =
          (x.sges[i].length / x.path_mtu_bytes) +
          ((x.sges[i].length % x.path_mtu_bytes) != 0);
      if (descriptor_packets > 24'hff_ffff - packet_count)
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "URC READ TOTAL_PKT_NUM exceeds 24 bits");
      packet_count += descriptor_packets;
    end

    total_packet_num = packet_count[23:0];
    return rdma_status::success();
  endfunction

  // 功能：授权 raw URC external-SGB READ 的 qword5[63:40] TOTAL_PKT_NUM 字段。
  // 输入/输出及副作用：只比较 raw_mode/raw_opcode 并返回 bit，不改 last_*。
  // 失败/边界：仅 SGE_SGB + RDMA_SQ_OPCODE_READ 返回真；其余返回假，qword5[39:0] 仍须为零。
  protected virtual function bit allow_urc_read_total_packet_num(
      rdma_sq_payload_mode_e raw_mode,
      bit [3:0] raw_opcode);
    return raw_mode == RDMA_SQ_PAYLOAD_SGE_SGB &&
           raw_opcode == RDMA_SQ_OPCODE_READ;
  endfunction

  // 功能：校验 URC SQE header 保留位和固定 64B 几何。
  // 输入/输出及副作用：只读 b。
  // 失败/边界：qword 数不为 8 或保留位非零返回 CODEC_ERROR。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b);
    // URC data-plane WQE 与 RC 共用 qword1..7，复用 RC body mask，避免把 completion-QP
    // 控制面 authority 误写入 payload/SGE 区。
    return super.check_reserved(b);
  endfunction
    // 功能：编码 URC 目的 QPN、可用远端字段和 complement-XOR signature。
    // 输入/输出及副作用：model 输入，b 输出；completion-QP 仅做 authority 校验。
    // 失败/边界：缺 completion authority、payload/字段非法或 builder overlap 时返回错误。
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b);
    rdma_hw_sqe_model x;
    rdma_sqe_urc_ext ext;
    rdma_status s;
    rdma_sq_payload_mode_e mode;
    byte unsigned sgb[$];
    bit [3:0] op;
    bit [23:0] total_packet_num;

    if (!$cast(x,model)) return err("URC SQE model type mismatch");
    if (x.transport != RDMA_TRANSPORT_URC) return err("URC codec received non-URC SQE");
    if (!$cast(ext,x.transport_ext)) return err("URC extension type mismatch");
    s=ext.validate(x.opcode); if(!s.ok()) return s; s=map_opcode(x.opcode,op); if(!s.ok()) return s;
    last_hw_opcode = op;
    s=body_and_header(x,b,mode,sgb); if(!s.ok()) return s;

    s = calculate_total_packet_num(x, mode, total_packet_num);
    if (!s.ok())
      return s;
    if (x.opcode == RDMA_WR_RDMA_READ &&
        mode == RDMA_SQ_PAYLOAD_SGE_SGB) begin
      // wr.c 在填完 external SGB descriptor 后写字节 0x28；该字段属于 64B WQE 签名，
      // 须先于下面的 complement-XOR 计算写入。
      s = put(b, RDMA_SQ_WQE_URC_TOTAL_PKT_NUM_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_URC_TOTAL_PKT_NUM_LSB,
              RDMA_SQ_WQE_URC_TOTAL_PKT_NUM_WIDTH,
              total_packet_num);
      if (!s.ok())
        return s;
    end
    last_mode = mode;
    begin
      byte unsigned raw[];
      bit [7:0] sig;

      s = b.serialize(raw);
      if (!s.ok())
        return err(s.message);

      sig = ~8'h00;
      foreach (raw[i])
        if (i != 16)
          sig ^= raw[i];

      foreach (sgb[i])
        sig ^= sgb[i];

      s = put(b, RDMA_SQ_WQE_SIGNATURE_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_SIGNATURE_LSB, RDMA_SQ_WQE_SIGNATURE_WIDTH, sig);
      if (!s.ok())
        return s;
    end
    return rdma_status::success();
  endfunction

  // 功能：明确拒绝只含 64B WQE 的 URC decode，避免继承 RC decode 而丢失 completion-QP/sequence 证据。
  // 输入/输出及副作用：不改 image 或 codec 状态。
  // 失败/边界：恒返回 UNSUPPORTED_OPCODE；须经带 completion-QP/epoch 的专用接口认证。
  virtual function rdma_status validate_image(rdma_hw_image image);
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                              "URC decode requires completion-QP evidence");
  endfunction
endclass

class rdma_hw_rqe_codec extends rdma_hw_queue_codec_base;
  `rdma_object_utils(rdma_hw_rqe_codec)

  // decode_fields 仅在构造 detached external model 的瞬间开启此 capability 窗口；
  // 以对象 identity 比较 active model，防止 fresh caller 伪造 raw marker。
  local bit raw_decode_authorization_active;
  local rdma_hw_rqe_model active_raw_decode_model;

  // 驱动把 qword4 复用为两种物理布局：至多两个有效 SGE 直接内联，更多则写外部 SGB_PA。
  // codec 须依据 wire 上的 SGE_NUM、SGE qword 与 SGB 对齐位判定布局，不能放宽保留位掩码来掩盖歧义。
  // 功能：构造 RQE codec。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name="rdma_hw_rqe_codec");
    super.new(name);
    raw_decode_authorization_active = 1'b0;
    active_raw_decode_model = null;
  endfunction

  // 功能：判断 candidate 是否为当前 decode-active 窗口内的 model，供 RQE model 建立 provenance。
  // 输入/输出及副作用：只读，返回 bit；不提供设置 capability 的入口。
  // 失败/边界：codec 不在 decode_fields 窗口、candidate 为空或非当前 active 对象时返回 0。
  function bit is_raw_decode_authorization_active(
      rdma_hw_rqe_model candidate);
    return raw_decode_authorization_active &&
           candidate != null && candidate == active_raw_decode_model;
  endfunction
  // 功能：按 wr.h 字段坐标检查 RQE 的 8 个 qword：保留位、未使用 qword 与两种布局的约束。
  // 输入/输出及副作用：只读 b，返回 rdma_status。
  // 失败/边界：拒绝 header/meta 保留位、inline SGE 长度 bit63、外部 SGB_PA 低 9 位及未使用 qword
  //   非零；不靠放宽整字掩码吞掉驱动 ABI 错误。
  protected function rdma_status image_check(rdma_hw_qword_builder b);
    bit [63:0] words[];
    bit inline_mode;
    int unsigned inline_sge_count;
    longint unsigned inline_payload_len;
    longint unsigned semantic_sge_len;
    bit [30:0] wire_sge_len;
    const bit [63:0] RQE_HEADER_MASK = 64'h81ff_ff0f_ffff_ffff;
    const bit [63:0] RQE_TPL_MASK = 64'h0000_0000_ffff_ffff;
    const bit [63:0] RQE_META_MASK = 64'hffff_0000_0000_0000;
    const bit [63:0] RQE_SGB_MASK = 64'hffff_ffff_ffff_fe00;
    const bit [63:0] RQE_INLINE_SGE_WORD_MASK = 64'h7fff_ffff_ffff_ffff;

    b.get_words(words);
    if (words.size() != 8)
      return err("RQE image must contain eight qwords");

    // wr.h:177/182 与 wr.c:1159-1165 把 RQE opcode 0x9 定为硬件固定的 receive-WQE 类型，
    // 不是调用方可选字段；在布局推断和发布 model 前拒绝其他 raw 值。
    if (words[0][35:32] !== 4'h9)
      return err("RQE hardware opcode is not the fixed receive opcode 0x9");

    inline_sge_count = words[2][55:48];
    // wr.c/queue data 只支持 32 个有效 SGE；qword2 的 SGE_NUM 超限不是另一种合法布局，
    // 须在 inline/external 分支前拒绝。
    if (inline_sge_count > RDMA_MAX_WQ_SGE)
      return err("RQE SGE count exceeds driver limit of 32");
    inline_mode = inline_sge_count <= 2;

    // 每个 raw qword 都经四态 helper 检查（而非直接拼 `& ~mask` 与相等运算，避免优先级回归），
    // 未知位在进入布局分支前 fail-closed；mask 数值取自 wr.h。
    if (!rdma_raw_qword_mask_is_valid(words[0], RQE_HEADER_MASK) ||
        !rdma_raw_qword_mask_is_valid(words[1], RQE_TPL_MASK) ||
        !rdma_raw_qword_mask_is_valid(words[2], RQE_META_MASK) ||
        words[3] !== 0 ||
        (inline_mode &&
         (!rdma_raw_qword_mask_is_valid(
             words[4], RQE_INLINE_SGE_WORD_MASK) ||
          !rdma_raw_qword_mask_is_valid(
             words[6], RQE_INLINE_SGE_WORD_MASK) ||
          (inline_sge_count == 0 &&
           (words[4] !== 0 || words[5] !== 0 ||
            words[6] !== 0 || words[7] !== 0)) ||
          (inline_sge_count < 2 &&
           (words[6] !== 0 || words[7] !== 0)))) ||
        (!inline_mode &&
         (words[0][56] !== 1'b1 ||
          !rdma_raw_qword_mask_is_valid(words[4], RQE_SGB_MASK) ||
          words[4][63:9] == 0 || words[5] !== 0 ||
          words[6] !== 0 || words[7] !== 0)))
      return err("RQE reserved bits are nonzero");

    // 驱动由同一批有效 SGE 长度写 TPL 与 inline descriptor；wire 长度 0 是 2GiB sentinel 而非空
    // descriptor，故校验语义总和，而不仅检查 qword4/qword6 非零。
    if (inline_mode) begin
      inline_payload_len = 0;
      for (int unsigned i = 0; i < inline_sge_count; i++) begin
        wire_sge_len = i == 0 ? words[4][62:32] : words[6][62:32];
        semantic_sge_len = wire_sge_len == 31'b0 ?
                           64'h8000_0000 : wire_sge_len;
        inline_payload_len += semantic_sge_len;
      end

      if (inline_payload_len > 64'h8000_0000 ||
          words[1][31:0] !== inline_payload_len[31:0])
        return err("RQE TPL does not match inline SGE length sum");
    end

    return rdma_status::success();
  endfunction
  // 功能：返回 RDMA_IMAGE_RQE。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_RQE;
  endfunction

  // 功能：返回 RQE 固定镜像长度 RDMA_RQE_BYTES（64B）。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  protected virtual function int unsigned image_bytes();
    return RDMA_RQE_BYTES;
  endfunction

  // 功能：调用 RQE 专用保留位检查，使编码与解码共用同一份驱动掩码。
  // 输入/输出及副作用：只读 b。
  // 失败/边界：任一未声明位非零时沿 image_check 返回 CODEC_ERROR。
  protected virtual function rdma_status check_reserved(
      rdma_hw_qword_builder b);
    if (b == null)
      return err("RQE qword builder is null");
    return image_check(b);
  endfunction

  // 功能：按 wr.c xtrdma_calculate_wqe_signature 校验已解码 RQE 的 WQE 字节及可选外部 SGB descriptor。
  // 输入/输出及副作用：image、descriptor_bytes 只读；descriptor_authority_valid 表示调用方是否提供真实
  //   SGB authority；失败时仅把 model 清空。
  // 失败/边界：inline RQE 只允许空 descriptor authority；external RQE 须恰为 SGE_NUM*16 字节，
  //   缺失、长度不符或 complement-XOR 失配返回错误，禁止用零填充代替宿主内存 descriptor。
  protected function rdma_status validate_rqe_signature(
      rdma_hw_image image,
      inout rdma_hw_model model,
      input byte unsigned descriptor_bytes[],
      bit descriptor_authority_valid
  );
    rdma_hw_rqe_model x;
    bit [7:0] expected;

    if (!$cast(x, model) || x == null) begin
      model = null;
      return err("RQE signature model type mismatch");
    end

    if (!x.sign_en)
      return rdma_status::success();

    if (x.sge_num > 2) begin
      if (!descriptor_authority_valid)
        begin
          model = null;
          return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "RQE external signature requires descriptor authority");
        end

      if (descriptor_bytes.size() != int'(x.sge_num) * 16) begin
        model = null;
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "RQE external signature descriptor length is invalid");
      end
    end
    else if (descriptor_bytes.size() != 0) begin
      model = null;
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE inline signature cannot use external descriptors");
    end

    expected = ~rdma_hw_sq_signature_xor(image, descriptor_bytes);
    if (image.bytes[16] !== expected) begin
      model = null;
      return err("RQE signature XOR is invalid");
    end

    if (x.sge_num > 2) begin
      rdma_status authority_status;

      authority_status = x.set_external_sgb_descriptor_bytes(
          descriptor_bytes);
      if (authority_status == null || !authority_status.ok()) begin
        model = null;
        return authority_status == null ?
          err("RQE external descriptor authority installation failed") :
          authority_status;
      end
    end

    return rdma_status::success();
  endfunction

  // 功能：复用基类的长度/保留位/字段解码流程，并在发布 detached RQE 前校验 inline/no-SGB 签名；
  //   external RQE 缺少 host-memory descriptor authority 时 fail-closed。
  // 输入/输出及副作用：image 输入，model 输出；失败保持 model=null。
  // 失败/边界：metadata/保留位/字段解码失败原样返回；签名缺失/失配或 external authority 不可证明
  //   时返回明确状态，不把 descriptor 当作零字节。
  virtual function rdma_status decode(
      rdma_hw_image image,
      output rdma_hw_model model
  );
    byte unsigned no_descriptor_authority[];
    rdma_status status;

    model = null;
    no_descriptor_authority = new[0];
    status = super.decode(image, model);
    if (status == null || !status.ok())
      return status == null ? err("RQE base decode returned null status") : status;

    status = validate_rqe_signature(
        image, model, no_descriptor_authority, 1'b0);
    if (status == null || !status.ok())
      model = null;
    return status == null ? err("RQE signature validation returned null status") :
      status;
  endfunction

  // 功能：普通 RQE 解码后注入调用方提供的真实 external-SGB descriptor authority，并按 wr.c 完整 XOR
  //   规则验签，供 host-memory/queue-data 读取路径使用。
  // 输入/输出及副作用：image、descriptor_bytes 输入，model 输出；成功发布携带 descriptor authority 的 model。
  // 失败/边界：仅 external RQE 接受恰为 SGE_NUM*16 字节；inline RQE、长度不符、解码失败或签名失配
  //   均拒绝，失败保持 model=null，不截断、补零或重试。
  function rdma_status decode_with_sgb_descriptor_bytes(
      rdma_hw_image image,
      input byte unsigned descriptor_bytes[],
      output rdma_hw_model model
  );
    rdma_status status;

    model = null;
    status = super.decode(image, model);
    if (status == null || !status.ok())
      return status == null ? err("RQE base decode returned null status") : status;

    status = validate_rqe_signature(
        image, model, descriptor_bytes, 1'b1);
    if (status == null || !status.ok())
      model = null;
    return status == null ? err("RQE signature validation returned null status") :
      status;
  endfunction

  // 功能：把 RQE model 的 header、SGE/SGB_PA 字段按布局写入 builder，并计算签名。
  // 输入/输出及副作用：model 只读，b 为写入器；成功更新 b，不改源 model。
  // 失败/边界：model 非 rdma_hw_rqe_model、字段/布局非法或 put 失败返回错误，不发布 image。
  protected virtual function rdma_status encode_fields(
      rdma_hw_model model,
      rdma_hw_qword_builder b
  );
    rdma_hw_rqe_model x;
    rdma_status status;
    bit inline_mode;
    bit wire_sign_en;
    int unsigned valid_sge_count;
    int unsigned inline_sge_index;
    longint unsigned valid_payload_len;
    byte unsigned descriptor_bytes[$];
    byte unsigned serialized[];
    rdma_hw_image signature_image;
    bit [7:0] computed_signature;

    if (!$cast(x, model))
      return err("RQE model type mismatch");
    if (b == null)
      return err("RQE qword builder is null");

    status = x.validate();
    if (!status.ok())
      return status;

    status = x.resolve_payload_authority(
        valid_sge_count, valid_payload_len);
    if (!status.ok())
      return status;

    // wr.c 对至多两个有效 SGE 使用 inline RQE 存储；SGB_PA 非零是 model 侧显式请求
    // external SGB 布局的信号，以保留较大 SGE 列表的既有 queue-data 路径。
    inline_mode = x.sge_num <= 2;
    if (inline_mode) begin
      if (x.sgb_pa != 0)
        return err("RQE inline layout cannot carry an SGB pointer");
      if (x.sge_num != valid_sge_count)
        return err("RQE inline SGE count does not match SGE_NUM");
    end
    else begin
      if (x.sgb_pa == 0)
        return err("RQE external layout requires an SGB pointer");

      // typed 请求经 detached SGE 列表持有 descriptor 值；decode 得到的 raw model 在调用方
      // 显式提供 authority 前不持有 descriptor 字节。两条路径都须得到恰为 N*16 字节。
      if (x.external_sgb_descriptor_authority_valid) begin
        if (x.external_sgb_descriptor_bytes.size() !=
            int'(x.sge_num) * 16)
          return err("RQE external SGB descriptor authority is incomplete");
        foreach (x.external_sgb_descriptor_bytes[i])
          descriptor_bytes.push_back(x.external_sgb_descriptor_bytes[i]);
      end
      else begin
        byte unsigned typed_descriptor_bytes[];

        status = x.build_typed_sgb_descriptor_bytes(
            typed_descriptor_bytes);
        if (!status.ok())
          return status;
        foreach (typed_descriptor_bytes[i])
          descriptor_bytes.push_back(typed_descriptor_bytes[i]);
        if (descriptor_bytes.size() != int'(x.sge_num) * 16)
          return err("RQE external SGB descriptor bytes are unavailable");
      end
    end

    // wr.c 中 sign_en = rq_sign_en || use_sgb：model 的 sign_en 对应前者，external SGB 模式
    // 须强制置 wire 位，即使调用方未置 sign_en。
    wire_sign_en = x.sign_en || !inline_mode;

    `define RQPUT(STEM, VALUE) \
      status = b.put_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                           STEM``_WIDTH, VALUE); \
      if (!status.ok()) return err(status.message);

    `RQPUT(RDMA_RQE_QPN, x.qpn)
    `RQPUT(RDMA_RQE_QP_SN, x.qp_sn)
    `RQPUT(RDMA_RQE_OPCODE, x.hw_opcode)
    `RQPUT(RDMA_RQE_INDEX, x.index)
    `RQPUT(RDMA_RQE_WRAP, x.wrap)
    `RQPUT(RDMA_RQE_SIGN_EN, wire_sign_en)
    `RQPUT(RDMA_RQE_VALID, x.valid)
    `RQPUT(RDMA_RQE_PAYLOAD_LEN, x.payload_len)
    `RQPUT(RDMA_RQE_SGE_NUM, x.sge_num)

    if (inline_mode) begin
      inline_sge_index = 0;
      foreach (x.sges[i]) begin
        bit [30:0] encoded_length;

        if (x.sges[i].length == 0)
          continue;
        if (x.sges[i].length[31] &&
            x.sges[i].length != 32'h8000_0000)
          return err("RQE inline SGE length exceeds 31 bits");

        // wr.c 以 GENMASK(30,0) 屏蔽长度，零值表示 2GiB SGE；显式保留该 sentinel，避免 bit31 泄漏到保留位。
        encoded_length = x.sges[i].length == 32'h8000_0000 ?
                         31'b0 : x.sges[i].length[30:0];

        status = b.put_field(
            32 + inline_sge_index * 16, 0, 32, x.sges[i].lkey);
        if (!status.ok()) return err(status.message);
        status = b.put_field(
            32 + inline_sge_index * 16, 32, 31, encoded_length);
        if (!status.ok()) return err(status.message);
        status = b.put_field(40 + inline_sge_index * 16, 0, 64,
                             x.sges[i].iova.value);
        if (!status.ok()) return err(status.message);
        inline_sge_index++;
      end
    end
    else begin
      `RQPUT(RDMA_RQE_SGB_PA, x.sgb_pa)
    end

    `undef RQPUT

    // wr.c 在 header 与 body 完成后计算补码，此时 signature 字节在新 builder 中仍为零。
    // 序列化该 64B image，只计入实际 external descriptor（不含 512B 尾部），signature 只写一次
    // （qword-builder 的占用检查会拒绝重复写同一字段）。
    status = b.serialize(serialized);
    if (!status.ok())
      return err(status.message);
    signature_image = rdma_hw_image::type_id::create("rqe_signature_image");
    if (signature_image == null)
      return err("RQE signature image allocation failed");
    foreach (serialized[i])
      signature_image.bytes.push_back(serialized[i]);
    computed_signature = wire_sign_en ?
        ~rdma_hw_sq_signature_xor(signature_image, descriptor_bytes) :
        8'h00;
    status = b.put_field(RDMA_RQE_SIGNATURE_WORD_BYTE_OFFSET,
                         RDMA_RQE_SIGNATURE_LSB,
                         RDMA_RQE_SIGNATURE_WIDTH, computed_signature);
    if (!status.ok())
      return err(status.message);
    return rdma_status::success();
  endfunction
  // 功能：把 builder 解码为 detached RQE model。
  // 输入/输出及副作用：b 只读，model 输出；至多 2 个 SGE 时恢复 inline SGE，否则读 SGB_PA 并在
  //   decode-active 窗口内标记 raw provenance。
  // 失败/边界：b 为空或字段读取/provenance 标记失败返回错误，model 保持 null。
  protected virtual function rdma_status decode_fields(
      rdma_hw_qword_builder b,
      output rdma_hw_model model
  );
    rdma_hw_rqe_model x;
    bit [63:0] value;
    rdma_status status;
    bit inline_mode;

    model = null;
    if (b == null)
      return err("RQE qword builder is null");

    x = rdma_hw_rqe_model::type_id::create("decoded_rqe");
    x.target_h = rdma_hw_queue_projected_handle(
        "decoded_qp", RDMA_RESOURCE_QP, 0);

    begin
      bit [63:0] words[];

      b.get_words(words);
      inline_mode = words[2][55:48] <= 8'd2;
      if (inline_mode) begin
        for (int unsigned i = 0; i < words[2][55:48]; i++) begin
          rdma_sge decoded_sge;
          decoded_sge = rdma_sge::type_id::create(
              $sformatf("decoded_rqe_sge_%0d", i));
          status = b.get_field(32 + i * 16, 0, 32, value);
          if (!status.ok()) return err(status.message);
          decoded_sge.lkey = value;
          status = b.get_field(32 + i * 16, 32, 31, value);
          if (!status.ok()) return err(status.message);
          // wr.c 的 XTRDMA_WQE_SGE_LEN_LOW 保留 bit31，零 wire 值表示 2GiB；在 model 中还原该 sentinel，
          // 不向调用方暴露含义不清的零长 SGE。
          decoded_sge.length = value[30:0] == 31'b0 ?
                               32'h8000_0000 : value[30:0];
          status = b.get_field(40 + i * 16, 0, 64, value);
          if (!status.ok()) return err(status.message);
          decoded_sge.iova.value = value;
          x.sges.push_back(decoded_sge);
        end
      end
    end

    `define RQGET(STEM, TARGET) \
      value = '0; \
      status = b.get_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                           STEM``_WIDTH, value); \
      if (!status.ok()) return err(status.message); \
      TARGET = value;

    `RQGET(RDMA_RQE_QPN, x.qpn)
    `RQGET(RDMA_RQE_QP_SN, x.qp_sn)
    `RQGET(RDMA_RQE_OPCODE, x.hw_opcode)
    `RQGET(RDMA_RQE_INDEX, x.index)
    `RQGET(RDMA_RQE_WRAP, x.wrap)
    `RQGET(RDMA_RQE_SIGN_EN, x.sign_en)
    `RQGET(RDMA_RQE_VALID, x.valid)
    `RQGET(RDMA_RQE_PAYLOAD_LEN, x.payload_len)
    `RQGET(RDMA_RQE_SIGNATURE, x.signature)
    `RQGET(RDMA_RQE_SGE_NUM, x.sge_num)
    if (!inline_mode) begin
      `RQGET(RDMA_RQE_SGB_PA, x.sgb_pa)
      raw_decode_authorization_active = 1'b1;
      active_raw_decode_model = x;
      status = x.mark_decoded_raw_sgb_provenance(this);
      raw_decode_authorization_active = 1'b0;
      active_raw_decode_model = null;
      if (!status.ok())
        return status;
    end

    `undef RQGET
    model = x;
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_cqe_codec extends rdma_hw_queue_codec_base;
  `rdma_object_utils(rdma_hw_cqe_codec)
  protected int unsigned active_bytes;
  protected rdma_cqe_variant_e active_variant;
  protected bit variant_is_explicit;

  // 功能：构造 CQE codec，默认 64B profile 与 RC overlay。
  // 输入/输出及副作用：初始化 active_bytes、active_variant、variant_is_explicit。
  // 失败/边界：无；未配置的调用由后续 metadata 检查拒绝。
  function new(string name = "rdma_hw_cqe_codec");
    super.new(name);
    active_bytes = RDMA_CQE_BYTES;
    active_variant = RDMA_CQE_VARIANT_RC;
    variant_is_explicit = 1'b0;
  endfunction
  // 功能：选择本次编解码使用的 CQE profile 大小。
  // 输入/输出及副作用：bytes 为输入；成功时更新 codec 本地 profile，返回状态。
  // 失败/边界：32/64/128 以外的大小被拒绝且保留原 profile。
  function rdma_status set_entry_bytes(int unsigned bytes);
    if (!(bytes inside {32, 64, 128}))
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "CQE profile size is invalid");

    active_bytes = bytes;
    return rdma_status::success();
  endfunction

  // 功能：选择 raw CQE qword2/qword3 overlay 的 variant authority（RC/UD/RQ_SRFQ）。
  // 输入/输出及副作用：成功时更新 codec 的 variant，不改 entry bytes。
  // 失败/边界：未知枚举值被拒绝并保留旧 variant；默认 RC 只接受 RC overlay，解码 UD/RQ 前须显式选择。
  function rdma_status set_variant(rdma_cqe_variant_e variant);
    if (variant > RDMA_CQE_VARIANT_RQ_SRFQ)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "CQE variant is invalid");

    active_variant = variant;
    variant_is_explicit = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：检查 variant 是否为驱动定义的 RC、UD 或 RQ/SRFQ。
  // 输入/输出及副作用：只读 variant，返回状态。
  // 失败/边界：枚举值 3 或 X/Z 返回 INVALID_ARGUMENT。
  protected function rdma_status validate_variant_value(
      rdma_cqe_variant_e variant);
    if (variant > RDMA_CQE_VARIANT_RQ_SRFQ)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "CQE variant is invalid");
    return rdma_status::success();
  endfunction

  // 功能：集中校验显式 CQE profile 的 image 尺寸、generation、端序、类型、硬件版本和写入目标。
  // 输入/输出及副作用：image、entry_size 只读，返回 rdma_status。
  // 失败/边界：entry_size 非 32/64/128 返回 "CQE profile size is invalid"；image 为空、generation 为零、
  //   length/bytes/alignment 不等于 entry_size、端序非 BIG、kind/硬件版本不符或 backing/hmc/bar/write target
  //   非空时，分别返回 queue image null、stale generation 或 queue image metadata 错误。
  protected function rdma_status validate_cqe_image_metadata(
      rdma_hw_image image,
      int unsigned entry_size
  );
    if (!(entry_size inside {32, 64, 128}))
      return err("CQE profile size is invalid");
    if (image == null)
      return err("queue image is null");
    if (image.function_generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "queue image generation is stale");
    if (image.length != entry_size || image.bytes.size() != entry_size ||
        image.alignment != entry_size || image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != image_kind_expected() ||
        image.hardware_version != RDMA_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return err("queue image metadata is invalid");
    return rdma_status::success();
  endfunction

  // 功能：返回完整 entry 中 signature 字节的绝对偏移（32/64B 为 16，128B 为 80）。
  // 输入/输出及副作用：只读 entry_size。
  // 失败/边界：entry_size 非 32/64/128 返回 0，调用方须先确认大小，不能把 0 当合法位置。
  protected function int unsigned cqe_signature_offset(
      int unsigned entry_size);
    case (entry_size)
      32, 64: return 16;
      128: return 80;
      default: return 0;
    endcase
  endfunction

  // 功能：对完整 CQE entry 逐字节 XOR，跳过 signature 字节，供编码阶段生成补码签名。
  // 输入/输出及副作用：bytes、entry_size 只读，返回 8 位 XOR。
  // 失败/边界：bytes 长度不等于 entry_size 或 profile 不支持返回 0，调用方须先检查，不能把 0 当有效 parity。
  protected function bit [7:0] cqe_signature_without_field(
      input byte unsigned bytes[],
      input int unsigned entry_size);
    bit [7:0] value;
    int unsigned signature_offset;

    value = 8'h00;
    if (!(entry_size inside {32, 64, 128}) || bytes.size() != entry_size)
      return value;

    signature_offset = cqe_signature_offset(entry_size);
    foreach (bytes[i]) begin
      if (i != signature_offset)
        value ^= bytes[i];
    end

    return value;
  endfunction

  // 功能：复现 wr.c 的 xtrdma_check_cqe_signature：SIGN_EN=1 时整个 entry 的 XOR 须为 8'hff。
  // 输入/输出及副作用：bytes、entry_size、sign_en 只读，返回 rdma_status。
  // 失败/边界：SIGN_EN=0 不检查；profile/长度不符或 XOR 不是 8'hff 返回 CODEC_ERROR。
  protected function rdma_status validate_cqe_signature_bytes(
      input byte unsigned bytes[],
      input int unsigned entry_size,
      input bit sign_en);
    bit [7:0] value;

    if (!(entry_size inside {32, 64, 128}) || bytes.size() != entry_size)
      return err("CQE signature image length is invalid");
    if (!sign_en)
      return rdma_status::success();

    value = 8'h00;
    foreach (bytes[i])
      value ^= bytes[i];

    if (value !== 8'hff)
      return err("CQE signature XOR is invalid");

    return rdma_status::success();
  endfunction

  // 功能：CQE 字段与 payload 写完后，按补码 XOR 派生 typed image 的 signature，
  //   或校验 raw qword2 authority 携带的原始 signature 未失配。
  // 输入/输出及副作用：typed 路径成功时向 b 的 signature 字节只写一次；raw 路径只读校验。
  // 失败/边界：SIGN_EN=0 保留调用方 signature；builder/profile 无效、signature 字段已被占用
  //   或 raw image parity 失效返回 CODEC_ERROR。
  protected function rdma_status finalize_cqe_signature(
      rdma_hw_qword_builder b,
      int unsigned entry_size,
      bit sign_en,
      bit raw_authority);
    byte unsigned serialized[];
    bit [7:0] signature;
    rdma_status status;
    bit [63:0] occupancy[];
    int unsigned signature_offset;
    int unsigned signature_base;
    int unsigned signature_qword;

    if (b == null)
      return err("CQE signature builder is null");
    if (!(entry_size inside {32, 64, 128}))
      return err("CQE signature profile size is invalid");
    if (!sign_en)
      return rdma_status::success();

    status = b.serialize(serialized);
    if (status == null || !status.ok())
      return err(status == null ? "CQE signature serialize returned null" :
                 status.message);

    if (raw_authority)
      return validate_cqe_signature_bytes(serialized, entry_size, sign_en);

    signature = ~cqe_signature_without_field(serialized, entry_size);
    signature_offset = cqe_signature_offset(entry_size);
    signature_base = (entry_size == 128) ? 64 : 0;
    signature_qword = (signature_base + RDMA_CQE_SIGNATURE_WORD_BYTE_OFFSET) >> 3;
    b.get_occupancy(occupancy);
    if (signature_qword >= occupancy.size() ||
        (occupancy[signature_qword] & 64'hff00_0000_0000_0000) != 0)
      return err($sformatf(
          "CQE signature field is already occupied (qword=%0d mask=0x%016h)",
          signature_qword,
          signature_qword < occupancy.size() ? occupancy[signature_qword] :
                                                64'h0));
    status = b.put_field(
        signature_base + RDMA_CQE_SIGNATURE_WORD_BYTE_OFFSET,
        RDMA_CQE_SIGNATURE_LSB,
        RDMA_CQE_SIGNATURE_WIDTH,
        signature);
    if (status == null || !status.ok())
      return err(status == null ? "CQE signature field write returned null" :
                 status.message);

    // 将偏移保留为显式局部不变量：profile 相对字段与序列化后的绝对字节指向同一 wire 坐标，
    // 且无需第二次写 builder。
    if (signature_offset >= serialized.size())
      return err("CQE signature offset is outside the image");

    return rdma_status::success();
  endfunction

  // 功能：为单次 CQE 编码建立独立的 profile/variant scope，避免共享 registry codec 的
  //   active_variant 被交错调用污染，再复用既有字段/保留位/metadata 检查。
  // 输入/输出及副作用：model、entry_size、variant 输入，image 输出；只创建本次私有 codec，
  //   不改当前 codec 的 active profile/variant。
  // 失败/边界：variant、entry_size、model 或字段/generation/保留位非法时返回错误且 image 为 null；
  //   model variant 须与显式 variant 一致。
  virtual function rdma_status encode_with_entry_bytes_variant(
      rdma_hw_model model,
      int unsigned entry_size,
      rdma_cqe_variant_e variant,
      output rdma_hw_image image
  );
    rdma_hw_cqe_codec scoped_codec;
    rdma_status status;

    image = null;
    status = validate_variant_value(variant);
    if (!status.ok())
      return status;

    scoped_codec = new("cqe_variant_encode_scope");
    scoped_codec.active_bytes = entry_size;
    scoped_codec.active_variant = variant;
    scoped_codec.variant_is_explicit = 1'b1;
    return scoped_codec.encode_with_entry_bytes(model, entry_size, image);
  endfunction

  // 功能：为单次 CQE 解码建立独立的 profile/variant scope，解出所有 qword2 物理 overlay，
  //   并在模型中保存 raw authority 以支持逐位回编码。
  // 输入/输出及副作用：image、entry_size、variant 输入，model 输出；只创建本次私有 codec。
  // 失败/边界：variant、entry_size、metadata、保留位或字段解码失败返回错误且 model 为 null；
  //   不从 qword2 非零值猜 variant。
  virtual function rdma_status decode_with_entry_bytes_variant(
      rdma_hw_image image,
      int unsigned entry_size,
      rdma_cqe_variant_e variant,
      output rdma_hw_model model
  );
    rdma_hw_cqe_codec scoped_codec;
    rdma_status status;

    model = null;
    status = validate_variant_value(variant);
    if (!status.ok())
      return status;

    scoped_codec = new("cqe_variant_decode_scope");
    scoped_codec.active_bytes = entry_size;
    scoped_codec.active_variant = variant;
    scoped_codec.variant_is_explicit = 1'b1;
    return scoped_codec.decode_with_entry_bytes(image, entry_size, model);
  endfunction

  // 功能：用一次性 variant scope 校验 CQE metadata、header reserved 位和显式 qword3 authority。
  // 输入/输出及副作用：image、entry_size、variant 输入；不改 codec 状态。
  // 失败/边界：variant/profile/metadata/反序列化/reserved 任一失败返回 CODEC_ERROR 或 INVALID_ARGUMENT。
  virtual function rdma_status validate_image_with_entry_bytes_variant(
      rdma_hw_image image,
      int unsigned entry_size,
      rdma_cqe_variant_e variant
  );
    rdma_hw_cqe_codec scoped_codec;
    rdma_status status;

    status = validate_variant_value(variant);
    if (!status.ok())
      return status;

    scoped_codec = new("cqe_variant_validate_scope");
    scoped_codec.active_bytes = entry_size;
    scoped_codec.active_variant = variant;
    scoped_codec.variant_is_explicit = 1'b1;
    return scoped_codec.validate_image_with_entry_bytes(image, entry_size);
  endfunction

  // 功能：按调用方显式给出的 CQE entry profile 解码 image，返回 detached CQE model；
  //   不读写 active_bytes，因此共享 registry codec 可交错调用而不串 profile。
  // 输入/输出及副作用：image、entry_size 输入，model 输出；只读 image。
  // 失败/边界：entry_size 非 32/64/128、metadata/generation 不符、保留位非零、反序列化或
  //   字段模型创建失败返回 CODEC_ERROR，model=null。
  virtual function rdma_status decode_with_entry_bytes(
      rdma_hw_image image,
      int unsigned entry_size,
      output rdma_hw_model model
  );
    rdma_hw_qword_builder b;
    byte unsigned p[];
    rdma_hw_model candidate;
    rdma_status status;
    bit [63:0] sign_value;
    int unsigned base_offset;

    model = null;
    status = validate_cqe_image_metadata(image, entry_size);
    if (!status.ok())
      return status;

    p = new[entry_size];
    foreach (p[i]) p[i] = image.bytes[i];
    b = new("cqe_decode_profile");
    status = b.deserialize(p);
    if (!status.ok())
      return err(status.message);
    status = check_reserved(b);
    if (!status.ok())
      return status;

    base_offset = (entry_size == 128) ? 64 : 0;
    sign_value = '0;
    status = b.get_field(
        base_offset + RDMA_CQE_SIGN_EN_WORD_BYTE_OFFSET,
        RDMA_CQE_SIGN_EN_LSB,
        RDMA_CQE_SIGN_EN_WIDTH,
        sign_value);
    if (status == null || !status.ok())
      return err(status == null ? "CQE SIGN_EN decode returned null" :
                 status.message);
    status = validate_cqe_signature_bytes(
        p, entry_size, sign_value[0]);
    if (!status.ok())
      return status;

    status = decode_fields(b, candidate);
    if (!status.ok())
      return status;
    if (candidate == null)
      return err("CQE decode returned null model");
    model = candidate;
    return rdma_status::success();
  endfunction

  // 功能：按调用方指定的 32/64/128B profile 编码 detached CQE image；使用局部 builder，
  //   复用 validate_model/encode_fields/check_reserved，不改 active_bytes。
  // 输入/输出及副作用：model 只读，entry_size 为 profile，image 输出；成功时完整发布 bytes/length/
  //   alignment/endian/image_kind/hardware_version/function_generation。
  // 失败/边界：entry_size 非法、generation 无效，或 builder 分配/复位、编码、保留位检查、序列化、
  //   image 分配失败返回错误，image 为 null。
  virtual function rdma_status encode_with_entry_bytes(
      rdma_hw_model model,
      int unsigned entry_size,
      output rdma_hw_image image
  );
    rdma_hw_qword_builder builder;
    byte unsigned bytes[];
    rdma_hw_image candidate;
    rdma_status status;

    image = null;
    if (!(entry_size inside {32, 64, 128}))
      return err("CQE profile size is invalid");

    status = validate_model(model);
    if (status == null)
      return err("CQE model validation returned null");
    if (!status.ok())
      return status;

    builder = new("cqe_encode_profile");
    if (builder == null)
      return err("CQE profile builder allocation failed");

    status = builder.reset(entry_size);
    if (status == null)
      return err("CQE profile builder reset returned null");
    if (!status.ok()) begin
      if (status.message == "")
        return err("CQE profile builder reset failed");
      return err(status.message);
    end

    status = encode_fields(model, builder);
    if (status == null)
      return err("CQE field encode returned null");
    if (!status.ok())
      return status;

    status = check_reserved(builder);
    if (status == null)
      return err("CQE reserved check returned null");
    if (!status.ok())
      return err(status.message == "" ?
                 "CQE reserved check failed" : status.message);

    bytes = new[0];
    status = builder.serialize(bytes);
    if (status == null)
      return err("CQE profile serialize returned null");
    if (!status.ok())
      return err(status.message == "" ?
                 "CQE profile serialize failed" : status.message);
    if (bytes.size() != entry_size)
      return err("CQE profile serialize length is invalid");

    candidate = rdma_hw_image::type_id::create("cqe_profile_image");
    if (candidate == null)
      return err("CQE profile image allocation failed");
    foreach (bytes[i])
      candidate.bytes.push_back(bytes[i]);
    candidate.length = entry_size;
    candidate.alignment = entry_size;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_CQE;
    candidate.hardware_version = RDMA_HW_VERSION;
    candidate.function_generation = model_handle_generation(model);
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    image = candidate;
    return rdma_status::success();
  endfunction

  // 功能：按调用方指定的 CQE profile 校验 image metadata 和保留位，不依赖 active_bytes。
  // 输入/输出及副作用：image、entry_size 输入；使用临时 builder。
  // 失败/边界：entry_size 非法、metadata 不符、反序列化失败或保留位非零返回 CODEC_ERROR。
  virtual function rdma_status validate_image_with_entry_bytes(
      rdma_hw_image image,
      int unsigned entry_size
  );
    rdma_hw_qword_builder b;
    byte unsigned p[];
    rdma_status status;
    bit [63:0] sign_value;
    int unsigned base_offset;

    status = validate_cqe_image_metadata(image, entry_size);
    if (!status.ok())
      return status;
    p = new[entry_size];
    foreach (p[i]) p[i] = image.bytes[i];
    b = new("cqe_validate_profile");
    status = b.deserialize(p);
    if (status == null || !status.ok())
      return err(status == null ? "CQE image deserialize returned null" :
                 status.message);
    status = check_reserved(b);
    if (status == null || !status.ok())
      return status == null ? err("CQE reserved check returned null") : status;

    base_offset = (entry_size == 128) ? 64 : 0;
    sign_value = '0;
    status = b.get_field(
        base_offset + RDMA_CQE_SIGN_EN_WORD_BYTE_OFFSET,
        RDMA_CQE_SIGN_EN_LSB,
        RDMA_CQE_SIGN_EN_WIDTH,
        sign_value);
    if (status == null || !status.ok())
      return err(status == null ? "CQE SIGN_EN validation returned null" :
                 status.message);

    return validate_cqe_signature_bytes(
        p, entry_size, sign_value[0]);
  endfunction

  // 功能：按 image 自带长度选择 CQE profile，调用无状态解码入口。
  // 输入/输出及副作用：image 输入，model 输出；不改 active_bytes。
  // 失败/边界：image 为空或长度非 32/64/128 返回 CODEC_ERROR；下游错误原样传播，model 为空。
  virtual function rdma_status decode(rdma_hw_image image, output rdma_hw_model model);
    model = null;
    if (image == null || !(image.length inside {32, 64, 128}))
      return rdma_status::make(RDMA_SC_CODEC_ERROR, "CQE image size is invalid");
    return decode_with_entry_bytes(image, int'(image.length), model);
  endfunction
  // 功能：返回 RDMA_IMAGE_CQE。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_CQE;
  endfunction

  // 功能：返回当前 active profile 字节数（32/64/128，默认 64）。
  // 输入/输出及副作用：读取 active_bytes。
  // 失败/边界：无；set_entry_bytes 已拒绝非法尺寸。
  protected virtual function int unsigned image_bytes();
    return active_bytes;
  endfunction

  // 功能：按 profile 基址和 active_variant 校验 CQE 四个 header qword 的 reserved 位，保留合法 payload。
  // 输入/输出及副作用：只读 b、active_bytes、active_variant。
  // 失败/边界：builder 为空、qword 数/profile 不符、qword0/1/2 未声明位、非 UD 的 qword3 非零、
  //   128B 的 qword12..15 非零均返回 CODEC_ERROR。
  protected virtual function rdma_status check_reserved(
      rdma_hw_qword_builder b
  );
    bit [63:0] words[];
    int unsigned profile_bytes;
    int unsigned base_qword;

    if (b == null)
      return err("CQE qword builder is null");

    b.get_words(words);
    if (!(words.size() inside {4, 8, 16}))
      return err("CQE profile qword count is invalid");

    profile_bytes = words.size() << 3;
    base_qword = (profile_bytes == 128) ? 8 : 0;

    // 128B 的前缀是 inline payload 窗口，不是第二个 header。
    if ((words[base_qword] & ~RDMA_CQE_QWORD0_UNION_MASK) !== 64'b0)
      return err("CQE qword0 reserved bits are nonzero");
    if ((words[base_qword + 1] & ~RDMA_CQE_QWORD1_MASK) !== 64'b0)
      return err("CQE qword1 reserved bits are nonzero");

    // qword2 是物理 union，而非三套独立保留布局：驱动无 wire 判别位，从同一 word 读取 SIGNATURE、
    // RC_REMOTE_SYNDROME、UD_SRC_QPN 与 RQ/SRFQ 坐标；只有 [30:28] 不属于任何 wr.h 字段，保持保留。
    if ((words[base_qword + 2] & ~RDMA_CQE_QWORD2_UNION_MASK) !== 64'b0)
      return err("CQE qword2 reserved bits are nonzero");

    if (active_variant != RDMA_CQE_VARIANT_UD &&
        words[base_qword + 3] !== 64'b0)
      return err("CQE qword3 requires UD variant");
    if (active_variant == RDMA_CQE_VARIANT_UD &&
        (words[base_qword + 3] & ~RDMA_CQE_QWORD3_UD_MASK) !== 64'b0)
      return err("CQE qword3 reserved bits are nonzero");

    // 64B 的 qword4..7 与 128B 的 qword0..7/12..15 是 opaque profile 字节；wr.h/cq.h 未规定其必须为零，
    // raw 解码器不能自行加限制而拒绝设备产生的 payload。

    return rdma_status::success();
  endfunction

  // 功能：比较 decode 保存的完整 qword2 与所有物理 overlay 字段，防止字段被改后仍冒充原始 wire authority。
  // 输入/输出及副作用：只读 x 的 raw_qword2 与 signature/RC/UD/RQ 字段。
  // 失败/边界：raw authority 未设置返回成功；任一字段与原始坐标不符返回 CODEC_ERROR，
  //   调用方须先 clear_raw_qword2_authority 再编码。
  protected function rdma_status validate_raw_qword2_authority(
      rdma_hw_cqe_model x);
    if (x == null)
      return err("CQE model is null");
    if (!x.raw_qword2_valid)
      return rdma_status::success();

    if (x.raw_qword2[63:56] !== x.signature)
      return err("CQE raw qword2 signature authority is stale");
    if (x.raw_qword2[55:48] !== x.rc_remote_syndrome)
      return err("CQE raw qword2 RC syndrome authority is stale");
    if (x.raw_qword2[55:32] !== x.ud_src_qpn)
      return err("CQE raw qword2 UD QPN authority is stale");
    if (x.raw_qword2[31] !== x.rqe_cpl)
      return err("CQE raw qword2 RQE completion authority is stale");
    if (x.raw_qword2[27:16] !== x.srfqn)
      return err("CQE raw qword2 SRFQN authority is stale");
    if (x.raw_qword2[15] !== x.srfqe_wrap)
      return err("CQE raw qword2 SRFQ wrap authority is stale");
    if (x.raw_qword2[14:0] !== x.srfqe_index)
      return err("CQE raw qword2 SRFQ index authority is stale");

    return rdma_status::success();
  endfunction


  // 功能：按 profile 相对布局（从 qword0 或 qword8 起）把 CQE model 写入 builder。
  // 输入/输出及副作用：model 只读，b 为写入器；有签名的 typed 路径留空 signature 字节，由
  //   finalize_cqe_signature 派生。
  // 失败/边界：model 类型/字段/generation/保留位非法或 put 失败返回错误，不发布 image。
  protected virtual function rdma_status encode_fields(
      rdma_hw_model model,
      rdma_hw_qword_builder b
  );
    rdma_hw_cqe_model x;
    rdma_status status;
    bit [63:0] words[];
    int unsigned base_offset;
    int unsigned profile_bytes;
    rdma_cqe_variant_e variant;
    bit [31:0] immediate_value;
    int unsigned payload_capacity;
    int unsigned payload_offset;
    byte unsigned payload_bytes[];
    string field_name;

    if (!$cast(x, model))
      return err("CQE model type mismatch");

    variant = x.resolved_variant();
    if (variant > RDMA_CQE_VARIANT_RQ_SRFQ)
      return err("CQE variant is invalid");

    if (variant_is_explicit && active_variant != variant)
      return err("CQE codec/model variant mismatch");
    active_variant = variant;

    status = x.validate();
    if (!status.ok())
      return status;

    b.get_words(words);
    if (!(words.size() inside {4, 8, 16}))
      return err("CQE profile qword count is invalid");
    profile_bytes = words.size() << 3;
    base_offset = (words.size() == 16) ? 64 : 0;

    `define CQPUT(STEM, VALUE) \
      begin \
        field_name = "STEM"; \
        status = b.put_field(base_offset + STEM``_WORD_BYTE_OFFSET, \
                             STEM``_LSB, STEM``_WIDTH, VALUE); \
        if (!status.ok()) \
          return err($sformatf("CQE field %s: %s", field_name, \
                               status.message)); \
      end

    `CQPUT(RDMA_CQE_POLARITY, x.polarity)
    `CQPUT(RDMA_CQE_QP_ST, x.qp_state)
    `CQPUT(RDMA_CQE_RQ_CQE, x.rq_cqe)
    `CQPUT(RDMA_CQE_SRFQ, x.srfq)
    `CQPUT(RDMA_CQE_SE, x.se)
    `CQPUT(RDMA_CQE_SIGN_EN, x.sign_en)
    `CQPUT(RDMA_CQE_WQE_WRAP, x.wqe_wrap)
    `CQPUT(RDMA_CQE_WQE_INDEX, x.wqe_index)
    `CQPUT(RDMA_CQE_PKT_OPCODE, x.packet_opcode)
    `CQPUT(RDMA_CQE_ECODE, x.ecode)
    `CQPUT(RDMA_CQE_VLAN, x.vlan)
    `CQPUT(RDMA_CQE_IPV6, x.ipv6)
    `CQPUT(RDMA_CQE_CQE_FORMAT, x.cqe_format)
    `CQPUT(RDMA_CQE_RESIZE_CQE, x.resize_cqe)
    `CQPUT(RDMA_CQE_UD_MC, x.ud_mc)
    `CQPUT(RDMA_CQE_QPN, x.qpn)

    if (x.immediate_data != 0 && x.immdt_data_invld_key != 0 &&
        x.immediate_data != x.immdt_data_invld_key)
      return err("CQE immediate/key aliases disagree");
    immediate_value = (x.immdt_data_invld_key != 0) ?
                      x.immdt_data_invld_key : x.immediate_data;
    `CQPUT(RDMA_CQE_IMMDT_DATA, immediate_value)
    `CQPUT(RDMA_CQE_PAYLOAD_LEN, x.payload_len)

    if (x.raw_qword2_valid) begin
      status = validate_raw_qword2_authority(x);
      if (!status.ok())
        return status;
      status = b.put_field(base_offset + RDMA_CQE_SIGNATURE_WORD_BYTE_OFFSET,
                           0, 64, x.raw_qword2);
      if (!status.ok())
        return err(status.message);
    end
    else begin
      // wr.c 仅在 SIGN_EN 置位时验证整个 entry：有签名的 typed 路径留空该字节，由 finalize_cqe_signature
      // 依最终 header 与 opaque payload 派生；无签名 image 保留调用方给的 signature 字节。
      if (!x.sign_en)
        `CQPUT(RDMA_CQE_SIGNATURE, x.signature)

      case (variant)
        RDMA_CQE_VARIANT_RC:
          `CQPUT(RDMA_CQE_RC_REMOTE_SYNDROME, x.rc_remote_syndrome)
        RDMA_CQE_VARIANT_UD:
          `CQPUT(RDMA_CQE_UD_SRC_QPN, x.ud_src_qpn)
        RDMA_CQE_VARIANT_RQ_SRFQ: begin
          `CQPUT(RDMA_CQE_RQE_CPL, x.rqe_cpl)
          `CQPUT(RDMA_CQE_SRFQN, x.srfqn)
          `CQPUT(RDMA_CQE_SRFQE_WRAP, x.srfqe_wrap)
          `CQPUT(RDMA_CQE_SRFQE_INDEX, x.srfqe_index)
        end
        default:
          return err("CQE variant is invalid");
      endcase
    end

    if (variant == RDMA_CQE_VARIANT_UD) begin
      `CQPUT(RDMA_CQE_UD_SMAC, x.ud_smac)
      `CQPUT(RDMA_CQE_UD_VLAN_TAG, x.ud_vlan_tag)
    end

    `undef CQPUT

    payload_capacity = 0;
    payload_offset = 0;
    case (profile_bytes)
      64: begin
        payload_capacity = RDMA_CQE_64B_PAYLOAD_BYTES;
        payload_offset = RDMA_CQE_64B_PAYLOAD_BYTE_OFFSET;
      end
      128: begin
        payload_capacity = RDMA_CQE_128B_PAYLOAD_BYTES;
        payload_offset = RDMA_CQE_128B_PAYLOAD_BYTE_OFFSET;
      end
      default: begin
        payload_capacity = 0;
        payload_offset = 0;
      end
    endcase

    if (x.payload.size() > payload_capacity)
      return err("CQE detached payload exceeds profile window");
    if (x.payload.size() != 0 && x.payload.size() != x.payload_len)
      return err("CQE detached payload length disagrees with payload_len");

    if (x.payload.size() != 0) begin
      payload_bytes = new[x.payload.size()];
      foreach (x.payload[i])
        payload_bytes[i] = x.payload[i];
      status = b.put_memcpy(payload_offset, payload_bytes);
      if (!status.ok())
        return err(status.message);
    end

    status = finalize_cqe_signature(
        b, profile_bytes, x.sign_en, x.raw_qword2_valid);
    if (!status.ok())
      return status;

    return rdma_status::success();
  endfunction
  // 功能：从 profile 相对窗口（qword0 或 qword8 起）解码 CQE 字段为 detached model。
  // 输入/输出及副作用：b 只读，model 输出；解出 qword2 的所有物理 overlay 并保存 raw authority。
  // 失败/边界：b 为空、布局/保留位非法或字段读取失败返回错误，model 保持 null。
  protected virtual function rdma_status decode_fields(
      rdma_hw_qword_builder b,
      output rdma_hw_model model
  );
    rdma_hw_cqe_model x;
    bit [63:0] v;
    bit [63:0] words[];
    int unsigned base_offset;
    int unsigned profile_bytes;
    rdma_status status;
    int unsigned payload_capacity;
    int unsigned payload_offset;
    int unsigned payload_count;

    x = rdma_hw_cqe_model::type_id::create("decoded_cqe");
    x.qp_h = rdma_hw_queue_projected_handle("decoded_qp", RDMA_RESOURCE_QP, 0);
    b.get_words(words);
    if (!(words.size() inside {4, 8, 16}))
      return err("CQE profile qword count is invalid");
    profile_bytes = words.size() << 3;
    base_offset = (words.size() == 16) ? 64 : 0;
    x.variant = active_variant;
    x.raw_qword2_valid = 1'b1;
    x.raw_qword2 = words[(base_offset >> 3) + 2];

    `define CQGET(STEM, TARGET) \
      begin \
        v = '0; \
        status = b.get_field(base_offset + STEM``_WORD_BYTE_OFFSET, \
                             STEM``_LSB, STEM``_WIDTH, v); \
        if (!status.ok()) \
          return err(status.message); \
        TARGET = v; \
      end

    `CQGET(RDMA_CQE_POLARITY, x.polarity)
    `CQGET(RDMA_CQE_QP_ST, x.qp_state)
    `CQGET(RDMA_CQE_RQ_CQE, x.rq_cqe)
    `CQGET(RDMA_CQE_SRFQ, x.srfq)
    `CQGET(RDMA_CQE_SE, x.se)
    `CQGET(RDMA_CQE_SIGN_EN, x.sign_en)
    `CQGET(RDMA_CQE_WQE_WRAP, x.wqe_wrap)
    `CQGET(RDMA_CQE_WQE_INDEX, x.wqe_index)
    `CQGET(RDMA_CQE_PKT_OPCODE, x.packet_opcode)
    `CQGET(RDMA_CQE_ECODE, x.ecode)
    `CQGET(RDMA_CQE_VLAN, x.vlan)
    `CQGET(RDMA_CQE_IPV6, x.ipv6)
    `CQGET(RDMA_CQE_CQE_FORMAT, x.cqe_format)
    `CQGET(RDMA_CQE_RESIZE_CQE, x.resize_cqe)
    `CQGET(RDMA_CQE_UD_MC, x.ud_mc)
    `CQGET(RDMA_CQE_QPN, x.qpn)
    `CQGET(RDMA_CQE_IMMDT_DATA, x.immediate_data)
    x.immdt_data_invld_key = x.immediate_data;
    `CQGET(RDMA_CQE_PAYLOAD_LEN, x.payload_len)
    `CQGET(RDMA_CQE_SIGNATURE, x.signature)

    // qword2 被三种驱动视图物理共享：解出每个已声明坐标，以便 raw authority 之后能证明 image 无损；
    // 显式 variant 只决定语义使用方。
    `CQGET(RDMA_CQE_RC_REMOTE_SYNDROME, x.rc_remote_syndrome)
    `CQGET(RDMA_CQE_UD_SRC_QPN, x.ud_src_qpn)
    `CQGET(RDMA_CQE_RQE_CPL, x.rqe_cpl)
    `CQGET(RDMA_CQE_SRFQN, x.srfqn)
    `CQGET(RDMA_CQE_SRFQE_WRAP, x.srfqe_wrap)
    `CQGET(RDMA_CQE_SRFQE_INDEX, x.srfqe_index)

    if (active_variant == RDMA_CQE_VARIANT_UD) begin
      `CQGET(RDMA_CQE_UD_SMAC, x.ud_smac)
      `CQGET(RDMA_CQE_UD_VLAN_TAG, x.ud_vlan_tag)
    end

    `undef CQGET

    payload_capacity = 0;
    payload_offset = 0;
    case (profile_bytes)
      64: begin
        payload_capacity = RDMA_CQE_64B_PAYLOAD_BYTES;
        payload_offset = RDMA_CQE_64B_PAYLOAD_BYTE_OFFSET;
      end
      128: begin
        payload_capacity = RDMA_CQE_128B_PAYLOAD_BYTES;
        payload_offset = RDMA_CQE_128B_PAYLOAD_BYTE_OFFSET;
      end
      default: begin
        payload_capacity = 0;
        payload_offset = 0;
      end
    endcase

    payload_count = (x.payload_len < payload_capacity) ?
                    x.payload_len : payload_capacity;
    x.payload.delete();
    for (int unsigned i = 0; i < payload_count; i++)
      x.payload.push_back(words[(payload_offset + i) >> 3]
                           [63 - (((payload_offset + i) & 7) << 3) -: 8]);

    status = x.validate();
    if (!status.ok())
      return status;
    x.status = rdma_status::type_id::create("decoded_status");
    model = x;
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_ceqe_codec extends rdma_hw_queue_codec_base;
  `rdma_object_utils(rdma_hw_ceqe_codec)

  // 功能：构造 CEQE codec。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_ceqe_codec");
    super.new(name);
  endfunction

  // 功能：返回 RDMA_IMAGE_CEQE。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_CEQE;
  endfunction

  // 功能：返回 CEQE entry 固定大小 RDMA_CEQE_BYTES（16B）。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  protected virtual function int unsigned image_bytes();
    return RDMA_CEQE_BYTES;
  endfunction

  // 功能：只拒绝驱动真正保留的位，允许 RC/URC overlay 在同一 wire image 中同时出现。
  // 输入/输出及副作用：按驱动 union mask 检查 b 的 qword0/qword1，不改 b。
  // 失败/边界：builder 为空、qword 数错误或 union mask 之外有位非零返回 CODEC_ERROR；
  //   URC_FLAG 不再作为 canonical-zero 的拒绝条件。
  protected virtual function rdma_status check_reserved(
      rdma_hw_qword_builder b);
    bit [63:0] words[];
    bit [63:0] qword0_mask;
    bit [63:0] qword1_mask;

    if (b == null)
      return err("CEQE qword builder is null");

    b.get_words(words);
    if (words.size() != 2)
      return err("CEQE image must contain two qwords");

    // event.c 的 xtrdma_get_ceqe_info() 无条件 FIELD_GET 两个 overlay；
    // qword1_URC_MASK 覆盖 qword1[57:0]，其中含 RC CI 的重叠坐标。
    qword0_mask = RDMA_CEQE_QWORD0_UNION_MASK;
    qword1_mask = RDMA_CEQE_QWORD1_RC_MASK |
                  RDMA_CEQE_QWORD1_URC_MASK;

    if ((words[0] & ~qword0_mask) !== 64'b0 ||
        (words[1] & ~qword1_mask) !== 64'b0)
      return err("CEQE reserved bits are nonzero");

    return rdma_status::success();
  endfunction

  // 功能：按 defs.h 的 URC abnormal、SQ/RQ completion 字段构造 qword1 的 URC 视图（不含 RC CI alias）。
  // 输入/输出及副作用：只读 x，返回逻辑 qword1。
  // 失败/边界：x 为空返回 0；物理 alias 冲突由 build_model_qword1 判断。
  protected function bit [63:0] build_urc_qword1(
      rdma_hw_ceqe_model x);
    bit [63:0] value;

    value = '0;
    if (x == null)
      return value;

    value[RDMA_CEQE_URC_ABNML_CQE_TYPE_LSB +:
          RDMA_CEQE_URC_ABNML_CQE_TYPE_WIDTH] =
        x.urc_abnormal_cqe_type;
    value[RDMA_CEQE_URC_ABNML_CQE_REMOTE_ECODE_LSB +:
          RDMA_CEQE_URC_ABNML_CQE_REMOTE_ECODE_WIDTH] =
        x.urc_abnormal_cqe_remote_ecode;
    value[RDMA_CEQE_URC_ABNML_CQE_WQE_IDX_WRAP_LSB] =
        x.urc_abnormal_cqe_wqe_idx_wrap;
    value[RDMA_CEQE_URC_ABNML_CQE_WQE_IDX_LSB +:
          RDMA_CEQE_URC_ABNML_CQE_WQE_IDX_WIDTH] =
        x.urc_abnormal_cqe_wqe_idx;
    value[RDMA_CEQE_URC_HW_CPL_SQ_WQE_IDX_WRAP_LSB] =
        x.urc_hw_cpl_sq_wqe_idx_wrap;
    value[RDMA_CEQE_URC_HW_CPL_SQ_WQE_IDX_LSB +:
          RDMA_CEQE_URC_HW_CPL_SQ_WQE_IDX_WIDTH] =
        x.urc_hw_cpl_sq_wqe_idx;
    value[RDMA_CEQE_URC_HW_CPL_RQ_WQE_IDX_WRAP_LSB] =
        x.urc_hw_cpl_rq_wqe_idx_wrap;
    value[RDMA_CEQE_URC_HW_CPL_RQ_WQE_IDX_LSB +:
          RDMA_CEQE_URC_HW_CPL_RQ_WQE_IDX_WIDTH] =
        x.urc_hw_cpl_rq_wqe_idx;
    return value;
  endfunction

  // 功能：按 RC_CQ_PI_WRAP/RC_CQ_PI 坐标构造仅含 RC alias 的 qword1 视图。
  // 输入/输出及副作用：只读 x，返回逻辑 qword1。
  // 失败/边界：x 为空返回 0。
  protected function bit [63:0] build_rc_qword1(
      rdma_hw_ceqe_model x);
    bit [63:0] value;

    value = '0;
    if (x == null)
      return value;

    value[RDMA_CEQE_CQ_PI_WRAP_LSB] = x.cq_pi_wrap;
    value[RDMA_CEQE_CQ_PI_LSB +: RDMA_CEQE_CQ_PI_WIDTH] = x.cq_pi;
    return value;
  endfunction

  // 功能：检查 CEQE model 已绑定唯一 routed CQ transport，且 wire URC_FLAG 与之一致。
  // 输入/输出及副作用：只读 profile authority 与 urc_flag，返回状态。
  // 失败/边界：authority 未设置、transport 非 RC/UD/URC 或 selector 与 URC profile 不符均 fail-closed；
  //   不从默认枚举值或 qword alias 猜 profile。
  protected function rdma_status validate_profile_authority(
      rdma_hw_ceqe_model x);
    if (x == null)
      return err("CEQE model is null");
    if (!x.profile_transport_valid)
      return err("CEQE canonical profile authority is missing");
    if (!(x.profile_transport inside {RDMA_TRANSPORT_RC,
                                      RDMA_TRANSPORT_UD,
                                      RDMA_TRANSPORT_URC}))
      return err("CEQE canonical profile transport is invalid");
    if (x.urc_flag !== (x.profile_transport == RDMA_TRANSPORT_URC))
      return err("CEQE URC selector disagrees with routed profile");
    return rdma_status::success();
  endfunction

  // 功能：拒绝 canonical authoring 中不属于当前 routed profile 的 qword1 语义字段，避免 union mask 变成写权限。
  // 输入/输出及副作用：只读 x 的 URC/RC alias 字段，返回状态。
  // 失败/边界：RC/UD profile 不能带 URC-only 字段，URC profile 不能带 RC CQ_PI alias；
  //   仅用于新 authoring，raw replay 走显式通道。
  protected function rdma_status validate_canonical_overlay_fields(
      rdma_hw_ceqe_model x);
    bit [63:0] urc_word;

    if (x == null)
      return err("CEQE model is null");
    urc_word = build_urc_qword1(x);
    if (x.profile_transport == RDMA_TRANSPORT_URC) begin
      if (x.cq_pi != 0 || x.cq_pi_wrap != 0)
        return err("CEQE URC profile cannot author RC CQ_PI fields");
    end
    else begin
      if (x.urc_sq_cqe_valid || x.urc_rq_cqe_valid)
        return err("CEQE RC/UD profile cannot author URC qword0 fields");
      if (urc_word != 0)
        return err("CEQE RC/UD profile cannot author URC qword1 fields");
    end
    return rdma_status::success();
  endfunction

  // 功能：按 profile 选择 RC 或 URC alias 构造 qword1，并阻止两个物理重叠视图被静默合并。
  // 输入/输出及副作用：只读 x，返回可序列化 qword1。
  // 失败/边界：inactive 视图的 alias 为零视为未声明；两个非零 alias 不一致返回 CODEC_ERROR。
  protected function rdma_status build_model_qword1(
      rdma_hw_ceqe_model x,
      output bit [63:0] qword1);
    bit [63:0] urc_word;
    bit [63:0] rc_word;
    rdma_status status;

    qword1 = '0;
    if (x == null)
      return err("CEQE model is null");

    status = validate_profile_authority(x);
    if (!status.ok())
      return status;
    status = validate_canonical_overlay_fields(x);
    if (!status.ok())
      return status;

    urc_word = build_urc_qword1(x);
    rc_word = build_rc_qword1(x);
    if (x.urc_flag)
      qword1 = urc_word;
    else
      qword1 = rc_word;

    return rdma_status::success();
  endfunction

  // 功能：确认 decode 保存的原始 qword1 仍与 model 字段一致，防止字段被改后被悄然忽略。
  // 输入/输出及副作用：只读比较 raw_qword1 与两套字段，返回状态。
  // 失败/边界：raw authority 未设置返回成功；任一 mismatch 返回 CODEC_ERROR，
  //   调用方须先 clear_raw_qword1_authority 再重选 alias。
  protected function rdma_status validate_raw_qword1_authority(
      rdma_hw_ceqe_model x);
    bit [63:0] urc_word;
    bit [63:0] rc_word;
    bit [63:0] alias_mask;

    if (x == null)
      return err("CEQE model is null");
    if (!x.raw_qword1_valid)
      return rdma_status::success();

    urc_word = build_urc_qword1(x);
    rc_word = build_rc_qword1(x);
    alias_mask = RDMA_CEQE_QWORD1_RC_MASK;
    if ((x.raw_qword1 & RDMA_CEQE_QWORD1_URC_MASK) !=
        (urc_word & RDMA_CEQE_QWORD1_URC_MASK))
      return err("CEQE raw qword1 URC authority is stale");
    if ((x.raw_qword1 & alias_mask) != (rc_word & alias_mask))
      return err("CEQE raw qword1 RC authority is stale");

    return rdma_status::success();
  endfunction

  // 功能：把 CEQE model 写入 builder：raw replay 模式原样写 raw qword，否则按 canonical 字段编码。
  // 输入/输出及副作用：model 只读，b 为写入器。
  // 失败/边界：类型不符、builder 为空、model/profile 校验失败、raw 未授权或 put 失败返回错误，不发布 image。
  protected virtual function rdma_status encode_fields(
      rdma_hw_model model,
      rdma_hw_qword_builder b
  );
    rdma_hw_ceqe_model x;
    rdma_status status;
    bit [63:0] qword1;

    if (!$cast(x, model))
      return err("CEQE model type mismatch");
    if (b == null)
      return err("CEQE qword builder is null");

    status = x.validate();
    if (!status.ok())
      return status;

    status = validate_profile_authority(x);
    if (!status.ok())
      return status;

    `define CEQE_PUT(STEM, VALUE) \
      status = b.put_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                           STEM``_WIDTH, VALUE); \
      if (!status.ok()) \
        return err(status.message);

    `CEQE_PUT(RDMA_CEQE_VALID, x.valid)
    `CEQE_PUT(RDMA_CEQE_URC_FLAG, x.urc_flag)
    `CEQE_PUT(RDMA_CEQE_QPN, x.qpn)
    `CEQE_PUT(RDMA_CEQE_CQN, x.cqn)
    `CEQE_PUT(RDMA_CEQE_ECODE, x.ecode)
    `CEQE_PUT(RDMA_CEQE_PKT_OPCODE, x.packet_opcode)

    // qword0 的 URC selector/valid 位也是驱动持有的 wire 字段，即使 selector 为 RC 也不能被规整成零。
    `CEQE_PUT(RDMA_CEQE_URC_SQ_CQE_VALID, x.urc_sq_cqe_valid)
    `CEQE_PUT(RDMA_CEQE_URC_RQ_CQE_VALID, x.urc_rq_cqe_valid)

    if (x.raw_qword1_valid) begin
      if (!x.raw_qword1_replay_authorized)
        return err("CEQE raw qword1 replay requires explicit authority");
      status = validate_raw_qword1_authority(x);
      if (!status.ok())
        return status;
      qword1 = x.raw_qword1;
    end
    else begin
      status = build_model_qword1(x, qword1);
      if (!status.ok())
        return status;
    end

    status = b.put_field(RDMA_CEQE_CQ_PI_WORD_BYTE_OFFSET, 0, 64, qword1);
    if (!status.ok())
      return err(status.message);

    `undef CEQE_PUT
    return rdma_status::success();
  endfunction

  // 功能：把 builder 解码为 detached CEQE model，并保存 raw qword1 authority。
  // 输入/输出及副作用：b 只读，model 输出。
  // 失败/边界：builder 为空或字段读取失败返回错误，model 保持 null。
  protected virtual function rdma_status decode_fields(
      rdma_hw_qword_builder b,
      output rdma_hw_model model
  );
    rdma_hw_ceqe_model x;
    bit [63:0] value;
    bit [63:0] words[];
    rdma_status status;

    model = null;
    if (b == null)
      return err("CEQE qword builder is null");

    x = rdma_hw_ceqe_model::type_id::create("decoded_ceqe");
    if (x == null)
      return err("CEQE model allocation failed");
    x.cq_h = rdma_hw_queue_projected_handle(
        "decoded_cq", RDMA_RESOURCE_CQ, 0);

    `define CEQE_GET(STEM, TARGET) \
      value = '0; \
      status = b.get_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                           STEM``_WIDTH, value); \
      if (status == null || !status.ok()) \
        return err(status == null ? "CEQE field read returned null status" : \
                   status.message); \
      TARGET = value;

    `CEQE_GET(RDMA_CEQE_VALID, x.valid)
    `CEQE_GET(RDMA_CEQE_URC_FLAG, x.urc_flag)
    `CEQE_GET(RDMA_CEQE_QPN, x.qpn)
    `CEQE_GET(RDMA_CEQE_CQN, x.cqn)
    `CEQE_GET(RDMA_CEQE_ECODE, x.ecode)
    `CEQE_GET(RDMA_CEQE_PKT_OPCODE, x.packet_opcode)

    // event.c 无条件解码 RC/URC overlay：同一 raw image 的两种解释都要发布到 detached model，
    // 不能因 selector 丢弃 inactive 位。
    `CEQE_GET(RDMA_CEQE_URC_SQ_CQE_VALID, x.urc_sq_cqe_valid)
    `CEQE_GET(RDMA_CEQE_URC_RQ_CQE_VALID, x.urc_rq_cqe_valid)
    `CEQE_GET(RDMA_CEQE_URC_ABNML_CQE_TYPE,
              x.urc_abnormal_cqe_type)
    `CEQE_GET(RDMA_CEQE_URC_ABNML_CQE_REMOTE_ECODE,
              x.urc_abnormal_cqe_remote_ecode)
    `CEQE_GET(RDMA_CEQE_URC_ABNML_CQE_WQE_IDX_WRAP,
              x.urc_abnormal_cqe_wqe_idx_wrap)
    `CEQE_GET(RDMA_CEQE_URC_ABNML_CQE_WQE_IDX,
              x.urc_abnormal_cqe_wqe_idx)
    `CEQE_GET(RDMA_CEQE_URC_HW_CPL_SQ_WQE_IDX_WRAP,
              x.urc_hw_cpl_sq_wqe_idx_wrap)
    `CEQE_GET(RDMA_CEQE_URC_HW_CPL_SQ_WQE_IDX,
              x.urc_hw_cpl_sq_wqe_idx)
    `CEQE_GET(RDMA_CEQE_URC_HW_CPL_RQ_WQE_IDX_WRAP,
              x.urc_hw_cpl_rq_wqe_idx_wrap)
    `CEQE_GET(RDMA_CEQE_URC_HW_CPL_RQ_WQE_IDX,
              x.urc_hw_cpl_rq_wqe_idx)
    `CEQE_GET(RDMA_CEQE_CQ_PI_WRAP, x.cq_pi_wrap)
    `CEQE_GET(RDMA_CEQE_CQ_PI, x.cq_pi)

    b.get_words(words);
    x.raw_qword1_valid = 1'b1;
    x.raw_qword1 = words[1];

    `undef CEQE_GET
    model = x;
    return rdma_status::success();
  endfunction
endclass

class rdma_hw_aeqe_codec extends rdma_hw_queue_codec_base;
  `rdma_object_utils(rdma_hw_aeqe_codec)

  // 功能：构造 AEQE codec。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_aeqe_codec");
    super.new(name);
  endfunction

  // 功能：返回 RDMA_IMAGE_AEQE。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_AEQE;
  endfunction

  // 功能：返回 AEQE entry 固定大小 RDMA_AEQE_BYTES（16B）。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  protected virtual function int unsigned image_bytes();
    return RDMA_AEQE_BYTES;
  endfunction

  // 功能：检查 AEQE 两个 qword 的 reserved 位。
  // 输入/输出及副作用：只读 b。
  // 失败/边界：builder 为空、qword 数不是 2 或 mask 之外有位非零返回 CODEC_ERROR。
  protected virtual function rdma_status check_reserved(
      rdma_hw_qword_builder b);
    bit [63:0] words[];

    if (b == null)
      return err("AEQE qword builder is null");

    b.get_words(words);
    if (words.size() != 2)
      return err("AEQE image must contain two qwords");
    if ((words[0] & ~RDMA_AEQE_QWORD0_MASK) !== 64'b0 ||
        (words[1] & ~RDMA_AEQE_QWORD1_MASK) !== 64'b0)
      return err("AEQE reserved bits are nonzero");

    return rdma_status::success();
  endfunction

  // 功能：确认 AEQE model 可作为 wire/raw observation 处理，保留 event.c 无条件 FIELD_GET 的 inactive overlay。
  // 输入/输出及副作用：只确认对象存在，不改任何字段。
  // 失败/边界：x 为空返回 CODEC_ERROR；3-bit QP_ST 的 0..7 均可 decode/显式 replay，
  //   URC_FLAG 或 SRFQ_EN 关闭时 inactive 字段原样保留；canonical 限制由 validate_canonical_fields 执行。
  protected function rdma_status validate_variant_fields(
      rdma_hw_aeqe_model x);
    if (x == null)
      return err("AEQE variant model is null");

    return rdma_status::success();
  endfunction

  // 功能：检查 AEQE canonical model 绑定的 class/owner authority 与 event.c 的 ecode 分派一致。
  // 输入/输出及副作用：只读 ecode、profile class 与 owner kind，返回状态。
  // 失败/边界：authority 缺失、class 与 ecode 不符、owner kind 不属于该 class 或 target_h kind 与 owner 不符
  //   均 fail-closed；不从 srfq_en、urc_flag 或默认枚举猜 owner。
  protected function rdma_status validate_profile_authority(
      rdma_hw_aeqe_model x);
    rdma_aeqe_event_class_e expected_class;
    bit valid_owner;

    if (x == null)
      return err("AEQE model is null");
    if (!x.profile_class_valid || !x.profile_owner_valid)
      return err("AEQE canonical owner authority is missing");

    expected_class = rdma_aeqe_event_class_from_ecode(x.ecode);
    if (x.profile_class != expected_class)
      return err("AEQE profile class disagrees with driver ecode");

    valid_owner = 1'b0;
    case (expected_class)
      RDMA_AEQE_EVENT_QP:
        valid_owner = x.profile_owner_kind == RDMA_RESOURCE_QP;
      RDMA_AEQE_EVENT_SRQ:
        valid_owner = x.profile_owner_kind == RDMA_RESOURCE_SRQ;
      RDMA_AEQE_EVENT_CQ:
        valid_owner = x.profile_owner_kind == RDMA_RESOURCE_CQ;
      RDMA_AEQE_EVENT_EQ:
        valid_owner = x.profile_owner_kind inside {RDMA_RESOURCE_CEQ,
                                                   RDMA_RESOURCE_AEQ};
      RDMA_AEQE_EVENT_DIAGNOSTIC:
        valid_owner = x.profile_owner_kind == RDMA_RESOURCE_FUNCTION;
      RDMA_AEQE_EVENT_FLUSH:
        valid_owner = x.profile_owner_kind inside {RDMA_RESOURCE_FUNCTION,
                                                   RDMA_RESOURCE_QP};
      default:
        valid_owner = 1'b0;
    endcase

    if (!valid_owner)
      return err("AEQE profile owner kind disagrees with driver class");
    // event.c 的两个 flush case 与 CEQ/AEQ case 还固定了 owner kind：class 级允许集合
    // 不能把 0x08 错发到 Function，或把 0xfb 错发到 CEQ。
    case (x.ecode)
      8'h07:
        if (x.profile_owner_kind != RDMA_RESOURCE_FUNCTION)
          return err("AEQE TX flush requires Function owner");
      8'h08:
        if (x.profile_owner_kind != RDMA_RESOURCE_QP)
          return err("AEQE QP flush requires QP owner");
      8'hf7,
      8'hf8:
        if (x.profile_owner_kind != RDMA_RESOURCE_CEQ)
          return err("AEQE CEQ event requires CEQ owner");
      8'hfb:
        if (x.profile_owner_kind != RDMA_RESOURCE_AEQ)
          return err("AEQE AEQ event requires AEQ owner");
      default:
        begin
        end
    endcase
    if (x.target_h != null && x.target_h.kind != x.profile_owner_kind)
      return err("AEQE target kind disagrees with profile owner");
    return rdma_status::success();
  endfunction

  // 功能：按 rdma_defs.svh 的固定坐标重组 AEQE qword0，用于 raw replay 前确认 typed 字段未被改写。
  // 输入/输出及副作用：只读 x，返回 64 位物理 qword；坐标对应 0.1.34 event.c 的 FIELD_GET。
  // 失败/边界：x 为空返回 0；不做 reserved 检查，调用方须先过 check_reserved。
  protected function bit [63:0] build_typed_qword0(
      rdma_hw_aeqe_model x);
    bit [63:0] value;

    value = '0;
    if (x == null)
      return value;

    value[63] = x.valid;
    value[62:60] = x.qp_state;
    value[59] = x.srfq_en;
    value[58] = x.overflow_flag;
    value[57] = x.urc_flag;
    value[56] = x.cq_invalid_flag;
    value[55:54] = x.urc_abnormal_cqe_type;
    value[52:40] = x.cqn_eqn_high;
    value[39:32] = x.packet_opcode;
    value[31:24] = x.ecode;
    value[23:18] = x.cqn_eqn_low;
    value[17:0] = x.qpn;
    return value;
  endfunction

  // 功能：按 event.h 的 URC/SRFQ overlay 坐标重组 AEQE qword1，供 raw replay 一致性检查与 canonical 编码。
  // 输入/输出及副作用：只读 x，返回 64 位物理 qword。
  // 失败/边界：x 为空返回 0；inactive selector 不自动清零，因为 event.c 无条件 FIELD_GET 这些字段。
  protected function bit [63:0] build_typed_qword1(
      rdma_hw_aeqe_model x);
    bit [63:0] value;

    value = '0;
    if (x == null)
      return value;

    value[63:56] = x.urc_remote_ecode;
    value[55] = x.wqe_wrap;
    value[54:32] = x.wqe_index;
    value[27:16] = x.srfqn;
    value[15:0] = x.srfqe_idx;
    return value;
  endfunction

  // 功能：比较 decode 保存的原始 qword 与 typed 字段，防止改字段后仍以 raw replay 名义覆盖新值。
  // 输入/输出及副作用：只读 x，返回状态。
  // 失败/边界：raw authority 未设置返回 INVALID_STATE；任一 qword 不符返回 CODEC_ERROR，
  //   调用方须 clear_raw_authority 后重选 canonical profile。
  protected function rdma_status validate_raw_authority(
      rdma_hw_aeqe_model x);
    if (x == null)
      return err("AEQE model is null");
    if (!x.raw_qwords_valid)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "AEQE raw qword authority is missing");
    if (x.raw_qword0 != build_typed_qword0(x) ||
        x.raw_qword1 != build_typed_qword1(x))
      return err("AEQE raw qword authority is stale");
    return rdma_status::success();
  endfunction

  // 功能：按 event.c 的 ecode class 与 CQ-flush/URC-abnormal subselector 建立 canonical 字段 allowlist，
  //   把 QP_ST、packet_opcode、SRFQ_EN、CQ-invalid 限制到各自 owner；overflow 仅允许 raw observation。
  // 输入/输出及副作用：x 已通过 profile authority；只读 header flags、object ID 与 URC payload。
  // 失败/边界：QP_ST=6/7、canonical overflow、非所属 class 的 header/object/payload、TX-flush QPN、
  //   非 flush CQ 的 secondary QPN、URC subtype=3，以及非 CQ/非 URC-abnormal subtype 1/2 带 packet_opcode
  //   均返回 CODEC_ERROR；SRQ route 不依赖 srfq_en；显式 raw replay 已提前分流。
  protected function rdma_status validate_canonical_fields(
      rdma_hw_aeqe_model x);
    bit has_qpn;
    bit has_split_id;
    bit has_srq_fields;
    bit has_urc_payload;

    if (x == null)
      return err("AEQE model is null");

    if (x.qp_state > 3'd5)
      return err("AEQE canonical QP state is outside driver enum");

    // packet_opcode 仅 CQ 或 QP URC-abnormal subtype 1/2 有写权；event.c 的无条件 FIELD_GET 不允许其他
    // class/subselector 借用该坐标，调用方给的非零值必须拒绝而不是静默清除。
    if (x.packet_opcode != 0 &&
        !(x.profile_class == RDMA_AEQE_EVENT_CQ ||
          (x.profile_class == RDMA_AEQE_EVENT_QP && x.urc_flag &&
           x.urc_abnormal_cqe_type inside {2'b01, 2'b10})))
      return err("AEQE canonical event does not own packet opcode");

    has_qpn = x.qpn != 0;
    has_split_id = x.cqn_eqn_high != 0 || x.cqn_eqn_low != 0;
    has_srq_fields = x.srfqn != 0 || x.srfqe_idx != 0;
    has_urc_payload = x.urc_abnormal_cqe_type != 0 ||
                      x.urc_remote_ecode != 0 ||
                      x.wqe_wrap || x.wqe_index != 0;

    // event.c 的无条件 FIELD_GET 只是 raw 观测权；canonical 新建事件须按 class 声明 header 字段，
    // 不得以物理坐标共享代替写权。
    if (x.overflow_flag)
      return err("AEQE canonical event cannot author overflow flag");

    case (x.profile_class)
      RDMA_AEQE_EVENT_QP: begin
        if (x.srfq_en || x.cq_invalid_flag)
          return err("AEQE QP class contains non-QP header fields");
        if (has_split_id || has_srq_fields)
          return err("AEQE QP class cannot author CQ/EQ or SRQ fields");
        if (!x.urc_flag && has_urc_payload)
          return err("AEQE QP class cannot author inactive URC fields");
        if (x.urc_flag && x.urc_abnormal_cqe_type == 2'b11)
          return err("AEQE URC abnormal subtype is invalid");
        if (x.urc_flag && x.urc_abnormal_cqe_type == 2'b00 &&
            (x.urc_remote_ecode != 0 || x.wqe_wrap || x.wqe_index != 0))
          return err("AEQE normal URC subtype cannot author abnormal payload");
      end

      RDMA_AEQE_EVENT_SRQ: begin
        if (x.qp_state != 0 || x.cq_invalid_flag)
          return err("AEQE SRQ class contains non-SRQ header fields");
        if (has_qpn || has_split_id || x.urc_flag || has_urc_payload)
          return err("AEQE SRQ class contains non-SRQ owner fields");
      end

      RDMA_AEQE_EVENT_CQ: begin
        if (x.qp_state != 0 || x.srfq_en)
          return err("AEQE CQ class contains non-CQ header fields");
        if (has_srq_fields || x.urc_flag || has_urc_payload)
          return err("AEQE CQ class contains SRQ or URC fields");
        if (has_qpn && x.packet_opcode[4:0] != 5'h1d)
          return err("AEQE CQ QPN requires the flush packet subselector");
      end

      RDMA_AEQE_EVENT_EQ: begin
        if (x.qp_state != 0 || x.srfq_en || x.cq_invalid_flag)
          return err("AEQE EQ class contains object header fields");
        if (has_qpn || has_srq_fields || x.urc_flag || has_urc_payload)
          return err("AEQE EQ class contains QP, SRQ or URC fields");
      end

      RDMA_AEQE_EVENT_DIAGNOSTIC: begin
        if (x.qp_state != 0 || x.srfq_en || x.cq_invalid_flag)
          return err("AEQE diagnostic class contains object header fields");
        if (has_qpn || has_split_id || has_srq_fields ||
            x.urc_flag || has_urc_payload)
          return err("AEQE diagnostic class cannot author object fields");
      end

      RDMA_AEQE_EVENT_FLUSH: begin
        if (x.qp_state != 0 || x.srfq_en || x.cq_invalid_flag)
          return err("AEQE flush class contains object header fields");
        if (has_split_id || has_srq_fields ||
            x.urc_flag || has_urc_payload)
          return err("AEQE flush class contains unrelated owner fields");
        if (x.ecode == 8'h07 && has_qpn)
          return err("AEQE TX flush cannot author an object ID");
        if (!(x.ecode inside {8'h07, 8'h08}))
          return err("AEQE flush class ecode is invalid");
      end

      default:
        return err("AEQE canonical event class is invalid");
    endcase

    return rdma_status::success();
  endfunction

  // 功能：把 AEQE model 写入 builder：raw replay 须已授权并通过 validate_raw_authority，原样写两个 qword；
  //   否则校验 canonical 字段后按 typed 字段编码。
  // 输入/输出及副作用：model 只读，b 为写入器。
  // 失败/边界：类型不符、builder 为空、model/variant/profile/canonical 校验失败、raw 未授权或 put 失败返回错误。
  protected virtual function rdma_status encode_fields(
      rdma_hw_model model,
      rdma_hw_qword_builder b
  );
    rdma_hw_aeqe_model x;
    rdma_status status;

    if (!$cast(x, model))
      return err("AEQE model type mismatch");
    if (b == null)
      return err("AEQE qword builder is null");

    status = x.validate();
    if (status == null || !status.ok())
      return status == null ?
        err("AEQE model validation returned null status") : status;

    status = validate_variant_fields(x);
    if (status == null || !status.ok())
      return status == null ?
        err("AEQE variant validation returned null status") : status;

    status = validate_profile_authority(x);
    if (status == null || !status.ok())
      return status == null ?
        err("AEQE profile authority validation returned null status") : status;

    if (x.raw_qwords_valid) begin
      if (!x.raw_replay_authorized)
        return err("AEQE raw replay requires explicit authority");
      status = validate_raw_authority(x);
      if (status == null || !status.ok())
        return status == null ?
          err("AEQE raw authority validation returned null status") : status;
      status = b.put_field(0, 0, 64, x.raw_qword0);
      if (status == null || !status.ok())
        return err(status == null ? "AEQE raw qword0 write returned null" :
                   status.message);
      status = b.put_field(8, 0, 64, x.raw_qword1);
      if (status == null || !status.ok())
        return err(status == null ? "AEQE raw qword1 write returned null" :
                   status.message);
      return rdma_status::success();
    end

    status = validate_canonical_fields(x);
    if (status == null || !status.ok())
      return status == null ?
        err("AEQE canonical field validation returned null status") : status;

    `define AEQE_PUT(STEM, VALUE) \
      status = b.put_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                           STEM``_WIDTH, VALUE); \
      if (status == null || !status.ok()) \
        return err(status == null ? "AEQE field write returned null status" : \
                   status.message);

    `AEQE_PUT(RDMA_AEQE_VALID, x.valid)
    `AEQE_PUT(RDMA_AEQE_QP_ST, x.qp_state)
    `AEQE_PUT(RDMA_AEQE_SRFQ_EN, x.srfq_en)
    `AEQE_PUT(RDMA_AEQE_OVERFLOW_FLAG, x.overflow_flag)
    `AEQE_PUT(RDMA_AEQE_URC_FLAG, x.urc_flag)
    `AEQE_PUT(RDMA_AEQE_CQ_INVALID_FLAG, x.cq_invalid_flag)
    `AEQE_PUT(RDMA_AEQE_URC_ABNML_CQE_TYPE,
              x.urc_abnormal_cqe_type)
    `AEQE_PUT(RDMA_AEQE_CQN_EQN_HIGH, x.cqn_eqn_high)
    `AEQE_PUT(RDMA_AEQE_PKT_OPCODE, x.packet_opcode)
    `AEQE_PUT(RDMA_AEQE_ECODE, x.ecode)
    `AEQE_PUT(RDMA_AEQE_CQN_EQN_LOW, x.cqn_eqn_low)
    `AEQE_PUT(RDMA_AEQE_QPN, x.qpn)
    `AEQE_PUT(RDMA_AEQE_URC_REMOTE_ECODE, x.urc_remote_ecode)
    `AEQE_PUT(RDMA_AEQE_WQE_WRAP, x.wqe_wrap)
    `AEQE_PUT(RDMA_AEQE_WQE_INDEX, x.wqe_index)
    `AEQE_PUT(RDMA_AEQE_SRFQN, x.srfqn)
    `AEQE_PUT(RDMA_AEQE_SRFQE_IDX, x.srfqe_idx)

    `undef AEQE_PUT
    return rdma_status::success();
  endfunction

  // 功能：把两个 AEQE qword 解码为 detached raw observation，保留全部 typed overlay 与原始 qword，
  //   但不伪造经 manager 认证的 primary target。
  // 输入/输出及副作用：b 只读，model 输出；成功时 target_h=null、profile_*_valid=0。
  // 失败/边界：b 为空、字段读取失败或 qword 数不是 2 返回错误，model 保持 null；raw QP_ST 的 0..7 均保留；
  //   target authority 须由上层 resolver 后续安装。
  protected virtual function rdma_status decode_fields(
      rdma_hw_qword_builder b,
      output rdma_hw_model model
  );
    rdma_hw_aeqe_model x;
    bit [63:0] value;
    bit [63:0] words[];
    rdma_status status;

    model = null;
    if (b == null)
      return err("AEQE qword builder is null");

    x = rdma_hw_aeqe_model::type_id::create("decoded_aeqe");
    if (x == null)
      return err("AEQE model allocation failed");

    `define AEQE_GET(STEM, TARGET) \
      value = '0; \
      status = b.get_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                           STEM``_WIDTH, value); \
      if (status == null || !status.ok()) \
        return err(status == null ? "AEQE field read returned null status" : \
                   status.message); \
      TARGET = value;

    `AEQE_GET(RDMA_AEQE_VALID, x.valid)
    `AEQE_GET(RDMA_AEQE_QP_ST, x.qp_state)
    `AEQE_GET(RDMA_AEQE_SRFQ_EN, x.srfq_en)
    `AEQE_GET(RDMA_AEQE_OVERFLOW_FLAG, x.overflow_flag)
    `AEQE_GET(RDMA_AEQE_URC_FLAG, x.urc_flag)
    `AEQE_GET(RDMA_AEQE_CQ_INVALID_FLAG, x.cq_invalid_flag)
    `AEQE_GET(RDMA_AEQE_URC_ABNML_CQE_TYPE,
              x.urc_abnormal_cqe_type)
    `AEQE_GET(RDMA_AEQE_CQN_EQN_HIGH, x.cqn_eqn_high)
    `AEQE_GET(RDMA_AEQE_PKT_OPCODE, x.packet_opcode)
    `AEQE_GET(RDMA_AEQE_ECODE, x.ecode)
    `AEQE_GET(RDMA_AEQE_CQN_EQN_LOW, x.cqn_eqn_low)
    `AEQE_GET(RDMA_AEQE_QPN, x.qpn)
    `AEQE_GET(RDMA_AEQE_URC_REMOTE_ECODE, x.urc_remote_ecode)
    `AEQE_GET(RDMA_AEQE_WQE_WRAP, x.wqe_wrap)
    `AEQE_GET(RDMA_AEQE_WQE_INDEX, x.wqe_index)
    `AEQE_GET(RDMA_AEQE_SRFQN, x.srfqn)
    `AEQE_GET(RDMA_AEQE_SRFQE_IDX, x.srfqe_idx)

    b.get_words(words);
    if (words.size() != 2)
      return err("AEQE decoded qword count is invalid");
    x.raw_qwords_valid = 1'b1;
    x.raw_qword0 = words[0];
    x.raw_qword1 = words[1];

    `undef AEQE_GET
    status = validate_variant_fields(x);
    if (status == null || !status.ok())
      return status == null ?
        err("AEQE decoded variant validation returned null status") : status;

    model = x;
    return rdma_status::success();
  endfunction
endclass

// 功能：把语义 post-send 请求复制为独立的 SQE hardware model，选择 RC/UD/URC 专用 codec，生成 64B WQE 镜像。
// 输入/输出及副作用：request 只读；复制句柄、transport extension、SGE 与原子字段，不取得 QP/AV/SGB/DMA 所有权。
// 失败/边界：请求校验、对象分配、transport/extension 选择、SGE clone 或 codec encode 失败时返回错误且
//   image 为空，不会让未知 transport、null SGE 或 success+null image 流入队列写入路径。
function rdma_status rdma_queue_codec::encode_sqe(
    input rdma_post_send_req request,
    output byte unsigned image[]
  );
  rdma_hw_sqe_model model;
  rdma_hw_image encoded;
  rdma_status status;

  rdma_sqe_rc_ext rc;
  rdma_sqe_ud_ext ud;
  rdma_sqe_urc_ext urc;
  rdma_hw_queue_codec_base codec;

  rdma_sge copied_sge;

  image = new[0];

  if (request == null)
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      "SQE request is null");

  status = request.validate();
  if (status == null || !status.ok())
    return status == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                        "SQE request validation returned null status") :
      status;

  model = rdma_hw_sqe_model::type_id::create("sqe_request_model");
  if (model == null)
    return rdma_status::make(
      RDMA_SC_RESOURCE_EXHAUSTED,
      "SQE request model allocation failed");

  model.transport = request.transport;
  model.opcode = request.opcode;
  model.qp_h = request.qp_h;
  model.wr_id = request.wr_id;
  model.inline_data = request.inline_data;
  model.payload = request.payload;
  model.signaled = request.signaled;
  model.solicited = request.solicited;
  model.immediate_data = request.immediate_data;
  model.remote_va = request.remote_addr;
  model.rkey = request.rkey;
  model.invalidate_key = request.invalidate_rkey;

  // 原子操作的本地地址、lkey 与 compare/swap 值属于请求快照，facade 必须完整复制，
  // 不能依赖 hardware model 的默认零值。
  if (request.sges.size() == 0) begin
    model.atomic_local_iova = '0;
    model.atomic_local_lkey = '0;
  end
  else begin
    model.atomic_local_iova = request.sges[0].iova;
    model.atomic_local_lkey = request.sges[0].lkey;
  end
  model.atomic_compare = request.compare_value;
  model.atomic_value = request.swap_add_value;

  model.destination_qpn = request.destination_qpn;
  model.qkey = request.qkey;
  model.valid = 1'b1;
  model.sign_en = 1'b1;
  model.sgb_iova = request.sgb_iova;
  model.ce = request.signaled;
  model.se = request.solicited;

  foreach (request.sges[i]) begin
    if (request.sges[i] == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "SQE SGE is null");

    copied_sge = rdma_sge::type_id::create("sqe_sge");
    if (copied_sge == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "SQE SGE allocation failed");
    copied_sge.copy(request.sges[i]);
    model.sges.push_back(copied_sge);
  end
  // request facade 与三个 transport writer 共享 hardware model 的 canonical 推导；
  // 须在 payload/SGE 快照完整后再发布 wire 字段。
  model.sge_num = model.derive_sge_num();

  case (request.transport)
    RDMA_TRANSPORT_RC: begin
      rc = rdma_sqe_rc_ext::type_id::create("sqe_rc_ext");
      if (rc == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "RC SQE extension allocation failed");
      rc.remote_addr = request.remote_addr;
      rc.rkey = request.rkey;
      rc.remote_access_valid = request.remote_access_valid;
      rc.rkey_valid = request.rkey_valid;
      model.transport_ext = rc;
      codec = rdma_hw_sqe_rc_codec::type_id::create("sqe_rc_codec");
    end

    RDMA_TRANSPORT_UD: begin
      ud = rdma_sqe_ud_ext::type_id::create("sqe_ud_ext");
      if (ud == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "UD SQE extension allocation failed");
      ud.destination_qpn = request.destination_qpn;
      ud.qkey = request.qkey;
      ud.address_vector_id = request.address_vector_id;
      ud.address_vector_valid = request.address_vector_valid;
      ud.address_vector = request.address_vector;
      model.transport_ext = ud;
      codec = rdma_hw_sqe_ud_codec::type_id::create("sqe_ud_codec");
    end

    RDMA_TRANSPORT_URC: begin
      urc = rdma_sqe_urc_ext::type_id::create("sqe_urc_ext");
      if (urc == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "URC SQE extension allocation failed");
      urc.destination_qpn = request.destination_qpn;
      urc.remote_addr = request.remote_addr;
      urc.rkey = request.rkey;
      urc.remote_access_valid = request.remote_access_valid;
      urc.rkey_valid = request.rkey_valid;
      urc.completion_qp_h = request.completion_qp_h;
      model.transport_ext = urc;
      codec = rdma_hw_sqe_urc_codec::type_id::create("sqe_urc_codec");
    end

    default:
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        "SQE transport is unsupported");
  endcase

  if (codec == null)
    return rdma_status::make(
      RDMA_SC_RESOURCE_EXHAUSTED,
      "SQE codec allocation failed");

  status = codec.encode(model, encoded);
  if (status == null || !status.ok())
    return status == null ?
      rdma_status::make(RDMA_SC_CODEC_ERROR,
                        "SQE codec returned null status") :
      status;
  if (encoded == null || encoded.bytes.size() == 0)
    return rdma_status::make(
      RDMA_SC_CODEC_ERROR,
      "SQE codec returned no image");

  image = new[encoded.bytes.size()];
  foreach (image[i])
    image[i] = encoded.bytes[i];

  return rdma_status::success();
endfunction

// 功能：把 XTR v1 的 SQE/RQE/CQE/CEQE/AEQE codec 按 object_type、opcode、variant 键注册到 registry。
// 输入/输出及副作用：逐项更新 registry，返回最后一次注册的 status；不取得所有权。
// 失败/边界：registry 为空返回 INVALID_ARGUMENT；任一 register_codec 失败原样返回，
//   后续键不再注册，已完成的注册保持可见。
function automatic rdma_status rdma_register_queue_codecs(rdma_codec_registry registry);
  rdma_codec_key k;
  rdma_status s;

  if (registry == null)
    return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue codec registry is null");

  k.hw_version = "rdma";
  k.opcode = 0;

  k.image_kind = RDMA_IMAGE_SQE;
  k.object_type = "sqe";

  k.variant = "rc";
  s = registry.register_codec(
      k, rdma_hw_sqe_rc_codec::type_id::create("sqe_rc"));
  if (!s.ok())
    return s;

  k.variant = "ud";
  s = registry.register_codec(
      k, rdma_hw_sqe_ud_codec::type_id::create("sqe_ud"));
  if (!s.ok())
    return s;

  k.variant = "urc";
  s = registry.register_codec(
      k, rdma_hw_sqe_urc_codec::type_id::create("sqe_urc"));
  if (!s.ok())
    return s;

  k.image_kind = RDMA_IMAGE_RQE;
  k.object_type = "rqe";
  k.variant = "default";
  s = registry.register_codec(
      k, rdma_hw_rqe_codec::type_id::create("rqe"));
  if (!s.ok())
    return s;

  k.image_kind = RDMA_IMAGE_CQE;
  k.object_type = "cqe";
  s = registry.register_codec(
      k, rdma_hw_cqe_codec::type_id::create("cqe"));
  if (!s.ok())
    return s;

  k.image_kind = RDMA_IMAGE_CEQE;
  k.object_type = "ceqe";
  s = registry.register_codec(
      k, rdma_hw_ceqe_codec::type_id::create("ceqe"));
  if (!s.ok())
    return s;

  k.image_kind = RDMA_IMAGE_AEQE;
  k.object_type = "aeqe";
  return registry.register_codec(
      k, rdma_hw_aeqe_codec::type_id::create("aeqe"));
endfunction
