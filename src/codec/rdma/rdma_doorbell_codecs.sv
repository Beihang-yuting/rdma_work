// 目录：硬件编解码层 codec/rdma/rdma_doorbell_codecs.sv。
// 职责：实现 rdma_hw_doorbell_codecs 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_doorbell_codecs.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit {
  RDMA_SRQ_DB_PI    = 1'b0,
  RDMA_SRQ_DB_LIMIT = 1'b1
} rdma_hw_srq_doorbell_variant_e;

typedef enum bit {
  RDMA_CQ_DB_RC_UD = 1'b0,
  RDMA_CQ_DB_URC   = 1'b1
} rdma_hw_cq_doorbell_variant_e;

virtual class rdma_hw_doorbell_model_base extends rdma_hw_model;
  rdma_handle target_h;

  // 功能：构造 rdma_hw_doorbell_model_base，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：target_h=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_doorbell_model_base 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_doorbell_model_base");
    super.new(name);
    target_h = null;
  endfunction

  // 功能：在 rdma_hw_doorbell_model_base 中，do_copy 将 rhs 中 rdma_hw_doorbell_model_base 的字段复制到当前对象，建立与源对象隔离的值快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（doorbell model copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_doorbell_model_base rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "doorbell model copy type mismatch")
    target_h = rdma_clone_handle_value(rhs_model.target_h,
                                       "rdma doorbell target");
  endfunction

  // 功能：target_status 校验 expected_kind、label 与当前对象状态的一致性，并显式处理“target handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：expected_kind（输入）、label（输入）；target_status 读取 expected_kind、label 并使用字段 rdma_status、target_h、target_h.kind、target_h.generation；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：target_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_STALE_GENERATION；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status target_status(
    rdma_resource_kind_e expected_kind,
    string label
  );
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {label, " target handle is null"});
    if (target_h.kind != expected_kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {label, " target kind is invalid"});
    if (target_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               {label, " target generation is stale"});
    return rdma_status::success();
  endfunction

  // 功能：width_status 校验 value、width、label 与当前对象状态的一致性，并显式处理“%s exceeds %0d bits”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：value（输入）、width（输入）、label（输入）；width_status 读取 value、width、label 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：width_status 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status width_status(
    longint unsigned value,
    int unsigned width,
    string label
  );
    if (width < 64 && (value >> width) != 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        $sformatf("%s exceeds %0d bits", label, width)
      );
    return rdma_status::success();
  endfunction

  // 功能：target_id_status 校验 expected_id、label 与当前对象状态的一致性，并显式处理“target object ID does not match”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：expected_id（输入）、label（输入）；target_id_status 读取 expected_id、label 并使用字段 rdma_status、target_h.object_id；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：target_id_status 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status target_id_status(
    int unsigned expected_id,
    string label
  );
    if (target_h.object_id != expected_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {label, " target object ID does not match"});
    return rdma_status::success();
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“rdma doorbell target handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、target_h、target_h.generation 并使用字段 rdma_status、target_h、target_h.generation；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_STALE_GENERATION；典型拒绝条件为“rdma doorbell target handle is null”“rdma doorbell target generation is stale”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "rdma doorbell target handle is null");
    if (target_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "rdma doorbell target generation is stale");
    return rdma_status::success();
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取 对象字段：pi 并使用字段 name、pi、polarity；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，按对象字段返回固定值；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  pure virtual function rdma_doorbell_kind_e doorbell_kind();

  // 功能：在 rdma_hw_doorbell_model_base 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 返回具体 doorbell codec 的 profile 名称，不读取 name、pi 或 polarity 运行时字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，按对象字段返回固定值；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  pure virtual function string codec_variant();
endclass

class rdma_hw_cmq_sq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_cmq_sq_doorbell_model)

  int unsigned pi;
  bit polarity;

  // 功能：构造 rdma_hw_cmq_sq_doorbell_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：pi=0；polarity=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_sq_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_sq_doorbell_model");
    super.new(name);
    pi = 0;
    polarity = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_cmq_sq_doorbell_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ doorbell copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cmq_sq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ doorbell copy type mismatch")
    pi = rhs_model.pi;
    polarity = rhs_model.polarity;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CMQ doorbell”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：pi 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_CMQ, "CMQ doorbell");
    if (!status.ok()) return status;
    return width_status(pi, RDMA_CMQ_DB_PI_WIDTH, "CMQ doorbell PI");
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 RDMA_DOORBELL_CMQ_SQ；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_CMQ_SQ;
  endfunction

  // 功能：在 rdma_hw_cmq_sq_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，返回 "cmq_sq"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string codec_variant();
    return "cmq_sq";
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("rdma CMQ doorbell(pi=%0d polarity=%0b)",
                     pi, polarity);
  endfunction
endclass

class rdma_hw_sq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_sq_doorbell_model)

  byte unsigned sqe_header[$];

  // 功能：构造 rdma_hw_sq_doorbell_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_sq_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_sq_doorbell_model");
    super.new(name);
    sqe_header.delete();
  endfunction

  // 功能：将 rhs 中 rdma_hw_sq_doorbell_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（SQ doorbell copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_sq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SQ doorbell copy type mismatch")
    sqe_header = rhs_model.sqe_header;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“SQ doorbell”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “SQ doorbell header is not exactly eight bytes”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_QP, "SQ doorbell");
    if (!status.ok()) return status;
    if (sqe_header.size() != RDMA_DB_BYTES)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQ doorbell header is not exactly eight bytes");
    return rdma_status::success();
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 RDMA_DOORBELL_SQ；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_SQ;
  endfunction

  // 功能：在 rdma_hw_sq_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，返回 "sq"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string codec_variant();
    return "sq";
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return "rdma opaque SQ doorbell header";
  endfunction
endclass

class rdma_hw_rq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_rq_doorbell_model)

  int unsigned qpn;
  int unsigned icos;
  int unsigned pi;
  bit wrap;

  // 功能：构造 rdma_hw_rq_doorbell_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：qpn=0；icos=0；pi=0；wrap=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_rq_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_rq_doorbell_model");
    super.new(name);
    qpn = 0;
    icos = 0;
    pi = 0;
    wrap = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_rq_doorbell_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（RQ doorbell copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_rq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "RQ doorbell copy type mismatch")
    qpn = rhs_model.qpn;
    icos = rhs_model.icos;
    pi = rhs_model.pi;
    wrap = rhs_model.wrap;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“RQ doorbell”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：qpn 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_QP, "RQ doorbell");
    if (!status.ok()) return status;
    status = width_status(qpn, RDMA_NOTIFY_RQ_QPN_WIDTH,
                          "RQ doorbell QPN");
    if (!status.ok()) return status;
    status = width_status(icos, RDMA_NOTIFY_RQ_ICOS_WIDTH,
                          "RQ doorbell ICOS");
    if (!status.ok()) return status;
    status = width_status(pi, RDMA_NOTIFY_RQ_PI_WIDTH,
                          "RQ doorbell PI");
    if (!status.ok()) return status;
    return target_id_status(qpn, "RQ doorbell");
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 RDMA_DOORBELL_RQ；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_RQ;
  endfunction

  // 功能：在 rdma_hw_rq_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，返回 "rq"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string codec_variant();
    return "rq";
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("rdma RQ doorbell(qpn=%0d pi=%0d wrap=%0b)",
                     qpn, pi, wrap);
  endfunction
