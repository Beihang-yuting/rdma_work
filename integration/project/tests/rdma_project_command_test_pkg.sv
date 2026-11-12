// 目录/层次：integration/project/tests；最终独立命令案例编译单元。
// 职责：显式注册公共命令和测试观测入口；复用包不会包含本文件。
// 依赖：runtime、模型及配置fixture；无VIO package。
// 所有权/生命周期：命令上下文仅借用当前test；静态注册一次，恢复不重注册。
package rdma_project_command_test_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import host_mem_pkg::*;
  import dpu_resource_pkg::*;
  import dpu_pcie_pkg::*;
  import pcie_tl_pkg::*;
  import rdma_types_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_drv_pkg::*;
  import rdma_host_mem_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_env_pkg::*;
  import rdma_aip_cfg_pkg::*;
  import rdma_project_pkg::*;
  import rdma_project_runtime_pkg::*;
  import rdma_project_config_test_pkg::*;
  `include "uvm_macros.svh"
  typedef class rdma_project_test;
  rdma_project_test	project_context;
  uvm_sequencer #(pcie_tl_tlp)	project_rc_sqr;
  `include "rdma_project_test.sv"
  `include "rdma_project_commands.sv"
  `include "rdma_project_model_fixture.sv"

  // 功能：向真实Tcl桥返回模型实际观测，作为独立脚本断言输入。
  // 输入/输出及副作用：读取project_observe同名handle，输出Tcl dict。
  // 失败/边界：仅模型test支持；生产平台不能用该入口假冒硬件证据。
  task project_observe();
    aip_cmd	handle;
    rdma_project_model_test	model;

    handle = aip_cmd::get_handle("project_observe");
    if (!$cast(model, project_context)) begin
      handle.status = 1;
      handle.result_out = "observation requires explicit model fixture";
      return;
    end
    handle.status = 0;
    handle.result_out = model.observation();
  endtask
  `aip_cmd_task(project_observe, project_observe)

  // 功能：在真实命令执行期间制造重复注册，验证既有AIP拒绝并保留原handle。
  // 输入/输出及副作用：读取project_duplicate，构造同名load_params对象，预期产生AIP原始错误。
  // 失败/边界：只用于独立负向进程，不捕获/降级重复错误，也不替换原注册对象。
  task project_duplicate();
    aip_cmd	handle;
    aip_cmd	before_handle;
    aip_cmd	duplicate;

    handle = aip_cmd::get_handle("project_duplicate");
    before_handle = aip_cmd::get_handle("load_params");
    duplicate = new("load_params");
    if (aip_cmd::get_handle("load_params") != before_handle)
      `uvm_fatal("PROJECT_DUPLICATE", "duplicate replaced original command")
    handle.status = 0;
    handle.result_out = "DUPLICATE_ORIGINAL_PRESERVED";
  endtask
  `aip_cmd_task(project_duplicate, project_duplicate)
  // 功能：在未初始化模型中选择prepare、配置写或第二Function probe故障。
  // 输入/输出及副作用：project_inject handle的mode用AIP读取，改变测试替身开关并返回结果。
  // 失败/边界：非模型/活动/已初始化尝试或未知mode拒绝，不改生产ready/grant状态。
  task project_inject();
    aip_cmd	handle;
    rdma_project_model_test	model;
    rdma_project_fault_bar	bar;
    string	mode;

    handle = aip_cmd::get_handle("project_inject");
    handle.status = 1;
    handle.result_out = "invalid model injection lifecycle or mode";
    if (!$cast(model, project_context) || model.busy || model.init_attempted)
      return;
    mode = aip_cmd::get_arg(handle.args_in, "mode");
    case (mode)
      "prepare": model.fail_prepare = 1;
      "config": begin
        rdma_config_reg_fixture::fail_enabled = 1;
        rdma_config_reg_fixture::fail_address = rdma_config_reg_fixture::af_address;
      end
      "probe": begin
        if (!$cast(bar, model.model_system.nodes[1].bar))
          return;
        bar.fail_write = 1;
      end
      default: return;
    endcase
    handle.status = 0;
    handle.result_out = "model fault armed";
  endtask
  `aip_cmd_task(project_inject, project_inject)
endpackage
