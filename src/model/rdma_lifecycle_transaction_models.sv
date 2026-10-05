// 目录：模型层 model/rdma_lifecycle_transaction_models.sv。
// 职责：保存 control-plane、queue、QP lifecycle 共用的 detached 结果初始值（事务号、业务域、
//   “尚未完成”状态）；不执行外部 I/O，不拥有可变账本。
// 依赖：rdma_model_pkg 中的 rdma_control_result、rdma_status、rdma_resource_state_e。
// 所有权与生命周期：seed 只拥有自身标量和字符串；initialize_result 只向调用方传入的
//   result 写 detached 字段，不取得 result 或任何外部资源的所有权。

// 设计说明：三个生命周期 executor 都先发布“事务尚未完成”的结果，再推进具体业务。
// seed 只统一这段 value staging；错误优先级、外部调用顺序和 mutable owner 仍归各 executor。
typedef enum bit [1:0] {
  RDMA_LIFECYCLE_DOMAIN_CONTROL = 2'd0,
  RDMA_LIFECYCLE_DOMAIN_QUEUE   = 2'd1,
  RDMA_LIFECYCLE_DOMAIN_QP      = 2'd2
} rdma_lifecycle_domain_e;

class rdma_lifecycle_result_seed extends uvm_object;
  `rdma_object_utils(rdma_lifecycle_result_seed)

  longint unsigned transaction_id;
  rdma_lifecycle_domain_e domain;
  string pending_message;

  // 功能：构造 result seed，保存业务域、事务号和未完成文案。
  // 输入/输出及副作用：name 为对象名；只初始化三个字段。
  // 失败/边界：transaction_id 默认 0；业务入口须在提交前自行拒绝 0 id。
  function new(string name = "rdma_lifecycle_result_seed");
    super.new(name);
    transaction_id = 0;
    domain = RDMA_LIFECYCLE_DOMAIN_CONTROL;
    pending_message = "lifecycle operation did not complete";
  endfunction

  // 功能：检查 seed 的业务域与未完成文案是否可用。
  // 输入/输出及副作用：读取 domain、pending_message；返回新 status，不修改 seed。
  // 失败/边界：domain 未知或 pending_message 为空返回 INVALID_ARGUMENT；不检查 transaction_id。
  virtual function rdma_status validate();
    if (!(domain inside {RDMA_LIFECYCLE_DOMAIN_CONTROL,
                         RDMA_LIFECYCLE_DOMAIN_QUEUE,
                         RDMA_LIFECYCLE_DOMAIN_QP}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "lifecycle result seed domain is invalid");
    if (pending_message.len() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "lifecycle result seed message is empty");
    return rdma_status::success();
  endfunction

  // 功能：把 seed 的事务号和“未完成”状态写入 result。
  // 输入/输出及副作用：写 result 的 transaction_id、status、primary_status（各为独立 clone）、
  //   final_resource_state=NEW（known=0）、recovery_required=0。
  // 失败/边界：result 为空、seed 校验失败或 clone 失败时返回错误且不写 result。
  function rdma_status initialize_result(rdma_control_result result);
    rdma_status status;
    rdma_status pending_status;
    rdma_status detached_status;
    rdma_status detached_primary_status;

    if (result == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "lifecycle result seed target is null");
    status = validate();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "lifecycle result seed validation returned null"
      ) : status;
    pending_status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       pending_message);
    if (pending_status == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "lifecycle result seed status allocation failed");
    detached_status = rdma_cmq_clone_status_value(pending_status);
    detached_primary_status = rdma_cmq_clone_status_value(pending_status);
    if (detached_status == null || detached_primary_status == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "lifecycle result seed status clone failed");
    result.transaction_id = transaction_id;
    result.status = detached_status;
    result.primary_status = detached_primary_status;
    result.final_resource_state = RDMA_RESOURCE_NEW;
    result.final_resource_state_known = 1'b0;
    result.recovery_required = 1'b0;
    return rdma_status::success();
  endfunction
endclass
