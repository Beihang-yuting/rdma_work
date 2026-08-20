typedef enum bit [2:0] {
  RDMA_RESOURCE_NEW        = 3'd0,
  RDMA_RESOURCE_ALLOCATED  = 3'd1,
  RDMA_RESOURCE_PROGRAMMED = 3'd2,
  RDMA_RESOURCE_ACTIVE     = 3'd3,
  RDMA_RESOURCE_QUIESCING  = 3'd4,
  RDMA_RESOURCE_RELEASED   = 3'd5,
  RDMA_RESOURCE_ERROR      = 3'd6
} rdma_resource_state_e;

function automatic rdma_handle rdma_clone_handle_value(
  rdma_handle source,
  string copy_label
);
  uvm_object cloned_object;
  rdma_handle cloned_handle;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_handle, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {copy_label, " handle clone type mismatch"})
  return cloned_handle;
endfunction

function automatic rdma_function_handle rdma_clone_function_handle_value(
  rdma_function_handle source,
  string copy_label
);
  uvm_object cloned_object;
  rdma_function_handle cloned_handle;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_handle, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {copy_label, " function handle mismatch"})
  return cloned_handle;
endfunction

function automatic bit rdma_ring_state_valid(
  int unsigned producer_index,
  bit producer_wrap,
  int unsigned consumer_index,
  bit consumer_wrap
);
  if (producer_wrap == consumer_wrap)
    return producer_index >= consumer_index;
  return producer_index <= consumer_index;
endfunction

