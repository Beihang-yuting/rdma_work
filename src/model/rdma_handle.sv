// 目录：协议与资源模型层 model/rdma_handle.sv。
// 职责：实现 rdma_handle 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_handle.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_handle extends uvm_object;
  `uvm_object_utils_begin(rdma_handle)
    `uvm_field_enum(rdma_resource_kind_e, kind, UVM_DEFAULT)
    `uvm_field_int(function_uid, UVM_DEFAULT)
    `uvm_field_int(object_id, UVM_DEFAULT)
    `uvm_field_int(generation, UVM_DEFAULT)
  `uvm_object_utils_end

  rdma_resource_kind_e kind;
  longint unsigned function_uid;
  int unsigned object_id;
  int unsigned generation;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_handle");
    super.new(name);
    kind = RDMA_RESOURCE_FUNCTION;
    function_uid = '0;
    object_id = '0;
    generation = '0;
  endfunction

  // 中文：Handle 是可复制的值快照；clone/copy 必须保留完整 owner identity，
  // 不得退化成仅有默认字段的空句柄。
  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_handle source;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_handle copy type mismatch")
    kind = source.kind;
    function_uid = source.function_uid;
    object_id = source.object_id;
    generation = source.generation;
  endfunction

  // 功能：比较两个输入对象的协议字段或身份快照并返回确定的相等性结果，不修改任一输入。
  // 输入/输出及副作用：输入为待比较的两个值对象；返回 bit/状态结果，不修改任一输入或外部账本。
  //   任一对象为空、类型不符或字段未初始化时按接口约定返回不相等或错误。
  // 失败/边界：比较输入为空或类型不符时不得抛出未处理异常；结果必须保持确定且无副作用。
  function bit same_instance(rdma_handle rhs);
    if (rhs == null)
      return 1'b0;
    return kind == rhs.kind &&
           function_uid == rhs.function_uid &&
           object_id == rhs.object_id &&
           generation == rhs.generation;
  endfunction
endclass

class rdma_function_handle extends rdma_handle;
  `uvm_object_utils(rdma_function_handle)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_function_handle");
    super.new(name);
    kind = RDMA_RESOURCE_FUNCTION;
  endfunction
endclass

  // 功能：处理 rdma_handle_owner_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 handle, owner 用于执行 rdma_handle_owner_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_handle_owner_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_status rdma_handle_owner_status(
  rdma_handle handle,
  rdma_function_handle owner
);
  if (handle == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "handle is null");
  if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "owner is not a function handle");
  if (handle.function_uid != owner.function_uid)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "handle function does not match owner");
  if (handle.generation != owner.generation)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             "handle generation does not match owner");
  return rdma_status::success();
endfunction
