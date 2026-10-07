// 目录：验证组件层 tb/rdma_res.sv。
// 层：验证组件。
// 职责：资源层：每类对象一个类（设备级队列 CMQ/EQ(CEQ、AEQ) 与用户对象 PD/BUF/MR/CQ/SRQ/QP，共用基类
//   rdma_res），每个 Function 一组类型化的
//   资源池（rdma_res_func），全局资源库 rdma_res_db 负责编号、依赖与销毁顺序、FLR 失效与事件广播。
//   资源类只持有驱动对象句柄与验证所需的元数据，不复制驱动状态（如 QP 状态读 qp.cur_state）；
//   在途 WR 属于 scoreboard。
// 依赖：rdma_drv_*（驱动对象）、rdma_dpu_node（Function 的设备与驱动）。
// 所有权：资源库拥有全部 rdma_res 对象；驱动对象归驱动模型。
// 生命周期：env 建立资源库；控制面 driver 是唯一写入者，其它组件只读。

typedef enum {RDMA_RES_CMQ, RDMA_RES_EQ, RDMA_RES_PD, RDMA_RES_BUF, RDMA_RES_MR, RDMA_RES_CQ,
              RDMA_RES_SRQ, RDMA_RES_QP} rdma_res_kind_e;
typedef enum {RDMA_RES_ALIVE, RDMA_RES_ERROR, RDMA_RES_DESTROYED} rdma_res_state_e;

typedef class rdma_res_func;

// 资源公共部分：全局 uid、所属 Function、设备内编号（QPN/CQN/key 等）、状态、复用代数与依赖。
virtual class rdma_res extends uvm_object;
  rdma_res_kind_e kind;
  longint unsigned uid;
  int unsigned id;
  rdma_res_func owner;
  rdma_res_state_e state;
  int unsigned generation;
  rdma_res deps[$];

  // 功能：构造 ALIVE 状态的资源。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res");
    super.new(name);
    state = RDMA_RES_ALIVE;
    generation = 0;
  endfunction

  // 功能：单行描述（日志用）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("%s f%0d #%0d (uid %0d g%0d %s)", kind.name(),
                     owner == null ? -1 : int'(owner.index), id, uid, generation, state.name());
  endfunction
endclass

// 设备级队列：probe 时由驱动创建，env 登记；FLR/remove 时失效。驱动内部对象（HMC、PBLE、位图）不登记。
class rdma_res_cmq extends rdma_res;
  `uvm_object_utils(rdma_res_cmq)
  rdma_drv_cmq cmq;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_cmq");
    super.new(name);
    kind = RDMA_RES_CMQ;
  endfunction
endclass

// CEQ 或 AEQ（id 为 EQN；AEQ 每 Function 一个）。CQ 依赖其 CEQ。
class rdma_res_eq extends rdma_res;
  `uvm_object_utils(rdma_res_eq)
  rdma_drv_eq eq;
  bit is_aeq;
  int unsigned entries;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_eq");
    super.new(name);
    kind = RDMA_RES_EQ;
  endfunction

  // 功能：描述（区分 CEQ/AEQ）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  virtual function string describe();
    return {is_aeq ? "AEQ " : "CEQ ", super.describe()};
  endfunction
endclass

class rdma_res_pd extends rdma_res;
  `uvm_object_utils(rdma_res_pd)
  rdma_drv_pd pd;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_pd");
    super.new(name);
    kind = RDMA_RES_PD;
  endfunction
endclass

// 一段可被 MR 覆盖的内存；仿真 Function 经驱动 hw 读写，远端（rxe）由子类覆盖 read/write。
class rdma_res_buf extends rdma_res;
  `uvm_object_utils(rdma_res_buf)
  rdma_drv_dma dma;
  bit [63:0] iova;
  int unsigned size;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_buf");
    super.new(name);
    kind = RDMA_RES_BUF;
  endfunction

  // 功能：读 [off, off+len)。
  // 输入/输出及副作用：data 输出。
  // 失败/边界：越界或读失败返回错误 status。
  virtual function rdma_status read(int unsigned off, int unsigned len, output rdma_bytes_t data);
    return owner.node.hw.read(dma, off, len, data);
  endfunction

  // 功能：写 off 起的 data。
  // 输入/输出及副作用：写内存。
  // 失败/边界：越界或写失败返回错误 status。
  virtual function rdma_status write(int unsigned off, rdma_bytes_t data);
    return owner.node.hw.write(dma, off, data);
  endfunction
