// 目录：硬件编解码层 codec/rdma/rdma_queue_codecs.sv。
// 职责：实现 rdma_hw_queue_codecs 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_codecs.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// XTR v1 fixed-size queue data entry codecs.  Queue fields are authored in
// logical qwords and serialized big-endian by rdma_hw_qword_builder.

// 功能：在 rdma_hw_queue_codecs 中，rdma_hw_queue_projected_handle 构造或投影带完整 kind、Function UID、object ID 和 generation 的资源句柄。
// 输入/输出及副作用：name（输入）、kind（输入）、id（输入）、generation（输入）；rdma_hw_queue_projected_handle 读取 name、kind、id、generation 并使用字段 h、h.kind、h.object_id、h.generation；函数返回 rdma_handle，不取得调用方资源所有权。
// 失败/边界：rdma_hw_queue_projected_handle 的结果直接由 return h 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
function automatic rdma_handle rdma_hw_queue_projected_handle(
    string name, rdma_resource_kind_e kind, int unsigned id,
    int unsigned generation = 1);
  rdma_handle h;
  h = rdma_handle::type_id::create(name);
  h.kind = kind; h.object_id = id; h.generation = generation;
  return h;
endfunction

class rdma_queue_codec;
  // 功能：encode_sqe 将语义发送请求投影为 XTR v1 64B SQE 镜像，统一选择 RC/UD/URC codec。
  // 输入/输出及副作用：request 为只读请求，image 为输出镜像；函数仅复制请求快照，不取得 QP、AV 或 DMA 所有权。
  // 失败/边界：空请求、请求校验失败、未知 transport、authority 不完整或 codec 拒绝 payload 时返回对应 status，image 保持为空。
  extern static function rdma_status encode_sqe(input rdma_post_send_req request,
                                          output byte unsigned image[]);
  // 功能：按 CQE layout 编码公共字段，生成零填充的大端字节镜像。
  // 输入输出及副作用：fields/layout 为输入，image 为输出；成功时 image 长度等于 layout.bytes。
  // 失败边界：layout 无效、header 未按 16B 对齐或输出空间不足时返回 CODEC_ERROR 且 image 为空。
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
  // 输入输出及副作用：image/layout 为输入，fields 为输出；不修改输入数组。
  // 失败边界：镜像长度、header 对齐或保留字节不满足 profile 时返回 CODEC_ERROR。
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
  bit [20:0] qpn; bit [2:0] icos; bit [7:0] qp_sn; bit [3:0] dst_port;
  bit [14:0] index; bit wrap; bit sign_en; bit se; bit [1:0] fence; bit [1:0] ce;
  bit valid; bit [7:0] signature; bit [7:0] sge_num; bit [3:0] hw_opcode;
  bit [31:0] rkey; rdma_iova_t remote_va;
  rdma_sq_payload_mode_e payload_mode;
  longint unsigned total_payload_len;
  byte unsigned inline_bytes[];
  rdma_iova_t sgb_iova;
  bit [31:0] invalidate_key;
  bit [23:0] destination_qpn;
  bit [31:0] qkey;
  bit [31:0] mr_handle_id;
  bit [31:0] mw_handle_id;
  rdma_iova_t atomic_local_iova;
  bit [31:0] atomic_local_lkey;
  longint unsigned atomic_value;
  longint unsigned atomic_compare;

  // 功能：构造 rdma_hw_sqe_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：remote_va='0；sgb_iova='0；atomic_local_iova='0；payload_mode=RDMA_SQ_PAYLOAD_NONE；total_payload_len=0；inline_bytes=new[0]；invalidate_key=0；atomic_local_lkey=0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_sqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_sqe_model");
    super.new(name);
    remote_va='0; sgb_iova='0; atomic_local_iova='0;
    payload_mode = RDMA_SQ_PAYLOAD_NONE;
    total_payload_len = 0; inline_bytes = new[0];
    invalidate_key = 0; atomic_local_lkey = 0;
    destination_qpn = 0; qkey = 0; mr_handle_id = 0; mw_handle_id = 0;
    atomic_value = 0; atomic_compare = 0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_sqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（xtr SQE copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_sqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr SQE copy mismatch");
    qpn=x.qpn; icos=x.icos; qp_sn=x.qp_sn; dst_port=x.dst_port; index=x.index; wrap=x.wrap; sign_en=x.sign_en; se=x.se; fence=x.fence; ce=x.ce; valid=x.valid; signature=x.signature; sge_num=x.sge_num; hw_opcode=x.hw_opcode; rkey=x.rkey; remote_va=x.remote_va;
    payload_mode=x.payload_mode; total_payload_len=x.total_payload_len;
    inline_bytes=x.inline_bytes; sgb_iova=x.sgb_iova;
    invalidate_key=x.invalidate_key; atomic_local_iova=x.atomic_local_iova;
    destination_qpn=x.destination_qpn; qkey=x.qkey;
    mr_handle_id=x.mr_handle_id; mw_handle_id=x.mw_handle_id;
    atomic_local_lkey=x.atomic_local_lkey; atomic_value=x.atomic_value;
    atomic_compare=x.atomic_compare;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“SQE requires QP handle”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、qp_h、qp_h.kind、qpn、icos、index、transport_ext、payload_mode 并使用字段 rdma_status、qp_h、qp_h.kind、qpn、icos、index、transport_ext、payload_mode；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SQE requires QP handle”“SQE field width overflow”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (qp_h==null || qp_h.kind!=RDMA_RESOURCE_QP) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE requires QP handle");
    if (qpn > 21'h7ffff || icos > 3'd7 || index > 15'h7fff) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE field width overflow");
    if (transport_ext!=null && transport_ext.transport_kind()!=transport) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE transport extension mismatch");
    if (payload_mode > RDMA_SQ_PAYLOAD_ATOMIC_FIXED) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE payload mode is invalid");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe(); return $sformatf("XTR_SQE(qpn=%0d opcode=%0d index=%0d)",qpn,hw_opcode,index); endfunction
endclass

class rdma_hw_rqe_model extends rdma_rqe_model;
  `uvm_object_utils(rdma_hw_rqe_model)
  bit [23:0] qpn; bit [7:0] qp_sn; bit [3:0] hw_opcode; bit [14:0] index; bit wrap; bit valid;
  bit [31:0] payload_len; bit [7:0] signature; bit [7:0] sge_num;

  // 功能：构造 rdma_hw_rqe_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_rqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_rqe_model"); super.new(name); endfunction

  // 功能：将 rhs 中 rdma_hw_rqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（xtr RQE copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_rqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr RQE copy mismatch");
    qpn=x.qpn; qp_sn=x.qp_sn; hw_opcode=x.hw_opcode; index=x.index; wrap=x.wrap; valid=x.valid; payload_len=x.payload_len; signature=x.signature; sge_num=x.sge_num;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“RQE requires QP or SRQ handle”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、target_h、target_h.kind、index 并使用字段 rdma_status、target_h、target_h.kind、index；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“RQE requires QP or SRQ handle”“RQE index exceeds width”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (target_h==null || !(target_h.kind inside {RDMA_RESOURCE_QP,RDMA_RESOURCE_SRQ})) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"RQE requires QP or SRQ handle");
    if (index > 15'h7fff) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"RQE index exceeds width");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe(); return $sformatf("XTR_RQE(qpn=%0d opcode=%0d index=%0d)",qpn,hw_opcode,index); endfunction
endclass

class rdma_hw_cqe_model extends rdma_cqe_model;
  `uvm_object_utils(rdma_hw_cqe_model)
  bit [17:0] qpn; bit [14:0] wqe_index; bit wqe_wrap; bit rq_cqe; bit polarity;
  bit [7:0] packet_opcode; bit [7:0] ecode; bit [31:0] payload_len; bit [31:0] immediate_data; bit [7:0] signature;

  // 功能：构造 rdma_hw_cqe_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_cqe_model"); super.new(name); endfunction

  // 功能：将 rhs 中 rdma_hw_cqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（xtr CQE copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr CQE copy mismatch");
    qpn=x.qpn; wqe_index=x.wqe_index; wqe_wrap=x.wqe_wrap; rq_cqe=x.rq_cqe; polarity=x.polarity; packet_opcode=x.packet_opcode; ecode=x.ecode; payload_len=x.payload_len; immediate_data=x.immediate_data; signature=x.signature;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CQE requires QP handle”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、qp_h、qp_h.kind 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQE requires QP handle”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (qp_h==null || qp_h.kind!=RDMA_RESOURCE_QP) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"CQE requires QP handle");
    if (status==null) status=rdma_status::type_id::create("cqe_status");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe(); return $sformatf("XTR_CQE(qpn=%0d index=%0d ecode=0x%02x)",qpn,wqe_index,ecode); endfunction