endclass

class rdma_hw_srq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_srq_doorbell_model)

  rdma_hw_srq_doorbell_variant_e variant;
  int unsigned srqn;
  int unsigned pi;
  bit wrap;
  int unsigned limit;
  int unsigned arm_sn;

  // 功能：构造 rdma_hw_srq_doorbell_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：variant=RDMA_SRQ_DB_PI；srqn=0；pi=0；wrap=1'b0；limit=0；arm_sn=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_srq_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_srq_doorbell_model");
    super.new(name);
    variant = RDMA_SRQ_DB_PI;
    srqn = 0;
    pi = 0;
    wrap = 1'b0;
    limit = 0;
    arm_sn = 0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_srq_doorbell_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（SRQ doorbell copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_srq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SRQ doorbell copy type mismatch")
    variant = rhs_model.variant;
    srqn = rhs_model.srqn;
    pi = rhs_model.pi;
    wrap = rhs_model.wrap;
    limit = rhs_model.limit;
    arm_sn = rhs_model.arm_sn;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“SRQ doorbell”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、srqn、variant 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SRQ doorbell variant is invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_SRQ, "SRQ doorbell");
    if (!status.ok()) return status;
    if (!(variant inside {RDMA_SRQ_DB_PI, RDMA_SRQ_DB_LIMIT}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQ doorbell variant is invalid");
    status = width_status(srqn, RDMA_NOTIFY_SRFQN_WIDTH,
                          "SRQ doorbell SRQN");
    if (!status.ok()) return status;
    if (variant == RDMA_SRQ_DB_PI) begin
      status = width_status(pi, RDMA_NOTIFY_SRFQ_PI_WIDTH,
                            "SRQ doorbell PI");
      if (!status.ok()) return status;
    end
    else begin
      status = width_status(limit, RDMA_NOTIFY_SRQ_LIMIT_WIDTH,
                            "SRQ doorbell limit");
      if (!status.ok()) return status;
      status = width_status(arm_sn, RDMA_NOTIFY_SRQ_ARM_SN_WIDTH,
                            "SRQ doorbell arm sequence");
      if (!status.ok()) return status;
    end
    return target_id_status(srqn, "SRQ doorbell");
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 RDMA_DOORBELL_SRQ；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_SRQ;
  endfunction

  // 功能：在 rdma_hw_srq_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取 对象字段：variant 并使用字段 variant；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，返回 (variant == RDMA_SRQ_DB_PI) ? "srq_pi" : "srq_limit"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string codec_variant();
    return (variant == RDMA_SRQ_DB_PI) ? "srq_pi" : "srq_limit";
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("rdma SRQ doorbell(variant=%s srqn=%0d)",
                     codec_variant(), srqn);
  endfunction
endclass

class rdma_hw_cq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_cq_doorbell_model)

  rdma_hw_cq_doorbell_variant_e variant;
  int unsigned cqn;
  int unsigned host_id;
  int unsigned ci;
  bit wrap;
  int unsigned sq_ci;
  bit sq_wrap;
  int unsigned rq_ci;
  bit rq_wrap;
  bit ci_invalid;
  bit arm_invalid;
  bit arm;
  int unsigned arm_state;
  int unsigned arm_sn;

  // 功能：构造 rdma_hw_cq_doorbell_model，建立同时覆盖 RC/UD 与 URC 线布局的
  //       独立 doorbell 快照；invalid 标志也在模型中保留，避免丢失驱动字段。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造只建立本地初始状态，不接管 CQ、Host-memory、PCIe 或 manager；
  //       未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cq_doorbell_model");
    super.new(name);
    variant = RDMA_CQ_DB_RC_UD;
    cqn = 0;
    host_id = 0;
    ci = 0;
    wrap = 1'b0;
    sq_ci = 0;
    sq_wrap = 1'b0;
    rq_ci = 0;
    rq_wrap = 1'b0;
    ci_invalid = 1'b0;
    arm_invalid = 1'b0;
    arm = 1'b0;
    arm_state = 0;
    arm_sn = 0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_cq_doorbell_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CQ doorbell copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQ doorbell copy type mismatch")
    variant = rhs_model.variant;
    cqn = rhs_model.cqn;
    host_id = rhs_model.host_id;
    ci = rhs_model.ci;
    wrap = rhs_model.wrap;
    sq_ci = rhs_model.sq_ci;
    sq_wrap = rhs_model.sq_wrap;
    rq_ci = rhs_model.rq_ci;
    rq_wrap = rhs_model.rq_wrap;
    ci_invalid = rhs_model.ci_invalid;
    arm_invalid = rhs_model.arm_invalid;
    arm = rhs_model.arm;
    arm_state = rhs_model.arm_state;
    arm_sn = rhs_model.arm_sn;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CQ doorbell”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、cqn、variant 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQ doorbell variant is invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_CQ, "CQ doorbell");
    if (!status.ok()) return status;
    if (!(variant inside {RDMA_CQ_DB_RC_UD, RDMA_CQ_DB_URC}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ doorbell variant is invalid");
    status = width_status(cqn, RDMA_NOTIFY_CQ_CQN_WIDTH,
                          "CQ doorbell CQN");
    if (!status.ok()) return status;
    status = width_status(host_id, RDMA_NOTIFY_CQ_HOST_ID_WIDTH,
                          "CQ doorbell host ID");
    if (!status.ok()) return status;
    status = width_status(arm_state, RDMA_NOTIFY_CQ_ARM_ST_WIDTH,
                          "CQ doorbell arm state");
    if (!status.ok()) return status;
    status = width_status(arm_sn, RDMA_NOTIFY_CQ_ARM_SN_WIDTH,
                          "CQ doorbell arm sequence");
    if (!status.ok()) return status;
    if (variant == RDMA_CQ_DB_RC_UD) begin
      status = width_status(ci, RDMA_NOTIFY_CQ_CI_WIDTH,
                            "CQ doorbell CI");
      if (!status.ok()) return status;
    end
    else begin
      status = width_status(sq_ci, RDMA_NOTIFY_CQ_URC_SQ_CI_WIDTH,
                            "CQ doorbell SQ CI");
      if (!status.ok()) return status;
      status = width_status(rq_ci, RDMA_NOTIFY_CQ_URC_RQ_CI_WIDTH,
                            "CQ doorbell RQ CI");
      if (!status.ok()) return status;
    end

    return target_id_status(cqn, "CQ doorbell");
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 RDMA_DOORBELL_CQ；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_CQ;
  endfunction

  // 功能：在 rdma_hw_cq_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取 对象字段：variant 并使用字段 variant；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，返回 (variant == RDMA_CQ_DB_RC_UD) ? "cq_rc_ud" : "cq_urc"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string codec_variant();
    return (variant == RDMA_CQ_DB_RC_UD) ? "cq_rc_ud" : "cq_urc";
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("rdma CQ doorbell(variant=%s cqn=%0d)",
                     codec_variant(), cqn);
  endfunction
endclass

class rdma_hw_ceq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_ceq_doorbell_model)

  int unsigned ceqn;
  int unsigned ci;
  bit wrap;

  // 功能：构造 rdma_hw_ceq_doorbell_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：ceqn=0；ci=0；wrap=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_ceq_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_ceq_doorbell_model");
    super.new(name);
    ceqn = 0;
    ci = 0;
    wrap = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_ceq_doorbell_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CEQ doorbell copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_ceq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQ doorbell copy type mismatch")
    ceqn = rhs_model.ceqn;
    ci = rhs_model.ci;
    wrap = rhs_model.wrap;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CEQ doorbell”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：ceqn 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_CEQ, "CEQ doorbell");
    if (!status.ok()) return status;
    status = width_status(ceqn, RDMA_NOTIFY_CEQ_CEQN_WIDTH,
                          "CEQ doorbell CEQN");
    if (!status.ok()) return status;
    status = width_status(ci, RDMA_NOTIFY_CEQ_CI_WIDTH,
                          "CEQ doorbell CI");
    if (!status.ok()) return status;
    return target_id_status(ceqn, "CEQ doorbell");
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 RDMA_DOORBELL_CEQ；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_CEQ;
  endfunction

  // 功能：在 rdma_hw_ceq_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，返回 "ceq"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string codec_variant();
    return "ceq";
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("rdma CEQ doorbell(ceqn=%0d ci=%0d wrap=%0b)",
                     ceqn, ci, wrap);
  endfunction
