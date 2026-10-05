// 目录：硬件编解码层 codec/rdma/rdma_doorbell_codecs.sv。
// 职责：实现 rdma_hw_doorbell_codecs 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

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

  // 功能：构造 rdma_hw_doorbell_model_base。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_doorbell_model_base");
    super.new(name);
    target_h = null;
  endfunction

  // 功能：把 rhs 的字段复制到当前对象。
  // 输入/输出及副作用：rhs 只读；写入当前对象字段。
  // 失败/边界：rhs 类型不符时 uvm_fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_doorbell_model_base rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "doorbell model copy type mismatch")
    target_h = rdma_clone_handle_value(rhs_model.target_h,
                                       "rdma doorbell target");
  endfunction

  // 功能：校验 doorbell 的 target handle 与期望资源类型。
  // 输入/输出及副作用：target_h 只读；label 用于错误文本。
  // 失败/边界：handle 为空或 kind 不符返回 INVALID_ARGUMENT；generation 为 0 返回 STALE_GENERATION。
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

  // 功能：检查 value 是否放得进 width 位。
  // 输入/输出及副作用：只读；label 用于错误文本。
  // 失败/边界：width 小于 64 且 value 超出该位宽时返回 INVALID_ARGUMENT。
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

  // 功能：检查 target handle 的 object_id 是否等于 expected_id。
  // 输入/输出及副作用：target_h 只读（调用方须已校验非空）。
  // 失败/边界：object_id 不等返回 INVALID_ARGUMENT。
  protected function rdma_status target_id_status(
    int unsigned expected_id,
    string label
  );
    if (target_h.object_id != expected_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {label, " target object ID does not match"});
    return rdma_status::success();
  endfunction

  // 功能：基类校验：target handle 非空且 generation 非 0。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：handle 为空返回 INVALID_ARGUMENT；generation 为 0 返回 STALE_GENERATION。
  virtual function rdma_status validate();
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "rdma doorbell target handle is null");
    if (target_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "rdma doorbell target generation is stale");
    return rdma_status::success();
  endfunction

  // 功能：返回该 model 对应的 doorbell 类别（子类实现）。
  // 输入/输出及副作用：无参数；只读。
  // 失败/边界：无。
  pure virtual function rdma_doorbell_kind_e doorbell_kind();

  // 功能：按当前 variant 返回 codec 变体名。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  pure virtual function string codec_variant();
endclass

class rdma_hw_cmq_sq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `rdma_object_utils(rdma_hw_cmq_sq_doorbell_model)

  int unsigned pi;
  bit polarity;

  // 功能：构造 rdma_hw_cmq_sq_doorbell_model。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_cmq_sq_doorbell_model");
    super.new(name);
    pi = 0;
    polarity = 1'b0;
  endfunction

  // 功能：把 rhs 的字段复制到当前对象。
  // 输入/输出及副作用：rhs 只读；写入当前对象字段。
  // 失败/边界：rhs 类型不符时 uvm_fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_cmq_sq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ doorbell copy type mismatch")
    pi = rhs_model.pi;
    polarity = rhs_model.polarity;
  endfunction

  // 功能：校验 rdma_hw_cmq_sq_doorbell_model 的 target 与各字段位宽。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：target 为空/类型或 generation 不符、字段超位宽或 object ID 不匹配时返回非成功状态。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_CMQ, "CMQ doorbell");
    if (!status.ok()) return status;
    return width_status(pi, RDMA_CMQ_DB_PI_WIDTH, "CMQ doorbell PI");
  endfunction

  // 功能：返回 RDMA_DOORBELL_CMQ_SQ。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_CMQ_SQ;
  endfunction

  // 功能：返回 "cmq_sq"。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function string codec_variant();
    return "cmq_sq";
  endfunction

  // 功能：生成该 model 的诊断文本。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("rdma CMQ doorbell(pi=%0d polarity=%0b)",
                     pi, polarity);
  endfunction
endclass

class rdma_hw_sq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `rdma_object_utils(rdma_hw_sq_doorbell_model)

  byte unsigned sqe_header[$];

  // 功能：构造 rdma_hw_sq_doorbell_model。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_sq_doorbell_model");
    super.new(name);
    sqe_header.delete();
  endfunction

  // 功能：把 rhs 的字段复制到当前对象。
  // 输入/输出及副作用：rhs 只读；写入当前对象字段。
  // 失败/边界：rhs 类型不符时 uvm_fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_sq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SQ doorbell copy type mismatch")
    sqe_header = rhs_model.sqe_header;
  endfunction

  // 功能：校验 SQ doorbell 的 target 与 8 字节 header。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：target 非法或 sqe_header 长度不是 RDMA_DB_BYTES 时返回非成功状态。
  virtual function rdma_status validate();
    rdma_status status;
    status = target_status(RDMA_RESOURCE_QP, "SQ doorbell");
    if (!status.ok()) return status;
    if (sqe_header.size() != RDMA_DB_BYTES)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQ doorbell header is not exactly eight bytes");
    return rdma_status::success();
  endfunction

  // 功能：返回 RDMA_DOORBELL_SQ。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_SQ;
  endfunction

  // 功能：返回 "sq"。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function string codec_variant();
    return "sq";
  endfunction

  // 功能：返回 "rdma opaque SQ doorbell header"。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function string describe();
    return "rdma opaque SQ doorbell header";
  endfunction
