// 目录：验证组件层 tb/rdma_verb_agent.sv。
// 层：验证组件。
// 职责：数据面 agent（每个 Function 一个）：driver 把 rdma_verb_item 翻译成驱动模型的
//   post_send/post_recv/post_srq_recv（源数据按数据规格生成并写入源内存），monitor 模拟中断处理：
//   处理该 Function 的全部 CEQ 与 AEQ、轮询全部 CQ，广播完成与异步事件。
// 依赖：rdma_env（资源库、配置）、rdma_data_gen、rdma_drv_wr。
// 所有权：组件只借用资源对象；WR 对象由 driver 每次新建。
// 生命周期：env 就绪后开始工作，仿真期间常驻。

typedef uvm_sequencer #(rdma_verb_item) rdma_verb_sequencer;
typedef class rdma_verb_monitor;

class rdma_verb_driver extends uvm_driver #(rdma_verb_item);
  `uvm_component_utils(rdma_verb_driver)

  rdma_env env;
  int unsigned func;
  rdma_verb_monitor monitor;
  // 投递成功的 item（已回填 wr_id 与原始数据），供 scoreboard 建立期望。
  uvm_analysis_port #(rdma_verb_item) posted_ap;
  protected longint unsigned next_wr;

  // 功能：构造 verb driver，创建 posted_ap，并把首个自动分配的 WR 序号初始化为 1。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；posted_ap 由本组件拥有，env/monitor 留待后续绑定。
  // 失败/边界：允许 parent 为 null；构造阶段不验证 Function 下标，也不能在 monitor 连接前运行请求。
  function new(string name = "rdma_verb_driver", uvm_component parent = null);
    super.new(name, parent);
    posted_ap = new("posted_ap", this);
    next_wr = 1;
  endfunction

  // 功能：逐个投递；signaled 的 SQ 请求等到其完成后才 item_done（verb 同步语义），RECV 不等待。
  // 输入/输出及副作用：永久循环。
  // 失败/边界：投递失败报 UVM_ERROR；完成超时由 monitor 报告。
  task run_phase(uvm_phase phase);
    rdma_verb_item item;
    bit posted;

    env.wait_ready();
    forever begin
      seq_item_port.get_next_item(item);
      drive(item, posted);
      if (posted && item.signaled && item.op != RDMA_VERB_RECV)
        monitor.wait_completion(item.wr_id, 4 * env.cfg.response_timeout);
      seq_item_port.item_done();
    end
  endtask

  // 功能：回填 wr_id；SEND/WRITE 生成原始数据（未给出时）并写入本地 buffer；构造 SGE 后投递。
  // 输入/输出及副作用：写源内存；调用驱动；成功后广播 item。
  // 失败/边界：写内存或投递失败报 UVM_ERROR，posted=0。
  protected task drive(rdma_verb_item item, output bit posted);
    rdma_drv_sge sges[$];
    rdma_bytes_t bytes;
    rdma_status status;

    posted = 1'b0;
    item.wr_id = {func[15:0], 48'(next_wr++)};
    if (item.has_data() && item.data.size() == 0)
      rdma_data_gen::make(item.data_mode, item.data_fixed, item.data_pattern, item.length,
                          item.data);
    if (item.data.size() != 0) begin
      bytes = new[item.data.size()];
      foreach (item.data[i])
        bytes[i] = item.data[i];
      status = item.lmr.mem.write(buf_offset(item.lmr, item.local_offset), bytes);
      if (!status.ok()) begin
        `uvm_error("RDMA_VERB", {"source write failed: ", item.convert2string()})
        return;
      end
    end
    split_sges(item, sges);
    if (item.op == RDMA_VERB_RECV)
      post_recv(item, sges, status);
    else
      post_send(item, sges, status);
    if (!status.ok()) begin
      `uvm_error("RDMA_VERB", $sformatf("post failed (%s): %s", status.convert2string(),
                                        item.convert2string()))
      return;
    end
    posted = 1'b1;
    posted_ap.write(item);
  endtask

  // 功能：把 MR 内偏移 off 换算为底层内存对象中的偏移，即 mr.va - mr.mem.iova + off。
  // 输入/输出及副作用：只读取 mr、mr.mem 与 off 并返回 int unsigned 偏移，不修改 MR 或内存对象。
  // 失败/边界：要求 mr/mr.mem 非空且换算结果可由 int unsigned 表示；本函数不做范围或下溢检查。
  static function int unsigned buf_offset(rdma_res_mr mr, int unsigned off);
    return mr.va - mr.mem.iova + off;
  endfunction

  // 功能：投递 RECV（srq 非空时投到 SRQ）。
  // 输入/输出及副作用：写 RQ/SRQ 并敲 doorbell。
  // 失败/边界：驱动错误经 status 输出。
  protected virtual task post_recv(rdma_verb_item item, rdma_drv_sge sges[$],
                                   output rdma_status status);
    rdma_drv_recv_wr wr;

    wr = rdma_drv_recv_wr::type_id::create("recv_wr");
    wr.wr_id = item.wr_id;
    wr.sges = sges;
    if (item.srq != null)
      rdma_drv_wr::post_srq_recv(env.res.funcs[func].drv(), item.srq.srq, wr, status);
    else
      rdma_drv_wr::post_recv(env.res.funcs[func].drv(), item.qp.qp, wr, status);
  endtask

  // 功能：投递 SQ 请求：远端地址/rkey（非 SEND）、atomic 操作数、UD 目的（对端 QPN、Q_Key、MAC）。
  // 输入/输出及副作用：写 SQ/SGB 并按需敲 doorbell。
  // 失败/边界：驱动错误经 status 输出。
  protected virtual task post_send(rdma_verb_item item, rdma_drv_sge sges[$],
                                   output rdma_status status);
    rdma_drv_send_wr wr;

    wr = rdma_drv_send_wr::type_id::create("send_wr");
    wr.wr_id = item.wr_id;
    wr.opcode = wr_opcode(item.op);
    wr.signaled = item.signaled;
    wr.imm = item.imm;
    wr.sges = sges;
    if (item.rmr != null) begin
      wr.remote_va = item.rmr.va + item.remote_offset;
      wr.rkey = item.rmr.key;
    end
    wr.compare_add = item.op == RDMA_VERB_FETCH_ADD ? item.swap_add_value : item.compare_value;
    wr.swap = item.swap_add_value;
    if (item.qp.ud()) begin
      wr.dest_qpn = item.qp.peer.id;
      wr.qkey = item.ud_qkey != 0 ? item.ud_qkey : item.qp.peer.qkey;
      wr.dmac = item.qp.peer.owner.mac;
    end
    rdma_drv_wr::post_send(env.res.funcs[func].drv(), item.qp.qp, wr, status);
  endtask

  // 功能：本地 buffer [local_offset, +length) 均分为 sge_count 个连续 SGE（末项含余数，lkey 取 lmr）。
  // 输入/输出及副作用：sges 输出。
  // 失败/边界：sge_count 为 0 按 1。
  protected function void split_sges(rdma_verb_item item, output rdma_drv_sge sges[$]);
    int unsigned count;
    int unsigned chunk;

    count = item.sge_count == 0 ? 1 : item.sge_count;
    chunk = item.length / count;
    sges.delete();
    for (int unsigned k = 0; k < count; k++)
      sges.push_back(rdma_drv_sge::make(item.lmr.va + item.local_offset + k * chunk,
                                        k == count - 1 ? item.length - k * chunk : chunk,
                                        item.lmr.key));
  endfunction

  // 功能：verb → 驱动 WR opcode。
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

  rdma_env env;
  int unsigned func;
  uvm_analysis_port #(rdma_verb_completion) cqe_ap;
  uvm_analysis_port #(rdma_aeq_event) aeq_ap;
  // 已观测的完成（按 wr_id），供 driver 同步等待。
  protected bit seen[longint unsigned];
  protected event seen_event;

  // 功能：构造 verb monitor 及 CQE/AEQ analysis 端口，完成记录 seen 初始为空。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；cqe_ap 与 aeq_ap 由本组件拥有，env 留待绑定。
  // 失败/边界：允许 parent 为 null；构造阶段不选择 Function，run_phase 前必须由 agent 完成绑定。
  function new(string name = "rdma_verb_monitor", uvm_component parent = null);
    super.new(name, parent);
    cqe_ap = new("cqe_ap", this);
    aeq_ap = new("aeq_ap", this);
  endfunction

  // 功能：中断处理循环：全部 CEQ → AEQ（控制面命令进行中或 FLR 后未恢复时跳过，驱动内部等待自己取
  //   AEQ）→
  //   全部 CQ 各取至多 16 个 WC；无事可做时等待 poll_interval。
  // 输入/输出及副作用：推进驱动 EQ/CQ 软件状态；永久循环。
  // 失败/边界：处理失败报 UVM_ERROR。
  task run_phase(uvm_phase phase);
    rdma_res_func f;
    rdma_res_eq ceqs[$];
    rdma_res_cq cqs[$];
    rdma_drv_wc wcs[$];
    int unsigned cqns[$];
    bit [31:0] events[$];
    rdma_status status;

    env.wait_ready();
    f = env.res.funcs[func];
    forever begin
      wcs.delete();
      events.delete();
      f.ceqs.all(ceqs);
      foreach (ceqs[i]) begin
        rdma_drv_wr::process_ceq(f.drv(), ceqs[i].eq, cqns, status);
        report_fail(status, "CEQ");
      end
      cqns.delete();
      if (!env.ctrl_busy && f.aeq != null && f.aeq.state != RDMA_RES_DESTROYED) begin
        rdma_drv_wr::process_aeq(f.drv(), events, status);
        report_fail(status, "AEQ");
      end
      f.cqs.all(cqs);
      foreach (cqs[i]) begin
        rdma_drv_wr::poll_cq(f.drv(), cqs[i].cq, 16, wcs, status);
        report_fail(status, "CQ poll");
      end
      foreach (events[i])
        publish_aeq(events[i]);
      foreach (wcs[i])
        publish(wcs[i]);
      if (wcs.size() == 0 && events.size() == 0)
        #(env.cfg.poll_interval);
    end
  endtask

  // 功能：检查一次驱动操作状态，并在失败时用操作名 what 和 Function 号形成 UVM_ERROR。
  // 输入/输出及副作用：只读取 status/what/func；失败时增加 UVM 错误计数，成功时不产生输出。
  // 失败/边界：status.ok() 为真时是显式 no-op；本函数只报告错误，不终止 monitor 或传播状态。
  protected function void report_fail(rdma_status status, string what);
    if (!status.ok())
      `uvm_error("RDMA_MON", $sformatf("f%0d %s failed: %s", func, what, status.convert2string()))
  endfunction

  // 功能：把驱动 WC 转换为 rdma_verb_completion，记录 wr_id 已完成并经 cqe_ap 广播。
  // 输入/输出及副作用：复制 wc 字段与 func，更新 seen，触发 seen_event；新完成对象归订阅方按 UVM 语义使用。
  // 失败/边界：要求 wc 非空且端口已构造；重复 wr_id 仍会再次触发事件和广播，seen 只保持已出现标记。
  function void publish(rdma_drv_wc wc);
    rdma_verb_completion c;

    c = rdma_verb_completion::type_id::create("completion");
    c.func = func;
    c.wr_id = wc.wr_id;
    c.qpn = wc.qpn;
    c.src_qp = wc.src_qp;
    c.rq = wc.is_recv;
    c.status = wc.status;
    c.vendor = wc.vendor_err;
    c.byte_len = wc.byte_len;
    c.imm = wc.imm;
    seen[c.wr_id] = 1'b1;
    ->seen_event;
    cqe_ap.write(c);
  endfunction

  // 功能：把原始 {ecode[31:24], id[23:0]} 解码成带 Function 号的 rdma_aeq_event 并广播。
  // 输入/输出及副作用：读取 raw/func，输出一条 UVM_HIGH 日志并写 aeq_ap；事件对象经 factory 新建。
  // 失败/边界：接受任意 32 bit 编码且不验证 ecode/id；要求 factory 对象和 analysis 端口有效。
  protected function void publish_aeq(bit [31:0] raw);
    rdma_aeq_event e;

    e = rdma_aeq_event::type_id::create("aeq_event");
    e.func = func;
    e.ecode = raw[31:24];
    e.id = raw[23:0];
    `uvm_info("RDMA_MON", $sformatf("f%0d AEQ ecode=%02h id=%0d", func, e.ecode, e.id), UVM_HIGH)
    aeq_ap.write(e);
  endfunction

  // 功能：等待 wr_id 的完成出现。
  // 输入/输出及副作用：阻塞至多 timeout。
  // 失败/边界：超时报 UVM_ERROR。
  task wait_completion(longint unsigned wr_id, time timeout);
    time deadline;

    deadline = $time + timeout;
    while (!seen.exists(wr_id) && $time < deadline)
      fork
        begin
          fork
            @(seen_event);
            #(deadline - $time);
          join_any
          disable fork;
        end
      join
    if (!seen.exists(wr_id))
      `uvm_error("RDMA_MON", $sformatf("f%0d wr_id %0h completion timeout", func, wr_id))
  endtask
