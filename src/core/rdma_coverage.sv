// 目录：核心执行层 core/。
// 职责：收集 RDMA transport、Function/domain、错误来源、doorbell/状态以及
//       reset/wrap/DMA 地址属性的值覆盖，并提供轻量 cross 命中查询。
// 依赖：rdma_types_pkg、rdma_model_pkg 中的枚举和 rdma_status；不依赖外部
//       PCIe、host-mem、net_packet 或 AXIS 实现。
// 所有权与生命周期：coverage 只拥有最后一次事件的值快照和本地 covergroup；
//       传入对象只读取枚举/标量字段，不保存外部对象句柄。

// 中文说明：该 collector 故意保持为 uvm_object，而不是 uvm_component，便于
// core-only 回归直接构造；集成测试可以把同一个 collector 借给多个 Function
// harness，但事件本身必须携带完整 Function/domain 和 generation 证据。
typedef enum bit [2:0] {
  RDMA_COVER_RESET_NONE   = 3'd0,
  RDMA_COVER_RESET_VF     = 3'd1,
  RDMA_COVER_RESET_PF     = 3'd2,
  RDMA_COVER_RESET_HOST   = 3'd3,
  RDMA_COVER_RESET_DEVICE = 3'd4
} rdma_coverage_reset_stage_e;

typedef enum bit [2:0] {
  RDMA_COVER_FN_DISCOVERED  = 3'd0,
  RDMA_COVER_FN_ACTIVE      = 3'd1,
  RDMA_COVER_FN_QUIESCING   = 3'd2,
  RDMA_COVER_FN_QUARANTINED = 3'd3,
  RDMA_COVER_FN_RECOVERED   = 3'd4
} rdma_coverage_function_state_e;

