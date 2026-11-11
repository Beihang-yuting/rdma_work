// 目录：验证组件层 tb/rdma_env_cfg.sv。
// 层：验证组件。
// 职责：env 配置根：运行模式、拓扑（dpu_common 的 Host/PF/VF 与 Function 角色）、链路类型、插件、
//   统一场景资源属性、时间参数、检查开关，以及统一场景 scenario（资源与流量参数的唯一配置源）。测试经
//   uvm_config_db 把它交给 env（键 "cfg"）。
// 依赖：rdma_dpu_adapter_pkg（Function 声明）、rdma_scenario_cfg（场景与表达式求值器）。
// 所有权：配置对象持有插件引用、场景与表达式求值器；external_system 由平台拥有，覆盖 env 生命周期。
// 生命周期：测试 build_phase 创建并加载参数；env build_phase 在插件 pre_build 之后调用 finalize
//   校验并冻结；初始化前可由项目统一候选事务原地提交。

typedef class rdma_env;
typedef class rdma_dut_frame_endpoint;

// 一个 Function 的声明（交给 rdma_dpu_system）；role 决定设备由模型还是 RTL 承担。
typedef struct {
  int unsigned	host;
  int unsigned	pf;
  dpu_function_kind_e	kind;
  int unsigned	vf;
  rdma_func_role_e	role;
} rdma_env_func_t;

// 传输相关扩展：PCIe 承载、rxe 远端等在各自包内实现。
virtual class rdma_env_plugin extends uvm_object;
  // 功能：构造不带资源与状态的 env 插件基对象，供具体传输扩展继承生命周期钩子。
  // 输入/输出及副作用：name 为 UVM 名；基类不保存 env、不创建组件，也不取得外部资源所有权。
  // 失败/边界：直接实例化时四个钩子均为空操作；需要平台行为的插件必须覆盖对应阶段。
  function new(string	name = "rdma_env_plugin");
    super.new(name);
  endfunction

  // 功能：提供 dpu 系统 build 前的可覆盖钩子，例如安装 factory override 或调整平台配置。
  // 输入/输出及副作用：env 为待构建环境的非拥有引用；基类实现有意不读取或修改它。
  // 失败/边界：插件不需要预构建动作时保持空操作；派生实现必须在该阶段内完成影响类型创建的配置。
  virtual function void pre_build(rdma_env	env);
  endfunction

  // 功能：提供 env build_phase 末尾的可覆盖钩子，供插件创建并连接依赖已装配 dpu 系统的组件。
  // 输入/输出及副作用：env 为当前环境非拥有引用；基类不创建对象或改变拓扑。
  // 失败/边界：无需额外组件的插件可沿用空操作；派生类不得在此假设 Function 已 probe。
  virtual function void build(rdma_env	env);
  endfunction

  // 功能：提供 Function probe 后、业务流量前的可覆盖运行期准备钩子。
  // 输入/输出及副作用：env 已完成静态装配；基类立即完成且不持有 objection、不启动线程或外部进程。
  // 失败/边界：无需运行期准备时为空操作；派生 task 失败必须自行报告，接口没有 status 返回值。
  virtual task start(rdma_env	env);
  endtask

  // 功能：提供 env report_phase 的可覆盖收尾钩子，供插件检查计数或释放其拥有的外部资源。
  // 输入/输出及副作用：env 为已运行环境；基类不报告、不释放，也不修改仿真结果。
  // 失败/边界：未分配资源的插件可沿用空操作；派生实现必须自行处理部分启动后的幂等收尾。
  virtual function void report(rdma_env	env);
  endfunction
endclass

