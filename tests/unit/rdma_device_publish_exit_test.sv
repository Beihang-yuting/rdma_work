// 目录/层次：tests/unit；职责：验证 CQ/CEQ/AEQ 共用设备发布出口及状态复制回调窗口。
// 依赖：完整 queue-data lifecycle fixture、真实 runtime/access 和 mock Host-memory。
// 所有权与生命周期：每个 case 拥有独立 fixture/factory；probe 只借用 attachment，
//   注入后先恢复 factory/锁，再通过真实 recovery 与聚合 cleanup 归还全部资源。
// 本测试直接进入已 reserve 的公共设备事务，不替代公开 CQE/CEQE/AEQE 编码与路由回归。

// 设计说明：观察字段复制完成后的真实 status factory 窗口；首次可替换 destination，
// 第二次必须重新读取 pending.failure_status 并恢复原诊断，不能提前缓存字段引用。
class rdma_device_publish_exit_factory extends uvm_default_factory;
  rdma_queue_pending_operation pending;
  rdma_status first_destination;
  string copied_values[$];
  bit watching;
  bit replace_destination;

  // 功能：构造尚未 armed 的隔离 factory，清空借用 pending 和观测记录。
  // 输入/输出及副作用：无输入；不安装全局 factory，也不分配或拥有队列资源。
  // 失败/边界：case 必须在调用事务前启用 watching，并在 admission 前停止观测。
  function new();
    super.new();
    watching = 1'b0;
    replace_destination = 1'b0;
  endfunction

  // 功能：捕获本次 pending，并记录每次 failure 字段写完后触发的 status 创建。
  // 输入/输出及副作用：requested_type/parent_inst_path/name 原样委托基类；首次复制后
  //   可把 pending.failure_status 替换成独立 sentinel，所有 factory 返回对象仍是真实类型。
  // 失败/边界：仅 watching 且失败已复制时观测；不返回 null，避免 rdma_status::make
  //   自身的空解引用；admission 会关停 watching，防止把最终返回状态误计为复制窗口。
  virtual function uvm_object create_object_by_type(
    uvm_object_wrapper requested_type, string parent_inst_path = "", string name = ""
  );
    uvm_object created;

    if (watching && requested_type == rdma_status::get_type() &&
        name == "rdma_status" && pending != null && pending.failure_status != null &&
        pending.failure_status.code != RDMA_SC_RECOVERY_REQUIRED) begin
      copied_values.push_back(pending.failure_status.convert2string());
      if (copied_values.size() == 1 && replace_destination) begin
        first_destination = pending.failure_status;
        pending.failure_status = rdma_status::make_direct(
          RDMA_SC_RECOVERY_REQUIRED, "factory replaced destination");
      end
    end
    created = super.create_object_by_type(requested_type, parent_inst_path, name);
    if (watching && name == "device_publish_pending" && !$cast(pending, created))
      `uvm_fatal("PUBLISH_EXIT", "pending factory capture failed")
    return created;
  endfunction
endclass

// 设计说明：用真实 semaphore 忙制造 producer commit 拒绝，不伪造 commit 返回或游标。
class rdma_device_publish_exit_runtime extends rdma_queue_runtime;
  `uvm_object_utils(rdma_device_publish_exit_runtime)
  bit held;

  // 功能：构造默认 runtime，关闭测试占锁标志。
  // 输入/输出及副作用：name 传给基类；held=0，不创建第二把锁或账本。
  // 失败/边界：只能在 configure/activate 后使用测试锁窗口，所有权仍归 fixture。
  function new(string name = "rdma_device_publish_exit_runtime");
    super.new(name);
    held = 1'b0;
  endfunction

  // 功能：按 hold 取得或归还唯一 runtime lock，驱动 commit 的真实 RESOURCE_BUSY 分支。
  // 输入/输出及副作用：hold=1 临时取 token，hold=0 仅归还已持有 token；不修改 PI/CI。
  // 失败/边界：重复持有、锁缺失或被占用 fatal；释放未持有锁为空操作，禁止重复 put。
  function void set_test_hold(bit hold);
    if (hold) begin
      if (held || lock == null || !lock.try_get(1))
        `uvm_fatal("PUBLISH_EXIT", "runtime lock injection unavailable")
      held = 1'b1;
    end
    else if (held) begin
      held = 1'b0;
      lock.put(1);
    end
  endfunction
endclass

// 设计说明：真实 write 后注入 commit 忙，或在 access 边界返回未开始/null 状态；
// 其余写入均委托原实现，Host-memory write/read 故障仍由 mock 的真实调用记录核对。
class rdma_device_publish_exit_access extends rdma_queue_backing_access;
  `uvm_object_utils(rdma_device_publish_exit_access)
  static int unsigned mode;
  static rdma_device_publish_exit_runtime target_runtime;

  // 功能：构造未配置 access，保留基类 backing authority 校验。
  // 输入/输出及副作用：name 透传；不修改共享 mode/target_runtime 或 mapping 所有权。
  // 失败/边界：case 在 setup 后才设置注入模式；未匹配模式完全使用生产实现。
  function new(string name = "rdma_device_publish_exit_access");
    super.new(name);
  endfunction

  // 功能：在指定设备 write 窗口注入 preflight、假成功、null 或真实 commit 锁竞争。
  // 输入/输出及副作用：offset/data 透传；backend_write_started 表示真实调用阶段；
  //   mode=4 在真实 write 成功后占锁，5/6/8 不调用 backend，7 在真实写后返回 null。
  // 失败/边界：mode=5 返回 DMA_PERMISSION，6 返回 OK 但未写，7/8 返回 null；
  //   其它错误原样传播，测试必须在 admission 前归还 mode=4 的 token。
  virtual function rdma_status write_device(
    longint unsigned offset, byte data[], output bit backend_write_started
  );
    rdma_status status;

    backend_write_started = 1'b0;
    if (mode == 5)
      return rdma_status::make_direct(RDMA_SC_DMA_PERMISSION, "injected preflight");
    if (mode == 6)
      return rdma_status::make_direct(RDMA_SC_OK);
    if (mode == 8)
      return null;
    status = super.write_device(offset, data, backend_write_started);
    if (status != null && status.ok() && mode == 4)
      target_runtime.set_test_hold(1'b1);
    if (mode == 7)
      return null;
    return status;
  endfunction
endclass

// 设计说明：同时破坏首尾两个字节，验证 foreach 的首错退出不会重复建立错误或继续 commit。
class rdma_device_publish_exit_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_device_publish_exit_mem)
  bit corrupt_read;

  // 功能：构造正常 mock memory，默认不破坏回读数据。
  // 输入/输出及副作用：name 透传；corrupt_read=0，保留基类 allocation/call 账本。
  // 失败/边界：只供隔离测试 fixture 拥有，不替代外部 Host-memory 适配器。
  function new(string name = "rdma_device_publish_exit_mem");
    super.new(name);
    corrupt_read = 1'b0;
  endfunction

  // 功能：在一次成功回读后翻转首尾字节，建立多个 mismatch 的确定故障。
  // 输入/输出及副作用：mapping/offset/size 透传，data 是真实读结果再局部修改；
  //   消耗 corrupt_read，不修改 backing，调用记录仍由基类生成。
  // 失败/边界：基类错误原样返回；空 data 不索引，不把读失败伪造成 mismatch。
  virtual function rdma_status read(
    rdma_dma_mapping mapping, longint unsigned offset, int unsigned size,
    output byte data[]
  );
    rdma_status status;

    status = super.read(mapping, offset, size, data);
    if (corrupt_read && status != null && status.ok() && data.size() != 0) begin
      corrupt_read = 1'b0;
      data[0] ^= 8'h1;
      data[data.size() - 1] ^= 8'h2;
    end
    return status;
  endfunction
