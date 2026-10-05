// 目录：核心执行层 core/rdma_sq_payload_writer.sv。
// 职责：staged non-inline SQ payload 的 mapping 注册、Host-memory 写入与逐字节回读校验。
// 依赖：host_mem API、function binding、DMA request context 与 mapping/SGE 值类型。
// 所有权与生命周期：writer 保存 mapping 副本；receipt 为 detached 快照，释放能力只绑定签发它的 writer。

// 中文说明：本文件实现 staged non-inline payload 的注册、写入和逐字节回读校验。
// 生命周期约束：writer 只借用 caller-owned mapping，不取得 host_mem.release() 权限。

class rdma_sq_payload_write_receipt extends uvm_object;
  // receipt 保存 detached 的 payload/SGE 快照，供后续 record 生命周期使用。
  `rdma_object_utils(rdma_sq_payload_write_receipt)

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

  // 功能：构造 receipt，verified/released 置 0，function_h/release_owner 置 null。
  // 输入/输出及副作用：name 传给 UVM 父类；不绑定外部依赖。
  // 失败/边界：无；依赖须由后续 configure 注入。
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
  // 功能：一次性绑定 release owner（仅 writer 调用），防止 receipt 拷贝获得释放能力。
  // 输入/输出及副作用：owner 为输入；仅当 release_owner 为空且 owner 非空时记录。
  // 失败/边界：已绑定或 owner 为空时静默忽略。
  function void bind_release_owner(uvm_object owner);
    if (release_owner == null && owner != null)
      release_owner = owner;
  endfunction

  // 功能：判断 owner 是否为该 receipt 绑定的 release owner。
  // 输入/输出及副作用：owner 为输入；返回 bit，无副作用。
  // 失败/边界：任一方为 null 返回 0。
  function bit release_authority_matches(uvm_object owner);
    return release_owner != null && owner != null && release_owner == owner;
  endfunction

  // 功能：把 rhs 的值字段复制为隔离快照（SGE/mapping 深拷贝）。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，不修改 rhs。
  // 失败/边界：类型不匹配或 clone/cast 失败时触发 UVM fatal。
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
        sge_copy = source.sges[i].duplicate();
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

  // 功能：构造抽象 writer 基类。
  // 输入/输出及副作用：name 传给 UVM 父类；不绑定外部依赖。
  // 失败/边界：无；依赖须由后续 configure 注入。
  function new(string name = "rdma_sq_payload_writer");
    super.new(name);
  endfunction

  // 功能：注入 host_mem API、binding 与访问超时（纯虚接口）。
  // 输入/输出及副作用：api/binding/timeout 为输入；返回 status。
  // 失败/边界：由具体实现定义。
  pure virtual function rdma_status configure(
    rdma_host_mem_api api,
    rdma_function_binding binding,
    time timeout
  );

  // 功能：登记一个 DMA mapping，返回 registration_id（纯虚接口）。
  // 输入/输出及副作用：mapping 为输入；registration_id 为输出。
  // 失败/边界：由具体实现定义。
  pure virtual function rdma_status register_mapping(
    rdma_dma_mapping mapping,
    output longint unsigned registration_id
  );

  // 功能：按 registration_id 注销 mapping（纯虚接口）。
  // 输入/输出及副作用：registration_id 为输入；返回 status。
  // 失败/边界：由具体实现定义。
  pure virtual function rdma_status unregister_mapping(
    longint unsigned registration_id
  );

  // 功能：预检、写入并回读校验 payload，产出 receipt（纯虚接口）。
  // 输入/输出及副作用：request_context/sges/payload 为输入；receipt 为输出；写 Host-memory。
  // 失败/边界：由具体实现定义。
  pure virtual function rdma_status stage_and_verify(
    rdma_dma_request_context request_context,
    rdma_sge sges[$],
    byte unsigned payload[$],
    output rdma_sq_payload_write_receipt receipt
  );

  // 功能：释放 receipt 持有的 mapping 引用（纯虚接口）。
  // 输入/输出及副作用：receipt 为输入；返回 status。
  // 失败/边界：由具体实现定义。
  pure virtual function rdma_status release_receipt(
    rdma_sq_payload_write_receipt receipt
  );
endclass

class rdma_host_mem_sq_payload_writer extends rdma_sq_payload_writer;
  // 默认实现使用真实 rdma_host_mem_api；所有写入前检查必须先完成。
  `rdma_object_utils(rdma_host_mem_sq_payload_writer)

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

  // 功能：构造 writer，next_id=1，api/binding 为 null，timeout=0。
  // 输入/输出及副作用：name 传给 UVM 父类；不绑定外部依赖。
  // 失败/边界：无；依赖须由后续 configure 注入。
  function new(string name = "rdma_host_mem_sq_payload_writer");
    super.new(name);
    next_id = 1;
    api = null;
    binding = null;
    timeout = 0;
  endfunction

  // 功能：保存 host_mem API、binding 与访问超时。
  // 输入/输出及副作用：api/binding/timeout 为输入；保存引用，不取得所有权。
  // 失败/边界：api 或 binding 为 null 返回 INVALID_ARGUMENT，不覆盖旧配置。
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
  // 功能：校验并登记 mapping 副本，分配 registration_id。
  // 输入/输出及副作用：mapping 为输入；registration_id 为输出（失败为 0）；写 regs，next_id 自增。
  // 失败/边界：null、非 ACTIVE 或空返回 INVALID_ARGUMENT/INVALID_STATE；区间溢出返回
  //   DMA_TRANSLATION；与已登记区间重叠返回 RESOURCE_BUSY；clone 失败返回 INVALID_STATE。
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

  // 功能：注销 registration_id 对应的 mapping。
  // 输入/输出及副作用：registration_id 为输入；从 regs 删除条目。
  // 失败/边界：仍被 live receipt 引用返回 RESOURCE_BUSY；未知 ID 返回 INVALID_ARGUMENT。
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

  // 功能：判断 ids 中是否包含 id。
  // 输入/输出及副作用：ids/id 为输入；返回 bit，无副作用。
  // 失败/边界：无。
  function automatic bit contains_id(
    longint unsigned ids[$],
    longint unsigned id
  );
    foreach (ids[i])
      if (ids[i] == id)
        return 1'b1;
    return 1'b0;
  endfunction

  // 功能：校验 request_context 与 binding 的 Function、generation、BDF、PASID、DMA domain 一致。
  // 输入/输出及副作用：request_context 为输入；返回 status，无副作用。
  // 失败/边界：binding 未配置返回 INVALID_STATE；generation 过期返回 STALE_GENERATION；
  //   其余不一致返回 DMA_TRANSLATION。
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

  // 功能：由已预检的请求数据构建 detached receipt 候选，并检查各 factory/clone。
  // 输入/输出及副作用：request_context/sges/payload/registration_ids 为输入；candidate 为输出；
  //   只创建本地对象，不改 regs.ref 或 Host-memory。
  // 失败/边界：输入为空、factory 返回 null、clone 失败或 mapping 查找失败时返回失败，
  //   candidate 保持 null，调用方不得发布引用或写 Host-memory。
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

  // 功能：校验 context、SGE、权限与 mapping 覆盖后写 Host-memory 并逐字节回读，产出 receipt。
  // 输入/输出及副作用：request_context/sges/payload 为输入；receipt 为输出；成功时写 Host-memory
  //   并递增所覆盖 mapping 的 refs。
  // 设计约束：所有检查与 receipt 快照构建先于任何 host 写入。
  // 失败/边界：未配置返回 INVALID_STATE；context/SGE/长度非法返回 INVALID_ARGUMENT；
  //   mapping 未覆盖、长度溢出、写读失败或回读不一致返回 DMA_TRANSLATION 或底层错误。
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

    // 预检与 receipt 构建全部完成后才触碰 host memory 并发布引用，避免 late 失败留下残留。
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

    // 同上：所有 factory/clone 完成后才进行 Host-memory I/O 与引用发布。
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

  // 功能：对每个 registration id 递减一次 refs。
  // 输入/输出及副作用：ids 为输入；修改 regs[].refs。
  // 失败/边界：未知 ID 或 refs 已为 0 时忽略。
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
  // 功能：释放 receipt 持有的 mapping 引用，released 标志保证只递减一次。
  // 输入/输出及副作用：receipt 为输入；递减 refs 并置 receipt.released。
  // 失败/边界：null 或已释放视为成功；release owner 不是本 writer 返回 INVALID_ARGUMENT。
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
