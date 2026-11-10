// 目录/层次：integration/project/tests；Intel BAR/DMA 同源映射的独立传输回归。
// 职责：两个真实 wrapper 端口使用同 BDF/requester，逐 Host 验证 literal wire bytes、DMA backing 与隔离。
// 依赖：项目 transport、DPU resolver、真实 Host manager；APPLICATION adapter 只注入/捕获包，无 EP responder。
// 所有权/生命周期：测试拥有 env、map、快照、pool 和视图；pool 拥有各 Host manager，RC/BAR 借用，撤销或复位后释放分配。
package rdma_project_transport_test_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import dpu_resource_pkg::*;
  import dpu_pcie_pkg::*;
  import host_mem_pkg::*;
  import pcie_tl_pkg::*;
  import intel_pcie_adapter_pkg::*;
  import rdma_types_pkg::*;
  import rdma_host_mem_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_project_transport_pkg::*;
  `include "uvm_macros.svh"

  // 在真正 manager 的虚接口记录访问次数，证明拒绝发生在 backing 前而非仅保证最终数据不变。
  class rdma_transport_counting_mem extends host_mem_manager;
    `uvm_object_utils(rdma_transport_counting_mem)
    int unsigned	reads;
    int unsigned	writes;

    // 功能：创建真实 backing 的计数 manager。
    // 输入/输出及副作用：name 交给 manager，read/write 计数默认清零。
    // 失败/边界：区域由 build 显式初始化，构造不分配 Function 数据。
    extern function new(string	name = "rdma_transport_counting_mem");

    // 功能：统计底层 backing 写次数并执行真实 manager 写。
    // 输入/输出及副作用：addr/data/file/line 原样传给 super，writes 每次调用加一。
    // 失败/边界：即使非法访问也先计数，使测试不能掩盖拒绝前的副作用。
    extern virtual function void write_mem(bit [63:0]	addr, byte	data[], string	file = "", int	line = 0);

    // 功能：统计底层 backing 读取次数并返回真实字节。
    // 输入/输出及副作用：addr/size/file/line 原样传给 super，data 为输出，reads 每次调用加一。
    // 失败/边界：计数覆盖所有底层调用，空/错误访问同样可被拒绝测试观察。
    extern virtual function void read_mem(bit [63:0]	addr, int unsigned	size, ref byte	data[],
        input string	file = "", input int	line = 0);

  endclass

  // 真复位中止首个 Completion 是预期外部诊断；只吞这一项且断言次数，其他错误继续失败。
  class rdma_transport_reset_catcher extends uvm_report_catcher;
    int unsigned	count;
    // 功能：建立只用于 reset_abort 的报告捕获器。
    // 输入/输出及副作用：name 透传基类，count 初始零。
    // 失败/边界：不默认注册；测试仅在主动复位窗口安装。
    extern function new(string	name = "rdma_transport_reset_catcher");

    // 功能：计数并捕获 Intel 已入队发送被复位中止的预期错误。
    // 输入/输出及副作用：读取当前 report id/severity；仅匹配 RTILE_RESET_ABORT 时 count 加一。
    // 失败/边界：其他 report 全部 THROW，不隐藏真正路由或协议错误。
    extern virtual function action_e catch();

  endclass

  // 独立包级测试，不创建 RDMA model system，验证真实传输边界不依赖 static current。
  class rdma_project_transport_test extends uvm_test;
    `uvm_component_utils(rdma_project_transport_test)
    pcie_tl_env					env;
    pcie_tl_env_config				cfg;
    intel_pcie_if_adapter			app[2];
    intel_pcie_if_adapter			hip[2];
    rdma_project_rc_driver			rc[2];
    host_mem_pool				pool;
    rdma_transport_counting_mem			manager[2];
    rdma_host_mem				view[2][2];
    bit [63:0]					allocation[2][2];
    dpu_device_snapshot				snapshot;
    dpu_pcie_bar_map				map;
    dpu_bar_target_t				target[2][2];
    rdma_project_pcie_bar			bar[2][2];
    virtual rdma_project_transport_control_if	control;

    // 功能：建立空测试实例，由 build 创建权威拓扑与传输环境。
    // 输入/输出及副作用：name/parent 传给 UVM；句柄初始为空。
    // 失败/边界：构造不发 MMIO、不启动设备，也不使用真实 RDMA shared grant。
    extern function new(string	name = "rdma_project_transport_test", uvm_component	parent = null);

    // 功能：把契约失败集中提升为 UVM_FATAL，防止后续空句柄误导诊断。
    // 输入/输出及副作用：condition/message 只读，失败报告 message。
    // 失败/边界：假条件立即结束；真条件无状态变化。
    extern function void require(bit	condition, string	message);

    // 功能：建立两个 Host 的同 BDF/重叠 BAR 和每 Host 两个 Function，使用正式 device resolver。
    // 输入/输出及副作用：创建 snapshot/map、公共pool/Function视图、RC-only env 和 APPLICATION 注入器；本测试用 factory 替换 manager 以统计访问。
    // 失败/边界：冻结/映射/内存分配失败 fatal；不创建 resource grant，也不声称可完成真实 RDMA init。
    extern function void build_phase(uvm_phase	phase);

    // 功能：独立 APPLICATION 捕获下一包，避免用生产 RC 自己的发送观察计数证明 wire 数据。
    // 输入/输出及副作用：port 选择物理 Host；packet 输出解码后的实际接收对象，receive 归还 Intel credit。
    // 失败/边界：10us 没有完整包即 fatal；不读另一个 Host，不默认回退端口零。
    extern task receive_packet(int unsigned	port, output pcie_tl_tlp	packet);

    // 功能：构建确定长度的设备 DMA wire 请求，requester 与冻结 BDF 故意不同。
    // 输入/输出及副作用：address/bytes/write_request/requester 输入；返回独立 TLP，写负载按字节序号构造。
    // 失败/边界：fixture 仅生成 DWORD 对齐非零长度；负向用例显式修改返回字段注入错误。
    extern function pcie_tl_mem_tlp dma_request(bit [63:0]	address, int unsigned	bytes,
        bit	write_request, bit [15:0]	requester = 16'h45);

    // 功能：直接观察 RX 分段 wire，独立断言 iowrite64be 的八个固定字节与 Intel sideband。
    // 输入/输出及副作用：port 选择 Host；从 monitor_cb 读取 literal payload，不调用编码函数或动态期望算法。
    // 失败/边界：首个包未包含八字节、PF/BAR/VF sideband 不符即 fatal；全局 watchdog 防止无流量死锁。
    extern task check_literal_wire(int unsigned	port);

    // 功能：给已绑定 RC 注入非法请求并检查 backing 调用和 wire 发送均为零。
    // 输入/输出及副作用：request/port 为故障 fixture；核对拒绝计数正好加一。
    // 失败/边界：不通过 Intel codec 发送不可编码对象，避免把 codec 拒绝误当作 RC 授权验证。
    extern task reject_dma(int unsigned	port, pcie_tl_tlp	request);

    // 功能：执行双 Host MMIO/DMA、部分 BE、完整预检负例及多 Completion 中的真实复位。
    // 输入/输出及副作用：phase 持有 objection；实际发包/读写 backing，最终释放 Function 分配。
    // 失败/边界：任一 oracle 不符 fatal；复位中止旧 context 后不重绑、不继续旧包或伪造初始化成功。
    extern task run_phase(uvm_phase	phase);

  endclass

  // 功能：创建真实 backing 的计数 manager。
  // 输入/输出及副作用：name 交给 manager，read/write 计数默认清零。
  // 失败/边界：区域由 build 显式初始化，构造不分配 Function 数据。
  function rdma_transport_counting_mem::new(string	name = "rdma_transport_counting_mem");
    super.new(name);
  endfunction

  // 功能：统计底层 backing 写次数并执行真实 manager 写。
  // 输入/输出及副作用：addr/data/file/line 原样传给 super，writes 每次调用加一。
  // 失败/边界：即使非法访问也先计数，使测试不能掩盖拒绝前的副作用。
  function void rdma_transport_counting_mem::write_mem(bit [63:0]	addr, byte	data[], string	file = "", int	line = 0);
    writes++;
    super.write_mem(addr, data, file, line);
  endfunction

  // 功能：统计底层 backing 读取次数并返回真实字节。
  // 输入/输出及副作用：addr/size/file/line 原样传给 super，data 为输出，reads 每次调用加一。
  // 失败/边界：计数覆盖所有底层调用，空/错误访问同样可被拒绝测试观察。
  function void rdma_transport_counting_mem::read_mem(bit [63:0]	addr, int unsigned	size, ref byte	data[],
      input string	file = "", input int	line = 0);
    reads++;
    super.read_mem(addr, size, data, file, line);
  endfunction

  // 功能：建立只用于 reset_abort 的报告捕获器。
  // 输入/输出及副作用：name 透传基类，count 初始零。
  // 失败/边界：不默认注册；测试仅在主动复位窗口安装。
  function rdma_transport_reset_catcher::new(string	name = "rdma_transport_reset_catcher");
    super.new(name);
  endfunction

  // 功能：计数并捕获 Intel 已入队发送被复位中止的预期错误。
  // 输入/输出及副作用：读取当前 report id/severity；仅匹配 RTILE_RESET_ABORT 时 count 加一。
  // 失败/边界：其他 report 全部 THROW，不隐藏真正路由或协议错误。
  function uvm_report_catcher::action_e rdma_transport_reset_catcher::catch();
    if (get_id() == "RTILE_RESET_ABORT" && get_severity() == UVM_ERROR) begin
      count++;
      return CAUGHT;
    end
    return THROW;
  endfunction

  // 功能：建立空测试实例，由 build 创建权威拓扑与传输环境。
  // 输入/输出及副作用：name/parent 传给 UVM；句柄初始为空。
  // 失败/边界：构造不发 MMIO、不启动设备，也不使用真实 RDMA shared grant。
  function rdma_project_transport_test::new(string	name = "rdma_project_transport_test", uvm_component	parent = null);
    super.new(name, parent);
  endfunction

  // 功能：把契约失败集中提升为 UVM_FATAL，防止后续空句柄误导诊断。
  // 输入/输出及副作用：condition/message 只读，失败报告 message。
  // 失败/边界：假条件立即结束；真条件无状态变化。
  function void rdma_project_transport_test::require(bit	condition, string	message);
    if (!condition)
      `uvm_fatal("PROJECT_TRANSPORT", message)
  endfunction

  // 功能：建立两个 Host 的同 BDF/重叠 BAR 和每 Host 两个 Function，使用正式 device resolver。
  // 输入/输出及副作用：创建 snapshot/map、公共pool/Function视图、RC-only env 和 APPLICATION 注入器；本测试用 factory 替换 manager 以统计访问。
  // 失败/边界：冻结/映射/内存分配失败 fatal；不创建 resource grant，也不声称可完成真实 RDMA init。
  function void rdma_project_transport_test::build_phase(uvm_phase	phase);
    dpu_device_cfg	device_cfg;
    rdma_dpu_function	funcs[$];
    rdma_status		status;
    dpu_host_info_t		host;
    string		why;
    int			index;

    super.build_phase(phase);
    require(uvm_config_db#(virtual rdma_project_transport_control_if)::get(this, "", "control", control),
      "missing physical reset control");
    device_cfg = dpu_device_cfg::type_id::create("transport_authoring");
    for (int	h = 0; h < 2; h++) begin
      rdma_dpu_topology::add_host(device_cfg, h == 0 ? 1 : 0, 0);
      // 两个 Host 故意声明相同 GPA；各自的 pool manager 必须保持 backing 隔离。
      device_cfg.hosts[h].gpa_base = 64'h4_0000_0000;
      device_cfg.hosts[h].gpa_limit = 64'h4_0010_0000;
      device_cfg.hosts[h].pcie_domains[0].mmio_windows[0].base = 64'h1_0000_0000;
      device_cfg.hosts[h].pcie_domains[0].mmio_windows[0].limit = 64'h2_0000_0000;
      for (int	f = 0; f < 2; f++) begin
        rdma_dpu_topology::add_function(device_cfg, h == 0 ? 1 : 0, f, DPU_FUNCTION_PF, 0);
        index = device_cfg.functions.size() - 1;
        device_cfg.functions[index].bdf_mode = DPU_ALLOC_PINNED;
        device_cfg.functions[index].pinned_bdf = 16'h20 + f;
        foreach (device_cfg.functions[index].bars[b]) begin
          device_cfg.functions[index].bars[b].placement = DPU_ALLOC_PINNED;
          device_cfg.functions[index].bars[b].pinned_base = 64'h1_0000_0000 +
            f * 64'h4000_0000 + b * 64'h1000_0000;
        end
      end
    end
    status = rdma_dpu_topology::resolve(device_cfg, snapshot, funcs);
    require(status.ok(), status.convert2string());
    map = dpu_pcie_bar_map::type_id::create("same_map");
    require(map.initialize(snapshot, 11, why), why);
    cfg = pcie_tl_env_config::type_id::create("cfg");
    cfg.rc_agent_enable = 1;
    cfg.ep_agent_enable = 0;
    cfg.num_rc = 2;
    cfg.num_ep = 0;
    cfg.ep_auto_response = 0;
    cfg.shaper_enable = 0;
    cfg.link_delay_enable = 0;
    cfg.use_unified_mem = 1;
    cfg.scb_enable = 0;
    host_mem_manager::type_id::set_type_override(rdma_transport_counting_mem::get_type());
    pool = host_mem_pool::type_id::create("transport_memory");
    for (int	h = 0; h < 2; h++) begin
      require(map.bind_host(h == 0 ? 1 : 0, h, why), why);
      require(snapshot.lookup_host(h == 0 ? 1 : 0, host, why), why);
      require(pool.create_host(host.host_id, host.gpa_base, host.gpa_limit - 1,
        MODE_BUDDY, 16), "could not create shared Host memory");
      require($cast(manager[h], pool.get_host(h == 0 ? 1 : 0)), "pool did not create counting manager");
      require(cfg.bind_host_memory(h, h == 0 ? 1 : 0, manager[h], why), why);
      for (int	f = 0; f < 2; f++) begin
        require(map.bind_function(device_cfg.functions[h * 2 + f].key, f + 2, -1,
          16'h45 + f, why), why);
        view[h][f] = rdma_host_mem::type_id::create($sformatf("view%0d_%0d", h, f));
        view[h][f].mem = manager[h];
        status = view[h][f].alloc(512, 4096, allocation[h][f]);
        require(status.ok(), status.convert2string());
        bar[h][f] = rdma_project_pcie_bar::type_id::create($sformatf("bar%0d_%0d", h, f));
      end
    end
    require(map.freeze(why), why);
    for (int	h = 0; h < 2; h++)
      for (int	f = 0; f < 2; f++)
        require(map.resolve_function(device_cfg.functions[h * 2 + f].key, 0, target[h][f], why), why);
    require(target[0][0].pcie_id.bdf == target[1][0].pcie_id.bdf &&
      target[0][0].bar_lease.base == target[1][0].bar_lease.base, "fixture must collide across Hosts");
    pcie_tl_rc_driver::type_id::set_inst_override(rdma_project_rc_driver::get_type(),
      {get_full_name(), ".env.*"});
    intel_pcie_configure_env(this, cfg, "env");
    env = pcie_tl_env::type_id::create("env", this);
    app[0] = intel_pcie_if_adapter::type_id::create("app0", this);
    app[1] = intel_pcie_if_adapter::type_id::create("app1", this);
  endfunction

  // 功能：独立 APPLICATION 捕获下一包，避免用生产 RC 自己的发送观察计数证明 wire 数据。
  // 输入/输出及副作用：port 选择物理 Host；packet 输出解码后的实际接收对象，receive 归还 Intel credit。
  // 失败/边界：10us 没有完整包即 fatal；不读另一个 Host，不默认回退端口零。
  task rdma_project_transport_test::receive_packet(int unsigned	port, output pcie_tl_tlp	packet);
    packet = null;
    for (int	i = 0; i < 5000; i++) begin
      app[port].receive(packet);
      if (packet != null)
        return;
      #2ns;
    end
    `uvm_fatal("PROJECT_TRANSPORT", "timed out capturing physical packet")
  endtask

  // 功能：构建确定长度的设备 DMA wire 请求，requester 与冻结 BDF 故意不同。
  // 输入/输出及副作用：address/bytes/write_request/requester 输入；返回独立 TLP，写负载按字节序号构造。
  // 失败/边界：fixture 仅生成 DWORD 对齐非零长度；负向用例显式修改返回字段注入错误。
  function pcie_tl_mem_tlp rdma_project_transport_test::dma_request(bit [63:0]	address, int unsigned	bytes,
      bit	write_request, bit [15:0]	requester = 16'h45);
    pcie_tl_mem_tlp	request;

    request = pcie_tl_mem_tlp::type_id::create("injected_dma");
    request.kind = write_request ? TLP_MEM_WR : TLP_MEM_RD;
    request.type_f = TLP_TYPE_MEM_RD;
    request.fmt = write_request ? FMT_4DW_WITH_DATA : FMT_4DW_NO_DATA;
    request.addr = address;
    request.length = bytes / 4;
    request.first_be = 4'hf;
    request.last_be = bytes == 4 ? 0 : 4'hf;
    request.requester_id = requester;
    request.tag = 10'h53;
    request.payload = new[write_request ? bytes : 0];
    foreach (request.payload[i])
      request.payload[i] = 8'h80 + i;
    return request;
  endfunction

  // 功能：直接观察 RX 分段 wire，独立断言 iowrite64be 的八个固定字节与 Intel sideband。
  // 输入/输出及副作用：port 选择 Host；从 monitor_cb 读取 literal payload，不调用编码函数或动态期望算法。
  // 失败/边界：首个包未包含八字节、PF/BAR/VF sideband 不符即 fatal；全局 watchdog 防止无流量死锁。
  task rdma_project_transport_test::check_literal_wire(int unsigned	port);
    bit	found;

    found = 0;
    while (!found) begin
      @(app[port].avst_vif.monitor_cb);
      for (int	s = 0; s < INTEL_SEGMENTS; s++) begin
        if (app[port].avst_vif.monitor_cb.rx_sop[s] && app[port].avst_vif.monitor_cb.rx_dvalid[s]) begin
          require(app[port].avst_vif.monitor_cb.rx_data[s][63:0] === 64'hefcdab8967452301,
            "literal wire bytes must be 01 23 45 67 89 ab cd ef");
          require(app[port].avst_vif.monitor_cb.rx_bar[s] == 0 &&
            app[port].avst_vif.monitor_cb.rx_pfnum[s] == 2 &&
            !app[port].avst_vif.monitor_cb.rx_vfactive[s], "wire PF/BAR sideband mismatch");
          found = 1;
        end
      end
    end
  endtask

  // 功能：给已绑定 RC 注入非法请求并检查 backing 调用和 wire 发送均为零。
  // 输入/输出及副作用：request/port 为故障 fixture；核对拒绝计数正好加一。
  // 失败/边界：不通过 Intel codec 发送不可编码对象，避免把 codec 拒绝误当作 RC 授权验证。
  task rdma_project_transport_test::reject_dma(int unsigned	port, pcie_tl_tlp	request);
    int unsigned	reads;
    int unsigned	writes;
    int unsigned	rejected;
    longint unsigned	sends;

    reads = manager[port].reads;
    writes = manager[port].writes;
    rejected = rc[port].rejected_requests;
    sends = hip[port].sent_packets;
    rc[port].handle_request(request);
    require(manager[port].reads == reads && manager[port].writes == writes &&
      rc[port].rejected_requests == rejected + 1 && hip[port].sent_packets == sends,
      "invalid DMA touched backing or emitted Completion");
  endtask

  // 功能：执行双 Host MMIO/DMA、部分 BE、完整预检负例及多 Completion 中的真实复位。
  // 输入/输出及副作用：phase 持有 objection；实际发包/读写 backing，最终释放 Function 分配。
  // 失败/边界：任一 oracle 不符 fatal；复位中止旧 context 后不重绑、不继续旧包或伪造初始化成功。
  task rdma_project_transport_test::run_phase(uvm_phase	phase);
    dpu_function_key_t	keys[$];
    rdma_host_mem	views[$];
    rdma_status		status;
    pcie_tl_tlp		packet;
    pcie_tl_mem_tlp	request;
    pcie_tl_mem_tlp	memory_packet;
    pcie_tl_cpl_tlp	completion;
    byte	data[];
    string				why;
    int unsigned			reads;
    int unsigned			writes;
    int unsigned			rejected;
    longint unsigned			sent;
    uvm_sequencer #(pcie_tl_tlp)	saved_sequencer;
    rdma_project_pcie_bar		invalid_bar;
    dpu_bar_target_t			stale_target;
    dpu_pcie_bar_map			missing_policy;
    rdma_transport_reset_catcher	catcher;

    phase.raise_objection(this);
    #100ns;
    for (int	h = 0; h < 2; h++) begin
      require($cast(rc[h], env.rc_agents[h].rc_driver), "wrong RC factory type");
      require($cast(hip[h], env.rc_adapters[h]), "wrong Intel adapter factory type");
      map.rc_sequencers[h] = env.v_seqr.rc_seqr_arr[h];
      status = null;
      bar[h][0].write64(0, 0, status);
      require(!status.ok(), "unbound BAR must not send");
      keys.delete();
      views.delete();
      for (int	f = 0; f < 2; f++) begin
        keys.push_back(target[h][f].function_key);
        views.push_back(view[h][f]);
      end
      status = rc[h].bind_transport(map, snapshot, cfg, h == 0 ? 1 : 0, h,
        manager[h], keys, views, 1);
      require(status.ok(), status.convert2string());
      for (int	f = 0; f < 2; f++) begin
        status = bar[h][f].bind_project(map, target[h][f], rc[h]);
        require(status.ok(), status.convert2string());
      end
      fork
        bar[h][0].write64(64'h80, 64'h0123456789abcdef, status);
        check_literal_wire(h);
      join
      require(status.ok(), status.convert2string());
      receive_packet(h, packet);
      require($cast(memory_packet, packet), "MMIO was not Memory TLP");
      require(memory_packet.addr == target[h][0].bar_lease.base + 'h80 &&
        memory_packet.payload.size() == 8 && packet.cq_route.pf_index == 2,
        "MMIO address/length/route mismatch");
    end
    // 两个 Host 的相同 requester 选择各自 backing；每个端口捕获独立 Completion。
    for (int	h = 0; h < 2; h++) begin
      request = dma_request(allocation[h][0], 8, 1);
      request.payload[0] = 8'h31 + h;
      writes = manager[h].writes;
      app[h].send(request);
      #50ns;
      require(manager[h].writes == writes + 8, "DMA write did not hit selected Host backing");
      data = new[0];
      manager[h].read_mem(allocation[h][0], 8, data);
      require(data.size() == 8 && data[0] == 8'h31 + h, "Host backing content mismatch");
      request = dma_request(allocation[h][0], 8, 0);
      app[h].send(request);
      receive_packet(h, packet);
      require($cast(completion, packet), "DMA read did not return Completion");
      require(completion.requester_id == 16'h45 && completion.tag == 10'h53 &&
        completion.payload.size() == 8 && completion.payload[0] == 8'h31 + h &&
        completion.cq_route.pf_index == 2, "Host/requester Completion mismatch");
    end
    // 正常多 Completion 路径必须保持基类的 RCB 分片与递减 Byte Count，独立核对每个线上 payload。
    data = new[256];
    foreach (data[i])
      data[i] = byte'(i + 3);
    status = view[0][0].write(allocation[0][0], data);
    require(status.ok(), status.convert2string());
    request = dma_request(allocation[0][0], 256, 0);
    reads = manager[0].reads;
    app[0].send(request);
    for (int	chunk = 0; chunk < 4; chunk++) begin
      receive_packet(0, packet);
      require($cast(completion, packet), "split read missing Completion");
      require(completion.payload.size() == 64 && completion.byte_count == 256 - chunk * 64 &&
        completion.tag == 10'h53 && completion.requester_id == 16'h45,
        "base Completion split length/count/identity changed");
      foreach (completion.payload[i])
        require(completion.payload[i] == byte'(chunk * 64 + i + 3), "split Completion data mismatch");
    end
    require(manager[0].reads == reads + 256, "split read backing count mismatch");
    // 部分 BE 只读两个中间字节；Completion 仍须提供 DWORD padding，不为 padding 访问 backing。
    request = dma_request(allocation[0][0], 4, 0);
    request.first_be = 4'b0110;
    reads = manager[0].reads;
    app[0].send(request);
    receive_packet(0, packet);
    require($cast(completion, packet), "partial BE read missing Completion");
    require(manager[0].reads == reads + 2 && completion.byte_count == 2 &&
      completion.payload.size() == 4 && completion.payload[0] == 0 && completion.payload[3] == 0 &&
      completion.payload[1] == 8'h04 && completion.payload[2] == 8'h05,
      "partial BE read accessed padding or returned wrong bytes");
    reject_dma(0, dma_request(allocation[0][1], 8, 1));
    reject_dma(0, dma_request(allocation[0][0], 8, 1, 16'hffff));
    reject_dma(0, dma_request(allocation[0][0] + 508, 8, 1));
    reject_dma(0, dma_request(64'hffff_ffff_ffff_fffc, 8, 1));
    request = dma_request(allocation[0][0], 8, 1);
    request.payload = new[4];
    reject_dma(0, request);
    request = dma_request(allocation[0][0], 8, 1);
    request.first_be = 0;
    reject_dma(0, request);
    request = dma_request(allocation[0][0], 8, 0);
    request.fmt = FMT_3DW_NO_DATA;
    reject_dma(0, request);
    request = dma_request(allocation[0][0], 8, 0);
    request.type_f = TLP_TYPE_CPL;
    reject_dma(0, request);
    request = dma_request(allocation[0][0], 8, 0);
    request.kind = TLP_ATOMIC_FETCHADD;
    reject_dma(0, request);
    // 编码错误必须在调用基类发送前拒绝，不能先分配 tag 或把未授权请求交给 Intel codec。
    request = dma_request(target[0][0].bar_lease.base, 8, 0);
    request.first_be = 0;
    sent = hip[0].sent_packets;
    rejected = rc[0].rejected_sends;
    rc[0].send_tlp(request);
    require(rc[0].rejected_sends == rejected + 1 && hip[0].sent_packets == sent,
      "malformed outbound Memory request reached Intel send");
    sent = app[0].received_packets;
    bar[0][0].write64(target[0][0].bar_lease.size - 4, 0, status);
    require(!status.ok(), "cross-BAR 8B write accepted");
    bar[0][0].write64(64'hffff_ffff_ffff_fffc, 0, status);
    require(!status.ok(), "overflowed BAR write accepted");
    saved_sequencer = map.rc_sequencers[0];
    map.rc_sequencers[0] = null;
    bar[0][0].write64(0, 0, status);
    require(!status.ok(), "missing sequencer accepted");
    map.rc_sequencers[0] = saved_sequencer;
    #20ns;
    require(app[0].received_packets == sent && app[1].rx_queue.size() == 0,
      "invalid BAR leaked to a physical port");
    invalid_bar = rdma_project_pcie_bar::type_id::create("stale_target");
    stale_target = target[0][0];
    status = invalid_bar.bind_project(map, target[0][0], null);
    require(!status.ok(), "missing RC driver accepted");
    stale_target.snapshot = null;
    status = invalid_bar.bind_project(map, stale_target, rc[0]);
    require(!status.ok(), "foreign/null snapshot accepted");
    stale_target = target[0][0];
    stale_target.snapshot_generation++;
    status = invalid_bar.bind_project(map, stale_target, rc[0]);
    require(!status.ok(), "stale BAR generation bound");
    status = invalid_bar.bind_project(map, target[0][0], rc[1]);
    require(!status.ok(), "BAR borrowed wrong Host driver");
    missing_policy = dpu_pcie_bar_map::type_id::create("missing_policy");
    require(missing_policy.initialize(snapshot, 12, why), why);
    require(missing_policy.bind_host(1, 0, why) && missing_policy.bind_host(0, 1, why), why);
    require(missing_policy.freeze(why), why);
    missing_policy.rc_sequencers[0] = saved_sequencer;
    require(missing_policy.resolve_function(target[0][0].function_key, 0, stale_target, why), why);
    status = invalid_bar.bind_project(missing_policy, stale_target, rc[0]);
    require(!status.ok(), "missing Function policy bound");
    require(!map.get_slot(1, 1, rejected, why) && !map.get_slot(999, 0, rejected, why),
      "unsupported segment/unknown Host fell back to RC0");
    cfg.shaper_enable = 1;
    bar[0][0].write64(0, 0, status);
    require(!status.ok(), "active shaping accepted");
    cfg.shaper_enable = 0;
    rc[0].fc_mgr.infinite_credit = 0;
    bar[0][0].write64(0, 0, status);
    require(!status.ok(), "effective finite credit accepted despite cfg");
    rc[0].fc_mgr.infinite_credit = 1;
    require(rc[0].revoke_function(target[0][1].function_key), "revoke known Function failed");
    bar[0][1].write64(0, 0, status);
    require(!status.ok(), "revoked Function MMIO accepted");
    reject_dma(0, dma_request(allocation[0][1], 8, 0, 16'h46));
    // 第一个 CplD 在 Intel send 内等待时撤销物理链路；不得为第二片再次读取 backing。
    catcher = new();
    uvm_report_cb::add(null, catcher);
    reads = manager[1].reads;
    request = dma_request(allocation[1][0], 256, 0);
    fork
      app[1].send(request);
      begin
        wait (manager[1].reads >= reads + 64);
        control.reset_port(1);
      end
    join
    #80ns;
    uvm_report_cb::delete(null, catcher);
    require(manager[1].reads == reads + 64, "reset allowed subsequent Completion backing reads");
    require(catcher.count == 1, "reset did not abort exactly the in-flight Completion");
    bar[1][0].write64(0, 0, status);
    require(!status.ok(), "old reset epoch BAR accepted");
    reject_dma(1, dma_request(allocation[1][0], 8, 1));
    rc[0].revoke();
    reject_dma(0, dma_request(allocation[0][0], 8, 0));
    for (int	h = 0; h < 2; h++) begin
      for (int	f = 0; f < 2; f++) begin
        status = view[h][f].free(allocation[h][f]);
        require(status.ok(), status.convert2string());
      end
    end
    `uvm_info("PROJECT_TRANSPORT_PASS", "dual Host Intel MMIO/DMA, literal bytes, isolation and epoch checks passed", UVM_LOW)
    phase.drop_objection(this);
  endtask
endpackage
