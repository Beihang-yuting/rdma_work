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

  function new(string name = "rdma_sq_payload_write_receipt");
    super.new(name);
    verified = 1'b0;
    released = 1'b0;
    function_h = null;
    function_generation = '0;
  endfunction

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

  function new(string name = "rdma_sq_payload_writer");
    super.new(name);
  endfunction

  pure virtual function rdma_status configure(
    rdma_host_mem_api api,
    rdma_function_binding binding,
    time timeout
  );

  pure virtual function rdma_status register_mapping(
    rdma_dma_mapping mapping,
    output longint unsigned registration_id
  );

  pure virtual function rdma_status unregister_mapping(
    longint unsigned registration_id
  );

  pure virtual function rdma_status stage_and_verify(
    rdma_dma_request_context request_context,
    rdma_sge sges[$],
    byte unsigned payload[$],
    output rdma_sq_payload_write_receipt receipt
  );

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

  function new(string name = "rdma_host_mem_sq_payload_writer");
    super.new(name);
    next_id = 1;
    api = null;
    binding = null;
    timeout = 0;
  endfunction

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

  function automatic bit contains_id(
    longint unsigned ids[$],
    longint unsigned id
  );
    foreach (ids[i])
      if (ids[i] == id)
        return 1'b1;
    return 1'b0;
  endfunction

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
  function rdma_status release_receipt(rdma_sq_payload_write_receipt receipt);
    if (receipt == null || receipt.released)
      return rdma_status::success();
    release_ids(receipt.registration_ids);
    receipt.released = 1'b1;
    return rdma_status::success();
  endfunction
endclass
