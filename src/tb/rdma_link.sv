// 目录：验证组件层 tb/rdma_link.sv。
// 层：验证组件。
// 职责：Function 之间的报文链路。rdma_link 本身即 loopback（深拷贝交付）：NIC 经 rdma_link_port 发包，
//   链路按目的 MAC 找到目的 Function，carry() 传输后交给目的 NIC，并经 tx_ap/rx_ap 广播发出与交付的报文。
//   子类覆盖 carry()：rdma_link_netpkt 让报文经过 net_packet 的 RoCEv2 帧编码与解析。
//   env 按 cfg.link_type 经 factory 创建（rxe 链路在 rxe 包内，tb 不依赖它）。
// 依赖：rdma_res_func（Function 的设备与 MAC）、rdma_dev_port、net_packet 适配器。
// 所有权：链路只借用设备；交付的是独立副本。
// 生命周期：env build 创建，attach() 后对该 Function 生效。

typedef class rdma_link;

// 一个 Function 设备的出口：把 NIC 发送转交给链路。
class rdma_link_port extends rdma_dev_port;
  `rdma_object_utils(rdma_link_port)

  rdma_link link;
  int unsigned src;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_link_port");
    super.new(name);
  endfunction

  // 功能：NIC 发包。
  // 输入/输出及副作用：见 rdma_link.transmit。
  // 失败/边界：同 transmit。
  virtual task send(rdma_packet pkt, bit [47:0] dmac);
    link.transmit(src, pkt, dmac);
  endtask
endclass

class rdma_link extends uvm_component;
  `uvm_component_utils(rdma_link)

  uvm_analysis_port #(rdma_packet) tx_ap;
  uvm_analysis_port #(rdma_packet) rx_ap;
  protected rdma_res_func funcs[int unsigned];
  protected int unsigned func_of_mac[bit [47:0]];

  // 功能：构造链路与 analysis 端口。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_link", uvm_component parent = null);
    super.new(name, parent);
    tx_ap = new("tx_ap", this);
    rx_ap = new("rx_ap", this);
  endfunction

  // 功能：接入 Function：登记 MAC，返回其 NIC 的出口端口。
  // 输入/输出及副作用：覆盖同下标/MAC 的旧登记。
  // 失败/边界：子类准备失败报 UVM_FATAL。
  virtual function rdma_dev_port attach(rdma_res_func f);
    rdma_link_port port;

    funcs[f.index] = f;
    func_of_mac[f.mac] = f.index;
    port = rdma_link_port::type_id::create($sformatf("port%0d", f.index));
    port.link = this;
    port.src = f.index;
    return port;
  endfunction

  // 功能：传输钩子：把报文变成目的端看到的报文（loopback 深拷贝）。
  // 输入/输出及副作用：delivered/status 输出；status 非 OK 时报文丢弃。
  // 失败/边界：子类编解码失败时返回错误。
  virtual task carry(int unsigned src, int unsigned dst, rdma_packet pkt,
                     output rdma_packet delivered, output rdma_status status);
    delivered = rdma_deep_copy#(rdma_packet)::of(pkt, "link packet copy failed");
    status = rdma_status::success();
  endtask

  // 功能：src 向目的 MAC 发包：广播 tx → carry → 广播 rx → 目的 NIC 接收。
  // 输入/输出及副作用：写 analysis 端口与目的 NIC 接收队列。
  // 失败/边界：目的 MAC 未接入或 carry 失败报 UVM_ERROR 并丢弃。
  task transmit(int unsigned src, rdma_packet pkt, bit [47:0] dmac);
    rdma_packet delivered;
    rdma_status status;
    int unsigned dst;

    tx_ap.write(pkt);
    if (!func_of_mac.exists(dmac)) begin
      `uvm_error("RDMA_LINK", $sformatf("destination MAC %012h is not attached", dmac))
      return;
    end
    dst = func_of_mac[dmac];
    carry(src, dst, pkt, delivered, status);
    if (!status.ok() || delivered == null) begin
      `uvm_error("RDMA_LINK", {"carry failed: ", status.convert2string()})
      return;
    end
    rx_ap.write(delivered);
    funcs[dst].node.dev.nic.receive(delivered);
  endtask
endclass

// 报文经 net_packet 编码为 RoCEv2 帧、再由目的端适配器解析（每个 Function 一个适配器，身份取自
//   dpu_common）。
class rdma_link_netpkt extends rdma_link;
  `uvm_component_utils(rdma_link_netpkt)

  protected rdma_net_packet_adapter nets[int unsigned];
  protected rdma_net_packet_queue_sink sinks[int unsigned];

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_link_netpkt", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：接入 Function 并为它建立 net_packet 适配器与接收队列。
  // 输入/输出及副作用：见基类。
  // 失败/边界：身份解析或适配器配置失败报 UVM_FATAL。
  virtual function rdma_dev_port attach(rdma_res_func f);
    rdma_function_identity identity;
    rdma_status status;

    sinks[f.index] = rdma_net_packet_queue_sink::type_id::create($sformatf("sink%0d", f.index));
    nets[f.index] = rdma_net_packet_adapter::type_id::create($sformatf("net%0d", f.index));
    status = nets[f.index].configure_sink(sinks[f.index]);
    if (status.ok())
      status = f.node.func.identity(identity);
    if (status.ok())
      status = nets[f.index].configure_function(identity);
    if (!status.ok())
      `uvm_fatal("RDMA_LINK", {"net_packet attach failed: ", status.convert2string()})
    return super.attach(f);
  endfunction

  // 功能：源适配器编码发帧 → 目的接收队列 → 目的适配器解析。
  // 输入/输出及副作用：见基类。
  // 失败/边界：编码/解析失败经 status 返回。
  virtual task carry(int unsigned src, int unsigned dst, rdma_packet pkt,
                     output rdma_packet delivered, output rdma_status status);
    delivered = null;
    nets[src].send_packet(pkt, status);
    if (!status.ok())
      return;
    sinks[dst].enqueue(nets[src].last_sent_packet);
    nets[dst].receive_packet(delivered, status);
  endtask
endclass
