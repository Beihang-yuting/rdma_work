// 中文说明：Device env 汇总 dpu_common 冻结快照和 RDMA integration routers。
class rdma_device_env extends uvm_object;
  `uvm_object_utils(rdma_device_env)
  dpu_device_snapshot device_snapshot;
  dpu_resource_snapshot resources;
  dpu_resource_manager resource_manager;
  rdma_host_mem_router host_mem;
  rdma_pcie_router pcie;
  function new(string name="rdma_device_env"); super.new(name); endfunction
  static function rdma_status build(dpu_device_snapshot device_snapshot, dpu_resource_snapshot resources, dpu_resource_manager resource_manager, rdma_host_mem_router host_mem, rdma_pcie_router pcie, uvm_object registry, time timeout, output rdma_device_env env);
    env=null; if(device_snapshot==null||resources==null||resource_manager==null||host_mem==null||pcie==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"Device environment dependency is null");
    if(!device_snapshot.is_frozen()||!resources.is_frozen()) return rdma_status::make(RDMA_SC_INVALID_STATE,"Device snapshots must be frozen");
    env=rdma_device_env::type_id::create("device_env"); env.device_snapshot=device_snapshot; env.resources=resources; env.resource_manager=resource_manager; env.host_mem=host_mem; env.pcie=pcie; return rdma_status::success();
  endfunction
endclass
