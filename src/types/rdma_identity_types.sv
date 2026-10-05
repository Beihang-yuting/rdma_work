// 目录：公共类型层 types/rdma_identity_types.sv。
// 职责：定义 BDF、Function key、route key 及其纯值校验函数。
// 依赖：本层 enum 类型（rdma_function_kind_e）。
// 所有权与生命周期：仅含值类型与纯函数，无对象所有权，无生命周期状态。


typedef struct packed {
  bit [15:0] segment;
  bit [7:0] bus;
  bit [4:0] device;
  bit [2:0] function_num;
} rdma_bdf_t;

// 功能：按 PCIe requester-ID 位序拼出 16 位请求者标识。
// 输入/输出及副作用：bdf 为输入；返回 {bus,device,function_num}，无副作用。
// 失败/边界：无；全零 BDF 需由路由层另行校验。
function automatic bit [15:0] rdma_bdf_requester_id(rdma_bdf_t bdf);
  return {bdf.bus, bdf.device, bdf.function_num};
endfunction

typedef struct packed {
  bit [15:0] root_id;
  bit [31:0] host_topology_key;
  rdma_function_kind_e function_kind;
  rdma_bdf_t parent_pf_bdf;
  bit [15:0] vf_index;
  rdma_bdf_t bdf;
} rdma_function_key_t;

// 中文说明：reset epoch 是 Function incarnation 的值快照，用于隔离复位前资源。
typedef longint unsigned rdma_reset_epoch_t;

// 中文说明：PCIe 路由键必须保留 Host/root/segment，避免相同 BDF 跨 fabric 串线。
typedef struct packed {
  bit [31:0] host_topology_key;
  bit [15:0] root_id;
  bit [15:0] segment;
  rdma_bdf_t bdf;
} rdma_route_key_t;

// 功能：从 Function key 投影出完整 route key。
// 输入/输出及副作用：key 为输入；返回独立 route 快照，不修改 key。
// 失败/边界：只投影字段，不判断 PF/VF 合法性（见 rdma_route_key_valid）。
function automatic rdma_route_key_t rdma_route_key_from_function(
  rdma_function_key_t key
);
  rdma_route_key_t route;
  route.host_topology_key = key.host_topology_key;
  route.root_id = key.root_id;
  route.segment = key.bdf.segment;
  route.bdf = key.bdf;
  return route;
endfunction

// 中文说明：这些纯值校验函数由 identity、binding 和各 router 共用。
// BDF 的 segment=0 是合法 PCIe segment；只有完整 BDF 全零才表示缺失。
// 功能：判断 BDF 是否全零（缺失）。
// 输入/输出及副作用：bdf 为输入；返回 bit，无副作用。
// 失败/边界：segment=0 但其他字段非零时返回 0。
function automatic bit rdma_bdf_is_zero(rdma_bdf_t bdf);
  return bdf.segment == 16'h0 && bdf.bus == 8'h0 &&
         bdf.device == 5'h0 && bdf.function_num == 3'h0;
endfunction

// 功能：判断两个 BDF 是否逐字段相同。
// 输入/输出及副作用：lhs/rhs 为输入；返回 bit，无副作用。
// 失败/边界：任一字段不等返回 0。
function automatic bit rdma_bdf_same(rdma_bdf_t lhs, rdma_bdf_t rhs);
  return lhs.segment == rhs.segment && lhs.bus == rhs.bus &&
         lhs.device == rhs.device && lhs.function_num == rhs.function_num;
endfunction

// 中文说明：Host topology key=0 是合法的显式 Host0；BDF 必须非零，且
// route 中的 segment 必须与 BDF segment 一致；root_id=0 允许作为显式 root0。
// 功能：校验 route 可交给 router 查找：BDF 非零且 route.segment 与 BDF segment 一致。
// 输入/输出及副作用：route 为输入；返回 bit，无副作用。
// 失败/边界：BDF 全零或 segment 不一致返回 0；host_topology_key=0、root_id=0 合法。
function automatic bit rdma_route_key_valid(rdma_route_key_t route);
  if (rdma_bdf_is_zero(route.bdf))
    return 1'b0;
  if (route.segment != route.bdf.segment)
    return 1'b0;
  return 1'b1;
endfunction

// 中文说明：Function key 的 parent PF 约束在这里集中执行，避免 VF 走错
// Host/root/segment 或把 parent 当成自身 BDF。
// 功能：校验 Function key：route 合法，且 PF/VF 的 parent PF 与 vf_index 约束成立。
// 输入/输出及副作用：key 为输入；返回 bit，无副作用。
// 失败/边界：PF 须 vf_index=0 且无 parent；VF 须 vf_index 非零、parent 同 segment 且不同于自身；
//   其他 function_kind 返回 0。
function automatic bit rdma_function_key_route_valid(rdma_function_key_t key);
  rdma_route_key_t route;
  route = rdma_route_key_from_function(key);
  if (!rdma_route_key_valid(route))
    return 1'b0;
  case (key.function_kind)
    RDMA_FUNCTION_PF:
      return key.vf_index == 16'h0 && rdma_bdf_is_zero(key.parent_pf_bdf);
    RDMA_FUNCTION_VF:
      return key.vf_index != 16'h0 &&
             !rdma_bdf_is_zero(key.parent_pf_bdf) &&
             key.parent_pf_bdf.segment == key.bdf.segment &&
             !rdma_bdf_same(key.parent_pf_bdf, key.bdf);
    default:
      return 1'b0;
  endcase
endfunction
