class rdma_xtr_v1_queue_codec_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_queue_codec_test)
  function new(string name="rdma_xtr_v1_queue_codec_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction
  function automatic rdma_handle h(string n, rdma_resource_kind_e k, int unsigned id);
    rdma_handle x=rdma_handle::type_id::create(n); x.kind=k; x.object_id=id;
    x.function_uid=64'h1122; x.generation=1; return x;
  endfunction
  function automatic void ok(string l, rdma_status s);
    if (s==null || !s.ok()) `uvm_error(l, s==null?"null":s.convert2string());
  endfunction
  function automatic void eq_bytes(string l, rdma_hw_image a, rdma_hw_image b);
    if (a==null || b==null || a.bytes.size()!=b.bytes.size()) begin `uvm_error(l,"image mismatch"); return; end
    foreach (a.bytes[i]) if (a.bytes[i]!==b.bytes[i]) `uvm_error(l,$sformatf("byte %0d",i));
  endfunction
  task run_phase(uvm_phase phase);
    rdma_codec_registry r; rdma_status s; rdma_codec_base c; rdma_hw_image im,im2; rdma_hw_model m;
    rdma_xtr_v1_sqe_model sq, sq2; rdma_xtr_v1_rqe_model rq, rq2; rdma_xtr_v1_cqe_model cq, cq2;
    rdma_sqe_rc_ext re; rdma_sge sg; byte unsigned bad[];
    phase.raise_objection(this);
    r=rdma_codec_registry::type_id::create("r"); s=rdma_xtr_v1_register_queue_codecs(r); ok("register",s);
    sq=rdma_xtr_v1_sqe_model::type_id::create("sq"); sq.transport=RDMA_TRANSPORT_RC; sq.qp_h=h("q",RDMA_RESOURCE_QP,'h15555);
    sq.hw_opcode=4'hd; sq.icos=5; sq.qp_sn=8'ha6; sq.dst_port=11; sq.index='h4567; sq.wrap=1; sq.sign_en=1; sq.se=1; sq.fence=2; sq.ce=2; sq.valid=1; sq.signature=8'hc7;
    re=rdma_sqe_rc_ext::type_id::create("re"); re.remote_access_valid=1; re.rkey_valid=1; re.rkey=32'hdeadbeef; re.remote_addr.value=64'h0123456789abcdef; sq.transport_ext=re;
    sg=rdma_sge::type_id::create("sg"); sg.iova.value=64'h1000; sg.length=8; sq.sges.push_back(sg); sq.sge_num=4;
    s=r.lookup('{hw_version:"xtr_v1",image_kind:RDMA_IMAGE_SQE,object_type:"sqe",variant:"rc",opcode:0},c); ok("lookup sq",s); s=c.encode(sq,im); ok("sq encode",s); s=c.decode(im,m); ok("sq decode",s); $cast(sq2,m); s=c.encode(sq2,im2); ok("sq reencode",s); eq_bytes("sq roundtrip",im,im2);
    rq=rdma_xtr_v1_rqe_model::type_id::create("rq"); rq.target_h=h("rq",RDMA_RESOURCE_QP,1); rq.qpn='habcde; rq.qp_sn='h5a; rq.hw_opcode=9; rq.index='h3456; rq.wrap=1; rq.valid=1; rq.payload_len='h10203040; rq.signature=8'h96; rq.sge_num=2; rq.sges.push_back(sg);
    s=r.lookup('{hw_version:"xtr_v1",image_kind:RDMA_IMAGE_RQE,object_type:"rqe",variant:"default",opcode:0},c); ok("lookup rq",s); s=c.encode(rq,im); ok("rq encode",s); s=c.decode(im,m); ok("rq decode",s);
    cq=rdma_xtr_v1_cqe_model::type_id::create("cq"); cq.qp_h=h("cq",RDMA_RESOURCE_QP,'h2aaaa); cq.qpn='h2aaaa; cq.wqe_index='h4567; cq.ecode=8'hf4; cq.payload_len='h10203040; cq.polarity=1; cq.rq_cqe=1; cq.wqe_wrap=1; cq.packet_opcode=8'h9a; cq.immediate_data=32'h89abcdef; cq.status=rdma_status::type_id::create("st");
    s=r.lookup('{hw_version:"xtr_v1",image_kind:RDMA_IMAGE_CQE,object_type:"cqe",variant:"default",opcode:0},c); ok("lookup cq",s); s=c.encode(cq,im); ok("cq encode",s); s=c.decode(im,m); ok("cq decode",s);
    bad = new[64]; foreach (bad[i]) bad[i]=0; bad[0]=8'h1; im.bytes.delete(); foreach (bad[i]) im.bytes.push_back(bad[i]); im.length=64; im.alignment=64; im.endian=RDMA_ENDIAN_BIG; im.image_kind=RDMA_IMAGE_CQE; im.hardware_version=1; s=c.validate_image(im); if (s==null || s.ok()) `uvm_error("reserved","reserved bits accepted");
    phase.drop_objection(this);
  endtask
endclass