endclass

class rdma_hw_aeq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_aeq_doorbell_model)

  int unsigned aeqn;
  int unsigned ci;
  bit wrap;

  // 功能：构造 rdma_hw_aeq_doorbell_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：aeqn=0；ci=0；wrap=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_aeq_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_aeq_doorbell_model");
    super.new(name);
    aeqn = 0;
    ci = 0;
    wrap = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_aeq_doorbell_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（AEQ doorbell copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_aeq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQ doorbell copy type mismatch")
    aeqn = rhs_model.aeqn;
    ci = rhs_model.ci;
    wrap = rhs_model.wrap;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“AEQ doorbell”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：aeqn 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_AEQ, "AEQ doorbell");
    if (!status.ok()) return status;
    status = width_status(aeqn, RDMA_NOTIFY_AEQ_AEQN_WIDTH,
                          "AEQ doorbell AEQN");
    if (!status.ok()) return status;
    status = width_status(ci, RDMA_NOTIFY_AEQ_CI_WIDTH,
                          "AEQ doorbell CI");
    if (!status.ok()) return status;
    return target_id_status(aeqn, "AEQ doorbell");
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 RDMA_DOORBELL_AEQ；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_AEQ;
  endfunction

  // 功能：在 rdma_hw_aeq_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 是只读访问器，返回 "aeq"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string codec_variant();
    return "aeq";
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("rdma AEQ doorbell(aeqn=%0d ci=%0d wrap=%0b)",
                     aeqn, ci, wrap);
  endfunction
endclass