endclass

class rdma_res_mr extends rdma_res;
  `uvm_object_utils(rdma_res_mr)
  rdma_drv_mr mr;
  rdma_res_buf mem;
  bit [63:0] va;
  int unsigned len;
  bit [4:0] rights;
  bit [31:0] key;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_mr");
    super.new(name);
    kind = RDMA_RES_MR;
  endfunction

  // 功能：MR 是否允许以 right 权限访问 [addr, addr+n)（ALIVE、范围内、权限齐全）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit covers(bit [63:0] addr, int unsigned n, bit [4:0] right);
    return state == RDMA_RES_ALIVE && addr >= va && addr + n <= va + len &&
           (rights & right) == right;
  endfunction
endclass

class rdma_res_cq extends rdma_res;
  `uvm_object_utils(rdma_res_cq)
  rdma_drv_cq cq;
  int unsigned depth;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_cq");
    super.new(name);
    kind = RDMA_RES_CQ;
  endfunction
endclass

class rdma_res_srq extends rdma_res;
  `uvm_object_utils(rdma_res_srq)
  rdma_drv_srq srq;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_srq");
    super.new(name);
    kind = RDMA_RES_SRQ;
  endfunction
endclass

class rdma_res_qp extends rdma_res;
  `uvm_object_utils(rdma_res_qp)
  rdma_drv_qp qp;
  rdma_drv_qp_type_e qp_type;
  bit urc;
  rdma_res_qp peer;
  rdma_res_cq send_cq;
  rdma_res_cq recv_cq;
  rdma_res_srq srq;
  bit [31:0] qkey;
  int unsigned mtu;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_qp");
    super.new(name);
    kind = RDMA_RES_QP;
  endfunction

  // 功能：是否为 UD QP。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit ud();
    return qp_type == RDMA_DRV_QPT_UD;
  endfunction
endclass

// 一类资源的池：设备内编号 → 对象。编号复用时新对象的 generation 加一。
class rdma_res_pool #(type T = rdma_res) extends uvm_object;
  `uvm_object_param_utils(rdma_res_pool #(T))
  protected T by_id[int unsigned];

  // 功能：构造空池。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_pool");
    super.new(name);
  endfunction

  // 功能：登记对象；同编号的旧对象须已销毁（新对象 generation = 旧 + 1）。
  // 输入/输出及副作用：修改池。
  // 失败/边界：编号被未销毁对象占用时报 UVM_ERROR 并覆盖。
  function void add(T r);
    if (by_id.exists(r.id)) begin
      if (by_id[r.id].state != RDMA_RES_DESTROYED)
        `uvm_error("RDMA_RES", {"id reused while alive: ", by_id[r.id].describe()})
      r.generation = by_id[r.id].generation + 1;
    end
    by_id[r.id] = r;
  endfunction

  // 功能：按编号取未销毁对象。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：不存在或已销毁返回 null。
  function T get(int unsigned id);
    if (!by_id.exists(id) || by_id[id].state == RDMA_RES_DESTROYED)
      return null;
    return by_id[id];
  endfunction

  // 功能：全部未销毁对象。
  // 输入/输出及副作用：out 输出。
  // 失败/边界：无。
  function void all(ref T out[$]);
    out.delete();
    foreach (by_id[i])
      if (by_id[i].state != RDMA_RES_DESTROYED)
        out.push_back(by_id[i]);
  endfunction
