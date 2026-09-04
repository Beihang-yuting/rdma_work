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

  // 功能：构造 rdma_doorbell_dependency，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：dependency_id='0；stage=RDMA_DB_DEP_PAYLOAD；mapping=null；relative_offset='0；image=null；ready=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_doorbell_dependency 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_doorbell_dependency");
    super.new(name);
    dependency_id = '0;
    stage = RDMA_DB_DEP_PAYLOAD;
    mapping = null;
    relative_offset = '0;
    image = null;
    ready = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_doorbell_dependency 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（rdma_doorbell_dependency copy type mismatch），不保留部分有效快照。
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

  // 功能：构造 rdma_doorbell_desc，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：kind=RDMA_DOORBELL_CMQ_SQ；function_h=null；target_h=null；notify_bar_id='0；relative_offset='0；width='0；endian=RDMA_ENDIAN_LITTLE；payload_image=null；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_doorbell_desc 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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

  // 功能：将 rhs 中 rdma_doorbell_desc 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（rdma_doorbell_desc copy type mismatch），不保留部分有效快照。
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

  // 功能：构造 rdma_doorbell_result，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：kind=RDMA_DOORBELL_CMQ_SQ；function_h=null；target_h=null；absolute_address='0；width='0；dependency_count='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_doorbell_result 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_doorbell_result");
    super.new(name);
    kind = RDMA_DOORBELL_CMQ_SQ;
    function_h = null;
    target_h = null;
    absolute_address = '0;
    width = '0;
    dependency_count = '0;
  endfunction

  // 功能：将 rhs 中 rdma_doorbell_result 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（rdma_doorbell_result copy type mismatch），不保留部分有效快照。
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

  // 功能：构造 rdma_doorbell_scheduler，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：host_mem=null；pcie=null；configured=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_doorbell_scheduler 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_doorbell_scheduler");
    super.new(name);
    host_mem = null;
    pcie = null;
    configured = 1'b0;
    function_locks.delete();
  endfunction

  // 功能：在 rdma_doorbell_scheduler 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：host_mem_arg（输入）、pcie_arg（输入）；configure 先依据 host_mem_arg == null；pcie_arg == null；configured 校验 host_mem_arg、pcie_arg；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
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

  // 功能：在 rdma_doorbell_scheduler 中，function_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：function_uid（输入）、object_id（输入）；function_key 读取 function_uid、object_id 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：function_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string function_key(
    longint unsigned function_uid,
    int unsigned object_id
  );
    return $sformatf("%016h:%08h", function_uid, object_id);
  endfunction

  // 功能：在 rdma_doorbell_scheduler 中，lock_for 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：function_uid（输入）、object_id（输入）；lock_for 读取 function_uid、object_id 并使用字段 key；函数返回 semaphore，不取得调用方资源所有权。
  // 失败/边界：lock_for 先检查 !function_locks.exists(key，再返回 function_locks[key]；拒绝分支不提交部分状态，也不隐式重试。
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

  // 功能：timeout_status 校验 operation 与当前对象状态的一致性，并显式处理“doorbell submit deadline expired during”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：operation（输入）；timeout_status 读取 operation 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：timeout_status 返回 RDMA_SC_TIMEOUT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status timeout_status(string operation);
    return rdma_status::make(
      RDMA_SC_TIMEOUT,
      {"doorbell submit deadline expired during ", operation}
    );
  endfunction

  // 功能：在 rdma_doorbell_scheduler 中，deadline_remaining 比较当前仿真时间与 deadline，写回剩余时间并返回是否仍可继续等待。
  // 输入/输出及副作用：deadline（输入）、remaining（输出）；deadline_remaining 读取 deadline、remaining 并使用字段 remaining，并写入 remaining；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：deadline_remaining 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：在 rdma_doorbell_scheduler 中，clone_binding_snapshot 将 rhs 中 rdma_doorbell_scheduler 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；clone_binding_snapshot 读取 source、snapshot 并使用字段 snapshot、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_binding_snapshot 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“function binding is null”“function binding snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_doorbell_scheduler 中，clone_desc_snapshot 将 rhs 中 rdma_doorbell_scheduler 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；clone_desc_snapshot 读取 source、snapshot 并使用字段 snapshot、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_desc_snapshot 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“doorbell descriptor is null”“doorbell descriptor snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_doorbell_scheduler 中，acquire_function_lock_before_deadline 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：function_lock（输入）、deadline（输入）、acquired（输出）、status（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
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

  // 功能：在 rdma_doorbell_scheduler 中，dma_barrier_before_deadline 在截止时间内执行 DMA 可见性或 MMIO 顺序屏障，确保 doorbell 之前的数据写入已按序可见。
  // 输入/输出及副作用：function_h（输入）、deadline（输入）、status（输出）；dma_barrier_before_deadline 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：dma_barrier_before_deadline 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“PCIe DMA barrier returned null status”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_doorbell_scheduler 中，mmio_barrier_before_deadline 在截止时间内执行 DMA 可见性或 MMIO 顺序屏障，确保 doorbell 之前的数据写入已按序可见。
  // 输入/输出及副作用：function_h（输入）、deadline（输入）、status（输出）；mmio_barrier_before_deadline 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：mmio_barrier_before_deadline 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“PCIe MMIO barrier returned null status”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_doorbell_scheduler 中，mmio_write_before_deadline 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：function_h（输入）、address（输入）、data（输入）、deadline（输入）、status（输出）；mmio_write_before_deadline 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。

  // 失败/边界：mmio_write_before_deadline 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
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

  // 功能：target_kind_status 校验 kind、target_h 与当前对象状态的一致性，并显式处理“target_kind_model”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：kind（输入）、target_h（输入）；target_kind_status 读取 kind、target_h 并使用字段 model、model.kind、model.target_h；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：target_kind_status 的结果直接由 return model.validate() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 功能：在 rdma_doorbell_scheduler 中，image_shape_status 返回 profile 固定的镜像字段或长度常量，供编码和断言使用。
  // 输入/输出及副作用：image（输入）、function_generation（输入）；image_shape_status 读取 image、function_generation 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：image_shape_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_STALE_GENERATION；典型拒绝条件为“hardware image is null”“hardware image length does not match bytes”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：payload_status 校验 binding、desc、absolute_address 与当前对象状态的一致性，并显式处理“doorbell payload image is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、desc（输入）、absolute_address（输出）；payload_status 读取 binding、desc、absolute_address 并使用字段 absolute_address、status、absolute_address.value，并写入 absolute_address；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：payload_status 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “doorbell payload image is null”；“doorbell width does not match payload image”；“doorbell endian does not match payload image”；“payload image is not a doorbell”；“doorbell payload target is not a BAR”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
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

  // 功能：dependency_status 校验 binding、desc、dependency 与当前对象状态的一致性，并显式处理“doorbell dependency is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、desc（输入）、dependency（输入）；dependency_status 读取 binding、desc、dependency 并使用字段 status、first_iova.value、read_permission；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：dependency_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE、RDMA_SC_DMA_TRANSLATION；典型拒绝条件为“doorbell dependency is null”“doorbell dependency ID is zero”；失败路径不提交部分状态或转移未声明资源。

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

  // 功能：scheduler preflight 校验 doorbell 请求的 Function、队列类型和 ring 游标，并将规范化结果写入 result。
  // 输入/输出及副作用：binding（输入）、desc（输入）、locked_function_uid（输入）、locked_object_id（输入）、absolute_address（输出）；preflight 读取 binding、desc、locked_function_uid、locked_object_id、absolute_address 并使用字段 absolute_address、status，并写入 absolute_address；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
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

  // 功能：copy_image_bytes 复制 image、data 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：image（输入）、data（输出）；copy_image_bytes 读取 image、data 并使用字段 data，并写入 data；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  protected function void copy_image_bytes(
    rdma_hw_image image,
    output byte data[]
  );
    data = new[image.bytes.size()];
    foreach (data[i])
      data[i] = image.bytes[i];
  endfunction

  // 功能：在 rdma_doorbell_scheduler 中，write_dependency_stage 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：desc（输入）、stage（输入）、status（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：write_dependency_stage 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
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

  // 功能：在 rdma_doorbell_scheduler 中，submit_locked 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：binding（输入）、desc（输入）、locked_function_uid（输入）、locked_object_id（输入）、deadline（输入）、result（输出）、status（输出）；输入
  //   request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：submit_locked 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
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

  // 功能：在 rdma_doorbell_scheduler 中，submit 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：binding（输入）、desc（输入）、result（输出）、status（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或
  //   pending journal，并通过 output 返回结果。
  // 失败/边界：submit 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
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
