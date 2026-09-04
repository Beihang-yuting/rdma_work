// 中文说明：Function context 绑定 identity、资源 snapshot 与两类外部 router。
class rdma_function_context extends uvm_object;
  `uvm_object_utils(rdma_function_context)
  rdma_function_identity identity;
  dpu_resource_snapshot resources;
  rdma_host_mem_router host_mem;
  rdma_pcie_router pcie;
  function new(string name="rdma_function_context"); super.new(name); endfunction
  static function rdma_status build(rdma_function_identity identity, dpu_resource_snapshot resources, rdma_host_mem_router host_mem, rdma_pcie_router pcie, uvm_object registry, time timeout, output rdma_function_context context);
    context=null; if(identity==null||resources==null||host_mem==null||pcie==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"Function context dependency is null");
    if(!identity.validate().ok()||!resources.is_frozen()) return rdma_status::make(RDMA_SC_INVALID_STATE,"Function context snapshot invalid");
    context=rdma_function_context::type_id::create("function_context"); context.identity=identity; context.resources=resources; context.host_mem=host_mem; context.pcie=pcie; return rdma_status::success();
  endfunction
endclass
