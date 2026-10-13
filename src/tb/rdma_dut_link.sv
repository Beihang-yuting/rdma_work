// 目录：验证组件层 tb/rdma_dut_link.sv。
// 层次：真实 DUT 网络边界适配层。
// 职责：定义外部原始 Ethernet frame endpoint、可供单元测试使用的 memory endpoint，以及
//   rdma_dut_link。该 link 复用 rdma_link 的模型 Function 路由和观测端口，但把发往 DUT
//   的报文编码成独立 frame，通过 endpoint 发送；DUT TX frame 只解码并发布观测，不伪造模型 NIC。
// 依赖：rdma_link.sv、rdma_netpkt_pkg、rdma_dut_link_snapshot、UVM。
// 所有权与生命周期：endpoint 由外部 plugin 或测试拥有；link 仅保存非拥有 endpoint 引用。
//   memory endpoint 自己拥有收发 mailbox，停止时通过关闭标记唤醒 poll；每个观测拥有独立 frame 副本。

// 一个 endpoint frame 载体；close_marker 只用于唤醒停止中的 poll，不会被交给 codec。
class rdma_dut_frame extends uvm_object;
  `uvm_object_utils(rdma_dut_frame)

  int unsigned port;
  bit close_marker;
  byte unsigned bytes[$];

  // 功能：构造空的 endpoint frame 载体，用于保存端口、关闭标志和原始字节副本。
  // 输入/输出及副作用：name 传给 UVM；port/close_marker 清零，bytes 为空；不取得 endpoint 所有权。
  // 失败/边界：构造不会校验端口或帧长度；调用者在入队前必须明确设置 close_marker 或 bytes。
  function new(string name = "rdma_dut_frame");
    super.new(name);
    port = 0;
    close_marker = 1'b0;
    bytes.delete();
  endfunction

  // 功能：复制端口和 frame 字节，形成与输入队列无别名的 endpoint 消息。
  // 输入/输出及副作用：from_port/from_bytes 为输入；覆盖本对象字段并清除旧字节，不修改输入队列。
  // 失败/边界：空字节队列表示合法的零长度载体但不能作为 Ethernet frame 交给 codec。
  function void set_frame(int unsigned from_port, byte unsigned from_bytes[$]);
    port = from_port;
    close_marker = 1'b0;
    bytes = from_bytes;
  endfunction
endclass

// 真实网络、TAP、VPI/VHPI 或厂商 VIP 的最小契约。实现负责外部句柄和生命周期，link 不拥有它。
virtual class rdma_dut_frame_endpoint extends uvm_object;
  bit started;
  bit stopped;

  // 功能：构造尚未启动的外部 frame endpoint 基对象。
  // 输入/输出及副作用：name 传给 UVM；started/stopped 初始化为 0；不创建外部端口或线程。
  // 失败/边界：抽象基类不能直接用于收发；派生 endpoint 必须实现 send_to_dut/poll_from_dut。
  function new(string name = "rdma_dut_frame_endpoint");
    super.new(name);
    started = 1'b0;
    stopped = 1'b0;
  endfunction

  // 功能：启动 endpoint 的外部资源和收发边界。
  // 输入/输出及副作用：更新 started/stopped 并返回状态；默认实现只建立逻辑生命周期，不打开外部资源。
  // 失败/边界：重复启动幂等成功；已停止 endpoint 不允许重新启动，需创建新 endpoint 或由插件复位。
  virtual function rdma_status start();
    if (stopped)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DUT frame endpoint cannot restart after stop");
    started = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：停止 endpoint 并关闭外部收发边界。
  // 输入/输出及副作用：设置 stopped=1、started=0；默认实现不释放调用方拥有的外部句柄。
  // 失败/边界：重复 stop 幂等成功；具体外部资源释放由 endpoint/plugin 覆盖实现完成。
  virtual function rdma_status stop();
    started = 1'b0;
    stopped = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：把原始 Ethernet frame 注入真实 DUT RX 端口。
  // 输入/输出及副作用：port/frame 为输入，status 为 endpoint 发送结果；不得修改 frame 或重算 ICRC。
  // 失败/边界：未 start、端口关闭、背压或外部错误必须返回非 OK；失败帧不能被 link 当作已发送。
  pure virtual task send_to_dut(input int unsigned port,
                                input byte unsigned frame[$],
                                output rdma_status status);

  // 功能：从真实 DUT TX 端口取出一帧原始 Ethernet frame。
  // 输入/输出及副作用：port 为输入，frame/status 为输出；阻塞或轮询行为由 endpoint 实现决定。
  // 失败/边界：正常 stop 必须返回可识别的 INVALID_STATE；短帧或非 RoCE frame 交给 link decode 处理。
  pure virtual task poll_from_dut(input int unsigned port,
                                  output byte unsigned frame[$],
                                  output rdma_status status);
endclass

// memory endpoint 是单元测试替身：to_dut 保存模型注入 DUT 的帧，from_dut 接收测试注入的 DUT TX 帧。
class rdma_memory_frame_endpoint extends rdma_dut_frame_endpoint;
  `uvm_object_utils(rdma_memory_frame_endpoint)

  mailbox #(rdma_dut_frame) to_dut;
  mailbox #(rdma_dut_frame) from_dut;

  // 功能：构造带双向 mailbox 的 memory endpoint。
  // 输入/输出及副作用：name 传给 UVM；创建独立 to_dut/from_dut 队列，不连接真实 DUT。
  // 失败/边界：队列无界但由测试负责消费；endpoint 未 start 前注入和发送均返回 INVALID_STATE。
  function new(string name = "rdma_memory_frame_endpoint");
    super.new(name);
    to_dut = new();
    from_dut = new();
  endfunction

  // 功能：停止 memory endpoint，并放入关闭标记唤醒正在 poll 的接收线程。
  // 输入/输出及副作用：更新生命周期并向 from_dut 追加一个 close marker；重复 stop 不重复入队。
  // 失败/边界：已有 frame 仍按 FIFO 先交付；关闭标记被取出后 poll 返回 INVALID_STATE。
  virtual function rdma_status stop();
    rdma_dut_frame marker;
    rdma_status status;

    if (stopped)
      return rdma_status::success();
    status = super.stop();
    marker = rdma_dut_frame::type_id::create("endpoint_close");
    marker.close_marker = 1'b1;
    from_dut.put(marker);
    return status;
  endfunction

  // 功能：把模型送往 DUT 的 frame 复制到 to_dut mailbox。
  // 输入/输出及副作用：成功时追加独立 frame 对象并返回 OK；不修改调用方 frame。
  // 失败/边界：未 start、已 stop 或空 frame 返回对应错误；端口值由 link 绑定校验，endpoint 不改写。
  virtual task send_to_dut(input int unsigned port,
                           input byte unsigned frame[$],
                           output rdma_status status);
    rdma_dut_frame item;

    status = rdma_status::success();
    if (!started || stopped) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "memory endpoint is not running");
      return;
    end
    if (frame.size() == 0) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "cannot send an empty Ethernet frame");
      return;
    end
    item = rdma_dut_frame::type_id::create("to_dut_frame");
    item.set_frame(port, frame);
    to_dut.put(item);
  endtask

  // 功能：从 from_dut mailbox 取出 DUT TX frame，并复制给 link 的接收线程。
  // 输入/输出及副作用：成功时 frame 获得独立字节队列；关闭标记返回 INVALID_STATE 且不输出数据。
  // 失败/边界：端口不匹配、关闭或空消息返回错误；阻塞等待由 mailbox 保证不会忙等。
  virtual task poll_from_dut(input int unsigned port,
                             output byte unsigned frame[$],
                             output rdma_status status);
    rdma_dut_frame item;

    frame.delete();
    from_dut.get(item);
    if (item == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "memory endpoint returned a null frame");
      return;
    end
    if (item.close_marker || stopped) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "memory endpoint is closed");
      return;
    end
    if (item.port != port) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "memory endpoint port mismatch");
      return;
    end
    frame = item.bytes;
    status = rdma_status::success();
  endtask

  // 功能：向 memory endpoint 注入一帧模拟 DUT TX，供 rdma_dut_link 接收线程消费。
  // 输入/输出及副作用：成功时复制 frame 到 from_dut；返回状态，不触碰真实网络。
  // 失败/边界：未 start、已 stop 或空 frame 被拒绝；调用者负责保证注入端口与 link 绑定端口一致。
  function rdma_status inject_dut_tx(int unsigned port, byte unsigned frame[$]);
    rdma_dut_frame item;

    if (!started || stopped)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "memory endpoint is not running");
    if (frame.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "cannot inject an empty Ethernet frame");
    item = rdma_dut_frame::type_id::create("from_dut_frame");
    item.set_frame(port, frame);
    from_dut.put(item);
    return rdma_status::success();
  endfunction

  // 功能：非阻塞取出一帧已发送给 DUT 的 frame，供单元测试检查字节保真和路由端口。
  // 输入/输出及副作用：成功时 frame 获得独立副本并返回 1；无帧或关闭时返回 0，不阻塞。
  // 失败/边界：port 不匹配的消息被取出并返回 0；测试应先调用 start 再检查发送结果。
  function bit try_pop_to_dut(int unsigned port, output byte unsigned frame[$]);
    rdma_dut_frame item;

    frame.delete();
    if (!to_dut.try_get(item) || item == null || item.close_marker || item.port != port)
      return 1'b0;
    frame = item.bytes;
    return 1'b1;
  endfunction
