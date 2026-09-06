// 目录：测试层 tests/integration/。
// 职责：使用两套相互隔离的 host-memory/queue/net_packet 环境，跑通一条
//   发送端 SQ -> RoCEv2 frame -> 接收端 RQ -> 双端 CQ 的完整业务路径。
// 依赖：真实 host_mem_manager、rdma_host_mem_adapter、queue-data fixture、
//   rdma_net_packet_adapter 和 rdma_net_packet_queue_sink；外部源码只通过
//   filelist 路径引用，本文件不复制或修改外部组件。
// 所有权与生命周期：测试独占 tx/rx fixture、host-memory manager、adapter、
//   sink 和 payload mapping；每个 mapping 先显式 release，再销毁 QP/CQ/CEQ，
//   最后以 adapter.check_leaks() 和 host_mem.leak_check() 验证没有残留资源。

// 中文说明：该测试故意把发送端和接收端放在不同 Function/IOVA/物理区间，
// 从而验证多 Host 场景下不能通过默认 root/PF 或别名 mapping 误串线。
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

class rdma_end_to_end_dual_env_test extends uvm_test;
  `uvm_component_utils(rdma_end_to_end_dual_env_test)

  localparam int unsigned PACKET_COUNT = 128;
  localparam int unsigned PAYLOAD_BYTES = 256;
  localparam int unsigned CQ_DEPTH = 16;
  // CQ 生命周期策略为硬件 CQ ring 选择 1 作为首个 slot 的 owner，后续
  // 每次 ring wrap 翻转一次；测试生成的 CQE 必须遵循该 runtime 约定。
  localparam bit CQ_INITIAL_POLARITY = 1'b1;

  rdma_queue_data_engine_fixture tx_env;
  rdma_queue_data_engine_fixture rx_env;
  $unit::host_mem_manager tx_host_mem;
  $unit::host_mem_manager rx_host_mem;
  rdma_host_mem_adapter tx_host_adapter;
  rdma_host_mem_adapter rx_host_adapter;
  rdma_real_host_mem_proxy tx_mem_proxy;
  rdma_real_host_mem_proxy rx_mem_proxy;
  rdma_net_packet_queue_sink tx_sink;
  rdma_net_packet_queue_sink rx_sink;
  rdma_net_packet_adapter tx_net;
  rdma_net_packet_adapter rx_net;
  rdma_dma_mapping tx_payload_mapping;
  rdma_dma_mapping rx_payload_mapping;

  // 功能：构造双 env 测试组件，只建立 UVM 层级和空依赖句柄。
  // 输入/输出及副作用：name、parent（输入）；调用 super.new，不访问外部
  //   host_mem、PCIe 或网络资源。
  // 失败/边界：构造成功不代表环境可用；run_phase 必须先完成 configure_envs。
  function new(string name = "rdma_end_to_end_dual_env_test",
               uvm_component parent = null);
    super.new(name, parent);
    tx_env = null;
    rx_env = null;
    tx_host_mem = null;
    rx_host_mem = null;
    tx_host_adapter = null;
    rx_host_adapter = null;
    tx_mem_proxy = null;
    rx_mem_proxy = null;
    tx_sink = null;
    rx_sink = null;
    tx_net = null;
    rx_net = null;
    tx_payload_mapping = null;
    rx_payload_mapping = null;
  endfunction

  // 功能：为一个 fixture 构造与其 Function/DMA route 一致的请求上下文。
  // 输入/输出及副作用：fixture、name（输入）；返回新的 detached context，
  //   不修改 fixture.binding，也不取得 host-memory 所有权。
  // 失败/边界：fixture 或 binding 未 setup 时返回 null；调用方必须检查
  //   function_h/owner_h 是否为空后再调用 adapter.allocate。
  function automatic rdma_dma_request_context make_dma_context(
    rdma_queue_data_engine_fixture fixture,
    string name
  );
    rdma_dma_request_context dma_ctx;
    rdma_function_handle function_h;

    dma_ctx = null;
    if (fixture == null || fixture.binding == null)
      return dma_ctx;
    function_h = fixture.binding.make_handle();
    if (function_h == null)
      return dma_ctx;
    dma_ctx = rdma_dma_request_context::type_id::create(name);
    dma_ctx.function_h = function_h;
    dma_ctx.requester_bdf = fixture.binding.queue_dma.requester_bdf;
    dma_ctx.pasid_valid = fixture.binding.queue_dma.pasid_valid;
    dma_ctx.pasid = fixture.binding.queue_dma.pasid;
    dma_ctx.dma_domain_valid = fixture.binding.queue_dma.dma_domain_valid;
    dma_ctx.dma_domain_id = fixture.binding.queue_dma.dma_domain_id;
    dma_ctx.owner_h = rdma_clone_handle_value(function_h,
                                               {name, "_owner"});
    if (dma_ctx.owner_h == null)
      dma_ctx = null;
    return dma_ctx;
  endfunction

  // 功能：在指定 host_mem manager 中建立独立的真实 payload mapping。
  // 输入/输出及副作用：fixture、adapter、name、direction（输入）；mapping
  //   （输出）；成功时 host_mem 实际分配 backing 并由 adapter 登记 authority。
  // 失败/边界：上下文无效、分配失败或返回非 ACTIVE mapping 时返回错误；
  //   失败路径不得保留半分配 backing。
  function automatic rdma_status allocate_payload_mapping(
    rdma_queue_data_engine_fixture fixture,
    rdma_host_mem_adapter adapter,
    string name,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_dma_request_context dma_ctx;
    rdma_status status;

    mapping = null;
    if (fixture == null || adapter == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "payload mapping fixture or adapter is null");
    dma_ctx = make_dma_context(fixture, {name, "_context"});
    if (dma_ctx == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "payload DMA context could not be built");
    status = adapter.allocate(dma_ctx, PAYLOAD_BYTES, 64,
                              direction, mapping);
    if (status == null || !status.ok() || mapping == null ||
        mapping.state != RDMA_MAPPING_ACTIVE)
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "payload mapping allocation returned null status") :
        status;
    return rdma_status::success();
  endfunction

  // 功能：建立两套真实 host-memory fixture，并绑定独立的 net_packet sink/adapter。
  // 输入/输出及副作用：无显式参数；创建并配置 tx/rx manager、adapter、proxy、
  //   queue fixture 和 network authority，实际分配多组 SQ/RQ/CQ backing。
  // 失败/边界：任一 setup/configure/allocate 失败立即返回错误；调用方必须在
  //   返回失败后执行 cleanup_envs，不能继续发布网络事务。
  task automatic configure_envs(output rdma_status status);
    rdma_function_identity tx_identity;
    rdma_function_identity rx_identity;

    status = rdma_status::success();
    tx_host_mem = $unit::host_mem_manager::type_id::create("tx_host_mem");
    rx_host_mem = $unit::host_mem_manager::type_id::create("rx_host_mem");
    // 物理 backing 区间不相交，且分别设置不同 host_id，模拟多 Host fabric。
    tx_host_mem.init_region(64'h0000_0008_0000_0000,
                            64'h0000_0008_00ff_ffff,
                            MODE_BUDDY, 16, 8'hd1);
    rx_host_mem.init_region(64'h0000_0009_0000_0000,
                            64'h0000_0009_00ff_ffff,
                            MODE_BUDDY, 16, 8'he2);
    tx_host_mem.set_host_id(1);
    rx_host_mem.set_host_id(2);

    tx_host_adapter = rdma_host_mem_adapter::type_id::create("tx_host_adapter");
    rx_host_adapter = rdma_host_mem_adapter::type_id::create("rx_host_adapter");
    tx_host_adapter.mem = tx_host_mem;
    rx_host_adapter.mem = rx_host_mem;
    tx_host_adapter.iova_base = 64'h0000_0010_0000_0000;
    rx_host_adapter.iova_base = 64'h0000_0020_0000_0000;

    tx_mem_proxy = rdma_real_host_mem_proxy::type_id::create("tx_mem_proxy");
    rx_mem_proxy = rdma_real_host_mem_proxy::type_id::create("rx_mem_proxy");
    tx_mem_proxy.delegate = tx_host_adapter;
    rx_mem_proxy.delegate = rx_host_adapter;

    tx_env = rdma_queue_data_engine_fixture::type_id::create("tx_env");
    rx_env = rdma_queue_data_engine_fixture::type_id::create("rx_env");
    tx_env.mem = tx_mem_proxy;
    rx_env.mem = rx_mem_proxy;
    tx_env.setup(status);
    if (status == null || !status.ok())
      return;
    rx_env.setup(status);
    if (status == null || !status.ok())
      return;

    tx_sink = rdma_net_packet_queue_sink::type_id::create("tx_sink");
    rx_sink = rdma_net_packet_queue_sink::type_id::create("rx_sink");
    tx_net = rdma_net_packet_adapter::type_id::create("tx_net");
    rx_net = rdma_net_packet_adapter::type_id::create("rx_net");
    status = tx_net.configure_sink(tx_sink);
    if (!status.ok()) return;
    status = rx_net.configure_sink(rx_sink);
    if (!status.ok()) return;
    tx_identity = tx_env.binding.function_identity_snapshot();
    rx_identity = rx_env.binding.function_identity_snapshot();
    status = tx_net.configure_function(tx_identity);
    if (!status.ok()) return;
    status = rx_net.configure_function(rx_identity);
    if (!status.ok()) return;

    status = allocate_payload_mapping(tx_env, tx_host_adapter,
                                      "tx_payload", RDMA_DMA_DEVICE_READ,
                                      tx_payload_mapping);
    if (!status.ok()) return;
    status = allocate_payload_mapping(rx_env, rx_host_adapter,
                                      "rx_payload", RDMA_DMA_DEVICE_WRITE,
                                      rx_payload_mapping);
  endtask

  // 功能：生成确定性 payload，使每个包在大流量运行中都能做逐字节比对。
  // 输入/输出及副作用：packet_index（输入）、payload（输出）；只写入新的
  //   byte queue，不访问 host_mem 或网络 adapter。
  // 失败/边界：固定长度为 PAYLOAD_BYTES；packet_index 只影响内容模式，不会溢出
  //   byte 类型（显式截断为低 8 位是测试定义的一部分）。
  function automatic void make_payload(
    int unsigned packet_index,
    output byte unsigned payload[$]
  );
    payload.delete();
    for (int unsigned i = 0; i < PAYLOAD_BYTES; i++)
      payload.push_back(byte'((packet_index * 13 + i) & 8'hff));
  endfunction

  // 功能：构造与两端 QP 关联的 RDMA SEND 语义 packet。
  // 输入/输出及副作用：packet_index、payload（输入）；返回新建 detached packet，
  //   不修改 queue engine 或 host-memory 游标。
  // 失败/边界：payload 为空仍返回对象，由 send_packet/build_packet 负责拒绝；
  //   QPN 必须在调用前由已 setup 的 fixture 提供。
  function automatic rdma_packet make_network_packet(
    int unsigned packet_index,
    byte unsigned payload[$]
  );
    rdma_packet packet;

    packet = rdma_packet::type_id::create(
      $sformatf("tx_packet_%0d", packet_index));
    packet.transport = RDMA_TRANSPORT_RC;
    packet.opcode = RDMA_NET_SEND;
    packet.source_qpn = tx_env.qp.local_qp_id;
    packet.destination_qpn = rx_env.qp.local_qp_id;
    packet.psn = packet_index[23:0];
    packet.payload = payload;
    return packet;
  endfunction

  // 功能：生成设备侧 CQE，分别表示发送 SQ 或接收 RQ 的 WQE 已完成。
  // 输入/输出及副作用：qp、posted、rq_cqe、packet_index、cq_slot（输入）；返回
  //   新建 CQE 值对象，不写入 CQ backing。
  // 失败/边界：posted 为空时仍生成占位 index=0，调用方必须在写 CQE 前检查
  //   post status；cq_slot 用于计算 owner polarity 的 wrap。
  function automatic rdma_hw_cqe_model make_cqe(
    rdma_qp qp,
    rdma_queue_post_result posted,
    bit rq_cqe,
    int unsigned packet_index,
    int unsigned cq_slot
  );
    rdma_hw_cqe_model cqe;

    cqe = rdma_hw_cqe_model::type_id::create(
      $sformatf("e2e_cqe_%0d_%0d", packet_index, rq_cqe));
    cqe.qp_h = (qp == null) ? null :
               rdma_clone_handle_value(qp.handle, "e2e CQE QP");
    cqe.qpn = qp == null ? 0 : qp.local_qp_id;
    cqe.wqe_index = posted == null ? 0 : posted.index;
    cqe.wqe_wrap = posted == null ? 0 : posted.wrap;
    cqe.rq_cqe = rq_cqe;
    cqe.polarity = CQ_INITIAL_POLARITY ^ bit'(cq_slot / CQ_DEPTH);
    cqe.packet_opcode = 8'h01;
    cqe.ecode = RDMA_CMQ_SUCCESS_ECODE;
    cqe.payload_len = PAYLOAD_BYTES;
    cqe.status = rdma_status::success();
    return cqe;
  endfunction

  // 功能：在 CQ backing 写入一个 CQE 并轮询一次，验证 CI 提交、WQE release
  //   和 detached completion 的 WR ID/状态。
  // 输入/输出及副作用：env、posted、rq_cqe、packet_index、cq_slot（输入）；
  //   写入真实 host_mem 并推进该 env 的 CQ consumer cursor。
  // 失败/边界：任一 write/poll/route/status 失败返回错误；失败时 result 保持
  //   为空，调用方不得将该包计入成功吞吐。
  task automatic publish_and_poll_cqe(
    rdma_queue_data_engine_fixture env,
    rdma_qp qp,
    rdma_queue_post_result posted,
    bit rq_cqe,
    int unsigned packet_index,
    int unsigned cq_slot,
    output rdma_status status
  );
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;

    status = rdma_status::success();
    cqe = make_cqe(qp, posted, rq_cqe, packet_index, cq_slot);
    status = env.write_cq_entry(cq_slot % CQ_DEPTH, cqe);
    if (status == null || !status.ok())
      return;
    completion = null;
    env.engine.poll_cqe(env.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.cqe == null || completion.cqe.wr_id != posted.wr_id ||
        completion.completion_status == null ||
        !completion.completion_status.ok()) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "E2E CQ poll did not return expected completion");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：逐包执行双 env 的发送、网络转发、接收 payload 写入和双 CQ completion。
  // 输入/输出及副作用：无显式参数；PACKET_COUNT 次写入/读取真实 host_mem，
  //   发送端和接收端各推进 SQ/RQ/CQ PI/CI，并把 net frame 经过 sink loopback。
  // 失败/边界：单包失败立即停止，保留首个错误状态；每包都在 poll 后才进入
  //   下一次 post，避免 depth=16 ring 溢出并覆盖未消费的 WQE。
  task automatic run_traffic(output rdma_status status);
    rdma_post_recv_req recv_request;
    rdma_post_send_req send_request;
    rdma_queue_post_result recv_posted;
    rdma_queue_post_result send_posted;
    rdma_packet network_packet;
    rdma_packet received_packet;
    rdma_status tx_status;
    rdma_status rx_status;
    rdma_status cqe_status;
    byte unsigned payload[$];
    byte write_data[];
    byte tx_readback[];
    byte rx_readback[];
    int unsigned tx_cq_slot;
    int unsigned rx_cq_slot;
    int unsigned expected_sq_index;
    int unsigned expected_rq_index;
    bit expected_sq_wrap;
    bit expected_rq_wrap;

    status = rdma_status::success();
    tx_cq_slot = 0;
    rx_cq_slot = 0;
    expected_sq_index = 0;
    expected_rq_index = 0;
    expected_sq_wrap = 0;
    expected_rq_wrap = 0;
    for (int unsigned i = 0; i < PACKET_COUNT; i++) begin
      make_payload(i, payload);
      write_data = new[payload.size()];
      foreach (payload[j])
        write_data[j] = payload[j];
      tx_status = tx_host_adapter.write(tx_payload_mapping, 0, write_data);
      if (tx_status == null || !tx_status.ok()) begin
        status = tx_status;
        return;
      end
      tx_status = tx_host_adapter.read(tx_payload_mapping, 0,
                                       PAYLOAD_BYTES, tx_readback);
      if (tx_status == null || !tx_status.ok() || tx_readback.size() != PAYLOAD_BYTES) begin
        status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                   "TX payload host_mem readback failed");
        return;
      end
      foreach (payload[j])
        if (tx_readback[j] !== payload[j]) begin
          status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                     "TX payload host_mem readback mismatch");
          return;
        end

      recv_request = rx_env.make_recv(64'h7000_0000_0000_0000 + i);
      recv_request.sges[0].iova = rx_payload_mapping.iova;
      recv_request.sges[0].length = PAYLOAD_BYTES;
      recv_request.sges[0].lkey = 32'hbabe_0001;
      rx_env.engine.post_recv(recv_request, recv_posted, rx_status);
      if (rx_status == null || !rx_status.ok() || recv_posted == null) begin
        status = rx_status;
        return;
      end
      if (recv_posted.index != expected_rq_index ||
          recv_posted.wrap != expected_rq_wrap) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RQ producer index/wrap did not advance as expected");
        return;
      end
      expected_rq_index++;
      if (expected_rq_index == 16) begin
        expected_rq_index = 0;
        expected_rq_wrap = ~expected_rq_wrap;
      end

      send_request = tx_env.make_send(64'h5000_0000_0000_0000 + i);
      send_request.sges[0].iova = tx_payload_mapping.iova;
      send_request.sges[0].length = PAYLOAD_BYTES;
      send_request.sges[0].lkey = 32'hfeed_0001;
      tx_env.engine.post_send(send_request, send_posted, tx_status);
      if (tx_status == null || !tx_status.ok() || send_posted == null) begin
        status = tx_status;
        return;
      end
      if (send_posted.index != expected_sq_index ||
          send_posted.wrap != expected_sq_wrap) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "SQ producer index/wrap did not advance as expected");
        return;
      end
      expected_sq_index++;
      if (expected_sq_index == 16) begin
        expected_sq_index = 0;
        expected_sq_wrap = ~expected_sq_wrap;
      end

      network_packet = make_network_packet(i, payload);
      tx_net.send_packet(network_packet, tx_status);
      if (tx_status == null || !tx_status.ok() || tx_net.last_sent_packet == null) begin
        status = tx_status;
        return;
      end
      // sink.enqueue() 会复制完整 raw frame，模拟真实链路把发送端 packet
      // 交给接收端；接收 adapter 仍负责独立 unpack/decode/checksum 验证。
      rx_sink.enqueue(tx_net.last_sent_packet);
      rx_net.receive_packet(received_packet, rx_status);
      if (rx_status == null || !rx_status.ok() || received_packet == null ||
          received_packet.payload.size() != payload.size() ||
          received_packet.source_qpn != network_packet.source_qpn ||
          received_packet.destination_qpn != network_packet.destination_qpn) begin
        status = rx_status == null ?
          rdma_status::make(RDMA_SC_CODEC_ERROR,
                            "RX net_packet decode returned null status") :
          rx_status;
        return;
      end
      foreach (payload[j])
        if (received_packet.payload[j] !== payload[j]) begin
          status = rdma_status::make(RDMA_SC_CODEC_ERROR,
                                     "RX net_packet payload differs from TX");
          return;
        end
      write_data = new[received_packet.payload.size()];
      foreach (received_packet.payload[j])
        write_data[j] = received_packet.payload[j];
      rx_status = rx_host_adapter.write(rx_payload_mapping, 0, write_data);
      if (rx_status == null || !rx_status.ok()) begin
        status = rx_status;
        return;
      end
      rx_status = rx_host_adapter.read(rx_payload_mapping, 0,
                                       PAYLOAD_BYTES, rx_readback);
      if (rx_status == null || !rx_status.ok() || rx_readback.size() != PAYLOAD_BYTES) begin
        status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                   "RX payload host_mem readback failed");
        return;
      end
      foreach (payload[j])
        if (rx_readback[j] !== payload[j]) begin
          status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                     "RX payload host_mem readback mismatch");
          return;
        end

      publish_and_poll_cqe(tx_env, tx_env.qp, send_posted, 1'b0,
                           i, tx_cq_slot, cqe_status);
      if (cqe_status == null || !cqe_status.ok()) begin
        status = cqe_status;
        return;
      end
      tx_cq_slot++;
      publish_and_poll_cqe(rx_env, rx_env.qp, recv_posted, 1'b1,
                           i, rx_cq_slot, cqe_status);
      if (cqe_status == null || !cqe_status.ok()) begin
        status = cqe_status;
        return;
      end
      rx_cq_slot++;
    end
    status = rdma_status::success();
  endtask

  // 功能：销毁 fixture 的 QP/CQ/CEQ，并释放真实 adapter 的 payload mapping。
  // 输入/输出及副作用：env、adapter、mapping（输入）；向 lifecycle executor
  //   提交 destroy，释放 host_mem backing，并通过 leak_count 输出 owner 账本状态。
  // 失败/边界：任一 release/destroy 失败记录 UVM error 但继续清理其余资源，
  //   防止一个失败路径掩盖其它 mapping 泄漏。
  task automatic cleanup_env(
    string tag,
    rdma_queue_data_engine_fixture env,
    rdma_host_mem_adapter adapter,
    inout rdma_dma_mapping mapping
  );
    rdma_status status;
    rdma_control_result destroy_result;
    rdma_destroy_resource_req destroy_request;
    int unsigned leak_count;

    if (adapter != null && mapping != null) begin
      status = adapter.\release (mapping);
      if (status == null || !status.ok())
        `uvm_error("E2E_RELEASE", $sformatf("%s payload release failed: %s",
                    tag, status == null ? "null" : status.convert2string()))
      mapping = null;
    end
    if (env == null || env.binding == null)
      return;
    if (env.qp != null) begin
      destroy_request = rdma_destroy_resource_req::type_id::create(
        {tag, "_destroy_qp"});
      destroy_request.owner = env.binding.make_handle();
      destroy_request.target_h = env.qp.handle;
      env.qp_executor.destroy_locked(env.binding, env.binding.make_handle(),
                                     destroy_request, 64'h3001,
                                     destroy_result);
    end
    if (env.cq != null) begin
      destroy_request = rdma_destroy_resource_req::type_id::create(
        {tag, "_destroy_cq"});
      destroy_request.owner = env.binding.make_handle();
      destroy_request.target_h = env.cq.handle;
      env.queue_executor.destroy_locked(env.binding, env.binding.make_handle(),
                                        destroy_request, 64'h3002,
                                        destroy_result);
    end
    if (env.ceq != null) begin
      destroy_request = rdma_destroy_resource_req::type_id::create(
        {tag, "_destroy_ceq"});
      destroy_request.owner = env.binding.make_handle();
      destroy_request.target_h = env.ceq.handle;
      env.queue_executor.destroy_locked(env.binding, env.binding.make_handle(),
                                        destroy_request, 64'h3003,
                                        destroy_result);
    end
    if (adapter != null) begin
      status = adapter.check_leaks(leak_count);
      if (status == null || !status.ok() || leak_count != 0)
        `uvm_error("E2E_ADAPTER_LEAK", $sformatf(
          "%s adapter leak check failed: %s leaks=%0d", tag,
          status == null ? "null" : status.convert2string(), leak_count))
    end
  endtask

  // 功能：运行配置、128 包大流量闭环和最终 host_mem 全局 leak 检查。
  // 输入/输出及副作用：phase（输入）；管理 UVM objection，驱动所有端到端
  //   事务，结束时释放 mapping/queue 资源并执行 manager.leak_check。
  // 失败/边界：配置或流量失败会报告首个错误但仍进入 cleanup；cleanup 必须
  //   在 drop_objection 前完成，避免仿真提前退出留下外部 allocation。
  task run_phase(uvm_phase phase);
    rdma_status status;

    phase.raise_objection(this);
    configure_envs(status);
    if (status == null || !status.ok()) begin
      `uvm_error("E2E_SETUP", status == null ? "null setup status" :
                 status.convert2string())
    end
    else begin
      run_traffic(status);
      if (status == null || !status.ok())
        `uvm_error("E2E_TRAFFIC", status == null ? "null traffic status" :
                   status.convert2string())
      if (tx_net.send_sequence != PACKET_COUNT ||
          rx_net.receive_sequence != PACKET_COUNT ||
          tx_sink.sent_count != PACKET_COUNT ||
          rx_sink.receive_count != PACKET_COUNT)
        `uvm_error("E2E_COUNTS", $sformatf(
          "unexpected network counts tx_seq=%0d rx_seq=%0d tx_sink=%0d rx_sink=%0d",
          tx_net.send_sequence, rx_net.receive_sequence,
          tx_sink.sent_count, rx_sink.receive_count))
      if (tx_payload_mapping == null || rx_payload_mapping == null ||
          tx_payload_mapping.iova.value == rx_payload_mapping.iova.value ||
          tx_payload_mapping.backing_addr.value == rx_payload_mapping.backing_addr.value)
        `uvm_error("E2E_ISOLATION", "TX/RX payload mappings are not isolated")
    end

    cleanup_env("tx", tx_env, tx_host_adapter, tx_payload_mapping);
    cleanup_env("rx", rx_env, rx_host_adapter, rx_payload_mapping);
    if (tx_host_mem != null)
      tx_host_mem.leak_check(`__FILE__, `__LINE__);
    if (rx_host_mem != null)
      rx_host_mem.leak_check(`__FILE__, `__LINE__);
    phase.drop_objection(this);
  endtask
endclass
