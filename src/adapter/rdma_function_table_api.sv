// 目录：适配器接口层 adapter/rdma_function_table_api.sv。
// 职责：定义 Function table（notify/DMI/VFT）的后端编程与清除接口。
// 依赖：本层 types/model/adapter 契约。
// 所有权与生命周期：接口对象只拥有值快照；外部资源为非拥有引用，生命周期由调用方管理。

virtual class rdma_function_table_api extends uvm_object;

  // 功能：构造 rdma_function_table_api。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无；外部依赖留待上层注入。
  function new(string name = "rdma_function_table_api");
    super.new(name);
  endfunction

  // 功能：向后端适配器提交 notify 配置请求。
  // 输入/输出及副作用：binding 为输入；status 为输出；驱动下游事务。
  // 失败/边界：后端拒绝或范围/权限错误时通过 status 返回，不推进本地状态。
  pure virtual task program_notify(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：按 binding 清除 notify 配置。
  // 输入/输出及副作用：binding 为输入；status 为输出。
  // 失败/边界：owner/generation 不匹配或记录未知时返回错误或幂等结果。
  pure virtual task clear_notify(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：向后端适配器提交 DMI 配置请求。
  // 输入/输出及副作用：binding 为输入；status 为输出；驱动下游事务。
  // 失败/边界：后端拒绝或范围/权限错误时通过 status 返回，不推进本地状态。
  pure virtual task program_dmi(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：按 binding 清除 DMI 配置。
  // 输入/输出及副作用：binding 为输入；status 为输出。
  // 失败/边界：owner/generation 不匹配或记录未知时返回错误或幂等结果。
  pure virtual task clear_dmi(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：向后端适配器提交 VFT 配置请求。
  // 输入/输出及副作用：binding 为输入；status 为输出；驱动下游事务。
  // 失败/边界：后端拒绝或范围/权限错误时通过 status 返回，不推进本地状态。
  pure virtual task program_vft(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：按 binding 清除 VFT 配置。
  // 输入/输出及副作用：binding 为输入；status 为输出。
  // 失败/边界：owner/generation 不匹配或记录未知时返回错误或幂等结果。
  pure virtual task clear_vft(
    rdma_function_binding binding,
    output rdma_status status
  );
endclass
