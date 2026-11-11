// 目录/层次：integration/virtio；RDMA 组合专用的 project_env_cfg overlay。
// 职责：复用 virtio_work project_env_cfg 的 DPU/VIO/PCIe 参数，并在同一配置对象中持有 RDMA 配置。
// 依赖：外部 project_env/project_base_test 只消费本类公开字段；RDMA 参数由 rdma_aip_cfg_loader 加载。
// 所有权/生命周期：本对象拥有 dpu_cfg、vio_cfg、pcie_cfg 和 rdma_cfg；平台注入的 pool/VIF 仍为借用引用。
// 该文件只由 rdma_virtio.f 使用，原 virtio_work project_env_cfg 和 project_env_pkg 不被修改。
class project_env_cfg extends uvm_object;
	`uvm_object_utils(project_env_cfg)
	// 三类子配置由本对象创建；每个 Host 的 VIO 配置在加载参数后独立生成。
	dpu_env_cfg				dpu_cfg;
	virtio_net_env_config	vio_cfg;
	virtio_net_env_config	vio_cfg_by_host[int unsigned];
	pcie_tl_env_config		pcie_cfg;

	// RDMA 与 VIO 共用本对象的快照、Host pool 和 platform controls；RDMA 默认关闭。
	rdma_env_cfg			rdma_cfg;
	bit				rdma_enabled;
	dpu_function_key_t		rdma_functions[$];
	protected bit			rdma_params_loaded;

	// 值是 RC agent 下标；EP 由真实 DUT 提供。缺省 h→h，PF/VF 共用 Host 的 slot。
	int unsigned	tl_slot_by_host[int unsigned];

	// 借用平台已有 pool；分配模式和粒度只作用于需要新建的 Host manager。
	host_mem_pool	host_mem_pool_binding;
	alloc_mode_e	host_mem_mode = MODE_BUDDY;
	int unsigned	host_mem_granule = DEFAULT_MIN_GRANULE;

	// 按物理 RC slot 索引，不是按 PF/VF 索引；同一 Host 的 Function 共用端口。
	// 平台可注入句柄，或由 bind wrapper 向实际 adapter 路径发布；env 会复用并校验。
	// Intel cfg 没有 load_params；这里不宣称 pcie_cfg.intel.* 已自动注册。
	intel_pcie_adapter_config	intel_cfg_by_slot[int unsigned];
	intel_pcie_vif_t			intel_rc_vifs[int unsigned];

	virtual virtio_protocol_event_if protocol_vifs[$];

	protected bit	params_loaded;

	// 功能：创建组合配置容器并建立 DPU/VIO/PCIe/RDMA 默认对象。
	// 输入/输出及副作用：name 传给 UVM；对象拥有四个子配置，RDMA 默认关闭且不读取参数。
	// 失败/边界：构造不访问平台句柄或快照；调用方须在 load_params 前注入可选 pool/VIF。
	extern function new(string	name = "project_env_cfg");

	// 功能：验证 Host→TL slot 是完整的一一映射，并核对每个 Host 的 segment 0。
	// 输入/输出及副作用：why 输出首个拒绝原因；只读 dpu_cfg、slot 和 Host domain，不访问 DUT。
	// 失败/边界：Host、VIO、slot 缺失、slot 重复/越界或 domain 非 Host segment 0 时返回假。
	extern function bit validate_tl_mapping(output string	why);

	// 功能：加载 DPU、各 Host VIO 和 Intel PCIe 的组合参数，再进入 RDMA 门控加载。
	// 输入/输出及副作用：更新三个子配置和 Host VIO 映射；不解析快照、不创建 env 或发送事务。
	// 失败/边界：重复调用保持幂等；非法内存粒度、模式、Host 映射或 PCIe 约束直接 fatal。
	extern virtual function void load_params();

	// 功能：加载组合环境的 RDMA 子配置，并把选中的 Function 映射到 dpu_common service。
	// 输入/输出及副作用：更新 rdma_cfg、rdma_functions 和 DPU service 列表；不解析快照、不分配硬件资源。
	// 失败/边界：关闭时保持空 RDMA 视图；显式 Function、grant、重复或不存在 Function 会拒绝。
	extern function void load_rdma_params();

	// 功能：构造 DPU/VIO/PCIe 运行期候选，保留当前对象身份和共享句柄。
	// 输入/输出及副作用：candidate 输出纯参数对象，why 输出首个校验失败；不分配 BAR/ring 或发送配置。
	// 失败/边界：任一子配置候选、VIO service 或 MSI-X scope 不可重载时返回假且不修改活动值。
	extern function bit make_runtime_candidate(
		output project_env_cfg	candidate,
		output string			why
	);

	// 功能：把已通过预检的 DPU/VIO/PCIe 候选原地提交到组合配置。
	// 输入/输出及副作用：candidate 提供新参数；更新子配置可变字段，保留对象、快照、BAR 和 pool 句柄。
	// 失败/边界：调用方必须先完成 make_runtime_candidate 和消费者预检；本函数不自行回滚或推进时间。
	extern function void apply_runtime_candidate(input project_env_cfg	candidate);
endclass

// 功能：创建组合配置容器并建立 DPU/VIO/PCIe/RDMA 默认对象。
// 输入/输出及副作用：name 传给 UVM；对象拥有四个子配置，RDMA 默认关闭且不读取参数。
// 失败/边界：构造不访问平台句柄或快照；调用方须在 load_params 前注入可选 pool/VIF。
function project_env_cfg::new(string	name);
	super.new(name);

	dpu_cfg  = dpu_env_cfg::type_id::create("dpu_cfg");
	vio_cfg  = virtio_net_env_config::type_id::create("vio_cfg");
	pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
	rdma_cfg = rdma_env_cfg::type_id::create("rdma_cfg");
	rdma_cfg.external_configuration = 1;
	rdma_cfg.vseq_type = "rdma_traffic_vseq";
	rdma_enabled = 0;

	vio_cfg.execution_mode         = VIRTIO_EXEC_REAL_DUT;
	vio_cfg.external_configuration = 1;
	vio_cfg.default_num_pairs      = 0;
endfunction

// 功能：验证 Host→TL slot 是完整的一一映射，并核对每个 Host 的 segment 0。
// 输入/输出及副作用：why 输出首个拒绝原因；只读 dpu_cfg、slot 和 Host domain，不访问 DUT。
// 失败/边界：Host、VIO、slot 缺失、slot 重复/越界或 domain 非 Host segment 0 时返回假。
function bit project_env_cfg::validate_tl_mapping(output string	why);
	bit				used_slots[int unsigned];
	int unsigned	count;

	why   = "";
	count = dpu_cfg.device_cfg.hosts.size();

	if (count == 0 || tl_slot_by_host.num() != count || vio_cfg_by_host.num() != count) begin
		why = "each DPU Host needs exactly one VIO config and TL slot";
		return 0;
	end

	foreach (dpu_cfg.device_cfg.hosts[i]) begin
		dpu_host_cfg	host;
		int unsigned	slot;

		host = dpu_cfg.device_cfg.hosts[i];

		if (host == null) begin
			why = "DPU Host config is null";
			return 0;
		end

		if (!tl_slot_by_host.exists(host.host_id) ||
			!vio_cfg_by_host.exists(host.host_id) || vio_cfg_by_host[host.host_id] == null) begin
			why = $sformatf("Host%0d has no VIO config or TL slot", host.host_id);
			return 0;
		end

		slot = tl_slot_by_host[host.host_id];

		if (slot >= count || used_slots.exists(slot)) begin
			why = "TL slots must be unique and cover 0..Host_count-1";
			return 0;
		end

		if (host.pcie_domains.size() != 1) begin
			why = "Intel project requires one PCIe domain per Host";
			return 0;
		end

		if (host.pcie_domains[0] == null) begin
			why = "Host PCIe domain is null";
			return 0;
		end

		if (
			host.pcie_domains[0].key.host_id != host.host_id ||
			host.pcie_domains[0].key.segment_id != 0
		) begin
			why = "Intel project requires Host-owned segment 0";
			return 0;
		end

		used_slots[slot] = 1;
	end

	return 1;
endfunction

// 功能：加载 DPU、各 Host VIO 和 Intel PCIe 的组合参数，再进入 RDMA 门控加载。
// 输入/输出及副作用：更新三个子配置和 Host VIO 映射；不解析快照、不创建 env 或发送事务。
// 失败/边界：重复调用保持幂等；非法内存粒度、模式、Host 映射或 PCIe 约束直接 fatal。
function void project_env_cfg::load_params();
	string	why;

	if (params_loaded) begin
		return;
	end
	dpu_cfg.load_params();
`ifdef AIP_CMDLINE_SV
	begin
		alloc_mode_e			mem_mode;
		host_mem_alloc_policy_e	mem_policy;
		longint unsigned		mem_granule;

		`aip_enum("dpu", alloc_mode_e, mem_mode, host_mem_mode)
		`aip_enum("dpu", host_mem_alloc_policy_e, mem_policy, vio_cfg.host_mem_policy)
		`DPU_AIP_UINT("dpu", longint unsigned, mem_granule, host_mem_granule)

		if (
			(mem_granule == 0) ||
			(mem_granule > 64) ||
			((mem_granule & (mem_granule - 1)) != 0)
		) begin
			`uvm_fatal("PROJECT_CFG", "dpu.mem_granule must be a power of two in 1..64")
		end

		host_mem_mode           = mem_mode;
		host_mem_granule        = int'(mem_granule);
		vio_cfg.host_mem_policy = mem_policy;
	end
