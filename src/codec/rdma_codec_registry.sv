// 目录/层次：src/codec，位于语义模型与具体硬件 codec 实现之间的注册层。
// 文件职责：把完整 rdma_codec_key 规范化为稳定字符串，并提供 codec 的唯一登记、
// 查找、清空与有序枚举接口；本文件不执行 encode/decode，也不补选默认 variant。
// 主要依赖：rdma_types_pkg 的 image-kind/status 定义、rdma_codec_base 与 UVM object；
// 不依赖 queue runtime、Host-memory、PCIe、网络组件或 dpu_common topology。
// 所有权与生命周期：registry 拥有关联数组及其 key，但只保存 codec 非拥有引用；
// codec 由创建它的 profile/registry owner 管理，clear 仅解除引用而不销毁对象。

// 设计说明：完整 key 的五个维度共同构成 codec authority。集中规范化可防止登记与
// 查询使用不同拼接规则；缺项、保留分隔符、未知 image kind 和重复 key 均 fail closed。

class rdma_codec_registry extends uvm_object;
  `uvm_object_utils(rdma_codec_registry)

  protected rdma_codec_base codecs[string];

  // 功能：构造一个 codec 表为空的 registry，并把 name 交给 UVM 基类。
  // 输入/输出及副作用：name 为对象名；关联数组 codecs 保持空表，不登记 codec，
  //   也不取得任何外部对象的所有权。
  // 失败/边界：构造阶段没有必需外部依赖；后续 lookup 在尚未登记目标 key 时返回
  //   RDMA_SC_UNSUPPORTED_OPCODE，而不是把空表解释为默认 codec。
  function new(string name = "rdma_codec_registry");
    super.new(name);
  endfunction

  // 功能：contains_delimiter 检查一个 key 字符串分量是否含 canonical 格式保留的
  //   `|` 字符，供 canonicalize 排除可产生拼接歧义的输入。
  // 输入/输出及副作用：component 为只读字符串；返回是否发现 8'h7c，不修改
  //   component、codec 表或任何外部状态。
  // 失败/边界：空字符串和不含分隔符的字符串返回 0；本函数只检查保留字符，
  //   空字符串是否合法由 canonicalize 的必填字段检查决定。
  protected function bit contains_delimiter(string component);
    for (int unsigned i = 0; i < component.len(); i++) begin
      if (component.getc(i) == 8'h7c)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：canonicalize 校验 codec key 的必填字符串与 image kind，并按固定五元组
  //   顺序生成 hw_version|image_kind|object_type|variant|opcode 唯一索引。
  // 输入/输出及副作用：key 为值输入，canonical 为输出；入口先清空 canonical，
  //   成功时填入小写十六进制 opcode 的稳定字符串，不读取或修改 codecs。
  // 失败/边界：hw_version/object_type/variant 为空、任一字符串含 `|`，或
  //   image_kind 不在受支持枚举集合时返回 RDMA_SC_INVALID_ARGUMENT 并保持输出为空。
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

  // 功能：register_codec 把非空 codec 非拥有引用登记到完整 key 的 canonical 索引，
  //   建立后续 lookup 的唯一 authority。
  // 输入/输出及副作用：key 与 codec 为输入；成功时向 codecs 新增一个引用并返回
  //   RDMA_SC_OK，不 clone codec，也不改变已有登记项。
  // 失败/边界：key 规范化失败或 codec=null 时返回对应非成功 status；重复 canonical
  //   key 报 RDMA_CODEC_DUPLICATE fatal，并在 catcher 消费 fatal 时仍返回
  //   RDMA_SC_INVALID_STATE，原登记保持不变。
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
      // 设计说明：负向单测可能用 report catcher 消费 fatal，因此此分支还必须显式
      // 返回失败，确保 caller 不会把重复登记误判为成功，且原引用保持不变。
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "duplicate codec registration");
    end

    codecs[canonical] = codec;
    return rdma_status::success();
  endfunction

  // 功能：lookup 作为可覆写的 registry 读取边界，按完整 codec key 查找唯一登记项，
  //   使 adapter/test registry 能注入明确失败而不改写调用方或基础 codec 表。
  // 输入/输出及副作用：key 为输入，codec 为输出；基类先置 codec=null，成功返回
  //   登记项的非拥有引用与 RDMA_SC_OK，不复制 codec 或改变 registry 内容。
  // 失败/边界：key 非法或条目缺失时保持 codec=null 并返回明确非成功 status；override
  //   必须保留完整 key authority 与输出初始化，返回 null status 时 caller 必须 fail closed。
  virtual function rdma_status lookup(
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

  // 功能：clear 删除 registry 的全部 key→codec 关联，恢复为空表状态。
  // 输入/输出及副作用：无参数和返回值；只清空 codecs 关联数组中的非拥有引用，
  //   不调用 codec 方法，也不销毁 codec 对象。
  // 失败/边界：空表上重复调用保持幂等；已有 caller 保存的 codec 引用不失效，
  //   但后续 registry lookup 必须重新登记后才能成功。
  virtual function void clear();
    codecs.delete();
  endfunction

  // 功能：list_keys 导出当前全部 canonical key，并按字符串升序形成稳定视图。
  // 输入/输出及副作用：keys 为输出队列；入口先删除 caller 原内容，再复制关联数组
  //   索引并在多项时排序，不暴露或修改 codec 引用。
  // 失败/边界：空 registry 返回空队列；函数没有 status 输出或分配恢复路径，
  //   caller 不得从空结果推断 registry 生命周期已结束。
  function void list_keys(output string keys[$]);
    keys.delete();
    foreach (codecs[canonical])
      keys.push_back(canonical);
    if (keys.size() > 1)
      keys.sort();
  endfunction
endclass
