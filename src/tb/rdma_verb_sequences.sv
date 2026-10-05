// 目录：验证组件层 tb/rdma_verb_sequences.sv。
// 职责：verb 序列：单 item 序列与两节点虚拟流量序列（SEND/RECV 跨 MTU、SEND_IMM、WRITE(+IMM)、
//   unsignaled WRITE、READ、CMP_SWAP/FETCH_ADD、多 SGE/外部 SGB、UD、URC、双向流量与越界访问错误）。
// 依赖：rdma_tb_env（各节点 sequencer）。
// 所有权与生命周期：序列只借用 env；每个 item 新建后交给 driver。
// 约定：数据 MR 内按区域划分偏移；signaled SQ 请求在 driver 内同步等待完成，RECV 不阻塞。
//   qp_index 0/1/2 分别为 RC/UD/URC（后两者存在时才运行对应场景）。

class rdma_verb_one_seq extends uvm_sequence #(rdma_verb_item);
  `uvm_object_utils(rdma_verb_one_seq)

  rdma_verb_item item;

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_verb_one_seq");
    super.new(name);
  endfunction

  // 功能：下发预先构造好的 item。
  // 输入/输出及副作用：阻塞到 driver item_done。
  // 失败/边界：无。
  task body();
    start_item(item);
    finish_item(item);
  endtask
endclass

class rdma_tb_traffic_vseq extends uvm_sequence;
  `uvm_object_utils(rdma_tb_traffic_vseq)

  rdma_tb_env env;

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：运行前须设置 env。
  function new(string name = "rdma_tb_traffic_vseq");
    super.new(name);
  endfunction

  // 功能：两节点（node0↔node1，各自 qp 0 互连）依次运行全部场景。
  // 输入/输出及副作用：经各节点 sequencer 下发 item。
  // 失败/边界：结果由记分板判定。
  task body();
    send_recv();
    write_read();
    atomics();
    reverse_write();
    multi_sge();
    if (env.nodes[0].qps.size() > 2) begin
      ud_send();
      urc_traffic();
    end
    access_error();
  endtask

  // 功能：在节点 node 上下发一个 verb。
  // 输入/输出及副作用：阻塞到 driver 完成该 item（signaled SQ 请求含等待完成）。
  // 失败/边界：无。
  task post(int unsigned node, rdma_verb_item item);
    rdma_verb_one_seq seq;

    seq = rdma_verb_one_seq::type_id::create("one");
    seq.item = item;
    seq.start(env.agents[node].sequencer);
  endtask

  // 功能：构造一个 verb item；带数据的操作填入以 seed 派生的确定性字节。
  // 输入/输出及副作用：返回新 item。
  // 失败/边界：无。
  function rdma_verb_item make(rdma_verb_op_e op, int unsigned local_offset,
                               int unsigned length, int unsigned remote_offset = 0,
                               int unsigned seed = 0, int unsigned qp_index = 0,
                               int unsigned sge_count = 1);
    rdma_verb_item item;

    item = rdma_verb_item::type_id::create("verb");
    item.op = op;
    item.qp_index = qp_index;
    item.sge_count = sge_count;
    item.local_offset = local_offset;
    item.length = length;
    item.remote_offset = remote_offset;
    if (op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM})
      for (int unsigned k = 0; k < length; k++)
        item.data.push_back(byte'(seed * 31 + k * 7 + (k >> 8)));
    return item;
  endfunction

  // 功能：SEND 跨 3 个 MTU 包、SEND_IMM 单包；接收端先投 RECV。
  // 输入/输出及副作用：node1 0x2000/0x3000 区域被写入。
  // 失败/边界：无。
  task send_recv();
    rdma_verb_item item;

    post(1, make(RDMA_VERB_RECV, 'h2000, 'h1000));
    post(1, make(RDMA_VERB_RECV, 'h3000, 'h100));
    post(0, make(RDMA_VERB_SEND, 'h0000, 2500, 0, 1));
    item = make(RDMA_VERB_SEND_IMM, 'h1000, 100, 0, 2);
    item.imm = 32'hcafe_0001;
    post(0, item);
  endtask

  // 功能：unsignaled + signaled WRITE、WRITE_IMM（消耗 RQE）、随后 READ 回读写入区域。
  // 输入/输出及副作用：node1 0x4000 区域写入，node0 0x6000 区域回读。
  // 失败/边界：无。
  task write_read();
    rdma_verb_item item;

    item = make(RDMA_VERB_WRITE, 'h0800, 300, 'h4000, 3);
    item.signaled = 1'b0;
    post(0, item);
    post(0, make(RDMA_VERB_WRITE, 'h0a00, 2148, 'h4200, 4));
    post(1, make(RDMA_VERB_RECV, 'h3100, 'h10));
    item = make(RDMA_VERB_WRITE_IMM, 'h1800, 64, 'h5000, 5);
    item.imm = 32'hcafe_0002;
    post(0, item);
    post(0, make(RDMA_VERB_READ, 'h6000, 2448, 'h4000));
  endtask

  // 功能：FETCH_ADD 两次后 CMP_SWAP 一次命中、一次不命中（原值写回本地 0x7000 区域）。
  // 输入/输出及副作用：node1 0x7800 的 8 字节被改写。
  // 失败/边界：比较值基于 node1 初始内存为零的约定。
  task atomics();
    rdma_verb_item item;

    item = make(RDMA_VERB_FETCH_ADD, 'h7000, 8, 'h7800);
    item.swap_add_value = 64'h5;
    post(0, item);
    item = make(RDMA_VERB_FETCH_ADD, 'h7008, 8, 'h7800);
    item.swap_add_value = 64'h1_0000_0000;
    post(0, item);
    item = make(RDMA_VERB_CMP_SWAP, 'h7010, 8, 'h7800);
    item.compare_value = 64'h1_0000_0005;
    item.swap_add_value = 64'h1234_5678_9abc_def0;
    post(0, item);
    item = make(RDMA_VERB_CMP_SWAP, 'h7018, 8, 'h7800);
    item.compare_value = 64'h1;
    item.swap_add_value = 64'hdead;
    post(0, item);
  endtask

  // 功能：反方向 node1 → node0 的 WRITE 与 SEND。
  // 输入/输出及副作用：node0 0x8000/0x9000 区域写入。
  // 失败/边界：无。
  task reverse_write();
    post(1, make(RDMA_VERB_WRITE, 'h0000, 1024, 'h8000, 6));
    post(0, make(RDMA_VERB_RECV, 'h9000, 'h800));
    post(1, make(RDMA_VERB_SEND, 'h0400, 1025, 0, 7));
  endtask

  // 功能：多 SGE：4-SGE SEND（外部 SGB）进 2-SGE RECV、3-SGE WRITE、READ 散写到 3 个 SGE。
  // 输入/输出及副作用：node1 0xa000/0xb000、node0 0xc000 区域写入。
  // 失败/边界：无。
  task multi_sge();
    post(1, make(RDMA_VERB_RECV, 'ha000, 'h1000, 0, 0, 0, 2));
    post(0, make(RDMA_VERB_SEND, 'h2000, 3000, 0, 9, 0, 4));
    post(0, make(RDMA_VERB_WRITE, 'h3000, 2000, 'hb000, 10, 0, 3));
    post(0, make(RDMA_VERB_READ, 'hc000, 1800, 'hb100, 0, 0, 3));
  endtask

  // 功能：UD SEND（3 个 SGE 经 SGB，单包 ≤ MTU）与 UD SEND_IMM。
  // 输入/输出及副作用：node1 0xd000/0xd400 区域写入。
  // 失败/边界：无。
  task ud_send();
    rdma_verb_item item;

    post(1, make(RDMA_VERB_RECV, 'hd000, 'h400, 0, 0, 1));
    post(1, make(RDMA_VERB_RECV, 'hd400, 'h100, 0, 0, 1));
    post(0, make(RDMA_VERB_SEND, 'h4000, 700, 0, 11, 1, 3));
    item = make(RDMA_VERB_SEND_IMM, 'h4400, 64, 0, 12, 1);
    item.imm = 32'hcafe_0003;
    post(0, item);
  endtask

  // 功能：URC SEND（3 包）、WRITE 与 WRITE_IMM（不等 ACK 即完成）。
  // 输入/输出及副作用：node1 0xe000/0xf000/0xf800 区域写入。
  // 失败/边界：无。
  task urc_traffic();
    rdma_verb_item item;

    post(1, make(RDMA_VERB_RECV, 'he000, 'h900, 0, 0, 2));
    post(1, make(RDMA_VERB_RECV, 'he900, 'h10, 0, 0, 2));
    post(0, make(RDMA_VERB_SEND, 'h4800, 2100, 0, 13, 2));
    post(0, make(RDMA_VERB_WRITE, 'h5000, 1500, 'hf000, 14, 2));
    item = make(RDMA_VERB_WRITE_IMM, 'h5800, 40, 'hf800, 15, 2);
    item.imm = 32'hcafe_0004;
    post(0, item);
  endtask

  // 功能：WRITE 超出对端数据 MR 范围，预期 NAK 并以错误完成，对端内存不变。
  // 输入/输出及副作用：无内存效果。
  // 失败/边界：放在最后，因错误完成可能使 QP 进入错误态。
  task access_error();
    rdma_verb_item item;

    item = make(RDMA_VERB_WRITE, 'h0000, 64,
                env.nodes[1].data_mr.length - 32, 8);
    item.expect_error = 1'b1;
    post(0, item);
  endtask
endclass
