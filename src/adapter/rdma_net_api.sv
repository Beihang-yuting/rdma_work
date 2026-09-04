// 目录：适配器接口层 adapter/rdma_net_api.sv。
// 职责：实现 rdma_net_api 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_net_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_net_observer extends uvm_object;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_net_observer");
    super.new(name);
  endfunction

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 endclas 用于执行 write；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
  pure virtual function void write(rdma_packet packet);
endclass

virtual class rdma_net_api extends uvm_object;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_net_api");
    super.new(name);
  endfunction

  // 功能：处理 send_packet：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 packet, status 用于执行 send_packet；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：send_packet 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  pure virtual task send_packet(
    rdma_packet packet,
    output rdma_status status
  );

  // 功能：处理 receive_packet：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 packet, status 用于执行 receive_packet；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：receive_packet 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  pure virtual task receive_packet(
    output rdma_packet packet,
    output rdma_status status
  );

  // 功能：把指定资源或后端能力绑定到当前对象的唯一索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：输入为待绑定资源/后端引用；成功后新增一条受 identity 保护的关联记录。
  //   重复绑定、资源类型错误或依赖缺失时不留下部分关联。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  pure virtual function void register_observer(rdma_net_observer observer);

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
  pure virtual function rdma_status configure_response_policy(
    rdma_net_response_policy policy
  );

  // 功能：执行 inject_fault 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 endclas 用于执行 inject_fault；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：inject_fault 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  pure virtual function rdma_status inject_fault(rdma_net_fault fault);
endclass
