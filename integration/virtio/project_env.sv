// 目录/层次：integration/virtio；virtio_work project_env 的本地 RDMA overlay。
// 职责：直接拥有 DPU、PCIe、各 Host VIO、共享 Host memory 和可选 RDMA env；只在 build/connect
//   阶段组装组件并发布同源快照，运行期参数重载沿用 virtio_work 的 load_params 契约。
// 依赖：project_env_cfg、dpu_pcie_pkg、virtio_dpu_pkg、rdma_env_pkg、rdma_project_pkg 及 Intel adapter。
// 所有权/生命周期：project_env 拥有子组件；RDMA 只借用 dpu_common snapshot/resource/pool/grant，
//   配置和业务启动由 sequence/Tcl 负责，外部 virtio_work checkout 不被修改。
typedef class project_env;

// 运行期参数命令共用项目 env；VIO 业务由 virtio_aip_pkg 管理，RDMA 业务由 rdma_aip_pkg 管理。
project_env	project_runtime_env;

// RDMA env 的 pre_build 绑定必须发生在 dpu_device_env 子树开始 build 前；插件只保存 project_cfg
// 的非拥有引用，把 dpu_common 发布的 snapshot/resource/pool/grant 投影给基础 rdma_env。
class rdma_virtio_bind_plugin extends rdma_env_plugin;
  `uvm_object_utils(rdma_virtio_bind_plugin)

  project_env_cfg project_cfg;

  // 功能：构造只保存组合配置引用的 RDMA 绑定插件。
  // 输入/输出及副作用：name 传给 UVM；不创建系统、不读取快照、不申请资源。
  // 失败/边界：project_cfg 必须在 rdma_env build 前注入，否则 pre_build 明确拒绝。
  function new(string name = "rdma_virtio_bind_plugin");
    super.new(name);
  endfunction

  // 功能：在基础 rdma_env finalize 前绑定 DPU 快照、资源快照、共享 Host pool，并补齐或使用显式 grant。
  // 输入/输出及副作用：更新 project_cfg.rdma_cfg.external_system/grants；所有外部对象保持非拥有引用，不分配 DMA。
  // 失败/边界：父级不是 dpu_device_env、重复投影、异源快照或 grant 不匹配时 fatal；不执行 probe/初始化。
  virtual function void pre_build(rdma_env env);
    dpu_device_env dpu;
    rdma_status status;
    string	why;

    if (project_cfg == null || env == null || !$cast(dpu, env.get_parent()))
      `uvm_fatal("RDMA_VIRTIO", "RDMA plugin requires a dpu_device_env parent and project_cfg")
    if (project_cfg.rdma_cfg.external_system != null)
      `uvm_fatal("RDMA_VIRTIO", "project_env owns the RDMA projection; do not inject a second system")

    project_cfg.rdma_cfg.external_system = rdma_dpu_system::type_id::create("rdma_projection");
    status = project_cfg.rdma_cfg.external_system.bind_snapshot(
      dpu.get_snapshot(), project_cfg.rdma_functions, project_cfg.host_mem_pool_binding);
    if (!status.ok())
      `uvm_fatal("RDMA_VIRTIO", status.convert2string())
    status = project_cfg.rdma_cfg.external_system.bind_resources(dpu.get_resource_snapshot());
    if (!status.ok())
      `uvm_fatal("RDMA_VIRTIO", status.convert2string())
    if (!project_cfg.make_rdma_grants(project_cfg.rdma_cfg.external_system, why))
      `uvm_fatal("RDMA_VIRTIO", why)
    status = project_cfg.rdma_cfg.external_system.bind_grants(project_cfg.rdma_cfg.grants);
    if (!status.ok())
      `uvm_fatal("RDMA_VIRTIO", status.convert2string())
  endfunction
endclass



class project_env extends uvm_env;
	`uvm_component_utils(project_env)

	project_env_cfg	cfg;
	dpu_device_env	dpu_env;
	pcie_tl_env		pcie_env;
	virtio_net_env	vio_envs[int unsigned];
	host_mem_pool	shared_pool;
	rdma_env		rdma;
	// project_env 按冻结 Function key 保存非拥有硬件绑定，动态支持任意 PF/VF 数量。
	rdma_drv_bar	rdma_bars[string];
	rdma_drv_hw	rdma_hws[string];

	local bit	tx_observation_bound[int unsigned];

	// 首次成功发布后才打印，重复同快照幂等，新拓扑要求 rebuild 而不留下新旧路由混合。
// 功能：根据 DPU snapshot、Host slot、Function policy 和 RC driver 建立并发布 project BAR map。
// 输入/输出及副作用：输出 ok/why；成功更新 cfg.dpu_cfg 的 map、消息和运行期发布状态，不发送配置表事务。
// 失败/边界：组件未 ready、拓扑缺失、已有异源 map 或任一 registry 安装失败时返回失败。
	extern function void publish_dpu_configuration(
		output bit		ok,
		output string	why
	);

	// EOE 与晚首次发布共用同一检查；自动打印去重由 registry 维护。
// 功能：在 EOE 阶段幂等发布 DPU 配置并登记唯一 project_runtime_env。
// 输入/输出及副作用：phase 透传；只读组件状态，必要时调用发布 helper，不启动任何 RDMA/VIO sequence。
// 失败/边界：快照或 map 仍未 ready、已有其他 runtime env 时 fatal；重复同源发布保持幂等。
	extern virtual function void end_of_elaboration_phase(uvm_phase	phase);

	// 构造组件壳；配置与共享资源延迟到 build，允许 test 先注入平台对象。
// 功能：创建 project_env 组件壳并保留 cfg、子环境和共享资源的空状态。
// 输入/输出及副作用：name/parent 交给 UVM；构造不创建 DPU、PCIe、VIO 或 RDMA 子组件，所有权在后续 build 阶段确定。
// 失败/边界：name 或 parent 不由调用方提供时由 UVM 拒绝；构造阶段不读取平台句柄。
	extern function new(
		string			name,
		uvm_component	parent
	);

	// 按 UVM 顺序建立 DPU、PCIe 和 VIO；缺 cfg 或绑定冲突立即报错。
// 功能：创建 project_env 的 DPU、PCIe、各 Host VIO 以及启用时的 RDMA 子环境。
// 输入/输出及副作用：phase 透传；读取 cfg、准备共享 pool/Intel binding，把完整 project_cfg 和 dpu_cfg
// 发布给 PCIe sequence，并把 RDMA cfg 发布到 dpu_env 子树；全部复用原对象句柄。
// 失败/边界：缺 cfg、Host memory、PCIe binding 或平台 VIF 时 fatal；RDMA 关闭时不创建 RDMA 子环境。
	extern virtual function void build_phase(uvm_phase	phase);

	// 子环境构建完毕后绑定快照、协议接口、Function endpoint 和 RDMA catalog；拒绝跨 Host 错配。