class rdma_hw_qp_control_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `uvm_object_utils(rdma_hw_qp_control_doorbell_model)

  rdma_doorbell_kind_e kind;
  int unsigned qpn;
  int unsigned dst_port;
  int unsigned qp_sn;
  int unsigned icos;

  // 功能：构造 rdma_hw_qp_control_doorbell_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：kind=RDMA_DOORBELL_QP_FLUSH；qpn=0；dst_port=0；qp_sn=0；icos=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_qp_control_doorbell_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_qp_control_doorbell_model");
    super.new(name);
    kind = RDMA_DOORBELL_QP_FLUSH;
    qpn = 0;
    dst_port = 0;
    qp_sn = 0;
    icos = 0;
  endfunction

  // 功能：将 rhs 中 rdma_hw_qp_control_doorbell_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（QP-control doorbell copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_qp_control_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "QP-control doorbell copy type mismatch")
    kind = rhs_model.kind;
    qpn = rhs_model.qpn;
    dst_port = rhs_model.dst_port;
    qp_sn = rhs_model.qp_sn;
    icos = rhs_model.icos;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“QP-control doorbell”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、kind、dst_port、qp_sn、icos 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “QP-control doorbell kind is invalid”；“TX-flush doorbell requires fixed destination, sequence, and ICOS”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_QP, "QP-control doorbell");
    if (!status.ok()) return status;
    if (!(kind inside {RDMA_DOORBELL_RTS2SQD, RDMA_DOORBELL_SQD2RTS,
                       RDMA_DOORBELL_QP_FLUSH,
                       RDMA_DOORBELL_TX_FLUSH}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP-control doorbell kind is invalid");
    status = width_status(qpn, RDMA_NOTIFY_QP_QPN_WIDTH,
                          "QP-control doorbell QPN");
    if (!status.ok()) return status;
    status = width_status(dst_port, RDMA_NOTIFY_QP_DST_PORT_WIDTH,
                          "QP-control doorbell destination port");
    if (!status.ok()) return status;
    status = width_status(qp_sn, RDMA_NOTIFY_QP_SN_WIDTH,
                          "QP-control doorbell QP sequence");
    if (!status.ok()) return status;
    status = width_status(icos, RDMA_NOTIFY_QP_ICOS_WIDTH,
                          "QP-control doorbell ICOS");
    if (!status.ok()) return status;
    status = target_id_status(qpn, "QP-control doorbell");
    if (!status.ok()) return status;
    if (kind == RDMA_DOORBELL_TX_FLUSH &&
        (dst_port != RDMA_TX_FLUSH_DST_PORT || qp_sn != 0 || icos != 0))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "TX-flush doorbell requires fixed destination, sequence, and ICOS"
      );
    return rdma_status::success();
  endfunction

  // 功能：doorbell_kind 使用 当前对象字段 计算并返回 rdma_doorbell_kind_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：doorbell_kind 是只读访问器，返回 kind；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return kind;
  endfunction

  // 功能：在 rdma_hw_qp_control_doorbell_model 中，codec_variant 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；codec_variant 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：codec_variant 按 case(输入字段) 的固定映射计算 string（RDMA_DOORBELL_RTS2SQD→"rts2sqd"；RDMA_DOORBELL_SQD2RTS→"sqd2rts"；RDMA_DOORBELL_QP_FLUSH→"qp_flush"；RDMA_DOORBELL_TX_FLUSH→"tx_flush"；default→"invalid"）；未列出的输入走 default，不修改运行时账本。
  virtual function string codec_variant();
    case (kind)
      RDMA_DOORBELL_RTS2SQD:  return "rts2sqd";
      RDMA_DOORBELL_SQD2RTS:  return "sqd2rts";
      RDMA_DOORBELL_QP_FLUSH: return "qp_flush";
      RDMA_DOORBELL_TX_FLUSH: return "tx_flush";
      default:                return "invalid";
    endcase
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("rdma QP-control doorbell(kind=%s qpn=%0d)",
                     kind.name(), qpn);
  endfunction
endclass

class rdma_hw_doorbell_codec extends rdma_codec_base;
  `uvm_object_utils(rdma_hw_doorbell_codec)

  protected string variant_name;

  // 功能：构造 rdma_hw_doorbell_codec，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：this.variant_name=variant_name。
  // 输入/输出及副作用：name、variant_name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_doorbell_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_doorbell_codec",
               string variant_name = "rq");
    super.new(name);
    this.variant_name = variant_name;
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，codec_error 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；codec_error 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：codec_error 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：判断 supported_variant 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；supported_variant 读取 对象字段：variant_name 并使用字段 variant_name；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：supported_variant 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit supported_variant();
    return variant_name inside {
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，expected_relative_offset 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_relative_offset 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_relative_offset 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected function bit [63:0] expected_relative_offset();
    case (variant_name)
      "cmq_sq":   return RDMA_DB_CMQ_OFFSET;
      "sq":       return RDMA_DB_SQ_OFFSET;
      "rq":       return RDMA_DB_RQ_OFFSET;
      "srq_pi",
      "srq_limit":return RDMA_DB_SRFQ_OFFSET;
      "cq_rc_ud",
      "cq_urc":   return RDMA_DB_CQ_OFFSET;
      "ceq":      return RDMA_DB_CEQ_OFFSET;
      "aeq":      return RDMA_DB_AEQ_OFFSET;
      "rts2sqd":  return RDMA_DB_RTS2SQD_OFFSET;
      "sqd2rts":  return RDMA_DB_SQD2RTS_OFFSET;
      "qp_flush": return RDMA_DB_QP_FLUSH_OFFSET;
      "tx_flush": return RDMA_DB_TX_FLUSH_OFFSET;
      default:     return '1;
    endcase
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，selected_mask 根据 opcode、对象类型或 profile 选择允许位掩码/有效 payload 范围，供保留位检查使用。
  // 输入/输出及副作用：无显式参数；selected_mask 读取 对象字段：hffff_ffff_ffff_ffff 并使用字段 ；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：selected_mask 是只读访问器，返回 64'h0000_003f_0000_0000；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected function bit [63:0] selected_mask();
    case (variant_name)
      "cmq_sq":   return 64'h0000_003f_0000_0000;
      "sq":       return 64'hffff_ffff_ffff_ffff;
      "rq":       return 64'h0000_ffff_00ff_ffff;
      "srq_pi":   return 64'h4000_ffff_0000_ffff;
      "srq_limit":return 64'h8000_0000_ffff_ffff;
      // cq.h:108-113 reserve the top two bits for explicit invalid markers;
      // they are authored by the driver even when the corresponding cursor is
      // not valid, so both CQ variants must include them in the selected mask.
      "cq_rc_ud": return 64'hff00_ffff_ffff_ffff;
      "cq_urc":   return 64'hffff_ffff_ffff_ffff;
      "ceq":      return 64'h0007_ffff_003f_ffff;
      "aeq":      return 64'h0007_ffff_0000_0fff;
      "rts2sqd",
      "sqd2rts",
      "qp_flush",
      "tx_flush": return 64'h000f_fff0_00ff_ffff;
      default:     return '0;
    endcase
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，expected_target_kind 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_target_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_resource_kind_e，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_target_kind 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected function rdma_resource_kind_e expected_target_kind();
    case (variant_name)
      "cmq_sq": return RDMA_RESOURCE_CMQ;
      "srq_pi", "srq_limit": return RDMA_RESOURCE_SRQ;
      "cq_rc_ud", "cq_urc": return RDMA_RESOURCE_CQ;
      "ceq": return RDMA_RESOURCE_CEQ;
      "aeq": return RDMA_RESOURCE_AEQ;
      default: return RDMA_RESOURCE_QP;
    endcase
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，expected_doorbell_kind 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_doorbell_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_doorbell_kind_e，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_doorbell_kind 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected function rdma_doorbell_kind_e expected_doorbell_kind();
    case (variant_name)
      "cmq_sq": return RDMA_DOORBELL_CMQ_SQ;
      "sq": return RDMA_DOORBELL_SQ;
      "rq": return RDMA_DOORBELL_RQ;
      "srq_pi", "srq_limit": return RDMA_DOORBELL_SRQ;
      "cq_rc_ud", "cq_urc": return RDMA_DOORBELL_CQ;
      "ceq": return RDMA_DOORBELL_CEQ;
      "aeq": return RDMA_DOORBELL_AEQ;
      "rts2sqd": return RDMA_DOORBELL_RTS2SQD;
      "sqd2rts": return RDMA_DOORBELL_SQD2RTS;
      "qp_flush": return RDMA_DOORBELL_QP_FLUSH;
      default: return RDMA_DOORBELL_TX_FLUSH;
    endcase
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，expected_db_type 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_db_type 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_db_type 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  protected function int unsigned expected_db_type();
    case (variant_name)
      "rts2sqd":  return RDMA_DB_TYPE_RTS2SQD;
      "sqd2rts":  return RDMA_DB_TYPE_SQD2RTS;
      "qp_flush": return RDMA_DB_TYPE_QP_FLUSH;
      "tx_flush": return RDMA_DB_TYPE_TX_FLUSH;
      default:     return 0;
    endcase
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，put 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：builder（输入）、word_byte_offset（输入）、lsb（输入）、width（输入）、value（输入）；put 读取 builder、word_byte_offset、lsb、width、value 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：put 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  protected function rdma_status put(
    rdma_hw_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    bit [63:0] value
  );
    rdma_status status;
    status = builder.put_field(word_byte_offset, lsb, width, value);
    if (!status.ok())
      return codec_error({"doorbell field authorship failed: ",
                          status.message});
    return status;
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，get 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：builder（输入）、word_byte_offset（输入）、lsb（输入）、width（输入）、value（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output
  //   为 detached 快照，读取不取得外部资源所有权。
  // 失败/边界：get 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status get(
    rdma_hw_qword_builder builder,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    output bit [63:0] value
  );
    rdma_status status;
    bit [63:0] extracted;
    extracted = '0;
    status = builder.get_field(word_byte_offset, lsb, width, extracted);
    if (!status.ok())
      return codec_error({"doorbell field extraction failed: ",
                          status.message});
    value = extracted;
    return status;
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，decoded_target 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：kind（输入）、object_id（输入）、generation（输入）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decoded_target 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_handle decoded_target(
    rdma_resource_kind_e kind,
    int unsigned object_id,
    int unsigned generation
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create("decoded_doorbell_target");
    handle.kind = kind;
    handle.function_uid = 0;
    handle.object_id = object_id;
    handle.generation = generation;
    return handle;
  endfunction

  // 功能：validate_model 校验 model 与当前对象状态的一致性，并显式处理“rdma doorbell codec variant is unsupported”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：model（输入）；validate_model 读取 model 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_model(rdma_hw_model model);
    rdma_hw_doorbell_model_base doorbell;
    rdma_hw_cmq_sq_doorbell_model cmq;
    rdma_hw_sq_doorbell_model sq;
    rdma_hw_rq_doorbell_model rq;
    rdma_hw_srq_doorbell_model srq;
    rdma_hw_cq_doorbell_model cq;
    rdma_hw_ceq_doorbell_model ceq;
    rdma_hw_aeq_doorbell_model aeq;
    rdma_hw_qp_control_doorbell_model qp;
    rdma_status status;

    if (!supported_variant())
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "rdma doorbell codec variant is unsupported");
    if (!$cast(doorbell, model))
      return invalid_argument("rdma doorbell codec requires typed model");
    case (variant_name)
      "cmq_sq": if (!$cast(cmq, model))
        return invalid_argument("cmq_sq codec requires CMQ doorbell model");
      "sq": if (!$cast(sq, model))
        return invalid_argument("sq codec requires SQ doorbell model");
      "rq": if (!$cast(rq, model))
        return invalid_argument("rq codec requires RQ doorbell model");
      "srq_pi", "srq_limit": if (!$cast(srq, model))
        return invalid_argument("SRQ codec requires SRQ doorbell model");
      "cq_rc_ud", "cq_urc": if (!$cast(cq, model))
        return invalid_argument("CQ codec requires CQ doorbell model");
      "ceq": if (!$cast(ceq, model))
        return invalid_argument("ceq codec requires CEQ doorbell model");
      "aeq": if (!$cast(aeq, model))
        return invalid_argument("aeq codec requires AEQ doorbell model");
      default: if (!$cast(qp, model))
        return invalid_argument("QP-control codec requires QP-control model");
    endcase
    if (doorbell.codec_variant() != variant_name ||
        doorbell.doorbell_kind() != expected_doorbell_kind())
      return invalid_argument("doorbell model variant does not match codec");
    status = doorbell.validate();
    if (!status.ok()) return status;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，encode_fields 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、builder（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_fields 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_fields(
    rdma_hw_model model,
    rdma_hw_qword_builder builder
  );
    rdma_hw_cmq_sq_doorbell_model cmq;
    rdma_hw_sq_doorbell_model sq;
    rdma_hw_rq_doorbell_model rq;
    rdma_hw_srq_doorbell_model srq;
    rdma_hw_cq_doorbell_model cq;
    rdma_hw_ceq_doorbell_model ceq;
    rdma_hw_aeq_doorbell_model aeq;
    rdma_hw_qp_control_doorbell_model qp;
    byte unsigned header[];
    rdma_status status;

