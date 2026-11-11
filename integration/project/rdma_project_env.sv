// 目录/层次：integration/project；项目生命周期与候选事务。
// 职责：只在显式命令中配置/初始化/运行；所有候选先验证再原地提交。
// 依赖：RDMA/DPU既有API；平台负责实际PCIe连接与prepare。
// 所有权/生命周期：项目拥有RDMA子环境，借用cfg/RC；取消中的操作保持busy以禁止不安全重入。
class rdma_project_manual_env extends rdma_env;
  `uvm_component_utils(rdma_project_manual_env)
  // 功能：构造只允许显式initialize的RDMA子环境。
  // 输入/输出及副作用：name/parent透传；不改变模型或外部模式。
  // 失败/边界：平台必须自行组装cfg并显式启动初始化。
  extern function new(string	name, uvm_component	parent);
  // 功能：禁用模型基类run_phase的隐式初始化。
  // 输入/输出及副作用：phase不变，无probe/MMIO/等待。
  // 失败/边界：仅命令initialize能够使环境ready，空run不代表就绪。
  extern task run_phase(uvm_phase	phase);
endclass

class rdma_project_env extends uvm_env;
  `uvm_component_utils(rdma_project_env)
  rdma_project_env_cfg	cfg;
  rdma_project_manual_env	rdma;
  uvm_sequencer #(pcie_tl_tlp)	rc;
  bit	configured;
  bit	busy;
  bit	init_attempted;
  int unsigned	dpu_candidates;
  int unsigned	rdma_candidates;
  int unsigned	loads;
  int unsigned	prints;

  // 功能：创建尚未配置、未初始化的项目容器。
  // 输入/输出及副作用：name/parent交给UVM，状态和观测计数默认零。
  // 失败/边界：build前需通过config_db提供project_cfg，RC在connect绑定。
  extern function new(string	name, uvm_component	parent);
  // 功能：借用平台配置并创建禁止隐式启动的RDMA子环境。
  // 输入/输出及副作用：phase透传，向rdma发布同一cfg引用。
  // 失败/边界：缺任一组合配置或目录为空fatal，不创建替代身份。
  extern function void build_phase(uvm_phase	phase);
  // 功能：按唯一DPU和RDMA候选完成全项目无时间推进提交。
  // 输入/输出及副作用：ok/why报告结果；成功保留句柄、清configured并增加loads，无MMIO或WR抽样。
  // 失败/边界：busy/初始化尝试/驱动资源存在或任一候选无效时活动值完全不变。
  extern function void load_params(output bit	ok, output string	why);
  // 功能：执行已由平台prepare完成的公共配置，并消费打印策略。
  // 输入/输出及副作用：ok/why返回正常结果；实际seq登记到AIP既有取消registry。
  // 失败/边界：busy/初始化后/无RC拒绝；配置硬件失败保留父类fatal，取消不自动清busy。
  extern task configure(output bit	ok, output string	why);
  // 功能：在完整配置成功之后执行一次RDMA初始化。
  // 输入/输出及副作用：status透传initialize，开始前锁定重载窗口。
  // 失败/边界：未配置/busy/重复调用拒绝；部分初始化失败不可重试。
  extern task initialize(output rdma_status	status);
  // 功能：按一条业务边的两个显式global Function ID选择实际节点，按 qp_count 建立对称 QP 并运行统一场景。
  // 输入/输出及副作用：first/second来自dpu_common，qp_count控制本次业务边；seq创建资源并投递流量。
  // 失败/边界：未ready/busy/同端点/不存在ID/零QP拒绝且不分配；执行中fatal不伪装正常返回。
  extern task run_traffic(int unsigned	first, int unsigned	second, int unsigned	qp_count,
                          output bit	ok, output string	why);

  // 功能：执行 cfg.rdma.flow_groups 中指定的业务边，统一复用 run_traffic 的 ID/QP 校验和生命周期。
  // 输入/输出及副作用：group_index只读配置，成功后创建该组资源并投递流量。
  // 失败/边界：索引越界、组端点/数量非法或当前环境未ready时返回失败，不访问不存在的 Function。
  extern task run_flow_group(int unsigned	group_index, output bit	ok, output string	why);
endclass