class rdma_coverage extends uvm_object;
  `uvm_object_utils(rdma_coverage)

  // 最后一次有效事件的 detached scalar snapshot，便于失败报告重现采样上下文。
  rdma_transport_e last_transport;
  rdma_work_opcode_e last_work_opcode;
  rdma_doorbell_kind_e last_doorbell_kind;
  rdma_resource_kind_e last_resource_kind;
  int unsigned last_function_count;
  int unsigned last_dma_domain_id;
  bit last_queue_wrap;
  bit last_dma_high_nonzero;
  rdma_status_code_e last_status_code;
  rdma_engine_kind_e last_source_engine;
  rdma_coverage_reset_stage_e last_reset_stage;
  rdma_coverage_function_state_e last_function_state;

  protected int unsigned m_sample_count;
  protected int unsigned m_cross_hit_count;
  protected bit m_fault_coverage;

  // covergroup 覆盖四个计划要求的关系，并将 wrap/DMA 高位/reset 单独采样。
  covergroup event_cg;
    cp_transport: coverpoint last_transport;
    cp_work_opcode: coverpoint last_work_opcode;
    cp_function_count: coverpoint last_function_count {
      bins zero = {0};
      bins one = {1};
      bins two_to_three = {[2:3]};
      bins four_or_more = {[4:$]};
    }
    cp_dma_domain: coverpoint last_dma_domain_id {
      bins domain_zero = {0};
      bins domain_one = {1};
      bins domain_two = {2};
      bins domain_other = {[3:$]};
    }
    cp_status: coverpoint last_status_code;
    cp_source_engine: coverpoint last_source_engine;
    cp_doorbell: coverpoint last_doorbell_kind;
    cp_function_state: coverpoint last_function_state;
    cp_queue_wrap: coverpoint last_queue_wrap;
    cp_dma_high: coverpoint last_dma_high_nonzero;
    cp_reset_stage: coverpoint last_reset_stage;
    transport_x_opcode: cross cp_transport, cp_work_opcode;
    function_x_domain: cross cp_function_count, cp_dma_domain;
    status_x_engine: cross cp_status, cp_source_engine;
    doorbell_x_function_state: cross cp_doorbell, cp_function_state;
  endgroup

  // 功能：构造空 coverage collector，初始化最后快照、计数器和 covergroup。
  // 输入/输出及副作用：name（输入）；只建立本地 UVM 对象和覆盖模型，不访问
  //   外部环境或分配 RDMA 资源。
  // 失败/边界：构造成功但尚未采样时所有计数为零；event_cg 仅由有效 sample 更新。
  function new(string name = "rdma_coverage");
    super.new(name);
    last_transport = RDMA_TRANSPORT_CUSTOM;
    last_work_opcode = RDMA_WR_SEND;
    last_doorbell_kind = RDMA_DOORBELL_SQ;
    last_resource_kind = RDMA_RESOURCE_QP;
    last_function_count = 0;
    last_dma_domain_id = 0;
    last_queue_wrap = 1'b0;
    last_dma_high_nonzero = 1'b0;
    last_status_code = RDMA_SC_OK;
    last_source_engine = RDMA_ENGINE_NONE;
    last_reset_stage = RDMA_COVER_RESET_NONE;
    last_function_state = RDMA_COVER_FN_DISCOVERED;
    m_sample_count = 0;
    m_cross_hit_count = 0;
    m_fault_coverage = 1'b0;
    event_cg = new();
  endfunction

  // 功能：判断事件的枚举、Function 数量和 engine 组合是否足以形成有效覆盖样本。
  // 输入/输出及副作用：所有事件字段为输入；只读检查，不修改 collector 或外部状态。
  // 失败/边界：CUSTOM/RESERVED transport、零 Function count 或未知枚举均返回 0，
  //   防止无效样本污染 coverage 统计。
  protected function bit valid_sample(
    rdma_transport_e transport,
    rdma_work_opcode_e work_opcode,
    rdma_doorbell_kind_e doorbell_kind,
    rdma_resource_kind_e resource_kind,
    int unsigned function_count,
    rdma_status_code_e status_code,
    rdma_engine_kind_e source_engine,
    rdma_coverage_reset_stage_e reset_stage,
    rdma_coverage_function_state_e function_state
  );
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}) ||
        !(work_opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                              RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                              RDMA_WR_RDMA_READ, RDMA_WR_ATOMIC_CMP_SWAP,
                              RDMA_WR_ATOMIC_FETCH_ADD}) ||
        !(doorbell_kind inside {RDMA_DOORBELL_CMQ_SQ, RDMA_DOORBELL_SQ,
                                RDMA_DOORBELL_RQ, RDMA_DOORBELL_CQ}) ||
        !(resource_kind inside {RDMA_RESOURCE_QP, RDMA_RESOURCE_CQ,
                                RDMA_RESOURCE_MR, RDMA_RESOURCE_CMQ}) ||
        function_count == 0 ||
        !(status_code inside {RDMA_SC_OK, RDMA_SC_STALE_GENERATION,
                              RDMA_SC_TIMEOUT, RDMA_SC_DMA_PERMISSION,
                              RDMA_SC_DMA_TRANSLATION, RDMA_SC_CODEC_ERROR,
                              RDMA_SC_RECOVERY_REQUIRED}) ||
        !(source_engine inside {RDMA_ENGINE_NONE, RDMA_ENGINE_CMQ,
                                RDMA_ENGINE_SQ, RDMA_ENGINE_RQ,
                                RDMA_ENGINE_CQ, RDMA_ENGINE_DMA,
                                RDMA_ENGINE_NETWORK, RDMA_ENGINE_RESET}) ||
        !(reset_stage inside {RDMA_COVER_RESET_NONE, RDMA_COVER_RESET_VF,
                              RDMA_COVER_RESET_PF, RDMA_COVER_RESET_HOST,
                              RDMA_COVER_RESET_DEVICE}) ||
        !(function_state inside {RDMA_COVER_FN_DISCOVERED,
                                 RDMA_COVER_FN_ACTIVE,
                                 RDMA_COVER_FN_QUIESCING,
                                 RDMA_COVER_FN_QUARANTINED,
                                 RDMA_COVER_FN_RECOVERED}))
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：采样一个带 transport/opcode/Function/domain/错误来源的完整事件。
  // 输入/输出及副作用：事件标量为输入；有效事件更新最后快照、covergroup、样本与
  //   cross 计数，错误/复位事件设置 fault coverage 标志；无效事件不改变任何计数。
  // 失败/边界：非法 transport/opcode、零 Function count 或不支持的枚举组合被丢弃，
  //   不抛出 fatal，也不把无效数据转换为默认 OK。
  function void sample_event(
    rdma_transport_e transport,
    rdma_work_opcode_e work_opcode,
    rdma_doorbell_kind_e doorbell_kind,
    rdma_resource_kind_e resource_kind,
    int unsigned function_count,
    int unsigned dma_domain_id,
    bit queue_wrap,
    bit dma_high_nonzero,
    rdma_status_code_e status_code,
    rdma_engine_kind_e source_engine,
    rdma_coverage_reset_stage_e reset_stage,
    rdma_coverage_function_state_e function_state
  );
    if (!valid_sample(transport, work_opcode, doorbell_kind, resource_kind,
                      function_count, status_code, source_engine, reset_stage,
                      function_state))
      return;
    last_transport = transport;
    last_work_opcode = work_opcode;
    last_doorbell_kind = doorbell_kind;
    last_resource_kind = resource_kind;
    last_function_count = function_count;
    last_dma_domain_id = dma_domain_id;
    last_queue_wrap = queue_wrap;
    last_dma_high_nonzero = dma_high_nonzero;
    last_status_code = status_code;
    last_source_engine = source_engine;
    last_reset_stage = reset_stage;
    last_function_state = function_state;
    event_cg.sample();
    m_sample_count++;
    m_cross_hit_count++;
    if (status_code != RDMA_SC_OK || reset_stage != RDMA_COVER_RESET_NONE)
      m_fault_coverage = 1'b1;
  endfunction

  // 功能：返回已接受并送入 covergroup 的有效事件数。
  // 输入/输出及副作用：无参数；只读返回 m_sample_count，不修改采样账本。
  // 失败/边界：尚未采样或所有输入非法时返回 0。
  function int unsigned sample_count();
    return m_sample_count;
  endfunction

  // 功能：返回有效事件对应的 cross 命中数，供 focused test 检查 cross 已被驱动。
  // 输入/输出及副作用：无参数；只读返回本地 cross 计数，不访问外部覆盖数据库。
  // 失败/边界：没有有效样本时返回 0；每个有效事件至少贡献一个组合命中。
  function int unsigned cross_hit_count();
    return m_cross_hit_count;
  endfunction

  // 功能：报告是否至少采样到一个错误或 reset 阶段事件。
  // 输入/输出及副作用：无参数；只读返回 fault 标志，不修改计数器或最后快照。
  // 失败/边界：只有全为 RDMA_SC_OK 且无 reset 的样本时返回 0。
  function bit has_fault_coverage();
    return m_fault_coverage;
  endfunction
endclass
