// 目录：协议与资源模型层 model/rdma_handle.sv。
// 职责：实现 rdma_handle 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

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

  // 功能：构造句柄，各字段默认清零，kind 为 RDMA_RESOURCE_FUNCTION。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_handle");
    super.new(name);
    kind = RDMA_RESOURCE_FUNCTION;
    function_uid = '0;
    object_id = '0;
    generation = '0;
  endfunction

  // 设计说明：Handle 是可复制的值快照；copy 须保留完整 owner identity。
  // 功能：把 rhs 的 kind/function_uid/object_id/generation 复制到当前对象。
  // 输入/输出及副作用：覆盖当前对象字段，不修改 rhs。
  // 失败/边界：rhs 类型不匹配时 uvm_fatal（rdma_handle copy type mismatch）。
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

  // 功能：逐字段比较 kind/function_uid/object_id/generation 是否相同。
  // 输入/输出及副作用：只读，返回 bit。
  // 失败/边界：rhs 为 null 返回 0。
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

  // 功能：构造 Function 句柄，kind 固定为 RDMA_RESOURCE_FUNCTION。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_function_handle");
    super.new(name);
    kind = RDMA_RESOURCE_FUNCTION;
  endfunction
endclass

// 功能：校验 handle 与 owner（Function 句柄）的 UID 与 generation 一致。
// 输入/输出及副作用：只读 handle/owner；返回 rdma_status。
// 失败/边界：handle 或 owner 非法、UID 不符为 INVALID_ARGUMENT；generation 不符为 STALE_GENERATION。
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

// 功能：校验 handle 的 kind，并将其 Function UID/generation 与 reference 对齐。
// 输入/输出及副作用：只读 handle/reference；label 用作错误消息前缀；返回 rdma_status。
// 失败/边界：为空或 kind 不符、UID 不符为 INVALID_ARGUMENT；generation 不符为 STALE_GENERATION；
//   reference 为 Function 时转 rdma_handle_owner_status 检查。
function automatic rdma_status rdma_handle_authority_status(
  rdma_handle handle,
  rdma_resource_kind_e expected_kind,
  rdma_handle reference,
  string label
);
  rdma_function_handle function_reference;

  if (handle == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " handle is null"});
  if (handle.kind != expected_kind)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " handle kind is invalid"});
  if (reference == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " authority reference is null"});
  if (reference.kind == RDMA_RESOURCE_FUNCTION) begin
    if (!$cast(function_reference, reference))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {label, " Function reference is invalid"});
    return rdma_handle_owner_status(handle, function_reference);
  end
  if (handle.function_uid != reference.function_uid)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " Function UID does not match"});
  if (handle.generation != reference.generation)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             {label, " Function generation is stale"});
  return rdma_status::success();
endfunction
