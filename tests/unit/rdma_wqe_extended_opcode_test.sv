// 目录：测试层 unit/rdma_wqe_extended_opcode_test.sv。
// 职责：验证扩展 WQE typed authority 字段与非法传输组合拒绝。
// 依赖：rdma_model_pkg、rdma_codec_pkg 与 UVM；测试对象只拥有本地句柄快照。
class rdma_wqe_extended_opcode_test extends uvm_test;
  `uvm_component_utils(rdma_wqe_extended_opcode_test)
  function new(string name="rdma_wqe_extended_opcode_test", uvm_component parent=null); super.new(name,parent); endfunction
  function automatic rdma_handle h(rdma_resource_kind_e k); rdma_handle x=rdma_handle::type_id::create("h"); x.kind=k; x.object_id=2; x.function_uid=64'h1122; x.generation=1; return x; endfunction
  task run_phase(uvm_phase phase);
    rdma_post_send_req req; rdma_status s; byte unsigned image[];
    phase.raise_objection(this);
    req=rdma_post_send_req::type_id::create("bad_ud_rc"); req.qp_h=h(RDMA_RESOURCE_QP); req.transport=RDMA_TRANSPORT_UD; req.opcode=RDMA_WR_RDMA_WRITE; req.remote_access_valid=1; req.rkey_valid=1; req.inline_data=1; req.payload.push_back(8'h1);
    s=req.validate(); if (s==null || s.ok()) `uvm_error("EXT_REJECT","UD accepted RC-only fields")
    req.opcode=RDMA_WR_SEND_WITH_INV; req.destination_qpn=1; req.qkey=1; req.address_vector_valid=1; req.address_vector=rdma_address_vector::type_id::create("av"); req.invalidate_rkey=32'h1234; req.payload.delete(); req.payload.push_back(8'h2);
    s=rdma_queue_codec::encode_sqe(req,image); if (s==null || !s.ok()) `uvm_error("EXT_ENCODE","typed SEND_WITH_INV rejected")
    req.transport=RDMA_TRANSPORT_URC; req.completion_qp_h=h(RDMA_RESOURCE_QP); req.destination_qpn=7;
    s=rdma_queue_codec::encode_sqe(req,image);
    if (s==null || s.ok() || s.code != RDMA_SC_UNSUPPORTED_OPCODE)
      `uvm_error("URC_PROFILE","URC missing completion-QP profile was not explicit")
    req.completion_qp_h=null; s=req.validate(); if (s==null || s.ok()) `uvm_error("URC_AUTH","URC accepted missing completion QP")
    phase.drop_objection(this);
  endtask
endclass
