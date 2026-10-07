// 目录：验证组件层 tb/rdma_mem_model.sv。
// 层：验证组件。
// 职责：期望内存：每个被流量触及的 buffer 一份字节镜像（首次触及时从真实内存载入），由 scoreboard 按
//   原始数据与操作语义写入；提供区域比对与整块比对（发现越界写）。
// 依赖：rdma_res_buf（读真实内存）。
// 所有权：镜像归模型；buffer 归资源库。
// 生命周期：scoreboard 创建，仿真期间常驻。

class rdma_mem_model extends uvm_object;
  `uvm_object_utils(rdma_mem_model)

  localparam int unsigned MAX_REPORTED_DIFFS = 8;

  protected byte unsigned img[longint unsigned][$];
  protected rdma_res_buf bufs[longint unsigned];

  // 功能：构造空模型。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_mem_model");
    super.new(name);
  endfunction

  // 功能：开始跟踪 buffer：从真实内存载入镜像（已跟踪则不变）。
  // 输入/输出及副作用：读真实内存。
  // 失败/边界：读取失败报 UVM_ERROR，镜像为全 0。
  function void track(rdma_res_buf b);
    rdma_bytes_t raw;

    if (b == null || bufs.exists(b.uid))
      return;
    bufs[b.uid] = b;
    if (!b.read(0, b.size, raw).ok()) begin
      `uvm_error("RDMA_MEM", {"initial load failed: ", b.describe()})
      raw = new[b.size];
    end
    img[b.uid] = {};
    foreach (raw[i])
      img[b.uid].push_back(raw[i]);
  endfunction

  // 功能：写镜像 [off, off+data.size())。
  // 输入/输出及副作用：修改镜像。
  // 失败/边界：越界部分忽略。
  function void write(rdma_res_buf b, int unsigned off, byte unsigned data[$]);
    track(b);
    foreach (data[i])
      if (off + i < img[b.uid].size())
        img[b.uid][off + i] = data[i];
  endfunction

  // 功能：读镜像 [off, off+len)。
  // 输入/输出及副作用：data 输出。
  // 失败/边界：越界部分为 0。
  function void read(rdma_res_buf b, int unsigned off, int unsigned len,
                     output byte unsigned data[$]);
    track(b);
    data = {};
    for (int unsigned i = 0; i < len; i++)
      data.push_back(off + i < img[b.uid].size() ? img[b.uid][off + i] : 8'h00);
  endfunction

  // 功能：以真实内存 [off, off+len) 为期望（内容无法预测的区域，如远端写入的 GRH）。
  // 输入/输出及副作用：读真实内存，修改镜像。
  // 失败/边界：读失败报 UVM_ERROR。
  function void accept(rdma_res_buf b, int unsigned off, int unsigned len);
    rdma_bytes_t raw;

    if (!b.read(off, len, raw).ok())
      `uvm_error("RDMA_MEM", {"read failed: ", b.describe()})
    write(b, off, raw);
  endfunction

  // 功能：真实内存 [off, off+len) 与镜像比对，what 用于定位（如具体 WR）。
  // 输入/输出及副作用：读真实内存；差异报 UVM_ERROR（最多 8 个）。
  // 失败/边界：返回差异字节数（读失败按整段计）。
  function int unsigned compare(rdma_res_buf b, int unsigned off, int unsigned len, string what);
    rdma_bytes_t raw;
    int unsigned diffs;

    track(b);
    if (!b.read(off, len, raw).ok()) begin
      `uvm_error("RDMA_MEM", {"read failed: ", what})
      return len;
    end
    diffs = 0;
    foreach (raw[i]) begin
      if (raw[i] == img[b.uid][off + i])
        continue;
      if (++diffs <= MAX_REPORTED_DIFFS)
        `uvm_error("RDMA_MEM", $sformatf("%s: %s +%0h memory %02h != expected %02h", what,
                   b.describe(), off + i, raw[i], img[b.uid][off + i]))
    end
    return diffs;
  endfunction

  // 功能：全部跟踪中的 buffer 整块比对。
  // 输入/输出及副作用：读真实内存。
  // 失败/边界：返回差异字节总数。
  function int unsigned compare_all();
    int unsigned diffs;

    diffs = 0;
    foreach (bufs[u])
      if (bufs[u].state != RDMA_RES_DESTROYED)
        diffs += compare(bufs[u], 0, bufs[u].size, "final");
    return diffs;
  endfunction
endclass
