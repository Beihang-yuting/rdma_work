// 目录：外部适配器实现层 adapters/pcie_work/rdma_pcie_work_pkg.sv。
// 层：外部适配器。
// 职责：MMIO 与设备 DMA 经 pcie_work 传输：dpu_common 快照（rdma_dpu_system）→ PCIe 拓扑（每个 Host
//   一条 RC↔EP 链）→ pcie_dpu_cfg_adapter 投影 → pcie_tl_env（TLM，统一内存）。
//   MMIO：驱动 BAR 写成为所属 Host 的 RC 上的 MemWr TLP（BAR0 基址 + 偏移，8 字节大端）；EP 收到后
//   排队，由 MMIO 工作进程按到达顺序经快照解码（rdma_dpu_bar_router）交给所属 Function 的设备，非 BAR0
//   或不在任何 BAR 的写被拒绝并计数。
//   DMA：设备 DMA 端口（rdma_pcie_dma）在所属 Host 的 EP 上发 MemRd/MemWr（requester ID = Function
//   BDF，按 MRRS/MPS 切分且不跨 4KB），RC 以绑定到该 Root 的 Host host_mem 应答（无 IOMMU，IOVA 即
//   host_mem 地址）。
// 依赖：pcie_work（pcie_tl_pkg、pcie_topology_pkg、pcie_dpu_integration_pkg）、host_mem_pkg、
//   dpu_common、rdma_dpu_adapter_pkg、rdma_dev_pkg。
// 所有权：rdma_pcie_system 持有 pcie_tl_env；rdma_dpu_system 与各 Host 的 host_mem 由测试创建并交给它。
// 生命周期：UVM 组件，build_phase 建立。
package rdma_pcie_work_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import dpu_resource_pkg::*;
  import host_mem_pkg::*;
  import pcie_tl_pkg::*;
  import pcie_topology_pkg::*;
  import pcie_dpu_integration_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_dpu_adapter_pkg::*;

  typedef class rdma_pcie_system;

  // EP 发起的读写序列：在发出前把 requester ID 置为 Function 的 BDF（基类随机化后、驱动分配 tag 前）。
  class rdma_pcie_dma_seq extends pcie_tl_rw_seq;
    `uvm_object_utils(rdma_pcie_dma_seq)

    bit [15:0] requester_id;

    // 功能：构造。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_pcie_dma_seq");
      super.new(name);
      requester_id = '0;
    endfunction

    // 功能：finish_item 发出前的回调：写入 requester ID。
    // 输入/输出及副作用：修改待发 TLP。
    // 失败/边界：非 TLP 对象忽略。
    virtual function void mid_do(uvm_sequence_item this_item);
      pcie_tl_tlp tlp;

      if ($cast(tlp, this_item))
        tlp.requester_id = requester_id;
    endfunction
  endclass

  // RC 驱动：记录 EP 发来的 DMA 请求（按 requester ID 计数）后按统一内存应答。
  class rdma_pcie_rc_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(rdma_pcie_rc_driver)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_pcie_rc_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：EP→RC 请求：MemRd/MemWr 计入 rdma_pcie_system 的 RC 侧观测，再交基类（读 host_mem 回 CplD
    //   或写 host_mem）。
    // 输入/输出及副作用：更新计数。
    // 失败/边界：系统未建立时只走基类。
    virtual task handle_request(pcie_tl_tlp req);
      if (rdma_pcie_system::current != null)
        rdma_pcie_system::current.note_host_request(req);
      super.handle_request(req);
    endtask
  endclass

  // 设备 DMA 端口：在所属 Host 的 EP 上发 MemRd/MemWr。
  class rdma_pcie_dma extends rdma_dev_dma;
    `uvm_object_utils(rdma_pcie_dma)

    // pcie_tl_mem_tlp 的 LEGAL 约束：MemWr 负载 ≤ MPS，MemRd ≤ MRRS，且都不跨 4KB。
    localparam int unsigned MPS_BYTES = 256;
    localparam int unsigned MRRS_BYTES = 512;

    rdma_dpu_function func;

    // 功能：构造未绑定 Function 的端口。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：rdma_pcie_system 建立时绑定 func。
    function new(string name = "rdma_pcie_dma");
      super.new(name);
      func = null;
    endfunction

    // 功能：按 IOVA 读 size 字节：按 MRRS 对齐边界切成多个 MemRd，逐个等 CplD。
    // 输入/输出及副作用：bytes 输出；在 EP 上发请求，消耗仿真时间。
    // 失败/边界：未绑定、读超时或 Completion 状态非 SC 返回 DMA_TRANSLATION/INVALID_STATE。
    virtual task read(bit [63:0] iova, int unsigned size, output byte unsigned bytes[],
                      output rdma_status status);
      rdma_pcie_dma_seq seq;
      bit [63:0] addr;
      int unsigned take;

      bytes = new[0];
      if (!bound(status))
        return;
      addr = iova;
      while (addr < iova + size) begin
        take = chunk(addr, iova + size, MRRS_BYTES);
        seq = new_seq(PCIE_RW_READ, addr, take);
        seq.start(rdma_pcie_system::current.ep_seqr(func.key.host_id));
        if (seq.status != PCIE_RW_OK) begin
          status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                     $sformatf("PCIe MemRd %016h+%0d failed: %s", addr, take,
                                               seq.status.name()));
          return;
        end
        bytes = new[bytes.size() + take](bytes);
        foreach (seq.rdata[i])
          bytes[addr - iova + i] = seq.rdata[i];
        rdma_pcie_system::current.dma_read_tlps++;
        addr += take;
      end
      status = rdma_status::success();
    endtask

    // 功能：按 IOVA 写 bytes：按 MPS 对齐边界切成多个 MemWr（posted，发出即返回）。
    // 输入/输出及副作用：在 EP 上发请求。
    // 失败/边界：未绑定返回 INVALID_STATE。
    virtual task write(bit [63:0] iova, byte unsigned bytes[], output rdma_status status);
      rdma_pcie_dma_seq seq;
      bit [63:0] addr;
      int unsigned take;

      if (!bound(status))
        return;
      addr = iova;
      while (addr < iova + bytes.size()) begin
        take = chunk(addr, iova + bytes.size(), MPS_BYTES);
        seq = new_seq(PCIE_RW_WRITE, addr, take);
        seq.wdata = new[take];
        foreach (seq.wdata[i])
          seq.wdata[i] = bytes[addr - iova + i];
        seq.start(rdma_pcie_system::current.ep_seqr(func.key.host_id));
        rdma_pcie_system::current.dma_write_tlps++;
        addr += take;
      end
      status = rdma_status::success();
    endtask

    // 功能：端口是否已绑定 Function 且 PCIe 系统已建立。
    // 输入/输出及副作用：未绑定时 status 输出 INVALID_STATE。
    // 失败/边界：无。
    protected function bit bound(output rdma_status status);
      status = rdma_status::success();
      if (func != null && rdma_pcie_system::current != null)
        return 1'b1;
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "PCIe DMA port is not bound");
      return 1'b0;
    endfunction

    // 功能：从 addr 起到下一个 limit 对齐边界（或 last）的字节数。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：无。
    protected function int unsigned chunk(bit [63:0] addr, bit [63:0] last, int unsigned limit);
      bit [63:0] boundary;

      boundary = (addr / limit + 1) * limit;
      return (boundary < last ? boundary : last) - addr;
    endfunction

    // 功能：新建一个带本 Function requester ID 的读写序列。
    // 输入/输出及副作用：返回新序列。
    // 失败/边界：无。
    protected function rdma_pcie_dma_seq new_seq(pcie_rw_op_e op, bit [63:0] addr,
                                                 int unsigned len);
      rdma_pcie_dma_seq seq;

      seq = rdma_pcie_dma_seq::type_id::create("rdma_dma");
      seq.op = op;
      seq.addr = addr;
      seq.byte_len = len;
      seq.requester_id = func.pcie_id.bdf;
      return seq;
    endfunction
  endclass

  // EP 驱动：MemWr 排入 rdma_pcie_system 的 MMIO 队列；其余请求按 pcie_tl_ep_driver 处理。
  class rdma_pcie_ep_driver extends pcie_tl_ep_driver;
    `uvm_component_utils(rdma_pcie_ep_driver)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_pcie_ep_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：EP 收到请求：MemWr 排入 rdma_pcie_system 的 MMIO 队列（不在本进程执行：同一链路的 CplD 也
    //   经本进程送达，设备 DMA 需要它们）；其余（MemRd、Cfg 等）走基类。
    // 输入/输出及副作用：入队。
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
    // 每个 Host 的主机内存（host_id → manager），绑定到该 Host 的 Root 作为 RC 统一内存。
    host_mem_api host_mems[int unsigned];
    int unsigned sent_writes;
    int unsigned decoded_writes;
    int unsigned rejected_writes;
    // 观测：EP 发出的 DMA TLP 数；RC 收到的 DMA 请求数与按 requester ID 的分布。
    int unsigned dma_read_tlps;
    int unsigned dma_write_tlps;
    int unsigned host_reads;
    int unsigned host_writes;
    int unsigned host_requesters[bit [15:0]];
    protected mailbox #(pcie_tl_mem_tlp) mmio_q;

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_pcie_system", uvm_component parent = null);
      super.new(name, parent);
      dpu = null;
      sent_writes = 0;
      decoded_writes = 0;
      rejected_writes = 0;
      dma_read_tlps = 0;
      dma_write_tlps = 0;
      host_reads = 0;
      host_writes = 0;
      mmio_q = new();
    endfunction

    // 功能：注册 factory 覆盖（EP/RC 驱动、驱动 BAR、设备 DMA 端口）；须在 rdma_dpu_system.build 与
    //   本组件 build 之前调用。
    // 输入/输出及副作用：修改 UVM factory。
    // 失败/边界：无。
    static function void install_overrides();
      pcie_tl_ep_driver::type_id::set_type_override(rdma_pcie_ep_driver::get_type());
      pcie_tl_rc_driver::type_id::set_type_override(rdma_pcie_rc_driver::get_type());
      rdma_dpu_bar::type_id::set_type_override(rdma_pcie_bar::get_type());
      rdma_dev_dma::type_id::set_type_override(rdma_pcie_dma::get_type());
    endfunction

    // 功能：按 dpu 快照建 PCIe 拓扑（每个 Host 一个 RC 与一个 EP，一条 x16 链）、attachment（Function
    //   挂在其 Host 的 EP）、Root 绑定（Host 域 → 同序号 Root），投影为 global_cfg 并建 TLM 环境
    //   （RC/EP active，EP 自动应答，不开 FC/记分板/覆盖率；统一内存：各 Root 绑定其 Host 的
    //   host_mem）；把各设备的 DMA 端口绑定到其 Function。
    // 输入/输出及副作用：创建 tl_env；current 指向本组件。
    // 失败/边界：dpu 未 build、Host 缺 host_mem、DMA 端口不是 rdma_pcie_dma 或投影/绑定失败报告
    //   UVM_FATAL。
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
      rdma_pcie_dma port;

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
      tl_cfg.use_unified_mem = 1'b1;
      foreach (segment[h]) begin
        if (!host_mems.exists(h))
          `uvm_fatal("RDMA_PCIE", $sformatf("Host %0d has no host_mem for PCIe DMA", h))
        if (!tl_cfg.bind_host_memory(host_root[h], h, host_mems[h], why))
          `uvm_fatal("RDMA_PCIE", {"host memory binding failed: ", why})
      end
      foreach (dpu.nodes[i]) begin
        if (!$cast(port, dpu.nodes[i].dev.cmq.dma))
          `uvm_fatal("RDMA_PCIE", "device DMA port is not rdma_pcie_dma (install_overrides first)")
        port.func = dpu.nodes[i].func;
      end
      uvm_config_db#(pcie_global_cfg)::set(this, "tl_env", "global_cfg", global_cfg);
      uvm_config_db#(pcie_tl_env_config)::set(this, "tl_env", "tl_policy_cfg", tl_cfg);
      tl_env = pcie_tl_env::type_id::create("tl_env", this);
    endfunction

    // 功能：启动 MMIO 工作进程。
    // 输入/输出及副作用：永久循环。
    // 失败/边界：无。
    task run_phase(uvm_phase phase);
      pcie_tl_mem_tlp req;

      forever begin
        mmio_q.get(req);
        dispatch_mmio(req);
      end
    endtask

    // 功能：Host 对应 Root 的 RC 序列器。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：Host 未知报告 UVM_FATAL。
    function uvm_sequencer #(pcie_tl_tlp) rc_seqr(int unsigned host_id);
      if (!host_root.exists(host_id))
        `uvm_fatal("RDMA_PCIE", $sformatf("Host %0d has no PCIe root", host_id))
      return tl_env.v_seqr.rc_seqr_arr[host_root[host_id]];
    endfunction

    // 功能：Host 对应 Root 的链路上 EP 的序列器（设备 DMA 由此发出）。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：Host 未知报告 UVM_FATAL。
    function uvm_sequencer #(pcie_tl_tlp) ep_seqr(int unsigned host_id);
      if (!host_root.exists(host_id))
        `uvm_fatal("RDMA_PCIE", $sformatf("Host %0d has no PCIe endpoint", host_id))
      return tl_env.v_seqr.ep_seqr_arr[host_root[host_id]];
    endfunction

    // 功能：EP 收到的 MemWr 入队，由 run_phase 的工作进程按到达顺序分派。
    // 输入/输出及副作用：入队。
    // 失败/边界：无。
    function void deliver_mmio(pcie_tl_mem_tlp req);
      void'(mmio_q.try_put(req));
    endfunction

    // 功能：RC 收到 EP 的 DMA 请求：按类型与 requester ID 计数。
    // 输入/输出及副作用：更新观测计数。
    // 失败/边界：非 MemRd/MemWr 忽略。
    function void note_host_request(pcie_tl_tlp req);
      if (!(req.kind inside {TLP_MEM_RD, TLP_MEM_WR}))
        return;
      if (req.kind == TLP_MEM_RD)
        host_reads++;
      else
        host_writes++;
      if (!host_requesters.exists(req.requester_id))
        host_requesters[req.requester_id] = 0;
      host_requesters[req.requester_id]++;
    endfunction

    // 功能：一个 MemWr：取 8 字节大端值，依次在各 Host 域内经快照解码，落在某 Function 的 BAR0
    //   内即交给其设备（decoded_writes 加一，设备处理可能经 PCIe DMA 消耗时间），否则拒绝
    //   （rejected_writes 加一）。
    // 输入/输出及副作用：可能写设备寄存器。
    // 失败/边界：长度不足 8 字节按拒绝计。
    protected task dispatch_mmio(pcie_tl_mem_tlp req);
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
        dpu.router.write(domains[d], req.addr, value, status);
        if (status.ok()) begin
          decoded_writes++;
          return;
        end
      end
      rejected_writes++;
    endtask
  endclass
endpackage
