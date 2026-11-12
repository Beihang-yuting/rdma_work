// 目录/层次：integration/project/tests；命令/恢复专用模型夹具。
// 职责：从唯一正常解析快照装配模型节点，验证真实命令桥而不声称DUT/grant有效。
// 依赖：现有模型API及配置寄存器fixture；无VIO package，无外部模式翻转。
// 所有权/生命周期：test拥有DPU配置、公共pool、模型系统和RC，子env只借用；模型由 Tcl 命令显式启动。
`uvm_analysis_imp_decl(_project_posted)
`uvm_analysis_imp_decl(_project_cqe)

class rdma_project_model_env extends rdma_env;
  `uvm_component_utils(rdma_project_model_env)
  // 功能：创建借用测试预装配系统的模型子环境。
  // 输入/输出及副作用：name/parent透传，无模型创建副作用。
  // 失败/边界：build_system必须取得同源的显式model_system。
  extern function new(string	name, uvm_component	parent);
  // 功能：借用已正常组装的模型系统，不再次resolve产生第二份身份快照。
  // 输入/输出及副作用：读取model_system配置引用并赋sys。
  // 失败/边界：空系统或external模式fatal，不修改任何ready/grant/mode字段。
  extern protected virtual function void build_system();
  // 功能：保持模型夹具的显式命令生命周期，避免基础 rdma_env 在 run_phase 自动初始化。
  // 输入/输出及副作用：phase 不推进状态；rdma_init 仍是唯一 probe/ready 入口。
  // 失败/边界：该覆盖仅用于模型测试夹具，生产 project env 直接使用基础 rdma_env。
  extern task run_phase(uvm_phase phase);
endclass

class rdma_project_draw_spy extends rdma_aip_value_spec;
  `uvm_object_utils(rdma_project_draw_spy)
  static int unsigned	draws;
  // 功能：创建实际AIP求值器的记录替身。
  // 输入/输出及副作用：name透传，静态draws不在构造重置。
  // 失败/边界：继承真实求值语义，禁止为了验证重载而额外抽样。
  extern function new(string	name = "rdma_project_draw_spy");
  // 功能：记录每一次真实WR表达式求值并委托现有实现。
  // 输入/输出及副作用：spec输入，value/why输出，draws增加一次。
  // 失败/边界：父类失败和fatal原样保留，不重试、不裁剪。
  extern function bit eval(string	spec, output longint unsigned	value, output string	why);
endclass

// 在第二个模型Function的真实probe路径返回一次写失败，验证部分初始化不会开放业务。
class rdma_project_fault_bar extends rdma_dpu_bar;
  bit	fail_write;
  // 功能：构造默认正常转发的模型BAR。
  // 输入/输出及副作用：name交给父类，故障初始关闭。
  // 失败/边界：router/func仍必须按模型契约绑定。
  extern function new(string	name = "rdma_project_fault_bar");
  // 功能：在显式测试故障开关下拒绝设备probe写，否则复用真实模型路由。
  // 输入/输出及副作用：offset/value传给父类；拒绝返回INVALID_STATE且无路由写。
  // 失败/边界：开关只由未初始化的测试注入命令设置，生产包不包含此类。
  extern task write64(bit [63:0]	offset, bit [63:0]	value, output rdma_status	status);
endclass
// 功能：构造默认正常转发的模型BAR。
// 输入/输出及副作用：name交给父类，故障初始关闭。
// 失败/边界：router/func仍必须按模型契约绑定。
function rdma_project_fault_bar::new(string	name = "rdma_project_fault_bar");
  super.new(name);
endfunction

// 功能：在显式测试故障开关下拒绝设备probe写，否则复用真实模型路由。
// 输入/输出及副作用：offset/value传给父类；拒绝返回INVALID_STATE且无路由写。
// 失败/边界：开关只由未初始化的测试注入命令设置，生产包不包含此类。
task rdma_project_fault_bar::write64(bit [63:0]	offset, bit [63:0]	value, output rdma_status	status);
  if (fail_write) begin
    status = rdma_status::make(RDMA_SC_INVALID_STATE, "injected second-model-Function probe write failure");
    return;
  end
  super.write64(offset, value, status);
