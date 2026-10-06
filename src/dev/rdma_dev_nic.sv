// 目录：设备层 src/dev/rdma_dev_nic.sv。
// 职责：NIC 数据面行为模型，只依据设备自己的 context 与主机内存工作：
//   TX：SQ doorbell → 按 QPC 的 SQ 基址/深度从设备游标取 polarity 有效的 SQE，校验签名，
//       SGE（WQE 内/SGB/inline）经 MRT（PBL 模式 0/1/2，MODE_2 经 HMC PBLE）翻译后 DMA，
//       按 PMTU 分段经端口发包；RC 等 ACK/READ 响应/ATOMIC ACK；处理完回写 shadow 的
//       HW_DROP_DB_CNT。RX：按目的 QPN 取 QPC，从 shadow 的 RQ PI 判断可用 RQE，散写数据，
//       WRITE/READ/ATOMIC 按 rkey 校验 MRT。完成：按 CQC 的 CQ 基址/大小写 32B CQE，CQ 已 arm 时
//       按 CEQN 的 EQC 写 CEQE。
// 依赖：rdma_dev_cmq（context 与地址翻译）、rdma_host_mem_api（DMA）、rdma_packet、rdma_defs.svh。
// 所有权与生命周期：拥有每 QP/CQ/EQ 的设备运行状态；context 归 rdma_dev_cmq；reset 清空。

// 网络端口：设备按目的 MAC 发包（测试平台的 wire 实现路由）。
virtual class rdma_dev_port extends uvm_object;
  // 功能：构造端口。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_dev_port");
    super.new(name);
  endfunction

  // 功能：发送一个报文到目的 MAC 所在节点。
  // 输入/输出及副作用：由实现投递。
  // 失败/边界：实现自行报告无法投递。
  pure virtual task send(rdma_packet pkt, bit [47:0] dmac);
endclass

