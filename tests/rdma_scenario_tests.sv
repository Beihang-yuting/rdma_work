// 目录：tests/rdma_scenario_tests.sv。
// 层：UVM 配置与业务契约测试，由 rdma_env_test_pkg 包含，不改旧 filelist。
// 职责：覆盖候选优先级/原子提交、初始化边界、单资源复用及实际 WR 表达式次数。
// 依赖：rdma_env_pkg、rdma_aip_cfg_pkg、aip_core_pkg；复用 env 测试基类。
// 所有权：测试拥有候选和计数求值器；环境拥有资源；快照和 Host manager 仅借用。
// 生命周期：build 装配，run 验证，仿真结束释放测试对象。

// 手动启动模型只用来验证统一候选入口；不伪造外部共享资源许可。
class rdma_candidate_env extends rdma_env;
  `uvm_component_utils(rdma_candidate_env)
  // 功能：构造由测试显式 initialize 的模型环境。
  // 输入/输出及副作用：name/parent 建立层次，不分配运行期资源。
  // 失败/边界：run_phase 不自动启动，测试负责调用 initialize。
  extern function new(string	name = "rdma_candidate_env", uvm_component	parent = null);
  // 功能：抑制自动模型初始化，以暴露合法的重载边界。
  // 输入/输出及副作用：phase 只读，立即返回。
  // 失败/边界：不调用 initialize 时环境始终未就绪。
  extern task run_phase(uvm_phase	phase);
endclass

// 功能：构造由测试显式 initialize 的模型环境。
// 输入/输出及副作用：name/parent 建立层次，不分配运行期资源。
// 失败/边界：run_phase 不自动启动，测试负责调用 initialize。
function rdma_candidate_env::new(string	name = "rdma_candidate_env", uvm_component	parent = null);
  super.new(name, parent);
endfunction

// 功能：抑制自动模型初始化，以暴露合法的重载边界。
// 输入/输出及副作用：phase 只读，立即返回。
// 失败/边界：不调用 initialize 时环境始终未就绪。
task rdma_candidate_env::run_phase(uvm_phase	phase);
endtask

// 候选读取观察器：factory 使 loader 新建的求值器也受监视；不改变返回值。
class rdma_reload_spy extends rdma_aip_value_spec;
  `uvm_object_utils(rdma_reload_spy)
  static int unsigned	calls;
  // 功能：建立候选读取的共享 eval 调用计数观察器。
  // 输入/输出及副作用：name 透传；calls 跨实例由测试显式清零。
  // 失败/边界：构造不抽样、不改变表达式。
  extern function new(string	name = "rdma_reload_spy");
  // 功能：记录候选读取期间不应出现的 eval 调用并委托已有求值器。
  // 输入/输出及副作用：spec 输入，value/why 输出；calls 递增一次。
  // 失败/边界：解析语义不变；任何调用会使候选测试失败，不掩盖其抽样。
  extern virtual function bit eval(string	spec, output longint unsigned	value, output string	why);
endclass

// 功能：建立候选读取的共享 eval 调用计数观察器。
// 输入/输出及副作用：name 透传；calls 跨实例由测试显式清零。
// 失败/边界：构造不抽样、不改变表达式。
function rdma_reload_spy::new(string	name = "rdma_reload_spy");
  super.new(name);
endfunction

// 功能：记录候选读取期间不应出现的 eval 调用并委托已有求值器。
// 输入/输出及副作用：spec 输入，value/why 输出；calls 递增一次。
// 失败/边界：解析语义不变；任何调用会使候选测试失败，不掩盖其抽样。
function bit rdma_reload_spy::eval(string	spec, output longint unsigned	value, output string	why);
  calls++;
  return super.eval(spec, value, why);
endfunction

class rdma_scenario_cfg_test extends uvm_test;
  `uvm_component_utils(rdma_scenario_cfg_test)
  rdma_env_cfg	cfg;
  rdma_candidate_env	env;
  // 功能：构造场景候选测试容器。
  // 输入/输出及副作用：name/parent 透传，cfg/env 在 build 创建。
  // 失败/边界：构造不读取参数或分配设备资源。
  extern function new(string	name = "rdma_scenario_cfg_test", uvm_component	parent = null);
  // 功能：建立单 Host 模型环境，固定关闭 coverage 以验证缺省保留。
  // 输入/输出及副作用：phase 透传；发布 cfg 并创建手动环境。
  // 失败/边界：不加载 CLI，运行期 candidate 才读取当前参数。
  extern function void build_phase(uvm_phase	phase);
  // 功能：核对状态是否与用例预期一致。
  // 输入/输出及副作用：label 定位用例，status/ok 只读。
  // 失败/边界：空 status 或成功位不匹配 fatal。
  extern function void expect_status(string	label, rdma_status	status, bit	ok);
  // 功能：核对十进制/十六进制 64 位边界及超长字面量，阻止长度/SGE/IPv4 回绕。
  // 输入/输出及副作用：创建独立场景并暂设 src_ip override；断言失败值清零与确定性语义拒绝。
  // 失败/边界：max64 接受，max64+1/+2、长数字与超宽 hex 必须拒绝；不求值分布或修改活动 cfg。
  extern function void numeric_boundaries();
  // 功能：验证候选优先级、空覆盖、固定字段、失败无更新以及初始化后拒绝。
  // 输入/输出及副作用：持有 objection；使用与 Tcl 相同的 override 表，最后清除测试键。
  // 失败/边界：断言失败 fatal；本测试不能和其它修改全局 override 的测试并行。
  extern task run_phase(uvm_phase	phase);
endclass

// 功能：构造场景候选测试容器。
// 输入/输出及副作用：name/parent 透传，cfg/env 在 build 创建。
// 失败/边界：构造不读取参数或分配设备资源。
function rdma_scenario_cfg_test::new(string	name = "rdma_scenario_cfg_test", uvm_component	parent = null);
  super.new(name, parent);
endfunction

// 功能：建立单 Host 模型环境，固定关闭 coverage 以验证缺省保留。
// 输入/输出及副作用：phase 透传；发布 cfg 并创建手动环境。
// 失败/边界：不加载 CLI，运行期 candidate 才读取当前参数。
function void rdma_scenario_cfg_test::build_phase(uvm_phase	phase);
  super.build_phase(phase);
  cfg = rdma_env_cfg::type_id::create("cfg");
  cfg.add_func(0);
  cfg.cov_enable = 0;
  cfg.link_type = "rdma_link_netpkt";
  cfg.vseq_type = "rdma_traffic_vseq";
  uvm_config_db#(rdma_env_cfg)::set(this, "env", "cfg", cfg);
  env = rdma_candidate_env::type_id::create("env", this);
endfunction

// 功能：核对状态是否与用例预期一致。
// 输入/输出及副作用：label 定位用例，status/ok 只读。
// 失败/边界：空 status 或成功位不匹配 fatal。
function void rdma_scenario_cfg_test::expect_status(string	label, rdma_status	status, bit	ok);
  if (status == null || status.ok() != ok)
    `uvm_fatal("SCENARIO_CFG", {label, ": ", status == null ? "null" : status.convert2string()})
