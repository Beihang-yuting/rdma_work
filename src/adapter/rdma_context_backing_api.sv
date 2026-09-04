// 目录：适配器接口层 adapter/rdma_context_backing_api.sv。
// 职责：实现 rdma_context_backing_api 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_context_backing_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_context_backing_api extends uvm_object;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_context_backing_api");
    super.new(name);
  endfunction

  // 功能：原子地预留或获取所需资源/游标，并记录后续提交所需的所有权证据（接口 acquire）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  pure virtual function rdma_status acquire(
    rdma_function_binding binding,
    rdma_resource_kind_e resource_kind,
    int unsigned local_id,
    output rdma_context_backing_ref context_ref
  );

  // RDMA_RESOURCE_QP uses the same stable contract: acquire returns an opaque
  // control-plane-owned 512-byte, 512-byte-aligned QPC slot authority.  The
  // four method signatures intentionally remain shared with CQ/SRQ backing.

  // 功能：向目标后端提交数据/事务并更新本对象的进度或账本状态（接口 write）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  pure virtual function rdma_status write(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    byte unsigned data[]
  );

  // 功能：释放、撤销或回滚当前对象持有的事务/资源，并保持账本与生命周期一致（接口 \release）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  pure virtual function rdma_status \release (rdma_context_backing_ref context_ref);

  // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 query_release_completion）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  pure virtual function rdma_status query_release_completion(
    rdma_context_backing_ref context_ref,
    output bit complete
  );
endclass