// 功能：构造只允许显式initialize的RDMA子环境。
// 输入/输出及副作用：name/parent透传；不改变模型或外部模式。
// 失败/边界：平台必须自行组装cfg并显式启动初始化。
function rdma_project_manual_env::new(string	name, uvm_component	parent);
  super.new(name, parent);
endfunction

// 功能：禁用模型基类run_phase的隐式初始化。
// 输入/输出及副作用：phase不变，无probe/MMIO/等待。
// 失败/边界：仅命令initialize能够使环境ready，空run不代表就绪。
task rdma_project_manual_env::run_phase(uvm_phase	phase);
endtask

// 功能：创建尚未配置、未初始化的项目容器。
// 输入/输出及副作用：name/parent交给UVM，状态和观测计数默认零。
// 失败/边界：build前需通过config_db提供project_cfg，RC在connect绑定。
function rdma_project_env::new(string	name, uvm_component	parent);
  super.new(name, parent);
endfunction

// 功能：借用平台配置并创建禁止隐式启动的RDMA子环境。
// 输入/输出及副作用：phase透传，向rdma发布同一cfg引用。
// 失败/边界：缺任一组合配置或目录为空fatal，不创建替代身份。
function void rdma_project_env::build_phase(uvm_phase	phase);
  bit grants_match;

  super.build_phase(phase);
  if (!uvm_config_db#(rdma_project_env_cfg)::get(this, "", "project_cfg", cfg) ||
      cfg == null || cfg.dpu == null || cfg.rdma == null || cfg.pcie == null || cfg.functions.size() == 0)
    `uvm_fatal("RDMA_PROJECT", "published project_cfg and complete Function directory required")
  if (cfg.grants.size() != 0 && cfg.rdma.grants.size() == 0)
    cfg.rdma.grants = cfg.grants;
  if (cfg.grants.size() != 0) begin
    grants_match = cfg.grants.size() == cfg.rdma.grants.size();
    if (grants_match)
      foreach (cfg.grants[i])
        grants_match &= cfg.grants[i] != null && cfg.rdma.grants[i] != null &&
                        cfg.grants[i].same_as(cfg.rdma.grants[i]);
    if (!grants_match)
      `uvm_fatal("RDMA_PROJECT", "project and RDMA grant lists disagree")
  end
  uvm_config_db#(rdma_env_cfg)::set(this, "rdma", "cfg", cfg.rdma);
  rdma = rdma_project_manual_env::type_id::create("rdma", this);
endfunction

// 功能：按唯一DPU和RDMA候选完成全项目无时间推进提交。
// 输入/输出及副作用：ok/why报告结果；成功保留句柄、清configured并增加loads，无MMIO或WR抽样。
// 失败/边界：busy/初始化尝试/驱动资源存在或任一候选无效时活动值完全不变。
function void rdma_project_env::load_params(output bit	ok, output string	why);
  dpu_env_cfg	dpu_next;
  rdma_env_cfg	rdma_next;
  rdma_status	status;
  dpu_control_cfg_t	catalog[$];

  ok = 0;
  why = "load_params requires idle pre-initialization project";
  if (busy || init_attempted || rdma == null)
    return;
  status = rdma.validate_runtime_candidate(cfg.rdma);
  if (!status.ok()) begin
    why = status.convert2string();
    return;
  end
  dpu_candidates++;
  if (!cfg.dpu.make_runtime_candidate(dpu_next, why))
    return;
  rdma_candidates++;
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg.rdma, rdma_next);
  if (!status.ok()) begin
    why = status.convert2string();
    return;
  end
  if (!cfg.validate_dpu(dpu_next, why) ||
      !rdma_project_cfg_seq::make_catalog_for_grants(cfg.dpu.device_snapshot, cfg.dpu.bar_map,
        cfg.functions, cfg.rdma.grants, catalog, why))
    return;
  status = rdma.validate_runtime_candidate(rdma_next);
  if (!status.ok()) begin
    why = status.convert2string();
    return;
  end
  // 两次apply均为无等待函数，且前面已经验证所有消费者；不调用分别提交的子loader。
  cfg.dpu.apply_runtime_candidate(dpu_next);
  rdma.apply_runtime_candidate(rdma_next);
  configured = 0;
  loads++;
  ok = 1;
  why = "parameters committed; explicit dut_config and rdma_init required";
endfunction

