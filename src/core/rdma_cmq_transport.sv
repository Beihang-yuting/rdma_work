// 目录：核心执行层 core/rdma_cmq_transport.sv。
// 职责：为 CMQ engine 提供无状态 doorbell 提交边界，转发给已绑定 scheduler 并修复不可信返回。
// 依赖：rdma_doorbell_scheduler、rdma_function_binding、rdma_doorbell_desc、submission evidence。
// 所有权与生命周期：只拥有 configured 标志，scheduler 为非拥有引用；engine 每次 prepare
//   持有新 facade，reset/shutdown 后丢弃。

// 设计说明：只隔离 CMQ 与通用 scheduler 的调用契约，不缓存任何状态。委托后 I/O 可能
//   已发生，故返回 envelope 不能 clone，未知结果也不能降级成 PRE_SUBMIT_REJECTED。
class rdma_cmq_transport extends uvm_object;
  `uvm_object_utils(rdma_cmq_transport)

  protected rdma_doorbell_scheduler scheduler;
  protected bit configured;

  // 功能：构造未配置的 transport，scheduler 置 null。
  // 输入/输出及副作用：name 传给 uvm_object。
  // 失败/边界：configure 前 submit_observed 返回 INVALID_STATE + PRE_SUBMIT_REJECTED。
  function new(string name = "rdma_cmq_transport");
    super.new(name);
    scheduler = null;
    configured = 1'b0;
  endfunction

  // 功能：直接构造 INVALID_STATE status，用于可能已发生 I/O 的路径。
  // 输入/输出及副作用：name、message 为输入；返回新 rdma_status，诊断上下文清零。
  // 失败/边界：不经 UVM factory/clone，type override 不会使结果为 null；不读 scheduler。
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

  // 功能：一次性绑定 doorbell scheduler。
  // 输入/输出及副作用：scheduler_arg 为非拥有引用；成功时保存并置 configured。
  // 失败/边界：null 返回 INVALID_ARGUMENT；已配置返回 INVALID_STATE；均不改原状态。
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

  // 功能：预建 fail-closed envelope，向 scheduler 恰好委托一次并转移其 result。
  // 输入/输出及副作用：binding、desc、observer 非拥有透传；result 为输出；委托可能触发下游 I/O。
  // 失败/边界：未配置返回 INVALID_STATE + PRE_SUBMIT_REJECTED；委托后 null result 改为
  //   INVALID_STATE + UNOBSERVED；null status 保留 submission_effect 并补 INVALID_STATE。
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
