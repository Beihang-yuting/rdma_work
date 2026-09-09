// 目录：测试层 unit/rdma_queue_runtime_test.sv。
// 职责：验证 rdma_queue_runtime_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_runtime_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_runtime_test extends uvm_test;
  `uvm_component_utils(rdma_queue_runtime_test)

  // 功能：构造 rdma_queue_runtime_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_runtime_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_runtime_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_queue_runtime_test 中，queue_handle 构造或投影带完整 kind、Function UID、object ID 和 generation 的资源句柄。
  // 输入/输出及副作用：name（输入）、kind（输入）、object_id（输入）；queue_handle 读取 name、kind、object_id 并使用字段 result、result.kind、result.function_uid、result.object_id、result.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：queue_handle 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_handle queue_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle result;
    result = rdma_handle::type_id::create(name);
    result.kind = kind;
    result.function_uid = 64'h1234;
    result.object_id = object_id;
    result.generation = 5;
    return result;
  endfunction

  // 功能：在 rdma_queue_runtime_test 中，expect_ok 在测试中执行 expect_ok 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_ok 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_ok(string label, rdma_status status);
    if (status == null || !status.ok())
      `uvm_error(label, status == null ? "null status" :
                 status.convert2string())
  endfunction

  // 功能：在 rdma_queue_runtime_test 中，expect_code 在测试中执行 expect_code 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、code（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_code 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_code(
    string label,
    rdma_status status,
    rdma_status_code_e code
  );
    if (status == null || status.code != code)
      `uvm_error(label, status == null ? "null status" :
                 status.convert2string())
  endfunction

  // 功能：验证 device-produced CQ runtime 的 reservation、commit 与 consumer 可见性边界，并确认 host/device producer API 方向隔离。
  // 输入/输出及副作用：在本地构造 CQ 与 SQ runtime，调用 configure/activate/reserve/commit/query 接口并产生 UVM 断言；不接管外部句柄所有权。
  // 失败/边界：若配置、激活或 reservation 前置步骤失败则提前返回；未提交 reservation 必须保持 occupancy 为零且 peek 返回 RDMA_SC_QUEUE_EMPTY，方向错误必须返回 RDMA_SC_INVALID_STATE。
  task automatic test_device_ring_reserve_commit_and_visibility();
    rdma_queue_runtime runtime;
    rdma_queue_runtime host_runtime;
    rdma_queue_cursor_snapshot reservation, consumer;
    rdma_status status;
    int unsigned occupancy;

    runtime = rdma_queue_runtime::type_id::create("device_runtime");
    status = runtime.configure(queue_handle("cq", RDMA_RESOURCE_CQ, 7),
                               RDMA_QUEUE_RUNTIME_CQ, 2, 0, 1'b0,
                               0, 1'b0, 1'b0);
    expect_ok("DEVICE_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    expect_ok("DEVICE_ACTIVATE", runtime.activate());
    status = runtime.reserve_device_producer(reservation);
    expect_ok("DEVICE_RESERVE", status);
    if (status == null || !status.ok() || reservation == null) return;
    status = runtime.query_occupancy(occupancy);
    if (status == null || occupancy != 0)
      `uvm_error("DEVICE_OCCUPANCY", "reservation changed committed occupancy")
    status = runtime.peek_consumer(consumer);
    if (status == null || status.code != RDMA_SC_QUEUE_EMPTY || consumer != null)
      `uvm_error("DEVICE_VISIBILITY", "uncommitted slot became visible")
    expect_ok("DEVICE_COMMIT", runtime.commit_device_producer(reservation));
    status = runtime.query_occupancy(occupancy);
    if (status == null || occupancy != 1)
      `uvm_error("DEVICE_OCCUPANCY", "committed occupancy is incorrect")

    host_runtime = rdma_queue_runtime::type_id::create("host_runtime");
    expect_ok("HOST_CONFIGURE", host_runtime.configure(
      queue_handle("sq", RDMA_RESOURCE_QP, 9), RDMA_QUEUE_RUNTIME_SQ,
      2, 0, 1'b0, 0, 1'b0, 1'b1));
    expect_ok("HOST_ACTIVATE", host_runtime.activate());
    expect_code("HOST_DEVICE_RESERVE",
                host_runtime.reserve_device_producer(reservation),
                RDMA_SC_INVALID_STATE);
    expect_code("DEVICE_HOST_RESERVE",
                runtime.reserve_producer(reservation),
                RDMA_SC_INVALID_STATE);
  endtask

  // 功能：验证 device ring 的 consumer credit、重复 reservation、recovery pending 与 abort 隔离。
  // 输入/输出及副作用：构造 AEQ runtime 与 detached pending，调用 producer/consumer/recovery 接口并产生 UVM 断言；fixture 句柄仍由测试持有。
  // 失败/边界：任一前置配置失败即返回；空 ring 的 consumer commit、重复 reservation、stale producer commit 和 pending quiesce 必须拒绝且不改变账本。
  task automatic test_device_consumer_credit_and_recovery();
    rdma_queue_runtime runtime;
    rdma_queue_cursor_snapshot producer, duplicate, consumer, stale, remaining;
    rdma_queue_pending_operation pending;
    rdma_status status;
    int unsigned occupancy;
    bit reservation_valid;
    rdma_queue_runtime_state_e runtime_state;

    runtime = rdma_queue_runtime::type_id::create("device_credit_runtime");
    expect_ok("CREDIT_CONFIGURE", runtime.configure(
      queue_handle("aeq", RDMA_RESOURCE_AEQ, 8), RDMA_QUEUE_RUNTIME_AEQ,
      4, 0, 1'b0, 0, 1'b0, 1'b0));
    expect_ok("CREDIT_ACTIVATE", runtime.activate());
    expect_ok("CREDIT_RESERVE", runtime.reserve_device_producer(producer));
    expect_code("CREDIT_DUPLICATE_RESERVE",
                runtime.reserve_device_producer(duplicate), RDMA_SC_RESOURCE_BUSY);
    if (duplicate != null) `uvm_error("CREDIT_DUPLICATE_RESERVE", "output was published")
    expect_ok("CREDIT_COMMIT", runtime.commit_device_producer(producer));
    expect_ok("CREDIT_PEEK", runtime.peek_consumer(consumer));
    expect_ok("CREDIT_CONSUMER_COMMIT", runtime.commit_consumer(consumer));
    expect_ok("CREDIT_QUERY", runtime.query_occupancy(occupancy));
    if (occupancy != 0) `uvm_error("CREDIT_QUERY", "consumer did not release credit")
    expect_code("CREDIT_EMPTY_COMMIT", runtime.commit_consumer(consumer),
                RDMA_SC_QUEUE_EMPTY);

    expect_ok("RECOVERY_RESERVE", runtime.reserve_device_producer(producer));
    pending = rdma_queue_pending_operation::type_id::create("device_pending_test");
    pending.queue_h = queue_handle("aeq", RDMA_RESOURCE_AEQ, 8);
    pending.kind = RDMA_QUEUE_RUNTIME_AEQ;
    pending.device_producer = 1'b1;
    pending.device_write_attempted = 1'b1;
    pending.mmio_evidence = RDMA_QUEUE_MMIO_NOT_APPLICABLE;
    expect_ok("RECOVERY_ENTER", runtime.enter_recovery_prepared(pending));
    expect_code("QUIESCE_PENDING", runtime.begin_quiesce(), RDMA_SC_RESOURCE_BUSY);
    stale = rdma_queue_cursor_snapshot::type_id::create("stale_device_cursor");
    stale.index = producer.index;
    stale.wrap = ~producer.wrap;
    expect_code("STALE_DEVICE_COMMIT", runtime.commit_device_producer(stale),
                RDMA_SC_INVALID_STATE);
    expect_ok("RECOVERY_ABORT", runtime.abort_recovery());
    expect_ok("ABORT_QUERY_RESERVATION",
              runtime.query_device_reservation(reservation_valid, remaining));
    expect_ok("ABORT_QUERY_STATE", runtime.query_state(runtime_state));
    if (reservation_valid || remaining != null ||
        runtime_state != RDMA_QUEUE_RUNTIME_DETACHED)
      `uvm_error("RECOVERY_ABORT", "abort retained device recovery state")
  endtask

  // 功能：在 rdma_queue_runtime_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_queue_runtime runtime;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_slot_ledger_entry released[$];
    rdma_queue_pending_operation pending;
    rdma_handle queue_h;
    rdma_handle stale_h;
    rdma_post_send_req request;
    rdma_hw_image image;
    rdma_status status;

    phase.raise_objection(this);
    test_device_ring_reserve_commit_and_visibility();
    test_device_consumer_credit_and_recovery();
    runtime = rdma_queue_runtime::type_id::create("runtime");
    queue_h = queue_handle("qp", RDMA_RESOURCE_QP, 9);

    status = runtime.configure(queue_h, RDMA_QUEUE_RUNTIME_SQ, 3,
                               0, 1'b0, 0, 1'b0, 1'b1);
    expect_code("POWER_OF_TWO", status, RDMA_SC_INVALID_ARGUMENT);
    status = runtime.configure(queue_h, RDMA_QUEUE_RUNTIME_SQ, 4,
                               3, 1'b0, 3, 1'b0, 1'b1);
    expect_ok("CONFIGURE", status);
    expect_ok("ACTIVATE", runtime.activate());

    request = rdma_post_send_req::type_id::create("request");
    image = rdma_hw_image::type_id::create("image");
    image.length = 64;
    status = runtime.reserve_producer(reservation);
    expect_ok("RESERVE_WRAP", status);
    if (reservation == null || reservation.index != 3 || reservation.wrap)
      `uvm_error("RESERVE_WRAP", "wrong producer reservation")
    status = runtime.commit_producer(reservation, request, 64'h11, 1'b0,
                                     image);
    expect_ok("COMMIT_WRAP", status);
    if (runtime.producer_index != 0 || runtime.producer_wrap != 1'b1 ||
        runtime.used != 1 || runtime.available_slots() != 3)
      `uvm_error("COMMIT_WRAP", "producer wrap/credit update is wrong")

    // Fill remaining credits and prove the full check is side-effect free.
    repeat (3) begin
      expect_ok("RESERVE_FILL", runtime.reserve_producer(reservation));
      expect_ok("COMMIT_FILL", runtime.commit_producer(
        reservation, request, 64'h20 + runtime.used, runtime.used == 3,
        image));
    end
    reservation = rdma_queue_cursor_snapshot::type_id::create("sentinel");
    reservation.index = 99;
    status = runtime.reserve_producer(reservation);
    expect_code("QUEUE_FULL", status, RDMA_SC_QUEUE_FULL);
    if (reservation != null)
      `uvm_error("QUEUE_FULL", "failed reserve published an output")

    // Completion of the last slot releases all preceding contiguous,
    // unsignaled slots and advances CI through the same wrap rule.
    status = runtime.match_and_release(2, 1'b1, released);
    expect_ok("RELEASE_CONTIGUOUS", status);
    if (released.size() != 4 || runtime.used != 0 ||
        runtime.consumer_index != 3 || runtime.consumer_wrap != 1'b1)
      `uvm_error("RELEASE_CONTIGUOUS", "contiguous release is wrong")
    released.delete();
    status = runtime.match_and_release(2, 1'b1, released);
    expect_code("DUPLICATE_COMPLETION", status, RDMA_SC_INVALID_STATE);
    if (released.size() != 0)
      `uvm_error("DUPLICATE_COMPLETION", "failed match published slots")

    stale_h = rdma_clone_handle_value(queue_h, "stale runtime handle");
    stale_h.generation++;
    expect_code("GENERATION", runtime.validate_queue_handle(stale_h),
                RDMA_SC_STALE_GENERATION);

    pending = rdma_queue_pending_operation::type_id::create("pending");
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create("cursor");
    pending.cursor.index = runtime.producer_index;
    expect_ok("ENTER_RECOVERY", runtime.enter_recovery(pending, 1'b1));
    expect_code("AMBIGUOUS_RETRY",
                runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1),
                RDMA_SC_RECOVERY_REQUIRED);
    expect_ok("ABORT_RECOVERY",
              runtime.recover(RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b0));
    if (runtime.state != RDMA_QUEUE_RUNTIME_DETACHED)
      `uvm_error("ABORT_RECOVERY", "runtime did not detach")

    // Known-no-MMIO retry additionally requires explicit caller confirmation.
    runtime = rdma_queue_runtime::type_id::create("retry_runtime");
    expect_ok("RETRY_CONFIG", runtime.configure(
      queue_h, RDMA_QUEUE_RUNTIME_CQ, 8, 0, 1'b0, 0, 1'b0, 1'b0));
    expect_ok("RETRY_ACTIVE", runtime.activate());
    expect_ok("RETRY_ENTER", runtime.enter_recovery(pending, 1'b0));
    expect_code("RETRY_CONFIRM",
                runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("RETRY_ALLOWED",
              runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1));
    if (runtime.state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        runtime.pending_operation == null)
      `uvm_error("RETRY_ALLOWED", "retry did not retain pending authority")
    phase.drop_objection(this);
  endtask
endclass