endclass

// 一个 Function 的资源（仿真 Function 持有 dpu 节点；rxe 远端 remote=1、node 为 null）。
class rdma_res_func extends uvm_object;
  `uvm_object_utils(rdma_res_func)
  int unsigned index;
  bit remote;
  rdma_dpu_node node;
  bit [47:0] mac;
  rdma_res_cmq cmq;
  rdma_res_eq aeq;
  rdma_res_pool #(rdma_res_eq) ceqs;
  rdma_res_pool #(rdma_res_pd) pds;
  rdma_res_pool #(rdma_res_buf) bufs;
  rdma_res_pool #(rdma_res_mr) mrs;
  rdma_res_pool #(rdma_res_cq) cqs;
  rdma_res_pool #(rdma_res_srq) srqs;
  rdma_res_pool #(rdma_res_qp) qps;

  // 功能：构造空资源组。
  // 输入/输出及副作用：创建各池。
  // 失败/边界：无。
  function new(string name = "rdma_res_func");
    super.new(name);
    cmq = null;
    aeq = null;
    ceqs = new("ceqs");
    pds = new("pds");
    bufs = new("bufs");
    mrs = new("mrs");
    cqs = new("cqs");
    srqs = new("srqs");
    qps = new("qps");
  endfunction

  // 功能：该 Function 的驱动（远端为 null）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function rdma_drv_dev drv();
    return node == null ? null : node.drv;
  endfunction

  // 功能：全部未销毁资源（QP、SRQ、CQ、MR、BUF、PD、CEQ、AEQ、CMQ 的顺序，即合法销毁顺序）。
  // 输入/输出及副作用：out 输出。
  // 失败/边界：无。
  function void all(ref rdma_res out[$]);
    rdma_res_pd p[$];
    rdma_res_buf b[$];
    rdma_res_mr m[$];
    rdma_res_cq c[$];
    rdma_res_srq s[$];
    rdma_res_qp q[$];
    rdma_res_eq e[$];

    out.delete();
    ceqs.all(e);
    pds.all(p);
    bufs.all(b);
    mrs.all(m);
    cqs.all(c);
    srqs.all(s);
    qps.all(q);
    foreach (q[i]) out.push_back(q[i]);
    foreach (s[i]) out.push_back(s[i]);
    foreach (c[i]) out.push_back(c[i]);
    foreach (m[i]) out.push_back(m[i]);
    foreach (b[i]) out.push_back(b[i]);
    foreach (p[i]) out.push_back(p[i]);
    foreach (e[i]) out.push_back(e[i]);
    if (aeq != null && aeq.state != RDMA_RES_DESTROYED) out.push_back(aeq);
    if (cmq != null && cmq.state != RDMA_RES_DESTROYED) out.push_back(cmq);
  endfunction
endclass

typedef enum {RDMA_RES_CREATED, RDMA_RES_CHANGED, RDMA_RES_REMOVED} rdma_res_event_e;

class rdma_res_event extends uvm_object;
  `uvm_object_utils(rdma_res_event)
  rdma_res_event_e what;
  rdma_res res;

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_res_event");
    super.new(name);
  endfunction
endclass

