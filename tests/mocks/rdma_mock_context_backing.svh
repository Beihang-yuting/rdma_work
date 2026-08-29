class rdma_mock_context_slot_token extends rdma_queue_slot_token_contract;
  `uvm_object_utils(rdma_mock_context_slot_token)

  function new(string name = "rdma_mock_context_slot_token");
    super.new(name);
  endfunction
endclass

class rdma_mock_context_slot extends uvm_object;
  `uvm_object_utils(rdma_mock_context_slot)

  rdma_function_handle owner;
  rdma_resource_kind_e resource_kind;
  int unsigned local_id;
  rdma_queue_completion_authority completion_authority;
  longint unsigned slot_length;
  longint unsigned shadow_view_offset;
  longint unsigned shadow_view_length;
  rdma_backing_addr_t shadow_pointer_base;
  byte unsigned data[];
  bit released;
  int unsigned release_count;

  function new(string name = "rdma_mock_context_slot");
    super.new(name);
    owner = null;
    resource_kind = RDMA_RESOURCE_CQ;
    local_id = 0;
    completion_authority = null;
    slot_length = 0;
    shadow_view_offset = 0;
    shadow_view_length = 0;
    shadow_pointer_base = '0;
    data = new[0];
    released = 0;
    release_count = 0;
  endfunction
endclass

