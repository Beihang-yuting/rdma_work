// 目录/层次：integration/project/tests；既有项目load_params注册隔离测试。
// 职责：先定义用户命令，再导入RDMA可复用包，核对原handle与唯一名字集合。
// 依赖：真实AIP桥/runtime包；无VIO包、模型或DUT。
// 所有权/生命周期：静态命令注册一次，模块桥等待显式Tcl调用。
package rdma_project_namespace_test_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  // 功能：模拟用户原有项目的唯一load_params入口。
  // 输入/输出及副作用：通过同名handle返回用户项目标记。
  // 失败/边界：不加载任何RDMA参数，不产生资源或MMIO。
  task existing_load();
    aip_cmd	handle;
    handle = aip_cmd::get_handle("load_params");
    handle.status = 0;
    handle.result_out = "EXISTING_PROJECT_LOAD";
  endtask
  `aip_cmd_task(load_params, existing_load)
  import rdma_project_runtime_pkg::*;
  // 功能：核对导入可复用包没有注册任何独立案例命令，并确认创建组合类型也无副作用。
  // 输入/输出及副作用：namespace_probe返回结果，比较创建前后完整命令名字集合。
  // 失败/边界：任一独立命令存在或数量/名字改变返回非零，不通过未知命令错误间接证明。
  task namespace_probe();
    aip_cmd	handle;
    rdma_project_env_cfg	composition;
    string	names;

    handle = aip_cmd::get_handle("namespace_probe");
    names = aip_cmd::get_all_cmd_names();
    composition = new("imported_type_without_registration");
    handle.status = aip_cmd::get_handle("dut_config") != null ||
      aip_cmd::get_handle("rdma_init") != null || aip_cmd::get_handle("rdma_run") != null ||
      aip_cmd::get_handle("reg_acc") != null || names != aip_cmd::get_all_cmd_names();
    handle.result_out = handle.status == 0 ? "NAMESPACE_UNCHANGED" : "unexpected command registration";
  endtask
  `aip_cmd_task(namespace_probe, namespace_probe)
endpackage
module rdma_project_namespace_top;
  import aip_core_pkg::*;
  import rdma_project_namespace_test_pkg::*;
  initial aip_tcl_bridge::run_loop();
endmodule
