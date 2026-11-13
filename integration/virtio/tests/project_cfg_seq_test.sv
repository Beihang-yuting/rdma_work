// 目录/层次：integration/virtio/tests；独立项目配置 sequence 的直接 AIP 注册回归。
// 职责：验证 load_params 后新建 sequence 自动取得原 cfg/grant，并完成两 PF 的配置与 Notify DWORD 写入。
// 依赖：本文件包含于 rdma_virtio_test_pkg；生产组合环境和 AIP 宏，复用已有寄存器传输 fixture。
// 所有权/生命周期：探针借用配置句柄，传输 fixture 拥有字节存储；不提供真实 DUT 或数据面 completion。
uvm_sequencer #(pcie_tl_tlp)	cfg_seq_rc;

// 先检查对象绑定，再执行原 RDMA 配置流程；仅最底层 PCIe 寄存器传输由既有 fixture 接收。
class project_cfg_binding_probe extends rdma_project_cfg_seq;
  `uvm_object_utils(project_cfg_binding_probe)
  static int unsigned	calls;

  // 功能：构造不拥有配置或硬件的 RDMA 子流程探针。
  // 输入/输出及副作用：name 交给父类；calls 跨命令累计，不在构造时清零。
  // 失败/边界：只由定向测试安装 factory override，不进入生产 filelist。
  extern function new(string	name = "project_cfg_binding_probe");

  // 功能：核对原 cfg/Function/grant 绑定，执行生产配置并检查两 PF 的 Notify 写入。
  // 输入/输出及副作用：清理传输记录后调用父类 body；成功才增加 calls，保留真实 success/error_msg。
  // 失败/边界：对象异源/遗漏、生产预检或写入失败、Notify 内容/次序不符均失败，不注入配置成功状态。
  extern virtual task body();

  // 功能：以冻结 BAR 和 grant 独立计算 PF Notify 字段，检查地址排序及高 DWORD 先写。
  // 输入/输出及副作用：只读 cfg、rdma_grants 和传输 accesses；不调用生产 Notify 编码器或修改 catalog。
  // 失败/边界：本例限定 Host0 两 PF；缺项/重复、目标/宽度/内容错误或低 DWORD 先写均 fatal。
  extern function void check_notify();
endclass

// 功能：构造不拥有配置或硬件的 RDMA 子流程探针。
// 输入/输出及副作用：name 交给父类；calls 跨命令累计，不在构造时清零。
// 失败/边界：只由定向测试安装 factory override，不进入生产 filelist。
function project_cfg_binding_probe::new(string	name = "project_cfg_binding_probe");
  super.new(name);
endfunction

// 功能：核对原 cfg/Function/grant 绑定，执行生产配置并检查两 PF 的 Notify 写入。
// 输入/输出及副作用：清理传输记录后调用父类 body；成功才增加 calls，保留真实 success/error_msg。
// 失败/边界：对象异源/遗漏、生产预检或写入失败、Notify 内容/次序不符均失败，不注入配置成功状态。
task project_cfg_binding_probe::body();
  project_env_cfg	expected;

  expected = project_runtime_env.cfg;
  if (cfg != expected.dpu_cfg || rdma_functions.size() == 0 ||
      rdma_functions.size() != expected.rdma_functions.size() ||
      rdma_grants.size() != expected.rdma_cfg.grants.size())
    `uvm_fatal("CFG_SEQ_TEST", "direct sequence did not consume existing project configuration")
  foreach (rdma_functions[i]) begin
    if (!dpu_same_function_key(rdma_functions[i], expected.rdma_functions[i]) ||
        rdma_grants[i] != expected.rdma_cfg.grants[i])
      `uvm_fatal("CFG_SEQ_TEST", "direct sequence changed Function or grant identity")
  end
  rdma_config_reg_fixture::reset_fixture();
  super.body();
  if (!success)
    return;
  check_notify();
  calls++;
endtask

// 功能：以冻结 BAR 和 grant 独立计算 PF Notify 字段，检查地址排序及高 DWORD 先写。
// 输入/输出及副作用：只读 cfg、rdma_grants 和传输 accesses；不调用生产 Notify 编码器或修改 catalog。
// 失败/边界：本例限定 Host0 两 PF；缺项/重复、目标/宽度/内容错误或低 DWORD 先写均 fatal。
function void project_cfg_binding_probe::check_notify();
  logic [63:0]		expected_by_address[bit [63:0]];
  rdma_config_access_t	writes[$];
  dpu_bar_target_t	management;
  int unsigned		row;
  string		why;

  if (!cfg.bar_map.resolve_name("h0.pf0.bar0", management, why))
    `uvm_fatal("CFG_SEQ_TEST", why)
  foreach (rdma_grants[i]) begin
    dpu_bar_pair_lease_t	bar;
    bit [63:0]			address;

    if (rdma_grants[i].key.kind != DPU_FUNCTION_PF || rdma_grants[i].host_id != 0 ||
        !cfg.device_snapshot.get_bar(rdma_grants[i].key, DPU_BAR_DEVICE_MEMORY, bar, why))
      `uvm_fatal("CFG_SEQ_TEST", "Notify fixture requires two resolved Host0 PFs")
    address = bar.base + 'h2000;
    expected_by_address[address] = (64'(rdma_grants[i].rdma_vf_id) << 51) | (address >> 13);
  end
  foreach (rdma_config_reg_fixture::accesses[i]) begin
    rdma_config_access_t	access;

    access = rdma_config_reg_fixture::accesses[i];
    if (access.writing && access.address >= management.bar_lease.base + 'hc000 &&
        access.address < management.bar_lease.base + 'hc800)
      writes.push_back(access);
  end
  if (expected_by_address.num() != 2 || writes.size() != 4)
    `uvm_fatal("CFG_SEQ_TEST", "two PFs must each emit exactly two Notify DWORD writes")
  row = 0;
  foreach (expected_by_address[address]) begin
    for (int unsigned	word = 0; word < 2; word++) begin
      rdma_config_access_t	access;
      logic [63:0]		expected;

      access = writes[2 * row + word];
      expected = expected_by_address[address];
      if (access.host != 0 || access.length != 4 ||
          access.address != management.bar_lease.base + 'hc000 + row * 8 + (word == 0 ? 4 : 0) ||
          access.data != (word == 0 ? 128'(expected[63:32]) : 128'(expected[31:0])))
        `uvm_fatal("CFG_SEQ_TEST", "PF Notify sorting, ID or DWORD order mismatch")
    end
    row++;
  end
endfunction

// 原环境负责所有参数、grant 和 AIP 绑定；测试仅给直接注册宏提供真实管理 RC。
class project_cfg_seq_test extends rdma_virtio_smoke_test;
  `uvm_component_utils(project_cfg_seq_test)

  // 功能：构造复用组合环境、共享资源和寄存器 fixture 的配置测试。
  // 输入/输出及副作用：name/parent 透传；不拥有额外 snapshot、pool 或 grant。
  // 失败/边界：仅支持直接注册 sequence 的配置传输测试，不启动 DUT、driver 或流量。
  extern function new(string	name = "project_cfg_seq_test", uvm_component	parent = null);

  // 功能：保留原环境构建，为配置子流程安装观察探针和既有寄存器传输 fixture。
  // 输入/输出及副作用：factory override 只对本测试进程生效；生产预检/写表及状态管理照常执行。
  // 失败/边界：不覆盖 project_dut_config_seq，不向它设置 cfg、Function 或 grant。
  extern virtual function void build_phase(uvm_phase	phase);

  // 功能：沿用 Intel VIF 绑定，并在发布前声明测试平台的 RDMA Notify/RNET 表布局。
  // 输入/输出及副作用：仅写 authoring table_layouts；布局与独立配置 fixture 一致，不修改冻结快照。
  // 失败/边界：真实平台必须提供自己的硬件布局；此声明不改变 DUT 能力或 Function 身份。
  extern virtual function void bind_platform_handles();

  // 功能：从实际 BAR map 取得直接注册命令使用的管理 RC。
  // 输入/输出及副作用：cfg_seq_rc 借用已有 RC，向传输 fixture 登记 Host/AF 地址；父类验证自动 grant。
  // 失败/边界：RC 解析失败 fatal，不猜测路径或临时创建 sequencer。
  extern virtual function void end_of_elaboration_phase(uvm_phase	phase);
