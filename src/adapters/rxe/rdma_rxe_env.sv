// 目录：外部适配器实现层 adapters/rxe/rdma_rxe_env.sv。
// 层：外部适配器（env 插件）。
// 职责：把 Linux Soft-RoCE 接入 rdma_env：一个远端 Function（rxe 设备，由 rxe_peer 进程驱动）与仿真
//   Function 经 TAP 互打。
//   - rdma_link_rxe：发往远端 Function 的报文经 TAP 发给 rxe，TAP 收到的报文交给仿真 Function；
//   - rdma_rxe_buf：远端缓冲（对端进程的 MR），读写经 rbuf/wbuf；
//   - rdma_rxe_ctrl_driver / rdma_rxe_verb_driver / rdma_rxe_verb_monitor：远端 Function 的控制面、投递
//     与完成经对端进程命令完成，仿真 Function 走基类；
//   - rdma_rxe_plugin：安装上述覆盖、启动对端进程、登记远端 Function。
//   对端进程限制：一个 PD/CQ/MR/SRQ、单 SGE、无 URC；远端只支持建资源与连接（不支持销毁/FLR）。
// 依赖：rdma_env_pkg、rdma_rxe_pkg（TAP 链路、对端进程）、net_packet 适配器。
// 所有权：插件持有对端进程；链路持有 TAP。
// 生命周期：env build 时安装，run_phase 启动，report 时关闭。
package rdma_rxe_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_drv_pkg::*;
  import rdma_net_packet_adapter_pkg::*;
  import rdma_env_pkg::*;
  import rdma_rxe_pkg::*;

  // 文本工具：plusarg、地址解析、十六进制转换。
  class rdma_rxe_util;
    // 功能：+name=value，缺省 fallback。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：无。
    static function string arg(string name, string fallback);
      string value;

      if ($value$plusargs({name, "=%s"}, value))
        return value;
      return fallback;
    endfunction

    // 功能：点分 IPv4 → 32 位。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：格式错误 UVM_FATAL。
    static function bit [31:0] ip_of(string text);
      int a, b, c, d;

      if ($sscanf(text, "%d.%d.%d.%d", a, b, c, d) != 4)
        `uvm_fatal("RXE", {"bad IPv4 address ", text})
      return {8'(a), 8'(b), 8'(c), 8'(d)};
    endfunction

    // 功能：冒号分隔 MAC → 48 位。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：格式错误 UVM_FATAL。
    static function bit [47:0] mac_of(string text);
      int b0, b1, b2, b3, b4, b5;

      if ($sscanf(text, "%h:%h:%h:%h:%h:%h", b0, b1, b2, b3, b4, b5) != 6)
        `uvm_fatal("RXE", {"bad MAC address ", text})
      return {8'(b0), 8'(b1), 8'(b2), 8'(b3), 8'(b4), 8'(b5)};
    endfunction

    // 功能：data[off, off+n) → 十六进制串（用于至多 1KiB 的块）。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：无。
    static function string hex_of(rdma_bytes_t data, int unsigned off, int unsigned n);
      string s;

      s = "";
      for (int unsigned i = off; i < off + n; i++)
        s = {s, $sformatf("%02x", data[i])};
      return s;
    endfunction
  endclass

  typedef class rdma_rxe_plugin;

  // 远端缓冲：iova 为对端进程 MR 的虚拟地址，偏移即 MR 内偏移；按 1KiB 分块读写（应答行长度有限）。
  class rdma_rxe_buf extends rdma_res_buf;
    `uvm_object_utils(rdma_rxe_buf)

    localparam int unsigned CHUNK = 1024;

    bit [31:0] rkey;

    // 功能：构造。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_rxe_buf");
      super.new(name);
    endfunction

    // 功能：rbuf 分块读。
    // 输入/输出及副作用：data 输出。
    // 失败/边界：对端应答错误返回 INVALID_STATE。
    virtual function rdma_status read(int unsigned off, int unsigned len,
                                      output rdma_bytes_t data);
      string reply;
      int unsigned n;

      data = new[len];
      for (int unsigned done = 0; done < len; done += n) begin
        n = len - done < CHUNK ? len - done : CHUNK;
        reply = rdma_rxe_plugin::peer.cmd($sformatf("rbuf %0d %0d", off + done, n));
        if (reply.len() != 3 + 2 * n)
          return rdma_status::make(RDMA_SC_INVALID_STATE, {"rbuf: ", reply});
        for (int unsigned i = 0; i < n; i++)
          data[done + i] = reply.substr(3 + 2 * i, 4 + 2 * i).atohex();
      end
      return rdma_status::success();
    endfunction

    // 功能：wbuf 分块写。
    // 输入/输出及副作用：写对端内存。
    // 失败/边界：对端应答错误返回 INVALID_STATE。
    virtual function rdma_status write(int unsigned off, rdma_bytes_t data);
      int unsigned n;

      for (int unsigned done = 0; done < data.size(); done += n) begin
        n = data.size() - done < CHUNK ? data.size() - done : CHUNK;
        if (rdma_rxe_plugin::peer.cmd({$sformatf("wbuf %0d ", off + done),
                                       rdma_rxe_util::hex_of(data, done, n)}) != "OK")
          return rdma_status::make(RDMA_SC_INVALID_STATE, "wbuf failed");
      end
      return rdma_status::success();
    endfunction
  endclass

  // TAP 链路：仿真 Function 发往远端 Function 的报文编码后写入 TAP；TAP 收到的帧解码后交给仿真
  //   Function（只支持一个仿真 Function）。帧地址：仿真侧 +RXE_SIM_MAC/+RXE_SIM_IP，rxe 侧为 TAP 的
  //   MAC 与 +RXE_IP。
  class rdma_link_rxe extends rdma_link;
    `uvm_component_utils(rdma_link_rxe)

    rdma_rxe_link tap;
    bit [47:0] rxe_mac;

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_link_rxe", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：读 TAP 的 MAC 并打开 TAP（+RXE_TAP，缺省 rtap0）。
    // 输入/输出及副作用：打开文件描述符。
    // 失败/边界：TAP 不存在 UVM_FATAL。
    function void build_phase(uvm_phase phase);
      string name;
      string text;
      int fd;

      super.build_phase(phase);
      name = rdma_rxe_util::arg("RXE_TAP", "rtap0");
      fd = $fopen({"/sys/class/net/", name, "/address"}, "r");
      if (fd == 0 || $fgets(text, fd) == 0)
        `uvm_fatal("RXE", {"TAP ", name, " not found: run tools/rxe/rxe_tap_setup.sh up"})
      $fclose(fd);
      rxe_mac = rdma_rxe_util::mac_of(text);
      tap = rdma_rxe_link::type_id::create("tap");
      tap.adapter = rdma_net_packet_adapter::type_id::create("rxe_adapter");
      tap.wait_us = rdma_rxe_util::arg("RXE_WAIT_US", "20").atoi();
      if (!tap.open(name))
        `uvm_fatal("RXE", {"cannot open TAP ", name})
    endfunction

    // 功能：接入 Function：远端只登记 MAC；仿真 Function 配置 TAP 适配器的身份与帧地址并接收 TAP 报文。
    // 输入/输出及副作用：见基类。
    // 失败/边界：适配器配置失败 UVM_FATAL。
    virtual function rdma_dev_port attach(rdma_res_func f);
      rdma_function_identity id;

      if (f.remote) begin
        funcs[f.index] = f;
        func_of_mac[f.mac] = f.index;
        return null;
      end
      if (!f.node.func.identity(id).ok() || !tap.adapter.configure_function(id).ok())
        `uvm_fatal("RXE", "TAP adapter configuration failed")
      tap.adapter.src_mac = rdma_rxe_util::mac_of(rdma_rxe_util::arg("RXE_SIM_MAC",
                                                                     "02:00:00:00:79:01"));
      tap.adapter.dst_mac = rxe_mac;
      tap.adapter.src_ip = rdma_rxe_util::ip_of(rdma_rxe_util::arg("RXE_SIM_IP", "10.79.0.1"));
      tap.adapter.dst_ip = rdma_rxe_util::ip_of(rdma_rxe_util::arg("RXE_IP", "10.79.0.2"));
      tap.nic = f.node.dev.nic;
      tap.rx_ap = rx_ap;
      return super.attach(f);
    endfunction

    // 功能：发往远端 Function 的报文写入 TAP，其余按基类交付。
    // 输入/输出及副作用：写 TAP。
    // 失败/边界：见 rdma_rxe_link.send。
    virtual task deliver(int unsigned src, int unsigned dst, rdma_packet pkt);
      if (funcs[dst].remote)
        tap.send(pkt, funcs[dst].mac);
      else
        super.deliver(src, dst, pkt);
    endtask

    // 功能：TAP 接收循环。
    // 输入/输出及副作用：常驻。
    // 失败/边界：无。
    task run_phase(uvm_phase phase);
      tap.run();
    endtask

    // 功能：rxe 发来的帧都应能解码；关闭 TAP。
    // 输入/输出及副作用：报告。
    // 失败/边界：有不可解码帧报 UVM_ERROR。
    function void report_phase(uvm_phase phase);
      `uvm_info("RXE", $sformatf("frames: sim->rxe %0d, rxe->sim %0d", tap.tx_log.size(),
                tap.rx_log.size()), UVM_LOW)
      if (tap.rx_dropped != 0)
        `uvm_error("RXE", $sformatf("%0d frames from rxe were not decodable", tap.rx_dropped))
      tap.close();
    endfunction
  endclass

  // 远端 Function 的控制面：资源映射到对端进程的唯一 PD/CQ/MR/SRQ 与按 QPN 区分的 QP；连接在 RTS 一步
  //   以 rc_connect/ud_ready 完成（INIT→RTR→RTS）。
  class rdma_rxe_ctrl_driver extends rdma_ctrl_driver;
    `uvm_component_utils(rdma_rxe_ctrl_driver)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_rxe_ctrl_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：远端 Function 的资源请求经对端进程执行，其余（含连接）走基类。
    // 输入/输出及副作用：见各分支。
    // 失败/边界：远端不支持的操作返回 UNSUPPORTED_OPCODE。
    protected virtual task execute(rdma_ctrl_item item);
      rdma_res_func f;
      rdma_rxe_buf b;
      string reply;

      f = env.res.funcs[item.func];
      if (!f.remote || item.op inside {RDMA_CTRL_CONNECT, RDMA_CTRL_MODIFY_QP}) begin
        super.execute(item);
        return;
      end
      case (item.op)
        RDMA_CTRL_ALLOC_PD:
          register(item, f, rdma_res_pd::type_id::create("rxe_pd"), 0, {});
        RDMA_CTRL_CREATE_CQ:
          register(item, f, rdma_res_cq::type_id::create("rxe_cq"), 0, {});
        RDMA_CTRL_ALLOC_BUF: begin
          reply = rdma_rxe_plugin::peer.cmd($sformatf("mr %0d", item.size));
          b = rdma_rxe_buf::type_id::create("rxe_buf");
          b.iova = rdma_rxe_peer::field(reply, "addr");
          b.rkey = rdma_rxe_peer::field(reply, "rkey");
          b.size = item.size;
          register(item, f, b, 0, {});
        end
        RDMA_CTRL_REG_MR:
          reg_mr_remote(f, item);
        RDMA_CTRL_CREATE_SRQ: begin
          void'(rdma_rxe_plugin::peer.cmd($sformatf("srq %0d", item.size)));
          register(item, f, rdma_res_srq::type_id::create("rxe_srq"), 0, {item.pd});
        end
        RDMA_CTRL_CREATE_QP:
          create_qp_remote(f, item);
        default:
          item.status = rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                          {"rxe peer: ", item.op.name()});
      endcase
    endtask

    // 功能：远端 MR：覆盖对端进程 MR 的 [offset, offset+len)，key 即其 rkey。
    // 输入/输出及副作用：写资源库。
    // 失败/边界：无。
    protected function void reg_mr_remote(rdma_res_func f, rdma_ctrl_item item);
      rdma_rxe_buf b;
      rdma_res_mr mr;

      void'($cast(b, item.mem));
      mr = rdma_res_mr::type_id::create("rxe_mr");
      mr.mem = b;
      mr.va = b.iova + item.offset;
      mr.len = item.len != 0 ? item.len : b.size - item.offset;
      mr.rights = item.rights;
      mr.key = b.rkey;
      register(item, f, mr, mr.key, {item.pd, item.mem});
    endfunction

    // 功能：远端 QP：qp rc|ud [srq]，编号为对端返回的 QPN。
    // 输入/输出及副作用：对端进程命令；写资源库。
    // 失败/边界：URC 返回 UNSUPPORTED_OPCODE。
    protected function void create_qp_remote(rdma_res_func f, rdma_ctrl_item item);
      rdma_res_qp qp;
      string reply;

      if (item.urc) begin
        item.status = rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "rxe has no URC");
        return;
      end
      reply = rdma_rxe_plugin::peer.cmd({"qp ", item.qp_type == RDMA_DRV_QPT_UD ? "ud" : "rc",
                                         item.srq != null ? " srq" : ""});
      qp = rdma_res_qp::type_id::create("rxe_qp");
      qp.qp_type = item.qp_type;
      qp.send_cq = item.send_cq;
      qp.recv_cq = item.recv_cq;
      qp.srq = item.srq;
      qp.qkey = env.cfg.ud_qkey;
      qp.mtu = env.cfg.mtu;
      register(item, f, qp, rdma_rxe_peer::field(reply, "qpn"), {item.pd, item.send_cq});
    endfunction

    // 功能：远端 QP 只在迁到 RTS 时一次完成连接（RC：rc_connect，PSN 0、rxe 侧 timeout 14；UD：ud_ready）；
    //   仿真 QP 走基类。
    // 输入/输出及副作用：对端进程命令；广播 CHANGED。
    // 失败/边界：其它迁移不动作（INIT/RTR 由 RTS 一步完成）。
    protected virtual task modify(rdma_res_qp qp, rdma_drv_qp_state_e state, rdma_res_qp peer,
                                  output rdma_status status);
      if (!qp.owner.remote) begin
        super.modify(qp, state, peer, status);
        return;
      end
      status = rdma_status::success();
      if (state != RDMA_DRV_QPS_RTS)
        return;
      if (qp.ud())
        void'(rdma_rxe_plugin::peer.cmd($sformatf("ud_ready %0d 0x%0h 0", qp.id, qp.qkey)));
      else
        void'(rdma_rxe_plugin::peer.cmd($sformatf("rc_connect %0d %0d 0 0 %s %0d 14 %0d %0d",
              qp.id, peer.id, rdma_rxe_util::arg("RXE_SIM_IP", "10.79.0.1"), qp.mtu,
              env.cfg.retry, env.cfg.rnr_retry)));
      env.res.set_state(qp, RDMA_RES_ALIVE);
    endtask
  endclass

  // 远端 Function 的投递：recv/srq_recv/send/send_ud 命令（单 SGE；wr_id 原样带给对端）。
  class rdma_rxe_verb_driver extends rdma_verb_driver;
    `uvm_component_utils(rdma_rxe_verb_driver)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_rxe_verb_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：远端 RECV（srq 非空时 srq_recv）。
    // 输入/输出及副作用：对端进程命令。
    // 失败/边界：多 SGE 返回 UNSUPPORTED_OPCODE。
    protected virtual task post_recv(rdma_verb_item item, rdma_drv_sge sges[$],
                                     output rdma_status status);
      if (!env.res.funcs[func].remote) begin
        super.post_recv(item, sges, status);
        return;
      end
      if (!single(item, status))
        return;
      if (item.srq != null)
        issue($sformatf("srq_recv %0d %0d 0x%0h", buf_offset(item.lmr, item.local_offset),
                        item.length, item.wr_id), status);
      else
        issue($sformatf("recv %0d %0d %0d 0x%0h", item.qp.id,
                        buf_offset(item.lmr, item.local_offset), item.length, item.wr_id), status);
    endtask

    // 功能：远端 SQ 请求：send <qp> <op> <off> <len> <wr_id> [imm|raddr rkey [imm|cmp swap]]；UD 为
    //   send_ud（目的 IP 为仿真侧）。
    // 输入/输出及副作用：对端进程命令。
    // 失败/边界：多 SGE 或 UD 非 SEND 返回 UNSUPPORTED_OPCODE。
    protected virtual task post_send(rdma_verb_item item, rdma_drv_sge sges[$],
                                     output rdma_status status);
      string line;

      if (!env.res.funcs[func].remote) begin
        super.post_send(item, sges, status);
        return;
      end
      if (!single(item, status))
        return;
      if (item.qp.ud()) begin
        if (item.op != RDMA_VERB_SEND)
          status = rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "rxe peer: UD SEND only");
        else
          issue($sformatf("send_ud %0d %0d %0d 0x%0h %s %0d 0x%0h", item.qp.id,
                          buf_offset(item.lmr, item.local_offset), item.length, item.wr_id,
                          rdma_rxe_util::arg("RXE_SIM_IP", "10.79.0.1"), item.qp.peer.id,
                          item.qp.peer.qkey), status);
        return;
      end
      line = $sformatf("send %0d %s %0d %0d 0x%0h", item.qp.id, op_name(item.op),
                       buf_offset(item.lmr, item.local_offset), item.length, item.wr_id);
      if (item.rmr != null)
        line = {line, $sformatf(" 0x%0h 0x%0h", item.rmr.va + item.remote_offset, item.rmr.key)};
      if (item.op inside {RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE_IMM})
        line = {line, $sformatf(" 0x%0h", item.imm)};
      if (item.atomic())
        line = {line, $sformatf(" 0x%0h 0x%0h", item.compare_value, item.swap_add_value)};
      issue(line, status);
    endtask

    // 功能：verb → 对端进程的 op 名（faa 的加数在 swap 位置）。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：RECV 不经此路径。
    protected function string op_name(rdma_verb_op_e op);
      case (op)
        RDMA_VERB_SEND_IMM:  return "send_imm";
        RDMA_VERB_WRITE:     return "write";
        RDMA_VERB_WRITE_IMM: return "write_imm";
        RDMA_VERB_READ:      return "read";
        RDMA_VERB_CMP_SWAP:  return "cas";
        RDMA_VERB_FETCH_ADD: return "faa";
        default:             return "send";
      endcase
    endfunction

    // 功能：远端只支持单 SGE。
    // 输入/输出及副作用：status 输出。
    // 失败/边界：多 SGE 返回 0。
    protected function bit single(rdma_verb_item item, output rdma_status status);
      status = item.sge_count <= 1 ? rdma_status::success() :
               rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "rxe peer: single SGE only");
      return status.ok();
    endfunction

    // 功能：发命令，应答须为 OK。
    // 输入/输出及副作用：对端进程命令。
    // 失败/边界：失败返回 INVALID_STATE。
    protected function void issue(string line, output rdma_status status);
      status = rdma_rxe_plugin::peer.cmd(line) == "OK" ? rdma_status::success() :
               rdma_status::make(RDMA_SC_INVALID_STATE, {"rxe peer: ", line});
    endfunction
  endclass

  // 远端 Function 的完成：poll 对端进程（ibv_wc → rdma_drv_wc）；仿真 Function 走基类。
  class rdma_rxe_verb_monitor extends rdma_verb_monitor;
    `uvm_component_utils(rdma_rxe_verb_monitor)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_rxe_verb_monitor", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：远端 Function：循环 poll，有完成即广播，否则等待 poll_interval。
    // 输入/输出及副作用：常驻。
    // 失败/边界：无。
    task run_phase(uvm_phase phase);
      string reply;

      env.wait_ready();
      if (!env.res.funcs[func].remote) begin
        super.run_phase(phase);
        return;
      end
      forever begin
        reply = rdma_rxe_plugin::peer.cmd("poll 0");
        if (reply == "OK none")
          #(env.cfg.poll_interval);
        else
          publish(wc_of(reply));
      end
    endtask

    // 功能：对端应答 → rdma_drv_wc（ibv_wc_status：0 成功、5 FLUSH、9 REM_INV_REQ、10 REM_ACCESS、
    //   11 REM_OP，其余 GENERAL；opcode ≥ 128 为接收完成）。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：无。
    protected function rdma_drv_wc wc_of(string reply);
      rdma_drv_wc wc;

      wc = rdma_drv_wc::type_id::create("rxe_wc");
      wc.wr_id = rdma_rxe_peer::field(reply, "wr_id");
      case (rdma_rxe_peer::field(reply, "status"))
        0: wc.status = RDMA_DRV_WC_SUCCESS;
        5: wc.status = RDMA_DRV_WC_FLUSH_ERR;
        9: wc.status = RDMA_DRV_WC_REM_INV_REQ_ERR;
        10: wc.status = RDMA_DRV_WC_REM_ACCESS_ERR;
        11: wc.status = RDMA_DRV_WC_REM_OP_ERR;
        default: wc.status = RDMA_DRV_WC_GENERAL_ERR;
      endcase
      wc.is_recv = rdma_rxe_peer::field(reply, "opcode") >= 128;
      wc.byte_len = rdma_rxe_peer::field(reply, "len");
      wc.imm = rdma_rxe_peer::field(reply, "imm");
      wc.src_qp = rdma_rxe_peer::field(reply, "src_qp");
      wc.qpn = rdma_rxe_peer::field(reply, "qp");
      return wc;
    endfunction
  endclass

  // rxe 插件：一个远端 Function（下标在 dpu Function 之后），链路 rdma_link_rxe；仿真侧 QP 不设响应
  //   超时（仿真时间与真实时间不同步）。对端进程 +RXE_PEER=<path>，设备 +RXE_DEV（rxe_rtap0），
  //   GID 下标 +RXE_GID（1）。
  class rdma_rxe_plugin extends rdma_env_plugin;
    `uvm_object_utils(rdma_rxe_plugin)

    static rdma_rxe_peer peer;

    // 功能：构造。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_rxe_plugin");
      super.new(name);
    endfunction

    // 功能：安装覆盖、选择链路、声明一个远端 Function、仿真侧不超时；Q_Key 用非受控值（最高位为 1 的
    //   受控 Q_Key 需要特权才能设置到 rxe QP）。
    // 输入/输出及副作用：修改 env 配置与 factory。
    // 失败/边界：无。
    virtual function void pre_build(rdma_env env);
      rdma_ctrl_driver::type_id::set_type_override(rdma_rxe_ctrl_driver::get_type());
      rdma_verb_driver::type_id::set_type_override(rdma_rxe_verb_driver::get_type());
      rdma_verb_monitor::type_id::set_type_override(rdma_rxe_verb_monitor::get_type());
      env.cfg.link_type = "rdma_link_rxe";
      env.cfg.remote_funcs = 1;
      env.cfg.timeout = 0;
      env.cfg.ud_qkey = 32'h1234_5678;
    endfunction

    // 功能：启动对端进程、打开 rxe 设备，登记远端 Function（MAC 为 TAP 的 MAC）。
    // 输入/输出及副作用：创建子进程；写资源库与链路。
    // 失败/边界：启动失败 UVM_FATAL。
    virtual task start(rdma_env env);
      rdma_link_rxe link;
      rdma_res_func f;

      void'($cast(link, env.link));
      peer = rdma_rxe_peer::type_id::create("rxe_peer");
      if (!peer.start(rdma_rxe_util::arg("RXE_PEER", "")))
        `uvm_fatal("RXE", "cannot start rxe_peer (+RXE_PEER=<path>)")
      void'(peer.cmd({"open ", rdma_rxe_util::arg("RXE_DEV", "rxe_rtap0"), " ",
                      rdma_rxe_util::arg("RXE_GID", "1")}));
      f = env.res.add_func(null, link.rxe_mac, 1'b1);
      void'(link.attach(f));
    endtask

    // 功能：停止对端进程。
    // 输入/输出及副作用：结束子进程。
    // 失败/边界：无。
    virtual function void report(rdma_env env);
      peer.stop();
    endfunction
  endclass
endpackage
