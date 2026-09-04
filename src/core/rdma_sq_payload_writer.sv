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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
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
  // 功能：把指定资源或后端能力绑定到当前对象的唯一索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：输入为待绑定资源/后端引用；成功后新增一条受 identity 保护的关联记录。
  //   重复绑定、资源类型错误或依赖缺失时不留下部分关联。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  function void bind_release_owner(uvm_object owner);
    if (release_owner == null && owner != null)
      release_owner = owner;
  endfunction

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  function bit release_authority_matches(uvm_object owner);
    return release_owner != null && owner != null && release_owner == owner;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_sq_payload_write_receipt source;
    uvm_object cloned;
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
      cloned = source.function_h.clone();
      if (cloned == null || !$cast(function_h, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "payload receipt function copy mismatch")
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
        cloned = source.mappings[i].clone();
        if (cloned == null || !$cast(mapping_copy, cloned))
          `uvm_fatal("RDMA_COPY_TYPE", "payload receipt mapping copy mismatch")
        mappings.push_back(mapping_copy);
      end
    end
  endfunction

endclass

virtual class rdma_sq_payload_writer extends uvm_object;
  // 抽象接口把“注册映射”和“写入验证”与队列数据引擎解耦。

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_sq_payload_writer");
    super.new(name);
  endfunction

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
  pure virtual function rdma_status configure(
    rdma_host_mem_api api,
    rdma_function_binding binding,
    time timeout
  );

  // 功能：把指定资源或后端能力绑定到当前对象的唯一索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：输入为待绑定资源/后端引用；成功后新增一条受 identity 保护的关联记录。
  //   重复绑定、资源类型错误或依赖缺失时不留下部分关联。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  pure virtual function rdma_status register_mapping(
    rdma_dma_mapping mapping,
    output longint unsigned registration_id
  );

  // 功能：解除指定资源绑定并隔离其 runtime/映射，避免旧句柄在删除后继续访问后端。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  pure virtual function rdma_status unregister_mapping(
    longint unsigned registration_id
  );

  // 功能：处理 stage_and_verify：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 request_context, sges, payload, receipt 用于执行 stage_and_verify；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：stage_and_verify 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  pure virtual function rdma_status stage_and_verify(
    rdma_dma_request_context request_context,
    rdma_sge sges[$],
    byte unsigned payload[$],
    output rdma_sq_payload_write_receipt receipt
  );

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_host_mem_sq_payload_writer");
    super.new(name);
    next_id = 1;
    api = null;
    binding = null;
    timeout = 0;
  endfunction

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
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
  // 功能：把指定资源或后端能力绑定到当前对象的唯一索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：输入为待绑定资源/后端引用；成功后新增一条受 identity 保护的关联记录。
  //   重复绑定、资源类型错误或依赖缺失时不留下部分关联。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  function rdma_status register_mapping(
    rdma_dma_mapping mapping,
    output longint unsigned registration_id
  );
    registration_t registration;
    uvm_object cloned;
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
    cloned = mapping.clone();
    if (cloned == null || !$cast(mapping_copy, cloned))
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

  // 功能：解除指定资源绑定并隔离其 runtime/映射，避免旧句柄在删除后继续访问后端。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
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

  // 功能：处理 contains_id：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 ids, id 用于执行 contains_id；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：contains_id 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic bit contains_id(
    longint unsigned ids[$],
    longint unsigned id
  );
    foreach (ids[i])
      if (ids[i] == id)
        return 1'b1;
    return 1'b0;
  endfunction

  // 功能：处理 identity_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 request_context 用于执行 identity_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：identity_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 先完成 context、长度、注册项、权限和地址范围检查，再产生任何 host 写入。
  // 功能：处理 stage_and_verify：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 request_context, sges, payload, receipt 用于执行 stage_and_verify；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：stage_and_verify 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
    status = request_context.validate();
    if (!status.ok())
      return status;
    status = identity_status(request_context);
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

    // 上面的预检全部完成后才触碰 host memory，并发布 registration 引用。
    // All checks above are intentionally complete before touching host memory
    // or publishing reference counts.
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

    candidate = rdma_sq_payload_write_receipt::type_id::create("receipt");
    candidate.verified = 1'b1;
    candidate.released = 1'b0;
    candidate.payload = payload;
    candidate.registration_ids = registration_ids;
    candidate.function_generation = request_context.function_h.generation;
    candidate.bind_release_owner(this);
    candidate.function_h = rdma_function_handle::type_id::create(
      "receipt_function");
    candidate.function_h.copy(request_context.function_h);
    foreach (sges[i]) begin
      rdma_sge sge_copy;
      sge_copy = rdma_sge::type_id::create($sformatf("receipt_sge_%0d", i));
      sge_copy.copy(sges[i]);
      candidate.sges.push_back(sge_copy);
    end
    foreach (registration_ids[i]) begin
      foreach (regs[j]) begin
        if (regs[j].id == registration_ids[i]) begin
          uvm_object cloned;
          rdma_dma_mapping mapping_copy;
          cloned = regs[j].mapping.clone();
          if (cloned == null || !$cast(mapping_copy, cloned)) begin
            release_ids(registration_ids);
            return rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "receipt mapping snapshot failed");
          end
          candidate.mappings.push_back(mapping_copy);
        end
      end
    end
    receipt = candidate;
    return rdma_status::success();
  endfunction

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
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
  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
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
