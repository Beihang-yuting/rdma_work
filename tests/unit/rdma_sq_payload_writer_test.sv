// 中文说明：rdma_sq_payload_writer_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_sq_payload_writer_test extends uvm_test;
  `uvm_component_utils(rdma_sq_payload_writer_test)

  function new(string name="rdma_sq_payload_writer_test", uvm_component parent=null); super.new(name,parent); endfunction

  virtual task run_phase(uvm_phase phase);
    rdma_host_mem_sq_payload_writer w; rdma_mock_host_mem m; rdma_sq_payload_write_receipt r; rdma_sge s; rdma_status st; rdma_sge ss[$]; byte unsigned p[$]; longint unsigned id;
    phase.raise_objection(this);
    w=rdma_host_mem_sq_payload_writer::type_id::create("w"); m=rdma_mock_host_mem::type_id::create("m");
    st=w.configure(m,null,0); if(st.ok()) `uvm_error("CFG","null binding accepted")
    s=rdma_sge::type_id::create("s"); s.length=4; ss.push_back(s); p='{1,2};
    st=w.stage_and_verify(null,ss,p,r); if(st.ok() || r!=null) `uvm_error("PREFLIGHT","invalid request accepted or receipt allocated")
    st=w.register_mapping(null,id); if(st.ok()) `uvm_error("REG","null mapping accepted")
    phase.drop_objection(this);
  endtask
endclass
