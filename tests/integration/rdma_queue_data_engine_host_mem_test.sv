// 目录：测试层 integration/rdma_queue_data_engine_host_mem_test.sv。
// 职责：验证 device-producer 在真实 pinned host_mem 上的 CQ/CEQ/AEQ
//       publish、mapping-relative 分段读回、ring wrap 和释放契约。
// 依赖：依赖 UVM、Task 9 queue-data fixture、RDMA codec/core 与 pinned
//       host_mem manager/adapter；不复制外部 manager 实现。
// 所有权与生命周期：顶层 task 拥有单一 manager/adapter/proxy 和各 fixture；
//       source CQ 拥有 4KiB mapping，target CQ/engine 只借用，最后逆序清理并查漏。

// 中文说明：rdma_queue_data_engine_host_mem_test.sv 属于集成测试，验证真实适配器与队列/控制面之间的联调。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// End-to-end queue data-plane test using the pinned host_mem implementation.
// The test intentionally reuses the lifecycle fixture from the core package,
// replacing only its host-memory adapter with a delegating real adapter.

import rdma_unit_test_pkg::*;
import rdma_codec_pkg::*;

// 中文设计：这些 one-shot 模式只在本集成测试内破坏 adapter 返回契约，
// 用真实 proxy 调用链验证 null status、缺失 mapping 与失败 partial data
// 不会越过测试边界成为正式输出；未命中的方法继续调用真实 pinned adapter。
typedef enum int unsigned {
  RDMA_REAL_MEM_FAULT_NONE,
  RDMA_REAL_MEM_FAULT_ALLOCATE_NULL_STATUS,
  RDMA_REAL_MEM_FAULT_ALLOCATE_SUCCESS_NULL,
  RDMA_REAL_MEM_FAULT_WRITE_NULL_STATUS,
  RDMA_REAL_MEM_FAULT_READ_NULL_PARTIAL,
  RDMA_REAL_MEM_FAULT_READ_ERROR_PARTIAL,
  RDMA_REAL_MEM_FAULT_RELEASE_NULL_STATUS,
  RDMA_REAL_MEM_FAULT_OPAQUE_RELEASE_NULL_STATUS
} rdma_real_mem_fault_e;