endclass

class rdma_hw_ceqe_model extends rdma_ceqe_model;
  `uvm_object_utils(rdma_hw_ceqe_model)
  bit [20:0] qpn; bit [20:0] cqn; bit [7:0] ecode; bit [7:0] packet_opcode; bit [15:0] cq_pi; bit cq_pi_wrap; bit valid;

  // 功能：构造 rdma_hw_ceqe_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_ceqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_ceqe_model"); super.new(name); endfunction

  // 功能：将 rhs 中 rdma_hw_ceqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（xtr CEQE copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_ceqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr CEQE copy mismatch");
    qpn=x.qpn; cqn=x.cqn; ecode=x.ecode; packet_opcode=x.packet_opcode; cq_pi=x.cq_pi; cq_pi_wrap=x.cq_pi_wrap; valid=x.valid;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CEQE requires CQ handle”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 只读取 cq_h 及其 kind，返回状态且
  //   不修改 cq_h/cqn；global handle incarnation 与 Function-local cqn 的关联由
  //   queue-data attachment authority 校验，codec 不跨命名空间猜测 identity。
  // 失败/边界：cq_h 为空或不是 CQ 时返回 INVALID_ARGUMENT；cqn 的字段宽度由
  //   packed 类型/codec 保证，unknown local CQN 必须由拥有 topology 的调用方拒绝。
  virtual function rdma_status validate();
    if (cq_h==null || cq_h.kind!=RDMA_RESOURCE_CQ) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"CEQE requires CQ handle");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe(); return $sformatf("XTR_CEQE(qpn=%0d cqn=%0d)",qpn,cqn); endfunction
endclass

class rdma_hw_aeqe_model extends rdma_aeqe_model;
  `uvm_object_utils(rdma_hw_aeqe_model)
  bit [17:0] qpn; bit [2:0] qp_state; bit [7:0] ecode; bit [7:0] packet_opcode; bit [22:0] wqe_index; bit wqe_wrap; bit valid;

  // 功能：构造 rdma_hw_aeqe_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_aeqe_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_aeqe_model"); super.new(name); endfunction

  // 功能：将 rhs 中 rdma_hw_aeqe_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（xtr AEQE copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_aeqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr AEQE copy mismatch");
    qpn=x.qpn; qp_state=x.qp_state; ecode=x.ecode; packet_opcode=x.packet_opcode; wqe_index=x.wqe_index; wqe_wrap=x.wqe_wrap; valid=x.valid;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“AEQE target handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“AEQE target handle is null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate(); if (target_h==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"AEQE target handle is null"); return rdma_status::success(); endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe(); return $sformatf("XTR_AEQE(qpn=%0d ecode=0x%02x)",qpn,ecode); endfunction
endclass

