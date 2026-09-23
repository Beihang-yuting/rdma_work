// 目录：测试层 mocks/rdma_mock_context_backing.sv。
// 职责：验证 rdma_mock_context_backing 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_mock_context_backing.sv 属于测试替身，为单元测试提供可控的适配器、
//   host-visible context read/write 和控制面行为。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_mock_context_slot_token extends rdma_queue_slot_token_contract;
  `uvm_object_utils(rdma_mock_context_slot_token)

  // 功能：构造 rdma_mock_context_slot_token，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_context_slot_token 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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

  // 功能：构造 rdma_mock_context_slot，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：owner=null；resource_kind=RDMA_RESOURCE_CQ；local_id=0；completion_authority=null；slot_length=0；shadow_view_offset=0；shadow_view_length=0；shadow_pointer_base='0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_context_slot 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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

  // 功能：构造 rdma_mock_context_backing，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：release_call_count=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_context_backing 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_context_backing");
    super.new(name);
    slots.delete();
    call_trace.delete();
    release_call_count = 0;
    failure_queue.delete();
  endfunction

  // 功能：在 rdma_mock_context_backing 中，fail_next 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、status（输入）；fail_next 读取 method_name、status 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：fail_next 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“unknown context backing method”“failure status is null”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {"acquire", "write", "read", "release",
                              "query_release_completion"}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown context backing method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failure_queue[method_name].push_back(rdma_mock_clone_status(status));
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_context_backing 中，fail_role_call 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）、ordinal（输入）、status（输入）；fail_role_call 读取 method_name、role、ordinal、status 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：fail_role_call 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status status);
    if (status != null && ordinal != 0)
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_mock_clone_status(status);
  endfunction

  // 功能：在 rdma_mock_context_backing 中，reset reset 清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function void reset();
    slots.delete(); call_trace.delete(); failure_queue.delete();
    role_failures.delete(); method_ordinals.delete(); release_call_count = 0;
  endfunction

  // 功能：在 rdma_mock_context_backing 中，consume_failure 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：method_name（输入）；consume_failure 读取 method_name 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：consume_failure 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_status consume_failure(string method_name);
    rdma_status status;
    if (!failure_queue.exists(method_name) ||
        failure_queue[method_name].size() == 0)
      return null;
    status = failure_queue[method_name].pop_front();
    return status;
  endfunction

  // 功能：在 rdma_mock_context_backing 中，consume_role_failure 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：method_name（输入）、role（输入）；consume_role_failure 读取 method_name、role 并使用字段 ordinal、key、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：consume_role_failure 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：context_role 使用 resource_kind 计算并返回 rdma_queue_backing_role_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：resource_kind（输入）；context_role 读取 resource_kind 并使用输入参数和固定枚举/常量；函数返回 rdma_queue_backing_role_e，不取得调用方资源所有权。
  // 失败/边界：context_role 按 case(resource_kind) 的固定映射计算 rdma_queue_backing_role_e（RDMA_RESOURCE_SRQ→RDMA_QUEUE_ROLE_SRQ_RING；RDMA_RESOURCE_QP→RDMA_QUEUE_ROLE_QP_SQ_RING；default→RDMA_QUEUE_ROLE_CQ_RING）；未列出的输入走 default，不修改运行时账本。
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

  // 功能：在 rdma_mock_context_backing 中，find_slot 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：context_ref（输入）；find_slot 读取 context_ref 并使用字段 status；函数返回 rdma_mock_context_slot，不取得调用方资源所有权。
  // 失败/边界：find_slot 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_mock_context_backing 中，acquire 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：binding（输入）、resource_kind（输入）、local_id（输入）、context_ref（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output
  //   发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
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
    hmc.index_valid = 1'b1;
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

  // 功能：在 rdma_mock_context_backing 中，write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：context_ref（输入）、offset（输入）、data（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
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

  // 功能：在 rdma_mock_context_backing 中，read 从指定 context slot 复制一段
  //   detached bytes，模拟驱动读取 QPC runtime shadow 等 host-visible 回写区域。
  // 输入/输出及副作用：context_ref、offset、size 为输入，data 为输出；调用只
  //   增加可审计的 read 调用轨迹，不改变 slot 内容、释放状态或 owner authority。
  // 失败/边界：故障注入、authority 不匹配、已释放 slot、size=0 或范围越界时返回
  //   对应错误且 data 为空；成功返回独立数组，调用方修改不会反写 mock slot。
  virtual function rdma_status read(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    int unsigned size,
    output byte unsigned data[]
  );
    rdma_status forced;
    rdma_mock_context_slot slot;

    data = new[0];
    call_trace.push_back("read");
    method_ordinals["read"]++;

    forced = consume_role_failure("read", context_role(
      context_ref == null ? RDMA_RESOURCE_CQ : context_ref.resource_kind));
    if (forced != null)
      return forced;

    forced = consume_failure("read");
    if (forced != null)
      return forced;

    slot = find_slot(context_ref);
    if (slot == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context authority mismatch");
    if (slot.released || context_ref.release_complete)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "context slot released");
    if (size == 0 || offset > slot.slot_length ||
        size > slot.slot_length - offset)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "context read exceeds slot");

    data = new[size];
    for (int unsigned i = 0; i < size; i++)
      data[i] = slot.data[offset + i];
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_context_backing 中，release 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：context_ref（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
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

  // 功能：在 rdma_mock_context_backing 中，query_release_completion 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：context_ref（输入）、complete（输出）；query_release_completion 读取 context_ref、complete 并使用字段 complete、forced、slot，并写入 complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：query_release_completion 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_mock_context_backing 中，read_slot_byte 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：context_ref（输入）、offset（输入）、value（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：read_slot_byte 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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