`endif
	vio_cfg.external_configuration = 1;
	vio_cfg.load_params("vio");

	if (vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT) begin
		`uvm_fatal("PROJECT_INTEL", "Intel reference requires REAL_DUT EP application logic")
	end

	foreach (dpu_cfg.device_cfg.hosts[i]) begin
		int unsigned			h;
		virtio_net_env_config	host_vio;

		h        = dpu_cfg.device_cfg.hosts[i].host_id;
		host_vio = virtio_net_env_config::type_id::create($sformatf("vio_cfg_h%0d", h));
		host_vio.copy_defaults_from(vio_cfg);

		host_vio.host_id           = h;
		host_vio.host_scope_enable = 1;
		host_vio.host_scope_id     = h;

		host_vio.load_params($sformatf("vio.h%0d", h));
		host_vio.enable_service_params("vio");

		if (host_vio.execution_mode != vio_cfg.execution_mode) begin
			`uvm_fatal("PROJECT_CFG",
					   "one PCIe environment requires consistent VIO execution modes")
		end

		vio_cfg_by_host[h] = host_vio;

		if (!host_vio.bind_dpu_services(dpu_cfg, why)) `uvm_fatal("PROJECT_CFG", why)
	end
	if (tl_slot_by_host.num() == 0) begin
		for (int	unsigned	h = 0; h < dpu_cfg.hosts; h++) begin
			tl_slot_by_host[h] = h;
		end
	end

	if (!validate_tl_mapping(why)) begin
		`uvm_fatal("PROJECT_CFG", why)
	end

	// Intel 的接口选择由下面的固定模式和 env 的 instance override 完成，
	// 无需额外选择宏。标量参数仍加载，但不能绕过真实 DUT 的方向与信用约束。
	pcie_cfg.if_mode          = SV_IF_MODE;
	pcie_cfg.rc_is_active     = UVM_ACTIVE;
	pcie_cfg.ep_auto_response = 0;
	pcie_cfg.use_unified_mem  = 1;
	pcie_cfg.mem_access_mode  = PCIE_TL_MEM_PER_BUFFER;

	// 真实 EP 应用逻辑由 DUT 提供；Intel adapter 即使放在 passive agent 旁也会驱动
	// 引脚，因此必须关闭 EP 组件，而不是仅将 EP 标成 UVM_PASSIVE。
	pcie_cfg.rc_agent_enable = 1;
	pcie_cfg.ep_agent_enable = 0;
	pcie_cfg.num_rc          = tl_slot_by_host.num();
	pcie_cfg.num_ep          = 0;

	// 公共 FC 不门控；每端口有限 AVST credit 由 intel_cfg 独立管理。
	pcie_cfg.infinite_credit = 1;
	pcie_cfg.load_params("pcie_cfg");

	if (pcie_cfg.ep_auto_response) begin
		`uvm_fatal("PROJECT_CFG", "real EP DUT must provide its own responses")
	end

	if (!pcie_cfg.infinite_credit) begin
		`uvm_fatal("PROJECT_INTEL", "pcie_cfg.infinite_credit must be 1; Intel owns AVST credits")
	end

	load_rdma_params();
	params_loaded = 1;
endfunction

// 功能：在 DPU/VIO/PCIe 参数完成后，按统一 project_env_cfg 入口决定是否加载 RDMA。
// 输入/输出及副作用：读取 rdma.enabled、Function/grant 选择和 rdma.* 场景参数；开启时声明 DPU RDMA service。
// 失败/边界：关闭时不读取 RDMA 参数、不创建 service 或 Function；开启后空选择才覆盖全部
// DPU Function，重复调用由 rdma_params_loaded 保证幂等。
function void project_env_cfg::load_rdma_params();
	bit seen[string];
	bit enabled;
	rdma_status status;
	string vseq;

	if (rdma_params_loaded)
		return;
`ifdef AIP_CMDLINE_SV
	enabled = rdma_enabled;
	`aip_int("rdma", bit, enabled, rdma_enabled)
	rdma_enabled = enabled;
`endif
	if (!rdma_enabled && (rdma_functions.size() != 0 || rdma_cfg.grants.size() != 0))
		rdma_enabled = 1;
	if (!rdma_enabled) begin
		rdma_params_loaded = 1;
		return;
	end

	if (rdma_functions.size() == 0 && rdma_cfg.grants.size() != 0) begin
		foreach (rdma_cfg.grants[i])
			if (rdma_cfg.grants[i] != null)
				rdma_functions.push_back(rdma_cfg.grants[i].key);
	end
	if (rdma_functions.size() == 0) begin
		foreach (dpu_cfg.device_cfg.functions[i])
			rdma_functions.push_back(dpu_cfg.device_cfg.functions[i].key);
	end
	if (rdma_functions.size() == 0 || !rdma_cfg.external_configuration)
		`uvm_fatal("PROJECT_RDMA_CFG", "RDMA requires a nonempty Function selection and external mode")

	foreach (rdma_functions[i]) begin
		string key;
		bit found;

		key = dpu_function_key_name(rdma_functions[i]);
		if (seen.exists(key))
			`uvm_fatal("PROJECT_RDMA_CFG", {"duplicate RDMA Function: ", key})
		seen[key] = 1;
		found = 0;
		foreach (dpu_cfg.device_cfg.functions[j]) begin
			bit declared;
			dpu_service_decl service;

			if (!dpu_same_function_key(rdma_functions[i], dpu_cfg.device_cfg.functions[j].key))
				continue;
			found = 1;
			declared = 0;
			foreach (dpu_cfg.device_cfg.functions[j].services[k])
				if (dpu_cfg.device_cfg.functions[j].services[k].service_kind == DPU_SERVICE_RDMA)
					declared = 1;
			if (declared)
				continue;
			service = dpu_service_decl::type_id::create({"rdma_", key});
			service.service_kind = DPU_SERVICE_RDMA;
			service.service_instance_id = 0;
			dpu_cfg.device_cfg.functions[j].services.push_back(service);
		end
		if (!found)
			`uvm_fatal("PROJECT_RDMA_CFG", {"RDMA Function absent from dpu_common: ", key})
	end

	rdma_cfg.funcs.delete();
	vseq = rdma_cfg.vseq_type;
	status = rdma_aip_cfg_loader::load(rdma_cfg, vseq);
	if (!status.ok())
		`uvm_fatal("PROJECT_RDMA_CFG", status.convert2string())
	rdma_cfg.vseq_type = vseq;
	rdma_params_loaded = 1;