virtual class rdma_hw_queue_codec_base extends rdma_codec_base;

  // 功能：构造 rdma_hw_queue_codec_base，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_queue_codec_base 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_queue_codec_base"); super.new(name); endfunction
  // 功能：在 rdma_hw_aeqe_model 中，image_kind_expected 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：无显式参数；image_kind_expected 返回 AEQE model 固定的镜像类型，不读取可变对象字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：image_kind_expected 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected pure virtual function rdma_image_kind_e image_kind_expected();
  // 功能：在 rdma_hw_aeqe_model 中，image_bytes 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：无显式参数；image_bytes 返回 AEQE codec 固定的镜像字节数，不读取可变对象字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：image_bytes 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected pure virtual function int unsigned image_bytes();
  // 功能：在 rdma_hw_queue_codec_base 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected pure virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b);
  // 功能：在 rdma_hw_queue_codec_base 中，decode_fields 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected pure virtual function rdma_status decode_fields(rdma_hw_qword_builder b, output rdma_hw_model model);
  // 功能：check_reserved 校验 b 与当前对象状态的一致性，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：b（输入）；check_reserved 读取 b 中的 qword，并检查保留位是否为零；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：check_reserved 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected pure virtual function rdma_status check_reserved(rdma_hw_qword_builder b);
  // 功能：在 rdma_hw_aeqe_model 中，err 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：m（输入）；err 将 m 封装为 RDMA_SC_CODEC_ERROR，不更新 builder 或外部资源；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：err 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status err(string m); return rdma_status::make(RDMA_SC_CODEC_ERROR,m); endfunction
  // 功能：model_handle_generation 按函数体读取当前字段并生成 int unsigned 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：model（输入）；model_handle_generation 读取 model 并使用字段 generation、rq.target_h、cq.qp_h、aq.target_h、rq、cq、aq；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  protected function int unsigned model_handle_generation(rdma_hw_model model);
    rdma_hw_sqe_model sq; rdma_hw_rqe_model rq; rdma_hw_cqe_model cq;
    rdma_hw_ceqe_model eq; rdma_hw_aeqe_model aq;
    if ($cast(sq, model) && sq.qp_h != null) return sq.qp_h.generation;
    if ($cast(rq, model) && rq.target_h != null) return rq.target_h.generation;
    if ($cast(cq, model) && cq.qp_h != null) return cq.qp_h.generation;
    if ($cast(eq, model) && eq.cq_h != null) return eq.cq_h.generation;
    if ($cast(aq, model) && aq.target_h != null) return aq.target_h.generation;
    return 0;
  endfunction

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理“queue model is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 rdma_status、s.message、image、image.function_generation、image.length、p；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_model(rdma_hw_model model); if (model==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue model is null"); if (model_handle_generation(model)==0) return rdma_status::make(RDMA_SC_STALE_GENERATION,"queue model handle generation is stale"); return rdma_status::success(); endfunction

  // 功能：validate_image 校验 image 与当前对象状态的一致性，并显式处理“queue image is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image（输入）；validate_image 读取 image 并使用字段 p、b、s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_hw_qword_builder b; byte unsigned p[]; rdma_status s;
    if (image==null) return err("queue image is null");
    if (image.function_generation==0) return rdma_status::make(RDMA_SC_STALE_GENERATION,"queue image generation is stale");
    if (image.length!=image_bytes() || image.bytes.size()!=image_bytes() || image.alignment!=image_bytes() || image.endian!=RDMA_ENDIAN_BIG || image.image_kind!=image_kind_expected() || image.hardware_version!=RDMA_HW_VERSION || image.write_target_kind!=RDMA_HW_TARGET_NONE || image.backing_target.value!=0 || image.hmc_target.value!=0 || image.bar_target.value!=0) return err("queue image metadata is invalid");
    p=new[image_bytes()]; foreach (p[i]) p[i]=image.bytes[i]; b=new("queue_validate"); s=b.deserialize(p); if (!s.ok()) return err(s.message); return check_reserved(b);
  endfunction

  // 功能：hardware_endian 使用 当前对象字段 计算并返回 rdma_byte_endian_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；hardware_endian 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_byte_endian_e，不取得调用方资源所有权。
  // 失败/边界：hardware_endian 是只读访问器，返回 RDMA_ENDIAN_BIG；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_byte_endian_e hardware_endian(); return RDMA_ENDIAN_BIG; endfunction

  // 功能：describe_fields 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；describe_fields 读取 image_bytes() 返回的固定长度并生成 queue image 描述文本；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe_fields(); return $sformatf("rdma %0d-byte queue image",image_bytes()); endfunction

  // 功能：在 rdma_hw_queue_codec_base 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status encode(rdma_hw_model model, output rdma_hw_image image);
    rdma_hw_qword_builder b; byte unsigned p[]; rdma_hw_image c; rdma_status s; image=null;
    s=validate_model(model); if (!s.ok()) return s; b=new("queue_encode"); s=b.reset(image_bytes()); if (!s.ok()) return err(s.message); s=encode_fields(model,b); if (!s.ok()) return s; s=check_reserved(b); if (!s.ok()) return s; p=new[0]; s=b.serialize(p); if (!s.ok()) return err(s.message); c=rdma_hw_image::type_id::create("queue_image"); foreach(p[i]) c.bytes.push_back(p[i]); c.length=image_bytes(); c.alignment=image_bytes(); c.endian=RDMA_ENDIAN_BIG; c.image_kind=image_kind_expected(); c.hardware_version=RDMA_HW_VERSION; c.function_generation=model_handle_generation(model); c.write_target_kind=RDMA_HW_TARGET_NONE; image=c; return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_queue_codec_base 中，decode 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：image（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status decode(rdma_hw_image image, output rdma_hw_model model);
    rdma_hw_qword_builder b; byte unsigned p[]; rdma_status s; rdma_hw_model candidate; model=null;
    s=validate_image(image); if (!s.ok()) return s; p=new[image_bytes()]; foreach(p[i]) p[i]=image.bytes[i]; b=new("queue_decode"); s=b.deserialize(p); if (!s.ok()) return err(s.message); s=decode_fields(b,candidate); if (!s.ok()) return s; model=candidate; return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_queue_codecs 中由 serialized_equal 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）、equal（输出）、mismatch（输出）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：serialized_equal 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function rdma_status serialized_equal(rdma_hw_model lhs, rdma_hw_model rhs, output bit equal, output string mismatch);
    rdma_hw_image a,b; rdma_status s; equal=0; mismatch=""; s=encode(lhs,a); if(!s.ok()) return s; s=encode(rhs,b); if(!s.ok()) return s; if(a.image_kind!=b.image_kind || a.length!=b.length) begin mismatch="queue metadata differs"; return rdma_status::success(); end foreach(a.bytes[i]) if(a.bytes[i]!==b.bytes[i]) begin mismatch=$sformatf("queue byte %0d differs",i); return rdma_status::success(); end equal=1; return rdma_status::success();
  endfunction
endclass

class rdma_hw_sqe_codec_base extends rdma_hw_queue_codec_base;

  // 功能：构造 rdma_hw_sqe_codec_base，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_sqe_codec_base 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_sqe_codec_base"); super.new(name); endfunction
  // 功能：在 rdma_hw_sqe_codec_base 中，image_kind_expected 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：无显式参数；image_kind_expected 返回 SQE codec 固定的 RDMA_IMAGE_SQE 类型，不读取可变对象字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：image_kind_expected 是只读访问器，返回 RDMA_IMAGE_SQE；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_SQE; endfunction
  // 功能：在 rdma_hw_sqe_codec_base 中，image_bytes 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：无显式参数；image_bytes 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：image_bytes 的结果直接由 return RDMA_WQE_BYTES 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected virtual function int unsigned image_bytes(); return RDMA_WQE_BYTES; endfunction
  // 功能：在 rdma_hw_sqe_codec_base 中，put 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：b（输入）、o（输入）、l（输入）、w（输入）、v（输入）；put 读取 b、o、l、w、v 并使用字段 s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：put 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  protected function rdma_status put(rdma_hw_qword_builder b,int unsigned o,int unsigned l,int unsigned w,bit [63:0] v); rdma_status s=b.put_field(o,l,w,v); return s.ok()?s:rdma_status::make(RDMA_SC_CODEC_ERROR,s.message); endfunction
  // 功能：在 rdma_hw_sqe_codec_base 中，get 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：b（输入）、o（输入）、l（输入）、w（输入）、v（输入输出）；get 读取 b、o、l、w、v 并使用字段 s，并写入 v；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：get 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status get(rdma_hw_qword_builder b,int unsigned o,int unsigned l,int unsigned w,inout bit [63:0] v); rdma_status s=b.get_field(o,l,w,v); return s.ok()?s:rdma_status::make(RDMA_SC_CODEC_ERROR,s.message); endfunction
  // 功能：check_reserved 校验 b 与当前对象状态的一致性，并显式处理“SQE header reserved bits are nonzero”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：b（输入）；check_reserved 读取 b 的 qword[0]，拒绝 SQE header 保留位非零的镜像；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：check_reserved 是只读访问器，返回 err("SQE header reserved bits are nonzero")；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b);
    bit [63:0] w[];
    b.get_words(w);
    if ((w[0] & ~64'hefff_ffff_ffff_ffff) != 0)
      return err("SQE header reserved bits are nonzero");
    return rdma_status::success();
  endfunction
  // 功能：在 rdma_hw_sqe_codec_base 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b); rdma_hw_sqe_model x; rdma_status s; if(!$cast(x,model)) return err("SQE model type mismatch"); s=x.validate(); if(!s.ok()) return s;
    `define SQPUT(S,V) s=put(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return s;
    `SQPUT(RDMA_SQ_WQE_QPN,x.qpn) `SQPUT(RDMA_SQ_WQE_ICOS,x.icos) `SQPUT(RDMA_SQ_WQE_QP_SN,x.qp_sn) `SQPUT(RDMA_SQ_WQE_OPCODE,x.hw_opcode) `SQPUT(RDMA_SQ_WQE_DST_PORT,x.dst_port) `SQPUT(RDMA_SQ_WQE_INDEX,x.index) `SQPUT(RDMA_SQ_WQE_WRAP,x.wrap) `SQPUT(RDMA_SQ_WQE_SIGN_EN,x.sign_en) `SQPUT(RDMA_SQ_WQE_SE,x.se) `SQPUT(RDMA_SQ_WQE_FENCE,x.fence) `SQPUT(RDMA_SQ_WQE_CE,x.ce) `SQPUT(RDMA_SQ_WQE_VALID,x.valid) `SQPUT(RDMA_SQ_WQE_SIGNATURE,x.signature) `SQPUT(RDMA_SQ_WQE_RC_SGE_NUM,x.sge_num)
    if (x.transport!=RDMA_TRANSPORT_RC) return rdma_status::success();
    `SQPUT(RDMA_SQ_WQE_RC_REMOTE_KEY,x.rkey) `SQPUT(RDMA_SQ_WQE_RC_REMOTE_VA,x.remote_va.value) `undef SQPUT return rdma_status::success();
  endfunction
  // 功能：在 rdma_hw_sqe_codec_base 中，decode_fields 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_fields(rdma_hw_qword_builder b, output rdma_hw_model model); rdma_hw_sqe_model x; rdma_sqe_rc_ext ext; bit [63:0] v; rdma_status s; x=rdma_hw_sqe_model::type_id::create("decoded_sqe"); x.transport=RDMA_TRANSPORT_RC; x.opcode=RDMA_WR_SEND; x.inline_data=1; x.payload.push_back(0); x.qp_h=rdma_hw_queue_projected_handle("decoded_qp",RDMA_RESOURCE_QP,0); ext=rdma_sqe_rc_ext::type_id::create("decoded_rc_ext"); x.transport_ext=ext; `define SQGET(S,T) v='0; s=get(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return s; T=v;
    `SQGET(RDMA_SQ_WQE_QPN,x.qpn) `SQGET(RDMA_SQ_WQE_ICOS,x.icos) `SQGET(RDMA_SQ_WQE_QP_SN,x.qp_sn) `SQGET(RDMA_SQ_WQE_OPCODE,x.hw_opcode) `SQGET(RDMA_SQ_WQE_DST_PORT,x.dst_port) `SQGET(RDMA_SQ_WQE_INDEX,x.index) `SQGET(RDMA_SQ_WQE_WRAP,x.wrap) `SQGET(RDMA_SQ_WQE_SIGN_EN,x.sign_en) `SQGET(RDMA_SQ_WQE_SE,x.se) `SQGET(RDMA_SQ_WQE_FENCE,x.fence) `SQGET(RDMA_SQ_WQE_CE,x.ce) `SQGET(RDMA_SQ_WQE_VALID,x.valid) `SQGET(RDMA_SQ_WQE_SIGNATURE,x.signature) `SQGET(RDMA_SQ_WQE_RC_SGE_NUM,x.sge_num) `SQGET(RDMA_SQ_WQE_RC_REMOTE_KEY,x.rkey) `SQGET(RDMA_SQ_WQE_RC_REMOTE_VA,x.remote_va.value) `undef SQGET model=x; return rdma_status::success(); endfunction
endclass

// 功能：在 rdma_hw_sqe_codec_base 中，rdma_hw_sq_signature_xor 对除 signature byte 外的 SQE 和 SGB 字节执行 XOR，生成 XTR v1 校验签名。
// 输入/输出及副作用：image（输入）、sgb（输入）；rdma_hw_sq_signature_xor 读取 image、sgb 并使用字段 value；函数返回 bit [7:0]，不取得调用方资源所有权。
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

  // 功能：mode_of 按函数体读取当前字段并生成 rdma_sq_payload_mode_e 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：x（输入）；mode_of 读取 x 并使用输入参数和固定枚举/常量；函数返回 rdma_sq_payload_mode_e，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  protected function rdma_sq_payload_mode_e mode_of(rdma_hw_sqe_model x);
    if (x.payload_mode != RDMA_SQ_PAYLOAD_NONE)
      return x.payload_mode;
    if (x.inline_data || x.inline_bytes.size() != 0 || x.payload.size() != 0)
      return (x.inline_bytes.size() > 32 || x.payload.size() > 32) ?
             RDMA_SQ_PAYLOAD_INLINE_SGB : RDMA_SQ_PAYLOAD_INLINE_WQE;
    if (x.opcode inside {RDMA_WR_ATOMIC_CMP_SWAP, RDMA_WR_ATOMIC_FETCH_ADD})
      return RDMA_SQ_PAYLOAD_ATOMIC_FIXED;
    if (x.sges.size() > 2)
      return RDMA_SQ_PAYLOAD_SGE_SGB;
    if (x.sges.size() != 0)
      return RDMA_SQ_PAYLOAD_SGE_WQE;
    return RDMA_SQ_PAYLOAD_NONE;
  endfunction

  // 功能：payload_length 根据 x.total_payload_len、inline_bytes、payload 和 mode 计算实际 payload 字节数，供 SQE 编码检查使用。
  // 输入/输出及副作用：x（输入）、mode（输入）；payload_length 读取 x、mode 并使用字段 value；函数返回 longint unsigned，不取得调用方资源所有权。
  // 失败/边界：payload_length 先检查 value != 0；x.inline_bytes.size(；mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED，再返回 value；x.inline_bytes.size()；x.payload.size()；拒绝分支不提交部分状态，也不隐式重试。
  protected function automatic longint unsigned payload_length(
      rdma_hw_sqe_model x,
      rdma_sq_payload_mode_e mode);
    longint unsigned value;
    value = x.total_payload_len;
    if (value != 0)
      return value;
    if (mode inside {RDMA_SQ_PAYLOAD_INLINE_WQE,
                     RDMA_SQ_PAYLOAD_INLINE_SGB}) begin
      if (x.inline_bytes.size() != 0) return x.inline_bytes.size();
      return x.payload.size();
    end
    if (mode inside {RDMA_SQ_PAYLOAD_SGE_WQE,
                     RDMA_SQ_PAYLOAD_SGE_SGB}) begin
      value = 0;
      foreach (x.sges[i]) value += x.sges[i].length;
    end
    if (mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED)
      value = 8;
    return value;
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

  // 功能：在 rdma_hw_sqe_rc_codec 中，body_and_header 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：x（输入）、b（输入）、mode（输出）、signature_sgb（输出）；body_and_header 读取 x、b、mode、signature_sgb 并使用字段 s、mode、length、sge_length、encoded_length、raw、descriptor_length、descriptor_lkey，并写入 mode、signature_sgb；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：body_and_header 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “local invalidate uses a payload mode”；“atomic opcode uses a non-atomic payload mode”；“non-atomic opcode uses atomic payload mode”；“ordinary RC SQE has no payload shape”；“RDMA read requires an SGE payload mode”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
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
    s = rdma_status::success();
    mode = mode_of(x);
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
        x.opcode != RDMA_WR_LOCAL_INVALIDATE)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ordinary RC SQE has no payload shape");
    if (x.opcode == RDMA_WR_RDMA_READ &&
        !(mode inside {RDMA_SQ_PAYLOAD_SGE_WQE,
                       RDMA_SQ_PAYLOAD_SGE_SGB}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RDMA read requires an SGE payload mode");

    length = payload_length(x, mode);
    if (mode inside {RDMA_SQ_PAYLOAD_SGE_WQE,
                     RDMA_SQ_PAYLOAD_SGE_SGB}) begin
      sge_length = 0;
      foreach (x.sges[i]) begin
        if (x.sges[i] == null || x.sges[i].length == 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "RC SQE contains an empty SGE");
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
      if (x.inline_bytes.size() != 0) begin
        raw = new[x.inline_bytes.size()]; foreach (raw[i]) raw[i]=x.inline_bytes[i];
      end else begin
        raw = new[x.payload.size()]; foreach (raw[i]) raw[i]=x.payload[i];
      end
      if (raw.size() != length || raw.size() == 0)
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
        s = b.put_memcpy(32, raw); if (!s.ok()) return err(s.message);
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
      if (x.sges.size() == 0 || x.sges.size() > 32)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RC SGE count is outside 1..32");
      if (mode == RDMA_SQ_PAYLOAD_SGE_WQE && x.sges.size() > 2)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "direct RC SGE count exceeds two");
      if (mode == RDMA_SQ_PAYLOAD_SGE_SGB && x.sges.size() < 3)
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
        foreach (x.sges[i]) begin
          s = put_sge(b, i, x.sges[i]); if (!s.ok()) return s;
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
            mode inside {RDMA_SQ_PAYLOAD_INLINE_WQE,
                         RDMA_SQ_PAYLOAD_INLINE_SGB} ?
            ((length + 15) / 16) :
            (mode inside {RDMA_SQ_PAYLOAD_SGE_WQE,
                          RDMA_SQ_PAYLOAD_SGE_SGB,
                          RDMA_SQ_PAYLOAD_ATOMIC_FIXED} ?
             (mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED ? 1 : x.sges.size()) : 0));
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

  // 功能：check_reserved 校验 b 与当前对象状态的一致性，并显式处理“RC SQE does not contain eight qwords”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：b（输入）；check_reserved 读取 b 并使用字段 allowed、count、length、s、q；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：check_reserved 是只读访问器，返回 err("RC SQE does not contain eight qwords")；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_status check_reserved(
      rdma_hw_qword_builder b);
    bit [63:0] w[];
    bit [63:0] allowed;
    byte unsigned raw[];
    rdma_status s;
    int unsigned count;
    int unsigned length;
    b.get_words(w);
    if (w.size() != 8)
      return err("RC SQE does not contain eight qwords");
    allowed = last_mode inside {RDMA_SQ_PAYLOAD_INLINE_WQE,
                                RDMA_SQ_PAYLOAD_INLINE_SGB} ?
              64'hffff_ffff_ffff_ffff : 64'hefff_ffff_ffff_ffff;
    if ((w[0] & ~allowed) != 0)
      return err("RC SQE header reserved bits are nonzero");
    foreach (w[q]) begin
      if (q == 0)
        continue;
      allowed = 0;
      case (last_mode)
        RDMA_SQ_PAYLOAD_INLINE_WQE,
        RDMA_SQ_PAYLOAD_SGE_WQE: begin
          case (q)
            1, 3, 4, 5, 6, 7: allowed = 64'hffff_ffff_ffff_ffff;
            2: allowed = 64'hffff_0000_ffff_ffff;
            default: allowed = 0;
          endcase
        end
        RDMA_SQ_PAYLOAD_INLINE_SGB,
        RDMA_SQ_PAYLOAD_SGE_SGB: begin
          case (q)
            1, 3: allowed = 64'hffff_ffff_ffff_ffff;
            2: allowed = 64'hffff_0000_ffff_ffff;
            4: allowed = 64'hffff_ffff_ffff_fe00;
            default: allowed = 0;
          endcase
        end
        RDMA_SQ_PAYLOAD_ATOMIC_FIXED: begin
          case (q)
            1: allowed = 64'h0000_0000_ffff_ffff;
            2: allowed = 64'hffff_0000_ffff_ffff;
            3, 4, 5, 6: allowed = 64'hffff_ffff_ffff_ffff;
            7: allowed = last_hw_opcode == RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP ?
                         64'hffff_ffff_ffff_ffff : 64'h0;
            default: allowed = 0;
          endcase
        end
        RDMA_SQ_PAYLOAD_NONE: begin
          case (q)
            1: allowed = 64'hffff_ffff_0000_0000;
            2: allowed = 64'hff00_0000_0000_0000;
            default: allowed = 0;
          endcase
        end
        default: return err("RC SQE payload mode is invalid");
      endcase
      if ((w[q] & ~allowed) != 0)
        return err($sformatf("RC SQE qword %0d reserved bits are nonzero", q));
    end

    count = w[2][55:48];
    if (last_mode == RDMA_SQ_PAYLOAD_INLINE_WQE) begin
      length = w[1][31:0];
      if (length == 0 || length > 32 || count != ((length + 15) / 16))
        return err("RC inline WQE length or chunk count is invalid");
      s = b.serialize(raw);
      if (!s.ok()) return err(s.message);
      for (int unsigned i = 32 + length; i < RDMA_WQE_BYTES; i++)
        if (raw[i] != 0)
          return err("RC inline WQE unused tail is nonzero");
    end else if (last_mode == RDMA_SQ_PAYLOAD_INLINE_SGB) begin
      length = w[1][31:0];
      if (length <= 32 || count != ((length + 15) / 16))
        return err("RC inline SGB length or chunk count is invalid");
    end else if (last_mode == RDMA_SQ_PAYLOAD_SGE_WQE) begin
      if (count == 0 || count > 2)
        return err("RC direct SGE count is invalid");
      for (int unsigned q = 4 + count * 2; q < 8; q++)
        if (w[q] != 0)
          return err("RC direct SGE unused tail is nonzero");
    end else if (last_mode == RDMA_SQ_PAYLOAD_SGE_SGB) begin
      if (count < 3 || count > 32)
        return err("RC SGB SGE count is invalid");
    end else if (last_mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED) begin
      if (count != 1 || w[1][31:0] != 8)
        return err("RC atomic length or SGE count is invalid");
    end else if (last_mode == RDMA_SQ_PAYLOAD_NONE) begin
      if (last_hw_opcode != RDMA_SQ_OPCODE_LOCAL_INV || count != 0 ||
          w[1][31:0] != 0)
        return err("RC empty body is not a local invalidate");
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

  // 功能：在 rdma_hw_sqe_rc_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(
      rdma_hw_model model,
      rdma_hw_qword_builder b);
    rdma_hw_sqe_model x;
    rdma_sqe_rc_ext ext;
    rdma_status s;
    rdma_sq_payload_mode_e mode;
    byte unsigned signature_sgb[$];
    byte unsigned serialized[];
    bit [7:0] signature;
    bit [3:0] hw_opcode;
    if (!$cast(x, model)) return err("RC SQE model type mismatch");
    s = x.validate(); if (!s.ok()) return s;
    if (x.transport != RDMA_TRANSPORT_RC)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RC codec received a non-RC SQE");
    s = map_opcode(x.opcode, hw_opcode); if (!s.ok()) return s;
    if (x.transport_ext != null) begin
      if (!$cast(ext, x.transport_ext)) return err("RC extension type mismatch");
      s = ext.validate(x.opcode); if (!s.ok()) return s;
      if (ext.rkey_valid) x.rkey = ext.rkey;
      if (ext.remote_access_valid) x.remote_va = ext.remote_addr;
      if (x.opcode == RDMA_WR_LOCAL_INVALIDATE && ext.rkey_valid)
        x.invalidate_key = ext.rkey;
    end
    last_hw_opcode = hw_opcode;
    s = body_and_header(x, b, mode, signature_sgb); if (!s.ok()) return s;
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

  // 功能：在 rdma_hw_sqe_rc_codec 中，decode_fields 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
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
      x.payload_mode = words[0][60] ?
                        (x.total_payload_len <= 32 ?
                         RDMA_SQ_PAYLOAD_INLINE_WQE :
                         RDMA_SQ_PAYLOAD_INLINE_SGB) :
                        (count <= 2 ? RDMA_SQ_PAYLOAD_SGE_WQE :
                                      RDMA_SQ_PAYLOAD_SGE_SGB);
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
          s = get(b, 32+i*16, 32, 32, v); if(!s.ok()) return s;
          sg.length = v == 0 ? 32'h8000_0000 : v;
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
  function new(string name="rdma_hw_sqe_ud_codec"); super.new(name); endfunction
  // 功能：校验 UD SQE 的 header、AH 元数据和 64B 固定几何。
  // 输入/输出及副作用：b 为输入；仅读取 builder，不修改任何模型或 backing。
  // 失败/边界：qword 数量不是 8、header 保留位或未定义 body 位非零时拒绝。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b);
    bit [63:0] w[];
    bit [63:0] allowed_payload;
    b.get_words(w);
    // offset=8 的 qword 由 payload length、destination vport、FWD/LAG/
    // tunnel/IPv6/VLAN 和（按 opcode）立即数覆盖，bit25 是唯一 reserved。
    // offset=16 的 qword 则由 signature、SGE_NUM、DMAC 完整覆盖。
    allowed_payload = 64'h0000_0000_fdff_ffff;
    if (last_hw_opcode inside {RDMA_SQ_OPCODE_SEND_WITH_IMM,
                                RDMA_SQ_OPCODE_SEND_WITH_INV})
      allowed_payload |= 64'hffff_ffff_0000_0000;
    if (w.size() != 8 || (w[0] & ~64'hefff_ffff_ffff_ffff) != 0 ||
        (w[1] & ~allowed_payload) != 0)
      return err("UD SQE reserved bits are nonzero");
    return rdma_status::success();
  endfunction

  // 功能：把驱动 xtrdma_set_ud_wqe() 的 8..56 字节布局独立编码到 WQE。
  // 输入/输出及副作用：model 为输入、b 为输出；仅生成 detached image，SGB 内容由 queue-data
  // writer 另行写入，不在此函数取得 host-memory 所有权。
  // 失败/边界：非 UD 扩展、payload 超过 14-bit、非零 payload 缺失 512B 对齐 SGB IOVA、
  // SGE/inline 长度不一致或字段写入重叠时返回明确错误且不发布 image。
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b);
    rdma_hw_sqe_model x;
    rdma_sqe_ud_ext ext;
    rdma_address_vector av;
    rdma_status s;
    rdma_sq_payload_mode_e mode;
    byte unsigned sgb[$];
    byte unsigned raw[];
    byte unsigned payload_bytes[];
    bit [3:0] op;
    bit [7:0] sig;
    longint unsigned length;
    int unsigned sge_count;
    rdma_sq_payload_mode_e header_mode;
    if (!$cast(x, model)) return err("UD SQE model type mismatch");
    if (x.transport != RDMA_TRANSPORT_UD) return err("UD codec received non-UD SQE");
    if (!$cast(ext, x.transport_ext)) return err("UD extension type mismatch");
    s = ext.validate(x.opcode); if (!s.ok()) return s;
    s = map_opcode(x.opcode, op); if (!s.ok()) return s;
    last_hw_opcode = op;
    av = ext.address_vector;
    if (av == null) return err("UD SQE address vector is null");

    // 驱动会过滤零长 SGE，再按有效长度计算 payload 和 SGE_NUM。
    length = x.total_payload_len;
    if (length == 0 && x.inline_data) length = x.payload.size();
    if (!x.inline_data) begin
      length = 0;
      foreach (x.sges[i]) begin
        if (x.sges[i] == null || x.sges[i].length == 0)
          return err("UD SQE contains an empty SGE");
        length += x.sges[i].length;
      end
    end
    if (length > 14'h3fff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD payload length exceeds 14-bit field");
    if (length != 0 && (x.sgb_iova.value == 0 ||
                        (x.sgb_iova.value & 64'h1ff) != 0))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD nonzero payload requires aligned SGB IOVA");
    mode = length == 0 ? RDMA_SQ_PAYLOAD_NONE : RDMA_SQ_PAYLOAD_INLINE_SGB;
    if (!x.inline_data && length != 0) mode = RDMA_SQ_PAYLOAD_SGE_SGB;
    // UD driver 统一把非空 payload 放在外部 SQ-SGB；即使语义输入来自
    // inline_data，header 的 INLINE_LOCAL_QPC_RD 也必须保持 0（与 golden
    // UD SGB image 一致），而 SGE_NUM 仍按有效 payload 计算。
    header_mode = length == 0 ? RDMA_SQ_PAYLOAD_NONE :
                  RDMA_SQ_PAYLOAD_SGE_SGB;
    last_mode = mode;
    sge_count = x.inline_data ? ((length + 15) / 16) : x.sges.size();
    if (sge_count > 8'hff)
      return err("UD SGE count exceeds field width");
    if (x.inline_data) begin
      payload_bytes = new[x.payload.size()];
      foreach (payload_bytes[i]) payload_bytes[i] = x.payload[i];
      if (payload_bytes.size() != length)
        return err("UD inline payload length is inconsistent");
      foreach (payload_bytes[i]) sgb.push_back(payload_bytes[i]);
      while (sgb.size() < 512) sgb.push_back(0);
    end
    else if (length != 0) begin
      foreach (x.sges[i]) begin
        bit [31:0] enc_len;
        enc_len = x.sges[i].length == 32'h8000_0000 ? 0 : x.sges[i].length;
        for (int unsigned j = 0; j < 4; j++) sgb.push_back(enc_len[31-j*8 -: 8]);
        for (int unsigned j = 0; j < 4; j++) sgb.push_back(x.sges[i].lkey[31-j*8 -: 8]);
        for (int unsigned j = 0; j < 8; j++) sgb.push_back(x.sges[i].iova.value[63-j*8 -: 8]);
      end
      while (sgb.size() < 512) sgb.push_back(0);
    end

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
    s = put_header(x, header_mode, last_hw_opcode, b); if (!s.ok()) return s;
    s = b.serialize(raw); if (!s.ok()) return err(s.message);
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
  function new(string name="rdma_hw_sqe_urc_codec"); super.new(name); endfunction
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
    rdma_hw_sqe_model x; rdma_sqe_urc_ext ext; rdma_status s; rdma_sq_payload_mode_e mode; byte unsigned sgb[$]; bit [3:0] op;
    if (!$cast(x,model)) return err("URC SQE model type mismatch");
    if (x.transport != RDMA_TRANSPORT_URC) return err("URC codec received non-URC SQE");
    if (!$cast(ext,x.transport_ext)) return err("URC extension type mismatch");
    s=ext.validate(x.opcode); if(!s.ok()) return s; s=map_opcode(x.opcode,op); if(!s.ok()) return s;
    last_hw_opcode = op;
    s=body_and_header(x,b,mode,sgb); if(!s.ok()) return s;
    last_mode = mode;
    begin
      byte unsigned raw[]; bit [7:0] sig;
      s = b.serialize(raw); if (!s.ok()) return err(s.message);
      sig = ~8'h00; foreach (raw[i]) if (i != 16) sig ^= raw[i];
      foreach (sgb[i]) sig ^= sgb[i];
      s = put(b, RDMA_SQ_WQE_SIGNATURE_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_SIGNATURE_LSB, RDMA_SQ_WQE_SIGNATURE_WIDTH, sig);
      if (!s.ok()) return s;
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

  // 功能：构造 rdma_hw_rqe_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_rqe_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_rqe_codec"); super.new(name); endfunction
  // 功能：在 rdma_hw_rqe_codec 中，image_check 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：b（输入）；image_check 读取 b 的 8 个 qword，校验 RQE 保留位和未使用 qword；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：image_check 先检查 (w[0]&~64'h80ff_ff0f_ffff_ffff，再返回 err("RQE reserved bits are nonzero")；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status image_check(rdma_hw_qword_builder b); bit [63:0] w[]; b.get_words(w); if ((w[0]&~64'h80ff_ff0f_ffff_ffff)!=0 || w[1][63:32]!==0 || w[2]&~64'hff00_0000_0000_0000!==0 || w[3]!==0 || w[4]!==0 || w[5]!==0 || w[6]!==0 || w[7]!==0) return err("RQE reserved bits are nonzero"); return rdma_status::success(); endfunction
  // 功能：在 rdma_hw_rqe_codec 中，image_kind_expected 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：无显式参数；image_kind_expected 读取 对象字段：s、s.message、x、model 并使用字段 s、s.message、x、model；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：image_kind_expected 是只读访问器，返回 RDMA_IMAGE_RQE；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_RQE; endfunction protected virtual function int unsigned image_bytes(); return RDMA_RQE_BYTES; endfunction protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b); return image_check(b); endfunction
  // 功能：在 rdma_hw_rqe_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b); rdma_hw_rqe_model x; rdma_status s; if(!$cast(x,model)) return err("RQE model type mismatch"); s=x.validate(); if(!s.ok()) return s; `define RQPUT(S,V) s=b.put_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return err(s.message);
    `RQPUT(RDMA_RQE_QPN,x.qpn) `RQPUT(RDMA_RQE_QP_SN,x.qp_sn) `RQPUT(RDMA_RQE_OPCODE,x.hw_opcode) `RQPUT(RDMA_RQE_INDEX,x.index) `RQPUT(RDMA_RQE_WRAP,x.wrap) `RQPUT(RDMA_RQE_VALID,x.valid) `RQPUT(RDMA_RQE_PAYLOAD_LEN,x.payload_len) `RQPUT(RDMA_RQE_SIGNATURE,x.signature) `RQPUT(RDMA_RQE_SGE_NUM,x.sge_num) `undef RQPUT return rdma_status::success(); endfunction
  // 功能：在 rdma_hw_rqe_codec 中，decode_fields 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_fields(rdma_hw_qword_builder b, output rdma_hw_model model); rdma_hw_rqe_model x; bit [63:0] v; rdma_status s; x=rdma_hw_rqe_model::type_id::create("decoded_rqe"); x.target_h=rdma_hw_queue_projected_handle("decoded_qp",RDMA_RESOURCE_QP,0); `define RQGET(S,T) v='0; s=b.get_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return err(s.message); T=v;
    `RQGET(RDMA_RQE_QPN,x.qpn) `RQGET(RDMA_RQE_QP_SN,x.qp_sn) `RQGET(RDMA_RQE_OPCODE,x.hw_opcode) `RQGET(RDMA_RQE_INDEX,x.index) `RQGET(RDMA_RQE_WRAP,x.wrap) `RQGET(RDMA_RQE_VALID,x.valid) `RQGET(RDMA_RQE_PAYLOAD_LEN,x.payload_len) `RQGET(RDMA_RQE_SIGNATURE,x.signature) `RQGET(RDMA_RQE_SGE_NUM,x.sge_num) `undef RQGET model=x; return rdma_status::success(); endfunction
endclass

class rdma_hw_cqe_codec extends rdma_hw_queue_codec_base;
  `uvm_object_utils(rdma_hw_cqe_codec)
  protected int unsigned active_bytes;

  // 功能：构造 rdma_hw_cqe_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cqe_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  // 功能：构造 CQE codec 并默认保持历史 64B profile。
  // 输入输出及副作用：name 为输入；初始化本地 profile 状态，不拥有 ring 或 image。
  // 失败边界：profile 仅可由 set_entry_bytes 切换，构造不接管外部资源。
  function new(string name="rdma_hw_cqe_codec"); super.new(name); active_bytes=RDMA_CQE_BYTES; endfunction
  // 功能：选择本次编解码使用的 CQE profile 大小。
  // 输入输出及副作用：bytes 为输入；成功时更新 codec 本地 profile，返回状态。
  // 失败边界：32/64/128 以外的大小被拒绝且保留原 profile。
  function rdma_status set_entry_bytes(int unsigned bytes);
    if (!(bytes inside {32,64,128}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"CQE profile size is invalid");
    active_bytes=bytes; return rdma_status::success();
  endfunction

  // 功能：按调用方显式提供的 CQE entry profile 解码一份 image，构造独立的
  // qword builder 并返回 detached CQE model；该路径不读取或写入 active_bytes，
  // 因而可被共享 registry codec 并发/交错调用而不会串 profile。
  // 输入输出及副作用：image、entry_size 为输入，model 为输出；函数只读取 image
  // 字节和 metadata，成功时发布新建 model，不接管 image 或其 backing 所有权。
  // 失败边界：entry_size 不是 32/64/128、image metadata/代际不匹配、保留位非零、
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

    model = null;
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

    p = new[entry_size];
    foreach (p[i]) p[i] = image.bytes[i];
    b = new("cqe_decode_profile");
    status = b.deserialize(p);
    if (!status.ok())
      return err(status.message);
    status = check_reserved(b);
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
  // 失败边界：entry_size 不是 32/64/128、模型代际无效、builder 分配/复位、
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
    p = new[entry_size];
    foreach (p[i]) p[i] = image.bytes[i];
    b = new("cqe_validate_profile");
    status = b.deserialize(p);
    if (status == null || !status.ok())
      return err(status == null ? "CQE image deserialize returned null" :
                 status.message);
    return check_reserved(b);
  endfunction

  // 功能：依据 image 自带长度选择本次 CQE profile 并调用无状态解码入口。
  // 输入输出及副作用：image 为输入、model 为输出；不会改变 active_bytes 或 image，
  // 成功时发布 detached model。
  // 失败边界：image 为空或长度不是 32/64/128 时返回 CODEC_ERROR；下游 profile
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
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_CQE; endfunction
  protected virtual function int unsigned image_bytes(); return active_bytes; endfunction
  // 功能：check_reserved 校验 CQE 三个有效 qword 中的保留位，允许 qword0/1
  //       已定义字段和 qword2[63:56] signature，其余位必须为零。
  // 输入/输出及副作用：b 为输入；函数读取序列化 qword 并返回校验状态，不修改
  //       builder、active_bytes 或任何外部资源。
  // 失败/边界：builder 少于三个 qword、qword0/1 未定义位非零、qword2[55:0]
  //       非零或扩展 qword 非零时返回 CODEC_ERROR，调用方不得发布该 CQE。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b);
    bit [63:0] w[];
    b.get_words(w);
    if (w.size() < 3 || (w[0]&~64'h88ff_ffff_ff03_ffff)!=0 ||
        (w[2]&~64'hff00_0000_0000_0000)!=0)
      return err("CQE reserved bits are nonzero");
    foreach (w[i]) if (i >= 3 && w[i] !== 0)
      return err("CQE reserved words are nonzero");
    return rdma_status::success();
  endfunction
  // 功能：在 rdma_hw_cqe_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b); rdma_hw_cqe_model x; rdma_status s; if(!$cast(x,model)) return err("CQE model type mismatch"); s=x.validate(); if(!s.ok()) return s; `define CQPUT(S,V) s=b.put_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return err(s.message);
    `CQPUT(RDMA_CQE_POLARITY,x.polarity) `CQPUT(RDMA_CQE_RQ_CQE,x.rq_cqe) `CQPUT(RDMA_CQE_WQE_WRAP,x.wqe_wrap) `CQPUT(RDMA_CQE_WQE_INDEX,x.wqe_index) `CQPUT(RDMA_CQE_PKT_OPCODE,x.packet_opcode) `CQPUT(RDMA_CQE_ECODE,x.ecode) `CQPUT(RDMA_CQE_QPN,x.qpn) `CQPUT(RDMA_CQE_IMMDT_DATA,x.immediate_data) `CQPUT(RDMA_CQE_PAYLOAD_LEN,x.payload_len) `CQPUT(RDMA_CQE_SIGNATURE,x.signature) `undef CQPUT return rdma_status::success(); endfunction
  // 功能：在 rdma_hw_cqe_codec 中，decode_fields 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_fields(rdma_hw_qword_builder b, output rdma_hw_model model); rdma_hw_cqe_model x; bit [63:0] v; rdma_status s; x=rdma_hw_cqe_model::type_id::create("decoded_cqe"); x.qp_h=rdma_hw_queue_projected_handle("decoded_qp",RDMA_RESOURCE_QP,0); `define CQGET(S,T) v='0; s=b.get_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return err(s.message); T=v;
    `CQGET(RDMA_CQE_POLARITY,x.polarity) `CQGET(RDMA_CQE_RQ_CQE,x.rq_cqe) `CQGET(RDMA_CQE_WQE_WRAP,x.wqe_wrap) `CQGET(RDMA_CQE_WQE_INDEX,x.wqe_index) `CQGET(RDMA_CQE_PKT_OPCODE,x.packet_opcode) `CQGET(RDMA_CQE_ECODE,x.ecode) `CQGET(RDMA_CQE_QPN,x.qpn) `CQGET(RDMA_CQE_IMMDT_DATA,x.immediate_data) `CQGET(RDMA_CQE_PAYLOAD_LEN,x.payload_len) `CQGET(RDMA_CQE_SIGNATURE,x.signature) `undef CQGET x.status=rdma_status::type_id::create("decoded_status"); model=x; return rdma_status::success(); endfunction
endclass

class rdma_hw_ceqe_codec extends rdma_hw_queue_codec_base;
  `uvm_object_utils(rdma_hw_ceqe_codec)

  // 功能：构造 rdma_hw_ceqe_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_ceqe_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_ceqe_codec"); super.new(name); endfunction
  // 功能：在 rdma_hw_ceqe_codec 中，image_kind_expected 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：无显式参数；image_kind_expected 返回 CEQE codec 固定的 RDMA_IMAGE_CEQE 类型，不读取可变对象字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：image_kind_expected 是只读访问器，返回 RDMA_IMAGE_CEQE；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_CEQE; endfunction protected virtual function int unsigned image_bytes(); return RDMA_CEQE_BYTES; endfunction
  // 功能：check_reserved 校验 b 与当前对象状态的一致性，并显式处理“CEQE reserved bits are nonzero”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：b（输入）；check_reserved 读取 b 并使用字段 s、s.message、x、model；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：check_reserved 是只读访问器，返回 err("CEQE reserved bits are nonzero")；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b); bit [63:0] w[]; b.get_words(w); if ((w[0]&~64'h9fff_ff1f_ffff_ffff)!=0 || (w[1]&~64'h0000_0000_0080_ffff)!=0) return err("CEQE reserved bits are nonzero"); return rdma_status::success(); endfunction
  // 功能：在 rdma_hw_ceqe_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b); rdma_hw_ceqe_model x; rdma_status s; if(!$cast(x,model)) return err("CEQE model type mismatch"); s=x.validate(); if(!s.ok()) return s; `define EQPUT(S,V) s=b.put_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return err(s.message);
    `EQPUT(RDMA_CEQE_VALID,x.valid) `EQPUT(RDMA_CEQE_QPN,x.qpn) `EQPUT(RDMA_CEQE_CQN,x.cqn) `EQPUT(RDMA_CEQE_ECODE,x.ecode) `EQPUT(RDMA_CEQE_PKT_OPCODE,x.packet_opcode) `EQPUT(RDMA_CEQE_CQ_PI_WRAP,x.cq_pi_wrap) `EQPUT(RDMA_CEQE_CQ_PI,x.cq_pi) `undef EQPUT return rdma_status::success(); endfunction
  // 功能：在 rdma_hw_ceqe_codec 中，decode_fields 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_fields(rdma_hw_qword_builder b, output rdma_hw_model model); rdma_hw_ceqe_model x; bit [63:0] v; rdma_status s; x=rdma_hw_ceqe_model::type_id::create("decoded_ceqe"); x.cq_h=rdma_hw_queue_projected_handle("decoded_cq",RDMA_RESOURCE_CQ,0); `define EQGET(S,T) v='0; s=b.get_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return err(s.message); T=v;
    `EQGET(RDMA_CEQE_VALID,x.valid) `EQGET(RDMA_CEQE_QPN,x.qpn) `EQGET(RDMA_CEQE_CQN,x.cqn) `EQGET(RDMA_CEQE_ECODE,x.ecode) `EQGET(RDMA_CEQE_PKT_OPCODE,x.packet_opcode) `EQGET(RDMA_CEQE_CQ_PI_WRAP,x.cq_pi_wrap) `EQGET(RDMA_CEQE_CQ_PI,x.cq_pi) `undef EQGET model=x; return rdma_status::success(); endfunction
endclass

class rdma_hw_aeqe_codec extends rdma_hw_queue_codec_base;
  `uvm_object_utils(rdma_hw_aeqe_codec)

  // 功能：构造 rdma_hw_aeqe_codec，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_aeqe_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_hw_aeqe_codec"); super.new(name); endfunction
  // 功能：在 rdma_hw_aeqe_codec 中，image_kind_expected 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：无显式参数；image_kind_expected 返回 AEQE codec 固定的 RDMA_IMAGE_AEQE 类型，不读取可变对象字段；函数返回 rdma_image_kind_e，不取得调用方资源所有权。
  // 失败/边界：image_kind_expected 是只读访问器，返回 RDMA_IMAGE_AEQE；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_AEQE; endfunction protected virtual function int unsigned image_bytes(); return RDMA_AEQE_BYTES; endfunction
  // 功能：check_reserved 校验 b 与当前对象状态的一致性，并显式处理“AEQE reserved bits are nonzero”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：b（输入）；check_reserved 读取 b 并使用字段 s、s.message、x、model；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：check_reserved 是只读访问器，返回 err("AEQE reserved bits are nonzero")；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected virtual function rdma_status check_reserved(rdma_hw_qword_builder b); bit [63:0] w[]; b.get_words(w); if ((w[0]&~64'hf000_00ff_ff03_ffff)!=0 || (w[1]&~64'h00ff_ffff_0000_0000)!=0) return err("AEQE reserved bits are nonzero"); return rdma_status::success(); endfunction
  // 功能：在 rdma_hw_aeqe_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、b（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_hw_qword_builder b); rdma_hw_aeqe_model x; rdma_status s; if(!$cast(x,model)) return err("AEQE model type mismatch"); s=x.validate(); if(!s.ok()) return s; `define EQPUT2(S,V) s=b.put_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return err(s.message);
    `EQPUT2(RDMA_AEQE_VALID,x.valid) `EQPUT2(RDMA_AEQE_QP_ST,x.qp_state) `EQPUT2(RDMA_AEQE_PKT_OPCODE,x.packet_opcode) `EQPUT2(RDMA_AEQE_ECODE,x.ecode) `EQPUT2(RDMA_AEQE_QPN,x.qpn) `EQPUT2(RDMA_AEQE_WQE_WRAP,x.wqe_wrap) `EQPUT2(RDMA_AEQE_WQE_INDEX,x.wqe_index) `undef EQPUT2 return rdma_status::success(); endfunction
  // 功能：在 rdma_hw_aeqe_codec 中，decode_fields 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：b（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected virtual function rdma_status decode_fields(rdma_hw_qword_builder b, output rdma_hw_model model); rdma_hw_aeqe_model x; bit [63:0] v; rdma_status s; x=rdma_hw_aeqe_model::type_id::create("decoded_aeqe"); x.target_h=rdma_hw_queue_projected_handle("decoded_qp",RDMA_RESOURCE_QP,0); `define EQGET2(S,T) v='0; s=b.get_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return err(s.message); T=v;
    `EQGET2(RDMA_AEQE_VALID,x.valid) `EQGET2(RDMA_AEQE_QP_ST,x.qp_state) `EQGET2(RDMA_AEQE_PKT_OPCODE,x.packet_opcode) `EQGET2(RDMA_AEQE_ECODE,x.ecode) `EQGET2(RDMA_AEQE_QPN,x.qpn) `EQGET2(RDMA_AEQE_WQE_WRAP,x.wqe_wrap) `EQGET2(RDMA_AEQE_WQE_INDEX,x.wqe_index) `undef EQGET2 model=x; return rdma_status::success(); endfunction
endclass

function rdma_status rdma_queue_codec::encode_sqe(
    input rdma_post_send_req request, output byte unsigned image[]);
  rdma_hw_sqe_model model; rdma_hw_image encoded; rdma_status status;
  rdma_sqe_rc_ext rc; rdma_sqe_ud_ext ud; rdma_sqe_urc_ext urc;
  rdma_hw_queue_codec_base codec;
  image = new[0];
  if (request == null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE request is null");
  status = request.validate(); if (!status.ok()) return status;
  model = rdma_hw_sqe_model::type_id::create("sqe_request_model");
  model.transport=request.transport; model.opcode=request.opcode; model.qp_h=request.qp_h;
  model.wr_id=request.wr_id; model.inline_data=request.inline_data; model.payload=request.payload;
  model.signaled=request.signaled; model.solicited=request.solicited; model.immediate_data=request.immediate_data;
  model.remote_va=request.remote_addr; model.rkey=request.rkey; model.invalidate_key=request.invalidate_rkey;
  // 原子操作的本地地址、lkey 和 compare/swap 值属于请求快照的一部分，
  // facade 必须完整复制，不能依赖 hardware model 的默认零值。
  model.atomic_local_iova = request.sges.size() == 0 ? '0 : request.sges[0].iova;
  model.atomic_local_lkey = request.sges.size() == 0 ? '0 : request.sges[0].lkey;
  model.atomic_compare = request.compare_value;
  model.atomic_value = request.swap_add_value;
  model.destination_qpn=request.destination_qpn; model.qkey=request.qkey; model.valid=1'b1; model.sign_en=1'b1;
  model.sgb_iova=request.sgb_iova;
  model.ce=request.signaled ? 1 : 0; model.se=request.solicited; model.sge_num=request.sges.size();
  foreach(request.sges[i]) begin rdma_sge sg; if(request.sges[i]==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE SGE is null"); sg=rdma_sge::type_id::create("sqe_sge"); sg.copy(request.sges[i]); model.sges.push_back(sg); end
  case(request.transport)
    RDMA_TRANSPORT_RC: begin rc=rdma_sqe_rc_ext::type_id::create("sqe_rc_ext"); rc.remote_addr=request.remote_addr; rc.rkey=request.rkey; rc.remote_access_valid=request.remote_access_valid; rc.rkey_valid=request.rkey_valid; model.transport_ext=rc; codec=rdma_hw_sqe_rc_codec::type_id::create("sqe_rc_codec"); end
    RDMA_TRANSPORT_UD: begin ud=rdma_sqe_ud_ext::type_id::create("sqe_ud_ext"); ud.destination_qpn=request.destination_qpn; ud.qkey=request.qkey; ud.address_vector_id=request.address_vector_id; ud.address_vector_valid=request.address_vector_valid; ud.address_vector=request.address_vector; model.transport_ext=ud; codec=rdma_hw_sqe_ud_codec::type_id::create("sqe_ud_codec"); end
    RDMA_TRANSPORT_URC: begin urc=rdma_sqe_urc_ext::type_id::create("sqe_urc_ext"); urc.destination_qpn=request.destination_qpn; urc.remote_addr=request.remote_addr; urc.rkey=request.rkey; urc.remote_access_valid=request.remote_access_valid; urc.rkey_valid=request.rkey_valid; urc.completion_qp_h=request.completion_qp_h; model.transport_ext=urc; codec=rdma_hw_sqe_urc_codec::type_id::create("sqe_urc_codec"); end
    default: return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,"SQE transport is unsupported");
  endcase
  status=codec.encode(model,encoded); if(!status.ok()) return status;
  image=new[encoded.bytes.size()]; foreach(image[i]) image[i]=encoded.bytes[i]; return rdma_status::success();
endfunction

// 功能：在 rdma_hw_aeqe_codec 中，rdma_register_queue_codecs 把 XTR v1 对应对象类型、opcode 和 variant 的 codec 注册到 profile registry，并拒绝重复键。
// 输入/输出及副作用：registry（输入）；rdma_register_queue_codecs 读取 registry 并使用字段 k.hw_version、k.opcode、k.image_kind、k.object_type、k.variant、s；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_register_queue_codecs 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue codec registry is null”；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_register_queue_codecs(rdma_codec_registry registry);
  rdma_codec_key k; rdma_status s; if(registry==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue codec registry is null"); k.hw_version="rdma"; k.opcode=0;
  k.image_kind=RDMA_IMAGE_SQE; k.object_type="sqe"; k.variant="rc"; s=registry.register_codec(k,rdma_hw_sqe_rc_codec::type_id::create("sqe_rc")); if(!s.ok()) return s; k.variant="ud"; s=registry.register_codec(k,rdma_hw_sqe_ud_codec::type_id::create("sqe_ud")); if(!s.ok()) return s; k.variant="urc"; s=registry.register_codec(k,rdma_hw_sqe_urc_codec::type_id::create("sqe_urc")); if(!s.ok()) return s;
  k.image_kind=RDMA_IMAGE_RQE; k.object_type="rqe"; k.variant="default"; s=registry.register_codec(k,rdma_hw_rqe_codec::type_id::create("rqe")); if(!s.ok()) return s; k.image_kind=RDMA_IMAGE_CQE; k.object_type="cqe"; s=registry.register_codec(k,rdma_hw_cqe_codec::type_id::create("cqe")); if(!s.ok()) return s; k.image_kind=RDMA_IMAGE_CEQE; k.object_type="ceqe"; s=registry.register_codec(k,rdma_hw_ceqe_codec::type_id::create("ceqe")); if(!s.ok()) return s; k.image_kind=RDMA_IMAGE_AEQE; k.object_type="aeqe"; return registry.register_codec(k,rdma_hw_aeqe_codec::type_id::create("aeqe"));
endfunction