// 一个 QP 的设备运行状态。
class rdma_dev_qp_rt extends uvm_object;
  `rdma_object_utils(rdma_dev_qp_rt)

  longint unsigned sq_ci;
  longint unsigned rq_ci;
  int unsigned sq_doorbells;
  // 已投递 TX 但尚未 drain 完的 SQ doorbell 数（flush 据此决定立即执行或排队）。
  int unsigned kicks_pending;
  // URC：已完成的 SQ/RQ WQE 数（经 CEQE 的 HW_CPL 下标上报）。
  longint unsigned urc_sq_cpl;
  longint unsigned urc_rq_cpl;
  // URC 异常完成后 QP 停止处理 SQ（剩余 WQE 由驱动按异常/flush 合成完成）。
  bit urc_error;
  // 当前请求的响应超时（由 QPC RTO_CODE 换算，0 为不超时）。
  time rto;
  bit [23:0] send_psn;
  bit [23:0] expected_psn;
  bit [23:0] msn;
  // 正在接收的 SEND。
  bit rx_active;
  bit rx_failed;
  int unsigned rx_index;
  bit rx_wrap;
  int unsigned rx_offset;
  bit [63:0] rx_sges[$];
  // 正在接收的 WRITE。
  bit [63:0] wr_va;
  bit [31:0] wr_rkey;
  int unsigned wr_len;
  int unsigned wr_offset;
  bit wr_failed;
  // 响应方 PSN 状态：本消息首 PSN、已发 PSN 序列 NAK（等正确 PSN 前不再重复）、RNR 后丢弃本消息
  //   余下报文；ATOMIC 结果按 PSN 缓存以应答重复请求。
  bit [23:0] msg_first_psn;
  bit seq_nak_sent;
  bit rnr_drop;
  bit [63:0] atomic_cache[bit [23:0]];
  mailbox #(rdma_packet) responses;

  // 功能：构造零游标状态。
  // 输入/输出及副作用：创建响应 mailbox。
  // 失败/边界：无。
  function new(string name = "rdma_dev_qp_rt");
    super.new(name);
    sq_ci = 0;
    rq_ci = 0;
    sq_doorbells = 0;
    kicks_pending = 0;
    urc_sq_cpl = 0;
    urc_rq_cpl = 0;
    send_psn = '0;
    expected_psn = '0;
    msn = '0;
    rx_active = 1'b0;
    rx_failed = 1'b0;
    urc_error = 1'b0;
    rto = 0;
    msg_first_psn = '0;
    seq_nak_sent = 1'b0;
    rnr_drop = 1'b0;
    responses = new();
  endfunction
endclass

class rdma_dev_nic extends uvm_object;
  `rdma_object_utils(rdma_dev_nic)

  localparam int unsigned CQE_BYTES = 32;
  localparam int unsigned SGE_BYTES = 16;
  localparam int unsigned PAYLOAD_OFFSET = 32;
  localparam int unsigned QP_SHADOW_OFFSET = 504;
  localparam int unsigned HMC_PBL = 3;
  // TX 队列中标记 QP flush（与 SQ doorbell 共用队列以保持顺序）。
  localparam int unsigned FLUSH_TAG = 32'h8000_0000;
  localparam int unsigned URC_SERVICE_TYPE = 6;
  // 设备保存的 CQC 从 SQE 字节 8 起、EQC 从 SQE 字节 16 起。
  localparam int unsigned CQC_BASE = 8;
  localparam int unsigned EQC_BASE = 16;
  // SRFQC 从 SQE 字节 16 起；SRQ shadow 在 context 页 + (srqn%128)*32 + 28。
  localparam int unsigned SRQC_BASE = 16;
  localparam int unsigned SRQ_CTX_BYTES = 32;
  localparam int unsigned SRQ_SHADOW_OFFSET = 28;
  // 请求方一次尝试的结果。
  localparam int unsigned RSP_OK = 0;
  localparam int unsigned RSP_TIMEOUT = 1;
  localparam int unsigned RSP_RNR = 2;
  localparam int unsigned RSP_SEQ = 3;
  localparam int unsigned RSP_FATAL = 4;
  localparam int unsigned RSP_LOCAL = 5;
  // UD 接收缓冲开头的 GRH 字节数（RoCEv2：IPv4 头放在后 20 字节）。
  localparam int unsigned GRH_BYTES = 40;

  rdma_dev_cmq ctx;
  rdma_host_mem_api host_mem;
  rdma_dev_port port;
  // 观测：因 Q_Key 不符被丢弃的 UD 报文数。
  int unsigned qkey_drops;
  // URC 异常上报通道：0 为 frag CQ 的 ABNML CEQE，1 为 AEQE（驱动两条路径都处理；硬件选择未知）。
  bit urc_abnormal_via_aeq;
  protected rdma_dev_qp_rt qps[int unsigned];
  protected longint unsigned cq_pi[int unsigned];
  protected int unsigned cq_armed[int unsigned];
  protected longint unsigned eq_pi[int unsigned];
  protected longint unsigned srq_ci[int unsigned];
  // SRQ limit：SRFQ doorbell 武装的阈值（WQE 数）；可用 WQE 低于阈值时写 AEQE（0x78）并解除。
  protected int unsigned srq_limit[int unsigned];
  protected mailbox #(int unsigned) sq_kicks;
  protected mailbox #(rdma_packet) rx_mb;
  // 观测：设备检测到的协议错误（签名、地址翻译、超时等）。
  string errors[$];

  // 功能：构造未连接的 NIC。
  // 输入/输出及副作用：创建 mailbox。
  // 失败/边界：run 前须设置 ctx/host_mem/port。
  function new(string name = "rdma_dev_nic");
    super.new(name);
    ctx = null;
    host_mem = null;
    port = null;
    qkey_drops = 0;
    urc_abnormal_via_aeq = 1'b0;
    sq_kicks = new();
    rx_mb = new();
  endfunction

  // 功能：设备复位：清空全部运行状态。
  // 输入/输出及副作用：修改本对象。
  // 失败/边界：无。
  function void reset();
    qps.delete();
    cq_pi.delete();
    cq_armed.delete();
    eq_pi.delete();
    srq_ci.delete();
    srq_limit.delete();
    errors.delete();
  endfunction

  // 功能：新建 context 时丢弃该对象残留的设备运行状态（编号复用）。
  // 输入/输出及副作用：删除对应运行状态。
  // 失败/边界：无。
  function void forget(rdma_dev_kind_e kind, int unsigned id);
    case (kind)
      RDMA_DEV_QP: qps.delete(id);
      RDMA_DEV_CQ: begin
        cq_pi.delete(id);
        cq_armed.delete(id);
      end
      RDMA_DEV_SRQ: begin
        srq_ci.delete(id);
        srq_limit.delete(id);
      end
      default: ;
    endcase
  endfunction

  // 功能：SQ doorbell：值为 SQE 头，按其中 QPN 唤醒 TX。
  // 输入/输出及副作用：记录 doorbell 次数并投递 TX 任务。
  // 失败/边界：无。
  function void sq_doorbell(bit [63:0] value);
    int unsigned qpn;

    qpn = value[RDMA_SQ_WQE_QPN_LSB +: RDMA_SQ_WQE_QPN_WIDTH];
    qp_rt(qpn).sq_doorbells++;
    qp_rt(qpn).kicks_pending++;
    void'(sq_kicks.try_put(qpn));
  endfunction

  // 功能：QP flush doorbell（转 ERR）：该 QP 没有待处理的 SQ 工作时立即写 flush CQE（先于随后的 CMQ
  //   命令，如 QPC_DELETE），否则排入 TX 队列在之前的 SQ doorbell 处理完后执行。
  // 输入/输出及副作用：写 CQE 或投递 TX 任务。
  // 失败/边界：无。
  function void qp_flush(bit [63:0] value);
    int unsigned qpn;

    qpn = value[RDMA_NOTIFY_QP_QPN_LSB +: RDMA_NOTIFY_QP_QPN_WIDTH];
    if (qp_rt(qpn).kicks_pending == 0)
      flush_qp(qpn);
    else
      void'(sq_kicks.try_put(FLUSH_TAG | qpn));
  endfunction

  // 功能：SRFQ doorbell：LIMIT_INVLD=0 时（modify_srq）按 LIMIT（4 个 WQE 为单位）武装 SRQ limit 事件；
  //   post_srq_recv 的 doorbell（LIMIT_INVLD=1）只更新 PI，设备从 shadow 读取，此处无动作。
  // 输入/输出及副作用：修改 srq_limit。
  // 失败/边界：无。
  function void srq_doorbell(bit [63:0] value);
    if (!value[RDMA_NOTIFY_SRQ_LIMIT_INVALID_LSB])
      srq_limit[value[RDMA_NOTIFY_SRFQN_LSB +: RDMA_NOTIFY_SRFQN_WIDTH]] =
        value[RDMA_NOTIFY_SRQ_LIMIT_LSB +: RDMA_NOTIFY_SRQ_LIMIT_WIDTH] * 4;
  endfunction

  // 功能：CQ doorbell：ARM 置位时记录 arm 状态（下一个 CQE 触发 CEQE）。
  // 输入/输出及副作用：修改 cq_armed。
  // 失败/边界：无。
  function void cq_doorbell(bit [63:0] value);
    int unsigned cqn;

    cqn = value[RDMA_NOTIFY_CQ_CQN_LSB +: RDMA_NOTIFY_CQ_CQN_WIDTH];
    if (value[RDMA_NOTIFY_CQ_ARM_LSB])
      cq_armed[cqn] = value[RDMA_NOTIFY_CQ_ARM_ST_LSB +: RDMA_NOTIFY_CQ_ARM_ST_WIDTH];
  endfunction

  // 功能：网络端口收到报文。
  // 输入/输出及副作用：放入 RX 队列。
  // 失败/边界：无。
  function void receive(rdma_packet pkt);
    void'(rx_mb.try_put(pkt));
  endfunction

  // 功能：并行运行 TX 与 RX 循环（永不返回）。
  // 输入/输出及副作用：处理 doorbell 与报文。
  // 失败/边界：无。
  task run();
    fork
      tx_loop();
      rx_loop();
    join
  endtask

  // 功能：TX 循环：按 doorbell 顺序 drain 对应 QP 的 SQ 或执行 QP flush。
  // 输入/输出及副作用：永久循环。
  // 失败/边界：无。
  protected task tx_loop();
    int unsigned qpn;

    forever begin
      sq_kicks.get(qpn);
      if (qpn & FLUSH_TAG) begin
        flush_qp(qpn & ~FLUSH_TAG);
      end
      else begin
        drain_sq(qpn);
        qp_rt(qpn).kicks_pending--;
      end
    end
  endtask

  // 功能：RX 循环：逐个处理收到的报文。
  // 输入/输出及副作用：永久循环。
  // 失败/边界：无。
  protected task rx_loop();
    rdma_packet pkt;

    forever begin
      rx_mb.get(pkt);
      rx_packet(pkt);
    end
  endtask

  // 功能：取（必要时新建）QP 运行状态。
  // 输入/输出及副作用：可能新建对象。
  // 失败/边界：无。
  function rdma_dev_qp_rt qp_rt(int unsigned qpn);
    if (!qps.exists(qpn))
      qps[qpn] = rdma_dev_qp_rt::type_id::create($sformatf("qp_rt_%0d", qpn));
    return qps[qpn];
  endfunction

  // 功能：记录协议错误。
  // 输入/输出及副作用：追加 errors 并报告 UVM_ERROR。
  // 失败/边界：无。
  protected function void protocol_error(string message);
    errors.push_back(message);
    `uvm_error("RDMA_DEV_NIC", message)
  endfunction

  // ---------------------------------------------------------------- DMA 与 MR
  // 功能：按 IOVA 读字节。
  // 输入/输出及副作用：bytes 输出。
  // 失败/边界：DMA 失败返回 0。
  protected function bit dma_read(bit [63:0] iova, int unsigned size, output rdma_bytes_t bytes);
    byte raw[];
    rdma_status status;

    bytes = new[0];
    status = host_mem.dma_read(iova, size, raw);
    if (!status.ok())
      return 1'b0;
    bytes = new[raw.size()];
    foreach (raw[i])
      bytes[i] = raw[i];
    return 1'b1;
  endfunction

  // 功能：按 IOVA 写字节。
  // 输入/输出及副作用：写主机内存。
  // 失败/边界：DMA 失败返回 0。
  protected function bit dma_write(bit [63:0] iova, byte unsigned bytes[]);
    byte raw[];
    rdma_status status;

    raw = new[bytes.size()];
    foreach (raw[i])
      raw[i] = bytes[i];
    status = host_mem.dma_write(iova, raw);
    return status.ok();
  endfunction

  // 功能：MR 地址翻译：key 的 STAG_IDX 找 MRT，校验 STAG_KEY、状态 VALID、PD、权限位与 [va, va+len)
  //   在 MR 范围内；按 PBL 模式求每个 4KiB 页的 DMA 地址，输出按页切分的 {iova, len} 段。
  // 输入/输出及副作用：segs 输出 iova/len 交替；MODE_2 读 PBLE。
  // 失败/边界：任一校验失败返回 0。
  protected function bit translate(bit [31:0] key, int unsigned pd, bit [4:0] need,
                                   bit [63:0] va, int unsigned len, output bit [63:0] segs[$]);
    rdma_dev_object mrt;
    bit [63:0] start;
    longint unsigned mr_len;
    longint unsigned off;
    longint unsigned page_off;
    int unsigned take;
    bit [63:0] page;
    int unsigned mode;

    segs.delete();
    if (!ctx.lookup(RDMA_DEV_MR, key >> 8, mrt))
      return 1'b0;
    if (`RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_STAG_KEY) != key[7:0] ||
        `RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_ST) != RDMA_MR_ST_VALID ||
        `RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_PD_IDX) != pd ||
        (`RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_RIGHT) & need) != need)
      return 1'b0;
    start = `RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_START_VA);
    mr_len = `RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_LEN);
    if (va < start || va + len > start + mr_len)
      return 1'b0;
    mode = `RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_PBL_MODE);
    off = va - (start & ~64'hfff);
    while (len != 0) begin
      page_off = off % RDMA_HMC_PAGE_BYTES;
      take = RDMA_HMC_PAGE_BYTES - page_off;
      if (take > len)
        take = len;
      if (mode == RDMA_PBL_MODE_0)
        page = (`RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_PAYLOAD_PBA0) << 12) +
               (off / RDMA_HMC_PAGE_BYTES) * RDMA_HMC_PAGE_BYTES;
      else if (mode == RDMA_PBL_MODE_1 && off < RDMA_HMC_PAGE_BYTES)
        page = `RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_PAYLOAD_PBA0) << 12;
      else if (mode == RDMA_PBL_MODE_1)
        page = `RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_PAYLOAD_PBA1) << 12;
      else if (!read_pble(`RDMA_BE_GET(mrt.bytes, RDMA_MRT_BODY_FIRST_PBL_IDX) +
                          off / RDMA_HMC_PAGE_BYTES, page))
        return 1'b0;
      segs.push_back(page + page_off);
      segs.push_back(take);
      off += take;
      len -= take;
    end
    return 1'b1;
  endfunction

  // 功能：读第 idx 个 PBLE（HMC PBL 对象区），返回页地址（去掉 VLD 位）。
  // 输入/输出及副作用：page 输出；DMA 读。
  // 失败/边界：翻译失败或 VLD=0 返回 0。
  protected function bit read_pble(longint unsigned idx, output bit [63:0] page);
    bit [63:0] iova;
    rdma_bytes_t entry;
    rdma_status status;

    page = '0;
    status = ctx.hmc_addr(HMC_PBL, idx * 8, iova);
    if (!status.ok() || !dma_read(iova, 8, entry))
      return 1'b0;
    page = rdma_be::qword(entry, 0);
    if (!page[0])
      return 1'b0;
    page[0] = 1'b0;
    return 1'b1;
  endfunction

  // 功能：按 SGE 列表（{key, va, len} 三元组）读出数据。
  // 输入/输出及副作用：data 输出。
  // 失败/边界：翻译或 DMA 失败返回 0。
  protected function bit gather(bit [63:0] sges[$], int unsigned pd, output rdma_bytes_t data);
    bit [63:0] segs[$];
    rdma_bytes_t part;

    data = new[0];
    for (int i = 0; i < sges.size(); i += 3) begin
      if (!translate(sges[i], pd, 5'h0, sges[i + 1], sges[i + 2], segs))
        return 1'b0;
      for (int k = 0; k < segs.size(); k += 2) begin
        if (!dma_read(segs[k], segs[k + 1], part))
          return 1'b0;
        data = {data, part};
      end
    end
    return 1'b1;
  endfunction

  // 功能：把 data 从消息偏移 offset 起按 need 权限散写到 SGE 列表。
  // 输入/输出及副作用：写主机内存。
  // 失败/边界：超出容量或翻译/DMA 失败返回 0。
  protected function bit scatter(bit [63:0] sges[$], int unsigned pd, bit [4:0] need,
                                 int unsigned offset, byte unsigned data[]);
    int unsigned pos;
    longint unsigned base;
    int unsigned start;
    int unsigned take;
    bit [63:0] segs[$];
    int unsigned done;

    pos = 0;
    base = 0;
    for (int i = 0; i < sges.size() && pos < data.size(); i += 3) begin
      if (offset + pos < base + sges[i + 2]) begin
        start = offset + pos - base;
        take = sges[i + 2] - start;
        if (take > data.size() - pos)
          take = data.size() - pos;
        if (!translate(sges[i], pd, need, sges[i + 1] + start, take, segs))
          return 1'b0;
        done = 0;
        for (int k = 0; k < segs.size(); k += 2) begin
          if (!dma_write(segs[k], rdma_be::slice(data, pos + done, segs[k + 1])))
            return 1'b0;
          done += segs[k + 1];
        end
        pos += take;
      end
      base += sges[i + 2];
    end
    return pos == data.size();
  endfunction

  // 功能：解析 n 个 16B SGE 描述符为 {key, va, len} 三元组。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function void parse_sges(byte unsigned desc[], int unsigned n,
                                     output bit [63:0] sges[$]);
    bit [63:0] w0;

    sges.delete();
    for (int unsigned i = 0; i < n; i++) begin
      w0 = rdma_be::qword(desc, i * SGE_BYTES);
      sges.push_back(w0[31:0]);
      sges.push_back(rdma_be::qword(desc, i * SGE_BYTES + 8));
      sges.push_back(w0[62:32]);
    end
  endfunction

  // ---------------------------------------------------------------- context 读取
  // 功能：取 QPC 字段。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：QP 不存在返回 0。
  protected function bit [63:0] qpc_field(int unsigned qpn, int unsigned word_byte,
                                          int unsigned lsb, int unsigned width);
    rdma_dev_object obj;

    if (!ctx.lookup(RDMA_DEV_QP, qpn, obj))
      return '0;
    return rdma_be::field(obj.bytes, word_byte, lsb, width);
  endfunction

  `define RDMA_QPC(QPN, STEM) qpc_field(QPN, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH)

  // 功能：QP 的 SQ/RQ 槽地址（QPC 的 PBA/OM，深度 2^SIZE）。
  // 输入/输出及副作用：iova/depth 输出。
  // 失败/边界：翻译失败返回 0。
  protected function bit wq_slot(int unsigned qpn, bit rq, longint unsigned index,
                                 output bit [63:0] iova, output int unsigned depth);
    bit [63:0] pba;
    int unsigned om;
    rdma_status status;

    if (rq) begin
      pba = `RDMA_QPC(qpn, RDMA_QPC_RQ_PBA);
      om = `RDMA_QPC(qpn, RDMA_QPC_RQ_OM);
      depth = 1 << `RDMA_QPC(qpn, RDMA_QPC_RQ_SIZE);
    end
    else begin
      pba = `RDMA_QPC(qpn, RDMA_QPC_SQ_PBA);
      om = `RDMA_QPC(qpn, RDMA_QPC_SQ_OM);
      depth = 1 << `RDMA_QPC(qpn, RDMA_QPC_SQ_SIZE);
    end
    status = ctx.buffer_addr(om, pba, (index % depth) * RDMA_WQE_BYTES, iova);
    return status.ok();
  endfunction

  // 功能：QP shadow 地址（QPC SHADOW_PBA<<9 + 504）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  protected function bit [63:0] qp_shadow(int unsigned qpn);
    return (`RDMA_QPC(qpn, RDMA_QPC_SHADOW_PBA) << 9) + QP_SHADOW_OFFSET;
  endfunction

  // ---------------------------------------------------------------- TX
  // 功能：QP 是否为 URC（QPC 服务类型 6）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：QP 不存在返回 0。
  protected function bit is_urc(int unsigned qpn);
    return `RDMA_QPC(qpn, RDMA_QPC_SERVICE_TYPE) == URC_SERVICE_TYPE;
  endfunction

  // 功能：URC 完成（假设：每完成一个 WQE 即上报，不依赖 arm）：RQ 完成在 RQ frag 的
  //   URC_CQ_START_IDX + (n % RQ 深度) 槽写 32B CQE（polarity 按 RQ 圈数，首圈 1）；SQ 完成只计数；
  //   随后向该 frag 的 CEQ 写 URC CEQE，携带本 QP 的 HW_CPL SQ/RQ 下标。
  // 输入/输出及副作用：DMA 写 CQ/CEQ，推进 URC 完成计数。
  // 失败/边界：frag CQ 不存在或写失败报告协议错误。
  protected function void urc_complete(int unsigned qpn, bit rq, int unsigned wqe_index,
                                       bit [7:0] ecode, int unsigned byte_len, bit [31:0] imm);
    rdma_dev_qp_rt rt;
    rdma_dev_object cqc;
    rdma_bytes_t cqe;
    bit [63:0] slot;
    int unsigned cqn;
    int unsigned rq_size;
    longint unsigned n;
    rdma_status status;

    rt = qp_rt(qpn);
    if (!rq) begin
      rt.urc_sq_cpl++;
      urc_ceqe(qpn, `RDMA_QPC(qpn, RDMA_QPC_SQ_CQN), 8'h00, 1'b0, 1'b0);
      return;
    end
    cqn = `RDMA_QPC(qpn, RDMA_QPC_RQ_CQN);
    if (!ctx.lookup(RDMA_DEV_CQ, cqn, cqc)) begin
      protocol_error($sformatf("URC QP %0d completes to absent CQ %0d", qpn, cqn));
      return;
    end
    rq_size = 1 << `RDMA_QPC(qpn, RDMA_QPC_RQ_SIZE);
    n = rt.urc_rq_cpl;
    status = ctx.buffer_addr(`RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CQ_OM, CQC_BASE),
                             `RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CUR_CQ_PD_PBA, CQC_BASE),
                             (`RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_URC_CQ_START_IDX, CQC_BASE) +
                              n % rq_size) * CQE_BYTES, slot);
    cqe = rdma_be::zeros(CQE_BYTES);
    `RDMA_BE_SET(cqe, RDMA_CQE_POLARITY, !((n / rq_size) & 1))
    `RDMA_BE_SET(cqe, RDMA_CQE_RQ_CQE, 1)
    `RDMA_BE_SET(cqe, RDMA_CQE_WQE_INDEX, wqe_index)
    `RDMA_BE_SET(cqe, RDMA_CQE_PKT_OPCODE, 8'h01)
    `RDMA_BE_SET(cqe, RDMA_CQE_ECODE, ecode)
    `RDMA_BE_SET(cqe, RDMA_CQE_QPN, qpn)
    `RDMA_BE_SET(cqe, RDMA_CQE_IMMDT_DATA, imm)
    `RDMA_BE_SET(cqe, RDMA_CQE_PAYLOAD_LEN, byte_len)
    if (!status.ok() || !dma_write(slot, cqe)) begin
      protocol_error($sformatf("URC QP %0d RQ CQE write failed", qpn));
      return;
    end
    rt.urc_rq_cpl = n + 1;
    urc_ceqe(qpn, cqn, 8'h00, 1'b0, 1'b0);
  endfunction

  // 功能：向 frag CQ 的 CEQ 写 URC CEQE：URC_FLAG、QPN、CQN、ECODE、flush 时的 SQ/RQ 有效位，
  //   qword1 的 HW_CPL SQ（cqn 为 QP 的 SQ CQ 时）与 RQ（cqn 为 RQ CQ 时）{wrap, 下标}。
  // 输入/输出及副作用：DMA 写 CEQ。
  // 失败/边界：CQ 不存在报告协议错误。
  protected function void urc_ceqe(int unsigned qpn, int unsigned cqn, bit [7:0] ecode,
                                   bit sq_vld, bit rq_vld);
    rdma_dev_object cqc;
    rdma_dev_qp_rt rt;
    rdma_bytes_t ceqe;
    int unsigned size;

    if (!ctx.lookup(RDMA_DEV_CQ, cqn, cqc)) begin
      protocol_error($sformatf("URC QP %0d notifies absent CQ %0d", qpn, cqn));
      return;
    end
    rt = qp_rt(qpn);
    ceqe = rdma_be::zeros(RDMA_CEQE_BYTES);
    `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_FLAG, 1)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_QPN, qpn)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_SQ_CQE_VALID, sq_vld)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_RQ_CQE_VALID, rq_vld)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_CQN, cqn)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_ECODE, ecode)
    if (`RDMA_QPC(qpn, RDMA_QPC_SQ_CQN) == cqn) begin
      size = 1 << `RDMA_QPC(qpn, RDMA_QPC_SQ_SIZE);
      `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_HW_CPL_SQ_WQE_IDX, rt.urc_sq_cpl % size)
      `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_HW_CPL_SQ_WQE_IDX_WRAP, (rt.urc_sq_cpl / size) & 1)
    end
    if (`RDMA_QPC(qpn, RDMA_QPC_RQ_CQN) == cqn) begin
      size = 1 << `RDMA_QPC(qpn, RDMA_QPC_RQ_SIZE);
      `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_HW_CPL_RQ_WQE_IDX, rt.urc_rq_cpl % size)
      `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_HW_CPL_RQ_WQE_IDX_WRAP, (rt.urc_rq_cpl / size) & 1)
    end
    write_eqe(RDMA_DEV_CEQ, `RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CEQN, CQC_BASE), ceqe);
  endfunction

  // 功能：URC 异常完成（event.c urc_eq_update_abnml_info）：urc_abnormal_via_aeq 时写 URC AEQE，否则
  //   向 SQ（rq=0）或 RQ（rq=1）的 frag CQ 写 ABNML CEQE（类型 1/2、ECODE、远端 syndrome、
  //   异常 WQE 位置 = 当前已完成数 {wrap, idx}），
  //   HW_CPL 不推进；QP 进入错误，不再处理 SQ。
  // 输入/输出及副作用：DMA 写 CEQ 或 AEQ；置 urc_error。
  // 失败/边界：CQ 不存在报告协议错误。
  protected function void urc_abnormal(int unsigned qpn, bit rq, bit [7:0] ecode,
                                       bit [7:0] remote);
    rdma_dev_object cqc;
    rdma_dev_qp_rt rt;
    rdma_bytes_t ceqe;
    int unsigned cqn;
    int unsigned size;
    longint unsigned pos;

    rt = qp_rt(qpn);
    cqn = rq ? `RDMA_QPC(qpn, RDMA_QPC_RQ_CQN) : `RDMA_QPC(qpn, RDMA_QPC_SQ_CQN);
    size = 1 << (rq ? `RDMA_QPC(qpn, RDMA_QPC_RQ_SIZE) : `RDMA_QPC(qpn, RDMA_QPC_SQ_SIZE));
    pos = rq ? rt.urc_rq_cpl : rt.urc_sq_cpl;
    rt.urc_error = 1'b1;
    if (urc_abnormal_via_aeq) begin
      urc_abnormal_aeqe(qpn, rq, ecode, remote, pos, size);
      return;
    end
    if (!ctx.lookup(RDMA_DEV_CQ, cqn, cqc)) begin
      protocol_error($sformatf("URC QP %0d abnormal completion to absent CQ %0d", qpn, cqn));
      return;
    end
    ceqe = rdma_be::zeros(RDMA_CEQE_BYTES);
    `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_FLAG, 1)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_QPN, qpn)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_CQN, cqn)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_ECODE, ecode)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_ABNML_CQE_TYPE, rq ? 2 : 1)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_ABNML_CQE_REMOTE_ECODE, remote)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_ABNML_CQE_WQE_IDX, pos % size)
    `RDMA_BE_SET(ceqe, RDMA_CEQE_URC_ABNML_CQE_WQE_IDX_WRAP, (pos / size) & 1)
    write_eqe(RDMA_DEV_CEQ, `RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CEQN, CQC_BASE), ceqe);
  endfunction

  // 功能：URC 异常经 AEQ 上报（event.c get_aeqe_info / qp 类错误分支）：AEQE 带 URC_FLAG、异常类型、
  //   ECODE、QPN、远端 syndrome 与异常 WQE 位置 {wrap, idx}。
  // 输入/输出及副作用：DMA 写 AEQ。
  // 失败/边界：无 AEQ 报告协议错误。
  protected function void urc_abnormal_aeqe(int unsigned qpn, bit rq, bit [7:0] ecode,
                                            bit [7:0] remote, longint unsigned pos,
                                            int unsigned size);
    rdma_bytes_t aeqe;
    int unsigned aeqn;

    aeqe = rdma_be::zeros(RDMA_AEQE_BYTES);
    `RDMA_BE_SET(aeqe, RDMA_AEQE_URC_FLAG, 1)
    `RDMA_BE_SET(aeqe, RDMA_AEQE_URC_ABNML_CQE_TYPE, rq ? 2 : 1)
    `RDMA_BE_SET(aeqe, RDMA_AEQE_ECODE, ecode)
    `RDMA_BE_SET(aeqe, RDMA_AEQE_QPN, qpn)
    `RDMA_BE_SET(aeqe, RDMA_AEQE_URC_REMOTE_ECODE, remote)
    `RDMA_BE_SET(aeqe, RDMA_AEQE_WQE_INDEX, pos % size)
    `RDMA_BE_SET(aeqe, RDMA_AEQE_WQE_WRAP, (pos / size) & 1)
    if (!ctx.first_id(RDMA_DEV_AEQ, aeqn)) begin
      protocol_error("URC abnormal event without an AEQ");
      return;
    end
    write_eqe(RDMA_DEV_AEQ, aeqn, aeqe);
  endfunction

  // 功能：QP flush：向 SQ CQ 写一个 SQ flush CQE（0x08），非 SRQ 时向 RQ CQ 写一个 RQ flush CQE（0x8F）；
  //   驱动以每个 flush CQE 为对应环中全部未完成 WQE 生成 FLUSH 完成。
  // 输入/输出及副作用：写 CQE。
  // 失败/边界：QP 不存在时报告协议错误。
  protected function void flush_qp(int unsigned qpn);
    rdma_dev_object obj;

    if (!ctx.lookup(RDMA_DEV_QP, qpn, obj)) begin
      protocol_error($sformatf("flush doorbell for absent QP %0d", qpn));
      return;
    end
    if (is_urc(qpn)) begin
      // URC：flush 经 CEQE 上报（CQC_MODIFY 的 SQ/RQ_CEQE_VLD），驱动据此合成 FLUSH 完成。
      urc_ceqe(qpn, `RDMA_QPC(qpn, RDMA_QPC_SQ_CQN), RDMA_ECODE_EC_TPE_QP_FLUSH, 1'b1, 1'b0);
      urc_ceqe(qpn, `RDMA_QPC(qpn, RDMA_QPC_RQ_CQN), RDMA_ECODE_EC_RPE_RX_FLUSH, 1'b0, 1'b1);
      return;
    end
    write_cqe(qpn, 1'b0, 0, 1'b0, RDMA_ECODE_XTRDMA_CQE_ECODE_SQ_FLUSH_ERR, 0, '0, 0);
    if (!`RDMA_QPC(qpn, RDMA_QPC_RC_SRFQ))
      write_cqe(qpn, 1'b1, 0, 1'b0, RDMA_ECODE_XTRDMA_CQE_ECODE_RQ_FLUSH_ERR, 0, '0, 0);
  endfunction

  // 功能：drain SQ：从设备游标起处理所有 polarity 有效的 SQE；完毕后把 HW_DROP_DB_CNT 写为已见
  //   doorbell 数（驱动据此判断可再次敲 doorbell）。
  // 输入/输出及副作用：处理 WQE、写 shadow。
  // 失败/边界：QP 不存在或 SQ 不可读报告协议错误。
  task drain_sq(int unsigned qpn);
    rdma_dev_qp_rt rt;
    bit [63:0] slot;
    int unsigned depth;
    rdma_bytes_t wqe;
    rdma_bytes_t cnt;
    rdma_dev_object obj;
    bit ok;

    if (!ctx.lookup(RDMA_DEV_QP, qpn, obj)) begin
      protocol_error($sformatf("SQ doorbell for absent QP %0d", qpn));
      return;
    end
    rt = qp_rt(qpn);
    forever begin
      // wq_slot 的输出与同一表达式中的读取顺序不保证，分两句写。
      ok = wq_slot(qpn, 1'b0, rt.sq_ci, slot, depth);
      if (ok)
        ok = dma_read(slot, RDMA_WQE_BYTES, wqe);
      if (!ok) begin
        protocol_error($sformatf("QP %0d SQ slot %0d is not readable", qpn, rt.sq_ci));
        break;
      end
      if (rdma_be::field(wqe, 0, RDMA_SQ_WQE_VALID_LSB, 1) != !((rt.sq_ci / depth) & 1))
        break;
      if (rt.urc_error)
        break;
      process_sqe(qpn, rt, wqe);
      rt.sq_ci++;
    end
    cnt = rdma_be::zeros(1);
    cnt[0] = rt.sq_doorbells & 7'h7f;
    void'(dma_write(qp_shadow(qpn) + 1, cnt));
  endtask

  // 功能：取 SQE 的数据区：inline（WQE 内或 SGB）或 SGE 描述符（WQE 内或 SGB），并校验签名
  //   （头、WQE 其余字节与使用中的 SGB 部分异或，含签名应为 0xff）。
  // 输入/输出及副作用：sges/inline_data/payload 输出；读 SGB。
  // 失败/边界：签名不符或 SGB 读失败返回 0。
  protected function bit sqe_data(int unsigned qpn, rdma_bytes_t wqe, bit ud,
                                  output bit [63:0] sges[$], output rdma_bytes_t inline_data,
                                  output int unsigned payload);
    bit inl;
    bit use_sgb;
    int unsigned sge_num;
    rdma_bytes_t area;
    bit [7:0] sum;

    sges.delete();
    inline_data = new[0];
    inl = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD);
    if (ud) begin
      sge_num = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_UD_SGE_NUM);
      payload = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN);
    end
    else begin
      sge_num = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_RC_SGE_NUM);
      payload = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN);
    end
    use_sgb = ud;
    if (!ud && payload != 0) begin
      if (inl)
        use_sgb = payload > 32;
      else
        use_sgb = sge_num > 2;
    end
    area = rdma_be::slice(wqe, PAYLOAD_OFFSET, 32);
    // dma_read 的输出参数放在短路表达式里会被 VCS 无条件清空，单独成句。
    if (use_sgb) begin
      if (!dma_read(`RDMA_BE_GET(wqe, RDMA_SQ_WQE_SGB_PA) << 9, sge_num * SGE_BYTES, area))
        return 1'b0;
    end
    sum = rdma_be::xor_bytes(wqe);
    if (use_sgb)
      sum ^= rdma_be::xor_bytes(area);
    if (sum != 8'hff) begin
      protocol_error($sformatf("QP %0d SQE signature mismatch", qpn));
      return 1'b0;
    end
    if (inl)
      inline_data = rdma_be::slice(area, 0, payload);
    else
      parse_sges(area, sge_num, sges);
    return 1'b1;
  endfunction

  // 功能：执行一个 SQE：本地准备（签名、SGE/inline 取数）后 UD 直接发包；RC/URC 经 run_request
  //   带重传/RNR 重试执行；结果按 RC 写 SQ CQE（CE 或出错时）或按 URC 推进 HW_CPL/上报异常。
  // 输入/输出及副作用：DMA、发包、写 CQE/CEQE。
  // 失败/边界：签名错以 WQE_SIGN_ERR、本地访问错以 SQ_KEY_ERR 完成；远端错误见 run_request。
  protected task process_sqe(int unsigned qpn, rdma_dev_qp_rt rt, rdma_bytes_t wqe);
    bit [63:0] sges[$];
    rdma_bytes_t data;
    int unsigned payload;
    int unsigned pd;
    bit ud;
    bit [3:0] op;
    bit [7:0] ecode;
    bit [7:0] synd;
    bit [23:0] dst_qpn;
    bit [47:0] dmac;
    int unsigned byte_len;

    ud = `RDMA_QPC(qpn, RDMA_QPC_SERVICE_TYPE) == 3;
    pd = `RDMA_QPC(qpn, RDMA_QPC_PD_IDX);
    op = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_OPCODE);
    dst_qpn = `RDMA_QPC(qpn, RDMA_QPC_DST_QPN);
    dmac = `RDMA_QPC(qpn, RDMA_QPC_DMAC);
    if (ud) begin
      dst_qpn = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_UD_DST_QPN);
      dmac = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_UD_DMAC);
    end
    ecode = RDMA_CMQ_SUCCESS_ECODE;
    synd = '0;
    byte_len = 0;
    data = new[0];
    if (op inside {RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP, RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD}) begin
      byte_len = 8;
      if (rdma_be::xor_bytes(wqe) != 8'hff) begin
        protocol_error($sformatf("QP %0d SQE signature mismatch", qpn));
        ecode = RDMA_ECODE_EC_TPE_SQ_WQE_SIGN_ERR;
      end
    end
    else if (!sqe_data(qpn, wqe, ud, sges, data, payload))
      ecode = RDMA_ECODE_EC_TPE_SQ_WQE_SIGN_ERR;
    else if (op == RDMA_SQ_OPCODE_READ)
      byte_len = payload;
    else begin
      // gather 的输出参数不能放进短路表达式（VCS 会无条件清空 inline 数据），单独成句。
      if (data.size() == 0 && sges.size() != 0) begin
        if (!gather(sges, pd, data))
          ecode = RDMA_ECODE_EC_TPE_SQ_KEY_ERR;
      end
      byte_len = data.size();
    end
    if (ecode == RDMA_CMQ_SUCCESS_ECODE) begin
      if (ud)
        send_message(qpn, rt, net_opcode(op), data, wqe, dst_qpn, dmac, 1'b1);
      else
        run_request(qpn, rt, wqe, op, sges, data, pd, payload, dst_qpn, dmac, ecode, synd);
    end
    if (is_urc(qpn)) begin
      if (ecode == RDMA_CMQ_SUCCESS_ECODE)
        urc_complete(qpn, 1'b0, `RDMA_BE_GET(wqe, RDMA_SQ_WQE_INDEX), ecode, byte_len, '0);
      else
        urc_abnormal(qpn, 1'b0, ecode, synd);
    end
    else if (`RDMA_BE_GET(wqe, RDMA_SQ_WQE_CE) != 0 || ecode != RDMA_CMQ_SUCCESS_ECODE)
      write_cqe(qpn, 1'b0, `RDMA_BE_GET(wqe, RDMA_SQ_WQE_INDEX),
                `RDMA_BE_GET(wqe, RDMA_SQ_WQE_WRAP), ecode, byte_len, '0, 0, synd);
  endtask

  // 功能：RC/URC 请求的重传循环。PSN 序列 NAK 从 NAK 指出的 PSN 起重发（READ 从第一个缺失的响应
  //   PSN 起重新请求剩余部分）；超时时 SEND/WRITE 从首 PSN 重发、READ 从第一个缺失的响应起；两者消耗
  //   PSN_RETRY_TH（耗尽为 0x16/0x18）。RNR NAK 按其 syndrome 低 5 位的 RNR 定时器编码等待后从首 PSN
  //   重发，消耗 RNR_RETRY_TH（7 为无限，耗尽为 0xB7）。其余 NAK 为致命错误（0xB9，synd 为远端
  //   syndrome）。ACK/READ 响应/ATOMIC ACK 完成。响应超时由 QPC RTO_CODE 换算（rto_time）。
  // 输入/输出及副作用：发包、写本地内存；send_psn 结束于首 PSN + 分段数；ecode/synd 输出。
  // 失败/边界：本地写失败以 SQ_KEY_ERR 结束。
  protected task run_request(int unsigned qpn, rdma_dev_qp_rt rt, rdma_bytes_t wqe, bit [3:0] op,
                             bit [63:0] sges[$], rdma_bytes_t data, int unsigned pd,
                             int unsigned payload, bit [23:0] dst_qpn, bit [47:0] dmac,
                             output bit [7:0] ecode, output bit [7:0] synd);
    bit [23:0] start;
    bit [23:0] nak_psn;
    int unsigned retries;
    int unsigned rnrs;
    int unsigned outcome;
    int unsigned segs;
    int unsigned from;
    int unsigned resume;
    rdma_packet junk;

    start = rt.send_psn;
    rt.rto = rto_time(`RDMA_QPC(qpn, RDMA_QPC_RTO_CODE));
    retries = `RDMA_QPC(qpn, RDMA_QPC_PSN_RETRY_TH);
    rnrs = `RDMA_QPC(qpn, RDMA_QPC_RNR_RETRY_TH);
    segs = (payload + mtu(qpn) - 1) / mtu(qpn);
    if (segs == 0)
      segs = 1;
    from = 0;
    synd = '0;
    forever begin
      rt.send_psn = start + from;
      while (rt.responses.try_get(junk))
        ;
      ecode = RDMA_CMQ_SUCCESS_ECODE;
      resume = 0;
      if (op inside {RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP, RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD})
        do_atomic(qpn, rt, wqe, pd, dmac, outcome, synd, ecode);
      else if (op == RDMA_SQ_OPCODE_READ)
        do_read(qpn, rt, wqe, sges, pd, payload, dmac, start, from, outcome, synd, ecode, resume);
      else begin
        send_message(qpn, rt, net_opcode(op), data, wqe, dst_qpn, dmac, 1'b0, from);
        wait_ack(rt, start, outcome, synd, nak_psn);
        if (outcome == RSP_SEQ)
          resume = 24'(nak_psn - start);
      end
      case (outcome)
        RSP_OK: return;
        RSP_LOCAL: return;
        RSP_FATAL: begin
          ecode = RDMA_ECODE_EC_RPE_NAK_FATAL_ERR;
          return;
        end
        RSP_RNR: begin
          if (rnrs == 0) begin
            ecode = RDMA_ECODE_EC_RPE_RSP_NAK_RNR_ERR_OVERTIME;
            return;
          end
          if (rnrs != 7)
            rnrs--;
          #(rnr_time(5'(synd)));
          from = 0;
        end
        default: begin
          if (retries == 0) begin
            ecode = RDMA_ECODE_EC_TPE_SQ_RTO_OVERTIME;
            if (outcome == RSP_SEQ)
              ecode = RDMA_ECODE_EC_TPE_SQ_PSN_ERR_OVERTIME;
            return;
          end
          retries--;
          from = resume < segs ? resume : 0;
        end
      endcase
    end
  endtask

  // 功能：QPC RTO_CODE（硬件时间编码）→ 响应超时。假设：硬件编码表未公开，取驱动
  //   xtrdma_rto_code_map（IB timeout t → 编码）的逆：编码 c 的时长为映射到它的 IB 超时
  //   4.096us * 2^t，即 0:8.192us 1:16.384us 3:32.768us 7:65.536us 11:131.072us 15:262.144us，
  //   17..30 为 4.096us * 2^(c-10)；未被映射的编码取不大于它的最近映射编码的时长；31（IB t=0）为
  //   不超时，返回 0。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function time rto_time(bit [4:0] code);
    if (code == 31)
      return 0;
    if (code >= 17)
      return 4096ns * (64'd1 << (code - 10));
    if (code >= 15)
      return 262144ns;
    if (code >= 11)
      return 131072ns;
    if (code >= 7)
      return 65536ns;
    if (code >= 3)
      return 32768ns;
    if (code >= 1)
      return 16384ns;
    return 8192ns;
  endfunction

  // 功能：IB RNR 定时器编码 → 等待时间（0 为 655.36ms，1..31 为 0.01ms..491.52ms）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function time rnr_time(bit [4:0] code);
    int unsigned table_us[32] = '{655360, 10, 20, 30, 40, 60, 80, 120, 160, 240, 320, 480, 640,
                                   960, 1280, 1920, 2560, 3840, 5120, 7680, 10240, 15360, 20480,
                                   30720, 40960, 61440, 81920, 122880, 163840, 245760, 327680,
                                   491520};

    return table_us[code] * 1us;
  endfunction

  // 功能：本端 RNR NAK 的 syndrome：001 + QPC LOCAL_RNR_CODE（最小 RNR 定时器编码）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  protected function bit [7:0] rnr_syndrome(int unsigned qpn);
    return RDMA_AETH_RNR_NAK | 8'(`RDMA_QPC(qpn, RDMA_QPC_LOCAL_RNR_CODE));
  endfunction

  // 功能：SQ WQE opcode → 网络 opcode。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：其余按 SEND。
  protected function rdma_network_opcode_e net_opcode(bit [3:0] op);
    case (op)
      RDMA_SQ_OPCODE_SEND_WITH_IMM: return RDMA_NET_SEND_WITH_IMM;
      RDMA_SQ_OPCODE_WRITE: return RDMA_NET_RDMA_WRITE;
      RDMA_SQ_OPCODE_WRITE_WITH_IMM: return RDMA_NET_WRITE_WITH_IMM;
      default: return RDMA_NET_SEND;
    endcase
  endfunction

  // 功能：PMTU 字节数（QPC PMTU 编码：256<<code）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  protected function int unsigned mtu(int unsigned qpn);
    return 256 << `RDMA_QPC(qpn, RDMA_QPC_PMTU);
  endfunction

  // 功能：构造报文骨架（第 k 个/共 count 个分段）。
  // 输入/输出及副作用：返回新报文。
  // 失败/边界：无。
  protected function rdma_packet new_packet(int unsigned qpn, rdma_network_opcode_e op,
                                            int unsigned k, int unsigned count, bit [23:0] psn,
                                            bit [23:0] dst_qpn, bit ud);
    rdma_packet pkt;

    pkt = rdma_packet::type_id::create("dev_packet");
    pkt.transport = RDMA_TRANSPORT_RC;
    if (ud)
      pkt.transport = RDMA_TRANSPORT_UD;
    else if (is_urc(qpn))
      pkt.transport = RDMA_TRANSPORT_URC;
    pkt.opcode = op;
    pkt.segment = RDMA_SEG_MIDDLE;
    if (count == 1)
      pkt.segment = RDMA_SEG_ONLY;
    else if (k == 0)
      pkt.segment = RDMA_SEG_FIRST;
    else if (k == count - 1)
      pkt.segment = RDMA_SEG_LAST;
    pkt.source_qpn = qpn;
    pkt.destination_qpn = dst_qpn;
    pkt.psn = psn;
    return pkt;
  endfunction

  // 功能：序列化扩展头并经端口发送。
  // 输入/输出及副作用：发包。
  // 失败/边界：无。
  protected task emit(rdma_packet pkt, bit [47:0] dmac);
    pkt.pack_headers();
    port.send(pkt, dmac);
  endtask

  // 功能：按 PMTU 分段发送一条消息（WRITE 带 RETH，立即数带 ImmDt，UD 带 DETH Q_Key），从第 from
  //   个分段起（重传时从中间分段继续，PSN 取 send_psn）。
  // 输入/输出及副作用：推进 send_psn，经端口发包。
  // 失败/边界：空负载发一个零长度单包。
  protected task send_message(int unsigned qpn, rdma_dev_qp_rt rt, rdma_network_opcode_e op,
                              rdma_bytes_t payload, rdma_bytes_t wqe, bit [23:0] dst_qpn,
                              bit [47:0] dmac, bit ud, int unsigned from = 0);
    int unsigned count;
    int unsigned start;
    int unsigned take;
    rdma_packet pkt;

    count = (payload.size() + mtu(qpn) - 1) / mtu(qpn);
    if (count == 0)
      count = 1;
    for (int unsigned k = from; k < count; k++) begin
      pkt = new_packet(qpn, op, k, count, rt.send_psn, dst_qpn, ud);
      rt.send_psn++;
      start = k * mtu(qpn);
      take = payload.size() - start;
      if (take > mtu(qpn))
        take = mtu(qpn);
      for (int unsigned b = 0; b < take; b++)
        pkt.payload.push_back(payload[start + b]);
      pkt.reth_va = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_RC_REMOTE_VA);
      pkt.reth_rkey = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_RC_REMOTE_KEY);
      pkt.reth_len = payload.size();
      pkt.imm = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_RC_IMMEDIATE);
      if (ud)
        pkt.deth_qkey = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_UD_DST_Q_KEY);
      emit(pkt, dmac);
    end
  endtask

  // 功能：a 是否在 24 位 PSN 空间中先于 b（半窗口比较）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：相等返回 0。
  protected function bit psn_before(bit [23:0] a, bit [23:0] b);
    bit [23:0] d;

    d = b - a;
    return d != 0 && d < 24'h80_0000;
  endfunction

  // 功能：等待一个属于本次请求（PSN 不早于 first）的响应，丢弃更早的过期响应。
  // 输入/输出及副作用：消费响应；pkt 输出；至多等待 rt.rto（0 为一直等）。
  // 失败/边界：超时 got=0。
  protected task next_response(rdma_dev_qp_rt rt, bit [23:0] first, output rdma_packet pkt,
                               output bit got);
    forever begin
      pkt = null;
      got = 1'b0;
      fork
        begin
          fork
            begin
              rt.responses.get(pkt);
              got = 1'b1;
            end
            begin
              if (rt.rto == 0)
                wait (1'b0);
              #(rt.rto);
            end
          join_any
          disable fork;
        end
      join
      if (!got || !psn_before(pkt.psn, first))
        return;
    end
  endtask

  // 功能：把一个 NAK syndrome 分类：RNR（001xxxxx）、PSN 序列错误（0x60）、其余致命。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function int unsigned nak_outcome(bit [7:0] syndrome);
    if (syndrome[7:5] == 3'b001)
      return RSP_RNR;
    if (syndrome == RDMA_AETH_NAK_PSN_SEQ)
      return RSP_SEQ;
    return RSP_FATAL;
  endfunction

  // 功能：RC SEND/WRITE 等 ACK：覆盖最后一个 PSN（send_psn-1）的 ACK 完成；NAK 按类型返回，
  //   nak_psn 为 NAK 携带的 PSN（序列 NAK 时即响应方期望的 PSN）。
  // 输入/输出及副作用：消费响应；outcome/synd/nak_psn 输出。
  // 失败/边界：超时为 RSP_TIMEOUT。
  protected task wait_ack(rdma_dev_qp_rt rt, bit [23:0] first, output int unsigned outcome,
                          output bit [7:0] synd, output bit [23:0] nak_psn);
    rdma_packet pkt;
    bit got;

    synd = '0;
    nak_psn = first;
    forever begin
      next_response(rt, first, pkt, got);
      if (!got) begin
        outcome = RSP_TIMEOUT;
        return;
      end
      if (pkt.aeth_syndrome != RDMA_AETH_ACK) begin
        synd = pkt.aeth_syndrome;
        nak_psn = pkt.psn;
        outcome = nak_outcome(pkt.aeth_syndrome);
        return;
      end
      if (pkt.opcode == RDMA_NET_ACK && pkt.psn == rt.send_psn - 1) begin
        outcome = RSP_OK;
        return;
      end
    end
  endtask

  // 功能：RDMA READ 一次尝试，从第 from 个响应分段起：发请求（RC 一个，覆盖 from 之后的剩余部分，
  //   PSN = start + from；URC 按 PMTU 每段一个 READ_DATA_ONLY 请求），按序收响应并散写到本地 SGE。
  //   resume 输出第一个未收到的分段（供重传）。
  // 输入/输出及副作用：send_psn 置为 start + 分段数，写主机内存；outcome/synd/ecode/resume 输出。
  // 失败/边界：超时/NAK 按类型返回；响应 PSN 跳号为 RSP_SEQ；长度不符为致命；本地写失败为
  //   RSP_LOCAL（SQ_KEY_ERR）。
  protected task do_read(int unsigned qpn, rdma_dev_qp_rt rt, rdma_bytes_t wqe,
                         bit [63:0] sges[$], int unsigned pd, int unsigned total,
                         bit [47:0] dmac, bit [23:0] start, int unsigned from,
                         output int unsigned outcome, output bit [7:0] synd,
                         inout bit [7:0] ecode, output int unsigned resume);
    rdma_packet pkt;
    int unsigned offset;
    int unsigned count;
    int unsigned received;
    bit [23:0] first;
    bit got;
    bit urc;
    rdma_bytes_t part;

    count = (total + mtu(qpn) - 1) / mtu(qpn);
    if (count == 0)
      count = 1;
    urc = is_urc(qpn);
    first = start;
    synd = '0;
    resume = from;
    for (int unsigned k = from; k < (urc ? count : from + 1); k++) begin
      pkt = new_packet(qpn, RDMA_NET_RDMA_READ_REQUEST, k, urc ? count : 1, first + k,
                       `RDMA_QPC(qpn, RDMA_QPC_DST_QPN), 1'b0);
      pkt.reth_va = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_RC_REMOTE_VA) + k * mtu(qpn);
      pkt.reth_rkey = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_RC_REMOTE_KEY);
      pkt.reth_len = total - k * mtu(qpn);
      if (urc && pkt.reth_len > mtu(qpn))
        pkt.reth_len = mtu(qpn);
      emit(pkt, dmac);
    end
    rt.send_psn = first + count;
    offset = from * mtu(qpn);
    received = from;
    forever begin
      next_response(rt, first, pkt, got);
      resume = received;
      if (!got) begin
        outcome = RSP_TIMEOUT;
        return;
      end
      if (pkt.opcode != RDMA_NET_RDMA_READ_RESP) begin
        synd = pkt.aeth_syndrome;
        outcome = nak_outcome(pkt.aeth_syndrome);
        return;
      end
      // 响应缺失（PSN 跳号）：整条 READ 重发，响应方按重复请求重放。
      if (pkt.psn != first + received) begin
        outcome = RSP_SEQ;
        return;
      end
      part = new[pkt.payload.size()];
      foreach (part[b])
        part[b] = pkt.payload[b];
      if (!scatter(sges, pd, RDMA_RIGHT_LOCAL_WRITE, offset, part)) begin
        ecode = RDMA_ECODE_EC_TPE_SQ_KEY_ERR;
        outcome = RSP_LOCAL;
        return;
      end
      offset += part.size();
      received++;
      if (received == count)
        break;
    end
    outcome = RSP_OK;
    if (offset != total) begin
      synd = RDMA_AETH_NAK_INVALID_REQUEST;
      outcome = RSP_FATAL;
    end
  endtask

  // 功能：ATOMIC 一次尝试：发 AtomicETH 请求，收到 ATOMIC ACK 后把原值（小端 8B）写到本地缓冲。
  // 输入/输出及副作用：推进 send_psn，写主机内存；outcome/synd/ecode 输出。
  // 失败/边界：超时/NAK 按类型返回；本地写失败为 RSP_LOCAL（SQ_KEY_ERR）。
  protected task do_atomic(int unsigned qpn, rdma_dev_qp_rt rt, rdma_bytes_t wqe,
                           int unsigned pd, bit [47:0] dmac, output int unsigned outcome,
                           output bit [7:0] synd, inout bit [7:0] ecode);
    rdma_packet pkt;
    bit got;
    bit cas;
    bit [23:0] first;
    rdma_bytes_t orig;
    bit [63:0] lsge[$];

    cas = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_OPCODE) == RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP;
    first = rt.send_psn;
    synd = '0;
    if (cas)
      pkt = new_packet(qpn, RDMA_NET_ATOMIC_CMP_SWAP, 0, 1, first,
                       `RDMA_QPC(qpn, RDMA_QPC_DST_QPN), 1'b0);
    else
      pkt = new_packet(qpn, RDMA_NET_ATOMIC_FETCH_ADD, 0, 1, first,
                       `RDMA_QPC(qpn, RDMA_QPC_DST_QPN), 1'b0);
    rt.send_psn = first + 1;
    pkt.atomic_va = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_ATOMIC_R_VA);
    pkt.atomic_rkey = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_ATOMIC_R_KEY);
    if (cas) begin
      pkt.atomic_compare = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA);
      pkt.atomic_swap_add = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_ATOMIC_CAS_SWAP_DATA);
    end
    else
      pkt.atomic_swap_add = `RDMA_BE_GET(wqe, RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA);
    emit(pkt, dmac);
    next_response(rt, first, pkt, got);
    if (!got) begin
      outcome = RSP_TIMEOUT;
      return;
    end
    if (pkt.opcode != RDMA_NET_ATOMIC_ACK || pkt.aeth_syndrome != RDMA_AETH_ACK) begin
      synd = pkt.aeth_syndrome;
      outcome = nak_outcome(pkt.aeth_syndrome);
      return;
    end
    orig = rdma_be::zeros(8);
    foreach (orig[k])
      orig[k] = pkt.atomic_orig >> (8 * k);
    lsge.push_back(`RDMA_BE_GET(wqe, RDMA_SQ_WQE_ATOMIC_L_KEY));
    lsge.push_back(`RDMA_BE_GET(wqe, RDMA_SQ_WQE_ATOMIC_L_VA));
    lsge.push_back(8);
    outcome = RSP_OK;
    if (!scatter(lsge, pd, RDMA_RIGHT_LOCAL_WRITE, 0, orig)) begin
      ecode = RDMA_ECODE_EC_TPE_SQ_KEY_ERR;
      outcome = RSP_LOCAL;
    end
  endtask

  // ---------------------------------------------------------------- 完成
  // 功能：按 CQC 写一个 32B CQE（polarity 首圈为 1），CQ 已 arm 时按 CEQN 写 CEQE 并解除 arm。
  // 输入/输出及副作用：DMA 写 CQ/CEQ。
  // 失败/边界：CQ 不存在或写失败报告协议错误。
  protected function void write_cqe(int unsigned qpn, bit rq, int unsigned wqe_index, bit wqe_wrap,
                           bit [7:0] ecode, int unsigned byte_len, bit [31:0] imm,
                           int unsigned src_qpn, bit [7:0] rem_synd = '0);
    int unsigned cqn;
    rdma_dev_object cqc;
    int unsigned size;
    bit [63:0] slot;
    rdma_bytes_t cqe;
    longint unsigned pi;
    rdma_status status;

    if (is_urc(qpn)) begin
      urc_complete(qpn, rq, wqe_index, ecode, byte_len, imm);
      return;
    end
    if (rq)
      cqn = `RDMA_QPC(qpn, RDMA_QPC_RQ_CQN);
    else
      cqn = `RDMA_QPC(qpn, RDMA_QPC_SQ_CQN);
    if (!ctx.lookup(RDMA_DEV_CQ, cqn, cqc)) begin
      protocol_error($sformatf("QP %0d completes to absent CQ %0d", qpn, cqn));
      return;
    end
    size = 1 << `RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CQ_SIZE, CQC_BASE);
    if (!cq_pi.exists(cqn))
      cq_pi[cqn] = 0;
    pi = cq_pi[cqn];
    status = ctx.buffer_addr(`RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CQ_OM, CQC_BASE),
                             `RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CUR_CQ_PD_PBA, CQC_BASE),
                             (pi % size) * CQE_BYTES, slot);
    if (!status.ok()) begin
      protocol_error($sformatf("CQ %0d buffer is not translatable", cqn));
      return;
    end
    cqe = rdma_be::zeros(CQE_BYTES);
    `RDMA_BE_SET(cqe, RDMA_CQE_POLARITY, !((pi / size) & 1))
    `RDMA_BE_SET(cqe, RDMA_CQE_RQ_CQE, rq)
    `RDMA_BE_SET(cqe, RDMA_CQE_WQE_WRAP, wqe_wrap)
    `RDMA_BE_SET(cqe, RDMA_CQE_WQE_INDEX, wqe_index)
    `RDMA_BE_SET(cqe, RDMA_CQE_PKT_OPCODE, 8'h01)
    `RDMA_BE_SET(cqe, RDMA_CQE_ECODE, ecode)
    `RDMA_BE_SET(cqe, RDMA_CQE_QPN, qpn)
    `RDMA_BE_SET(cqe, RDMA_CQE_IMMDT_DATA, imm)
    `RDMA_BE_SET(cqe, RDMA_CQE_PAYLOAD_LEN, byte_len)
    if (src_qpn != 0) begin
      `RDMA_BE_SET(cqe, RDMA_CQE_UD_SRC_QPN, src_qpn)
    end
    if (rem_synd != 0) begin
      `RDMA_BE_SET(cqe, RDMA_CQE_RC_REMOTE_SYNDROME, rem_synd)
    end
    if (rq && `RDMA_QPC(qpn, RDMA_QPC_RC_SRFQ)) begin
      `RDMA_BE_SET(cqe, RDMA_CQE_SRFQ, 1)
      `RDMA_BE_SET(cqe, RDMA_CQE_SRFQN, `RDMA_QPC(qpn, RDMA_QPC_RC_SRFQN))
    end
    if (!dma_write(slot, cqe)) begin
      protocol_error($sformatf("CQ %0d CQE write failed", cqn));
      return;
    end
    cq_pi[cqn] = pi + 1;
    if (cq_armed.exists(cqn) && cq_armed[cqn] != RDMA_CQC_ARM_ST_NO_EVENT) begin
      cq_armed.delete(cqn);
      write_ceqe(cqn, `RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CEQN, CQC_BASE));
    end
  endfunction

  // 功能：CQC_RESIZE 的数据面部分（命令完成前执行）：在旧 CQ 的当前 PI 槽写 RESIZE CQE（不推进 PI），
  //   未被驱动消费的 CQE 数 pending = PI - (OLD_CI_WRAP*old + OLD_CI)（模 2*old）；驱动把它们复制到
  //   新 CQ 的 OLD_CI+1 起，故新生产者位置 = OLD_CI_WRAP*new + OLD_CI + 1 + pending。
  // 输入/输出及副作用：DMA 写旧 CQ；更新 cq_pi。
  // 失败/边界：CQ 不存在或旧缓冲不可翻译时报告协议错误。
  function void resize_cq(int unsigned cqn, byte unsigned sqe[]);
    rdma_dev_object cqc;
    int unsigned old_size;
    int unsigned new_size;
    longint unsigned pi;
    longint unsigned consumed;
    longint unsigned pending;
    bit [63:0] slot;
    rdma_bytes_t cqe;
    rdma_status status;

    if (!ctx.lookup(RDMA_DEV_CQ, cqn, cqc)) begin
      protocol_error($sformatf("resize of absent CQ %0d", cqn));
      return;
    end
    old_size = 1 << `RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CQ_SIZE, CQC_BASE);
    new_size = 1 << `RDMA_BE_GET(sqe, RDMA_CQC_RESIZE_CQ_SIZE);
    if (!cq_pi.exists(cqn))
      cq_pi[cqn] = 0;
    pi = cq_pi[cqn];
    status = ctx.buffer_addr(`RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CQ_OM, CQC_BASE),
                             `RDMA_BE_GET_AT(cqc.bytes, RDMA_CQC_BODY_CUR_CQ_PD_PBA, CQC_BASE),
                             (pi % old_size) * CQE_BYTES, slot);
    cqe = rdma_be::zeros(CQE_BYTES);
    `RDMA_BE_SET(cqe, RDMA_CQE_POLARITY, !((pi / old_size) & 1))
    `RDMA_BE_SET(cqe, RDMA_CQE_RESIZE_CQE, 1)
    if (!status.ok() || !dma_write(slot, cqe)) begin
      protocol_error($sformatf("CQ %0d resize CQE write failed", cqn));
      return;
    end
    consumed = `RDMA_BE_GET(sqe, RDMA_CQC_RESIZE_OLD_CQ_CI_WRAP) * old_size +
               `RDMA_BE_GET(sqe, RDMA_CQC_RESIZE_OLD_CQ_CI);
    pending = (pi + 2 * old_size - consumed) % (2 * old_size);
    cq_pi[cqn] = `RDMA_BE_GET(sqe, RDMA_CQC_RESIZE_OLD_CQ_CI_WRAP) * new_size +
                 `RDMA_BE_GET(sqe, RDMA_CQC_RESIZE_OLD_CQ_CI) + 1 + pending;
  endfunction

  // 功能：向 CEQ 写一个 16B CEQE（CQN）。
  // 输入/输出及副作用：DMA 写 CEQ。
  // 失败/边界：见 write_eqe。
  protected function void write_ceqe(int unsigned cqn, int unsigned ceqn);
    rdma_bytes_t ceqe;

    ceqe = rdma_be::zeros(RDMA_CEQE_BYTES);
    `RDMA_BE_SET(ceqe, RDMA_CEQE_CQN, cqn)
    write_eqe(RDMA_DEV_CEQ, ceqn, ceqe);
  endfunction

  // 功能：向 AEQ 写一个 16B AEQE（ECODE、QPN；SRQ 事件带 SRFQ_EN/SRFQN）。本设备实例即一个
  //   Function，AEQN 取该 Function 唯一的 AEQ（驱动以 vf_id 建立）。
  // 输入/输出及副作用：DMA 写 AEQ。
  // 失败/边界：见 write_eqe。
  protected function void write_aeqe(int unsigned qpn, bit [7:0] ecode, bit srfq,
                                     int unsigned srfqn);
    rdma_bytes_t aeqe;
    int unsigned aeqn;

    aeqe = rdma_be::zeros(RDMA_AEQE_BYTES);
    `RDMA_BE_SET(aeqe, RDMA_AEQE_ECODE, ecode)
    `RDMA_BE_SET(aeqe, RDMA_AEQE_QPN, qpn)
    `RDMA_BE_SET(aeqe, RDMA_AEQE_SRFQ_EN, srfq)
    `RDMA_BE_SET(aeqe, RDMA_AEQE_SRFQN, srfqn)
    if (!ctx.first_id(RDMA_DEV_AEQ, aeqn)) begin
      protocol_error("asynchronous event without an AEQ");
      return;
    end
    write_eqe(RDMA_DEV_AEQ, aeqn, aeqe);
  endfunction

  // 功能：按 EQC 向 CEQ/AEQ 的当前 PI 槽写一个 16B 事件（bit63 polarity 首圈为 1），PI 加一。
  // 输入/输出及副作用：DMA 写 EQ。
  // 失败/边界：EQ 不存在、不可翻译或写失败报告协议错误。
  protected function void write_eqe(rdma_dev_kind_e kind, int unsigned eqn, rdma_bytes_t entry);
    rdma_dev_object eqc;
    int unsigned entries;
    int unsigned key;
    bit [63:0] slot;
    longint unsigned pi;
    rdma_status status;

    if (!ctx.lookup(kind, eqn, eqc)) begin
      protocol_error($sformatf("event for absent %s %0d", kind.name(), eqn));
      return;
    end
    // CEQ 与 AEQ 的 PI 分开计数。
    key = (kind == RDMA_DEV_AEQ) ? 32'h8000_0000 | eqn : eqn;
    entries = 1 << `RDMA_BE_GET_AT(eqc.bytes, RDMA_EQC_BODY_EQ_SIZE, EQC_BASE);
    if (!eq_pi.exists(key))
      eq_pi[key] = 0;
    pi = eq_pi[key];
    status = ctx.buffer_addr(`RDMA_BE_GET_AT(eqc.bytes, RDMA_EQC_BODY_EQ_OM, EQC_BASE),
                             `RDMA_BE_GET_AT(eqc.bytes, RDMA_EQC_BODY_CUR_EQ_PBA, EQC_BASE),
                             (pi % entries) * RDMA_CEQE_BYTES, slot);
    if (!status.ok()) begin
      protocol_error($sformatf("%s %0d buffer is not translatable", kind.name(), eqn));
      return;
    end
    entry[0][7] = !((pi / entries) & 1);
    if (!dma_write(slot, entry))
      protocol_error($sformatf("%s %0d write failed", kind.name(), eqn));
    eq_pi[key] = pi + 1;
  endfunction

  // ---------------------------------------------------------------- RX
  // 功能：处理一个收到的报文：响应类交给请求方 QP，请求类按 opcode 处理。
  // 输入/输出及副作用：见各处理函数。
  // 失败/边界：扩展头截断或目的 QP 不存在报告协议错误。
  protected task rx_packet(rdma_packet pkt);
    rdma_dev_object obj;

    if (!pkt.unpack_headers()) begin
      protocol_error("received packet extension headers are truncated");
      return;
    end
    if (!ctx.lookup(RDMA_DEV_QP, pkt.destination_qpn, obj)) begin
      protocol_error($sformatf("packet for absent QP %0d", pkt.destination_qpn));
      return;
    end
    if (pkt.opcode inside {RDMA_NET_ACK, RDMA_NET_NAK, RDMA_NET_RDMA_READ_RESP,
                           RDMA_NET_ATOMIC_ACK})
      void'(qp_rt(pkt.destination_qpn).responses.try_put(pkt));
    else
      handle_request(pkt.destination_qpn, pkt);
  endtask

  // 功能：取下一个 RQE：shadow（QPC+510）的 be16 PI|wrap<<15 与设备 CI 比较判断可用，校验 polarity
  //   与签名，解析 SGE（WQE 内或 RQ SGB）。
  // 输入/输出及副作用：推进 rq_ci；index/wrap 输出 RQE 头中的 INDEX/WRAP。
  // 失败/边界：无可用 RQE 或校验失败返回 0。
  protected function bit fetch_rqe(int unsigned qpn, rdma_dev_qp_rt rt, output int unsigned index,
                                   output bit wrap, output bit [63:0] sges[$]);
    bit [63:0] slot;
    int unsigned depth;
    rdma_bytes_t shadow;
    rdma_bytes_t rqe;
    bit [15:0] pi;

    index = 0;
    wrap = 1'b0;
    sges.delete();
    if (`RDMA_QPC(qpn, RDMA_QPC_RC_SRFQ))
      return fetch_srqe(qpn, `RDMA_QPC(qpn, RDMA_QPC_RC_SRFQN), index, wrap, sges);
    if (!dma_read(qp_shadow(qpn) + 6, 2, shadow) || !wq_slot(qpn, 1'b1, rt.rq_ci, slot, depth))
      return 1'b0;
    pi = {shadow[0], shadow[1]};
    if (pi[14:0] == rt.rq_ci % depth && pi[15] == ((rt.rq_ci / depth) & 1))
      return 1'b0;
    if (!dma_read(slot, RDMA_RQE_BYTES, rqe))
      return 1'b0;
    if (rdma_be::field(rqe, 0, RDMA_RQE_VALID_LSB, 1) != !((rt.rq_ci / depth) & 1)) begin
      protocol_error($sformatf("QP %0d RQE polarity does not match the posted PI", qpn));
      return 1'b0;
    end
    rt.rq_ci++;
    index = `RDMA_BE_GET(rqe, RDMA_RQE_INDEX);
    wrap = `RDMA_BE_GET(rqe, RDMA_RQE_WRAP);
    return rqe_sges(rqe, $sformatf("QP %0d", qpn), sges);
  endfunction

  // 功能：解析 RQE 的 SGE：SGE≤2 在 WQE 字节 32 起，否则从 SGB_PA<<9 读 SGB；SIGN_EN 时校验签名
  //   （WQE 与 SGB 有效部分异或为 0xFF）。
  // 输入/输出及副作用：DMA 读 SGB；sges 输出 {key, va, len} 三元组。
  // 失败/边界：读失败返回 0；签名不符报告协议错误并返回 0。
  protected function bit rqe_sges(rdma_bytes_t rqe, string owner, output bit [63:0] sges[$]);
    rdma_bytes_t area;
    int unsigned sge_num;
    bit [7:0] sum;

    sges.delete();
    sge_num = `RDMA_BE_GET(rqe, RDMA_RQE_SGE_NUM);
    area = rdma_be::slice(rqe, PAYLOAD_OFFSET, 32);
    if (sge_num > 2) begin
      if (!dma_read(`RDMA_BE_GET(rqe, RDMA_RQE_SGB_PA) << 9, sge_num * SGE_BYTES, area))
        return 1'b0;
    end
    if (`RDMA_BE_GET(rqe, RDMA_RQE_SIGN_EN)) begin
      sum = rdma_be::xor_bytes(rqe);
      if (sge_num > 2)
        sum ^= rdma_be::xor_bytes(area);
      if (sum != 8'hff) begin
        protocol_error($sformatf("%s RQE signature mismatch", owner));
        return 1'b0;
      end
    end
    parse_sges(area, sge_num, sges);
    return 1'b1;
  endfunction

  // 功能：从 SRQ 的 SRFQ 环取下一个 RQE：SRQ shadow 的 be16 PI|wrap<<15 与设备 SRQ CI 比较判断
  //   可用，校验 polarity，解析 SGE（含 SGB 与签名）。
  // 输入/输出及副作用：推进该 SRQ 的 CI；index/wrap 输出 RQE 头中的 INDEX（驱动 bitmap 槽）/WRAP。
  // 失败/边界：无可用 RQE 或校验失败返回 0。
  protected function bit fetch_srqe(int unsigned qpn, int unsigned srqn,
                                    output int unsigned index, output bit wrap,
                                    output bit [63:0] sges[$]);
    rdma_dev_object srqc;
    rdma_bytes_t shadow;
    rdma_bytes_t rqe;
    bit [63:0] shadow_pa;
    bit [63:0] slot;
    bit [15:0] pi;
    int unsigned depth;
    longint unsigned ci;
    rdma_status status;

    index = 0;
    wrap = 1'b0;
    sges.delete();
    if (!ctx.lookup(RDMA_DEV_SRQ, srqn, srqc)) begin
      protocol_error($sformatf("QP %0d uses absent SRQ %0d", qpn, srqn));
      return 1'b0;
    end
    if (!srq_ci.exists(srqn))
      srq_ci[srqn] = 0;
    ci = srq_ci[srqn];
    depth = 1 << `RDMA_BE_GET_AT(srqc.bytes, RDMA_SRQC_BODY_SRFQ_SIZE, SRQC_BASE);
    shadow_pa = (`RDMA_BE_GET_AT(srqc.bytes, RDMA_SRQC_BODY_SHADOW_PA, SRQC_BASE) << 12) +
                (srqn % 128) * SRQ_CTX_BYTES + SRQ_SHADOW_OFFSET;
    if (!dma_read(shadow_pa, 2, shadow))
      return 1'b0;
    pi = {shadow[0], shadow[1]};
    if (pi[14:0] == ci % depth && pi[15] == ((ci / depth) & 1))
      return 1'b0;
    status = ctx.buffer_addr(`RDMA_BE_GET_AT(srqc.bytes, RDMA_SRQC_BODY_SRFQ_OM, SRQC_BASE),
                             `RDMA_BE_GET_AT(srqc.bytes, RDMA_SRQC_BODY_SRFQ_PBA, SRQC_BASE),
                             (ci % depth) * RDMA_RQE_BYTES, slot);
    if (!status.ok() || !dma_read(slot, RDMA_RQE_BYTES, rqe))
      return 1'b0;
    if (rdma_be::field(rqe, 0, RDMA_RQE_VALID_LSB, 1) != !((ci / depth) & 1)) begin
      protocol_error($sformatf("SRQ %0d RQE polarity does not match the posted PI", srqn));
      return 1'b0;
    end
    srq_ci[srqn] = ci + 1;
    if (srq_limit.exists(srqn) &&
        ((pi[15] * depth + pi[14:0]) + 2 * depth - (ci + 1) % (2 * depth)) % (2 * depth) <
          srq_limit[srqn]) begin
      srq_limit.delete(srqn);
      write_aeqe(qpn, RDMA_ECODE_XTRDMA_CQE_ECODE_SRFQ_OVER_LIMIT_TH, 1'b1, srqn);
    end
    index = `RDMA_BE_GET(rqe, RDMA_RQE_INDEX);
    wrap = `RDMA_BE_GET(rqe, RDMA_RQE_WRAP);
    return rqe_sges(rqe, $sformatf("SRQ %0d", srqn), sges);
  endfunction

  // 功能：发送 ACK/NAK。dup 为重复请求的重发 ACK（不推进 MSN）。
  // 输入/输出及副作用：新 ACK 推进 msn，经端口发包。
  // 失败/边界：无。
  protected task send_ack(int unsigned qpn, rdma_dev_qp_rt rt, bit [23:0] psn,
                          bit [7:0] syndrome, bit dup = 1'b0);
    rdma_packet pkt;
    bit [23:0] dst_qpn;

    // RC 响应的目的 QPN 取自本端 QPC（BTH 不携带源 QPN）。
    dst_qpn = `RDMA_QPC(qpn, RDMA_QPC_DST_QPN);
    if (syndrome == RDMA_AETH_ACK) begin
      pkt = new_packet(qpn, RDMA_NET_ACK, 0, 1, psn, dst_qpn, 1'b0);
      if (!dup)
        rt.msn++;
    end
    else
      pkt = new_packet(qpn, RDMA_NET_NAK, 0, 1, psn, dst_qpn, 1'b0);
    pkt.aeth_syndrome = syndrome;
    pkt.aeth_msn = rt.msn;
    emit(pkt, `RDMA_QPC(qpn, RDMA_QPC_DMAC));
  endtask

  // 功能：RC/URC 响应方 PSN 检查：早于期望的为重复请求（重发 ACK / 重放 READ / 回缓存的 ATOMIC
  //   结果，不再执行）；晚于期望的回一次 PSN 序列 NAK 后丢弃（RNR 后的本消息余下报文静默丢弃）；
  //   等于期望的放行。
  // 输入/输出及副作用：可能发包；accept 输出是否继续处理。
  // 失败/边界：无。
  protected task check_psn(int unsigned qpn, rdma_dev_qp_rt rt, rdma_packet pkt, int unsigned pd,
                           output bit accept);
    bit last;

    accept = 1'b0;
    last = pkt.segment inside {RDMA_SEG_LAST, RDMA_SEG_ONLY};
    if (psn_before(pkt.psn, rt.expected_psn)) begin
      case (pkt.opcode)
        RDMA_NET_RDMA_READ_REQUEST: serve_read(qpn, rt, pkt, pd, 1'b1);
        RDMA_NET_ATOMIC_CMP_SWAP, RDMA_NET_ATOMIC_FETCH_ADD: begin
          if (rt.atomic_cache.exists(pkt.psn))
            atomic_ack(qpn, rt, pkt.psn, rt.atomic_cache[pkt.psn]);
        end
        default: begin
          if (last)
            send_ack(qpn, rt, pkt.psn, RDMA_AETH_ACK, 1'b1);
        end
      endcase
      return;
    end
    if (pkt.psn != rt.expected_psn) begin
      if (!rt.rnr_drop && !rt.seq_nak_sent) begin
        rt.seq_nak_sent = 1'b1;
        send_ack(qpn, rt, rt.expected_psn, RDMA_AETH_NAK_PSN_SEQ);
      end
      return;
    end
    rt.seq_nak_sent = 1'b0;
    rt.rnr_drop = 1'b0;
    if (pkt.segment inside {RDMA_SEG_FIRST, RDMA_SEG_ONLY})
      rt.msg_first_psn = pkt.psn;
    accept = 1'b1;
  endtask

  // 功能：在 RQE 缓冲开头写 40B GRH（RoCEv2 IPv4：前 20 字节为 0，后 20 字节为 IPv4 头：版本/IHL、
  //   总长、TTL 64、协议 UDP；模型报文不携带 IP 地址，地址字段为 0）。
  // 输入/输出及副作用：写主机内存。
  // 失败/边界：写失败返回 0。
  protected function bit write_grh(bit [63:0] sges[$], int unsigned pd, int unsigned payload);
    rdma_bytes_t grh;
    int unsigned total;

    grh = rdma_be::zeros(GRH_BYTES);
    total = 20 + 8 + 12 + 8 + payload + 4;
    grh[20] = 8'h45;
    grh[22] = total[15:8];
    grh[23] = total[7:0];
    grh[28] = 8'd64;
    grh[29] = 8'd17;
    return scatter(sges, pd, RDMA_RIGHT_LOCAL_WRITE, 0, grh);
  endfunction

  // 功能：响应方处理请求：RC/URC 先做 PSN 检查；SEND 消费 RQE 散写（UD 先校验 Q_Key，缓冲前 40B
  //   为 GRH），WRITE 按 rkey 写入（带立即数时消费 RQE），READ/ATOMIC 读出或读改写后回包；RC 按
  //   结果回 ACK/NAK。无 RQE 时回 RNR NAK 且不推进期望 PSN。URC 接收侧错误上报 RQ 异常。
  // 输入/输出及副作用：写主机内存、写 CQE/CEQE、发包。
  // 失败/边界：访问错误回 NAK 且不写内存；Q_Key 不符的 UD 报文静默丢弃。
  protected task handle_request(int unsigned qpn, rdma_packet pkt);
    rdma_dev_qp_rt rt;
    bit ud;
    bit last;
    bit accept;
    int unsigned pd;
    rdma_bytes_t data;
    bit [63:0] segs[$];
    bit [63:0] rsges[$];
    int unsigned index;
    bit wrap;
    bit [7:0] syndrome;
    bit [31:0] imm;
    int unsigned src_qp;
    int unsigned base;

    rt = qp_rt(qpn);
    ud = `RDMA_QPC(qpn, RDMA_QPC_SERVICE_TYPE) == 3;
    pd = `RDMA_QPC(qpn, RDMA_QPC_PD_IDX);
    last = pkt.segment inside {RDMA_SEG_LAST, RDMA_SEG_ONLY};
    if (ud) begin
      if (pkt.deth_qkey != {8'(`RDMA_QPC(qpn, RDMA_QPC_UD_QKEY_H)),
                            24'(`RDMA_QPC(qpn, RDMA_QPC_UD_QKEY_L))}) begin
        qkey_drops++;
        return;
      end
    end
    else begin
      check_psn(qpn, rt, pkt, pd, accept);
      if (!accept)
        return;
      rt.expected_psn = pkt.psn + 1;
    end
    data = new[pkt.payload.size()];
    foreach (data[b])
      data[b] = pkt.payload[b];
    imm = pkt.has_immdt() ? pkt.imm : '0;
    src_qp = ud ? pkt.source_qpn : 0;
    base = ud ? GRH_BYTES : 0;
    case (pkt.opcode)
      RDMA_NET_SEND, RDMA_NET_SEND_WITH_IMM: begin
        if (pkt.segment inside {RDMA_SEG_FIRST, RDMA_SEG_ONLY}) begin
          rt.rx_offset = 0;
          rt.rx_active = fetch_rqe(qpn, rt, index, wrap, rsges);
          rt.rx_index = index;
          rt.rx_wrap = wrap;
          rt.rx_sges = rsges;
          rt.rx_failed = !rt.rx_active;
          if (!rt.rx_active && !ud) begin
            // RNR：本消息不接收，期望 PSN 回到首包，余下报文丢弃，等请求方重传。
            rt.expected_psn = pkt.psn;
            rt.rnr_drop = 1'b1;
            send_ack(qpn, rt, pkt.psn, rnr_syndrome(qpn));
            return;
          end
          // 带副作用的调用不放进 && 表达式（VCS 不保证短路）。
          if (rt.rx_active && ud) begin
            if (!write_grh(rt.rx_sges, pd, pkt.payload.size()))
              rt.rx_failed = 1'b1;
          end
        end
        if (!rt.rx_failed) begin
          if (!scatter(rt.rx_sges, pd, RDMA_RIGHT_LOCAL_WRITE, base + rt.rx_offset, data))
            rt.rx_failed = 1'b1;
        end
        rt.rx_offset += data.size();
        if (last) begin
          if (rt.rx_active && rt.rx_failed && is_urc(qpn))
            urc_abnormal(qpn, 1'b1, RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC, '0);
          else if (rt.rx_active && rt.rx_failed)
            write_cqe(qpn, 1'b1, rt.rx_index, rt.rx_wrap,
                      RDMA_ECODE_EC_RPE_REQ_PKT_LEN_UNMATCH_SGE_RC_URC, rt.rx_offset, imm, src_qp);
          else if (rt.rx_active)
            write_cqe(qpn, 1'b1, rt.rx_index, rt.rx_wrap, RDMA_CMQ_SUCCESS_ECODE,
                      base + rt.rx_offset, imm, src_qp);
          syndrome = RDMA_AETH_ACK;
          if (rt.rx_failed)
            syndrome = RDMA_AETH_NAK_INVALID_REQUEST;
          if (!ud)
            send_ack(qpn, rt, pkt.psn, syndrome);
        end
      end
      RDMA_NET_RDMA_WRITE, RDMA_NET_WRITE_WITH_IMM: begin
        if (pkt.segment inside {RDMA_SEG_FIRST, RDMA_SEG_ONLY}) begin
          rt.wr_va = pkt.reth_va;
          rt.wr_rkey = pkt.reth_rkey;
          rt.wr_len = pkt.reth_len;
          rt.wr_offset = 0;
          rt.wr_failed = !translate(pkt.reth_rkey, pd, RDMA_RIGHT_REMOTE_WRITE, pkt.reth_va,
                                    pkt.reth_len, segs);
          if (rt.wr_failed)
            send_ack(qpn, rt, pkt.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
        end
        if (!rt.wr_failed && data.size() != 0) begin
          rsges.delete();
          rsges.push_back(rt.wr_rkey);
          rsges.push_back(rt.wr_va);
          rsges.push_back(rt.wr_len);
          if (!scatter(rsges, pd, RDMA_RIGHT_REMOTE_WRITE, rt.wr_offset, data)) begin
            rt.wr_failed = 1'b1;
            send_ack(qpn, rt, pkt.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
          end
        end
        rt.wr_offset += data.size();
        if (last && !rt.wr_failed) begin
          syndrome = RDMA_AETH_ACK;
          if (pkt.opcode == RDMA_NET_WRITE_WITH_IMM) begin
            if (fetch_rqe(qpn, rt, index, wrap, rsges))
              write_cqe(qpn, 1'b1, index, wrap, RDMA_CMQ_SUCCESS_ECODE, rt.wr_len, pkt.imm, 0);
            else begin
              // RNR：数据可重写，整条消息待重传。
              syndrome = rnr_syndrome(qpn);
              rt.expected_psn = rt.msg_first_psn;
            end
          end
          send_ack(qpn, rt, pkt.psn, syndrome);
        end
      end
      RDMA_NET_RDMA_READ_REQUEST: begin
        serve_read(qpn, rt, pkt, pd, 1'b0);
      end
      RDMA_NET_ATOMIC_CMP_SWAP, RDMA_NET_ATOMIC_FETCH_ADD: begin
        serve_atomic(qpn, rt, pkt, pd);
      end
      default: begin
        protocol_error($sformatf("unexpected request opcode %s", pkt.opcode.name()));
      end
    endcase
  endtask

  // 功能：响应 READ：按 rkey（远端读权限）读出并分段回 READ RESPONSE；dup 为重复请求的重放
  //   （不改变期望 PSN 与 MSN）。
  // 输入/输出及副作用：新请求推进 expected_psn；发包。
  // 失败/边界：访问错误回 NAK。
  protected task serve_read(int unsigned qpn, rdma_dev_qp_rt rt, rdma_packet req,
                            int unsigned pd, bit dup);
    bit [63:0] segs[$];
    rdma_bytes_t data;
    rdma_bytes_t part;
    rdma_packet pkt;
    int unsigned count;
    int unsigned start;
    int unsigned take;

    count = (req.reth_len + mtu(qpn) - 1) / mtu(qpn);
    if (count == 0)
      count = 1;
    if (!dup)
      rt.expected_psn = req.psn + count;
    data = new[0];
    if (!translate(req.reth_rkey, pd, RDMA_RIGHT_REMOTE_READ, req.reth_va, req.reth_len,
                   segs)) begin
      send_ack(qpn, rt, req.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
      return;
    end
    for (int k = 0; k < segs.size(); k += 2) begin
      if (!dma_read(segs[k], segs[k + 1], part)) begin
        send_ack(qpn, rt, req.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
        return;
      end
      data = {data, part};
    end
    if (!dup)
      rt.msn++;
    for (int unsigned k = 0; k < count; k++) begin
      pkt = new_packet(qpn, RDMA_NET_RDMA_READ_RESP, k, count, req.psn + k,
                       `RDMA_QPC(qpn, RDMA_QPC_DST_QPN), 1'b0);
      start = k * mtu(qpn);
      take = data.size() - start;
      if (take > mtu(qpn))
        take = mtu(qpn);
      for (int unsigned b = 0; b < take; b++)
        pkt.payload.push_back(data[start + b]);
      pkt.aeth_syndrome = RDMA_AETH_ACK;
      pkt.aeth_msn = rt.msn;
      emit(pkt, `RDMA_QPC(qpn, RDMA_QPC_DMAC));
    end
  endtask

  // 功能：响应 ATOMIC：8B 对齐、远端原子权限，按小端读改写，原值按 PSN 缓存并以 ATOMIC ACK 回送。
  // 输入/输出及副作用：写主机内存，发包。
  // 失败/边界：对齐或访问错误回 NAK，内存不变。
  protected task serve_atomic(int unsigned qpn, rdma_dev_qp_rt rt, rdma_packet req,
                              int unsigned pd);
    bit [63:0] segs[$];
    rdma_bytes_t raw;
    bit [63:0] orig;
    bit [63:0] value;

    if (req.atomic_va[2:0] != 3'b000 ||
        !translate(req.atomic_rkey, pd, RDMA_RIGHT_REMOTE_ATOMIC, req.atomic_va, 8, segs) ||
        !dma_read(segs[0], 8, raw)) begin
      send_ack(qpn, rt, req.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
      return;
    end
    orig = '0;
    for (int k = 7; k >= 0; k--)
      orig = (orig << 8) | raw[k];
    if (req.opcode == RDMA_NET_ATOMIC_CMP_SWAP)
      value = (orig == req.atomic_compare) ? req.atomic_swap_add : orig;
    else
      value = orig + req.atomic_swap_add;
    foreach (raw[k])
      raw[k] = value >> (8 * k);
    void'(dma_write(segs[0], raw));
    rt.msn++;
    rt.atomic_cache[req.psn] = orig;
    atomic_ack(qpn, rt, req.psn, orig);
  endtask

  // 功能：发 ATOMIC ACK（原值）。
  // 输入/输出及副作用：发包。
  // 失败/边界：无。
  protected task atomic_ack(int unsigned qpn, rdma_dev_qp_rt rt, bit [23:0] psn, bit [63:0] orig);
    rdma_packet pkt;

    pkt = new_packet(qpn, RDMA_NET_ATOMIC_ACK, 0, 1, psn, `RDMA_QPC(qpn, RDMA_QPC_DST_QPN), 1'b0);
    pkt.aeth_syndrome = RDMA_AETH_ACK;
    pkt.aeth_msn = rt.msn;
    pkt.atomic_orig = orig;
    emit(pkt, `RDMA_QPC(qpn, RDMA_QPC_DMAC));
  endtask

  `undef RDMA_QPC
endclass
