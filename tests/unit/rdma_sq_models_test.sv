// 中文说明：rdma_sq_models_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_sq_models_test extends uvm_test;
  `uvm_component_utils(rdma_sq_models_test)

  function new(string name = "rdma_sq_models_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    longint unsigned logical_bytes, storage_bytes;
    rdma_status s; rdma_address_vector av, av_copy; uvm_object cloned;
    phase.raise_objection(this);
    if (!rdma_qp_needs_sq_sgb(RDMA_TRANSPORT_UD, 1, 1))
      `uvm_error("SQ_CAP", "UD did not require SQ SGB")
    if (!rdma_qp_needs_sq_sgb(RDMA_TRANSPORT_RC, 3, 1) ||
        rdma_qp_needs_sq_sgb(RDMA_TRANSPORT_RC, 2, 2) ||
        rdma_qp_needs_sq_sgb(RDMA_TRANSPORT_URC, 32, 32))
      `uvm_error("SQ_CAP", "RC/URC SQ SGB thresholds are incorrect")
    s = rdma_qp_sq_sgb_geometry(16, logical_bytes, storage_bytes);
    if (s == null || !s.ok() || logical_bytes != 8192 || storage_bytes != 8192)
      `uvm_error("SQ_GEOMETRY", "16-slot SQ SGB geometry is incorrect")
    av = rdma_address_vector::type_id::create("av");
    av.\priority = 3; av.multicast = 1; av.forwarding_mode = 2;
    cloned = av.clone();
    if (cloned == null || !$cast(av_copy, cloned) || av_copy == av ||
        av_copy.\priority != 3 || !av_copy.multicast ||
        av_copy.forwarding_mode != 2)
      `uvm_error("SQ_AV", "AV clone lost detached UD WQE fields")
    phase.drop_objection(this);
  endtask
endclass