endfunction

// 功能：构造 DPU/VIO/PCIe 运行期候选，保留当前对象身份和共享句柄。
// 输入/输出及副作用：candidate 输出纯参数对象，why 输出首个校验失败；不分配 BAR/ring 或发送配置。
// 失败/边界：任一子配置候选、VIO service 或 MSI-X scope 不可重载时返回假且不修改活动值。
function bit project_env_cfg::make_runtime_candidate(
	output project_env_cfg	candidate,
	output string			why
);
	dpu_cfg_scope	msix_scope;

	candidate = new("runtime_candidate");
	if (!dpu_cfg.make_runtime_candidate(candidate.dpu_cfg, why)) return 0;
	if (!vio_cfg.make_runtime_candidate(null, "vio", candidate.vio_cfg, why)) return 0;
	foreach (vio_cfg_by_host[h]) begin
		if (!vio_cfg_by_host[h].make_runtime_candidate(
				candidate.vio_cfg, $sformatf("vio.h%0d", h), candidate.vio_cfg_by_host[h], why
			))
			return 0;
	end
	foreach (dpu_cfg.device_cfg.functions[f]) begin
		dpu_service_key_t	key;
		int unsigned		h;

		key = '{
			function_key: dpu_cfg.device_cfg.functions[f].key,
			service_kind: DPU_SERVICE_VIO_NET,
			service_instance_id: 0
		};
		h = key.function_key.host_id;
		if (!vio_cfg_by_host[h].validate_runtime_service(candidate.vio_cfg_by_host[h], key, why))
			return 0;
	end
	foreach (candidate.vio_cfg_by_host[h])
	if (!candidate.vio_cfg_by_host[h].bind_dpu_services(candidate.dpu_cfg, why, 0)) return 0;
	if (!candidate.dpu_cfg.select_msix_scope(msix_scope, why)) return 0;
	why = "";
	return 1;
endfunction

// 功能：把已通过预检的 DPU/VIO/PCIe 候选原地提交到组合配置。
// 输入/输出及副作用：candidate 提供新参数；更新子配置可变字段，保留对象、快照、BAR 和 pool 句柄。
// 失败/边界：调用方必须先完成 make_runtime_candidate 和消费者预检；本函数不自行回滚或推进时间。
function void project_env_cfg::apply_runtime_candidate(input project_env_cfg	candidate);
	dpu_cfg.apply_runtime_candidate(candidate.dpu_cfg);
	vio_cfg.apply_runtime_candidate(candidate.vio_cfg);
	foreach (vio_cfg_by_host[h])
	vio_cfg_by_host[h].apply_runtime_candidate(candidate.vio_cfg_by_host[h]);
endfunction
