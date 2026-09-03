// 中文说明：rdma_xtr_v1_queue_codecs.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// XTR v1 fixed-size queue data entry codecs.  Queue fields are authored in
// logical qwords and serialized big-endian by rdma_xtr_v1_qword_builder.

function automatic rdma_handle rdma_xtr_v1_queue_projected_handle(
    string name, rdma_resource_kind_e kind, int unsigned id,
    int unsigned generation = 1);
  rdma_handle h;
  h = rdma_handle::type_id::create(name);
  h.kind = kind; h.object_id = id; h.generation = generation;
  return h;
endfunction

class rdma_xtr_v1_sqe_model extends rdma_sqe_model;
  `uvm_object_utils(rdma_xtr_v1_sqe_model)
  bit [20:0] qpn; bit [2:0] icos; bit [7:0] qp_sn; bit [3:0] dst_port;
  bit [14:0] index; bit wrap; bit sign_en; bit se; bit [1:0] fence; bit [1:0] ce;
  bit valid; bit [7:0] signature; bit [7:0] sge_num; bit [3:0] hw_opcode;
  bit [31:0] rkey; rdma_iova_t remote_va;
  rdma_sq_payload_mode_e payload_mode;
  longint unsigned total_payload_len;
  byte unsigned inline_bytes[];
  rdma_iova_t sgb_iova;
  bit [31:0] invalidate_key;
  rdma_iova_t atomic_local_iova;
  bit [31:0] atomic_local_lkey;
  longint unsigned atomic_value;
  longint unsigned atomic_compare;

  function new(string name="rdma_xtr_v1_sqe_model");
    super.new(name);
    remote_va='0; sgb_iova='0; atomic_local_iova='0;
    payload_mode = RDMA_SQ_PAYLOAD_NONE;
    total_payload_len = 0; inline_bytes = new[0];
    invalidate_key = 0; atomic_local_lkey = 0;
    atomic_value = 0; atomic_compare = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_sqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr SQE copy mismatch");
    qpn=x.qpn; icos=x.icos; qp_sn=x.qp_sn; dst_port=x.dst_port; index=x.index; wrap=x.wrap; sign_en=x.sign_en; se=x.se; fence=x.fence; ce=x.ce; valid=x.valid; signature=x.signature; sge_num=x.sge_num; hw_opcode=x.hw_opcode; rkey=x.rkey; remote_va=x.remote_va;
    payload_mode=x.payload_mode; total_payload_len=x.total_payload_len;
    inline_bytes=x.inline_bytes; sgb_iova=x.sgb_iova;
    invalidate_key=x.invalidate_key; atomic_local_iova=x.atomic_local_iova;
    atomic_local_lkey=x.atomic_local_lkey; atomic_value=x.atomic_value;
    atomic_compare=x.atomic_compare;
  endfunction

  virtual function rdma_status validate();
    if (qp_h==null || qp_h.kind!=RDMA_RESOURCE_QP) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE requires QP handle");
    if (qpn > 21'h7ffff || icos > 3'd7 || index > 15'h7fff) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE field width overflow");
    if (transport_ext!=null && transport_ext.transport_kind()!=transport) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE transport extension mismatch");
    if (payload_mode > RDMA_SQ_PAYLOAD_ATOMIC_FIXED) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE payload mode is invalid");
    return rdma_status::success();
  endfunction

  virtual function string describe(); return $sformatf("XTR_SQE(qpn=%0d opcode=%0d index=%0d)",qpn,hw_opcode,index); endfunction
endclass

class rdma_xtr_v1_rqe_model extends rdma_rqe_model;
  `uvm_object_utils(rdma_xtr_v1_rqe_model)
  bit [23:0] qpn; bit [7:0] qp_sn; bit [3:0] hw_opcode; bit [14:0] index; bit wrap; bit valid;
  bit [31:0] payload_len; bit [7:0] signature; bit [7:0] sge_num;

  function new(string name="rdma_xtr_v1_rqe_model"); super.new(name); endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_rqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr RQE copy mismatch");
    qpn=x.qpn; qp_sn=x.qp_sn; hw_opcode=x.hw_opcode; index=x.index; wrap=x.wrap; valid=x.valid; payload_len=x.payload_len; signature=x.signature; sge_num=x.sge_num;
  endfunction

  virtual function rdma_status validate();
    if (target_h==null || !(target_h.kind inside {RDMA_RESOURCE_QP,RDMA_RESOURCE_SRQ})) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"RQE requires QP or SRQ handle");
    if (index > 15'h7fff) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"RQE index exceeds width");
    return rdma_status::success();
  endfunction

  virtual function string describe(); return $sformatf("XTR_RQE(qpn=%0d opcode=%0d index=%0d)",qpn,hw_opcode,index); endfunction
endclass

class rdma_xtr_v1_cqe_model extends rdma_cqe_model;
  `uvm_object_utils(rdma_xtr_v1_cqe_model)
  bit [17:0] qpn; bit [14:0] wqe_index; bit wqe_wrap; bit rq_cqe; bit polarity;
  bit [7:0] packet_opcode; bit [7:0] ecode; bit [31:0] payload_len; bit [31:0] immediate_data; bit [7:0] signature;

  function new(string name="rdma_xtr_v1_cqe_model"); super.new(name); endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_cqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr CQE copy mismatch");
    qpn=x.qpn; wqe_index=x.wqe_index; wqe_wrap=x.wqe_wrap; rq_cqe=x.rq_cqe; polarity=x.polarity; packet_opcode=x.packet_opcode; ecode=x.ecode; payload_len=x.payload_len; immediate_data=x.immediate_data; signature=x.signature;
  endfunction

  virtual function rdma_status validate();
    if (qp_h==null || qp_h.kind!=RDMA_RESOURCE_QP) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"CQE requires QP handle");
    if (status==null) status=rdma_status::type_id::create("cqe_status");
    return rdma_status::success();
  endfunction

  virtual function string describe(); return $sformatf("XTR_CQE(qpn=%0d index=%0d ecode=0x%02x)",qpn,wqe_index,ecode); endfunction
endclass

class rdma_xtr_v1_ceqe_model extends rdma_ceqe_model;
  `uvm_object_utils(rdma_xtr_v1_ceqe_model)
  bit [20:0] qpn; bit [20:0] cqn; bit [7:0] ecode; bit [7:0] packet_opcode; bit [15:0] cq_pi; bit cq_pi_wrap; bit valid;

  function new(string name="rdma_xtr_v1_ceqe_model"); super.new(name); endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_ceqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr CEQE copy mismatch");
    qpn=x.qpn; cqn=x.cqn; ecode=x.ecode; packet_opcode=x.packet_opcode; cq_pi=x.cq_pi; cq_pi_wrap=x.cq_pi_wrap; valid=x.valid;
  endfunction

  virtual function rdma_status validate();
    if (cq_h==null || cq_h.kind!=RDMA_RESOURCE_CQ) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"CEQE requires CQ handle");
    if (cq_h.object_id != 0 && cqn != 0 && cq_h.object_id != cqn) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"CEQE CQN does not match handle");
    return rdma_status::success();
  endfunction

  virtual function string describe(); return $sformatf("XTR_CEQE(qpn=%0d cqn=%0d)",qpn,cqn); endfunction
