// 目录/层次：核心执行层 core/rdma_queue_mmio_transition_policy.sv。
// 职责：定义 queue runtime 的 MMIO evidence 迁移规则，供 recovery 与 noalloc scheduler 共用。
// 依赖：依赖 rdma_queue_mmio_evidence_e；不访问 lock、pending、cursor 或外部 adapter。
// 所有权与生命周期：policy 不拥有 queue/MMIO 资源，只返回 detached bit；evidence 与迁移由 runtime 拥有。

// 设计说明：MMIO evidence 是 recovery 的安全边界。consumer 的 AMBIGUOUS 表示 doorbell 可能已提交，
// 任何 retry 都须拒绝；device producer 的 NOT_APPLICABLE 仅在确认写入后才可安装。
class rdma_queue_mmio_transition_policy extends uvm_object;
  `uvm_object_utils(rdma_queue_mmio_transition_policy)

  // 功能：构造无状态 MMIO transition policy。
  // 输入/输出及副作用：name 为 UVM 名称；仅初始化基类。
  // 失败/边界：无。
  function new(string name = "rdma_queue_mmio_transition_policy");
    super.new(name);
  endfunction

  // 功能：按 producer 方向与当前/目标 evidence 判断迁移是否允许，并指出是否消费 retry confirmation。
  // 输入/输出及副作用：current/evidence/device_producer/device_write_attempted/retry_confirmed 为输入；
  //   consume_confirmation 为输出；纯值计算。
  // 失败/边界：非法 enum、device 未写 backing 却声明 NOT_APPLICABLE、从 SUCCESS/AMBIGUOUS 回退、
  //   或重放缺少 confirmation 时返回 0；consumer 的 AMBIGUOUS 为终态。
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