endclass

// 功能：构造复用组合环境、共享资源和寄存器 fixture 的配置测试。
// 输入/输出及副作用：name/parent 透传；不拥有额外 snapshot、pool 或 grant。
// 失败/边界：仅支持直接注册 sequence 的配置传输测试，不启动 DUT、driver 或流量。
function project_cfg_seq_test::new(
  string	name = "project_cfg_seq_test",
  uvm_component	parent = null
);
  super.new(name, parent);
endfunction

// 功能：保留原环境构建，为配置子流程安装观察探针和既有寄存器传输 fixture。
// 输入/输出及副作用：factory override 只对本测试进程生效；生产预检/写表及状态管理照常执行。
// 失败/边界：不覆盖 project_dut_config_seq，不向它设置 cfg、Function 或 grant。
function void project_cfg_seq_test::build_phase(uvm_phase	phase);
  super.build_phase(phase);
  rdma_project_cfg_seq::type_id::set_type_override(project_cfg_binding_probe::get_type());
  pcie_tl_reg_seq::type_id::set_type_override(rdma_config_reg_fixture::get_type());
endfunction

// 功能：沿用 Intel VIF 绑定，并在发布前声明测试平台的 RDMA Notify/RNET 表布局。
// 输入/输出及副作用：仅写 authoring table_layouts；布局与独立配置 fixture 一致，不修改冻结快照。
// 失败/边界：真实平台必须提供自己的硬件布局；此声明不改变 DUT 能力或 Function 身份。
function void project_cfg_seq_test::bind_platform_handles();
  dpu_table_layout_t	layout;

  super.bind_platform_handles();
  layout = '{index_policy: DPU_INDEX_EXPLICIT, default: 0};
  layout.provided = 1;
  layout.reg_target = "h0.pf0.bar0";
  layout.table_offset = 'hc000;
  layout.entry_bytes = 8;
  layout.capacity = 256;
  cfg.dpu_cfg.table_layouts[DPU_TABLE_RDMA_NOTIFY] = layout;
  layout.reg_target = "pf0.bar0";
  layout.access_uses_owner_host = 1;
  layout.module_offset = 'hb00000;
  layout.table_offset = 'h15000;
  layout.entry_bytes = 4;
  cfg.dpu_cfg.table_layouts[DPU_TABLE_RNET] = layout;
