// 目录/层次：tests/unit；TX-only scoreboard 定向契约 fixture。
// 职责：用完整 codec 帧验证无帧拒绝、首发计数、重传幂等以及出口/字段/payload/CRC 拒绝。
// 依赖：rdma_env_pkg、rdma_netpkt_pkg；不创建 DUT、Host memory 或 ACK/RX 路径。
// 所有权/生命周期：测试拥有 item/codec，scoreboard 保存独立期望；fixture 不是实际 DUT 发包证据。
class rdma_tx_contract_test extends uvm_test;
  `uvm_component_utils(rdma_tx_contract_test)

  rdma_scoreboard	sb;

  // 功能：构造尚未创建 scoreboard 的 TX 契约测试。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；不创建硬件或传输线程。
  // 失败/边界：组件由 UVM build 创建后才可运行 fixture。
  extern function new(string name = "rdma_tx_contract_test", uvm_component parent = null);

  // 功能：创建只接完整帧输入的 scoreboard，并静默预期的负例报告。
  // 输入/输出及副作用：phase 传给基类；sb 由测试拥有，errors 仍正常累计。
  // 失败/边界：只抑制 RDMA_SB 的 UVM_ERROR 展示；断言失败继续以 TX_CONTRACT fatal 报告。
  extern function void build_phase(uvm_phase phase);

  // 功能：构建固定地址、VLAN、PSN、IMM 和 payload 的发送 WR fixture。
  // 输入/输出及副作用：ud 选择 RC/UD；返回独立 item/QP/Function，不使用真实 driver 或 MR。
  // 失败/边界：仅供 expect_tx 使用，不能交给 verb driver 投递；owner.index 是本地下标。
  extern function rdma_verb_item make_item(bit ud);

  // 功能：执行 RC/UD 完整帧正负例，确认冻结值及重传计数契约。
  // 输入/输出及副作用：持有 objection；构造有效 CRC 的错误 payload/目的帧及损坏 CRC 帧。
  // 失败/边界：任何未检测错误或额外计数都 fatal；结束清理负例状态避免 check_phase 重报。
  extern task run_phase(uvm_phase phase);
endclass

// 功能：建立 TX fixture 的 UVM test 外壳。
// 输入/输出及副作用：name/parent 传给基类，sb 留空。
// 失败/边界：构造不运行 codec，不访问硬件。
function rdma_tx_contract_test::new(string name = "rdma_tx_contract_test", uvm_component parent = null);
  super.new(name, parent);
endfunction

// 功能：创建用于正负例的 scoreboard，并仅抑制预期错误的日志动作。
// 输入/输出及副作用：phase 传给父类；sb.errors 保持可检查的真实计数。
// 失败/边界：测试断言使用不同 report ID，不能被此过滤隐藏。
function void rdma_tx_contract_test::build_phase(uvm_phase phase);
  super.build_phase(phase);
  sb = rdma_scoreboard::type_id::create("sb", this);
  sb.set_report_severity_id_action(UVM_ERROR, "RDMA_SB", UVM_NO_ACTION);
endfunction

// 功能：建立固定 SEND_IMM 期望输入，覆盖非零 VLAN 和非默认 UDP 源端口。
// 输入/输出及副作用：ud 选择传输；返回 item 拥有独立 QP 和 Function 描述，无真实资源分配。
// 失败/边界：item 未含 MR，调用者仅可使用 TX expectation API。
function rdma_verb_item rdma_tx_contract_test::make_item(bit ud);
  rdma_verb_item	item;

  item = new("tx_item");
  item.qp = new("qp");
  item.qp.owner = new("function");
  item.qp.owner.index = 2;
  item.qp.id = 17;
  item.qp.qp_type = ud ? RDMA_DRV_QPT_UD : RDMA_DRV_QPT_RC;
  item.qp.psn = 7;
  item.qp.tx_only = 1;
  item.qp.pkt.src_mac = 48'h02_00_00_00_00_01;
  item.qp.pkt.src_ip = 32'h0a000001;
  item.qp.pkt.dst_ip = 32'h0a000002;
  item.qp.pkt.vlan_en = 1;
  item.qp.pkt.vlan_id = 37;
  item.qp.pkt.udp_sport = 5071;
  item.tx_dest_qpn = 23;
  item.tx_dest_qkey = 32'h12345678;
  item.tx_dmac = 48'h02_00_00_00_00_02;
  item.tx_only = 1;
  item.op = RDMA_VERB_SEND_IMM;
  item.imm = 32'h1234abcd;
  item.wr_id = 1;
  item.length = 4;
  item.data = '{8'hde, 8'had, 8'hbe, 8'hef};
  return item;
endfunction

// 功能：验证无帧不成功、合法首发成功、完全重复幂等以及完整错误帧被拒绝。
// 输入/输出及副作用：phase 管理 objection；负例使用 errors 增量断言，最后清空 fixture 记录。
// 失败/边界：本测试不证明真实 DUT 输出，仅验证平台 monitor 必须满足的完整帧验收接口。
task rdma_tx_contract_test::run_phase(uvm_phase phase);
  rdma_verb_item	item;
  rdma_netpkt_codec	codec;
  rdma_packet	pkt;
  rdma_status	status;
  byte unsigned	frame[$];
  byte unsigned	bad[$];
  int unsigned	errors_before;

  phase.raise_objection(this);
  for (int mode = 0; mode < 2; mode++) begin
    sb.errors = 0;
    sb.begin_tx();
    item = make_item(bit'(mode));
    if (!sb.expect_tx(item))
      `uvm_fatal("TX_CONTRACT", "valid expectation was rejected")
    if (sb.tx_complete(1))
      `uvm_fatal("TX_CONTRACT", "no frame incorrectly passed")
    frame = sb.tx_expected[0].frame;
    // 修改上游对象后旧帧仍须匹配，证明验收没有借用可变 payload。
    item.data[0] = 0;
    sb.observe_tx(2, frame);
    sb.observe_tx(2, frame);
    if (!sb.tx_complete(1) || sb.tx_checked != 1)
      `uvm_fatal("TX_CONTRACT", "valid frame or retransmission contract failed")
    errors_before = sb.errors;
    sb.observe_tx(3, frame);
    bad = frame;
    bad[bad.size() - 5] ^= 8'h01;
    sb.observe_tx(2, bad);
    bad = '{8'h00};
    sb.observe_tx(2, bad);
    codec = new("fixture_codec");
    codec.src_mac = item.qp.pkt.src_mac;
    codec.dst_mac = item.tx_dmac;
    codec.src_ip = item.qp.pkt.src_ip;
    codec.dst_ip = item.qp.pkt.dst_ip;
    codec.udp_src_port = item.qp.pkt.udp_sport;
    codec.vlan_enable = 1;
    codec.vlan_id = 37;
    pkt = sb.tx_expected[0].pkt;
    pkt.payload[0] ^= 8'h01;
    status = codec.encode(pkt, bad);
    if (!status.ok())
      `uvm_fatal("TX_CONTRACT", "negative payload frame could not encode")
    // 不改期望对象：错误帧生成之后恢复字段，再提交观测。
    pkt.payload[0] ^= 8'h01;
    sb.observe_tx(2, bad);
    codec.dst_ip ^= 1;
    status = codec.encode(pkt, bad);
    if (!status.ok())
      `uvm_fatal("TX_CONTRACT", "negative destination frame could not encode")
    sb.observe_tx(2, bad);
    if (sb.errors != errors_before + 5 || sb.tx_complete(1) || sb.tx_checked != 1)
      `uvm_fatal("TX_CONTRACT", "negative frame was accepted or counted")
  end
  sb.errors = 0;
  sb.tx_expected.delete();
  sb.tx_seen.delete();
  sb.tx_wr_ids.delete();
  phase.drop_objection(this);
endtask
