// 目录：验证组件层 tb/rdma_coverage.sv。
// 层：验证组件。
// 职责：功能覆盖率（一个 subscriber，每个覆盖面一个 covergroup）：
//   - verb：op × QP 类型、op × 长度区间、SGE 数、数据模式；
//   - completion：完成状态 × 方向（SQ/RQ）；
//   - error：预测的错误状态 × op 类别；
//   - qp_state：QP 状态迁移（驱动状态，前一状态 → 当前状态）；
//   - fault：链路故障类型 × 报文类别（报告时按已作用的规则采样）；
//   - reset：复位操作 × 范围（单 Function / 两个 / 更多）；
//   - cmq：CMQ 命令类别（设备执行记录）；
//   - wire：链路报文 opcode × 传输类型。
//   report_phase 打印各覆盖面与平均值（RDMA_COV 行，回归汇总据此提取）。
// 依赖：rdma_env（链路、dpu 系统）、verb/控制面/资源事件。
// 所有权：只读观测。
// 生命周期：cfg.cov_enable 时由 env 创建。

`uvm_analysis_imp_decl(_cov_verb)
`uvm_analysis_imp_decl(_cov_cqe)
`uvm_analysis_imp_decl(_cov_res)
`uvm_analysis_imp_decl(_cov_ctrl)
`uvm_analysis_imp_decl(_cov_wire)

class rdma_coverage extends uvm_component;
  `uvm_component_utils(rdma_coverage)

  rdma_env env;
  uvm_analysis_imp_cov_verb #(rdma_verb_item, rdma_coverage) verb_export;
  uvm_analysis_imp_cov_cqe #(rdma_verb_completion, rdma_coverage) cqe_export;
  uvm_analysis_imp_cov_res #(rdma_res_event, rdma_coverage) res_export;
  uvm_analysis_imp_cov_ctrl #(rdma_ctrl_item, rdma_coverage) ctrl_export;
  uvm_analysis_imp_cov_wire #(rdma_link_obs, rdma_coverage) wire_export;

  // 采样值。
  protected rdma_verb_item it;
  protected int unsigned qp_kind;
  protected rdma_verb_completion done;
  protected bit [7:0] move;
  protected rdma_fault_e fault_kind;
  protected int fault_opcode;
  protected rdma_ctrl_op_e reset_op;
  protected int unsigned reset_scope;
  protected bit [7:0] cmq_opcode;
  protected rdma_packet pkt;
  // 每个 QP（uid）上次采样的驱动状态；每个 Function 已采样的 CMQ 记录数。
  protected bit [3:0] last_state[longint unsigned];
  protected int unsigned cmq_seen[int unsigned];

  covergroup cg_verb;
    op: coverpoint it.op;
    kind: coverpoint qp_kind {
      bins rc = {0};
      bins ud = {1};
      bins urc = {2};
    }
    len: coverpoint it.length {
      bins tiny = {[0:63]};
      bins one_pkt = {[64:1024]};
      bins few_pkts = {[1025:4096]};
      bins many_pkts = {[4097:$]};
    }
    sge: coverpoint it.sge_count {
      bins one = {[0:1]};
      bins two = {2};
      bins sgb = {[3:$]};
    }
    mode: coverpoint it.data_mode;
    op_kind: cross op, kind {
      ignore_bins ud_rdma = binsof(kind.ud) &&
                            !binsof(op) intersect {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM,
                                                   RDMA_VERB_RECV};
    }
    op_len: cross op, len {
      ignore_bins atomic_len = binsof(op) intersect {RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD} &&
                               !binsof(len.tiny);
    }
  endgroup

  covergroup cg_completion;
    status: coverpoint done.status;
    dir: coverpoint done.rq;
    status_dir: cross status, dir {
      ignore_bins rq_remote = binsof(dir) intersect {1} &&
                              binsof(status) intersect {RDMA_DRV_WC_REM_INV_REQ_ERR,
                                                        RDMA_DRV_WC_REM_ACCESS_ERR,
                                                        RDMA_DRV_WC_REM_OP_ERR};
    }
  endgroup

  covergroup cg_error;
    status: coverpoint it.expect_status {ignore_bins ok = {RDMA_DRV_WC_SUCCESS};}
    op: coverpoint it.op {
      bins send = {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM};
      bins write = {RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM};
      bins read = {RDMA_VERB_READ};
      bins atomic = {RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
      bins recv = {RDMA_VERB_RECV};
    }
  endgroup

  covergroup cg_qp_state;
    transition: coverpoint move {
      bins reset_init = {{4'(RDMA_DRV_QPS_RESET), 4'(RDMA_DRV_QPS_INIT)}};
      bins init_rtr = {{4'(RDMA_DRV_QPS_INIT), 4'(RDMA_DRV_QPS_RTR)}};
      bins rtr_rts = {{4'(RDMA_DRV_QPS_RTR), 4'(RDMA_DRV_QPS_RTS)}};
      bins rts_sqd = {{4'(RDMA_DRV_QPS_RTS), 4'(RDMA_DRV_QPS_SQD)}};
      bins sqd_rts = {{4'(RDMA_DRV_QPS_SQD), 4'(RDMA_DRV_QPS_RTS)}};
      bins rts_err = {{4'(RDMA_DRV_QPS_RTS), 4'(RDMA_DRV_QPS_ERR)}};
    }
  endgroup

  covergroup cg_fault;
    kind: coverpoint fault_kind;
    opcode: coverpoint fault_opcode {
      bins request = {RDMA_NET_SEND, RDMA_NET_RDMA_WRITE};
      bins read_resp = {RDMA_NET_RDMA_READ_RESP};
      bins ack = {RDMA_NET_ACK, RDMA_NET_ATOMIC_ACK};
    }
  endgroup

  covergroup cg_reset;
    op: coverpoint reset_op {
      bins flr = {RDMA_CTRL_FLR};
      bins recover = {RDMA_CTRL_RECOVER};
    }
    scope: coverpoint reset_scope {
      bins one = {1};
      bins two = {2};
      bins more = {[3:$]};
    }
    op_scope: cross op, scope;
  endgroup

  covergroup cg_cmq;
    opcode: coverpoint cmq_opcode {
      bins qpc = {RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY, RDMA_OP_QPC_DELETE};
      bins mr = {RDMA_OP_KEY_ALLOC, RDMA_OP_MR_REGISTER, RDMA_OP_MR_DEREGISTER};
      bins cq = {RDMA_OP_CQC_CREATE, RDMA_OP_CQC_DELETE};
      bins eq = {RDMA_OP_CEQC_CREATE, RDMA_OP_AEQC_CREATE};
      bins sd = {RDMA_OP_SD_UPDATE};
    }
  endgroup

  covergroup cg_wire;
    opcode: coverpoint pkt.opcode;
    transport: coverpoint pkt.transport {
      bins rc = {RDMA_TRANSPORT_RC};
      bins ud = {RDMA_TRANSPORT_UD};
      bins urc = {RDMA_TRANSPORT_URC};
    }
    opcode_transport: cross opcode, transport {
      ignore_bins ud_send_only = binsof(transport.ud) &&
                                 !binsof(opcode) intersect {RDMA_NET_SEND,
                                                            RDMA_NET_SEND_WITH_IMM};
    }
  endgroup

  // 功能：构造各 covergroup 与端口。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_coverage", uvm_component parent = null);
    super.new(name, parent);
    verb_export = new("verb_export", this);
    cqe_export = new("cqe_export", this);
    res_export = new("res_export", this);
    ctrl_export = new("ctrl_export", this);
    wire_export = new("wire_export", this);
    cg_verb = new();
    cg_completion = new();
    cg_error = new();
    cg_qp_state = new();
    cg_fault = new();
    cg_reset = new();
    cg_cmq = new();
    cg_wire = new();
  endfunction

  // 功能：投递的 verb（scoreboard 已填好预测状态）：采 verb 与 error。
  // 输入/输出及副作用：采样。
  // 失败/边界：无。
  function void write_cov_verb(rdma_verb_item item);
    it = item;
    qp_kind = 0;
    if (item.qp != null && item.qp.ud())
      qp_kind = 1;
    else if (item.qp != null && item.qp.urc)
      qp_kind = 2;
    cg_verb.sample();
    if (item.expect_status != RDMA_DRV_WC_SUCCESS)
      cg_error.sample();
  endfunction

  // 功能：完成。
  // 输入/输出及副作用：采样。
  // 失败/边界：无。
  function void write_cov_cqe(rdma_verb_completion c);
    done = c;
    cg_completion.sample();
  endfunction

  // 功能：QP 状态变化（驱动状态迁移）与 CMQ 执行记录。
  // 输入/输出及副作用：采样。
  // 失败/边界：远端 QP 没有驱动状态，跳过。
  function void write_cov_res(rdma_res_event e);
    rdma_res_qp qp;
    bit [3:0] prev;

    if ($cast(qp, e.res) && qp.qp != null && e.what == RDMA_RES_CHANGED) begin
      prev = last_state.exists(qp.uid) ? last_state[qp.uid] : 4'(RDMA_DRV_QPS_RESET);
      last_state[qp.uid] = 4'(qp.qp.cur_state);
      move = {prev, last_state[qp.uid]};
      if (prev != last_state[qp.uid])
        cg_qp_state.sample();
    end
    sample_cmq();
  endfunction

  // 功能：控制面请求完成：复位范围与 CMQ 执行记录。
  // 输入/输出及副作用：采样。
  // 失败/边界：无。
  function void write_cov_ctrl(rdma_ctrl_item item);
    if (item.op inside {RDMA_CTRL_FLR, RDMA_CTRL_RECOVER}) begin
      reset_op = item.op;
      reset_scope = item.scope.size();
      cg_reset.sample();
    end
    sample_cmq();
  endfunction

  // 功能：链路报文。
  // 输入/输出及副作用：采样。
  // 失败/边界：无。
  function void write_cov_wire(rdma_link_obs o);
    pkt = o.pkt;
    cg_wire.sample();
  endfunction

  // 功能：采各仿真 Function 设备 CMQ 的新执行记录（复位后记录清空，从头采）。
  // 输入/输出及副作用：采样，更新 cmq_seen。
  // 失败/边界：无。
  protected function void sample_cmq();
    rdma_dev_cmq q;

    foreach (env.sys.nodes[f]) begin
      q = env.sys.nodes[f].dev.cmq;
      if (!cmq_seen.exists(f) || cmq_seen[f] > q.executed_opcodes.size())
        cmq_seen[f] = 0;
      for (int unsigned i = cmq_seen[f]; i < q.executed_opcodes.size(); i++) begin
        cmq_opcode = q.executed_opcodes[i];
        cg_cmq.sample();
      end
      cmq_seen[f] = q.executed_opcodes.size();
    end
  endfunction

  // 功能：按已作用的链路故障规则采样；打印各覆盖面与平均覆盖率。
  // 输入/输出及副作用：报告。
  // 失败/边界：无。
  function void report_phase(uvm_phase phase);
    real parts[string];
    real total;
    string line;

    foreach (env.link.faults[i])
      if (env.link.faults[i].applied != 0) begin
        fault_kind = env.link.faults[i].kind;
        fault_opcode = env.link.faults[i].opcode;
        cg_fault.sample();
      end
    parts["verb"] = cg_verb.get_coverage();
    parts["completion"] = cg_completion.get_coverage();
    parts["error"] = cg_error.get_coverage();
    parts["qp_state"] = cg_qp_state.get_coverage();
    parts["fault"] = cg_fault.get_coverage();
    parts["reset"] = cg_reset.get_coverage();
    parts["cmq"] = cg_cmq.get_coverage();
    parts["wire"] = cg_wire.get_coverage();
    total = 0;
    line = "";
    foreach (parts[k]) begin
      total += parts[k];
      line = {line, $sformatf(" %s=%0.1f", k, parts[k])};
    end
    `uvm_info("RDMA_COV", $sformatf("total=%0.1f%s", total / parts.size(), line), UVM_LOW)
  endfunction
endclass
