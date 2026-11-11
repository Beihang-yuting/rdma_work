// 目录/层次：integration/virtio/tests；组合环境实际 build/connect 与 Tcl 重载回归。
// 职责：检查多 Host/PF/VF 下的共享快照、内存、原始 VIO 组件以及无自动启动契约。
// 依赖：生产组合 package 和空闲 Intel/协议 VIF；无 DUT、Completion responder 或 RDMA grant。
// 所有权/生命周期：fixture 只拥有观测句柄；finish 核对无隐式配置，不伪造数据面完成。
package rdma_virtio_test_pkg;
  timeunit 1ns;
  timeprecision 1ps;

  import uvm_pkg::*;
  import aip_core_pkg::*;
  import host_mem_pkg::*;
  import dpu_resource_pkg::*;
  import virtio_net_pkg::*;
  import intel_pcie_adapter_pkg::*;
  import rdma_types_pkg::*;
  import rdma_env_pkg::*;
  import rdma_virtio_pkg::*;
  `include "uvm_macros.svh"

  // 探针仅暴露只读身份比较，所有构建/连接仍执行原始 virtio 实现。
  class rdma_vio_probe extends virtio_net_env;
    `uvm_component_utils(rdma_vio_probe)

    // 功能：创建不改变生产行为的 VIO 身份探针。
    // 输入/输出及副作用：name/parent 透传，无私有 snapshot 或内存。
    // 失败/边界：仍由父类检查平台 cfg 和外部模式，测试不屏蔽报错。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 功能：比较 VIO 实际消费的设备/资源快照与 DPU 权威对象。
    // 输入/输出及副作用：device/resources 只读，返回 configuration_valid 与句柄等式。
    // 失败/边界：未配置或任一身份不同返回假，不以内容相等替代对象同源。
    function bit consumes(dpu_device_snapshot device, dpu_resource_snapshot resources);
      return configuration_valid && device_snapshot == device && resource_snapshot == resources;
    endfunction
  endclass

  class rdma_virtio_smoke_test extends rdma_virtio_test;
    `uvm_component_utils(rdma_virtio_smoke_test)

    dpu_device_snapshot saved_device;
    dpu_resource_snapshot saved_resources;
    host_mem_pool saved_pool;
    rdma_env_cfg saved_rdma_cfg;
    rdma_scenario_cfg saved_scenario;
    aip_cmd saved_loader;
    aip_cmd saved_release;
    int unsigned prepares;

    // 功能：构造只验证组合和重载契约的 test。
    // 输入/输出及副作用：name/parent 透传，prepares 默认零用于检查无自动平台准备。
    // 失败/边界：没有真实 DUT，dut_config 在本 fixture 明确 fatal。
    function new(string name = "rdma_virtio_smoke_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：安装只读 VIO 探针，并使用完整生产 test/build 流程。
    // 输入/输出及副作用：factory override 仅用于本次测试；不绕过组合 env 的创建或连接。
    // 失败/边界：所有生产 build 拒绝路径保持 fatal；具体 VIF 由下一个平台钩子注入。
    virtual function void build_phase(uvm_phase phase);
      virtio_net_env::type_id::set_type_override(rdma_vio_probe::get_type());
      super.build_phase(phase);
    endfunction

    // 功能：向父项目注入 top 的 Intel VIF，交换两 Host 的 TL slot 以检查显式路由。
    // 输入/输出及副作用：读取 intel_vif_0/1；cfg 已加载，不再次解析拓扑。
    // 失败/边界：缺 VIF fatal；单 Host 不交换，多 Host 用原始独立接口，禁止复用同一 VIF。
    virtual function void bind_platform_handles();
      intel_pcie_vif_t vif;

      if (cfg.tl_slot_by_host.num() == 2) begin
        cfg.tl_slot_by_host[0] = 1;
        cfg.tl_slot_by_host[1] = 0;
      end
      foreach (cfg.tl_slot_by_host[h]) begin
        if (!uvm_config_db#(intel_pcie_vif_t)::get(this, "", $sformatf("intel_vif_%0d", h), vif))
          `uvm_fatal("COMPOSE_TEST", "missing top Intel VIF")
        cfg.intel_rc_vifs[cfg.tl_slot_by_host[h]] = vif;
      end
      saved_release = aip_cmd::get_handle("vio_release");
    endfunction

    // 功能：拒绝把空闲结构 top 当作真实 DUT 配置平台。
    // 输入/输出及副作用：增加 prepares 后 fatal，使任何隐式或误发 dut_config 都被观测。
    // 失败/边界：本回归不允许调用该钩子；真实平台须自行实现 readiness/transport 绑定。
    virtual task prepare_platform();
      prepares++;
      `uvm_fatal("COMPOSE_TEST", "structure fixture has no DUT for dut_config")
    endtask

    // 功能：记录 build/connect 后的对象身份并立即检查组合结构。
    // 输入/输出及副作用：保存快照、pool、RDMA cfg/scenario 及统一 loader；随后 restore 也必须保持身份。
    // 失败/边界：生产 EOE/注册失败不记录通过；verify_structure 发现错误会产生 UVM_ERROR。
    virtual function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      saved_device = project.dpu_env.get_snapshot();
      saved_resources = project.dpu_env.get_resource_snapshot();
      saved_pool = project.shared_pool;
      saved_rdma_cfg = project.project_cfg.rdma_cfg;
      saved_scenario = saved_rdma_cfg.scenario;
      saved_loader = aip_cmd::get_handle("load_params");
      verify_structure();
    endfunction

    // 功能：以四态断言报告具体共享资源或生命周期契约失败。
    // 输入/输出及副作用：condition/detail 只读；不符合条件时记录 UVM_ERROR。
    // 失败/边界：X/Z 也视为失败，不降低生产报错等级或提供默认通过值。
    function void require_true(logic condition, string detail);
      if (condition !== 1'b1)
        `uvm_error("COMPOSE_CHECK", detail)
    endfunction

    // 功能：核对两业务实际共享的对象和路由，并证明尚无初始化/资源/自动平台操作。
    // 输入/输出及副作用：只读 env、nodes、VIO 实例和 AIP registry；跨 Host 使用明确 manager/slot。
    // 失败/边界：缺组件、换 cfg/快照/pool、私有 backing、隐式创建驱动或同名 loader 被替换均报错。
    function void verify_structure();
      int unsigned functions;
      int unsigned vio_functions;
      int unsigned rdma_services;

      functions = cfg.dpu_cfg.device_cfg.functions.size();
      vio_functions = 0;
      require_true(cfg.dpu_cfg.device_snapshot == saved_device &&
        cfg.dpu_cfg.resource_snapshot == saved_resources,
        "configuration publication replaced authoritative snapshots");
      require_true(cfg.dpu_cfg.host_mem_pool_ref == saved_pool,
        "RDMA/DPU have distinct Host pools");
      require_true((!project.project_cfg.rdma_enabled && project.rdma == null) ||
        (project.rdma != null && project.rdma.cfg == saved_rdma_cfg &&
         saved_rdma_cfg.scenario == saved_scenario),
        "reload replaced RDMA config/scenario");
      if (project.project_cfg.rdma_enabled) begin
        require_true(project.rdma != null && project.rdma.get_parent() == project.dpu_env,
          "RDMA outside DPU publication subtree");
        require_true(project.rdma.sys.snapshot == saved_device &&
          project.rdma.sys.resources == saved_resources,
          "RDMA did not consume DPU snapshot handles");
        require_true(project.rdma.sys.mem_pool == saved_pool,
          "RDMA/DPU have distinct Host pools");
        require_true(project.rdma.sys.nodes.size() == functions,
          "RDMA did not include every selected PF/VF");
        foreach (project.rdma.sys.nodes[i]) begin
          require_true(project.rdma.sys.nodes[i].mem.mem ==
            saved_pool.get_host(project.rdma.sys.nodes[i].func.key.host_id),
            "RDMA Function has a private/wrong Host manager");
          require_true(project.rdma.sys.nodes[i].drv == null,
            "RDMA initialized without explicit command");
        end
      end else begin
        foreach (cfg.dpu_cfg.device_cfg.functions[i])
          foreach (cfg.dpu_cfg.device_cfg.functions[i].services[j])
            if (cfg.dpu_cfg.device_cfg.functions[i].services[j].service_kind == DPU_SERVICE_RDMA)
              rdma_services++;
        require_true(project.rdma == null && project.project_cfg.rdma_functions.size() == 0 &&
          project.project_cfg.rdma_cfg.funcs.size() == 0 && rdma_services == 0,
          "disabled RDMA still created a child, service or Function configuration");
        foreach (cfg.dpu_cfg.platform_controls[i])
          require_true(!(cfg.dpu_cfg.platform_controls[i].ctx.kind inside {
            DPU_TABLE_RDMA_NOTIFY, DPU_TABLE_RNET}),
            "disabled RDMA published Notify/RNET controls");
      end
      foreach (project.vio_envs[h]) begin
        rdma_vio_probe vio;

        if (!$cast(vio, project.vio_envs[h]))
          `uvm_fatal("COMPOSE_TEST", "VIO probe missing")
        vio_functions += vio.function_instances.size();
        require_true(vio.consumes(saved_device, saved_resources),
          "VIO did not share DPU snapshots");
        require_true(vio.host_mem == saved_pool.get_host(h) &&
          project.pcie_env.cfg.host_mem_by_root[cfg.tl_slot_by_host[h]] == vio.host_mem,
          "VIO/PCIe/RDMA Host backing differs");
        require_true(vio.get_external_setup() == null, "VIO queues prepared automatically");
      end
      require_true(vio_functions != 0 && aip_cmd::get_handle("vio_start") != null,
        "combined env lacks actual VIO Functions/commands");
      require_true(aip_cmd::get_handle("load_params") == saved_loader &&
        aip_cmd::get_handle("vio_release") == saved_release,
        "load/release command registry changed");
      require_true((!project.project_cfg.rdma_enabled ||
        (!project.rdma.is_ready() && project.rdma.res.funcs.size() == 0)) && prepares == 0 &&
        !project.configured && !project.busy && !project.init_attempted,
        "structure/reload caused initialization, configuration or resources");
    endfunction

    // 功能：桥退出后再次验证身份和无自动启动契约，并发布独立 PASS 标记。
    // 输入/输出及副作用：不释放从未创建的 ring/QP；报告仍由 UVM runner 核对零错误。
    // 失败/边界：PASS 信息不掩盖先前 UVM_ERROR，runner 必须同时检查报告汇总。
    virtual task finish_platform();
      verify_structure();
      `uvm_info("RDMA_VIRTIO_PASS", "combined env and shared-resource checks completed", UVM_LOW)
    endtask
  endclass

  // 功能：从真实组合环境读取重载后的 DPU/VIO/RDMA 值并检查句柄身份。
  // 输入/输出及副作用：compose_observe 返回 Tcl dict；不创建/配置任何业务资源。
  // 失败/边界：test 类型不符 fatal；校验错误保留在 UVM 报告中，不返回伪造 PASS 状态。
  task compose_observe();
    rdma_virtio_smoke_test test;
    aip_cmd handle;

    handle = aip_cmd::get_handle("compose_observe");
    if (!$cast(test, uvm_root::get().find("uvm_test_top")))
      `uvm_fatal("COMPOSE_TEST", "smoke test unavailable")
    test.verify_structure();
    handle.status = 0;
    handle.result_out = $sformatf("count %0d print %0d poll %0d hosts %0d functions %0d",
      test.project.project_cfg.rdma_enabled ?
        test.project.project_cfg.rdma_cfg.scenario.traffic.count : 0,
      test.cfg.dpu_cfg.print_bar_map,
      test.cfg.vio_cfg.wait_policy_cfg.default_poll_interval_ns,
      test.project.vio_envs.num(),
      test.project.rdma == null ? 0 : test.project.rdma.sys.nodes.size());
  endtask
  `aip_cmd_task(compose_observe, compose_observe)
endpackage