`define DB_PUT(STEM, VALUE) \
    status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, VALUE); \
    if (!status.ok()) return status;
    case (variant_name)
      "cmq_sq": begin
        void'($cast(cmq, model));
        `DB_PUT(RDMA_CMQ_DB_PI, cmq.pi)
        `DB_PUT(RDMA_CMQ_DB_POLARITY, cmq.polarity)
      end
      "sq": begin
        void'($cast(sq, model));
        header = new[RDMA_DB_BYTES];
        foreach (header[i]) header[i] = sq.sqe_header[i];
        status = builder.put_memcpy(0, header);
        if (!status.ok())
          return codec_error({"SQ header authorship failed: ", status.message});
      end
      "rq": begin
        void'($cast(rq, model));
        `DB_PUT(RDMA_NOTIFY_RQ_PI_WRAP, rq.wrap)
        `DB_PUT(RDMA_NOTIFY_RQ_PI, rq.pi)
        `DB_PUT(RDMA_NOTIFY_RQ_ICOS, rq.icos)
        `DB_PUT(RDMA_NOTIFY_RQ_QPN, rq.qpn)
      end
      "srq_pi": begin
        void'($cast(srq, model));
        `DB_PUT(RDMA_NOTIFY_SRQ_LIMIT_INVALID,
                RDMA_NOTIFY_SRQ_LIMIT_INVALID_VALUE)
        `DB_PUT(RDMA_NOTIFY_SRFQ_WRAP, srq.wrap)
        `DB_PUT(RDMA_NOTIFY_SRFQ_PI, srq.pi)
        `DB_PUT(RDMA_NOTIFY_SRFQN, srq.srqn)
      end
      "srq_limit": begin
        void'($cast(srq, model));
        `DB_PUT(RDMA_NOTIFY_SRQ_PI_INVALID,
                RDMA_NOTIFY_SRQ_PI_INVALID_VALUE)
        `DB_PUT(RDMA_NOTIFY_SRQ_LIMIT, srq.limit)
        `DB_PUT(RDMA_NOTIFY_SRQ_ARM_SN, srq.arm_sn)
        `DB_PUT(RDMA_NOTIFY_SRFQN, srq.srqn)
      end
      "cq_rc_ud", "cq_urc": begin
        void'($cast(cq, model));
        `DB_PUT(RDMA_NOTIFY_CQ_CI_INVALID, cq.ci_invalid)
        `DB_PUT(RDMA_NOTIFY_CQ_ARM_INVALID, cq.arm_invalid)
        `DB_PUT(RDMA_NOTIFY_CQ_ARM, cq.arm)
        `DB_PUT(RDMA_NOTIFY_CQ_URC,
                (variant_name == "cq_urc"))
        `DB_PUT(RDMA_NOTIFY_CQ_ARM_ST, cq.arm_state)
        `DB_PUT(RDMA_NOTIFY_CQ_ARM_SN, cq.arm_sn)
        if (variant_name == "cq_rc_ud") begin
          `DB_PUT(RDMA_NOTIFY_CQ_CI_WRAP, cq.wrap)
          `DB_PUT(RDMA_NOTIFY_CQ_CI, cq.ci)
        end
        else begin
          `DB_PUT(RDMA_NOTIFY_CQ_URC_SQ_WRAP, cq.sq_wrap)
          `DB_PUT(RDMA_NOTIFY_CQ_URC_SQ_CI, cq.sq_ci)
          `DB_PUT(RDMA_NOTIFY_CQ_URC_RQ_WRAP, cq.rq_wrap)
          `DB_PUT(RDMA_NOTIFY_CQ_URC_RQ_CI, cq.rq_ci)
        end
        `DB_PUT(RDMA_NOTIFY_CQ_HOST_ID, cq.host_id)
        `DB_PUT(RDMA_NOTIFY_CQ_CQN, cq.cqn)
      end
      "ceq": begin
        void'($cast(ceq, model));
        `DB_PUT(RDMA_NOTIFY_CEQ_CI_WRAP, ceq.wrap)
        `DB_PUT(RDMA_NOTIFY_CEQ_CI, ceq.ci)
        `DB_PUT(RDMA_NOTIFY_CEQ_CEQN, ceq.ceqn)
      end
      "aeq": begin
        void'($cast(aeq, model));
        `DB_PUT(RDMA_NOTIFY_AEQ_CI_WRAP, aeq.wrap)
        `DB_PUT(RDMA_NOTIFY_AEQ_CI, aeq.ci)
        `DB_PUT(RDMA_NOTIFY_AEQ_AEQN, aeq.aeqn)
      end
      default: begin
        void'($cast(qp, model));
        `DB_PUT(RDMA_NOTIFY_QP_DST_PORT, qp.dst_port)
        `DB_PUT(RDMA_NOTIFY_QP_SN, qp.qp_sn)
        `DB_PUT(RDMA_NOTIFY_QP_DB_TYPE, expected_db_type())
        `DB_PUT(RDMA_NOTIFY_QP_ICOS, qp.icos)
        `DB_PUT(RDMA_NOTIFY_QP_QPN, qp.qpn)
      end
    endcase
