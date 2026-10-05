// 目录：验证组件层 tb/rdma_tb_items.sv。
// 职责：定义 verb 事务（sequence item）与完成事件，作为 sequence、driver、monitor、记分板之间的契约。
// 依赖：rdma_types/model 的枚举与 UVM sequence item。
// 所有权与生命周期：item 由 sequence 创建，driver 回填 wr_id/node_id 后经 analysis 端口广播。

// verb 操作类型；RECV 走 RQ，其余走 SQ。
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

// 功能：判断 verb 是否为 atomic（固定 8 字节，偏移需 8 字节对齐）。
// 输入/输出及副作用：纯函数。
// 失败/边界：无。
function automatic bit rdma_verb_is_atomic(rdma_verb_op_e op);
  return op inside {RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
endfunction

// 一条 verb 请求：本地 buffer 位于节点数据 MR 的 local_offset，远端地址位于对端数据 MR 的
//   remote_offset；SEND/WRITE 的源数据放在 data，由 driver 在投递前写入 host 内存。
class rdma_verb_item extends uvm_sequence_item;
  `rdma_object_utils(rdma_verb_item)

  rdma_verb_op_e op;
  int unsigned qp_index;
  int unsigned local_offset;
  int unsigned length;
  // 本地 buffer 均分为 sge_count 个连续 SGE（>2 时走 SQ/RQ 外部 SGB，RQ 需 QP 启用 RQ SGB）。
  int unsigned sge_count;
  int unsigned remote_offset;
  bit [31:0] imm;
  bit [63:0] compare_value;
  bit [63:0] swap_add_value;
  bit signaled;
  // 预期以错误完成（如非法 rkey）；记分板据此比对状态且不更新影子内存。
  bit expect_error;
  byte unsigned data[$];
  // 由 driver 回填。
  int unsigned node_id;
  longint unsigned wr_id;

  // 功能：构造默认 SEND item，signaled=1，其余字段清零。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_verb_item");
    super.new(name);
    op = RDMA_VERB_SEND;
    qp_index = 0;
    local_offset = 0;
    length = 0;
    sge_count = 1;
    remote_offset = 0;
    imm = '0;
    compare_value = '0;
    swap_add_value = '0;
    signaled = 1'b1;
    expect_error = 1'b0;
    node_id = 0;
    wr_id = 0;
  endfunction

  // 功能：复制 item 的全部字段。
  // 输入/输出及副作用：覆盖本对象字段。
  // 失败/边界：类型不符触发 RDMA_COPY_TYPE fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_verb_item r;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "verb item copy mismatch")
    op = r.op;
    qp_index = r.qp_index;
    local_offset = r.local_offset;
    length = r.length;
    sge_count = r.sge_count;
    remote_offset = r.remote_offset;
    imm = r.imm;
    compare_value = r.compare_value;
    swap_add_value = r.swap_add_value;
    signaled = r.signaled;
    expect_error = r.expect_error;
    data = r.data;
    node_id = r.node_id;
    wr_id = r.wr_id;
  endfunction

  // 功能：生成单行诊断字符串。
  // 输入/输出及副作用：只读。
  // 失败/边界：无。
  virtual function string convert2string();
    return $sformatf("node=%0d qp=%0d %s wr_id=%0h local=+%0h len=%0d sges=%0d remote=+%0h",
                     node_id, qp_index, op.name(), wr_id, local_offset, length, sge_count,
                     remote_offset);
  endfunction
endclass

// monitor 观测到的一条完成。
class rdma_verb_completion extends uvm_object;
  `rdma_object_utils(rdma_verb_completion)

  int unsigned node_id;
  longint unsigned wr_id;
  bit rq;
  bit ok;
  bit [7:0] ecode;
  int unsigned byte_len;
  bit [31:0] imm;

  // 功能：构造空完成事件。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_verb_completion");
    super.new(name);
    node_id = 0;
    wr_id = 0;
    rq = 1'b0;
    ok = 1'b0;
    ecode = '0;
    byte_len = 0;
    imm = '0;
  endfunction

  // 功能：生成单行诊断字符串。
  // 输入/输出及副作用：只读。
  // 失败/边界：无。
  virtual function string convert2string();
    return $sformatf("node=%0d wr_id=%0h rq=%0b ok=%0b ecode=%02h len=%0d imm=%08h",
                     node_id, wr_id, rq, ok, ecode, byte_len, imm);
  endfunction
endclass