endclass

// 真实 DUT link 的目的端哨兵；模型 Function 下标从零开始，不与该值冲突。
localparam int unsigned RDMA_DUT_LINK_DST = '1;

class rdma_dut_link extends rdma_link;
  `uvm_component_utils(rdma_dut_link)

  protected rdma_dut_frame_endpoint endpoint;
  protected rdma_dut_link_snapshot snapshot;
  protected rdma_netpkt_codec codec;
  protected int unsigned dut_port;
  protected bit [47:0] dut_mac;
  protected bit endpoint_bound;
  protected bit running;
  protected bit receiver_active;

  int unsigned tx_frames_sent;
  int unsigned rx_frames_captured;
  int unsigned endpoint_errors;
  int unsigned decode_errors;
  int unsigned fault_drops;

  // 功能：构造真实 DUT link，创建独立 RoCEv2 codec，初始不绑定 endpoint 或 route。
  // 输入/输出及副作用：name/parent 建立 UVM 组件；计数器和运行标志清零；不打开外部端口。
  // 失败/边界：必须在 run_phase 前调用 bind_endpoint；未绑定 endpoint 的 DUT link 会在启动时报告 fatal。
  function new(string name = "rdma_dut_link", uvm_component parent = null);
    super.new(name, parent);
    codec = rdma_netpkt_codec::type_id::create("dut_codec");
    endpoint = null;
    snapshot = null;
    dut_port = 0;
    dut_mac = '0;
    endpoint_bound = 1'b0;
    running = 1'b0;
    receiver_active = 1'b0;
    tx_frames_sent = 0;
    rx_frames_captured = 0;
    endpoint_errors = 0;
    decode_errors = 0;
    fault_drops = 0;
  endfunction

  // 功能：绑定 resolver 生成的冻结 DUT link snapshot，保存 source/epoch/path 只读校验视图。
  // 输入/输出及副作用：snapshot 成功校验后保存非拥有引用；不创建 endpoint 或修改 snapshot 字段。
  // 失败/边界：运行中、空 snapshot、snapshot 未冻结/route 非法时拒绝；重复绑定不同 snapshot 拒绝。
  function rdma_status bind_snapshot(rdma_dut_link_snapshot value);
    rdma_status status;

    if (running)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "cannot bind snapshot while DUT link is running");
    if (value == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DUT link snapshot is null");
    status = value.validate();
    if (!status.ok())
      return status;
    if (snapshot != null && snapshot != value)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY, "DUT link snapshot is already bound");
    snapshot = value;
    return rdma_status::success();
  endfunction

  // 功能：绑定外部 endpoint、端口和 DUT MAC，并校验与已 attach Function 的 MAC 不冲突。
  // 输入/输出及副作用：保存 endpoint 的非拥有引用及 route；不启动 endpoint，也不注册 DUT 为 Function。
  // 失败/边界：空 endpoint/零 MAC、重复绑定、运行中绑定、MAC 与模型 Function 冲突或 snapshot route 冲突均拒绝。
  function rdma_status bind_endpoint(rdma_dut_frame_endpoint value,
                                     int unsigned port,
                                     bit [47:0] mac);
    if (running || endpoint_bound)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY, "DUT endpoint is already bound or running");
    if (value == null || mac == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DUT endpoint or MAC is missing");
    if (func_of_mac.exists(mac))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DUT MAC conflicts with a model Function");
    if (snapshot != null) begin
      if (snapshot.dut_port != port && snapshot.endpoint.dut_port != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DUT port conflicts with snapshot");
      if (snapshot.dut_mac != 0 && snapshot.dut_mac != mac)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DUT MAC conflicts with snapshot");
    end
    endpoint = value;
    dut_port = port;
    dut_mac = mac;
    endpoint_bound = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：按模型 Function 的 MAC 路由附加出口，并拒绝与已绑定 DUT MAC 重叠的模型地址。
  // 输入/输出及副作用：成功返回可发送端口并登记 funcs/func_of_mac；不改变 endpoint 生命周期。
  // 失败/边界：空 Function 返回 null；MAC 冲突通过 UVM_FATAL 终止配置，避免运行期歧义路由。
  virtual function rdma_dev_port attach(rdma_res_func f);
    if (f == null)
      return null;
    if (endpoint_bound && f.mac == dut_mac)
      `uvm_fatal("RDMA_DUT_LINK", $sformatf("model Function f%0d conflicts with DUT MAC %012h",
                                             f.index, dut_mac))
    return super.attach(f);
  endfunction

  // 功能：在 UVM run_phase 启动 endpoint 并创建 DUT TX 接收循环。
  // 输入/输出及副作用：设置 running/receiver_active，调用 endpoint.start；接收线程结束后清除 active。
  // 失败/边界：未绑定 endpoint 或 start 失败时报 UVM_FATAL；不持有 objection，停止由 final_phase 完成。
  virtual task run_phase(uvm_phase phase);
    rdma_status status;

    if (!endpoint_bound || endpoint == null) begin
      `uvm_fatal("RDMA_DUT_LINK", "DUT link endpoint is not bound before run_phase")
      return;
    end
    status = endpoint.start();
    if (!status.ok()) begin
      `uvm_fatal("RDMA_DUT_LINK", {"DUT endpoint start failed: ", status.convert2string()})
      return;
    end
    running = 1'b1;
    fork
      receiver_loop();
    join_none
  endtask

  // 功能：停止接收循环并调用 endpoint.stop，保证 final/reset 路径幂等。
  // 输入/输出及副作用：清除 running，唤醒并关闭 endpoint；不释放外部 endpoint 所有权。
  // 失败/边界：未绑定 endpoint 只清运行标志；重复 stop 不重复产生错误，外部 endpoint 自行处理关闭。
  function void stop();
    rdma_status status;

    running = 1'b0;
    if (endpoint != null) begin
      status = endpoint.stop();
      if (!status.ok())
        endpoint_errors++;
    end
  endfunction

  // 功能：UVM final 阶段关闭外部接收线程，避免 mailbox poll 跨越仿真结束。
  // 输入/输出及副作用：调用 stop；phase 仅用于生命周期定位，不修改 phase objection。
  // 失败/边界：停止必须支持重复调用；线程无法被外部 endpoint 唤醒时由其实现负责返回关闭状态。
  virtual function void final_phase(uvm_phase phase);
    stop();
  endfunction

  // 功能：报告 endpoint、decode、frame 发送和故障计数，并复用基类故障规则检查。
  // 输入/输出及副作用：phase 不修改；非零 endpoint/decode 错误产生 UVM_ERROR，随后检查 base faults。
  // 失败/边界：未关闭 receiver_active、未完成 fault 规则或接收线程残留均报告诊断但不伪造成功。
  virtual function void report_phase(uvm_phase phase);
    if (receiver_active)
      `uvm_error("RDMA_DUT_LINK", "DUT link receiver thread is still active")
    if (endpoint_errors != 0)
      `uvm_error("RDMA_DUT_LINK", $sformatf("endpoint errors=%0d", endpoint_errors))
    if (decode_errors != 0)
      `uvm_error("RDMA_DUT_LINK", $sformatf("DUT frame decode errors=%0d", decode_errors))
    super.report_phase(phase);
  endfunction

  // 功能：把 source Function 发往 DUT 的 semantic packet 编码并提交 endpoint，成功后发布 TX 观测。
  // 输入/输出及副作用：写 endpoint、tx_ap 和计数器；packet 不被修改，frame 在 endpoint 调用前后均独立保存。
  // 失败/边界：未绑定 route、编码失败、故障 DROP、endpoint 发送失败均不发布 TX 观测；DUP/DELAY/CORRUPT
  //   按首条命中的 base fault 规则处理，故障计数仍由 rdma_link_fault 管理。
  virtual task transmit(int unsigned src, rdma_packet pkt, bit [47:0] dmac);
    rdma_link_fault fault;
    int unsigned dst;
    byte unsigned frame[$];
    rdma_status status;

    if (dmac != dut_mac) begin
      super.transmit(src, pkt, dmac);
      return;
    end
    if (!endpoint_bound || endpoint == null) begin
      `uvm_error("RDMA_DUT_LINK", "DUT route used before endpoint bind")
      return;
    end
    dst = RDMA_DUT_LINK_DST;
    foreach (faults[i])
      if (fault == null && faults[i].hit(src, pkt))
        fault = faults[i];
    if (fault != null && fault.kind == RDMA_FAULT_DROP) begin
      fault_drops++;
      return;
    end
    status = codec.encode(pkt, frame);
    if (!status.ok()) begin
      endpoint_errors++;
      `uvm_error("RDMA_DUT_LINK", {"DUT TX encode failed: ", status.convert2string()})
      return;
    end
    if (fault != null && fault.kind == RDMA_FAULT_CORRUPT && frame.size() > 6)
      frame[frame.size() - 6] ^= 8'h01;
    if (fault != null && fault.kind == RDMA_FAULT_DELAY) begin
      fork
        send_frame(src, dst, pkt, frame, fault.delay);
      join_none
      return;
    end
    send_frame(src, dst, pkt, frame, 0);
    if (fault != null && fault.kind == RDMA_FAULT_DUP)
      send_frame(src, dst, pkt, frame, 0);
  endtask

  // 功能：按可选延迟向 endpoint 发送单个 frame，成功后发布拥有独立字节副本的 TX 观测。
  // 输入/输出及副作用：调用 endpoint.send_to_dut，更新 tx_frames_sent/endpoint_errors/tx_ap；不修改 frame。
  // 失败/边界：endpoint 返回非 OK 时不发布观测；delay 为零立即发送，非零值只影响该副本。
  protected task send_frame(int unsigned src, int unsigned dst, rdma_packet pkt,
                            byte unsigned frame[$], time delay);
    rdma_status status;
    rdma_link_obs observation;

    if (delay != 0)
      #(delay);
    if (!running)
      return;
    endpoint.send_to_dut(dut_port, frame, status);
    if (!status.ok()) begin
      endpoint_errors++;
      `uvm_error("RDMA_DUT_LINK", {"DUT endpoint send failed: ", status.convert2string()})
      return;
    end
    tx_frames_sent++;
    observation = super.observe(src, dst, pkt);
    observation.frame = frame;
    tx_ap.write(observation);
  endtask

  // 功能：轮询 DUT TX 原始帧、保存独立副本、解码并发布 RX 观测。
  // 输入/输出及副作用：更新 rx_frames_captured/decode_errors/endpoint_errors/rx_ap；不把 DUT frame 自动送入模型 NIC。
  // 失败/边界：endpoint 正常关闭退出；poll/decode/ICRC 失败只记录 raw frame 和计数，不发布空 packet 观测。
  protected task receiver_loop();
    byte unsigned frame[$];
    rdma_packet decoded;
    rdma_status status;
    rdma_link_obs observation;
    int unsigned dst;

    receiver_active = 1'b1;
    while (running) begin
      frame.delete();
      endpoint.poll_from_dut(dut_port, frame, status);
      if (!status.ok()) begin
        if (!running || status.code == RDMA_SC_INVALID_STATE)
          break;
        endpoint_errors++;
        continue;
      end
      if (!running)
        break;
      rx_frames_captured++;
      decoded = null;
      status = codec.decode(frame, decoded);
      if (!status.ok() || decoded == null) begin
        decode_errors++;
        `uvm_error("RDMA_DUT_LINK", {"DUT frame decode failed: ", status.convert2string()})
        continue;
      end
      dst = route_dst_from_frame(frame);
      observation = super.observe(RDMA_DUT_LINK_DST, dst, decoded);
      observation.frame = frame;
      rx_ap.write(observation);
    end
    receiver_active = 1'b0;
  endtask

  // 功能：从 Ethernet frame 前六字节读取目的 MAC，并映射到已 attach 的模型 Function。
  // 输入/输出及副作用：frame 只读；返回 Function 下标，未知/短帧返回 DUT 哨兵值。
  // 失败/边界：短于六字节、未知 MAC 或全零地址不进入模型路由；该函数不改变 endpoint 或 funcs。
  protected function int unsigned route_dst_from_frame(byte unsigned frame[$]);
    bit [47:0] dmac;

    if (frame.size() < 6)
      return RDMA_DUT_LINK_DST;
    dmac = {frame[0], frame[1], frame[2], frame[3], frame[4], frame[5]};
    if (func_of_mac.exists(dmac))
      return func_of_mac[dmac];
    return RDMA_DUT_LINK_DST;
  endfunction
endclass
