// 目录/层次：核心执行层 core/rdma_queue_wq_target_policy.sv。
// 文件职责：计算 CQ poll 中 send、私有 RQ、共享 SRQ 对应的 runtime kind 与 backing role。
// 主要依赖：rdma_model_pkg 的资源/queue role 枚举及 runtime kind；不访问 engine、ledger、
//   registry 或外部 adapter。
// 所有权与生命周期：只返回 detached contract 值；attachment、cursor、reservation 等
//   生命周期仍归 queue-data engine/runtime 与资源 owner。
// 设计说明：CQE 的 rq_cqe 与 QP link 的 SRQ presence 是 wire route 到 software ring 的唯一输入。
// 纯 policy 只“选择目标”；handle incarnation、attachment geometry、route/epoch 与 ledger
// admission 仍由 caller 负责。
typedef struct {
  rdma_queue_runtime_kind_e runtime_kind;
  rdma_queue_backing_role_e backing_role;
} rdma_queue_wq_target_contract_t;

class rdma_queue_wq_target_policy extends uvm_object;
  `uvm_object_utils(rdma_queue_wq_target_policy)

  // 功能：构造无状态 policy 对象。
  // 输入/输出及副作用：name 为对象名；不保存任何状态。
  // 失败/边界：无；使用方须检查 for_cqe/for_receive_target 的返回值。
  function new(string name = "rdma_queue_wq_target_policy");
    super.new(name);
  endfunction

  // 功能：由 rq_cqe 与 SRQ presence 选出 SQ、私有 RQ 或共享 SRQ 的 runtime kind/backing role。
  // 输入/输出及副作用：contract 先写安全默认值（SQ），成功后覆盖；纯函数。
  // 失败/边界：rq_cqe 或 srq_present 含 X/Z 返回 0；send CQE 忽略 SRQ presence。
  static function bit for_cqe(
    input logic rq_cqe,
    input logic srq_present,
    output rdma_queue_wq_target_contract_t contract
  );
    contract.runtime_kind = RDMA_QUEUE_RUNTIME_SQ;
    contract.backing_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    if ((rq_cqe !== 1'b0 && rq_cqe !== 1'b1) ||
        (srq_present !== 1'b0 && srq_present !== 1'b1))
      return 1'b0;
    if (!rq_cqe)
      return 1'b1;
    if (srq_present) begin
      contract.runtime_kind = RDMA_QUEUE_RUNTIME_SRQ;
      contract.backing_role = RDMA_QUEUE_ROLE_SRQ_RING;
    end
    else begin
      contract.runtime_kind = RDMA_QUEUE_RUNTIME_RQ;
      contract.backing_role = RDMA_QUEUE_ROLE_QP_RQ_RING;
    end
    return 1'b1;
  endfunction

  // 功能：由 post_recv 目标 resource kind 选出私有 RQ 或共享 SRQ 的 kind/role。
  // 输入/输出及副作用：contract 先写默认值（RQ），成功后覆盖；纯函数。
  // 失败/边界：target_kind 含 X/Z 或非 QP/SRQ 返回 0，caller 须在预留/提交前拒绝。
  static function bit for_receive_target(
    input rdma_resource_kind_e target_kind,
    output rdma_queue_wq_target_contract_t contract
  );
    contract.runtime_kind = RDMA_QUEUE_RUNTIME_RQ;
    contract.backing_role = RDMA_QUEUE_ROLE_QP_RQ_RING;
    if ($isunknown(target_kind))
      return 1'b0;
    case (target_kind)
      RDMA_RESOURCE_QP:
        return 1'b1;
      RDMA_RESOURCE_SRQ: begin
        contract.runtime_kind = RDMA_QUEUE_RUNTIME_SRQ;
        contract.backing_role = RDMA_QUEUE_ROLE_SRQ_RING;
        return 1'b1;
      end
      default:
        return 1'b0;
    endcase
  endfunction
endclass
