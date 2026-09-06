// 目录：外部适配器实现层 adapters/net_packet/rdma_net_packet_bridge.sv。
// 职责：提供一个只保存 packet raw bytes 快照的测试 sink，连接 adapter 与 DUT/PCAP fixture。
// 依赖：rdma_net_packet_adapter_pkg 和外部 net_packet packet 类。
// 所有权与生命周期：bridge 拥有自身队列中的 packet 副本；调用方传入的 packet 始终由调用方管理。

// 中文说明：该 bridge 是验证夹具，不模拟真实 NIC 调度；真实 AXIS/PCIe 环境可实现同一 sink 接口。
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

    // 功能：构造 queue sink，初始化发送/接收队列和计数器。
    // 输入/输出及副作用：name（输入）；只创建本地队列，不绑定外部 DUT 或释放外部对象。
    // 失败/边界：构造不会预分配无限队列；调用方应通过 status 处理空接收队列。
    function new(string name = "rdma_net_packet_queue_sink");
      super.new(name);
      sent_packets.delete();
      receive_queue.delete();
      last_raw.delete();
      previous_raw.delete();
      sent_count = 0;
      receive_count = 0;
    endfunction

    // 功能：复制 packet 的 raw_data 并重新解析 layer_stack，形成 sink 自有值快照。
    // 输入/输出及副作用：source（输入）；返回新建 packet，源对象和其层句柄保持不变。
    // 失败/边界：source 为空或 raw_data 为空时返回 null，不把外部句柄放入本地队列。
    static function packet clone_packet(packet source);
      packet clone_value;

      if (source == null || source.raw_data.size() == 0)
        return null;
      clone_value = new();
      clone_value.unpack(source.raw_data);
      return clone_value;
    endfunction

    // 功能：把最近一次发送的 packet 快照放入接收队列，构造 loopback 测试路径。
    // 输入/输出及副作用：无显式输入；增加 receive_queue 元素，不修改 sent_packets。
    // 失败/边界：没有最近发送报文时保持队列不变，避免注入空 packet。
    function void enqueue_last_sent_for_receive();
      packet clone_value;

      if (sent_packets.size() == 0)
        return;
      clone_value = clone_packet(sent_packets[sent_packets.size() - 1]);
      if (clone_value != null)
        receive_queue.push_back(clone_value);
    endfunction

    // 功能：将显式 packet 快照放入接收队列，供 parser/错误恢复场景使用。
    // 输入/输出及副作用：source（输入）；成功时复制 source，不转移 source 所有权。
    // 失败/边界：source 无 raw_data 时静默拒绝；接收方通过 QUEUE_EMPTY 观察无数据状态。
    function void enqueue(packet source);
      packet clone_value;

      clone_value = clone_packet(source);
      if (clone_value != null)
        receive_queue.push_back(clone_value);
    endfunction

    // 功能：保存发送 packet 的 raw bytes 副本并加入 sent_packets，模拟外部网络注入点。
    // 输入/输出及副作用：pkt（输入）、status（输出）；只更新 bridge 自有队列和统计量。
    // 失败/边界：pkt 为空或 raw_data 为空时返回 INVALID_ARGUMENT，不保存半包。
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

    // 功能：从 receive_queue 弹出一个 packet 快照，向 adapter 发布非拥有引用。
    // 输入/输出及副作用：pkt、status（输出）；只移动 bridge 队列头，不修改发送记录。
    // 失败/边界：队列为空时返回 RDMA_SC_QUEUE_EMPTY，pkt 保持为空。
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