endfunction

// 功能：从实际 BAR map 取得直接注册命令使用的管理 RC。
// 输入/输出及副作用：cfg_seq_rc 借用已有 RC，向传输 fixture 登记 Host/AF 地址；父类验证自动 grant。
// 失败/边界：RC 解析失败 fatal，不猜测路径或临时创建 sequencer。
function void project_cfg_seq_test::end_of_elaboration_phase(uvm_phase	phase);
  dpu_bar_target_t	management;
  string		why;

  super.end_of_elaboration_phase(phase);
  if (!get_management_rc(cfg_seq_rc, why))
    `uvm_fatal("CFG_SEQ_TEST", why)
  if (!cfg.dpu_cfg.bar_map.resolve_name("h0.pf0.bar0", management, why))
    `uvm_fatal("CFG_SEQ_TEST", why)
  rdma_config_reg_fixture::host_by_sequencer[cfg_seq_rc.get_full_name()] = 0;
  rdma_config_reg_fixture::af_address = management.bar_lease.base + 'h1010;
endfunction

// 宏仅创建/启动项目 sequence，与用户接入方式相同，没有调用前的字段赋值。
`aip_cmd_user_seq(cfg_seq_direct, project_dut_config_seq, cfg_seq_rc)

// 只捕获本用例精确注入的异源错误，其他配置失败保持 fatal。
class project_cfg_reject_catcher extends uvm_report_catcher;
  int unsigned	count;

  // 功能：构造只统计异源 cfg 拒绝的局部 catcher。
  // 输入/输出及副作用：name 传给基类；count 默认零，测试负责注册与注销。
  // 失败/边界：不能用于隐藏其他 fatal 或实际 DUT 错误。
  extern function new(string	name = "project_cfg_reject_catcher");

  // 功能：捕获 PROJECT_CONFIG_SEQ 的精确异源配置诊断并计数。
  // 输入/输出及副作用：匹配返回 CAUGHT，其余返回 THROW，不改变生产 sequence 状态。
  // 失败/边界：severity、id 或 message 任一不符均保留原报告。
  extern virtual function action_e catch();
endclass

// 功能：构造只统计异源 cfg 拒绝的局部 catcher。
// 输入/输出及副作用：name 传给基类；count 默认零，测试负责注册与注销。
// 失败/边界：不能用于隐藏其他 fatal 或实际 DUT 错误。
function project_cfg_reject_catcher::new(string	name = "project_cfg_reject_catcher");
  super.new(name);
endfunction

// 功能：捕获 PROJECT_CONFIG_SEQ 的精确异源配置诊断并计数。
// 输入/输出及副作用：匹配返回 CAUGHT，其余返回 THROW，不改变生产 sequence 状态。
// 失败/边界：severity、id 或 message 任一不符均保留原报告。
function uvm_report_catcher::action_e project_cfg_reject_catcher::catch();
  if (get_severity() == UVM_FATAL && get_id() == "PROJECT_CONFIG_SEQ" && get_message() ==
      "project_cfg and PCIe dpu_cfg must share the published resource snapshot") begin
    count++;
    return CAUGHT;
  end
  return THROW;
endfunction

// 功能：导出子流程调用次数、当前参数和 RDMA 配置门禁，供 Tcl 检查重载前后状态。
// 输入/输出及副作用：读取真实 registry 和项目 cfg，返回 calls/configured/initializable/count/busy。
// 失败/边界：target 缺失 fatal；initializable 只检查门禁，不调用 probe 或声称真实配置完成。
task cfg_seq_observe();
  aip_cmd		handle;
  rdma_aip_target	target;
  bit			initializable;
  string		why;

  handle = aip_cmd::get_handle("cfg_seq_observe");
  target = rdma_aip_registry::target;
  if (target == null)
    `uvm_fatal("CFG_SEQ_TEST", "RDMA target was not registered")
  initializable = target.can_initialize(why);
  handle.status = 0;
  handle.result_out = $sformatf("calls %0d configured %0d initializable %0d count %0d busy %0d",
    project_cfg_binding_probe::calls, target.configured, initializable,
    project_runtime_env.cfg.rdma_cfg.scenario.traffic.count, target.busy);
