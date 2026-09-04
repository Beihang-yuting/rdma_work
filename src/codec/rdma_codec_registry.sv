// 目录：硬件编解码层 codec/rdma_codec_registry.sv。
// 职责：实现 rdma_codec_registry 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_codec_registry.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_codec_registry extends uvm_object;
  `uvm_object_utils(rdma_codec_registry)

  protected rdma_codec_base codecs[string];

  // 功能：构造 rdma_codec_registry，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_codec_registry 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_codec_registry");
    super.new(name);
  endfunction

  // 功能：contains_delimiter 比较 component 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：component（输入）；contains_delimiter 读取 component 并使用字段 i；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：contains_delimiter 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit contains_delimiter(string component);
    for (int unsigned i = 0; i < component.len(); i++) begin
      if (component.getc(i) == 8'h7c)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：在 rdma_codec_registry 中，canonicalize 规范化输入 key/恢复记录并检查必需字段，使同一语义对象只产生一种登记表示。
  // 输入/输出及副作用：key（输入）、canonical（输出）；canonicalize 读取 key、canonical 并使用字段 canonical，并写入 canonical；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：canonicalize 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “codec key has an empty required string component”；“codec key string component contains reserved delimiter '|'”；“codec key image kind is invalid”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
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

  // 功能：在 rdma_codec_registry 中，register_codec 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：key（输入）、codec（输入）；register_codec 先依据 !status.ok(；codec == null；codecs.exists(canonical 校验 key、codec；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：register_codec 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal，不保留部分有效快照。
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

  // 功能：在 rdma_codec_registry 中，lookup 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：key（输入）、codec（输出）；lookup 读取 key、codec 并使用字段 codec、status，并写入 codec；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：lookup 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_codec_registry 中，clear 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function void clear();
    codecs.delete();
  endfunction

  // 功能：在 rdma_codec_registry 中，list_keys 导出并排序所有 canonical codec key，向调用方提供稳定、无内部别名的注册表视图。
  // 输入/输出及副作用：keys（输出）；list_keys 读取 keys 并使用输入参数和固定枚举/常量，并写入 keys；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：list_keys 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void list_keys(output string keys[$]);
    keys.delete();
    foreach (codecs[canonical])
      keys.push_back(canonical);
    if (keys.size() > 1)
      keys.sort();
  endfunction
endclass
