// 目录：适配器接口层 adapter/rdma_context_backing_api.sv。
// 职责：定义 context backing 的 acquire/write/read/release 后端接口；read 为可选观察能力。
// 依赖：本层 types/model/adapter 契约。
// 所有权与生命周期：接口对象只拥有值快照；外部资源为非拥有引用，生命周期由调用方管理。

virtual class rdma_context_backing_api extends uvm_object;

  // 功能：构造 rdma_context_backing_api。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无；外部依赖留待上层注入。
  function new(string name = "rdma_context_backing_api");
    super.new(name);
  endfunction

  // 功能：检查容量后预留 context 资源，返回带 owner 证据的 context_ref。
  // 输入/输出及副作用：binding/resource_kind/local_id 为输入；context_ref 为输出；更新账本。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误，且不泄漏半分配资源。
  pure virtual function rdma_status acquire(
    rdma_function_binding binding,
    rdma_resource_kind_e resource_kind,
    int unsigned local_id,
    output rdma_context_backing_ref context_ref
  );

  // RDMA_RESOURCE_QP uses the same stable contract: acquire returns an opaque
  // control-plane-owned 512-byte, 512-byte-aligned QPC slot authority.  The
  // four method signatures intentionally remain shared with CQ/SRQ backing.

  // 功能：把 data 写入 context_ref 指定后端的 offset 处。
  // 输入/输出及副作用：context_ref/offset/data 为输入；成功才允许调用方推进本地状态。
  // 失败/边界：后端拒绝、范围溢出或 DMA 权限不足时返回错误。
  pure virtual function rdma_status write(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    byte unsigned data[]
  );

  // 功能：从 context backing 读取固定范围的 host-visible bytes（QPC runtime shadow 观察路径）。
  // 输入/输出及副作用：context_ref/offset/size 为输入；data 为输出 detached 快照，不改 owner 或生命周期。
  // 失败/边界：基类返回 UNSUPPORTED_OPCODE 且 data 为空；具体 adapter 须自行校验 handle/generation、
  //   范围和释放状态，不得把缺失读能力伪装成零。
  virtual function rdma_status read(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    int unsigned size,
    output byte unsigned data[]
  );
    data = new[0];
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "context backing read is not supported by this adapter"
    );
  endfunction

  // 功能：按 owner/generation 释放 context_ref 并删除账本引用。
  // 输入/输出及副作用：context_ref 为输入；更新账本与生命周期。
  // 失败/边界：owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果。
  pure virtual function rdma_status \release (rdma_context_backing_ref context_ref);

  // 功能：按完整 key/handle 查询释放是否完成。
  // 输入/输出及副作用：context_ref 为输入；complete 为输出；只读查询。
  // 失败/边界：key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回错误。
  pure virtual function rdma_status query_release_completion(
    rdma_context_backing_ref context_ref,
    output bit complete
  );

  // ABI v5 生命周期约束：context backing 的 acquire/release 由 ABI adapter
  // 以完整 Function snapshot 调用；borrowed context 只登记引用，不调用 release。
endclass