`undef DB_PUT
    return rdma_status::success();
  endfunction

  // 功能：validate_encode_mask 校验 builder 与当前对象状态的一致性，并显式处理“doorbell field authorship differs from selected mask”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：builder（输入）；validate_encode_mask 读取 builder 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate_encode_mask 返回 函数体规定的失败状态；具体拒绝条件包括 “doorbell field authorship differs from selected mask”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status validate_encode_mask(
    rdma_hw_qword_builder builder
  );
    bit [63:0] occupancy[];
    builder.get_occupancy(occupancy);
    if (occupancy.size() != 1 || occupancy[0] != selected_mask())
      return codec_error("doorbell field authorship differs from selected mask");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_hw_doorbell_model_base doorbell;
    rdma_hw_qword_builder builder;
    rdma_hw_image candidate;
    byte unsigned payload[];
    rdma_status status;

    image = null;
    status = validate_model(model);
    if (!status.ok()) return status;
    if (!$cast(doorbell, model))
      return invalid_argument("typed doorbell model cast failed");
    builder = new("doorbell_encode_builder");
    status = builder.reset(RDMA_DB_BYTES);
    if (!status.ok()) return codec_error(status.message);
    status = encode_fields(model, builder);
    if (!status.ok()) return status;
    status = validate_encode_mask(builder);
    if (!status.ok()) return status;
    payload = new[0];
    status = builder.serialize(payload);
    if (!status.ok()) return codec_error(status.message);

    candidate = rdma_hw_image::type_id::create("rdma_doorbell_image");
    foreach (payload[i]) candidate.bytes.push_back(payload[i]);
    candidate.length = RDMA_DB_BYTES;
    candidate.alignment = RDMA_DB_BYTES;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = RDMA_IMAGE_DOORBELL;
    candidate.hardware_version = RDMA_HW_VERSION;
    candidate.function_generation = doorbell.target_h.generation;
    candidate.write_target_kind = RDMA_HW_TARGET_BAR;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target.value = expected_relative_offset();
    image = candidate;
    return rdma_status::success();
  endfunction

  // 功能：validate_image 校验 image 与当前对象状态的一致性，并显式处理“rdma doorbell codec variant is unsupported”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image（输入）；validate_image 读取 image 并使用字段 payload、builder、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  virtual function rdma_status validate_image(rdma_hw_image image);
    rdma_hw_qword_builder builder;
    byte unsigned payload[];
    bit [63:0] words[];
    rdma_status status;

    if (!supported_variant())
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "rdma doorbell codec variant is unsupported");
    if (image == null)
      return codec_error("doorbell image is null");
    if (image.length != RDMA_DB_BYTES ||
        image.bytes.size() != RDMA_DB_BYTES)
      return codec_error("doorbell image length is not eight bytes");
    if (image.function_generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "doorbell image generation is stale");
    if (image.alignment != RDMA_DB_BYTES ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_DOORBELL ||
        image.hardware_version != RDMA_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_BAR ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != expected_relative_offset())
      return codec_error("doorbell image metadata is invalid");
    payload = new[RDMA_DB_BYTES];
    foreach (payload[i]) payload[i] = image.bytes[i];
    builder = new("doorbell_validate_builder");
    status = builder.deserialize(payload);
    if (!status.ok()) return codec_error(status.message);
    builder.get_words(words);
    if (words.size() != 1 || (words[0] & ~selected_mask()) != 0)
      return codec_error("doorbell image contains a selected-variant reserved bit");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中，decode 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：image（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );
    rdma_hw_qword_builder builder;
    rdma_hw_doorbell_model_base candidate;
    rdma_hw_cmq_sq_doorbell_model cmq;
    rdma_hw_sq_doorbell_model sq;
    rdma_hw_rq_doorbell_model rq;
    rdma_hw_srq_doorbell_model srq;
    rdma_hw_cq_doorbell_model cq;
    rdma_hw_ceq_doorbell_model ceq;
    rdma_hw_aeq_doorbell_model aeq;
    rdma_hw_qp_control_doorbell_model qp;
    byte unsigned payload[];
    bit [63:0] value;
    rdma_status status;

    model = null;
    status = validate_image(image);
    if (!status.ok()) return status;
    payload = new[RDMA_DB_BYTES];
    foreach (payload[i]) payload[i] = image.bytes[i];
    builder = new("doorbell_decode_builder");
    status = builder.deserialize(payload);
    if (!status.ok()) return codec_error(status.message);

`define DB_GET(STEM, DEST) \
    status = get(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                 STEM``_WIDTH, value); \
    if (!status.ok()) return status; \
    DEST = value;
    case (variant_name)
      "cmq_sq": begin
        cmq = rdma_hw_cmq_sq_doorbell_model::type_id::create(
            "decoded_cmq_doorbell");
        `DB_GET(RDMA_CMQ_DB_PI, cmq.pi)
        `DB_GET(RDMA_CMQ_DB_POLARITY, cmq.polarity)
        cmq.target_h = decoded_target(RDMA_RESOURCE_CMQ, 0,
                                      image.function_generation);
        candidate = cmq;
      end
      "sq": begin
        sq = rdma_hw_sq_doorbell_model::type_id::create(
            "decoded_sq_doorbell");
        foreach (image.bytes[i]) sq.sqe_header.push_back(image.bytes[i]);
        sq.target_h = decoded_target(RDMA_RESOURCE_QP, 0,
                                     image.function_generation);
        candidate = sq;
      end
      "rq": begin
        rq = rdma_hw_rq_doorbell_model::type_id::create(
            "decoded_rq_doorbell");
        `DB_GET(RDMA_NOTIFY_RQ_PI_WRAP, rq.wrap)
        `DB_GET(RDMA_NOTIFY_RQ_PI, rq.pi)
        `DB_GET(RDMA_NOTIFY_RQ_ICOS, rq.icos)
        `DB_GET(RDMA_NOTIFY_RQ_QPN, rq.qpn)
        rq.target_h = decoded_target(RDMA_RESOURCE_QP, rq.qpn,
                                     image.function_generation);
        candidate = rq;
      end
      "srq_pi", "srq_limit": begin
        srq = rdma_hw_srq_doorbell_model::type_id::create(
            "decoded_srq_doorbell");
        if (variant_name == "srq_pi") begin
          srq.variant = RDMA_SRQ_DB_PI;
          `DB_GET(RDMA_NOTIFY_SRQ_LIMIT_INVALID, value)
          if (value != RDMA_NOTIFY_SRQ_LIMIT_INVALID_VALUE)
            return codec_error("SRQ PI doorbell limit-invalid bit is not set");
          `DB_GET(RDMA_NOTIFY_SRFQ_WRAP, srq.wrap)
          `DB_GET(RDMA_NOTIFY_SRFQ_PI, srq.pi)
        end
        else begin
          srq.variant = RDMA_SRQ_DB_LIMIT;
          `DB_GET(RDMA_NOTIFY_SRQ_PI_INVALID, value)
          if (value != RDMA_NOTIFY_SRQ_PI_INVALID_VALUE)
            return codec_error("SRQ limit doorbell PI-invalid bit is not set");
          `DB_GET(RDMA_NOTIFY_SRQ_LIMIT, srq.limit)
          `DB_GET(RDMA_NOTIFY_SRQ_ARM_SN, srq.arm_sn)
        end
        `DB_GET(RDMA_NOTIFY_SRFQN, srq.srqn)
        srq.target_h = decoded_target(RDMA_RESOURCE_SRQ, srq.srqn,
                                      image.function_generation);
        candidate = srq;
      end
      "cq_rc_ud", "cq_urc": begin
        cq = rdma_hw_cq_doorbell_model::type_id::create(
            "decoded_cq_doorbell");
        cq.variant = (variant_name == "cq_rc_ud") ?
                     RDMA_CQ_DB_RC_UD : RDMA_CQ_DB_URC;
        `DB_GET(RDMA_NOTIFY_CQ_CI_INVALID, cq.ci_invalid)
        `DB_GET(RDMA_NOTIFY_CQ_ARM_INVALID, cq.arm_invalid)
        `DB_GET(RDMA_NOTIFY_CQ_ARM, cq.arm)
        `DB_GET(RDMA_NOTIFY_CQ_URC, value)
        if (value != (variant_name == "cq_urc"))
          return codec_error("CQ doorbell URC selector mismatches variant");
        `DB_GET(RDMA_NOTIFY_CQ_ARM_ST, cq.arm_state)
        `DB_GET(RDMA_NOTIFY_CQ_ARM_SN, cq.arm_sn)
        if (variant_name == "cq_rc_ud") begin
          `DB_GET(RDMA_NOTIFY_CQ_CI_WRAP, cq.wrap)
          `DB_GET(RDMA_NOTIFY_CQ_CI, cq.ci)
        end
        else begin
          `DB_GET(RDMA_NOTIFY_CQ_URC_SQ_WRAP, cq.sq_wrap)
          `DB_GET(RDMA_NOTIFY_CQ_URC_SQ_CI, cq.sq_ci)
          `DB_GET(RDMA_NOTIFY_CQ_URC_RQ_WRAP, cq.rq_wrap)
          `DB_GET(RDMA_NOTIFY_CQ_URC_RQ_CI, cq.rq_ci)
        end
        `DB_GET(RDMA_NOTIFY_CQ_HOST_ID, cq.host_id)
        `DB_GET(RDMA_NOTIFY_CQ_CQN, cq.cqn)
        cq.target_h = decoded_target(RDMA_RESOURCE_CQ, cq.cqn,
                                     image.function_generation);
        candidate = cq;
      end
      "ceq": begin
        ceq = rdma_hw_ceq_doorbell_model::type_id::create(
            "decoded_ceq_doorbell");
        `DB_GET(RDMA_NOTIFY_CEQ_CI_WRAP, ceq.wrap)
        `DB_GET(RDMA_NOTIFY_CEQ_CI, ceq.ci)
        `DB_GET(RDMA_NOTIFY_CEQ_CEQN, ceq.ceqn)
        ceq.target_h = decoded_target(RDMA_RESOURCE_CEQ, ceq.ceqn,
                                      image.function_generation);
        candidate = ceq;
      end
      "aeq": begin
        aeq = rdma_hw_aeq_doorbell_model::type_id::create(
            "decoded_aeq_doorbell");
        `DB_GET(RDMA_NOTIFY_AEQ_CI_WRAP, aeq.wrap)
        `DB_GET(RDMA_NOTIFY_AEQ_CI, aeq.ci)
        `DB_GET(RDMA_NOTIFY_AEQ_AEQN, aeq.aeqn)
        aeq.target_h = decoded_target(RDMA_RESOURCE_AEQ, aeq.aeqn,
                                      image.function_generation);
        candidate = aeq;
      end
      default: begin
        qp = rdma_hw_qp_control_doorbell_model::type_id::create(
            "decoded_qp_control_doorbell");
        qp.kind = expected_doorbell_kind();
        `DB_GET(RDMA_NOTIFY_QP_DST_PORT, qp.dst_port)
        `DB_GET(RDMA_NOTIFY_QP_SN, qp.qp_sn)
        `DB_GET(RDMA_NOTIFY_QP_DB_TYPE, value)
        if (value != expected_db_type())
          return codec_error("QP-control DB type mismatches selected variant");
        `DB_GET(RDMA_NOTIFY_QP_ICOS, qp.icos)
        `DB_GET(RDMA_NOTIFY_QP_QPN, qp.qpn)
        qp.target_h = decoded_target(RDMA_RESOURCE_QP, qp.qpn,
                                     image.function_generation);
        candidate = qp;
      end
    endcase
