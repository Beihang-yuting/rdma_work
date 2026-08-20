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
