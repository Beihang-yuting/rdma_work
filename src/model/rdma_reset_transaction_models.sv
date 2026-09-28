// 目录：模型层 model/rdma_reset_transaction_models.sv。
// 职责：保存 reset coordinator 在 Function epoch 递增前使用的 detached staged map，
//   让 reset scope 的准备阶段与 coordinator 的可变 epoch ledger 分界清晰。
// 依赖：依赖 rdma_reset_epoch_t 与 rdma_status；不读取 Function registry、Host router、
//   lease、context 或其他 integration 可变对象。
// 所有权与生命周期：candidate 只拥有自己的 associative map 副本和 valid 标志；
//   coordinator 在 commit 点前读取该副本，提交后仍由 coordinator 独占 ledger，candidate
//   不取得任何外部资源或锁的所有权。

// 设计说明：VF/PF/Host/Device reset 都需要先完成整个 Function scope 的容量检查，再一次性
//   替换 m_function_epochs。candidate 只封装这份 detached map，避免每个 reset implementation
//   重复表达“临时 map + null/unknown 检查”的生命周期，同时不把 reset policy 或 external
//   router side effect 下放到模型层。
class rdma_reset_epoch_candidate extends uvm_object;
  `uvm_object_utils(rdma_reset_epoch_candidate)

  rdma_reset_epoch_t function_epochs[string];
  bit valid;

  // 功能：构造空的 reset epoch candidate，建立未提交的 map 状态并清除 valid 标志。
  // 输入/输出及副作用：name（输入）；new 只初始化本地 map/标志，不读取或修改
  //   coordinator、Function registry、Host router 或任何外部资源。
  // 失败/边界：空 candidate 不能直接提交；调用方必须先 capture_function_epochs() 成功，
  //   即使空 scope 也要显式建立 valid=true 的 detached snapshot。
  function new(string name = "rdma_reset_epoch_candidate");
    super.new(name);
    function_epochs.delete();
    valid = 1'b0;
  endfunction

  // 功能：capture_function_epochs 将 coordinator 当前 Function epoch map 复制为独立的
  //   staged snapshot，作为后续 reset scope 的唯一 detached candidate 输入。
  // 输入/输出及副作用：source（输入）为 coordinator 只读 map；成功时更新本 candidate 的
  //   function_epochs 和 valid，不修改 source 或 coordinator ledger。
  // 失败/边界：candidate 未分配或 source 不能逐项复制时返回明确错误并保持 valid=false；
  //   空 source 合法，表示没有 Function 需要递增但 snapshot 仍已建立。
  function rdma_status capture_function_epochs(
    input rdma_reset_epoch_t source[string]
  );
    function_epochs.delete();
    foreach (source[name]) begin
      if ($isunknown(source[name])) begin
        valid = 1'b0;
        function_epochs.delete();
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "reset epoch candidate source contains an unknown value"
        );
      end
      function_epochs[name] = source[name];
    end
    valid = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：validate 检查 staged Function epoch map 是否已经建立且每个值都为确定的
  //   reset epoch，供 coordinator 在 commit 前执行 detached candidate 门禁。
  // 输入/输出及副作用：candidate 自身的 valid/function_epochs（输入）；返回独立
  //   rdma_status，不修改 candidate、coordinator 或外部 router。
  // 失败/边界：valid=false 或 map 含 unknown epoch 时返回 INVALID_STATE/INVALID_ARGUMENT；
  //   空但 valid=true 的 map 合法，不能被误判为“未建立 candidate”。
  function rdma_status validate();
    if (!valid)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset epoch candidate has not been captured"
      );
    foreach (function_epochs[name]) begin
      if ($isunknown(function_epochs[name]))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "reset epoch candidate contains an unknown value"
        );
    end
    return rdma_status::success();
  endfunction

  // 功能：clear 释放 candidate 的 staged Function map 并撤销提交资格，供 reset scope
  //   完成或失败后清理 transient evidence。
  // 输入/输出及副作用：无显式参数；只删除本对象 map 并置 valid=false，不回写 coordinator
  //   ledger，也不触碰 Host-router、lease 或 Function identity。
  // 失败/边界：重复 clear 幂等；clear 后再次 commit 前必须重新 capture，防止旧 candidate
  //   在下一次 reset 中重放。
  function void clear();
    function_epochs.delete();
    valid = 1'b0;
  endfunction
endclass
