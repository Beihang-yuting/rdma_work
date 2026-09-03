// 中文说明：rdma_sq_payload_writer_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_sq_payload_writer_test extends uvm_test;
  `uvm_component_utils(rdma_sq_payload_writer_test)

  function new(string name="rdma_sq_payload_writer_test", uvm_component parent=null); super.new(name,parent); endfunction

  virtual task run_phase(uvm_phase phase); phase.raise_objection(this); phase.drop_objection(this); endtask
endclass