class rdma_env_cfg extends uvm_object;
  `uvm_object_utils(rdma_env_cfg)

  // 运行模式（PEER / RXE / DUT）；rxe 插件在 pre_build 中切换为 RXE。
  rdma_env_mode_e	mode;
  // 外部系统由平台拥有：已投影快照、绑定 Host manager/hw；环境只借用，不重复声明拓扑。
  bit	external_configuration;
  rdma_dpu_system	external_system;
  // 平台为每个 RDMA Function 发布的固定资源/路由授权；不从 VIO lease 推导，也不随 load_params 改变。
  rdma_dpu_grant	grants[$];
  // 拓扑与平台。
  rdma_env_func_t	funcs[$];
  // 插件提供的远端 Function 数（如 rxe），下标排在 dpu Function 之后。
  int unsigned	remote_funcs;
  string	link_type;
  rdma_env_plugin	plugins[$];
  // 声明式 RDMA 流量输入与 resolver 生成的冻结快照。flow_plan 与 resolved_config 由测试拥有；
  // env 只在缺少 resolved_config 时读取 plan 并保存发布结果，之后各组件消费只读快照。
  rdma_flow_plan	flow_plan;
  rdma_resolved_config	resolved_config;
  // DUT link 外部 endpoint 与 frozen route snapshot；仅 rdma_dut_link 使用，普通 loopback 忽略。
  rdma_dut_frame_endpoint	dut_endpoint;
  rdma_dut_link_snapshot	dut_link_snapshot;
  int unsigned	dut_port;
  bit [47:0]	dut_mac;
  // 时间：monitor 轮询间隔、等待一个完成的上限。
  time	poll_interval;
  time	response_timeout;
  // 检查开关与协议偏差（按规则名降级为 info）。
  bit	checker_enable;
  bit	cov_enable;
  string	deviations[$];
  // 唯一场景与分布表达式求值器（适配层可替换为 aip_core 实现）。
  rdma_scenario_cfg	scenario;
  // 可选流量拓扑；每个条目引用 global Function ID，RDMA env 仍由一个实例统一管理。
  rdma_flow_group_t	flow_groups[$];
  string	vseq_type;
  rdma_value_spec	spec;
  protected bit	finalized;

  // 功能：构造默认配置：PEER 模式，链路 rdma_link（loopback），PMTU 1024，timeout 14，重试 7，
  //   min_rnr 1，深度 256；为单一场景创建默认值，表达式求值器为最小语法实现。
  // 输入/输出及副作用：name 为 UVM 名；创建场景与求值器对象并由本配置持有。
  // 失败/边界：拓扑须由测试填写；场景为所有控制面 QP 默认值的唯一来源。
  extern function new(string	name = "rdma_env_cfg");

  // 功能：把 host/PF/kind/VF 四元组追加为一个待交给 rdma_dpu_system 的 Function 声明。
  // 输入/输出及副作用：构造值类型 rdma_env_func_t 并保持调用顺序追加到 funcs，不立即修改 dpu_common。
  // 失败/边界：本函数不去重或验证拓扑编号；重复 key、VF/PF kind 与 vf 不一致等由系统 build 拒绝。
  function void add_func(int unsigned	host, int unsigned	pf = 0,
                         dpu_function_kind_e	kind = DPU_FUNCTION_PF, int unsigned	vf = 0,
                         rdma_func_role_e	role = RDMA_FUNC_ROLE_MODEL);
    rdma_env_func_t	f;

    f.host = host;
    f.pf = pf;
    f.kind = kind;
    f.vf = vf;
    f.role = role;
    funcs.push_back(f);
  endfunction

  // 功能：追加一条由两个 global Function ID 端点组成的业务边，并记录对称 QP 数量；多条边可引用任意 Function 组合。
  // 输入/输出及副作用：把值类型条目追加到 flow_groups；不解析 snapshot、不分配 QP 或内存。
  // 失败/边界：零 QP 或同端点只在 finalize/运行前拒绝；global ID 是否存在要等 dpu_common 快照发布后检查。
  function void add_flow_group(int unsigned f0_global_id, int unsigned f1_global_id,
                               int unsigned qp_count = 1);
    rdma_flow_group_t	group;

    group.f0_global_id = f0_global_id;
    group.f1_global_id = f1_global_id;
    group.qp_count     = qp_count;
    flow_groups.push_back(group);
  endfunction

  // 功能：校验模式、拓扑和唯一场景，成功后冻结构建配置。
  // 输入/输出及副作用：校验场景并置 finalized，返回首个错误状态或成功。
  // 失败/边界：模型拓扑为空、外部系统缺失/非外部/无节点、外部同时声明 funcs、存在 DUT 角色、mode 与链路/远端
  //   Function 不一致、流量组端点/数量非法或任一场景非法均返回错误；重复调用幂等。
  extern function rdma_status finalize();

  // 功能：生成最终生效配置的多行摘要（模式、拓扑、链路、环境默认、时间、检查开关、当前场景）。
  // 输入/输出及副作用：纯格式化，不修改配置。
  // 失败/边界：finalize 之前可打印未验证输入，不抽样表达式。
  extern function string describe();

  // 功能：按完整字符串判断协议规则 name 是否已列入偏差清单。
  // 输入/输出及副作用：顺序读取 deviations，首次精确匹配返回 1；不修改队列或规则状态。
  // 失败/边界：匹配区分大小写且不做前后空白归一化；空清单或未知名字返回 0，重复项不改变结果。
  function bit deviates(string	name);
    foreach (deviations[i])
      if (deviations[i] == name)
        return 1'b1;
    return 1'b0;
  endfunction

  // 功能：为运行期候选复制不可重建的环境身份及固定字段默认值，保持可变参数构造默认值。
  // 输入/输出及副作用：active 为现有配置；本候选借用外部系统、快照、插件和 endpoint，不分配设备资源。
  // 失败/边界：active 必须非空；不复制已加载 qp/mem/pkt/traffic、时间参数或 finalized。
  extern function void inherit_identity(rdma_env_cfg	active);

  // 功能：预检候选的固定环境身份和全部可变场景语义，不修改活动配置。
  // 输入/输出及副作用：candidate 只读，返回 status；不抽样、不访问设备。
  // 失败/边界：空候选、环境固定字段或身份变化、无效时间/场景以及不支持的报文 override 均拒绝。
  extern function rdma_status validate_runtime_candidate(rdma_env_cfg	candidate);

  // 功能：在项目全局预检成功后原地提交 RDMA 参数，保留全部共享句柄。
  // 输入/输出及副作用：candidate 提供场景和时间值；更新现有 scenario 与 spec，不更换 cfg 或资源快照。
  // 失败/边界：仅供已经预检且尚未初始化的事务调用；不分配资源或推进 WR 表达式。
  extern function void apply_runtime_candidate(rdma_env_cfg	candidate);
endclass

  // 功能：生成最终生效配置的多行摘要（模式、拓扑、链路、环境默认、时间、检查开关、当前场景）。
  // 输入/输出及副作用：纯格式化，不修改配置。
  // 失败/边界：finalize 之前可打印未验证输入，不抽样表达式。
function string rdma_env_cfg::describe();
    string	s;

    s = $sformatf("RDMA effective configuration\n  mode=%s link=%s funcs=%0d grants=%0d\n",
                  mode.name(), link_type, funcs.size(), grants.size());
    s = {s, $sformatf("  remote_funcs=%0d\n", remote_funcs)};
    foreach (funcs[i])
      s = {s, $sformatf("  f%0d host=%0d pf=%0d kind=%s vf=%0d role=%s\n", i, funcs[i].host,
                        funcs[i].pf, funcs[i].kind.name(), funcs[i].vf, funcs[i].role.name())};
    foreach (flow_groups[i])
      s = {s, $sformatf("  flow%0d global=%0d<->%0d qps=%0d\n", i,
                        flow_groups[i].f0_global_id, flow_groups[i].f1_global_id,
                        flow_groups[i].qp_count)};
    s = {s, scenario.describe(), "\n"};
    foreach (deviations[i])
      s = {s, "  deviation: ", deviations[i], "\n"};
    return s;
endfunction

// 功能：构造默认配置：PEER 模式，链路 rdma_link（loopback），PMTU 1024，timeout 14，重试 7，
//   min_rnr 1，深度 256；为单一场景创建默认值，表达式求值器为最小语法实现。
// 输入/输出及副作用：name 为 UVM 名；创建场景与求值器对象并由本配置持有。
// 失败/边界：拓扑须由测试填写；场景为所有控制面 QP 默认值的唯一来源。
function rdma_env_cfg::new(string	name = "rdma_env_cfg");
  super.new(name);
  external_configuration = 0;
  external_system = null;
  grants.delete();
  mode = RDMA_ENV_MODE_PEER;
  link_type = "rdma_link";
  flow_plan = null;
  flow_groups.delete();
  resolved_config = null;
  dut_endpoint = null;
  dut_link_snapshot = null;
  dut_port = 0;
  dut_mac = '0;
  scenario = rdma_scenario_cfg::type_id::create("scenario");
  vseq_type = "";
  poll_interval = 10ns;
  response_timeout = 100us;
  checker_enable = 1'b1;
  cov_enable = 1'b1;
  finalized = 1'b0;
  spec = rdma_value_spec::type_id::create("value_spec");
endfunction

// 功能：校验模式、拓扑和唯一场景，成功后冻结构建配置。
// 输入/输出及副作用：校验场景并置 finalized，返回首个错误状态或成功。
// 失败/边界：模型拓扑为空、外部系统缺失/非外部/无节点、外部同时声明 funcs、存在 DUT 角色、mode 与链路/远端
//   Function 不一致、任一场景非法均返回错误；重复调用幂等。
function rdma_status rdma_env_cfg::finalize();
  rdma_status	status;

  if (finalized)
    return rdma_status::success();
  if (external_configuration && (external_system == null ||
      !external_system.external_configuration || external_system.nodes.size() == 0))
    return rdma_status::make(RDMA_SC_INVALID_STATE, "external configuration requires a bound external system");
  if (external_configuration && funcs.size() != 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "external configuration cannot redeclare Functions");
  if (!external_configuration && funcs.size() == 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "rdma_env_cfg has no Function");
  foreach (funcs[i])
    if (funcs[i].role == RDMA_FUNC_ROLE_DUT)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               $sformatf("f%0d role DUT: DUT bridge/RM not implemented yet", i));
  if (mode == RDMA_ENV_MODE_DUT && link_type != "rdma_dut_link")
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "mode DUT requires link_type rdma_dut_link");
  if (mode == RDMA_ENV_MODE_RXE && remote_funcs == 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "mode RXE requires a remote Function");
  foreach (flow_groups[i]) begin
    if (flow_groups[i].qp_count == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, $sformatf("flow group %0d has zero QP count", i));
    if (flow_groups[i].f0_global_id == flow_groups[i].f1_global_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, $sformatf("flow group %0d has identical endpoints", i));
  end
  status = validate_runtime_candidate(this);
  if (!status.ok())
    return status;
  status = scenario.finalize();
  if (!status.ok())
    return status;
  finalized = 1'b1;
  return rdma_status::success();
endfunction

// 功能：为运行期候选复制不可重建的环境身份及固定字段默认值，保持可变参数构造默认值。
// 输入/输出及副作用：active 为现有配置；本候选借用外部系统、快照、插件和 endpoint，不分配设备资源。
// 失败/边界：active 必须非空；不复制已加载 qp/mem/pkt/traffic、时间参数或 finalized。
function void rdma_env_cfg::inherit_identity(rdma_env_cfg	active);
  mode = active.mode;
  link_type = active.link_type;
  vseq_type = active.vseq_type;
  checker_enable = active.checker_enable;
  cov_enable = active.cov_enable;
  external_configuration = active.external_configuration;
  external_system = active.external_system;
  grants = active.grants;
  funcs = active.funcs;
  remote_funcs = active.remote_funcs;
  plugins = active.plugins;
  deviations = active.deviations;
  flow_plan = active.flow_plan;
  resolved_config = active.resolved_config;
  flow_groups = active.flow_groups;
  dut_endpoint = active.dut_endpoint;
  dut_link_snapshot = active.dut_link_snapshot;
  dut_port = active.dut_port;
  dut_mac = active.dut_mac;
endfunction

// 功能：预检候选的固定环境身份和全部可变场景语义，不修改活动配置。
// 输入/输出及副作用：candidate 只读，返回 status；不抽样、不访问设备。
// 失败/边界：空候选、环境固定字段或身份变化、无效时间/场景以及不支持的报文 override 均拒绝。
function rdma_status rdma_env_cfg::validate_runtime_candidate(rdma_env_cfg	candidate);
  rdma_status	status;
  if (candidate == null || candidate.scenario == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "RDMA candidate is missing");
  if (candidate.mode != mode || candidate.link_type != link_type || candidate.vseq_type != vseq_type ||
      candidate.checker_enable != checker_enable || candidate.cov_enable != cov_enable)
    return rdma_status::make(RDMA_SC_INVALID_STATE, "rdma.env mode/link/vseq/checker/cov are fixed after build");
  if (candidate.external_configuration != external_configuration || candidate.external_system != external_system ||
      candidate.funcs != funcs || candidate.remote_funcs != remote_funcs || candidate.plugins != plugins ||
      candidate.deviations != deviations || candidate.flow_plan != flow_plan ||
      candidate.flow_groups != flow_groups ||
      candidate.resolved_config != resolved_config || candidate.dut_endpoint != dut_endpoint ||
      candidate.dut_link_snapshot != dut_link_snapshot || candidate.dut_port != dut_port || candidate.dut_mac != dut_mac)
    return rdma_status::make(RDMA_SC_INVALID_STATE, "RDMA candidate changed fixed topology/platform identity");
  if (candidate.grants.size() != grants.size())
    return rdma_status::make(RDMA_SC_INVALID_STATE, "RDMA candidate changed fixed Function grants");
  foreach (grants[i]) begin
    if (grants[i] == null || candidate.grants[i] == null ||
        !grants[i].same_as(candidate.grants[i]))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
        "RDMA candidate changed fixed Function grants");
  end
  if (candidate.poll_interval == 0 || candidate.response_timeout == 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "rdma.env.poll_ns/response_timeout_us must be positive");
  if (!(candidate.mode inside {RDMA_ENV_MODE_PEER, RDMA_ENV_MODE_RXE, RDMA_ENV_MODE_DUT}))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "rdma.env.mode must be PEER/RXE/DUT");
  status = candidate.scenario.validate();
  if (!status.ok())
    return status;
  if (!candidate.scenario.packet_defaults() && candidate.link_type != "rdma_link_netpkt")
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
      "rdma.pkt overrides require rdma_link_netpkt; driver/platform has no scenario packet configuration API");
  if (candidate.scenario.urc() && candidate.remote_funcs != 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "rdma.qp.type URC is unsupported by remote Functions");
  return rdma_status::success();
endfunction

// 功能：在项目全局预检成功后原地提交 RDMA 参数，保留全部共享句柄。
// 输入/输出及副作用：candidate 提供场景和时间值；更新现有 scenario 与 spec，不更换 cfg 或资源快照。
// 失败/边界：仅供已经预检且尚未初始化的事务调用；不分配资源或推进 WR 表达式。
function void rdma_env_cfg::apply_runtime_candidate(rdma_env_cfg	candidate);
  scenario.apply(candidate.scenario);
  poll_interval = candidate.poll_interval;
  response_timeout = candidate.response_timeout;
  spec = candidate.spec;
endfunction
