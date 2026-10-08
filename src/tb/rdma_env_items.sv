// 目录：验证组件层 tb/rdma_env_items.sv。
// 层：验证组件。
// 职责：env 事务：控制面 rdma_ctrl_item（资源生命周期、QP 连接/迁移、FLR/恢复）、数据面 rdma_verb_item
//   （资源句柄、数据规格与原始数据、scoreboard 预测的完成状态）、monitor 观测的 rdma_verb_completion 与 rdma_aeq_event。
// 依赖：rdma_res（资源句柄）、rdma_drv_*（类型与状态枚举）、net_packet payload_mode_e。
// 所有权：item 由序列创建；driver 回填输出字段（资源、wr_id、原始数据）。
// 生命周期：随序列与 analysis 广播流转。

typedef enum {
  RDMA_CTRL_ALLOC_PD,
  RDMA_CTRL_ALLOC_BUF,
  RDMA_CTRL_REG_MR,
  RDMA_CTRL_CREATE_CQ,
  RDMA_CTRL_CREATE_SRQ,
  RDMA_CTRL_CREATE_QP,
  RDMA_CTRL_CONNECT,
  RDMA_CTRL_MODIFY_QP,
  RDMA_CTRL_DESTROY,
  RDMA_CTRL_FLR,
  RDMA_CTRL_RECOVER
} rdma_ctrl_op_e;

// 控制面请求：按 op 使用对应字段；driver 回填 res 与 status。
class rdma_ctrl_item extends uvm_sequence_item;
  `rdma_object_utils(rdma_ctrl_item)

  rdma_ctrl_op_e op;
  int unsigned func;
  // ALLOC_BUF 字节数；CREATE_CQ/SRQ/QP 深度。
  int unsigned size;
  // REG_MR：pd + mem（len 为 0 时覆盖 mem 的 offset 之后全部）与权限。
  rdma_res_pd pd;
  rdma_res_buf mem;
  int unsigned offset;
  int unsigned len;
  bit [4:0] rights;
  // CREATE_QP：类型、URC、CQ、SRQ、SGE 上限。
  rdma_drv_qp_type_e qp_type;
  bit urc;
  rdma_res_cq send_cq;
  rdma_res_cq recv_cq;
  rdma_res_srq srq;
  int unsigned max_sge;
  // CONNECT（qp ↔ peer 双向推到 RTS）/ MODIFY_QP（qp 迁到 state）。
  rdma_res_qp qp;
  rdma_res_qp peer;
  rdma_drv_qp_state_e state;
  // DESTROY 对象；FLR/RECOVER 范围（Function 下标）。
  rdma_res target;
  int unsigned scope[$];
  // 期望失败（如非法迁移）：失败不报错，成功反而报错。
  bit expect_fail;
  // 输出。
  rdma_res res;
  rdma_status status;

  // 功能：构造默认深度 256、最多 4 SGE、RC 类型且开放本地写与全部远端权限的控制面请求。
  // 输入/输出及副作用：name 为 UVM 名；资源句柄、scope、res/status 输出保持空或零初值，item 不拥有资源。
  // 失败/边界：默认 op 为枚举零值 ALLOC_PD；执行其他 op 前 sequence 必须补齐该分支要求的句柄和范围。
  function new(string name = "rdma_ctrl_item");
    super.new(name);
    size = 256;
    max_sge = 4;
    qp_type = RDMA_DRV_QPT_RC;
    rights = rdma_drv_mr::rights_of(1, 1, 1, 1);
  endfunction

  // 功能：生成包含操作、Function、size 与可选 destroy target 的单行控制请求描述。
  // 输入/输出及副作用：只读当前字段并返回新字符串；target 非空时调用其 describe，不改变 item 或资源。
  // 失败/边界：target 为空时省略目标；尚未设置的字段按零/当前枚举名打印，status/res 不进入描述。
  virtual function string convert2string();
    return $sformatf("%s f%0d size=%0d%s", op.name(), func, size,
                     target == null ? "" : {" ", target.describe()});
  endfunction
endclass

typedef enum bit [3:0] {
  RDMA_VERB_SEND,
  RDMA_VERB_SEND_IMM,
  RDMA_VERB_WRITE,
  RDMA_VERB_WRITE_IMM,
  RDMA_VERB_READ,
  RDMA_VERB_CMP_SWAP,
  RDMA_VERB_FETCH_ADD,
  RDMA_VERB_RECV
} rdma_verb_op_e;

// 一条 verb：本地 buffer = lmr 内 local_offset 起 length 字节（均分为 sge_count 个 SGE）；
//   WRITE/READ/ATOMIC 的远端 = rmr 内 remote_offset；UD 目的为 qp.peer。srq 非空时 RECV 投到 SRQ。
//   SEND/WRITE 的源数据按 data_mode 生成（data 已给出时直接使用），driver 写入源内存并保留在 data。
class rdma_verb_item extends uvm_sequence_item;
  `rdma_object_utils(rdma_verb_item)

  rdma_verb_op_e op;
  rdma_res_qp qp;
  rdma_res_srq srq;
  rdma_res_mr lmr;
  int unsigned local_offset;
  int unsigned length;
  int unsigned sge_count;
  rdma_res_mr rmr;
  int unsigned remote_offset;
  bit [31:0] imm;
  bit [63:0] compare_value;
  bit [63:0] swap_add_value;
  bit signaled;
  // UD 目的 Q_Key（0 取对端 QP 的 Q_Key；故意不符时接收端应丢弃）。
  bit [31:0] ud_qkey;
  payload_mode_e data_mode;
  byte unsigned data_fixed;
  byte unsigned data_pattern[$];
  // 原始数据（driver 生成或序列给出）。
  byte unsigned data[$];
  // driver 回填。
  longint unsigned wr_id;
  // scoreboard 预测：期望完成状态；may_flush 为 QP 转 ERR 时在途（成功或 FLUSH 均可）；overflow 为
  //   消耗的 RECV 容量不足（接收端以错误完成）。
  rdma_drv_wc_status_e expect_status;
  bit may_flush;
  bit overflow;

  // 功能：构造默认 signaled、单 SGE、随机数据模式的 SEND verb item。
  // 输入/输出及副作用：name 为 UVM 名；QP/MR/SRQ 为非拥有空引用，长度/偏移/数据与 wr_id 输出为空或零。
  // 失败/边界：投递前 sequence 必须提供 QP、本地 MR 及与操作匹配的远端资源；构造不做范围或权限校验。
  function new(string name = "rdma_verb_item");
    super.new(name);
    op = RDMA_VERB_SEND;
    sge_count = 1;
    signaled = 1'b1;
    data_mode = PAYLOAD_RANDOM;
  endfunction

  // 功能：判断当前 verb 是否需要 driver 从本地 SGE 取得源数据，即 SEND/WRITE 及其立即数变体。
  // 输入/输出及副作用：只读 op 并返回布尔值，不访问 MR 或修改数据队列。
  // 失败/边界：READ、ATOMIC、RECV 及强制转换得到的未知 opcode 均返回 0。
  function bit has_data();
    return op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM};
  endfunction

  // 功能：判断当前 verb 是否为固定 8 字节的 compare-swap 或 fetch-add 原子操作。
  // 输入/输出及副作用：只读 op 并返回布尔值，不校验 length、地址对齐或远端权限。
  // 失败/边界：非两种 atomic opcode（含未知枚举值）返回 0，实际 8B/对齐约束由 driver/scoreboard 检查。
  function bit atomic();
    return op inside {RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
  endfunction

  // 功能：判断 verb 是否需要对端消费一个 RQE：SEND、SEND_IMM 或 WRITE_IMM。
  // 输入/输出及副作用：只读 op 并返回 scoreboard/sequence 使用的布尔分类，不修改 item。
  // 失败/边界：普通 WRITE、READ、ATOMIC、RECV 与未知 opcode 返回 0；本函数不判断 RQE 是否已投递。
  function bit consumes_rqe();
    return op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE_IMM};
  endfunction

  // 功能：生成包含 verb、QP、wr_id、本地/远端偏移、长度、SGE 数与数据模式的单行描述。
  // 输入/输出及副作用：只读 item；QP 非空时调用 describe，返回字符串且不触碰资源或 payload。
  // 失败/边界：QP 为空时显示“-”；非法枚举的 name 可能为空，MR/key/status 等详细字段有意不在摘要中。
  virtual function string convert2string();
    return $sformatf("%s qp=%s wr_id=%0h local=+%0h len=%0d sges=%0d remote=+%0h %s",
                     op.name(), qp == null ? "-" : qp.describe(), wr_id, local_offset, length,
                     sge_count, remote_offset, data_mode.name());
  endfunction