endclass

class rdma_xtr_v1_aeqe_model extends rdma_aeqe_model;
  `uvm_object_utils(rdma_xtr_v1_aeqe_model)
  bit [17:0] qpn; bit [2:0] qp_state; bit [7:0] ecode; bit [7:0] packet_opcode; bit [22:0] wqe_index; bit wqe_wrap; bit valid;

  function new(string name="rdma_xtr_v1_aeqe_model"); super.new(name); endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_aeqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr AEQE copy mismatch");
    qpn=x.qpn; qp_state=x.qp_state; ecode=x.ecode; packet_opcode=x.packet_opcode; wqe_index=x.wqe_index; wqe_wrap=x.wqe_wrap; valid=x.valid;
  endfunction

  virtual function rdma_status validate(); if (target_h==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"AEQE target handle is null"); return rdma_status::success(); endfunction

  virtual function string describe(); return $sformatf("XTR_AEQE(qpn=%0d ecode=0x%02x)",qpn,ecode); endfunction
endclass

virtual class rdma_xtr_v1_queue_codec_base extends rdma_codec_base;

  function new(string name="rdma_xtr_v1_queue_codec_base"); super.new(name); endfunction
  protected pure virtual function rdma_image_kind_e image_kind_expected();
  protected pure virtual function int unsigned image_bytes();
  protected pure virtual function rdma_status encode_fields(rdma_hw_model model, rdma_xtr_v1_qword_builder b);
  protected pure virtual function rdma_status decode_fields(rdma_xtr_v1_qword_builder b, output rdma_hw_model model);
  protected pure virtual function rdma_status check_reserved(rdma_xtr_v1_qword_builder b);
  protected function rdma_status err(string m); return rdma_status::make(RDMA_SC_CODEC_ERROR,m); endfunction
  protected function int unsigned model_handle_generation(rdma_hw_model model);
    rdma_xtr_v1_sqe_model sq; rdma_xtr_v1_rqe_model rq; rdma_xtr_v1_cqe_model cq;
    rdma_xtr_v1_ceqe_model eq; rdma_xtr_v1_aeqe_model aq;
    if ($cast(sq, model) && sq.qp_h != null) return sq.qp_h.generation;
    if ($cast(rq, model) && rq.target_h != null) return rq.target_h.generation;
    if ($cast(cq, model) && cq.qp_h != null) return cq.qp_h.generation;
    if ($cast(eq, model) && eq.cq_h != null) return eq.cq_h.generation;
    if ($cast(aq, model) && aq.target_h != null) return aq.target_h.generation;
    return 0;
  endfunction

  virtual function rdma_status validate_model(rdma_hw_model model); if (model==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue model is null"); if (model_handle_generation(model)==0) return rdma_status::make(RDMA_SC_STALE_GENERATION,"queue model handle generation is stale"); return rdma_status::success(); endfunction

  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_xtr_v1_qword_builder b; byte unsigned p[]; rdma_status s;
    if (image==null) return err("queue image is null");
    if (image.function_generation==0) return rdma_status::make(RDMA_SC_STALE_GENERATION,"queue image generation is stale");
    if (image.length!=image_bytes() || image.bytes.size()!=image_bytes() || image.alignment!=image_bytes() || image.endian!=RDMA_ENDIAN_BIG || image.image_kind!=image_kind_expected() || image.hardware_version!=XTR_V1_HW_VERSION || image.write_target_kind!=RDMA_HW_TARGET_NONE || image.backing_target.value!=0 || image.hmc_target.value!=0 || image.bar_target.value!=0) return err("queue image metadata is invalid");
    p=new[image_bytes()]; foreach (p[i]) p[i]=image.bytes[i]; b=new("queue_validate"); s=b.deserialize(p); if (!s.ok()) return err(s.message); return check_reserved(b);
  endfunction

  virtual function rdma_byte_endian_e hardware_endian(); return RDMA_ENDIAN_BIG; endfunction

  virtual function string describe_fields(); return $sformatf("xtr_v1 %0d-byte queue image",image_bytes()); endfunction

  virtual function rdma_status encode(rdma_hw_model model, output rdma_hw_image image);
    rdma_xtr_v1_qword_builder b; byte unsigned p[]; rdma_hw_image c; rdma_status s; image=null;
    s=validate_model(model); if (!s.ok()) return s; b=new("queue_encode"); s=b.reset(image_bytes()); if (!s.ok()) return err(s.message); s=encode_fields(model,b); if (!s.ok()) return s; s=check_reserved(b); if (!s.ok()) return s; p=new[0]; s=b.serialize(p); if (!s.ok()) return err(s.message); c=rdma_hw_image::type_id::create("queue_image"); foreach(p[i]) c.bytes.push_back(p[i]); c.length=image_bytes(); c.alignment=image_bytes(); c.endian=RDMA_ENDIAN_BIG; c.image_kind=image_kind_expected(); c.hardware_version=XTR_V1_HW_VERSION; c.function_generation=model_handle_generation(model); c.write_target_kind=RDMA_HW_TARGET_NONE; image=c; return rdma_status::success();
  endfunction

  virtual function rdma_status decode(rdma_hw_image image, output rdma_hw_model model);
    rdma_xtr_v1_qword_builder b; byte unsigned p[]; rdma_status s; rdma_hw_model candidate; model=null;
    s=validate_image(image); if (!s.ok()) return s; p=new[image_bytes()]; foreach(p[i]) p[i]=image.bytes[i]; b=new("queue_decode"); s=b.deserialize(p); if (!s.ok()) return err(s.message); s=decode_fields(b,candidate); if (!s.ok()) return s; model=candidate; return rdma_status::success();
  endfunction

  virtual function rdma_status serialized_equal(rdma_hw_model lhs, rdma_hw_model rhs, output bit equal, output string mismatch);
    rdma_hw_image a,b; rdma_status s; equal=0; mismatch=""; s=encode(lhs,a); if(!s.ok()) return s; s=encode(rhs,b); if(!s.ok()) return s; if(a.image_kind!=b.image_kind || a.length!=b.length) begin mismatch="queue metadata differs"; return rdma_status::success(); end foreach(a.bytes[i]) if(a.bytes[i]!==b.bytes[i]) begin mismatch=$sformatf("queue byte %0d differs",i); return rdma_status::success(); end equal=1; return rdma_status::success();
  endfunction
endclass

class rdma_xtr_v1_sqe_codec_base extends rdma_xtr_v1_queue_codec_base;

  function new(string name="rdma_xtr_v1_sqe_codec_base"); super.new(name); endfunction
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_SQE; endfunction
  protected virtual function int unsigned image_bytes(); return XTR_V1_WQE_BYTES; endfunction
  protected function rdma_status put(rdma_xtr_v1_qword_builder b,int unsigned o,int unsigned l,int unsigned w,bit [63:0] v); rdma_status s=b.put_field(o,l,w,v); return s.ok()?s:rdma_status::make(RDMA_SC_CODEC_ERROR,s.message); endfunction
  protected function rdma_status get(rdma_xtr_v1_qword_builder b,int unsigned o,int unsigned l,int unsigned w,inout bit [63:0] v); rdma_status s=b.get_field(o,l,w,v); return s.ok()?s:rdma_status::make(RDMA_SC_CODEC_ERROR,s.message); endfunction
  protected virtual function rdma_status check_reserved(rdma_xtr_v1_qword_builder b);
    bit [63:0] w[];
    b.get_words(w);
    if ((w[0] & ~64'hefff_ffff_ffff_ffff) != 0)
      return err("SQE header reserved bits are nonzero");
    return rdma_status::success();
  endfunction
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_xtr_v1_qword_builder b); rdma_xtr_v1_sqe_model x; rdma_status s; if(!$cast(x,model)) return err("SQE model type mismatch"); s=x.validate(); if(!s.ok()) return s;
    `define SQPUT(S,V) s=put(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return s;
    `SQPUT(XTR_V1_SQ_WQE_QPN,x.qpn) `SQPUT(XTR_V1_SQ_WQE_ICOS,x.icos) `SQPUT(XTR_V1_SQ_WQE_QP_SN,x.qp_sn) `SQPUT(XTR_V1_SQ_WQE_OPCODE,x.hw_opcode) `SQPUT(XTR_V1_SQ_WQE_DST_PORT,x.dst_port) `SQPUT(XTR_V1_SQ_WQE_INDEX,x.index) `SQPUT(XTR_V1_SQ_WQE_WRAP,x.wrap) `SQPUT(XTR_V1_SQ_WQE_SIGN_EN,x.sign_en) `SQPUT(XTR_V1_SQ_WQE_SE,x.se) `SQPUT(XTR_V1_SQ_WQE_FENCE,x.fence) `SQPUT(XTR_V1_SQ_WQE_CE,x.ce) `SQPUT(XTR_V1_SQ_WQE_VALID,x.valid) `SQPUT(XTR_V1_SQ_WQE_SIGNATURE,x.signature) `SQPUT(XTR_V1_SQ_WQE_RC_SGE_NUM,x.sge_num)
    if (x.transport!=RDMA_TRANSPORT_RC) return rdma_status::success();
    `SQPUT(XTR_V1_SQ_WQE_RC_REMOTE_KEY,x.rkey) `SQPUT(XTR_V1_SQ_WQE_RC_REMOTE_VA,x.remote_va.value) `undef SQPUT return rdma_status::success();
  endfunction
  protected virtual function rdma_status decode_fields(rdma_xtr_v1_qword_builder b, output rdma_hw_model model); rdma_xtr_v1_sqe_model x; rdma_sqe_rc_ext ext; bit [63:0] v; rdma_status s; x=rdma_xtr_v1_sqe_model::type_id::create("decoded_sqe"); x.transport=RDMA_TRANSPORT_RC; x.opcode=RDMA_WR_SEND; x.inline_data=1; x.payload.push_back(0); x.qp_h=rdma_xtr_v1_queue_projected_handle("decoded_qp",RDMA_RESOURCE_QP,0); ext=rdma_sqe_rc_ext::type_id::create("decoded_rc_ext"); x.transport_ext=ext; `define SQGET(S,T) v='0; s=get(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return s; T=v;
    `SQGET(XTR_V1_SQ_WQE_QPN,x.qpn) `SQGET(XTR_V1_SQ_WQE_ICOS,x.icos) `SQGET(XTR_V1_SQ_WQE_QP_SN,x.qp_sn) `SQGET(XTR_V1_SQ_WQE_OPCODE,x.hw_opcode) `SQGET(XTR_V1_SQ_WQE_DST_PORT,x.dst_port) `SQGET(XTR_V1_SQ_WQE_INDEX,x.index) `SQGET(XTR_V1_SQ_WQE_WRAP,x.wrap) `SQGET(XTR_V1_SQ_WQE_SIGN_EN,x.sign_en) `SQGET(XTR_V1_SQ_WQE_SE,x.se) `SQGET(XTR_V1_SQ_WQE_FENCE,x.fence) `SQGET(XTR_V1_SQ_WQE_CE,x.ce) `SQGET(XTR_V1_SQ_WQE_VALID,x.valid) `SQGET(XTR_V1_SQ_WQE_SIGNATURE,x.signature) `SQGET(XTR_V1_SQ_WQE_RC_SGE_NUM,x.sge_num) `SQGET(XTR_V1_SQ_WQE_RC_REMOTE_KEY,x.rkey) `SQGET(XTR_V1_SQ_WQE_RC_REMOTE_VA,x.remote_va.value) `undef SQGET model=x; return rdma_status::success(); endfunction
endclass

function automatic bit [7:0] rdma_xtr_v1_sq_signature_xor(
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

function automatic rdma_status validate_sq_signature(
    rdma_hw_image wqe,
    byte unsigned sgb[$],
    output bit valid);
  bit [7:0] expected;
  valid = 1'b0;
  if (wqe == null || wqe.image_kind != RDMA_IMAGE_SQE ||
      wqe.length != XTR_V1_WQE_BYTES || wqe.bytes.size() != XTR_V1_WQE_BYTES)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "SQ signature image metadata is invalid");
  if (sgb.size() != 0 && sgb.size() != 512)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "SQ signature SGB must be exactly 512 bytes");
  expected = ~rdma_xtr_v1_sq_signature_xor(wqe, sgb);
  valid = (wqe.bytes[16] === expected);
  return rdma_status::success();
endfunction

class rdma_xtr_v1_sqe_rc_codec extends rdma_xtr_v1_sqe_codec_base;
  `uvm_object_utils(rdma_xtr_v1_sqe_rc_codec)
  protected rdma_sq_payload_mode_e last_mode;
  protected bit [3:0] last_hw_opcode;

  function new(string name="rdma_xtr_v1_sqe_rc_codec");
    super.new(name);
    last_mode = RDMA_SQ_PAYLOAD_NONE;
    last_hw_opcode = 0;
  endfunction

  protected function rdma_status map_opcode(
      rdma_work_opcode_e opcode,
      output bit [3:0] hw_opcode);
    case (opcode)
      RDMA_WR_SEND:             hw_opcode = XTR_V1_SQ_OPCODE_SEND;
      RDMA_WR_SEND_WITH_IMM:    hw_opcode = XTR_V1_SQ_OPCODE_SEND_WITH_IMM;
      RDMA_WR_RDMA_WRITE:       hw_opcode = XTR_V1_SQ_OPCODE_WRITE;
      RDMA_WR_WRITE_WITH_IMM:   hw_opcode = XTR_V1_SQ_OPCODE_WRITE_WITH_IMM;
      RDMA_WR_RDMA_READ:        hw_opcode = XTR_V1_SQ_OPCODE_READ;
      RDMA_WR_ATOMIC_CMP_SWAP:  hw_opcode = XTR_V1_SQ_OPCODE_ATOMIC_CMP_AND_SWP;
      RDMA_WR_ATOMIC_FETCH_ADD: hw_opcode = XTR_V1_SQ_OPCODE_ATOMIC_FETCH_AND_ADD;
      RDMA_WR_LOCAL_INVALIDATE: hw_opcode = XTR_V1_SQ_OPCODE_LOCAL_INV;
      default:
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "RC SQE opcode is unsupported");
    endcase
    return rdma_status::success();
  endfunction

  protected function rdma_sq_payload_mode_e mode_of(rdma_xtr_v1_sqe_model x);
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

  protected function automatic longint unsigned payload_length(
      rdma_xtr_v1_sqe_model x,
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

  protected function rdma_status put_header(
      rdma_xtr_v1_sqe_model x,
      rdma_sq_payload_mode_e mode,
      bit [3:0] hw_opcode,
      rdma_xtr_v1_qword_builder b);
    rdma_status s;
    bit [1:0] ce_value;
    bit [1:0] fence_value;
    bit se_value;
    ce_value = x.signaled ? 2'd1 : 2'd0;
    fence_value = x.opcode == RDMA_WR_LOCAL_INVALIDATE ? 2'd1 :
                  (x.fence != 0 ? 2'd2 : 2'd0);
    se_value = x.opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                                RDMA_WR_WRITE_WITH_IMM} ? x.se : 1'b0;
    `define RCPUT(S,V) s=put(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return s;
    `RCPUT(XTR_V1_SQ_WQE_QPN,x.qpn)
    `RCPUT(XTR_V1_SQ_WQE_ICOS,x.icos)
    `RCPUT(XTR_V1_SQ_WQE_QP_SN,x.qp_sn)
    `RCPUT(XTR_V1_SQ_WQE_OPCODE,hw_opcode)
    `RCPUT(XTR_V1_SQ_WQE_DST_PORT,x.dst_port)
    `RCPUT(XTR_V1_SQ_WQE_INDEX,x.index)
    `RCPUT(XTR_V1_SQ_WQE_WRAP,x.wrap)
    `RCPUT(XTR_V1_SQ_WQE_SIGN_EN,1'b1)
    `RCPUT(XTR_V1_SQ_WQE_SE,se_value)
    `RCPUT(XTR_V1_SQ_WQE_FENCE,fence_value)
    `RCPUT(XTR_V1_SQ_WQE_INLINE_LOCAL_QPC_RD,
           mode inside {RDMA_SQ_PAYLOAD_INLINE_WQE,
                        RDMA_SQ_PAYLOAD_INLINE_SGB})
    `RCPUT(XTR_V1_SQ_WQE_CE,ce_value)
    `RCPUT(XTR_V1_SQ_WQE_VALID,x.valid)
    `undef RCPUT
    return rdma_status::success();
  endfunction

  protected function rdma_status put_sge(
      rdma_xtr_v1_qword_builder b,
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

  protected function rdma_status body_and_header(
      rdma_xtr_v1_sqe_model x,
      rdma_xtr_v1_qword_builder b,
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
        s = put(b, XTR_V1_SQ_WQE_SGB_PA_WORD_BYTE_OFFSET,
                XTR_V1_SQ_WQE_SGB_PA_LSB, XTR_V1_SQ_WQE_SGB_PA_WIDTH,
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
        s = put(b, XTR_V1_SQ_WQE_SGB_PA_WORD_BYTE_OFFSET,
                XTR_V1_SQ_WQE_SGB_PA_LSB, XTR_V1_SQ_WQE_SGB_PA_WIDTH,
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
      s = put(b, XTR_V1_SQ_WQE_ATOMIC_L_LEN_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_ATOMIC_L_LEN_LSB,
              XTR_V1_SQ_WQE_ATOMIC_L_LEN_WIDTH, 8); if (!s.ok()) return s;
      s = put(b, XTR_V1_SQ_WQE_ATOMIC_L_KEY_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_ATOMIC_L_KEY_LSB,
              XTR_V1_SQ_WQE_ATOMIC_L_KEY_WIDTH,
              local_sge.lkey);
      if (!s.ok()) return s;
      if ((x.atomic_local_iova.value & 64'h7) != 0 ||
          x.atomic_local_iova.value == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "atomic local IOVA is not 8-byte aligned");
      s = put(b, XTR_V1_SQ_WQE_ATOMIC_L_VA_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_ATOMIC_L_VA_LSB,
              XTR_V1_SQ_WQE_ATOMIC_L_VA_WIDTH, x.atomic_local_iova.value);
      if (!s.ok()) return s;
      s = put(b, XTR_V1_SQ_WQE_ATOMIC_FAA_ADD_DATA_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_ATOMIC_FAA_ADD_DATA_LSB,
              XTR_V1_SQ_WQE_ATOMIC_FAA_ADD_DATA_WIDTH, x.atomic_value);
      if (!s.ok()) return s;
      if (x.opcode == RDMA_WR_ATOMIC_CMP_SWAP)
        s = put(b, XTR_V1_SQ_WQE_ATOMIC_CAS_CMP_DATA_WORD_BYTE_OFFSET,
                XTR_V1_SQ_WQE_ATOMIC_CAS_CMP_DATA_LSB,
                XTR_V1_SQ_WQE_ATOMIC_CAS_CMP_DATA_WIDTH, x.atomic_compare);
      if (!s.ok()) return s;
    end
    if (x.opcode == RDMA_WR_LOCAL_INVALIDATE)
      s = put(b, XTR_V1_SQ_WQE_LOCAL_INVLD_STAG_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_LOCAL_INVLD_STAG_LSB,
              XTR_V1_SQ_WQE_LOCAL_INVLD_STAG_WIDTH, x.invalidate_key);
    else if (x.opcode inside {RDMA_WR_SEND_WITH_IMM,
                              RDMA_WR_WRITE_WITH_IMM})
      s = put(b, XTR_V1_SQ_WQE_RC_IMMEDIATE_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_RC_IMMEDIATE_LSB,
              XTR_V1_SQ_WQE_RC_IMMEDIATE_WIDTH, x.immediate_data);
    else if (x.immediate_data != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RC immediate data is invalid for opcode");
    if (!s.ok()) return s;
    s = put(b, XTR_V1_SQ_WQE_RC_TOTAL_PAYLOAD_LEN_WORD_BYTE_OFFSET,
            XTR_V1_SQ_WQE_RC_TOTAL_PAYLOAD_LEN_LSB,
            XTR_V1_SQ_WQE_RC_TOTAL_PAYLOAD_LEN_WIDTH, encoded_length);
    if (!s.ok()) return s;
    s = put(b, XTR_V1_SQ_WQE_RC_SGE_NUM_WORD_BYTE_OFFSET,
            XTR_V1_SQ_WQE_RC_SGE_NUM_LSB,
            XTR_V1_SQ_WQE_RC_SGE_NUM_WIDTH,
            mode inside {RDMA_SQ_PAYLOAD_INLINE_WQE,
                         RDMA_SQ_PAYLOAD_INLINE_SGB} ?
            ((length + 15) / 16) :
            (mode inside {RDMA_SQ_PAYLOAD_SGE_WQE,
                          RDMA_SQ_PAYLOAD_SGE_SGB,
                          RDMA_SQ_PAYLOAD_ATOMIC_FIXED} ?
             (mode == RDMA_SQ_PAYLOAD_ATOMIC_FIXED ? 1 : x.sges.size()) : 0));
    if (!s.ok()) return s;
    s = put(b, XTR_V1_SQ_WQE_RC_REMOTE_KEY_WORD_BYTE_OFFSET,
            XTR_V1_SQ_WQE_RC_REMOTE_KEY_LSB,
            XTR_V1_SQ_WQE_RC_REMOTE_KEY_WIDTH,
            (x.opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                              RDMA_WR_RDMA_READ,
                              RDMA_WR_ATOMIC_CMP_SWAP,
                              RDMA_WR_ATOMIC_FETCH_ADD}) ? x.rkey : 0);
    if (!s.ok()) return s;
    s = put(b, XTR_V1_SQ_WQE_RC_REMOTE_VA_WORD_BYTE_OFFSET,
            XTR_V1_SQ_WQE_RC_REMOTE_VA_LSB,
            XTR_V1_SQ_WQE_RC_REMOTE_VA_WIDTH,
            (x.opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                              RDMA_WR_RDMA_READ,
                              RDMA_WR_ATOMIC_CMP_SWAP,
                              RDMA_WR_ATOMIC_FETCH_ADD}) ? x.remote_va.value : 0);
    if (!s.ok()) return s;
    return put_header(x, mode, last_hw_opcode, b);
  endfunction

  protected virtual function rdma_status check_reserved(
      rdma_xtr_v1_qword_builder b);
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
            7: allowed = last_hw_opcode == XTR_V1_SQ_OPCODE_ATOMIC_CMP_AND_SWP ?
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
      for (int unsigned i = 32 + length; i < XTR_V1_WQE_BYTES; i++)
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
      if (last_hw_opcode != XTR_V1_SQ_OPCODE_LOCAL_INV || count != 0 ||
          w[1][31:0] != 0)
        return err("RC empty body is not a local invalidate");
    end
    return rdma_status::success();
  endfunction

  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_xtr_v1_qword_builder b;
    bit [63:0] w[];
    byte unsigned raw[];
    rdma_status s;
    b = new("rc_image_probe");
    if (image != null && image.bytes.size() == XTR_V1_WQE_BYTES) begin
      raw = new[XTR_V1_WQE_BYTES];
      foreach (raw[i]) raw[i] = image.bytes[i];
      s = b.deserialize(raw);
      if (s.ok()) begin
        b.get_words(w);
        last_hw_opcode = w[0][35:32];
        if (last_hw_opcode inside {XTR_V1_SQ_OPCODE_LOCAL_INV,
                                   XTR_V1_SQ_OPCODE_ATOMIC_CMP_AND_SWP,
                                   XTR_V1_SQ_OPCODE_ATOMIC_FETCH_AND_ADD})
          last_mode = last_hw_opcode == XTR_V1_SQ_OPCODE_LOCAL_INV ?
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

  protected virtual function rdma_status encode_fields(
      rdma_hw_model model,
      rdma_xtr_v1_qword_builder b);
    rdma_xtr_v1_sqe_model x;
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
    s = put(b, XTR_V1_SQ_WQE_SIGNATURE_WORD_BYTE_OFFSET,
            XTR_V1_SQ_WQE_SIGNATURE_LSB,
            XTR_V1_SQ_WQE_SIGNATURE_WIDTH, signature);
    return s;
  endfunction

  protected virtual function rdma_status decode_fields(
      rdma_xtr_v1_qword_builder b,
      output rdma_hw_model model);
    rdma_xtr_v1_sqe_model x;
    rdma_sqe_rc_ext ext;
    bit [63:0] v;
    bit [63:0] words[];
    byte unsigned p[];
    rdma_status s;
    int unsigned count;
    x = rdma_xtr_v1_sqe_model::type_id::create("decoded_rc_sqe");
    x.transport = RDMA_TRANSPORT_RC;
    x.qp_h = rdma_xtr_v1_queue_projected_handle("decoded_qp", RDMA_RESOURCE_QP, 0);
    ext = rdma_sqe_rc_ext::type_id::create("decoded_rc_ext");
    x.transport_ext = ext;
    `define RCGET(S,T) v='0; s=get(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return s; T=v;
    `RCGET(XTR_V1_SQ_WQE_QPN,x.qpn) `RCGET(XTR_V1_SQ_WQE_ICOS,x.icos)
    `RCGET(XTR_V1_SQ_WQE_QP_SN,x.qp_sn) `RCGET(XTR_V1_SQ_WQE_OPCODE,x.hw_opcode)
    `RCGET(XTR_V1_SQ_WQE_DST_PORT,x.dst_port) `RCGET(XTR_V1_SQ_WQE_INDEX,x.index)
    `RCGET(XTR_V1_SQ_WQE_WRAP,x.wrap) `RCGET(XTR_V1_SQ_WQE_SIGN_EN,x.sign_en)
    `RCGET(XTR_V1_SQ_WQE_SE,x.se) `RCGET(XTR_V1_SQ_WQE_FENCE,x.fence)
    `RCGET(XTR_V1_SQ_WQE_CE,x.ce) `RCGET(XTR_V1_SQ_WQE_VALID,x.valid)
    `RCGET(XTR_V1_SQ_WQE_SIGNATURE,x.signature) `RCGET(XTR_V1_SQ_WQE_RC_SGE_NUM,x.sge_num)
    `RCGET(XTR_V1_SQ_WQE_RC_TOTAL_PAYLOAD_LEN,x.total_payload_len)
    `RCGET(XTR_V1_SQ_WQE_RC_IMMEDIATE,x.immediate_data)
    `RCGET(XTR_V1_SQ_WQE_RC_REMOTE_KEY,x.rkey)
    `RCGET(XTR_V1_SQ_WQE_RC_REMOTE_VA,x.remote_va.value) `undef RCGET
    x.sign_en = 1'b1;
    x.signaled = x.ce != 0;
    x.solicited = x.se;
    count = x.sge_num;
    if (x.hw_opcode == XTR_V1_SQ_OPCODE_LOCAL_INV) begin
      x.opcode = RDMA_WR_LOCAL_INVALIDATE;
      x.payload_mode = RDMA_SQ_PAYLOAD_NONE;
      s = get(b, XTR_V1_SQ_WQE_LOCAL_INVLD_STAG_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_LOCAL_INVLD_STAG_LSB,
              XTR_V1_SQ_WQE_LOCAL_INVLD_STAG_WIDTH, v);
      if (!s.ok()) return s; x.invalidate_key = v;
      ext.rkey = x.invalidate_key;
      ext.rkey_valid = 1'b1;
    end else if (x.hw_opcode == XTR_V1_SQ_OPCODE_ATOMIC_CMP_AND_SWP ||
                 x.hw_opcode == XTR_V1_SQ_OPCODE_ATOMIC_FETCH_AND_ADD) begin
      x.opcode = x.hw_opcode == XTR_V1_SQ_OPCODE_ATOMIC_CMP_AND_SWP ?
                 RDMA_WR_ATOMIC_CMP_SWAP : RDMA_WR_ATOMIC_FETCH_ADD;
      x.payload_mode = RDMA_SQ_PAYLOAD_ATOMIC_FIXED;
      s = get(b, XTR_V1_SQ_WQE_ATOMIC_L_VA_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_ATOMIC_L_VA_LSB,
              XTR_V1_SQ_WQE_ATOMIC_L_VA_WIDTH, v); if(!s.ok()) return s;
      x.atomic_local_iova.value = v;
      s = get(b, XTR_V1_SQ_WQE_ATOMIC_L_KEY_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_ATOMIC_L_KEY_LSB,
              XTR_V1_SQ_WQE_ATOMIC_L_KEY_WIDTH, v); if(!s.ok()) return s;
      x.atomic_local_lkey = v;
      begin
        rdma_sge local_sge;
        local_sge = rdma_sge::type_id::create("decoded_atomic_sge");
        local_sge.length = 8;
        local_sge.lkey = x.atomic_local_lkey;
        local_sge.iova.value = x.atomic_local_iova.value;
        x.sges.push_back(local_sge);
      end
      s = get(b, XTR_V1_SQ_WQE_ATOMIC_FAA_ADD_DATA_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_ATOMIC_FAA_ADD_DATA_LSB,
              XTR_V1_SQ_WQE_ATOMIC_FAA_ADD_DATA_WIDTH, v); if(!s.ok()) return s;
      x.atomic_value = v;
      s = get(b, XTR_V1_SQ_WQE_ATOMIC_CAS_CMP_DATA_WORD_BYTE_OFFSET,
              XTR_V1_SQ_WQE_ATOMIC_CAS_CMP_DATA_LSB,
              XTR_V1_SQ_WQE_ATOMIC_CAS_CMP_DATA_WIDTH, v); if(!s.ok()) return s;
      x.atomic_compare = v;
      ext.remote_access_valid = 1'b1;
      ext.rkey_valid = 1'b1;
      ext.remote_addr = x.remote_va;
      ext.rkey = x.rkey;
    end else begin
      case (x.hw_opcode)
        XTR_V1_SQ_OPCODE_SEND: x.opcode = RDMA_WR_SEND;
        XTR_V1_SQ_OPCODE_SEND_WITH_IMM: x.opcode = RDMA_WR_SEND_WITH_IMM;
        XTR_V1_SQ_OPCODE_WRITE: x.opcode = RDMA_WR_RDMA_WRITE;
        XTR_V1_SQ_OPCODE_WRITE_WITH_IMM: x.opcode = RDMA_WR_WRITE_WITH_IMM;
        XTR_V1_SQ_OPCODE_READ: x.opcode = RDMA_WR_RDMA_READ;
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
        s = get(b, XTR_V1_SQ_WQE_SGB_PA_WORD_BYTE_OFFSET,
                XTR_V1_SQ_WQE_SGB_PA_LSB,
                XTR_V1_SQ_WQE_SGB_PA_WIDTH, v);
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

class rdma_xtr_v1_sqe_ud_codec extends rdma_xtr_v1_sqe_codec_base; `uvm_object_utils(rdma_xtr_v1_sqe_ud_codec) function new(string name="rdma_xtr_v1_sqe_ud_codec"); super.new(name); endfunction endclass

