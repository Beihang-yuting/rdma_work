// 目录/层次：核心执行层 core/rdma_qp_urc_backing_policy.sv。
// 职责：集中描述 URC QP 三类内部 backing 的 role、长度和顺序，供 QP materialize/recovery 消费。
// 依赖：rdma_types_pkg 的 transport/role 枚举；不访问 manager、adapter、mapping 或 ledger。
// 所有权与生命周期：只生成短生命周期值规格；分配、plan 发布和回滚由 rdma_qp_lifecycle_executor 负责。

// 设计说明：URC 的 RSQ、RDSQ、DSQ 按固定顺序建立，长度 4 KiB、4 KiB、8 KiB；
//   几何放在纯值层，executor 只按规格分配，保留 partial-allocation rollback 行为。
typedef struct {
  rdma_queue_backing_role_e role;
  longint unsigned length;
} rdma_qp_urc_backing_spec_t;

class rdma_qp_urc_backing_policy extends uvm_object;
  `uvm_object_utils(rdma_qp_urc_backing_policy)

  // 功能：构造无状态 policy。
  // 输入/输出及副作用：name 仅设置 UVM 对象名。
  // 失败/边界：无；需显式调用 specs_for_transport()。
  function new(string name = "rdma_qp_urc_backing_policy");
    super.new(name);
  endfunction

  // 功能：按 transport 返回 URC 内部 backing 规格，顺序 RSQ→RDSQ→DSQ。
  // 输入/输出及副作用：specs 先清空，再写入 role/length；不分配资源。
  // 失败/边界：非 URC（含 X/Z）返回空数组；URC 恒为三项。
  static function void specs_for_transport(
    input rdma_transport_e transport,
    output rdma_qp_urc_backing_spec_t specs[$]
  );
    rdma_qp_urc_backing_spec_t spec;

    specs.delete();
    if (transport !== RDMA_TRANSPORT_URC)
      return;

    spec.role = RDMA_QUEUE_ROLE_QP_URC_RSQ;
    spec.length = 4096;
    specs.push_back(spec);
    spec.role = RDMA_QUEUE_ROLE_QP_URC_RDSQ;
    spec.length = 4096;
    specs.push_back(spec);
    spec.role = RDMA_QUEUE_ROLE_QP_URC_DSQ;
    spec.length = 8192;
    specs.push_back(spec);
  endfunction
endclass
