// 目录：核心执行层 core/rdma_queue_facade_configuration.sv。
// 职责：集中实现 CQ/SQ/RQ/EQ facade 共用的配置 admission 校验，统一依赖一致性、
//   Function binding 状态和失败优先级；各 facade 仍负责 one-shot 状态写入。
// 主要依赖：rdma_queue_data_engine、rdma_function_binding、rdma_status 及核心
//   adapter/codec 类型；本文件只读取传入对象，不访问 queue runtime 或外部资源。
// 所有权与生命周期：helper 不保存输入引用、不接管任何依赖所有权；成功返回后，
//   调用 facade 才保存 shared_engine/binding 的非拥有引用并负责自身配置生命周期。

// 设计说明：CQ、SQ、RQ、EQ 的普通 configure() 必须在保存 delegate 前验证同一组 manager、
// binding、Host-memory、doorbell、codec registry，并拒绝非 ACTIVE binding。把纯
// admission 阶段集中到 core package，可避免三个 facade 的错误优先级和消息前缀漂移；
// configured 门禁及 authority 快照写入仍留在调用方，以保持各 facade 的状态所有权。

// 功能：rdma_validate_queue_facade_configuration 检查队列 facade 配置所需的依赖
//       是否完整且与 shared_engine 指向同一组对象，再验证 Function binding 可用。
// 输入/输出及副作用：resource_manager、function_binding、memory、scheduler、codecs、
//       timeout 和 shared_engine 为待登记输入，label 用于错误消息前缀；函数只读
//       这些对象并返回 rdma_status，不修改 facade、delegate、binding 或任何资源。
// 失败/边界：任一依赖为空、timeout 为零、shared_engine 的五个依赖不完全匹配时
//       返回 INVALID_ARGUMENT；binding.validate() 返回 null 时返回 INVALID_STATE，
//       非空失败状态原样透传；binding 非 ACTIVE 时返回 INVALID_STATE；全部通过时
//       返回 success，调用方仍必须自行执行 configured/one-shot 门禁后再保存引用。
function automatic rdma_status rdma_validate_queue_facade_configuration(
  input rdma_resource_manager resource_manager,
  input rdma_function_binding function_binding,
  input rdma_host_mem_api memory,
  input rdma_doorbell_scheduler scheduler,
  input rdma_codec_registry codecs,
  input time timeout,
  input rdma_queue_data_engine shared_engine,
  input string label
);
  rdma_status status;

  if (resource_manager == null || function_binding == null || memory == null ||
      scheduler == null || codecs == null || timeout == 0 || shared_engine == null)
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      {label, " facade configuration dependency is null/zero"});

  if (shared_engine.manager != resource_manager ||
      shared_engine.binding != function_binding ||
      shared_engine.host_mem != memory ||
      shared_engine.doorbells != scheduler ||
      shared_engine.registry != codecs)
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      {label, " facade dependencies do not match shared engine"});

  status = rdma_status::nonnull(
    function_binding.validate(),
    {label, " Function binding validation returned null"}
  );
  if (!status.ok())
    return status;
  if (function_binding.state != RDMA_BIND_ACTIVE)
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      {label, " Function binding is not ACTIVE"});
  return rdma_status::success();
endfunction

