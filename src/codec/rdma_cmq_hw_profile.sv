// 目录/层次：codec 层 CMQ hardware profile 抽象契约。
// 职责：定义 profile 名称/自校验与 SQE/CQE/doorbell 编解码。
// 依赖：rdma_cmq_engine_models 的 command/slot/ticket/CQE 值、rdma_hw_image/model、rdma_status；
//  具体 body 类型只出现在派生 profile 中。
// 所有权与生命周期：profile 拥有自身 codec 组合；输入为非拥有只读值，成功输出由调用方拥有。

// 设计说明：抽象 profile 是 model 与具体 hardware codec 的依赖倒置边界。
virtual class rdma_cmq_hw_profile extends uvm_object;

  // 功能：构造抽象基对象，仅建立 UVM 实例身份。
  // 输入/输出及副作用：name 透传给 uvm_object。
  // 失败/边界：抽象类不能单独实例化。
  function new(string name = "rdma_cmq_hw_profile");
    super.new(name);
  endfunction

  // 功能：返回派生实现的稳定 profile 名称，供 registry/opcode key 选 codec。
  // 输入/输出及副作用：无参数；返回字符串，不改状态。
  // 失败/边界：实现应返回非空且跨运行稳定的名称，由 validate_profile 检查。
  pure virtual function string profile_name();

  // 功能：校验派生 profile 的名称、hardware version、SQE/CQE 宽度与 codec registry 完整性。
  // 输入/输出及副作用：无参数；只读配置。
  // 失败/边界：错误码与拒绝条件由派生类定义；不得隐式注册或修复 codec。
  pure virtual function rdma_status validate_profile();

  // 功能：把已校验的 command 与 slot 编码为完整 SQE，并产生 CQE 期望键。
  // 输入/输出及副作用：command/slot 只读；sqe/expected 输出且应入口清空，成功后由调用方拥有。
  // 失败/边界：模型空/无效、opcode/body 不支持、slot 不匹配或字段越界时返回错误，不得发布部分结果。
  pure virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );

  // 功能：校验 raw CQE image，比较 owner bit，ready 时解码 opcode/index/status/payload。
  // 输入/输出及副作用：raw_cqe/expected_owner 只读；ready 始终写回；decoded 仅完整解码成功时发布。
  // 失败/边界：owner 不同表示 not-ready 而非错误；metadata、reserved bits、opcode/status 或 payload
  //  解码失败返回错误且不发布部分 decoded。
  pure virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );

  // 功能：把 CMQ handle、批次最终 PI 与 polarity 编码为 profile 专用 doorbell image。
  // 输入/输出及副作用：参数只读；image 入口清空，成功发布完整 BAR-write image，不执行 MMIO。
  // 失败/边界：cmq_h 非 CMQ/代际无效、PI 超出 ring 宽度或 codec/profile 未就绪时返回错误，不发布部分 image。
  pure virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
endclass
