// 目录/层次：tests/unit；TX-only 数据面链路 fixture。
// 职责：复用 rdma_link_netpkt 的 QP 属性和 RoCEv2 编解码，只把设备发出的完整帧发布给链路 monitor，
//   不查找或驱动目的 Function，因此 UD TX 用例不会隐式创建接收端或产生 ACK。
// 依赖：rdma_env_pkg 中的 rdma_link_netpkt、rdma_link_obs 和 rdma_netpkt_codec。
// 所有权/生命周期：link 拥有继承的 codec/carried 状态；Function/QP 仍由 rdma_env 和资源库拥有，fixture 只保存非拥有引用。

class rdma_tx_capture_link extends rdma_link_netpkt;
  `uvm_component_utils(rdma_tx_capture_link)

  // 功能：构造只发布 TX wire frame 的 net_packet 链路。
  // 输入/输出及副作用：name/parent 传给 rdma_link_netpkt；复用其 codec 和观测端口，不创建目的节点。
  // 失败/边界：codec factory 不兼容时沿用父类创建阶段的失败；构造后必须由 rdma_env.attach Function 才能解析 QP 属性。
  function new(string name = "rdma_tx_capture_link", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：把源 Function 发出的 packet 编码为 RoCEv2 frame 并发布 TX 观测，不执行 loopback 交付。
  // 输入/输出及副作用：src/pkt 只读；更新 codec/carried 并写 tx_ap，dmac 仅为接口兼容而不参与目的查找。
  // 失败/边界：编码失败报告 UVM_ERROR 且不发布帧；无论 dmac 是否已 attach 都不会生成 RX 或 ACK。
  virtual task transmit(int unsigned src, rdma_packet pkt, bit [47:0] dmac);
    rdma_status status;

    apply_qp_attrs(src, pkt);
    status = codec.encode(pkt, carried);
    if (status == null || !status.ok()) begin
      `uvm_error("RDMA_TX", $sformatf("TX frame encode failed: %s",
                                       status == null ? "null" : status.convert2string()))
      return;
    end
    tx_ap.write(observe(src, src, pkt));
  endtask
endclass
