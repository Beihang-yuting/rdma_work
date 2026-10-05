// 目录/层次：核心执行层 core/rdma_control_plane.sv。
// 职责：控制面事务入口：PD/MR/CQ/SRQ/CEQ/AEQ/QP 的创建、修改、销毁与恢复，
//   串联 resource manager、CMQ、host-memory、HMC 与队列/QP executor，并维护 Function 锁与事务号。
// 依赖：依赖 resource manager、cmq port、STAG key policy、host_mem、hmc_allocator、
//   context_backing 与 queue/QP executor。
// 所有权与生命周期：外部依赖为非拥有引用；本类拥有 Function 锁表、事务号与 executor 对象。

class rdma_control_plane extends uvm_object;
  `rdma_object_utils(rdma_control_plane)

  protected rdma_resource_manager manager;
  protected rdma_cmq_port cmq;
  protected rdma_stag_key_policy key_policy;
  protected rdma_host_mem_api host_mem;
  protected rdma_hmc_allocator hmc_allocator;
  protected rdma_context_backing_api context_backing;
  protected rdma_queue_lifecycle_executor queue_executor;
  protected rdma_qp_lifecycle_executor qp_executor;
  protected time default_timeout;
  protected bit configured;

  protected longint unsigned next_transaction_id;
  protected bit transaction_ids_exhausted;
  protected semaphore lock_table_guard;
  protected semaphore function_locks[string];

  // 功能：构造控制面，外部依赖置空。
  // 输入/输出及副作用：name 为 UVM 实例名。
  // 失败/边界：未 configure 前业务入口返回 INVALID_STATE。
  function new(string name = "rdma_control_plane");
    super.new(name);
    manager = null;
    cmq = null;
    key_policy = null;
    host_mem = null;
    hmc_allocator = null;
    context_backing = null;
    queue_executor = null;
    qp_executor = null;
    default_timeout = 0;
    configured = 1'b0;
    next_transaction_id = 1;
    transaction_ids_exhausted = 1'b0;
    lock_table_guard = new(1);
    function_locks.delete();
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

  // 功能：生成 handle 的 detached 快照（kind、UID、object_id、generation）。
  // 输入/输出及副作用：source 只读；返回新 handle。
  // 失败/边界：source 为 null 返回 null。
  protected function rdma_handle snapshot_handle(rdma_handle source);
    rdma_handle snapshot;

    if (source == null)
      return null;
    snapshot = new("control_handle_snapshot");
    snapshot.kind = source.kind;
    snapshot.function_uid = source.function_uid;
    snapshot.object_id = source.object_id;
    snapshot.generation = source.generation;
    return snapshot;
  endfunction

  // 功能：把后端 status 克隆为 detached 副本，null 转为 INVALID_STATE。
  // 输入/输出及副作用：source、null_message 为输入；返回独立 status。
  // 失败/边界：source 为 null 时返回带 null_message 的 INVALID_STATE。
  protected function rdma_status checked_status(
    rdma_status source,
    string null_message
  );
    if (source == null)
      return invalid_state(null_message);
    return rdma_cmq_clone_status_value(source);
  endfunction

  // 功能：为 MR 的硬件阶段构造 CMQ 命令：OCC_FLUSHED→OCC_FLUSH（按 mr_serial 冲刷 PBLE）、
  //   MR_DEREGISTERED→MR_DEREGISTER（失效 MRT）、DRAINED→TQ_FLUSH。
  // 输入/输出及副作用：owner 被深拷贝进命令，mr 只读；返回新命令，使用 default_timeout。
  // 失败/边界：其它 step 返回 null，由调用方报告 UNSUPPORTED_OPCODE。
  protected function rdma_cmq_command_desc make_mr_hw_command(
    rdma_function_handle owner,
    rdma_mr mr,
    rdma_control_step_e step,
    string name
  );
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_mr_deregister_body deregister_body;

    if (step == RDMA_CTRL_STEP_HW_OCC_FLUSHED) begin
      occ_body = rdma_hw_occ_flush_body::type_id::create({name, "_body"});
      occ_body.mr_serial_flush = 1'b1;
      occ_body.pble = 1'b1;
      occ_body.mr_serial = mr.mr_serial[11:0];
      return rdma_make_cmq_command(owner, RDMA_OP_OCC_FLUSH, "occ_flush",
                                   occ_body, default_timeout, name);
    end
    if (step == RDMA_CTRL_STEP_HW_MR_DEREGISTERED) begin
      deregister_body =
        rdma_hw_mr_deregister_body::type_id::create({name, "_body"});
      deregister_body.mr_h = project_handle(mr.handle, mr.local_mr_id,
                                            RDMA_RESOURCE_MR);
      deregister_body.stag_key = mr.lkey[7:0];
      deregister_body.next_state = RDMA_CONTEXT_INVALID;
      return rdma_make_cmq_command(owner, RDMA_OP_MR_DEREGISTER,
                                   "deregister", deregister_body,
                                   default_timeout, name);
    end
    if (step == RDMA_CTRL_STEP_HW_DRAINED)
      return rdma_make_cmq_command(
        owner, RDMA_OP_TQ_FLUSH, "tq_flush",
        rdma_hw_cmq_empty_body::type_id::create({name, "_body"}),
        default_timeout, name
      );
    return null;
  endfunction

  // 功能：派发一次 CMQ 命令，原样保留 backend 的 status 引用。
  // 输入/输出及副作用：command 为输入；ticket、completion、status 为输出；恰调用 cmq.execute 一次。
  // 失败/边界：cmq 为空返回 INVALID_STATE，command 为空返回 INVALID_ARGUMENT；backend 返回 null status 时保留 null，
  //   由调用方归一化；不重试、不推断 timeout，不推进 generation 或资源状态。
  protected task execute_control_command_raw_status(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    bit no_submit;

    rdma_cmq_dispatch(
      cmq, command, ticket, completion, status, no_submit,
      "control-plane CMQ is unavailable",
      "control-plane CMQ command is null"
    );
  endtask

  // 功能：在 raw 派发之后把 status 归一化为 detached 副本，供回滚/注销/恢复阶段稳定读取。
  // 输入/输出及副作用：command、null_status_message 为输入；ticket、completion、status 为输出；只调用 cmq.execute 一次。
  // 失败/边界：cmq/command 的错误沿用 raw 路径；backend 返回 null status 时转为 INVALID_STATE；
  //   不重试，不推进 generation、资源状态或 recovery journal。
  protected task execute_control_command(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status,
    input string null_status_message
  );
    execute_control_command_raw_status(
      command, ticket, completion, status
    );
    status = checked_status(status, null_status_message);
  endtask

  // 功能：经 control 域 lifecycle result seed 创建未完成的 detached rdma_control_result。
  // 输入/输出及副作用：无输入；返回写入 status、primary_status、初始资源状态与 recovery 标志的 result。
  // 失败/边界：seed 创建或初始化失败时返回带 INVALID_STATE 的结果；transaction_id 由调用入口写入。
  protected function rdma_control_result make_result();
    rdma_control_result result;
    rdma_lifecycle_result_seed seed;
    rdma_status seed_status;

    result = new("control_result");
    seed = rdma_lifecycle_result_seed::type_id::create(
      "control_result_seed"
    );
    if (seed == null) begin
      result.status = invalid_state(
        "control-plane result seed allocation failed"
      );
      result.primary_status = rdma_cmq_clone_status_value(result.status);
      return result;
    end
    seed.domain = RDMA_LIFECYCLE_DOMAIN_CONTROL;
    seed.pending_message = "control-plane operation did not complete";
    seed_status = seed.initialize_result(result);
    if (seed_status == null || !seed_status.ok()) begin
      result.status = invalid_state(
        "control-plane result seed initialization failed"
      );
      result.primary_status = rdma_cmq_clone_status_value(result.status);
      result.final_resource_state = RDMA_RESOURCE_NEW;
      result.final_resource_state_known = 1'b0;
      result.recovery_required = 1'b0;
    end
    return result;
  endfunction

  // 功能：清理已激活的 PD：先 begin_quiesce，再 finalize_release。
  // 输入/输出及副作用：pd_h 为输入；result 被更新（final_resource_state、completed_steps、rollback_statuses）。
  // 失败/边界：任一步失败时把 status 记入 result.rollback_statuses 并停止。
  protected function void cleanup_activated_pd(
    rdma_handle pd_h,
    rdma_control_result result
  );
    rdma_status cleanup_status;

    cleanup_status = manager.begin_quiesce(pd_h);
    cleanup_status = checked_status(
      cleanup_status, "active PD cleanup quiesce returned null"
    );
    if (!cleanup_status.ok()) begin
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(cleanup_status)
      );
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_QUIESCING;
    result.final_resource_state_known = 1'b1;

    cleanup_status = manager.finalize_release(pd_h);
    cleanup_status = checked_status(
      cleanup_status, "active PD cleanup release returned null"
    );
    if (!cleanup_status.ok()) begin
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(cleanup_status)
      );
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
  endfunction

  // 功能：冻结 MR 的 recovery 记录并发布 RECOVERY_REQUIRED 结果。
  // 输入/输出及副作用：reserved_mr、recovery、primary_status 为输入；mr、result_finalized 为输出；
  //   经 manager.mark_error 或 mark_reserved_error 冻结，再 lookup 取得 ERROR MR 快照。
  // 失败/边界：冻结失败时记录错误并回查权威状态，recovery_required 置 0；最终 result.status 恒为 RECOVERY_REQUIRED。
  protected function void finalize_mr_recovery(
    rdma_mr reserved_mr,
    rdma_recovery_record recovery,
    rdma_status primary_status,
    rdma_control_result result,
    output rdma_mr mr,
    output bit result_finalized,
    input bit reserved_error = 1'b0
  );
    rdma_resource authoritative_resource;
    rdma_status normalized_primary;
    rdma_status recovery_status;

    mr = null;
    result_finalized = 1'b1;
    normalized_primary = checked_status(
      primary_status, "MR recovery primary status is null"
    );
    if (reserved_error)
      recovery_status = manager.mark_reserved_error(
        reserved_mr.handle, recovery
      );
    else
      recovery_status = manager.mark_error(reserved_mr.handle, recovery);
    recovery_status = checked_status(
      recovery_status, "MR recovery freeze returned null"
    );
    if (recovery_status.ok()) begin
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b1;
      recovery_status = manager.lookup(
        reserved_mr.handle, authoritative_resource
      );
      recovery_status = checked_status(
        recovery_status, "resource manager ERROR MR lookup returned null"
      );
      if (recovery_status.ok()) begin
        if (!$cast(mr, authoritative_resource) || mr == null ||
            mr.handle == null || mr.state != RDMA_RESOURCE_ERROR)
          mr = null;
      end
    end
    else begin
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(recovery_status)
      );
      recovery_status = manager.lookup(
        reserved_mr.handle, authoritative_resource
      );
      recovery_status = checked_status(
        recovery_status, "authoritative MR fallback lookup returned null"
      );
      if (recovery_status.ok() && authoritative_resource != null) begin
        result.final_resource_state = authoritative_resource.state;
        result.final_resource_state_known = 1'b1;
      end
      else begin
        if (recovery_status.ok())
          recovery_status = invalid_state(
            "authoritative MR fallback snapshot is null"
          );
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(recovery_status)
        );
        result.final_resource_state = RDMA_RESOURCE_NEW;
        result.final_resource_state_known = 1'b0;
      end
      result.recovery_required = 1'b0;
    end
    result.primary_status = rdma_cmq_clone_status_value(normalized_primary);
    result.status = rdma_status::make(
      RDMA_SC_RECOVERY_REQUIRED,
      "MR state requires recovery"
    );
  endfunction

  // 功能：MR 创建回滚失败后，登记 recovery 记录并发布结果。
  // 输入/输出及副作用：reserved_mr、primary_status、result、hardware_presence、待执行 step、ambiguous_ticket 为输入；
  //   mr、result_finalized 为输出；调用 finalize_mr_recovery。
  // 失败/边界：无。
  protected function void retain_mr_rollback_error(
    rdma_mr reserved_mr,
    rdma_status primary_status,
    rdma_control_result result,
    rdma_hw_presence_e hardware_presence,
    bit has_pending_step,
    rdma_control_step_e pending_step,
    rdma_cmq_ticket ambiguous_ticket,
    output rdma_mr mr,
    output bit result_finalized
  );
    rdma_recovery_record recovery;

    recovery = rdma_recovery_record::type_id::create(
      "register_mr_rollback_recovery"
    );
    recovery.resource_h = snapshot_handle(reserved_mr.handle);
    recovery.hardware_presence = hardware_presence;
    recovery.completed_steps = result.completed_steps;
    if (has_pending_step)
      recovery.pending_steps.push_back(pending_step);
    recovery.backing_refs = reserved_mr.backing_refs;
    recovery.hmc_refs = reserved_mr.hmc_refs;
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
      ambiguous_ticket, "register MR rollback recovery"
    );
    recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
    recovery.rollback_statuses = result.rollback_statuses;
    finalize_mr_recovery(reserved_mr, recovery, primary_status, result, mr,
                         result_finalized);
  endfunction

  // 功能：回滚未完成的 MR 创建：依次 MR_DEREGISTER（若已分配硬件 key）、释放 owned HMC 与 backing、
  //   释放预留或 mark_error 后 finalize_release。
  // 输入/输出及副作用：reserved_mr、owner、primary_status、result、hardware_key_allocated、
  //   registry_programmed 为输入；
  //   mr、result_finalized 为输出。
  // 失败/边界：任一回滚步骤失败则经 retain_mr_rollback_error 保留 recovery 记录，不继续释放。
  protected task rollback_mr_creation(
    rdma_mr reserved_mr,
    rdma_function_handle owner,
    rdma_status primary_status,
    rdma_control_result result,
    bit hardware_key_allocated,
    bit registry_programmed,
    output rdma_mr mr,
    output bit result_finalized
  );
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_recovery_record recovery;
    rdma_status rollback_status;
    rdma_hw_presence_e failure_presence;
    bit released_owned_backing;

    mr = null;
    result_finalized = 1'b0;
    ticket = null;
    released_owned_backing = 1'b0;

    if (hardware_key_allocated) begin
      command = make_mr_hw_command(owner, reserved_mr,
                                   RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
                                   "register_mr_rollback_deregister");
      execute_control_command(
        command, ticket, completion, rollback_status,
        "MR_DEREGISTER rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        failure_presence = (rollback_status.code == RDMA_SC_TIMEOUT) ?
          RDMA_HW_PRESENCE_UNKNOWN : RDMA_HW_PRESENCE_PRESENT;
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, failure_presence, 1'b1,
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
          (rollback_status.code == RDMA_SC_TIMEOUT) ? ticket : null, mr,
          result_finalized
        );
        return;
      end
      result.completed_steps.push_back(
        RDMA_CTRL_STEP_HW_MR_DEREGISTERED
      );
    end

    for (int i = int'(reserved_mr.hmc_refs.size()) - 1; i >= 0; i--) begin
      if (reserved_mr.hmc_refs[i] == null ||
          reserved_mr.hmc_refs[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          reserved_mr.hmc_refs[i].release_complete)
        continue;
      if (hmc_allocator == null)
        rollback_status = invalid_state(
          "owned MR HMC rollback allocator is unavailable"
        );
      else
        rollback_status = hmc_allocator.\release (
          reserved_mr.hmc_refs[i].owner,
          reserved_mr.hmc_refs[i].object_kind,
          reserved_mr.hmc_refs[i].address
        );
      rollback_status = checked_status(
        rollback_status, "owned MR HMC rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null, mr,
          result_finalized
        );
        return;
      end
      reserved_mr.hmc_refs[i].release_complete = 1'b1;
      released_owned_backing = 1'b1;
    end

    for (int i = int'(reserved_mr.backing_refs.size()) - 1; i >= 0; i--) begin
      if (reserved_mr.backing_refs[i] == null ||
          reserved_mr.backing_refs[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          reserved_mr.backing_refs[i].release_complete)
        continue;
      if (host_mem == null)
        rollback_status = invalid_state(
          "owned MR backing rollback host memory is unavailable"
        );
      else
        rollback_status = host_mem.\release (
          reserved_mr.backing_refs[i].mapping
        );
      rollback_status = checked_status(
        rollback_status, "owned MR backing rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        if (hardware_key_allocated || registry_programmed) begin
          retain_mr_rollback_error(
            reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
            1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null, mr,
            result_finalized
          );
          return;
        end
        recovery = rdma_recovery_record::type_id::create(
          "register_mr_reserved_backing_rollback"
        );
        recovery.resource_h = snapshot_handle(reserved_mr.handle);
        recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
        recovery.completed_steps = result.completed_steps;
        recovery.pending_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);
        recovery.backing_refs = reserved_mr.backing_refs;
        recovery.hmc_refs = reserved_mr.hmc_refs;
        recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
        recovery.rollback_statuses = result.rollback_statuses;
        finalize_mr_recovery(
          reserved_mr, recovery, primary_status, result, mr,
          result_finalized, 1'b1
        );
        return;
      end
      reserved_mr.backing_refs[i].release_complete = 1'b1;
      released_owned_backing = 1'b1;
    end
    if (released_owned_backing)
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);

    if (!registry_programmed) begin
      rollback_status = manager.release_reserved(reserved_mr.handle);
      rollback_status = checked_status(
        rollback_status, "MR reservation rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        if (reserved_mr.hmc_refs.size() == 0 &&
            reserved_mr.backing_refs.size() == 1 &&
            reserved_mr.backing_refs[0] != null &&
            reserved_mr.backing_refs[0].ownership ==
              RDMA_OWNERSHIP_CONTROL_PLANE) begin
          recovery = rdma_recovery_record::type_id::create(
            "register_mr_reserved_resource_rollback"
          );
          recovery.resource_h = snapshot_handle(reserved_mr.handle);
          recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
          recovery.completed_steps = result.completed_steps;
          recovery.pending_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
          recovery.backing_refs = reserved_mr.backing_refs;
          recovery.hmc_refs = reserved_mr.hmc_refs;
          recovery.primary_status =
            rdma_cmq_clone_status_value(primary_status);
          recovery.rollback_statuses = result.rollback_statuses;
          finalize_mr_recovery(
            reserved_mr, recovery, primary_status, result, mr,
            result_finalized, 1'b1
          );
        end
        else begin
          retain_mr_rollback_error(
            reserved_mr, primary_status, result,
            RDMA_HW_PRESENCE_ABSENT, 1'b1,
            RDMA_CTRL_STEP_RESOURCE_RELEASED, null, mr,
            result_finalized
          );
        end
        return;
      end
    end
    else begin
      recovery = rdma_recovery_record::type_id::create(
        "register_mr_programmed_rollback"
      );
      recovery.resource_h = snapshot_handle(reserved_mr.handle);
      recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
      recovery.completed_steps = result.completed_steps;
      recovery.backing_refs = reserved_mr.backing_refs;
      recovery.hmc_refs = reserved_mr.hmc_refs;
      recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
      recovery.rollback_statuses = result.rollback_statuses;
      rollback_status = manager.mark_error(reserved_mr.handle, recovery);
      rollback_status = checked_status(
        rollback_status, "programmed MR rollback mark ERROR returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null, mr,
          result_finalized
        );
        return;
      end
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      rollback_status = manager.finalize_release(reserved_mr.handle);
      rollback_status = checked_status(
        rollback_status, "programmed MR rollback release returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null, mr,
          result_finalized
        );
        return;
      end
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.final_resource_state_known = 1'b1;
  endtask

  // 功能：MR 注销失败后，登记 recovery 记录并发布结果。
  // 输入/输出及副作用：mr_snapshot、primary_status、result、hardware_presence、待执行 step、ambiguous_ticket 为输入；
  //   result_finalized 为输出；调用 finalize_mr_recovery。
  // 失败/边界：无。
  protected function void retain_mr_destroy_error(
    rdma_mr mr_snapshot,
    rdma_status primary_status,
    rdma_control_result result,
    rdma_hw_presence_e hardware_presence,
    bit has_pending_step,
    rdma_control_step_e pending_step,
    rdma_cmq_ticket ambiguous_ticket,
    output bit result_finalized
  );
    rdma_mr ignored_mr;
    rdma_recovery_record recovery;

    recovery = rdma_recovery_record::type_id::create(
      "deregister_mr_recovery"
    );
    recovery.resource_h = snapshot_handle(mr_snapshot.handle);
    recovery.hardware_presence = hardware_presence;
    recovery.completed_steps = result.completed_steps;
    if (has_pending_step)
      recovery.pending_steps.push_back(pending_step);
    recovery.backing_refs = mr_snapshot.backing_refs;
    recovery.hmc_refs = mr_snapshot.hmc_refs;
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
      ambiguous_ticket, "deregister MR recovery"
    );
    recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
    recovery.rollback_statuses = result.rollback_statuses;
    finalize_mr_recovery(
      mr_snapshot, recovery, primary_status, result, ignored_mr,
      result_finalized
    );
  endfunction

  // 功能：把 operation_status 归一化后写入 result.status 与 primary_status。
  // 输入/输出及副作用：result、operation_status 为输入；result 被更新。
  // 失败/边界：result 为 null 直接返回；status 为 null 时归一化为 INVALID_STATE。
  protected function void finish_result(
    rdma_control_result result,
    rdma_status operation_status
  );
    rdma_status normalized;

    if (result == null)
      return;
    normalized = checked_status(
      operation_status, "control-plane operation returned null status"
    );
    result.status = rdma_cmq_clone_status_value(normalized);
    result.primary_status = rdma_cmq_clone_status_value(normalized);
  endfunction

  // 功能：检查控制面是否已配置。
  // 输入/输出及副作用：只读本对象字段；返回 status。
  // 失败/边界：未配置、manager/cmq/key_policy 为空或默认 timeout 为 0 返回 INVALID_STATE。
  protected function rdma_status configured_status();
    if (!configured || manager == null || cmq == null ||
        key_policy == null || default_timeout == 0)
      return invalid_state("control plane is not configured");
    return rdma_status::success();
  endfunction

  // 功能：校验 Function binding 并构造其 owner 句柄。
  // 输入/输出及副作用：binding 为输入；owner 为输出。
  // 失败/边界：binding 为空返回 INVALID_ARGUMENT；校验返回 null/失败、非 ACTIVE 或 owner 构造失败返回对应错误。
  protected function rdma_status binding_owner_status(
    rdma_function_binding binding,
    output rdma_function_handle owner
  );
    rdma_status status;

    owner = null;
    if (binding == null)
      return invalid_argument("control-plane Function binding is null");
    status = binding.validate();
    if (status == null)
      return invalid_state("Function binding validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    if (binding.state != RDMA_BIND_ACTIVE)
      return invalid_state("control-plane Function binding is not ACTIVE");
    owner = binding.make_handle();
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state("Function binding owner construction failed");
    return rdma_status::success();
  endfunction

  // 功能：校验 binding 与期望 owner 的 Function 身份与 generation 一致。
  // 输入/输出及副作用：binding、expected_owner 只读；返回 status。
  // 失败/边界：任一为空或 Function 不同返回 INVALID_ARGUMENT；generation 不同返回 STALE_GENERATION。
  protected function rdma_status generation_fence(
    rdma_function_binding binding,
    rdma_function_handle expected_owner
  );
    if (binding == null || expected_owner == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "generation fence authority is null"
      );
    if (binding.function_uid != expected_owner.function_uid ||
        binding.global_function_id != expected_owner.object_id)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "generation fence Function differs"
      );
    if (binding.generation != expected_owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "Function generation changed during transaction"
      );
    return rdma_status::success();
  endfunction

  // 功能：校验候选 owner 与期望 Function owner 的身份与 generation 一致。
  // 输入/输出及副作用：candidate、expected、label 为输入；返回 status。
  // 失败/边界：candidate 非 Function 返回 INVALID_ARGUMENT；expected 非法返回 INVALID_STATE；
  //   身份不符返回 INVALID_ARGUMENT；generation 不同返回 STALE_GENERATION。
  protected function rdma_status same_owner_status(
    rdma_function_handle candidate,
    rdma_function_handle expected,
    string label
  );
    if (candidate == null || candidate.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_argument({label, " owner is not a Function handle"});
    if (expected == null || expected.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state({label, " expected Function owner is invalid"});
    if (candidate.function_uid != expected.function_uid ||
        candidate.object_id != expected.object_id)
      return invalid_argument({label, " Function identity does not match"});
    if (candidate.generation != expected.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        {label, " Function generation is stale"}
      );
    return rdma_status::success();
  endfunction


  // 功能：校验 MR 注册请求合法且属于 owner。
  // 输入/输出及副作用：request、owner 只读；返回 status。
  // 失败/边界：request 为空返回 INVALID_ARGUMENT；validate 返回 null 为 INVALID_STATE；owner 不符透传其错误。
  protected function rdma_status register_mr_request_status(
    rdma_register_mr_req request,
    rdma_function_handle owner
  );
    rdma_status status;

    if (request == null)
      return invalid_argument("register MR request is null");
    status = request.validate();
    if (status == null)
      return invalid_state("register MR request validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    return same_owner_status(request.owner, owner, "register MR request");
  endfunction

  // 功能：MR 注册的入口校验：可选 generation fence、request 合法且属于 owner、backing 与 request/ownership 一致；
  //   锁前、锁后、快照三处共用同一顺序。
  // 输入/输出及副作用：fence_owner 为 null 时跳过 fence；stage 作为诊断前缀；只读输入，返回独立 status。
  // 失败/边界：fence 失败返回 INVALID_ARGUMENT/STALE_GENERATION，其余沿用 register_mr_request_status 与
  //   validate_backing 的错误码；子校验返回 null 为 INVALID_STATE。
  protected function rdma_status register_mr_input_status(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_function_handle fence_owner,
    rdma_function_handle owner,
    rdma_resource_ownership_e required_ownership,
    string stage
  );
    rdma_status status;

    if (fence_owner != null) begin
      status = checked_status(
        generation_fence(binding, fence_owner),
        {stage, "register MR generation fence returned null"}
      );
      if (!status.ok())
        return status;
    end
    status = checked_status(
      register_mr_request_status(request, owner),
      {stage, "register MR request check returned null"}
    );
    if (!status.ok())
      return status;
    return checked_status(
      validate_backing(binding, request, backing, owner, required_ownership),
      {stage, "register MR backing check returned null"}
    );
  endfunction

  // 功能：owned MR 的入口校验：request 合法且属于 owner、长度不超 32 位 host 分配上限、不请求 atomic；
  //   DMA context 合法、属于 owner、与 binding.queue_dma 一致且无 owner_h。
  // 输入/输出及副作用：stage 作为诊断前缀；只读输入，返回独立 status。
  // 失败/边界：超长/context 为空/owner_h 非空返回 INVALID_ARGUMENT，atomic 返回 UNSUPPORTED_OPCODE，
  //   DMA 授权不符返回 DMA_TRANSLATION，子校验 null 为 INVALID_STATE。
  protected function rdma_status owned_mr_input_status(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_dma_request_context dma_context,
    rdma_function_handle owner,
    string stage
  );
    rdma_status status;

    status = checked_status(
      register_mr_request_status(request, owner),
      {stage, "owned register MR request check returned null"}
    );
    if (!status.ok())
      return status;
    if (request.length > 64'h0000_0000_ffff_ffff)
      return invalid_argument(
        {stage, "owned MR length exceeds host allocation size"}
      );
    if (request.access.remote_atomic)
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        {stage, "owned MR helper cannot allocate atomic DMA authority"}
      );
    if (dma_context == null)
      return invalid_argument({stage, "owned MR DMA request context is null"});
    status = checked_status(
      dma_context.validate(),
      {stage, "owned MR DMA context validation returned null"}
    );
    if (!status.ok())
      return status;
    status = checked_status(
      same_owner_status(dma_context.function_h, owner,
                        {stage, "owned MR DMA context"}),
      {stage, "owned MR DMA Function check returned null"}
    );
    if (!status.ok())
      return status;
    if (dma_context.requester_bdf != binding.queue_dma.requester_bdf ||
        dma_context.pasid_valid != binding.queue_dma.pasid_valid ||
        dma_context.pasid != binding.queue_dma.pasid ||
        dma_context.dma_domain_valid != binding.queue_dma.dma_domain_valid ||
        dma_context.dma_domain_id != binding.queue_dma.dma_domain_id)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "owned MR DMA authority does not match Function"
      );
    if (dma_context.owner_h != null)
      return invalid_argument("owned MR DMA request owner must be null");
    return rdma_status::success();
  endfunction

  // 功能：深拷贝 register MR request，并确认副本与原对象及其 owner/PD 句柄不共享引用。
  // 输入/输出及副作用：request 只读；frozen 输出新副本，失败时为 null。
  // 失败/边界：clone 失败、类型不符或任一引用未分离返回 INVALID_STATE。
  protected function rdma_status detach_mr_request(
    rdma_register_mr_req request,
    output rdma_register_mr_req frozen
  );
    uvm_object cloned_object;

    frozen = null;
    cloned_object = request.clone();
    if (cloned_object == null || !$cast(frozen, cloned_object) ||
        frozen == request || frozen.owner == request.owner ||
        frozen.pd_h == request.pd_h) begin
      frozen = null;
      return invalid_state("register MR request snapshot is not deeply detached");
    end
    return rdma_status::success();
  endfunction

  // 功能：深拷贝 MR backing 描述，并确认副本及其 Function 句柄、page layout、每个 backing/HMC 引用均不与原对象共享。
  // 输入/输出及副作用：backing 只读；frozen 输出新副本，失败时为 null。
  // 失败/边界：clone 失败、类型不符、数组长度不同或任一引用未分离返回 INVALID_STATE。
  protected function rdma_status detach_mr_backing(
    rdma_mr_backing_desc backing,
    output rdma_mr_backing_desc frozen
  );
    uvm_object cloned_object;

    frozen = null;
    cloned_object = backing.clone();
    if (cloned_object == null || !$cast(frozen, cloned_object) ||
        frozen == backing || frozen.function_h == backing.function_h ||
        frozen.page_layout == backing.page_layout ||
        frozen.backing_refs.size() != backing.backing_refs.size() ||
        frozen.hmc_refs.size() != backing.hmc_refs.size()) begin
      frozen = null;
      return invalid_state("register MR backing snapshot is not deeply detached");
    end
    foreach (frozen.backing_refs[i]) begin
      rdma_backing_ref copy_ref = frozen.backing_refs[i];
      rdma_backing_ref orig_ref = backing.backing_refs[i];

      if (copy_ref == null || orig_ref == null || copy_ref == orig_ref ||
          copy_ref.mapping == null || orig_ref.mapping == null ||
          copy_ref.mapping == orig_ref.mapping ||
          copy_ref.mapping.function_h == orig_ref.mapping.function_h ||
          (orig_ref.mapping.owner_h == null && copy_ref.mapping.owner_h != null) ||
          (orig_ref.mapping.owner_h != null &&
           (copy_ref.mapping.owner_h == null ||
            copy_ref.mapping.owner_h == orig_ref.mapping.owner_h))) begin
        frozen = null;
        return invalid_state(
          "register MR backing reference snapshot is not deeply detached"
        );
      end
    end
    foreach (frozen.hmc_refs[i]) begin
      if (frozen.hmc_refs[i] == null || backing.hmc_refs[i] == null ||
          frozen.hmc_refs[i] == backing.hmc_refs[i] ||
          frozen.hmc_refs[i].owner == backing.hmc_refs[i].owner) begin
        frozen = null;
        return invalid_state(
          "register MR HMC reference snapshot is not deeply detached"
        );
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：深拷贝 owned MR 的 DMA request context，并确认 Function/owner 句柄已分离。
  // 输入/输出及副作用：dma_context 只读；frozen 输出新副本，失败时为 null。
  // 失败/边界：clone 失败、类型不符或句柄仍共享返回 INVALID_STATE。
  protected function rdma_status detach_dma_context(
    rdma_dma_request_context dma_context,
    output rdma_dma_request_context frozen
  );
    uvm_object cloned_object;

    frozen = null;
    cloned_object = dma_context.clone();
    if (cloned_object == null || !$cast(frozen, cloned_object) ||
        frozen == dma_context ||
        frozen.function_h == dma_context.function_h ||
        (dma_context.owner_h == null && frozen.owner_h != null) ||
        (dma_context.owner_h != null &&
         (frozen.owner_h == null || frozen.owner_h == dma_context.owner_h))) begin
      frozen = null;
      return invalid_state("owned MR DMA context snapshot is not deeply detached");
    end
    return rdma_status::success();
  endfunction

  // 功能：按 MR access 计算所需 DMA 方向。
  // 输入/输出及副作用：access 为输入；返回方向。
  // 失败/边界：含 local_write/remote_write/remote_atomic 为 BIDIRECTIONAL，否则为 DEVICE_READ。
  protected function rdma_dma_direction_e required_dma_direction(
    rdma_rdma_access_t access
  );
    return (access.local_write || access.remote_write ||
            access.remote_atomic) ?
           RDMA_DMA_BIDIRECTIONAL : RDMA_DMA_DEVICE_READ;
  endfunction

  // 功能：校验 MR backing 描述：owner、requester BDF/PASID、mapping 访问权限、HMC 引用与 lease 大小。
  // 输入/输出及副作用：binding、request、backing、owner、required_ownership 为输入；只读，返回 status。
  // 失败/边界：权威信息缺失为 INVALID_STATE；backing/引用为空、ownership 非法、PBL 索引超 28 位为 INVALID_ARGUMENT；
  //   BDF/PASID 与 Function 不符返回 DMA_TRANSLATION；HMC allocator 缺失或 lookup 失败返回对应错误。
  protected function rdma_status validate_backing(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_function_handle owner,
    rdma_resource_ownership_e required_ownership
  );
    rdma_dma_permission_t required_permissions;
    rdma_dma_direction_e required_direction;
    rdma_status status;
    longint unsigned lease_size;

    if (binding == null || request == null || owner == null)
      return invalid_state("register MR backing authority is incomplete");
    if (backing == null)
      return invalid_argument("register MR backing descriptor is null");
    status = backing.validate();
    if (status == null)
      return invalid_state("register MR backing validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    if (backing.page_layout.pbl_mode == RDMA_MR_PBL2 &&
        backing.page_layout.first_pbl_index > 28'hfff_ffff)
      return invalid_argument("register MR first PBL index exceeds 28 bits");
    status = same_owner_status(backing.function_h, owner,
                               "register MR backing");
    if (status == null || !status.ok())
      return checked_status(status,
                            "register MR backing owner check returned null");
    if (backing.requester_bdf != binding.queue_dma.requester_bdf)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "register MR backing requester BDF does not match Function"
      );
    if (backing.pasid_valid != binding.queue_dma.pasid_valid ||
        backing.pasid != binding.queue_dma.pasid)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "register MR backing PASID does not match Function"
      );
    required_permissions = '0;
    required_permissions.device_read = 1'b1;
    required_permissions.device_write = request.access.local_write ||
                                        request.access.remote_write ||
                                        request.access.remote_atomic;
    required_permissions.atomic = request.access.remote_atomic;
    required_direction = required_dma_direction(request.access);
    foreach (backing.backing_refs[i]) begin
      if (backing.backing_refs[i] == null ||
          backing.backing_refs[i].mapping == null)
        return invalid_argument("register MR backing reference is null");
      if (backing.backing_refs[i].ownership != required_ownership)
        return invalid_argument("register MR backing ownership is invalid");
      if (backing.backing_refs[i].mapping.pasid_valid !=
            backing.pasid_valid ||
          (backing.pasid_valid &&
           backing.backing_refs[i].mapping.pasid != backing.pasid))
        return rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "register MR backing PASID does not match mapping"
        );
      status = backing.backing_refs[i].mapping.check_access(
        owner, backing.requester_bdf, backing.pasid_valid, backing.pasid,
        binding.queue_dma.dma_domain_valid,
        binding.queue_dma.dma_domain_id, request.iova, request.length,
        required_direction, required_permissions
      );
      if (status == null)
        return invalid_state("register MR mapping access returned null");
      if (!status.ok())
        return rdma_cmq_clone_status_value(status);
    end
    foreach (backing.hmc_refs[i]) begin
      if (backing.hmc_refs[i] == null)
        return invalid_argument("register MR HMC reference is null");
      if (backing.hmc_refs[i].ownership != required_ownership)
        return invalid_argument("register MR HMC ownership is invalid");
      status = same_owner_status(backing.hmc_refs[i].owner, owner,
                                 "register MR HMC backing");
      if (status == null || !status.ok())
        return checked_status(
          status, "register MR HMC owner check returned null"
        );
      if (hmc_allocator == null)
        return invalid_state("register MR HMC allocator is unavailable");
      status = hmc_allocator.lookup(
        owner, backing.hmc_refs[i].object_kind,
        backing.hmc_refs[i].address, lease_size
      );
      if (status == null)
        return invalid_state("register MR HMC lookup returned null");
      if (!status.ok())
        return rdma_cmq_clone_status_value(status);
      if (lease_size != backing.hmc_refs[i].size)
        return invalid_argument("register MR HMC lease size does not match");
    end
    return rdma_status::success();
  endfunction

  // 功能：把软件句柄投影为硬件视角的 handle（object_id 换成 local_id）。
  // 输入/输出及副作用：software_h、local_id、expected_kind 为输入；返回新 handle。
  // 失败/边界：software_h 为空或 kind 不符返回 null。
  protected function rdma_handle project_handle(
    rdma_handle software_h,
    int unsigned local_id,
    rdma_resource_kind_e expected_kind
  );
    rdma_handle projected;

    if (software_h == null || software_h.kind != expected_kind)
      return null;
    projected = new("control_plane_hw_projection");
    projected.kind = expected_kind;
    projected.function_uid = software_h.function_uid;
    projected.object_id = local_id;
    projected.generation = software_h.generation;
    return projected;
  endfunction

  // 功能：校验 destroy PD 的句柄 kind 与 Function 归属。
  // 输入/输出及副作用：pd_h、owner 只读；返回 status。
  // 失败/边界：句柄为空或非 PD、属于其他 Function 返回 INVALID_ARGUMENT；owner 非法返回 INVALID_STATE；
  //   generation 不同返回 STALE_GENERATION。
  protected function rdma_status pd_handle_owner_status(
    rdma_handle pd_h,
    rdma_function_handle owner
  );
    if (pd_h == null)
      return invalid_argument("destroy PD handle is null");
    if (pd_h.kind != RDMA_RESOURCE_PD)
      return invalid_argument("destroy PD handle kind is not PD");
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state("destroy PD Function owner is invalid");
    if (pd_h.function_uid != owner.function_uid)
      return invalid_argument("destroy PD belongs to another Function");
    if (pd_h.generation != owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "destroy PD Function generation is stale"
      );
    return rdma_status::success();
  endfunction

  // 功能：校验注销 MR 的句柄 kind 与 Function 归属。
  // 输入/输出及副作用：mr_h、owner 只读；返回 status。
  // 失败/边界：句柄为空或非 MR、属于其他 Function 返回 INVALID_ARGUMENT；owner 非法返回 INVALID_STATE；
  //   generation 不同返回 STALE_GENERATION。
  protected function rdma_status mr_handle_owner_status(
    rdma_handle mr_h,
    rdma_function_handle owner
  );
    if (mr_h == null)
      return invalid_argument("deregister MR handle is null");
    if (mr_h.kind != RDMA_RESOURCE_MR)
      return invalid_argument("deregister MR handle kind is not MR");
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state("deregister MR Function owner is invalid");
    if (mr_h.function_uid != owner.function_uid)
      return invalid_argument("deregister MR belongs to another Function");
    if (mr_h.generation != owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "deregister MR Function generation is stale"
      );
    return rdma_status::success();
  endfunction

  // 功能：用 Function UID 与 object_id 生成 Function 锁表的 key。
  // 输入/输出及副作用：owner 为输入；返回 string。
  // 失败/边界：无。
  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  endfunction

  // 功能：分配一个控制面事务号。
  // 输入/输出及副作用：transaction_id、status 为输出；持 lock_table_guard 递增 next_transaction_id。
  // 失败/边界：事务号空间耗尽返回 RESOURCE_EXHAUSTED，transaction_id 保持 0。
  protected task reserve_transaction_id(
    output longint unsigned transaction_id,
    output rdma_status status
  );
    transaction_id = 0;
    status = invalid_state("transaction ID allocation did not complete");
    // 先尝试 try_get，避免无竞争时阻塞调度；失败再 get()，保持真实竞争语义。
    if (!lock_table_guard.try_get(1))
      lock_table_guard.get(1);
    if (transaction_ids_exhausted) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "control-plane transaction ID space is exhausted"
      );
    end
    else begin
      transaction_id = next_transaction_id;
      if (next_transaction_id == 64'hffff_ffff_ffff_ffff)
        transaction_ids_exhausted = 1'b1;
      else
        next_transaction_id++;
      status = rdma_status::success();
    end
    lock_table_guard.put(1);
  endtask

  // 功能：获取 owner 对应的 Function 锁（必要时创建）。
  // 输入/输出及副作用：owner 为输入；function_lock 输出已取得的信号量，由调用方释放。
  // 失败/边界：无错误返回；阻塞直到取得锁。
  protected task acquire_function_lock(
    rdma_function_handle owner,
    output semaphore function_lock
  );
    string key;

    function_lock = null;
    key = function_key(owner);
    // 先尝试 try_get，避免无竞争时阻塞调度；失败再 get()，保持真实竞争语义。
    if (!lock_table_guard.try_get(1))
      lock_table_guard.get(1);
    if (!function_locks.exists(key))
      function_locks[key] = new(1);
    function_lock = function_locks[key];
    lock_table_guard.put(1);
    function_lock.get(1);
  endtask

  // 功能：配置控制面依赖并创建 queue/QP executor。
  // 输入/输出及副作用：resource_manager、cmq_port、key_policy 必填，host_mem/hmc_allocator/context_backing 可选；
  //   保存非拥有引用并创建 executor，成功后置 configured。
  // 失败/边界：重复配置、必填依赖为空或 timeout 为 0 返回错误；QP executor 仅在 host_mem 与 context_backing 都存在时配置。
  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_cmq_port cmq_port,
    rdma_stag_key_policy key_policy,
    rdma_host_mem_api host_mem = null,
    rdma_hmc_allocator hmc_allocator = null,
    rdma_context_backing_api context_backing = null,
    time command_timeout = 1us
  );
    rdma_status status;

    if (configured)
      return invalid_state("control plane is already configured");
    if (resource_manager == null)
      return invalid_argument("resource manager is null");
    if (cmq_port == null)
      return invalid_argument("CMQ port is null");
    if (key_policy == null)
      return invalid_argument("STAG key policy is null");
    if (command_timeout == 0)
      return invalid_argument("default control-plane timeout is zero");

    this.manager = resource_manager;
    this.cmq = cmq_port;
    this.key_policy = key_policy;
    this.host_mem = host_mem;
    this.hmc_allocator = hmc_allocator;
    this.context_backing = context_backing;
    default_timeout = command_timeout;
    queue_executor = rdma_queue_lifecycle_executor::type_id::create(
      "control_plane_queue_executor"
    );
    if (queue_executor == null)
      return invalid_state("queue lifecycle executor construction failed");
    status = queue_executor.configure(
      resource_manager, cmq_port, host_mem, context_backing, command_timeout
    );
    status = checked_status(status, "queue executor configure returned null");
    if (!status.ok()) begin
      queue_executor = null;
      return status;
    end
    qp_executor = rdma_qp_lifecycle_executor::type_id::create(
      "control_plane_qp_executor"
    );
    if (qp_executor == null)
      return invalid_state("QP lifecycle executor construction failed");
    if (host_mem != null && context_backing != null) begin
      status = qp_executor.configure(
        resource_manager, cmq_port, host_mem, context_backing, command_timeout
      );
      status = checked_status(status, "QP executor configure returned null");
      if (!status.ok()) begin
        qp_executor = null;
        return status;
      end
    end
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：校验队列类请求合法且属于 owner。
  // 输入/输出及副作用：request、owner、label 为输入；返回 status。
  // 失败/边界：request 为空返回 INVALID_ARGUMENT；validate 返回 null 为 INVALID_STATE；owner 不符透传其错误。
  protected function rdma_status queue_request_status(
    rdma_semantic_request request,
    rdma_function_handle owner,
    string label
  );
    rdma_status status;

    if (request == null)
      return invalid_argument({label, " request is null"});
    status = request.validate();
    if (status == null)
      return invalid_state({label, " request validation returned null"});
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    return same_owner_status(request.owner, owner, label);
  endfunction

  // 功能：校验队列请求目标句柄的 Function 归属。
  // 输入/输出及副作用：target、owner、label 为输入；返回 status。
  // 失败/边界：target 为空或属于其他 Function 返回 INVALID_ARGUMENT；owner 非法返回 INVALID_STATE；
  //   generation 不同返回 STALE_GENERATION。
  protected function rdma_status queue_target_owner_status(
    rdma_handle target,
    rdma_function_handle owner,
    string label
  );
    if (target == null)
      return invalid_argument({label, " target handle is null"});
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state({label, " Function owner is invalid"});
    if (target.function_uid != owner.function_uid)
      return invalid_argument({label, " target belongs to another Function"});
    if (target.generation != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               {label, " target generation is stale"});
    return rdma_status::success();
  endfunction

  // 功能：校验请求合法且属于 owner；target 非 NONE 时再从请求中重新读取目标句柄并校验归属，
  //   destroy 目标还须为 expected_kind。
  // 输入/输出及副作用：每次调用都重新读取请求字段（锁后复验依赖此点）；label 为诊断前缀；返回非 null status。
  // 失败/边界：请求类型或目标 kind 不符返回 INVALID_ARGUMENT，归属不符返回 INVALID_ARGUMENT/STALE_GENERATION，
  //   子校验返回 null 为 INVALID_STATE。
  protected function rdma_status request_target_status(
    rdma_semantic_request request,
    rdma_control_target_e target,
    rdma_resource_kind_e expected_kind,
    rdma_function_handle owner,
    string label
  );
    rdma_destroy_resource_req destroy_request;
    rdma_modify_qp_req modify_request;
    rdma_handle target_h;
    rdma_status status;

    status = checked_status(queue_request_status(request, owner, label),
                            {label, " request returned null"});
    if (!status.ok() || target == RDMA_CTRL_TARGET_NONE)
      return status;
    if (target == RDMA_CTRL_TARGET_DESTROY && $cast(destroy_request, request))
      target_h = destroy_request.target_h;
    else if (target == RDMA_CTRL_TARGET_MODIFY_QP &&
             $cast(modify_request, request))
      target_h = modify_request.qp_h;
    else
      return invalid_argument({label, " request type is invalid"});
    if (target == RDMA_CTRL_TARGET_DESTROY &&
        (target_h == null || target_h.kind != expected_kind))
      return invalid_argument({label, " target kind is invalid"});
    return checked_status(
      queue_target_owner_status(target_h, owner, {label, " target"}),
      {label, " target returned null"}
    );
  endfunction

  // 功能：锁内操作的统一准入：锁前校验 binding 与请求/目标，取得 Function 锁，再以锁内 binding 重新校验。
  // 输入/输出及副作用：owner 输出锁前 binding 推导的 Function 句柄；function_lock 输出已取得的锁（未取得为 null），
  //   由调用方释放；status 输出非 null 结果。
  // 失败/边界：任一校验失败立即返回；锁内 binding 的 Function 或 generation 漂移返回 INVALID_ARGUMENT/STALE_GENERATION，
  //   调用方不得继续执行副作用。
  protected task admit_locked_request(
    rdma_function_binding binding,
    rdma_semantic_request request,
    rdma_control_target_e target,
    rdma_resource_kind_e expected_kind,
    string label,
    output rdma_function_handle owner,
    output semaphore function_lock,
    output rdma_status status
  );
    rdma_function_handle locked_owner;

    function_lock = null;
    status = checked_status(binding_owner_status(binding, owner),
                            {label, " Function binding returned null"});
    if (!status.ok())
      return;
    status = request_target_status(request, target, expected_kind, owner, label);
    if (!status.ok())
      return;
    acquire_function_lock(owner, function_lock);
    status = checked_status(binding_owner_status(binding, locked_owner),
                            {"post-lock ", label, " Function returned null"});
    if (!status.ok())
      return;
    status = checked_status(
      same_owner_status(locked_owner, owner, {"post-lock ", label, " Function"}),
      {"post-lock ", label, " identity returned null"}
    );
    if (!status.ok())
      return;
    status = request_target_status(request, target, expected_kind,
                                   locked_owner, {"post-lock ", label});
  endtask

  // 功能：创建 CQ/SRQ/CEQ/AEQ 的共用事务外壳：分配事务号、检查配置与适配器、准入后调用 queue executor。
  // 输入/输出及副作用：binding、request、requires_context、expected_kind 为输入；queue、result 为输出；退出前释放 Function 锁。
  // 失败/边界：未配置、缺 executor/host_mem/context_backing 返回 INVALID_STATE；失败时 queue 为 null，错误经 result 发布。
  protected task create_queue_facade(
    rdma_function_binding binding,
    rdma_semantic_request request,
    bit requires_context,
    rdma_resource_kind_e expected_kind,
    output rdma_queue_resource queue,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;

    queue = null;
    result = make_result();
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      `RDMA_BREAK_IF_FAILED(status, "queue transaction ID allocation returned null")
      status = configured_status();
      `RDMA_BREAK_IF_FAILED(status, "queue control-plane configuration check returned null")
      if (queue_executor == null) begin
        status = invalid_state("queue lifecycle executor is unavailable");
        break;
      end
      if (host_mem == null) begin
        status = invalid_state("queue create requires a host-memory adapter");
        break;
      end
      if (requires_context && context_backing == null) begin
        status = invalid_state(
          "CQ/SRQ queue create requires a context-backing adapter"
        );
        break;
      end
      admit_locked_request(binding, request, RDMA_CTRL_TARGET_NONE,
                           expected_kind, "queue create", owner,
                           function_lock, status);
      if (!status.ok())
        break;
      queue_executor.create_locked(binding, owner, request, transaction_id,
                                   queue, result);
      if (result != null && result.ok() &&
          (queue == null || queue.resource_kind() != expected_kind)) begin
        queue = null;
        status = invalid_state("queue executor returned the wrong resource kind");
        finish_result(result, status);
        break;
      end
      status = (result == null) ?
        invalid_state("queue executor returned a null result") :
        rdma_cmq_clone_status_value(result.status);
      if (status == null)
        status = invalid_state("queue executor result status is null");
      break;
    end while (1'b0);
    if (result == null)
      result = make_result();
    if (status == null || !status.ok()) begin
      queue = null;
      finish_result(result, status);
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：queue（CQ/SRQ/CEQ/AEQ）与 QP destroy 共用的事务外壳：分配事务号、准入，再在锁内调用对应 executor。
  // 输入/输出及副作用：expected_kind 为目标类型，use_qp_executor 选择 QP executor；result 输出事务结果；退出前释放锁。
  // 失败/边界：准入失败或 executor 返回 null/改写事务号时以 INVALID_STATE 等发布；executor 调用后的失败由其 result 承载。
  protected task run_destroy_operation(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    rdma_resource_kind_e expected_kind,
    bit use_qp_executor,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;
    string op;
    bit executor_called;

    op = use_qp_executor ? "QP destroy" : "queue destroy";
    result = make_result();
    function_lock = null;
    executor_called = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      `RDMA_BREAK_IF_FAILED(status, {op, " transaction ID returned null"})
      status = configured_status();
      `RDMA_BREAK_IF_FAILED(status, {op, " configuration check returned null"})
      admit_locked_request(binding, request, RDMA_CTRL_TARGET_DESTROY,
                           expected_kind, op, owner, function_lock, status);
      if (!status.ok())
        break;
      executor_called = 1'b1;
      if (use_qp_executor)
        qp_executor.destroy_locked(binding, owner, request, transaction_id,
                                   result);
      else
        queue_executor.destroy_locked(binding, owner, request,
                                      transaction_id, result);
      if (result == null)
        status = invalid_state({op, " executor returned null result"});
      else if (use_qp_executor && result.transaction_id != transaction_id) begin
        status = invalid_state({op, " executor changed transaction ID"});
        finish_result(result, status);
      end
      else
        status = checked_status(result.status,
                                {op, " executor result status is null"});
      break;
    end while (1'b0);
    if (result == null) begin
      result = make_result();
      result.transaction_id = transaction_id;
      if (status == null || status.ok())
        status = invalid_state({op, " executor returned null result"});
      executor_called = 1'b0;
    end
    // QP executor 自行发布最终结果；queue executor 的失败结果沿用原契约，由外壳以其 status 重新归一化。
    if (!status.ok() && (!executor_called || !use_qp_executor))
      finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：销毁 队列资源（CQ/SRQ/CEQ/AEQ），转交 destroy 事务外壳并校验目标类型。
  // 输入/输出及副作用：binding、request 为输入；result 输出事务结果。
  // 失败/边界：owner/generation 不符或目标 kind 错误时拒绝，错误经 result 发布。
  protected task destroy_queue_facade(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    rdma_resource_kind_e expected_kind,
    output rdma_control_result result
  );
    run_destroy_operation(binding, request, expected_kind, 1'b0, result);
  endtask

  // 功能：创建 CQ，经 create_queue_facade 完成事务并校验返回资源。
  // 输入/输出及副作用：binding、request 为输入；cq 输出 ACTIVE 资源，result 输出事务结果。
  // 失败/边界：失败或类型/状态不符时 cq 为 null，错误经 result 发布。
  task create_cq(
    rdma_function_binding binding,
    rdma_create_cq_req request,
    output rdma_cq cq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    cq = null;
    create_queue_facade(binding, request, 1'b1, RDMA_RESOURCE_CQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(cq, queue) || cq == null || cq.state != RDMA_RESOURCE_ACTIVE) begin
        cq = null;
        finish_result(result, invalid_state("typed CQ projection is invalid"));
      end
    end
  endtask

  // 功能：创建 SRQ，经 create_queue_facade 完成事务并校验返回资源。
  // 输入/输出及副作用：binding、request 为输入；srq 输出 ACTIVE 资源，result 输出事务结果。
  // 失败/边界：失败或类型/状态不符时 srq 为 null，错误经 result 发布。
  task create_srq(
    rdma_function_binding binding,
    rdma_create_srq_req request,
    output rdma_srq srq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    srq = null;
    create_queue_facade(binding, request, 1'b1, RDMA_RESOURCE_SRQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(srq, queue) || srq == null || srq.state != RDMA_RESOURCE_ACTIVE) begin
        srq = null;
        finish_result(result, invalid_state("typed SRQ projection is invalid"));
      end
    end
  endtask

  // 功能：创建 CEQ，经 create_queue_facade 完成事务并校验返回资源。
  // 输入/输出及副作用：binding、request 为输入；ceq 输出 ACTIVE 资源，result 输出事务结果。
  // 失败/边界：失败或类型/状态不符时 ceq 为 null，错误经 result 发布。
  task create_ceq(
    rdma_function_binding binding,
    rdma_create_ceq_req request,
    output rdma_ceq ceq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    ceq = null;
    create_queue_facade(binding, request, 1'b0, RDMA_RESOURCE_CEQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(ceq, queue) || ceq == null || ceq.state != RDMA_RESOURCE_ACTIVE) begin
        ceq = null;
        finish_result(result, invalid_state("typed CEQ projection is invalid"));
      end
    end
  endtask

  // 功能：创建 AEQ，经 create_queue_facade 完成事务并校验返回资源。
  // 输入/输出及副作用：binding、request 为输入；aeq 输出 ACTIVE 资源，result 输出事务结果。
  // 失败/边界：失败或类型/状态不符时 aeq 为 null，错误经 result 发布。
  task create_aeq(
    rdma_function_binding binding,
    rdma_create_aeq_req request,
    output rdma_aeq aeq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    aeq = null;
    create_queue_facade(binding, request, 1'b0, RDMA_RESOURCE_AEQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(aeq, queue) || aeq == null || aeq.state != RDMA_RESOURCE_ACTIVE) begin
        aeq = null;
        finish_result(result, invalid_state("typed AEQ projection is invalid"));
      end
    end
  endtask

  // 功能：QP create/modify 共用的事务外壳：分配事务号，锁前/锁后校验 binding、请求与（modify 时）目标 QP 归属，
  //   在 Function 锁内调用 QP executor，并校验返回的事务号与 QP 投影（create 必须为 RESET 态）。
  // 输入/输出及副作用：request 为 create 或 modify 请求，is_modify 选择入口；qp/result 为输出，失败时 qp 为 null；
  //   退出前释放 Function 锁。
  // 失败/边界：未配置或缺 host-memory/context-backing/QP executor 返回 INVALID_STATE；校验失败沿用子检查状态；
  //   executor 改写事务号或返回非法 QP 投影返回 INVALID_STATE。
  protected task run_qp_operation(
    rdma_function_binding binding,
    rdma_semantic_request request,
    bit is_modify,
    output rdma_qp qp,
    output rdma_control_result result
  );
    rdma_create_qp_req create_request;
    rdma_modify_qp_req modify_request;
    rdma_function_handle owner;
    rdma_status status;
    rdma_status qp_validation_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    string op;
    bit executor_called;

    op = is_modify ? "QP modify" : "QP create";
    qp = null;
    result = make_result();
    function_lock = null;
    executor_called = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      `RDMA_BREAK_IF_FAILED(status, {op, " transaction ID allocation returned null"})
      status = configured_status();
      `RDMA_BREAK_IF_FAILED(status, {op, " control-plane configuration returned null"})
      if (host_mem == null || context_backing == null || qp_executor == null) begin
        status = invalid_state(
          {op, " requires host-memory, context-backing and QP executor"}
        );
        break;
      end
      admit_locked_request(binding, request,
                           is_modify ? RDMA_CTRL_TARGET_MODIFY_QP :
                                       RDMA_CTRL_TARGET_NONE,
                           RDMA_RESOURCE_QP, op, owner, function_lock, status);
      if (!status.ok())
        break;

      executor_called = 1'b1;
      if (is_modify && $cast(modify_request, request))
        qp_executor.modify_locked(binding, owner, modify_request,
                                  transaction_id, qp, result);
      else if (!is_modify && $cast(create_request, request))
        qp_executor.create_locked(binding, owner, create_request,
                                  transaction_id, qp, result);
      if (result == null) begin
        status = invalid_state({op, " executor returned a null result"});
        break;
      end
      if (result.transaction_id != transaction_id) begin
        qp = null;
        status = invalid_state({op, " executor changed the transaction ID"});
        finish_result(result, status);
        break;
      end
      status = checked_status(result.status,
                              {op, " executor result status is null"});
      if (status.ok()) begin
        qp_validation_status = qp == null ? null : qp.validate();
        if (qp == null || qp.state != RDMA_RESOURCE_ACTIVE ||
            (!is_modify && qp.qp_state != RDMA_QPS_RESET) ||
            qp_validation_status == null || !qp_validation_status.ok()) begin
          qp = null;
          status = invalid_state({"typed ", op, " projection is invalid"});
          finish_result(result, status);
        end
      end
      break;
    end while (1'b0);
    if (result == null) begin
      result = make_result();
      result.transaction_id = transaction_id;
    end
    if (status == null || !status.ok()) begin
      qp = null;
      if (!executor_called)
        finish_result(result, status);
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask


  // 功能：创建 QP：经 run_qp_operation 调用 QP executor 的 create 路径。
  // 输入/输出及副作用：request 为创建请求；qp 输出 RESET 态 ACTIVE QP，result 输出事务结果。
  // 失败/边界：失败时 qp 为 null，错误与恢复要求经 result 发布。
  task create_qp(
    rdma_function_binding binding,
    rdma_create_qp_req request,
    output rdma_qp qp,
    output rdma_control_result result
  );
    run_qp_operation(binding, request, 1'b0, qp, result);
  endtask

  // 功能：修改 QP 状态/属性：经 run_qp_operation 调用 QP executor 的 modify 路径。
  // 输入/输出及副作用：request 携带目标 qp_h；qp 输出修改后的 ACTIVE QP，result 输出事务结果。
  // 失败/边界：目标不属于 owner 或执行失败时 qp 为 null，错误与恢复要求经 result 发布。
  task modify_qp(
    rdma_function_binding binding,
    rdma_modify_qp_req request,
    output rdma_qp qp,
    output rdma_control_result result
  );
    run_qp_operation(binding, request, 1'b1, qp, result);
  endtask

  // 功能：销毁 QP，转交 destroy 事务外壳并校验目标类型。
  // 输入/输出及副作用：binding、request 为输入；result 输出事务结果。
  // 失败/边界：owner/generation 不符或目标 kind 错误时拒绝，错误经 result 发布。
  task destroy_qp(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    run_destroy_operation(binding, request, RDMA_RESOURCE_QP, 1'b1, result);
  endtask

  // 功能：销毁 CQ，转交 destroy 事务外壳并校验目标类型。
  // 输入/输出及副作用：binding、request 为输入；result 输出事务结果。
  // 失败/边界：owner/generation 不符或目标 kind 错误时拒绝，错误经 result 发布。
  task destroy_cq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_CQ, result);
  endtask

  // 功能：销毁 SRQ，转交 destroy 事务外壳并校验目标类型。
  // 输入/输出及副作用：binding、request 为输入；result 输出事务结果。
  // 失败/边界：owner/generation 不符或目标 kind 错误时拒绝，错误经 result 发布。
  task destroy_srq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_SRQ, result);
  endtask

  // 功能：销毁 CEQ，转交 destroy 事务外壳并校验目标类型。
  // 输入/输出及副作用：binding、request 为输入；result 输出事务结果。
  // 失败/边界：owner/generation 不符或目标 kind 错误时拒绝，错误经 result 发布。
  task destroy_ceq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_CEQ, result);
  endtask

  // 功能：销毁 AEQ，转交 destroy 事务外壳并校验目标类型。
  // 输入/输出及副作用：binding、request 为输入；result 输出事务结果。
  // 失败/边界：owner/generation 不符或目标 kind 错误时拒绝，错误经 result 发布。
  task destroy_aeq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_AEQ, result);
  endtask

  // 功能：创建 PD：预留、激活并回查 ACTIVE 快照。
  // 输入/输出及副作用：binding、request 为输入；pd 输出 ACTIVE PD，result 输出事务结果；
  //   经 manager.create_pd/activate/lookup。
  // 失败/边界：预留或激活失败时释放预留；激活后回查失败则清理已激活 PD；失败时 pd 为 null。
  task create_pd(
    rdma_function_binding binding,
    rdma_create_pd_req request,
    output rdma_pd pd,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_pd reserved_pd;
    rdma_resource active_resource;
    rdma_status status;
    rdma_status rollback_status;
    semaphore function_lock;
    longint unsigned transaction_id;

    pd = null;
    result = make_result();
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      `RDMA_BREAK_IF_FAILED(status, "transaction ID allocation returned null status")
      status = configured_status();
      `RDMA_BREAK_IF_FAILED(status, "control-plane configuration check returned null")
      admit_locked_request(binding, request, RDMA_CTRL_TARGET_NONE,
                           RDMA_RESOURCE_PD, "create PD", owner,
                           function_lock, status);
      if (!status.ok())
        break;
      status = manager.create_pd(binding, reserved_pd);
      `RDMA_BREAK_IF_FAILED(status, "resource manager create PD returned null")
      if (reserved_pd == null || reserved_pd.handle == null ||
          reserved_pd.state != RDMA_RESOURCE_ALLOCATED) begin
        status = invalid_state(
          "resource manager returned an invalid PD reservation"
        );
        if (reserved_pd != null && reserved_pd.handle != null) begin
          result.resource_h = snapshot_handle(reserved_pd.handle);
          result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
          result.final_resource_state_known = 1'b1;
          rollback_status = manager.release_reserved(reserved_pd.handle);
          rollback_status = checked_status(
            rollback_status, "PD reservation rollback returned null"
          );
          if (rollback_status.ok()) begin
            result.final_resource_state = RDMA_RESOURCE_RELEASED;
          end
          else
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(rollback_status)
            );
        end
        break;
      end
      result.resource_h = snapshot_handle(reserved_pd.handle);
      result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);

      status = manager.activate(reserved_pd.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager PD activate returned null");
        rollback_status = manager.release_reserved(reserved_pd.handle);
        rollback_status = checked_status(
          rollback_status, "PD reservation rollback returned null"
        );
        if (rollback_status.ok()) begin
          result.final_resource_state = RDMA_RESOURCE_RELEASED;
        end
        else begin
          result.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(rollback_status)
          );
        end
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_ACTIVE;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);

      status = manager.lookup(reserved_pd.handle, active_resource);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager active PD lookup returned null"
        );
        cleanup_activated_pd(reserved_pd.handle, result);
        break;
      end
      if (!$cast(pd, active_resource) || pd == null || pd.handle == null ||
          pd.state != RDMA_RESOURCE_ACTIVE) begin
        pd = null;
        status = invalid_state(
          "resource manager active PD snapshot is invalid"
        );
        cleanup_activated_pd(reserved_pd.handle, result);
        break;
      end
      result.resource_h = snapshot_handle(pd.handle);
      status = rdma_status::success();
    end while (1'b0);

    finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：销毁 PD：校验归属后 begin_quiesce，再 finalize_release。
  // 输入/输出及副作用：binding、pd_h 为输入；result 输出事务结果。
  // 失败/边界：PD 不存在、快照无效、owner 不符或 PD 非 ACTIVE 时拒绝，错误经 result 发布。
  task destroy_pd(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_resource resource;
    rdma_pd pd_snapshot;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;

    result = make_result();
    result.resource_h = snapshot_handle(pd_h);
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      `RDMA_BREAK_IF_FAILED(status, "transaction ID allocation returned null status")
      status = configured_status();
      `RDMA_BREAK_IF_FAILED(status, "control-plane configuration check returned null")
      status = binding_owner_status(binding, owner);
      `RDMA_BREAK_IF_FAILED(status, "Function binding check returned null")
      status = pd_handle_owner_status(pd_h, owner);
      `RDMA_BREAK_IF_FAILED(status, "destroy PD handle check returned null")

      acquire_function_lock(owner, function_lock);
      status = manager.lookup(pd_h, resource);
      `RDMA_BREAK_IF_FAILED(status, "resource manager PD lookup returned null")
      if (!$cast(pd_snapshot, resource) || pd_snapshot == null ||
          pd_snapshot.handle == null || pd_snapshot.owner == null) begin
        status = invalid_state("resource manager PD snapshot is invalid");
        break;
      end
      result.resource_h = snapshot_handle(pd_snapshot.handle);
      result.final_resource_state = pd_snapshot.state;
      result.final_resource_state_known = 1'b1;
      status = same_owner_status(pd_snapshot.owner, owner, "destroy PD");
      `RDMA_BREAK_IF_FAILED(status, "destroy PD owner check returned null")
      if (pd_snapshot.state != RDMA_RESOURCE_ACTIVE) begin
        status = invalid_state("destroy PD requires an ACTIVE PD");
        break;
      end

      status = manager.begin_quiesce(pd_snapshot.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager PD quiesce returned null"
        );
        result.final_resource_state = RDMA_RESOURCE_ACTIVE;
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_QUIESCING;

      status = manager.finalize_release(pd_snapshot.handle);
      `RDMA_BREAK_IF_FAILED(status, "resource manager PD release returned null")
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
      status = rdma_status::success();
    end while (1'b0);

    finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：注销 MR：quiesce 后依次执行硬件阶段（有 HMC 时 OCC_FLUSH、MR_DEREGISTER、TQ_FLUSH），
  //   再释放 HMC 与 owned backing，最后 finalize_release。
  // 输入/输出及副作用：binding、mr_h 为输入；result 输出事务结果。
  // 失败/边界：MR 非 ACTIVE 或 owner 不符拒绝，仍有 outstanding 返回 RESOURCE_BUSY；超时或释放失败经
  //   retain_mr_destroy_error 保留 recovery，可恢复时先 restore_active。
  task deregister_mr(
    rdma_function_binding binding,
    rdma_handle mr_h,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_resource resource;
    rdma_mr mr_snapshot;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    rdma_status primary_status;
    rdma_status cleanup_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit result_finalized;

    result = make_result();
    result.resource_h = snapshot_handle(mr_h);
    function_lock = null;
    result_finalized = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      `RDMA_BREAK_IF_FAILED(status, "deregister MR transaction ID allocation returned null")
      status = configured_status();
      `RDMA_BREAK_IF_FAILED(status, "deregister MR configuration check returned null")
      status = binding_owner_status(binding, owner);
      `RDMA_BREAK_IF_FAILED(status, "deregister MR Function check returned null")
      status = generation_fence(binding, owner);
      `RDMA_BREAK_IF_FAILED(status, "initial deregister MR generation fence returned null")
      status = mr_handle_owner_status(mr_h, owner);
      `RDMA_BREAK_IF_FAILED(status, "deregister MR handle check returned null")

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      `RDMA_BREAK_IF_FAILED(status, "post-lock deregister MR Function check returned null")
      status = generation_fence(binding, owner);
      `RDMA_BREAK_IF_FAILED(status, "post-lock deregister MR generation fence returned null")
      status = mr_handle_owner_status(mr_h, locked_owner);
      `RDMA_BREAK_IF_FAILED(status, "post-lock deregister MR handle check returned null")
      status = manager.lookup(mr_h, resource);
      `RDMA_BREAK_IF_FAILED(status, "resource manager deregister MR lookup returned null")
      if (!$cast(mr_snapshot, resource) || mr_snapshot == null ||
          mr_snapshot.handle == null || mr_snapshot.owner == null) begin
        status = invalid_state(
          "resource manager deregister MR snapshot is invalid"
        );
        break;
      end
      result.resource_h = snapshot_handle(mr_snapshot.handle);
      result.final_resource_state = mr_snapshot.state;
      result.final_resource_state_known = 1'b1;
      status = same_owner_status(
        mr_snapshot.owner, locked_owner, "deregister MR"
      );
      `RDMA_BREAK_IF_FAILED(status, "deregister MR owner check returned null")
      if (mr_snapshot.state != RDMA_RESOURCE_ACTIVE) begin
        status = invalid_state("deregister MR requires an ACTIVE MR");
        break;
      end
      if (mr_snapshot.outstanding_ids.size() != 0) begin
        status = rdma_status::make(
          RDMA_SC_RESOURCE_BUSY,
          "deregister MR has outstanding operations"
        );
        break;
      end

      status = manager.begin_quiesce(mr_snapshot.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager MR quiesce returned null"
        );
        result.final_resource_state = RDMA_RESOURCE_ACTIVE;
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_QUIESCING;

      if (mr_snapshot.hmc_refs.size() != 0) begin
        command = make_mr_hw_command(locked_owner, mr_snapshot,
                                     RDMA_CTRL_STEP_HW_OCC_FLUSHED,
                                     "deregister_mr_occ_flush");
        execute_control_command(
          command, ticket, completion, status,
          "OCC_FLUSH execution returned null"
        );
        if (!status.ok()) begin
          primary_status = rdma_cmq_clone_status_value(status);
          if (status.code == RDMA_SC_TIMEOUT) begin
            retain_mr_destroy_error(
              mr_snapshot, primary_status, result,
              RDMA_HW_PRESENCE_UNKNOWN, 1'b1,
              RDMA_CTRL_STEP_HW_OCC_FLUSHED, ticket, result_finalized
            );
          end
          else begin
            cleanup_status = manager.restore_active(mr_snapshot.handle);
            cleanup_status = checked_status(
              cleanup_status, "OCC failure restore ACTIVE returned null"
            );
            if (cleanup_status.ok()) begin
              result.final_resource_state = RDMA_RESOURCE_ACTIVE;
              status = primary_status;
            end
            else begin
              result.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(cleanup_status)
              );
              retain_mr_destroy_error(
                mr_snapshot, primary_status, result,
                RDMA_HW_PRESENCE_PRESENT, 1'b1,
                RDMA_CTRL_STEP_HW_OCC_FLUSHED, null, result_finalized
              );
            end
          end
          break;
        end
        result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED);
        status = generation_fence(binding, locked_owner);
        status = checked_status(
          status, "post-OCC_FLUSH generation fence returned null"
        );
        if (!status.ok()) begin
          primary_status = rdma_cmq_clone_status_value(status);
          retain_mr_destroy_error(
            mr_snapshot, primary_status, result,
            RDMA_HW_PRESENCE_PRESENT, 1'b1,
            RDMA_CTRL_STEP_HW_MR_DEREGISTERED, null, result_finalized
          );
          break;
        end
      end

      command = make_mr_hw_command(locked_owner, mr_snapshot,
                                   RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
                                   "deregister_mr_command");
      execute_control_command(
        command, ticket, completion, status,
        "MR_DEREGISTER execution returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        if (status.code == RDMA_SC_TIMEOUT) begin
          retain_mr_destroy_error(
            mr_snapshot, primary_status, result,
            RDMA_HW_PRESENCE_UNKNOWN, 1'b1,
            RDMA_CTRL_STEP_HW_MR_DEREGISTERED, ticket, result_finalized
          );
        end
        else begin
          cleanup_status = manager.restore_active(mr_snapshot.handle);
          cleanup_status = checked_status(
            cleanup_status,
            "MR_DEREGISTER failure restore ACTIVE returned null"
          );
          if (cleanup_status.ok()) begin
            result.final_resource_state = RDMA_RESOURCE_ACTIVE;
            status = primary_status;
          end
          else begin
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(cleanup_status)
            );
            retain_mr_destroy_error(
              mr_snapshot, primary_status, result,
              RDMA_HW_PRESENCE_PRESENT, 1'b1,
              RDMA_CTRL_STEP_HW_MR_DEREGISTERED, null,
              result_finalized
            );
          end
        end
        break;
      end
      result.completed_steps.push_back(
        RDMA_CTRL_STEP_HW_MR_DEREGISTERED
      );
      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "post-MR_DEREGISTER generation fence returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_HW_DRAINED, null, result_finalized
        );
        break;
      end

      command = make_mr_hw_command(locked_owner, mr_snapshot,
                                   RDMA_CTRL_STEP_HW_DRAINED,
                                   "deregister_mr_tq_flush");
      execute_control_command(
        command, ticket, completion, status,
        "TQ_FLUSH execution returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_HW_DRAINED,
          (status.code == RDMA_SC_TIMEOUT) ? ticket : null,
          result_finalized
        );
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "post-TQ_FLUSH generation fence returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null, result_finalized
        );
        break;
      end

      for (int i = int'(mr_snapshot.hmc_refs.size()) - 1;
           i >= 0; i--) begin
        if (mr_snapshot.hmc_refs[i] == null) begin
          status = invalid_state("deregister MR HMC reference is null");
          break;
        end
        if (mr_snapshot.hmc_refs[i].ownership !=
              RDMA_OWNERSHIP_CONTROL_PLANE ||
            mr_snapshot.hmc_refs[i].release_complete)
          continue;
        if (hmc_allocator == null)
          status = invalid_state(
            "owned deregister MR HMC allocator is unavailable"
          );
        else
          status = hmc_allocator.\release (
            mr_snapshot.hmc_refs[i].owner,
            mr_snapshot.hmc_refs[i].object_kind,
            mr_snapshot.hmc_refs[i].address
          );
        status = checked_status(
          status, "owned deregister MR HMC release returned null"
        );
        if (!status.ok())
          break;
        mr_snapshot.hmc_refs[i].release_complete = 1'b1;
      end
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null,
          result_finalized
        );
        break;
      end

      for (int i = int'(mr_snapshot.backing_refs.size()) - 1;
           i >= 0; i--) begin
        if (mr_snapshot.backing_refs[i] == null ||
            mr_snapshot.backing_refs[i].mapping == null) begin
          status = invalid_state(
            "deregister MR backing reference is null"
          );
          break;
        end
        if (mr_snapshot.backing_refs[i].ownership !=
              RDMA_OWNERSHIP_CONTROL_PLANE ||
            mr_snapshot.backing_refs[i].release_complete)
          continue;
        if (host_mem == null)
          status = invalid_state(
            "owned deregister MR host memory is unavailable"
          );
        else
          status = host_mem.\release (
            mr_snapshot.backing_refs[i].mapping
          );
        status = checked_status(
          status, "owned deregister MR backing release returned null"
        );
        if (!status.ok())
          break;
        mr_snapshot.backing_refs[i].release_complete = 1'b1;
      end
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null,
          result_finalized
        );
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);

      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "pre-finalize MR generation fence returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null, result_finalized
        );
        break;
      end

      status = manager.finalize_release(mr_snapshot.handle);
      status = checked_status(
        status, "resource manager MR release returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null,
          result_finalized
        );
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
      status = rdma_status::success();
    end while (1'b0);

    if (!result_finalized)
      finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：MR 注册的内部实现：冻结请求与 backing，预留 MR、派生 STAG key、发出硬件命令，
  //   再 commit_programmed 并 activate。
  // 输入/输出及副作用：required_ownership 区分 borrowed/owned backing；supplied_transaction_id
  //   与 supplied_function_lock 非空时沿用调用方的事务号与锁；mr、result 为输出。
  // 失败/边界：任一步失败经 rollback_mr_creation 回滚，硬件超时或回滚失败经 finalize_mr_recovery 发布 RECOVERY_REQUIRED。
  protected task register_mr_internal(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_resource_ownership_e required_ownership,
    longint unsigned supplied_transaction_id,
    semaphore supplied_function_lock,
    output rdma_mr mr,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_function_handle live_owner;
    rdma_register_mr_req frozen_request;
    rdma_mr_backing_desc frozen_backing;
    rdma_resource pd_resource;
    rdma_pd pd_snapshot;
    rdma_mr reserved_mr;
    rdma_resource active_resource;
    rdma_mrt_model mrt;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_recovery_record recovery;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;
    longint unsigned live_lease_size;
    bit [7:0] stag_key;
    bit has_remote_access;
    bit result_finalized;
    bit function_lock_acquired_here;

    mr = null;
    result = make_result();
    function_lock = supplied_function_lock;
    result_finalized = 1'b0;
    function_lock_acquired_here = 1'b0;
    transaction_id = supplied_transaction_id;
    if (transaction_id == 0)
      reserve_transaction_id(transaction_id, status);
    else
      status = rdma_status::success();
    result.transaction_id = transaction_id;

    do begin
      `RDMA_BREAK_IF_FAILED(status, "transaction ID allocation returned null status")
      status = configured_status();
      `RDMA_BREAK_IF_FAILED(status, "control-plane configuration check returned null")
      status = binding_owner_status(binding, owner);
      `RDMA_BREAK_IF_FAILED(status, "Function binding check returned null")
      status = register_mr_input_status(binding, request, backing, owner,
                                        owner, required_ownership, "");
      if (!status.ok())
        break;

      if (function_lock == null) begin
        acquire_function_lock(owner, function_lock);
        function_lock_acquired_here = 1'b1;
      end
      status = binding_owner_status(binding, locked_owner);
      `RDMA_BREAK_IF_FAILED(status, "post-lock Function binding check returned null")
      status = register_mr_input_status(binding, request, backing, owner,
                                        locked_owner, required_ownership,
                                        "post-lock ");
      if (!status.ok())
        break;

      status = detach_mr_request(request, frozen_request);
      if (!status.ok())
        break;
      status = detach_mr_backing(backing, frozen_backing);
      if (!status.ok())
        break;
      status = register_mr_input_status(binding, frozen_request,
                                        frozen_backing, null, locked_owner,
                                        required_ownership, "snapshot ");
      if (!status.ok())
        break;

      status = manager.lookup(frozen_request.pd_h, pd_resource);
      `RDMA_BREAK_IF_FAILED(status, "resource manager PD lookup returned null")
      if (!$cast(pd_snapshot, pd_resource) || pd_snapshot == null ||
          pd_snapshot.handle == null || pd_snapshot.owner == null ||
          pd_snapshot.state != RDMA_RESOURCE_ACTIVE) begin
        status = invalid_state("register MR requires an ACTIVE PD");
        break;
      end
      status = same_owner_status(pd_snapshot.owner, locked_owner,
                                 "register MR PD");
      `RDMA_BREAK_IF_FAILED(status, "register MR PD owner check returned null")

      status = manager.create_mr(binding, frozen_request.pd_h, reserved_mr);
      `RDMA_BREAK_IF_FAILED(status, "resource manager create MR returned null")
      if (reserved_mr == null || reserved_mr.handle == null ||
          reserved_mr.state != RDMA_RESOURCE_ALLOCATED) begin
        status = invalid_state(
          "resource manager returned an invalid MR reservation"
        );
        break;
      end
      result.resource_h = snapshot_handle(reserved_mr.handle);
      result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);

      reserved_mr.iova = frozen_request.iova;
      reserved_mr.length = frozen_request.length;
      reserved_mr.access = frozen_request.access;
      reserved_mr.mr_serial = reserved_mr.handle.object_id[11:0];
      reserved_mr.backing_refs = frozen_backing.backing_refs;
      reserved_mr.hmc_refs = frozen_backing.hmc_refs;
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_ATTACHED);
      if (reserved_mr.hmc_refs.size() != 0)
        result.completed_steps.push_back(RDMA_CTRL_STEP_HMC_ATTACHED);
      status = key_policy.derive(reserved_mr, stag_key);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "STAG key policy returned null status");
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b0, 1'b0, mr, result_finalized);
        break;
      end
      reserved_mr.lkey = {reserved_mr.local_mr_id[23:0], stag_key};
      has_remote_access = frozen_request.access.remote_read ||
                          frozen_request.access.remote_write ||
                          frozen_request.access.remote_atomic;
      reserved_mr.rkey = has_remote_access ? reserved_mr.lkey : 32'b0;
      status = manager.stage_allocated(reserved_mr);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager stage MR returned null");
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b0, 1'b0, mr, result_finalized);
        break;
      end

      mrt = rdma_mrt_model::type_id::create("register_mr_mrt");
      mrt.mr_h = project_handle(reserved_mr.handle,
                                reserved_mr.local_mr_id,
                                RDMA_RESOURCE_MR);
      mrt.pd_h = project_handle(pd_snapshot.handle,
                                pd_snapshot.local_pd_id,
                                RDMA_RESOURCE_PD);
      mrt.state = RDMA_MR_STATE_VALID;
      mrt.iova = reserved_mr.iova;
      mrt.length = reserved_mr.length;
      mrt.lkey = reserved_mr.lkey;
      mrt.rkey = reserved_mr.rkey;
      mrt.access = reserved_mr.access;
      mrt.object_type = 2'b0;
      mrt.page_layout = rdma_clone_mr_page_layout_value(
        frozen_backing.page_layout, "register MR"
      );
      if (mrt.page_layout != null)
        mrt.page_layout.mr_serial = reserved_mr.mr_serial;

      command = rdma_make_cmq_command(
        locked_owner, RDMA_OP_KEY_ALLOC, "key_alloc", mrt, default_timeout,
        "register_mr_key_alloc"
      );

      execute_control_command_raw_status(
        command, ticket, completion, status
      );
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "KEY_ALLOC execution returned null status");
        if (status.code == RDMA_SC_TIMEOUT) begin
          recovery = rdma_recovery_record::type_id::create(
            "register_mr_timeout_recovery"
          );
          recovery.resource_h = snapshot_handle(reserved_mr.handle);
          recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
          recovery.completed_steps = result.completed_steps;
          recovery.pending_steps.push_back(
            RDMA_CTRL_STEP_HW_KEY_ALLOCATED
          );
          recovery.backing_refs = reserved_mr.backing_refs;
          recovery.hmc_refs = reserved_mr.hmc_refs;
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "register MR timeout recovery"
          );
          recovery.primary_status = rdma_cmq_clone_status_value(status);
          finalize_mr_recovery(reserved_mr, recovery, status, result, mr,
                               result_finalized);
          break;
        end
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b0, 1'b0, mr, result_finalized);
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_KEY_ALLOCATED);

      status = binding_owner_status(binding, live_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-KEY_ALLOC Function binding check returned null"
        );
      end
      else begin
        status = generation_fence(binding, locked_owner);
        status = checked_status(
          status, "post-KEY_ALLOC generation fence returned null"
        );
      end
      if (status.ok()) begin
        foreach (frozen_backing.hmc_refs[i]) begin
          status = hmc_allocator.lookup(
            locked_owner, frozen_backing.hmc_refs[i].object_kind,
            frozen_backing.hmc_refs[i].address, live_lease_size
          );
          status = checked_status(
            status, "post-KEY_ALLOC HMC lookup returned null"
          );
          if (!status.ok())
            break;
          if (live_lease_size != frozen_backing.hmc_refs[i].size) begin
            status = invalid_argument(
              "post-KEY_ALLOC HMC lease size does not match"
            );
            break;
          end
        end
      end
      if (!status.ok()) begin
        recovery = rdma_recovery_record::type_id::create(
          "register_mr_post_cmq_recovery"
        );
        recovery.resource_h = snapshot_handle(reserved_mr.handle);
        recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
        recovery.completed_steps = result.completed_steps;
        recovery.pending_steps.push_back(
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED
        );
        recovery.backing_refs = reserved_mr.backing_refs;
        recovery.hmc_refs = reserved_mr.hmc_refs;
        recovery.primary_status = rdma_cmq_clone_status_value(status);
        finalize_mr_recovery(reserved_mr, recovery, status, result, mr,
                             result_finalized);
        break;
      end

      status = manager.commit_programmed(reserved_mr);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager MR commit returned null"
        );
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b1, 1'b0, mr, result_finalized);
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_PROGRAMMED);

      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "pre-activate MR generation fence returned null"
      );
      if (!status.ok()) begin
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b1, 1'b1, mr, result_finalized);
        break;
      end

      status = manager.activate(reserved_mr.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager MR activate returned null");
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b1, 1'b1, mr, result_finalized);
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_ACTIVE;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);

      status = manager.lookup(reserved_mr.handle, active_resource);
      `RDMA_BREAK_IF_FAILED(status, "resource manager active MR lookup returned null")
      if (!$cast(mr, active_resource) || mr == null || mr.handle == null ||
          mr.state != RDMA_RESOURCE_ACTIVE) begin
        mr = null;
        status = invalid_state(
          "resource manager active MR snapshot is invalid"
        );
        break;
      end
      result.resource_h = snapshot_handle(mr.handle);
      status = rdma_status::success();
    end while (1'b0);

    if (!result_finalized)
      finish_result(result, status);
    if (function_lock_acquired_here && function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：注册借用（borrowed）backing 的 MR。
  // 输入/输出及副作用：binding、request、backing 为输入；mr、result 为输出；转交 register_mr_internal。
  // 失败/边界：错误与恢复要求经 result 发布。
  task register_mr(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    output rdma_mr mr,
    output rdma_control_result result
  );
    register_mr_internal(binding, request, backing,
                         RDMA_OWNERSHIP_BORROWED, 0, null, mr, result);
  endtask

  // 功能：为 owned MR 从 host_mem 分配 backing 并注册。
  // 输入/输出及副作用：dma_context、alignment 为输入；mapping、mr、result 为输出；分配后转交 register_mr_internal。
  // 失败/边界：alignment 须为不小于 4096 的 2 的幂；适配器缺失或分配结果无效返回错误；注册失败时释放未挂接的 mapping，
  //   释放也失败则返回 RECOVERY_REQUIRED。
  task alloc_and_register_mr(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_dma_request_context dma_context,
    int unsigned alignment,
    output rdma_dma_mapping mapping,
    output rdma_mr mr,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_register_mr_req frozen_request;
    rdma_dma_request_context frozen_context;
    rdma_dma_mapping allocated_mapping;
    rdma_mr_backing_desc backing;
    rdma_backing_ref backing_ref;
    rdma_status status;
    rdma_status release_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit ownership_transferred;
    bit registration_started;

    mapping = null;
    mr = null;
    result = make_result();
    allocated_mapping = null;
    function_lock = null;
    ownership_transferred = 1'b0;
    registration_started = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      `RDMA_BREAK_IF_FAILED(status, "transaction ID allocation returned null status")
      status = configured_status();
      `RDMA_BREAK_IF_FAILED(status, "control-plane configuration check returned null")
      status = binding_owner_status(binding, owner);
      `RDMA_BREAK_IF_FAILED(status, "Function binding check returned null")
      if (alignment < 4096 ||
          (alignment & (alignment - 1'b1)) != 0) begin
        status = invalid_argument(
          "owned MR alignment must be a power of two of at least 4096"
        );
        break;
      end
      status = owned_mr_input_status(binding, request, dma_context, owner, "");
      if (!status.ok())
        break;
      if (host_mem == null) begin
        status = invalid_state(
          "owned MR host memory adapter is unavailable"
        );
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      `RDMA_BREAK_IF_FAILED(status, "post-lock owned MR Function binding check returned null")
      status = same_owner_status(
        locked_owner, owner, "post-lock owned MR Function binding"
      );
      `RDMA_BREAK_IF_FAILED(status, "post-lock owned MR Function identity check returned null")
      status = owned_mr_input_status(binding, request, dma_context,
                                     locked_owner, "post-lock ");
      if (!status.ok())
        break;

      status = detach_mr_request(request, frozen_request);
      if (!status.ok())
        break;
      status = detach_dma_context(dma_context, frozen_context);
      if (!status.ok())
        break;
      status = owned_mr_input_status(binding, frozen_request, frozen_context,
                                     locked_owner, "snapshot ");
      if (!status.ok())
        break;
      // 保留调用方选定的 MR IOVA。分配契约无法指定 IOVA，故内部 backing 校验须证明返回的 mapping
      // 覆盖 request.iova，而不是悄悄改写它。
      status = host_mem.allocate(
        frozen_context, frozen_request.length, alignment,
        required_dma_direction(frozen_request.access), allocated_mapping
      );
      status = checked_status(
        status, "owned MR host memory allocation returned null"
      );
      if (!status.ok())
        break;
      if (allocated_mapping == null ||
          allocated_mapping.state != RDMA_MAPPING_ACTIVE ||
          allocated_mapping.owner_h != null) begin
        status = invalid_state(
          "owned MR host memory allocation is invalid"
        );
        break;
      end

      backing = rdma_mr_backing_desc::type_id::create(
        "allocated_mr_backing"
      );
      backing.function_h = rdma_clone_function_handle_value(
        frozen_context.function_h, "allocated MR backing"
      );
      backing.requester_bdf = frozen_context.requester_bdf;
      backing.pasid_valid = frozen_context.pasid_valid;
      backing.pasid = frozen_context.pasid;
      backing_ref = rdma_backing_ref::type_id::create(
        "allocated_mr_backing_ref"
      );
      backing_ref.mapping = allocated_mapping;
      backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
      backing_ref.release_complete = 1'b0;
      backing.backing_refs.push_back(backing_ref);
      backing.page_layout.pbl_mode = RDMA_MR_PBL0;
      backing.page_layout.host_page_size = RDMA_MR_PAGE_4K;
      backing.page_layout.pba0 = allocated_mapping.backing_addr;
      backing.page_layout.pba1 = '0;
      backing.page_layout.first_pbl_index = 0;
      backing.page_layout.address_mode = RDMA_MR_ADDRESS_VA_BASED;
      backing.page_layout.odp = 1'b0;

      registration_started = 1'b1;
      register_mr_internal(
        binding, frozen_request, backing, RDMA_OWNERSHIP_CONTROL_PLANE,
        transaction_id, function_lock, mr, result
      );
      foreach (result.completed_steps[i])
        if (result.completed_steps[i] == RDMA_CTRL_STEP_BACKING_ATTACHED)
          ownership_transferred = 1'b1;
      if (result.ok())
        mapping = allocated_mapping;
    end while (1'b0);

    if (!registration_started)
      finish_result(result, status);
    if (allocated_mapping != null && !ownership_transferred) begin
      release_status = host_mem.\release (allocated_mapping);
      release_status = checked_status(
        release_status, "unattached owned MR release returned null"
      );
      if (!release_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(release_status)
        );
        result.status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "unattached owned MR mapping requires caller recovery"
        );
        result.recovery_required = 1'b0;
        result.final_resource_state = RDMA_RESOURCE_NEW;
        result.final_resource_state_known = 1'b0;
        mapping = allocated_mapping;
      end
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：在 recovery.pending_steps 中按持久化顺序找出第一个硬件阶段。
  // 输入/输出及副作用：recovery 只读；step 输出（默认 RESOURCE_RESERVED，命中时为该硬件 step）；返回是否找到。
  // 失败/边界：recovery 为空或无硬件阶段返回 0；不校验 recovery 的其它 authority，调用方仍须按原顺序执行门禁。
  protected function bit first_pending_hardware_step(
    rdma_recovery_record recovery,
    output rdma_control_step_e step
  );
    step = RDMA_CTRL_STEP_RESOURCE_RESERVED;
    if (recovery == null)
      return 1'b0;
    foreach (recovery.pending_steps[i]) begin
      if (rdma_control_step_is_hardware(recovery.pending_steps[i])) begin
        step = recovery.pending_steps[i];
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 功能：检查 recovery 的 completed_steps 或 pending_steps 中是否含硬件阶段。
  // 输入/输出及副作用：recovery 只读；inspect_completed 为 1 扫描 completed_steps，否则扫描 pending_steps；返回 bit。
  // 失败/边界：recovery 为空或所选数组无硬件阶段返回 0；不校验顺序或 hardware_presence。
  protected function bit recovery_has_hardware_step(
    rdma_recovery_record recovery,
    bit inspect_completed
  );
    if (recovery == null)
      return 1'b0;
    if (inspect_completed) begin
      foreach (recovery.completed_steps[i]) begin
        if (rdma_control_step_is_hardware(recovery.completed_steps[i]))
          return 1'b1;
      end
    end
    else begin
      foreach (recovery.pending_steps[i]) begin
        if (rdma_control_step_is_hardware(recovery.pending_steps[i]))
          return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 功能：判断 ERROR MR 的 recovery 是否满足“仅本地预留待释放”的快速路径形状。
  // 输入/输出及副作用：recovery 只读；返回 bit，不修改任何状态。
  // 失败/边界：硬件存在或未知、有 ambiguous ticket、有 HMC 引用、backing 非单个 control-plane 拥有、
  //   pending 不是 BACKING_RELEASED/RESOURCE_RELEASED 或 completed 含硬件阶段时返回 0；不检查 owner/generation。
  protected function bit recovery_is_reserved_only(
    rdma_recovery_record recovery
  );
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.ambiguous_ticket != null ||
        recovery.hmc_refs.size() != 0 ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        recovery.pending_steps.size() != 1 ||
        !(recovery.pending_steps[0] inside {
          RDMA_CTRL_STEP_BACKING_RELEASED,
          RDMA_CTRL_STEP_RESOURCE_RELEASED
        }))
      return 1'b0;
    return !recovery_has_hardware_step(recovery, 1'b1);
  endfunction

  // 功能：持久化 recovery 进度，失败时重试一次。
  // 输入/输出及副作用：resource_h、recovery 为输入；调用 manager.mark_error，失败状态追加到 recovery.rollback_statuses。
  // 失败/边界：首次成功即返回；重试仍失败时返回重试的 status。
  protected function rdma_status persist_recovery_record(
    rdma_handle resource_h,
    rdma_recovery_record recovery
  );
    rdma_status first_status;
    rdma_status retry_status;

    first_status = manager.mark_error(resource_h, recovery);
    first_status = checked_status(
      first_status, "recovery progress persistence returned null"
    );
    if (first_status.ok())
      return first_status;

    recovery.rollback_statuses.push_back(
      rdma_cmq_clone_status_value(first_status)
    );
    retry_status = manager.mark_error(resource_h, recovery);
    retry_status = checked_status(
      retry_status, "recovery progress retry returned null"
    );
    if (!retry_status.ok())
      recovery.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(retry_status)
      );
    return first_status;
  endfunction

  // 功能：记录一次 recovery 失败并发布 RECOVERY_REQUIRED。
  // 输入/输出及副作用：resource_h、recovery、failure、result、message 为输入；追加失败状态、持久化 recovery 并更新 result。
  // 失败/边界：持久化失败且尚无记录时补记该失败。
  protected function void retain_recovery_failure(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_status failure,
    rdma_control_result result,
    string message
  );
    rdma_status persist_status;

    recovery.rollback_statuses.push_back(
      checked_status(failure, "recovery failure status is null")
    );
    persist_status = persist_recovery_record(resource_h, recovery);
    if (!persist_status.ok() && recovery.rollback_statuses.size() == 0)
      recovery.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(persist_status)
      );
    rdma_recovery_publish_required(recovery, result, message);
  endfunction

  // 功能：判断 destroy 的 recovery 是否可直接 restore_active。
  // 输入/输出及副作用：recovery 只读；返回 bit。
  // 失败/边界：硬件非 PRESENT、有 ambiguous ticket、仍有 pending，或 completed 超出“空或仅 OCC_FLUSHED”时返回 0。
  protected function bit destroy_recovery_restore_ready(
    rdma_recovery_record recovery
  );
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.ambiguous_ticket != null ||
        recovery.pending_steps.size() != 0)
      return 1'b0;
    return recovery.completed_steps.size() == 0 ||
           (recovery.completed_steps.size() == 1 &&
            recovery.completed_steps[0] == RDMA_CTRL_STEP_HW_OCC_FLUSHED);
  endfunction

  // 功能：把 destroy 失败的 MR 恢复为 ACTIVE。
  // 输入/输出及副作用：resource_h、recovery、result 为输入；调用 manager.restore_active，成功时更新 result 为 ACTIVE。
  // 失败/边界：restore 失败时经 retain_recovery_failure 保留 recovery 并发布 RECOVERY_REQUIRED。
  protected function void restore_destroy_recovery(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_control_result result
  );
    rdma_status status;

    status = manager.restore_active(resource_h);
    status = checked_status(
      status, "destroy recovery restore ACTIVE returned null"
    );
    if (!status.ok()) begin
      retain_recovery_failure(
        resource_h, recovery, status, result,
        "destroy MR still requires ACTIVE restoration"
      );
      return;
    end
    rdma_recovery_project_history(recovery, result);
    result.status = rdma_status::success();
    result.final_resource_state = RDMA_RESOURCE_ACTIVE;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b0;
  endfunction

  // 设计说明：仅预留的 ERROR MR 使用 resource manager 的原子 complete 迁移；在 complete_reserved_error()
  // 成功前不得发布本地 RELEASED 映射——适配器的 opaque release seal 是使重试幂等的持久证据。
  // 功能：恢复仅预留的 ERROR MR：必要时释放 owned backing，再原子完成 reserved error。
  // 输入/输出及副作用：resource_h、recovery、result 为输入；经 host_mem release 与 manager 迁移，更新 result。
  // 失败/边界：适配器缺失、释放失败、lookup 失败或锁/超时/generation 变化时保持原状态，并持久化失败后发布 RECOVERY_REQUIRED。
  protected function void recover_reserved_error(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_control_result result
  );
    rdma_recovery_record durable_recovery;
    rdma_status status;
    rdma_status lookup_status;
    rdma_status persist_status;
    bit backing_release_pending;
    bit release_complete;

    backing_release_pending = recovery.pending_steps[0] ==
      RDMA_CTRL_STEP_BACKING_RELEASED;
    status = rdma_status::success();
    if (backing_release_pending) begin
      if (host_mem == null)
        status = invalid_state(
          "reserved recovery host memory adapter is unavailable"
        );
      else begin
        foreach (recovery.backing_refs[i]) begin
          if (recovery.backing_refs[i] == null ||
              recovery.backing_refs[i].ownership !=
                RDMA_OWNERSHIP_CONTROL_PLANE ||
              recovery.backing_refs[i].mapping == null) begin
            status = invalid_state(
              "reserved recovery backing authority is incomplete"
            );
            break;
          end
          status = manager.query_owned_release_completion(
            recovery.backing_refs[i].mapping, release_complete
          );
          status = checked_status(
            status, "reserved recovery completion query returned null"
          );
          if (!status.ok())
            break;
          if (!release_complete) begin
            status = host_mem.\release (
              recovery.backing_refs[i].mapping
            );
            status = checked_status(
              status, "reserved recovery backing release returned null"
            );
            if (!status.ok())
              break;
            status = manager.query_owned_release_completion(
              recovery.backing_refs[i].mapping, release_complete
            );
            status = checked_status(
              status, "post-release completion query returned null"
            );
            if (!status.ok())
              break;
            if (!release_complete) begin
              status = invalid_state(
                "host memory release did not seal completion"
              );
              break;
            end
          end
        end
      end
    end

    if (status.ok()) begin
      status = manager.complete_reserved_error(resource_h);
      status = checked_status(
        status, "reserved ERROR completion returned null"
      );
    end
    if (!status.ok()) begin
      // 成功的 host release 只改变这份工作副本；追加新失败前先刷新权威记录，
      // 使重试保持 reserved-error 形状并消费 opaque release seal。
      durable_recovery = null;
      lookup_status = manager.lookup_recovery(
        resource_h, durable_recovery
      );
      lookup_status = checked_status(
        lookup_status, "reserved recovery refresh returned null"
      );
      if (!lookup_status.ok() || durable_recovery == null) begin
        recovery.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(status)
        );
        if (!lookup_status.ok())
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(lookup_status)
          );
        rdma_recovery_publish_required(
          recovery, result, "reserved MR still requires recovery"
        );
        return;
      end
      durable_recovery.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(status)
      );
      persist_status = persist_recovery_record(
        resource_h, durable_recovery
      );
      if (!persist_status.ok() &&
          durable_recovery.rollback_statuses.size() == 0)
        durable_recovery.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(persist_status)
        );
      rdma_recovery_publish_required(
        durable_recovery, result, "reserved MR still requires recovery"
      );
      return;
    end

    if (backing_release_pending)
      rdma_recovery_complete_step(
        recovery, RDMA_CTRL_STEP_BACKING_RELEASED
      );
    rdma_recovery_complete_step(
      recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
    );
    rdma_recovery_project_history(recovery, result);
    result.status = rdma_status::success();
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b0;
  endfunction

  // 功能：为恢复流程执行一个 pending 硬件阶段。
  // 输入/输出及副作用：error_mr、owner、step 为输入；ticket、completion、status 为输出；构造 CMQ 命令并 execute。
  // 失败/边界：error_mr 或 owner 为空返回 INVALID_STATE；step 不被支持返回 UNSUPPORTED_OPCODE。
  protected task execute_recovery_hardware_step(
    rdma_mr error_mr,
    rdma_function_handle owner,
    rdma_control_step_e step,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_cmq_command_desc command;

    ticket = null;
    completion = null;
    status = invalid_state("recovery hardware command was not executed");
    if (error_mr == null || owner == null) begin
      status = invalid_state("recovery hardware authority is incomplete");
      return;
    end

    command = make_mr_hw_command(owner, error_mr, step,
                                 "recovery_hardware_command");
    if (command == null) begin
      status = rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        "recovery pending hardware step is unsupported"
      );
      return;
    end
    execute_control_command(
      command, ticket, completion, status,
      "recovery hardware execution returned null"
    );
  endtask

  // 功能：恢复 ERROR 资源：按 recovery 记录继续硬件阶段、释放 HMC/backing 并 finalize_release；
  //   QP 与队列类资源分派给对应 executor。
  // 输入/输出及副作用：binding、resource_h 为输入；result 输出事务结果；全程在 Function 锁内。
  // 失败/边界：锁、超时、generation 变化或提交证据不完整时保持原状态；不可恢复条件继续发布 RECOVERY_REQUIRED。
  task recover_resource(
    rdma_function_binding binding,
    rdma_handle resource_h,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_resource resource;
    rdma_mr error_mr;
    rdma_queue_resource error_queue;
    rdma_recovery_record recovery;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    rdma_status completion_status;
    rdma_status persist_status;
    rdma_status reconcile_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    longint unsigned lease_size;
    rdma_control_step_e pending_hardware_step;
    bit terminal_known;
    bit release_complete;
    bit creation_origin;
    bit has_hardware_pending;
    bit reserved_only;
    bit result_finalized;
    bit defer_terminal_retry;

    result = make_result();
    function_lock = null;
    result_finalized = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    result.resource_h = snapshot_handle(resource_h);

    do begin
      `RDMA_BREAK_IF_FAILED(status, "recovery transaction ID allocation returned null")
      status = configured_status();
      `RDMA_BREAK_IF_FAILED(status, "recovery configuration check returned null")
      status = binding_owner_status(binding, owner);
      `RDMA_BREAK_IF_FAILED(status, "recovery Function check returned null")
      if (resource_h == null ||
          !(resource_h.kind inside {RDMA_RESOURCE_MR, RDMA_RESOURCE_QP,
                                    RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                    RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ})) begin
        status = invalid_argument("recovery handle kind is unsupported");
        break;
      end
      status = queue_target_owner_status(resource_h, owner,
                                         "recovery target");
      if (status == null || !status.ok())
        break;

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      `RDMA_BREAK_IF_FAILED(status, "post-lock recovery Function check returned null")
      status = same_owner_status(locked_owner, owner,
                                 "post-lock recovery Function");
      `RDMA_BREAK_IF_FAILED(status, "post-lock recovery Function identity returned null")
      status = manager.lookup(resource_h, resource);
      status = checked_status(status, "recovery lookup returned null");
      if (!status.ok())
        break;

      // QP recovery 使用独立的 lifecycle executor（QPC image、query-buffer authority 与有序 backing 清理
      // 不同于通用 queue/MR 恢复协议）；与 create/modify/destroy 一样在持有 Function 锁时派发。
      if (resource_h.kind == RDMA_RESOURCE_QP) begin
        rdma_qp error_qp;
        if (qp_executor == null) begin
          status = invalid_state("QP lifecycle executor is unavailable");
          break;
        end
        if (!$cast(error_qp, resource) || error_qp == null ||
            error_qp.state != RDMA_RESOURCE_ERROR) begin
          status = invalid_state("QP recovery requires an ERROR QP");
          break;
        end
        status = same_owner_status(error_qp.owner, locked_owner,
                                   "recovery QP");
        if (status == null || !status.ok())
          break;
        qp_executor.recover_locked(binding, locked_owner, resource_h,
                                   transaction_id, result);
        if (result == null) begin
          result = make_result();
          result.transaction_id = transaction_id;
          status = invalid_state("QP recovery executor returned null result");
          break;
        end
        result_finalized = 1'b1;
        break;
      end

      // 队列恢复由 queue executor 按策略执行；在持有与 create/destroy 相同的 Function 锁时派发，
      // executor 自己不分配事务号，也不再取其它锁。
      if (resource_h.kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                  RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}) begin
        if (queue_executor == null) begin
          status = invalid_state("queue lifecycle executor is unavailable");
          break;
        end
        if (!$cast(error_queue, resource) || error_queue == null ||
            error_queue.state != RDMA_RESOURCE_ERROR) begin
          status = invalid_state("recovery requires an ERROR queue");
          break;
        end
        status = same_owner_status(error_queue.owner, locked_owner,
                                   "recovery queue");
        if (status == null || !status.ok())
          break;
        queue_executor.recover_locked(
          binding, locked_owner, resource_h, transaction_id, result
        );
        if (result == null) begin
          result = make_result();
          result.transaction_id = transaction_id;
          status = invalid_state("queue recovery executor returned null result");
          break;
        end
        result_finalized = 1'b1;
        break;
      end
      if (!$cast(error_mr, resource) || error_mr == null ||
          error_mr.state != RDMA_RESOURCE_ERROR) begin
        status = invalid_state("recovery requires an ERROR MR");
        break;
      end
      result.resource_h = snapshot_handle(error_mr.handle);
      status = same_owner_status(error_mr.owner, locked_owner, "recovery MR");
      `RDMA_BREAK_IF_FAILED(status, "recovery owner check returned null")
      status = manager.lookup_recovery(resource_h, recovery);
      status = checked_status(
        status, "recovery record lookup returned null"
      );
      if (!status.ok())
        break;
      if (recovery == null || recovery.primary_status == null) begin
        status = invalid_state("ERROR MR recovery record is incomplete");
        break;
      end
      rdma_recovery_project_history(recovery, result);
      creation_origin = rdma_recovery_step_completed(
        recovery, RDMA_CTRL_STEP_RESOURCE_RESERVED
      );
      reserved_only = recovery_is_reserved_only(recovery);
      if (reserved_only) begin
        recover_reserved_error(resource_h, recovery, result);
        result_finalized = 1'b1;
        break;
      end

      if (!creation_origin &&
          destroy_recovery_restore_ready(recovery)) begin
        restore_destroy_recovery(resource_h, recovery, result);
        result_finalized = 1'b1;
        break;
      end

      if (recovery.ambiguous_ticket != null) begin
        ticket = recovery.ambiguous_ticket;
        terminal_known = 1'b0;
        completion = null;
        cmq.reconcile(ticket, terminal_known, completion,
                      reconcile_status);
        reconcile_status = checked_status(
          reconcile_status, "CMQ reconciliation returned null"
        );
        if (!terminal_known) begin
          rdma_recovery_publish_required(
            recovery, result,
            "ambiguous CMQ command has no terminal result"
          );
          if (!reconcile_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(reconcile_status)
            );
          result_finalized = 1'b1;
          break;
        end
        if (completion == null || completion.status == null) begin
          retain_recovery_failure(
            resource_h, recovery,
            invalid_state("CMQ reconciliation completion is incomplete"),
            result, "CMQ reconciliation still requires recovery"
          );
          result_finalized = 1'b1;
          break;
        end
        completion_status = checked_status(
          completion.status, "CMQ reconciliation status returned null"
        );
        if (completion_status.code == RDMA_SC_RESET_CANCELLED) begin
          rdma_recovery_publish_required(
            recovery, result,
            "reset cancellation does not prove hardware absence"
          );
          result_finalized = 1'b1;
          break;
        end

        if (ticket.opcode_key == null) begin
          retain_recovery_failure(
            resource_h, recovery,
            invalid_state("ambiguous CMQ ticket has no opcode"), result,
            "ambiguous CMQ command still requires recovery"
          );
          result_finalized = 1'b1;
          break;
        end
        defer_terminal_retry = 1'b0;
        case (ticket.opcode_key.opcode)
          RDMA_OP_KEY_ALLOC: begin
            if (!rdma_recovery_step_pending(
                  recovery, RDMA_CTRL_STEP_HW_KEY_ALLOCATED)) begin
              retain_recovery_failure(
                resource_h, recovery,
                invalid_state("KEY_ALLOC ticket has no pending step"),
                result, "ambiguous KEY_ALLOC still requires recovery"
              );
              result_finalized = 1'b1;
              break;
            end
            recovery.ambiguous_ticket = null;
            if (completion_status.ok()) begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
              rdma_recovery_complete_step(
                recovery, RDMA_CTRL_STEP_HW_KEY_ALLOCATED
              );
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
              );
            end
            else begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
              rdma_recovery_remove_pending(
                recovery, RDMA_CTRL_STEP_HW_KEY_ALLOCATED
              );
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_BACKING_RELEASED
              );
            end
          end
          RDMA_OP_OCC_FLUSH: begin
            recovery.ambiguous_ticket = null;
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            if (completion_status.ok()) begin
              rdma_recovery_complete_step(
                recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED
              );
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
              );
            end
            else begin
              if (!creation_origin)
                rdma_recovery_remove_pending(
                  recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED
                );
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
            end
          end
          RDMA_OP_MR_DEREGISTER: begin
            recovery.ambiguous_ticket = null;
            if (completion_status.ok()) begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
              rdma_recovery_complete_step(
                recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
              );
              if (creation_origin)
                rdma_recovery_queue_step(
                  recovery, RDMA_CTRL_STEP_BACKING_RELEASED
                );
              else
                rdma_recovery_queue_step(
                  recovery, RDMA_CTRL_STEP_HW_DRAINED
                );
            end
            else begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
              if (!creation_origin)
                rdma_recovery_remove_pending(
                  recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
                );
              else
                defer_terminal_retry = 1'b1;
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
            end
          end
          RDMA_OP_TQ_FLUSH: begin
            recovery.ambiguous_ticket = null;
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            if (completion_status.ok()) begin
              rdma_recovery_complete_step(
                recovery, RDMA_CTRL_STEP_HW_DRAINED
              );
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_BACKING_RELEASED
              );
            end
            else begin
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
              defer_terminal_retry = 1'b1;
            end
          end
          default: begin
            retain_recovery_failure(
              resource_h, recovery,
              rdma_status::make(
                RDMA_SC_UNSUPPORTED_OPCODE,
                "ambiguous recovery opcode is unsupported"
              ), result, "ambiguous CMQ command still requires recovery"
            );
            result_finalized = 1'b1;
          end
        endcase
        if (result_finalized)
          break;
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "reconciled CMQ progress could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
        if (defer_terminal_retry) begin
          rdma_recovery_publish_required(
            recovery, result,
            "terminal hardware failure was retained for a later retry"
          );
          result_finalized = 1'b1;
          break;
        end
        if (!creation_origin &&
            destroy_recovery_restore_ready(recovery)) begin
          restore_destroy_recovery(resource_h, recovery, result);
          result_finalized = 1'b1;
          break;
        end
      end

      while (1'b1) begin
        has_hardware_pending = first_pending_hardware_step(
          recovery, pending_hardware_step
        );
        if (!has_hardware_pending)
          break;
        if (recovery.hardware_presence == RDMA_HW_PRESENCE_UNKNOWN) begin
          rdma_recovery_publish_required(
            recovery, result,
            "unknown hardware state lacks terminal reconciliation"
          );
          result_finalized = 1'b1;
          break;
        end
        if (pending_hardware_step == RDMA_CTRL_STEP_HW_KEY_ALLOCATED) begin
          rdma_recovery_publish_required(
            recovery, result,
            "KEY_ALLOC ambiguity requires its original terminal result"
          );
          result_finalized = 1'b1;
          break;
        end

        execute_recovery_hardware_step(
          error_mr, locked_owner, pending_hardware_step,
          ticket, completion, status
        );
        if (!status.ok()) begin
          if (status.code == RDMA_SC_TIMEOUT) begin
            recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
              ticket, "recovery timeout ticket"
            );
            if (pending_hardware_step == RDMA_CTRL_STEP_HW_DRAINED)
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            else
              recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
          end
          else begin
            recovery.ambiguous_ticket = null;
            if (pending_hardware_step == RDMA_CTRL_STEP_HW_DRAINED)
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            else
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
          end
          retain_recovery_failure(
            resource_h, recovery, status, result,
            "hardware recovery step failed"
          );
          result_finalized = 1'b1;
          break;
        end

        case (pending_hardware_step)
          RDMA_CTRL_STEP_HW_OCC_FLUSHED: begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            rdma_recovery_complete_step(recovery, pending_hardware_step);
            rdma_recovery_queue_step(
              recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
            );
          end
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED: begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            rdma_recovery_complete_step(recovery, pending_hardware_step);
            if (creation_origin)
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_BACKING_RELEASED
              );
            else
              rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_DRAINED);
          end
          RDMA_CTRL_STEP_HW_DRAINED: begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            rdma_recovery_complete_step(recovery, pending_hardware_step);
            rdma_recovery_queue_step(
              recovery, RDMA_CTRL_STEP_BACKING_RELEASED
            );
          end
          default: begin
          end
        endcase
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "hardware recovery progress could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end
      if (result_finalized)
        break;

      has_hardware_pending = recovery_has_hardware_step(
        recovery, 1'b0
      );
      if (has_hardware_pending ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT) begin
        rdma_recovery_publish_required(
          recovery, result,
          "hardware absence is not yet proven"
        );
        result_finalized = 1'b1;
        break;
      end

      if (!rdma_recovery_step_pending(
            recovery, RDMA_CTRL_STEP_BACKING_RELEASED) &&
          !rdma_recovery_step_completed(
            recovery, RDMA_CTRL_STEP_BACKING_RELEASED) &&
          !rdma_recovery_step_pending(
            recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED)) begin
        rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_BACKING_RELEASED);
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "local recovery plan could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end

      if (rdma_recovery_step_pending(
            recovery, RDMA_CTRL_STEP_BACKING_RELEASED)) begin
        for (int i = int'(recovery.hmc_refs.size()) - 1; i >= 0; i--) begin
          if (recovery.hmc_refs[i] == null) begin
            status = invalid_state("recovery HMC reference is null");
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "HMC cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          if (recovery.hmc_refs[i].ownership == RDMA_OWNERSHIP_BORROWED ||
              recovery.hmc_refs[i].release_complete)
            continue;
          if (hmc_allocator == null) begin
            status = invalid_state("recovery HMC allocator is unavailable");
          end
          else begin
            status = hmc_allocator.lookup(
              recovery.hmc_refs[i].owner,
              recovery.hmc_refs[i].object_kind,
              recovery.hmc_refs[i].address, lease_size
            );
            status = checked_status(
              status, "recovery HMC lookup returned null"
            );
            if (status.ok() && lease_size != recovery.hmc_refs[i].size)
              status = invalid_state("recovery HMC lease size changed");
            if (status.ok()) begin
              status = hmc_allocator.\release (
                recovery.hmc_refs[i].owner,
                recovery.hmc_refs[i].object_kind,
                recovery.hmc_refs[i].address
              );
              status = checked_status(
                status, "recovery HMC release returned null"
              );
            end
            else if (status.code == RDMA_SC_INVALID_STATE) begin
              status = rdma_status::success(
                "recovery HMC lease was already released"
              );
            end
          end
          if (!status.ok()) begin
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "HMC cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          recovery.hmc_refs[i].release_complete = 1'b1;
          persist_status = persist_recovery_record(resource_h, recovery);
          if (!persist_status.ok()) begin
            rdma_recovery_publish_required(
              recovery, result,
              "HMC cleanup progress could not be persisted"
            );
            result_finalized = 1'b1;
            break;
          end
        end
        if (result_finalized)
          break;

        foreach (recovery.backing_refs[i]) begin
          if (recovery.backing_refs[i] == null ||
              recovery.backing_refs[i].mapping == null) begin
            status = invalid_state("recovery backing reference is null");
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "backing cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          if (recovery.backing_refs[i].ownership ==
                RDMA_OWNERSHIP_BORROWED ||
              recovery.backing_refs[i].release_complete)
            continue;
          status = manager.query_owned_release_completion(
            recovery.backing_refs[i].mapping, release_complete
          );
          status = checked_status(
            status, "recovery completion query returned null"
          );
          if (!status.ok()) begin
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "backing cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          if (!release_complete) begin
            if (host_mem == null)
              status = invalid_state(
                "recovery host memory adapter is unavailable"
              );
            else
              status = host_mem.\release (
                recovery.backing_refs[i].mapping
              );
            status = checked_status(
              status, "recovery backing release returned null"
            );
            if (!status.ok()) begin
              retain_recovery_failure(
                resource_h, recovery, status, result,
                "backing cleanup still requires recovery"
              );
              result_finalized = 1'b1;
              break;
            end
            status = manager.query_owned_release_completion(
              recovery.backing_refs[i].mapping, release_complete
            );
            status = checked_status(
              status, "post-release completion query returned null"
            );
            if (!status.ok() || !release_complete) begin
              if (status.ok())
                status = invalid_state(
                  "host memory release did not seal completion"
                );
              retain_recovery_failure(
                resource_h, recovery, status, result,
                "backing cleanup still requires recovery"
              );
              result_finalized = 1'b1;
              break;
            end
          end
          recovery.backing_refs[i].release_complete = 1'b1;
          persist_status = persist_recovery_record(resource_h, recovery);
          if (!persist_status.ok()) begin
            rdma_recovery_publish_required(
              recovery, result,
              "backing cleanup progress could not be persisted"
            );
            result_finalized = 1'b1;
            break;
          end
        end
        if (result_finalized)
          break;

        rdma_recovery_complete_step(
          recovery, RDMA_CTRL_STEP_BACKING_RELEASED
        );
        rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED);
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "backing cleanup completion could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end

      if (recovery.pending_steps.size() != 0 &&
          !rdma_recovery_step_pending(
            recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED)) begin
        retain_recovery_failure(
          resource_h, recovery,
          invalid_state("recovery contains an unsupported pending step"),
          result, "resource still requires recovery"
        );
        result_finalized = 1'b1;
        break;
      end

      if (!rdma_recovery_step_completed(
            recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED)) begin
        rdma_recovery_queue_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        rdma_recovery_complete_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "resource-release progress could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end
      if (recovery.pending_steps.size() != 0) begin
        rdma_recovery_publish_required(
          recovery, result,
          "resource still has pending recovery work"
        );
        result_finalized = 1'b1;
        break;
      end
      status = manager.finalize_release(resource_h);
      status = checked_status(
        status, "recovered ERROR final release returned null"
      );
      if (!status.ok()) begin
        rdma_recovery_remove_completed(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        rdma_recovery_queue_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        retain_recovery_failure(
          resource_h, recovery, status, result,
          "resource finalization still requires recovery"
        );
        result_finalized = 1'b1;
        break;
      end

      rdma_recovery_project_history(recovery, result);
      result.status = rdma_status::success();
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b0;
      status = rdma_status::success();
    end while (1'b0);

    if (!result_finalized && (status == null || !status.ok()))
      finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask
endclass
