// 目录：验证组件层 tb/rdma_wire.sv。
// 层：验证组件。
// 职责：节点之间的报文链路：设备 NIC 经 rdma_wire_port 发出报文，wire 按目的 MAC 找到目的节点，
//   经 carry() 传输后交给目的 NIC，并经 analysis 端口广播全部报文。默认 carry 深拷贝；
//   子类可覆盖 carry() 让报文经过真实帧编解码（如 net_packet）。
// 依赖：rdma_packet、rdma_dev（NIC 接收入口）、rdma_dev_port。
// 所有权：wire 只保存设备的非拥有引用；交付的是独立副本。
// 生命周期：env 建立时创建，attach() 后对该节点生效。

typedef class rdma_wire;

// 一个节点设备的出口：把 NIC 发送转交给 wire。
class rdma_wire_port extends rdma_dev_port;
  `rdma_object_utils(rdma_wire_port)

  rdma_wire fabric;
  int unsigned src_node;

  // 功能：构造端口。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_wire_port");
    super.new(name);
    fabric = null;
    src_node = 0;
  endfunction

  // 功能：NIC 发包：交给 wire 按目的 MAC 投递。
  // 输入/输出及副作用：见 rdma_wire.transmit。
  // 失败/边界：同 transmit。
  virtual task send(rdma_packet pkt, bit [47:0] dmac);
    fabric.transmit(src_node, pkt, dmac);
  endtask
endclass

class rdma_wire extends uvm_component;
  `uvm_component_utils(rdma_wire)

  uvm_analysis_port #(rdma_packet) ap;
  protected rdma_dev devs[int unsigned];
  protected int unsigned node_of_mac[bit [47:0]];

  // 功能：构造 wire 与 analysis 端口。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_wire", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  // 功能：登记节点设备与 MAC，返回该节点 NIC 应使用的出口端口。
  // 输入/输出及副作用：覆盖同 node_id/MAC 的旧登记。
  // 失败/边界：无。
  function rdma_dev_port attach(int unsigned node_id, rdma_dev dev, bit [47:0] mac);
    rdma_wire_port port;

    devs[node_id] = dev;
    node_of_mac[mac] = node_id;
    port = rdma_wire_port::type_id::create($sformatf("port%0d", node_id));
    port.fabric = this;
    port.src_node = node_id;
    return port;
  endfunction

  // 功能：链路传输钩子：把报文变成目的端看到的报文。默认深拷贝。
  // 输入/输出及副作用：delivered 输出；status 输出非 OK 时报文丢弃。
  // 失败/边界：子类可在编解码失败时返回错误。
  virtual task carry(
    int unsigned src_node,
    int unsigned dst_node,
    rdma_packet packet,
    output rdma_packet delivered,
    output rdma_status status
  );
    delivered = rdma_deep_copy#(rdma_packet)::of(packet, "wire packet copy failed");
    status = rdma_status::success();
  endtask

  // 功能：从 src_node 向目的 MAC 发送一个报文：carry → 广播 → 目的 NIC 接收。
  // 输入/输出及副作用：写 analysis 端口与目的 NIC 接收队列。
  // 失败/边界：目的 MAC 未登记或 carry 失败时报 UVM_ERROR 并丢弃报文。
  task transmit(int unsigned src_node, rdma_packet packet, bit [47:0] dmac);
    rdma_packet delivered;
    rdma_status status;
    int unsigned dst_node;

    if (!node_of_mac.exists(dmac)) begin
      `uvm_error("RDMA_WIRE", $sformatf("destination MAC %012h is not attached", dmac))
      return;
    end
    dst_node = node_of_mac[dmac];
    carry(src_node, dst_node, packet, delivered, status);
    if (status == null || !status.ok() || delivered == null) begin
      `uvm_error("RDMA_WIRE", $sformatf("wire carry failed: %s",
                 status == null ? "null status" : status.convert2string()))
      return;
    end
    ap.write(delivered);
    devs[dst_node].nic.receive(delivered);
  endtask
endclass
