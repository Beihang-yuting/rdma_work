// 目录：测试层 tests/unit。
// 职责：验证 doorbell scheduler 的预检、分阶段 Host-memory 写、barrier、
//   MMIO 截止时间、按 Function 串行化及每次调用 submission evidence 契约。
//   状态矩阵分别验证 adapter 原始诊断传输与 legacy 枚举准入，避免重构时混用两者。
// 依赖：rdma core 公开类型、UVM，rdma_mock_host_mem/rdma_mock_pcie、
//   可控 factory 故障 wrapper 与调用 trace。
// 所有权与生命周期：测试 phase 拥有本地 fixture 和断言证据；传给 DUT 的
//   binding、mapping 和 adapter 均是测试生命周期内的非拥有引用。

// 设计说明：observer 只记录 scheduler 越过 MMIO 最后截止检查的次数，
// 不在回调内分配、等待或反向调用 DUT，以精确隔离“准备进入 PCIe”边界。
class rdma_doorbell_counting_observer
  extends rdma_doorbell_submission_observer;

  int unsigned calls;

  // 功能：构造一个调用计数为零的 doorbell MMIO 边界 observer。
  // 输入/输出及副作用：name 仅传给 uvm_object；将本地 calls 置零。
  // 失败/边界：构造不访问 adapter/scheduler，不取得任何外部资源所有权。
  function new(string name = "rdma_doorbell_counting_observer");
    super.new(name);
    calls = 0;
  endfunction

  // 功能：同步记录 scheduler 即将发起 PCIe MMIO 的一次可观察边界。
  // 输入/输出及副作用：无输入和返回值；仅将本地 calls 加一。
  // 失败/边界：回调不可失败，不分配、不等待、不取锁且不调用任何 service。
  virtual function void before_mmio_maybe_visible();
    calls++;
  endfunction

  // 功能：在独立测试场景之间清空 observer 计数，避免跨调用污染。
  // 输入/输出及副作用：无输入和返回值；将本地 calls 置零。
  // 失败/边界：重复调用幂等；不影响已返回的 observed result 或 DUT 状态。
  function void clear();
    calls = 0;
  endfunction
endclass

// 设计说明：该 PCIe 替身让 DMA barrier 在整个 deadline 时刻完成，
// 用于验证 barrier 成功后、PCIe MMIO 入口前的最后 deadline 拒绝。
class rdma_doorbell_deadline_edge_pcie extends rdma_mock_pcie;
  `uvm_object_utils(rdma_doorbell_deadline_edge_pcie)

  time dma_delay;

  // 功能：构造默认不延迟的 deadline-edge PCIe 测试替身。
  // 输入/输出及副作用：name 传给父类；将本地 dma_delay 置零。
  // 失败/边界：未配置 dma_delay 时与普通成功 barrier 等价，不接管 PCIe 资源。
  function new(string name = "rdma_doorbell_deadline_edge_pcie");
    super.new(name);
    dma_delay = 0;
  endfunction

  // 功能：记录 DMA barrier，等待 dma_delay 后返回明确成功状态。
  // 输入/输出及副作用：function_h 是非拥有路由值，status 输出直接构造的 OK；task 推进仿真时间。
  // 失败/边界：dma_delay 达到请求 deadline 时，scheduler 必须在 MMIO 入口前返回 TIMEOUT。
  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    void'(record_call("dma_visibility_barrier", '0, '0, '0, '0,
                      function_h));
    #(dma_delay);
    status = new("deadline_edge_dma_status");
  endtask
endclass

// 设计说明：Host-memory 替身先执行真实 mock write，再打开
//   status raw-factory 故障窗口并返回预构造失败，定位首个外部写后的构造降级。
class rdma_doorbell_post_write_factory_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_doorbell_post_write_factory_mem)

  rdma_cmq_value_factory_fault_wrapper status_fault;
  rdma_status injected_status;
  bit wrong_type;
  bit armed_once;

  // 功能：构造未武装的 Host-memory 写后 factory 故障替身。
  // 输入/输出及副作用：name 传给父类；清空 status_fault/injected_status 并将模式置默认。
  // 失败/边界：未调用 arm_after_next_write 时不注入故障，外部 mapping 仍由父类 mock 管理。
  function new(string name = "rdma_doorbell_post_write_factory_mem");
    super.new(name);
    status_fault = null;
    injected_status = null;
    wrong_type = 1'b0;
    armed_once = 1'b0;
  endfunction

  // 功能：配置下一次成功写后的 status raw-factory 模式和返回失败值。
  // 输入/输出及副作用：fault、response、return_wrong_type 为非拥有输入；保存本地测试配置。
  // 失败/边界：fault 或 response 为 null 时后续 write 不武装 factory，防止测试 fixture 自身 fatal。
  function void arm_after_next_write(
    rdma_cmq_value_factory_fault_wrapper fault,
    rdma_status response,
    bit return_wrong_type
  );
    status_fault = fault;
    injected_status = response;
    wrong_type = return_wrong_type;
    armed_once = (fault != null && response != null);
  endfunction

  // 功能：执行父类 Host-memory write，在其真实记录/写入完成后注入一次状态构造故障。
  // 输入/输出及副作用：mapping、offset、data 传给父类；返回 injected_status 并武装 status_fault。
  // 失败/边界：父类 write 失败或未武装时原样返回；故障只消费一次。
  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_status status;

    status = super.write(mapping, offset, data);
    if (status != null && status.ok() && armed_once) begin
      armed_once = 1'b0;
      status_fault.arm(wrong_type);
      return injected_status;
    end
    return status;
  endfunction
endclass

// 设计说明：PCIe 替身在记录 MMIO 后才打开指定 raw-factory
// 故障，使 scheduler 必须保留 MMIO_VISIBLE 高水位并用直接构造降级。
class rdma_doorbell_post_mmio_factory_pcie extends rdma_mock_pcie;
  `uvm_object_utils(rdma_doorbell_post_mmio_factory_pcie)

  rdma_cmq_value_factory_fault_wrapper post_mmio_fault;
  bit wrong_type;
  bit armed_once;
  rdma_status success_status;

  // 功能：构造未武装的 MMIO 后 factory 故障 PCIe 替身，预先直接构造 OK 状态。
  // 输入/输出及副作用：name 传给父类；初始化本地 fault 配置和 success_status。
  // 失败/边界：成功状态在 factory 武装前建立；本类不取得 function_h 所有权。
  function new(string name = "rdma_doorbell_post_mmio_factory_pcie");
    super.new(name);
    post_mmio_fault = null;
    wrong_type = 1'b0;
    armed_once = 1'b0;
    success_status = new("post_mmio_success_status");
  endfunction

  // 功能：配置下一次 MMIO 记录后武装的 raw-factory 故障。
  // 输入/输出及副作用：fault 为非拥有 wrapper，return_wrong_type 选择 null/错误类型；更新本地状态。
  // 失败/边界：fault 为 null 时保持未武装；重复配置只覆盖下一次模式。
  function void arm_after_next_mmio(
    rdma_cmq_value_factory_fault_wrapper fault,
    bit return_wrong_type
  );
    post_mmio_fault = fault;
    wrong_type = return_wrong_type;
    armed_once = (fault != null);
  endfunction

  // 功能：记录一次成功 PCIe MMIO，再武装后续结果/status 构造故障。
  // 输入/输出及副作用：function_h、address、data 被记录；status 返回预构造 OK 值；可更新 fault 状态。
  // 失败/边界：故障只消费一次；武装发生在 MMIO 记录后，不得被分类为未提交。
  virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );
    void'(record_call("mmio_write", '0, '0, '0, '0, function_h,
                      address, data));
    status = success_status;
    if (armed_once) begin
      armed_once = 1'b0;
      post_mmio_fault.arm(wrong_type);
    end
  endtask
endclass

// 设计说明：该 descriptor 只在公共入口的 snapshot 阶段返回 null，
// 证明失败前已冻结声明 dependency_count，且不会误报外部可见性。
class rdma_doorbell_snapshot_fault_desc extends rdma_doorbell_desc;
  `uvm_object_utils(rdma_doorbell_snapshot_fault_desc)

  // 功能：构造一个仅覆盖 clone 的 descriptor snapshot 故障 fixture。
  // 输入/输出及副作用：name 传给父类；其他字段由测试通过 copy 填充。
  // 失败/边界：构造本身成功；只有后续 clone 被故意拒绝。
  function new(string name = "rdma_doorbell_snapshot_fault_desc");
    super.new(name);
  endfunction

  // 功能：将入口 descriptor snapshot 故障注入为 null clone 结果。
  // 输入/输出及副作用：无输入；返回 null，不修改 source descriptor。
  // 失败/边界：该故障仅用于测试 snapshot 拒绝，不能作为有效复制值消费。
  virtual function uvm_object clone();
    return null;
  endfunction
endclass

// 设计说明：三个 hostile value 在 clone 时返回 null 并计数，
// 用于证明 legacy 投影只按显式字段直接复制 envelope 及其嵌套值。
class rdma_doorbell_clone_fault_result extends rdma_doorbell_result;
  `uvm_object_utils(rdma_doorbell_clone_fault_result)

  local static int unsigned clone_calls;

  // 功能：构造一个只在 clone 时故障的 doorbell result fixture。
  // 输入/输出及副作用：name 传给父类；不改写公共结果默认字段。
  // 失败/边界：构造不触发故障，clone 才返回 null；不接管嵌套 handle。
  function new(string name = "rdma_doorbell_clone_fault_result");
    super.new(name);
  endfunction

  // 功能：记录并拒绝一次 doorbell result clone，检测不应出现的 clone 依赖。
  // 输入/输出及副作用：无输入；clone_calls 加一并返回 null。
  // 失败/边界：返回 null 是故意故障；生产 nonfatal 投影不得调用本函数。
  virtual function uvm_object clone();
    clone_calls++;
    return null;
  endfunction

  // 功能：清空 doorbell result clone 调用计数，用于隔离投影场景。
  // 输入/输出及副作用：无输入和返回值；只写静态 clone_calls。
  // 失败/边界：重复调用幂等，不改变已构造结果字段。
  static function void clear_clone_calls();
    clone_calls = 0;
  endfunction

  // 功能：返回当前 doorbell result clone 故障入口被调用的次数。
  // 输入/输出及副作用：无输入；返回 clone_calls，不修改任何对象。
  // 失败/边界：未发生 clone 时返回零；计数仅是测试证据。
  static function int unsigned get_clone_calls();
    return clone_calls;
  endfunction
endclass

// 设计说明：该 hostile status 只禁止 clone 并记录调用次数，
//   用于证明 legacy status 投影依赖显式标量复制，不依赖 UVM clone。
class rdma_doorbell_clone_fault_status extends rdma_status;
  `uvm_object_utils(rdma_doorbell_clone_fault_status)

  local static int unsigned clone_calls;

  // 功能：构造一个只在 clone 时故障的 status fixture。
  // 输入/输出及副作用：name 传给父类；公共 status 字段保持可由测试显式填充。
  // 失败/边界：构造不触发 clone 故障，不取得 adapter 或 scheduler 资源。
  function new(string name = "rdma_doorbell_clone_fault_status");
    super.new(name);
  endfunction

  // 功能：记录并拒绝一次 status clone，检测 legacy 投影的 clone 依赖。
  // 输入/输出及副作用：无输入；clone_calls 加一并返回 null。
  // 失败/边界：返回 null 是测试注入；生产投影必须绕开本函数且不产生 UVM fatal。
  virtual function uvm_object clone();
    clone_calls++;
    return null;
  endfunction

  // 功能：清空 status clone 故障调用计数。
  // 输入/输出及副作用：无输入和返回值；只将静态 clone_calls 置零。
  // 失败/边界：重复调用幂等，不改写任何 status 值。
  static function void clear_clone_calls();
    clone_calls = 0;
  endfunction

  // 功能：读取 status clone 故障入口的调用次数。
  // 输入/输出及副作用：无输入；返回 clone_calls，不修改状态。
  // 失败/边界：未调用 clone 时返回零，计数不表示业务状态成功。
  static function int unsigned get_clone_calls();
    return clone_calls;
  endfunction
endclass

// 设计说明：该 hostile envelope 拒绝 outer clone，使测试能分辨
//   try_project_legacy 是否错误复制整个 observed 对象。
class rdma_doorbell_clone_fault_submission_result
  extends rdma_doorbell_submission_result;
  `uvm_object_utils(rdma_doorbell_clone_fault_submission_result)

  local static int unsigned clone_calls;

  // 功能：构造一个 clone 恒失败的 observed envelope fixture。
  // 输入/输出及副作用：name 传给父类；其他 envelope 字段由测试显式配置。
  // 失败/边界：构造本身不失败；只有 clone 入口故意返回 null。
  function new(
    string name = "rdma_doorbell_clone_fault_submission_result"
  );
    super.new(name);
  endfunction

  // 功能：记录并拒绝 observed envelope clone，验证 legacy 投影不复制 outer 对象。
  // 输入/输出及副作用：无输入；clone_calls 加一并返回 null。
  // 失败/边界：故意返回 null；try_project_legacy 必须仍非致命完成。
  virtual function uvm_object clone();
    clone_calls++;
    return null;
  endfunction

  // 功能：清空 observed envelope clone 调用计数。
  // 输入/输出及副作用：无输入和返回值；只写静态 clone_calls。
  // 失败/边界：重复清空幂等，不影响 envelope 中已设置的 effect/status。
  static function void clear_clone_calls();
    clone_calls = 0;
  endfunction

  // 功能：读取 observed envelope clone 故障入口的调用次数。
  // 输入/输出及副作用：无输入；返回 clone_calls，不改写 fixture。
  // 失败/边界：未调用 clone 时返回零；不用于推断任何 submission effect。
  static function int unsigned get_clone_calls();
    return clone_calls;
  endfunction
