// 目录：模型层 model/rdma_flow_resolver.sv。
// 层次：RDMA 流量配置解析层。
// 职责：把 mutable flow plan 和各 profile 解析为独立的 QP/QPC/HMC/message/netpacket/endpoint/fault
//   snapshot，并在发布前执行跨对象约束；不创建真实 driver/dev/link，也不解析 AIP/Tcl。
// 依赖：rdma_flow_profiles.sv、rdma_status；资源 handle 在此仅生成稳定值占位，实际分配仍归资源 owner。
// 所有权与生命周期：resolver 拥有输出 snapshot 直到调用方接管；输入 profile 只读，不被修改；输出
//   freeze 后可跨组件共享，reset_epoch 由调用方提供并用于拒绝旧 binding。

class rdma_config_resolver;

  // 功能：为 profile/snapshot 设置统一 source identity 与 reset epoch。
  // 输入/输出及副作用：src/dst 为对象引用；只写 dst 的 source_id/reset_epoch，不改变其他字段。
  // 失败/边界：任一对象为空时静默返回，由上层 resolve 的空句柄检查负责报错。
  static function void stamp(rdma_flow_profile_base src, rdma_flow_profile_base dst,
                             string source_id, longint unsigned reset_epoch);
    if (src == null || dst == null)
      return;
    dst.source_id = source_id;
    dst.reset_epoch = reset_epoch;
    dst.frozen = 1'b0;
  endfunction

  // 功能：复制 QP profile 的用户字段和 resolver 关联字段到 QP snapshot。
  // 输入/输出及副作用：src 只读，dst 全字段覆盖；payload/外部资源不涉及。
  // 失败/边界：空 src/dst 不执行；策略非法由 dst.validate() 在发布前拒绝。
  static function void copy_qp(rdma_qp_profile src, rdma_qp_snapshot dst);
    if (src == null || dst == null) return;
    dst.index = src.index;
    dst.qp_type_mode = src.qp_type_mode; dst.qp_type = src.qp_type;
    dst.sq_depth_mode = src.sq_depth_mode; dst.rq_depth_mode = src.rq_depth_mode;
    dst.mtu_mode = src.mtu_mode; dst.pkey_mode = src.pkey_mode;
    dst.qkey_mode = src.qkey_mode; dst.psn_mode = src.psn_mode;
    dst.dest_qpn_mode = src.dest_qpn_mode;
    dst.max_send_sge_mode = src.max_send_sge_mode;
    dst.max_recv_sge_mode = src.max_recv_sge_mode;
    dst.max_inline_mode = src.max_inline_mode;
    dst.sq_depth = src.sq_depth; dst.rq_depth = src.rq_depth;
    dst.mtu = src.mtu; dst.pkey = src.pkey; dst.qkey = src.qkey;
    dst.psn = src.psn; dst.dest_qpn = src.dest_qpn;
    dst.max_send_sge = src.max_send_sge; dst.max_recv_sge = src.max_recv_sge;
    dst.max_inline = src.max_inline;
    dst.local_qpn = src.local_qpn; dst.qp_h = src.qp_h;
    dst.send_cq_h = src.send_cq_h; dst.recv_cq_h = src.recv_cq_h;
  endfunction

  // 功能：复制 QPC profile 到 QPC snapshot，保留路径和权限策略的用户选择。
  // 输入/输出及副作用：src 只读，dst 字段覆盖；不写任何 driver/dev 对象。
  // 失败/边界：空对象不执行；QPC 与 QP 的交叉一致性由 resolve 统一校验。
  static function void copy_qpc(rdma_qpc_profile src, rdma_qpc_snapshot dst);
    if (src == null || dst == null) return;
    dst.qp_index = src.qp_index;
    dst.pd_ref_mode = src.pd_ref_mode; dst.send_cq_ref_mode = src.send_cq_ref_mode;
    dst.recv_cq_ref_mode = src.recv_cq_ref_mode; dst.srq_ref_mode = src.srq_ref_mode;
    dst.dmac_mode = src.dmac_mode; dst.vlan_mode = src.vlan_mode;
    dst.fwd_mode = src.fwd_mode; dst.tunnel_mode = src.tunnel_mode;
    dst.access_mode = src.access_mode;
    dst.pd_ref = src.pd_ref; dst.send_cq_ref = src.send_cq_ref;
    dst.recv_cq_ref = src.recv_cq_ref; dst.srq_ref = src.srq_ref;
    dst.dmac = src.dmac; dst.local_ip = src.local_ip; dst.vlan = src.vlan;
    dst.fwd = src.fwd; dst.tunnel = src.tunnel; dst.access = src.access;
    dst.qp_h = src.qp_h; dst.send_cqn = src.send_cqn; dst.recv_cqn = src.recv_cqn;
    dst.qpc_shadow = src.qpc_shadow; dst.sq_backing = src.sq_backing;
    dst.rq_backing = src.rq_backing; dst.pd_h = src.pd_h; dst.srq_h = src.srq_h;
  endfunction

  // 功能：复制 HMC profile 到 HMC snapshot。
  // 输入/输出及副作用：src 只读，dst 字段覆盖；地址仍是值快照，不取得 HMC owner。
  // 失败/边界：空对象不执行；PBA/PBL/SD 合法性由 snapshot validate 检查。
  static function void copy_hmc(rdma_hmc_profile src, rdma_hmc_snapshot dst);
    if (src == null || dst == null) return;
    dst.page_size_mode = src.page_size_mode; dst.pbl_mode_mode = src.pbl_mode_mode;
    dst.sd_vld_mode = src.sd_vld_mode; dst.vf_id_mode = src.vf_id_mode;
    dst.pba_alignment_mode = src.pba_alignment_mode;
    dst.page_size = src.page_size; dst.pbl_mode = src.pbl_mode;
    dst.sd_vld = src.sd_vld; dst.vf_id = src.vf_id;
    dst.pba_alignment = src.pba_alignment; dst.hmc_pba = src.hmc_pba;
    dst.pbl_base = src.pbl_base; dst.sd_base = src.sd_base;
  endfunction

  // 功能：复制 message profile 及其 payload 到 message snapshot。
  // 输入/输出及副作用：src 只读；dst 字段和 payload 队列独立复制，不保存源队列别名。
  // 失败/边界：空对象不执行；长度、opcode 与 QP 索引由 snapshot validate/resolve 检查。
  static function void copy_message(rdma_message_profile src, rdma_message_snapshot dst);
    if (src == null || dst == null) return;
    dst.index = src.index; dst.qp_index = src.qp_index;
    dst.opcode_mode = src.opcode_mode; dst.opcode = src.opcode;
    dst.sge_count_mode = src.sge_count_mode; dst.local_offset_mode = src.local_offset_mode;
    dst.length_mode = src.length_mode; dst.lkey_mode = src.lkey_mode;
    dst.rkey_mode = src.rkey_mode; dst.remote_va_mode = src.remote_va_mode;
    dst.imm_mode = src.imm_mode; dst.atomic_mode = src.atomic_mode;
    dst.sge_count = src.sge_count; dst.local_offset = src.local_offset;
    dst.length = src.length; dst.lkey = src.lkey; dst.rkey = src.rkey;
    dst.remote_va = src.remote_va; dst.imm = src.imm;
    dst.atomic_compare = src.atomic_compare; dst.atomic_swap_add = src.atomic_swap_add;
    dst.signaled = src.signaled; dst.payload = src.payload;
    dst.wqe_address = src.wqe_address; dst.psn_first = src.psn_first;
  endfunction

  // 功能：复制 netpacket profile 及业务 header/payload 到 netpacket snapshot。
  // 输入/输出及副作用：src 只读；dst 的动态数组独立复制，避免 resolver 输出引用输入队列。
  // 失败/边界：空对象不执行；QPC 同名字段冲突由 resolve_netpacket 检查。
  static function void copy_netpacket(rdma_netpacket_profile src, rdma_netpacket_snapshot dst);
    if (src == null || dst == null) return;
    dst.message_index = src.message_index; dst.transport_mode = src.transport_mode;
    dst.transport = src.transport; dst.dmac_mode = src.dmac_mode;
    dst.smac_mode = src.smac_mode; dst.source_ip_mode = src.source_ip_mode;
    dst.destination_ip_mode = src.destination_ip_mode;
    dst.udp_source_port_mode = src.udp_source_port_mode;
    dst.udp_destination_port_mode = src.udp_destination_port_mode;
    dst.vlan_mode = src.vlan_mode; dst.qpn_mode = src.qpn_mode; dst.psn_mode = src.psn_mode;
    dst.dmac = src.dmac; dst.smac = src.smac; dst.source_ip = src.source_ip;
    dst.destination_ip = src.destination_ip; dst.udp_source_port = src.udp_source_port;
    dst.udp_destination_port = src.udp_destination_port; dst.vlan = src.vlan;
    dst.qpn = src.qpn; dst.psn = src.psn;
    dst.business_header = src.business_header; dst.payload = src.payload;
  endfunction

  // 功能：复制 endpoint profile 到 endpoint snapshot。
  // 输入/输出及副作用：src 只读，dst 值字段覆盖；不调用 endpoint 生命周期钩子。
  // 失败/边界：空对象不执行；外部 endpoint handle 只作为非拥有值保留。
  static function void copy_endpoint(rdma_endpoint_profile src, rdma_endpoint_snapshot dst);
    if (src == null || dst == null) return;
    dst.dut_port_mode = src.dut_port_mode; dst.dut_mac_mode = src.dut_mac_mode;
    dst.peer_mac_mode = src.peer_mac_mode; dst.mtu_mode = src.mtu_mode;
    dst.frame_limit_mode = src.frame_limit_mode; dst.queue_depth_mode = src.queue_depth_mode;
    dst.dut_port = src.dut_port; dst.dut_mac = src.dut_mac; dst.peer_mac = src.peer_mac;
    dst.mtu = src.mtu; dst.frame_limit = src.frame_limit; dst.queue_depth = src.queue_depth;
    dst.tx_timeout = src.tx_timeout; dst.rx_timeout = src.rx_timeout; dst.endpoint_h = src.endpoint_h;
  endfunction

  // 功能：复制 fault profile 到 fault snapshot。
  // 输入/输出及副作用：src 只读，dst 字段覆盖；不修改计数器或 link 状态。
  // 失败/边界：空对象不执行；故障启用条件和概率由 snapshot validate 检查。
  static function void copy_fault(rdma_fault_profile src, rdma_fault_snapshot dst);
    if (src == null || dst == null) return;
    dst.index = src.index; dst.enabled = src.enabled; dst.kind = src.kind;
    dst.direction_mode = src.direction_mode; dst.direction = src.direction;
    dst.function_index = src.function_index; dst.qp_index = src.qp_index;
    dst.qpn = src.qpn; dst.opcode = src.opcode; dst.segment = src.segment;
    dst.frame_offset = src.frame_offset; dst.skip = src.skip; dst.count = src.count;
    dst.probability_percent = src.probability_percent; dst.delay = src.delay;
  endfunction

  // 功能：解析 QP profile 并补齐稳定的本地 QPN/QP/CQ handle 占位。
  // 输入/输出及副作用：src 只读；dst 为新建 snapshot，auto 字段按位置生成确定值。
  // 失败/边界：src 为空返回 INVALID_ARGUMENT；零深度/非法模式由 dst.validate 拒绝。
  static function rdma_status resolve_qp(rdma_qp_profile src, int unsigned ordinal,
                                          string source_id, longint unsigned epoch,
                                          output rdma_qp_snapshot dst);
    dst = null;
    if (src == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null QP profile");
    dst = rdma_qp_snapshot::type_id::create($sformatf("qp_snapshot_%0d", ordinal));
    copy_qp(src, dst);
    stamp(src, dst, source_id, epoch);
    if (dst.local_qpn == 0) dst.local_qpn = 24'h100 + ordinal;
    if (dst.qp_h == 0) dst.qp_h = 64'h1000 + ordinal;
    if (dst.send_cq_h == 0) dst.send_cq_h = 64'h2000 + ordinal;
    if (dst.recv_cq_h == 0) dst.recv_cq_h = 64'h3000 + ordinal;
    if (!dst.freeze())
      return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze QP snapshot");
    return dst.validate();
  endfunction

  // 功能：将 message 与对应 QP snapshot 做索引和 opcode 约束检查。
  // 输入/输出及副作用：只读 config arrays；返回状态，不修改 message。
  // 失败/边界：qp_index 超界、RC 使用 UD 专属语义或 remote 字段缺失时返回配置错误。
  static function rdma_status validate_message_binding(rdma_message_snapshot msg,
                                                        rdma_resolved_config cfg);
    if (msg == null || cfg == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "message binding is null");
    if (msg.qp_index >= cfg.tx_qps.size() + cfg.rx_qps.size())
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "message QP index is out of range");
    if (msg.opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM, RDMA_WR_RDMA_READ,
                           RDMA_WR_ATOMIC_CMP_SWAP, RDMA_WR_ATOMIC_FETCH_ADD} &&
        msg.remote_va == 0 && msg.remote_va_mode == RDMA_FIELD_FIXED)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "remote message VA is zero");
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction

  // 功能：按统一索引从 resolved config 取得 message 对应的 TX 或 RX QP snapshot。
  // 输入/输出及副作用：cfg 只读；返回非拥有引用，找不到时返回 null。
  // 失败/边界：index 先映射 TX 再映射 RX；超出两侧总数返回 null，不修改 config。
  static function rdma_qp_snapshot qp_for_message(rdma_resolved_config cfg,
                                                  int unsigned index);
    if (cfg == null)
      return null;
    if (index < cfg.tx_qps.size())
      return cfg.tx_qps[index];
    index -= cfg.tx_qps.size();
    if (index < cfg.rx_qps.size())
      return cfg.rx_qps[index];
    return null;
  endfunction

  // 功能：检查 netpacket 与其 message/QPC 的同名 path 字段一致性，并补齐 AUTO QPN/PSN。
  // 输入/输出及副作用：np 字段可填充 AUTO 值；cfg 只读；返回状态。
  // 失败/边界：message_index 越界、FIXED QPN/PSN 与 QPC 不等、非法 transport 均拒绝；不回写 QPC。
  static function rdma_status resolve_netpacket(rdma_netpacket_snapshot np,
                                                rdma_message_snapshot msg,
                                                rdma_qp_snapshot qp);
    if (np == null || msg == null || qp == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "netpacket binding is null");
    if (np.qpn_mode == RDMA_FIELD_AUTO) np.qpn = qp.local_qpn;
    else if (np.qpn_mode == RDMA_FIELD_FIXED && np.qpn != qp.local_qpn)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "netpacket QPN conflicts with QPC snapshot");
    if (np.psn_mode == RDMA_FIELD_AUTO) np.psn = qp.psn;
    else if (np.psn_mode == RDMA_FIELD_FIXED && np.psn != qp.psn)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "netpacket PSN conflicts with QPC snapshot");
    if (np.transport_mode == RDMA_FIELD_AUTO) begin
      case (qp.qp_type)
        RDMA_FLOW_QP_RC: np.transport = RDMA_TRANSPORT_RC;
        RDMA_FLOW_QP_UD: np.transport = RDMA_TRANSPORT_UD;
        RDMA_FLOW_QP_URC: np.transport = RDMA_TRANSPORT_URC;
        default: return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "unsupported QP transport");
      endcase
    end
    return np.validate();
  endfunction

  // 功能：从 mutable flow plan 生成冻结 resolved config 与 DUT link snapshot。
  // 输入/输出及副作用：plan 只读；config/link 输出为独立对象；不创建、修改或持有 link/env/driver。
  // 失败/边界：空 plan、空 source/epoch、列表不一致、profile 非法或 QPC/netpacket 冲突均返回失败，
  //   且输出置 null；成功时两个 snapshot 使用同一 source_id/reset_epoch。
  static function rdma_status resolve(rdma_flow_plan plan,
                                      output rdma_resolved_config config,
                                      output rdma_dut_link_snapshot link);
    rdma_status status;
    rdma_qp_snapshot qp;
    rdma_qpc_snapshot qpc;
    rdma_hmc_snapshot hmc;
    rdma_message_snapshot msg;
    rdma_netpacket_snapshot np;
    rdma_endpoint_snapshot ep;
    rdma_fault_snapshot fault;
    string source_id;
    longint unsigned epoch;

    config = null;
    link = null;
    if (plan == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flow plan is null");
    if (plan.source_id == "" || plan.reset_epoch == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flow plan source identity is incomplete");
    status = plan.validate();
    if (!status.ok()) return status;
    source_id = plan.source_id;
    epoch = plan.reset_epoch;
    config = rdma_resolved_config::type_id::create("resolved_config");
    config.source_id = source_id; config.reset_epoch = epoch;

    foreach (plan.tx_qps[i]) begin
      status = resolve_qp(plan.tx_qps[i], i, source_id, epoch, qp);
      if (!status.ok()) begin config = null; return status; end
      config.tx_qps.push_back(qp);
    end
    foreach (plan.rx_qps[i]) begin
      status = resolve_qp(plan.rx_qps[i], plan.tx_qps.size() + i, source_id, epoch, qp);
      if (!status.ok()) begin config = null; return status; end
      config.rx_qps.push_back(qp);
    end
    foreach (plan.qpcs[i]) begin
      if (plan.qpcs[i] == null) begin config = null; return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null QPC profile"); end
      qpc = rdma_qpc_snapshot::type_id::create($sformatf("qpc_snapshot_%0d", i));
      copy_qpc(plan.qpcs[i], qpc); stamp(plan.qpcs[i], qpc, source_id, epoch);
      qpc.qpc_shadow = qpc.qpc_shadow == 0 ? 64'h4000 + i : qpc.qpc_shadow;
      qpc.sq_backing = qpc.sq_backing == 0 ? 64'h5000 + i : qpc.sq_backing;
      qpc.rq_backing = qpc.rq_backing == 0 ? 64'h6000 + i : qpc.rq_backing;
      if (!qpc.freeze()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze QPC snapshot"); end
      status = qpc.validate(); if (!status.ok()) begin config = null; return status; end
      config.qpcs.push_back(qpc);
    end
    if (plan.qpcs.size() == 0) begin
      for (int unsigned i = 0; i < config.tx_qps.size() + config.rx_qps.size(); i++) begin
        qpc = rdma_qpc_snapshot::type_id::create($sformatf("qpc_snapshot_%0d", i));
        qpc.qp_index = i;
        qpc.qp_h = qp_for_message(config, i).qp_h;
        qpc.send_cqn = i;
        qpc.recv_cqn = i;
        qpc.qpc_shadow = 64'h4000 + i;
        qpc.sq_backing = 64'h5000 + i;
        qpc.rq_backing = 64'h6000 + i;
        qpc.source_id = source_id; qpc.reset_epoch = epoch;
        if (!qpc.freeze()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze generated QPC snapshot"); end
        status = qpc.validate(); if (!status.ok()) begin config = null; return status; end
        config.qpcs.push_back(qpc);
      end
    end
    foreach (plan.hmcs[i]) begin
      if (plan.hmcs[i] == null) begin config = null; return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null HMC profile"); end
      hmc = rdma_hmc_snapshot::type_id::create($sformatf("hmc_snapshot_%0d", i));
      copy_hmc(plan.hmcs[i], hmc); stamp(plan.hmcs[i], hmc, source_id, epoch);
      if (hmc.hmc_pba == 0) hmc.hmc_pba = 64'h8000 + i * hmc.pba_alignment;
      if (!hmc.freeze()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze HMC snapshot"); end
      status = hmc.validate(); if (!status.ok()) begin config = null; return status; end
      config.hmcs.push_back(hmc);
    end
    if (plan.hmcs.size() == 0) begin
      for (int unsigned i = 0; i < config.tx_qps.size() + config.rx_qps.size(); i++) begin
        hmc = rdma_hmc_snapshot::type_id::create($sformatf("hmc_snapshot_%0d", i));
        hmc.source_id = source_id; hmc.reset_epoch = epoch;
        hmc.hmc_pba = 64'h8000 + i * hmc.pba_alignment;
        if (!hmc.freeze()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze generated HMC snapshot"); end
        status = hmc.validate(); if (!status.ok()) begin config = null; return status; end
        config.hmcs.push_back(hmc);
      end
    end
    foreach (plan.messages[i]) begin
      if (plan.messages[i] == null) begin config = null; return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null message profile"); end
      msg = rdma_message_snapshot::type_id::create($sformatf("message_snapshot_%0d", i));
      copy_message(plan.messages[i], msg); stamp(plan.messages[i], msg, source_id, epoch);
      if (!msg.freeze()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze message snapshot"); end
      status = msg.validate(); if (!status.ok()) begin config = null; return status; end
      config.messages.push_back(msg);
      status = validate_message_binding(msg, config); if (!status.ok()) begin config = null; return status; end
    end
    foreach (plan.netpackets[i]) begin
      if (plan.netpackets[i] == null) begin config = null; return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null netpacket profile"); end
      if (plan.netpackets[i].message_index >= config.messages.size()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "netpacket message index is out of range"); end
      np = rdma_netpacket_snapshot::type_id::create($sformatf("netpacket_snapshot_%0d", i));
      copy_netpacket(plan.netpackets[i], np); stamp(plan.netpackets[i], np, source_id, epoch);
      status = resolve_netpacket(np, config.messages[plan.netpackets[i].message_index],
                                 qp_for_message(config, config.messages[plan.netpackets[i].message_index].qp_index));
      if (!status.ok()) begin config = null; return status; end
      if (!np.freeze()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze netpacket snapshot"); end
      status = np.validate(); if (!status.ok()) begin config = null; return status; end
      config.netpackets.push_back(np);
    end
    foreach (plan.endpoints[i]) begin
      if (plan.endpoints[i] == null) begin config = null; return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null endpoint profile"); end
      ep = rdma_endpoint_snapshot::type_id::create($sformatf("endpoint_snapshot_%0d", i));
      copy_endpoint(plan.endpoints[i], ep); stamp(plan.endpoints[i], ep, source_id, epoch);
      if (!ep.freeze()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze endpoint snapshot"); end
      status = ep.validate(); if (!status.ok()) begin config = null; return status; end
      config.endpoints.push_back(ep);
    end
    foreach (plan.faults[i]) begin
      if (plan.faults[i] == null) begin config = null; return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null fault profile"); end
      fault = rdma_fault_snapshot::type_id::create($sformatf("fault_snapshot_%0d", i));
      copy_fault(plan.faults[i], fault); stamp(plan.faults[i], fault, source_id, epoch);
      if (!fault.freeze()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze fault snapshot"); end
      status = fault.validate(); if (!status.ok()) begin config = null; return status; end
      config.faults.push_back(fault);
    end
    if (config.endpoints.size() == 0) begin
      ep = rdma_endpoint_snapshot::type_id::create("endpoint_snapshot_0");
      ep.source_id = source_id; ep.reset_epoch = epoch; void'(ep.freeze());
      config.endpoints.push_back(ep);
    end
    if (config.netpackets.size() == 0) begin
      foreach (config.messages[i]) begin
        np = rdma_netpacket_snapshot::type_id::create($sformatf("netpacket_snapshot_%0d", i));
        np.message_index = i;
        np.source_id = source_id; np.reset_epoch = epoch;
        status = resolve_netpacket(np, config.messages[i], qp_for_message(config, config.messages[i].qp_index));
        if (!status.ok()) begin config = null; return status; end
        void'(np.freeze());
        config.netpackets.push_back(np);
      end
      if (config.netpackets.size() == 0) begin
        np = rdma_netpacket_snapshot::type_id::create("netpacket_snapshot_0");
        np.source_id = source_id; np.reset_epoch = epoch; void'(np.freeze());
        config.netpackets.push_back(np);
      end
    end
    if (!config.freeze()) begin config = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze resolved config"); end
    status = config.validate(); if (!status.ok()) begin config = null; return status; end

    link = rdma_dut_link_snapshot::type_id::create("dut_link_snapshot");
    link.source_id = source_id; link.reset_epoch = epoch;
    link.endpoint = config.endpoints[0];
    link.netpacket = config.netpackets[0];
    foreach (config.faults[i]) link.faults.push_back(config.faults[i]);
    if (!link.freeze()) begin config = null; link = null; return rdma_status::make(RDMA_SC_INVALID_STATE, "failed to freeze DUT link snapshot"); end
    status = link.validate(); if (!status.ok()) begin config = null; link = null; return status; end
    return rdma_status::make(RDMA_SC_OK, "");
  endfunction

  // 功能：提供 task 风格的 resolver 入口，便于 UVM sequence 直接接收 output status。
  // 输入/输出及副作用：转发 resolve 的两个 snapshot 输出；不额外分配或改变结果。
  // 失败/边界：与 resolve 完全相同；status 必定为非空 rdma_status。
  static task resolve_task(rdma_flow_plan plan, output rdma_resolved_config config,
                           output rdma_dut_link_snapshot link, output rdma_status status);
    status = resolve(plan, config, link);
  endtask
endclass

// 兼容简短名称的门面；实现仍集中在 rdma_config_resolver，避免两套校验规则漂移。
class rdma_flow_resolver;
  // 功能：将 flow plan 解析为 resolved config 和 DUT link snapshot。
  // 输入/输出及副作用：转发 rdma_config_resolver::resolve；输出为独立冻结对象。
  // 失败/边界：空 plan、非法 profile、冲突字段或旧 epoch 直接返回对应 status。
  static function rdma_status resolve(rdma_flow_plan plan,
                                      output rdma_resolved_config config,
                                      output rdma_dut_link_snapshot link);
    return rdma_config_resolver::resolve(plan, config, link);
  endfunction
endclass