endfunction

  // 功能：核对十进制/十六进制 64 位边界及超长字面量，阻止长度/SGE/IPv4 回绕。
  // 输入/输出及副作用：创建独立场景并暂设 src_ip override；断言失败值清零与确定性语义拒绝。
  // 失败/边界：max64 接受，max64+1/+2、长数字与超宽 hex 必须拒绝；不求值分布或修改活动 cfg。
function void rdma_scenario_cfg_test::numeric_boundaries();
  string	invalid[$];
  longint unsigned	value;
  bit	overflow;
  bit	parsed;
  bit [31:0]	ip;
  rdma_scenario_cfg	scenario;
  rdma_status	status;
  rdma_env_cfg	candidate;
  rdma_aip_value_spec	evaluator;
  string	why;

  parsed = rdma_value_spec::parse_number("18446744073709551615", value, overflow);
  if (!parsed || overflow || value != 64'hffff_ffff_ffff_ffff)
    `uvm_fatal("NUMERIC_BOUNDARY", "decimal max64 rejected")
  parsed = rdma_value_spec::parse_number("0xffff_ffff_ffff_ffff", value, overflow);
  if (!parsed || overflow || value != 64'hffff_ffff_ffff_ffff)
    `uvm_fatal("NUMERIC_BOUNDARY", "hex max64 rejected")
  invalid = '{"18446744073709551616", "18446744073709551617",
    "99999999999999999999999999999999999999", "0x10000000000000000", "0x10000000000000001"};
  scenario = rdma_scenario_cfg::type_id::create("numeric_scenario");
  evaluator = rdma_aip_value_spec::type_id::create("overflow_evaluator");
  foreach (invalid[i]) begin
    value = 1;
    parsed = rdma_value_spec::parse_number(invalid[i], value, overflow);
    if (parsed || !overflow || value != 0)
      `uvm_fatal("NUMERIC_BOUNDARY", {"overflow published a wrapped value: ", invalid[i]})
    scenario.traffic.len = invalid[i];
    expect_status("overflow length candidate", scenario.validate(), 0);
    scenario.traffic.len = "64";
    scenario.traffic.sge = invalid[i];
    expect_status("overflow SGE candidate", scenario.validate(), 0);
    scenario.traffic.sge = "1";
    if (evaluator.eval(invalid[i], value, why) || value != 0)
      `uvm_fatal("NUMERIC_BOUNDARY", "AIP fallback accepted an overflowing literal")
    aip_core_pkg::aip_cmdline_override::set_val("rdma.traffic.len", invalid[i]);
    status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
    expect_status("public overflow length", status, 0);
    aip_core_pkg::aip_cmdline_override::clear("rdma.traffic.len");
    aip_core_pkg::aip_cmdline_override::set_val("rdma.traffic.sge", invalid[i]);
    status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
    expect_status("public overflow SGE", status, 0);
    aip_core_pkg::aip_cmdline_override::clear("rdma.traffic.sge");
  end
  if (evaluator.eval("[18446744073709551617:18446744073709551617]", value, why) || value != 0)
    `uvm_fatal("NUMERIC_BOUNDARY", "AIP fallback accepted an overflowing range endpoint")
  parsed = rdma_value_spec::parse_number("[1:64]", value, overflow);
  if (parsed || overflow || value != 0)
    `uvm_fatal("NUMERIC_BOUNDARY", "distribution was classified as an overflowing literal")
  ip = 32'h01020304;
  aip_core_pkg::aip_cmdline_override::set_val("rdma.pkt.src_ip", "18446744073709551617.1.2.3");
  status = rdma_aip_cfg_loader::ip_param("src_ip", ip);
  expect_status("oversized IPv4 octet", status, 0);
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
  expect_status("public oversized IPv4 octet", status, 0);
  if (ip != 32'h01020304)
    `uvm_fatal("NUMERIC_BOUNDARY", "failed IPv4 parse published a partial value")
  aip_core_pkg::aip_cmdline_override::clear("rdma.pkt.src_ip");
endfunction

// 功能：验证候选优先级、空覆盖、固定字段、失败无更新以及初始化后拒绝。
// 输入/输出及副作用：持有 objection；使用与 Tcl 相同的 override 表，最后清除测试键。
// 失败/边界：断言失败 fatal；本测试不能和其它修改全局 override 的测试并行。
task rdma_scenario_cfg_test::run_phase(uvm_phase	phase);
  rdma_env_cfg	candidate;
  rdma_scenario_cfg	original;
  rdma_status	status;
  dpu_device_snapshot	snapshot;
  rdma_host_mem	memory;
  process	current_process;
  rdma_value_spec	original_spec;
  string	random_state;
  int unsigned	expected_depth;
  rdma_reload_spy	spy;

  phase.raise_objection(this);
  numeric_boundaries();
  original = cfg.scenario;
  snapshot = env.sys.snapshot;
  memory = env.sys.nodes[0].mem;
  cfg.scenario.qp.depth = 1024;
  original_spec = cfg.spec;
  current_process = process::self();
  random_state = current_process.get_randstate();
  status = cfg.scenario.validate();
  expect_status("deterministic validation", status, 1);
  if (current_process.get_randstate() != random_state)
    `uvm_fatal("SCENARIO_CFG", "validation consumed WR random state")
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
  expect_status("fresh candidate", status, 1);
  expected_depth = 256;
  void'($value$plusargs("EXPECT_DEPTH=%d", expected_depth));
  if (candidate.scenario.qp.depth != expected_depth || candidate.cov_enable != 0 ||
      candidate.link_type != cfg.link_type || candidate.vseq_type != cfg.vseq_type)
    `uvm_fatal("SCENARIO_CFG", "fresh mutable defaults/fixed defaults/CLI projection mismatch")
  // raw 字符串断言同时防止绕过 eval 的 AIP string 宏提前抽取逗号候选。
  rdma_aip_value_spec::type_id::set_type_override(rdma_reload_spy::get_type());
  spy = rdma_reload_spy::type_id::create("active_spy");
  cfg.spec = spy;
  original_spec = spy;
  rdma_reload_spy::calls = 0;
  aip_core_pkg::aip_cmdline_override::set_val("rdma.traffic.len", "[17:31]");
  aip_core_pkg::aip_cmdline_override::set_val("rdma.traffic.sge", "[1:4]");
  aip_core_pkg::aip_cmdline_override::set_val("rdma.traffic.data_mode", "FIXED,PATTERN");
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
  expect_status("raw candidate load", status, 1);
  if (rdma_reload_spy::calls != 0 || candidate.scenario.traffic.len != "[17:31]" ||
      candidate.scenario.traffic.sge != "[1:4]" || candidate.scenario.traffic.data_mode != "FIXED,PATTERN")
    `uvm_fatal("SCENARIO_CFG", "candidate load sampled or changed a WR distribution")
  aip_core_pkg::aip_cmdline_override::clear("rdma.traffic.len");
  aip_core_pkg::aip_cmdline_override::clear("rdma.traffic.sge");
  aip_core_pkg::aip_cmdline_override::clear("rdma.traffic.data_mode");
  aip_core_pkg::aip_cmdline_override::set_val("depth", "512");
  aip_core_pkg::aip_cmdline_override::set_val("rdma.qp.depth", "128");
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
  expect_status("full override", status, 1);
  if (candidate.scenario.qp.depth != 128)
    `uvm_fatal("SCENARIO_CFG", "full override did not beat leaf/CLI")
  aip_core_pkg::aip_cmdline_override::clear("rdma.qp.depth");
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
  expect_status("leaf override", status, 1);
  if (candidate.scenario.qp.depth != 512)
    `uvm_fatal("SCENARIO_CFG", "leaf override did not beat full CLI")
  aip_core_pkg::aip_cmdline_override::set_val("rdma.traffic.len", "");
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
  expect_status("empty raw override", status, 0);
  if (cfg.scenario != original || cfg.scenario.qp.depth != 1024 || cfg.spec != original_spec)
    `uvm_fatal("SCENARIO_CFG", "failed candidate changed active state")
  aip_core_pkg::aip_cmdline_override::clear("rdma.traffic.len");
  aip_core_pkg::aip_cmdline_override::set_val("rdma.env.cov_enable", "1");
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
  expect_status("fixed candidate read", status, 1);
  expect_status("fixed change reject", env.validate_runtime_candidate(candidate), 0);
  aip_core_pkg::aip_cmdline_override::clear("rdma.env.cov_enable");
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
  expect_status("valid candidate", status, 1);
  expect_status("pre-init guard", env.validate_runtime_candidate(candidate), 1);
  env.apply_runtime_candidate(candidate);
  if (cfg.scenario != original || cfg.scenario.qp.depth != 512 || env.sys.snapshot != snapshot ||
      env.sys.nodes[0].mem != memory || env.res.funcs.size() != 0)
    `uvm_fatal("SCENARIO_CFG", "commit replaced identity or allocated resources")
  candidate.scenario.qp.kind = RDMA_SCENARIO_UD;
  candidate.scenario.traffic.op = "read";
  expect_status("UD read", env.validate_runtime_candidate(candidate), 0);
  candidate.scenario.qp.kind = RDMA_SCENARIO_URC;
  candidate.scenario.traffic.op = "send_imm";
  expect_status("URC send_imm", env.validate_runtime_candidate(candidate), 0);
  candidate.scenario.qp.kind = RDMA_SCENARIO_RC;
  candidate.scenario.traffic.op = "write";
  candidate.scenario.mem.mr_remote_write = 0;
  expect_status("write permission", env.validate_runtime_candidate(candidate), 0);
  status = rdma_aip_cfg_loader::make_runtime_candidate(cfg, candidate);
  expect_status("restore valid candidate", status, 1);
  candidate.scenario.pkt.vlan_id = 4096;
  expect_status("packet width", env.validate_runtime_candidate(candidate), 0);
  candidate.scenario.pkt.vlan_id = 0;
  env.initialize(status);
  expect_status("initialize", status, 1);
  expect_status("live idle reload", env.validate_runtime_candidate(candidate), 0);
  aip_core_pkg::aip_cmdline_override::clear("depth");
  phase.drop_objection(this);
endtask

// 计数器包装现有求值器，不改变每条 WR 的值或随机语义。
class rdma_counting_spec extends rdma_aip_value_spec;
  `uvm_object_utils(rdma_counting_spec)
  int unsigned	draws;
  // 功能：创建 eval 计数器，初始 draws=0。
  // 输入/输出及副作用：name 透传；不持有设备引用。
  // 失败/边界：语法与失败语义完整委托原 AIP 求值器。
  extern function new(string	name = "rdma_counting_spec");
  // 功能：为每次真实 WR eval 增加一次计数后委托原求值器。
  // 输入/输出及副作用：spec 输入，value/why 输出；draws 递增一次。
  // 失败/边界：原解析器 fatal 不被捕获，也不重试采样。
  extern virtual function bit eval(string	spec, output longint unsigned	value, output string	why);
endclass

// 功能：创建 eval 计数器，初始 draws=0。
// 输入/输出及副作用：name 透传；不持有设备引用。
// 失败/边界：语法与失败语义完整委托原 AIP 求值器。
function rdma_counting_spec::new(string	name = "rdma_counting_spec");
  super.new(name);
  draws = 0;
endfunction

// 功能：为每次真实 WR eval 增加一次计数后委托原求值器。
// 输入/输出及副作用：spec 输入，value/why 输出；draws 递增一次。
// 失败/边界：原解析器 fatal 不被捕获，也不重试采样。
function bit rdma_counting_spec::eval(string	spec, output longint unsigned	value, output string	why);
  draws++;
  return super.eval(spec, value, why);
endfunction

class rdma_scenario_traffic_test extends rdma_env_traffic_test;
  `uvm_component_utils(rdma_scenario_traffic_test)
  rdma_counting_spec	counter;
  // 功能：构造统一流量测试，继承 netpkt 链路与单场景 sequence。
  // 输入/输出及副作用：name/parent 透传，无资源创建。
  // 失败/边界：实际参数由基类 build 读取。
  extern function new(string	name = "rdma_scenario_traffic_test", uvm_component	parent = null);
  // 功能：参数读取后安装计数求值器，用于观察真实 WR 抽样次数。
  // 输入/输出及副作用：phase 透传；cfg.spec 指向测试拥有的 counter。
  // 失败/边界：不改变参数和随机值，不进行预抽样。
  extern function void build_phase(uvm_phase	phase);
  // 功能：运行流量后核对每端只有一组 PD/CQ/QP/MR，并按显式期望核对 eval 次数。
  // 输入/输出及副作用：继承流量执行；读取资源池和 EXPECT_DRAWS plusarg。
  // 失败/边界：资源数量不等于1或计数不符 fatal；mix 可省略 EXPECT_DRAWS，仅核对资源复用。
  extern virtual task run_traffic();
endclass

// 功能：构造统一流量测试，继承 netpkt 链路与单场景 sequence。
// 输入/输出及副作用：name/parent 透传，无资源创建。
// 失败/边界：实际参数由基类 build 读取。
function rdma_scenario_traffic_test::new(string	name = "rdma_scenario_traffic_test", uvm_component	parent = null);
  super.new(name, parent);
endfunction

// 功能：参数读取后安装计数求值器，用于观察真实 WR 抽样次数。
// 输入/输出及副作用：phase 透传；cfg.spec 指向测试拥有的 counter。
// 失败/边界：不改变参数和随机值，不进行预抽样。
function void rdma_scenario_traffic_test::build_phase(uvm_phase	phase);
  super.build_phase(phase);
  counter = rdma_counting_spec::type_id::create("counter");
  cfg.spec = counter;
endfunction

// 功能：运行流量后核对每端只有一组 PD/CQ/QP/MR，并按显式期望核对 eval 次数。
// 输入/输出及副作用：继承流量执行；读取资源池和 EXPECT_DRAWS plusarg。
// 失败/边界：资源数量不等于1或计数不符 fatal；mix 可省略 EXPECT_DRAWS，仅核对资源复用。
task rdma_scenario_traffic_test::run_traffic();
  rdma_res_pd	pds[$];
  rdma_res_cq	cqs[$];
  rdma_res_qp	qps[$];
  rdma_res_mr	mrs[$];
  int unsigned	expected;
  super.run_traffic();
  foreach (env.res.funcs[i]) begin
    pds.delete();
    cqs.delete();
    qps.delete();
    mrs.delete();
    env.res.funcs[i].pds.all(pds);
    env.res.funcs[i].cqs.all(cqs);
    env.res.funcs[i].qps.all(qps);
    env.res.funcs[i].mrs.all(mrs);
    if (pds.size() != 1 || cqs.size() != 1 || qps.size() != 1 || mrs.size() != 1)
      `uvm_fatal("SCENARIO_RESOURCES", "single/mixed operation duplicated scenario resources")
  end
  if ($value$plusargs("EXPECT_DRAWS=%d", expected) && counter.draws != expected)
    `uvm_fatal("SCENARIO_DRAWS", $sformatf("draws=%0d expected=%0d", counter.draws, expected))
endtask

// 多 Function 流量回归：一个 RDMA env 内按 global Function ID 建三条独立业务边，验证拓扑不依赖固定两端。
class rdma_scenario_multifunc_test extends rdma_env_traffic_test;
  `uvm_component_utils(rdma_scenario_multifunc_test)

  // 功能：构造动态 Function/flow group 回归测试。
  // 输入/输出及副作用：name/parent 透传；不在构造阶段创建快照、QP 或 Host 内存。
  // 失败/边界：拓扑和业务边由 configure 在 env build 前填写，运行期资源由统一 traffic sequence 创建。
  extern function new(string name = "rdma_scenario_multifunc_test", uvm_component parent = null);

  // 功能：声明两个 Host 上六个由 dpu_common 分配 global ID 的 Function，并配置三条不同 QP 数量的业务边。
  // 输入/输出及副作用：修改尚未冻结的 cfg.funcs/flow_groups；不手工分配 ID、QP 或内存。
  // 失败/边界：Function 数量受冻结 snapshot 的 capability 限制；global ID 必须与稳定排序一致（0<->2、1<->3、4<->5），缺端点时 env build 拒绝。
  extern virtual function void configure(rdma_env_cfg c);

  // 功能：运行统一场景后检查所有 Function 的 global ID 映射及每条业务边的 QP/CQ 数量。
  // 输入/输出及副作用：读取 env/sys/res 只读状态；不创建第二个 env 或重新绑定共享资源。
  // 失败/边界：任一 Function 缺失、映射错位或资源数量不是期望值时报告 UVM_FATAL。
  extern virtual task run_traffic();
endclass

// 功能：构造动态 Function/flow group 回归测试。
// 输入/输出及副作用：name/parent 透传；不在构造阶段创建快照、QP 或 Host 内存。
// 失败/边界：拓扑和业务边由 configure 在 env build 前填写，运行期资源由统一 traffic sequence 创建。
function rdma_scenario_multifunc_test::new(string name = "rdma_scenario_multifunc_test",
                                           uvm_component parent = null);
  super.new(name, parent);
endfunction

// 功能：声明两个 Host 上六个由 dpu_common 分配 global ID 的 Function，并配置三条不同 QP 数量的业务边。
// 输入/输出及副作用：修改尚未冻结的 cfg.funcs/flow_groups；不手工分配 ID、QP 或内存。
// 失败/边界：Function 数量受冻结 snapshot 的 capability 限制；global ID 必须与稳定排序一致（0<->2、1<->3、4<->5），缺端点时 env build 拒绝。
function void rdma_scenario_multifunc_test::configure(rdma_env_cfg c);
  c.funcs.delete();
  c.flow_groups.delete();
  c.add_func(0, 0, DPU_FUNCTION_PF, 0);
  c.add_func(0, 0, DPU_FUNCTION_VF, 1);
  c.add_func(0, 0, DPU_FUNCTION_VF, 2);
  c.add_func(1, 0, DPU_FUNCTION_PF, 0);
  c.add_func(1, 0, DPU_FUNCTION_VF, 1);
  c.add_func(1, 0, DPU_FUNCTION_VF, 2);
  c.add_flow_group(0, 2, 2);
  c.add_flow_group(1, 3, 3);
  c.add_flow_group(4, 5, 1);
endfunction

// 功能：运行统一场景后检查所有 Function 的 global ID 映射及每条业务边的 QP/CQ 数量。
// 输入/输出及副作用：读取 env/sys/res 只读状态；不创建第二个 env 或重新绑定共享资源。
// 失败/边界：任一 Function 缺失、映射错位或资源数量不是期望值时报告 UVM_FATAL；期望列表按 ID 动态遍历。
task rdma_scenario_multifunc_test::run_traffic();
  rdma_res_cq cqs[$];
  rdma_res_qp qps[$];
  rdma_res_pd pds[$];
  rdma_res_mr mrs[$];
  int unsigned expected_ids[$] = '{0, 1, 2, 3, 4, 5};
  int unsigned expected_qps[$] = '{2, 3, 2, 3, 1, 1};
  int unsigned expected;

  super.run_traffic();
  if (env.res.funcs.size() != expected_ids.size() || expected_ids.size() != expected_qps.size())
    `uvm_fatal("SCENARIO_MULTIFUNC", $sformatf("expected %0d Functions, got %0d",
      expected_ids.size(), env.res.funcs.size()))
  foreach (expected_ids[i]) begin
    int function_index;
    int unsigned global_id;

    global_id = expected_ids[i];
    expected = expected_qps[i];
    function_index = env.find_function_index(global_id);
    if (function_index < 0)
      `uvm_fatal("SCENARIO_MULTIFUNC", $sformatf("global Function ID %0d was not published", global_id))
    pds.delete();
    cqs.delete();
    qps.delete();
    mrs.delete();
    env.res.funcs[function_index].pds.all(pds);
    env.res.funcs[function_index].cqs.all(cqs);
    env.res.funcs[function_index].qps.all(qps);
    env.res.funcs[function_index].mrs.all(mrs);
    if (pds.size() != 1 || mrs.size() != 1 || cqs.size() != expected ||
        qps.size() != expected)
      `uvm_fatal("SCENARIO_MULTIFUNC", $sformatf(
        "Function %0d resources pd=%0d mr=%0d cq=%0d qp=%0d expected cq/qp=%0d",
        global_id, pds.size(), mrs.size(), cqs.size(), qps.size(), expected))
  end
endtask

// 同一 Host 的多 PF 流量回归：一个 Host 下的 PF0/PF1 通过 dpu_common 发布不同 global ID，
//   一条业务边为两端各建立两个独立 QP，验证 PF 级身份、资源归属和 QP 对端关系。
class rdma_scenario_same_host_pf_test extends rdma_env_traffic_test;
  `uvm_component_utils(rdma_scenario_same_host_pf_test)

  // 功能：构造同一 Host 双 PF 的统一流量回归测试。
  // 输入/输出及副作用：name/parent 透传；不在构造阶段创建快照、Function 或 QP。
  // 失败/边界：拓扑和业务边由 configure 在 env build 前声明，资源及连接由统一 traffic sequence 创建。
  extern function new(string name = "rdma_scenario_same_host_pf_test", uvm_component parent = null);

  // 功能：声明 Host0 的 PF0/PF1，并按 dpu_common 稳定 global ID 顺序配置双 QP 业务边。
  // 输入/输出及副作用：修改尚未冻结的 cfg.funcs/flow_groups；不手工分配 BDF、BAR、global ID 或 QP。
  // 失败/边界：PF 数量、Function ID 和 BAR 合法性由 dpu_common resolver 与 env finalize 检查。
  extern virtual function void configure(rdma_env_cfg c);

  // 功能：运行 PF0↔PF1 流量后核对两端身份、独立资源数量和每个 QP 的对端绑定。
  // 输入/输出及副作用：读取 env.sys/res 中冻结的 Function 与资源句柄；不创建第二个 env 或修改资源。
  // 失败/边界：要求两个 Function 同 Host 且 PF ID 不同；任一端缺少 1 个 PD/MR、2 个 CQ/QP 或 QP 对端错配时 fatal。
  extern virtual task run_traffic();
endclass

// 功能：构造同一 Host 双 PF 的统一流量回归测试。
// 输入/输出及副作用：name/parent 透传；不在构造阶段创建快照、Function 或 QP。
// 失败/边界：拓扑和业务边由 configure 在 env build 前声明，资源及连接由统一 traffic sequence 创建。
function rdma_scenario_same_host_pf_test::new(string name = "rdma_scenario_same_host_pf_test",
                                              uvm_component parent = null);
  super.new(name, parent);
endfunction

// 功能：声明 Host0 的 PF0/PF1，并按 dpu_common 稳定 global ID 顺序配置双 QP 业务边。
// 输入/输出及副作用：修改尚未冻结的 cfg.funcs/flow_groups；不手工分配 BDF、BAR、global ID 或 QP。
// 失败/边界：PF 数量、Function ID 和 BAR 合法性由 dpu_common resolver 与 env finalize 检查。
function void rdma_scenario_same_host_pf_test::configure(rdma_env_cfg c);
  c.funcs.delete();
  c.flow_groups.delete();
  c.add_func(0, 0, DPU_FUNCTION_PF, 0);
  c.add_func(0, 1, DPU_FUNCTION_PF, 0);
  c.add_flow_group(0, 1, 2);
endfunction

// 功能：运行 PF0↔PF1 流量后核对两端身份、独立资源数量和每个 QP 的对端绑定。
// 输入/输出及副作用：读取 env.sys/res 中冻结的 Function 与资源句柄；不创建第二个 env 或修改资源。
// 失败/边界：要求两个 Function 同 Host 且 PF ID 不同；任一端缺少 1 个 PD/MR、2 个 CQ/QP 或 QP 对端错配时 fatal。
task rdma_scenario_same_host_pf_test::run_traffic();
  rdma_res_cq cqs[$];
  rdma_res_qp qps[$];
  rdma_res_pd pds[$];
  rdma_res_mr mrs[$];
  rdma_res_func pf[2];
  int function_index;

  super.run_traffic();
  if (env.res.funcs.size() != 2)
    `uvm_fatal("SCENARIO_SAME_HOST_PF", $sformatf("expected two PF Functions, got %0d",
      env.res.funcs.size()))
  for (int unsigned n = 0; n < 2; n++) begin
    function_index = env.find_function_index(n);
    if (function_index < 0)
      `uvm_fatal("SCENARIO_SAME_HOST_PF", $sformatf(
        "PF global Function ID %0d was not published", n))
    pf[n] = env.res.funcs[function_index];
    if (pf[n] == null)
      `uvm_fatal("SCENARIO_SAME_HOST_PF", $sformatf(
        "PF global Function ID %0d has no resource record", n))
    else if (pf[n].node == null || pf[n].node.func == null || pf[n].node.func.key.host_id != 0 ||
             pf[n].node.func.key.pf_id != n || pf[n].node.func.key.kind != DPU_FUNCTION_PF)
      `uvm_fatal("SCENARIO_SAME_HOST_PF", $sformatf(
        "global Function ID %0d is not Host0 PF%0d", n, n))
  end
  foreach (pf[n]) begin
    pds.delete();
    cqs.delete();
    qps.delete();
    mrs.delete();
    pf[n].pds.all(pds);
    pf[n].cqs.all(cqs);
    pf[n].qps.all(qps);
    pf[n].mrs.all(mrs);
    if (pds.size() != 1 || mrs.size() != 1 || cqs.size() != 2 || qps.size() != 2)
      `uvm_fatal("SCENARIO_SAME_HOST_PF", $sformatf(
        "PF%0d resources pd=%0d mr=%0d cq=%0d qp=%0d expected 1/1/2/2",
        n, pds.size(), mrs.size(), cqs.size(), qps.size()))
    foreach (qps[q]) begin
      if (qps[q] == null)
        `uvm_fatal("SCENARIO_SAME_HOST_PF", $sformatf(
          "PF%0d contains a null QP resource", n))
      else if (qps[q].owner == null || qps[q].peer == null || qps[q].send_cq == null ||
               qps[q].recv_cq == null)
        `uvm_fatal("SCENARIO_SAME_HOST_PF", $sformatf(
          "PF%0d QP%0d is missing owner, peer or CQ", n, qps[q].id))
      else if (qps[q].peer.owner == null || qps[q].peer.peer == null ||
               qps[q].send_cq.owner == null || qps[q].recv_cq.owner == null)
        `uvm_fatal("SCENARIO_SAME_HOST_PF", $sformatf(
          "PF%0d QP%0d has an incomplete peer/CQ owner", n, qps[q].id))
      else if (qps[q].owner.index != pf[n].index ||
               qps[q].peer.owner.index != pf[1 - n].index || qps[q].peer.peer != qps[q] ||
               qps[q].send_cq.owner.index != pf[n].index ||
               qps[q].recv_cq.owner.index != pf[n].index)
        `uvm_fatal("SCENARIO_SAME_HOST_PF", $sformatf(
          "PF%0d QP%0d has an invalid owner/peer/CQ binding", n, qps[q].id))
    end
  end
endtask

// 首次给出非法长度，第二次给出合法长度；任何重试都会被 fatal 观察器识别。
class rdma_invalid_first_spec extends rdma_value_spec;
  `uvm_object_utils(rdma_invalid_first_spec)
  int unsigned	calls;
  // 功能：构造首次非法、随后合法的确定性求值器。
  // 输入/输出及副作用：name 透传，calls 初始0，不持有随机源。
  // 失败/边界：只用于拒绝测试；不模拟完整表达式语法。
  extern function new(string	name = "rdma_invalid_first_spec");
  // 功能：第一次返回长度0，第二次返回64，后续返回1，揭露隐藏重采样。
  // 输入/输出及副作用：spec 不解析；value/why 输出成功和值，calls 递增一次。
  // 失败/边界：始终成功，越界必须由场景 draw 拒绝，而非由求值器伪造失败。
  extern virtual function bit eval(string	spec, output longint unsigned	value, output string	why);
endclass

// 功能：构造首次非法、随后合法的确定性求值器。
// 输入/输出及副作用：name 透传，calls 初始0，不持有随机源。
// 失败/边界：只用于拒绝测试；不模拟完整表达式语法。
function rdma_invalid_first_spec::new(string	name = "rdma_invalid_first_spec");
  super.new(name);
  calls = 0;
endfunction

// 功能：第一次返回长度0，第二次返回64，后续返回1，揭露隐藏重采样。
// 输入/输出及副作用：spec 不解析；value/why 输出成功和值，calls 递增一次。
// 失败/边界：始终成功，越界必须由场景 draw 拒绝，而非由求值器伪造失败。
function bit rdma_invalid_first_spec::eval(string	spec, output longint unsigned	value, output string	why);
  calls++;
  value = calls == 1 ? 0 : calls == 2 ? 64 : 1;
  why = "";
  return 1;
endfunction

class rdma_reject_post_probe extends uvm_subscriber #(rdma_verb_item);
  `uvm_component_utils(rdma_reject_post_probe)
  int unsigned	posts;
  // 功能：创建拒绝路径的实际 driver post 事件计数器。
  // 输入/输出及副作用：name/parent 建立组件，posts 初始0。
  // 失败/边界：测试必须连接两端 driver.posted_ap，否则不能证明无投递。
  extern function new(string	name = "rdma_reject_post_probe", uvm_component	parent = null);
  // 功能：记录每次 driver 已成功投递的业务或接收 WR。
  // 输入/输出及副作用：t 只读；posts 递增，不修改事务或设备。
  // 失败/边界：非法长度场景期望此函数从未被调用。
  extern virtual function void write(rdma_verb_item	t);
endclass

// 功能：创建拒绝路径的实际 driver post 事件计数器。
// 输入/输出及副作用：name/parent 建立组件，posts 初始0。
// 失败/边界：测试必须连接两端 driver.posted_ap，否则不能证明无投递。
function rdma_reject_post_probe::new(string	name = "rdma_reject_post_probe", uvm_component	parent = null);
  super.new(name, parent);
  posts = 0;
endfunction

// 功能：记录每次 driver 已成功投递的业务或接收 WR。
// 输入/输出及副作用：t 只读；posts 递增，不修改事务或设备。
// 失败/边界：非法长度场景期望此函数从未被调用。
function void rdma_reject_post_probe::write(rdma_verb_item	t);
  posts++;
endfunction

class rdma_reject_catcher extends uvm_report_catcher;
  rdma_invalid_first_spec	spec;
  rdma_reject_post_probe	probe;
  // 功能：建立只观察目标场景 fatal、不吞掉错误的报告回调。
  // 输入/输出及副作用：name 透传；spec/probe 稍后由测试绑定，均非拥有引用。
  // 失败/边界：仅在两个观察句柄绑定之后注册到 UVM 回调列表。
  extern function new(string	name = "rdma_reject_catcher");
  // 功能：在真实拒绝发生时证明一次eval且零post，输出机器可判定标志后保留fatal。
  // 输入/输出及副作用：读取 report/spec/probe；成功打印 REJECT_ONCE，返回 THROW。
  // 失败/边界：次数或路径不符直接 $fatal；不降级、不捕获或继续失败 WR。
  extern virtual function action_e catch();
endclass

// 功能：建立只观察目标场景 fatal、不吞掉错误的报告回调。
// 输入/输出及副作用：name 透传；spec/probe 稍后由测试绑定，均非拥有引用。
// 失败/边界：仅在两个观察句柄绑定之后注册到 UVM 回调列表。
function rdma_reject_catcher::new(string	name = "rdma_reject_catcher");
  super.new(name);
endfunction

// 功能：在真实拒绝发生时证明一次eval且零post，输出机器可判定标志后保留fatal。
// 输入/输出及副作用：读取 report/spec/probe；成功打印 REJECT_ONCE，返回 THROW。
// 失败/边界：次数或路径不符直接 $fatal；不降级、不捕获或继续失败 WR。
function uvm_report_catcher::action_e rdma_reject_catcher::catch();
  string	message;
  if (get_severity() == UVM_FATAL && get_id() == "RDMA_SCENARIO") begin
    message = get_message();
    if (spec.calls != 1 || probe.posts != 0 || message.len() < 16 ||
        message.substr(0, 15) != "rdma.traffic.len")
      $fatal(1, "REJECT_ONCE failed: calls=%0d posts=%0d %s", spec.calls, probe.posts, message);
    $display("REJECT_ONCE draws=1 posts=0");
  end
  return THROW;
endfunction

class rdma_scenario_reject_test extends rdma_env_traffic_test;
  `uvm_component_utils(rdma_scenario_reject_test)
  rdma_invalid_first_spec	scripted;
  rdma_reject_post_probe	probe;
  rdma_reject_catcher	observer;
  // 功能：构造单条SEND非法抽样的预期fatal测试。
  // 输入/输出及副作用：name/parent 透传，不修改生产实现。
  // 失败/边界：测试通过条件为指定fatal和REJECT_ONCE标志，不能按普通零fatal用例运行。
  extern function new(string	name = "rdma_scenario_reject_test", uvm_component	parent = null);
  // 功能：在参数读取后强制单条SEND并安装非法后合法求值器与post计数器。
  // 输入/输出及副作用：phase 透传；替换测试cfg.spec并建立probe，场景长度文本本身保持合法。
  // 失败/边界：避免原子分支跳过len；不在build调用eval或发WR。
  extern function void build_phase(uvm_phase	phase);
  // 功能：连接所有端点的真实post事件到同一个计数器。
  // 输入/输出及副作用：phase 透传；增加只读analysis订阅。
  // 失败/边界：必须在env完成build之后执行，probe已创建。
  extern function void connect_phase(uvm_phase	phase);
  // 功能：安装fatal观察器后执行真实统一流量，证明越界在任何post之前拒绝。
  // 输入/输出及副作用：运行资源创建/连接与首次WR生成；正常情况下以原fatal结束。
  // 失败/边界：若序列返回说明非法抽样被吞掉或重试，以不同fatal报告测试失败。
  extern virtual task run_traffic();
endclass

// 功能：构造单条SEND非法抽样的预期fatal测试。
// 输入/输出及副作用：name/parent 透传，不修改生产实现。
// 失败/边界：测试通过条件为指定fatal和REJECT_ONCE标志，不能按普通零fatal用例运行。
function rdma_scenario_reject_test::new(string	name = "rdma_scenario_reject_test", uvm_component	parent = null);
  super.new(name, parent);
endfunction

// 功能：在参数读取后强制单条SEND并安装非法后合法求值器与post计数器。
// 输入/输出及副作用：phase 透传；替换测试cfg.spec并建立probe，场景长度文本本身保持合法。
// 失败/边界：避免原子分支跳过len；不在build调用eval或发WR。
function void rdma_scenario_reject_test::build_phase(uvm_phase	phase);
  super.build_phase(phase);
  cfg.scenario.traffic.op = "send";
  cfg.scenario.traffic.count = 1;
  cfg.scenario.traffic.len = "64";
  cfg.scenario.traffic.sge = "1";
  scripted = rdma_invalid_first_spec::type_id::create("scripted");
  cfg.spec = scripted;
  probe = rdma_reject_post_probe::type_id::create("probe", this);
endfunction

// 功能：连接所有端点的真实post事件到同一个计数器。
// 输入/输出及副作用：phase 透传；增加只读analysis订阅。
// 失败/边界：必须在env完成build之后执行，probe已创建。
function void rdma_scenario_reject_test::connect_phase(uvm_phase	phase);
  super.connect_phase(phase);
  foreach (env.verb[i])
    env.verb[i].driver.posted_ap.connect(probe.analysis_export);
endfunction

// 功能：安装fatal观察器后执行真实统一流量，证明越界在任何post之前拒绝。
// 输入/输出及副作用：运行资源创建/连接与首次WR生成；正常情况下以原fatal结束。
// 失败/边界：若序列返回说明非法抽样被吞掉或重试，以不同fatal报告测试失败。
task rdma_scenario_reject_test::run_traffic();
  observer = new("observer");
  observer.spec = scripted;
  observer.probe = probe;
  uvm_report_cb::add(null, observer);
  super.run_traffic();
  `uvm_fatal("REJECT_MISSING", "invalid-first evaluator did not terminate at the first draw")
endtask
