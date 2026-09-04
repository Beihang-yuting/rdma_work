// 目录：核心执行层 core/rdma_doorbell_scheduler.sv。
// 职责：实现 rdma_doorbell_scheduler 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_doorbell_scheduler.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit {
  RDMA_DB_DEP_PAYLOAD       = 1'b0,
  RDMA_DB_DEP_QUEUE_CONTEXT = 1'b1
} rdma_doorbell_dependency_stage_e;

typedef enum bit [1:0] {
  RDMA_DB_BARRIER_NONE     = 2'b00,
  RDMA_DB_BARRIER_DMA      = 2'b01,
  RDMA_DB_BARRIER_MMIO     = 2'b10,
  RDMA_DB_BARRIER_DMA_MMIO = 2'b11
} rdma_doorbell_barrier_policy_e;

typedef enum bit {
  RDMA_DB_WRITE_NON_COMBINING = 1'b0,
  RDMA_DB_WRITE_COMBINING     = 1'b1
} rdma_doorbell_write_combining_policy_e;

typedef enum bit {
  RDMA_DB_READBACK_NONE     = 1'b0,
  RDMA_DB_READBACK_REQUIRED = 1'b1
} rdma_doorbell_readback_policy_e;

class rdma_doorbell_dependency extends uvm_object;
  `uvm_object_utils(rdma_doorbell_dependency)

  longint unsigned dependency_id;
  rdma_doorbell_dependency_stage_e stage;
  rdma_dma_mapping mapping;
  longint unsigned relative_offset;
  rdma_hw_image image;
  bit ready;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_doorbell_dependency");
    super.new(name);
    dependency_id = '0;
    stage = RDMA_DB_DEP_PAYLOAD;
    mapping = null;
    relative_offset = '0;
    image = null;
    ready = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_doorbell_dependency rhs_dependency;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_dependency, rhs))
      `uvm_fatal("RDMA_COPY_TYPE",
                 "rdma_doorbell_dependency copy type mismatch")
    dependency_id = rhs_dependency.dependency_id;
    stage = rhs_dependency.stage;
    if (rhs_dependency.mapping == null) begin
      mapping = null;
    end
    else begin
      cloned_object = rhs_dependency.mapping.clone();
      if (cloned_object == null || !$cast(mapping, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "doorbell dependency mapping clone type mismatch")
    end
    relative_offset = rhs_dependency.relative_offset;
    if (rhs_dependency.image == null) begin
      image = null;
    end
    else begin
      cloned_object = rhs_dependency.image.clone();
      if (cloned_object == null || !$cast(image, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "doorbell dependency image clone type mismatch")
    end
    ready = rhs_dependency.ready;
  endfunction
endclass

class rdma_doorbell_desc extends uvm_object;
  `uvm_object_utils(rdma_doorbell_desc)

  rdma_doorbell_kind_e kind;
  rdma_function_handle function_h;
  rdma_handle target_h;
  bit [2:0] notify_bar_id;
  longint unsigned relative_offset;
  int unsigned width;
  rdma_byte_endian_e endian;
  rdma_hw_image payload_image;
  rdma_doorbell_barrier_policy_e barrier_policy;
  rdma_doorbell_write_combining_policy_e write_combining_policy;
  bit allow_merge;
  bit merge_requested;
  rdma_doorbell_dependency dependencies[$];
  // Maximum total elapsed SystemVerilog simulation time for submit(), from
  // entry through Function-lock acquisition and the final PCIe task. The value
  // is a simulation-time value, not a per-operation timeout. Callers should
  // assign an explicit time literal (for example, 100ns) so the intended unit
  // is independent of compilation-unit time settings.
  time timeout;
  rdma_doorbell_readback_policy_e readback_policy;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_doorbell_desc");
    super.new(name);
    kind = RDMA_DOORBELL_CMQ_SQ;
    function_h = null;
    target_h = null;
    notify_bar_id = '0;
    relative_offset = '0;
    width = '0;
    endian = RDMA_ENDIAN_LITTLE;
    payload_image = null;
    barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    allow_merge = 1'b0;
    merge_requested = 1'b0;
    dependencies.delete();
    timeout = '0;
    readback_policy = RDMA_DB_READBACK_NONE;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_doorbell_desc rhs_desc;
    rdma_doorbell_dependency cloned_dependency;
    rdma_doorbell_dependency dependency_clones[rdma_doorbell_dependency];
    rdma_dma_mapping mapping_clones[rdma_dma_mapping];
    rdma_hw_image image_clones[rdma_hw_image];
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_desc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_doorbell_desc copy type mismatch")
    kind = rhs_desc.kind;
    if (rhs_desc.function_h == null) begin
      function_h = null;
    end
    else begin
      cloned_object = rhs_desc.function_h.clone();
      if (cloned_object == null || !$cast(function_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "doorbell descriptor Function clone type mismatch")
    end
    if (rhs_desc.target_h == null) begin
      target_h = null;
    end
    else begin
      cloned_object = rhs_desc.target_h.clone();
      if (cloned_object == null || !$cast(target_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "doorbell descriptor target clone type mismatch")
    end
    notify_bar_id = rhs_desc.notify_bar_id;
    relative_offset = rhs_desc.relative_offset;
    width = rhs_desc.width;
    endian = rhs_desc.endian;
    if (rhs_desc.payload_image == null) begin
      payload_image = null;
    end
    else begin
      cloned_object = rhs_desc.payload_image.clone();
      if (cloned_object == null || !$cast(payload_image, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "doorbell payload image clone type mismatch")
      image_clones[rhs_desc.payload_image] = payload_image;
    end
    barrier_policy = rhs_desc.barrier_policy;
    write_combining_policy = rhs_desc.write_combining_policy;
    allow_merge = rhs_desc.allow_merge;
    merge_requested = rhs_desc.merge_requested;
    dependencies.delete();
    foreach (rhs_desc.dependencies[i]) begin
      if (rhs_desc.dependencies[i] == null) begin
        dependencies.push_back(null);
      end
      else if (dependency_clones.exists(rhs_desc.dependencies[i])) begin
        dependencies.push_back(dependency_clones[rhs_desc.dependencies[i]]);
      end
      else begin
        cloned_object = rhs_desc.dependencies[i].clone();
        if (cloned_object == null ||
            !$cast(cloned_dependency, cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE",
                     "doorbell dependency clone type mismatch")
        // UVM 1.2 suppresses a repeated nested copy while an outer copy is
        // active. Preserve source alias topology explicitly so two
        // dependencies sharing one mapping/image receive the same detached
        // value rather than a default-constructed second clone.
        if (rhs_desc.dependencies[i].mapping != null) begin
          if (mapping_clones.exists(rhs_desc.dependencies[i].mapping))
            cloned_dependency.mapping =
              mapping_clones[rhs_desc.dependencies[i].mapping];
          else
            mapping_clones[rhs_desc.dependencies[i].mapping] =
              cloned_dependency.mapping;
        end
        if (rhs_desc.dependencies[i].image != null) begin
          if (image_clones.exists(rhs_desc.dependencies[i].image))
            cloned_dependency.image =
              image_clones[rhs_desc.dependencies[i].image];
          else
            image_clones[rhs_desc.dependencies[i].image] =
              cloned_dependency.image;
        end
        dependency_clones[rhs_desc.dependencies[i]] = cloned_dependency;
        dependencies.push_back(cloned_dependency);
      end
    end
    timeout = rhs_desc.timeout;
    readback_policy = rhs_desc.readback_policy;
  endfunction
endclass

class rdma_doorbell_result extends uvm_object;
  `uvm_object_utils(rdma_doorbell_result)

  rdma_doorbell_kind_e kind;
  rdma_function_handle function_h;
  rdma_handle target_h;
  rdma_bar_addr_t absolute_address;
  int unsigned width;
  int unsigned dependency_count;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_doorbell_result");
    super.new(name);
    kind = RDMA_DOORBELL_CMQ_SQ;
    function_h = null;
    target_h = null;
    absolute_address = '0;
    width = '0;
    dependency_count = '0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_doorbell_result rhs_result;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_result, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_doorbell_result copy type mismatch")
    kind = rhs_result.kind;
    if (rhs_result.function_h == null) begin
      function_h = null;
    end
    else begin
      cloned_object = rhs_result.function_h.clone();
      if (cloned_object == null || !$cast(function_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "doorbell result Function clone type mismatch")
    end
    if (rhs_result.target_h == null) begin
      target_h = null;
    end
    else begin
      cloned_object = rhs_result.target_h.clone();
      if (cloned_object == null || !$cast(target_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "doorbell result target clone type mismatch")
    end
    absolute_address = rhs_result.absolute_address;
    width = rhs_result.width;
    dependency_count = rhs_result.dependency_count;
  endfunction
endclass

class rdma_doorbell_scheduler extends uvm_object;
  `uvm_object_utils(rdma_doorbell_scheduler)

  protected rdma_host_mem_api host_mem;
  protected rdma_pcie_api pcie;
  protected bit configured;
  protected semaphore function_locks[string];

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_doorbell_scheduler");
    super.new(name);
    host_mem = null;
    pcie = null;
    configured = 1'b0;
    function_locks.delete();
  endfunction

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
  function rdma_status configure(
    rdma_host_mem_api host_mem_arg,
    rdma_pcie_api pcie_arg
  );
    if (host_mem_arg == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "host memory adapter is null");
    if (pcie_arg == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PCIe adapter is null");
    if (configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "doorbell scheduler is already configured");
    host_mem = host_mem_arg;
    pcie = pcie_arg;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：处理 function_key：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 function_uid, object_id 用于执行 function_key；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：function_key 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function string function_key(
    longint unsigned function_uid,
    int unsigned object_id
  );
    return $sformatf("%016h:%08h", function_uid, object_id);
  endfunction

  // 功能：处理 lock_for：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 function_uid, object_id 用于执行 lock_for；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：lock_for 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function semaphore lock_for(
    longint unsigned function_uid,
    int unsigned object_id
  );
    string key;

    key = function_key(function_uid, object_id);
    if (!function_locks.exists(key))
      function_locks[key] = new(1);
    return function_locks[key];
  endfunction

  // 功能：处理 timeout_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 operation 用于执行 timeout_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：timeout_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status timeout_status(string operation);
    return rdma_status::make(
      RDMA_SC_TIMEOUT,
      {"doorbell submit deadline expired during ", operation}
    );
  endfunction

  // 功能：处理 deadline_remaining：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 deadline, remaining 用于执行 deadline_remaining；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：deadline_remaining 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function bit deadline_remaining(
    time deadline,
    output time remaining
  );
    if ($time >= deadline) begin
      remaining = 0;
      return 1'b0;
    end
    remaining = deadline - $time;
    return 1'b1;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  protected function rdma_status clone_binding_snapshot(
    rdma_function_binding source,
    output rdma_function_binding snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "function binding is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
      snapshot = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "function binding snapshot clone failed"
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  protected function rdma_status clone_desc_snapshot(
    rdma_doorbell_desc source,
    output rdma_doorbell_desc snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell descriptor is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
      snapshot = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "doorbell descriptor snapshot clone failed"
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：检查可用容量并预留所需资源，返回带所有权证据的分配结果；容量不足时不留下部分分配。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  protected task acquire_function_lock_before_deadline(
    semaphore function_lock,
    time deadline,
    output bit acquired,
    output rdma_status status
  );
    bit worker_acquired;
    time remaining;

    acquired = 1'b0;
    worker_acquired = 1'b0;
    if (!deadline_remaining(deadline, remaining)) begin
      status = timeout_status("Function lock acquisition");
      return;
    end
    if (function_lock.try_get(1)) begin
      acquired = 1'b1;
      status = rdma_status::success();
      return;
    end

    // Enclose the race in a per-invocation child process. A named-block
    // disable can reach concurrent activations of this task in some
    // simulators; this descendant-only disable cannot.
    fork
      begin : function_lock_deadline_scope
        fork
          begin : function_lock_worker
            function_lock.get(1);
            worker_acquired = 1'b1;
          end
          begin : function_lock_timer
            #(remaining);
          end
        join_any
        disable fork;
      end
    join

    if (!worker_acquired) begin
      status = timeout_status("Function lock acquisition");
      return;
    end
    acquired = 1'b1;
    status = rdma_status::success();
  endtask

  // 功能：处理 dma_barrier_before_deadline：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 function_h, deadline, status 用于执行 dma_barrier_before_deadline；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：dma_barrier_before_deadline 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected task dma_barrier_before_deadline(
    rdma_function_handle function_h,
    time deadline,
    output rdma_status status
  );
    rdma_status worker_status;
    bit worker_done;
    time remaining;

    worker_status = null;
    worker_done = 1'b0;
    if (!deadline_remaining(deadline, remaining)) begin
      status = timeout_status("DMA visibility barrier");
      return;
    end
    fork
      begin : dma_barrier_deadline_scope
        fork
          begin : dma_barrier_worker
            pcie.dma_visibility_barrier(function_h, worker_status);
            worker_done = 1'b1;
          end
          begin : dma_barrier_timer
            #(remaining);
          end
        join_any
        disable fork;
      end
    join
    if (!worker_done) begin
      status = timeout_status("DMA visibility barrier");
      return;
    end
    if (worker_status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "PCIe DMA barrier returned null status");
      return;
    end
    status = worker_status;
  endtask

  // 功能：处理 mmio_barrier_before_deadline：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 function_h, deadline, status 用于执行 mmio_barrier_before_deadline；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：mmio_barrier_before_deadline 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected task mmio_barrier_before_deadline(
    rdma_function_handle function_h,
    time deadline,
    output rdma_status status
  );
    rdma_status worker_status;
    bit worker_done;
    time remaining;

    worker_status = null;
    worker_done = 1'b0;
    if (!deadline_remaining(deadline, remaining)) begin
      status = timeout_status("MMIO ordering barrier");
      return;
    end
    fork
      begin : mmio_barrier_deadline_scope
        fork
          begin : mmio_barrier_worker
            pcie.mmio_ordering_barrier(function_h, worker_status);
            worker_done = 1'b1;
          end
          begin : mmio_barrier_timer
            #(remaining);
          end
        join_any
        disable fork;
      end
    join
    if (!worker_done) begin
      status = timeout_status("MMIO ordering barrier");
      return;
    end
    if (worker_status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "PCIe MMIO barrier returned null status");
      return;
    end
    status = worker_status;
  endtask

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 function_h, address, data, deadline, status 用于执行 mmio_write_before_deadline；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
  protected task mmio_write_before_deadline(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    time deadline,
    output rdma_status status
  );
    rdma_status worker_status;
    bit worker_done;
    time remaining;

    worker_status = null;
    worker_done = 1'b0;
    if (!deadline_remaining(deadline, remaining)) begin
      status = timeout_status("MMIO write");
      return;
    end
    fork
      begin : mmio_write_deadline_scope
        fork
          begin : mmio_write_worker
            pcie.mmio_write(function_h, address, data, worker_status);
            worker_done = 1'b1;
          end
          begin : mmio_write_timer
            #(remaining);
          end
        join_any
        disable fork;
      end
    join
    if (!worker_done) begin
      status = timeout_status("MMIO write");
      return;
    end
    if (worker_status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "PCIe MMIO write returned null status");
      return;
    end
    status = worker_status;
  endtask

  // 功能：处理 target_kind_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 kind, target_h 用于执行 target_kind_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：target_kind_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status target_kind_status(
    rdma_doorbell_kind_e kind,
    rdma_handle target_h
  );
    rdma_doorbell_model model;

    model = rdma_doorbell_model::type_id::create("target_kind_model");
    model.kind = kind;
    model.target_h = target_h;
    return model.validate();
  endfunction

  // 功能：处理 image_shape_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, function_generation 用于执行 image_shape_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：image_shape_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status image_shape_status(
    rdma_hw_image image,
    int unsigned function_generation
  );
    if (image == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image is null");
    if (image.length == 0 || image.bytes.size() != image.length)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image length does not match bytes");
    if (image.alignment == 0 ||
        (image.alignment & (image.alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image alignment is invalid");
    if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image endian is invalid");
    if (image.image_kind == RDMA_IMAGE_NONE || image.hardware_version == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "hardware image metadata is incomplete");
    if (image.function_generation != function_generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "hardware image generation is stale");
    return rdma_status::success();
  endfunction

  // 功能：处理 payload_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 binding, desc, absolute_address 用于执行 payload_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：payload_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status payload_status(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    output rdma_bar_addr_t absolute_address
  );
    rdma_status status;

    absolute_address = '0;
    if (desc.payload_image == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell payload image is null");
    status = image_shape_status(desc.payload_image,
                                desc.function_h.generation);
    if (!status.ok())
      return status;
    if (desc.width == 0 || desc.payload_image.length != desc.width ||
        desc.payload_image.bytes.size() != desc.width)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell width does not match payload image");
    if (desc.endian != desc.payload_image.endian)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell endian does not match payload image");
    if (desc.payload_image.image_kind != RDMA_IMAGE_DOORBELL)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "payload image is not a doorbell");
    if (desc.payload_image.write_target_kind != RDMA_HW_TARGET_BAR)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell payload target is not a BAR");
    if (desc.payload_image.bar_target.value != desc.relative_offset)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "payload BAR offset does not match descriptor");
    if ((desc.relative_offset &
         (desc.payload_image.alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell offset violates image alignment");
    if (desc.relative_offset > binding.notify_size ||
        desc.width > (binding.notify_size - desc.relative_offset))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell write is outside notify aperture");

    // A half-open aperture end must be representable so all later range
    // arithmetic can remain non-wrapping.
    if (binding.notify_base.value >
        (64'hffff_ffff_ffff_ffff - binding.notify_size))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture end overflows 64 bits");
    if (binding.notify_base.value >
        (64'hffff_ffff_ffff_ffff - desc.relative_offset))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell absolute address overflows 64 bits");
    absolute_address.value = binding.notify_base.value + desc.relative_offset;
    if (absolute_address.value >
        (64'hffff_ffff_ffff_ffff - (desc.width - 1'b1)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell write end overflows 64 bits");
    return rdma_status::success();
  endfunction

  // 功能：处理 dependency_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 binding, desc, dependency 用于执行 dependency_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：dependency_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status dependency_status(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    rdma_doorbell_dependency dependency
  );
    rdma_status status;
    rdma_iova_t first_iova;
    rdma_dma_permission_t read_permission;

    if (dependency == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell dependency is null");
    if (dependency.dependency_id == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell dependency ID is zero");
    if (!(dependency.stage inside {RDMA_DB_DEP_PAYLOAD,
                                   RDMA_DB_DEP_QUEUE_CONTEXT}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell dependency stage is invalid");
    if (!dependency.ready)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "doorbell dependency is not ready");
    if (dependency.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell dependency mapping is null");
    status = image_shape_status(dependency.image,
                                desc.function_h.generation);
    if (!status.ok())
      return status;
    if (dependency.image.write_target_kind != RDMA_HW_TARGET_BACKING)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "dependency image target is not backing memory");
    if (dependency.mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - dependency.relative_offset))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "dependency IOVA overflows 64 bits");

    first_iova.value = dependency.mapping.iova.value +
                       dependency.relative_offset;
    read_permission = '{device_read:1'b1, device_write:1'b0, atomic:1'b0};
    status = dependency.mapping.check_access(
      desc.function_h,
      binding.queue_dma.requester_bdf,
      binding.queue_dma.pasid_valid,
      binding.queue_dma.pasid,
      binding.queue_dma.dma_domain_valid,
      binding.queue_dma.dma_domain_id,
      first_iova,
      dependency.image.length,
      RDMA_DMA_DEVICE_READ,
      read_permission
    );
    if (!status.ok())
      return status;
    if ((dependency.relative_offset &
         (dependency.image.alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "dependency offset violates image alignment");
    return status;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected function rdma_status preflight(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    longint unsigned locked_function_uid,
    int unsigned locked_object_id,
    output rdma_bar_addr_t absolute_address
  );
    rdma_status status;
    bit seen_ids[longint unsigned];

    absolute_address = '0;
    if (!configured || host_mem == null || pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "doorbell scheduler is not configured");
    if (binding.function_uid != locked_function_uid ||
        binding.global_function_id != locked_object_id)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "binding identity changed while waiting");
    status = binding.validate();
    if (!status.ok())
      return status;
    if (binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "function binding is not ACTIVE");
    if (desc.function_h == null ||
        desc.function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell Function handle is invalid");
    if (desc.function_h.function_uid != binding.function_uid ||
        desc.function_h.object_id != binding.global_function_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell Function does not match binding");
    if (desc.function_h.generation != binding.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "doorbell Function generation is stale");
    if (desc.target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell target handle is null");
    if (desc.target_h.function_uid != desc.function_h.function_uid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell target belongs to another Function");
    if (desc.target_h.generation != desc.function_h.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "doorbell target generation is stale");
    status = target_kind_status(desc.kind, desc.target_h);
    if (!status.ok())
      return status;
    if (desc.notify_bar_id != binding.notify_bar_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell notify BAR does not match binding");
    if (desc.timeout == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell timeout is zero");
    if (desc.merge_requested && !desc.allow_merge)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell merge was not allowed");
    if (desc.write_combining_policy == RDMA_DB_WRITE_NON_COMBINING &&
        desc.merge_requested)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "non-combining doorbell cannot be merged");
    if (desc.readback_policy != RDMA_DB_READBACK_NONE)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "doorbell readback is unsupported");

    status = payload_status(binding, desc, absolute_address);
    if (!status.ok())
      return status;

    seen_ids.delete();
    foreach (desc.dependencies[i]) begin
      if (desc.dependencies[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "doorbell dependency is null");
      if (seen_ids.exists(desc.dependencies[i].dependency_id))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "doorbell dependency ID is duplicated");
      seen_ids[desc.dependencies[i].dependency_id] = 1'b1;
      status = dependency_status(binding, desc, desc.dependencies[i]);
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：处理 copy_image_bytes：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, data 用于执行 copy_image_bytes；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：copy_image_bytes 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function void copy_image_bytes(
    rdma_hw_image image,
    output byte data[]
  );
    data = new[image.bytes.size()];
    foreach (data[i])
      data[i] = image.bytes[i];
  endfunction

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 desc, stage, status 用于执行 write_dependency_stage；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
  protected task write_dependency_stage(
    rdma_doorbell_desc desc,
    rdma_doorbell_dependency_stage_e stage,
    output rdma_status status
  );
    byte data[];

    status = rdma_status::success();
    foreach (desc.dependencies[i]) begin
      if (desc.dependencies[i].stage != stage)
        continue;
      copy_image_bytes(desc.dependencies[i].image, data);
      status = host_mem.write(desc.dependencies[i].mapping,
                              desc.dependencies[i].relative_offset,
                              data);
      if (status == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "host memory adapter returned null status");
        return;
      end
      if (!status.ok())
        return;
    end
  endtask

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 binding, desc, locked_function_uid, locked_object_id, deadline, result, status 用于执行 submit_locked；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
  protected task submit_locked(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    longint unsigned locked_function_uid,
    int unsigned locked_object_id,
    time deadline,
    output rdma_doorbell_result result,
    output rdma_status status
  );
    rdma_bar_addr_t absolute_address;
    byte payload[];

    result = null;
    status = preflight(binding, desc, locked_function_uid, locked_object_id,
                       absolute_address);
    if (!status.ok())
      return;

    write_dependency_stage(desc, RDMA_DB_DEP_PAYLOAD, status);
    if (!status.ok())
      return;
    write_dependency_stage(desc, RDMA_DB_DEP_QUEUE_CONTEXT, status);
    if (!status.ok())
      return;

    if (desc.barrier_policy inside {RDMA_DB_BARRIER_DMA,
                                    RDMA_DB_BARRIER_DMA_MMIO}) begin
      dma_barrier_before_deadline(desc.function_h, deadline, status);
      if (!status.ok())
        return;
    end
    if (desc.barrier_policy inside {RDMA_DB_BARRIER_MMIO,
                                    RDMA_DB_BARRIER_DMA_MMIO}) begin
      mmio_barrier_before_deadline(desc.function_h, deadline, status);
      if (!status.ok())
        return;
    end

    copy_image_bytes(desc.payload_image, payload);
    mmio_write_before_deadline(desc.function_h, absolute_address, payload,
                               deadline, status);
    if (!status.ok())
      return;

    result = rdma_doorbell_result::type_id::create("doorbell_result");
    result.kind = desc.kind;
    result.function_h = rdma_clone_function_handle_value(
      desc.function_h, "doorbell result Function"
    );
    result.target_h = rdma_clone_handle_value(desc.target_h,
                                               "doorbell result target");
    result.absolute_address = absolute_address;
    result.width = desc.width;
    result.dependency_count = desc.dependencies.size();
    status = rdma_status::success();
  endtask

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 binding, desc, result, status 用于执行 submit；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
  task submit(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    output rdma_doorbell_result result,
    output rdma_status status
  );
    longint unsigned locked_function_uid;
    int unsigned locked_object_id;
    semaphore function_lock;
    rdma_function_binding binding_snapshot;
    rdma_doorbell_desc desc_snapshot;
    time request_timeout;
    time deadline;
    bit lock_acquired;

    result = null;
    if (binding == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "function binding is null");
      return;
    end
    if (desc == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "doorbell descriptor is null");
      return;
    end

    // The timeout is the only descriptor scalar required before the lock.
    // Capture it once so caller mutation cannot extend a queued request.
    request_timeout = desc.timeout;
    if (request_timeout == 0) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "doorbell timeout is zero");
      return;
    end
    deadline = $time + request_timeout;
    if (deadline < $time) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "doorbell deadline overflows simulation time");
      return;
    end

    // Generation is deliberately excluded: teardown/rebind of the same
    // immutable Function identity must serialize with its prior incarnation.
    locked_function_uid = binding.function_uid;
    locked_object_id = binding.global_function_id;
    function_lock = lock_for(locked_function_uid, locked_object_id);
    acquire_function_lock_before_deadline(function_lock, deadline,
                                          lock_acquired, status);
    if (!lock_acquired)
      return;

    // Snapshot only after acquiring the immutable-identity lock, so binding
    // teardown/rebind that completed while waiting remains visible to
    // preflight. From this point onward, preflight and execution read only the
    // detached value graph and never caller-owned objects.
    status = clone_binding_snapshot(binding, binding_snapshot);
    if (status.ok())
      status = clone_desc_snapshot(desc, desc_snapshot);
    if (status.ok()) begin
      desc_snapshot.timeout = request_timeout;
      submit_locked(binding_snapshot, desc_snapshot, locked_function_uid,
                    locked_object_id, deadline, result, status);
    end

    // This is the single post-acquisition exit: every preflight, adapter,
    // timeout, and snapshot failure releases exactly the token acquired above.
    function_lock.put(1);
  endtask
endclass
