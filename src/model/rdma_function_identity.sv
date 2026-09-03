// 中文说明：rdma_function_identity.sv 定义跨 Host/root 隔离的 Function 值快照。
class rdma_function_identity extends uvm_object;
  `uvm_object_utils(rdma_function_identity)

  rdma_function_key_t key;
  int unsigned global_function_id;
  longint unsigned function_uid;
  int unsigned generation;
  rdma_reset_epoch_t reset_epoch;

  function new(string name = "rdma_function_identity");
    super.new(name);
    key = '0;
    global_function_id = 0;
    function_uid = 0;
    generation = 0;
    reset_epoch = 0;
  endfunction

  function rdma_status configure(
    rdma_function_key_t new_key,
    int unsigned new_global_id,
    longint unsigned new_uid,
    int unsigned new_generation,
    longint unsigned new_reset_epoch
  );
    key = new_key;
    global_function_id = new_global_id;
    function_uid = new_uid;
    generation = new_generation;
    reset_epoch = new_reset_epoch;
    return validate();
  endfunction

  function rdma_route_key_t route_key();
    return rdma_route_key_from_function(key);
  endfunction

  function bit same_function(rdma_function_identity rhs);
    if (rhs == null) return 1'b0;
    // Compare packed key members explicitly; some simulators reject packed
    // struct equality in class methods and this keeps the route semantics
    // visible (Host/root/BDF are all part of function identity).
    return key.root_id == rhs.key.root_id &&
           key.host_topology_key == rhs.key.host_topology_key &&
           key.function_kind == rhs.key.function_kind &&
           key.parent_pf_bdf.segment == rhs.key.parent_pf_bdf.segment &&
           key.parent_pf_bdf.bus == rhs.key.parent_pf_bdf.bus &&
           key.parent_pf_bdf.device == rhs.key.parent_pf_bdf.device &&
           key.parent_pf_bdf.function_num == rhs.key.parent_pf_bdf.function_num &&
           key.vf_index == rhs.key.vf_index &&
           key.bdf.segment == rhs.key.bdf.segment &&
           key.bdf.bus == rhs.key.bdf.bus &&
           key.bdf.device == rhs.key.bdf.device &&
           key.bdf.function_num == rhs.key.bdf.function_num &&
           global_function_id == rhs.global_function_id;
  endfunction

  function bit same_incarnation(rdma_function_identity rhs);
    if (!same_function(rhs)) return 1'b0;
    return function_uid == rhs.function_uid &&
           generation == rhs.generation && reset_epoch == rhs.reset_epoch;
  endfunction

  function rdma_status validate();
    bit bdf_zero;
    bdf_zero = (key.bdf.segment == 0 && key.bdf.bus == 0 &&
                key.bdf.device == 0 && key.bdf.function_num == 0);
    if (function_uid == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function UID must be non-zero");
    if (generation == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function generation must be non-zero");
    if (bdf_zero)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function BDF is invalid");
    if (key.function_kind == RDMA_FUNCTION_VF && key.vf_index == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "VF index must be non-zero");
    return rdma_status::success();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_function_identity source;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "Function identity copy type mismatch")
    key = source.key;
    global_function_id = source.global_function_id;
    function_uid = source.function_uid;
    generation = source.generation;
    reset_epoch = source.reset_epoch;
  endfunction
endclass
