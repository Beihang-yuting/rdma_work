// 目录：测试层 mocks/rdma_mock_context_backing.sv。
// 职责：验证 rdma_mock_context_backing 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_mock_context_backing.sv 属于测试替身，为单元测试提供可控的适配器和控制面行为。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_mock_context_slot_token extends rdma_queue_slot_token_contract;
  `uvm_object_utils(rdma_mock_context_slot_token)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_mock_context_backing");
    super.new(name);
    slots.delete();
    call_trace.delete();
    release_call_count = 0;
    failure_queue.delete();
  endfunction

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
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

  // 功能：把输入错误或注入故障转换成统一的 rdma_status，供上层沿原事务路径处理。
  // 输入/输出及副作用：输入为错误消息、错误码或故障证据；返回统一 rdma_status，不推进事务游标。
  //   空消息仍需保留错误类别；未知错误码不得被静默转换为成功。
  // 失败/边界：错误路径不能返回成功状态；消息和错误码缺失时仍须保留可诊断类别。
  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status status);
    if (status != null && ordinal != 0)
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_mock_clone_status(status);
  endfunction

  // 功能：清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：参数 delete 用于执行 reset；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function void reset();
    slots.delete(); call_trace.delete(); failure_queue.delete();
    role_failures.delete(); method_ordinals.delete(); release_call_count = 0;
  endfunction

  // 功能：处理 consume_failure：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 status 用于执行 consume_failure；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：consume_failure 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic rdma_status consume_failure(string method_name);
    rdma_status status;
    if (!failure_queue.exists(method_name) ||
        failure_queue[method_name].size() == 0)
      return null;
    status = failure_queue[method_name].pop_front();
    return status;
  endfunction

  // 功能：处理 consume_role_failure：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 method_name, role 用于执行 consume_role_failure；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：consume_role_failure 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：处理 context_role：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 resource_kind 用于执行 context_role；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：context_role 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic rdma_queue_backing_role_e context_role(
    rdma_resource_kind_e resource_kind
  );
    case (resource_kind)
      RDMA_RESOURCE_SRQ: return RDMA_QUEUE_ROLE_SRQ_RING;
      // Fault-routing discriminator only: QPC context authority is not SQ
      // backing, and Task 1 deliberately defines no separate QPC role.
      RDMA_RESOURCE_QP: return RDMA_QUEUE_ROLE_QP_SQ_RING;
      default: return RDMA_QUEUE_ROLE_CQ_RING;
    endcase
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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

  // 功能：检查可用容量并预留所需资源，返回带所有权证据的分配结果；容量不足时不留下部分分配。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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
        !(resource_kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                RDMA_RESOURCE_QP}))
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
    end else if (resource_kind == RDMA_RESOURCE_SRQ) begin
      slot.slot_length = 32;
      slot.shadow_view_offset = 28;
      slot.shadow_view_length = 4;
      alignment = 4096;
      slot.shadow_pointer_base.value = 64'h0000_2000_0000_0000 +
                                       longint'(local_id) * 4096;
    end else begin
      slot.slot_length = 512;
      slot.shadow_view_offset = 0;
      slot.shadow_view_length = 512;
      alignment = 512;
      slot.shadow_pointer_base.value = 64'h0000_3000_0000_0000 +
                                       longint'(local_id) * 512;
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
                        longint'(local_id) *
                          (resource_kind == RDMA_RESOURCE_QP ? 512 : 4096);
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

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 context_ref, offset, data 用于执行 write；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
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

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
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

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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
