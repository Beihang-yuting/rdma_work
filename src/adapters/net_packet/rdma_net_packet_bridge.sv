// 目录：外部适配器实现层 adapters/net_packet/rdma_net_packet_bridge.sv。
// 职责：提供一个只保存 packet raw bytes 快照的测试 sink，连接 adapter 与 DUT/PCAP fixture。
// 依赖：rdma_net_packet_adapter_pkg 和外部 net_packet packet 类。
// 所有权与生命周期：bridge 拥有自身队列中的 packet 副本；调用方传入的 packet 始终由调用方管理。

// 中文说明：该 bridge 是验证夹具，不模拟 NIC 调度；真实 AXIS/PCIe 环境可实现同一 sink 接口。
package rdma_net_packet_bridge_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_net_packet_adapter_pkg::*;
  `include "uvm_macros.svh"

  class rdma_net_packet_queue_sink extends rdma_net_packet_sink;
    `uvm_object_utils(rdma_net_packet_queue_sink)

    packet sent_packets[$];
    packet receive_queue[$];
    byte unsigned last_raw[$];
    byte unsigned previous_raw[$];
    int unsigned sent_count;
    int unsigned receive_count;

    // 功能：构造 queue sink 并清空收发队列与计数。
    // 输入/输出及副作用：name 为对象名；只初始化本地队列。
    // 失败/边界：无。
    function new(string name = "rdma_net_packet_queue_sink");
      super.new(name);
      sent_packets.delete();
      receive_queue.delete();
      last_raw.delete();
      previous_raw.delete();
      sent_count = 0;
      receive_count = 0;
    endfunction

    // 功能：按 raw_data 重新 unpack，得到 sink 自有的 packet 副本。
    // 输入/输出及副作用：source 只读；返回新 packet。
    // 失败/边界：source 为空或 raw_data 为空返回 null。
    static function packet clone_packet(packet source);
      packet clone_value;

      if (source == null || source.raw_data.size() == 0)
        return null;
      clone_value = new();
      clone_value.unpack(source.raw_data);
      return clone_value;
    endfunction

    // 功能：把最近一次发送的 packet 副本放入接收队列（loopback）。
    // 输入/输出及副作用：追加 receive_queue，不改 sent_packets。
    // 失败/边界：无已发送报文时不动作。
    function void enqueue_last_sent_for_receive();
      packet clone_value;

      if (sent_packets.size() == 0)
        return;
      clone_value = clone_packet(sent_packets[sent_packets.size() - 1]);
      if (clone_value != null)
        receive_queue.push_back(clone_value);
    endfunction

    // 功能：把 source 的副本放入接收队列。
    // 输入/输出及副作用：source 只读，不转移所有权。
    // 失败/边界：source 无 raw_data 时静默忽略。
    function void enqueue(packet source);
      packet clone_value;

      clone_value = clone_packet(source);
      if (clone_value != null)
        receive_queue.push_back(clone_value);
    endfunction

    // 功能：保存发送 packet 的副本并记录 last_raw/previous_raw。
    // 输入/输出及副作用：pkt 输入、status 输出；更新 sent_packets 与 sent_count。
    // 失败/边界：pkt 为空或无 raw_data 返回 INVALID_ARGUMENT；克隆失败返回 RESOURCE_EXHAUSTED。
    virtual task send(packet pkt, output rdma_status status);
      packet clone_value;

      status = rdma_status::success();
      if (pkt == null || pkt.raw_data.size() == 0) begin
        status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "sink packet is empty");
        return;
      end
      clone_value = clone_packet(pkt);
      if (clone_value == null) begin
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "sink packet clone failed");
        return;
      end
      previous_raw = last_raw;
      last_raw = pkt.raw_data;
      sent_packets.push_back(clone_value);
      sent_count++;
    endtask

    // 功能：从 receive_queue 弹出一个 packet 发布给调用方。
    // 输入/输出及副作用：pkt、status 为输出；递增 receive_count。
    // 失败/边界：队列为空返回 QUEUE_EMPTY，pkt 为 null。
    virtual task receive(output packet pkt, output rdma_status status);
      pkt = null;
      if (receive_queue.size() == 0) begin
        status = rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                   "net_packet receive queue is empty");
        return;
      end
      pkt = receive_queue.pop_front();
      receive_count++;
      status = rdma_status::success();
    endtask
  endclass
endpackage
