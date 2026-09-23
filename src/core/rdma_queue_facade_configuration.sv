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

  status = function_binding.validate();
  if (status == null)
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      {label, " Function binding validation returned null"});
  if (!status.ok())
    return status;
  if (function_binding.state != RDMA_BIND_ACTIVE)
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      {label, " Function binding is not ACTIVE"});
  return rdma_status::success();
endfunction
