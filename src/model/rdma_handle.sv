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

  function new(string name = "rdma_handle");
    super.new(name);
    kind = RDMA_RESOURCE_FUNCTION;
    function_uid = '0;
    object_id = '0;
    generation = '0;
  endfunction

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

  function new(string name = "rdma_function_handle");
    super.new(name);
    kind = RDMA_RESOURCE_FUNCTION;
  endfunction
endclass

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