// 功能：连接 Intel RC、VIO endpoint、协议观察口，并在 RDMA 开启时追加同源控制目录。
// 输入/输出及副作用：phase 透传；复用已创建组件和冻结快照，不启动配置、初始化或流量 sequence。
// 失败/边界：adapter、RC、协议 VIF、snapshot 或 catalog 不一致时 fatal；连接失败不伪造 ready。
	extern virtual function void connect_phase(uvm_phase	phase);

	// 功能：把已冻结 RDMA Function 目录转换为 Notify/RNET 控制项并重新发布同源 DPU 配置。
	// 输入/输出及副作用：只更新 cfg.dpu_cfg 的控制目录和已发布值，不发送 PCIe 事务或启动 driver。
	// 失败/边界：RDMA 未开启时为空操作；快照/map/grant 不完整、重复目录或发布失败时 fatal。
	extern protected function void bind_rdma_catalog();

	// 功能：按每个 RDMA Function 的冻结 BAR 和 Host RC 创建 Intel BAR adapter/driver hardware，
	//   并把它们绑定到 rdma_dpu_system；不启动 probe、初始化或流量 sequence。
	// 输入/输出及副作用：更新 rdma_bars/rdma_hws 和外部系统节点的硬件句柄；只借用 map、RC、Host memory。
	// 失败/边界：RDMA 未启用为空操作；缺 map、节点、BAR、RC 或任一绑定失败立即 fatal，禁止留下半绑定系统。
	extern protected function void bind_rdma_hardware();

	// 功能：从 dpu_common 冻结 MSI-X catalog 中筛出 VIO/AF resource 实际拥有的 vector。
	// 输入/输出及副作用：按 Host 读取同源 resource snapshot，输出可交给 VIO RC 的值复制 catalog；不修改 snapshot。
	// 失败/边界：缺少冻结 resource snapshot 返回 why；未配置 VIO/AF resource 时输出空目录，不把 RDMA vector 当作 VIO sink。
	extern protected function void collect_vio_msix_messages(
		int unsigned				host_id,
		input dpu_msix_message_t	catalog[$],
		output dpu_msix_message_t	messages[$],
		output string				why
	);


	// 运行期入口：重读当前AIP参数，只在首次prepare前或已release后更新同一个cfg。
// 功能：按 virtio_work 契约重载 DPU/VIO 参数，并在 RDMA 开启时原子提交 RDMA 候选。
// 输入/输出及副作用：输出 ok/why；候选验证通过后更新既有 cfg、RC 消息、VIO 运行参数和 rdma_env cfg。
// 失败/边界：活动 VIO generation、RDMA 初始化已开始、候选或 RC catalog 校验失败时不提交。
	extern task load_params(
		output bit		ok,
		output string	why
	);

	// 统一停止并回收全部 Host 的 VIO；调用时机由用户安排，没有队列时成功返回。
	// 先等待所有 worker 退出，再预检和回收实际资源并清除 cfg 的队列导出值。
// 功能：停止并释放每个 Host 的 VIO external setup，清除对应 DPU queue 导出值。
// 输入/输出及副作用：输出 ok/why；先停止 worker、再逐 Host 预检和释放资源，不触碰 RDMA driver 或共享 pool 其他分配。
// 失败/边界：仍有活动 worker、setup 预检失败或释放失败时立即返回，已释放 Host 保持其实际状态。
	extern task release_vio_resources(
		output bit		ok,
		output string	why
	);

	// 每次仿真登记一次各 Host 的 VIO 服务及 Tcl 命令；空服务或重复注册会报错。
// 功能：把各 Host 的 VIO env 绑定到 virtio AIP registry 并注册既有业务命令。
// 输入/输出及副作用：无显式输出；只写 AIP registry，RDMA 命令由 rdma_virtio_test 单独注册。
// 失败/边界：空 VIO 服务时保持空操作；重复绑定或命令冲突由 registry 返回失败并 fatal。
	extern function void register_aip_commands();

	// 准备或借用各 Host 的共享内存，校验已有 manager 的身份、范围与分配策略。
// 功能：为每个 DPU Host 选择或创建唯一共享 Host memory manager。
// 输入/输出及副作用：读取 cfg 的 pool/aperture/policy，更新 shared_pool、DPU cfg 和每个 VIO cfg 的借用句柄。
// 失败/边界：已有 pool 类型、范围、Host ID 或策略不一致时 fatal，不重置既有分配。
	extern protected function void prepare_host_memory();

	// 校验 cfg 已确定的 RC 拓扑并绑定 Host 内存，不在组件创建阶段重复覆盖参数。
// 功能：校验 Intel RC-only 拓扑并把每个 Host slot 绑定到共享 Host manager。
// 输入/输出及副作用：读取 cfg 的 PCIe/slot 映射，更新 pcie_cfg.host_mem_by_root；不创建组件或发送 TLP。
// 失败/边界：Switch、EP agent、有限信用、slot 缺失或 manager 不同源时 fatal。
	extern protected function void prepare_pcie_config();

	// 在 PCIe build 前解析各端口的 cfg/VIF，借用 wrapper 对象并拒绝缺失或复用。
// 功能：在 PCIe env 创建前解析每个 RC slot 的 Intel adapter cfg 和物理 VIF。
// 输入/输出及副作用：读取 config_db 与 cfg 显式句柄，更新 cfg.intel_cfg_by_slot/intel_rc_vifs 并发布给 PCIe env。
// 失败/边界：缺 VIF、side 不为 HARD_IP、cfg/VIF 跨 slot 复用或发布句柄不一致时 fatal。
	extern protected function void prepare_intel_bindings();

	// 连接阶段核对实际 adapter、cfg/VIF 句柄及 RC-only 组件树，不再补绑接口。
// 功能：在 connect 阶段确认实际 PCIe 树为 Intel bridge、RC-only，并消费同一 cfg/VIF。
// 输入/输出及副作用：只读 pcie_env 和 cfg adapter 句柄；失败通过 UVM_FATAL 报告，不补绑接口。
// 失败/边界：缺 adapter、EP 组件未关闭、bridge 未启用或 cfg/VIF 句柄不同源时 fatal。
	extern protected function void check_intel_bindings();

	// 按完整 Function 身份分配协议 VIF，拒绝空接口以及跨 Host/Function 复用。
// 功能：按完整 Function 身份为每个 VIO instance 分配唯一协议事件 VIF。
// 输入/输出及副作用：读取 cfg 显式 VIF 或 uvm_test_top slot，更新每个 Host VIO 的 protocol mapping。
// 失败/边界：VIF 缺失、数量不足、为空或跨 Function/Host 复用时 fatal。
	extern protected function void bind_protocol_vifs();
endclass

// 构造项目组件壳；资源创建延迟到 build，以允许 test 注入已有平台对象。
// 功能：创建 project_env 组件壳并保留 cfg、子环境和共享资源的空状态。
// 输入/输出及副作用：name/parent 交给 UVM；构造不创建 DPU、PCIe、VIO 或 RDMA 子组件，所有权在后续 build 阶段确定。
// 失败/边界：name 或 parent 不由调用方提供时由 UVM 拒绝；构造阶段不读取平台句柄。
function project_env::new(
	string			name,
	uvm_component	parent
);
	super.new(name, parent);
endfunction

