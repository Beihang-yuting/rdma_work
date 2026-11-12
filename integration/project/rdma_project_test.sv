// 目录/层次：integration/project；独立案例的显式平台钩子。
// 职责：建立项目组件并运行AIP桥；平台子类提供真实bind/prepare/finish。
// 依赖：最终test package导入runtime/AIP；本文件不创建默认DUT或伪造就绪。
// 所有权/生命周期：test拥有project；平台依赖必须覆盖运行期，结束时由finish撤销。
class rdma_project_test extends uvm_test;
  `uvm_component_utils(rdma_project_test)
  rdma_project_env	project;
  rdma_project_env_cfg	project_cfg;
  uvm_sequencer #(pcie_tl_tlp)	project_rc;
  // 命令生命周期由 test 持有，避免环境在 build/connect 之外承担 sequence 调度状态。
  bit	preparing;
  bit	busy;
  bit	configured;
  bit	init_attempted;
  int unsigned	prints;

  // 功能：构造尚未组装的平台测试入口。
  // 输入/输出及副作用：name/parent交给UVM，平台引用为空。
  // 失败/边界：具体平台必须在build前提供project_cfg，默认prepare拒绝真实配置。
  extern function new(string	name = "rdma_project_test", uvm_component	parent = null);
  // 功能：创建项目并向其提供平台组合配置。
  // 输入/输出及副作用：从config_db读取或使用子类已提供project_cfg；创建project。
  // 失败/边界：缺配置fatal；不执行reset、probe或初始化。
  extern function void build_phase(uvm_phase	phase);
  // 功能：发布非拥有RC/环境引用，供显式命令使用。
  // 输入/输出及副作用：核对DPU与RDMA共享同一pool，再调用bind_platform_handles并发布同一DPU cfg至RC。
  // 失败/边界：pool缺失/类型错误/与RDMA不同、缺RC或已有另一个命令上下文fatal，不进行物理准备。
  extern function void connect_phase(uvm_phase	phase);
  // 功能：绑定平台已经创建的管理RC句柄。
  // 输入/输出及副作用：默认从冻结map解析h0.pf0.bar0并保存project_rc。
  // 失败/边界：缺已发布路由返回假；不绑定reset epoch或发送事务。
  extern virtual function bit bind_platform_handles(output string	why);
  // 功能：由dut_config唯一调用，完成实际平台reset/readiness和一次性transport绑定。
  // 输入/输出及副作用：ok/why报告结果；默认无硬件实现而拒绝。
  // 失败/边界：平台子类不得自动重置/重绑已撤销epoch，失败不能进入配置。
  extern virtual task prepare_platform(output bit	ok, output string	why);
  // 功能：结束桥循环后让平台停止并撤销借用的外部资源。
  // 输入/输出及副作用：默认无外部句柄可撤销，子类负责真实transport teardown。
  // 失败/边界：不是恢复或重新初始化入口，不清理仍在DMA使用的资源。
  extern virtual task finish_platform();
  // 功能：只运行显式命令桥及平台收尾。
  // 输入/输出及副作用：phase objection覆盖run_loop，结束后finish并drop。
  // 失败/边界：不自动调用prepare/configure/initialize/traffic，脚本须显式source执行。
  extern task run_phase(uvm_phase	phase);
endclass

// 功能：构造尚未组装的平台测试入口。
// 输入/输出及副作用：name/parent交给UVM，平台引用为空。
// 失败/边界：具体平台必须在build前提供project_cfg，默认prepare拒绝真实配置。
function rdma_project_test::new(string	name = "rdma_project_test", uvm_component	parent = null);
  super.new(name, parent);
endfunction

// 功能：创建项目并向其提供平台组合配置。
// 输入/输出及副作用：从config_db读取或使用子类已提供project_cfg；创建project。
// 失败/边界：缺配置fatal；不执行reset、probe或初始化。
function void rdma_project_test::build_phase(uvm_phase	phase);
  super.build_phase(phase);
  if (project_cfg == null && !uvm_config_db#(rdma_project_env_cfg)::get(this, "", "project_cfg", project_cfg))
    `uvm_fatal("RDMA_PROJECT", "platform must provide project_cfg before build")
  uvm_config_db#(rdma_project_env_cfg)::set(this, "project", "project_cfg", project_cfg);
  project = rdma_project_env::type_id::create("project", this);
endfunction

// 功能：发布非拥有RC/环境引用，供显式命令使用。
// 输入/输出及副作用：核对DPU与RDMA共享同一pool，再调用bind_platform_handles并发布同一DPU cfg至RC。
// 失败/边界：pool缺失/类型错误/与RDMA不同、缺RC或已有另一个命令上下文fatal，不进行物理准备。
function void rdma_project_test::connect_phase(uvm_phase	phase);
  string	why;
  host_mem_pool	pool;

  super.connect_phase(phase);
  if (!$cast(pool, project_cfg.dpu.host_mem_pool_ref) || pool == null ||
      pool != project.rdma.sys.mem_pool)
    `uvm_fatal("RDMA_PROJECT", "DPU and RDMA must borrow the same host_mem_pool")
  if (!bind_platform_handles(why))
    `uvm_fatal("RDMA_PROJECT", why)
  project.rc = project_rc;
  project_rc_sqr = project_rc;
  uvm_config_db#(dpu_env_cfg)::set(project_rc, "", "dpu_cfg", project_cfg.dpu);
  if (project_context != null && project_context != this)
    `uvm_fatal("RDMA_PROJECT", "standalone command context already belongs to another test")
  project_context = this;
endfunction

// 功能：绑定平台已经创建的管理RC句柄。
// 输入/输出及副作用：默认从冻结map解析h0.pf0.bar0并保存project_rc。
// 失败/边界：缺已发布路由返回假；不绑定reset epoch或发送事务。
function bit rdma_project_test::bind_platform_handles(output string	why);
  dpu_pcie_bar_map	map;
  dpu_bar_target_t	target;

  if (!$cast(map, project_cfg.dpu.bar_map) || map == null) begin
    why = "platform must publish a PCIe BAR map";
    return 0;
  end
  return map.resolve_name("h0.pf0.bar0", target, why) && map.get_sequencer(target, project_rc, why);
endfunction

// 功能：由dut_config唯一调用，完成实际平台reset/readiness和一次性transport绑定。
// 输入/输出及副作用：ok/why报告结果；默认无硬件实现而拒绝。
// 失败/边界：平台子类不得自动重置/重绑已撤销epoch，失败不能进入配置。
task rdma_project_test::prepare_platform(output bit	ok, output string	why);
  ok = 0;
  why = "platform prepare hook is not implemented; no hardware readiness assumed";
endtask

// 功能：结束桥循环后让平台停止并撤销借用的外部资源。
// 输入/输出及副作用：默认无外部句柄可撤销，子类负责真实transport teardown。
// 失败/边界：不是恢复或重新初始化入口，不清理仍在DMA使用的资源。
task rdma_project_test::finish_platform();
endtask

// 功能：只运行显式命令桥及平台收尾。
// 输入/输出及副作用：phase objection覆盖run_loop，结束后finish并drop。
// 失败/边界：不自动调用prepare/configure/initialize/traffic，脚本须显式source执行。
task rdma_project_test::run_phase(uvm_phase	phase);
  phase.raise_objection(this);
  aip_tcl_bridge::run_loop();
  finish_platform();
  phase.drop_objection(this);
endtask
