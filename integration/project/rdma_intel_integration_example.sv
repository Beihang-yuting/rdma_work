// 目录/层次：integration/project；Intel PCIe 平台接入示例，不属于默认 filelist。
// 职责：把平台已经冻结的 dpu_common snapshot、resource snapshot、Host memory pool、RDMA grant、
//   Intel VIF 驱动句柄和显式驱动配置按唯一顺序交给 rdma_dpu_system；不创建拓扑、不分配资源、
//   不自动执行 rdma_init 或 rdma_run。
// 依赖：dpu_resource_pkg、rdma_dpu_adapter_pkg、rdma_drv_pkg、host_mem_pkg；真实 Intel VIF、reset/
//   readiness、运行期 SD IOVA 与 PCIe sequencer 由平台 test 提供。
// 所有权与生命周期：snapshot/resource/pool/grants/hw/cfg 均由平台拥有；示例对象只保留 system 引用，
//   system 对外部对象使用非拥有引用，平台必须保证它们覆盖 Tcl 配置和流量生命周期。
// 使用顺序：平台先完成 dpu_common publish 与 Host pool 建立，再调用 bind；随后显式执行
//   load_params、dut_config、rdma_init、rdma_run。恢复后平台刷新 grant/运行期 IOVA，并重新建立绑定。
package rdma_intel_integration_example_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import host_mem_pkg::*;
  import dpu_resource_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_drv_pkg::*;

  class rdma_intel_integration_example extends uvm_object;
    `uvm_object_utils(rdma_intel_integration_example)

    rdma_dpu_system system;

    // 功能：构造尚未绑定外部平台句柄的 Intel RDMA 接入示例。
    // 输入/输出及副作用：name 传给 UVM；system 为空，不创建 DPU 拓扑、Host backing 或驱动线程。
    // 失败/边界：bind 成功前不能调用 system 的 probe/start；平台仍须显式控制 Tcl 生命周期。
    function new(string name = "rdma_intel_integration_example");
      super.new(name);
      system = null;
    endfunction

    // 功能：发布一份外部 RDMA 系统，把每个选定 Function 的 grant 与 Intel 驱动句柄逐项绑定。
    // 输入/输出及副作用：keys/grants/hw/cfg 按同一 snapshot 顺序配对；成功后 system 持有非拥有引用，
    //   返回 success，不发 MMIO、不 probe、不启动任何 task。
    // 失败/边界：空/长度不一致、快照或 pool 异源、grant 不完整、硬件 Host memory 不一致或重复绑定
    //   返回首个错误；失败不会保留半成品 system，调用者应修正平台输入后重新建立对象。
    function rdma_status bind(
      dpu_device_snapshot snapshot,
      dpu_resource_snapshot resources,
      host_mem_pool pool,
      dpu_function_key_t keys[$],
      rdma_dpu_grant grants[$],
      rdma_drv_hw hw[$],
      rdma_drv_config drv_cfg[$]
    );
      rdma_status status;

      if (snapshot == null || resources == null || pool == null || keys.size() == 0 ||
          grants.size() != keys.size() || hw.size() != keys.size() || drv_cfg.size() != keys.size())
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
          "Intel RDMA example requires equal nonempty Function, grant, hardware and driver lists");
      system = rdma_dpu_system::type_id::create("intel_rdma_system");
      status = system.bind_snapshot(snapshot, keys, pool);
      if (!status.ok()) begin
        system = null;
        return status;
      end
      status = system.bind_resources(resources);
      if (!status.ok()) begin
        system = null;
        return status;
      end
      status = system.bind_grants(grants);
      if (!status.ok()) begin
        system = null;
        return status;
      end
      foreach (keys[i]) begin
        status = system.bind_external_hw(i, hw[i], drv_cfg[i]);
        if (!status.ok()) begin
          system = null;
          return status;
        end
      end
      return rdma_status::success();
    endfunction
  endclass
endpackage