endclass

// monitor 观测到的一条完成（func 为所属 Function 下标）。
class rdma_verb_completion extends uvm_object;
  `rdma_object_utils(rdma_verb_completion)

  int unsigned func;
  longint unsigned wr_id;
  int unsigned qpn;
  int unsigned src_qp;
  bit rq;
  rdma_drv_wc_status_e status;
  bit [7:0] vendor;
  int unsigned byte_len;
  bit [31:0] imm;

  // 功能：构造尚未填入 monitor 结果的 verb completion 值对象。
  // 输入/输出及副作用：name 为 UVM 名；身份、状态、长度与立即数字段保持零初值，不持有 QP/CQ 引用。
  // 失败/边界：必须由 monitor 填完 func/wr_id/qpn/rq/status 后再发布；零值本身可表示成功状态但非有效事件。
  function new(string name = "rdma_verb_completion");
    super.new(name);
  endfunction

  // 功能：把完成的 Function/QPN/wr_id/方向、状态、vendor、长度和立即数格式化为单行摘要。
  // 输入/输出及副作用：只读全部标量字段并返回字符串，不修改完成或关联 monitor 状态。
  // 失败/边界：未填充对象按零值打印；非法 status 枚举的 name 可能为空，不在此补做合法性判断。
  virtual function string convert2string();
    return $sformatf("f%0d qpn=%0d wr_id=%0h rq=%0b %s vendor=%02h len=%0d imm=%08h", func, qpn,
                     wr_id, rq, status.name(), vendor, byte_len, imm);
  endfunction
endclass

// AEQ 异步事件：{ecode, QPN 或 SRQN}。
class rdma_aeq_event extends uvm_object;
  `rdma_object_utils(rdma_aeq_event)

  int unsigned func;
  bit [7:0] ecode;
  int unsigned id;

  // 功能：构造尚未填入 Function、错误码与资源编号的 AEQ 事件值对象。
  // 输入/输出及副作用：name 为 UVM 名；func/ecode/id 保持零初值，对象不持有 AEQ 或 QP/SRQ 资源。
  // 失败/边界：零值不是“无事件”哨兵；monitor 必须在 analysis 发布前填写与 AEQE 类型相符的 id。
  function new(string name = "rdma_aeq_event");
    super.new(name);
  endfunction
endclass
