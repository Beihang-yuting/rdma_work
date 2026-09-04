// 目录：硬件编解码层 codec/rdma_cmq_hw_profile.sv。
// 职责：实现 rdma_cmq_hw_profile 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_cmq_hw_profile.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_cmq_hw_profile extends uvm_object;

  // 功能：构造 rdma_cmq_hw_profile，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_hw_profile 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_hw_profile");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_hw_profile 中，profile_name 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；profile_name 读取 对象字段：rdma_status、snapshot 并使用字段 snapshot；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：profile_name 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “CMQ profile does not recognize the command body type”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  pure virtual function string profile_name();

  // 功能：validate_profile 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CMQ profile does not recognize the command body type”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate_profile 读取 profile_name、hardware_version、command_width_bytes 和 completion_width_bytes，返回 profile 自洽性状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate_profile 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “CMQ profile does not recognize the command body type”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  pure virtual function rdma_status validate_profile();

  // 功能：在 rdma_cmq_hw_profile 中，snapshot_command_body 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；snapshot_command_body 读取 source、snapshot 并使用字段 snapshot，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_command_body 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_cmq_hw_profile 中由 same_command_body_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_command_body_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function bit same_command_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_hw_profile 中，command_body_graph_detached 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：source（输入）、snapshot（输入）；command_body_graph_detached 读取 source、snapshot 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：command_body_graph_detached 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  virtual function bit command_body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_hw_profile 中，snapshot_completion_payload 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；snapshot_completion_payload 读取 source、snapshot 并使用字段 snapshot，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_completion_payload 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_cmq_hw_profile 中由 same_completion_payload_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_completion_payload_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function bit same_completion_payload_value(
    uvm_object lhs,
    uvm_object rhs
  );
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_hw_profile 中，completion_payload_graph_detached 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：source（输入）、snapshot（输入）；completion_payload_graph_detached 读取 source、snapshot 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：completion_payload_graph_detached 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  virtual function bit completion_payload_graph_detached(
    uvm_object source,
    uvm_object snapshot
  );
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_hw_profile 中，compose_sqe 按 profile 的字段布局和端序把语义模型编码为硬件镜像，并在发布前检查长度与对齐。
  // 输入/输出及副作用：command（输入）、slot（输入）、sqe（输出）、expected（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：模型为空、字段越界、保留位非零或输出长度不足时返回编码错误，不发布部分图像。
  pure virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );

  // 功能：在 rdma_cmq_hw_profile 中，inspect_cqe 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：raw_cqe（输入）、expected_owner（输入）、ready（输出）、decoded（输出）；inspect_cqe 校验 raw_cqe 的长度、镜像类型和 owner 代际，成功时写入 ready 与 decoded；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：inspect_cqe 只读输入并返回 rdma_status；边界由函数体现有分支决定，不修改状态或转移资源。
  pure virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );

  // 功能：在 rdma_cmq_hw_profile 中，encode_doorbell 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：cmq_h（输入）、final_pi（输入）、polarity（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_doorbell 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  pure virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
endclass
