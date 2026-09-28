// 目录/层次：核心执行层 core/rdma_queue_mmio_transition_policy.sv。
// 文件职责：集中定义 queue runtime 的 MMIO evidence 迁移规则，向普通 recovery
//   API 和 noalloc scheduler API 提供同一份无状态、可审计的值决策。
// 主要依赖：依赖 rdma_queue_runtime_transaction_models.sv 中的
//   rdma_queue_mmio_evidence_e；不访问 runtime lock、pending、cursor、Host-memory、
//   PCIe 或任何外部 adapter。
// 所有权与生命周期：policy 对象不拥有 queue、recovery 或 MMIO 资源；调用方只接收
//   detached bit 结果，runtime 仍唯一拥有 evidence、confirmation 和状态迁移副作用。

// 中文设计说明：MMIO evidence 是 recovery 的安全边界。consumer 的 AMBIGUOUS 表示
//   doorbell 可能已经提交，任何 retry 都必须拒绝；device producer 的 NOT_APPLICABLE
//   只在本次确认过写入后才可安装。将规则独立出来，避免两个 caller 各自维护允许表。
class rdma_queue_mmio_transition_policy extends uvm_object;
  `uvm_object_utils(rdma_queue_mmio_transition_policy)

  // 功能：构造无状态 MMIO transition policy 对象；对象不保存任何当前 queue evidence。
  // 输入/输出及副作用：name（输入）设置 UVM 名称；new 不创建 pending、lock、cursor
  //   或外部 MMIO 资源。
  // 失败/边界：构造成功不代表 transition 合法；调用方必须检查 decide() 的 bit
  //   结果，不能把默认 output 当成已授权状态。
  function new(string name = "rdma_queue_mmio_transition_policy");
    super.new(name);
  endfunction

  // 功能：decide 根据 producer 方向和当前/目标 evidence 计算唯一允许的 MMIO
  //   状态迁移，并指出该迁移是否应消费 caller 的一次性 retry confirmation。
  // 输入/输出及副作用：current/evidence/device_producer/device_write_attempted/
  //   retry_confirmed 为输入；consume_confirmation 为输出；函数只计算值，不修改
  //   runtime pending、confirmation、cursor 或外部 adapter。
  // 失败/边界：非法 enum、device 在未写入 backing 时声明 NOT_APPLICABLE、从
  //   SUCCESS/AMBIGUOUS 回退、或确定性重放缺少 confirmation 时返回 0；AMBIGUOUS
  //   对 consumer 永远是终态，不能被该 policy 变成可重放状态。
  static function bit decide(
      rdma_queue_mmio_evidence_e current,
      rdma_queue_mmio_evidence_e evidence,
      bit device_producer,
      bit device_write_attempted,
      bit retry_confirmed,
      output bit consume_confirmation
  );
    bit transition_allowed;

    consume_confirmation = 1'b0;
    transition_allowed = 1'b0;
    if (!(current inside {RDMA_QUEUE_MMIO_NONE,
                          RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                          RDMA_QUEUE_MMIO_NO_SUBMIT,
                          RDMA_QUEUE_MMIO_SUCCESS,
                          RDMA_QUEUE_MMIO_AMBIGUOUS}) ||
        !(evidence inside {RDMA_QUEUE_MMIO_NONE,
                           RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                           RDMA_QUEUE_MMIO_NO_SUBMIT,
                           RDMA_QUEUE_MMIO_SUCCESS,
                           RDMA_QUEUE_MMIO_AMBIGUOUS}))
      return 1'b0;

    if (device_producer) begin
      case (current)
        RDMA_QUEUE_MMIO_NONE: begin
          transition_allowed = evidence inside {
            RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_NO_SUBMIT};
          if (evidence == RDMA_QUEUE_MMIO_NOT_APPLICABLE)
            transition_allowed = device_write_attempted;
        end
        RDMA_QUEUE_MMIO_NO_SUBMIT: begin
          transition_allowed = (evidence == RDMA_QUEUE_MMIO_NO_SUBMIT);
          if (evidence == RDMA_QUEUE_MMIO_NOT_APPLICABLE) begin
            transition_allowed = retry_confirmed && device_write_attempted;
            consume_confirmation = transition_allowed;
          end
        end
        RDMA_QUEUE_MMIO_NOT_APPLICABLE:
          transition_allowed = (evidence == RDMA_QUEUE_MMIO_NOT_APPLICABLE);
        default:
          transition_allowed = 1'b0;
      endcase
    end
    else begin
      case (current)
        RDMA_QUEUE_MMIO_NONE:
          transition_allowed = evidence inside {
            RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_NO_SUBMIT,
            RDMA_QUEUE_MMIO_SUCCESS, RDMA_QUEUE_MMIO_AMBIGUOUS};
        RDMA_QUEUE_MMIO_NO_SUBMIT: begin
          transition_allowed = (evidence == RDMA_QUEUE_MMIO_NO_SUBMIT);
          if (evidence inside {RDMA_QUEUE_MMIO_SUCCESS,
                               RDMA_QUEUE_MMIO_AMBIGUOUS}) begin
            transition_allowed = retry_confirmed;
            consume_confirmation = transition_allowed;
          end
        end
        RDMA_QUEUE_MMIO_SUCCESS:
          transition_allowed = (evidence == RDMA_QUEUE_MMIO_SUCCESS);
        RDMA_QUEUE_MMIO_AMBIGUOUS:
          transition_allowed = (evidence == RDMA_QUEUE_MMIO_AMBIGUOUS);
        default:
          transition_allowed = 1'b0;
      endcase
    end
    return transition_allowed;
  endfunction
endclass