endclass

class rdma_hw_rq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `rdma_object_utils(rdma_hw_rq_doorbell_model)

  int unsigned qpn;
  int unsigned icos;
  int unsigned pi;
  bit wrap;

  // 功能：构造 rdma_hw_rq_doorbell_model。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_rq_doorbell_model");
    super.new(name);
    qpn = 0;
    icos = 0;
    pi = 0;
    wrap = 1'b0;
  endfunction

  // 功能：把 rhs 的字段复制到当前对象。
  // 输入/输出及副作用：rhs 只读；写入当前对象字段。
  // 失败/边界：rhs 类型不符时 uvm_fatal。
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

  // 功能：校验 rdma_hw_rq_doorbell_model 的 target 与各字段位宽。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：target 为空/类型或 generation 不符、字段超位宽或 object ID 不匹配时返回非成功状态。
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

  // 功能：返回 RDMA_DOORBELL_RQ。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_RQ;
  endfunction

  // 功能：返回 "rq"。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function string codec_variant();
    return "rq";
  endfunction

  // 功能：生成该 model 的诊断文本。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("rdma RQ doorbell(qpn=%0d pi=%0d wrap=%0b)",
                     qpn, pi, wrap);
  endfunction
endclass

class rdma_hw_srq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `rdma_object_utils(rdma_hw_srq_doorbell_model)

  rdma_hw_srq_doorbell_variant_e variant;
  int unsigned srqn;
  int unsigned pi;
  bit wrap;
  int unsigned limit;
  int unsigned arm_sn;

  // 功能：构造 rdma_hw_srq_doorbell_model。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_srq_doorbell_model");
    super.new(name);
    variant = RDMA_SRQ_DB_PI;
    srqn = 0;
    pi = 0;
    wrap = 1'b0;
    limit = 0;
    arm_sn = 0;
  endfunction

  // 功能：把 rhs 的字段复制到当前对象。
  // 输入/输出及副作用：rhs 只读；写入当前对象字段。
  // 失败/边界：rhs 类型不符时 uvm_fatal。
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

  // 功能：校验 rdma_hw_srq_doorbell_model 的 target 与各字段位宽。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：target 为空/类型或 generation 不符、variant 非法、字段超位宽或 object ID 不匹配时返回非成功状态。
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

  // 功能：返回 RDMA_DOORBELL_SRQ。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_SRQ;
  endfunction

  // 功能：按当前 variant 返回 codec 变体名。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string codec_variant();
    return (variant == RDMA_SRQ_DB_PI) ? "srq_pi" : "srq_limit";
  endfunction

  // 功能：生成该 model 的诊断文本。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("rdma SRQ doorbell(variant=%s srqn=%0d)",
                     codec_variant(), srqn);
  endfunction