endtask

class rdma_project_model_test extends rdma_project_test;
  `uvm_component_utils(rdma_project_model_test)
  uvm_sequencer #(pcie_tl_tlp)	fixture_rc;
  rdma_dpu_system	model_system;
  rdma_env_cfg	original_cfg;
  rdma_scenario_cfg	original_scenario;
  dpu_device_snapshot	original_snapshot;
  dpu_resource_snapshot	original_resources;
  dpu_bar_map	original_map;
  string	original_commands;
  bit	prepared;
  bit	fail_prepare;
  pcie_tl_env_config	original_pcie;
  dpu_env_cfg	original_dpu;
  host_mem_pool	original_pool;
  host_mem_api	original_manager;
  int unsigned	prepare_calls;

  // 只订阅现有成功post和SQ完成广播；保存值身份而不保留driver的可变item句柄。
  // 本夹具的WRITE全部signaled，逐WR匹配，避免把scoreboard内存比较次数当作业务数。
  uvm_analysis_imp_project_posted #(rdma_verb_item, rdma_project_model_test)	posted_export;
  uvm_analysis_imp_project_cqe #(rdma_verb_completion, rdma_project_model_test)	cqe_export;
  bit	pending_writes[string];
  int unsigned	write_posts;
  int unsigned	write_completions;

  // 功能：创建明确命名的模型命令测试。
  // 输入/输出及副作用：name/parent透传，组装引用为空；test拥有两个analysis接收端，WRITE计数为零且待完成集合为空。
  // 失败/边界：不用于生产DUT初始化，也不提供RDMA shared grant。
  extern function new(string	name = "rdma_project_model_test", uvm_component	parent = null);
  // 功能：正常发布DPU并创建同源模型，然后建立项目子组件。
  // 输入/输出及副作用：建立一Host/PF0和两RDMA VF，配置真实resolver lineage及寄存器替身。
  // 失败/边界：能力/resolve/publish失败fatal；不调用prepare/initialize，不修改冻结flag。
  extern function void build_phase(uvm_phase	phase);
  // 功能：在原平台绑定后订阅每个verb agent的成功投递和实际完成事件。
  // 输入/输出及副作用：phase传给父类，现有analysis端口增加本test订阅，不改变scoreboard连接。
  // 失败/边界：要求build已创建project及verb；连接本身不启动WR或分配业务资源。
  extern function void connect_phase(uvm_phase	phase);
  // 功能：记录驱动已成功投递的普通WRITE，建立待完成身份集合。
  // 输入/输出及副作用：item只读；按Function/QPN/wr_id保存值键，增加write_posts。
  // 失败/边界：非WRITE忽略；空item、无QP/owner、非signaled或重复待完成身份fatal。
  extern function void write_project_posted(rdma_verb_item	item);
  // 功能：将匹配的成功SQ完成计入真实WRITE完成数，并移除待完成身份。
  // 输入/输出及副作用：c只读；write_completions只在成功匹配时增加一次，不读取cfg.count。
  // 失败/边界：空c或匹配WRITE失败完成fatal；RQ及非待完成WRITE忽略，其他错误仍由scoreboard检查。
  extern function void write_project_cqe(rdma_verb_completion	c);
  // 功能：按既有模型硬件API从已冻结source装配每个RDMA VF。
  // 输入/输出及副作用：model_system拥有node/dev/irq/router及公共pool；按冻结GPA创建每Host唯一manager，不probe。
  // 失败/边界：GPA缺失、pool创建或投影/绑定失败fatal；不调用sys.build、不借用VIO向量充当RDMA授权。
  extern function void assemble_model();
  // 功能：声明测试寄存器替身已可用，刻意不模拟真实Intel reset/readiness。
  // 输入/输出及副作用：累计prepare_calls；成功设置prepared，ok/why返回模型限定或注入失败。
  // 失败/边界：仅dut_config调用；fail_prepare返回假且不配置，重复调用不重建系统或重置epoch。
  extern task prepare_platform(output bit	ok, output string	why);
  // 功能：检查命令结束后的模型业务结算。
  // 输入/输出及副作用：检查scoreboard与WRITE待完成集合并输出模型测试结束标记。
  // 失败/边界：残留业务或error fatal；不声称外部硬件验证成功。
  extern task finish_platform();
  // 功能：返回独立Tcl断言需要的真实状态和稳定身份观测。
  // 输入/输出及副作用：返回Tcl dict格式字符串，读取驱动/路由/资源/WR抽样及成功WRITE投递/完成计数；checked仅供诊断，不修改状态。
  // 失败/边界：仅connect之后调用；identity=0暴露重载更换cfg/scenario/快照、map、pool或Host manager。
  extern function string observation();
endclass

// 功能：创建借用测试预装配系统的模型子环境。
// 输入/输出及副作用：name/parent透传，无模型创建副作用。
// 失败/边界：build_system必须取得同源的显式model_system。
function rdma_project_model_env::new(string	name, uvm_component	parent);
  super.new(name, parent);
endfunction

// 功能：借用已正常组装的模型系统，不再次resolve产生第二份身份快照。
// 输入/输出及副作用：读取model_system配置引用并赋sys。
// 失败/边界：空系统或external模式fatal，不修改任何ready/grant/mode字段。
function void rdma_project_model_env::build_system();
  if (!uvm_config_db#(rdma_dpu_system)::get(this, "", "model_system", sys) ||
      sys == null || sys.external_configuration || cfg.external_configuration)
    `uvm_fatal("PROJECT_MODEL", "fresh model system required; external-mode bypass is forbidden")
