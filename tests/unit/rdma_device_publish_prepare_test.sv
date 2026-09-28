// 目录/层次：tests/unit；职责：验证 CQ/CEQ/AEQ 准备失败的取消权限与恢复证据完整性。
// 依赖：真实 queue-data engine、runtime、lifecycle fixture 与 mock Host-memory；不替代 codec 测试。
// 所有权/生命周期：每个 case 拥有独立 fixture/factory，probe 仅借用 attachment；公开恢复后 cleanup。

// 按业务阶段命名故障；顺序只用于遍历，不作为 pending 完整性的隐含判断。
typedef enum int {
  PREP_NULL_IMAGE, PREP_GEOMETRY, PREP_STALE,
  PREP_NEXT_NULL, PREP_NEXT_TYPE, PREP_PENDING, PREP_PENDING_QUEUE,
  PREP_PENDING_IMAGE, PREP_CURSOR, PREP_NEXT_CURSOR,
  PREP_IMAGE_SHAPE, PREP_RESULT, PREP_BYTES, PREP_RESULT_IMAGE,
  PREP_RESULT_QUEUE, PREP_OFFSET
} rdma_publish_prepare_fault_e;

// 隔离 factory 只在事务窗口精确注入；status 对象始终真实创建，避免基础 make 的空解引用。
class rdma_device_publish_prepare_factory extends uvm_default_factory;
  string target_name;
  int unsigned occurrence;
  bit wrong_type;
  bit armed;
  bit fired;
  bit mutate_bytes;
  bit mutate_depth;
  bit result_created;
  rdma_hw_image source_image;
  rdma_queue_pending_operation pending;
  rdma_queue_runtime runtime_ref;

  // 功能：构造未启用的单次故障 factory，默认命中第一个同名对象。
  // 输入/输出及副作用：无输入；不安装全局 factory，不创建或拥有 runtime/镜像资源。
  // 失败/边界：case 必须在 setup 后配置 target/借用引用并 armed，结束后恢复原 factory。
  function new();
    super.new();
    occurrence = 1;
    armed = 1'b0;
    fired = 1'b0;
  endfunction

  // 功能：对指定 next/pending/result/clone 返回空或错误类型，或在真实 status 回调修改源值。
  // 输入/输出及副作用：requested_type/path/name 默认透传；只触发一次；字节故障发生在
  //   result status 分配前，depth 故障发生在 pending route/epoch 已准备完成后的 success 回调。
  // 失败/边界：不对 status 返回空；depth 必须在 cancel seam 恢复，源 image 仅本 case 使用；
  //   未命中时 fired=0，外层断言必须拒绝“测试没有实际注入”的假通过。
  virtual function uvm_object create_object_by_type(
    uvm_object_wrapper requested_type, string parent_inst_path = "", string name = ""
  );
    uvm_object created;
    rdma_hw_image wrong;

    if (armed && !fired && target_name != "" && name == target_name) begin
      occurrence--;
      if (occurrence == 0) begin
        fired = 1'b1;
        if (wrong_type) begin
          wrong = new("wrong_next_type");
          return wrong;
        end
        return null;
      end
    end
    if (armed && !fired && requested_type == rdma_status::get_type()) begin
      if (mutate_bytes && result_created) begin
        source_image.length = 0;
        fired = 1'b1;
      end
      if (mutate_depth && pending != null && pending.route_valid && pending.epoch_valid) begin
        runtime_ref.depth = 0;
        fired = 1'b1;
      end
    end
    created = super.create_object_by_type(requested_type, parent_inst_path, name);
    if (armed && name == "device_publish_pending" && !$cast(pending, created))
      `uvm_fatal("PUBLISH_PREP", "pending capture failed")
    if (armed && name == "device_publish_result") result_created = 1'b1;
    return created;
  endfunction
endclass

// probe 只暴露共同事务的测试入口；取消仍委托原 runtime，失败后仅用公开 recovery 清理。
class rdma_device_publish_prepare_probe extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_device_publish_prepare_probe)
  int unsigned cancel_mode;
  int unsigned cancel_calls;
  int unsigned saved_depth;
  rdma_device_publish_prepare_factory injector;

  // 功能：构造未配置 engine，默认取消走真实 runtime 且计数为零。
  // 输入/输出及副作用：name 传给基类；不取得 injector 或 fixture 的生命周期所有权。
  // 失败/边界：必须等 fixture.setup 完成后调用 attempt，构造不代表 attachment 已存在。
  function new(string name = "rdma_device_publish_prepare_probe");
    super.new(name);
    cancel_mode = 0;
    cancel_calls = 0;
  endfunction

  // 功能：取得真实 reservation 后注入入口拒绝或准备故障，调用生产 write/commit task。
  // 输入/输出及副作用：queue_h/kind/fault 输入，result/status 输出；记录并恢复 geometry，
  //   stale 仅替换调用者 cursor，不改真实预留；factory 只在事务执行期间 armed。
  // 失败/边界：lookup/reserve 缺失 fatal；入口拒绝后的原 reservation 保留给外层公开 abort，
  //   不手动清除账本；合成 image 只验证机制，不冒充公开 CQE/CEQE/AEQE 业务验收。
  task attempt(
    rdma_handle queue_h, rdma_queue_runtime_kind_e kind, rdma_publish_prepare_fault_e fault,
    output rdma_queue_device_publish_result result, output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_cursor_snapshot reservation;
    rdma_hw_image image;
    longint unsigned saved_stride;

    status = lookup_attachment(queue_h, kind, attachment);
    if (status == null || !status.ok() || attachment == null)
      `uvm_fatal("PUBLISH_PREP", "attachment missing")
    status = attachment.runtime.reserve_device_producer(reservation);
    if (status == null || !status.ok() || reservation == null)
      `uvm_fatal("PUBLISH_PREP", "reservation failed")
    image = new("prepare_image");
    image.length = attachment.entry_size;
    image.alignment = attachment.entry_size;
    image.endian = RDMA_ENDIAN_BIG;
    case (kind)
      RDMA_QUEUE_RUNTIME_CQ: image.image_kind = RDMA_IMAGE_CQE;
      RDMA_QUEUE_RUNTIME_CEQ: image.image_kind = RDMA_IMAGE_CEQE;
      RDMA_QUEUE_RUNTIME_AEQ: image.image_kind = RDMA_IMAGE_AEQE;
      default: `uvm_fatal("PUBLISH_PREP", "unsupported queue")
    endcase
    for (int unsigned i = 0; i < attachment.entry_size; i++) begin
      image.bytes.push_back(8'h5a);
    end
    saved_stride = attachment.entry_size;
    saved_depth = attachment.runtime.depth;
    injector.source_image = image;
    injector.runtime_ref = attachment.runtime;
    case (fault)
      PREP_NULL_IMAGE: image = null;
      PREP_GEOMETRY: attachment.entry_size = 0;
      PREP_STALE: reservation.index++;
      PREP_NEXT_NULL, PREP_NEXT_TYPE: injector.target_name = "device_publish_next";
      PREP_PENDING: injector.target_name = "device_publish_pending";
      PREP_PENDING_QUEUE: injector.target_name = "device pending queue_copy";
      PREP_PENDING_IMAGE, PREP_RESULT_IMAGE: injector.target_name = "publish_image_copy";
      PREP_CURSOR: injector.target_name = "device_pending_cursor";
      PREP_NEXT_CURSOR: injector.target_name = "device_pending_next_cursor";
      PREP_IMAGE_SHAPE: image.alignment = 0;
      PREP_RESULT: injector.target_name = "device_publish_result";
      PREP_BYTES: injector.mutate_bytes = 1'b1;
      PREP_RESULT_QUEUE: injector.target_name = "publish result queue_copy";
      PREP_OFFSET: injector.mutate_depth = 1'b1;
      default: `uvm_fatal("PUBLISH_PREP", "unsupported prepare fault")
    endcase
    injector.wrong_type = fault == PREP_NEXT_TYPE;
    injector.occurrence = fault == PREP_RESULT_IMAGE ? 2 : 1;
    injector.armed = 1'b1;
    write_commit_device_entry(attachment, reservation, image, result, status);
    injector.armed = 1'b0;
    attachment.entry_size = saved_stride;
    attachment.runtime.depth = saved_depth;
  endtask

  // 功能：计数唯一取消入口，并制造正常取消、null 或 RESOURCE_BUSY 三种结果。
  // 输入/输出及副作用：attachment/reservation 输入；先恢复临时 depth，再由 mode=0 委托
  //   基类取消；mode=1/2 不调用 runtime，保留预留以验证 reservation-only/完整 pending 分界。
  // 失败/边界：null 与 BUSY 只注入当前 case；不把失败当作已取消，不提前安装 recovery。
  protected virtual function rdma_status cancel_device_publish_reservation(
    rdma_queue_data_attachment attachment, rdma_queue_cursor_snapshot reservation
  );
    cancel_calls++;
    attachment.runtime.depth = saved_depth;
    if (cancel_mode == 1)
      return null;
    if (cancel_mode == 2)
      return rdma_status::make_direct(RDMA_SC_RESOURCE_BUSY, "injected cancel busy");
    return super.cancel_device_publish_reservation(attachment, reservation);
  endfunction
endclass

// 入口拒绝仅跑一次；十三类 owned-reservation 故障各跑三种取消结果，三种队列共 126 cases。
class rdma_device_publish_prepare_test extends uvm_test;
  `uvm_component_utils(rdma_device_publish_prepare_test)

  // 功能：构造准备阶段矩阵测试组件，不提前建立资源或替换 factory。
  // 输入/输出及副作用：name/parent 传给基类；fixture 生命周期限定在各 run_case 内。
  // 失败/边界：构造不执行仿真，run_phase 的 objection 覆盖全部 case。
  function new(string name = "rdma_device_publish_prepare_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：核对指定准备故障的零 I/O、取消次数、预留/信用与完整或缺失的恢复证据。
  // 输入/输出及副作用：kind/fault/cancel_mode 选择隔离 fixture；恢复全局 factory 后检查
  //   快照；完整且格式有效的 pending 公开 retry，其余遗留预留公开 abort/detach，最后零泄漏 cleanup。
  // 失败/边界：setup/关键 evidence 缺失 fatal，其余契约不符 error；所有失败 result 必为空，
  //   未拥有预留不可取消、残缺 pending 不可接管；abort 成功才清 fixture attached 标志。
  task run_case(
    rdma_queue_runtime_kind_e kind, rdma_publish_prepare_fault_e fault, int unsigned cancel_mode
  );
    uvm_coreservice_t service;
    uvm_factory saved_factory;
    rdma_device_publish_prepare_factory factory;
    rdma_device_publish_prepare_probe probe;
    rdma_queue_data_engine_fixture fixture;
    rdma_handle queue_h;
    rdma_status status;
    rdma_status_code_e expected_code;
    rdma_queue_device_publish_result result;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot cursor;
    int unsigned calls_before;
    int unsigned occupancy;
    bit has_pending;
    bit reserved;
    bit entry_reject;
    bit full_pending;
    bit retained;

    service = uvm_coreservice_t::get();
    saved_factory = service.get_factory();
    factory = new();
    factory.set_type_override_by_type(
      rdma_queue_data_engine::get_type(), rdma_device_publish_prepare_probe::get_type());
    service.set_factory(factory);
    fixture = new("publish_prepare_fixture");
    fixture.setup(status);
    if (status == null || !status.ok() || !$cast(probe, fixture.engine))
      `uvm_fatal("PUBLISH_PREP", "fixture setup failed")
    case (kind)
      RDMA_QUEUE_RUNTIME_CQ: queue_h = fixture.cq.handle;
      RDMA_QUEUE_RUNTIME_CEQ: queue_h = fixture.ceq.handle;
      RDMA_QUEUE_RUNTIME_AEQ: queue_h = fixture.aeq.handle;
      default: `uvm_fatal("PUBLISH_PREP", "invalid kind")
    endcase
    entry_reject = fault inside {PREP_NULL_IMAGE, PREP_GEOMETRY, PREP_STALE};
    full_pending = fault inside {PREP_IMAGE_SHAPE, PREP_RESULT, PREP_BYTES,
                                 PREP_RESULT_IMAGE, PREP_RESULT_QUEUE, PREP_OFFSET};
    retained = entry_reject || cancel_mode != 0;
    expected_code = RDMA_SC_RESOURCE_EXHAUSTED;
    case (fault)
      PREP_NULL_IMAGE, PREP_GEOMETRY: expected_code = RDMA_SC_INVALID_STATE;
      PREP_STALE: expected_code = RDMA_SC_INVALID_ARGUMENT;
      PREP_IMAGE_SHAPE, PREP_BYTES: expected_code = RDMA_SC_CODEC_ERROR;
      PREP_OFFSET: expected_code = RDMA_SC_DMA_TRANSLATION;
      default: expected_code = RDMA_SC_RESOURCE_EXHAUSTED;
    endcase
    if (!entry_reject && cancel_mode != 0) expected_code = RDMA_SC_RECOVERY_REQUIRED;
    probe.injector = factory;
    probe.cancel_mode = cancel_mode;
    calls_before = fixture.mem.calls.size();
    probe.attempt(queue_h, kind, fault, result, status);
    service.set_factory(saved_factory);
    if (status == null || status.code != expected_code || result != null ||
        probe.cancel_calls != (entry_reject ? 0 : 1) || fixture.mem.calls.size() != calls_before)
      `uvm_error("PUBLISH_PREP", $sformatf("result/cancel/I/O kind=%0d fault=%s cancel=%0d",
                                          kind, fault.name(), cancel_mode))
    if (!entry_reject && fault != PREP_IMAGE_SHAPE && !factory.fired)
      `uvm_error("PUBLISH_PREP", "factory fault did not fire")
    status = probe.query_runtime_occupancy(queue_h, kind, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 ||
        has_pending != (full_pending && cancel_mode != 0))
      `uvm_error("PUBLISH_PREP", "credit changed or partial pending admitted")
    status = probe.query_runtime_device_reservation(queue_h, kind, reserved, cursor);
    if (status == null || !status.ok() || reserved != retained ||
        (reserved && (cursor == null || cursor.index != 0 || cursor.wrap)))
      `uvm_error("PUBLISH_PREP", "reservation ownership changed")
    status = probe.query_runtime_pending(queue_h, kind, pending);
    if (full_pending && cancel_mode != 0) begin
      if (status == null || !status.ok() || pending == null || pending.failure_status == null)
        `uvm_fatal("PUBLISH_PREP", "complete pending unavailable")
      if (!pending.device_producer || pending.device_write_attempted ||
          pending.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT || !pending.known_no_mmio ||
          pending.cursor.index != 0 || pending.next_cursor.index != 1 ||
          !pending.route_valid || !pending.epoch_valid ||
          pending.failure_status.code != (cancel_mode == 1 ? RDMA_SC_INVALID_ARGUMENT :
                                                                           RDMA_SC_RESOURCE_BUSY))
        `uvm_error("PUBLISH_PREP", "cancel failure phase/authority/diagnostic changed")
    end
    else if (status == null || status.code != RDMA_SC_INVALID_STATE || pending != null)
      `uvm_error("PUBLISH_PREP", "partial evidence became visible")
    if (retained && full_pending && fault != PREP_IMAGE_SHAPE) begin
      probe.recover_queue(queue_h, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
      if (status == null || !status.ok())
        `uvm_fatal("PUBLISH_PREP", "retry failed")
      status = probe.query_runtime_occupancy(queue_h, kind, occupancy, has_pending);
      if (status == null || !status.ok() || occupancy != 1 || has_pending ||
          fixture.mem.calls.size() != calls_before + 2 ||
          fixture.mem.calls[calls_before].method_name != "write" ||
          fixture.mem.calls[calls_before + 1].method_name != "read")
        `uvm_error("PUBLISH_PREP", "retry did not write/read/commit exactly once")
      status = probe.query_runtime_device_reservation(queue_h, kind, reserved, cursor);
      if (status == null || !status.ok() || reserved)
        `uvm_error("PUBLISH_PREP", "retry retained reservation")
    end
    else if (retained) begin
      probe.recover_queue(queue_h, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b1, status);
      if (status == null || !status.ok())
        `uvm_fatal("PUBLISH_PREP", "explicit abort failed")
      case (kind)
        RDMA_QUEUE_RUNTIME_CQ: fixture.cq_attached = 1'b0;
        RDMA_QUEUE_RUNTIME_CEQ: fixture.ceq_attached = 1'b0;
        RDMA_QUEUE_RUNTIME_AEQ: fixture.aeq_attached = 1'b0;
        default: `uvm_fatal("PUBLISH_PREP", "invalid abort kind")
      endcase
    end
    fixture.cleanup(status);
    if (status == null || !status.ok() || fixture.mem.live_allocations() != 0)
      `uvm_error("PUBLISH_PREP", "cleanup leaked resources")
  endtask

  // 功能：遍历三个队列、十六类故障与适用的三类取消结果，输出 126-case 完成标记。
  // 输入/输出及副作用：phase 管理 objection；case 顺序隔离，不残留全局 factory 或资源。
  // 失败/边界：入口拒绝不枚举无意义取消模式；完成标记不替代 runner 的零 UVM_ERROR 检查。
  task run_phase(uvm_phase phase);
    rdma_queue_runtime_kind_e kinds[3] = '{
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_RUNTIME_CEQ, RDMA_QUEUE_RUNTIME_AEQ};
    rdma_publish_prepare_fault_e fault;

    phase.raise_objection(this);
    foreach (kinds[i]) begin
      fault = fault.first();
      do begin
        for (int unsigned cancel_mode = 0;
             cancel_mode < (fault inside {PREP_NULL_IMAGE, PREP_GEOMETRY, PREP_STALE} ? 1 : 3);
             cancel_mode++)
          run_case(kinds[i], fault, cancel_mode);
        fault = fault.next();
      end while (fault != fault.first());
    end
    `uvm_info("PUBLISH_PREP", "completed 126 device publish prepare cases", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