endclass

// 设计说明：测试借用真实 attachment 进入公共设备事务；不新增生产公开 API。
class rdma_device_publish_exit_probe extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_device_publish_exit_probe)
  rdma_device_publish_exit_factory observer;
  int unsigned expected_copies;
  bit reject_admission;

  // 功能：构造未配置 engine，默认不拒绝 runtime 接管。
  // 输入/输出及副作用：name 透传基类；observer 由 case 借用，不取得 factory 所有权。
  // 失败/边界：fixture.setup 完成前不能调用 publish_image，测试不绕过 attachment 检查。
  function new(string name = "rdma_device_publish_exit_probe");
    super.new(name);
    reject_admission = 1'b0;
  endfunction

  // 功能：为指定已附着队列 reserve 一个槽位，构造精确 stride 的原始 image 后执行真实事务。
  // 输入/输出及副作用：queue_h/kind 输入，result/status 输出；借用 runtime/access，
  //   image 仅用于机制测试；会写真实 mock backing 并可能提交 PI 或保留 recovery。
  // 失败/边界：lookup/reserve/type 不完整 fatal；本入口不测试业务 codec/route admission，
  //   recovery 仍必须通过公开 recover_queue 完成，不能手动清除 pending 或 reservation。
  task publish_image(
    rdma_handle queue_h, rdma_queue_runtime_kind_e kind,
    output rdma_queue_device_publish_result result, output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_cursor_snapshot reservation;
    rdma_hw_image image;

    status = lookup_attachment(queue_h, kind, attachment);
    if (status == null || !status.ok() || attachment == null ||
        !$cast(rdma_device_publish_exit_access::target_runtime, attachment.runtime))
      `uvm_fatal("PUBLISH_EXIT", "attachment/runtime unavailable")
    status = attachment.runtime.reserve_device_producer(reservation);
    if (status == null || !status.ok() || reservation == null)
      `uvm_fatal("PUBLISH_EXIT", "reserve failed")
    image = new("exit_image");
    image.length = attachment.entry_size;
    image.alignment = attachment.entry_size;
    image.endian = RDMA_ENDIAN_BIG;
    case (kind)
      RDMA_QUEUE_RUNTIME_CQ: image.image_kind = RDMA_IMAGE_CQE;
      RDMA_QUEUE_RUNTIME_CEQ: image.image_kind = RDMA_IMAGE_CEQE;
      RDMA_QUEUE_RUNTIME_AEQ: image.image_kind = RDMA_IMAGE_AEQE;
      default: `uvm_fatal("PUBLISH_EXIT", "unsupported test queue")
    endcase
    for (int unsigned i = 0; i < attachment.entry_size; i++)
      image.bytes.push_back(8'h5a);
    write_commit_device_entry(attachment, reservation, image, result, status);
  endtask

  // 功能：在实际 runtime admission 前检查复制次数，归还 commit 故障锁并可拒绝一次接管。
  // 输入/输出及副作用：attachment/prepared_pending 透传；关闭 observer，确保最终 status
  //   factory 不会掩盖缺失的复制窗口；正常模式调用真实 runtime admission。
  // 失败/边界：复制次数不符 error；reject_admission 只消耗一次并返回 RESOURCE_BUSY，
  //   evidence 必须由基类保留为 unclaimed，后续公开 retry 应接管并完成提交。
  protected virtual function rdma_status admit_device_publish_recovery(
    rdma_queue_data_attachment attachment, rdma_queue_pending_operation prepared_pending
  );
    if (observer.watching && observer.copied_values.size() != expected_copies)
      `uvm_error("PUBLISH_EXIT", "status copy callback count changed before admission")
    observer.watching = 1'b0;
    rdma_device_publish_exit_access::target_runtime.set_test_hold(1'b0);
    if (reject_admission) begin
      reject_admission = 1'b0;
      return rdma_status::make_direct(RDMA_SC_RESOURCE_BUSY, "injected admission");
    end
    return super.admit_device_publish_recovery(attachment, prepared_pending);
  endfunction
endclass

// 独立注册三种队列 × 十种状态，避免只验证抽出的尾段而不经过实际 write/read/commit caller。
class rdma_device_publish_exit_test extends uvm_test;
  `uvm_component_utils(rdma_device_publish_exit_test)

  // 功能：构造发布出口矩阵组件，不提前占用 fixture 或全局 factory。
  // 输入/输出及副作用：name/parent 传给 UVM；对象只负责 case 调度和断言汇总。
  // 失败/边界：资源延迟到 run_case 创建，构造成功不代表仿真已完成。
  function new(string name = "rdma_device_publish_exit_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：对一个 CQ/CEQ/AEQ 事务验证 I/O 次数、失败 evidence、reservation、两次复制和 retry。
  // 输入/输出及副作用：kind 选择队列，mode=0..9 选择成功/四类写后失败/写前拒绝/异常成功/
  //   两类 null/admission 拒绝；每个 case 独立 setup，恢复后再次发布并 cleanup 至零 allocation。
  // 失败/边界：fixture/type/关键快照缺失 fatal；其余不符 error；只在四类写后复制路径替换
  //   destination，异常成功保留原单次复制；不将合成 image 当作公开业务编解码验收。
  task run_case(rdma_queue_runtime_kind_e kind, int unsigned mode);
    uvm_coreservice_t service;
    uvm_factory saved_factory;
    rdma_device_publish_exit_factory factory;
    rdma_queue_data_engine_fixture fixture;
    rdma_device_publish_exit_probe probe;
    rdma_device_publish_exit_mem mem;
    rdma_handle queue_h;
    rdma_status status;
    rdma_status injected;
    rdma_queue_device_publish_result result;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot cursor;
    int unsigned calls_before;
    int unsigned expected_calls;
    int unsigned occupancy;
    bit has_pending;
    bit reserved;
    bit recovery;

    service = uvm_coreservice_t::get();
    saved_factory = service.get_factory();
    factory = new();
    factory.set_type_override_by_type(
      rdma_queue_data_engine::get_type(), rdma_device_publish_exit_probe::get_type());
    factory.set_type_override_by_type(
      rdma_queue_runtime::get_type(), rdma_device_publish_exit_runtime::get_type());
    factory.set_type_override_by_type(
      rdma_queue_backing_access::get_type(), rdma_device_publish_exit_access::get_type());
    factory.set_type_override_by_type(
      rdma_mock_host_mem::get_type(), rdma_device_publish_exit_mem::get_type());
    service.set_factory(factory);
    rdma_device_publish_exit_access::mode = 0;
    fixture = new("publish_exit_fixture");
    fixture.setup(status);
    if (status == null || !status.ok() || !$cast(probe, fixture.engine) ||
        !$cast(mem, fixture.mem))
      `uvm_fatal("PUBLISH_EXIT", "fixture setup/cast failed")
    case (kind)
      RDMA_QUEUE_RUNTIME_CQ: queue_h = fixture.cq.handle;
      RDMA_QUEUE_RUNTIME_CEQ: queue_h = fixture.ceq.handle;
      RDMA_QUEUE_RUNTIME_AEQ: queue_h = fixture.aeq.handle;
      default: `uvm_fatal("PUBLISH_EXIT", "invalid matrix kind")
    endcase
    injected = rdma_status::make_direct(RDMA_SC_DMA_TRANSLATION, "injected I/O failure");
    injected.hardware_code = 32'h1234;
    injected.hardware_code_valid = 1'b1;
    injected.function_uid = queue_h.function_uid;
    injected.generation = queue_h.generation;
    injected.resource_id = queue_h.object_id;
    injected.command_id = 64'h3456;
    injected.wr_id = 64'h5678;
    injected.retryable = 1'b1;
    if (mode inside {1, 2, 9}) begin
      status = mem.fail_next(mode == 2 ? "read" : "write", injected);
      if (status == null || !status.ok())
        `uvm_fatal("PUBLISH_EXIT", "I/O fault setup failed")
    end
    mem.corrupt_read = mode == 3;
    rdma_device_publish_exit_access::mode = mode;
    recovery = !(mode inside {0, 5, 8});
    probe.observer = factory;
    probe.expected_copies = recovery ? (mode == 6 ? 1 : 2) : 0;
    probe.reject_admission = mode == 9;
    factory.replace_destination = probe.expected_copies == 2;
    factory.watching = 1'b1;
    calls_before = mem.calls.size();
    probe.publish_image(queue_h, kind, result, status);
    factory.watching = 1'b0;
    service.set_factory(saved_factory);
    rdma_device_publish_exit_access::mode = 0;
    rdma_device_publish_exit_access::target_runtime.set_test_hold(1'b0);

    if (status == null || (recovery && status.code != RDMA_SC_RECOVERY_REQUIRED) ||
        (mode == 0 && !status.ok()) || (mode == 5 && status.code != RDMA_SC_DMA_PERMISSION) ||
        (mode == 8 && status.code != RDMA_SC_INVALID_ARGUMENT) ||
        ((result != null) != (mode == 0)))
      `uvm_error("PUBLISH_EXIT", $sformatf("wrong result/status kind=%0d mode=%0d", kind, mode))
    expected_calls = mode inside {5, 6, 8} ? 0 : (mode inside {1, 7, 9} ? 1 : 2);
    if (mem.calls.size() != calls_before + expected_calls ||
        (expected_calls > 0 && mem.calls[calls_before].method_name != "write") ||
        (expected_calls > 1 && mem.calls[calls_before + 1].method_name != "read") ||
        factory.copied_values.size() != probe.expected_copies)
      `uvm_error("PUBLISH_EXIT", "I/O or status-copy count/order changed")
    if (factory.replace_destination &&
        (factory.copied_values[0] != factory.copied_values[1] ||
         factory.pending.failure_status == factory.first_destination))
      `uvm_error("PUBLISH_EXIT", "second copy cached destination or lost original fields")
    status = probe.query_runtime_occupancy(queue_h, kind, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != (mode == 0 ? 1 : 0) ||
        has_pending != (recovery && mode != 9))
      `uvm_error("PUBLISH_EXIT", "failed publish changed credit or lost pending")
    status = probe.query_runtime_device_reservation(queue_h, kind, reserved, cursor);
    if (status == null || !status.ok() || reserved != recovery ||
        (reserved && (cursor == null || cursor.index != 0 || cursor.wrap)))
      `uvm_error("PUBLISH_EXIT", "reservation was lost or prematurely committed")
    if (recovery) begin
      status = probe.query_runtime_pending(queue_h, kind, pending);
      if (status == null || !status.ok() || pending == null || pending.failure_status == null)
        `uvm_fatal("PUBLISH_EXIT", "failure evidence unavailable")
      if (!pending.device_producer || !pending.device_write_attempted ||
          pending.mmio_evidence != RDMA_QUEUE_MMIO_NOT_APPLICABLE ||
          pending.cursor.index != 0 || pending.next_cursor.index != 1 ||
          !pending.route_valid || !pending.epoch_valid ||
          (mode inside {1, 2, 9} &&
           pending.failure_status.convert2string() != injected.convert2string()) ||
          (mode == 3 && pending.failure_status.message != "device publish readback bytes differ") ||
          (mode == 4 && pending.failure_status.code != RDMA_SC_RESOURCE_BUSY) ||
          (mode inside {6, 7} && pending.failure_status.code != RDMA_SC_INVALID_ARGUMENT))
        `uvm_error("PUBLISH_EXIT", "pending diagnostics/authority/phase changed")
      probe.recover_queue(queue_h, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
      if (status == null || !status.ok())
        `uvm_error("PUBLISH_EXIT", "retry failed")
    end
    status = probe.query_runtime_occupancy(queue_h, kind, occupancy, has_pending);
    if (status == null || !status.ok() || has_pending ||
        occupancy != (mode inside {5, 8} ? 0 : 1))
      `uvm_error("PUBLISH_EXIT", "retry did not commit exactly one slot")
    probe.publish_image(queue_h, kind, result, status);
    if (status == null || !status.ok() || result == null ||
        result.index != (mode inside {5, 8} ? 0 : 1))
      `uvm_error("PUBLISH_EXIT", "later activation retained failure diagnostic or reservation")
    fixture.cleanup(status);
    if (status == null || !status.ok() || mem.live_allocations() != 0)
      `uvm_error("PUBLISH_EXIT", "cleanup leaked lifecycle resources")
    rdma_device_publish_exit_access::target_runtime = null;
  endtask

  // 功能：遍历三个设备生产队列与十种退出状态，覆盖共同尾段及所有旁路，共 30 cases。
  // 输入/输出及副作用：phase 管理 objection；顺序运行隔离 fixture，输出完整矩阵完成标记。
  // 失败/边界：非致命断言继续后续 case，UVM_ERROR 由 runner 拒绝；不把完成标记等同零错误。
  task run_phase(uvm_phase phase);
    rdma_queue_runtime_kind_e kinds[3] = '{
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_RUNTIME_CEQ, RDMA_QUEUE_RUNTIME_AEQ};

    phase.raise_objection(this);
    foreach (kinds[i])
      for (int unsigned mode = 0; mode < 10; mode++)
        run_case(kinds[i], mode);
    `uvm_info("PUBLISH_EXIT", "completed 30 device publish exit cases", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
