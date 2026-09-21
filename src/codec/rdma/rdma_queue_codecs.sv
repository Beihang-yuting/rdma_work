// 目录：硬件编解码层 src/codec/rdma。
// 职责：定义 XTR v1 队列项硬件模型，并实现 SQE/RQE/CQE/CEQE/AEQE 的
//   固定布局编解码、reserved/signature 校验及 post-send facade。
// 依赖：消费 rdma_queue_models 的语义快照、rdma_defs.svh 的冻结字段坐标、
//   rdma_hw_qword_builder 的大端 qword 操作和公共 handle/status 类型。
// 所有权与生命周期：codec 只拥有本地 builder、候选模型和 image 值快照；QP、
//   AV、SGB/Host-memory 与外部 handle 均为非拥有输入，生命周期由上层环境管理。

// XTR v1 fixed-size queue data entry codecs.  Queue fields are authored in
// logical qwords and serialized big-endian by rdma_hw_qword_builder.

// 功能：为 raw queue-image decode 构造仅含 kind/object_id/generation 的投影
//   handle，使 detached 模型可保留 wire identity，而不伪造 Function authority。
// 输入/输出及副作用：name、kind、id、generation 为输入；返回新建 rdma_handle，
//   function_uid 保持构造默认值，不修改调用方句柄或资源账本。
// 失败/边界：函数不校验 kind/id，也不把投影结果认证为可路由句柄；id=0 或
//   generation=0 仍按原值返回，后续 authoring/route gate 必须独立拒绝无效 authority。
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
  // 功能：encode_sqe 将语义发送请求投影为 XTR v1 64B SQE 镜像，统一选择 RC/UD/URC codec。
  // 输入/输出及副作用：request 为只读请求，image 为输出镜像；函数仅复制请求快照，不取得 QP、AV 或 DMA 所有权。
  // 失败/边界：空请求、请求校验失败、未知 transport、authority 不完整或 codec 拒绝 payload 时返回对应 status，image 保持为空。
  extern static function rdma_status encode_sqe(input rdma_post_send_req request,
                                          output byte unsigned image[]);
  // 功能：按 CQE layout 编码公共字段，生成零填充的大端字节镜像。
  // 输入/输出及副作用：fields/layout 为输入，image 为输出；成功时 image 长度等于 layout.bytes。
  // 失败/边界：layout 无效、header 未按 16B 对齐或输出空间不足时返回 CODEC_ERROR 且 image 为空。
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

  // 功能：从 CQE 大端字节镜像解码公共字段并校验布局元数据。
  // 输入/输出及副作用：image/layout 为输入，fields 为输出；不修改输入数组。
  // 失败/边界：镜像长度、header 对齐或保留字节不满足 profile 时返回 CODEC_ERROR。
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
  `uvm_object_utils(rdma_hw_sqe_model)
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
  // Frozen QPC-derived authority used only by the URC external-SGB READ
  // packet-count field.  A zero value is intentionally not a default MTU:
  // it means the queue path did not authenticate a programmed QPC.
  int unsigned path_mtu_bytes;
  rdma_iova_t atomic_local_iova;
  bit [31:0] atomic_local_lkey;
  longint unsigned atomic_value;
  longint unsigned atomic_compare;

  // 功能：构造 rdma_hw_sqe_model，调用 super.new 建立 UVM 对象，并把构造体
  //   直接写入的默认值设为：remote_va='0；sgb_iova='0；path_mtu_bytes=0；
  //   atomic_local_iova='0；payload_mode=RDMA_SQ_PAYLOAD_NONE；total_payload_len=0；
  //   inline_bytes=new[0]；invalidate_key=0；atomic_local_lkey=0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_sqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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

  // 功能：将 rhs 的 SQE wire 字段、payload 形状和 URC/QP 相关值复制到当前对象，形成独立的值快照。
  // 输入/输出及副作用：rhs 必须可 cast 为 rdma_hw_sqe_model；super.do_copy 先处理基类字段，动态 byte 数组按元素复制，句柄字段不由本对象拥有。
  // 失败/边界：rhs 为空或类型不匹配时触发 RDMA_COPY_TYPE fatal；fatal 前不得把部分字段当作有效快照继续发布。
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

  // 功能：validate_inline_payload_authority 确认 SQE 的两个 detached inline
  //   字节容器没有形成分叉事实源；当 inline_bytes 与 payload 同时存在时，
  //   它们必须逐字节相同，供 codec 签名和 queue-data SGB writer 共享。
  // 输入/输出及副作用：只读 inline_bytes、payload；返回 rdma_status，不修改
  //   任一数组、模型字段或外部 Host-memory 所有权。
  // 失败/边界：任一数组为空表示未提供该可选镜像来源，不触发冲突；两者长度不等
  //   或任一 byte 使用 case-inequality 不同时返回 INVALID_ARGUMENT，调用方不得
  //   选择其中一份继续编码，以免 WQE signature 与实际 SGB backing 不一致。
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

  // 功能：resolve_inline_payload_authority 选出本次 inline WQE/SGB 要签名和写入
  //   的唯一 detached byte 快照；优先使用显式 inline_bytes，否则复制 payload。
  // 输入/输出及副作用：resolved_bytes 为输出动态数组；读取两个源并复制值，
  //   不把数组引用或 Host-memory 生命周期转移给调用方，也不修改当前模型。
  // 失败/边界：若两个非空源未通过 validate_inline_payload_authority，返回同一
  //   INVALID_ARGUMENT 且 output 置空；两个源均为空时返回长度为零的成功快照。
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

  // 功能：derive_payload_authority 一次归一 payload mode、唯一有效 SGE 数、
  //   inline 实际字节源/长度和最终 hardware SGE_NUM，供 validation 与 writer 共用。
  // 输入/输出及副作用：只读 payload_mode、inline_data、inline_bytes、payload、
  //   opcode、sges；五个 output 返回本次 authority，不修改模型、数组或 SGE。
  // 失败/边界：null/zero-length SGE 不进入数值计数，null 仍由 shape gate 拒绝；
  //   显式 SGE mode 无有效项归一为 NONE，未知显式 mode 原样交给 validate 拒绝，
  //   total_payload_len 不参与 byte-source 选择，避免用声明长度伪造 payload。
  function automatic void derive_payload_authority(
      output rdma_sq_payload_mode_e mode,
      output int unsigned valid_sge_count,
      output int unsigned inline_payload_bytes,
      output bit inline_bytes_are_authority,
      output int unsigned canonical_sge_num);
    valid_sge_count = 0;
    foreach (sges[i]) begin
      if (sges[i] != null && sges[i].length != 0)
        valid_sge_count++;
    end

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

  // 功能：derive_payload_mode 为既有调用方返回共享 payload authority 的 mode。
  // 输入/输出及副作用：无显式参数；只读当前模型并返回 mode，不修改模型；其余
  //   authority output 仅为兼容 wrapper 的局部临时值。
  // 失败/边界：未知显式 mode 原样返回供 validate 拒绝；null SGE 不在此函数放行，
  //   后续 shape gate 仍返回 INVALID_ARGUMENT。
  function automatic rdma_sq_payload_mode_e derive_payload_mode();
    rdma_sq_payload_mode_e mode;
    int unsigned valid_sge_count;
    int unsigned inline_payload_bytes;
    int unsigned canonical_sge_num;
    bit inline_bytes_are_authority;

    derive_payload_authority(mode, valid_sge_count, inline_payload_bytes,
                             inline_bytes_are_authority,
                             canonical_sge_num);
    return mode;
  endfunction

  // 功能：derive_sge_num 为既有调用方返回共享 payload authority 的 canonical
  //   SGE_NUM：empty=0、inline=ceil(bytes/16)、SGE=有效项数、atomic=1。
  // 输入/输出及副作用：无显式参数；只读当前模型，返回未截断计数，不写 sge_num
  //   或调用方数组；其余 authority output 仅为局部临时值。
  // 失败/边界：null/zero-length SGE 不计数，但 null 仍由 shape gate 拒绝；长度
  //   超过 wire 宽度时返回完整 int，由 validate/writer fail closed 而不截断。
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

  // 功能：validate 校验 SQE handle、字段宽度、payload shape 与 canonical
  //   SGE_NUM 一致性，防止 caller-visible model 和最终 wire count 分叉。
  // 输入/输出及副作用：无显式参数；只读 qp_h、qpn、transport_ext、
  //   payload_mode、payload/SGE 与 sge_num，返回 rdma_status，不修改模型。
  // 失败/边界：按 shape、QP handle、字段宽度、transport extension、mode、
  //   canonical count 的既有优先级拒绝；null SGE、count 超出 8 bit 或 sge_num
  //   不等于 derive_sge_num 时返回 INVALID_ARGUMENT，不发布 image 或转移资源。
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

  // 功能：describe 将 SQE 的 QPN、硬件 opcode 和 ring index 编成稳定文本，供日志和失败诊断定位具体 WQE。
  // 输入/输出及副作用：无显式参数；只读取 qpn、hw_opcode、index，返回 string，不修改模型、builder 或资源账本。
  // 失败/边界：字段即使尚未配置也按当前数值输出，不抛出异常；调用方不得把描述文本当作编码或校验结果。
  virtual function string describe();
    return $sformatf(
        "XTR_SQE(qpn=%0d opcode=%0d index=%0d)",
        qpn,
        hw_opcode,
        index);
  endfunction
endclass

class rdma_hw_rqe_model extends rdma_rqe_model;
  `uvm_object_utils(rdma_hw_rqe_model)
  bit [23:0] qpn;
  bit [7:0] qp_sn;
  bit [3:0] hw_opcode;
  bit [14:0] index;
  bit wrap;
  // wr.h XTRDMA_QP_RQ_SIGN_EN (bit 56) records whether the receive WQE has a
  // signature.  xtrdma_post_receive_uk() also forces this bit for external
  // SGB entries, so the codec keeps the requested semantic value separate
  // from the wire-level mode override performed during encode.
  bit sign_en;
  bit valid;

  bit [31:0] payload_len;
  bit [7:0] signature;
  bit [7:0] sge_num;

  // XTRDMA_QP_RQ_SGB_PA is not a byte address in the wire image.  It is the
  // physical SGB address after the driver's nine-bit alignment shift.
  bit [54:0] sgb_pa;

  // An external RQE image carries only SGB_PA.  Descriptor bytes are detached
  // authority supplied by queue-data/host-memory, never inferred from PA.
  bit external_sgb_descriptor_authority_valid;
  byte unsigned external_sgb_descriptor_bytes[$];

  // decoded external image 没有 typed SGE 列表；provenance 保持为模型私有状态，
  // 只通过 checked API 暴露，避免调用方直接翻转 public bit 伪造 detached replay。
  // count、payload、SGB_PA 与 descriptor snapshot 冻结同一份认证输入，后续 mutation
  // 会在 resolve 阶段 fail-closed。
  local bit decoded_raw_sgb_provenance_valid;
  local bit [7:0] external_sgb_authority_sge_num;
  local bit [31:0] external_sgb_authority_payload_len;
  local bit [54:0] external_sgb_authority_sgb_pa;
  local byte unsigned external_sgb_authority_snapshot[$];

  // 功能：构造 rdma_hw_rqe_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 将 sign_en、sgb_pa 等本地 wire
  // 字段清零并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_rqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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

  // 功能：set_sgb_pa_encoded 把调用方提供的 PA>>9 编码值安装到 RQE 模型。
  // 输入/输出及副作用：encoded_pa 是未截断的 64 位编码输入；成功时写入
  // sgb_pa，失败时保留旧值并返回 INVALID_ARGUMENT，不取得外部内存所有权。
  // 失败/边界：encoded_pa[63:55] 任一置位表示超过驱动 55 位字段，拒绝截断。
  function rdma_status set_sgb_pa_encoded(bit [63:0] encoded_pa);
    if (encoded_pa[63:55] != 9'b0)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE encoded SGB_PA exceeds 55 bits");

    sgb_pa = encoded_pa[54:0];
    return rdma_status::success();
  endfunction

  // 功能：set_sgb_pa_from_physical 将驱动 API 使用的物理 SGB 地址转换为
  // 明确的 PA>>9 模型字段，确保 codec 不把未移位地址写进 qword4。
  // 输入/输出及副作用：physical_pa 是 64 位物理地址；成功时更新 sgb_pa，
  // 失败时不改变旧值；函数只更新本地语义快照，不取得 DMA 映射所有权。
  // 失败/边界：低九位非零表示未满足 512B 对齐而被拒绝；转换后超过 55 位
  // 也被拒绝，避免静默丢失高位。
  function rdma_status set_sgb_pa_from_physical(bit [63:0] physical_pa);
    bit [63:0] encoded_pa;

    if (physical_pa[8:0] != 9'b0)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE physical SGB_PA is not 512-byte aligned");

    encoded_pa = physical_pa >> 9;
    return set_sgb_pa_encoded(encoded_pa);
  endfunction

  // 功能：sgb_pa_as_physical 将已编码的 RQE SGB_PA 恢复成物理地址，供
  // detached decode 断言和上层日志核对驱动的 512B 坐标。
  // 输入/输出及副作用：无输入；返回低九位补零的 64 位物理地址，不修改模型
  // 或外部资源；调用方获得的是值快照而非可写引用。
  // 失败/边界：sgb_pa 已受 55 位宽度约束，左移不会溢出 64 位；零编码返回零。
  function bit [63:0] sgb_pa_as_physical();
    return {sgb_pa, 9'b0};
  endfunction

  // 功能：derive_typed_sge_authority 按驱动过滤规则从 detached SGE 列表计算
  //   有效 descriptor 数和总 payload 长度，作为 RQE canonical authority 的唯一
  //   typed 来源；length==0 被过滤，0x8000_0000 保留为 2GiB sentinel。
  // 输入/输出及副作用：有效数量与长度通过 output 返回；只读取 sges，不修改
  //   SGE、模型字段或外部 backing，也不取得输入对象所有权。
  // 失败/边界：raw SGE 列表超过 RDMA_MAX_WQ_SGE、包含 null、包含除 sentinel
  //   外的 bit31 长度，或有效长度和超过 2GiB 时返回 INVALID_ARGUMENT；失败时
  //   output 仍归零，调用方不得把部分统计发布到 sge_num/payload_len。
  function rdma_status derive_typed_sge_authority(
      output int unsigned valid_sge_count,
      output longint unsigned valid_payload_len
  );
    valid_sge_count = 0;
    valid_payload_len = 0;

    if (sges.size() > RDMA_MAX_WQ_SGE)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE raw SGE list exceeds driver limit of 32");

    foreach (sges[i]) begin
      if (sges[i] == null)
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "RQE SGE handle is null");

      if (sges[i].length == 0)
        continue;

      if (sges[i].length != 32'h8000_0000 && sges[i].length[31])
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "RQE SGE length uses reserved bit 31");

      if (valid_payload_len > 64'h8000_0000 - sges[i].length)
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "RQE payload length exceeds 2 GiB");

      valid_sge_count++;
      valid_payload_len += sges[i].length;
    end

    if (valid_sge_count > RDMA_MAX_WQ_SGE)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE valid SGE count exceeds driver limit of 32");

    return rdma_status::success();
  endfunction

  // 功能：build_typed_sgb_descriptor_bytes 将 canonical typed SGE 列表按驱动的
  //   length/lkey/IOVA 大端布局串行化，供 external-SGB 签名和 authority 比对共用。
  // 输入/输出及副作用：descriptor_bytes 为 output 动态数组；只读取 sges，并在
  //   成功时返回有效 SGE_NUM*16 字节，不修改模型或调用方 SGE。
  // 失败/边界：typed 统计失败、有效数量为零或 descriptor 长度无法按 16 字节表达时
  //   返回对应 INVALID_ARGUMENT，output 置为空；zero-length SGE 不产生 descriptor。
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

  // 功能：mark_decoded_raw_sgb_provenance 仅在 RQE codec 的 decode-active window
  //   内标记 detached raw external image；codec handle 与 candidate identity 双重
  //   检查把 provenance 建立限制在真实 decode 路径，而不是 caller 直接翻转状态。
  // 输入/输出及副作用：codec_handle 为输入 capability；成功时只更新模型内部
  //   provenance，不修改 wire 字段、descriptor bytes 或外部内存所有权。
  // 失败/边界：null/非 active codec、已有 marker、typed SGE 或 descriptor authority
  //   均返回 INVALID_STATE；调用方必须保留原状态，不能绕过 clear/re-authorize 边界。
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

  // 功能：clear_decoded_raw_sgb_provenance 放弃 detached raw 来源证明，使模型
  //   必须重新通过 typed SGE 或显式 provenance API 建立 external authority。
  // 输入/输出及副作用：无输入；清除内部 marker，不修改 sge_num、payload_len、
  //   SGB_PA 或已安装 descriptor bytes。
  // 失败/边界：清除后若 sges 为空且仍要编码 external RQE，必须重新调用
  //   mark_decoded_raw_sgb_provenance 并安装 descriptor authority，否则 fail-closed。
  function void clear_decoded_raw_sgb_provenance();
    decoded_raw_sgb_provenance_valid = 1'b0;
  endfunction

  // 功能：has_decoded_raw_sgb_provenance 返回模型是否持有 codec 建立的 detached
  //   raw external-SGB 来源证明，供测试和上层诊断读取而不暴露可写 marker。
  // 输入/输出及副作用：无输入；返回只读 bit，不修改模型、authority 或外部资源。
  // 失败/边界：构造或 typed 模型返回 0；该结果不能替代 descriptor length、签名和
  //   当前字段快照校验，调用方仍必须走 resolve_payload_authority()。
  function bit has_decoded_raw_sgb_provenance();
    return decoded_raw_sgb_provenance_valid;
  endfunction

  // 功能：clear_external_sgb_descriptor_authority 丢弃已安装的 external descriptor
  //   bytes 及其冻结 count/payload snapshot，供 caller 在确认 source 变化后重新授权。
  // 输入/输出及副作用：无输入；清除 authority bytes/valid 位和 snapshot，不修改
  //   typed SGE、wire 字段或外部 host-memory 生命周期。
  // 失败/边界：清除不可恢复旧 descriptor 证明；若模型仍是 detached raw，后续 encode
  //   必须重新安装恰好 sge_num*16 字节并再次通过快照检查。
  function void clear_external_sgb_descriptor_authority();
    external_sgb_descriptor_authority_valid = 1'b0;
    external_sgb_descriptor_bytes.delete();
    external_sgb_authority_sge_num = '0;
    external_sgb_authority_payload_len = '0;
    external_sgb_authority_sgb_pa = '0;
    external_sgb_authority_snapshot.delete();
  endfunction

  // 功能：validate_external_sgb_descriptor_authority 校验 external descriptor
  //   bytes 与当前 RQE 字段、typed SGE（若存在）或 detached raw provenance 的一致性。
  // 输入/输出及副作用：无显式输入；返回状态并只读 authority/SGE，不修改模型或 bytes。
  // 失败/边界：拒绝 N<=2、N>32、长度非 N*16、snapshot 被 mutation 改写、typed
  //   count/payload 或 descriptor 内容冲突，以及没有 raw provenance 的空 sges 模型。
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

    status = derive_typed_sge_authority(valid_sge_count, valid_payload_len);
    if (!status.ok())
      return status;
    if (valid_sge_count != sge_num ||
        valid_payload_len != payload_len)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE external SGB authority disagrees with typed SGE list");

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

  // 功能：resolve_payload_authority 统一解析 RQE 当前可发布的 SGE_NUM、payload
  //   length 和 external descriptor authority，供 model.validate、codec encode 与
  //   queue-data make_rqe 共用，消除 typed/raw 双事实源。
  // 输入/输出及副作用：有效数量与长度通过 output 返回；只读模型状态，不修改
  //   caller 字段、SGE 或外部 backing。
  // 失败/边界：external authority 存在时必须通过 snapshot/typed/raw provenance
  //   检查；否则要求 typed 列表统计与 sge_num/payload_len 完全一致，并拒绝范围、
  //   null、reserved bit31 或 2GiB 溢出。失败时 output 归零。
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

    status = derive_typed_sge_authority(
        effective_sge_count, effective_payload_len);
    if (!status.ok())
      return status;
    if (effective_sge_count != sge_num)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE SGE_NUM does not match canonical SGE count");
    if (effective_payload_len != payload_len)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "RQE payload length does not match canonical SGE sum");

    return rdma_status::success();
  endfunction

  // 功能：set_external_sgb_descriptor_bytes 安装与当前 external-SGB RQE
  //   对应的、按驱动大端布局排列的 descriptor 字节，作为签名 authority。
  // 输入/输出及副作用：descriptor_bytes 为输入快照；成功时复制到对象并置
  //   external_sgb_descriptor_authority_valid，调用方数组和外部 backing 不被取得。
  // 失败/边界：仅 external 布局（sge_num>2）接受恰好 sge_num*16 字节；长度不符
  //   时保留旧 authority 并返回 INVALID_ARGUMENT，禁止用截断或补零冒充 descriptor。
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
      status = derive_typed_sge_authority(valid_sge_count, valid_payload_len);
      if (!status.ok())
        return status;
      if (valid_sge_count != sge_num || valid_payload_len != payload_len)
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "RQE external SGB authority disagrees with typed SGE list");
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

  // 功能：将 rhs 的 RQE header、SGB 地址和外部 descriptor authority 复制到当前对象，形成 detached 接收 WQE 快照。
  // 输入/输出及副作用：rhs 必须可 cast 为 rdma_hw_rqe_model；descriptor byte queue 按元素复制，target_h 仍由基类作为非拥有句柄处理。
  // 失败/边界：rhs 为空或类型不匹配时触发 RDMA_COPY_TYPE fatal；长度 authority 不在此处重新推断，避免复制阶段改变驱动布局语义。
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

  // 功能：validate 校验 RQE route handle、index 以及 typed/raw payload authority，
  //   确认 caller-visible sge_num/payload_len 与唯一有效 SGE 来源一致后才允许编码。
  // 输入/输出及副作用：无显式参数；只读取 target_h、index、SGE 列表、wire count/
  //   length 和 external authority，返回 rdma_status，不取得句柄、descriptor 或 backing 所有权。
  // 失败/边界：拒绝缺失/错误 kind handle、index 越界、raw SGE 数量/长度范围错误、
  //   typed count/payload mismatch、stale external snapshot 或无 provenance 的 detached
  //   authority；失败时不发布 image、不修改模型状态。
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

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf(
        "XTR_RQE(qpn=%0d opcode=%0d index=%0d sign_en=%0d sgb_pa=0x%0h)",
        qpn, hw_opcode, index, sign_en, sgb_pa);
  endfunction
