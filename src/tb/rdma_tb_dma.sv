// 目录：验证组件层 tb/rdma_tb_dma.sv。
// 职责：NIC 模型的设备侧 DMA：按 lkey/rkey 经 resource manager 反查 MR，校验 key、范围与访问权限，
//   再通过 host_mem 读写 MR 的 backing mapping；同时提供 WQE ring 读取。
// 依赖：rdma_resource_manager.lookup_local_resource、rdma_host_mem_api、rdma_mr/backing 模型。
// 所有权与生命周期：只借用节点配置；读出的数据为调用方持有的副本。

// DMA 校验失败的类别，决定请求方 CQE ecode 或响应方 NAK 类型。
typedef enum bit [1:0] {
  RDMA_TB_DMA_OK,
  RDMA_TB_DMA_KEY_ERROR,
  RDMA_TB_DMA_ACCESS_ERROR,
  RDMA_TB_DMA_IO_ERROR
} rdma_tb_dma_result_e;

class rdma_tb_dma extends uvm_object;
  `uvm_object_utils(rdma_tb_dma)

  rdma_tb_node_cfg cfg;

  // 功能：构造未绑定配置的 DMA helper。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：使用前必须设置 cfg。
  function new(string name = "rdma_tb_dma");
    super.new(name);
    cfg = null;
  endfunction

  // 功能：把 (key, va, len) 解析为 MR backing mapping 与偏移。
  // 输入/输出及副作用：remote 选择匹配 rkey 还是 lkey；need_write/need_atomic 决定所需权限；
  //   mapping/offset 输出；只读 manager registry。
  // 失败/边界：MR 不存在/非 ACTIVE/key 不符返回 KEY_ERROR；越界或缺权限返回 ACCESS_ERROR。
  function rdma_tb_dma_result_e resolve(
    bit [31:0] key,
    bit remote,
    bit need_write,
    bit need_atomic,
    bit [63:0] va,
    longint unsigned len,
    output rdma_dma_mapping mapping,
    output longint unsigned offset
  );
    rdma_resource resource;
    rdma_mr mr;
    rdma_status status;
    bit permitted;

    mapping = null;
    offset = 0;
    status = cfg.engine.manager.lookup_local_resource(
      cfg.owner(), RDMA_RESOURCE_MR, key[31:8], resource);
    if (status == null || !status.ok() || !$cast(mr, resource) || mr == null ||
        mr.state != RDMA_RESOURCE_ACTIVE || (remote ? mr.rkey : mr.lkey) != key)
      return RDMA_TB_DMA_KEY_ERROR;
    if (remote)
      permitted = need_atomic ? mr.access.remote_atomic :
                  need_write ? mr.access.remote_write : mr.access.remote_read;
    else
      permitted = !need_write || mr.access.local_write;
    if (!permitted || va < mr.iova.value ||
        va + len > mr.iova.value + mr.length ||
        mr.backing_refs.size() == 0 || mr.backing_refs[0] == null ||
        mr.backing_refs[0].mapping == null)
      return RDMA_TB_DMA_ACCESS_ERROR;
    mapping = mr.backing_refs[0].mapping;
    offset = va - mapping.iova.value;
    return RDMA_TB_DMA_OK;
  endfunction

  // 功能：经 MR 校验后读取 len 字节。
  // 输入/输出及副作用：data 输出读到的字节；只读 host 内存。
  // 失败/边界：校验失败返回对应类别，host_mem 读失败返回 IO_ERROR；失败时 data 为空。
  function rdma_tb_dma_result_e read(
    bit [31:0] key,
    bit remote,
    bit [63:0] va,
    int unsigned len,
    output byte unsigned data[$]
  );
    rdma_dma_mapping mapping;
    longint unsigned offset;
    rdma_tb_dma_result_e result;
    rdma_status status;
    byte raw[];

    data.delete();
    result = resolve(key, remote, 1'b0, 1'b0, va, len, mapping, offset);
    if (result != RDMA_TB_DMA_OK || len == 0)
      return result;
    status = cfg.engine.host_mem.read(mapping, offset, len, raw);
    if (status == null || !status.ok() || raw.size() != len)
      return RDMA_TB_DMA_IO_ERROR;
    foreach (raw[i])
      data.push_back(raw[i]);
    return RDMA_TB_DMA_OK;
  endfunction

  // 功能：经 MR 校验后写入 data。
  // 输入/输出及副作用：写 host 内存。
  // 失败/边界：校验失败返回对应类别（不写任何字节），host_mem 写失败返回 IO_ERROR。
  function rdma_tb_dma_result_e write(
    bit [31:0] key,
    bit remote,
    bit need_atomic,
    bit [63:0] va,
    byte unsigned data[$]
  );
    rdma_dma_mapping mapping;
    longint unsigned offset;
    rdma_tb_dma_result_e result;
    rdma_status status;
    byte raw[];

    result = resolve(key, remote, 1'b1, need_atomic, va, data.size(), mapping,
                     offset);
    if (result != RDMA_TB_DMA_OK || data.size() == 0)
      return result;
    raw = new[data.size()];
    foreach (data[i])
      raw[i] = data[i];
    status = cfg.engine.host_mem.write(mapping, offset, raw);
    if (status == null || !status.ok())
      return RDMA_TB_DMA_IO_ERROR;
    return RDMA_TB_DMA_OK;
  endfunction

  // 功能：读取 QP 的第 index 个 64B WQE 并按 codec 解码。
  // 输入/输出及副作用：send 选择 SQ/RQ；model 输出解码结果；只读 host 内存。
  // 失败/边界：backing 缺失、读失败、codec 缺失或解码失败返回非 OK，model 为 null。
  function rdma_status read_wqe(
    rdma_qp qp,
    bit send,
    int unsigned index,
    output rdma_hw_model model
  );
    rdma_qp_backing_ref ref_value;
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_image image;
    rdma_status status;
    byte raw[];

    model = null;
    ref_value = (qp == null || qp.qp_plan == null) ? null :
                (send ? qp.qp_plan.sq_ref : qp.qp_plan.rq_ref);
    if (ref_value == null || ref_value.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "tb WQE ring backing is missing");
    status = cfg.engine.host_mem.read(
      ref_value.mapping, ref_value.mapping_offset + longint'(index) * RDMA_WQE_BYTES,
      RDMA_WQE_BYTES, raw);
    if (status == null || !status.ok())
      return rdma_status::nonnull(status, "tb WQE read returned null");
    image = rdma_hw_image::type_id::create("tb_wqe_image");
    foreach (raw[i])
      image.bytes.push_back(raw[i]);
    image.length = RDMA_WQE_BYTES;
    image.alignment = RDMA_WQE_BYTES;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = send ? RDMA_IMAGE_SQE : RDMA_IMAGE_RQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = cfg.engine.binding.generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    key = '{hw_version:"rdma", image_kind:image.image_kind,
            object_type:send ? "sqe" : "rqe",
            variant:!send ? "default" :
                    qp.transport == RDMA_TRANSPORT_UD ? "ud" :
                    qp.transport == RDMA_TRANSPORT_URC ? "urc" : "rc",
            opcode:8'h00};
    status = cfg.engine.registry.lookup(key, codec);
    if (status == null || !status.ok() || codec == null)
      return rdma_status::nonnull(status, "tb WQE codec lookup failed",
                                  RDMA_SC_CODEC_ERROR);
    status = codec.decode(image, model);
    if (status == null || !status.ok() || model == null) begin
      model = null;
      return rdma_status::nonnull(status, "tb WQE decode returned null",
                                  RDMA_SC_CODEC_ERROR);
    end
    return rdma_status::success();
  endfunction
endclass