class rdma_mock_context_backing extends rdma_context_backing_api;
  `uvm_object_utils(rdma_mock_context_backing)

  rdma_mock_context_slot slots[$];
  string call_trace[$];
  int unsigned release_call_count;
  rdma_status failure_queue[string][$];
  rdma_status role_failures[string];
  int unsigned method_ordinals[string];

  function new(string name = "rdma_mock_context_backing");
    super.new(name);
    slots.delete();
    call_trace.delete();
    release_call_count = 0;
    failure_queue.delete();
  endfunction

  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {"acquire", "write", "release",
                              "query_release_completion"}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown context backing method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failure_queue[method_name].push_back(rdma_mock_clone_status(status));
    return rdma_status::success();
  endfunction

  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status status);
    if (status != null && ordinal != 0)
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_mock_clone_status(status);
  endfunction

  function void reset();
    slots.delete(); call_trace.delete(); failure_queue.delete();
    role_failures.delete(); method_ordinals.delete(); release_call_count = 0;
  endfunction

  function automatic rdma_status consume_failure(string method_name);
    rdma_status status;
    if (!failure_queue.exists(method_name) ||
        failure_queue[method_name].size() == 0)
      return null;
    status = failure_queue[method_name].pop_front();
    return status;
  endfunction

  function automatic rdma_status consume_role_failure(
    string method_name,
    rdma_queue_backing_role_e role
  );
    rdma_status status;
    int unsigned ordinal;
    string key;

    ordinal = method_ordinals.exists(method_name) ? method_ordinals[method_name] : 0;
    key = $sformatf("%s:%0d:%0d", method_name, role, ordinal);
    if (role_failures.exists(key)) begin
      status = rdma_mock_clone_status(role_failures[key]);
      role_failures.delete(key);
      return status;
    end
    return null;
  endfunction

  function automatic rdma_queue_backing_role_e context_role(
    rdma_resource_kind_e resource_kind
  );
    return (resource_kind == RDMA_RESOURCE_SRQ) ?
      RDMA_QUEUE_ROLE_SRQ_RING : RDMA_QUEUE_ROLE_CQ_RING;
  endfunction

  function automatic rdma_mock_context_slot find_slot(
    rdma_context_backing_ref context_ref
  );
    rdma_status status;
    rdma_queue_slot_token_contract token;
    rdma_function_handle owner;

    if (context_ref == null || context_ref.owner == null ||
        context_ref.slot_token == null)
      return null;
    if (!$cast(token, context_ref.slot_token) ||
        token.completion_authority == null)
      return null;
    status = token.validate();
    if (status == null || !status.ok())
      return null;
    if (!$cast(owner, context_ref.owner) ||
        owner.kind != RDMA_RESOURCE_FUNCTION)
      return null;
    foreach (slots[i]) begin
      if (slots[i] == null || slots[i].owner == null ||
          slots[i].completion_authority == null)
        continue;
      if (slots[i].resource_kind != context_ref.resource_kind ||
          slots[i].local_id != context_ref.local_id ||
          slots[i].owner.function_uid != owner.function_uid ||
          slots[i].owner.object_id != owner.object_id ||
          slots[i].owner.generation != owner.generation)
        continue;
      if (token.completion_authority !== slots[i].completion_authority)
        continue;
      if (context_ref.slot_length != slots[i].slot_length ||
          context_ref.shadow_view_offset != slots[i].shadow_view_offset ||
          context_ref.shadow_view_length != slots[i].shadow_view_length ||
          context_ref.shadow_pointer_base.value !=
            slots[i].shadow_pointer_base.value ||
          context_ref.shadow_view_length == 0 ||
          context_ref.shadow_view_length > context_ref.slot_length ||
          context_ref.shadow_view_offset >
            context_ref.slot_length - context_ref.shadow_view_length)
        continue;
      return slots[i];
    end
    return null;
  endfunction

  virtual function rdma_status acquire(
    rdma_function_binding binding,
    rdma_resource_kind_e resource_kind,
    int unsigned local_id,
    output rdma_context_backing_ref context_ref
  );
    rdma_status forced;
    rdma_mock_context_slot slot;
    rdma_function_handle owner;
    rdma_hmc_ref hmc;
    rdma_queue_slot_token_contract token;
    rdma_context_backing_ref result;
    longint unsigned alignment;

    context_ref = null;
    call_trace.push_back("acquire");
    method_ordinals["acquire"]++;
    forced = consume_role_failure("acquire", context_role(resource_kind));
    if (forced != null) return forced;
    forced = consume_failure("acquire");
    if (forced != null)
      return forced;
    if (binding == null ||
        !(resource_kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "invalid context acquire");
    owner = binding.make_handle();
    if (owner == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "binding owner unavailable");

    slot = rdma_mock_context_slot::type_id::create(
      $sformatf("slot_%0d", slots.size())
    );
    slot.owner = owner;
    slot.resource_kind = resource_kind;
    slot.local_id = local_id;
    slot.completion_authority = rdma_queue_completion_authority::type_id::create(
      $sformatf("completion_%0d", slots.size())
    );
    if (resource_kind == RDMA_RESOURCE_CQ) begin
      slot.slot_length = 64;
      slot.shadow_view_offset = 48;
      slot.shadow_view_length = 8;
      alignment = 64;
      slot.shadow_pointer_base.value = 64'h0000_1000_0000_0000 +
                                       longint'(local_id) * 64;
    end else begin
      slot.slot_length = 32;
      slot.shadow_view_offset = 28;
      slot.shadow_view_length = 4;
      alignment = 4096;
      slot.shadow_pointer_base.value = 64'h0000_2000_0000_0000 +
                                       longint'(local_id) * 4096;
    end
    slot.shadow_pointer_base.value =
      (slot.shadow_pointer_base.value / alignment) * alignment;
    slot.data = new[slot.slot_length];
    foreach (slot.data[i]) slot.data[i] = 8'h00;
    slots.push_back(slot);

    token = rdma_mock_context_slot_token::type_id::create(
      $sformatf("token_%0d", slots.size() - 1)
    );
    token.completion_authority = slot.completion_authority;
    hmc = rdma_hmc_ref::type_id::create($sformatf("hmc_%0d", slots.size() - 1));
    hmc.owner = owner;
    hmc.object_kind = RDMA_RESOURCE_MR;
    hmc.address.value = 64'h0000_4000_0000_0000 +
                        longint'(local_id) * 4096;
    hmc.size = slot.slot_length;
    hmc.first_pbl_index = local_id + 1;
    hmc.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;

    result = rdma_context_backing_ref::type_id::create("context_ref");
    result.owner = owner;
    result.resource_kind = resource_kind;
    result.local_id = local_id;
    result.slot_token = token;
    result.hmc_ref = hmc;
    result.shadow_pointer_base = slot.shadow_pointer_base;
    result.slot_length = slot.slot_length;
    result.shadow_view_offset = slot.shadow_view_offset;
    result.shadow_view_length = slot.shadow_view_length;
    result.release_complete = 0;
    context_ref = result;
    return rdma_status::success();
  endfunction

  virtual function rdma_status write(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    byte unsigned data[]
  );
    rdma_status forced;
    rdma_mock_context_slot slot;
    longint unsigned i;

    call_trace.push_back("write");
    method_ordinals["write"]++;
    forced = consume_role_failure("write", context_role(
      context_ref == null ? RDMA_RESOURCE_CQ : context_ref.resource_kind));
    if (forced != null) return forced;
    forced = consume_failure("write");
    if (forced != null)
      return forced;
    slot = find_slot(context_ref);
    if (slot == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context authority mismatch");
    if (slot.released || context_ref.release_complete)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "context slot released");
    if (data.size() > slot.slot_length ||
        offset > slot.slot_length - data.size())
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "context write exceeds slot");
    if (!(offset == 0 && data.size() == slot.slot_length) &&
        data.size() != 0 && offset >= slot.shadow_view_offset &&
        data.size() > slot.shadow_view_offset + slot.shadow_view_length - offset)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "context write exceeds shadow view");
    for (i = 0; i < data.size(); i++)
      slot.data[offset + i] = data[i];
    return rdma_status::success();
  endfunction

  virtual function rdma_status \release (
    rdma_context_backing_ref context_ref
  );
    rdma_status forced;
    rdma_mock_context_slot slot;

    call_trace.push_back("release");
    method_ordinals["release"]++;
    forced = consume_role_failure("release", context_role(
      context_ref == null ? RDMA_RESOURCE_CQ : context_ref.resource_kind));
    if (forced != null) return forced;
    forced = consume_failure("release");
    if (forced != null)
      return forced;
    slot = find_slot(context_ref);
    if (slot == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context authority mismatch");
    if (slot.released || context_ref.release_complete)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "context already released");
    slot.released = 1;
    slot.release_count++;
    release_call_count++;
    slot.completion_authority.complete = 1;
    context_ref.release_complete = 1;
    return rdma_status::success();
  endfunction

  virtual function rdma_status query_release_completion(
    rdma_context_backing_ref context_ref,
    output bit complete
  );
    rdma_status forced;
    rdma_mock_context_slot slot;

    complete = 0;
    call_trace.push_back("query_release_completion");
    method_ordinals["query_release_completion"]++;
    forced = consume_role_failure("query_release_completion", context_role(
      context_ref == null ? RDMA_RESOURCE_CQ : context_ref.resource_kind));
    if (forced != null) return forced;
    forced = consume_failure("query_release_completion");
    if (forced != null)
      return forced;
    slot = find_slot(context_ref);
    if (slot == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context authority mismatch");
    complete = slot.completion_authority.complete;
    return rdma_status::success();
  endfunction

  function rdma_status read_slot_byte(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    output byte unsigned value
  );
    rdma_mock_context_slot slot;
    value = 0;
    slot = find_slot(context_ref);
    if (slot == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context authority mismatch");
    if (offset >= slot.slot_length)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "context read exceeds slot");
    value = slot.data[offset];
    return rdma_status::success();
  endfunction
endclass
