// 目录：测试层 tests/integration/。
// 职责：在真实 host_mem 与 net_packet 适配器上验证 RC/UD/URC 传输矩阵。
// 依赖：复用 rdma_end_to_end_dual_env_test 的双 Function fixture、queue-data
//   engine、host-memory adapter 与 net_packet sink；并为每个 Function 装配一个
//   rdma_env 组合对象，验证组合层与数据面使用同一份 identity/binding 快照。
// 所有权与生命周期：测试拥有本地 fixture 和 mapping；组合 engine 只借用
//   fixture 的 CQ/QP，清理时先撤销其 attachment，再由基类 cleanup_env 按
//   mapping→QP/CQ/CEQ/AEQ→PD→Function 释放并执行最终 leak check。

// 中文设计说明：传输矩阵共用一套已隔离的 TX/RX Function，按独立 WR ID
// 顺序推进 SQ/RQ/CQ ring。UD 只允许 SEND，RC 支持 SEND/WRITE/READ/ATOMIC，
// URC（RoCEv2 UC wire profile）支持 SEND/WRITE；网络字段和 queue WQE 字段分别断言，避免把
// “报文成功”误当成“队列提交成功”。
import rdma_unit_test_pkg::*;
import rdma_types_pkg::*;
import rdma_model_pkg::*;
import rdma_core_pkg::*;
import rdma_adapter_pkg::*;
import host_mem_pkg::*;
import rdma_host_mem_adapter_pkg::*;
import rdma_net_packet_adapter_pkg::*;
import rdma_net_packet_bridge_pkg::*;
import uvm_pkg::*;
`include "uvm_macros.svh"

class rdma_end_to_end_transport_test extends rdma_end_to_end_dual_env_test;
  `uvm_component_utils(rdma_end_to_end_transport_test)

  localparam int unsigned TRANSPORT_CASES = 8;
  // 额外回放一整圈再多一个事务，确保 SQ/RQ/CQ 的 wrap 翻转不是仅由
  // 单个 posted 结果字段“看起来正确”，而是在真实 ring 深度上发生过。
  localparam int unsigned WRAP_REPLAY_CASES = CQ_DEPTH + 1;
  localparam time COMPLETION_TIMEOUT = 1us;
  int unsigned case_counter;
  int unsigned tx_cq_slot;
  int unsigned rx_cq_slot;
  rdma_env tx_composition_env;
  rdma_env rx_composition_env;
  rdma_env_config tx_composition_cfg;
  rdma_env_config rx_composition_cfg;
  bit tx_composition_cq_attached;
  bit tx_composition_rc_attached;
  bit tx_composition_ud_attached;
  bit tx_composition_urc_attached;
  bit rx_composition_cq_attached;
  bit rx_composition_rc_attached;
  bit rx_composition_ud_attached;
  bit rx_composition_urc_attached;

  // 功能：构造 transport E2E 测试并清零事务计数器。
  // 输入/输出及副作用：name、parent（输入）；调用父类构造，不取得外部资源。
  // 失败/边界：构造只建立 UVM 对象；真实依赖必须由 run_phase 配置完成。
  function new(string name = "rdma_end_to_end_transport_test",
               uvm_component parent = null);
    super.new(name, parent);
    case_counter = 0;
    tx_cq_slot = 0;
    rx_cq_slot = 0;
    tx_composition_env = null;
    rx_composition_env = null;
    tx_composition_cfg = null;
    rx_composition_cfg = null;
    tx_composition_cq_attached = 1'b0;
    tx_composition_rc_attached = 1'b0;
    tx_composition_ud_attached = 1'b0;
    tx_composition_urc_attached = 1'b0;
    rx_composition_cq_attached = 1'b0;
    rx_composition_rc_attached = 1'b0;
    rx_composition_ud_attached = 1'b0;
    rx_composition_urc_attached = 1'b0;
  endfunction

  // 功能：在 UVM build 阶段创建两个纯组合 rdma_env，并注入已启用但可选的
  // host-mem/net 能力配置；真实 adapter 句柄在 run_phase 的 fixture setup
  // 完成后再绑定，避免组合层提前取得外部资源所有权。
  // 输入/输出及副作用：phase（输入）；创建 env/config 子组件并写入 config_db，
  //   不创建 pcie_env/axis_env，也不分配 host-memory 或 queue backing。
  // 失败/边界：配置保持无 required adapter 的 HYBRID 模式；若后续 fixture
  //   无法提供真实 adapter，configure_composition_envs 必须显式失败。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    tx_composition_cfg = rdma_env_config::type_id::create("tx_composition_cfg");
    rx_composition_cfg = rdma_env_config::type_id::create("rx_composition_cfg");
    tx_composition_cfg.mode = RDMA_ENV_HYBRID;
    rx_composition_cfg.mode = RDMA_ENV_HYBRID;
    tx_composition_cfg.host_mem_enabled = 1'b1;
    rx_composition_cfg.host_mem_enabled = 1'b1;
    tx_composition_cfg.net_enabled = 1'b1;
    rx_composition_cfg.net_enabled = 1'b1;
    tx_composition_env = rdma_env::type_id::create("tx_composition_env", this);
    rx_composition_env = rdma_env::type_id::create("rx_composition_env", this);
    uvm_config_db#(rdma_env_config)::set(
      this, "tx_composition_env", "cfg", tx_composition_cfg);
    uvm_config_db#(rdma_env_config)::set(
      this, "rx_composition_env", "cfg", rx_composition_cfg);
  endfunction

  // 功能：把双 fixture 的真实 host-mem/net adapter、CQC context shadow 和
  //   Function 快照接入 rdma_env 组合对象，并重新冻结一次配置，使组合层成为
  //   本轮数据面 authority。
  // 输入/输出及副作用：无显式输入；更新两个 cfg/env 的快照、借用 adapter 句柄
  //   与 context backing 引用，成功时不修改 fixture、host-memory mapping 或网络统计。
  // 失败/边界：fixture identity/binding/context backing 缺失、配置校验失败或
  //   组合对象为空时返回明确错误；任一路径均不得发布半成品组合状态，且 CQ poll
  //   不得在缺少 CQC shadow backing 时退回 legacy consumer doorbell。
  task automatic configure_composition_envs(output rdma_status status);
    rdma_function_identity tx_identity;
    rdma_function_identity rx_identity;

    status = rdma_status::success();
    // 每个 Function 的基础 fixture 先建立 RC QP；传输矩阵再显式创建
    // 匹配的 UD/URC QP，后续 request 不得跨 profile 借用 RC 句柄。
    tx_env.setup_transport_qps(status);
    if (status == null || !status.ok()) begin
      if (status != null) status.message = {"TX transport QP setup: ", status.message};
      return;
    end
    rx_env.setup_transport_qps(status);
    if (status == null || !status.ok()) begin
      if (status != null) status.message = {"RX transport QP setup: ", status.message};
      return;
    end
    if (tx_composition_env == null || rx_composition_env == null ||
        tx_composition_cfg == null || rx_composition_cfg == null)
      begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "rdma_env composition objects are missing");
        return;
      end
    tx_identity = tx_env.binding.function_identity_snapshot();
    rx_identity = rx_env.binding.function_identity_snapshot();
    if (tx_identity == null || rx_identity == null || tx_env.binding == null ||
        rx_env.binding == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "fixture Function identity/binding is missing");
      return;
    end
    tx_composition_cfg.function_identity = tx_identity;
    rx_composition_cfg.function_identity = rx_identity;
    tx_composition_cfg.function_binding = tx_env.binding;
    rx_composition_cfg.function_binding = rx_env.binding;
    tx_composition_env.host_mem = tx_host_adapter;
    rx_composition_env.host_mem = rx_host_adapter;
    tx_composition_env.net = tx_net;
    rx_composition_env.net = rx_net;
    status = tx_composition_env.configure(tx_composition_cfg);
    if (status == null || !status.ok()) return;
    status = rx_composition_env.configure(rx_composition_cfg);
    if (status == null || !status.ok()) return;
    // 让组合层自己的 queue-data engine 绑定 fixture 已创建的真实资源；后续
    // sequence 只通过 rdma_env 语义入口提交/轮询，fixture 仅创建并持有
    // lifecycle 资源，正向 CQE 必须由组合 engine 的公开 publish 路径生成。
    status = tx_composition_env.bind_data_path(
      tx_env.manager, tx_env.binding, tx_env.mem, tx_env.scheduler,
      tx_env.registry, 2us, tx_env.contexts);
    if (status == null || !status.ok()) return;
    status = rx_composition_env.bind_data_path(
      rx_env.manager, rx_env.binding, rx_env.mem, rx_env.scheduler,
      rx_env.registry, 2us, rx_env.contexts);
    if (status == null || !status.ok()) return;
    status = tx_composition_env.queue_data.attach_cq(
      tx_env.cq.handle, RDMA_TRANSPORT_RC);
    if (status == null || !status.ok()) return;
    tx_composition_cq_attached = 1'b1;
    status = tx_composition_env.queue_data.attach_qp(tx_env.qp.handle);
    if (status == null || !status.ok()) return;
    tx_composition_rc_attached = 1'b1;
    status = tx_composition_env.queue_data.attach_qp(tx_env.ud_qp.handle);
    if (status == null || !status.ok()) return;
    tx_composition_ud_attached = 1'b1;
    status = tx_composition_env.queue_data.attach_qp(tx_env.urc_qp.handle);
    if (status == null || !status.ok()) return;
    tx_composition_urc_attached = 1'b1;
    status = rx_composition_env.queue_data.attach_cq(
      rx_env.cq.handle, RDMA_TRANSPORT_RC);
    if (status == null || !status.ok()) return;
    rx_composition_cq_attached = 1'b1;
    status = rx_composition_env.queue_data.attach_qp(rx_env.qp.handle);
    if (status == null || !status.ok()) return;
    rx_composition_rc_attached = 1'b1;
    status = rx_composition_env.queue_data.attach_qp(rx_env.ud_qp.handle);
    if (status == null || !status.ok()) return;
    rx_composition_ud_attached = 1'b1;
    status = rx_composition_env.queue_data.attach_qp(rx_env.urc_qp.handle);
    if (status == null || !status.ok()) return;
    rx_composition_urc_attached = 1'b1;
    if (tx_composition_env.function_identity_snapshot == null ||
        rx_composition_env.function_identity_snapshot == null ||
        !tx_composition_env.function_identity_snapshot.same_incarnation(tx_identity) ||
        !rx_composition_env.function_identity_snapshot.same_incarnation(rx_identity))
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "rdma_env Function snapshot mismatch");
  endtask

  // 功能：detach_composition_resource 撤销一个由 composition queue-data engine
  //   借用的 CQ/QP attachment，并同步清除调用方记录的 attached 标志。
  // 输入/输出及副作用：env、resource_h、label 为输入，attached 与 first_failure
  //   为 inout；成功只删除 composition 本地 runtime/route，不释放 manager resource。
  // 失败/边界：未 attach 时幂等返回；env/engine/handle 缺失或 detach 拒绝时保留
  //   attached 并记录首错，调用方仍须继续撤销其它独立 attachment。
  task automatic detach_composition_resource(
    input rdma_env env,
    input rdma_handle resource_h,
    input string label,
    inout bit attached,
    inout rdma_status first_failure
  );
    rdma_status stage_status;

    if (!attached) return;
    stage_status = env == null || env.queue_data == null || resource_h == null ?
      null : env.queue_data.detach(resource_h);
    if (stage_status == null)
      stage_status = rdma_status::make(
        RDMA_SC_INVALID_STATE, {label, " detach returned null status"});
    else if (!stage_status.ok())
      stage_status = rdma_status::make(
        stage_status.code, {label, " detach: ", stage_status.message});
    if (!stage_status.ok() && first_failure == null)
      first_failure = stage_status;
    if (stage_status.ok()) attached = 1'b0;
  endtask

  // 功能：cleanup_composition_data_paths 在 lifecycle fixture 销毁前撤销 TX/RX
  //   composition engine 对 URC/UD/RC QP 和 CQ 的全部非拥有引用。
  // 输入/输出及副作用：status 为输出；按每端 QP→CQ 顺序调用 detach 并保留首错，
  //   不释放 queue backing、payload mapping 或 Function 资源。
  // 失败/边界：支持 partial configure 与重复 cleanup；单项失败不阻断后续端点，
  //   失败 attachment 标志保持为一，便于诊断或显式重试。
  task automatic cleanup_composition_data_paths(output rdma_status status);
    rdma_status first_failure;

    first_failure = null;
    detach_composition_resource(
      tx_composition_env, tx_env == null || tx_env.urc_qp == null ? null :
      tx_env.urc_qp.handle, "TX URC QP", tx_composition_urc_attached,
      first_failure);
    detach_composition_resource(
      tx_composition_env, tx_env == null || tx_env.ud_qp == null ? null :
      tx_env.ud_qp.handle, "TX UD QP", tx_composition_ud_attached,
      first_failure);
    detach_composition_resource(
      tx_composition_env, tx_env == null || tx_env.qp == null ? null :
      tx_env.qp.handle, "TX RC QP", tx_composition_rc_attached,
      first_failure);
    detach_composition_resource(
      tx_composition_env, tx_env == null || tx_env.cq == null ? null :
      tx_env.cq.handle, "TX CQ", tx_composition_cq_attached, first_failure);
    detach_composition_resource(
      rx_composition_env, rx_env == null || rx_env.urc_qp == null ? null :
      rx_env.urc_qp.handle, "RX URC QP", rx_composition_urc_attached,
      first_failure);
    detach_composition_resource(
      rx_composition_env, rx_env == null || rx_env.ud_qp == null ? null :
      rx_env.ud_qp.handle, "RX UD QP", rx_composition_ud_attached,
      first_failure);
    detach_composition_resource(
      rx_composition_env, rx_env == null || rx_env.qp == null ? null :
      rx_env.qp.handle, "RX RC QP", rx_composition_rc_attached,
      first_failure);
    detach_composition_resource(
      rx_composition_env, rx_env == null || rx_env.cq == null ? null :
      rx_env.cq.handle, "RX CQ", rx_composition_cq_attached, first_failure);
    status = first_failure == null ? rdma_status::success() : first_failure;
  endtask

  // 功能：按 transport 选择发送端 fixture 中已创建的匹配 QP。
  // 输入/输出及副作用：transport 为输入；返回非拥有 QP 引用，不修改任何
  // runtime、manager 或 adapter 状态。
  // 失败/边界：fixture 未配置或 transport 无对应 QP 时返回 null，调用方必须
  // 在提交前报告 setup 错误，不能回退到 RC QP。
  function automatic rdma_qp tx_qp_for_transport(rdma_transport_e transport);
    if (tx_env == null)
      return null;
    return tx_env.get_qp_for_transport(transport);
  endfunction

  // 功能：按 transport 选择接收端 fixture 中已创建的匹配 QP。
  // 输入/输出及副作用：transport 为输入；返回非拥有 QP 引用，不修改任何
  // runtime、manager 或 adapter 状态。
  // 失败/边界：fixture 未配置或 transport 无对应 QP 时返回 null，调用方必须
  // 在提交前报告 setup 错误，不能回退到 RC QP。
  function automatic rdma_qp rx_qp_for_transport(rdma_transport_e transport);
    if (rx_env == null)
      return null;
    return rx_env.get_qp_for_transport(transport);
  endfunction

  // 功能：将一次网络事务登记到指定 rdma_env 的 Function-qualified event 路由，
  //   让组合层 pending 账本与 SQ/RQ 事务一一对应。
  // 输入/输出及副作用：env、identity、vector（输入）；成功时 env pending_count
  //   加一；不修改 queue cursor 或 adapter 统计。
  // 失败/边界：identity/env 为空、代际不一致或裸 vector 均返回错误且不递增计数。
  task automatic route_composition_event(
    rdma_env env,
    rdma_function_identity identity,
    int unsigned vector,
    output rdma_status status
  );
    rdma_env_event_route event_route;

    status = rdma_status::success();
    if (env == null || identity == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "composition event authority is missing");
      return;
    end
    event_route = rdma_env_event_route::type_id::create(
      $sformatf("transport_event_%0d", vector));
    event_route.target_function = identity;
    event_route.vector = vector;
    event_route.generation = identity.generation;
    status = env.route_event(event_route);
  endtask

  // 功能：在异常提前退出时回收组合层仍挂起的事件计数，避免测试清理阶段
  //   把一次失败事务永久留在 rdma_env scoreboard 账本中。
  // 输入/输出及副作用：无显式输入；只递减本测试创建的两个 env 的 pending_count，
  //   不释放 queue/host-memory/net 资源。
  // 失败/边界：计数为零时幂等返回；rdma_env 为空时跳过对应端并由调用方记录 setup 错误。
  task automatic drain_composition_pending();
    if (tx_composition_env != null)
      while (tx_composition_env.pending_count() != 0)
        tx_composition_env.end_pending();
    if (rx_composition_env != null)
      while (rx_composition_env.pending_count() != 0)
        rx_composition_env.end_pending();
  endtask

  // 功能：为指定传输和 opcode 构造语义发送请求，绑定 TX QP 与真实 payload
  //   mapping，并补齐 UD 地址向量或 URC completion-QP 约束。
  // 输入/输出及副作用：transport、opcode、wr_id（输入）；返回 detached request，
  //   不修改队列游标；请求失败边界由 request.validate() 在 post 前判定。
  // 失败/边界：不支持的组合仍返回请求对象，由 run_transport_case 统一期待
  //   RDMA_SC_UNSUPPORTED_OPCODE；remote 字段仅在 WRITE/READ/ATOMIC 时设置，
  //   其中 URC READ 会被核心能力表拒绝，不进入网络编码。
  function automatic rdma_post_send_req make_transport_request(
    rdma_transport_e transport,
    rdma_work_opcode_e opcode,
    longint unsigned wr_id
  );
    rdma_post_send_req request;
    rdma_sge sge;
    rdma_qp transport_qp;
    rdma_qp receiving_qp;

    transport_qp = tx_env.get_qp_for_transport(transport);
    receiving_qp = rx_env.get_qp_for_transport(transport);
    request = tx_env.make_send(wr_id);
    request.transport = transport;
    request.opcode = opcode;
    request.qp_h = transport_qp == null ? null :
                   rdma_clone_handle_value(transport_qp.handle, "transport QP");
    request.owner = tx_env.binding.make_handle();
    request.sges.delete();
    sge = rdma_sge::type_id::create("transport_sge");
    sge.iova = tx_payload_mapping.iova;
    sge.length = (opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                                 RDMA_WR_ATOMIC_FETCH_ADD}) ? 8 : PAYLOAD_BYTES;
    sge.lkey = 32'hfeed_3000 + case_counter;
    request.sges.push_back(sge);
    request.payload.delete();
    if (opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                       RDMA_WR_SEND_WITH_INV}) begin
      request.payload.push_back(8'h5a);
    end
    if (transport == RDMA_TRANSPORT_UD) begin
      // Fixture manager 不保证给模型 QP 分配非零硬件 QPN；UD DETH
      // 明确要求目的 QPN 非零，因此使用测试拓扑中的稳定逻辑 QPN。
      request.destination_qpn = 24'h000002;
      request.qkey = 32'h8001_0000;
      request.address_vector_valid = 1'b1;
      request.address_vector_id = 32'h100 + case_counter;
      request.address_vector = rdma_address_vector::type_id::create(
        $sformatf("transport_av_%0d", case_counter));
      if (transport_qp != null && transport_qp.qp_plan != null &&
          transport_qp.qp_plan.sq_sgb_ref != null &&
          transport_qp.qp_plan.sq_sgb_ref.mapping != null)
        request.sgb_iova = transport_qp.qp_plan.sq_sgb_ref.mapping.iova.value +
                           transport_qp.qp_plan.sq_sgb_ref.mapping_offset +
                           longint'(transport_qp.sq_producer_index) * 512;
    end
    if (transport == RDMA_TRANSPORT_URC) begin
      request.destination_qpn = receiving_qp == null ||
                                receiving_qp.local_qp_id == 0 ? 24'h000002 :
                                receiving_qp.local_qp_id;
      request.remote_addr = tx_payload_mapping.iova;
      request.rkey = 32'hcafe_0001;
      request.remote_access_valid = 1'b1;
      request.rkey_valid = 1'b1;
      request.completion_qp_h = rdma_clone_handle_value(tx_env.urc_qp.handle,
                                                         "URC completion QP");
    end
    if (opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                       RDMA_WR_RDMA_READ, RDMA_WR_ATOMIC_CMP_SWAP,
                       RDMA_WR_ATOMIC_FETCH_ADD}) begin
      request.remote_addr = rx_payload_mapping.iova;
      request.rkey = 32'hbabe_0002;
      request.remote_access_valid = 1'b1;
      request.rkey_valid = 1'b1;
      request.compare_value = 64'h0102_0304_0506_0708;
      request.swap_add_value = 64'h1112_1314_1516_1718;
    end
    return request;
  endfunction

  // 功能：将语义 request 映射为 net_packet 可编码或可拒绝的
  //   transport/opcode 观察值，并填入 QPN、PSN 和 payload。
  // 输入/输出及副作用：transport、opcode、index、payload（输入）；返回独立
  //   rdma_packet，不推进 sink 或 adapter 统计。
  // 失败/边界：未知组合返回 CUSTOM/NAK 观察值；URC RDMA_READ 仍可构造为
  //   wire-capability negative fixture，但必须由 net_packet adapter 在发送入口拒绝。
  function automatic rdma_packet make_transport_packet(
    rdma_transport_e transport,
    rdma_work_opcode_e opcode,
    int unsigned index,
    byte unsigned payload[$]
  );
    rdma_packet packet;
    rdma_qp tx_qp;
    rdma_qp rx_qp;
    longint unsigned atomic_compare;
    tx_qp = tx_env.get_qp_for_transport(transport);
    rx_qp = rx_env.get_qp_for_transport(transport);
    packet = rdma_packet::type_id::create($sformatf("transport_packet_%0d", index));
    packet.transport = transport;
    packet.source_qpn = tx_qp == null ? 0 : tx_qp.local_qp_id;
    packet.destination_qpn = rx_qp == null ? 0 : rx_qp.local_qp_id;
    if (transport inside {RDMA_TRANSPORT_UD, RDMA_TRANSPORT_URC} &&
        packet.destination_qpn == 0)
      packet.destination_qpn = 24'h000002;
    packet.psn = 24'h100 + index;
    // READ/ATOMIC request 的数据通过 responder response 返回；请求帧自身不
    // 携带 payload，避免把 request 伪装成 write/send。
    if (opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                       RDMA_WR_SEND_WITH_INV, RDMA_WR_RDMA_WRITE,
                       RDMA_WR_WRITE_WITH_IMM})
      packet.payload = payload;
    else
      packet.payload.delete();
    if (opcode inside {RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                       RDMA_WR_RDMA_READ}) begin
      // RETH: remote VA、r_key、DMA length，全部采用网络大端序。
      for (int signed byte_index = 7; byte_index >= 0; byte_index--)
        packet.header_bytes.push_back(
          byte'((rx_payload_mapping.iova.value >> (byte_index * 8)) & 8'hff));
      for (int signed byte_index = 3; byte_index >= 0; byte_index--)
        packet.header_bytes.push_back(byte'((32'hbabe_0002 >>
                                             (byte_index * 8)) & 8'hff));
      for (int signed byte_index = 3; byte_index >= 0; byte_index--)
        packet.header_bytes.push_back(byte'(((opcode == RDMA_WR_RDMA_READ ?
                                              PAYLOAD_BYTES : payload.size()) >>
                                             (byte_index * 8)) & 8'hff));
    end
    if (opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                       RDMA_WR_ATOMIC_FETCH_ADD}) begin
      // 与 make_transport_request 中的 RC 原子语义保持一致：AtomicETH
      //   依次携带远端 VA、r_key、swap/add 和 compare，全部采用网络大端序。
      for (int signed byte_index = 7; byte_index >= 0; byte_index--)
        packet.header_bytes.push_back(
          byte'((rx_payload_mapping.iova.value >> (byte_index * 8)) & 8'hff));
      for (int signed byte_index = 3; byte_index >= 0; byte_index--)
        packet.header_bytes.push_back(byte'((32'hbabe_0002 >>
                                             (byte_index * 8)) & 8'hff));
      for (int signed byte_index = 7; byte_index >= 0; byte_index--)
        packet.header_bytes.push_back(byte'((64'h1112_1314_1516_1718 >>
                                             (byte_index * 8)) & 8'hff));
      atomic_compare = opcode == RDMA_WR_ATOMIC_CMP_SWAP ?
                       64'h0102_0304_0506_0708 : 64'h0;
      for (int signed byte_index = 7; byte_index >= 0; byte_index--)
        packet.header_bytes.push_back(byte'((atomic_compare >>
                                             (byte_index * 8)) & 8'hff));
    end
    case (opcode)
      RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM, RDMA_WR_SEND_WITH_INV:
        packet.opcode = RDMA_NET_SEND;
      RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM:
        packet.opcode = RDMA_NET_RDMA_WRITE;
      RDMA_WR_RDMA_READ:
        packet.opcode = RDMA_NET_RDMA_READ_REQUEST;
      RDMA_WR_ATOMIC_CMP_SWAP:
        packet.opcode = RDMA_NET_ATOMIC_CMP_SWAP;
      RDMA_WR_ATOMIC_FETCH_ADD:
        packet.opcode = RDMA_NET_ATOMIC_FETCH_ADD;
      default:
        // 不支持的语义不得静默降级为 SEND；adapter 应在编码入口拒绝。
        packet.opcode = RDMA_NET_NAK;
    endcase
    return packet;
  endfunction

  // 功能：run_urc_read_wire_rejection 在不触碰 SQ/RQ/CQ 的前提下，把一个
  //   URC RDMA_READ request 交给真实 net_packet adapter，验证 UC wire profile
  //   的 unsupported-opcode 边界只发生在网络编码层。
  // 输入/输出及副作用：status 为输出；本 task 构造独立 rdma_packet 并调用
  //   tx_net.send_packet，读取 tx_net.send_sequence、last_sent_packet 与
  //   tx_sink.sent_count，不创建 pending、推进 queue cursor 或写 host-memory。
  // 失败/边界：adapter/packet/status 为空或返回非 RDMA_SC_UNSUPPORTED_OPCODE 时
  //   失败；send_sequence 是 adapter 的编码尝试计数，拒绝请求允许只增加一次，
  //   但 sink.sent_count 与 last_sent_packet 必须保持同一对象，不能发布半包。
  task automatic run_urc_read_wire_rejection(output rdma_status status);
    byte unsigned payload[$];
    rdma_packet request;
    rdma_status send_status;
    longint unsigned before_sequence;
    int unsigned before_sent_count;
    packet before_last_sent;

    status = rdma_status::success();
    if (tx_net == null || tx_sink == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "URC READ wire rejection adapter or sink is missing");
      return;
    end
    make_payload(case_counter, payload);
    request = make_transport_packet(
      RDMA_TRANSPORT_URC, RDMA_WR_RDMA_READ, case_counter, payload);
    if (request == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "URC READ wire rejection packet construction returned null");
      return;
    end
    before_sequence = tx_net.send_sequence;
    before_sent_count = tx_sink.sent_count;
    before_last_sent = tx_net.last_sent_packet;
    tx_net.send_packet(request, send_status);
    if (send_status == null ||
        send_status.code != RDMA_SC_UNSUPPORTED_OPCODE) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        $sformatf("URC READ wire rejection returned %s",
                  send_status == null ? "null" : send_status.convert2string()));
      return;
    end
    if (tx_net.send_sequence != before_sequence + 1) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        $sformatf("URC READ reject changed attempt sequence unexpectedly: %0d -> %0d",
                  before_sequence, tx_net.send_sequence));
      return;
    end
    if (tx_sink.sent_count != before_sent_count ||
        tx_net.last_sent_packet != before_last_sent) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "URC READ reject published a network packet or changed sink accounting");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：构造 READ response 或 Atomic ACK response，模拟远端 responder 在
  // 完成请求后返回的 RoCEv2 数据面报文。
  // 输入/输出及副作用：opcode、index、payload、original_value 为输入；返回
  //   独立 packet，不推进 sink、queue 或 host-memory 统计。
  // 失败/边界：仅接受 RC READ response/Atomic ACK；其他 opcode 返回 NAK 观察值，
  //   调用方必须停止当前 case。
  function automatic rdma_packet make_response_packet(
    rdma_network_opcode_e opcode,
    int unsigned index,
    byte unsigned payload[$],
    longint unsigned original_value
  );
    rdma_packet packet;
    packet = rdma_packet::type_id::create($sformatf("transport_response_%0d", index));
    packet.transport = RDMA_TRANSPORT_RC;
    packet.source_qpn = rx_env.qp.local_qp_id;
    packet.destination_qpn = tx_env.qp.local_qp_id;
    packet.psn = 24'h200 + index;
    packet.opcode = opcode;
    if (opcode == RDMA_NET_RDMA_READ_RESP)
      packet.payload = payload;
    else if (opcode == RDMA_NET_ATOMIC_ACK) begin
      packet.payload.delete();
      // RC Atomic ACK 在线上先携带 4B AETH，再携带 8B AtomicAckETH；
      // 显式写入零值 AETH，避免 adapter 把原值字段从错误偏移解析。
      for (int unsigned aeth_byte = 0; aeth_byte < 4; aeth_byte++)
        packet.header_bytes.push_back(8'h00);
      for (int signed byte_index = 7; byte_index >= 0; byte_index--)
        packet.header_bytes.push_back(byte'((original_value >>
                                             (byte_index * 8)) & 8'hff));
    end
    return packet;
  endfunction

  // 功能：failure_status 把“返回句柄为空但 status 仍为 OK”的异常统一转换为
  //   可诊断失败，避免测试 task 在半成品路径上错误返回成功。
  // 输入/输出及副作用：observed、fallback_code、message（输入）；返回独立
  //   rdma_status，不修改队列、mapping 或网络对象。
  // 失败/边界：observed 为非空错误时保留其原始 code/message；observed 为空或
  //   意外为 OK 时使用 fallback_code 和 message，调用方仍需立即终止当前 case。
  function automatic rdma_status failure_status(
    rdma_status observed,
    rdma_status_code_e fallback_code,
    string message
  );
    if (observed == null || observed.ok())
      return rdma_status::make(fallback_code, message);
    return observed;
  endfunction

  // 功能：比较 unsupported 前后读取到的 host-memory 字节快照。
  // 输入/输出及副作用：lhs、rhs（输入）；只读比较，不修改任何 mapping、队列
  //   或 adapter 状态；返回两份快照是否逐字节完全一致。
  // 失败/边界：长度不同或任一 byte 含未知值/不相等时返回 0；两个空快照视为相等。
  function automatic bit bytes_equal(input byte lhs[], input byte rhs[]);
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i])
      if (lhs[i] !== rhs[i])
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：轮询 TX/RX CQ，确认 CQE 释放对应 WR、opcode/status 正确并推进 CI。
  // 输入/输出及副作用：transport、wr_id、expected_index、expected_wrap、timeout（输入）；
  //   completion/status（输出）；
  //   成功时消费真实 CQ ring 一个 slot，更新 engine pending/credit 账本。
  // 失败/边界：队列空超时、owner/QPN 不匹配、CQE 错误或 WR ID 不一致均失败，
  //   不发布半成品 completion。
  task automatic wait_transport_completion(
    rdma_transport_e transport,
    longint unsigned wr_id,
    int unsigned expected_index,
    bit expected_wrap,
    time timeout,
    output rdma_queue_completion_result completion,
    output rdma_status status
  );
    rdma_qp tx_qp;
    int unsigned used;
    bit pending;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;

    completion = null;
    tx_qp = tx_env.get_qp_for_transport(transport);
    if (tx_qp == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "transport completion QP is missing");
      return;
    end
    tx_composition_env.poll_completion(tx_env.cq.handle, timeout,
                                       completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.cqe == null || completion.completion_status == null ||
        !completion.completion_status.ok() ||
        completion.released_slots.size() != 1) begin
      status = status == null ? rdma_status::make(RDMA_SC_TIMEOUT,
                                                   "TX completion unavailable") : status;
      return;
    end
    if (completion.cqe.qpn != tx_qp.local_qp_id ||
        completion.cqe.wr_id != wr_id) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        $sformatf("%s completion identity mismatch", transport.name()));
      return;
    end
    if (completion.released_slots[0].wr_id != wr_id ||
        completion.released_slots[0].index != expected_index ||
        completion.released_slots[0].wrap != expected_wrap) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "TX completion released-slot mismatch");
      return;
    end
    status = tx_composition_env.queue_data.query_runtime_occupancy(
      tx_qp.handle, RDMA_QUEUE_RUNTIME_SQ, used, pending);
    if (status == null || !status.ok() || used != 0 || pending) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "TX SQ credits were not fully released");
      return;
    end
    status = tx_composition_env.queue_data.query_runtime_cursors(
      tx_qp.handle, RDMA_QUEUE_RUNTIME_SQ, producer_index,
      producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok() || producer_index != consumer_index ||
        producer_wrap != consumer_wrap) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "TX SQ producer/consumer cursors diverged");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：执行一个 queue-level transport/opcode case：post RQ/SQ、host-memory
  //   payload、net_packet loopback、双端 CQE poll，并校验 queue cursor/wrap/credit
  //   结果；仅把核心语义层拒绝的组合作为 queue-level negative case。
  // 输入/输出及副作用：transport、opcode（输入）；status（输出）；成功时各环
  //   推进一个事务并释放 outstanding，失败时保持首个错误并停止该 case。
  // 失败/边界：UD 非 SEND 以及 CUSTOM/保留 transport 必须在 SQ 入口 fail-closed；
  //   任何 queue-level unsupported 请求不得写 host-memory、推进 PI 或产生 CQE。
  //   仅由外部 net_packet wire capability 拒绝的 URC RDMA_READ 由独立 helper
  //   在发送层验证，不能在本 task 中先 post 一个必然无法编码的 SQE。
  task automatic run_transport_case(
    rdma_transport_e transport,
    rdma_work_opcode_e opcode,
    output rdma_status status
  );
    rdma_post_send_req request;
    rdma_queue_post_result posted;
    rdma_queue_post_result recv_posted;
    rdma_post_recv_req recv_request;
    rdma_queue_completion_result completion;
    rdma_status local_status;
    rdma_status post_status;
    rdma_status cursor_status;
    rdma_status occupancy_status;
    rdma_status rx_occupancy_status;
    rdma_packet packet;
    rdma_packet received;
    rdma_packet response_packet;
    rdma_packet response_received;
    byte unsigned payload[$];
    byte unsigned response_payload[$];
    byte write_data[];
    byte readback[];
    longint unsigned wr_id;
    int unsigned before_pi;
    int unsigned before_sq_index;
    bit before_sq_wrap;
    int unsigned before_rq_index;
    bit before_rq_wrap;
    int unsigned after_sq_index;
    bit after_sq_wrap;
    int unsigned after_rq_index;
    bit after_rq_wrap;
    int unsigned ignored_index;
    bit ignored_wrap;
    longint unsigned before_tx_sequence;
    int unsigned before_tx_sent;
    longint unsigned before_rx_sequence;
    int unsigned before_rx_received;
    byte tx_payload_before[];
    byte rx_payload_before[];
    byte tx_payload_after[];
    byte rx_payload_after[];
    rdma_mapping_state_e before_tx_mapping_state;
    rdma_mapping_state_e before_rx_mapping_state;
    rdma_iova_t before_tx_iova;
    rdma_iova_t before_rx_iova;
    rdma_backing_addr_t before_tx_backing;
    rdma_backing_addr_t before_rx_backing;
    longint unsigned before_tx_mapping_size;
    longint unsigned before_rx_mapping_size;
    rdma_dma_direction_e before_tx_mapping_direction;
    rdma_dma_direction_e before_rx_mapping_direction;
    rdma_dma_permission_t before_tx_mapping_permissions;
    rdma_dma_permission_t before_rx_mapping_permissions;
    bit supported;
    bit unsupported_unchanged;
    int unsigned tx_used;
    int unsigned rx_used;
    bit tx_pending;
    bit rx_pending;
    bit tx_event_pending;
    bit rx_event_pending;
    bit needs_receive_wqe;
    longint unsigned atomic_original;
    longint unsigned atomic_result;
    longint unsigned atomic_addend;
    rdma_function_identity tx_event_identity;
    rdma_function_identity rx_event_identity;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    bit cq_polarity;
    int unsigned before_rq_pi;
    rdma_qp tx_qp;
    rdma_qp rx_qp;

    status = rdma_status::success();
    tx_event_pending = 1'b0;
    rx_event_pending = 1'b0;
    tx_qp = tx_env.get_qp_for_transport(transport);
    rx_qp = rx_env.get_qp_for_transport(transport);
    if (tx_qp == null || rx_qp == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "transport case QP topology is incomplete");
      return;
    end
    wr_id = 64'h9000_0000_0000_0000 + case_counter;
    make_payload(case_counter, payload);
    supported = rdma_send_opcode_valid_for_transport(transport, opcode) &&
                rdma_net_packet_work_opcode_supported_for_transport(
                  transport, opcode);
    before_pi = tx_qp.sq_producer_index;
    before_rq_pi = rx_qp.rq_producer_index;
    before_tx_sequence = tx_net.send_sequence;
    before_tx_sent = tx_sink.sent_count;
    before_rx_sequence = rx_net.receive_sequence;
    before_rx_received = rx_sink.receive_count;
    cursor_status = tx_composition_env.queue_data.query_runtime_cursors(
      tx_qp.handle, RDMA_QUEUE_RUNTIME_SQ, before_sq_index,
      before_sq_wrap, after_sq_index, after_sq_wrap);
    if (cursor_status == null || !cursor_status.ok()) begin
      status = failure_status(cursor_status, RDMA_SC_INVALID_STATE,
                              "TX SQ cursor query failed");
      return;
    end
    needs_receive_wqe = opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                                       RDMA_WR_SEND_WITH_INV,
                                       RDMA_WR_RDMA_WRITE,
                                       RDMA_WR_WRITE_WITH_IMM};
    cursor_status = rx_composition_env.queue_data.query_runtime_cursors(
      rx_qp.handle, RDMA_QUEUE_RUNTIME_RQ, before_rq_index,
      before_rq_wrap, after_rq_index, after_rq_wrap);
    if (cursor_status == null || !cursor_status.ok()) begin
      status = failure_status(cursor_status, RDMA_SC_INVALID_STATE,
                              "RX RQ cursor query failed");
      return;
    end

    // 不支持组合在最早入口 fail-closed：不得触碰 payload mapping、RQ/SQ
    // producer、doorbell 或 CQ。这样负向断言不会被前置副作用污染。
    if (!supported) begin
      // 记录真实 host-memory payload 和 mapping authority；unsupported post
      // 返回后再次读取，确保拒绝路径没有偷偷改写数据或生命周期字段。
      local_status = tx_host_adapter.read(tx_payload_mapping, 0,
                                           PAYLOAD_BYTES, tx_payload_before);
      if (local_status == null || !local_status.ok() ||
          tx_payload_before.size() != PAYLOAD_BYTES) begin
        status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                "TX unsupported pre-read failed");
        return;
      end
      local_status = rx_host_adapter.read(rx_payload_mapping, 0,
                                          PAYLOAD_BYTES, rx_payload_before);
      if (local_status == null || !local_status.ok() ||
          rx_payload_before.size() != PAYLOAD_BYTES) begin
        status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                "RX unsupported pre-read failed");
        return;
      end
      before_tx_mapping_state = tx_payload_mapping.state;
      before_rx_mapping_state = rx_payload_mapping.state;
      before_tx_iova = tx_payload_mapping.iova;
      before_rx_iova = rx_payload_mapping.iova;
      before_tx_backing = tx_payload_mapping.backing_addr;
      before_rx_backing = rx_payload_mapping.backing_addr;
      before_tx_mapping_size = tx_payload_mapping.size;
      before_rx_mapping_size = rx_payload_mapping.size;
      before_tx_mapping_direction = tx_payload_mapping.direction;
      before_rx_mapping_direction = rx_payload_mapping.direction;
      before_tx_mapping_permissions = tx_payload_mapping.permissions;
      before_rx_mapping_permissions = rx_payload_mapping.permissions;
      request = make_transport_request(transport, opcode, wr_id);
      tx_composition_env.post_send(request, posted, local_status);
      post_status = local_status;
      cursor_status = tx_composition_env.queue_data.query_runtime_cursors(
        tx_qp.handle, RDMA_QUEUE_RUNTIME_SQ, after_sq_index,
        after_sq_wrap, ignored_index, ignored_wrap);
      if (cursor_status != null && cursor_status.ok())
        cursor_status = rx_composition_env.queue_data.query_runtime_cursors(
          rx_qp.handle, RDMA_QUEUE_RUNTIME_RQ, after_rq_index,
          after_rq_wrap, ignored_index, ignored_wrap);
      occupancy_status = tx_composition_env.queue_data.query_runtime_occupancy(
        tx_qp.handle, RDMA_QUEUE_RUNTIME_SQ, tx_used, tx_pending);
      if (occupancy_status != null && occupancy_status.ok())
        rx_occupancy_status = rx_composition_env.queue_data.query_runtime_occupancy(
          rx_qp.handle, RDMA_QUEUE_RUNTIME_RQ, rx_used, rx_pending);
      local_status = tx_host_adapter.read(tx_payload_mapping, 0,
                                           PAYLOAD_BYTES, tx_payload_after);
      if (local_status == null || !local_status.ok() ||
          tx_payload_after.size() != PAYLOAD_BYTES)
        tx_payload_after.delete();
      local_status = rx_host_adapter.read(rx_payload_mapping, 0,
                                          PAYLOAD_BYTES, rx_payload_after);
      if (local_status == null || !local_status.ok() ||
          rx_payload_after.size() != PAYLOAD_BYTES)
        rx_payload_after.delete();
      unsupported_unchanged = post_status != null &&
          post_status.code == RDMA_SC_UNSUPPORTED_OPCODE && posted == null &&
          cursor_status != null && cursor_status.ok() &&
          after_sq_index == before_sq_index && after_sq_wrap == before_sq_wrap &&
          after_rq_index == before_rq_index && after_rq_wrap == before_rq_wrap &&
          occupancy_status != null && occupancy_status.ok() &&
          rx_occupancy_status != null && rx_occupancy_status.ok() &&
          tx_used == 0 && !tx_pending && rx_used == 0 && !rx_pending &&
          tx_qp.sq_producer_index == before_pi &&
          rx_qp.rq_producer_index == before_rq_pi &&
          tx_net.send_sequence == before_tx_sequence &&
          tx_sink.sent_count == before_tx_sent &&
          rx_net.receive_sequence == before_rx_sequence &&
          rx_sink.receive_count == before_rx_received &&
          bytes_equal(tx_payload_before, tx_payload_after) &&
          bytes_equal(rx_payload_before, rx_payload_after) &&
          tx_payload_mapping.state == before_tx_mapping_state &&
          rx_payload_mapping.state == before_rx_mapping_state &&
          tx_payload_mapping.iova === before_tx_iova &&
          rx_payload_mapping.iova === before_rx_iova &&
          tx_payload_mapping.backing_addr === before_tx_backing &&
          rx_payload_mapping.backing_addr === before_rx_backing &&
          tx_payload_mapping.size == before_tx_mapping_size &&
          rx_payload_mapping.size == before_rx_mapping_size &&
          tx_payload_mapping.direction == before_tx_mapping_direction &&
          rx_payload_mapping.direction == before_rx_mapping_direction &&
          tx_payload_mapping.permissions === before_tx_mapping_permissions &&
          rx_payload_mapping.permissions === before_rx_mapping_permissions;
      if (!unsupported_unchanged) begin
        if (tx_payload_after.size() == tx_payload_before.size())
          foreach (tx_payload_before[i])
            if (tx_payload_after[i] !== tx_payload_before[i]) begin
              `uvm_info("E2E_TRANSPORT_UNSUPPORTED_DIAG",
                        "TX unsupported path modified payload", UVM_LOW)
              break;
            end
        if (rx_payload_after.size() == rx_payload_before.size())
          foreach (rx_payload_before[i])
            if (rx_payload_after[i] !== rx_payload_before[i]) begin
              `uvm_info("E2E_TRANSPORT_UNSUPPORTED_DIAG",
                        "RX unsupported path modified payload", UVM_LOW)
              break;
            end
        `uvm_info("E2E_TRANSPORT_UNSUPPORTED_DIAG",
                  $sformatf("transport=%s opcode=%0d post=%s tx_cursor=%0d/%0d tx_wrap=%0d/%0d rx_cursor=%0d/%0d rx_wrap=%0d/%0d tx_used=%0d tx_pending=%0d rx_used=%0d rx_pending=%0d qp_pi=%0d/%0d rq_pi=%0d/%0d tx_net=%0d/%0d tx_sink=%0d/%0d rx_net=%0d/%0d rx_sink=%0d/%0d",
                            transport.name(), opcode,
                            post_status == null ? "null" : post_status.convert2string(),
                            before_sq_index, after_sq_index,
                            before_sq_wrap, after_sq_wrap,
                            before_rq_index, after_rq_index,
                            before_rq_wrap, after_rq_wrap,
                            tx_used, tx_pending, rx_used, rx_pending,
                            tx_qp.sq_producer_index, before_pi,
                            rx_qp.rq_producer_index, before_rq_pi,
                            tx_net.send_sequence, before_tx_sequence,
                            tx_sink.sent_count, before_tx_sent,
                            rx_net.receive_sequence, before_rx_sequence,
                            rx_sink.receive_count, before_rx_received),
                  UVM_LOW)
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "unsupported transport did not fail closed");
      end
      else begin
        status = rdma_status::success();
      end
      return;
    end

    // 真实事务进入数据面前先经过组合层的 Function-qualified 路由；该路由
    // 只登记 pending 账本，不替代 SQ/RQ post，避免重复推进 ring。
    tx_event_identity = tx_env.binding.function_identity_snapshot();
    route_composition_event(tx_composition_env, tx_event_identity,
                            case_counter, local_status);
    if (local_status == null || !local_status.ok()) begin
      status = failure_status(local_status, RDMA_SC_INVALID_STATE,
                              "TX composition event route failed");
      return;
    end
    tx_event_pending = 1'b1;
    rx_event_identity = rx_env.binding.function_identity_snapshot();
    route_composition_event(rx_composition_env, rx_event_identity,
                            case_counter, local_status);
    if (local_status == null || !local_status.ok()) begin
      status = failure_status(local_status, RDMA_SC_INVALID_STATE,
                              "RX composition event route failed");
      return;
    end
    rx_event_pending = 1'b1;

    write_data = new[payload.size()];
    foreach (payload[i]) write_data[i] = payload[i];
    local_status = tx_host_adapter.write(tx_payload_mapping, 0, write_data);
    if (local_status == null || !local_status.ok()) begin
      status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                              "TX payload write failed");
      return;
    end
    if (needs_receive_wqe) begin
      recv_request = rx_env.make_recv(64'ha000_0000_0000_0000 + case_counter);
      recv_request.target_h = rdma_clone_handle_value(
        rx_qp.handle, "transport receive QP");
      recv_request.sges[0].iova = rx_payload_mapping.iova;
      recv_request.sges[0].length = PAYLOAD_BYTES;
      rx_composition_env.post_recv(recv_request, recv_posted, local_status);
      if (local_status == null || !local_status.ok() || recv_posted == null) begin
        status = failure_status(local_status, RDMA_SC_INVALID_STATE,
                                "RQ post returned no result");
        return;
      end
      if (recv_posted.index != before_rq_index ||
          recv_posted.wrap != before_rq_wrap) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "RQ post cursor did not match runtime snapshot");
        return;
      end
    end
    else begin
      // READ/ATOMIC 的 responder 访问远端内存，不消耗接收 WQE。预置远端
      // backing，随后由本 task 执行最小 responder 语义并通过 response packet
      // 返回数据/原值。
      if (opcode == RDMA_WR_RDMA_READ) begin
        local_status = rx_host_adapter.write(rx_payload_mapping, 0, write_data);
      end
      else begin
        write_data = new[8];
        atomic_addend = 64'h1112_1314_1516_1718;
        // CompareSwap 预置匹配值以覆盖成功更新分支；FetchAdd 使用小的
        // 初始值，便于在 response 前后检查远端 backing 已被更新。
        atomic_result = opcode == RDMA_WR_ATOMIC_CMP_SWAP ?
                        64'h0102_0304_0506_0708 : 64'h10;
        for (int signed byte_index = 7; byte_index >= 0; byte_index--)
          write_data[7 - byte_index] = byte'((atomic_result >>
                                              (byte_index * 8)) & 8'hff);
        local_status = rx_host_adapter.write(rx_payload_mapping, 0, write_data);
      end
      if (local_status == null || !local_status.ok()) begin
        status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                "remote responder initialization failed");
        return;
      end
    end
    request = make_transport_request(transport, opcode, wr_id);
    tx_composition_env.post_send(request, posted, local_status);
    if (local_status == null || !local_status.ok() || posted == null) begin
      status = failure_status(local_status, RDMA_SC_INVALID_STATE,
                              "SQ post returned no result");
      return;
    end
    if (posted.index != before_sq_index || posted.wrap != before_sq_wrap) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "SQ post cursor did not match runtime snapshot");
      return;
    end
    packet = make_transport_packet(transport, opcode, case_counter, payload);
    tx_net.send_packet(packet, local_status);
    if (local_status == null || !local_status.ok()) begin
      status = failure_status(local_status, RDMA_SC_CODEC_ERROR,
                              "transport packet encode failed");
      return;
    end
    rx_sink.enqueue(tx_net.last_sent_packet);
    rx_net.receive_packet(received, local_status);
    // UC/URC wire BTH 不带 DETH，解码器无法从报文恢复 source_qpn；RC/UD
    // 中 RC 的模型值为零，而 UD 的 DETH 会携带并保留 source_qpn。
    if (local_status == null || !local_status.ok() || received == null ||
        received.transport != transport ||
        (transport != RDMA_TRANSPORT_URC &&
         received.source_qpn != packet.source_qpn) ||
        received.destination_qpn != packet.destination_qpn || received.psn != packet.psn ||
        ((opcode inside {RDMA_WR_ATOMIC_CMP_SWAP, RDMA_WR_ATOMIC_FETCH_ADD}) &&
         (received.payload.size() != 0 || received.header_bytes.size() < 28)) ||
        (opcode == RDMA_WR_RDMA_READ && received.payload.size() != 0))
      begin
        status = failure_status(local_status, RDMA_SC_CODEC_ERROR,
                                "transport packet decode failed");
      return;
    end
    if (needs_receive_wqe) begin
      foreach (payload[i]) if (received.payload[i] !== payload[i]) begin
        status = rdma_status::make(RDMA_SC_CODEC_ERROR,
                                   "transport payload mismatch");
        return;
      end
      write_data = new[received.payload.size()];
      foreach (received.payload[i]) write_data[i] = received.payload[i];
      local_status = rx_host_adapter.write(rx_payload_mapping, 0, write_data);
      if (local_status == null || !local_status.ok()) begin
        status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                "RX payload write failed");
        return;
      end
      local_status = rx_host_adapter.read(rx_payload_mapping, 0, PAYLOAD_BYTES,
                                          readback);
      if (local_status == null || !local_status.ok() ||
          readback.size() != PAYLOAD_BYTES) begin
        status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                "RX payload readback failed");
        return;
      end
      foreach (payload[i]) if (readback[i] !== payload[i]) begin
        status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                   "RX payload mismatch");
        return;
      end
    end
    else begin
      response_payload.delete();
      if (opcode == RDMA_WR_RDMA_READ) begin
        local_status = rx_host_adapter.read(rx_payload_mapping, 0,
                                            PAYLOAD_BYTES, readback);
        if (local_status == null || !local_status.ok() ||
            readback.size() != PAYLOAD_BYTES) begin
          status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                  "remote READ source read failed");
          return;
        end
        foreach (readback[i]) response_payload.push_back(readback[i]);
        response_packet = make_response_packet(RDMA_NET_RDMA_READ_RESP,
                                                case_counter, response_payload,
                                                0);
      end
      else begin
        local_status = rx_host_adapter.read(rx_payload_mapping, 0, 8, readback);
        if (local_status == null || !local_status.ok() || readback.size() != 8) begin
          status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                  "remote ATOMIC source read failed");
          return;
        end
        atomic_original = 0;
        foreach (readback[i])
          atomic_original = (atomic_original << 8) | longint'(readback[i]);
        atomic_result = opcode == RDMA_WR_ATOMIC_CMP_SWAP ?
          (atomic_original == 64'h0102_0304_0506_0708 ?
           64'h1112_1314_1516_1718 : atomic_original) :
          atomic_original + atomic_addend;
        write_data = new[8];
        for (int signed byte_index = 7; byte_index >= 0; byte_index--)
          write_data[7 - byte_index] = byte'((atomic_result >>
                                              (byte_index * 8)) & 8'hff);
        local_status = rx_host_adapter.write(rx_payload_mapping, 0, write_data);
        if (local_status == null || !local_status.ok()) begin
          status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                  "remote ATOMIC update failed");
          return;
        end
        response_packet = make_response_packet(RDMA_NET_ATOMIC_ACK,
                                                case_counter, response_payload,
                                                atomic_original);
      end
      rx_net.send_packet(response_packet, local_status);
      if (local_status == null || !local_status.ok() ||
          rx_net.last_sent_packet == null) begin
        status = failure_status(local_status, RDMA_SC_CODEC_ERROR,
                                "responder response encode failed");
        return;
      end
      tx_sink.enqueue(rx_net.last_sent_packet);
      tx_net.receive_packet(response_received, local_status);
      if (local_status == null || !local_status.ok() || response_received == null ||
          response_received.transport != RDMA_TRANSPORT_RC ||
          response_received.destination_qpn != tx_env.qp.local_qp_id ||
          response_received.source_qpn != rx_env.qp.local_qp_id ||
          response_received.psn != response_packet.psn ||
          response_received.opcode != response_packet.opcode) begin
        status = failure_status(local_status, RDMA_SC_CODEC_ERROR,
                                "responder response decode failed");
        return;
      end
      if (opcode == RDMA_WR_RDMA_READ) begin
        if (response_received.payload.size() != PAYLOAD_BYTES) begin
          status = rdma_status::make(RDMA_SC_CODEC_ERROR,
                                     "READ response payload length mismatch");
          return;
        end
        write_data = new[response_received.payload.size()];
        foreach (response_received.payload[i])
          write_data[i] = response_received.payload[i];
        local_status = tx_host_adapter.write(tx_payload_mapping, 0, write_data);
        if (local_status == null || !local_status.ok()) begin
          status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                  "READ response local write failed");
          return;
        end
      end
      else begin
        if (response_received.header_bytes.size() < 8) begin
          status = rdma_status::make(RDMA_SC_CODEC_ERROR,
                                     "Atomic ACK payload is missing");
          return;
        end
        atomic_original = 0;
        for (int unsigned byte_index = response_received.header_bytes.size() - 8;
             byte_index < response_received.header_bytes.size(); byte_index++)
          atomic_original = (atomic_original << 8) |
                            longint'(response_received.header_bytes[byte_index]);
        `uvm_info("E2E_ATOMIC_ACK_DIAG",
                  $sformatf("opcode=%0d header_bytes=%0d decoded_tail=0x%016x",
                            opcode, response_received.header_bytes.size(),
                            atomic_original), UVM_LOW)
        if (atomic_original != (opcode == RDMA_WR_ATOMIC_CMP_SWAP ?
                                64'h0102_0304_0506_0708 : 64'h10)) begin
          status = rdma_status::make(RDMA_SC_CODEC_ERROR,
                                     "Atomic ACK original value mismatch");
          return;
        end
        write_data = new[8];
        for (int signed byte_index = 7; byte_index >= 0; byte_index--)
          write_data[7 - byte_index] = byte'((atomic_original >>
                                              (byte_index * 8)) & 8'hff);
        local_status = tx_host_adapter.write(tx_payload_mapping, 0, write_data);
        if (local_status == null || !local_status.ok()) begin
          status = failure_status(local_status, RDMA_SC_DMA_TRANSLATION,
                                  "Atomic ACK local write failed");
          return;
        end
      end
    end
    // 中文设计：发送 completion 必须由实际持有 SQ/CQ runtime 的组合 engine
    // 查询 polarity 并公开 publish；fixture 只拥有 lifecycle 资源，不能旁路写 backing。
    local_status = tx_composition_env.queue_data.query_runtime_producer_polarity(
      tx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, cq_polarity);
    if (local_status == null || !local_status.ok()) begin
      status = failure_status(local_status, RDMA_SC_INVALID_STATE,
                              "TX CQ polarity query failed");
      return;
    end
    cqe = make_cqe(tx_qp, posted, 1'b0, case_counter, cq_polarity);
    cqe.wr_id = wr_id;
    cqe.opcode = opcode;
    cqe.byte_len = opcode == RDMA_WR_RDMA_READ ? PAYLOAD_BYTES :
                   ((opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                                     RDMA_WR_ATOMIC_FETCH_ADD}) ? 8 :
                    PAYLOAD_BYTES);
    published = null;
    tx_composition_env.queue_data.publish_cqe(
      tx_env.cq.handle, cqe, published, local_status);
    if (local_status == null || !local_status.ok() || published == null ||
        published.index != tx_cq_slot % CQ_DEPTH ||
        published.wrap != bit'(tx_cq_slot / CQ_DEPTH) ||
        !published.occupancy_valid || published.occupancy != 1) begin
      status = failure_status(local_status, RDMA_SC_INVALID_STATE,
                              "TX CQE public publish failed");
      return;
    end
    wait_transport_completion(transport, wr_id, posted.index, posted.wrap,
                              COMPLETION_TIMEOUT, completion, local_status);
    if (local_status == null || !local_status.ok()) begin
      status = local_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE, "TX CQ poll returned null status") :
        rdma_status::make(local_status.code, {"TX CQ poll: ", local_status.message});
      return;
    end
    if (completion.cqe.opcode != opcode) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "TX CQE opcode mismatch");
      return;
    end
    tx_cq_slot++;
    if (needs_receive_wqe) begin
      // SEND/WRITE 的接收方向独立查询自身 CQ polarity、公开 publish 并轮询；
      // TX polarity 不得复用于 RX，READ/ATOMIC response 不消费 RQ。
      local_status = rx_composition_env.queue_data.query_runtime_producer_polarity(
        rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, cq_polarity);
      if (local_status == null || !local_status.ok()) begin
        status = failure_status(local_status, RDMA_SC_INVALID_STATE,
                                "RX CQ polarity query failed");
        return;
      end
      cqe = make_cqe(rx_qp, recv_posted, 1'b1, case_counter, cq_polarity);
      cqe.wr_id = recv_posted.wr_id;
      cqe.opcode = RDMA_WR_RECV;
      cqe.byte_len = PAYLOAD_BYTES;
      published = null;
      rx_composition_env.queue_data.publish_cqe(
        rx_env.cq.handle, cqe, published, local_status);
      if (local_status == null || !local_status.ok() || published == null ||
          published.index != rx_cq_slot % CQ_DEPTH ||
          published.wrap != bit'(rx_cq_slot / CQ_DEPTH) ||
          !published.occupancy_valid || published.occupancy != 1) begin
        status = failure_status(local_status, RDMA_SC_INVALID_STATE,
                                "RX CQE public publish failed");
        return;
      end
      begin
        int unsigned cq_pi;
        int unsigned cq_ci;
        bit cq_pw;
        bit cq_cw;
        local_status = rx_composition_env.queue_data.query_runtime_cursors(
          rx_env.cq.handle, RDMA_QUEUE_RUNTIME_CQ, cq_pi, cq_pw, cq_ci, cq_cw);
        `uvm_info("E2E_RX_CQ_DIAG",
                  $sformatf("transport=%s slot=%0d cqe_polarity=%0d cq_pi=%0d/%0d cq_ci=%0d/%0d",
                            transport.name(), case_counter, cqe.polarity,
                            cq_pi, cq_pw, cq_ci, cq_cw), UVM_LOW)
      end
      rx_composition_env.poll_completion(rx_env.cq.handle, COMPLETION_TIMEOUT,
                                         completion, local_status);
      if (local_status == null || !local_status.ok() || completion == null ||
          completion.cqe == null || completion.cqe.qpn != rx_qp.local_qp_id ||
          completion.released_slots.size() != 1 ||
          completion.released_slots[0].wr_id != recv_posted.wr_id ||
          completion.released_slots[0].index != recv_posted.index ||
          completion.released_slots[0].wrap != recv_posted.wrap) begin
        status = local_status == null ? rdma_status::make(RDMA_SC_TIMEOUT,
          "RX CQ poll returned null status") :
          rdma_status::make(local_status.code,
                            {"RX CQ poll: ", local_status.message});
        return;
      end
      rx_cq_slot++;
    end
    local_status = rx_composition_env.queue_data.query_runtime_occupancy(
      rx_qp.handle, RDMA_QUEUE_RUNTIME_RQ, rx_used, rx_pending);
    if (local_status == null || !local_status.ok() || rx_used != 0 || rx_pending) begin
      status = local_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "RX RQ credit query returned null status") :
        rdma_status::make(local_status.code,
                          "RX RQ credits were not fully released");
      return;
    end
    local_status = rx_composition_env.queue_data.query_runtime_cursors(
      rx_qp.handle, RDMA_QUEUE_RUNTIME_RQ, after_rq_index,
      after_rq_wrap, ignored_index, ignored_wrap);
    if (local_status == null || !local_status.ok() ||
        after_rq_index != ignored_index || after_rq_wrap != ignored_wrap) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "RX RQ producer/consumer cursors diverged");
      return;
    end
    // 双端 CQ 已确认完成后再释放组合层 pending，避免组合账本先于数据面
    // 完成而出现短暂的假空闲。
    if (tx_event_pending) begin
      tx_composition_env.end_pending();
      tx_event_pending = 1'b0;
    end
    if (rx_event_pending) begin
      rx_composition_env.end_pending();
      rx_event_pending = 1'b0;
    end
    status = rdma_status::success();
  endtask

  // 功能：配置双 env，按计划矩阵执行六种协议支持场景及两种负向场景，
  //   最后统一清理并检查 leak。
  // 输入/输出及副作用：phase（输入）；驱动真实 host_mem/net_packet 与 CQ ring，
  //   管理 objection；失败场景记录 UVM error 但仍执行完整 cleanup。
  // 失败/边界：任一 setup/case 失败停止后续 case，cleanup 仍必须释放全部 mapping。
  task run_phase(uvm_phase phase);
    rdma_status status;
    bit transport_matrix_ok;
    rdma_transport_e transports[TRANSPORT_CASES];
    rdma_work_opcode_e opcodes[TRANSPORT_CASES];
    phase.raise_objection(this);
    tx_cq_slot = 0;
    rx_cq_slot = 0;
    configure_envs(status);
    if (status != null && status.ok())
      configure_composition_envs(status);
    if (status != null && status.ok())
      `uvm_info("E2E_TRANSPORT_TOPOLOGY",
                $sformatf("tx rc=%s/id%0d/qpn%0d ud=%s/id%0d/qpn%0d urc=%s/id%0d/qpn%0d; rx rc=%s/id%0d/qpn%0d ud=%s/id%0d/qpn%0d urc=%s/id%0d/qpn%0d",
                          tx_env.qp.transport.name(), tx_env.qp.handle.object_id,
                          tx_env.qp.local_qp_id,
                          tx_env.ud_qp.transport.name(), tx_env.ud_qp.handle.object_id,
                          tx_env.ud_qp.local_qp_id,
                          tx_env.urc_qp.transport.name(), tx_env.urc_qp.handle.object_id,
                          tx_env.urc_qp.local_qp_id,
                          rx_env.qp.transport.name(), rx_env.qp.handle.object_id,
                          rx_env.qp.local_qp_id,
                          rx_env.ud_qp.transport.name(), rx_env.ud_qp.handle.object_id,
                          rx_env.ud_qp.local_qp_id,
                          rx_env.urc_qp.transport.name(), rx_env.urc_qp.handle.object_id,
                          rx_env.urc_qp.local_qp_id), UVM_LOW)
    if (status != null && status.ok()) begin
      transport_matrix_ok = 1'b1;
      transports = '{RDMA_TRANSPORT_RC, RDMA_TRANSPORT_RC, RDMA_TRANSPORT_RC,
                     RDMA_TRANSPORT_RC, RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                     RDMA_TRANSPORT_URC, RDMA_TRANSPORT_URC};
      opcodes = '{RDMA_WR_SEND, RDMA_WR_RDMA_WRITE, RDMA_WR_RDMA_READ,
                  RDMA_WR_ATOMIC_CMP_SWAP, RDMA_WR_ATOMIC_FETCH_ADD,
                  RDMA_WR_SEND, RDMA_WR_SEND, RDMA_WR_RDMA_WRITE};
      for (int unsigned i = 0; i < TRANSPORT_CASES; i++) begin
        case_counter = i;
        run_transport_case(transports[i], opcodes[i], status);
        if (status == null || !status.ok()) begin
          `uvm_error("E2E_TRANSPORT", $sformatf("case %0d failed: %s", i, status == null ? "null" : status.convert2string()));
          transport_matrix_ok = 1'b0;
          break;
        end
      end
      if (transport_matrix_ok) begin
        // 独立回放跨过完整 ring 深度，验证 producer/consumer wrap 翻转和
        // 翻转后的第二个 slot 仍能完成、释放 credit 并保持 cursor 一致。
        for (int unsigned i = 0; i < WRAP_REPLAY_CASES; i++) begin
          case_counter = TRANSPORT_CASES + i;
          run_transport_case(RDMA_TRANSPORT_RC, RDMA_WR_SEND, status);
          if (status == null || !status.ok()) begin
            `uvm_error("E2E_TRANSPORT_WRAP",
                       $sformatf("wrap replay %0d failed: %s", i,
                                 status == null ? "null" : status.convert2string()));
            transport_matrix_ok = 1'b0;
            break;
          end
        end
        // 回放结束后统一检查，而不是假设某个固定 iteration 同时触发 SQ/RQ
        // 回卷：READ/ATOMIC 不消耗 RQ，两个 ring 的绝对序号本来就不同。
        if (transport_matrix_ok) begin
          begin
            int unsigned sq_producer_index;
            int unsigned sq_consumer_index;
            bit sq_producer_wrap;
            bit sq_consumer_wrap;
            int unsigned rq_producer_index;
            int unsigned rq_consumer_index;
            bit rq_producer_wrap;
            bit rq_consumer_wrap;
            rdma_status cursor_status;
            cursor_status = tx_composition_env.queue_data.query_runtime_cursors(
              tx_env.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_producer_index,
              sq_producer_wrap, sq_consumer_index, sq_consumer_wrap);
            if (cursor_status == null || !cursor_status.ok() ||
                sq_producer_index != sq_consumer_index ||
                sq_producer_wrap != sq_consumer_wrap || !sq_producer_wrap) begin
              `uvm_error("E2E_TRANSPORT_WRAP",
                         $sformatf("SQ cursor did not complete a wrap: %s %0d/%0d %0d/%0d",
                                   cursor_status == null ? "null" : cursor_status.convert2string(),
                                   sq_producer_index, sq_consumer_index,
                                   sq_producer_wrap, sq_consumer_wrap));
              transport_matrix_ok = 1'b0;
            end
            cursor_status = rx_composition_env.queue_data.query_runtime_cursors(
              rx_env.qp.handle, RDMA_QUEUE_RUNTIME_RQ, rq_producer_index,
              rq_producer_wrap, rq_consumer_index, rq_consumer_wrap);
            if (cursor_status == null || !cursor_status.ok() ||
                rq_producer_index != rq_consumer_index ||
                rq_producer_wrap != rq_consumer_wrap || !rq_producer_wrap) begin
              `uvm_error("E2E_TRANSPORT_WRAP",
                         $sformatf("RQ cursor did not complete a wrap: %s %0d/%0d %0d/%0d",
                                   cursor_status == null ? "null" : cursor_status.convert2string(),
                                   rq_producer_index, rq_consumer_index,
                                   rq_producer_wrap, rq_consumer_wrap));
              transport_matrix_ok = 1'b0;
            end
          end
        end
      end
      if (transport_matrix_ok) begin
        // 负向契约：UD RDMA_WRITE 由核心 queue-data 入口拒绝且不推进 SQ/RQ；
        // URC RDMA_READ 则保留核心语义白名单，改由 net_packet wire capability
        // 在不触碰 SQ 的独立发送层 fixture 中拒绝。
        case_counter = TRANSPORT_CASES;
        run_transport_case(RDMA_TRANSPORT_UD, RDMA_WR_RDMA_WRITE, status);
        if (status == null || !status.ok())
          `uvm_error("E2E_TRANSPORT_UNSUPPORTED", "UD RDMA_WRITE was not rejected")
        case_counter = TRANSPORT_CASES + 1;
        run_urc_read_wire_rejection(status);
        if (status == null || !status.ok())
          `uvm_error("E2E_TRANSPORT_UNSUPPORTED", "URC RDMA_READ was not rejected")
      end
      if (tx_composition_env.pending_count() != 0 ||
          rx_composition_env.pending_count() != 0)
        `uvm_error("E2E_COMPOSITION_PENDING",
                   "composition env pending count did not drain")
    end
    else `uvm_error("E2E_SETUP", status == null ? "null setup status" : status.convert2string());
    drain_composition_pending();
    cleanup_composition_data_paths(status);
    if (status == null || !status.ok())
      `uvm_error("E2E_COMPOSITION_CLEANUP",
                 status == null ? "null cleanup status" : status.convert2string())
    cleanup_env("tx_transport", tx_env, tx_host_adapter, tx_payload_mapping);
    cleanup_env("rx_transport", rx_env, rx_host_adapter, rx_payload_mapping);
    if (tx_host_mem != null) tx_host_mem.leak_check(`__FILE__, `__LINE__);
    if (rx_host_mem != null) rx_host_mem.leak_check(`__FILE__, `__LINE__);
    phase.drop_objection(this);
  endtask
endclass