endfunction

// 功能：保持模型夹具的显式命令生命周期，避免基础 rdma_env 自动调用 initialize。
// 输入/输出及副作用：phase 不推进状态；Tcl 命令通过独立 runtime sequence 显式驱动初始化。
// 失败/边界：仅该 fixture 禁止自动启动，基础 RDMA env 和外部平台契约不受影响。
task rdma_project_model_env::run_phase(uvm_phase phase);
endtask

// 功能：创建实际AIP求值器的记录替身。
// 输入/输出及副作用：name透传，静态draws不在构造重置。
// 失败/边界：继承真实求值语义，禁止为了验证重载而额外抽样。
function rdma_project_draw_spy::new(string	name = "rdma_project_draw_spy");
  super.new(name);
endfunction

// 功能：记录每一次真实WR表达式求值并委托现有实现。
// 输入/输出及副作用：spec输入，value/why输出，draws增加一次。
// 失败/边界：父类失败和fatal原样保留，不重试、不裁剪。
function bit rdma_project_draw_spy::eval(string	spec, output longint unsigned	value, output string	why);
  draws++;
  return super.eval(spec, value, why);
endfunction

// 功能：创建明确命名的模型命令测试。
// 输入/输出及副作用：name/parent透传，组装引用为空；test拥有两个analysis接收端，WRITE计数为零且待完成集合为空。
// 失败/边界：不用于生产DUT初始化，也不提供RDMA shared grant。
function rdma_project_model_test::new(string	name = "rdma_project_model_test", uvm_component	parent = null);
  super.new(name, parent);
  posted_export = new("posted_export", this);
  cqe_export = new("cqe_export", this);
endfunction

