// 目录：适配器接口层 adapter/rdma_function_table_api.sv。
// 职责：实现 rdma_function_table_api 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_function_table_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_function_table_api extends uvm_object;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_function_table_api");
    super.new(name);
  endfunction

  // 功能：把 program_notify 的配置或编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：参数 binding, status 用于执行 program_notify；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：program_notify 的后端拒绝或超时时不推进本地配置游标，ambiguous 提交必须进入恢复路径。
  pure virtual task program_notify(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  pure virtual task clear_notify(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：把 program_dmi 的配置或编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：参数 binding, status 用于执行 program_dmi；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：program_dmi 的后端拒绝或超时时不推进本地配置游标，ambiguous 提交必须进入恢复路径。
  pure virtual task program_dmi(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  pure virtual task clear_dmi(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：把 program_vft 的配置或编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：参数 binding, status 用于执行 program_vft；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：program_vft 的后端拒绝或超时时不推进本地配置游标，ambiguous 提交必须进入恢复路径。
  pure virtual task program_vft(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  pure virtual task clear_vft(
    rdma_function_binding binding,
    output rdma_status status
  );
endclass