class rdma_xtr_v1_sqe_urc_codec extends rdma_xtr_v1_sqe_codec_base; `uvm_object_utils(rdma_xtr_v1_sqe_urc_codec) function new(string name="rdma_xtr_v1_sqe_urc_codec"); super.new(name); endfunction endclass

class rdma_xtr_v1_rqe_codec extends rdma_xtr_v1_queue_codec_base;
  `uvm_object_utils(rdma_xtr_v1_rqe_codec)

  function new(string name="rdma_xtr_v1_rqe_codec"); super.new(name); endfunction
  protected function rdma_status image_check(rdma_xtr_v1_qword_builder b); bit [63:0] w[]; b.get_words(w); if ((w[0]&~64'h80ff_ff0f_ffff_ffff)!=0 || w[1][63:32]!==0 || w[2]&~64'hff00_0000_0000_0000!==0 || w[3]!==0 || w[4]!==0 || w[5]!==0 || w[6]!==0 || w[7]!==0) return err("RQE reserved bits are nonzero"); return rdma_status::success(); endfunction
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_RQE; endfunction protected virtual function int unsigned image_bytes(); return XTR_V1_RQE_BYTES; endfunction protected virtual function rdma_status check_reserved(rdma_xtr_v1_qword_builder b); return image_check(b); endfunction
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_xtr_v1_qword_builder b); rdma_xtr_v1_rqe_model x; rdma_status s; if(!$cast(x,model)) return err("RQE model type mismatch"); s=x.validate(); if(!s.ok()) return s; `define RQPUT(S,V) s=b.put_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return err(s.message);
    `RQPUT(XTR_V1_RQE_QPN,x.qpn) `RQPUT(XTR_V1_RQE_QP_SN,x.qp_sn) `RQPUT(XTR_V1_RQE_OPCODE,x.hw_opcode) `RQPUT(XTR_V1_RQE_INDEX,x.index) `RQPUT(XTR_V1_RQE_WRAP,x.wrap) `RQPUT(XTR_V1_RQE_VALID,x.valid) `RQPUT(XTR_V1_RQE_PAYLOAD_LEN,x.payload_len) `RQPUT(XTR_V1_RQE_SIGNATURE,x.signature) `RQPUT(XTR_V1_RQE_SGE_NUM,x.sge_num) `undef RQPUT return rdma_status::success(); endfunction
  protected virtual function rdma_status decode_fields(rdma_xtr_v1_qword_builder b, output rdma_hw_model model); rdma_xtr_v1_rqe_model x; bit [63:0] v; rdma_status s; x=rdma_xtr_v1_rqe_model::type_id::create("decoded_rqe"); x.target_h=rdma_xtr_v1_queue_projected_handle("decoded_qp",RDMA_RESOURCE_QP,0); `define RQGET(S,T) v='0; s=b.get_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return err(s.message); T=v;
    `RQGET(XTR_V1_RQE_QPN,x.qpn) `RQGET(XTR_V1_RQE_QP_SN,x.qp_sn) `RQGET(XTR_V1_RQE_OPCODE,x.hw_opcode) `RQGET(XTR_V1_RQE_INDEX,x.index) `RQGET(XTR_V1_RQE_WRAP,x.wrap) `RQGET(XTR_V1_RQE_VALID,x.valid) `RQGET(XTR_V1_RQE_PAYLOAD_LEN,x.payload_len) `RQGET(XTR_V1_RQE_SIGNATURE,x.signature) `RQGET(XTR_V1_RQE_SGE_NUM,x.sge_num) `undef RQGET model=x; return rdma_status::success(); endfunction
