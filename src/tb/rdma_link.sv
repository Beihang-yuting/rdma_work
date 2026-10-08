// 目录：验证组件层 tb/rdma_link.sv。
// 层：验证组件。
// 职责：Function 之间的报文链路。rdma_link 本身即 loopback（深拷贝交付）：NIC 经 rdma_link_port 发包，
//   链路按目的 MAC 找到目的 Function，carry() 传输后交给目的 NIC，并经 tx_ap/rx_ap 广播发出与交付的报文。
//   故障注入（rdma_link_fault）：按源 Function/opcode 过滤，跳过前 skip 个后对 count 个报文丢弃、复制、
//   延迟（造成乱序）或损坏（接收端校验应丢弃）。
//   子类覆盖 carry()/corrupt()：rdma_link_netpkt 让报文经过 net_packet 的 RoCEv2 帧编码与解析。
//   env 按 cfg.link_type 经 factory 创建（rxe 链路在 rxe 包内，tb 不依赖它）。
// 依赖：rdma_res_func（Function 的设备与 MAC）、rdma_dev_port、rdma_netpkt_codec。
// 所有权：链路只借用设备；交付的是独立副本。
// 生命周期：env build 创建，attach() 后对该 Function 生效。

typedef class rdma_link;

// 链路上观测到的一个报文：源/目的 Function 下标；netpkt 链路另带编码后的帧。
class rdma_link_obs extends uvm_object;
  `uvm_object_utils(rdma_link_obs)

  int unsigned src;
  int unsigned dst;
  rdma_packet pkt;
  byte unsigned frame[$];

  // 功能：构造尚未填充路由和报文的链路观测快照。
  // 输入/输出及副作用：name 为 UVM 名；src/dst 为零初值、pkt 为 null、frame 队列为空，快照不拥有链路。
  // 失败/边界：必须由 observe 填入非空 packet 后才能交给 checker；无帧的 loopback 观测保留空 frame。
  function new(string name = "rdma_link_obs");
    super.new(name);
  endfunction
endclass

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

  // 功能：构造默认 DROP 故障规则：不过滤源/opcode、不跳过、作用一个匹配报文，延迟参数预置 1us。
  // 输入/输出及副作用：name 为 UVM 名；src/opcode=-1、count=1、delay=1us，seen/applied 从零开始。
  // 失败/边界：delay 仅对 DELAY 生效；调用者把 count 设为零会禁用规则，计数只在 hit 中推进。
  function new(string name = "rdma_link_fault");
    super.new(name);
    src = -1;
    opcode = -1;
    count = 1;
    delay = 1us;
  endfunction

  // 功能：按可选源/opcode 过滤候选报文，跳过前 skip 个匹配项，再让至多 count 个命中故障。
  // 输入/输出及副作用：通过过滤的候选推进 seen，实际命中推进 applied 并返回 1；其他情况返回 0。
  // 失败/边界：达到 count 后不再更新计数；opcode 过滤启用时 pkt 必须非空，未通过过滤的报文不计入 skip。
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

  // 功能：构造尚未绑定链路和源 Function 的 NIC 出口端口。
  // 输入/输出及副作用：name 为 UVM 名；link 为非拥有空引用，src 使用零初值，不创建传输线程。
  // 失败/边界：端口只能使用 attach 返回的已绑定实例；直接调用空端口 send 会解引用 null link。
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

  // 源 NIC 发出（故障注入前）与交付给目的 NIC 的报文。
  uvm_analysis_port #(rdma_link_obs) tx_ap;
  uvm_analysis_port #(rdma_link_obs) rx_ap;
  rdma_link_fault faults[$];
  protected rdma_res_func funcs[int unsigned];
  protected int unsigned func_of_mac[bit [47:0]];

  // 功能：构造 loopback 链路及发送/交付两个 analysis port，初始不接入任何 Function 或故障规则。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；本组件拥有 tx_ap/rx_ap 和后续注入的规则引用，
  //   funcs 中的设备引用保持非拥有。
  // 失败/边界：目的 Function 必须先 attach 才能传输；构造阶段不验证 MAC 唯一性或连接 subscriber。
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

  // 功能：每条故障规则都应作用满 count 个报文（否则场景没有测到它）。
  // 输入/输出及副作用：报告。
  // 失败/边界：未作用满报 UVM_ERROR。
  function void report_phase(uvm_phase phase);
    foreach (faults[i])
      if (faults[i].applied < faults[i].count)
        `uvm_error("RDMA_LINK", $sformatf("%s fault (src %0d opcode %0d skip %0d) applied %0d/%0d",
                   faults[i].kind.name(), faults[i].src, faults[i].opcode, faults[i].skip,
                   faults[i].applied, faults[i].count))
  endfunction

  // 功能：把故障规则按优先次序追加到链路，传输时每个报文只执行首条命中的规则。
  // 输入/输出及副作用：保存 f 的非拥有引用到 faults，不克隆也不重置 seen/applied。
  // 失败/边界：f 必须非空且应在流量开始前完成配置；重复注入同一对象会共享计数并可能导致报告歧义。
  function void inject(rdma_link_fault f);
    faults.push_back(f);
  endfunction

  // 功能：src 向目的 MAC 发包：广播 tx → 故障规则 → deliver。
  // 输入/输出及副作用：写 tx_ap；见 deliver。
  // 失败/边界：目的 MAC 未接入报 UVM_ERROR 并丢弃。
  task transmit(int unsigned src, rdma_packet pkt, bit [47:0] dmac);
    rdma_link_fault f;
    int unsigned dst;

    if (!func_of_mac.exists(dmac)) begin
      `uvm_error("RDMA_LINK", $sformatf("destination MAC %012h is not attached", dmac))
      return;
    end
    dst = func_of_mac[dmac];
    tx_ap.write(observe(src, dst, pkt));
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
    rx_ap.write(observe(src, dst, delivered));
    funcs[dst].node.dev.nic.receive(delivered);
  endtask

  // 功能：为指定源、目的与 packet 构造一条 analysis 观测，供子类追加 wire frame。
  // 输入/输出及副作用：返回新建 rdma_link_obs，保存 pkt 非拥有引用；不克隆或发送报文。
  // 失败/边界：调用者必须传入非空 pkt 和已解析的索引；基类 frame 留空，隔离副本由 carry 负责。
  virtual function rdma_link_obs observe(int unsigned src, int unsigned dst, rdma_packet pkt);
    rdma_link_obs o;

    o = rdma_link_obs::type_id::create("obs");
    o.src = src;
    o.dst = dst;
    o.pkt = pkt;
    return o;
  endfunction

  // 功能：损坏报文的传输。loopback 没有帧校验，等同接收端丢弃校验失败的帧。
  // 输入/输出及副作用：无交付。
  // 失败/边界：子类验证接收端确实拒绝损坏的帧。
  virtual task corrupt(int unsigned src, int unsigned dst, rdma_packet pkt);
  endtask
endclass

// 报文经 net_packet 编码为 RoCEv2 帧、再解析回报文后交付（帧地址取 codec 缺省值）。
class rdma_link_netpkt extends rdma_link;
  `uvm_component_utils(rdma_link_netpkt)

  protected rdma_netpkt_codec codec;
  protected byte unsigned carried[$];

  // 功能：构造 net_packet 链路并创建本链路独占的 RoCEv2 codec，初始 carried frame 为空。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；codec 由链路拥有，Function 与 fault 状态沿用空基类。
  // 失败/边界：codec factory override 必须返回非空兼容对象；地址配置使用 codec 默认值或由上层后续设置。
  function new(string name = "rdma_link_netpkt", uvm_component parent = null);
    super.new(name, parent);
    codec = rdma_netpkt_codec::type_id::create("codec");
  endfunction

  // 功能：编码为帧 → 解析回报文。
  // 输入/输出及副作用：见基类；记下帧供观测。
  // 失败/边界：编码/解析失败经 status 返回。
  virtual task carry(int unsigned src, int unsigned dst, rdma_packet pkt,
                     output rdma_packet delivered, output rdma_status status);
    delivered = null;
    status = codec.encode(pkt, carried);
    if (status.ok())
      status = codec.decode(carried, delivered);
  endtask

  // 功能：在基类观测上复制最近一次 carry 生成的 RoCEv2 frame，供 RX 帧级协议规则检查。
  // 输入/输出及副作用：返回新观测并把 carried 值复制到 o.frame，不转移 codec 或队列所有权。
  // 失败/边界：只有紧随成功 carry 的 RX 观测保证 frame 对应该 packet；TX 观测可能携带空或上一帧，
  //   帧规则按设计只消费 RX。
  virtual function rdma_link_obs observe(int unsigned src, int unsigned dst, rdma_packet pkt);
    rdma_link_obs o;

    o = super.observe(src, dst, pkt);
    o.frame = carried;
    return o;
  endfunction

  // 功能：编码后翻转帧中载荷/ICRC 区的一个字节，解析须失败（ICRC 校验），报文丢弃。
  // 输入/输出及副作用：无交付。
  // 失败/边界：损坏帧被接受时报 UVM_ERROR。
  virtual task corrupt(int unsigned src, int unsigned dst, rdma_packet pkt);
    byte unsigned frame[$];
    rdma_packet decoded;

    if (!codec.encode(pkt, frame).ok()) begin
      `uvm_error("RDMA_LINK", "encode failed")
      return;
    end
    frame[frame.size() - 6] ^= 8'h01;
    if (codec.decode(frame, decoded).ok())
      `uvm_error("RDMA_LINK", "corrupted frame passed the receiver's checks")
  endtask
endclass
