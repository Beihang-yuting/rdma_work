// 目录：验证组件层 tb/rdma_verb_agent.sv。
// 职责：verb agent：sequencer 下发 rdma_verb_item，driver 把它翻译成 queue-data engine 的
//   post_send/post_recv（含源数据写入 host 内存），monitor 轮询 CQ 并广播完成事件。
// 依赖：rdma_tb_node_cfg、queue_data_engine 公开接口与语义请求模型。
// 所有权与生命周期：组件只借用节点配置；请求对象由 driver 每次新建并交给 engine。

typedef uvm_sequencer #(rdma_verb_item) rdma_verb_sequencer;

class rdma_verb_driver extends uvm_driver #(rdma_verb_item);
  `uvm_component_utils(rdma_verb_driver)

  rdma_tb_node_cfg cfg;
  rdma_tb_node_cfg nodes[int unsigned];
  // 本节点 monitor：signaled 的 SQ 请求在其完成到达后才 item_done（verb 语义同步化）。
  rdma_verb_monitor monitor;
  // 投递成功的 item（已回填 node_id/wr_id），供记分板建立期望。
  uvm_analysis_port #(rdma_verb_item) posted_ap;
  protected longint unsigned next_wr;

  // 功能：构造 driver 与 analysis 端口。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_verb_driver", uvm_component parent = null);
    super.new(name, parent);
    posted_ap = new("posted_ap", this);
    next_wr = 1;
  endfunction

  // 功能：逐个取 item 并投递；signaled 的 SQ 请求等待其完成后再 item_done。
  // 输入/输出及副作用：永久循环。
  // 失败/边界：投递失败报 UVM_ERROR，item 仍 item_done；完成超时报 UVM_ERROR。
  task run_phase(uvm_phase phase);
    rdma_verb_item item;
    bit posted_ok;

    forever begin
      seq_item_port.get_next_item(item);
      drive(item, posted_ok);
      if (posted_ok && item.signaled && item.op != RDMA_VERB_RECV)
        monitor.wait_completion(item.wr_id, 4 * cfg.response_timeout);
      seq_item_port.item_done();
    end
  endtask

  // 功能：把 item 翻译为 engine 请求：SEND/WRITE 先把 data 写入本地 buffer，再构造 SGE（数据 MR
  //   lkey）、远端地址（对端数据 MR + remote_offset，rkey）与 atomic 操作数后投递。
  // 输入/输出及副作用：回填 item.node_id/wr_id；写 host 内存；调用 engine.post_send/post_recv。
  // 失败/边界：写内存或投递失败时报 UVM_ERROR，不广播 item，posted_ok=0。
  protected task automatic drive(rdma_verb_item item, output bit posted_ok);
    rdma_qp qp;
    rdma_tb_node_cfg peer;
    rdma_sge sges[$];
    rdma_queue_post_result posted;
    bit [23:0] peer_qpn;
    rdma_status status;
    byte raw[];
    longint unsigned va;

    posted_ok = 1'b0;
    item.node_id = cfg.node_id;
    item.wr_id = {cfg.node_id[15:0], 48'(next_wr)};
    next_wr++;
    qp = cfg.qps[item.qp_index].qp;
    peer = nodes[cfg.qps[item.qp_index].peer_node];
    va = cfg.data_mr.iova.value + item.local_offset;
    if (item.data.size() != 0) begin
      raw = new[item.data.size()];
      foreach (item.data[i])
        raw[i] = item.data[i];
      status = cfg.engine.host_mem.write(cfg.data_mapping,
                                         va - cfg.data_mapping.iova.value, raw);
      if (status == null || !status.ok()) begin
        `uvm_error("RDMA_DRV", {"source data write failed: ", item.convert2string()})
        return;
      end
    end
    split_sges(item, va, sges);
    if (item.op == RDMA_VERB_RECV) begin
      rdma_post_recv_req req;

      req = rdma_post_recv_req::type_id::create("drv_recv");
      req.owner = cfg.owner();
      req.target_h = rdma_clone_handle_value(qp.handle, "driver RECV QP");
      req.wr_id = item.wr_id;
      req.sges = sges;
      cfg.engine.post_recv(req, posted, status);
    end
    else begin
      rdma_post_send_req req;

      req = rdma_post_send_req::type_id::create("drv_send");
      req.owner = cfg.owner();
      req.qp_h = rdma_clone_handle_value(qp.handle, "driver SEND QP");
      req.wr_id = item.wr_id;
      req.transport = qp.transport;
      req.opcode = work_opcode(item.op);
      req.signaled = item.signaled;
      req.immediate_data = item.imm;
      if (!(item.op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM})) begin
        req.remote_addr.value = peer.data_mr.iova.value + item.remote_offset;
        req.rkey = peer.data_mr.rkey;
        req.remote_access_valid = 1'b1;
        req.rkey_valid = 1'b1;
      end
      req.compare_value = item.compare_value;
      req.swap_add_value = item.swap_add_value;
      req.sges = sges;
      peer_qpn = peer.qps[cfg.qps[item.qp_index].peer_qp_index].qp.local_qp_id;
      if (qp.transport == RDMA_TRANSPORT_UD) begin
        req.destination_qpn = peer_qpn;
        req.qkey = cfg.ud_qkey;
        req.address_vector_valid = 1'b1;
        req.address_vector_id = item.qp_index;
        req.address_vector = rdma_address_vector::type_id::create("drv_av");
      end
      if (qp.transport == RDMA_TRANSPORT_URC) begin
        req.destination_qpn = peer_qpn;
        req.completion_qp_h = rdma_clone_handle_value(qp.handle, "driver URC completion QP");
      end
      // UD 非零 payload 与超过 2 个 SGE 的请求使用 SQ 外部 SGB：槽位为当前 SQ PI × 512B。
      if ((qp.transport == RDMA_TRANSPORT_UD && item.length != 0) || sges.size() > 2)
        req.sgb_iova.value = sgb_slot(qp);
      cfg.engine.post_send(req, posted, status);
    end
    if (status == null || !status.ok()) begin
      `uvm_error("RDMA_DRV", $sformatf("post failed (%s): %s",
                 status == null ? "null" : status.convert2string(), item.convert2string()))
      return;
    end
    posted_ok = 1'b1;
    posted_ap.write(item);
  endtask

  // 功能：把 [va, va+length) 均分为 sge_count 个连续 SGE（末项含余数），lkey 取数据 MR。
  // 输入/输出及副作用：sges 输出新建对象。
  // 失败/边界：sge_count 为 0 按 1 处理。
  protected function void split_sges(rdma_verb_item item, longint unsigned va,
                                     output rdma_sge sges[$]);
    rdma_sge sge;
    int unsigned count;
    int unsigned chunk;

    count = item.sge_count == 0 ? 1 : item.sge_count;
    chunk = item.length / count;
    sges.delete();
    for (int unsigned k = 0; k < count; k++) begin
      sge = rdma_sge::type_id::create("drv_sge");
      sge.iova.value = va + k * chunk;
      sge.length = (k == count - 1) ? item.length - k * chunk : chunk;
      sge.lkey = cfg.data_mr.lkey;
      sges.push_back(sge);
    end
  endfunction

  // 功能：当前 SQ PI 对应的 SQ SGB 512B 槽 IOVA（engine 要求 sgb_iova 与 PI 槽一致）。
  // 输入/输出及副作用：只读 runtime 游标与 qp_plan。
  // 失败/边界：游标查询失败或无 SGB backing 返回 0，由 engine 拒绝投递。
  protected function longint unsigned sgb_slot(rdma_qp qp);
    rdma_status status;
    int unsigned pi;
    int unsigned ci;
    bit pw;
    bit cw;

    if (qp.qp_plan == null || qp.qp_plan.sq_sgb_ref == null ||
        qp.qp_plan.sq_sgb_ref.mapping == null)
      return 0;
    status = cfg.engine.query_runtime_cursors(qp.handle, RDMA_QUEUE_RUNTIME_SQ, pi, pw, ci, cw);
    if (status == null || !status.ok())
      return 0;
    return qp.qp_plan.sq_sgb_ref.mapping.iova.value + qp.qp_plan.sq_sgb_ref.mapping_offset +
           longint'(pi) * 512;
  endfunction

  // 功能：verb 操作映射为 WQE opcode。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：RECV 不经此路径。
  protected function rdma_work_opcode_e work_opcode(rdma_verb_op_e op);
    case (op)
      RDMA_VERB_SEND_IMM:  return RDMA_WR_SEND_WITH_IMM;
      RDMA_VERB_WRITE:     return RDMA_WR_RDMA_WRITE;
      RDMA_VERB_WRITE_IMM: return RDMA_WR_WRITE_WITH_IMM;
      RDMA_VERB_READ:      return RDMA_WR_RDMA_READ;
      RDMA_VERB_CMP_SWAP:  return RDMA_WR_ATOMIC_CMP_SWAP;
      RDMA_VERB_FETCH_ADD: return RDMA_WR_ATOMIC_FETCH_ADD;
      default:             return RDMA_WR_SEND;
    endcase
  endfunction
endclass

class rdma_verb_monitor extends uvm_monitor;
  `uvm_component_utils(rdma_verb_monitor)

  rdma_tb_node_cfg cfg;
  uvm_analysis_port #(rdma_verb_completion) cqe_ap;
  // 已观测的完成（按 wr_id），供 driver 同步等待。
  protected rdma_verb_completion seen[longint unsigned];
  protected event seen_event;

  // 功能：构造 monitor 与 analysis 端口。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_verb_monitor", uvm_component parent = null);
    super.new(name, parent);
    cqe_ap = new("cqe_ap", this);
  endfunction

  // 功能：持续轮询节点 CQ，把每个完成转换为 rdma_verb_completion 广播。
  // 输入/输出及副作用：消费 CQE（会释放对应 WQE 槽位）；永久循环。
  // 失败/边界：QUEUE_EMPTY 时等待 poll_interval；其它失败报 UVM_ERROR。
  task run_phase(uvm_phase phase);
    rdma_queue_completion_result result;
    rdma_verb_completion done;
    rdma_status status;

    wait (cfg != null);
    forever begin
      cfg.cq_lock.get(1);
      cfg.engine.poll_cqe(cfg.cq.handle, 0, result, status);
      cfg.cq_lock.put(1);
      if (status != null && status.code == RDMA_SC_QUEUE_EMPTY) begin
        #(cfg.poll_interval);
        continue;
      end
      if (status == null || !status.ok() || result == null || result.cqe == null) begin
        `uvm_error("RDMA_MON", $sformatf("node %0d CQ poll failed: %s", cfg.node_id,
                   status == null ? "null" : status.convert2string()))
        #(cfg.poll_interval);
        continue;
      end
      done = rdma_verb_completion::type_id::create("completion");
      done.node_id = cfg.node_id;
      done.wr_id = result.cqe.wr_id;
      done.rq = result.cqe.rq_cqe;
      done.ok = result.completion_status != null && result.completion_status.ok();
      done.ecode = result.cqe.ecode;
      done.byte_len = result.cqe.payload_len;
      done.imm = result.cqe.immediate_data;
      seen[done.wr_id] = done;
      ->seen_event;
      cqe_ap.write(done);
    end
  endtask

  // 功能：等待指定 wr_id 的完成出现。
  // 输入/输出及副作用：阻塞至多 timeout。
  // 失败/边界：超时报 UVM_ERROR 后返回。
  task wait_completion(longint unsigned wr_id, time timeout);
    time deadline;

    deadline = $time + timeout;
    while (!seen.exists(wr_id)) begin
      fork
        begin
          fork
            @(seen_event);
            #(deadline - $time);
          join_any
          disable fork;
        end
      join
      if ($time >= deadline && !seen.exists(wr_id)) begin
        `uvm_error("RDMA_MON", $sformatf("node %0d wr_id %0h completion timeout",
                   cfg.node_id, wr_id))
        return;
      end
    end
  endtask
