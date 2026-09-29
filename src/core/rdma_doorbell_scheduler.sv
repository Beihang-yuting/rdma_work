// 目录：核心执行层 core/rdma_doorbell_scheduler.sv。
// 职责：定义 doorbell descriptor/result，并按依赖写、barrier、MMIO 顺序执行，发布每次调用的副作用证据。
// 依赖：依赖 model 中的 Function/handle/image/effect 值，以及 Host-memory、PCIe adapter 契约。
// 所有权与生命周期：descriptor/result/envelope 拥有 detached 值；scheduler/observer 只借用外部 adapter 或回调引用。
// 状态边界：普通字段初始化/复制由 rdma_status 提供；legacy 的枚举准入保留在 envelope，
//   raw factory、直接构造名称和 submission_effect 高水位仍由当前业务边界决定。

// 设计说明：依赖阶段和 barrier policy 是硬件发布顺序的显式输入；effect 则是
// 恢复方可消费的单调高水位，禁止从最终 status 反推已经发生的外部副作用。

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

// 设计说明：单条 dependency 把要写入的 detached hardware image 与非拥有 DMA
//   mapping 绑定，并显式标注 payload/context 阶段，避免 scheduler 猜测写入顺序。
class rdma_doorbell_dependency extends uvm_object;
  `uvm_object_utils(rdma_doorbell_dependency)

  longint unsigned dependency_id;
  rdma_doorbell_dependency_stage_e stage;
  rdma_dma_mapping mapping;
  longint unsigned relative_offset;
  rdma_hw_image image;
  bit ready;

  // 功能：构造尚未 ready 的 payload-stage dependency，清空 identity、mapping、offset 和 image。
  // 输入/输出及副作用：name 传给 uvm_object；只初始化本对象字段，不访问 DMA backing。
  // 失败/边界：默认 dependency_id=0、mapping/image=null，不能通过 scheduler preflight；mapping 始终非拥有。
  function new(string name = "rdma_doorbell_dependency");
    super.new(name);
    dependency_id = '0;
    stage = RDMA_DB_DEP_PAYLOAD;
    mapping = null;
    relative_offset = '0;
    image = null;
    ready = 1'b0;
  endfunction

  // 功能：深复制 dependency identity/stage/offset/ready 以及 mapping/image 值，形成独立快照。
  // 输入/输出及副作用：rhs 为只读 source；覆盖当前字段，mapping/image 通过 clone 分离，源对象不变。
  // 失败/边界：rhs 类型不匹配，或 mapping/image clone 返回 null/错误类型时触发 UVM fatal。
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

// 设计说明：descriptor 冻结一次 doorbell 的 Function/target、BAR payload、总
//   deadline 和有序 dependency 队列；调用方拥有原值，scheduler 只消费锁内快照。
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
  // 其中 timeout 是从公共入口、Function lock 等待到最终 PCIe task 的总仿真时间预算，
  // 不是逐操作预算；调用方应写显式时间单位（例如 100ns）。
  time timeout;
  rdma_doorbell_readback_policy_e readback_policy;

  // 功能：构造空的 CMQ-SQ descriptor，并设置严格 DMA+MMIO barrier、非合并写和无 readback 默认策略。
  // 输入/输出及副作用：name 传给 uvm_object；清空 handle/image/dependency 和 timeout，不访问外部资源。
  // 失败/边界：默认 width/timeout 为零且必要 handle/image 为空，必须由调用方填充后才能通过 preflight。
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

  // 功能：深复制 descriptor 全部标量、handle、payload 和 dependency 图，并保留源图中的 mapping/image 别名拓扑。
  // 输入/输出及副作用：rhs 为只读 source；覆盖当前字段，动态队列和嵌套值与 source 分离。
  // 失败/边界：rhs 或任一嵌套 clone 类型不匹配/返回 null 时触发 UVM fatal，不发布不完整快照。
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
        // 由于 UVM 1.2 在外层 copy 活跃时会抑制重复嵌套 copy，这里显式缓存源图
        //   identity，使共享 mapping/image 的多个 dependency 仍指向同一 detached 值，
        // 避免第二个 clone 只留下默认字段。
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

// 设计说明：doorbell result 只承载成功发布后的不可变 identity、绝对 BAR 地址
//   以及 declared dependency 数；它不持有 adapter、mapping 或 caller descriptor。
class rdma_doorbell_result extends uvm_object;
  `uvm_object_utils(rdma_doorbell_result)

  rdma_doorbell_kind_e kind;
  rdma_function_handle function_h;
  rdma_handle target_h;
  rdma_bar_addr_t absolute_address;
  int unsigned width;
  int unsigned dependency_count;

  // 功能：构造空的 CMQ-SQ doorbell result，清空 handle、地址、宽度和依赖数。
  // 输入/输出及副作用：name 传给 uvm_object；只初始化本地值，不访问 scheduler 或 adapter。
  // 失败/边界：默认对象不是成功证据；只有 scheduler 在 MMIO 成功后填充并发布。
  function new(string name = "rdma_doorbell_result");
    super.new(name);
    kind = RDMA_DOORBELL_CMQ_SQ;
    function_h = null;
    target_h = null;
    absolute_address = '0;
    width = '0;
    dependency_count = '0;
  endfunction

  // 功能：深复制 doorbell result 的 kind、地址、宽度、依赖数和两个 handle。
  // 输入/输出及副作用：rhs 为只读 source；覆盖当前字段，Function/target handle 通过 clone 分离。
  // 失败/边界：rhs 类型不匹配，或任一 handle clone 返回 null/错误类型时触发 UVM fatal。
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

// 设计说明：observer 只暴露“最终 deadline 已通过、即将进入 PCIe MMIO”这一同步边界；
//   该 scheduler 不保存此非拥有引用，回调也不得等待、分配、取锁或重入执行路径。
virtual class rdma_doorbell_submission_observer extends uvm_object;
  // 功能：构造一个无状态的 doorbell submission observer 基类对象。
  // 输入/输出及副作用：name 传给 uvm_object；不登记回调、不保存 scheduler 或 adapter 引用。
  // 失败/边界：抽象类只能由具体 observer 子类构造；对象生命周期和回调状态由调用方管理。
  function new(string name = "rdma_doorbell_submission_observer");
    super.new(name);
  endfunction

  // 功能：通知调用方本次 doorbell 已到达 MMIO_MAYBE_VISIBLE 边界。
  // 输入/输出及副作用：无输入和返回值；实现只能同步记录调用方自有的轻量状态。
  // 失败/边界：回调不能报告失败，也不得分配、等待、取锁、调用 adapter/service 或重入 scheduler。
  pure virtual function void before_mmio_maybe_visible();
