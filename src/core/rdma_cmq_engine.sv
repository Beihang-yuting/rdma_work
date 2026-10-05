// 目录：核心执行层 core/rdma_cmq_engine.sv。
// 职责：按 rdma-driver-0.1.34 cmq.c 的行为实现 CMQ：SQ/CQ 两个 64B 条目环与 request_array，提交时 pending
//   链表为空且环未满则直接填 SQE 并打 doorbell，否则排入 pending 链表；完成侧按 CQ polarity 收割 CQE，
//   校验 wrap/opcode/ecode，推进 CI 并补发 pending；复位等价 clean_pending。
// 依赖：CMQ hardware profile（SQE 组装、CQE 解析、doorbell 编码）、Host-memory adapter、rdma_cmq_transport
//   （doorbell scheduler）。
// 所有权与生命周期：engine 拥有 ring 游标、request_array 与 pending 链表；backing mapping 由 prepare 申请、
//   reset/shutdown 释放；profile/host_mem/scheduler 为非拥有引用。
// 设计说明：驱动没有超时、重试与歧义处理。模型保留 command.timeout 作为 TB 看门狗：超时以 TIMEOUT 结束
//   该命令并让 engine 进入 POISONED（须 reset），不产生可对账的歧义；reconcile_ticket 恒报告无终态。

// 一个在途或排队的 CMQ 请求（对应驱动 struct xtrdma_cmq_request）。
class rdma_cmq_request;
  rdma_cmq_command_desc command;
  rdma_cmq_expected_response expected;
  rdma_cmq_ticket ticket;
  rdma_cmq_completion completion;
  time deadline;
  bit done;
endclass