endclass

// 设计说明：该 PCIe 替身只阻塞指定 Function UID 和方法的一次执行点，
//   以可控 release 验证总 deadline、Function lock token 和跨 Function 独立性。
//   它只记录调用并保存测试控制位，不拥有 function handle 或 scheduler。
class rdma_doorbell_blocking_pcie extends rdma_mock_pcie;
  `uvm_object_utils(rdma_doorbell_blocking_pcie)

  longint unsigned blocked_function_uid;
  string blocked_method;
  bit block_enabled;
  bit barrier_entered;
  bit release_barrier;
  int unsigned blocked_call_count;

  // 功能：构造默认未武装的 PCIe 阻塞 fixture，默认目标为 DMA barrier。
  // 输入/输出及副作用：name 传给父类；清零 UID、入口证据、release 位和计数。
  // 失败/边界：block_enabled=0 时所有 PCIe 调用立即完成；本类不接管 adapter 资源。
  function new(string name = "rdma_doorbell_blocking_pcie");
    super.new(name);
    blocked_function_uid = 0;
    blocked_method = "dma_visibility_barrier";
    block_enabled = 1'b0;
    barrier_entered = 1'b0;
    release_barrier = 1'b0;
    blocked_call_count = 0;
  endfunction

  // 功能：当方法名和 Function UID 同时命中配置时，阻塞至 release_barrier。
  // 输入/输出及副作用：method_name 和非拥有 function_h 为输入；命中时置入口位并计数。
  // 失败/边界：未武装、方法/UID 不匹配或 function_h=null 时不等待；
  //   命中后必须由测试或 watchdog 置 release_barrier，否则 task 持续阻塞。
  protected task block_selected_call(
    string method_name,
    rdma_function_handle function_h
  );
    if (block_enabled && method_name == blocked_method &&
        function_h != null &&
        function_h.function_uid == blocked_function_uid) begin
      barrier_entered = 1'b1;
      blocked_call_count++;
      wait (release_barrier);
    end
  endtask

  // 功能：记录 DMA visibility barrier，先消费注入失败，否则在选中点可控阻塞。
  // 输入/输出及副作用：function_h 用于 trace 与匹配；status 输出注入失败或新建 OK 值。
  // 失败/边界：take_failure 命中时立即返回且不阻塞；选中阻塞时由 scheduler deadline 取消。
  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    void'(record_call("dma_visibility_barrier", '0, '0, '0, '0,
                      function_h));
    status = take_failure("dma_visibility_barrier");
    if (status != null)
      return;
    block_selected_call("dma_visibility_barrier", function_h);
    status = rdma_status::success();
  endtask

  // 功能：记录 MMIO ordering barrier，先消费注入失败，否则在选中点可控阻塞。
  // 输入/输出及副作用：function_h 用于 trace 与匹配；status 输出注入失败或新建 OK 值。
  // 失败/边界：take_failure 命中时立即返回且不阻塞；选中阻塞时由 scheduler deadline 取消。
  virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    void'(record_call("mmio_ordering_barrier", '0, '0, '0, '0,
                      function_h));
    status = take_failure("mmio_ordering_barrier");
    if (status != null)
      return;
    block_selected_call("mmio_ordering_barrier", function_h);
    status = rdma_status::success();
  endtask

  // 功能：记录 MMIO address/data，先消费注入失败，否则在选中点可控阻塞。
  // 输入/输出及副作用：function_h、address、data 写入 trace；status 输出注入失败或 OK。
  // 失败/边界：take_failure 命中时不进入阻塞；阻塞后若未释放，scheduler 必须按 deadline 结束。
  virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );
    void'(record_call("mmio_write", '0, '0, '0, '0, function_h,
                      address, data));
    status = take_failure("mmio_write");
    if (status != null)
      return;
    block_selected_call("mmio_write", function_h);
    status = rdma_status::success();
  endtask
endclass

// 设计说明：主测试将 value-copy、预检、adapter 失败、deadline/锁并发和
//   observed effect 放在同一 fixture 图中，共用身份、mapping 与 trace 以检查恢复后不污染。
//   各辅助函数只构造值或发布断言，DUT 和 adapter 生命周期由 run_phase 管理。
class rdma_doorbell_scheduler_test extends uvm_test;
  `uvm_component_utils(rdma_doorbell_scheduler_test)

  // 功能：构造 doorbell scheduler UVM 单元测试组件。
  // 输入/输出及副作用：name 和 parent 传给 uvm_test；fixture 延迟到 run_phase 创建。
  // 失败/边界：parent 可为 null 以作为顶层测试；构造不配置 DUT 也不取得 adapter 所有权。
  function new(string name = "rdma_doorbell_scheduler_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：断言 status 非空且 code 精确等于 expected，并附加可定位 label。
  // 输入/输出及副作用：label/status/expected 为只读输入；不返回值，偏差发布 UVM_ERROR。
  // 失败/边界：status=null 时只报“null status”并立即返回，避免后续解引用。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null) begin
      `uvm_error(label, "scheduler returned null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：直接构造指定 code/message 的测试 status，使 raw-factory 故障窗口内的 fixture 不触发 typed factory fatal。
  // 输入/输出及副作用：code、message 为输入；返回本函数直接 new 且填充分类/严重度的独立 status。
  // 失败/边界：不调用 type_id::create/clone；未知 code 的 category 依据 rdma_status::category_for 保守计算。
  function automatic rdma_status make_direct_status(
    rdma_status_code_e code,
    string message
  );
    rdma_status status;

    status = new("doorbell_direct_test_status");
    status.category = rdma_status::category_for(code);
    status.code = code;
    status.severity = (code == RDMA_SC_OK) ? RDMA_SEVERITY_INFO
                                           : RDMA_SEVERITY_ERROR;
    status.message = message;
    return status;
  endfunction

  // 功能：统一断言 observed scheduler 的非空、effect、入口 dependency 数、observer 和 detached 输出契约。
  // 输入/输出及副作用：label/result/expected_effect/expected_dependencies、
  //   observer/call count/desc/source_status/expect_doorbell 为只读输入；仅发布断言。
  // 失败/边界：result/status 为 null 时先报错并停止解引用；失败要求
  //   doorbell_result=null，成功要求其与 desc 句柄隔离。
  function automatic void expect_observed_contract(
    string label,
    rdma_doorbell_submission_result result,
    rdma_submission_effect_e expected_effect,
    int unsigned expected_dependencies,
    rdma_doorbell_counting_observer observer,
    int unsigned expected_observer_calls,
    rdma_doorbell_desc desc,
    rdma_status source_status,
    bit expect_doorbell
  );
    if (result == null) begin
      `uvm_error(label, "scheduler returned a null observed envelope")
      return;
    end
    if (result.status == null) begin
      `uvm_error(label, "observed envelope returned a null status")
      return;
    end
    if (result.submission_effect != expected_effect)
      `uvm_error(label,
                 $sformatf("expected effect %s, got %s",
                           expected_effect.name(),
                           result.submission_effect.name()))
    if (result.dependency_count != expected_dependencies)
      `uvm_error(label,
                 $sformatf("expected dependency_count=%0d, got %0d",
                           expected_dependencies, result.dependency_count))
    if (result.before_mmio_maybe_visible_called !=
        (expected_observer_calls != 0))
      `uvm_error(label, "observer-called flag disagrees with expected edge")
    if (observer != null && observer.calls != expected_observer_calls)
      `uvm_error(label,
                 $sformatf("observer calls=%0d, expected %0d",
                           observer.calls, expected_observer_calls))
    if (source_status != null && result.status == source_status)
      `uvm_error(label, "observed status aliases the adapter/source status")

    if (expect_doorbell) begin
      if (result.doorbell_result == null) begin
        `uvm_error(label, "successful observed call omitted doorbell result")
      end
      else if (desc == null ||
               result.doorbell_result.function_h == null ||
               result.doorbell_result.target_h == null ||
               result.doorbell_result.function_h == desc.function_h ||
               result.doorbell_result.target_h == desc.target_h) begin
        `uvm_error(label, "observed doorbell result is incomplete or aliased")
      end
    end
    else if (result.doorbell_result != null) begin
      `uvm_error(label, "failed observed call published a doorbell result")
    end
  endfunction

  // 功能：构造 active binding fixture：Function 取 dpu_common 拓扑（Host0：PF0 + VF1..VF11）中
  //   global ID = function_id 的那个，BDF、BAR0、notify 窗口（BAR0 + 0x2000）、DMA domain 与能力
  //   取自快照投影；测试句柄所用的 function_uid/generation 按参数覆盖（沿快照 route 重建 identity），
  //   并补上运行期就绪位与中断向量。
  // 输入/输出及副作用：返回新 binding，不修改任何输入对象。
  // 失败/边界：function_id 超出 0..11 或快照 global ID 不符报告 UVM_FATAL；identity 重建失败报
  //   UVM_ERROR。
  function automatic rdma_function_binding make_binding(
    string name,
    longint unsigned function_uid,
    int unsigned function_id,
    int unsigned generation
  );
    rdma_function_binding binding;
    rdma_dpu_function dpu;
    rdma_interrupt_vector_binding vector;

    binding = rdma_dpu_test_topology::binding(name, dpu, 11, function_id);
    if (dpu.global_id != function_id)
      `uvm_fatal("BINDING", $sformatf("dpu_common global ID %0d, expected %0d", dpu.global_id,
                                      function_id))
    binding.function_uid = function_uid;
    binding.generation = generation;
    if (!binding.synchronize_identity_from_legacy_mirrors().ok())
      `uvm_error("BINDING", "binding identity resynchronization failed")
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = binding.make_handle();
    vector = '{default:'0};
    vector.function_local_vector = 3;
    vector.hardware_eq_vector = 17;
    vector.msix_table_index = 5;
    vector.enabled = 1'b1;
    binding.interrupt_vectors.push_back(vector);
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
    return binding;
  endfunction

  // 功能：为指定 Function 构造 kind/object_id/generation 一致的目标资源 handle。
  // 输入/输出及副作用：name/kind/object_id 直接填充；从非拥有 function_h 复制 UID 和
  //   generation；返回新 rdma_handle。
  // 失败/边界：function_h 或 factory 结果为 null 会使 fixture 无法构造；函数不过滤 kind/object_id。
  function automatic rdma_handle make_target(
    string name,
    rdma_function_handle function_h,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle target;
    target = rdma_handle::type_id::create(name);
    target.kind = kind;
    target.function_uid = function_h.function_uid;
    target.object_id = object_id;
    target.generation = function_h.generation;
    return target;
  endfunction

  // 功能：构造 big-endian、8-byte aligned doorbell image，并标记 Function generation 与写目标类型。
  // 输入/输出及副作用：深拷贝 payload 到新 image.bytes；复制 function_h.generation；
  //   target_kind=BAR 时把 relative_offset 写入 bar_target。
  // 失败/边界：function_h/factory 结果必须非空；非 BAR 目标不填 bar_target，长度和对齐由 DUT 预检。
  function automatic rdma_hw_image make_image(
    string name,
    rdma_function_handle function_h,
    longint unsigned relative_offset,
    byte unsigned payload[],
    rdma_hw_target_kind_e target_kind
  );
    rdma_hw_image image;
    image = rdma_hw_image::type_id::create(name);
    foreach (payload[i]) image.bytes.push_back(payload[i]);
    image.length = payload.size();
    image.alignment = 8;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_DOORBELL;
    image.hardware_version = 1;
    image.function_generation = function_h.generation;
    image.write_target_kind = target_kind;
    if (target_kind == RDMA_HW_TARGET_BAR)
      image.bar_target.value = relative_offset;
    return image;
  endfunction

  // 功能：从 binding 构造默认 RQ doorbell descriptor，含 8-byte payload、DMA+MMIO barrier
  //   策略与总 100ns deadline，初始不含 dependency。
  // 输入/输出及副作用：name 用于对象命名；从非拥有 binding 复制 Function handle、
  //   notify BAR 和 generation；返回新 desc 及其自有 payload/target 值。
  // 失败/边界：binding/factory 结果必须非空；该辅助函数只生成合法基线，故障由调用方修改注入。
  function automatic rdma_doorbell_desc make_desc(
    string name,
    rdma_function_binding binding
  );
    rdma_doorbell_desc desc;
    rdma_function_handle function_h;
    byte unsigned payload[] = '{8'h00, 8'h00, 8'hc5, 8'h67,
                                8'h00, 8'ha1, 8'h55, 8'h55};
    desc = rdma_doorbell_desc::type_id::create(name);
    function_h = binding.make_handle();
    desc.kind = RDMA_DOORBELL_RQ;
    desc.function_h = function_h;
    desc.target_h = make_target({name, "_qp"}, function_h,
                                RDMA_RESOURCE_QP, 21'h15555);
    desc.notify_bar_id = binding.notify_bar_id;
    desc.relative_offset = 64'h10;
    desc.width = 8;
    desc.endian = RDMA_ENDIAN_BIG;
    desc.payload_image = make_image({name, "_payload"}, function_h,
                                    desc.relative_offset, payload,
                                    RDMA_HW_TARGET_BAR);
    desc.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    desc.write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    desc.allow_merge = 1'b0;
    desc.merge_requested = 1'b0;
    desc.timeout = 100ns;
    desc.readback_policy = RDMA_DB_READBACK_NONE;
    return desc;
  endfunction

  // 功能：构造 ready dependency fixture，其 8-byte backing image 从 value 开始递增。
  // 输入/输出及副作用：dependency_id/stage/relative_offset 直接填充；mapping 作非拥有引用；
  //   function_h 提供 image generation；返回新 dependency 和独立 image。
  // 失败/边界：function_h/factory 结果必须非空；函数不检查 mapping 权限、范围或 stage 合法性。
  function automatic rdma_doorbell_dependency make_dependency(
    string name,
    longint unsigned dependency_id,
    rdma_doorbell_dependency_stage_e stage,
    rdma_dma_mapping mapping,
    longint unsigned relative_offset,
    rdma_function_handle function_h,
    byte unsigned value
  );
    rdma_doorbell_dependency dependency;
    byte unsigned payload[];
    payload = new[8];
    foreach (payload[i]) payload[i] = value + i;
    dependency = rdma_doorbell_dependency::type_id::create(name);
    dependency.dependency_id = dependency_id;
    dependency.stage = stage;
    dependency.mapping = mapping;
    dependency.relative_offset = relative_offset;
    dependency.image = make_image({name, "_image"}, function_h, 0,
                                  payload, RDMA_HW_TARGET_BACKING);
    dependency.ready = 1'b1;
    return dependency;
  endfunction

  // 功能：向 desc 追加一个 queue-context 和一个 payload dependency，故意按反 stage 顺序插入。
  // 输入/输出及副作用：desc.dependencies 增加两项；mapping/function_h 仅用于构造子值。
  // 失败/边界：desc、mapping 和 function_h 必须非空；本函数不清空已有 dependency，
  //   故调用次数会累加声明队列长度。
  function automatic void add_two_dependencies(
    rdma_doorbell_desc desc,
    rdma_dma_mapping mapping,
    rdma_function_handle function_h
  );
    rdma_doorbell_dependency queue_dependency;
    rdma_doorbell_dependency payload_dependency;
    queue_dependency = make_dependency(
      "queue_dependency", 64'd2, RDMA_DB_DEP_QUEUE_CONTEXT,
      mapping, 16, function_h, 8'hb0
    );
    payload_dependency = make_dependency(
      "payload_dependency", 64'd1, RDMA_DB_DEP_PAYLOAD,
      mapping, 8, function_h, 8'ha0
    );
    // 故意交错声明：scheduler 必须按 stage 排序，同时保留每个 stage 内的 caller 顺序。
    desc.dependencies.push_back(queue_dependency);
    desc.dependencies.push_back(payload_dependency);
  endfunction

  // 功能：清空 Host-memory、PCIe 各自调用队列与共享 trace，隔离后续场景。
  // 输入/输出及副作用：mem/pcie/trace 为测试拥有 fixture；函数原地删除三组观测记录。
  // 失败/边界：重复调用幂等；任一输入为 null 会使 fixture 解引用失败，不清理 adapter 故障队列。
  function automatic void clear_observation(
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    mem.calls.delete();
    pcie.calls.delete();
    trace.clear();
  endfunction

  // 功能：断言当前场景未留下任何 Host-memory、PCIe 或共享 trace 调用。
  // 输入/输出及副作用：label 用于报错；mem/pcie/trace 只读；发现记录时发布 UVM_ERROR。
  // 失败/边界：函数不自动清空记录；任一 fixture 为 null 时无法执行检查。
  function automatic void expect_no_side_effects(
    string label,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    if (mem.calls.size() != 0 || pcie.calls.size() != 0 ||
        trace.calls.size() != 0)
      `uvm_error(label, "preflight failure caused adapter side effects")
  endfunction

  // 功能：执行一次预期在外部 I/O 前被拒绝的 legacy submit，并统一验证错误码。
  // 输入/输出及副作用：scheduler/binding/desc 驱动 DUT；expected 给出精确 code；
  //   mem/pcie/trace 在调用前清空，并被检查为无副作用。
  // 失败/边界：除 status 匹配外，result 必须为 null；该辅助 task 不适用于已开始外部 I/O 的失败。
  task automatic expect_rejected(
    string label,
    rdma_doorbell_scheduler scheduler,
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    rdma_status_code_e expected,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    rdma_doorbell_result result;
    rdma_status status;
    clear_observation(mem, pcie, trace);
    result = null;
    scheduler.submit(binding, desc, result, status);
    expect_status(label, status, expected);
    if (result != null)
      `uvm_error(label, "rejected submission published a result")
    expect_no_side_effects(label, mem, pcie, trace);
  endtask

  // 功能：断言 trace.calls 的长度与每个方法名都与 expected 队列完全一致。
  // 输入/输出及副作用：label/trace/expected 为只读输入；对长度或元素偏差发布 UVM_ERROR。
  // 失败/边界：长度不同时立即返回以避免越界；trace=null 时无法检查。
  function automatic void expect_trace(
    string label,
    rdma_mock_call_trace trace,
    string expected[]
  );
    if (trace.calls.size() != expected.size()) begin
      `uvm_error(label,
                 $sformatf("trace has %0d calls, expected %0d",
                           trace.calls.size(), expected.size()))
      return;
    end
    foreach (expected[i]) begin
      if (trace.calls[i] != expected[i])
        `uvm_error(label,
                   $sformatf("call %0d is %s, expected %s", i,
                             trace.calls[i], expected[i]))
    end
  endfunction

  // 功能：故障场景后向同一 Function 发起新的无 dependency submit，验证 lock/超时资源已恢复。
  // 输入/输出及副作用：label 命名 fixture/报错；scheduler 被驱动；binding 提供原 Function 身份。
  // 失败/边界：恢复调用必须同时返回 RDMA_SC_OK 和非空 result；本 task 不清空 adapter trace。
  task automatic expect_recovery_submit(
    string label,
    rdma_doorbell_scheduler scheduler,
    rdma_function_binding binding
  );
    rdma_doorbell_desc recovery_desc;
    rdma_doorbell_result recovery_result;
    rdma_status recovery_status;

    recovery_desc = make_desc({label, "_desc"}, binding);
    scheduler.submit(binding, recovery_desc, recovery_result, recovery_status);
    expect_status(label, recovery_status, RDMA_SC_OK);
    if (recovery_result == null)
      `uvm_error(label, "same-Function recovery did not publish a result")
  endtask

  // 功能：验证 dependency、descriptor 和 legacy doorbell result 的 UVM clone 保留标量且深拷贝可变值图。
  // 输入/输出及副作用：binding/allocated_mapping 为只读 fixture；task 构造源值、clone、
  //   变异源图并发布 UVM_ERROR，同时检查 mock mapping 的不透明 allocation identity。
  // 失败/边界：allocated_mapping clone 为 null/错类型时报错并返回；其他缺失子值只报错并防止解引用。
  task automatic check_value_clone_contracts(
    rdma_function_binding binding,
    rdma_dma_mapping allocated_mapping
  );
    uvm_object cloned_object;
    rdma_dma_mapping source_mapping;
    rdma_mock_dma_mapping source_mock_mapping;
    rdma_mock_dma_mapping cloned_mock_mapping;
    rdma_doorbell_dependency source_dependency;
    rdma_doorbell_dependency cloned_dependency;
    rdma_doorbell_desc source_desc;
    rdma_doorbell_desc cloned_desc;
    rdma_doorbell_result source_result;
    rdma_doorbell_result cloned_result;
    rdma_function_handle function_h;
    longint unsigned expected_mapping_iova;
    byte unsigned expected_dependency_byte;
    byte unsigned expected_payload_byte;

    function_h = binding.make_handle();
    cloned_object = allocated_mapping.clone();
    if (cloned_object == null || !$cast(source_mapping, cloned_object)) begin
      `uvm_error("DB_COPY_SETUP", "could not clone source DMA mapping")
      return;
    end
    source_dependency = make_dependency(
      "copy_dependency", 64'h1234, RDMA_DB_DEP_QUEUE_CONTEXT,
      source_mapping, 8, function_h, 8'h40
    );
    expected_mapping_iova = source_dependency.mapping.iova.value;
    expected_dependency_byte = source_dependency.image.bytes[0];

    cloned_object = source_dependency.clone();
    if (cloned_object == null || !$cast(cloned_dependency, cloned_object)) begin
      `uvm_error("DEPENDENCY_COPY", "dependency clone type was not preserved")
    end
    else begin
      if (cloned_dependency.dependency_id != source_dependency.dependency_id ||
          cloned_dependency.stage != source_dependency.stage ||
          cloned_dependency.relative_offset !=
            source_dependency.relative_offset ||
          cloned_dependency.ready != source_dependency.ready)
        `uvm_error("DEPENDENCY_COPY", "dependency scalar fields were not copied")
      if (cloned_dependency.mapping == null ||
          cloned_dependency.mapping == source_dependency.mapping ||
          cloned_dependency.image == null ||
          cloned_dependency.image == source_dependency.image)
        `uvm_error("DEPENDENCY_COPY", "dependency value handles alias source")
      if (cloned_dependency.mapping == null) begin
        `uvm_error("DEPENDENCY_COPY", "mapping clone was null")
      end
      else if (!$cast(source_mock_mapping, source_dependency.mapping)) begin
        `uvm_error("DEPENDENCY_COPY",
                   "source mapping lost its concrete mock type")
      end
      else if (!$cast(cloned_mock_mapping, cloned_dependency.mapping)) begin
        `uvm_error("DEPENDENCY_COPY",
                   "mapping clone lost its concrete mock type")
      end
      else if (!cloned_mock_mapping.same_allocation(source_mock_mapping)) begin
        `uvm_error("DEPENDENCY_COPY",
                   "mapping clone lost opaque allocation identity")
      end
      if (cloned_dependency.mapping != null &&
          cloned_dependency.mapping.state !=
            source_dependency.mapping.state)
        `uvm_error("DEPENDENCY_COPY", "mapping clone lost mapping state")

      source_dependency.mapping.iova.value++;
      source_dependency.image.bytes[0] ^= 8'hff;
      if (cloned_dependency.mapping == null ||
          cloned_dependency.image == null) begin
        `uvm_error("DEPENDENCY_COPY",
                   "dependency clone omitted nested values")
      end
      else if (cloned_dependency.mapping.iova.value != expected_mapping_iova ||
               cloned_dependency.image.bytes[0] !=
                 expected_dependency_byte) begin
        `uvm_error("DEPENDENCY_COPY",
                   "dependency clone changed after source mutation")
      end
    end

    source_desc = make_desc("copy_desc", binding);
    source_desc.dependencies.push_back(source_dependency);
    expected_payload_byte = source_desc.payload_image.bytes[0];
    cloned_object = source_desc.clone();
    if (cloned_object == null || !$cast(cloned_desc, cloned_object)) begin
      `uvm_error("DESC_COPY", "descriptor clone type was not preserved")
    end
    else begin
      if (cloned_desc.kind != source_desc.kind ||
          cloned_desc.notify_bar_id != source_desc.notify_bar_id ||
          cloned_desc.relative_offset != source_desc.relative_offset ||
          cloned_desc.width != source_desc.width ||
          cloned_desc.endian != source_desc.endian ||
          cloned_desc.barrier_policy != source_desc.barrier_policy ||
          cloned_desc.write_combining_policy !=
            source_desc.write_combining_policy ||
          cloned_desc.allow_merge != source_desc.allow_merge ||
          cloned_desc.merge_requested != source_desc.merge_requested ||
          cloned_desc.timeout != source_desc.timeout ||
          cloned_desc.readback_policy != source_desc.readback_policy)
        `uvm_error("DESC_COPY", "descriptor scalar fields were not copied")
      if (cloned_desc.function_h == null ||
          cloned_desc.target_h == null ||
          cloned_desc.payload_image == null ||
          cloned_desc.dependencies.size() != 1) begin
        `uvm_error("DESC_COPY", "descriptor clone omitted value fields")
      end
      else if (cloned_desc.function_h == source_desc.function_h ||
               cloned_desc.target_h == source_desc.target_h ||
               cloned_desc.payload_image == source_desc.payload_image ||
               cloned_desc.dependencies[0] == source_desc.dependencies[0] ||
               cloned_desc.dependencies[0].mapping ==
                 source_desc.dependencies[0].mapping ||
               cloned_desc.dependencies[0].image ==
                 source_desc.dependencies[0].image) begin
        `uvm_error("DESC_COPY", "descriptor value graph aliases source")
      end
      if (cloned_desc.dependencies.size() == 1 &&
          cloned_desc.dependencies[0].mapping != null &&
          cloned_desc.dependencies[0].mapping.state !=
            source_desc.dependencies[0].mapping.state)
        `uvm_error("DESC_COPY", "nested mapping clone lost mapping state")

      source_desc.function_h.generation++;
      source_desc.target_h.object_id++;
      source_desc.payload_image.bytes[0] ^= 8'hff;
      source_desc.dependencies[0].relative_offset++;
      if (cloned_desc.function_h == null ||
          cloned_desc.target_h == null ||
          cloned_desc.payload_image == null ||
          cloned_desc.dependencies.size() != 1) begin
        `uvm_error("DESC_COPY", "descriptor clone omitted mutation targets")
      end
      else if (cloned_desc.function_h.generation != binding.generation ||
               cloned_desc.target_h.object_id != 21'h15555 ||
               cloned_desc.payload_image.bytes[0] != expected_payload_byte ||
               cloned_desc.dependencies[0].relative_offset != 8) begin
        `uvm_error("DESC_COPY", "descriptor clone changed after source mutation")
      end
    end

    source_result = rdma_doorbell_result::type_id::create("copy_result");
    source_result.kind = RDMA_DOORBELL_RQ;
    source_result.function_h = function_h;
    source_result.target_h = make_target("copy_result_target", function_h,
                                         RDMA_RESOURCE_QP, 21'h15555);
    source_result.absolute_address.value = 64'h1234_5000;
    source_result.width = 8;
    source_result.dependency_count = 3;
    cloned_object = source_result.clone();
    if (cloned_object == null || !$cast(cloned_result, cloned_object)) begin
      `uvm_error("RESULT_COPY", "result clone type was not preserved")
    end
    else begin
      if (cloned_result.kind != source_result.kind ||
          cloned_result.absolute_address != source_result.absolute_address ||
          cloned_result.width != source_result.width ||
          cloned_result.dependency_count != source_result.dependency_count ||
          cloned_result.function_h == null ||
          cloned_result.target_h == null) begin
        `uvm_error("RESULT_COPY", "result fields were not copied")
      end
      else if (cloned_result.function_h == source_result.function_h ||
               cloned_result.target_h == source_result.target_h) begin
        `uvm_error("RESULT_COPY", "result fields were not deep copied")
      end
      source_result.function_h.generation++;
      source_result.target_h.object_id++;
      if (cloned_result.function_h == null ||
          cloned_result.target_h == null) begin
        `uvm_error("RESULT_COPY", "result clone omitted mutation targets")
      end
      else if (cloned_result.function_h.generation != binding.generation ||
               cloned_result.target_h.object_id != 21'h15555) begin
        `uvm_error("RESULT_COPY", "result clone changed after source mutation")
      end
    end
  endtask

  // 功能：验证 observed envelope 的普通 UVM deep-copy，以及不调用 hostile
  //   clone/factory 的 legacy 单向投影。
  // 输入/输出及副作用：binding 为只读 Function fixture；task 构造
  //   source/cloned/projected 值并发布断言，不调用 scheduler 外部 I/O。
  // 失败/边界：普通 clone 必须隔离；hostile outer/result/status clone 不得调用；
  //   null doorbell 可投影，malformed status/result 返回直接构造 INVALID_STATE。
  task automatic check_observed_value_projection(
    rdma_function_binding binding
  );
    rdma_doorbell_submission_result source;
    rdma_doorbell_submission_result cloned;
    rdma_doorbell_clone_fault_submission_result hostile;
    rdma_doorbell_clone_fault_result hostile_result;
    rdma_doorbell_clone_fault_status hostile_status;
    rdma_doorbell_result projected_result;
    rdma_status projected_status;
    uvm_object cloned_object;
    string failure_reason;
    bit projected;

    source = new("observed_copy_source");
    source.status = make_direct_status(RDMA_SC_TIMEOUT,
                                       "observed copy source");
    source.doorbell_result = new("observed_copy_doorbell");
    source.doorbell_result.kind = RDMA_DOORBELL_RQ;
    source.doorbell_result.function_h = binding.make_handle();
    source.doorbell_result.target_h = make_target(
      "observed_copy_target", source.doorbell_result.function_h,
      RDMA_RESOURCE_QP, 21'h15555
    );
    source.doorbell_result.absolute_address.value =
      binding.notify_base.value + 64'h10;
    source.doorbell_result.width = 8;
    source.doorbell_result.dependency_count = 2;
    source.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
    source.dependency_count = 2;
    source.before_mmio_maybe_visible_called = 1'b1;

    cloned_object = source.clone();
    if (cloned_object == null || !$cast(cloned, cloned_object)) begin
      `uvm_error("OBSERVED_COPY", "observed envelope clone failed")
    end
    else if (cloned == source || cloned.status == null ||
             cloned.status == source.status || cloned.doorbell_result == null ||
             cloned.doorbell_result == source.doorbell_result ||
             cloned.doorbell_result.function_h ==
               source.doorbell_result.function_h ||
             cloned.doorbell_result.target_h ==
               source.doorbell_result.target_h ||
             cloned.status.code != RDMA_SC_TIMEOUT ||
             cloned.submission_effect !=
               RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE ||
             cloned.dependency_count != 2 ||
             !cloned.before_mmio_maybe_visible_called) begin
      `uvm_error("OBSERVED_COPY", "observed envelope was not deeply copied")
    end

    hostile = new("hostile_projection_source");
    hostile_status = new("hostile_projection_status");
    hostile_status.category = RDMA_STATUS_TIMEOUT;
    hostile_status.code = RDMA_SC_TIMEOUT;
    hostile_status.severity = RDMA_SEVERITY_ERROR;
    hostile_status.message = "hostile projection timeout";
    hostile_result = new("hostile_projection_result");
    hostile_result.kind = RDMA_DOORBELL_RQ;
    hostile_result.function_h = binding.make_handle();
    hostile_result.target_h = make_target(
      "hostile_projection_target", hostile_result.function_h,
      RDMA_RESOURCE_QP, 21'h15555
    );
    hostile_result.absolute_address.value = binding.notify_base.value + 64'h10;
    hostile_result.width = 8;
    hostile_result.dependency_count = 2;
    hostile.status = hostile_status;
    hostile.doorbell_result = hostile_result;
    hostile.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
    hostile.dependency_count = 2;
    hostile.before_mmio_maybe_visible_called = 1'b1;

    rdma_doorbell_clone_fault_submission_result::clear_clone_calls();
    rdma_doorbell_clone_fault_result::clear_clone_calls();
    rdma_doorbell_clone_fault_status::clear_clone_calls();
    projected = hostile.try_project_legacy(
      projected_result, projected_status, failure_reason
    );
    if (!projected || projected_result == null || projected_status == null ||
        failure_reason != "" || projected_status.code != RDMA_SC_TIMEOUT ||
        projected_status == hostile_status ||
        projected_result == hostile_result ||
        projected_result.function_h == hostile_result.function_h ||
        projected_result.target_h == hostile_result.target_h ||
        projected_result.absolute_address != hostile_result.absolute_address ||
        projected_result.width != 8 ||
        projected_result.dependency_count != 2 ||
        rdma_doorbell_clone_fault_submission_result::get_clone_calls() != 0 ||
        rdma_doorbell_clone_fault_result::get_clone_calls() != 0 ||
        rdma_doorbell_clone_fault_status::get_clone_calls() != 0)
      `uvm_error("LEGACY_DIRECT_PROJECTION",
                 "legacy projection used clone/factory or lost fields")

    hostile.doorbell_result = null;
    projected = hostile.try_project_legacy(
      projected_result, projected_status, failure_reason
    );
    if (!projected || projected_result != null || projected_status == null ||
        projected_status.code != RDMA_SC_TIMEOUT || failure_reason != "")
      `uvm_error("LEGACY_NULL_RESULT",
                 "null observed doorbell result was not projected independently")

    hostile.status = null;
    projected = hostile.try_project_legacy(
      projected_result, projected_status, failure_reason
    );
    if (projected || projected_result != null || projected_status == null ||
        projected_status.code != RDMA_SC_INVALID_STATE || failure_reason == "")
      `uvm_error("LEGACY_NULL_STATUS",
                 "malformed observed status did not fail closed")

    hostile.status = hostile_status;
    hostile_result.function_h = null;
    hostile.doorbell_result = hostile_result;
    projected = hostile.try_project_legacy(
      projected_result, projected_status, failure_reason
    );
    if (projected || projected_result != null || projected_status == null ||
        projected_status.code != RDMA_SC_INVALID_STATE || failure_reason == "")
      `uvm_error("LEGACY_MALFORMED_RESULT",
                 "malformed observed result did not fail closed")
  endtask

  // 功能：构造带完整非默认诊断的 hostile status，按 field 覆盖一个枚举坐标。
  // 输入/输出及副作用：field=0/1/2/3 分别选 category/code/source_engine/severity，
  //   encoding 按实际位宽转换；直接 new 返回测试独占值，故意保留 category/code 不匹配。
  // 失败/边界：其它 field 不覆盖；枚举是二态 bit，不把保留编码矩阵称作 X/Z 注入；
  //   source.clone 仍由既有 hostile 类型拒绝，不调用 factory 或生产字段 helper。
  function automatic rdma_doorbell_clone_fault_status make_status_evidence(
    int field, int encoding
  );
    rdma_doorbell_clone_fault_status value;

    value = new("status_evidence");
    value.category = RDMA_STATUS_PCIE;
    value.code = RDMA_SC_TIMEOUT;
    value.hardware_code = 32'h8765_4321;
    value.hardware_code_valid = 1'b1;
    value.source_engine = RDMA_ENGINE_CMQ;
    value.function_uid = 64'h1234_5678_9abc_def0;
    value.generation = 32'h1122_3344;
    value.resource_id = 64'h3141_5926_5358_9793;
    value.command_id = 64'h2384_6264_3383_2795;
    value.wr_id = 64'h0123_4567_89ab_cdef;
    value.severity = RDMA_SEVERITY_WARNING;
    value.retryable = 1'b1;
    value.message = "unmodified adapter evidence";
    case (field)
      0: value.category = rdma_status_category_e'(encoding);
      1: value.code = rdma_status_code_e'(encoding);
      2: value.source_engine = rdma_engine_kind_e'(encoding);
      3: value.severity = rdma_severity_e'(encoding);
      default: ;
    endcase
    return value;
  endfunction

  // 功能：独立断言 status 初始化覆盖全部 13 个字段，并保留指定直接构造名称。
  // 输入/输出及副作用：value/code/message/name 为待验对象及预期；只发布 UVM_ERROR，
  //   不调用生产初始化 helper 生成预期，也不创建状态对象。
  // 失败/边界：null 时立即返回以避免解引用；旧硬件/身份/retry 字段残留或分类/严重度不符均拒绝。
  function automatic void expect_fresh_status(
    rdma_status value, rdma_status_code_e code, string message, string name
  );
    if (value == null) begin
      `uvm_error("DOORBELL_STATUS", "missing initialized status")
      return;
    end
    if (value.category != rdma_status::category_for(code) || value.code != code ||
        value.hardware_code != 0 || value.hardware_code_valid ||
        value.source_engine != RDMA_ENGINE_NONE || value.function_uid != 0 ||
        value.generation != 0 || value.resource_id != 0 || value.command_id != 0 ||
        value.wr_id != 0 || value.retryable || value.message != message ||
        value.severity != (code == RDMA_SC_OK ? RDMA_SEVERITY_INFO : RDMA_SEVERITY_ERROR) ||
        value.get_name() != name)
      `uvm_error("DOORBELL_STATUS", "initialization retained old evidence or changed object name")
  endfunction

  // 功能：穷举 legacy 四个枚举坐标的全部编码，并验证三种 PCIe 调用的原始状态捕获不套用 legacy 准入。
  // 输入/输出及副作用：scheduler/binding/mem/pcie/trace 复用本 test fixture；136 次
  //   legacy 投影使用临时 null/错型 factory，恢复后执行 12 次故障提交；不分配外部 backing。
  // 失败/边界：legacy 拒绝 category/code/source_engine 越界但保留 severity 和合法不匹配分类；
  //   adapter 原始诊断不得规范化，effect/observer 必须保持对应阶段；所有偏差报 UVM_ERROR。
  task automatic check_status_transfer_matrix(
    rdma_doorbell_scheduler scheduler,
    rdma_function_binding binding,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    uvm_coreservice_t service;
    uvm_factory saved_factory;
    uvm_default_factory isolated_factory;
    rdma_cmq_value_factory_fault_wrapper fault;
    rdma_doorbell_clone_fault_status source;
    rdma_doorbell_submission_result envelope, observed;
    rdma_doorbell_result projected_result;
    rdma_status projected_status;
    rdma_doorbell_desc desc;
    rdma_doorbell_counting_observer observer;
    int limits[4] = '{16, 32, 16, 4};
    string operations[3] = '{"dma_visibility_barrier", "mmio_ordering_barrier", "mmio_write"};
    rdma_submission_effect_e effects[3] = '{
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN, RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE
    };
    string reason, source_text;
    bit accepted, expected;
    int unsigned cases;

    service = uvm_coreservice_t::get();
    saved_factory = service.get_factory();
    isolated_factory = new();
    fault = new("legacy_status_fault", rdma_status::get_type());
    isolated_factory.set_type_override_by_type(rdma_status::get_type(), fault);
    service.set_factory(isolated_factory);
    rdma_doorbell_clone_fault_status::clear_clone_calls();
    cases = 0;
    foreach (limits[field]) begin
      for (int encoding = 0; encoding < limits[field]; encoding++) begin
        source = make_status_evidence(field, encoding);
        source_text = source.convert2string();
        expected = (field == 0) ? encoding <= 10 :
                   (field == 1) ? encoding <= 16 :
                   (field == 2) ? encoding <= 11 : 1'b1;
        for (int wrong = 0; wrong < 2; wrong++) begin
          fault.arm(bit'(wrong));
          expect_fresh_status(scheduler.configure(null, pcie), RDMA_SC_INVALID_ARGUMENT,
            "host memory adapter is null", "doorbell_direct_status");
          envelope = new("status_matrix_envelope");
          expect_fresh_status(envelope.status, RDMA_SC_INVALID_STATE,
            "doorbell submission has not completed validation",
            "doorbell_submission_initial_status");
          envelope.status = source;
          envelope.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
          envelope.dependency_count = 3;
          envelope.before_mmio_maybe_visible_called = 1'b1;
          accepted = envelope.try_project_legacy(projected_result, projected_status, reason);
          if (projected_status == null)
            `uvm_fatal("DOORBELL_STATUS", "legacy projection returned null status")
          if (accepted != expected || projected_result != null || projected_status == source ||
              projected_status.get_name() != "legacy_doorbell_status")
            `uvm_error("DOORBELL_STATUS", "legacy admission or detached shape changed")
          if (expected) begin
            if (projected_status.convert2string() != source_text || reason != "")
              `uvm_error("DOORBELL_STATUS", "legacy projection normalized valid evidence")
          end
          else begin
            expect_fresh_status(projected_status, RDMA_SC_INVALID_STATE,
              "observed doorbell status is null or malformed", "legacy_doorbell_status");
            if (reason != "observed doorbell status is null or malformed")
              `uvm_error("DOORBELL_STATUS", "legacy rejection reason changed")
          end
          if (fault.call_count() != 0 || source.convert2string() != source_text ||
              rdma_doorbell_clone_fault_status::get_clone_calls() != 0 ||
              envelope.status != source || envelope.dependency_count != 3 ||
              !envelope.before_mmio_maybe_visible_called ||
              envelope.submission_effect != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE)
            `uvm_error("DOORBELL_STATUS", "projection invoked factory/clone or changed evidence")
          fault.disarm();
          cases++;
        end
      end
    end
    service.set_factory(saved_factory);

    observer = new("status_matrix_observer");
    foreach (operations[operation]) begin
      for (int variant = 0; variant < 4; variant++) begin
        source = make_status_evidence(variant - 1, 31);
        source_text = source.convert2string();
        desc = make_desc("status_matrix_desc", binding);
        desc.barrier_policy = operation == 0 ? RDMA_DB_BARRIER_DMA :
                              operation == 1 ? RDMA_DB_BARRIER_MMIO : RDMA_DB_BARRIER_NONE;
        clear_observation(mem, pcie, trace);
        expect_status("STATUS_MATRIX_ARM",
          pcie.fail_next(operations[operation], source), RDMA_SC_OK);
        observer.clear();
        scheduler.submit_observed(binding, desc, observer, observed);
        expect_observed_contract("STATUS_MATRIX_CAPTURE", observed, effects[operation], 0,
          observer, operation == 2 ? 1 : 0, desc, source, 0);
        if (observed == null || observed.status == null)
          `uvm_fatal("DOORBELL_STATUS", "observed capture returned null evidence")
        if (observed.status.get_name() !=
              (operation == 0 ? "doorbell_dma_barrier_status" :
               operation == 1 ? "doorbell_mmio_barrier_status" : "doorbell_mmio_write_status") ||
            observed.status.convert2string() != source_text ||
            source.convert2string() != source_text || pcie.calls.size() != 1)
          `uvm_error("DOORBELL_STATUS", "adapter capture normalized or lost raw diagnostic fields")
        accepted = observed.try_project_legacy(projected_result, projected_status, reason);
        if (accepted != (variant == 0) || projected_result != null ||
            observed.status.convert2string() != source_text ||
            observed.submission_effect != effects[operation])
          `uvm_error("DOORBELL_STATUS", "legacy rejection changed observed effect or diagnostic")
        cases++;
      end
    end
    clear_observation(mem, pcie, trace);
    if (cases != 148)
      `uvm_error("DOORBELL_STATUS", "status transfer matrix coverage changed")
    `uvm_info("DOORBELL_STATUS", "completed 148 doorbell status transfer cases", UVM_LOW)
  endtask

  // 功能：验证 observed 入口在参数/snapshot/preflight/锁/写/barrier/MMIO
  //   各边界发布精确单调 effect。
  // 输入/输出及副作用：scheduler/binding/mapping/mem/pcie/trace/request_context
  //   为 fixture；task 驱动真实 DUT、可控 adapter 故障和 raw-factory 窗口。
  // 失败/边界：覆盖 null/invalid、声明依赖数、四种 barrier、最后 deadline、
  //   MMIO error/timeout、null observer 和构造故障；偏差报 UVM_ERROR。
  task automatic check_observed_submission_contracts(
    rdma_doorbell_scheduler scheduler,
    rdma_function_binding binding,
    rdma_dma_mapping mapping,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace,
    rdma_dma_request_context request_context
  );
    rdma_doorbell_counting_observer observer;
    rdma_doorbell_submission_result observed;
    rdma_doorbell_submission_result previous_observed;
    rdma_doorbell_desc desc;
    rdma_doorbell_desc owner_desc;
    rdma_doorbell_desc waiter_desc;
    rdma_doorbell_snapshot_fault_desc snapshot_fault_desc;
    rdma_doorbell_dependency dependency;
    rdma_doorbell_result owner_result;
    rdma_status owner_status;
    rdma_status injected;
    rdma_doorbell_barrier_policy_e policies[4];
    rdma_doorbell_blocking_pcie blocking_pcie;
    rdma_doorbell_scheduler blocking_scheduler;
    rdma_pcie_api blocking_api;
    rdma_doorbell_deadline_edge_pcie deadline_pcie;
    rdma_doorbell_scheduler deadline_scheduler;
    rdma_pcie_api deadline_api;
    rdma_doorbell_post_write_factory_mem fault_mem;
    rdma_host_mem_api fault_mem_api;
    rdma_dma_mapping fault_mapping;
    rdma_doorbell_scheduler fault_mem_scheduler;
    rdma_doorbell_post_mmio_factory_pcie fault_pcie;
    rdma_pcie_api fault_pcie_api;
    rdma_doorbell_scheduler fault_pcie_scheduler;
    uvm_factory factory;
    rdma_cmq_value_factory_fault_wrapper envelope_fault;
    rdma_cmq_value_factory_fault_wrapper doorbell_fault;
    rdma_cmq_value_factory_fault_wrapper status_fault;
    bit owner_done;
    bit waiter_done;
    bit watchdog_fired;

    observer = new("doorbell_counting_observer");
    injected = make_direct_status(RDMA_SC_TIMEOUT,
                                  "injected observed scheduler failure");
    policies = '{RDMA_DB_BARRIER_NONE, RDMA_DB_BARRIER_DMA,
                 RDMA_DB_BARRIER_MMIO, RDMA_DB_BARRIER_DMA_MMIO};

    desc = make_desc("observed_null_binding", binding);
    observer.clear();
    scheduler.submit_observed(null, desc, observer, observed);
    expect_status("OBSERVED_NULL_BINDING", observed.status,
                  RDMA_SC_INVALID_ARGUMENT);
    expect_observed_contract(
      "OBSERVED_NULL_BINDING", observed,
      RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, 0, observer, 0, desc, null, 0
    );

    observer.clear();
    scheduler.submit_observed(binding, null, observer, observed);
    expect_status("OBSERVED_NULL_DESC", observed.status,
                  RDMA_SC_INVALID_ARGUMENT);
    expect_observed_contract(
      "OBSERVED_NULL_DESC", observed,
      RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, 0, observer, 0, null, null, 0
    );

    desc = make_desc("observed_preflight", binding);
    desc.width = 4;
    observer.clear();
    scheduler.submit_observed(binding, desc, observer, observed);
    expect_status("OBSERVED_PREFLIGHT", observed.status,
                  RDMA_SC_INVALID_ARGUMENT);
    expect_observed_contract(
      "OBSERVED_PREFLIGHT", observed,
      RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, 0, observer, 0, desc, null, 0
    );

    desc = make_desc("observed_invalid_third_dependency", binding);
    add_two_dependencies(desc, mapping, desc.function_h);
    desc.dependencies.push_back(null);
    observer.clear();
    scheduler.submit_observed(binding, desc, observer, observed);
    expect_status("OBSERVED_INVALID_THIRD", observed.status,
                  RDMA_SC_INVALID_ARGUMENT);
    expect_observed_contract(
      "OBSERVED_INVALID_THIRD", observed,
      RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, 3, observer, 0, desc, null, 0
    );

    desc = make_desc("observed_snapshot_fault_source", binding);
    add_two_dependencies(desc, mapping, desc.function_h);
    snapshot_fault_desc = new("observed_snapshot_fault");
    snapshot_fault_desc.copy(desc);
    observer.clear();
    scheduler.submit_observed(binding, snapshot_fault_desc, observer, observed);
    expect_status("OBSERVED_SNAPSHOT_FAULT", observed.status,
                  RDMA_SC_INVALID_STATE);
    expect_observed_contract(
      "OBSERVED_SNAPSHOT_FAULT", observed,
      RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, 2, observer, 0,
      snapshot_fault_desc, null, 0
    );

    desc = make_desc("observed_first_write_failure", binding);
    add_two_dependencies(desc, mapping, desc.function_h);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_OBSERVED_FIRST_WRITE",
                  mem.fail_write_at(1, injected), RDMA_SC_OK);
    observer.clear();
    scheduler.submit_observed(binding, desc, observer, observed);
    expect_status("OBSERVED_FIRST_WRITE", observed.status, RDMA_SC_TIMEOUT);
    expect_observed_contract(
      "OBSERVED_FIRST_WRITE", observed,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE, 2, observer, 0,
      desc, injected, 0
    );

    desc = make_desc("observed_second_write_failure", binding);
    add_two_dependencies(desc, mapping, desc.function_h);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_OBSERVED_SECOND_WRITE",
                  mem.fail_write_at(2, injected), RDMA_SC_OK);
    observer.clear();
    scheduler.submit_observed(binding, desc, observer, observed);
    expect_status("OBSERVED_SECOND_WRITE", observed.status, RDMA_SC_TIMEOUT);
    expect_observed_contract(
      "OBSERVED_SECOND_WRITE", observed,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE, 2, observer, 0,
      desc, injected, 0
    );
    if (mem.calls.size() != 2)
      `uvm_error("OBSERVED_SECOND_WRITE",
                 "second-write failure did not enter exactly two writes")

    desc = make_desc("observed_dma_failure", binding);
    add_two_dependencies(desc, mapping, desc.function_h);
    desc.barrier_policy = RDMA_DB_BARRIER_DMA;
    clear_observation(mem, pcie, trace);
    expect_status("ARM_OBSERVED_DMA",
                  pcie.fail_next("dma_visibility_barrier", injected),
                  RDMA_SC_OK);
    observer.clear();
    scheduler.submit_observed(binding, desc, observer, observed);
    expect_status("OBSERVED_DMA_FAILURE", observed.status, RDMA_SC_TIMEOUT);
    expect_observed_contract(
      "OBSERVED_DMA_FAILURE", observed,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN, 2, observer, 0,
      desc, injected, 0
    );

    desc = make_desc("observed_mmio_barrier_failure", binding);
    add_two_dependencies(desc, mapping, desc.function_h);
    desc.barrier_policy = RDMA_DB_BARRIER_MMIO;
    clear_observation(mem, pcie, trace);
    expect_status("ARM_OBSERVED_MMIO_BARRIER",
                  pcie.fail_next("mmio_ordering_barrier", injected),
                  RDMA_SC_OK);
    observer.clear();
    scheduler.submit_observed(binding, desc, observer, observed);
    expect_status("OBSERVED_MMIO_BARRIER_FAILURE", observed.status,
                  RDMA_SC_TIMEOUT);
    expect_observed_contract(
      "OBSERVED_MMIO_BARRIER_FAILURE", observed,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED, 2, observer, 0,
      desc, injected, 0
    );

    desc = make_desc("observed_mmio_error", binding);
    desc.barrier_policy = RDMA_DB_BARRIER_NONE;
    clear_observation(mem, pcie, trace);
    expect_status("ARM_OBSERVED_MMIO_ERROR",
                  pcie.fail_next("mmio_write", injected), RDMA_SC_OK);
    observer.clear();
    scheduler.submit_observed(binding, desc, observer, observed);
    expect_status("OBSERVED_MMIO_ERROR", observed.status, RDMA_SC_TIMEOUT);
    expect_observed_contract(
      "OBSERVED_MMIO_ERROR", observed,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE, 0, observer, 1,
      desc, injected, 0
    );

    previous_observed = observed;
    foreach (policies[policy_index]) begin
      desc = make_desc($sformatf("observed_policy_%0d", policy_index),
                       binding);
      desc.barrier_policy = policies[policy_index];
      clear_observation(mem, pcie, trace);
      observer.clear();
      scheduler.submit_observed(binding, desc, observer, observed);
      expect_status($sformatf("OBSERVED_POLICY_%0d", policy_index),
                    observed.status, RDMA_SC_OK);
      expect_observed_contract(
        $sformatf("OBSERVED_POLICY_%0d", policy_index), observed,
        RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 0, observer, 1,
        desc, null, 1
      );
      if (observed == previous_observed)
        `uvm_error("OBSERVED_CALL_LOCAL",
                   "two scheduler calls shared one observed envelope")
      previous_observed = observed;
    end

    desc = make_desc("observed_null_observer", binding);
    desc.barrier_policy = RDMA_DB_BARRIER_NONE;
    scheduler.submit_observed(binding, desc, null, observed);
    expect_status("OBSERVED_NULL_OBSERVER", observed.status, RDMA_SC_OK);
    expect_observed_contract(
      "OBSERVED_NULL_OBSERVER", observed, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
      0, null, 0, desc, null, 1
    );

    blocking_pcie = rdma_doorbell_blocking_pcie::type_id::create(
      "observed_blocking_pcie"
    );
    blocking_pcie.set_call_trace(trace);
    blocking_api = blocking_pcie;
    blocking_scheduler = rdma_doorbell_scheduler::type_id::create(
      "observed_blocking_scheduler"
    );
    expect_status("CONFIGURE_OBSERVED_BLOCKING",
                  blocking_scheduler.configure(mem, blocking_api), RDMA_SC_OK);

    desc = make_desc("observed_mmio_timeout", binding);
    desc.barrier_policy = RDMA_DB_BARRIER_NONE;
    desc.timeout = 5ns;
    blocking_pcie.blocked_function_uid = binding.function_uid;
    blocking_pcie.blocked_method = "mmio_write";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    observer.clear();
    blocking_scheduler.submit_observed(binding, desc, observer, observed);
    blocking_pcie.release_barrier = 1'b1;
    expect_status("OBSERVED_MMIO_TIMEOUT", observed.status, RDMA_SC_TIMEOUT);
    expect_observed_contract(
      "OBSERVED_MMIO_TIMEOUT", observed,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE, 0, observer, 1,
      desc, null, 0
    );

    owner_desc = make_desc("observed_lock_owner", binding);
    owner_desc.barrier_policy = RDMA_DB_BARRIER_DMA;
    owner_desc.timeout = 100ns;
    waiter_desc = make_desc("observed_lock_waiter", binding);
    waiter_desc.barrier_policy = RDMA_DB_BARRIER_NONE;
    waiter_desc.timeout = 5ns;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    owner_done = 1'b0;
    waiter_done = 1'b0;
    watchdog_fired = 1'b0;
    fork : observed_lock_watchdog
      begin : observed_lock_scenario
        fork : observed_lock_owner_worker
          begin
            blocking_scheduler.submit(binding, owner_desc, owner_result,
                                      owner_status);
            owner_done = 1'b1;
          end
        join_none
        wait (blocking_pcie.barrier_entered);
        observer.clear();
        blocking_scheduler.submit_observed(binding, waiter_desc, observer,
                                           observed);
        waiter_done = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        wait (owner_done);
      end
      begin : observed_lock_deadline
        #40ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        #20ns;
      end
    join_any
    disable observed_lock_watchdog;
    if (watchdog_fired || !owner_done || !waiter_done)
      `uvm_error("OBSERVED_LOCK_DEADLINE", "Function-lock scenario hung")
    expect_status("OBSERVED_LOCK_OWNER", owner_status, RDMA_SC_OK);
    expect_status("OBSERVED_LOCK_DEADLINE", observed.status, RDMA_SC_TIMEOUT);
    expect_observed_contract(
      "OBSERVED_LOCK_DEADLINE", observed,
      RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, 0, observer, 0,
      waiter_desc, null, 0
    );
    blocking_pcie.block_enabled = 1'b0;

    deadline_pcie = rdma_doorbell_deadline_edge_pcie::type_id::create(
      "observed_deadline_edge_pcie"
    );
    deadline_pcie.set_call_trace(trace);
    deadline_pcie.dma_delay = 5ns;
    deadline_api = deadline_pcie;
    deadline_scheduler = rdma_doorbell_scheduler::type_id::create(
      "observed_deadline_edge_scheduler"
    );
    expect_status("CONFIGURE_DEADLINE_EDGE",
                  deadline_scheduler.configure(mem, deadline_api), RDMA_SC_OK);
    desc = make_desc("observed_deadline_before_mmio", binding);
    desc.barrier_policy = RDMA_DB_BARRIER_DMA;
    desc.timeout = 5ns;
    observer.clear();
    deadline_scheduler.submit_observed(binding, desc, observer, observed);
    expect_status("OBSERVED_DEADLINE_BEFORE_MMIO", observed.status,
                  RDMA_SC_TIMEOUT);
    expect_observed_contract(
      "OBSERVED_DEADLINE_BEFORE_MMIO", observed,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED, 0, observer, 0,
      desc, null, 0
    );
    if (deadline_pcie.calls.size() != 1 ||
        deadline_pcie.calls[0].method_name != "dma_visibility_barrier")
      `uvm_error("OBSERVED_DEADLINE_BEFORE_MMIO",
                 "expired final deadline entered PCIe MMIO")

    factory = uvm_factory::get();
    envelope_fault = new("doorbell_submission_envelope_fault",
                         rdma_doorbell_submission_result::get_type());
    doorbell_fault = new("doorbell_nested_result_fault",
                         rdma_doorbell_result::get_type());
    status_fault = new("doorbell_nested_status_fault",
                       rdma_status::get_type());
    factory.set_type_override_by_type(
      rdma_doorbell_submission_result::get_type(), envelope_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_doorbell_result::get_type(), doorbell_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_status::get_type(), status_fault, 1'b1
    );

    for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
      envelope_fault.arm(wrong_type);
      status_fault.arm(wrong_type);
      observer.clear();
      scheduler.submit_observed(binding, null, observer, observed);
      if (envelope_fault.call_count() != 0 || status_fault.call_count() != 0)
        `uvm_error("OBSERVED_PRE_FACTORY_FALLBACK",
                   "entry fallback used raw factory")
      expect_status("OBSERVED_PRE_FACTORY_FALLBACK", observed.status,
                    RDMA_SC_INVALID_ARGUMENT);
      expect_observed_contract(
        "OBSERVED_PRE_FACTORY_FALLBACK", observed,
        RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, 0, observer, 0,
        null, null, 0
      );
      envelope_fault.disarm();
      status_fault.disarm();
    end

    envelope_fault.arm(1'b1);
    desc = make_desc("observed_envelope_factory_success", binding);
    desc.barrier_policy = RDMA_DB_BARRIER_NONE;
    observer.clear();
    scheduler.submit_observed(binding, desc, observer, observed);
    if (envelope_fault.call_count() != 0)
      `uvm_error("OBSERVED_ENVELOPE_FACTORY",
                 "scheduler constructed its call-local envelope via factory")
    expect_status("OBSERVED_ENVELOPE_FACTORY", observed.status, RDMA_SC_OK);
    expect_observed_contract(
      "OBSERVED_ENVELOPE_FACTORY", observed,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 0, observer, 1,
      desc, null, 1
    );
    envelope_fault.disarm();

    fault_mem = rdma_doorbell_post_write_factory_mem::type_id::create(
      "observed_factory_fault_mem"
    );
    fault_mem.set_call_trace(trace);
    fault_mem_api = fault_mem;
    fault_mem_scheduler = rdma_doorbell_scheduler::type_id::create(
      "observed_factory_fault_mem_scheduler"
    );
    expect_status("CONFIGURE_FACTORY_FAULT_MEM",
                  fault_mem_scheduler.configure(fault_mem_api, pcie),
                  RDMA_SC_OK);
    expect_status("ALLOCATE_FACTORY_FAULT_MEM",
                  fault_mem.allocate(request_context, 64, 8,
                                     RDMA_DMA_DEVICE_READ, fault_mapping),
                  RDMA_SC_OK);
    if (fault_mapping == null)
      `uvm_fatal("FACTORY_FAULT_MEM_SETUP", "fault mapping is null")

    for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
      desc = make_desc($sformatf("observed_post_write_factory_%0d",
                                 wrong_type), binding);
      dependency = make_dependency(
        $sformatf("observed_post_write_dependency_%0d", wrong_type),
        1, RDMA_DB_DEP_PAYLOAD, fault_mapping, 8, desc.function_h, 8'h41
      );
      desc.dependencies.push_back(dependency);
      fault_mem.arm_after_next_write(status_fault, injected, wrong_type);
      observer.clear();
      fault_mem_scheduler.submit_observed(binding, desc, observer, observed);
      if (status_fault.call_count() != 1)
        `uvm_error("OBSERVED_POST_WRITE_FACTORY",
                   "status construction fault was not exercised exactly once")
      expect_status("OBSERVED_POST_WRITE_FACTORY", observed.status,
                    RDMA_SC_INVALID_STATE);
      expect_observed_contract(
        "OBSERVED_POST_WRITE_FACTORY", observed,
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE, 1, observer, 0,
        desc, injected, 0
      );
      status_fault.disarm();
    end

    fault_pcie = rdma_doorbell_post_mmio_factory_pcie::type_id::create(
      "observed_factory_fault_pcie"
    );
    fault_pcie.set_call_trace(trace);
    fault_pcie_api = fault_pcie;
    fault_pcie_scheduler = rdma_doorbell_scheduler::type_id::create(
      "observed_factory_fault_pcie_scheduler"
    );
    expect_status("CONFIGURE_FACTORY_FAULT_PCIE",
                  fault_pcie_scheduler.configure(mem, fault_pcie_api),
                  RDMA_SC_OK);

    for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
      desc = make_desc($sformatf("observed_post_mmio_status_%0d",
                                 wrong_type), binding);
      desc.barrier_policy = RDMA_DB_BARRIER_NONE;
      fault_pcie.arm_after_next_mmio(status_fault, wrong_type);
      observer.clear();
      fault_pcie_scheduler.submit_observed(binding, desc, observer, observed);
      if (status_fault.call_count() != 1)
        `uvm_error("OBSERVED_POST_MMIO_STATUS_FACTORY",
                   "post-MMIO status fault was not consumed exactly once")
      expect_status("OBSERVED_POST_MMIO_STATUS_FACTORY", observed.status,
                    RDMA_SC_INVALID_STATE);
      expect_observed_contract(
        "OBSERVED_POST_MMIO_STATUS_FACTORY", observed,
        RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 0, observer, 1,
        desc, fault_pcie.success_status, 1
      );
      status_fault.disarm();

      desc = make_desc($sformatf("observed_post_mmio_result_%0d",
                                 wrong_type), binding);
      desc.barrier_policy = RDMA_DB_BARRIER_NONE;
      fault_pcie.arm_after_next_mmio(doorbell_fault, wrong_type);
      observer.clear();
      fault_pcie_scheduler.submit_observed(binding, desc, observer, observed);
      if (doorbell_fault.call_count() != 1)
        `uvm_error("OBSERVED_POST_MMIO_RESULT_FACTORY",
                   "post-MMIO result fault was not consumed exactly once")
      expect_status("OBSERVED_POST_MMIO_RESULT_FACTORY", observed.status,
                    RDMA_SC_INVALID_STATE);
      expect_observed_contract(
        "OBSERVED_POST_MMIO_RESULT_FACTORY", observed,
        RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 0, observer, 1,
        desc, null, 0
      );
      doorbell_fault.disarm();
    end
  endtask

  // 功能：建立共享 mock 环境，依次验证 value copy、状态传输/legacy 准入、observed effect、预检、
  //   正常顺序、adapter 失败恢复、immutable snapshot 和 Function-lock/deadline 并发契约。
  // 输入/输出及副作用：phase 由 UVM 提供；task 持有 objection，分配 mock mapping、
  //   驱动 scheduler/adapter 并以 UVM report 发布所有可观测结果。
  // 失败/边界：mapping 分配失败使用 UVM_FATAL 停止场景；各并发区域有 watchdog，
  //   超时时释放阻塞点并报错；正常收尾时必须 drop objection。
  task run_phase(uvm_phase phase);
    rdma_mock_call_trace trace;
    rdma_mock_host_mem mem;
    rdma_host_mem_api mem_api;
    rdma_mock_pcie pcie;
    rdma_pcie_api pcie_api;
    rdma_doorbell_scheduler scheduler;
    rdma_function_binding binding_a;
    rdma_function_binding binding_b;
    rdma_function_binding snapshot_binding;
    rdma_function_binding rebound_binding_old;
    rdma_function_binding rebound_binding_new;
    longint unsigned saved_notify;
    longint unsigned saved_bar_base;
    longint unsigned saved_bar_size;
    rdma_function_handle function_a;
    rdma_function_handle function_b;
    rdma_dma_request_context request_context;
    rdma_dma_mapping mapping;
    rdma_doorbell_desc desc;
    rdma_doorbell_dependency dependency;
    rdma_doorbell_result result;
    rdma_status status;
    rdma_status injected;
    byte expected_mmio[] = '{8'h00, 8'h00, 8'hc5, 8'h67,
                             8'h00, 8'ha1, 8'h55, 8'h55};
    string full_order[] = '{"host_write", "host_write",
                            "pcie_dma_visibility_barrier",
                            "pcie_mmio_ordering_barrier",
                            "pcie_mmio_write"};
    string host_first_failure[] = '{"host_write"};
    string host_second_failure[] = '{"host_write", "host_write"};
    string dma_failure[] = '{"host_write", "host_write",
                             "pcie_dma_visibility_barrier"};
    string mmio_barrier_failure[] = '{
      "host_write", "host_write", "pcie_dma_visibility_barrier",
      "pcie_mmio_ordering_barrier"
    };
    rdma_doorbell_blocking_pcie blocking_pcie;
    rdma_pcie_api blocking_pcie_api;
    rdma_doorbell_scheduler concurrent_scheduler;
    rdma_doorbell_desc first_desc;
    rdma_doorbell_desc second_desc;
    rdma_doorbell_desc other_desc;
    rdma_doorbell_desc snapshot_desc;
    rdma_doorbell_result first_result;
    rdma_doorbell_result second_result;
    rdma_doorbell_result other_result;
    rdma_doorbell_result snapshot_result;
    rdma_status first_status;
    rdma_status second_status;
    rdma_status other_status;
    rdma_status snapshot_status;
    bit first_done;
    bit second_started;
    bit second_done;
    bit other_done;
    bit snapshot_done;
    bit watchdog_fired;
    time submit_started_at;
    time submit_finished_at;
    string blocking_methods[3] = '{
      "dma_visibility_barrier", "mmio_ordering_barrier", "mmio_write"
    };
    longint unsigned snapshot_address;
    int unsigned expected_generation;
    int unsigned expected_target_id;

    phase.raise_objection(this);

    trace = rdma_mock_call_trace::type_id::create("trace");
    mem = rdma_mock_host_mem::type_id::create("mem");
    pcie = rdma_mock_pcie::type_id::create("pcie");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    mem_api = mem;
    pcie_api = pcie;
    scheduler = rdma_doorbell_scheduler::type_id::create("scheduler");
    expect_status("CONFIGURE_NULL_HOST", scheduler.configure(null, pcie_api),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("CONFIGURE_NULL_PCIE", scheduler.configure(mem_api, null),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("CONFIGURE", scheduler.configure(mem_api, pcie_api),
                  RDMA_SC_OK);

    binding_a = make_binding("binding_a", 64'haaaa, 1, 9);
    binding_b = make_binding("binding_b", 64'hbbbb, 2, 4);
    function_a = binding_a.make_handle();
    function_b = binding_b.make_handle();
    request_context = rdma_dma_request_context::type_id::create(
      "dependency_dma_context"
    );
    request_context.function_h =
      rdma_mock_clone_function_handle(function_a);
    request_context.requester_bdf = binding_a.pcie.bdf;
    request_context.pasid_valid = 1'b0;
    request_context.pasid = '0;
    request_context.dma_domain_valid = binding_a.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding_a.queue_dma.dma_domain_id;
    request_context.owner_h = null;
    status = mem.allocate(request_context, 64, 8,
                          RDMA_DMA_DEVICE_READ, mapping);
    expect_status("ALLOCATE_DEPENDENCY", status, RDMA_SC_OK);
    if (mapping == null) begin
      `uvm_fatal("TEST_SETUP", "dependency mapping allocation failed")
    end
    // 这些 scheduler request/result 是值：clone 必须递归隔离可变 handle/image/dependency，
    //   同时保留具体 mapping 子类的不透明 allocation identity。
    check_value_clone_contracts(binding_a, mapping);
    check_observed_value_projection(binding_a);
    check_status_transfer_matrix(scheduler, binding_a, mem, pcie, trace);
    check_observed_submission_contracts(
      scheduler, binding_a, mapping, mem, pcie, trace, request_context
    );
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("DB_COPY_SETUP", "clone contract mutated source mapping state")

    // 成功路径同时验证 stage 顺序、barrier、最终地址、精确 payload 和仅成功发布 result。
    desc = make_desc("success_desc", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    result = null;
    scheduler.submit(binding_a, desc, result, status);
    expect_status("ORDERED_SUBMIT", status, RDMA_SC_OK);
    expect_trace("ORDERED_SUBMIT", trace, full_order);
    if (mem.calls.size() != 2 || mem.calls[0].offset != 8 ||
        mem.calls[1].offset != 16)
      `uvm_error("ORDERED_SUBMIT", "dependency stage order is incorrect")
    if (pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write" ||
        pcie.calls[2].address.value != binding_a.notify_base.value + 16 ||
        pcie.calls[2].data != expected_mmio)
      `uvm_error("ORDERED_SUBMIT", "MMIO address or payload is incorrect")
    if (result == null || result.absolute_address.value !=
        binding_a.notify_base.value + 16 || result.width != 8 ||
        result.dependency_count != 2)
      `uvm_error("ORDERED_SUBMIT", "success result is incomplete")

    // 完整 preflight 必须在第一个 Host-memory 或 PCIe 副作用前拒绝每个畸形坐标。
    binding_a.state = RDMA_BIND_BOUND;
    desc = make_desc("inactive_binding", binding_a);
    expect_rejected("INACTIVE_BINDING", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_STATE, mem, pcie, trace);
    binding_a.state = RDMA_BIND_ACTIVE;

    binding_a.owner_h.generation = binding_a.generation - 1;
    desc = make_desc("stale_binding", binding_a);
    expect_rejected("STALE_BINDING", scheduler, binding_a, desc,
                    RDMA_SC_STALE_GENERATION, mem, pcie, trace);
    binding_a.owner_h.generation = binding_a.generation;

    desc = make_desc("function_mismatch", binding_a);
    desc.function_h.function_uid = 64'hcccc;
    expect_rejected("FUNCTION_MISMATCH", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("target_uid", binding_a);
    desc.target_h.function_uid = 64'hcccc;
    expect_rejected("TARGET_UID", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("target_generation", binding_a);
    desc.target_h.generation--;
    expect_rejected("TARGET_GENERATION", scheduler, binding_a, desc,
                    RDMA_SC_STALE_GENERATION, mem, pcie, trace);

    desc = make_desc("target_kind", binding_a);
    desc.target_h.kind = RDMA_RESOURCE_CQ;
    expect_rejected("TARGET_KIND", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("wrong_bar", binding_a);
    desc.notify_bar_id = 1;
    expect_rejected("WRONG_BAR", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("out_of_window", binding_a);
    desc.relative_offset = binding_a.notify_size - 4;
    desc.payload_image.bar_target.value = desc.relative_offset;
    expect_rejected("OUT_OF_WINDOW", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("address_overflow", binding_a);
    saved_notify = binding_a.notify_base.value;
    saved_bar_base = binding_a.pcie.bar[0].base.value;
    saved_bar_size = binding_a.pcie.bar[0].size;
    binding_a.notify_base.value = 64'hffff_ffff_ffff_e000;
    binding_a.pcie.bar[0].base.value = 64'hffff_ffff_ffff_e000;
    binding_a.pcie.bar[0].size = 64'h2000;
    expect_rejected("ADDRESS_OVERFLOW", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);
    binding_a.notify_base.value = saved_notify;
    binding_a.pcie.bar[0].base.value = saved_bar_base;
    binding_a.pcie.bar[0].size = saved_bar_size;

    desc = make_desc("width_mismatch", binding_a);
    desc.width = 4;
    expect_rejected("WIDTH_MISMATCH", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("endian_mismatch", binding_a);
    desc.endian = RDMA_ENDIAN_LITTLE;
    expect_rejected("ENDIAN_MISMATCH", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("offset_mismatch", binding_a);
    desc.payload_image.bar_target.value = 64'h18;
    expect_rejected("OFFSET_MISMATCH", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("unready_dependency", binding_a);
    dependency = make_dependency("unready", 1, RDMA_DB_DEP_PAYLOAD,
                                 mapping, 0, function_a, 8'h11);
    dependency.ready = 1'b0;
    desc.dependencies.push_back(dependency);
    expect_rejected("UNREADY_DEPENDENCY", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_STATE, mem, pcie, trace);

    desc = make_desc("duplicate_dependency", binding_a);
    dependency = make_dependency("duplicate_0", 7, RDMA_DB_DEP_PAYLOAD,
                                 mapping, 0, function_a, 8'h22);
    desc.dependencies.push_back(dependency);
    dependency = make_dependency("duplicate_1", 7,
                                 RDMA_DB_DEP_QUEUE_CONTEXT,
                                 mapping, 8, function_a, 8'h33);
    desc.dependencies.push_back(dependency);
    expect_rejected("DUPLICATE_DEPENDENCY", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("cross_function_mapping", binding_a);
    dependency = make_dependency("cross_function", 1,
                                 RDMA_DB_DEP_PAYLOAD, mapping, 0,
                                 function_a, 8'h44);
    mapping.function_h = function_b;
    desc.dependencies.push_back(dependency);
    expect_rejected("CROSS_FUNCTION_MAPPING", scheduler, binding_a, desc,
                    RDMA_SC_DMA_TRANSLATION, mem, pcie, trace);
    mapping.function_h = function_a;

    desc = make_desc("inactive_mapping", binding_a);
    dependency = make_dependency("inactive_mapping_dep", 1,
                                 RDMA_DB_DEP_PAYLOAD, mapping, 0,
                                 function_a, 8'h55);
    mapping.state = RDMA_MAPPING_FROZEN;
    desc.dependencies.push_back(dependency);
    expect_rejected("INACTIVE_MAPPING", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_STATE, mem, pcie, trace);
    mapping.state = RDMA_MAPPING_ACTIVE;

    desc = make_desc("mapping_range", binding_a);
    dependency = make_dependency("mapping_range_dep", 1,
                                 RDMA_DB_DEP_PAYLOAD, mapping, 60,
                                 function_a, 8'h66);
    desc.dependencies.push_back(dependency);
    expect_rejected("MAPPING_RANGE", scheduler, binding_a, desc,
                    RDMA_SC_DMA_TRANSLATION, mem, pcie, trace);

    desc = make_desc("mapping_permission", binding_a);
    dependency = make_dependency("mapping_permission_dep", 1,
                                 RDMA_DB_DEP_PAYLOAD, mapping, 0,
                                 function_a, 8'h77);
    mapping.permissions.device_read = 1'b0;
    mapping.direction = RDMA_DMA_DEVICE_WRITE;
    desc.dependencies.push_back(dependency);
    expect_rejected("MAPPING_PERMISSION", scheduler, binding_a, desc,
                    RDMA_SC_DMA_PERMISSION, mem, pcie, trace);
    mapping.permissions.device_read = 1'b1;
    mapping.permissions.device_write = 1'b0;
    mapping.direction = RDMA_DMA_DEVICE_READ;

    desc = make_desc("illegal_merge", binding_a);
    desc.merge_requested = 1'b1;
    expect_rejected("ILLEGAL_MERGE", scheduler, binding_a, desc,
                    RDMA_SC_INVALID_ARGUMENT, mem, pcie, trace);

    desc = make_desc("readback", binding_a);
    desc.readback_policy = RDMA_DB_READBACK_REQUIRED;
    expect_rejected("UNSUPPORTED_READBACK", scheduler, binding_a, desc,
                    RDMA_SC_UNSUPPORTED_OPCODE, mem, pcie, trace);

    // 每个 adapter 失败都必须立即停止 pipeline 且不发布 result；
    //   第二次 Host-memory 写失败额外证明不泄漏后续写或 barrier。
    injected = rdma_status::make(RDMA_SC_TIMEOUT, "injected doorbell failure");

    desc = make_desc("fail_host_first", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_HOST_FIRST", mem.fail_write_at(1, injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_HOST_FIRST", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_HOST_FIRST", trace, host_first_failure);
    if (result != null) `uvm_error("FAIL_HOST_FIRST", "failure published result")
    expect_recovery_submit("RECOVER_HOST_FIRST", scheduler, binding_a);

    desc = make_desc("fail_host_second", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_HOST_SECOND", mem.fail_write_at(2, injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_HOST_SECOND", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_HOST_SECOND", trace, host_second_failure);
    if (result != null) `uvm_error("FAIL_HOST_SECOND", "failure published result")
    expect_recovery_submit("RECOVER_HOST_SECOND", scheduler, binding_a);

    desc = make_desc("fail_dma_barrier", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_DMA_BARRIER",
                  pcie.fail_next("dma_visibility_barrier", injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_DMA_BARRIER", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_DMA_BARRIER", trace, dma_failure);
    if (result != null) `uvm_error("FAIL_DMA_BARRIER", "failure published result")
    expect_recovery_submit("RECOVER_DMA_FAILURE", scheduler, binding_a);

    desc = make_desc("fail_mmio_barrier", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_MMIO_BARRIER",
                  pcie.fail_next("mmio_ordering_barrier", injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_MMIO_BARRIER", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_MMIO_BARRIER", trace, mmio_barrier_failure);
    if (result != null) `uvm_error("FAIL_MMIO_BARRIER", "failure published result")
    expect_recovery_submit("RECOVER_MMIO_BARRIER_FAILURE", scheduler,
                           binding_a);

    desc = make_desc("fail_mmio_write", binding_a);
    add_two_dependencies(desc, mapping, function_a);
    clear_observation(mem, pcie, trace);
    expect_status("ARM_MMIO_WRITE", pcie.fail_next("mmio_write", injected),
                  RDMA_SC_OK);
    scheduler.submit(binding_a, desc, result, status);
    expect_status("FAIL_MMIO_WRITE", status, RDMA_SC_TIMEOUT);
    expect_trace("FAIL_MMIO_WRITE", trace, full_order);
    if (result != null) `uvm_error("FAIL_MMIO_WRITE", "failure published result")
    expect_recovery_submit("RECOVER_MMIO_WRITE_FAILURE", scheduler, binding_a);

    // 取得 Function lock 后，所有执行输入成为 immutable value；barrier 阻塞期间
    //   修改 caller 对象图不得影响后续 adapter 调用或已发布 result。
    blocking_pcie = rdma_doorbell_blocking_pcie::type_id::create(
        "blocking_pcie");
    blocking_pcie_api = blocking_pcie;
    concurrent_scheduler = rdma_doorbell_scheduler::type_id::create(
        "concurrent_scheduler");
    expect_status("CONFIGURE_CONCURRENT",
                  concurrent_scheduler.configure(mem_api, blocking_pcie_api),
                  RDMA_SC_OK);

    snapshot_binding = make_binding("snapshot_binding", 64'haaaa, 1, 9);
    snapshot_desc = make_desc("snapshot_desc", snapshot_binding);
    add_two_dependencies(snapshot_desc, mapping,
                         snapshot_desc.function_h);
    snapshot_address = snapshot_binding.notify_base.value +
                       snapshot_desc.relative_offset;
    expected_generation = snapshot_desc.function_h.generation;
    expected_target_id = snapshot_desc.target_h.object_id;
    blocking_pcie.blocked_function_uid = function_a.function_uid;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    blocking_pcie.blocked_call_count = 0;
    blocking_pcie.calls.delete();
    clear_observation(mem, blocking_pcie, trace);
    snapshot_done = 1'b0;
    watchdog_fired = 1'b0;
    fork : snapshot_watchdog
      begin : snapshot_scenario
        fork : snapshot_submit_worker
          begin
            concurrent_scheduler.submit(snapshot_binding, snapshot_desc,
                                        snapshot_result, snapshot_status);
            snapshot_done = 1'b1;
          end
        join_none
        wait (blocking_pcie.barrier_entered);
        snapshot_binding.state = RDMA_BIND_BOUND;
        snapshot_binding.generation++;
        snapshot_binding.notify_base.value += 64'h2000;
        snapshot_desc.function_h.generation += 32;
        snapshot_desc.target_h.object_id++;
        snapshot_desc.relative_offset = 64'h18;
        snapshot_desc.payload_image.bytes[0] = 8'hff;
        snapshot_desc.dependencies[0].relative_offset = 40;
        snapshot_desc.dependencies[0].image.bytes[0] = 8'hee;
        snapshot_desc.dependencies[0].mapping.state = RDMA_MAPPING_FROZEN;
        snapshot_desc.dependencies.delete();
        blocking_pcie.release_barrier = 1'b1;
        wait (snapshot_done);
      end
      begin : snapshot_deadline
        #200ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        #20ns;
      end
    join_any
    disable snapshot_watchdog;
    if (watchdog_fired)
      `uvm_error("IMMUTABLE_SNAPSHOT", "snapshot submission hung")
    expect_status("IMMUTABLE_SNAPSHOT", snapshot_status, RDMA_SC_OK);
    if (snapshot_result == null ||
        snapshot_result.function_h == null ||
        snapshot_result.function_h.generation != expected_generation ||
        snapshot_result.target_h == null ||
        snapshot_result.target_h.object_id != expected_target_id ||
        snapshot_result.absolute_address.value != snapshot_address ||
        snapshot_result.dependency_count != 2)
      `uvm_error("IMMUTABLE_SNAPSHOT", "result observed caller mutation")
    if (blocking_pcie.calls.size() != 3 ||
        blocking_pcie.calls[1].function_h == null ||
        blocking_pcie.calls[1].function_h.generation != expected_generation ||
        blocking_pcie.calls[2].function_h == null ||
        blocking_pcie.calls[2].function_h.generation != expected_generation ||
        blocking_pcie.calls[2].address.value != snapshot_address ||
        blocking_pcie.calls[2].data != expected_mmio)
      `uvm_error("IMMUTABLE_SNAPSHOT", "adapter observed caller mutation")

    // 这里的 timeout 是一个总仿真时间 deadline；每个可阻塞 PCIe task 只能消耗剩余预算，
    //   到期后必须局部终止并使 Function lock 可复用。
    foreach (blocking_methods[method_index]) begin
      first_desc = make_desc({"timeout_", blocking_methods[method_index]},
                             binding_a);
      first_desc.timeout = 5ns;
      blocking_pcie.blocked_function_uid = function_a.function_uid;
      blocking_pcie.blocked_method = blocking_methods[method_index];
      blocking_pcie.block_enabled = 1'b1;
      blocking_pcie.barrier_entered = 1'b0;
      blocking_pcie.release_barrier = 1'b0;
      blocking_pcie.blocked_call_count = 0;
      blocking_pcie.calls.delete();
      first_done = 1'b0;
      watchdog_fired = 1'b0;
      submit_started_at = $time;
      fork : pcie_timeout_watchdog
        begin : timed_submit
          concurrent_scheduler.submit(binding_a, first_desc, first_result,
                                      first_status);
          submit_finished_at = $time;
          first_done = 1'b1;
        end
        begin : timed_submit_deadline
          #(first_desc.timeout + 5ns);
          if (!first_done) begin
            watchdog_fired = 1'b1;
            blocking_pcie.release_barrier = 1'b1;
          end
          #20ns;
        end
      join_any
      disable pcie_timeout_watchdog;
      if (watchdog_fired || !first_done)
        `uvm_error("PCIE_TIMEOUT", {blocking_methods[method_index],
                    " did not honor the descriptor deadline"})
      expect_status({"TIMEOUT_", blocking_methods[method_index]},
                    first_status, RDMA_SC_TIMEOUT);
      if (first_result != null)
        `uvm_error("PCIE_TIMEOUT", "timed-out submission published a result")
      if (!blocking_pcie.barrier_entered ||
          blocking_pcie.blocked_call_count != 1)
        `uvm_error("PCIE_TIMEOUT", "selected adapter task did not block")
      if (submit_finished_at - submit_started_at != first_desc.timeout)
        `uvm_error("PCIE_TIMEOUT", "submit did not use one total deadline")
      blocking_pcie.block_enabled = 1'b0;
      blocking_pcie.release_barrier = 1'b1;
      expect_recovery_submit({"RECOVER_", blocking_methods[method_index]},
                             concurrent_scheduler, binding_a);
    end

    // 等待已占用 Function lock 也消耗同一 deadline；超时 waiter 不得归还未取得的 token，
    //   因此第三个 waiter 必须继续阻塞到原 owner 释放 lock。
    first_desc = make_desc("lock_owner", binding_a);
    first_desc.timeout = 100ns;
    second_desc = make_desc("lock_timeout", binding_a);
    second_desc.timeout = 5ns;
    other_desc = make_desc("post_timeout_waiter", binding_a);
    other_desc.timeout = 50ns;
    blocking_pcie.blocked_function_uid = function_a.function_uid;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    blocking_pcie.blocked_call_count = 0;
    blocking_pcie.calls.delete();
    first_done = 1'b0;
    second_started = 1'b0;
    second_done = 1'b0;
    other_done = 1'b0;
    watchdog_fired = 1'b0;
    fork : lock_timeout_watchdog
      begin : lock_timeout_scenario
        fork : lock_timeout_workers
          begin
            concurrent_scheduler.submit(binding_a, first_desc, first_result,
                                        first_status);
            first_done = 1'b1;
          end
          begin
            wait (blocking_pcie.barrier_entered);
            second_started = 1'b1;
            submit_started_at = $time;
            concurrent_scheduler.submit(binding_a, second_desc, second_result,
                                        second_status);
            submit_finished_at = $time;
            second_done = 1'b1;
          end
        join_none
        wait (blocking_pcie.barrier_entered && second_done);
        fork : post_timeout_waiter_worker
          begin
            concurrent_scheduler.submit(binding_a, other_desc, other_result,
                                        other_status);
            other_done = 1'b1;
          end
        join_none
        #1ns;
        if (first_done || other_done || blocking_pcie.calls.size() != 1)
          `uvm_error("LOCK_TIMEOUT_TOKEN",
                     "timed-out lock waiter leaked a semaphore token")
        blocking_pcie.release_barrier = 1'b1;
        wait (first_done && other_done);
      end
      begin : lock_timeout_deadline
        #40ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        #20ns;
      end
    join_any
    disable lock_timeout_watchdog;
    if (watchdog_fired)
      `uvm_error("LOCK_TIMEOUT", "lock wait did not honor its deadline")
    expect_status("LOCK_OWNER", first_status, RDMA_SC_OK);
    expect_status("LOCK_TIMEOUT", second_status, RDMA_SC_TIMEOUT);
    expect_status("POST_TIMEOUT_WAITER", other_status, RDMA_SC_OK);
    if (second_result != null)
      `uvm_error("LOCK_TIMEOUT", "timed-out lock waiter published a result")
    if (submit_finished_at - submit_started_at != second_desc.timeout)
      `uvm_error("LOCK_TIMEOUT", "lock wait used the wrong deadline")
    if (first_result == null || other_result == null)
      `uvm_error("LOCK_TIMEOUT", "lock timeout recovery lost a result")
    blocking_pcie.block_enabled = 1'b0;
    expect_recovery_submit("RECOVER_LOCK_TIMEOUT", concurrent_scheduler,
                           binding_a);

    // 锁 identity 故意排除 generation：同一 immutable Function 的旧/新 incarnation
    //   即使使用两个 binding 对象，也必须串行。
    rebound_binding_old = make_binding("rebound_old", 64'hcccc, 3, 1);
    rebound_binding_new = make_binding("rebound_new", 64'hcccc, 3, 2);
    first_desc = make_desc("old_incarnation", rebound_binding_old);
    second_desc = make_desc("new_incarnation", rebound_binding_new);
    first_desc.timeout = 100ns;
    second_desc.timeout = 100ns;
    blocking_pcie.blocked_function_uid = rebound_binding_old.function_uid;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    blocking_pcie.blocked_call_count = 0;
    blocking_pcie.calls.delete();
    first_done = 1'b0;
    second_started = 1'b0;
    second_done = 1'b0;
    watchdog_fired = 1'b0;
    fork : incarnation_lock_watchdog
      begin : incarnation_lock_scenario
        fork : incarnation_workers
          begin
            concurrent_scheduler.submit(rebound_binding_old, first_desc,
                                        first_result, first_status);
            first_done = 1'b1;
          end
          begin
            wait (blocking_pcie.barrier_entered);
            second_started = 1'b1;
            concurrent_scheduler.submit(rebound_binding_new, second_desc,
                                        second_result, second_status);
            second_done = 1'b1;
          end
        join_none
        wait (blocking_pcie.barrier_entered && second_started);
        #1ns;
        if (first_done || second_done || blocking_pcie.calls.size() != 1)
          `uvm_error("INCARNATION_LOCK",
                     "new Function incarnation overlapped the old one")
        blocking_pcie.release_barrier = 1'b1;
        wait (first_done && second_done);
      end
      begin : incarnation_lock_deadline
        #50ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        #20ns;
      end
    join_any
    disable incarnation_lock_watchdog;
    if (watchdog_fired)
      `uvm_error("INCARNATION_LOCK", "incarnation serialization hung")
    expect_status("OLD_INCARNATION", first_status, RDMA_SC_OK);
    expect_status("NEW_INCARNATION", second_status, RDMA_SC_OK);
    if (first_result == null || second_result == null)
      `uvm_error("INCARNATION_LOCK", "serialized incarnation lost result")

    // 不同 Function 拥有独立 lock，必须能越过已阻塞 Function 继续提交。
    first_desc = make_desc("different_function_a", binding_a);
    other_desc = make_desc("different_function_b", binding_b);
    blocking_pcie.blocked_function_uid = function_a.function_uid;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    blocking_pcie.blocked_call_count = 0;
    blocking_pcie.calls.delete();
    first_done = 1'b0;
    other_done = 1'b0;
    watchdog_fired = 1'b0;
    fork : independent_function_watchdog
      begin : independent_function_scenario
        fork : independent_function_workers
          begin
            concurrent_scheduler.submit(binding_a, first_desc, first_result,
                                        first_status);
            first_done = 1'b1;
          end
          begin
            wait (blocking_pcie.barrier_entered);
            concurrent_scheduler.submit(binding_b, other_desc, other_result,
                                        other_status);
            other_done = 1'b1;
          end
        join_none
        wait (blocking_pcie.barrier_entered && other_done);
        blocking_pcie.release_barrier = 1'b1;
        wait (first_done);
      end
      begin : independent_function_deadline
        #50ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
        #20ns;
      end
    join_any
    disable independent_function_watchdog;
    if (watchdog_fired)
      `uvm_error("DIFFERENT_FUNCTION_LOCK",
                 "independent Function progress hung")
    if (!first_done || first_result == null || other_result == null)
      `uvm_error("DIFFERENT_FUNCTION_LOCK",
                 "independent Function submissions lost a result")
    expect_status("DIFFERENT_FUNCTION_B", other_status, RDMA_SC_OK);
    expect_status("DIFFERENT_FUNCTION_A", first_status, RDMA_SC_OK);

    phase.drop_objection(this);
  endtask
endclass
