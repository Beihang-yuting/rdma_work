// 目录/层次：codec 层 CMQ hardware profile 抽象契约。
// 职责：定义 profile 名称/自校验、SQE/CQE/doorbell 编解码，以及 model 层
// 无法实现的 polymorphic body/payload 非致命快照与 canonicalization seam。
// 主要依赖：rdma_cmq_engine_models 的 command/slot/ticket/CQE 值、rdma_hw_image/model
// 和 rdma_status；具体 body 类型只能在派生 RDMA profile 中出现。
// 所有权与生命周期：profile 拥有自身 codec 组合；所有输入是非拥有只读值，
// 成功输出由调用方拥有，基类默认 seam 不保存输入句柄。

// 设计说明：抽象 profile 是 model 与具体 hardware codec 的依赖倒置边界；
// polymorphic body/payload 的复制和 canonicalization 必须留在知道其真实类型的派生层。
virtual class rdma_cmq_hw_profile extends uvm_object;

  // 功能：构造 CMQ profile 抽象基对象，仅建立 UVM 实例身份。
  // 输入/输出及副作用：name 透传给 uvm_object；基类没有 codec 或外部资源字段。
  // 失败/边界：抽象类不能单独实例化；派生类必须实现 profile 与三个硬件编解码接口。
  function new(string name = "rdma_cmq_hw_profile");
    super.new(name);
  endfunction

  // 功能：返回派生实现的稳定 profile 名称，供 registry/opcode key 选择 codec。
  // 输入/输出及副作用：无参数；返回 string 值，不修改 profile 或注册表。
  // 失败/边界：实现应返回非空、跨运行稳定的名称；约束由 validate_profile() 统一检查。
  pure virtual function string profile_name();

  // 功能：校验派生 profile 的稳定名称、hardware version、SQE/CQE 宽度和 codec registry 完整性。
  // 输入/输出及副作用：无参数；只读 profile 配置，返回自洽性 rdma_status。
  // 失败/边界：具体错误码和拒绝条件由派生 profile 定义；失败不得隐式注册或修复 codec。
  pure virtual function rdma_status validate_profile();

  // 功能：提供 codec-layer 唯一合法的 polymorphic body nonfatal snapshot 边界。
  // 输入/输出及副作用：source 为输入，snapshot 为输出且入口清空；具体 profile
  //   成功时发布 typed detached 值，不修改请求拥有的 body。
  // 失败/边界：base profile 恒返 INVALID_ARGUMENT/null；实现不得用 fatal generic
  //   clone/copy 伪装 status-returning 边界，也不得回退未知 subtype。
  virtual function rdma_status snapshot_command_body(
    rdma_hw_model source,
    output rdma_hw_model snapshot
  );
    snapshot = null;
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ profile does not recognize the command body type"
    );
  endfunction

  // 功能：提供 codec-layer 唯一合法的 polymorphic body V1 canonicalization seam。
  // 输入/输出及副作用：source 为输入，schema_tag/field bytes 为 fresh 输出；
  //   实现只返回稳定 type tag 之后的字段 bytes，不保留 source 引用。
  // 失败/边界：base 实现清空两项输出并返回 UNSUPPORTED_OPCODE；未知 body 不能
  //   由 factory name 或 fallback tag 编码，也不得发布 partial bytes。
  virtual function rdma_status canonicalize_command_body(
    input rdma_hw_model source,
    output string schema_tag,
    output byte unsigned canonical_field_bytes[]
  );
    schema_tag = "";
    canonical_field_bytes = new[0];
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "CMQ profile does not canonicalize this command body type"
    );
  endfunction

  // 功能：声明 profile-owned command-body 值相等检查，供 snapshot 发布前验真。
  // 输入/输出及副作用：lhs/rhs 为只读 polymorphic body；基类不识别任何类型，固定返回 0。
  // 失败/边界：即使两个句柄相同或均为 null，基类也不声明值相等；派生类必须精确派发。
  virtual function bit same_command_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    return 1'b0;
  endfunction

  // 功能：声明 profile-owned command-body 图分离检查，阻止 snapshot 保留源节点别名。
  // 输入/输出及副作用：source/snapshot 为只读 body 图；基类无法解释嵌套节点，固定返回 0。
  // 失败/边界：基类从不认证 detached；派生类必须同时检查外层和每个可变嵌套句柄。
  virtual function bit command_body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    return 1'b0;
  endfunction

  // 功能：提供 completion payload 的 status-returning nonfatal polymorphic snapshot 边界。
  // 输入/输出及副作用：source 为输入，snapshot 为输出且入口清空；实现成功时
  //   发布 typed detached payload，不修改 completion 拥有的源值。
  // 失败/边界：base profile 恒返 INVALID_ARGUMENT/null；未知 subtype 或分离失败
  //   不发布 partial payload，且实现不得依赖会触发 UVM fatal 的 factory clone。
  virtual function rdma_status snapshot_completion_payload(
    uvm_object source,
    output uvm_object snapshot
  );
    snapshot = null;
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ profile does not recognize the completion payload type"
    );
  endfunction

  // 功能：声明 profile-owned completion-payload 值相等检查，用于验证直接拷贝结果。
  // 输入/输出及副作用：lhs/rhs 为只读 payload；基类固定返回 0，不修改任一对象。
  // 失败/边界：基类不接受 null 或相同句柄作为相等证据；派生类须对受支持 subtype 逐字段比较。
  virtual function bit same_completion_payload_value(
    uvm_object lhs,
    uvm_object rhs
  );
    return 1'b0;
  endfunction

  // 功能：声明 profile-owned completion payload 图分离检查，保证观测快照不别名源图。
  // 输入/输出及副作用：source/snapshot 为只读 payload；基类固定返回 0，不保存句柄。
  // 失败/边界：基类从不认证图已分离；派生类必须拒绝外层自别名和任一嵌套共享节点。
  virtual function bit completion_payload_graph_detached(
    uvm_object source,
    uvm_object snapshot
  );
    return 1'b0;
  endfunction

  // 功能：把已校验 command 与 slot 编码为完整 SQE，同时产生 CQE 期望键。
  // 输入/输出及副作用：command/slot 只读；sqe/expected 为输出且应在入口清空，
  // 成功后由调用方拥有两个 detached 值。
  // 失败/边界：空/无效模型、profile 不支持的 opcode/body、slot 不匹配或硬件字段越界
  // 时返回错误；派生实现不得发布部分 SQE/expected。
  pure virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );

  // 功能：校验 raw CQE image，比较 owner bit，并在 ready 时解码 opcode/index/status/payload。
  // 输入/输出及副作用：raw_cqe/expected_owner 只读；ready 始终写回，decoded 仅在
  // 完整解码成功时发布，输出对象由调用方拥有。
  // 失败/边界：owner 不同表示 not-ready 而非错误；image metadata、reserved bits、opcode/status
  // 或 payload 解码失败时返回错误并不发布部分 decoded 图。
  pure virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );

  // 功能：把 CMQ handle、批次最终 PI 和 polarity 编码为 profile-specific doorbell image。
  // 输入/输出及副作用：cmq_h/final_pi/polarity 只读；image 入口清空，成功时发布
  // 调用方拥有的完整 BAR-write image，不执行实际 MMIO。
  // 失败/边界：cmq_h 非 CMQ/代际无效、PI 超出 ring 宽度或 doorbell codec/profile 未就绪时
  // 返回错误；不得发布部分 image。
  pure virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
endclass
