// 目录：单元测试层 tests/unit/rdma_drv_reliability_test.sv。
// 层：单元测试。
// 职责：两节点（复用 rdma_drv_data_test 的节点、链路与辅助）的可靠传输与异常路径：中间包丢失后从
//   PSN 序列 NAK 指出的 PSN 起重传、中间 AckReq 的累计 ACK 与 SEND/WRITE 超时部分重传、
//   RNR 后旧累计 ACK 与新 sequence NAK 的代次交错、QP 重建时序列/RNR 门控清理、transport/QPC 准入、
//   ACK/ATOMIC ACK 丢失后的重复请求处理（不重复执行）、READ 末段响应丢失后只重新请求缺失部分、
//   RNR NAK 按定时器编码等待的重试与耗尽（0xB7）、URC 的 SQ/RQ 异常
//   完成（ABNML CEQE 或 AEQE → REM_ACCESS/REM_INV_REQ + FLUSH、RQ 0x9C）、UD 的 Q_Key 校验与 40B
//   GRH、SRQ 3 SGE 走 SGB。
// 依赖：rdma_drv_data_test。
// 所有权：同 rdma_drv_data_test。
// 生命周期：run_phase 内建立并运行到结束。

class rdma_drv_reliability_test extends rdma_drv_data_test;
  `uvm_component_utils(rdma_drv_reliability_test)

  // 5 个 1024B PMTU 分段：默认 ACK_REQ_TH=3 会在第 3 段产生中间 ACK，末两段可用于验证部分重传。
  localparam int unsigned PARTIAL_RETRY_BYTES = 4 * 1024 + 1;

  // 先错后对的 UD 发送 Q_Key（B 的 UD QP Q_Key 为 0x22220002）。
  bit [31:0] ud_qkeys[2];

  // 功能：构造可执行可靠性场景的 UVM 测试组件，预置一个错误和一个正确的 UD Q_Key 序列。
  // 输入/输出及副作用：name/parent 透传给 rdma_drv_data_test；ud_qkeys 设为 0x22220003/0x22220002，
  //   节点、QP 与链路仍由父类 run_phase 创建和释放。
  // 失败/边界：parent=null 是顶层 test 的正常形式；构造阶段不访问 DUT，资源错误在父类 run_phase 报告。
  function new(string name = "rdma_drv_reliability_test", uvm_component parent = null);
    super.new(name, parent);
    ud_qkeys = '{32'h2222_0003, 32'h2222_0002};
  endfunction

  // 功能：依次执行各用例（RC QP 的 RTO 编码 3 = 32.768us，见 connect_qp）。
  // 输入/输出及副作用：见各用例。
  // 失败/边界：以 UVM_ERROR/FATAL 报告。
  virtual task run_cases();
    check_request_drop();
    check_ack_drop();
    check_partial_timeout_retransmit();
    check_rnr();
    check_rnr_stale_ack_recovery();
    check_ud();
    check_srq_sgb();
    check_urc_sq_abnormal();
    check_urc_rq_abnormal();
    check_urc_aeqe();
    check_psn_wrap();
    check_infinite_psn_retry();
    check_response_filtering();
    check_segment_state();
    check_non_message_segment_rejects();
    check_epoch_gate_reset();
  endtask

  // 功能：把一个测试 RC QP 按指定起始 PSN、RTO 与 PSN retry 连到 dest_qpn/dmac，供回绕和重试
  //   边界用例避免依赖主测试 QP 的当前 PSN。
  // 输入/输出及副作用：依次修改 qp 为 INIT/RTR/RTS；rq_psn/sq_psn 均取 start_psn，RTS 写入
  //   timeout/retry_cnt，远端读写原子权限全部开启。
  // 失败/边界：qp 必须处于 RESET 且属于 drv；任何 modify 失败通过 expect_ok 终止当前用例。
  task connect_configured_qp(rdma_drv_dev drv, rdma_drv_qp qp, bit [23:0] dest_qpn,
                             bit [47:0] dmac, bit [23:0] start_psn,
                             int unsigned timeout, int unsigned retry_cnt);
    rdma_drv_qp_attr attr;
    rdma_status status;

    attr = rdma_drv_qp_attr::type_id::create("configured_init");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_ACCESS;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.access = RDMA_RIGHT_REMOTE_READ | RDMA_RIGHT_REMOTE_WRITE |
                  RDMA_RIGHT_REMOTE_ATOMIC;
    qp.modify(drv, attr, status);
    expect_ok("configured INIT", status);
    attr = rdma_drv_qp_attr::type_id::create("configured_rtr");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_DEST_QPN |
                rdma_drv_qp_attr::M_RQ_PSN | rdma_drv_qp_attr::M_PATH_MTU |
                rdma_drv_qp_attr::M_AV | rdma_drv_qp_attr::M_MIN_RNR;
    attr.state = RDMA_DRV_QPS_RTR;
    attr.dest_qpn = dest_qpn;
    attr.rq_psn = start_psn;
    attr.path_mtu = 1024;
    attr.dmac = dmac;
    attr.min_rnr = 1;
    qp.modify(drv, attr, status);
    expect_ok("configured RTR", status);
    attr = rdma_drv_qp_attr::type_id::create("configured_rts");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN |
                rdma_drv_qp_attr::M_TIMEOUT | rdma_drv_qp_attr::M_RETRY_CNT;
    attr.state = RDMA_DRV_QPS_RTS;
    attr.sq_psn = start_psn;
    attr.timeout = timeout;
    attr.retry_cnt = retry_cnt;
    qp.modify(drv, attr, status);
    expect_ok("configured RTS", status);
  endtask

  // 功能：在同一个设备 QPC/runtime 上制造 INIT→RTR 边沿并写入新的接收 PSN，精确验证
  //   qpc_written 的 RTR epoch 清理，而不走 verbs 层不支持的 RESET 复用路径。
  // 输入/输出及副作用：n/qp 选择设备 QPC，start_psn 写 EPSN_REQ；先发布 INIT 再发布 RTR，并在每个
  //   边沿调用 nic.qpc_written；驱动 qp.cur_state 与发送侧字段保持不变，本辅助只服务直接注包测试。
  // 失败/边界：要求 QPC 仍存在且没有并发 SQ/RX 流量，否则报 UVM_FATAL；该辅助绕过 CMQ，只用于
  //   隔离设备运行态生命周期，不能作为正常驱动状态迁移接口。
  task reenter_device_rtr(rdma_drv_data_node n, rdma_drv_qp qp, bit [23:0] start_psn);
    rdma_dev_object obj;
    int unsigned old_state;

    if (!n.dev.cmq.lookup(RDMA_DEV_QP, qp.qpn, obj))
      `uvm_fatal("RTR_EPOCH", $sformatf("device has no QPC %0d", qp.qpn))
    old_state = rdma_be::field(obj.bytes, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET,
                               RDMA_QPC_QP_ST_LSB, RDMA_QPC_QP_ST_WIDTH);
    rdma_be::set_field(obj.bytes, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET, RDMA_QPC_QP_ST_LSB,
                       RDMA_QPC_QP_ST_WIDTH, 1);
    n.dev.nic.qpc_written(qp.qpn, old_state);
    rdma_be::set_field(obj.bytes, RDMA_QPC_EPSN_REQ_WORD_BYTE_OFFSET, RDMA_QPC_EPSN_REQ_LSB,
                       RDMA_QPC_EPSN_REQ_WIDTH, start_psn);
    rdma_be::set_field(obj.bytes, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET, RDMA_QPC_QP_ST_LSB,
                       RDMA_QPC_QP_ST_WIDTH, 2);
    n.dev.nic.qpc_written(qp.qpn, 1);
  endtask

  // 功能：创建一对使用共享 CQ、但拥有独立 QPN 与指定起始 PSN/重试参数的 RC QP。
  // 输入/输出及副作用：在 A/B 各创建一个 QP，双向调用 connect_configured_qp，qa/qb 输出给用例。
  // 失败/边界：不绑定 SRQ；创建或状态迁移失败通过 expect_ok 报 UVM_FATAL，已创建对象保留到测试结束。
  task make_configured_pair(bit [23:0] start_psn, int unsigned timeout,
                            int unsigned retry_cnt, output rdma_drv_qp qa,
                            output rdma_drv_qp qb);
    rdma_drv_qp_init_attr attr;
    rdma_status status;

    attr = rdma_drv_qp_init_attr::type_id::create("configured_pair_b");
    attr.pd = b.pd;
    attr.send_cq = b.cq;
    attr.recv_cq = b.cq;
    attr.max_send_sge = 4;
    attr.max_recv_sge = 4;
    rdma_drv_qp::create_qp(b.drv, attr, qb, status);
    expect_ok("create configured B QP", status);
    attr = rdma_drv_qp_init_attr::type_id::create("configured_pair_a");
    attr.pd = a.pd;
    attr.send_cq = a.cq;
    attr.recv_cq = a.cq;
    attr.max_send_sge = 4;
    attr.max_recv_sge = 4;
    rdma_drv_qp::create_qp(a.drv, attr, qa, status);
    expect_ok("create configured A QP", status);
    connect_configured_qp(a.drv, qa, qb.qpn, b.mac, start_psn, timeout, retry_cnt);
    connect_configured_qp(b.drv, qb, qa.qpn, a.mac, start_psn, timeout, retry_cnt);
  endtask

  // 功能：向指定节点/QP 投递一个单 SGE RECV，供独立测试 QP 使用而不落到节点默认 QP。
  // 输入/输出及副作用：SGE 指向 n.data_buf 的 offset/len，分配并输出 wr_id，推进 next_wr_id。
  // 失败/边界：offset/len 必须落在 n.mr；post 失败由 expect_ok 报 UVM_FATAL。
  task post_recv_on(rdma_drv_data_node n, rdma_drv_qp qp, int unsigned offset,
                    int unsigned len, output longint unsigned wr_id);
    rdma_drv_recv_wr wr;
    rdma_status status;

    wr = rdma_drv_recv_wr::type_id::create("configured_recv");
    wr.wr_id = next_wr_id++;
    wr.sges.push_back(rdma_drv_sge::make(n.data_buf.iova + offset, len, n.mr.key()));
    rdma_drv_wr::post_recv(n.drv, qp, wr, status);
    expect_ok("post configured RECV", status);
    wr_id = wr.wr_id;
  endtask

  // 功能：在指定节点/QP 投递 SEND WR，等待共享 CQ 上的一条发送完成并校验 wr_id/状态。
  // 输入/输出及副作用：调用 post_send 与 wait_wcs；消费 n.cq 的一个完成，不改变 WR 所有权。
  // 失败/边界：post/poll 失败报 UVM_FATAL，完成方向、wr_id 或状态不符报 UVM_ERROR。
  task send_on_qp_and_wait(string label, rdma_drv_data_node n, rdma_drv_qp qp,
                           rdma_drv_send_wr wr,
                           rdma_drv_wc_status_e st = RDMA_DRV_WC_SUCCESS);
    rdma_drv_wc wcs[$];
    rdma_status status;

    rdma_drv_wr::post_send(n.drv, qp, wr, status);
    expect_ok({"post ", label}, status);
    wait_wcs(n, 1, wcs);
    expect_wc(label, wcs[0], wr.wr_id, 1'b0, st);
  endtask

  // 功能：向节点 NIC 注入一条响应语义包，用于构造窗口外 ACK/NAK 或 opcode 不相关的陈旧响应。
  // 输入/输出及副作用：创建 ONLY 包，填写 destination_qpn/psn/AETH 后序列化并调用 n.dev.nic.receive。
  // 失败/边界：调用方负责保证 opcode 携带 AETH；包绕过链路故障计数，仅用于确定性协议边界测试。
  task inject_response(rdma_drv_data_node n, bit [23:0] destination_qpn,
                       rdma_network_opcode_e opcode, bit [23:0] psn,
                       bit [7:0] syndrome);
    rdma_packet pkt;

    pkt = rdma_packet::type_id::create("injected_response");
    pkt.transport = RDMA_TRANSPORT_RC;
    pkt.opcode = opcode;
    pkt.segment = RDMA_SEG_ONLY;
    pkt.destination_qpn = destination_qpn;
    pkt.psn = psn;
    pkt.aeth_syndrome = syndrome;
    pkt.pack_headers();
    n.dev.nic.receive(pkt);
  endtask

  // 功能：经测试链路向节点注入一条指定 transport/opcode/segment 的请求，构造 PSN 缺口、RNR 门控或
  //   transport 伪装等正常驱动不会生成的线上边界。
  // 输入/输出及副作用：n 选择目的节点，source_qpn/destination_qpn/psn 填 BTH 语义字段；报文固定请求
  //   ACK 并 pack_headers 后由 link.send 投递，因此计入 sent_to/dropped 观测。
  // 失败/边界：未填充 opcode 所需扩展头，故只适合无需有效 RETH/原子字段即可到达被测准入分支的请求；
  //   调用方须保证目标 QP 存在，异步 RX 结果应在调用后留出处理时间。
  task inject_request(rdma_drv_data_node n, rdma_transport_e transport,
                      rdma_network_opcode_e opcode, rdma_packet_segment_e segment,
                      bit [23:0] source_qpn, bit [23:0] destination_qpn,
                      bit [23:0] psn);
    rdma_packet pkt;

    pkt = rdma_packet::type_id::create("injected_request");
    pkt.transport = transport;
    pkt.opcode = opcode;
    pkt.segment = segment;
    pkt.source_qpn = source_qpn;
    pkt.destination_qpn = destination_qpn;
    pkt.psn = psn;
    pkt.ack_req = 1'b1;
    pkt.pack_headers();
    link.send(pkt, n.mac);
  endtask

  // 功能：分别发送 5 段 RC SEND 和 WRITE；链路放行前 3 段后丢掉末 2 段，要求第 3 段的
  //   AckReq 得到累计 ACK，RTO 后只重发末 2 段，两种 opcode 均恢复原始数据。
  // 输入/输出及副作用：向 B 投递一个 RQE，两次配置 link.drop_after[b.mac]=3/drops[b.mac]=2；
  //   消费 A/B 完成并校验链路计数、RTO 时间和 B 内存。
  // 失败/边界：缺少中间 AckReq/响应 ACK 或超时回到首 PSN 都会使向 B 发包数从 7 变为 10；
  //   未经 RTO 就完成、故障未全命中、响应数非 2 或数据不符均报 UVM_ERROR。
  task check_partial_timeout_retransmit();
    rdma_bytes_t data;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    longint unsigned rwr;
    int unsigned to_a;
    int unsigned to_b;
    int unsigned dropped;
    time started;
    time elapsed;

    data = fill(a, 'h800, PARTIAL_RETRY_BYTES, 8'h2d);
    post_recv(b, '{'h2000}, '{PARTIAL_RETRY_BYTES}, rwr);
    to_a = link.sent_to[a.mac];
    to_b = link.sent_to[b.mac];
    dropped = link.dropped;
    link.drop_after[b.mac] = 3;
    link.drops[b.mac] = 2;
    started = $time;
    send_and_wait("SEND partial timeout", send_wr(a, RDMA_DRV_WR_SEND, '{'h800},
                                                   '{PARTIAL_RETRY_BYTES}));
    elapsed = $time - started;
    expect_recv("SEND partial timeout rq", rwr, wc);
    expect_mem("SEND partial timeout data", b, 'h2000, data);
    if (elapsed < 32768ns || elapsed >= 34us)
      `uvm_error("SEND partial timeout", $sformatf("completed after %0t, expected one RTO",
                                                    elapsed))
    if (link.sent_to[b.mac] - to_b != 7 || link.sent_to[a.mac] - to_a != 2 ||
        link.dropped - dropped != 2)
      `uvm_error("SEND partial timeout",
                 $sformatf("requests %0d responses %0d drops %0d, expected 7/2/2",
                           link.sent_to[b.mac] - to_b, link.sent_to[a.mac] - to_a,
                           link.dropped - dropped))
    expect_b_idle("SEND partial timeout");

    data = fill(a, 'h1800, PARTIAL_RETRY_BYTES, 8'h3d);
    wr = send_wr(a, RDMA_DRV_WR_WRITE, '{'h1800}, '{PARTIAL_RETRY_BYTES});
    wr.remote_va = b.data_buf.iova + 'h2800;
    wr.rkey = b.mr.key();
    to_a = link.sent_to[a.mac];
    to_b = link.sent_to[b.mac];
    dropped = link.dropped;
    link.drop_after[b.mac] = 3;
    link.drops[b.mac] = 2;
    started = $time;
    send_and_wait("WRITE partial timeout", wr);
    elapsed = $time - started;
    expect_mem("WRITE partial timeout data", b, 'h2800, data);
    if (elapsed < 32768ns || elapsed >= 34us)
      `uvm_error("WRITE partial timeout", $sformatf("completed after %0t, expected one RTO",
                                                     elapsed))
    if (link.sent_to[b.mac] - to_b != 7 || link.sent_to[a.mac] - to_a != 2 ||
        link.dropped - dropped != 2)
      `uvm_error("WRITE partial timeout",
                 $sformatf("requests %0d responses %0d drops %0d, expected 7/2/2",
                           link.sent_to[b.mac] - to_b, link.sent_to[a.mac] - to_a,
                           link.dropped - dropped))
  endtask

  // 功能：以 0xffffff 启动两包 RC READ，验证第二个响应 PSN 回绕到 0 后仍按同一请求的偏移 1 接收。
  // 输入/输出及副作用：创建独立 QP 对，从 B 读取 2000B 到 A，并逐字节比较本地目标缓冲。
  // 失败/边界：若比较使用未截断的 int 加法，回绕响应会被反复判为跳号并以发送错误完成。
  task check_psn_wrap();
    rdma_bytes_t data;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wr;

    make_configured_pair(24'hff_ffff, 3, 6, qa, qb);
    data = fill(b, 'h400, 2000, 8'h6d);
    wr = send_wr(a, RDMA_DRV_WR_READ, '{'h2000}, '{2000});
    wr.remote_va = b.data_buf.iova + 'h400;
    wr.rkey = b.mr.key();
    send_on_qp_and_wait("READ PSN wrap", a, qa, wr);
    expect_mem("READ PSN wrap data", a, 'h2000, data);
  endtask

  // 功能：把 retry_cnt 配成 7 并连续丢 8 个 ACK，验证第 9 次请求仍会发送并成功，而不是按有限 7 次耗尽。
  // 输入/输出及副作用：创建 RTO=8.192us 的独立 QP 对，投递一个 SEND/RQE，检查包数、丢包数、耗时与数据。
  // 失败/边界：完成早于 8 个 RTO、请求/响应不是 9 个、重复 SEND 消费第二个 RQE 或数据不符均报错。
  task check_infinite_psn_retry();
    rdma_bytes_t data;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_wc wc;
    longint unsigned rwr;
    int unsigned to_a;
    int unsigned to_b;
    int unsigned dropped;
    time started;
    time elapsed;

    make_configured_pair(24'h000100, 1, 7, qa, qb);
    data = fill(a, 'h1000, 32, 8'h7d);
    post_recv_on(b, qb, 'h1800, 128, rwr);
    to_a = link.sent_to[a.mac];
    to_b = link.sent_to[b.mac];
    dropped = link.dropped;
    link.drop_after[a.mac] = 0;
    link.drops[a.mac] = 8;
    started = $time;
    send_on_qp_and_wait("infinite PSN retry", a, qa,
                        send_wr(a, RDMA_DRV_WR_SEND, '{'h1000}, '{32}));
    elapsed = $time - started;
    expect_recv("infinite PSN retry rq", rwr, wc);
    expect_mem("infinite PSN retry data", b, 'h1800, data);
    if (elapsed < 65536ns || elapsed >= 70us)
      `uvm_error("infinite PSN retry",
                 $sformatf("completed after %0t, expected eight 8.192us RTOs", elapsed))
    if (link.sent_to[b.mac] - to_b != 9 || link.sent_to[a.mac] - to_a != 9 ||
        link.dropped - dropped != 8)
      `uvm_error("infinite PSN retry",
                 $sformatf("requests %0d responses %0d drops %0d, expected 9/9/8",
                           link.sent_to[b.mac] - to_b, link.sent_to[a.mac] - to_a,
                           link.dropped - dropped))
    expect_b_idle("infinite PSN retry");
  endtask

  // 功能：丢失真实响应后注入窗口外致命 NAK、同 PSN 的错误 opcode、窗口外普通 ACK，以及落在已
  //   累计确认/接收前缀内的陈旧致命/sequence NAK，验证它们不结束或回退 SEND/READ，也不刷新 RTO。
  // 输入/输出及副作用：使用四对独立 QP；每项由链路丢弃目标响应，再定时注入伪响应并检查成功完成、
  //   一个 RTO 的耗时、RQE（SEND）与目的数据。
  // 失败/边界：窗口外/错误 opcode 响应若被采纳会提前错误完成；无进展响应若刷新 RTO 会延迟重传；
  //   中间累计 ACK 或首个 READ 响应后的旧 fatal/sequence NAK 必须按当前进度过滤，不能回退 resume。
  task check_response_filtering();
    rdma_bytes_t data;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    longint unsigned rwr;
    time started;
    time elapsed;

    make_configured_pair(24'h000200, 3, 6, qa, qb);
    data = fill(a, 'h1200, 32, 8'h8d);
    post_recv_on(b, qb, 'h1a00, 128, rwr);
    link.drop_after[a.mac] = 0;
    link.drops[a.mac] = 1;
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h1200}, '{32});
    started = $time;
    fork
      send_on_qp_and_wait("filtered NAK/opcode", a, qa, wr);
      begin
        #1us;
        inject_response(a, qa.qpn, RDMA_NET_NAK, 24'h000208,
                        RDMA_AETH_NAK_REMOTE_ACCESS);
        #1us;
        inject_response(a, qa.qpn, RDMA_NET_RDMA_READ_RESP, 24'h000200,
                        RDMA_AETH_NAK_REMOTE_ACCESS);
      end
    join
    elapsed = $time - started;
    expect_recv("filtered NAK/opcode rq", rwr, wc);
    expect_mem("filtered NAK/opcode data", b, 'h1a00, data);
    if (elapsed < 32768ns || elapsed >= 34us)
      `uvm_error("filtered NAK/opcode",
                 $sformatf("completed after %0t, expected one unaffected RTO", elapsed))

    make_configured_pair(24'h000300, 3, 6, qa, qb);
    data = fill(a, 'h1400, 32, 8'h9d);
    post_recv_on(b, qb, 'h1c00, 128, rwr);
    link.drop_after[a.mac] = 0;
    link.drops[a.mac] = 1;
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h1400}, '{32});
    started = $time;
    fork
      send_on_qp_and_wait("stale ACK deadline", a, qa, wr);
      begin
        #20us;
        inject_response(a, qa.qpn, RDMA_NET_ACK, 24'h000308, RDMA_AETH_ACK);
      end
    join
    elapsed = $time - started;
    expect_recv("stale ACK deadline rq", rwr, wc);
    expect_mem("stale ACK deadline data", b, 'h1c00, data);
    if (elapsed < 32768ns || elapsed >= 40us)
      `uvm_error("stale ACK deadline",
                 $sformatf("completed after %0t, stale ACK changed the RTO", elapsed))

    make_configured_pair(24'h000350, 3, 6, qa, qb);
    data = fill(a, 'h2000, PARTIAL_RETRY_BYTES, 8'ha3);
    post_recv_on(b, qb, 0, PARTIAL_RETRY_BYTES, rwr);
    link.drop_after[a.mac] = 1;
    link.drops[a.mac] = 1;
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h2000}, '{PARTIAL_RETRY_BYTES});
    started = $time;
    fork
      send_on_qp_and_wait("stale NAK after cumulative ACK", a, qa, wr);
      begin
        #1us;
        inject_response(a, qa.qpn, RDMA_NET_NAK, 24'h000351,
                        RDMA_AETH_NAK_REMOTE_ACCESS);
        #1us;
        inject_response(a, qa.qpn, RDMA_NET_NAK, 24'h000350,
                        RDMA_AETH_NAK_PSN_SEQ);
      end
    join
    elapsed = $time - started;
    expect_recv("stale NAK after cumulative ACK rq", rwr, wc);
    expect_mem("stale NAK after cumulative ACK data", b, 0, data);
    if (elapsed < 32768ns || elapsed >= 34us)
      `uvm_error("stale NAK after cumulative ACK",
                 $sformatf("completed after %0t, expected one unaffected RTO", elapsed))

    make_configured_pair(24'h000360, 3, 6, qa, qb);
    data = fill(b, 'h1800, 2000, 8'hb3);
    link.drop_after[a.mac] = 1;
    link.drops[a.mac] = 1;
    wr = send_wr(a, RDMA_DRV_WR_READ, '{'h3000}, '{2000});
    wr.remote_va = b.data_buf.iova + 'h1800;
    wr.rkey = b.mr.key();
    started = $time;
    fork
      send_on_qp_and_wait("stale NAK after READ progress", a, qa, wr);
      begin
        #1us;
        inject_response(a, qa.qpn, RDMA_NET_NAK, 24'h000360,
                        RDMA_AETH_NAK_REMOTE_ACCESS);
      end
    join
    elapsed = $time - started;
    expect_mem("stale NAK after READ progress data", a, 'h3000, data);
    if (elapsed < 32768ns || elapsed >= 34us)
      `uvm_error("stale NAK after READ progress",
                 $sformatf("completed after %0t, expected one unaffected RTO", elapsed))
  endtask

  // 功能：先完成一个 SEND 再注入下一 PSN 的孤立 LAST，并在另一 QP 上把 WRITE LAST 插入未完成 SEND，
  //   验证 LAST 已清理旧 RQE，且跨 opcode 分段由显式状态机拒绝。
  // 输入/输出及副作用：创建两对独立 QP，直接经 link 注入请求；检查 segment_rejects、目的尾部和 B CQ；
  //   跨消息族的致命 NAK 会把 RC QP 转 ERR，并为已消费但未完成的 RQE 生成接收方向 FLUSH_ERR。
  // 失败/边界：孤立 LAST 若复用旧 rx_sges 会改写尾部并产生重复 CQE；错族 LAST 若被接受则拒绝计数不增，
  //   若未按 RC fatal 错误收口则 flush 完成的数量、wr_id、方向或状态不符。
  task check_segment_state();
    rdma_bytes_t data;
    rdma_bytes_t zeros;
    rdma_packet pkt;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_wc wc;
    rdma_drv_wc wcs[$];
    longint unsigned rwr;
    int unsigned rejected;
    rdma_status status;

    make_configured_pair(24'h000400, 3, 6, qa, qb);
    zeros = rdma_be::zeros(128);
    expect_ok("clear segmented destination", b.drv.hw.write(b.data_buf, 'h3000, zeros));
    data = fill(a, 'h1600, 16, 8'had);
    post_recv_on(b, qb, 'h3000, 128, rwr);
    send_on_qp_and_wait("segment state seed", a, qa,
                        send_wr(a, RDMA_DRV_WR_SEND, '{'h1600}, '{16}));
    expect_recv("segment state seed rq", rwr, wc);
    rejected = b.dev.nic.segment_rejects;
    pkt = rdma_packet::type_id::create("orphan_send_last");
    pkt.transport = RDMA_TRANSPORT_RC;
    pkt.opcode = RDMA_NET_SEND;
    pkt.segment = RDMA_SEG_LAST;
    pkt.source_qpn = qa.qpn;
    pkt.destination_qpn = qb.qpn;
    pkt.psn = 24'h000401;
    pkt.ack_req = 1'b1;
    repeat (4)
      pkt.payload.push_back(8'hee);
    pkt.pack_headers();
    link.send(pkt, b.mac);
    #1us;
    if (b.dev.nic.segment_rejects != rejected + 1)
      `uvm_error("orphan SEND LAST", "segment reject counter did not advance")
    expect_mem("orphan SEND LAST tail", b, 'h3010, rdma_be::zeros(4));
    rdma_drv_wr::poll_cq(b.drv, b.cq, 4, wcs, status);
    expect_ok("poll orphan SEND LAST", status);
    if (wcs.size() != 0)
      `uvm_error("orphan SEND LAST", $sformatf("%0d duplicate receive completions", wcs.size()))

    make_configured_pair(24'h000500, 3, 6, qa, qb);
    post_recv_on(b, qb, 'h3200, 128, rwr);
    rejected = b.dev.nic.segment_rejects;
    pkt = rdma_packet::type_id::create("send_first_before_write_last");
    pkt.transport = RDMA_TRANSPORT_RC;
    pkt.opcode = RDMA_NET_SEND;
    pkt.segment = RDMA_SEG_FIRST;
    pkt.source_qpn = qa.qpn;
    pkt.destination_qpn = qb.qpn;
    pkt.psn = 24'h000500;
    repeat (4)
      pkt.payload.push_back(8'h5a);
    pkt.pack_headers();
    link.send(pkt, b.mac);
    #100ns;
    pkt = rdma_packet::type_id::create("write_last_after_send_first");
    pkt.transport = RDMA_TRANSPORT_RC;
    pkt.opcode = RDMA_NET_RDMA_WRITE;
    pkt.segment = RDMA_SEG_LAST;
    pkt.source_qpn = qa.qpn;
    pkt.destination_qpn = qb.qpn;
    pkt.psn = 24'h000501;
    pkt.ack_req = 1'b1;
    pkt.pack_headers();
    link.send(pkt, b.mac);
    #1us;
    if (b.dev.nic.segment_rejects != rejected + 1)
      `uvm_error("cross-opcode segment", "segment reject counter did not advance")
    wcs.delete();
    rdma_drv_wr::poll_cq(b.drv, b.cq, 4, wcs, status);
    expect_ok("poll cross-opcode segment", status);
    if (wcs.size() != 1)
      `uvm_error("cross-opcode segment", $sformatf("%0d completions, expected one RQ flush",
                                                    wcs.size()))
    else
      expect_wc("cross-opcode segment flush", wcs[0], rwr, 1'b1, RDMA_DRV_WC_FLUSH_ERR);
  endtask

  // 功能：先向 RC QP 注入伪装成 URC 的 READ MIDDLE，验证目标 QPC service type 在 PSN/分段状态机
  //   之前拒绝它；再分别注入真实 RC READ MIDDLE 与 ATOMIC MIDDLE，验证非 SEND/WRITE 只接受 ONLY。
  // 输入/输出及副作用：创建三对独立 QP，经 link 注入报文，检查 transport_rejects、segment_rejects、
  //   state_drops 与响应计数；不投递 RQE，也不产生正常 CQE。
  // 失败/边界：仅真正 URC QP 的 READ 可用 FIRST/MIDDLE/LAST；伪装包不得推进 expected_psn 或使 RC
  //   QP 进入 ERR，真实 RC 非 ONLY 请求则须回 fatal INVALID_REQUEST 并使后续请求按状态丢弃。
  task check_non_message_segment_rejects();
    rdma_packet pkt;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    int unsigned rejected;
    int unsigned dropped;
    int unsigned transport_rejected;
    int unsigned to_a;

    make_configured_pair(24'h0005f0, 3, 6, qa, qb);
    rejected = b.dev.nic.segment_rejects;
    transport_rejected = b.dev.nic.transport_rejects;
    to_a = link.sent_to[a.mac];
    inject_request(b, RDMA_TRANSPORT_URC, RDMA_NET_RDMA_READ_REQUEST, RDMA_SEG_MIDDLE,
                   qa.qpn, qb.qpn, 24'h0005f0);
    #100ns;
    if (b.dev.nic.transport_rejects != transport_rejected + 1 ||
        b.dev.nic.segment_rejects != rejected || link.sent_to[a.mac] != to_a)
      `uvm_error("spoofed URC READ MIDDLE",
                 "transport mismatch was not rejected before RC PSN/segment processing")
    // 伪装包不得推进 expected_psn 或转 ERR；下一 PSN 应触发指向原 expected_psn 的 sequence NAK。
    inject_request(b, RDMA_TRANSPORT_RC, RDMA_NET_SEND, RDMA_SEG_ONLY,
                   qa.qpn, qb.qpn, 24'h0005f1);
    #100ns;
    if (link.sent_to[a.mac] != to_a + 1)
      `uvm_error("spoofed URC READ MIDDLE", "RC QP state or expected PSN changed")

    make_configured_pair(24'h000600, 3, 6, qa, qb);
    rejected = b.dev.nic.segment_rejects;
    dropped = b.dev.nic.state_drops;
    pkt = rdma_packet::type_id::create("rc_read_middle");
    pkt.transport = RDMA_TRANSPORT_RC;
    pkt.opcode = RDMA_NET_RDMA_READ_REQUEST;
    pkt.segment = RDMA_SEG_MIDDLE;
    pkt.source_qpn = qa.qpn;
    pkt.destination_qpn = qb.qpn;
    pkt.psn = 24'h000600;
    pkt.pack_headers();
    link.send(pkt, b.mac);
    #100ns;
    if (b.dev.nic.segment_rejects != rejected + 1)
      `uvm_error("RC READ MIDDLE", "segment reject counter did not advance")
    pkt = rdma_packet::type_id::create("request_after_rc_read_middle");
    pkt.transport = RDMA_TRANSPORT_RC;
    pkt.opcode = RDMA_NET_SEND;
    pkt.segment = RDMA_SEG_ONLY;
    pkt.source_qpn = qa.qpn;
    pkt.destination_qpn = qb.qpn;
    pkt.psn = 24'h000600;
    pkt.pack_headers();
    link.send(pkt, b.mac);
    #100ns;
    if (b.dev.nic.state_drops != dropped + 1)
      `uvm_error("RC READ MIDDLE", "response QP did not enter ERR after fatal NAK")

    make_configured_pair(24'h000700, 3, 6, qa, qb);
    rejected = b.dev.nic.segment_rejects;
    dropped = b.dev.nic.state_drops;
    pkt = rdma_packet::type_id::create("rc_atomic_middle");
    pkt.transport = RDMA_TRANSPORT_RC;
    pkt.opcode = RDMA_NET_ATOMIC_FETCH_ADD;
    pkt.segment = RDMA_SEG_MIDDLE;
    pkt.source_qpn = qa.qpn;
    pkt.destination_qpn = qb.qpn;
    pkt.psn = 24'h000700;
    pkt.pack_headers();
    link.send(pkt, b.mac);
    #100ns;
    if (b.dev.nic.segment_rejects != rejected + 1)
      `uvm_error("RC ATOMIC MIDDLE", "segment reject counter did not advance")
    pkt = rdma_packet::type_id::create("request_after_rc_atomic_middle");
    pkt.transport = RDMA_TRANSPORT_RC;
    pkt.opcode = RDMA_NET_SEND;
    pkt.segment = RDMA_SEG_ONLY;
    pkt.source_qpn = qa.qpn;
    pkt.destination_qpn = qb.qpn;
    pkt.psn = 24'h000700;
    pkt.pack_headers();
    link.send(pkt, b.mac);
    #100ns;
    if (b.dev.nic.state_drops != dropped + 1)
      `uvm_error("RC ATOMIC MIDDLE", "response QP did not enter ERR after fatal NAK")
  endtask

  // 功能：先后制造 seq_nak_sent 与 rnr_drop，再让同一响应 QP 两次重入 RTR，验证新 epoch 的首个
  //   缺口都能重新发送 sequence NAK，不受旧门控状态抑制。
  // 输入/输出及副作用：创建一对 RC QP；第一次未来 PSN 置位 seq_nak_sent，设备重入 RTR 到 0x1100
  //   后再次制造缺口并以正确首包触发 RNR，随后重入 RTR 到 0x1200；检查发往 A 的响应增量。
  // 失败/边界：B 不投递 RQE，正确首包必须产生 RNR；若 RTR 未清任一 gate，紧随重建的未来 PSN
  //   会被静默丢弃且响应增量为 0；测试不依赖受保护运行态字段，也不调用驱动 RESET 复用路径。
  task check_epoch_gate_reset();
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    int unsigned to_a;

    make_configured_pair(24'h001000, 3, 6, qa, qb);
    to_a = link.sent_to[a.mac];
    inject_request(b, RDMA_TRANSPORT_RC, RDMA_NET_SEND, RDMA_SEG_ONLY,
                   qa.qpn, qb.qpn, 24'h001001);
    #100ns;
    if (link.sent_to[a.mac] != to_a + 1)
      `uvm_error("sequence gate seed", "initial PSN gap did not emit sequence NAK")

    reenter_device_rtr(b, qb, 24'h001100);
    to_a = link.sent_to[a.mac];
    inject_request(b, RDMA_TRANSPORT_RC, RDMA_NET_SEND, RDMA_SEG_ONLY,
                   qa.qpn, qb.qpn, 24'h001101);
    #100ns;
    if (link.sent_to[a.mac] != to_a + 1)
      `uvm_error("sequence gate reset", "old seq_nak_sent suppressed the new epoch NAK")

    // 正确 PSN 清除刚置位的 sequence gate，随后因没有 RQE 置位 rnr_drop 并回 RNR。
    to_a = link.sent_to[a.mac];
    inject_request(b, RDMA_TRANSPORT_RC, RDMA_NET_SEND, RDMA_SEG_ONLY,
                   qa.qpn, qb.qpn, 24'h001100);
    #100ns;
    if (link.sent_to[a.mac] != to_a + 1)
      `uvm_error("RNR gate seed", "expected-PSN SEND without RQE did not emit RNR")

    reenter_device_rtr(b, qb, 24'h001200);
    to_a = link.sent_to[a.mac];
    inject_request(b, RDMA_TRANSPORT_RC, RDMA_NET_SEND, RDMA_SEG_ONLY,
                   qa.qpn, qb.qpn, 24'h001201);
    #100ns;
    if (link.sent_to[a.mac] != to_a + 1)
      `uvm_error("RNR gate reset", "old rnr_drop suppressed the new epoch NAK")
  endtask

  // 功能：断言 B 在 20us 内没有新的完成。
  // 输入/输出及副作用：轮询 B 的 CQ。
  // 失败/边界：有完成报告 UVM_ERROR。
  task expect_b_idle(string label);
    rdma_drv_wc wcs[$];
    rdma_status status;

    #20us;
    rdma_drv_wr::poll_cq(b.drv, b.cq, 4, wcs, status);
    expect_ok("poll idle", status);
    if (wcs.size() != 0)
      `uvm_error(label, $sformatf("%0d unexpected completions on B", wcs.size()))
  endtask

  // 功能：3 包 SEND 的第 2 包被丢：B 对第 3 包回 PSN 序列 NAK（期望 PSN = 第 2 包），A 只重发第 2、
  //   3 包（发往 B 共 5 包），两端各一个成功完成，数据一致，B 无多余完成。
  // 输入/输出及副作用：丢 1 包。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_request_drop();
    rdma_bytes_t data;
    rdma_drv_wc wc;
    longint unsigned rwr;
    int unsigned to_b;

    data = fill(a, 0, 2500, 8'h17);
    post_recv(b, '{4096}, '{4096}, rwr);
    to_b = link.sent_to[b.mac];
    link.drop_after[b.mac] = 1;
    link.drops[b.mac] = 1;
    send_and_wait("request drop", send_wr(a, RDMA_DRV_WR_SEND, '{0}, '{2500}));
    expect_recv("request drop rq", rwr, wc);
    expect_mem("request drop data", b, 4096, data);
    if (link.dropped != 1 || wc.byte_len != 2500 || link.sent_to[b.mac] - to_b != 5)
      `uvm_error("request drop", $sformatf("dropped %0d, byte_len %0d, packets to B %0d",
                                           link.dropped, wc.byte_len,
                                           link.sent_to[b.mac] - to_b))
    expect_b_idle("request drop");
  endtask

  // 功能：B→A 的响应被丢，A 等满 RTO（32.768us）后重发，B 按重复请求处理：SEND 只消费一个 RQE（第二个 RQE 留给
  //   下一条 SEND）；2 段 READ 的第 2 段响应被丢，A 只对第 2 段重新请求（发往 B 共 2 个请求，回 A
  //   共 3 个响应）；FAA 回缓存的原值且目标只加一次。
  // 输入/输出及副作用：每项丢 1 包。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_ack_drop();
    rdma_bytes_t data;
    rdma_bytes_t init;
    rdma_bytes_t sum;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    longint unsigned rwr[2];
    int unsigned to_a;
    int unsigned to_b;
    time started;

    data = fill(a, 'h100, 64, 8'h27);
    post_recv(b, '{'h1000}, '{'h100}, rwr[0]);
    post_recv(b, '{'h1100}, '{'h100}, rwr[1]);
    link.drops[a.mac] = 1;
    started = $time;
    send_and_wait("ACK drop", send_wr(a, RDMA_DRV_WR_SEND, '{'h100}, '{64}));
    if ($time - started < 32768ns || $time - started >= 34us)
      `uvm_error("ACK drop", $sformatf("completed after %0t, expected one 32.768us RTO",
                                       $time - started))
    expect_recv("ACK drop rq", rwr[0], wc);
    expect_mem("ACK drop data", b, 'h1000, data);
    expect_b_idle("ACK drop");
    data = fill(a, 'h200, 32, 8'h37);
    send_and_wait("after ACK drop", send_wr(a, RDMA_DRV_WR_SEND, '{'h200}, '{32}));
    expect_recv("after ACK drop rq", rwr[1], wc);
    expect_mem("after ACK drop data", b, 'h1100, data);
    data = fill(b, 'h2000, 2000, 8'h47);
    to_a = link.sent_to[a.mac];
    to_b = link.sent_to[b.mac];
    link.drop_after[a.mac] = 1;
    link.drops[a.mac] = 1;
    wr = send_wr(a, RDMA_DRV_WR_READ, '{'h2800}, '{2000});
    wr.remote_va = b.data_buf.iova + 'h2000;
    wr.rkey = b.mr.key();
    send_and_wait("READ response drop", wr);
    expect_mem("READ response drop data", a, 'h2800, data);
    if (link.sent_to[a.mac] - to_a != 3 || link.sent_to[b.mac] - to_b != 2)
      `uvm_error("READ response drop", $sformatf("responses to A %0d, requests to B %0d",
                                                 link.sent_to[a.mac] - to_a,
                                                 link.sent_to[b.mac] - to_b))
    init = rdma_be::zeros(8);
    init[0] = 8'h40;
    expect_ok("seed FAA", b.drv.hw.write(b.data_buf, 'h3800, init));
    link.drops[a.mac] = 1;
    wr = send_wr(a, RDMA_DRV_WR_FAA, '{'h3900}, '{8});
    wr.remote_va = b.data_buf.iova + 'h3800;
    wr.rkey = b.mr.key();
    wr.compare_add = 3;
    send_and_wait("ATOMIC ACK drop", wr);
    expect_mem("ATOMIC ACK drop orig", a, 'h3900, init);
    sum = rdma_be::zeros(8);
    sum[0] = 8'h43;
    expect_mem("ATOMIC ACK drop target", b, 'h3800, sum);
    if (link.dropped != 4)
      `uvm_error("ACK drop", $sformatf("dropped %0d, expected 4", link.dropped))
  endtask

  // 功能：B 无 RQE 时 SEND 得到 RNR NAK，2us 后 B 投 RECV，A 的 RNR 重试成功；另一对 QP 上 B 始终
  //   不投 RECV，RNR 重试（RNR_RETRY_TH=6）耗尽得到 vendor 0xB7，耗时为 6 次 RNR 定时器（编码 1 =
  //   10us，由 B 的 QPC LOCAL_RNR_CODE 经 NAK 带给 A）。
  // 输入/输出及副作用：创建一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_rnr();
    rdma_bytes_t data;
    rdma_drv_wc wc;
    rdma_drv_wc wcs[$];
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wr;
    longint unsigned rwr;
    time started;
    time elapsed;
    rdma_status status;

    data = fill(a, 'h300, 48, 8'h57);
    fork
      begin
        #2us;
        post_recv(b, '{'h1200}, '{'h100}, rwr);
      end
    join_none
    send_and_wait("RNR retry", send_wr(a, RDMA_DRV_WR_SEND, '{'h300}, '{48}));
    expect_recv("RNR retry rq", rwr, wc);
    expect_mem("RNR retry data", b, 'h1200, data);
    make_pair(null, qa, qb);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h300}, '{48});
    started = $time;
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post RNR exhausted", status);
    wait_wcs(a, 1, wcs);
    elapsed = $time - started;
    if (elapsed < 60us || elapsed >= 65us)
      `uvm_error("RNR exhausted", $sformatf("took %0t, expected 6 x 10us", elapsed))
    expect_wc("RNR exhausted", wcs[0], wr.wr_id, 1'b0, RDMA_DRV_WC_GENERAL_ERR);
    if (wcs[0].vendor_err != RDMA_ECODE_EC_RPE_RSP_NAK_RNR_ERR_OVERTIME)
      `uvm_error("RNR exhausted", $sformatf("vendor %02h", wcs[0].vendor_err))
  endtask

  // 功能：5 段 WRITE_IMM 先取得第 3 段累计 ACK、末段因无 RQE 收到 RNR；RNR 等待后整轮重传被
  //   丢弃，再在该轮 mailbox 清空之后注入旧中间 ACK 与较低 PSN 的 sequence NAK，验证重传点能回到
  //   首段并由下一轮成功完成。
  // 输入/输出及副作用：创建起始 PSN=0x800 的独立 QP 对；2us 时向 B 投递 RQE，第二轮 5 个请求全丢，
  //   11us/12us 向 A 依次注入旧 ACK 与 sequence NAK；校验 A/B 完成、立即数、数据、耗时及链路计数。
  // 失败/边界：若 RNR 后仍采纳无法证明代次的中间 ACK，且较低 sequence NAK 被 resume 前缀过滤，
  //   请求会从第 4 段错误重试并在 20us 窗口内无法成功；丢包数或响应数偏离也报告 UVM_ERROR。
  task check_rnr_stale_ack_recovery();
    localparam bit [23:0] START_PSN = 24'h000800;
    rdma_bytes_t data;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wr;
    rdma_drv_wc wc;
    longint unsigned rwr;
    int unsigned to_a;
    int unsigned to_b;
    int unsigned dropped;
    time started;
    time elapsed;

    make_configured_pair(START_PSN, 1, 6, qa, qb);
    data = fill(a, 'h800, PARTIAL_RETRY_BYTES, 8'hc3);
    wr = send_wr(a, RDMA_DRV_WR_WRITE_IMM, '{'h800}, '{PARTIAL_RETRY_BYTES});
    wr.remote_va = b.data_buf.iova + 'h2000;
    wr.rkey = b.mr.key();
    wr.imm = 32'h51a1_e0c1;
    to_a = link.sent_to[a.mac];
    to_b = link.sent_to[b.mac];
    dropped = link.dropped;
    // 首轮 5 包均放行并在末包得到 RNR；RNR 后的第二轮 5 包全部丢弃。
    link.drop_after[b.mac] = 5;
    link.drops[b.mac] = 5;
    started = $time;
    fork
      send_on_qp_and_wait("RNR stale ACK recovery", a, qa, wr);
      begin
        #2us;
        post_recv_on(b, qb, 'h3f00, 16, rwr);
        // RNR timer=10us；这些响应在第二轮开头清 mailbox 之后到达，顺序固定为旧 ACK 再缺口 NAK。
        #9us;
        inject_response(a, qa.qpn, RDMA_NET_ACK, START_PSN + 2, RDMA_AETH_ACK);
        #1us;
        inject_response(a, qa.qpn, RDMA_NET_NAK, START_PSN, RDMA_AETH_NAK_PSN_SEQ);
      end
    join
    elapsed = $time - started;
    expect_recv("RNR stale ACK recovery rq", rwr, wc);
    expect_mem("RNR stale ACK recovery data", b, 'h2000, data);
    if (wc.imm != 32'h51a1_e0c1)
      `uvm_error("RNR stale ACK recovery", $sformatf("immediate %08h", wc.imm))
    if (elapsed < 12us || elapsed >= 20us)
      `uvm_error("RNR stale ACK recovery",
                 $sformatf("completed after %0t, expected sequence recovery before RTO", elapsed))
    if (link.sent_to[b.mac] - to_b != 15 || link.sent_to[a.mac] - to_a != 4 ||
        link.dropped - dropped != 5)
      `uvm_error("RNR stale ACK recovery",
                 $sformatf("requests %0d responses %0d drops %0d, expected 15/4/5",
                           link.sent_to[b.mac] - to_b, link.sent_to[a.mac] - to_a,
                           link.dropped - dropped))
  endtask

  // 功能：建一个 UD QP（max SGE 4，Q_Key = qkey）并推到 RTS。
  // 输入/输出及副作用：qp 输出。
  // 失败/边界：失败报告 UVM_FATAL。
  task make_ud(rdma_drv_data_node n, bit [31:0] qkey, output rdma_drv_qp qp);
    rdma_drv_qp_init_attr init;
    rdma_drv_qp_attr attr;
    rdma_status status;

    init = rdma_drv_qp_init_attr::type_id::create("ud_attr");
    init.qp_type = RDMA_DRV_QPT_UD;
    init.pd = n.pd;
    init.send_cq = n.cq;
    init.recv_cq = n.cq;
    init.max_send_sge = 4;
    init.max_recv_sge = 4;
    rdma_drv_qp::create_qp(n.drv, init, qp, status);
    expect_ok("create UD QP", status);
    attr = rdma_drv_qp_attr::type_id::create("ud_init");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_QKEY;
    attr.state = RDMA_DRV_QPS_INIT;
    attr.qkey = qkey;
    qp.modify(n.drv, attr, status);
    expect_ok("UD INIT", status);
    attr = rdma_drv_qp_attr::type_id::create("ud_rtr");
    attr.mask = rdma_drv_qp_attr::M_STATE;
    attr.state = RDMA_DRV_QPS_RTR;
    qp.modify(n.drv, attr, status);
    expect_ok("UD RTR", status);
    attr = rdma_drv_qp_attr::type_id::create("ud_rts");
    attr.mask = rdma_drv_qp_attr::M_STATE | rdma_drv_qp_attr::M_SQ_PSN;
    attr.state = RDMA_DRV_QPS_RTS;
    attr.sq_psn = 0;
    qp.modify(n.drv, attr, status);
    expect_ok("UD RTS", status);
  endtask

  // 功能：UD：Q_Key 不符的 SEND 被 B 静默丢弃（qkey_drops 加一，B 无完成）；Q_Key 正确的 SEND 在
  //   接收缓冲前 40B 写 GRH（IPv4 头 0x45、总长、TTL、UDP），数据从 +40 起，byte_len = 载荷 + 40。
  // 输入/输出及副作用：创建一对 UD QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_ud();
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    rdma_bytes_t grh;
    rdma_status status;

    make_ud(a, 32'h1111_0001, qa);
    make_ud(b, 32'h2222_0002, qb);
    rwr = rdma_drv_recv_wr::type_id::create("ud_recv");
    rwr.wr_id = next_wr_id++;
    rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h3000, 'h200, b.mr.key()));
    rdma_drv_wr::post_recv(b.drv, qb, rwr, status);
    expect_ok("post UD recv", status);
    data = fill(a, 'h400, 64, 8'h67);
    foreach (ud_qkeys[k]) begin
      wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h400}, '{64});
      wr.dest_qpn = qb.qpn;
      wr.dmac = b.mac;
      wr.qkey = ud_qkeys[k];
      rdma_drv_wr::post_send(a.drv, qa, wr, status);
      expect_ok("post UD send", status);
      wait_wcs(a, 1, wcs);
      expect_wc("UD sq", wcs[0], wr.wr_id, 1'b0);
      if (k == 0)
        expect_b_idle("UD bad Q_Key");
    end
    if (b.dev.nic.qkey_drops != 1)
      `uvm_error("UD", $sformatf("qkey_drops %0d, expected 1", b.dev.nic.qkey_drops))
    wait_wcs(b, 1, wcs);
    expect_wc("UD rq", wcs[0], rwr.wr_id, 1'b1);
    if (wcs[0].byte_len != 104 || wcs[0].src_qp != qa.qpn)
      `uvm_error("UD", $sformatf("byte_len %0d src_qp %0d", wcs[0].byte_len, wcs[0].src_qp))
    expect_mem("UD data", b, 'h3000 + 40, data);
    grh = rdma_be::zeros(40);
    grh[20] = 8'h45;
    grh[23] = 8'd116;
    grh[28] = 8'd64;
    grh[29] = 8'd17;
    expect_mem("UD GRH", b, 'h3000, grh);
  endtask

  // 功能：SRQ 上 3 个 SGE 的 RECV 写入 SGB（签名），SEND 0xA0 字节按 SGE 切分写入 B。
  // 输入/输出及副作用：创建 SRQ 与一对 QP。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_srq_sgb();
    rdma_drv_srq srq;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    rdma_status status;

    rdma_drv_srq::create_srq(b.drv, b.pd, 16, 0, srq, status);
    expect_ok("create SRQ", status);
    make_pair(srq, qa, qb);
    rwr = rdma_drv_recv_wr::type_id::create("srq_sgb_recv");
    rwr.wr_id = next_wr_id++;
    for (int k = 0; k < 3; k++)
      rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h3400 + k * 'h100, 'h40,
                                            b.mr.key()));
    rdma_drv_wr::post_srq_recv(b.drv, srq, rwr, status);
    expect_ok("post SRQ SGB recv", status);
    data = fill(a, 'h500, 'ha0, 8'h77);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h500}, '{'ha0});
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post SEND to SRQ SGB", status);
    wait_wcs(a, 1, wcs);
    expect_wc("SRQ SGB sq", wcs[0], wr.wr_id, 1'b0);
    wait_wcs(b, 1, wcs);
    expect_wc("SRQ SGB rq", wcs[0], rwr.wr_id, 1'b1);
    expect_mem("SRQ SGB part 0", b, 'h3400, rdma_be::slice(data, 0, 'h40));
    expect_mem("SRQ SGB part 1", b, 'h3500, rdma_be::slice(data, 'h40, 'h40));
    expect_mem("SRQ SGB part 2", b, 'h3600, rdma_be::slice(data, 'h80, 'h20));
  endtask

  // 功能：rc_to_urc 下建一对 URC QP（各用新建的 64 深 CQ）。
  // 输入/输出及副作用：ua/ub/qa/qb 输出。
  // 失败/边界：失败报告 UVM_FATAL。
  task make_urc_pair(output rdma_drv_cq ua, output rdma_drv_cq ub, output rdma_drv_qp qa,
                     output rdma_drv_qp qb);
    rdma_status status;

    rdma_drv_cq::create_cq(a.drv, 64, 0, ua, status);
    expect_ok("create URC CQ on A", status);
    rdma_drv_cq::create_cq(b.drv, 64, 0, ub, status);
    expect_ok("create URC CQ on B", status);
    a.drv.cfg.rc_to_urc = 1'b1;
    b.drv.cfg.rc_to_urc = 1'b1;
    make_pair(null, qa, qb, ua, ub);
    a.drv.cfg.rc_to_urc = 1'b0;
    b.drv.cfg.rc_to_urc = 1'b0;
  endtask

  // 功能：URC SQ 异常：A 先发一个成功的 WRITE，再发错 rkey 的 WRITE 与一个 SEND；B 回 REMOTE_ACCESS
  //   NAK，A 设备上报 SQ ABNML CEQE 并停止该 SQ；A 依次得到 SUCCESS、REM_ACCESS_ERR、FLUSH_ERR。
  // 输入/输出及副作用：创建一对 URC QP 与 CQ。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_urc_sq_abnormal();
    rdma_drv_cq ua;
    rdma_drv_cq ub;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wrs[3];
    rdma_drv_wc wcs[$];
    rdma_bytes_t data;
    rdma_status status;

    make_urc_pair(ua, ub, qa, qb);
    data = fill(a, 'h600, 32, 8'h87);
    wrs[0] = send_wr(a, RDMA_DRV_WR_WRITE, '{'h600}, '{32});
    wrs[0].remote_va = b.data_buf.iova + 'h3700;
    wrs[0].rkey = b.mr.key();
    wrs[1] = send_wr(a, RDMA_DRV_WR_WRITE, '{'h600}, '{32});
    wrs[1].remote_va = b.data_buf.iova + 'h3700;
    wrs[1].rkey = b.mr.key() ^ 32'h1;
    wrs[2] = send_wr(a, RDMA_DRV_WR_SEND, '{'h600}, '{32});
    foreach (wrs[k]) begin
      rdma_drv_wr::post_send(a.drv, qa, wrs[k], status);
      expect_ok("post URC abnormal", status);
    end
    wait_urc(a, ua, 3, wcs);
    expect_wc("URC ok before abnormal", wcs[0], wrs[0].wr_id, 1'b0);
    expect_wc("URC SQ abnormal", wcs[1], wrs[1].wr_id, 1'b0, RDMA_DRV_WC_REM_ACCESS_ERR);
    expect_wc("URC SQ flush", wcs[2], wrs[2].wr_id, 1'b0, RDMA_DRV_WC_FLUSH_ERR);
    if (wcs[1].vendor_err != RDMA_ECODE_EC_RPE_NAK_FATAL_ERR)
      `uvm_error("URC SQ abnormal", $sformatf("vendor %02h", wcs[1].vendor_err))
    expect_mem("URC write before abnormal", b, 'h3700, data);
  endtask

  // 功能：URC RQ 异常：B 的 RECV 只有 16B，A SEND 64B；B 设备上报 RQ ABNML CEQE（0x9C）并回
  //   INVALID_REQUEST NAK；B 得到 vendor 0x9C 的接收错误，A 得到 REM_INV_REQ_ERR。
  // 输入/输出及副作用：创建一对 URC QP 与 CQ。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_urc_rq_abnormal();
    rdma_drv_cq ua;
    rdma_drv_cq ub;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_recv_wr rwr;
    rdma_drv_send_wr wr;
    rdma_drv_wc wcs[$];
    rdma_bytes_t scratch;
    rdma_status status;

    make_urc_pair(ua, ub, qa, qb);
    rwr = rdma_drv_recv_wr::type_id::create("urc_small_recv");
    rwr.wr_id = next_wr_id++;
    rwr.sges.push_back(rdma_drv_sge::make(b.data_buf.iova + 'h3800, 'h10, b.mr.key()));
    rdma_drv_wr::post_recv(b.drv, qb, rwr, status);
    expect_ok("post URC small recv", status);
    scratch = fill(a, 'h700, 64, 8'h97);
    wr = send_wr(a, RDMA_DRV_WR_SEND, '{'h700}, '{64});
    rdma_drv_wr::post_send(a.drv, qa, wr, status);
    expect_ok("post URC oversized SEND", status);
    wait_urc(b, ub, 1, wcs);
    expect_wc("URC RQ abnormal", wcs[0], rwr.wr_id, 1'b1, RDMA_DRV_WC_GENERAL_ERR);
    if (wcs[0].vendor_err != RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC)
      `uvm_error("URC RQ abnormal", $sformatf("vendor %02h", wcs[0].vendor_err))
    wait_urc(a, ua, 1, wcs);
    expect_wc("URC requester of RQ abnormal", wcs[0], wr.wr_id, 1'b0,
              RDMA_DRV_WC_REM_INV_REQ_ERR);
  endtask

  // 功能：URC 异常经 AEQ：A 设备改走 AEQE 上报；错 rkey 的 WRITE 后跟一个 SEND。驱动处理 AEQ 时记入
  //   SQ frag 的异常信息并把 QP 转 ERR，A 得到 REM_ACCESS_ERR 与 FLUSH_ERR，AEQ 记录 {0xB9, QPN}。
  // 输入/输出及副作用：创建一对 URC QP 与 CQ；临时切换 A 设备的上报通道。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_urc_aeqe();
    rdma_drv_cq ua;
    rdma_drv_cq ub;
    rdma_drv_qp qa;
    rdma_drv_qp qb;
    rdma_drv_send_wr wrs[2];
    rdma_drv_wc wcs[$];
    bit [31:0] events[$];
    rdma_status status;

    make_urc_pair(ua, ub, qa, qb);
    a.dev.nic.urc_abnormal_via_aeq = 1'b1;
    wrs[0] = send_wr(a, RDMA_DRV_WR_WRITE, '{'h600}, '{32});
    wrs[0].remote_va = b.data_buf.iova + 'h3700;
    wrs[0].rkey = b.mr.key() ^ 32'h1;
    wrs[1] = send_wr(a, RDMA_DRV_WR_SEND, '{'h600}, '{32});
    foreach (wrs[k]) begin
      rdma_drv_wr::post_send(a.drv, qa, wrs[k], status);
      expect_ok("post URC AEQE", status);
    end
    for (int t = 0; t < 200 && events.size() == 0; t++) begin
      #100ns;
      rdma_drv_wr::process_aeq(a.drv, events, status);
      expect_ok("process AEQ", status);
    end
    a.dev.nic.urc_abnormal_via_aeq = 1'b0;
    if (events.size() != 1 || events[0] != {RDMA_ECODE_EC_RPE_NAK_FATAL_ERR, 24'(qa.qpn)} ||
        qa.cur_state != RDMA_DRV_QPS_ERR)
      `uvm_error("URC AEQE", $sformatf("AEQ events %p, QP state %s", events,
                                       qa.cur_state.name()))
    wait_urc(a, ua, 2, wcs);
    expect_wc("URC AEQE abnormal", wcs[0], wrs[0].wr_id, 1'b0, RDMA_DRV_WC_REM_ACCESS_ERR);
    expect_wc("URC AEQE flush", wcs[1], wrs[1].wr_id, 1'b0, RDMA_DRV_WC_FLUSH_ERR);
  endtask
endclass