endclass

class rdma_hw_cqe_model extends rdma_cqe_model;
  `uvm_object_utils(rdma_hw_cqe_model)

  // Common qword0/qword1 fields from wr.h.
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

  // qword2 overlay fields.  Only one overlay is authoritative for a CQE
  // variant; the other values must remain zero on an encoded image.
  bit [7:0] signature;
  bit [7:0] rc_remote_syndrome;
  bit [23:0] ud_src_qpn;
  bit rqe_cpl;
  bit [11:0] srfqn;
  bit srfqe_wrap;
  bit [14:0] srfqe_index;

  // qword2 is a physical union in wr.h.  A decoded raw word remains the
  // authority until the caller explicitly clears it and chooses one typed
  // overlay for a new image.
  bit raw_qword2_valid;
  bit [63:0] raw_qword2;

  // qword3 is present only for an explicitly authorized UD completion.
  bit [47:0] ud_smac;
  bit [15:0] ud_vlan_tag;

  // CQE profile payload is a detached byte snapshot.  It is intentionally
  // separate from payload_len: the driver may report a total packet length
  // larger than the inline bytes carried by a CQE entry.
  byte unsigned payload[$];

  // 功能：构造 rdma_hw_cqe_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cqe_model");
    super.new(name);
    variant = RDMA_CQE_VARIANT_RC;
    raw_qword2_valid = 1'b0;
    raw_qword2 = '0;
    payload.delete();
  endfunction

  // 功能：将 rhs 的 CQE variant、header/overlay 字段和 raw qword2 authority 复制到当前对象，形成可再次校验的 detached 快照。
  // 输入/输出及副作用：rhs 必须可 cast 为 rdma_hw_cqe_model；payload queue 按元素复制，QP/CQ 句柄沿基类规则保持非拥有引用。
  // 失败/边界：rhs 为空或类型不匹配时触发 RDMA_COPY_TYPE fatal；raw authority 与 typed 字段同时复制，不在此处猜测 variant 或改写保留位。
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

  // 功能：resolved_variant 返回模型持有的显式 CQE variant，作为 qword2/qword3
  //       overlay 的唯一语义 authority；不从 raw overlay 的非零值猜测传输类型。
  // 输入/输出及副作用：无输入；读取 variant 并返回其值，不修改模型、raw
  //       authority 或外部 CQ/QP 资源。
  // 失败/边界：variant 的合法性由 validate() 和 codec 的显式 variant API
  //       检查；默认 RC 只表示兼容初值，不代表 wire image 已证明为 RC。
  function rdma_cqe_variant_e resolved_variant();
    return variant;
  endfunction

  // 功能：clear_raw_qword2_authority 放弃 decode 保存的 CQE qword2 原始权威，
  //       允许调用方在清理不适用 overlay 后按显式 variant 重新编码。
  // 输入/输出及副作用：无输入；清除 raw_qword2_valid 和 raw_qword2，不修改
  //       其他 CQE 字段、句柄或外部 ring/backing 的所有权。
  // 失败/边界：该操作不可恢复原始 qword2；若仍保留冲突的 RC/UD/RQ 字段，后续
  //       encode 会按 typed variant fail-closed，而不会静默合并或截断。
  function void clear_raw_qword2_authority();
    raw_qword2_valid = 1'b0;
    raw_qword2 = '0;
  endfunction


  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CQE requires QP handle”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、qp_h、qp_h.kind 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQE requires QP handle”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "CQE requires QP handle");

    if (status == null)
      status = rdma_status::type_id::create("cqe_status");

    if (variant > RDMA_CQE_VARIANT_RQ_SRFQ)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "CQE variant is invalid");

    // A raw decode may legitimately expose every physical interpretation of
    // qword2 at once; the codec validates those fields against raw_qword2.
    // Newly constructed typed models, however, must not silently drop fields
    // belonging to another explicitly selected variant.
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

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf(
        "XTR_CQE(qpn=%0d index=%0d variant=%0d ecode=0x%02x)",
        qpn, wqe_index, variant, ecode);
  endfunction
endclass

class rdma_hw_ceqe_model extends rdma_ceqe_model;
  `uvm_object_utils(rdma_hw_ceqe_model)
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

  // qword1 contains two driver views with physical aliases.  A decoded raw
  // image keeps the original word as the authority so an inactive overlay is
  // not rewritten through a guessed semantic view.
  bit raw_qword1_valid;
  bit [63:0] raw_qword1;

  // Canonical CEQE authoring requires the routed CQ transport as an explicit
  // authority.  A newly constructed model is intentionally unauthenticated;
  // callers must not infer RC/URC from the default value of urc_flag.
  rdma_transport_e profile_transport;
  bit profile_transport_valid;
  bit raw_qword1_replay_authorized;

  // 功能：构造 CEQE 硬件模型并初始化 UVM 对象身份，保留 raw qword1 authority 的默认无效状态。
  // 输入/输出及副作用：name 是 UVM 实例名；new 调用 super.new，不创建 CQ/CEQ backing，也不取得外部句柄所有权。
  // 失败/边界：构造不验证 qpn/cqn 或 URC overlay；字段完整性由 validate/decode 在发布模型前检查。
  function new(string name = "rdma_hw_ceqe_model");
    super.new(name);
    profile_transport = RDMA_TRANSPORT_RESERVED;
    profile_transport_valid = 1'b0;
    raw_qword1_valid = 1'b0;
    raw_qword1 = '0;
    raw_qword1_replay_authorized = 1'b0;
  endfunction

  // 功能：将 rhs 的 CEQE qword0/1 字段和 raw qword1 authority 复制到当前对象，保留 RC/URC overlay 的原始证据。
  // 输入/输出及副作用：rhs 必须可 cast 为 rdma_hw_ceqe_model；super.do_copy
  //   处理 CQ handle，当前方法只复制值字段，不取得 CEQ backing 所有权。
  // 失败/边界：rhs 为空或类型不匹配时触发 RDMA_COPY_TYPE fatal；raw authority 不得在复制时被清除或由 typed 字段重算。
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

  // 功能：set_profile_transport_authority 冻结 routed CQ 提供的 CEQE wire profile，
  //       供 canonical encode 判断 RC/UD 与 URC 的唯一 overlay ownership。
  // 输入/输出及副作用：transport 为已认证 CQ attachment 的传输类型；成功时写入
  //       profile_transport/profile_transport_valid，不修改 qword 字段、句柄或 backing。
  // 失败/边界：CUSTOM、RESERVED 及其他未知 transport 被拒绝；重复设置同一值幂等，
  //       重设为不同值返回 INVALID_STATE，避免在同一 detached model 上切换 wire profile。
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

  // 功能：clear_profile_transport_authority 清除 canonical CEQE 的 routed profile，
  //       用于丢弃一个不再属于当前 CQ attachment 的 detached 候选。
  // 输入/输出及副作用：无输入；清除 profile_transport_valid 与 raw replay 授权，
  //       不修改物理字段、CQ handle 或外部 runtime/backing。
  // 失败/边界：清除不可恢复此前的 authority；清除后普通 encode 必须重新获得
  //       当前 route 的 transport，不能回退到 RC 默认值。
  function void clear_profile_transport_authority();
    profile_transport = RDMA_TRANSPORT_RESERVED;
    profile_transport_valid = 1'b0;
    raw_qword1_replay_authorized = 1'b0;
  endfunction

  // 功能：authorize_raw_qword1_replay 显式允许把 decode 保存的 qword1 原字节
  //       原样重放，保留驱动同时暴露的 inactive physical overlay。
  // 输入/输出及副作用：无输入；成功时只设置 raw_qword1_replay_authorized，不复制
  //       bytes、不修改 typed 字段或任何 queue 状态。
  // 失败/边界：没有 raw_qword1_valid 时返回 INVALID_STATE；该授权不绕过 profile
  //       transport、raw/typed 一致性或 image reserved 校验。
  function rdma_status authorize_raw_qword1_replay();
    if (!raw_qword1_valid)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "CEQE raw qword1 replay requires decoded authority");
    raw_qword1_replay_authorized = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：clear_raw_qword1_authority 放弃 decode 保存的 CEQE qword1 原始权威，
  //       允许调用方在确认 alias 一致后按模型字段重新编码。
  // 输入/输出及副作用：无显式输入；清除 raw_qword1_valid，不修改业务字段、
  //       CQ handle 或外部 CEQ backing 的所有权。
  // 失败/边界：该操作不可恢复原始字节；调用方若随后同时设置冲突的 RC/URC
  //       alias，codec 会 fail-closed 而不会自动合并。
  function void clear_raw_qword1_authority();
    raw_qword1_valid = 1'b0;
    raw_qword1 = '0;
    raw_qword1_replay_authorized = 1'b0;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CEQE requires CQ handle”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 只读取 cq_h 及其 kind，返回状态且
  //   不修改 cq_h/cqn；global handle incarnation 与 Function-local cqn 的关联由
  //   queue-data attachment authority 校验，codec 不跨命名空间猜测 identity。
  // 失败/边界：cq_h 为空或不是 CQ 时返回 INVALID_ARGUMENT；cqn 的字段宽度由
  //   packed 类型/codec 保证，unknown local CQN 必须由拥有 topology 的调用方拒绝。
  virtual function rdma_status validate();
    if (cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "CEQE requires CQ handle");

    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("XTR_CEQE(qpn=%0d cqn=%0d urc=%0b)",
                     qpn, cqn, urc_flag);
  endfunction
