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

  // 功能：构造 rdma_handle，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：kind=RDMA_RESOURCE_FUNCTION；function_uid='0；object_id='0；generation='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_handle 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_handle");
    super.new(name);
    kind = RDMA_RESOURCE_FUNCTION;
    function_uid = '0;
    object_id = '0;
    generation = '0;
  endfunction

  // 中文：Handle 是可复制的值快照；clone/copy 必须保留完整 owner identity，
  // 不得退化成仅有默认字段的空句柄。
  // 功能：将 rhs 中 rdma_handle 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（rdma_handle copy type mismatch），不保留部分有效快照。
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

  // 功能：在 rdma_handle 中由 same_instance 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_instance 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
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

  // 功能：构造 rdma_function_handle，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：kind=RDMA_RESOURCE_FUNCTION。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_function_handle 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_function_handle");
    super.new(name);
    kind = RDMA_RESOURCE_FUNCTION;
  endfunction
endclass

// 功能：rdma_handle_owner_status 校验 handle、owner 与当前对象状态的一致性，并显式处理“handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：handle（输入）、owner（输入）；rdma_handle_owner_status 读取 handle、owner 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_handle_owner_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_STALE_GENERATION；典型拒绝条件为“handle is null”“owner is not a function handle”；失败路径不提交部分状态或转移未声明资源。
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
