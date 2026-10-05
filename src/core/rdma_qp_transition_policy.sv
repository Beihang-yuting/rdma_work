// 目录：核心执行层 core/rdma_qp_transition_policy.sv，QP 生命周期 policy 层。
// 职责：集中描述 QP 状态迁移矩阵，与 QPC 编码、CMQ 提交和 manager mutation 分离。
// 依赖：rdma_model_pkg 的 rdma_qp_state_e、rdma_status_code_e；不读取 manager、ledger、
//   Host-memory 或 adapter。
// 所有权与生命周期：只返回无状态 decision 值，不保存句柄；调用方负责映射为 status 与 commit。

// 设计说明：RESET→INIT→RTR→RTS 为主干，ERROR/RESET 为 teardown/recovery 分支。当前 profile
//   未实现 SQD/SQE drain，由 executor 的 capability gate 拒绝；将来增加 drain policy 时
//   只需替换本层。
typedef enum bit [1:0] {
  RDMA_QP_TRANSITION_INVALID = 2'd0,
  RDMA_QP_TRANSITION_SEMANTIC_ONLY = 2'd1,
  RDMA_QP_TRANSITION_FULL_MODIFY = 2'd2
} rdma_qp_transition_action_e;

typedef struct {
  rdma_qp_transition_action_e action;
  rdma_status_code_e reject_code;
  string reject_reason;
} rdma_qp_transition_decision_t;

// 功能：按当前与目标 QP 状态计算迁移动作（仅语义/完整 modify/拒绝）。
// 输入/输出及副作用：两个状态只读；返回 decision，成功时 reject_code 为 RDMA_SC_OK；无副作用。
// 失败/边界：含 X/Z、不在矩阵内返回 INVALID_STATE；涉及 SQD/SQE 返回 UNSUPPORTED_OPCODE。
//   相同状态与 outstanding WQE 不在此判断。
function automatic rdma_qp_transition_decision_t rdma_qp_transition_decide(
  input rdma_qp_state_e current_state,
  input rdma_qp_state_e requested_state
);
  rdma_qp_transition_decision_t decision;

  decision.action = RDMA_QP_TRANSITION_INVALID;
  decision.reject_code = RDMA_SC_INVALID_STATE;
  decision.reject_reason = "QP state transition is invalid";

  if ($isunknown(current_state) || $isunknown(requested_state)) begin
    decision.reject_reason = "QP state transition contains an unknown state";
    return decision;
  end

  if (current_state inside {RDMA_QPS_SQD, RDMA_QPS_SQE} ||
      requested_state inside {RDMA_QPS_SQD, RDMA_QPS_SQE}) begin
    decision.reject_code = RDMA_SC_UNSUPPORTED_OPCODE;
    decision.reject_reason = "QP SQD/SQE modify is unsupported";
    return decision;
  end

  case (current_state)
    RDMA_QPS_RESET: begin
      if (requested_state == RDMA_QPS_INIT)
        decision.action = RDMA_QP_TRANSITION_SEMANTIC_ONLY;
    end
    RDMA_QPS_INIT: begin
      if (requested_state == RDMA_QPS_RTR)
        decision.action = RDMA_QP_TRANSITION_FULL_MODIFY;
      else if (requested_state inside {RDMA_QPS_ERROR, RDMA_QPS_RESET})
        decision.action = RDMA_QP_TRANSITION_SEMANTIC_ONLY;
    end
    RDMA_QPS_RTR: begin
      if (requested_state == RDMA_QPS_RTS)
        decision.action = RDMA_QP_TRANSITION_FULL_MODIFY;
      else if (requested_state inside {RDMA_QPS_ERROR, RDMA_QPS_RESET})
        decision.action = RDMA_QP_TRANSITION_SEMANTIC_ONLY;
    end
    RDMA_QPS_RTS: begin
      if (requested_state inside {RDMA_QPS_ERROR, RDMA_QPS_RESET})
        decision.action = RDMA_QP_TRANSITION_SEMANTIC_ONLY;
    end
    RDMA_QPS_ERROR: begin
      if (requested_state == RDMA_QPS_RESET)
        decision.action = RDMA_QP_TRANSITION_SEMANTIC_ONLY;
    end
    default: begin
      decision.action = RDMA_QP_TRANSITION_INVALID;
    end
  endcase

  if (decision.action != RDMA_QP_TRANSITION_INVALID) begin
    decision.reject_code = RDMA_SC_OK;
    decision.reject_reason = "";
  end
  return decision;
endfunction