// 为每个 Host 准备唯一 manager；DPU 的 GPA limit 是开区间，pool end 是闭区间。
// 已有 manager 必须覆盖声明 aperture 且策略一致，不重置已有分配/数据。
// 功能：为每个 DPU Host 选择或创建唯一共享 Host memory manager。
// 输入/输出及副作用：读取 cfg 的 pool/aperture/policy，更新 shared_pool、DPU cfg 和每个 VIO cfg 的借用句柄。
// 失败/边界：已有 pool 类型、范围、Host ID 或策略不一致时 fatal，不重置既有分配。
function void project_env::prepare_host_memory();
	host_mem_pool	dpu_pool;

	shared_pool = cfg.host_mem_pool_binding;

	if (cfg.dpu_cfg.host_mem_pool_ref != null) begin
		if (!$cast(dpu_pool, cfg.dpu_cfg.host_mem_pool_ref)) begin
			`uvm_fatal("PROJECT_ENV", "DPU memory owner is not a host_mem_pool")
		end

		if (shared_pool != null && shared_pool != dpu_pool) begin
			`uvm_fatal("PROJECT_ENV", "project and DPU specify distinct Host pools")
		end

		shared_pool = dpu_pool;
	end

	if (shared_pool == null) begin
		shared_pool = host_mem_pool::type_id::create("shared_pool");
	end

	foreach (cfg.dpu_cfg.device_cfg.hosts[i]) begin
		dpu_host_cfg			host;
		virtio_net_env_config	vio;
		host_mem_manager		manager;

		host = cfg.dpu_cfg.device_cfg.hosts[i];

		if (host == null || !host.has_gpa_aperture || host.gpa_limit <= host.gpa_base) begin
			`uvm_fatal("PROJECT_ENV", "each Host requires a nonempty GPA aperture")
		end

		if (!cfg.vio_cfg_by_host.exists(host.host_id)) begin
			`uvm_fatal("PROJECT_ENV", "Host has no VIO behavior configuration")
		end

		vio = cfg.vio_cfg_by_host[host.host_id];

		if (!shared_pool.has_host(host.host_id)) begin
			if (!shared_pool.create_host(
					host.host_id,
					host.gpa_base,
					host.gpa_limit - 1,
					cfg.host_mem_mode,
					cfg.host_mem_granule,
					vio.host_mem_policy
				)) begin
				`uvm_fatal("PROJECT_ENV", "could not initialize Host memory")
			end
		end

		manager = shared_pool.get_host(host.host_id);

		if (
			!manager.is_initialized() ||
			manager.get_host_id() != host.host_id ||
			!manager.contains_range(host.gpa_base, host.gpa_limit - host.gpa_base) || manager.get_alloc_policy() != vio.host_mem_policy) begin
			`uvm_fatal("PROJECT_ENV",
					   "existing Host memory disagrees with configured aperture/policy")
		end

		if (
			vio.host_mem_binding != null ||
			(vio.host_mem_pool_binding != null && vio.host_mem_pool_binding != shared_pool)
		) begin
			`uvm_fatal("PROJECT_ENV", "Host VIO cfg must borrow the project-owned pool")
		end

		vio.host_mem_pool_binding = shared_pool;
		vio.mem_base              = host.gpa_base;
		vio.mem_end               = host.gpa_limit - 1;
	end

	cfg.host_mem_pool_binding     = shared_pool;
	cfg.dpu_cfg.host_mem_pool_ref = shared_pool;
endfunction

// 按显式 Host→slot 绑定 TL 内存；拓扑由 cfg 加载时确定，这里不再次赋固定值。
// 每 Host 只保留一个 RC，EP 和配置空间/MMIO 响应来自真实 DUT。
// 既有绑定只校验不重建；Switch、多余绑定或不同 manager 都拒绝。
// 功能：校验 Intel RC-only 拓扑并把每个 Host slot 绑定到共享 Host manager。
// 输入/输出及副作用：读取 cfg 的 PCIe/slot 映射，更新 pcie_cfg.host_mem_by_root；不创建组件或发送 TLP。
// 失败/边界：Switch、EP agent、有限信用、slot 缺失或 manager 不同源时 fatal。
function void project_env::prepare_pcie_config();
	string	why;

	if (!cfg.validate_tl_mapping(why)) begin
		`uvm_fatal("PROJECT_ENV", why)
	end

	if (cfg.pcie_cfg.switch_enable) begin
		`uvm_fatal("PROJECT_ENV", "Intel project reference does not create a Switch")
	end

	if (
		cfg.vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT ||
		!cfg.pcie_cfg.rc_agent_enable ||
		cfg.pcie_cfg.num_rc != cfg.tl_slot_by_host.num() ||
		cfg.pcie_cfg.ep_agent_enable ||
		cfg.pcie_cfg.num_ep != 0 ||
		cfg.pcie_cfg.if_mode != SV_IF_MODE ||
		!cfg.pcie_cfg.infinite_credit ||
		cfg.pcie_cfg.rc_is_active != UVM_ACTIVE ||
		cfg.pcie_cfg.ep_auto_response ||
		!cfg.pcie_cfg.use_unified_mem
	) begin
		`uvm_fatal(
			"PROJECT_INTEL",
			"Intel requires REAL_DUT, one active RC per Host, no VIP EP, SV_IF_MODE, unified memory and infinite public FC")
	end

	if (cfg.pcie_cfg.ep_root_by_index.num() != 0) begin
		`uvm_fatal("PROJECT_INTEL", "real EP DUT must not have VIP EP-to-Root bindings")
	end

	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned		slot;
		host_mem_manager	manager;

		slot    = cfg.tl_slot_by_host[h];
		manager = shared_pool.get_host(h);

		if (cfg.pcie_cfg.host_mem_by_root.exists(slot)) begin
			if (
				cfg.pcie_cfg.host_mem_by_root[slot] != manager ||
				!cfg.pcie_cfg.host_id_by_root.exists(slot) || cfg.pcie_cfg.host_id_by_root[slot] != h) begin
				`uvm_fatal("PROJECT_ENV", "PCIe Host memory binding disagrees with DPU owner")
			end
		end else if (!cfg.pcie_cfg.bind_host_memory(slot, h, manager, why)) begin
			`uvm_fatal("PROJECT_ENV", why)
		end
	end

	if (cfg.pcie_cfg.host_mem_by_root.num() != cfg.tl_slot_by_host.num()) begin
		`uvm_fatal("PROJECT_ENV", "extra PCIe Root bindings are not part of this project")
	end
endfunction