class rdma_res_db extends uvm_component;
  `uvm_component_utils(rdma_res_db)
  rdma_res_func funcs[$];
  uvm_analysis_port #(rdma_res_event) ap;
  protected longint unsigned next_uid;

  // 功能：构造空资源库。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_res_db", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
    next_uid = 1;
  endfunction

  // 功能：登记一个 Function（index 为其在 funcs 中的位置）。
  // 输入/输出及副作用：追加 funcs，返回新资源组。
  // 失败/边界：无。
  function rdma_res_func add_func(rdma_dpu_node node, bit [47:0] mac, bit remote = 1'b0);
    rdma_res_func f;

    f = rdma_res_func::type_id::create($sformatf("func%0d", funcs.size()));
    f.index = funcs.size();
    f.node = node;
    f.mac = mac;
    f.remote = remote;
    funcs.push_back(f);
    return f;
  endfunction

  // 功能：登记资源：分配 uid，放入所属 Function 的对应池，广播 CREATED。
  // 输入/输出及副作用：修改池。
  // 失败/边界：owner 为空报 UVM_FATAL。
  function void add(rdma_res r);
    rdma_res_pd pd;
    rdma_res_buf b;
    rdma_res_mr mr;
    rdma_res_cq cq;
    rdma_res_srq srq;
    rdma_res_qp qp;
    rdma_res_eq eq;
    rdma_res_cmq cmq;

    if (r.owner == null)
      `uvm_fatal("RDMA_RES", "resource without owner")
    r.uid = next_uid++;
    if ($cast(cmq, r))
      r.owner.cmq = cmq;
    else if ($cast(eq, r) && eq.is_aeq)
      r.owner.aeq = eq;
    else if ($cast(eq, r))
      r.owner.ceqs.add(eq);
    else if ($cast(pd, r))
      r.owner.pds.add(pd);
    else if ($cast(b, r))
      r.owner.bufs.add(b);
    else if ($cast(mr, r))
      r.owner.mrs.add(mr);
    else if ($cast(cq, r))
      r.owner.cqs.add(cq);
    else if ($cast(srq, r))
      r.owner.srqs.add(srq);
    else if ($cast(qp, r))
      r.owner.qps.add(qp);
    publish(RDMA_RES_CREATED, r);
  endfunction

  // 功能：修改资源状态（如 QP 进入 ERR）并广播 CHANGED。
  // 输入/输出及副作用：修改 r.state。
  // 失败/边界：无。
  function void set_state(rdma_res r, rdma_res_state_e state);
    r.state = state;
    publish(RDMA_RES_CHANGED, r);
  endfunction

  // 功能：销毁资源：仍被同 Function 的未销毁资源依赖时报错（销毁顺序：QP → CQ/SRQ/MR → BUF/PD → EQ/CMQ）。
  // 输入/输出及副作用：r.state = DESTROYED，广播 REMOVED。
  // 失败/边界：顺序错误报 UVM_ERROR，仍执行销毁。
  function void destroy(rdma_res r);
    rdma_res users[$];

    r.owner.all(users);
    foreach (users[i])
      foreach (users[i].deps[d])
        if (users[i].deps[d] == r && users[i] != r)
          `uvm_error("RDMA_RES", {r.describe(), " destroyed while used by ", users[i].describe()})
    r.state = RDMA_RES_DESTROYED;
    publish(RDMA_RES_REMOVED, r);
  endfunction

  // 功能：FLR/复位：范围内 Function 的全部资源失效（编号可复用），逐个广播 REMOVED。
  // 输入/输出及副作用：修改资源状态。
  // 失败/边界：无。
  function void on_flr(int unsigned scope[$]);
    rdma_res all_res[$];

    foreach (scope[i]) begin
      funcs[scope[i]].all(all_res);
      foreach (all_res[k]) begin
        all_res[k].state = RDMA_RES_DESTROYED;
        publish(RDMA_RES_REMOVED, all_res[k]);
      end
    end
  endfunction

  // 功能：按 (Function, QPN) 取 QP。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：不存在返回 null。
  function rdma_res_qp qp(int unsigned f, int unsigned qpn);
    return funcs[f].qps.get(qpn);
  endfunction

  // 功能：广播资源事件。
  // 输入/输出及副作用：写 analysis 端口。
  // 失败/边界：无。
  protected function void publish(rdma_res_event_e what, rdma_res r);
    rdma_res_event e;

    e = rdma_res_event::type_id::create("res_event");
    e.what = what;
    e.res = r;
    ap.write(e);
  endfunction
endclass
