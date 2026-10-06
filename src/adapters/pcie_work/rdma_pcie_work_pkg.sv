// 目录：外部适配器实现层 adapters/pcie_work/rdma_pcie_work_pkg.sv。
// 层：外部适配器。
// 职责：MMIO 经 pcie_work 传输：dpu_common 快照（rdma_dpu_system）→ PCIe 拓扑（每个 Host 一条
//   RC↔EP 链）→ pcie_dpu_cfg_adapter 投影 → pcie_tl_env（TLM）。驱动 BAR 写成为所属 Host 的 RC 上
//   的 MemWr TLP（BAR0 基址 + 偏移，8 字节大端）；EP 侧收到 MemWr 后经快照解码（rdma_dpu_bar_router）
//   交给所属 Function 的设备，非 BAR0 或不在任何 BAR 的写被拒绝并计数。
// 依赖：pcie_work（pcie_tl_pkg、pcie_topology_pkg、pcie_dpu_integration_pkg）、dpu_common、
//   rdma_dpu_adapter_pkg。
// 所有权：rdma_pcie_system 持有 pcie_tl_env；rdma_dpu_system 由测试创建并交给它。
// 生命周期：UVM 组件，build_phase 建立。
package rdma_pcie_work_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import dpu_resource_pkg::*;
  import pcie_tl_pkg::*;
  import pcie_topology_pkg::*;
  import pcie_dpu_integration_pkg::*;
  import rdma_types_pkg::*;
  import rdma_dpu_adapter_pkg::*;

  typedef class rdma_pcie_system;

  // EP 驱动：MemWr 经快照解码交给 RDMA 设备；其余请求按 pcie_tl_ep_driver 处理。
  class rdma_pcie_ep_driver extends pcie_tl_ep_driver;
    `uvm_component_utils(rdma_pcie_ep_driver)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_pcie_ep_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：EP 收到请求：MemWr 交给 rdma_pcie_system 解码分派；其余（MemRd、Cfg 等）走基类。
    // 输入/输出及副作用：可能写设备寄存器。
    // 失败/边界：系统未建立时走基类。
    virtual task handle_request(pcie_tl_tlp req);
      pcie_tl_mem_tlp mem_req;

      if (req.kind == TLP_MEM_WR && rdma_pcie_system::current != null && $cast(mem_req, req)) begin
        rdma_pcie_system::current.deliver_mmio(mem_req);
        return;
      end
      super.handle_request(req);
    endtask
  endclass

  // 驱动 BAR：写成为所属 Host 的 RC 上的 MemWr TLP（8 字节大端），记录同基类。
  class rdma_pcie_bar extends rdma_dpu_bar;
    `uvm_object_utils(rdma_pcie_bar)

    // 功能：构造。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_pcie_bar");
      super.new(name);
    endfunction

    // 功能：BAR0 内偏移的 64 位写：记录后在 RC 上发 MemWr（posted，发出即返回）。
    // 输入/输出及副作用：启动 pcie_tl_rw_seq。
    // 失败/边界：未连接或 PCIe 系统未建立返回 INVALID_STATE。
    virtual task write64(bit [63:0] offset, bit [63:0] value, output rdma_status status);
      pcie_tl_rw_seq seq;

      written_offsets.push_back(offset);
      written_values.push_back(value);
      if (func == null || rdma_pcie_system::current == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE, "PCIe BAR is not connected");
        return;
      end
      seq = pcie_tl_rw_seq::type_id::create("rdma_mmio_wr");
      seq.op = PCIE_RW_WRITE;
      seq.addr = func.bar0.base + offset;
      seq.byte_len = 8;
      seq.wdata = new[8];
      foreach (seq.wdata[i])
        seq.wdata[i] = value[63 - 8 * i -: 8];
      seq.start(rdma_pcie_system::current.rc_seqr(func.key.host_id));
      rdma_pcie_system::current.sent_writes++;
      status = rdma_status::success();
    endtask
  endclass

  // dpu_common 快照 → pcie_work 环境，及 EP 侧 MMIO 分派。
  class rdma_pcie_system extends uvm_component;
    `uvm_component_utils(rdma_pcie_system)

    static rdma_pcie_system current;

    rdma_dpu_system dpu;
    pcie_tl_env tl_env;
    pcie_global_cfg global_cfg;
    pcie_tl_env_config tl_cfg;
    int unsigned host_root[int unsigned];
    int unsigned sent_writes;
    int unsigned decoded_writes;
    int unsigned rejected_writes;

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_pcie_system", uvm_component parent = null);
      super.new(name, parent);
      dpu = null;
      sent_writes = 0;
      decoded_writes = 0;
      rejected_writes = 0;
    endfunction

    // 功能：注册 factory 覆盖（EP 驱动、驱动 BAR）；须在 rdma_dpu_system.build 与本组件 build 之前调用。
    // 输入/输出及副作用：修改 UVM factory。
    // 失败/边界：无。
    static function void install_overrides();
      pcie_tl_ep_driver::type_id::set_type_override(rdma_pcie_ep_driver::get_type());
      rdma_dpu_bar::type_id::set_type_override(rdma_pcie_bar::get_type());
    endfunction

    // 功能：按 dpu 快照建 PCIe 拓扑（每个 Host 一个 RC 与一个 EP，一条 x16 链）、attachment（Function
    //   挂在其 Host 的 EP）、Root 绑定（Host 域 → 同序号 Root），投影为 global_cfg 并建 TLM 环境
    //   （RC/EP active，EP 自动应答，不开 FC/记分板/覆盖率，非统一内存）。
    // 输入/输出及副作用：创建 tl_env；current 指向本组件。
    // 失败/边界：dpu 未 build 或投影失败报告 UVM_FATAL。
    function void build_phase(uvm_phase phase);
      pcie_topology_builder builder;
      pcie_topology_cfg topology;
      pcie_dpu_cfg_adapter adapter;
      pcie_dpu_attachment_cfg attachments;
      pcie_dpu_root_binding_cfg root_bindings;
      int unsigned segment[int unsigned];
      string errors[$];
      string why;
      int unsigned root;

      super.build_phase(phase);
      current = this;
      if (dpu == null || dpu.snapshot == null)
        `uvm_fatal("RDMA_PCIE", "dpu system must be built before the PCIe system")
      foreach (dpu.nodes[i])
        segment[dpu.nodes[i].func.key.host_id] = dpu.nodes[i].func.pcie_id.domain.segment_id;
      builder = pcie_topology_builder::type_id::create("rdma_pcie_topology");
      root = 0;
      foreach (segment[h]) begin
        host_root[h] = root++;
        void'(builder.add_rc($sformatf("RC%0d", h)));
        void'(builder.add_ep($sformatf("EP%0d", h)));
        void'(builder.connect($sformatf("RC%0d_EP%0d", h, h), $sformatf("RC%0d", h),
                              PCIE_TOPO_PORT_RC, 0, $sformatf("EP%0d", h), PCIE_TOPO_PORT_EP, 0,
                              16, 4));
      end
      topology = builder.finish();
      attachments = pcie_dpu_attachment_cfg::type_id::create("rdma_pcie_attachments");
      foreach (dpu.nodes[i]) begin
        if (!attachments.add(dpu.nodes[i].func.key,
                             $sformatf("EP%0d", dpu.nodes[i].func.key.host_id),
                             $sformatf("RC%0d_EP%0d", dpu.nodes[i].func.key.host_id,
                                       dpu.nodes[i].func.key.host_id), 1'b0, 0, why))
          `uvm_fatal("RDMA_PCIE", {"attachment failed: ", why})
      end
      root_bindings = pcie_dpu_root_binding_cfg::type_id::create("rdma_pcie_roots");
      foreach (segment[h])
        if (!root_bindings.bind_domain_to_root(h, segment[h], host_root[h], why))
          `uvm_fatal("RDMA_PCIE", {"root binding failed: ", why})
      adapter = pcie_dpu_cfg_adapter::type_id::create("rdma_pcie_adapter");
      if (!adapter.project_with_root_bindings(dpu.snapshot, null, topology, attachments,
                                              root_bindings, global_cfg, errors)) begin
        foreach (errors[i])
          `uvm_error("RDMA_PCIE", errors[i])
        `uvm_fatal("RDMA_PCIE", "dpu snapshot projection failed")
      end
      tl_cfg = pcie_tl_env_config::type_id::create("rdma_pcie_tl_cfg");
      tl_cfg.if_mode = TLM_MODE;
      tl_cfg.rc_is_active = UVM_ACTIVE;
      tl_cfg.ep_is_active = UVM_ACTIVE;
      tl_cfg.ep_auto_response = 1'b1;
      tl_cfg.fc_enable = 1'b0;
      tl_cfg.scb_enable = 1'b0;
      tl_cfg.cov_enable = 1'b0;
      tl_cfg.use_unified_mem = 1'b0;
      uvm_config_db#(pcie_global_cfg)::set(this, "tl_env", "global_cfg", global_cfg);
      uvm_config_db#(pcie_tl_env_config)::set(this, "tl_env", "tl_policy_cfg", tl_cfg);
      tl_env = pcie_tl_env::type_id::create("tl_env", this);
    endfunction

    // 功能：Host 对应 Root 的 RC 序列器。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：Host 未知报告 UVM_FATAL。
    function uvm_sequencer #(pcie_tl_tlp) rc_seqr(int unsigned host_id);
      if (!host_root.exists(host_id))
        `uvm_fatal("RDMA_PCIE", $sformatf("Host %0d has no PCIe root", host_id))
      return tl_env.v_seqr.rc_seqr_arr[host_root[host_id]];
    endfunction

    // 功能：EP 收到的 MemWr：取 8 字节大端值，依次在各 Host 域内经快照解码，落在某 Function 的 BAR0
    //   内即交给其设备（decoded_writes 加一），否则拒绝（rejected_writes 加一）。
    // 输入/输出及副作用：可能写设备寄存器。
    // 失败/边界：长度不足 8 字节按拒绝计。
    function void deliver_mmio(pcie_tl_mem_tlp req);
      bit [63:0] value;
      dpu_pcie_domain_key_t domains[$];
      bit seen[string];
      rdma_status status;

      value = '0;
      if (req.payload.size() < 8) begin
        rejected_writes++;
        return;
      end
      for (int i = 0; i < 8; i++)
        value = (value << 8) | req.payload[i];
      foreach (dpu.nodes[i]) begin
        if (seen.exists(dpu_pcie_domain_key_name(dpu.nodes[i].func.pcie_id.domain)))
          continue;
        seen[dpu_pcie_domain_key_name(dpu.nodes[i].func.pcie_id.domain)] = 1'b1;
        domains.push_back(dpu.nodes[i].func.pcie_id.domain);
      end
      foreach (domains[d]) begin
        status = dpu.router.write(domains[d], req.addr, value);
        if (status.ok()) begin
          decoded_writes++;
          return;
        end
      end
      rejected_writes++;
    endfunction
  endclass
endpackage
