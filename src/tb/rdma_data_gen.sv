// 目录：验证组件层 tb/rdma_data_gen.sv。
// 层：验证组件。
// 职责：源数据生成：用 net_packet 的负载引擎（空协议栈 packet，payload_mode 为 RANDOM/FIXED/
//   INCREMENT/PATTERN，pkt_len = 长度，do_pack 后 raw_data 即负载）生成 verb 的原始数据。
//   原始数据由 verb driver 写入源内存并保留在 item 上，scoreboard 以它为唯一判据。
// 依赖：rdma_netpkt_pkg 中的 net_packet packet 类与 payload_mode_e。
// 所有权：一个共享 packet 对象（构造开销大，只建一次）。
// 生命周期：首次调用时创建，仿真期间常驻。

class rdma_data_gen;
  protected static packet engine;

  // 功能：按模式生成 len 字节。FIXED 用 fixed，PATTERN 循环 pattern，INCREMENT 为 0,1,2...（模 256），
  //   RANDOM 来自仿真随机数（随种子复现）。
  // 输入/输出及副作用：data 输出；修改共享 packet。
  // 失败/边界：len 为 0 时 data 为空。
  static function void make(payload_mode_e mode, byte unsigned fixed, byte unsigned pattern[$],
                            int unsigned len, output byte unsigned data[$]);
    if (engine == null)
      engine = new();
    engine.payload_mode = mode;
    engine.payload_fixed_val = fixed;
    engine.payload_pattern = pattern;
    engine.pkt_len = len;
    engine.do_pack();
    data = engine.raw_data;
  endfunction
endclass