// 在 pcie_env::create 前解析每个端口的配置和 VIF：cfg 显式句柄与 wrapper 发布值
// 必须相同；只缺配置时可创建 HARD_IP 默认对象，缺 HDL 接口则不能自动补造。
// 复用 wrapper 对象以保留端口压力/信用设置，拒绝跨端口共享可变 cfg 或物理 VIF。
// 功能：在 PCIe env 创建前解析每个 RC slot 的 Intel adapter cfg 和物理 VIF。
// 输入/输出及副作用：读取 config_db 与 cfg 显式句柄，更新 cfg.intel_cfg_by_slot/intel_rc_vifs 并发布给 PCIe env。
// 失败/边界：缺 VIF、side 不为 HARD_IP、cfg/VIF 跨 slot 复用或发布句柄不一致时 fatal。
function void project_env::prepare_intel_bindings();
	intel_pcie_adapter_config	used_cfgs[$];
	intel_pcie_vif_t			used_vifs[$];

	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned				slot;
		string						path;
		intel_pcie_adapter_config	port_cfg;
		intel_pcie_adapter_config	published_cfg;
		intel_pcie_vif_t			vif;
		intel_pcie_vif_t			published_vif;

		slot          = cfg.tl_slot_by_host[h];
		path          = $sformatf("pcie_env.rc_adapter_%0d", slot);
		port_cfg      = null;
		published_cfg = null;
		vif           = null;
		published_vif = null;

		if (cfg.intel_cfg_by_slot.exists(slot)) begin
			port_cfg = cfg.intel_cfg_by_slot[slot];

			if (port_cfg == null) begin
				`uvm_fatal("PROJECT_INTEL", "explicit Intel cfg is null")
			end
		end

		if (uvm_config_db#(intel_pcie_adapter_config)::get(this, path, "intel_cfg", published_cfg)) begin
			if (published_cfg == null || (port_cfg != null && port_cfg != published_cfg)) begin
				`uvm_fatal("PROJECT_INTEL",
						   "project and wrapper publish different Intel cfg handles")
			end

			port_cfg = published_cfg;
		end

		if (port_cfg == null) begin
			port_cfg = intel_pcie_adapter_config::type_id::create($sformatf("intel_cfg_%0d", slot));

			port_cfg.side = INTEL_PCIE_HARD_IP;
		end

		if (port_cfg.side != INTEL_PCIE_HARD_IP) begin
			`uvm_fatal("PROJECT_INTEL",
					   "EP application DUT requires explicit INTEL_PCIE_HARD_IP side")
		end

		port_cfg.validate();

		if (cfg.intel_rc_vifs.exists(slot)) begin
			vif = cfg.intel_rc_vifs[slot];

			if (vif == null) begin
				`uvm_fatal("PROJECT_INTEL", "explicit Intel VIF is null")
			end
		end

		if (uvm_config_db#(intel_pcie_vif_t)::get(this, path, "vif", published_vif)) begin
			if (published_vif == null || (vif != null && vif != published_vif)) begin
				`uvm_fatal("PROJECT_INTEL", "project and wrapper publish different Intel VIFs")
			end

			vif = published_vif;
		end

		if (vif == null) begin
			`uvm_fatal("PROJECT_INTEL", $sformatf("missing Intel VIF at %s.%s", get_full_name(),
												  path))
		end

		foreach (used_cfgs[i]) begin
			if (used_cfgs[i] == port_cfg || used_vifs[i] == vif) begin
				`uvm_fatal("PROJECT_INTEL", "Intel cfg or VIF reused by distinct TL slots")
			end
		end

		used_cfgs.push_back(port_cfg);
		used_vifs.push_back(vif);

		cfg.intel_cfg_by_slot[slot] = port_cfg;
		cfg.intel_rc_vifs[slot]     = vif;

		uvm_config_db#(intel_pcie_adapter_config)::set(this, path, "intel_cfg", port_cfg);

		uvm_config_db#(intel_pcie_vif_t)::set(this, path, "vif", vif);
	end

	if (
		cfg.intel_cfg_by_slot.num() != cfg.tl_slot_by_host.num() ||
		cfg.intel_rc_vifs.num() != cfg.tl_slot_by_host.num()
	) begin
		`uvm_fatal("PROJECT_INTEL", "Intel bindings contain an unused TL slot")
	end
endfunction

// connect 时只校验实际创建的 adapter，不再补绑接口；否则 adapter build 早已失败。
// 确认 instance override 和 bridge 生效，防止接口配置看似存在却仍走公共 TLM 回环。
// 功能：在 connect 阶段确认实际 PCIe 树为 Intel bridge、RC-only，并消费同一 cfg/VIF。
// 输入/输出及副作用：只读 pcie_env 和 cfg adapter 句柄；失败通过 UVM_FATAL 报告，不补绑接口。
// 失败/边界：缺 adapter、EP 组件未关闭、bridge 未启用或 cfg/VIF 句柄不同源时 fatal。
function void project_env::check_intel_bindings();
	if (
		!pcie_env.bridge_required ||
		pcie_env.ep_agent != null ||
		pcie_env.ep_agents.size() != 0 ||
		pcie_env.ep_adapter != null ||
		pcie_env.ep_adapters.size() != 0
	) begin
		`uvm_fatal("PROJECT_INTEL",
				   "Intel needs the external-pin bridge and RC-only component tree")
	end

	foreach (cfg.intel_cfg_by_slot[slot]) begin
		intel_pcie_if_adapter	adapter;

		if (slot >= pcie_env.rc_adapters.size()) begin
			`uvm_fatal("PROJECT_INTEL", "Intel RC adapter slot is missing")
		end

		if (!$cast(adapter, pcie_env.rc_adapters[slot]) || adapter == null) begin
			`uvm_fatal("PROJECT_INTEL", "Intel instance factory override did not take effect")
		end

		if (
			adapter.cfg != cfg.intel_cfg_by_slot[slot] ||
			adapter.avst_vif != cfg.intel_rc_vifs[slot]
		) begin
			`uvm_fatal("PROJECT_INTEL", "Intel adapter consumed different cfg/VIF handles")
		end
	end
endfunction

// 这里只创建组件和发布输入，不提前查询 DPU snapshot，也不手动调用子组件 build。
// create(..., dpu_env) 让 VIO 位于 DPU 子树；框架先 build DPU，再 build VIO。
// PCIe 只需要 Host 内存和 TL cfg，可以与 DPU 同级，不依赖二者遍历先后顺序。
// 功能：创建 project_env 的 DPU、PCIe、各 Host VIO 以及启用时的 RDMA 子环境。
// 输入/输出及副作用：phase 透传；读取 cfg、准备共享 pool/Intel binding，把完整 project_cfg 和 dpu_cfg
// 发布给 PCIe sequence，并把 RDMA cfg 发布到 dpu_env 子树；全部复用原对象句柄。
// 失败/边界：缺 cfg、Host memory、PCIe binding 或平台 VIF 时 fatal；RDMA 关闭时不创建 RDMA 子环境。
function void project_env::build_phase(uvm_phase	phase);

	super.build_phase(phase);

	if (!uvm_config_db#(project_env_cfg)::get(this, "", "cfg", cfg) || cfg == null) begin
		`uvm_fatal("PROJECT_ENV", "project environment cfg is missing")
	end

	cfg.load_params();
	uvm_config_db#(project_env_cfg)::set(this, "pcie_env.*", "project_cfg", cfg);
	uvm_config_db#(dpu_env_cfg)::set(this, "pcie_env.*", "dpu_cfg", cfg.dpu_cfg);
	prepare_host_memory();
	prepare_pcie_config();

	uvm_config_db#(dpu_env_cfg)::set(this, "dpu_env", "cfg", cfg.dpu_cfg);

	dpu_env = dpu_device_env::type_id::create("dpu_env", this);

	if (cfg.rdma_enabled) begin
		rdma_virtio_bind_plugin	binder;

		binder = rdma_virtio_bind_plugin::type_id::create("rdma_bind");
		binder.project_cfg = cfg;
		cfg.rdma_cfg.plugins.push_back(binder);
		uvm_config_db#(rdma_env_cfg)::set(dpu_env, "rdma", "cfg", cfg.rdma_cfg);
		rdma = rdma_env::type_id::create("rdma", dpu_env);
	end

	prepare_intel_bindings();

	// bridge 的历史字段名含 svt，但这里只开启外部引脚传输，不创建 SVT/provider。
	intel_pcie_configure_env(this, cfg.pcie_cfg, "pcie_env");
	foreach (cfg.tl_slot_by_host[h]) begin
		pcie_tl_rc_driver::type_id::set_inst_override(
			vio_pcie_rc_driver::get_type(), $sformatf(
			"pcie_env.rc_agent_%0d.driver", cfg.tl_slot_by_host[h]), this);
	end
	pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

	foreach (cfg.vio_cfg_by_host[h]) begin
		string	child_name;

		child_name = $sformatf("vio_h%0d", h);

		uvm_config_db#(virtio_net_env_config)::set(dpu_env, child_name, "cfg",
												   cfg.vio_cfg_by_host[h]);

		vio_envs[h] = virtio_net_env::type_id::create(child_name, dpu_env);
	end
endfunction

// 全项目统一分配协议 VIF；显式身份映射优先，兼容 top 的全局 VIF slot 入口。
// 在 Function 绑定 PCIe 前拒绝空接口和跨 Host/Function 复用，不依赖各 Host 局部计数。
// 功能：按完整 Function 身份为每个 VIO instance 分配唯一协议事件 VIF。
// 输入/输出及副作用：读取 cfg 显式 VIF 或 uvm_test_top slot，更新每个 Host VIO 的 protocol mapping。
// 失败/边界：VIF 缺失、数量不足、为空或跨 Function/Host 复用时 fatal。
function void project_env::bind_protocol_vifs();
	virtual virtio_protocol_event_if used [$];
	virtual virtio_protocol_event_if vif;
	int unsigned	slot;
	string			why;

	slot = 0;

	foreach (vio_envs[h]) begin
		foreach (vio_envs[h].function_instances[i]) begin
			virtio_function_instance	f;

			f = vio_envs[h].function_instances[i];

			if (!cfg.vio_cfg_by_host[h].get_protocol_event_vif(f.pcie_id, vif)) begin
				if (cfg.protocol_vifs.size() != 0) begin
					if (slot >= cfg.protocol_vifs.size()) begin
						`uvm_fatal("PROJECT_ENV", "protocol VIF pool is too small")
					end

					vif = cfg.protocol_vifs[slot];
				end else if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(null, "uvm_test_top", $sformatf("protocol_event_vif_%0d", slot), vif)) begin
					`uvm_fatal("PROJECT_ENV", "global protocol VIF slot is missing")
				end

				if (!cfg.vio_cfg_by_host[h].bind_protocol_event_vif(f.pcie_id, vif, why)) begin
					`uvm_fatal("PROJECT_ENV", why)
				end
			end

			if (vif == null) begin
				`uvm_fatal("PROJECT_ENV", "protocol VIF is null")
			end

			foreach (used[j]) begin
				if (used[j] == vif) begin
					`uvm_fatal("PROJECT_ENV", "protocol VIF reused by distinct Functions/Hosts")
				end
			end

			used.push_back(vif);
			slot++;
		end
	end
endfunction

// connect 自底向上运行，此时 DPU 快照和 PCIe/VIO 子组件均已完成 build/connect。
// 从 Function 的完整身份选择 Host 对应的 TL slot；BDF/BAR 不在 PCIe 中重新分配。
// 功能：连接 Intel RC、VIO endpoint、协议观察口，并在 RDMA 开启时追加同源控制目录。
// 输入/输出及副作用：phase 透传；复用已创建组件和冻结快照，不启动配置、初始化或流量 sequence。
// 失败/边界：adapter、RC、协议 VIF、snapshot 或 catalog 不一致时 fatal；连接失败不伪造 ready。
function void project_env::connect_phase(uvm_phase	phase);
	super.connect_phase(phase);

	if (
		pcie_env.global_cfg != null ||
		pcie_env.topology_adapter != null ||
		pcie_env.backend_provider_active ||
		pcie_env.cfg != cfg.pcie_cfg
	) begin
		`uvm_fatal("PROJECT_ENV", "Intel project requires the direct PCIe cfg-only path")
	end

	check_intel_bindings();
	bind_protocol_vifs();

	begin
		bit		ok;
		string	why;

		publish_dpu_configuration(ok, why);
		if (!ok) `uvm_fatal("PROJECT_PUBLICATION", why)
	end

	foreach (vio_envs[h]) begin
		virtio_pcie_function_endpoint	endpoints[$];
		int unsigned					slot;

		slot = cfg.tl_slot_by_host[h];

		if (slot >= pcie_env.rc_agents.size() || pcie_env.rc_agents[slot] == null) begin
			`uvm_fatal("PROJECT_ENV", "Host has no native RC agent")
		end

		foreach (vio_envs[h].function_instances[i]) begin
			virtio_function_instance		f;
			virtio_pcie_function_endpoint	endpoint;

			f = vio_envs[h].function_instances[i];

			if (f.pcie_id.domain.host_id != h || f.pcie_id.domain.segment_id != 0) begin
				`uvm_fatal("PROJECT_ENV", "Function does not belong to its Host segment 0")
			end

			endpoint = virtio_pcie_function_endpoint::type_id::create(
				$sformatf("endpoint_h%0d_f%0d", h, i));

			// Completion 由 PCIe RC driver 接收；无模型 completion adapter 或 EP monitor。
			// 同 Host 的所有 Function 共用该 RC，完整身份仍由 endpoint 保留。
			endpoint.configure(f.pcie_id, pcie_env.rc_agents[slot].sequencer,
							   pcie_env.rc_agents[slot].rc_driver, null,
							   pcie_env.rc_agents[slot].monitor, null);

			endpoints.push_back(endpoint);
		end

		if (!vio_envs[h].bind_pcie_endpoints(endpoints)) begin
			`uvm_fatal("PROJECT_ENV", "VIO endpoint binding failed")
		end
		// 真 DUT 无 EP 接收 monitor；RC monitor 仅收包，发出的真实 doorbell 从 driver TX 观察口补齐。
		// 仅补出站观察，不连接第二 responder，也不重复消费入站 MSI-X。
		if (!tx_observation_bound.exists(h)) begin
			foreach (vio_envs[h].function_instances[i])
			pcie_env.rc_agents[slot].rc_driver.tx_ap.connect(
				vio_envs[h].function_instances[i].driver_agent.observer.analysis_export);
			tx_observation_bound[h] = 1;
		end
	end
	// 发布真实组件句柄，所有配置 sequence 共享它们，不复制运行期状态。
	foreach (vio_envs[h]) begin
		uvm_config_db#(virtio_net_env)::set(this, "pcie_env.*", $sformatf("vio_env_h%0d", h),
											vio_envs[h]);
	end
	bind_rdma_catalog();
	bind_rdma_hardware();
endfunction

// 功能：按 RDMA 节点顺序把 dpu_common BAR0 目标和 Intel RC sequencer 投影给 RDMA driver。
// 输入/输出及副作用：为每个节点创建一个 rdma_pcie_bar 与 rdma_drv_hw，并调用
//   rdma_dpu_system::bind_external_hw_by_key；不发送 TLP、不分配 Host memory、不启动驱动。
// 失败/边界：只接受已冻结同源 dpu_pcie_bar_map；节点顺序、BAR0、Host RC 或外部 driver cfg 缺失时 fatal，
//   任一失败都停止绑定，避免后续 rdma_init 看到部分可用硬件。
function void project_env::bind_rdma_hardware();
	dpu_pcie_bar_map				map;
	rdma_pcie_bar			bar;
	dpu_bar_target_t				target;
	uvm_sequencer #(pcie_tl_tlp)	sequencer;
	rdma_drv_hw					hw;
	rdma_status					status;
	string						key_name;
	string						why;

	if (!cfg.rdma_enabled)
		return;
	if (rdma == null || rdma.sys == null || cfg.dpu_cfg.bar_map == null) begin
		`uvm_fatal("RDMA_VIRTIO", "RDMA hardware binding requires an initialized system and BAR map")
	end
	if (!$cast(map, cfg.dpu_cfg.bar_map) || map == null || !map.is_frozen()) begin
		`uvm_fatal("RDMA_VIRTIO", "RDMA hardware binding requires a frozen Intel BAR map")
	end
	if (rdma.sys.nodes.size() == 0 || rdma.sys.nodes.size() != cfg.rdma_functions.size()) begin
		`uvm_fatal("RDMA_VIRTIO", "RDMA node set does not match the configured Function selection")
	end

	rdma_bars.delete();
	rdma_hws.delete();
	foreach (rdma.sys.nodes[i]) begin
		if (rdma.sys.nodes[i] == null || rdma.sys.nodes[i].func == null ||
			rdma.sys.nodes[i].mem == null || rdma.sys.nodes[i].drv_cfg == null) begin
			`uvm_fatal("RDMA_VIRTIO", $sformatf("RDMA node %0d is incomplete before hardware binding", i))
		end
		if (!map.resolve_function(rdma.sys.nodes[i].func.key,
						  rdma.sys.nodes[i].func.bar0.even_bar_id, target, why)) begin
			`uvm_fatal("RDMA_VIRTIO", why)
		end
		if (!map.get_sequencer(target, sequencer, why)) begin
			`uvm_fatal("RDMA_VIRTIO", why)
		end

		key_name = dpu_function_key_name(rdma.sys.nodes[i].func.key);
		bar = rdma_pcie_bar::type_id::create({"rdma_bar_", key_name});
		bar.map       = map;
		bar.target    = target;
		bar.sequencer = sequencer;

		hw = rdma_drv_hw::type_id::create({"rdma_hw_", key_name});
		status = hw.bind_hw(bar, rdma.sys.nodes[i].mem);
		if (!status.ok())
			`uvm_fatal("RDMA_VIRTIO", status.convert2string())
		status = rdma.sys.bind_external_hw_by_key(rdma.sys.nodes[i].func.key,
			hw, rdma.sys.nodes[i].drv_cfg);
		if (!status.ok())
			`uvm_fatal("RDMA_VIRTIO", status.convert2string())

		rdma_bars[key_name] = bar;
		rdma_hws[key_name]  = hw;
	end
endfunction

// 功能：把已冻结 RDMA Function 目录转换为 Notify/RNET 控制项并重新发布同源 DPU 配置。
// 输入/输出及副作用：更新 platform_controls 和已发布 bar_map；不启动 RDMA driver 或流量 sequence。
// 失败/边界：关闭 RDMA 时不解析目录；任一控制项重复、grant 不匹配或 publish 失败时 fatal。
function void project_env::bind_rdma_catalog();
	dpu_control_cfg_t	controls[$];
	string			why;

	if (!cfg.rdma_enabled)
		return;
	foreach (cfg.dpu_cfg.platform_controls[i])
		if (cfg.dpu_cfg.platform_controls[i].ctx.kind inside {DPU_TABLE_RDMA_NOTIFY, DPU_TABLE_RNET})
			`uvm_fatal("RDMA_VIRTIO", "project_env generates the RDMA catalog exactly once")
	if (!rdma_project_cfg_seq::make_catalog_for_grants(dpu_env.get_snapshot(), cfg.dpu_cfg.bar_map,
		cfg.rdma_functions, cfg.rdma_cfg.grants, controls, why))
		`uvm_fatal("RDMA_VIRTIO", why)
	foreach (controls[i])
		cfg.dpu_cfg.platform_controls.push_back(controls[i]);
	if (!cfg.dpu_cfg.publish(dpu_env.get_snapshot(), dpu_env.get_resource_snapshot(),
		cfg.dpu_cfg.bar_map, why))
		`uvm_fatal("RDMA_VIRTIO", why)
endfunction

// 每个仿真调用一次：按完整 service 身份登记各 Host 的 VIO env；RDMA 注册由 test 在 env 完成连接后执行。
// 空 Host 可跳过；VIO 关闭时不注册 VIO 业务命令，重复注册仍报接入错误。
// 功能：把各 Host 的 VIO env 绑定到 virtio AIP registry，并注册既有 VIO 业务命令。
// 输入/输出及副作用：无显式输出；VIO 命令对象和状态由 virtio AIP package 持有，project_env 不实现命令。
// 失败/边界：空 VIO 服务保持空操作；重复绑定、异源环境或命令冲突由 registry 返回失败并 fatal。
function void project_env::register_aip_commands();
	int unsigned	active_hosts;
	string			why;

	active_hosts = 0;

	foreach (vio_envs[h]) begin
		if (vio_envs[h].function_instances.size() == 0) begin
			continue;
		end

		if (!virtio_aip_registry::bind_env(vio_envs[h], why)) begin
			`uvm_fatal("PROJECT_ENV", why)
		end

		active_hosts++;
	end

	if (active_hosts != 0 && !virtio_aip_registry::register_business_commands(why)) begin
		`uvm_fatal("PROJECT_ENV", why)
	end

endfunction

// 功能：按 dpu_common resource snapshot 的 VIO qpair/AF extra vector 选择消息，隔离 RDMA-only vector。
// 输入/输出及副作用：host_id 和 catalog 为只读输入，messages 输出值复制；why 返回快照缺失原因，不改写 catalog。
// 失败/边界：resource snapshot 未冻结或与当前 DPU snapshot 不同源时返回空目录和失败原因；重复 vector 只保留一行。
function void project_env::collect_vio_msix_messages(
	int unsigned				host_id,
	input dpu_msix_message_t	catalog[$],
	output dpu_msix_message_t	messages[$],
	output string				why
);
	dpu_resource_snapshot	resources;
	dpu_vio_qpair_binding_t	pairs[$];
	dpu_af_extra_queue_binding_t	extras[$];
	bit					selected[string];
	string					key;

	messages.delete();
	why = "DPU resource snapshot is unavailable for MSI-X filtering";
	resources = dpu_env == null ? null : dpu_env.get_resource_snapshot();
	if (resources == null || !resources.is_frozen())
		return;
	if (dpu_env.get_snapshot() == null ||
		!resources.references_device_snapshot(dpu_env.get_snapshot())) begin
		why = "DPU resource snapshot is not from the active device snapshot";
		return;
	end
	resources.list_vio_bindings(pairs);
	resources.list_af_extra_queue_bindings(extras);
	foreach (pairs[i]) begin
		if (pairs[i].service_key.function_key.host_id == host_id)
			selected[$sformatf("%s:%0d", dpu_function_key_name(pairs[i].service_key.function_key),
				pairs[i].local_msix_vector_id)] = 1;
	end
	foreach (extras[i]) begin
		if (extras[i].af_function_key.host_id == host_id)
			selected[$sformatf("%s:%0d", dpu_function_key_name(extras[i].af_function_key),
				extras[i].local_msix_vector_id)] = 1;
	end
	foreach (catalog[i]) begin
		if (catalog[i].owner.host_id != host_id)
			continue;
		key = $sformatf("%s:%0d", dpu_function_key_name(catalog[i].owner),
			catalog[i].local_vector);
		if (selected.exists(key)) begin
			bit duplicate;
			duplicate = 0;
			foreach (messages[j])
				if (messages[j].owner == catalog[i].owner &&
					messages[j].local_vector == catalog[i].local_vector)
					duplicate = 1;
			if (!duplicate)
				messages.push_back(catalog[i]);
		end
	end
	why = "";
endfunction

// 建立一份 PCIe BAR 扩展并交给公共 cfg；driver 与配置 seq 复用同一个对象。
// 功能：根据 DPU snapshot、Host slot、Function policy 和 RC driver 建立并发布 project BAR map。
// 输入/输出及副作用：输出 ok/why；成功更新 cfg.dpu_cfg 的 map、消息和运行期发布状态，不发送配置表事务。
// 失败/边界：组件未 ready、拓扑缺失、已有异源 map 或任一 registry 安装失败时返回失败。
function void project_env::publish_dpu_configuration(
	output bit		ok,
	output string	why
);
	dpu_pcie_bar_map	map;
	dpu_host_info_t		hosts[$];
	vio_pcie_rc_driver	driver;
	dpu_msix_message_t	host_messages[$];

	ok  = 0;
	why = "DPU/PCIe components are not ready";
	if (dpu_env == null || pcie_env == null || dpu_env.get_snapshot() == null) begin
		return;
	end
	if (cfg.dpu_cfg.runtime_ready) begin
		if (cfg.dpu_cfg.device_snapshot != dpu_env.get_snapshot()) begin
			why = "new DPU snapshot requires environment rebuild";
			return;
		end
		ok = !cfg.dpu_cfg.print_bar_map || cfg.dpu_cfg.bar_map.print_bar_map(why, 1);
		return;
	end
	map = dpu_pcie_bar_map::type_id::create("bar_map");
	if (!map.initialize(dpu_env.get_snapshot(), 1, why)) begin
		return;
	end
	dpu_env.get_snapshot().list_hosts(hosts);
	foreach (hosts[i]) begin
		int unsigned	h;
		int unsigned	slot;

		h = hosts[i].host_id;
		if (!cfg.tl_slot_by_host.exists(h)) begin
			return;
		end
		slot = cfg.tl_slot_by_host[h];
		if (!map.bind_host(h, slot, why)) begin
			return;
		end
		if (slot >= pcie_env.rc_agents.size() || !$cast(driver, pcie_env.rc_agents[slot].rc_driver)) begin
			why = "VIO RC driver override was not installed";
			return;
		end
		map.rc_sequencers[slot] = pcie_env.rc_agents[slot].sequencer;
	end
	foreach (cfg.dpu_cfg.function_policies[name]) begin
		dpu_function_policy_t	p;

		p = cfg.dpu_cfg.function_policies[name];
		if (name != dpu_function_key_name(p.key) || $isunknown(p.requester) || !map.bind_function(p.key, p.intel_pf, p.intel_vf, p.requester, why))
			return;
	end
	if (!map.freeze(why) || !cfg.dpu_cfg.publish(dpu_env.get_snapshot(), dpu_env.get_resource_snapshot(), map, why))
		return;
	foreach (hosts[i]) begin
		int unsigned	h;
		int unsigned	slot;

		h    = hosts[i].host_id;
		slot = cfg.tl_slot_by_host[h];
		void'($cast(driver, pcie_env.rc_agents[slot].rc_driver));
		// 只把 dpu_common 冻结 catalog 中有 VIO/AF resource 归属的条目交给 RC；
		// RDMA vector 没有平台 event sink 时不进入 VIO responder 的消费目录。
		collect_vio_msix_messages(h, cfg.dpu_cfg.frozen_messages, host_messages, why);
		if (why != "")
			return;
		if (!driver.install_registry(map, h, 0, slot, why) || !driver.install_receive_path(
				vio_envs[h].host_mem, vio_envs[h].iommu, host_messages, why
			))
			return;
	end
    // 同一个 Requester 可同时使用 VIO IOVA 与 RDMA 直接 Host 地址。
    // 公共 RC 在每笔请求上检查唯一所有者；冲突拒绝，不靠业务优先级绕过权限。
    if (rdma != null && rdma.sys != null) begin
		foreach (rdma.sys.nodes[i]) begin
			dpu_function_key_t key;
			dpu_bar_target_t target;
			pcie_tl_cq_route_t route;
			dpu_function_policy_t policy;
			string function_name;
			int unsigned slot;
			key = rdma.sys.nodes[i].func.key;
			if (!map.resolve_function(key, rdma.sys.nodes[i].func.bar0.even_bar_id, target, why) ||
				!map.get_route(target, route, why)) return;
			function_name = dpu_function_key_name(key);
			if (!cfg.dpu_cfg.function_policies.exists(function_name)) begin
				why = {"RDMA Function has no DPU policy: ", function_name};
				return;
			end
			policy = cfg.dpu_cfg.function_policies[function_name];
			if ($isunknown(policy.requester)) begin
				why = {"RDMA Function policy has unknown requester: ", function_name};
				return;
			end
			slot = cfg.tl_slot_by_host[key.host_id];
			if (!$cast(driver, pcie_env.rc_agents[slot].rc_driver)) return;
			if (!driver.install_vio_dma_view(policy.requester, why) ||
				!driver.register_dma_view(policy.requester, rdma.sys.nodes[i].mem.dma_view, why)) return;
		end
	    end
	ok = !cfg.dpu_cfg.print_bar_map || map.print_bar_map(why, 1);
endfunction

// EOE 与晚首次发布共用同一检查；自动打印去重由 BAR map 维护。
// 功能：在 EOE 阶段幂等发布 DPU 配置并登记唯一 project_runtime_env。
// 输入/输出及副作用：phase 透传；只读组件状态，必要时调用发布 helper，不启动任何 RDMA/VIO sequence。
// 失败/边界：快照或 map 仍未 ready、已有其他 runtime env 时 fatal；重复同源发布保持幂等。
function void project_env::end_of_elaboration_phase(uvm_phase	phase);
	bit		ok;
	string	why;

	super.end_of_elaboration_phase(phase);
	publish_dpu_configuration(ok, why);
	if (!ok) `uvm_fatal("PROJECT_PUBLICATION", why)
	if (project_runtime_env != null && project_runtime_env != this)
		`uvm_fatal("PROJECT_PARAM", "runtime commands already bound to another project environment")
	project_runtime_env = this;
endfunction

// Tcl 释放整个项目的 VIO 资源，无须保留配置 sequence；不影响其他业务的 Host 内存。
// 用户安排 DUT 业务收尾时序；本 task 只自动停止 VIP worker，不轮询或复位 DUT。
// 已停止的 worker 不重复 stop；全部退出后先预检各 Host，随后无时间推进地统一回收。
// 功能：停止并释放每个 Host 的 VIO external setup，清除对应 DPU queue 导出值。
// 输入/输出及副作用：输出 ok/why；先停止 worker、再逐 Host 预检和释放资源，不触碰 RDMA driver 或共享 pool 其他分配。
// 失败/边界：仍有活动 worker、setup 预检失败或释放失败时立即返回，已释放 Host 保持其实际状态。
task project_env::release_vio_resources(
	output bit		ok,
	output string	why
);
	vio_external_setup	setup;
	virtio_auto_fsm		fsm;

	ok  = 0;
	why = "";

	foreach (vio_envs[h]) begin
		if (vio_envs[h].get_external_setup() == null) continue;

		foreach (vio_envs[h].function_instances[f]) begin
			fsm = vio_envs[h].function_instances[f].driver_agent.fsm;
			if (!fsm.external_workers_stopped())
				fsm.stop_dataplane();
		end
	end

	foreach (vio_envs[h]) begin
		setup = vio_envs[h].get_external_setup();
		if (setup == null) continue;

		if (!vio_envs[h].preflight_external_configuration(setup, null, why)) begin
			why = $sformatf("Host%0d: %s", h, why);
			return;
		end
	end

	foreach (vio_envs[h]) begin
		setup = vio_envs[h].get_external_setup();
		if (setup == null) continue;

		if (!vio_envs[h].release_external_resources(setup, 1'b1, why)) begin
			why = $sformatf("Host%0d: %s", h, why);
			return;
		end
		cfg.dpu_cfg.clear_host_queues(h);
	end

	ok  = 1;
	why = "";
endtask

// 全部候选和RC消息先校验，成功后不推进时间地提交；不自动停DUT或释放现有ring。
// 资源和协议规模固定，字段更改由下一次配置seq写入DUT，命令自身不发送PCIe请求。
// 功能：按 virtio_work 契约重载 DPU/VIO 参数，并在 RDMA 开启时原子提交 RDMA 候选。
// 输入/输出及副作用：输出 ok/why；候选验证通过后更新既有 cfg、RC 消息、VIO 运行参数和 rdma_env cfg。
// 失败/边界：活动 VIO generation、RDMA 初始化已开始、候选或 RC catalog 校验失败时不提交。
task project_env::load_params(
	output bit		ok,
	output string	why
);
	project_env_cfg		candidate;
	rdma_env_cfg		rdma_candidate;
	rdma_status		rdma_status;
	vio_pcie_rc_driver	drivers[int unsigned];
	dpu_msix_message_t	host_messages[int unsigned][$];

	ok = 0;
	why = "load_params requires published env without an active VIO generation; release before reload";
	if (cfg == null || !cfg.dpu_cfg.runtime_ready) begin
		return;
	end
	foreach (vio_envs[h]) begin
		if (vio_envs[h].get_external_setup() != null) begin
			return;
		end
	end
	foreach (vio_envs[h])
		foreach (vio_envs[h].function_instances[f]) begin
			virtio_function_instance	vio_instance;

			vio_instance = vio_envs[h].function_instances[f];
			if (vio_instance.driver_agent.ops == null || vio_instance.driver_agent.fsm == null ||
			vio_instance.driver_agent.ops.has_active_queues() ||
			!vio_instance.driver_agent.fsm.external_workers_stopped())
				return;
		end
	if (!cfg.make_runtime_candidate(candidate, why)) begin
		return;
	end
	if (cfg.rdma_enabled) begin
		if (rdma == null) begin
			why = "RDMA is enabled but project_env did not create rdma_env";
			return;
		end
		rdma_status = rdma_aip_cfg_loader::make_runtime_candidate(cfg.rdma_cfg, rdma_candidate);
		if (!rdma_status.ok()) begin
			why = rdma_status.convert2string();
			return;
		end
		rdma_status = rdma.validate_runtime_candidate(rdma_candidate);
		if (!rdma_status.ok()) begin
			why = rdma_status.convert2string();
			return;
		end
	end
	foreach (vio_envs[h]) begin
		int unsigned	slot;

		slot = cfg.tl_slot_by_host[h];
		if (!$cast(drivers[h], pcie_env.rc_agents[slot].rc_driver)) begin
			why = "project RC driver is unavailable";
			return;
		end
		// 候选 catalog 同样按同源 resource 过滤，避免环境替 RDMA 解释 MSI-X。
		collect_vio_msix_messages(h, candidate.dpu_cfg.frozen_messages, host_messages[h], why);
		if (why != "")
			return;
		if (!drivers[h].validate_message_catalog(host_messages[h], why)) begin
			return;
		end
	end

	cfg.apply_runtime_candidate(candidate);
	foreach (vio_envs[h]) begin
		// 相同候选已通过全Host预检，函数无时间推进；提交不更换BAR或DMA backing。
		if (!drivers[h].replace_message_catalog(host_messages[h], why))
			`uvm_fatal("PROJECT_PARAM", why)
		vio_envs[h].wait_pol.copy(cfg.vio_cfg_by_host[h].wait_policy_cfg);
		foreach (vio_envs[h].function_instances[f]) begin
			virtio_function_instance	vio_instance;
			vio_service_requirement_t	requirement;

			vio_instance = vio_envs[h].function_instances[f];
			void'(cfg.vio_cfg_by_host[h].resolve_final_service_requirement(vio_instance.service_key, requirement, why));
			requirement.behavior.max_vio_net_qpairs_per_device = vio_instance.drv_cfg.max_vio_net_qpairs_per_device;
			vio_instance.drv_cfg = requirement.behavior;
			vio_instance.driver_agent.fsm.drv_cfg = vio_instance.drv_cfg;
			vio_instance.private_cfg =
				cfg.vio_cfg_by_host[h].get_dpu_private_config(vio_instance.service_key);
		end
	end
	if (cfg.rdma_enabled)
		rdma.apply_runtime_candidate(rdma_candidate);
	ok  = 1;
	why = "";
	`uvm_info("PROJECT_PARAM",
			  "reloaded runtime parameters into existing cfg; run dut_config to program DUT",
			  UVM_LOW)
endtask

// 顶层无参命令保持原 status/result_out；restore 后读取 AIP 当前来源，命令自身不写 DUT。
// 功能：把 AIP load_params 命令转发给唯一 project_runtime_env。
// 输入/输出及副作用：读取 command.args_in，调用 env.load_params 并写回 status/result_out；不启动 PCIe sequence。
// 失败/边界：带参数、runtime env 未建立或 env 候选失败时返回非零状态。
task project_load_params();
	aip_cmd	command;
	bit		ok;
	string	why;

	command = aip_cmd::get_handle("load_params");
	if (command.args_in != "") begin
		command.status     = 1;
		command.result_out = "ERROR: load_params takes no arguments";
		return;
	end
	if (project_runtime_env == null) begin
		command.status     = 1;
		command.result_out = "ERROR: load_params environment is not ready";
		return;
	end
	project_runtime_env.load_params(ok, why);
	command.status     = ok ? 0 : 1;
	command.result_out = ok ? "OK: runtime parameters reloaded" : {"ERROR: load_params: ", why};
endtask

`aip_cmd_task(load_params, project_load_params)

// 无参 Tcl 命令统一停止并释放 VIO；沿用宏的 status/result_out 通道返回结果。
// 用户负责选择调用时机，不再读取参数表或要求单独的停机确认参数。
// 功能：把 AIP vio_release 命令转发给唯一 project_runtime_env。
// 输入/输出及副作用：读取 command.args_in，调用 env.release_vio_resources 并写回 status/result_out。
// 失败/边界：带参数、runtime env 未建立或 VIO 回收失败时返回非零状态。
task project_vio_release();
	aip_cmd	command;
	bit		ok;
	string	why;

	command = aip_cmd::get_handle("vio_release");
	if (command.args_in != "") begin
		command.status     = 1;
		command.result_out = "ERROR: vio_release takes no arguments";
		return;
	end
	if (project_runtime_env == null) begin
		command.status     = 1;
		command.result_out = "ERROR: vio_release environment is not ready";
		return;
	end

	project_runtime_env.release_vio_resources(ok, why);
	command.status     = ok ? 0 : 1;
	command.result_out = ok ? "OK: VIO resources released" : {"ERROR: vio_release: ", why};
endtask

`aip_cmd_task(vio_release, project_vio_release)
