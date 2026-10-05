// 目录：验证组件层 tb/rdma_verb_agent.sv。
// 层：验证组件。
// 职责：verb agent：sequencer 下发 rdma_verb_item，driver 把它翻译成驱动模型的 post_send/post_recv
//   （含源数据写入 host 内存），monitor 经驱动模型 poll_cq 轮询 CQ 并广播完成事件。
// 依赖：rdma_tb_node_cfg、rdma_drv_wr（驱动数据路径）。
// 所有权：组件只借用节点配置；WR 对象由 driver 每次新建。
// 生命周期：env.configure() 后开始工作，仿真期间常驻。

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

  // 功能：把 item 翻译为驱动 WR：SEND/WRITE 先把 data 写入本地 buffer，再构造 SGE（数据 MR
  //   lkey）、远端地址（对端数据缓冲 + remote_offset，rkey）、atomic 操作数与 UD 目的后投递。
  // 输入/输出及副作用：回填 item.node_id/wr_id；写 host 内存；调用 rdma_drv_wr。
  // 失败/边界：写内存或投递失败时报 UVM_ERROR，不广播 item，posted_ok=0。
  protected task automatic drive(rdma_verb_item item, output bit posted_ok);
    rdma_tb_qp_link link;
    rdma_tb_node_cfg peer;
    rdma_drv_sge sges[$];
    rdma_bytes_t bytes;
    rdma_status status;

    posted_ok = 1'b0;
    item.node_id = cfg.node_id;
    item.wr_id = {cfg.node_id[15:0], 48'(next_wr)};
    next_wr++;
    link = cfg.qps[item.qp_index];
    peer = nodes[link.peer_node];
    if (item.data.size() != 0) begin
      bytes = new[item.data.size()];
      foreach (item.data[i])
        bytes[i] = item.data[i];
      status = cfg.drv.hw.write(cfg.data_buf, item.local_offset, bytes);
      if (!status.ok()) begin
        `uvm_error("RDMA_DRV", {"source data write failed: ", item.convert2string()})
        return;
      end
    end
    split_sges(item, sges);
    if (item.op == RDMA_VERB_RECV)
      post_recv(item, link.qp, sges, status);
    else
      post_send(item, link, peer, sges, status);
    if (!status.ok()) begin
      `uvm_error("RDMA_DRV", $sformatf("post failed (%s): %s", status.convert2string(),
                                       item.convert2string()))
      return;
    end
    posted_ok = 1'b1;
    posted_ap.write(item);
  endtask

  // 功能：投递 RECV。
  // 输入/输出及副作用：写 RQ 并敲 RQ doorbell。
  // 失败/边界：驱动返回的错误经 status 输出。
  protected task post_recv(rdma_verb_item item, rdma_drv_qp qp, rdma_drv_sge sges[$],
                           output rdma_status status);
    rdma_drv_recv_wr wr;

    wr = rdma_drv_recv_wr::type_id::create("drv_recv");
    wr.wr_id = item.wr_id;
    wr.sges = sges;
    rdma_drv_wr::post_recv(cfg.drv, qp, wr, status);
  endtask

  // 功能：投递 SQ 请求（RC 远端地址/rkey、atomic 操作数、UD 目的 QPN/Q_Key/DMAC）。
  // 输入/输出及副作用：写 SQ/SGB 并按需敲 SQ doorbell。
  // 失败/边界：驱动返回的错误经 status 输出。
  protected task post_send(rdma_verb_item item, rdma_tb_qp_link link, rdma_tb_node_cfg peer,
                           rdma_drv_sge sges[$], output rdma_status status);
    rdma_drv_send_wr wr;

    wr = rdma_drv_send_wr::type_id::create("drv_send");
    wr.wr_id = item.wr_id;
    wr.opcode = wr_opcode(item.op);
    wr.signaled = item.signaled;
    wr.imm = item.imm;
    wr.sges = sges;
    if (!(item.op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM})) begin
      wr.remote_va = peer.data_buf.iova + item.remote_offset;
      wr.rkey = peer.data_mr.key();
    end
    wr.compare_add = item.compare_value;
    wr.swap = item.swap_add_value;
    if (item.op == RDMA_VERB_FETCH_ADD)
      wr.compare_add = item.swap_add_value;
    if (link.qp.qp_type == RDMA_DRV_QPT_UD) begin
      wr.dest_qpn = peer.qps[link.peer_qp_index].qp.qpn;
      wr.qkey = cfg.ud_qkey;
      wr.dmac = peer.mac;
    end
    rdma_drv_wr::post_send(cfg.drv, link.qp, wr, status);
  endtask

  // 功能：把本地 buffer [local_offset, +length) 均分为 sge_count 个连续 SGE（末项含余数）。
  // 输入/输出及副作用：sges 输出新建对象。
  // 失败/边界：sge_count 为 0 按 1 处理。
  protected function void split_sges(rdma_verb_item item, output rdma_drv_sge sges[$]);
    int unsigned count;
    int unsigned chunk;
    int unsigned len;

    count = item.sge_count == 0 ? 1 : item.sge_count;
    chunk = item.length / count;
    sges.delete();
    for (int unsigned k = 0; k < count; k++) begin
      len = chunk;
      if (k == count - 1)
        len = item.length - k * chunk;
      sges.push_back(rdma_drv_sge::make(cfg.data_buf.iova + item.local_offset + k * chunk, len,
                                        cfg.data_mr.key()));
    end
  endfunction

  // 功能：verb 操作映射为驱动 WR opcode。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：RECV 不经此路径。
  protected function rdma_drv_wr_opcode_e wr_opcode(rdma_verb_op_e op);
    case (op)
      RDMA_VERB_SEND_IMM:  return RDMA_DRV_WR_SEND_IMM;
      RDMA_VERB_WRITE:     return RDMA_DRV_WR_WRITE;
      RDMA_VERB_WRITE_IMM: return RDMA_DRV_WR_WRITE_IMM;
      RDMA_VERB_READ:      return RDMA_DRV_WR_READ;
      RDMA_VERB_CMP_SWAP:  return RDMA_DRV_WR_CAS;
      RDMA_VERB_FETCH_ADD: return RDMA_DRV_WR_FAA;
      default:             return RDMA_DRV_WR_SEND;
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

  // 功能：持续经驱动 poll_cq 轮询节点 CQ，把每个完成转换为 rdma_verb_completion 广播。
  // 输入/输出及副作用：消费 CQE（推进驱动的 SQ/RQ 尾与 CQ shadow CI）；永久循环。
  // 失败/边界：无完成时等待 poll_interval；轮询失败报 UVM_ERROR。
  task run_phase(uvm_phase phase);
    rdma_drv_wc wcs[$];
    rdma_verb_completion done;
    rdma_status status;

    wait (cfg != null);
    forever begin
      wcs.delete();
      rdma_drv_wr::poll_cq(cfg.drv, cfg.cq, 1, wcs, status);
      if (!status.ok())
        `uvm_error("RDMA_MON", $sformatf("node %0d CQ poll failed: %s", cfg.node_id,
                   status.convert2string()))
      if (wcs.size() == 0) begin
        #(cfg.poll_interval);
        continue;
      end
      done = rdma_verb_completion::type_id::create("completion");
      done.node_id = cfg.node_id;
      done.wr_id = wcs[0].wr_id;
      done.rq = wcs[0].is_recv;
      done.ok = wcs[0].status == RDMA_DRV_WC_SUCCESS;
      done.ecode = wcs[0].vendor_err;
      done.byte_len = wcs[0].byte_len;
      done.imm = wcs[0].imm;
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
