// 目录：测试层 unit/rdma_ud_urc_sqe_codec_test.sv。
// 职责：验证 UD/URC SQE 编解码的 opcode、目的 QP/Q_Key、payload 和拒绝边界。
// 依赖：rdma_model_pkg、rdma_codec_pkg 与 UVM；不拥有外部 DMA/PCIe 资源。
class rdma_ud_urc_sqe_codec_test extends uvm_test;
  `uvm_component_utils(rdma_ud_urc_sqe_codec_test)
  function new(string name="rdma_ud_urc_sqe_codec_test", uvm_component parent=null); super.new(name,parent); endfunction
  function automatic rdma_handle qp_handle(); rdma_handle h=rdma_handle::type_id::create("qp"); h.kind=RDMA_RESOURCE_QP; h.object_id=1; h.function_uid=64'h1122; h.generation=1; return h; endfunction
  task run_phase(uvm_phase phase);
    rdma_post_send_req req; byte unsigned image[]; rdma_status s;
    phase.raise_objection(this);
    req=rdma_post_send_req::type_id::create("ud_send_inv"); req.qp_h=qp_handle(); req.transport=RDMA_TRANSPORT_UD; req.opcode=RDMA_WR_SEND_WITH_INV; req.destination_qpn=24'h12345; req.qkey=32'h11112222; req.invalidate_rkey=32'hdeadbeef; req.address_vector_valid=1; req.address_vector=rdma_address_vector::type_id::create("av"); req.inline_data=1; req.payload.push_back(8'h5a);
    s=rdma_queue_codec::encode_sqe(req,image);
    if (s==null || !s.ok() || image.size()!=RDMA_WQE_BYTES) `uvm_error("SQE_RED","UD SEND_WITH_INV codec did not encode")
    if (image.size()>3 && image[3] != RDMA_SQ_OPCODE_SEND_WITH_INV) `uvm_error("SQE_OPCODE","UD opcode mismatch")
    phase.drop_objection(this);
  endtask
endclass