`undef DB_GET
    if (candidate == null)
      return codec_error("doorbell decoder produced a null model");
    status = validate_model(candidate);
    if (!status.ok())
      return codec_error({"decoded doorbell semantics are invalid: ",
                          status.message});
    model = candidate;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_doorbell_codec 中由 serialized_equal 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）、equal（输出）、mismatch（输出）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：serialized_equal 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function rdma_status serialized_equal(
    rdma_hw_model lhs,
    rdma_hw_model rhs,
    output bit equal,
    output string mismatch
  );
    rdma_hw_image lhs_image;
    rdma_hw_image rhs_image;
    rdma_status status;

    equal = 1'b0;
    mismatch = "";
    status = encode(lhs, lhs_image);
    if (!status.ok()) begin
      mismatch = {"left model: ", status.message};
      return status;
    end
    status = encode(rhs, rhs_image);
    if (!status.ok()) begin
      mismatch = {"right model: ", status.message};
      return status;
    end
    foreach (lhs_image.bytes[i]) begin
      if (lhs_image.bytes[i] != rhs_image.bytes[i]) begin
        mismatch = $sformatf("serialized byte %0d differs: %02x != %02x",
                             i, lhs_image.bytes[i], rhs_image.bytes[i]);
        return rdma_status::success();
      end
    end
    equal = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：hardware_endian 使用 当前对象字段 计算并返回 rdma_byte_endian_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；hardware_endian 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_byte_endian_e，不取得调用方资源所有权。
  // 失败/边界：hardware_endian 是只读访问器，返回 RDMA_ENDIAN_BIG；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_byte_endian_e hardware_endian();
    return RDMA_ENDIAN_BIG;
  endfunction

  // 功能：describe_fields 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；describe_fields 读取 对象字段：variant_name 并使用字段 variant_name；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe_fields();
    return {"rdma 8-byte doorbell variant ", variant_name};
  endfunction
endclass

class rdma_hw_doorbell_codec_registry extends rdma_codec_registry;
  `uvm_object_utils(rdma_hw_doorbell_codec_registry)

  protected bit defaults_registered;

  // 功能：构造 rdma_hw_doorbell_codec_registry，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：defaults_registered=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_doorbell_codec_registry 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_doorbell_codec_registry");
    super.new(name);
    defaults_registered = 1'b0;
  endfunction

  // 功能：make_key 把 variant 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：variant（输入）；make_key 读取 variant 并使用字段 key.hw_version、key.image_kind、key.object_type、key.variant、key.opcode；函数返回 rdma_codec_key，不取得调用方资源所有权。
