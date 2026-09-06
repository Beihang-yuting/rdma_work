// 目录：测试层 unit/rdma_wqe_extended_opcode_test.sv。
// 职责：验证扩展 WQE typed authority 字段与非法传输组合拒绝。
// 依赖：rdma_model_pkg、rdma_codec_pkg 与 UVM；测试对象只拥有本地句柄快照。
class rdma_wqe_extended_opcode_test extends uvm_test;
  `uvm_component_utils(rdma_wqe_extended_opcode_test)
  // 功能：构造扩展 opcode focused 测试组件。
  // 输入/输出及副作用：name、parent 为输入；建立 UVM 测试节点，不拥有 DUT 资源。
  // 失败/边界：构造不执行测试；依赖缺失由 run_phase 报告。
  function new(string name="rdma_wqe_extended_opcode_test", uvm_component parent=null); super.new(name,parent); endfunction
  // 功能：创建指定 kind 的 authority 测试句柄。
  // 输入/输出及副作用：k 为输入；返回带 Function UID/generation 的本地句柄快照。
  // 失败/边界：句柄不登记资源管理器，仅用于语义 authority 分支。
  function automatic rdma_handle h(rdma_resource_kind_e k); rdma_handle x=rdma_handle::type_id::create("h"); x.kind=k; x.object_id=2; x.function_uid=64'h1122; x.generation=1; return x; endfunction
  // 功能：运行扩展 opcode authority 与 URC profile 边界断言。
  // 输入/输出及副作用：phase 为 UVM 阶段输入；产生错误报告，不修改外部资源。
  // 失败/边界：非法 authority 未拒绝或无 profile 未返回 UNSUPPORTED 时报告 UVM error。
  task run_phase(uvm_phase phase);
    rdma_post_send_req req; rdma_status s; byte unsigned image[];
    phase.raise_objection(this);
    req=rdma_post_send_req::type_id::create("bad_ud_rc"); req.qp_h=h(RDMA_RESOURCE_QP); req.transport=RDMA_TRANSPORT_UD; req.opcode=RDMA_WR_RDMA_WRITE; req.remote_access_valid=1; req.rkey_valid=1; req.inline_data=1; req.payload.push_back(8'h1);
    s=req.validate(); if (s==null || s.ok()) `uvm_error("EXT_REJECT","UD accepted RC-only fields")
    // 复用请求对象切换到 UD 时清除上一个 RC 操作遗留的远端 authority。
    req.opcode=RDMA_WR_SEND_WITH_INV; req.destination_qpn=1; req.qkey=1; req.address_vector_valid=1; req.address_vector=rdma_address_vector::type_id::create("av"); req.invalidate_rkey=32'h1234; req.remote_access_valid=0; req.rkey_valid=0; req.sgb_iova.value=64'h2000; req.payload.delete(); req.payload.push_back(8'h2);
    s=rdma_queue_codec::encode_sqe(req,image); if (s==null || !s.ok()) `uvm_error("EXT_ENCODE",$sformatf("typed SEND_WITH_INV rejected: %s", s == null ? "null status" : s.message))
    req.transport=RDMA_TRANSPORT_URC; req.completion_qp_h=h(RDMA_RESOURCE_QP); req.destination_qpn=7;
    req.opcode=RDMA_WR_SEND; req.inline_data=0; req.payload.delete(); req.sges.delete();
    begin
      rdma_sge sg; sg=rdma_sge::type_id::create("urc_sge"); sg.length=8; sg.lkey=32'h77; sg.iova.value=64'h4000; req.sges.push_back(sg);
    end
    s=rdma_queue_codec::encode_sqe(req,image);
    if (s==null || !s.ok())
      `uvm_error("URC_PROFILE",$sformatf("URC SEND codec rejected valid completion-QP profile: %s", s == null ? "null status" : s.message))
    // RoCEv2 的 UC/URC wire profile 没有 RDMA READ opcode；语义入口必须
    // 在队列写入前 fail-closed，不能把请求伪装成 RC READ。
    req.opcode=RDMA_WR_RDMA_READ; req.remote_access_valid=1; req.rkey_valid=1;
    req.remote_addr.value=64'h5000; req.rkey=32'h99;
    s=req.validate();
    if (s==null || s.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("URC_READ_PROFILE",$sformatf("URC READ was not rejected explicitly: %s", s == null ? "null status" : s.convert2string()))
    req.opcode=RDMA_WR_SEND;
    req.completion_qp_h=null; s=req.validate(); if (s==null || s.ok()) `uvm_error("URC_AUTH","URC accepted missing completion QP")
    // 当前 64B SQE profile 没有驱动 REG_MR/BIND_MW/FLUSH 的固定 body；
    // 语义层仍校验 authority，codec 必须显式返回 UNSUPPORTED，而不能
    // 静默生成一个可能被硬件误解释的普通 SEND WQE。
    req=rdma_post_send_req::type_id::create("reg_mr_boundary");
    req.qp_h=h(RDMA_RESOURCE_QP); req.transport=RDMA_TRANSPORT_RC;
    req.opcode=RDMA_WR_REG_MR; req.mr_h=h(RDMA_RESOURCE_MR);
    s=rdma_queue_codec::encode_sqe(req,image);
    if (s==null || s.code != RDMA_SC_UNSUPPORTED_OPCODE)
      `uvm_error("REG_MR_PROFILE","REG_MR unsupported boundary was not explicit")
    req=rdma_post_send_req::type_id::create("bind_mw_boundary");
    req.qp_h=h(RDMA_RESOURCE_QP); req.transport=RDMA_TRANSPORT_RC;
    req.opcode=RDMA_WR_BIND_MW; req.mr_h=h(RDMA_RESOURCE_MR);
    req.mw_h=h(RDMA_RESOURCE_MW);
    s=rdma_queue_codec::encode_sqe(req,image);
    if (s==null || s.code != RDMA_SC_UNSUPPORTED_OPCODE)
      `uvm_error("BIND_MW_PROFILE","BIND_MW unsupported boundary was not explicit")
    req=rdma_post_send_req::type_id::create("flush_boundary");
    req.qp_h=h(RDMA_RESOURCE_QP); req.transport=RDMA_TRANSPORT_RC;
    req.opcode=RDMA_WR_FLUSH; req.authority_h=h(RDMA_RESOURCE_QP);
    req.authority_h.object_id=req.qp_h.object_id;
    s=rdma_queue_codec::encode_sqe(req,image);
    if (s==null || s.code != RDMA_SC_UNSUPPORTED_OPCODE)
      `uvm_error("FLUSH_PROFILE","FLUSH unsupported boundary was not explicit")
    phase.drop_objection(this);
  endtask
endclass