endclass

class rdma_xtr_v1_cqe_codec extends rdma_xtr_v1_queue_codec_base;
  `uvm_object_utils(rdma_xtr_v1_cqe_codec)

  function new(string name="rdma_xtr_v1_cqe_codec"); super.new(name); endfunction
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_CQE; endfunction protected virtual function int unsigned image_bytes(); return XTR_V1_CQE_BYTES; endfunction
  protected virtual function rdma_status check_reserved(rdma_xtr_v1_qword_builder b); bit [63:0] w[]; b.get_words(w); if ((w[0]&~64'h88ff_ffff_ff03_ffff)!=0 || w[3]!==0 || w[4]!==0 || w[5]!==0 || w[6]!==0 || w[7]!==0) return err("CQE reserved bits are nonzero"); return rdma_status::success(); endfunction
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_xtr_v1_qword_builder b); rdma_xtr_v1_cqe_model x; rdma_status s; if(!$cast(x,model)) return err("CQE model type mismatch"); s=x.validate(); if(!s.ok()) return s; `define CQPUT(S,V) s=b.put_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return err(s.message);
    `CQPUT(XTR_V1_CQE_POLARITY,x.polarity) `CQPUT(XTR_V1_CQE_RQ_CQE,x.rq_cqe) `CQPUT(XTR_V1_CQE_WQE_WRAP,x.wqe_wrap) `CQPUT(XTR_V1_CQE_WQE_INDEX,x.wqe_index) `CQPUT(XTR_V1_CQE_PKT_OPCODE,x.packet_opcode) `CQPUT(XTR_V1_CQE_ECODE,x.ecode) `CQPUT(XTR_V1_CQE_QPN,x.qpn) `CQPUT(XTR_V1_CQE_IMMDT_DATA,x.immediate_data) `CQPUT(XTR_V1_CQE_PAYLOAD_LEN,x.payload_len) `CQPUT(XTR_V1_CQE_SIGNATURE,x.signature) `undef CQPUT return rdma_status::success(); endfunction
  protected virtual function rdma_status decode_fields(rdma_xtr_v1_qword_builder b, output rdma_hw_model model); rdma_xtr_v1_cqe_model x; bit [63:0] v; rdma_status s; x=rdma_xtr_v1_cqe_model::type_id::create("decoded_cqe"); x.qp_h=rdma_xtr_v1_queue_projected_handle("decoded_qp",RDMA_RESOURCE_QP,0); `define CQGET(S,T) v='0; s=b.get_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return err(s.message); T=v;
    `CQGET(XTR_V1_CQE_POLARITY,x.polarity) `CQGET(XTR_V1_CQE_RQ_CQE,x.rq_cqe) `CQGET(XTR_V1_CQE_WQE_WRAP,x.wqe_wrap) `CQGET(XTR_V1_CQE_WQE_INDEX,x.wqe_index) `CQGET(XTR_V1_CQE_PKT_OPCODE,x.packet_opcode) `CQGET(XTR_V1_CQE_ECODE,x.ecode) `CQGET(XTR_V1_CQE_QPN,x.qpn) `CQGET(XTR_V1_CQE_IMMDT_DATA,x.immediate_data) `CQGET(XTR_V1_CQE_PAYLOAD_LEN,x.payload_len) `CQGET(XTR_V1_CQE_SIGNATURE,x.signature) `undef CQGET x.status=rdma_status::type_id::create("decoded_status"); model=x; return rdma_status::success(); endfunction
endclass

class rdma_xtr_v1_ceqe_codec extends rdma_xtr_v1_queue_codec_base;
  `uvm_object_utils(rdma_xtr_v1_ceqe_codec)

  function new(string name="rdma_xtr_v1_ceqe_codec"); super.new(name); endfunction
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_CEQE; endfunction protected virtual function int unsigned image_bytes(); return XTR_V1_CEQE_BYTES; endfunction
  protected virtual function rdma_status check_reserved(rdma_xtr_v1_qword_builder b); bit [63:0] w[]; b.get_words(w); if ((w[0]&~64'h9fff_ff1f_ffff_ffff)!=0 || (w[1]&~64'h0000_0000_0080_ffff)!=0) return err("CEQE reserved bits are nonzero"); return rdma_status::success(); endfunction
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_xtr_v1_qword_builder b); rdma_xtr_v1_ceqe_model x; rdma_status s; if(!$cast(x,model)) return err("CEQE model type mismatch"); s=x.validate(); if(!s.ok()) return s; `define EQPUT(S,V) s=b.put_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return err(s.message);
    `EQPUT(XTR_V1_CEQE_VALID,x.valid) `EQPUT(XTR_V1_CEQE_QPN,x.qpn) `EQPUT(XTR_V1_CEQE_CQN,x.cqn) `EQPUT(XTR_V1_CEQE_ECODE,x.ecode) `EQPUT(XTR_V1_CEQE_PKT_OPCODE,x.packet_opcode) `EQPUT(XTR_V1_CEQE_CQ_PI_WRAP,x.cq_pi_wrap) `EQPUT(XTR_V1_CEQE_CQ_PI,x.cq_pi) `undef EQPUT return rdma_status::success(); endfunction
  protected virtual function rdma_status decode_fields(rdma_xtr_v1_qword_builder b, output rdma_hw_model model); rdma_xtr_v1_ceqe_model x; bit [63:0] v; rdma_status s; x=rdma_xtr_v1_ceqe_model::type_id::create("decoded_ceqe"); x.cq_h=rdma_xtr_v1_queue_projected_handle("decoded_cq",RDMA_RESOURCE_CQ,0); `define EQGET(S,T) v='0; s=b.get_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return err(s.message); T=v;
    `EQGET(XTR_V1_CEQE_VALID,x.valid) `EQGET(XTR_V1_CEQE_QPN,x.qpn) `EQGET(XTR_V1_CEQE_CQN,x.cqn) `EQGET(XTR_V1_CEQE_ECODE,x.ecode) `EQGET(XTR_V1_CEQE_PKT_OPCODE,x.packet_opcode) `EQGET(XTR_V1_CEQE_CQ_PI_WRAP,x.cq_pi_wrap) `EQGET(XTR_V1_CEQE_CQ_PI,x.cq_pi) `undef EQGET model=x; return rdma_status::success(); endfunction