class rdma_resource extends uvm_object;
  `uvm_object_utils(rdma_resource)

  rdma_handle handle;
  rdma_function_handle owner;
  rdma_resource_state_e state;
  rdma_dma_mapping backing_mappings[$];
  rdma_handle dependencies[$];
  longint unsigned outstanding_ids[$];
  rdma_hmc_fvm_addr_t hmc_fvm_addr;
  bit hmc_fvm_addr_valid;

  function new(string name = "rdma_resource");
    super.new(name);
    handle = null;
    owner = null;
    state = RDMA_RESOURCE_NEW;
    hmc_fvm_addr = '0;
    hmc_fvm_addr_valid = 1'b0;
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_FUNCTION;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_resource rhs_resource;
    uvm_object cloned_object;
    rdma_dma_mapping cloned_mapping;
    rdma_handle cloned_handle;

    super.do_copy(rhs);
    if (!$cast(rhs_resource, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "resource copy type mismatch")
    handle = rdma_clone_handle_value(rhs_resource.handle, "resource");
    owner = rdma_clone_function_handle_value(rhs_resource.owner, "resource");
    state = rhs_resource.state;
    hmc_fvm_addr = rhs_resource.hmc_fvm_addr;
    hmc_fvm_addr_valid = rhs_resource.hmc_fvm_addr_valid;
    backing_mappings.delete();
    foreach (rhs_resource.backing_mappings[i]) begin
      if (rhs_resource.backing_mappings[i] == null) begin
        backing_mappings.push_back(null);
      end
      else begin
        cloned_object = rhs_resource.backing_mappings[i].clone();
        if (cloned_object == null || !$cast(cloned_mapping, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "DMA mapping clone type mismatch")
        backing_mappings.push_back(cloned_mapping);
      end
    end
    dependencies.delete();
    foreach (rhs_resource.dependencies[i]) begin
      cloned_handle = rdma_clone_handle_value(rhs_resource.dependencies[i],
                                               "dependency");
      dependencies.push_back(cloned_handle);
    end
    outstanding_ids = rhs_resource.outstanding_ids;
  endfunction

  virtual function rdma_status validate();
    if (!(state inside {RDMA_RESOURCE_NEW, RDMA_RESOURCE_ALLOCATED,
                        RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE,
                        RDMA_RESOURCE_QUIESCING, RDMA_RESOURCE_RELEASED,
                        RDMA_RESOURCE_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource state is invalid");
    if (state != RDMA_RESOURCE_NEW) begin
      if (handle == null || handle.kind != resource_kind())
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "resource handle kind is invalid");
      if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "resource owner is not a function handle");
      if (!rdma_handle_matches_owner(handle, owner))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "resource handle does not match its owner");
      foreach (dependencies[i]) begin
        if (!rdma_handle_matches_owner(dependencies[i], owner))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "resource dependency does not match owner");
      end
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_resource extends rdma_resource;
  `uvm_object_utils(rdma_queue_resource)

  int unsigned depth;
  int unsigned producer_index;
  int unsigned consumer_index;
  bit producer_wrap;
  bit consumer_wrap;
  rdma_iova_t queue_iova;

  function new(string name = "rdma_queue_resource");
    super.new(name);
    depth = '0;
    producer_index = '0;
    consumer_index = '0;
    producer_wrap = 1'b0;
    consumer_wrap = 1'b0;
    queue_iova = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_resource rhs_queue;

    super.do_copy(rhs);
    if (!$cast(rhs_queue, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "queue resource copy type mismatch")
    depth = rhs_queue.depth;
    producer_index = rhs_queue.producer_index;
    consumer_index = rhs_queue.consumer_index;
    producer_wrap = rhs_queue.producer_wrap;
    consumer_wrap = rhs_queue.consumer_wrap;
    queue_iova = rhs_queue.queue_iova;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue depth is not a nonzero power of two");
    if (producer_index >= depth || consumer_index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue index is outside the queue depth");
    if (!rdma_ring_state_valid(producer_index, producer_wrap,
                               consumer_index, consumer_wrap))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue producer and consumer state is invalid");
    return rdma_status::success();
  endfunction
endclass

class rdma_function extends rdma_resource;
  `uvm_object_utils(rdma_function)

  int unsigned local_function_id;
  int unsigned global_function_id;
  int unsigned rdma_vf_id;
  int unsigned vsi_id;
  int unsigned pfvf_id;
  rdma_function_binding binding;

  function new(string name = "rdma_function");
    super.new(name);
    local_function_id = '0;
    global_function_id = '0;
    rdma_vf_id = '0;
    vsi_id = '0;
    pfvf_id = '0;
    binding = rdma_function_binding::type_id::create("binding");
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_FUNCTION;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_function rhs_function;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_function, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "function resource copy type mismatch")
    local_function_id = rhs_function.local_function_id;
    global_function_id = rhs_function.global_function_id;
    rdma_vf_id = rhs_function.rdma_vf_id;
    vsi_id = rhs_function.vsi_id;
    pfvf_id = rhs_function.pfvf_id;
    if (rhs_function.binding == null) begin
      binding = null;
    end
    else begin
      cloned_object = rhs_function.binding.clone();
      if (cloned_object == null || !$cast(binding, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "function binding clone mismatch")
    end
  endfunction
endclass

class rdma_pd extends rdma_resource;
  `uvm_object_utils(rdma_pd)

  int unsigned local_pd_id;
  int unsigned global_pd_id;

  function new(string name = "rdma_pd");
    super.new(name);
    local_pd_id = '0;
    global_pd_id = '0;
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_PD;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_pd rhs_pd;

    super.do_copy(rhs);
    if (!$cast(rhs_pd, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "PD resource copy type mismatch")
    local_pd_id = rhs_pd.local_pd_id;
    global_pd_id = rhs_pd.global_pd_id;
  endfunction
endclass

class rdma_mr extends rdma_resource;
  `uvm_object_utils(rdma_mr)

  int unsigned local_mr_id;
  int unsigned global_mr_id;
  rdma_handle pd_h;
  rdma_iova_t iova;
  longint unsigned length;
  bit [31:0] lkey;
  bit [31:0] rkey;
  rdma_dma_permission_t permissions;

  function new(string name = "rdma_mr");
    super.new(name);
    local_mr_id = '0;
    global_mr_id = '0;
    pd_h = null;
    iova = '0;
    length = '0;
    lkey = '0;
    rkey = '0;
    permissions = '0;
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_MR;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_mr rhs_mr;

    super.do_copy(rhs);
    if (!$cast(rhs_mr, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MR resource copy type mismatch")
    local_mr_id = rhs_mr.local_mr_id;
    global_mr_id = rhs_mr.global_mr_id;
    pd_h = rdma_clone_handle_value(rhs_mr.pd_h, "MR PD");
    iova = rhs_mr.iova;
    length = rhs_mr.length;
    lkey = rhs_mr.lkey;
    rkey = rhs_mr.rkey;
    permissions = rhs_mr.permissions;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (state inside {RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE}) begin
      if (pd_h == null || pd_h.kind != RDMA_RESOURCE_PD ||
          !rdma_handle_matches_owner(pd_h, owner))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR PD handle is invalid");
      if (length == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR length is zero");
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_cq extends rdma_queue_resource;
  `uvm_object_utils(rdma_cq)

  int unsigned local_cq_id;
  int unsigned global_cq_id;
  rdma_handle ceq_h;

  function new(string name = "rdma_cq");
    super.new(name);
    local_cq_id = '0;
    global_cq_id = '0;
    ceq_h = null;
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CQ;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_cq rhs_cq;

    super.do_copy(rhs);
    if (!$cast(rhs_cq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQ resource copy type mismatch")
    local_cq_id = rhs_cq.local_cq_id;
    global_cq_id = rhs_cq.global_cq_id;
    ceq_h = rdma_clone_handle_value(rhs_cq.ceq_h, "CQ CEQ");
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (state inside {RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE}) begin
      if (ceq_h == null || ceq_h.kind != RDMA_RESOURCE_CEQ ||
          !rdma_handle_matches_owner(ceq_h, owner))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "CQ CEQ handle is invalid");
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_qp extends rdma_resource;
  `uvm_object_utils(rdma_qp)

  int unsigned local_qp_id;
  int unsigned global_qp_id;
  rdma_transport_e transport;
  rdma_qp_state_e qp_state;
  int unsigned sq_depth;
  int unsigned rq_depth;
  int unsigned sq_producer_index;
  int unsigned sq_consumer_index;
  bit sq_wrap;
  bit sq_consumer_wrap;
  int unsigned rq_producer_index;
  int unsigned rq_consumer_index;
  bit rq_wrap;
  bit rq_consumer_wrap;
  rdma_iova_t sq_iova;
  rdma_iova_t rq_iova;
  rdma_handle pd_h;
  rdma_handle send_cq_h;
  rdma_handle recv_cq_h;
  rdma_handle srq_h;

  function new(string name = "rdma_qp");
    super.new(name);
    local_qp_id = '0;
    global_qp_id = '0;
    transport = RDMA_TRANSPORT_RC;
    qp_state = RDMA_QPS_RESET;
    sq_depth = '0;
    rq_depth = '0;
    sq_producer_index = '0;
    sq_consumer_index = '0;
    sq_wrap = 1'b0;
    sq_consumer_wrap = 1'b0;
    rq_producer_index = '0;
    rq_consumer_index = '0;
    rq_wrap = 1'b0;
    rq_consumer_wrap = 1'b0;
    sq_iova = '0;
    rq_iova = '0;
    pd_h = null;
    send_cq_h = null;
    recv_cq_h = null;
    srq_h = null;
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_QP;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qp rhs_qp;

    super.do_copy(rhs);
    if (!$cast(rhs_qp, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "QP resource copy type mismatch")
    local_qp_id = rhs_qp.local_qp_id;
    global_qp_id = rhs_qp.global_qp_id;
    transport = rhs_qp.transport;
    qp_state = rhs_qp.qp_state;
    sq_depth = rhs_qp.sq_depth;
    rq_depth = rhs_qp.rq_depth;
    sq_producer_index = rhs_qp.sq_producer_index;
    sq_consumer_index = rhs_qp.sq_consumer_index;
    sq_wrap = rhs_qp.sq_wrap;
    sq_consumer_wrap = rhs_qp.sq_consumer_wrap;
    rq_producer_index = rhs_qp.rq_producer_index;
    rq_consumer_index = rhs_qp.rq_consumer_index;
    rq_wrap = rhs_qp.rq_wrap;
    rq_consumer_wrap = rhs_qp.rq_consumer_wrap;
    sq_iova = rhs_qp.sq_iova;
    rq_iova = rhs_qp.rq_iova;
    pd_h = rdma_clone_handle_value(rhs_qp.pd_h, "QP PD");
    send_cq_h = rdma_clone_handle_value(rhs_qp.send_cq_h, "QP send CQ");
    recv_cq_h = rdma_clone_handle_value(rhs_qp.recv_cq_h, "QP receive CQ");
    srq_h = rdma_clone_handle_value(rhs_qp.srq_h, "QP SRQ");
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (!rdma_is_power_of_two(sq_depth) ||
        !rdma_is_power_of_two(rq_depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP depth is not a nonzero power of two");
    if (sq_producer_index >= sq_depth || sq_consumer_index >= sq_depth ||
        rq_producer_index >= rq_depth || rq_consumer_index >= rq_depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP queue index is outside the queue depth");
    if (!rdma_ring_state_valid(sq_producer_index, sq_wrap,
                               sq_consumer_index, sq_consumer_wrap) ||
        !rdma_ring_state_valid(rq_producer_index, rq_wrap,
                               rq_consumer_index, rq_consumer_wrap))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP producer and consumer state is invalid");
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP transport is invalid");
    if (!(qp_state inside {RDMA_QPS_RESET, RDMA_QPS_INIT, RDMA_QPS_RTR,
                           RDMA_QPS_RTS, RDMA_QPS_SQD, RDMA_QPS_SQE,
                           RDMA_QPS_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP state is invalid");
    if (state inside {RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE}) begin
      if (pd_h == null || pd_h.kind != RDMA_RESOURCE_PD ||
          !rdma_handle_matches_owner(pd_h, owner))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP PD handle is invalid");
      if (send_cq_h == null || send_cq_h.kind != RDMA_RESOURCE_CQ ||
          !rdma_handle_matches_owner(send_cq_h, owner) ||
          recv_cq_h == null || recv_cq_h.kind != RDMA_RESOURCE_CQ ||
          !rdma_handle_matches_owner(recv_cq_h, owner))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP completion queue handle is invalid");
      if (srq_h != null &&
          (srq_h.kind != RDMA_RESOURCE_SRQ ||
           !rdma_handle_matches_owner(srq_h, owner)))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP SRQ handle is invalid");
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_srq extends rdma_queue_resource;
  `uvm_object_utils(rdma_srq)

  int unsigned local_srq_id;
  int unsigned global_srq_id;
  int unsigned max_sge;
  rdma_handle pd_h;

  function new(string name = "rdma_srq");
    super.new(name);
    local_srq_id = '0;
    global_srq_id = '0;
    max_sge = '0;
    pd_h = null;
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_SRQ;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_srq rhs_srq;

    super.do_copy(rhs);
    if (!$cast(rhs_srq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SRQ resource copy type mismatch")
    local_srq_id = rhs_srq.local_srq_id;
    global_srq_id = rhs_srq.global_srq_id;
    max_sge = rhs_srq.max_sge;
    pd_h = rdma_clone_handle_value(rhs_srq.pd_h, "SRQ PD");
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (state inside {RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE}) begin
      if (pd_h == null || pd_h.kind != RDMA_RESOURCE_PD ||
          !rdma_handle_matches_owner(pd_h, owner))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SRQ PD handle is invalid");
      if (max_sge == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SRQ maximum SGE count is zero");
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_ceq extends rdma_queue_resource;
  `uvm_object_utils(rdma_ceq)

  int unsigned local_ceq_id;
  int unsigned global_ceq_id;

  function new(string name = "rdma_ceq");
    super.new(name);
    local_ceq_id = '0;
    global_ceq_id = '0;
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CEQ;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_ceq rhs_ceq;

    super.do_copy(rhs);
    if (!$cast(rhs_ceq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQ resource copy type mismatch")
    local_ceq_id = rhs_ceq.local_ceq_id;
    global_ceq_id = rhs_ceq.global_ceq_id;
  endfunction
endclass

class rdma_aeq extends rdma_queue_resource;
  `uvm_object_utils(rdma_aeq)

  int unsigned local_aeq_id;
  int unsigned global_aeq_id;

  function new(string name = "rdma_aeq");
    super.new(name);
    local_aeq_id = '0;
    global_aeq_id = '0;
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_AEQ;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_aeq rhs_aeq;

    super.do_copy(rhs);
    if (!$cast(rhs_aeq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQ resource copy type mismatch")
    local_aeq_id = rhs_aeq.local_aeq_id;
    global_aeq_id = rhs_aeq.global_aeq_id;
  endfunction
endclass

class rdma_cmq extends rdma_queue_resource;
  `uvm_object_utils(rdma_cmq)

  int unsigned local_cmq_id;
  int unsigned global_cmq_id;
  int unsigned completion_producer_index;
  int unsigned completion_consumer_index;
  bit completion_wrap;
  bit completion_consumer_wrap;
  rdma_iova_t completion_iova;

  function new(string name = "rdma_cmq");
    super.new(name);
    local_cmq_id = '0;
    global_cmq_id = '0;
    completion_producer_index = '0;
    completion_consumer_index = '0;
    completion_wrap = 1'b0;
    completion_consumer_wrap = 1'b0;
    completion_iova = '0;
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CMQ;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_cmq rhs_cmq;

    super.do_copy(rhs);
    if (!$cast(rhs_cmq, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ resource copy type mismatch")
    local_cmq_id = rhs_cmq.local_cmq_id;
    global_cmq_id = rhs_cmq.global_cmq_id;
    completion_producer_index = rhs_cmq.completion_producer_index;
    completion_consumer_index = rhs_cmq.completion_consumer_index;
    completion_wrap = rhs_cmq.completion_wrap;
    completion_consumer_wrap = rhs_cmq.completion_consumer_wrap;
    completion_iova = rhs_cmq.completion_iova;
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    status = super.validate();
    if (!status.ok())
      return status;
    if (completion_producer_index >= depth ||
        completion_consumer_index >= depth)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ completion index is outside the queue depth"
      );
    if (!rdma_ring_state_valid(completion_producer_index, completion_wrap,
                               completion_consumer_index,
                               completion_consumer_wrap))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ completion producer and consumer state is invalid"
      );
    return rdma_status::success();
  endfunction
endclass
