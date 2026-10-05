// 目录：验证组件层 tb/rdma_wire.sv。
// 职责：节点之间的报文链路：把源 NIC 发出的报文交付到目的 NIC，并经 analysis 端口广播全部报文。
//   默认实现在模型层直接深拷贝交付；子类可覆盖 carry() 让报文经过真实帧编解码（如 net_packet）。
// 依赖：rdma_packet、rdma_nic_model（前向声明）。
// 所有权与生命周期：wire 只保存 NIC 的非拥有引用；交付的是独立副本。
class rdma_wire extends uvm_component;
  `uvm_component_utils(rdma_wire)

  uvm_analysis_port #(rdma_packet) ap;
  protected rdma_nic_model nics[int unsigned];

  // 功能：构造 wire 与 analysis 端口。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_wire", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  // 功能：登记节点的 NIC。
  // 输入/输出及副作用：覆盖同 node_id 的旧登记。
  // 失败/边界：nic 为空时忽略。
  function void attach(int unsigned node_id, rdma_nic_model nic);
    if (nic != null)
      nics[node_id] = nic;
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

  // 功能：从 src_node 向 dst_node 发送一个报文：carry → 广播 → 放入目的 NIC 接收队列。
  // 输入/输出及副作用：写 analysis 端口与目的 NIC mailbox。
  // 失败/边界：目的节点未登记或 carry 失败时报 UVM_ERROR 并丢弃报文。
  task transmit(int unsigned src_node, int unsigned dst_node, rdma_packet packet);
    rdma_packet delivered;
    rdma_status status;

    if (!nics.exists(dst_node)) begin
      `uvm_error("RDMA_WIRE", $sformatf("destination node %0d is not attached", dst_node))
      return;
    end
    carry(src_node, dst_node, packet, delivered, status);
    if (status == null || !status.ok() || delivered == null) begin
      `uvm_error("RDMA_WIRE", $sformatf("wire carry failed: %s",
                 status == null ? "null status" : status.convert2string()))
      return;
    end
    ap.write(delivered);
    nics[dst_node].deliver(delivered);
  endtask
endclass
