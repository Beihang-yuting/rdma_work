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
  function new(string name="rdma_xtr_v1_sqe_model"); super.new(name); remote_va='0; endfunction
  virtual function void do_copy(uvm_object rhs);
    rdma_xtr_v1_sqe_model x; super.do_copy(rhs); if (!$cast(x,rhs)) `uvm_fatal("RDMA_COPY_TYPE","xtr SQE copy mismatch");
    qpn=x.qpn; icos=x.icos; qp_sn=x.qp_sn; dst_port=x.dst_port; index=x.index; wrap=x.wrap; sign_en=x.sign_en; se=x.se; fence=x.fence; ce=x.ce; valid=x.valid; signature=x.signature; sge_num=x.sge_num; hw_opcode=x.hw_opcode; rkey=x.rkey; remote_va=x.remote_va;
  endfunction
  virtual function rdma_status validate();
    if (qp_h==null || qp_h.kind!=RDMA_RESOURCE_QP) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE requires QP handle");
    if (qpn > 21'h7ffff || icos > 3'd7 || index > 15'h7fff) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE field width overflow");
    if (transport_ext==null || transport_ext.transport_kind()!=transport) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"SQE transport extension mismatch");
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
  virtual function rdma_status validate_model(rdma_hw_model model); if (model==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue model is null"); return rdma_status::success(); endfunction
  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_xtr_v1_qword_builder b; byte unsigned p[]; rdma_status s;
    if (image==null) return err("queue image is null");
    if (image.length!=image_bytes() || image.bytes.size()!=image_bytes() || image.alignment!=image_bytes() || image.endian!=RDMA_ENDIAN_BIG || image.image_kind!=image_kind_expected() || image.hardware_version!=XTR_V1_HW_VERSION || image.write_target_kind!=RDMA_HW_TARGET_NONE || image.backing_target.value!=0 || image.hmc_target.value!=0 || image.bar_target.value!=0) return err("queue image metadata is invalid");
    p=new[image_bytes()]; foreach (p[i]) p[i]=image.bytes[i]; b=new("queue_validate"); s=b.deserialize(p); if (!s.ok()) return err(s.message); return check_reserved(b);
  endfunction
  virtual function rdma_byte_endian_e hardware_endian(); return RDMA_ENDIAN_BIG; endfunction
  virtual function string describe_fields(); return $sformatf("xtr_v1 %0d-byte queue image",image_bytes()); endfunction
  virtual function rdma_status encode(rdma_hw_model model, output rdma_hw_image image);
    rdma_xtr_v1_qword_builder b; byte unsigned p[]; rdma_hw_image c; rdma_status s; image=null;
    s=validate_model(model); if (!s.ok()) return s; b=new("queue_encode"); s=b.reset(image_bytes()); if (!s.ok()) return err(s.message); s=encode_fields(model,b); if (!s.ok()) return s; s=check_reserved(b); if (!s.ok()) return s; p=new[0]; s=b.serialize(p); if (!s.ok()) return err(s.message); c=rdma_hw_image::type_id::create("queue_image"); foreach(p[i]) c.bytes.push_back(p[i]); c.length=image_bytes(); c.alignment=image_bytes(); c.endian=RDMA_ENDIAN_BIG; c.image_kind=image_kind_expected(); c.hardware_version=XTR_V1_HW_VERSION; c.write_target_kind=RDMA_HW_TARGET_NONE; image=c; return rdma_status::success();
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
  protected function rdma_status check_reserved(rdma_xtr_v1_qword_builder b); bit [63:0] w[]; b.get_words(w); if ((w[0] & ~(64'hefff_ffff_ffff_ffff))!=0 || (w[1]!=0) || ((w[2] & ~64'hffff_0000_ffff_ffff)!=0) || (w[3]!=0) || (w[4]!=0) || (w[5]!=0) || (w[6]!=0) || (w[7]!=0)) return err("SQE reserved bits are nonzero"); return rdma_status::success(); endfunction
  protected virtual function rdma_status encode_fields(rdma_hw_model model, rdma_xtr_v1_qword_builder b); rdma_xtr_v1_sqe_model x; rdma_status s; if(!$cast(x,model)) return err("SQE model type mismatch"); s=x.validate(); if(!s.ok()) return s;
    `define SQPUT(S,V) s=put(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,V); if(!s.ok()) return s;
    `SQPUT(XTR_V1_SQ_WQE_QPN,x.qpn) `SQPUT(XTR_V1_SQ_WQE_ICOS,x.icos) `SQPUT(XTR_V1_SQ_WQE_QP_SN,x.qp_sn) `SQPUT(XTR_V1_SQ_WQE_OPCODE,x.hw_opcode) `SQPUT(XTR_V1_SQ_WQE_DST_PORT,x.dst_port) `SQPUT(XTR_V1_SQ_WQE_INDEX,x.index) `SQPUT(XTR_V1_SQ_WQE_WRAP,x.wrap) `SQPUT(XTR_V1_SQ_WQE_SIGN_EN,x.sign_en) `SQPUT(XTR_V1_SQ_WQE_SE,x.se) `SQPUT(XTR_V1_SQ_WQE_FENCE,x.fence) `SQPUT(XTR_V1_SQ_WQE_CE,x.ce) `SQPUT(XTR_V1_SQ_WQE_VALID,x.valid) `SQPUT(XTR_V1_SQ_WQE_SIGNATURE,x.signature) `SQPUT(XTR_V1_SQ_WQE_RC_SGE_NUM,x.sge_num)
    if (x.transport!=RDMA_TRANSPORT_RC) return err("XTR v1 only defines RC SQE extension fields");
    `SQPUT(XTR_V1_SQ_WQE_RC_REMOTE_KEY,x.rkey) `SQPUT(XTR_V1_SQ_WQE_RC_REMOTE_VA,x.remote_va.value) `undef SQPUT return rdma_status::success();
  endfunction
  protected virtual function rdma_status decode_fields(rdma_xtr_v1_qword_builder b, output rdma_hw_model model); rdma_xtr_v1_sqe_model x; bit [63:0] v; rdma_status s; x=rdma_xtr_v1_sqe_model::type_id::create("decoded_sqe"); x.transport=RDMA_TRANSPORT_RC; x.qp_h=rdma_xtr_v1_queue_projected_handle("decoded_qp",RDMA_RESOURCE_QP,0); `define SQGET(S,T) v='0; s=get(b,S``_WORD_BYTE_OFFSET,S``_LSB,S``_WIDTH,v); if(!s.ok()) return s; T=v;
    `SQGET(XTR_V1_SQ_WQE_QPN,x.qpn) `SQGET(XTR_V1_SQ_WQE_ICOS,x.icos) `SQGET(XTR_V1_SQ_WQE_QP_SN,x.qp_sn) `SQGET(XTR_V1_SQ_WQE_OPCODE,x.hw_opcode) `SQGET(XTR_V1_SQ_WQE_DST_PORT,x.dst_port) `SQGET(XTR_V1_SQ_WQE_INDEX,x.index) `SQGET(XTR_V1_SQ_WQE_WRAP,x.wrap) `SQGET(XTR_V1_SQ_WQE_SIGN_EN,x.sign_en) `SQGET(XTR_V1_SQ_WQE_SE,x.se) `SQGET(XTR_V1_SQ_WQE_FENCE,x.fence) `SQGET(XTR_V1_SQ_WQE_CE,x.ce) `SQGET(XTR_V1_SQ_WQE_VALID,x.valid) `SQGET(XTR_V1_SQ_WQE_SIGNATURE,x.signature) `SQGET(XTR_V1_SQ_WQE_RC_SGE_NUM,x.sge_num) `SQGET(XTR_V1_SQ_WQE_RC_REMOTE_KEY,x.rkey) `SQGET(XTR_V1_SQ_WQE_RC_REMOTE_VA,x.remote_va.value) `undef SQGET model=x; return rdma_status::success(); endfunction
endclass
class rdma_xtr_v1_sqe_rc_codec extends rdma_xtr_v1_sqe_codec_base; `uvm_object_utils(rdma_xtr_v1_sqe_rc_codec) function new(string name="rdma_xtr_v1_sqe_rc_codec"); super.new(name); endfunction endclass
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
