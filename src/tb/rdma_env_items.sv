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

  // 功能：构造默认请求（深度 256、SGE 4、RC、全部权限）。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_ctrl_item");
    super.new(name);
    size = 256;
    max_sge = 4;
    qp_type = RDMA_DRV_QPT_RC;
    rights = rdma_drv_mr::rights_of(1, 1, 1, 1);
  endfunction

  // 功能：单行描述。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
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

  // 功能：构造默认 SEND（signaled、1 个 SGE、RANDOM 数据）。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_verb_item");
    super.new(name);
    op = RDMA_VERB_SEND;
    sge_count = 1;
    signaled = 1'b1;
    data_mode = PAYLOAD_RANDOM;
  endfunction

  // 功能：是否携带源数据（SEND/WRITE 类）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit has_data();
    return op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM};
  endfunction

  // 功能：是否为 atomic（固定 8 字节）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit atomic();
    return op inside {RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
  endfunction

  // 功能：是否消耗对端 RQE（SEND 类与 WRITE_IMM）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit consumes_rqe();
    return op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE_IMM};
  endfunction

  // 功能：单行描述。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
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

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_verb_completion");
    super.new(name);
  endfunction

  // 功能：单行描述。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
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

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_aeq_event");
    super.new(name);
  endfunction
endclass
