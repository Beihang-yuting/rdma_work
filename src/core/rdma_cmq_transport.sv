// 目录：核心执行层 core/rdma_cmq_transport.sv。
// 职责：为 CMQ engine 提供无状态 doorbell 提交边界，把一次调用原样转发给
//   已绑定 scheduler，并修复无法信任的返回 envelope。
// 依赖：依赖 rdma_doorbell_scheduler、rdma_function_binding、
//   rdma_doorbell_desc 及共享 submission evidence 类型。
// 所有权与生命周期：对象只拥有 configured 标志；scheduler 是非拥有引用。
//   engine 在每次成功 prepare 中持有新 facade，reset/shutdown 后整体丢弃。

// 设计说明：该层只隔离 CMQ 与通用 scheduler 的调用契约，不缓存
//   mapping、ring、ticket、ledger、snapshot 或 recovery 状态。委托后 I/O
//   可能已经发生，因此返回
//   envelope 不能 clone，也不能把未知结果降级成 PRE_SUBMIT_REJECTED。
class rdma_cmq_transport extends uvm_object;
  `uvm_object_utils(rdma_cmq_transport)

  protected rdma_doorbell_scheduler scheduler;
  protected bit configured;

  // 功能：构造未配置的 CMQ transport facade，清空非拥有 scheduler 引用。
  // 输入/输出及副作用：name 传给 uvm_object；scheduler 置 null、
  //   configured 置零，不创建外部 adapter 或运行账本。
  // 失败/边界：configure 成功前 submit_observed 只返回 INVALID_STATE +
  //   PRE_SUBMIT_REJECTED；构造不接管 scheduler 生命周期。
  function new(string name = "rdma_cmq_transport");
    super.new(name);
    scheduler = null;
    configured = 1'b0;
  endfunction

  // 功能：直接构造完整 INVALID_STATE，供 factory 不可信或可能已发生 I/O
  //   的路径发布非空恢复证据。
  // 输入/输出及副作用：name、message 为输入；返回 new 创建的独立
  //   rdma_status，填充标准分类、严重度和空诊断上下文。
  // 失败/边界：不调用 UVM factory/clone，故 type override 不能把结果变成
  //   null 或错误类型；函数不读取或修改 scheduler。
  protected function rdma_status make_invalid_state_direct(
    string name,
    string message
  );
    rdma_status status;

    status = new(name);
    status.category = rdma_status::category_for(RDMA_SC_INVALID_STATE);
    status.code = RDMA_SC_INVALID_STATE;
    status.hardware_code = '0;
    status.hardware_code_valid = 1'b0;
    status.source_engine = RDMA_ENGINE_NONE;
    status.function_uid = '0;
    status.generation = '0;
    status.resource_id = '0;
    status.command_id = '0;
    status.wr_id = '0;
    status.severity = RDMA_SEVERITY_ERROR;
    status.retryable = 1'b0;
    status.message = message;
    return status;
  endfunction

  // 功能：一次性绑定通用 doorbell scheduler，使 CMQ 提交具有唯一转发目标。
  // 输入/输出及副作用：scheduler_arg 是非拥有输入；首次成功保存同一引用、
  //   置 configured 并返回 OK，不配置或接管 scheduler 自身 adapter。
  // 失败/边界：scheduler_arg 为 null 返回 INVALID_ARGUMENT；已配置实例返回
  //   INVALID_STATE；两个拒绝分支均保留原 scheduler/configured。
  function rdma_status configure(
    input rdma_doorbell_scheduler scheduler_arg
  );
    if (scheduler_arg == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CMQ transport scheduler is null");
    if (configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CMQ transport is already configured");

    scheduler = scheduler_arg;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：为一次 CMQ doorbell 调用预建 fail-closed envelope，再向已绑定
  //   scheduler 恰好委托一次并原样转移其 call-local result。
  // 输入/输出及副作用：binding、desc、observer 按 identity 非拥有透传；
  //   result 为每次调用输出；只有成功委托才可能驱动 scheduler 下游 I/O。
  // 失败/边界：未配置/内部 scheduler 为空时返回 INVALID_STATE +
  //   PRE_SUBMIT_REJECTED；委托后 null result 改为 INVALID_STATE +
  //   UNOBSERVED，null status 保留原 submission_effect 并直接补 INVALID_STATE。
  task submit_observed(
    input rdma_function_binding binding,
    input rdma_doorbell_desc desc,
    input rdma_doorbell_submission_observer observer,
    output rdma_doorbell_submission_result result
  );
    rdma_doorbell_submission_result fallback;

    fallback = new("cmq_transport_fallback");
    fallback.status = make_invalid_state_direct(
      "cmq_transport_fallback_status",
      "CMQ transport is not configured"
    );
    fallback.submission_effect =
      RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result = fallback;

    if (!configured || scheduler == null)
      return;

    scheduler.submit_observed(binding, desc, observer, result);
    if (result == null) begin
      fallback.status = make_invalid_state_direct(
        "cmq_transport_null_result_status",
        "CMQ transport scheduler returned null result"
      );
      fallback.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      result = fallback;
      return;
    end
    if (result.status == null)
      result.status = make_invalid_state_direct(
        "cmq_transport_null_status",
        "CMQ transport scheduler returned null status"
      );
  endtask
endclass
