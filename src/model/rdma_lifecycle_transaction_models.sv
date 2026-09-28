// 目录：模型层 model/rdma_lifecycle_transaction_models.sv。
// 职责：保存 control-plane、queue lifecycle 和 QP lifecycle 共用的 detached
//   结果初始化值，把 transaction id、业务域和“尚未完成”状态从各 executor
//   的重复样板中抽出；本文件不执行外部 I/O，也不拥有任何可变账本。
// 依赖：依赖 rdma_model_pkg 已先定义的 rdma_control_result、rdma_status 及
//   rdma_resource_state_e；只消费值模型和 status clone 工具。
// 所有权与生命周期：seed 只拥有自己的标量和字符串值；initialize_result 只向
//   调用方提供的 rdma_control_result 写入 detached 字段，不取得 result、manager、
//   CMQ、Host-memory、PCIe 或 recovery ledger 的所有权。

// 设计说明：三个生命周期 executor 都需要先发布一个可验证的“事务尚未完成”
// 结果，随后才根据具体业务推进 resource_h、completed_steps、recovery 和最终
// 状态。seed 只统一这段公共 value staging；实际错误优先级、外部调用顺序和
// mutable owner 仍由各自 executor 决定，避免把不同生命周期误合成为万能事务。
typedef enum bit [1:0] {
  RDMA_LIFECYCLE_DOMAIN_CONTROL = 2'd0,
  RDMA_LIFECYCLE_DOMAIN_QUEUE   = 2'd1,
  RDMA_LIFECYCLE_DOMAIN_QP      = 2'd2
} rdma_lifecycle_domain_e;

class rdma_lifecycle_result_seed extends uvm_object;
  `uvm_object_utils(rdma_lifecycle_result_seed)

  longint unsigned transaction_id;
  rdma_lifecycle_domain_e domain;
  string pending_message;

  // 功能：构造 lifecycle result seed，保存所属业务域、事务号和未完成诊断文案，
  //   为后续 executor 生成统一的 detached rdma_control_result 初始值。
  // 输入/输出及副作用：name（输入）；new 只初始化 transaction_id、domain 和
  //   pending_message，不访问外部对象，也不发布或回滚任何资源。
  // 失败/边界：构造函数允许 transaction_id 为 0，因为 control-plane 可能先建立
  //   默认结果再补写分配到的 id；业务入口仍须在真正提交前拒绝 0 id。
  function new(string name = "rdma_lifecycle_result_seed");
    super.new(name);
    transaction_id = 0;
    domain = RDMA_LIFECYCLE_DOMAIN_CONTROL;
    pending_message = "lifecycle operation did not complete";
  endfunction

  // 功能：validate 检查 seed 的业务域和未完成诊断文案是否可用于结果初始化，
  //   防止空文案或未知域把不完整状态发布给 caller。
  // 输入/输出及副作用：对象字段 transaction_id、domain、pending_message（输入）；
  //   返回 detached rdma_status，不修改 seed 或任何外部账本。
  // 失败/边界：domain 含未知值或 pending_message 为空时返回 RDMA_SC_INVALID_ARGUMENT；
  //   transaction_id 为 0 不在本函数拒绝范围内，交给各 executor 按原有错误优先级处理。
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

  // 功能：initialize_result 把 seed 的 transaction_id、未完成 status、初始资源状态
  //   和 recovery 标志写入调用方提供的 rdma_control_result，统一三个 executor 的
  //   事务起始语义。
  // 输入/输出及副作用：result（输出/inout）接收 detached status 和默认状态字段；
  //   seed 只读取自身值，函数不取得 result 或外部资源所有权。
  // 失败/边界：result 为空、seed 校验失败或 status clone 失败时返回明确错误并不
  //   发布半初始化结果；成功时 status/primary_status 都表示同一份“尚未完成”状态，
  //   final_resource_state 固定为 RDMA_RESOURCE_NEW、recovery_required 清零。
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