// 功能：正常发布DPU并创建同源模型，然后建立项目子组件。
// 输入/输出及副作用：建立一Host/PF0和两RDMA VF，配置真实resolver lineage及寄存器替身。
// 失败/边界：能力/resolve/publish失败fatal；不调用prepare/initialize，不修改冻结flag。
function void rdma_project_model_test::build_phase(uvm_phase	phase);
  dpu_env_cfg	dpu;
  dpu_configuration_resolver	resolver;
  dpu_placement_diagnostic	diagnostic;
  dpu_vio_placement_request	request;
  dpu_pcie_bar_map	map;
  dpu_device_snapshot	snapshot;
  dpu_resource_snapshot	resources;
  dpu_function_key_t	all_keys[$];
  dpu_control_cfg_t	controls[$];
  dpu_table_layout_t	layout;
  dpu_bar_target_t	target;
  rdma_status	status;
  string	why;
  string	vseq;

  rdma_env::type_id::set_type_override(rdma_project_model_env::get_type());
  rdma_aip_value_spec::type_id::set_type_override(rdma_project_draw_spy::get_type());
  pcie_tl_reg_seq::type_id::set_type_override(rdma_config_reg_fixture::get_type());
  fixture_rc = new("fixture_rc", this);
  rdma_config_reg_fixture::host_by_sequencer[fixture_rc.get_full_name()] = 0;
  rdma_config_reg_fixture::reset_fixture();
  project_cfg = new("model_project_cfg");
  dpu = new("dpu_cfg");
  dpu.hosts = 1;
  dpu.vfs_per_pf = 2;
  dpu.load_params();
  if (dpu.hosts != 1 || dpu.pfs_per_host != 1 || dpu.vfs_per_pf != 2)
    `uvm_fatal("PROJECT_MODEL", "fixture requires genuine one Host PF0 plus VF0/VF1 topology")
  foreach (dpu.device_cfg.functions[f]) begin
    dpu_service_decl	service;

    if (dpu.device_cfg.functions[f].key.kind != DPU_FUNCTION_VF) continue;
    service = new("rdma_service");
    service.service_kind = DPU_SERVICE_RDMA;
    dpu.device_cfg.functions[f].services.push_back(service);
    project_cfg.functions.push_back(dpu.device_cfg.functions[f].key);
  end
  request = new("publication_lineage_only");
  request.request_id = 0;
  request.total_qpairs = 1;
  request.device_policy = DPU_VIO_DEVICE_FIXED;
  request.candidate_kind = DPU_VIO_CANDIDATE_PF_ONLY;
  request.fixed_devices.push_back(dpu.device_cfg.functions[0].key);
  dpu.placement_cfg.vio_requests.push_back(request);
  resolver = new("resolver");
  if (!resolver.resolve(dpu.device_cfg, dpu.placement_cfg, snapshot, resources, diagnostic))
    `uvm_fatal("PROJECT_MODEL", diagnostic.message)
  map = new("map");
  if (!map.initialize(snapshot, 1, why) || !map.bind_host(0, 0, why))
    `uvm_fatal("PROJECT_MODEL", why)
  map.rc_sequencers[0] = fixture_rc;
  snapshot.list_functions(all_keys);
  foreach (all_keys[f]) begin
    dpu_function_policy_t	policy;
    dpu_pcie_function_id_t	pcie_id;
    int unsigned	global_id;

    if (!snapshot.get_pcie_id(all_keys[f], pcie_id, why) ||
        !snapshot.get_global_function_id(all_keys[f], global_id, why) ||
        !map.bind_function(all_keys[f], 0,
          all_keys[f].kind == DPU_FUNCTION_VF ? int'(all_keys[f].vf_id) : -1, pcie_id.bdf, why))
      `uvm_fatal("PROJECT_MODEL", why)
    policy = '{default: 0};
    policy.key = all_keys[f];
    policy.mode = DPU_HOST_SW;
    policy.requester = pcie_id.bdf;
    policy.bdf_index = global_id;
    policy.vport = global_id;
    policy.pfvf = global_id;
    policy.intel_pf = 0;
    policy.intel_vf = all_keys[f].kind == DPU_FUNCTION_VF ? int'(all_keys[f].vf_id) : -1;
    dpu.function_policies[dpu_function_key_name(all_keys[f])] = policy;
  end
  if (!map.freeze(why) || !map.resolve_name("h0.pf0.bar0", target, why) ||
      !rdma_project_cfg_seq::make_catalog(snapshot, map, project_cfg.functions, controls, why))
    `uvm_fatal("PROJECT_MODEL", why)
  rdma_config_reg_fixture::af_address = target.bar_lease.base + 'h1010;
  dpu.platform_controls = controls;
  layout = '{default: 0};
  layout.provided = 1;
  layout.reg_target = "h0.pf0.bar0";
  layout.table_offset = 'hc000;
  layout.entry_bytes = 8;
  layout.capacity = 256;
  layout.index_policy = DPU_INDEX_EXPLICIT;
  dpu.table_layouts[DPU_TABLE_RDMA_NOTIFY] = layout;
  layout.module_offset = 'hb00000;
  layout.table_offset = 'h15000;
  layout.entry_bytes = 4;
  dpu.table_layouts[DPU_TABLE_RNET] = layout;
  if (!dpu.publish(snapshot, resources, map, why))
    `uvm_fatal("PROJECT_MODEL", why)
  project_cfg.dpu = dpu;
  project_cfg.pcie = new("fixture_pcie_cfg");
  project_cfg.rdma = rdma_env_cfg::type_id::create("rdma_cfg");
  project_cfg.rdma.add_func(0, 0, DPU_FUNCTION_VF, 0);
  project_cfg.rdma.add_func(0, 0, DPU_FUNCTION_VF, 1);
  vseq = "rdma_traffic_vseq";
  status = rdma_aip_cfg_loader::load(project_cfg.rdma, vseq);
  if (!status.ok()) `uvm_fatal("PROJECT_MODEL", status.convert2string())
  original_cfg = project_cfg.rdma;
  original_scenario = original_cfg.scenario;
  original_snapshot = snapshot;
  original_resources = resources;
  original_map = map;
  original_commands = aip_cmd::get_all_cmd_names();
  original_pcie = project_cfg.pcie;
  original_dpu = dpu;
  assemble_model();
  uvm_config_db#(rdma_dpu_system)::set(this, "project.rdma", "model_system", model_system);
  super.build_phase(phase);
endfunction

// 功能：在原平台绑定后订阅每个verb agent的成功投递和实际完成事件。
// 输入/输出及副作用：phase传给父类，现有analysis端口增加本test订阅，不改变scoreboard连接。
// 失败/边界：要求build已创建project及verb；连接本身不启动WR或分配业务资源。
function void rdma_project_model_test::connect_phase(uvm_phase	phase);
  super.connect_phase(phase);
  foreach (project.rdma.verb[i]) begin
    project.rdma.verb[i].driver.posted_ap.connect(posted_export);
    project.rdma.verb[i].monitor.cqe_ap.connect(cqe_export);
  end
endfunction

// 功能：记录驱动已成功投递的普通WRITE，建立待完成身份集合。
// 输入/输出及副作用：item只读；按Function/QPN/wr_id保存值键，增加write_posts。
// 失败/边界：非WRITE忽略；空item、无QP/owner、非signaled或重复待完成身份fatal。
function void rdma_project_model_test::write_project_posted(rdma_verb_item	item);
  string	key;

  if (item == null) `uvm_fatal("PROJECT_WRITE", "null posted item")
  if (item.op != RDMA_VERB_WRITE) begin
    return;
  end
  if (item.qp == null) `uvm_fatal("PROJECT_WRITE", "WRITE has no QP")
  if (item.qp.owner == null || !item.signaled)
    `uvm_fatal("PROJECT_WRITE", "WRITE observer requires owned QP and individually signaled requests")
  key = $sformatf("%0d/%0d/%0h", item.qp.owner.index, item.qp.id, item.wr_id);
  if (pending_writes.exists(key)) `uvm_fatal("PROJECT_WRITE", "duplicate pending WRITE identity")
  pending_writes[key] = 1;
  write_posts++;
endfunction

// 功能：将匹配的成功SQ完成计入真实WRITE完成数，并移除待完成身份。
// 输入/输出及副作用：c只读；write_completions只在成功匹配时增加一次，不读取cfg.count。
// 失败/边界：空c或匹配WRITE失败完成fatal；RQ及非待完成WRITE忽略，其他错误仍由scoreboard检查。
function void rdma_project_model_test::write_project_cqe(rdma_verb_completion	c);
  string	key;

  if (c == null) `uvm_fatal("PROJECT_WRITE", "null completion")
  if (c.rq) begin
    return;
  end
  key = $sformatf("%0d/%0d/%0h", c.func, c.qpn, c.wr_id);
  if (!pending_writes.exists(key)) begin
    return;
  end
  if (c.status != RDMA_DRV_WC_SUCCESS)
    `uvm_fatal("PROJECT_WRITE", {"WRITE completion failed: ", c.convert2string()})
  pending_writes.delete(key);
  write_completions++;
endfunction

// 功能：按既有模型硬件API从已冻结source装配每个RDMA VF。
// 输入/输出及副作用：model_system拥有node/dev/irq/router及公共pool；按冻结GPA创建每Host唯一manager，不probe。
// 失败/边界：GPA缺失、pool创建或投影/绑定失败fatal；不调用sys.build、不借用VIO向量充当RDMA授权。
function void rdma_project_model_test::assemble_model();
  string	why;
  rdma_status	status;
  dpu_host_info_t	hosts[$];

  model_system = new("model_system");
  model_system.cfg = project_cfg.dpu.device_cfg;
  model_system.snapshot = original_snapshot;
  model_system.resources = original_resources;
  model_system.router = new("model_router");
  model_system.router.snapshot = original_snapshot;
  original_pool = host_mem_pool::type_id::create("model_memory");
  original_snapshot.list_hosts(hosts);
  foreach (hosts[i]) begin
    if (!hosts[i].has_gpa_aperture || hosts[i].gpa_limit <= hosts[i].gpa_base ||
        !original_pool.create_host(hosts[i].host_id, hosts[i].gpa_base, hosts[i].gpa_limit - 1,
          MODE_BUDDY, 16))
      `uvm_fatal("PROJECT_MODEL", "frozen Host GPA could not populate the shared pool")
  end
  model_system.mem_pool = original_pool;
  project_cfg.dpu.host_mem_pool_ref = original_pool;
  original_manager = original_pool.get_host(0);
  foreach (project_cfg.functions[i]) begin
    rdma_dpu_node	node;
    rdma_project_fault_bar	bar;

    node = new($sformatf("model_vf%0d", i));
    node.func = new("function_projection");
    node.func.key = project_cfg.functions[i];
    if (!rdma_dpu_topology::project(original_snapshot, node.func, why))
      `uvm_fatal("PROJECT_MODEL", why)
    node.source_snapshot = original_snapshot;
    node.mem = rdma_host_mem::type_id::create(node.get_name());
    node.mem.mem = original_pool.get_host(node.func.key.host_id);
    node.dev = new("model_device");
    node.dev.configure(node.mem);
    node.interrupt_ctrl = new("model_interrupts");
    status = node.interrupt_ctrl.configure(node.func);
    if (!status.ok()) `uvm_fatal("PROJECT_MODEL", status.convert2string())
    bar = new("model_bar");
    bar.router = model_system.router;
    bar.func = node.func;
    node.bar = bar;
    node.hw = new("model_hw");
    status = node.hw.bind_hw(bar, node.mem);
    if (!status.ok()) `uvm_fatal("PROJECT_MODEL", status.convert2string())
    status = model_system.router.attach(node.func, node.dev, node.interrupt_ctrl);
    if (!status.ok()) `uvm_fatal("PROJECT_MODEL", status.convert2string())
    model_system.nodes.push_back(node);
  end
