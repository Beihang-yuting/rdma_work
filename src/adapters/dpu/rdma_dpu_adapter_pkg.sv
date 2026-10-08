// 目录：外部适配器实现层 adapters/dpu/rdma_dpu_adapter_pkg.sv。
// 层：外部适配器。
// 职责：dpu_common 是全局 Function 的唯一控制方。rdma_dpu_system 按快照为每个 Function 建立设备、
//   主机内存域、BAR、驱动并 probe，并按快照的 PF→VF/Host 关系给出 FLR、PF FLR、Host 与整设备复位
//   范围；下层把 dpu_common 的逻辑设备配置接入 RDMA 驱动/设备模型：按 Host/PF/VF 声明生成
//   dpu_device_cfg（BAR 请求取 dut_caps.bar_profiles），经 dpu_device_resolver 解析并冻结快照；
//   把快照中每个 Function 投影为 host_id、global Function ID（驱动 QPC/PD 的 VF_ID）、BDF、BAR，
//   驱动的 MMIO 写按 BAR0 基址 + 偏移形成绝对地址，由快照 resolve_bar_address 解码到所属
//   Function 的设备；MAILBOX/MSI-X 控制面同样只接受快照解码出的 Function，并以独立 reset epoch
//   隔离 FLR 前后的寄存器状态、pending 位与中断事件。
// 依赖：dpu_common（dpu_resource_pkg）、rdma_types/model、rdma_host_mem_pkg、rdma_dev、rdma_drv。
// 所有权：快照与 cfg 由调用方持有；Function 投影为值快照；路由器只借用设备引用。
// 生命周期：测试建立拓扑时创建，仿真期间常驻。
package rdma_dpu_adapter_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import dpu_resource_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_host_mem_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_drv_pkg::*;

  // MAILBOX 是本项目内的显式适配契约：payload/command 形成一次发布，status 暴露发布、pending、
  // delivered、failed、序号与 reset epoch。ACK 寄存器读出当前发布的 64 位 token，只有在投递
  // 完成后回写完全相同的 token 才会消费发布；因此旧发布或 FLR 前的延迟 ACK 不能命中新发布。
  // 每个寄存器宽 64 位。
  localparam bit [63:0] RDMA_DPU_MAILBOX_PAYLOAD_OFFSET = 64'h0000;
  localparam bit [63:0] RDMA_DPU_MAILBOX_COMMAND_OFFSET = 64'h0008;
  localparam bit [63:0] RDMA_DPU_MAILBOX_STATUS_OFFSET  = 64'h0010;
  localparam bit [63:0] RDMA_DPU_MAILBOX_ACK_OFFSET     = 64'h0018;

  // dpu_device_snapshot 当前不导出 mailbox 的 Function-local→global MSI-X 切片。适配器因此只
  // 建模现有 MAILBOX 寄存器实际触发的 local vector 0，不从 DUT 全局 vector 池推导每 Function 容量。
  localparam int unsigned RDMA_DPU_MODELED_MAILBOX_VECTOR_COUNT = 1;
  localparam int unsigned RDMA_DPU_MAILBOX_VECTOR_INDEX = 0;

  // MSI-X BAR 按标准 16B table entry 的前两组 64 位访问建模：+0 为 message address，+8 的
  // [31:0] 为 message data、[32] 为 mask；读取时 [33] 额外暴露 PBA pending，写入该位会被拒绝。
  localparam int unsigned RDMA_DPU_MSIX_ENTRY_BYTES = 16;
  localparam bit [63:0] RDMA_DPU_MSIX_ADDRESS_OFFSET = 64'h0;
  localparam bit [63:0] RDMA_DPU_MSIX_DATA_CTRL_OFFSET = 64'h8;

  typedef struct {
    bit [63:0] message_address;
    bit [31:0] message_data;
    bit masked;
    bit pending;
    bit [63:0] pending_cause;
  } rdma_dpu_msix_entry_t;

  // 一个 Function 的冻结投影（只读值）。
  class rdma_dpu_function extends uvm_object;
    `uvm_object_utils(rdma_dpu_function)

    dpu_function_key_t key;
    dpu_pcie_function_id_t pcie_id;
    int unsigned global_id;
    dpu_bar_pair_lease_t bar0;
    dpu_bar_pair_lease_t mailbox;
    dpu_bar_pair_lease_t msix;
    dpu_pcie_function_id_t parent_pcie_id;
    // 快照的 DUT 能力。
    dpu_dut_caps caps;

    // 功能：构造尚未由 dpu_common snapshot 填充的 Function 投影，身份、BAR、父 PF 与 global_id 清零。
    // 输入/输出及副作用：name 仅作为 UVM 对象名；caps 初始化为 null，调用方拥有后续 project 结果。
    // 失败/边界：project 成功前零值身份/BAR 不具备路由权限，不能登记到 router 或配置中断控制器。
    function new(string name = "rdma_dpu_function");
      super.new(name);
      key = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
      pcie_id = '{default:'0};
      global_id = 0;
      bar0 = '{role: DPU_BAR_DEVICE_MEMORY, even_bar_id: 0, base: '0, size: '0};
      mailbox = '{role: DPU_BAR_MAILBOX, even_bar_id: 0, base: '0, size: '0};
      msix = '{role: DPU_BAR_MSIX, even_bar_id: 0, base: '0, size: '0};
      parent_pcie_id = '{default:'0};
      caps = null;
    endfunction
  endclass

  // 一次已投递的 MSI-X 事件。身份、BDF 与 epoch 都是投递时的值快照，消费者不能借事件反向修改
  // dpu_common 快照或 Function 控制器。
  class rdma_dpu_interrupt_event extends uvm_object;
    `uvm_object_utils(rdma_dpu_interrupt_event)

    dpu_function_key_t function_key;
    dpu_pcie_function_id_t pcie_id;
    int unsigned vector_index;
    bit [63:0] message_address;
    bit [31:0] message_data;
    bit [63:0] cause;
    rdma_reset_epoch_t reset_epoch;

    // 功能：构造一个尚未绑定 Function、vector 或消息内容的 MSI-X 事件快照。
    // 输入/输出及副作用：name 仅作为 UVM 对象名；数值字段清零，构造过程不登记到任何控制器。
    // 失败/边界：事件只有由 rdma_dpu_interrupt_ctrl 投递后才具备有效身份，空事件不得当作中断使用。
    function new(string name = "rdma_dpu_interrupt_event");
      super.new(name);
      function_key = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
      pcie_id = '{default:'0};
      vector_index = 0;
      message_address = '0;
      message_data = '0;
      cause = '0;
      reset_epoch = '0;
    endfunction
  endclass

  // dpu_device_cfg 的构造与解析。
  class rdma_dpu_topology extends uvm_object;
    `uvm_object_utils(rdma_dpu_topology)

    localparam bit [63:0] MMIO_WINDOW_BYTES = 64'h1_0000_0000;

    // 功能：构造无实例状态的 dpu_device_cfg 拓扑辅助对象，后续静态方法只操作调用方传入配置。
    // 输入/输出及副作用：name 仅作为 UVM 对象名；不持有 cfg、snapshot 或 BAR 分配结果。
    // 失败/边界：构造本身不校验配置；null/冲突等约束由 add/resolve 调用边界处理。
    function new(string name = "rdma_dpu_topology");
      super.new(name);
    endfunction

    // 功能：声明一个 Host 及其 PCIe domain（segment 为负时取 host_id，BDF 0x0010..0x00ff，MMIO 窗口
    //   [4GiB*(host+1), +4GiB) 允许 DEVICE_MEMORY/MAILBOX/MSI-X，BAR 随机放置）。
    // 输入/输出及副作用：追加 cfg.hosts；该 Host 的 Function 用同一 segment。
    // 失败/边界：无（合法性由 resolver 校验）。
    static function void add_host(dpu_device_cfg cfg, int unsigned host_id,
                                  int segment_id = -1);
      dpu_host_cfg host;
      dpu_pcie_domain_cfg domain;
      dpu_mmio_window_cfg window;
      dpu_bdf_range_t range;

      host = dpu_host_cfg::type_id::create($sformatf("host%0d", host_id));
      host.host_id = host_id;
      domain = dpu_pcie_domain_cfg::type_id::create($sformatf("domain%0d", host_id));
      domain.key.host_id = host_id;
      domain.key.segment_id = segment_id < 0 ? host_id : segment_id;
      range.first_bdf = 16'h0010;
      range.last_bdf = 16'h00ff;
      domain.bdf_ranges.push_back(range);
      window = dpu_mmio_window_cfg::type_id::create($sformatf("window%0d", host_id));
      window.base = MMIO_WINDOW_BYTES * (host_id + 1);
      window.limit = window.base + MMIO_WINDOW_BYTES;
      window.allowed_roles.push_back(DPU_BAR_DEVICE_MEMORY);
      window.allowed_roles.push_back(DPU_BAR_MAILBOX);
      window.allowed_roles.push_back(DPU_BAR_MSIX);
      domain.mmio_windows.push_back(window);
      // BAR 基址由 dpu_common resolver 在窗口内随机放置（满足对齐/同域不重叠），随快照冻结。
      domain.bar_placement_policy = DPU_BAR_PLACEMENT_RANDOM;
      host.pcie_domains.push_back(domain);
      cfg.hosts.push_back(host);
    endfunction

    // 功能：声明一个 PF/VF（BDF 与 BAR 自动分配；BAR 请求按 dut_caps.bar_profiles 中该类型的
    //   全部角色），并声明 RDMA 服务。第一个声明的 Function 作为 AF 请求者。
    // 输入/输出及副作用：追加 cfg.functions，可能设置 cfg.af_request。
    // 失败/边界：无（合法性由 resolver 校验）。
    static function void add_function(dpu_device_cfg cfg, int unsigned host_id,
                                      int unsigned pf_id, dpu_function_kind_e kind,
                                      int unsigned vf_id);
      dpu_function_cfg fcfg;
      dpu_bar_request bar;
      dpu_service_decl service;

      fcfg = dpu_function_cfg::type_id::create($sformatf("fn_h%0d_pf%0d_vf%0d", host_id, pf_id,
                                                         vf_id));
      fcfg.key.host_id = host_id;
      fcfg.key.pf_id = pf_id;
      fcfg.key.kind = kind;
      fcfg.key.vf_id = vf_id;
      fcfg.domain_key.host_id = host_id;
      fcfg.domain_key.segment_id = host_segment(cfg, host_id);
      fcfg.bdf_mode = DPU_ALLOC_AUTO;
      foreach (cfg.dut_caps.bar_profiles[i]) begin
        if (cfg.dut_caps.bar_profiles[i].kind != kind)
          continue;
        bar = dpu_bar_request::type_id::create("bar");
        bar.role = cfg.dut_caps.bar_profiles[i].role;
        bar.even_bar_id = cfg.dut_caps.bar_profiles[i].even_bar_id;
        bar.size = cfg.dut_caps.bar_profiles[i].size;
        bar.alignment = cfg.dut_caps.bar_profiles[i].alignment;
        bar.placement = DPU_ALLOC_AUTO;
        fcfg.bars.push_back(bar);
      end
      service = dpu_service_decl::type_id::create("rdma_service");
      service.service_kind = DPU_SERVICE_RDMA;
      service.service_instance_id = 0;
      fcfg.services.push_back(service);
      if (cfg.functions.size() == 0) begin
        cfg.af_request.mode = DPU_AF_SELECTED;
        cfg.af_request.requester = fcfg.key;
      end
      cfg.functions.push_back(fcfg);
    endfunction

    // 功能：查找 cfg 中 host_id 的首个 PCIe domain segment，供后续 Function domain_key 保持一致。
    // 输入/输出及副作用：只读 cfg.hosts，返回匹配 domain 的 segment_id，不修改 Host 或 domain 队列。
    // 失败/边界：Host 不存在或未声明任何 PCIe domain 时以 host_id 作为确定性 fallback。
    static function int unsigned host_segment(dpu_device_cfg cfg, int unsigned host_id);
      foreach (cfg.hosts[i])
        if (cfg.hosts[i].host_id == host_id && cfg.hosts[i].pcie_domains.size() != 0)
          return cfg.hosts[i].pcie_domains[0].key.segment_id;
      return host_id;
    endfunction

    // 功能：解析并冻结 cfg，按快照的 Function 顺序投影每个 Function（PCIe ID、global ID、三个
    //   BAR、VF 的父 PF PCIe ID）。
    // 输入/输出及副作用：snapshot/funcs 输出。
    // 失败/边界：解析失败或快照缺项返回 INVALID_ARGUMENT/INVALID_STATE（带 dpu_common 原因）。
    static function rdma_status resolve(dpu_device_cfg cfg, output dpu_device_snapshot snapshot,
                                        output rdma_dpu_function funcs[$]);
      dpu_device_resolver resolver;
      dpu_function_key_t keys[$];
      rdma_dpu_function f;
      string why;

      funcs.delete();
      resolver = dpu_device_resolver::type_id::create("rdma_dpu_resolver");
      if (!resolver.resolve(cfg, snapshot, why))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, {"dpu_common resolve: ", why});
      snapshot.list_functions(keys);
      foreach (keys[i]) begin
        f = rdma_dpu_function::type_id::create(dpu_function_key_name(keys[i]));
        f.key = keys[i];
        if (!project(snapshot, f, why))
          return rdma_status::make(RDMA_SC_INVALID_STATE, {"dpu_common snapshot: ", why});
        funcs.push_back(f);
      end
      return rdma_status::success();
    endfunction

    // 功能：从快照读取一个 Function 的 DUT 能力、PCIe ID、global ID、三个 BAR 与（VF）父 PF PCIe ID。
    // 输入/输出及副作用：写 f；why 输出失败原因。
    // 失败/边界：任一查询失败返回 0。
    static function bit project(dpu_device_snapshot snapshot, rdma_dpu_function f,
                                output string why);
      dpu_function_key_t parent;

      why = "";
      f.caps = snapshot.snapshot_dut_caps();
      if (f.caps == null) begin
        why = "snapshot DUT capabilities are unavailable";
        return 0;
      end
      if (!snapshot.get_pcie_id(f.key, f.pcie_id, why))
        return 0;
      if (!snapshot.get_global_function_id(f.key, f.global_id, why))
        return 0;
      if (!snapshot.get_bar(f.key, DPU_BAR_DEVICE_MEMORY, f.bar0, why))
        return 0;
      if (!snapshot.get_bar(f.key, DPU_BAR_MAILBOX, f.mailbox, why))
        return 0;
      if (!snapshot.get_bar(f.key, DPU_BAR_MSIX, f.msix, why))
        return 0;
      if (f.key.kind != DPU_FUNCTION_VF)
        return 1;
      parent = f.key;
      parent.kind = DPU_FUNCTION_PF;
      parent.vf_id = 0;
      return snapshot.get_pcie_id(parent, f.parent_pcie_id, why);
    endfunction
  endclass

  // 每个 Function 独占一个控制器。控制器在 configure 时深拷贝 Function key、PCIe ID、global ID、
  // BAR lease 与 DUT caps，之后不再借用可变 rdma_dpu_function 投影；它拥有寄存器、pending 位和
  // 事件队列，router 在 attach 边界把这份冻结副本与 dpu_common snapshot 重新逐项核对。
  class rdma_dpu_interrupt_ctrl extends uvm_object;
    `uvm_object_utils(rdma_dpu_interrupt_ctrl)

    protected rdma_dpu_function frozen_func;
    rdma_reset_epoch_t reset_epoch;
    rdma_dpu_msix_entry_t vectors[];
    rdma_dpu_interrupt_event delivered_events[$];
    bit [63:0] mailbox_payload;
    bit [63:0] mailbox_command;
    int unsigned mailbox_sequence;
    protected bit [63:0] mailbox_generation;
    protected bit [63:0] mailbox_publication_token;
    protected bit mailbox_generation_exhausted;
    bit mailbox_published;
    bit mailbox_delivered;
    bit mailbox_failed;
    int unsigned delivered_count;
    int unsigned coalesced_count;
    int unsigned rejected_count;

    // 功能：构造未连接的 Function 中断控制器，所有计数和 MAILBOX 状态从零开始。
    // 输入/输出及副作用：name 仅作为 UVM 对象名；frozen_func 保持 null，vectors 与事件队列为空。
    // 失败/边界：configure 成功前寄存器访问、raise_interrupt 与事件读取均返回 INVALID_STATE。
    function new(string name = "rdma_dpu_interrupt_ctrl");
      super.new(name);
      frozen_func = null;
      reset_epoch = '0;
      mailbox_payload = '0;
      mailbox_command = '0;
      mailbox_sequence = 0;
      mailbox_generation = '0;
      mailbox_publication_token = '0;
      mailbox_generation_exhausted = 1'b0;
      mailbox_published = 1'b0;
      mailbox_delivered = 1'b0;
      mailbox_failed = 1'b0;
      delivered_count = 0;
      coalesced_count = 0;
      rejected_count = 0;
    endfunction

    // 功能：比较两个 BAR lease 的 role、BAR 号、base 和 size，供冻结投影权限核验复用。
    // 输入/输出及副作用：lhs/rhs 均为值输入；返回完全相等判定，不修改 lease。
    // 失败/边界：任一字段不同都返回 0，不用 BAR 区间重叠代替精确身份匹配。
    protected static function bit same_bar(dpu_bar_pair_lease_t lhs,
                                           dpu_bar_pair_lease_t rhs);
      return lhs.role == rhs.role && lhs.even_bar_id == rhs.even_bar_id &&
             lhs.base == rhs.base && lhs.size == rhs.size;
    endfunction

    // 功能：比较两份 dpu_dut_caps 的全部标量能力和 BAR profile 顺序/内容。
    // 输入/输出及副作用：lhs/rhs 为只读对象引用；返回值语义相等结果，不暴露内部 caps。
    // 失败/边界：任一对象为 null、标量字段、profile 数量或 profile 字段不同均返回 0。
    protected static function bit same_caps(dpu_dut_caps lhs, dpu_dut_caps rhs);
      if (lhs == null || rhs == null)
        return 0;
      if (lhs.max_hosts != rhs.max_hosts ||
          lhs.max_pfs_per_host != rhs.max_pfs_per_host ||
          lhs.max_vfs_per_pf != rhs.max_vfs_per_pf ||
          lhs.max_functions != rhs.max_functions ||
          lhs.global_msix_vector_count != rhs.global_msix_vector_count ||
          lhs.mailbox_msix_vectors != rhs.mailbox_msix_vectors ||
          lhs.af_extra_msix_vectors != rhs.af_extra_msix_vectors ||
          lhs.af_extra_queue_count != rhs.af_extra_queue_count ||
          lhs.vio_global_qpair_count != rhs.vio_global_qpair_count ||
          lhs.max_vio_net_qpairs_per_device != rhs.max_vio_net_qpairs_per_device ||
          lhs.vio_notify_entries_per_bank != rhs.vio_notify_entries_per_bank ||
          lhs.bar_profiles.size() != rhs.bar_profiles.size())
        return 0;
      foreach (lhs.bar_profiles[i]) begin
        if (lhs.bar_profiles[i].kind != rhs.bar_profiles[i].kind ||
            lhs.bar_profiles[i].role != rhs.bar_profiles[i].role ||
            lhs.bar_profiles[i].even_bar_id != rhs.bar_profiles[i].even_bar_id ||
            lhs.bar_profiles[i].size != rhs.bar_profiles[i].size ||
            lhs.bar_profiles[i].alignment != rhs.bar_profiles[i].alignment)
          return 0;
      end
      return 1;
    endfunction

    // 功能：报告控制器是否已成功冻结一个 Function 投影。
    // 输入/输出及副作用：无输入；返回 frozen_func 是否非空，不返回可变对象引用。
    // 失败/边界：configure 从未成功时稳定返回 0，配置后不因原投影变异而改变。
    function bit is_configured();
      return frozen_func != null;
    endfunction

    // 功能：核对 candidate 与 configure 时冻结的 key、PCIe ID、global ID、三类 BAR、父 PF 和 caps。
    // 输入/输出及副作用：candidate 只读；返回匹配结果，why 返回首个权限差异，不修改控制器。
    // 失败/边界：未配置、candidate/caps 为空或任一冻结字段不等时返回 0。
    function bit matches_projection(rdma_dpu_function candidate, output string why);
      why = "";
      if (frozen_func == null) begin
        why = "interrupt controller is not configured";
        return 0;
      end
      if (candidate == null || candidate.caps == null) begin
        why = "interrupt controller projection is incomplete";
        return 0;
      end
      if (!dpu_same_function_key(candidate.key, frozen_func.key) ||
          !dpu_same_domain_key(candidate.pcie_id.domain, frozen_func.pcie_id.domain) ||
          candidate.pcie_id.bdf != frozen_func.pcie_id.bdf ||
          candidate.global_id != frozen_func.global_id ||
          !same_bar(candidate.bar0, frozen_func.bar0) ||
          !same_bar(candidate.mailbox, frozen_func.mailbox) ||
          !same_bar(candidate.msix, frozen_func.msix) ||
          !dpu_same_domain_key(candidate.parent_pcie_id.domain,
                               frozen_func.parent_pcie_id.domain) ||
          candidate.parent_pcie_id.bdf != frozen_func.parent_pcie_id.bdf ||
          !same_caps(candidate.caps, frozen_func.caps)) begin
        why = {"interrupt controller frozen projection differs from ",
               dpu_function_key_name(frozen_func.key)};
        return 0;
      end
      return 1;
    endfunction

    // 功能：从冻结 dpu_common snapshot 重新投影控制器所属 Function，并对比全部冻结身份。
    // 输入/输出及副作用：snapshot 只读；why 返回 dpu_common 查询或匹配失败原因，不保存 snapshot 引用。
    // 失败/边界：snapshot/控制器未就绪、Function/BAR/caps 查询失败或 VF 父 PF 不匹配时返回 0。
    function bit matches_snapshot(dpu_device_snapshot snapshot, output string why);
      rdma_dpu_function expected;
      dpu_function_key_t parent;

      why = "";
      if (snapshot == null || frozen_func == null) begin
        why = "interrupt controller snapshot authority is incomplete";
        return 0;
      end
      expected = rdma_dpu_function::type_id::create({get_name(), "_snapshot_projection"});
      expected.key = frozen_func.key;
      expected.caps = snapshot.snapshot_dut_caps();
      if (expected.caps == null) begin
        why = "snapshot DUT capabilities are unavailable";
        return 0;
      end
      if (!snapshot.get_pcie_id(expected.key, expected.pcie_id, why) ||
          !snapshot.get_global_function_id(expected.key, expected.global_id, why) ||
          !snapshot.get_bar(expected.key, DPU_BAR_DEVICE_MEMORY, expected.bar0, why) ||
          !snapshot.get_bar(expected.key, DPU_BAR_MAILBOX, expected.mailbox, why) ||
          !snapshot.get_bar(expected.key, DPU_BAR_MSIX, expected.msix, why))
        return 0;
      if (expected.key.kind == DPU_FUNCTION_VF) begin
        parent = expected.key;
        parent.kind = DPU_FUNCTION_PF;
        parent.vf_id = 0;
        if (!snapshot.get_pcie_id(parent, expected.parent_pcie_id, why))
          return 0;
      end
      return matches_projection(expected, why);
    endfunction

    // 功能：按值冻结 Function 投影，并且只建立寄存器契约明确支持的 MAILBOX local vector 0。
    // 输入/输出及副作用：func_arg 只在本调用内读取；成功时深拷贝 caps/身份/BAR，创建一个
    //   vector 并进入 epoch 1，之后 func_arg 变异不会影响控制器。
    // 失败/边界：重复配置返回 RESOURCE_BUSY；空投影、BAR role/尺寸不足、全局池为零，或
    //   mailbox_msix_vectors 不是唯一可建模数量 1 时返回 INVALID_ARGUMENT，不留半配置状态。
    function rdma_status configure(rdma_dpu_function func_arg);
      if (frozen_func != null)
        return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                 "interrupt controller is already configured");
      if (func_arg == null || func_arg.caps == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "interrupt controller requires a Function snapshot");
      if (func_arg.bar0.role != DPU_BAR_DEVICE_MEMORY ||
          func_arg.mailbox.role != DPU_BAR_MAILBOX ||
          func_arg.msix.role != DPU_BAR_MSIX)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "interrupt controller Function BAR roles are inconsistent");
      if (func_arg.mailbox.size < RDMA_DPU_MAILBOX_ACK_OFFSET + 8 ||
          func_arg.msix.size < RDMA_DPU_MSIX_ENTRY_BYTES)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "Function control BAR cannot cover modeled registers");
      if (func_arg.caps.global_msix_vector_count == 0 ||
          func_arg.caps.mailbox_msix_vectors >
            func_arg.caps.global_msix_vector_count)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "DUT global MSI-X pool cannot cover MAILBOX capability");
      if (func_arg.caps.mailbox_msix_vectors !=
          RDMA_DPU_MODELED_MAILBOX_VECTOR_COUNT)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "adapter models exactly one MAILBOX local MSI-X vector");

      frozen_func = rdma_dpu_function::type_id::create({get_name(), "_frozen_func"});
      frozen_func.key = func_arg.key;
      frozen_func.pcie_id = func_arg.pcie_id;
      frozen_func.global_id = func_arg.global_id;
      frozen_func.bar0 = func_arg.bar0;
      frozen_func.mailbox = func_arg.mailbox;
      frozen_func.msix = func_arg.msix;
      frozen_func.parent_pcie_id = func_arg.parent_pcie_id;
      frozen_func.caps = dpu_dut_caps::type_id::create({get_name(), "_frozen_caps"});
      frozen_func.caps.copy_from(func_arg.caps);
      vectors = new[RDMA_DPU_MODELED_MAILBOX_VECTOR_COUNT];
      delivered_events.delete();
      reset_epoch = '0;
      mailbox_generation = '0;
      mailbox_generation_exhausted = 1'b0;
      reset();
      return rdma_status::success();
    endfunction

    // 功能：推进跨发布和跨复位共用的 64 位单调 generation，作为新 ACK token 的唯一性基础。
    // 输入/输出及副作用：无输入；成功时 generation 加一并返回 1，不直接更改发布状态。
    // 失败/边界：generation 已耗尽或到达全 1 时设置 exhausted 并返回 0，禁止回绕造成 ABA。
    protected function bit advance_mailbox_generation();
      if (mailbox_generation_exhausted)
        return 0;
      if (mailbox_generation == '1) begin
        mailbox_generation_exhausted = 1'b1;
        return 0;
      end
      mailbox_generation++;
      return 1;
    endfunction

    // 功能：执行 Function 级控制面复位：推进 reset_epoch 与 ACK generation，清空 MAILBOX
    //   发布、事件与统计，并把全部 MSI-X entry 恢复为地址/数据零、masked=1、pending=0。
    // 输入/输出及副作用：只修改本控制器拥有的状态；已导出的事件对象仍是旧 epoch 的值快照。
    // 失败/边界：未 configure 时保持 epoch/generation 0；epoch 全 1 时回到 1。generation 不回绕，
    //   耗尽后所有后续发布都安全拒绝，不重用旧 ACK token。
    function void reset();
      if (frozen_func != null) begin
        if (reset_epoch == '1)
          reset_epoch = 1;
        else
          reset_epoch++;
        void'(advance_mailbox_generation());
      end
      else begin
        reset_epoch = '0;
        mailbox_generation = '0;
      end
      mailbox_payload = '0;
      mailbox_command = '0;
      mailbox_sequence = 0;
      mailbox_publication_token = '0;
      mailbox_published = 1'b0;
      mailbox_delivered = 1'b0;
      mailbox_failed = 1'b0;
      delivered_events.delete();
      delivered_count = 0;
      coalesced_count = 0;
      rejected_count = 0;
      foreach (vectors[i]) begin
        vectors[i].message_address = '0;
        vectors[i].message_data = '0;
        vectors[i].masked = 1'b1;
        vectors[i].pending = 1'b0;
        vectors[i].pending_cause = '0;
      end
    endfunction

    // 功能：检查控制器已经绑定 Function，并验证 expected_epoch 指向当前 Function incarnation。
    // 输入/输出及副作用：expected_epoch 为调用方捕获的 epoch；返回成功或明确状态，不修改寄存器与队列。
    // 失败/边界：未配置返回 INVALID_STATE；epoch 不等返回 STALE_GENERATION，包含旧/新 epoch 诊断。
    protected function rdma_status validate_epoch(rdma_reset_epoch_t expected_epoch);
      if (frozen_func == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "interrupt controller is not configured");
      if (expected_epoch != reset_epoch)
        return rdma_status::make(
          RDMA_SC_STALE_GENERATION,
          $sformatf("interrupt epoch %0d is stale; current epoch is %0d",
                    expected_epoch, reset_epoch));
      return rdma_status::success();
    endfunction

    // 功能：把一个已就绪且未 mask 的 vector 转为不可变事件并加入本 Function 的 delivered_events；
    //   vector 0 对应未完成 MAILBOX 发布时同步置 delivered 状态。
    // 输入/输出及副作用：vector_index/cause 写入新事件；成功清 pending 并增加 delivered_count。
    // 失败/边界：vector 越界返回 INVALID_ARGUMENT；message address 为零或未按 4B 对齐返回 INVALID_STATE，
    //   pending 保留以便重新编程后重试，不产生事件。
    protected function rdma_status deliver_pending(int unsigned vector_index);
      rdma_dpu_interrupt_event irq;

      if (vector_index >= vectors.size()) begin
        rejected_count++;
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MSI-X vector index is outside the Function table");
      end
      if (!vectors[vector_index].pending)
        return rdma_status::success();
      if (vectors[vector_index].masked)
        return rdma_status::success();
      if (vectors[vector_index].message_address == 0 ||
          vectors[vector_index].message_address[1:0] != 2'b00) begin
        rejected_count++;
        if (vector_index == RDMA_DPU_MAILBOX_VECTOR_INDEX && mailbox_published)
          mailbox_failed = 1'b1;
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "pending MSI-X vector has no valid message address");
      end
      irq = rdma_dpu_interrupt_event::type_id::create(
        $sformatf("%s_irq%0d_e%0d", get_name(), vector_index, reset_epoch));
      irq.function_key = frozen_func.key;
      irq.pcie_id = frozen_func.pcie_id;
      irq.vector_index = vector_index;
      irq.message_address = vectors[vector_index].message_address;
      irq.message_data = vectors[vector_index].message_data;
      irq.cause = vectors[vector_index].pending_cause;
      irq.reset_epoch = reset_epoch;
      delivered_events.push_back(irq);
      vectors[vector_index].pending = 1'b0;
      vectors[vector_index].pending_cause = '0;
      delivered_count++;
      if (vector_index == RDMA_DPU_MAILBOX_VECTOR_INDEX && mailbox_published) begin
        mailbox_delivered = 1'b1;
        mailbox_failed = 1'b0;
      end
      return rdma_status::success();
    endfunction

    // 功能：为当前 Function 发布一次 vector 中断；mask 时仅置 PBA pending，解 mask 或已解 mask时由
    //   deliver_pending 形成事件，重复 pending 请求按 MSI-X 合并语义计数且保留首个 cause。
    // 输入/输出及副作用：vector_index、expected_epoch、cause 为输入；可能更新 pending、事件队列和统计。
    // 失败/边界：未配置/旧 epoch/越界分别返回 INVALID_STATE、STALE_GENERATION、INVALID_ARGUMENT；
    //   未编程有效 message address 时返回 INVALID_STATE 并保留 pending，便于随后编程恢复。
    function rdma_status raise_interrupt(int unsigned vector_index,
                                         rdma_reset_epoch_t expected_epoch,
                                         bit [63:0] cause);
      rdma_status status;

      status = validate_epoch(expected_epoch);
      if (!status.ok()) begin
        rejected_count++;
        return status;
      end
      if (vector_index >= vectors.size()) begin
        rejected_count++;
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MSI-X vector index is outside the Function table");
      end
      if (vectors[vector_index].pending) begin
        coalesced_count++;
      end
      else begin
        vectors[vector_index].pending = 1'b1;
        vectors[vector_index].pending_cause = cause;
      end
      status = deliver_pending(vector_index);
      return status;
    endfunction

    // 功能：按本项目 MAILBOX 布局执行一次 64 位写；payload/command 构成原子发布，command 触发
    //   唯一建模的 local vector 0，ACK 只在投递完成后且回写当前 64 位 publication token 时消费。
    // 输入/输出及副作用：offset/value 为 BAR 内偏移和值；更新 MAILBOX、vector 0 pending 或事件队列。
    // 失败/边界：非 8B 对齐/未知/只读 offset、零 command、generation 耗尽、未完成发布上的
    //   覆盖或 vector 0 已 pending 返回明确错误；ACK token 不等/无活动发布返回 STALE_GENERATION，
    //   token 正确但仍 pending 返回 RESOURCE_BUSY。
    function rdma_status write_mailbox(bit [63:0] offset, bit [63:0] value);
      rdma_status status;

      if (frozen_func == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "MAILBOX controller is not configured");
      if (offset[2:0] != 3'b000)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MAILBOX access is not 8-byte aligned");
      case (offset)
        RDMA_DPU_MAILBOX_PAYLOAD_OFFSET: begin
          if (mailbox_published)
            return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                     "MAILBOX payload is owned by an active publication");
          mailbox_payload = value;
          return rdma_status::success();
        end
        RDMA_DPU_MAILBOX_COMMAND_OFFSET: begin
          if (value == 0)
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "MAILBOX command zero does not publish a request");
          if (mailbox_published)
            return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                     "MAILBOX already has an active publication");
          if (vectors[RDMA_DPU_MAILBOX_VECTOR_INDEX].pending)
            return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                     "MAILBOX MSI-X vector already has a pending cause");
          if (!advance_mailbox_generation())
            return rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "MAILBOX publication generation is exhausted");
          mailbox_command = value;
          mailbox_sequence++;
          mailbox_publication_token = mailbox_generation;
          mailbox_published = 1'b1;
          mailbox_delivered = 1'b0;
          mailbox_failed = 1'b0;
          status = raise_interrupt(RDMA_DPU_MAILBOX_VECTOR_INDEX, reset_epoch, value);
          if (!status.ok())
            mailbox_failed = 1'b1;
          return status;
        end
        RDMA_DPU_MAILBOX_STATUS_OFFSET:
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "MAILBOX status register is read-only");
        RDMA_DPU_MAILBOX_ACK_OFFSET: begin
          if (!mailbox_published)
            return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                     "MAILBOX ACK has no active publication");
          if (value == 0 || value != mailbox_publication_token)
            return rdma_status::make(
              RDMA_SC_STALE_GENERATION,
              $sformatf("MAILBOX ACK token %016h does not match active token %016h",
                        value, mailbox_publication_token));
          if (vectors[RDMA_DPU_MAILBOX_VECTOR_INDEX].pending)
            return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                     "MAILBOX interrupt is still pending");
          if (!mailbox_delivered)
            return rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "MAILBOX publication has no delivered interrupt");
          mailbox_payload = '0;
          mailbox_command = '0;
          mailbox_publication_token = '0;
          mailbox_published = 1'b0;
          mailbox_delivered = 1'b0;
          mailbox_failed = 1'b0;
          return rdma_status::success();
        end
        default:
          return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                   $sformatf("MAILBOX register %0h is not modeled", offset));
      endcase
    endfunction

    // 功能：读取 payload、command、组合 status 或 ACK token；status 位 0..3 依次是 published、pending、
    //   delivered、failed，[31:16] 是当前 epoch 内发布序号，[63:32] 是 reset epoch 低 32 位。
    // 输入/输出及副作用：offset 为 BAR 内偏移，value 返回寄存器快照；读取不消费发布或事件。
    // 失败/边界：未配置、非 8B 对齐或未知 offset 返回 INVALID_STATE、INVALID_ARGUMENT 或
    //   UNSUPPORTED_OPCODE；无活动发布时 ACK 读值为零，失败时 value 也保持零。
    function rdma_status read_mailbox(bit [63:0] offset, output bit [63:0] value);
      value = '0;
      if (frozen_func == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "MAILBOX controller is not configured");
      if (offset[2:0] != 3'b000)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MAILBOX access is not 8-byte aligned");
      case (offset)
        RDMA_DPU_MAILBOX_PAYLOAD_OFFSET: value = mailbox_payload;
        RDMA_DPU_MAILBOX_COMMAND_OFFSET: value = mailbox_command;
        RDMA_DPU_MAILBOX_STATUS_OFFSET: begin
          value[0] = mailbox_published;
          value[1] = vectors[RDMA_DPU_MAILBOX_VECTOR_INDEX].pending;
          value[2] = mailbox_delivered;
          value[3] = mailbox_failed;
          value[31:16] = mailbox_sequence[15:0];
          value[63:32] = reset_epoch[31:0];
        end
        RDMA_DPU_MAILBOX_ACK_OFFSET:
          value = mailbox_publication_token;
        default:
          return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                   $sformatf("MAILBOX register %0h is not modeled", offset));
      endcase
      return rdma_status::success();
    endfunction

    // 功能：写 MSI-X table 的 message address 或 data/control qword；每个 entry 的 pending 位只读，
    //   写入有效地址或从 mask 切到 unmask 时会尝试投递已 pending 的事件。
    // 输入/输出及副作用：offset/value 更新指定 vector；成功解阻 pending 时向 delivered_events 追加事件。
    // 失败/边界：未配置、非 8B 对齐、vector 越界、地址非 4B 对齐或 value[63:33] 非零分别返回明确
    //   INVALID_STATE/INVALID_ARGUMENT；投递所需字段仍不完整时保留 pending 并返回 INVALID_STATE。
    function rdma_status write_msix(bit [63:0] offset, bit [63:0] value);
      int unsigned vector_index;
      bit [63:0] entry_offset;

      if (frozen_func == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "MSI-X controller is not configured");
      if (offset[2:0] != 3'b000)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MSI-X table access is not 8-byte aligned");
      vector_index = int'(offset / RDMA_DPU_MSIX_ENTRY_BYTES);
      entry_offset = offset % RDMA_DPU_MSIX_ENTRY_BYTES;
      if (vector_index >= vectors.size())
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MSI-X table access exceeds Function vector capacity");
      case (entry_offset)
        RDMA_DPU_MSIX_ADDRESS_OFFSET: begin
          if ((value & 64'h3) != 0)
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "MSI-X message address is not 4-byte aligned");
          vectors[vector_index].message_address = value;
        end
        RDMA_DPU_MSIX_DATA_CTRL_OFFSET: begin
          if ((value & 64'hffff_fffe_0000_0000) != 0)
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "MSI-X data/control write sets reserved or pending bits");
          vectors[vector_index].message_data = value;
          vectors[vector_index].masked = value[32];
        end
        default:
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "MSI-X table access does not select an entry qword");
      endcase
      return deliver_pending(vector_index);
    endfunction

    // 功能：读取 MSI-X table entry；address qword 返回消息地址，data/control qword 返回消息数据、mask
    //   与只读 pending 位。
    // 输入/输出及副作用：offset 选择 Function-local vector，value 返回当前寄存器快照；无状态副作用。
    // 失败/边界：未配置、未对齐、vector 越界或 qword 非法返回 INVALID_STATE/INVALID_ARGUMENT，
    //   失败时 value 为零。
    function rdma_status read_msix(bit [63:0] offset, output bit [63:0] value);
      int unsigned vector_index;
      bit [63:0] entry_offset;

      value = '0;
      if (frozen_func == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "MSI-X controller is not configured");
      if (offset[2:0] != 3'b000)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MSI-X table access is not 8-byte aligned");
      vector_index = int'(offset / RDMA_DPU_MSIX_ENTRY_BYTES);
      entry_offset = offset % RDMA_DPU_MSIX_ENTRY_BYTES;
      if (vector_index >= vectors.size())
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MSI-X table access exceeds Function vector capacity");
      case (entry_offset)
        RDMA_DPU_MSIX_ADDRESS_OFFSET:
          value = vectors[vector_index].message_address;
        RDMA_DPU_MSIX_DATA_CTRL_OFFSET: begin
          value = vectors[vector_index].message_data;
          value[32] = vectors[vector_index].masked;
          value[33] = vectors[vector_index].pending;
        end
        default:
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "MSI-X table access does not select an entry qword");
      endcase
      return rdma_status::success();
    endfunction

    // 功能：按 FIFO 顺序消费本 Function 已投递的下一条 MSI-X 事件。
    // 输入/输出及副作用：irq 输出事件对象引用；成功从 delivered_events 删除队首，其他字段不变。
    // 失败/边界：未配置返回 INVALID_STATE，队列为空返回 QUEUE_EMPTY；两种失败均令 irq=null。
    function rdma_status pop_interrupt(output rdma_dpu_interrupt_event irq);
      irq = null;
      if (frozen_func == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "interrupt controller is not configured");
      if (delivered_events.size() == 0)
        return rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "Function has no delivered MSI-X interrupt");
      irq = delivered_events.pop_front();
      return rdma_status::success();
    endfunction
  endclass

  // MMIO 地址解码：按快照把绝对地址落到 Function 的 BAR 与偏移，DEVICE_MEMORY（BAR0，驱动
  // pf->hw_addr）交给设备，MAILBOX/MSI-X 交给该 Function 独占控制器；BAR 外地址与未登记 Function
  // 均拒绝。路由器只保存设备和控制器的非拥有引用。
  class rdma_dpu_bar_router extends uvm_object;
    `uvm_object_utils(rdma_dpu_bar_router)

    dpu_device_snapshot snapshot;
    rdma_dev devs[string];
    rdma_dpu_interrupt_ctrl interrupt_ctrls[string];
    int unsigned routed;

    // 功能：构造一个尚未绑定快照、设备或中断控制器的 BAR 路由器，并把成功路由计数置零。
    // 输入/输出及副作用：name 仅作为 UVM 对象名；devs/interrupt_ctrls 保持空关联数组。
    // 失败/边界：snapshot 与 Function 映射接入前，read/write/raise_interrupt 返回 INVALID_STATE。
    function new(string name = "rdma_dpu_bar_router");
      super.new(name);
      snapshot = null;
      routed = 0;
    endfunction

    // 功能：按 dpu_common Function key 登记其设备与独占 MAILBOX/MSI-X 控制器；登记前同时核对
    //   f、控制器内部冻结副本与 snapshot 的 key/PCIe/global ID/三个 BAR/父 PF/caps。
    // 输入/输出及副作用：f 仅在 attach 期间读取，不被 router 保存；dev/interrupt_ctrl 作为非拥有引用
    //   写入两个关联数组，后续 f 变异不会改写路由身份或事件身份。
    // 失败/边界：快照/参数/控制器未就绪返回 INVALID_STATE/INVALID_ARGUMENT；任一冻结字段不同
    //   按 INVALID_ARGUMENT 拒绝；重复 key 返回 RESOURCE_BUSY，失败不覆盖现有 route。
    function rdma_status attach(rdma_dpu_function f, rdma_dev dev,
                                rdma_dpu_interrupt_ctrl interrupt_ctrl);
      string name;
      string why;

      if (snapshot == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "BAR router cannot attach without a snapshot");
      if (f == null || dev == null || interrupt_ctrl == null ||
          !interrupt_ctrl.is_configured())
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "BAR router Function attachment is incomplete");
      name = dpu_function_key_name(f.key);
      if (!interrupt_ctrl.matches_projection(f, why))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 {"BAR router projection mismatch for ", name, ": ", why});
      if (!interrupt_ctrl.matches_snapshot(snapshot, why))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 {"BAR router snapshot mismatch for ", name, ": ", why});
      if (devs.exists(name) || interrupt_ctrls.exists(name))
        return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                 {"BAR router already has a route for ", name});
      devs[name] = dev;
      interrupt_ctrls[name] = interrupt_ctrl;
      return rdma_status::success();
    endfunction

    // 功能：查询 key 对应的中断控制器，集中执行 direct interrupt API 与复位调用前的 Function 授权检查。
    // 输入/输出及副作用：key 为冻结快照中的 Function key；interrupt_ctrl 输出非拥有引用，不修改映射。
    // 失败/边界：key 未登记时返回 INVALID_STATE 且 interrupt_ctrl=null，不按 global ID 或 BDF 猜测回退。
    function rdma_status lookup_interrupt_ctrl(dpu_function_key_t key,
                                                output rdma_dpu_interrupt_ctrl interrupt_ctrl);
      string name;

      interrupt_ctrl = null;
      name = dpu_function_key_name(key);
      if (!interrupt_ctrls.exists(name))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {"no interrupt controller for ", name});
      interrupt_ctrl = interrupt_ctrls[name];
      return rdma_status::success();
    endfunction

    // 功能：64 位 MMIO 写：由 snapshot.resolve_bar_address 决定 Function 与 BAR role，再把 BAR0、
    //   MAILBOX、MSI-X 分别交给设备寄存器、邮箱控制器或 vector table。
    // 输入/输出及副作用：domain/address/value 为 Host MMIO 请求；命中设备或已建模控制寄存器即令 routed
    //   加一（即使目标随后报错），并可能驱动设备、发布 MAILBOX 状态或投递 MSI-X 事件。
    // 失败/边界：无快照、地址/8B 宽度越界、Function 未 attach 时不增加 routed；MAILBOX 未建模 offset
    //   返回 UNSUPPORTED_OPCODE 且不增加，已命中寄存器的状态/资源失败保留 routed 以阻止上层跨 domain 重试。
    task write(dpu_pcie_domain_key_t domain, bit [63:0] address, bit [63:0] value,
               output rdma_status status);
      dpu_bar_address_match_t match;
      string name;
      string why;

      if (snapshot == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE, "BAR router has no snapshot");
        return;
      end
      if (!snapshot.resolve_bar_address(domain, address, match, why)) begin
        status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
        return;
      end
      if (match.bar_size < 8 || match.offset > match.bar_size - 8) begin
        status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "64-bit MMIO access crosses the decoded BAR boundary");
        return;
      end
      name = dpu_function_key_name(match.function_key);
      case (match.role)
        DPU_BAR_DEVICE_MEMORY: begin
          if (!devs.exists(name)) begin
            status = rdma_status::make(RDMA_SC_INVALID_STATE, {"no device for ", name});
            return;
          end
          routed++;
          devs[name].write_register(match.offset, value, status);
        end
        DPU_BAR_MAILBOX: begin
          if (!interrupt_ctrls.exists(name)) begin
            status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       {"no interrupt controller for ", name});
            return;
          end
          status = interrupt_ctrls[name].write_mailbox(match.offset, value);
          if (status != null && status.code != RDMA_SC_UNSUPPORTED_OPCODE)
            routed++;
        end
        DPU_BAR_MSIX: begin
          if (!interrupt_ctrls.exists(name)) begin
            status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       {"no interrupt controller for ", name});
            return;
          end
          status = interrupt_ctrls[name].write_msix(match.offset, value);
          routed++;
        end
        default: begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     $sformatf("MMIO %016h has unknown BAR role", address));
          return;
        end
      endcase
    endtask

    // 功能：64 位 MMIO 读：用冻结快照解码 MAILBOX/MSI-X 地址并返回所属 Function 的寄存器快照。
    // 输入/输出及副作用：domain/address 为请求，value/status 为输出；成功读取后 routed 加一，不消费事件。
    // 失败/边界：无快照、地址或宽度越界、BAR0 不支持读、Function 未 attach 或寄存器非法时返回明确
    //   状态且 value=0、routed 不增加。
    task read(dpu_pcie_domain_key_t domain, bit [63:0] address,
              output bit [63:0] value, output rdma_status status);
      dpu_bar_address_match_t match;
      string name;
      string why;

      value = '0;
      if (snapshot == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE, "BAR router has no snapshot");
        return;
      end
      if (!snapshot.resolve_bar_address(domain, address, match, why)) begin
        status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
        return;
      end
      if (match.bar_size < 8 || match.offset > match.bar_size - 8) begin
        status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "64-bit MMIO access crosses the decoded BAR boundary");
        return;
      end
      name = dpu_function_key_name(match.function_key);
      if (!interrupt_ctrls.exists(name)) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   {"no interrupt controller for ", name});
        return;
      end
      case (match.role)
        DPU_BAR_MAILBOX:
          status = interrupt_ctrls[name].read_mailbox(match.offset, value);
        DPU_BAR_MSIX:
          status = interrupt_ctrls[name].read_msix(match.offset, value);
        DPU_BAR_DEVICE_MEMORY:
          status = rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                     "device-memory BAR read is not modeled");
        default:
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     $sformatf("MMIO %016h has unknown BAR role", address));
      endcase
      if (status != null && status.ok())
        routed++;
    endtask

    // 功能：按完整 dpu_common Function key 向其 MSI-X 控制器注入设备事件，供 MAILBOX 之外的设备源复用。
    // 输入/输出及副作用：key/vector_index/expected_epoch/cause 为值输入；成功或 mask 时更新该 Function
    //   pending/事件队列，status 返回控制器结果，不解析或修改 BAR 拓扑。
    // 失败/边界：未知 key、旧 epoch、vector 越界或消息地址未配置分别返回 INVALID_STATE、
    //   STALE_GENERATION、INVALID_ARGUMENT 或 INVALID_STATE，绝不转投其他 Function。
    function rdma_status raise_interrupt(dpu_function_key_t key, int unsigned vector_index,
                                         rdma_reset_epoch_t expected_epoch, bit [63:0] cause);
      rdma_dpu_interrupt_ctrl interrupt_ctrl;
      rdma_status status;

      status = lookup_interrupt_ctrl(key, interrupt_ctrl);
      if (!status.ok())
        return status;
      return interrupt_ctrl.raise_interrupt(vector_index, expected_epoch, cause);
    endfunction

    // 功能：消费指定 Function 的下一条已投递 MSI-X 事件，保持不同 Function 的 FIFO 相互独立。
    // 输入/输出及副作用：key 选择精确控制器；irq 输出事件并从该控制器队首删除。
    // 失败/边界：未知 key 返回 INVALID_STATE；目标队列为空返回 QUEUE_EMPTY；均令 irq=null。
    function rdma_status pop_interrupt(dpu_function_key_t key,
                                       output rdma_dpu_interrupt_event irq);
      rdma_dpu_interrupt_ctrl interrupt_ctrl;
      rdma_status status;

      irq = null;
      status = lookup_interrupt_ctrl(key, interrupt_ctrl);
      if (!status.ok())
        return status;
      return interrupt_ctrl.pop_interrupt(irq);
    endfunction
  endclass

  // 一个 Function 的驱动 BAR：偏移加 BAR0 基址成为该 Host domain 内的绝对地址，经路由器解码；记录
  // 每次写的 BAR 内偏移与值供观测。
  class rdma_dpu_bar extends rdma_drv_bar;
    `uvm_object_utils(rdma_dpu_bar)

    rdma_dpu_bar_router router;
    rdma_dpu_function func;
    bit [63:0] written_offsets[$];
    bit [63:0] written_values[$];

    // 功能：构造未连接的驱动 BAR 端口，清空 router/func 引用和写观测队列。
    // 输入/输出及副作用：name 仅作为 UVM 对象名；router 与 func 保持非拥有 null 引用。
    // 失败/边界：rdma_dpu_system::build 完成连接前 write64 返回 INVALID_STATE，但仍记录尝试的 offset/value。
    function new(string name = "rdma_dpu_bar");
      super.new(name);
      router = null;
      func = null;
    endfunction

    // 功能：BAR0 内偏移的 64 位写（先记录）。
    // 输入/输出及副作用：见 rdma_dpu_bar_router.write。
    // 失败/边界：未连接返回 INVALID_STATE；偏移超出 BAR0 由路由器拒绝。
    virtual task write64(bit [63:0] offset, bit [63:0] value, output rdma_status status);
      written_offsets.push_back(offset);
      written_values.push_back(value);
      if (router == null || func == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE, "dpu BAR is not connected");
        return;
      end
      router.write(func.pcie_id.domain, func.bar0.base + offset, value, status);
    endtask
  endclass

  // 一个 Function 的全部模型对象。
  class rdma_dpu_node extends uvm_object;
    `uvm_object_utils(rdma_dpu_node)

    rdma_dpu_function func;
    rdma_host_mem mem;
    rdma_dev dev;
    rdma_dpu_interrupt_ctrl interrupt_ctrl;
    rdma_dpu_bar bar;
    rdma_drv_hw hw;
    rdma_drv_dev drv;

    // 功能：构造尚未装配 Function 投影、设备、MAILBOX/MSI-X 控制器、驱动 BAR 与硬件绑定的空节点。
    // 输入/输出及副作用：name 仅作为 UVM 对象名；成员由 rdma_dpu_system::build 按快照统一赋值。
    // 失败/边界：build 完成前成员引用为空，调用方不得用空节点发 MMIO、DMA 或中断事务。
    function new(string name = "rdma_dpu_node");
      super.new(name);
      func = null;
      mem = null;
      dev = null;
      interrupt_ctrl = null;
      bar = null;
      hw = null;
      drv = null;
    endfunction
  endclass

  // 全局 Function 控制：dpu_common 拓扑 → 每个 Function 的设备/内存/BAR/驱动，复位范围由快照推出。
  class rdma_dpu_system extends uvm_object;
    `uvm_object_utils(rdma_dpu_system)

    dpu_device_cfg cfg;
    dpu_device_snapshot snapshot;
    rdma_dpu_bar_router router;
    // 各 Host 的 host_mem（Function 在其 Host 的 manager 上分配）。
    rdma_host_mems mems;
    rdma_dpu_node nodes[$];

    // 功能：构造可追加 Host/Function 的空系统，创建本系统拥有的 cfg 与 host_mem 管理器。
    // 输入/输出及副作用：name 派生 cfg/mems 名称；snapshot/router 为 null，nodes 为空，外部依赖尚未启动。
    // 失败/边界：调用 build 前不能 probe/start/发 MMIO；配置合法性与容量约束延迟到 resolver。
    function new(string name = "rdma_dpu_system");
      super.new(name);
      cfg = dpu_device_cfg::type_id::create({name, "_cfg"});
      snapshot = null;
      router = null;
      mems = rdma_host_mems::type_id::create({name, "_mems"});
    endfunction

    // 功能：声明 Host（见 rdma_dpu_topology::add_host）。
    // 输入/输出及副作用：写 cfg。
    // 失败/边界：合法性由 build 时的 resolver 校验。
    function void add_host(int unsigned host_id, int segment_id = -1);
      rdma_dpu_topology::add_host(cfg, host_id, segment_id);
    endfunction

    // 功能：声明 PF/VF（见 rdma_dpu_topology::add_function）。
    // 输入/输出及副作用：写 cfg。
    // 失败/边界：合法性由 build 时的 resolver 校验。
    function void add_function(int unsigned host_id, int unsigned pf_id, dpu_function_kind_e kind,
                               int unsigned vf_id);
      rdma_dpu_topology::add_function(cfg, host_id, pf_id, kind, vf_id);
    endfunction

    // 功能：解析冻结快照，按快照顺序为每个 Function 建立节点：所属 Host 的主机内存、设备、独占
    //   MAILBOX/MSI-X 控制器、BAR 路由与驱动硬件绑定；不启动 NIC、不 probe。
    // 输入/输出及副作用：设置 snapshot/router/nodes；控制器容量、BDF 和三个 BAR 均来自同一冻结投影。
    // 失败/边界：拓扑解析、中断控制器配置或硬件绑定失败立即返回其 status；失败节点不加入 nodes。
    function rdma_status build();
      rdma_dpu_function funcs[$];
      rdma_dpu_node n;
      rdma_status status;
      string name;

      status = rdma_dpu_topology::resolve(cfg, snapshot, funcs);
      if (!status.ok())
        return status;
      router = rdma_dpu_bar_router::type_id::create({get_name(), "_router"});
      router.snapshot = snapshot;
      nodes.delete();
      foreach (funcs[i]) begin
        name = $sformatf("%s_f%0d", get_name(), funcs[i].global_id);
        n = rdma_dpu_node::type_id::create(name);
        n.func = funcs[i];
        n.mem = mems.make(funcs[i].key.host_id, {name, "_mem"});
        n.dev = rdma_dev::type_id::create({name, "_dev"});
        n.dev.configure(n.mem);
        n.interrupt_ctrl = rdma_dpu_interrupt_ctrl::type_id::create({name, "_interrupt_ctrl"});
        status = n.interrupt_ctrl.configure(funcs[i]);
        if (!status.ok())
          return status;
        n.bar = rdma_dpu_bar::type_id::create({name, "_bar"});
        n.bar.router = router;
        n.bar.func = funcs[i];
        n.hw = rdma_drv_hw::type_id::create({name, "_hw"});
        status = n.hw.bind_hw(n.bar, n.mem);
        if (!status.ok())
          return status;
        status = router.attach(funcs[i], n.dev, n.interrupt_ctrl);
        if (!status.ok())
          return status;
        n.drv = null;
        nodes.push_back(n);
      end
      return rdma_status::success();
    endfunction

    // 功能：为 build 后的每个节点启动一个 NIC 收发常驻进程，端口由调用方在本 task 前接入。
    // 输入/输出及副作用：借用 nodes[i].dev 并以 fork/join_none 返回；进程生命周期由仿真结束或外部停止控制。
    // 失败/边界：nodes 为空时幂等返回；重复调用会为同一 NIC 启动重复 run 进程，调用方必须避免。
    task start();
      foreach (nodes[i]) begin
        automatic rdma_dev d = nodes[i].dev;
        fork
          d.nic.run();
        join_none
      end
    endtask

    // 功能：probe 第 i 个节点的驱动：driver cfg（为 null 时用默认）的 host_id 与 vf_id（global
    //   Function ID）取自快照。
    // 输入/输出及副作用：替换节点驱动。
    // 失败/边界：i 越界返回 INVALID_ARGUMENT；probe 失败返回其 status。
    task probe(int unsigned i, output rdma_status status, input rdma_drv_config drv_cfg = null);
      if (i >= nodes.size()) begin
        status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "no such dpu node");
        return;
      end
      if (drv_cfg == null)
        drv_cfg = rdma_drv_config::type_id::create({nodes[i].get_name(), "_drv_cfg"});
      drv_cfg.host_id = nodes[i].func.key.host_id;
      drv_cfg.vf_id = nodes[i].func.global_id;
      nodes[i].drv = rdma_drv_dev::type_id::create({nodes[i].get_name(), "_drv"});
      nodes[i].drv.probe(drv_cfg, nodes[i].hw, status);
    endtask

    // 功能：快照中 key 对应的节点下标。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：不存在返回 -1。
    function int find(dpu_function_key_t key);
      foreach (nodes[i])
        if (dpu_function_key_name(nodes[i].func.key) == dpu_function_key_name(key))
          return i;
      return -1;
    endfunction

    // 功能：PF FLR 范围：Host host_id 上 PF pf_id 及其全部 VF。
    // 输入/输出及副作用：scope 输出节点下标。
    // 失败/边界：无匹配时为空。
    function void pf_scope(int unsigned host_id, int unsigned pf_id, output int unsigned scope[$]);
      scope.delete();
      foreach (nodes[i])
        if (nodes[i].func.key.host_id == host_id && nodes[i].func.key.pf_id == pf_id)
          scope.push_back(i);
    endfunction

    // 功能：Host 范围：该 Host 的全部 Function。
    // 输入/输出及副作用：scope 输出节点下标。
    // 失败/边界：无匹配时为空。
    function void host_scope(int unsigned host_id, output int unsigned scope[$]);
      scope.delete();
      foreach (nodes[i])
        if (nodes[i].func.key.host_id == host_id)
          scope.push_back(i);
    endfunction

    // 功能：按 nodes 当前稳定顺序生成覆盖整设备全部 Function 的复位下标范围。
    // 输入/输出及副作用：先清空 output scope，再依次追加 0..nodes.size()-1；不修改节点状态。
    // 失败/边界：尚未 build 或设备没有 Function 时返回空 scope，不伪造默认节点。
    function void device_scope(output int unsigned scope[$]);
      scope.delete();
      foreach (nodes[i])
        scope.push_back(i);
    endfunction

    // 功能：对 scope 内 Function 执行 FLR，同时清设备 context/NIC 与 MAILBOX/MSI-X 状态并推进独立
    //   reset_epoch；驱动对象保留，后续须 recover 重新 probe。
    // 输入/输出及副作用：scope 是节点下标队列；只修改合法下标对应的 dev 与 interrupt_ctrl。
    // 失败/边界：越界下标幂等忽略；同一 Function 每次合法调用都推进一次 epoch 并使旧 epoch 中断失效。
    function void flr(int unsigned scope[$]);
      foreach (scope[k])
        if (scope[k] < nodes.size()) begin
          nodes[scope[k]].dev.flr();
          nodes[scope[k]].interrupt_ctrl.reset();
        end
    endfunction

    // 功能：恢复 scope：先再次 FLR 保证设备与 MAILBOX/MSI-X 干净，再以 after_reset remove 驱动并
    //   重新 probe；既可接在 flr 后，也可单独作为复位恢复入口。
    // 输入/输出及副作用：替换 scope 内节点驱动；每个合法节点的第二次清理也推进一次 reset_epoch，
    //   因而恢复期间捕获的旧事件同样不能跨过重新 probe 边界。
    // 失败/边界：scope 下标越界返回 INVALID_ARGUMENT；remove/probe 失败立即返回其 status，已恢复节点保留。
    task recover(int unsigned scope[$], output rdma_status status,
                 input rdma_drv_config drv_cfg = null);
      status = rdma_status::success();
      foreach (scope[k]) begin
        if (scope[k] >= nodes.size()) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "reset recovery scope contains no such dpu node");
          return;
        end
        nodes[scope[k]].dev.flr();
        nodes[scope[k]].interrupt_ctrl.reset();
        if (nodes[scope[k]].drv != null) begin
          nodes[scope[k]].drv.remove(status, 1'b1);
          if (!status.ok())
            return;
        end
        probe(scope[k], status, drv_cfg);
        if (!status.ok())
          return;
      end
    endtask
  endclass
endpackage