endclass

class rdma_hw_aeqe_model extends rdma_aeqe_model;
  `uvm_object_utils(rdma_hw_aeqe_model)
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

  // Canonical AEQE authoring must be tied to the owner route selected by
  // event.c.  These fields are intentionally invalid for a newly constructed
  // model; the queue-data engine freezes them only after manager lookup.
  rdma_aeqe_event_class_e profile_class;
  rdma_resource_kind_e profile_owner_kind;
  bit profile_class_valid;
  bit profile_owner_valid;

  // A raw decode keeps both physical qwords so a later replay can preserve
  // driver-owned overlay bits without treating the typed view as write
  // authority.  Replay is separately gated and never inferred from ecode.
  bit raw_qwords_valid;
  bit [63:0] raw_qword0;
  bit [63:0] raw_qword1;
  bit raw_replay_authorized;

  // 功能：构造 AEQE 硬件模型并初始化 UVM 对象身份，保留驱动事件字段的零值默认状态。
  // 输入/输出及副作用：name 是 UVM 实例名；new 调用 super.new，不创建 AEQ backing、路由或 QP 句柄，也不取得外部所有权。
  // 失败/边界：构造不验证 QP state、CQN/EQN 拆分或 ecode；这些字段必须由 validate/decode 在事件发布前确认。
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

  // 功能：将 rhs 的 AEQE 事件字段、CQN/EQN 拆分值和 URC 扩展复制到当前对象，形成可路由的 detached 事件快照。
  // 输入/输出及副作用：rhs 必须可 cast 为 rdma_hw_aeqe_model；super.do_copy 处理目标句柄，当前方法只覆盖本类值字段。
  // 失败/边界：rhs 为空或类型不匹配时触发 RDMA_COPY_TYPE fatal；复制不重新组合或归一化 cqn_eqn，避免丢失驱动高/低位语义。
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

  // 功能：set_profile_owner_authority 冻结 AEQE 的 ecode class 与 primary
  //   resource kind，供 canonical codec 和 publish route 共同校验 owner。
  // 输入/输出及副作用：event_class、owner_kind 为已完成 manager lookup 的输入；
  //   成功时写入两个 authority 字段，不修改 wire payload、target_h 或 backing。
  // 失败/边界：class/kind 组合不符合驱动 event.c 分派、未知枚举或重复切换到不同
  //   authority 时返回 INVALID_ARGUMENT/INVALID_STATE；不会部分冻结一半 authority。
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

  // 功能：clear_profile_owner_authority 丢弃 canonical AEQE 的 route 绑定，供
  //   detached candidate 在跨代际或重新路由时回到未认证状态。
  // 输入/输出及副作用：无输入；清除 class/kind valid 位及 raw replay 授权，
  //   保留所有物理字段和 target_h 值，不触碰 manager 或 AEQ runtime。
  // 失败/边界：清除后任何普通 encode 都必须重新绑定 authority；该操作不可恢复
  //   已丢弃的 route 证明，调用方不得把旧 target 当成隐式 authority。
  function void clear_profile_owner_authority();
    profile_class = RDMA_AEQE_EVENT_QP;
    profile_owner_kind = RDMA_RESOURCE_QP;
    profile_class_valid = 1'b0;
    profile_owner_valid = 1'b0;
    raw_replay_authorized = 1'b0;
  endfunction

  // 功能：authorize_raw_replay 显式允许将 decode 保存的两个 AEQE qword 原样
  //   重放，保留驱动在 inactive overlay 中提供的物理证据。
  // 输入/输出及副作用：无输入；成功只置 raw_replay_authorized，不复制数组或
  //   修改 typed 字段，调用方仍拥有原始 image/backing 生命周期。
  // 失败/边界：raw qword authority 尚未由 decode 建立时返回 INVALID_STATE；该
  //   授权不绕过 profile owner、raw/typed 一致性和 reserved mask 检查。
  function rdma_status authorize_raw_replay();
    if (!raw_qwords_valid)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "AEQE raw replay requires decoded qword authority");
    raw_replay_authorized = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：clear_raw_authority 放弃 decode 保留的 qword image，使调用方可以在
  //  重新绑定 owner 后重新进行 canonical authoring。
  // 输入/输出及副作用：无输入；清除 raw qword 值、valid/replay 位，不修改 typed
  //   fields、target_h、manager 或 AEQ backing。
  // 失败/边界：原始 qword 证据清除后不可恢复；后续 encode 不得再声称是 raw replay。
  function void clear_raw_authority();
    raw_qwords_valid = 1'b0;
    raw_qword0 = '0;
    raw_qword1 = '0;
    raw_replay_authorized = 1'b0;
  endfunction

  // 功能：validate_wire_fields 校验 AEQE 中独立于 owner route 的驱动字段约束，
  //   供 publish 在 route lookup 前检查 severity，并保留完整 3-bit QP_ST 观测。
  // 输入/输出及副作用：无输入；只读取 severity，返回状态，不修改 qp_state、
  //   target_h、authority 或任何 runtime 资源。
  // 失败/边界：severity 不在四个定义枚举时返回 INVALID_ARGUMENT；bit[2:0]
  //   qp_state 的 0..7 均是合法 wire 值，只有 canonical authoring 会拒绝 6/7；
  //   target_h 为空不在此处拒绝，因为非 QP route 可由 wire ID 推导。
  function rdma_status validate_wire_fields();
    if (!(severity inside {RDMA_SEVERITY_INFO, RDMA_SEVERITY_WARNING,
                           RDMA_SEVERITY_ERROR, RDMA_SEVERITY_FATAL}))
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "AEQE severity is invalid");
    return rdma_status::success();
  endfunction

  // 功能：logical_cqn_eqn 将驱动 AEQE 的高/低拆分坐标重组成逻辑 EQ/CQ 编号。
  // 输入/输出及副作用：无输入；读取 cqn_eqn_high、cqn_eqn_low，按 defs.h 的
  //   CQN_EQN_LSHIFT=6 返回 19 位值，不修改模型或外部路由所有权。
  // 失败/边界：字段宽度由 packed 类型保证；高段和低段均为合法值时直接返回
  //   (cqn_eqn_high << 6) | cqn_eqn_low，不会把两个 wire 字段误当连续 19 位串接。
  function bit [18:0] logical_cqn_eqn();
    bit [18:0] high_part;

    high_part = cqn_eqn_high;
    high_part = high_part << RDMA_AEQE_CQN_EQN_LSHIFT;
    return high_part | cqn_eqn_low;
  endfunction

  // 功能：validate 校验 AEQE 基础 wire 字段并确认对象已安装 target authority，
  //   供 encode 在 class-specific canonical/raw replay 分流前建立共同前置条件。
  // 输入/输出及副作用：无显式参数；读取 target_h、severity 与完整 3-bit
  //   qp_state，返回状态，不修改模型或取得调用方资源所有权。
  // 失败/边界：target_h 为空或 severity 非法时返回 INVALID_ARGUMENT；QP_ST=6/7
  //   可进入显式 raw replay，canonical 路径由 validate_canonical_fields 拒绝，
  //   失败路径不发布部分事件镜像。
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

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("XTR_AEQE(qpn=%0d ecode=0x%02x cqn_eqn=%0d)",
                     qpn, ecode, logical_cqn_eqn());
  endfunction
endclass

virtual class rdma_hw_queue_codec_base extends rdma_codec_base;

  // 功能：构造 queue codec 的抽象基类，先初始化 UVM 对象身份，再把布局相关状态留给派生 codec。
  // 输入/输出及副作用：name 是 UVM 实例名；new 只调用 super.new，不创建 image、builder 或外部资源，返回 void。
  // 失败/边界：构造阶段不验证 model/image，也不取得 Host-memory、PCIe 或
  //   资源 manager 所有权；具体 codec 必须在 encode/decode 入口执行自己的校验。
  function new(string name="rdma_hw_queue_codec_base");
    super.new(name);
  endfunction
  // 功能：声明派生 queue codec 提供的硬件 image 类型，供 validate_image 和 encode 填充 metadata。
  // 输入/输出及副作用：无显式参数；返回固定 rdma_image_kind_e，不读取或修改 model、builder 或资源账本。
  // 失败/边界：这是纯虚契约，基类不提供默认类型；派生实现若返回与实际布局不符的类型，调用方会在 metadata 校验阶段拒绝。
  protected pure virtual function rdma_image_kind_e image_kind_expected();

  // 功能：声明派生 queue codec 的固定 image 字节数，供 builder reset、长度检查和序列化边界使用。
  // 输入/输出及副作用：无显式参数；返回正的布局长度，不读取或修改 image、model、builder 和外部 backing。
  // 失败/边界：这是纯虚契约，基类不以错误码代替长度；派生实现必须返回与驱动几何一致且受 builder 支持的尺寸。
  protected pure virtual function int unsigned image_bytes();

  // 功能：要求派生 queue codec 把 model 的业务字段写入已 reset 的 qword builder，形成待校验的硬件布局。
  // 输入/输出及副作用：model 为只读输入，b 为当前 image 的可变写入器；成功时只更新 b，不发布最终 image 或取得外部 backing 所有权。
  // 失败/边界：model 类型、字段范围、布局重叠或底层 put 失败时必须返回对应 rdma_status，并由上层丢弃 b 的部分内容。
  protected pure virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b);

  // 功能：要求派生 queue codec 从已反序列化的 qword builder 解码出 detached model 快照。
  // 输入/输出及副作用：b 为只读字段源，model 为 output；成功时 model 指向新建或隔离对象，不接管 b 或原始 image 生命周期。
  // 失败/边界：字段读取、类型构造或语义验证失败时返回错误，model 应保持 null 或不发布不完整快照。
  protected pure virtual function rdma_status decode_fields(rdma_hw_qword_builder b, output rdma_hw_model model);

  // 功能：要求派生 queue codec 按驱动 profile 检查 builder 中未声明的 reserved 位和 variant 约束。
  // 输入/输出及副作用：b 为只读 qword 源；返回 rdma_status，不修改 builder、model 或任何外部资源。
  // 失败/边界：reserved 位非零、qword 数量错误或 variant 几何不符时必须返回
  //   CODEC_ERROR；合法 opaque/payload 位应由派生 profile 明确放行。
  protected pure virtual function rdma_status check_reserved(rdma_hw_qword_builder b);

  // 功能：把 queue codec 的布局或反序列化错误消息统一封装为 CODEC_ERROR，保留底层失败证据。
  // 输入/输出及副作用：m 是诊断文本；返回新的 rdma_status，不更新 builder、image、model 或资源账本。
  // 失败/边界：m 为空仍返回 CODEC_ERROR；调用方不得把该状态误当成功，也不得在此处重试或转移资源。
  protected function rdma_status err(string m);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, m);
  endfunction
  // 功能：model_handle_generation 按函数体读取当前字段并生成 int unsigned 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：model（输入）；model_handle_generation 读取 model 并使用字段 generation、rq.target_h、cq.qp_h、aq.target_h、rq、cq、aq；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
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

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理“queue model is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 rdma_status、s.message、image、image.function_generation、image.length、p；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
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

  // 功能：validate_queue_image_metadata 按 queue codec 的固定布局校验 image
  //   的空值、generation 和完整 metadata 前置条件，供不同 image 校验入口复用。
  // 输入/输出及副作用：image、expected_length 为只读输入；函数读取 image 的
  //   function_generation、length、bytes、alignment、endian、image_kind、硬件版本及
  //   各写入目标字段，返回 rdma_status，不修改 image、codec、builder 或外部资源。
  // 失败/边界：image 为空返回“queue image is null”；generation 为零返回原有
  //   stale 状态；length/bytes、对齐、端序、image kind、硬件版本或 backing/HMC/BAR/
  //   write target 任一不符 expected_length/queue profile 时返回“queue image metadata
  //   is invalid”，并保持 null→generation→metadata 的拒绝顺序。
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

  // 功能：validate_image 先校验 queue image 的固定 metadata，再反序列化 bytes
  //   并执行派生 codec 的 reserved-bit 检查，确认镜像可安全进入字段解码路径。
  // 输入/输出及副作用：image 为只读输入；函数使用 image_bytes、临时 byte 数组 p、
  //   qword builder b 和状态 s，返回 rdma_status，不修改 image 或取得外部资源所有权。
  // 失败/边界：metadata helper 拒绝空镜像、stale generation 或布局/目标不符，
  //   deserialize 失败会保留其消息并包装为 codec error，reserved 检查失败原样返回；
  //   任一失败都不发布部分解码模型。
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

  // 功能：hardware_endian 使用 当前对象字段 计算并返回 rdma_byte_endian_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；hardware_endian 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_byte_endian_e，不取得调用方资源所有权。
  // 失败/边界：hardware_endian 是只读访问器，返回 RDMA_ENDIAN_BIG；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_byte_endian_e hardware_endian();
    return RDMA_ENDIAN_BIG;
  endfunction

  // 功能：describe_fields 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；describe_fields 读取 image_bytes() 返回的固定长度并生成 queue image 描述文本；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe_fields();
    return $sformatf(
        "rdma %0d-byte queue image",
        image_bytes());
  endfunction

  // 功能：在 rdma_hw_queue_codec_base 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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

  // 功能：在 rdma_hw_queue_codec_base 中，decode 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：image（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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

  // 功能：在 rdma_hw_queue_codecs 中由 serialized_equal 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）、equal（输出）、mismatch（输出）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：serialized_equal 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
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

  // 功能：构造 SQE codec 基类并初始化 UVM 对象身份，布局常量由本类固定为 SQE/WQE 几何。
  // 输入/输出及副作用：name 是 UVM 实例名；new 只调用 super.new，不创建 WQE backing 或取得 QP/SQ 所有权。
  // 失败/边界：构造不验证具体 transport、payload 或 handle；这些检查由 encode_fields 和派生 UD/URC codec 完成。
  function new(string name = "rdma_hw_sqe_codec_base");
    super.new(name);
  endfunction

  // 功能：返回 SQE codec 生成的硬件 image 类型，供基类 metadata 校验和调用方路由使用。
  // 输入/输出及副作用：无显式参数；返回固定 RDMA_IMAGE_SQE，不读取或修改 model、builder 或资源账本。
  // 失败/边界：该访问器没有运行时失败分支；若调用方收到其他 image_kind，表示 image 来源与 SQE codec 不匹配。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_SQE;
  endfunction

  // 功能：返回驱动 SQ WQE 的固定字节数，供 builder reset、image length 和序列化边界使用。
  // 输入/输出及副作用：无显式参数；返回 RDMA_WQE_BYTES，不读取或修改 image、model、builder 和外部 backing。
  // 失败/边界：该访问器没有运行时失败分支；若驱动几何改变，必须同步更新冻结 profile 而不能在此处猜测长度。
  protected virtual function int unsigned image_bytes();
    return RDMA_WQE_BYTES;
  endfunction

  // 功能：validate_model 在任何 RC/UD/URC builder 写入前统一校验 SQE
  //   generation、hardware-model shape 与 canonical SGE_NUM，避免派生 writer 漏 gate。
  // 输入/输出及副作用：model 为只读输入；先调用 queue 基类校验 handle
  //   generation，再 cast 并调用 rdma_hw_sqe_model::validate，不修改模型或 image。
  // 失败/边界：空/stale handle、模型类型不符、null SGE 或 count mismatch 均
  //   返回非成功状态；encode 已先把 image 置 null，raw decode 不经过本 authoring gate。
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

  // 功能：把一个已解析的 SQE 字段写入 qword builder，并把底层失败归类为 CODEC_ERROR。
  // 输入/输出及副作用：b 为可变 builder，o/l/w/v 分别是字节偏移、LSB、宽度和值；成功只更新 b，不取得外部 backing 所有权。
  // 失败/边界：put_field 拒绝越界、宽度非法或已有冲突位时返回 CODEC_ERROR，并保留原始错误消息；失败后调用方不得继续发布 image。
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

  // 功能：从 qword builder 读取一个 SQE 字段，统一转换底层读取错误并写回调用方变量。
  // 输入/输出及副作用：b 为只读字段源，o/l/w 指定位坐标，v 为 inout 输出值；不修改 image、model 或外部资源。
  // 失败/边界：get_field 拒绝越界、宽度非法或 builder 未反序列化时返回 CODEC_ERROR；v 的值只有读取成功后才可被调用方使用。
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

  // 功能：check_reserved 校验 b 与当前对象状态的一致性，并显式处理“SQE header reserved bits are nonzero”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：b（输入）；check_reserved 读取 b 的 qword[0]，拒绝 SQE header 保留位非零的镜像；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：check_reserved 是只读访问器，返回 err("SQE header reserved bits are nonzero")；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b);
    bit [63:0] w[];
    b.get_words(w);
    if (!rdma_raw_qword_mask_is_valid(
          w[0], 64'hefff_ffff_ffff_ffff))
      return err("SQE header reserved bits are nonzero");
    return rdma_status::success();
  endfunction

  // 功能：encode_fields 把已由统一 authoring gate 校验的 SQE 公共 header
  //   写入 builder；RC 模型还写入 remote key/VA，供基础 codec 的简单布局使用。
  // 输入/输出及副作用：model 为只读输入，b 接收固定 raw 坐标字段；函数不再
  //   重复调用 model.validate，也不修改 handle、payload 或资源生命周期。
  // 失败/边界：model 不是 rdma_hw_sqe_model，或任一 put 因坐标/重叠失败时
  //   返回非 OK；非 RC transport 只写公共 header 后成功返回。
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

  // 功能：decode_fields 解码 SQE 基类公共 header 与 RC remote 坐标，生成
  //   可供通用 codec round-trip 的 detached RC SEND 模型。
  // 输入/输出及副作用：b 为已通过 raw/layout 校验的只读 builder，model 为输出；
  //   成功时发布新建模型和投影 QP handle，不修改原 image 或取得外部资源所有权。
  // 失败/边界：任一字段读取失败立即返回 CODEC_ERROR 且不发布 model；投影 handle
  //   仅保留 raw identity，不构成 Function/route authority，业务路径不得直接提交。
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

// 功能：在 rdma_hw_sqe_codec_base 中，rdma_hw_sq_signature_xor 对除
//   signature byte 外的 SQE 和 SGB 字节执行 XOR，生成 XTR v1 校验签名。
// 输入/输出及副作用：image（输入）、sgb（输入）；rdma_hw_sq_signature_xor
//   读取 image、sgb 并使用字段 value；函数返回 bit [7:0]，不取得调用方资源所有权。
// 失败/边界：rdma_hw_sq_signature_xor 先检查 image == null；i != 16，再返回 value；拒绝分支不提交部分状态，也不隐式重试。
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

// 功能：validate_sq_signature 校验 wqe、sgb、valid 与当前对象状态的一致性，并显式处理“SQ signature image metadata is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：wqe（输入）、sgb（输入）、valid（输出）；validate_sq_signature 读取 wqe、sgb、valid 并使用字段 valid、expected，并写入 valid；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
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
  `uvm_object_utils(rdma_hw_sqe_rc_codec)
  protected rdma_sq_payload_mode_e last_mode;
  protected bit [3:0] last_hw_opcode;

  // 功能：构造 rdma_hw_sqe_rc_codec，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：last_mode=RDMA_SQ_PAYLOAD_NONE；last_hw_opcode=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_sqe_rc_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_sqe_rc_codec");
    super.new(name);
    last_mode = RDMA_SQ_PAYLOAD_NONE;
    last_hw_opcode = 0;
  endfunction

  // 功能：在 rdma_hw_sqe_rc_codec 中，map_opcode 把输入枚举或资源类型映射成对应的状态类别、执行引擎、opcode 或生命周期策略。
  // 输入/输出及副作用：opcode（输入）、hw_opcode（输出）；map_opcode 读取 opcode、hw_opcode 并使用字段 hw_opcode，并写入 hw_opcode；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：map_opcode 返回 RDMA_SC_UNSUPPORTED_OPCODE；典型拒绝条件为“RC SQE opcode is unsupported”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：payload_length 将调用方声明长度与共享 authority 的 inline byte count
  //   合成为 RC writer 的候选长度；SGE 实长随后由 descriptor 遍历覆盖。
  // 输入/输出及副作用：x、mode、inline_payload_bytes 为只读输入；返回候选长度，
  //   不扫描/计数 SGE，也不修改模型、builder 或外部 backing。
  // 失败/边界：非零 total_payload_len 保持调用方声明供后续一致性检查；atomic
  //   缺省为 8，NONE/SGE 缺省为 0；本 helper 不单独判错或截断长度。
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

  // 功能：在 rdma_hw_sqe_rc_codec 中，put_header 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：x（输入）、mode（输入）、hw_opcode（输入）、b（输入）；put_header 读取 x、mode、hw_opcode、b 并使用字段 ce_value、fence_value、se_value、s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：put_header 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
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

  // 功能：在 rdma_hw_sqe_rc_codec 中，put_sge 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：b（输入）、slot（输入）、sge（输入）；put_sge 读取 b、slot、sge 并使用字段 encoded_length、s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：put_sge 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
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

  // 功能：body_and_header 按共享 mode/count derivation 校验 RC payload shape，
  //   把 inline、direct SGE、external SGB 或 atomic fixed body 写入 builder，
  //   并生成签名覆盖所需的外部 SGB bytes 与公共 header 字段。
  // 输入/输出及副作用：x 为只读 hardware model，b 接收已校验字段；mode
  //   返回最终 payload mode，signature_sgb 返回 detached 外部 payload/descriptor
  //   字节；成功会更新 b，但不修改 x、SGE 或外部 Host-memory。
  // 失败/边界：opcode/mode 不相容、READ 无 SGE、长度/保留位/SGE 阈值非法、
  //   SGB IOVA 未按 512-byte 对齐或 builder 写入失败时返回非 OK；null SGE
  //   即使不参与 canonical 数值计数仍明确拒绝，失败结果不得发布 image。
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
      sge_length = 0;
      foreach (x.sges[i]) begin
        if (x.sges[i] == null)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "RC SQE contains a null SGE");
        if (x.sges[i].length == 0)
          continue;
        if (x.sges[i].length != 32'h8000_0000 &&
            x.sges[i].length[31])
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "RC SGE length uses reserved bit 31");
        sge_length += x.sges[i].length;
      end
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
        // A zero-byte IB_SEND_INLINE is a legal driver shape.  The detached
        // builder is already zero-filled, so an empty memcpy must be skipped
        // rather than passed to the helper, which intentionally rejects an
        // empty source range.
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
        // SGE-SGB entries are stored as 16-byte big-endian descriptors in
        // the external 512-byte SGB.  The descriptor bytes are not part of
        // the 64-byte WQE image, but they are covered by the WQE signature.
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

  // 功能：allow_urc_read_total_packet_num 由 URC 子 codec 根据当前 raw image
  //       的 payload mode 与 hardware opcode 声明 qword5[63:40] 是否属于
  //       驱动定义的 TOTAL_PKT_NUM 字段。
  // 输入/输出及副作用：raw_mode、raw_opcode 来自本次 check_reserved 解析的
  //       builder；函数只返回授权 bit，不读取或修改 codec 历史状态、模型和资源。
  // 失败/边界：基类默认拒绝；普通 RC、direct-SGE、inline 和未知 opcode 即使
  //       之前编码过 URC READ，也不能获得旧状态遗留的字段授权。
  protected virtual function bit allow_urc_read_total_packet_num(
      rdma_sq_payload_mode_e raw_mode,
      bit [3:0] raw_opcode);
    return 1'b0;
  endfunction

  // 功能：rc_qword1_allowed_mask 返回 RC/URC SQE qword1 在当前硬件 opcode
  //   下真正由驱动写入的位；payload length 始终占低 32 位，immediate 或
  //   invalidate key 只对驱动明确支持的 opcode 占高 32 位。
  // 输入/输出及副作用：无显式输入；函数只读取 last_hw_opcode，不修改 codec
  //   状态、builder 或模型，返回用于 reserved-bit 检查的 64-bit mask。
  // 失败/边界：未知 opcode 不获得 immediate 位；调用方仍须对 NONE 模式的
  //   payload length 和 LOCAL_INV 的低 32 位执行额外零值检查。
  protected function bit [63:0] rc_qword1_allowed_mask();
    bit [63:0] allowed;

    allowed = 64'h0000_0000_ffff_ffff;
    if (last_hw_opcode inside {RDMA_SQ_OPCODE_SEND_WITH_IMM,
                               RDMA_SQ_OPCODE_SEND_WITH_INV,
                               RDMA_SQ_OPCODE_WRITE_WITH_IMM,
                               RDMA_SQ_OPCODE_LOCAL_INV})
      allowed |= 64'hffff_ffff_0000_0000;
    return allowed;
  endfunction

  // 功能：rc_opcode_has_remote_address 判断当前 RC/URC hardware opcode 是否
  //   拥有 qword2 的 remote-key 与 qword3 的 remote-VA 坐标。
  // 输入/输出及副作用：无显式输入；只读取 last_hw_opcode，返回驱动
  //   xtrdma_set_rc_read_write_wqe() 是否会写入 remote address，不修改 codec。
  // 失败/边界：SEND、LOCAL_INV 和未知 opcode 返回 false；atomic 使用独立
  //   payload layout，不通过本函数扩大普通 RC body mask。
  protected function bit rc_opcode_has_remote_address();
    return last_hw_opcode inside {
      RDMA_SQ_OPCODE_WRITE,
      RDMA_SQ_OPCODE_WRITE_WITH_IMM,
      RDMA_SQ_OPCODE_READ
    };
  endfunction

  // 功能：rc_qword2_allowed_mask 按 opcode 返回 RC/URC qword2 的字段所有权；
  //   signature 与 SGE_NUM 始终存在，remote-key 只属于 READ/WRITE。
  // 输入/输出及副作用：无显式输入；读取 last_hw_opcode 并返回 64-bit mask，
  //   不修改 builder、模型或 payload mode。
  // 失败/边界：SEND/LOCAL_INV/未知 opcode 不放行低 32 位，防止跨 opcode
  //   复用同一物理 qword 时把驱动固定为零的区域误当作有效字段。
  protected function bit [63:0] rc_qword2_allowed_mask();
    bit [63:0] allowed;

    allowed = 64'hffff_0000_0000_0000;
    if (rc_opcode_has_remote_address())
      allowed |= 64'h0000_0000_ffff_ffff;

    return allowed;
  endfunction

  // 功能：check_reserved 校验 b 与当前对象状态的一致性，并显式处理“RC SQE
  //   does not contain eight qwords”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：b（输入）；check_reserved 从 b 的硬件 header 提取
  // opcode、INLINE_LOCAL_QPC_RD、SGE_NUM 和 payload length，计算本次 image
  // 的字段所有权并返回校验状态；不修改 builder 或外部资源。
  // 失败/边界：check_reserved 不依赖上一次 encode 留下的 last_hw_opcode/last_mode；
  // 只要 raw opcode 未列入驱动 ABI、header/body 保留位非零或 mode/长度几何不符，
  // 即返回 CODEC_ERROR，避免 fresh/reused codec 对同一 raw image 得出不同结果。
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
              // wr.h exposes each direct-SGE length as GENMASK(30, 0).
              // The value's bit31 is qword bit63 and remains reserved even
              // though the rest of the descriptor qword is driver-owned.
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
      // xtrdma_hw.h/wr.c 固定一个 SQ-SGB slot 为 512B，并以 16B chunk
      // 编码 inline payload；因此 32B 以内必须留在 WQE，超过 512B 或
      // 超过 32 个 chunk 的 raw image 都不能仅因 TPL/SGE_NUM 字段宽度
      // 足够而被接受。先检查真实 slot 容量，再检查 count 与长度的几何
      // 关系，避免把一个越过 backing slot 的 image 误判为合法 detached model。
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
      // wr.h/wr.c fix both atomic length views to eight bytes: the common
      // total payload field and the local SGE length at qword4[63:32].
      // Validate the raw local field before decode_fields can synthesize a
      // semantic SGE and accidentally hide a malformed wire value.
      if (count != 1 ||
          w[1][31:0] !== 32'd8 ||
          w[4][63:32] !== 32'd8)
        return err("RC atomic length or SGE count is invalid");
    end else if (raw_mode == RDMA_SQ_PAYLOAD_NONE) begin
      // wr.c publishes SEND/WRITE WQEs with num_sge==0 when the payload
      // length is zero.  LOCAL_INV is the only opcode that has no payload
      // by definition, but ordinary non-read opcodes may use this same wire
      // shape; READ and atomics are selected into their own modes above.
      if (raw_opcode == RDMA_SQ_OPCODE_READ ||
          raw_opcode inside {RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP,
                             RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD} ||
          count != 0 || w[1][31:0] != 0)
        return err("RC empty body opcode or length is invalid");
    end
    return rdma_status::success();
  endfunction

  // 功能：validate_image 校验 image 与当前对象状态的一致性，并显式处理“rc_image_probe”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image（输入）；validate_image 读取 image 并使用字段 b、raw、s、last_hw_opcode、last_mode；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
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
          // A zero SGE count is the driver's legal zero-payload shape.  Do
          // not classify it as a direct-SGE body, whose count range starts
          // at one and would reject a valid SEND/WRITE WQE.
          last_mode = RDMA_SQ_PAYLOAD_NONE;
        else
          last_mode = w[2][55:48] <= 2 ? RDMA_SQ_PAYLOAD_SGE_WQE :
                                         RDMA_SQ_PAYLOAD_SGE_SGB;
      end
    end
    s = super.validate_image(image);
    if (!s.ok())
      return s;
    // Image-only validation cannot authenticate SGB-backed payload bytes,
    // because the detached 512-byte host-memory slot is not part of
    // rdma_hw_image.  Callers holding that slot must use validate_sq_signature
    // with the exact 512-byte SGB after this structural validation succeeds.
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

  // 功能：encode_fields 在 detached SQE candidate 上投影 RC extension，再编码
  //   body/header/signature，避免 wire-effective remote 字段回写 caller model。
  // 输入/输出及副作用：model 为只读输入，b 为待提交 builder；成功更新 b 与
  //   codec 的 last_* 诊断状态；opcode 映射成功后即可能更新 last_hw_opcode，
  //   即使后续 body 拒绝。源 model、extension、SGE、payload 和 handle 始终不变。
  // 失败/边界：类型/clone/extension/opcode、payload 几何或 builder 写入失败时返回
  //   非 OK；candidate 与局部 builder 内容被丢弃，源模型不需要回滚且 image 不发布。
  protected virtual function rdma_status encode_fields(
      rdma_hw_model model,
      rdma_hw_qword_builder b);
    rdma_hw_sqe_model source;
    rdma_hw_sqe_model candidate;
    rdma_sqe_rc_ext ext;
    uvm_object cloned_object;
    rdma_status s;
    rdma_sq_payload_mode_e mode;
    byte unsigned signature_sgb[$];
    byte unsigned serialized[];
    bit [7:0] signature;
    bit [3:0] hw_opcode;

    if (!$cast(source, model))
      return err("RC SQE model type mismatch");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(candidate, cloned_object))
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

  // 功能：decode_fields 将已通过结构校验的 RC SQE 解成 detached 模型；ordinary
  //   opcode 先以 raw INLINE_LOCAL_QPC_RD 判 inline，再以非 inline count=0 判 NONE，
  //   并恢复 inline_data 与 WQE 内 inline_bytes，保证零字节 inline 可原样重编码。
  // 输入/输出及副作用：b 为只读 builder，model 为输出；成功发布新建 SQE、RC
  //   extension、投影 QP handle 及 direct descriptor，不接管 image/backing 所有权。
  // 失败/边界：字段读取失败时返回非 OK 且不发布 model；external-SGB
  //   raw image 仅恢复 SGB 指针/count，因没有 detached 512B bytes 不伪造 payload，
  //   后续需要 payload/signature authority 的调用方必须另行提供该 backing 快照。
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
        // wr.h opcode 3 is SEND_WITH_INV; qword1[63:32] is the
        // invalidate_rkey alias and must survive detached round-trips.
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
      // INLINE_LOCAL_QPC_RD 是 ordinary opcode 的首要 raw mode authority；
      // 即使 TPL/count 都为零也必须保留 inline 语义，才能 byte-exact 重编码。
      // 非 inline 时 count==0 才表示 NONE，其余按 direct/external 阈值解析。
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
          // The driver owns only SGE length[30:0]; bit31 was already
          // rejected by check_reserved and is intentionally not projected
          // into the semantic model during raw decode.
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
  `uvm_object_utils(rdma_hw_sqe_ud_codec)
  // 功能：构造 UD SQE codec，复用 RC 基础 builder 与签名状态。
  // 输入/输出及副作用：name 为输入；仅初始化本地 codec 状态，不取得队列或 DMA 所有权。
  // 失败/边界：构造不验证请求；调用 encode 时仍会执行完整 UD authority 与 payload 校验。
  function new(string name = "rdma_hw_sqe_ud_codec");
    super.new(name);
  endfunction

  // 功能：校验 UD SQE 的 header、AH 元数据和 64B 固定几何。
  // 输入/输出及副作用：b 为输入；从 raw header 提取 opcode 与
  // INLINE_LOCAL_QPC_RD，计算 qword0/qword1 的驱动字段所有权；不修改模型、
  // codec 历史状态或 backing。
  // 失败/边界：qword 数量不是 8、SIGN_EN 为零、驱动未定义 opcode、header
  // 保留位或未定义 body 位非零时拒绝；判定不依赖上一次 encode 的 last_*。
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

    // offset=8 的 qword 由 payload length、destination vport、FWD/LAG/
    // tunnel/IPv6/VLAN 和（按 opcode）立即数覆盖，bit25 是唯一 reserved。
    // offset=16 的 qword 则由 signature、SGE_NUM、DMAC 完整覆盖。
    allowed_payload = 64'h0000_0000_fdff_ffff;
    if (raw_opcode inside {RDMA_SQ_OPCODE_SEND_WITH_IMM,
                           RDMA_SQ_OPCODE_SEND_WITH_INV})
      allowed_payload |= 64'hffff_ffff_0000_0000;
    // wr.c computes INLINE_LOCAL_QPC_RD through
    // xtrdma_get_inline_local_qpc_rd_flag(), which returns the inline flag
    // for every IB_SEND_INLINE request that uses the SGB path as well as for
    // the zero-byte WQE shape.  The bit therefore follows the payload mode,
    // not the storage location of the bytes.
    allowed_header = w[0][60] ? 64'hffff_ffff_ffff_ffff :
                     64'hefff_ffff_ffff_ffff;
    if (w[0][56] !== 1'b1 ||
        !rdma_raw_qword_mask_is_valid(
          w[0], allowed_header) ||
        !rdma_raw_qword_mask_is_valid(w[1], allowed_payload))
      return err("UD SQE reserved bits are nonzero");
    return rdma_status::success();
  endfunction

  // 功能：把共享 payload authority 归一成驱动 xtrdma_set_ud_wqe() 的物理
  //   8..56B 布局，并让 TPL、INLINE、SGE_NUM、SGB bytes 与 signature 同源。
  // 输入/输出及副作用：model 为只读输入，b 为输出；成功更新 detached builder
  //   及 last_* 诊断状态，SGB bytes 仅参与签名并由 queue-data writer 另行写入
  //   Host-memory；opcode 映射后即可能更新 last_hw_opcode，即使后续 validation 拒绝。
  // 失败/边界：非 UD 扩展、tunnel、mode/opcode 不相容、inline 超过 512B、
  //   descriptor 超过 32、TPL 超过 14 bit、SGB IOVA 未对齐或长度不一致时，
  //   均在首个字段/signature 写入前返回错误，不发布 image 或取得 backing 所有权。
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

    if (!$cast(x, model)) return err("UD SQE model type mismatch");
    if (x.transport != RDMA_TRANSPORT_UD) return err("UD codec received non-UD SQE");
    if (!$cast(ext, x.transport_ext)) return err("UD extension type mismatch");
    s = ext.validate(x.opcode); if (!s.ok()) return s;
    s = map_opcode(x.opcode, op); if (!s.ok()) return s;
    last_hw_opcode = op;
    av = ext.address_vector;
    if (av == null) return err("UD SQE address vector is null");

    // 53 上 0.1.34 驱动 wr.c:735 固定以 FIELD_PREP(..., 0) 写入
    // XTRDMA_SQ_WQE_UD_TUNNEL（wr.h:116 为 bit29）；该内核路径没有
    // 可编码的 tunnel capability。拒绝非零请求，避免生成驱动永远不会发出的
    // wire image，也不静默清除调用方的语义输入。
    if (av.tunnel_enable)
      return rdma_status::make(
          RDMA_SC_UNSUPPORTED_OPCODE,
          "UD SQE tunnel flag is unsupported by kernel driver ABI");

    // semantic mode、过滤后的 descriptor 数、inline 字节源/长度与 raw count
    // 必须来自同一次 authority derivation。后续遍历只校验、累计 TPL 和序列化，
    // 不再形成 UD 私有的 mode/count 公式。
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
        if (valid_sge_count != sge_count)
          return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "UD payload authority count is inconsistent");
        if (sge_count > RDMA_MAX_WQ_SGE)
          return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "UD external SGB SGE count exceeds driver limit of 32");

        foreach (x.sges[i]) begin
          if (x.sges[i] == null)
            return rdma_status::make(
                RDMA_SC_INVALID_ARGUMENT,
                "UD SQE contains a null SGE");
          if (x.sges[i].length == 0)
            continue;
          length += x.sges[i].length;
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
    // UD driver 把非零 IB_SEND_INLINE payload 放进外部 SQ-SGB，但
    // xtrdma_get_inline_local_qpc_rd_flag() 仍将 INLINE_LOCAL_QPC_RD 置 1；
    // 因此 mode 必须保留 INLINE_SGB，而不能仅按 SGB 的物理存储位置改写成
    // SGE_SGB。只有非 inline descriptor 使用 SGE_SGB。
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
    // driver 使用 memcpy 写入目标 IP；将数组按大端 qword 组合可保持最终 image 字节顺序。
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

  // 功能：明确拒绝仅携带 64B WQE 的 UD decode，避免把外部 SGB/AH 缺失的镜像
  // 错误解释成 RC transport；完整 decode 由后续带 SGB/AH 输入的接口负责。
  // 输入/输出及副作用：image 为输入；不修改 image 或 codec 状态。
  // 失败/边界：任何 UD image 都返回 UNSUPPORTED_OPCODE，调用方必须提供带外部
  // SGB/AH 证据的专用解析入口后才能建立可认证的 UD 模型。
  virtual function rdma_status validate_image(rdma_hw_image image);
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                              "UD decode requires external SGB and AH evidence");
  endfunction
endclass

class rdma_hw_sqe_urc_codec extends rdma_hw_sqe_rc_codec;
  `uvm_object_utils(rdma_hw_sqe_urc_codec)
  // 功能：构造 URC SQE codec，保留 completion-QP authority 校验状态。
  // 输入/输出及副作用：name 为输入；仅初始化本地 codec 状态，不接管 completion QP 生命周期。
  // 失败/边界：缺少 completion-QP authority、远端字段或 payload 形状非法时拒绝。
  function new(string name = "rdma_hw_sqe_urc_codec");
    super.new(name);
  endfunction

  // 功能：path_mtu_is_driver_valid 确认 PMTU 是 0.1.34 驱动实际支持的
  //       QPC 值，避免用默认值或未经认证的任意粒度计算 packet 数。
  // 输入/输出及副作用：path_mtu_bytes 为输入；函数只读取该值并返回 bit，
  //       不修改 SQE、QPC 或 backing 所有权。
  // 失败/边界：256/512 在 qp.h 中标为 reserved/hw unsupported；零值、非
  //       2 的幂和 1024/2048/4096/8192 之外的值均返回 false。
  protected function bit path_mtu_is_driver_valid(int unsigned path_mtu_bytes);
    return path_mtu_bytes inside {1024, 2048, 4096, 8192};
  endfunction

  // 功能：calculate_total_packet_num 按 wr.c 的 ALIGN(length, PMTU)/PMTU
  //       规则累计 external-SGB URC READ 的 descriptor packet 数。
  // 输入/输出及副作用：x、mode 为输入，total_packet_num 为输出；只读取 SGE
  //       快照和冻结 PMTU，不修改 SGE、builder 或外部 host memory。
  // 失败/边界：仅对 SGE_SGB + RDMA_READ 计算；PMTU 缺失/不受支持、null SGE、
  //       保留长度位或累计值超出 24 bit 时返回 INVALID_ARGUMENT，调用方不得编码。
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

  // 功能：allow_urc_read_total_packet_num 授权当前 raw URC external-SGB READ
  //       的 qword5[63:40] TOTAL_PKT_NUM 字段，保持 reserved 检查可重复。
  // 输入/输出及副作用：raw_mode、raw_opcode 是本次 builder 的 wire 坐标解析值；
  //       函数只比较它们并返回 bit，不修改 last_mode、last_hw_opcode 或模型。
  // 失败/边界：只有 SGE_SGB + RDMA_SQ_OPCODE_READ 获得授权；direct-SGE、inline、
  //       RC 继承调用和未知 opcode 均返回 false，qword5[39:0] 仍必须为零。
  protected virtual function bit allow_urc_read_total_packet_num(
      rdma_sq_payload_mode_e raw_mode,
      bit [3:0] raw_opcode);
    return raw_mode == RDMA_SQ_PAYLOAD_SGE_SGB &&
           raw_opcode == RDMA_SQ_OPCODE_READ;
  endfunction

  // 功能：校验 URC SQE header 保留位和固定 64B 几何。
  // 输入/输出及副作用：b 为输入；仅读取 qword，不修改 builder。
  // 失败/边界：qword 数量非 8 或保留位非零时返回 CODEC_ERROR。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b);
    // URC 的 data-plane WQE 与 RC 共用 qword1..7；复用 RC body mask 可避免
    // 把 completion-QP 这一控制面 authority 误写入 payload/SGE 区。
    return super.check_reserved(b);
  endfunction
    // 功能：编码 URC 目的 QPN、可用远端字段和 complement-XOR signature。
    // 输入/输出及副作用：model 为输入、b 为输出 builder；completion-QP 仅做 authority 校验。
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
      // wr.c writes byte 0x28 after filling external SGB descriptors; this
      // field is part of the 64B WQE signature and must be written before the
      // complement-XOR is calculated below.
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

  // 功能：明确拒绝仅携带 64B WQE 的 URC decode，防止继承 RC decode 后丢失
  // completion-QP authority 和 URC sequence 证据。
  // 输入/输出及副作用：image 为输入；不修改 image 或 codec 状态。
  // 失败/边界：任何 URC image 都返回 UNSUPPORTED_OPCODE，调用方必须通过带
  // completion-QP/epoch 的专用解析接口完成认证。
  virtual function rdma_status validate_image(rdma_hw_image image);
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                              "URC decode requires completion-QP evidence");
  endfunction
