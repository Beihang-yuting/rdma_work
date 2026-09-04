// 目录：核心执行层 core/rdma_stag_key_policy.sv。
// 职责：实现 rdma_stag_key_policy 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_stag_key_policy.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_stag_key_policy extends uvm_object;

  // 功能：构造 rdma_stag_key_policy，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_stag_key_policy 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_stag_key_policy");
    super.new(name);
  endfunction

  // 功能：在 rdma_stag_key_policy 中，derive 根据 STAG index、incarnation 和策略参数派生硬件 key，避免释放后旧 key 再次有效。
  // 输入/输出及副作用：mr（输入）、stag_key（输出）；derive 读取 mr、stag_key 并使用字段 name，并写入 stag_key；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：derive 无返回值，仅执行 name="rdma_incarnation_stag_key_policy")；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  pure virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
endclass

class rdma_incarnation_stag_key_policy extends rdma_stag_key_policy;
  `uvm_object_utils(rdma_incarnation_stag_key_policy)

  // 功能：构造 rdma_incarnation_stag_key_policy，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_incarnation_stag_key_policy 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_incarnation_stag_key_policy");
    super.new(name);
  endfunction

  // 功能：在 rdma_incarnation_stag_key_policy 中，derive 根据 STAG index、incarnation 和策略参数派生硬件 key，避免释放后旧 key 再次有效。
  // 输入/输出及副作用：mr（输入）、stag_key（输出）；derive 读取 mr、stag_key 并使用字段 stag_key，并写入 stag_key；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：derive 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“MR STAG key source is invalid”；失败路径不提交部分状态或转移未声明资源。
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
