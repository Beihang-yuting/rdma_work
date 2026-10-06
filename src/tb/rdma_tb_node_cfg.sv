// 目录：验证组件层 tb/rdma_tb_node_cfg.sv。
// 层：验证组件。
// 职责：描述一个 RDMA 节点在 tb 中可见的资源：设备模型、驱动模型、CQ、QP 连接表、数据 MR 与其
//   DMA 缓冲，供 agent、wire 和记分板共享。
// 依赖：rdma_dev（设备侧）、rdma_drv_*（主机驱动侧）。
// 所有权：全部为非拥有引用，资源由测试创建。
// 生命周期：测试建立节点后经 env.configure() 下发，仿真期间常驻。

// 本地 QP 与对端 (节点, QP 下标) 的连接关系。
class rdma_tb_qp_link extends uvm_object;
  `rdma_object_utils(rdma_tb_qp_link)

  rdma_drv_qp qp;
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
  // 节点 MAC：wire 按目的 MAC 路由，RC QP 的 AV 与 UD WQE 的 DMAC 指向它。
  bit [47:0] mac;
  rdma_dev dev;
  rdma_drv_dev drv;
  rdma_drv_cq cq;
  // URC QP 专用 CQ（URC 的 frag CQ 取自它，置 urc_flag 后只能轮询 frag）；无 URC QP 时为 null。
  rdma_drv_cq urc_cq;
  rdma_tb_qp_link qps[$];
  // 数据 MR：verb 的本地/远端 buffer 都位于 data_buf 内，MR 覆盖整个 data_buf（VA = IOVA）。
  rdma_drv_mr data_mr;
  rdma_drv_dma data_buf;
  int unsigned mtu;
  // UD 发送使用的 Q_Key（须与对端 UD QP 的 QPC qkey 一致）。
  bit [31:0] ud_qkey;
  time poll_interval;
  // 等待一个 signaled 请求完成的时间基准（driver 等 4 倍）。
  time response_timeout;

  // 功能：构造默认配置（MTU 1024，轮询 10ns，响应超时 100us）。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_tb_node_cfg");
    super.new(name);
    node_id = 0;
    mac = '0;
    dev = null;
    drv = null;
    cq = null;
    urc_cq = null;
    data_mr = null;
    data_buf = null;
    mtu = 1024;
    ud_qkey = 32'h8001_0000;
    poll_interval = 10ns;
    response_timeout = 100us;
  endfunction

  // 功能：配置完整性校验。
  // 输入/输出及副作用：只读。
  // 失败/边界：缺设备/驱动/CQ/QP/数据 MR、MAC 或 MTU 为零时返回 INVALID_ARGUMENT。
  function rdma_status validate();
    if (dev == null || drv == null || cq == null || qps.size() == 0 || data_mr == null ||
        data_buf == null || mac == 0 || mtu == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               $sformatf("tb node %0d config is incomplete", node_id));
    foreach (qps[i])
      if (qps[i] == null || qps[i].qp == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 $sformatf("tb node %0d QP link %0d is empty", node_id, i));
    return rdma_status::success();
  endfunction
endclass
