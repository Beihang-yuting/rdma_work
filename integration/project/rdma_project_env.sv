// 目录/层次：integration/project；独立 RDMA 项目的环境容器。
// 职责：完成基础 RDMA 子环境的 build/connect 和统一参数事务，不启动配置、初始化或流量 sequence。
// 依赖：RDMA/DPU 既有 API；平台负责实际 PCIe 连接、reset/readiness 和 sequence 启动。
// 所有权/生命周期：项目拥有基础 rdma_env 子环境，借用 cfg/RC；运行期 sequence 的生命周期由 test/命令拥有。
class rdma_project_env extends uvm_env;
  `uvm_component_utils(rdma_project_env)
  rdma_project_env_cfg	cfg;
  rdma_env	rdma;
  uvm_sequencer #(pcie_tl_tlp)	rc;
  int unsigned	dpu_candidates;
  int unsigned	rdma_candidates;
  int unsigned	loads;

  // 功能：创建尚未配置、未初始化的项目容器。
  // 输入/输出及副作用：name/parent交给UVM，状态和观测计数默认零。
  // 失败/边界：build前需通过config_db提供project_cfg，RC在connect绑定。
  extern function new(string	name, uvm_component	parent);
  // 功能：借用平台配置并创建基础 RDMA 子环境。
  // 输入/输出及副作用：phase透传，向 rdma 发布同一 cfg 引用；外部配置模式由 cfg 控制显式初始化。
  // 失败/边界：缺任一组合配置或目录为空 fatal，不创建替代身份。
  extern function void build_phase(uvm_phase	phase);
  // 功能：按唯一DPU和RDMA候选完成全项目无时间推进提交。
  // 输入/输出及副作用：ok/why报告结果；成功保留句柄并增加loads，无MMIO或WR抽样。
  // 失败/边界：调用方必须在初始化前且无活动 sequence 时调用；任一候选无效时活动值完全不变。
  extern function void load_params(output bit	ok, output string	why);
endclass

// 功能：创建尚未配置、未初始化的项目容器。
// 输入/输出及副作用：name/parent交给UVM，状态和观测计数默认零。
// 失败/边界：build前需通过config_db提供project_cfg，RC在connect绑定。
function rdma_project_env::new(string	name, uvm_component	parent);
  super.new(name, parent);
endfunction

// 功能：借用平台配置并创建基础 RDMA 子环境。
// 输入/输出及副作用：phase透传，向 rdma 发布同一 cfg 引用；外部配置模式由 cfg 控制显式初始化。
// 失败/边界：缺任一组合配置或目录为空 fatal，不创建替代身份。
function void rdma_project_env::build_phase(uvm_phase	phase);
  super.build_phase(phase);
  if (!uvm_config_db#(rdma_project_env_cfg)::get(this, "", "project_cfg", cfg) ||
      cfg == null || cfg.dpu == null || cfg.rdma == null || cfg.functions.size() == 0)
    `uvm_fatal("RDMA_PROJECT", "published project_cfg and complete Function directory required")
  uvm_config_db#(rdma_env_cfg)::set(this, "rdma", "cfg", cfg.rdma);
  rdma = rdma_env::type_id::create("rdma", this);
endfunction

// 功能：按唯一DPU和RDMA候选完成全项目无时间推进提交。
// 输入/输出及副作用：ok/why报告结果；成功保留句柄并增加loads，无MMIO或WR抽样。
// 失败/边界：调用方必须在初始化前且无活动 sequence 时调用；任一候选无效时活动值完全不变。
function void rdma_project_env::load_params(output bit	ok, output string	why);
  dpu_env_cfg	dpu_next;
  rdma_env_cfg	rdma_next;
  rdma_status	status;
  dpu_control_cfg_t	catalog[$];

  ok = 0;
  why = "load_params requires idle pre-initialization project";
  if (rdma == null)
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
  loads++;
  ok = 1;
  why = "parameters committed; explicit dut_config and rdma_init required";
endfunction