endclass

class rdma_hw_cq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `rdma_object_utils(rdma_hw_cq_doorbell_model)

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

  // 功能：构造 rdma_hw_cq_doorbell_model。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
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

  // 功能：把 rhs 的字段复制到当前对象。
  // 输入/输出及副作用：rhs 只读；写入当前对象字段。
  // 失败/边界：rhs 类型不符时 uvm_fatal。
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

  // 功能：校验 rdma_hw_cq_doorbell_model 的 target 与各字段位宽。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：target 为空/类型或 generation 不符、variant 非法、字段超位宽或 object ID 不匹配时返回非成功状态。
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

  // 功能：返回 RDMA_DOORBELL_CQ。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_CQ;
  endfunction

  // 功能：按当前 variant 返回 codec 变体名。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string codec_variant();
    return (variant == RDMA_CQ_DB_RC_UD) ? "cq_rc_ud" : "cq_urc";
  endfunction

  // 功能：生成该 model 的诊断文本。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("rdma CQ doorbell(variant=%s cqn=%0d)",
                     codec_variant(), cqn);
  endfunction
endclass

class rdma_hw_ceq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `rdma_object_utils(rdma_hw_ceq_doorbell_model)

  int unsigned ceqn;
  int unsigned ci;
  bit wrap;

  // 功能：构造 rdma_hw_ceq_doorbell_model。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_ceq_doorbell_model");
    super.new(name);
    ceqn = 0;
    ci = 0;
    wrap = 1'b0;
  endfunction

  // 功能：把 rhs 的字段复制到当前对象。
  // 输入/输出及副作用：rhs 只读；写入当前对象字段。
  // 失败/边界：rhs 类型不符时 uvm_fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_ceq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQ doorbell copy type mismatch")
    ceqn = rhs_model.ceqn;
    ci = rhs_model.ci;
    wrap = rhs_model.wrap;
  endfunction

  // 功能：校验 rdma_hw_ceq_doorbell_model 的 target 与各字段位宽。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：target 为空/类型或 generation 不符、字段超位宽或 object ID 不匹配时返回非成功状态。
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

  // 功能：返回 RDMA_DOORBELL_CEQ。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_CEQ;
  endfunction

  // 功能：返回 "ceq"。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function string codec_variant();
    return "ceq";
  endfunction

  // 功能：生成该 model 的诊断文本。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("rdma CEQ doorbell(ceqn=%0d ci=%0d wrap=%0b)",
                     ceqn, ci, wrap);
  endfunction
endclass