endclass

class rdma_hw_rqe_codec extends rdma_hw_queue_codec_base;
  `uvm_object_utils(rdma_hw_rqe_codec)

  // decode_fields 只在构造 detached external model 的瞬间建立这个 capability
  //   window；active model 采用对象 identity 比较，避免 fresh caller 伪造 raw marker。
  local bit raw_decode_authorization_active;
  local rdma_hw_rqe_model active_raw_decode_model;

  // 驱动 wr.h/wr.c 将 qword4 复用为两种物理布局：最多两个有效 SGE
  // 直接内联，更多 SGE 时写入外部 SGB_PA。codec 必须依据 wire 上的
  // SGE_NUM、SGE qword 和 SGB 对齐位判定布局，不能用放宽保留位掩码掩盖歧义。
  // 功能：构造 rdma_hw_rqe_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_rqe_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_rqe_codec");
    super.new(name);
    raw_decode_authorization_active = 1'b0;
    active_raw_decode_model = null;
  endfunction

  // 功能：is_raw_decode_authorization_active 把 model candidate 与当前 codec 的
  //   decode-active seam 做 identity 比对，供 RQE model 建立 opaque provenance。
  // 输入/输出及副作用：candidate 为输入；返回只读 bit，不修改 codec、model、image
  //   或外部 host-memory/backing 所有权。
  // 失败/边界：codec 未处于 decode_fields 的 active window、candidate 为空或不是
  //   当前 active 对象时返回 0；该 accessor 不提供设置 capability 的入口。
  function bit is_raw_decode_authorization_active(
      rdma_hw_rqe_model candidate);
    return raw_decode_authorization_active &&
           candidate != null && candidate == active_raw_decode_model;
  endfunction
  // 功能：在 rdma_hw_rqe_codec 中，image_check 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：b（输入）；image_check 读取 b 的 8 个 qword，校验 RQE 保留位和未使用 qword；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：image_check 拒绝 header/meta 保留位、inline SGE 的长度
  // bit63、外部 SGB_PA 的低九位以及未使用 qword；两种布局均严格按
  // wr.h 的字段坐标检查，不能靠放宽整字掩码吞掉驱动 ABI 错误。
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

    // wr.h:177/182 and wr.c:1159-1165 define RQE opcode 0x9 as a
    // hardware-fixed receive-WQE type.  It is not a caller-selected field;
    // reject any other raw value before layout inference or model publish.
    if (words[0][35:32] !== 4'h9)
      return err("RQE hardware opcode is not the fixed receive opcode 0x9");

    inline_sge_count = words[2][55:48];
    // wr.c/queue data 只支持 32 个有效 SGE；qword2 的 SGE_NUM 超出该
    // 上限不是另一种合法布局，必须在任何 inline/external 分支前拒绝。
    if (inline_sge_count > RDMA_MAX_WQ_SGE)
      return err("RQE SGE count exceeds driver limit of 32");
    inline_mode = inline_sge_count <= 2;

    // 每个 raw qword 都通过四态 helper 检查，而不是把 `& ~mask` 与
    // equality 运算符直接拼在条件里；这样既避免优先级回归，也让未知位
    // 在进入 RQE layout 分支前 fail-closed。下面的 mask 数值严格来自 wr.h。
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

    // The driver writes TPL from the same valid SGE lengths that populate the
    // inline descriptors.  A zero wire length is the 2-GiB sentinel, not an
    // empty descriptor, so validate the semantic sum rather than merely
    // checking that qword4/qword6 contain non-zero identity fields.
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
  // 功能：在 rdma_hw_rqe_codec 中，image_kind_expected 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：无显式参数；image_kind_expected 读取 对象字段：s、s.message、x、model 并使用字段 s、s.message、x、model；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：image_kind_expected 是只读访问器，返回 RDMA_IMAGE_RQE；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_RQE;
  endfunction

  // 功能：image_bytes 返回 RQE 固定的硬件镜像长度，供基类 metadata 校验和
  // builder 分配使用。
  // 输入/输出及副作用：无输入；返回 RDMA_RQE_BYTES，不修改 codec 状态或外部资源。
  // 失败/边界：RQE profile 只有 64B，函数不接受运行期扩展长度。
  protected virtual function int unsigned image_bytes();
    return RDMA_RQE_BYTES;
  endfunction

  // 功能：check_reserved 统一调用 RQE 专用保留位检查，确保编码和解码采用
  // 相同的驱动掩码，而不是分别维护两份规则。
  // 输入/输出及副作用：b 为待检查的 qword builder；返回校验状态，不修改 builder。
  // 失败/边界：b 为空或任一未声明位非零时沿 image_check 返回 CODEC_ERROR。
  protected virtual function rdma_status check_reserved(
      rdma_hw_qword_builder b);
    if (b == null)
      return err("RQE qword builder is null");
    return image_check(b);
  endfunction

  // 功能：validate_rqe_signature 按 wr.c 的 xtrdma_calculate_wqe_signature
  //       校验已解码 RQE 的完整 WQE 字节和可选外部 SGB descriptor 字节。
  // 输入/输出及副作用：image、model 和 descriptor_bytes 为只读输入；
  //       descriptor_authority_valid 表示调用方是否提供了真实 SGB authority；
  //       成功时不修改 model，失败时仅把 model 清空，不取得 image/backing 所有权。
  // 失败/边界：inline RQE 只允许空 descriptor authority；external RQE 必须提供
  //       恰好 SGE_NUM*16 字节，缺失、长度不符或 complement-XOR 失配均返回错误，
  //       禁止用零填充替代宿主内存中的 descriptor。
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

  // 功能：decode 重用队列基类的长度、保留位和字段解码流程，并在发布
  //       detached RQE 前验证 inline/no-SGB signature；external RQE 因缺少
  //       host-memory descriptor authority 必须 fail-closed。
  // 输入/输出及副作用：image 为输入，model 为输出；成功发布完整 detached
  //       RQE model，失败保持 model=null，不修改 image 或外部 backing。
  // 失败/边界：metadata/保留位/字段解码失败原样返回；签名缺失、失配或
  //       external authority 不可证明时返回明确状态，不把 descriptor 当作零字节。
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

  // 功能：decode_with_sgb_descriptor_bytes 在完成普通 RQE 解码后注入调用方
  //       提供的真实 external-SGB descriptor authority，并按 wr.c 完整 XOR
  //       规则验证签名，供 host-memory/queue-data 读取路径使用。
  // 输入/输出及副作用：image、descriptor_bytes 为输入，model 为输出；成功时
  //       发布携带 detached descriptor authority 的 RQE model，不取得输入数组或
  //       image 所有权；失败保持 model=null。
  // 失败/边界：仅 external RQE 接受恰好 SGE_NUM*16 字节；inline RQE、长度不符、
  //       raw image/字段解码失败或 signature XOR 失配均拒绝，不进行截断、补零或重试。
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

  // 功能：在 rdma_hw_rqe_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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

    // wr.c selects inline RQE storage for at most two valid SGEs.  A nonzero
    // SGB_PA is the explicit model-side request for the external SGB layout,
    // which preserves the existing queue-data path for larger SGE lists.
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

      // A typed request owns descriptor values through its detached SGE list;
      // a decoded raw model owns no descriptor bytes until the caller supplies
      // an explicit authority.  Both paths must yield exactly N*16 bytes.
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

    // wr.c computes sign_en = rq_sign_en || use_sgb.  The model's sign_en
    // captures the first operand; external SGB mode supplies the second and
    // therefore has to force the physical header bit even when the caller
    // left sign_en clear.
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

        // wr.c masks with GENMASK(30,0); its documented zero value denotes
        // a 2-GiB SGE.  Preserve that sentinel explicitly rather than
        // allowing bit31 to leak into the reserved wire position.
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

    // wr.c computes the complement after header and body are complete, while
    // the still-unoccupied signature byte remains zero in the fresh builder.
    // Serialize that exact 64B image, include only the actual external
    // descriptors (not the 512B tail), and write the signature exactly once;
    // qword-builder occupancy intentionally rejects a second write to a field.
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
  // 功能：在 rdma_hw_rqe_codec 中，decode_fields 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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
          // wr.c's XTRDMA_WQE_SGE_LEN_LOW reserves bit31 and documents a
          // zero wire value as the 2-GiB semantic length.  Restore that
          // sentinel in the detached model instead of exposing an ambiguous
          // zero-length SGE to callers.
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
  `uvm_object_utils(rdma_hw_cqe_codec)
  protected int unsigned active_bytes;
  protected rdma_cqe_variant_e active_variant;
  protected bit variant_is_explicit;

  // 功能：构造 CQE codec 并默认选择历史 64B profile，同时建立 RC overlay
  //       作为兼容初值；codec 只拥有这些本地配置，不拥有 ring 或 image。
  // 输入/输出及副作用：name 为输入；new 调用 super.new，初始化 active_bytes、
  //       active_variant 和 variant_is_explicit，返回 void，不修改外部资源。
  // 失败/边界：构造不会验证或接管外部 CQ/QP/backing；未通过 set_entry_bytes 或
  //       set_variant 配置的调用仍由后续 encode/decode 的 metadata 检查拒绝。
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

  // 功能：set_variant 选择 raw CQE qword2/qword3 overlay 的硬件 authority，
  //       让同一 codec 在 RC、UD 与 RQ/SRFQ completion 间保持显式边界。
  // 输入/输出及副作用：variant 为输入；成功时更新 codec 的解码 variant，
  //       不改变 entry bytes、镜像或外部 ring 所有权。
  // 失败/边界：未知 enum 值被拒绝并保留旧 variant；默认 RC 只接受 RC overlay，
  //       调用方必须在解码 UD/RQ raw image 前显式选择对应 authority。
  function rdma_status set_variant(rdma_cqe_variant_e variant);
    if (variant > RDMA_CQE_VARIANT_RQ_SRFQ)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "CQE variant is invalid");

    active_variant = variant;
    variant_is_explicit = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：set_ud_qword3_enabled 保留历史测试/adapter seam，并将其映射到
  //       显式 UD variant；它不放宽其他 qword 的 reserved 检查。
  // 输入/输出及副作用：enabled 为输入；更新 active_variant，不修改 profile
  //       长度、已编码 image 或外部资源所有权。
  // 失败/边界：关闭时回到 RC authority；未显式启用 UD 时 qword3 非零仍被拒绝。
  function rdma_status set_ud_qword3_enabled(bit enabled);
    active_variant = enabled ? RDMA_CQE_VARIANT_UD : RDMA_CQE_VARIANT_RC;
    variant_is_explicit = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：validate_variant_value 检查调用方提供的 CQE overlay authority 是否
  //       对应驱动已定义的 RC、UD 或 RQ/SRFQ 三种语义视图。
  // 输入/输出及副作用：variant 为输入；返回校验状态，不修改 codec、model、
  //       image 或外部 ring 的任何状态。
  // 失败/边界：枚举值 3 或未知 X/Z 不能进入显式编解码入口，返回
  //       RDMA_SC_INVALID_ARGUMENT；合法值按原样接受。
  protected function rdma_status validate_variant_value(
      rdma_cqe_variant_e variant);
    if (variant > RDMA_CQE_VARIANT_RQ_SRFQ)
      return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "CQE variant is invalid");
    return rdma_status::success();
  endfunction

  // 功能：validate_cqe_image_metadata 集中校验显式 CQE profile 的镜像尺寸、代际、
  //   端序、类型、硬件版本和写入目标，供解码与仅校验入口共用同一前置门禁。
  // 输入/输出及副作用：image、entry_size（输入）；函数只读取 image metadata 和
  //   image_kind_expected()，返回 rdma_status，不修改 image、codec、model、builder
  //   或外部 ring/backing 的所有权。
  // 失败/边界：entry_size 不属于 32/64/128 时返回 “CQE profile size is invalid”；
  //   image 为空、generation 为零、length/bytes/alignment 不等于 entry_size、端序不为
  //   BIG、image kind/硬件版本不匹配，或 backing/hmc/bar/write target 非空时，分别保留
  //   两个调用方原有的 queue image null、stale generation 或 queue image metadata 错误。
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

  // 功能：cqe_signature_offset 按驱动 CQE header 的 profile-relative 起点，
  //       计算完整 entry 中 signature byte 的绝对位置。
  // 输入/输出及副作用：entry_size 为输入 profile 大小；函数只读取该值并返回
  //       32/64B 的 byte16 或 128B 的 byte80，不修改 codec、builder 或 image。
  // 失败/边界：调用方必须先确认 entry_size 属于 32、64、128；其他大小返回
  //       0，调用方不得把该保守值当作合法签名位置继续发布 image。
  protected function int unsigned cqe_signature_offset(
      int unsigned entry_size);
    case (entry_size)
      32, 64: return 16;
      128: return 80;
      default: return 0;
    endcase
  endfunction

  // 功能：cqe_signature_without_field 对完整 CQE entry 做逐字节 XOR，但跳过
  //       驱动保留给 signature 的一个 byte，供编码阶段生成补码签名。
  // 输入/输出及副作用：bytes 与 entry_size 为只读输入；返回排除 signature
  //       byte 后的 8 位 XOR，不修改输入数组或任何外部资源。
  // 失败/边界：bytes 长度不是 entry_size 或 profile 不受支持时返回零；调用方
  //       必须先检查长度并处理对应错误，不能把零值解释为有效 parity。
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

  // 功能：validate_cqe_signature_bytes 复现驱动 wr.c 的
  //       xtrdma_check_cqe_signature，对 SIGN_EN=1 的完整 CQE entry 验证
  //       XOR 结果必须为 8'hff。
  // 输入/输出及副作用：bytes、entry_size 和 sign_en 为只读输入；返回统一
  //       rdma_status，不修改 entry bytes、model、builder 或外部 ring。
  // 失败/边界：SIGN_EN=0 时不执行 parity 检查；profile/长度不匹配或完整
  //       image XOR 不是 8'hff 时返回 RDMA_SC_CODEC_ERROR，禁止发布模型。
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

  // 功能：finalize_cqe_signature 在 CQE 字段和 profile payload 全部写入后，
  //       按驱动 complement-XOR 规则派生 typed image 的 signature，或验证
  //       raw qword2 authority 携带的原始 signature 没有失配。
  // 输入/输出及副作用：b、entry_size、sign_en 和 raw_authority 为输入；typed
  //       路径成功时只向 b 的 signature byte 写一次，raw 路径只读并校验 b，
  //       不取得 image/backing/ring 所有权。
  // 失败/边界：SIGN_EN=0 保留调用方 signature；builder/profile 无效、签名字段
  //       已被错误占用或 raw image parity 失效时返回 CODEC_ERROR，不发布半成品。
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

    // Keep the offset as an explicit local invariant: it documents that the
    // profile-relative field and the serialized absolute byte refer to the
    // same wire coordinate, without rewriting the builder a second time.
    if (signature_offset >= serialized.size())
      return err("CQE signature offset is outside the image");

    return rdma_status::success();
  endfunction

  // 功能：encode_with_entry_bytes_variant 为单次 CQE 编码建立独立的 profile
  //       与 variant scope，避免共享 registry codec 的 active_variant 被交错
  //       调用污染，然后复用既有字段/保留位/metadata 检查。
  // 输入/输出及副作用：model、entry_size、variant 为输入，image 为输出；只
  //       创建本次调用私有 codec 和 detached image，不修改当前 codec 的 active
  //       profile/variant，也不取得 ring 或 backing 所有权。
  // 失败/边界：variant、entry_size、model 或任一字段/代际/保留位不合法时返回
  //       明确错误且 image 保持 null；模型 variant 必须与显式 variant 一致。
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

  // 功能：decode_with_entry_bytes_variant 为单次 CQE 解码建立独立的 profile
  //       与 variant scope，按调用方 authority 解出所有 qword2 物理 overlay，
  //       并在模型中保存 raw authority 以支持逐位回编码。
  // 输入/输出及副作用：image、entry_size、variant 为输入，model 为输出；只
  //       创建本次调用私有 codec 和 detached model，不修改当前 codec 的 active
  //       profile/variant 或 image backing 所有权。
  // 失败/边界：variant、entry_size、image metadata、保留位或字段解码失败时
  //       返回错误且 model 保持 null；不会从 qword2 非零值猜测 variant。
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

  // 功能：validate_image_with_entry_bytes_variant 使用一次性 variant scope
  //       校验 CQE metadata、header reserved bits 和显式 qword3 authority，
  //       不让共享 codec 的历史 variant 参与本次判定。
  // 输入/输出及副作用：image、entry_size、variant 为输入；返回状态，不修改
  //       image、当前 codec 状态、model 或外部资源。
  // 失败/边界：variant/profile/metadata/反序列化/reserved 任一检查失败时返回
  //       CODEC_ERROR 或 INVALID_ARGUMENT，且不会发布部分解码模型。
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

  // 功能：按调用方显式提供的 CQE entry profile 解码一份 image，构造独立的
  // qword builder 并返回 detached CQE model；该路径不读取或写入 active_bytes，
  // 因而可被共享 registry codec 并发/交错调用而不会串 profile。
  // 输入/输出及副作用：image、entry_size 为输入，model 为输出；函数只读取 image
  // 字节和 metadata，成功时发布新建 model，不接管 image 或其 backing 所有权。
  // 失败/边界：entry_size 不是 32/64/128、image metadata/代际不匹配、保留位非零、
  // builder 反序列化失败或字段模型创建失败时返回 CODEC_ERROR，并保持 model=null。
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

  // 功能：encode_with_entry_bytes 使用调用方指定的 32/64/128B CQE profile
  //       编码一份 detached 硬件镜像；它为本次调用新建局部 builder，复用
  //       validate_model/encode_fields/check_reserved，并保持 active_bytes 不变。
  // 输入/输出及副作用：model 为只读 CQE 模型，entry_size 为显式 profile，
  //       image 为输出镜像；成功时 image.bytes、length、alignment、endian、
  //       image_kind、hardware_version 和 function_generation 完整发布，
  //       不取得 ring、backing 或其他外部资源的所有权。
  // 失败/边界：entry_size 不是 32/64/128、模型代际无效、builder 分配/复位、
  //       字段编码、保留位检查、序列化或 image 分配失败时返回明确错误，
  //       image 保持 null；进入本函数的任何路径都不能修改 active_bytes。
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

  // 功能：validate_image_with_entry_bytes 按调用方指定的 CQE profile 校验
  //       image metadata 和保留位，避免共享 codec 的 active_bytes 串扰。
  // 输入/输出及副作用：image、entry_size 为输入；函数只读取 image 字节并
  //       构造临时 qword builder，不修改 active_bytes 或外部资源。
  // 失败/边界：entry_size 非 32/64/128、image metadata 不匹配、反序列化失败
  //       或保留位非零时返回 CODEC_ERROR；不会发布部分模型。
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

  // 功能：依据 image 自带长度选择本次 CQE profile 并调用无状态解码入口。
  // 输入/输出及副作用：image 为输入、model 为输出；不会改变 active_bytes 或 image，
  // 成功时发布 detached model。
  // 失败/边界：image 为空或长度不是 32/64/128 时返回 CODEC_ERROR；下游 profile
  // 校验/字段解码失败时原样传播错误，model 保持为空。
  virtual function rdma_status decode(rdma_hw_image image, output rdma_hw_model model);
    model = null;
    if (image == null || !(image.length inside {32, 64, 128}))
      return rdma_status::make(RDMA_SC_CODEC_ERROR, "CQE image size is invalid");
    return decode_with_entry_bytes(image, int'(image.length), model);
  endfunction
  // 功能：在 rdma_hw_cqe_codec 中，image_kind_expected 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：无显式参数；image_kind_expected 返回 CQE codec 固定的 RDMA_IMAGE_CQE 类型，不读取可变对象字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：image_kind_expected 是只读访问器，返回 RDMA_IMAGE_CQE；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_CQE;
  endfunction

  // 功能：image_bytes 返回当前 CQE codec 选择的 active profile 字节数，供
  //       默认 encode/decode 和镜像 metadata 校验使用。
  // 输入/输出及副作用：无显式参数；读取 active_bytes 并返回 32/64/128 之一，
  //       不修改 profile 或取得 ring、image 和 backing 的所有权。
  // 失败/边界：构造前 active_bytes 为历史 64B；set_entry_bytes 拒绝非法尺寸，
  //       因而本函数不会发布未支持的长度。
  protected virtual function int unsigned image_bytes();
    return active_bytes;
  endfunction

  // 功能：check_reserved 按 profile 基址和 active_variant 校验 CQE 的四个
  //       header qword，逐位拒绝驱动未声明的 reserved 区域，并保留合法 payload。
  // 输入/输出及副作用：b 为输入；函数读取 logical qword、active_bytes 和
  //       active_variant，返回校验状态，不修改 builder、镜像或外部资源。
  // 失败/边界：空 builder、qword 数量/profile 不符、qword0/qword1/qword2 的
  //       未声明位、非 UD qword3 非零、128B qword12..15 非零均返回 CODEC_ERROR。
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

    // The 128B prefix is an inline payload window, not a second header.
    if ((words[base_qword] & ~RDMA_CQE_QWORD0_UNION_MASK) !== 64'b0)
      return err("CQE qword0 reserved bits are nonzero");
    if ((words[base_qword + 1] & ~RDMA_CQE_QWORD1_MASK) !== 64'b0)
      return err("CQE qword1 reserved bits are nonzero");

    // qword2 is a physical union, not three independently reserved layouts.
    // The driver reads SIGNATURE, RC_REMOTE_SYNDROME, UD_SRC_QPN and the
    // RQ/SRFQ coordinates from this same word without a wire discriminator.
    // Only [30:28] are absent from every wr.h field and remain reserved.
    if ((words[base_qword + 2] & ~RDMA_CQE_QWORD2_UNION_MASK) !== 64'b0)
      return err("CQE qword2 reserved bits are nonzero");

    if (active_variant != RDMA_CQE_VARIANT_UD &&
        words[base_qword + 3] !== 64'b0)
      return err("CQE qword3 requires UD variant");
    if (active_variant == RDMA_CQE_VARIANT_UD &&
        (words[base_qword + 3] & ~RDMA_CQE_QWORD3_UD_MASK) !== 64'b0)
      return err("CQE qword3 reserved bits are nonzero");

    // 64B qword4..7 and 128B qword0..7/qword12..15 are opaque profile bytes.
    // wr.h/cq.h provide no reserved-zero contract for these locations; a raw
    // CQE decoder must not invent one and reject device-produced payload.

    return rdma_status::success();
  endfunction

  // 功能：validate_raw_qword2_authority 比较 decoded CQE 保存的完整 qword2
  //       与所有物理 overlay 字段，确认没有字段被调用方修改后仍伪装成原始
  //       wire authority。
  // 输入/输出及副作用：x 为输入 detached CQE model；只读取 raw_qword2 和
  //       signature/RC/UD/RQ 字段，返回状态，不修改 model、builder 或 CQ 资源。
  // 失败/边界：raw authority 未设置时返回成功；任一字段与原始坐标不一致时
  //       返回 CODEC_ERROR，调用方必须先 clear_raw_qword2_authority 再编码。
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


  // 功能：在 rdma_hw_cqe_codec 中，encode_fields 按 profile-relative 硬件布局把
  //       输入模型编码到 qword0 或 qword8 起始的 image/缓冲区，并检查字段范围。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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
      // wr.c authenticates the complete entry only when SIGN_EN is set.  Leave
      // this byte unoccupied for the signed typed path so finalize_cqe_signature
      // can derive it from the final header and opaque payload bytes; unsigned
      // images retain the caller-provided signature byte.
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
  // 功能：在 rdma_hw_cqe_codec 中，decode_fields 从 qword0 或 qword8 起始的
  //       profile-relative 硬件窗口解码字段，验证布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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

    // qword2 is physically shared by all three driver views.  Decode every
    // declared coordinate so raw authority can later prove a lossless image;
    // the explicit variant only selects the semantic consumer.
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
  `uvm_object_utils(rdma_hw_ceqe_codec)

  // 功能：构造 rdma_hw_ceqe_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_ceqe_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_ceqe_codec");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_ceqe_codec 中，image_kind_expected 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：无显式参数；image_kind_expected 返回 CEQE codec 固定的 RDMA_IMAGE_CEQE 类型，不读取可变对象字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：image_kind_expected 是只读访问器，返回 RDMA_IMAGE_CEQE；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_CEQE;
  endfunction

  // 功能：image_bytes 返回驱动固定的 CEQE entry 大小，供基类 metadata 校验和
  //   builder 分配使用。
  // 输入/输出及副作用：无输入；返回 RDMA_CEQE_BYTES，不修改 codec 状态或外部
  //   ring 所有权。
  // 失败/边界：CEQE profile 只有 16B，调用方不能通过运行期参数扩大 entry。
  protected virtual function int unsigned image_bytes();
    return RDMA_CEQE_BYTES;
  endfunction

  // 功能：check_reserved 校验 b 的两个 CEQE qword，只拒绝驱动真正保留的位，
  //   并允许 RC/URC overlay 在同一 wire image 中同时出现。
  // 输入/输出及副作用：b（输入）；读取 qword0/qword1 的 raw bits，使用驱动
  //   union mask 返回状态，不修改 builder、模型或外部 ring。
  // 失败/边界：空 builder、qword 数量错误或 union mask 之外的任一 bit 非零时
  //   返回 CODEC_ERROR；URC_FLAG 不再被当作 canonical-zero 的拒绝条件。
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

    // event.c 的 xtrdma_get_ceqe_info() 无条件 FIELD_GET 两个 overlay。
    // qword1_URC_MASK 覆盖 qword1[57:0]，其中包含 RC CI 的重叠坐标。
    qword0_mask = RDMA_CEQE_QWORD0_UNION_MASK;
    qword1_mask = RDMA_CEQE_QWORD1_RC_MASK |
                  RDMA_CEQE_QWORD1_URC_MASK;

    if ((words[0] & ~qword0_mask) !== 64'b0 ||
        (words[1] & ~qword1_mask) !== 64'b0)
      return err("CEQE reserved bits are nonzero");

    return rdma_status::success();
  endfunction

  // 功能：build_urc_qword1 依据 defs.h 的 URC abnormal、SQ/RQ completion
  //       字段构造 qword1 的 URC 视图，不填入 RC consumer-index alias。
  // 输入/输出及副作用：x 为输入 CEQE model；返回逻辑 qword1，不修改 x、builder
  //       或 CEQ backing，也不转移 model 的所有权。
  // 失败/边界：x 为空时返回全零；字段宽度由 model packed 类型保证，物理 alias
  //       的冲突由 build_model_qword1 统一判断。
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

  // 功能：build_rc_qword1 依据驱动 RC_CQ_PI_WRAP/RC_CQ_PI 坐标构造 RC
  //       alias 视图，供 qword1 冲突检查和最终编码使用。
  // 输入/输出及副作用：x 为输入 CEQE model；返回仅含 RC alias 的逻辑 qword1，
  //       不修改 x、builder 或外部 CEQ backing。
  // 失败/边界：x 为空时返回全零；CQ_PI 的 16-bit 宽度由 model 字段保证。
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

  // 功能：validate_profile_authority 检查 CEQE 模型是否已经绑定唯一的 routed CQ
  //       transport，并确认 wire URC_FLAG 与该 transport 一致。
  // 输入/输出及副作用：x 为输入 detached model；函数只读取 profile authority 与
  //       urc_flag，返回状态，不修改模型、builder、CQ attachment 或 runtime。
  // 失败/边界：authority 未设置、transport 不是 RC/UD/URC，或 selector 与 URC
  //       profile 不一致时 fail-closed；函数不从默认枚举值或 qword alias 猜测 profile。
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

  // 功能：validate_canonical_overlay_fields 拒绝 canonical authoring 中不属于当前
  //       routed profile 的 qword1 semantic fields，避免 union mask 变成写入权限。
  // 输入/输出及副作用：x 为输入 detached model；读取 URC/RC alias 字段并返回状态，
  //       不修改模型、raw authority、builder 或 queue 状态。
  // 失败/边界：RC/UD profile 不能携带 URC-only qword1 fields；URC profile 不能
  //       携带 RC CQ_PI alias；该检查只用于新 authoring，raw replay 走显式 seam。
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

  // 功能：build_model_qword1 根据 CEQE 的 selector 选择 RC 或 URC alias
  //       authority，并阻止两个物理重叠视图被静默合并。
  // 输入/输出及副作用：x 为输入 CEQE model；返回可序列化 qword1，读取但不
  //       修改 x 或外部资源。
  // 失败/边界：inactive view 的 alias 为零时作为未声明字段处理；两个非零 alias
  //       不一致时返回 CODEC_ERROR。
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

  // 功能：validate_raw_qword1_authority 确认 decode 保存的原始 qword1 仍与
  //       detached model 字段一致，防止调用方修改字段后悄然忽略变更。
  // 输入/输出及副作用：x 为输入 CEQE model；只读比较 raw_qword1 与两套字段，
  //       返回状态，不修改 model、builder 或外部 CEQ backing。
  // 失败/边界：raw authority 未设置时返回成功；任一 raw/字段 mismatch 返回
  //       CODEC_ERROR，调用方需先 clear_raw_qword1_authority 再重新选择 alias。
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

  // 功能：在 rdma_hw_ceqe_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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

    // qword0 的 URC selector/valid bits 也是 driver-owned wire fields，
    // 即使 selector 为 RC 仍不能被 canonicalize 成零。
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

  // 功能：在 rdma_hw_ceqe_codec 中，decode_fields 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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

    // event.c 解码 RC/URC overlay 无条件；这里也必须把同一 raw image
    // 的两个解释都发布到 detached model，不能因 selector 丢掉 inactive bits。
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
  `uvm_object_utils(rdma_hw_aeqe_codec)

  // 功能：构造 rdma_hw_aeqe_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_aeqe_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_aeqe_codec");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_aeqe_codec 中，image_kind_expected 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：无显式参数；image_kind_expected 返回 AEQE codec 固定的 RDMA_IMAGE_AEQE 类型，不读取可变对象字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：image_kind_expected 是只读访问器，返回 RDMA_IMAGE_AEQE；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_image_kind_e image_kind_expected();
    return RDMA_IMAGE_AEQE;
  endfunction

  // 功能：image_bytes 返回驱动固定的 AEQE entry 大小，供基类 metadata 校验和
  //   builder 分配使用。
  // 输入/输出及副作用：无输入；返回 RDMA_AEQE_BYTES，不修改 codec 状态或外部
  //   ring 所有权。
  // 失败/边界：AEQE profile 只有 16B，调用方不能通过运行期参数扩大 entry。
  protected virtual function int unsigned image_bytes();
    return RDMA_AEQE_BYTES;
  endfunction

  // 功能：check_reserved 校验 b 与当前对象状态的一致性，并显式处理“AEQE reserved bits are nonzero”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：b（输入）；check_reserved 读取 b 并使用字段 s、s.message、x、model；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：check_reserved 是只读访问器，返回 err("AEQE reserved bits are nonzero")；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
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

  // 功能：validate_variant_fields 校验 AEQE detached model 可作为 wire/raw
  //   observation 处理，同时保留 event.c 无条件 FIELD_GET 的 inactive overlay。
  // 输入/输出及副作用：x（输入）是待编码或已解码的 detached AEQE；函数只
  //   确认对象存在，返回状态，不修改 typed 字段、raw image 或外部资源。
  // 失败/边界：x 为空返回 CODEC_ERROR；bit[2:0] QP_ST 的 0..7 均可 decode/
  //   explicit replay，URC_FLAG 或 SRFQ_EN 关闭时 inactive 字段也原样保留；
  //   canonical class/subselector 限制由 validate_canonical_fields 单独执行。
  protected function rdma_status validate_variant_fields(
      rdma_hw_aeqe_model x);
    if (x == null)
      return err("AEQE variant model is null");

    return rdma_status::success();
  endfunction

  // 功能：validate_profile_authority 检查 AEQE canonical model 是否绑定了与
  //   驱动 event.c ecode 分派一致的 class/owner authority。
  // 输入/输出及副作用：x 为 detached AEQE 输入；函数只读取 ecode、profile class
  //   和 owner kind，返回状态，不修改模型、builder、route 或 runtime。
  // 失败/边界：authority 缺失、class 与 ecode 不匹配、owner kind 不属于该 class
  //   或 target_h kind 与 owner 不一致时 fail-closed；不从 srfq_en、urc_flag
  //   或默认 enum 值猜测 owner。
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
    // event.c 的两个 flush case 和 CEQ/AEQ case 还进一步固定了 owner kind；
    // class 级别的允许集合不能把 0x08 错发到 Function，或把 0xfb 错发到 CEQ。
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

  // 功能：build_typed_qword0 按 rdma_defs.svh 的固定坐标重组成 AEQE qword0，
  //   用于 raw replay 前确认 typed 字段未被悄然改写。
  // 输入/输出及副作用：x 为输入；返回 64-bit 物理 qword，不修改 x、builder 或
  //   外部资源；字段坐标直接对应 53 机 0.1.34 event.c 的 FIELD_GET。
  // 失败/边界：x 为空返回全零；该函数不执行 reserved 检查，调用方必须先经过
  //   check_reserved，不能把全零返回当作合法 model。
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

  // 功能：build_typed_qword1 按驱动 event.h 的 URC/SRFQ overlay 坐标重组成
  //   AEQE qword1，供 raw replay 一致性检查和 canonical fallback 使用。
  // 输入/输出及副作用：x 为输入；返回 64-bit 物理 qword，不修改 x 或外部资源。
  // 失败/边界：x 为空返回全零；qword1 的 inactive selector 不会被自动清零，
  //   因为 event.c 对这些字段无条件 FIELD_GET。
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

  // 功能：validate_raw_authority 比较 decode 保存的原始 qword 与 typed 字段，
  //   防止调用方修改某一字段后仍以“raw replay”名义覆盖新值。
  // 输入/输出及副作用：x 为输入 detached model；返回状态，不修改 raw qword、
  //   typed 字段或 route authority。
  // 失败/边界：raw authority 未设置时返回 INVALID_STATE；任一 qword 不一致返回
  //   CODEC_ERROR，调用方需 clear_raw_authority 后重新选择 canonical profile。
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

  // 功能：validate_canonical_fields 按 event.c 的 ecode class 与 CQ-flush/
  //   URC-abnormal subselector 建立 canonical 字段 allowlist，并把 QP_ST、
  //   packet_opcode、SRFQ_EN、CQ-invalid 限制到各自 owner；overflow 仅允许
  //   raw observation。
  // 输入/输出及副作用：x 为已通过 profile authority 的 detached
  //   AEQE；函数只读取 header flags、object IDs 和 URC payload，返回
  //   rdma_status，不修改 raw qword、target_h、builder 或 queue runtime。
  // 失败/边界：QP_ST=6/7、任意 canonical overflow、非所属 class 的 header/
  //   object/payload、TX-flush QPN、非 flush CQ secondary QPN、URC subtype=3，
  //   以及非 CQ/非 URC-abnormal subtype 1/2 携带 packet_opcode 均返回
  //   CODEC_ERROR；SRQ route 不依赖 srfq_en，explicit raw replay 已提前分流。
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

    // packet_opcode 是 CQ 或 QP URC-abnormal subtype 1/2 的写权；event.c
    // 的无条件 FIELD_GET 不允许其他 class/subselector 在 canonical image
    // 中借用该坐标，调用方提供的非零值必须拒绝而不是静默清除。
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

    // event.c 的无条件 FIELD_GET 只是 raw 观测权。canonical 新建事件
    // 必须按 class 宣告 header 字段，不得用物理坐标共享替代写权。
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

  // 功能：在 rdma_hw_aeqe_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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

  // 功能：decode_fields 将两个 AEQE qword 解码为 detached raw
  //   observation，保留全部 typed overlay 与原始 qword，但不伪造经过
  //   manager 认证的 primary target。
  // 输入/输出及副作用：b 为只读 qword builder，model 为输出；
  //   成功时新建 rdma_hw_aeqe_model，写入 typed/raw 快照并保持
  //   target_h=null、profile_*_valid=0，不取得 image 或 route 所有权。
  // 失败/边界：b 为空、字段读取失败或 qword 数不是 2 时返回错误且 model
  //   保持 null；raw QP_ST 的完整 0..7 均保留，QP/SRQ/CQ/EQ/diagnostic
  //   均必须由上层 resolver 后续安装 target authority。
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

// 功能：encode_sqe 将语义 post-send 请求复制为独立的 SQE hardware model，选择
//   RC、UD 或 URC 专用 codec，并生成驱动可消费的 64B WQE 字节镜像。
// 输入/输出及副作用：request 为只读请求快照，image 为输出数组；函数复制句柄、
//   transport extension、SGE 和原子字段，不取得 QP、AV、SGB 或 DMA 资源所有权。
// 失败/边界：请求校验、对象分配、transport/extension 选择、SGE clone 或 codec
//   encode 任一失败都返回明确 status 并保持 image 为空；不能把未知 transport、
//   null SGE 或 success+null image 继续交给队列写入路径。
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

  // 原子操作的本地地址、lkey 和 compare/swap 值属于请求快照的一部分，
  // facade 必须完整复制，不能依赖 hardware model 的默认零值。
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
  // request facade 与三个 transport writer 共享 hardware model 的 canonical
  // derivation；必须在 payload/SGE snapshot 完整后发布 wire-facing 字段。
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

// 功能：rdma_register_queue_codecs 把 XTR v1 的 SQE、RQE、CQE、CEQE 和 AEQE
//       codec 按稳定的对象类型、opcode 和 variant 键注册到 profile registry。
// 输入/输出及副作用：registry（输入）；函数逐项更新 registry，复用局部键
//       k，并返回最后一项注册的 rdma_status；不取得 codec 或 registry 的所有权。
// 失败/边界：registry 为空时立即返回 INVALID_ARGUMENT；任一 register_codec
//       失败都会原样返回，后续键不再注册，已完成的前序注册保持可见。
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