// 中文设计：fault adapter 继承真实 adapter，正常模式仍持有真实 manager
// allocation ledger；arm 后仅下一次匹配 API 返回畸形结果，测试随后恢复正常
// 模式并通过真实 release 收口，避免用 mock 掩盖 ownership 副作用。
class rdma_fault_host_mem_adapter extends rdma_host_mem_adapter;
  `uvm_object_utils(rdma_fault_host_mem_adapter)

  protected rdma_real_mem_fault_e next_fault;

  // 功能：构造 one-shot fault adapter，并以不注入故障的模式启动。
  // 输入/输出及副作用：name 为 UVM 对象名；初始化真实 adapter 基类与
  //   next_fault，不创建 manager 或 pinned allocation。
  // 失败/边界：mem 仍须由顶层显式绑定；未 arm 时全部 API 保持真实行为。
  function new(string name = "rdma_fault_host_mem_adapter");
    super.new(name);
    next_fault = RDMA_REAL_MEM_FAULT_NONE;
  endfunction

  // 功能：arm 选择下一次匹配 adapter API 的单次畸形返回模式。
  // 输入/输出及副作用：fault 为输入并覆盖 next_fault；不调用 manager，
  //   不分配、写入或释放任何 mapping。
  // 失败/边界：重复 arm 以最后一次为准；NONE 显式取消尚未消费的故障。
  function void arm(rdma_real_mem_fault_e fault);
    next_fault = fault;
  endfunction

  // 功能：consume_fault 判断当前 API 是否命中已 arm 模式，命中后立即复位。
  // 输入/输出及副作用：expected 为输入；返回是否命中的 bit，命中时把
  //   next_fault 清为 NONE，保证故障不会污染恢复清理。
  // 失败/边界：模式不匹配时返回 0 且保留原模式，供预定 API 稍后消费。
  protected function bit consume_fault(rdma_real_mem_fault_e expected);
    if (next_fault != expected)
      return 1'b0;
    next_fault = RDMA_REAL_MEM_FAULT_NONE;
    return 1'b1;
  endfunction

  // 功能：allocate 在指定模式返回 null status+非空假 candidate 或
  //   success+null mapping，否则执行真实 pinned allocation。
  // 输入/输出及副作用：request_context/size/alignment/direction 为输入，
  //   mapping 为输出；正常路径更新真实 adapter ledger，故障路径不占用 backing。
  // 失败/边界：故障 candidate 没有 allocation identity，只用于证明 proxy
  //   不发布 backend 临时输出；one-shot 消费后后续 allocate 自动恢复正常。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    if (consume_fault(RDMA_REAL_MEM_FAULT_ALLOCATE_NULL_STATUS)) begin
      mapping = rdma_dma_mapping::type_id::create("fault_allocate_candidate");
      return null;
    end
    if (consume_fault(RDMA_REAL_MEM_FAULT_ALLOCATE_SUCCESS_NULL)) begin
      mapping = null;
      return rdma_status::success();
    end
    return super.allocate(request_context, size, alignment, direction, mapping);
  endfunction

  // 功能：write 在指定模式返回 null status 且不写 backing，否则委托真实 adapter。
  // 输入/输出及副作用：mapping/offset/data 为输入；正常路径可能更新 pinned
  //   bytes，故障路径只消费模式且不改变 allocation/cursor。
  // 失败/边界：null status 是被测 contract violation；恢复后的调用仍须接受
  //   真实 adapter 的 authority、range 与 permission 校验。
  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    if (consume_fault(RDMA_REAL_MEM_FAULT_WRITE_NULL_STATUS))
      return null;
    return super.write(mapping, offset, data);
  endfunction

  // 功能：read 在指定模式写入两字节 partial candidate 后返回 null 或明确错误，
  //   否则从真实 pinned backing 读取完整数据。
  // 输入/输出及副作用：mapping/offset/size 为输入，data 为输出；故障路径只写
  //   临时错误载荷，不修改 backing，正常路径保持真实 adapter read 语义。
  // 失败/边界：两种 partial 模式均为 one-shot；调用边界必须返回非成功并
  //   丢弃 data，不能把 `8'hd1/8'hd2` 暴露给上层。
  virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    if (consume_fault(RDMA_REAL_MEM_FAULT_READ_NULL_PARTIAL)) begin
      data = new[2];
      data[0] = 8'hd1;
      data[1] = 8'hd2;
      return null;
    end
    if (consume_fault(RDMA_REAL_MEM_FAULT_READ_ERROR_PARTIAL)) begin
      data = new[2];
      data[0] = 8'he1;
      data[1] = 8'he2;
      return rdma_status::make(
        RDMA_SC_UNKNOWN_HW_ERROR, "injected partial read failure");
    end
    return super.read(mapping, offset, size, data);
  endfunction

  // 功能：release 在指定模式返回 null 且保留真实 allocation，供 proxy 验证
  //   strict release 的 status 归一化与 active index 稳定性。
  // 输入/输出及副作用：mapping 为输入；正常路径释放 backing，故障路径只消费
  //   模式，不标记 completion、不改变真实 ledger。
  // 失败/边界：故障后必须切回正常模式精确释放同一 mapping；不得重试已成功释放者。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    if (consume_fault(RDMA_REAL_MEM_FAULT_RELEASE_NULL_STATUS))
      return null;
    return super.\release (mapping);
  endfunction

  // 功能：release_opaque 在指定模式返回 null 且不消费 allocation identity，
  //   否则由真实 adapter 按 opaque token 完成释放。
  // 输入/输出及副作用：mapping 为输入；正常成功会更新真实 ledger/completion，
  //   故障路径只消费 next_fault，不修改 proxy canonical index。
  // 失败/边界：故障 mapping 必须仍可在恢复调用中释放一次；未知或重复 token
  //   继续由真实 adapter 返回明确非成功。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    if (consume_fault(RDMA_REAL_MEM_FAULT_OPAQUE_RELEASE_NULL_STATUS))
      return null;
    return super.release_opaque(mapping);
  endfunction
endclass

// 中文设计：真实 adapter 的 opaque allocation identity 不能穿过 resource
// manager 的 borrowed public projection；本 proxy 作为测试边界恢复 canonical
// identity，但只借用 adapter/mapping，真实 manager 与 allocation 生命周期仍由上层拥有。
class rdma_real_host_mem_proxy extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_real_host_mem_proxy)

  rdma_host_mem_adapter delegate;
  // 中文设计：resource manager 会把 borrowed carrier 安全投影为基类值；
  // proxy 因而按 IOVA 保存 allocate 返回的真实 mapping 非拥有引用，并在 I/O
  // 前核对全部 public authority 字段，绝不把该索引当成释放权。
  rdma_dma_mapping active_mappings[longint unsigned];
  int unsigned strict_release_successes[longint unsigned];
  int unsigned opaque_release_successes[longint unsigned];

  // 功能：构造一个仅负责 API 适配的 real host_mem proxy，清空 delegate、
  //   active canonical mapping 索引与两类成功 release 证据账本。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地引用/计数，
  //   不创建、不释放真实 manager 或 mapping。
  // 失败/边界：构造后 delegate 为 null，所有 I/O/release 必须拒绝为
  //   INVALID_STATE；proxy 始终不取得外部 adapter 所有权。
  function new(string name = "rdma_real_host_mem_proxy");
    super.new(name);
    delegate = null;
    active_mappings.delete();
    strict_release_successes.delete();
    opaque_release_successes.delete();
  endfunction

  // 功能：same_handle_value 比较两个 detached handle 是否描述同一
  //   Function/resource 实例，供 proxy 恢复真实 adapter mapping identity。
  // 输入/输出及副作用：lhs/rhs 为只读输入；返回 kind、function_uid、
  //   object_id、generation 全部相同的 bit，不修改 handle 或 proxy 账本。
  // 失败/边界：两个 null 视为相同，仅一个 null 视为不同；不把对象别名
  //   当作身份依据，也不接受代际不同的旧 handle。
  protected function bit same_handle_value(
    rdma_handle lhs,
    rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：same_mapping_value 核对 projected mapping 与 allocate 返回的
  //   canonical mapping 的全部 public authority/geometry/state 字段。
  // 输入/输出及副作用：candidate/canonical 为只读输入；返回字段完全
  //   一致的 bit，不暴露或复制 host_mem adapter 的 opaque allocation identity。
  // 失败/边界：任一 mapping/Function/owner/route/epoch/范围/权限字段不一致
  //   都返回 0，禁止仅凭 IOVA 命中真实 allocation。
  protected function bit same_mapping_value(
    rdma_dma_mapping candidate,
    rdma_dma_mapping canonical
  );
    if (candidate == null || canonical == null)
      return 1'b0;
    return same_handle_value(candidate.function_h, canonical.function_h) &&
           candidate.requester_bdf == canonical.requester_bdf &&
           candidate.pasid_valid == canonical.pasid_valid &&
           candidate.pasid == canonical.pasid &&
           candidate.dma_domain_valid == canonical.dma_domain_valid &&
           candidate.dma_domain_id == canonical.dma_domain_id &&
           candidate.route_valid == canonical.route_valid &&
           candidate.route.host_topology_key ==
             canonical.route.host_topology_key &&
           candidate.route.root_id == canonical.route.root_id &&
           candidate.route.segment == canonical.route.segment &&
           rdma_bdf_same(candidate.route.bdf, canonical.route.bdf) &&
           candidate.epoch_valid == canonical.epoch_valid &&
           candidate.reset_epoch == canonical.reset_epoch &&
           candidate.backing_addr == canonical.backing_addr &&
           candidate.iova == canonical.iova &&
           candidate.size == canonical.size &&
           candidate.direction == canonical.direction &&
           candidate.permissions == canonical.permissions &&
           candidate.state == canonical.state &&
           same_handle_value(candidate.owner_h, canonical.owner_h);
  endfunction

  // 功能：resolve_delegate_mapping 将 resource manager 有意降型的 borrowed
  //   mapping 投影解析回本 proxy 在 allocate 时保存的真实 canonical mapping。
  // 输入/输出及副作用：mapping 为只读输入，resolved 输出非拥有 canonical
  //   引用；函数只查 active_mappings，不创建、释放或修改 pinned allocation。
  // 失败/边界：mapping/null、未知 IOVA 或完整 public 字段不匹配时返回
  //   INVALID_ARGUMENT/DMA_TRANSLATION；禁止猜测相邻地址或回退直接 delegate。
  protected function rdma_status resolve_delegate_mapping(
    rdma_dma_mapping mapping,
    output rdma_dma_mapping resolved
  );
    resolved = null;
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "proxy mapping is null");
    if (!active_mappings.exists(mapping.iova.value))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "proxy mapping IOVA is not active");
    if (!same_mapping_value(mapping, active_mappings[mapping.iova.value]))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "proxy mapping authority fields changed");
    resolved = active_mappings[mapping.iova.value];
    return rdma_status::success();
  endfunction

  // 功能：allocate 委托真实 adapter 分配 pinned mapping，并按成功 mapping
  //   的 IOVA 保存 canonical 非拥有引用，供 borrowed 投影后的 I/O 恢复 identity。
  // 输入/输出及副作用：request_context/size/alignment/direction 为输入；
  //   mapping 入口清空，只有 delegate 返回非空 candidate 和成功 status 后才发布
  //   并更新 active_mappings，proxy 不取得真实 allocation 的释放权。
  // 失败/边界：delegate 缺失、返回 null/non-OK status 或 success/null mapping
  //   时返回明确非成功，mapping 保持 null 且 canonical index 不改变。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_dma_mapping candidate;
    rdma_status status;

    mapping = null;
    candidate = null;
    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    status = delegate.allocate(request_context, size, alignment, direction,
                               candidate);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "real host-memory allocate returned null status");
    if (!status.ok())
      return status;
    if (candidate == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "real host-memory allocate succeeded without a mapping");
    active_mappings[candidate.iova.value] = candidate;
    mapping = candidate;
    return rdma_status::success();
  endfunction

  // 功能：write 先把 borrowed public mapping 安全解析到 canonical identity，
  //   再由真实 adapter 将 data 写入 mapping-relative offset。
  // 输入/输出及副作用：mapping/offset/data 为输入；成功只修改 pinned bytes，
  //   proxy 不推进队列游标、不取得 mapping 所有权。
  // 失败/边界：delegate 缺失、mapping 未登记/字段变化、范围溢出、权限不足
  //   或任一内部调用返回 null status 时返回明确错误，不执行部分写入。
  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_dma_mapping resolved;
    rdma_status status;

    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    status = resolve_delegate_mapping(mapping, resolved);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "proxy write mapping resolution returned null status");
    if (!status.ok())
      return status;
    status = delegate.write(resolved, offset, data);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "real host-memory write returned null status");
    return status;
  endfunction

  // 功能：read 先把 borrowed public mapping 安全解析到 canonical identity，
  //   再从真实 adapter 读取 mapping-relative offset/size 的 pinned bytes。
  // 输入/输出及副作用：mapping/offset/size 为输入；data 入口清空，真实
  //   adapter 只写 candidate，完整成功且尺寸等于 size 时才发布正式 data。
  // 失败/边界：delegate 缺失、mapping 未登记/字段变化、null/non-OK status、
  //   partial/短读、范围或权限错误时 data 保持空；size=0 可发布空成功。
  virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    rdma_dma_mapping resolved;
    rdma_status status;
    byte candidate[];

    data = new[0];
    candidate = new[0];
    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    status = resolve_delegate_mapping(mapping, resolved);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "proxy read mapping resolution returned null status");
    if (!status.ok())
      return status;
    status = delegate.read(resolved, offset, size, candidate);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "real host-memory read returned null status");
    if (!status.ok())
      return status;
    if (candidate.size() != size)
      return rdma_status::make(
        RDMA_SC_UNKNOWN_HW_ERROR,
        "real host-memory read returned the wrong size");
    data = candidate;
    return rdma_status::success();
  endfunction

  // 功能：release 把完整 public mapping 的 strict 释放委托给真实
  //   adapter，用于正常 lifecycle-owned backing 收口。
  // 输入/输出及副作用：mapping 为输入；delegate 成功时释放 pinned block、
  //   标记 mapping completion，并按 IOVA 累计 strict_release_successes。
  // 失败/边界：delegate 缺失、null status、public geometry/owner/route 篡改、
  //   未知或重复 mapping 时返回非成功，失败不计数也不转为 opaque release。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status status;

    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    status = delegate.\release (mapping);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "real host-memory strict release returned null status");
    if (status.ok() && mapping != null) begin
      strict_release_successes[mapping.iova.value]++;
      active_mappings.delete(mapping.iova.value);
    end
    return status;
  endfunction

  // 功能：release_opaque 把真实 mapping 的不透明释放直接委托给
  //   rdma_host_mem_adapter，避免进入基类 mock token 或 strict geometry 路径。
  // 输入/输出及副作用：mapping 是 adapter 拥有的 allocation capability；
  //   成功时 delegate 释放 pinned backing，并按 IOVA 累计一次成功释放证据。
  // 失败/边界：delegate/null status 返回 INVALID_STATE；空 mapping、未知 token
  //   或重复释放由 delegate 拒绝，失败不增加成功计数，不回退到 release。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    rdma_status status;

    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    status = delegate.release_opaque(mapping);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "real host-memory opaque release returned null status");
    if (status.ok() && mapping != null) begin
      opaque_release_successes[mapping.iova.value]++;
      active_mappings.delete(mapping.iova.value);
    end
    return status;
  endfunction
endclass

// 中文设计：该 UVM test 把 Task 9 lifecycle fixture 与真实 pinned host_mem
// 组合，集中验证 device publish bytes、cursor/credit 和释放边界；测试类拥有
// 本地 fixture/manager，engine/target 仅借用 source backing，不反写 topology authority。
class rdma_queue_data_engine_host_mem_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_host_mem_test)

  // 功能：构造 rdma_queue_data_engine_host_mem_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_engine_host_mem_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_engine_host_mem_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：retain_failure 把一个阶段的 null/non-OK status 规范化后
  //   仅记录为聚合流程的首个失败，便于后续仍继续清理。
  // 输入/输出及副作用：stage/candidate 为输入，first_failure 为 inout；
  //   只可能在其原为 null 时写入，不修改 candidate 或任何 lifecycle 资源。
  // 失败/边界：candidate 为 null 时合成 INVALID_STATE 并带 stage；
  //   candidate 成功或 first_failure 已有值时为空操作，不覆盖原始根因。
  function automatic void retain_failure(
    string stage,
    rdma_status candidate,
    inout rdma_status first_failure
  );
    if (first_failure != null)
      return;
    if (candidate == null)
      first_failure = rdma_status::make(
        RDMA_SC_INVALID_STATE, {stage, " returned null status"});
    else if (!candidate.ok())
      first_failure = candidate;
  endfunction

  // 功能：find_queue_backing 从 lifecycle queue plan 中找到指定 role 的
  //   canonical backing ref，供真实分段读回和所有权检查使用。
  // 输入/输出及副作用：queue/role 为输入；返回 plan 中的非拥有引用，
  //   只读 refs，不修改 mapping、queue 或 cleanup authority。
  // 失败/边界：queue/plan 为 null 或 role 不存在时返回 null；
  //   plan 若非法含多个同 role 时返回最后一个，后续 validate 仍会拒绝歧义。
  function automatic rdma_queue_backing_ref find_queue_backing(
    rdma_queue_resource queue,
    rdma_queue_backing_role_e role
  );
    rdma_queue_backing_ref backing;

    backing = null;
    if (queue == null || queue.queue_plan == null)
      return null;
    foreach (queue.queue_plan.refs[i])
      if (queue.queue_plan.refs[i] != null &&
          queue.queue_plan.refs[i].role == role)
        backing = queue.queue_plan.refs[i];
    return backing;
  endfunction

  // 功能：make_cq_backing_slice 把 source-owned 真实 4KiB mapping 投影为
  //   target CQ 可借用的逻辑 slice，不转移 mapping 释放权。
  // 输入/输出及副作用：name/mapping/logical_offset 为输入；返回新的
  //   4KiB CQ_RING slice，mapping_offset=0，只有 source lifecycle 仍拥有 backing。
  // 失败/边界：mapping 为 null 或 factory 失败时返回 null；对齐、
  //   逻辑连续性和 DEVICE_WRITE authority 由 target create 的 planner 继续校验。
  function automatic rdma_queue_backing_slice make_cq_backing_slice(
    string name,
    rdma_dma_mapping mapping,
    longint unsigned logical_offset
  );
    rdma_queue_backing_slice slice;

    if (mapping == null)
      return null;
    slice = rdma_queue_backing_slice::type_id::create(name);
    if (slice == null)
      return null;
    slice.role = RDMA_QUEUE_ROLE_CQ_RING;
    slice.mapping = mapping;
    slice.mapping_offset = 0;
    slice.length = 4096;
    slice.logical_queue_offset = logical_offset;
    return slice;
  endfunction

  // 功能：published_bytes_match 按字节比较真实 Host-memory 读回数组与
  //   publish 返回的 detached image，不复用 codec 生成期望值。
  // 输入/输出及副作用：actual/image 为只读输入；返回尺寸相等且
  //   每个 byte 四态相等的 bit，不更新 cursor、ledger 或输入对象。
  // 失败/边界：image 为 null、尺寸不同或任一 byte 含 X/Z/不同时
  //   返回 0；空数组与空 image bytes 仅在 image 非空时可判定相等。
  function automatic bit published_bytes_match(
    byte actual[],
    rdma_hw_image image
  );
    if (image == null || actual.size() != image.bytes.size())
      return 1'b0;
    foreach (actual[i])
      if (actual[i] !== image.bytes[i])
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：read_real_queue_entry 通过 backing-access 的 resolve_ref 将队列
  //   logical offset 拆成 mapping-relative spans，再从真实 pinned Host-memory 读回。
  // 输入/输出及副作用：fixture/queue/role/logical_offset/size 为输入；data
  //   入口清空，access 只写 candidate，完整成功且尺寸匹配时才发布正式数据。
  // 失败/边界：必需对象/role/Function 缺失、size=0、null/non-OK status、
  //   partial read、未覆盖区间或 mapping authority 失效时 data 保持空。
  function automatic rdma_status read_real_queue_entry(
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_resource queue,
    rdma_queue_backing_role_e role,
    longint unsigned logical_offset,
    int unsigned size,
    output byte data[]
  );
    rdma_queue_backing_ref backing;
    rdma_queue_backing_access access;
    rdma_status status;
    byte candidate[];

    data = new[0];
    candidate = new[0];
    if (fixture == null || fixture.mem == null || queue == null || size == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "real queue read input is incomplete");
    backing = find_queue_backing(queue, role);
    if (backing == null || backing.mapping == null ||
        backing.mapping.function_h == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "real queue backing is unavailable");
    access = rdma_queue_backing_access::type_id::create(
      "real_queue_read_access");
    if (access == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED, "real queue access allocation failed");
    status = access.configure(backing.mapping.function_h, fixture.mem);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "real queue access configure returned null") :
        status;
    status = access.attach_queue(backing);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "real queue access attach returned null") :
        status;
    status = access.read(logical_offset, size, candidate);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "real queue access read returned null status");
    if (!status.ok())
      return status;
    if (candidate.size() != size)
      return rdma_status::make(
        RDMA_SC_UNKNOWN_HW_ERROR,
        "real queue access read returned the wrong size");
    data = candidate;
    return rdma_status::success();
  endfunction

  // 功能：check_runtime_drained 在一次 publish/poll 后验证指定 runtime 的
  //   producer/consumer 已共同推进到手算 cursor，且 credit/pending 已完全清零。
  // 输入/输出及副作用：fixture/queue_h/kind/expected_index/expected_wrap 为
  //   只读输入；返回查询/断言 status，不修改 PI/CI、backing 或 lifecycle。
  // 失败/边界：fixture/handle 缺失、query 返回 null/non-OK、PI/CI 与期望
  //   不同、used 非零或 pending 存在时返回明确错误，不能把默认输出当作通过。
  function automatic rdma_status check_runtime_drained(
    rdma_queue_data_engine_fixture fixture,
    rdma_handle queue_h,
    rdma_queue_runtime_kind_e kind,
    int unsigned expected_index,
    bit expected_wrap
  );
    rdma_status status;
    int unsigned producer_index;
    int unsigned consumer_index;
    int unsigned used;
    bit producer_wrap;
    bit consumer_wrap;
    bit pending;

    if (fixture == null || fixture.engine == null || queue_h == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "runtime drain input is incomplete");
    status = fixture.engine.query_runtime_cursors(
      queue_h, kind, producer_index, producer_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "runtime cursor query returned null status") :
        status;
    if (producer_index != expected_index ||
        producer_wrap != expected_wrap ||
        consumer_index != expected_index ||
        consumer_wrap != expected_wrap)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "runtime PI/CI did not reach expected cursor");
    status = fixture.engine.query_runtime_occupancy(
      queue_h, kind, used, pending);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "runtime occupancy query returned null status") :
        status;
    if (used != 0 || pending)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "runtime credit or pending state was not drained");
    return rdma_status::success();
  endfunction

  // 功能：release_success_count 合并 proxy 对指定真实 mapping 的 strict
  //   与 opaque 成功释放数，用于验证 borrowed target 不释放 source。
  // 输入/输出及副作用：proxy/mapping 为只读输入；返回对应 IOVA
  //   的两类 delegate 成功次数之和，不修改账本或 mapping state。
  // 失败/边界：proxy 或 mapping 为 null 时返回 0；未出现的关联数组
  //   key 按 SystemVerilog 默认值 0 计数，不能单独代替 release completion/leak 断言。
  function automatic int unsigned release_success_count(
    rdma_real_host_mem_proxy proxy,
    rdma_dma_mapping mapping
  );
    if (proxy == null || mapping == null)
      return 0;
    return proxy.strict_release_successes[mapping.iova.value] +
           proxy.opaque_release_successes[mapping.iova.value];
  endfunction

  // 功能：make_cqe_for_send 从一次已提交的真实 send WQE ledger 构造
  //   CQE，使 publish/poll 只能释放匹配的 QP slot。
  // 输入/输出及副作用：qp/posted/polarity 为输入，status 为输出；
  //   返回 detached CQE model，其 wr_id/index/wrap 来自 post 结果，不修改 ledger。
  // 失败/边界：qp/handle/posted/status 缺失、post 未成功、factory 或 handle
  //   clone 失败时返回 null 和非成功 status，不发布半成品 CQE。
  function automatic rdma_hw_cqe_model make_cqe_for_send(
    rdma_qp qp,
    rdma_queue_post_result posted,
    bit polarity,
    output rdma_status status
  );
    rdma_hw_cqe_model cqe;

    status = rdma_status::success();
    if (qp == null || qp.handle == null || posted == null ||
        posted.status == null || !posted.status.ok()) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "real CQE post evidence is incomplete");
      return null;
    end
    cqe = rdma_hw_cqe_model::type_id::create("real_device_cqe");
    if (cqe == null) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED, "real CQE allocation failed");
      return null;
    end
    cqe.qp_h = rdma_clone_handle_value(qp.handle, "real CQE QP");
    if (cqe.qp_h == null) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED, "real CQE QP clone failed");
      return null;
    end
    cqe.wr_id = posted.wr_id;
    cqe.opcode = RDMA_WR_SEND;
    cqe.status = rdma_status::success();
    cqe.qpn = qp.local_qp_id;
    cqe.wqe_index = posted.index;
    cqe.wqe_wrap = posted.wrap;
    cqe.rq_cqe = 1'b0;
    cqe.polarity = polarity;
    cqe.packet_opcode = 8'h01;
    cqe.ecode = RDMA_CMQ_SUCCESS_ECODE;
    cqe.payload_len = 32;
    cqe.immediate_data = 0;
    cqe.signature = 0;
    return cqe;
  endfunction

  // 功能：cleanup_fixture 是本文件唯一的基础 fixture 收口，仅在
  //   needs_cleanup() 表明尚有 lifecycle ownership 时精确委托一次 Task 9 cleanup。
  // 输入/输出及副作用：fixture 为可空输入，status 返回聚合清理结果；
  //   成功时回收 fixture 拥有的 Function/PD/AEQ/CEQ/CQ/QP 与 backing。
  // 失败/边界：fixture 为 null 时返回 INVALID_STATE；已完整清理时幂等
  //   返回成功；cleanup 返回 null 时规范化为 INVALID_STATE，不复制 teardown。
  task automatic cleanup_fixture(
    rdma_queue_data_engine_fixture fixture,
    output rdma_status status
  );
    status = rdma_status::success();
    if (fixture == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "fixture is null");
    end
    else if (fixture.needs_cleanup()) begin
      fixture.cleanup(status);
      if (status == null)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture cleanup returned null status");
    end
  endtask

  // 功能：create_queue_for_test 调用真实 queue executor，并在 caller-facing
  //   类型投影前从 control result 保存 canonical detached resource handle。
  // 输入/输出及副作用：label/fixture/request/transaction_id/inject_wrong_type 为
  //   输入；resource/created_h/control_result/status 入口置安全值，真实成功会注册 CQ。
  // 失败/边界：依赖、create status、canonical resource/handle 或 clone 缺失时
  //   返回明确错误；注入只替换返回对象，不登记或销毁 fake resource。
  task automatic create_queue_for_test(
    string label,
    rdma_queue_data_engine_fixture fixture,
    rdma_create_cq_req request,
    longint unsigned transaction_id,
    bit inject_wrong_type,
    output rdma_queue_resource resource,
    output rdma_handle created_h,
    output rdma_control_result control_result,
    output rdma_status status
  );
    rdma_queue_resource canonical_resource;

    resource = null;
    created_h = null;
    control_result = null;
    status = rdma_status::success();
    canonical_resource = null;
    if (fixture == null || fixture.queue_executor == null ||
        fixture.binding == null || request == null || transaction_id == 0) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "test queue create input is incomplete");
      return;
    end
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), request,
      transaction_id, canonical_resource, control_result);
    if (control_result != null && control_result.resource_h != null)
      created_h = rdma_clone_handle_value(
        control_result.resource_h, {label, " canonical handle"});
    if (control_result == null || control_result.status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, "test queue create returned no status");
      return;
    end
    if (!control_result.status.ok()) begin
      status = control_result.status;
      return;
    end
    if (canonical_resource == null || created_h == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test queue create omitted canonical resource evidence");
      return;
    end
    if (inject_wrong_type)
      resource = rdma_queue_resource::type_id::create(
        {label, " caller_type_fault"});
    else
      resource = canonical_resource;
    if (resource == null)
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "test queue caller-facing resource allocation failed");
  endtask

  // 功能：cleanup_created_queue_handle 负责按 canonical detached handle 销毁
  //   一个 create 已成功但 caller-facing 类型不可用的 queue。
  // 输入/输出及副作用：fixture/created_h/attached/transaction_id 为输入，status
  //   入口置成功；非空 handle 以 created=1 精确委托一次 lifecycle queue destroy。
  // 失败/边界：null handle 为幂等成功且不解引用 fixture；非空 handle 配 null
  //   fixture、零 transaction_id、attached 但 engine 缺失或底层 destroy 异常
  //   均返回非成功；底层 null status 规范化为 INVALID_STATE。
  task automatic cleanup_created_queue_handle(
    rdma_queue_data_engine_fixture fixture,
    rdma_handle created_h,
    bit attached,
    longint unsigned transaction_id,
    output rdma_status status
  );
    status = rdma_status::success();
    if (created_h == null)
      return;
    if (fixture == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, "test queue cleanup fixture is null");
      return;
    end
    fixture.destroy_lifecycle_owned_queue(
      created_h, 1'b1, attached, transaction_id, status);
    if (status == null)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, "test queue cleanup returned null status");
  endtask

  // 功能：test_partial_create_cleanup_contract 在真实 CQ create 后注入错误动态
  //   类型，验证 cleanup 仍只凭提前保存的 canonical handle 释放 queue/mapping。
  // 输入/输出及副作用：proxy 为借用输入，status 入口置成功并返回首错；task
  //   创建一个额外 owned CQ，保存 release 计数并在失败时执行恢复销毁。
  // 失败/边界：create/canonical lookup/backing 缺失、cast 意外成功、cleanup 后
  //   queue 仍 ACTIVE 或 release 次数不为一次均失败；fake resource 永不销毁。
  task automatic test_partial_create_cleanup_contract(
    rdma_real_host_mem_proxy proxy,
    output rdma_status status
  );
    rdma_queue_data_engine_fixture fixture;
    rdma_create_cq_req request;
    rdma_queue_resource exposed_resource;
    rdma_resource authoritative_resource;
    rdma_cq typed_resource;
    rdma_cq authoritative_cq;
    rdma_queue_backing_ref backing;
    rdma_dma_mapping mapping;
    rdma_handle created_h;
    rdma_control_result control_result;
    rdma_status first_failure;
    rdma_status step;
    rdma_status lookup_status;
    rdma_status cleanup_status;
    int unsigned releases_before;

    status = rdma_status::success();
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "partial_create_fixture");
    first_failure = null;
    created_h = null;
    mapping = null;
    begin : partial_create_flow
      if (proxy == null || fixture == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "partial create fixture is unavailable");
        disable partial_create_flow;
      end
      fixture.mem = proxy;
      fixture.setup(step, 16, 64, 16, 16);
      retain_failure("partial create fixture setup", step, first_failure);
      if (first_failure != null)
        disable partial_create_flow;
      request = rdma_create_cq_req::type_id::create(
        "partial_create_request");
      if (request == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "partial create request allocation failed");
        disable partial_create_flow;
      end
      request.owner = fixture.binding.make_handle();
      request.depth = 64;
      request.cqe_size_bytes = 64;
      request.ceq_h = rdma_clone_handle_value(
        fixture.ceq.handle, "partial create CEQ");
      request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
      create_queue_for_test(
        "partial_create", fixture, request, 64'hd201, 1'b1,
        exposed_resource, created_h, control_result, step);
      retain_failure("partial create injected result", step, first_failure);
      if (first_failure != null || exposed_resource == null ||
          created_h == null) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "partial create did not publish fault evidence");
        disable partial_create_flow;
      end
      if ($cast(typed_resource, exposed_resource)) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "partial create wrong-type injection unexpectedly cast to CQ");
        disable partial_create_flow;
      end
      authoritative_resource = null;
      step = fixture.manager.lookup(created_h, authoritative_resource);
      retain_failure("partial create canonical lookup", step, first_failure);
      if (first_failure != null ||
          !$cast(authoritative_cq, authoritative_resource) ||
          authoritative_cq == null) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "partial create canonical CQ is unavailable");
        disable partial_create_flow;
      end
      backing = find_queue_backing(
        authoritative_cq, RDMA_QUEUE_ROLE_CQ_RING);
      if (backing == null || backing.mapping == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "partial create canonical backing is unavailable");
        disable partial_create_flow;
      end
      mapping = backing.mapping;
      releases_before = release_success_count(proxy, mapping);
      cleanup_created_queue_handle(
        fixture, created_h, 1'b0, 64'hd202, cleanup_status);
      retain_failure("partial create canonical cleanup", cleanup_status,
                     first_failure);
      authoritative_resource = null;
      lookup_status = fixture.manager.lookup(
        created_h, authoritative_resource);
      if (lookup_status == null ||
          lookup_status.code != RDMA_SC_INVALID_STATE ||
          authoritative_resource != null ||
          release_success_count(proxy, mapping) != releases_before + 1)
        retain_failure(
          "partial create cleanup evidence",
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "wrong-type create left canonical queue or mapping active"),
          first_failure);
    end

    // 中文设计：RED 或任一前置失败若仍留下 canonical handle，只按该
    // detached handle 恢复一次；fake exposed_resource 从未登记，禁止销毁。
    authoritative_resource = null;
    lookup_status = fixture == null || fixture.manager == null ||
                    created_h == null ? null :
      fixture.manager.lookup(created_h, authoritative_resource);
    if (lookup_status != null && lookup_status.ok()) begin
      fixture.destroy_lifecycle_owned_queue(
        created_h, 1'b1, 1'b0, 64'hd203, cleanup_status);
      retain_failure("partial create recovery destroy", cleanup_status,
                     first_failure);
    end
    cleanup_fixture(fixture, cleanup_status);
    retain_failure("partial create fixture cleanup", cleanup_status,
                   first_failure);
    status = first_failure == null ? rdma_status::success() : first_failure;
  endtask

  // 功能：test_proxy_failure_output_contracts 以 one-shot 真实 adapter 故障
  //   验证 proxy 对 mapping/data/status 的 candidate-then-publish 边界。
  // 输入/输出及副作用：proxy/fault_adapter 为借用输入，status 入口置成功并
  //   返回首错；task 创建真实 fixture/isolated mappings，故障后恢复并精确释放。
  // 失败/边界：任一 null status、success/null mapping、失败 partial data、
  //   active index 或 release 计数异常均失败，但仍继续释放真实 allocation。
  task automatic test_proxy_failure_output_contracts(
    rdma_real_host_mem_proxy proxy,
    rdma_fault_host_mem_adapter fault_adapter,
    output rdma_status status
  );
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_backing_ref backing;
    rdma_dma_request_context request_context;
    rdma_dma_mapping mapping;
    rdma_dma_mapping opaque_mapping;
    rdma_status first_failure;
    rdma_status step;
    rdma_status cleanup_status;
    byte payload[];
    byte data[];
    int unsigned releases_before;

    status = rdma_status::success();
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "proxy_failure_fixture");
    first_failure = null;
    mapping = null;
    opaque_mapping = null;
    begin : proxy_failure_flow
      if (proxy == null || fault_adapter == null ||
          proxy.delegate != fault_adapter || fixture == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "proxy failure fixture is unavailable");
        disable proxy_failure_flow;
      end
      fixture.mem = proxy;
      fixture.setup(step, 16, 64, 16, 16);
      retain_failure("proxy failure fixture setup", step, first_failure);
      if (first_failure != null)
        disable proxy_failure_flow;
      backing = find_queue_backing(fixture.cq, RDMA_QUEUE_ROLE_CQ_RING);
      if (backing == null || backing.mapping == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "proxy failure backing is unavailable");
        disable proxy_failure_flow;
      end
      request_context = rdma_dma_request_context::type_id::create(
        "proxy_failure_context");
      if (request_context == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "proxy failure context allocation failed");
        disable proxy_failure_flow;
      end
      request_context.function_h = rdma_clone_function_handle_value(
        backing.mapping.function_h, "proxy failure Function");
      request_context.requester_bdf = backing.mapping.requester_bdf;
      request_context.pasid_valid = backing.mapping.pasid_valid;
      request_context.pasid = backing.mapping.pasid;
      request_context.dma_domain_valid = backing.mapping.dma_domain_valid;
      request_context.dma_domain_id = backing.mapping.dma_domain_id;
      request_context.route = backing.mapping.route;
      request_context.route_valid = backing.mapping.route_valid;
      request_context.reset_epoch = backing.mapping.reset_epoch;
      request_context.epoch_valid = backing.mapping.epoch_valid;
      request_context.owner_h = rdma_clone_handle_value(
        backing.mapping.owner_h, "proxy failure owner");

      // 中文设计：先用非空 sentinel 调用 null-status allocation；proxy
      // 必须同时丢弃 caller 旧值与 backend 生成的无 identity candidate。
      mapping = backing.mapping;
      fault_adapter.arm(RDMA_REAL_MEM_FAULT_ALLOCATE_NULL_STATUS);
      step = proxy.allocate(request_context, 4096, 4096,
                            RDMA_DMA_DEVICE_WRITE, mapping);
      if (step == null || step.ok() || mapping != null)
        retain_failure(
          "proxy allocate null status",
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "proxy published null-status allocation output"),
          first_failure);

      mapping = backing.mapping;
      fault_adapter.arm(RDMA_REAL_MEM_FAULT_ALLOCATE_SUCCESS_NULL);
      step = proxy.allocate(request_context, 4096, 4096,
                            RDMA_DMA_DEVICE_WRITE, mapping);
      if (step == null || step.ok() || mapping != null)
        retain_failure(
          "proxy allocate success/null",
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "proxy accepted success without a mapping"),
          first_failure);

      step = proxy.allocate(request_context, 4096, 4096,
                            RDMA_DMA_DEVICE_WRITE, mapping);
      if (step == null || !step.ok() || mapping == null) begin
        retain_failure("proxy recovery allocation", step, first_failure);
        if (step != null && step.ok())
          retain_failure(
            "proxy recovery mapping",
            rdma_status::make(
              RDMA_SC_INVALID_STATE, "proxy recovery mapping is null"),
            first_failure);
        disable proxy_failure_flow;
      end
      payload = new[4];
      payload[0] = 8'h11;
      payload[1] = 8'h22;
      payload[2] = 8'h33;
      payload[3] = 8'h44;

      fault_adapter.arm(RDMA_REAL_MEM_FAULT_WRITE_NULL_STATUS);
      step = proxy.write(mapping, 0, payload);
      if (step == null || step.ok())
        retain_failure(
          "proxy write null status",
          rdma_status::make(
            RDMA_SC_INVALID_STATE, "proxy propagated null write status"),
          first_failure);

      data = new[1];
      data[0] = 8'hff;
      fault_adapter.arm(RDMA_REAL_MEM_FAULT_READ_NULL_PARTIAL);
      step = proxy.read(mapping, 0, 4, data);
      if (step == null || step.ok() || data.size() != 0)
        retain_failure(
          "proxy read null partial",
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "proxy published null-status partial read data"),
          first_failure);

      data = new[1];
      data[0] = 8'hff;
      fault_adapter.arm(RDMA_REAL_MEM_FAULT_READ_ERROR_PARTIAL);
      step = proxy.read(mapping, 0, 4, data);
      if (step == null || step.ok() || data.size() != 0)
        retain_failure(
          "proxy read error partial",
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "proxy published failed partial read data"),
          first_failure);

      data = new[1];
      data[0] = 8'hff;
      fault_adapter.arm(RDMA_REAL_MEM_FAULT_READ_NULL_PARTIAL);
      step = read_real_queue_entry(
        fixture, fixture.cq, RDMA_QUEUE_ROLE_CQ_RING, 0, 64, data);
      if (step == null || step.ok() || data.size() != 0)
        retain_failure(
          "real queue read null partial",
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "real queue helper published failed partial data"),
          first_failure);

      releases_before = release_success_count(proxy, mapping);
      fault_adapter.arm(RDMA_REAL_MEM_FAULT_RELEASE_NULL_STATUS);
      step = proxy.\release (mapping);
      if (step == null || step.ok() ||
          !proxy.active_mappings.exists(mapping.iova.value) ||
          release_success_count(proxy, mapping) != releases_before)
        retain_failure(
          "proxy strict release null status",
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "proxy strict null release changed lifecycle evidence"),
          first_failure);
      step = proxy.\release (mapping);
      retain_failure("proxy strict release recovery", step, first_failure);
      if (step != null && step.ok())
        mapping = null;

      step = proxy.allocate(request_context, 4096, 4096,
                            RDMA_DMA_DEVICE_WRITE, opaque_mapping);
      retain_failure("proxy opaque recovery allocation", step, first_failure);
      if (step == null || !step.ok() || opaque_mapping == null)
        disable proxy_failure_flow;
      releases_before = release_success_count(proxy, opaque_mapping);
      fault_adapter.arm(RDMA_REAL_MEM_FAULT_OPAQUE_RELEASE_NULL_STATUS);
      step = proxy.release_opaque(opaque_mapping);
      if (step == null || step.ok() ||
          !proxy.active_mappings.exists(opaque_mapping.iova.value) ||
          release_success_count(proxy, opaque_mapping) != releases_before)
        retain_failure(
          "proxy opaque release null status",
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "proxy opaque null release changed lifecycle evidence"),
          first_failure);
      step = proxy.release_opaque(opaque_mapping);
      retain_failure("proxy opaque release recovery", step, first_failure);
      if (step != null && step.ok())
        opaque_mapping = null;
    end

    // 中文设计：若流程在正常 recovery release 前中止，只对仍登记于 proxy
    // 的真实 mapping 调用 opaque rollback；fault 已 one-shot 消费，不会污染清理。
    if (mapping != null &&
        proxy != null && proxy.active_mappings.exists(mapping.iova.value)) begin
      cleanup_status = proxy.release_opaque(mapping);
      retain_failure("proxy strict mapping fallback", cleanup_status,
                     first_failure);
    end
    if (opaque_mapping != null && proxy != null &&
        proxy.active_mappings.exists(opaque_mapping.iova.value)) begin
      cleanup_status = proxy.release_opaque(opaque_mapping);
      retain_failure("proxy opaque mapping fallback", cleanup_status,
                     first_failure);
    end
    cleanup_fixture(fixture, cleanup_status);
    retain_failure("proxy failure fixture cleanup", cleanup_status,
                   first_failure);
    status = first_failure == null ? rdma_status::success() : first_failure;
  endtask

  // 功能：cleanup_segmented_profile 按 routed QP→borrowed target CQ→source CQ2
  //   →source CQ1→基础 fixture 的依赖反序清理一个 stride profile。
  // 输入/输出及副作用：fixture/proxy、三个 canonical detached handle、QP、
  //   mapping 和 attach 标志为输入；status 入口置成功安全值，尾部返回首错；
  //   成功时 target 不释放
  //   mapping，两个 source 各释放一次。
  // 失败/边界：任一 detach/destroy/null status/所有权断言失败都只记首错，
  //   但继续尝试其余释放；最后仅通过 cleanup_fixture 委托一次 Task 9 cleanup。
  task automatic cleanup_segmented_profile(
    int unsigned cqe_size,
    rdma_queue_data_engine_fixture fixture,
    rdma_real_host_mem_proxy proxy,
    rdma_handle source_first_h,
    rdma_handle source_second_h,
    rdma_handle target_cq_h,
    rdma_qp target_qp,
    bit target_cq_attached,
    bit target_qp_attached,
    rdma_dma_mapping first_mapping,
    rdma_dma_mapping second_mapping,
    output rdma_status status
  );
    rdma_status first_failure;
    rdma_status step;
    int unsigned first_before;
    int unsigned second_before;
    bit release_complete;

    status = rdma_status::success();
    first_failure = null;
    first_before = release_success_count(proxy, first_mapping);
    second_before = release_success_count(proxy, second_mapping);

    // 中文设计：QP runtime 借用 target CQ route，因此先解除 QP
    // attachment 并销毁 QP，再销毁 target，避免带活 route 释放 CQ。
    if (target_qp != null) begin
      fixture.destroy_lifecycle_owned_qp(
        target_qp.handle, 1'b1, target_qp_attached,
        64'hb100 + cqe_size, step);
      retain_failure("segmented target QP cleanup", step, first_failure);
    end
    cleanup_created_queue_handle(
      fixture, target_cq_h, target_cq_attached,
      64'hb200 + cqe_size, step);
    retain_failure("segmented target CQ cleanup", step, first_failure);
    if (release_success_count(proxy, first_mapping) != first_before ||
        release_success_count(proxy, second_mapping) != second_before)
      retain_failure(
        "borrowed target released source mapping",
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "borrowed target released source mapping"),
        first_failure);

    // 中文设计：target 的所有非拥有引用已撤销，现按第二段
    // 到第一段的顺序销毁 source owners，并同时校验调用数与 completion。
    if (source_second_h != null) begin
      cleanup_created_queue_handle(
        fixture, source_second_h, 1'b0, 64'hb300 + cqe_size, step);
      retain_failure("segmented second source cleanup", step, first_failure);
      if (second_mapping != null &&
          release_success_count(proxy, second_mapping) != second_before + 1)
        retain_failure(
          "second source release count",
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "second source mapping was not released once"),
          first_failure);
      release_complete = 1'b0;
      step = second_mapping == null ? null :
        second_mapping.release_completion_status(release_complete);
      retain_failure("second source release completion", step, first_failure);
      if (step != null && step.ok() && !release_complete)
        retain_failure(
          "second source incomplete release",
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "second source release is incomplete"),
          first_failure);
    end
    if (source_first_h != null) begin
      cleanup_created_queue_handle(
        fixture, source_first_h, 1'b0, 64'hb400 + cqe_size, step);
      retain_failure("segmented first source cleanup", step, first_failure);
      if (first_mapping != null &&
          release_success_count(proxy, first_mapping) != first_before + 1)
        retain_failure(
          "first source release count",
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "first source mapping was not released once"),
          first_failure);
      release_complete = 1'b0;
      step = first_mapping == null ? null :
        first_mapping.release_completion_status(release_complete);
      retain_failure("first source release completion", step, first_failure);
      if (step != null && step.ok() && !release_complete)
        retain_failure(
          "first source incomplete release",
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "first source release is incomplete"),
          first_failure);
    end
    cleanup_fixture(fixture, step);
    retain_failure("segmented base fixture cleanup", step, first_failure);
    status = first_failure == null ? rdma_status::success() : first_failure;
  endtask

  // 功能：run_real_cq_profile 对指定 32/64/128B CQE stride 建立两个
  //   source-owned 4KiB mapping 和一个 borrowed 8KiB target CQ，完成发布与回卷。
  // 输入/输出及副作用：cqe_size/proxy 为输入；status 入口置成功安全值，
  //   尾部返回首个失败；每个 CQE 先 post 真实 send WQE，publish 写 pinned
  //   bytes，poll 后恢复 credit。
  // 失败/边界：stride 不受支持、fixture/create/attach/post/publish/read/poll 任一
  //   null/non-OK 时停止新事务，但始终按 target→source→fixture 逆序清理。
  task automatic run_real_cq_profile(
    int unsigned cqe_size,
    rdma_real_host_mem_proxy proxy,
    output rdma_status status
  );
    rdma_queue_data_engine_fixture fixture;
    rdma_create_cq_req request;
    rdma_queue_resource resource;
    rdma_control_result control_result;
    rdma_queue_backing_slice slice;
    rdma_queue_backing_ref source_backing;
    rdma_queue_backing_ref target_backing;
    rdma_cq source_first;
    rdma_cq source_second;
    rdma_cq target_cq;
    rdma_handle source_first_h;
    rdma_handle source_second_h;
    rdma_handle target_cq_h;
    rdma_qp target_qp;
    rdma_dma_mapping first_mapping;
    rdma_dma_mapping second_mapping;
    rdma_post_send_req send_request;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status first_failure;
    rdma_status step;
    rdma_status diagnostic_status;
    rdma_status cleanup_status;
    byte actual[];
    int unsigned depth;
    int unsigned source_depth;
    int unsigned primary_slots;
    int unsigned expected_index;
    int unsigned drained_index;
    bit expected_wrap;
    bit drained_wrap;
    bit polarity;
    bit target_cq_attached;
    bit target_qp_attached;
    string label;

    status = rdma_status::success();
    fixture = null;
    source_first = null;
    source_second = null;
    target_cq = null;
    source_first_h = null;
    source_second_h = null;
    target_cq_h = null;
    target_qp = null;
    first_mapping = null;
    second_mapping = null;
    first_failure = null;
    target_cq_attached = 1'b0;
    target_qp_attached = 1'b0;
    label = $sformatf("real_cq_%0d", cqe_size);

    begin : profile_flow
      if (proxy == null || proxy.delegate == null ||
          !(cqe_size inside {32, 64, 128})) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "real CQ profile input is invalid");
        disable profile_flow;
      end
      source_depth = 4096 / cqe_size;
      depth = 8192 / cqe_size;
      primary_slots = source_depth;
      fixture = rdma_queue_data_engine_fixture::type_id::create(
        {label, "_fixture"});
      if (fixture == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "real CQ fixture allocation failed");
        disable profile_flow;
      end
      fixture.mem = proxy;
      fixture.setup(step, 16, cqe_size, 16, 16);
      retain_failure("real CQ fixture setup", step, first_failure);
      if (first_failure != null)
        disable profile_flow;

      // 中文设计：两个 source CQ 各以 depth*stride=4096 请求
      // owned ring，planner 生成真实 pinned allocation 并保留唯一 release owner。
      request = rdma_create_cq_req::type_id::create(
        {label, "_source_first_request"});
      if (request == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "first source request allocation failed");
        disable profile_flow;
      end
      request.owner = fixture.binding.make_handle();
      request.depth = source_depth;
      request.cqe_size_bytes = cqe_size;
      request.ceq_h = rdma_clone_handle_value(
        fixture.ceq.handle, "first source CEQ");
      request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
      create_queue_for_test(
        {label, " first source"}, fixture, request,
        64'ha100 + cqe_size, 1'b0, resource, source_first_h,
        control_result, step);
      retain_failure("first source CQ create", step, first_failure);
      if (first_failure == null &&
          (resource == null || !$cast(source_first, resource)))
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "first source CQ cast failed");
      if (first_failure != null)
        disable profile_flow;
      source_backing = find_queue_backing(
        source_first, RDMA_QUEUE_ROLE_CQ_RING);
      if (source_backing == null || source_backing.mapping == null ||
          source_backing.length != 4096 ||
          source_backing.mapping.owner_h == null ||
          !source_backing.mapping.owner_h.same_instance(source_first.handle)) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "first source did not own one 4KiB real mapping");
        disable profile_flow;
      end
      first_mapping = source_backing.mapping;

      request = rdma_create_cq_req::type_id::create(
        {label, "_source_second_request"});
      if (request == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "second source request allocation failed");
        disable profile_flow;
      end
      request.owner = fixture.binding.make_handle();
      request.depth = source_depth;
      request.cqe_size_bytes = cqe_size;
      request.ceq_h = rdma_clone_handle_value(
        fixture.ceq.handle, "second source CEQ");
      request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
      create_queue_for_test(
        {label, " second source"}, fixture, request,
        64'ha200 + cqe_size, 1'b0, resource, source_second_h,
        control_result, step);
      retain_failure("second source CQ create", step, first_failure);
      if (first_failure == null &&
          (resource == null || !$cast(source_second, resource)))
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "second source CQ cast failed");
      if (first_failure != null)
        disable profile_flow;
      source_backing = find_queue_backing(
        source_second, RDMA_QUEUE_ROLE_CQ_RING);
      if (source_backing == null || source_backing.mapping == null ||
          source_backing.length != 4096 ||
          source_backing.mapping.owner_h == null ||
          !source_backing.mapping.owner_h.same_instance(source_second.handle)) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "second source did not own one 4KiB real mapping");
        disable profile_flow;
      end
      second_mapping = source_backing.mapping;

      // 中文设计：target CQ 的两个 slice 逻辑上连续为 8KiB，但
      // 保留两个独立 mapping-relative offset；target 只借用，不获得 release authority。
      request = rdma_create_cq_req::type_id::create(
        {label, "_target_request"});
      if (request == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "target CQ request allocation failed");
        disable profile_flow;
      end
      request.owner = fixture.binding.make_handle();
      request.depth = depth;
      request.cqe_size_bytes = cqe_size;
      request.ceq_h = rdma_clone_handle_value(
        fixture.ceq.handle, "segmented target CEQ");
      request.ring_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
      request.ring_backing.slices.delete();
      slice = make_cq_backing_slice(
        {label, "_primary_slice"}, first_mapping, 0);
      if (slice == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "target primary slice allocation failed");
        disable profile_flow;
      end
      request.ring_backing.slices.push_back(slice);
      slice = make_cq_backing_slice(
        {label, "_additional_slice"}, second_mapping, 4096);
      if (slice == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "target additional slice allocation failed");
        disable profile_flow;
      end
      request.ring_backing.slices.push_back(slice);
      create_queue_for_test(
        {label, " target"}, fixture, request,
        64'ha300 + cqe_size, 1'b0, resource, target_cq_h,
        control_result, step);
      retain_failure("segmented target CQ create", step, first_failure);
      if (first_failure == null &&
          (resource == null || !$cast(target_cq, resource)))
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "segmented target CQ cast failed");
      if (first_failure != null)
        disable profile_flow;
      target_backing = find_queue_backing(target_cq, RDMA_QUEUE_ROLE_CQ_RING);
      if (target_backing == null || target_backing.mapping == null ||
          target_backing.ownership != RDMA_OWNERSHIP_BORROWED ||
          target_backing.length != 4096 ||
          target_backing.additional_segments.size() != 1 ||
          target_backing.additional_segments[0] == null ||
          target_backing.additional_segments[0].mapping == null ||
          target_backing.additional_segments[0].logical_queue_offset != 4096 ||
          target_backing.additional_segments[0].length != 4096 ||
          target_backing.mapping.iova.value != first_mapping.iova.value ||
          target_backing.additional_segments[0].mapping.iova.value !=
            second_mapping.iova.value) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "target CQ did not retain two borrowed mappings");
        disable profile_flow;
      end
      step = fixture.engine.attach_cq(target_cq.handle, RDMA_TRANSPORT_RC);
      retain_failure("segmented target CQ attach", step, first_failure);
      if (first_failure != null)
        disable profile_flow;
      target_cq_attached = 1'b1;
      fixture.create_transport_qp_for_cq(
        {label, "_qp"}, RDMA_TRANSPORT_RC, target_cq, target_qp, step);
      retain_failure("segmented target QP create", step, first_failure);
      if (first_failure != null || target_qp == null) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "segmented target QP is null");
        disable profile_flow;
      end
      step = fixture.engine.attach_qp(target_qp.handle);
      retain_failure("segmented target QP attach", step, first_failure);
      if (first_failure != null)
        disable profile_flow;
      target_qp_attached = 1'b1;

      // 中文设计：一直 publish/poll 到 depth+1，使期望值独立地
      // 覆盖 primary 末槽、additional 首/末槽和首个 wrap 槽；每槽均先建 WQE ledger。
      for (int unsigned n = 0; n <= depth; n++) begin
        expected_index = n == depth ? 0 : n;
        expected_wrap = n == depth;
        send_request = fixture.make_send(
          64'hcafe_0000_0000_0000 + longint'(cqe_size) * 64'h1000 + n);
        send_request.qp_h = rdma_clone_handle_value(
          target_qp.handle, "segmented send QP");
        posted = null;
        fixture.engine.post_send(send_request, posted, step);
        retain_failure("segmented send post", step, first_failure);
        if (first_failure != null || posted == null) begin
          if (first_failure == null)
            first_failure = rdma_status::make(
              RDMA_SC_INVALID_STATE, "segmented send post returned null result");
          disable profile_flow;
        end
        step = fixture.engine.query_runtime_producer_polarity(
          target_cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
        retain_failure("segmented CQ polarity query", step, first_failure);
        if (first_failure != null)
          disable profile_flow;
        cqe = make_cqe_for_send(target_qp, posted, polarity, step);
        retain_failure("segmented CQE model", step, first_failure);
        if (first_failure != null || cqe == null) begin
          if (first_failure == null)
            first_failure = rdma_status::make(
              RDMA_SC_INVALID_STATE, "segmented CQE model is null");
          disable profile_flow;
        end
        published = null;
        fixture.engine.publish_cqe(target_cq.handle, cqe, published, step);
        if (step == null || !step.ok()) begin
          pending = null;
          diagnostic_status = fixture.engine.query_runtime_pending(
            target_cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
          if (diagnostic_status != null && diagnostic_status.ok() &&
              pending != null && pending.failure_status != null) begin
            `uvm_info("REAL_CQ_ROOT_CAUSE",
                      $sformatf("stride=%0d %s", cqe_size,
                                pending.failure_status.convert2string()),
                      UVM_LOW)
            first_failure = pending.failure_status;
          end
          else
            retain_failure("segmented CQE publish", step, first_failure);
        end
        if (first_failure != null || published == null ||
            published.index != expected_index ||
            published.wrap != expected_wrap ||
            published.queue_h == null ||
            !published.queue_h.same_instance(target_cq.handle) ||
            !published.occupancy_valid || published.occupancy != 1) begin
          if (first_failure == null)
            first_failure = rdma_status::make(
              RDMA_SC_INVALID_STATE, "segmented CQ publish cursor mismatch");
          disable profile_flow;
        end
        step = read_real_queue_entry(
          fixture, target_cq, RDMA_QUEUE_ROLE_CQ_RING,
          longint'(published.index) * cqe_size, cqe_size, actual);
        retain_failure("segmented CQE real read", step, first_failure);
        if (first_failure == null &&
            !published_bytes_match(actual, published.image))
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "segmented CQE bytes differ from image");
        if (first_failure != null)
          disable profile_flow;
        if (n == primary_slots - 1 || n == primary_slots ||
            n == depth - 1 || n == depth)
          `uvm_info("REAL_CQ_SAMPLE",
                    $sformatf("stride=%0d index=%0d wrap=%0d bytes=%0d",
                              cqe_size, published.index, published.wrap,
                              actual.size()), UVM_LOW)
        completion = null;
        fixture.engine.poll_cqe(target_cq.handle, 0, completion, step);
        retain_failure("segmented CQE poll", step, first_failure);
        if (first_failure != null || completion == null ||
            completion.queue_h == null ||
            !completion.queue_h.same_instance(target_cq.handle) ||
            completion.cqe == null ||
            completion.cqe.wr_id != send_request.wr_id ||
            completion.cqe.qp_h == null ||
            !completion.cqe.qp_h.same_instance(target_qp.handle) ||
            completion.completion_status == null ||
            !completion.completion_status.ok()) begin
          if (first_failure == null)
            first_failure = rdma_status::make(
              RDMA_SC_INVALID_STATE, "segmented CQ poll owner/credit mismatch");
          disable profile_flow;
        end
        drained_index = expected_index + 1;
        drained_wrap = expected_wrap;
        if (drained_index == depth) begin
          drained_index = 0;
          drained_wrap = ~drained_wrap;
        end
        step = check_runtime_drained(
          fixture, target_cq.handle, RDMA_QUEUE_RUNTIME_CQ,
          drained_index, drained_wrap);
        retain_failure("segmented CQ drain", step, first_failure);
        if (first_failure != null)
          disable profile_flow;
      end
    end

    cleanup_segmented_profile(
      cqe_size, fixture, proxy, source_first_h, source_second_h, target_cq_h,
      target_qp, target_cq_attached, target_qp_attached,
      first_mapping, second_mapping, cleanup_status);
    retain_failure("segmented profile cleanup", cleanup_status, first_failure);
    status = first_failure == null ? rdma_status::success() : first_failure;
  endtask

  // 功能：run_real_event_profiles 在同一个真实 fixture 上发布 16B CEQE
  //   与 AEQE，并用一个真实 CQE/WQE 建立 CEQ 通知的 authoritative route。
  // 输入/输出及副作用：proxy 为借用输入；status 入口置成功安全值，尾部
  //   返回 setup/publish/read/poll/cleanup 的首错；成功路径推进各事件队列
  //   一次 PI/CI 并恢复 credit。
  // 失败/边界：proxy/fixture/backing/route 缺失或任一 status 为 null/non-OK
  //   时不再发布依赖事件，但总是经 cleanup_fixture 精确委托一次清理。
  task automatic run_real_event_profiles(
    rdma_real_host_mem_proxy proxy,
    output rdma_status status
  );
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_backing_ref cq_backing;
    rdma_queue_backing_ref ceq_backing;
    rdma_queue_backing_ref aeq_backing;
    rdma_qp event_qp;
    rdma_post_send_req send_request;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_hw_ceqe_model ceqe;
    rdma_hw_ceqe_model polled_ceqe;
    rdma_hw_aeqe_model aeqe;
    rdma_hw_aeqe_model polled_aeqe;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_queue_completion_result completion;
    rdma_status first_failure;
    rdma_status step;
    rdma_status cleanup_status;
    byte actual[];
    int unsigned cq_pi;
    int unsigned cq_ci;
    bit cq_pi_wrap;
    bit cq_ci_wrap;
    bit polarity;
    bit event_qp_attached;

    status = rdma_status::success();
    fixture = null;
    event_qp = null;
    event_qp_attached = 1'b0;
    first_failure = null;
    begin : event_flow
      if (proxy == null || proxy.delegate == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "real event proxy is unavailable");
        disable event_flow;
      end
      fixture = rdma_queue_data_engine_fixture::type_id::create(
        "real_event_fixture");
      if (fixture == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "real event fixture allocation failed");
        disable event_flow;
      end
      fixture.mem = proxy;
      fixture.setup(step, 16, 64, 16, 16);
      retain_failure("real event fixture setup", step, first_failure);
      if (first_failure != null)
        disable event_flow;
      fixture.create_transport_qp_for_cq(
        "real_event_qp", RDMA_TRANSPORT_RC, fixture.cq, event_qp, step);
      retain_failure("real event QP create", step, first_failure);
      if (first_failure != null || event_qp == null ||
          event_qp.handle == null || event_qp.local_qp_id == 0) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "real event QP lacks handle or nonzero QPN authority");
        disable event_flow;
      end
      step = fixture.engine.attach_qp(event_qp.handle);
      retain_failure("real event QP attach", step, first_failure);
      if (first_failure != null)
        disable event_flow;
      event_qp_attached = 1'b1;
      cq_backing = find_queue_backing(fixture.cq, RDMA_QUEUE_ROLE_CQ_RING);
      ceq_backing = find_queue_backing(fixture.ceq, RDMA_QUEUE_ROLE_CEQ_RING);
      aeq_backing = find_queue_backing(fixture.aeq, RDMA_QUEUE_ROLE_AEQ_RING);
      if (cq_backing == null || cq_backing.mapping == null ||
          ceq_backing == null || ceq_backing.mapping == null ||
          aeq_backing == null || aeq_backing.mapping == null ||
          cq_backing.mapping.owner_h == null ||
          !cq_backing.mapping.owner_h.same_instance(fixture.cq.handle) ||
          ceq_backing.mapping.owner_h == null ||
          !ceq_backing.mapping.owner_h.same_instance(fixture.ceq.handle) ||
          aeq_backing.mapping.owner_h == null ||
          !aeq_backing.mapping.owner_h.same_instance(fixture.aeq.handle)) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "real event backing owner is invalid");
        disable event_flow;
      end

      // 中文设计：CEQE 必须通知一个已提交 CQ producer，因此先在
      // fixture QP 上 post WQE，发布 CQE 并保留未 poll 的 CQ PI 供 CEQE 编码。
      send_request = fixture.make_send(64'he001);
      send_request.qp_h = rdma_clone_handle_value(
        event_qp.handle, "real event send QP");
      posted = null;
      fixture.engine.post_send(send_request, posted, step);
      retain_failure("real event send post", step, first_failure);
      if (first_failure != null || posted == null) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "real event post returned null result");
        disable event_flow;
      end
      step = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      retain_failure("real event CQ polarity", step, first_failure);
      if (first_failure != null)
        disable event_flow;
      cqe = make_cqe_for_send(event_qp, posted, polarity, step);
      retain_failure("real event CQE model", step, first_failure);
      if (first_failure != null || cqe == null) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "real event CQE model is null");
        disable event_flow;
      end
      published = null;
      fixture.engine.publish_cqe(fixture.cq.handle, cqe, published, step);
      retain_failure("real event CQE publish", step, first_failure);
      if (first_failure != null || published == null ||
          published.index != 0 || published.wrap != 0) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "real event CQE cursor mismatch");
        disable event_flow;
      end
      step = read_real_queue_entry(
        fixture, fixture.cq, RDMA_QUEUE_ROLE_CQ_RING,
        longint'(published.index) * 64, 64, actual);
      retain_failure("real event CQE read", step, first_failure);
      if (first_failure == null &&
          !published_bytes_match(actual, published.image))
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "real event CQE bytes mismatch");
      if (first_failure != null)
        disable event_flow;

      step = fixture.engine.query_runtime_cursors(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ,
        cq_pi, cq_pi_wrap, cq_ci, cq_ci_wrap);
      retain_failure("real event CQ cursor", step, first_failure);
      if (first_failure != null)
        disable event_flow;
      step = fixture.engine.query_runtime_producer_polarity(
        fixture.ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, polarity);
      retain_failure("real CEQ polarity", step, first_failure);
      if (first_failure != null)
        disable event_flow;
      ceqe = rdma_hw_ceqe_model::type_id::create("real_ceqe");
      if (ceqe == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "real CEQE allocation failed");
        disable event_flow;
      end
      ceqe.cq_h = rdma_clone_handle_value(fixture.cq.handle, "real CEQE CQ");
      ceqe.cqn = fixture.cq.local_cq_id;
      ceqe.qpn = event_qp.local_qp_id;
      ceqe.cq_pi = cq_pi;
      ceqe.cq_pi_wrap = cq_pi_wrap;
      ceqe.valid = polarity;
      ceqe.ecode = 0;
      ceqe.packet_opcode = 0;
      published = null;
      fixture.engine.publish_ceqe(fixture.ceq.handle, ceqe, published, step);
      retain_failure("real CEQE publish", step, first_failure);
      if (first_failure != null || published == null ||
          published.image == null || published.image.length != 16) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "real CEQE publish result is incomplete");
        disable event_flow;
      end
      step = read_real_queue_entry(
        fixture, fixture.ceq, RDMA_QUEUE_ROLE_CEQ_RING,
        longint'(published.index) * 16, 16, actual);
      retain_failure("real CEQE read", step, first_failure);
      if (first_failure == null &&
          !published_bytes_match(actual, published.image))
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "real CEQE bytes mismatch");
      if (first_failure != null)
        disable event_flow;
      event_result = null;
      fixture.engine.poll_ceqe(
        fixture.ceq.handle, 0, event_result, step);
      retain_failure("real CEQE poll", step, first_failure);
      polled_ceqe = null;
      if (first_failure != null || event_result == null ||
          event_result.queue_h == null ||
          !event_result.queue_h.same_instance(fixture.ceq.handle) ||
          !$cast(polled_ceqe, event_result.event_model) ||
          polled_ceqe.cq_h == null ||
          !polled_ceqe.cq_h.same_instance(fixture.cq.handle) ||
          polled_ceqe.cqn != fixture.cq.local_cq_id ||
          polled_ceqe.qpn != event_qp.local_qp_id ||
          event_result.event_status == null ||
          !event_result.event_status.ok()) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "real CEQE poll route mismatch");
        disable event_flow;
      end
      step = check_runtime_drained(
        fixture, fixture.ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, 1, 1'b0);
      retain_failure("real CEQ drain", step, first_failure);
      if (first_failure != null)
        disable event_flow;
      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, step);
      retain_failure("real event CQE poll", step, first_failure);
      if (first_failure != null || completion == null ||
          completion.cqe == null || completion.cqe.wr_id != send_request.wr_id) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "real event CQE did not release WQE owner");
        disable event_flow;
      end
      step = check_runtime_drained(
        fixture, fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, 1, 1'b0);
      retain_failure("real event CQ drain", step, first_failure);
      if (first_failure != null)
        disable event_flow;

      // 中文设计：AEQE 使用同一已 attach QP 的 detached handle
      // 和 qpn，使 poll 后可同时验证 target owner、16B bytes 与 event credit。
      step = fixture.engine.query_runtime_producer_polarity(
        fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
      retain_failure("real AEQ polarity", step, first_failure);
      if (first_failure != null)
        disable event_flow;
      aeqe = rdma_hw_aeqe_model::type_id::create("real_aeqe");
      if (aeqe == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED, "real AEQE allocation failed");
        disable event_flow;
      end
      aeqe.target_h = rdma_clone_handle_value(
        event_qp.handle, "real AEQE target");
      aeqe.qpn = event_qp.local_qp_id;
      aeqe.valid = polarity;
      aeqe.ecode = 0;
      aeqe.packet_opcode = 0;
      published = null;
      fixture.engine.publish_aeqe(fixture.aeq.handle, aeqe, published, step);
      retain_failure("real AEQE publish", step, first_failure);
      if (first_failure != null || published == null ||
          published.image == null || published.image.length != 16) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "real AEQE publish result is incomplete");
        disable event_flow;
      end
      step = read_real_queue_entry(
        fixture, fixture.aeq, RDMA_QUEUE_ROLE_AEQ_RING,
        longint'(published.index) * 16, 16, actual);
      retain_failure("real AEQE read", step, first_failure);
      if (first_failure == null &&
          !published_bytes_match(actual, published.image))
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "real AEQE bytes mismatch");
      if (first_failure != null)
        disable event_flow;
      event_result = null;
      fixture.engine.poll_aeqe(
        fixture.aeq.handle, 0, event_result, step);
      retain_failure("real AEQE poll", step, first_failure);
      polled_aeqe = null;
      if (first_failure != null || event_result == null ||
          event_result.queue_h == null ||
          !event_result.queue_h.same_instance(fixture.aeq.handle) ||
          !$cast(polled_aeqe, event_result.event_model) ||
          polled_aeqe.target_h == null ||
          !polled_aeqe.target_h.same_instance(event_qp.handle) ||
          polled_aeqe.qpn != event_qp.local_qp_id ||
          event_result.event_status == null ||
          !event_result.event_status.ok()) begin
        if (first_failure == null)
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "real AEQE poll owner mismatch");
        disable event_flow;
      end
      step = check_runtime_drained(
        fixture, fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, 1, 1'b0);
      retain_failure("real AEQ drain", step, first_failure);
      if (first_failure != null)
        disable event_flow;
      `uvm_info("REAL_EVENT_SAMPLE",
                "CEQE/AEQE each published and polled as 16-byte real entries",
                UVM_LOW)
    end

    // 中文设计：事件 QP 是 Task-10-local lifecycle owner，必须在基础
    // fixture 的 CQ/PD 前 detach/destroy；其后仍只委托一次 accepted cleanup。
    if (fixture != null && event_qp != null) begin
      fixture.destroy_lifecycle_owned_qp(
        event_qp.handle, 1'b1, event_qp_attached, 64'hbe01, cleanup_status);
      retain_failure("real event QP cleanup", cleanup_status, first_failure);
    end
    cleanup_fixture(fixture, cleanup_status);
    retain_failure("real event fixture cleanup", cleanup_status,
                   first_failure);
    status = first_failure == null ? rdma_status::success() : first_failure;
  endtask

  // 功能：test_direct_proxy_opaque_release 用真实 pinned allocation 验证
  //   proxy 在 public mapping geometry 被篡改时仍按 opaque identity 释放 backing。
  // 输入/输出及副作用：proxy 借用顶层 real adapter；status 入口先置成功
  //   安全值，尾部返回首个 setup/allocate/release/cleanup 错误；成功路径只释放
  //   一次 isolated mapping。
  // 失败/边界：proxy/delegate/fixture/backing 缺失时返回 INVALID_STATE；
  //   proxy 拒绝时直接用 delegate.release_opaque 恢复清理，保留原错且不 double-free。
  task automatic test_direct_proxy_opaque_release(
    rdma_real_host_mem_proxy proxy,
    output rdma_status status
  );
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_backing_ref backing;
    rdma_dma_request_context request_context;
    rdma_dma_mapping mapping;
    rdma_status first_failure;
    rdma_status step;
    rdma_status cleanup_status;

    status = rdma_status::success();
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "opaque_release_fixture");
    first_failure = null;
    begin : opaque_flow
      if (proxy == null || proxy.delegate == null || fixture == null) begin
        first_failure = rdma_status::make(
          RDMA_SC_INVALID_STATE, "opaque release fixture is unavailable");
        disable opaque_flow;
      end
      fixture.mem = proxy;
      fixture.setup(step, 16, 64, 16, 16);
      if (step == null || !step.ok()) begin
        first_failure = step == null ? rdma_status::make(
          RDMA_SC_INVALID_STATE, "opaque release setup returned null status") :
          step;
      end
      if (first_failure == null) begin
        backing = null;
        foreach (fixture.cq.queue_plan.refs[i]) begin
          if (fixture.cq.queue_plan.refs[i] != null &&
              fixture.cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
            backing = fixture.cq.queue_plan.refs[i];
        end
        if (backing == null || backing.mapping == null) begin
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE, "opaque release source mapping is missing");
        end
      end
      if (first_failure == null) begin
        request_context = rdma_dma_request_context::type_id::create(
          "opaque_release_context");
        request_context.function_h = rdma_clone_function_handle_value(
          backing.mapping.function_h, "opaque release Function");
        request_context.requester_bdf = backing.mapping.requester_bdf;
        request_context.pasid_valid = backing.mapping.pasid_valid;
        request_context.pasid = backing.mapping.pasid;
        request_context.dma_domain_valid = backing.mapping.dma_domain_valid;
        request_context.dma_domain_id = backing.mapping.dma_domain_id;
        request_context.route = backing.mapping.route;
        request_context.route_valid = backing.mapping.route_valid;
        request_context.reset_epoch = backing.mapping.reset_epoch;
        request_context.epoch_valid = backing.mapping.epoch_valid;
        request_context.owner_h = rdma_clone_handle_value(
          backing.mapping.owner_h, "opaque release owner");
        step = proxy.allocate(request_context, 4096, 4096,
                              RDMA_DMA_DEVICE_WRITE, mapping);
        if (step == null || !step.ok() || mapping == null)
          first_failure = step == null || step.ok() ? rdma_status::make(
            RDMA_SC_INVALID_STATE, "isolated allocation returned no mapping") :
            step;
      end
      if (first_failure == null) begin
        // 中文设计：只篡改 public size，使 strict release 必然拒绝；
        // opaque release 必须仍依赖 adapter 内部 allocation identity 完成释放。
        mapping.size++;
        step = proxy.\release (mapping);
        if (step == null || step.code != RDMA_SC_DMA_TRANSLATION) begin
          first_failure = rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "strict release did not reject modified public geometry");
          if (step == null || !step.ok()) begin
            cleanup_status = proxy.delegate.release_opaque(mapping);
            if (cleanup_status != null && cleanup_status.ok())
              proxy.active_mappings.delete(mapping.iova.value);
            else
              `uvm_error("STRICT_RECOVERY",
                         "unexpected strict rejection could not be recovered")
          end
        end
        else begin
          step = proxy.release_opaque(mapping);
          if (step == null || !step.ok()) begin
            first_failure = step == null ? rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "proxy opaque release returned null status") : step;
            cleanup_status = proxy.delegate.release_opaque(mapping);
            if (cleanup_status != null && cleanup_status.ok())
              proxy.active_mappings.delete(mapping.iova.value);
            else
              `uvm_error("OPAQUE_RECOVERY",
                         "direct adapter opaque recovery release failed")
          end
        end
      end
    end
    if (fixture != null)
      cleanup_fixture(fixture, cleanup_status);
    else
      cleanup_status = rdma_status::success();
    if ((cleanup_status == null || !cleanup_status.ok()) &&
        first_failure == null)
      first_failure = cleanup_status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "opaque fixture cleanup returned null status") :
        cleanup_status;
    status = first_failure == null ? rdma_status::success() : first_failure;
  endtask

  // 功能：test_real_host_mem_device_publish_and_release 建立单一真实 host_mem
  //   manager/adapter/proxy 生命周期，依次验证畸形后端输出、partial-create
  //   canonical cleanup、opaque release、三种 segmented CQ stride、CEQE/AEQE
  //   与最终零活动分配。
  // 输入/输出及副作用：无显式输入/输出；task 创建并借用一个外部
  //   manager，通过 UVM report 发布行为和数字泄漏断言。
  // 失败/边界：任一状态为 null/non-OK 或 leak_count 非零时报错；
  //   泄漏检查只在 isolated mapping 与 fixture 均已清理后执行。
  task automatic test_real_host_mem_device_publish_and_release();
    int unsigned profiles[3] = '{32, 64, 128};
    rdma_host_mem_external_pkg::host_mem_manager host_manager;
    rdma_fault_host_mem_adapter real_adapter;
    rdma_real_host_mem_proxy proxy;
    rdma_status status;
    int unsigned leak_count;

    host_manager = rdma_host_mem_external_pkg::host_mem_manager::type_id::create(
      "real_publish_host_manager");
    host_manager.init_region(64'h0000_0008_0000_0000,
                             64'h0000_0008_00ff_ffff);
    real_adapter = rdma_fault_host_mem_adapter::type_id::create(
      "real_publish_adapter");
    real_adapter.mem = host_manager;
    real_adapter.iova_base = 64'h0000_0010_0000_0000;
    proxy = rdma_real_host_mem_proxy::type_id::create("real_publish_proxy");
    proxy.delegate = real_adapter;

    test_proxy_failure_output_contracts(proxy, real_adapter, status);
    if (status == null || !status.ok())
      `uvm_error("PROXY_OUTPUT", status == null ? "null status" :
                 status.convert2string())
    test_partial_create_cleanup_contract(proxy, status);
    if (status == null || !status.ok())
      `uvm_error("PARTIAL_CREATE", status == null ? "null status" :
                 status.convert2string())
    test_direct_proxy_opaque_release(proxy, status);
    if (status == null || !status.ok())
      `uvm_error("OPAQUE_RELEASE", status == null ? "null status" :
                 status.convert2string())
    foreach (profiles[i]) begin
      run_real_cq_profile(profiles[i], proxy, status);
      if (status == null || !status.ok())
        `uvm_error("REAL_PROFILE", status == null ? "null status" :
                   $sformatf("stride=%0d %s", profiles[i],
                             status.convert2string()))
    end
    run_real_event_profiles(proxy, status);
    if (status == null || !status.ok())
      `uvm_error("REAL_EVENT", status == null ? "null status" :
                 status.convert2string())

    // 中文设计：数字 leak_count 是主权断言；manager 的
    // "0 blocks outstanding" 日志只作为外部 allocator 一致的辅助证据。
    status = real_adapter.check_leaks(leak_count);
    if (status == null || !status.ok() || leak_count != 0)
      `uvm_error("HOST_MEM_LEAK", status == null ? "null status" :
                 $sformatf("%s leaks=%0d", status.convert2string(),
                           leak_count))
  endtask

  // 功能：run_phase 在 UVM run 阶段执行真实 host_mem 测试并成对管理
  //   objection，不在阶段层复制任何 fixture 设置或清理逻辑。
  // 输入/输出及副作用：phase 为 UVM 输入；task 提起/放下 objection，
  //   调用顶层测试 task 并将结果以 UVM report 对外可见。
  // 失败/边界：子场景失败也必须到达 drop_objection；本 task 不使用
  //   return 跳过 UVM 收尾，不接管外部 manager 的生命周期。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_real_host_mem_device_publish_and_release();

    phase.drop_objection(this);
  endtask
endclass
