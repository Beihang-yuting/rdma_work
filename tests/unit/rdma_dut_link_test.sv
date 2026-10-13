// 目录：单元测试层 tests/unit/rdma_dut_link_test.sv。
// 层次：真实 DUT 网络边界测试。
// 职责：验证 memory endpoint 的 frame 复制、rdma_dut_link 的模型→DUT 编码投递和 DUT→link 解码统计。
// 依赖：rdma_env_pkg（rdma_dut_link/endpoint）、rdma_netpkt_pkg；不创建模型 Function 或 NIC。
// 所有权与生命周期：测试拥有 endpoint、codec 和 packet；link 作为 UVM 子组件管理接收线程。
class rdma_dut_link_test extends uvm_test;
  `uvm_component_utils(rdma_dut_link_test)

  rdma_memory_frame_endpoint endpoint;
  rdma_dut_link link;
  localparam bit [47:0] DUT_MAC = 48'h02_00_00_00_20_00;
  localparam int unsigned DUT_PORT = 3;

  // 功能：构造 DUT link 边界测试组件。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；endpoint/link 在 build_phase 创建。
  // 失败/边界：顶层 test 的 parent 可为空；真实 endpoint 不参与本用例。
  function new(string name = "rdma_dut_link_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建 memory endpoint 和 DUT link，并在 link 启动前绑定端口与 DUT MAC。
  // 输入/输出及副作用：link 成为 UVM 子组件，endpoint 由测试拥有；绑定失败报告 UVM fatal。
  // 失败/边界：重复绑定或零 MAC 会被 link 拒绝；本用例不把 DUT 注册为模型 Function。
  function void build_phase(uvm_phase phase);
    rdma_status status;

    super.build_phase(phase);
    endpoint = rdma_memory_frame_endpoint::type_id::create("memory_endpoint");
    link = rdma_dut_link::type_id::create("dut_link", this);
    status = link.bind_endpoint(endpoint, DUT_PORT, DUT_MAC);
    if (!status.ok())
      `uvm_fatal("DUT_LINK_BIND", status.convert2string())
  endfunction

  // 功能：生成固定语义 SEND packet，供 link 编码后注入 endpoint。
  // 输入/输出及副作用：返回测试拥有的 packet；不访问 QP、MR 或模型 NIC。
  // 失败/边界：payload 和 QPN/PSN 必须能被 codec 编码；目标 MAC 由调用者传给 link.transmit。
  function rdma_packet make_packet(string name);
    rdma_packet pkt;

    pkt = rdma_packet::type_id::create(name);
    pkt.transport = RDMA_TRANSPORT_RC;
    pkt.opcode = RDMA_NET_SEND;
    pkt.destination_qpn = 24'h12345;
    pkt.source_qpn = 24'h23456;
    pkt.psn = 24'h000123;
    pkt.payload = '{8'hca, 8'hfe, 8'hba, 8'hbe};
    return pkt;
  endfunction

  // 功能：验证 link 编码并将独立 Ethernet frame 投递到 memory endpoint 的 to_dut mailbox。
  // 输入/输出及副作用：发送一帧并读取 frame 副本；不把报文交给模型 NIC。
  // 失败/边界：等待 link run_phase 启动；空帧、错误端口或 tx 计数不符合预期均报告错误。
  task test_model_to_dut();
    rdma_packet pkt;
    byte unsigned frame[$];

    while (!link.is_running())
      #(1ns);
    pkt = make_packet("model_to_dut");
    link.transmit(0, pkt, DUT_MAC);
    if (!endpoint.try_pop_to_dut(DUT_PORT, frame)) begin
      `uvm_error("DUT_LINK_TX", "model packet did not reach DUT endpoint")
      return;
    end
    if (frame.size() < 64 || link.tx_frames_sent != 1)
      `uvm_error("DUT_LINK_TX_FRAME", $sformatf("frame=%0d tx_count=%0d", frame.size(),
                                                link.tx_frames_sent))
  endtask

  // 功能：把 codec 生成的 DUT TX frame 注入 endpoint，确认 link 解码并只增加 RX 观测计数。
  // 输入/输出及副作用：向 from_dut mailbox 写一帧并等待 rx_frames_captured；不触发模型 NIC receive。
  // 失败/边界：编码失败、接收线程未运行或 decode 失败均报告错误；该测试不要求存在模型 Function 路由。
  task test_dut_to_model_observation();
    rdma_packet pkt;
    rdma_netpkt_codec codec;
    byte unsigned frame[$];
    rdma_status status;
    int unsigned deadline;

    pkt = make_packet("dut_to_model");
    codec = rdma_netpkt_codec::type_id::create("dut_codec");
    status = codec.encode(pkt, frame);
    if (!status.ok()) begin
      `uvm_error("DUT_LINK_RX_ENCODE", status.convert2string())
      return;
    end
    status = endpoint.inject_dut_tx(DUT_PORT, frame);
    if (!status.ok()) begin
      `uvm_error("DUT_LINK_RX_INJECT", status.convert2string())
      return;
    end
    deadline = 100;
    while (link.rx_frames_captured == 0 && deadline != 0) begin
      #1ns;
      deadline--;
    end
    if (link.rx_frames_captured != 1 || link.decode_errors != 0)
      `uvm_error("DUT_LINK_RX", $sformatf("rx_count=%0d decode_errors=%0d",
                                           link.rx_frames_captured, link.decode_errors))
  endtask

  // 功能：执行模型出站和 DUT 入站两个方向的 endpoint/link 契约测试。
  // 输入/输出及副作用：持有 UVM objection 直到 frame 收发和线程收敛；结束时由 link final_phase 停止 endpoint。
  // 失败/边界：任一方向失败由 UVM 汇总；没有模型 Function 时 RX 观测使用 DUT 哨兵目的下标。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_model_to_dut();
    test_dut_to_model_observation();
    phase.drop_objection(this);
  endtask
endclass