endclass

// 设计说明：observed result 是每次 submit 独占的恢复证据 envelope；普通 UVM copy
// 保留深复制语义，而 legacy 投影绕过 clone/factory，保证 hostile override 下仍非致命返回。
class rdma_doorbell_submission_result extends uvm_object;
  `uvm_object_utils(rdma_doorbell_submission_result)

  rdma_doorbell_result doorbell_result;
  rdma_status status;
  rdma_submission_effect_e submission_effect;
  int unsigned dependency_count;
  bit before_mmio_maybe_visible_called;

  // 功能：构造一个 call-local observed envelope，并预置非空 INVALID_STATE 状态和未提交证据。
  // 输入/输出及副作用：name 传给 uvm_object；直接创建本对象拥有的初始 status，不调用 UVM factory。
  // 失败/边界：构造始终令 status 非空、doorbell_result 为空、dependency_count 为零；不接管 observer 或 adapter。
  function new(string name = "rdma_doorbell_submission_result");
    super.new(name);
    doorbell_result = null;
    status = new("doorbell_submission_initial_status");
    rdma_status::set_fields_noalloc(status, RDMA_SC_INVALID_STATE,
                      "doorbell submission has not completed validation");
    submission_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    dependency_count = 0;
    before_mmio_maybe_visible_called = 1'b0;
  endfunction

  // 功能：copy_status_fields 先执行 legacy 专属的枚举准入，再复用公共无分配字段复制。
  // 输入/输出及副作用：source/destination 为输入；准入通过后覆盖 destination 全部诊断，
  //   不重新分类、不修改 source，也不调用 clone/factory；不根据 status 推导 submission_effect。
  // 失败/边界：任一对象为空，或 category/code/source_engine 含未知或超过各自最大枚举值时
  //   返回 0 且不写 destination；不检查 severity 或 category/code 的配对，自复制允许。
  protected static function bit copy_status_fields(
    rdma_status source,
    rdma_status destination
  );
    if (source == null || destination == null)
      return 1'b0;
    if ($isunknown(source.category) || $isunknown(source.code) ||
        $isunknown(source.source_engine) ||
        source.category > RDMA_STATUS_RESET ||
        source.code > RDMA_SC_RECOVERY_REQUIRED ||
        source.source_engine > RDMA_ENGINE_RESET)
      return 1'b0;
    return rdma_status::copy_fields_noalloc(source, destination);
  endfunction

  // 功能：把任意有效 handle 的 identity 标量直接复制为独立 base-handle 值。
  // 输入/输出及副作用：source 为只读输入，destination 先置 null；成功返回直接 new 的 detached handle。
  // 失败/边界：source 为空或 kind 含未知位时返回 0；不调用 clone 或 factory。
  protected static function bit project_handle_direct(
    rdma_handle source,
    output rdma_handle destination
  );
    destination = null;
    if (source == null || $isunknown(source.kind))
      return 1'b0;
    destination = new("legacy_doorbell_target");
    destination.kind = source.kind;
    destination.function_uid = source.function_uid;
    destination.object_id = source.object_id;
    destination.generation = source.generation;
    return 1'b1;
  endfunction

  // 功能：把 Function handle 的 identity 标量直接复制为独立 rdma_function_handle。
  // 输入/输出及副作用：source 为只读输入，destination 先置 null；成功返回直接 new 的 detached Function 值。
  // 失败/边界：source 为空或 kind 不是 RDMA_RESOURCE_FUNCTION 时返回 0；不调用 clone 或 factory。
  protected static function bit project_function_handle_direct(
    rdma_function_handle source,
    output rdma_function_handle destination
  );
    destination = null;
    if (source == null || source.kind != RDMA_RESOURCE_FUNCTION)
      return 1'b0;
    destination = new("legacy_doorbell_function");
    destination.kind = source.kind;
    destination.function_uid = source.function_uid;
    destination.object_id = source.object_id;
    destination.generation = source.generation;
    return 1'b1;
  endfunction

  // 功能：把 observed envelope 深复制到当前对象，供普通 UVM value clone 保留嵌套隔离。
  // 输入/输出及副作用：rhs 为只读 source；覆盖当前 status/result/effect/count/observer 标志。
  // 失败/边界：rhs 类型不匹配，或嵌套 clone 返回 null/错误类型时触发 UVM fatal，不发布部分有效副本。
  virtual function void do_copy(uvm_object rhs);
    rdma_doorbell_submission_result source;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE",
                 "rdma_doorbell_submission_result copy type mismatch")

    if (source.doorbell_result == null) begin
      doorbell_result = null;
    end
    else begin
      cloned_object = source.doorbell_result.clone();
      if (cloned_object == null || !$cast(doorbell_result, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "observed doorbell result clone type mismatch")
    end
    if (source.status == null) begin
      status = null;
    end
    else begin
      cloned_object = source.status.clone();
      if (cloned_object == null || !$cast(status, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "observed doorbell status clone type mismatch")
    end
    submission_effect = source.submission_effect;
    dependency_count = source.dependency_count;
    before_mmio_maybe_visible_called =
      source.before_mmio_maybe_visible_called;
  endfunction

  // 功能：将 observed status 和可选 doorbell result 单向投影为旧 submit 输出。
  // 输入/输出及副作用：projected_result/projected_status/failure_reason
  //   均为输出；只读取本 envelope 并直接创建 detached 值。
  // 失败/边界：null/畸形 status 或非空 result 缺少 Function/target 时返回
  //   0、result=null 和直接构造 INVALID_STATE；null result 是合法失败形状。
  function bit try_project_legacy(
    output rdma_doorbell_result projected_result,
    output rdma_status projected_status,
    output string failure_reason
  );
    rdma_function_handle function_copy;
    rdma_handle target_copy;

    projected_result = null;
    projected_status = new("legacy_doorbell_status");
    failure_reason = "";
    if (!copy_status_fields(status, projected_status)) begin
      rdma_status::set_fields_noalloc(projected_status, RDMA_SC_INVALID_STATE,
                        "observed doorbell status is null or malformed");
      failure_reason = "observed doorbell status is null or malformed";
      return 1'b0;
    end
    if (doorbell_result == null)
      return 1'b1;

    if (!project_function_handle_direct(doorbell_result.function_h,
                                        function_copy) ||
        !project_handle_direct(doorbell_result.target_h, target_copy)) begin
      projected_result = null;
      rdma_status::set_fields_noalloc(projected_status, RDMA_SC_INVALID_STATE,
                        "observed doorbell result is malformed");
      failure_reason = "observed doorbell result is malformed";
      return 1'b0;
    end

    projected_result = new("legacy_doorbell_result");
    projected_result.kind = doorbell_result.kind;
    projected_result.function_h = function_copy;
    projected_result.target_h = target_copy;
    projected_result.absolute_address = doorbell_result.absolute_address;
    projected_result.width = doorbell_result.width;
    projected_result.dependency_count = doorbell_result.dependency_count;
    return 1'b1;
  endfunction
endclass

// 设计说明：scheduler 以 Function identity semaphore 串行化同一 Function 的 doorbell，
// 并把每次调用的不可回退副作用高水位发布到 call-local observed envelope。
class rdma_doorbell_scheduler extends uvm_object;
  `uvm_object_utils(rdma_doorbell_scheduler)

  protected rdma_host_mem_api host_mem;
  protected rdma_pcie_api pcie;
  protected bit configured;
  protected semaphore function_locks[string];

  // 功能：构造未配置 scheduler，清空两个 adapter 引用和 per-Function lock 表。
  // 输入/输出及副作用：name 传给 uvm_object；仅初始化本地状态，不创建或接管 adapter。
  // 失败/边界：configured 保持 0；configure 成功前的 submit 会在 preflight 返回 INVALID_STATE。
  function new(string name = "rdma_doorbell_scheduler");
    super.new(name);
    host_mem = null;
    pcie = null;
    configured = 1'b0;
    function_locks.delete();
  endfunction

  // 功能：一次性绑定 Host-memory 与 PCIe adapter，使 scheduler 具备执行 doorbell 的外部能力。
  // 输入/输出及副作用：host_mem_arg/pcie_arg 为非拥有输入；成功保存引用、置 configured 并返回 OK。
  // 失败/边界：任一 adapter 为 null 返回 INVALID_ARGUMENT；重复配置返回 INVALID_STATE，且保留原引用。
  function rdma_status configure(
    rdma_host_mem_api host_mem_arg,
    rdma_pcie_api pcie_arg
  );
    if (host_mem_arg == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "host memory adapter is null");
    if (pcie_arg == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "PCIe adapter is null");
    if (configured)
      return make_status_direct(RDMA_SC_INVALID_STATE,
                                "doorbell scheduler is already configured");
    host_mem = host_mem_arg;
    pcie = pcie_arg;
    configured = 1'b1;
    return make_status_direct(RDMA_SC_OK);
  endfunction

  // 功能：直接构造独立 rdma_status，供 entry fallback 和外部 I/O 后 factory 故障降级。
  // 输入/输出及副作用：code/message 为输入；直接 new doorbell_direct_status，
  //   再由 rdma_status 的无分配 setter 初始化全部字段并返回非空结果。
  // 失败/边界：不调用 type_id::create/clone，故 null/错误 factory override 不会把恢复证据变成 fatal。
  protected function rdma_status make_status_direct(
    rdma_status_code_e code,
    string message = ""
  );
    rdma_status status;

    status = new("doorbell_direct_status");
    void'(rdma_status::set_fields_noalloc(status, code, message));
    return status;
  endfunction

  // 功能：把任一内部/外部 status 结果归一化为可安全解引用的非空值。
  // 输入/输出及副作用：candidate 为被检查的 status，fallback_code/operation
  //   提供空返回时的诊断；返回 candidate 或 scheduler 直接构造的 detached status。
  // 失败/边界：candidate==null 时绝不调用 candidate.ok()，而是 fail-closed 为
  //   fallback_code；非空 status 原样保留其硬件诊断字段和错误码。
  protected function rdma_status normalize_status(
    rdma_status candidate,
    rdma_status_code_e fallback_code,
    string operation
  );
    if (candidate != null)
      return candidate;
    return make_status_direct(
      fallback_code,
      {operation, " returned null status"}
    );
  endfunction

  // 功能：在尚未触发外部 I/O 的路径把 validator/lock/snapshot status 写入初始 observed slot。
  // 输入/输出及副作用：source/result 为输入；只改写 result.status，非空槽原位复用，空槽直接补建。
  // 失败/边界：result=null 时不处理；status slot=null 时直接补建；source=null 时
  //   将 slot 重置为 INVALID_STATE，非空 source 原样复制且不执行 legacy 枚举准入。
  protected function void capture_pre_submit_status(
    rdma_status source,
    rdma_doorbell_submission_result result
  );
    if (result == null)
      return;
    if (result.status == null)
      result.status = make_status_direct(
        RDMA_SC_INVALID_STATE, "observed doorbell status slot is null"
      );
    if (!rdma_status::copy_fields_noalloc(source, result.status))
      void'(rdma_status::set_fields_noalloc(result.status, RDMA_SC_INVALID_STATE,
                              "doorbell operation returned null status"));
  endfunction

  // 功能：直接调用 UVM raw factory，使外部 I/O 后的对象创建可显式处理 null/错误 override。
  // 输入/输出及副作用：requested_type/name 为输入；返回 raw uvm_object，不修改 factory override。
  // 失败/边界：requested_type/factory 为空或 factory 返回 null 时返回 null；调用方负责类型检查和直接降级。
  protected function uvm_object factory_create_object_nonfatal(
    uvm_object_wrapper requested_type,
    string name
  );
    uvm_factory factory;

    if (requested_type == null)
      return null;
    factory = uvm_factory::get();
    if (factory == null)
      return null;
    return factory.create_object_by_type(requested_type, "", name);
  endfunction

  // 功能：在一次 adapter 调用结束后把其 status 捕获为 observed envelope 独占快照。
  // 输入/输出及副作用：source/result/operation_context 为输入；result 非空时尝试一次 raw 创建并替换其 status。
  // 失败/边界：result=null 返回 0 且不创建对象；raw factory null/错型直接安装
  //   INVALID_STATE，source=null 则复用 candidate 写入 INVALID_STATE；不回退 effect，
  //   不执行 legacy 枚举准入，原始 adapter 诊断与旧接口投影策略分开。
  protected function bit capture_external_status(
    rdma_status source,
    rdma_doorbell_submission_result result,
    string operation_context
  );
    rdma_status candidate;
    uvm_object raw_candidate;

    if (result == null)
      return 1'b0;
    raw_candidate = factory_create_object_nonfatal(
      rdma_status::get_type(), {operation_context, "_status"}
    );
    if (raw_candidate == null || !$cast(candidate, raw_candidate)) begin
      result.status = make_status_direct(
        RDMA_SC_INVALID_STATE,
        {operation_context, " status allocation failed"}
      );
      return 1'b0;
    end
    if (!rdma_status::copy_fields_noalloc(source, candidate)) begin
      void'(rdma_status::set_fields_noalloc(candidate, RDMA_SC_INVALID_STATE,
                              {operation_context, " returned null status"}));
      result.status = candidate;
      return 1'b0;
    end
    result.status = candidate;
    return 1'b1;
  endfunction

  // 功能：直接复制 preflight 已验证的 Function handle identity，供 observed result 避开 clone/factory。
  // 输入/输出及副作用：source 为只读输入；返回 new 创建的 detached rdma_function_handle。
  // 失败/边界：source 为空时返回 null；不重新验证 binding authority，也不取得源句柄所有权。
  protected function rdma_function_handle copy_function_handle_direct(
    rdma_function_handle source
  );
    rdma_function_handle destination;

    if (source == null)
      return null;
    destination = new("observed_doorbell_function");
    destination.kind = source.kind;
    destination.function_uid = source.function_uid;
    destination.object_id = source.object_id;
    destination.generation = source.generation;
    return destination;
  endfunction

  // 功能：直接复制 preflight 已验证的 target handle identity，供 observed result 避开 clone/factory。
  // 输入/输出及副作用：source 为只读输入；返回 new 创建的 detached base handle。
  // 失败/边界：source 为空时返回 null；子类专有字段不属于 rdma_doorbell_result 契约且不会被复制。
  protected function rdma_handle copy_handle_direct(rdma_handle source);
    rdma_handle destination;

    if (source == null)
      return null;
    destination = new("observed_doorbell_target");
    destination.kind = source.kind;
    destination.function_uid = source.function_uid;
    destination.object_id = source.object_id;
    destination.generation = source.generation;
    return destination;
  endfunction

  // 功能：在成功 MMIO 后经 raw factory 构造并填充 detached doorbell result。
  // 输入/输出及副作用：desc/address/result 为输入；成功发布
  //   result.doorbell_result，不修改 desc。
  // 失败/边界：raw factory 返回 null/错误类型或 handle 复制不完整时保持
  //   doorbell_result=null、安装 INVALID_STATE；保留 MMIO_VISIBLE effect。
  protected function bit publish_doorbell_result(
    rdma_doorbell_desc desc,
    rdma_bar_addr_t address,
    rdma_doorbell_submission_result result
  );
    rdma_doorbell_result candidate;
    uvm_object raw_candidate;

    if (result == null)
      return 1'b0;
    result.doorbell_result = null;
    raw_candidate = factory_create_object_nonfatal(
      rdma_doorbell_result::get_type(), "observed_doorbell_result"
    );
    if (raw_candidate == null || !$cast(candidate, raw_candidate)) begin
      result.status = make_status_direct(
        RDMA_SC_INVALID_STATE, "doorbell result allocation failed"
      );
      return 1'b0;
    end
    candidate.kind = desc.kind;
    candidate.function_h = copy_function_handle_direct(desc.function_h);
    candidate.target_h = copy_handle_direct(desc.target_h);
    candidate.absolute_address = address;
    candidate.width = desc.width;
    candidate.dependency_count = result.dependency_count;
    if (candidate.function_h == null || candidate.target_h == null) begin
      result.status = make_status_direct(
        RDMA_SC_INVALID_STATE, "doorbell result handle copy failed"
      );
      return 1'b0;
    end
    result.doorbell_result = candidate;
    return 1'b1;
  endfunction

  // 功能：把 immutable Function UID 和 global Function ID 格式化为 semaphore 表键。
  // 输入/输出及副作用：function_uid/object_id 为输入；返回固定宽度十六进制 string，不修改 scheduler。
  // 失败/边界：键故意不含 generation，使同一 Function 的 teardown/rebind 与旧 incarnation 串行。
  protected function string function_key(
    longint unsigned function_uid,
    int unsigned object_id
  );
    return $sformatf("%016h:%08h", function_uid, object_id);
  endfunction

  // 功能：查找或惰性创建指定 immutable Function identity 的单 token semaphore。
  // 输入/输出及副作用：function_uid/object_id 为输入；首次访问会更新 function_locks，返回 scheduler 拥有的 semaphore。
  // 失败/边界：同一 key 始终复用同一 lock；函数不获取 token，等待/超时由调用 task 处理。
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

  // 功能：直接构造带 operation 上下文的 doorbell 总截止时间超时状态。
  // 输入/输出及副作用：operation 为输入；返回独立 RDMA_SC_TIMEOUT status，不修改 scheduler。
  // 失败/边界：不依赖 factory，因而 barrier/MMIO 已开始后的 hostile override 不会触发 fatal 或丢失 effect。
  protected function rdma_status timeout_status(string operation);
    return make_status_direct(
      RDMA_SC_TIMEOUT,
      {"doorbell submit deadline expired during ", operation}
    );
  endfunction

  // 功能：计算总 deadline 相对当前仿真时间的剩余预算，并指示能否启动下一次等待。
  // 输入/输出及副作用：deadline 为输入，remaining 为输出；未到期返回 1 和 deadline-$time。
  // 失败/边界：$time 已达到/超过 deadline 时返回 0、remaining=0；不延长或重置预算。
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

  // 功能：通过 binding 的 nonfatal authority seam 建立锁内只读 detached snapshot，
  //   供 preflight 和执行统一消费，并绕过可覆盖的 UVM clone/type_id 路径。
  // 输入/输出及副作用：source 为输入，snapshot 先置 null；成功输出完整 value
  //   graph 和 OK，source 的动态 validate 会在 seam 内再次参与校验。
  // 失败/边界：source=null 返回 INVALID_ARGUMENT；嵌套 authority 缺失、动态
  //   subtype 不支持、候选不等值或 validator 返回 null 时返回非空错误，snapshot 保持 null。
  protected function rdma_status clone_binding_snapshot(
    rdma_function_binding source,
    output rdma_function_binding snapshot
  );
    rdma_status status;

    snapshot = null;
    if (source == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "function binding is null");
    status = source.snapshot_complete_nonfatal(snapshot);
    if (status == null) begin
      snapshot = null;
      return make_status_direct(
        RDMA_SC_INVALID_STATE,
        "function binding nonfatal snapshot returned null status"
      );
    end
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    if (snapshot == null) begin
      return make_status_direct(
        RDMA_SC_INVALID_STATE,
        "function binding nonfatal snapshot returned null value"
      );
    end
    return make_status_direct(RDMA_SC_OK);
  endfunction

  // 功能：clone 调用方 descriptor 为锁内 detached snapshot，冻结 handle/image/dependency 图。
  // 输入/输出及副作用：source 为输入，snapshot 先置 null；成功输出 rdma_doorbell_desc clone 和 OK。
  // 失败/边界：source=null 返回 INVALID_ARGUMENT；clone=null/错误类型返回 INVALID_STATE，snapshot 保持 null。
  protected function rdma_status clone_desc_snapshot(
    rdma_doorbell_desc source,
    output rdma_doorbell_desc snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell descriptor is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
      snapshot = null;
      return make_status_direct(
        RDMA_SC_INVALID_STATE,
        "doorbell descriptor snapshot clone failed"
      );
    end
    return make_status_direct(RDMA_SC_OK);
  endfunction

  // 功能：先 try_get，再以 invocation-local worker/timer 竞争在总 deadline 前取得 Function lock。
  // 输入/输出及副作用：function_lock/deadline 为输入；成功消耗一个 token，输出 acquired=1 和 OK。
  // 失败/边界：入口已超时或 timer 胜出时输出 acquired=0/TIMEOUT；未取得 token 的路径绝不 put。
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
      status = make_status_direct(RDMA_SC_OK);
      return;
    end

    // 每次调用用独立子进程包住 worker/timer 竞争；某些 simulator 的具名块
    //   直接 disable 会误伤本 task 的并发 activation，而 descendant-only disable fork
    // 只终止当前调用创建的竞争分支。
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
    status = make_status_direct(RDMA_SC_OK);
  endtask

  // 功能：用总 deadline 的剩余预算执行一次 PCIe DMA visibility barrier。
  // 输入/输出及副作用：function_h/deadline 为输入；调用 pcie task，并输出其 status 或本地失败 status。
  // 失败/边界：入口/等待超时返回 TIMEOUT；adapter 返回 null 转为 INVALID_STATE；timer 胜出时终止本调用 worker。
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
      status = make_status_direct(RDMA_SC_INVALID_STATE,
                                  "PCIe DMA barrier returned null status");
      return;
    end
    status = worker_status;
  endtask

  // 功能：用总 deadline 的剩余预算执行一次 PCIe MMIO ordering barrier。
  // 输入/输出及副作用：function_h/deadline 为输入；调用 pcie task，并输出其 status 或本地失败 status。
  // 失败/边界：入口/等待超时返回 TIMEOUT；adapter 返回 null 转为 INVALID_STATE；timer 胜出时终止本调用 worker。
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
      status = make_status_direct(RDMA_SC_INVALID_STATE,
                                  "PCIe MMIO barrier returned null status");
      return;
    end
    status = worker_status;
  endtask

  // 功能：在最终 deadline 检查后发布 MMIO_MAYBE_VISIBLE 边界，并限时执行
  //   一次 PCIe MMIO write。
  // 输入/输出及副作用：function_h/address/data/deadline、非拥有 observer 和
  //   call-local result 为输入；写 status，并在回调/成功时推进 result effect。
  // 失败/边界：最终检查失败保持 HOST_MEMORY_ORDERED 且不回调；进入 PCIe
  //   后的错误/超时保持 MMIO_MAYBE_VISIBLE；只有明确 OK 才推进 MMIO_VISIBLE。
  protected task mmio_write_before_deadline(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    time deadline,
    rdma_doorbell_submission_observer observer,
    rdma_doorbell_submission_result result,
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
    result.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
    if (observer != null) begin
      result.before_mmio_maybe_visible_called = 1'b1;
      observer.before_mmio_maybe_visible();
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
      status = make_status_direct(RDMA_SC_INVALID_STATE,
                                  "PCIe MMIO write returned null status");
      return;
    end
    status = worker_status;
    if (worker_status.ok())
      result.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
  endtask

  // 功能：复用 rdma_doorbell_model.validate 检查 doorbell kind 与 target handle kind 的对应关系。
  // 输入/输出及副作用：kind/target_h 为只读输入；构造临时 model 并返回 validate status，不修改 handle。
  // 失败/边界：无效 kind、null target 或不支持的 target kind 由 model 返回 INVALID_ARGUMENT。
  protected function rdma_status target_kind_status(
    rdma_doorbell_kind_e kind,
    rdma_handle target_h
  );
    rdma_doorbell_model model;
    rdma_status status;
    uvm_object raw_model;

    // 通过 raw factory 获取对象，先做显式 cast；typed registry::create 在 hostile
    //   override 返回错误动态类型时会直接触发 UVM fatal，无法把边界错误转成 status。
    raw_model = factory_create_object_nonfatal(
      rdma_doorbell_model::get_type(), "target_kind_model"
    );
    if (raw_model == null || !$cast(model, raw_model))
      return make_status_direct(
        RDMA_SC_INVALID_STATE,
        "doorbell target-kind model factory returned null or wrong type"
      );
    model.kind = kind;
    model.target_h = target_h;
    status = model.validate();
    return normalize_status(
      status,
      RDMA_SC_INVALID_STATE,
      "doorbell target-kind validation"
    );
  endfunction

  // 功能：校验 hardware image 的长度、alignment、endian、metadata 和 Function generation 基本形状。
  // 输入/输出及副作用：image/function_generation 为只读输入；返回检查 status，不修改 bytes 或 metadata。
  // 失败/边界：null/空长/长度不符/非二次幂 alignment/非法 endian/
  //   不完整 metadata 返回 INVALID_ARGUMENT；generation 不符返回 STALE_GENERATION。
  protected function rdma_status image_shape_status(
    rdma_hw_image image,
    int unsigned function_generation
  );
    if (image == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "hardware image is null");
    if (image.length == 0 || image.bytes.size() != image.length)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "hardware image length does not match bytes"
      );
    if (image.alignment == 0 ||
        (image.alignment & (image.alignment - 1'b1)) != 0)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "hardware image alignment is invalid");
    if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}))
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "hardware image endian is invalid");
    if (image.image_kind == RDMA_IMAGE_NONE || image.hardware_version == 0)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "hardware image metadata is incomplete");
    if (image.function_generation != function_generation)
      return make_status_direct(RDMA_SC_STALE_GENERATION,
                                "hardware image generation is stale");
    return make_status_direct(RDMA_SC_OK);
  endfunction

  // 功能：校验 doorbell payload 的 image/width/endian/BAR target、alignment
  //   和 notify aperture，并计算绝对 BAR 地址。
  // 输入/输出及副作用：binding/desc 为只读输入，absolute_address 先清零；成功写入 notify_base+relative_offset。
  // 失败/边界：image 形状/类型/target/offset 不符、aperture 越界或任一 64-bit 地址加法溢出时返回错误，地址不作为有效结果消费。
  protected function rdma_status payload_status(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    output rdma_bar_addr_t absolute_address
  );
    rdma_status status;

    absolute_address = '0;
    if (desc.payload_image == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell payload image is null");
    status = normalize_status(
      image_shape_status(desc.payload_image,
                         desc.function_h.generation),
      RDMA_SC_INVALID_STATE,
      "doorbell payload image validation"
    );
    if (!status.ok())
      return status;
    if (desc.width == 0 || desc.payload_image.length != desc.width ||
        desc.payload_image.bytes.size() != desc.width)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell width does not match payload image"
      );
    if (desc.endian != desc.payload_image.endian)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell endian does not match payload image"
      );
    if (desc.payload_image.image_kind != RDMA_IMAGE_DOORBELL)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "payload image is not a doorbell");
    if (desc.payload_image.write_target_kind != RDMA_HW_TARGET_BAR)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell payload target is not a BAR"
      );
    if (desc.payload_image.bar_target.value != desc.relative_offset)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "payload BAR offset does not match descriptor"
      );
    if ((desc.relative_offset &
         (desc.payload_image.alignment - 1'b1)) != 0)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell offset violates image alignment"
      );
    if (desc.relative_offset > binding.notify_size ||
        desc.width > (binding.notify_size - desc.relative_offset))
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell write is outside notify aperture"
      );

    // 此处要求 notify aperture 的半开区间末端可表示，保证后续范围运算无回绕。
    if (binding.notify_base.value >
        (64'hffff_ffff_ffff_ffff - binding.notify_size))
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "notify aperture end overflows 64 bits"
      );
    if (binding.notify_base.value >
        (64'hffff_ffff_ffff_ffff - desc.relative_offset))
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell absolute address overflows 64 bits"
      );
    absolute_address.value = binding.notify_base.value + desc.relative_offset;
    if (absolute_address.value >
        (64'hffff_ffff_ffff_ffff - (desc.width - 1'b1)))
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell write end overflows 64 bits"
      );
    return make_status_direct(RDMA_SC_OK);
  endfunction

  // 功能：校验单条 dependency 的 identity/stage/readiness、backing image 和 queue-DMA read authority。
  // 输入/输出及副作用：binding/desc/dependency 为只读输入；
  //   通过 mapping.check_access 验证完整 requester/PASID/domain/IOVA 范围。
  // 失败/边界：null/零 ID/非法 stage/not-ready/null mapping/image/错 target/alignment
  //   返回参数或状态错误；IOVA 溢出/authority 失败原样返回。
  protected function rdma_status dependency_status(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    rdma_doorbell_dependency dependency
  );
    rdma_status status;
    rdma_iova_t first_iova;
    rdma_dma_permission_t read_permission;

    if (dependency == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell dependency is null");
    if (dependency.dependency_id == 0)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell dependency ID is zero");
    if (!(dependency.stage inside {RDMA_DB_DEP_PAYLOAD,
                                   RDMA_DB_DEP_QUEUE_CONTEXT}))
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell dependency stage is invalid"
      );
    if (!dependency.ready)
      return make_status_direct(RDMA_SC_INVALID_STATE,
                                "doorbell dependency is not ready");
    if (dependency.mapping == null)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell dependency mapping is null"
      );
    status = normalize_status(
      image_shape_status(dependency.image, desc.function_h.generation),
      RDMA_SC_INVALID_STATE,
      "doorbell dependency image validation"
    );
    if (!status.ok())
      return status;
    if (dependency.image.write_target_kind != RDMA_HW_TARGET_BACKING)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "dependency image target is not backing memory"
      );
    if (dependency.mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - dependency.relative_offset))
      return make_status_direct(
        RDMA_SC_DMA_TRANSLATION,
        "dependency IOVA overflows 64 bits"
      );

    first_iova.value = dependency.mapping.iova.value +
                       dependency.relative_offset;
    read_permission = '{device_read:1'b1, device_write:1'b0, atomic:1'b0};
    status = normalize_status(
      dependency.mapping.check_access(
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
      ),
      RDMA_SC_INVALID_STATE,
      "doorbell dependency DMA authority check"
    );
    if (!status.ok())
      return status;
    if ((dependency.relative_offset &
         (dependency.image.alignment - 1'b1)) != 0)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "dependency offset violates image alignment"
      );
    return status;
  endfunction

  // 功能：在任何外部 I/O 前完整验证配置、锁定 identity、binding lifecycle、
  //       doorbell/target、payload 和全部 dependency。
  // 输入/输出及副作用：binding/desc/locked Function identity/reset epoch 为只读输入；
  //       absolute_address 先清零，成功写入已验证 BAR 地址。
  // 失败/边界：scheduler 未配置，identity/generation/handle/policy/payload/dependency
  //       非法、reset epoch 漂移、status 为空或 dependency ID 重复时返回对应错误，且不触发 adapter。
  protected function rdma_status preflight(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    longint unsigned locked_function_uid,
    int unsigned locked_object_id,
    rdma_reset_epoch_t locked_reset_epoch,
    output rdma_bar_addr_t absolute_address
  );
    rdma_status status;
    bit seen_ids[longint unsigned];

    absolute_address = '0;
    if (binding == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "function binding is null");
    if (desc == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell descriptor is null");
    if (!configured || host_mem == null || pcie == null)
      return make_status_direct(RDMA_SC_INVALID_STATE,
                                "doorbell scheduler is not configured");
    if (binding.function_uid != locked_function_uid ||
        binding.global_function_id != locked_object_id)
      return make_status_direct(RDMA_SC_INVALID_STATE,
                                "binding identity changed while waiting");
    if (locked_reset_epoch != 0 && binding.function_reset_epoch() != 0 &&
        binding.function_reset_epoch() != locked_reset_epoch)
      return make_status_direct(
        RDMA_SC_STALE_GENERATION,
        "Function reset epoch changed while waiting"
      );

    status = normalize_status(
      binding.validate(),
      RDMA_SC_INVALID_STATE,
      "Function binding validation"
    );
    if (!status.ok())
      return status;
    if (binding.state != RDMA_BIND_ACTIVE)
      return make_status_direct(RDMA_SC_INVALID_STATE,
                                "function binding is not ACTIVE");
    if (desc.function_h == null ||
        desc.function_h.kind != RDMA_RESOURCE_FUNCTION)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell Function handle is invalid");
    if (desc.function_h.function_uid != binding.function_uid ||
        desc.function_h.object_id != binding.global_function_id)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell Function does not match binding");
    if (desc.function_h.generation != binding.generation)
      return make_status_direct(RDMA_SC_STALE_GENERATION,
                                "doorbell Function generation is stale");
    if (desc.target_h == null)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell target handle is null");
    if (desc.target_h.function_uid != desc.function_h.function_uid)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell target belongs to another Function"
      );
    if (desc.target_h.generation != desc.function_h.generation)
      return make_status_direct(RDMA_SC_STALE_GENERATION,
                                "doorbell target generation is stale");
    status = normalize_status(
      target_kind_status(desc.kind, desc.target_h),
      RDMA_SC_INVALID_STATE,
      "doorbell target-kind check"
    );
    if (!status.ok())
      return status;
    if (desc.notify_bar_id != binding.notify_bar_id)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "doorbell notify BAR does not match binding"
      );
    if (desc.timeout == 0)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell timeout is zero");
    if (desc.merge_requested && !desc.allow_merge)
      return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                "doorbell merge was not allowed");
    if (desc.write_combining_policy == RDMA_DB_WRITE_NON_COMBINING &&
        desc.merge_requested)
      return make_status_direct(
        RDMA_SC_INVALID_ARGUMENT,
        "non-combining doorbell cannot be merged"
      );
    if (desc.readback_policy != RDMA_DB_READBACK_NONE)
      return make_status_direct(
        RDMA_SC_UNSUPPORTED_OPCODE,
        "doorbell readback is unsupported"
      );

    status = normalize_status(
      payload_status(binding, desc, absolute_address),
      RDMA_SC_INVALID_STATE,
      "doorbell payload check"
    );
    if (!status.ok())
      return status;

    seen_ids.delete();
    foreach (desc.dependencies[i]) begin
      if (desc.dependencies[i] == null)
        return make_status_direct(RDMA_SC_INVALID_ARGUMENT,
                                  "doorbell dependency is null");
      if (seen_ids.exists(desc.dependencies[i].dependency_id))
        return make_status_direct(
          RDMA_SC_INVALID_ARGUMENT,
          "doorbell dependency ID is duplicated"
        );
      seen_ids[desc.dependencies[i].dependency_id] = 1'b1;
      status = normalize_status(
        dependency_status(binding, desc, desc.dependencies[i]),
        RDMA_SC_INVALID_STATE,
        "doorbell dependency check"
      );
      if (!status.ok())
        return status;
    end
    return make_status_direct(RDMA_SC_OK);
  endfunction

  // 功能：把已通过 preflight 的 hardware image queue 复制为 adapter 调用专用动态数组。
  // 输入/输出及副作用：image 为只读输入，data 为输出；按 bytes.size 分配并逐字节复制，不修改 image。
  // 失败/边界：调用方必须先保证 image 非空且 length/bytes 一致；本 helper 不再校验，也不产生 status。
  protected function void copy_image_bytes(
    rdma_hw_image image,
    output byte data[]
  );
    data = new[image.bytes.size()];
    foreach (data[i])
      data[i] = image.bytes[i];
  endfunction

  // 功能：按 descriptor 内顺序写完指定 dependency stage，并在每个真实
  //   write 前发布 MAYBE_VISIBLE。
  // 输入/输出及副作用：desc/stage 和 call-local result 为输入；调用
  //   host_mem.write，并把 detached status/effect 写入 result。
  // 失败/边界：image 本地准备失败前不推进 effect；任一 write 拒绝、返回
  //   null 或 status 构造失败时立即停止，保持 HOST_MEMORY_MAYBE_VISIBLE。
  protected task write_dependency_stage(
    rdma_doorbell_desc desc,
    rdma_doorbell_dependency_stage_e stage,
    rdma_doorbell_submission_result result
  );
    byte data[];
    rdma_status adapter_status;
    string status_context;

    foreach (desc.dependencies[i]) begin
      if (desc.dependencies[i].stage != stage)
        continue;
      copy_image_bytes(desc.dependencies[i].image, data);
      status_context = $sformatf("doorbell_dependency_%0d", i);
      result.submission_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      adapter_status = host_mem.write(desc.dependencies[i].mapping,
                                      desc.dependencies[i].relative_offset,
                                      data);
      if (!capture_external_status(adapter_status, result, status_context))
        return;
      if (!result.status.ok())
        return;
    end
  endtask

  // 功能：在 Function lock 内完成 preflight、两阶段依赖写、barrier 和 MMIO，
  //   并单调推进 per-call effect。
  // 输入/输出及副作用：binding/desc/锁定 identity/deadline、非拥有 observer
  //   和 call-local result 为输入；驱动 Host-memory/PCIe 并更新 result。
  // 失败/边界：preflight 保持 PRE_SUBMIT_REJECTED；写/barrier/MMIO 失败保留
  //   对应高水位；MMIO 成功后 nested 构造失败仍保持 MMIO_VISIBLE。
  protected task submit_locked(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    longint unsigned locked_function_uid,
    int unsigned locked_object_id,
    rdma_reset_epoch_t locked_reset_epoch,
    time deadline,
    rdma_doorbell_submission_observer observer,
    rdma_doorbell_submission_result result
  );
    rdma_bar_addr_t absolute_address;
    byte payload[];
    rdma_status operation_status;
    bit mmio_succeeded;

    operation_status = preflight(binding, desc, locked_function_uid,
                                 locked_object_id, locked_reset_epoch,
                                 absolute_address);
    capture_pre_submit_status(operation_status, result);
    if (!result.status.ok())
      return;

    write_dependency_stage(desc, RDMA_DB_DEP_PAYLOAD, result);
    if (!result.status.ok())
      return;
    write_dependency_stage(desc, RDMA_DB_DEP_QUEUE_CONTEXT, result);
    if (!result.status.ok())
      return;
    result.submission_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN;

    if (desc.barrier_policy inside {RDMA_DB_BARRIER_DMA,
                                    RDMA_DB_BARRIER_DMA_MMIO}) begin
      dma_barrier_before_deadline(desc.function_h, deadline,
                                  operation_status);
      if (!capture_external_status(operation_status, result,
                                   "doorbell_dma_barrier") ||
          !result.status.ok())
        return;
      result.submission_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
    end
    else begin
      result.submission_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
    end

    if (desc.barrier_policy inside {RDMA_DB_BARRIER_MMIO,
                                    RDMA_DB_BARRIER_DMA_MMIO}) begin
      mmio_barrier_before_deadline(desc.function_h, deadline,
                                   operation_status);
      if (!capture_external_status(operation_status, result,
                                   "doorbell_mmio_barrier") ||
          !result.status.ok())
        return;
    end

    copy_image_bytes(desc.payload_image, payload);
    mmio_write_before_deadline(desc.function_h, absolute_address, payload,
                               deadline, observer, result, operation_status);
    if (result.submission_effect ==
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED) begin
      capture_pre_submit_status(operation_status, result);
      return;
    end

    mmio_succeeded = operation_status != null && operation_status.ok();
    void'(capture_external_status(operation_status, result,
                                  "doorbell_mmio_write"));
    if (!mmio_succeeded)
      return;

    void'(publish_doorbell_result(desc, absolute_address, result));
  endtask

  // 功能：为一次 doorbell 调用直接建立 observed envelope，冻结入口依赖数，
  //   再在 Function lock 内执行并发布 effect。
  // 输入/输出及副作用：binding/desc 和非拥有 observer 为输入，result 为独占
  //   输出；可能驱动 Host-memory/PCIe，observer 至多同步调用一次。
  // 失败/边界：null/timeout/snapshot/preflight/锁失败返回非空
  //   PRE_SUBMIT_REJECTED envelope；取得锁后的退出都释放 token，effect 不回退。
  virtual task submit_observed(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    rdma_doorbell_submission_observer observer,
    output rdma_doorbell_submission_result result
  );
    longint unsigned locked_function_uid;
    int unsigned locked_object_id;
    rdma_reset_epoch_t locked_reset_epoch;
    semaphore function_lock;
    rdma_function_binding binding_snapshot;
    rdma_doorbell_desc desc_snapshot;
    rdma_status operation_status;
    time request_timeout;
    time deadline;
    bit lock_acquired;

    result = new("doorbell_submission_result");
    result.dependency_count = (desc == null) ? 0 : desc.dependencies.size();
    if (binding == null) begin
      void'(rdma_status::set_fields_noalloc(result.status, RDMA_SC_INVALID_ARGUMENT,
                              "function binding is null"));
      return;
    end
    if (desc == null) begin
      void'(rdma_status::set_fields_noalloc(result.status, RDMA_SC_INVALID_ARGUMENT,
                              "doorbell descriptor is null"));
      return;
    end

    // 这里的 descriptor timeout 是取锁前唯一必须读取的标量；入口只冻结一次，
    //   因此 caller 在排队期间的 mutation 不能延长本次请求预算。
    request_timeout = desc.timeout;
    if (request_timeout == 0) begin
      void'(rdma_status::set_fields_noalloc(result.status, RDMA_SC_INVALID_ARGUMENT,
                              "doorbell timeout is zero"));
      return;
    end
    deadline = $time + request_timeout;
    if (deadline < $time) begin
      void'(rdma_status::set_fields_noalloc(
        result.status, RDMA_SC_INVALID_ARGUMENT,
        "doorbell deadline overflows simulation time"
      ));
      return;
    end

    // 锁 key 故意排除 generation：同一 immutable Function identity 的
    //   teardown/rebind 必须与旧 incarnation 串行。
    locked_function_uid = binding.function_uid;
    locked_object_id = binding.global_function_id;
    // reset epoch 随入口 identity 一并冻结；它不在 legacy Function handle 的
    //   wire 字段中，必须独立保存，才能在等待 lock 期间识别 reset 后的 binding。
    locked_reset_epoch = binding.function_reset_epoch();
    function_lock = lock_for(locked_function_uid, locked_object_id);
    acquire_function_lock_before_deadline(function_lock, deadline,
                                          lock_acquired, operation_status);
    capture_pre_submit_status(operation_status, result);
    if (!lock_acquired)
      return;

    // 取得 immutable-identity lock 后，先对 caller-owned binding 做一次动态分派的
    //   authority 校验，再建立 detached snapshot。不能只依赖 clone 后的 base 类型
    //   validate：hostile subtype 或 dpu_common 适配器可能在 clone 时丢失动态行为，
    //   这样会把原 binding 的拒绝结果错误地升级为成功。
    operation_status = normalize_status(
      binding.validate(),
      RDMA_SC_INVALID_STATE,
      "Function binding validation before snapshot"
    );
    capture_pre_submit_status(operation_status, result);

    // 只有原 binding 在锁内通过 authority 校验后才 snapshot；随后只读取 detached
    //   value graph，不再读取 caller-owned 对象。preflight 仍会对 snapshot 重复校验，
    //   用于发现 clone/value graph 不完整，而不是替代上面的动态 authority 检查。
    if (result.status.ok()) begin
      operation_status = clone_binding_snapshot(binding, binding_snapshot);
      capture_pre_submit_status(operation_status, result);
    end
    if (result.status.ok()) begin
      operation_status = clone_desc_snapshot(desc, desc_snapshot);
      capture_pre_submit_status(operation_status, result);
    end
    if (result.status.ok()) begin
      desc_snapshot.timeout = request_timeout;
      submit_locked(binding_snapshot, desc_snapshot, locked_function_uid,
                    locked_object_id, locked_reset_epoch, deadline,
                    observer, result);
    end

    // 这是取得 token 后的唯一出口；preflight、adapter、timeout 和 snapshot
    // 任一失败都只释放上面取得的那个 token。
    function_lock.put(1);
  endtask

  // 功能：兼容旧调用方，把 submit_observed 的一次调用结果单向投影为 detached result/status。
  // 输入/输出及副作用：binding/desc 为输入，result/status 为输出；内部只调用
  //   一次 submit_observed 且不保存 last_* 状态。
  // 失败/边界：observed envelope/status/result 畸形时返回 result=null 和直接构造
  //   INVALID_STATE；合法失败 envelope 可独立投影 null result 与原 status。
  task submit(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    output rdma_doorbell_result result,
    output rdma_status status
  );
    rdma_doorbell_submission_result observed;
    string failure_reason;

    submit_observed(binding, desc, null, observed);
    if (observed == null) begin
      result = null;
      status = make_status_direct(
        RDMA_SC_INVALID_STATE, "observed doorbell result is null"
      );
      return;
    end
    void'(observed.try_project_legacy(result, status, failure_reason));
  endtask
endclass
