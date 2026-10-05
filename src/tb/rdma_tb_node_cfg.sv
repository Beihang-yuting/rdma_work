// 目录：验证组件层 tb/rdma_tb_node_cfg.sv。
// 职责：描述一个 RDMA 节点（一个 Function）在 tb 中可见的资源：queue-data engine、CQ、QP 连接表、
//   数据 MR 与 MTU，供 agent、NIC 模型和记分板共享。
// 依赖：core/model 的 engine、resource 与 mapping 类型。
// 所有权与生命周期：全部为非拥有引用，资源由测试/fixture 创建与释放。

// 本地 QP 与对端 (节点, QP 下标) 的连接关系。
class rdma_tb_qp_link extends uvm_object;
  `rdma_object_utils(rdma_tb_qp_link)

  rdma_qp qp;
  int unsigned peer_node;
  int unsigned peer_qp_index;

  // 功能：构造空连接。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_tb_qp_link");
    super.new(name);
    qp = null;
    peer_node = 0;
    peer_qp_index = 0;
  endfunction
endclass

class rdma_tb_node_cfg extends uvm_object;
  `rdma_object_utils(rdma_tb_node_cfg)

  int unsigned node_id;
  rdma_queue_data_engine engine;
  rdma_cq cq;
  rdma_tb_qp_link qps[$];
  // 数据 MR：verb 的本地/远端 buffer 都位于该 MR 内，data_mapping 是其唯一 backing。
  rdma_mr data_mr;
  rdma_dma_mapping data_mapping;
  int unsigned mtu;
  // UD 发送使用的 Q_Key（须与对端 UD QP 的 QPC qkey 一致）。
  bit [31:0] ud_qkey;
  time poll_interval;
  // NIC 等待对端响应或 RQE 的最长时间。
  time response_timeout;
  // engine 的 CQ 生产（NIC）与消费（monitor）串行化。
  semaphore cq_lock;

  // 功能：构造默认配置（MTU 1024，轮询 10ns，响应超时 100us）。
  // 输入/输出及副作用：name 为 UVM 名；创建 cq_lock。
  // 失败/边界：无。
  function new(string name = "rdma_tb_node_cfg");
    super.new(name);
    node_id = 0;
    engine = null;
    cq = null;
    data_mr = null;
    data_mapping = null;
    mtu = 1024;
    ud_qkey = 32'h8001_0000;
    poll_interval = 10ns;
    response_timeout = 100us;
    cq_lock = new(1);
  endfunction

  // 功能：返回 Function owner 句柄。
  // 输入/输出及副作用：只读 engine.binding。
  // 失败/边界：engine 或 binding 为空时返回 null。
  function rdma_function_handle owner();
    if (engine == null || engine.binding == null)
      return null;
    return engine.binding.make_handle();
  endfunction

  // 功能：按本地 QPN 查找 QP 下标。
  // 输入/输出及副作用：index 输出；只读 qps。
  // 失败/边界：未找到返回 0。
  function bit find_qp(bit [23:0] qpn, output int unsigned index);
    index = 0;
    foreach (qps[i]) begin
      if (qps[i] != null && qps[i].qp != null &&
          qps[i].qp.local_qp_id == qpn) begin
        index = i;
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 功能：配置完整性校验。
  // 输入/输出及副作用：只读。
  // 失败/边界：缺 engine/CQ/QP/数据 MR 或 MTU 为零时返回 INVALID_ARGUMENT。
  function rdma_status validate();
    if (engine == null || engine.host_mem == null || engine.manager == null ||
        engine.registry == null || cq == null || qps.size() == 0 ||
        data_mr == null || data_mapping == null || mtu == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               $sformatf("tb node %0d config is incomplete", node_id));
    // 报文按目的 QPN 分发，节点内 QPN 必须唯一。
    foreach (qps[i])
      for (int unsigned j = i + 1; j < qps.size(); j++)
        if (qps[i].qp.local_qp_id == qps[j].qp.local_qp_id)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   $sformatf("tb node %0d has duplicate QPN %0h", node_id,
                                             qps[i].qp.local_qp_id));
    return rdma_status::success();
  endfunction
endclass
