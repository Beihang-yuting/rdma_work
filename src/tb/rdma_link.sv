// 目录：验证组件层 tb/rdma_link.sv。
// 层：验证组件。
// 职责：Function 之间的报文链路。rdma_link 本身即 loopback（深拷贝交付）：NIC 经 rdma_link_port 发包，
//   链路按目的 MAC 找到目的 Function，carry() 传输后交给目的 NIC，并经 tx_ap/rx_ap 广播发出与交付的报文。
//   故障注入（rdma_link_fault）：按源 Function/opcode 过滤，跳过前 skip 个后对 count 个报文丢弃、复制、
//   延迟（造成乱序）或损坏（接收端校验应丢弃）。
//   子类覆盖 carry()/corrupt()：rdma_link_netpkt 让报文经过 net_packet 的 RoCEv2 帧编码与解析。
//   env 按 cfg.link_type 经 factory 创建（rxe 链路在 rxe 包内，tb 不依赖它）。
// 依赖：rdma_res_func（Function 的设备与 MAC）、rdma_dev_port、net_packet 适配器。
// 所有权：链路只借用设备；交付的是独立副本。
// 生命周期：env build 创建，attach() 后对该 Function 生效。

typedef class rdma_link;

typedef enum {RDMA_FAULT_DROP, RDMA_FAULT_DUP, RDMA_FAULT_DELAY, RDMA_FAULT_CORRUPT} rdma_fault_e;

// 一条故障规则：src/opcode 为 -1 时不过滤。
class rdma_link_fault extends uvm_object;
  `uvm_object_utils(rdma_link_fault)

  rdma_fault_e kind;
  int src;
  int opcode;
  int unsigned skip;
  int unsigned count;
  time delay;
  int unsigned seen;
  int unsigned applied;

  // 功能：构造（不过滤、不跳过、作用 1 个报文、延迟 1us）。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_link_fault");
    super.new(name);
    src = -1;
    opcode = -1;
    count = 1;
    delay = 1us;
  endfunction

  // 功能：报文是否命中本规则（命中即计数）。
  // 输入/输出及副作用：更新 seen/applied。
  // 失败/边界：无。
  function bit hit(int unsigned from, rdma_packet pkt);
    if ((src >= 0 && from != src) || (opcode >= 0 && int'(pkt.opcode) != opcode) ||
        applied >= count)
      return 1'b0;
    if (seen++ < skip)
      return 1'b0;
    applied++;
    return 1'b1;
  endfunction
endclass

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
  rdma_link_fault faults[$];
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

  // 功能：加入故障规则（按加入顺序匹配，每个报文至多命中一条）。
  // 输入/输出及副作用：追加 faults。
  // 失败/边界：无。
  function void inject(rdma_link_fault f);
    faults.push_back(f);
  endfunction

  // 功能：src 向目的 MAC 发包：广播 tx → 故障规则 → deliver。
  // 输入/输出及副作用：写 tx_ap；见 deliver。
  // 失败/边界：目的 MAC 未接入报 UVM_ERROR 并丢弃。
  task transmit(int unsigned src, rdma_packet pkt, bit [47:0] dmac);
    rdma_link_fault f;
    int unsigned dst;

    tx_ap.write(pkt);
    if (!func_of_mac.exists(dmac)) begin
      `uvm_error("RDMA_LINK", $sformatf("destination MAC %012h is not attached", dmac))
      return;
    end
    dst = func_of_mac[dmac];
    foreach (faults[i])
      if (f == null && faults[i].hit(src, pkt))
        f = faults[i];
    if (f == null) begin
      deliver(src, dst, pkt);
      return;
    end
    `uvm_info("RDMA_LINK", $sformatf("%s f%0d->f%0d %s psn %06h", f.kind.name(), src, dst,
              pkt.opcode.name(), pkt.psn), UVM_MEDIUM)
    case (f.kind)
      RDMA_FAULT_DUP: begin
        deliver(src, dst, pkt);
        deliver(src, dst, pkt);
      end
      RDMA_FAULT_DELAY:
        fork
          begin
            #(f.delay);
            deliver(src, dst, pkt);
          end
        join_none
      RDMA_FAULT_CORRUPT: corrupt(src, dst, pkt);
      default: ;
    endcase
  endtask

  // 功能：交付：carry → 广播 rx → 目的 NIC 接收。
  // 输入/输出及副作用：写 rx_ap 与目的 NIC 接收队列。
  // 失败/边界：carry 失败报 UVM_ERROR 并丢弃。
  virtual task deliver(int unsigned src, int unsigned dst, rdma_packet pkt);
    rdma_packet delivered;
    rdma_status status;

    carry(src, dst, pkt, delivered, status);
    if (!status.ok() || delivered == null) begin
      `uvm_error("RDMA_LINK", {"carry failed: ", status.convert2string()})
      return;
    end
    rx_ap.write(delivered);
    funcs[dst].node.dev.nic.receive(delivered);
  endtask

  // 功能：损坏报文的传输。loopback 没有帧校验，等同接收端丢弃校验失败的帧。
  // 输入/输出及副作用：无交付。
  // 失败/边界：子类验证接收端确实拒绝损坏的帧。
  virtual task corrupt(int unsigned src, int unsigned dst, rdma_packet pkt);
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

  // 功能：编码后翻转帧中载荷/ICRC 区的一个字节，目的适配器解析须失败（ICRC 校验），报文丢弃。
  // 输入/输出及副作用：无交付。
  // 失败/边界：损坏帧被接受时报 UVM_ERROR。
  virtual task corrupt(int unsigned src, int unsigned dst, rdma_packet pkt);
    byte unsigned frame[$];
    rdma_packet decoded;

    if (!nets[src].encode_packet(pkt, frame).ok()) begin
      `uvm_error("RDMA_LINK", "encode failed")
      return;
    end
    frame[frame.size() - 6] ^= 8'h01;
    if (nets[dst].decode_packet(frame, decoded).ok())
      `uvm_error("RDMA_LINK", "corrupted frame passed the receiver's checks")
  endtask
endclass
