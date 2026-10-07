// 目录：验证组件层 tb/rdma_ctrl_agent.sv。
// 层：验证组件。
// 职责：控制面 agent：sequencer 下发 rdma_ctrl_item，driver 调用驱动模型完成资源生命周期（PD/BUF/MR/
//   CQ/SRQ/QP 创建与销毁）、QP 连接与状态迁移、FLR 与恢复，并把结果写入资源库（资源库是唯一的控制面
//   事件源，其 analysis 端口即本 agent 的 monitor 输出）。所有 Function 共用一个控制面 agent。
// 依赖：rdma_env（资源库、dpu 系统、配置）、rdma_drv_*。
// 所有权：driver 是资源库的唯一写入者。
// 生命周期：env 就绪后开始工作，仿真期间常驻。

typedef uvm_sequencer #(rdma_ctrl_item) rdma_ctrl_sequencer;

class rdma_ctrl_driver extends uvm_driver #(rdma_ctrl_item);
  `uvm_component_utils(rdma_ctrl_driver)

  rdma_env env;
  // 执行完成的请求（覆盖率用；资源变化另经资源库广播）。
  uvm_analysis_port #(rdma_ctrl_item) ap;

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_ctrl_driver", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  // 功能：等待 env 就绪后逐个执行 item；结果与 expect_fail 不符时报 UVM_ERROR。
  // 输入/输出及副作用：永久循环。
  // 失败/边界：见各操作。
  task run_phase(uvm_phase phase);
    rdma_ctrl_item item;

    env.wait_ready();
    forever begin
      seq_item_port.get_next_item(item);
      item.status = rdma_status::success();
      env.ctrl_busy = 1'b1;
      execute(item);
      env.ctrl_busy = 1'b0;
      ap.write(item);
      if (item.status.ok() == item.expect_fail)
        `uvm_error("RDMA_CTRL", $sformatf("%s: expect_fail=%0b got %s", item.convert2string(),
                   item.expect_fail, item.status.convert2string()))
      seq_item_port.item_done();
    end
  endtask

  // 功能：按 op 分派。
  // 输入/输出及副作用：调用驱动并更新资源库；item.res/status 输出。
  // 失败/边界：驱动失败经 item.status 返回，不登记资源。
  protected virtual task execute(rdma_ctrl_item item);
    rdma_res_func f;

    f = env.res.funcs[item.func];
    case (item.op)
      RDMA_CTRL_ALLOC_PD:   alloc_pd(f, item);
      RDMA_CTRL_ALLOC_BUF:  alloc_buf(f, item);
      RDMA_CTRL_REG_MR:     reg_mr(f, item);
      RDMA_CTRL_CREATE_CQ:  create_cq(f, item);
      RDMA_CTRL_CREATE_SRQ: create_srq(f, item);
      RDMA_CTRL_CREATE_QP:  create_qp(f, item);
      RDMA_CTRL_CONNECT:    connect_pair(item);
      RDMA_CTRL_MODIFY_QP:  modify(item.qp, item.state, item.peer, item.status);
      RDMA_CTRL_DESTROY:    destroy(item);
      RDMA_CTRL_FLR: begin
        env.sys.flr(item.scope);
        env.res.on_flr(item.scope);
      end
      default: begin
        env.res.on_flr(item.scope);
        env.sys.recover(item.scope, item.status);
        foreach (item.scope[i])
          if (item.status.ok())
            env.register_device(env.res.funcs[item.scope[i]]);
      end
    endcase
  endtask

  // 功能：登记新资源（status 成功时）：owner、编号、依赖。
  // 输入/输出及副作用：写资源库与 item.res。
  // 失败/边界：status 失败时不登记。
  protected function void register(rdma_ctrl_item item, rdma_res_func f, rdma_res r,
                                   int unsigned id, rdma_res deps[$]);
    if (!item.status.ok())
      return;
    r.owner = f;
    r.id = id;
    r.deps = deps;
    env.res.add(r);
    item.res = r;
  endfunction

  // 功能：分配 PD。
  // 输入/输出及副作用：见 register；编号为 PD 号。
  // 失败/边界：驱动失败经 item.status 返回。
  protected task alloc_pd(rdma_res_func f, rdma_ctrl_item item);
    rdma_res_pd r;

    r = rdma_res_pd::type_id::create("pd");
    item.status = rdma_drv_pd::alloc(f.drv(), r.pd);
    if (item.status.ok())
      register(item, f, r, r.pd.pd_id, {});
  endtask

  // 功能：分配 item.size 字节、4KiB 对齐的 DMA 缓冲（编号取页号）。
  // 输入/输出及副作用：见 register。
  // 失败/边界：驱动失败经 item.status 返回。
  protected task alloc_buf(rdma_res_func f, rdma_ctrl_item item);
    rdma_res_buf r;

    r = rdma_res_buf::type_id::create("buf");
    item.status = f.node.hw.alloc_dma(item.size, 4096, r.dma);
    if (!item.status.ok())
      return;
    r.iova = r.dma.iova;
    r.size = r.dma.size;
    register(item, f, r, r.iova >> 12, {});
  endtask

  // 功能：在 mem 的 [offset, offset+len) 上注册 MR（VA = IOVA），页表按 4KiB 列出。
  // 输入/输出及副作用：见 register；编号为 key。
  // 失败/边界：驱动失败经 item.status 返回。
  protected task reg_mr(rdma_res_func f, rdma_ctrl_item item);
    rdma_res_mr r;
    bit [63:0] pages[$];

    r = rdma_res_mr::type_id::create("mr");
    r.mem = item.mem;
    r.va = item.mem.iova + item.offset;
    r.len = item.len != 0 ? item.len : item.mem.size - item.offset;
    r.rights = item.rights;
    for (bit [63:0] a = r.va & ~64'hfff; a < r.va + r.len; a += 4096)
      pages.push_back(a);
    rdma_drv_mr::reg_mr(f.drv(), item.pd.pd, r.va, r.len, r.rights, pages, r.mr, item.status);
    if (!item.status.ok())
      return;
    r.key = r.mr.key();
    register(item, f, r, r.key, {item.pd, item.mem});
  endtask

  // 功能：创建 item.size 深度的 CQ（完成向量 0，依赖其 CEQ）。
  // 输入/输出及副作用：见 register；编号为 CQN。
  // 失败/边界：驱动失败经 item.status 返回。
  protected task create_cq(rdma_res_func f, rdma_ctrl_item item);
    rdma_res_cq r;

    r = rdma_res_cq::type_id::create("cq");
    rdma_drv_cq::create_cq(f.drv(), item.size, 0, r.cq, item.status);
    if (!item.status.ok())
      return;
    r.depth = item.size;
    register(item, f, r, r.cq.cqn, {f.ceqs.get(r.cq.ceqn)});
  endtask

  // 功能：创建 item.size 深度的 SRQ（limit 0）。
  // 输入/输出及副作用：见 register；编号为 SRQN。
  // 失败/边界：驱动失败经 item.status 返回。
  protected task create_srq(rdma_res_func f, rdma_ctrl_item item);
    rdma_res_srq r;

    r = rdma_res_srq::type_id::create("srq");
    rdma_drv_srq::create_srq(f.drv(), item.pd.pd, item.size, 0, r.srq, item.status);
    if (item.status.ok())
      register(item, f, r, r.srq.srqn, {item.pd});
  endtask

  // 功能：创建 QP（urc 时以 rc_to_urc 创建 RC QP）；Q_Key、MTU 取配置。
  // 输入/输出及副作用：见 register；编号为 QPN。
  // 失败/边界：驱动失败经 item.status 返回。
  protected task create_qp(rdma_res_func f, rdma_ctrl_item item);
    rdma_drv_qp_init_attr attr;
    rdma_res_qp r;
    rdma_res deps[$];

    attr = rdma_drv_qp_init_attr::type_id::create("qp_attr");
    attr.qp_type = item.qp_type;
    attr.pd = item.pd.pd;
    attr.send_cq = item.send_cq.cq;
    attr.recv_cq = item.recv_cq.cq;
    attr.srq = item.srq == null ? null : item.srq.srq;
    attr.max_send_sge = item.max_sge;
    attr.max_recv_sge = item.max_sge;
    attr.max_send_wr = item.size;
    attr.max_recv_wr = item.size;
    r = rdma_res_qp::type_id::create("qp");
    f.drv().cfg.rc_to_urc = item.urc;
    rdma_drv_qp::create_qp(f.drv(), attr, r.qp, item.status);
    f.drv().cfg.rc_to_urc = 1'b0;
    if (!item.status.ok())
      return;
    r.qp_type = item.qp_type;
    r.urc = item.urc;
    r.send_cq = item.send_cq;
    r.recv_cq = item.recv_cq;
    r.srq = item.srq;
    r.qkey = env.cfg.ud_qkey;
    r.mtu = env.cfg.mtu;
    deps = {item.pd, item.send_cq, item.recv_cq};
    if (item.srq != null)
      deps.push_back(item.srq);
    register(item, f, r, r.qp.qpn, deps);
  endtask

  // 功能：qp ↔ peer 互为对端，双方依次 INIT → RTR → RTS。
  // 输入/输出及副作用：修改两个 QP 与资源库。
  // 失败/边界：任一步失败即返回其 status。
  protected task connect_pair(rdma_ctrl_item item);
    rdma_drv_qp_state_e steps[3] = '{RDMA_DRV_QPS_INIT, RDMA_DRV_QPS_RTR, RDMA_DRV_QPS_RTS};

    item.qp.peer = item.peer;
    item.peer.peer = item.qp;
    foreach (steps[s]) begin
      modify(item.qp, steps[s], item.peer, item.status);
      if (item.status.ok())
        modify(item.peer, steps[s], item.qp, item.status);
      if (!item.status.ok())
        return;
    end
  endtask

  // 功能：把 qp 迁到 state，属性按迁移取配置默认值：→INIT（UD Q_Key / RC 远端权限）、INIT→RTR（RC：
  //   对端 QPN、RQ PSN 0、MTU、目的 MAC、min_rnr）、RTR→RTS（SQ PSN 0、timeout、重试次数）；其它迁移
  //   （SQD、ERR、RESET、SQD→RTS 等）只给状态。
  // 输入/输出及副作用：驱动 modify；广播 CHANGED（ERR 时资源状态置 ERROR）。
  // 失败/边界：驱动失败经 status 返回。
  protected virtual task modify(rdma_res_qp qp, rdma_drv_qp_state_e state, rdma_res_qp peer,
                                output rdma_status status);
    rdma_drv_qp_attr attr;

    attr = rdma_drv_qp_attr::type_id::create("qp_modify");
    attr.mask = rdma_drv_qp_attr::M_STATE;
    attr.state = state;
    if (state == RDMA_DRV_QPS_INIT && qp.ud()) begin
      attr.mask |= rdma_drv_qp_attr::M_QKEY;
      attr.qkey = qp.qkey;
    end
    else if (state == RDMA_DRV_QPS_INIT) begin
      attr.mask |= rdma_drv_qp_attr::M_ACCESS;
      attr.access = RDMA_RIGHT_REMOTE_READ | RDMA_RIGHT_REMOTE_WRITE | RDMA_RIGHT_REMOTE_ATOMIC;
    end
    else if (state == RDMA_DRV_QPS_RTR && !qp.ud() && qp.qp.cur_state == RDMA_DRV_QPS_INIT) begin
      attr.mask |= rdma_drv_qp_attr::M_DEST_QPN | rdma_drv_qp_attr::M_RQ_PSN |
                   rdma_drv_qp_attr::M_PATH_MTU | rdma_drv_qp_attr::M_AV |
                   rdma_drv_qp_attr::M_MIN_RNR;
      attr.dest_qpn = peer.id;
      attr.rq_psn = 0;
      attr.path_mtu = qp.mtu;
      attr.dmac = peer.owner.mac;
      attr.min_rnr = env.cfg.min_rnr;
    end
    else if (state == RDMA_DRV_QPS_RTS && qp.qp.cur_state == RDMA_DRV_QPS_RTR) begin
      attr.mask |= rdma_drv_qp_attr::M_SQ_PSN | rdma_drv_qp_attr::M_TIMEOUT |
                   rdma_drv_qp_attr::M_RETRY_CNT | rdma_drv_qp_attr::M_RNR_RETRY;
      attr.sq_psn = 0;
      attr.timeout = env.cfg.timeout;
      attr.retry_cnt = env.cfg.retry;
      attr.rnr_retry = env.cfg.rnr_retry;
    end
    qp.qp.modify(qp.owner.drv(), attr, status);
    if (status.ok())
      env.res.set_state(qp, state == RDMA_DRV_QPS_ERR ? RDMA_RES_ERROR : RDMA_RES_ALIVE);
  endtask

  // 功能：销毁 target（按类型调用驱动），成功后资源库置 DESTROYED（依赖检查在资源库）。
  // 输入/输出及副作用：释放驱动资源。
  // 失败/边界：驱动失败经 item.status 返回，资源保持；设备级队列只随 FLR/remove 失效。
  protected task destroy(rdma_ctrl_item item);
    rdma_res_func f;
    rdma_res_pd pd;
    rdma_res_buf b;
    rdma_res_mr mr;
    rdma_res_cq cq;
    rdma_res_srq srq;
    rdma_res_qp qp;

    f = item.target.owner;
    case (item.target.kind)
      RDMA_RES_PD: begin
        void'($cast(pd, item.target));
        pd.pd.dealloc(f.drv());
      end
      RDMA_RES_BUF: begin
        void'($cast(b, item.target));
        item.status = f.node.hw.free_dma(b.dma);
      end
      RDMA_RES_MR: begin
        void'($cast(mr, item.target));
        mr.mr.dereg(f.drv(), item.status);
      end
      RDMA_RES_CQ: begin
        void'($cast(cq, item.target));
        cq.cq.destroy(f.drv(), item.status);
      end
      RDMA_RES_SRQ: begin
        void'($cast(srq, item.target));
        srq.srq.destroy(f.drv(), item.status);
      end
      RDMA_RES_QP: begin
        void'($cast(qp, item.target));
        qp.qp.destroy(f.drv(), item.status);
      end
      default:
        item.status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                        "device queues are destroyed by FLR/remove only");
    endcase
    if (item.status.ok())
      env.res.destroy(item.target);
  endtask
endclass

class rdma_ctrl_agent extends uvm_agent;
  `uvm_component_utils(rdma_ctrl_agent)

  rdma_ctrl_sequencer sequencer;
  rdma_ctrl_driver driver;

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_ctrl_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建 sequencer 与 driver。
  // 输入/输出及副作用：创建子组件。
  // 失败/边界：无。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sequencer = rdma_ctrl_sequencer::type_id::create("sequencer", this);
    driver = rdma_ctrl_driver::type_id::create("driver", this);
  endfunction

  // 功能：连接 driver 与 sequencer。
  // 输入/输出及副作用：建立 TLM 连接。
  // 失败/边界：无。
  function void connect_phase(uvm_phase phase);
    driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction
endclass
