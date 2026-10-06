// 目录：外部适配器实现层 adapters/dpu/rdma_dpu_adapter_pkg.sv。
// 层：外部适配器。
// 职责：把 dpu_common 的逻辑设备配置接入 RDMA 驱动/设备模型：按 Host/PF/VF 声明生成
//   dpu_device_cfg（BAR 请求取 dut_caps.bar_profiles），经 dpu_device_resolver 解析并冻结快照；
//   把快照中每个 Function 投影为 host_id、global Function ID（驱动 QPC/PD 的 VF_ID）、BDF、BAR，
//   以及 net_packet 用的 rdma_function_identity；驱动的 MMIO 写按 BAR0 基址 + 偏移形成绝对地址，
//   由快照 resolve_bar_address 解码到所属 Function 的设备。
// 依赖：dpu_common（dpu_resource_pkg）、rdma_types/model、rdma_dev、rdma_drv。
// 所有权：快照与 cfg 由调用方持有；Function 投影为值快照；路由器只借用设备引用。
// 生命周期：测试建立拓扑时创建，仿真期间常驻。
package rdma_dpu_adapter_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import dpu_resource_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_drv_pkg::*;

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

    // 功能：构造空投影。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_dpu_function");
      super.new(name);
      global_id = 0;
    endfunction

    // 功能：Function 唯一标识：{Host, segment, BDF}（与 net_packet/host_mem 的 function_uid 共用）。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：全零路由时退回 global_id + 1。
    function longint unsigned uid();
      longint unsigned value;

      value = (longint'(pcie_id.domain.host_id) << 32) |
              (longint'(pcie_id.domain.segment_id) << 16) | longint'(pcie_id.bdf);
      if (value == 0)
        value = longint'(global_id) + 1;
      return value;
    endfunction

    // 功能：生成 RDMA Function identity（Host 拓扑键、segment、PF/VF、BDF、父 PF BDF、global ID）。
    // 输入/输出及副作用：id 输出新对象。
    // 失败/边界：identity 校验失败返回其 status。
    function rdma_status identity(output rdma_function_identity id);
      rdma_function_key_t rkey;

      rkey.root_id = pcie_id.domain.segment_id;
      rkey.host_topology_key = pcie_id.domain.host_id;
      rkey.function_kind = RDMA_FUNCTION_PF;
      rkey.parent_pf_bdf = '0;
      if (key.kind == DPU_FUNCTION_VF) begin
        rkey.function_kind = RDMA_FUNCTION_VF;
        rkey.parent_pf_bdf = to_bdf(parent_pcie_id);
      end
      rkey.vf_index = key.vf_id;
      rkey.bdf = to_bdf(pcie_id);
      id = rdma_function_identity::type_id::create($sformatf("dpu_identity_%0d", global_id));
      return id.configure(rkey, global_id, uid(), 1, 0);
    endfunction

    // 功能：dpu_common PCIe ID → RDMA BDF。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：无。
    static function rdma_bdf_t to_bdf(dpu_pcie_function_id_t id);
      rdma_bdf_t bdf;

      bdf.segment = id.domain.segment_id;
      bdf.bus = id.bdf[15:8];
      bdf.device = id.bdf[7:3];
      bdf.function_num = id.bdf[2:0];
      return bdf;
    endfunction
  endclass

  // dpu_device_cfg 的构造与解析。
  class rdma_dpu_topology extends uvm_object;
    `uvm_object_utils(rdma_dpu_topology)

    localparam bit [63:0] MMIO_WINDOW_BYTES = 64'h1_0000_0000;

    // 功能：构造。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_dpu_topology");
      super.new(name);
    endfunction

    // 功能：声明一个 Host 及其 PCIe domain（segment = host_id，BDF 0x0010..0x00ff，MMIO 窗口
    //   [4GiB*(host+1), +4GiB) 允许 DEVICE_MEMORY/MAILBOX/MSI-X）。
    // 输入/输出及副作用：追加 cfg.hosts。
    // 失败/边界：无（合法性由 resolver 校验）。
    static function void add_host(dpu_device_cfg cfg, int unsigned host_id);
      dpu_host_cfg host;
      dpu_pcie_domain_cfg domain;
      dpu_mmio_window_cfg window;
      dpu_bdf_range_t range;

      host = dpu_host_cfg::type_id::create($sformatf("host%0d", host_id));
      host.host_id = host_id;
      domain = dpu_pcie_domain_cfg::type_id::create($sformatf("domain%0d", host_id));
      domain.key.host_id = host_id;
      domain.key.segment_id = host_id;
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
      fcfg.domain_key.segment_id = host_id;
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

    // 功能：从快照读取一个 Function 的 PCIe ID、global ID、三个 BAR 与（VF）父 PF PCIe ID。
    // 输入/输出及副作用：写 f；why 输出失败原因。
    // 失败/边界：任一查询失败返回 0。
    static function bit project(dpu_device_snapshot snapshot, rdma_dpu_function f,
                                output string why);
      dpu_function_key_t parent;

      why = "";
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

  // MMIO 地址解码：按快照把绝对地址落到 Function 的 BAR 与偏移，DEVICE_MEMORY（BAR0，驱动
  // pf->hw_addr）写交给该 Function 的设备；MAILBOX/MSI-X 与 BAR 外地址拒绝。
  class rdma_dpu_bar_router extends uvm_object;
    `uvm_object_utils(rdma_dpu_bar_router)

    dpu_device_snapshot snapshot;
    rdma_dev devs[string];
    int unsigned routed;

    // 功能：构造。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_dpu_bar_router");
      super.new(name);
      snapshot = null;
      routed = 0;
    endfunction

    // 功能：登记 Function 对应的设备。
    // 输入/输出及副作用：写 devs。
    // 失败/边界：无。
    function void attach(rdma_dpu_function f, rdma_dev dev);
      devs[dpu_function_key_name(f.key)] = dev;
    endfunction

    // 功能：64 位 MMIO 写：解码地址并交给所属 Function 的设备（BAR 内偏移）。
    // 输入/输出及副作用：调用 rdma_dev.write_register，routed 计数。
    // 失败/边界：地址不在任何 BAR、落在非 DEVICE_MEMORY BAR、或 Function 无设备时返回
    //   INVALID_ARGUMENT/INVALID_STATE。
    function rdma_status write(dpu_pcie_domain_key_t domain, bit [63:0] address,
                               bit [63:0] value);
      dpu_bar_address_match_t match;
      string name;
      string why;

      if (snapshot == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE, "BAR router has no snapshot");
      if (!snapshot.resolve_bar_address(domain, address, match, why))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
      if (match.role != DPU_BAR_DEVICE_MEMORY)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 $sformatf("MMIO %016h is in a %s BAR", address,
                                           match.role.name()));
      name = dpu_function_key_name(match.function_key);
      if (!devs.exists(name))
        return rdma_status::make(RDMA_SC_INVALID_STATE, {"no device for ", name});
      routed++;
      return devs[name].write_register(match.offset, value);
    endfunction
  endclass

  // 一个 Function 的驱动 BAR：偏移加 BAR0 基址成为该 Host domain 内的绝对地址，经路由器解码。
  class rdma_dpu_bar extends rdma_drv_bar;
    `uvm_object_utils(rdma_dpu_bar)

    rdma_dpu_bar_router router;
    rdma_dpu_function func;

    // 功能：构造未连接的 BAR。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_dpu_bar");
      super.new(name);
      router = null;
      func = null;
    endfunction

    // 功能：BAR0 内偏移的 64 位写。
    // 输入/输出及副作用：见 rdma_dpu_bar_router.write。
    // 失败/边界：未连接返回 INVALID_STATE；偏移超出 BAR0 由路由器拒绝。
    virtual task write64(bit [63:0] offset, bit [63:0] value, output rdma_status status);
      if (router == null || func == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE, "dpu BAR is not connected");
        return;
      end
      status = router.write(func.pcie_id.domain, func.bar0.base + offset, value);
    endtask
  endclass
endpackage
