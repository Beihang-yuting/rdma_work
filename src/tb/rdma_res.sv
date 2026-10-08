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

  // 功能：建立尚未登记的资源基对象，并把生命周期状态初始化为 ALIVE、复用代数初始化为 0。
  // 输入/输出及副作用：name 传给 uvm_object；只初始化本对象，uid、id、kind、owner 与依赖由具体资源和资源库补齐。
  // 失败/边界：不校验 name，也不分配设备资源；对象加入 rdma_res_db 前不得依赖尚未赋值的身份与所有者字段。
  function new(string name = "rdma_res");
    super.new(name);
    state = RDMA_RES_ALIVE;
    generation = 0;
  endfunction

  // 功能：把资源种类、Function 下标、设备内编号、uid、复用代数和状态格式化为单行日志文本。
  // 输入/输出及副作用：返回当前字段的快照字符串，不修改资源或 owner。
  // 失败/边界：owner 为空时以 Function 下标 -1 表示尚未归属，其余尚未赋值字段按 SystemVerilog 当前值输出。
  virtual function string describe();
    return $sformatf("%s f%0d #%0d (uid %0d g%0d %s)", kind.name(),
                     owner == null ? -1 : int'(owner.index), id, uid, generation, state.name());
  endfunction
endclass

// 设备级队列：probe 时由驱动创建，env 登记；FLR/remove 时失效。驱动内部对象（HMC、PBLE、位图）不登记。
class rdma_res_cmq extends rdma_res;
  `uvm_object_utils(rdma_res_cmq)
  rdma_drv_cmq cmq;

  // 功能：建立 ALIVE 的 CMQ 资源描述，并固定资源种类为 RDMA_RES_CMQ。
  // 输入/输出及副作用：name 传给资源基类；只修改新对象，cmq 驱动句柄仍由 probe 登记路径绑定。
  // 失败/边界：构造不创建硬件 CMQ；在 cmq、owner 与 id 赋值前，该对象只能作为未登记描述使用。
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

  // 功能：建立 ALIVE 的 CEQ/AEQ 资源描述，并固定资源种类为 RDMA_RES_EQ。
  // 输入/输出及副作用：name 传给资源基类；eq、is_aeq、entries 和身份字段由创建/登记路径随后填写。
  // 失败/边界：构造不创建驱动 EQ，也不推断 CEQ/AEQ 类型；调用者必须在加入资源库前设置 is_aeq。
  function new(string name = "rdma_res_eq");
    super.new(name);
    kind = RDMA_RES_EQ;
  endfunction

  // 功能：在资源基类描述前添加 CEQ 或 AEQ 前缀，便于日志区分两类事件队列。
  // 输入/输出及副作用：根据 is_aeq 返回新字符串，不修改队列资源。
  // 失败/边界：尚未显式设置 is_aeq 时使用其默认假值并显示为 CEQ；owner 为空的处理沿用基类 describe。
  virtual function string describe();
    return {is_aeq ? "AEQ " : "CEQ ", super.describe()};
  endfunction
endclass

class rdma_res_pd extends rdma_res;
  `uvm_object_utils(rdma_res_pd)
  rdma_drv_pd pd;

  // 功能：建立 ALIVE 的保护域资源描述，并固定资源种类为 RDMA_RES_PD。
  // 输入/输出及副作用：name 传给资源基类；pd 驱动句柄及 owner、id 由控制面创建路径绑定。
  // 失败/边界：构造不分配保护域；登记前访问空 pd 句柄或未赋值身份字段属于调用顺序错误。
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

  // 功能：建立 ALIVE 的缓冲资源描述，并固定资源种类为 RDMA_RES_BUF。
  // 输入/输出及副作用：name 传给资源基类；dma、iova、size 与 owner 由缓冲分配路径随后填写。
  // 失败/边界：构造不分配 Host 内存；dma 或 owner/node 未绑定时不得调用 read/write。
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

  // 功能：建立 ALIVE 的内存区域资源描述，并固定资源种类为 RDMA_RES_MR。
  // 输入/输出及副作用：name 传给资源基类；mr、mem、va、len、rights、key 和归属由注册路径随后填写。
  // 失败/边界：构造不注册 MR，也不取得 mem 所有权；字段绑定完成前 covers 的结果不代表有效注册区间。
  function new(string name = "rdma_res_mr");
    super.new(name);
    kind = RDMA_RES_MR;
  endfunction

  // 功能：MR 是否允许以 right 权限访问 [addr, addr+n)（ALIVE、范围内、权限齐全）。
  // 输入/输出及副作用：输入起始地址 addr、长度 n 和所需权限 right，返回布尔判定；不修改 MR。
  // 失败/边界：MR 非 ALIVE、addr 低于 va、末地址超过 va+len 或 rights 缺少任一请求位时返回 0；调用者须避免地址加法溢出。
  function bit covers(bit [63:0] addr, int unsigned n, bit [4:0] right);
    return state == RDMA_RES_ALIVE && addr >= va && addr + n <= va + len &&
           (rights & right) == right;
  endfunction
endclass

class rdma_res_cq extends rdma_res;
  `uvm_object_utils(rdma_res_cq)
  rdma_drv_cq cq;
  int unsigned depth;

  // 功能：建立 ALIVE 的完成队列资源描述，并固定资源种类为 RDMA_RES_CQ。
  // 输入/输出及副作用：name 传给资源基类；cq、depth、owner、id 及其 CEQ 依赖由创建路径随后填写。
  // 失败/边界：构造不创建驱动 CQ；depth 与 cq 句柄绑定前不得用该对象提交或轮询完成。
  function new(string name = "rdma_res_cq");
    super.new(name);
    kind = RDMA_RES_CQ;
  endfunction
endclass

class rdma_res_srq extends rdma_res;
  `uvm_object_utils(rdma_res_srq)
  rdma_drv_srq srq;

  // 功能：建立 ALIVE 的共享接收队列资源描述，并固定资源种类为 RDMA_RES_SRQ。
  // 输入/输出及副作用：name 传给资源基类；srq 句柄、身份、保护域依赖和归属由创建路径随后填写。
  // 失败/边界：构造不创建驱动 SRQ；未登记对象不能作为 QP 的共享接收队列使用。
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

  // 功能：建立 ALIVE 的队列对资源描述，并固定资源种类为 RDMA_RES_QP。
  // 输入/输出及副作用：name 传给资源基类；qp、类型、peer、CQ/SRQ、qkey、mtu 与依赖由 QP 创建/连接路径填写。
  // 失败/边界：构造不创建或连接 QP；拓扑字段补齐前不得用该对象生成 verb。
  function new(string name = "rdma_res_qp");
    super.new(name);
    kind = RDMA_RES_QP;
  endfunction

  // 功能：判断当前资源记录的 QP 类型是否为 RDMA_DRV_QPT_UD。
  // 输入/输出及副作用：读取 qp_type 并返回精确比较结果，不修改 QP。
  // 失败/边界：未由创建路径赋值时按 qp_type 的当前默认值判定，不查询底层 qp 句柄作兜底。
  function bit ud();
    return qp_type == RDMA_DRV_QPT_UD;
  endfunction
endclass

// 一类资源的池：设备内编号 → 对象。编号复用时新对象的 generation 加一。
class rdma_res_pool #(type T = rdma_res) extends uvm_object;
  `uvm_object_param_utils(rdma_res_pool #(T))
  protected T by_id[int unsigned];

  // 功能：建立不含任何设备内编号映射的类型化资源池。
  // 输入/输出及副作用：name 传给 uvm_object；关联数组 by_id 留空，后续 add 的对象仍归资源库所有。
  // 失败/边界：不预分配容量或检查参数类型；只有经 add 登记的编号才能被 get/all 观察到。
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

  // 功能：收集池中状态不是 RDMA_RES_DESTROYED 的全部对象。
  // 输入/输出及副作用：先清空调用者传入的 out 队列，再按关联数组迭代顺序写入借用句柄；池本身不变。
  // 失败/边界：空池或仅含已销毁对象时输出空队列；返回次序只由 by_id 的关联数组顺序决定。
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

  // 功能：建立一个 Function 的空资源组，将单例 CMQ/AEQ 置空并创建各类编号资源池。
  // 输入/输出及副作用：name 传给 uvm_object；本对象拥有新建的池，池内资源仍由 rdma_res_db 管理。
  // 失败/边界：index、remote、node、mac 由 add_func 随后赋值；构造阶段 drv() 返回 null，all() 返回空队列。
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

  // 功能：取得该 Function 节点所引用的 RDMA 驱动，供本地资源操作使用。
  // 输入/输出及副作用：返回 node.drv 的非拥有句柄，不修改 node 或驱动生命周期。
  // 失败/边界：node 为空（包括 rxe 远端资源组）时返回 null；不校验非空 node 内的 drv 是否已经 probe。
  function rdma_drv_dev drv();
    return node == null ? null : node.drv;
  endfunction

  // 功能：全部未销毁资源（QP、SRQ、CQ、MR、BUF、PD、CEQ、AEQ、CMQ 的顺序，即合法销毁顺序）。
  // 输入/输出及副作用：先清空 out，再写入各池和单例队列中的非拥有资源句柄；不改变资源状态。
  // 失败/边界：跳过已销毁资源以及空的 aeq/cmq；Function 尚无资源时输出空队列，顺序仅保证类型间的销毁依赖顺序。
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

  // 功能：建立尚未填充事件类型和资源句柄的资源事件载体。
  // 输入/输出及副作用：name 传给 uvm_object；事件只借用 res，不取得资源所有权。
  // 失败/边界：构造不设置 what/res；只有 publish 填完两个字段后才能发送给 analysis 订阅者。
  function new(string name = "rdma_res_event");
    super.new(name);
  endfunction
endclass

class rdma_res_db extends uvm_component;
  `uvm_component_utils(rdma_res_db)
  rdma_res_func funcs[$];
  uvm_analysis_port #(rdma_res_event) ap;
  protected longint unsigned next_uid;

  // 功能：建立空资源库、创建资源事件 analysis 端口，并把首个全局 uid 设为 1。
  // 输入/输出及副作用：name/parent 传给 uvm_component；本组件拥有 ap 与以后建立的 Function 资源组。
  // 失败/边界：parent 可按 UVM 顶层规则为空；构造阶段 funcs 为空，资源只有经 add_func/add 后才可查询。
  function new(string name = "rdma_res_db", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
    next_uid = 1;
  endfunction

  // 功能：登记一个 Function（index 为其在 funcs 中的位置）。
  // 输入/输出及副作用：输入非拥有 node、mac 和 remote 标志；追加 funcs，设置连续 index，并返回资源组句柄。
  // 失败/边界：不检查重复 Function；remote 组允许 node 为空，本地组若传空 node 则后续驱动访问只能得到 null。
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

  // 功能：把指定资源切换到给定生命周期状态，并向所有订阅者广播 CHANGED 事件。
  // 输入/输出及副作用：写 r.state，即使值未变化也创建并发送一次事件；通知不会转移 r 的所有权。
  // 失败/边界：调用者必须传入非空且已登记的 r；本函数不验证状态迁移合法性，也不抑制幂等通知。
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

  // 功能：对 scope 中每个 Function 执行 FLR 失效，将其当前全部未销毁资源置为 DESTROYED 并逐个广播 REMOVED。
  // 输入/输出及副作用：读取 Function 下标队列 scope，修改资源状态并写 ap；保留池映射供后续编号复用递增 generation。
  // 失败/边界：scope 下标必须落在 funcs 范围内；重复下标第二次看不到已销毁资源，因此不会重复发布其 REMOVED。
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

  // 功能：为资源状态变化创建事件对象，填入事件类型与资源句柄后通过 analysis 端口同步广播。
  // 输入/输出及副作用：输入 what 和非拥有 r，分配临时 rdma_res_event 并调用 ap.write；不改变 r。
  // 失败/边界：不拒绝空 r，也不缓存无订阅者事件；调用方负责只发布语义完整的资源事件。
  protected function void publish(rdma_res_event_e what, rdma_res r);
    rdma_res_event e;

    e = rdma_res_event::type_id::create("res_event");
    e.what = what;
    e.res = r;
    ap.write(e);
  endfunction
endclass
