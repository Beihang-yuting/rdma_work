// 目录/层次：核心执行层 core/rdma_stag_key_policy.sv。
// 职责：定义 STAG key 派生策略接口及取 object_id 低 8 位的默认实现。
// 依赖：依赖 types/model 层的 rdma_mr、rdma_status。
// 所有权与生命周期：策略无状态，不持有 MR；stag_key 由调用方接收。

virtual class rdma_stag_key_policy extends uvm_object;

  // 功能：构造策略对象。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_stag_key_policy");
    super.new(name);
  endfunction

  // 功能：由 MR 派生 8 位硬件 STAG key，使释放后旧 key 不再有效（纯虚接口）。
  // 输入/输出及副作用：mr 为输入；stag_key 为输出；返回 status。
  // 失败/边界：由子类定义。
  pure virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
endclass

class rdma_incarnation_stag_key_policy extends rdma_stag_key_policy;
  `uvm_object_utils(rdma_incarnation_stag_key_policy)

  // 功能：构造策略对象。
  // 输入/输出及副作用：name 为 UVM 实例名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_incarnation_stag_key_policy");
    super.new(name);
  endfunction

  // 功能：取 mr.handle.object_id[7:0] 作为 STAG key。
  // 输入/输出及副作用：mr 只读；stag_key 先清零，成功时写入 key；返回 status。
  // 失败/边界：mr、mr.handle 为空或 kind 非 MR 返回 INVALID_ARGUMENT，stag_key 保持 0。
  virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
    stag_key = '0;
    if (mr == null || mr.handle == null ||
        mr.handle.kind != RDMA_RESOURCE_MR)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR STAG key source is invalid");
    stag_key = mr.handle.object_id[7:0];
    return rdma_status::success();
  endfunction
endclass