// 失败/边界：make_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function rdma_codec_key make_key(string variant);
    rdma_codec_key key;
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_DOORBELL;
    key.object_type = "doorbell";
    key.variant = variant;
    key.opcode = 8'h00;
    return key;
  endfunction

  // 功能：在 rdma_hw_doorbell_codec_registry 中，clear 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function void clear();
    super.clear();
    defaults_registered = 1'b0;
  endfunction

  // 功能：在 rdma_hw_doorbell_codec_registry 中，register_defaults 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：无显式参数；register_defaults 先依据 defaults_registered；!status.ok(；codecs.exists(canonical_keys[i] 校验 函数体读取的依赖；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status register_defaults();
    string variants[13] = '{
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
    string canonical_keys[13];
    rdma_hw_doorbell_codec codec;
    rdma_status status;

    if (defaults_registered)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "rdma doorbell codecs are already registered");
    // Preflight every canonical key before mutating the registry. A collision
    // at any position must preserve the exact prior key set.
    foreach (variants[i]) begin
      status = canonicalize(make_key(variants[i]), canonical_keys[i]);
      if (!status.ok())
        return status;
      if (codecs.exists(canonical_keys[i]))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {"rdma doorbell codec key already registered: ",
           canonical_keys[i]}
        );
    end
    foreach (variants[i]) begin
      codec = new({"doorbell_codec_", variants[i]}, variants[i]);
      codecs[canonical_keys[i]] = codec;
    end
    defaults_registered = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_doorbell_codec_registry 中，find_codec 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：variant（输入）、codec（输出）；find_codec 读取 variant、codec 并使用输入参数和固定枚举/常量，并写入 codec；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：find_codec 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status find_codec(
    string variant,
    output rdma_codec_base codec
  );
    return lookup(make_key(variant), codec);
  endfunction

  // 功能：在 rdma_hw_doorbell_codec_registry 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function rdma_status encode(
    rdma_hw_doorbell_model_base model,
    output rdma_hw_image image
  );
    rdma_codec_base codec;
    rdma_status status;
    image = null;
    if (model == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell registry model is null");
    status = find_codec(model.codec_variant(), codec);
    if (!status.ok()) return status;
    return codec.encode(model, image);
  endfunction

  // 功能：在 rdma_hw_doorbell_codec_registry 中，decode 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：variant（输入）、image（输入）、model（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function rdma_status decode(
    string variant,
    rdma_hw_image image,
    output rdma_hw_model model
  );
    rdma_codec_base codec;
    rdma_status status;
    model = null;
    status = find_codec(variant, codec);
    if (!status.ok()) return status;
    return codec.decode(image, model);
  endfunction

  // 功能：在 rdma_hw_doorbell_codec_registry 中由 serialized_equal 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：variant（输入）、lhs（输入）、rhs（输入）、equal（输出）、mismatch（输出）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：serialized_equal 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function rdma_status serialized_equal(
    string variant,
    rdma_hw_model lhs,
    rdma_hw_model rhs,
    output bit equal,
    output string mismatch
  );
    rdma_codec_base codec;
    rdma_status status;
    equal = 1'b0;
    mismatch = "";
    status = find_codec(variant, codec);
    if (!status.ok()) return status;
    return codec.serialized_equal(lhs, rhs, equal, mismatch);
  endfunction
endclass