endfunction

// 功能：声明测试寄存器替身已可用，刻意不模拟真实Intel reset/readiness。
// 输入/输出及副作用：累计prepare_calls；成功设置prepared，ok/why返回模型限定或注入失败。
// 失败/边界：仅dut_config调用；fail_prepare返回假且不配置，重复调用不重建系统或重置epoch。
task rdma_project_model_test::prepare_platform(output bit	ok, output string	why);
  prepare_calls++;
  if (fail_prepare) begin
    ok = 0;
    why = "injected model preparation failure";
    return;
  end
  prepared = 1;
  ok = 1;
  why = "model register fixture only; no DUT readiness claim";
endtask

// 功能：检查命令结束后的模型业务结算。
// 输入/输出及副作用：检查scoreboard与WRITE待完成集合并输出模型测试结束标记。
// 失败/边界：残留业务或error fatal；不声称外部硬件验证成功。
task rdma_project_model_test::finish_platform();
  if (project.rdma.sb.errors != 0 || !project.rdma.sb.idle() || pending_writes.num() != 0)
    `uvm_fatal("PROJECT_MODEL", "model traffic did not settle")
  `uvm_info("PROJECT_COMMANDS_FINISHED", "explicit model lifecycle finished", UVM_LOW)
endtask

// 功能：返回独立Tcl断言需要的真实状态和稳定身份观测。
// 输入/输出及副作用：返回Tcl dict格式字符串，读取驱动/路由/资源/WR抽样及成功WRITE投递/完成计数；checked仅供诊断，不修改状态。
// 失败/边界：仅connect之后调用；identity=0暴露重载更换cfg/scenario/快照、map、pool或Host manager。
function string rdma_project_model_test::observation();
  int unsigned	probes;
  bit	identity;

  probes = 0;
  foreach (model_system.nodes[i])
    if (model_system.nodes[i].drv != null) probes++;
  identity = project.cfg.dpu == original_dpu && project.cfg.pcie == original_pcie &&
    project_cfg.dpu.host_mem_pool_ref == original_pool && model_system.mem_pool == original_pool &&
    original_pool.get_host(0) == original_manager &&
    project.rc == fixture_rc && project.cfg.rdma == original_cfg && project.cfg.rdma.scenario == original_scenario &&
    project.cfg.dpu.device_snapshot == original_snapshot && project.cfg.dpu.resource_snapshot == original_resources &&
    project.cfg.dpu.bar_map == original_map && project.rdma.sys.snapshot == original_snapshot;
  return $sformatf({"count %0d print %0d verify %0d configured %0d ready %0d probes %0d ",
    "cmq_mmio %0d config_accesses %0d checked %0d resources %0d draws %0d identity %0d ",
    "write_posts %0d write_completions %0d pending_writes %0d sb_errors %0d sb_idle %0d ",
    "loads %0d dpu_reads %0d rdma_reads %0d registry_stable %0d preparing %0d busy %0d prints %0d"},
    original_scenario.traffic.count, project_cfg.dpu.print_bar_map, project_cfg.dpu.verify_readback,
    configured, project.rdma.is_ready(), probes, model_system.router.routed,
    rdma_config_reg_fixture::accesses.size(), project.rdma.sb.checked, project.rdma.res.funcs.size(),
    rdma_project_draw_spy::draws, identity, write_posts, write_completions, pending_writes.num(),
    project.rdma.sb.errors, project.rdma.sb.idle(), project.loads, project.dpu_candidates, project.rdma_candidates,
    aip_cmd::get_all_cmd_names() == original_commands, preparing, busy, prints);
endfunction
