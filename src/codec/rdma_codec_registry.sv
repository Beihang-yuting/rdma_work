// 目录：硬件编解码层 codec/rdma_codec_registry.sv。
// 职责：实现 rdma_codec_registry 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_codec_registry.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_codec_registry extends uvm_object;
  `uvm_object_utils(rdma_codec_registry)

  protected rdma_codec_base codecs[string];

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_codec_registry");
    super.new(name);
  endfunction

  // 功能：处理 contains_delimiter：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 i 用于执行 contains_delimiter；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：contains_delimiter 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function bit contains_delimiter(string component);
    for (int unsigned i = 0; i < component.len(); i++) begin
      if (component.getc(i) == 8'h7c)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：处理 canonicalize：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 key, canonical 用于执行 canonicalize；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：canonicalize 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status canonicalize(
    rdma_codec_key key,
    output string canonical
  );
    canonical = "";
    if (key.hw_version.len() == 0 || key.object_type.len() == 0 ||
        key.variant.len() == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "codec key has an empty required string component"
      );
    if (contains_delimiter(key.hw_version) ||
        contains_delimiter(key.object_type) ||
        contains_delimiter(key.variant))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "codec key string component contains reserved delimiter '|'"
      );
    if (!(key.image_kind inside {
          RDMA_IMAGE_QPC, RDMA_IMAGE_CQC, RDMA_IMAGE_MRT,
          RDMA_IMAGE_SRQC, RDMA_IMAGE_CEQC, RDMA_IMAGE_AEQC,
          RDMA_IMAGE_CMQ_SQE, RDMA_IMAGE_CMQ_CQE, RDMA_IMAGE_SQE,
          RDMA_IMAGE_RQE, RDMA_IMAGE_CQE, RDMA_IMAGE_CEQE,
          RDMA_IMAGE_AEQE, RDMA_IMAGE_DOORBELL
        }))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "codec key image kind is invalid");

    canonical = $sformatf("%s|%0d|%s|%s|%02x",
                          key.hw_version, key.image_kind,
                          key.object_type, key.variant, key.opcode);
    return rdma_status::success();
  endfunction

  // 功能：处理 register_codec：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 key, codec 用于执行 register_codec；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：register_codec 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status register_codec(
    rdma_codec_key key,
    rdma_codec_base codec
  );
    string canonical;
    rdma_status status;

    status = canonicalize(key, canonical);
    if (!status.ok())
      return status;
    if (codec == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "cannot register a null codec");
    if (codecs.exists(canonical)) begin
      `uvm_fatal("RDMA_CODEC_DUPLICATE",
                 $sformatf("duplicate codec registration for %s",
                           canonical))
      // A report catcher may consume the fatal in a negative unit test.  The
      // operation must still fail and leave the original registration intact.
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "duplicate codec registration");
    end

    codecs[canonical] = codec;
    return rdma_status::success();
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function rdma_status lookup(
    rdma_codec_key key,
    output rdma_codec_base codec
  );
    string canonical;
    rdma_status status;

    codec = null;
    status = canonicalize(key, canonical);
    if (!status.ok())
      return status;
    if (!codecs.exists(canonical))
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        $sformatf("no codec registered for %s", canonical)
      );

    codec = codecs[canonical];
    return rdma_status::success();
  endfunction

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  virtual function void clear();
    codecs.delete();
  endfunction

  // 功能：处理 list_keys：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 delete 用于执行 list_keys；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：list_keys 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function void list_keys(output string keys[$]);
    keys.delete();
    foreach (codecs[canonical])
      keys.push_back(canonical);
    if (keys.size() > 1)
      keys.sort();
  endfunction
endclass
