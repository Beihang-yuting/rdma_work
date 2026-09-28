// 目录/层次：核心执行层 core/rdma_queue_wq_target_policy.sv。
// 文件职责：集中计算 CQ poll 中 send、私有 RQ 和共享 SRQ 对应的 runtime kind 与
//   backing role，消除 queue-data engine 内重复的目标映射分支。
// 主要依赖：依赖 rdma_model_pkg 的资源/queue role 枚举和
//   rdma_queue_runtime_transaction_models.sv 中的 runtime kind；不访问 queue-data
//   engine、runtime ledger、attachment registry、Host-memory、PCIe 或外部 adapter。
// 所有权与生命周期：本文件只返回 detached contract 值；SQ/RQ/SRQ attachment、cursor、
//   reservation、completion release 及其生命周期仍由 queue-data engine/runtime 及资源 owner 管理。

// 设计说明：CQE 的 rq_cqe 与 QP link 的 SRQ presence 是 wire route 到 software ring
// 的唯一输入。把该映射做成纯 policy 后，caller 仍负责 handle incarnation、attachment
// geometry、route/epoch 和 ledger admission，policy 不会把“选择目标”误变成“拥有目标”。
typedef struct {
  rdma_queue_runtime_kind_e runtime_kind;
  rdma_queue_backing_role_e backing_role;
} rdma_queue_wq_target_contract_t;

class rdma_queue_wq_target_policy extends uvm_object;
  `uvm_object_utils(rdma_queue_wq_target_policy)

  // 功能：构造无状态 WQ target policy 对象，供 UVM factory 或 caller 建立短生命周期
  //   的纯值 policy 句柄。
  // 输入/输出及副作用：name（输入）设置对象名；构造不保存 rq_cqe、SRQ presence、
  //   queue handle 或任何 runtime/adapter 引用。
  // 失败/边界：构造成功不代表 contract 已授权；调用方必须检查 for_cqe() 的返回值，
  //   不能把默认 output 当成可提交的 attachment 目标。
  function new(string name = "rdma_queue_wq_target_policy");
    super.new(name);
  endfunction

  // 功能：for_cqe 将 CQE receive 标志与冻结 QP link 的 SRQ presence 投影为唯一的
  //   SQ、私有 RQ 或共享 SRQ runtime kind/backing role，供 poll 和 recovery caller
  //   使用同一目标 contract。
  // 输入/输出及副作用：rq_cqe、srq_present 为只读输入；contract 先写入安全默认值，
  //   成功后发布 detached kind/role；函数不查询或修改 attachment、cursor、ledger、
  //   Host-memory、MMIO 或生命周期 owner。
  // 失败/边界：rq_cqe 或 srq_present 含 X/Z 时返回 0 并保持默认 contract；send CQE
  //   忽略未被选中的 SRQ presence，receive CQE 按 presence 选择 RQ 或 SRQ，后续仍须
  //   由 caller 校验 handle kind、完整 incarnation、attachment geometry 和 route/epoch。
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

  // 功能：for_receive_target 将 post_recv 冻结的 target resource kind 投影为私有
  //   RQ 或共享 SRQ contract，令 receive posting 与 CQ polling 使用同一 role vocabulary。
  // 输入/输出及副作用：target_kind 为只读资源 kind；contract 先置为安全默认值，
  //   对 QP/SRQ 成功写入对应 runtime kind/backing role；函数不查询 QP link、attachment、
  //   runtime 或 resource registry，也不修改任何生命周期状态。
  // 失败/边界：target_kind 为 X/Z 或不是 QP/SRQ 时返回 0；失败 output 保持 QP-RQ 默认，
  //   caller 必须在进入 completion-QP lookup、producer reservation 或 WQE commit 前拒绝。
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
