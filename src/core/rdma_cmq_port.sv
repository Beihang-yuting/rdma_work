// 中文说明：rdma_cmq_port.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_cmq_port extends uvm_object;

  function new(string name = "rdma_cmq_port");
    super.new(name);
  endfunction

  pure virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );

  pure virtual task reconcile(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );

  // A missing ticket/completion is not proof that a command was rejected
  // before submission.  An adapter may override this observation when it can
  // prove that the most recent execute() failed in its own pre-submit
  // validation path.  The conservative default is fail-closed.
  virtual function bit last_execute_definitive_no_submit();
    return 1'b0;
  endfunction
endclass
