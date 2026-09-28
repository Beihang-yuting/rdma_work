// 目录：核心执行层 core/rdma_qp_transition_policy.sv，位于 QP 生命周期 policy 层。
// 职责：集中描述 QP 状态迁移矩阵，把状态机决策从 QPC 编码、CMQ 提交和 resource
//   manager mutation 中分离出来；当前只表达既有项目能力，不拥有 QP、CMQ 或 runtime。
// 依赖：依赖 rdma_model_pkg 提供的 rdma_qp_state_e、rdma_status_code_e 和基础值类型；
//   不读取可变 resource manager、outstanding ledger、Host-memory 或外部 adapter。
// 所有权与生命周期：本文件只返回无状态 decision value；decision 不保存任何句柄或
//   外部引用，调用方负责把它映射为 status、编码阶段和最终 commit。

// 设计说明：业界 verbs 的 RESET→INIT→RTR→RTS 是状态机主干，ERROR/RESET 是
//   teardown/recovery 分支。当前驱动 profile 尚未实现 SQD/SQE 的 drain 语义，
//   因而 SQD/SQE 仍由 executor 的 capability gate 拒绝；把剩余矩阵集中在此处，
//   可在未来增加 drain policy 时只替换这一层，而不改动 CMQ、QPC 或 resource owner。
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

// 功能：按当前 QP 状态和目标状态计算唯一迁移动作，供 executor 决定是否只改语义、
//   是否生成完整 QPC modify image，或按既有 capability 返回拒绝。
// 输入/输出及副作用：current_state、requested_state 为只读状态值；返回 decision，
//   不修改 QP/resource manager/CMQ 或任何外部资源。成功 decision 的 reject_code 为
//   RDMA_SC_OK；拒绝 decision 携带稳定错误码和具体原因。
// 失败/边界：状态含未知值、迁移不在当前 profile 矩阵、或任一方向涉及 SQD/SQE
//   时返回 INVALID_STATE/UNSUPPORTED_OPCODE；相同状态由调用方在本 helper 之前按既有
//   顺序拒绝，本函数不改变该错误优先级，也不判断 outstanding WQE 数量。
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