endtask
`aip_cmd_task(cfg_seq_observe, cfg_seq_observe)

// 功能：注入异源项目配置，验证真实 start 在调用任何配置子流程前拒绝。
// 输入/输出及副作用：临时覆盖管理 RC 的 project_cfg；捕获一次预期 fatal 后恢复原句柄。
// 失败/边界：错误诊断不符、调用了子流程或未释放 busy 均报错；原 RDMA 完成状态必须保留。
task cfg_seq_reject();
  project_cfg_seq_test		test;
  project_env_cfg		wrong_cfg;
  project_dut_config_seq	seq;
  project_cfg_reject_catcher	catcher;
  int unsigned			before_calls;
  aip_cmd			handle;

  if (!$cast(test, uvm_root::get().find("uvm_test_top")))
    `uvm_fatal("CFG_SEQ_TEST", "configuration test is unavailable")
  before_calls = project_cfg_binding_probe::calls;
  wrong_cfg = project_env_cfg::type_id::create("wrong_project_cfg");
  uvm_config_db#(project_env_cfg)::set(cfg_seq_rc, "", "project_cfg", wrong_cfg);
  catcher = new();
  uvm_report_cb::add(null, catcher);
  seq = project_dut_config_seq::type_id::create("reject_wrong_project");
  seq.start(cfg_seq_rc);
  uvm_report_cb::delete(null, catcher);
  uvm_config_db#(project_env_cfg)::set(cfg_seq_rc, "", "project_cfg", test.cfg);
  test.require_true(catcher.count == 1 && !seq.success, "foreign project cfg was not rejected");
  test.require_true(project_cfg_binding_probe::calls == before_calls &&
    !rdma_aip_registry::target.busy, "rejected cfg started a child or left RDMA busy");
  handle = aip_cmd::get_handle("cfg_seq_reject");
  handle.status = 0;
  handle.result_out = "foreign project cfg rejected before configuration";
endtask
`aip_cmd_task(cfg_seq_reject, cfg_seq_reject)
