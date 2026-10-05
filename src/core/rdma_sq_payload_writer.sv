// 目录：核心执行层 core/rdma_sq_payload_writer.sv。
// 职责：实现 rdma_sq_payload_writer 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：本文件实现 staged non-inline payload 的注册、写入和逐字节回读校验。
// 生命周期约束：writer 只借用 caller-owned mapping，不取得 host_mem.release() 权限。

class rdma_sq_payload_write_receipt extends uvm_object;
  // receipt 保存 detached 的 payload/SGE 快照，供后续 record 生命周期使用。
  `uvm_object_utils(rdma_sq_payload_write_receipt)

  bit verified;
  bit released;
  byte unsigned payload[$];
  rdma_sge sges[$];
  longint unsigned registration_ids[$];
  rdma_dma_mapping mappings[$];
  rdma_function_handle function_h;
  int unsigned function_generation;
  // A receipt copy is a data snapshot only; the release capability remains
  // bound to the original writer-issued object and is never duplicated by
  // uvm_object::copy().
  local uvm_object release_owner;

  // 功能：构造 rdma_sq_payload_write_receipt，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：verified=1'b0；released=1'b0；function_h=null；function_generation='0；release_owner=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_sq_payload_write_receipt 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_sq_payload_write_receipt");
    super.new(name);
    verified = 1'b0;
    released = 1'b0;
    function_h = null;
    function_generation = '0;
    release_owner = null;
  endfunction

  // The writer is the only production caller of these helpers.  The
  // one-shot bind prevents a receipt copy from acquiring the capability.
  // 功能：在 rdma_sq_payload_write_receipt 中，bind_release_owner 把 bind_release_owner 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：owner（输入）；bind_release_owner 先依据 release_owner == null && owner != null 校验 owner；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  function void bind_release_owner(uvm_object owner);
    if (release_owner == null && owner != null)
      release_owner = owner;
  endfunction

  // 功能：在 rdma_sq_payload_write_receipt 中，release_authority_matches 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：owner（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_authority_matches 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function bit release_authority_matches(uvm_object owner);
    return release_owner != null && owner != null && release_owner == owner;
  endfunction

  // 功能：将 rhs 中 rdma_sq_payload_write_receipt 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（payload receipt copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_sq_payload_write_receipt source;
    rdma_sge sge_copy;
    rdma_dma_mapping mapping_copy;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "payload receipt copy type mismatch")

    verified = source.verified;
    released = source.released;
    payload = source.payload;
    registration_ids = source.registration_ids;
    function_generation = source.function_generation;
    release_owner = null;
    sges.delete();
    mappings.delete();
    function_h = null;

    if (source.function_h != null) begin
      function_h = rdma_deep_copy#(rdma_function_handle)::of(
        source.function_h, "payload receipt function copy mismatch");
    end
    foreach (source.sges[i]) begin
      if (source.sges[i] == null) begin
        sges.push_back(null);
      end
      else begin
        sge_copy = rdma_sge::type_id::create($sformatf("receipt_sge_%0d", i));
        sge_copy.copy(source.sges[i]);
        sges.push_back(sge_copy);
      end
    end
    foreach (source.mappings[i]) begin
      if (source.mappings[i] == null) begin
        mappings.push_back(null);
      end
      else begin
        mapping_copy = rdma_deep_copy#(rdma_dma_mapping)::of(
          source.mappings[i], "payload receipt mapping copy mismatch");
        mappings.push_back(mapping_copy);
      end
    end
  endfunction

endclass

virtual class rdma_sq_payload_writer extends uvm_object;
  // 抽象接口把“注册映射”和“写入验证”与队列数据引擎解耦。

  // 功能：构造 rdma_sq_payload_writer，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_sq_payload_writer 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_sq_payload_writer");
    super.new(name);
  endfunction

  // 功能：在 rdma_sq_payload_writer 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：api（输入）、binding（输入）、timeout（输入）；configure 先依据 依赖存在性、authority 和 generation 条件 校验 api、binding、timeout；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  pure virtual function rdma_status configure(
    rdma_host_mem_api api,
    rdma_function_binding binding,
    time timeout
  );

  // 功能：在 rdma_sq_payload_writer 中，register_mapping 把 register_mapping 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：mapping（输入）、registration_id（输出）；register_mapping 先依据 依赖存在性、authority 和 generation 条件 校验 mapping、registration_id；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  pure virtual function rdma_status register_mapping(
    rdma_dma_mapping mapping,
    output longint unsigned registration_id
  );

  // 功能：在 rdma_sq_payload_writer 中，unregister_mapping unregister_mapping 解除指定资源绑定并隔离 runtime/映射，避免旧句柄在删除后访问后端。
  // 输入/输出及副作用：registration_id（输入）；unregister_mapping 读取 registration_id 并使用字段 name、next_id、api、binding、timeout；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：unregister_mapping 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  pure virtual function rdma_status unregister_mapping(
    longint unsigned registration_id
  );

  // 功能：在 rdma_sq_payload_write_receipt 中，stage_and_verify 预检输入并预留事务所需的槽位、映射或中间状态，失败时保留可恢复证据。
  // 输入/输出及副作用：request_context（输入）、sges（输入）、payload（输入）、receipt（输出）；stage_and_verify 读取 request_context、sges、payload、receipt 并使用字段 name、next_id、api、binding、timeout，并写入 receipt；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：stage_and_verify 无返回值，仅执行 name="rdma_host_mem_sq_payload_writer")、next_id=1、api=null、binding=null；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  pure virtual function rdma_status stage_and_verify(
    rdma_dma_request_context request_context,
    rdma_sge sges[$],
    byte unsigned payload[$],
    output rdma_sq_payload_write_receipt receipt
  );

  // 功能：在 rdma_sq_payload_writer 中，release_receipt 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：receipt（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_receipt 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  pure virtual function rdma_status release_receipt(
    rdma_sq_payload_write_receipt receipt
  );
endclass

class rdma_host_mem_sq_payload_writer extends rdma_sq_payload_writer;
  // 默认实现使用真实 rdma_host_mem_api；所有写入前检查必须先完成。
  `uvm_object_utils(rdma_host_mem_sq_payload_writer)

  typedef struct {
    longint unsigned id;
    rdma_dma_mapping mapping;
    int unsigned refs;
  } registration_t;

  rdma_host_mem_api api;
  rdma_function_binding binding;
  time timeout;
  registration_t regs[$];
  longint unsigned next_id;

  // registration_t 的 refs 记录仍被 receipt 引用的注册项数量。

  // 功能：构造 rdma_host_mem_sq_payload_writer，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：next_id=1；api=null；binding=null；timeout=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_host_mem_sq_payload_writer 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_host_mem_sq_payload_writer");
    super.new(name);
    next_id = 1;
    api = null;
    binding = null;
    timeout = 0;
  endfunction

  // 功能：在 rdma_host_mem_sq_payload_writer 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：api（输入）、binding（输入）、timeout（输入）；configure 先依据 api == null || binding == null 校验 api、binding、timeout；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status configure(
    rdma_host_mem_api api,
    rdma_function_binding binding,
    time timeout
  );
    if (api == null || binding == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "host memory API and binding are required");
    this.api = api;
    this.binding = binding;
    this.timeout = timeout;
    return rdma_status::success();
  endfunction

  // 注册只保存 detached authority；重叠区间和溢出必须在登记阶段拒绝。
  // 功能：在 rdma_host_mem_sq_payload_writer 中，register_mapping 把 register_mapping 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：mapping（输入）、registration_id（输出）；register_mapping 先依据 mapping == null；mapping.state != RDMA_MAPPING_ACTIVE || mapping.size == 0；mapping.iova.value > (64'hffff_ffff_ffff_ffff - (mapping.size - 1'b1 校验 mapping、registration_id；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  function rdma_status register_mapping(
    rdma_dma_mapping mapping,
    output longint unsigned registration_id
  );
    registration_t registration;
    rdma_dma_mapping mapping_copy;
    longint unsigned mapping_last;
    longint unsigned other_last;

    registration_id = 0;
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE || mapping.size == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mapping must be active and non-empty");
    if (mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - (mapping.size - 1'b1)))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "mapping range end overflows 64 bits");
    mapping_last = mapping.iova.value + mapping.size - 1'b1;
    foreach (regs[i]) begin
      other_last = regs[i].mapping.iova.value + regs[i].mapping.size - 1'b1;
      if (!(mapping.iova.value > other_last ||
            regs[i].mapping.iova.value > mapping_last))
        return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                 "mapping overlaps registration");
    end
    if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(mapping, mapping_copy))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mapping clone failed");

    registration.id = next_id;
    registration.mapping = mapping_copy;
    registration.refs = 0;
    regs.push_back(registration);
    registration_id = next_id;
    next_id++;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_host_mem_sq_payload_writer 中，unregister_mapping unregister_mapping 解除指定资源绑定并隔离 runtime/映射，避免旧句柄在删除后访问后端。
  // 输入/输出及副作用：registration_id（输入）；unregister_mapping 读取 registration_id 并使用字段 rdma_status、regs、id、refs；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：unregister_mapping 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function rdma_status unregister_mapping(longint unsigned registration_id);
    foreach (regs[i]) begin
      if (regs[i].id != registration_id)
        continue;
      if (regs[i].refs != 0)
        return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                 "mapping is referenced by a live receipt");
      regs.delete(i);
      return rdma_status::success();
    end
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "unknown registration id");
  endfunction

  // 功能：contains_id 比较 ids、id 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：ids（输入）、id（输入）；contains_id 读取 ids、id 并使用字段 i；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：contains_id 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  function automatic bit contains_id(
    longint unsigned ids[$],
    longint unsigned id
  );
    foreach (ids[i])
      if (ids[i] == id)
        return 1'b1;
    return 1'b0;
  endfunction

  // 功能：identity_status 校验 request_context 与当前对象状态的一致性，并显式处理“writer binding is not configured”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：request_context（输入）；identity_status 读取 request_context 并使用字段 expected；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：identity_status 返回 RDMA_SC_INVALID_STATE、RDMA_SC_DMA_TRANSLATION、RDMA_SC_STALE_GENERATION；典型拒绝条件为“writer binding is not configured”“request Function does not match binding”；失败路径不提交部分状态或转移未声明资源。
  function automatic rdma_status identity_status(
    rdma_dma_request_context request_context
  );
    rdma_function_handle expected;

    if (binding == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "writer binding is not configured");
    expected = binding.make_handle();
    if (request_context.function_h.function_uid != expected.function_uid ||
        request_context.function_h.object_id != expected.object_id)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "request Function does not match binding");
    if (request_context.function_h.generation != expected.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "request Function generation is stale");
    if (request_context.requester_bdf != binding.queue_dma.requester_bdf)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "requester BDF does not match binding");
    if (request_context.pasid_valid != binding.queue_dma.pasid_valid ||
        (request_context.pasid_valid ? request_context.pasid : '0) !=
        (binding.queue_dma.pasid_valid ? binding.queue_dma.pasid : '0))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "requester PASID does not match binding");
    if (request_context.dma_domain_valid != binding.queue_dma.dma_domain_valid ||
        request_context.dma_domain_id != binding.queue_dma.dma_domain_id)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA domain does not match binding");
    return rdma_status::success();
  endfunction

  // 功能：build_receipt_candidate 依据已通过权限/范围预检的请求数据建立
  // receipt 值快照，一次性完成 receipt、Function、SGE 和 mapping 的
  // 工厂/clone 检查。
  // 输入/输出及副作用：request_context、sges、payload、registration_ids
  // （输入）；candidate（输出）；函数只创建本地 detached 对象，不修改
  // regs.ref、Host-memory 或调用方输入；成功时返回含 payload、registration_ids、
  // function_h、sges、mappings 和 release owner 的候选 receipt。
  // 失败/边界：request_context/Function/SGE/mapping 为空、registration_ids
  // 为空、任一 UVM 工厂返回 null、copy/clone 失败或映射查找失败时返回明确
  // 失败；candidate 在任何失败分支保持 null，调用方不得在该阶段发布引用或
  // 写入 Host-memory。
  function rdma_status build_receipt_candidate(
    rdma_dma_request_context request_context,
    rdma_sge sges[$],
    byte unsigned payload[$],
    longint unsigned registration_ids[$],
    output rdma_sq_payload_write_receipt candidate
  );
    rdma_sq_payload_write_receipt staged;
    rdma_function_handle function_copy;
    rdma_sge sge_copy;
    rdma_dma_mapping mapping_copy;
    bit found;

    candidate = null;
    if (request_context == null)
      return rdma_status::make_direct(
          RDMA_SC_INVALID_ARGUMENT,
          "receipt candidate request context is null");
    if (request_context.function_h == null)
      return rdma_status::make_direct(
          RDMA_SC_INVALID_ARGUMENT,
          "receipt candidate Function is null");
    if (registration_ids.size() == 0)
      return rdma_status::make_direct(
          RDMA_SC_INVALID_ARGUMENT,
          "receipt candidate has no registration ids");

    staged = rdma_sq_payload_write_receipt::type_id::create(
      "receipt_candidate"
    );
    if (staged == null)
      return rdma_status::make_direct(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "receipt candidate allocation failed");
    staged.verified = 1'b1;
    staged.released = 1'b0;
    staged.payload = payload;
    staged.registration_ids = registration_ids;
    staged.function_generation = request_context.function_h.generation;
    staged.bind_release_owner(this);

    function_copy = rdma_function_handle::type_id::create(
      "receipt_candidate_function"
    );
    if (function_copy == null)
      return rdma_status::make_direct(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "receipt candidate Function allocation failed");
    function_copy.copy(request_context.function_h);
    staged.function_h = function_copy;

    foreach (sges[i]) begin
      if (sges[i] == null)
        return rdma_status::make_direct(
            RDMA_SC_INVALID_ARGUMENT,
            "receipt candidate SGE is null");
      sge_copy = rdma_sge::type_id::create(
        $sformatf("receipt_candidate_sge_%0d", i)
      );
      if (sge_copy == null)
        return rdma_status::make_direct(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "receipt candidate SGE allocation failed");
      sge_copy.copy(sges[i]);
      staged.sges.push_back(sge_copy);
    end

    foreach (registration_ids[i]) begin
      found = 1'b0;
      foreach (regs[j]) begin
        if (regs[j].id != registration_ids[i])
          continue;
        found = 1'b1;
        if (regs[j].mapping == null)
          return rdma_status::make_direct(
              RDMA_SC_INVALID_STATE,
              "receipt candidate mapping is null");
        if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(regs[j].mapping, mapping_copy))
          return rdma_status::make_direct(
              RDMA_SC_INVALID_STATE,
              "receipt candidate mapping snapshot failed");
        staged.mappings.push_back(mapping_copy);
        break;
      end
      if (!found)
        return rdma_status::make_direct(
            RDMA_SC_INVALID_STATE,
            "receipt candidate registration disappeared");
    end

    candidate = staged;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_host_mem_sq_payload_writer 中，stage_and_verify 预检输入并预留事务所需的槽位、映射或中间状态，失败时保留可恢复证据。
  // 输入/输出及副作用：request_context（输入）、sges（输入）、payload（输入）、receipt（输出）；stage_and_verify 读取 request_context、sges、payload、receipt 并使用字段 receipt、status、total、permissions、permissions.device_read、map_index、access_failure、payload_offset，并写入 receipt；函数返回 rdma_status，不取得调用方资源所有权。
  // 设计约束：先完成 context、长度、注册项、权限和地址范围检查，再产生任何 host 写入。
  // 失败/边界：stage_and_verify 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_DMA_TRANSLATION；典型拒绝条件为“writer is not configured”“request context is null”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status stage_and_verify(
    rdma_dma_request_context request_context,
    rdma_sge sges[$],
    byte unsigned payload[$],
    output rdma_sq_payload_write_receipt receipt
  );
    rdma_status status;
    rdma_dma_permission_t permissions;
    longint unsigned total;
    longint unsigned payload_offset;
    longint unsigned registration_ids[$];
    int map_indices[$];
    int map_index;
    rdma_status access_failure;
    byte unsigned chunk_queue[$];
    byte unsigned readback_queue[$];
    byte chunk[];
    byte readback[];
    rdma_sq_payload_write_receipt candidate;

    receipt = null;
    if (api == null || binding == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "writer is not configured");
    if (request_context == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "request context is null");

    status = rdma_status::nonnull(
      request_context.validate(),
      "DMA request context validation returned null status"
    );
    if (!status.ok())
      return status;

    status = rdma_status::nonnull(
      identity_status(request_context),
      "writer identity validation returned null status"
    );
    if (!status.ok())
      return status;
    if (sges.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "at least one SGE is required");

    total = 0;
    foreach (sges[i]) begin
      if (sges[i] == null || sges[i].length == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SGE is null or empty");
      if (total > (64'hffff_ffff_ffff_ffff - sges[i].length))
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "payload length overflows 64 bits");
      total += sges[i].length;
    end
    if (total != payload.size())
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "payload length does not match SGE lengths");

    permissions = '0;
    permissions.device_read = 1'b1;
    foreach (sges[i]) begin
      map_index = -1;
      access_failure = null;
      foreach (regs[j]) begin
        status = regs[j].mapping.check_access(
          request_context.function_h,
          request_context.requester_bdf,
          request_context.pasid_valid,
          request_context.pasid,
          request_context.dma_domain_valid,
          request_context.dma_domain_id,
          sges[i].iova,
          sges[i].length,
          RDMA_DMA_DEVICE_READ,
          permissions
        );
        if (status == null) begin
          status = rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "DMA mapping access check returned null status");
        end
        if (status.ok()) begin
          map_index = j;
          break;
        end
        if (access_failure == null)
          access_failure = status;
      end
      if (map_index < 0) begin
        if (access_failure != null &&
            access_failure.code inside {RDMA_SC_INVALID_STATE,
                                        RDMA_SC_DMA_PERMISSION,
                                        RDMA_SC_STALE_GENERATION})
          return access_failure;
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "SGE is not covered by a registered mapping");
      end
      map_indices.push_back(map_index);
      if (!contains_id(registration_ids, regs[map_index].id))
        registration_ids.push_back(regs[map_index].id);
    end

    // 上面的预检和 receipt 快照构建全部完成后才触碰 host memory，并发布
    // registration 引用；这样 late factory/clone 失败不会留下引用或写入。
    status = build_receipt_candidate(
      request_context,
      sges,
      payload,
      registration_ids,
      candidate
    );
    if (status == null)
      return rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "receipt candidate staging returned null status");
    if (!status.ok())
      return status;

    // All candidate factories/clones are complete before any host-memory I/O
    // or registration reference publication.
    foreach (registration_ids[k]) begin
      foreach (regs[j])
        if (regs[j].id == registration_ids[k])
          regs[j].refs++;
    end

    payload_offset = 0;
    foreach (sges[i]) begin
      map_index = map_indices[i];
      chunk_queue.delete();
      for (int unsigned k = 0; k < sges[i].length; k++)
        chunk_queue.push_back(payload[payload_offset + k]);
      chunk = new[chunk_queue.size()];
      foreach (chunk_queue[k])
        chunk[k] = chunk_queue[k];
      status = api.write(
        regs[map_index].mapping,
        sges[i].iova.value - regs[map_index].mapping.iova.value,
        chunk
      );
      if (status == null) begin
        release_ids(registration_ids);
        return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Host-memory write returned null status");
      end
      if (!status.ok()) begin
        release_ids(registration_ids);
        return status;
      end

      readback_queue.delete();
      status = api.read(
        regs[map_index].mapping,
        sges[i].iova.value - regs[map_index].mapping.iova.value,
        sges[i].length,
        readback
      );
      if (status == null) begin
        release_ids(registration_ids);
        return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Host-memory read returned null status");
      end
      if (!status.ok()) begin
        release_ids(registration_ids);
        return status;
      end
      if (readback.size() != chunk.size()) begin
        release_ids(registration_ids);
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "staged payload readback length mismatch");
      end
      foreach (chunk[k]) begin
        if (readback[k] !== chunk[k]) begin
          release_ids(registration_ids);
          return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                   "staged payload readback mismatch");
        end
      end
      payload_offset += sges[i].length;
    end
    receipt = candidate;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_host_mem_sq_payload_writer 中，release_ids 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：ids（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_ids 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function void release_ids(longint unsigned ids[$]);
    foreach (ids[i]) begin
      foreach (regs[j]) begin
        if (regs[j].id == ids[i] && regs[j].refs != 0) begin
          regs[j].refs--;
          break;
        end
      end
    end
  endfunction

  // abort 或 SQ record retire 时调用；released 标志保证引用只递减一次。
  // 功能：在 rdma_host_mem_sq_payload_writer 中，release_receipt 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：receipt（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_receipt 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function rdma_status release_receipt(rdma_sq_payload_write_receipt receipt);
    if (receipt == null || receipt.released)
      return rdma_status::success();
    if (!receipt.release_authority_matches(this))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "receipt release authority is not owned by writer");
    release_ids(receipt.registration_ids);
    receipt.released = 1'b1;
    return rdma_status::success();
  endfunction
endclass
