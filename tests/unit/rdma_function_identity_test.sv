// 中文说明：覆盖 Function identity 的拓扑隔离与 incarnation 比较契约。
class rdma_function_identity_test extends uvm_test;
  `uvm_component_utils(rdma_function_identity_test)
  function new(string name = "rdma_function_identity_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    rdma_function_identity lhs, rhs, copy;
    uvm_object cloned;
    rdma_route_key_t lhs_route, rhs_route;
    rdma_function_key_t key;
    rdma_status status;
    phase.raise_objection(this);
    key = '{root_id:16'h1, host_topology_key:32'h10, function_kind:RDMA_FUNCTION_VF,
            parent_pf_bdf:'{segment:0,bus:8'h20,device:5'h1,function_num:0},
            vf_index:16'h2, bdf:'{segment:0,bus:8'h30,device:5'h4,function_num:1}};
    lhs = rdma_function_identity::type_id::create("lhs");
    rhs = rdma_function_identity::type_id::create("rhs");
    status = lhs.configure(key, 7, 64'h1234, 1, 9);
    if (!status.ok()) `uvm_error("IDENTITY", $sformatf("lhs configure failed: %s", status.convert2string()))
    key.host_topology_key = 32'h11;
    status = rhs.configure(key, 7, 64'h1234, 1, 9);
    if (!status.ok()) `uvm_error("IDENTITY", $sformatf("rhs configure failed: %s", status.convert2string()))
    if (lhs.same_function(rhs)) `uvm_error("IDENTITY", "different host route compared equal")
    lhs_route = lhs.route_key();
    rhs_route = rhs.route_key();
    if ((lhs_route.host_topology_key == rhs_route.host_topology_key &&
         lhs_route.root_id == rhs_route.root_id &&
         lhs_route.segment == rhs_route.segment &&
         lhs_route.bdf.segment == rhs_route.bdf.segment &&
         lhs_route.bdf.bus == rhs_route.bdf.bus &&
         lhs_route.bdf.device == rhs_route.bdf.device &&
         lhs_route.bdf.function_num == rhs_route.bdf.function_num) ||
        lhs_route.host_topology_key != 32'h10 ||
        lhs_route.root_id != 16'h1 || lhs_route.segment != 16'h0 ||
        lhs_route.bdf.segment != lhs.key.bdf.segment ||
        lhs_route.bdf.bus != lhs.key.bdf.bus ||
        lhs_route.bdf.device != lhs.key.bdf.device ||
        lhs_route.bdf.function_num != lhs.key.bdf.function_num ||
        rhs_route.host_topology_key != 32'h11)
      `uvm_error("IDENTITY", "route key fields are incorrect")
    cloned = lhs.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error("IDENTITY", "identity clone failed")
    end
    else begin
      copy.reset_epoch = lhs.reset_epoch + 1;
      if (!lhs.same_function(copy) || lhs.same_incarnation(copy))
        `uvm_error("IDENTITY", "reset epoch did not separate incarnation")
    end
    key = lhs.key;
    status = rhs.configure(key, 7, 64'h1234, 1, 10);
    if (!status.ok() || !lhs.same_function(rhs) || lhs.same_incarnation(rhs))
      `uvm_error("IDENTITY", "reset epoch did not separate incarnation")
    status = lhs.configure(key, 7, 64'h1234, 0, 10);
    if (status.ok() || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("IDENTITY", "zero generation accepted")
    phase.drop_objection(this);
  endtask
endclass
