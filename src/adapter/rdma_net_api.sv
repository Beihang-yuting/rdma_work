// 目录：适配器接口层 adapter/rdma_net_api.sv。
// 职责：声明网络 observer 与 rdma_net_api 抽象接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有值快照；外部资源为非拥有引用，生命周期由调用方管理。

// 中文说明：本文件定义网络侧接口；先看公开类型与接口，再看实现。失败路径应保持状态与所有权可追踪。

virtual class rdma_net_observer extends uvm_object;

  // 功能：构造 observer 对象。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_net_observer");
    super.new(name);
  endfunction

  // 功能：由 observer 接收一个网络 packet 通知。
  // 输入/输出及副作用：packet 为输入；具体副作用由子类实现。
  // 失败/边界：由子类实现定义。
  pure virtual function void write(rdma_packet packet);
endclass

virtual class rdma_net_api extends uvm_object;

  // 功能：构造网络 API 对象。
  // 输入/输出及副作用：name 为 UVM 对象名；不绑定外部依赖。
  // 失败/边界：无。
  function new(string name = "rdma_net_api");
    super.new(name);
  endfunction

  // 功能：发送一个 packet 并返回 status。
  // 输入/输出及副作用：packet 输入；status 输出；副作用由实现定义。
  // 失败/边界：失败通过 status 返回，具体条件由实现定义。
  pure virtual task send_packet(
    rdma_packet packet,
    output rdma_status status
  );

  // 功能：接收一个 packet 并返回 status。
  // 输入/输出及副作用：packet、status 均为输出；副作用由实现定义。
  // 失败/边界：失败或超时通过 status 返回，不隐式重试。
  pure virtual task receive_packet(
    output rdma_packet packet,
    output rdma_status status
  );

  // 功能：登记网络事件 observer。
  // 输入/输出及副作用：observer 输入；实现保存非拥有引用。
  // 失败/边界：重复登记等条件由实现定义。
  pure virtual function void register_observer(rdma_net_observer observer);

  // 功能：配置网络响应 policy。
  // 输入/输出及副作用：policy 输入；成功时保存非拥有引用；返回 status。
  // 失败/边界：空依赖或重复配置返回错误并保留旧配置（由实现定义）。
  pure virtual function rdma_status configure_response_policy(
    rdma_net_response_policy policy
  );

  // 功能：向网络适配器的故障注入通道提交 fault 请求。
  // 输入/输出及副作用：fault 只读（kind/function_uid/resource_id）；返回 status。
  // 失败/边界：仅限测试/恢复范围；代际或资源不匹配时拒绝并保留原账本。
  pure virtual function rdma_status inject_fault(rdma_net_fault fault);
endclass
