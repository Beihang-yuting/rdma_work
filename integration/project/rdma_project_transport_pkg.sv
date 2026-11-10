// 目录/层次：integration/project，后编译的 Intel PCIe 传输接入层。
// 职责：同源 BAR map 同时决定 MMIO sideband 与 DMA Function authority；复用 RC responder 的 Completion 分片。
// 依赖：dpu_pcie_pkg、Intel adapter、rdma_pcie_work_pkg 和 rdma_host_mem_pkg；核心 PCIe 包不反向依赖本包。
// 所有权：平台拥有冻结快照/map、Host manager、Function 视图和 Intel env；本层全部借用，仅拥有请求上下文。
// 生命周期：可在 connect 发布空 BAR，但必须在 prepare_platform 完成初始复位后一次性 bind；此前访问拒绝。
// 平台在独立 FLR/link teardown 前显式 revoke；绑定不支持 rearm，重置后的旧 epoch 永久失效。
package rdma_project_transport_pkg;
  import uvm_pkg::*;
  import dpu_resource_pkg::*;
  import dpu_pcie_pkg::*;
  import host_mem_pkg::*;
  import pcie_tl_pkg::*;
  import intel_pcie_adapter_pkg::*;
  import rdma_types_pkg::*;
  import rdma_host_mem_pkg::*;
  import rdma_pcie_work_pkg::*;
  `include "uvm_macros.svh"

  typedef class rdma_project_rc_driver;

  // 基类 responder 只认识 host_mem_api；永久安装此无分配权适配器，避免临时切换共享 mem 句柄。
  class rdma_project_dma_mem extends host_mem_api;
    rdma_project_rc_driver	owner;

    // 功能：建立无 backing、无分配账本的 responder 内存适配器。
    // 输入/输出及副作用：name 传给基类；owner 由所属 RC 设置为非拥有引用。
    // 失败/边界：owner 尚未设置时所有访问拒绝，构造不创建 manager。
    extern function new(string	name = "rdma_project_dma_mem");

    // 功能：拒绝通过 responder 重新定义平台 Host 地址区域。
    // 输入/输出及副作用：base_addr/end_addr/m/granule/poison 不转发，只报告不支持。
    // 失败/边界：始终拒绝，不改变已有 manager 或分配。
    extern virtual function void init_region(bit [63:0]	base_addr, bit [63:0]	end_addr,
        alloc_mode_e	m = MODE_BUDDY, int unsigned	granule = DEFAULT_MIN_GRANULE,
        byte	poison = DEFAULT_POISON);

    // 功能：拒绝通过借用视图改变平台分配策略。
    // 输入/输出及副作用：policy 只用于接口兼容；报告不支持，不写 manager。
    // 失败/边界：任何 policy 均拒绝，策略由平台独占。
    extern virtual function void set_alloc_policy(host_mem_alloc_policy_e	policy);

    // 功能：查询所借 Host 的当前分配策略，仅供 API 元数据消费者。
    // 输入/输出及副作用：返回 manager 策略，不申请内存或改变请求上下文。
    // 失败/边界：未绑定时返回枚举零值；is_initialized 同时返回假，不宣称已有策略授权。
    extern virtual function host_mem_alloc_policy_e get_alloc_policy();

    // 功能：拒绝 responder 改写 Host 身份。
    // 输入/输出及副作用：id 不转发到 manager，报告不支持。
    // 失败/边界：包括重复同值在内的所有调用均拒绝；身份只由平台绑定。
    extern virtual function void set_host_id(int unsigned	id);

    // 功能：读取所属 RC 已借用的 Host manager 身份。
    // 输入/输出及副作用：返回 manager.get_host_id()，不更新路由。
    // 失败/边界：未绑定返回全一值作为无效 Host，不默认落到 RC0。
    extern virtual function int unsigned get_host_id();

    // 功能：判断借用 manager 是否已初始化，不赋予任何 Function 访问权限。
    // 输入/输出及副作用：返回 manager 的只读初始化标志。
    // 失败/边界：owner/manager 为空返回假；实际 DMA 仍须逐次验证上下文与 epoch。
    extern virtual function bit is_initialized();

    // 功能：检查当前请求 Function 是否拥有完整区间。
    // 输入/输出及副作用：base/size 不读 backing；仅经 guard_access 拒绝时锁存 request_failed。
    // 失败/边界：owner 为空或 size 超出 uint 时直接返回假且不锁存；未激活请求、旧 epoch、撤销或跨 Function 范围由 guard_access 拒绝。
    extern virtual function bit contains_range(bit [63:0]	base, bit [63:0]	size);

    // 功能：保守提供当前请求完整可访问区间判定，responder 不依赖宽松相交语义。
    // 输入/输出及副作用：base/size 转给 contains_range，不触碰 backing。
    // 失败/边界：只有整个区间有效才返回真，部分相交、无上下文或过宽 size 返回假。
    extern virtual function bit intersects_region(bit [63:0]	base, bit [63:0]	size);

    // 功能：拒绝 responder 为 Host 预留地址。
    // 输入/输出及副作用：base/size/owner/file/line 不转发，报告不支持并返回零。
    // 失败/边界：始终失败，不创建第二份 reservation authority。
    extern virtual function bit reserve_range(bit [63:0]	base, bit [63:0]	size,
        string	owner = "", string	file = "", int	line = 0);

    // 功能：拒绝 responder 申请新的 Host backing。
    // 输入/输出及副作用：size/align/file/line 不转发；返回 host_mem 无效地址全一值。
    // 失败/边界：所有请求均报告不支持，不修改 Function 分配账本。
    extern virtual function bit [63:0] alloc(int unsigned	size, int unsigned	align = 1,
        string	file = "", int	line = 0);

    // 功能：拒绝 responder 释放业务层拥有的内存。
    // 输入/输出及副作用：addr/file/line 不转发，仅报告不支持。
    // 失败/边界：任意 addr 都不触发 manager.free，资源生命周期仍由 RDMA driver 管理。
    extern virtual function void free(bit [63:0]	addr, string	file = "", int	line = 0);

    // 功能：在每个 responder 写片段前重新验证 Function authority，再写既有视图。
    // 输入/输出及副作用：addr/data 为实际字节；file/line 不承担授权，失败锁存 request_failed。
    // 失败/边界：无上下文、复位/撤销、manager 身份变化或区间失效时不访问 backing。
    extern virtual function void write_mem(bit [63:0]	addr, byte	data[], string	file = "", int	line = 0);

    // 功能：在每个 responder 读取片段前重新验证 Function authority，再读既有视图。
    // 输入/输出及副作用：addr/size 输入，data 先清空后返回字节；失败锁存 request_failed。
    // 失败/边界：复位/撤销、无上下文、manager 改绑或范围失效时 data 为空且不读 backing。
    extern virtual function void read_mem(bit [63:0]	addr, int unsigned	size, ref byte	data[],
        input string	file = "", input int	line = 0);

    // 功能：明确拒绝 responder 用任意双地址比较绕过当前请求范围。
    // 输入/输出及副作用：addr1/addr2/size/file/line 不访问 backing；mismatch_offset 清零，返回假。
    // 失败/边界：始终报告不支持，不把拒绝解释为比较相等。
    extern virtual function bit mem_compare(bit [63:0]	addr1, bit [63:0]	addr2,
        int unsigned	size, output int unsigned	mismatch_offset,
        input string	file = "", input int	line = 0);

    // 功能：结束无所有权适配器的泄漏检查；不检查或释放平台的分配。
    // 输入/输出及副作用：file/line 仅保持 API 签名，无状态变化。
    // 失败/边界：本对象从不分配，所以检查为显式空操作；平台 manager 仍承担实际 leak_check。
    extern virtual function void leak_check(string	file = "", int	line = 0);

  endclass

  // RC 拥有串行 request context，继承外部 responder；只有边界授权与 route 选择属于本层。
  class rdma_project_rc_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(rdma_project_rc_driver)

    protected dpu_pcie_bar_map			bar_map;
    protected dpu_device_snapshot		source;
    protected int unsigned			host_id;
    protected int unsigned			slot;
    protected pcie_tl_env_config		transport_cfg;
    protected intel_pcie_if_adapter		intel_adapter;
    protected longint unsigned			generation;
    protected longint unsigned			reset_epoch;
    protected bit				revoked;
    protected bit				revoked_functions[string];
    protected rdma_host_mem			views[string];
    protected rdma_project_dma_mem		guarded_mem;
    protected dpu_function_key_t		active_key;
    protected longint unsigned			active_generation;
    protected bit				busy;
    protected bit [15:0]			active_requester;
    protected uvm_sequencer #(pcie_tl_tlp)	bound_sequencer;
    host_mem_api				manager;
    rdma_host_mem				active_view;
    bit						request_failed;
    int unsigned				rejected_requests;
    int unsigned				rejected_sends;

    // 功能：构造项目 RC 及其永久 host_mem_api 适配器。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；guarded_mem 归本 RC 所有，其 owner 借用 this。
    // 失败/边界：构造不绑定 map/manager/epoch，bind_transport 成功前收发全部拒绝。
    extern function new(string	name = "rdma_project_rc_driver", uvm_component	parent = null);

    // 功能：检查固定 Intel 发送能力，确保授权检查到 enqueue 之间不存在 FC/shaper/delay 等待。
    // 输入/输出及副作用：只读配置、实际 driver 组件和 Intel 状态；why 输出具体拒绝原因。
    // 失败/边界：角色不符、有限信用、活动整形/延时、非 Intel/HARD_IP 或 reset/not running 均拒绝。
    extern function bit effective_ready(output string	why);

    // 功能：在平台初始复位完成后一次性绑定同源 map、Host manager 和 Function 视图。
    // 输入/输出及副作用：map/snapshot/cfg/host_manager/keys/function_views 全部借用；live_generation 非零。
    // 失败/边界：重复绑定、缺路由/slot/sequencer、同源/Host/视图不匹配或实际发送能力不符不发布绑定。
    extern function rdma_status bind_transport(dpu_pcie_bar_map	map, dpu_device_snapshot	snapshot,
        pcie_tl_env_config	cfg, int unsigned	host, int unsigned	rc_slot,
        host_mem_api	host_manager, dpu_function_key_t	keys[$],
        rdma_host_mem	function_views[$], longint unsigned	live_generation);

    // 功能：只读验证 BAR 所借 map/快照/Host 与当前 transport 完全一致并取得存活 generation。
    // 输入/输出及副作用：map/snapshot/key 输入；epoch 返回已捕获 generation；不启动 sequence。
    // 失败/边界：不同来源、未绑定 Function、撤销、复位或能力变化均拒绝。
    extern function bit authorize(dpu_pcie_bar_map	map, dpu_device_snapshot	snapshot,
        dpu_function_key_t	key, output longint unsigned	epoch);

    // 功能：判断某 Function 的既有 generation 是否仍可发送或接触 Host backing。
    // 输入/输出及副作用：key/epoch 为捕获身份；只读 revoke、Intel reset counter 与实际配置。
    // 失败/边界：零或不同 generation、不同 Host、缺视图、撤销、reset、manager 换绑或配置变动返回假。
    extern function bit live(dpu_function_key_t	key, longint unsigned	epoch);

    // 功能：在平台 FLR 前永久撤销指定 Function，阻止后续 MMIO、DMA 和 Completion。
    // 输入/输出及副作用：key 定位本 Host 已绑定视图；成功置撤销标志，无 backing 操作。
    // 失败/边界：未知 Function 返回假；重复撤销幂等成功，无恢复入口。
    extern function bit revoke_function(dpu_function_key_t	key);

    // 功能：在平台链路 teardown 前永久撤销整个 transport。
    // 输入/输出及副作用：置 revoked；当前请求后续适配器访问和 Completion 自动失败。
    // 失败/边界：重复调用幂等，不释放业务内存，不回滚已经发出的字节，也不支持 rearm。
    extern function void revoke();

    // 功能：验证 Memory wire 编码并计算全部使能字节的连续覆盖区间。
    // 输入/输出及副作用：request 输入；first/span 输出预检范围；why 解释拒绝，不访问 backing。
    // 失败/边界：不支持 kind/type/fmt、3DW 高地址、空 BE、payload 长度、地址回绕和跨 4KB 均拒绝。
    extern function bit memory_span(pcie_tl_mem_tlp	request, output bit [63:0]	first,
        output int unsigned	span, output string	why);

    // 功能：每次 responder 实际访问前检查 active context 与 Function 单次分配归属。
    // 输入/输出及副作用：address/size 输入；失败锁存 request_failed，成功不读取 backing。
    // 失败/边界：无串行请求、前次失败、generation/epoch 失效、视图替换或跨 allocation 均拒绝。
    extern function bit guard_access(bit [63:0]	address, int unsigned	size);

    // 功能：以 ingress Host+requester 建立完整预检上下文，再调用原 RC responder。
    // 输入/输出及副作用：req 输入；成功由 super 访问共享视图并分片应答；拒绝计数且不访问 backing。
    // 失败/边界：重入、未知 requester、编码非法、跨 Function 分配或旧 epoch 均在首次访问前拒绝。
    extern virtual task handle_request(pcie_tl_tlp	req);

    // 功能：发送前按同一 map 生成 Memory/Completion Intel route，并检查旧请求 context。
    // 输入/输出及副作用：tlp.cq_route 由冻结目录填写；成功沿用基类 tag/FC/Completion 生命周期。
    // 失败/边界：缺 map/policy、非法编码、撤销/reset 或失效 Completion 不调用 super，绝不落到 RC0。
    extern virtual task send_tlp(pcie_tl_tlp	tlp);

  endclass

  // map 类型只在可选包内可见；BAR subclass 不复制编码，只在现有 sequence 两端验证借用的 authority。
  class rdma_project_pcie_bar extends rdma_pcie_bar;
    `uvm_object_utils(rdma_project_pcie_bar)
    protected dpu_pcie_bar_map		map;
    protected dpu_bar_target_t		target;
    protected rdma_project_rc_driver	rc;
    protected longint unsigned		epoch;

    // 功能：创建尚未获准发送的项目 BAR，可在 connect 提前发布给 RDMA driver。
    // 输入/输出及副作用：name 传给现有 BAR；不创建 map/sequencer/硬件模型。
    // 失败/边界：初始复位后 bind_project 成功前，write64 拒绝且无 MMIO。
    extern function new(string	name = "rdma_project_pcie_bar");

    // 功能：把 BAR 绑定到已完成初始复位的一次性 RC transport 和同源 map target。
    // 输入/输出及副作用：registry/selected/driver 借用；成功调用现有 bind_instance 并保存当前 epoch。
    // 失败/边界：旧 target、缺 policy/sequencer、不同快照/Host/driver 或重复绑定均不发布。
    extern function rdma_status bind_project(dpu_pcie_bar_map	registry,
        dpu_bar_target_t	selected, rdma_project_rc_driver	driver);

    // 功能：完整预检 8B BAR 范围与存活 epoch，复用已有大端编码 sequence。
    // 输入/输出及副作用：offset/value 发给基类；成功仅确认 posted 发送，失败返回结构化状态。
    // 失败/边界：缺绑定、旧 epoch、跨 BAR/溢出、policy/sequencer 变化在发送前拒绝；发送期间撤销返回失败。
    extern virtual task write64(bit [63:0]	offset, bit [63:0]	value, output rdma_status	status);

  endclass

  // 功能：建立无 backing、无分配账本的 responder 内存适配器。
  // 输入/输出及副作用：name 传给基类；owner 由所属 RC 设置为非拥有引用。
  // 失败/边界：owner 尚未设置时所有访问拒绝，构造不创建 manager。
  function rdma_project_dma_mem::new(string	name = "rdma_project_dma_mem");
    super.new(name);
  endfunction

  // 功能：拒绝通过 responder 重新定义平台 Host 地址区域。
  // 输入/输出及副作用：base_addr/end_addr/m/granule/poison 不转发，只报告不支持。
  // 失败/边界：始终拒绝，不改变已有 manager 或分配。
  function void rdma_project_dma_mem::init_region(bit [63:0]	base_addr, bit [63:0]	end_addr,
      alloc_mode_e	m = MODE_BUDDY, int unsigned	granule = DEFAULT_MIN_GRANULE,
      byte	poison = DEFAULT_POISON);
    `uvm_error("RDMA_DMA_API", "responder cannot initialize a Host region")
  endfunction

  // 功能：拒绝通过借用视图改变平台分配策略。
  // 输入/输出及副作用：policy 只用于接口兼容；报告不支持，不写 manager。
  // 失败/边界：任何 policy 均拒绝，策略由平台独占。
  function void rdma_project_dma_mem::set_alloc_policy(host_mem_alloc_policy_e	policy);
    `uvm_error("RDMA_DMA_API", "responder cannot change allocation policy")
  endfunction

  // 功能：查询所借 Host 的当前分配策略，仅供 API 元数据消费者。
  // 输入/输出及副作用：返回 manager 策略，不申请内存或改变请求上下文。
  // 失败/边界：未绑定时返回枚举零值；is_initialized 同时返回假，不宣称已有策略授权。
  function host_mem_alloc_policy_e rdma_project_dma_mem::get_alloc_policy();
    if (owner == null || owner.manager == null)
      return host_mem_alloc_policy_e'(0);
    return owner.manager.get_alloc_policy();
  endfunction

  // 功能：拒绝 responder 改写 Host 身份。
  // 输入/输出及副作用：id 不转发到 manager，报告不支持。
  // 失败/边界：包括重复同值在内的所有调用均拒绝；身份只由平台绑定。
  function void rdma_project_dma_mem::set_host_id(int unsigned	id);
    `uvm_error("RDMA_DMA_API", "responder cannot change Host identity")
  endfunction

  // 功能：读取所属 RC 已借用的 Host manager 身份。
  // 输入/输出及副作用：返回 manager.get_host_id()，不更新路由。
  // 失败/边界：未绑定返回全一值作为无效 Host，不默认落到 RC0。
  function int unsigned rdma_project_dma_mem::get_host_id();
    if (owner == null || owner.manager == null)
      return '1;
    return owner.manager.get_host_id();
  endfunction

  // 功能：判断借用 manager 是否已初始化，不赋予任何 Function 访问权限。
  // 输入/输出及副作用：返回 manager 的只读初始化标志。
  // 失败/边界：owner/manager 为空返回假；实际 DMA 仍须逐次验证上下文与 epoch。
  function bit rdma_project_dma_mem::is_initialized();
    return owner != null && owner.manager != null && owner.manager.is_initialized();
  endfunction

  // 功能：检查当前请求 Function 是否拥有完整区间。
  // 输入/输出及副作用：base/size 不读 backing；仅经 guard_access 拒绝时锁存 request_failed。
  // 失败/边界：owner 为空或 size 超出 uint 时直接返回假且不锁存；未激活请求、旧 epoch、撤销或跨 Function 范围由 guard_access 拒绝。
  function bit rdma_project_dma_mem::contains_range(bit [63:0]	base, bit [63:0]	size);
    if (owner == null || size > 32'hffff_ffff)
      return 0;
    return owner.guard_access(base, int'(size));
  endfunction

  // 功能：保守提供当前请求完整可访问区间判定，responder 不依赖宽松相交语义。
  // 输入/输出及副作用：base/size 转给 contains_range，不触碰 backing。
  // 失败/边界：只有整个区间有效才返回真，部分相交、无上下文或过宽 size 返回假。
  function bit rdma_project_dma_mem::intersects_region(bit [63:0]	base, bit [63:0]	size);
    return contains_range(base, size);
  endfunction

  // 功能：拒绝 responder 为 Host 预留地址。
  // 输入/输出及副作用：base/size/owner/file/line 不转发，报告不支持并返回零。
  // 失败/边界：始终失败，不创建第二份 reservation authority。
  function bit rdma_project_dma_mem::reserve_range(bit [63:0]	base, bit [63:0]	size,
      string	owner = "", string	file = "", int	line = 0);
    `uvm_error("RDMA_DMA_API", "responder cannot reserve Host ranges")
    return 0;
  endfunction

  // 功能：拒绝 responder 申请新的 Host backing。
  // 输入/输出及副作用：size/align/file/line 不转发；返回 host_mem 无效地址全一值。
  // 失败/边界：所有请求均报告不支持，不修改 Function 分配账本。
  function bit [63:0] rdma_project_dma_mem::alloc(int unsigned	size, int unsigned	align = 1,
      string	file = "", int	line = 0);
    `uvm_error("RDMA_DMA_API", "responder cannot allocate Host memory")
    return '1;
  endfunction

  // 功能：拒绝 responder 释放业务层拥有的内存。
  // 输入/输出及副作用：addr/file/line 不转发，仅报告不支持。
  // 失败/边界：任意 addr 都不触发 manager.free，资源生命周期仍由 RDMA driver 管理。
  function void rdma_project_dma_mem::free(bit [63:0]	addr, string	file = "", int	line = 0);
    `uvm_error("RDMA_DMA_API", "responder cannot free Host memory")
  endfunction

  // 功能：在每个 responder 写片段前重新验证 Function authority，再写既有视图。
  // 输入/输出及副作用：addr/data 为实际字节；file/line 不承担授权，失败锁存 request_failed。
  // 失败/边界：无上下文、复位/撤销、manager 身份变化或区间失效时不访问 backing。
  function void rdma_project_dma_mem::write_mem(bit [63:0]	addr, byte	data[], string	file = "", int	line = 0);
    rdma_status	status;

    if (owner == null || !owner.guard_access(addr, data.size()))
      return;
    status = owner.active_view.write(addr, data);
    if (!status.ok())
      owner.request_failed = 1;
  endfunction

  // 功能：在每个 responder 读取片段前重新验证 Function authority，再读既有视图。
  // 输入/输出及副作用：addr/size 输入，data 先清空后返回字节；失败锁存 request_failed。
  // 失败/边界：复位/撤销、无上下文、manager 改绑或范围失效时 data 为空且不读 backing。
  function void rdma_project_dma_mem::read_mem(bit [63:0]	addr, int unsigned	size, ref byte	data[],
      input string	file = "", input int	line = 0);
    rdma_status	status;

    data = new[0];
    if (owner == null || !owner.guard_access(addr, size))
      return;
    status = owner.active_view.read(addr, size, data);
    if (!status.ok())
      owner.request_failed = 1;
  endfunction

  // 功能：明确拒绝 responder 用任意双地址比较绕过当前请求范围。
  // 输入/输出及副作用：addr1/addr2/size/file/line 不访问 backing；mismatch_offset 清零，返回假。
  // 失败/边界：始终报告不支持，不把拒绝解释为比较相等。
  function bit rdma_project_dma_mem::mem_compare(bit [63:0]	addr1, bit [63:0]	addr2,
      int unsigned	size, output int unsigned	mismatch_offset,
      input string	file = "", input int	line = 0);
    mismatch_offset = 0;
    `uvm_error("RDMA_DMA_API", "responder does not provide memory comparison")
    return 0;
  endfunction

  // 功能：结束无所有权适配器的泄漏检查；不检查或释放平台的分配。
  // 输入/输出及副作用：file/line 仅保持 API 签名，无状态变化。
  // 失败/边界：本对象从不分配，所以检查为显式空操作；平台 manager 仍承担实际 leak_check。
  function void rdma_project_dma_mem::leak_check(string	file = "", int	line = 0);
  endfunction

  // 功能：构造项目 RC 及其永久 host_mem_api 适配器。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；guarded_mem 归本 RC 所有，其 owner 借用 this。
  // 失败/边界：构造不绑定 map/manager/epoch，bind_transport 成功前收发全部拒绝。
  function rdma_project_rc_driver::new(string	name = "rdma_project_rc_driver", uvm_component	parent = null);
    super.new(name, parent);
    guarded_mem = new("guarded_mem");
    guarded_mem.owner = this;
  endfunction

  // 功能：检查固定 Intel 发送能力，确保授权检查到 enqueue 之间不存在 FC/shaper/delay 等待。
  // 输入/输出及副作用：只读配置、实际 driver 组件和 Intel 状态；why 输出具体拒绝原因。
  // 失败/边界：角色不符、有限信用、活动整形/延时、非 Intel/HARD_IP 或 reset/not running 均拒绝。
  function bit rdma_project_rc_driver::effective_ready(output string	why);
    why = "Intel transport requires RC only, infinite credit and no shaper/link delay";
    if (transport_cfg == null || !transport_cfg.rc_agent_enable ||
        transport_cfg.ep_agent_enable || transport_cfg.ep_auto_response ||
        transport_cfg.if_mode != SV_IF_MODE || !transport_cfg.infinite_credit ||
        transport_cfg.shaper_enable || transport_cfg.link_delay_enable)
      return 0;
    if (fc_mgr == null || !fc_mgr.infinite_credit ||
        (bw_shaper != null && bw_shaper.shaper_enable) ||
        (tx_delay_model != null && tx_delay_model.enable))
      return 0;
    why = "Intel adapter is not running HARD_IP or is in reset";
    if (intel_adapter == null || adapter != intel_adapter || !intel_adapter.running ||
        intel_adapter.in_reset || intel_adapter.cfg == null ||
        intel_adapter.cfg.side != INTEL_PCIE_HARD_IP)
      return 0;
    why = "";
    return 1;
  endfunction

  // 功能：在平台初始复位完成后一次性绑定同源 map、Host manager 和 Function 视图。
  // 输入/输出及副作用：map/snapshot/cfg/host_manager/keys/function_views 全部借用；live_generation 非零。
  // 失败/边界：重复绑定、缺路由/slot/sequencer、同源/Host/视图不匹配或实际发送能力不符不发布绑定。
  function rdma_status rdma_project_rc_driver::bind_transport(dpu_pcie_bar_map	map, dpu_device_snapshot	snapshot,
      pcie_tl_env_config	cfg, int unsigned	host, int unsigned	rc_slot,
      host_mem_api	host_manager, dpu_function_key_t	keys[$],
      rdma_host_mem	function_views[$], longint unsigned	live_generation);
    int unsigned			mapped_slot;
    string				why;
    dpu_bar_pair_lease_t		lease;
    dpu_bar_target_t			target;
    uvm_sequencer #(pcie_tl_tlp)	sequencer;
    intel_pcie_if_adapter		candidate;
    dpu_function_key_t			all_keys[$];

    if (generation != 0 || revoked || map == null || snapshot == null ||
        cfg == null || host_manager == null || live_generation == 0 ||
        keys.size() == 0 || keys.size() != function_views.size())
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transport binding incomplete or already installed");
    if (!map.references_device_snapshot(snapshot) ||
        !map.get_slot(host, 0, mapped_slot, why) || mapped_slot != rc_slot ||
        host_manager.get_host_id() != host || !host_manager.is_initialized() ||
        !$cast(candidate, adapter))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "transport source/Host/slot/Intel adapter mismatch");
    foreach (keys[i]) begin
      if (keys[i].host_id != host || function_views[i] == null ||
          function_views[i].mem != host_manager)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "Function view does not borrow bound Host manager");
      for (int	j = 0; j < i; j++)
        if (dpu_same_function_key(keys[i], keys[j]) || function_views[i] == function_views[j])
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "duplicate Function key or shared Function ledger");
      if (!snapshot.get_bar(keys[i], DPU_BAR_DEVICE_MEMORY, lease, why) ||
          !map.resolve_function(keys[i], lease.even_bar_id, target, why) ||
          !map.get_sequencer(target, sequencer, why) ||
          seq_item_port.get_if(0) != sequencer.seq_item_export.get_if(0))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
    end
    // freeze 仅保证 Host/segment；发布前补齐该 Host 全部 Function 的显式 policy 和实际 sequencer。
    snapshot.list_functions(all_keys);
    foreach (all_keys[i]) begin
      if (all_keys[i].host_id != host)
        continue;
      if (!snapshot.get_bar(all_keys[i], DPU_BAR_DEVICE_MEMORY, lease, why) ||
          !map.resolve_function(all_keys[i], lease.even_bar_id, target, why) ||
          !map.get_sequencer(target, sequencer, why) ||
          seq_item_port.get_if(0) != sequencer.seq_item_export.get_if(0))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "Host Function policy/sequencer is incomplete");
    end
    // 暂存仅用于纯能力校验，失败清空；在成功前 mem 不得发布 backing 或新权限。
    transport_cfg = cfg;
    intel_adapter = candidate;
    if (!effective_ready(why)) begin
      transport_cfg = null;
      intel_adapter = null;
      return rdma_status::make(RDMA_SC_INVALID_STATE, why);
    end
    bar_map = map;
    source = snapshot;
    host_id = host;
    slot = rc_slot;
    manager = host_manager;
    bound_sequencer = sequencer;
    generation = live_generation;
    reset_epoch = intel_adapter.reset_epochs;
    foreach (keys[i])
      views[dpu_function_key_name(keys[i])] = function_views[i];
    mem = guarded_mem;
    use_unified_mem = 1;
    auto_response_enable = 1;
    return rdma_status::success();
  endfunction

  // 功能：只读验证 BAR 所借 map/快照/Host 与当前 transport 完全一致并取得存活 generation。
  // 输入/输出及副作用：map/snapshot/key 输入；epoch 返回已捕获 generation；不启动 sequence。
  // 失败/边界：不同来源、未绑定 Function、撤销、复位或能力变化均拒绝。
  function bit rdma_project_rc_driver::authorize(dpu_pcie_bar_map	map, dpu_device_snapshot	snapshot,
      dpu_function_key_t	key, output longint unsigned	epoch);
    epoch = generation;
    return map == bar_map && snapshot == source && live(key, generation);
  endfunction

  // 功能：判断某 Function 的既有 generation 是否仍可发送或接触 Host backing。
  // 输入/输出及副作用：key/epoch 为捕获身份；只读 revoke、Intel reset counter 与实际配置。
  // 失败/边界：零或不同 generation、不同 Host、缺视图、撤销、reset、manager 换绑或配置变动返回假。
  function bit rdma_project_rc_driver::live(dpu_function_key_t	key, longint unsigned	epoch);
    string		why;
    string		name;
    int unsigned	mapped_slot;

    name = dpu_function_key_name(key);
    if (generation == 0 || epoch != generation || revoked || key.host_id != host_id ||
        revoked_functions.exists(name) || !views.exists(name) || manager == null)
      return 0;
    if (!effective_ready(why) || intel_adapter.reset_epochs != reset_epoch ||
        mem != guarded_mem || !use_unified_mem || !auto_response_enable ||
        views[name].mem != manager || manager.get_host_id() != host_id ||
        !bar_map.get_slot(host_id, 0, mapped_slot, why) || mapped_slot != slot ||
        !bar_map.rc_sequencers.exists(slot) || bar_map.rc_sequencers[slot] != bound_sequencer ||
        seq_item_port.get_if(0) != bound_sequencer.seq_item_export.get_if(0))
      return 0;
    return 1;
  endfunction

  // 功能：在平台 FLR 前永久撤销指定 Function，阻止后续 MMIO、DMA 和 Completion。
  // 输入/输出及副作用：key 定位本 Host 已绑定视图；成功置撤销标志，无 backing 操作。
  // 失败/边界：未知 Function 返回假；重复撤销幂等成功，无恢复入口。
  function bit rdma_project_rc_driver::revoke_function(dpu_function_key_t	key);
    string	name;

    name = dpu_function_key_name(key);
    if (!views.exists(name) || key.host_id != host_id)
      return 0;
    revoked_functions[name] = 1;
    return 1;
  endfunction

  // 功能：在平台链路 teardown 前永久撤销整个 transport。
  // 输入/输出及副作用：置 revoked；当前请求后续适配器访问和 Completion 自动失败。
  // 失败/边界：重复调用幂等，不释放业务内存，不回滚已经发出的字节，也不支持 rearm。
  function void rdma_project_rc_driver::revoke();
    revoked = 1;
  endfunction

  // 功能：验证 Memory wire 编码并计算全部使能字节的连续覆盖区间。
  // 输入/输出及副作用：request 输入；first/span 输出预检范围；why 解释拒绝，不访问 backing。
  // 失败/边界：不支持 kind/type/fmt、3DW 高地址、空 BE、payload 长度、地址回绕和跨 4KB 均拒绝。
  function bit rdma_project_rc_driver::memory_span(pcie_tl_mem_tlp	request, output bit [63:0]	first,
      output int unsigned	span, output string	why);
    int unsigned	bytes;
    int			first_lane;
    int			last_lane;
    bit [63:0]		wire_address;
    bit [64:0]		last_address;

    first = 0;
    span = 0;
    why = "malformed or unsupported Memory request";
    if (request == null || !(request.kind inside {TLP_MEM_RD, TLP_MEM_WR}) ||
        request.type_f != TLP_TYPE_MEM_RD)
      return 0;
    if ((request.kind == TLP_MEM_WR && !(request.fmt inside {FMT_3DW_WITH_DATA, FMT_4DW_WITH_DATA})) ||
        (request.kind == TLP_MEM_RD && !(request.fmt inside {FMT_3DW_NO_DATA, FMT_4DW_NO_DATA})) ||
        (!request.is_4dw() && request.addr[63:32] != 0))
      return 0;
    bytes = pcie_tl_mem_dw_count(request) * 4;
    wire_address = pcie_tl_mem_wire_addr(request);
    last_address = {1'b0, wire_address} + bytes - 1;
    if (last_address[64] || wire_address[63:12] != last_address[63:12] ||
        request.first_be == 0 || (bytes == 4 && request.last_be != 0) ||
        (bytes > 4 && request.last_be == 0) ||
        (request.kind == TLP_MEM_WR && request.payload.size() != bytes) ||
        (request.kind == TLP_MEM_RD && request.payload.size() != 0))
      return 0;
    first_lane = -1;
    last_lane = -1;
    for (int	i = 0; i < bytes; i++) begin
      if (pcie_tl_mem_lane_enabled(request, i)) begin
        if (first_lane < 0)
          first_lane = i;
        last_lane = i;
      end
    end
    if (first_lane < 0)
      return 0;
    first = wire_address + first_lane;
    span = last_lane - first_lane + 1;
    why = "";
    return 1;
  endfunction

  // 功能：每次 responder 实际访问前检查 active context 与 Function 单次分配归属。
  // 输入/输出及副作用：address/size 输入；失败锁存 request_failed，成功不读取 backing。
  // 失败/边界：无串行请求、前次失败、generation/epoch 失效、视图替换或跨 allocation 均拒绝。
  function bit rdma_project_rc_driver::guard_access(bit [63:0]	address, int unsigned	size);
    rdma_status	status;
    string	name;

    name = dpu_function_key_name(active_key);
    if (!busy || request_failed || !live(active_key, active_generation) ||
        active_view == null || !views.exists(name) || views[name] != active_view) begin
      request_failed = 1;
      return 0;
    end
    status = active_view.validate_range(address, size);
    if (!status.ok()) begin
      request_failed = 1;
      return 0;
    end
    return 1;
  endfunction

  // 功能：以 ingress Host+requester 建立完整预检上下文，再调用原 RC responder。
  // 输入/输出及副作用：req 输入；成功由 super 访问共享视图并分片应答；拒绝计数且不访问 backing。
  // 失败/边界：重入、未知 requester、编码非法、跨 Function 分配或旧 epoch 均在首次访问前拒绝。
  task rdma_project_rc_driver::handle_request(pcie_tl_tlp	req);
    pcie_tl_mem_tlp		request;
    dpu_function_key_t		key;
    dpu_pcie_function_id_t	id;
    bit [63:0]			first;
    int unsigned		span;
    string			why;

    if (busy || bar_map == null || req == null || !$cast(request, req)) begin
      rejected_requests++;
      return;
    end
    if (!bar_map.resolve_requester(host_id, req.requester_id, key, id, why) ||
        !live(key, generation) || !memory_span(request, first, span, why)) begin
      rejected_requests++;
      return;
    end
    busy = 1;
    request_failed = 0;
    active_key = key;
    active_requester = req.requester_id;
    active_generation = generation;
    active_view = views[dpu_function_key_name(key)];
    if (guard_access(first, span))
      super.handle_request(req);
    if (request_failed)
      rejected_requests++;
    active_view = null;
    busy = 0;
  endtask

  // 功能：发送前按同一 map 生成 Memory/Completion Intel route，并检查旧请求 context。
  // 输入/输出及副作用：tlp.cq_route 由冻结目录填写；成功沿用基类 tag/FC/Completion 生命周期。
  // 失败/边界：缺 map/policy、非法编码、撤销/reset 或失效 Completion 不调用 super，绝不落到 RC0。
  task rdma_project_rc_driver::send_tlp(pcie_tl_tlp	tlp);
    pcie_tl_mem_tlp		request;
    pcie_tl_cq_route_t		route;
    dpu_bar_address_match_t	match;
    dpu_pcie_domain_key_t	domain;
    bit [63:0]			first;
    int unsigned		span;
    string			why;
    bit				accepted;

    accepted = 0;
    if (tlp != null && bar_map != null && effective_ready(why)) begin
      if (tlp.kind inside {TLP_MEM_RD, TLP_MEM_WR}) begin
        domain = '{host_id: host_id, segment_id: 0};
        if ($cast(request, tlp) && memory_span(request, first, span, why) &&
            source.resolve_bar_address(domain, first, match, why) &&
            live(match.function_key, generation))
          accepted = bar_map.route_memory(host_id, 0, first, span, route, why);
      end
      else if (tlp.kind inside {TLP_CPL, TLP_CPLD}) begin
        if (busy && !request_failed && tlp.requester_id == active_requester &&
            live(active_key, active_generation))
          accepted = bar_map.route_completion(host_id, 0, tlp.requester_id, route, why);
      end
    end
    if (!accepted) begin
      rejected_sends++;
      if (busy)
        request_failed = 1;
      return;
    end
    tlp.cq_route = route;
    super.send_tlp(tlp);
    // Intel send 等待物理发送完成；等待期间的复位/撤销不回滚已发段，但阻止下一次 backing 读取/应答。
    if (busy && !live(active_key, active_generation))
      request_failed = 1;
  endtask

  // 功能：创建尚未获准发送的项目 BAR，可在 connect 提前发布给 RDMA driver。
  // 输入/输出及副作用：name 传给现有 BAR；不创建 map/sequencer/硬件模型。
  // 失败/边界：初始复位后 bind_project 成功前，write64 拒绝且无 MMIO。
  function rdma_project_pcie_bar::new(string	name = "rdma_project_pcie_bar");
    super.new(name);
  endfunction

  // 功能：把 BAR 绑定到已完成初始复位的一次性 RC transport 和同源 map target。
  // 输入/输出及副作用：registry/selected/driver 借用；成功调用现有 bind_instance 并保存当前 epoch。
  // 失败/边界：旧 target、缺 policy/sequencer、不同快照/Host/driver 或重复绑定均不发布。
  function rdma_status rdma_project_pcie_bar::bind_project(dpu_pcie_bar_map	registry,
      dpu_bar_target_t	selected, rdma_project_rc_driver	driver);
    uvm_sequencer #(pcie_tl_tlp)	sequencer;
    longint unsigned			live_epoch;
    bit [63:0]				address;
    string				why;
    rdma_status				status;

    if (map != null || registry == null || driver == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "project BAR binding incomplete or repeated");
    if (!registry.references_device_snapshot(selected.snapshot) ||
        !registry.check_range(selected, 0, 8, address, why) ||
        !registry.get_sequencer(selected, sequencer, why) ||
        !driver.authorize(registry, selected.snapshot, selected.function_key, live_epoch))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "project BAR route/source/epoch is invalid");
    status = bind_instance(selected.snapshot, selected.function_key, selected.bar_lease, sequencer);
    if (!status.ok())
      return status;
    map = registry;
    target = selected;
    rc = driver;
    epoch = live_epoch;
    return rdma_status::success();
  endfunction

  // 功能：完整预检 8B BAR 范围与存活 epoch，复用已有大端编码 sequence。
  // 输入/输出及副作用：offset/value 发给基类；成功仅确认 posted 发送，失败返回结构化状态。
  // 失败/边界：缺绑定、旧 epoch、跨 BAR/溢出、policy/sequencer 变化在发送前拒绝；发送期间撤销返回失败。
  task rdma_project_pcie_bar::write64(bit [63:0]	offset, bit [63:0]	value, output rdma_status	status);
    uvm_sequencer #(pcie_tl_tlp)	sequencer;
    bit [63:0]				address;
    string				why;
    int unsigned			rejected_before;

    if (map == null || rc == null || !rc.live(target.function_key, epoch)) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "project BAR transport is not live");
      return;
    end
    if (!map.check_range(target, offset, 8, address, why) ||
        !map.get_sequencer(target, sequencer, why) || sequencer != bar_sequencer) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "project BAR range or sequencer is invalid");
      return;
    end
    rejected_before = rc.rejected_sends;
    super.write64(offset, value, status);
    if (!rc.live(target.function_key, epoch) || rc.rejected_sends != rejected_before)
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "project BAR send rejected or epoch revoked during send");
  endtask
endpackage