class rdma_hw_aeq_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `rdma_object_utils(rdma_hw_aeq_doorbell_model)

  int unsigned aeqn;
  int unsigned ci;
  bit wrap;

  // 功能：构造 rdma_hw_aeq_doorbell_model。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_aeq_doorbell_model");
    super.new(name);
    aeqn = 0;
    ci = 0;
    wrap = 1'b0;
  endfunction

  // 功能：把 rhs 的字段复制到当前对象。
  // 输入/输出及副作用：rhs 只读；写入当前对象字段。
  // 失败/边界：rhs 类型不符时 uvm_fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hw_aeq_doorbell_model rhs_model;
    super.do_copy(rhs);
    if (!$cast(rhs_model, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQ doorbell copy type mismatch")
    aeqn = rhs_model.aeqn;
    ci = rhs_model.ci;
    wrap = rhs_model.wrap;
  endfunction

  // 功能：校验 rdma_hw_aeq_doorbell_model 的 target 与各字段位宽。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：target 为空/类型或 generation 不符、字段超位宽或 object ID 不匹配时返回非成功状态。
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

  // 功能：返回 RDMA_DOORBELL_AEQ。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return RDMA_DOORBELL_AEQ;
  endfunction

  // 功能：返回 "aeq"。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function string codec_variant();
    return "aeq";
  endfunction

  // 功能：生成该 model 的诊断文本。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("rdma AEQ doorbell(aeqn=%0d ci=%0d wrap=%0b)",
                     aeqn, ci, wrap);
  endfunction
endclass

class rdma_hw_qp_control_doorbell_model
    extends rdma_hw_doorbell_model_base;
  `rdma_object_utils(rdma_hw_qp_control_doorbell_model)

  rdma_doorbell_kind_e kind;
  int unsigned qpn;
  int unsigned dst_port;
  int unsigned qp_sn;
  int unsigned icos;

  // 功能：构造 rdma_hw_qp_control_doorbell_model。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_qp_control_doorbell_model");
    super.new(name);
    kind = RDMA_DOORBELL_QP_FLUSH;
    qpn = 0;
    dst_port = 0;
    qp_sn = 0;
    icos = 0;
  endfunction

  // 功能：把 rhs 的字段复制到当前对象。
  // 输入/输出及副作用：rhs 只读；写入当前对象字段。
  // 失败/边界：rhs 类型不符时 uvm_fatal。
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

  // 功能：校验 rdma_hw_qp_control_doorbell_model 的 target 与各字段位宽。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：target 为空/类型或 generation 不符、kind 非法、字段超位宽或 object ID 不匹配时返回非成功状态。
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

  // 功能：返回 kind。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function rdma_doorbell_kind_e doorbell_kind();
    return kind;
  endfunction

  // 功能：按当前 variant 返回 codec 变体名。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string codec_variant();
    case (kind)
      RDMA_DOORBELL_RTS2SQD:  return "rts2sqd";
      RDMA_DOORBELL_SQD2RTS:  return "sqd2rts";
      RDMA_DOORBELL_QP_FLUSH: return "qp_flush";
      RDMA_DOORBELL_TX_FLUSH: return "tx_flush";
      default:                return "invalid";
    endcase
  endfunction

  // 功能：生成该 model 的诊断文本。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("rdma QP-control doorbell(kind=%s qpn=%0d)",
                     kind.name(), qpn);
  endfunction
endclass

