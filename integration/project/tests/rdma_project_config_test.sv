// 目录/层次：integration/project/tests；公共配置 sequence 的独立表/传输契约回归。
// 职责：正常 DPU resolve/publish 建立两 Host/四 RDMA VF；独立字节 fixture 验证完整 MSI-X 尾项并注入失败。
// 依赖：DPU/PCIe/project 包；不创建 RDMA driver、模型设备或真实 Intel 链路，不声称 init/grant 就绪。
// 所有权：测试拥有 cfg/snapshot/map/RC；唯一 VIO 请求仅提供真实资源 lineage，MSI-X 用例消费其真实 vector。
// 生命周期：每个案例重新解析并发布独立配置，RC存活至测试结束；无驱动启动或后台DMA。
package rdma_project_config_test_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import dpu_resource_pkg::*;
  import dpu_pcie_pkg::*;
  import pcie_tl_pkg::*;
  import rdma_project_pkg::*;
  `include "uvm_macros.svh"

  typedef struct {
    int unsigned	host;
    bit			writing;
    bit [63:0]		address;
    int unsigned	length;
    bit [127:0]		data;

  } rdma_config_access_t;

  // 只替换最底层寄存器传输，保留生产 public_records、dispatch 和高 DWORD 先写实现。
  class rdma_config_reg_fixture extends pcie_tl_reg_seq;
    `uvm_object_utils(rdma_config_reg_fixture)
    static rdma_config_access_t	accesses[$];
    static byte unsigned	memory[string];
    static int unsigned		host_by_sequencer[string];
    static bit [63:0]		af_address;
    static bit [63:0]		fail_address;
    static bit			fail_enabled;
    static bit			bad_af;
    static bit [63:0]		corrupt_address;
    static bit			corrupt_enabled;
    static int unsigned		corrupt_count;

    // 功能：创建保留公共 reg_seq 请求字段的传输 fixture。
    // 输入/输出及副作用：name 透传基类；共享访问记录由 reset_fixture 管理。
    // 失败/边界：构造不修改全局日志、不访问 DPU 配置。
    extern function new(string	name = "rdma_config_reg_fixture");

    // 功能：清理一次测试的传输观察及故障注入状态。
    // 输入/输出及副作用：清空 accesses/memory，关闭写失败、AF错误和读回扰动。
    // 失败/边界：保留已绑定 RC→Host 目录；不能在正在运行的 sequence 中调用。
    extern static function void reset_fixture();

    // 功能：记录真实寄存器请求，按 Host/地址存储写字节，读回独立重组字节。
    // 输入/输出及副作用：消费继承 addr/len/wdata/is_write；返回 status/rdata/issued_tlps，并记录每次尝试。
    // 失败/边界：未知 RC fatal；指定写地址返回 PCIE_RW_ERR且不存储，AF读可返回错误状态，指定普通读只扰动输出。
    extern virtual task body();
  endclass

  // 父类失败 fatal 是被测契约；仅在明确失败用例中计数捕获，其他诊断不隐藏。
  class rdma_config_fatal_catcher extends uvm_report_catcher;
    int unsigned	count;

    // 功能：构造本次预期失败的局部 catcher。
    // 输入/输出及副作用：name 交给基类，count 初始零。
    // 失败/边界：测试自行注册/注销，不影响其他用例。
    extern function new(string	name = "rdma_config_fatal_catcher");

    // 功能：捕获公共配置 sequence 的唯一预期 fatal并计数。
    // 输入/输出及副作用：PROJECT_CONFIG_SEQ/UVM_FATAL 匹配时增加 count 并 CAUGHT。
    // 失败/边界：所有其他 report 均 THROW；测试要求 count 精确等于一。
    extern virtual function action_e catch();
  endclass

  // 公共 DPU 对 VF 家族要求平台声明关系；这里只认可本 fixture 的完整 PF0+VF0/VF1 连接。
  // 该扩展不授予资源、不改解析结果，正向 MSI-X 用真实 VIO vector验证表机制。
  class rdma_config_fixture_cfg extends dpu_env_cfg;
    // 功能：构造只用于明确 PF/VF 接线的测试配置。
    // 输入/输出及副作用：name传给基类；不修改DUT能力或默认资源容量。
    // 失败/边界：必须仍走正常 load_params/resolve/publish，不允许直接修改冻结字段。
    extern function new(string	name = "rdma_config_fixture_cfg");

    // 功能：验证 fixture 实际 PF0和两个VF 的 SW requester/Intel/PFVF 对应关系。
    // 输入/输出及副作用：family只读；按每个冻结 Function/global ID与policy比较，返回why。
    // 失败/边界：不是完整三成员家族、身份/Host/PF/VF/requester/global-PFVF 任一不符均拒绝。
    extern virtual function bit validate_pfvf_relationship(
      input dpu_pfvf_relationship_t	family,
      output string			why
    );
  endclass

  // fixture 每次重新正常 resolve/publish，错误输入只在 authoring阶段注入，不改 frozen flags/catalog。
  class rdma_project_config_test extends uvm_test;
    `uvm_component_utils(rdma_project_config_test)
    uvm_sequencer #(pcie_tl_tlp)	rc[2];
    rdma_config_fixture_cfg		cfg;
    dpu_pcie_bar_map			map;
    dpu_function_key_t			keys[$];
    dpu_device_snapshot			snapshot;
    dpu_resource_snapshot		resources;
    bit [63:0]				management_base;
    int unsigned			completed_cases;

    // 功能：创建独立配置契约测试，初始不持有发布配置。
    // 输入/输出及副作用：name/parent 传给 UVM，句柄保持空。
    // 失败/边界：构造不分配资源、不启动配置或初始化。
    extern function new(string	name = "rdma_project_config_test", uvm_component	parent = null);

    // 功能：把独立 oracle 的假条件立即报告为测试失败。
    // 输入/输出及副作用：condition/message 输入，假条件发布 PROJECT_CONFIG_TEST fatal。
    // 失败/边界：该 id 不会被配置失败 catcher 隐藏。
    extern function void require(bit	condition, string	message);

    // 功能：创建两 Host 的空 RC sequencer并安装寄存器传输替身。
    // 输入/输出及副作用：phase 透传基类；factory override只替换 pcie_tl_reg_seq，注册 Host 映射。
    // 失败/边界：不创建驱动/EP，替身只验证配置传输，不证明真实链路可发送。
    extern function void build_phase(uvm_phase	phase);

    // 功能：正常解析两 Host/PF0+两个 RDMA VF及一个真实 VIO request，发布独立配置。
    // 输入/输出及副作用：fault 注入发布前缺项或仅尾部越界/冲突/4KB/容量错误，with_msix选择真实vector所属VF；更新cfg/map/keys。
    // 失败/边界：resolve/map/publish失败 fatal；不修改 capabilities或冻结状态、不产生任何 RDMA CEQ/SD/QP grant。
    extern function void make_fixture(string	fault = "", bit	with_msix = 0);

    // 功能：启动生产 sequence并验证返回结果与父类 fatal 保留契约。
    // 输入/输出及副作用：expect_success 控制局部 catcher；返回 seq供 oracle 检查，使用当前 cfg/keys。
    // 失败/边界：失败必须 success=0、有 error_msg 且恰好一次 fatal；成功不允许配置 fatal。
    extern task execute(bit	expect_success, output rdma_project_cfg_seq	seq);

    // 功能：验证发布前缺项/身份/传输错误在任何事务前拒绝。
    // 输入/输出及副作用：fault/with_msix 构造指定负例并运行 sequence，要求 accesses 为空。
    // 失败/边界：使用真实发布而非直接污染 frozen_controls，任何发出的 AF/MMIO 都判失败。
    extern task reject_preflight(string	fault, bit	with_msix = 0);

    // 功能：独立计算两 Host 反向 VF 地址 fixture 的 Notify literal 字段并核对 DWORD顺序和唯一使能。
    // 输入/输出及副作用：读取accesses及两Host冻结PF0租约；AF/BDF读按Host/精确行/4B核验，Notify/RNET用独立期望，不调用编码器。
    // 失败/边界：拒绝MSI-X读写、排序/ID混用、重复/缺RNET行、额外bank/旧使能、早使能或低DWORD先写；不约束RNET跨Function顺序。
    extern function void check_notify_oracle();

    // 功能：给默认2048行单 bank 的2047个未用行预填旧字节，确保漏写和保留位错误可被发现。
    // 输入/输出及副作用：使用 management_base 与独立固定偏移0xc0000，向 Host0 memory 写入0xa5，不发事务。
    // 失败/边界：只用于单消息默认布局；不改冻结记录，不调用生产尾项编码器。
    extern function void seed_msix_tail();

    // 功能：独立验证全部未用行的literal无效值、高DWORD先写、完整读回和后续类别顺序。
    // 输入/输出及副作用：verify决定应有2047次8B读回或零次；只读accesses/memory，逐字节比较0x00000007ffffffff。
    // 失败/边界：重复/漏行、旧字节/保留位错误、过早读回/Notify/使能或错误宽度均fatal；table-only MSI-X enable无MMIO可观察。
    extern function void check_msix_tail(bit	verify);

    // 功能：覆盖纯编码边界，不通过伪造 DPU能力制造不可解析的256号 Function。
    // 输入/输出及副作用：调用无分配的 encode_notify，独立常量断言255/256、Host和地址边界。
    // 失败/边界：越界失败必须 entry 清零，不能以截断返回成功；不宣称这些值对应已分配身份。
    extern function void check_encoding();

    // 功能：执行路由/完整MSI-X尾项成功、读回、仅尾部预检、缺表、身份与传输失败矩阵。
    // 输入/输出及副作用：phase objection覆盖测试；只发送配置 fixture事务，最后报告案例数。
    // 失败/边界：任何失败后不得继续后续类别；没有 driver/init入口，因此不建立虚假的初始化成功计数。
    extern task run_phase(uvm_phase	phase);
  endclass

  // 功能：创建保留公共 reg_seq 请求字段的传输 fixture。
  // 输入/输出及副作用：name 透传基类；共享访问记录由 reset_fixture 管理。
  // 失败/边界：构造不修改全局日志、不访问 DPU 配置。
  function rdma_config_reg_fixture::new(string	name = "rdma_config_reg_fixture");
    super.new(name);
  endfunction

  // 功能：清理一次测试的传输观察及故障注入状态。
  // 输入/输出及副作用：清空 accesses/memory，关闭写失败、AF错误和读回扰动。
  // 失败/边界：保留已绑定 RC→Host 目录；不能在正在运行的 sequence 中调用。
  function void rdma_config_reg_fixture::reset_fixture();
    accesses.delete();
    memory.delete();
    fail_enabled    = 0;
    bad_af          = 0;
    corrupt_enabled = 0;
    corrupt_count   = 0;
  endfunction

  // 功能：记录真实寄存器请求，按 Host/地址存储写字节，读回独立重组字节。
  // 输入/输出及副作用：消费继承 addr/len/wdata/is_write；返回 status/rdata/issued_tlps，并记录每次尝试。
  // 失败/边界：未知 RC fatal；指定写地址返回 PCIE_RW_ERR且不存储，AF读可返回错误状态，指定普通读只扰动输出。
  task rdma_config_reg_fixture::body();
    rdma_config_access_t	access;
    pcie_tl_mem_tlp		issued;
    string			name;

    if (mask != 0 || !(len inside {4, 8, 16}) || addr[1:0] != 0)
      `uvm_fatal("CONFIG_FIXTURE", "unexpected mask/length/alignment in public configuration request")
    name = m_sequencer.get_full_name();
    if (!host_by_sequencer.exists(name))
      `uvm_fatal("CONFIG_FIXTURE", "request used an unregistered RC")
    access.host    = host_by_sequencer[name];
    access.writing = is_write;
    access.address = addr;
    access.length  = len;
    access.data    = wdata;
    accesses.push_back(access);
    status    = PCIE_RW_OK;
    error_msg = "";
    rdata     = '0;
    issued_tlps.delete();
    if (is_write && fail_enabled && addr == fail_address) begin
      status    = PCIE_RW_ERR;
      error_msg = "injected register write failure";
      return;
    end
    if (!is_write && access.host == 0 && addr == af_address) begin
      rdata = bad_af ? 0 : 8;
      return;
    end
    for (int unsigned	i = 0; i < len; i++) begin
      string	location;

      location = $sformatf("%0d:%016h", access.host, addr + i);
      if (is_write)
        memory[location] = wdata[8 * i +: 8];
      else if (memory.exists(location))
        rdata[8 * i +: 8] = memory[location];
    end
    if (is_write) begin
      issued = new("observed_write");
      issued_tlps.push_back(issued);
    end else if (corrupt_enabled && addr == corrupt_address) begin
      rdata[0] = ~rdata[0];
      corrupt_count++;
    end
  endtask

  // 功能：构造本次预期失败的局部 catcher。
  // 输入/输出及副作用：name 交给基类，count 初始零。
  // 失败/边界：测试自行注册/注销，不影响其他用例。
  function rdma_config_fatal_catcher::new(string	name = "rdma_config_fatal_catcher");
    super.new(name);
  endfunction

  // 功能：捕获公共配置 sequence 的唯一预期 fatal并计数。
  // 输入/输出及副作用：PROJECT_CONFIG_SEQ/UVM_FATAL 匹配时增加 count 并 CAUGHT。
  // 失败/边界：所有其他 report 均 THROW；测试要求 count 精确等于一。
  function uvm_report_catcher::action_e rdma_config_fatal_catcher::catch();
    if (get_id() == "PROJECT_CONFIG_SEQ" && get_severity() == UVM_FATAL) begin
      count++;
      return CAUGHT;
    end
    return THROW;
  endfunction

  // 功能：构造只用于明确 PF/VF 接线的测试配置。
  // 输入/输出及副作用：name传给基类；不修改DUT能力或默认资源容量。
  // 失败/边界：必须仍走正常 load_params/resolve/publish，不允许直接修改冻结字段。
  function rdma_config_fixture_cfg::new(string	name = "rdma_config_fixture_cfg");
    super.new(name);
  endfunction

  // 功能：验证 fixture 实际 PF0和两个VF 的 SW requester/Intel/PFVF 对应关系。
  // 输入/输出及副作用：family只读；按每个冻结 Function/global ID与policy比较，返回why。
  // 失败/边界：不是完整三成员家族、身份/Host/PF/VF/requester/global-PFVF 任一不符均拒绝。
  function bit rdma_config_fixture_cfg::validate_pfvf_relationship(
    input dpu_pfvf_relationship_t	family,
    output string			why
  );
    bit	seen[int unsigned];

    why = "fixture PF/VF relationship does not match resolved SW topology";
    if (family.functions.size() != 3 || family.policies.size() != 3)
      return 0;
    foreach (family.functions[f]) begin
      int unsigned	slot;

      slot = family.functions[f].key.kind == DPU_FUNCTION_PF ? 0 : family.functions[f].key.vf_id + 1;
      if (slot > 2 || seen.exists(slot) || family.functions[f].key.pf_id != 0 ||
          !dpu_same_function_key(family.functions[f].key, family.policies[f].key) ||
          family.policies[f].mode != DPU_HOST_SW ||
          family.policies[f].requester != family.functions[f].pcie_id.bdf ||
          family.policies[f].pfvf != family.functions[f].global_function_id ||
          family.policies[f].intel_pf != 0 ||
          family.policies[f].intel_vf != (slot == 0 ? -1 : int'(slot - 1)))
        return 0;
      seen[slot] = 1;
    end
    why = "";
    return 1;
  endfunction

  // 功能：创建独立配置契约测试，初始不持有发布配置。
  // 输入/输出及副作用：name/parent 传给 UVM，句柄保持空。
  // 失败/边界：构造不分配资源、不启动配置或初始化。
  function rdma_project_config_test::new(string	name = "rdma_project_config_test", uvm_component	parent = null);
    super.new(name, parent);
  endfunction

  // 功能：把独立 oracle 的假条件立即报告为测试失败。
  // 输入/输出及副作用：condition/message 输入，假条件发布 PROJECT_CONFIG_TEST fatal。
  // 失败/边界：该 id 不会被配置失败 catcher 隐藏。
  function void rdma_project_config_test::require(bit	condition, string	message);
    if (!condition)
      `uvm_fatal("PROJECT_CONFIG_TEST", message)
  endfunction

  // 功能：创建两 Host 的空 RC sequencer并安装寄存器传输替身。
  // 输入/输出及副作用：phase 透传基类；factory override只替换 pcie_tl_reg_seq，注册 Host 映射。
  // 失败/边界：不创建驱动/EP，替身只验证配置传输，不证明真实链路可发送。
  function void rdma_project_config_test::build_phase(uvm_phase	phase);
    super.build_phase(phase);
    foreach (rc[h]) begin
      rc[h] = new($sformatf("rc%0d", h), this);
      rdma_config_reg_fixture::host_by_sequencer[rc[h].get_full_name()] = h;
    end
    pcie_tl_reg_seq::type_id::set_type_override(rdma_config_reg_fixture::get_type());
  endfunction

  // 功能：正常解析两 Host/PF0+两个 RDMA VF及一个真实 VIO request，发布独立配置。
  // 输入/输出及副作用：fault 注入发布前缺项或仅尾部越界/冲突/4KB/容量错误，with_msix选择真实vector所属VF；更新cfg/map/keys。
  // 失败/边界：resolve/map/publish失败 fatal；不修改 capabilities或冻结状态、不产生任何 RDMA CEQ/SD/QP grant。
  function void rdma_project_config_test::make_fixture(string	fault = "", bit	with_msix = 0);
    dpu_configuration_resolver	resolver;
    dpu_placement_diagnostic	diagnostic;
    dpu_vio_placement_request	request;
    dpu_vio_qpair_binding_t	pairs[$];
    dpu_function_key_t		all_keys[$];
    dpu_control_cfg_t		controls[$];
    dpu_table_layout_t		layout;
    dpu_bar_target_t		target;
    string			why;

    rdma_config_reg_fixture::reset_fixture();
    cfg            = new("fixture_cfg");
    cfg.hosts      = 2;
    cfg.vfs_per_pf = 2;
    cfg.load_params();
    keys.delete();
    foreach (cfg.device_cfg.functions[f]) begin
      dpu_service_decl	service;
      dpu_function_cfg	function_cfg;

      function_cfg = cfg.device_cfg.functions[f];
      if (function_cfg.key.kind != DPU_FUNCTION_VF)
        continue;
      service              = new("rdma_service");
      service.service_kind = DPU_SERVICE_RDMA;
      if (!(fault == "missing_service" && f == 1)) begin
        function_cfg.services.push_back(service);
        keys.push_front(function_cfg.key);
      end
      foreach (function_cfg.bars[b]) begin
        if (function_cfg.bars[b].role == DPU_BAR_DEVICE_MEMORY) begin
          function_cfg.bars[b].placement = DPU_ALLOC_PINNED;
          function_cfg.bars[b].pinned_base = cfg.device_cfg.hosts[function_cfg.key.host_id].pcie_domains[0].mmio_windows[0].base +
            64'h4000000 + (1 - function_cfg.key.vf_id) * 64'h10000;
        end
      end
    end
    request                = new("lineage_only_vio_request");
    request.request_id     = 0;
    request.total_qpairs   = 1;
    request.device_policy  = DPU_VIO_DEVICE_FIXED;
    request.candidate_kind = with_msix ? DPU_VIO_CANDIDATE_VF_ONLY : DPU_VIO_CANDIDATE_PF_ONLY;
    request.fixed_devices.push_back(cfg.device_cfg.functions[with_msix ? 1 : 0].key);
    cfg.placement_cfg.vio_requests.push_back(request);
    resolver = new("resolver");
    if (!resolver.resolve(cfg.device_cfg, cfg.placement_cfg, snapshot, resources, diagnostic))
      `uvm_fatal("PROJECT_CONFIG_TEST", diagnostic.message)
    map = new("fixture_map");
    require(map.initialize(snapshot, 1, why), why);
    for (int unsigned	h = 0; h < 2; h++) begin
      require(map.bind_host(h, h, why), why);
      map.rc_sequencers[h] = rc[h];
    end
    snapshot.list_functions(all_keys);
    foreach (all_keys[f]) begin
      dpu_pcie_function_id_t	pcie_id;
      dpu_function_policy_t	policy;
      int unsigned		global_id;

      require(snapshot.get_pcie_id(all_keys[f], pcie_id, why), why);
      require(snapshot.get_global_function_id(all_keys[f], global_id, why), why);
      require(map.bind_function(all_keys[f], all_keys[f].pf_id,
        all_keys[f].kind == DPU_FUNCTION_VF ? int'(all_keys[f].vf_id) : -1, pcie_id.bdf, why), why);
      policy           = '{default: 0};
      policy.key       = all_keys[f];
      policy.mode      = DPU_HOST_SW;
      policy.requester = pcie_id.bdf;
      policy.bdf_index = global_id;
      policy.vport     = global_id;
      policy.pfvf      = global_id;
      policy.intel_pf  = all_keys[f].pf_id;
      policy.intel_vf  = all_keys[f].kind == DPU_FUNCTION_VF ? int'(all_keys[f].vf_id) : -1;
      cfg.function_policies[dpu_function_key_name(all_keys[f])] = policy;
    end
    require(map.freeze(why), why);
    require(map.resolve_name("h0.pf0.bar0", target, why), why);
    management_base                     = target.bar_lease.base;
    rdma_config_reg_fixture::af_address = management_base + 'h1010;
    require(rdma_project_cfg_seq::make_catalog(snapshot, map, keys, controls, why), why);
    cfg.platform_controls                    = controls;
    layout                                   = '{default: 0};
    layout.provided                          = 1;
    layout.reg_target                        = "h0.pf0.bar0";
    layout.table_offset                      = 'hc000;
    layout.entry_bytes                       = 8;
    layout.capacity                          = 256;
    layout.index_policy                      = DPU_INDEX_EXPLICIT;
    cfg.table_layouts[DPU_TABLE_RDMA_NOTIFY] = layout;
    layout.reg_target                        = "pf0.bar0";
    layout.access_uses_owner_host            = 1;
    layout.module_offset                     = 'hb00000;
    layout.table_offset                      = 'h15000;
    layout.entry_bytes                       = 4;
    cfg.table_layouts[DPU_TABLE_RNET]        = layout;
    if (with_msix) begin
      dpu_msix_message_t	message;
      dpu_msix_policy_t		policy;

      resources.list_vio_bindings(pairs);
      require(pairs.size() == 1, "MSI-X fixture needs one genuine resolved VIO binding");
      message               = '{default: 0};
      message.owner         = pairs[0].service_key.function_key;
      message.local_vector  = pairs[0].local_msix_vector_id;
      message.global_vector = pairs[0].global_msix_vector_id;
      message.address       = 64'hfee00000;
      message.data          = 'h40;
      cfg.messages.push_back(message);
      policy                   = '{default: 0};
      policy.self_mask_present = 1;
      policy.interval_present  = 1;
      policy.table_only_enable = 1;
      cfg.msix_policies[dpu_function_key_name(message.owner)] = policy;
      if (fault == "missing_msix_policy")
        cfg.msix_policies.delete(dpu_function_key_name(message.owner));
      if (fault == "missing_msix_layout")
        cfg.table_layouts.delete(DPU_TABLE_MSIX_INFO);
      if (fault == "unsupported_control" || fault == "unsupported_function") begin
        dpu_control_cfg_t	control_item;
        dpu_table_kind_e	kind;

        kind                         = fault == "unsupported_control" ? DPU_TABLE_MSIX_CONTROL : DPU_TABLE_MSIX_FUNCTION;
        control_item                 = controls[0];
        control_item.owner           = message.owner;
        control_item.ctx.kind        = kind;
        control_item.ctx.table_index = 0;
        control_item.value           = 1;
        control_item.writable_mask   = 1;
        cfg.platform_controls.push_back(control_item);
        layout                  = '{default: 0};
        layout.provided         = 1;
        layout.reg_target       = "h0.pf0.bar0";
        layout.table_offset     = 'h90000;
        layout.entry_bytes      = 4;
        layout.capacity         = 1;
        cfg.table_layouts[kind] = layout;
      end
    end
    if (fault == "missing_notify")
      cfg.platform_controls.delete(0);
    if (fault == "missing_rnet")
      cfg.platform_controls.delete(controls.size() - 1);
    if (fault == "wrong_row")
      cfg.platform_controls[0].ctx.table_index = 7;
    if (fault == "wrong_id")
      cfg.platform_controls[0].value[58:51] = 8'hfe;
    if (fault == "wrong_rnet_id")
      cfg.platform_controls[controls.size() - 1].ctx.table_index = 17;
    if (fault == "missing_bdf")
      cfg.function_policies.delete(dpu_function_key_name(all_keys[1]));
    if (fault == "missing_notify_layout")
      cfg.table_layouts.delete(DPU_TABLE_RDMA_NOTIFY);
    if (fault == "unaligned_notify")
      cfg.table_layouts[DPU_TABLE_RDMA_NOTIFY].module_offset = 1;
    if (fault == "notify_bdf_overlap")
      cfg.table_layouts[DPU_TABLE_RDMA_NOTIFY].module_offset = 'hfc000;
    if (fault == "notify_bdf_partial_overlap") begin
      // BDF行0为[0x108100:0x108103]；Notify行0为[0x1080fc:0x108103]。
      // 两者均在同一4KB页且起点不同，只能由完整跨度重叠检查拒绝。
      cfg.table_layouts[DPU_TABLE_BDF].module_offset         = 'h100100;
      cfg.table_layouts[DPU_TABLE_RDMA_NOTIFY].module_offset = 'hfc0fc;
    end
    if (fault == "notify_enable_overlap")
      cfg.table_layouts[DPU_TABLE_RDMA_NOTIFY].module_offset = 'h74040;
    if (fault == "msix_bdf_overlap")
      cfg.table_layouts[DPU_TABLE_MSIX_TABLE].module_offset =
        'he8000 - cfg.messages[0].global_vector * 16;
    // 有效行0仍合法；错误仅出现在父类会写/读的未用尾部，必须在AF之前拒绝。
    if (fault == "msix_tail_overrun")
      cfg.table_layouts[DPU_TABLE_MSIX_LINEAR].module_offset = target.bar_lease.size - 'h40000 - 8;
    if (fault == "msix_tail_bdf_overlap")
      cfg.table_layouts[DPU_TABLE_MSIX_LINEAR].module_offset = 'hc7ff8;
    if (fault == "msix_tail_notify_overlap")
      cfg.table_layouts[DPU_TABLE_RDMA_NOTIFY].module_offset = 'hb4008;
    if (fault == "msix_tail_enable_overlap")
      cfg.table_layouts[DPU_TABLE_MSIX_LINEAR].module_offset = 'h40038;
    if (fault == "msix_tail_4kb")
      cfg.table_layouts[DPU_TABLE_MSIX_LINEAR].module_offset = 'h80004;
    if (fault == "msix_tail_capacity")
      cfg.table_layouts[DPU_TABLE_MSIX_LINEAR].capacity = 2049;
    if (fault == "split_notify_window") begin
      cfg.table_layouts[DPU_TABLE_RDMA_NOTIFY].reg_target             = "pf0.bar0";
      cfg.table_layouts[DPU_TABLE_RDMA_NOTIFY].access_uses_owner_host = 1;
    end
    if (fault == "missing_rc")
      map.rc_sequencers.delete(1);
    require(cfg.publish(snapshot, resources, map, why), why);
    if (fault == "missing_service")
      keys.push_back(all_keys[1]);
    if (fault == "subset")
      keys.delete(keys.size() - 1);
    if (fault == "duplicate_key")
      keys.push_back(keys[0]);
    if (fault == "pf_owner")
      keys[0] = all_keys[0];
    if (fault == "empty_keys")
      keys.delete();
  endfunction

  // 功能：启动生产 sequence并验证返回结果与父类 fatal 保留契约。
  // 输入/输出及副作用：expect_success 控制局部 catcher；返回 seq供 oracle 检查，使用当前 cfg/keys。
  // 失败/边界：失败必须 success=0、有 error_msg 且恰好一次 fatal；成功不允许配置 fatal。
  task rdma_project_config_test::execute(bit	expect_success, output rdma_project_cfg_seq	seq);
    rdma_config_fatal_catcher	catcher;

    seq                = new("configuration_under_test");
    seq.rdma_functions = keys;
    uvm_config_db#(dpu_env_cfg)::set(rc[0], "", "dpu_cfg", cfg);
    catcher = new();
    if (!expect_success)
      uvm_report_cb::add(null, catcher);
    seq.start(rc[0]);
    if (!expect_success)
      uvm_report_cb::delete(null, catcher);
    require(seq.success == expect_success, {"configuration result: ", seq.error_msg});
    require(catcher.count == (expect_success ? 0 : 1), "public post_start fatal contract changed");
    require(expect_success || seq.error_msg != "", "failure lost diagnostic");
    completed_cases++;
  endtask

  // 功能：验证发布前缺项/身份/传输错误在任何事务前拒绝。
  // 输入/输出及副作用：fault/with_msix 构造指定负例并运行 sequence，要求 accesses 为空。
  // 失败/边界：使用真实发布而非直接污染 frozen_controls，任何发出的 AF/MMIO 都判失败。
  task rdma_project_config_test::reject_preflight(string	fault, bit	with_msix = 0);
    rdma_project_cfg_seq	seq;

    make_fixture(fault, with_msix);
    execute(0, seq);
    require(rdma_config_reg_fixture::accesses.size() == 0, {fault, " issued transactions before rejecting"});
  endtask

  // 功能：独立计算两 Host 反向 VF 地址 fixture 的 Notify literal 字段并核对 DWORD顺序和唯一使能。
  // 输入/输出及副作用：读取accesses及两Host冻结PF0租约；AF/BDF读按Host/精确行/4B核验，Notify/RNET用独立期望，不调用编码器。
  // 失败/边界：拒绝MSI-X读写、排序/ID混用、重复/缺RNET行、额外bank/旧使能、早使能或低DWORD先写；不约束RNET跨Function顺序。
  function void rdma_project_config_test::check_notify_oracle();
    int unsigned	notify_writes;
    int unsigned	enables;
    int unsigned	rnet_writes;
    bit		seen_rnet[int unsigned];
    bit [63:0]	rnet_addresses[int unsigned];
    int unsigned	rnet_hosts[int unsigned];
    bit [63:0]	bdf_addresses[6];
    int unsigned	bdf_hosts[6];
    bit [63:0]	bdf_offsets[6] = '{'h108000, 'h108004, 'h108008, 'h10800c, 'h108010, 'h108014};
    string		why;

    for (int unsigned	host = 0; host < 2; host++) begin
      dpu_bar_target_t	management;

      require(map.resolve_name($sformatf("h%0d.pf0.bar0", host), management, why), why);
      // fixture每Host为PF0/VF0/VF1，bdf_index分别为全局0..2/3..5。
      // 明列六个合法DWORD行；BAR基址只取冻结租约，不把整页或Host地址步长当作白名单。
      for (int unsigned	slot = 0; slot < 3; slot++) begin
        int unsigned	global_id;

        global_id                = host * 3 + slot;
        bdf_addresses[global_id] = management.bar_lease.base + bdf_offsets[global_id];
        bdf_hosts[global_id]     = host;
      end
      for (int unsigned	vf = 0; vf < 2; vf++) begin
        int unsigned	global_id;

        global_id = host * 3 + 1 + vf;
        rnet_addresses[global_id] = management.bar_lease.base + 'hb15000 + global_id * 4;
        rnet_hosts[global_id] = host;
      end
    end
    notify_writes = 0;
    enables       = 0;
    rnet_writes   = 0;
    foreach (rdma_config_reg_fixture::accesses[a]) begin
      rdma_config_access_t	access;

      access = rdma_config_reg_fixture::accesses[a];
      if (!access.writing) begin
        bit	allowed_read;

        allowed_read = access.host == 0 && access.address == management_base + 'h1010;
        foreach (bdf_addresses[id]) begin
          if (cfg.verify_readback && access.host == bdf_hosts[id] && access.address == bdf_addresses[id])
            allowed_read = 1;
        end
        require(allowed_read && access.length == 4,
          $sformatf("routing-only unexpected read (including MSI-X): Host%0d address=%h length=%0d",
            access.host, access.address, access.length));
        continue;
      end
      if (access.address >= management_base + 'hc000 && access.address < management_base + 'hc020) begin
        int unsigned	row;
        int unsigned	host;
        int unsigned	vf;
        int unsigned	global_id;
        bit [63:0]	notify_address;
        bit [63:0]	expected;

        row            = notify_writes / 2;
        host           = row / 2;
        vf             = 1 - row % 2;
        global_id      = host * 3 + 1 + vf;
        notify_address = 64'h20_0400_2000 + host * 64'h10_0000_0000 + (1 - vf) * 64'h10000;
        expected       = (64'(global_id) << 51) | (64'(host) << 48) | (notify_address >> 13);
        require(access.host == 0 && access.length == 4, "Notify must target management Host0 in DWORDs");
        require(access.address == management_base + 'hc000 + row * 8 + (notify_writes % 2 == 0 ? 4 : 0),
          "Notify sorted row or high-first DWORD address mismatch");
        require(access.data == (notify_writes % 2 == 0 ? 128'(expected[63:32]) : 128'(expected[31:0])),
          "Notify literal fields disagree with Host/address/global ID oracle");
        notify_writes++;
      end else if (access.address == management_base + 'h80044) begin
        require(notify_writes == 8 && access.data == 1 && access.length == 4, "Notify enable is early or malformed");
        enables++;
      end else if (access.address[23:16] == 8'hb1) begin
        int unsigned	match_count;

        match_count = 0;
        foreach (rnet_addresses[id]) begin
          if (access.host != rnet_hosts[id] || access.address != rnet_addresses[id])
            continue;
          require(!seen_rnet.exists(id), "duplicate RNET global Function row");
          require(access.length == 4 && access.data == (rnet_hosts[id] == 0 ? 1 : 3),
            "RNET Host/enable fields or DWORD width mismatch");
          seen_rnet[id] = 1;
          match_count++;
        end
        require(match_count == 1,
          $sformatf("RNET global-ID row mismatch: Host%0d address=%h data=%h",
            access.host, access.address, access.data));
        require(enables == 1, "RNET written before Notify enable");
        rnet_writes++;
      end else begin
        require(access.address == management_base + 'h1010 || access.address[23:12] == 12'h108,
          "unexpected register write (old enable/bank or unrequested category)");
      end
    end
    require(notify_writes == 8 && enables == 1 && rnet_writes == 4 && seen_rnet.num() == 4,
      "incomplete Notify/RNET write set");
  endfunction

  // 功能：给默认2048行单 bank 的2047个未用行预填旧字节，确保漏写和保留位错误可被发现。
  // 输入/输出及副作用：使用 management_base 与独立固定偏移0xc0000，向 Host0 memory 写入0xa5，不发事务。
  // 失败/边界：只用于单消息默认布局；不改冻结记录，不调用生产尾项编码器。
  function void rdma_project_config_test::seed_msix_tail();
    for (int unsigned	row = 1; row < 2048; row++) begin
      for (int unsigned	b = 0; b < 8; b++)
        rdma_config_reg_fixture::memory[$sformatf("0:%016h", management_base + 'hc0000 + row * 8 + b)] = 'ha5;
    end
  endfunction

  // 功能：独立验证全部未用行的literal无效值、高DWORD先写、完整读回和后续类别顺序。
  // 输入/输出及副作用：verify决定应有2047次8B读回或零次；只读accesses/memory，逐字节比较0x00000007ffffffff。
  // 失败/边界：重复/漏行、旧字节/保留位错误、过早读回/Notify/使能或错误宽度均fatal；table-only MSI-X enable无MMIO可观察。
  function void rdma_project_config_test::check_msix_tail(bit	verify);
    int unsigned	writes;
    int unsigned	reads;
    int unsigned	enables;
    bit [63:0]	invalid_literal;

    writes          = 0;
    reads           = 0;
    enables         = 0;
    invalid_literal = 64'h0000_0007_ffff_ffff;
    foreach (rdma_config_reg_fixture::accesses[a]) begin
      rdma_config_access_t	access;

      access = rdma_config_reg_fixture::accesses[a];
      if (access.address >= management_base + 'hc0008 && access.address < management_base + 'hc4000) begin
        require(access.host == 0, "MSI-X tail accessed wrong Host");
        if (access.writing) begin
          require(reads == 0 && enables == 0 && access.length == 4,
            "MSI-X tail write occurred after readback/enable or used wrong width");
          require(access.address == management_base + 'hc0008 + (writes / 2) * 8 + (writes % 2 == 0 ? 4 : 0),
            "MSI-X tail missing/duplicate row or not high-DWORD first");
          require(access.data == (writes % 2 == 0 ? 128'h7 : 128'hffff_ffff),
            "MSI-X tail literal invalid fields/reserved bits mismatch");
          writes++;
        end else begin
          require(verify && writes == 4094 && enables == 0 && access.length == 8,
            "MSI-X tail readback preceded complete initialization or followed enable");
          require(access.address == management_base + 'hc0008 + reads * 8,
            "MSI-X tail readback missed/duplicated a row");
          reads++;
        end
      end
      // table_only_enable不产生MSI-X Function事务；可观察的使能是Notify enable。
      // 同时检查第一笔Notify及RNET，防止尾项虽最终补写却已让后续类别先运行。
      if (access.writing && ((access.address >= management_base + 'hc000 &&
          access.address < management_base + 'hc020) || access.address == management_base + 'h80044 ||
          access.address[23:16] == 8'hb1)) begin
        require(writes == 4094 && reads == (verify ? 2047 : 0),
          "later configuration category started before complete MSI-X tail processing");
        if (access.address == management_base + 'h80044)
          enables++;
      end
    end
    require(writes == 4094 && reads == (verify ? 2047 : 0) && enables == 1,
      "MSI-X tail or Notify enable access set is incomplete");
    for (int unsigned	row = 1; row < 2048; row++) begin
      for (int unsigned	b = 0; b < 8; b++) begin
        string	location;

        location = $sformatf("0:%016h", management_base + 'hc0000 + row * 8 + b);
        require(rdma_config_reg_fixture::memory.exists(location) &&
          rdma_config_reg_fixture::memory[location] == invalid_literal[b * 8 +: 8],
          "MSI-X tail retained seeded bytes or invalid reserved bits");
      end
    end
  endfunction

  // 功能：覆盖纯编码边界，不通过伪造 DPU能力制造不可解析的256号 Function。
  // 输入/输出及副作用：调用无分配的 encode_notify，独立常量断言255/256、Host和地址边界。
  // 失败/边界：越界失败必须 entry 清零，不能以截断返回成功；不宣称这些值对应已分配身份。
  function void rdma_project_config_test::check_encoding();
    dpu_rdma_notify_entry_t	entry;
    string			why;

    require(rdma_project_cfg_seq::encode_notify(255, 7, 64'h2000, entry, why), why);
    require(entry == 64'h07ff_0000_0000_0001, "ID255/Host7 encoding mismatch");
    require(!rdma_project_cfg_seq::encode_notify(256, 7, 64'h2000, entry, why) && entry == 0, "ID256 truncated");
    require(!rdma_project_cfg_seq::encode_notify(1, 8, 64'h2000, entry, why), "Host8 truncated");
    require(!rdma_project_cfg_seq::encode_notify(1, 0, 64'h2000_0000_0000_0000, entry, why), "address high bits truncated");
    require(!rdma_project_cfg_seq::encode_notify(1, 0, 64'h2001, entry, why), "unaligned Notify accepted");
    require(!rdma_project_cfg_seq::encode_notify(1, 0, 64'hxxxx, entry, why), "unknown Notify address accepted");
  endfunction

  // 功能：执行路由/完整MSI-X尾项成功、读回、仅尾部预检、缺表、身份与传输失败矩阵。
  // 输入/输出及副作用：phase objection覆盖测试；只发送配置 fixture事务，最后报告案例数。
  // 失败/边界：任何失败后不得继续后续类别；没有 driver/init入口，因此不建立虚假的初始化成功计数。
  task rdma_project_config_test::run_phase(uvm_phase	phase);
    rdma_project_cfg_seq	seq;
    string			faults[$] = '{"missing_notify", "missing_rnet", "wrong_row", "wrong_id", "wrong_rnet_id",
      "missing_bdf", "missing_notify_layout", "missing_rc", "split_notify_window", "missing_service",
      "subset", "duplicate_key", "pf_owner", "empty_keys", "unaligned_notify",
      "notify_bdf_overlap", "notify_bdf_partial_overlap", "notify_enable_overlap"};
    string	msix_faults[$] = '{"missing_msix_policy", "missing_msix_layout", "unsupported_control",
      "unsupported_function", "msix_bdf_overlap", "msix_tail_overrun", "msix_tail_bdf_overlap",
      "msix_tail_notify_overlap", "msix_tail_enable_overlap", "msix_tail_4kb", "msix_tail_capacity"};

    phase.raise_objection(this);
    check_encoding();
    make_fixture();
    execute(1, seq);
    require(seq.configured_tables == "BDF,RDMA_NOTIFY,RNET", "routing-only category report mismatch");
    check_notify_oracle();
    make_fixture();
    cfg.verify_readback = 1;
    execute(1, seq);
    check_notify_oracle();
    foreach (faults[i])
      reject_preflight(faults[i]);
    foreach (msix_faults[i])
      reject_preflight(msix_faults[i], 1);
    // 两种verify策略都必须覆盖完整2047尾行，不能依靠复位零值或生产编码器构造期望。
    for (int	i = 0; i < 2; i++) begin
      make_fixture("", 1);
      seed_msix_tail();
      cfg.verify_readback = i == 1;
      execute(1, seq);
      require(seq.configured_tables ==
        "BDF,MSIX_LINEAR,MSIX_INFO,MSIX_INTERVAL,MSIX_TABLE(table_only_enable),RDMA_NOTIFY,RNET",
        "real MSI-X messages were silently skipped");
      check_msix_tail(i == 1);
    end

    // 首行与末行的两个DWORD都注入写失败；失败访问必须是最后一次尝试。
    for (int	i = 0; i < 4; i++) begin
      make_fixture("", 1);
      seed_msix_tail();
      cfg.verify_readback                   = 1;
      rdma_config_reg_fixture::fail_enabled = 1;
      rdma_config_reg_fixture::fail_address = management_base + 'hc0000 +
        (i < 2 ? 8 : 2047 * 8) + (i % 2 == 0 ? 4 : 0);
      execute(0, seq);
      require(seq.configured_tables == "BDF", "tail write failure published MSI-X completion");
      require(rdma_config_reg_fixture::accesses[$].writing &&
        rdma_config_reg_fixture::accesses[$].address == rdma_config_reg_fixture::fail_address,
        "tail write failure did not immediately stop configuration");
      foreach (rdma_config_reg_fixture::accesses[a])
        require(rdma_config_reg_fixture::accesses[a].address != management_base + 'hc004 &&
          rdma_config_reg_fixture::accesses[a].address != management_base + 'h80044 &&
          rdma_config_reg_fixture::accesses[a].address[23:16] != 8'hb1,
          "tail write failure reached Notify/enable/RNET");
    end
    // 首尾行读回扰动仅改响应；要求真实父类读回检测到一次错误并停止后续类别。
    for (int	i = 0; i < 2; i++) begin
      make_fixture("", 1);
      seed_msix_tail();
      cfg.verify_readback                     = 1;
      rdma_config_reg_fixture::corrupt_enabled = 1;
      rdma_config_reg_fixture::corrupt_address = management_base + 'hc0000 + (i == 0 ? 8 : 2047 * 8);
      execute(0, seq);
      require(rdma_config_reg_fixture::corrupt_count == 1, "tail readback corruption was not consumed");
      require(!rdma_config_reg_fixture::accesses[$].writing &&
        rdma_config_reg_fixture::accesses[$].address == rdma_config_reg_fixture::corrupt_address,
        "tail readback mismatch did not immediately stop configuration");
      foreach (rdma_config_reg_fixture::accesses[a])
        require(rdma_config_reg_fixture::accesses[a].address != management_base + 'hc004 &&
          rdma_config_reg_fixture::accesses[a].address != management_base + 'h80044 &&
          rdma_config_reg_fixture::accesses[a].address[23:16] != 8'hb1,
          "tail readback failure reached Notify/enable/RNET");
    end

    // 独立字节存储使 BDF/MSI-X 读回确实来自先前写入；故障只改读响应，不改 cfg预期。
    for (int	i = 0; i < 2; i++) begin
      make_fixture("", i == 1);
      cfg.verify_readback                     = 1;
      rdma_config_reg_fixture::corrupt_enabled = 1;
      rdma_config_reg_fixture::corrupt_address = management_base + (i == 0 ? 'h108000 : 'h150000);
      // MSI-X INFO 使用 resolver 的实际 global vector，不能假定其为零。
      if (i == 1)
        rdma_config_reg_fixture::corrupt_address += cfg.frozen_messages[0].global_vector * 4;
      execute(0, seq);
      require(rdma_config_reg_fixture::corrupt_count == 1, "readback mismatch injection was not observed");
      foreach (rdma_config_reg_fixture::accesses[a])
        require(rdma_config_reg_fixture::accesses[a].address != management_base + 'hc004,
          "readback failure continued into Notify");
    end
    // 逐个实际下发地址注入失败：AF、Notify高/低DWORD及使能；失败后不能出现任何后续事务。
    for (int	i = 0; i < 4; i++) begin
      make_fixture();
      rdma_config_reg_fixture::fail_enabled = 1;
      case (i)
        0: rdma_config_reg_fixture::fail_address = management_base + 'h1010;
        1: rdma_config_reg_fixture::fail_address = management_base + 'hc004;
        2: rdma_config_reg_fixture::fail_address = management_base + 'hc000;
        3: rdma_config_reg_fixture::fail_address = management_base + 'h80044;
        // 循环只产生0..3；未来扩展若漏定义故障地址，必须在execute前失败而非复用旧地址。
        default: `uvm_fatal("PROJECT_CONFIG_TEST", "unexpected fault-address case index")
      endcase
      execute(0, seq);
      require(rdma_config_reg_fixture::accesses[$].address == rdma_config_reg_fixture::fail_address,
        "failed write did not terminate configuration immediately");
    end
    make_fixture();
    rdma_config_reg_fixture::bad_af = 1;
    execute(0, seq);
    require(rdma_config_reg_fixture::accesses.size() == 2, "invalid AF status allowed later writes");
    `uvm_info("PROJECT_CONFIG_PASS", $sformatf("%0d configuration cases; table/transport only, no RDMA init authorization", completed_cases), UVM_LOW)
    phase.drop_objection(this);
  endtask
endpackage
