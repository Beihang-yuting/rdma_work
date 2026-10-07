// 目录：外部适配器实现层 adapters/rxe/rdma_rxe_pkg.sv。
// 层：外部适配器。
// 职责：仿真设备与 Linux Soft-RoCE（rdma_rxe）经 TAP 网卡互打：
//   - rdma_rxe_link 作为设备 NIC 的网络端口：发出的 rdma_packet 经 net_packet adapter 编码为 RoCEv2
//     以太网帧（ICRC、pad、AckReq）写入 TAP；接收进程从 TAP 读帧、解码后交给 NIC。
//   - rdma_rxe_peer 驱动 rxe 侧的 verbs 对端进程（tools/rxe/rxe_peer）。
//   仿真时间与真实时间：链路空闲时每推进 poll_step 仿真时间等待至多 wait_us 真实时间，使 rxe 有时间
//   应答；设备 QP 的响应超时应设为不超时（IB timeout 0），避免在仿真时间内误判超时。
// 依赖：rdma_rxe_dpi.c（DPI-C）、rdma_net_packet_adapter_pkg、rdma_dev_pkg。
// 所有权：link 持有 TAP 文件描述符；peer 持有子进程句柄。
// 生命周期：由测试创建；测试结束时调用 link.close/peer.stop。
package rdma_rxe_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_net_packet_adapter_pkg::*;

  import "DPI-C" function int rdma_rxe_tap_open(string name);
  import "DPI-C" function void rdma_rxe_tap_close(int fd);
  import "DPI-C" function int rdma_rxe_tap_send(int fd, input byte unsigned data[], int len);
  // 未写方向的形参沿用前一个形参的方向，timeout_us 必须显式 input。
  import "DPI-C" function int rdma_rxe_tap_recv(int fd, inout byte unsigned data[],
                                                input int timeout_us);
  import "DPI-C" function int rdma_rxe_peer_start(string path);
  import "DPI-C" function string rdma_rxe_peer_cmd(int h, string line);
  import "DPI-C" function void rdma_rxe_peer_stop(int h);

  // rxe 侧 verbs 对端进程（逐行命令/应答，见 tools/rxe/rxe_peer.c）。
  class rdma_rxe_peer extends uvm_object;
    `uvm_object_utils(rdma_rxe_peer)

    protected int handle;

    // 功能：构造未启动的对端。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_rxe_peer");
      super.new(name);
      handle = -1;
    endfunction

    // 功能：启动 rxe_peer 子进程。
    // 输入/输出及副作用：fork 子进程。
    // 失败/边界：失败返回 0。
    function bit start(string path);
      handle = rdma_rxe_peer_start(path);
      return handle >= 0;
    endfunction

    // 功能：发一条命令，返回应答行；应答不是 "OK" 开头时报告 UVM_ERROR。
    // 输入/输出及副作用：与子进程交互（阻塞直到应答）。
    // 失败/边界：子进程不可用时应答为 "ERR peer ..."。
    function string cmd(string line);
      string reply;

      reply = rdma_rxe_peer_cmd(handle, line);
      if (reply.len() < 2 || reply.substr(0, 1) != "OK")
        `uvm_error("RXE_PEER", $sformatf("'%s' -> '%s'", line, reply))
      return reply;
    endfunction

    // 功能：取应答中 key=value 的值（十进制或 0x 十六进制）。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：找不到 key 返回 0。
    static function longint unsigned field(string reply, string key);
      string token;
      int start;
      longint unsigned value;

      start = -1;
      for (int i = 0; i + key.len() < reply.len() && start < 0; i++)
        if (reply.substr(i, i + key.len()) == {key, "="} && (i == 0 || reply[i - 1] == " "))
          start = i + key.len() + 1;
      if (start < 0)
        return 0;
      token = "";
      for (int i = start; i < reply.len() && reply[i] != " "; i++)
        token = {token, reply[i]};
      // atohex/atoi 只有 32 位，逐位累加 64 位值。
      value = 0;
      if (token.len() > 2 && token.substr(0, 1) == "0x") begin
        for (int i = 2; i < token.len(); i++)
          value = (value << 4) | token.substr(i, i).atohex();
        return value;
      end
      for (int i = 0; i < token.len(); i++)
        value = value * 10 + (token[i] - "0");
      return value;
    endfunction

    // 功能：让子进程退出。
    // 输入/输出及副作用：回收子进程。
    // 失败/边界：未启动时无动作。
    function void stop();
      rdma_rxe_peer_stop(handle);
      handle = -1;
    endfunction
  endclass

  // 设备 NIC 的网络端口：RoCEv2 帧经 TAP 与 rxe 互通。
  class rdma_rxe_link extends rdma_dev_port;
    `uvm_object_utils(rdma_rxe_link)

    localparam int unsigned FRAME_MAX = 16384;

    rdma_net_packet_adapter adapter;
    rdma_dev_nic nic;
    // 链路空闲时每次推进的仿真时间与等待的真实时间（微秒）。
    time poll_step;
    int unsigned wait_us;
    // 观测：发出/收到的报文（rx 为解码成功的）、解码失败（非 RoCEv2 或 ICRC 错）的帧数、
    //   注入丢弃的报文。
    rdma_packet tx_log[$];
    rdma_packet rx_log[$];
    int unsigned rx_dropped;
    rdma_packet tx_lost[$];
    rdma_packet rx_lost[$];
    protected int fd;
    protected int unsigned tx_drop_countdown;
    protected int unsigned rx_drop_countdown;

    // 功能：构造未打开的链路。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：open 前 send 报告 UVM_ERROR。
    function new(string name = "rdma_rxe_link");
      super.new(name);
      fd = -1;
      poll_step = 100ns;
      wait_us = 200;
      rx_dropped = 0;
      tx_drop_countdown = 0;
      rx_drop_countdown = 0;
    endfunction

    // 功能：故障注入：丢弃此后设备发出的第 k 个报文（k 从 1 起，不写入 TAP，记入 tx_lost）。
    // 输入/输出及副作用：设置一次性计数。
    // 失败/边界：k 为 0 时取消。
    function void drop_tx(int unsigned k);
      tx_drop_countdown = k;
    endfunction

    // 功能：故障注入：丢弃此后从 rxe 收到的第 k 个 RoCEv2 报文（不交给 NIC，记入 rx_lost）。
    // 输入/输出及副作用：设置一次性计数。
    // 失败/边界：k 为 0 时取消。
    function void drop_rx(int unsigned k);
      rx_drop_countdown = k;
    endfunction

    // 功能：打开 TAP 网卡。
    // 输入/输出及副作用：保存文件描述符。
    // 失败/边界：TAP 不存在或无权限返回 0（先运行 tools/rxe/rxe_tap_setup.sh up）。
    function bit open(string tap);
      fd = rdma_rxe_tap_open(tap);
      return fd >= 0;
    endfunction

    // 功能：关闭 TAP。
    // 输入/输出及副作用：释放文件描述符。
    // 失败/边界：无。
    function void close();
      rdma_rxe_tap_close(fd);
      fd = -1;
    endfunction

    // 功能：设备发包：编码为 RoCEv2 帧写入 TAP（地址取 adapter 配置）。
    // 输入/输出及副作用：写 TAP，记入 tx_log。
    // 失败/边界：编码或写失败报告 UVM_ERROR。
    virtual task send(rdma_packet pkt, bit [47:0] dmac);
      byte unsigned frame[$];
      byte unsigned data[];
      rdma_status status;

      if (tx_drop_countdown != 0 && --tx_drop_countdown == 0) begin
        tx_lost.push_back(pkt);
        `uvm_info("RXE_LINK", $sformatf("tx %s psn %06h dropped (injected)", pkt.opcode.name(),
                                        pkt.psn), UVM_MEDIUM)
        return;
      end
      status = adapter.encode_packet(pkt, frame);
      if (status == null || !status.ok()) begin
        `uvm_error("RXE_LINK", "RoCEv2 encode failed")
        return;
      end
      data = new[frame.size()];
      foreach (frame[i])
        data[i] = frame[i];
      if (rdma_rxe_tap_send(fd, data, data.size()) != data.size())
        `uvm_error("RXE_LINK", "TAP write failed")
      tx_log.push_back(pkt);
      `uvm_info("RXE_LINK", $sformatf("tx %s %s dqpn %0d psn %06h ackreq %0b len %0d (%0dB frame)",
                                      pkt.opcode.name(), pkt.segment.name(), pkt.destination_qpn,
                                      pkt.psn, pkt.ack_req, pkt.payload.size(), frame.size()),
                UVM_HIGH)
    endtask

    // 功能：接收进程：TAP 有帧则解码交给 NIC，否则推进 poll_step 并等待至多 wait_us 真实时间。
    // 输入/输出及副作用：永久循环；记入 rx_log。
    // 失败/边界：解码失败（非 RoCEv2、ICRC 错）计入 rx_dropped。
    task run();
      byte unsigned data[];
      byte unsigned frame[$];
      rdma_packet pkt;
      rdma_status status;
      int n;

      data = new[FRAME_MAX];
      forever begin
        n = rdma_rxe_tap_recv(fd, data, wait_us);
        if (n <= 0) begin
          #(poll_step);
          continue;
        end
        frame.delete();
        for (int i = 0; i < n; i++)
          frame.push_back(data[i]);
        status = adapter.decode_packet(frame, pkt);
        if (status == null || !status.ok() || pkt == null) begin
          rx_dropped++;
          `uvm_info("RXE_LINK", $sformatf("rx %0dB frame dropped: %s", n,
                                          status == null ? "null" : status.convert2string()),
                    UVM_MEDIUM)
          continue;
        end
        if (rx_drop_countdown != 0 && --rx_drop_countdown == 0) begin
          rx_lost.push_back(pkt);
          `uvm_info("RXE_LINK", $sformatf("rx %s psn %06h dropped (injected)", pkt.opcode.name(),
                                          pkt.psn), UVM_MEDIUM)
          continue;
        end
        rx_log.push_back(pkt);
        `uvm_info("RXE_LINK", $sformatf("rx %s %s dqpn %0d psn %06h len %0d", pkt.opcode.name(),
                                        pkt.segment.name(), pkt.destination_qpn, pkt.psn,
                                        pkt.payload.size()), UVM_HIGH)
        nic.receive(pkt);
        #1ns;
      end
    endtask
  endclass
endpackage