endclass

class rdma_xtr_v1_aeqe_codec extends rdma_xtr_v1_queue_codec_base;
  `uvm_object_utils(rdma_xtr_v1_aeqe_codec)

  function new(string name="rdma_xtr_v1_aeqe_codec"); super.new(name); endfunction
  protected virtual function rdma_image_kind_e image_kind_expected(); return RDMA_IMAGE_AEQE; endfunction protected virtual function int unsigned image_bytes(); return XTR_V1_AEQE_BYTES; endfunction
  protected virtual function rdma_status check_reserved(rdma_xtr_v1_qword_builder b); bit [63:0] w[]; b.get_words(w); if ((w[0]&~64'hf000_00ff_ff03_ffff)!=0 || (w[1]&~64'h00ff_ffff_0000_0000)!=0) return err("AEQE reserved bits are nonzero"); return rdma_status::success(); endfunction
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_xtr_v1_qword_builder b); rdma_xtr_v1_aeqe_model x; rdma_status s; if(!$cast(x,model)) return err("AEQE model type mismatch"); s=x.validate(); if(!s.ok()) return s; `define EQPUT2(S,V) s=b.put_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return err(s.message);
    `EQPUT2(XTR_V1_AEQE_VALID,x.valid) `EQPUT2(XTR_V1_AEQE_QP_ST,x.qp_state) `EQPUT2(XTR_V1_AEQE_PKT_OPCODE,x.packet_opcode) `EQPUT2(XTR_V1_AEQE_ECODE,x.ecode) `EQPUT2(XTR_V1_AEQE_QPN,x.qpn) `EQPUT2(XTR_V1_AEQE_WQE_WRAP,x.wqe_wrap) `EQPUT2(XTR_V1_AEQE_WQE_INDEX,x.wqe_index) `undef EQPUT2 return rdma_status::success(); endfunction
  protected virtual function rdma_status decode_fields(rdma_xtr_v1_qword_builder b, output rdma_hw_model model); rdma_xtr_v1_aeqe_model x; bit [63:0] v; rdma_status s; x=rdma_xtr_v1_aeqe_model::type_id::create("decoded_aeqe"); x.target_h=rdma_xtr_v1_queue_projected_handle("decoded_qp",RDMA_RESOURCE_QP,0); `define EQGET2(S,T) v='0; s=b.get_field(S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return err(s.message); T=v;
    `EQGET2(XTR_V1_AEQE_VALID,x.valid) `EQGET2(XTR_V1_AEQE_QP_ST,x.qp_state) `EQGET2(XTR_V1_AEQE_PKT_OPCODE,x.packet_opcode) `EQGET2(XTR_V1_AEQE_ECODE,x.ecode) `EQGET2(XTR_V1_AEQE_QPN,x.qpn) `EQGET2(XTR_V1_AEQE_WQE_WRAP,x.wqe_wrap) `EQGET2(XTR_V1_AEQE_WQE_INDEX,x.wqe_index) `undef EQGET2 model=x; return rdma_status::success(); endfunction
endclass

function automatic rdma_status rdma_xtr_v1_register_queue_codecs(rdma_codec_registry registry);
  rdma_codec_key k; rdma_status s; if(registry==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue codec registry is null"); k.hw_version="xtr_v1"; k.opcode=0;
  k.image_kind=RDMA_IMAGE_SQE; k.object_type="sqe"; k.variant="rc"; s=registry.register_codec(k,rdma_xtr_v1_sqe_rc_codec::type_id::create("sqe_rc")); if(!s.ok()) return s; k.variant="ud"; s=registry.register_codec(k,rdma_xtr_v1_sqe_ud_codec::type_id::create("sqe_ud")); if(!s.ok()) return s; k.variant="urc"; s=registry.register_codec(k,rdma_xtr_v1_sqe_urc_codec::type_id::create("sqe_urc")); if(!s.ok()) return s;
  k.image_kind=RDMA_IMAGE_RQE; k.object_type="rqe"; k.variant="default"; s=registry.register_codec(k,rdma_xtr_v1_rqe_codec::type_id::create("rqe")); if(!s.ok()) return s; k.image_kind=RDMA_IMAGE_CQE; k.object_type="cqe"; s=registry.register_codec(k,rdma_xtr_v1_cqe_codec::type_id::create("cqe")); if(!s.ok()) return s; k.image_kind=RDMA_IMAGE_CEQE; k.object_type="ceqe"; s=registry.register_codec(k,rdma_xtr_v1_ceqe_codec::type_id::create("ceqe")); if(!s.ok()) return s; k.image_kind=RDMA_IMAGE_AEQE; k.object_type="aeqe"; return registry.register_codec(k,rdma_xtr_v1_aeqe_codec::type_id::create("aeqe"));
endfunction
