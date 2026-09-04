// 目录：硬件编解码层 codec/xtr_v1/rdma_xtr_v1_queue_page_codec.sv。
// 职责：实现 rdma_xtr_v1_queue_page_codec 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_xtr_v1_queue_page_codec.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_queue_pd_entry extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_pd_entry)

  rdma_iova_t page_iova;
  int unsigned rdma_vf_id;
  bit valid;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_xtr_v1_queue_pd_entry");
    super.new(name);
    page_iova = '0;
    rdma_vf_id = 0;
    valid = 1'b0;
  endfunction
endclass

class rdma_xtr_v1_queue_pd_codec extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_pd_codec)

  localparam int unsigned PAGE_BYTES = 4096;
  localparam int unsigned MAX_PAGES = 512;
  localparam int unsigned TABLE_BYTES = MAX_PAGES * 8;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_xtr_v1_queue_pd_codec");
    super.new(name);
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_entry）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status encode_entry(
    rdma_xtr_v1_queue_pd_entry entry,
    inout byte unsigned bytes[]
  );
    bit [63:0] word;
    byte unsigned encoded[];

    if (entry == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD entry is null");
    if (!rdma_queue_aligned(entry.page_iova.value, PAGE_BYTES))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD entry IOVA is unaligned");
    if (entry.rdma_vf_id > 8'hff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD entry VF ID exceeds eight bits");

    word = (entry.page_iova.value & 64'hffff_ffff_ffff_f000) |
           ((longint'(entry.rdma_vf_id) & 64'hff) << 4) |
           longint'(entry.valid);
    encoded = new[8];
    for (int unsigned i = 0; i < 8; i++)
      encoded[i] = word[63 - i*8 -: 8];
    bytes = encoded;
    return rdma_status::success();
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_table）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_status encode_table(
    rdma_queue_dma_page_ref pages[$],
    int unsigned rdma_vf_id,
    inout byte unsigned bytes[]
  );
    rdma_status status;
    byte unsigned encoded[];
    byte unsigned entry_bytes[];
    rdma_xtr_v1_queue_pd_entry entry;
    longint unsigned expected_offset;
    longint unsigned logical_index;

    if (rdma_vf_id > 8'hff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD table VF ID exceeds eight bits");
    if (pages.size() == 0 || pages.size() > MAX_PAGES)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD table page count is outside 1..512");

    // Preflight every page before allocating or publishing any output.
    foreach (pages[i]) begin
      if (pages[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "queue PD table contains a null page");
      status = pages[i].validate();
      if (!status.ok())
        return status;
      expected_offset = longint'(i) * PAGE_BYTES;
      if (pages[i].logical_page_offset != expected_offset)
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue PD table logical page offsets are not contiguous");
    end

    encoded = new[TABLE_BYTES];
    foreach (encoded[i])
      encoded[i] = 8'h00;

    foreach (pages[i]) begin
      logical_index = pages[i].logical_page_offset / PAGE_BYTES;
      entry = rdma_xtr_v1_queue_pd_entry::type_id::create(
          $sformatf("queue_pd_entry_%0d", logical_index));
      entry.page_iova = pages[i].page_iova;
      entry.rdma_vf_id = rdma_vf_id;
      entry.valid = 1'b1;
      entry_bytes = new[0];
      status = encode_entry(entry, entry_bytes);
      if (!status.ok())
        return status;
      for (int unsigned j = 0; j < 8; j++)
        encoded[(logical_index * 8) + j] = entry_bytes[j];
    end

    bytes = encoded;
    return rdma_status::success();
  endfunction
endclass
