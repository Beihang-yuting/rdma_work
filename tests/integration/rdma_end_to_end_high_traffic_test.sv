// 目录：测试层 tests/integration/ 。
// 职责：以双 Function 的真实 host-memory、net_packet 和 queue-data 路径验证
//   有界 outstanding window 下的高流量 SEND 业务。本文件仅拥有测试夹具和
//   detached 快照，不复制、不修改外部 host_mem/net_packet/dpu_common 源码。
// 依赖：继承 rdma_end_to_end_transport_test 的双环境配置、Function-qualified
//   event 路由、真实 host-memory adapter 和 net_packet bridge，并使用 queue-data
//   engine 的 SQ/RQ/CQ 公开接口。
// 所有权与生命周期：本测试拥有本轮 tx/rx fixture 和 payload mapping；外部
//   manager/adapter 只由基类创建并在 run_phase 结束时显式释放，最后执行 leak check。

// 中文设计说明：高流量测试将一整个 16-slot window 填满后才发布 CQE，再以 4 个一批回收。
// 这个序列同时覆盖 PI/CI、ring wrap、queue full 和 backpressure，与既有的“每包立即 poll”测试互补。
import rdma_unit_test_pkg::*;
import rdma_types_pkg::*;
import rdma_model_pkg::*;
import rdma_core_pkg::*;
import rdma_adapter_pkg::*;
import host_mem_pkg::*;
import rdma_host_mem_adapter_pkg::*;
import rdma_net_packet_adapter_pkg::*;
import rdma_net_packet_bridge_pkg::*;
import uvm_pkg::*;
`include "uvm_macros.svh"

class rdma_end_to_end_high_traffic_test extends rdma_end_to_end_transport_test;
  `uvm_component_utils(rdma_end_to_end_high_traffic_test)

  localparam int unsigned HIGH_PACKET_COUNT = 4096;
  localparam int unsigned HIGH_PAYLOAD_BYTES = 256;
  localparam int unsigned HIGH_WINDOW = 16;
  localparam int unsigned HIGH_DRAIN_BATCH = 4;
  localparam int unsigned HIGH_CQ_DEPTH = 16;

  // 一个窗口内的 post 结果必须保留到 CQE 被消费后：CQE 的 WQE index/wrap
  // 由该快照确定，不能在下一次 post 时只依赖可变的 QP producer 指针回推。
  rdma_queue_post_result tx_window_posts[HIGH_WINDOW];
  rdma_queue_post_result rx_window_posts[HIGH_WINDOW];

  // 功能：创建高流量测试组件，并保持父类环境句柄的空初始状态。
  // 输入/输出及副作用：name、parent（输入）；调用父类构造函数，不分配 host-memory、QP 或网络资源。
  // 失败/边界：构造成功不代表外部环境已可用；run_phase 必须先完成父类配置。
  function new(string name = "rdma_end_to_end_high_traffic_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：确认一次 CQ poll 同时返回引擎 completion 状态和 CQE 自带状态，
  //   且两者都明确表示成功，避免仅凭 WR ID 把错误 CQE 计入吞吐量。
  // 输入/输出及副作用：completion（输入）；只读检查 completion、completion_status、
  //   cqe 和 cqe.status，返回成功布尔值，不推进 CI、不释放 WQE，也不修改任何账本。
  // 失败/边界：结果对象、两个 status 或其任一 ok() 为假时返回 0；该函数不把
  //   null/默认对象解释成成功，调用方仍需检查 poll 返回的 rdma_status。
  function automatic bit completion_is_success(
    rdma_queue_completion_result completion
  );
    if (completion == null || completion.completion_status == null ||
        completion.cqe == null || completion.cqe.status == null)
      return 1'b0;
    return completion.completion_status != null &&
           completion.completion_status.ok() &&
           completion.cqe.status != null &&
           completion.cqe.status.ok();
  endfunction

  // 功能：比较两个 resource handle 的值语义，供 mapping authority 快照复用。
  // 输入/输出及副作用：lhs、rhs（输入）；只读取 kind、Function UID、object ID
  //   和 generation，返回是否代表同一份 authority，不修改句柄或资源账本。
  // 失败/边界：仅一侧为空时返回 0；两侧都为空视为相等；非空句柄通过
  //   same_instance() 逐字段比较，generation 不同也会被拒绝。
  function automatic bit handle_value_equal(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.same_instance(rhs);
  endfunction

  // 功能：逐字段比较 DMA mapping authority，确认 queue-full 的拒绝路径没有
  //   改写 IOVA/backing、访问属性、完整 PCIe route、reset epoch 或 owner 证据。
  // 输入/输出及副作用：lhs、rhs（输入）；只读比较 mapping 元数据和关联 handle，
  //   返回是否完全一致，不释放 backing、不推进队列，也不改变 adapter 状态。
  // 失败/边界：任一 mapping 为空、Function/owner handle 不同、PASID/domain、
  //   route/BDF、geometry、state、direction/permissions 或 UMEM 标志不同均返回 0；
  //   该函数不把两个空对象误判为有效 authority。
  function automatic bit mapping_authority_equal(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    if (!handle_value_equal(lhs.function_h, rhs.function_h) ||
        !handle_value_equal(lhs.owner_h, rhs.owner_h))
      return 1'b0;
    return lhs.requester_bdf === rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid &&
           lhs.pasid === rhs.pasid &&
           lhs.dma_domain_valid == rhs.dma_domain_valid &&
           lhs.dma_domain_id == rhs.dma_domain_id &&
           lhs.route_valid == rhs.route_valid &&
           lhs.route.host_topology_key == rhs.route.host_topology_key &&
           lhs.route.root_id == rhs.route.root_id &&
           lhs.route.segment == rhs.route.segment &&
           lhs.route.bdf === rhs.route.bdf &&
           lhs.epoch_valid == rhs.epoch_valid &&
           lhs.reset_epoch == rhs.reset_epoch &&
           lhs.backing_addr === rhs.backing_addr &&
           lhs.iova === rhs.iova &&
           lhs.size == rhs.size &&
           lhs.direction == rhs.direction &&
           lhs.permissions === rhs.permissions &&
           lhs.state == rhs.state &&
           lhs.umem_backed == rhs.umem_backed &&
           lhs.umem_page_count == rhs.umem_page_count;
  endfunction

  // 功能：执行固定 16-entry outstanding window 的 RC SEND 高流量闭环；每轮先
  //   填满 RQ/SQ，再验证第 17 次无副作用拒绝，最后按四个 CQE 一批回收 credit。
  // 输入/输出及副作用：status（输出）；成功时写入两个真实 payload mapping、发送/接收
  //   net_packet、推进双端 SQ/RQ/CQ PI/CI，并在每个已完成的 Function 事件上 end_pending。
  // 失败/边界：配置不完整、post/CQE/网络/host-memory 任一步失败立即返回首个状态；已登记
  //   的 pending 由调用方 run_phase 的 drain_composition_pending 兜底清账，不能继续下一窗口。
  task automatic run_high_traffic(output rdma_status status);
    rdma_post_recv_req recv_request;
    rdma_post_send_req send_request;
    rdma_queue_post_result rejected_post;
    rdma_queue_completion_result tx_completion;
    rdma_queue_completion_result rx_completion;
    rdma_status local_status;
    rdma_status tx_status;
    rdma_status rx_status;
    rdma_packet network_packet;
    rdma_packet received_packet;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result tx_published[HIGH_WINDOW];
    rdma_queue_device_publish_result rx_published[HIGH_WINDOW];
    byte unsigned payload[$];
    byte write_data[];
    byte tx_readback[];
    byte rx_readback[];
    byte tx_before[];
    byte rx_before[];
    byte tx_after[];
    byte rx_after[];
    bit payload_match;
    longint unsigned tx_before_sequence;
    longint unsigned rx_before_sequence;
    int unsigned tx_before_sent;
    int unsigned rx_before_received;
    int unsigned tx_before_pending;
    int unsigned rx_before_pending;
    int unsigned tx_cq_used;
    int unsigned rx_cq_used;
    bit tx_cq_pending;
    bit rx_cq_pending;
    int unsigned sq_used;
    int unsigned rq_used;
    bit sq_pending;
    bit rq_pending;
    int unsigned sq_pi;
    int unsigned sq_ci;
    int unsigned rq_pi;
    int unsigned rq_ci;
    bit sq_pw;
    bit sq_cw;
    bit rq_pw;
    bit rq_cw;
    int unsigned before_sq_pi;
    int unsigned before_sq_ci;
    int unsigned before_rq_pi;
    int unsigned before_rq_ci;
    bit before_sq_pw;
    bit before_sq_cw;
    bit before_rq_pw;
    bit before_rq_cw;
    int unsigned before_tx_cq_pi;
    int unsigned before_tx_cq_ci;
    int unsigned before_rx_cq_pi;
    int unsigned before_rx_cq_ci;
    int unsigned before_tx_cq_used;
    int unsigned before_rx_cq_used;
    bit before_tx_cq_pending;
    bit before_rx_cq_pending;
    bit before_tx_cq_pw;
    bit before_tx_cq_cw;
    bit before_rx_cq_pw;
    bit before_rx_cq_cw;
    int unsigned tx_cq_pi;
    int unsigned tx_cq_ci;
    int unsigned rx_cq_pi;
    int unsigned rx_cq_ci;
    bit tx_cq_pw;
    bit tx_cq_cw;
    bit rx_cq_pw;
    bit rx_cq_cw;
    rdma_dma_mapping tx_mapping_before;
    rdma_dma_mapping rx_mapping_before;
    int unsigned tx_cq_absolute;
    int unsigned rx_cq_absolute;
    int unsigned packet_index;
    int unsigned window_base;
    int unsigned completed_in_window;
    rdma_function_identity tx_identity;
    rdma_function_identity rx_identity;
    bit saw_sq_wrap;
    bit saw_rq_wrap;
    bit cq_polarity;

    status = rdma_status::success();
    tx_cq_absolute = 0;
    rx_cq_absolute = 0;
    saw_sq_wrap = 1'b0;
    saw_rq_wrap = 1'b0;
    tx_identity = tx_env == null || tx_env.binding == null ? null :
                  tx_env.binding.function_identity_snapshot();
    rx_identity = rx_env == null || rx_env.binding == null ? null :
                  rx_env.binding.function_identity_snapshot();
    if (tx_env == null || rx_env == null || tx_env.qp == null || rx_env.qp == null ||
        tx_composition_env == null || rx_composition_env == null ||
        tx_identity == null || rx_identity == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "high-traffic fixture or composition authority is missing");
      return;
    end
    // 该用例的 queue-full 证据依赖 fixture 与窗口使用同一深度；若外部
    // 配置改变深度，必须显式失败，不能让固定的 index/wrap 公式静默失真。
    if (tx_env.qp.sq_depth != HIGH_WINDOW || tx_env.qp.rq_depth != HIGH_WINDOW ||
        rx_env.qp.sq_depth != HIGH_WINDOW || rx_env.qp.rq_depth != HIGH_WINDOW ||
        tx_env.cq.depth != HIGH_CQ_DEPTH || rx_env.cq.depth != HIGH_CQ_DEPTH) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        $sformatf({"high-traffic fixture depth mismatch tx_sq=%0d tx_rq=%0d tx_cq=%0d ",
                   "rx_sq=%0d rx_rq=%0d rx_cq=%0d expected=%0d"},
                  tx_env.qp.sq_depth, tx_env.qp.rq_depth, tx_env.cq.depth,
                  rx_env.qp.sq_depth, rx_env.qp.rq_depth, rx_env.cq.depth,
                  HIGH_WINDOW));
      return;
    end

    for (window_base = 0; window_base < HIGH_PACKET_COUNT;
         window_base += HIGH_WINDOW) begin
      // 每轮开始时 queue 必须已由上一轮全部回收；否则不能把 queue-full
      // 拒绝归因于本窗口的 backpressure。
      local_status = tx_composition_env.queue_data.query_runtime_occupancy(
        tx_env.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_used, sq_pending);
      if (local_status == null || !local_status.ok() || sq_used != 0 || sq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "TX SQ was not empty at high-traffic window start");
        return;
      end
      local_status = rx_composition_env.queue_data.query_runtime_occupancy(
        rx_env.qp.handle, RDMA_QUEUE_RUNTIME_RQ, rq_used, rq_pending);
      if (local_status == null || !local_status.ok() || rq_used != 0 || rq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RX RQ was not empty at high-traffic window start");
        return;
      end
      // CQ producer 由外部设备写入接口维护；当前 fixture 的 queue-data
      // runtime 只负责 consumer/CI，因此每轮开始必须确认没有遗留的 CQ
      // occupancy 或恢复事务，但不要求 producer/consumer 数值相等。
      local_status = tx_composition_env.queue_data.query_runtime_occupancy(
        tx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, tx_cq_used, tx_cq_pending);
      if (local_status == null || !local_status.ok() || tx_cq_used != 0 || tx_cq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "TX CQ runtime was not idle at high-traffic window start");
        return;
      end
      local_status = rx_composition_env.queue_data.query_runtime_occupancy(
        rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, rx_cq_used, rx_cq_pending);
      if (local_status == null || !local_status.ok() || rx_cq_used != 0 || rx_cq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RX CQ runtime was not idle at high-traffic window start");
        return;
      end

      for (int unsigned slot = 0; slot < HIGH_WINDOW; slot++) begin
        packet_index = window_base + slot;
        tx_window_posts[slot] = null;
        rx_window_posts[slot] = null;
        make_payload(packet_index, payload);
        write_data = new[payload.size()];
        foreach (payload[i])
          write_data[i] = payload[i];
        tx_status = tx_host_adapter.write(tx_payload_mapping, 0, write_data);
        if (tx_status == null || !tx_status.ok()) begin
          status = tx_status == null ? rdma_status::make(RDMA_SC_DMA_TRANSLATION,
            "TX payload write returned null status") : tx_status;
          return;
        end
        tx_status = tx_host_adapter.read(tx_payload_mapping, 0, HIGH_PAYLOAD_BYTES,
                                         tx_readback);
        payload_match = tx_readback.size() == payload.size();
        if (payload_match)
          foreach (payload[i])
            if (tx_readback[i] !== payload[i]) payload_match = 1'b0;
        if (tx_status == null || !tx_status.ok() || !payload_match) begin
          status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                     "TX payload readback differs before post");
          return;
        end

        recv_request = rx_env.make_recv(64'hb000_0000_0000_0000 + packet_index);
        recv_request.target_h = rdma_clone_handle_value(rx_env.qp.handle,
                                                         "high-traffic receive QP");
        recv_request.sges[0].iova = rx_payload_mapping.iova;
        recv_request.sges[0].length = HIGH_PAYLOAD_BYTES;
        recv_request.sges[0].lkey = 32'hbabe_4000 + packet_index;
        rx_composition_env.post_recv(recv_request, rx_window_posts[slot], rx_status);
        if (rx_status == null || !rx_status.ok() || rx_window_posts[slot] == null) begin
          status = rx_status == null ? rdma_status::make(RDMA_SC_INVALID_STATE,
            "RQ post returned null status") : rx_status;
          return;
        end
        if (rx_window_posts[slot].index != (packet_index % HIGH_WINDOW) ||
            rx_window_posts[slot].wrap != bit'((packet_index / HIGH_WINDOW) & 1)) begin
          status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "RQ post index/wrap does not cover ring wrap");
          return;
        end
        saw_rq_wrap |= rx_window_posts[slot].wrap;
        route_composition_event(rx_composition_env, rx_identity, packet_index, local_status);
        if (local_status == null || !local_status.ok()) begin
          status = local_status == null ? rdma_status::make(RDMA_SC_INVALID_STATE,
            "RX composition route returned null status") : local_status;
          return;
        end

        send_request = make_transport_request(RDMA_TRANSPORT_RC, RDMA_WR_SEND,
                                               64'hc000_0000_0000_0000 + packet_index);
        tx_composition_env.post_send(send_request, tx_window_posts[slot], tx_status);
        if (tx_status == null || !tx_status.ok() || tx_window_posts[slot] == null) begin
          status = tx_status == null ? rdma_status::make(RDMA_SC_INVALID_STATE,
            "SQ post returned null status") : tx_status;
          return;
        end
        if (tx_window_posts[slot].index != (packet_index % HIGH_WINDOW) ||
            tx_window_posts[slot].wrap != bit'((packet_index / HIGH_WINDOW) & 1)) begin
          status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "SQ post index/wrap does not cover ring wrap");
          return;
        end
        saw_sq_wrap |= tx_window_posts[slot].wrap;
        route_composition_event(tx_composition_env, tx_identity, packet_index, local_status);
        if (local_status == null || !local_status.ok()) begin
          status = local_status == null ? rdma_status::make(RDMA_SC_INVALID_STATE,
            "TX composition route returned null status") : local_status;
          return;
        end

        network_packet = make_transport_packet(RDMA_TRANSPORT_RC, RDMA_WR_SEND,
                                                packet_index, payload);
        tx_net.send_packet(network_packet, tx_status);
        if (tx_status == null || !tx_status.ok() || tx_net.last_sent_packet == null) begin
          status = tx_status == null ? rdma_status::make(RDMA_SC_CODEC_ERROR,
            "TX net_packet send returned null status") : tx_status;
          return;
        end
        rx_sink.enqueue(tx_net.last_sent_packet);
        rx_net.receive_packet(received_packet, rx_status);
        payload_match = received_packet != null &&
                        received_packet.payload.size() == payload.size();
        if (payload_match)
          foreach (payload[i])
            if (received_packet.payload[i] !== payload[i]) payload_match = 1'b0;
        if (rx_status == null || !rx_status.ok() || !payload_match) begin
          status = rx_status == null ? rdma_status::make(RDMA_SC_CODEC_ERROR,
            "RX net_packet receive returned null status") : rx_status;
          return;
        end
        write_data = new[received_packet.payload.size()];
        foreach (received_packet.payload[i])
          write_data[i] = received_packet.payload[i];
        rx_status = rx_host_adapter.write(rx_payload_mapping, 0, write_data);
        if (rx_status == null || !rx_status.ok()) begin
          status = rx_status == null ? rdma_status::make(RDMA_SC_DMA_TRANSLATION,
            "RX payload write returned null status") : rx_status;
          return;
        end
        rx_status = rx_host_adapter.read(rx_payload_mapping, 0, HIGH_PAYLOAD_BYTES,
                                         rx_readback);
        payload_match = rx_readback.size() == payload.size();
        if (payload_match)
          foreach (payload[i])
            if (rx_readback[i] !== payload[i]) payload_match = 1'b0;
        if (rx_status == null || !rx_status.ok() || !payload_match) begin
          status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                     "RX payload readback differs from net_packet");
          return;
        end
      end

      // 所有 16 个事务已进入网路与 queue ledger，但没有 completion；第 17 个
      // post 必须 fail-closed，且绝不能影响 payload、PI/CI、网络统计或 used。
      local_status = tx_composition_env.queue_data.query_runtime_cursors(
        tx_env.qp.handle, RDMA_QUEUE_RUNTIME_SQ, before_sq_pi, before_sq_pw,
        before_sq_ci, before_sq_cw);
      if (local_status == null || !local_status.ok()) begin status = local_status; return; end
      local_status = rx_composition_env.queue_data.query_runtime_cursors(
        rx_env.qp.handle, RDMA_QUEUE_RUNTIME_RQ, before_rq_pi, before_rq_pw,
        before_rq_ci, before_rq_cw);
      if (local_status == null || !local_status.ok()) begin status = local_status; return; end
      local_status = tx_composition_env.queue_data.query_runtime_cursors(
        tx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, before_tx_cq_pi, before_tx_cq_pw,
        before_tx_cq_ci, before_tx_cq_cw);
      if (local_status == null || !local_status.ok()) begin status = local_status; return; end
      local_status = rx_composition_env.queue_data.query_runtime_cursors(
        rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, before_rx_cq_pi, before_rx_cq_pw,
        before_rx_cq_ci, before_rx_cq_cw);
      if (local_status == null || !local_status.ok()) begin status = local_status; return; end
      local_status = tx_composition_env.queue_data.query_runtime_occupancy(
        tx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ,
        before_tx_cq_used, before_tx_cq_pending);
      if (local_status == null || !local_status.ok()) begin status = local_status; return; end
      local_status = rx_composition_env.queue_data.query_runtime_occupancy(
        rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ,
        before_rx_cq_used, before_rx_cq_pending);
      if (local_status == null || !local_status.ok()) begin status = local_status; return; end
      // 使用 host_mem adapter 提供的 opaque authority snapshot，而不是普通
      // clone；这样比较既覆盖公开字段，也保留 allocation identity 的释放
      // 证据，避免 queue-full 路径把另一份 backing 冒充为原映射。
      tx_status = tx_payload_mapping.snapshot_release_authority(tx_mapping_before);
      rx_status = rx_payload_mapping.snapshot_release_authority(rx_mapping_before);
      if (tx_status == null || !tx_status.ok() || tx_mapping_before == null ||
          rx_status == null || !rx_status.ok() || rx_mapping_before == null) begin
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "queue-full mapping authority snapshot failed");
        return;
      end
      tx_before_sequence = tx_net.send_sequence;
      rx_before_sequence = rx_net.receive_sequence;
      tx_before_sent = tx_sink.sent_count;
      rx_before_received = rx_sink.receive_count;
      tx_before_pending = tx_composition_env.pending_count();
      rx_before_pending = rx_composition_env.pending_count();
      tx_status = tx_host_adapter.read(tx_payload_mapping, 0, HIGH_PAYLOAD_BYTES, tx_before);
      rx_status = rx_host_adapter.read(rx_payload_mapping, 0, HIGH_PAYLOAD_BYTES, rx_before);
      if (tx_status == null || !tx_status.ok() || rx_status == null || !rx_status.ok()) begin
        status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                   "queue-full payload snapshot failed");
        return;
      end
      recv_request = rx_env.make_recv(64'hd000_0000_0000_0000 + window_base);
      recv_request.target_h = rdma_clone_handle_value(rx_env.qp.handle,
                                                       "high-traffic full receive QP");
      recv_request.sges[0].iova = rx_payload_mapping.iova;
      recv_request.sges[0].length = HIGH_PAYLOAD_BYTES;
      rejected_post = null;
      rx_composition_env.post_recv(recv_request, rejected_post, rx_status);
      if (rx_status == null || rx_status.code != RDMA_SC_QUEUE_FULL || rejected_post != null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "17th RQ post did not return queue full without result");
        return;
      end
      send_request = make_transport_request(RDMA_TRANSPORT_RC, RDMA_WR_SEND,
                                             64'he000_0000_0000_0000 + window_base);
      rejected_post = null;
      tx_composition_env.post_send(send_request, rejected_post, tx_status);
      if (tx_status == null || tx_status.code != RDMA_SC_QUEUE_FULL || rejected_post != null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "17th SQ post did not return queue full without result");
        return;
      end
      local_status = tx_composition_env.queue_data.query_runtime_occupancy(
        tx_env.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_used, sq_pending);
      if (local_status == null || !local_status.ok() || sq_used != HIGH_WINDOW || sq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "SQ queue-full attempt changed outstanding credits");
        return;
      end
      local_status = rx_composition_env.queue_data.query_runtime_occupancy(
        rx_env.qp.handle, RDMA_QUEUE_RUNTIME_RQ, rq_used, rq_pending);
      if (local_status == null || !local_status.ok() || rq_used != HIGH_WINDOW || rq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RQ queue-full attempt changed outstanding credits");
        return;
      end
      local_status = tx_composition_env.queue_data.query_runtime_cursors(
        tx_env.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_pi, sq_pw, sq_ci, sq_cw);
      if (local_status == null || !local_status.ok() || sq_pi != before_sq_pi ||
          sq_pw != before_sq_pw || sq_ci != before_sq_ci || sq_cw != before_sq_cw) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "SQ queue-full attempt changed PI/CI");
        return;
      end
      local_status = rx_composition_env.queue_data.query_runtime_cursors(
        rx_env.qp.handle, RDMA_QUEUE_RUNTIME_RQ, rq_pi, rq_pw, rq_ci, rq_cw);
      if (local_status == null || !local_status.ok() || rq_pi != before_rq_pi ||
          rq_pw != before_rq_pw || rq_ci != before_rq_ci || rq_cw != before_rq_cw) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RQ queue-full attempt changed PI/CI");
        return;
      end
      local_status = tx_composition_env.queue_data.query_runtime_occupancy(
        tx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, tx_cq_used, tx_cq_pending);
      if (local_status == null || !local_status.ok() ||
          tx_cq_used != before_tx_cq_used || tx_cq_pending != before_tx_cq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "TX CQ queue-full attempt changed runtime occupancy");
        return;
      end
      local_status = rx_composition_env.queue_data.query_runtime_occupancy(
        rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, rx_cq_used, rx_cq_pending);
      if (local_status == null || !local_status.ok() ||
          rx_cq_used != before_rx_cq_used || rx_cq_pending != before_rx_cq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RX CQ queue-full attempt changed runtime occupancy");
        return;
      end
      local_status = tx_composition_env.queue_data.query_runtime_cursors(
        tx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, tx_cq_pi, tx_cq_pw,
        tx_cq_ci, tx_cq_cw);
      if (local_status == null || !local_status.ok() ||
          tx_cq_pi != before_tx_cq_pi || tx_cq_pw != before_tx_cq_pw ||
          tx_cq_ci != before_tx_cq_ci || tx_cq_cw != before_tx_cq_cw) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "TX CQ queue-full attempt changed PI/CI");
        return;
      end
      local_status = rx_composition_env.queue_data.query_runtime_cursors(
        rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, rx_cq_pi, rx_cq_pw,
        rx_cq_ci, rx_cq_cw);
      if (local_status == null || !local_status.ok() ||
          rx_cq_pi != before_rx_cq_pi || rx_cq_pw != before_rx_cq_pw ||
          rx_cq_ci != before_rx_cq_ci || rx_cq_cw != before_rx_cq_cw) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RX CQ queue-full attempt changed PI/CI");
        return;
      end
      tx_status = tx_host_adapter.read(tx_payload_mapping, 0, HIGH_PAYLOAD_BYTES, tx_after);
      rx_status = rx_host_adapter.read(rx_payload_mapping, 0, HIGH_PAYLOAD_BYTES, rx_after);
      if (tx_status == null || !tx_status.ok() || rx_status == null || !rx_status.ok() ||
          !bytes_equal(tx_before, tx_after) || !bytes_equal(rx_before, rx_after) ||
          tx_net.send_sequence != tx_before_sequence ||
          rx_net.receive_sequence != rx_before_sequence ||
          tx_sink.sent_count != tx_before_sent || rx_sink.receive_count != rx_before_received ||
          tx_composition_env.pending_count() != tx_before_pending ||
          rx_composition_env.pending_count() != rx_before_pending ||
          !mapping_authority_equal(tx_payload_mapping, tx_mapping_before) ||
          !mapping_authority_equal(rx_payload_mapping, rx_mapping_before)) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "queue-full post changed payload, authority, network accounting, or pending events");
        return;
      end

      // 中文设计：先经组合 engine 的公开 producer pipeline 填满 TX/RX CQ，
      // 保存每项 result.index/wrap/occupancy，再按四个一批独立 poll 两个 ring；
      // 这样 backing、runtime credit 与 WQE ledger 在整窗延迟消费期间保持一致。
      for (int unsigned slot = 0; slot < HIGH_WINDOW; slot++) begin
        tx_status = tx_composition_env.queue_data.query_runtime_producer_polarity(
          tx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, cq_polarity);
        if (tx_status == null || !tx_status.ok()) begin status = tx_status; return; end
        cqe = make_cqe(tx_env.qp, tx_window_posts[slot], 1'b0,
                       window_base + slot, cq_polarity);
        cqe.wr_id = tx_window_posts[slot].wr_id;
        cqe.opcode = RDMA_WR_SEND;
        cqe.byte_len = HIGH_PAYLOAD_BYTES;
        tx_published[slot] = null;
        tx_composition_env.queue_data.publish_cqe(
          tx_env.cq.handle, cqe, tx_published[slot], tx_status);
        if (tx_status == null || !tx_status.ok() || tx_published[slot] == null ||
            tx_published[slot].index !=
              (tx_cq_absolute + slot) % HIGH_CQ_DEPTH ||
            tx_published[slot].wrap !=
              bit'((tx_cq_absolute + slot) / HIGH_CQ_DEPTH) ||
            !tx_published[slot].occupancy_valid ||
            tx_published[slot].occupancy != slot + 1) begin
          status = tx_status == null || tx_status.ok() ?
            rdma_status::make(RDMA_SC_INVALID_STATE,
                              "TX CQ public publish result mismatch") : tx_status;
          return;
        end
        rx_status = rx_composition_env.queue_data.query_runtime_producer_polarity(
          rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, cq_polarity);
        if (rx_status == null || !rx_status.ok()) begin status = rx_status; return; end
        cqe = make_cqe(rx_env.qp, rx_window_posts[slot], 1'b1,
                       window_base + slot, cq_polarity);
        cqe.wr_id = rx_window_posts[slot].wr_id;
        cqe.opcode = RDMA_WR_RECV;
        cqe.byte_len = HIGH_PAYLOAD_BYTES;
        rx_published[slot] = null;
        rx_composition_env.queue_data.publish_cqe(
          rx_env.cq.handle, cqe, rx_published[slot], rx_status);
        if (rx_status == null || !rx_status.ok() || rx_published[slot] == null ||
            rx_published[slot].index !=
              (rx_cq_absolute + slot) % HIGH_CQ_DEPTH ||
            rx_published[slot].wrap !=
              bit'((rx_cq_absolute + slot) / HIGH_CQ_DEPTH) ||
            !rx_published[slot].occupancy_valid ||
            rx_published[slot].occupancy != slot + 1) begin
          status = rx_status == null || rx_status.ok() ?
            rdma_status::make(RDMA_SC_INVALID_STATE,
                              "RX CQ public publish result mismatch") : rx_status;
          return;
        end
      end

      local_status = tx_composition_env.queue_data.query_runtime_occupancy(
        tx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, tx_cq_used, tx_cq_pending);
      if (local_status == null || !local_status.ok() ||
          tx_cq_used != HIGH_CQ_DEPTH || tx_cq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "TX CQ did not reach committed full occupancy");
        return;
      end
      local_status = rx_composition_env.queue_data.query_runtime_occupancy(
        rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, rx_cq_used, rx_cq_pending);
      if (local_status == null || !local_status.ok() ||
          rx_cq_used != HIGH_CQ_DEPTH || rx_cq_pending) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RX CQ did not reach committed full occupancy");
        return;
      end

      completed_in_window = 0;
      for (int unsigned batch_base = 0; batch_base < HIGH_WINDOW;
           batch_base += HIGH_DRAIN_BATCH) begin
        for (int unsigned batch_slot = 0; batch_slot < HIGH_DRAIN_BATCH; batch_slot++) begin
          int unsigned slot;
          slot = batch_base + batch_slot;
          tx_composition_env.poll_completion(tx_env.cq.handle, 2us,
                                             tx_completion, tx_status);
          if (tx_status == null || !tx_status.ok() || tx_completion == null ||
              !completion_is_success(tx_completion) ||
              tx_completion.cqe.wr_id != tx_window_posts[slot].wr_id ||
              tx_completion.cqe.qpn != tx_env.qp.local_qp_id ||
              tx_completion.cqe.opcode != RDMA_WR_SEND ||
              tx_completion.released_slots.size() != 1 ||
              tx_completion.released_slots[0].wr_id != tx_window_posts[slot].wr_id ||
              tx_completion.released_slots[0].index != tx_window_posts[slot].index ||
              tx_completion.released_slots[0].wrap != tx_window_posts[slot].wrap) begin
            status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       "TX CQE poll did not release expected SQ slot");
            return;
          end
          rx_composition_env.poll_completion(rx_env.cq.handle, 2us,
                                             rx_completion, rx_status);
          if (rx_status == null || !rx_status.ok() || rx_completion == null ||
              !completion_is_success(rx_completion) ||
              rx_completion.cqe.wr_id != rx_window_posts[slot].wr_id ||
              rx_completion.cqe.qpn != rx_env.qp.local_qp_id ||
              rx_completion.cqe.opcode != RDMA_WR_RECV ||
              rx_completion.released_slots.size() != 1 ||
              rx_completion.released_slots[0].wr_id != rx_window_posts[slot].wr_id ||
              rx_completion.released_slots[0].index != rx_window_posts[slot].index ||
              rx_completion.released_slots[0].wrap != rx_window_posts[slot].wrap) begin
            status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       "RX CQE poll did not release expected RQ slot");
            return;
          end
          tx_composition_env.end_pending();
          rx_composition_env.end_pending();
          completed_in_window++;
          local_status = tx_composition_env.queue_data.query_runtime_occupancy(
            tx_env.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_used, sq_pending);
          if (local_status == null || !local_status.ok() ||
              sq_used != HIGH_WINDOW - completed_in_window || sq_pending) begin
            status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       "TX SQ credit did not decrease after CQE");
            return;
          end
          local_status = rx_composition_env.queue_data.query_runtime_occupancy(
            rx_env.qp.handle, RDMA_QUEUE_RUNTIME_RQ, rq_used, rq_pending);
          if (local_status == null || !local_status.ok() ||
              rq_used != HIGH_WINDOW - completed_in_window || rq_pending) begin
            status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       "RX RQ credit did not decrease after CQE");
            return;
          end
        end
      end
      tx_cq_absolute += HIGH_WINDOW;
      rx_cq_absolute += HIGH_WINDOW;
      // 中文设计：空 CQ 连续公开 publish 整整一个 depth 后，PI
      // index 回到窗口前手算值且 PI wrap 精确翻转；再 poll 整环后
      // CI 也回到原 index 并翻转，最终 PI/CI index+wrap 必须收敛。
      local_status = tx_composition_env.queue_data.query_runtime_cursors(
        tx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, tx_cq_pi, tx_cq_pw,
        tx_cq_ci, tx_cq_cw);
      if (local_status == null || !local_status.ok() ||
          tx_cq_pi != before_tx_cq_pi || tx_cq_pw != ~before_tx_cq_pw ||
          tx_cq_ci != before_tx_cq_ci || tx_cq_cw != ~before_tx_cq_cw ||
          tx_cq_pi != tx_cq_ci || tx_cq_pw != tx_cq_cw) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "TX CQ producer/consumer did not converge after one ring");
        return;
      end
      local_status = rx_composition_env.queue_data.query_runtime_cursors(
        rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, rx_cq_pi, rx_cq_pw,
        rx_cq_ci, rx_cq_cw);
      if (local_status == null || !local_status.ok() ||
          rx_cq_pi != before_rx_cq_pi || rx_cq_pw != ~before_rx_cq_pw ||
          rx_cq_ci != before_rx_cq_ci || rx_cq_cw != ~before_rx_cq_cw ||
          rx_cq_pi != rx_cq_ci || rx_cq_pw != rx_cq_cw) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RX CQ producer/consumer did not converge after one ring");
        return;
      end
      local_status = tx_composition_env.queue_data.query_runtime_cursors(
        tx_env.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_pi, sq_pw, sq_ci, sq_cw);
      if (local_status == null || !local_status.ok() || sq_pi != sq_ci || sq_pw != sq_cw) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "TX SQ PI/CI did not converge after window drain");
        return;
      end
      local_status = rx_composition_env.queue_data.query_runtime_cursors(
        rx_env.qp.handle, RDMA_QUEUE_RUNTIME_RQ, rq_pi, rq_pw, rq_ci, rq_cw);
      if (local_status == null || !local_status.ok() || rq_pi != rq_ci || rq_pw != rq_cw) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RX RQ PI/CI did not converge after window drain");
        return;
      end
      if (tx_composition_env.pending_count() != 0 ||
          rx_composition_env.pending_count() != 0) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "Function-qualified events did not drain after window");
        return;
      end
      // 发送历史只用于本窗口的 queue-full 网络计数采样；删除它避免 4096 个
      // raw frame 常驻内存。receive_queue 已逐包消费，不能在这里误删诊断数据。
      tx_sink.sent_packets.delete();
    end
    if (!saw_sq_wrap || !saw_rq_wrap) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "high-traffic run did not exercise ring wrap");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：配置双 Function 组合层、运行高流量窗口测试并统一释放 mapping/queue。
  // 输入/输出及副作用：phase（输入）；管理 objection，最终检查网络总数、pending、
  //   ring 归零和两个 adapter/host-memory manager 的资源泄漏。
  // 失败/边界：setup 或 traffic 失败会报告首个错误但仍清空 pending 并执行 cleanup；
  //   cleanup 不尝试重放未完成 CQE，避免把故障路径伪装成正常完成。
  task run_phase(uvm_phase phase);
    rdma_status status;
    int unsigned sq_used;
    int unsigned rq_used;
    bit sq_pending;
    bit rq_pending;

    phase.raise_objection(this);
    configure_envs(status);
    if (status != null && status.ok())
      configure_composition_envs(status);
    if (status == null || !status.ok()) begin
      `uvm_error("HIGH_TRAFFIC_SETUP", status == null ? "null setup status" :
                 status.convert2string())
    end
    else begin
      run_high_traffic(status);
      if (status == null || !status.ok())
        `uvm_error("HIGH_TRAFFIC_TRAFFIC", status == null ? "null traffic status" :
                   status.convert2string())
      if (tx_net.send_sequence != HIGH_PACKET_COUNT ||
          rx_net.receive_sequence != HIGH_PACKET_COUNT ||
          tx_sink.sent_count != HIGH_PACKET_COUNT ||
          rx_sink.receive_count != HIGH_PACKET_COUNT)
        `uvm_error("HIGH_TRAFFIC_COUNTS", $sformatf(
          "network counts tx_seq=%0d rx_seq=%0d tx_sink=%0d rx_sink=%0d",
          tx_net.send_sequence, rx_net.receive_sequence,
          tx_sink.sent_count, rx_sink.receive_count))
      if (tx_composition_env.pending_count() != 0 || rx_composition_env.pending_count() != 0)
        `uvm_error("HIGH_TRAFFIC_PENDING", $sformatf(
          "pending did not drain tx=%0d rx=%0d", tx_composition_env.pending_count(),
          rx_composition_env.pending_count()))
      status = tx_composition_env.queue_data.query_runtime_occupancy(
        tx_env.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_used, sq_pending);
      if (status == null || !status.ok() || sq_used != 0 || sq_pending)
        `uvm_error("HIGH_TRAFFIC_TX_CREDIT", "TX SQ did not fully drain")
      status = rx_composition_env.queue_data.query_runtime_occupancy(
        rx_env.qp.handle, RDMA_QUEUE_RUNTIME_RQ, rq_used, rq_pending);
      if (status == null || !status.ok() || rq_used != 0 || rq_pending)
        `uvm_error("HIGH_TRAFFIC_RX_CREDIT", "RX RQ did not fully drain")
    end
    drain_composition_pending();
    cleanup_composition_data_paths(status);
    if (status == null || !status.ok())
      `uvm_error("HIGH_TRAFFIC_COMPOSITION_CLEANUP",
                 status == null ? "null cleanup status" : status.convert2string())
    cleanup_env("high_tx", tx_env, tx_host_adapter, tx_payload_mapping);
    cleanup_env("high_rx", rx_env, rx_host_adapter, rx_payload_mapping);
    if (tx_host_mem != null)
      tx_host_mem.leak_check(`__FILE__, `__LINE__);
    if (rx_host_mem != null)
      rx_host_mem.leak_check(`__FILE__, `__LINE__);
    phase.drop_objection(this);
  endtask
endclass