endclass

class rdma_verb_agent extends uvm_agent;
  `uvm_component_utils(rdma_verb_agent)

  rdma_tb_node_cfg cfg;
  rdma_verb_sequencer sequencer;
  rdma_verb_driver driver;
  rdma_verb_monitor monitor;

  // 功能：构造 agent。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_verb_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建 sequencer/driver/monitor。
  // 输入/输出及副作用：创建子组件。
  // 失败/边界：无。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sequencer = rdma_verb_sequencer::type_id::create("sequencer", this);
    driver = rdma_verb_driver::type_id::create("driver", this);
    monitor = rdma_verb_monitor::type_id::create("monitor", this);
  endfunction

  // 功能：连接 driver 与 sequencer。
  // 输入/输出及副作用：建立 TLM 连接。
  // 失败/边界：无。
  function void connect_phase(uvm_phase phase);
    driver.seq_item_port.connect(sequencer.seq_item_export);
    driver.monitor = monitor;
  endfunction

  // 功能：把节点配置下发给 driver/monitor。
  // 输入/输出及副作用：设置子组件 cfg/nodes。
  // 失败/边界：无。
  function void configure(rdma_tb_node_cfg node, rdma_tb_node_cfg all[int unsigned]);
    cfg = node;
    driver.cfg = node;
    driver.nodes = all;
    monitor.cfg = node;
  endfunction
endclass
