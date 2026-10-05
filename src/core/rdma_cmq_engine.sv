// 目录：核心执行层 core/rdma_cmq_engine.sv。
// 职责：管理 CMQ backing、ring/slot 账本与提交/完成/恢复状态；prepare 时安装无状态 transport facade。
//  完成、恢复、execute、reconcile、wait、shutdown 各业务阶段共用持锁入口与统一出口，在原 engine_lock
//  内借用候选，不增加持久 authority。
// 依赖：CMQ model/profile、Host-memory adapter、doorbell scheduler、rdma_cmq_transport 与共享
//  submission evidence。
// 所有权与生命周期：engine 拥有本地锁、快照、账本与每次 prepare 新建的 facade；Host-memory/profile/
//  scheduler 为非拥有引用，backing 由 adapter 管理。

// 设计说明：engine 是 CMQ runtime、journal、fence 与复位代际的唯一可变所有者，snapshot/value helper
//  不另建账本；任何发布须先通过锁内身份检查。
class rdma_cmq_engine extends uvm_object;
  `uvm_object_utils(rdma_cmq_engine)

  localparam int unsigned CMQ_DEPTH = 32;
  localparam int unsigned CMQE_BYTES = 64;
  localparam int unsigned SQ_BYTES = 2048;
  localparam int unsigned CQ_OFFSET = SQ_BYTES;
  localparam int unsigned BACKING_BYTES = 2 * SQ_BYTES;

  protected semaphore engine_lock;
  protected rdma_cmq_engine_state_e engine_state;
  protected rdma_function_binding prepared_binding;
  protected rdma_dma_request_context dma_context;
  protected rdma_cmq cmq_snapshot;
  protected rdma_dma_mapping backing_mapping;
  protected rdma_host_mem_api host_mem;
  protected rdma_doorbell_scheduler scheduler;
  protected rdma_cmq_transport transport;
  protected rdma_cmq_hw_profile profile;
  protected longint unsigned publish_seq;
  protected longint unsigned retire_seq;
  protected longint unsigned cq_consume_seq;
  protected rdma_cmq_slot_record slots[CMQ_DEPTH];
  protected bit token_in_use[CMQ_DEPTH];
  protected bit [58:0] token_incarnation[CMQ_DEPTH];
  protected rdma_cmq_slot_record command_registry[string];
  protected rdma_cmq_slot_record entry_registry[string];
  protected rdma_cmq_completion terminal_fifo[$];
  protected rdma_cmq_diagnostic diagnostic_fifo[$];
  protected rdma_cmq_completion late_final_fifo[$];
  protected rdma_cmq_diagnostic last_poison;
  // // 公开 authority 校验失败的候选 mapping 须经 adapter 的 opaque allocation identity 重试释放；
  // // 仅在 engine 为 POISONED 且 backing 未释放时保留此位。
  protected bit backing_release_opaque;
  // // reset_observed 持有外部 release 窗口；置位期间所有公开生命周期修改入口必须 fail closed，
  // // 避免 runtime 图在 candidate staging 与无分配 commit 之间漂移。
  protected bit reset_release_in_progress;
  // // 固定的 CMQ profile API 没有单独的 raw-CQE metadata hook，故 profile 的 SQE/CQE image 共用一种
  // // endian/hardware-version 格式；仅 scheduler 成功的 batch 可建立此 authority，staging/transport
  // // 失败须保持不变。
  protected bit profile_image_format_valid;
  protected rdma_byte_endian_e profile_image_endian;
  protected int unsigned profile_hardware_version;
  // // journal 身份计数在 UVM 对象整个生命周期内单调；四张表与 fence 受 engine_lock 保护，
  // // 存在 retained row 时有意跨 reset/reprepare 保留。
  protected longint unsigned engine_instance_id;
  protected longint unsigned engine_incarnation;
  protected longint unsigned batch_id_counter;
  protected longint unsigned attempt_id_counter;
  protected longint unsigned reset_proof_id_counter;
  protected rdma_cmq_batch_submission_record submission_journal[string];
  protected string journal_batch_by_ticket[string];
  protected rdma_cmq_preallocated_publish_batch
    preallocated_publish_batches[string];
  // 预分配 observer 行仅以 exact object identity 授权；字符串字段只是
  //   查找键，成功 arm 与对应 preallocation 在同一无分配函数中消费。
  protected rdma_cmq_mmio_arm_observer arm_observers[string];
  // Approved non-owning seam: each row retains the exact profile service
  // used to type/canonicalize only its own record.
  protected rdma_cmq_hw_profile journal_profile_by_batch[string];
  protected string fenced_batch_key;
  protected string submission_fence_reason;

  // 功能：构造 UNCONFIGURED 的 CMQ engine，捕获 UVM instance ID，初始化 journal 计数与各表。
  // 输入/输出及副作用：name 传给 uvm_object；engine_instance_id 仅在构造时捕获一次；引用均置 null。
  // 失败/边界：不申请 Host-memory、不建 facade；instance ID 为零时 batch allocator fail-closed。
  function new(string name = "rdma_cmq_engine");
    int unsigned captured_instance_id;

    super.new(name);
    captured_instance_id = get_inst_id();
    engine_instance_id = captured_instance_id;
    engine_lock = new(1);
    engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
    prepared_binding = null;
    dma_context = null;
    cmq_snapshot = null;
    backing_mapping = null;
    host_mem = null;
    scheduler = null;
    transport = null;
    profile = null;
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    engine_incarnation = 0;
    batch_id_counter = 0;
    attempt_id_counter = 0;
    reset_proof_id_counter = 0;
    submission_journal.delete();
    journal_batch_by_ticket.delete();
    preallocated_publish_batches.delete();
    arm_observers.delete();
    journal_profile_by_batch.delete();
    fenced_batch_key = "";
    submission_fence_reason = "";
    last_poison = null;
    backing_release_opaque = 1'b0;
    reset_release_in_progress = 1'b0;
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
      token_incarnation[i] = '0;
    end
  endfunction

  // 功能：构造 INVALID_ARGUMENT 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 INVALID_STATE 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：reset_observed 把 backing release 交给 adapter 期间，拒绝会读写 runtime graph 的生命周期入口。
  // 输入/输出及副作用：只读 reset_release_in_progress；返回成功或 INVALID_STATE，不改任何状态。
  // 失败/边界：gate 为 1 时 INVALID_STATE，调用方须已持锁并立即退出；本函数不取锁，也不替代
  //  reset_observed 对 release 结果的 CAS 重验。
  protected function rdma_status reset_release_gate_status();
    if (reset_release_in_progress)
      return invalid_state(
        "CMQ lifecycle mutation is blocked during reset backing release"
      );
    return rdma_status::success();
  endfunction

  // 功能：账本不变量破坏时置 POISONED，并返回带原诊断的 INVALID_STATE。
  // 输入/输出及副作用：message 为诊断；清空 late_final_fifo、改 engine_state；不释放 backing。
  // 失败/边界：已 POISONED 时仍清 FIFO 并返回新状态；调用方须持锁。
  protected function rdma_status poison_status(string message);
    late_final_fifo.delete();
    engine_state = RDMA_CMQ_ENGINE_POISONED;
    return invalid_state(message);
  endfunction

  // 设计说明：ring counter 失序不是普通容量不足；保持提交优先级，先 poison 并丢弃 late final。
  // 功能：按 publish_seq-retire_seq 计算 ring 占用，拒绝计数器逆序或超深度。
  // 输入/输出及副作用：used 输出差值；不变量破坏时经 poison_status 清 late_final_fifo、置 POISONED。
  // 失败/边界：publish_seq<retire_seq 时 used 为零；差值超过 CMQ_DEPTH 时 used 保留该差值，均返回
  //  INVALID_STATE。
  protected function rdma_status ring_used(output longint unsigned used);
    if (!rdma_cmq_ring_occupancy_valid(
          publish_seq, retire_seq, CMQ_DEPTH, used
        )) begin
      if (publish_seq < retire_seq)
        return poison_status("CMQ publish counter precedes retire counter");
      return poison_status("CMQ ring occupancy exceeds depth");
    end
    return rdma_status::success();
  endfunction

  // 功能：核对已解码 hardware_ecode 与 command_status 的 code/category/severity 契约。
  // 输入/输出及副作用：decoded 只读；返回校验状态，不解码 wire、不改 command_status。
  // 失败/边界：decoded/status 缺失或 category 不符时拒绝；零 ecode 须为 OK/INFO 且无硬件错误标记，
  //  非零须为非 OK、精确硬件码及 WARNING/ERROR/FATAL 之一。
  protected function rdma_status decoded_status_contract(
    rdma_cmq_decoded_cqe decoded
  );
    rdma_status command_status;

    if (decoded == null || decoded.command_status == null)
      return invalid_state("CMQ decoded completion status is missing");
    command_status = decoded.command_status;
    if (command_status.category !=
        rdma_status::category_for(command_status.code))
      return invalid_state(
        "CMQ decoded completion status category is inconsistent"
      );
    if (decoded.hardware_ecode == 0) begin
      if (!command_status.ok() || command_status.hardware_code_valid ||
          command_status.hardware_code != 0 ||
          command_status.severity != RDMA_SEVERITY_INFO)
        return invalid_state(
          "CMQ successful hardware ecode status is inconsistent"
        );
    end
    else begin
      if (command_status.ok() || !command_status.hardware_code_valid ||
          command_status.hardware_code != decoded.hardware_ecode ||
          !(command_status.severity inside {
            RDMA_SEVERITY_WARNING,
            RDMA_SEVERITY_ERROR,
            RDMA_SEVERITY_FATAL
          }))
        return invalid_state(
          "CMQ failed hardware ecode status is inconsistent"
        );
    end
    return rdma_status::success();
  endfunction

  // 功能：审计 ring/slot/entry/command/token 账本；token 覆盖 PUBLISHED 与 TIMED_OUT_QUARANTINED，
  //  command registry 只覆盖 PUBLISHED slot。
  // 输入/输出及副作用：used 输出占用数；只读 slot/entry/command/token 表，异常时 poison_status。
  // 失败/边界：counter 逆序/超深度、slot/entry 数与 used 不等、command 或 token 数不匹配时 fail closed。
  protected function rdma_status poll_ledger_status(
    output longint unsigned used
  );
    rdma_status status;
    int unsigned slot_count;
    int unsigned published_slot_count;
    int unsigned quarantined_slot_count;
    int unsigned token_count;

    used = 0;
    status = ring_used(used);
    if (!status.ok())
      return status;
    if (cq_consume_seq < retire_seq || cq_consume_seq > publish_seq)
      return poison_status("CMQ completion counters are inconsistent");
    slot_count = 0;
    published_slot_count = 0;
    quarantined_slot_count = 0;
    token_count = 0;
    foreach (slots[i]) begin
      if (slots[i] != null) begin
        slot_count++;
        if (slots[i].state == CMQ_SLOT_PUBLISHED)
          published_slot_count++;
        else if (slots[i].state inside {
                   CMQ_SLOT_TIMED_OUT_QUARANTINED,
                   CMQ_SLOT_RESET_CANCELLED
                 })
          quarantined_slot_count++;
      end
      if (token_in_use[i])
        token_count++;
    end
    if (slot_count != used || entry_registry.num() != used ||
        command_registry.num() != published_slot_count ||
        token_count != published_slot_count + quarantined_slot_count)
      return poison_status("CMQ polling ledger is inconsistent");
    return rdma_status::success();
  endfunction

  // 功能：校验 ticket 的指针与 command_id/槽位等字段可信。
  // 输入/输出及副作用：ticket 只读；返回 INVALID_ARGUMENT 或成功状态。
  // 失败/边界：句柄缺失或标识含未知位（X/Z）时拒绝。
  protected function rdma_status ticket_trust_status(
    rdma_cmq_ticket ticket
  );
    rdma_status status;

    if (ticket == null || ticket.function_h == null ||
        ticket.cmq_h == null || ticket.opcode_key == null)
      return invalid_argument("CMQ ticket trust authority is incomplete");
    if ($isunknown(ticket.command_id) ||
        $isunknown(ticket.slot_sequence) ||
        $isunknown(ticket.sq_index) ||
        $isunknown(ticket.sq_wrap) ||
        $isunknown(ticket.absolute_deadline) ||
        $isunknown(ticket.function_h.kind) ||
        $isunknown(ticket.function_h.function_uid) ||
        $isunknown(ticket.function_h.object_id) ||
        $isunknown(ticket.function_h.generation) ||
        $isunknown(ticket.cmq_h.kind) ||
        $isunknown(ticket.cmq_h.function_uid) ||
        $isunknown(ticket.cmq_h.object_id) ||
        $isunknown(ticket.cmq_h.generation) ||
        $isunknown(ticket.opcode_key.opcode))
      return invalid_argument("CMQ ticket identity contains unknown bits");
    status = ticket.validate();
    if (status == null)
      return invalid_argument("CMQ ticket validation returned null");
    return status;
  endfunction

  // 功能：比较 slot record 与其 ticket 的 sequence/index/wrap/command-token 四元组是否一致。
  // 输入/输出及副作用：record 只读；返回逐字段是否相等，不改任何状态。
  // 失败/边界：record 或 record.ticket 为空返回 0；null/unknown/geometry 等门禁由调用方保留。
  protected function bit slot_ticket_tuple_matches(
    input rdma_cmq_slot_record record
  );
    if (record == null || record.ticket == null)
      return 1'b0;
    return record.ticket.sq_index == record.sq_index &&
           record.ticket.slot_sequence == record.slot_sequence &&
           record.ticket.sq_wrap == record.sq_wrap &&
           record.ticket.command_id[4:0] == record.command_token;
  endfunction

  // 功能：生成 command 登记表键。
  // 输入/输出及副作用：ticket 只读；返回由 function uid/object/generation/command_id 拼成的键。
  // 失败/边界：调用方须先校验句柄非空。
  protected function string command_key(rdma_cmq_ticket ticket);
    return $sformatf(
      "%016h:%08h:%08h:%016h",
      ticket.function_h.function_uid,
      ticket.function_h.object_id,
      ticket.function_h.generation,
      ticket.command_id
    );
  endfunction

  // 功能：生成 ring entry 键。
  // 输入/输出及副作用：index/wrap 为位置；读 prepared_binding 的 function_uid、generation 拼键。
  // 失败/边界：调用方须保证 prepared_binding 非空。
  protected function string entry_key(int unsigned index, bit wrap);
    return $sformatf(
      "%016h:%08h:%0d:%0b",
      prepared_binding.function_uid,
      prepared_binding.generation,
      index,
      wrap
    );
  endfunction

  // 功能：把一条 CQE 读回的字节包装为 raw_cqe 硬件镜像（长度、端序、版本、Function generation）。
  // 输入/输出及副作用：data 为读回字节；raw_cqe 输出新镜像，入口先置 null。
  // 失败/边界：data 不足 CMQE_BYTES、prepared_binding 缺失或 profile 镜像格式无效时返回 INVALID_STATE。
  protected function rdma_status make_raw_cqe_image(
    byte data[],
    output rdma_hw_image raw_cqe
  );
    raw_cqe = null;
    if (data.size() != CMQE_BYTES)
      return invalid_state("CMQ host read did not return one full CQE");
    if (prepared_binding == null)
      return invalid_state("CMQ CQE Function authority is missing");
    if (!profile_image_format_valid ||
        !(profile_image_endian inside {
          RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG
        }) || profile_hardware_version == 0)
      return invalid_state(
        "CMQ profile-wide CQE format authority is missing"
      );
    raw_cqe = rdma_hw_image::type_id::create("cmq_raw_cqe");
    if (raw_cqe == null)
      return invalid_state("CMQ raw CQE construction failed");
    foreach (data[i])
      raw_cqe.bytes.push_back(data[i]);
    raw_cqe.length = CMQE_BYTES;
    raw_cqe.alignment = CMQE_BYTES;
    raw_cqe.endian = profile_image_endian;
    raw_cqe.image_kind = RDMA_IMAGE_CMQ_CQE;
    raw_cqe.hardware_version = profile_hardware_version;
    raw_cqe.function_generation = prepared_binding.generation;
    raw_cqe.write_target_kind = RDMA_HW_TARGET_NONE;
    raw_cqe.backing_target = '0;
    raw_cqe.hmc_target = '0;
    raw_cqe.bar_target = '0;
    return rdma_status::success();
  endfunction

  // 功能：为 normal/late CQE 构造 completion，复制 ticket/status/payload 并补齐 CMQ 身份。
  // 输入/输出及副作用：record/decoded 只读；raw_cqe 为读取阶段已独立化的证据，直接交给 completion，
  //  不再 clone；不写 journal、FIFO 或 slot；会触发 UVM factory 与 profile payload snapshot。
  // 失败/边界：输入缺失、factory 返回 null、snapshot 失败或 completion.validate 失败时输出 null 并拒绝。
  protected function rdma_status make_polled_completion(
    rdma_cmq_slot_record record,
    rdma_hw_image raw_cqe,
    rdma_cmq_decoded_cqe decoded,
    output rdma_cmq_completion completion
  );
    rdma_status validation_status;
    rdma_status snapshot_status;
    rdma_cmq_ticket ticket_snapshot;
    uvm_object payload_snapshot;

    completion = null;
    if (record == null || record.ticket == null ||
        record.ticket.function_h == null || record.ticket.cmq_h == null)
      return invalid_state("CMQ completion ticket authority is missing");
    if (raw_cqe == null || decoded == null ||
        decoded.command_status == null)
      return invalid_state("CMQ completion decode authority is missing");
    completion = rdma_cmq_completion::type_id::create(
      "cmq_polled_completion"
    );
    if (completion == null)
      return invalid_state("CMQ completion construction failed");
    snapshot_status = checked_completion_ticket_snapshot(
      record.ticket, ticket_snapshot
    );
    if (snapshot_status == null || !snapshot_status.ok()) begin
      completion = null;
      return (snapshot_status == null) ?
        invalid_state("CMQ completion ticket snapshot returned null") :
        snapshot_status;
    end
    completion.ticket = ticket_snapshot;
    completion.status = rdma_cmq_clone_status_value(
      decoded.command_status
    );
    completion.raw_cqe = raw_cqe;
    snapshot_status = checked_completion_payload_snapshot(
      decoded.response_payload, payload_snapshot
    );
    if (snapshot_status == null || !snapshot_status.ok()) begin
      completion = null;
      return (snapshot_status == null) ?
        invalid_state("CMQ completion payload snapshot returned null") :
        snapshot_status;
    end
    completion.decoded_response = payload_snapshot;
    if (completion.ticket == null || completion.status == null ||
        completion.raw_cqe == null) begin
      completion = null;
      return invalid_state("CMQ completion snapshot construction failed");
    end
    completion.status.source_engine = RDMA_ENGINE_CMQ;
    completion.status.function_uid =
      completion.ticket.function_h.function_uid;
    completion.status.generation =
      completion.ticket.function_h.generation;
    completion.status.resource_id = completion.ticket.cmq_h.object_id;
    completion.status.command_id = completion.ticket.command_id;
    validation_status = completion.validate();
    if (validation_status == null || !validation_status.ok()) begin
      completion = null;
      return invalid_state("CMQ completion snapshot validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：构造携带 TIMEOUT 状态码的 rdma_status。
  // 输入/输出及副作用：ticket 提供身份；message 为诊断；timeout_status 输出新状态，入口置 null。
  // 失败/边界：ticket 或其 function/cmq 句柄缺失，或状态构造失败时返回 INVALID_STATE。
  protected function rdma_status make_timeout_status(
    rdma_cmq_ticket ticket,
    string message,
    output rdma_status timeout_status
  );
    timeout_status = null;
    if (ticket == null || ticket.function_h == null || ticket.cmq_h == null)
      return invalid_state("CMQ timeout status ticket authority is missing");
    timeout_status = rdma_status::make(RDMA_SC_TIMEOUT, message);
    if (timeout_status == null)
      return invalid_state("CMQ timeout status construction failed");
    timeout_status.source_engine = RDMA_ENGINE_CMQ;
    timeout_status.function_uid = ticket.function_h.function_uid;
    timeout_status.generation = ticket.function_h.generation;
    timeout_status.resource_id = ticket.cmq_h.object_id;
    timeout_status.command_id = ticket.command_id;
    return rdma_status::success();
  endfunction

  // 功能：为超时 slot 构造 completion，status 为 TIMEOUT，ticket 为快照。
  // 输入/输出及副作用：record 只读；completion 输出新对象，入口置 null；不改 slot 与队列。
  // 失败/边界：record/ticket 缺失、构造失败、ticket 快照或 timeout status 为 null、validate 失败时拒绝。
  protected function rdma_status make_timeout_completion(
    rdma_cmq_slot_record record,
    output rdma_cmq_completion completion
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;

    completion = null;
    if (record == null || record.ticket == null)
      return invalid_state("CMQ timeout completion authority is missing");
    completion = rdma_cmq_completion::type_id::create(
      "cmq_timeout_completion"
    );
    if (completion == null)
      return invalid_state("CMQ timeout completion construction failed");
    status = checked_completion_ticket_snapshot(record.ticket,
                                                ticket_snapshot);
    if (status == null || !status.ok()) begin
      completion = null;
      return (status == null) ?
        invalid_state("CMQ timeout ticket snapshot returned null status") :
        status;
    end
    completion.ticket = ticket_snapshot;
    status = make_timeout_status(
      completion.ticket, "CMQ command deadline expired", completion.status
    );
    if (status == null || !status.ok()) begin
      completion = null;
      return (status == null) ?
        invalid_state("CMQ timeout status helper returned null") : status;
    end
    completion.raw_cqe = null;
    completion.decoded_response = null;
    status = completion.validate();
    if (status == null || !status.ok()) begin
      completion = null;
      return invalid_state("CMQ timeout completion validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：为 reset 取消的 slot 构造 RESET_CANCELLED completion。
  // 输入/输出及副作用：record 只读；completion 输出新对象，入口置 null；不改 slot 与队列。
  // 失败/边界：record、ticket 或其 function/cmq 句柄缺失，或构造失败时返回 INVALID_STATE。
  protected function rdma_status make_cancel_completion(
    rdma_cmq_slot_record record,
    output rdma_cmq_completion completion
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;

    completion = null;
    if (record == null || record.ticket == null ||
        record.ticket.function_h == null || record.ticket.cmq_h == null)
      return invalid_state("CMQ cancel completion authority is missing");
    completion = rdma_cmq_completion::type_id::create(
      "cmq_cancel_completion"
    );
    if (completion == null)
      return invalid_state("CMQ cancel completion construction failed");
    status = checked_completion_ticket_snapshot(record.ticket,
                                                ticket_snapshot);
    if (status == null || !status.ok()) begin
      completion = null;
      return (status == null) ?
        invalid_state("CMQ cancel ticket snapshot returned null") : status;
    end
    completion.ticket = ticket_snapshot;
    completion.status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED,
      "CMQ command cancelled by generation reset"
    );
    if (completion.status == null) begin
      completion = null;
      return invalid_state("CMQ cancel status construction failed");
    end
    completion.status.source_engine = RDMA_ENGINE_RESET;
    completion.status.function_uid = ticket_snapshot.function_h.function_uid;
    completion.status.generation = ticket_snapshot.function_h.generation;
    completion.status.resource_id = ticket_snapshot.cmq_h.object_id;
    completion.status.command_id = ticket_snapshot.command_id;
    completion.raw_cqe = null;
    completion.decoded_response = null;
    status = completion.validate();
    if (status == null || !status.ok()) begin
      completion = null;
      return invalid_state("CMQ cancel completion validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：在 terminal_fifo 中按 ticket 值查找 completion。
  // 输入/输出及副作用：ticket 只读；返回下标，不改 FIFO。
  // 失败/边界：ticket 为空或未命中返回 -1。
  protected function int terminal_index(rdma_cmq_ticket ticket);
    if (ticket == null)
      return -1;
    foreach (terminal_fifo[i]) begin
      if (terminal_fifo[i] != null && terminal_fifo[i].ticket != null &&
          same_ticket_value(terminal_fifo[i].ticket, ticket))
        return i;
    end
    return -1;
  endfunction

  // 功能：在 diagnostic_fifo 中按 ticket 值查找 LATE_COMPLETION 诊断。
  // 输入/输出及副作用：ticket 只读；返回下标，不改 FIFO。
  // 失败/边界：ticket 为空或未命中返回 -1。
  protected function int late_diagnostic_index(rdma_cmq_ticket ticket);
    if (ticket == null)
      return -1;
    foreach (diagnostic_fifo[i]) begin
      if (diagnostic_fifo[i] != null &&
          diagnostic_fifo[i].kind == RDMA_CMQ_DIAG_LATE_COMPLETION &&
          diagnostic_fifo[i].ticket != null &&
          same_ticket_value(diagnostic_fifo[i].ticket, ticket))
        return i;
    end
    return -1;
  endfunction

  // 功能：在 late_final_fifo 中按 ticket 值查找晚到 final。
  // 输入/输出及副作用：ticket 只读；返回下标，不改 FIFO。
  // 失败/边界：ticket 为空或未命中返回 -1。
  protected function int late_final_index(rdma_cmq_ticket ticket);
    if (ticket == null)
      return -1;
    foreach (late_final_fifo[i]) begin
      if (late_final_fifo[i] != null &&
          late_final_fifo[i].ticket != null &&
          same_ticket_value(late_final_fifo[i].ticket, ticket))
        return i;
    end
    return -1;
  endfunction

  // 功能：判断 ticket 是否属于当前 engine 的 Function 与 CMQ（经 same_handle 判定 incarnation）。
  // 输入/输出及副作用：ticket 只读；返回 bit，不改状态。
  // 失败/边界：ticket/binding/snapshot/CMQ handle 缺失，或身份、incarnation 不一致时返回 0。
  protected function bit ticket_has_engine_authority(
    rdma_cmq_ticket ticket
  );
    if (ticket == null || ticket.function_h == null || ticket.cmq_h == null ||
        prepared_binding == null || cmq_snapshot == null ||
        cmq_snapshot.handle == null)
      return 1'b0;
    if (ticket.function_h.kind != RDMA_RESOURCE_FUNCTION ||
        ticket.function_h.function_uid != prepared_binding.function_uid ||
        ticket.function_h.object_id != prepared_binding.global_function_id ||
        ticket.function_h.generation != prepared_binding.generation ||
        !same_handle(ticket.cmq_h, cmq_snapshot.handle))
      return 1'b0;
    if (terminal_index(ticket) >= 0 || late_diagnostic_index(ticket) >= 0 ||
        late_final_index(ticket) >= 0 || ticket_is_outstanding(ticket))
      return 1'b1;
    foreach (slots[i]) begin
      if (slots[i] != null && slots[i].ticket != null &&
          same_ticket_value(slots[i].ticket, ticket))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：判断 ticket 是否仍登记在 command_registry 中。
  // 输入/输出及副作用：ticket 只读；以 command_key 查表并比较 ticket 值，不改状态。
  // 失败/边界：ticket 为空或未登记返回 0。
  protected function bit ticket_is_outstanding(rdma_cmq_ticket ticket);
    string software_key;

    if (ticket == null)
      return 1'b0;
    software_key = command_key(ticket);
    return command_registry.exists(software_key) &&
           command_registry[software_key] != null &&
           command_registry[software_key].ticket != null &&
           same_ticket_value(command_registry[software_key].ticket, ticket);
  endfunction

  // 设计说明：reconcile/wait 的恢复 authority 来自 retained journal 而非 command/entry registry；
  //  集中到一个锁内入口，避免旧 incarnation 在 reprepare 后被误判未知。
  // 功能：按 journal_batch_by_ticket 定位唯一 retained batch/item，并核对 ticket 全部公开字段。
  // 输入/输出及副作用：ticket 只读；batch_record/journal_item 为非拥有输出，journal_item_index 输出
  //  下标；只读 journal/index/profile，无 I/O 与生命周期迁移。
  // 失败/边界：ticket 为空/shape 非法、index 孤立、目标 row 损坏、无匹配或多重匹配时返回
  //  INVALID_ARGUMENT/INVALID_STATE，输出保持 null/0。
  protected function rdma_status locate_journal_item_by_ticket_locked(
    input rdma_cmq_ticket ticket,
    output rdma_cmq_batch_submission_record batch_record,
    output rdma_cmq_batch_submission_item_record journal_item,
    output int unsigned journal_item_index
  );
    string ticket_key;
    string batch_key;
    rdma_status status;
    int unsigned match_count;

    batch_record = null;
    journal_item = null;
    journal_item_index = 0;
    if (!rdma_cmq_ticket_shape_valid(ticket))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal ticket locator received an invalid ticket"
      );
    ticket_key = command_key(ticket);
    if (ticket_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal ticket key is empty"
      );
    status = journal_ticket_index_targets_locked();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket locator index check returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    if (!journal_batch_by_ticket.exists(ticket_key))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal ticket is not installed"
      );
    batch_key = journal_batch_by_ticket[ticket_key];
    if (batch_key.len() == 0 || !submission_journal.exists(batch_key))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket index target is missing"
      );
    status = submission_journal_invariant_locked(batch_key);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket locator invariant returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    batch_record = submission_journal[batch_key];
    if (batch_record == null || batch_record.batch_key != batch_key)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket locator batch row is inconsistent"
      );
    if (!rdma_cmq_find_unique_ticket_item(
          batch_record, ticket, journal_item, journal_item_index, match_count
        )) begin
      batch_record = null;
      journal_item = null;
      journal_item_index = 0;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket locator batch or ticket is incomplete"
      );
    end
    if (match_count == 0) begin
      batch_record = null;
      journal_item = null;
      journal_item_index = 0;
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal ticket key matched but full ticket value differs"
      );
    end
    if (match_count != 1) begin
      batch_record = null;
      journal_item = null;
      journal_item_index = 0;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket resolves to multiple retained items"
      );
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：持 engine_lock 时核对 observed result 与 retained journal 行的身份及 state/phase 组合，
  //  作为 execute 的唯一决策门禁。
  // 输入/输出及副作用：submitted、batch_record、journal_item 只读；返回非空 status，不改 journal。
  // 失败/边界：ticket、batch/attempt、Function/CMQ identity 或 reset mapping 不一致，或 pending 行
  //  incarnation/lifecycle 矛盾时返回 INVALID_STATE；caller 的旧 status/effect/phase 只查 shape，
  //  当前状态以 journal 行为准。
  protected function rdma_status validate_observed_item_locked(
    input rdma_cmq_execution_result submitted,
    input rdma_cmq_batch_submission_record batch_record,
    input rdma_cmq_batch_submission_item_record journal_item
  );
    rdma_cmq_command_identity expected_command_identity;
    rdma_status dma_status;
    string identity_failure;

    if (submitted == null || batch_record == null || journal_item == null ||
        submitted.ticket == null || journal_item.ticket == null ||
        batch_record.function_identity == null || batch_record.cmq_h == null ||
        journal_item.command == null || journal_item.recovery_owner == null ||
        journal_item.dma_context == null || journal_item.status == null ||
        submitted.batch_key != batch_record.batch_key ||
        submitted.batch_id != batch_record.batch_id ||
        submitted.attempt_id != batch_record.attempt_id ||
        batch_record.engine_instance_id != engine_instance_id ||
        !rdma_cmq_same_ticket_detached_value(submitted.ticket, journal_item.ticket) ||
        !same_handle_value(batch_record.cmq_h, journal_item.ticket.cmq_h) ||
        (journal_item.completion != null &&
         (journal_item.completion.ticket == null ||
          journal_item.completion.status == null ||
          !rdma_cmq_ticket_shape_valid(journal_item.completion.ticket) ||
          !rdma_cmq_status_shape_valid(journal_item.completion.status) ||
          !rdma_cmq_same_ticket_detached_value(journal_item.completion.ticket,
                                      journal_item.ticket) ||
          !same_status_value(journal_item.completion.status,
                             journal_item.status) ||
          journal_item.completion.ticket != journal_item.ticket ||
          journal_item.completion.status != journal_item.status)))
      return journal_status(
        RDMA_SC_INVALID_STATE, "CMQ observed journal identity mismatch"
      );

    // submitted 是 detached 快照，lifecycle/status/effect 可在取锁前过时，但身份图、枚举 shape 与
    // completion 内部 alias 不得损坏。
    if (!rdma_cmq_ticket_shape_valid(submitted.ticket) ||
        !rdma_cmq_status_shape_valid(submitted.status) ||
        !rdma_cmq_status_shape_valid(submitted.observation_status) ||
        !rdma_cmq_submission_effect_valid(submitted.submission_effect) ||
        !rdma_cmq_submission_effect_valid(submitted.attempt_effect) ||
        !rdma_cmq_completion_phase_valid(submitted.completion_phase) ||
        !rdma_cmq_frozen_owner_shape_valid(submitted.recovery_owner) ||
        submitted.dma_context == null || submitted.dma_context.function_h == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed submitted detached graph is malformed"
      );
    dma_status = submitted.dma_context.validate();
    if (dma_status == null || !dma_status.ok() ||
        !same_handle_value(submitted.dma_context.function_h,
                           submitted.ticket.function_h))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed submitted DMA identity is malformed"
      );

    // delegated result 可带旧的 state/effect 投影，但组合须自洽；当前状态以下方 retained row 为准。
    if (submitted.submission_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        submitted.attempt_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED) begin
      if (submitted.submission_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
          submitted.attempt_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
          submitted.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
          submitted.completion != null || submitted.batch_id == 0 ||
          submitted.attempt_id == 0)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ observed submitted PRE effect contradicts retained identity"
        );
    end
    if (submitted.completion_phase == RDMA_CMQ_COMPLETION_UNOBSERVED &&
        (submitted.submission_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED ||
         submitted.attempt_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED ||
         submitted.completion != null ||
         submitted.recovery_required != 1'b1))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed submitted UNOBSERVED envelope is malformed"
      );
    if (submitted.completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
        (submitted.completion != null ||
         !(submitted.submission_effect inside {
           RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
           RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
         }) || !(submitted.attempt_effect inside {
           RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
           RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
         })))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed submitted pending envelope is malformed"
      );
    if (submitted.completion != null &&
        (submitted.completion.ticket == null || submitted.completion.status == null ||
         !rdma_cmq_ticket_shape_valid(submitted.completion.ticket) ||
         !rdma_cmq_status_shape_valid(submitted.completion.status) ||
         !rdma_cmq_same_ticket_detached_value(submitted.completion.ticket,
                                     submitted.ticket) ||
         !same_status_value(submitted.completion.status, submitted.status) ||
         submitted.completion.ticket != submitted.ticket ||
         submitted.completion.status != submitted.status))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed submitted completion alias is malformed"
      );

    if (!rdma_cmq_identity_shape_valid(batch_record.function_identity) ||
        !rdma_cmq_status_shape_valid(journal_item.status) ||
        !rdma_cmq_frozen_owner_shape_valid(journal_item.recovery_owner) ||
        journal_item.ticket.function_h == null ||
        !same_handle_value(journal_item.ticket.function_h,
                           submitted.ticket.function_h) ||
        journal_item.ticket.function_h.function_uid !=
          batch_record.function_identity.function_uid ||
        journal_item.ticket.function_h.object_id !=
          batch_record.function_identity.global_function_id ||
        journal_item.ticket.function_h.generation !=
          batch_record.function_identity.generation ||
        journal_item.dma_context.reset_epoch !=
          batch_record.function_identity.reset_epoch ||
        journal_item.dma_context.function_h == null ||
        journal_item.dma_context.function_h.function_uid !=
          batch_record.function_identity.function_uid ||
        journal_item.dma_context.function_h.object_id !=
          batch_record.function_identity.global_function_id ||
        journal_item.dma_context.function_h.generation !=
          batch_record.function_identity.generation ||
        journal_item.dma_context.reset_epoch !=
          batch_record.function_identity.reset_epoch ||
        !rdma_cmq_same_journal_dma_context_detached_value(
          submitted.dma_context, journal_item.dma_context
        ) ||
        !rdma_cmq_same_journal_owner_detached_value(
          submitted.recovery_owner, journal_item.recovery_owner
        ))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed Function or recovery authority mismatch"
      );

    if (batch_record.cmq_h.kind != RDMA_RESOURCE_CMQ ||
        batch_record.cmq_h.function_uid !=
          batch_record.function_identity.function_uid ||
        batch_record.cmq_h.generation !=
          batch_record.function_identity.generation ||
        !same_handle_value(batch_record.cmq_h, submitted.ticket.cmq_h) ||
        journal_item.dependency_mapping == null ||
        journal_item.dependency_mapping.function_h == null ||
        !journal_item.dependency_mapping.epoch_valid ||
        journal_item.dependency_mapping.reset_epoch !=
          batch_record.function_identity.reset_epoch)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed CMQ or reset mapping authority mismatch"
      );

    expected_command_identity = new("cmq_observed_expected_command_identity");
    if (!expected_command_identity.capture_from(
          journal_item.command, identity_failure
        ) || submitted.command_identity == null ||
        !rdma_cmq_same_journal_command_identity_value(
          submitted.command_identity, expected_command_identity
        ))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        (identity_failure.len() == 0) ?
          "CMQ observed command identity mismatch" :
          {"CMQ observed command identity is invalid: ", identity_failure}
      );

    if (journal_item.dependency_mapping == null ||
        journal_item.dependency_mapping.reset_epoch !=
          batch_record.function_identity.reset_epoch)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed DMA mapping reset evidence is stale"
      );
    if (!rdma_cmq_submission_state_valid(journal_item.state) ||
        !rdma_cmq_completion_phase_valid(journal_item.completion_phase) ||
        !rdma_cmq_submission_effect_valid(journal_item.submission_effect) ||
        !rdma_cmq_submission_effect_valid(journal_item.attempt_effect))
      return journal_status(
        RDMA_SC_INVALID_STATE, "CMQ observed lifecycle evidence is malformed"
      );
    if (journal_item.state inside {
          RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
          RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
        } && batch_record.engine_incarnation != engine_incarnation)
      return journal_status(
        RDMA_SC_INVALID_STATE, "CMQ observed pending incarnation mismatch"
      );
    if (journal_item.state == RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED)
      if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
          journal_item.completion != null)
        return journal_status(
          RDMA_SC_INVALID_STATE, "CMQ observed host-visible lifecycle mismatch"
        );
    if (journal_item.state == RDMA_CMQ_SUBMISSION_COMPLETED)
      if (!rdma_cmq_terminal_state_phase_valid(
            journal_item.state, journal_item.completion_phase
          ) ||
          journal_item.completion == null)
        return journal_status(
          RDMA_SC_INVALID_STATE, "CMQ observed completed lifecycle mismatch"
        );
    if (journal_item.state == RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED)
      if (!rdma_cmq_terminal_state_phase_valid(
            journal_item.state, journal_item.completion_phase
          ) ||
          journal_item.completion == null)
        return journal_status(
          RDMA_SC_INVALID_STATE, "CMQ observed timeout lifecycle mismatch"
        );
    if (journal_item.state == RDMA_CMQ_SUBMISSION_LATE_COMPLETED)
      if (!rdma_cmq_terminal_state_phase_valid(
            journal_item.state, journal_item.completion_phase
          ) ||
          journal_item.completion == null)
        return journal_status(
          RDMA_SC_INVALID_STATE, "CMQ observed late lifecycle mismatch"
        );
    if (journal_item.state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED)
      if (!rdma_cmq_terminal_state_phase_valid(
            journal_item.state, journal_item.completion_phase
          ) ||
          journal_item.completion == null)
        return journal_status(
          RDMA_SC_INVALID_STATE, "CMQ observed reset lifecycle mismatch"
        );
    if (journal_item.state inside {
          RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
          RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
        } && (journal_item.completion_phase != RDMA_CMQ_COMPLETION_PENDING ||
              journal_item.completion != null))
      return journal_status(
        RDMA_SC_INVALID_STATE, "CMQ observed pending lifecycle mismatch"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：从 retained item 的 completion 生成全新 detached snapshot，供 FIFO 已消费或 reprepare 后的
  //  wait/reconcile 读取。
  // 输入/输出及副作用：batch_record/journal_item 为锁内只读输入，completion 为 caller-owned 输出；
  //  使用该 batch 保存的 exact profile，不借用当前 profile，也不转移 journal completion 句柄。
  // 失败/边界：batch/item/completion/profile 缺失、phase 不含 completion、snapshot 或 alias 校验失败
  //  时返回非 OK 且输出 null。
  protected function rdma_status snapshot_retained_completion_locked(
    input rdma_cmq_batch_submission_record batch_record,
    input rdma_cmq_batch_submission_item_record journal_item,
    output rdma_cmq_completion completion
  );
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_cmq_hw_profile retained_profile;
    rdma_status status;

    completion = null;
    if (batch_record == null || journal_item == null ||
        journal_item.completion == null || journal_item.completion.ticket == null ||
        journal_item.completion.status == null ||
        !journal_profile_by_batch.exists(batch_record.batch_key) ||
        journal_profile_by_batch[batch_record.batch_key] == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained completion authority is incomplete"
      );
    retained_profile = journal_profile_by_batch[batch_record.batch_key];
    snapshot_context = new();
    status = snapshot_completion_with_profile_locked(
      journal_item.completion, snapshot_context, retained_profile,
      completion
    );
    if (status == null || !status.ok() || completion == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained completion snapshot returned null status"
      ) : journal_status(status.code, status.message);
    if (completion.ticket == null || completion.status == null ||
        !rdma_cmq_same_ticket_detached_value(completion.ticket, journal_item.ticket)) begin
      completion = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained completion snapshot ticket is inconsistent"
      );
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：把 retained item 的 operation status 复制为 caller-owned 独立 status。
  // 输入/输出及副作用：journal_item 为锁内只读输入，status 为新建输出；不碰 completion/FIFO/runtime。
  // 失败/边界：item 或 status shape 非法时返回 INVALID_STATE 且输出 null；结果与原值相等但不共享对象。
  protected function rdma_status snapshot_retained_operation_status_locked(
    input rdma_cmq_batch_submission_item_record journal_item,
    output rdma_status status
  );
    status = null;
    if (journal_item == null ||
        !rdma_cmq_status_shape_valid(journal_item.status))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained operation status is null or malformed"
      );
    status = copy_submit_status_direct(
      journal_item.status, "cmq_reconcile_operation_status"
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained operation status snapshot returned null"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：为晚到 CQE 构造 LATE_COMPLETION 诊断，status 为 TIMEOUT，ticket 为快照。
  // 输入/输出及副作用：record、raw_cqe 只读；diagnostic 输出新对象，入口置 null；不入 FIFO。
  // 失败/边界：record/ticket/raw_cqe 缺失、构造或 ticket 快照失败、status 构造或 validate 失败时拒绝。
  protected function rdma_status make_late_diagnostic(
    rdma_cmq_slot_record record,
    rdma_hw_image raw_cqe,
    output rdma_cmq_diagnostic diagnostic
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;

    diagnostic = null;
    if (record == null || record.ticket == null || raw_cqe == null)
      return invalid_state("CMQ late diagnostic authority is missing");
    diagnostic = rdma_cmq_diagnostic::type_id::create(
      "cmq_late_completion_diagnostic"
    );
    if (diagnostic == null)
      return invalid_state("CMQ late diagnostic construction failed");
    status = checked_completion_ticket_snapshot(record.ticket,
                                                ticket_snapshot);
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return (status == null) ?
        invalid_state("CMQ late diagnostic ticket snapshot returned null") :
        status;
    end
    diagnostic.kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    diagnostic.ticket = ticket_snapshot;
    status = make_timeout_status(
      diagnostic.ticket, "CMQ completion arrived after timeout",
      diagnostic.status
    );
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return (status == null) ?
        invalid_state("CMQ late diagnostic status helper returned null") :
        status;
    end
    diagnostic.raw_cqe = raw_cqe;
    status = diagnostic.validate();
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return invalid_state("CMQ late diagnostic validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：构造携带 kind、ticket 快照、failure 和 raw_cqe 的诊断。
  // 输入/输出及副作用：kind/trusted_ticket/failure/raw_cqe 输入；diagnostic 输出新对象，与输入隔离。
  // 失败/边界：authority 缺失或 trusted_ticket 不完整等构造失败时返回 INVALID_STATE。
  protected function rdma_status make_diagnostic(
    rdma_cmq_diagnostic_kind_e kind,
    rdma_cmq_ticket trusted_ticket,
    rdma_status failure,
    rdma_hw_image raw_cqe,
    output rdma_cmq_diagnostic diagnostic
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;
    rdma_function_handle function_snapshot;
    rdma_handle cmq_snapshot_value;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_status failure_snapshot;
    rdma_hw_image raw_snapshot;

    diagnostic = null;
    if (failure == null || raw_cqe == null)
      return invalid_state("CMQ poison diagnostic authority is missing");
    ticket_snapshot = null;
    if (trusted_ticket != null) begin
      if (trusted_ticket.function_h == null ||
          trusted_ticket.cmq_h == null ||
          trusted_ticket.opcode_key == null)
        return invalid_state("CMQ trusted poison ticket is incomplete");
      function_snapshot = new("cmq_poison_ticket_function");
      function_snapshot.kind = trusted_ticket.function_h.kind;
      function_snapshot.function_uid =
        trusted_ticket.function_h.function_uid;
      function_snapshot.object_id = trusted_ticket.function_h.object_id;
      function_snapshot.generation = trusted_ticket.function_h.generation;
      cmq_snapshot_value = new("cmq_poison_ticket_cmq");
      cmq_snapshot_value.kind = trusted_ticket.cmq_h.kind;
      cmq_snapshot_value.function_uid = trusted_ticket.cmq_h.function_uid;
      cmq_snapshot_value.object_id = trusted_ticket.cmq_h.object_id;
      cmq_snapshot_value.generation = trusted_ticket.cmq_h.generation;
      opcode_snapshot = new("cmq_poison_ticket_opcode");
      opcode_snapshot.profile_name = trusted_ticket.opcode_key.profile_name;
      opcode_snapshot.opcode = trusted_ticket.opcode_key.opcode;
      opcode_snapshot.variant = trusted_ticket.opcode_key.variant;
      ticket_snapshot = new("cmq_poison_ticket");
      ticket_snapshot.command_id = trusted_ticket.command_id;
      ticket_snapshot.function_h = function_snapshot;
      ticket_snapshot.cmq_h = cmq_snapshot_value;
      ticket_snapshot.slot_sequence = trusted_ticket.slot_sequence;
      ticket_snapshot.sq_index = trusted_ticket.sq_index;
      ticket_snapshot.sq_wrap = trusted_ticket.sq_wrap;
      ticket_snapshot.opcode_key = opcode_snapshot;
      ticket_snapshot.absolute_deadline =
        trusted_ticket.absolute_deadline;
      status = ticket_snapshot.validate();
      if (status == null || !status.ok()) begin
        ticket_snapshot = null;
        return (status == null) ?
          invalid_state("CMQ poison ticket validation returned null") :
          status;
      end
    end
    failure_snapshot = new("cmq_poison_status");
    failure_snapshot.category = failure.category;
    failure_snapshot.code = failure.code;
    failure_snapshot.hardware_code = failure.hardware_code;
    failure_snapshot.hardware_code_valid = failure.hardware_code_valid;
    failure_snapshot.source_engine = failure.source_engine;
    failure_snapshot.function_uid = failure.function_uid;
    failure_snapshot.generation = failure.generation;
    failure_snapshot.resource_id = failure.resource_id;
    failure_snapshot.command_id = failure.command_id;
    failure_snapshot.wr_id = failure.wr_id;
    failure_snapshot.severity = failure.severity;
    failure_snapshot.retryable = failure.retryable;
    failure_snapshot.message = failure.message;
    raw_snapshot = new("cmq_poison_raw_cqe");
    raw_snapshot.bytes = raw_cqe.bytes;
    raw_snapshot.length = raw_cqe.length;
    raw_snapshot.alignment = raw_cqe.alignment;
    raw_snapshot.endian = raw_cqe.endian;
    raw_snapshot.image_kind = raw_cqe.image_kind;
    raw_snapshot.hardware_version = raw_cqe.hardware_version;
    raw_snapshot.function_generation = raw_cqe.function_generation;
    raw_snapshot.write_target_kind = raw_cqe.write_target_kind;
    raw_snapshot.backing_target = raw_cqe.backing_target;
    raw_snapshot.hmc_target = raw_cqe.hmc_target;
    raw_snapshot.bar_target = raw_cqe.bar_target;
    raw_snapshot.field_summary = raw_cqe.field_summary;
    diagnostic = new("cmq_poison_diagnostic");
    diagnostic.kind = kind;
    diagnostic.ticket = ticket_snapshot;
    diagnostic.status = failure_snapshot;
    diagnostic.raw_cqe = raw_snapshot;
    status = diagnostic.validate();
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return invalid_state("CMQ poison diagnostic validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：克隆诊断对象，得到与源隔离的快照。
  // 输入/输出及副作用：source 只读；snapshot 输出，经 make_diagnostic 重建。
  // 失败/边界：source 为 null 时返回 INVALID_STATE。
  protected function rdma_status clone_diagnostic(
    rdma_cmq_diagnostic source,
    output rdma_cmq_diagnostic snapshot
  );
    snapshot = null;
    if (source == null)
      return invalid_state("CMQ poison diagnostic source is null");
    return make_diagnostic(
      source.kind, source.ticket, source.status, source.raw_cqe, snapshot
    );
  endfunction

  // 功能：丢弃 late-final FIFO，构造 detached 诊断并在候选与 last_poison 快照都成功时发布，
  //  最后置 POISONED。
  // 输入/输出及副作用：kind/message/raw_cqe/可选 trusted_ticket 为输入；清空 late_final_fifo，
  //  更新 last_poison、diagnostic_fifo、engine_state；不取得 ticket/raw_cqe 所有权。
  // 失败/边界：主诊断、无 ticket 回退或 last_poison clone 失败时不装半成品、保留旧诊断，仍置
  //  POISONED 并返回 INVALID_STATE；全部成功返回原 CODEC_ERROR failure；late FIFO 清空不可回滚。
  protected function rdma_status poison(
    rdma_cmq_diagnostic_kind_e kind,
    string message,
    rdma_hw_image raw_cqe,
    rdma_cmq_ticket trusted_ticket = null
  );
    rdma_status status;
    rdma_status failure;
    rdma_cmq_diagnostic diagnostic;
    rdma_cmq_diagnostic poison_snapshot;

    late_final_fifo.delete();
    failure = rdma_status::make(RDMA_SC_CODEC_ERROR, message);
    failure.source_engine = RDMA_ENGINE_CMQ;
    if (prepared_binding != null) begin
      failure.function_uid = prepared_binding.function_uid;
      failure.generation = prepared_binding.generation;
    end
    if (cmq_snapshot != null && cmq_snapshot.handle != null)
      failure.resource_id = cmq_snapshot.handle.object_id;
    if (trusted_ticket != null)
      failure.command_id = trusted_ticket.command_id;

    // 先 stage 两份自有对象再发布：FIFO 项在 poll() 后归 caller，last_poison 归 engine，二者不得共享
    // 对象；staging 失败仍 poison，但保留旧诊断。
    status = make_diagnostic(
      kind, trusted_ticket, failure, raw_cqe, diagnostic
    );
    if (status == null || !status.ok() || diagnostic == null) begin
      // trusted ticket 自身不一致时只保留原始证据、不声称关联；回退诊断成功则完整 detached，
      // 否则不发布半成品，engine 保持 POISONED。
      failure.command_id = 0;
      status = make_diagnostic(
        RDMA_CMQ_DIAG_POISON, null, failure, raw_cqe, diagnostic
      );
      if (status == null || !status.ok() || diagnostic == null) begin
        engine_state = RDMA_CMQ_ENGINE_POISONED;
        return (status == null) ?
          invalid_state("CMQ poison diagnostic staging returned null") :
          status;
      end
    end
    status = clone_diagnostic(diagnostic, poison_snapshot);
    if (status == null || !status.ok() || poison_snapshot == null) begin
      engine_state = RDMA_CMQ_ENGINE_POISONED;
      return (status == null) ?
        invalid_state("CMQ last-poison staging returned null") : status;
    end
    last_poison = poison_snapshot;
    diagnostic_fifo.push_back(diagnostic);
    engine_state = RDMA_CMQ_ENGINE_POISONED;
    return failure;
  endfunction

  // 设计说明：expiry 前半段只构造 detached 图，避免后续 slot 的 clone/reducer 失败留下前面 slot 的
  //  部分可见状态；提交由 expire_locked 在全部 staging 成功后统一执行。
  // 功能：审计 ledger，按 slot 顺序收集已过期 PUBLISHED row 的 timeout completion、journal transition
  //  与 command key，形成候选 batch。
  // 输入/输出及副作用：stage 为调用期输出；只读 slot/registry/token/journal，不写共享状态，不取放锁。
  // 失败/边界：ledger、locator、deadline、completion 或 journal staging 任一步失败即整体失败；
  //  未过期 row 跳过，X/Z deadline 拒绝，失败时 stage 仅为不可见局部候选。
  protected function automatic rdma_status
  stage_expiry_candidates_locked(
    output rdma_cmq_terminal_transition_candidate_stage_t stage
  );
    rdma_status status;
    longint unsigned ledger_used;

    stage.staged_records.delete();
    stage.staged_completions.delete();
    stage.staged_batches.delete();
    stage.staged_items.delete();
    stage.staged_journal_completions.delete();
    stage.staged_batch_states.delete();
    stage.staged_recovery_required.delete();
    stage.staged_command_keys.delete();

    status = poll_ledger_status(ledger_used);
    if (status == null || !status.ok())
      return (status == null) ? invalid_state(
        "CMQ expiry ledger audit returned null status"
      ) : status;
    foreach (slots[i]) begin
      rdma_cmq_slot_record record;
      rdma_cmq_completion timeout_completion;
      rdma_cmq_batch_submission_record journal_batch;
      rdma_cmq_batch_submission_item_record journal_item;
      rdma_cmq_completion journal_completion;
      rdma_cmq_submission_state_e reduced_batch_state;
      bit recovery_required;
      string software_key;
      string hardware_key;
      int unsigned token_index;

      record = slots[i];
      if (record == null || record.state != CMQ_SLOT_PUBLISHED)
        continue;
      if (record.ticket == null || record.ticket.function_h == null ||
          record.ticket.cmq_h == null || record.ticket.opcode_key == null ||
          record.expected == null ||
          $isunknown(record.ticket.absolute_deadline))
        return invalid_state("CMQ expiry slot authority is incomplete");
      if (record.ticket.absolute_deadline > $time)
        continue;
      hardware_key = entry_key(record.sq_index, record.sq_wrap);
      software_key = command_key(record.ticket);
      token_index = record.command_token;
      if (record.sq_index != i || record.ticket.sq_index != i ||
          record.ticket.slot_sequence != record.slot_sequence ||
          record.ticket.sq_wrap != record.sq_wrap ||
          record.ticket.command_id[4:0] != record.command_token ||
          !entry_registry.exists(hardware_key) ||
          entry_registry[hardware_key] != record ||
          !command_registry.exists(software_key) ||
          command_registry[software_key] != record ||
          token_index >= CMQ_DEPTH || !token_in_use[token_index])
        return invalid_state("CMQ expiry slot ledger is inconsistent");
      status = make_timeout_completion(record, timeout_completion);
      if (status == null || !status.ok() || timeout_completion == null)
        return (status == null) ? invalid_state(
          "CMQ timeout completion helper returned null status"
        ) : status;
      status = stage_runtime_journal_transition_locked(
        record, timeout_completion,
        RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
        RDMA_CMQ_COMPLETION_TIMEOUT,
        journal_batch, journal_item, journal_completion,
        recovery_required, reduced_batch_state
      );
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ timeout journal staging returned null status"
        ) : status;
      stage.staged_records.push_back(record);
      stage.staged_completions.push_back(timeout_completion);
      stage.staged_batches.push_back(journal_batch);
      stage.staged_items.push_back(journal_item);
      stage.staged_journal_completions.push_back(journal_completion);
      stage.staged_batch_states.push_back(reduced_batch_state);
      stage.staged_recovery_required.push_back(recovery_required);
      stage.staged_command_keys.push_back(software_key);
    end
    return rdma_status::success();
  endfunction

  // 功能：把已过期 PUBLISHED slot 转为 timeout（带 TIMED_OUT_QUARANTINED journal 迁移）。
  // 输入/输出及副作用：无参数；先 staging 再提交 journal、terminal_fifo，并删除 command registry 项。
  // 失败/边界：slot authority、ledger 或候选 staging 不完整时返回错误，不提交部分状态。
  protected function rdma_status expire_locked();
    rdma_status status;
    rdma_cmq_terminal_transition_candidate_stage_t stage;

    status = stage_expiry_candidates_locked(stage);
    if (status == null || !status.ok())
      return (status == null) ? invalid_state(
        "CMQ expiry candidate staging returned null status"
      ) : status;
    for (int unsigned i = 0; i < stage.staged_records.size(); i++) begin
      // // journal completion 是恢复 authority，须先于仅管交付顺序的 FIFO 发布。
      commit_runtime_journal_transition_locked(
        stage.staged_batches[i], stage.staged_items[i],
        stage.staged_journal_completions[i],
        RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
        RDMA_CMQ_COMPLETION_TIMEOUT,
        stage.staged_recovery_required[i], stage.staged_batch_states[i]
      );
      terminal_fifo.push_back(stage.staged_completions[i]);
      command_registry.delete(stage.staged_command_keys[i]);
      stage.staged_records[i].state = CMQ_SLOT_TIMED_OUT_QUARANTINED;
    end
    return rdma_status::success();
  endfunction

  // 功能：strict cancellation 前逐 slot 审计 generation、entry、command、token 的 exact membership；
  //  PUBLISHED 与 timeout quarantine 都保留各自 token incarnation，仅 PUBLISHED 留在 command registry。
  // 输入/输出及副作用：generation 为待取消的 Function generation；只读账本，损坏时 poison。
  // 失败/边界：粗审计失败、ticket/locator 不可信、slot/entry/key 不一致、command 缺失或残留、
  //  token 不一致或总数不等时返回 INVALID_STATE 并 poison。
  protected function rdma_status strict_cancel_ledger_status(
    int unsigned generation
  );
    rdma_status status;
    longint unsigned ledger_used;
    int unsigned published_slot_count;
    int unsigned quarantined_slot_count;
    int unsigned token_count;

    status = poll_ledger_status(ledger_used);
    if (status == null || !status.ok())
      return (status == null) ?
        poison_status("CMQ cancel ledger audit returned null status") :
        status;
    published_slot_count = 0;
    quarantined_slot_count = 0;
    token_count = 0;
    foreach (slots[i]) begin
      rdma_cmq_slot_record record;
      string hardware_key;
      string software_key;

      if (token_in_use[i])
        token_count++;
      record = slots[i];
      if (record == null)
        continue;
      if ($isunknown(record.slot_sequence) ||
          $isunknown(record.sq_index) ||
          $isunknown(record.sq_wrap) ||
          $isunknown(record.state) ||
          $isunknown(record.command_token))
        return poison_status(
          "CMQ cancel slot identity contains unknown bits"
        );
      status = ticket_trust_status(record.ticket);
      if (status == null || !status.ok())
        return poison_status("CMQ cancel ticket authority is untrusted");
      if (record.expected == null ||
          !(record.state inside {
            CMQ_SLOT_PUBLISHED,
            CMQ_SLOT_COMPLETED,
            CMQ_SLOT_TIMED_OUT_QUARANTINED,
            CMQ_SLOT_LATE_COMPLETED,
            CMQ_SLOT_RESET_CANCELLED
          }) ||
          !rdma_cmq_slot_ring_geometry_matches(
            record.slot_sequence, record.sq_index, record.sq_wrap, i, CMQ_DEPTH
          ) ||
          !slot_ticket_tuple_matches(record) ||
          record.batch_key.len() == 0 ||
          !submission_journal.exists(record.batch_key) ||
          record.journal_item_index >=
            submission_journal[record.batch_key].items.size() ||
          record.ticket.function_h.generation != generation ||
          prepared_binding == null ||
          !prepared_binding.accepts(record.ticket.function_h) ||
          cmq_snapshot == null || cmq_snapshot.handle == null ||
          !same_handle(record.ticket.cmq_h, cmq_snapshot.handle))
        return poison_status("CMQ cancel slot authority is inconsistent");
      hardware_key = entry_key(record.sq_index, record.sq_wrap);
      if (!entry_registry.exists(hardware_key) ||
          entry_registry[hardware_key] != record)
        return poison_status("CMQ cancel entry registry is inconsistent");
      software_key = command_key(record.ticket);
      if (record.state == CMQ_SLOT_PUBLISHED) begin
        published_slot_count++;
        if (!command_registry.exists(software_key) ||
            command_registry[software_key] != record ||
            record.command_token >= CMQ_DEPTH ||
            !token_in_use[record.command_token] ||
            token_incarnation[record.command_token] !=
              record.ticket.command_id[63:5])
          return poison_status(
            "CMQ cancel published command ledger is inconsistent"
          );
      end
      else begin
        if (command_registry.exists(software_key))
          return poison_status(
            "CMQ cancel terminal command remains in the registry"
          );
        if (record.state inside {
              CMQ_SLOT_TIMED_OUT_QUARANTINED,
              CMQ_SLOT_RESET_CANCELLED
            }) begin
          quarantined_slot_count++;
          if (record.command_token >= CMQ_DEPTH ||
              !token_in_use[record.command_token] ||
              token_incarnation[record.command_token] !=
                record.ticket.command_id[63:5])
            return poison_status(
              "CMQ cancel quarantined token ledger is inconsistent"
            );
        end
      end
    end
    if (published_slot_count != command_registry.num() ||
        published_slot_count + quarantined_slot_count != token_count)
      return poison_status(
        "CMQ cancel reserved command membership is inconsistent"
      );
    return rdma_status::success();
  endfunction

  // 功能：为严格 generation cancellation 预建所有 PUBLISHED slot 的取消 completion 与 journal
  //  transition，按 slot 顺序写入 stage。
  // 输入/输出及副作用：generation 为已审计的 generation；stage 为输出；只读 slots/journal，
  //  不改 journal/FIFO/registry/token/slot。
  // 失败/边界：slot 数超过 CMQ_DEPTH、make_cancel_completion 或 journal staging 失败时返回错误；
  //  partial stage 仅存于调用期输出，调用方不得进入 commit。
  protected function rdma_status
  stage_generation_cancel_candidates_locked(
    input int unsigned generation,
    output rdma_cmq_terminal_transition_candidate_stage_t stage
  );
    rdma_status status;

    stage.staged_records.delete();
    stage.staged_completions.delete();
    stage.staged_batches.delete();
    stage.staged_items.delete();
    stage.staged_journal_completions.delete();
    stage.staged_batch_states.delete();
    stage.staged_recovery_required.delete();
    stage.staged_command_keys.delete();
    if (prepared_binding == null)
      return invalid_state("CMQ cancel candidate generation authority is missing");
    if (generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ cancel candidate generation is stale"
      );

    foreach (slots[i]) begin
      rdma_cmq_slot_record record;
      rdma_cmq_completion completion;
      rdma_cmq_batch_submission_record batch_record;
      rdma_cmq_batch_submission_item_record journal_item;
      rdma_cmq_completion journal_completion;
      rdma_cmq_submission_state_e reduced_batch_state;
      bit recovery_required;

      record = slots[i];
      if (record == null || record.state != CMQ_SLOT_PUBLISHED)
        continue;
      if (stage.staged_records.size() >= CMQ_DEPTH)
        return invalid_state(
          "CMQ cancel candidate count exceeds ring depth"
        );
      completion = null;
      status = make_cancel_completion(record, completion);
      if (status == null || !status.ok() || completion == null)
        return (status == null) ? invalid_state(
          "CMQ cancel completion helper returned null"
        ) : status;
      status = stage_runtime_journal_transition_locked(
        record, completion,
        RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
        RDMA_CMQ_COMPLETION_RESET_CANCELLED,
        batch_record, journal_item, journal_completion,
        recovery_required, reduced_batch_state
      );
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ cancel journal staging returned null"
        ) : status;
      stage.staged_records.push_back(record);
      stage.staged_completions.push_back(completion);
      stage.staged_batches.push_back(batch_record);
      stage.staged_items.push_back(journal_item);
      stage.staged_journal_completions.push_back(journal_completion);
      stage.staged_batch_states.push_back(reduced_batch_state);
      stage.staged_recovery_required.push_back(recovery_required);
      stage.staged_command_keys.push_back(command_key(record.ticket));
    end
    return rdma_status::success();
  endfunction

  // 功能：判断 slot record 是否是当前 generation 下可信的 PUBLISHED 恢复对象。
  // 输入/输出及副作用：record、slot_index、generation 只读；返回 bit，不改状态。
  // 失败/边界：字段含 X/Z、ticket 不可信、非 PUBLISHED、Function/CMQ/generation 不匹配或 ring
  //  geometry/tuple 不符时返回 0。
  protected function bit recovery_record_is_trusted(
    rdma_cmq_slot_record record,
    int unsigned slot_index,
    int unsigned generation
  );
    rdma_status status;

    if (record == null || record.ticket == null ||
        $isunknown(record.slot_sequence) ||
        $isunknown(record.sq_index) ||
        $isunknown(record.sq_wrap) ||
        $isunknown(record.state) ||
        $isunknown(record.command_token))
      return 1'b0;
    status = ticket_trust_status(record.ticket);
    if (status == null || !status.ok())
      return 1'b0;
    if (record.state != CMQ_SLOT_PUBLISHED ||
        prepared_binding == null ||
        !prepared_binding.accepts(record.ticket.function_h) ||
        cmq_snapshot == null || cmq_snapshot.handle == null ||
        !same_handle(record.ticket.cmq_h, cmq_snapshot.handle) ||
        record.ticket.function_h.generation != generation ||
        !rdma_cmq_slot_ring_geometry_matches(
          record.slot_sequence, record.sq_index, record.sq_wrap,
          slot_index, CMQ_DEPTH
        ) ||
        !slot_ticket_tuple_matches(record))
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：审计 ledger 后把仍 PUBLISHED 的 journal item 转为 reset cancellation，使旧 generation
  //  进入 QUIESCED；timeout tombstone 及其 slot/token authority 保留，待 late completion 或 reset 隔离。
  // 输入/输出及副作用：generation、recover_poisoned_ledger 为输入；严格路径先预建 completion/journal
  //  transition，再在锁内提交 FIFO、command registry 与 slot；poison 路径仅供 shutdown 尽力清账。
  // 失败/边界：generation 不匹配返回 STALE_GENERATION；审计、authority、journal predecessor 或
  //  snapshot 不完整时 fail closed，不发布 FIFO、不改 journal/runtime；quarantine 不重复取消。
  protected function rdma_status cancel_generation_locked(
    int unsigned generation,
    bit recover_poisoned_ledger
  );
    rdma_status status;
    rdma_cmq_completion staged_completions[CMQ_DEPTH];
    rdma_cmq_terminal_transition_candidate_stage_t strict_stage;
    bit recovery_command_keys[string];
    int unsigned staged_count;

    if (prepared_binding == null)
      return invalid_state("CMQ generation authority is missing");
    if (generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ cancel generation does not match current generation"
      );

    if (!recover_poisoned_ledger) begin
      status = strict_cancel_ledger_status(generation);
      if (status == null || !status.ok())
        return (status == null) ?
          poison_status("CMQ cancel ledger audit returned null status") :
          status;
    end

    staged_count = 0;
    if (recover_poisoned_ledger) begin
      foreach (slots[i]) begin
        rdma_cmq_slot_record record;
        string software_key;

        record = slots[i];
        if (!recovery_record_is_trusted(record, i, generation))
          continue;
        software_key = command_key(record.ticket);
        if (recovery_command_keys.exists(software_key))
          continue;
        status = make_cancel_completion(
          record, staged_completions[staged_count]
        );
        if (status != null && status.ok() &&
            staged_completions[staged_count] != null) begin
          recovery_command_keys[software_key] = 1'b1;
          staged_count++;
        end
      end
    end
    else begin
      status = stage_generation_cancel_candidates_locked(
        generation, strict_stage
      );
      if (status == null || !status.ok())
        return (status == null) ?
          invalid_state("CMQ cancel candidate staging returned null status") :
          status;
    end

    if (recover_poisoned_ledger) begin
      // // shutdown/poison 恢复无 completion 输出契约，可保守丢弃可信取消证据并清空全部 runtime 容器
      // // （调用方已保留 release authority）。
      for (int unsigned i = 0; i < staged_count; i++)
        terminal_fifo.push_back(staged_completions[i]);
      foreach (slots[i])
        slots[i] = null;
      foreach (token_in_use[i])
        token_in_use[i] = 1'b0;
      command_registry.delete();
      entry_registry.delete();
      publish_seq = 0;
      retire_seq = 0;
      cq_consume_seq = 0;
      profile_image_format_valid = 1'b0;
      profile_image_endian = RDMA_ENDIAN_LITTLE;
      profile_hardware_version = 0;
    end
    else begin
      // // journal 证据先于 FIFO 发布提交；runtime slot/entry/token 图保持权威，直到后续 reset 或
      // // shutdown 证明旧硬件已隔离。
      for (int unsigned i = 0; i < strict_stage.staged_records.size(); i++) begin
        commit_runtime_journal_transition_locked(
          strict_stage.staged_batches[i], strict_stage.staged_items[i],
          strict_stage.staged_journal_completions[i],
          RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
          RDMA_CMQ_COMPLETION_RESET_CANCELLED,
          strict_stage.staged_recovery_required[i],
          strict_stage.staged_batch_states[i]
        );
        terminal_fifo.push_back(strict_stage.staged_completions[i]);
        command_registry.delete(strict_stage.staged_command_keys[i]);
        strict_stage.staged_records[i].state = CMQ_SLOT_RESET_CANCELLED;
      end
    end
    engine_state = RDMA_CMQ_ENGINE_QUIESCED;
    return rdma_status::success();
  endfunction

  // 功能：假定 prospective_record 即将完成，从 retire_seq 预演可连续回收的 SQ 前缀。
  // 输入/输出及副作用：record 非拥有；prospective_retire_seq 输出预演结束位置；只读账本。
  // 失败/边界：record 缺失、sequence 越界、index/wrap 或 slot 身份不符返回 INVALID_STATE；
  //  遇未完成前驱正常停止；失败输出不可用于回收。
  protected function rdma_status prospective_retirement_status(
    rdma_cmq_slot_record prospective_record,
    output longint unsigned prospective_retire_seq
  );
    rdma_cmq_ring_position_t prospective_position;

    prospective_retire_seq = retire_seq;
    if (prospective_record == null)
      return invalid_state("CMQ prospective retirement record is null");
    if (!rdma_cmq_ring_position_for_sequence(
          prospective_record.slot_sequence, CMQ_DEPTH, prospective_position
        ) ||
        prospective_record.slot_sequence < retire_seq ||
        prospective_record.slot_sequence >= publish_seq ||
        prospective_record.sq_index != prospective_position.index ||
        prospective_record.sq_wrap != prospective_position.wrap)
      return invalid_state(
        "CMQ prospective retirement record incarnation is inconsistent"
      );
    while (prospective_retire_seq < publish_seq) begin
      int unsigned index;
      rdma_cmq_slot_record record;
      rdma_cmq_ring_position_t position;

      if (!rdma_cmq_ring_position_for_sequence(
            prospective_retire_seq, CMQ_DEPTH, position
          ))
        return invalid_state("CMQ retirement sequence geometry is unknown");
      index = position.index;
      record = slots[index];
      if (record == null ||
          record.slot_sequence != prospective_retire_seq ||
          record.sq_index != index ||
          record.sq_wrap != position.wrap)
        return invalid_state("CMQ retirement slot ledger is inconsistent");
      if (record != prospective_record &&
          !(record.state inside {
            CMQ_SLOT_COMPLETED,
            CMQ_SLOT_LATE_COMPLETED,
            CMQ_SLOT_RESET_CANCELLED
          }))
        break;
      prospective_retire_seq++;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 completion 提交后，回收已预验的连续 SQ slot/entry 前缀。
  // 输入/输出及副作用：prospective_retire_seq 为已认证结束位置；逐项删 entry、清 slot、递增 retire_seq。
  // 失败/边界：结束位置不大于 retire_seq 时无操作；几何转换失败即停止且不回滚；不做 epoch/超时检查。
  protected function void commit_retired_prefix(
    longint unsigned prospective_retire_seq
  );
    while (retire_seq < prospective_retire_seq) begin
      int unsigned index;
      rdma_cmq_ring_position_t position;

      if (!rdma_cmq_ring_position_for_sequence(
            retire_seq, CMQ_DEPTH, position
          ))
        return;
      index = position.index;
      entry_registry.delete(entry_key(index, slots[index].sq_wrap));
      slots[index] = null;
      retire_seq++;
    end
  endfunction

  // 功能：same_handle 的 engine 扩展点，委托共享契约比较 incarnation。
  // 输入/输出及副作用：lhs/rhs 只读；返回共享结果。
  // 失败/边界：任一为 null 返回 0。
  protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
    return rdma_cmq_same_handle_instance(lhs, rhs);
  endfunction

  // 功能：detached handle 值比较 seam，转发共享契约。
  // 输入/输出及副作用：lhs/rhs 只读；比较 kind/uid/object/generation。
  // 失败/边界：null 或字段含 X/Z 返回 0。
  protected function bit same_handle_value(
    input rdma_handle lhs,
    input rdma_handle rhs
  );
    return rdma_cmq_same_handle_value(lhs, rhs);
  endfunction

  // 功能：status 值比较 seam，转发共享契约。
  // 输入/输出及副作用：lhs/rhs 只读；比较完整诊断字段。
  // 失败/边界：null、不支持子类型或 shape 非法返回 0。
  protected function bit same_status_value(
    input rdma_status lhs,
    input rdma_status rhs
  );
    return rdma_cmq_same_status_value(lhs, rhs);
  endfunction

  // 功能：判断 command 是否属于 context-body codec（MRT/CQC 等），允许 journal 以已编码 SQE image 作投影。
  // 输入/输出及副作用：command/body 只读；仅检查 opcode 与 body 的确切 context model 类型。
  // 失败/边界：command/opcode/body 为空、opcode 非已注册 context opcode 或类型不匹配时返回 0。
  protected function bit context_body_fallback_supported(
    input rdma_cmq_command_desc command,
    input rdma_hw_model body
  );
    rdma_mrt_model mrt;
    rdma_cqc_model cqc;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if (command == null || command.opcode_key == null || body == null)
      return 1'b0;
    case (command.opcode_key.opcode)
      RDMA_OP_KEY_ALLOC,
      RDMA_OP_MR_REGISTER:
        return $cast(mrt, body);
      RDMA_OP_CQC_CREATE:
        return $cast(cqc, body);
      RDMA_OP_SRFQC_CREATE:
        return $cast(srqc, body);
      RDMA_OP_CEQC_CREATE:
        return $cast(ceqc, body);
      RDMA_OP_AEQC_CREATE:
        return $cast(aeqc, body);
      default:
        return 1'b0;
    endcase
  endfunction

  // 功能：生成 journal 用的 command body 规范化投影；先委托 profile 的五种 V1 body seam，
  //  对 MRT/CQC/SRQC/CEQC/AEQC 仅在 SQE 已编码后以 CONTEXT-IMAGE-V1 标签与 SQE 字节作 fallback。
  // 输入/输出及副作用：profile_service/command/encoded_image 只读；schema_tag/field_bytes 入口清空，
  //  成功时输出新值，不保留输入引用。
  // 失败/边界：输入缺失、规范化返回 null、context 类型不符或 image shape 非法时返回原失败 status；
  //  不接受未知 body，也不以 EMPTY 冒充 context。
  protected function rdma_status canonicalize_journal_body(
    input rdma_cmq_hw_profile profile_service,
    input rdma_cmq_command_desc command,
    input rdma_hw_image encoded_image,
    output string schema_tag,
    output byte unsigned field_bytes[]
  );
    rdma_status status;

    schema_tag = "";
    field_bytes = new[0];
    if (profile_service == null || command == null ||
        command.body == null || encoded_image == null)
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal body canonicalization source is incomplete"
      );
    status = profile_service.canonicalize_command_body(
      command.body, schema_tag, field_bytes
    );
    if (status == null)
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal body canonicalization returned null status"
      );
    if (status.ok())
      return status;
    if (!context_body_fallback_supported(command, command.body) ||
        !rdma_cmq_image_shape_valid(encoded_image))
      return status;

    schema_tag = "CMQ-BODY-CONTEXT-IMAGE-V1";
    field_bytes = new[encoded_image.bytes.size()];
    foreach (encoded_image.bytes[i])
      field_bytes[i] = encoded_image.bytes[i];
    return rdma_cmq_direct_status(RDMA_SC_OK);
  endfunction

  // 功能：克隆 Function binding 得到隔离快照。
  // 输入/输出及副作用：source 只读；snapshot 输出克隆结果。
  // 失败/边界：source 为 null 返回 INVALID_ARGUMENT；clone 失败返回 INVALID_STATE。
  protected function rdma_status clone_binding_snapshot(
    rdma_function_binding source,
    output rdma_function_binding snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_argument("CMQ Function binding is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
      snapshot = null;
      return invalid_state("CMQ Function binding snapshot clone failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：校验 binding 的 owner_h 与 binding.make_handle() 一致。
  // 输入/输出及副作用：binding 只读；lifecycle_name 拼入诊断文本。
  // 失败/边界：binding 为 null 返回 INVALID_ARGUMENT；owner 缺失或不一致返回 INVALID_STATE。
  protected function rdma_status validate_binding_owner(
    rdma_function_binding binding,
    string lifecycle_name
  );
    rdma_function_handle expected_owner;

    if (binding == null)
      return invalid_argument("CMQ Function binding is null");
    expected_owner = binding.make_handle();
    if (binding.owner_h == null ||
        !same_handle(binding.owner_h, expected_owner))
      return invalid_state({lifecycle_name,
                            " Function binding owner identity is invalid"});
    return rdma_status::success();
  endfunction

  // 功能：校验 binding 处于 PREPARED 且自身合法。
  // 输入/输出及副作用：binding 只读；返回状态。
  // 失败/边界：null 返回 INVALID_ARGUMENT；非 PREPARED 或 validate 失败返回 INVALID_STATE。
  protected function rdma_status prepared_binding_status(
    rdma_function_binding binding
  );
    rdma_status status;

    if (binding == null)
      return invalid_argument("CMQ Function binding is null");
    if (binding.state != RDMA_BIND_PREPARED)
      return invalid_state("CMQ prepare requires a PREPARED binding");
    status = rdma_status::nonnull(binding.validate(), "CMQ PREPARED binding returned null status");
    if (!status.ok())
      return status;
    return validate_binding_owner(binding, "PREPARED");
  endfunction

  // 功能：校验 binding 处于 ACTIVE 且自身合法。
  // 输入/输出及副作用：binding 只读；返回状态。
  // 失败/边界：null 返回 INVALID_ARGUMENT；非 ACTIVE 或 validate 失败返回 INVALID_STATE。
  protected function rdma_status active_binding_status(
    rdma_function_binding binding
  );
    rdma_status status;

    if (binding == null)
      return invalid_argument("CMQ active Function binding is null");
    if (binding.state != RDMA_BIND_ACTIVE)
      return invalid_state("CMQ activate requires an ACTIVE binding");
    status = rdma_status::nonnull(binding.validate(), "CMQ ACTIVE binding returned null status");
    if (!status.ok())
      return status;
    return validate_binding_owner(binding, "ACTIVE");
  endfunction

  // 功能：克隆 CMQ 资源得到隔离快照。
  // 输入/输出及副作用：source 只读；snapshot 输出克隆结果。
  // 失败/边界：source 为 null 返回 INVALID_ARGUMENT；clone 失败返回 INVALID_STATE。
  protected function rdma_status clone_cmq_snapshot(
    rdma_cmq source,
    output rdma_cmq snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_argument("CMQ resource is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
      snapshot = null;
      return invalid_state("CMQ resource snapshot clone failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：校验 CMQ 资源 ALLOCATED、深度为 CMQ_DEPTH，且 owner/handle 与 binding 的 Function 一致。
  // 输入/输出及副作用：cmq、binding 只读；返回状态。
  // 失败/边界：null、状态/深度/owner/handle 不符返回 INVALID_ARGUMENT/INVALID_STATE；generation 不符返回
  //   STALE_GENERATION。
  protected function rdma_status cmq_resource_status(
    rdma_cmq cmq,
    rdma_function_binding binding
  );
    rdma_status status;
    rdma_function_handle expected_owner;

    if (cmq == null)
      return invalid_argument("CMQ resource is null");
    status = rdma_status::nonnull(cmq.validate(), "CMQ resource returned null status");
    if (!status.ok())
      return status;
    if (cmq.state != RDMA_RESOURCE_ALLOCATED)
      return invalid_state("CMQ resource is not ALLOCATED");
    if (cmq.depth != CMQ_DEPTH)
      return invalid_argument("CMQ queue depth must be 32");
    expected_owner = binding.make_handle();
    if (cmq.owner == null || !same_handle(cmq.owner, expected_owner))
      return invalid_argument("CMQ owner does not match Function binding");
    if (cmq.handle == null || cmq.handle.kind != RDMA_RESOURCE_CMQ)
      return invalid_argument("CMQ resource handle is invalid");
    if (cmq.handle.function_uid != expected_owner.function_uid)
      return invalid_argument("CMQ handle Function UID does not match owner");
    if (cmq.handle.generation != expected_owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ handle Function generation does not match owner"
      );
    return rdma_status::success();
  endfunction

  // 功能：由 binding/cmq 构造 CMQ DMA request context（Function、BDF、PASID、domain、route、epoch、owner）。
  // 输入/输出及副作用：binding、cmq、pasid_valid、pasid 输入；request_context 输出新对象。
  // 失败/边界：构造或 validate 失败、PASID 与 Function queue DMA authority 不符时返回 INVALID_STATE 或
  //   DMA_TRANSLATION。
  protected function rdma_status make_request_context(
    rdma_function_binding binding,
    rdma_cmq cmq,
    bit pasid_valid,
    bit [19:0] pasid,
    output rdma_dma_request_context request_context
  );
    rdma_status status;
    rdma_function_identity identity;
    request_context = rdma_dma_request_context::type_id::create(
      "cmq_dma_request_context"
    );
    if (request_context == null)
      return invalid_state("CMQ DMA request context construction failed");
    request_context.function_h = binding.make_handle();
    if (request_context.function_h == null)
      return invalid_state("CMQ DMA Function handle construction failed");
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return invalid_state("CMQ DMA Function identity snapshot failed");
    if (pasid_valid != binding.queue_dma.pasid_valid ||
        (pasid_valid ? pasid : '0) != binding.queue_dma.pasid)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ PASID does not match Function queue DMA authority"
      );
    request_context.requester_bdf = binding.queue_dma.requester_bdf;
    request_context.pasid_valid = binding.queue_dma.pasid_valid;
    request_context.pasid = binding.queue_dma.pasid;
    request_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    // // Host-memory router 需要完整 route 与 reset epoch；把 identity 快照投影进 request context，
    // // 避免 CMQ 经 router 时因缺少路由/代际证据被拒。
    request_context.route = identity.route_key();
    request_context.route_valid = 1'b1;
    request_context.reset_epoch = identity.reset_epoch;
    request_context.epoch_valid = 1'b1;
    request_context.owner_h = rdma_clone_handle_value(
      cmq.handle, "CMQ DMA owner"
    );
    status = request_context.validate();
    if (status == null)
      return invalid_state("CMQ DMA request context returned null status");
    return status;
  endfunction

  // 功能：核对 host-memory 返回的 backing mapping 与 request context 的权限、身份和范围一致。
  // 输入/输出及副作用：mapping、request_context 只读；返回状态。
  // 失败/边界：句柄缺失、Function/BDF/PASID/domain/owner 不符、非 ACTIVE、尺寸/方向/权限/对齐/溢出异常时拒绝。
  protected function rdma_status mapping_authority_status(
    rdma_dma_mapping mapping,
    rdma_dma_request_context request_context
  );
    rdma_dma_permission_t expected_permissions;

    expected_permissions = '{
      device_read: 1'b1,
      device_write: 1'b1,
      atomic: 1'b0
    };
    if (mapping == null)
      return invalid_state("CMQ host memory returned a null mapping");
    if (request_context == null)
      return invalid_state("CMQ DMA authority context is missing");
    if (mapping.function_h == null)
      return invalid_state("CMQ mapping Function authority is missing");
    if (request_context.function_h == null)
      return invalid_state("CMQ request Function authority is missing");
    if (mapping.function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping Function handle kind is invalid"
      );
    if (mapping.function_h.function_uid !=
          request_context.function_h.function_uid ||
        mapping.function_h.object_id != request_context.function_h.object_id)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping Function authority does not match request"
      );
    if (mapping.function_h.generation !=
        request_context.function_h.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ mapping Function generation does not match request"
      );
    if (!rdma_cmq_same_bdf_value(mapping.requester_bdf,
                  request_context.requester_bdf))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping requester BDF does not match request"
      );
    if (mapping.pasid_valid != request_context.pasid_valid)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "CMQ mapping PASID-valid authority does not match request"
      );
    if (mapping.pasid != request_context.pasid)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "CMQ mapping PASID authority does not match request"
      );
    if (mapping.dma_domain_valid != request_context.dma_domain_valid)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping DMA-domain-valid authority does not match request"
      );
    if (mapping.dma_domain_id != request_context.dma_domain_id)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping DMA domain authority does not match request"
      );
    if (mapping.owner_h == null || request_context.owner_h == null ||
        !same_handle(mapping.owner_h, request_context.owner_h))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping owner authority does not match request"
      );
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return invalid_state("CMQ backing mapping is not ACTIVE");
    if (mapping.size != BACKING_BYTES)
      return invalid_state("CMQ backing mapping size is not 4096 bytes");
    if (mapping.direction != RDMA_DMA_BIDIRECTIONAL)
      return invalid_state("CMQ backing mapping is not bidirectional");
    if (mapping.permissions != expected_permissions)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "CMQ backing mapping permissions are not exactly bidirectional"
      );
    if ((mapping.iova.value & (BACKING_BYTES - 1'b1)) != 0 ||
        (mapping.backing_addr.value & (BACKING_BYTES - 1'b1)) != 0)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ backing mapping is not 4096-byte aligned"
      );
    if (mapping.iova.value >
          (64'hffff_ffff_ffff_ffff - (BACKING_BYTES - 1'b1)) ||
        mapping.backing_addr.value >
          (64'hffff_ffff_ffff_ffff - (BACKING_BYTES - 1'b1)))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ backing mapping range overflows"
      );
    return rdma_status::success();
  endfunction

  // 功能：复制 Function handle 的值字段到新对象。
  // 输入/输出及副作用：source 只读；name 为新对象名；result 输出。
  // 失败/边界：source 为 null 或构造失败返回 INVALID_STATE。
  protected function rdma_status clone_function_handle_fields(
    rdma_function_handle source,
    string name,
    output rdma_function_handle result
  );
    result = null;
    if (source == null)
      return invalid_state("CMQ runtime Function source is null");
    result = rdma_function_handle::type_id::create(name);
    if (result == null)
      return invalid_state("CMQ runtime Function construction failed");
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  // 功能：复制 handle 的值字段到新对象。
  // 输入/输出及副作用：source 只读；name 为新对象名；result 输出。
  // 失败/边界：source 为 null 或构造失败返回 INVALID_STATE。
  protected function rdma_status clone_handle_fields(
    rdma_handle source,
    string name,
    output rdma_handle result
  );
    result = null;
    if (source == null)
      return invalid_state("CMQ runtime handle source is null");
    result = rdma_handle::type_id::create(name);
    if (result == null)
      return invalid_state("CMQ runtime handle construction failed");
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  // 功能：以指定状态码构造诊断状态。
  // 输入/输出及副作用：failure_code、message 输入；返回新 status。
  // 失败/边界：无。
  protected function rdma_status snapshot_failure(
    rdma_status_code_e failure_code,
    string message
  );
    return rdma_status::make(failure_code, message);
  endfunction

  // 功能：image 值比较 seam，转发共享契约（bytes、metadata、targets、summary）。
  // 输入/输出及副作用：lhs/rhs 只读；返回共享结果。
  // 失败/边界：null 或字段不同返回 0。
  protected function bit same_image_value(
    rdma_hw_image lhs,
    rdma_hw_image rhs
  );
    return rdma_cmq_same_image_value(lhs, rhs);
  endfunction

  // 功能：expected-response 值比较 seam，转发共享契约。
  // 输入/输出及副作用：lhs/rhs 只读；返回共享结果。
  // 失败/边界：任一为 null 返回 0。
  protected function bit same_expected_value(
    rdma_cmq_expected_response lhs,
    rdma_cmq_expected_response rhs
  );
    return rdma_cmq_same_expected_value(lhs, rhs);
  endfunction

  // 功能：opcode-key 值比较 seam，转发共享契约。
  // 输入/输出及副作用：lhs/rhs 只读；返回共享结果。
  // 失败/边界：任一为 null 返回 0；不做 validate。
  protected function bit same_opcode_value(
    rdma_cmq_opcode_key lhs,
    rdma_cmq_opcode_key rhs
  );
    return rdma_cmq_same_opcode_value(lhs, rhs);
  endfunction

  // 功能：mapping 值比较 seam，转发共享 instance-authority 契约。
  // 输入/输出及副作用：lhs/rhs 只读；返回共享结果。
  // 失败/边界：mapping 或必需 handle 为 null 返回 0。
  protected function bit same_mapping_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    return rdma_cmq_same_mapping_instance_value(lhs, rhs);
  endfunction

  // 功能：ticket instance 比较 seam，转发共享契约。
  // 输入/输出及副作用：lhs/rhs 只读；返回共享结果。
  // 失败/边界：ticket 或 Function/CMQ handle 为 null 返回 0。
  protected function bit same_ticket_value(
    rdma_cmq_ticket lhs,
    rdma_cmq_ticket rhs
  );
    return rdma_cmq_same_ticket_instance_value(lhs, rhs);
  endfunction

  // 功能：逐字段比较两个 doorbell dependency（id、stage、mapping 等）。
  // 输入/输出及副作用：lhs/rhs 只读；返回 bit。
  // 失败/边界：任一为 null 返回 0。
  protected function bit same_dependency_value(
    rdma_doorbell_dependency lhs,
    rdma_doorbell_dependency rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.dependency_id == rhs.dependency_id &&
           lhs.stage == rhs.stage &&
           same_mapping_value(lhs.mapping, rhs.mapping) &&
           lhs.relative_offset == rhs.relative_offset &&
           same_image_value(lhs.image, rhs.image) &&
           lhs.ready == rhs.ready;
  endfunction

  // 功能：body 值键 seam，转发共享 model 契约。
  // 输入/输出及副作用：body 原样传入；返回稳定字符串。
  // 失败/边界：null/unsupported 与 SQE 递归由共享 helper 处理。
  protected function automatic string body_value_key(rdma_hw_model body);
    return rdma_cmq_body_value_key(body);
  endfunction

  // 功能：比较两个 hw model body 是否值相等。
  // 输入/输出及副作用：lhs/rhs 只读；返回 bit。
  // 失败/边界：任一为 null 或类型不符返回 0。
  protected function automatic bit same_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    uvm_object_wrapper lhs_type;
    uvm_object_wrapper rhs_type;
    rdma_cmq_sqe_model lhs_sqe;
    rdma_cmq_sqe_model rhs_sqe;
    string lhs_value;
    string rhs_value;

    if (lhs == null || rhs == null)
      return 1'b0;
    lhs_type = lhs.get_object_type();
    rhs_type = rhs.get_object_type();
    if (lhs_type == null || rhs_type == null || lhs_type != rhs_type)
      return 1'b0;
    if (!rdma_cmq_core_body_shell_is_exact(lhs) ||
        !rdma_cmq_core_body_shell_is_exact(rhs)) begin
      if (profile == null)
        return 1'b0;
      return profile.same_command_body_value(lhs, rhs);
    end
    if (lhs_type == rdma_cmq_sqe_model::get_type()) begin
      if (!$cast(lhs_sqe, lhs) || !$cast(rhs_sqe, rhs))
        return 1'b0;
      if (lhs_sqe.opcode != rhs_sqe.opcode ||
          lhs_sqe.command_id != rhs_sqe.command_id ||
          lhs_sqe.flags != rhs_sqe.flags ||
          rdma_cmq_handle_value_key(lhs_sqe.function_h) !=
            rdma_cmq_handle_value_key(rhs_sqe.function_h) ||
          rdma_cmq_handle_value_key(lhs_sqe.target_h) !=
            rdma_cmq_handle_value_key(rhs_sqe.target_h) ||
          ((lhs_sqe.context_model == null) !=
           (rhs_sqe.context_model == null)))
        return 1'b0;
      return lhs_sqe.context_model == null ||
             same_body_value(lhs_sqe.context_model,
                             rhs_sqe.context_model);
    end
    lhs_value = body_value_key(lhs);
    rhs_value = body_value_key(rhs);
    if (lhs_value != "" || rhs_value != "")
      return lhs_value != "" && lhs_value == rhs_value;
    return 1'b0;
  endfunction

  // 功能：body graph 枚举 seam，转发共享契约。
  // 输入/输出及副作用：body 原样传入；向 nodes 追加非拥有引用。
  // 失败/边界：null、unsupported、顺序与去重语义均由共享 helper 保持。
  protected function automatic void append_body_graph_nodes(
    rdma_hw_model body,
    ref uvm_object nodes[$]
  );
    rdma_cmq_append_body_graph_nodes(body, nodes);
  endfunction

  // 功能：检查 snapshot 的 body 图与 source 同类型且无共享节点（SQE 递归检查 context_model）。
  // 输入/输出及副作用：source、snapshot 只读；非核心 body 交给 profile 判定；返回 bit。
  // 失败/边界：任一为 null、类型不同、共享节点或 profile 缺失（非核心 body）时返回 0。
  protected function automatic bit body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    uvm_object_wrapper source_type;
    uvm_object_wrapper snapshot_type;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model snapshot_sqe;
    uvm_object source_nodes[$];
    uvm_object snapshot_nodes[$];

    if (source == null || snapshot == null)
      return 1'b0;
    source_type = source.get_object_type();
    snapshot_type = snapshot.get_object_type();
    if (source_type == null || snapshot_type == null ||
        source_type != snapshot_type)
      return 1'b0;
    if (!rdma_cmq_core_body_shell_is_exact(source) ||
        !rdma_cmq_core_body_shell_is_exact(snapshot)) begin
      if (profile == null)
        return 1'b0;
      return profile.command_body_graph_detached(source, snapshot);
    end
    if (source_type == rdma_cmq_sqe_model::get_type()) begin
      if (!$cast(source_sqe, source) || !$cast(snapshot_sqe, snapshot))
        return 1'b0;
      append_body_graph_nodes(source, source_nodes);
      append_body_graph_nodes(snapshot, snapshot_nodes);
      foreach (source_nodes[i])
        foreach (snapshot_nodes[j])
          if (source_nodes[i] == snapshot_nodes[j])
            return 1'b0;
      if ((source_sqe.context_model == null) !=
          (snapshot_sqe.context_model == null))
        return 1'b0;
      return source_sqe.context_model == null ||
             body_graph_detached(source_sqe.context_model,
                                 snapshot_sqe.context_model);
    end
    append_body_graph_nodes(source, source_nodes);
    append_body_graph_nodes(snapshot, snapshot_nodes);
    foreach (source_nodes[i])
      foreach (snapshot_nodes[j])
        if (source_nodes[i] == snapshot_nodes[j])
          return 1'b0;
    return 1'b1;
  endfunction

  // 功能：校验嵌套对象（handle、ring、page layout 等）合法。
  // 输入/输出及副作用：source 只读；label、failure_code 用于构造诊断。
  // 失败/边界：source 为 null、类型不受支持或 validate 返回 null 时以 failure_code 返回；其余透传 validate 结果。
  protected function rdma_status nested_object_status(
    uvm_object source,
    string label,
    rdma_status_code_e failure_code
  );
    rdma_handle handle;
    rdma_ring_position ring;
    rdma_page_table_layout page_layout;
    rdma_address_vector address_vector;
    rdma_urc_queue_config queues;
    rdma_mr_page_layout mr_page_layout;
    rdma_qpc_behavior behavior;
    rdma_qpc_transport_ext transport_ext;
    rdma_status status;

    if (source == null)
      return snapshot_failure(failure_code, {label, " is null"});
    if ($cast(handle, source))
      return rdma_status::success();
    if ($cast(ring, source))
      status = ring.validate();
    else if ($cast(page_layout, source))
      status = page_layout.validate();
    else if ($cast(address_vector, source))
      status = address_vector.validate();
    else if ($cast(queues, source))
      status = queues.validate();
    else if ($cast(mr_page_layout, source))
      status = mr_page_layout.validate();
    else if ($cast(behavior, source))
      status = behavior.validate();
    else if ($cast(transport_ext, source))
      status = transport_ext.validate();
    else
      return snapshot_failure(
        failure_code, {label, " has an unsupported nested type"}
      );
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " validation returned null"}
      );
    return status;
  endfunction

  // 功能：校验并克隆嵌套对象，要求克隆后源值未被改变。
  // 输入/输出及副作用：source 只读（内部临时 copy/还原）；snapshot 输出克隆。
  // 失败/边界：校验失败、无值表示、克隆契约或值一致性失败时以 failure_code 返回，snapshot 为 null。
  protected function rdma_status checked_nested_snapshot(
    uvm_object source,
    string label,
    rdma_status_code_e failure_code,
    output uvm_object snapshot
  );
    uvm_object cloned_object;
    uvm_object saved_source;
    uvm_object_wrapper source_wrapper;
    rdma_status status;
    string source_type_name;
    string saved_value;

    snapshot = null;
    status = nested_object_status(source, label, failure_code);
    if (!status.ok())
      return status;
    source_type_name = source.get_type_name();
    saved_value = rdma_cmq_nested_value_key(source);
    if (saved_value == "")
      return snapshot_failure(
        failure_code, {label, " has no checked value representation"}
      );
    source_wrapper = source.get_object_type();
    saved_source = (source_wrapper == null) ? null :
      source_wrapper.create_object({label, "_saved"});
    if (saved_source == null)
      return snapshot_failure(
        failure_code, {label, " source value capture failed"}
      );
    saved_source.copy(source);
    cloned_object = source.clone();
    source.copy(saved_source);
    if (cloned_object == null || cloned_object == source ||
        cloned_object.get_type_name() != source_type_name) begin
      return snapshot_failure(
        failure_code, {label, " snapshot clone contract failed"}
      );
    end
    if (rdma_cmq_nested_value_key(source) != saved_value ||
        rdma_cmq_nested_value_key(cloned_object) != saved_value) begin
      return snapshot_failure(
        failure_code, {label, " snapshot changed its source value"}
      );
    end
    status = nested_object_status(cloned_object, label, failure_code);
    if (!status.ok())
      return status;
    snapshot = cloned_object;
    return rdma_status::success();
  endfunction

  // 功能：校验并克隆 QPC transport 扩展（RC/UD 直接克隆，URC 另行克隆 queues）。
  // 输入/输出及副作用：source 只读（URC 路径会临时置空/还原 source.queues）；snapshot 输出克隆。
  // 失败/边界：source 为 null、类型不受支持、嵌套快照或类型转换失败时以 failure_code 返回，snapshot 为 null。
  protected function rdma_status checked_transport_snapshot(
    rdma_qpc_transport_ext source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_qpc_transport_ext snapshot
  );
    uvm_object cloned_object;
    uvm_object queues_object;
    uvm_object saved_object;
    uvm_object_wrapper source_wrapper;
    rdma_status status;
    rdma_qpc_rc_ext source_rc;
    rdma_qpc_ud_ext source_ud;
    rdma_qpc_urc_ext source_urc;
    rdma_qpc_urc_ext snapshot_urc;
    rdma_urc_queue_config queues_snapshot;
    string source_type_name;
    string saved_value;
    string saved_shell_value;
    rdma_urc_queue_config saved_queues;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code,
                              {label, " transport extension is null"});
    if ($cast(source_rc, source) || $cast(source_ud, source)) begin
      status = checked_nested_snapshot(
        source, {label, " transport extension"}, failure_code,
        cloned_object
      );
      if (!status.ok())
        return status;
      if (!$cast(snapshot, cloned_object))
        return snapshot_failure(
          failure_code, {label, " transport snapshot type is invalid"}
        );
      return rdma_status::success();
    end
    if (!$cast(source_urc, source))
      return snapshot_failure(
        failure_code, {label, " transport extension type is unsupported"}
      );
    status = nested_object_status(source_urc, label, failure_code);
    if (!status.ok())
      return status;
    status = checked_nested_snapshot(
      source_urc.queues, {label, " URC queues"}, failure_code,
      queues_object
    );
    if (!status.ok())
      return status;
    if (!$cast(queues_snapshot, queues_object))
      return snapshot_failure(failure_code,
                              {label, " URC queue snapshot is invalid"});
    source_type_name = source.get_type_name();
    saved_value = rdma_cmq_nested_value_key(source);
    saved_queues = source_urc.queues;
    source_urc.queues = null;
    source_wrapper = source.get_object_type();
    saved_object = (source_wrapper == null) ? null :
      source_wrapper.create_object({label, "_saved_transport"});
    if (saved_object == null) begin
      source_urc.queues = saved_queues;
      return snapshot_failure(
        failure_code, {label, " transport value capture failed"}
      );
    end
    saved_object.copy(source);
    saved_shell_value = rdma_cmq_nested_value_key(saved_object);
    cloned_object = source.clone();
    source.copy(saved_object);
    source_urc.queues = saved_queues;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name ||
        !$cast(snapshot_urc, snapshot)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport snapshot clone contract failed"}
      );
    end
    if (rdma_cmq_nested_value_key(source) != saved_value ||
        rdma_cmq_nested_value_key(snapshot) != saved_shell_value ||
        snapshot_urc.queues != null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport snapshot changed its source value"}
      );
    end
    snapshot_urc.queues = queues_snapshot;
    if (snapshot_urc.queues == source_urc.queues) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport snapshot aliases its source"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 功能：取出 body 的外部引用（handle、嵌套 model）存入 references，并把 body 中对应字段置 null。
  // 输入/输出及副作用：body 被原地置空引用；references 先清空再接收原引用。
  // 失败/边界：不支持的 body 类型返回 0；成功返回 1。
  protected function automatic bit clear_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    references.delete();
    if ($cast(sqe, body)) begin
      references.push_back(sqe.function_h);
      references.push_back(sqe.target_h);
      references.push_back(sqe.context_model);
      sqe.function_h = null;
      sqe.target_h = null;
      sqe.context_model = null;
      return 1'b1;
    end
    if ($cast(qpc, body)) begin
      references.push_back(qpc.qp_h);
      references.push_back(qpc.pd_h);
      references.push_back(qpc.send_cq_h);
      references.push_back(qpc.recv_cq_h);
      references.push_back(qpc.srq_h);
      references.push_back(qpc.address_vector);
      references.push_back(qpc.behavior);
      references.push_back(qpc.transport_ext);
      qpc.qp_h = null;
      qpc.pd_h = null;
      qpc.send_cq_h = null;
      qpc.recv_cq_h = null;
      qpc.srq_h = null;
      qpc.address_vector = null;
      qpc.behavior = null;
      qpc.transport_ext = null;
      return 1'b1;
    end
    if ($cast(cqc, body)) begin
      references.push_back(cqc.cq_h);
      references.push_back(cqc.ceq_h);
      references.push_back(cqc.page_layout);
      references.push_back(cqc.producer);
      references.push_back(cqc.consumer);
      cqc.cq_h = null;
      cqc.ceq_h = null;
      cqc.page_layout = null;
      cqc.producer = null;
      cqc.consumer = null;
      return 1'b1;
    end
    if ($cast(mrt, body)) begin
      references.push_back(mrt.mr_h);
      references.push_back(mrt.pd_h);
      references.push_back(mrt.page_layout);
      mrt.mr_h = null;
      mrt.pd_h = null;
      mrt.page_layout = null;
      return 1'b1;
    end
    if ($cast(srqc, body)) begin
      references.push_back(srqc.srq_h);
      references.push_back(srqc.pd_h);
      references.push_back(srqc.producer);
      srqc.srq_h = null;
      srqc.pd_h = null;
      srqc.producer = null;
      return 1'b1;
    end
    if ($cast(ceqc, body)) begin
      references.push_back(ceqc.ceq_h);
      references.push_back(ceqc.page_layout);
      references.push_back(ceqc.producer);
      references.push_back(ceqc.consumer);
      ceqc.ceq_h = null;
      ceqc.page_layout = null;
      ceqc.producer = null;
      ceqc.consumer = null;
      return 1'b1;
    end
    if ($cast(aeqc, body)) begin
      references.push_back(aeqc.aeq_h);
      references.push_back(aeqc.page_layout);
      references.push_back(aeqc.producer);
      references.push_back(aeqc.consumer);
      aeqc.aeq_h = null;
      aeqc.page_layout = null;
      aeqc.producer = null;
      aeqc.consumer = null;
      return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：把 references 中保存的外部引用按 clear_body_references 的顺序写回 body。
  // 输入/输出及副作用：body 被原地恢复引用；references 只读。
  // 失败/边界：body 类型不支持或 references 数量/类型不符返回 0。
  protected function automatic bit restore_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if ($cast(sqe, body) && references.size() == 3) begin
      if (!$cast(sqe.function_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(sqe.target_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(sqe.context_model, references[2]) &&
          references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(qpc, body) && references.size() == 8) begin
      if (!$cast(qpc.qp_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(qpc.pd_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(qpc.send_cq_h, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(qpc.recv_cq_h, references[3]) && references[3] != null)
        return 1'b0;
      if (!$cast(qpc.srq_h, references[4]) && references[4] != null)
        return 1'b0;
      if (!$cast(qpc.address_vector, references[5]) &&
          references[5] != null)
        return 1'b0;
      if (!$cast(qpc.behavior, references[6]) && references[6] != null)
        return 1'b0;
      if (!$cast(qpc.transport_ext, references[7]) &&
          references[7] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(cqc, body) && references.size() == 5) begin
      if (!$cast(cqc.cq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(cqc.ceq_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(cqc.page_layout, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(cqc.producer, references[3]) && references[3] != null)
        return 1'b0;
      if (!$cast(cqc.consumer, references[4]) && references[4] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(mrt, body) && references.size() == 3) begin
      if (!$cast(mrt.mr_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(mrt.pd_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(mrt.page_layout, references[2]) && references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(srqc, body) && references.size() == 3) begin
      if (!$cast(srqc.srq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(srqc.pd_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(srqc.producer, references[2]) && references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(ceqc, body) && references.size() == 4) begin
      if (!$cast(ceqc.ceq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(ceqc.page_layout, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(ceqc.producer, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(ceqc.consumer, references[3]) && references[3] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(aeqc, body) && references.size() == 4) begin
      if (!$cast(aeqc.aeq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(aeqc.page_layout, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(aeqc.producer, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(aeqc.consumer, references[3]) && references[3] != null)
        return 1'b0;
      return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：检查 body 的外部引用字段是否都已为 null。
  // 输入/输出及副作用：body 只读；返回 bit。
  // 失败/边界：任一引用非 null 或类型不支持返回 0。
  protected function automatic bit body_references_are_null(
    rdma_hw_model body
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if ($cast(sqe, body))
      return sqe.function_h == null && sqe.target_h == null &&
             sqe.context_model == null;
    if ($cast(qpc, body))
      return qpc.qp_h == null && qpc.pd_h == null &&
             qpc.send_cq_h == null && qpc.recv_cq_h == null &&
             qpc.srq_h == null && qpc.address_vector == null &&
             qpc.behavior == null && qpc.transport_ext == null;
    if ($cast(cqc, body))
      return cqc.cq_h == null && cqc.ceq_h == null &&
             cqc.page_layout == null && cqc.producer == null &&
             cqc.consumer == null;
    if ($cast(mrt, body))
      return mrt.mr_h == null && mrt.pd_h == null &&
             mrt.page_layout == null;
    if ($cast(srqc, body))
      return srqc.srq_h == null && srqc.pd_h == null &&
             srqc.producer == null;
    if ($cast(ceqc, body))
      return ceqc.ceq_h == null && ceqc.page_layout == null &&
             ceqc.producer == null && ceqc.consumer == null;
    if ($cast(aeqc, body))
      return aeqc.aeq_h == null && aeqc.page_layout == null &&
             aeqc.producer == null && aeqc.consumer == null;
    return 1'b0;
  endfunction

  // 功能：克隆 body 外壳：先摘除引用再 clone，随后还原 source 并核对值不变。
  // 输入/输出及副作用：source 临时被改写后还原；saved_value 为 source 原值键；snapshot 输出克隆。
  // 失败/边界：引用捕获/还原、外壳保存、clone 契约或值一致性失败时以 failure_code 返回，snapshot 为 null。
  protected function rdma_status checked_outer_body_clone(
    rdma_hw_model source,
    string saved_value,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    uvm_object cloned_object;
    uvm_object saved_object;
    uvm_object_wrapper source_wrapper;
    rdma_hw_model saved_body;
    string source_type_name;
    string saved_shell_value;
    uvm_object saved_references[$];

    snapshot = null;
    source_type_name = source.get_type_name();
    if (!clear_body_references(source, saved_references))
      return snapshot_failure(
        failure_code, {label, " body reference capture failed"}
      );
    source_wrapper = source.get_object_type();
    saved_object = (source_wrapper == null) ? null :
      source_wrapper.create_object({label, "_saved_shell"});
    if (saved_object == null || !$cast(saved_body, saved_object)) begin
      void'(restore_body_references(source, saved_references));
      return snapshot_failure(
        failure_code, {label, " body value capture failed"}
      );
    end
    saved_body.copy(source);
    saved_shell_value = body_value_key(saved_body);
    cloned_object = source.clone();
    source.copy(saved_body);
    if (!restore_body_references(source, saved_references)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body source restoration failed"}
      );
    end
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot clone contract failed"}
      );
    end
    if (body_value_key(source) != saved_value ||
        body_value_key(snapshot) != saved_shell_value ||
        !body_references_are_null(snapshot)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot changed its source value"}
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：校验并克隆 QPC model，其 handle/嵌套对象各自做受检克隆。
  // 输入/输出及副作用：source 只读；snapshot 输出克隆。
  // 失败/边界：下游校验或克隆失败时原样返回其 status。
  protected function rdma_status checked_qpc_snapshot(
    rdma_qpc_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    uvm_object nested_snapshot;
    rdma_status status;
    rdma_hw_model cloned_body;
    rdma_qpc_model cloned_qpc;
    rdma_handle qp_snapshot;
    rdma_handle pd_snapshot;
    rdma_handle send_cq_snapshot;
    rdma_handle recv_cq_snapshot;
    rdma_handle srq_snapshot;
    rdma_address_vector address_snapshot;
    rdma_qpc_behavior behavior_snapshot;
    rdma_qpc_transport_ext transport_snapshot;
    string saved_value;

    snapshot = null;
    saved_value = body_value_key(source);
    status = rdma_cmq_checked_handle_snapshot(source.qp_h, {label, " QPC QP"},
                                     failure_code, qp_snapshot);
    if (!status.ok()) return status;
    status = rdma_cmq_checked_handle_snapshot(source.pd_h, {label, " QPC PD"},
                                     failure_code, pd_snapshot);
    if (!status.ok()) return status;
    status = rdma_cmq_checked_handle_snapshot(
      source.send_cq_h, {label, " QPC send CQ"}, failure_code,
      send_cq_snapshot
    );
    if (!status.ok()) return status;
    status = rdma_cmq_checked_handle_snapshot(
      source.recv_cq_h, {label, " QPC receive CQ"}, failure_code,
      recv_cq_snapshot
    );
    if (!status.ok()) return status;
    srq_snapshot = null;
    if (source.srq_h != null) begin
      status = rdma_cmq_checked_handle_snapshot(source.srq_h, {label, " QPC SRQ"},
                                       failure_code, srq_snapshot);
      if (!status.ok()) return status;
    end
    status = checked_nested_snapshot(
      source.address_vector, {label, " QPC address vector"}, failure_code,
      nested_snapshot
    );
    if (!status.ok() || !$cast(address_snapshot, nested_snapshot))
      return status.ok() ? snapshot_failure(
        failure_code, {label, " QPC address snapshot is invalid"}
      ) : status;
    status = checked_nested_snapshot(
      source.behavior, {label, " QPC behavior"}, failure_code,
      nested_snapshot
    );
    if (!status.ok() || !$cast(behavior_snapshot, nested_snapshot))
      return status.ok() ? snapshot_failure(
        failure_code, {label, " QPC behavior snapshot is invalid"}
      ) : status;
    status = checked_transport_snapshot(
      source.transport_ext, label, failure_code, transport_snapshot
    );
    if (!status.ok()) return status;
    status = checked_outer_body_clone(
      source, saved_value, label, failure_code, cloned_body
    );
    if (!status.ok()) return status;
    if (!$cast(cloned_qpc, cloned_body))
      return snapshot_failure(failure_code,
                              {label, " QPC body snapshot is invalid"});
    cloned_qpc.qp_h = qp_snapshot;
    cloned_qpc.pd_h = pd_snapshot;
    cloned_qpc.send_cq_h = send_cq_snapshot;
    cloned_qpc.recv_cq_h = recv_cq_snapshot;
    cloned_qpc.srq_h = srq_snapshot;
    cloned_qpc.address_vector = address_snapshot;
    cloned_qpc.behavior = behavior_snapshot;
    cloned_qpc.transport_ext = transport_snapshot;
    snapshot = cloned_qpc;
    if (!body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " QPC snapshot aliases its source"});
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " QPC validation returned null"});
    end
    if (!status.ok()) snapshot = null;
    return status;
  endfunction

  // 功能：校验并克隆 context model（handle 与嵌套对象各自受检克隆）。
  // 输入/输出及副作用：source 只读；snapshot 输出克隆。
  // 失败/边界：下游校验或克隆失败时原样返回其 status。
  protected function rdma_status checked_context_snapshot(
    rdma_hw_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    rdma_status status;
    rdma_hw_model cloned_body;
    rdma_handle handle0_snapshot;
    rdma_handle handle1_snapshot;
    uvm_object nested0_snapshot;
    uvm_object nested1_snapshot;
    uvm_object nested2_snapshot;
    rdma_page_table_layout page_snapshot;
    rdma_mr_page_layout mr_page_snapshot;
    rdma_ring_position ring0_snapshot;
    rdma_ring_position ring1_snapshot;
    rdma_cqc_model source_cqc;
    rdma_cqc_model cloned_cqc;
    rdma_mrt_model source_mrt;
    rdma_mrt_model cloned_mrt;
    rdma_srqc_model source_srqc;
    rdma_srqc_model cloned_srqc;
    rdma_ceqc_model source_ceqc;
    rdma_ceqc_model cloned_ceqc;
    rdma_aeqc_model source_aeqc;
    rdma_aeqc_model cloned_aeqc;
    string saved_value;

    snapshot = null;
    handle0_snapshot = null;
    handle1_snapshot = null;
    nested0_snapshot = null;
    nested1_snapshot = null;
    nested2_snapshot = null;
    saved_value = body_value_key(source);
    if ($cast(source_cqc, source)) begin
      status = rdma_cmq_checked_handle_snapshot(source_cqc.cq_h,
                                       {label, " CQC CQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      if (source_cqc.ceq_h != null) begin
        status = rdma_cmq_checked_handle_snapshot(source_cqc.ceq_h,
                                         {label, " CQC CEQ"}, failure_code,
                                         handle1_snapshot);
        if (!status.ok()) return status;
      end
      status = checked_nested_snapshot(source_cqc.page_layout,
                                       {label, " CQC page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_cqc.producer,
                                       {label, " CQC producer"},
                                       failure_code, nested1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_cqc.consumer,
                                       {label, " CQC consumer"},
                                       failure_code, nested2_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_mrt, source)) begin
      status = rdma_cmq_checked_handle_snapshot(source_mrt.mr_h,
                                       {label, " MRT MR"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = rdma_cmq_checked_handle_snapshot(source_mrt.pd_h,
                                       {label, " MRT PD"}, failure_code,
                                       handle1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_mrt.page_layout,
                                       {label, " MRT page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_srqc, source)) begin
      status = rdma_cmq_checked_handle_snapshot(source_srqc.srq_h,
                                       {label, " SRQC SRQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = rdma_cmq_checked_handle_snapshot(source_srqc.pd_h,
                                       {label, " SRQC PD"}, failure_code,
                                       handle1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_srqc.producer,
                                       {label, " SRQC producer"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_ceqc, source)) begin
      status = rdma_cmq_checked_handle_snapshot(source_ceqc.ceq_h,
                                       {label, " CEQC CEQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_ceqc.page_layout,
                                       {label, " CEQC page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_ceqc.producer,
                                       {label, " CEQC producer"},
                                       failure_code, nested1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_ceqc.consumer,
                                       {label, " CEQC consumer"},
                                       failure_code, nested2_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_aeqc, source)) begin
      status = rdma_cmq_checked_handle_snapshot(source_aeqc.aeq_h,
                                       {label, " AEQC AEQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_aeqc.page_layout,
                                       {label, " AEQC page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_aeqc.producer,
                                       {label, " AEQC producer"},
                                       failure_code, nested1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_aeqc.consumer,
                                       {label, " AEQC consumer"},
                                       failure_code, nested2_snapshot);
      if (!status.ok()) return status;
    end
    else begin
      return snapshot_failure(failure_code,
                              {label, " context type is unsupported"});
    end
    status = checked_outer_body_clone(source, saved_value, label,
                                      failure_code, cloned_body);
    if (!status.ok()) return status;
    if (source_cqc != null) begin
      if (!$cast(cloned_cqc, cloned_body) ||
          !$cast(page_snapshot, nested0_snapshot) ||
          !$cast(ring0_snapshot, nested1_snapshot) ||
          !$cast(ring1_snapshot, nested2_snapshot))
        return snapshot_failure(failure_code,
                                {label, " CQC snapshot type is invalid"});
      cloned_cqc.cq_h = handle0_snapshot;
      cloned_cqc.ceq_h = handle1_snapshot;
      cloned_cqc.page_layout = page_snapshot;
      cloned_cqc.producer = ring0_snapshot;
      cloned_cqc.consumer = ring1_snapshot;
    end
    else if (source_mrt != null) begin
      if (!$cast(cloned_mrt, cloned_body) ||
          !$cast(mr_page_snapshot, nested0_snapshot))
        return snapshot_failure(failure_code,
                                {label, " MRT snapshot type is invalid"});
      cloned_mrt.mr_h = handle0_snapshot;
      cloned_mrt.pd_h = handle1_snapshot;
      cloned_mrt.page_layout = mr_page_snapshot;
    end
    else if (source_srqc != null) begin
      if (!$cast(cloned_srqc, cloned_body) ||
          !$cast(ring0_snapshot, nested0_snapshot))
        return snapshot_failure(failure_code,
                                {label, " SRQC snapshot type is invalid"});
      cloned_srqc.srq_h = handle0_snapshot;
      cloned_srqc.pd_h = handle1_snapshot;
      cloned_srqc.producer = ring0_snapshot;
    end
    else if (source_ceqc != null) begin
      if (!$cast(cloned_ceqc, cloned_body) ||
          !$cast(page_snapshot, nested0_snapshot) ||
          !$cast(ring0_snapshot, nested1_snapshot) ||
          !$cast(ring1_snapshot, nested2_snapshot))
        return snapshot_failure(failure_code,
                                {label, " CEQC snapshot type is invalid"});
      cloned_ceqc.ceq_h = handle0_snapshot;
      cloned_ceqc.page_layout = page_snapshot;
      cloned_ceqc.producer = ring0_snapshot;
      cloned_ceqc.consumer = ring1_snapshot;
    end
    else begin
      if (!$cast(cloned_aeqc, cloned_body) ||
          !$cast(page_snapshot, nested0_snapshot) ||
          !$cast(ring0_snapshot, nested1_snapshot) ||
          !$cast(ring1_snapshot, nested2_snapshot))
        return snapshot_failure(failure_code,
                                {label, " AEQC snapshot type is invalid"});
      cloned_aeqc.aeq_h = handle0_snapshot;
      cloned_aeqc.page_layout = page_snapshot;
      cloned_aeqc.producer = ring0_snapshot;
      cloned_aeqc.consumer = ring1_snapshot;
    end
    snapshot = cloned_body;
    if (!body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " context snapshot aliases its source"});
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " context validation returned null"});
    end
    if (!status.ok()) snapshot = null;
    return status;
  endfunction

  // 功能：经 profile 的 body 快照 seam 克隆 body 并核对类型一致。
  // 输入/输出及副作用：source 只读；snapshot 输出；staging_invariant_failed 标记 staging 不变量破坏。
  // 失败/边界：profile 缺失、快照契约失败时返回 INVALID_STATE/INVALID_ARGUMENT。
  protected function rdma_status checked_profile_body_snapshot(
    rdma_hw_model source,
    string label,
    output rdma_hw_model snapshot,
    output bit staging_invariant_failed
  );
    uvm_object_wrapper source_type;
    uvm_object_wrapper snapshot_type;
    rdma_status status;

    snapshot = null;
    if (profile == null)
      return invalid_argument({label, " body profile is unavailable"});
    source_type = source.get_object_type();
    if (source_type == null)
      return invalid_argument({label, " body dynamic type is unregistered"});
    status = profile.snapshot_command_body(source, snapshot);
    if (status == null) begin
      snapshot = null;
      staging_invariant_failed = 1'b1;
      return snapshot_failure(
        RDMA_SC_INVALID_STATE,
        {label, " body profile snapshot returned null status"}
      );
    end
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot_type = (snapshot == null) ? null : snapshot.get_object_type();
    if (snapshot == null || snapshot == source || snapshot_type == null ||
        snapshot_type != source_type ||
        !profile.same_command_body_value(source, snapshot) ||
        !profile.command_body_graph_detached(source, snapshot)) begin
      snapshot = null;
      staging_invariant_failed = 1'b1;
      return snapshot_failure(
        RDMA_SC_INVALID_STATE,
        {label, " body profile snapshot contract failed"}
      );
    end
    status = snapshot.validate();
    if (status == null || !status.ok()) begin
      snapshot = null;
      staging_invariant_failed = 1'b1;
      return snapshot_failure(
        RDMA_SC_INVALID_STATE,
        {label, " body profile snapshot validation failed"}
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：克隆 command body 并核对 opcode/command_id/flags 等保持不变。
  // 输入/输出及副作用：source 只读；snapshot 输出；staging_invariant_failed 标记不变量破坏。
  // 失败/边界：校验或克隆失败返回 INVALID_ARGUMENT 等非 OK 状态。
  protected function rdma_status checked_body_snapshot(
    rdma_hw_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot,
    output bit staging_invariant_failed
  );
    rdma_status status;
    rdma_hw_model cloned_body;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model cloned_sqe;
    rdma_qpc_model source_qpc;
    rdma_cqc_model source_cqc;
    rdma_mrt_model source_mrt;
    rdma_srqc_model source_srqc;
    rdma_ceqc_model source_ceqc;
    rdma_aeqc_model source_aeqc;
    rdma_function_handle function_snapshot;
    rdma_handle target_snapshot;
    rdma_hw_model context_snapshot;
    rdma_cmq_opcode_e saved_opcode;
    longint unsigned saved_command_id;
    int unsigned saved_flags;
    string saved_body_value;

    snapshot = null;
    staging_invariant_failed = 1'b0;
    if (source == null)
      return snapshot_failure(failure_code, {label, " body is null"});
    status = source.validate();
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " body validation returned null"}
      );
    if (!status.ok())
      return status;
    if (!rdma_cmq_core_body_shell_is_exact(source))
      return checked_profile_body_snapshot(
        source, label, snapshot, staging_invariant_failed
      );
    if (!rdma_cmq_has_exact_object_type(source,
                               rdma_cmq_sqe_model::get_type())) begin
      if (rdma_cmq_has_exact_object_type(source, rdma_qpc_model::get_type()) &&
          $cast(source_qpc, source))
        return checked_qpc_snapshot(
          source_qpc, label, failure_code, snapshot
        );
      if ((rdma_cmq_has_exact_object_type(source, rdma_cqc_model::get_type()) &&
           $cast(source_cqc, source)) ||
          (rdma_cmq_has_exact_object_type(source, rdma_mrt_model::get_type()) &&
           $cast(source_mrt, source)) ||
          (rdma_cmq_has_exact_object_type(source, rdma_srqc_model::get_type()) &&
           $cast(source_srqc, source)) ||
          (rdma_cmq_has_exact_object_type(source, rdma_ceqc_model::get_type()) &&
           $cast(source_ceqc, source)) ||
          (rdma_cmq_has_exact_object_type(source, rdma_aeqc_model::get_type()) &&
           $cast(source_aeqc, source)))
        return checked_context_snapshot(
          source, label, failure_code, snapshot
        );
      return invalid_argument({label, " body exact type is unsupported"});
    end
    if (!$cast(source_sqe, source))
      return invalid_argument({label, " SQE body dynamic type is invalid"});
    begin
      saved_body_value = body_value_key(source);
      saved_opcode = source_sqe.opcode;
      saved_command_id = source_sqe.command_id;
      saved_flags = source_sqe.flags;
      status = rdma_cmq_checked_function_snapshot(
        source_sqe.function_h, {label, " body"}, failure_code,
        function_snapshot
      );
      if (!status.ok())
        return status;
      target_snapshot = null;
      if (source_sqe.target_h != null) begin
        status = rdma_cmq_checked_handle_snapshot(
          source_sqe.target_h, {label, " body target"}, failure_code,
          target_snapshot
        );
        if (!status.ok())
          return status;
      end
      context_snapshot = null;
      if (source_sqe.context_model != null) begin
        status = checked_body_snapshot(
          source_sqe.context_model, {label, " body context"}, failure_code,
          context_snapshot, staging_invariant_failed
        );
        if (!status.ok())
          return status;
      end
    end
    status = checked_outer_body_clone(
      source, saved_body_value, label, failure_code, cloned_body
    );
    if (!status.ok())
      return status;
    if (!$cast(cloned_sqe, cloned_body))
      return snapshot_failure(
        failure_code, {label, " body snapshot type is invalid"}
      );
    if (source_sqe.opcode != saved_opcode ||
        source_sqe.command_id != saved_command_id ||
        source_sqe.flags != saved_flags) begin
      return snapshot_failure(
        failure_code, {label, " body snapshot changed its source value"}
      );
    end
    cloned_sqe.function_h = function_snapshot;
    cloned_sqe.target_h = target_snapshot;
    cloned_sqe.context_model = context_snapshot;
    snapshot = cloned_sqe;
    if (!body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot aliases its source"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 功能：经 profile 克隆 completion payload 并核对快照契约。
  // 输入/输出及副作用：source 只读；snapshot 输出克隆。
  // 失败/边界：profile 不可用、payload 为 null 或快照契约失败时返回非 OK。
  protected function rdma_status checked_completion_payload_snapshot(
    uvm_object source,
    output uvm_object snapshot
  );
    uvm_object_wrapper source_type;
    uvm_object_wrapper snapshot_type;
    rdma_status status;

    snapshot = null;
    if (profile == null)
      return invalid_state("CMQ completion payload profile is unavailable");
    if (source == null)
      return invalid_state("CMQ completion payload is null");
    source_type = source.get_object_type();
    if (source_type == null)
      return invalid_state(
        "CMQ completion payload dynamic type is unregistered"
      );
    status = profile.snapshot_completion_payload(source, snapshot);
    if (status == null) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion payload snapshot returned null status"
      );
    end
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot_type = (snapshot == null) ? null : snapshot.get_object_type();
    if (snapshot == null || snapshot == source || snapshot_type == null ||
        snapshot_type != source_type ||
        !profile.same_completion_payload_value(source, snapshot) ||
        !profile.completion_payload_graph_detached(source, snapshot)) begin
      snapshot = null;
      return invalid_state("CMQ completion payload snapshot contract failed");
    end
    if (!profile.same_completion_payload_value(source, snapshot) ||
        !profile.completion_payload_graph_detached(source, snapshot)) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion payload final snapshot contract failed"
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：经 factory 候选与 nested clone 契约复制 completion ticket，再直接构造 exact base ticket，
  //  使 runtime factory override 不泄漏进 retained-journal snapshot。
  // 输入/输出及副作用：source 只读；snapshot 入口清空，成功时为与 source/候选无别名的 canonical 值；
  //  不更新 slot、journal 或 token。
  // 失败/边界：authority 缺失、factory 失败、Function/CMQ/opcode clone 为 null/自身/变值、source 被改写
  //  或 validate/shape 失败时返回 INVALID_STATE，不发布 partial snapshot。
  protected function rdma_status checked_completion_ticket_snapshot(
    rdma_cmq_ticket source,
    output rdma_cmq_ticket snapshot
  );
    rdma_status status;
    rdma_cmq_ticket factory_snapshot;
    rdma_cmq_ticket canonical_snapshot;
    longint unsigned saved_command_id;
    longint unsigned saved_slot_sequence;
    int unsigned saved_sq_index;
    bit saved_sq_wrap;
    time saved_absolute_deadline;

    snapshot = null;
    if (source == null || source.function_h == null ||
        source.cmq_h == null || source.opcode_key == null)
      return invalid_state("CMQ completion ticket authority is incomplete");
    saved_command_id = source.command_id;
    saved_slot_sequence = source.slot_sequence;
    saved_sq_index = source.sq_index;
    saved_sq_wrap = source.sq_wrap;
    saved_absolute_deadline = source.absolute_deadline;
    factory_snapshot = rdma_cmq_ticket::type_id::create(
      "cmq_polled_completion_ticket"
    );
    if (factory_snapshot == null)
      return invalid_state("CMQ completion ticket construction failed");
    factory_snapshot.command_id = saved_command_id;
    status = rdma_cmq_checked_function_snapshot(
      source.function_h, "CMQ completion ticket", RDMA_SC_INVALID_STATE,
      factory_snapshot.function_h
    );
    if (status.ok())
      status = rdma_cmq_checked_handle_snapshot(
        source.cmq_h, "CMQ completion ticket", RDMA_SC_INVALID_STATE,
        factory_snapshot.cmq_h
      );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    factory_snapshot.slot_sequence = saved_slot_sequence;
    factory_snapshot.sq_index = saved_sq_index;
    factory_snapshot.sq_wrap = saved_sq_wrap;
    status = rdma_cmq_checked_opcode_snapshot(
      source.opcode_key, "CMQ completion ticket", RDMA_SC_INVALID_STATE,
      factory_snapshot.opcode_key
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    factory_snapshot.absolute_deadline = saved_absolute_deadline;
    if (source.command_id != saved_command_id ||
        source.slot_sequence != saved_slot_sequence ||
        source.sq_index != saved_sq_index || source.sq_wrap != saved_sq_wrap ||
        source.absolute_deadline != saved_absolute_deadline) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion ticket snapshot changed its source value"
      );
    end
    status = factory_snapshot.validate();
    if (status == null || !status.ok()) begin
      snapshot = null;
      return invalid_state("CMQ completion ticket snapshot validation failed");
    end
    canonical_snapshot = new("cmq_polled_completion_ticket_canonical");
    canonical_snapshot.command_id = factory_snapshot.command_id;
    canonical_snapshot.function_h = factory_snapshot.function_h;
    canonical_snapshot.cmq_h = factory_snapshot.cmq_h;
    canonical_snapshot.slot_sequence = factory_snapshot.slot_sequence;
    canonical_snapshot.sq_index = factory_snapshot.sq_index;
    canonical_snapshot.sq_wrap = factory_snapshot.sq_wrap;
    canonical_snapshot.opcode_key = factory_snapshot.opcode_key;
    canonical_snapshot.absolute_deadline = factory_snapshot.absolute_deadline;
    if (!rdma_cmq_ticket_shape_valid(canonical_snapshot) ||
        !same_ticket_value(canonical_snapshot, source) ||
        canonical_snapshot.function_h == source.function_h ||
        canonical_snapshot.cmq_h == source.cmq_h ||
        canonical_snapshot.opcode_key == source.opcode_key) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion ticket canonical value is invalid"
      );
    end
    snapshot = canonical_snapshot;
    return rdma_status::success();
  endfunction

  // 功能：expected-response snapshot 的 engine ABI，转发共享 typed contract，供 staging 与测试子类调用。
  // 输入/输出及副作用：参数原样转发；engine 不保存状态，输出清空、clone、恢复 source 由共享 helper 完成。
  // 失败/边界：校验、clone 契约、mutation latch 与消息优先级均由共享 helper 保持。
  protected function rdma_status checked_expected_snapshot(
    rdma_cmq_expected_response source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_cmq_expected_response snapshot
  );
    return rdma_cmq_checked_expected_snapshot(
      source, label, failure_code, snapshot
    );
  endfunction

  // 功能：逐层验证 command shell/body/signature 的 clone 契约，并把 signature 重建为 journal digest
  //  可接受的 exact image。
  // 输入/输出及副作用：source 只读；snapshot 成功时输出完整 detached 图；staging_invariant_failed
  //  仅标识 body profile 契约故障；不转移 caller body/image 所有权。
  // 失败/边界：null、Function/opcode/body/signature clone 为 null/自身/变值、signature 形状非法或
  //  validate 失败时不发布 partial snapshot；factory override 的派生 image 不得泄漏进 journal。
  protected function rdma_status snapshot_command_value(
    rdma_cmq_command_desc source,
    output rdma_cmq_command_desc snapshot,
    output bit staging_invariant_failed
  );
    rdma_status status;
    uvm_object cloned_object;
    rdma_cmq_command_desc cloned_command;
    rdma_function_handle function_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_hw_model body_snapshot;
    rdma_hw_image signature_snapshot;
    rdma_function_handle saved_function_source;
    rdma_cmq_opcode_key saved_opcode_source;
    rdma_hw_model saved_body_source;
    rdma_hw_image saved_signature_source;
    string source_type_name;
    bit saved_vfid_override;
    bit [10:0] saved_use_vfid;
    time saved_timeout;
    bit root_source_changed_during_clone;

    snapshot = null;
    staging_invariant_failed = 1'b0;
    if (source == null)
      return invalid_argument("CMQ command is null");
    saved_function_source = source.function_h;
    saved_opcode_source = source.opcode_key;
    saved_body_source = source.body;
    saved_signature_source = source.qpc_signature_source;
    source_type_name = source.get_type_name();
    saved_vfid_override = source.vfid_override;
    saved_use_vfid = source.use_vfid;
    saved_timeout = source.timeout;
    status = rdma_cmq_checked_function_snapshot(
      source.function_h, "CMQ command", RDMA_SC_INVALID_ARGUMENT,
      function_snapshot
    );
    if (!status.ok())
      return status;
    status = rdma_cmq_checked_opcode_snapshot(
      source.opcode_key, "CMQ command", RDMA_SC_INVALID_ARGUMENT,
      opcode_snapshot
    );
    if (!status.ok())
      return status;
    status = checked_body_snapshot(
      source.body, "CMQ command", RDMA_SC_INVALID_ARGUMENT, body_snapshot,
      staging_invariant_failed
    );
    if (!status.ok())
      return status;
    signature_snapshot = null;
    if (source.qpc_signature_source != null) begin
      status = rdma_cmq_checked_canonical_image_snapshot(
        source.qpc_signature_source, "CMQ command signature",
        RDMA_SC_INVALID_ARGUMENT, signature_snapshot
      );
      if (!status.ok())
        return status;
    end

    source.function_h = null;
    source.opcode_key = null;
    source.body = null;
    source.qpc_signature_source = null;
    cloned_object = source.clone();
    root_source_changed_during_clone =
      source.function_h != null || source.opcode_key != null ||
      source.body != null || source.qpc_signature_source != null ||
      source.vfid_override != saved_vfid_override ||
      source.use_vfid != saved_use_vfid || source.timeout != saved_timeout;
    source.function_h = saved_function_source;
    source.opcode_key = saved_opcode_source;
    source.body = saved_body_source;
    source.qpc_signature_source = saved_signature_source;
    source.vfid_override = saved_vfid_override;
    source.use_vfid = saved_use_vfid;
    source.timeout = saved_timeout;
    if (cloned_object == null || !$cast(cloned_command, cloned_object) ||
        cloned_command == source ||
        cloned_command.get_type_name() != source_type_name) begin
      return invalid_argument("CMQ command snapshot clone contract failed");
    end
    if (root_source_changed_during_clone ||
        cloned_command.function_h != null ||
        cloned_command.opcode_key != null ||
        cloned_command.body != null ||
        cloned_command.qpc_signature_source != null ||
        cloned_command.vfid_override != saved_vfid_override ||
        cloned_command.use_vfid != saved_use_vfid ||
        cloned_command.timeout != saved_timeout ||
        !same_handle(source.function_h, function_snapshot) ||
        !same_opcode_value(source.opcode_key, opcode_snapshot) ||
        ((source.qpc_signature_source == null) !=
         (signature_snapshot == null)) ||
        (signature_snapshot != null &&
         (!same_image_value(source.qpc_signature_source,
                            signature_snapshot)))) begin
      return invalid_argument("CMQ command snapshot changed its source value");
    end

    if (!same_body_value(source.body, body_snapshot) ||
        !body_graph_detached(source.body, body_snapshot)) begin
      staging_invariant_failed = 1'b1;
      return invalid_state(
        "CMQ command body snapshot violated its final staging contract"
      );
    end

    snapshot = cloned_command;
    snapshot.function_h = function_snapshot;
    snapshot.opcode_key = opcode_snapshot;
    snapshot.body = body_snapshot;
    snapshot.qpc_signature_source = signature_snapshot;
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return invalid_state("CMQ command validation returned null status");
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 功能：复制 DMA mapping 并核对 clone 契约与公开字段不变。
  // 输入/输出及副作用：source 只读；name 为新对象名；snapshot 输出。
  // 失败/边界：source 为 null、值捕获、clone 契约或字段一致性失败时返回 INVALID_STATE。
  protected function rdma_status make_mapping_snapshot(
    rdma_dma_mapping source,
    string name,
    output rdma_dma_mapping snapshot
  );
    rdma_status status;
    uvm_object cloned_object;
    rdma_dma_mapping saved_value;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ dependency mapping source is null");
    saved_value = rdma_dma_mapping::type_id::create({name, "_saved"});
    if (saved_value == null)
      return invalid_state("CMQ dependency mapping value capture failed");
    status = rdma_cmq_checked_function_snapshot(
      source.function_h, "CMQ dependency mapping", RDMA_SC_INVALID_STATE,
      saved_value.function_h
    );
    if (!status.ok()) begin
      return status;
    end
    status = rdma_cmq_checked_handle_snapshot(
      source.owner_h, "CMQ dependency mapping owner", RDMA_SC_INVALID_STATE,
      saved_value.owner_h
    );
    if (!status.ok()) begin
      return status;
    end
    saved_value.requester_bdf = source.requester_bdf;
    saved_value.pasid_valid = source.pasid_valid;
    saved_value.pasid = source.pasid;
    saved_value.dma_domain_valid = source.dma_domain_valid;
    saved_value.dma_domain_id = source.dma_domain_id;
    saved_value.backing_addr = source.backing_addr;
    saved_value.iova = source.iova;
    saved_value.size = source.size;
    saved_value.direction = source.direction;
    saved_value.permissions = source.permissions;
    saved_value.state = source.state;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ dependency mapping clone contract failed");
    end
    if (!same_mapping_value(source, saved_value) ||
        !same_mapping_value(snapshot, saved_value) ||
        snapshot.function_h == source.function_h ||
        snapshot.owner_h == source.owner_h) begin
      snapshot = null;
      return invalid_state("CMQ dependency mapping snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  // 功能：先经 UVM factory 构造并 clone 候选 ticket（使测试可观测 factory/clone 故障），通过后再直接
  //  构造 exact rdma_cmq_ticket 作为 journal digest 可接受的 canonical 值。
  // 输入/输出及副作用：command_id、handle、slot_sequence、SQ 位置、opcode_key、deadline 为输入；
  //  ticket 先清空，成功时与输入及候选均无别名，不改写输入。
  // 失败/边界：factory、nested 快照、validate/clone 契约、canonical 快照或形状任一失败返回
  //  INVALID_STATE；已武装 clone-self 故障在 canonicalization 前消费；不发布部分 ticket。
  protected function rdma_status make_ticket_value(
    string name,
    longint unsigned command_id,
    rdma_function_handle function_h,
    rdma_handle cmq_h,
    longint unsigned slot_sequence,
    int unsigned sq_index,
    bit sq_wrap,
    rdma_cmq_opcode_key opcode_key,
    time absolute_deadline,
    output rdma_cmq_ticket ticket
  );
    rdma_status status;
    rdma_cmq_ticket detached_ticket;
    rdma_cmq_ticket canonical_ticket;
    rdma_handle function_snapshot_base;
    rdma_handle cmq_snapshot;
    rdma_function_handle function_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;

    ticket = rdma_cmq_ticket::type_id::create(name);
    if (ticket == null)
      return invalid_state("CMQ ticket construction failed");
    ticket.command_id = command_id;
    status = rdma_cmq_checked_function_snapshot(
      function_h, "CMQ ticket", RDMA_SC_INVALID_STATE, ticket.function_h
    );
    if (status.ok())
      status = rdma_cmq_checked_handle_snapshot(
        cmq_h, "CMQ ticket", RDMA_SC_INVALID_STATE, ticket.cmq_h
      );
    if (!status.ok()) begin
      ticket = null;
      return status;
    end
    ticket.slot_sequence = slot_sequence;
    ticket.sq_index = sq_index;
    ticket.sq_wrap = sq_wrap;
    status = rdma_cmq_checked_opcode_snapshot(
      opcode_key, "CMQ ticket", RDMA_SC_INVALID_STATE, ticket.opcode_key
    );
    if (!status.ok()) begin
      ticket = null;
      return status;
    end
    ticket.absolute_deadline = absolute_deadline;
    status = ticket.validate();
    if (status == null || !status.ok()) begin
      ticket = null;
      return invalid_state("CMQ ticket validation failed");
    end
    if (!rdma_deep_copy#(rdma_cmq_ticket)::try_of(ticket, detached_ticket) ||
        !same_ticket_value(detached_ticket, ticket) ||
        detached_ticket.function_h == ticket.function_h ||
        detached_ticket.cmq_h == ticket.cmq_h ||
        detached_ticket.opcode_key == ticket.opcode_key) begin
      ticket = null;
      return invalid_state("CMQ ticket snapshot clone contract failed");
    end
    if (!rdma_cmq_try_snapshot_handle_direct(
          detached_ticket.function_h, 1'b0, function_snapshot_base
        ) || !$cast(function_snapshot, function_snapshot_base) ||
        !rdma_cmq_try_snapshot_handle_direct(
          detached_ticket.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_opcode_key_direct(
          detached_ticket.opcode_key, opcode_snapshot
        )) begin
      ticket = null;
      return invalid_state("CMQ ticket canonical snapshot failed");
    end
    canonical_ticket = new({name, "_canonical"});
    canonical_ticket.command_id = detached_ticket.command_id;
    canonical_ticket.function_h = function_snapshot;
    canonical_ticket.cmq_h = cmq_snapshot;
    canonical_ticket.slot_sequence = detached_ticket.slot_sequence;
    canonical_ticket.sq_index = detached_ticket.sq_index;
    canonical_ticket.sq_wrap = detached_ticket.sq_wrap;
    canonical_ticket.opcode_key = opcode_snapshot;
    canonical_ticket.absolute_deadline = detached_ticket.absolute_deadline;
    if (!rdma_cmq_ticket_shape_valid(canonical_ticket) ||
        !same_ticket_value(canonical_ticket, detached_ticket)) begin
      ticket = null;
      return invalid_state("CMQ ticket canonical value is invalid");
    end
    ticket = canonical_ticket;
    return rdma_status::success();
  endfunction

  // 功能：校验并克隆 slot context，核对 Function/CMQ handle 身份与字段值不变。
  // 输入/输出及副作用：source 只读；snapshot 输出克隆。
  // 失败/边界：source 为空、clone 为 null/自身、handle 经 same_handle 身份漂移、值改变或保留 alias
  //  时返回 INVALID_STATE。
  protected function rdma_status checked_slot_context_snapshot(
    rdma_cmq_slot_context source,
    output rdma_cmq_slot_context snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ slot context source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ slot context snapshot clone contract failed");
    end
    if (snapshot.function_h == null || source.function_h == null ||
        !same_handle(snapshot.function_h, source.function_h) ||
        snapshot.cmq_h == null || source.cmq_h == null ||
        !same_handle(snapshot.cmq_h, source.cmq_h) ||
        snapshot.backing_addr.value != source.backing_addr.value ||
        snapshot.relative_offset != source.relative_offset ||
        snapshot.slot_sequence != source.slot_sequence ||
        snapshot.sq_index != source.sq_index ||
        snapshot.sq_wrap != source.sq_wrap ||
        snapshot.function_h == source.function_h ||
        snapshot.cmq_h == source.cmq_h) begin
      snapshot = null;
      return invalid_state("CMQ slot context snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  // 功能：先验证 factory slot record 的 clone 契约，再直接重建 exact slot record/ticket/expected，
  //  供预分配发布。
  // 输入/输出及副作用：source 只读；snapshot 先清空，成功时与 source/factory clone 均无别名。
  // 失败/边界：source/ticket/expected 不完整、clone 为 null/自身/变值、嵌套快照失败或 canonical
  //  不等值时返回 INVALID_STATE；clone-self 故障在重建前可观测，不发布部分图。
  protected function rdma_status checked_record_snapshot(
    rdma_cmq_slot_record source,
    output rdma_cmq_slot_record snapshot
  );
    rdma_cmq_slot_record factory_snapshot;
    rdma_cmq_slot_record canonical_snapshot;
    rdma_cmq_ticket canonical_ticket;
    rdma_cmq_expected_response canonical_expected;
    rdma_handle function_snapshot_base;
    rdma_handle cmq_snapshot;
    rdma_function_handle function_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_status status;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ slot record source is null");
    if (!rdma_deep_copy#(rdma_cmq_slot_record)::try_of(source, factory_snapshot)) begin
      snapshot = null;
      return invalid_state("CMQ slot record snapshot clone contract failed");
    end
    if (factory_snapshot.slot_sequence != source.slot_sequence ||
        factory_snapshot.sq_index != source.sq_index ||
        factory_snapshot.sq_wrap != source.sq_wrap ||
        factory_snapshot.state != source.state ||
        factory_snapshot.command_token != source.command_token ||
        factory_snapshot.batch_key != source.batch_key ||
        factory_snapshot.journal_item_index != source.journal_item_index ||
        !same_ticket_value(factory_snapshot.ticket, source.ticket) ||
        !same_expected_value(factory_snapshot.expected, source.expected) ||
        factory_snapshot.ticket == source.ticket ||
        factory_snapshot.expected == source.expected) begin
      snapshot = null;
      return invalid_state("CMQ slot record snapshot changed value");
    end
    if (!rdma_cmq_try_snapshot_handle_direct(
          factory_snapshot.ticket.function_h, 1'b0, function_snapshot_base
        ) || !$cast(function_snapshot, function_snapshot_base) ||
        !rdma_cmq_try_snapshot_handle_direct(
          factory_snapshot.ticket.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_opcode_key_direct(
          factory_snapshot.ticket.opcode_key, opcode_snapshot
        )) begin
      return invalid_state("CMQ slot record ticket canonical snapshot failed");
    end
    canonical_ticket = new("cmq_slot_record_canonical_ticket");
    canonical_ticket.command_id = factory_snapshot.ticket.command_id;
    canonical_ticket.function_h = function_snapshot;
    canonical_ticket.cmq_h = cmq_snapshot;
    canonical_ticket.slot_sequence = factory_snapshot.ticket.slot_sequence;
    canonical_ticket.sq_index = factory_snapshot.ticket.sq_index;
    canonical_ticket.sq_wrap = factory_snapshot.ticket.sq_wrap;
    canonical_ticket.opcode_key = opcode_snapshot;
    canonical_ticket.absolute_deadline =
      factory_snapshot.ticket.absolute_deadline;
    canonical_expected = new("cmq_slot_record_canonical_expected");
    canonical_expected.hardware_opcode =
      factory_snapshot.expected.hardware_opcode;
    canonical_expected.variant = factory_snapshot.expected.variant;
    status = canonical_expected.validate();
    if (!rdma_cmq_ticket_shape_valid(canonical_ticket) || status == null ||
        !status.ok() ||
        !same_ticket_value(canonical_ticket, factory_snapshot.ticket) ||
        !same_expected_value(canonical_expected, factory_snapshot.expected))
      return invalid_state("CMQ slot record canonical value is invalid");
    canonical_snapshot = new("cmq_slot_record_canonical_snapshot");
    canonical_snapshot.slot_sequence = factory_snapshot.slot_sequence;
    canonical_snapshot.sq_index = factory_snapshot.sq_index;
    canonical_snapshot.sq_wrap = factory_snapshot.sq_wrap;
    canonical_snapshot.state = factory_snapshot.state;
    canonical_snapshot.ticket = canonical_ticket;
    canonical_snapshot.expected = canonical_expected;
    canonical_snapshot.command_token = factory_snapshot.command_token;
    canonical_snapshot.batch_key = factory_snapshot.batch_key;
    canonical_snapshot.journal_item_index =
      factory_snapshot.journal_item_index;
    snapshot = canonical_snapshot;
    return rdma_status::success();
  endfunction

  // 功能：校验并克隆 doorbell dependency，核对值不变。
  // 输入/输出及副作用：source 只读；snapshot 输出克隆。
  // 失败/边界：source 为 null、clone 契约失败或值改变时返回 INVALID_STATE。
  protected function rdma_status checked_dependency_snapshot(
    rdma_doorbell_dependency source,
    output rdma_doorbell_dependency snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ dependency source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ dependency snapshot clone contract failed");
    end
    if (!same_dependency_value(snapshot, source) ||
        snapshot.mapping == source.mapping || snapshot.image == source.image) begin
      snapshot = null;
      return invalid_state("CMQ dependency snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  // 功能：校验并克隆 doorbell descriptor，核对 handle 身份与嵌套 dependency 值不变。
  // 输入/输出及副作用：source 只读；snapshot 输出克隆。
  // 失败/边界：source 为空、clone 为 null/自身、handle 身份漂移、字段或 dependency 值改变或保留
  //  alias 时返回 INVALID_STATE。
  protected function rdma_status checked_doorbell_desc_snapshot(
    rdma_doorbell_desc source,
    output rdma_doorbell_desc snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ doorbell descriptor source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state(
        "CMQ doorbell descriptor snapshot clone contract failed"
      );
    end
    if (snapshot.kind != source.kind ||
        snapshot.function_h == null || source.function_h == null ||
        !same_handle(snapshot.function_h, source.function_h) ||
        snapshot.target_h == null || source.target_h == null ||
        !same_handle(snapshot.target_h, source.target_h) ||
        snapshot.notify_bar_id != source.notify_bar_id ||
        snapshot.relative_offset != source.relative_offset ||
        snapshot.width != source.width || snapshot.endian != source.endian ||
        !same_image_value(snapshot.payload_image, source.payload_image) ||
        snapshot.barrier_policy != source.barrier_policy ||
        snapshot.write_combining_policy != source.write_combining_policy ||
        snapshot.allow_merge != source.allow_merge ||
        snapshot.merge_requested != source.merge_requested ||
        snapshot.timeout != source.timeout ||
        snapshot.readback_policy != source.readback_policy ||
        snapshot.dependencies.size() != source.dependencies.size() ||
        snapshot.function_h == source.function_h ||
        snapshot.target_h == source.target_h ||
        snapshot.payload_image == source.payload_image) begin
      snapshot = null;
      return invalid_state("CMQ doorbell descriptor snapshot changed value");
    end
    foreach (source.dependencies[i]) begin
      if (!same_dependency_value(snapshot.dependencies[i],
                                 source.dependencies[i]) ||
          snapshot.dependencies[i] == source.dependencies[i]) begin
        snapshot = null;
        return invalid_state(
          "CMQ doorbell descriptor dependency snapshot changed value"
        );
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：校验 profile 生成的 SQE image 元数据（长度、对齐、端序、generation、写目标）。
  // 输入/输出及副作用：image 只读；expected_backing_target 为期望 backing 地址。
  // 失败/边界：null 返回 INVALID_STATE；长度/对齐/元数据/目标不符返回 INVALID_ARGUMENT；generation 过期返回 STALE_GENERATION。
  protected function rdma_status sqe_metadata_status(
    rdma_hw_image image,
    longint unsigned expected_backing_target
  );
    if (image == null)
      return invalid_state("CMQ profile returned a null SQE");
    if (image.length != CMQE_BYTES || image.bytes.size() != CMQE_BYTES)
      return invalid_argument("CMQ SQE is not exactly 64 bytes");
    if (image.alignment != CMQE_BYTES)
      return invalid_argument("CMQ SQE alignment is not 64 bytes");
    if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}) ||
        image.hardware_version == 0)
      return invalid_argument("CMQ SQE metadata is incomplete");
    if (image.image_kind != RDMA_IMAGE_CMQ_SQE)
      return invalid_argument("CMQ profile image is not an SQE");
    if (image.function_generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION, "CMQ SQE Function generation is stale"
      );
    if (image.write_target_kind != RDMA_HW_TARGET_BACKING)
      return invalid_argument("CMQ SQE write target is not backing memory");
    if (image.hmc_target.value != 0 || image.bar_target.value != 0)
      return invalid_argument("CMQ SQE has an inactive write target");
    if (image.backing_target.value != expected_backing_target)
      return invalid_argument(
        "CMQ SQE backing target does not match compacted slot"
      );
    return rdma_status::success();
  endfunction

  // 功能：校验 doorbell image 元数据（长度、对齐、端序、generation、BAR 目标与 notify 范围）。
  // 输入/输出及副作用：image 只读；使用 prepared_binding 的 generation 与 notify_size。
  // 失败/边界：null 返回 INVALID_STATE；格式或目标越界返回 INVALID_ARGUMENT；generation 过期返回 STALE_GENERATION。
  protected function rdma_status doorbell_metadata_status(
    rdma_hw_image image
  );
    if (image == null)
      return invalid_state("CMQ profile returned a null doorbell image");
    if (image.length == 0 || image.bytes.size() != image.length)
      return invalid_argument("CMQ doorbell image length is invalid");
    if (image.alignment == 0 ||
        (image.alignment & (image.alignment - 1'b1)) != 0)
      return invalid_argument("CMQ doorbell image alignment is invalid");
    if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}) ||
        image.hardware_version == 0)
      return invalid_argument("CMQ doorbell metadata is incomplete");
    if (image.image_kind != RDMA_IMAGE_DOORBELL)
      return invalid_argument("CMQ profile image is not a doorbell");
    if (image.function_generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ doorbell Function generation is stale"
      );
    if (image.write_target_kind != RDMA_HW_TARGET_BAR)
      return invalid_argument("CMQ doorbell target is not a BAR");
    if (image.backing_target.value != 0 || image.hmc_target.value != 0)
      return invalid_argument("CMQ doorbell has an inactive write target");
    if ((image.bar_target.value & (image.alignment - 1'b1)) != 0)
      return invalid_argument("CMQ doorbell BAR target is misaligned");
    if (image.bar_target.value > prepared_binding.notify_size ||
        image.length >
          (prepared_binding.notify_size - image.bar_target.value))
      return invalid_argument(
        "CMQ doorbell target is outside the notify aperture"
      );
    return rdma_status::success();
  endfunction

  // 功能：由 request_context、cmq、mapping 构造 runtime descriptor（含 SQ/CQ IOVA 与深度）。
  // 输入/输出及副作用：三者只读；runtime 输出新对象。
  // 失败/边界：SQ 到 CQ 的 IOVA 加法溢出返回 DMA_TRANSLATION；构造失败或 status 为 null 返回 INVALID_STATE。
  protected virtual function rdma_status build_runtime_desc(
    rdma_dma_request_context request_context,
    rdma_cmq cmq,
    rdma_dma_mapping mapping,
    output rdma_cmq_runtime_desc runtime
  );
    rdma_status status;
    rdma_function_handle runtime_function;
    rdma_handle runtime_cmq;

    runtime = null;
    if (mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - CQ_OFFSET))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ SQ-to-CQ IOVA addition overflows"
      );
    runtime = rdma_cmq_runtime_desc::type_id::create(
      "cmq_runtime_candidate"
    );
    if (runtime == null)
      return invalid_state("CMQ runtime descriptor construction failed");
    status = clone_function_handle_fields(request_context.function_h,
                                          "cmq_runtime_function",
                                          runtime_function);
    if (status.ok())
      status = clone_handle_fields(cmq.handle, "cmq_runtime_cmq",
                                   runtime_cmq);
    if (!status.ok()) begin
      runtime = null;
      return status;
    end
    runtime.function_h = runtime_function;
    runtime.cmq_h = runtime_cmq;
    runtime.sq_iova = mapping.iova;
    runtime.cq_iova.value = mapping.iova.value + CQ_OFFSET;
    runtime.sq_depth = CMQ_DEPTH;
    runtime.cq_depth = CMQ_DEPTH;
    runtime.entry_bytes = CMQE_BYTES;
    runtime.initial_sq_valid = 1'b1;
    runtime.initial_cq_owner = 1'b1;
    runtime.initial_doorbell_polarity = 1'b0;
    status = runtime.validate();
    if (status == null) begin
      runtime = null;
      return invalid_state("CMQ runtime descriptor returned null status");
    end
    if (!status.ok())
      runtime = null;
    return status;
  endfunction

  // 功能：复制 runtime descriptor 为 detached 快照并校验。
  // 输入/输出及副作用：source 只读；snapshot 输出。
  // 失败/边界：source 为 null、构造失败或校验 status 为 null/失败时返回 INVALID_STATE 或校验错误。
  protected virtual function rdma_status publish_runtime_snapshot(
    rdma_cmq_runtime_desc source,
    output rdma_cmq_runtime_desc snapshot
  );
    rdma_status status;
    rdma_function_handle runtime_function;
    rdma_handle runtime_cmq;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ runtime snapshot source is null");
    snapshot = rdma_cmq_runtime_desc::type_id::create(
      "cmq_runtime_snapshot"
    );
    if (snapshot == null)
      return invalid_state("CMQ runtime snapshot construction failed");
    status = clone_function_handle_fields(source.function_h,
                                          "cmq_published_function",
                                          runtime_function);
    if (status.ok())
      status = clone_handle_fields(source.cmq_h, "cmq_published_cmq",
                                   runtime_cmq);
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot.function_h = runtime_function;
    snapshot.cmq_h = runtime_cmq;
    snapshot.sq_iova = source.sq_iova;
    snapshot.cq_iova = source.cq_iova;
    snapshot.sq_depth = source.sq_depth;
    snapshot.cq_depth = source.cq_depth;
    snapshot.entry_bytes = source.entry_bytes;
    snapshot.initial_sq_valid = source.initial_sq_valid;
    snapshot.initial_cq_owner = source.initial_cq_owner;
    snapshot.initial_doorbell_polarity =
      source.initial_doorbell_polarity;
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return invalid_state("CMQ runtime snapshot returned null status");
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 设计说明：journal 的公开/hostile-factory 路径须始终返回直接构造的 status；本 helper 只统一类别字段。
  // 功能：直接构造指定 code/message 的 journal status，绕开 raw UVM factory。
  // 输入/输出及副作用：code/message 只读；返回新 status。
  // 失败/边界：未知 code 由 rdma_cmq_direct_status 保守归类；始终非空。
  protected function rdma_status journal_status(
    rdma_status_code_e code,
    string message = ""
  );
    return rdma_cmq_direct_status(code, message);
  endfunction

  // 功能：DMA request context instance 比较 seam，转发共享契约。
  // 输入/输出及副作用：lhs/rhs 只读；比较 Function/owner incarnation 与 requester/route/epoch 等投影。
  // 失败/边界：null、Function 缺失或字段漂移返回 0；不做 validation 或 alias 判断。
  protected function bit same_journal_dma_context_value(
    rdma_dma_request_context lhs,
    rdma_dma_request_context rhs
  );
    return rdma_cmq_same_journal_dma_context_value(lhs, rhs);
  endfunction

  // 功能：mapping 公开值比较 seam，转发共享 journal 契约。
  // 输入/输出及副作用：lhs/rhs 只读；比较公开 authority/range/state、UMEM/PBL/MW 引用与 page metadata。
  // 失败/边界：null、Function 缺失或公开字段漂移返回 0；不比较私有 release authority。
  protected function bit same_journal_mapping_public_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    return rdma_cmq_same_journal_mapping_public_value(lhs, rhs);
  endfunction

  // 功能：直接复制 DMA request context 及两个嵌套 handle，使 journal 图拥有 detached 值。
  // 输入/输出及副作用：source 只读；snapshot 入口清空，成功发布新 context。
  // 失败/边界：null/未知 subtype、validate 或分离校验失败时返回 INVALID_ARGUMENT/null；不调用 clone/copy/factory。
  protected function rdma_status snapshot_journal_dma_context_locked(
    input rdma_dma_request_context source,
    output rdma_dma_request_context snapshot
  );
    rdma_dma_request_context candidate;
    rdma_handle function_snapshot_base;
    rdma_handle owner_snapshot;
    rdma_status status;

    snapshot = null;
    if (source == null ||
        source.get_object_type() != rdma_dma_request_context::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal DMA context is null or unsupported"
      );
    status = source.validate();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal DMA context validation returned null"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_handle_direct(
          source.owner_h, 1'b1, owner_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal DMA context nested snapshot failed"
      );

    candidate = new("journal_dma_context_snapshot");
    if (!$cast(candidate.function_h, function_snapshot_base))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal DMA Function snapshot subtype is invalid"
      );
    candidate.requester_bdf = source.requester_bdf;
    candidate.pasid_valid = source.pasid_valid;
    candidate.pasid = source.pasid;
    candidate.dma_domain_valid = source.dma_domain_valid;
    candidate.dma_domain_id = source.dma_domain_id;
    candidate.route = source.route;
    candidate.reset_epoch = source.reset_epoch;
    candidate.route_valid = source.route_valid;
    candidate.epoch_valid = source.epoch_valid;
    candidate.owner_h = owner_snapshot;
    candidate.queue_role_valid = source.queue_role_valid;
    candidate.queue_role = source.queue_role;
    if (!same_journal_dma_context_value(source, candidate) ||
        candidate.function_h == source.function_h ||
        (source.owner_h != null && candidate.owner_h == source.owner_h))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal DMA context snapshot is unequal or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 设计说明：adapter 私有 allocation identity 不能由 engine 猜测；先取 opaque release-authority
  //  subtype，再显式覆盖全部公开投影。
  // 功能：经 adapter seam 复制 mapping 私有 authority，并直接复制公开字段/handle。
  // 输入/输出及副作用：source 非拥有；snapshot 入口清空；adapter seam 仅做 snapshot/equivalence 查询。
  // 失败/边界：seam null/error、自别名/错误 subtype、handle 或公开值校验失败时返回错误与 null；
  //  不降级为 base mapping。
  protected function rdma_status snapshot_journal_mapping_locked(
    input rdma_dma_mapping source,
    output rdma_dma_mapping snapshot
  );
    rdma_dma_mapping candidate;
    rdma_handle function_snapshot_base;
    rdma_handle owner_snapshot;
    rdma_status status;

    snapshot = null;
    if (source == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal mapping is null"
      );
    status = source.snapshot_release_authority(candidate);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal mapping authority snapshot returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (candidate == null || candidate == source ||
        candidate.get_object_type() != source.get_object_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal mapping authority snapshot is null, aliased or sliced"
      );
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_handle_direct(
          source.owner_h, 1'b1, owner_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal mapping nested handle snapshot failed"
      );
    if (!$cast(candidate.function_h, function_snapshot_base))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal mapping Function snapshot subtype is invalid"
      );
    candidate.requester_bdf = source.requester_bdf;
    candidate.pasid_valid = source.pasid_valid;
    candidate.pasid = source.pasid;
    candidate.dma_domain_valid = source.dma_domain_valid;
    candidate.dma_domain_id = source.dma_domain_id;
    candidate.route = source.route;
    candidate.reset_epoch = source.reset_epoch;
    candidate.route_valid = source.route_valid;
    candidate.epoch_valid = source.epoch_valid;
    candidate.backing_addr = source.backing_addr;
    candidate.iova = source.iova;
    candidate.size = source.size;
    candidate.direction = source.direction;
    candidate.permissions = source.permissions;
    candidate.state = source.state;
    candidate.owner_h = owner_snapshot;
    candidate.umem_ref = source.umem_ref;
    candidate.pbl_ref = source.pbl_ref;
    candidate.mw_ref = source.mw_ref;
    candidate.umem_backed = source.umem_backed;
    candidate.umem_page_count = source.umem_page_count;

    status = source.release_authority_status(candidate);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal mapping authority verification returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (!same_journal_mapping_public_value(source, candidate) ||
        candidate.function_h == source.function_h ||
        (source.owner_h != null && candidate.owner_h == source.owner_h))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal mapping snapshot changed public value or retained an alias"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：用指定 profile service 复制 command body，再直接构造 command shell。
  // 输入/输出及副作用：source、detached_owner、context、profile 为输入；snapshot 入口清空。
  // 失败/边界：未知 body、profile seam 失败、subtype 非法、owner 不等值/仍别名或 shell 漂移时原子失败；
  //  不调用 generic clone/copy/factory。
  protected function rdma_status snapshot_command_with_profile_locked(
    input rdma_cmq_command_desc source,
    input rdma_cmq_recovery_owner detached_owner,
    input rdma_cmq_nonfatal_snapshot_context ctx_snapshot,
    input rdma_cmq_hw_profile profile_service,
    output rdma_cmq_command_desc snapshot
  );
    rdma_cmq_command_desc candidate;
    rdma_hw_model body_snapshot;
    rdma_handle function_snapshot_base;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_hw_image signature_snapshot;
    rdma_status status;
    bit context_body;

    snapshot = null;
    if (source == null || ctx_snapshot == null || profile_service == null ||
        source.get_object_type() != rdma_cmq_command_desc::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command source/context/profile is invalid"
      );

    context_body = rdma_cmq_has_exact_object_type(source.body,
                                         rdma_cqc_model::get_type()) ||
                   rdma_cmq_has_exact_object_type(source.body,
                                         rdma_mrt_model::get_type()) ||
                   rdma_cmq_has_exact_object_type(source.body,
                                         rdma_srqc_model::get_type()) ||
                   rdma_cmq_has_exact_object_type(source.body,
                                         rdma_ceqc_model::get_type()) ||
                   rdma_cmq_has_exact_object_type(source.body,
                                         rdma_aeqc_model::get_type());
    if (context_body)
      status = checked_context_snapshot(
        source.body, "CMQ journal command body", RDMA_SC_INVALID_ARGUMENT,
        body_snapshot
      );
    else
      status = profile_service.snapshot_command_body(
        source.body, body_snapshot
      );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal command body snapshot returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (body_snapshot == null || body_snapshot == source.body ||
        (context_body &&
         (!same_body_value(source.body, body_snapshot) ||
          !body_graph_detached(source.body, body_snapshot))) ||
        (!context_body &&
         (!profile_service.same_command_body_value(
            source.body, body_snapshot
          ) || !profile_service.command_body_graph_detached(
            source.body, body_snapshot
          ))))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command body snapshot contract failed"
      );
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_opcode_key_direct(
          source.opcode_key, opcode_snapshot
        ) || !rdma_cmq_try_snapshot_image_direct(
          source.qpc_signature_source, 1'b1, signature_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command shell nested snapshot failed"
      );
    if (detached_owner == null || detached_owner == source.recovery_owner ||
        !rdma_cmq_same_journal_owner_value(source.recovery_owner, detached_owner) ||
        source.timeout == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command owner or timeout is invalid"
      );

    candidate = new("journal_command_snapshot");
    if (!$cast(candidate.function_h, function_snapshot_base))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command Function snapshot subtype is invalid"
      );
    candidate.opcode_key = opcode_snapshot;
    candidate.body = body_snapshot;
    candidate.qpc_signature_source = signature_snapshot;
    candidate.vfid_override = source.vfid_override;
    candidate.use_vfid = source.use_vfid;
    candidate.timeout = source.timeout;
    candidate.recovery_owner = detached_owner;
    if (candidate.function_h == source.function_h ||
        candidate.opcode_key == source.opcode_key ||
        (source.qpc_signature_source != null &&
         candidate.qpc_signature_source == source.qpc_signature_source) ||
        !same_handle(candidate.function_h, source.function_h) ||
        !same_opcode_value(candidate.opcode_key, source.opcode_key) ||
        (source.qpc_signature_source != null &&
         !same_image_value(candidate.qpc_signature_source,
                           source.qpc_signature_source)) ||
        candidate.vfid_override != source.vfid_override ||
        candidate.use_vfid != source.use_vfid ||
        candidate.timeout != source.timeout)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command snapshot is unequal or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：用 engine 当前 profile 委托 command journal snapshot。
  // 输入/输出及副作用：source/detached_owner/context 为输入；不取锁，调用方须已持 engine_lock。
  // 失败/边界：profile 缺失或 body/shell 被拒时输出 null 与非空错误。
  protected function rdma_status snapshot_command_for_journal_locked(
    input rdma_cmq_command_desc source,
    input rdma_cmq_recovery_owner detached_owner,
    input rdma_cmq_nonfatal_snapshot_context ctx_snapshot,
    output rdma_cmq_command_desc snapshot
  );
    return snapshot_command_with_profile_locked(
      source, detached_owner, ctx_snapshot, profile, snapshot
    );
  endfunction

  // 设计说明：retained completion 不得把 profile/测试 factory 的 raw-CQE subtype 带入 journal 图；先把
  //  公开字段投影为 exact base image，再交 nonfatal snapshot context 复制，以同时隔离 hostile
  //  subtype 并保持 timeout/reset completion 的 null raw-CQE 语义。纯值阶段，不拥有任何生命周期。
  // 功能：把可选 completion.raw_cqe 复制为 canonical CQE image，并校验长度、metadata 与 generation。
  // 输入/输出及副作用：source 只读；canonical_raw_cqe 先清空，raw 缺失返回 OK+null，否则返回新 base
  //  image；不取锁、不调用 profile/factory，不改 source/engine。
  // 失败/边界：非 CMQ CQE、长度/target 非法、ticket/Function 缺失、generation 不符或值漂移返回
  //  INVALID_ARGUMENT；source/raw 为 null 是 timeout/reset 合法边界，返回成功。
  protected function rdma_status canonicalize_completion_raw_cqe(
    input rdma_cmq_completion source,
    output rdma_hw_image canonical_raw_cqe
  );
    canonical_raw_cqe = null;
    if (source == null || source.raw_cqe == null)
      return journal_status(RDMA_SC_OK);

    canonical_raw_cqe = new("cmq_completion_canonical_raw_cqe");
    canonical_raw_cqe.bytes = source.raw_cqe.bytes;
    rdma_hw_image::copy_metadata_noalloc(source.raw_cqe, canonical_raw_cqe);
    canonical_raw_cqe.field_summary = source.raw_cqe.field_summary;
    if (!rdma_cmq_image_shape_valid(canonical_raw_cqe) ||
        canonical_raw_cqe.length != CMQE_BYTES ||
        canonical_raw_cqe.image_kind != RDMA_IMAGE_CMQ_CQE ||
        canonical_raw_cqe.write_target_kind != RDMA_HW_TARGET_NONE ||
        canonical_raw_cqe.backing_target.value != 0 ||
        canonical_raw_cqe.hmc_target.value != 0 ||
        canonical_raw_cqe.bar_target.value != 0 ||
        source.ticket == null || source.ticket.function_h == null ||
        canonical_raw_cqe.function_generation !=
          source.ticket.function_h.generation ||
        !same_image_value(canonical_raw_cqe, source.raw_cqe))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ completion raw CQE canonicalization failed"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：用指定 profile 先复制可选 typed payload，再由 context 构造 completion shell。
  // 输入/输出及副作用：source/context/profile 只读；snapshot 入口清空；ticket/status alias 由 context 维护。
  // 失败/边界：未知 payload、profile seam 失败、subtype/shape 或 payload 分离校验失败时原子返回错误；
  //  null source/payload 合法。
  protected function rdma_status snapshot_completion_with_profile_locked(
    input rdma_cmq_completion source,
    input rdma_cmq_nonfatal_snapshot_context ctx_snapshot,
    input rdma_cmq_hw_profile profile_service,
    output rdma_cmq_completion snapshot
  );
    uvm_object payload_snapshot;
    rdma_cmq_completion candidate;
    rdma_cmq_completion canonical_source;
    rdma_hw_image canonical_raw_cqe;
    rdma_status status;
    string failure_reason;

    snapshot = null;
    if (ctx_snapshot == null || profile_service == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ completion snapshot context or profile is null"
      );
    payload_snapshot = null;
    if (source != null && source.decoded_response != null) begin
      status = profile_service.snapshot_completion_payload(
        source.decoded_response, payload_snapshot
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ completion payload snapshot returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      if (payload_snapshot == null ||
          payload_snapshot == source.decoded_response ||
          !profile_service.same_completion_payload_value(
            source.decoded_response, payload_snapshot
          ) || !profile_service.completion_payload_graph_detached(
            source.decoded_response, payload_snapshot
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ completion payload snapshot contract failed"
        );
    end
    status = canonicalize_completion_raw_cqe(source, canonical_raw_cqe);
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ completion raw-CQE canonicalization returned null status"
      ) : status;
    if (source != null && canonical_raw_cqe != null) begin
      canonical_source = new("cmq_completion_canonical_source");
      canonical_source.ticket = source.ticket;
      canonical_source.status = source.status;
      canonical_source.raw_cqe = canonical_raw_cqe;
      canonical_source.decoded_response = source.decoded_response;
    end
    else
      canonical_source = source;
    if (!ctx_snapshot.try_snapshot_completion_shell(
          canonical_source, payload_snapshot, candidate, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ completion shell snapshot failed: ", failure_reason}
      );
    if (source != null && (candidate == null || candidate == source))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ completion shell snapshot is null or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：只读定位 runtime transition 对应的唯一 retained journal item，预建 journal-owned
  //  completion，并用 reducer 与 recovery classifier 计算目标标量；不发布任何状态。
  // 输入/输出及副作用：slot_record/source_completion/target_state/target_phase 只读；成功输出 batch/item
  //  非拥有句柄、独立 completion、recovery_required、reduced_batch_state；不改 slot/FIFO/journal。
  // 失败/边界：locator 为空/越界、四表 invariant、ticket/slot/token 不等、非法前驱迁移、snapshot 或
  //  reducer 失败时返回非 OK 且输出清空；不从 request_index/当前 runtime 猜测 journal authority。
  protected function rdma_status stage_runtime_journal_transition_locked(
    input rdma_cmq_slot_record slot_record,
    input rdma_cmq_completion source_completion,
    input rdma_cmq_submission_state_e target_state,
    input rdma_cmq_completion_phase_e target_phase,
    output rdma_cmq_batch_submission_record batch_record,
    output rdma_cmq_batch_submission_item_record journal_item,
    output rdma_cmq_completion journal_completion,
    output bit recovery_required,
    output rdma_cmq_submission_state_e reduced_batch_state
  );
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_cmq_batch_submission_item_record reducer_items[$];
    rdma_cmq_batch_submission_item_record reducer_item;
    rdma_cmq_hw_profile retained_profile;
    rdma_status status;
    bit predecessor_valid;

    batch_record = null;
    journal_item = null;
    journal_completion = null;
    recovery_required = 1'b1;
    reduced_batch_state = RDMA_CMQ_SUBMISSION_STAGED;
    if (slot_record == null || source_completion == null ||
        slot_record.batch_key.len() == 0 ||
        !submission_journal.exists(slot_record.batch_key) ||
        !journal_profile_by_batch.exists(slot_record.batch_key))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime slot journal locator is missing or unknown"
      );
    status = submission_journal_invariant_locked(slot_record.batch_key);
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal invariant returned null status"
      ) : journal_status(status.code, status.message);

    batch_record = submission_journal[slot_record.batch_key];
    retained_profile = journal_profile_by_batch[slot_record.batch_key];
    if (batch_record == null || retained_profile == null ||
        slot_record.journal_item_index >= batch_record.items.size()) begin
      batch_record = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime slot journal item index is out of range"
      );
    end
    journal_item = batch_record.items[slot_record.journal_item_index];
    if (journal_item == null || journal_item.ticket == null ||
        source_completion.ticket == null || source_completion.status == null ||
        !same_ticket_value(slot_record.ticket, journal_item.ticket) ||
        !same_ticket_value(source_completion.ticket, journal_item.ticket) ||
        journal_item.slot_sequence != slot_record.slot_sequence ||
        journal_item.slot_index != slot_record.sq_index ||
        journal_item.slot_wrap != slot_record.sq_wrap ||
        journal_item.command_token != slot_record.command_token ||
        journal_item.entry_key != entry_key(
          slot_record.sq_index, slot_record.sq_wrap
        )) begin
      batch_record = null;
      journal_item = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime slot and retained journal item disagree"
      );
    end

    predecessor_valid = rdma_cmq_transition_predecessor_valid(
      journal_item.state, journal_item.completion_phase, target_state,
      target_phase, journal_item.completion != null
    );
    if (!predecessor_valid) begin
      batch_record = null;
      journal_item = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal lifecycle predecessor is invalid"
      );
    end

    snapshot_context = new();
    status = snapshot_completion_with_profile_locked(
      source_completion, snapshot_context, retained_profile,
      journal_completion
    );
    if (status == null) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal completion snapshot returned null status"
      );
    end
    if (!status.ok()) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return journal_status(status.code, status.message);
    end
    if (journal_completion == null ||
        journal_completion.ticket == null ||
        journal_completion.status == null ||
        !same_ticket_value(journal_completion.ticket, journal_item.ticket)) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal completion snapshot is incomplete"
      );
    end
    status = rdma_cmq_classify_recovery_required(
      target_state, target_phase, journal_item.submission_effect, 1'b0,
      journal_item.recovery_owner.is_legacy_unmigrated(), recovery_required
    );
    if (status == null || !status.ok()) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal recovery classifier returned null status"
      ) : journal_status(status.code, status.message);
    end

    foreach (batch_record.items[i]) begin
      reducer_item = new($sformatf("cmq_lifecycle_reducer_item_%0d", i));
      reducer_item.state = (i == slot_record.journal_item_index) ?
        target_state : batch_record.items[i].state;
      reducer_items.push_back(reducer_item);
    end
    status = rdma_cmq_reduce_batch_state(
      reducer_items, reduced_batch_state
    );
    if (status == null || !status.ok()) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal reducer returned null status"
      ) : journal_status(status.code, status.message);
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：把已 staging 的 completion 与标量写入 retained item，并更新 reducer 给出的 batch aggregate。
  // 输入/输出及副作用：batch_record/journal_item/journal_completion 为 engine-owned 句柄；其余为预算值；
  //  成功同步更新 journal aliases。
  // 失败/边界：须先由 stage_runtime_journal_transition_locked 认证；无返回值、不分配、不碰 FIFO/slot。
  protected function void commit_runtime_journal_transition_locked(
    input rdma_cmq_batch_submission_record batch_record,
    input rdma_cmq_batch_submission_item_record journal_item,
    input rdma_cmq_completion journal_completion,
    input rdma_cmq_submission_state_e target_state,
    input rdma_cmq_completion_phase_e target_phase,
    input bit recovery_required,
    input rdma_cmq_submission_state_e reduced_batch_state
  );
    journal_completion.ticket = journal_item.ticket;
    journal_item.status = journal_completion.status;
    journal_item.completion = journal_completion;
    journal_item.state = target_state;
    journal_item.completion_phase = target_phase;
    journal_item.reset_isolation_confirmed = 1'b0;
    journal_item.recovery_required = recovery_required;
    batch_record.state = reduced_batch_state;
  endfunction

  // 功能：在单一 context 中直接复制 reset proof 的 identity、tuple 与 owner 图。
  // 输入/输出及副作用：source/context 为输入；snapshot 入口清空；重算 proof_digest 后才发布，重复 owner
  //  复用同一 detached 节点。
  // 失败/边界：subtype、ID/key/state、tuple 数量、owner/identity 或 digest 无效返回 INVALID_ARGUMENT/null；
  //  下游 null status 转 INVALID_STATE。
  protected function rdma_status snapshot_reset_proof_with_context_locked(
    input rdma_cmq_reset_isolation_proof source,
    input rdma_cmq_nonfatal_snapshot_context ctx_snapshot,
    output rdma_cmq_reset_isolation_proof snapshot
  );
    rdma_cmq_reset_isolation_proof candidate;
    rdma_function_identity isolated_identity_snapshot;
    rdma_function_identity replacement_identity_snapshot;
    rdma_cmq_recovery_owner owner_snapshot;
    rdma_cmq_recovery_owner owners_snapshot[$];
    rdma_cmq_journal_digest_t computed_digest;
    rdma_status status;
    string failure_reason;

    snapshot = null;
    if (source == null || ctx_snapshot == null ||
        source.get_object_type() != rdma_cmq_reset_isolation_proof::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof source or snapshot context is invalid"
      );
    if (source.proof_key.len() == 0 || source.batch_key.len() == 0 ||
        source.proof_id == 0 || source.batch_id == 0 ||
        source.attempt_id == 0 || source.engine_instance_id == 0 ||
        source.engine_incarnation == 0 || source.batch_digest == '0 ||
        source.proof_digest == '0 || !source.backing_release_confirmed ||
        !(source.state inside {RDMA_CMQ_RESET_PROOF_AWAITING_REBIND,
                               RDMA_CMQ_RESET_PROOF_READY}) ||
        source.isolated_request_indices.size() == 0 ||
        source.isolated_request_indices.size() !=
          source.isolated_image_digests.size() ||
        source.isolated_request_indices.size() !=
          source.isolated_authority_digests.size() ||
        source.isolated_request_indices.size() !=
          source.isolated_recovery_owners.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof fixed projection or tuple cardinality is invalid"
      );
    if ((source.state == RDMA_CMQ_RESET_PROOF_AWAITING_REBIND &&
         source.replacement_identity != null) ||
        (source.state == RDMA_CMQ_RESET_PROOF_READY &&
         (source.replacement_identity == null ||
          !source.replacement_identity.same_function(
            source.isolated_identity
          ) || source.replacement_identity.reset_epoch <=
            source.isolated_identity.reset_epoch)))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof replacement transition is invalid"
      );
    if (!rdma_cmq_try_snapshot_identity_direct(
          source.isolated_identity, isolated_identity_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof isolated identity snapshot failed"
      );
    replacement_identity_snapshot = null;
    if (source.replacement_identity != null &&
        !rdma_cmq_try_snapshot_identity_direct(
          source.replacement_identity, replacement_identity_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof replacement identity snapshot failed"
      );
    foreach (source.isolated_recovery_owners[i]) begin
      if (!ctx_snapshot.try_snapshot_recovery_owner(
            source.isolated_recovery_owners[i], owner_snapshot,
            failure_reason
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ reset proof owner snapshot failed: ", failure_reason}
        );
      owners_snapshot.push_back(owner_snapshot);
    end
    status = rdma_cmq_compute_reset_proof_digest(
      source.proof_key, source.proof_id, source.batch_key,
      source.batch_id, source.attempt_id, source.engine_instance_id,
      source.engine_incarnation, source.isolated_identity,
      source.batch_digest, source.isolated_request_indices,
      source.isolated_image_digests, source.isolated_authority_digests,
      source.isolated_recovery_owners, computed_digest
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ reset proof digest computation returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (computed_digest != source.proof_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof carried digest does not match its source graph"
      );

    candidate = new("journal_reset_proof_snapshot");
    candidate.proof_key = source.proof_key;
    candidate.proof_id = source.proof_id;
    candidate.batch_key = source.batch_key;
    candidate.batch_id = source.batch_id;
    candidate.attempt_id = source.attempt_id;
    candidate.engine_instance_id = source.engine_instance_id;
    candidate.engine_incarnation = source.engine_incarnation;
    candidate.isolated_identity = isolated_identity_snapshot;
    candidate.replacement_identity = replacement_identity_snapshot;
    candidate.batch_digest = source.batch_digest;
    candidate.isolated_request_indices = source.isolated_request_indices;
    candidate.isolated_image_digests = source.isolated_image_digests;
    candidate.isolated_authority_digests =
      source.isolated_authority_digests;
    candidate.isolated_recovery_owners = owners_snapshot;
    candidate.proof_digest = source.proof_digest;
    candidate.state = source.state;
    candidate.backing_release_confirmed =
      source.backing_release_confirmed;
    if (candidate == source ||
        candidate.isolated_identity == source.isolated_identity ||
        (source.replacement_identity != null &&
         candidate.replacement_identity == source.replacement_identity))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof snapshot retained a source graph alias"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：为 reset proof 公开 snapshot seam 创建唯一 context 并原子发布图。
  // 输入/输出及副作用：source 只读；snapshot 入口清空；不登记 proof authority。
  // 失败/边界：nested/digest 被拒时 output 保持 null，返回非空 status。
  protected function rdma_status snapshot_reset_proof_locked(
    input rdma_cmq_reset_isolation_proof source,
    output rdma_cmq_reset_isolation_proof snapshot
  );
    rdma_cmq_nonfatal_snapshot_context ctx_snapshot;

    snapshot = null;
    ctx_snapshot = new();
    return snapshot_reset_proof_with_context_locked(
      source, ctx_snapshot, snapshot
    );
  endfunction

  // 功能：直接复制可选 command identity 标量，使 execution result 保留诊断身份。
  // 输入/输出及副作用：source 为输入；snapshot 入口清空，成功发布新 base 对象。
  // 失败/边界：null 视为可选值并成功；未知 subtype、无效文本/身份或值漂移时原子失败。
  protected function rdma_status snapshot_journal_command_identity_locked(
    input rdma_cmq_command_identity source,
    output rdma_cmq_command_identity snapshot
  );
    rdma_cmq_command_identity candidate;

    snapshot = null;
    if (source == null)
      return journal_status(RDMA_SC_OK);
    if (source.get_object_type() != rdma_cmq_command_identity::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ command identity runtime subtype is unsupported"
      );
    candidate = new("journal_command_identity_snapshot");
    candidate.function_kind = source.function_kind;
    candidate.function_uid = source.function_uid;
    candidate.global_function_id = source.global_function_id;
    candidate.generation = source.generation;
    candidate.profile_name = source.profile_name;
    candidate.opcode = source.opcode;
    candidate.variant = source.variant;
    if (!rdma_cmq_same_journal_command_identity_value(source, candidate))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ command identity source is incomplete or changed"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：直接构造完整 execution result，并用单一 context 保留 ticket/status/owner alias。
  // 输入/输出及副作用：source 只读；snapshot 入口清空；profile 仅复制 completion typed payload。
  // 失败/边界：subtype、profile payload seam 或 required status 失败时返回非空错误与 null；
  //  不调用 raw factory/generic clone/copy。
  protected function rdma_status snapshot_execution_result_locked(
    input rdma_cmq_execution_result source,
    output rdma_cmq_execution_result snapshot
  );
    rdma_cmq_nonfatal_snapshot_context ctx_snapshot;
    rdma_cmq_execution_result candidate;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_completion completion_snapshot;
    rdma_status status_snapshot;
    rdma_status observation_snapshot;
    rdma_cmq_command_identity command_identity_snapshot;
    rdma_cmq_recovery_owner owner_snapshot;
    rdma_dma_request_context dma_snapshot;
    rdma_cmq_hw_profile snapshot_profile;
    rdma_status status;
    string failure_reason;

    snapshot = null;
    if (source == null ||
        source.get_object_type() != rdma_cmq_execution_result::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ execution result source is null or unsupported"
      );
    ctx_snapshot = new();
    snapshot_profile = profile;
    if (source.batch_key.len() != 0 &&
        journal_profile_by_batch.exists(source.batch_key) &&
        journal_profile_by_batch[source.batch_key] != null)
      snapshot_profile = journal_profile_by_batch[source.batch_key];
    if (!ctx_snapshot.try_snapshot_optional_ticket(
          source.ticket, ticket_snapshot, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ execution result ticket snapshot failed: ", failure_reason}
      );
    status = snapshot_completion_with_profile_locked(
      source.completion, ctx_snapshot, snapshot_profile, completion_snapshot
    );
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ execution result completion snapshot returned null status"
      ) : journal_status(status.code, status.message);
    if (!ctx_snapshot.try_snapshot_required_status(
          source.status, status_snapshot, failure_reason
        ) || !ctx_snapshot.try_snapshot_required_status(
          source.observation_status, observation_snapshot, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ execution result status snapshot failed: ", failure_reason}
      );
    status = snapshot_journal_command_identity_locked(
      source.command_identity, command_identity_snapshot
    );
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ execution command identity snapshot returned null status"
      ) : journal_status(status.code, status.message);
    owner_snapshot = null;
    if (source.recovery_owner != null &&
        !ctx_snapshot.try_snapshot_recovery_owner(
          source.recovery_owner, owner_snapshot, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ execution owner snapshot failed: ", failure_reason}
      );
    dma_snapshot = null;
    if (source.dma_context != null) begin
      status = snapshot_journal_dma_context_locked(
        source.dma_context, dma_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ execution DMA snapshot returned null status"
        ) : journal_status(status.code, status.message);
    end

    candidate = new("journal_execution_result_snapshot");
    candidate.ticket = ticket_snapshot;
    candidate.completion = completion_snapshot;
    candidate.status = status_snapshot;
    candidate.observation_status = observation_snapshot;
    candidate.command_identity = command_identity_snapshot;
    candidate.recovery_owner = owner_snapshot;
    candidate.dma_context = dma_snapshot;
    candidate.submission_effect = source.submission_effect;
    candidate.attempt_effect = source.attempt_effect;
    candidate.completion_phase = source.completion_phase;
    candidate.batch_key = source.batch_key;
    candidate.batch_id = source.batch_id;
    candidate.attempt_id = source.attempt_id;
    candidate.recovery_required = source.recovery_required;
    if (candidate == source ||
        (source.ticket != null && candidate.ticket == source.ticket) ||
        (source.completion != null &&
         candidate.completion == source.completion) ||
        candidate.status == source.status ||
        candidate.observation_status == source.observation_status ||
        (source.recovery_owner != null &&
         candidate.recovery_owner == source.recovery_owner))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ execution result snapshot retained a source alias"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：用指定 retained profile 和单一 context 直接复制完整 batch journal record。
  // 输入/输出及副作用：source/profile 为输入；snapshot 入口清空；成功图拥有 detached 值，重复 ticket/
  //  status/owner 保持 canonical alias。
  // 失败/边界：节点/subtype、mapping opaque authority、body/payload 或 alias 拓扑失败时不发布 partial，
  //  返回具体非空 status。
  protected function rdma_status snapshot_journal_record_with_profile_locked(
    input rdma_cmq_batch_submission_record source,
    input rdma_cmq_hw_profile profile_service,
    output rdma_cmq_batch_submission_record snapshot
  );
    rdma_cmq_nonfatal_snapshot_context ctx_snapshot;
    rdma_cmq_batch_submission_record candidate;
    rdma_function_identity identity_snapshot;
    rdma_function_binding binding_snapshot;
    rdma_handle cmq_snapshot;
    rdma_hw_image doorbell_snapshot;
    rdma_cmq_reset_isolation_proof proof_snapshot;
    rdma_dma_mapping mapping_snapshots[rdma_dma_mapping];
    rdma_status status;
    string failure_reason;

    snapshot = null;
    if (source == null || profile_service == null ||
        source.get_object_type() != rdma_cmq_batch_submission_record::get_type() ||
        source.function_identity == null || source.binding == null ||
        source.cmq_h == null || source.doorbell_image == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record source or profile is null or unsupported"
      );
    if (source.batch_key.len() == 0 || source.batch_id == 0 ||
        source.attempt_id == 0 || source.engine_instance_id == 0 ||
        source.engine_incarnation == 0 || source.items.size() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record fixed identity or item list is incomplete"
      );
    ctx_snapshot = new();
    if (!rdma_cmq_try_snapshot_identity_direct(
          source.function_identity, identity_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record Function identity snapshot failed"
      );
    status = source.binding.snapshot_complete_nonfatal(binding_snapshot);
    if (status == null || !status.ok() || binding_snapshot == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal binding snapshot returned null status"
      ) : journal_status(status.code, status.message);
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_image_direct(
          source.doorbell_image, 1'b0, doorbell_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record CMQ/doorbell snapshot failed"
      );

    candidate = new("journal_record_snapshot");
    candidate.batch_key = source.batch_key;
    candidate.batch_id = source.batch_id;
    candidate.attempt_id = source.attempt_id;
    candidate.engine_instance_id = source.engine_instance_id;
    candidate.engine_incarnation = source.engine_incarnation;
    candidate.function_identity = identity_snapshot;
    candidate.binding = binding_snapshot;
    candidate.cmq_h = cmq_snapshot;
    candidate.start_sequence = source.start_sequence;
    candidate.end_sequence = source.end_sequence;
    candidate.doorbell_image = doorbell_snapshot;
    candidate.final_pi = source.final_pi;
    candidate.final_polarity = source.final_polarity;
    candidate.batch_digest = source.batch_digest;
    candidate.state = source.state;
    candidate.submission_effect = source.submission_effect;
    candidate.attempt_effect = source.attempt_effect;
    candidate.observer_armed = source.observer_armed;
    candidate.publication_retry_safe = source.publication_retry_safe;

    foreach (source.items[i]) begin
      rdma_cmq_batch_submission_item_record source_item;
      rdma_cmq_batch_submission_item_record item_snapshot;
      rdma_cmq_recovery_owner owner_snapshot;
      rdma_cmq_command_desc command_snapshot;
      rdma_cmq_ticket ticket_snapshot;
      rdma_dma_request_context dma_snapshot;
      rdma_hw_image sqe_snapshot;
      rdma_dma_mapping mapping_snapshot;
      rdma_hw_image dependency_snapshot;
      rdma_cmq_completion completion_snapshot;
      rdma_status item_status_snapshot;

      source_item = source.items[i];
      if (source_item == null ||
          source_item.get_object_type() !=
            rdma_cmq_batch_submission_item_record::get_type() ||
          source_item.command == null || source_item.ticket == null ||
          source_item.recovery_owner == null ||
          source_item.command.recovery_owner !=
            source_item.recovery_owner ||
          source_item.dma_context == null || source_item.sqe_image == null ||
          source_item.dependency_mapping == null ||
          source_item.dependency_image == null || source_item.status == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ journal item %0d graph is incomplete", i)
        );
      if (!ctx_snapshot.try_snapshot_recovery_owner(
            source_item.recovery_owner, owner_snapshot, failure_reason
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ journal owner snapshot failed: ", failure_reason}
        );
      status = snapshot_command_with_profile_locked(
        source_item.command, owner_snapshot, ctx_snapshot, profile_service,
        command_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal command snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!ctx_snapshot.try_snapshot_optional_ticket(
            source_item.ticket, ticket_snapshot, failure_reason
          ) || ticket_snapshot == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ journal ticket snapshot failed: ", failure_reason}
        );
      status = snapshot_journal_dma_context_locked(
        source_item.dma_context, dma_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal DMA snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!rdma_cmq_try_snapshot_image_direct(
            source_item.sqe_image, 1'b0, sqe_snapshot
          ) || !rdma_cmq_try_snapshot_image_direct(
            source_item.dependency_image, 1'b0, dependency_snapshot
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal item image snapshot failed"
        );
      if (mapping_snapshots.exists(source_item.dependency_mapping)) begin
        mapping_snapshot =
          mapping_snapshots[source_item.dependency_mapping];
      end
      else begin
        status = snapshot_journal_mapping_locked(
          source_item.dependency_mapping, mapping_snapshot
        );
        if (status == null || !status.ok())
          return (status == null) ? journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ journal mapping snapshot returned null status"
          ) : journal_status(status.code, status.message);
        mapping_snapshots[source_item.dependency_mapping] =
          mapping_snapshot;
      end
      status = snapshot_completion_with_profile_locked(
        source_item.completion, ctx_snapshot, profile_service,
        completion_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal completion snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!ctx_snapshot.try_snapshot_required_status(
            source_item.status, item_status_snapshot, failure_reason
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ journal item status snapshot failed: ", failure_reason}
        );

      item_snapshot = new($sformatf("journal_item_snapshot_%0d", i));
      item_snapshot.request_index = source_item.request_index;
      item_snapshot.command = command_snapshot;
      item_snapshot.ticket = ticket_snapshot;
      item_snapshot.recovery_owner = owner_snapshot;
      item_snapshot.dma_context = dma_snapshot;
      item_snapshot.sqe_image = sqe_snapshot;
      item_snapshot.dependency_mapping = mapping_snapshot;
      item_snapshot.dependency_offset = source_item.dependency_offset;
      item_snapshot.dependency_image = dependency_snapshot;
      item_snapshot.slot_sequence = source_item.slot_sequence;
      item_snapshot.slot_index = source_item.slot_index;
      item_snapshot.slot_wrap = source_item.slot_wrap;
      item_snapshot.command_token = source_item.command_token;
      item_snapshot.token_incarnation = source_item.token_incarnation;
      item_snapshot.entry_key = source_item.entry_key;
      item_snapshot.image_digest = source_item.image_digest;
      item_snapshot.authority_digest = source_item.authority_digest;
      item_snapshot.dependency_replay_safe =
        source_item.dependency_replay_safe;
      item_snapshot.state = source_item.state;
      item_snapshot.submission_effect = source_item.submission_effect;
      item_snapshot.attempt_effect = source_item.attempt_effect;
      item_snapshot.completion_phase = source_item.completion_phase;
      item_snapshot.reset_isolation_confirmed =
        source_item.reset_isolation_confirmed;
      item_snapshot.recovery_required = source_item.recovery_required;
      item_snapshot.completion = completion_snapshot;
      item_snapshot.status = item_status_snapshot;
      if (item_snapshot.command.recovery_owner !=
            item_snapshot.recovery_owner ||
          (source_item.completion != null &&
           source_item.completion.ticket == source_item.ticket &&
           item_snapshot.completion.ticket != item_snapshot.ticket) ||
          (source_item.completion != null &&
           source_item.completion.status == source_item.status &&
           item_snapshot.completion.status != item_snapshot.status))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal item canonical alias topology changed"
        );
      candidate.items.push_back(item_snapshot);
    end

    proof_snapshot = null;
    if (source.reset_isolation_proof != null) begin
      status = snapshot_reset_proof_with_context_locked(
        source.reset_isolation_proof, ctx_snapshot, proof_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal reset proof snapshot returned null status"
        ) : journal_status(status.code, status.message);
    end
    candidate.reset_isolation_proof = proof_snapshot;
    if (candidate == source || candidate.function_identity ==
          source.function_identity || candidate.binding == source.binding ||
        candidate.cmq_h == source.cmq_h ||
        candidate.doorbell_image == source.doorbell_image ||
        candidate.items.size() != source.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record snapshot is partial or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：直接复制 recovery request，并以当前 profile 重算每项与批次 digest 后发布。
  // 输入/输出及副作用：source 只读；snapshot 入口清空；单一 context 保留重复 ticket/owner，
  //  mapping 保留 opaque authority。
  // 失败/边界：固定字段、cardinality、profile name/body、carried digest、proof 或嵌套快照失败时输出 null；
  //  未知 polymorph 返回 INVALID_ARGUMENT。
  protected function rdma_status snapshot_recovery_request_locked(
    input rdma_cmq_submission_recovery_request source,
    output rdma_cmq_submission_recovery_request snapshot
  );
    rdma_cmq_nonfatal_snapshot_context ctx_snapshot;
    rdma_cmq_submission_recovery_request candidate;
    rdma_function_identity identity_snapshot;
    rdma_function_binding binding_snapshot;
    rdma_handle cmq_snapshot;
    rdma_hw_image doorbell_snapshot;
    rdma_cmq_reset_isolation_proof proof_snapshot;
    rdma_dma_mapping mapping_snapshots[rdma_dma_mapping];
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_cmq_journal_digest_t computed_batch_digest;
    rdma_status status;
    string profile_name;
    string failure_reason;

    snapshot = null;
    if (source == null || profile == null ||
        source.get_object_type() !=
          rdma_cmq_submission_recovery_request::get_type() ||
        source.batch_key.len() == 0 || source.batch_id == 0 ||
        source.expected_attempt_id == 0 ||
        source.expected_function_identity == null || source.binding == null ||
        source.cmq_h == null || source.doorbell_image == null ||
        source.items.size() == 0 ||
        !(source.action inside {RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
                                RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION}))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request fixed projection is incomplete or unsupported"
      );
    profile_name = profile.profile_name();
    if (profile_name.len() == 0 ||
        rdma_cmq_string_has_separator(profile_name))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request profile name is invalid"
      );

    foreach (source.items[i]) begin
      rdma_cmq_submission_recovery_item source_item;
      rdma_cmq_journal_digest_t computed_image_digest;
      rdma_cmq_journal_digest_t computed_authority_digest;
      string body_tag;
      byte unsigned body_bytes[];

      source_item = source.items[i];
      if (source_item == null ||
          source_item.get_object_type() !=
            rdma_cmq_submission_recovery_item::get_type() ||
          source_item.command == null || source_item.ticket == null ||
          source_item.recovery_owner == null ||
          source_item.command.recovery_owner !=
            source_item.recovery_owner ||
          source_item.dma_context == null || source_item.sqe_image == null ||
          source_item.dependency_mapping == null ||
          source_item.dependency_image == null ||
          source_item.command.opcode_key == null ||
          source_item.ticket.opcode_key == null ||
          source_item.command.opcode_key.profile_name != profile_name ||
          source_item.ticket.opcode_key.profile_name != profile_name)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ recovery request item %0d is incomplete", i)
        );
      status = canonicalize_journal_body(
        profile, source_item.command, source_item.sqe_image,
        body_tag, body_bytes
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request body canonicalization returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      status = rdma_cmq_compute_item_digests(
        source_item.command, body_tag, body_bytes, source_item.ticket,
        source_item.recovery_owner, source.expected_function_identity,
        source_item.dma_context, source_item.sqe_image,
        source_item.dependency_mapping, source_item.dependency_offset,
        source_item.dependency_image, computed_image_digest,
        computed_authority_digest
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request item digest returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      if (computed_image_digest != source_item.image_digest ||
          computed_authority_digest != source_item.authority_digest)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request item carried digest is inconsistent"
        );
      request_indices.push_back(source_item.request_index);
      image_digests.push_back(computed_image_digest);
      authority_digests.push_back(computed_authority_digest);
    end
    status = rdma_cmq_compute_batch_digest(
      source.expected_function_identity, source.binding, source.cmq_h,
      source.doorbell_image, source.final_pi, source.final_polarity,
      source.start_sequence, source.end_sequence, request_indices,
      image_digests, authority_digests, computed_batch_digest
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery request batch digest returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (computed_batch_digest != source.batch_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request carried batch digest is inconsistent"
      );

    ctx_snapshot = new();
    if (!rdma_cmq_try_snapshot_identity_direct(
          source.expected_function_identity, identity_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request identity snapshot failed"
      );
    status = source.binding.snapshot_complete_nonfatal(binding_snapshot);
    if (status == null || !status.ok() || binding_snapshot == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery request binding snapshot returned null status"
      ) : journal_status(status.code, status.message);
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_image_direct(
          source.doorbell_image, 1'b0, doorbell_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request CMQ/doorbell snapshot failed"
      );

    candidate = new("journal_recovery_request_snapshot");
    candidate.batch_key = source.batch_key;
    candidate.batch_id = source.batch_id;
    candidate.expected_attempt_id = source.expected_attempt_id;
    candidate.expected_function_identity = identity_snapshot;
    candidate.binding = binding_snapshot;
    candidate.cmq_h = cmq_snapshot;
    candidate.start_sequence = source.start_sequence;
    candidate.end_sequence = source.end_sequence;
    candidate.doorbell_image = doorbell_snapshot;
    candidate.final_pi = source.final_pi;
    candidate.final_polarity = source.final_polarity;
    candidate.batch_digest = source.batch_digest;
    candidate.action = source.action;

    foreach (source.items[i]) begin
      rdma_cmq_submission_recovery_item source_item;
      rdma_cmq_submission_recovery_item item_snapshot;
      rdma_cmq_recovery_owner owner_snapshot;
      rdma_cmq_command_desc command_snapshot;
      rdma_cmq_ticket ticket_snapshot;
      rdma_dma_request_context dma_snapshot;
      rdma_hw_image sqe_snapshot;
      rdma_dma_mapping mapping_snapshot;
      rdma_hw_image dependency_snapshot;

      source_item = source.items[i];
      if (!ctx_snapshot.try_snapshot_recovery_owner(
            source_item.recovery_owner, owner_snapshot, failure_reason
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ recovery request owner snapshot failed: ", failure_reason}
        );
      status = snapshot_command_with_profile_locked(
        source_item.command, owner_snapshot, ctx_snapshot, profile,
        command_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request command snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!ctx_snapshot.try_snapshot_optional_ticket(
            source_item.ticket, ticket_snapshot, failure_reason
          ) || ticket_snapshot == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ recovery request ticket snapshot failed: ", failure_reason}
        );
      status = snapshot_journal_dma_context_locked(
        source_item.dma_context, dma_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request DMA snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!rdma_cmq_try_snapshot_image_direct(
            source_item.sqe_image, 1'b0, sqe_snapshot
          ) || !rdma_cmq_try_snapshot_image_direct(
            source_item.dependency_image, 1'b0, dependency_snapshot
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request image snapshot failed"
        );
      if (mapping_snapshots.exists(source_item.dependency_mapping)) begin
        mapping_snapshot =
          mapping_snapshots[source_item.dependency_mapping];
      end
      else begin
        status = snapshot_journal_mapping_locked(
          source_item.dependency_mapping, mapping_snapshot
        );
        if (status == null || !status.ok())
          return (status == null) ? journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ recovery request mapping snapshot returned null status"
          ) : journal_status(status.code, status.message);
        mapping_snapshots[source_item.dependency_mapping] =
          mapping_snapshot;
      end
      item_snapshot = new($sformatf(
        "journal_recovery_item_snapshot_%0d", i
      ));
      item_snapshot.request_index = source_item.request_index;
      item_snapshot.command = command_snapshot;
      item_snapshot.ticket = ticket_snapshot;
      item_snapshot.recovery_owner = owner_snapshot;
      item_snapshot.dma_context = dma_snapshot;
      item_snapshot.sqe_image = sqe_snapshot;
      item_snapshot.dependency_mapping = mapping_snapshot;
      item_snapshot.dependency_offset = source_item.dependency_offset;
      item_snapshot.dependency_image = dependency_snapshot;
      item_snapshot.image_digest = source_item.image_digest;
      item_snapshot.authority_digest = source_item.authority_digest;
      if (item_snapshot.command.recovery_owner !=
          item_snapshot.recovery_owner)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request command/owner alias changed"
        );
      candidate.items.push_back(item_snapshot);
    end

    proof_snapshot = null;
    if (source.reset_isolation_proof != null) begin
      status = snapshot_reset_proof_with_context_locked(
        source.reset_isolation_proof, ctx_snapshot, proof_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request proof snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (source.reset_isolation_proof.batch_key != source.batch_key ||
          source.reset_isolation_proof.batch_id != source.batch_id ||
          source.reset_isolation_proof.attempt_id !=
            source.expected_attempt_id ||
          source.reset_isolation_proof.batch_digest != source.batch_digest)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request reset proof does not identify this batch"
        );
    end
    candidate.reset_isolation_proof = proof_snapshot;
    if (candidate == source || candidate.expected_function_identity ==
          source.expected_function_identity ||
        candidate.binding == source.binding || candidate.cmq_h == source.cmq_h ||
        candidate.doorbell_image == source.doorbell_image ||
        candidate.items.size() != source.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request snapshot is partial or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：比较 recovery item 与 journal item 的四个重算 digest，可信后逐字段复验 command/body/owner/
  //  ticket/DMA/image/mapping。
  // 输入/输出及副作用：request_item、journal_item 与四个 digest 均只读；返回非空 status，不改任何状态。
  // 失败/边界：digest 不一致、command-owner alias 破坏或完整值漂移返回 INVALID_ARGUMENT；null/partial 图亦拒绝。
  protected function rdma_status validate_recovery_item_match_locked(
    input rdma_cmq_submission_recovery_item request_item,
    input rdma_cmq_batch_submission_item_record journal_item,
    input rdma_cmq_journal_digest_t recomputed_request_image_digest,
    input rdma_cmq_journal_digest_t recomputed_request_authority_digest,
    input rdma_cmq_journal_digest_t recomputed_journal_image_digest,
    input rdma_cmq_journal_digest_t recomputed_journal_authority_digest
  );
    if (request_item == null || journal_item == null ||
        request_item.command == null || journal_item.command == null ||
        request_item.ticket == null || journal_item.ticket == null ||
        request_item.recovery_owner == null ||
        journal_item.recovery_owner == null ||
        request_item.dma_context == null || journal_item.dma_context == null ||
        request_item.sqe_image == null || journal_item.sqe_image == null ||
        request_item.dependency_mapping == null ||
        journal_item.dependency_mapping == null ||
        request_item.dependency_image == null ||
        journal_item.dependency_image == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery item full-value graph is incomplete"
      );
    if (request_item.image_digest !== recomputed_request_image_digest ||
        request_item.authority_digest !==
          recomputed_request_authority_digest ||
        journal_item.image_digest !== recomputed_journal_image_digest ||
        journal_item.authority_digest !==
          recomputed_journal_authority_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery item carried digest does not match its graph"
      );
    if (recomputed_request_image_digest !==
          recomputed_journal_image_digest ||
        recomputed_request_authority_digest !==
          recomputed_journal_authority_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request and journal item digests disagree"
      );
    if (request_item.command.recovery_owner !=
          request_item.recovery_owner ||
        journal_item.command.recovery_owner !=
          journal_item.recovery_owner ||
        request_item.request_index != journal_item.request_index ||
        !same_handle(request_item.command.function_h,
                     journal_item.command.function_h) ||
        !same_opcode_value(request_item.command.opcode_key,
                           journal_item.command.opcode_key) ||
        !same_body_value(request_item.command.body,
                         journal_item.command.body) ||
        ((request_item.command.qpc_signature_source == null) !=
         (journal_item.command.qpc_signature_source == null)) ||
        (request_item.command.qpc_signature_source != null &&
         !same_image_value(request_item.command.qpc_signature_source,
                           journal_item.command.qpc_signature_source)) ||
        request_item.command.vfid_override !=
          journal_item.command.vfid_override ||
        request_item.command.use_vfid != journal_item.command.use_vfid ||
        request_item.command.timeout != journal_item.command.timeout ||
        !rdma_cmq_same_journal_owner_value(request_item.recovery_owner,
                                  journal_item.recovery_owner) ||
        !same_ticket_value(request_item.ticket, journal_item.ticket) ||
        !same_journal_dma_context_value(request_item.dma_context,
                                        journal_item.dma_context) ||
        !same_image_value(request_item.sqe_image,
                          journal_item.sqe_image) ||
        !same_journal_mapping_public_value(
          request_item.dependency_mapping,
          journal_item.dependency_mapping
        ) ||
        request_item.dependency_offset != journal_item.dependency_offset ||
        !same_image_value(request_item.dependency_image,
                          journal_item.dependency_image))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request and journal item full values disagree"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 设计说明：graph、digest、完整字段与 handle/binding/image/status seam 留在 engine，末尾有序 item
  //  tuple 仅调用无状态 package 谓词；前面的 graph gate 保证其额外防护不改变原失败优先级。
  // 功能：batch digest 重算后按既有优先级比较 request 与 journal 的完整固定值，最后判断 item 三列 tuple。
  // 输入/输出及副作用：request、journal_record 与两个 batch digest 只读；binding 比较会创建瞬态对象；
  //  不检查 lifecycle、不改 journal。
  // 失败/边界：graph 缺失或 item 为空/不等长优先拒绝，其次 carried/cross digest，再是完整字段与 tuple；
  //  均返回 INVALID_ARGUMENT，成功返回 OK；hash 相等不当作 authority。
  protected function rdma_status validate_recovery_batch_match_locked(
    input rdma_cmq_submission_recovery_request request,
    input rdma_cmq_batch_submission_record journal_record,
    input rdma_cmq_journal_digest_t recomputed_request_batch_digest,
    input rdma_cmq_journal_digest_t recomputed_journal_batch_digest
  );
    if (request == null || journal_record == null ||
        request.expected_function_identity == null ||
        journal_record.function_identity == null || request.binding == null ||
        journal_record.binding == null || request.cmq_h == null ||
        journal_record.cmq_h == null || request.doorbell_image == null ||
        journal_record.doorbell_image == null || request.items.size() == 0 ||
        request.items.size() != journal_record.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery batch full-value graph is incomplete"
      );
    if (request.batch_digest !== recomputed_request_batch_digest ||
        journal_record.batch_digest !== recomputed_journal_batch_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery batch carried digest does not match its graph"
      );
    if (recomputed_request_batch_digest !==
        recomputed_journal_batch_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request and journal batch digests disagree"
      );
    if (request.batch_key != journal_record.batch_key ||
        request.batch_id != journal_record.batch_id ||
        !request.expected_function_identity.same_incarnation(
          journal_record.function_identity
        ) || !rdma_cmq_same_journal_binding_value(request.binding,
                                          journal_record.binding) ||
        !same_handle(request.cmq_h, journal_record.cmq_h) ||
        !same_image_value(request.doorbell_image,
                          journal_record.doorbell_image) ||
        request.final_pi != journal_record.final_pi ||
        request.final_polarity != journal_record.final_polarity ||
        request.start_sequence != journal_record.start_sequence ||
        request.end_sequence != journal_record.end_sequence)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request and journal batch full values disagree"
      );
    if (!rdma_cmq_recovery_batch_ordered_item_tuple_matches(
          request, journal_record
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery batch ordered item tuple disagrees"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：为 recovery staging 直接构造 fail-closed execution result 外层值。
  // 输入/输出及副作用：name 为新对象名；返回调用方拥有的 result，不查询 journal/factory。
  // 失败/边界：直接 new 始终非空；virtual seam 允许测试在 CAS 前注入 null，调用方须发布 fallback。
  protected virtual function rdma_cmq_execution_result
  make_recovery_result_locked(input string name);
    rdma_cmq_execution_result result;

    result = new(name);
    return result;
  endfunction

  // 功能：为 recovery staging 创建 frozen owner 的 detached 完整值。
  // 输入/输出及副作用：name/source 只读；成功返回新 owner，不改 source 与 journal。
  // 失败/边界：source 为 null、非 legacy 的坏 shape 或嵌套快照失败返回 null；virtual seam 仅用于测试。
  protected virtual function rdma_cmq_recovery_owner
  make_recovery_owner_locked(
    input string name,
    input rdma_cmq_recovery_owner source
  );
    rdma_cmq_nonfatal_snapshot_context ctx_snapshot;
    rdma_cmq_recovery_owner snapshot;
    string failure_reason;

    ctx_snapshot = new();
    if (!ctx_snapshot.try_snapshot_recovery_owner(
          source, snapshot, failure_reason
        ))
      return null;
    snapshot.set_name(name);
    return snapshot;
  endfunction

  // 功能：为 recovery staging 直接构造空 doorbell 外层值。
  // 输入/输出及副作用：name 命名候选；返回新 descriptor，不调用 scheduler、不改 attempt counter。
  // 失败/边界：直接 new 始终非空；virtual seam 可在 CAS 前注入 null，调用方须保持 retained authority。
  protected virtual function rdma_doorbell_desc
  make_recovery_doorbell_locked(input string name);
    rdma_doorbell_desc doorbell;

    doorbell = new(name);
    return doorbell;
  endfunction

  // 功能：为 candidate attempt 直接构造尚未配置的一次性 MMIO observer。
  // 输入/输出及副作用：name 命名候选；返回独立 observer，不登记 capability。
  // 失败/边界：直接 new 始终非空；virtual seam 可返回 null 或已配置对象，失败须发生在 CAS/I/O 前。
  protected virtual function rdma_cmq_mmio_arm_observer
  make_recovery_observer_locked(input string name);
    rdma_cmq_mmio_arm_observer observer;

    observer = new(name);
    return observer;
  endfunction

  // 功能：用指定 profile 对 record 的 immutable digest 与 mutable lifecycle evidence 执行同一份完整
  //  invariant，区分首次安装与合法 retry 后的 attempt 关系。
  // 输入/输出及副作用：source/profile_service/initial_install 只读；调用 profile canonicalize body，
  //  重算 item/batch digest、batch state 与 recovery bit。
  // 失败/边界：key/shape/enum/reducer/classifier、owner attempt、completion alias、polymorph 或 digest
  //  任一不一致返回非空失败；不改 source/journal。
  protected function rdma_status validate_submission_record_locked(
    input rdma_cmq_batch_submission_record source,
    input rdma_cmq_hw_profile profile_service,
    input bit initial_install
  );
    string expected_batch_key;
    string format_failure;
    string service_name;
    bit key_formatted;
    bit request_seen[int unsigned];
    bit ticket_seen[string];
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_cmq_journal_digest_t computed_batch_digest;
    rdma_cmq_submission_state_e reduced_batch_state;
    rdma_status status;

    if (source == null || profile_service == null ||
        source.get_object_type() != rdma_cmq_batch_submission_record::get_type() ||
        source.function_identity == null || source.binding == null ||
        source.cmq_h == null || source.doorbell_image == null ||
        source.batch_key.len() == 0 || source.batch_id == 0 ||
        source.attempt_id == 0 || source.engine_instance_id == 0 ||
        source.engine_incarnation == 0 || source.items.size() == 0 ||
        source.start_sequence >= source.end_sequence ||
        source.end_sequence - source.start_sequence != source.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record fixed projection is incomplete or inconsistent"
      );
    if (source.engine_instance_id != engine_instance_id)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record belongs to a different engine instance"
      );
    key_formatted = rdma_cmq_format_batch_key(
      source.function_identity, source.engine_instance_id,
      source.engine_incarnation, source.batch_id, expected_batch_key,
      format_failure
    );
    if (!key_formatted || expected_batch_key != source.batch_key)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        key_formatted ? "CMQ journal batch key is not canonical" :
                        {"CMQ journal batch key formatting failed: ",
                         format_failure}
      );
    service_name = profile_service.profile_name();
    if (service_name.len() == 0 ||
        rdma_cmq_string_has_separator(service_name))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal retained profile name is invalid"
      );
    if (!rdma_cmq_submission_state_valid(source.state) ||
        !rdma_cmq_submission_effect_valid(source.submission_effect) ||
        !rdma_cmq_submission_effect_valid(source.attempt_effect))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal batch mutable evidence contains an invalid enum"
      );

    foreach (source.items[i]) begin
      rdma_cmq_batch_submission_item_record item;
      rdma_cmq_journal_digest_t computed_image_digest;
      rdma_cmq_journal_digest_t computed_authority_digest;
      bit classified_recovery_required;
      string body_tag;
      byte unsigned body_bytes[];
      string ticket_key;

      item = source.items[i];
      if (item == null ||
          item.get_object_type() !=
            rdma_cmq_batch_submission_item_record::get_type() ||
          item.command == null || item.ticket == null ||
          item.recovery_owner == null ||
          item.command.recovery_owner != item.recovery_owner ||
          item.dma_context == null || item.sqe_image == null ||
          item.dependency_mapping == null || item.dependency_image == null ||
          item.status == null || item.command.opcode_key == null ||
          item.ticket.opcode_key == null || item.entry_key.len() == 0 ||
          item.command.opcode_key.profile_name != service_name ||
          item.ticket.opcode_key.profile_name != service_name ||
          item.slot_sequence != item.ticket.slot_sequence ||
          item.slot_index != item.ticket.sq_index ||
          item.slot_wrap != item.ticket.sq_wrap ||
          item.token_incarnation != source.engine_incarnation[58:0])
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ journal item %0d projection is incomplete", i)
        );
      if (!rdma_cmq_submission_state_valid(item.state) ||
          !rdma_cmq_submission_effect_valid(item.submission_effect) ||
          !rdma_cmq_submission_effect_valid(item.attempt_effect) ||
          !rdma_cmq_completion_phase_valid(item.completion_phase))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf(
            "CMQ journal item %0d mutable evidence has an invalid enum", i
          )
        );
      if (!rdma_cmq_frozen_owner_shape_valid(item.recovery_owner))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ journal item %0d recovery owner is invalid", i)
        );
      if (!item.recovery_owner.is_legacy_unmigrated() &&
          (item.recovery_owner.admission_attempt_id > source.attempt_id ||
           (initial_install &&
            item.recovery_owner.admission_attempt_id != source.attempt_id)))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf(
            "CMQ journal item %0d owner attempt is not valid for the batch",
            i
          )
        );
      if (item.completion_phase inside {
            RDMA_CMQ_COMPLETION_TERMINAL,
            RDMA_CMQ_COMPLETION_TIMEOUT,
            RDMA_CMQ_COMPLETION_RESET_CANCELLED,
            RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY
          } && item.completion == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ journal item %0d requires a completion", i)
        );
      if (item.completion != null &&
          (item.completion.ticket != item.ticket ||
           item.completion.status != item.status))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf(
            "CMQ journal item %0d completion aliases are inconsistent", i
          )
        );
      status = rdma_cmq_classify_recovery_required(
        item.state, item.completion_phase, item.submission_effect,
        item.reset_isolation_confirmed,
        item.recovery_owner.is_legacy_unmigrated(),
        classified_recovery_required
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal recovery classifier returned null status"
        );
      if (!status.ok())
        return journal_status(RDMA_SC_INVALID_ARGUMENT, status.message);
      if (classified_recovery_required != item.recovery_required)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf(
            "CMQ journal item %0d recovery classification disagrees", i
          )
        );
      if (request_seen.exists(item.request_index))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal record contains a duplicate request index"
        );
      request_seen[item.request_index] = 1'b1;
      if (!rdma_cmq_ticket_shape_valid(item.ticket))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal record contains an invalid ticket"
        );
      ticket_key = command_key(item.ticket);
      if (ticket_key.len() == 0 || ticket_seen.exists(ticket_key))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal record contains a duplicate or empty ticket key"
        );
      ticket_seen[ticket_key] = 1'b1;
      status = canonicalize_journal_body(
        profile_service, item.command, item.sqe_image,
        body_tag, body_bytes
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal body canonicalization returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      status = rdma_cmq_compute_item_digests(
        item.command, body_tag, body_bytes, item.ticket,
        item.recovery_owner, source.function_identity, item.dma_context,
        item.sqe_image, item.dependency_mapping, item.dependency_offset,
        item.dependency_image, computed_image_digest,
        computed_authority_digest
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal item digest computation returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      if (computed_image_digest != item.image_digest ||
          computed_authority_digest != item.authority_digest)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal item carried digest does not match its graph"
        );
      request_indices.push_back(item.request_index);
      image_digests.push_back(computed_image_digest);
      authority_digests.push_back(computed_authority_digest);
    end
    status = rdma_cmq_reduce_batch_state(source.items, reduced_batch_state);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal batch state reducer returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_ARGUMENT, status.message);
    if (reduced_batch_state != source.state)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal batch state disagrees with its item reduction"
      );
    status = rdma_cmq_compute_batch_digest(
      source.function_identity, source.binding, source.cmq_h,
      source.doorbell_image, source.final_pi, source.final_polarity,
      source.start_sequence, source.end_sequence, request_indices,
      image_digests, authority_digests, computed_batch_digest
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal batch digest computation returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (computed_batch_digest != source.batch_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal carried batch digest does not match its graph"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：验证并直接复制与 detached record 一一对应的预分配发布批次。
  // 输入/输出及副作用：source、source_record、record_snapshot 为输入；snapshot 入口清空；复用
  //  record_snapshot 的 ticket 以维持 engine-owned alias。
  // 失败/边界：批次/SQE-CQE 格式/cardinality、slot/key/token 或 expected-response 漂移返回
  //  INVALID_ARGUMENT/null；doorbell 用独立 codec 格式，不强制等于 profile 的 SQE/CQE 格式。
  protected function rdma_status snapshot_preallocated_publish_batch_locked(
    input rdma_cmq_preallocated_publish_batch source,
    input rdma_cmq_batch_submission_record source_record,
    input rdma_cmq_batch_submission_record record_snapshot,
    output rdma_cmq_preallocated_publish_batch snapshot
  );
    rdma_cmq_preallocated_publish_batch candidate;

    snapshot = null;
    if (source == null || source_record == null || record_snapshot == null ||
        source.get_object_type() !=
          rdma_cmq_preallocated_publish_batch::get_type() ||
        source.batch_key != source_record.batch_key ||
        source.batch_key != record_snapshot.batch_key ||
        source.attempt_id != source_record.attempt_id ||
        source.final_sequence != source_record.end_sequence ||
        !source.profile_format_valid ||
        !(source.profile_endian inside {RDMA_ENDIAN_LITTLE,
                                        RDMA_ENDIAN_BIG}) ||
        source.profile_hardware_version == 0 ||
        source.items.size() != source_record.items.size() ||
        record_snapshot.items.size() != source_record.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ preallocated publication batch is incomplete or inconsistent"
      );
    candidate = new("journal_preallocated_batch_snapshot");
    candidate.batch_key = source.batch_key;
    candidate.attempt_id = source.attempt_id;
    candidate.final_sequence = source.final_sequence;
    candidate.profile_format_valid = source.profile_format_valid;
    candidate.profile_endian = source.profile_endian;
    candidate.profile_hardware_version =
      source.profile_hardware_version;
    foreach (source.items[i]) begin
      rdma_cmq_preallocated_publish_item source_item;
      rdma_cmq_preallocated_publish_item item_snapshot;
      rdma_cmq_slot_record slot_snapshot;
      rdma_cmq_expected_response expected_snapshot;

      source_item = source.items[i];
      if (source_item == null || source_record.items[i] == null ||
          record_snapshot.items[i] == null ||
          source_item.get_object_type() !=
            rdma_cmq_preallocated_publish_item::get_type() ||
          source_item.slot_record == null ||
          source_item.slot_record.get_object_type() !=
            rdma_cmq_slot_record::get_type() ||
          source_item.slot_record.ticket == null ||
          source_item.slot_record.expected == null ||
          source_item.slot_record.expected.get_object_type() !=
            rdma_cmq_expected_response::get_type() ||
          source_item.request_index !=
            source_record.items[i].request_index ||
          !same_ticket_value(source_item.slot_record.ticket,
                             source_record.items[i].ticket) ||
          source_item.slot_record.slot_sequence !=
            source_record.items[i].slot_sequence ||
          source_item.slot_record.sq_index !=
            source_record.items[i].slot_index ||
          source_item.slot_record.sq_wrap !=
            source_record.items[i].slot_wrap ||
          source_item.slot_record.state != CMQ_SLOT_PUBLISHED ||
          source_item.slot_record.command_token !=
            source_record.items[i].command_token ||
          source_item.slot_record.batch_key != source_record.batch_key ||
          source_item.slot_record.journal_item_index != i ||
          source_item.command_key != command_key(
            source_record.items[i].ticket
          ) || source_item.entry_key != source_record.items[i].entry_key ||
          source_item.command_token !=
            source_record.items[i].command_token ||
          source_record.items[i].sqe_image.endian !=
            source.profile_endian ||
          source_record.items[i].sqe_image.hardware_version !=
            source.profile_hardware_version ||
          source_record.items[i].dependency_image.endian !=
            source.profile_endian ||
          source_record.items[i].dependency_image.hardware_version !=
            source.profile_hardware_version)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ preallocated publication item %0d is partial", i)
        );
      expected_snapshot = new($sformatf(
        "journal_preallocated_expected_%0d", i
      ));
      expected_snapshot.hardware_opcode =
        source_item.slot_record.expected.hardware_opcode;
      expected_snapshot.variant = source_item.slot_record.expected.variant;
      if (expected_snapshot.variant.len() == 0 ||
          rdma_cmq_string_has_separator(expected_snapshot.variant))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ preallocated expected response is invalid"
        );
      slot_snapshot = new($sformatf(
        "journal_preallocated_slot_%0d", i
      ));
      slot_snapshot.slot_sequence = source_item.slot_record.slot_sequence;
      slot_snapshot.sq_index = source_item.slot_record.sq_index;
      slot_snapshot.sq_wrap = source_item.slot_record.sq_wrap;
      slot_snapshot.state = source_item.slot_record.state;
      slot_snapshot.ticket = record_snapshot.items[i].ticket;
      slot_snapshot.expected = expected_snapshot;
      slot_snapshot.command_token = source_item.slot_record.command_token;
      slot_snapshot.batch_key = source_item.slot_record.batch_key;
      slot_snapshot.journal_item_index =
        source_item.slot_record.journal_item_index;
      item_snapshot = new($sformatf(
        "journal_preallocated_item_%0d", i
      ));
      item_snapshot.request_index = source_item.request_index;
      item_snapshot.slot_record = slot_snapshot;
      item_snapshot.command_key = source_item.command_key;
      item_snapshot.entry_key = source_item.entry_key;
      item_snapshot.command_token = source_item.command_token;
      candidate.items.push_back(item_snapshot);
    end
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：检查指定 key 的 record/profile 主行是否同生同在，区分 arm 前后的 preallocation 生命周期：
  //  未 arm 必须有预分配行，已 arm 可已消费。
  // 输入/输出及副作用：batch_key 输入，row_set_present 输出 0/1（完整缺席/完整存在）；只读三张表。
  // 失败/边界：空 key 返回 INVALID_ARGUMENT；record/profile 孤行、null 行、无 record 的 preallocation，
  //  或 observer_armed=0 却缺 preallocation 返回 INVALID_STATE。
  protected function rdma_status journal_row_set_existence_locked(
    input string batch_key,
    output bit row_set_present
  );
    bit record_present;
    bit preallocation_present;
    bit profile_present;

    row_set_present = 1'b0;
    if (batch_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is empty"
      );
    record_present = submission_journal.exists(batch_key);
    preallocation_present = preallocated_publish_batches.exists(batch_key);
    profile_present = journal_profile_by_batch.exists(batch_key);
    if (record_present != profile_present)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal record/profile rows are orphaned"
      );
    if (!record_present) begin
      if (preallocation_present)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal preallocation row is orphaned"
        );
      return journal_status(RDMA_SC_OK);
    end
    if (submission_journal[batch_key] == null ||
        journal_profile_by_batch[batch_key] == null ||
        (preallocation_present &&
         preallocated_publish_batches[batch_key] == null))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal record/preallocation/profile row contains null"
      );
    // // preallocation 只在首次 arm/retry 的 pre-MMIO 窗口提供安装值；证据写入 retained item 后 reset
    // // commit 会删除旧 runtime/preallocation，这些终态仍须可查询。
    if (!preallocation_present &&
        !submission_journal[batch_key].observer_armed &&
        submission_journal[batch_key].state inside {
          RDMA_CMQ_SUBMISSION_STAGED,
          RDMA_CMQ_SUBMISSION_PENDING_EFFECT,
          RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED
        })
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ unarmed journal record has no preallocation row"
      );
    row_set_present = 1'b1;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：确认每条 ticket index 都指向完整、非空的 retained 主表行。
  // 输入/输出及副作用：无输入；遍历 journal_batch_by_ticket 并只读三张主表，不修改状态。
  // 失败/边界：空 index/target、目标表缺失、部分存在、null 行或 helper null status 返回 INVALID_STATE；
  //  空 index 表合法。
  protected function rdma_status journal_ticket_index_targets_locked();
    bit target_present;
    rdma_status status;

    foreach (journal_batch_by_ticket[ticket_key]) begin
      string target_batch_key;

      target_batch_key = journal_batch_by_ticket[ticket_key];
      if (ticket_key.len() == 0 || target_batch_key.len() == 0)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal ticket index contains an empty key or target"
        );
      status = journal_row_set_existence_locked(
        target_batch_key, target_present
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal ticket target check returned null status"
        );
      if (!status.ok() || !target_present)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          status.ok() ?
            "CMQ journal ticket index targets a missing row set" :
            status.message
        );
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：检查一个 batch 的 record/ticket-index/preallocation/profile 四表一致性。
  // 输入/输出及副作用：batch_key 输入；先全局审计 index target，再只读该 batch 的主表与各 ticket；
  //  形成 key 前先验证 ticket shape。
  // 失败/边界：完整缺失返回 INVALID_ARGUMENT；orphan/null/坏 ticket、索引路由或 cardinality 不一致
  //  返回 INVALID_STATE；不自动修复。
  protected function rdma_status submission_journal_invariant_locked(
    input string batch_key
  );
    rdma_cmq_batch_submission_record record;
    bit row_set_present;
    int unsigned indexed_count;
    rdma_status status;

    if (batch_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is not present"
      );
    status = journal_ticket_index_targets_locked();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket target invariant returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    status = journal_row_set_existence_locked(batch_key, row_set_present);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal row-set invariant returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    if (!row_set_present)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is not present"
      );
    record = submission_journal[batch_key];
    if (record == null || record.batch_key != batch_key)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal batch row is inconsistent"
      );
    if (preallocated_publish_batches.exists(batch_key) &&
        (preallocated_publish_batches[batch_key].batch_key != batch_key ||
         preallocated_publish_batches[batch_key].items.size() !=
           record.items.size()))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal preallocation row is inconsistent"
      );
    foreach (record.items[i]) begin
      string ticket_key;

      if (record.items[i] == null ||
          !rdma_cmq_ticket_shape_valid(record.items[i].ticket))
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal retained item or ticket shape is invalid"
        );
      ticket_key = command_key(record.items[i].ticket);
      if (!journal_batch_by_ticket.exists(ticket_key) ||
          journal_batch_by_ticket[ticket_key] != batch_key)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal retained ticket index is missing or misrouted"
        );
    end
    indexed_count = 0;
    foreach (journal_batch_by_ticket[ticket_key]) begin
      if (journal_batch_by_ticket[ticket_key] == batch_key)
        indexed_count++;
    end
    if (indexed_count != record.items.size())
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal retained ticket index cardinality is inconsistent"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：锁内为当前 engine incarnation 分配下一个非零 batch ID 与 canonical key。
  // 输入/输出及副作用：identity 输入；batch_key/batch_id 入口清空；成功才推进 batch_id_counter，
  //  不安装 journal 行。
  // 失败/边界：identity/engine/incarnation 无效、counter 耗尽、formatter 或四表 key 冲突时输出为空/零，
  //  counter 不变。
  protected function rdma_status allocate_batch_identity_locked(
    input rdma_function_identity identity,
    output string batch_key,
    output longint unsigned batch_id
  );
    longint unsigned candidate_id;
    bit row_set_present;
    string candidate_key;
    string failure_reason;
    rdma_status status;

    batch_key = "";
    batch_id = 0;
    if (engine_instance_id == 0 || engine_incarnation == 0 ||
        identity == null ||
        identity.get_object_type() != rdma_function_identity::get_type() ||
        !rdma_cmq_identity_shape_valid(identity))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ batch allocation identity or engine incarnation is invalid"
      );
    if (batch_id_counter == 64'hffff_ffff_ffff_ffff)
      return journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED, "CMQ batch IDs are exhausted"
      );
    candidate_id = batch_id_counter + 1'b1;
    if (!rdma_cmq_format_batch_key(
          identity, engine_instance_id, engine_incarnation, candidate_id,
          candidate_key, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ batch key allocation failed: ", failure_reason}
      );
    status = journal_ticket_index_targets_locked();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ batch allocation ticket target check returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    status = journal_row_set_existence_locked(
      candidate_key, row_set_present
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ batch allocation row-set check returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    if (row_set_present)
      return journal_status(
        RDMA_SC_RESOURCE_BUSY, "CMQ batch key is already allocated"
      );
    batch_id_counter = candidate_id;
    batch_key = candidate_key;
    batch_id = candidate_id;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：锁内分配下一个 engine-lifetime 非零 attempt ID。
  // 输入/输出及副作用：attempt_id 入口清零；成功推进 attempt_id_counter。
  // 失败/边界：counter 为 64 位最大值时返回 RESOURCE_EXHAUSTED，状态不变。
  protected function rdma_status allocate_attempt_id_locked(
    output longint unsigned attempt_id
  );
    attempt_id = 0;
    if (attempt_id_counter == 64'hffff_ffff_ffff_ffff)
      return journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED, "CMQ attempt IDs are exhausted"
      );
    attempt_id_counter++;
    attempt_id = attempt_id_counter;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：锁内分配下一个 engine-lifetime 非零 reset-proof ID。
  // 输入/输出及副作用：proof_id 入口清零；成功推进 reset_proof_id_counter。
  // 失败/边界：counter 为最大值时返回 RESOURCE_EXHAUSTED，不回绕。
  protected function rdma_status allocate_reset_proof_id_locked(
    output longint unsigned proof_id
  );
    proof_id = 0;
    if (reset_proof_id_counter == 64'hffff_ffff_ffff_ffff)
      return journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED, "CMQ reset proof IDs are exhausted"
      );
    reset_proof_id_counter++;
    proof_id = reset_proof_id_counter;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：把完整 record、ticket index、预分配值和 exact profile 作为一个原子行组安装。
  // 输入/输出及副作用：record/preallocated 为非拥有输入；成功后四表拥有 detached 值，profile 表仅存
  //  安装时 service 的非拥有句柄。
  // 失败/边界：未配置 profile、digest/graph/cardinality 失败、batch/ticket 冲突或 snapshot 失败时零行提交；
  //  重复 key/ticket 返回 RESOURCE_BUSY。
  protected function rdma_status install_submission_journal_locked(
    input rdma_cmq_batch_submission_record record,
    input rdma_cmq_preallocated_publish_batch preallocated
  );
    rdma_cmq_batch_submission_record record_snapshot;
    rdma_cmq_preallocated_publish_batch preallocated_snapshot;
    bit row_set_present;
    string candidate_ticket_keys[$];
    rdma_status status;

    if (record == null || preallocated == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal installation source record or preallocation is null"
      );
    if (profile == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal installation has no active profile service"
      );
    status = journal_row_set_existence_locked(
      record.batch_key, row_set_present
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal installation row-set check returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    status = journal_ticket_index_targets_locked();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal installation ticket target check returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    if (row_set_present)
      return journal_status(
        RDMA_SC_RESOURCE_BUSY, "CMQ journal batch key is already installed"
      );

    status = validate_submission_record_locked(record, profile, 1'b1);
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal candidate validation returned null status"
      ) : journal_status(status.code, status.message);
    foreach (record.items[i]) begin
      string ticket_key;

      ticket_key = command_key(record.items[i].ticket);
      if (journal_batch_by_ticket.exists(ticket_key))
        return journal_status(
          RDMA_SC_RESOURCE_BUSY,
          "CMQ journal ticket identity is already installed"
        );
      candidate_ticket_keys.push_back(ticket_key);
    end

    status = snapshot_journal_record_with_profile_locked(
      record, profile, record_snapshot
    );
    if (status == null || !status.ok() || record_snapshot == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal candidate snapshot returned null status"
      ) : journal_status(status.code, status.message);
    status = validate_submission_record_locked(
      record_snapshot, profile, 1'b1
    );
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal detached candidate validation returned null status"
      ) : journal_status(status.code, status.message);
    status = snapshot_preallocated_publish_batch_locked(
      preallocated, record, record_snapshot, preallocated_snapshot
    );
    if (status == null || !status.ok() || preallocated_snapshot == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ preallocated publication snapshot returned null status"
      ) : journal_status(status.code, status.message);

    // // 可能失败的构造、canonicalization 与冲突检查均已完成；以下赋值在 engine_lock 下构成单次
    // // 不可观察中间态的 publication commit。
    submission_journal[record.batch_key] = record_snapshot;
    preallocated_publish_batches[record.batch_key] =
      preallocated_snapshot;
    journal_profile_by_batch[record.batch_key] = profile;
    foreach (candidate_ticket_keys[i])
      journal_batch_by_ticket[candidate_ticket_keys[i]] = record.batch_key;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 设计说明：该入口仅因 observer 需同步回调而公开；调用方已持 engine_lock，故先完整收集只读证据，
  //  通过后才做无失败的句柄转移与标量迁移，禁止构造或外部重入。
  // 功能：认证 registered observer 与 journal tuple（含 slot 的 batch key/item 下标），把预分配
  //  slot/token/command/entry 装入 runtime，并把 batch/items 推进到 PUBLISH_AMBIGUOUS。
  // 输入/输出及副作用：observer 非拥有；成功推进 publish_seq 一次、安装预建句柄、更新
  //  MMIO_MAYBE_VISIBLE 证据，再删除 capability 与 preallocation 行；不取锁、不等待、不调用外部服务。
  // 失败/边界：null/未配置、身份伪造、tuple 漂移、缺行、lifecycle 过期、冲突或重复调用只报
  //  RDMA_CMQ_MMIO_ARM_INVALID 且零状态变化。
  function void arm_submission_for_mmio(
    input rdma_cmq_mmio_arm_observer observer
  );
    rdma_cmq_batch_submission_record record;
    rdma_cmq_preallocated_publish_batch preallocated;
    string capability_key;
    string batch_key;
    bit valid;
    rdma_submission_effect_e armed_cumulative;

    record = null;
    preallocated = null;
    capability_key = "";
    batch_key = "";
    valid = observer != null;
    if (reset_release_in_progress) begin
      `uvm_error("RDMA_CMQ_MMIO_ARM_INVALID",
                 "CMQ MMIO arm is blocked during reset backing release")
      return;
    end
    if (valid) begin
      valid = observer.is_configured() && observer.owner_handle() == this;
      if (valid) begin
        capability_key = observer.get_capability_key();
        batch_key = observer.get_batch_key();
        valid = capability_key.len() != 0 && batch_key.len() != 0 &&
                observer.get_attempt_id() != 0 &&
                observer.get_engine_incarnation() != 0 &&
                arm_observers.exists(capability_key) &&
                arm_observers[capability_key] == observer &&
                submission_journal.exists(batch_key) &&
                preallocated_publish_batches.exists(batch_key) &&
                journal_profile_by_batch.exists(batch_key);
      end
      if (valid) begin
        record = submission_journal[batch_key];
        preallocated = preallocated_publish_batches[batch_key];
        valid = record != null && preallocated != null &&
                journal_profile_by_batch[batch_key] != null;
      end
      if (valid)
        valid = record.batch_key == batch_key &&
                record.attempt_id == observer.get_attempt_id() &&
                record.engine_incarnation ==
                  observer.get_engine_incarnation() &&
                engine_incarnation == observer.get_engine_incarnation() &&
                record.state == RDMA_CMQ_SUBMISSION_PENDING_EFFECT &&
                record.observer_armed == 1'b0 &&
                record.submission_effect inside {
                  RDMA_SUBMIT_EFFECT_UNOBSERVED,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
                } && record.attempt_effect inside {
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
                } &&
                record.items.size() != 0 &&
                record.start_sequence == publish_seq &&
                record.end_sequence > record.start_sequence &&
                record.end_sequence - record.start_sequence ==
                  record.items.size() &&
                preallocated.batch_key == batch_key &&
                preallocated.attempt_id == observer.get_attempt_id() &&
                preallocated.final_sequence == record.end_sequence &&
                preallocated.profile_format_valid &&
                preallocated.profile_endian inside {
                  RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG
                } && preallocated.profile_hardware_version != 0 &&
                preallocated.items.size() == record.items.size();
      if (valid)
        valid = rdma_cmq_fold_attempt_effect(
          record.submission_effect,
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
          armed_cumulative
        );
      if (valid && profile_image_format_valid)
        valid = profile_image_endian == preallocated.profile_endian &&
                profile_hardware_version ==
                  preallocated.profile_hardware_version;
      if (valid) begin
        foreach (record.items[i]) begin
          rdma_cmq_batch_submission_item_record item;
          rdma_cmq_preallocated_publish_item preallocated_item;

          item = record.items[i];
          preallocated_item = preallocated.items[i];
          if (item == null || preallocated_item == null ||
              preallocated_item.slot_record == null) begin
            valid = 1'b0;
            break;
          end
          if (item.state != RDMA_CMQ_SUBMISSION_PENDING_EFFECT ||
              item.submission_effect != record.submission_effect ||
              item.attempt_effect != record.attempt_effect ||
              item.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
              item.reset_isolation_confirmed || !item.recovery_required ||
              preallocated_item.request_index != item.request_index ||
              preallocated_item.command_key.len() == 0 ||
              preallocated_item.entry_key.len() == 0 ||
              preallocated_item.entry_key != item.entry_key ||
              preallocated_item.command_token != item.command_token ||
              preallocated_item.slot_record.ticket != item.ticket ||
              preallocated_item.slot_record.slot_sequence !=
                item.slot_sequence ||
              preallocated_item.slot_record.sq_index != item.slot_index ||
              preallocated_item.slot_record.sq_wrap != item.slot_wrap ||
              preallocated_item.slot_record.state != CMQ_SLOT_PUBLISHED ||
              preallocated_item.slot_record.expected == null ||
              preallocated_item.slot_record.command_token !=
                item.command_token ||
              preallocated_item.slot_record.batch_key != batch_key ||
              preallocated_item.slot_record.journal_item_index != i ||
              item.slot_index >= CMQ_DEPTH ||
              slots[item.slot_index] != null ||
              token_in_use[item.command_token] ||
              command_registry.exists(preallocated_item.command_key) ||
              entry_registry.exists(preallocated_item.entry_key)) begin
            valid = 1'b0;
            break;
          end
          for (int unsigned prior = 0; prior < i; prior++) begin
            if (preallocated.items[prior] == null ||
                preallocated.items[prior].slot_record == null ||
                preallocated.items[prior].slot_record.sq_index ==
                  preallocated_item.slot_record.sq_index ||
                preallocated.items[prior].command_token ==
                  preallocated_item.command_token ||
                preallocated.items[prior].command_key ==
                  preallocated_item.command_key ||
                preallocated.items[prior].entry_key ==
                  preallocated_item.entry_key) begin
              valid = 1'b0;
              break;
            end
          end
          if (!valid)
            break;
        end
      end
    end

    // // arm 入口来自 scheduler/MMIO 上下文，不取 engine_lock；发布提交前再查 release gate，
    // // 避免并发 reset 在 backing 交给 adapter 后暴露 slot。
    if (reset_release_in_progress)
      valid = 1'b0;
    if (!valid) begin
      `uvm_error("RDMA_CMQ_MMIO_ARM_INVALID",
                 "CMQ MMIO arm capability is invalid")
      return;
    end

    // // 认证、cardinality 与冲突检查已完成；以下仅转移预建句柄、写标量、删关联行，
    // // 无 new/factory/format/wait/lock/外部调用，不会出现 partial failure。
    foreach (record.items[i]) begin
      rdma_cmq_batch_submission_item_record item;
      rdma_cmq_preallocated_publish_item preallocated_item;
      int unsigned slot_index;
      int unsigned token_index;

      item = record.items[i];
      preallocated_item = preallocated.items[i];
      slot_index = preallocated_item.slot_record.sq_index;
      token_index = preallocated_item.command_token;
      slots[slot_index] = preallocated_item.slot_record;
      token_in_use[token_index] = 1'b1;
      command_registry[preallocated_item.command_key] =
        preallocated_item.slot_record;
      entry_registry[preallocated_item.entry_key] =
        preallocated_item.slot_record;
      item.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
      item.submission_effect = armed_cumulative;
      item.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
      item.completion_phase = RDMA_CMQ_COMPLETION_PENDING;
      item.recovery_required = 1'b1;
    end
    publish_seq = preallocated.final_sequence;
    profile_image_format_valid = preallocated.profile_format_valid;
    profile_image_endian = preallocated.profile_endian;
    profile_hardware_version = preallocated.profile_hardware_version;
    record.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
    record.submission_effect = armed_cumulative;
    record.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
    record.observer_armed = 1'b1;
    if (fenced_batch_key == batch_key) begin
      fenced_batch_key = "";
      submission_fence_reason = "";
    end
    arm_observers.delete(capability_key);
    preallocated_publish_batches.delete(batch_key);
  endfunction

  // 功能：结构预检后同步删除一个 batch 的 record/index/preallocation/profile 行。
  // 输入/输出及副作用：batch_key 输入；成功删除四表及全部 ticket 索引。
  // 失败/边界：未知 key 返回 INVALID_ARGUMENT；retained invariant 损坏返回 INVALID_STATE 且不删行；
  //  重复删除不视为幂等成功。
  protected function rdma_status remove_submission_journal_locked(
    input string batch_key
  );
    rdma_cmq_batch_submission_record record;
    string ticket_keys[$];
    rdma_status status;

    if (batch_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is not installed"
      );
    status = submission_journal_invariant_locked(batch_key);
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal removal invariant returned null status"
      ) : journal_status(status.code, status.message);
    record = submission_journal[batch_key];
    foreach (record.items[i])
      ticket_keys.push_back(command_key(record.items[i].ticket));

    foreach (ticket_keys[i])
      journal_batch_by_ticket.delete(ticket_keys[i]);
    submission_journal.delete(batch_key);
    preallocated_publish_batches.delete(batch_key);
    journal_profile_by_batch.delete(batch_key);
    if (fenced_batch_key == batch_key) begin
      fenced_batch_key = "";
      submission_fence_reason = "";
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：锁内按 batch key 重验 retained profile/digest 并发布完整 detached record。
  // 输入/输出及副作用：batch_key 输入；record 入口清空；只读四表与 exact profile。
  // 失败/边界：未知 key 为 INVALID_ARGUMENT；结构/profile/graph/digest 损坏转 INVALID_STATE/null，
  //  不回退当前 profile。
  protected function rdma_status query_submission_journal_locked(
    input string batch_key,
    output rdma_cmq_batch_submission_record record
  );
    rdma_cmq_batch_submission_record candidate;
    rdma_cmq_hw_profile retained_profile;
    rdma_status status;

    record = null;
    if (batch_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is not installed"
      );
    status = submission_journal_invariant_locked(batch_key);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal invariant returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    retained_profile = journal_profile_by_batch[batch_key];
    if (retained_profile == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal retained profile service is missing"
      );
    status = validate_submission_record_locked(
      submission_journal[batch_key], retained_profile, 1'b0
    );
    if (status == null || !status.ok())
      return journal_status(
        RDMA_SC_INVALID_STATE,
        (status == null) ?
          "CMQ retained journal validation returned null status" :
          status.message
      );
    status = snapshot_journal_record_with_profile_locked(
      submission_journal[batch_key], retained_profile, candidate
    );
    if (status == null || !status.ok() || candidate == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        (status == null) ?
          "CMQ retained journal snapshot returned null status" :
          status.message
      );
    status = validate_submission_record_locked(
      candidate, retained_profile, 1'b0
    );
    if (status == null || !status.ok())
      return journal_status(
        RDMA_SC_INVALID_STATE,
        (status == null) ?
          "CMQ detached journal validation returned null status" :
          status.message
      );
    record = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：按 batch key 查询 journal 并返回 detached snapshot。
  // 输入/输出及副作用：record/status 为输出；入口清空 record；取并释放现有 engine_lock，调用方独占结果。
  // 失败/边界：未知 key 为 INVALID_ARGUMENT；metadata/profile/digest 损坏为 INVALID_STATE；不发布 partial。
  task query_submission_journal(
    input string batch_key,
    output rdma_cmq_batch_submission_record record,
    output rdma_status status
  );
    record = null;
    status = journal_status(
      RDMA_SC_INVALID_STATE, "CMQ journal query did not complete"
    );
    engine_lock.get(1);
    status = query_submission_journal_locked(batch_key, record);
    if (status == null) begin
      record = null;
      status = journal_status(
        RDMA_SC_INVALID_STATE, "CMQ journal query returned null status"
      );
    end
    engine_lock.put(1);
  endtask

  // 功能：以 ticket 稳定 key 定位 batch，先验证 retained graph 再比较全值。
  // 输入/输出及副作用：ticket 只读；record/status 输出；持锁审计全局 index，唯一匹配后才发布 record。
  // 失败/边界：坏/未知 ticket 或全值不匹配为 INVALID_ARGUMENT；orphan/index 歧义/损坏为 INVALID_STATE。
  task query_submission_journal_by_ticket(
    input rdma_cmq_ticket ticket,
    output rdma_cmq_batch_submission_record record,
    output rdma_status status
  );
    rdma_cmq_batch_submission_record candidate;
    rdma_cmq_ticket ticket_snapshot;
    string ticket_key;
    string batch_key;
    int unsigned match_count;

    record = null;
    status = journal_status(
      RDMA_SC_INVALID_STATE, "CMQ journal ticket query did not complete"
    );
    engine_lock.get(1);
    if (!rdma_cmq_ticket_shape_valid(ticket)) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal query ticket is invalid"
      );
      engine_lock.put(1);
      return;
    end
    status = checked_completion_ticket_snapshot(ticket, ticket_snapshot);
    if (status == null || !status.ok() || ticket_snapshot == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        (status == null) ?
          "CMQ journal query ticket snapshot returned null status" :
          {"CMQ journal query ticket snapshot failed: ", status.message}
      );
      engine_lock.put(1);
      return;
    end
    ticket_key = command_key(ticket_snapshot);
    status = journal_ticket_index_targets_locked();
    if (status == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket target check returned null status"
      );
      engine_lock.put(1);
      return;
    end
    if (!status.ok()) begin
      status = journal_status(RDMA_SC_INVALID_STATE, status.message);
      engine_lock.put(1);
      return;
    end
    if (!journal_batch_by_ticket.exists(ticket_key)) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal query ticket is not installed"
      );
      engine_lock.put(1);
      return;
    end
    batch_key = journal_batch_by_ticket[ticket_key];
    status = query_submission_journal_locked(batch_key, candidate);
    if (status == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket query returned null status"
      );
      engine_lock.put(1);
      return;
    end
    if (!status.ok()) begin
      record = null;
      engine_lock.put(1);
      return;
    end
    match_count = 0;
    foreach (candidate.items[i]) begin
      if (same_ticket_value(ticket_snapshot, candidate.items[i].ticket))
        match_count++;
    end
    if (match_count == 0) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal ticket key matched but full ticket value differs"
      );
      engine_lock.put(1);
      return;
    end
    if (match_count != 1) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket resolves to more than one retained item"
      );
      engine_lock.put(1);
      return;
    end
    record = candidate;
    status = journal_status(RDMA_SC_OK);
    engine_lock.put(1);
  endtask

  // 功能：查询 submission fence 的 key/reason，不暴露 journal 句柄。
  // 输入/输出及副作用：active/batch_key/reason/status 为输出；持现有 engine_lock 读两个字符串，
  //  均空为 inactive，均非空为 active。
  // 失败/边界：仅一项非空说明 fence partial，返回 INVALID_STATE 并清空输出；查询不改状态。
  task query_submission_fence(
    output bit active,
    output string batch_key,
    output string reason,
    output rdma_status status
  );
    active = 1'b0;
    batch_key = "";
    reason = "";
    status = journal_status(
      RDMA_SC_INVALID_STATE, "CMQ submission fence query did not complete"
    );
    engine_lock.get(1);
    if ((fenced_batch_key.len() == 0) !=
        (submission_fence_reason.len() == 0)) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ submission fence key/reason state is partial"
      );
      engine_lock.put(1);
      return;
    end
    if (fenced_batch_key.len() != 0) begin
      active = 1'b1;
      batch_key = fenced_batch_key;
      reason = submission_fence_reason;
    end
    status = journal_status(RDMA_SC_OK);
    engine_lock.put(1);
  endtask

  // 功能：清空 active runtime 的配置、facade、格式 authority 与 ring 账本，使后续 prepare 建新 incarnation。
  // 输入/输出及副作用：清空协作者引用、ring counter、FIFO、registry、slot/token；保留单调 ID、四表、
  //  profile 行与 fence。
  // 失败/边界：不调用 adapter release，调用方须先处理 backing 所有权；重复清理幂等。
  protected function void clear_configuration();
    prepared_binding = null;
    dma_context = null;
    cmq_snapshot = null;
    backing_mapping = null;
    host_mem = null;
    scheduler = null;
    transport = null;
    profile = null;
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    command_registry.delete();
    entry_registry.delete();
    terminal_fifo.delete();
    diagnostic_fifo.delete();
    late_final_fifo.delete();
    last_poison = null;
    backing_release_opaque = 1'b0;
    reset_release_in_progress = 1'b0;
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
    end
  endfunction

  // 功能：opaque backing 已释放但 reset candidate 的 runtime CAS 失败时，清空可能指向已释放
  //  allocation 的本地引用，并让 engine 停在仅可诊断的 POISONED。
  // 输入/输出及副作用：无参数；调用 clear_configuration 后置 POISONED 并清 gate；不分配、不调用
  //  adapter/scheduler、不碰 retained journal。
  // 失败/边界：仅在 release 已成功且 gate 由当前 reset 持有时调用；不二次 release 也不造 reset proof。
  protected function void poison_released_runtime_drift_locked();
    clear_configuration();
    engine_state = RDMA_CMQ_ENGINE_POISONED;
    reset_release_in_progress = 1'b0;
  endfunction

  // 功能：释放失败后清理 runtime，保留原释放 authority、last_poison 与 terminal FIFO，
  //  engine 停在 POISONED 供重试或诊断。
  // 输入/输出及副作用：retained_mapping/host_mem 为原引用，use_opaque 指定下次释放方式；不调用 adapter。
  // 失败/边界：不验证代际；mapping 为 null 时不保留 adapter，mapping 非空而 adapter 为 null 只保留
  //  mapping；调用方负责持锁与释放策略。
  protected function void retain_release_authority(
    rdma_dma_mapping retained_mapping,
    rdma_host_mem_api retained_host_mem,
    bit use_opaque = 1'b0
  );
    rdma_cmq_diagnostic retained_last_poison;
    rdma_cmq_completion retained_terminal_fifo[$];

    retained_last_poison = last_poison;
    // // 先保留 caller 尚未消费的 terminal FIFO 再清其余账本；本 helper 不决定交付策略（shutdown
    // // 已明确丢弃，rollback 保留，observed reset 不走此路径）。
    foreach (terminal_fifo[i])
      retained_terminal_fifo.push_back(terminal_fifo[i]);
    clear_configuration();
    last_poison = retained_last_poison;
    foreach (retained_terminal_fifo[i])
      terminal_fifo.push_back(retained_terminal_fifo[i]);
    if (retained_mapping != null) begin
      backing_mapping = retained_mapping;
      host_mem = retained_host_mem;
      backing_release_opaque = use_opaque;
    end
    engine_state = RDMA_CMQ_ENGINE_POISONED;
  endfunction

  // 功能：回滚 prepare 候选：释放候选 mapping，并在失败时保留恢复 authority。
  // 输入/输出及副作用：candidate_host_mem/candidate_mapping/original_failure/mapping_validated 为输入；返回回滚结果。
  // 失败/边界：mapping_validated 为 0 时只能用 opaque allocation identity，验证过 public authority 才用严格 release；
  //   释放失败保留同模式恢复 authority。
  protected function rdma_status rollback_candidate(
    rdma_host_mem_api candidate_host_mem,
    rdma_dma_mapping candidate_mapping,
    rdma_status original_failure,
    bit mapping_validated = 1'b0
  );
    rdma_status release_status;
    rdma_status cleanup_failure;
    string original_message;

    if (original_failure == null)
      original_failure = invalid_state("CMQ prepare failed with null status");
    if (candidate_mapping == null)
      return original_failure;
    if (mapping_validated)
      release_status = candidate_host_mem.\release (candidate_mapping);
    else
      release_status = candidate_host_mem.release_opaque(candidate_mapping);
    if (release_status != null && release_status.ok()) begin
      clear_configuration();
      engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
      return original_failure;
    end
    original_message = original_failure.message;
    retain_release_authority(candidate_mapping, candidate_host_mem,
                             !mapping_validated);
    if (release_status == null)
      cleanup_failure = invalid_state(
        {"CMQ prepare rollback release returned null; original failure: ",
         original_message}
      );
    else
      cleanup_failure = rdma_status::make(
        release_status.code,
        {"CMQ prepare rollback release failed: ", release_status.message,
         "; original failure: ", original_message}
      );
    return cleanup_failure;
  endfunction

  // 功能：验证 PREPARED binding/CMQ/profile，配置新 transport，申请并清零 backing，最后原子提交
  //  runtime 与协作者引用。
  // 输入/输出及副作用：各参数均为非拥有输入；成功执行一次 allocate/zero-write，发布 runtime_desc，
  //  engine_incarnation 恰好加一；失败不推进。
  // 失败/边界：重复 prepare、incarnation 溢出、空依赖、authority/profile/facade 失败在外部 I/O 前拒绝；
  //  allocate 后失败走 rollback，候选 transport 不安装。
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
    rdma_function_binding binding_candidate;
    rdma_cmq cmq_candidate;
    rdma_dma_request_context context_candidate;
    rdma_dma_mapping mapping_candidate;
    rdma_cmq_runtime_desc runtime_candidate;
    rdma_cmq_runtime_desc published_runtime;
    rdma_cmq_transport transport_candidate;
    byte zeros[];

    runtime_desc = null;
    status = invalid_state("CMQ prepare did not complete");
    engine_lock.get(1);
    status = reset_release_gate_status();
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (engine_state != RDMA_CMQ_ENGINE_UNCONFIGURED) begin
      status = invalid_state("CMQ engine is already configured");
      engine_lock.put(1);
      return;
    end
    if (engine_incarnation == 64'hffff_ffff_ffff_ffff) begin
      status = journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "CMQ engine incarnation IDs are exhausted"
      );
      engine_lock.put(1);
      return;
    end

    status = clone_binding_snapshot(binding, binding_candidate);
    if (status.ok())
      status = prepared_binding_status(binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = clone_cmq_snapshot(cmq, cmq_candidate);
    if (status.ok())
      status = cmq_resource_status(cmq_candidate, binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (host_mem == null) begin
      status = invalid_argument("CMQ host memory adapter is null");
      engine_lock.put(1);
      return;
    end
    if (scheduler == null) begin
      status = invalid_argument("CMQ doorbell scheduler is null");
      engine_lock.put(1);
      return;
    end
    if (profile == null) begin
      status = invalid_argument("CMQ hardware profile is null");
      engine_lock.put(1);
      return;
    end
    status = profile.validate_profile();
    if (status == null)
      status = invalid_state("CMQ hardware profile returned null status");
    if (status.ok())
      status = make_request_context(binding_candidate, cmq_candidate,
                                    pasid_valid, pasid, context_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end

    // // facade 在任何 Host-memory I/O 前一次性配置；仅 prepare 最终 commit 才装入 engine，
    // // 早退与 rollback 不会留下旧引用。
    transport_candidate = rdma_cmq_transport::type_id::create(
      "cmq_transport_candidate"
    );
    if (transport_candidate == null) begin
      status = invalid_state("CMQ transport construction failed");
      engine_lock.put(1);
      return;
    end
    status = transport_candidate.configure(scheduler);
    if (status == null)
      status = invalid_state("CMQ transport configure returned null status");
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end

    mapping_candidate = null;
    status = host_mem.allocate(context_candidate, BACKING_BYTES,
                               BACKING_BYTES, RDMA_DMA_BIDIRECTIONAL,
                               mapping_candidate);
    if (status == null)
      status = invalid_state("CMQ host allocation returned null status");
    if (!status.ok()) begin
      if (mapping_candidate != null)
        status = rollback_candidate(host_mem, mapping_candidate, status);
      engine_lock.put(1);
      return;
    end
    status = mapping_authority_status(mapping_candidate,
                                      context_candidate);
    if (!status.ok()) begin
      status = rollback_candidate(host_mem, mapping_candidate, status);
      engine_lock.put(1);
      return;
    end

    zeros = new[BACKING_BYTES];
    foreach (zeros[i])
      zeros[i] = 0;
    status = host_mem.write(mapping_candidate, 0, zeros);
    if (status == null)
      status = invalid_state("CMQ backing zero-write returned null status");
    if (!status.ok()) begin
      status = rollback_candidate(host_mem, mapping_candidate, status,
                                  1'b1);
      engine_lock.put(1);
      return;
    end
    status = build_runtime_desc(context_candidate, cmq_candidate,
                                mapping_candidate, runtime_candidate);
    if (status == null)
      status = invalid_state("CMQ runtime construction returned null status");
    if (!status.ok()) begin
      status = rollback_candidate(host_mem, mapping_candidate, status,
                                  1'b1);
      engine_lock.put(1);
      return;
    end
    status = publish_runtime_snapshot(runtime_candidate,
                                      published_runtime);
    if (status == null)
      status = invalid_state("CMQ runtime publication returned null status");
    if (!status.ok() || published_runtime == null) begin
      if (status.ok())
        status = invalid_state("CMQ runtime publication returned null");
      status = rollback_candidate(host_mem, mapping_candidate, status,
                                  1'b1);
      engine_lock.put(1);
      return;
    end

    cmq_candidate.queue_iova = runtime_candidate.sq_iova;
    cmq_candidate.completion_iova = runtime_candidate.cq_iova;
    prepared_binding = binding_candidate;
    dma_context = context_candidate;
    cmq_snapshot = cmq_candidate;
    backing_mapping = mapping_candidate;
    this.host_mem = host_mem;
    this.scheduler = scheduler;
    this.transport = transport_candidate;
    this.profile = profile;
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    command_registry.delete();
    entry_registry.delete();
    terminal_fifo.delete();
    diagnostic_fifo.delete();
    late_final_fifo.delete();
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
    end
    engine_incarnation++;
    engine_state = RDMA_CMQ_ENGINE_PREPARED;
    runtime_desc = published_runtime;
    status = rdma_status::success();
    engine_lock.put(1);
  endtask

  // 功能：新 incarnation ACTIVE 后，把同一 Function 且 reset epoch 严格递增的 AWAITING_REBIND proof
  //  绑定到 replacement identity 并提升为 READY。
  // 输入/输出及副作用：replacement_identity 为已校验的 ACTIVE detached identity；只改匹配 journal row 的
  //  proof state/replacement 字段，不碰 backing、fence、attempt、scheduler。
  // 失败/边界：不同 Function、epoch 相同/回退、PREPARED-only 或 tuple/digest 损坏的 proof 保持
  //  AWAITING_REBIND；不创建第二份 proof，也不因单行不匹配阻断 ACTIVE。
  protected function void promote_reset_proofs_ready_locked(
    input rdma_function_identity replacement_identity
  );
    rdma_function_identity replacement_snapshot;
    rdma_status status;

    if (replacement_identity == null ||
        !rdma_cmq_identity_shape_valid(replacement_identity))
      return;
    if (!rdma_cmq_try_snapshot_identity_direct(
          replacement_identity, replacement_snapshot
        ) || replacement_snapshot == null)
      return;

    foreach (submission_journal[batch_key]) begin
      rdma_cmq_batch_submission_record row;
      rdma_cmq_reset_isolation_proof proof;
      rdma_cmq_journal_digest_t computed_digest;

      row = submission_journal[batch_key];
      if (row == null || row.reset_isolation_proof == null)
        continue;
      proof = row.reset_isolation_proof;
      if (proof.state != RDMA_CMQ_RESET_PROOF_AWAITING_REBIND ||
          !proof.backing_release_confirmed ||
          proof.engine_instance_id != engine_instance_id ||
          proof.engine_incarnation >= engine_incarnation ||
          proof.isolated_identity == null ||
          !replacement_snapshot.same_function(proof.isolated_identity) ||
          replacement_snapshot.reset_epoch <= proof.isolated_identity.reset_epoch)
        continue;
      status = rdma_cmq_compute_reset_proof_digest(
        proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
        proof.attempt_id, proof.engine_instance_id,
        proof.engine_incarnation, proof.isolated_identity,
        proof.batch_digest, proof.isolated_request_indices,
        proof.isolated_image_digests, proof.isolated_authority_digests,
        proof.isolated_recovery_owners, computed_digest
      );
      if (status == null || !status.ok() || computed_digest !== proof.proof_digest)
        continue;
      proof.replacement_identity = replacement_snapshot;
      proof.state = RDMA_CMQ_RESET_PROOF_READY;
    end
  endfunction

  // 功能：校验 ACTIVE binding 与 PREPARED binding 的 Function、generation、BDF、PASID、DMA domain 一致，
  //  复核 backing mapping 后切换为 ACTIVE 并提升 reset proof。
  // 输入/输出及副作用：active_binding 为输入，status 输出；持锁，克隆 binding 并更新 prepared_binding、
  //  engine_state。
  // 失败/边界：gate 阻断、非 PREPARED、binding 无效、身份不符或 mapping authority 失败时返回错误，
  //  保留原配置。
  task activate(
    rdma_function_binding active_binding,
    output rdma_status status
  );
    rdma_function_binding binding_candidate;

    status = invalid_state("CMQ activate did not complete");
    engine_lock.get(1);
    status = reset_release_gate_status();
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (engine_state != RDMA_CMQ_ENGINE_PREPARED) begin
      status = invalid_state("CMQ engine is not PREPARED");
      engine_lock.put(1);
      return;
    end
    status = clone_binding_snapshot(active_binding, binding_candidate);
    if (status.ok())
      status = active_binding_status(binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (prepared_binding == null) begin
      status = invalid_state("CMQ prepared binding authority is missing");
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.function_uid != prepared_binding.function_uid ||
        binding_candidate.global_function_id !=
          prepared_binding.global_function_id) begin
      status = invalid_argument(
        "CMQ ACTIVE binding Function identity does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.generation != prepared_binding.generation) begin
      status = rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ ACTIVE binding generation does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (!rdma_cmq_same_bdf_value(binding_candidate.pcie.bdf,
                  prepared_binding.pcie.bdf)) begin
      status = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ ACTIVE binding BDF does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.queue_dma.pasid_valid !=
          prepared_binding.queue_dma.pasid_valid ||
        binding_candidate.queue_dma.pasid !=
          prepared_binding.queue_dma.pasid) begin
      status = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ ACTIVE binding PASID does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.queue_dma.dma_domain_valid !=
          prepared_binding.queue_dma.dma_domain_valid ||
        binding_candidate.queue_dma.dma_domain_id !=
          prepared_binding.queue_dma.dma_domain_id) begin
      status = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ ACTIVE binding DMA domain does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    status = mapping_authority_status(backing_mapping, dma_context);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    prepared_binding = binding_candidate;
    engine_state = RDMA_CMQ_ENGINE_ACTIVE;
    promote_reset_proofs_ready_locked(
      prepared_binding.function_identity_snapshot()
    );
    status = rdma_status::success();
    engine_lock.put(1);
  endtask

  // 功能：直接复制 submit 路径返回或写入 journal 的 status 标量，避免 transport 副作用后再依赖
  //  UVM factory/clone。
  // 输入/输出及副作用：source/name 只读；返回新 status，不改 source、不读共享 last_* 证据。
  // 失败/边界：source 为 null、subtype 或枚举 shape 非法时返回独立 INVALID_STATE；始终非空。
  protected function rdma_status copy_submit_status_direct(
    input rdma_status source,
    input string name
  );
    rdma_status snapshot;

    if (!rdma_cmq_status_shape_valid(source))
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed submit status is null or malformed"
      );

    snapshot = new(name);
    snapshot.category = source.category;
    snapshot.code = source.code;
    snapshot.hardware_code = source.hardware_code;
    snapshot.hardware_code_valid = source.hardware_code_valid;
    snapshot.source_engine = source.source_engine;
    snapshot.function_uid = source.function_uid;
    snapshot.generation = source.generation;
    snapshot.resource_id = source.resource_id;
    snapshot.command_id = source.command_id;
    snapshot.wr_id = source.wr_id;
    snapshot.severity = source.severity;
    snapshot.retryable = source.retryable;
    snapshot.message = source.message;
    return snapshot;
  endfunction

  // 设计说明：observed submit 与 recovery submit 都先把 transport envelope 降级为四项 detached
  //  evidence；context 只选诊断文案与 status 名，不把 arm、effect fold、分类或 journal 修改拉进 decoder。
  // 功能：从 transport 返回值提取独立的 operation status、observation 状态/文本和原始 effect，
  //  供两条 submit 路径复用同一套 shape 校验与降级规则。
  // 输入/输出及副作用：transport_result 非拥有只读；recovery_context 选诊断上下文；四个 output 入口
  //  先清空；不改 envelope、observer、锁、journal 或 transport。
  // 失败/边界：null envelope、非法 status 或 X/Z/spare effect 均返回非空保守证据；observed 在 status/effect
  //  同时非法时保留 combined 文案，recovery 保留其历史 effect 文案；非法 effect 降级为 UNOBSERVED。
  protected function void decode_transport_envelope(
    input rdma_doorbell_submission_result transport_result,
    input bit recovery_context,
    output rdma_status operation_status,
    output rdma_status_code_e observation_code,
    output string observation_message,
    output rdma_submission_effect_e raw_effect
  );
    bit status_valid;

    operation_status = null;
    observation_code = RDMA_SC_OK;
    observation_message = "";
    raw_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    if (transport_result == null) begin
      if (recovery_context) begin
        operation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery transport returned a null envelope"
        );
        observation_message = "CMQ recovery transport envelope is missing";
      end
      else begin
        operation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ observed transport returned a null envelope"
        );
        observation_message = "CMQ observed transport envelope is missing";
      end
      observation_code = RDMA_SC_INVALID_STATE;
      return;
    end

    status_valid = rdma_cmq_status_shape_valid(transport_result.status);
    if (status_valid) begin
      operation_status = copy_submit_status_direct(
        transport_result.status,
        recovery_context ? "cmq_recovery_operation_status" :
                           "cmq_transport_operation_status"
      );
    end
    else begin
      operation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        recovery_context ?
          "CMQ recovery transport operation status is malformed" :
          "CMQ observed transport returned a malformed operation status"
      );
      observation_code = RDMA_SC_INVALID_STATE;
      if (recovery_context)
        observation_message =
          "CMQ recovery transport operation status is malformed";
      else
        observation_message =
          "CMQ observed transport operation status is malformed";
    end

    if (rdma_cmq_submission_effect_valid(
          transport_result.submission_effect
        )) begin
      raw_effect = transport_result.submission_effect;
    end
    else begin
      raw_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      observation_code = RDMA_SC_INVALID_STATE;
      if (recovery_context)
        observation_message = "CMQ recovery transport effect is malformed";
      else if (status_valid)
        observation_message = "CMQ observed transport effect is malformed";
      else
        observation_message =
          "CMQ observed transport status and effect are malformed";
    end
  endfunction

  // 设计说明：operation status 与 attempted effect 是独立证据；malformed 字段只降级自身，
  //  不得擦除另一字段的有效 PRE/MMIO 事实。
  // 功能：把 observed envelope 解码为 submit 的 operation status、原始 effect 与初始 observation，
  //  并判定未 arm 的确证 PRE rollback。
  // 输入/输出及副作用：transport_result 只读；observer_armed 只来自 retained journal 的真实回调；
  //  decision 为调用方局部输出，仅分配 status。
  // 失败/边界：null envelope 或非法 status/effect 保留原精确诊断；X/Z 或 spare effect 降级为
  //  UNOBSERVED；仅未 arm 且有效 PRE effect 才置 rollback_pre；不改 engine 账本。
  protected function void decode_observed_transport_evidence(
    input rdma_doorbell_submission_result transport_result,
    input bit observer_armed,
    output rdma_cmq_submit_transport_decision_t decision
  );
    decision.operation_status = null;
    decision.observation_code = RDMA_SC_OK;
    decision.observation_message = "";
    decision.raw_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    decision.rollback_pre = 1'b0;
    decision.state = RDMA_CMQ_SUBMISSION_STAGED;
    decision.cumulative_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    decision.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    decision.publication_retry_safe = 1'b0;

    decode_transport_envelope(
      transport_result, 1'b0, decision.operation_status,
      decision.observation_code, decision.observation_message,
      decision.raw_effect
    );

    decision.rollback_pre = !observer_armed &&
      decision.raw_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
  endfunction

  // 设计说明：PRE rollback 在调用前已完成；owner replayability 由原 task 在锁内只读扫描，classifier
  //  不接管 journal 写权限，只计算 arm、原始 effect 与 retry-safe 的最终组合。
  // 功能：把非 PRE 的 transport 证据分类为 retained batch state、累计/本次 effect、重试标记与
  //  最终 observation，保持 operation status 原句柄。
  // 输入/输出及副作用：observer_armed/retry_safe 为锁内冻结输入，evidence 为解码值；decision 为新输出，
  //  不改输入或 engine 状态。
  // 失败/边界：真实 arm 后非 MMIO effect 强制 MAYBE_VISIBLE，raw UNOBSERVED 的 attempt 仍为
  //  UNOBSERVED；未 arm 却自报 MMIO 禁止重试；其他未 arm UNOBSERVED 保留 retry_safe 候选；
  //  PRE 须先由 submit task 回滚。
  protected function void classify_observed_transport_effect(
    input bit observer_armed,
    input bit retry_safe,
    input rdma_cmq_submit_transport_decision_t evidence,
    output rdma_cmq_submit_transport_decision_t decision
  );
    decision = evidence;
    if (observer_armed) begin
      decision.publication_retry_safe = 1'b0;
      if (evidence.raw_effect == RDMA_SUBMIT_EFFECT_MMIO_VISIBLE) begin
        decision.state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
        decision.cumulative_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
        decision.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
      end
      else if (evidence.raw_effect ==
               RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE) begin
        decision.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
        decision.cumulative_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
        decision.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
      end
      else begin
        decision.observation_code = RDMA_SC_INVALID_STATE;
        decision.observation_message =
          "CMQ transport effect contradicts an authentic MMIO arm";
        decision.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
        decision.cumulative_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
        decision.attempt_effect =
          (evidence.raw_effect == RDMA_SUBMIT_EFFECT_UNOBSERVED) ?
            RDMA_SUBMIT_EFFECT_UNOBSERVED :
            RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
      end
    end
    else begin
      decision.state = RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
      decision.publication_retry_safe = retry_safe;
      if (evidence.raw_effect inside {
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
          }) begin
        decision.cumulative_effect = evidence.raw_effect;
        decision.attempt_effect = evidence.raw_effect;
      end
      else begin
        decision.cumulative_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        decision.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        decision.observation_code = RDMA_SC_INVALID_STATE;
        if (evidence.raw_effect inside {
              RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
              RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
            }) begin
          decision.publication_retry_safe = 1'b0;
          decision.observation_message =
            "CMQ transport reported MMIO effect without authentic arm";
        end
        else begin
          decision.observation_message =
            "CMQ transport effect could not be observed after delegation";
        end
      end
    end
  endfunction

  // 功能：为 input-aligned submit item 建立本地拒绝默认结果，operation 与 observation status 互相独立且非空。
  // 输入/输出及副作用：name 仅为新对象名；返回调用方拥有的 result。
  // 失败/边界：默认为未发布的 PRE_SUBMIT_REJECTED，ticket/IDs 为空、recovery_required=0；
  //  后续 admission 须显式覆盖 operation evidence。
  protected function rdma_cmq_execution_result new_submit_result_direct(
    input string name
  );
    rdma_cmq_execution_result result;

    result = new(name);
    result.status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ submit item was not admitted"
    );
    result.observation_status = rdma_cmq_direct_status(RDMA_SC_OK);
    result.submission_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.attempt_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.completion_phase = RDMA_CMQ_COMPLETION_NONE;
    result.recovery_required = 1'b0;
    return result;
  endfunction

  // 功能：从 retained journal item 构造完整 detached observed result，operation outcome 与
  //  observation health 分开发布。
  // 输入/输出及副作用：record/item/observation_code/message 为输入；result 入口清空，成功经 nonfatal
  //  snapshot seam 发布独立 ticket/owner/DMA/status。
  // 失败/边界：record/item/command identity 不完整或嵌套 snapshot 被拒时返回错误与 null；不改 journal。
  protected function rdma_status build_observed_result_locked(
    input rdma_cmq_batch_submission_record record,
    input rdma_cmq_batch_submission_item_record item,
    input rdma_status_code_e observation_code,
    input string observation_message,
    output rdma_cmq_execution_result result
  );
    rdma_cmq_execution_result source;
    rdma_cmq_command_identity command_identity;
    string failure_reason;

    result = null;
    if (record == null || item == null || item.command == null ||
        item.status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed result source journal item is incomplete"
      );

    command_identity = new("cmq_observed_command_identity");
    if (!command_identity.capture_from(item.command, failure_reason))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        {"CMQ observed command identity capture failed: ", failure_reason}
      );

    source = new("cmq_observed_result_source");
    source.ticket = item.ticket;
    source.completion = item.completion;
    source.status = item.status;
    source.observation_status = rdma_cmq_direct_status(
      observation_code, observation_message
    );
    source.command_identity = command_identity;
    source.recovery_owner = item.recovery_owner;
    source.dma_context = item.dma_context;
    source.submission_effect = item.submission_effect;
    source.attempt_effect = item.attempt_effect;
    source.completion_phase = item.completion_phase;
    source.batch_key = record.batch_key;
    source.batch_id = record.batch_id;
    source.attempt_id = record.attempt_id;
    source.recovery_required = item.recovery_required;
    return snapshot_execution_result_locked(source, result);
  endfunction

  // 功能：为 recovery aligned result 直接复制 ticket 的身份、slot、opcode、absolute deadline，
  //  允许把含 X 的 deadline 原样带回拒绝结果。
  // 输入/输出及副作用：name/source 只读；成功返回嵌套 handle/key 独立的 ticket；不改 request/journal。
  // 失败/边界：source/必需嵌套值缺失或 snapshot/cast 失败返回 null；不把非法 deadline 当作授权。
  protected function rdma_cmq_ticket make_recovery_ticket_locked(
    input string name,
    input rdma_cmq_ticket source
  );
    rdma_cmq_ticket candidate;
    rdma_handle function_snapshot_base;
    rdma_handle cmq_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;

    if (source == null || source.function_h == null ||
        source.cmq_h == null || source.opcode_key == null ||
        !rdma_cmq_try_snapshot_handle_direct(
          source.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_handle_direct(
          source.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_opcode_key_direct(
          source.opcode_key, opcode_snapshot
        ))
      return null;
    candidate = new(name);
    if (!$cast(candidate.function_h, function_snapshot_base))
      return null;
    candidate.command_id = source.command_id;
    candidate.cmq_h = cmq_snapshot;
    candidate.slot_sequence = source.slot_sequence;
    candidate.sq_index = source.sq_index;
    candidate.sq_wrap = source.sq_wrap;
    candidate.opcode_key = opcode_snapshot;
    candidate.absolute_deadline = source.absolute_deadline;
    return candidate;
  endfunction

  // 功能：在任何 stale/action/authority 返回前，为已对齐请求构造等长同序 execution results；
  //  request ticket 失败时改从 retained ticket 创建 detached fallback。
  // 输入/输出及副作用：request/record 只读；results 入口按 request 大小重建；只分配本地候选。
  // 失败/边界：maker/snapshot/capture 失败仍用 direct-new 保留非空 aligned 外壳并返回首个失败 status；
  //  绝不把 retained ticket 引用返回 caller。
  protected function rdma_status stage_recovery_results_locked(
    input rdma_cmq_submission_recovery_request request,
    input rdma_cmq_batch_submission_record record,
    output rdma_cmq_execution_result results[]
  );
    rdma_status first_failure;

    results = new[request.items.size()];
    first_failure = null;
    foreach (results[i]) begin
      rdma_cmq_execution_result result;
      rdma_cmq_ticket ticket_snapshot;
      rdma_cmq_recovery_owner owner_snapshot;
      rdma_dma_request_context dma_snapshot;
      rdma_cmq_command_identity command_identity;
      rdma_status nested_status;
      string failure_reason;

      result = make_recovery_result_locked(
        $sformatf("cmq_recovery_result_%0d", i)
      );
      if (result == null) begin
        result = new($sformatf("cmq_recovery_emergency_result_%0d", i));
        if (first_failure == null)
          first_failure = journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ recovery result candidate construction failed"
          );
      end
      ticket_snapshot = make_recovery_ticket_locked(
        $sformatf("cmq_recovery_ticket_%0d", i), request.items[i].ticket
      );
      if (ticket_snapshot == null) begin
        if (first_failure == null)
          first_failure = journal_status(
            RDMA_SC_INVALID_ARGUMENT,
            "CMQ recovery aligned ticket snapshot failed"
          );
        ticket_snapshot = make_recovery_ticket_locked(
          $sformatf("cmq_recovery_retained_ticket_%0d", i),
          record.items[i].ticket
        );
      end
      if (ticket_snapshot == null) begin
        ticket_snapshot = new($sformatf(
          "cmq_recovery_emergency_ticket_%0d", i
        ));
        ticket_snapshot.command_id = request.items[i].ticket.command_id;
        ticket_snapshot.slot_sequence =
          request.items[i].ticket.slot_sequence;
        ticket_snapshot.sq_index = request.items[i].ticket.sq_index;
        ticket_snapshot.sq_wrap = request.items[i].ticket.sq_wrap;
        ticket_snapshot.absolute_deadline =
          request.items[i].ticket.absolute_deadline;
      end
      owner_snapshot = make_recovery_owner_locked(
        $sformatf("cmq_recovery_owner_%0d", i),
        request.items[i].recovery_owner
      );
      if (owner_snapshot == null && first_failure == null)
        first_failure = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery owner candidate construction failed"
        );
      dma_snapshot = null;
      nested_status = snapshot_journal_dma_context_locked(
        request.items[i].dma_context, dma_snapshot
      );
      if ((nested_status == null || !nested_status.ok() ||
           dma_snapshot == null) && first_failure == null)
        first_failure = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery DMA snapshot returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
      command_identity = new($sformatf(
        "cmq_recovery_command_identity_%0d", i
      ));
      if (!command_identity.capture_from(
            request.items[i].command, failure_reason
          )) begin
        command_identity = null;
        if (first_failure == null)
          first_failure = journal_status(
            RDMA_SC_INVALID_ARGUMENT,
            {"CMQ recovery command identity capture failed: ",
             failure_reason}
          );
      end

      result.ticket = ticket_snapshot;
      result.completion = null;
      result.status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ recovery attempt did not commit"
      );
      result.observation_status = rdma_cmq_direct_status(RDMA_SC_OK);
      result.command_identity = command_identity;
      result.recovery_owner = owner_snapshot;
      result.dma_context = dma_snapshot;
      result.submission_effect = record.items[i].submission_effect;
      result.attempt_effect = record.items[i].attempt_effect;
      result.completion_phase = record.items[i].completion_phase;
      result.batch_key = record.batch_key;
      result.batch_id = record.batch_id;
      result.attempt_id = record.attempt_id;
      result.recovery_required = 1'b1;
      results[i] = result;
    end
    return (first_failure == null) ? journal_status(RDMA_SC_OK) :
                                     first_failure;
  endfunction

  // 功能：把一次 aligned recovery 拒绝同步投影到每个预建 result，保留 observation OK、当前 attempt
  //  identity 与 retained cumulative evidence。
  // 输入/输出及副作用：results 的外层值被就地更新；code/message 只读；不改 ticket/owner/DMA、journal、
  //  fence、counter、registry。
  // 失败/边界：null result 被忽略；仅可在 staging 保证 aligned 后使用；未知 code 由 direct status 封装。
  protected function void reject_recovery_results_locked(
    input rdma_cmq_execution_result results[],
    input rdma_status_code_e code,
    input string message
  );
    foreach (results[i]) begin
      if (results[i] != null) begin
        results[i].status = rdma_cmq_direct_status(code, message);
        results[i].observation_status = rdma_cmq_direct_status(RDMA_SC_OK);
        results[i].recovery_required = 1'b1;
      end
    end
  endfunction

  // 功能：把 retained READY reset proof 重新绑定到当前 journal batch、engine/Function incarnation
  //  与完整 ordered item authority tuple。
  // 输入/输出及副作用：proof/record 为锁内只读输入；逐项比较 request index、digest 与 frozen owner；
  //  只返回 status。
  // 失败/边界：null、非 READY、backing 未释放、身份/tuple cardinality 或 item 值漂移返回
  //  INVALID_ARGUMENT；不 mint proof、不改 lifecycle、不做 I/O。
  protected function rdma_status
  validate_reset_isolation_proof_binding_locked(
    input rdma_cmq_reset_isolation_proof proof,
    input rdma_cmq_batch_submission_record record
  );
    int unsigned quarantined_count;
    int unsigned match_count;
    bit matched[int unsigned];
    rdma_cmq_journal_digest_t computed_digest;
    rdma_status status;

    if (proof == null || record == null || record.function_identity == null ||
        proof.state != RDMA_CMQ_RESET_PROOF_READY ||
        !proof.backing_release_confirmed ||
        proof.batch_key != record.batch_key ||
        proof.batch_id != record.batch_id ||
        proof.attempt_id != record.attempt_id ||
        proof.engine_instance_id != record.engine_instance_id ||
        proof.engine_incarnation != record.engine_incarnation ||
        proof.isolated_identity == null ||
        !proof.isolated_identity.same_incarnation(
          record.function_identity
        ) || proof.batch_digest !== record.batch_digest ||
        proof.isolated_request_indices.size() == 0 ||
        proof.isolated_request_indices.size() !=
          proof.isolated_image_digests.size() ||
        proof.isolated_request_indices.size() !=
          proof.isolated_authority_digests.size() ||
        proof.isolated_request_indices.size() !=
          proof.isolated_recovery_owners.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset isolation proof does not bind the retained batch"
      );

    quarantined_count = 0;
    foreach (record.items[i]) begin
      if (record.items[i] == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ reset proof retained item is null"
        );
      if (record.items[i].state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED)
        quarantined_count++;
    end
    if (proof.isolated_request_indices.size() != quarantined_count)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof tuple does not cover exactly quarantined items"
      );

    status = rdma_cmq_compute_reset_proof_digest(
      proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
      proof.attempt_id, proof.engine_instance_id, proof.engine_incarnation,
      proof.isolated_identity, proof.batch_digest,
      proof.isolated_request_indices, proof.isolated_image_digests,
      proof.isolated_authority_digests, proof.isolated_recovery_owners,
      computed_digest
    );
    if (status == null || !status.ok() || computed_digest !== proof.proof_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof digest does not match retained authority"
      );

    if (proof.replacement_identity == null ||
        !proof.replacement_identity.same_function(
          proof.isolated_identity
        ) || proof.replacement_identity.reset_epoch <=
          proof.isolated_identity.reset_epoch)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ reset proof replacement identity is not a newer same Function"
      );

    foreach (proof.isolated_request_indices[p]) begin
      match_count = 0;
      foreach (record.items[i]) begin
        if (record.items[i].request_index ==
              proof.isolated_request_indices[p]) begin
          match_count++;
          if (matched.exists(i))
            return journal_status(
              RDMA_SC_INVALID_ARGUMENT,
              "CMQ reset proof tuple repeats a journal item"
            );
          matched[i] = 1'b1;
          if (record.items[i].state !=
                RDMA_CMQ_SUBMISSION_RESET_QUARANTINED ||
              record.items[i].completion_phase !=
                RDMA_CMQ_COMPLETION_RESET_CANCELLED ||
              record.items[i].completion == null ||
              proof.isolated_image_digests[p] !==
                record.items[i].image_digest ||
              proof.isolated_authority_digests[p] !==
                record.items[i].authority_digest ||
              !rdma_cmq_same_journal_owner_value(
                proof.isolated_recovery_owners[p],
                record.items[i].recovery_owner
              ))
            return journal_status(
              RDMA_SC_INVALID_ARGUMENT,
              $sformatf(
                "CMQ reset isolation proof item %0d does not bind journal",
                p
              )
            );
        end
      end
      if (match_count != 1)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ reset proof request index is absent or ambiguous"
        );
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 设计说明：仅在 observed submit 已建默认结果并持 engine_lock 后调用；按原顺序先挡 reset release，
  //  再查 ACTIVE、authority、retained fence、Function handle 与 ring counter；不取放锁、不分配 ID；
  //  fence 是 batch OK、逐项 BUSY 的提前拒绝，不走事务失败回填。
  // 功能：对非空 observed batch 做锁内准入，拒绝时填好 batch_status 与逐项 status；成功时给出当前
  //  Function handle 与 ring 占用。
  // 输入/输出及副作用：results/batch_status 为 ref 输出；active_function、used 仅成功后有效；读 engine
  //  authority/fence，ring_used 异常会置 POISONED 并清 late_final_fifo。
  // 失败/边界：reset gate、非 ACTIVE、authority 缺失、fence、null Function、ring 失序/超深度各返回 0，
  //  保持原优先级；成功返回 1；调用者仅在返回 0 时解锁一次并退出。
  protected function automatic bit admit_observed_batch_locked(
    ref rdma_cmq_execution_result results[],
    ref rdma_status batch_status,
    output rdma_function_handle active_function,
    output longint unsigned used
  );
    rdma_status status;

    status = reset_release_gate_status();
    if (!status.ok()) begin
      batch_status = copy_submit_status_direct(
        status, "cmq_reset_release_gate_batch_status"
      );
      foreach (results[i])
        results[i].status = copy_submit_status_direct(
          status, $sformatf("cmq_reset_release_gate_item_%0d", i)
        );
      return 1'b0;
    end
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      batch_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ submit requires an ACTIVE engine"
      );
      foreach (results[i])
        results[i].status = copy_submit_status_direct(
          batch_status, $sformatf("cmq_inactive_item_%0d", i)
        );
      return 1'b0;
    end
    if (prepared_binding == null || dma_context == null ||
        cmq_snapshot == null || backing_mapping == null ||
        transport == null || profile == null) begin
      batch_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ ACTIVE publication authority is missing"
      );
      foreach (results[i])
        results[i].status = copy_submit_status_direct(
          batch_status, $sformatf("cmq_missing_authority_item_%0d", i)
        );
      return 1'b0;
    end
    if (fenced_batch_key.len() != 0) begin
      foreach (results[i])
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_RESOURCE_BUSY,
          "CMQ submission is fenced by a retained batch"
        );
      batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
      return 1'b0;
    end

    active_function = prepared_binding.make_handle();
    if (active_function == null) begin
      batch_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ ACTIVE Function handle is missing"
      );
      foreach (results[i])
        results[i].status = copy_submit_status_direct(
          batch_status, $sformatf("cmq_missing_function_item_%0d", i)
        );
      return 1'b0;
    end
    status = ring_used(used);
    if (status == null || !status.ok()) begin
      batch_status = copy_submit_status_direct(
        status, "cmq_ring_status"
      );
      foreach (results[i])
        results[i].status = copy_submit_status_direct(
          batch_status, $sformatf("cmq_ring_item_%0d", i)
        );
      return 1'b0;
    end
    return 1'b1;
  endfunction

  // 设计说明：由持 engine_lock 的 observed submit 按原请求索引逐项压缩候选。局部拒绝用 continue 保留
  //  精确结果，整批不变量故障用 break 留给原 task 回填；两处 poison_status 须在原序号/依赖溢出位置
  //  更新 engine_state 与 late_final_fifo，不是纯值计算。
  // 功能：暂存每项 command 的身份、slot、SQE、ticket、dependency 与未安装的 journal/preallocation
  //  条目，同时冻结本批 profile 格式，保持虚拟 compose hook。
  // 输入/输出及副作用：commands/active_function/used 为持锁输入；results、local_result_finalized 按输入
  //  索引更新；stage 借用候选句柄并累积 dependencies、profile 格式与失败状态；不装共享账本。
  // 失败/边界：snapshot 拒绝、无效命令、容量/token/地址与非 OK compose 仅逐项拒绝；staging invariant、
  //  后续 snapshot/shape、null compose、格式/依赖不变量或 poison 才终止全批；已定稿的局部结果不被
  //  回填覆盖；仅在原锁内、transport 前调用。
  protected function automatic void stage_observed_candidates_locked(
    input rdma_cmq_command_desc commands[],
    input rdma_function_handle active_function,
    input longint unsigned used,
    ref rdma_cmq_execution_result results[],
    ref bit local_result_finalized[],
    ref rdma_cmq_submit_candidate_stage_t stage
  );
    rdma_status status;

    foreach (commands[i]) begin : stage_observed_command
      rdma_cmq_command_desc command_snapshot;
      rdma_cmq_command_identity command_identity;
      rdma_cmq_slot_context slot_context;
      rdma_cmq_slot_context slot_context_snapshot;
      rdma_hw_image profile_sqe;
      rdma_hw_image sqe_snapshot;
      rdma_cmq_expected_response profile_expected;
      rdma_cmq_expected_response expected_snapshot;
      rdma_cmq_ticket authority_ticket;
      rdma_cmq_slot_record slot_candidate;
      rdma_cmq_slot_record slot_snapshot;
      rdma_doorbell_dependency dependency_candidate;
      rdma_doorbell_dependency dependency_snapshot;
      rdma_dma_mapping dependency_mapping;
      rdma_cmq_batch_submission_item_record item;
      rdma_cmq_preallocated_publish_item publish_item;
      bit [58:0] candidate_token_incarnation;
      time absolute_deadline;
      longint unsigned slot_sequence;
      rdma_cmq_ring_position_t slot_position;
      longint unsigned relative_offset;
      longint unsigned expected_backing_target;
      longint unsigned command_id;
      int unsigned sq_index;
      int unsigned selected_token;
      bit sq_wrap;
      bit token_found;
      bit snapshot_invariant_failed;
      string identity_failure;

      command_snapshot = null;
      command_identity = null;
      slot_context_snapshot = null;
      profile_sqe = null;
      sqe_snapshot = null;
      profile_expected = null;
      expected_snapshot = null;
      authority_ticket = null;
      slot_candidate = null;
      slot_snapshot = null;
      dependency_candidate = null;
      dependency_snapshot = null;
      dependency_mapping = null;
      token_found = 1'b0;
      selected_token = 0;
      snapshot_invariant_failed = 1'b0;

      status = snapshot_command_value(
        commands[i], command_snapshot, snapshot_invariant_failed
      );
      if (status == null)
        status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ command snapshot returned null status"
        );
      if (!status.ok()) begin
        if (snapshot_invariant_failed) begin
          stage.transaction_status = status;
          stage.transaction_failed = 1'b1;
          break;
        end
        results[i].status = copy_submit_status_direct(
          status, $sformatf("cmq_local_snapshot_reject_%0d", i)
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end

      command_identity = new($sformatf("cmq_command_identity_%0d", i));
      if (!command_identity.capture_from(
            command_snapshot, identity_failure
          )) begin
        stage.transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          {"CMQ command identity capture failed: ", identity_failure}
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      results[i].command_identity = command_identity;
      if (command_snapshot.function_h.kind != active_function.kind ||
          command_snapshot.function_h.function_uid !=
            active_function.function_uid ||
          command_snapshot.function_h.object_id !=
            active_function.object_id) begin
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ command Function identity does not match ACTIVE binding"
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end
      if (command_snapshot.function_h.generation !=
          active_function.generation) begin
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_STALE_GENERATION,
          "CMQ command Function generation does not match ACTIVE binding"
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end
      if (command_snapshot.opcode_key.profile_name !=
          profile.profile_name()) begin
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_UNSUPPORTED_OPCODE,
          "CMQ command opcode profile does not match ACTIVE profile"
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end
      if ($isunknown(command_snapshot.timeout)) begin
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ command timeout contains an unknown bit"
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end
      absolute_deadline = $time + command_snapshot.timeout;
      if ($isunknown(absolute_deadline) || absolute_deadline == 0 ||
          absolute_deadline < $time) begin
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ command absolute deadline overflows simulation time"
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end
      if ((used + stage.record_candidate.items.size()) == CMQ_DEPTH) begin
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_QUEUE_FULL, "CMQ submission ring is full"
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end
      if (publish_seq >= 64'hffff_ffff_ffff_ffff -
                         stage.record_candidate.items.size()) begin
        stage.transaction_status = poison_status(
          "CMQ producer sequence addition overflows"
        );
        stage.transaction_failed = 1'b1;
        break;
      end

      for (int unsigned token_index = 0;
           token_index < CMQ_DEPTH; token_index++) begin
        bit staged_token;

        staged_token = 1'b0;
        foreach (stage.record_candidate.items[prior]) begin
          if (stage.record_candidate.items[prior].command_token == token_index)
            staged_token = 1'b1;
        end
        if (!token_found && !token_in_use[token_index] &&
            !staged_token &&
            token_incarnation[token_index] != {59{1'b1}}) begin
          token_found = 1'b1;
          selected_token = token_index;
        end
      end
      if (!token_found) begin
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "CMQ command tokens are exhausted"
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end
      candidate_token_incarnation =
        token_incarnation[selected_token] + 1'b1;
      command_id = {candidate_token_incarnation,
                    selected_token[4:0]};
      if (command_id == 0) begin
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_RESOURCE_EXHAUSTED, "CMQ command ID is exhausted"
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end

      slot_sequence = publish_seq + stage.record_candidate.items.size();
      if (slot_sequence == 64'hffff_ffff_ffff_ffff) begin
        stage.transaction_status = poison_status(
          "CMQ dependency identifier addition overflows"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      if (!rdma_cmq_ring_position_for_sequence(
            slot_sequence, CMQ_DEPTH, slot_position
          )) begin
        stage.transaction_status = poison_status(
          "CMQ slot sequence cannot be mapped to ring geometry"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      sq_index = slot_position.index;
      sq_wrap = slot_position.wrap;
      relative_offset = longint'(sq_index) * CMQE_BYTES;
      if (backing_mapping.backing_addr.value >
          64'hffff_ffff_ffff_ffff - relative_offset) begin
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_DMA_TRANSLATION, "CMQ SQE backing address overflows"
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end
      expected_backing_target = backing_mapping.backing_addr.value +
                                relative_offset;

      slot_context = rdma_cmq_slot_context::type_id::create(
        $sformatf("cmq_slot_context_%0d", slot_sequence)
      );
      if (slot_context == null) begin
        stage.transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, "CMQ slot context construction failed"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      status = rdma_cmq_checked_function_snapshot(
        active_function, "CMQ submission slot", RDMA_SC_INVALID_STATE,
        slot_context.function_h
      );
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_slot_function_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      status = rdma_cmq_checked_handle_snapshot(
        cmq_snapshot.handle, "CMQ submission slot",
        RDMA_SC_INVALID_STATE, slot_context.cmq_h
      );
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_slot_handle_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      slot_context.backing_addr = backing_mapping.backing_addr;
      slot_context.relative_offset = relative_offset;
      slot_context.slot_sequence = slot_sequence;
      slot_context.sq_index = sq_index;
      slot_context.sq_wrap = sq_wrap;
      status = slot_context.validate();
      if (status == null || !status.ok()) begin
        stage.transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, "CMQ slot context validation failed"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      status = checked_slot_context_snapshot(
        slot_context, slot_context_snapshot
      );
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_slot_snapshot_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end

      status = profile.compose_sqe(
        command_snapshot, slot_context_snapshot,
        profile_sqe, profile_expected
      );
      if (status == null) begin
        stage.transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, "CMQ SQE composition returned null status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      if (!status.ok()) begin
        results[i].status = copy_submit_status_direct(
          status, $sformatf("cmq_local_compose_reject_%0d", i)
        );
        local_result_finalized[i] = 1'b1;
        continue;
      end
      status = sqe_metadata_status(profile_sqe, expected_backing_target);
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_sqe_metadata_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      status = rdma_cmq_checked_canonical_image_snapshot(
        profile_sqe, "CMQ SQE", RDMA_SC_INVALID_STATE, sqe_snapshot
      );
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_sqe_snapshot_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      status = sqe_metadata_status(sqe_snapshot, expected_backing_target);
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_sqe_snapshot_metadata_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      if (!stage.staged_profile_format_valid) begin
        stage.staged_profile_format_valid = 1'b1;
        stage.staged_profile_endian = sqe_snapshot.endian;
        stage.staged_profile_hardware_version = sqe_snapshot.hardware_version;
      end
      else if (sqe_snapshot.endian != stage.staged_profile_endian ||
               sqe_snapshot.hardware_version !=
                 stage.staged_profile_hardware_version) begin
        stage.transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ profile changed its profile-wide SQE/CQE image format"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      status = checked_expected_snapshot(
        profile_expected, "CMQ profile", RDMA_SC_INVALID_STATE,
        expected_snapshot
      );
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_expected_snapshot_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end

      status = make_ticket_value(
        $sformatf("cmq_authority_ticket_%0d", command_id), command_id,
        active_function, cmq_snapshot.handle, slot_sequence, sq_index,
        sq_wrap, command_snapshot.opcode_key, absolute_deadline,
        authority_ticket
      );
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_ticket_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end

      slot_candidate = rdma_cmq_slot_record::type_id::create(
        $sformatf("cmq_slot_record_%0d", slot_sequence)
      );
      if (slot_candidate == null) begin
        stage.transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, "CMQ slot record construction failed"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      slot_candidate.slot_sequence = slot_sequence;
      slot_candidate.sq_index = sq_index;
      slot_candidate.sq_wrap = sq_wrap;
      slot_candidate.state = CMQ_SLOT_PUBLISHED;
      slot_candidate.ticket = authority_ticket;
      slot_candidate.expected = expected_snapshot;
      slot_candidate.command_token = selected_token[4:0];
      status = checked_record_snapshot(slot_candidate, slot_snapshot);
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_slot_record_snapshot_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end

      dependency_candidate = rdma_doorbell_dependency::type_id::create(
        $sformatf("cmq_dependency_%0d", slot_sequence + 1'b1)
      );
      status = make_mapping_snapshot(
        backing_mapping, $sformatf(
          "cmq_dependency_mapping_%0d", slot_sequence
        ), dependency_mapping
      );
      if (dependency_candidate == null || status == null ||
          !status.ok() || dependency_mapping == null) begin
        stage.transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ scheduler dependency construction failed"
        );
        stage.transaction_failed = 1'b1;
        break;
      end
      dependency_candidate.dependency_id = slot_sequence + 1'b1;
      dependency_candidate.stage = RDMA_DB_DEP_QUEUE_CONTEXT;
      dependency_candidate.mapping = dependency_mapping;
      dependency_candidate.relative_offset = relative_offset;
      dependency_candidate.image = sqe_snapshot;
      dependency_candidate.ready = 1'b1;
      status = checked_dependency_snapshot(
        dependency_candidate, dependency_snapshot
      );
      if (status == null || !status.ok()) begin
        stage.transaction_status = copy_submit_status_direct(
          status, "cmq_dependency_snapshot_status"
        );
        stage.transaction_failed = 1'b1;
        break;
      end

      item = new($sformatf("cmq_submission_item_%0d", i));
      item.request_index = i;
      item.command = command_snapshot;
      item.ticket = authority_ticket;
      item.recovery_owner = null;
      item.dma_context = dma_context;
      item.sqe_image = sqe_snapshot;
      item.dependency_mapping = backing_mapping;
      item.dependency_offset = relative_offset;
      item.dependency_image = sqe_snapshot;
      item.slot_sequence = slot_sequence;
      item.slot_index = sq_index;
      item.slot_wrap = sq_wrap;
      item.command_token = selected_token[4:0];
      item.token_incarnation = engine_incarnation[58:0];
      item.entry_key = entry_key(sq_index, sq_wrap);
      item.state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
      item.submission_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      item.attempt_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      item.completion_phase = RDMA_CMQ_COMPLETION_NONE;
      item.reset_isolation_confirmed = 1'b0;
      item.recovery_required = 1'b1;
      item.completion = null;
      item.status = rdma_cmq_direct_status(RDMA_SC_OK);
      stage.record_candidate.items.push_back(item);

      publish_item = new($sformatf("cmq_publish_item_%0d", i));
      publish_item.request_index = i;
      publish_item.slot_record = slot_snapshot;
      publish_item.command_key = command_key(authority_ticket);
      publish_item.entry_key = item.entry_key;
      publish_item.command_token = selected_token[4:0];
      stage.preallocated_candidate.items.push_back(publish_item);
      stage.dependencies.push_back(dependency_snapshot);
    end
  endfunction

  // 设计说明：只处理已压缩的非空候选，在 engine_lock 内、ID 分配与 journal 安装之前运行。profile 的
  //  encoder 只拿 detached handle；即使同时返回 null/失败，也先查是否改写该 handle，再按 source metadata
  //  -> canonical snapshot -> snapshot metadata 顺序拒绝，不得合并为一次宽松校验。
  // 功能：依据 publish_seq 与 admitted_count 算最终 ring 位置，编码并冻结本批 CMQ doorbell image。
  // 输入/输出及副作用：admitted_count 为已 staging 的候选数；final_sequence/final_pi/final_polarity/
  //  doorbell_snapshot 为成功输出；transaction_status/failed 原位记录首个失败；可能分配局部对象，
  //  不装账本、不取放锁、不做 I/O。
  // 失败/边界：handle 快照、篡改、null/失败编码状态或任一 metadata 校验失败即跳过后续；失败输出不得
  //  用作发布 authority；仅在原锁内且 admitted_count 非零时调用。
  protected function automatic void stage_observed_doorbell_image_locked(
    input int unsigned admitted_count,
    output longint unsigned final_sequence,
    output int unsigned final_pi,
    output bit final_polarity,
    output rdma_hw_image doorbell_snapshot,
    ref rdma_status transaction_status,
    ref bit transaction_failed
  );
    rdma_handle doorbell_encode_target;
    rdma_hw_image doorbell_image;
    rdma_status status;

    if (!transaction_failed) begin
      final_sequence = publish_seq + admitted_count;
      begin
        rdma_cmq_ring_position_t final_position;

        if (!rdma_cmq_ring_position_for_sequence(
              final_sequence, CMQ_DEPTH, final_position
            )) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ final publication sequence cannot be mapped to ring geometry"
          );
          transaction_failed = 1'b1;
        end
        else begin
          final_pi = final_position.index;
          final_polarity = final_position.wrap;
        end
      end
    end
    if (!transaction_failed) begin
      status = rdma_cmq_checked_handle_snapshot(
        cmq_snapshot.handle, "CMQ doorbell encoder",
        RDMA_SC_INVALID_STATE, doorbell_encode_target
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_handle_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      doorbell_image = null;
      status = profile.encode_doorbell(
        doorbell_encode_target, final_pi, final_polarity, doorbell_image
      );
      if (!same_handle(doorbell_encode_target, cmq_snapshot.handle)) begin
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ doorbell encoder changed its detached handle input"
        );
        transaction_failed = 1'b1;
      end
      else if (status == null || !status.ok()) begin
        transaction_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ doorbell encoding returned null status"
        ) : copy_submit_status_direct(status, "cmq_doorbell_encode_status");
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = doorbell_metadata_status(doorbell_image);
      if (status == null || !status.ok()) begin
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          {"CMQ doorbell profile output is invalid: ",
           (status == null) ? "null status" : status.message}
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = rdma_cmq_checked_canonical_image_snapshot(
        doorbell_image, "CMQ doorbell", RDMA_SC_INVALID_STATE,
        doorbell_snapshot
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_snapshot_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = doorbell_metadata_status(doorbell_snapshot);
      if (status == null || !status.ok()) begin
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          {"CMQ doorbell snapshot metadata is invalid: ",
           (status == null) ? "null status" : status.message}
        );
        transaction_failed = 1'b1;
      end
    end
  endfunction

  // 设计说明：只借用锁内已冻结的 image、压缩后的 record 与依赖；先按 item 顺序读 $time，首个过期即终止，
  //  不得先构造 descriptor 或把 deadline 检查移到 image 编码前；全部存活才由 UVM factory 建 descriptor，
  //  按 Function -> target -> 完整值快照顺序拒绝；ID、journal、transport 仍由原 task 负责。
  // 功能：计算 observed batch 的最短剩余 deadline，并构造冻结发布前的 doorbell descriptor。
  // 输入/输出及副作用：record_candidate/active_function/doorbell_snapshot/dependencies 仅借用；
  //  doorbell_snapshot_desc 入口清空，成功输出 detached 描述符；失败状态原位保存；不改账本、不做 I/O。
  // 失败/边界：上游已失败只清输出；任一 ticket 的 absolute_deadline 不晚于 $time 返回 TIMEOUT 且不触发
  //  factory；否则依次拒绝 candidate、Function 快照、target 快照与 descriptor clone/值快照失败。
  protected function automatic void stage_observed_doorbell_descriptor_locked(
    input rdma_cmq_batch_submission_record record_candidate,
    input rdma_function_handle active_function,
    input rdma_hw_image doorbell_snapshot,
    input rdma_doorbell_dependency dependencies[$],
    output rdma_doorbell_desc doorbell_snapshot_desc,
    ref rdma_status transaction_status,
    ref bit transaction_failed
  );
    rdma_doorbell_desc doorbell_candidate;
    rdma_status status;
    time minimum_remaining;
    time remaining;

    minimum_remaining = 0;
    if (!transaction_failed) begin
      foreach (record_candidate.items[i]) begin
        if ($time >= record_candidate.items[i].ticket.absolute_deadline) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_TIMEOUT,
            "CMQ batch deadline expired before publication"
          );
          transaction_failed = 1'b1;
          break;
        end
        remaining = record_candidate.items[i].ticket.absolute_deadline -
                    $time;
        if (minimum_remaining == 0 || remaining < minimum_remaining)
          minimum_remaining = remaining;
      end
    end

    doorbell_candidate = null;
    doorbell_snapshot_desc = null;
    if (!transaction_failed) begin
      doorbell_candidate = rdma_doorbell_desc::type_id::create(
        "cmq_batch_doorbell_candidate"
      );
      if (doorbell_candidate == null) begin
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ doorbell descriptor construction failed"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      doorbell_candidate.kind = RDMA_DOORBELL_CMQ_SQ;
      status = rdma_cmq_checked_function_snapshot(
        active_function, "CMQ doorbell descriptor", RDMA_SC_INVALID_STATE,
        doorbell_candidate.function_h
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_function_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = rdma_cmq_checked_handle_snapshot(
        cmq_snapshot.handle, "CMQ doorbell descriptor",
        RDMA_SC_INVALID_STATE, doorbell_candidate.target_h
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_target_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      doorbell_candidate.notify_bar_id = prepared_binding.notify_bar_id;
      doorbell_candidate.relative_offset =
        doorbell_snapshot.bar_target.value;
      doorbell_candidate.width = doorbell_snapshot.length;
      doorbell_candidate.endian = doorbell_snapshot.endian;
      doorbell_candidate.payload_image = doorbell_snapshot;
      doorbell_candidate.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
      doorbell_candidate.write_combining_policy =
        RDMA_DB_WRITE_NON_COMBINING;
      doorbell_candidate.allow_merge = 1'b0;
      doorbell_candidate.merge_requested = 1'b0;
      doorbell_candidate.dependencies = dependencies;
      doorbell_candidate.timeout = minimum_remaining;
      doorbell_candidate.readback_policy = RDMA_DB_READBACK_NONE;
      status = checked_doorbell_desc_snapshot(
        doorbell_candidate, doorbell_snapshot_desc
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_descriptor_status"
        );
        transaction_failed = 1'b1;
      end
    end
  endfunction

  // 设计说明：身份与游标元数据已由原 task 写入；本阶段只完善未安装的 candidate 图，按压缩 item
  //  顺序冻结 owner、规范化 body、计算逐项两种摘要与有序 batch 摘要；不得提前安装前缀，
  //  失败时不回拨已分配 ID。
  // 功能：完成 observed journal candidate 的 slot locator、恢复 authority、dependency replayability、
  //  recovery_required 与有序 digest。
  // 输入/输出及副作用：record_candidate/preallocated_candidate 借用同一 detached 图并原位填字段；
  //  profile/backing_mapping 在调用方锁内借用；失败状态原位记录；摘要队列仅本函数内存活。
  // 失败/边界：仅在原锁内、候选非空且已分配非零身份后调用；上游已失败不访问图；owner 冻结、command
  //  校验、body 规范化、item digest 或 classifier 首错即停止并跳过 batch digest；legacy sentinel 不冻结；
  //  失败可留局部图前缀，但不装 journal/observer/fence，不回拨 ID，不取放锁。
  protected function automatic void finalize_observed_journal_candidate_locked(
    input rdma_cmq_batch_submission_record record_candidate,
    input rdma_cmq_preallocated_publish_batch preallocated_candidate,
    ref rdma_status transaction_status,
    ref bit transaction_failed
  );
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_status status;

    if (!transaction_failed) begin
      foreach (record_candidate.items[i]) begin
        rdma_cmq_batch_submission_item_record item;
        string body_tag;
        byte unsigned body_bytes[];
        bit classified_recovery;

        item = record_candidate.items[i];
        // // batch identity 在 admission 压缩后才分配；此处把稳定 journal locator 写入未安装的预分配 slot，
        // // request_index 不参与定位。
        preallocated_candidate.items[i].slot_record.batch_key =
          record_candidate.batch_key;
        preallocated_candidate.items[i].slot_record.journal_item_index = i;
        if (!item.command.recovery_owner.is_legacy_unmigrated()) begin
          status = item.command.recovery_owner.freeze_for_journal(
            record_candidate.function_identity, record_candidate.attempt_id
          );
          if (status == null || !status.ok()) begin
            transaction_status = copy_submit_status_direct(
              status, "cmq_recovery_owner_freeze_status"
            );
            transaction_failed = 1'b1;
            break;
          end
        end
        item.recovery_owner = item.command.recovery_owner;
        status = item.command.validate_for_journal(
          record_candidate.function_identity, record_candidate.attempt_id
        );
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_journal_command_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        item.dependency_replay_safe =
          item.dependency_mapping == backing_mapping &&
          item.dependency_offset ==
            longint'(item.slot_index) * CMQE_BYTES &&
          same_image_value(item.sqe_image, item.dependency_image) &&
          item.dma_context.function_h.generation ==
            record_candidate.function_identity.generation &&
          item.dma_context.reset_epoch ==
            record_candidate.function_identity.reset_epoch &&
          item.dependency_mapping.function_h.generation ==
            record_candidate.function_identity.generation &&
          item.dependency_mapping.reset_epoch ==
            record_candidate.function_identity.reset_epoch;
        status = canonicalize_journal_body(
          profile, item.command, item.sqe_image, body_tag, body_bytes
        );
        if (status == null || !status.ok()) begin
          transaction_status = (status == null) ? rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ command body canonicalization returned null status"
          ) : copy_submit_status_direct(
            status, "cmq_command_canonical_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        status = rdma_cmq_compute_item_digests(
          item.command, body_tag, body_bytes, item.ticket,
          item.recovery_owner, record_candidate.function_identity,
          item.dma_context, item.sqe_image, item.dependency_mapping,
          item.dependency_offset, item.dependency_image,
          item.image_digest, item.authority_digest
        );
        if (status == null || !status.ok()) begin
          transaction_status = (status == null) ? rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ item digest returned null status"
          ) : copy_submit_status_direct(status, "cmq_item_digest_status");
          transaction_failed = 1'b1;
          break;
        end
        status = rdma_cmq_classify_recovery_required(
          item.state, item.completion_phase, item.submission_effect,
          item.reset_isolation_confirmed,
          item.recovery_owner.is_legacy_unmigrated(), classified_recovery
        );
        if (status == null || !status.ok()) begin
          transaction_status = (status == null) ? rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ pending recovery classifier returned null status"
          ) : copy_submit_status_direct(
            status, "cmq_pending_recovery_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        item.recovery_required = classified_recovery;
        request_indices.push_back(item.request_index);
        image_digests.push_back(item.image_digest);
        authority_digests.push_back(item.authority_digest);
      end
    end
    if (!transaction_failed) begin
      status = rdma_cmq_compute_batch_digest(
        record_candidate.function_identity, record_candidate.binding,
        record_candidate.cmq_h, record_candidate.doorbell_image,
        record_candidate.final_pi, record_candidate.final_polarity,
        record_candidate.start_sequence, record_candidate.end_sequence,
        request_indices, image_digests, authority_digests,
        record_candidate.batch_digest
      );
      if (status == null || !status.ok()) begin
        transaction_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, "CMQ batch digest returned null status"
        ) : copy_submit_status_direct(status, "cmq_batch_digest_status");
        transaction_failed = 1'b1;
      end
    end
  endfunction

  // 功能：提交输入对齐的 observed CMQ batch，在 transport 前安装完整 journal、ticket index、
  //  preallocation、profile 与 authentic MMIO observer 图。
  // 输入/输出及副作用：commands 为输入；results 与 commands 等长同序；batch_status 仅描述 orchestration；
  //  成功 admission 可能写 Host-memory/MMIO，并经 observer 或同步返回更新 journal/fence/runtime；
  //  失败 status 由本 task 集中回填。
  // 失败/边界：空 batch 取锁前返回 OK；准入与 ID 分配前的拒绝不分配 ID、不调 transport；分配后失败可能
  //  留下单调 counter 空洞但不装部分 journal；encoder 改写 handle 优先于 null/失败状态，metadata 先于
  //  deadline，过期 ticket 先于 descriptor factory；PRE effect 原子回滚，Host 可见/UNOBSERVED/已 arm 结果
  //  保留恢复 authority；malformed status/effect 分别降级；legacy owner 不授予自动发布重试。
  task submit_batch_observed(
    input rdma_cmq_command_desc commands[],
    output rdma_cmq_execution_result results[],
    output rdma_status batch_status
  );
    rdma_cmq_batch_submission_record record_candidate;
    rdma_cmq_batch_submission_record retained_record;
    rdma_cmq_preallocated_publish_batch preallocated_candidate;
    rdma_cmq_submit_candidate_stage_t candidate_stage;
    rdma_cmq_mmio_arm_observer observer;
    rdma_doorbell_desc doorbell_snapshot_desc;
    rdma_doorbell_submission_result transport_result;
    rdma_cmq_submit_transport_decision_t evidence;
    rdma_cmq_submit_transport_decision_t decision;
    rdma_function_binding journal_binding;
    rdma_function_identity journal_identity;
    rdma_function_handle active_function;
    rdma_handle journal_cmq_h;
    rdma_hw_image doorbell_snapshot;
    bit local_result_finalized[];
    rdma_status status;
    rdma_status transaction_status;
    rdma_status_code_e observation_code;
    longint unsigned batch_id;
    longint unsigned attempt_id;
    longint unsigned final_sequence;
    longint unsigned used;
    int unsigned final_pi;
    bit final_polarity;
    bit transaction_failed;
    bit observer_armed;
    bit retry_safe;
    string batch_key;
    string capability_key;
    string observation_message;

    results = new[commands.size()];
    batch_status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ observed batch did not complete"
    );
    if (commands.size() == 0) begin
      batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
      return;
    end

    local_result_finalized = new[commands.size()];
    foreach (results[i]) begin
      results[i] = new_submit_result_direct(
        $sformatf("cmq_observed_result_%0d", i)
      );
      local_result_finalized[i] = 1'b0;
    end

    transaction_failed = 1'b0;
    transaction_status = null;
    candidate_stage.staged_profile_format_valid = 1'b0;
    candidate_stage.staged_profile_endian = RDMA_ENDIAN_LITTLE;
    candidate_stage.staged_profile_hardware_version = 0;
    candidate_stage.dependencies.delete();

    engine_lock.get(1);
    if (!admit_observed_batch_locked(
          results, batch_status, active_function, used
        )) begin
      engine_lock.put(1);
      return;
    end
    status = prepared_binding.snapshot_complete_nonfatal(journal_binding);
    if (status == null || !status.ok() || journal_binding == null) begin
      transaction_status = (status == null) ? rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal binding snapshot returned null status"
      ) : copy_submit_status_direct(status, "cmq_binding_snapshot_status");
      transaction_failed = 1'b1;
    end
    if (!transaction_failed) begin
      status = journal_binding.snapshot_identity_nonfatal(journal_identity);
      if (status == null || !status.ok() || journal_identity == null) begin
        transaction_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal Function identity snapshot returned null status"
        ) : copy_submit_status_direct(
          status, "cmq_identity_snapshot_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed &&
        !rdma_cmq_try_snapshot_handle_direct(
          cmq_snapshot.handle, 1'b0, journal_cmq_h
        )) begin
      transaction_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ journal handle snapshot failed"
      );
      transaction_failed = 1'b1;
    end

    record_candidate = new("cmq_submission_record_candidate");
    preallocated_candidate = new("cmq_publish_batch_candidate");
    if (!transaction_failed) begin
      record_candidate.engine_instance_id = engine_instance_id;
      record_candidate.engine_incarnation = engine_incarnation;
      record_candidate.function_identity = journal_identity;
      record_candidate.binding = journal_binding;
      record_candidate.cmq_h = journal_cmq_h;
      record_candidate.start_sequence = publish_seq;
      record_candidate.state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
      record_candidate.submission_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      record_candidate.attempt_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      record_candidate.observer_armed = 1'b0;
      record_candidate.publication_retry_safe = 1'b0;
      candidate_stage.staged_profile_format_valid =
        profile_image_format_valid;
      candidate_stage.staged_profile_endian = profile_image_endian;
      candidate_stage.staged_profile_hardware_version =
        profile_hardware_version;
    end

    // 设计说明：两个 candidate 句柄只借给锁内逐项阶段；status/failed 回传原 task 以沿用唯一失败回填点；
    //  依赖队列与 profile 格式留在调用期 context，所有 ID 仍在此步之后分配。
    if (!transaction_failed) begin
      candidate_stage.record_candidate = record_candidate;
      candidate_stage.preallocated_candidate = preallocated_candidate;
      candidate_stage.transaction_status = transaction_status;
      candidate_stage.transaction_failed = transaction_failed;
      stage_observed_candidates_locked(
        commands, active_function, used, results, local_result_finalized,
        candidate_stage
      );
      transaction_status = candidate_stage.transaction_status;
      transaction_failed = candidate_stage.transaction_failed;
    end

    if (!transaction_failed && record_candidate.items.size() == 0) begin
      batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
      engine_lock.put(1);
      return;
    end

    // 设计说明：all-local 快路已在上方结束；仅成功压缩出的候选才借用原锁调用 image 阶段，
    //  失败回到原 task 的唯一 fanout 点，deadline、ID 与安装步骤仍在其后。
    if (!transaction_failed) begin
      stage_observed_doorbell_image_locked(
        record_candidate.items.size(), final_sequence, final_pi,
        final_polarity, doorbell_snapshot, transaction_status,
        transaction_failed
      );
    end

    // 设计说明：image 阶段失败时仍调用一次 pre-ID helper 以清空 descriptor 输出；它仅在
    //  transaction_failed 为 0 时访问 ticket 或 factory；锁与 failure fanout 仍由当前 task 持有。
    stage_observed_doorbell_descriptor_locked(
      record_candidate, active_function, doorbell_snapshot,
      candidate_stage.dependencies, doorbell_snapshot_desc,
      transaction_status, transaction_failed
    );

    if (!transaction_failed) begin
      status = allocate_batch_identity_locked(
        record_candidate.function_identity, batch_key, batch_id
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_batch_identity_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = allocate_attempt_id_locked(attempt_id);
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_attempt_identity_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      record_candidate.batch_key = batch_key;
      record_candidate.batch_id = batch_id;
      record_candidate.attempt_id = attempt_id;
      record_candidate.end_sequence = final_sequence;
      record_candidate.doorbell_image = doorbell_snapshot;
      record_candidate.final_pi = final_pi;
      record_candidate.final_polarity = final_polarity;
      preallocated_candidate.batch_key = batch_key;
      preallocated_candidate.attempt_id = attempt_id;
      preallocated_candidate.final_sequence = final_sequence;
      preallocated_candidate.profile_format_valid =
        candidate_stage.staged_profile_format_valid;
      preallocated_candidate.profile_endian =
        candidate_stage.staged_profile_endian;
      preallocated_candidate.profile_hardware_version =
        candidate_stage.staged_profile_hardware_version;

      // // 借用未安装的局部图冻结并算摘要；失败仍由下方 fanout 回填，已分配身份不回拨，
      // // observer/journal 安装须等阶段成功。
      finalize_observed_journal_candidate_locked(
        record_candidate, preallocated_candidate, transaction_status,
        transaction_failed
      );
    end

    observer = null;
    capability_key = "";
    if (!transaction_failed) begin
      capability_key = $sformatf(
        "%s|attempt=%016h", batch_key, attempt_id
      );
      observer = new("cmq_submission_mmio_observer");
      status = observer.configure(
        this, capability_key, batch_key, attempt_id, engine_incarnation
      );
      if (status == null || !status.ok() ||
          arm_observers.exists(capability_key)) begin
        transaction_status = (status == null || status.ok()) ?
          rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ MMIO observer construction or key collision failed"
          ) : copy_submit_status_direct(
            status, "cmq_observer_configure_status"
          );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = install_submission_journal_locked(
        record_candidate, preallocated_candidate
      );
      if (status == null || !status.ok()) begin
        transaction_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal installation returned null status"
        ) : copy_submit_status_direct(
          status, "cmq_journal_installation_status"
        );
        transaction_failed = 1'b1;
      end
    end

    if (transaction_failed) begin
      if (transaction_status == null)
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ batch transaction failed without a status"
        );
      foreach (results[i]) begin
        if (!local_result_finalized[i])
          results[i].status = copy_submit_status_direct(
            transaction_status,
            $sformatf("cmq_transaction_failure_item_%0d", i)
          );
      end
      batch_status = copy_submit_status_direct(
        transaction_status, "cmq_transaction_failure_batch"
      );
      engine_lock.put(1);
      return;
    end

    arm_observers[capability_key] = observer;
    fenced_batch_key = batch_key;
    submission_fence_reason =
      "CMQ observed submission awaits authentic MMIO classification";
    retained_record = submission_journal[batch_key];
    foreach (retained_record.items[i]) begin
      int unsigned token_index;

      token_index = retained_record.items[i].command_token;
      token_incarnation[token_index] =
        retained_record.items[i].ticket.command_id[63:5];
    end

    transport_result = null;
    transport.submit_observed(
      prepared_binding, doorbell_snapshot_desc, observer, transport_result
    );
    retained_record = submission_journal[batch_key];
    observer_armed = retained_record != null &&
                     retained_record.observer_armed;
    if (!observer_armed)
      arm_observers.delete(capability_key);

    // 设计说明：decode 只发布局部证据；先消费未 arm 的 PRE rollback，再扫描 retained owner 并分类
    //  非 PRE effect；transport 与提交仍持同一锁。
    decode_observed_transport_evidence(
      transport_result, observer_armed, evidence
    );
    if (evidence.rollback_pre) begin
      foreach (retained_record.items[i]) begin
        int unsigned request_index;

        request_index = retained_record.items[i].request_index;
        results[request_index].status = copy_submit_status_direct(
          evidence.operation_status,
          $sformatf("cmq_pre_rejected_item_%0d", request_index)
        );
        results[request_index].observation_status = rdma_cmq_direct_status(
          evidence.observation_code, evidence.observation_message
        );
        results[request_index].submission_effect =
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
        results[request_index].attempt_effect =
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
        results[request_index].completion_phase =
          RDMA_CMQ_COMPLETION_NONE;
        results[request_index].recovery_required = 1'b0;
      end
      status = remove_submission_journal_locked(batch_key);
      if (status == null || !status.ok()) begin
        batch_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ PRE rollback returned null status"
        ) : copy_submit_status_direct(status, "cmq_pre_rollback_status");
        engine_lock.put(1);
        return;
      end
      batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
      engine_lock.put(1);
      return;
    end

    retry_safe = 1'b1;
    // 设计说明：dependency replayability 只证明数据可重放，不替代恢复 authority；journal 安装已验证 owner
    //  shape，故 LEGACY_UNMIGRATED workflow 必为精确 sentinel，保留人工 reconciliation 但无自动 retry 授权。
    foreach (retained_record.items[i]) begin
      rdma_cmq_batch_submission_item_record retry_item;

      retry_item = retained_record.items[i];
      if (retry_item == null || !retry_item.dependency_replay_safe)
        retry_safe = 1'b0;
      if (retry_item == null || retry_item.recovery_owner == null)
        retry_safe = 1'b0;
      else if (retry_item.recovery_owner.workflow ===
               RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED)
        retry_safe = 1'b0;
    end
    classify_observed_transport_effect(
      observer_armed, retry_safe, evidence, decision
    );

    // 设计说明：分类阶段不持 mutable journal；此处在原临界区唯一的 retained batch 提交点一次写入
    //  状态与 effect，随后才逐项生成结果。
    observation_code = decision.observation_code;
    observation_message = decision.observation_message;
    retained_record.state = decision.state;
    retained_record.publication_retry_safe =
      decision.publication_retry_safe;
    retained_record.submission_effect = decision.cumulative_effect;
    retained_record.attempt_effect = decision.attempt_effect;

    foreach (retained_record.items[i]) begin
      rdma_cmq_batch_submission_item_record item;
      rdma_cmq_execution_result detached_result;
      bit classified_recovery;
      int unsigned request_index;

      item = retained_record.items[i];
      item.state = retained_record.state;
      item.submission_effect = retained_record.submission_effect;
      item.attempt_effect = retained_record.attempt_effect;
      item.completion_phase = observer_armed ?
        RDMA_CMQ_COMPLETION_PENDING : RDMA_CMQ_COMPLETION_NONE;
      item.status = copy_submit_status_direct(
        decision.operation_status, $sformatf("cmq_journal_operation_%0d", i)
      );
      status = rdma_cmq_classify_recovery_required(
        item.state, item.completion_phase, item.submission_effect,
        item.reset_isolation_confirmed,
        item.recovery_owner.is_legacy_unmigrated(), classified_recovery
      );
      if (status == null || !status.ok()) begin
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message = (status == null) ?
          "CMQ retained recovery classifier returned null status" :
          status.message;
        item.recovery_required = 1'b1;
      end
      else begin
        item.recovery_required = classified_recovery;
      end
      request_index = item.request_index;
      status = build_observed_result_locked(
        retained_record, item, observation_code, observation_message,
        detached_result
      );
      if (status == null || !status.ok() || detached_result == null) begin
        detached_result = new_submit_result_direct(
          $sformatf("cmq_observed_fallback_%0d", request_index)
        );
        detached_result.status = copy_submit_status_direct(
          item.status, $sformatf("cmq_observed_fallback_status_%0d", i)
        );
        detached_result.observation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ observed result snapshot failed"
        );
        detached_result.submission_effect = item.submission_effect;
        detached_result.attempt_effect = item.attempt_effect;
        detached_result.completion_phase = item.completion_phase;
        detached_result.batch_key = retained_record.batch_key;
        detached_result.batch_id = retained_record.batch_id;
        detached_result.attempt_id = retained_record.attempt_id;
        detached_result.recovery_required = 1'b1;
      end
      results[request_index] = detached_result;
    end
    batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
    engine_lock.put(1);
  endtask

  // 设计说明：locate/对齐、结果暂存与 stale/action 检查已完成；本阶段先让 request 图自证，再让 journal 图
  //  独立自证，最后比较两图完整值。carried digest 不能替代源值重算或完整值认证。
  // 功能：按固定优先级认证 recovery request 与 retained journal 的逐项和批次 authority，返回首个失败。
  // 输入/输出及副作用：request/record/profile_service 为锁内借用图；摘要队列仅函数内存活；返回
  //  journal_status，不保存输入句柄、不改两图或账本；canonicalization 仍调用原 profile seam。
  // 失败/边界：调用方须已验证两图 item 数量/顺序、ticket 与 Function identity；request 重算及 carried
  //  检查先于 journal 对应步骤，随后做完整值比较，首错即返回；不检查 action/reset proof，不取放锁、
  //  不做 CAS/I/O；回填与解锁仍由 recovery task 负责。
  protected function automatic rdma_status authenticate_recovery_graphs_locked(
    input rdma_cmq_submission_recovery_request request,
    input rdma_cmq_batch_submission_record record,
    input rdma_cmq_hw_profile profile_service
  );
    int unsigned request_indices[$];
    int unsigned journal_indices[$];
    rdma_cmq_journal_digest_t request_image_digests[$];
    rdma_cmq_journal_digest_t request_authority_digests[$];
    rdma_cmq_journal_digest_t journal_image_digests[$];
    rdma_cmq_journal_digest_t journal_authority_digests[$];
    rdma_cmq_journal_digest_t request_batch_digest;
    rdma_cmq_journal_digest_t journal_batch_digest;
    rdma_status nested_status;
    rdma_status status;

    // // request 图的 body 与 digest 仅从 request-owned 值重算；全部重算完成前不把 journal carried
    // // digest 当作可信输入。
    foreach (request.items[i]) begin
      string body_tag;
      byte unsigned body_bytes[];
      rdma_cmq_journal_digest_t image_digest;
      rdma_cmq_journal_digest_t authority_digest;

      nested_status = canonicalize_journal_body(
        profile_service, request.items[i].command,
        request.items[i].sqe_image, body_tag, body_bytes
      );
      if (nested_status != null && nested_status.ok())
        nested_status = rdma_cmq_compute_item_digests(
          request.items[i].command, body_tag, body_bytes,
          request.items[i].ticket, request.items[i].recovery_owner,
          request.expected_function_identity, request.items[i].dma_context,
          request.items[i].sqe_image,
          request.items[i].dependency_mapping,
          request.items[i].dependency_offset,
          request.items[i].dependency_image, image_digest, authority_digest
        );
      if (nested_status == null || !nested_status.ok()) begin
        status = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request item recomputation returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
        return status;
      end
      request_indices.push_back(request.items[i].request_index);
      request_image_digests.push_back(image_digest);
      request_authority_digests.push_back(authority_digest);
    end
    nested_status = rdma_cmq_compute_batch_digest(
      request.expected_function_identity, request.binding, request.cmq_h,
      request.doorbell_image, request.final_pi, request.final_polarity,
      request.start_sequence, request.end_sequence, request_indices,
      request_image_digests, request_authority_digests,
      request_batch_digest
    );
    if (nested_status == null || !nested_status.ok()) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery request batch recomputation returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      return status;
    end
    foreach (request.items[i]) begin
      if (request.items[i].image_digest !== request_image_digests[i] ||
          request.items[i].authority_digest !==
            request_authority_digests[i]) begin
        status = journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request item carried digest is inconsistent"
        );
        return status;
      end
    end
    if (request.batch_digest !== request_batch_digest) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request carried batch digest is inconsistent"
      );
      return status;
    end

    // // journal 图用 retained exact profile 从 journal-owned 值独立重算；其 carried digest 自证后，
    // // 才与 request 重算值和完整值逐项比较。
    foreach (record.items[i]) begin
      string body_tag;
      byte unsigned body_bytes[];
      rdma_cmq_journal_digest_t image_digest;
      rdma_cmq_journal_digest_t authority_digest;

      nested_status = canonicalize_journal_body(
        profile_service, record.items[i].command,
        record.items[i].sqe_image, body_tag, body_bytes
      );
      if (nested_status != null && nested_status.ok())
        nested_status = rdma_cmq_compute_item_digests(
          record.items[i].command, body_tag, body_bytes,
          record.items[i].ticket, record.items[i].recovery_owner,
          record.function_identity, record.items[i].dma_context,
          record.items[i].sqe_image, record.items[i].dependency_mapping,
          record.items[i].dependency_offset,
          record.items[i].dependency_image, image_digest, authority_digest
        );
      if (nested_status == null || !nested_status.ok()) begin
        status = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery journal item recomputation returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
        return status;
      end
      journal_indices.push_back(record.items[i].request_index);
      journal_image_digests.push_back(image_digest);
      journal_authority_digests.push_back(authority_digest);
    end
    nested_status = rdma_cmq_compute_batch_digest(
      record.function_identity, record.binding, record.cmq_h,
      record.doorbell_image, record.final_pi, record.final_polarity,
      record.start_sequence, record.end_sequence, journal_indices,
      journal_image_digests, journal_authority_digests,
      journal_batch_digest
    );
    if (nested_status == null || !nested_status.ok()) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery journal batch recomputation returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      return status;
    end
    foreach (record.items[i]) begin
      if (record.items[i].image_digest !== journal_image_digests[i] ||
          record.items[i].authority_digest !==
            journal_authority_digests[i]) begin
        status = journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery journal item carried digest is inconsistent"
        );
        return status;
      end
    end
    if (record.batch_digest !== journal_batch_digest) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery journal carried batch digest is inconsistent"
      );
      return status;
    end

    foreach (request.items[i]) begin
      nested_status = validate_recovery_item_match_locked(
        request.items[i], record.items[i], request_image_digests[i],
        request_authority_digests[i], journal_image_digests[i],
        journal_authority_digests[i]
      );
      if (nested_status == null || !nested_status.ok()) begin
        status = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery item full-value comparison returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
        return status;
      end
    end
    nested_status = validate_recovery_batch_match_locked(
      request, record, request_batch_digest, journal_batch_digest
    );
    if (nested_status == null || !nested_status.ok()) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery batch full-value comparison returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      return status;
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 设计说明：CONFIRM 在双图与 owner 授权之后只读重验 retained 行；journal/lifecycle、READY、双份 proof
  //  自证与全值、proof-to-row binding 须按此顺序完成；attempt 重验与提交仍由入口 task 负责。
  // 功能：验证 reset confirmation 的未解决 concrete owner、RESET_CANCELLED 生命周期，以及 engine-minted
  //  READY proof 对同一 retained batch 的完整授权。
  // 输入/输出及副作用：request/record/profile_service 为已完成双图认证的借用句柄；仅返回首个 status，
  //  两个 proof digest 为局部暂存；不改输入图、不管锁/results/I/O。
  // 失败/边界：journal 无效、非隔离终态、无未解决 owner、proof 缺失/非 READY 为 INVALID_STATE；
  //  digest/完整值不符为 INVALID_ARGUMENT；digest/binding 校验失败保留原 code/message。
  protected function automatic rdma_status validate_reset_confirmation_locked(
    input rdma_cmq_submission_recovery_request request,
    input rdma_cmq_batch_submission_record record,
    input rdma_cmq_hw_profile profile_service
  );
    rdma_cmq_journal_digest_t request_proof_digest;
    rdma_cmq_journal_digest_t journal_proof_digest;
    rdma_status nested_status;
    rdma_status status;

    nested_status = validate_submission_record_locked(
      record, profile_service, 1'b0
    );
    if (nested_status == null || !nested_status.ok()) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        (nested_status == null) ?
          "CMQ reset confirmation journal validation returned null" :
          {"CMQ reset confirmation journal is invalid: ",
           nested_status.message}
      );
      return status;
    end
    if (record.state != RDMA_CMQ_SUBMISSION_RESET_QUARANTINED) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ reset confirmation requires a quarantined batch"
      );
      return status;
    end
    begin
      bit concrete_pending;

      concrete_pending = 1'b0;
      foreach (record.items[i]) begin
        if (record.items[i].recovery_owner.is_legacy_unmigrated() ||
            record.items[i].reset_isolation_confirmed ||
            !record.items[i].recovery_required)
          continue;
        if (record.items[i].state !=
              RDMA_CMQ_SUBMISSION_RESET_QUARANTINED ||
            record.items[i].completion_phase !=
              RDMA_CMQ_COMPLETION_RESET_CANCELLED) begin
          status = journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset confirmation item lifecycle is not unresolved"
          );
          return status;
        end
        concrete_pending = 1'b1;
      end
      if (!concrete_pending) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ reset confirmation has no unresolved concrete owner"
        );
        return status;
      end
    end
    if (request.reset_isolation_proof == null ||
        record.reset_isolation_proof == null ||
        record.reset_isolation_proof.state !=
          RDMA_CMQ_RESET_PROOF_READY ||
        request.reset_isolation_proof.state !=
          RDMA_CMQ_RESET_PROOF_READY) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ reset isolation proof is absent or not READY"
      );
      return status;
    end
    nested_status = rdma_cmq_compute_reset_proof_digest(
      request.reset_isolation_proof.proof_key,
      request.reset_isolation_proof.proof_id,
      request.reset_isolation_proof.batch_key,
      request.reset_isolation_proof.batch_id,
      request.reset_isolation_proof.attempt_id,
      request.reset_isolation_proof.engine_instance_id,
      request.reset_isolation_proof.engine_incarnation,
      request.reset_isolation_proof.isolated_identity,
      request.reset_isolation_proof.batch_digest,
      request.reset_isolation_proof.isolated_request_indices,
      request.reset_isolation_proof.isolated_image_digests,
      request.reset_isolation_proof.isolated_authority_digests,
      request.reset_isolation_proof.isolated_recovery_owners,
      request_proof_digest
    );
    if (nested_status != null && nested_status.ok())
      nested_status = rdma_cmq_compute_reset_proof_digest(
        record.reset_isolation_proof.proof_key,
        record.reset_isolation_proof.proof_id,
        record.reset_isolation_proof.batch_key,
        record.reset_isolation_proof.batch_id,
        record.reset_isolation_proof.attempt_id,
        record.reset_isolation_proof.engine_instance_id,
        record.reset_isolation_proof.engine_incarnation,
        record.reset_isolation_proof.isolated_identity,
        record.reset_isolation_proof.batch_digest,
        record.reset_isolation_proof.isolated_request_indices,
        record.reset_isolation_proof.isolated_image_digests,
        record.reset_isolation_proof.isolated_authority_digests,
        record.reset_isolation_proof.isolated_recovery_owners,
        journal_proof_digest
      );
    if (nested_status == null || !nested_status.ok() ||
        request.reset_isolation_proof.proof_digest !==
          request_proof_digest ||
        record.reset_isolation_proof.proof_digest !==
          journal_proof_digest ||
        request_proof_digest !== journal_proof_digest ||
        request.reset_isolation_proof.batch_digest !==
          request.batch_digest ||
        !rdma_cmq_same_reset_isolation_proof_value(
          request.reset_isolation_proof,
          record.reset_isolation_proof
        )) begin
      status = (nested_status == null || nested_status.ok()) ?
        journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ reset isolation proof authority does not match"
        ) : journal_status(nested_status.code, nested_status.message);
      return status;
    end
    nested_status = validate_reset_isolation_proof_binding_locked(
      record.reset_isolation_proof, record
    );
    if (nested_status == null || !nested_status.ok()) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ reset proof binding validation returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      return status;
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 设计说明：RETRY 的 live authority 与 preallocation 是证明 journal 仍可被当前 engine 重放的唯一
  //  admission 层；须在 candidate/observer/transport staging 之前完成，且不得把账本推进到 CAS 之外。
  // 功能：engine_lock 内按旧顺序认证 RETRY 的 engine/binding/CMQ authority、journal lifecycle、
  //  live/item mapping、fence、stale observer、preallocated row 与 slot/token/command/entry registry。
  // 输入/输出及副作用：request/record/profile_service 为借用图；成功时 preallocated 指向 retained row，
  //  status 返回原拒绝 code/message（含 OK+null mapping 旧边界）；只调 mapping authority seam，
  //  不取放锁、不改 counter/ledger。
  // 失败/边界：任一条件失败返回 0；mapping seam 返回 OK 但无 mapping 仍拒绝并保留 OK status；
  //  preallocated 冲突先于 attempt overflow；成功仅表示 admission 完成，最终重验与 CAS 由
  //  recover_submission_observed 负责。
  protected function automatic bit admit_retry_live_authority_locked(
    input rdma_cmq_submission_recovery_request request,
    input rdma_cmq_batch_submission_record record,
    input rdma_cmq_hw_profile profile_service,
    output rdma_cmq_preallocated_publish_batch preallocated,
    output rdma_status status
  );
    rdma_dma_mapping live_mapping_authority;
    rdma_status nested_status;

    preallocated = null;
    status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ recovery RETRY admission did not complete"
    );
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE || prepared_binding == null ||
        dma_context == null || cmq_snapshot == null ||
        backing_mapping == null || transport == null || profile == null ||
        !rdma_cmq_same_journal_binding_value(prepared_binding, record.binding) ||
        !same_handle(cmq_snapshot.handle, record.cmq_h)) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery live Function or CMQ authority drifted"
      );
      return 1'b0;
    end
    nested_status = validate_submission_record_locked(
      record, profile_service, 1'b0
    );
    if (nested_status == null || !nested_status.ok() ||
        record.state !=
          RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED ||
        record.observer_armed || !record.publication_retry_safe ||
        !(record.submission_effect inside {
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
        })) begin
      status = (nested_status == null || nested_status.ok()) ?
        journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery journal lifecycle is not retryable"
        ) : journal_status(nested_status.code, nested_status.message);
      return 1'b0;
    end
    nested_status = mapping_authority_status(backing_mapping, dma_context);
    if (nested_status != null && nested_status.ok())
      nested_status = backing_mapping.snapshot_release_authority(
        live_mapping_authority
      );
    if (nested_status != null && nested_status.ok() &&
        live_mapping_authority != null)
      nested_status = backing_mapping.release_authority_status(
        live_mapping_authority
      );
    if (nested_status == null || !nested_status.ok() ||
        live_mapping_authority == null) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery live mapping authority returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      return 1'b0;
    end
    foreach (record.items[i]) begin
      if (record.items[i].state != record.state ||
          record.items[i].submission_effect != record.submission_effect ||
          record.items[i].completion_phase != RDMA_CMQ_COMPLETION_NONE ||
          record.items[i].reset_isolation_confirmed ||
          !record.items[i].recovery_required ||
          !record.items[i].dependency_replay_safe ||
          !same_journal_mapping_public_value(
            backing_mapping, record.items[i].dependency_mapping
          ) || !same_journal_mapping_public_value(
            backing_mapping, request.items[i].dependency_mapping
          )) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery item mapping or replay authority is invalid"
        );
        return 1'b0;
      end
      nested_status = backing_mapping.release_authority_status(
        request.items[i].dependency_mapping
      );
      if (nested_status != null && nested_status.ok())
        nested_status = backing_mapping.release_authority_status(
          record.items[i].dependency_mapping
        );
      if (nested_status == null || !nested_status.ok()) begin
        status = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery item opaque mapping check returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
        return 1'b0;
      end
    end
    if (fenced_batch_key != record.batch_key ||
        submission_fence_reason.len() == 0) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery batch does not own the active submission fence"
      );
      return 1'b0;
    end
    foreach (arm_observers[registered_key]) begin
      if (arm_observers[registered_key] == null ||
          arm_observers[registered_key].get_batch_key() == record.batch_key) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery found a stale MMIO observer capability"
        );
        return 1'b0;
      end
    end
    if (!preallocated_publish_batches.exists(record.batch_key)) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery preallocated publication row is missing"
      );
      return 1'b0;
    end
    preallocated = preallocated_publish_batches[record.batch_key];
    if (preallocated == null ||
        preallocated.batch_key != record.batch_key ||
        preallocated.attempt_id != record.attempt_id ||
        preallocated.final_sequence != record.end_sequence ||
        preallocated.items.size() != record.items.size() ||
        record.start_sequence != publish_seq) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery preallocation is inconsistent with the journal"
      );
      return 1'b0;
    end
    foreach (record.items[i]) begin
      rdma_cmq_preallocated_publish_item publish_item;

      publish_item = preallocated.items[i];
      if (publish_item == null || publish_item.slot_record == null ||
          publish_item.slot_record.expected == null ||
          publish_item.request_index != record.items[i].request_index ||
          publish_item.slot_record.ticket != record.items[i].ticket ||
          publish_item.slot_record.slot_sequence !=
            record.items[i].slot_sequence ||
          publish_item.slot_record.sq_index != record.items[i].slot_index ||
          publish_item.slot_record.sq_wrap != record.items[i].slot_wrap ||
          publish_item.slot_record.state != CMQ_SLOT_PUBLISHED ||
          publish_item.slot_record.batch_key != record.batch_key ||
          publish_item.slot_record.journal_item_index != i ||
          publish_item.command_token != record.items[i].command_token ||
          publish_item.command_key != command_key(record.items[i].ticket) ||
          publish_item.entry_key != record.items[i].entry_key ||
          record.items[i].slot_index >= CMQ_DEPTH ||
          slots[record.items[i].slot_index] != null ||
          token_in_use[record.items[i].command_token] ||
          command_registry.exists(publish_item.command_key) ||
          entry_registry.exists(publish_item.entry_key)) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery preallocation or runtime registry collides"
        );
        return 1'b0;
      end
    end
    status = journal_status(RDMA_SC_OK);
    return 1'b1;
  endfunction

  // 设计说明：RETRY staging 把 ticket deadline、dependency descriptor、detached doorbell snapshot 与
  //  未登记 observer 组成 call-local 候选图；须待 expected-attempt 重验后才可进入 CAS/registry。
  // 功能：按 retained record 与 candidate attempt 完成 deadline 校验、依赖队列、descriptor 快照及
  //  observer configure，成功候选写入 stage。
  // 输入/输出及副作用：record 为锁内借用图；candidate_attempt 为下一 attempt；stage 输出候选句柄、
  //  deadline、capability key；status 输出原诊断；不登记 observer、不改 journal/counter、不调 transport。
  // 失败/边界：X/Z、零值或过期 deadline、依赖/descriptor/observer null、嵌套快照非 OK、observer key
  //  冲突/configure 失败均返回 0，且无 registry 可见副作用；成功仅表示 staging 完成。
  protected function automatic bit stage_recovery_candidate_locked(
    input rdma_cmq_batch_submission_record record,
    input longint unsigned candidate_attempt,
    output rdma_cmq_recovery_candidate_stage_t stage,
    output rdma_status status
  );
    rdma_doorbell_dependency dependencies[$];
    rdma_doorbell_desc doorbell_candidate;
    rdma_doorbell_desc doorbell_snapshot_desc;
    rdma_cmq_mmio_arm_observer observer;
    rdma_function_handle descriptor_function_source;
    rdma_handle descriptor_target;
    rdma_status nested_status;
    time minimum_remaining;
    time remaining;
    string capability_key;

    stage.dependencies.delete();
    stage.doorbell_snapshot_desc = null;
    stage.observer = null;
    stage.candidate_attempt = candidate_attempt;
    stage.minimum_remaining = 0;
    stage.capability_key = "";
    status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ recovery candidate staging did not complete"
    );

    minimum_remaining = 0;
    foreach (record.items[i]) begin
      if ($isunknown(record.items[i].ticket.absolute_deadline)) begin
        status = journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery ticket deadline contains X/Z"
        );
        return 1'b0;
      end
      if (record.items[i].ticket.absolute_deadline == 0 ||
          record.items[i].ticket.absolute_deadline <= $time) begin
        status = journal_status(
          RDMA_SC_TIMEOUT,
          "CMQ recovery ticket deadline is not strictly in the future"
        );
        return 1'b0;
      end
      remaining = record.items[i].ticket.absolute_deadline - $time;
      if (minimum_remaining == 0 || remaining < minimum_remaining)
        minimum_remaining = remaining;
    end

    dependencies.delete();
    foreach (record.items[i]) begin
      rdma_doorbell_dependency dependency;

      dependency = new($sformatf("cmq_recovery_dependency_%0d", i));
      dependency.dependency_id = record.items[i].slot_sequence + 1'b1;
      dependency.stage = RDMA_DB_DEP_QUEUE_CONTEXT;
      dependency.mapping = record.items[i].dependency_mapping;
      dependency.relative_offset = record.items[i].dependency_offset;
      dependency.image = record.items[i].dependency_image;
      dependency.ready = 1'b1;
      dependencies.push_back(dependency);
    end
    doorbell_candidate = make_recovery_doorbell_locked(
      "cmq_recovery_doorbell_candidate"
    );
    descriptor_function_source = record.binding.make_handle();
    if (doorbell_candidate == null || descriptor_function_source == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery doorbell descriptor construction failed"
      );
      return 1'b0;
    end
    nested_status = rdma_cmq_checked_function_snapshot(
      descriptor_function_source, "CMQ recovery doorbell descriptor",
      RDMA_SC_INVALID_STATE, doorbell_candidate.function_h
    );
    if (nested_status != null && nested_status.ok())
      nested_status = rdma_cmq_checked_handle_snapshot(
        record.cmq_h, "CMQ recovery doorbell descriptor",
        RDMA_SC_INVALID_STATE, descriptor_target
      );
    if (nested_status == null || !nested_status.ok() ||
        descriptor_target == null) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery descriptor nested snapshot returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      return 1'b0;
    end
    doorbell_candidate.kind = RDMA_DOORBELL_CMQ_SQ;
    doorbell_candidate.target_h = descriptor_target;
    doorbell_candidate.notify_bar_id = record.binding.notify_bar_id;
    doorbell_candidate.relative_offset =
      record.doorbell_image.bar_target.value;
    doorbell_candidate.width = record.doorbell_image.length;
    doorbell_candidate.endian = record.doorbell_image.endian;
    doorbell_candidate.payload_image = record.doorbell_image;
    doorbell_candidate.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    doorbell_candidate.write_combining_policy =
      RDMA_DB_WRITE_NON_COMBINING;
    doorbell_candidate.allow_merge = 1'b0;
    doorbell_candidate.merge_requested = 1'b0;
    doorbell_candidate.dependencies = dependencies;
    doorbell_candidate.timeout = minimum_remaining;
    doorbell_candidate.readback_policy = RDMA_DB_READBACK_NONE;
    nested_status = checked_doorbell_desc_snapshot(
      doorbell_candidate, doorbell_snapshot_desc
    );
    if (nested_status == null || !nested_status.ok() ||
        doorbell_snapshot_desc == null) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery descriptor validation returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      return 1'b0;
    end

    capability_key = $sformatf(
      "%s|attempt=%016h", record.batch_key, candidate_attempt
    );
    observer = make_recovery_observer_locked(
      "cmq_recovery_mmio_observer"
    );
    if (observer == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery observer construction failed"
      );
      return 1'b0;
    end
    nested_status = observer.configure(
      this, capability_key, record.batch_key, candidate_attempt,
      engine_incarnation
    );
    if (nested_status == null || !nested_status.ok() ||
        arm_observers.exists(capability_key)) begin
      status = (nested_status == null || nested_status.ok()) ?
        journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery observer configuration or key collision failed"
        ) : journal_status(nested_status.code, nested_status.message);
      return 1'b0;
    end

    stage.dependencies = dependencies;
    stage.doorbell_snapshot_desc = doorbell_snapshot_desc;
    stage.observer = observer;
    stage.minimum_remaining = minimum_remaining;
    stage.capability_key = capability_key;
    status = journal_status(RDMA_SC_OK);
    return 1'b1;
  endfunction

  // 设计说明：最终 expected-attempt 重验后 RETRY 不再走 admission 拒绝出口；唯一 CAS、同步 transport
  //  与证据交付在同一锁内完成；transport 操作失败不是 orchestration 回滚，须保留已提交 attempt 与证据。
  // 功能：提交已准入的恢复 attempt，登记 observer、发布一次 transport，把真实 arm 与 effect 折叠到
  //  retained journal，并按原顺序交付各项结果。
  // 输入/输出及副作用：record/preallocated 为 engine-owned 行的非拥有引用；recovery_stage 为调用期
  //  descriptor/observer；results 为已对齐数组，原位更新；推进 counter/行，transport 可能等待或产生
  //  Host/MMIO 副作用；不取放锁，调用方全程持锁。
  // 失败/边界：仅接受已完成全部准入与 stale 重验的非空参数；null/畸形 envelope、无 arm 的 MMIO 自报、
  //  arm/effect 矛盾及 classifier 失败均保守记录且不撤销 attempt；未 arm 的 PRE 不清 journal；真实 arm
  //  的累计输入读回调后的 record，未 arm 用发布前 prior_cumulative。
  protected task publish_recovery_retry_locked(
    input rdma_cmq_batch_submission_record record,
    input rdma_cmq_preallocated_publish_batch preallocated,
    input rdma_cmq_recovery_candidate_stage_t recovery_stage,
    input longint unsigned candidate_attempt,
    input rdma_cmq_execution_result results[]
  );
    rdma_doorbell_submission_result transport_result;
    rdma_status nested_status;
    rdma_status operation_status;
    rdma_status_code_e observation_code;
    rdma_submission_effect_e prior_cumulative;
    rdma_submission_effect_e current_attempt_effect;
    rdma_submission_effect_e cumulative_effect;
    rdma_submission_effect_e fold_evidence;
    string observation_message;
    bit observer_armed;
    bit retry_safe;
    bit classified_recovery;

    prior_cumulative = record.submission_effect;
    attempt_id_counter = candidate_attempt;
    record.attempt_id = candidate_attempt;
    record.state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
    record.attempt_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
    record.observer_armed = 1'b0;
    record.publication_retry_safe = 1'b0;
    preallocated.attempt_id = candidate_attempt;
    foreach (record.items[i]) begin
      record.items[i].state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
      record.items[i].attempt_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      record.items[i].completion_phase = RDMA_CMQ_COMPLETION_NONE;
      record.items[i].completion = null;
      record.items[i].reset_isolation_confirmed = 1'b0;
      record.items[i].recovery_required = 1'b1;
      record.items[i].status = rdma_cmq_direct_status(RDMA_SC_OK);
      results[i].attempt_id = candidate_attempt;
      results[i].submission_effect = prior_cumulative;
      results[i].attempt_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      results[i].completion_phase = RDMA_CMQ_COMPLETION_NONE;
      results[i].recovery_required = 1'b1;
    end
    arm_observers[recovery_stage.capability_key] =
      recovery_stage.observer;

    transport_result = null;
    transport.submit_observed(
      record.binding, recovery_stage.doorbell_snapshot_desc,
      recovery_stage.observer, transport_result
    );
    observer_armed = record.observer_armed;
    if (!observer_armed)
      arm_observers.delete(recovery_stage.capability_key);

    decode_transport_envelope(
      transport_result, 1'b1, operation_status, observation_code,
      observation_message, current_attempt_effect
    );

    retry_safe = 1'b1;
    if (observer_armed) begin
      record.publication_retry_safe = 1'b0;
      if (current_attempt_effect == RDMA_SUBMIT_EFFECT_MMIO_VISIBLE) begin
        record.state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
        fold_evidence = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
      end
      else begin
        record.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
        fold_evidence = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
        if (current_attempt_effect !=
              RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE &&
            current_attempt_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED) begin
          current_attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
          observation_code = RDMA_SC_INVALID_STATE;
          observation_message =
            "CMQ recovery transport effect contradicts authentic MMIO arm";
        end
      end
      if (!rdma_cmq_fold_attempt_effect(
            record.submission_effect, fold_evidence, cumulative_effect
          ))
        cumulative_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
    end
    else begin
      record.state = RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
      if (!(current_attempt_effect inside {
            RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
            RDMA_SUBMIT_EFFECT_UNOBSERVED,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
          })) begin
        current_attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        retry_safe = 1'b0;
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message =
          "CMQ recovery transport reported MMIO without authentic arm";
      end
      if (!rdma_cmq_fold_attempt_effect(
            prior_cumulative, current_attempt_effect, cumulative_effect
          ))
        cumulative_effect = prior_cumulative;
      record.publication_retry_safe = retry_safe;
    end
    record.submission_effect = cumulative_effect;
    record.attempt_effect = current_attempt_effect;

    foreach (record.items[i]) begin
      record.items[i].state = record.state;
      record.items[i].submission_effect = cumulative_effect;
      record.items[i].attempt_effect = current_attempt_effect;
      record.items[i].completion_phase = observer_armed ?
        RDMA_CMQ_COMPLETION_PENDING : RDMA_CMQ_COMPLETION_NONE;
      record.items[i].status = copy_submit_status_direct(
        operation_status, $sformatf("cmq_recovery_journal_status_%0d", i)
      );
      nested_status = rdma_cmq_classify_recovery_required(
        record.items[i].state, record.items[i].completion_phase,
        record.items[i].submission_effect,
        record.items[i].reset_isolation_confirmed,
        record.items[i].recovery_owner.is_legacy_unmigrated(),
        classified_recovery
      );
      if (nested_status == null || !nested_status.ok()) begin
        classified_recovery = 1'b1;
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message = (nested_status == null) ?
          "CMQ recovery classifier returned null status" :
          nested_status.message;
      end
      record.items[i].recovery_required = classified_recovery;
      results[i].status = copy_submit_status_direct(
        operation_status, $sformatf("cmq_recovery_result_status_%0d", i)
      );
      results[i].observation_status = rdma_cmq_direct_status(
        observation_code, observation_message
      );
      results[i].submission_effect = cumulative_effect;
      results[i].attempt_effect = current_attempt_effect;
      results[i].completion_phase = record.items[i].completion_phase;
      results[i].attempt_id = candidate_attempt;
      results[i].recovery_required = classified_recovery;
    end
  endtask

  // 设计说明：恢复入口在同一 engine_lock 内完成 locate、双图重算、完整值认证、candidate staging、
  //  唯一 CAS 与 transport；第二个相同 expected attempt 只能在首个释放锁后观察新 attempt 并以 stale 结束。
  // 功能：对 fenced submission 执行 RETRY_PUBLISH，或消费 READY reset proof 完成 CONFIRM_RESET_ISOLATION；
  //  CONFIRM 重验 proof-to-row tuple 与 RESET_QUARANTINED/RESET_CANCELLED 生命周期。
  // 输入/输出及副作用：request 为 detached 图；results/status 入口即初始化。RETRY CAS 成功后推进一次 attempt、
  //  登记 observer、可能写 Host/MMIO；CONFIRM 不分配 attempt、不做 I/O，重验后才更新 confirmation/
  //  recovery bit。双图认证与 CONFIRM 重验借给只读 helper，attempt 重验与提交留在此。结构对齐后所有
  //  拒绝汇合到同一回填/解锁出口，两条成功路径各自返回。
  // 失败/边界：无法 locate/对齐返回空 results；之后 stale/action/digest/owner/proof/binding/mapping/fence/
  //  deadline/staging/collision 失败返回 aligned results，唯一 CAS 前不改 counter、journal、observer 或 I/O；
  //  stale 的 journal_status 直接构造，统一出口取 status.message，与三处固定文本一致。
  task recover_submission_observed(
    input rdma_cmq_submission_recovery_request request,
    output rdma_cmq_execution_result results[],
    output rdma_status status
  );
    rdma_cmq_batch_submission_record record;
    rdma_cmq_preallocated_publish_batch preallocated;
    rdma_cmq_recovery_candidate_stage_t recovery_stage;
    rdma_cmq_hw_profile profile_service;
    rdma_status stage_status;
    rdma_status owner_status;
    longint unsigned candidate_attempt;
    bit owner_rejected;

    results = new[0];
    status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ recovery did not complete"
    );

    engine_lock.get(1);
    status = reset_release_gate_status();
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (request == null ||
        request.get_object_type() !=
          rdma_cmq_submission_recovery_request::get_type() ||
        request.batch_key.len() == 0 ||
        !submission_journal.exists(request.batch_key)) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request does not locate a retained batch"
      );
      engine_lock.put(1);
      return;
    end
    record = submission_journal[request.batch_key];
    if (record == null || record.batch_key != request.batch_key ||
        request.batch_id == 0 || request.batch_id != record.batch_id ||
        request.expected_function_identity == null ||
        record.function_identity == null ||
        !request.expected_function_identity.same_incarnation(
          record.function_identity
        ) || request.items.size() == 0 ||
        request.items.size() != record.items.size()) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request does not structurally match the retained batch"
      );
      engine_lock.put(1);
      return;
    end
    foreach (request.items[i]) begin
      if (request.items[i] == null || record.items[i] == null ||
          request.items[i].ticket == null || record.items[i].ticket == null ||
          request.items[i].request_index != record.items[i].request_index) begin
        status = journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery item cardinality or order does not match"
        );
        engine_lock.put(1);
        return;
      end
    end

    // // 单次循环只统一对齐后的失败出口；CONFIRM/RETRY 成功各自解锁返回，不能仅凭 status.ok() 判断
    // // （mapping snapshot 的 OK/null 拒绝也须回填）；用 break 而非命名块 disable，避免干扰其它调用。
    do begin : recovery_transaction
      stage_status = stage_recovery_results_locked(request, record, results);
      if (stage_status == null || !stage_status.ok()) begin
        status = (stage_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery result staging returned null status"
        ) : journal_status(stage_status.code, stage_status.message);
        break;
      end
      if (request.expected_attempt_id != record.attempt_id) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE, "stale CMQ recovery attempt"
        );
        break;
      end
      if ($isunknown(request.action) ||
          !(request.action inside {RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
                                   RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION})) begin
        status = journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery action is invalid or unsupported"
        );
        break;
      end
      if (!journal_profile_by_batch.exists(record.batch_key) ||
          journal_profile_by_batch[record.batch_key] == null) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery retained profile authority is missing"
        );
        break;
      end
      profile_service = journal_profile_by_batch[record.batch_key];

      status = authenticate_recovery_graphs_locked(
        request, record, profile_service
      );
      if (status == null || !status.ok()) begin
        if (status == null)
          status = journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ recovery graph authentication returned null status"
          );
        break;
      end

      owner_rejected = 1'b0;
      foreach (request.items[i]) begin
        // 设计说明：CONFIRM 跳过已确认或无需恢复的项，只认证剩余项的 frozen owner 与 action 权限；RETRY
        //  不跳过任何项；legacy sentinel 不提供具体恢复授权，不能替代未解决 workflow 的 owner 证据。
        if (request.action == RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION &&
            (record.items[i].reset_isolation_confirmed ||
             !record.items[i].recovery_required))
          continue;
        owner_status = record.items[i].recovery_owner.validate_frozen(
          record.function_identity,
          record.items[i].recovery_owner.admission_attempt_id
        );
        if (owner_status != null && owner_status.ok())
          owner_status = request.items[i].recovery_owner.validate_frozen(
            record.function_identity,
            record.items[i].recovery_owner.admission_attempt_id
          );
        if (owner_status == null || !owner_status.ok() ||
            !record.items[i].recovery_owner.permits(request.action) ||
            !request.items[i].recovery_owner.permits(request.action)) begin
          status = (owner_status == null || owner_status.ok()) ?
            journal_status(
              RDMA_SC_INVALID_ARGUMENT,
              "CMQ recovery owner does not authorize this action"
            ) : journal_status(owner_status.code, owner_status.message);
          owner_rejected = 1'b1;
          break;
        end
      end

      if (owner_rejected)
        break;

      if (request.action == RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION) begin
        status = validate_reset_confirmation_locked(
          request, record, profile_service
        );
        if (status == null || !status.ok()) begin
          if (status == null)
            status = journal_status(
              RDMA_SC_INVALID_STATE,
              "CMQ reset confirmation validation returned null status"
            );
          break;
        end
        if (request.expected_attempt_id != record.attempt_id) begin
          status = journal_status(
            RDMA_SC_INVALID_STATE, "stale CMQ recovery attempt"
          );
          break;
        end

        foreach (record.items[i]) begin
          if (!record.items[i].recovery_owner.is_legacy_unmigrated() &&
              !record.items[i].reset_isolation_confirmed &&
              record.items[i].recovery_required) begin
            record.items[i].reset_isolation_confirmed = 1'b1;
            record.items[i].recovery_required = 1'b0;
          end
          results[i].status = rdma_cmq_direct_status(RDMA_SC_OK);
          results[i].observation_status = rdma_cmq_direct_status(RDMA_SC_OK);
          results[i].submission_effect = record.items[i].submission_effect;
          results[i].attempt_effect = record.items[i].attempt_effect;
          results[i].completion_phase = record.items[i].completion_phase;
          results[i].attempt_id = record.attempt_id;
          results[i].recovery_required = record.items[i].recovery_required;
        end
        status = journal_status(RDMA_SC_OK);
        engine_lock.put(1);
        return;
      end

      if (!admit_retry_live_authority_locked(
            request, record, profile_service, preallocated, status
          )) begin
        break;
      end
      if (attempt_id_counter == 64'hffff_ffff_ffff_ffff) begin
        status = journal_status(
          RDMA_SC_RESOURCE_EXHAUSTED, "CMQ attempt IDs are exhausted"
        );
        break;
      end
      candidate_attempt = attempt_id_counter + 1'b1;

      if (!stage_recovery_candidate_locked(
            record, candidate_attempt, recovery_stage, status
          )) begin
        break;
      end

      // // 所有可失败 staging 已完成；最终 stale 重验与提交阶段间无 factory/adapter 回调或锁释放，
      // // owner provenance 与 absolute deadline 不变。
      if (request.expected_attempt_id != record.attempt_id) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE, "stale CMQ recovery attempt"
        );
        break;
      end
      publish_recovery_retry_locked(
        record, preallocated, recovery_stage, candidate_attempt, results
      );
      status = journal_status(RDMA_SC_OK);
      engine_lock.put(1);
      return;
    end while (1'b0);

    reject_recovery_results_locked(results, status.code, status.message);
    engine_lock.put(1);
  endtask

  // 功能：执行单条 command 的 observed 生命周期，提交后按锁内 retained 行选择立即观测或等待精确 pending 项。
  // 输入/输出及副作用：command 只读，result 为 caller-owned detached 图；submit_observed 仅调用一次，
  //  armed pending 才在锁外 wait_for；锁内选择 observation code/message 并复制 journal。
  // 失败/边界：零 identity envelope 降为 UNOBSERVED；缺行、身份/生命周期损坏或快照失败回退 submitted 并报
  //  INVALID_STATE；STAGED/PENDING_EFFECT 立即返回未决观测；wait 后缺终态不伪造 completion。
  task execute_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
    rdma_cmq_execution_result submitted;
    rdma_cmq_batch_submission_record batch_record;
    rdma_cmq_batch_submission_item_record journal_item;
    rdma_cmq_completion waited_completion;
    rdma_status waited_status;
    rdma_status lookup_status;
    rdma_status snapshot_status;
    rdma_status identity_status;
    rdma_status_code_e observation_code;
    string observation_message;
    string snapshot_failure_message;
    int unsigned item_index;
    bit armed_pending;

    result = new_submit_result_direct("cmq_execute_observed_fallback");
    submit_observed(command, submitted);
    if (submitted == null) begin
      result.status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ observed submit returned null result"
      );
      result.observation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ observed submit returned null result"
      );
      result.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      result.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      result.completion_phase = RDMA_CMQ_COMPLETION_UNOBSERVED;
      result.recovery_required = 1'b1;
      return;
    end

    // // 只有完整的零 identity PRE_SUBMIT_REJECTED/NONE envelope 才可直接返回；缺 identity 却宣称已提交的
    // // delegated submit 须转为 UNOBSERVED。
    if (submitted.ticket == null || submitted.batch_key.len() == 0) begin
      if (submitted.ticket == null && submitted.completion == null &&
          submitted.command_identity == null &&
          submitted.recovery_owner == null && submitted.dma_context == null &&
          submitted.batch_key.len() == 0 && submitted.batch_id == 0 &&
          submitted.attempt_id == 0 &&
          submitted.completion_phase == RDMA_CMQ_COMPLETION_NONE &&
          submitted.submission_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED &&
          submitted.attempt_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED &&
          submitted.recovery_required == 1'b0 && submitted.status != null &&
          submitted.observation_status != null &&
          rdma_cmq_status_shape_valid(submitted.status) &&
          rdma_cmq_status_shape_valid(submitted.observation_status) &&
          submitted.status.code != RDMA_SC_OK &&
          submitted.observation_status.code == RDMA_SC_OK)
        result = submitted;
      else begin
        result = submitted;
        result.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        result.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        result.completion_phase = RDMA_CMQ_COMPLETION_UNOBSERVED;
        result.recovery_required = 1'b1;
        result.observation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ observed submit returned malformed zero-identity envelope"
        );
      end
      return;
    end

    engine_lock.get(1);
    lookup_status = locate_journal_item_by_ticket_locked(
      submitted.ticket, batch_record, journal_item, item_index
    );
    if (lookup_status == null || !lookup_status.ok() ||
        batch_record == null || journal_item == null) begin
      engine_lock.put(1);
      result = submitted;
      result.observation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ observed journal lookup failed"
      );
      return;
    end
    identity_status = validate_observed_item_locked(
      submitted, batch_record, journal_item
    );
    if (identity_status == null || !identity_status.ok()) begin
      result = submitted;
      result.observation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        (identity_status == null) ?
          "CMQ observed journal validation returned null status" :
          identity_status.message
      );
      engine_lock.put(1);
      return;
    end

    // // 生命周期分支只决定观测诊断，快照与失败回退只在末尾执行一次；仅 armed pending 分支可释放锁等待，
    // // 重新取锁后按同一 ticket 重定位，不沿用 wait 返回的临时 completion。
    if (journal_item.state inside {
          RDMA_CMQ_SUBMISSION_STAGED,
          RDMA_CMQ_SUBMISSION_PENDING_EFFECT
        }) begin
      observation_code = RDMA_SC_INVALID_STATE;
      observation_message = "CMQ observed item has pending external effect";
      snapshot_failure_message = "CMQ observed pending item snapshot returned null status";
    end
    else if (journal_item.state == RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED) begin
      if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
          journal_item.completion != null) begin
        result = submitted;
        result.observation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ observed host-visible item has terminal evidence"
        );
        engine_lock.put(1);
        return;
      end
      observation_code = RDMA_SC_OK;
      observation_message = "CMQ retained host-visible journal observed";
      snapshot_failure_message = "CMQ retained host-visible snapshot returned null status";
    end
    else if (journal_item.completion != null &&
             rdma_cmq_completion_phase_has_terminal_evidence(
               journal_item.completion_phase
             )) begin
      observation_code = RDMA_SC_OK;
      observation_message = "CMQ retained journal completion observed";
      snapshot_failure_message = "CMQ retained completion snapshot returned null status";
    end
    else begin
      armed_pending = journal_item.state inside {
        RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
        RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
      } && journal_item.completion_phase == RDMA_CMQ_COMPLETION_PENDING;
      engine_lock.put(1);
      if (!armed_pending) begin
        result = submitted;
        result.observation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, "CMQ observed journal lifecycle is malformed"
        );
        return;
      end

      waited_completion = null;
      waited_status = null;
      wait_for(submitted.ticket, waited_completion, waited_status);
      engine_lock.get(1);
      lookup_status = locate_journal_item_by_ticket_locked(
        submitted.ticket, batch_record, journal_item, item_index
      );
      if (lookup_status != null && lookup_status.ok() &&
          journal_item != null && journal_item.completion != null &&
          rdma_cmq_completion_phase_has_terminal_evidence(
            journal_item.completion_phase
          )) begin
        observation_code = RDMA_SC_OK;
        observation_message = "CMQ retained journal completion observed after wait";
        snapshot_failure_message = "CMQ retained completion snapshot returned null status";
      end
      else begin
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message = "CMQ observed wait produced no retained completion";
        snapshot_failure_message = "CMQ observed wait produced no retained snapshot";
      end
    end

    // // 仅 wait 后重定位失败可能无 item，此时不调 builder；失败只替换 submitted 的 observation status。
    snapshot_status = (journal_item == null) ? null :
      build_observed_result_locked(
        batch_record, journal_item, observation_code, observation_message, result
      );
    if (snapshot_status == null || !snapshot_status.ok()) begin
      result = submitted;
      result.observation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        (snapshot_status == null) ? snapshot_failure_message : snapshot_status.message
      );
    end
    engine_lock.put(1);
  endtask

  // 功能：把一个 command 包装为恰好一次 observed batch 调用并返回其唯一结果。
  // 输入/输出及副作用：command 输入，result 输出；副作用全部来自 submit_batch_observed。
  // 失败/边界：batch 返回错位/null 结果时发布非空 INVALID_STATE fallback；不二次提交。
  virtual task submit_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
    rdma_cmq_command_desc commands[];
    rdma_cmq_execution_result results[];
    rdma_status batch_status;

    result = new_submit_result_direct("cmq_single_observed_fallback");
    commands = new[1];
    commands[0] = command;
    submit_batch_observed(commands, results, batch_status);
    if (results.size() != 1 || results[0] == null) begin
      result.status = (batch_status == null) ? rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ one-item observed batch returned no result"
      ) : copy_submit_status_direct(
        batch_status, "cmq_single_observed_batch_status"
      );
      result.observation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ one-item observed batch returned no result"
      );
      result.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      result.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      result.completion_phase = RDMA_CMQ_COMPLETION_UNOBSERVED;
      result.recovery_required = 1'b1;
      return;
    end
    result = results[0];
  endtask

  // 功能：把 observed batch 的 ticket/operation status 单向投影到 legacy 输出。
  // 输入/输出及副作用：requests 输入；tickets/item_statuses 与请求等长；batch_status 承接 observed 状态。
  // 失败/边界：result/ticket/status 形状异常时该项返回 INVALID_STATE 与 null ticket；不重试。
  task submit_batch(
    input rdma_cmq_command_desc requests[],
    output rdma_cmq_ticket tickets[],
    output rdma_status item_statuses[],
    output rdma_status batch_status
  );
    rdma_cmq_execution_result observed_results[];

    submit_batch_observed(requests, observed_results, batch_status);
    tickets = new[requests.size()];
    item_statuses = new[requests.size()];
    foreach (tickets[i]) begin
      rdma_cmq_nonfatal_snapshot_context snapshot_context;
      string failure_reason;

      tickets[i] = null;
      item_statuses[i] = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ legacy batch observed result is missing"
      );
      if (i >= observed_results.size() || observed_results[i] == null)
        continue;
      item_statuses[i] = copy_submit_status_direct(
        observed_results[i].status,
        $sformatf("cmq_legacy_item_status_%0d", i)
      );
      snapshot_context = new();
      if (!snapshot_context.try_snapshot_optional_ticket(
            observed_results[i].ticket, tickets[i], failure_reason
          )) begin
        tickets[i] = null;
        item_statuses[i] = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          {"CMQ legacy ticket projection failed: ", failure_reason}
        );
      end
    end
    if (batch_status == null)
      batch_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed batch returned null orchestration status"
      );
  endtask

  // 功能：把单条 observed result 单向投影为 legacy ticket/status。
  // 输入/输出及副作用：request 输入；ticket/status 为 detached 输出；submit_observed 仅调用一次。
  // 失败/边界：result/status/ticket snapshot 异常时返回 null ticket 与独立 INVALID_STATE；
  //  operation failure 原样返回。
  task submit(
    input rdma_cmq_command_desc request,
    output rdma_cmq_ticket ticket,
    output rdma_status status
  );
    rdma_cmq_execution_result observed_result;
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    string failure_reason;

    ticket = null;
    status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ legacy submit did not complete"
    );
    submit_observed(request, observed_result);
    if (observed_result == null) begin
      status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ observed submit returned null result"
      );
      return;
    end
    status = copy_submit_status_direct(
      observed_result.status, "cmq_legacy_submit_status"
    );
    snapshot_context = new();
    if (!snapshot_context.try_snapshot_optional_ticket(
          observed_result.ticket, ticket, failure_reason
        )) begin
      ticket = null;
      status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        {"CMQ legacy submit ticket projection failed: ", failure_reason}
      );
    end
  endtask

  // 功能：把已过期的 PUBLISHED slot 转为 timeout completion 并交付。
  // 输入/输出及副作用：completions 先清空后输出；status 输出结果；持 engine_lock，经 expire_locked 修改状态。
  // 失败/边界：reset release gate 阻断或 expire_locked 失败时经 status 报告，不隐式重试。
  task expire(
    output rdma_cmq_completion completions[$],
    output rdma_status status
  );
    completions.delete();
    status = invalid_state("CMQ expire did not complete");
    engine_lock.get(1);
    status = reset_release_gate_status();
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ expire requires an ACTIVE engine");
      engine_lock.put(1);
      return;
    end
    status = expire_locked();
    while (terminal_fifo.size() != 0)
      completions.push_back(terminal_fifo.pop_front());
    engine_lock.put(1);
  endtask

  // 设计说明：CQE 经 owner、opcode、token、locator 与 prospective-retire 校验后，正常完成与超时晚到完成
  //  仅在交付种类与 slot 终态上分叉；journal transition 与 FIFO/registry/token 提交由锁内唯一阶段按序完成。
  // 功能：把已构造的正常或 late completion 写入 retained journal item，统一执行 transition staging 与 commit。
  // 输入/输出及副作用：record/completion/target_state/target_phase/transition_name 为锁内已认证输入；
  //  只更新 journal 的 completion/state/phase/recovery 字段，不碰 FIFO/registry/token/slot。
  // 失败/边界：输入不完整、前驱 lifecycle 不符、snapshot 或 reducer 失败返回非 OK 且不发布部分状态；
  //  成功后调用方仍须按序发布 FIFO、释放 token、推进 slot。
  protected function rdma_status commit_polled_journal_transition_locked(
    input rdma_cmq_slot_record record,
    input rdma_cmq_completion completion,
    input rdma_cmq_submission_state_e target_state,
    input rdma_cmq_completion_phase_e target_phase,
    input string transition_name
  );
    rdma_cmq_batch_submission_record journal_batch;
    rdma_cmq_batch_submission_item_record journal_item;
    rdma_cmq_completion journal_completion;
    rdma_cmq_submission_state_e reduced_batch_state;
    rdma_status status;
    bit recovery_required;

    if (record == null || completion == null || transition_name.len() == 0)
      return invalid_state(
        "CMQ polled journal transition authority is incomplete"
      );
    status = stage_runtime_journal_transition_locked(
      record, completion, target_state, target_phase, journal_batch,
      journal_item, journal_completion, recovery_required, reduced_batch_state
    );
    if (status == null || !status.ok())
      return (status == null) ? invalid_state(
        {"CMQ ", transition_name,
         " journal staging returned null status"}
      ) : status;
    commit_runtime_journal_transition_locked(
      journal_batch, journal_item, journal_completion, target_state,
      target_phase, recovery_required, reduced_batch_state
    );
    return rdma_status::success();
  endfunction

  // 设计说明：正常与 late 共用 completion 构造与 journal 提交，仅 late 先构造 diagnostic；late 在原分支点冻结，
  //  不得在 factory/profile 回调后重读 record.state 改变交付种类；journal 成功后才发布 FIFO 并释放 token。
  // 功能：提交已校验的 CQE：PUBLISHED row 构造 terminal completion，TIMED_OUT_QUARANTINED row 构造 late
  //  diagnostic/completion，并把 journal、FIFO、registry、token、slot 状态原子推进到原有终态。
  // 输入/输出及副作用：record/raw_snapshot/decoded/software_key/token_index 为锁内已认证输入；读写 journal、
  //  terminal/diagnostic/late FIFO、command_registry、token_in_use、record.state；返回独立 status。
  // 失败/边界：构造、journal staging 或 reducer 失败时不 commit，调用方不得推进 cq_consume_seq；
  //  成功时保持 journal -> FIFO -> registry/token -> slot 终态的提交顺序。
  protected function rdma_status commit_polled_completion_locked(
    rdma_cmq_slot_record record,
    rdma_hw_image raw_snapshot,
    rdma_cmq_decoded_cqe decoded,
    string software_key,
    int unsigned token_index
  );
    rdma_status completion_status;
    rdma_status diagnostic_status;
    rdma_cmq_completion completion;
    rdma_cmq_diagnostic diagnostic;
    bit late;
    string transition_name;

    completion = null;
    diagnostic = null;
    if (record == null || raw_snapshot == null || decoded == null ||
        software_key.len() == 0 || token_index >= CMQ_DEPTH)
      return invalid_state("CMQ polled completion commit authority is incomplete");
    if (!(record.state inside {
            CMQ_SLOT_PUBLISHED,
            CMQ_SLOT_TIMED_OUT_QUARANTINED
          }))
      return invalid_state("CMQ polled completion slot state is not terminal");

    late = record.state != CMQ_SLOT_PUBLISHED;
    transition_name = late ? "late completion" : "normal completion";
    if (late) begin
      diagnostic_status = make_late_diagnostic(
        record, raw_snapshot, diagnostic
      );
      if (diagnostic_status == null || !diagnostic_status.ok() ||
          diagnostic == null)
        return (diagnostic_status == null) ? invalid_state(
          "CMQ late diagnostic returned null status"
        ) : diagnostic_status;
    end
    completion_status = make_polled_completion(
      record, raw_snapshot, decoded, completion
    );
    if (completion_status == null || !completion_status.ok() ||
        completion == null)
      return (completion_status == null) ? invalid_state(
        late ? "CMQ late final completion construction returned null status" :
               "CMQ completion construction returned null status"
      ) : completion_status;
    completion_status = commit_polled_journal_transition_locked(
      record, completion,
      late ? RDMA_CMQ_SUBMISSION_LATE_COMPLETED : RDMA_CMQ_SUBMISSION_COMPLETED,
      late ? RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY : RDMA_CMQ_COMPLETION_TERMINAL,
      transition_name
    );
    if (completion_status == null || !completion_status.ok())
      return (completion_status == null) ? invalid_state(
        {"CMQ ", transition_name, " journal commit returned null status"}
      ) : completion_status;
    if (late) begin
      diagnostic_fifo.push_back(diagnostic);
      late_final_fifo.push_back(completion);
    end
    else begin
      terminal_fifo.push_back(completion);
      command_registry.delete(software_key);
    end
    token_in_use[token_index] = 1'b0;
    record.state = late ? CMQ_SLOT_LATE_COMPLETED : CMQ_SLOT_COMPLETED;
    return rdma_status::success();
  endfunction

  // 设计说明：完成事务分为 CQ 读取/解码、命令匹配、journal/交付提交与连续前缀回收，均在同一 engine_lock
  //  下执行；读取失败与未就绪不得进入账本提交。
  // 功能：读取 cq_consume_seq 对应的 64B CQE，并让 profile 按预期 owner 解码。
  // 输入/输出及副作用：raw_snapshot 输出独立证据，decoded 输出解码结果，ready 仅在检查通过且 CQE 就绪时为 1；
  //  只访问 Host-memory 与 profile，不推进 ring；畸形解码经 poison 隔离并可能发布诊断。
  // 失败/边界：几何/read/snapshot 失败直接返回；先查 profile 未改写 raw，再查 inspect status；null、
  //  CODEC_ERROR、UNSUPPORTED_OPCODE 走 poison，其它失败复制原状态，not-ready 返回 OK；caller 按 ready 判断。
  protected task read_polled_cqe_locked(
    output rdma_hw_image raw_snapshot,
    output rdma_cmq_decoded_cqe decoded,
    output bit ready,
    output rdma_status status
  );
    byte data[];
    rdma_status read_status;
    rdma_status inspect_status;
    rdma_hw_image raw_cqe;
    longint unsigned read_offset;
    rdma_cmq_ring_position_t cq_position;
    int unsigned cq_index;
    bit expected_owner;
    bit inspected_ready;

    ready = 1'b0;
    if (!rdma_cmq_ring_position_for_sequence(
          cq_consume_seq, CMQ_DEPTH, cq_position
        ) || !rdma_cmq_cq_owner_for_sequence(
          cq_consume_seq, CMQ_DEPTH, expected_owner
        )) begin
      status = invalid_state(
        "CMQ CQ consumer sequence cannot be mapped to ring geometry"
      );
      return;
    end
    cq_index = cq_position.index;
    read_offset = CQ_OFFSET + (longint'(cq_index) * CMQE_BYTES);
    data = new[0];
    read_status = host_mem.read(
      backing_mapping, read_offset, CMQE_BYTES, data
    );
    if (read_status == null) begin
      status = invalid_state("CMQ CQ backing read returned null status");
      return;
    end
    if (!read_status.ok()) begin
      status = rdma_cmq_clone_status_value(read_status);
      return;
    end
    status = make_raw_cqe_image(data, raw_cqe);
    if (!status.ok())
      return;
    status = rdma_cmq_checked_image_snapshot(
      raw_cqe, "CMQ CQE inspection", RDMA_SC_INVALID_STATE,
      raw_snapshot
    );
    if (!status.ok())
      return;
    inspected_ready = 1'b0;
    decoded = null;
    inspect_status = profile.inspect_cqe(
      raw_cqe, expected_owner, inspected_ready, decoded
    );
    if (!same_image_value(raw_cqe, raw_snapshot)) begin
      status = invalid_state("CMQ profile changed its raw CQE input");
      return;
    end
    if (inspect_status == null) begin
      status = poison(
        RDMA_CMQ_DIAG_MALFORMED_CQE,
        "CMQ profile inspection returned null status", raw_snapshot
      );
      return;
    end
    if (!inspect_status.ok()) begin
      if (inspect_status.code inside {
            RDMA_SC_CODEC_ERROR, RDMA_SC_UNSUPPORTED_OPCODE
          })
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          inspect_status.message, raw_snapshot
        );
      else
        status = rdma_cmq_clone_status_value(inspect_status);
      return;
    end
    if (!inspected_ready) begin
      status = rdma_status::success();
      return;
    end
    ready = 1'b1;
  endtask

  // 功能：把 ready CQE 与 exact slot/entry/command/token 匹配，并预验连续可回收前缀。
  // 输入/输出及副作用：raw_snapshot/decoded 为非拥有输入；stage 仅成功时交付 record、software_key、
  //  token_index、retire_seq；返回是否匹配；正常路径只读，失败可调用 poison。
  // 失败/边界：index、entry/slot/ticket、status/opcode、counter、registry、token incarnation 或 prospective
  //  retirement 不符时按原优先级拒绝，不写 journal/FIFO、不释放 token；仅限持锁 ready 路径调用。
  protected function bit match_polled_cqe_locked(
    input rdma_hw_image raw_snapshot,
    input rdma_cmq_decoded_cqe decoded,
    output rdma_cmq_polled_completion_stage_t stage,
    output rdma_status status
  );
    rdma_status validation_status;
    rdma_status retirement_status;
    rdma_cmq_slot_record record;
    string hardware_key;
    string software_key;
    int unsigned token_index;
    longint unsigned prospective_retire_seq;
    bit late;

    if (decoded == null || decoded.wqe_index >= CMQ_DEPTH) begin
      status = poison(
        RDMA_CMQ_DIAG_MALFORMED_CQE,
        "CMQ profile returned an invalid decoded CQE", raw_snapshot
      );
      return 1'b0;
    end

    hardware_key = entry_key(decoded.wqe_index, decoded.wqe_wrap);
    if (!entry_registry.exists(hardware_key)) begin
      status = poison(
        RDMA_CMQ_DIAG_UNKNOWN_CQE,
        "CMQ decoded CQE has no registered entry", raw_snapshot
      );
      return 1'b0;
    end
    record = entry_registry[hardware_key];
    if (record == null || slots[decoded.wqe_index] == null ||
        slots[decoded.wqe_index] != record ||
        record.sq_index != decoded.wqe_index ||
        record.sq_wrap != decoded.wqe_wrap ||
        record.ticket == null || record.expected == null ||
        record.ticket.sq_index != record.sq_index ||
        record.ticket.sq_wrap != record.sq_wrap ||
        record.ticket.slot_sequence != record.slot_sequence ||
        record.ticket.command_id[4:0] != record.command_token ||
        !(record.state inside {
          CMQ_SLOT_PUBLISHED,
          CMQ_SLOT_TIMED_OUT_QUARANTINED
        })) begin
      status = poison(
        RDMA_CMQ_DIAG_POISON,
        "CMQ decoded CQE entry ledger is inconsistent", raw_snapshot
      );
      return 1'b0;
    end
    if (decoded.command_status == null) begin
      status = poison(
        RDMA_CMQ_DIAG_MALFORMED_CQE,
        "CMQ profile returned a null decoded command status",
        raw_snapshot, record.ticket
      );
      return 1'b0;
    end
    validation_status = decoded.validate();
    if (validation_status == null || !validation_status.ok()) begin
      status = poison(
        RDMA_CMQ_DIAG_MALFORMED_CQE,
        "CMQ decoded CQE validation failed", raw_snapshot,
        record.ticket
      );
      return 1'b0;
    end
    status = decoded_status_contract(decoded);
    if (!status.ok()) begin
      status = poison(
        RDMA_CMQ_DIAG_MALFORMED_CQE, status.message, raw_snapshot,
        record.ticket
      );
      return 1'b0;
    end
    if (record.expected.hardware_opcode != decoded.hardware_opcode) begin
      status = poison(
        RDMA_CMQ_DIAG_MALFORMED_CQE,
        "CMQ decoded CQE opcode does not match command", raw_snapshot,
        record.ticket
      );
      return 1'b0;
    end
    software_key = command_key(record.ticket);
    if (cq_consume_seq == 64'hffff_ffff_ffff_ffff) begin
      status = poison(
        RDMA_CMQ_DIAG_POISON,
        "CMQ completion consumer counter overflows", raw_snapshot,
        record.ticket
      );
      return 1'b0;
    end

    late = record.state != CMQ_SLOT_PUBLISHED;
    if (!late) begin
      if (!command_registry.exists(software_key) ||
          command_registry[software_key] != record) begin
        status = poison(
          RDMA_CMQ_DIAG_POISON,
          "CMQ decoded CQE command registry is inconsistent",
          raw_snapshot, record.ticket
        );
        return 1'b0;
      end
    end
    else if (command_registry.exists(software_key)) begin
      status = poison(
        RDMA_CMQ_DIAG_POISON,
        "CMQ quarantined command remains in the command registry",
        raw_snapshot, record.ticket
      );
      return 1'b0;
    end
    token_index = record.command_token;
    if (token_index >= CMQ_DEPTH || !token_in_use[token_index] ||
        token_incarnation[token_index] != record.ticket.command_id[63:5]) begin
      status = poison(
        RDMA_CMQ_DIAG_POISON,
        late ? "CMQ quarantined completion token incarnation is inconsistent" :
               "CMQ decoded CQE command token is inconsistent",
        raw_snapshot, record.ticket
      );
      return 1'b0;
    end
    retirement_status = prospective_retirement_status(
      record, prospective_retire_seq
    );
    if (retirement_status == null || !retirement_status.ok()) begin
      status = poison(
        RDMA_CMQ_DIAG_POISON,
        (retirement_status == null) ?
          "CMQ prospective retirement returned null status" :
          retirement_status.message,
        raw_snapshot
      );
      return 1'b0;
    end

    stage = '{record:record, software_key:software_key,
              token_index:token_index, retire_seq:prospective_retire_seq};
    return 1'b1;
  endfunction

  // 功能：按 CQ consumer 顺序执行读取、匹配、完成提交与连续 SQ 前缀回收。
  // 输入/输出及副作用：status 输出首个失败或 OK；逐项提交 journal、delivery/诊断、registry/token/slot，
  //  再推进 cq_consume_seq 与 retire_seq；持锁调用。
  // 失败/边界：非 ACTIVE、缺依赖、mapping/ledger 不符时不读 CQ；未建立格式且空账本直接成功；not-ready 正常停止；
  //  本项失败不回收且不回滚此前已完成项；poison 副作用保留。
  protected task poll_locked(output rdma_status status);
    rdma_hw_image raw_snapshot;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_polled_completion_stage_t stage;
    bit ready;
    longint unsigned ledger_used;

    status = invalid_state("CMQ poll did not complete");
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ poll requires an ACTIVE engine");
      return;
    end
    if (prepared_binding == null || backing_mapping == null ||
        host_mem == null || profile == null) begin
      status = invalid_state("CMQ ACTIVE polling authority is missing");
      return;
    end
    status = mapping_authority_status(backing_mapping, dma_context);
    if (!status.ok())
      return;
    status = poll_ledger_status(ledger_used);
    if (!status.ok())
      return;
    if (ledger_used == 0 && !profile_image_format_valid) begin
      status = rdma_status::success();
      return;
    end

    status = rdma_status::success();
    while (status.ok()) begin
      read_polled_cqe_locked(raw_snapshot, decoded, ready, status);
      if (!ready)
        break;
      if (!match_polled_cqe_locked(raw_snapshot, decoded, stage, status))
        break;
      status = commit_polled_completion_locked(
        stage.record, raw_snapshot, decoded, stage.software_key, stage.token_index
      );
      if (status == null || !status.ok()) begin
        status = (status == null) ? invalid_state(
          "CMQ polled completion commit returned null status"
        ) : status;
        break;
      end
      cq_consume_seq++;
      commit_retired_prefix(stage.retire_seq);
      if (publish_seq == retire_seq)
        break;
    end
  endtask

  // 功能：持 engine_lock，先发布过期命令，再 drain ready CQE 并交付 completion/diagnostic。
  // 输入/输出及副作用：completions/diagnostics 入口清空并消费 terminal/diagnostic FIFO；status 为 gate、expiry 或
  //  poll 的结果；清空 late_final_fifo。
  // 失败/边界：reset gate 拒绝时不消费 FIFO；非 ACTIVE 仍交付已有诊断；expiry/poll 失败仍交付已提交结果；
  //  late final 不作为普通完成输出。
  task poll(
    output rdma_cmq_completion completions[$],
    output rdma_cmq_diagnostic diagnostics[$],
    output rdma_status status
  );
    rdma_status expiry_status;

    completions.delete();
    diagnostics.delete();
    status = invalid_state("CMQ poll did not complete");
    engine_lock.get(1);
    status = reset_release_gate_status();
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ poll requires an ACTIVE engine");
      while (diagnostic_fifo.size() != 0)
        diagnostics.push_back(diagnostic_fifo.pop_front());
      late_final_fifo.delete();
      engine_lock.put(1);
      return;
    end
    expiry_status = expire_locked();
    if (expiry_status == null)
      status = invalid_state("CMQ expiry helper returned null status");
    else if (!expiry_status.ok())
      status = expiry_status;
    else begin
      poll_locked(status);
    end
    while (terminal_fifo.size() != 0)
      completions.push_back(terminal_fifo.pop_front());
    while (diagnostic_fifo.size() != 0)
      diagnostics.push_back(diagnostic_fifo.pop_front());
    late_final_fifo.delete();
    engine_lock.put(1);
  endtask

  // 设计说明：wait_for 从 retained journal 读取 terminal completion 的分支共享同一 detached snapshot 规则；
  //  仅正常 delivery 分支按 ticket 删除 terminal FIFO，reset 竞争分支不得碰 FIFO；helper 只封装值投影
  //  与可选 delivery 消费，不持锁。
  // 功能：从已定位的 retained batch/item 构造独立 completion 与 operation status，并按
  //  consume_terminal_fifo 选择性删除匹配 FIFO 行。
  // 输入/输出及副作用：batch_record/journal_item/ticket_snapshot 为锁内输入；completion/projected_status 为
  //  detached 输出；只读 retained row，最多改 terminal_fifo。
  // 失败/边界：输入为空、snapshot 或 status copy 为 null 返回 INVALID_STATE，snapshot 非 OK 原码透传；
  //  先消费 FIFO 再复制 status，copy 失败不回滚 FIFO；无匹配行仍可交付 retained completion。
  protected function rdma_status
  project_wait_retained_completion_locked(
    input rdma_cmq_batch_submission_record batch_record,
    input rdma_cmq_batch_submission_item_record journal_item,
    input rdma_cmq_ticket ticket_snapshot,
    input bit consume_terminal_fifo,
    input string status_label,
    input string copy_failure_message,
    output rdma_cmq_completion completion,
    output rdma_status projected_status
  );
    rdma_status snapshot_status;
    rdma_cmq_completion detached_completion;
    int fifo_index;

    completion = null;
    projected_status = null;
    if (batch_record == null || journal_item == null ||
        ticket_snapshot == null)
      return invalid_state("CMQ wait completion projection authority is missing");
    snapshot_status = snapshot_retained_completion_locked(
      batch_record, journal_item, detached_completion
    );
    if (snapshot_status == null || !snapshot_status.ok() ||
        detached_completion == null || detached_completion.status == null)
      return (snapshot_status == null) ? invalid_state(
        "CMQ wait retained completion snapshot returned null status"
      ) : snapshot_status;
    if (consume_terminal_fifo) begin
      fifo_index = terminal_index(ticket_snapshot);
      if (fifo_index >= 0)
        terminal_fifo.delete(fifo_index);
    end
    completion = detached_completion;
    projected_status = copy_submit_status_direct(
      detached_completion.status, status_label
    );
    if (projected_status == null)
      return invalid_state(copy_failure_message);
    return rdma_status::success();
  endfunction

  // 功能：冻结 ticket 后等待其 retained completion；仅当前 ACTIVE pending 驱动 expire/poll，已有终态立即复制，
  //  legacy 无 journal 路径保持 FIFO 单次转移。
  // 输入/输出及副作用：ticket 只读；completion/status 输出；普通 retained 交付删匹配 FIFO 行，reset 竞争分支
  //  只复制；等待以至多 1ns 步长让锁，重取锁后重验 gate/identity；所有结束共用一个最终解锁出口。
  // 失败/边界：null/坏 ticket、未发布/未决行、旧 pending、缺 legacy authority、快照或 expiry/poll 失败、让锁后
  //  身份变化均拒绝；超时须由真实 expiry 的 retained completion 交付，不凭 deadline 伪造；legacy FIFO 只消费一次。
  task wait_for(
    rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_status validation_status;
    rdma_status expiry_status;
    rdma_status poll_status;
    rdma_status projection_status;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_batch_submission_record frozen_batch;
    rdma_cmq_batch_submission_item_record frozen_item;
    rdma_cmq_batch_submission_record current_batch;
    rdma_cmq_batch_submission_item_record current_item;
    rdma_function_identity frozen_identity;
    rdma_function_identity current_identity;
    int unsigned frozen_item_index;
    int unsigned current_item_index;
    int fifo_index;
    time remaining;
    time wait_time;
    bit journal_located;
    bit fallback_outstanding;

    completion = null;
    status = invalid_state("CMQ wait did not complete");
    engine_lock.get(1);
    // // 外层只做一次准入，内层沿用真实轮询；break 只通向段后的最终解锁；put/delay/get 是唯一中途让锁点。
    do begin : wait_session
      status = reset_release_gate_status();
      if (!status.ok()) begin
        break;
      end
      if (ticket == null) begin
        status = invalid_argument("CMQ wait ticket is null");
        break;
      end
      validation_status = ticket_trust_status(ticket);
      if (validation_status == null || !validation_status.ok()) begin
        status = invalid_argument("CMQ wait ticket is invalid");
        break;
      end
      validation_status = checked_completion_ticket_snapshot(
        ticket, ticket_snapshot
      );
      if (validation_status == null || !validation_status.ok()) begin
        status = (validation_status == null) ?
          invalid_state("CMQ wait ticket snapshot returned null status") :
          validation_status;
        break;
      end

      // // 首次锁内定位须先冻结 retained row；ticket 句柄后续可被 caller 改写，waiter 只用此 canonical snapshot。
      validation_status = locate_journal_item_by_ticket_locked(
        ticket_snapshot, frozen_batch, frozen_item, frozen_item_index
      );
      journal_located = validation_status != null && validation_status.ok();
      fallback_outstanding = 1'b0;
      if (journal_located) begin
        if (frozen_batch.function_identity == null ||
            !rdma_cmq_try_snapshot_identity_direct(
              frozen_batch.function_identity, frozen_identity
            )) begin
          status = invalid_state("CMQ wait retained Function snapshot failed");
          break;
        end
        if (frozen_item == null || frozen_item.ticket == null) begin
          status = invalid_state("CMQ wait retained item is incomplete");
          break;
        end
        if (frozen_item.state inside {
              RDMA_CMQ_SUBMISSION_STAGED,
              RDMA_CMQ_SUBMISSION_PENDING_EFFECT
            }) begin
          status = invalid_state("CMQ wait ticket is not observable yet");
          break;
        end
        if (frozen_item.state == RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED) begin
          status = invalid_state("CMQ wait ticket was not published");
          break;
        end
        if (frozen_item.completion != null &&
            rdma_cmq_completion_phase_has_terminal_evidence(
              frozen_item.completion_phase
            )) begin
          // // FIFO 只维护交付次序；先从 journal 复制终态再删除匹配 FIFO 行，其它 ticket 不受影响。
          projection_status = project_wait_retained_completion_locked(
            frozen_batch, frozen_item, ticket_snapshot, 1'b1,
            "cmq_wait_terminal_status",
            "CMQ wait terminal status snapshot failed",
            completion, status
          );
          if (projection_status == null || !projection_status.ok()) begin
            status = (projection_status == null) ? invalid_state(
              "CMQ wait completion projection returned null status"
            ) : projection_status;
            break;
          end
          break;
        end
        if (!(frozen_item.state inside {
              RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
              RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
            }) || frozen_item.completion_phase !=
              RDMA_CMQ_COMPLETION_PENDING) begin
          status = invalid_state("CMQ wait retained lifecycle is not pending");
          break;
        end
        if (engine_state != RDMA_CMQ_ENGINE_ACTIVE ||
            engine_incarnation != frozen_batch.engine_incarnation) begin
          status = invalid_state("CMQ wait pending ticket belongs to old engine");
          break;
        end
      end
      else begin
        // // legacy 测试/facade 无 retained journal，只能回退到当前 ACTIVE runtime 的精确 FIFO/在途项；
        // // 不能让复位前 ticket 借新 prepare 的 backing 获得访问权。
        if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
          status = invalid_state("CMQ wait requires an ACTIVE engine");
          break;
        end
        fallback_outstanding = ticket_is_outstanding(ticket_snapshot);
        if (!fallback_outstanding && terminal_index(ticket_snapshot) < 0) begin
          status = invalid_argument("CMQ wait ticket is unknown or delivered");
          break;
        end
        if (prepared_binding == null ||
            !rdma_cmq_try_snapshot_identity_direct(
              prepared_binding.function_identity_snapshot(), frozen_identity
            )) begin
          status = invalid_state("CMQ wait Function snapshot failed");
          break;
        end
      end

      forever begin : wait_iteration
        if (journal_located) begin
          // // 每次交付或执行副作用前，都重读同一 ticket 的 retained 行。
          validation_status = locate_journal_item_by_ticket_locked(
            ticket_snapshot, current_batch, current_item, current_item_index
          );
          if (validation_status == null || !validation_status.ok() ||
              current_batch == null || current_item == null ||
              current_item_index != frozen_item_index ||
              current_batch.batch_key != frozen_batch.batch_key ||
              current_batch.engine_incarnation != frozen_batch.engine_incarnation ||
              current_batch.function_identity == null ||
              !current_batch.function_identity.same_incarnation(frozen_identity)) begin
            // // 两轮之间可能发生复位；authority 不一致时仅允许 retained reset completion 跨越该边界，不消费普通 FIFO。
            if (validation_status != null && validation_status.ok() &&
                current_item != null &&
                current_item.state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED) begin
              projection_status = project_wait_retained_completion_locked(
                current_batch, current_item, ticket_snapshot, 1'b0,
                "cmq_wait_reset_status",
                "CMQ wait reset status snapshot failed",
                completion, status
              );
              if (projection_status != null && projection_status.ok()) begin
                break;
              end
            end
            status = invalid_state("CMQ wait retained authority changed");
            break;
          end
          frozen_batch = current_batch;
          frozen_item = current_item;
          if (current_item.completion != null &&
              rdma_cmq_completion_phase_has_terminal_evidence(
                current_item.completion_phase
              )) begin
            projection_status = project_wait_retained_completion_locked(
              current_batch, current_item, ticket_snapshot, 1'b1,
              "cmq_wait_completion_status",
              "CMQ wait completion status snapshot failed",
              completion, status
            );
            if (projection_status == null || !projection_status.ok()) begin
              status = (projection_status == null) ? invalid_state(
                "CMQ wait completion projection returned null status"
              ) : projection_status;
              break;
            end
            break;
          end
          if (current_item.state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED) begin
            status = invalid_state("CMQ reset item has no retained completion");
            break;
          end
          if (!(current_item.state inside {
                RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
                RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
              }) || current_item.completion_phase !=
                RDMA_CMQ_COMPLETION_PENDING) begin
            status = invalid_state("CMQ wait pending lifecycle is invalid");
            break;
          end
          // // expiry/poll 会读 CQ backing 或提交 journal 迁移，须先重验当前 runtime 的 Function identity、
          // // incarnation 与 ticket 授权。
          current_identity = null;
          if (engine_state != RDMA_CMQ_ENGINE_ACTIVE ||
              engine_incarnation != frozen_batch.engine_incarnation ||
              prepared_binding == null ||
              !rdma_cmq_try_snapshot_identity_direct(
                prepared_binding.function_identity_snapshot(), current_identity
              ) || current_identity == null ||
              !current_identity.same_incarnation(frozen_identity) ||
              !ticket_has_engine_authority(ticket_snapshot)) begin
            status = invalid_state("CMQ wait current runtime authority changed");
            break;
          end
        end
        else if (terminal_index(ticket_snapshot) >= 0) begin
          // // legacy 无 retained 图，只转移精确匹配的 FIFO 原对象，保持历史单次消费语义。
          fifo_index = terminal_index(ticket_snapshot);
          completion = terminal_fifo[fifo_index];
          terminal_fifo.delete(fifo_index);
          if (completion == null || completion.status == null) begin
            completion = null;
            status = invalid_state("CMQ wait legacy completion is incomplete");
          end
          else
            status = copy_submit_status_direct(
              completion.status, "cmq_wait_legacy_status"
            );
          break;
        end

        expiry_status = expire_locked();
        if (expiry_status == null || !expiry_status.ok()) begin
          status = (expiry_status == null) ? invalid_state(
            "CMQ wait expiry helper returned null status"
          ) : expiry_status;
          break;
        end
        poll_status = rdma_status::success();
        poll_locked(poll_status);
        if (poll_status == null || !poll_status.ok()) begin
          status = (poll_status == null) ? invalid_state(
            "CMQ wait poll helper returned null status"
          ) : poll_status;
          break;
        end

        // // 下一轮重读 journal/FIFO，故真实到期迁移通过非空 retained TIMEOUT completion 交付，
        // // 而非仅返回超时状态。
        if ($time >= ticket_snapshot.absolute_deadline &&
            journal_located) begin
          validation_status = locate_journal_item_by_ticket_locked(
            ticket_snapshot, current_batch, current_item, current_item_index
          );
          if (validation_status != null && validation_status.ok() &&
              current_item != null && current_item.completion != null &&
              current_item.completion_phase == RDMA_CMQ_COMPLETION_TIMEOUT)
            continue;
          if (current_item != null &&
              current_item.state inside {
                RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
                RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
              }) begin
            // // owned slot 到期应由 expire_locked 完成迁移；仍 pending 说明证据缺失，必须拒绝，不制造无 completion 的超时。
            status = invalid_state("CMQ wait deadline transition is missing");
            break;
          end
        end

        if (journal_located && !ticket_is_outstanding(ticket_snapshot) &&
            terminal_index(ticket_snapshot) < 0) begin
          // // 下一轮会观察 reset/terminal 迁移；retained 证据与 runtime authority 都不存在时，报告未知或已交付。
          validation_status = locate_journal_item_by_ticket_locked(
            ticket_snapshot, current_batch, current_item, current_item_index
          );
          if (validation_status == null || !validation_status.ok() ||
              current_item == null || current_item.completion == null) begin
            status = invalid_argument("CMQ wait ticket is unknown or delivered");
            break;
          end
        end
        if ($isunknown(ticket_snapshot.absolute_deadline) ||
            ticket_snapshot.absolute_deadline == 0) begin
          status = invalid_argument("CMQ wait ticket deadline is invalid");
          break;
        end
        if ($time >= ticket_snapshot.absolute_deadline) begin
          // // 本轮 expiry 应已安装到期 completion；缺少迁移证据是状态错误，不能把 INVALID_STATE 冒充正常 timeout。
          status = invalid_state("CMQ wait deadline transition is unavailable");
          break;
        end
        remaining = ticket_snapshot.absolute_deadline - $time;
        wait_time = (remaining < 1ns) ? remaining : 1ns;
        engine_lock.put(1);
        #(wait_time);
        engine_lock.get(1);
        status = reset_release_gate_status();
        if (!status.ok()) begin
          break;
        end
        if (journal_located) begin
          validation_status = locate_journal_item_by_ticket_locked(
            ticket_snapshot, current_batch, current_item, current_item_index
          );
          if (validation_status == null || !validation_status.ok() ||
              current_batch == null || current_item == null ||
              current_item_index != frozen_item_index ||
              current_batch.batch_key != frozen_batch.batch_key ||
              current_batch.engine_incarnation != frozen_batch.engine_incarnation ||
              current_batch.function_identity == null ||
              !current_batch.function_identity.same_incarnation(frozen_identity)) begin
            status = invalid_state("CMQ wait retained authority changed after unlock");
            break;
          end
          // // 让锁后先重验 retained 身份再进入下一轮 CQ 访问；下一轮另行核对 ACTIVE runtime，两道门禁不可互相替代。
        end
        else if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
          status = invalid_state("CMQ engine changed state during wait");
          break;
        end
      end
    end while (1'b0);
    engine_lock.put(1);
  endtask

  // 设计说明：reconcile_ticket 的 pending 处理可能驱动当前 runtime；其后的状态分类只读已定位的 retained item，
  //  并对 caller 输出做 detached projection；独立出这段纯分类，使 orchestration 与 snapshot 规则各有唯一 owner。
  // 功能：按 retained item 的 lifecycle state/phase 分类 reconcile 结果，构造 operation-status 或
  //  detached terminal completion，返回 terminal_known；Host-visible/current pending 共用状态快照。
  // 输入/输出及副作用：batch_record/journal_item/pending_active 为锁内输入；terminal_known/completion/
  //  projected_status 为输出；只调受控 snapshot/copy helper，不取放锁、不推进 journal/FIFO/cursor。
  // 失败/边界：null row、STAGED/PENDING_EFFECT、phase 与 completion 组合错误或 status copy 缺失返回
  //  INVALID_STATE；嵌套 snapshot 拒绝保留原码；Host-visible/pending 的合法 operation failure 经
  //  projected_status 原样传播，不误报结构错。
  protected function rdma_status
  project_reconciled_journal_item_locked(
    input rdma_cmq_batch_submission_record batch_record,
    input rdma_cmq_batch_submission_item_record journal_item,
    input bit pending_active,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status projected_status
  );
    rdma_status snapshot_status;
    rdma_status operation_status;
    rdma_cmq_completion detached_completion;
    bit terminal_row;
    string status_snapshot_failure_message;

    terminal_known = 1'b0;
    completion = null;
    projected_status = invalid_state(
      "CMQ ticket reconcile projection did not complete"
    );
    if (journal_item == null || batch_record == null)
      return invalid_state("CMQ reconcile retained item is missing");
    if (journal_item.state inside {
          RDMA_CMQ_SUBMISSION_STAGED,
          RDMA_CMQ_SUBMISSION_PENDING_EFFECT
        })
      return invalid_state(
        "CMQ reconcile item is staged or has a pending external effect"
      );

    // // 未 arm 行不走 current pending 的 phase 门禁；先按原优先级区分，再复制同一 operation-status；
    // // 无终态时不建 completion、不消费 FIFO。
    if (journal_item.state == RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED ||
        pending_active) begin
      if (journal_item.state == RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED) begin
        if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
            journal_item.completion != null)
          return invalid_state(
            "CMQ unarmed reconcile item has terminal evidence"
          );
        status_snapshot_failure_message = "CMQ unarmed reconcile status snapshot returned null";
      end
      else begin
        if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_PENDING ||
            journal_item.completion != null ||
            !(journal_item.state inside {
              RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
              RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
            }))
          return invalid_state("CMQ reconcile pending item is malformed");
        status_snapshot_failure_message = "CMQ pending reconcile status snapshot returned null";
      end
      snapshot_status = snapshot_retained_operation_status_locked(
        journal_item, operation_status
      );
      if (snapshot_status == null || !snapshot_status.ok() ||
          operation_status == null)
        return (snapshot_status == null) ? invalid_state(
          status_snapshot_failure_message
        ) : snapshot_status;
      projected_status = operation_status;
      return rdma_status::success();
    end

    terminal_row = rdma_cmq_terminal_state_phase_valid(
      journal_item.state, journal_item.completion_phase
    );
    if (!terminal_row || journal_item.completion == null)
      return invalid_state("CMQ reconcile retained lifecycle is malformed");

    snapshot_status = snapshot_retained_completion_locked(
      batch_record, journal_item, detached_completion
    );
    if (snapshot_status == null || !snapshot_status.ok() ||
        detached_completion == null || detached_completion.status == null)
      return (snapshot_status == null) ? invalid_state(
        "CMQ reconcile retained completion snapshot returned null"
      ) : snapshot_status;
    operation_status = copy_submit_status_direct(
      detached_completion.status, "cmq_reconcile_terminal_status"
    );
    if (operation_status == null)
      return invalid_state("CMQ reconcile terminal status snapshot failed");
    terminal_known = 1'b1;
    completion = detached_completion;
    projected_status = operation_status;
    return rdma_status::success();
  endfunction

  // 功能：以 retained journal 单项生命周期为唯一依据，按状态返回未发布 operation status 或终态 completion。
  // 输入/输出及副作用：ticket 只读；terminal_known/completion/status 为 detached 输出；仅当前 ACTIVE incarnation
  //  的 PENDING 项调用一次 expire_locked/poll_locked，其余只读 journal；唯一出口释放 engine_lock。
  // 失败/边界：坏 ticket、index 歧义、STAGED/PENDING_EFFECT、旧 pending 缺 runtime authority 或 retained 图
  //  不完整时 fail closed；不删 FIFO/journal completion、不重试发布、不敲 doorbell；重复终态观察幂等。
  task reconcile_ticket(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_status validation_status;
    rdma_status helper_status;
    rdma_status projection_status;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_batch_submission_record batch_record;
    rdma_cmq_batch_submission_item_record journal_item;
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_function_identity current_identity;
    string failure_reason;
    int unsigned journal_item_index;
    bit pending_active;

    terminal_known = 1'b0;
    completion = null;
    status = invalid_state("CMQ ticket reconcile did not complete");
    engine_lock.get(1);
    // // 单次观察段保留首错与 poll/reread 次序；break 只退出本段，不推断 status 是否代表 terminal，
    // // 也不抹除合法 operation failure；锁在段后统一归还。
    do begin : reconcile_observation
      status = reset_release_gate_status();
      if (!status.ok()) begin
        break;
      end
      if (ticket == null) begin
        status = invalid_argument("CMQ reconcile ticket is null");
        break;
      end
      if (!rdma_cmq_ticket_shape_valid(ticket)) begin
        status = invalid_argument("CMQ reconcile ticket is invalid");
        break;
      end

      // // 用 direct nonfatal seam 冻结 caller ticket，使查询值不因 runtime 已 reset 或 FIFO 被清空而变化。
      snapshot_context = new();
      if (!snapshot_context.try_snapshot_optional_ticket(
            ticket, ticket_snapshot, failure_reason
          ) || ticket_snapshot == null) begin
        status = invalid_argument(
          {"CMQ reconcile ticket snapshot failed: ", failure_reason}
        );
        break;
      end

      // // 先查稳定 ticket index，再决定是否需要当前 runtime authority；这是旧 reset/timeout/late ticket
      // // 能跨 reprepare 被观察的关键顺序。
      validation_status = locate_journal_item_by_ticket_locked(
        ticket_snapshot, batch_record, journal_item,
        journal_item_index
      );
      if (validation_status == null || !validation_status.ok()) begin
        status = (validation_status == null) ? invalid_state(
          "CMQ reconcile journal locator returned null status"
        ) : validation_status;
        break;
      end

      pending_active =
        journal_item.state inside {
          RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
          RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
        } && journal_item.completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
        journal_item.completion == null;

      if (pending_active) begin
        // // 仅同一 ACTIVE incarnation 的真实 published item 才触发一次 expire/poll；unarmed fenced row 与旧
        //   incarnation 直接失败。
        current_identity = null;
        if (engine_state != RDMA_CMQ_ENGINE_ACTIVE ||
            prepared_binding == null || cmq_snapshot == null ||
            cmq_snapshot.handle == null ||
            batch_record.engine_incarnation != engine_incarnation ||
            batch_record.function_identity == null ||
            !rdma_cmq_try_snapshot_identity_direct(
              prepared_binding.function_identity_snapshot(), current_identity
            ) || current_identity == null ||
            !batch_record.function_identity.same_incarnation(current_identity) ||
            !same_handle(cmq_snapshot.handle, batch_record.cmq_h) ||
            !ticket_has_engine_authority(ticket_snapshot)) begin
          status = invalid_state(
            "CMQ reconcile pending ticket lacks current runtime authority"
          );
          break;
        end

        helper_status = expire_locked();
        if (helper_status == null || !helper_status.ok()) begin
          status = (helper_status == null) ? invalid_state(
            "CMQ reconcile expiry returned null status"
          ) : helper_status;
          break;
        end
        helper_status = rdma_status::success();
        poll_locked(helper_status);
        if (helper_status == null || !helper_status.ok()) begin
          status = (helper_status == null) ? invalid_state(
            "CMQ reconcile poll returned null status"
          ) : helper_status;
          break;
        end

        // // expire/poll 可能同时推进其他 slot；只重读原 ticket 对应的 retained item，不从 FIFO 顺序或 slot index 猜测。
        validation_status = locate_journal_item_by_ticket_locked(
          ticket_snapshot, batch_record, journal_item,
          journal_item_index
        );
        if (validation_status == null || !validation_status.ok()) begin
          status = (validation_status == null) ? invalid_state(
            "CMQ reconcile journal reread returned null status"
          ) : validation_status;
          break;
        end
        pending_active =
          journal_item.state inside {
            RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
            RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
          } && journal_item.completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
          journal_item.completion == null;
      end

      projection_status = project_reconciled_journal_item_locked(
        batch_record, journal_item, pending_active, terminal_known,
        completion, status
      );
      if (projection_status == null || !projection_status.ok()) begin
        status = (projection_status == null) ? invalid_state(
          "CMQ reconcile projection returned null status"
        ) : projection_status;
        break;
      end
    end while (1'b0);
    engine_lock.put(1);
  endtask

  // 功能：取消指定 Function generation 的在途命令，并输出取消 completion。
  // 输入/输出及副作用：generation 为输入；completions 先清空后输出；status 输出结果；持 engine_lock，
  //  经 cancel_generation_locked 修改状态。
  // 失败/边界：reset release gate 阻断或 cancel_generation_locked 失败时经 status 报告。
  task cancel_generation(
    int unsigned generation,
    output rdma_cmq_completion completions[$],
    output rdma_status status
  );
    completions.delete();
    status = invalid_state("CMQ generation cancel did not complete");
    engine_lock.get(1);
    status = reset_release_gate_status();
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (!(engine_state inside {
          RDMA_CMQ_ENGINE_PREPARED,
          RDMA_CMQ_ENGINE_ACTIVE,
          RDMA_CMQ_ENGINE_QUIESCED
        })) begin
      status = invalid_state("CMQ engine state cannot be cancelled");
      engine_lock.put(1);
      return;
    end
    status = cancel_generation_locked(generation, 1'b0);
    if (status != null && status.ok()) begin
      while (terminal_fifo.size() != 0)
        completions.push_back(terminal_fifo.pop_front());
    end
    if (status == null)
      status = invalid_state("CMQ generation cancel returned null status");
    engine_lock.put(1);
  endtask

  // 功能：判断 retained item 状态是否必须在 reset 中转为 RESET_QUARANTINED 并保留取消 completion。
  // 输入/输出及副作用：state 只读；仅返回分类结果。
  // 失败/边界：STAGED/PENDING_EFFECT 需有完整 concrete effect 才进入 reset staging；已完成/已隔离状态不重复取消。
  protected function bit reset_item_requires_quarantine(
    input rdma_cmq_submission_state_e state
  );
    return state inside {
      RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED,
      RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
      RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED,
      RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED
    };
  endfunction

  // 功能：reset staging 中判断 item 是否仍需转为 RESET_QUARANTINED：复用 state 分类，并排除已完成
  //  reset isolation confirmation 的 RESET_QUARANTINED，供 affected/proof/reducer/cancel 四阶段共用。
  // 输入/输出及副作用：state、reset_isolation_confirmed 只读；返回 bit，不改任何状态。
  // 失败/边界：state 不在 reset_item_requires_quarantine 集合或已确认的 RESET_QUARANTINED 返回 0；未确认的仍返回 1；
  //  不验证 owner/phase/recovery_required，由调用方保留各自门禁。
  protected function bit reset_item_needs_quarantine(
    input rdma_cmq_submission_state_e state,
    input bit reset_isolation_confirmed
  );
    return reset_item_requires_quarantine(state) &&
           !(state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED &&
             reset_isolation_confirmed);
  endfunction

  // 功能：observed reset staging 前只读核对 runtime 的 slot/entry/command/token/cursor 图与 journal 的
  //  exact locator，使损坏的 POISONED/QUIESCED authority 在 release I/O 前 fail closed。
  // 输入/输出及副作用：只读 engine ledger、binding/CMQ snapshot 与 journal；返回成功或 INVALID_STATE，
  //  不 poison、不清 FIFO、不修复。
  // 失败/边界：counter 逆序/越深、CQ 游标越界、slot incarnation/locator/ticket 漂移、membership 不精确、
  //  journal phase 不符或存在 stray token/registry 行时拒绝；空账本合法。
  protected function rdma_status reset_runtime_ledger_status_locked();
    longint unsigned used;
    int unsigned slot_count;
    int unsigned published_slot_count;
    int unsigned quarantined_slot_count;
    int unsigned token_count;

    if (publish_seq < retire_seq)
      return invalid_state("CMQ reset runtime publish counter precedes retire");
    used = publish_seq - retire_seq;
    if (used > CMQ_DEPTH)
      return invalid_state("CMQ reset runtime ring occupancy exceeds depth");
    if (cq_consume_seq < retire_seq || cq_consume_seq > publish_seq)
      return invalid_state("CMQ reset runtime completion counters are inconsistent");

    slot_count = 0;
    published_slot_count = 0;
    quarantined_slot_count = 0;
    token_count = 0;
    foreach (slots[i]) begin
      rdma_cmq_slot_record record;
      rdma_cmq_ring_position_t position;
      rdma_cmq_batch_submission_record batch_record;
      rdma_cmq_batch_submission_item_record journal_item;
      string hardware_key;
      string software_key;

      if (token_in_use[i])
        token_count++;
      record = slots[i];
      if (record == null)
        continue;
      slot_count++;
      if ($isunknown(record.slot_sequence) ||
          $isunknown(record.sq_index) ||
          $isunknown(record.sq_wrap) ||
          $isunknown(record.state) ||
          $isunknown(record.command_token) ||
          !rdma_cmq_ring_position_for_sequence(
            record.slot_sequence, CMQ_DEPTH, position
          ) ||
          record.sq_index != i || record.sq_index >= CMQ_DEPTH ||
          record.sq_index != position.index ||
          record.sq_wrap != position.wrap ||
          record.ticket == null || record.expected == null ||
          record.batch_key.len() == 0 ||
          record.journal_item_index >= CMQ_DEPTH ||
          prepared_binding == null || cmq_snapshot == null ||
          cmq_snapshot.handle == null)
        return invalid_state("CMQ reset runtime slot authority is incomplete");
      if (!rdma_cmq_ticket_shape_valid(record.ticket) ||
          record.ticket.sq_index != record.sq_index ||
          record.ticket.slot_sequence != record.slot_sequence ||
          record.ticket.sq_wrap != record.sq_wrap ||
          record.ticket.command_id[4:0] != record.command_token ||
          record.ticket.function_h.generation != prepared_binding.generation ||
          !prepared_binding.accepts(record.ticket.function_h) ||
          !same_handle(record.ticket.cmq_h, cmq_snapshot.handle))
        return invalid_state("CMQ reset runtime ticket authority is inconsistent");
      if (!submission_journal.exists(record.batch_key) ||
          submission_journal[record.batch_key] == null)
        return invalid_state("CMQ reset runtime journal locator is unknown");
      batch_record = submission_journal[record.batch_key];
      if (record.journal_item_index >= batch_record.items.size())
        return invalid_state("CMQ reset runtime journal item index is invalid");
      journal_item = batch_record.items[record.journal_item_index];
      if (journal_item == null || journal_item.ticket == null ||
          !same_ticket_value(record.ticket, journal_item.ticket) ||
          journal_item.slot_sequence != record.slot_sequence ||
          journal_item.slot_index != record.sq_index ||
          journal_item.slot_wrap != record.sq_wrap ||
          journal_item.command_token != record.command_token)
        return invalid_state("CMQ reset runtime slot/journal locator disagrees");

      hardware_key = entry_key(record.sq_index, record.sq_wrap);
      if (!entry_registry.exists(hardware_key) ||
          entry_registry[hardware_key] != record)
        return invalid_state("CMQ reset runtime entry registry is inconsistent");
      software_key = command_key(record.ticket);
      case (record.state)
        CMQ_SLOT_PUBLISHED: begin
          published_slot_count++;
          if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_PENDING ||
              journal_item.completion != null ||
              !command_registry.exists(software_key) ||
              command_registry[software_key] != record ||
              record.command_token >= CMQ_DEPTH ||
              !token_in_use[record.command_token] ||
              token_incarnation[record.command_token] !=
                record.ticket.command_id[63:5])
            return invalid_state("CMQ reset runtime published membership is inconsistent");
        end
        CMQ_SLOT_TIMED_OUT_QUARANTINED: begin
          quarantined_slot_count++;
          if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_TIMEOUT ||
              journal_item.completion == null ||
              command_registry.exists(software_key) ||
              record.command_token >= CMQ_DEPTH ||
              !token_in_use[record.command_token] ||
              token_incarnation[record.command_token] !=
                record.ticket.command_id[63:5])
            return invalid_state("CMQ reset runtime timeout membership is inconsistent");
        end
        CMQ_SLOT_RESET_CANCELLED: begin
          quarantined_slot_count++;
          if (journal_item.completion_phase !=
                RDMA_CMQ_COMPLETION_RESET_CANCELLED ||
              journal_item.completion == null ||
              command_registry.exists(software_key) ||
              record.command_token >= CMQ_DEPTH ||
              !token_in_use[record.command_token] ||
              token_incarnation[record.command_token] !=
                record.ticket.command_id[63:5])
            return invalid_state("CMQ reset runtime cancellation membership is inconsistent");
        end
        CMQ_SLOT_COMPLETED: begin
          if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_TERMINAL ||
              journal_item.completion == null ||
              command_registry.exists(software_key) ||
              (record.command_token < CMQ_DEPTH &&
               token_in_use[record.command_token]))
            return invalid_state("CMQ reset runtime completed membership is inconsistent");
        end
        CMQ_SLOT_LATE_COMPLETED: begin
          if (journal_item.completion_phase !=
                RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY ||
              journal_item.completion == null ||
              command_registry.exists(software_key) ||
              (record.command_token < CMQ_DEPTH &&
               token_in_use[record.command_token]))
            return invalid_state("CMQ reset runtime late membership is inconsistent");
        end
        default:
          return invalid_state("CMQ reset runtime slot state is unsupported");
      endcase
    end
    if (slot_count != used || entry_registry.num() != slot_count ||
        command_registry.num() != published_slot_count ||
        token_count != published_slot_count + quarantined_slot_count)
      return invalid_state("CMQ reset runtime ledger membership is inconsistent");
    return rdma_status::success();
  endfunction

  // 功能：在改动任何 engine 状态前预建 reset candidate：旧 Function/backing、逐项取消 completion、
  //  batch proof 与 detached 返回图。
  // 输入/输出及副作用：candidate 为输出；只读 journal/profile/runtime，所有 new/clone/摘要均写入本地 candidate。
  // 失败/边界：缺 backing/Function、journal invariant/digest/owner 损坏、proof tuple 不完整、ID 预估溢出或
  //  snapshot/cancellation 构造失败返回错误且输出 null。
  protected function rdma_status stage_reset_candidate_locked(
    output rdma_cmq_reset_candidate candidate
  );
    rdma_cmq_reset_candidate staged_candidate;
    rdma_function_identity isolated_identity;
    rdma_status status;
    longint unsigned next_proof_id;
    longint unsigned max_id;
    string affected_batch_keys[$];

    candidate = null;
    max_id = 64'hffff_ffff_ffff_ffff;
    if (!(engine_state inside {
          RDMA_CMQ_ENGINE_PREPARED,
          RDMA_CMQ_ENGINE_ACTIVE,
          RDMA_CMQ_ENGINE_QUIESCED,
          RDMA_CMQ_ENGINE_POISONED
        }))
      return invalid_state("CMQ reset candidate engine state is not resettable");
    if (prepared_binding == null || backing_mapping == null || host_mem == null)
      return invalid_state("CMQ reset candidate release authority is missing");
    if (!rdma_cmq_try_snapshot_identity_direct(
          prepared_binding.function_identity_snapshot(), isolated_identity
        ))
      return invalid_state("CMQ reset candidate Function snapshot failed");
    staged_candidate = new("cmq_reset_candidate");
    if (staged_candidate == null)
      return invalid_state("CMQ reset candidate construction failed");
    staged_candidate.isolated_identity = isolated_identity;
    // // 释放须使用 adapter 产生的 opaque authority 快照，而不是把 engine 可变的 public mapping 句柄带出锁外。
    status = backing_mapping.snapshot_release_authority(
      staged_candidate.backing_release_authority
    );
    if (status == null || !status.ok() ||
        staged_candidate.backing_release_authority == null)
      return (status == null) ? invalid_state(
        "CMQ reset backing authority snapshot returned null"
      ) : status;
    status = host_mem.validate_failure_atomic_release(
      staged_candidate.backing_release_authority
    );
    if (status == null || !status.ok())
      return (status == null) ? invalid_state(
        "CMQ reset backing authority equivalence returned null"
      ) : status;
    // // POISONED runtime 仅在本地 authority 自洽时才可 reset；此审计只读，避免畸形 slot/token/registry 在
    // // backing release 成功前被清除而“恢复”。
    status = reset_runtime_ledger_status_locked();
    if (status == null || !status.ok())
      return (status == null) ? invalid_state(
        "CMQ reset runtime ledger audit returned null"
      ) : status;
    staged_candidate.runtime_backing_mapping = backing_mapping;
    staged_candidate.backing_release_service = host_mem;
    staged_candidate.runtime_host_mem = host_mem;
    staged_candidate.backing_release_opaque = backing_release_opaque;
    staged_candidate.runtime_state = engine_state;
    staged_candidate.engine_incarnation = engine_incarnation;
    staged_candidate.runtime_publish_seq = publish_seq;
    staged_candidate.runtime_retire_seq = retire_seq;
    staged_candidate.runtime_cq_consume_seq = cq_consume_seq;
    staged_candidate.runtime_batch_id_counter = batch_id_counter;
    staged_candidate.runtime_attempt_id_counter = attempt_id_counter;
    staged_candidate.runtime_reset_proof_id_counter = reset_proof_id_counter;
    staged_candidate.runtime_journal_count = submission_journal.num();
    staged_candidate.runtime_ticket_index_count = journal_batch_by_ticket.num();
    staged_candidate.runtime_preallocation_count =
      preallocated_publish_batches.num();
    staged_candidate.runtime_observer_count = arm_observers.num();
    staged_candidate.runtime_command_count = command_registry.num();
    staged_candidate.runtime_entry_count = entry_registry.num();
    staged_candidate.runtime_terminal_fifo_count = terminal_fifo.size();
    staged_candidate.runtime_diagnostic_fifo_count = diagnostic_fifo.size();
    staged_candidate.runtime_late_fifo_count = late_final_fifo.size();
    foreach (slots[slot_i]) begin
      if (slots[slot_i] != null)
        staged_candidate.runtime_slot_count++;
      if (token_in_use[slot_i])
        staged_candidate.runtime_token_count++;
    end
    staged_candidate.runtime_fenced_batch_key = fenced_batch_key;
    staged_candidate.runtime_fence_reason = submission_fence_reason;

    // // 先只读扫描 retained rows 确定 N；counter 只在 commit 时推进。
    foreach (submission_journal[batch_key]) begin
      rdma_cmq_batch_submission_record row;
      rdma_cmq_hw_profile retained_profile;
      bit affected;

      row = submission_journal[batch_key];
      if (row == null || row.engine_incarnation != engine_incarnation)
        continue;
      status = submission_journal_invariant_locked(batch_key);
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ reset candidate journal invariant returned null"
        ) : status;
      retained_profile = journal_profile_by_batch[batch_key];
      if (retained_profile == null)
        return invalid_state("CMQ reset candidate retained profile is missing");
      status = validate_submission_record_locked(row, retained_profile, 1'b0);
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ reset candidate retained record validation returned null"
        ) : status;
      affected = 1'b0;
      foreach (row.items[i]) begin
        if (row.items[i] == null)
          return invalid_state("CMQ reset candidate journal item is null");
        if (row.items[i].state inside {
              RDMA_CMQ_SUBMISSION_STAGED,
              RDMA_CMQ_SUBMISSION_PENDING_EFFECT
            })
          return invalid_state(
            "CMQ reset candidate contains an unobserved external effect"
          );
        if (reset_item_needs_quarantine(
              row.items[i].state, row.items[i].reset_isolation_confirmed
            ))
          affected = 1'b1;
      end
      if (affected)
        affected_batch_keys.push_back(batch_key);
    end
    if (affected_batch_keys.size() > (max_id - reset_proof_id_counter))
      return journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "CMQ reset proof IDs would overflow"
      );

    // // 现有交付 FIFO 行在 reset 清空交付顺序前先复制。
    foreach (terminal_fifo[fifo_i]) begin
      rdma_cmq_completion detached;
      rdma_cmq_nonfatal_snapshot_context ctx_snapshot;
      rdma_cmq_hw_profile fifo_profile;

      if (terminal_fifo[fifo_i] == null || terminal_fifo[fifo_i].ticket == null)
        return invalid_state("CMQ reset terminal FIFO contains an incomplete row");
      fifo_profile = profile;
      if (journal_batch_by_ticket.exists(command_key(
            terminal_fifo[fifo_i].ticket
          ))) begin
        string fifo_batch_key;
        fifo_batch_key = journal_batch_by_ticket[command_key(
          terminal_fifo[fifo_i].ticket
        )];
        if (journal_profile_by_batch.exists(fifo_batch_key))
          fifo_profile = journal_profile_by_batch[fifo_batch_key];
      end
      if (fifo_profile == null)
        return invalid_state("CMQ reset FIFO retained profile is missing");
      ctx_snapshot = new();
      status = snapshot_completion_with_profile_locked(
        terminal_fifo[fifo_i], ctx_snapshot, fifo_profile, detached
      );
      if (status == null || !status.ok() || detached == null)
        return (status == null) ? invalid_state(
          "CMQ reset FIFO completion snapshot returned null"
        ) : status;
      staged_candidate.returned_completions.push_back(detached);
    end

    next_proof_id = reset_proof_id_counter;
    foreach (affected_batch_keys[b]) begin
      rdma_cmq_batch_submission_record row;
      rdma_cmq_hw_profile retained_profile;
      rdma_cmq_reset_batch_candidate batch_candidate;
      rdma_cmq_reset_isolation_proof proof;
      rdma_cmq_reset_isolation_proof proof_snapshot;
      rdma_function_identity proof_identity;
      rdma_cmq_submission_state_e reduced_state;
      rdma_cmq_batch_submission_item_record reducer_items[$];
      longint unsigned proof_id;
      string proof_key;

      next_proof_id++;
      proof_id = next_proof_id;
      row = submission_journal[affected_batch_keys[b]];
      retained_profile = journal_profile_by_batch[affected_batch_keys[b]];
      if (row == null || retained_profile == null)
        return invalid_state("CMQ reset candidate batch row/profile is missing");
      if (!rdma_cmq_try_snapshot_identity_direct(
            row.function_identity, proof_identity
          ))
        return invalid_state("CMQ reset candidate proof identity snapshot failed");
      proof_key = $sformatf("%s|proof=%016h", row.batch_key, proof_id);
      proof = new($sformatf("cmq_reset_journal_proof_%0d", b));
      if (proof == null)
        return invalid_state("CMQ reset proof construction failed");
      proof.proof_key = proof_key;
      proof.proof_id = proof_id;
      proof.batch_key = row.batch_key;
      proof.batch_id = row.batch_id;
      proof.attempt_id = row.attempt_id;
      proof.engine_instance_id = row.engine_instance_id;
      proof.engine_incarnation = row.engine_incarnation;
      proof.isolated_identity = proof_identity;
      proof.replacement_identity = null;
      proof.batch_digest = row.batch_digest;
      proof.state = RDMA_CMQ_RESET_PROOF_AWAITING_REBIND;
      proof.backing_release_confirmed = 1'b1;
      foreach (row.items[i]) begin
        rdma_cmq_recovery_owner owner_snapshot;

        // // proof tuple 只列本次 reset 隔离的 item；终态 COMPLETED/LATE 行仍是 retained 证据，
        // // 不构成新的隔离义务，故有意省略。
        if (row.items[i] == null)
          return invalid_state("CMQ reset proof journal item is null");
        if (!reset_item_needs_quarantine(
              row.items[i].state, row.items[i].reset_isolation_confirmed
            ))
          continue;

        if (row.items[i].recovery_owner == null)
          return invalid_state("CMQ reset proof recovery owner is missing");
        owner_snapshot = make_recovery_owner_locked(
          $sformatf("cmq_reset_proof_owner_%0d_%0d", b, i),
          row.items[i].recovery_owner
        );
        if (owner_snapshot == null)
          return invalid_state("CMQ reset proof owner snapshot failed");
        proof.isolated_request_indices.push_back(row.items[i].request_index);
        proof.isolated_image_digests.push_back(row.items[i].image_digest);
        proof.isolated_authority_digests.push_back(
          row.items[i].authority_digest
        );
        proof.isolated_recovery_owners.push_back(owner_snapshot);
      end
      status = rdma_cmq_compute_reset_proof_digest(
        proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
        proof.attempt_id, proof.engine_instance_id, proof.engine_incarnation,
        proof.isolated_identity, proof.batch_digest,
        proof.isolated_request_indices, proof.isolated_image_digests,
        proof.isolated_authority_digests, proof.isolated_recovery_owners,
        proof.proof_digest
      );
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ reset proof digest computation returned null"
        ) : status;
      status = snapshot_reset_proof_locked(proof, proof_snapshot);
      if (status == null || !status.ok() || proof_snapshot == null)
        return (status == null) ? invalid_state(
          "CMQ reset proof detached snapshot returned null"
        ) : status;

      batch_candidate = new($sformatf("cmq_reset_batch_%0d", b));
      if (batch_candidate == null)
        return invalid_state("CMQ reset batch candidate construction failed");
      batch_candidate.batch_key = row.batch_key;
      batch_candidate.quarantined_record = row;
      batch_candidate.journal_proof = proof;
      batch_candidate.returned_proof = proof_snapshot;

      foreach (row.items[i]) begin
        rdma_cmq_batch_submission_item_record reducer_item;
        bit needs_reset;

        reducer_item = new($sformatf("cmq_reset_reducer_%0d_%0d", b, i));
        if (reducer_item == null)
          return invalid_state("CMQ reset reducer candidate construction failed");
        needs_reset = reset_item_needs_quarantine(
          row.items[i].state, row.items[i].reset_isolation_confirmed
        );
        reducer_item.state = needs_reset ?
          RDMA_CMQ_SUBMISSION_RESET_QUARANTINED : row.items[i].state;
        reducer_items.push_back(reducer_item);
      end
      status = rdma_cmq_reduce_batch_state(reducer_items, reduced_state);
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ reset batch reducer returned null"
        ) : status;
      batch_candidate.reduced_state = reduced_state;

      foreach (row.items[i]) begin
        rdma_cmq_batch_submission_item_record item;
        rdma_cmq_slot_record slot_candidate;
        rdma_cmq_completion cancellation;
        rdma_cmq_completion detached_cancellation;
        rdma_cmq_nonfatal_snapshot_context ctx_snapshot;
        rdma_cmq_reset_item_candidate item_candidate;
        bit needs_reset;
        bit timeout_tombstone;

        item = row.items[i];
        needs_reset = reset_item_needs_quarantine(
          item.state, item.reset_isolation_confirmed
        );
        if (!needs_reset)
          continue;
        // // 严格 generation cancel 可能已装入 RESET_CANCELLED completion；observed reset 仍把该 item 计入 proof
        // // tuple，但不得重复生成或返回。
        if (item.state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED)
          continue;
        timeout_tombstone =
          item.state == RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED;
        if (item.ticket == null || item.command_token >= CMQ_DEPTH ||
            item.entry_key.len() == 0 ||
            (timeout_tombstone &&
             (item.completion == null ||
              item.completion_phase != RDMA_CMQ_COMPLETION_TIMEOUT ||
              item.completion.ticket != item.ticket ||
              item.completion.status != item.status)) ||
            (!timeout_tombstone && item.completion != null))
          return invalid_state("CMQ reset item cancellation authority is incomplete");
        slot_candidate = new($sformatf("cmq_reset_slot_%0d_%0d", b, i));
        slot_candidate.slot_sequence = item.slot_sequence;
        slot_candidate.sq_index = item.slot_index;
        slot_candidate.sq_wrap = item.slot_wrap;
        // // timeout tombstone 已拥有隔离的 slot/token；candidate 只借用其身份构造新的 reset completion，
        // // 不重放取消副作用。
        slot_candidate.state = timeout_tombstone ?
          CMQ_SLOT_TIMED_OUT_QUARANTINED : CMQ_SLOT_PUBLISHED;
        slot_candidate.ticket = item.ticket;
        slot_candidate.command_token = item.command_token;
        slot_candidate.batch_key = row.batch_key;
        slot_candidate.journal_item_index = i;
        status = make_cancel_completion(slot_candidate, cancellation);
        if (status == null || !status.ok() || cancellation == null)
          return (status == null) ? invalid_state(
            "CMQ reset cancellation completion returned null"
          ) : status;
        ctx_snapshot = new();
        status = snapshot_completion_with_profile_locked(
          cancellation, ctx_snapshot, retained_profile, detached_cancellation
        );
        if (status == null || !status.ok() || detached_cancellation == null)
          return (status == null) ? invalid_state(
            "CMQ reset cancellation snapshot returned null"
          ) : status;
        item_candidate = new($sformatf("cmq_reset_item_%0d_%0d", b, i));
        if (item_candidate == null)
          return invalid_state("CMQ reset item candidate construction failed");
        item_candidate.batch_key = row.batch_key;
        item_candidate.journal_item_index = i;
        item_candidate.request_index = item.request_index;
        item_candidate.slot_index = item.slot_index;
        item_candidate.command_key = command_key(item.ticket);
        item_candidate.entry_key = item.entry_key;
        item_candidate.cancellation_completion = cancellation;
        staged_candidate.items.push_back(item_candidate);
        staged_candidate.returned_completions.push_back(detached_cancellation);
      end
      staged_candidate.batches.push_back(batch_candidate);
    end
    candidate = staged_candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：把已通过 backing release 的 reset candidate 无失败地写回 retained rows，并清空旧
  //  runtime/fence/preallocation authority。
  // 输入/输出及副作用：candidate 为锁内完整输入；写 journal item/batch、proof counter 与 runtime 容器；
  //  不建对象、不调 adapter/scheduler。
  // 失败/边界：须先完成 stage、validator 与 release；candidate 缺 prebuilt 句柄属内部 invariant 破坏，
  //  只保守跳过该句柄，不做 I/O。
  protected function void commit_reset_candidate_locked(
    input rdma_cmq_reset_candidate candidate
  );
    if (candidate == null)
      return;
    foreach (candidate.batches[b]) begin
      rdma_cmq_reset_batch_candidate batch_candidate;

      batch_candidate = candidate.batches[b];
      if (batch_candidate == null || batch_candidate.quarantined_record == null)
        continue;
      foreach (candidate.items[i]) begin
        rdma_cmq_reset_item_candidate item_candidate;
        rdma_cmq_batch_submission_item_record item;

        item_candidate = candidate.items[i];
        if (item_candidate == null || item_candidate.batch_key !=
              batch_candidate.batch_key)
          continue;
        if (item_candidate.journal_item_index >=
              batch_candidate.quarantined_record.items.size())
          continue;
        item = batch_candidate.quarantined_record.items[
          item_candidate.journal_item_index
        ];
        if (item == null || item_candidate.cancellation_completion == null)
          continue;
        // // retained journal 要求 completion.ticket 与 item.ticket 是同一 authoritative 句柄；candidate
        // // completion 在 staging 时已 detached，故仅在无分配的 commit 处恢复该 engine-owned alias。
        item_candidate.cancellation_completion.ticket = item.ticket;
        item.status = item_candidate.cancellation_completion.status;
        item.completion = item_candidate.cancellation_completion;
        item.state = RDMA_CMQ_SUBMISSION_RESET_QUARANTINED;
        item.completion_phase = RDMA_CMQ_COMPLETION_RESET_CANCELLED;
        item.reset_isolation_confirmed =
          item.recovery_owner != null &&
          item.recovery_owner.is_legacy_unmigrated();
        item.recovery_required = !item.reset_isolation_confirmed;
      end
      batch_candidate.quarantined_record.reset_isolation_proof =
        batch_candidate.journal_proof;
      batch_candidate.quarantined_record.state = batch_candidate.reduced_state;
      batch_candidate.quarantined_record.observer_armed = 1'b0;
    end
    reset_proof_id_counter += candidate.batches.size();
    arm_observers.delete();
    preallocated_publish_batches.delete();
    fenced_batch_key = "";
    submission_fence_reason = "";
    clear_configuration();
    engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
  endfunction

  // 设计说明：backing release 在锁外执行，返回后须用同一把锁重验 candidate 捕获的 runtime 代际、账本规模
  //  与 retained row，才能把释放结果接回 engine；本 helper 只读两侧快照，CAS 重验不是第二个提交点。
  // 功能：比较 reset candidate 与当前 engine 的完整 runtime authority，确认释放期间无并发生命周期漂移，
  //  且每个待隔离 batch 仍指向原 retained row。
  // 输入/输出及副作用：candidate 为锁内 staged 图；返回 bit 表示 state、mapping/host_mem、代际、counter、
  //  表/队列/slot/token 计数、fence 与 batch identity 检查是否全部通过；不写 engine、不取放锁、不做 I/O。
  // 失败/边界：candidate 为 null、任一标量/计数不一致、batch 缺失、retained row 非 exact alias、
  //  incarnation 或 isolated identity 不符均返回 0；短路顺序与 `!==` 比较保持原契约。
  protected function automatic bit reset_candidate_runtime_matches_locked(
    input rdma_cmq_reset_candidate candidate
  );
    bit runtime_unchanged;

    if (candidate == null)
      return 1'b0;
    runtime_unchanged =
      engine_state == candidate.runtime_state &&
      backing_mapping === candidate.runtime_backing_mapping &&
      host_mem === candidate.runtime_host_mem &&
      backing_release_opaque == candidate.backing_release_opaque &&
      engine_incarnation == candidate.engine_incarnation &&
      publish_seq == candidate.runtime_publish_seq &&
      retire_seq == candidate.runtime_retire_seq &&
      cq_consume_seq == candidate.runtime_cq_consume_seq &&
      batch_id_counter == candidate.runtime_batch_id_counter &&
      attempt_id_counter == candidate.runtime_attempt_id_counter &&
      reset_proof_id_counter == candidate.runtime_reset_proof_id_counter &&
      submission_journal.num() == candidate.runtime_journal_count &&
      journal_batch_by_ticket.num() == candidate.runtime_ticket_index_count &&
      preallocated_publish_batches.num() ==
        candidate.runtime_preallocation_count &&
      arm_observers.num() == candidate.runtime_observer_count &&
      command_registry.num() == candidate.runtime_command_count &&
      entry_registry.num() == candidate.runtime_entry_count &&
      terminal_fifo.size() == candidate.runtime_terminal_fifo_count &&
      diagnostic_fifo.size() == candidate.runtime_diagnostic_fifo_count &&
      late_final_fifo.size() == candidate.runtime_late_fifo_count &&
      fenced_batch_key == candidate.runtime_fenced_batch_key &&
      submission_fence_reason == candidate.runtime_fence_reason;
    if (runtime_unchanged) begin
      int unsigned current_slot_count;
      int unsigned current_token_count;

      current_slot_count = 0;
      current_token_count = 0;
      foreach (slots[slot_i]) begin
        if (slots[slot_i] != null)
          current_slot_count++;
        if (token_in_use[slot_i])
          current_token_count++;
      end
      runtime_unchanged =
        current_slot_count == candidate.runtime_slot_count &&
        current_token_count == candidate.runtime_token_count;
    end
    if (runtime_unchanged) begin
      foreach (candidate.batches[b]) begin
        rdma_cmq_batch_submission_record retained_row;

        if (candidate.batches[b] == null ||
            candidate.batches[b].quarantined_record == null ||
            !submission_journal.exists(candidate.batches[b].batch_key)) begin
          runtime_unchanged = 1'b0;
          break;
        end
        retained_row = submission_journal[candidate.batches[b].batch_key];
        if (retained_row !== candidate.batches[b].quarantined_record ||
            retained_row.engine_incarnation != candidate.engine_incarnation ||
            retained_row.function_identity == null ||
            candidate.isolated_identity == null ||
            !retained_row.function_identity.same_incarnation(
              candidate.isolated_identity
            )) begin
          runtime_unchanged = 1'b0;
          break;
        end
      end
    end
    return runtime_unchanged;
  endfunction

  // 功能：failure-atomic observed reset：校验 release capability，staging、backing release、无分配 commit，
  //  最后发布 detached outputs。
  // 输入/输出及副作用：completions/proofs/status 为输出；成功释放旧 backing、隔离 retained rows 并返回
  //  取消 completion/proof 快照；失败清空 outputs。
  // 失败/边界：UNCONFIGURED 幂等成功；validator/release 为 null 或非 OK 时不做破坏性 cancel/clear，保留
  //  runtime/journal/fence/counter；release 成功后 runtime CAS 失配则清掉别名并置 POISONED，不提交候选。
  task reset_observed(
    output rdma_cmq_completion completions[$],
    output rdma_cmq_reset_isolation_proof proofs[],
    output rdma_status status
  );
    rdma_cmq_reset_candidate candidate;
    rdma_status release_status;
    rdma_status validation_status;
    bit candidate_runtime_unchanged;

    completions.delete();
    proofs = new[0];
    status = invalid_state("CMQ observed reset did not complete");
    engine_lock.get(1);
    status = reset_release_gate_status();
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (engine_state == RDMA_CMQ_ENGINE_UNCONFIGURED) begin
      status = rdma_status::success();
      engine_lock.put(1);
      return;
    end
    if (!(engine_state inside {
          RDMA_CMQ_ENGINE_PREPARED,
          RDMA_CMQ_ENGINE_ACTIVE,
          RDMA_CMQ_ENGINE_QUIESCED,
          RDMA_CMQ_ENGINE_POISONED
        })) begin
      status = invalid_state("CMQ engine state cannot be observed-reset");
      engine_lock.put(1);
      return;
    end
    if (host_mem == null || backing_mapping == null) begin
      status = invalid_state("CMQ reset release authority is missing");
      engine_lock.put(1);
      return;
    end
    validation_status = host_mem.validate_failure_atomic_release(
      backing_mapping
    );
    if (validation_status == null || !validation_status.ok()) begin
      status = (validation_status == null) ? invalid_state(
        "CMQ reset release validator returned null status"
      ) : validation_status;
      engine_lock.put(1);
      return;
    end
    status = stage_reset_candidate_locked(candidate);
    if (status == null || !status.ok() || candidate == null) begin
      status = (status == null) ? invalid_state(
        "CMQ reset candidate staging returned null status"
      ) : status;
      engine_lock.put(1);
      return;
    end
    // // 输出与所有 detached 图在外部 release 前已定好大小，release 失败可清空而不分配、不改行。
    proofs = new[candidate.batches.size()];
    foreach (candidate.batches[i])
      proofs[i] = candidate.batches[i].returned_proof;
    foreach (candidate.returned_completions[i])
      completions.push_back(candidate.returned_completions[i]);

    // // 整个外部 release 窗口内保持 gate 置位，排在 engine_lock 后的生命周期入口会先观察到它。
    reset_release_in_progress = 1'b1;

    // // adapter 调用有意放在 engine_lock 外；candidate 只保留 detached release authority 与本地见证，
    // // 不向 adapter 暴露 engine-owned 图。
    engine_lock.put(1);
    if (candidate.backing_release_service == null)
      release_status = invalid_state(
        "CMQ reset candidate release service is missing"
      );
    else
      release_status = candidate.backing_release_service.release_opaque(
        candidate.backing_release_authority
      );

    engine_lock.get(1);
    if (release_status == null || !release_status.ok()) begin
      completions.delete();
      proofs.delete();
      reset_release_in_progress = 1'b0;
      status = (release_status == null) ? invalid_state(
        "CMQ reset release returned null status"
      ) : release_status;
      engine_lock.put(1);
      return;
    end

    // // 任何并发生命周期变化都使 staged 图失效；当前 release_opaque 不阻塞，此 CAS 式重验是为将来可让出的 adapter。
    candidate_runtime_unchanged =
      reset_candidate_runtime_matches_locked(candidate);
    if (!candidate_runtime_unchanged) begin
      completions.delete();
      proofs.delete();
      // // release_opaque 已回收 allocation，runtime 漂移后 candidate 不能再提交；丢弃全部 runtime/backing 别名并置
      //   POISONED。
      poison_released_runtime_drift_locked();
      status = invalid_state(
        "CMQ reset runtime authority changed during backing release"
      );
      engine_lock.put(1);
      return;
    end

    commit_reset_candidate_locked(candidate);
    status = rdma_status::success();
    engine_lock.put(1);
  endtask

  // 功能：按唯一 proof_key 扫描 retained journal，返回 proof 的 detached 快照，不另建 proof 表。
  // 输入/输出及副作用：proof_key 只读；proof/status 输出；只读 journal/profile，做唯一性与全值快照。
  // 失败/边界：空/未知 key 返回 INVALID_ARGUMENT；重复 key、batch/proof 损坏或 snapshot 失败返回
  //  INVALID_STATE，不发布 partial proof。
  task query_reset_isolation_proof(
    input string proof_key,
    output rdma_cmq_reset_isolation_proof proof,
    output rdma_status status
  );
    rdma_cmq_reset_isolation_proof source;
    int unsigned match_count;

    proof = null;
    status = invalid_state("CMQ reset proof query did not complete");
    if (proof_key.len() == 0) begin
      status = invalid_argument("CMQ reset proof key is empty");
      return;
    end
    engine_lock.get(1);
    match_count = 0;
    foreach (submission_journal[batch_key]) begin
      rdma_cmq_batch_submission_record row;
      rdma_cmq_hw_profile retained_profile;
      rdma_cmq_reset_isolation_proof row_proof_snapshot;
      rdma_status row_status;
      bit row_set_present;

      row = submission_journal[batch_key];
      if (row == null)
        continue;
      if (row.reset_isolation_proof != null &&
          row.reset_isolation_proof.proof_key == proof_key) begin
        row_status = journal_row_set_existence_locked(
          batch_key, row_set_present
        );
        if (row_status == null || !row_status.ok() || !row_set_present) begin
          status = (row_status == null) ? journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset proof journal row invariant returned null"
          ) : journal_status(RDMA_SC_INVALID_STATE, row_status.message);
          engine_lock.put(1);
          return;
        end
        if (!journal_profile_by_batch.exists(batch_key) ||
            journal_profile_by_batch[batch_key] == null) begin
          status = journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset proof retained profile is missing"
          );
          engine_lock.put(1);
          return;
        end
        retained_profile = journal_profile_by_batch[batch_key];
        row_status = validate_submission_record_locked(
          row, retained_profile, 1'b0
        );
        if (row_status == null || !row_status.ok()) begin
          status = (row_status == null) ? journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset proof retained journal validation returned null"
          ) : journal_status(RDMA_SC_INVALID_STATE, row_status.message);
          engine_lock.put(1);
          return;
        end
        row_status = snapshot_reset_proof_locked(
          row.reset_isolation_proof, row_proof_snapshot
        );
        if (row_status == null || !row_status.ok() ||
            row_proof_snapshot == null ||
            row_proof_snapshot.batch_key != row.batch_key ||
            row_proof_snapshot.batch_id != row.batch_id ||
            row_proof_snapshot.attempt_id != row.attempt_id ||
            row_proof_snapshot.engine_instance_id != row.engine_instance_id ||
            row_proof_snapshot.engine_incarnation != row.engine_incarnation ||
            row.function_identity == null ||
            row_proof_snapshot.isolated_identity == null ||
            !row_proof_snapshot.isolated_identity.same_incarnation(
              row.function_identity
            )) begin
          status = journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset proof retained value does not bind its journal row"
          );
          engine_lock.put(1);
          return;
        end
        match_count++;
        source = row.reset_isolation_proof;
      end
    end
    if (match_count == 0) begin
      status = invalid_argument("CMQ reset proof key is not retained");
      engine_lock.put(1);
      return;
    end
    if (match_count != 1) begin
      status = invalid_state("CMQ reset proof key is not unique");
      engine_lock.put(1);
      return;
    end
    status = snapshot_reset_proof_locked(source, proof);
    if (status == null)
      status = invalid_state("CMQ reset proof snapshot returned null status");
    engine_lock.put(1);
  endtask

  // 功能：把 legacy reset 转发到一次 reset_observed，保留历史 completion/status 投影。
  // 输入/输出及副作用：completions/status 输出；内部 ignored_proofs 接收 proof 后丢弃。
  // 失败/边界：传播 reset_observed 的非空 status；不重复 cancel/release/清理。
  task reset(
    output rdma_cmq_completion completions[$],
    output rdma_status status
  );
    rdma_cmq_reset_isolation_proof ignored_proofs[];

    // // legacy 调用方只得到历史 completion/status 投影；全部 lifecycle/release/proof authority 在单次
    // // observed-reset 事务中，本 wrapper 不得二次取消。
    reset_observed(completions, ignored_proofs, status);
  endtask

  // 功能：返回当前 engine_state。
  // 输入/输出及副作用：无参数；无锁读取，不改状态。
  // 失败/边界：无；无锁返回值不保证与 journal/cursor/reset epoch 原子一致。
  function rdma_cmq_engine_state_e state();
    return engine_state;
  endfunction

  // 功能：返回 backing mapping 的 detached clone，没有则返回 null。
  // 输入/输出及副作用：读 backing_mapping；返回克隆。
  // 失败/边界：clone 或类型转换失败触发 uvm_fatal（CMQ mapping snapshot clone mismatch）。
  function rdma_dma_mapping mapping_snapshot();
    uvm_object cloned_object;
    rdma_dma_mapping snapshot;

    if (backing_mapping == null)
      return null;
    cloned_object = backing_mapping.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ mapping snapshot clone mismatch")
    return snapshot;
  endfunction

  // 功能：返回已发布命令的累计 sequence（publish_seq）。
  // 输入/输出及副作用：只读访问器。
  // 失败/边界：无。
  function longint unsigned published_count();
    return publish_seq;
  endfunction

  // 功能：返回已退休的累计 sequence（retire_seq）。
  // 输入/输出及副作用：只读访问器。
  // 失败/边界：无。
  function longint unsigned retired_count();
    return retire_seq;
  endfunction

  // 功能：返回已消费的 CQE 累计数（cq_consume_seq）。
  // 输入/输出及副作用：只读访问器。
  // 失败/边界：无。
  function longint unsigned cq_consumed_count();
    return cq_consume_seq;
  endfunction

  // 功能：返回在途命令数（command_registry 大小）。
  // 输入/输出及副作用：只读访问器。
  // 失败/边界：无。
  function int unsigned outstanding_count();
    return command_registry.num();
  endfunction

  // 功能：统计处于 TIMED_OUT_QUARANTINED 的 slot 数。
  // 输入/输出及副作用：只读遍历 slots。
  // 失败/边界：无。
  function int unsigned quarantine_count();
    int unsigned count;

    count = 0;
    foreach (slots[i]) begin
      if (slots[i] != null &&
          slots[i].state == CMQ_SLOT_TIMED_OUT_QUARANTINED)
        count++;
    end
    return count;
  endfunction

  // 功能：返回 last_poison 的 detached 快照。
  // 输入/输出及副作用：只读；经 clone_diagnostic 复制。
  // 失败/边界：last_poison 为空或克隆失败返回 null。
  function rdma_cmq_diagnostic last_poison_snapshot();
    rdma_status status;
    rdma_cmq_diagnostic snapshot;

    if (last_poison == null)
      return null;
    status = clone_diagnostic(last_poison, snapshot);
    if (status == null || !status.ok() || snapshot == null)
      return null;
    return snapshot;
  endfunction

  // 功能：按准入、best-effort 取消、丢弃交付、释放 backing、清配置的顺序关闭 CMQ。
  // 输入/输出及副作用：status 输出关闭结果；全程持 engine_lock；释放成功进入 UNCONFIGURED；释放失败只保留
  //  重试 authority 与原诊断，不删 retained journal。
  // 失败/边界：reset gate/非法状态立即拒绝；UNCONFIGURED 幂等清配置；取消失败原码透传（null 转
  //  INVALID_STATE）；缺释放 authority 或 release 为 null 返回 INVALID_STATE 并 POISONED；release 非 OK 原样透传。
  task shutdown(output rdma_status status);
    rdma_status cancel_status;

    status = invalid_state("CMQ shutdown did not complete");
    engine_lock.get(1);
    // // 单次业务段的退出只汇合解锁；release 仍在锁内，不能套用 reset 的让锁窗口。
    do begin : shutdown_transaction
      status = reset_release_gate_status();
      if (!status.ok())
        break;
      if (engine_state == RDMA_CMQ_ENGINE_UNCONFIGURED) begin
        clear_configuration();
        status = rdma_status::success();
        break;
      end
      if (!(engine_state inside {RDMA_CMQ_ENGINE_PREPARED,
                                 RDMA_CMQ_ENGINE_ACTIVE,
                                 RDMA_CMQ_ENGINE_QUIESCED,
                                 RDMA_CMQ_ENGINE_POISONED})) begin
        status = invalid_state("CMQ engine state cannot be shut down");
        break;
      end
      if (engine_state != RDMA_CMQ_ENGINE_POISONED &&
          prepared_binding != null) begin
        // // shutdown 无 completion 输出，不报告严格 ledger 审计失败；先尽力清除运行账本，
        // // 避免 release 失败后的重试继续使用旧 slot/token。
        cancel_status = cancel_generation_locked(
          prepared_binding.generation, 1'b1
        );
        if (cancel_status == null || !cancel_status.ok()) begin
          status = (cancel_status == null) ?
            invalid_state("CMQ shutdown cancellation returned null") :
            cancel_status;
          break;
        end
      end
      // // 取消产生的 completion 与旧的未交付结果都明确丢弃；保留 journal 诊断，不把关闭伪造成 observed reset，
      // // 也不生成 isolation proof。
      terminal_fifo.delete();
      diagnostic_fifo.delete();
      late_final_fifo.delete();
      if (backing_mapping == null || host_mem == null) begin
        retain_release_authority(backing_mapping, host_mem);
        status = invalid_state("CMQ shutdown release authority is missing");
        break;
      end
      if (backing_release_opaque)
        status = host_mem.release_opaque(backing_mapping);
      else
        status = host_mem.\release (backing_mapping);
      if (status == null || !status.ok()) begin
        retain_release_authority(backing_mapping, host_mem,
                                 backing_release_opaque);
        if (status == null)
          status = invalid_state("CMQ shutdown release returned null status");
        break;
      end
      clear_configuration();
      engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
      status = rdma_status::success();
    end while (1'b0);
    engine_lock.put(1);
  endtask
endclass

// 功能：doorbell 即将进入 MMIO 时，把本 observer 交给 owner 认证并 arm。
// 输入/输出及副作用：已配置时同步调用 owner.arm_submission_for_mmio(this)。
// 失败/边界：未配置或 owner 为 null 仅报 UVM_ERROR 后返回；不等待、分配、取锁。
function void
rdma_cmq_mmio_arm_observer::before_mmio_maybe_visible();
  if (!configured || owner == null) begin
    `uvm_error("RDMA_CMQ_MMIO_ARM_INVALID",
               "CMQ MMIO arm capability is invalid")
    return;
  end
  owner.arm_submission_for_mmio(this);
endfunction