class rdma_cmq_engine extends uvm_object;
  `rdma_object_utils(rdma_cmq_engine)

  localparam int unsigned CMQ_DEPTH = 32;
  localparam int unsigned CMQE_BYTES = 64;
  localparam int unsigned SQ_BYTES = CMQ_DEPTH * CMQE_BYTES;
  localparam int unsigned CQ_OFFSET = SQ_BYTES;
  localparam int unsigned BACKING_BYTES = 2 * SQ_BYTES;
  localparam time POLL_INTERVAL = 10ns;
  localparam time DEFAULT_TIMEOUT = 1ms;

  protected rdma_cmq_engine_state_e engine_state;
  protected rdma_function_binding binding;
  protected rdma_cmq cmq_snapshot;
  protected rdma_dma_mapping backing_mapping;
  protected rdma_host_mem_api host_mem;
  protected rdma_cmq_transport transport;
  protected rdma_cmq_hw_profile profile;
  protected semaphore engine_lock;
  // 驱动 sq_ring.head/tail：publish_seq 为已发布 SQE 数，cq_consume_seq 为已收割 CQE 数（CI = tail）。
  protected longint unsigned publish_seq;
  protected longint unsigned cq_consume_seq;
  protected longint unsigned retire_seq;
  protected longint unsigned next_command_id;
  protected rdma_cmq_request request_array[CMQ_DEPTH];
  protected rdma_cmq_request pending[$];
  protected rdma_byte_endian_e image_endian;
  protected int unsigned image_hardware_version;

  // 功能：构造未配置的 engine。
  // 输入/输出及副作用：name 为 UVM 实例名。
  // 失败/边界：无。
  function new(string name = "rdma_cmq_engine");
    super.new(name);
    engine_lock = new(1);
    engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
    retire_seq = 0;
    next_command_id = 0;
    clear_runtime();
  endfunction

  // 功能：在 PREPARED binding 下为 CMQ 申请并清零 SQ+CQ backing，建立 transport，返回 runtime 描述。
  // 输入/输出及副作用：成功时 engine 进入 PREPARED，runtime_desc 输出 SQ/CQ IOVA 与几何。
  // 失败/边界：状态非 UNCONFIGURED、参数缺失、binding/CMQ/PASID 不符或 backing 申请/清零失败时返回错误，
  //   已申请的 backing 被释放。
  task prepare(
    rdma_function_binding binding,
    rdma_cmq cmq,
    bit pasid_valid,
    bit [19:0] pasid,
    rdma_host_mem_api host_mem,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_hw_profile profile,
    output rdma_cmq_runtime_desc runtime_desc,
    output rdma_status status
  );
    rdma_dma_request_context dma_context;
    rdma_dma_mapping mapping;
    rdma_cmq_transport transport;
    byte zeros[];

    runtime_desc = null;
    mapping = null;
    engine_lock.get(1);
    status = prepare_status(binding, cmq, host_mem, scheduler, profile);
    if (status.ok())
      status = make_request_context(binding, cmq, pasid_valid, pasid, dma_context);
    if (status.ok()) begin
      transport = rdma_cmq_transport::type_id::create("cmq_transport");
      status = rdma_status::nonnull(transport.configure(scheduler),
                                    "CMQ transport configure returned null status");
    end
    if (status.ok()) begin
      status = rdma_status::nonnull(host_mem.allocate(dma_context, BACKING_BYTES, BACKING_BYTES,
                                                      RDMA_DMA_BIDIRECTIONAL, mapping),
                                    "CMQ host allocation returned null status");
      if (status.ok() && mapping == null)
        status = invalid_state("CMQ host allocation returned no mapping");
    end
    if (status.ok()) begin
      zeros = new[BACKING_BYTES];
      foreach (zeros[i])
        zeros[i] = 0;
      status = rdma_status::nonnull(host_mem.write(mapping, 0, zeros),
                                    "CMQ backing zero-write returned null status");
    end
    if (status.ok())
      status = build_runtime_desc(binding, cmq, mapping, runtime_desc);
    if (!status.ok()) begin
      if (mapping != null)
        void'(host_mem.\release (mapping));
      runtime_desc = null;
      engine_lock.put(1);
      return;
    end
    this.binding = rdma_deep_copy#(rdma_function_binding)::of(binding, "CMQ binding snapshot");
    cmq_snapshot = rdma_deep_copy#(rdma_cmq)::of(cmq, "CMQ resource snapshot");
    cmq_snapshot.queue_iova = runtime_desc.sq_iova;
    cmq_snapshot.completion_iova = runtime_desc.cq_iova;
    backing_mapping = mapping;
    this.host_mem = host_mem;
    this.transport = transport;
    this.profile = profile;
    clear_ring();
    engine_state = RDMA_CMQ_ENGINE_PREPARED;
    engine_lock.put(1);
  endtask

  // 功能：binding 进入 ACTIVE 后启用提交（之后 doorbell 以 ACTIVE binding 发出）。
  // 输入/输出及副作用：成功时 engine 进入 ACTIVE。
  // 失败/边界：状态非 PREPARED 或 binding 非同一 Function 的 ACTIVE binding 时返回错误。
  task activate(rdma_function_binding active_binding, output rdma_status status);
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_PREPARED)
      status = invalid_state("CMQ activate requires a PREPARED engine");
    else
      status = binding_status(active_binding, RDMA_BIND_ACTIVE);
    if (status.ok() && !same_handle(active_binding.make_handle(), binding.make_handle()))
      status = invalid_argument("CMQ active binding belongs to a different Function");
    if (status.ok()) begin
      binding = rdma_deep_copy#(rdma_function_binding)::of(active_binding,
                                                            "CMQ active binding snapshot");
      engine_state = RDMA_CMQ_ENGINE_ACTIVE;
    end
    engine_lock.put(1);
  endtask

  // 功能：执行一条 CMQ 命令并等待其完成（驱动 handle_cmq_op）：快照命令后提交或排入 pending，然后轮询
  //   CQ 收割直到本请求完成或看门狗超时。
  // 输入/输出及副作用：result 输出提交效果、ticket、completion 与终态 status；可能写 SQE、打 doorbell、消费 CQE。
  // 失败/边界：engine 非 ACTIVE、命令非法或 SQE 组装/写入失败时为 PRE_SUBMIT_REJECTED；doorbell 失败按
  //   scheduler 报告的效果返回；看门狗超时返回 TIMEOUT 并使 engine 进入 POISONED。
  task execute_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
    rdma_cmq_request request;
    rdma_submission_effect_e effect;
    rdma_status status;

    result = new("cmq_execution_result");
    result.observation_status = rdma_status::success();
    result.recovery_required = 1'b0;
    effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    engine_lock.get(1);
    status = admit(command, request);
    if (status.ok()) begin
      if (pending.size() == 0 && !ring_full())
        post_request(request, status, effect);
      else
        pending.push_back(request);
    end
    engine_lock.put(1);
    if (!status.ok()) begin
      reject(result, status);
      result.submission_effect = effect;
      result.attempt_effect = effect;
      return;
    end
    wait_request(request);
    publish_result(request, result);
  endtask

  // 功能：取消全部在途与 pending 请求（驱动 clean_pending_cmq_requests），释放 backing 并回到 UNCONFIGURED，
  //   之后可重新 prepare。
  // 输入/输出及副作用：completions 输出被取消请求的 RESET_CANCELLED completion。
  // 失败/边界：未配置时直接成功；backing 释放失败返回其 status（状态仍回到 UNCONFIGURED）。
  task reset(output rdma_cmq_completion completions[$], output rdma_status status);
    engine_lock.get(1);
    status = teardown(completions, RDMA_CMQ_ENGINE_UNCONFIGURED);
    engine_lock.put(1);
  endtask

  // 功能：最终关闭：取消全部请求、释放 backing 并进入 QUIESCED（不再接受 prepare）。
  // 输入/输出及副作用：同 reset。
  // 失败/边界：backing 释放失败返回其 status。
  task shutdown(output rdma_status status);
    rdma_cmq_completion completions[$];

    engine_lock.get(1);
    status = teardown(completions, RDMA_CMQ_ENGINE_QUIESCED);
    engine_lock.put(1);
  endtask

  // 功能：返回 engine 状态。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function rdma_cmq_engine_state_e state();
    return engine_state;
  endfunction

  // 功能：返回 backing mapping 的 detached 快照。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：未配置返回 null。
  function rdma_dma_mapping mapping_snapshot();
    if (backing_mapping == null)
      return null;
    return rdma_deep_copy#(rdma_dma_mapping)::of(backing_mapping, "CMQ mapping snapshot");
  endfunction

  // 功能：已发布 SQE 数（驱动 cmq_req_stats）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function longint unsigned published_count();
    return publish_seq;
  endfunction

  // 功能：已完成（含取消）的请求数。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function longint unsigned retired_count();
    return retire_seq;
  endfunction

  // 功能：已收割 CQE 数（驱动 cmq_cmpl_stats）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function longint unsigned cq_consumed_count();
    return cq_consume_seq;
  endfunction

  // 功能：环内在途与 pending 链表中的请求总数。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function int unsigned outstanding_count();
    return int'(publish_seq - cq_consume_seq) + pending.size();
  endfunction

  // 功能：port reconcile 入口。驱动语义下每条命令都以终态返回，engine 不保留可对账的歧义 ticket。
  // 输入/输出及副作用：terminal_known=0、completion=null；无副作用。
  // 失败/边界：恒返回 INVALID_STATE。
  task reconcile_ticket(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    terminal_known = 1'b0;
    completion = null;
    status = invalid_state("CMQ engine keeps no ambiguous tickets to reconcile");
  endtask

  // 功能：命令的 detached 快照（rdma_object_utils 深拷贝整张对象图），供 engine 与 mock port 共用。
  // 输入/输出及副作用：snapshot 输出。
  // 失败/边界：命令为空、拷贝失败或校验失败时返回错误且 snapshot=null；body 编码合法性由 compose_sqe 检查。
  static function rdma_status snapshot_command(
    rdma_cmq_command_desc source,
    output rdma_cmq_command_desc snapshot
  );
    rdma_status status;

    snapshot = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "CMQ command is null");
    if (!rdma_deep_copy#(rdma_cmq_command_desc)::try_of(source, snapshot)) begin
      snapshot = null;
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "CMQ command snapshot clone failed");
    end
    status = rdma_status::nonnull(snapshot.validate(),
                                  "CMQ command validation returned null status");
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // ---------------------------------------------------------------- 提交

  // 功能：校验 engine 状态与命令 Function，快照命令并建立请求（看门狗截止时间取 command.timeout）。
  // 输入/输出及副作用：request 输出；在 engine_lock 内调用。
  // 失败/边界：非 ACTIVE、命令非法或 Function 不符时返回错误且 request=null。
  protected function rdma_status admit(rdma_cmq_command_desc command,
                                       output rdma_cmq_request request);
    rdma_cmq_command_desc snapshot;
    rdma_status status;

    request = null;
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE)
      return invalid_state(engine_state == RDMA_CMQ_ENGINE_POISONED ?
        "CMQ engine requires reset after a watchdog timeout" : "CMQ engine is not ACTIVE");
    status = snapshot_command(command, snapshot);
    if (!status.ok())
      return status;
    if (snapshot.function_h == null || !same_handle(snapshot.function_h, binding.make_handle()))
      return invalid_argument("CMQ command Function does not match the engine binding");
    request = new();
    request.command = snapshot;
    request.deadline = $time + (snapshot.timeout != 0 ? snapshot.timeout : DEFAULT_TIMEOUT);
    return rdma_status::success();
  endfunction

  // 功能：驱动 exec_cmq_cmd + post_sq：在当前 PI 组装并写入 SQE，登记 request_array，PI+1（回零翻转
  //   polarity），以新 PI/polarity 打 doorbell。
  // 输入/输出及副作用：写 SQ backing、发 doorbell；effect 输出提交效果。
  // 失败/边界：组装/写入失败时不推进 PI（PRE_SUBMIT_REJECTED）；doorbell 编码/提交失败时效果取自
  //   scheduler，请求从 request_array 撤销且 engine 进入 POISONED。
  protected task post_request(rdma_cmq_request request, output rdma_status status,
                              output rdma_submission_effect_e effect);
    rdma_cmq_slot_context slot;
    rdma_hw_image sqe;
    rdma_hw_image doorbell;
    rdma_doorbell_submission_result submitted;
    byte data[];

    effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    slot = rdma_cmq_slot_context::type_id::create("cmq_slot");
    slot.function_h = binding.make_handle();
    slot.cmq_h = rdma_clone_handle_value(cmq_snapshot.handle, "CMQ slot");
    slot.backing_addr = backing_mapping.backing_addr;
    slot.relative_offset = longint'(ring_index(publish_seq)) * CMQE_BYTES;
    slot.slot_sequence = publish_seq;
    slot.sq_index = ring_index(publish_seq);
    slot.sq_wrap = ring_wrap(publish_seq);
    status = rdma_status::nonnull(profile.compose_sqe(request.command, slot, sqe, request.expected),
                                  "CMQ SQE composition returned null status");
    if (status.ok() && (sqe == null || sqe.bytes.size() != CMQE_BYTES || request.expected == null))
      status = invalid_state("CMQ profile composed an incomplete SQE");
    if (status.ok()) begin
      data = new[CMQE_BYTES];
      foreach (data[i])
        data[i] = sqe.bytes[i];
      status = rdma_status::nonnull(host_mem.write(backing_mapping, slot.relative_offset, data),
                                    "CMQ SQE write returned null status");
    end
    if (!status.ok())
      return;
    image_endian = sqe.endian;
    image_hardware_version = sqe.hardware_version;
    request.ticket = make_ticket(request, slot);
    request_array[slot.sq_index] = request;
    publish_seq++;
    effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN;
    status = rdma_status::nonnull(profile.encode_doorbell(cmq_snapshot.handle,
                                                          ring_index(publish_seq),
                                                          ring_wrap(publish_seq), doorbell),
                                  "CMQ doorbell encoding returned null status");
    if (status.ok()) begin
      transport.submit_observed(binding, make_doorbell_desc(doorbell), null, submitted);
      status = submitted.status;
      effect = submitted.submission_effect;
    end
    if (!status.ok()) begin
      // PI 已推进而设备未必看到 doorbell：环游标不再可信，须 reset。
      request_array[slot.sq_index] = null;
      engine_state = RDMA_CMQ_ENGINE_POISONED;
    end
  endtask

  // 功能：构造请求的 ticket（command ID、Function/CMQ 身份、SQ 槽位、opcode 与看门狗截止时间）。
  // 输入/输出及副作用：推进 next_command_id。
  // 失败/边界：无。
  protected function rdma_cmq_ticket make_ticket(rdma_cmq_request request,
                                                 rdma_cmq_slot_context slot);
    rdma_cmq_ticket ticket;

    ticket = rdma_cmq_ticket::type_id::create("cmq_ticket");
    next_command_id++;
    ticket.command_id = next_command_id;
    ticket.function_h = binding.make_handle();
    ticket.cmq_h = rdma_clone_handle_value(cmq_snapshot.handle, "CMQ ticket");
    ticket.slot_sequence = slot.slot_sequence;
    ticket.sq_index = slot.sq_index;
    ticket.sq_wrap = slot.sq_wrap;
    ticket.opcode_key = rdma_deep_copy#(rdma_cmq_opcode_key)::of(request.command.opcode_key,
                                                                 "CMQ ticket opcode");
    ticket.absolute_deadline = request.deadline;
    return ticket;
  endfunction

  // 功能：把 profile 编码的 doorbell image 包装为 CMQ SQ doorbell 描述符（DMA→MMIO 屏障、不合并）。
  // 输入/输出及副作用：纯构造。
  // 失败/边界：无。
  protected function rdma_doorbell_desc make_doorbell_desc(rdma_hw_image doorbell);
    rdma_doorbell_desc desc;

    desc = rdma_doorbell_desc::type_id::create("cmq_doorbell");
    desc.kind = RDMA_DOORBELL_CMQ_SQ;
    desc.function_h = binding.make_handle();
    desc.target_h = rdma_clone_handle_value(cmq_snapshot.handle, "CMQ doorbell");
    desc.notify_bar_id = binding.notify_bar_id;
    desc.relative_offset = doorbell.bar_target.value;
    desc.width = doorbell.length;
    desc.endian = doorbell.endian;
    desc.payload_image = doorbell;
    desc.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    desc.write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    desc.allow_merge = 1'b0;
    desc.merge_requested = 1'b0;
    desc.timeout = DEFAULT_TIMEOUT;
    desc.readback_policy = RDMA_DB_READBACK_NONE;
    return desc;
  endfunction

  // 功能：SQ 环是否已满（驱动 XTRDMA_RING_FULL：head - tail >= size）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  protected function bit ring_full();
    return publish_seq - cq_consume_seq >= CMQ_DEPTH;
  endfunction

  // 功能：单调序号在环内的槽位（驱动 head/tail 取模）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function int unsigned ring_index(longint unsigned seq);
    return seq % CMQ_DEPTH;
  endfunction

  // 功能：单调序号所在圈的 wrap 位；SQE valid 与 CQ 期望 owner 均为其反值（驱动 polarity 初值 1）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function bit ring_wrap(longint unsigned seq);
    return (seq / CMQ_DEPTH) & 1'b1;
  endfunction

  // ---------------------------------------------------------------- 完成

  // 功能：轮询收割直到请求完成（驱动 wait_event 中循环调用 ce_handler）；超过截止时间视为看门狗超时。
  // 输入/输出及副作用：可能消费 CQE、补发 pending；超时置 engine 为 POISONED 并以 TIMEOUT 结束请求。
  // 失败/边界：无。
  protected task wait_request(rdma_cmq_request request);
    forever begin
      engine_lock.get(1);
      if (!request.done)
        harvest_completions();
      if (!request.done && $time >= request.deadline) begin
        engine_state = RDMA_CMQ_ENGINE_POISONED;
        finish_request(request, rdma_status::make(RDMA_SC_TIMEOUT,
                       "CMQ command has no completion before the watchdog deadline"), null, null);
      end
      engine_lock.put(1);
      if (request.done)
        return;
      #(POLL_INTERVAL);
    end
  endtask

  // 功能：驱动 ce_handler：按 CQ polarity 依次读取新 CQE，找回请求并完成，推进 CI（回零翻转 polarity）；
  //   本轮有收割时补发 pending 链表（驱动 process_bh）。
  // 输入/输出及副作用：在 engine_lock 内调用；读 CQ backing、完成请求、可能写 SQE 并打 doorbell。
  // 失败/边界：CQE 读取/解析失败或指向空槽时 engine 进入 POISONED 并停止收割；POISONED 时清空 pending。
  protected task harvest_completions();
    rdma_cmq_decoded_cqe decoded;
    rdma_hw_image raw_cqe;
    rdma_status status;
    bit ready;
    int unsigned harvested;

    harvested = 0;
    while (engine_state == RDMA_CMQ_ENGINE_ACTIVE && cq_consume_seq < publish_seq) begin
      status = read_cqe(raw_cqe, ready, decoded);
      if (status.ok() && !ready)
        break;
      if (!status.ok() || decoded == null || decoded.wqe_index >= CMQ_DEPTH ||
          request_array[decoded.wqe_index] == null) begin
        engine_state = RDMA_CMQ_ENGINE_POISONED;
        `uvm_error("RDMA_CMQ", status.ok() ? "CMQ CQE does not match an outstanding request" :
                   {"CMQ CQE inspection failed: ", status.convert2string()})
        break;
      end
      complete_from_cqe(request_array[decoded.wqe_index], decoded, raw_cqe);
      request_array[decoded.wqe_index] = null;
      cq_consume_seq++;
      harvested++;
    end
    if (harvested != 0 || engine_state != RDMA_CMQ_ENGINE_ACTIVE)
      submit_pending();
  endtask

  // 功能：读取当前 CI 的 CQE 并由 profile 按期望 owner（驱动 cq_polarity）解析。
  // 输入/输出及副作用：raw_cqe/ready/decoded 输出；只读 CQ backing。
  // 失败/边界：读失败或 profile 拒绝时返回错误。
  protected function rdma_status read_cqe(output rdma_hw_image raw_cqe, output bit ready,
                                          output rdma_cmq_decoded_cqe decoded);
    rdma_status status;
    byte data[];

    raw_cqe = null;
    ready = 1'b0;
    decoded = null;
    status = rdma_status::nonnull(host_mem.read(backing_mapping,
                                                CQ_OFFSET +
                                                  longint'(ring_index(cq_consume_seq)) * CMQE_BYTES,
                                                CMQE_BYTES, data),
                                  "CMQ CQ read returned null status");
    if (!status.ok())
      return status;
    if (data.size() != CMQE_BYTES)
      return invalid_state("CMQ host read did not return one full CQE");
    raw_cqe = rdma_hw_image::type_id::create("cmq_raw_cqe");
    foreach (data[i])
      raw_cqe.bytes.push_back(data[i]);
    raw_cqe.length = CMQE_BYTES;
    raw_cqe.alignment = CMQE_BYTES;
    raw_cqe.endian = image_endian;
    raw_cqe.image_kind = RDMA_IMAGE_CMQ_CQE;
    raw_cqe.hardware_version = image_hardware_version;
    raw_cqe.function_generation = binding.generation;
    raw_cqe.write_target_kind = RDMA_HW_TARGET_NONE;
    return rdma_status::nonnull(profile.inspect_cqe(raw_cqe, !ring_wrap(cq_consume_seq), ready,
                                                    decoded),
                                "CMQ CQE inspection returned null status");
  endfunction

  // 功能：驱动 get_cqe_common_info：CQE wrap 须等于 SQE wrap、opcode 须等于请求 opcode，否则该请求以错误
  //   完成；否则以 profile 解码的命令状态（ecode 非 0 即失败）与回传负载完成。
  // 输入/输出及副作用：完成 request。
  // 失败/边界：无（失败记入请求 status）。
  protected function void complete_from_cqe(rdma_cmq_request request, rdma_cmq_decoded_cqe decoded,
                                            rdma_hw_image raw_cqe);
    rdma_status status;

    if (decoded.wqe_wrap != request.ticket.sq_wrap)
      status = rdma_status::make(RDMA_SC_INVALID_STATE, $sformatf(
        "the wrap of CMDSQ and CMDCQ is mismatched, CMDSQ_wrap[%0d] CMDCQ_wrap[%0d]",
        request.ticket.sq_wrap, decoded.wqe_wrap));
    else if (decoded.hardware_opcode != request.expected.hardware_opcode)
      status = rdma_status::make(RDMA_SC_INVALID_STATE, $sformatf(
        "CMQ get a mismatch opcode, expect 0x%0h but get 0x%0h",
        request.expected.hardware_opcode, decoded.hardware_opcode));
    else
      status = rdma_status::nonnull(decoded.command_status, "CMQ CQE command status is null");
    finish_request(request, status, raw_cqe, decoded.response_payload);
  endfunction

  // 功能：驱动 process_bh：环有空位时按序把 pending 链表中的请求提交到 SQ。
  // 输入/输出及副作用：可能写 SQE 并打 doorbell。
  // 失败/边界：提交失败的请求以该错误完成；engine 已 POISONED 时 pending 请求全部以 INVALID_STATE
  //   完成，不再等待看门狗。
  protected task submit_pending();
    rdma_cmq_request request;
    rdma_submission_effect_e effect;
    rdma_status status;

    while (pending.size() != 0 && (engine_state != RDMA_CMQ_ENGINE_ACTIVE || !ring_full())) begin
      request = pending.pop_front();
      if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
        finish_request(request, invalid_state("CMQ engine is poisoned; pending request dropped"),
                       null, null);
        continue;
      end
      post_request(request, status, effect);
      if (!status.ok())
        finish_request(request, status, null, null);
    end
  endtask

  // 功能：以 status 完成请求，生成 completion（ticket、status、raw CQE 与回传负载）。
  // 输入/输出及副作用：置 done，推进 retire_seq。
  // 失败/边界：已完成的请求忽略。
  protected function void finish_request(rdma_cmq_request request, rdma_status status,
                                         rdma_hw_image raw_cqe, uvm_object payload);
    if (request.done)
      return;
    request.completion = rdma_cmq_completion::type_id::create("cmq_completion");
    request.completion.ticket = request.ticket;
    request.completion.status = status;
    request.completion.raw_cqe = raw_cqe;
    request.completion.decoded_response = payload;
    request.done = 1'b1;
    retire_seq++;
  endfunction

  // 功能：把已结束的请求投影为 execution result。
  // 输入/输出及副作用：写 result。
  // 失败/边界：未获得 ticket（pending 补发失败）为 PRE_SUBMIT_REJECTED；看门狗超时/复位取消各有完成阶段。
  protected function void publish_result(rdma_cmq_request request,
                                         rdma_cmq_execution_result result);
    rdma_status status;

    status = request.completion.status;
    result.ticket = request.ticket;
    result.completion = request.completion;
    result.status = status;
    result.recovery_required = 1'b0;
    if (request.ticket == null) begin
      reject(result, status);
      return;
    end
    result.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    result.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    if (request.completion.raw_cqe != null)
      result.completion_phase = RDMA_CMQ_COMPLETION_TERMINAL;
    else if (status.code == RDMA_SC_TIMEOUT)
      result.completion_phase = RDMA_CMQ_COMPLETION_TIMEOUT;
    else
      result.completion_phase = RDMA_CMQ_COMPLETION_RESET_CANCELLED;
  endfunction

  // 功能：把 result 置为未提交拒绝。
  // 输入/输出及副作用：写 result。
  // 失败/边界：无。
  protected function void reject(rdma_cmq_execution_result result, rdma_status status);
    result.status = status;
    result.submission_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.attempt_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.completion_phase = RDMA_CMQ_COMPLETION_NONE;
  endfunction

  // ---------------------------------------------------------------- 配置与复位

  // 功能：驱动 clean_pending_cmq_requests + destroy：环内在途与 pending 请求以 RESET_CANCELLED 完成，
  //   释放 backing，进入 final_state。
  // 输入/输出及副作用：completions 输出被取消请求的 completion。
  // 失败/边界：backing 释放失败返回其 status。
  protected function rdma_status teardown(output rdma_cmq_completion completions[$],
                                          input rdma_cmq_engine_state_e final_state);
    rdma_status status;
    rdma_status cancelled;

    completions.delete();
    status = rdma_status::success();
    cancelled = rdma_status::make(RDMA_SC_RESET_CANCELLED, "CMQ request was cancelled by reset");
    foreach (request_array[i]) begin
      if (request_array[i] == null)
        continue;
      finish_request(request_array[i], cancelled, null, null);
      completions.push_back(request_array[i].completion);
    end
    foreach (pending[i]) begin
      finish_request(pending[i], cancelled, null, null);
      completions.push_back(pending[i].completion);
    end
    if (backing_mapping != null && host_mem != null)
      status = rdma_status::nonnull(host_mem.\release (backing_mapping),
                                    "CMQ backing release returned null status");
    clear_runtime();
    engine_state = final_state;
    return status;
  endfunction

  // 功能：清空 ring 游标、request_array 与 pending 链表。
  // 输入/输出及副作用：修改 engine 字段。
  // 失败/边界：无。
  protected function void clear_ring();
    publish_seq = 0;
    cq_consume_seq = 0;
    foreach (request_array[i])
      request_array[i] = null;
    pending.delete();
  endfunction

  // 功能：清空全部运行期引用（未配置状态）。
  // 输入/输出及副作用：修改 engine 字段。
  // 失败/边界：无。
  protected function void clear_runtime();
    clear_ring();
    binding = null;
    cmq_snapshot = null;
    backing_mapping = null;
    host_mem = null;
    transport = null;
    profile = null;
    image_endian = RDMA_ENDIAN_LITTLE;
    image_hardware_version = 0;
  endfunction

  // 功能：prepare 入参校验：状态、binding（PREPARED）、CMQ 资源与依赖。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：返回首个不符的错误。
  protected function rdma_status prepare_status(
    rdma_function_binding binding,
    rdma_cmq cmq,
    rdma_host_mem_api host_mem,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_hw_profile profile
  );
    rdma_status status;
    rdma_function_handle owner;

    if (engine_state != RDMA_CMQ_ENGINE_UNCONFIGURED)
      return invalid_state("CMQ engine is already configured");
    status = binding_status(binding, RDMA_BIND_PREPARED);
    if (!status.ok())
      return status;
    if (cmq == null)
      return invalid_argument("CMQ resource is null");
    status = rdma_status::nonnull(cmq.validate(), "CMQ resource returned null status");
    if (!status.ok())
      return status;
    if (cmq.state != RDMA_RESOURCE_ALLOCATED)
      return invalid_state("CMQ resource is not ALLOCATED");
    if (cmq.depth != CMQ_DEPTH)
      return invalid_argument("CMQ queue depth must be 32");
    owner = binding.make_handle();
    if (cmq.owner == null || !same_handle(cmq.owner, owner))
      return invalid_argument("CMQ owner does not match Function binding");
    if (cmq.handle == null || cmq.handle.kind != RDMA_RESOURCE_CMQ ||
        cmq.handle.function_uid != owner.function_uid)
      return invalid_argument("CMQ resource handle is invalid");
    if (cmq.handle.generation != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "CMQ handle Function generation does not match owner");
    if (host_mem == null)
      return invalid_argument("CMQ host memory adapter is null");
    if (scheduler == null)
      return invalid_argument("CMQ doorbell scheduler is null");
    if (profile == null)
      return invalid_argument("CMQ hardware profile is null");
    return rdma_status::nonnull(profile.validate_profile(),
                                "CMQ hardware profile returned null status");
  endfunction

  // 功能：binding 非空、处于 expected 状态且自身校验通过。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：返回首个不符的错误。
  protected function rdma_status binding_status(rdma_function_binding binding,
                                                rdma_binding_state_e expected);
    if (binding == null)
      return invalid_argument("CMQ Function binding is null");
    if (binding.state != expected)
      return invalid_state(expected == RDMA_BIND_ACTIVE ?
                           "CMQ activate requires an ACTIVE binding" :
                           "CMQ prepare requires a PREPARED binding");
    return rdma_status::nonnull(binding.validate(), "CMQ binding returned null status");
  endfunction

  // 功能：按 Function 队列 DMA authority 构造 CMQ backing 的 DMA 请求上下文。
  // 输入/输出及副作用：request_context 输出。
  // 失败/边界：PASID 与 Function 授权不符返回 DMA_TRANSLATION；上下文校验失败返回其 status。
  protected function rdma_status make_request_context(
    rdma_function_binding binding,
    rdma_cmq cmq,
    bit pasid_valid,
    bit [19:0] pasid,
    output rdma_dma_request_context request_context
  );
    rdma_function_identity identity;

    request_context = rdma_dma_request_context::type_id::create("cmq_dma_request_context");
    if (pasid_valid != binding.queue_dma.pasid_valid ||
        (pasid_valid ? pasid : '0) != binding.queue_dma.pasid)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "CMQ PASID does not match Function queue DMA authority");
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return invalid_state("CMQ DMA Function identity snapshot failed");
    request_context.function_h = binding.make_handle();
    request_context.requester_bdf = binding.queue_dma.requester_bdf;
    request_context.pasid_valid = binding.queue_dma.pasid_valid;
    request_context.pasid = binding.queue_dma.pasid;
    request_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    request_context.route = identity.route_key();
    request_context.route_valid = 1'b1;
    request_context.reset_epoch = identity.reset_epoch;
    request_context.epoch_valid = 1'b1;
    request_context.owner_h = rdma_clone_handle_value(cmq.handle, "CMQ DMA owner");
    return rdma_status::nonnull(request_context.validate(),
                                "CMQ DMA request context returned null status");
  endfunction

  // 功能：构造 runtime 描述：SQ 在 backing 起点、CQ 紧随其后，深度 32、条目 64B，SQ valid/CQ owner 初值 1、
  //   doorbell polarity 初值 0（与驱动 sq/cq polarity 初值 1 对应）。
  // 输入/输出及副作用：runtime 输出。
  // 失败/边界：IOVA 相加溢出或描述校验失败返回错误。
  protected function rdma_status build_runtime_desc(
    rdma_function_binding binding,
    rdma_cmq cmq,
    rdma_dma_mapping mapping,
    output rdma_cmq_runtime_desc runtime
  );
    rdma_status status;

    runtime = null;
    if (mapping.iova.value > 64'hffff_ffff_ffff_ffff - CQ_OFFSET)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "CMQ SQ-to-CQ IOVA addition overflows");
    runtime = rdma_cmq_runtime_desc::type_id::create("cmq_runtime");
    runtime.function_h = binding.make_handle();
    runtime.cmq_h = rdma_clone_handle_value(cmq.handle, "CMQ runtime");
    runtime.sq_iova = mapping.iova;
    runtime.cq_iova.value = mapping.iova.value + CQ_OFFSET;
    runtime.sq_depth = CMQ_DEPTH;
    runtime.cq_depth = CMQ_DEPTH;
    runtime.entry_bytes = CMQE_BYTES;
    runtime.initial_sq_valid = 1'b1;
    runtime.initial_cq_owner = 1'b1;
    runtime.initial_doorbell_polarity = 1'b0;
    status = rdma_status::nonnull(runtime.validate(),
                                  "CMQ runtime descriptor returned null status");
    if (!status.ok())
      runtime = null;
    return status;
  endfunction

  // 功能：比较两个 handle 是否指向同一实例。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：任一为空返回 0。
  protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
    return lhs != null && rhs != null && lhs.same_instance(rhs);
  endfunction

  // 功能：构造 INVALID_ARGUMENT status。
  // 输入/输出及副作用：纯构造。
  // 失败/边界：无。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 INVALID_STATE status。
  // 输入/输出及副作用：纯构造。
  // 失败/边界：无。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction
endclass