class rdma_hw_doorbell_codec extends rdma_codec_base;
  `rdma_object_utils(rdma_hw_doorbell_codec)

  protected string variant_name;

  // 功能：构造 rdma_hw_doorbell_codec。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_doorbell_codec",
               string variant_name = "rq");
    super.new(name);
    this.variant_name = variant_name;
  endfunction

  // 功能：构造 INVALID_ARGUMENT 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 CODEC_ERROR 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：判断 variant_name 是否为已登记的 doorbell 变体。
  // 输入/输出及副作用：只读；返回 bit。
  // 失败/边界：不在 13 个变体名内返回 0。
  protected function bit supported_variant();
    return variant_name inside {
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
  endfunction

  // 功能：按 variant_name 返回 doorbell 窗口内的期望偏移。
  // 输入/输出及副作用：只读；返回 64 位偏移。
  // 失败/边界：未知 variant 返回全 1。
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

  // 功能：selected_mask 根据 variant_name 返回对应门铃布局的字段所有权掩码，
  //   供 encode、validate_image 和 decode 共同执行保留位检查。
  // 输入/输出及副作用：无显式参数；函数只读取 variant_name，返回 bit [63:0]，
  //   不写入 builder、image 或任何外部资源。
  // 失败/边界：支持的 CMQ/SQ/RQ/SRQ/CQ/CEQ/AEQ/QP-control variant 返回驱动掩码；
  //   未登记 variant 返回零，调用方应先由 supported_variant() 拒绝该 codec。
  protected function bit [63:0] selected_mask();
    case (variant_name)
      "cmq_sq":   return 64'h0000_003f_0000_0000;
      "sq":       return 64'hffff_ffff_ffff_ffff;
      "rq":       return 64'h0000_ffff_00ff_ffff;
      "srq_pi":   return 64'h4000_ffff_0000_ffff;
      "srq_limit":return 64'h8000_0000_ffff_ffff;
      // cq.h:108-113 的顶部字段含两个 invalid 标记；即使对应游标无效驱动也会写入，
      // 因此两种 CQ variant 的 mask 都必须包含它们。
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

  // 功能：按 variant_name 返回期望的 doorbell 类别。
  // 输入/输出及副作用：只读；返回 rdma_doorbell_kind_e。
  // 失败/边界：未列出的 variant 落入 default，返回 TX_FLUSH。
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

  // 功能：按 variant_name 返回 QP 控制类 doorbell 的 db_type。
  // 输入/输出及副作用：只读；返回 int。
  // 失败/边界：非 QP 控制类 variant 返回 0。
  protected function int unsigned expected_db_type();
    case (variant_name)
      "rts2sqd":  return RDMA_DB_TYPE_RTS2SQD;
      "sqd2rts":  return RDMA_DB_TYPE_SQD2RTS;
      "qp_flush": return RDMA_DB_TYPE_QP_FLUSH;
      "tx_flush": return RDMA_DB_TYPE_TX_FLUSH;
      default:     return 0;
    endcase
  endfunction

  // 功能：通过 qword builder 写入 doorbell 的一个字段。
  // 输入/输出及副作用：builder 被更新（words/occupancy）；不修改源 model。
  // 失败/边界：越界、宽度不符或与既有写入重叠时返回 CODEC_ERROR。
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

  // 功能：从 builder 的 qword 中读取一个字段。
  // 输入/输出及副作用：builder 只读；value 输出提取值。
  // 失败/边界：提取失败时返回 CODEC_ERROR 并带原因。
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

  // 功能：为解码结果构造 target handle。
  // 输入/输出及副作用：返回新建 rdma_handle；function_uid 置 0，其余取自入参。
  // 失败/边界：无。
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

  // 功能：校验 model 的 variant、动态类型和字段内容。
  // 输入/输出及副作用：model 只读；返回 status。
  // 失败/边界：variant 不支持返回 UNSUPPORTED_OPCODE；类型转换失败或字段非法返回对应错误。
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

  // 功能：encode_fields 按 variant_name 将具体门铃模型的字段写入单个 qword builder；
  //   SQ variant 还会把驱动实际写入门铃窗口的 8B WQE header word0 原样复制到 byte 0..7。
  // 输入/输出及副作用：model 为只读的 typed doorbell 输入，builder 为可变输出；
  //   通过 put()/put_memcpy() 发布字段 ownership，不修改 model 或其 target handle。
  // 失败/边界：variant 与 model 动态类型不匹配、builder 写入越界或后端返回错误时
  //   立即返回对应 rdma_status；未完成字段不会被视为可提交的完整门铃。
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
        if (!$cast(cmq, model))
          return invalid_argument("cmq_sq codec requires CMQ doorbell model");
        `DB_PUT(RDMA_CMQ_DB_PI, cmq.pi)
        `DB_PUT(RDMA_CMQ_DB_POLARITY, cmq.polarity)
      end
      "sq": begin
        if (!$cast(sq, model))
          return invalid_argument("sq codec requires SQ doorbell model");
        header = new[RDMA_DB_BYTES];
        foreach (header[i]) header[i] = sq.sqe_header[i];
        status = builder.put_memcpy(0, header);
        if (!status.ok())
          return codec_error({"SQ header authorship failed: ", status.message});
      end
      "rq": begin
        if (!$cast(rq, model))
          return invalid_argument("rq codec requires RQ doorbell model");
        `DB_PUT(RDMA_NOTIFY_RQ_PI_WRAP, rq.wrap)
        `DB_PUT(RDMA_NOTIFY_RQ_PI, rq.pi)
        `DB_PUT(RDMA_NOTIFY_RQ_ICOS, rq.icos)
        `DB_PUT(RDMA_NOTIFY_RQ_QPN, rq.qpn)
      end
      "srq_pi": begin
        if (!$cast(srq, model))
          return invalid_argument("srq_pi codec requires SRQ doorbell model");
        `DB_PUT(RDMA_NOTIFY_SRQ_LIMIT_INVALID,
                RDMA_NOTIFY_SRQ_LIMIT_INVALID_VALUE)
        `DB_PUT(RDMA_NOTIFY_SRFQ_WRAP, srq.wrap)
        `DB_PUT(RDMA_NOTIFY_SRFQ_PI, srq.pi)
        `DB_PUT(RDMA_NOTIFY_SRFQN, srq.srqn)
      end
      "srq_limit": begin
        if (!$cast(srq, model))
          return invalid_argument(
            "srq_limit codec requires SRQ doorbell model");
        `DB_PUT(RDMA_NOTIFY_SRQ_PI_INVALID,
                RDMA_NOTIFY_SRQ_PI_INVALID_VALUE)
        `DB_PUT(RDMA_NOTIFY_SRQ_LIMIT, srq.limit)
        `DB_PUT(RDMA_NOTIFY_SRQ_ARM_SN, srq.arm_sn)
        `DB_PUT(RDMA_NOTIFY_SRFQN, srq.srqn)
      end
      "cq_rc_ud", "cq_urc": begin
        if (!$cast(cq, model))
          return invalid_argument("CQ codec requires CQ doorbell model");
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
        if (!$cast(ceq, model))
          return invalid_argument("ceq codec requires CEQ doorbell model");
        `DB_PUT(RDMA_NOTIFY_CEQ_CI_WRAP, ceq.wrap)
        `DB_PUT(RDMA_NOTIFY_CEQ_CI, ceq.ci)
        `DB_PUT(RDMA_NOTIFY_CEQ_CEQN, ceq.ceqn)
      end
      "aeq": begin
        if (!$cast(aeq, model))
          return invalid_argument("aeq codec requires AEQ doorbell model");
        `DB_PUT(RDMA_NOTIFY_AEQ_CI_WRAP, aeq.wrap)
        `DB_PUT(RDMA_NOTIFY_AEQ_CI, aeq.ci)
        `DB_PUT(RDMA_NOTIFY_AEQ_AEQN, aeq.aeqn)
      end
      default: begin
        if (!$cast(qp, model))
          return invalid_argument(
            "QP-control codec requires QP-control doorbell model");
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

  // 功能：检查 builder 已写入的字段位与 selected_mask 一致。
  // 输入/输出及副作用：builder 只读；读取 occupancy。
  // 失败/边界：occupancy 不是单个 qword 或与 selected_mask 不同时返回 CODEC_ERROR。
  protected function rdma_status validate_encode_mask(
    rdma_hw_qword_builder builder
  );
    bit [63:0] occupancy[];
    builder.get_occupancy(occupancy);
    if (occupancy.size() != 1 || occupancy[0] != selected_mask())
      return codec_error("doorbell field authorship differs from selected mask");
    return rdma_status::success();
  endfunction

  // 功能：把 doorbell model 编码为 8 字节 BAR 写入 image。
  // 输入/输出及副作用：model 只读；image 输出新建 image，失败时为 null。
  // 失败/边界：model 校验、字段写入、mask 校验或序列化失败时返回错误且不发布 image。
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

  // 功能：validate_image 校验门铃 image 的 variant、8B 长度、BAR 目标、generation、
  //   endian/版本元数据，并重新反序列化后核对 selected_mask。
  // 输入/输出及副作用：image 为只读输入；函数只创建临时 payload、builder、words，
  //   返回 rdma_status，不修改 image、codec variant 或任何门铃游标。
  // 失败/边界：variant 不支持、image 为空/非 8B、generation 为零、目标或元数据错误、
  //   反序列化失败、qword 含非掩码位（含 X/Z）时返回对应错误；成功才允许 decode 使用。
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
    if (words.size() != 1 ||
        !rdma_raw_qword_mask_is_valid(words[0], selected_mask()))
      return codec_error("doorbell image contains a selected-variant reserved bit");
    return rdma_status::success();
  endfunction

  // 功能：把 8 字节 doorbell image 解码为 typed model。
  // 输入/输出及副作用：image 只读；model 输出新建 model，失败时为 null。
  // 失败/边界：image 校验、反序列化、字段读取或解码结果语义校验失败时返回错误。
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

  // 功能：编码两个 model 并逐字节比较序列化结果。
  // 输入/输出及副作用：lhs/rhs 只读；equal 与 mismatch 输出比较结论。
  // 失败/边界：任一侧编码失败时返回其错误并在 mismatch 注明左/右；字节不同时 equal=0。
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

  // 功能：返回 RDMA_ENDIAN_BIG。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  virtual function rdma_byte_endian_e hardware_endian();
    return RDMA_ENDIAN_BIG;
  endfunction

  // 功能：返回含 variant_name 的 codec 描述文本。
  // 输入/输出及副作用：只读；返回 string。
  // 失败/边界：无。
  virtual function string describe_fields();
    return {"rdma 8-byte doorbell variant ", variant_name};
  endfunction
endclass

class rdma_hw_doorbell_codec_registry extends rdma_codec_registry;
  `rdma_object_utils(rdma_hw_doorbell_codec_registry)

  protected bit defaults_registered;

  // 功能：构造 rdma_hw_doorbell_codec_registry。
  // 输入/输出及副作用：name 为 UVM 对象名；字段置为默认值。
  // 失败/边界：无。
  function new(string name = "rdma_hw_doorbell_codec_registry");
    super.new(name);
    defaults_registered = 1'b0;
  endfunction

  // 功能：构造 doorbell 变体的 codec registry 键。
  // 输入/输出及副作用：variant 输入；返回 rdma_codec_key。
  // 失败/边界：无。
  protected function rdma_codec_key make_key(string variant);
    rdma_codec_key key;
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_DOORBELL;
    key.object_type = "doorbell";
    key.variant = variant;
    key.opcode = 8'h00;
    return key;
  endfunction

  // 功能：清空 registry 并复位默认注册标志。
  // 输入/输出及副作用：调用 super.clear 后 defaults_registered=0。
  // 失败/边界：无。
  virtual function void clear();
    super.clear();
    defaults_registered = 1'b0;
  endfunction

  // 功能：登记全部 13 个 doorbell codec 变体。
  // 输入/输出及副作用：写入 registry；先预检所有键，冲突时不改动已有键集。
  // 失败/边界：已登记过或任一键冲突/规范化失败时返回错误。
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
    // 先预检全部规范键再修改 registry；任一位置冲突都必须保持原键集不变。
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

  // 功能：返回 lookup(make_key(variant), codec)。
  // 输入/输出及副作用：无副作用。
  // 失败/边界：无。
  protected function rdma_status find_codec(
    string variant,
    output rdma_codec_base codec
  );
    return lookup(make_key(variant), codec);
  endfunction

  // 功能：按 model 的 codec_variant 查找 codec 并编码。
  // 输入/输出及副作用：model 只读；image 输出。
  // 失败/边界：model 为空或找不到 codec 时返回错误；其余由 codec 决定。
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

  // 功能：按 variant 查找 codec 并解码。
  // 输入/输出及副作用：image 只读；model 输出。
  // 失败/边界：找不到 codec 时返回错误；其余由 codec 决定。
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

  // 功能：按 variant 查找 codec 并比较序列化结果。
  // 输入/输出及副作用：lhs/rhs 只读；equal/mismatch 输出。
  // 失败/边界：找不到 codec 时返回错误；其余由 codec 决定。
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