// 功能：执行已由平台prepare完成的公共配置，并消费打印策略。
// 输入/输出及副作用：ok/why返回正常结果；实际seq登记到AIP既有取消registry。
// 失败/边界：busy/初始化后/无RC拒绝；配置硬件失败保留父类fatal，取消不自动清busy。
task rdma_project_env::configure(output bit	ok, output string	why);
  rdma_project_cfg_seq	seq;

  ok = 0;
  why = "configuration requires idle pre-initialization project and bound RC";
  if (busy || init_attempted || rc == null)
    return;
  busy = 1;
  configured = 0;
  if (cfg.dpu.print_bar_map) begin
    if (!cfg.dpu.bar_map.print_bar_map(why, 1)) begin
      busy = 0;
      return;
    end
    prints++;
  end
  seq = rdma_project_cfg_seq::type_id::create("project_configuration");
  seq.rdma_functions = cfg.functions;
  seq.rdma_grants = cfg.rdma.grants;
  seq.hw_plan = cfg.hw_plan;
  aip_cmd_seq_registry::register("dut_config", seq);
  seq.start(rc);
  aip_cmd_seq_registry::unregister("dut_config");
  configured = seq.success;
  ok = seq.success;
  why = seq.error_msg;
  busy = 0;
endtask

// 功能：在完整配置成功之后执行一次RDMA初始化。
// 输入/输出及副作用：status透传initialize，开始前锁定重载窗口。
// 失败/边界：未配置/busy/重复调用拒绝；部分初始化失败不可重试。
task rdma_project_env::initialize(output rdma_status	status);
  if (!configured || busy || init_attempted) begin
    status = rdma_status::make(RDMA_SC_INVALID_STATE, "rdma_init requires successful dut_config and no prior initialization attempt");
    return;
  end
  busy = 1;
  init_attempted = 1;
  rdma.initialize(status);
  busy = 0;
endtask

// 功能：按一条业务边的两个显式global Function ID选择实际节点，按 qp_count 建立对称 QP 并运行统一场景。
// 输入/输出及副作用：first/second来自dpu_common，qp_count控制本次业务边；seq创建资源并投递流量。
// 失败/边界：未ready/busy/同端点/不存在ID/零QP拒绝且不分配；执行中fatal不伪装正常返回。
task rdma_project_env::run_traffic(int unsigned	first, int unsigned	second, int unsigned	qp_count,
                                    output bit	ok, output string	why);
  rdma_traffic_vseq	seq;
  rdma_status	status;
  int	left;
  int	right;

  ok = 0;
  why = "rdma_run requires ready environment, two distinct global IDs and qp_count>0";
  if (busy || !rdma.is_ready() || first == second || qp_count == 0)
    return;
  left = rdma.find_function_index(first);
  right = rdma.find_function_index(second);
  if (left < 0 || right < 0)
    return;
  status = cfg.rdma.scenario.validate();
  if (!status.ok()) begin
    why = status.convert2string();
    return;
  end
  busy = 1;
  seq = rdma_traffic_vseq::type_id::create("project_traffic");
  seq.f0 = left;
  seq.f1 = right;
  seq.qp_count = qp_count;
  aip_cmd_seq_registry::register("rdma_run", seq);
  seq.start(rdma.vseqr);
  aip_cmd_seq_registry::unregister("rdma_run");
  busy = 0;
  ok = rdma.sb.errors == 0 && rdma.sb.idle();
  why = ok ? "traffic completed" : "traffic scoreboard did not drain cleanly";
endtask

// 功能：执行 cfg.rdma.flow_groups 中指定的业务边，统一复用 run_traffic 的 ID/QP 校验和生命周期。
// 输入/输出及副作用：group_index只读配置，成功后创建该组资源并投递流量。
// 失败/边界：索引越界、组端点/数量非法或当前环境未ready时返回失败，不访问不存在的 Function。
task rdma_project_env::run_flow_group(int unsigned	group_index, output bit	ok, output string	why);
  if (cfg == null || cfg.rdma == null || group_index >= cfg.rdma.flow_groups.size()) begin
    ok = 0;
    why = "rdma_run group index is outside the configured flow group list";
    return;
  end
  run_traffic(cfg.rdma.flow_groups[group_index].f0_global_id,
              cfg.rdma.flow_groups[group_index].f1_global_id,
              cfg.rdma.flow_groups[group_index].qp_count, ok, why);
endtask
