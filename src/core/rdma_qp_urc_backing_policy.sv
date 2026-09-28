// 目录/层次：核心执行层 core/rdma_qp_urc_backing_policy.sv。
// 文件职责：集中描述 URC QP 三类内部 backing 的 typed role、长度和顺序，供 QP
//   materialize/recovery 事务消费 detached 规格，避免在执行器中复制几段易漂移的分配代码。
// 主要依赖：依赖 rdma_types_pkg 的 transport/role 枚举；不访问 manager、Host-memory
//   adapter、mapping、QP plan 或 recovery ledger。
// 所有权与生命周期：policy 只生成短生命周期的值规格；真正的 mapping 分配、owner
//   绑定、plan publication 和失败回滚仍由 rdma_qp_lifecycle_executor 唯一拥有。

// 中文设计说明：URC 的 RSQ、RDSQ、DSQ 必须按固定顺序建立，长度分别为 4 KiB、
//   4 KiB、8 KiB。将这组 wire-independent 几何放在纯值层，可以让 executor 只负责
//   “按规格分配并把已分配引用追加到 plan”，从而保留原有 partial-allocation rollback
//   行为，同时禁止其它 transport 获得伪造的 URC backing。
typedef struct {
  rdma_queue_backing_role_e role;
  longint unsigned length;
} rdma_qp_urc_backing_spec_t;

class rdma_qp_urc_backing_policy extends uvm_object;
  `uvm_object_utils(rdma_qp_urc_backing_policy)

  // 功能：构造无状态 URC backing policy，不创建 mapping、plan 或任何外部资源引用。
  // 输入/输出及副作用：name（输入）仅设置 UVM 对象名称；构造函数只初始化基类对象，
  //   不修改 QP、manager、Host-memory adapter 或 recovery ledger。
  // 失败/边界：构造成功不代表 transport 已获得 URC backing；调用方必须显式调用
  //   specs_for_transport()，且只有 RDMA_TRANSPORT_URC 才会得到非空规格数组。
  function new(string name = "rdma_qp_urc_backing_policy");
    super.new(name);
  endfunction

  // 功能：specs_for_transport 根据 transport 返回 URC 内部 backing 的 canonical typed
  //   规格，并按硬件要求给出 RSQ→RDSQ→DSQ 顺序。
  // 输入/输出及副作用：transport（输入）选择是否需要内部 backing；specs（输出）先被
  //   清空，再写入 detached role/length 值；函数不读取或修改 QP plan、allocator、mapping
  //   或外部 adapter，也不分配运行期资源。
  // 失败/边界：非 URC transport（包括 X/Z 或 RC/UD）返回空数组并 fail-closed；URC 始终
  //   返回恰好三项，调用方不得删改规格后把它当作已完成的 allocation evidence。
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