// 设计说明：SQ/RQ/EQ/CQ facade 共享同一份“借用 delegate + 冻结 Function incarnation”
//   状态与 one-shot configure 契约；集中到基类后，各 facade 只保留自己的业务入口。
//   基类不注册 UVM factory，具体 facade 仍各自 `uvm_object_utils。
class rdma_queue_facade extends uvm_object;
  protected rdma_queue_data_engine delegate;
  // facade 借用 binding，并冻结配置时的 Function UID/generation/reset epoch；不持有
  //   binding 生命周期，业务入口前只用它检测 reset 或重绑。
  protected rdma_function_binding authority_binding;
  protected longint unsigned authority_function_uid;
  protected int unsigned authority_generation;
  protected rdma_reset_epoch_t authority_reset_epoch;
  protected time operation_timeout;
  protected bit configured;
  protected string facade_label;

  // 功能：构造未配置的 facade；label（SQ/RQ/EQ/CQ）用作全部诊断消息前缀。
  // 输入/输出及副作用：只写默认字段，不分配队列或接管外部资源。
  // 失败/边界：configure 前所有业务入口都返回 INVALID_STATE。
  function new(string name = "rdma_queue_facade", string label = "queue");
    super.new(name);
    facade_label = label;
    delegate = null;
    authority_binding = null;
    authority_function_uid = 0;
    authority_generation = 0;
    authority_reset_epoch = 0;
    operation_timeout = 0;
    configured = 1'b0;
  endfunction

  // 功能：校验冻结的 Function UID/generation/reset epoch 与借用 binding 仍一致，
  //   且 binding 仍为 ACTIVE 并通过自身 validate()。
  // 输入/输出及副作用：label 仅用于诊断；只读配置与 binding，返回 rdma_status。
  // 失败/边界：未配置/缺依赖/binding 非 ACTIVE 返回 INVALID_STATE；任一冻结坐标漂移
  //   返回 STALE_GENERATION。
  protected function rdma_status validate_live_authority(string label);
    return rdma_validate_live_authority(
      configured,
      delegate != null,
      authority_binding,
      authority_function_uid,
      authority_generation,
      authority_reset_epoch,
      label);
  endfunction

  // 功能：子类在 one-shot 门禁之后、保存引用之前追加的配置准入钩子。
  // 输入/输出及副作用：shared_engine 为待保存的 delegate；默认无额外条件。
  // 失败/边界：返回非 OK 时 configure 原样返回且不写任何字段。
  protected virtual function rdma_status configure_admission(
    rdma_queue_data_engine shared_engine
  );
    return rdma_status::success();
  endfunction

  // 功能：一次性绑定共享 queue-data engine，并冻结 binding 的 Function incarnation。
  // 输入/输出及副作用：依赖须与 shared_engine 持有的完全一致；成功时保存 delegate、
  //   binding 与 timeout 的非拥有引用并置 configured。
  // 失败/边界：依赖不一致/binding 非 ACTIVE 等沿用共用 admission 错误；已配置返回
  //   INVALID_STATE（在完整校验之后判定，非法重配仍报具体错误）；失败不改旧配置。
  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_function_binding function_binding,
    rdma_host_mem_api memory,
    rdma_doorbell_scheduler scheduler,
    rdma_codec_registry codecs,
    time timeout,
    rdma_queue_data_engine shared_engine = null
  );
    rdma_status status;

    status = rdma_validate_queue_facade_configuration(
      resource_manager, function_binding, memory, scheduler, codecs, timeout,
      shared_engine, facade_label);
    if (status == null || !status.ok())
      return status;
    if (configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {facade_label, " facade is already configured"});
    status = configure_admission(shared_engine);
    if (!status.ok())
      return status;
    delegate = shared_engine;
    authority_binding = function_binding;
    authority_function_uid = function_binding.function_uid;
    authority_generation = function_binding.generation;
    authority_reset_epoch = function_binding.function_reset_epoch();
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：业务入口统一前置门禁：已配置且 delegate 存在，并通过 live authority 校验。
  // 输入/输出及副作用：label 为入口诊断前缀；只读，返回非 null status。
  // 失败/边界：未配置返回 INVALID_STATE；authority 校验返回 null 时按 label 归一化。
  protected function rdma_status validate_operation_authority(string label);
    if (!configured || delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {facade_label, " facade is not configured"});
    return rdma_status::nonnull(validate_live_authority(label),
                                {label, " authority validation returned null"});
  endfunction

  // 功能：把 delegate 返回的 null status 归一化为带 facade/入口名的 INVALID_STATE。
  // 输入/输出及副作用：非 null 时原样返回同一对象；不修改 result 或队列状态。
  // 失败/边界：result 是否清空由调用方按返回状态决定。
  protected function rdma_status normalize_delegate_status(
    rdma_status candidate,
    string operation_name
  );
    return rdma_status::nonnull(
      candidate,
      {facade_label, " delegate ", operation_name, " returned null status"});
  endfunction
endclass