endclass

class rdma_verb_agent extends uvm_agent;
  `uvm_component_utils(rdma_verb_agent)

  rdma_verb_sequencer sequencer;
  rdma_verb_driver driver;
  rdma_verb_monitor monitor;

  // 功能：构造 verb agent 外壳，子 sequencer、driver 与 monitor 留到 build_phase 创建。
  // 输入/输出及副作用：name/parent 仅建立 UVM 组件层级；构造后三个子组件句柄仍为 null。
  // 失败/边界：允许 parent 为 null；在 build_phase 完成前不得连接或绑定子组件。
  function new(string name = "rdma_verb_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：执行父类 build 后，经 UVM factory 创建本 agent 唯一的 sequencer、driver 与 monitor。
  // 输入/输出及副作用：phase 由 UVM 调度；三个子组件以 this 为 parent，并写入对应成员句柄。
  // 失败/边界：依赖 UVM build_phase 只执行一次；factory 创建失败或同名重复由 UVM 机制报告。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sequencer = rdma_verb_sequencer::type_id::create("sequencer", this);
    driver = rdma_verb_driver::type_id::create("driver", this);
    monitor = rdma_verb_monitor::type_id::create("monitor", this);
  endfunction

  // 功能：连接 driver 的 seq_item_port 与 sequencer export，并把 monitor 句柄交给 driver 等待完成。
  // 输入/输出及副作用：phase 由 UVM 调度；建立持久 TLM 连接并设置 driver.monitor 非拥有引用。
  // 失败/边界：要求 build_phase 已成功创建三个子组件；重复连接或空句柄错误由 UVM 报告。
  function void connect_phase(uvm_phase phase);
    driver.seq_item_port.connect(sequencer.seq_item_export);
    driver.monitor = monitor;
  endfunction

  // 功能：把同一 env 非拥有引用和 Function 下标同时绑定给 driver 与 monitor，限定该 agent 的作用域。
  // 输入/输出及副作用：读取 env/func 并覆盖两个子组件的配置字段，不改变 env 资源或 Function 生命周期。
  // 失败/边界：要求 build_phase 已完成、env 非空且 func 对应 env.res.funcs 的有效项；本函数不自行校验范围。
  function void bind_func(rdma_env env, int unsigned func);
    driver.env = env;
    driver.func = func;
    monitor.env = env;
    monitor.func = func;
  endfunction
endclass
