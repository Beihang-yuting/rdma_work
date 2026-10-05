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
  `rdma_object_utils(rdma_codec_registry)

  protected rdma_codec_base codecs[string];

  // 功能：构造空 codec 表的 registry。
  // 输入/输出及副作用：name 传给 UVM 基类。
  // 失败/边界：无；空表上 lookup 返回 RDMA_SC_UNSUPPORTED_OPCODE，不使用默认 codec。
  function new(string name = "rdma_codec_registry");
    super.new(name);
  endfunction

  // 功能：检查 key 分量是否含保留分隔符 `|`。
  // 输入/输出及副作用：component 只读；返回是否发现 8'h7c。
  // 失败/边界：空串返回 0，其合法性由 canonicalize 判定。
  protected function bit contains_delimiter(string component);
    for (int unsigned i = 0; i < component.len(); i++) begin
      if (component.getc(i) == 8'h7c)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：校验 codec key 并生成 hw_version|image_kind|object_type|variant|opcode 唯一索引。
  // 输入/输出及副作用：key 输入，canonical 输出（先清空，opcode 为小写十六进制）；不读 codecs。
  // 失败/边界：hw_version/object_type/variant 为空、含 `|` 或 image_kind 不受支持时返回
  //   RDMA_SC_INVALID_ARGUMENT，canonical 保持为空。
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

  // 功能：以 canonical key 登记 codec 的非拥有引用。
  // 输入/输出及副作用：成功时 codecs 新增一项，返回 RDMA_SC_OK；不 clone。
  // 失败/边界：key 规范化失败或 codec 为 null 返回非成功 status；重复 key 报
  //   RDMA_CODEC_DUPLICATE fatal，fatal 被消费时仍返回 INVALID_STATE，原登记不变。
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
      // 设计说明：负向单测可能用 report catcher 消费 fatal，此处仍须显式返回失败。
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "duplicate codec registration");
    end

    codecs[canonical] = codec;
    return rdma_status::success();
  endfunction

  // 功能：按完整 key 查找 codec；可覆写，便于 adapter/test registry 注入失败。
  // 输入/输出及副作用：codec 输出，先置 null，成功返回非拥有引用与 RDMA_SC_OK。
  // 失败/边界：key 非法或条目缺失时 codec 保持 null 并返回非成功 status；override 须保留
  //   输出初始化，caller 对 null status fail closed。
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

  // 功能：清空全部 key→codec 关联。
  // 输入/输出及副作用：只清空非拥有引用，不销毁 codec。
  // 失败/边界：重复调用幂等；之后须重新登记才能 lookup。
  virtual function void clear();
    codecs.delete();
  endfunction

  // 功能：导出全部 canonical key，按字符串升序。
  // 输入/输出及副作用：keys 输出，先清空 caller 原内容。
  // 失败/边界：空 registry 返回空队列。
  function void list_keys(output string keys[$]);
    keys.delete();
    foreach (codecs[canonical])
      keys.push_back(canonical);
    if (keys.size() > 1)
      keys.sort();
  endfunction
endclass
