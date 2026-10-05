// 目录：模型层 model/rdma_reset_transaction_models.sv。
// 职责：保存 reset coordinator 在 Function epoch 递增前使用的 detached staged map，
//   与 coordinator 的可变 epoch ledger 分界。
// 依赖：rdma_reset_epoch_t 与 rdma_status；不读取 registry、Host router、lease、context。
// 所有权与生命周期：candidate 只拥有自己的 map 副本与 valid 标志；commit 后 ledger 仍由
//   coordinator 独占。

// 设计说明：各类 reset 都需先对整个 Function scope 做容量检查，再一次性替换
// m_function_epochs；candidate 只封装这份 detached map，不把 reset policy 或 router
// 副作用下放到模型层。
class rdma_reset_epoch_candidate extends uvm_object;
  `rdma_object_utils(rdma_reset_epoch_candidate)

  rdma_reset_epoch_t function_epochs[string];
  bit valid;

  // 功能：构造空 candidate，valid=false。
  // 输入/输出及副作用：name 为对象名；仅初始化本地 map/标志。
  // 失败/边界：空 candidate 不可提交，须先 capture_function_epochs() 成功。
  function new(string name = "rdma_reset_epoch_candidate");
    super.new(name);
    function_epochs.delete();
    valid = 1'b0;
  endfunction

  // 功能：把 coordinator 的 Function epoch map 复制为独立 staged snapshot。
  // 输入/输出及副作用：source 只读；成功更新 function_epochs 并置 valid。
  // 失败/边界：source 含 unknown 值返回 INVALID_ARGUMENT 且 valid=false；空 source 合法。
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

  // 功能：校验 snapshot 已建立且各 epoch 值确定。
  // 输入/输出及副作用：只读本对象；返回独立 status。
  // 失败/边界：valid=false 返回 INVALID_STATE；含 unknown epoch 返回 INVALID_ARGUMENT；空且 valid 合法。
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

  // 功能：清空 staged map 并撤销提交资格。
  // 输入/输出及副作用：删除 function_epochs，valid=false；不回写 coordinator。
  // 失败/边界：重复调用幂等；再次提交前必须重新 capture。
  function void clear();
    function_epochs.delete();
    valid = 1'b0;
  endfunction
endclass
