class rdma_resource_manager extends uvm_object;
  `uvm_object_utils(rdma_resource_manager)

  // Registry keys are exactly function_uid:generation:kind:object_id.
  protected rdma_resource registry[string];
  // Bindings remain live references so a Function generation transition is
  // immediately visible to stale-handle checks.
  protected rdma_function_binding live_bindings[string];
  // Incarnation ownership is retained after release to distinguish a stale or
  // released value handle from an unknown/forged handle.
  protected rdma_function_handle incarnation_owners[string];

  // Local IDs are reusable and independent for every resource kind.  The
  // 28-bit serial component of object_id is monotonic and never reused; the
  // upper nibble carries kind so changing only handle.kind cannot alias a live
  // object from another independent pool.
  protected int unsigned next_local_id[rdma_resource_kind_e];
  protected int unsigned free_local_ids[rdma_resource_kind_e][$];
  protected int unsigned next_object_serial[rdma_resource_kind_e];

  function new(string name = "rdma_resource_manager");
    super.new(name);
  endfunction

  protected function bit valid_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_FUNCTION, RDMA_RESOURCE_PD,
                        RDMA_RESOURCE_MR, RDMA_RESOURCE_CQ,
                        RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ,
                        RDMA_RESOURCE_CMQ, RDMA_RESOURCE_CEQ,
                        RDMA_RESOURCE_AEQ};
  endfunction

  protected function string resource_key(rdma_handle handle);
    return $sformatf("%016h:%08h:%0d:%08h", handle.function_uid,
                     handle.generation, handle.kind, handle.object_id);
  endfunction

  protected function string incarnation_key(rdma_handle handle);
    return $sformatf("%016h:%0d:%08h", handle.function_uid,
                     handle.kind, handle.object_id);
  endfunction

  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  endfunction

  protected function rdma_resource clone_resource_value(
    rdma_resource source,
    string copy_label
  );
    uvm_object cloned_object;
    rdma_resource cloned_resource;

    if (source == null)
      return null;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(cloned_resource, cloned_object))
      `uvm_fatal("RM_COPY_TYPE",
                 {copy_label, " resource clone type mismatch"})
    return cloned_resource;
  endfunction

  protected function rdma_status active_binding_status(
    rdma_function_binding binding
  );
    rdma_status status;

    if (binding == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "function binding is null");
    status = binding.validate();
    if (!status.ok())
      return status;
    if (binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "function binding is not ACTIVE");
    return rdma_status::success();
  endfunction

  protected function rdma_status owner_binding_status(
    rdma_function_handle owner
  );
    string key;
    rdma_function_binding binding;
    rdma_function_handle current_owner;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "registry owner is not a Function handle");
    key = function_key(owner);
    if (!live_bindings.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function binding is not registered");
    binding = live_bindings[key];
    if (binding == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "registered Function binding is null");
    current_owner = binding.make_handle();
    if (current_owner.generation != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is stale");
    if (!current_owner.same_instance(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "complete Function identity does not match");
    return rdma_status::success();
  endfunction

  protected function bit has_conflicting_generation(
    rdma_function_handle owner
  );
    foreach (registry[key]) begin
      if (registry[key].owner != null &&
          registry[key].owner.function_uid == owner.function_uid &&
          registry[key].owner.object_id == owner.object_id &&
          registry[key].owner.kind == owner.kind &&
          registry[key].owner.generation != owner.generation)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function rdma_status reserve_identity(
    rdma_function_binding binding,
    rdma_resource_kind_e kind,
    output rdma_function_handle owner,
    output rdma_handle handle,
    output int unsigned local_id
  );
    rdma_status status;
    int unsigned serial;
    string owner_key;

    owner = null;
    handle = null;
    local_id = '0;
    status = active_binding_status(binding);
    if (!status.ok())
      return status;
    if (!valid_kind(kind) || kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "object resource kind is invalid");

    serial = next_object_serial[kind];
    if (serial == 0)
      serial = 1;
    if (serial > 32'h0fff_ffff)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "resource incarnation serial is exhausted");
    if ((!free_local_ids.exists(kind) ||
         free_local_ids[kind].size() == 0) &&
        next_local_id[kind] == 32'hffff_ffff)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "resource local ID pool is exhausted");

    owner = binding.make_handle();
    if (has_conflicting_generation(owner))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "older Function generation still owns live resources"
      );
    owner_key = function_key(owner);
    if (live_bindings.exists(owner_key)) begin
      status = owner_binding_status(owner);
      if (!status.ok())
        return status;
    end

    if (free_local_ids.exists(kind) &&
        free_local_ids[kind].size() != 0)
      local_id = free_local_ids[kind].pop_front();
    else begin
      local_id = next_local_id[kind];
      next_local_id[kind]++;
    end
    next_object_serial[kind] = serial + 1'b1;

    handle = rdma_handle::type_id::create("resource_handle");
    handle.kind = kind;
    handle.function_uid = owner.function_uid;
    handle.object_id = {kind, serial[27:0]};
    handle.generation = owner.generation;
    live_bindings[owner_key] = binding;
    return rdma_status::success();
  endfunction

  protected function void register_resource(rdma_resource resource);
    string key;

    key = resource_key(resource.handle);
    registry[key] = resource;
    incarnation_owners[incarnation_key(resource.handle)] =
      rdma_clone_function_handle_value(resource.owner,
                                        "resource incarnation owner");
  endfunction

  protected function rdma_status dependency_status(
    rdma_function_handle owner,
    rdma_handle dependency,
    rdma_resource_kind_e expected_kind,
    bit allow_null
  );
    rdma_resource dependency_resource;
    rdma_status status;

    if (dependency == null) begin
      if (allow_null)
        return rdma_status::success();
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "required resource dependency is null");
    end
    if (dependency.kind != expected_kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource dependency kind is invalid");
    status = lookup(dependency, dependency_resource);
    if (!status.ok())
      return status;
    if (dependency_resource.owner == null ||
        !dependency_resource.owner.same_instance(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource dependency has another owner");
    return rdma_status::success();
  endfunction

  protected function int unsigned resource_local_id(rdma_resource resource);
    rdma_pd pd;
    rdma_mr mr;
    rdma_cq cq;
    rdma_qp qp;
    rdma_srq srq;
    rdma_cmq cmq;
    rdma_ceq ceq;
    rdma_aeq aeq;
    rdma_function function_resource;

    case (resource.resource_kind())
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(function_resource, resource))
          `uvm_fatal("RM_TYPE", "Function resource type mismatch")
        return function_resource.local_function_id;
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(pd, resource))
          `uvm_fatal("RM_TYPE", "PD resource type mismatch")
        return pd.local_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(mr, resource))
          `uvm_fatal("RM_TYPE", "MR resource type mismatch")
        return mr.local_mr_id;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq, resource))
          `uvm_fatal("RM_TYPE", "CQ resource type mismatch")
        return cq.local_cq_id;
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(qp, resource))
          `uvm_fatal("RM_TYPE", "QP resource type mismatch")
        return qp.local_qp_id;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq, resource))
          `uvm_fatal("RM_TYPE", "SRQ resource type mismatch")
        return srq.local_srq_id;
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(cmq, resource))
          `uvm_fatal("RM_TYPE", "CMQ resource type mismatch")
        return cmq.local_cmq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(ceq, resource))
          `uvm_fatal("RM_TYPE", "CEQ resource type mismatch")
        return ceq.local_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(aeq, resource))
          `uvm_fatal("RM_TYPE", "AEQ resource type mismatch")
        return aeq.local_aeq_id;
      end
    endcase
    `uvm_fatal("RM_KIND", "resource kind has no local ID pool")
    return '0;
  endfunction

  protected function bit resource_depends_on(
    rdma_resource candidate,
    rdma_handle dependency
  );
    if (candidate == null || dependency == null)
      return 1'b0;
    foreach (candidate.dependencies[i]) begin
      if (candidate.dependencies[i] != null &&
          candidate.dependencies[i].same_instance(dependency))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function bit has_dependents(rdma_resource resource);
    foreach (registry[key]) begin
      if (registry[key] == resource)
        continue;
      if (resource_depends_on(registry[key], resource.handle))
        return 1'b1;
      if (resource.resource_kind() == RDMA_RESOURCE_FUNCTION &&
          registry[key].owner != null &&
          registry[key].owner.same_instance(resource.handle))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function void force_release_key(string key);
    rdma_resource resource;
    rdma_resource_kind_e kind;
    int unsigned local_id;

    resource = registry[key];
    kind = resource.resource_kind();
    local_id = resource_local_id(resource);
    resource.state = RDMA_RESOURCE_RELEASED;
    free_local_ids[kind].push_back(local_id);
    registry.delete(key);
  endfunction

  function rdma_status create_function(
    rdma_function_binding binding,
    output rdma_function function_resource
  );
    rdma_status status;
    rdma_function authoritative;
    rdma_resource published;
    rdma_function_handle owner;
    string key;
    int unsigned local_id;

    function_resource = null;
    status = active_binding_status(binding);
    if (!status.ok())
      return status;
    owner = binding.make_handle();
    key = resource_key(owner);
    if (registry.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function incarnation already exists");
    if (has_conflicting_generation(owner))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "older Function generation still owns live resources"
      );
    if (incarnation_owners.exists(incarnation_key(owner)) &&
        incarnation_owners[incarnation_key(owner)].generation ==
          owner.generation)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function incarnation was already released");
    if ((!free_local_ids.exists(RDMA_RESOURCE_FUNCTION) ||
         free_local_ids[RDMA_RESOURCE_FUNCTION].size() == 0) &&
        next_local_id[RDMA_RESOURCE_FUNCTION] == 32'hffff_ffff)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "Function local ID pool is exhausted");
    if (free_local_ids.exists(RDMA_RESOURCE_FUNCTION) &&
        free_local_ids[RDMA_RESOURCE_FUNCTION].size() != 0)
      local_id = free_local_ids[RDMA_RESOURCE_FUNCTION].pop_front();
    else begin
      local_id = next_local_id[RDMA_RESOURCE_FUNCTION];
      next_local_id[RDMA_RESOURCE_FUNCTION]++;
    end
    live_bindings[function_key(owner)] = binding;
    authoritative = rdma_function::type_id::create("function_resource");
    authoritative.handle = owner;
    authoritative.owner = rdma_clone_function_handle_value(owner,
                                                             "Function owner");
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_function_id = local_id;
    authoritative.global_function_id = owner.object_id;
    authoritative.binding = binding;
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create Function");
    if (!$cast(function_resource, published))
      `uvm_fatal("RM_COPY_TYPE", "published Function type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_pd(
    rdma_function_binding binding,
    output rdma_pd pd
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_pd authoritative;
    rdma_resource published;
    int unsigned local_id;

    pd = null;
    status = reserve_identity(binding, RDMA_RESOURCE_PD, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_pd::type_id::create("pd");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_pd_id = local_id;
    authoritative.global_pd_id = handle.object_id;
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create PD");
    if (!$cast(pd, published))
      `uvm_fatal("RM_COPY_TYPE", "published PD type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_mr(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_mr mr
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_mr authoritative;
    rdma_resource published;
    int unsigned local_id;

    mr = null;
    status = active_binding_status(binding);
    if (!status.ok())
      return status;
    owner = binding.make_handle();
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_MR, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_mr::type_id::create("mr");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_mr_id = local_id;
    authoritative.global_mr_id = handle.object_id;
    authoritative.pd_h = rdma_clone_handle_value(pd_h, "MR PD");
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(pd_h, "MR dependency")
    );
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create MR");
    if (!$cast(mr, published))
      `uvm_fatal("RM_COPY_TYPE", "published MR type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_cq(
    rdma_function_binding binding,
    rdma_handle ceq_h,
    output rdma_cq cq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_cq authoritative;
    rdma_resource published;
    int unsigned local_id;

    cq = null;
    status = active_binding_status(binding);
    if (!status.ok())
      return status;
    owner = binding.make_handle();
    status = dependency_status(owner, ceq_h, RDMA_RESOURCE_CEQ, 1'b1);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_CQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_cq::type_id::create("cq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_cq_id = local_id;
    authoritative.global_cq_id = handle.object_id;
    if (ceq_h != null) begin
      authoritative.ceq_h = rdma_clone_handle_value(ceq_h, "CQ CEQ");
      authoritative.dependencies.push_back(
        rdma_clone_handle_value(ceq_h, "CQ dependency")
      );
    end
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create CQ");
    if (!$cast(cq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_qp(
    rdma_function_binding binding,
    rdma_handle pd_h,
    rdma_handle send_cq_h,
    rdma_handle recv_cq_h,
    rdma_handle srq_h,
    output rdma_qp qp
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_qp authoritative;
    rdma_resource published;
    int unsigned local_id;

    qp = null;
    status = active_binding_status(binding);
    if (!status.ok())
      return status;
    owner = binding.make_handle();
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, send_cq_h, RDMA_RESOURCE_CQ, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, recv_cq_h, RDMA_RESOURCE_CQ, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, srq_h, RDMA_RESOURCE_SRQ, 1'b1);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_QP, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_qp::type_id::create("qp");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_qp_id = local_id;
    authoritative.global_qp_id = handle.object_id;
    authoritative.pd_h = rdma_clone_handle_value(pd_h, "QP PD");
    authoritative.send_cq_h = rdma_clone_handle_value(send_cq_h,
                                                       "QP send CQ");
    authoritative.recv_cq_h = rdma_clone_handle_value(recv_cq_h,
                                                       "QP receive CQ");
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(pd_h, "QP PD dependency")
    );
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(send_cq_h, "QP send CQ dependency")
    );
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(recv_cq_h, "QP receive CQ dependency")
    );
    if (srq_h != null) begin
      authoritative.srq_h = rdma_clone_handle_value(srq_h, "QP SRQ");
      authoritative.dependencies.push_back(
        rdma_clone_handle_value(srq_h, "QP SRQ dependency")
      );
    end
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create QP");
    if (!$cast(qp, published))
      `uvm_fatal("RM_COPY_TYPE", "published QP type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_srq(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_srq srq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_srq authoritative;
    rdma_resource published;
    int unsigned local_id;

    srq = null;
    status = active_binding_status(binding);
    if (!status.ok())
      return status;
    owner = binding.make_handle();
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_SRQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_srq::type_id::create("srq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_srq_id = local_id;
    authoritative.global_srq_id = handle.object_id;
    authoritative.pd_h = rdma_clone_handle_value(pd_h, "SRQ PD");
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(pd_h, "SRQ dependency")
    );
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create SRQ");
    if (!$cast(srq, published))
      `uvm_fatal("RM_COPY_TYPE", "published SRQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_cmq(
    rdma_function_binding binding,
    output rdma_cmq cmq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_cmq authoritative;
    rdma_resource published;
    int unsigned local_id;

    cmq = null;
    status = reserve_identity(binding, RDMA_RESOURCE_CMQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_cmq::type_id::create("cmq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_cmq_id = local_id;
    authoritative.global_cmq_id = handle.object_id;
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create CMQ");
    if (!$cast(cmq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CMQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_ceq(
    rdma_function_binding binding,
    output rdma_ceq ceq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_ceq authoritative;
    rdma_resource published;
    int unsigned local_id;

    ceq = null;
    status = reserve_identity(binding, RDMA_RESOURCE_CEQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_ceq::type_id::create("ceq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_ceq_id = local_id;
    authoritative.global_ceq_id = handle.object_id;
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create CEQ");
    if (!$cast(ceq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CEQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_aeq(
    rdma_function_binding binding,
    output rdma_aeq aeq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_aeq authoritative;
    rdma_resource published;
    int unsigned local_id;

    aeq = null;
    status = reserve_identity(binding, RDMA_RESOURCE_AEQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_aeq::type_id::create("aeq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_aeq_id = local_id;
    authoritative.global_aeq_id = handle.object_id;
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create AEQ");
    if (!$cast(aeq, published))
      `uvm_fatal("RM_COPY_TYPE", "published AEQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status lookup(
    rdma_handle handle,
    output rdma_resource resource
  );
    string key;
    string incarnation;
    rdma_resource authoritative;
    rdma_function_handle owner;
    rdma_status status;

    resource = null;
    if (handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle is null");
    if (!valid_kind(handle.kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle kind is invalid");
    if (handle.kind != RDMA_RESOURCE_FUNCTION &&
        handle.object_id[31:28] != handle.kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource incarnation kind prefix is invalid");

    key = resource_key(handle);
    if (registry.exists(key)) begin
      authoritative = registry[key];
      if (authoritative == null || authoritative.handle == null ||
          !authoritative.handle.same_instance(handle))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "registry identity is inconsistent");
      status = owner_binding_status(authoritative.owner);
      if (!status.ok())
        return status;
      resource = clone_resource_value(authoritative, "lookup");
      return rdma_status::success();
    end

    incarnation = incarnation_key(handle);
    if (!incarnation_owners.exists(incarnation))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle is unknown or forged");
    owner = incarnation_owners[incarnation];
    status = owner_binding_status(owner);
    if (status.code == RDMA_SC_STALE_GENERATION)
      return status;
    if (!status.ok())
      return status;
    if (handle.generation != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "resource handle generation is stale");
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "resource handle has been released");
  endfunction

  function rdma_status freeze(rdma_handle handle);
    rdma_resource ignored;
    rdma_status status;
    string key;

    status = lookup(handle, ignored);
    if (!status.ok())
      return status;
    key = resource_key(handle);
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "only an ALLOCATED resource can be frozen");
    registry[key].state = RDMA_RESOURCE_PROGRAMMED;
    return rdma_status::success();
  endfunction

  function rdma_status \release (rdma_handle handle);
    rdma_resource ignored;
    rdma_status status;
    string key;

    status = lookup(handle, ignored);
    if (!status.ok())
      return status;
    key = resource_key(handle);
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "frozen resource requires Function teardown");
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource still has live dependents");
    force_release_key(key);
    return rdma_status::success();
  endfunction

  function rdma_status release_function(rdma_function_handle owner);
    rdma_status status;
    bit selected[string];
    string release_order[$];
    int unsigned target_count;
    bit progress;
    bit blocked;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function teardown handle is invalid");
    status = owner_binding_status(owner);
    if (!status.ok())
      return status;

    target_count = 0;
    foreach (registry[key]) begin
      if (registry[key].owner != null &&
          registry[key].owner.same_instance(owner))
        target_count++;
    end

    while (release_order.size() < target_count) begin
      progress = 1'b0;
      foreach (registry[key]) begin
        if (selected.exists(key) || registry[key].owner == null ||
            !registry[key].owner.same_instance(owner))
          continue;
        blocked = 1'b0;
        foreach (registry[other_key]) begin
          if (key == other_key || selected.exists(other_key) ||
              registry[other_key].owner == null ||
              !registry[other_key].owner.same_instance(owner))
            continue;
          if (resource_depends_on(registry[other_key],
                                  registry[key].handle))
            blocked = 1'b1;
          if (registry[key].resource_kind() == RDMA_RESOURCE_FUNCTION &&
              registry[other_key].resource_kind() !=
                RDMA_RESOURCE_FUNCTION)
            blocked = 1'b1;
        end
        if (!blocked) begin
          selected[key] = 1'b1;
          release_order.push_back(key);
          progress = 1'b1;
        end
      end
      if (!progress)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "resource dependency graph has a cycle");
    end

    foreach (release_order[i])
      force_release_key(release_order[i]);
    return rdma_status::success();
  endfunction

  function rdma_status check_leaks(
    output int unsigned leak_count,
    input rdma_function_handle owner = null
  );
    leak_count = 0;
    if (owner != null && owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "leak filter is not a Function handle");
    foreach (registry[key]) begin
      if (owner == null ||
          (registry[key].owner != null &&
           registry[key].owner.same_instance(owner)))
        leak_count++;
    end
    if (leak_count != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               $sformatf("%0d RDMA resources leaked",
                                         leak_count));
    return rdma_status::success();
  endfunction
endclass
